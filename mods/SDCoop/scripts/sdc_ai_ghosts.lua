-- SDCoop AI feature ai_client_ghosts (client): zombies, hounds, bosses and
-- animals that exist only on this client.
--
-- Every AI of the host reaches a client as a replicated copy (role 1). A
-- local-authority one (role 3, runtime-spawned) is a ghost: no AI controller
-- (APawn::SpawnDefaultController does nothing on a client), so it stands or
-- hangs where it appeared, while the host's copy next to it moves and fights
-- (the "second boss hanging in the air" of 2026-11-10 14:37). Two ways the
-- game makes one on a client:
--   * BP_AISpawner_Master (zombies, hounds, bosses, animals, settlement
--     survivors: data-only children). Its BeginPlay -> InitSpawner -> @4040
--     IsSpawnedClassReplicated -> HasAuthority: only an authority spawner
--     spawns a replicated class. The host's spawners reach a client as copies
--     (role 1) and stop there; a spawner that is this machine's own (role 3)
--     spawns here. Fix: SetIsSpawningStopped(true) on it, the game's own switch
--     (CanSpawnActors reads IsSpawningStopped).
--   * The AI optimizer plugin. A zombie / boss / animal whose
--     OnOptimizationUpdate says "beyond the last layer" calls
--     AIOptimizerSubsystem.K2_DespawnSubject (zombie @15045, boss @11880,
--     wolf @3969, ...) with no authority check, so the client's own optimizer
--     despawns host copies by the client's distance, and the plugin respawns
--     subjects itself (its spawner callbacks OnSubjectSpawnedByOptimizerSubsystem)
--     — on a client that would be a local actor. Fix: a boss copy gets
--     SD_AIComponent.CanSystemDespawnAI? = false, the flag the boss checks
--     first (@11844) and the game's quest spawner sets (BP_Quest_Spawner_AI
--     @1092). Zombies / animals have no such flag (their despawns on a client
--     were logged once for evidence; that hook is gone).
-- Every 3 s: the engine's live actor lists of BP_MainEnemy_C (zombies, hounds,
-- bosses) and BP_Animal_C; a role-3 runtime-spawned one that is not torn off
-- is destroyed (2 tries) and named in the log. Smart AI ghosts (bandits,
-- soldiers, traders) stay sdc_sync.client_ai_tick's.
-- Memory: a spawner not visited in the last three rounds of the cursor is
-- gone (camps' spawners come and go: 937 entries after 50 min) and is
-- forgotten; the per-copy tables go with the core's sweep of gone copies.

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = {
    stats = { spawners_host = 0, spawners_stopped = 0, removed = 0, survived = 0, boss_flags = 0, spawners_forgotten = 0 },
}
local core

local SPAWNER_CLASS = "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C"
local ENEMY_CLASS = "/Game/AI/Other/BP_MainEnemy.BP_MainEnemy_C"
local PASS_S = 3
local MAX_TRIES = 2
local LIST_MAX = 8
local VISIT_MAX = 192          -- actors looked at per class and pass (a cursor goes round)

local spawners = {}    -- client: [spawner full name] = "host" | "stopped"
local seen = {}        -- client: [spawner full name] = visits.n when it was last looked at
local visits = { n = 0, pruned = 0 }   -- client: spawner visits so far, at the last prune
local tries = {}       -- client: [ghost full name] = attempts
local flagged = {}     -- client: [boss copy full name] = true
local pass = { last = -1000, broken = false }
local cursors = {}     -- [class path] = index of the last actor looked at

-- At most VISIT_MAX elements of `out`, continuing where the last pass of this
-- class stopped; fn(actor) for each.
local function visit_some(path, out, fn)
    local n = #out
    if n == 0 then return end
    local c = cursors[path] or 0
    for _ = 1, math.min(n, VISIT_MAX) do
        c = c % n + 1
        fn(ue.elem(out[c]))
    end
    cursors[path] = c
end

-- live actors of a class in this world (engine iterator: pending-kill ones
-- excluded); {} when the class is not loaded, false + error when the call failed
local function actors_of(class_path)
    local out, err = ue.actors_of(class_path)
    if out == nil then return {} end
    return out, err
end

local function cls_short(c)
    if not ue.valid(c) then return "?" end
    return ue.short(c)
end

-- Spawners not looked at in the last three rounds of the cursor (n = the
-- live list's length) are gone: forgotten. A live one forgotten by a shifted
-- list is only classified again on its next visit.
local function prune_spawners(n)
    if n == 0 or visits.n - visits.pruned < 3 * n then return end
    visits.pruned = visits.n
    local before, dropped = visits.n - 3 * n, 0
    for key, v in pairs(seen) do
        if v < before then
            seen[key], spawners[key] = nil, nil
            dropped = dropped + 1
        end
    end
    M.stats.spawners_forgotten = M.stats.spawners_forgotten + dropped
    if dropped > 0 then
        log.debug("ai: ghosts: forgot %d spawner(s) no longer in this world (%d live)", dropped, n)
    end
end

-- This client's own spawners would spawn its own AI: stop them.
local function stop_spawners()
    local out, err = actors_of(SPAWNER_CLASS)
    if out == false then return err end
    local stopped, n_stopped = {}, 0
    visit_some(SPAWNER_CLASS, out, function(sp)
        if not ue.valid(sp) then return end
        local key = ue.name(sp)
        visits.n = visits.n + 1
        seen[key] = visits.n
        if spawners[key] then return end
        if ue.role(sp) ~= ue.ROLE_AUTHORITY then
            spawners[key] = "host"
            M.stats.spawners_host = M.stats.spawners_host + 1
            return
        end
        spawners[key] = "stopped"
        local ok = ue.call(sp, "SetIsSpawningStopped", true)
        M.stats.spawners_stopped = M.stats.spawners_stopped + 1
        n_stopped = n_stopped + 1
        if #stopped < LIST_MAX then
            stopped[#stopped + 1] = string.format("%s(%s%s)", ue.short(sp),
                cls_short(ue.prop(sp, "SpawnedActorClass")), ok and "" or ", call failed")
        end
    end)
    if n_stopped > 0 then
        log.info("ai: ghosts: stopped %d spawner(s) of this client's own (only the host spawns AI): %s%s",
            n_stopped, table.concat(stopped, " "), n_stopped > #stopped and " ..." or "")
    end
    prune_spawners(#out)
    return nil
end

-- A host boss copy: this machine's AI optimizer must not despawn it.
local function flag_boss(b)
    local key = ue.name(b)
    if flagged[key] then return end
    flagged[key] = true
    local comp = ue.prop(b, "SD_AIComponent")
    if ue.valid(comp) and ue.prop(comp, "CanSystemDespawnAI?") == true and ue.set_prop(comp, "CanSystemDespawnAI?", false) then
        M.stats.boss_flags = M.stats.boss_flags + 1
        local say = core.line("ghosts.boss", 3)
        if say then say("ai: ghosts: %s: this client's AI optimizer will not despawn the host's boss", ue.short(b)) end
    end
end

local function remove_ghosts()
    local removed, n_removed = {}, 0
    for _, path in ipairs({ ENEMY_CLASS, core.ANIMAL_CLASS }) do
        local out, err = actors_of(path)
        if out == false then return err end
        visit_some(path, out, function(a)
            if not ue.valid(a) then return end
            if ue.role(a) ~= ue.ROLE_AUTHORITY then
                if core.is_boss(a) then flag_boss(a) end
                return
            end
            if not ue.is_runtime_spawned(a) or ue.prop(a, "bTearOff") == true then return end
            local key = ue.name(a)
            local n = (tries[key] or 0) + 1
            tries[key] = n
            if n > MAX_TRIES then
                if n == MAX_TRIES + 1 then
                    M.stats.survived = M.stats.survived + 1
                    log.warn("ai: ghosts: local %s survives removal, left alone", ue.short(a))
                end
                return
            end
            local l = ue.location(a)
            local what = string.format("%s(dead=%s at %s)", ue.short(a),
                tostring(ue.prop(a, "IsDead?") == true or ue.prop(a, "Dead") == true),
                l and string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z) or "?")
            if pcall(function() a:K2_DestroyActor() end) then
                M.stats.removed = M.stats.removed + 1
                n_removed = n_removed + 1
                if #removed < LIST_MAX then removed[#removed + 1] = what end
            end
        end)
    end
    if n_removed > 0 then
        log.info("ai: ghosts: removed %d AI that existed only on this client: %s%s", n_removed,
            table.concat(removed, " "), n_removed > #removed and " ..." or "")
    end
    return nil
end

function M.init(c)
    core = c
    -- per-copy tables keyed by full name: entries of copies that are gone go
    -- with the core's once-a-minute sweep
    if core.forget_gone then
        core.forget_gone("ghosts", function() return { tries = tries, flagged = flagged } end)
    end
end

function M.client_tick(now)
    if pass.broken or now - pass.last < PASS_S then return end
    pass.last = now
    local err = stop_spawners() or remove_ghosts()
    if err then
        pass.broken = true
        log.warn("ai: ghosts: GetAllActorsOfClass failed (%s); local AI no longer checked", tostring(err))
    end
end

-- World / role change: names of the old world mean nothing any more.
function M.reset()
    spawners, seen, tries, flagged, cursors = {}, {}, {}, {}, {}
    visits = { n = 0, pruned = 0 }
    pass = { last = -1000, broken = false }
end

function M.status_line()
    local n = 0
    for _ in pairs(spawners) do n = n + 1 end
    local s = M.stats
    return string.format("ai: ghosts spawners host=%d stopped=%d known now=%d forgotten=%d | local AI removed=%d"
        .. " survived=%d | boss copies kept=%d", s.spawners_host, s.spawners_stopped, n, s.spawners_forgotten,
        s.removed, s.survived, s.boss_flags)
end

M._t = { spawners = function() return spawners end, seen = function() return seen end }

return M
