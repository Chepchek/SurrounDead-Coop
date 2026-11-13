-- Mock harness: a placed camp's map marker goes for everyone once any player
-- reaches the camp (sdc_events camp_pass / WEVT x; user report 2026-11-13:
-- "the marker does not go after you visit it").
-- The game (work\re\pseudo BP_PrefabSpawner DistanceToPrefab, BPC_MinimapSystem
-- "Remove World Marker", MapWidget "World Marker References", BP_Marker):
-- player 0 within DistanceToDiscoverPrefab (20 m) -> the marker's widget
-- RemoveFromParent + the BP_Marker destroyed, per machine, player 0 only.
--   K1  a client 25 m from the laboratory: nothing; 15 m: the host's widget
--       and marker go, WEVT x to every client, the other camp and the random
--       event's marker stay
--   K2  the client: both widgets of its copy (a late minimap registered it
--       twice) and the marker go; a stale WEVT o of it places nothing
--   K3  a joiner's list leaves the visited camp out
--   K4  the host itself within a spawner's own radius (30 m): visited
--   K5  after a remote player's respawn the marker's `Marker` names an
--       off-screen widget; the game's own discovery takes the marker first
--       (the host near at the last pass): the host's widget noted earlier
--       goes too, the clients are told
--   K6  a dead player at a camp does not count; alive it does; the host on
--       its death screen (no character): the marker still goes, no error
--   K7  a random event's marker with a player on it: untouched
--   K8  a marker not found by its path at note time: "not found" later is
--       no visit; world_prefabs off: no pass
--   K9  the host's respawn (a new map): its widgets noted again; a later
--       game's discovery (the host near at this pass) takes the new one off
--   K10 a widget the host's map never shows: looked for 6 times, then not
--       until the next map
--   K11 a camp at X -0.3: key "0,..." on both machines, WEVT x reaches it
--   K12 WEVT x on a client whose world_events_sync is off: marker goes
--   K13 WEVT x for a marker still waiting for the controller: never placed
--   K14 the world closing (DestroyAllActors: every BP_Marker_C) with the
--       host far, or dead near one: no visit, no WEVT x, the camps dropped
--   K15 reset; no hook / handler errors
-- usage: lua mock_events_camps.lua <scripts dir>
-- (harness core from mock_world_events.lua)
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD
local fails = 0
local function check(cond, what)
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- fake objects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
local next_addr = 4096
local LVL = "/Game/Levels/LongdownValley.LongdownValley:PersistentLevel."
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true }, Obj)
    o._full = chain[1] .. " " .. (path or (LVL .. name))
    w.objects[#w.objects + 1] = o
    w.paths[path or (LVL .. name)] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return self._p._outer end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:IsLocalController() return self._p._local == true end
function Obj:K2_DestroyActor() self._valid = false end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(self, nv) v = nv end, _v = function() return v end } end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
NotifyOnNewObject = function() end
StaticFindObject = function(path)
    local o = WORLD.paths[path]
    if o and o._valid then return o end
    return nil
end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(WORLD.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(ms, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local MODS = {}
local function bind(w)
    WORLD = w
    local m = MODS[w.id]
    if m then package.loaded["sdc_events"], package.loaded["sdc_notes"] = m.events, m.notes end
end
local function fire(w, path, ...)
    local prev = WORLD
    bind(w)
    for _, h in ipairs(w.hooks[path] or {}) do
        local r = h.pre(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
    if prev then bind(prev) end
end

-- ---------------------------------------------------------------- paths
local SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local MARKER_FN = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnMarker"
local EVENT_FN = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnRandomEvent"
local MARKER_P = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_Marker.BP_Marker_C"
local LAB_TEX = "/Game/UI/Textures/Mock/LabMarker.LabMarker"
local LAB_P = "/Game/Prefabs/Mock/Prefab_LabResearchTents1.Prefab_LabResearchTents1_C"
local CAMP_P = "/Game/Prefabs/Mock/Prefab_AbandonedCamp.Prefab_AbandonedCamp_C"
local APACHE_P = "/Game/Prefabs/Mock/Prefab_CrashedApache01.Prefab_CrashedApache01_C"

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, spawned = {} }
end
local HW, CW = world("host"), world("client")

-- MapWidget."World Marker References" (a TArray: ForEach / GetArrayNum);
-- _arr.walks: how often its list was walked
local function new_map(w, name)
    local list = {}
    local arr
    arr = {
        walks = 0,
        ForEach = function(_, fn)
            arr.walks = arr.walks + 1
            for i, x in ipairs(list) do fn(i, { get = function() return x end }) end
        end,
        GetArrayNum = function() return #list end,
    }
    local mw = new(w, { "MapWidget_C", "UserWidget" }, name, { ["World Marker References"] = arr })
    mw._list = list
    mw._arr = arr
    return mw
end
-- BP_Marker.AddMarker -> BPC_MinimapSystem."Add World Marker" ->
-- MapWidget.AddWorldCreatedMarker: a W_WorldMarker on that map, the marker's `Marker` = it
local wcount = 0
local function register(w, mw, marker)
    wcount = wcount + 1
    local wd = new(w, { "W_WorldMarker_C", "UserWidget" }, "W_WorldMarker_C_" .. wcount, { ["Target Actor"] = marker }, {
        RemoveFromParent = function(self) self._parented = false end,
    })
    wd._parented = true
    mw._list[#mw._list + 1] = wd
    marker._p.Marker = wd
    return wd
end
-- the game's DistanceToPrefab removal: "Remove World Marker"(Marker.Marker, Marker)
local function game_remove(marker)
    local wd = marker._p.Marker
    if wd and wd._valid then wd:RemoveFromParent() end
    marker:K2_DestroyActor()
end
local function widgets_of(mw, marker)
    local out = {}
    for _, wd in ipairs(mw._list) do if wd._p["Target Actor"] == marker then out[#out + 1] = wd end end
    return out
end
local function shown(mw, marker)
    local n = 0
    for _, wd in ipairs(widgets_of(mw, marker)) do if wd._parented then n = n + 1 end end
    return n
end

local function engine(w)
    WORLD = w
    w.gps = new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        BeginDeferredActorSpawnFromClass = function(gps, wco, cls, tf)
            local cp = param(cls)
            fire(w, SPAWN_FN, param(gps), param(wco), cp, param(tf))
            local c = cp._v()
            if not c or not c._actor then return nil end
            local t = tf.Translation
            local a = new(w, { c._name, "Actor" }, c._name .. "_" .. (2147400000 + #w.spawned),
                { _loc = { X = t.X, Y = t.Y, Z = t.Z }, Role = 3 }, {})
            w.spawned[#w.spawned + 1] = a
            return a
        end,
        FinishSpawningActor = function(_, a) if a then a._finished = true end return a end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return w.id == "host" end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
    for _, p in ipairs({ MARKER_FN, EVENT_FN }) do new(w, { "Function" }, p:match(":(.+)$"), {}, {}, p) end
    w.marker_cls = new(w, { "BlueprintGeneratedClass" }, "BP_Marker_C", {}, {}, MARKER_P)
    w.marker_cls._actor = true
    w.lab_tex = new(w, { "Texture2D" }, "LabMarker", {}, {}, LAB_TEX)
    w.lab = new(w, { "BlueprintGeneratedClass" }, "Prefab_LabResearchTents1_C", {}, {}, LAB_P)
    w.camp = new(w, { "BlueprintGeneratedClass" }, "Prefab_AbandonedCamp_C", {}, {}, CAMP_P)
    w.apache = new(w, { "BlueprintGeneratedClass" }, "Prefab_CrashedApache01_C", {}, {}, APACHE_P)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
        { Player = lp, _local = true }, { ServerExecRPC = function() end })
    w.map = new_map(w, "MapWidget_C_0")
    local mm = new(w, { "BPC_MinimapSystem_C", "ActorComponent" }, "BPC_MinimapSystem_0", { MapWidget = w.map })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _local = true, _loc = { X = 0, Y = 0, Z = 0 }, MinimapSystemComponent = mm })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
engine(HW)
engine(CW)

-- places (cm); every player starts far from all of them
local LAB = { X = 115194, Y = -99209, Z = 1527 }
local CAMP = { X = 150304, Y = -47827, Z = 1334 }
local CONVOY = { X = 65160, Y = 240059, Z = 1232 }
local QUAR = { X = -37657, Y = 116502, Z = 1399 }
local HIDDEN = { X = 277766, Y = 202693, Z = 1174 }
local HELI = { X = 173901, Y = 22718, Z = 1931 }
local function off(p, dx) return { X = p.X + dx, Y = p.Y, Z = p.Z } end
local FAR = { X = 0, Y = 0, Z = 0 }
HW.pawn._p._loc = { X = 1000, Y = 1000, Z = 0 }
CW.pawn._p._loc = { X = 2000, Y = 2000, Z = 0 }

WORLD = HW
local function remote(i, loc)
    local conn = new(HW, { "IpConnection" }, "IpConnection_" .. i)
    local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. i, { _loc = loc })
    local box = {}
    local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. i,
        { NetConnection = conn, Player = conn, Pawn = rpawn }, {
            ClientMessage = function(_, msg) box[#box + 1] = msg end,
            GetHUD = function() return nil end,
        })
    rpawn._p.Controller = rpc
    rpc._box = box
    rpc._pawn = rpawn
    return rpc
end
local rpc = remote(1, FAR)
local rpc2 = remote(2, { X = 3000, Y = 3000, Z = 0 })
HW.pcs[2], HW.pcs[3] = rpc, rpc2

-- ---------------------------------------------------------------- modules per world
local logs = { host = {}, client = {} }
local errors = 0
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.off = {}
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if m.off[k] then return false end
        return get0(k, ...)
    end
    local info0 = m.log.info
    m.log.info = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        local l = logs[w.id]
        l[#l + 1] = ok and s or fmt
        return info0(fmt, ...)
    end
    local errt0 = m.log.err_throttled
    m.log.err_throttled = function(key, fmt, ...)
        errors = errors + 1
        print("  [error " .. w.id .. "] " .. string.format(fmt, ...))
        return errt0(key, fmt, ...)
    end
    m.net.install_hooks()
    m.notes = require("sdc_notes")
    m.events = require("sdc_events")
    return m
end
local HS = { role = "host", remote_pcs = { rpc, rpc2 }, remote = {}, map = "LongdownValley" }
local H = load_mods(HW)
H.events.install(HS)
MODS.host = H
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
local C = load_mods(CW)
C.events.install(CS)
MODS.client = C

local function logged(id, pat)
    for _, l in ipairs(logs[id]) do if l:find(pat, 1, true) then return l end end
    return nil
end
local function clear_logs() logs.host, logs.client = {}, {} end
local function clear_box(p) for i = #p._box, 1, -1 do p._box[i] = nil end end
local function msgs(box, kind)
    local out = {}
    for _, m in ipairs(box) do if m:find("|" .. kind .. "|", 1, true) then out[#out + 1] = m end end
    return out
end
local function deliver_all()
    local list = {}
    for _, m in ipairs(rpc._box) do list[#list + 1] = m end
    clear_box(rpc)
    bind(CW)
    for _, msg in ipairs(list) do
        local kind, f = C.net.decode(msg)
        local h = C.net.handlers[kind]
        if h then h(f, CW.pc) end
    end
    return list
end
local function host_tick() bind(HW); H.events.tick() end
local function client_tick() bind(CW); C.events.tick() end

-- A placed camp spawner (DynamicEvent? off) and its roll at load: the camp,
-- @515 the discovery timer, @583 SpawnMarker (the BP_Marker), the post-hook.
local function camp_spawner(w, name, loc, prefab, title, radius)
    bind(w)
    return new(w, { "BP_PrefabSpawner_C", "Actor" }, name, {
        _loc = loc, Role = 3, ["DynamicEvent?"] = false, ["Spawned?"] = false, Prefab = prefab,
        ["Marker?"] = true, ["Marker Texture"] = w.lab_tex, ["Marker Title"] = FText(title),
        ["Marker Description"] = FText("desc"), DistanceToDiscoverPrefab = radius,
    }, {})
end
local function spawn_camp(w, sp, opts)
    opts = opts or {}
    bind(w)
    local tf = { Translation = sp._p._loc }
    local mp = param(w.marker_cls)
    fire(w, SPAWN_FN, param(w.gps), param(sp), mp, param(tf))
    local m = new(w, { "BP_Marker_C", "Actor" }, "BP_Marker_C_" .. (2147430000 + #w.objects), {
        _loc = sp._p._loc, MarkerTexture = sp._p["Marker Texture"], MarkerTitle = sp._p["Marker Title"],
        MarkerDescription = sp._p["Marker Description"], ["Texture Size"] = { X = 3.5, Y = 3.5 },
        Color = { R = 0.505208, G = 0.169744, B = 0.034207, A = 1 }, ["AddMarkerToCompass?"] = false })
    sp._p.Marker = m
    if opts.unfindable then w.paths[LVL .. m._name] = nil end
    fire(w, MARKER_FN, param(sp))
    return m
end
local function client_marker(key_loc)
    for _, a in ipairs(CW.spawned) do
        if a._chain[1] == "BP_Marker_C" and a._p._loc.X == key_loc.X and a._p._loc.Y == key_loc.Y then return a end
    end
    return nil
end
local function key_of(p) return string.format("%.0f,%.0f,%.0f", p.X, p.Y, p.Z) end
-- the host's kept camp at that place (nil: none, or dropped)
local function camp_at(p)
    for _, c in ipairs(H.events._st.camps) do if c.key == key_of(p) then return c end end
    return nil
end
local function open_camps()
    local n = 0
    for _, c in ipairs(H.events._st.camps) do if not c.gone then n = n + 1 end end
    return n
end

print("== K0. hooks; the host's camps and a random event, on both maps")
bind(HW); H.events.try_hooks(true)
bind(CW); C.events.try_hooks(true)
check(HW.hooks[MARKER_FN] ~= nil and #HW.hooks[MARKER_FN] == 1, "host: SpawnMarker post-hook")
local sp_lab = camp_spawner(HW, "BP_PrefabSpawner_C_53", LAB, HW.lab, "Abandoned Laboratory Research Tents", 2000)
local sp_camp = camp_spawner(HW, "BP_PrefabSpawner_C_0", CAMP, HW.camp, "Abandoned Camp", 3000)
local sp_conv = camp_spawner(HW, "BP_PrefabSpawner_C_25", CONVOY, HW.camp, "Abandoned Convoy", nil)
local sp_quar = camp_spawner(HW, "BP_PrefabSpawner_C_49", QUAR, HW.camp, "Military Quarantine Tents", 2000)
local m_lab, m_camp = spawn_camp(HW, sp_lab), spawn_camp(HW, sp_camp)
local m_conv, m_quar = spawn_camp(HW, sp_conv), spawn_camp(HW, sp_quar)
-- BP_Marker's BeginPlay AddMarker: on the host's own map
local hw_lab, hw_camp = register(HW, HW.map, m_lab), register(HW, HW.map, m_camp)
local hw_conv, hw_quar = register(HW, HW.map, m_conv), register(HW, HW.map, m_quar)
check(#H.events._st.camps == 4, "host: 4 camps kept")
local c_conv = H.events._st.camps[3]
check(c_conv.r == 2000 and H.events._st.camps[2].r == 3000, "radius: the spawner's own, else the class default 20 m")
check(c_conv.findable == true, "the marker is found by its path")
-- a random event (crashed helicopter) with its marker, relayed by its own hook
local sp_heli = new(HW, { "BP_PrefabSpawner_Dynamic_C", "BP_PrefabSpawner_C", "Actor" }, "BP_PrefabSpawner_Dynamic_C_17", {
    _loc = HELI, Role = 3, ["DynamicEvent?"] = true, ["Spawned?"] = true, Prefab = HW.apache })
local m_heli = new(HW, { "BP_Marker_C", "Actor" }, "BP_Marker_C_2147439000", { _loc = HELI,
    MarkerTitle = FText("Crashed Military Apache"), MarkerDescription = FText("y"), MarkerTexture = HW.lab_tex })
sp_heli._p.Marker = m_heli
local hw_heli = register(HW, HW.map, m_heli)
bind(HW); fire(HW, EVENT_FN, param(sp_heli))
check(#H.events._st.events == 1, "host: the random event kept")
-- the connected clients' lists (their characters seen, JOIN_WAIT_S later)
host_tick(); advance(6); host_tick()
local o1 = msgs(rpc._box, "WEVT")
check(#o1 >= 1 and o1[#o1]:find(key_of(LAB), 1, true) ~= nil and o1[#o1]:find(key_of(CAMP), 1, true) ~= nil,
    "the client got the camps' markers (WEVT o)")
deliver_all()
local cm_lab, cm_camp, cm_heli = client_marker(LAB), client_marker(CAMP), client_marker(HELI)
check(cm_lab ~= nil and cm_camp ~= nil and cm_heli ~= nil, "client: the markers placed")
-- the client's map: its markers registered; the laboratory twice (BeginPlay + sdc_players' late minimap)
local cw_lab1, cw_lab2 = register(CW, CW.map, cm_lab), register(CW, CW.map, cm_lab)
local cw_camp, cw_heli = register(CW, CW.map, cm_camp), register(CW, CW.map, cm_heli)
clear_box(rpc); clear_box(rpc2)

print("== K1. a client at the laboratory: 25 m nothing, 15 m its marker goes for everyone")
clear_logs()
rpc._pawn._p._loc = off(LAB, 2500)
advance(1); host_tick()
check(#msgs(rpc._box, "WEVT") == 0 and m_lab._valid and hw_lab._parented, "25 m (beyond the game's 20 m): nothing")
rpc._pawn._p._loc = off(LAB, 1500)
advance(1); host_tick()
local x1, x2 = msgs(rpc._box, "WEVT"), msgs(rpc2._box, "WEVT")
check(#x1 == 1 and x1[1] == "SDC1|WEVT|x|" .. key_of(LAB) and #x2 == 1 and x2[1] == x1[1],
    "WEVT x with the laboratory to every client (the far one too)")
check(not hw_lab._parented and not m_lab._valid, "host: its widget off the map, its BP_Marker destroyed")
check(hw_camp._parented and m_camp._valid and hw_conv._parented and hw_quar._parented, "host: the other camps' markers stay")
check(hw_heli._parented and m_heli._valid, "host: the random event's marker stays")
check(logged("host", "events: camp 'Abandoned Laboratory Research Tents' (Prefab_LabResearchTents1_C at 115194,-99209,1527) visited: BP_PlayerController_C_1 came within 15 m (the game's discovery radius 20 m); its map marker taken off for everyone: here 1 map widget(s) off, its marker destroyed, on 2 client(s) (WEVT x)") ~= nil,
    "host log line")
advance(1); host_tick()
check(#msgs(rpc._box, "WEVT") == 1, "told once")

print("== K2. the client: its copy goes (both widgets), a stale list places nothing")
clear_logs()
deliver_all()
check(not cw_lab1._parented and not cw_lab2._parented and not cm_lab._valid, "client: both widgets off, the marker destroyed")
check(cw_camp._parented and cm_camp._valid and cw_heli._parented and cm_heli._valid, "client: the others stay")
check(logged("client", "events: the host's camp at 115194,-99209,1527 was visited by a player of the group: its map marker taken off here (2 map widget(s) off, the marker destroyed)") ~= nil,
    "client log line")
local n_sp = #CW.spawned
bind(CW); C.events._t.on_wevt({ "o", "Prefab_LabResearchTents1_C>" .. key_of(LAB) .. ">" .. LAB_TEX:gsub("^/Game/", "") .. ">T>D>3.5,3.5>1,1,1,1>0" })
check(#CW.spawned == n_sp, "client: a stale WEVT o of the visited camp places no marker")
check(logged("client", "camp visited by the group already: no map marker") ~= nil, "client log: why")
bind(CW); C.events._t.on_wevt({ "x", key_of(LAB) })
check(C.events.stats.gone == 1, "the same WEVT x again: nothing more")

print("== K3. a joiner's list leaves the visited camp out")
clear_logs()
WORLD = HW
local rpc3 = remote(3, FAR)
HW.pcs[4] = rpc3
HS.remote_pcs = { rpc, rpc2, rpc3 }
advance(1); host_tick(); advance(6); host_tick()
local j = msgs(rpc3._box, "WEVT")
check(#j == 1 and j[1]:find("SDC1|WEVT|o|", 1, true) == 1 and j[1]:find(key_of(LAB), 1, true) == nil
    and j[1]:find(key_of(CAMP), 1, true) ~= nil and j[1]:find(key_of(HELI), 1, true) ~= nil,
    "joiner: the other camps and the random event, not the laboratory")
check(logged("host", "BP_PlayerController_C_3 joined: the map markers of 3 camp(s) of the host sent (WEVT o)") ~= nil,
    "host log: 3 camps to the joiner")

print("== K4. the host itself within the camp's own radius (30 m)")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
HW.pawn._p._loc = off(CAMP, 2800)
advance(1); host_tick()
check(not hw_camp._parented and not m_camp._valid, "host: the camp's widget and marker go")
check(#msgs(rpc._box, "WEVT") == 1 and msgs(rpc._box, "WEVT")[1] == "SDC1|WEVT|x|" .. key_of(CAMP), "clients told")
check(logged("host", "visited: the host came within 28 m (the game's discovery radius 30 m)") ~= nil, "host log: the host")
HW.pawn._p._loc = { X = 1000, Y = 1000, Z = 0 }
deliver_all()
check(not cw_camp._parented and not cm_camp._valid, "client: the camp's marker goes")

print("== K5. after a remote player's respawn the game's own discovery leaves the host's widget: taken off")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
-- the index pass notes the host's widget of each camp (every 5 s, no visit in
-- that pass); the host drives up to the convoy: 30 m away at that pass
HW.pawn._p._loc = off(CONVOY, 3000)
advance(H.events._t.INDEX_S + 1); host_tick()
check(c_conv.waddr ~= nil and c_conv.waddr[1] == hw_conv._addr, "host: the convoy's widget on the host's map noted")
check(c_conv.gone == nil, "(30 m: beyond its 20 m, no visit)")
-- a client respawns: the game instance's loop re-adds every BP_Marker to its off-screen map (sdc_respawn scope)
local offmap = new_map(HW, "MapWidget_C_remote")
local off_conv = register(HW, offmap, m_conv)
check(m_conv._p.Marker == off_conv and hw_conv._parented, "the marker's `Marker` names the off-screen widget now")
-- the host drives through; the game's DistanceToPrefab (2-6 s) comes before
-- the mod's pass; at the pass the host is 90 m on (beyond 20 + 60 m now:
-- within them at the last pass)
game_remove(m_conv)
check(hw_conv._parented and not m_conv._valid, "(the game's removal left the host's widget on the map)")
HW.pawn._p._loc = off(CONVOY, -9000)
advance(1); host_tick()
check(not hw_conv._parented, "host: the noted widget taken off")
check(msgs(rpc._box, "WEVT")[1] == "SDC1|WEVT|x|" .. key_of(CONVOY), "clients told")
check(logged("host", "visited: its marker went on the host (the game's own discovery: the host was within its radius); its map marker taken off for everyone: here 1 map widget(s) off (its marker was gone already)") ~= nil,
    "host log line")
HW.pawn._p._loc = { X = 1000, Y = 1000, Z = 0 }

print("== K6. dead players do not count; the host on its death screen")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
rpc2._pawn._p["PlayerDead?"] = true
rpc2._pawn._p._loc = off(QUAR, 500)
advance(1); host_tick()
check(m_quar._valid and hw_quar._parented and #msgs(rpc._box, "WEVT") == 0, "a dead client at the tents: nothing")
-- the host dies (AfterDeath UnPossess: no character, no map); the client comes to life there
local hpawn = HW.pawn
HW.pc._p.Pawn = nil
rpc2._pawn._p["PlayerDead?"] = false
advance(1); host_tick()
check(not m_quar._valid and #msgs(rpc._box, "WEVT") == 1, "host on its death screen: the marker still goes, clients told")
check(logged("host", "visited: BP_PlayerController_C_2 came within 5 m") ~= nil
    and logged("host", "here 0 map widget(s) off, its marker destroyed") ~= nil, "host log (no map now)")
-- the respawn: the game re-adds the BP_Markers that exist (the visited ones are gone)
local newmap = new_map(HW, "MapWidget_C_1")
HW.pc._p.Pawn = hpawn
hpawn._p.MinimapSystemComponent._p.MapWidget = newmap
local readded = 0
for _, a in ipairs(FindAllOf("BP_Marker_C")) do register(HW, newmap, a); readded = readded + 1 end
check(readded == 1 and #widgets_of(newmap, m_heli) == 1, "the respawn loop finds only the random event's marker")
rpc2._pawn._p._loc = { X = 3000, Y = 3000, Z = 0 }

print("== K7. a random event's marker with a player on it: untouched")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
rpc._pawn._p._loc = off(HELI, 100)
advance(1); host_tick()
check(m_heli._valid and #msgs(rpc._box, "WEVT") == 0, "the helicopter's marker stays, nothing sent")
rpc._pawn._p._loc = FAR

print("== K8. a marker not found by its path; world_prefabs off")
clear_logs()
local sp_hid = camp_spawner(HW, "BP_PrefabSpawner_C_37", HIDDEN, HW.camp, "Abandoned Camp", 2000)
local m_hid = spawn_camp(HW, sp_hid, { unfindable = true })
local c_hid = camp_at(HIDDEN)
check(c_hid ~= nil and c_hid.findable == false, "kept, not findable by its path")
advance(1); host_tick()
check(c_hid.gone == nil and m_hid._valid, "not found by path is no visit")
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)   -- (its WEVT o to the connected clients)
H.off.world_prefabs = true
rpc._pawn._p._loc = off(HIDDEN, 100)
advance(1); host_tick()
check(c_hid.gone == nil and #msgs(rpc._box, "WEVT") == 0, "world_prefabs off: no pass")
H.off.world_prefabs = nil
advance(1); host_tick()
check(c_hid.gone ~= nil and msgs(rpc._box, "WEVT")[1] == "SDC1|WEVT|x|" .. key_of(HIDDEN),
    "on again: a client there visits it, the clients are told")
check(logged("host", "its marker NOT found by its path: it may stay on the host's map") ~= nil, "host log says so")
rpc._pawn._p._loc = FAR

print("== K9. the host respawns (a new map): the widgets noted again there; a later visit takes the host's off")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
local P9 = { X = -150000, Y = -150000, Z = 1100 }
local sp9 = camp_spawner(HW, "BP_PrefabSpawner_C_61", P9, HW.camp, "Abandoned Camp", 2000)
local m9 = spawn_camp(HW, sp9)
local hw9 = register(HW, newmap, m9)
local c9 = camp_at(P9)
advance(H.events._t.INDEX_S + 1); host_tick()
check(c9 ~= nil and c9.waddr ~= nil and c9.waddr[1] == hw9._addr, "host: the camp's widget noted on the host's map")
-- the host dies and respawns: a new map; the game instance's loop re-adds every BP_Marker there
local map3 = new_map(HW, "MapWidget_C_2")
hpawn._p.MinimapSystemComponent._p.MapWidget = map3
bind(HW); for _, a in ipairs(FindAllOf("BP_Marker_C")) do register(HW, map3, a) end
local hw9b = widgets_of(map3, m9)[1]
advance(H.events._t.INDEX_S + 1); host_tick()
check(hw9b ~= nil and c9.waddr ~= nil and c9.waddr[1] == hw9b._addr, "host: noted again on the new map")
-- a client respawns (the marker's `Marker` names its off-screen widget); the
-- host comes from 90 m (beyond 20 + 60 m at that pass), the game's own
-- discovery takes the marker, the host is 40 m on at the next pass
register(HW, new_map(HW, "MapWidget_C_remote2"), m9)
HW.pawn._p._loc = off(P9, 9000)
advance(1); host_tick()
check(m9._valid and c9.gone == nil, "(the host 90 m away: no visit)")
game_remove(m9)
HW.pawn._p._loc = off(P9, -4000)
advance(1); host_tick()
check(c9.gone ~= nil and hw9b._parented == false, "host: its widget on the new map taken off")
local x9 = msgs(rpc._box, "WEVT")
check(x9[#x9] == "SDC1|WEVT|x|" .. key_of(P9), "clients told")
HW.pawn._p._loc = { X = 1000, Y = 1000, Z = 0 }

print("== K10. a camp whose widget the host's map never shows: looked for 6 times there, again on the next map")
clear_logs()
local P10 = { X = -160000, Y = 160000, Z = 900 }
local sp10 = camp_spawner(HW, "BP_PrefabSpawner_C_62", P10, HW.camp, "Abandoned Camp", 2000)
local m10 = spawn_camp(HW, sp10)   -- (no widget of it on the host's map)
local c10 = camp_at(P10)
local tries = H.events._t.INDEX_TRIES
local w0 = map3._arr.walks
for _ = 1, 3 * tries do advance(H.events._t.INDEX_S + 1); host_tick() end
check(map3._arr.walks - w0 == tries and c10.wkey == nil,
    "the map's list walked " .. tries .. " times for it, then no more (" .. (map3._arr.walks - w0) .. ")")
-- the host's next map (a respawn): looked for again; the respawn loop added it there
local map4 = new_map(HW, "MapWidget_C_3")
hpawn._p.MinimapSystemComponent._p.MapWidget = map4
bind(HW); for _, a in ipairs(FindAllOf("BP_Marker_C")) do register(HW, map4, a) end
advance(H.events._t.INDEX_S + 1); host_tick()
check(map4._arr.walks == 1 and c10.waddr ~= nil and c10.waddr[1] == widgets_of(map4, m10)[1]._addr,
    "a new map: looked for again and noted")

print("== K11. a camp at X -0.3: the same key on both machines ('0', not '-0')")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
local NZ = { X = -0.3, Y = 170000, Z = 1200 }
local NZK = "0,170000,1200"
local sp11 = camp_spawner(HW, "BP_PrefabSpawner_C_63", NZ, HW.camp, "Zero Camp", 2000)
local m11 = spawn_camp(HW, sp11)
register(HW, map4, m11)
advance(1); host_tick()
local o11 = msgs(rpc._box, "WEVT")
check(#o11 == 1 and o11[1]:find(">" .. NZK .. ">", 1, true) ~= nil and o11[1]:find(">-0,", 1, true) == nil,
    "WEVT o: its key '" .. NZK .. "'")
deliver_all()
local cm11
for _, a in ipairs(CW.spawned) do if a._chain[1] == "BP_Marker_C" and a._p._loc.Y == NZ.Y then cm11 = a end end
check(cm11 ~= nil and cm11._valid, "client: its marker placed")
rpc._pawn._p._loc = off(NZ, 500)
advance(1); host_tick()
check(msgs(rpc._box, "WEVT")[1] == "SDC1|WEVT|x|" .. NZK, "WEVT x with the same key")
deliver_all()
check(cm11 ~= nil and cm11._valid == false, "client: its marker taken off")
rpc._pawn._p._loc = FAR

print("== K12. a client with world_events_sync off: WEVT x still takes its marker off")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
local P12 = { X = 160000, Y = 160000, Z = 1000 }
local sp12 = camp_spawner(HW, "BP_PrefabSpawner_C_64", P12, HW.camp, "Abandoned Convoy", 2000)
local m12 = spawn_camp(HW, sp12)
register(HW, map4, m12)
advance(1); host_tick()
deliver_all()
local cm12 = client_marker(P12)
check(cm12 ~= nil and cm12._valid, "client: its marker placed (sync on)")
C.off.world_events_sync = true
rpc._pawn._p._loc = off(P12, 500)
advance(1); host_tick()
deliver_all()
check(cm12 ~= nil and cm12._valid == false and C.events._st.gone[key_of(P12)] == true,
    "client (sync off now): its marker taken off, the camp noted as visited")
C.off.world_events_sync = nil
rpc._pawn._p._loc = FAR

print("== K13. a marker still waiting for this world's controller: WEVT x, then it is never placed")
clear_logs()
local P13 = { X = -170000, Y = 10000, Z = 1300 }
local lp0 = CW.pc._p.Player
CW.pc._p.Player = nil              -- (still loading: no local controller yet)
local n13 = #CW.spawned
bind(CW); C.events._t.on_wevt({ "o", "Prefab_AbandonedCamp_C>" .. key_of(P13) .. ">" .. LAB_TEX:gsub("^/Game/", "") .. ">Abandoned Camp>D>3.5,3.5>1,1,1,1>0" })
check(C.events._st.pend[key_of(P13)] ~= nil and #CW.spawned == n13, "(its marker waits for the controller)")
bind(CW); C.events._t.on_wevt({ "x", key_of(P13) })
check(C.events._st.pend[key_of(P13)] == nil, "WEVT x: it waits no more")
CW.pc._p.Player = lp0
client_tick(); client_tick()
check(#CW.spawned == n13, "the controller there: nothing placed")

print("== K14. the world closes (DestroyAllActors: every BP_Marker_C) before the load's reset")
clear_logs()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
local P14 = { X = 60000, Y = -160000, Z = 1000 }
local sp14 = camp_spawner(HW, "BP_PrefabSpawner_C_65", P14, HW.lab, "Abandoned Laboratory Research Tents", 2000)
register(HW, map4, spawn_camp(HW, sp14))
advance(1); host_tick()            -- (its WEVT o)
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
local vis0, open0 = H.events.stats.visited, open_camps()
-- the host quits to the menu from its pause screen (alive, far from every
-- camp): GameFunctionLibrary.DestroyAllActors, then the load
bind(HW); for _, a in ipairs(FindAllOf("BP_Marker_C")) do a:K2_DestroyActor() end
advance(1); host_tick()
check(#msgs(rpc._box, "WEVT") == 0 and #msgs(rpc2._box, "WEVT") == 0 and #msgs(rpc3._box, "WEVT") == 0, "no WEVT x")
check(H.events.stats.visited == vis0 and logged("host", "visited") == nil, "no visit, no 'visited' line")
check(open0 == 2 and open_camps() == 0 and camp_at(P14) == nil and camp_at(P10) == nil,
    "the 2 camps whose markers went: dropped from the list")
check(logged("host", "events: the map markers of 2 camp(s) went on the host with nobody near them") ~= nil, "host log: one line")
-- the host's body (dead, still possessed) 40 m from a camp when the world goes: no visit either
clear_logs()
local P14b = { X = 70000, Y = -170000, Z = 1000 }
local sp14b = camp_spawner(HW, "BP_PrefabSpawner_C_66", P14b, HW.camp, "Abandoned Camp", 2000)
register(HW, map4, spawn_camp(HW, sp14b))
hpawn._p["PlayerDead?"] = true
hpawn._p._loc = off(P14b, 4000)
advance(1); host_tick()
clear_box(rpc); clear_box(rpc2); clear_box(rpc3)
bind(HW); for _, a in ipairs(FindAllOf("BP_Marker_C")) do a:K2_DestroyActor() end
advance(1); host_tick()
check(#msgs(rpc._box, "WEVT") == 0 and H.events.stats.visited == vis0 and camp_at(P14b) == nil,
    "the host dead 40 m from it: dropped, not a visit, nothing sent")
hpawn._p["PlayerDead?"] = nil
hpawn._p._loc = { X = 1000, Y = 1000, Z = 0 }

print("== K15. reset, status, errors")
bind(HW); local sh = H.events.status_line()
bind(CW); local sc = C.events.status_line()
check(sh:find("visited=8", 1, true) ~= nil, "host status: visited")
check(sc:find("camps_gone=4", 1, true) ~= nil, "client status: camps gone")
bind(HW); H.events.reset("test")
bind(CW); C.events.reset("test")
check(#H.events._st.camps == 0 and next(C.events._st.gone) == nil, "reset: a new world rolls the camps again")
check(errors == 0, "no hook / handler errors (" .. errors .. ")")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
