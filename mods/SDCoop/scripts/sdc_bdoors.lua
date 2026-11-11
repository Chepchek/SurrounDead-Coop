-- SDCoop: placed doors and gates (buildables) look and block the same on every
-- machine: which way a door swings, open or closed, and the garage door's power.
--
-- How the game runs them (work\re\pseudo\Buildable_WoodenDoor.txt,
-- pseudo_garage\*.txt, pseudo\Buildable_MASTER.txt, Buildable_GeneratorMaster.txt):
--   * F on a door -> the server's OnServerExecuteInteract -> MC_OnInteractBuildable
--     (NetMulticast, NOT reliable) -> OnInteractBuildable on every machine:
--     - swing doors (Buildable_WoodenDoor, _WoodenDoor2, _BarricadedMetalDoor,
--       _BunkerDoor): Event_OpenDoor (@1347): IsClosed -> open: IsClosed =
--       false, DotProduct = Dot(Normal(StaticMesh location - GetPlayerCharacter(
--       self, 0) location), StaticMesh forward) (@665-986), Timeline_OpenDoor
--       .Play; else Timeline_OpenDoor.Reverse (IsClosed = true when it ends,
--       @10). Each update (@1018-1271): yaw = Lerp(0, DotProduct >= 0 ? 90 :
--       -90, alpha) on the StaticMesh - DotProduct alone decides the side.
--     - gate (Buildable_WoodenGate): the same toggle on Timeline_0 / Timeline_1,
--       its leaves always swing the same way (DotProduct unused).
--     - garage door: @1802 no PoweredOn? -> "Requires power"; DoorOpening? ->
--       nothing; else the GarageDoor_AnimFix montage, DoorOpening? = true,
--       Delay 1.83 -> Opened? flips (@99 / @122).
--   * IsClosed, DotProduct, Opened?, DoorOpening? do not replicate. Player 0 is
--     the opener on the host (sdc_ctx's scope: CurrentActor), but each client's
--     own player there: a door the host opened swung away from the CLIENT on
--     its screen (other side, other collision). A dropped multicast (or a copy
--     that was out of range / joined later: BeginPlay = closed) left a door
--     open on one machine and closed on the other.
--   * Power: PoweredOn? replicates (RepNotify), but a generator's OnRep_TurnedOn?
--     runs on clients too and starts there the server's own timers: GetObjects
--     (every 2-4 s: SphereOverlapActors -> Power On / Power Off of buildables in
--     range) and FuelCost (fuel spent, at 0: TurnedOn? = false + Power Off).
--     So each client computed power from its own copy; a local write is never
--     corrected (push model: the host resends only its own changes), and
--     ReplacingObject (move) sets it false. One machine saw "Requires power".
-- Here:
--   world_build_doors (under world_sync)
--     host   OnInteractBuildable (post) of a door: its new state -> WBDOOR to
--            every client (open, the host's DotProduct, power); all doors to a
--            client that asks (WBDOORQ on joining) and to every client each
--            SNAP_S.
--     client OnInteractBuildable (post) of a swing door another player opened:
--            DotProduct from that player (the multicast's Actor) and the
--            timeline's own update right away - the host's side.
--     client kept host states, a pass every PASS_S: a door copy that is not
--            moving and differs from the host's (GRACE after the host's change:
--            its multicast may still come) gets the game's own toggle
--            (Event_OpenDoor / the garage door's OnInteractBuildable), a swing
--            door the host's DotProduct (+ its timeline update).
--   world_build_power (under world_sync)
--     client generators: their GetObjects / FuelCost timers are cleared after
--            OnRep_TurnedOn? and by the pass - power comes from the host;
--            a door copy whose PoweredOn? differs from the host's gets the
--            game's Power On / Power Off.
--     host   OnRep_PoweredOn? (post) of a door -> WBDOOR.
-- Messages:
--   WBDOOR|c or s|entries   host -> client; entries joined by ';', each
--          "class x,y,z open(1/0) dot(-) power(1/0/-)"
--   WBDOORQ                 client -> host (once in a world)
-- Hooks: post only, wrapped in pcall, return nothing; parameters are read
-- inside the callback; no engine object is kept between calls.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = { sent = 0, snaps = 0, dirs_here = 0, toggles = 0, dirs_fixed = 0, power_fixed = 0, timers_cleared = 0,
              received = 0 },
}

local DOORS = "/Game/Blueprints/BuildingSystem/Actors/Doors/"
local SWING = { tl = "Timeline_OpenDoor", update = "Timeline_OpenDoor__UpdateFunc" }
local KINDS = {
    Buildable_WoodenDoor_C = { kind = "swing", path = DOORS .. "Buildable_WoodenDoor.Buildable_WoodenDoor_C" },
    Buildable_WoodenDoor2_C = { kind = "swing", path = DOORS .. "Buildable_WoodenDoor2.Buildable_WoodenDoor2_C" },
    Buildable_BarricadedMetalDoor_C = { kind = "swing",
        path = DOORS .. "Buildable_BarricadedMetalDoor.Buildable_BarricadedMetalDoor_C" },
    Buildable_BunkerDoor_C = { kind = "swing", path = DOORS .. "Buildable_BunkerDoor.Buildable_BunkerDoor_C" },
    Buildable_WoodenGate_C = { kind = "gate", path = DOORS .. "Buildable_WoodenGate.Buildable_WoodenGate_C",
        tl = "Timeline_0", tl2 = "Timeline_1" },
    Buildable_GarageDoor_C = { kind = "garage", path = DOORS .. "Buildable_GarageDoor.Buildable_GarageDoor_C", power = true },
}
for _, k in pairs(KINDS) do
    if k.kind == "swing" then k.tl, k.update = SWING.tl, SWING.update end
end
local BASE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local GENERATOR = "/Game/Blueprints/BuildingSystem/Actors/Generator/Buildable_GeneratorMaster.Buildable_GeneratorMaster_C"
local GEN_CLS = "Buildable_GeneratorMaster_C"
local GEN_TIMERS = { "GetObjects", "FuelCost" }

local PLACE_MATCH = 100     -- cm
local GRACE = 2.5           -- s after the host's change before a copy is toggled here
local PASS_S = 2            -- client pass
local SNAP_S = 20           -- host: all doors to every client
local KEEP_S = 45           -- client: a host state not refreshed this long is forgotten
local SNAP_AFTER_S = 3
local CHUNK = 900
local HOOK_RETRY_S = 2

local clock = os.clock
local S
local st = {
    role = nil, hooks = {}, hook_logged = {}, hook_at = -100,
    known = {},          -- client: { cls, loc, locs, open, dot, power, changed, seen, applied }
    pass_at = -100, snap_at = 0, asked = nil, since = nil,
    gen_said = {},       -- client: [generator address] = true
}

local function doors_on() return cfg.get("world_sync") ~= false and cfg.get("world_build_doors") ~= false end
local function power_on() return cfg.get("world_sync") ~= false and cfg.get("world_build_power") ~= false end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end
local function addr(o) return ue.valid(o) and ctx.addr(o) or nil end
local function num(v) return type(v) == "number" and v or 0 end
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
local function vec(v)
    if v == nil then return nil end
    local x, y, z = ue.try(function() return v.X end), ue.try(function() return v.Y end), ue.try(function() return v.Z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end

local function kind_of(d) return KINDS[ue.class_name(d)] end

local function remote_pcs() return (S and S.remote_pcs) or {} end

-- ---------------------------------------------------------------------------
-- A door's state, the game's own toggle, its swing side
-- ---------------------------------------------------------------------------

-- open (the state it is in or moving to), moving
local function state_of(d, k)
    if k.kind == "garage" then
        local opening = ue.prop(d, "DoorOpening?") == true
        local opened = ue.prop(d, "Opened?") == true
        if opening then return not opened, true end
        return opened, false
    end
    local t = ue.prop(d, k.tl)
    local rev = ue.valid(t) and ue.try(function() return t:IsReversing() end) == true
    local moving = ue.valid(t) and ue.try(function() return t:IsPlaying() end) == true
    if not moving and k.tl2 then
        local t2 = ue.prop(d, k.tl2)
        moving = ue.valid(t2) and ue.try(function() return t2:IsPlaying() end) == true
    end
    return ue.prop(d, "IsClosed") == false and not rev, moving
end

-- Event_OpenDoor's formula with another player's place (@676-986).
local function dot_from(d, pawn)
    local mesh = ue.prop(d, "StaticMesh")
    if not ue.valid(mesh) then return nil end
    local ml = vec(ue.try(function() return mesh:K2_GetComponentLocation() end))
    local fw = vec(ue.try(function() return mesh:GetForwardVector() end))
    local pl = ue.location(pawn)
    if not ml or not fw or not pl then return nil end
    local dx, dy, dz = ml.X - pl.X, ml.Y - pl.Y, ml.Z - pl.Z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len <= 0.0001 then return 0 end
    return (dx * fw.X + dy * fw.Y + dz * fw.Z) / len
end

-- DotProduct, then the timeline's own update: the leaf on that side now.
local function set_dot(d, k, dot)
    ue.set_prop(d, "DotProduct", dot)
    pcall(function() d[k.update](d) end)
end

local function set_power(d, on_)
    local fn = on_ and "Power On" or "Power Off"
    local ok = pcall(function() d[fn](d, nil) end)
    if not ok or (ue.prop(d, "PoweredOn?") == true) ~= on_ then
        ue.set_prop(d, "PoweredOn?", on_)
        pcall(function() d["OnRep_PoweredOn?"](d) end)
    end
    return (ue.prop(d, "PoweredOn?") == true) == on_
end

-- The game's own toggle on this machine's copy.
local function toggle(d, k)
    if k.kind ~= "garage" then return pcall(function() d:Event_OpenDoor() end) end
    -- OnInteractBuildable moves it only with power (else "Requires power" on
    -- this screen): the host's door moved, so for this one call it has power
    local powered = ue.prop(d, "PoweredOn?") == true
    if not powered then ue.set_prop(d, "PoweredOn?", true) end
    local ok = pcall(function() d:OnInteractBuildable(nil) end)
    if not powered then ue.set_prop(d, "PoweredOn?", false) end
    return ok
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function entry_of(d, k)
    local l = ue.location(d)
    if not l then return nil end
    local open = state_of(d, k)
    local dot = k.kind == "swing" and string.format("%.3f", num(ue.prop(d, "DotProduct"))) or "-"
    local pw = k.power and (ue.prop(d, "PoweredOn?") == true and "1" or "0") or "-"
    return string.format("%s %s %s %s %s", ue.class_name(d), loc_str(l), open and "1" or "0", dot, pw), open
end

local function send_entries(pcs, why, entries)
    local buf, len = {}, 0
    local function flush()
        if #buf == 0 then return end
        net.broadcast(pcs, "WBDOOR", why, table.concat(buf, ";"))
        M.stats.sent = M.stats.sent + 1
        buf, len = {}, 0
    end
    for _, e in ipairs(entries) do
        if len + #e + 1 > CHUNK then flush() end
        buf[#buf + 1] = e
        len = len + #e + 1
    end
    flush()
end

local function all_doors()
    local out = {}
    for cls, k in pairs(KINDS) do
        if ue.find_object(k.path) then
            for _, d in ipairs(ue.find_all(cls)) do
                if ue.valid(d) and ue.class_name(d) == cls then out[#out + 1] = { d = d, k = k } end
            end
        end
    end
    return out
end

local function snapshot(pcs, why)
    local entries = {}
    for _, e in ipairs(all_doors()) do
        local s = entry_of(e.d, e.k)
        if s then entries[#entries + 1] = s end
    end
    if #entries > 0 then send_entries(pcs, "s", entries) end
    M.stats.snaps = M.stats.snaps + 1
    return #entries
end

local function host_change(d, k, why)
    local pcs = remote_pcs()
    if #pcs == 0 then return end
    local s, open = entry_of(d, k)
    if not s then return end
    send_entries(pcs, "c", { s })
    log.info("bdoors: host: %s %s (%s): WBDOOR to %d client(s)%s", ue.short(d), open and "opens" or "closes", why, #pcs,
        k.kind == "swing" and string.format(", swings %s (dot %.2f)", num(ue.prop(d, "DotProduct")) >= 0 and "+90" or "-90",
            num(ue.prop(d, "DotProduct"))) or (k.power and (", power " .. tostring(ue.prop(d, "PoweredOn?") == true)) or ""))
end

-- WBDOORQ (client -> host)
local function snap_msg(_, pc)
    if not S or S.role ~= "host" or not doors_on() then return end
    local n = snapshot({ pc }, "join")
    log.info("bdoors: host: a client asked for the doors: %d sent", n)
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function find_copy(cls, loc, list)
    local best, bestd = nil, PLACE_MATCH * PLACE_MATCH
    for _, d in ipairs(list or ue.find_all(cls)) do
        if ue.valid(d) and ue.class_name(d) == cls then
            local dd = d2(ue.location(d), loc)
            if dd <= bestd then best, bestd = d, dd end
        end
    end
    return best
end

local function remember(why, cls, loc, locs, open, dot, power, now)
    for _, e in ipairs(st.known) do
        if e.cls == cls and d2(e.loc, loc) <= PLACE_MATCH * PLACE_MATCH then
            if e.open ~= open then e.changed = now end
            e.loc, e.locs, e.open, e.dot, e.power, e.seen = loc, locs, open, dot, power, now
            return e
        end
    end
    local e = { cls = cls, loc = loc, locs = locs, open = open, dot = dot, power = power, seen = now,
                changed = why == "c" and now or -100, applied = -100 }
    st.known[#st.known + 1] = e
    return e
end

-- This machine's copy against the host's state.
local function reconcile(d, k, e, now)
    if k.power and e.power ~= nil and power_on() and (ue.prop(d, "PoweredOn?") == true) ~= e.power then
        if set_power(d, e.power) then
            M.stats.power_fixed = M.stats.power_fixed + 1
            log.info("bdoors: %s has %s here, as on the host", ue.short(d), e.power and "power" or "no power")
        end
    end
    if not doors_on() then return end
    local open, moving = state_of(d, k)
    if open ~= e.open and not moving and now - e.changed >= GRACE and now - e.applied >= GRACE then
        e.applied = now
        local ok = toggle(d, k)
        if ok and k.kind == "swing" and e.open and e.dot then set_dot(d, k, e.dot) end
        M.stats.toggles = M.stats.toggles + 1
        log.info("bdoors: %s was %s here, %s like on the host (the game's toggle)%s", ue.short(d),
            open and "open" or "closed", e.open and "opened" or "closed", ok and "" or " - FAILED")
        return
    end
    if k.kind == "swing" and open and e.open and e.dot
        and (num(ue.prop(d, "DotProduct")) >= 0) ~= (e.dot >= 0) then
        set_dot(d, k, e.dot)
        M.stats.dirs_fixed = M.stats.dirs_fixed + 1
        log.info("bdoors: %s swings to the host's side here (dot %.2f)", ue.short(d), e.dot)
    end
end

-- WBDOOR|c or s|entries (host -> client)
local function door_msg(f)
    if not S or S.role ~= "client" or not (doors_on() or power_on()) then return end
    local why = f[1] == "s" and "s" or "c"
    local now = clock()
    local n = 0
    for item in tostring(f[2] or ""):gmatch("[^;]+") do
        local cls, locs, o, dot, pw = item:match("^(%S+) (%S+) ([01]) (%S+) (%S+)$")
        local k = cls and KINDS[cls]
        local loc = locs and parse_loc(locs)
        if k and loc then
            n = n + 1
            local power = nil
            if pw == "1" then power = true elseif pw == "0" then power = false end
            local e = remember(why, cls, loc, locs, o == "1", tonumber(dot), power, now)
            if why == "c" then
                local d = find_copy(cls, loc)
                if d then reconcile(d, k, e, now) end
                log.debug("bdoors: the host's %s at %s %s", cls, locs, e.open and "opens" or "closes")
            end
        end
    end
    M.stats.received = M.stats.received + n
    if why == "s" then log.debug("bdoors: %d door state(s) from the host", n) end
end

-- Generators here do not compute power (the host's do).
local function quiet_generator(g, why)
    local ksl = ue.ksl()
    if not ksl then return end
    local cleared = {}
    for _, t in ipairs(GEN_TIMERS) do
        if ue.try(function() return ksl:K2_IsTimerActive(g, t) end) == true
            and pcall(function() ksl:K2_ClearTimer(g, t) end) then
            cleared[#cleared + 1] = t
        end
    end
    if #cleared == 0 then return end
    M.stats.timers_cleared = M.stats.timers_cleared + #cleared
    local a = addr(g) or -1
    if not st.gen_said[a] then
        st.gen_said[a] = true
        log.info("bdoors: generator %s: its server timers %s stopped here (%s) - buildables get their power from the host",
            ue.short(g), table.concat(cleared, "+"), why)
    end
end

local function client_pass(now)
    if now - st.pass_at < PASS_S then return end
    st.pass_at = now
    if power_on() and ue.find_object(GENERATOR) then
        for _, g in ipairs(ue.find_all(GEN_CLS)) do
            if ue.valid(g) then quiet_generator(g, "pass") end
        end
    end
    local keep, lists = {}, {}
    for _, e in ipairs(st.known) do
        if now - e.seen <= KEEP_S then
            keep[#keep + 1] = e
            local list = lists[e.cls]
            if not list then list = ue.find_all_recent(e.cls, PASS_S); lists[e.cls] = list end
            local d = find_copy(e.cls, e.loc, list)
            if d then reconcile(d, KINDS[e.cls], e, now) end
        end
    end
    st.known = keep
end

local function client_ask(now)
    local cs = S.client
    if not (cs and cs.acked == true) or not ue.local_pawn() then return end
    local key = tostring(S.map) .. "|" .. tostring(cs.pc_key)
    if st.asked == key then return end
    if not st.since or st.since.key ~= key then st.since = { key = key, t = now } return end
    if now - st.since.t < SNAP_AFTER_S then return end
    if net.send_to_host("WBDOORQ") then
        st.asked = key
        log.info("bdoors: asked the host for its doors (WBDOORQ)")
    end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- <door>.OnInteractBuildable(Actor), post: the door toggled on this machine.
local function on_toggle(c, actor_p)
    if not S then return end
    local d = pget(c)
    local k = ue.valid(d) and kind_of(d)
    if not k then return end
    if S.role == "host" then
        if doors_on() then host_change(d, k, "toggled") end
        return
    end
    if S.role ~= "client" or not doors_on() or k.kind ~= "swing" then return end
    local who = pget(actor_p)
    local me = ue.local_pawn()
    if not ue.valid(who) or (me and addr(who) == addr(me)) then return end
    local open = state_of(d, k)
    if not open then return end
    -- it opened with this player's side (player 0 here): the opener's instead
    local dot = dot_from(d, who)
    if dot == nil or (dot >= 0) == (num(ue.prop(d, "DotProduct")) >= 0) then return end
    set_dot(d, k, dot)
    M.stats.dirs_here = M.stats.dirs_here + 1
    log.info("bdoors: %s opened by %s: swings away from that player here too (dot %.2f)", ue.short(d), ue.short(who), dot)
end

-- Buildable_MASTER.OnRep_PoweredOn?, post, host: a door's power changed.
local function on_power(c)
    if not S or S.role ~= "host" or not power_on() then return end
    local d = pget(c)
    local k = ue.valid(d) and kind_of(d)
    if k and k.power then host_change(d, k, "power") end
end

-- Buildable_GeneratorMaster.OnRep_TurnedOn?, post, client: it started the
-- server's timers here.
local function on_turned(c)
    if not S or S.role ~= "client" or not power_on() then return end
    local g = pget(c)
    if ue.valid(g) then quiet_generator(g, "turned on/off") end
end

local HOOKS = {}
for cls, k in pairs(KINDS) do
    HOOKS[#HOOKS + 1] = { key = cls, path = k.path .. ":OnInteractBuildable", cb = on_toggle }
end
table.sort(HOOKS, function(a, b) return a.key < b.key end)
HOOKS[#HOOKS + 1] = { key = "power", path = BASE .. ":OnRep_PoweredOn?", cb = on_power, role = "host" }
HOOKS[#HOOKS + 1] = { key = "gen", path = GENERATOR .. ":OnRep_TurnedOn?", cb = on_turned, role = "client" }

local function try_hooks(now, role)
    if now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    for _, h in ipairs(HOOKS) do
        if not st.hooks[h.key] and (h.role == nil or h.role == role) and ue.find_object(h.path) then
            local cb = h.cb
            local ok, err = pcall(RegisterHook, h.path, function(...)
                local okc, e = pcall(cb, ...)
                if not okc then log.err_throttled("bdoors." .. h.key, "bdoors: %s hook: %s", h.key, tostring(e)) end
            end)
            local name = h.path:match("([%w_]+:[%w_?]+)$") or h.path
            if ok then
                st.hooks[h.key] = true
                log.info("bdoors: hook %s ok", name)
            elseif not st.hook_logged[h.key] then
                st.hook_logged[h.key] = true
                log.warn("bdoors: cannot hook %s yet (%s); retried", name, tostring(err))
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
    if not doors_on() and not power_on() then return end
    local now = clock()
    if role == "host" then
        if #remote_pcs() == 0 then return end
        try_hooks(now, role)
        if doors_on() and now - st.snap_at >= SNAP_S then
            st.snap_at = now
            snapshot(remote_pcs(), "periodic")
        end
    elseif role == "client" then
        try_hooks(now, role)
        if doors_on() then client_ask(now) end
        client_pass(now)
    end
end

-- main.lua, every 500 ms (any role).
function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("bdoors.tick", "bdoors: tick: %s", tostring(err)) end
end

function M.reset(why)
    st.known, st.pass_at, st.asked, st.since, st.gen_said = {}, -100, nil, nil, {}
    st.snap_at = clock()
    log.debug("bdoors: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    net.on("WBDOOR", door_msg)
    net.on("WBDOORQ", snap_msg)
    log.info("bdoors: installed (world_build_doors=%s, world_build_power=%s): placed doors and gates swing to the opener's side and stay open/closed as on the host (WBDOOR on change, on join, every %d s); clients' generators leave power to the host",
        tostring(doors_on()), tostring(power_on()), SNAP_S)
end

function M.status_line()
    local s = M.stats
    local n = 0
    for _ in pairs(st.hooks) do n = n + 1 end
    return string.format("bdoors: doors=%s power=%s hooks=%d/%d | host: messages=%d snapshots=%d | client: states=%d known=%d, sides set on open=%d, toggled to the host's=%d, sides fixed=%d, power fixed=%d, generator timers stopped=%d",
        tostring(doors_on()), tostring(power_on()), n, #HOOKS, s.sent, s.snaps, s.received, #st.known, s.dirs_here,
        s.toggles, s.dirs_fixed, s.power_fixed, s.timers_cleared)
end

return M
