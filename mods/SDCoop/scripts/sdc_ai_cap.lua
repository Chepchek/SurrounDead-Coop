-- SDCoop AI feature ai_host_cap (host): a ceiling on the zombies the host's
-- world keeps alive.
--
-- The game's spawners work around every player (every player character is
-- an AIOptimizer invoker: BP_AISpawner_Master.CanSpawnActors @137
-- IsAnyInvokerInRadius), so 3-4 players far apart each fill their own
-- surroundings, and the host simulates all of it; nothing in the game or the
-- mod limited the total. The host's world, every COUNT_S (only while a client
-- is connected or a spawner is still paused): one GetAllActorsOfClass of
-- BP_MasterZombie (zombies and hounds; their corpses too, so the living are
-- counted - IsDead? - only when the total reaches the resume mark).
-- At ai_host_cap_zombies living zombies the world is full: a zombie spawner
-- (SpawnedActorClass BP_Zombie_*, no boss) that queues a group
-- (AddGroupToSpawn, post-hook) is paused with the game's own switch,
-- SetIsSpawningStopped(true) (CanSpawnActors reads IsSpawningStopped; the
-- queued group waits in SpawnGroupsQueue, nothing is lost; IsSpawningStopped is
-- no SaveGame property). The cap is soft: AddGroupToSpawn spawns its first
-- actor before it returns (@1045 queue, @1113 TryToSpawnGroup; SpawningCapacity
-- 1, SpawningInterval 0.5 s), so a new group's first zombie and a single
-- respawn (a group of 1) still come; the pause holds the rest of a group.
-- Below RESUME_PCT % of the cap a paused spawner gets SetIsSpawningStopped(false)
-- back (it calls TryToSpawnGroup: the waiting group spawns) once a living
-- player is within its SpawnRadius (place and radius read when it was paused):
-- the game spawns only then (CanSpawnActors: IsAnyInvokerInRadius) and tries
-- again only at the spawner's next AddGroupToSpawn (its radius timer is
-- one-shot, cleared @1875), so a spawner given back with nobody near kept the
-- rest of its group unspawned. While nobody is near, a paused spawner changes
-- nothing the game would do. RESUME_PER_TICK per COUNT_S so they do not all
-- spawn at once. A spawner the game itself switches meanwhile (a post-hook on
-- SetIsSpawningStopped) is the game's again. Turned off, a role change in the
-- same world: every paused spawner resumed at once, a player near or not (the
-- rest of a group with nobody near comes with that spawner's next group).
-- sdc_ai_scale adds no bigger group while the world is full (core.ai_full).
-- Bosses, animals, people, hordes, infestation waves: not paused (counted
-- when they are zombies).
-- The ceiling follows the players in the world (the host and every connected
-- client; the user's decision 2026-11-13: "flexible", 250 kept):
--   cap = min(ai_host_cap_max, ai_host_cap_zombies + ai_host_cap_per_player x (players - 4))
-- (ai_host_cap_zombies: the ceiling for up to BASE_PLAYERS = 4 players, at
-- least MIN_CAP; the maximum never below it). Defaults 250 / +25 / 300: two
-- to four players 250 (as before), five 275, six and more 300. Why 250: the
-- busiest place in our logs had 63 characters (players included) within a
-- client's 150 m; the optimizer keeps zombies up to 225 m from a player (2.25
-- times that area): ~140 per player at most. Two players in the busiest
-- places stay under it; it acts with 3-4 players spread over busy places -
-- exactly where it guards the host's machine, so a usual session of 2-4 keeps
-- 250 (a step from the second player on gave 3-4 players 10-20 % more); every
-- player beyond four adds a little room, up to the maximum. A change of the
-- ceiling (a player joins / leaves, the settings) is logged. Every LOG_S the
-- living count and its maximum are logged, to tune it.
-- Not done: lowering the ceiling by itself when the host's frame rate is bad.
-- The mod's frame counter is a per-frame Lua loop (a timer where UE4SS has no
-- engine-tick hook), the frame rate drops for other reasons (the video card,
-- the game window in the background, loading and saving), and a false alarm
-- would quietly take zombies from every player; the [PERF] line (fps) and
-- this module's counts in UE4SS.log are there to set the numbers by hand.
-- Kept: spawner names (strings), their places and radii (numbers) and clocks.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = { stats = { counts = 0, max_living = 0, paused = 0, resumed = 0, gone = 0, game = 0, failed = 0, full = 0 } }
local core

local SPAWNER = "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C"
local COUNT_S = 5
local LOG_S = 600
local RESUME_PCT = 90
local RESUME_PER_TICK = 8
local DEFAULT_CAP = 250          -- up to BASE_PLAYERS players
local DEFAULT_PER_PLAYER = 25    -- each player beyond them
local DEFAULT_MAX = 300
local BASE_PLAYERS = 4
local MIN_CAP = 40
local SPAWN_RADIUS = 14000   -- BP_AISpawner_Master's default SpawnRadius (cm)

local state = { full = false, living = 0, all = 0, at = -1e9, logged = -1e9, waiting = 0, limit = nil }
local paused = {}        -- [spawner full name] = { t = clock it was paused, X, Y, Z = its place, r = its SpawnRadius }
local paused_n = 0
local ours = false       -- this module's own SetIsSpawningStopped call

local function setting(key, default)
    local v = tonumber(cfg.get(key))
    if v == nil then return default end
    return math.floor(v)
end

-- Players in this world now: the host and every connected client.
local function players_now()
    return 1 + #((core and core.S and core.S.remote_pcs) or {})
end
M.players_now = players_now

-- The ceiling for `n` players (default: the players in this world now) and
-- its parts: the value for up to four players, the step per player beyond
-- them, the maximum.
local function cap(n)
    n = n or players_now()
    local base = math.max(MIN_CAP, setting("ai_host_cap_zombies", DEFAULT_CAP))
    local per = math.max(0, setting("ai_host_cap_per_player", DEFAULT_PER_PLAYER))
    local top = math.max(base, setting("ai_host_cap_max", DEFAULT_MAX))
    return math.min(top, base + per * math.max(0, n - BASE_PLAYERS)), base, per, top
end
M.cap = cap

local function zombie_spawner(sp)
    local cls = ue.prop(sp, "SpawnedActorClass")
    if not ue.valid(cls) then return false end
    local name = ue.short(cls)
    return name:sub(1, 10) == "BP_Zombie_" and not name:find("Boss", 1, true)
end

-- Living zombies in this world (nil: the class is not loaded / the call failed).
local function count(resume_at)
    local out = ue.actors_of(core.ZOMBIE_CLASS)
    if type(out) ~= "table" then return nil end
    local all = #out
    state.all = all
    if all < resume_at then return all end   -- fewer in all than the mark: no need to tell the dead
    local living = 0
    for i = 1, all do
        local z = ue.elem(out[i])
        if ue.valid(z) and ue.prop(z, "IsDead?") ~= true then living = living + 1 end
    end
    return living
end

local function set_stopped(sp, stop)
    ours = true
    local ok = ue.call(sp, "SetIsSpawningStopped", stop)
    ours = false
    return ok
end

-- A living player within a paused spawner's SpawnRadius (its place unknown: yes).
local function player_near(p, players)
    if not p.X or not (p.r and p.r > 0) then return true end
    local r2 = p.r * p.r
    for _, e in ipairs(players) do
        local dx, dy, dz = e.loc.X - p.X, e.loc.Y - p.Y, e.loc.Z - p.Z
        if dx * dx + dy * dy + dz * dz <= r2 then return true end
    end
    return false
end

-- Paused spawners with a living player within their SpawnRadius get their
-- switch back (at most `limit`; all when nil); the others wait for one.
-- `all` (turned off, a role change): every paused spawner, near or not.
-- Spawners no longer in the world are forgotten.
local function resume(limit, why, all)
    if paused_n == 0 then return 0 end
    local players = ctx.live_players()
    local due, far = {}, 0
    for key, p in pairs(paused) do
        local near = player_near(p, players)
        if (all or near) and (not limit or #due < limit) then due[#due + 1] = key end
        if not near then far = far + 1 end
    end
    state.waiting = all and 0 or far
    if #due == 0 then return 0 end
    local out = ue.actors_of(SPAWNER)
    if type(out) ~= "table" then return 0 end
    local here, n = {}, 0
    for i = 1, #out do
        local sp = ue.elem(out[i])
        if ue.valid(sp) then
            local key = ue.name(sp)
            if paused[key] then here[key] = sp end
        end
    end
    for _, key in ipairs(due) do
        local sp = here[key]
        paused[key] = nil
        paused_n = paused_n - 1
        if not sp then
            M.stats.gone = M.stats.gone + 1
        elseif set_stopped(sp, false) then
            n = n + 1
            M.stats.resumed = M.stats.resumed + 1
        else
            M.stats.failed = M.stats.failed + 1
        end
    end
    if n > 0 and all then
        log.info("ai: cap: %d zombie spawner(s) spawn again (%s; %d of them with no player within their spawn radius:"
            .. " the rest of their group comes with their next group)", n, why, far)
    elseif n > 0 then
        log.info("ai: cap: %d zombie spawner(s) spawn again (%s; %d still paused, %d of them until a player comes"
            .. " within their spawn radius)", n, why, paused_n, far)
    end
    return n
end

-- BP_AISpawner_Master.AddGroupToSpawn(AmountToSpawn), post (host): a group
-- queued while the world is full -> the spawner waits.
local function on_add_group(c)
    if ours or not state.full then return end
    local sp = ue.param(c)
    if not ue.valid(sp) or not zombie_spawner(sp) then return end
    local key = ue.name(sp)
    if paused[key] or ue.prop(sp, "IsSpawningStopped") == true then return end
    if not set_stopped(sp, true) then
        M.stats.failed = M.stats.failed + 1
        return
    end
    local l = ue.location(sp)
    paused[key] = { t = os.clock(), X = l and l.X, Y = l and l.Y, Z = l and l.Z,
                    r = tonumber(ue.prop(sp, "SpawnRadius")) or SPAWN_RADIUS }
    paused_n = paused_n + 1
    M.stats.paused = M.stats.paused + 1
    local say = core.line("cap.paused", 5)
    if say then
        say("ai: cap: %s paused: %d living zombies in this world (cap %d); it spawns when there are fewer than %d"
            .. " and a player is within its spawn radius (%.0f m)", ue.short(sp), state.living, (cap()),
            math.floor((cap()) * RESUME_PCT / 100), paused[key].r / 100)
    end
end

-- BP_AISpawner_Master.SetIsSpawningStopped(Stop), post (host): the game
-- switched a paused spawner itself -> it is the game's again.
local function on_stopped(c)
    if ours or paused_n == 0 then return end
    local sp = ue.param(c)
    if not ue.valid(sp) then return end
    local key = ue.name(sp)
    if not paused[key] then return end
    paused[key] = nil
    paused_n = paused_n - 1
    M.stats.game = M.stats.game + 1
    log.info("ai: cap: the game switched the paused %s itself: it is the game's again", ue.short(sp))
end

function M.host_tick(now)
    if now - state.at < COUNT_S then return end
    state.at = now
    if not core.host.active and paused_n == 0 then
        state.full = false
        return
    end
    local players = players_now()
    local limit, base, per, top = cap(players)
    local resume_at = math.floor(limit * RESUME_PCT / 100)
    if limit ~= state.limit then
        log.info("ai: cap: %d player(s) in this world: the cap is %d living zombies (%d for up to four players, +%d"
            .. " for each player beyond four, at most %d)%s", players, limit, base, per, top,
            state.limit and string.format(", was %d", state.limit) or "")
        state.limit = limit
    end
    local living = count(resume_at)
    if living == nil then return end
    M.stats.counts = M.stats.counts + 1
    state.living = living
    if living > M.stats.max_living then M.stats.max_living = living end
    if not state.full and living >= limit then
        state.full = true
        M.stats.full = M.stats.full + 1
        log.info("ai: cap: %d living zombies in this world (cap %d for %d players): zombie spawners pause"
            .. " their next groups until there are fewer than %d", living, limit, players, resume_at)
    elseif state.full and living < resume_at then
        state.full = false
        log.info("ai: cap: %d living zombies: below %d again", living, resume_at)
    end
    if not state.full and paused_n > 0 then resume(RESUME_PER_TICK, string.format("%d living zombies", living)) end
    if now - state.logged >= LOG_S then
        state.logged = now
        log.info("ai: cap: %d living zombies now (%d actors with corpses), at most %d so far; cap %d", living,
            state.all, M.stats.max_living, limit)
    end
end

function M.init(c)
    core = c
    core.ai_full = function() return state.full == true end
    core.hook({ path = SPAWNER .. ":AddGroupToSpawn", kind = "bp", role = "host", feature = "cap",
                name = "cap.group", fn = on_add_group })
    core.hook({ path = SPAWNER .. ":SetIsSpawningStopped", kind = "bp", role = "host", feature = "cap",
                name = "cap.stopped", fn = on_stopped })
end

-- Turned off: every paused spawner spawns again.
function M.off()
    state.full = false
    local ok, err = pcall(resume, nil, "ai_host_cap off", true)
    if not ok then log.err_throttled("ai.cap.off", "ai: cap: resume: %s", tostring(err)) end
end

-- A role change in this world: the paused spawners get their switch back; a
-- new world: its spawners are new (the names go).
function M.reset(why)
    if tostring(why) == "role" and paused_n > 0 then
        local ok, err = pcall(resume, nil, "role change", true)
        if not ok then log.err_throttled("ai.cap.reset", "ai: cap: resume: %s", tostring(err)) end
    end
    paused, paused_n = {}, 0
    state.full, state.living, state.all, state.at, state.waiting, state.limit = false, 0, 0, -1e9, 0, nil
end

function M.status_line()
    local s = M.stats
    return string.format("ai: cap living=%d (max %d, actors %d) cap=%d (players %d) full=%s | spawners paused now=%d"
        .. " (waiting for a player %d) paused=%d resumed=%d gone=%d game's again=%d failed=%d", state.living,
        s.max_living, state.all, (cap()), players_now(), tostring(state.full), paused_n, state.waiting, s.paused,
        s.resumed, s.gone, s.game, s.failed)
end

M._t = { on_add_group = on_add_group, on_stopped = on_stopped, state = state,
         paused = function() return paused, paused_n end }

return M
