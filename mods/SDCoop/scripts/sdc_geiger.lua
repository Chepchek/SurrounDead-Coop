-- SDCoop: every player hears only their own dosimeter (Geiger counter), a
-- client's radiation stops building up when it leaves a radiation zone, and
-- after a client's respawn the radiation zones find its new character again
-- (radiation and the respirator filter work after a death).
--
-- RadiationComponent_C (one per BP_PlayerCharacter):
--   * DecreaseRadiation(amount) @0-853 lowers CurrentRadiation (replicated)
--     and plays the dosimeter: Geiger valid -> UpdateGeiger() + volume
--     (Max - Current) / 100; otherwise, with the CVar Character.GeigerSound
--     and Current <= 99: SpawnSound2D(self, Geiger_Counter_Sound_Cue, ...) ->
--     Geiger -> UpdateGeiger(). The cue loops (SoundNodeLooping).
--   * UpdateGeiger is a Client RPC [Net NetClient], @15: DoOnce FadeIn 1 s,
--     RetriggerableDelay 6-8 s -> StopGeiger (FadeOut, destroy, Geiger =
--     None). StopGeiger also runs from IncreaseRadiation @1314 (pills) and
--     BP_PlayerCharacter.AfterDeath @631.
--   * DecreaseRadiation runs where the radiation is applied: on the server.
--     RadiationTimer (every 0.04-0.2 s, set by UpdateRadiation, a Server RPC
--     that BP_RadiationArea_Sphere calls on the entering player's machine) and
--     GameFunctionLibrary.ApplyRadiationDamage @657 (radiated zombies' hits
--     and the UltraRadiated aura @14629, boss RadiationDamage).
-- Single player: server = owner, all of it on one machine. In co-op, for a
-- client's character:
--   * the HOST spawned the 2D sound (the host's ears), and the UpdateGeiger
--     that would have faded it out went to the client (Client RPC), where
--     Geiger is None: the host heard the client's looping dosimeter until
--     that client died or took anti-radiation pills (gaptrace, every co-op
--     session: host, remote, SpawnSound2D, RadiationComponent_C,
--     Geiger_Counter_Sound_Cue);
--   * the client never heard its own dosimeter;
--   * leaving a zone calls StopRadiation, a plain function, on the client
--     only (BP_RadiationArea_Sphere @2133): the host's RadiationTimer went on
--     lowering the client's radiation after it left (sickness, 15 damage
--     every 5 s).
-- Here, while others are connected:
--   both:   SpawnSound2D (pre) from the RadiationComponent of ANOTHER
--           player's character -> Sound = None: no dosimeter of another
--           player plays on this machine; DecreaseRadiation (post) and a 1 s
--           sweep stop one that already plays (spawned before this module).
--   client: own CurrentRadiation going down -> the dosimeter here, as
--           DecreaseRadiation does it: SpawnSound2D on the own component ->
--           Geiger -> UpdateGeiger(), which runs locally on the owning
--           client (FadeIn, 6-8 s, StopGeiger); Geiger already playing ->
--           its volume. Going up (pills), own character dead or replaced ->
--           StopGeiger(). Own InRadArea true -> false (left the zone) ->
--           RADZ|0|1, then RADZ|0|0 every 5 s for 30 s.
--   host:   RADZ|0 from a client -> StopRadiation() on the host's copy of its
--           component (as the zone does in single player) when its
--           RadiationTimer runs; a repeat (0) is ignored within 3 s of that
--           component's last UpdateRadiation (a newer zone entry).
-- Config: geiger_own_only, radiation_exit_sync.
--
-- Radiation zones after a client's respawn (config radiation_exit_sync).
-- BP_RadiationArea_Sphere (work\re\pseudo\BP_RadiationArea_Sphere.txt) runs on
-- every machine and reacts only to GetPlayerCharacter(0) there:
--   * BeginOverlap @3571 / EndOverlap @3732 of its Capsule, and a 0.2 s poll
--     Event_Overlap @2248 (GetOverlappingActors(BP_PlayerCharacter) ==
--     GetPlayerCharacter(0)), armed 5 s after BeginPlay @474 and cleared once
--     it found the player @951;
--   * Event_EnteredRadZone @2299 is a DoOnce (reset only by
--     Event_ExitedRadZone @1930): the zone's HUD text, then the own
--     RadiationComponent's UpdateRadiation (Server RPC: the host sets
--     RadiationTimer, which uses the respirator filter - RadiationTimer @120
--     UseFilter -> BP_JigComponent.ServerFuncUpdateDurabilityByUID - and
--     lowers CurrentRadiation) + CheckStats; Event_ExitedRadZone @2238 is the
--     mirror DoOnce (HUD text, StopRadiation, reopens the entry);
--   * Event_Respawn @3466 arms the poll again; the zone binds it to
--     GameInstance.PlayerRespawned @80, which only SD_GameInstance.
--     Survival_Respawn / Survival_SuicideRespawn broadcast (@649/@1389/@635):
--     the respawn RPC's body, on the host.
-- Single player: AfterDeath runs MC_PlayerDead (Capsule collision off @77886)
-- before UnPossess @1387, so the zone's EndOverlap still sees the player: the
-- exit runs, then PlayerRespawned makes every zone look for the new character.
-- A client: its new character is spawned by the host and appears here (inside
-- the zone, BeginOverlap) before it is possessed - ignored; PlayerRespawned
-- never comes; and the exit at death ran only if MC_PlayerDead (unreliable
-- multicast) arrived before the unpossess. So after a respawn no zone sent
-- UpdateRadiation: no RadiationTimer on the host, the filter was not used and
-- no radiation built up, until the player left the zone and came back - never
-- for a zone the old character died in (its entry DoOnce stayed closed).
-- 0.7.1 session 2026-11-11: the client in a zone since 18:59:56 (no exit on
-- the client), died 19:05:01 at -94989,-46483, respawned at the host
-- (-99540,-40544) inside the same area: no filter use after it.
-- Fix (client): post-hooks on Event_EnteredRadZone / Event_ExitedRadZone keep
-- each zone's DoOnce state here. When the own character is replaced (a
-- respawn), every zone the old one is still "in" gets the game's own
-- Event_ExitedRadZone (what the death does in single player), then every zone
-- gets Event_Respawn (what PlayerRespawned does): the zone's own poll finds
-- the new character and runs its own entry -> UpdateRadiation. A zone with no
-- known state (its hooks came after the old character appeared) counts as
-- "in" when that character's last living position, in a zone, was inside its
-- capsule. Host: other players' zone entries (UpdateRadiation) and filter use
-- (UseFilter) are logged (first use per character, then every 60 s).
--
-- This module also drives sdc_hudmods (install / tick / reset / status line):
-- the HUD's respirator / flashlight / NVG icons on a client's screen; the
-- UseFilter hook below hands it the filter's durability.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local hud = require("sdc_hudmods")   -- equipment status icons on a client's HUD

local M = {
    stats = {
        muted = 0, stopped = 0, swept = 0,              -- other players' dosimeters
        played = 0, faded = 0, failed = 0,              -- own dosimeter (client)
        radz_sent = 0, radz_stops = 0, radz_idle = 0, radz_soon = 0,
        zone_rechecks = 0, zone_resets = 0, zone_entries = 0, zone_blocked = 0,   -- client: zones after a respawn
        host_entries = 0, filter_uses = 0,                                       -- host: other players
    },
}

local RAD_CLASS = "RadiationComponent_C"
local RAD_FN = "/Game/Blueprints/Components/RadiationComponent.RadiationComponent_C:"
local SPAWN2D_FN = "/Script/Engine.GameplayStatics:SpawnSound2D"
local CUE_PATH = "/Game/Audio/Geiger_Counter_Sound_Cue.Geiger_Counter_Sound_Cue"
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"
local GEIGER_CVAR = "Character.GeigerSound"
local PLAYER_CLASS = "BP_PlayerCharacter_C"
local ZONE_CLASS = "BP_RadiationArea_Sphere_C"
local ZONE_FN = "/Game/Blueprints/Zones/BP_RadiationArea_Sphere.BP_RadiationArea_Sphere_C:"

local HOOK_RETRY_S = 2     -- s: BP hooks wait for RadiationComponent_C
local OWNER_TTL = 2        -- s: "this component is another player's" cache
local SWEEP_S = 1          -- s: sweep of other players' dosimeters
local RADZ_EVERY = 5       -- s: client repeats "left the zone" ...
local RADZ_FOR = 30        -- s: ... this long after leaving
local RADZ_GUARD = 3       -- s: host ignores a repeat this soon after UpdateRadiation
local ZONE_MARGIN = 100    -- cm: the character's own capsule around its position
local FILTER_SUMMARY_S = 60  -- s: host summary of another player's filter use
local FILTER_IDLE_S = 30   -- s: no use this long = the next use is a new zone visit
local EPS = 1e-4

local S
local st = {
    active = false, role = nil,
    hooks = {}, hook_at = -100,
    owner_cache = {},      -- [component address] = { other = bool, t = clock }
    updated_at = {},       -- host: [component address] = clock of its last UpdateRadiation
    sweep_at = 0, prune_at = 0,
    -- client: own character (address only), its last radiation, zone state
    pawn = nil, last_cur = nil, dead = false,
    inzone = false, left_at = nil, radz_at = -100,
    -- client: radiation zones (addresses only)
    zones = {},            -- [zone address] = the character address (or true) its entry ran for, no exit since / false
    zone_hooked_at = nil,  -- clock when both zone hooks were in
    pawn_since = nil, pawn_name = nil,
    alive_loc = nil, alive_inzone = false,   -- own character's last living position in a zone
    lost = nil,            -- the previous own character: { name, loc, inzone, hooked }
    respawn_at = nil,      -- clock of the last re-check after a respawn
    -- host: other players' zone entries and filter use
    filt = {},             -- [component address] = { n, t, used }
    cue = nil, cue_missing = false,
    logged = {},
}

local function clock() return os.clock() end

local function own_only() return cfg.get("geiger_own_only") ~= false end
local function exit_sync() return cfg.get("radiation_exit_sync") ~= false end

local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

local function once(key, fmt, ...)
    if st.logged[key] then return end
    st.logged[key] = true
    log.info(fmt, ...)
end

local function is_player(o)
    return ue.valid(o) and ue.class_name(o):find("PlayerCharacter", 1, true) ~= nil
end

local function locally_controlled(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

local function owner_name(comp)
    return ue.short(ue.try(function() return comp:GetOwner() end))
end

-- Is this RadiationComponent another player's (its character not controlled
-- on this machine: a remote player, or a body nobody controls)?
local function others(comp)
    local a = addr(comp)
    if not a then return false end
    local now = clock()
    local c = st.owner_cache[a]
    if c and now - c.t < OWNER_TTL then return c.other end
    local owner = ue.try(function() return comp:GetOwner() end)
    local other = is_player(owner) and not locally_controlled(owner)
    st.owner_cache[a] = { other = other, t = now }
    return other
end

local function get_bool_cvar(name)
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu then
        local ok, v = pcall(function() return cu:GetBoolCVar(FName(name)) end)
        if ok and type(v) == "boolean" then return v end
    end
    local ksl = ue.ksl()
    if ksl then
        local ok, v = pcall(function() return ksl:GetConsoleVariableBoolValue(name) end)
        if ok and type(v) == "boolean" then return v end
    end
    return nil
end

-- The cue is a hard reference of RadiationComponent_C: in memory with it.
local function cue_obj()
    if ue.valid(st.cue) then return st.cue end
    st.cue = ue.find_object(CUE_PATH)
    if st.cue then return st.cue end
    if st.cue_missing then return nil end
    local ok, loaded = ue.load_asset(CUE_PATH, "geiger")
    if ok and ue.valid(loaded) then
        st.cue = loaded
        return loaded
    end
    st.cue_missing = true
    log.warn("geiger: %s not found; the own dosimeter cannot play here", CUE_PATH)
    return nil
end

-- ---------------------------------------------------------------------------
-- Other players' dosimeters (both roles)
-- ---------------------------------------------------------------------------

-- GameplayStatics.SpawnSound2D (pre): (context, WorldContextObject, Sound, ...)
local function on_spawn2d(_, wco_p, sound_p)
    if not st.active or not own_only() then return end
    local wco = wco_p and wco_p:get()
    if not ue.valid(wco) or ue.class_name(wco) ~= RAD_CLASS then return end
    if not others(wco) then return end
    if not pcall(function() sound_p:set(nil) end) then
        once("mute-fail", "geiger: cannot clear SpawnSound2D's Sound; other players' dosimeters are stopped right after they start")
        return
    end
    M.stats.muted = M.stats.muted + 1
    if M.stats.muted <= 3 then
        log.info("geiger: dosimeter of %s not played here (that player hears it on its own machine)", owner_name(wco))
    end
end

-- RadiationComponent_C.DecreaseRadiation (post): one that still started here
local function on_decrease(c)
    if not st.active or not own_only() then return end
    local comp = c and c:get()
    if not ue.valid(comp) or not others(comp) then return end
    local g = ue.prop(comp, "Geiger")
    if not ue.valid(g) then return end
    -- native Stop (no Blueprint from inside the hook); bAutoDestroy frees it
    if pcall(function() g:Stop() end) then
        M.stats.stopped = M.stats.stopped + 1
        if M.stats.stopped <= 3 then
            log.info("geiger: dosimeter of %s stopped here right after it started", owner_name(comp))
        end
    end
end

local function param_value(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

-- "BP_PlayerCharacter_C_123 (Name)" of a RadiationComponent's character (host)
local function who(comp)
    local pawn = ue.try(function() return comp:GetOwner() end)
    local pc = ue.valid(pawn) and ue.prop(pawn, "Controller") or nil
    local r = ue.valid(pc) and S and S.remote and S.remote[ue.name(pc)] or nil
    return string.format("%s (%s)", ue.short(pawn), r and tostring(r.name) or "?")
end

local function dur_text(d)
    if type(d) == "number" then return string.format("%.2f", d) end
    return tostring(d)
end

-- RadiationComponent_C.UpdateRadiation(Time) (post; on the host: a zone
-- entry, the Server RPC the player's own zone sends from its machine)
local function on_update_radiation(c, t)
    if not S or S.role ~= "host" then return end
    local comp = c and c:get()
    local a = ue.valid(comp) and addr(comp)
    if not a then return end
    st.updated_at[a] = clock()
    if not others(comp) then return end
    M.stats.host_entries = M.stats.host_entries + 1
    local period = tonumber(param_value(t))
    log.info("geiger: %s entered a radiation zone on its machine (UpdateRadiation): its radiation timer runs on the host every %s s and uses the respirator filter there",
        who(comp), period and string.format("%.3f", period) or "?")
end

-- RadiationComponent_C.UseFilter(MinusDur, NewDur, Successful?) (post; the
-- host's RadiationTimer for another player's character)
local function on_use_filter(c, _, newdur_p, ok_p)
    if not S or S.role ~= "host" then return end
    local comp = c and c:get()
    if not ue.valid(comp) or not others(comp) then return end
    local a = addr(comp)
    if not a then return end
    M.stats.filter_uses = M.stats.filter_uses + 1
    local now = clock()
    local dur, okv = tonumber(param_value(newdur_p)), param_value(ok_p)
    -- the percent that player's own HUD shows (sdc_hudmods -> RESPUI)
    local okh, eh = pcall(hud.host_filter_used, comp, a, dur)
    if not okh then log.err_throttled("geiger.hudmods", "geiger: hudmods filter use: %s", tostring(eh)) end
    local f = st.filt[a]
    if not f or now - f.used > FILTER_IDLE_S then
        st.filt[a] = { n = 0, t = now, used = now }
        log.info("geiger: %s's respirator filter used on the host (RadiationTimer -> UseFilter): durability %s, ok=%s",
            who(comp), dur_text(dur), tostring(okv))
        return
    end
    f.n, f.used = f.n + 1, now
    if now - f.t >= FILTER_SUMMARY_S then
        log.info("geiger: %s's respirator filter: used %d more time(s) in %.0f s on the host, durability now %s, ok=%s",
            who(comp), f.n, now - f.t, dur_text(dur), tostring(okv))
        f.n, f.t = 0, now
    end
end

-- "BP_RadiationArea_Sphere_C_3 'Name'"
local function zone_label(z)
    local n = ue.str(ue.prop(z, "Name"))
    if n ~= "" then return string.format("%s '%s'", ue.short(z), n) end
    return ue.short(z)
end

-- BP_RadiationArea_Sphere_C.Event_EnteredRadZone / Event_ExitedRadZone(Actor)
-- (post; where the zone ran it: for this machine's own character). The
-- zone's entry DoOnce is closed after an entry and reopened by an exit.
local function on_zone_event(c, a, entered)
    local zone = c and c:get()
    local za = ue.valid(zone) and addr(zone)
    if not za then return end
    local was = st.zones[za]          -- nil / false / the character its entry ran for
    local actor = param_value(a)
    local aa = ue.valid(actor) and addr(actor) or nil
    local closed = was ~= nil and was ~= false
    if not entered then
        st.zones[za] = false
    elseif not closed then
        st.zones[za] = aa or true
    end
    if not S or S.role ~= "client" then return end
    local name = ue.valid(actor) and ue.short(actor) or "<none>"
    if not entered then
        log.debug("geiger: radiation zone %s: its exit ran here (%s)", zone_label(zone), name)
        return
    end
    if closed then
        -- the DoOnce was still closed: nothing went to the host. The same
        -- character again (its poll after its BeginOverlap) is harmless.
        if aa and was == aa then
            log.debug("geiger: radiation zone %s: second entry call for %s (already in)", zone_label(zone), name)
            return
        end
        M.stats.zone_blocked = M.stats.zone_blocked + 1
        log.info("geiger: radiation zone %s ignored the entry of %s (its entry ran for an earlier character, no exit since): no radiation timer on the host",
            zone_label(zone), name)
        return
    end
    M.stats.zone_entries = M.stats.zone_entries + 1
    local since = st.respawn_at and clock() - st.respawn_at or nil
    log.info("geiger: own character %s entered radiation zone %s%s -> UpdateRadiation to the host (its radiation timer and the respirator filter run there)",
        name, zone_label(zone), since and string.format(" (%.1f s after the respawn re-check)", since) or "")
end

local function zone_hook(fn, entered)
    return pcall(RegisterHook, ZONE_FN .. fn, function(c, a)
        local okc, e = pcall(on_zone_event, c, a, entered)
        if not okc then log.err_throttled("geiger.zone", "geiger: %s hook: %s", fn, tostring(e)) end
    end)
end

local function try_hooks(now)
    local h = st.hooks
    if h.spawn and h.decrease and h.update and h.usefilter and h.zone_in and h.zone_out then return end
    if now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    if not st.hooks.spawn then
        local ok, err = pcall(RegisterHook, SPAWN2D_FN, function(ctx, wco_p, sound_p)
            local okc, e = pcall(on_spawn2d, ctx, wco_p, sound_p)
            if not okc then log.err_throttled("geiger.spawn", "geiger: SpawnSound2D hook: %s", tostring(e)) end
        end, function() end)
        st.hooks.spawn = ok
        log.info("geiger: SpawnSound2D hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    -- the Blueprint hooks fail quietly until RadiationComponent_C is loaded
    if not st.hooks.decrease then
        st.hooks.decrease = pcall(RegisterHook, RAD_FN .. "DecreaseRadiation", function(c)
            local okc, e = pcall(on_decrease, c)
            if not okc then log.err_throttled("geiger.decrease", "geiger: DecreaseRadiation hook: %s", tostring(e)) end
        end)
        if st.hooks.decrease then log.info("geiger: DecreaseRadiation hook ok") end
    end
    if not st.hooks.update then
        st.hooks.update = pcall(RegisterHook, RAD_FN .. "UpdateRadiation", function(c, t)
            local okc, e = pcall(on_update_radiation, c, t)
            if not okc then log.err_throttled("geiger.update", "geiger: UpdateRadiation hook: %s", tostring(e)) end
        end)
        if st.hooks.update then log.info("geiger: UpdateRadiation hook ok") end
    end
    if not st.hooks.usefilter then
        st.hooks.usefilter = pcall(RegisterHook, RAD_FN .. "UseFilter", function(c, minus, newdur, okp)
            local okc, e = pcall(on_use_filter, c, minus, newdur, okp)
            if not okc then log.err_throttled("geiger.usefilter", "geiger: UseFilter hook: %s", tostring(e)) end
        end)
        if st.hooks.usefilter then log.info("geiger: UseFilter hook ok") end
    end
    -- BP_RadiationArea_Sphere_C is loaded with the map
    if not st.hooks.zone_in then st.hooks.zone_in = zone_hook("Event_EnteredRadZone", true) end
    if not st.hooks.zone_out then st.hooks.zone_out = zone_hook("Event_ExitedRadZone", false) end
    if st.hooks.zone_in and st.hooks.zone_out and not st.zone_hooked_at then
        st.zone_hooked_at = now
        log.info("geiger: radiation zone hooks ok (Event_EnteredRadZone / Event_ExitedRadZone)")
    end
end

-- Host: other players' dosimeters that play here anyway (the one started
-- before the hooks: it would loop until that player's death).
local function sweep(now)
    if now - st.sweep_at < SWEEP_S then return end
    st.sweep_at = now
    if not own_only() then return end
    for _, pc in ipairs(S.remote_pcs or {}) do
        local pawn = ue.pawn_of(pc)
        local comp = pawn and ue.prop(pawn, "RadiationComponent")
        if ue.valid(comp) and ue.valid(ue.prop(comp, "Geiger")) then
            if pcall(function() comp:StopGeiger() end) then
                M.stats.swept = M.stats.swept + 1
                if M.stats.swept <= 5 then
                    log.info("geiger: dosimeter of %s was playing here; stopped (StopGeiger)", ue.short(pawn))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: a client left a radiation zone
-- ---------------------------------------------------------------------------

-- true / false / nil (cannot tell)
local function timer_running(comp)
    local ksl = ue.ksl()
    if not ksl then return nil end
    local ok, v = pcall(function() return ksl:K2_IsTimerActive(comp, "RadiationTimer") end)
    if ok and type(v) == "boolean" then return v end
    once("timer-api", "geiger: K2_IsTimerActive unavailable (%s); radiation timers stop on zone exits only", tostring(v))
    return nil
end

-- RADZ|0|edge (client -> host): the client's own character is outside every
-- radiation zone on its machine; edge 1 = it just left one.
local function on_radz(f, pc)
    if not S or S.role ~= "host" or not exit_sync() then return end
    if f[1] ~= "0" then return end
    local edge = f[2] == "1"
    local pawn = ue.valid(pc) and ue.pawn_of(pc) or nil
    local comp = pawn and ue.prop(pawn, "RadiationComponent")
    if not ue.valid(comp) then return end
    local a = addr(comp)
    local up = a and st.updated_at[a]
    if not edge and up and clock() - up < RADZ_GUARD then
        M.stats.radz_soon = M.stats.radz_soon + 1
        return
    end
    local running = timer_running(comp)
    if running == false or (running == nil and not edge) then
        M.stats.radz_idle = M.stats.radz_idle + 1
        return
    end
    if pcall(function() comp:StopRadiation() end) then
        M.stats.radz_stops = M.stats.radz_stops + 1
        log.info("geiger: %s left the radiation zone on its machine; its radiation timer on the host stopped (%s)",
            ue.short(pawn), edge and "zone exit" or "repeat")
    else
        log.err_throttled("geiger.stoprad", "geiger: StopRadiation on %s failed", ue.short(pawn))
    end
end

-- ---------------------------------------------------------------------------
-- Client: own dosimeter and zone exits
-- ---------------------------------------------------------------------------

local function stop_own(comp, why)
    if not ue.valid(comp) or not ue.valid(ue.prop(comp, "Geiger")) then return end
    if pcall(function() comp:StopGeiger() end) then
        M.stats.faded = M.stats.faded + 1
        if M.stats.faded <= 3 then log.info("geiger: own dosimeter stopped (%s)", why) end
    end
end

-- DecreaseRadiation's dosimeter part @302-839, for the own component
local function own_dosimeter(comp, cur, max)
    local vol = (max - cur) / 100
    local g = ue.prop(comp, "Geiger")
    if ue.valid(g) then
        pcall(function() g:SetVolumeMultiplier(vol) end)
        return
    end
    if cur > 99 or get_bool_cvar(GEIGER_CVAR) == false then return end
    local cue, gps = cue_obj(), ue.gameplay_statics()
    if not cue or not gps then return end
    local ok, snd = pcall(function() return gps:SpawnSound2D(comp, cue, vol, 1.0, 0.0, nil, false, true) end)
    if not ok or not ue.valid(snd) then
        M.stats.failed = M.stats.failed + 1
        log.err_throttled("geiger.own", "geiger: own dosimeter: SpawnSound2D failed (%s)", tostring(snd))
        return
    end
    if not ue.set_prop(comp, "Geiger", snd) then
        pcall(function() snd:Stop() end)
        M.stats.failed = M.stats.failed + 1
        log.err_throttled("geiger.own", "geiger: own dosimeter: cannot set RadiationComponent.Geiger")
        return
    end
    -- the game's Client RPC runs locally on the owning client: FadeIn, then
    -- StopGeiger after 6-8 s (DoOnce)
    local okU, err = pcall(function() comp:UpdateGeiger() end)
    if not okU then log.err_throttled("geiger.update-own", "geiger: UpdateGeiger: %s", tostring(err)) end
    M.stats.played = M.stats.played + 1
    if M.stats.played <= 3 then
        log.info("geiger: own dosimeter plays here (radiation %.1f of %.0f)", cur, max)
    end
end

-- The previous own character (dead / replaced): only touched while it still
-- exists.
local function stop_old(old)
    for _, p in ipairs(ue.find_all(PLAYER_CLASS)) do
        if addr(p) == old then
            stop_own(ue.prop(p, "RadiationComponent"), "own character replaced")
            return
        end
    end
end

-- Is `loc` (the character's position) inside the zone's capsule? Fallback
-- for a zone whose DoOnce state the hooks did not see.
local function zone_contains(z, loc)
    if not loc then return false end
    local cap = ue.prop(z, "Capsule")
    if not ue.valid(cap) then return false end
    local c = ue.try(function() return cap:K2_GetComponentLocation() end)
    local r = tonumber(ue.try(function() return cap:GetScaledCapsuleRadius() end))
    local h = tonumber(ue.try(function() return cap:GetScaledCapsuleHalfHeight() end))
    local cx, cy, cz = c and tonumber(ue.try(function() return c.X end)), c and tonumber(ue.try(function() return c.Y end)),
        c and tonumber(ue.try(function() return c.Z end))
    if not (r and h and cx and cy and cz) then return false end
    local dx, dy, dz = loc.X - cx, loc.Y - cy, loc.Z - cz
    local seg = math.max(h - r, 0)
    local ez = 0
    if dz > seg then ez = dz - seg elseif dz < -seg then ez = dz + seg end
    local m = r + ZONE_MARGIN
    return dx * dx + dy * dy + ez * ez <= m * m
end

-- The own character was replaced (respawn): what single player does at the
-- death (the zone's exit) and after the respawn (PlayerRespawned ->
-- Event_Respawn on every zone), with the game's own zone events.
local function zones_recheck(pawn, lost, now)
    local resets, polled, failed, names = 0, 0, 0, {}
    for _, z in ipairs(ue.find_all(ZONE_CLASS)) do
        if ue.valid(z) and not ue.short(z):find("^Default__") then
            local za = addr(z)
            local s = za and st.zones[za]
            local how = nil
            if s ~= nil and s ~= false then
                how = "entered, no exit seen"
            elseif s == nil and not lost.hooked and lost.inzone and zone_contains(z, lost.loc) then
                how = "last position inside"
            end
            if how then
                if pcall(function() z:Event_ExitedRadZone(pawn) end) then
                    resets = resets + 1
                    if za then st.zones[za] = false end
                    names[#names + 1] = string.format("%s (%s)", zone_label(z), how)
                else
                    failed = failed + 1
                end
            end
            if pcall(function() z:Event_Respawn() end) then polled = polled + 1 else failed = failed + 1 end
        end
    end
    st.respawn_at = now
    M.stats.zone_rechecks = M.stats.zone_rechecks + 1
    M.stats.zone_resets = M.stats.zone_resets + resets
    log.info("geiger: own character replaced (%s -> %s): %d radiation zone(s) look for it again (Event_Respawn, as the game's PlayerRespawned, which fires on the host only); entry reopened (Event_ExitedRadZone, the exit its death skipped here) in %d zone(s)%s%s",
        tostring(lost.name), ue.short(pawn), polled, resets,
        resets > 0 and (": " .. table.concat(names, ", ")) or "",
        failed > 0 and string.format("; %d call(s) failed", failed) or "")
end

local function send_radz(edge, now)
    st.radz_at = now
    if net.send_to_host("RADZ", "0", edge and "1" or "0") then
        M.stats.radz_sent = M.stats.radz_sent + 1
        if edge then log.info("geiger: own character left a radiation zone -> the host stops its radiation timer") end
    end
end

local function client_tick(now)
    local pawn = ue.local_pawn()
    if pawn and not is_player(pawn) then pawn = nil end
    local pa = pawn and addr(pawn) or nil
    if pa ~= st.pawn then
        -- dead and unpossessed, or respawned: AfterDeath's StopGeiger ran on
        -- the host's copy only
        if st.pawn then
            stop_old(st.pawn)
            st.lost = {
                name = st.pawn_name, loc = st.alive_loc, inzone = st.alive_inzone,
                -- the zone hooks saw every entry / exit of that character
                hooked = st.zone_hooked_at ~= nil and st.pawn_since ~= nil and st.zone_hooked_at <= st.pawn_since,
            }
        end
        st.pawn, st.last_cur, st.dead = pa, nil, false
        st.inzone, st.left_at = false, nil
        st.pawn_since, st.pawn_name = now, pawn and ue.short(pawn) or nil
        st.alive_loc, st.alive_inzone = nil, false
        if pawn and st.lost then
            local lost = st.lost
            st.lost = nil
            if exit_sync() then zones_recheck(pawn, lost, now) end
        end
    end
    if not pawn then return end
    local comp = ue.prop(pawn, "RadiationComponent")
    if not ue.valid(comp) then return end

    -- the last living position in a zone (zones_recheck's fallback)
    local inzone = ue.prop(comp, "InRadArea") == true
    local dead = ue.prop(pawn, "PlayerDead?") == true
    if not dead then
        st.alive_inzone = inzone
        if inzone then st.alive_loc = ue.location(pawn) or st.alive_loc end
    end

    if exit_sync() then
        if st.inzone and not inzone then
            st.left_at = now
            send_radz(true, now)
        elseif not inzone and st.left_at and now - st.left_at <= RADZ_FOR and now - st.radz_at >= RADZ_EVERY then
            send_radz(false, now)
        end
        st.inzone = inzone
    end

    if not own_only() then
        st.last_cur = nil
        return
    end
    -- AfterDeath's StopGeiger @631 runs on the host's copy only
    if dead then
        if not st.dead then
            st.dead = true
            stop_own(comp, "own character dead")
        end
        st.last_cur = nil
        return
    end
    st.dead = false
    local cur = tonumber(ue.prop(comp, "CurrentRadiation"))
    local max = tonumber(ue.prop(comp, "MaxRadiation"))
    if not cur or not max then return end
    local last = st.last_cur
    st.last_cur = cur
    if not last then return end
    if cur < last - EPS then
        own_dosimeter(comp, cur, max)
    elseif cur > last + EPS then
        -- IncreaseRadiation (pills) @1314
        stop_own(comp, "radiation went up")
    end
end

-- ---------------------------------------------------------------------------

local function prune(now)
    if now - st.prune_at < 10 then return end
    st.prune_at = now
    for a, c in pairs(st.owner_cache) do
        if now - c.t > OWNER_TTL then st.owner_cache[a] = nil end
    end
    for a, t in pairs(st.updated_at) do
        if now - t > 60 then st.updated_at[a] = nil end
    end
    for a, f in pairs(st.filt) do
        if now - f.used > FILTER_IDLE_S then st.filt[a] = nil end
    end
end

-- Every 250 ms (main.lua), any role.
function M.tick()
    if not S then return end
    local now = clock()
    local role = S.role
    if role ~= st.role then
        st.role = role
        st.owner_cache = {}
        st.pawn, st.last_cur, st.inzone, st.left_at = nil, nil, false, nil
        st.lost, st.alive_loc, st.alive_inzone = nil, nil, false
    end
    st.active = (role == "host" and #(S.remote_pcs or {}) > 0) or role == "client"
    if not st.active then return end
    try_hooks(now)
    local okh, eh = pcall(hud.tick, now)
    if not okh then log.err_throttled("geiger.hudmods-tick", "geiger: hudmods tick: %s", tostring(eh)) end
    prune(now)
    if role == "host" then
        sweep(now)
    else
        client_tick(now)
    end
end

function M.install(state)
    S = state
    -- client -> host: RADZ|0|edge
    net.on("RADZ", function(f, pc)
        local ok, err = pcall(on_radz, f, pc)
        if not ok then log.err_throttled("geiger.radz", "geiger: RADZ: %s", tostring(err)) end
    end)
    hud.install(state)   -- RESPUI handler
    log.info("geiger: installed (geiger_own_only=%s, radiation_exit_sync=%s, client_gear_hud=%s)", tostring(own_only()),
        tostring(exit_sync()), tostring(cfg.get("client_gear_hud") ~= false))
end

-- World change: every cached address belongs to the old world; nothing of it
-- is touched.
function M.reset(why)
    st.owner_cache, st.updated_at = {}, {}
    st.pawn, st.last_cur, st.dead = nil, nil, false
    st.inzone, st.left_at = false, nil
    st.zones, st.lost, st.respawn_at, st.filt = {}, nil, nil, {}
    st.pawn_since, st.pawn_name, st.alive_loc, st.alive_inzone = nil, nil, nil, false
    st.cue = nil
    pcall(hud.reset, why)
    log.debug("geiger: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    return string.format("geiger: hooks spawn=%s decrease=%s update=%s usefilter=%s zones=%s | others' dosimeters muted=%d stopped=%d swept=%d | own played=%d stopped=%d failed=%d | zone exits sent=%d host stops=%d idle=%d too soon=%d | respawn re-checks=%d entries reopened=%d own entries=%d ignored=%d | host: others' zone entries=%d filter uses=%d",
        tostring(st.hooks.spawn), tostring(st.hooks.decrease), tostring(st.hooks.update),
        tostring(st.hooks.usefilter), tostring(st.hooks.zone_in and st.hooks.zone_out),
        s.muted, s.stopped, s.swept, s.played, s.faded, s.failed,
        s.radz_sent, s.radz_stops, s.radz_idle, s.radz_soon,
        s.zone_rechecks, s.zone_resets, s.zone_entries, s.zone_blocked, s.host_entries, s.filter_uses)
        .. " || " .. hud.status_line()
end

return M
