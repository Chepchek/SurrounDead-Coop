-- SDCoop: the host can use a placed buildable (garage door, wooden doors and
-- gates, workbenches, generators, storage) that a client used last.
--
-- How the game uses a buildable (work\re\pseudo\Buildable_MASTER.txt,
-- pseudo_garage\Buildable_GarageDoor.txt, BP_JigHelperComp.txt):
--   * Looking at it: the looker's BP_JigHelperComp.TraceToWorld (a 0.4 s
--     timer, local controller only) sets CurrentTracActor (@2382) and calls
--     OnBeginInteract(own pawn, options): Buildable_MASTER @4372
--     GameFunctionLibrary.GetHUD(self) -> ShowInteractWidget (the prompt
--     "Open / Move / Pick up") and @2072 UpdateInteractStats('Power');
--     looking away: OnEndInteract (ShowInteractWidget(false) the same way).
--     GetHUD = GetPlayerController(self, 0), only if that controller is local.
--   * F: TryInteract -> OnExecuteInteract -> the pawn's SERVER_ForwardInteract
--     -> on the server OnServerExecuteInteract(Option, ByActor): CurrentActor =
--     ByActor (garage door @2441, wooden door @312, base @3075), then the
--     option (garage door: Option1 MC_OnInteractBuildable -> OnInteractBuildable
--     on every machine: "Requires power" or the open / close montage;
--     Option2 ReplacingObject = move; Option3 Pickup).
--   * CurrentActor goes back to None only through OnExecuteInteractEnded
--     (@4280; the presser's helper calls it when its inventory window closes)
--     or CheckDistanceFromActor (a 0.1 s timer the window-opening buildables -
--     containers, workbenches, campfire, charger - start in OnInteractBuildable;
--     the user walked 3 m away). Doors and gates open no window: their
--     CurrentActor stays the last user forever. In single player that is
--     always the one player.
-- In co-op (host): sdc_ctx turns player-0 calls of a buildable into the
-- player in its CurrentActor (sdc_world's scope, kind "build"), which is
-- right during that player's interaction. A door a client moved, placed and
-- moved, or opened kept CurrentActor = that client, so when the HOST looked
-- at it, its own OnBeginInteract asked GetHUD for the client's controller
-- (not local on the host): None, no prompt - the host could not use the door
-- (log: "ctx: GetPlayerController(0) from Buildable_GarageDoor_C of a remote
-- player"). The same for any buildable a client used last and whose
-- interaction the game does not end itself (storage after a client's move or
-- rename, generators). The client's copy is not affected (sdc_ctx's client
-- mode does not use CurrentActor), so the reverse - a host-placed door the
-- client uses - worked.
-- Here (config world_build_release, under world_sync):
--   client OnExecuteInteract (post) on a buildable by its own pawn, then
--          OnEndInteract (post: it looked away) -> BREL|class|x,y,z: that
--          interaction is over.
--   host   BREL (a second later: its own server RPC may still be on the way)
--          -> that buildable, if its CurrentActor is still that client's pawn
--          and the game is not using it (not IsHeld, no CheckDistanceFromActor
--          timer): the game's own OnExecuteInteractEnded (CurrentActor =
--          None), as the presser's machine does at the end of an interaction.
--   host   OnBeginInteract (post) by the host's own pawn on a buildable whose
--          CurrentActor is a remote player (BREL not there yet, or that
--          player still looks at it): the same release, then the game's own
--          BP_JigHelperComp.StopInteraction on the host's helper, so the next
--          TraceToWorld (<= 0.4 s) begins the look again and shows the prompt.
-- Beds and sleeping bags are left alone (sdc_respawn routes their
-- BedComponent by the bed's CurrentActor).
-- Hooks: post only, wrapped in pcall, return nothing; parameters are read
-- inside the callback; no engine object is kept between calls (addresses,
-- classes, places only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = { pressed = 0, ends_sent = 0, ends_host = 0, released_end = 0, released_look = 0, busy = 0,
              not_theirs = 0, missing = 0, retraced = 0 },
}

local BASE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local CONTAINER = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local GENERATOR = "/Game/Blueprints/BuildingSystem/Actors/Generator/Buildable_GeneratorMaster.Buildable_GeneratorMaster_C"

-- sdc_respawn's BedComponent routing reads the bed's CurrentActor
local EXCLUDE = { Buildable_Bed_C = true, Buildable_SleepingBag_C = true }

local PLACE_MATCH = 100     -- cm: a buildable this close to the named place is the one
local END_DELAY_MS = 1000   -- host: BREL handled this much later
local PRESS_KEEP = 120      -- s: client: a press counts for a look-away this long
local LOOK_GAP = 1.0        -- s: host: one release per buildable per this long (no re-trace loop)
local HOOK_RETRY_S = 2

local clock = os.clock
local S
local st = {
    role = nil,
    hooks = {},          -- [key] = true once registered
    hook_logged = {},
    hook_at = -100,
    pressed = {},        -- client: [address] = { cls =, loc = "x,y,z", t = }
    looked = {},         -- host: [address] = clock of the last release on a look
    busy_said = {},      -- host: [address] = true: "in use" logged once
}

local function on()
    return cfg.get("world_sync") ~= false and cfg.get("world_build_release") ~= false
end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function addr(o)
    if not ue.valid(o) then return nil end
    return ctx.addr(o)
end

local function loc_str(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function parse_loc(s)
    local x, y, z = tostring(s or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end
local function d2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local isa_cache = {}   -- [class name] = bool
local function is_buildable(o)
    local cn = ue.class_name(o)
    if cn == "" then return false end
    local c = isa_cache[cn]
    if c ~= nil then return c end
    local cls = ue.find_object(BASE)
    if not cls then return false end   -- not loaded: no buildable exists
    local ok, r = pcall(function() return o:IsA(cls) end)
    if not ok then return false end
    isa_cache[cn] = r == true and not EXCLUDE[cn]
    return isa_cache[cn]
end

local function remote_pc_of(pawn)
    if not ue.valid(pawn) then return nil end
    local pc = ue.prop(pawn, "Controller")
    if ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) then return pc end
    return nil
end

-- Why the game still uses it for its CurrentActor, or nil.
local function busy(obj)
    if ue.prop(obj, "IsHeld") == true then return "a hold to pick up is running" end
    local ksl = ue.ksl()
    if ksl and ue.try(function() return ksl:K2_IsTimerActive(obj, "CheckDistanceFromActor") end) == true then
        return "its window is open (the game's distance check runs)"
    end
    return nil
end

-- The game's own end of an interaction (Buildable_MASTER.OnExecuteInteractEnded
-- @4280: CurrentActor = None); the property itself only if that fails.
local function release(obj)
    local ok, err = pcall(function() obj:OnExecuteInteractEnded() end)
    if ok and not ue.valid(ue.prop(obj, "CurrentActor")) then return true, "OnExecuteInteractEnded" end
    local okp = ue.set_prop(obj, "CurrentActor", nil)
    log.warn("build: OnExecuteInteractEnded on %s %s; CurrentActor set to None directly: %s", ue.short(obj),
        ok and "left CurrentActor set" or ("failed (" .. tostring(err) .. ")"), okp and "ok" or "FAILED")
    return okp and not ue.valid(ue.prop(obj, "CurrentActor")), "CurrentActor = None"
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function host_active()
    return S ~= nil and S.role == "host" and #(S.remote_pcs or {}) > 0 and on()
end

-- OnBeginInteract(InteractingActor, Options), post, host: the host's own look
-- at a buildable whose CurrentActor is a remote player.
local function on_begin(c, actor_p)
    if not host_active() then return end
    local obj = pget(c)
    if not ue.valid(obj) or not is_buildable(obj) then return end
    local me = ue.local_pawn()
    local who = pget(actor_p)
    if not me or addr(who) ~= addr(me) then return end
    local cur = ue.prop(obj, "CurrentActor")
    if not remote_pc_of(cur) then return end
    local a = addr(obj) or -1
    local now = clock()
    if now - (st.looked[a] or -100) < LOOK_GAP then return end
    local why = busy(obj)
    if why then
        M.stats.busy = M.stats.busy + 1
        if not st.busy_said[a] then
            st.busy_said[a] = true
            log.info("build: host: the host looks at %s, which %s uses: left to the game (%s)", ue.short(obj),
                ue.short(cur), why)
        end
        return
    end
    st.looked[a] = now
    local ok, how = release(obj)
    if not ok then return end
    M.stats.released_look = M.stats.released_look + 1
    log.info("build: host: the host looks at %s, last used by %s (its CurrentActor was left over): released (%s); the host's prompt shows on its next trace",
        ue.short(obj), ue.short(cur), how)
    -- the game's own StopInteraction on the host's helper: TraceToWorld then
    -- begins this look again (OnBeginInteract -> the host's HUD)
    ue.delay("builduse-retrace", 0, function()
        local p = ue.local_pawn()
        local h = p and ue.prop(p, "BP_JigHelperComp")
        if ue.valid(h) and pcall(function() h:StopInteraction() end) then
            M.stats.retraced = M.stats.retraced + 1
        end
    end)
end

-- BREL|class|x,y,z (client -> host): its interaction with that buildable is over.
local function end_msg(f, pc)
    if not host_active() then return end
    local cls, loc = f[1], parse_loc(f[2])
    if type(cls) ~= "string" or cls == "" or not loc then return end
    M.stats.ends_host = M.stats.ends_host + 1
    -- its SERVER_ForwardInteract travels on another channel: a moment later
    -- (the sender found again by its address: no wrapper kept)
    local place, pa = f[2], addr(pc)
    ue.delay("builduse-end", END_DELAY_MS, function()
        if not host_active() then return end
        local sender
        for _, p in ipairs(S.remote_pcs or {}) do
            if addr(p) == pa then sender = p end
        end
        local pawn = sender and ue.pawn_of(sender)
        if not pawn then return end
        local best, bestd = nil, PLACE_MATCH * PLACE_MATCH
        for _, o in ipairs(ue.find_all(cls)) do
            if ue.valid(o) and ue.class_name(o) == cls and is_buildable(o) then
                local d = d2(ue.location(o), loc)
                if d <= bestd then best, bestd = o, d end
            end
        end
        if not best then
            M.stats.missing = M.stats.missing + 1
            log.debug("build: host: %s ended its use of %s at %s, which the host does not have", ue.short(pawn), cls, place)
            return
        end
        local cur = ue.prop(best, "CurrentActor")
        if not ue.valid(cur) or addr(cur) ~= addr(pawn) then
            M.stats.not_theirs = M.stats.not_theirs + 1
            log.debug("build: host: %s ended its use of %s; its CurrentActor is %s: nothing to end", ue.short(pawn),
                ue.short(best), ue.valid(cur) and ue.short(cur) or "None")
            return
        end
        local why = busy(best)
        if why then
            M.stats.busy = M.stats.busy + 1
            log.debug("build: host: %s ended its use of %s, but %s: left to the game", ue.short(pawn), ue.short(best), why)
            return
        end
        local ok, how = release(best)
        if ok then
            M.stats.released_end = M.stats.released_end + 1
            log.info("build: host: %s's use of %s is over (it looked away): released (%s), the host can use it as its own",
                ue.short(pawn), ue.short(best), how)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function own_pawn_of(p)
    local me = ue.local_pawn()
    return me ~= nil and addr(p) == addr(me)
end

-- Buildable_MASTER.OnExecuteInteract(InteractingActor, Option), post,
-- client: this player pressed F on it (its server part runs on the host).
local function on_press(c, actor_p)
    if not S or S.role ~= "client" or not on() then return end
    local obj = pget(c)
    if not ue.valid(obj) or not is_buildable(obj) then return end
    if not own_pawn_of(pget(actor_p)) then return end
    local l = ue.location(obj)
    local a = addr(obj)
    if not l or not a then return end
    st.pressed[a] = { cls = ue.class_name(obj), loc = loc_str(l), t = clock() }
    M.stats.pressed = M.stats.pressed + 1
end

-- OnEndInteract, post, client: this player looked away from it.
local function on_end(c)
    if not S or S.role ~= "client" or not on() then return end
    local obj = pget(c)
    local a = addr(obj)
    local p = a and st.pressed[a]
    if not p then return end
    st.pressed[a] = nil
    if clock() - p.t > PRESS_KEEP then return end
    -- its current place (it may have been moved since the press)
    local l = ue.location(obj)
    local place = l and loc_str(l) or p.loc
    if net.send_to_host("BREL", p.cls, place) then
        M.stats.ends_sent = M.stats.ends_sent + 1
        log.info("build: the use of %s (%s at %s) is over here (looked away): the host ends it on its copy (BREL)",
            ue.short(obj), p.cls, place)
    end
end

-- ---------------------------------------------------------------------------
-- Hooks, tick, install
-- ---------------------------------------------------------------------------

local HOOKS = {
    { key = "begin", path = BASE .. ":OnBeginInteract", cb = on_begin, role = "host" },
    { key = "begin_c", path = CONTAINER .. ":OnBeginInteract", cb = on_begin, role = "host" },
    { key = "begin_g", path = GENERATOR .. ":OnBeginInteract", cb = on_begin, role = "host" },
    { key = "press", path = BASE .. ":OnExecuteInteract", cb = on_press, role = "client" },
    { key = "end", path = BASE .. ":OnEndInteract", cb = on_end, role = "client" },
    { key = "end_g", path = GENERATOR .. ":OnEndInteract", cb = on_end, role = "client" },
}

-- A Blueprint function exists once its class is loaded (a buildable of it in
-- the world): tried again every HOOK_RETRY_S until each hook is in.
local function try_hooks(now, role)
    if now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    for _, h in ipairs(HOOKS) do
        if not st.hooks[h.key] and h.role == role and ue.find_object(h.path) then
            local cb = h.cb
            local ok, err = pcall(RegisterHook, h.path, function(...)
                local okc, e = pcall(cb, ...)
                if not okc then log.err_throttled("builduse." .. h.key, "build: %s hook: %s", h.key, tostring(e)) end
            end)
            local name = h.path:match("([%w_]+:[%w_]+)$") or h.path
            if ok then
                st.hooks[h.key] = true
                log.info("build: hook %s ok", name)
            elseif not st.hook_logged[h.key] then
                st.hook_logged[h.key] = true
                log.warn("build: cannot hook %s yet (%s); retried", name, tostring(err))
            end
        end
    end
end

local function tick()
    if not S then return end
    local role = S.role
    if role ~= st.role then
        if st.role ~= nil then M.reset("role " .. tostring(st.role) .. " -> " .. tostring(role)) end
        st.role = role
    end
    if not on() then return end
    local now = clock()
    if role == "host" then
        if #(S.remote_pcs or {}) == 0 then return end
        try_hooks(now, role)
        for a, t in pairs(st.looked) do if now - t > 60 then st.looked[a] = nil end end
    elseif role == "client" then
        try_hooks(now, role)
        for a, p in pairs(st.pressed) do if now - p.t > PRESS_KEEP then st.pressed[a] = nil end end
    end
end

-- main.lua, every 500 ms (any role).
function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("builduse.tick", "build: tick: %s", tostring(err)) end
end

-- World / role change: every kept address belonged to the old world.
function M.reset(why)
    st.pressed, st.looked, st.busy_said = {}, {}, {}
    log.debug("build: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    net.on("BREL", end_msg)
    log.info("build: installed (world_build_release=%s): a buildable a client used last (garage door, doors, gates, benches, generators, storage) keeps no left-over user on the host - the host's own look and use work (BREL when the client looks away, release on the host's look)",
        tostring(on()))
end

function M.status_line()
    local s = M.stats
    local n = 0
    for _ in pairs(st.hooks) do n = n + 1 end
    return string.format("build: on=%s hooks=%d/%d | host: ends received=%d released=%d, released on the host's look=%d (re-traced %d), left to the game=%d, not theirs=%d, missing=%d | client: presses=%d ends sent=%d",
        tostring(on()), n, #HOOKS, s.ends_host, s.released_end, s.released_look, s.retraced, s.busy, s.not_theirs,
        s.missing, s.pressed, s.ends_sent)
end

return M
