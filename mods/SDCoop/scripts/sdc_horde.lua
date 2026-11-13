-- SDCoop AI feature ai_horde_beacon: the Horde Beacon (Buildable_HordeBeacon)
-- in co-op. Studied 2026-11-13 (pak -> pseudo, not in work\re\pseudo):
--
-- How the game runs it. Pressing the beacon (option 1) runs on the host
-- (OnServerExecuteInteract @6083) and goes to every machine as the multicast
-- MC_OnInteractBuildable (Buildable_MASTER, NetMulticast, unreliable) ->
-- OnInteractBuildable @7020 -> Event_StartHorde @4537: EVERY machine runs its
-- own copy of the whole horde: game music paused (Stop Music?), the horde
-- music started (MusicLayeringComponent.Initialise - a NetServer RPC: it
-- plays on the host only), "Horde Beacon Activated..." and the countdown (30 /
-- 20 / 10 / 5 s) as local game notifications, then per wave (Event_NextWave
-- @4117): NextTrack, "Wave: N Begin!", the wave's AI spawned with
-- BeginDeferredActorSpawnFromClass, EnemyDefeatedCheck every 5 s ("AI Is Dead?"
-- of CurrentEnemy), "Wave Completed! Next Wave in 15 Seconds...", the final
-- wave: "Final wave defeated!", SpawnRewards, the beacon destroyed. Its
-- ReceiveBeginPlay, 2 s later (@4057 Delay -> @918), binds the PlayerDead of
-- CastToCharacter(self) = GetPlayerCharacter(self, 0): that player's death
-- (Event_PlayerDead @5107 -> Event_SpawnBeacon @5122) spawns the beacon's
-- pickup at RewardSpawnLoc, waits 0.2 s (Delay, latent UUID 916395564, @5306)
-- and destroys the beacon (@1029) - every placed beacon, started or not
-- (Event_PlayerDead checks nothing). The binding is to one character: after
-- that player respawns, no death of anyone reaches the beacon any more.
-- On a client that means:
--   * the press, the countdown and wave 1's notice work (its own copy runs);
--   * its wave 1 spawns are its own AI (no AI controller on a client):
--     sdc_ai_ghosts removes them within 3 s; the client's CurrentEnemy then
--     never reads "dead", so its copy waits forever: no "Wave completed",
--     later waves or "Final wave defeated" on the client;
--   * no horde music (Initialise never reaches the host from a client);
--   * the client's death: its copy spawns a local beacon pickup (a phantom
--     item there) - the destroy fails on a copy;
--   * on the host, the death of the player the beacon is bound to (player 0
--     at its binding: the host) ended the horde for everyone.
-- Fixes (this feature):
--   host   Event_NextWave / EnemyDefeatedCheck (All Defeated?) /
--          FinalWaveDefeated? / Event_SpawnBeacon post-hooks: HORDE|wave|N
--          (waves 2+), HORDE|done|N, HORDE|final, HORDE|kept / HORDE|over
--          (see below; an idle beacon's death notice goes to nobody)
--          to the clients within RANGE_CM of the beacon, with its place. A
--          dead client has no character (AfterDeath unpossesses the body,
--          @1387): its place is its body's (the last character sdc_players
--          keeps while it is dead); its place unknown: HORDE|over still goes
--          to it (an end notice too many rather than none: when every player
--          is dead, every client is pawnless).
--   host   ai_horde_continue (the user's decision 2026-11-13: the horde goes
--          on while at least one player is alive): while a client is
--          connected, every beacon gets a Delay of this module with the
--          death path's latent UUID (KismetSystemLibrary.Delay adds no action
--          while one with the same object and UUID is pending), that never
--          runs out and runs nothing: the game's 0.2 s destroy after a death
--          is never added ("held"). A UE4SS Blueprint hook runs after the
--          function (no pre-hook can skip it), and the binding cannot be
--          undone from Lua: holding the destroy is the one way found. Then
--          the bound player's death (Event_SpawnBeacon post):
--            someone still alive -> the beacon stays (its horde runs on), the
--              pickup the game just spawned is taken back once the beacon is
--              still there PICKUP_AGE_S (game time) after it, clients near
--              it told (HORDE|kept); the end is deferred;
--            nobody alive, or ai_horde_continue off -> the game's end: the
--              pickup stays, the beacon is destroyed by this module
--              DESTROY_MS later (the game's own destroy is held), HORDE|over.
--          Every player dead for ALL_DEAD_S (every host tick): each held
--          beacon whose end was deferred, and each held horde still running,
--          ends the game's way (Event_SpawnBeacon + the destroy). A horde
--          ended because nobody is alive: the host sees horde_over_all too.
--          No client connected: nothing is held, the game runs as in single
--          player.
--   host   a running horde's new wave (ai_horde_continue): each zombie gets
--          SetBB_LockOnTarget(GetPlayerCharacter(beacon, 0) location)
--          (@2478-2605); sdc_world's scope makes player 0 the player who
--          pressed the beacon (CurrentActor). That player dead (the host: the
--          kept horde above) has no character: the call gives None and the
--          wave ran to the map's origin (0, 0, 0). ctx.beacon_scope (asked by
--          sdc_world's "beacon" kind) answers the living player nearest to
--          the beacon instead, while the presser has no living character.
--   client the game's notice in its language (wave N, wave done, final,
--          kept, over); the horde music: when its copy starts the horde
--          (Event_StartHorde post, HordeStarted? true, no track playing) the
--          component's Initialise body runs here (ExecuteUbergraph entry
--          1128, as sdc_localinit runs BP_PlayerCharacter's entry), and every
--          relayed wave calls NextTrack on that copy; its own death: the
--          local beacon pickup next to the copy is removed.
-- Diagnostics: start / stop / waves / deaths / holds logged on both sides.
-- Kept: strings and numbers (records by beacon full name).

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = { stats = { started = 0, stopped = 0, waves = 0, done = 0, final = 0, over = 0, sent = 0,
                      notices = 0, music = 0, tracks = 0, pickups = 0,
                      held = 0, hold_failed = 0, kept = 0, taken = 0, hold_lost = 0, ended = 0 } }
local core

local BEACON = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C"
local PICKUP = "/Game/Inventory/Items/Pickups/Buildable/HordeBeacon/BP_HordeBeaconPickup.BP_HordeBeaconPickup_C"
local B = BEACON .. ":"
local INIT_ENTRY = 1128       -- MusicLayeringComponent: Initialise's ubergraph entry
local RANGE_CM = 20000        -- clients this close to the beacon get its notices
local FIND_CM = 500           -- client: the copy of the beacon at the relayed place
local PICKUP_CM = 500
local DEATH_UUID = 916395564  -- Event_SpawnBeacon's Delay(0.2 s) before K2_DestroyActor (@5306 -> @1029)
local HOLD_S = 1e7            -- the stand-in Delay: never runs out in a session (and runs nothing)
local HOLD_CHECK_S = 2        -- host: new beacons held / the "everyone dead" check, this often
local ALL_DEAD_S = 2          -- every player dead this long: the deferred hordes end
local DESTROY_MS = 250        -- this module's stand-in for the game's 0.2 s destroy
local PICKUP_AGE_S = 0.35     -- a pickup this old (game time) next to a beacon still there: the hold took
local PICKUP_SLACK_S = 0.5    -- a pickup older than the death (+ this) is someone's item: never taken back
local POLL_MS = 250
local POLL_N = 16             -- the taken-back pickup is looked for ~4 s

local TEXT = {
    horde_wave  = { "Wave %d begins!", "Волна %d началась!" },
    horde_done  = { "Wave %d completed! Next wave in 15 seconds...", "Волна %d отбита! Следующая через 15 секунд..." },
    horde_final = { "Final wave defeated!", "Последняя волна отбита!" },
    horde_kept  = { "A player died, but the horde goes on while at least one of you is alive.",
                    "Игрок погиб, но орда продолжается, пока жив хоть один из вас." },
    horde_over  = { "The horde stopped: the player the beacon is tied to died.",
                    "Орда остановлена: погиб игрок, к которому привязан маяк." },
    horde_over_all = { "The horde stopped: every player is dead.", "Орда остановлена: погибли все игроки." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end

local pending = {}            -- host: [beacon full name] = { wave, loc, t }: its wave all dead, not the final one yet
local held = {}               -- host: [beacon full name] = true: the game's death-path destroy is held (our Delay)
local deferred = {}           -- host: [beacon full name] = { short, t }: a death the game ends it on, kept for now
local ending = {}             -- host: [beacon full name] = true: this module is ending it (its Event_SpawnBeacon)
local closing = {}            -- host: [beacon full name] = true: its removal is on the way (never ended twice)
local aimed = {}              -- host: [beacon full name] = the player its waves run to (short name; logged on a change)
local hold_at, dead_since = -1e9, nil

local function f0(v) return string.format("%.0f", v) end

local function wave_of(b)
    local w = tonumber(ue.prop(b, "CurrentWave"))
    return w and (w + 1) or 0
end

local function continue_on() return cfg.get("ai_horde_continue") ~= false end
local function coop_now() return #((core.S or {}).remote_pcs or {}) > 0 end
local function alive_count()
    local ok, list = pcall(ctx.live_players)
    return ok and type(list) == "table" and #list or 0
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

-- Where client `pc` is: its character; dead (the body is unpossessed), its
-- last character, the body, which sdc_players keeps in its session record.
local function client_place(pc)
    local p = ue.pawn_of(pc)
    if not p then
        local r = (core.S.remote or {})[ue.name(pc)]
        p = type(r) == "table" and ue.valid(r.pawn) and r.pawn or nil
    end
    return p and ue.location(p) or nil
end

local function send_near(loc, kind, ...)
    if not loc then return 0 end
    local n = 0
    for _, pc in ipairs(core.S.remote_pcs or {}) do
        local l = client_place(pc)
        local near = kind == "over"   -- its place unknown: the end notice all the same
        if l then
            local dx, dy, dz = l.X - loc.X, l.Y - loc.Y, l.Z - loc.Z
            near = dx * dx + dy * dy + dz * dz <= RANGE_CM * RANGE_CM
        end
        if near and net.send_to(pc, "HORDE", kind, ...) then n = n + 1 end
    end
    M.stats.sent = M.stats.sent + n
    return n
end

local function relay_at(loc, kind, wave, ...)
    if not loc then return 0 end
    return send_near(loc, kind, tostring(wave or 0), f0(loc.X), f0(loc.Y), f0(loc.Z), ...)
end

local function relay(b, kind, wave, ...)
    return relay_at(ue.location(b), kind, wave, ...)
end

-- This world's beacons with authority here, by full name (nil: not known now).
local function beacons_here()
    local out = ue.actors_of(BEACON)
    if type(out) ~= "table" then return nil end
    local here = {}
    for i = 1, #out do
        local b = ue.elem(out[i])
        if ue.valid(b) and ue.role(b) == ue.ROLE_AUTHORITY then here[ue.name(b)] = b end
    end
    return here
end

local function find_beacon(key)
    local here = beacons_here()
    return here and here[key] or nil
end

-- Holds the game's own end of beacon `b` on its bound player's death: a
-- Delay of ours with the death path's latent UUID on it (see the header).
local function hold(b)
    local key = ue.name(b)
    if held[key] then return true end
    local ksl = ue.ksl()
    if not ksl then return false end
    local ok, err = pcall(function()
        ksl:Delay(b, HOLD_S, { Linkage = -1, UUID = DEATH_UUID, ExecutionFunction = FName("None"), CallbackTarget = b })
    end)
    if not ok then
        M.stats.hold_failed = M.stats.hold_failed + 1
        log.err_throttled("ai.horde.hold", "ai: horde: %s: could not hold the game's end on a death (%s): a death"
            .. " ends its horde as in the game", ue.short(b), tostring(err))
        return false
    end
    held[key] = true
    M.stats.held = M.stats.held + 1
    log.info("ai: horde: %s held for co-op: the death of the player the game ties it to no longer ends it while"
        .. " another player is alive", ue.short(b))
    return true
end

-- The game's 0.2 s destroy of a held beacon (held: the game's own never comes).
local function destroy_later(key, short)
    closing[key] = true
    ue.delay("horde-end", DESTROY_MS, function()
        local b = find_beacon(key)
        if not b then return end
        if pcall(function() b:K2_DestroyActor() end) then
            log.info("ai: horde: %s removed (the game's own removal after a death is held)", short)
        else
            log.warn("ai: horde: %s: removing it failed", short)
        end
    end)
end

-- The newest beacon pickup with authority here within PICKUP_CM of `at`, at
-- most `max_age` old, and its age (game s).
local function newest_pickup(at, max_age)
    if not at then return nil end
    local out = ue.actors_of(PICKUP)
    if type(out) ~= "table" then return nil end
    local best, best_age = nil, nil
    for i = 1, #out do
        local p = ue.elem(out[i])
        local l = ue.valid(p) and ue.role(p) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(p) and ue.location(p)
        if l then
            local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
            local age = tonumber(ue.try(function() return p:GetGameTimeSinceCreation() end))
            if age and age <= max_age and dx * dx + dy * dy + dz * dz <= PICKUP_CM * PICKUP_CM
                and (not best_age or age < best_age) then
                best, best_age = p, age
            end
        end
    end
    return best, best_age
end

-- A kept beacon: the pickup the game spawned for its end is taken back once
-- the beacon is still there PICKUP_AGE_S after it (the game's destroy would
-- have come by then: the hold took). Only a pickup no older than the death
-- (t0): one lying there before is someone's item. The beacon gone instead:
-- the hold did not take, the game ended it - its pickup stays.
local function take_back(key, short, at, started, wave, tries, t0)
    ue.delay("horde-kept", POLL_MS, function()
        local b = find_beacon(key)
        if not b then
            held[key], deferred[key] = nil, nil
            M.stats.hold_lost = M.stats.hold_lost + 1
            log.warn("ai: horde: %s: the game removed the beacon after all (the hold did not take): its pickup stays%s",
                short, started and ", the horde is over" or "")
            if started then relay_at(at, "over", wave, "bound") end
            return
        end
        -- spawned at the death: game time runs no faster than the clock
        local p, age = newest_pickup(at, os.clock() - t0 + PICKUP_SLACK_S)
        if p and age >= PICKUP_AGE_S then
            if pcall(function() p:K2_DestroyActor() end) then
                M.stats.taken = M.stats.taken + 1
                log.info("ai: horde: %s stays: the pickup the game spawned for its end was taken back", short)
            else
                log.warn("ai: horde: %s stays, but taking back the game's pickup failed", short)
            end
            return
        end
        if tries <= 1 then
            log.info("ai: horde: %s stays; no new pickup found next to it", short)
            return
        end
        take_back(key, short, at, started, wave, tries - 1, t0)
    end)
end

-- Ends held beacon `b` the game's way: its own Event_SpawnBeacon (the
-- pickup) and the destroy (the game's own is held).
local function end_horde(b, why, all)
    local key, short = ue.name(b), ue.short(b)
    local started = ue.prop(b, "HordeStarted?") == true
    local wave = wave_of(b)
    local at = ue.location(b)
    ending[key] = true
    local ok = ue.call(b, "Event_SpawnBeacon")
    ending[key] = nil
    deferred[key], pending[key] = nil, nil
    destroy_later(key, short)
    M.stats.ended = M.stats.ended + 1
    local n = 0
    if started then
        M.stats.over = M.stats.over + 1
        n = relay_at(at, "over", wave, all and "all" or "bound")
        if all then log.say("horde_over_all", "info", 5) end
    end
    log.info("ai: horde: %s: %s: it turns back into its pickup%s%s (%d client(s) told)", short, why,
        started and ", the horde is over" or " (idle)", ok and "" or " (Event_SpawnBeacon failed: removed only)", n)
end

-- Every HOLD_CHECK_S (host): beacons held while a client is connected and
-- ai_horde_continue is on; records of beacons gone forgotten; deferred ends
-- once every player is dead (or the setting was turned off).
local function hold_tick(now)
    local want = core.S.role == "host" and continue_on() and coop_now()
    if not want and next(held) == nil then
        dead_since = nil
        return
    end
    local here = beacons_here()
    if not here then return end
    if want then
        for key, b in pairs(here) do
            if not held[key] then hold(b) end
        end
    end
    for key in pairs(held) do if not here[key] then held[key] = nil end end
    for key in pairs(deferred) do if not here[key] then deferred[key] = nil end end
    for key in pairs(closing) do if not here[key] then closing[key] = nil end end
    if next(held) == nil then
        dead_since = nil
        return
    end
    if not continue_on() then
        for key in pairs(deferred) do
            local b = here[key]
            if b and not closing[key] then end_horde(b, "ai_horde_continue was turned off", false) end
        end
    end
    if alive_count() > 0 then
        dead_since = nil
        return
    end
    dead_since = dead_since or now
    if now - dead_since < ALL_DEAD_S then return end
    dead_since = nil
    for key, b in pairs(here) do
        if held[key] and not closing[key] and (deferred[key] or ue.prop(b, "HordeStarted?") == true) then
            end_horde(b, "every player is dead", true)
        end
    end
end

-- Event_StartHorde, post (both roles): started or stopped (diagnostics; the client's music)
local function on_start(c)
    local b = ue.param(c)
    if not ue.valid(b) then return end
    local on = ue.prop(b, "HordeStarted?") == true
    if on then M.stats.started = M.stats.started + 1 else M.stats.stopped = M.stats.stopped + 1 end
    local own = ue.role(b) == ue.ROLE_AUTHORITY
    log.info("ai: horde: beacon %s %s (%s)", ue.short(b), on and "started: countdown 30 s" or "stopped",
        own and "this machine's beacon" or "the host's beacon, this machine's copy runs its own countdown")
    if own and on and core.S.role == "host" and continue_on() and coop_now() then hold(b) end
    if own or not on or core.S.role ~= "client" then return end
    -- client: the host's horde music here too (Initialise is a server RPC)
    local comp = ue.prop(b, "MusicLayeringComponent")
    if not ue.valid(comp) or ue.valid(ue.prop(comp, "CurrentTrack")) then return end
    local ok, err = pcall(function() comp:ExecuteUbergraph_MusicLayeringComponent(INIT_ENTRY) end)
    if ok then
        M.stats.music = M.stats.music + 1
        log.info("ai: horde: the horde music plays here too (its start never reaches the host from a client)")
    else
        log.err_throttled("ai.horde.music", "ai: horde: music: %s", tostring(err))
    end
end

-- Event_NextWave, post (host): wave N begins (the clients' own copies show wave 1)
local function on_next_wave(c)
    local b = ue.param(c)
    if not ue.valid(b) or ue.role(b) ~= ue.ROLE_AUTHORITY or ue.prop(b, "HordeStarted?") ~= true then return end
    local wave = wave_of(b)
    M.stats.waves = M.stats.waves + 1
    local n = wave >= 2 and relay(b, "wave", wave) or 0
    log.info("ai: horde: %s wave %d begins (%d client(s) told)", ue.short(b), wave, n)
end

-- EnemyDefeatedCheck(All Defeated?), post (host; every 5 s during a wave)
local function on_check(c, all_p)
    if ue.param(all_p) ~= true then return end
    local b = ue.param(c)
    if not ue.valid(b) or ue.role(b) ~= ue.ROLE_AUTHORITY then return end
    pending[ue.name(b)] = { wave = wave_of(b), loc = ue.location(b), t = os.clock(), short = ue.short(b) }
end

-- FinalWaveDefeated?, post (host): right after its check in the same call
local function on_final(c)
    local b = ue.param(c)
    if not ue.valid(b) or ue.role(b) ~= ue.ROLE_AUTHORITY then return end
    pending[ue.name(b)] = nil
    deferred[ue.name(b)] = nil
    M.stats.final = M.stats.final + 1
    local n = relay(b, "final", wave_of(b))
    log.info("ai: horde: %s final wave defeated (%d client(s) told)", ue.short(b), n)
end

-- Event_SpawnBeacon, post, the host's beacon: the player it is bound to died.
-- Runs with the feature off too (a held beacon still needs its destroy).
local function host_beacon_dead(b)
    local key, short = ue.name(b), ue.short(b)
    if ending[key] or closing[key] then return end   -- this module's own end_horde call / already ending
    pending[key] = nil
    local started = ue.prop(b, "HordeStarted?") == true
    if not core.on("horde") then
        if held[key] then
            deferred[key] = nil
            destroy_later(key, short)
        end
        return
    end
    local wave = wave_of(b)
    local alive = alive_count()
    if held[key] and continue_on() and alive > 0 then
        deferred[key] = deferred[key] or { short = short, t = os.clock() }
        M.stats.kept = M.stats.kept + 1
        take_back(key, short, ue.location(b), started, wave, POLL_N, os.clock())
        local n = 0
        if started then
            n = relay(b, "kept", wave)
            log.say("horde_kept", "info", 5)
        end
        log.info("ai: horde: %s: the player the game ties it to died; %d player(s) still alive: the beacon stays%s"
            .. " (%d client(s) told)", short, alive, started and string.format(", its horde goes on (wave %d)", wave)
            or " (idle)", n)
        return
    end
    deferred[key] = nil
    local held_now = held[key] == true
    if held_now then destroy_later(key, short) end
    local why = (alive == 0 and "no player is alive")
        or (not continue_on() and "ai_horde_continue is off")
        or "it was not held for co-op (no client connected since it appeared)"
    if not started then
        log.info("ai: horde: the player the game ties idle beacon %s to died (%s): it turns back into its pickup"
            .. " (no horde: no client told)", short, why)
        return
    end
    M.stats.over = M.stats.over + 1
    local n = relay(b, "over", wave, alive == 0 and "all" or "bound")
    -- co-op (held): the host is told as well; the game's own end says nothing
    if held_now and alive == 0 then log.say("horde_over_all", "info", 5) end
    log.info("ai: horde: the player the game ties %s to died (%s): it turns back into its pickup, the horde is over"
        .. " (%d client(s) told)", short, why, n)
end

-- ctx.beacon_scope (host; sdc_world's "beacon" scope kind, for every player-0
-- call of a horde beacon while a client is connected): a running horde whose
-- presser (CurrentActor) has no living character - dead, its body unpossessed
-- - gets the living player nearest to the beacon as player 0: a remote one ->
-- its controller, the host -> false; nil (sdc_world's build rule: the
-- presser) otherwise. The new wave's SetBB_LockOnTarget (@2478-2605) runs to
-- that player, not to (0, 0, 0). Not started (its death binding 2 s after
-- BeginPlay, @918): nil, as before.
local function beacon_scope(wco)
    if core.S.role ~= "host" or not core.on("horde") or not continue_on() then return nil end
    if ue.prop(wco, "HordeStarted?") ~= true then return nil end
    local cur = ue.prop(wco, "CurrentActor")
    if ue.valid(cur) and ue.valid(ue.prop(cur, "Controller")) and not ctx.is_dead_player(cur) then return nil end
    local e = ctx.nearest_live_player(ue.location(wco))
    if not e then return nil end
    local key, who = ue.name(wco), e.remote and ue.short(e.pc) or "the host"
    if aimed[key] ~= who then
        aimed[key] = who
        log.info("ai: horde: %s: the player who started it has no living character: its new zombies run to %s (the"
            .. " living player nearest to the beacon)", ue.short(wco), who)
    end
    if e.remote then return e.pc end
    return false
end

-- Event_SpawnBeacon, post: the player a beacon is bound to died (host: see
-- host_beacon_dead; client: its copy spawned a local pickup)
local function on_spawn_beacon(c)
    local b = ue.param(c)
    if not ue.valid(b) then return end
    if ue.role(b) == ue.ROLE_AUTHORITY then
        if core.S.role == "host" then host_beacon_dead(b) end
        return
    end
    if not core.on("horde") then return end
    local at = ue.location(b)
    local out = at and ue.actors_of(PICKUP)
    local removed = 0
    if type(out) == "table" then
        for i = 1, #out do
            local p = ue.elem(out[i])
            local l = ue.valid(p) and ue.role(p) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(p) and ue.location(p)
            if l then
                local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
                if dx * dx + dy * dy + dz * dz <= PICKUP_CM * PICKUP_CM and pcall(function() p:K2_DestroyActor() end) then
                    removed = removed + 1
                end
            end
        end
    end
    M.stats.pickups = M.stats.pickups + removed
    log.info("ai: horde: this player died near the host's beacon %s: %d local beacon pickup(s) removed (the host's"
        .. " beacon stays)", ue.short(b), removed)
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function beacon_at(loc)
    local out = ue.actors_of(BEACON)
    if type(out) ~= "table" then return nil end
    for i = 1, #out do
        local b = ue.elem(out[i])
        local l = ue.valid(b) and ue.location(b)
        if l then
            local dx, dy, dz = l.X - loc.X, l.Y - loc.Y, l.Z - loc.Z
            if dx * dx + dy * dy + dz * dz <= FIND_CM * FIND_CM then return b end
        end
    end
    return nil
end

-- HORDE|kind|wave|x|y|z[|why]
local function on_horde(f)
    if core.S.role ~= "client" then return end
    local kind, wave = f[1], tonumber(f[2]) or 0
    local loc = { X = tonumber(f[3]) or 0, Y = tonumber(f[4]) or 0, Z = tonumber(f[5]) or 0 }
    if kind == "wave" then
        log.say("horde_wave", "info", 4, wave)
        local b = beacon_at(loc)
        local comp = b and ue.prop(b, "MusicLayeringComponent")
        if ue.valid(comp) and ue.valid(ue.prop(comp, "CurrentTrack")) and pcall(function() comp:NextTrack() end) then
            M.stats.tracks = M.stats.tracks + 1
        end
    elseif kind == "done" then
        log.say("horde_done", "info", 4, wave)
    elseif kind == "final" then
        log.say("horde_final", "info", 4)
    elseif kind == "kept" then
        log.say("horde_kept", "info", 5)
    elseif kind == "over" then
        log.say(f[6] == "all" and "horde_over_all" or "horde_over", "info", 5)
    else
        return
    end
    M.stats.notices = M.stats.notices + 1
    log.info("ai: horde: from the host: %s (wave %d)", tostring(kind), wave)
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function M.init(c)
    core = c
    ctx.beacon_scope = beacon_scope
    for _, role in ipairs({ "host", "client" }) do
        core.hook({ path = B .. "Event_StartHorde", kind = "bp", role = role, feature = "horde",
                    name = "horde.start." .. role, fn = on_start })
    end
    -- the host's entry runs with the feature off too: a held beacon still needs its destroy
    core.hook({ path = B .. "Event_SpawnBeacon", kind = "bp", role = "host", feature = "horde",
                name = "horde.dead.host", fn = on_spawn_beacon, always = true })
    core.hook({ path = B .. "Event_SpawnBeacon", kind = "bp", role = "client", feature = "horde",
                name = "horde.dead.client", fn = on_spawn_beacon })
    core.hook({ path = B .. "Event_NextWave", kind = "bp", role = "host", feature = "horde", name = "horde.wave",
                fn = on_next_wave })
    core.hook({ path = B .. "EnemyDefeatedCheck", kind = "bp", role = "host", feature = "horde", name = "horde.check",
                fn = on_check })
    core.hook({ path = B .. "FinalWaveDefeated?", kind = "bp", role = "host", feature = "horde", name = "horde.final",
                fn = on_final })
end

-- Host: a wave whose enemies are all dead and that was not the final one;
-- the co-op hold (hold_tick).
function M.host_tick(now)
    for key, p in pairs(pending) do
        if now - p.t >= 0.2 then
            pending[key] = nil
            M.stats.done = M.stats.done + 1
            local n = p.loc and send_near(p.loc, "done", tostring(p.wave), f0(p.loc.X), f0(p.loc.Y), f0(p.loc.Z)) or 0
            log.info("ai: horde: %s wave %d completed (%d client(s) told)", p.short, p.wave, n)
        end
    end
    if now - hold_at >= HOLD_CHECK_S then
        hold_at = now
        local ok, err = pcall(hold_tick, now)
        if not ok then log.err_throttled("ai.horde.holdtick", "ai: horde: hold tick: %s", tostring(err)) end
    end
end

function M.on_message(kind, f)
    if kind == "HORDE" then on_horde(f) end
end

-- Turned off: the ends deferred so far come now (the game would have ended
-- those beacons already); held beacons keep their hold (it cannot be undone):
-- their destroy comes from the host's Event_SpawnBeacon entry, which runs
-- with the feature off too.
function M.off()
    if next(deferred) == nil then return end
    local here = beacons_here()
    if not here then return end
    for key in pairs(deferred) do
        local b = here[key]
        if b and not closing[key] then end_horde(b, "ai_horde_beacon was turned off", false) end
    end
    deferred = {}
end

-- A new world: its beacons are new (nothing held); a role change: the same.
function M.reset()
    pending, held, deferred, ending, closing, aimed = {}, {}, {}, {}, {}, {}
    hold_at, dead_since = -1e9, nil
end

function M.status_line()
    local s = M.stats
    local nh, nd = 0, 0
    for _ in pairs(held) do nh = nh + 1 end
    for _ in pairs(deferred) do nd = nd + 1 end
    return string.format("ai: horde started=%d stopped=%d waves=%d done=%d final=%d over=%d sent=%d | co-op hold:"
        .. " held now=%d (all %d, failed %d) kept after a death=%d (deferred now %d) pickups taken back=%d hold lost=%d"
        .. " ended by us=%d | client notices=%d music=%d tracks=%d pickups removed=%d", s.started, s.stopped, s.waves,
        s.done, s.final, s.over, s.sent, nh, s.held, s.hold_failed, s.kept, nd, s.taken, s.hold_lost, s.ended,
        s.notices, s.music, s.tracks, s.pickups)
end

M._t = { on_start = on_start, on_next_wave = on_next_wave, on_check = on_check, on_final = on_final,
         on_spawn_beacon = on_spawn_beacon, on_horde = on_horde, hold = hold, hold_tick = hold_tick,
         beacon_scope = beacon_scope,
         held = function() return held end, deferred = function() return deferred end }

return M
