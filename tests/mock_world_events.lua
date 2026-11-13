-- Mock harness: the game's random world events (sdc_events, WEVT; sdc_notes
-- shown_since / stale_note; sdc_world's hand-over points). The host's
-- crashed helicopter (BP_PrefabSpawner_Dynamic.SpawnRandomEvent: the prefab
-- with its BeginPlay notice, the BP_Marker, the spawn sound) reaches the
-- clients: the sound only within its range (played there with its own
-- attenuation), the game's notice through sdc_notes NOTE (shown once), the
-- map marker spawned the spawner's way, the wreck made always relevant when
-- sdc_world replicates it; a joiner gets the markers; the wreck's notice
-- when it reaches a client later is taken off; a client's own roll is
-- blocked and silent; world_events_sync off: nothing of it. E10: a placed
-- camp's map marker (the abandoned laboratory research tents: SpawnMarker at
-- load) reaches connected clients, joiners, one the hook missed, a new
-- player at a left one's address; none of them while the host's
-- world_prefabs is off; one the host found is not in a later joiner's list.
-- (A visited camp's marker going for everyone: mock_events_camps.lua.)
-- usage: lua mock_world_events.lua <scripts dir>
-- (harness core copied from mock_world_landmine.lua / mock_notes_route.lua)
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
                             _valid = true, _calls = {} }, Obj)
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
NotifyOnNewObject = function(path, fn) WORLD.watch[#WORLD.watch + 1] = { path = path, fn = fn } end
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
LoadAsset = function(path) WORLD.loads[#WORLD.loads + 1] = path; return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(ms, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

-- Both machines run in one Lua state: the modules that others reach through
-- package.loaded (sdc_events from sdc_world / sdc_notes) are the world's own.
local MODS = {}
local function bind(w)
    WORLD = w
    local m = MODS[w.id]
    if m then
        package.loaded["sdc_events"], package.loaded["sdc_notes"], package.loaded["sdc_world"] = m.events, m.notes, m.world
    end
end

local function run_timers(w)
    bind(w)
    for _ = 1, 3 do
        local t = w.timers
        w.timers = {}
        for _, fn in ipairs(t) do fn() end
    end
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
local function notify(w, path, o)
    local prev = WORLD
    bind(w)
    for _, e in ipairs(w.watch) do if e.path == path then e.fn(o) end end
    if prev then bind(prev) end
end

-- ---------------------------------------------------------------- paths
local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local GFL_FN = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"
local CHAR_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:CreateNotificationUI"
local FWD_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_ForwardInteract"
local NEST_FN = "/Game/Infestation/BP_Infestation.BP_Infestation_C:Damage_Object"
local GPC_FN = "/Script/Engine.GameplayStatics:GetPlayerController"
local SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local EVENT_FN = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnRandomEvent"
local PREFAB_P = "/Game/Prefabs/PrefabMaster.PrefabMaster_C"
local MARKER_P = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_Marker.BP_Marker_C"
local CUE_P = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_deep_low_1_Cue.explosion_deep_low_1_Cue"
local NUKE_P = "/Game/Audio/Attenuation/Nuke.Nuke"
local HELI_TEX = "/Game/UI/Textures/Survival-UI-Bundle/Rhombus/512x512/Helicopter.Helicopter"
local JEEP_TEX = "/Game/UI/Textures/Survival-UI-Bundle/Rhombus/512x512/Jeep.Jeep"
local APACHE_P = "/Game/Prefabs/CrashedHelicopters/Prefab_CrashedApache01.Prefab_CrashedApache01_C"
local TRUCK_P = "/Game/Prefabs/AbandonedTrucks/Prefab_AbandonedMilitarySuppliesTruck_HumanAI.Prefab_AbandonedMilitarySuppliesTruck_HumanAI_C"
local HELI_NOTE = "A helicopter has crashed in The Valley..."
local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, watch = {}, loads = {},
             sounds = {}, spawned = {} }
end
local HW, CW = world("host"), world("client")

-- the HUD's notification list (NotificationParentWidget.Notification @0-791)
local function make_hud(w)
    local box
    box = new(w, { "VerticalBox" }, "VerticalBox_31", {}, {
        GetChildrenCount = function() return #box._kids end,
        GetChildAt = function(_, i) return box._kids[i + 1] end,
    })
    box._kids = {}
    local parent = new(w, { "NotificationParentWidget_C" }, "NotificationUI", { VerticalBox_31 = box })
    local hud = new(w, { "HUD_Game_C", "HUD" }, "HUD_Game_C_0", { NotificationUI = parent })
    function hud.add(_, text, icon, col, delay, force)
        if not force then
            for _, k in ipairs(box._kids) do
                if k._p.NotificationDetailsStruct[MSG]:ToString() == text then return false end
            end
        end
        local wd
        wd = new(w, { "NotficationUI_C" }, "NotficationUI_C_" .. (#box._kids + 1), {
            NotificationDetailsStruct = { [MSG] = FText(text), Icon = icon, Col = col, Delay = delay },
        }, {
            RemoveFromParent = function()
                for i, k in ipairs(box._kids) do if k == wd then table.remove(box._kids, i) break end end
                wd._removed = true
            end,
        })
        box._kids[#box._kids + 1] = wd
        return true
    end
    hud._box = box
    return hud
end
local function on_screen(w, text)
    local n = 0
    for _, k in ipairs(w.hud._box._kids) do
        if k._p.NotificationDetailsStruct[MSG]:ToString() == text then n = n + 1 end
    end
    return n
end

-- the game's CreateNotificationUI: player 0 (sdc_ctx's real pre-hook), its HUD, the post-hooks
local function game_note(w, text, icon, col, delay, force, wco)
    local prev = WORLD
    bind(w)
    local idx = param(0)
    for _, h in ipairs(w.hooks[GPC_FN] or {}) do if h.pre then h.pre(param(w.gps), param(wco), idx) end end
    local pc = w.pcs[idx._v() + 1]
    local hud = pc and pc._p._hud
    if hud then hud:add(text, icon, col, delay, force) end
    for _, h in ipairs(w.hooks[GFL_FN] or {}) do
        local r = h.pre(param(w.gfl), param(FText(text)), param(icon), param(col), param(delay), param(force), param(wco))
        assert(r == nil, "hook returned a value")
    end
    if prev then bind(prev) end
end

local function engine(w)
    WORLD = w
    -- GameplayStatics: native pre-hooks run first (UE4SS), then the call
    w.gps = new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        PlaySoundAtLocation = function(_, wco, snd, loc, rot, vol, pitch, start, att)
            w.sounds[#w.sounds + 1] = { wco = wco, snd = snd, loc = loc, vol = vol, att = att }
        end,
        BeginDeferredActorSpawnFromClass = function(gps, wco, cls, tf, coll, owner, scale)
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
    w.gfl = new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(_, text, icon, col, delay, force, wco)
            game_note(w, type(text) == "table" and text:ToString() or text, icon, col, delay, force, wco)
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    for _, p in ipairs({ GFL_FN, CHAR_FN, FWD_FN, NEST_FN, EVENT_FN }) do new(w, { "Function" }, p:match(":(.+)$"), {}, {}, p) end
    -- in memory on every machine: hard references of the spawner class / level
    local nuke = new(w, { "SoundAttenuation" }, "Nuke", {}, {}, NUKE_P)
    w.cue = new(w, { "SoundCue" }, "explosion_deep_low_1_Cue", { MaxDistance = 350000, AttenuationSettings = nuke }, {}, CUE_P)
    w.heli_tex = new(w, { "Texture2D" }, "Helicopter", {}, {}, HELI_TEX)
    w.marker_cls = new(w, { "BlueprintGeneratedClass" }, "BP_Marker_C", {}, {}, MARKER_P)
    w.marker_cls._actor = true
    w.apache = new(w, { "BlueprintGeneratedClass" }, "Prefab_CrashedApache01_C", {}, {}, APACHE_P)
    w.truck = new(w, { "BlueprintGeneratedClass" }, "Prefab_AbandonedMilitarySuppliesTruck_HumanAI_C", {}, {}, TRUCK_P)
    -- the local player
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    w.hud = make_hud(w)
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
        { Player = lp, _local = true, _hud = w.hud }, {
            ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
            GetHUD = function(self) return self._p._hud end,
        })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _local = true, _loc = { X = 0, Y = 0, Z = 0 } })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
engine(HW)
engine(CW)

-- the event's place; the near client 1 km from it, the far one 5 km, the host 2 km
local E = { X = 173901, Y = 22718, Z = 1931 }
local function at(dx) return { X = E.X + dx, Y = E.Y, Z = E.Z } end
HW.pawn._p._loc = at(200000)
CW.pawn._p._loc = at(100000)

-- the clients' controllers and characters on the host
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
    return rpc
end
local rpc = remote(1, at(100000))
local rpc_far = remote(2, at(500000))
HW.pcs[2], HW.pcs[3] = rpc, rpc_far

-- ---------------------------------------------------------------- load modules per world
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
    m.world = require("sdc_world")
    m.notes = require("sdc_notes")
    m.events = require("sdc_events")
    return m
end
local HS = { role = "host", remote_pcs = { rpc, rpc_far }, remote = {}, map = "LongdownValley" }
local H = load_mods(HW)
H.world.install(HS)
H.notes.install(HS)
H.events.install(HS)
MODS.host = H
WORLD = HW; H.ctx.tick({ rpc, rpc_far })   -- player-0 redirection on (a client is connected)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
local C = load_mods(CW)
C.world.install(CS)
C.notes.install(CS)
C.events.install(CS)
MODS.client = C
WORLD = CW; C.ctx.tick_client(true)

local function logged(id, pat)
    for _, l in ipairs(logs[id]) do if l:find(pat, 1, true) then return l end end
    return nil
end
local function clear_logs() logs.host, logs.client = {}, {} end
-- empties a client's message list in place (its ClientMessage keeps
-- appending to the same table: a new table would no longer see them)
local function clear_box(p) for i = #p._box, 1, -1 do p._box[i] = nil end end
local function msgs(box, kind)
    local out = {}
    for _, m in ipairs(box) do if m:find("|" .. kind .. "|", 1, true) then out[#out + 1] = m end end
    return out
end
-- host -> the near client's machine
local function deliver_all()
    local list = {}
    for _, m in ipairs(rpc._box) do list[#list + 1] = m end
    for i = #rpc._box, 1, -1 do rpc._box[i] = nil end
    bind(CW)
    for _, msg in ipairs(list) do
        local kind, f = C.net.decode(msg)
        local h = C.net.handlers[kind]
        if h then h(f, CW.pc) end
    end
    return list
end
local function ticks()
    bind(HW); H.notes.tick(); H.events.tick()
    bind(CW); C.notes.tick(); C.events.tick()
end

-- A spawner of the level (the same path on both machines).
local function spawner(w, name, loc, prefab_cls, sound, marker)
    bind(w)
    return new(w, { "BP_PrefabSpawner_Dynamic_C", "BP_PrefabSpawner_C", "Actor" }, name, {
        _loc = loc, Role = 3, ["DynamicEvent?"] = true, ["Spawned?"] = false, Prefab = prefab_cls,
        SoundOnSpawn = sound, ["Marker?"] = marker ~= nil, ["Marker Texture"] = marker and marker.tex,
        ["Marker Title"] = marker and FText(marker.title), ["Marker Description"] = marker and FText(marker.desc),
    }, {})
end

-- BP_PrefabSpawner.SpawnRandomEvent as the game runs it (@672, @15, @46),
-- then UE4SS's post-hook.
local function spawn_random_event(w, sp, opts)
    opts = opts or {}
    bind(w)
    if opts.area_fail then fire(w, EVENT_FN, param(sp)); return nil end
    local tf = { Translation = sp._p._loc }
    local cp = param(sp._p.Prefab)
    fire(w, SPAWN_FN, param(w.gps), param(sp), cp, param(tf))
    local cls = cp._v()
    local prefab
    if cls == w.apache or cls == w.truck then
        prefab = new(w, { cls._name, "PrefabMaster_C", "Actor" }, cls._name .. "_" .. (2147410539 - #w.objects),
            { _loc = { X = sp._p._loc.X, Y = sp._p._loc.Y, Z = sp._p._loc.Z }, Role = 3, FoliageRemover = w.gps }, {
                SetReplicates = function(self, b) self._p.bReplicates = b end,
                ForceNetUpdate = function(self) self._net = (self._net or 0) + 1 end,
                GetAllChildActors = function() end,
            })
        notify(w, PREFAB_P, prefab)
        -- the prefab's BeginPlay (inside FinishSpawningActor)
        if cls == w.apache then w.gfl:CreateNotificationUI(FText(HELI_NOTE), nil, WHITE, 4, false, prefab) end
    end
    sp._p["Spawned?"] = true
    if sp._p["Marker?"] then
        local mp = param(w.marker_cls)
        fire(w, SPAWN_FN, param(w.gps), param(sp), mp, param(tf))
        if mp._v() == w.marker_cls then
            sp._p.Marker = new(w, { "BP_Marker_C", "Actor" }, "BP_Marker_C_" .. (2147420000 + #w.objects), {
                _loc = sp._p._loc, MarkerTexture = sp._p["Marker Texture"], MarkerTitle = sp._p["Marker Title"],
                MarkerDescription = sp._p["Marker Description"], ["Texture Size"] = { X = 3.5, Y = 3.5 },
                Color = { R = 0.505208, G = 0.169744, B = 0.034207, A = 1 }, ["AddMarkerToCompass?"] = false })
        end
    end
    if sp._p.SoundOnSpawn and sp._p.SoundOnSpawn._valid then
        w.gps:PlaySoundAtLocation(sp, sp._p.SoundOnSpawn, sp._p._loc, {}, 1, 1, 0, nil)
    end
    fire(w, EVENT_FN, param(sp))
    return prefab
end

local APACHE_MK = { tex = HELI_TEX, title = "Crashed Military Apache", desc = "A crashed apache that has flown into The Valley." }

print("== E0. hooks, handlers, install lines")
bind(HW); H.world._t.try_hooks(true); ticks()
bind(CW); C.world._t.try_hooks(true); ticks()
check(HW.hooks[EVENT_FN] ~= nil and CW.hooks[EVENT_FN] ~= nil, "SpawnRandomEvent post-hook on both machines")
check(#HW.hooks[EVENT_FN] == 1, "registered once")
check(H.net.handlers.WEVT ~= nil and C.net.handlers.WEVT ~= nil, "WEVT handlers")
check(logged("host", "sound relay WEVT") ~= nil and logged("host", "events: installed (world_events_sync=true)") ~= nil, "install lines")

print("== E1. the host's crashed Apache: sound to the near client, notice and marker to both")
clear_logs()
local hsp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_17", E, HW.apache, HW.cue, { tex = HW.heli_tex, title = APACHE_MK.title, desc = APACHE_MK.desc })
local csp = spawner(CW, "BP_PrefabSpawner_Dynamic_C_17", E, CW.apache, CW.cue, { tex = CW.heli_tex, title = APACHE_MK.title, desc = APACHE_MK.desc })
local hs0 = #HW.sounds
local wreck = spawn_random_event(HW, hsp)
check(#HW.sounds == hs0 + 1 and on_screen(HW, HELI_NOTE) == 1, "host: the game's own sound and notice")
local near = msgs(rpc._box, "WEVT")
local far = msgs(rpc_far._box, "WEVT")
check(#near == 1 and near[1]:find("SDC1|WEVT|n|Prefab_CrashedApache01_C|173901,22718,1931|Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_deep_low_1_Cue.explosion_deep_low_1_Cue|", 1, true) ~= nil,
    "near client: WEVT with the sound path")
check(#far == 1 and far[1]:find("SDC1|WEVT|n|Prefab_CrashedApache01_C|173901,22718,1931||", 1, true) ~= nil, "far client: WEVT without the sound")
check(near[1]:find("UI/Textures/Survival-UI-Bundle/Rhombus/512x512/Helicopter.Helicopter>Crashed Military Apache>A crashed apache that has flown into The Valley.>3.500,3.500>0.5052,0.1697,0.0342,1.0000>0", 1, true) ~= nil,
    "the marker as the host's BP_Marker shows it")
check(#msgs(rpc._box, "NOTE") == 1 and #msgs(rpc_far._box, "NOTE") == 1 and msgs(rpc._box, "NOTE")[1]:find(HELI_NOTE, 1, true),
    "the game's notice to both through sdc_notes NOTE")
check(on_screen(HW, HELI_NOTE) == 1, "the notice stays on the host's screen")
check(logged("host", "events: random event on the host: Prefab_CrashedApache01_C by BP_PrefabSpawner_Dynamic_C_17 at 173901,22718,1931 (sound explosion_deep_low_1_Cue carries 3500 m, Nuke; the game's notice 'A helicopter has crashed in The Valley...'; map marker 'Crashed Military Apache')") ~= nil,
    "host log: the event")
check(logged("host", "WEVT to 2 client(s): sound explosion_deep_low_1_Cue to 1 (within 3505 m), not to BP_PlayerController_C_2 5000 m (beyond); the game's notice 'A helicopter has crashed in The Valley...' to 2 (sdc_notes NOTE); map marker 'Crashed Military Apache' to 2") ~= nil,
    "host log: what went to whom")
-- sdc_world's 200 ms flush replicates the wreck
run_timers(HW)
check(wreck._p.bReplicates == true and wreck._p.bAlwaysRelevant == true and (wreck._net or 0) >= 1, "the wreck replicates, always relevant")
check(logged("host", "made always relevant (replicated by world_prefabs)") ~= nil, "host log: the wreck")
clear_box(rpc_far)

print("== E2. the near client: sound, marker, the notice once")
clear_logs()
local cs0 = #CW.sounds
deliver_all()
check(#CW.sounds == cs0 + 1 and CW.sounds[#CW.sounds].snd == CW.cue and CW.sounds[#CW.sounds].loc.X == E.X
    and CW.sounds[#CW.sounds].att == nil and CW.sounds[#CW.sounds].vol == 1.0, "the game's cue at the spawner, its own attenuation")
local mk = CW.spawned[#CW.spawned]
check(mk and mk._chain[1] == "BP_Marker_C" and mk._finished and mk._p.MarkerTexture == CW.heli_tex
    and mk._p.MarkerTitle:ToString() == APACHE_MK.title and mk._p.MarkerDescription:ToString() == APACHE_MK.desc
    and math.abs(mk._p["Texture Size"].X - 3.5) < 1e-6 and math.abs(mk._p.Color.R - 0.5052) < 1e-3
    and mk._p["AddMarkerToCompass?"] == false and mk._p._loc.Y == E.Y, "BP_Marker_C spawned the spawner's way")
check(#CW.loads == 0, "nothing loaded synchronously on the client")
check(logged("client", "events: the host's random event Prefab_CrashedApache01_C at 173901,22718,1931 (1000 m from here): sound explosion_deep_low_1_Cue played here (1000 m away, it carries 3500 m, Nuke); map marker 'Crashed Military Apache' placed (texture Helicopter, finish ok=true)") ~= nil,
    "client log line")
-- the host's wreck replicates here 0.2 s later: its BeginPlay notice is the event's own
advance(0.2)
WORLD = CW
local copy = new(CW, { "Prefab_CrashedApache01_C", "PrefabMaster_C", "Actor" }, "Prefab_CrashedApache01_C_2147482100",
    { _loc = { X = E.X, Y = E.Y, Z = E.Z }, Role = 1, FoliageRemover = CW.gps })
CW.gfl:CreateNotificationUI(FText(HELI_NOTE), nil, WHITE, 4, false, copy)
check(on_screen(CW, HELI_NOTE) == 1, "the copy's own notice shown (the event's)")
advance(0.4); run_timers(CW)
check(on_screen(CW, HELI_NOTE) == 1, "the relayed NOTE not shown twice")
check(C.events.stats.stale == 0, "not counted as stale")

print("== E3. the wreck reaches the client again later: its notice is taken off")
clear_logs()
advance(120)
CW.hud._box._kids = {}          -- the old widget is long gone
copy._valid = false
local copy2 = new(CW, { "Prefab_CrashedApache01_C", "PrefabMaster_C", "Actor" }, "Prefab_CrashedApache01_C_2147482050",
    { _loc = { X = E.X, Y = E.Y, Z = E.Z }, Role = 1, FoliageRemover = CW.gps })
CW.gfl:CreateNotificationUI(FText(HELI_NOTE), nil, WHITE, 4, false, copy2)
check(on_screen(CW, HELI_NOTE) == 0, "taken off this screen")
check(C.notes._st.recent[HELI_NOTE] == nil, "not remembered as shown (a later relay is no duplicate)")
check(logged("client", "notes: 'A helicopter has crashed in The Valley...' (Prefab_CrashedApache01_C) raised here by the host's Prefab_CrashedApache01_C reaching this client through replication") ~= nil,
    "client log line (stale)")
-- the client's own object, a non-prefab: untouched
local mine_note = "Spawn Point Set"
CW.gfl:CreateNotificationUI(FText(mine_note), nil, WHITE, 2, false, CW.pc)
check(on_screen(CW, mine_note) == 1, "other notices untouched")

print("== E4. a player who joins later gets the markers")
clear_logs()
WORLD = HW
local rpc3 = remote(3, at(300000))
HS.remote_pcs = { rpc, rpc_far, rpc3 }
ticks()
check(#msgs(rpc3._box, "WEVT") == 0, "not before its character settled")
advance(6); ticks()
local j = msgs(rpc3._box, "WEVT")
check(#j == 1 and j[1]:find("SDC1|WEVT|o|Prefab_CrashedApache01_C>173901,22718,1931>UI/Textures", 1, true) ~= nil, "WEVT o (one list) with the marker, no sound")
check(#msgs(rpc3._box, "NOTE") == 0, "no notice for an old event")
check(#msgs(rpc._box, "WEVT") == 0 and #msgs(rpc_far._box, "WEVT") == 0, "the others got it with the event already")
check(logged("host", "BP_PlayerController_C_3 joined after 1 random event(s): their map markers sent (WEVT o)") ~= nil, "host log line (joiner)")
advance(6); ticks()
check(#msgs(rpc3._box, "WEVT") == 1, "sent once")
-- the same 'o' on a machine that has the marker: not placed twice
local n_spawned = #CW.spawned
bind(CW); C.net.handlers.WEVT(select(2, C.net.decode(j[1])), CW.pc)
check(#CW.spawned == n_spawned and logged("client", "map marker 'Crashed Military Apache' already here") ~= nil, "client: marker not placed twice")
HS.remote_pcs = { rpc, rpc_far }

print("== E5. an abandoned truck: marker only; nothing spawned: nothing sent")
clear_logs()
local tsp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_35", { X = -50000, Y = 120000, Z = 900 }, HW.truck, nil,
    { tex = nil, title = "Abandoned Truck", desc = "An abandoned supplies truck that carriers important supplies." })
spawn_random_event(HW, tsp)
local t1 = msgs(rpc._box, "WEVT")
check(#t1 == 1 and t1[1]:find("|n|Prefab_AbandonedMilitarySuppliesTruck_HumanAI_C|-50000,120000,900||>Abandoned Truck>", 1, true) ~= nil,
    "WEVT without sound, the marker without texture")
check(#msgs(rpc._box, "NOTE") == 0, "no notice (the truck has none)")
check(logged("host", "no spawn sound; no notice; map marker 'Abandoned Truck'") ~= nil, "host log (truck)")
cs0 = #CW.sounds
deliver_all()
check(#CW.sounds == cs0, "client: no sound")
check(logged("client", "no sound here (the event has none, or this player was beyond its range on the host); map marker 'Abandoned Truck' placed (texture the marker's default") ~= nil,
    "client: marker with the marker's own texture")
local esp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_2", { X = 9000, Y = 9000, Z = 0 }, HW.apache, HW.cue, nil)
spawn_random_event(HW, esp, { area_fail = true })
check(#msgs(rpc._box, "WEVT") == 0 and logged("host", "BP_PrefabSpawner_Dynamic_C_2's random event roll on the host spawned nothing") ~= nil,
    "the area check refused: nothing")
fire(HW, EVENT_FN, param(hsp))
check(#msgs(rpc._box, "WEVT") == 0, "the same spawner again: not relayed twice")

print("== E5b. a marker before this world's controller exists: placed by the tick")
clear_logs()
local lp0 = CW.pc._p.Player
CW.pc._p.Player = nil            -- (still loading: no local controller yet)
n_spawned = #CW.spawned
bind(CW); C.net.handlers.WEVT({ "o", "Prefab_AbandonedMilitarySuppliesTruck_HumanAI_C", "-7000,5000,100", "", ">Abandoned Truck>d>3.500,3.500>0.5052,0.1697,0.0342,1.0000>0" }, CW.pc)
check(#CW.spawned == n_spawned and next(C.events._st.pend) ~= nil, "waits")
ticks()
check(#CW.spawned == n_spawned, "still waits without a controller")
CW.pc._p.Player = lp0
ticks()
check(#CW.spawned == n_spawned + 1 and next(C.events._st.pend) == nil, "placed once the controller is there")
check(logged("client", "events: the host's event marker at -7000,5000,100: map marker 'Abandoned Truck' placed") ~= nil, "client log line (late marker)")
ticks()
check(#CW.spawned == n_spawned + 1, "not placed again")

print("== E6. the client's own event manager rolls: blocked and silent")
clear_logs()
local own = spawner(CW, "BP_PrefabSpawner_Dynamic_C_5", { X = 400000, Y = 0, Z = 0 }, CW.apache, CW.cue,
    { tex = CW.heli_tex, title = APACHE_MK.title, desc = APACHE_MK.desc })
cs0 = #CW.sounds
local n_sp = #CW.spawned
local p0 = #CW.objects
local own_prefab = spawn_random_event(CW, own)
check(own_prefab == nil and #CW.spawned == n_sp, "client: its own prefab and marker blocked (world_prefabs)")
check(#CW.sounds == cs0 and own._p.SoundOnSpawn == nil, "client: its spawn sound muted")
check(logged("client", "events: this client's own event manager rolled a random event at BP_PrefabSpawner_Dynamic_C_5 (Prefab_CrashedApache01_C; its spawn blocked by world_prefabs): its spawn sound explosion_deep_low_1_Cue muted here") ~= nil,
    "client log line (own roll)")
check(logged("client", "SpawnRandomEvent ran on this client") == nil,
    "client: the post-hook adds no third line for the same roll")
check(#CW.outbox == 0, "nothing sent to the host")
run_timers(CW)

print("== E7. no client connected: kept for joiners")
clear_logs()
HS.remote_pcs = {}
local lsp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_9", { X = 70000, Y = -3000, Z = 1200 }, HW.apache, HW.cue,
    { tex = HW.heli_tex, title = "Crashed Military Helicopter", desc = "x" })
spawn_random_event(HW, lsp)
check(logged("host", "no client connected; kept for players who join (its map marker 'Crashed Military Helicopter')") ~= nil, "host log line")
HS.remote_pcs = { rpc, rpc_far }
clear_box(rpc); clear_box(rpc_far)
-- (the clients were marked as seen; a later joiner would get both markers)

print("== E8. world_events_sync off: nothing of it")
clear_logs()
H.off.world_events_sync = true
C.off.world_events_sync = true
local osp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_11", { X = 10000, Y = 10000, Z = 0 }, HW.apache, HW.cue,
    { tex = HW.heli_tex, title = "Crashed Military Helicopter", desc = "x" })
spawn_random_event(HW, osp)
check(#msgs(rpc._box, "WEVT") == 0 and #msgs(rpc._box, "NOTE") == 0, "host: no WEVT, no notice relay")
local own2 = spawner(CW, "BP_PrefabSpawner_Dynamic_C_13", { X = 450000, Y = 0, Z = 0 }, CW.apache, CW.cue, nil)
cs0 = #CW.sounds
spawn_random_event(CW, own2)
check(#CW.sounds == cs0 + 1 and own2._p.SoundOnSpawn == CW.cue, "client: its own roll's sound as before")
CW.hud._box._kids = {}
local copy3 = new(CW, { "Prefab_CrashedApache01_C", "PrefabMaster_C", "Actor" }, "Prefab_CrashedApache01_C_2147482010",
    { _loc = { X = 1, Y = 2, Z = 3 }, Role = 1, FoliageRemover = CW.gps })
CW.gfl:CreateNotificationUI(FText(HELI_NOTE), nil, WHITE, 4, false, copy3)
check(on_screen(CW, HELI_NOTE) == 1, "client: the wreck's notice as before")
bind(CW); C.net.handlers.WEVT({ "n", "Prefab_CrashedApache01_C", "1,2,3", "", "" }, CW.pc)
check(logged("client", "not shown here (world_events_sync off here)") ~= nil, "client: WEVT ignored")
H.off.world_events_sync, C.off.world_events_sync = nil, nil
H.off.world_sync = true
local wsp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_15", { X = 20000, Y = 10000, Z = 0 }, HW.apache, HW.cue, nil)
spawn_random_event(HW, wsp)
check(#msgs(rpc._box, "WEVT") == 0, "world_sync off: nothing either")
H.off.world_sync = nil

print("== E10. placed camps (abandoned laboratory research tents): their map markers reach the clients")
-- BP_PrefabSpawner (DynamicEvent? off) at load: @226 Random Check ->
-- CheckSurroundingArea -> @328 the camp -> @583 SpawnMarker (@850 the
-- BP_Marker) -> UE4SS's post-hook of SpawnMarker. No sound, no notice.
clear_logs()
local MARKER_FN = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnMarker"
local LAB_TEX = "/Game/UI/Textures/Mock/LabMarker.LabMarker"
local LAB2_P = "/Game/Prefabs/Mock/Prefab_LabResearchTents2.Prefab_LabResearchTents2_C"
local BANDIT_P = "/Game/Prefabs/Mock/Prefab_SmallBanditCamp.Prefab_SmallBanditCamp_C"
local LAB_MK = { title = "Abandoned Laboratory Research Tent",
                 desc = "Tents setup by laboratory staff as they tried to subdue the infection." }
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    new(w, { "Function" }, "SpawnMarker", {}, {}, MARKER_FN)
    w.lab_tex = new(w, { "Texture2D" }, "LabMarker", {}, {}, LAB_TEX)
    w.lab2 = new(w, { "BlueprintGeneratedClass" }, "Prefab_LabResearchTents2_C", {}, {}, LAB2_P)
    w.bandit = new(w, { "BlueprintGeneratedClass" }, "Prefab_SmallBanditCamp_C", {}, {}, BANDIT_P)
end
local function camp_spawner(w, name, loc, prefab_cls, marker)
    bind(w)
    return new(w, { "BP_PrefabSpawner_C", "Actor" }, name, {
        _loc = loc, Role = 3, ["DynamicEvent?"] = false, ["Spawned?"] = false, Prefab = prefab_cls,
        ["Marker?"] = marker ~= nil, ["Marker Texture"] = marker and w.lab_tex,
        ["Marker Title"] = marker and FText(marker.title), ["Marker Description"] = marker and FText(marker.desc),
    }, {})
end
local function spawn_camp(w, sp, opts)
    opts = opts or {}
    bind(w)
    local tf = { Translation = sp._p._loc }
    local cp = param(sp._p.Prefab)
    fire(w, SPAWN_FN, param(w.gps), param(sp), cp, param(tf))
    if cp._v() ~= sp._p.Prefab then return nil end          -- blocked (a client's own roll): no marker either
    local cls = sp._p.Prefab
    local camp = new(w, { cls._name, "PrefabMaster_C", "Actor" }, cls._name .. "_" .. (2147475310 - #w.objects),
        { _loc = { X = sp._p._loc.X, Y = sp._p._loc.Y, Z = sp._p._loc.Z }, Role = 3 }, {
            SetReplicates = function(self, b) self._p.bReplicates = b end,
            ForceNetUpdate = function() end,
            GetAllChildActors = function() end,
        })
    if sp._p["Marker?"] then
        local mp = param(w.marker_cls)
        fire(w, SPAWN_FN, param(w.gps), param(sp), mp, param(tf))
        if mp._v() == w.marker_cls then
            sp._p.Marker = new(w, { "BP_Marker_C", "Actor" }, "BP_Marker_C_" .. (2147430000 + #w.objects), {
                _loc = sp._p._loc, MarkerTexture = sp._p["Marker Texture"], MarkerTitle = sp._p["Marker Title"],
                MarkerDescription = sp._p["Marker Description"], ["Texture Size"] = { X = 3.5, Y = 3.5 },
                Color = { R = 0.505208, G = 0.169744, B = 0.034207, A = 1 }, ["AddMarkerToCompass?"] = false })
        end
    end
    if not opts.no_hook then fire(w, MARKER_FN, param(sp)) end
    return camp
end
bind(HW); H.events.try_hooks(true)
bind(CW); C.events.try_hooks(true)
check(HW.hooks[MARKER_FN] ~= nil and #HW.hooks[MARKER_FN] == 1, "host: SpawnMarker post-hook, once")
check(CW.hooks[MARKER_FN] == nil, "client: no SpawnMarker hook (the host's only)")
check(#HW.hooks[EVENT_FN] == 1 and #CW.hooks[EVENT_FN] == 1, "SpawnRandomEvent still registered once")
check(logged("host", "events: hook BP_PrefabSpawner_C:SpawnMarker ok") ~= nil, "host log: the hook")
bind(HW); H.events.try_hooks(true)
check(#HW.hooks[MARKER_FN] == 1, "not registered twice")

-- the laboratory rolls on the host at load (clients connected, their lists went before)
local LAB = { X = -120000, Y = 85000, Z = 2500 }
local lsp_h = camp_spawner(HW, "BP_PrefabSpawner56", LAB, HW.lab2, LAB_MK)
local lab_camp = spawn_camp(HW, lsp_h)
check(lab_camp ~= nil and lsp_h._p.Marker ~= nil, "host: the camp and its marker (the game's own)")
check(#H.events._st.camps == 1, "host: the camp's marker kept")
check(logged("host", "events: camp with a map marker on the host: Prefab_LabResearchTents2_C by BP_PrefabSpawner56 at -120000,85000,2500, marker 'Abandoned Laboratory Research Tent' (its camp spawned): every client gets it (WEVT o)") ~= nil,
    "host log line (camp)")
check(#msgs(rpc._box, "WEVT") == 0, "nothing sent inside the game's call")
-- a camp without a marker (Marker? off, or Difficulty.RandomEventMarker off) and a dynamic event's SpawnMarker
local bsp = camp_spawner(HW, "BP_PrefabSpawner12", { X = 5000, Y = 5000, Z = 0 }, HW.bandit, nil)
spawn_camp(HW, bsp)
check(#H.events._st.camps == 1, "a camp without a marker: nothing")
-- a random event's SpawnMarker (@31, inside SpawnRandomEvent, before its post-hook): host_event's
local dsp = spawner(HW, "BP_PrefabSpawner_Dynamic_C_21", { X = 30000, Y = -60000, Z = 800 }, HW.apache, HW.cue,
    { tex = HW.heli_tex, title = "Crashed Military Helicopter", desc = "y" })
dsp._p.Marker = new(HW, { "BP_Marker_C", "Actor" }, "BP_Marker_C_2147439999", { _loc = dsp._p._loc,
    MarkerTitle = FText("Crashed Military Helicopter"), MarkerDescription = FText("y") })
fire(HW, MARKER_FN, param(dsp))
check(#H.events._st.camps == 1 and H.events._st.done[H.ue.path(dsp)] == nil,
    "a random event's SpawnMarker: not a camp (its SpawnRandomEvent post-hook relays it)")
fire(HW, MARKER_FN, param(lsp_h))
check(#H.events._st.camps == 1, "the same spawner again: kept once")
-- next tick: the connected clients get it at once (with E7's helicopter,
-- whose marker they missed while not connected)
ticks()
local lab_near, lab_far = msgs(rpc._box, "WEVT"), msgs(rpc_far._box, "WEVT")
local LAB_ITEM = "Prefab_LabResearchTents2_C>-120000,85000,2500>UI/Textures/Mock/LabMarker.LabMarker>Abandoned Laboratory Research Tent>Tents setup by laboratory staff as they tried to subdue the infection.>3.500,3.500>0.5052,0.1697,0.0342,1.0000>0"
check(#lab_near == 1 and lab_near[1]:find("SDC1|WEVT|o|", 1, true) == 1 and lab_near[1]:find(LAB_ITEM, 1, true) ~= nil,
    "near client: WEVT o with the laboratory's marker")
check(#lab_far == 1 and lab_far[1]:find(LAB_ITEM, 1, true) ~= nil, "far client too (a marker has no range)")
check(lab_near[1]:find("Prefab_CrashedApache01_C>70000,-3000,1200>", 1, true) ~= nil, "the missed helicopter's marker along")
check(#msgs(rpc._box, "NOTE") == 0, "no notice (a camp has none)")
check(logged("host", "events: BP_PlayerController_C_1: 2 more map marker(s) sent (WEVT o): 1 random event(s), 1 camp(s): Abandoned Laboratory Research Tent") ~= nil,
    "host log line (sent to a connected client)")
advance(2); ticks()
check(#msgs(rpc._box, "WEVT") == 1 and #msgs(rpc_far._box, "WEVT") == 1, "sent once")
-- the client places them the spawner's way
clear_logs()
n_spawned = #CW.spawned
cs0 = #CW.sounds
deliver_all()
local lmk = CW.spawned[#CW.spawned]
check(#CW.spawned == n_spawned + 2 and lmk._chain[1] == "BP_Marker_C" and lmk._finished
    and lmk._p.MarkerTexture == CW.lab_tex and lmk._p.MarkerTitle:ToString() == LAB_MK.title
    and lmk._p.MarkerDescription:ToString() == LAB_MK.desc and lmk._p._loc.X == LAB.X and lmk._p._loc.Y == LAB.Y,
    "client: the laboratory's BP_Marker_C at the spawner, its texture, title and description")
check(#CW.sounds == cs0, "client: no sound")
check(logged("client", "events: the host's earlier random event / camp Prefab_LabResearchTents2_C at -120000,85000,2500") ~= nil
    and logged("client", "map marker 'Abandoned Laboratory Research Tent' placed (texture LabMarker, finish ok=true)") ~= nil,
    "client log line (camp marker)")
-- the client's own roll of the same spawner: camp and marker blocked (sdc_world), no second marker
local lsp_c = camp_spawner(CW, "BP_PrefabSpawner56", LAB, CW.lab2, LAB_MK)
n_spawned = #CW.spawned
check(spawn_camp(CW, lsp_c) == nil and lsp_c._p.Marker == nil and #CW.spawned == n_spawned,
    "client: its own laboratory roll blocked, no marker of its own")
check(C.events.stats.camps == 0 and #C.events._st.camps == 0, "client: nothing noted there")
run_timers(CW)

-- a later joiner gets it (nobody reached it yet: mock_events_camps.lua for a
-- visited one), with the events it missed
clear_logs()
WORLD = HW
local rpc4 = remote(4, at(400000))
HS.remote_pcs = { rpc, rpc_far, rpc4 }
ticks(); advance(6); ticks()
local j4 = msgs(rpc4._box, "WEVT")
check(#j4 == 1 and j4[1]:find(LAB_ITEM, 1, true) ~= nil and j4[1]:find("Prefab_CrashedApache01_C>173901,22718,1931>", 1, true) ~= nil,
    "joiner: one WEVT o list with the earlier events and the laboratory")
check(logged("host", "events: BP_PlayerController_C_4 joined: the map markers of 1 camp(s) of the host sent (WEVT o): Abandoned Laboratory Research Tent") ~= nil,
    "host log line (joiner, camps)")
check(logged("host", "BP_PlayerController_C_4 joined after 3 random event(s): their map markers sent (WEVT o)") ~= nil,
    "host log line (joiner, events) as before")

-- a camp whose SpawnMarker came before the hook: taken at the next join
clear_logs()
local csp2 = camp_spawner(HW, "BP_PrefabSpawner57", { X = -90000, Y = 60000, Z = 2400 }, HW.lab2, LAB_MK)
spawn_camp(HW, csp2, { no_hook = true })
check(#H.events._st.camps == 1, "(not seen by the hook)")
local rpc5 = remote(5, at(450000))
HS.remote_pcs = { rpc, rpc_far, rpc4, rpc5 }
ticks(); advance(6); ticks()
local j5 = msgs(rpc5._box, "WEVT")
check(#H.events._st.camps == 2 and #j5 == 1 and j5[1]:find("Prefab_LabResearchTents2_C>-90000,60000,2400>", 1, true) ~= nil
    and j5[1]:find(LAB_ITEM, 1, true) ~= nil, "joiner: both laboratories (one found by the join's pass)")
check(logged("host", "events: camp with a map marker on the host: Prefab_LabResearchTents2_C by BP_PrefabSpawner57 at -90000,60000,2400, marker 'Abandoned Laboratory Research Tent' (found at a join)") ~= nil,
    "host log line (found at a join)")
check(logged("host", "BP_PlayerController_C_5 joined: the map markers of 2 camp(s) of the host sent (WEVT o): Abandoned Laboratory Research Tent, Abandoned Laboratory Research Tent") ~= nil,
    "host log line (joiner, 2 camps)")
advance(1); ticks()
local j4b = msgs(rpc4._box, "WEVT")
check(#j4b == 2 and j4b[2]:find("Prefab_LabResearchTents2_C>-90000,60000,2400>", 1, true) ~= nil and j4b[2]:find(LAB_ITEM, 1, true) == nil,
    "the others get only the new one")

-- a player who left; its controller's address comes back as a new player's
clear_logs()
HS.remote_pcs = { rpc, rpc_far, rpc5 }
ticks()
WORLD = HW
local rpc6 = remote(6, at(300000))
rpc6._addr = rpc4._addr
HS.remote_pcs = { rpc, rpc_far, rpc5, rpc6 }
ticks(); advance(6); ticks()
local j6 = msgs(rpc6._box, "WEVT")
check(#j6 == 1 and j6[1]:find(LAB_ITEM, 1, true) ~= nil and j6[1]:find("Prefab_LabResearchTents2_C>-90000,60000,2400>", 1, true) ~= nil,
    "a new player at a left one's address gets every marker")
HS.remote_pcs = { rpc, rpc_far }
ticks()
clear_box(rpc); clear_box(rpc_far)

bind(HW); local sh10 = H.events.status_line()
check(sh10:find("hook=true/true", 1, true) ~= nil and sh10:find("camps=2", 1, true) ~= nil, "host status: camps")
bind(CW); check(C.events.status_line():find("hook=true/false", 1, true) ~= nil, "client status: no SpawnMarker hook")

-- the host's world_prefabs off: its camps do not replicate (sdc_world) and
-- every client rolls its own, with their markers: no marker of the host's
-- camps goes (a joiner would find nothing there, next to its own camps)
clear_logs()
H.off.world_prefabs = true
local csp3 = camp_spawner(HW, "BP_PrefabSpawner58", { X = -60000, Y = 40000, Z = 2300 }, HW.lab2, LAB_MK)
spawn_camp(HW, csp3)
check(csp3._p.Marker ~= nil and #H.events._st.camps == 2 and H.events._st.done[H.ue.path(csp3)] == nil,
    "world_prefabs off: the host's laboratory and its marker (the game's), not kept for the clients")
check(logged("host", "events: camp with a map marker on the host") == nil, "world_prefabs off: no camp log line")
advance(1); ticks()
check(#msgs(rpc._box, "WEVT") == 0 and #msgs(rpc_far._box, "WEVT") == 0, "world_prefabs off: nothing to the connected clients")
WORLD = HW
local rpc7 = remote(7, at(350000))
HS.remote_pcs = { rpc, rpc_far, rpc7 }
ticks(); advance(6); ticks()
local j7 = msgs(rpc7._box, "WEVT")
check(#j7 == 1 and j7[1]:find("Prefab_CrashedApache01_C>173901,22718,1931>", 1, true) ~= nil
    and j7[1]:find("Prefab_LabResearchTents2_C", 1, true) == nil,
    "world_prefabs off: a joiner gets the random events' markers, none of the camps' (also the ones kept before)")
check(#H.events._st.camps == 2, "world_prefabs off: the join's pass notes nothing")
check(logged("host", "BP_PlayerController_C_7 joined after") ~= nil
    and logged("host", "BP_PlayerController_C_7 joined: the map markers of") == nil, "host log lines (events only)")
-- back on: the next joiner gets every camp, the one rolled while off too
clear_logs()
H.off.world_prefabs = nil
WORLD = HW
local rpc8 = remote(8, at(320000))
HS.remote_pcs = { rpc, rpc_far, rpc7, rpc8 }
ticks(); advance(6); ticks()
local j8 = msgs(rpc8._box, "WEVT")
check(#H.events._st.camps == 3 and #j8 == 1 and j8[1]:find("Prefab_LabResearchTents2_C>-60000,40000,2300>", 1, true) ~= nil
    and j8[1]:find(LAB_ITEM, 1, true) ~= nil, "world_prefabs on again: a joiner gets the 3 camps")
HS.remote_pcs = { rpc, rpc_far }
ticks()
clear_box(rpc); clear_box(rpc_far)
-- the reverse: once the host found a camp (within its 20 m), a later joiner
-- does not get it (its marker went for everyone: mock_events_camps.lua)
clear_logs()
local L3 = "-60000,40000,2300"
local hloc = HW.pawn._p._loc
HW.pawn._p._loc = { X = -60000 + 1000, Y = 40000, Z = 2300 }
advance(1); ticks()
check(msgs(rpc._box, "WEVT")[1] == "SDC1|WEVT|x|" .. L3 and msgs(rpc_far._box, "WEVT")[1] == "SDC1|WEVT|x|" .. L3
    and csp3._p.Marker._valid == false, "the host at the third laboratory: its marker gone, the clients told (WEVT x)")
check(logged("host", "visited: the host came within 10 m") ~= nil, "host log line (visited)")
HW.pawn._p._loc = hloc
WORLD = HW
local rpc9 = remote(9, at(330000))
HS.remote_pcs = { rpc, rpc_far, rpc9 }
ticks(); advance(6); ticks()
local j9 = msgs(rpc9._box, "WEVT")
check(#j9 == 1 and j9[1]:find(LAB_ITEM, 1, true) ~= nil and j9[1]:find("Prefab_LabResearchTents2_C>-90000,60000,2400>", 1, true) ~= nil
    and j9[1]:find(L3, 1, true) == nil, "a later joiner: the other 2 laboratories, not the one the host found")
check(logged("host", "BP_PlayerController_C_9 joined: the map markers of 2 camp(s) of the host sent (WEVT o)") ~= nil,
    "host log line (joiner, 2 camps)")
HS.remote_pcs = { rpc, rpc_far }
ticks()
clear_box(rpc); clear_box(rpc_far)
-- a new world: the camps roll again
bind(HW); H.events.reset("test")
check(#H.events._st.camps == 0 and H.events._st.done[H.ue.path(lsp_h)] == nil, "host reset drops the camps")

print("== E9. reset, status, errors")
bind(HW); local sh = H.events.status_line(); print(sh)
bind(CW); local sc = C.events.status_line(); print(sc)
check(sh:find("events=3", 1, true) ~= nil and sh:find("wrecks=", 1, true) ~= nil, "host status")
check(sc:find("played=1", 1, true) ~= nil and sc:find("muted=1", 1, true) ~= nil and sc:find("stale_notices=1", 1, true) ~= nil, "client status")
bind(CW); C.events.reset("test")
check(next(C.events._st.markers) == nil and #C.events._st.recent == 0, "reset drops the client's state")
check(errors == 0, "no hook / handler errors (" .. errors .. ")")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
