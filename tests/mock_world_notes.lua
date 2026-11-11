-- Mock harness: sdc_world next to sdc_notes (the game's notices of another player's
-- state / step through notes.quietly / notes.for_player, hooks on the same functions)
-- and the hangar door's keycard XP / all-access for a client.
-- usage: lua mock_world_notes.lua <scripts dir>
-- (harness core copied from mock_world.lua)
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
local function class_obj(chain, i)
    i = i or 1
    if not chain[i] then return nil end
    return {
        IsValid = function() return true end,
        GetFName = function() return name_obj(chain[i]) end,
    }
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
function Obj:GetOuter() return nil end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:K2_DestroyActor() self._valid = false end
local function rec(name)
    return function(self, ...) self._calls[#self._calls + 1] = { name, ... } end
end
local function called(o, name)
    for _, c in ipairs(o._calls) do if c[1] == name then return c end end
    return nil
end

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
NotifyOnNewObject = function(path, fn) WORLD.watch = WORLD.watch or {}; table.insert(WORLD.watch, { path = path, fn = fn }) end
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

local function run_timers(w)
    WORLD = w
    for _ = 1, 3 do
        local t = w.timers
        w.timers = {}
        for _, fn in ipairs(t) do fn() end
    end
end

local function fire(w, path, ...)
    WORLD = w
    local hs = w.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local r = h.pre(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
    return true
end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
end
local HW, CW = world("host"), world("client")

HARV_METHODS = {
    SetMaxHits = function(self) self._calls[#self._calls + 1] = { "SetMaxHits" }; self._p.MaxHits = 7 end,
    HitHarvestableObject = function(self, at, hits)
        self._calls[#self._calls + 1] = { "HitHarvestableObject", at, hits }
        if not self._init then self._init = true; self._p.MaxHits = 7 end   -- DoOnce Svr_SetMaxHits
        self._p.MaxHits = self._p.MaxHits - hits
        if self._p.MaxHits <= 0 then self._fell = (self._fell or 0) + 1 end
    end,
}
local function engine(w, is_server)
    WORLD = w
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    w.sounds, w.spawned = {}, {}
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        PlaySoundAtLocation = function(_, wco, snd) w.sounds[#w.sounds + 1] = snd end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        BeginDeferredActorSpawnFromClass = function(_, wco, cls, tf)
            local a = new(w, { cls._name, "Actor" }, "Spawned_" .. (#w.spawned + 1), { _tf = tf })
            w.spawned[#w.spawned + 1] = a
            if cls._name:find("^BP_HarvestableObject") then
                a._p._loc = tf.Translation
                a._p.Role = 3
                a._p.MaxHits = 1
                for k, fn in pairs(HARV_METHODS) do a._m[k] = fn end
                for _, x in ipairs(w.watch or {}) do
                    if x.path:find(cls._name:gsub("_C$", ""), 1, true) then assert(x.fn(a) == nil) end
                end
            end
            return a
        end,
        FinishSpawningActor = function(_, a) a._finished = true; return a end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
    new(w, { "AISense_Hearing" }, "Hearing", {}, { ReportNoiseEvent = rec("ReportNoiseEvent") }, "/Script/AIModule.Default__AISense_Hearing")
    new(w, { "SoundCue" }, "BreakOpen_Cue", {}, {}, "/Game/Audio/BreakOpen_Cue.BreakOpen_Cue")
    new(w, { "JigsawItem_DataAsset_C" }, "DA_ScrapMetal", {}, {}, "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal")
    new(w, { "JigsawItem_DataAsset_C" }, "DA_WoodenWall", {}, {}, "/Game/Inventory/Items/DataAssets/Buildable/DA_WoodenWall.DA_WoodenWall")
    new(w, { "BlueprintGeneratedClass" }, "BP_HarvestableObject_Tree_C", {}, {},
        "/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Tree.BP_HarvestableObject_Tree_C")
end
engine(HW, true)
engine(CW, false)

local function players(w, locals)
    WORLD = w
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local bc = new(w, { "BuildingComponent_C" }, "BuildingComponent_0", { ["BuildModeOn?"] = false },
        { Event_StopBuildMode = rec("Event_StopBuildMode") })
    local jig = new(w, { "BP_JigComponent_C" }, "BP_JigMultiplayer_0", {}, {
        AddNewItemSomewhere = function(self, da, n, a, b, dropifail, sc, added) self._calls[#self._calls + 1] = { "Add", da, n }; added.Added = true end,
        FindJigItemByDA = function(self, da, tags, a, b, n, out) out.Result = false end,
        SERVER_RequestConsumeItem = rec("SERVER_RequestConsumeItem"),
    })
    local root = new(w, { "JSIContainer_C" }, "Root_0", { JigMultiplayerComp = jig })
    local menu = new(w, { "JigContextMenuComp_C" }, "JigContextMenuComp_0", { LocalComp = jig, RootContainer = root })
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true, BuildingComponent = bc, BP_JigMultiplayer = jig,
          JigContextMenuComp = menu })
    bc._p._owner = pawn
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn, w.bc, w.jig = pc, pawn, bc, jig
end
players(HW)
players(CW)

-- the remote player's controller and character on the host
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rjig = new(HW, { "BP_JigComponent_C" }, "BP_JigMultiplayer_1", {}, {
    AddNewItemSomewhere = function(self, da, n, a, b, dropifail, sc, added) self._calls[#self._calls + 1] = { "Add", da, n }; added.Added = true end,
})
local rbc = new(HW, { "BuildingComponent_C" }, "BuildingComponent_1", {})
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1",
    { _loc = { X = 5000, Y = 0, Z = 0 }, BP_JigMultiplayer = rjig, BuildingComponent = rbc })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
rbc._p._owner = rpawn
HW.pcs[2] = rpc

-- ===========================================================================
-- sdc_world with sdc_notes (0.7.0): the game's notices of another player's
-- state / step go through notes.quietly / notes.for_player; hangar doors.
-- ===========================================================================
local P = {
    lgen = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryGenerator.BP_LaboratoryGenerator_C",
    hangar = "/Game/Blueprints/Other/Doors/BP_HangarDoor.BP_HangarDoor_C",
    scan = "/Game/Blueprints/Bunker/BP_BunkerScanner.BP_BunkerScanner_C",
    gfl_fn = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI",
    nest_fn = "/Game/Infestation/BP_Infestation.BP_Infestation_C:Damage_Object",
}
local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local DA_ALL = "/Game/Inventory/Items/DataAssets/Keycards/DA_AllAccessKeycard.DA_AllAccessKeycard"
local DA_FUSE = "/Game/Inventory/Items/DataAssets/Misc/DA_Fuse.DA_Fuse"
local DA_RED = "/Game/Inventory/Items/DataAssets/Keycards/DA_RedKeycard.DA_RedKeycard"

for _, w in ipairs({ HW, CW }) do
    WORLD = w
    local vb = new(w, { "VerticalBox" }, "VB31_" .. w.id, {}, {})
    vb._children = {}
    vb._m.GetChildrenCount = function(self) return #self._children end
    vb._m.GetChildAt = function(self, i) return self._children[i + 1] end
    local hud = new(w, { "HUD_Game_C" }, "HUD_" .. w.id, { NotificationUI = new(w, { "NotificationParentWidget_C" }, "NP_" .. w.id, { VerticalBox_31 = vb }) })
    w.pc._m.GetHUD = function() return hud end
    w.vb = vb
    w.notes = {}
    new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(self, text)
            local s = type(text) == "string" and text or text:ToString()
            w.notes[#w.notes + 1] = s
            local note
            note = new(w, { "NotficationUI_C" }, "Note_" .. #w.notes, { NotificationDetailsStruct = { [MSG] = FText(s) } }, {
                RemoveFromParent = function()
                    for i, c in ipairs(vb._children) do if c == note then table.remove(vb._children, i) return end end
                end })
            vb._children[#vb._children + 1] = note
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    for _, pth in ipairs({ DA_ALL, DA_FUSE, DA_RED }) do new(w, { "JigsawItem_DataAsset_C" }, pth:match("%.([%w_]+)$"), {}, {}, pth) end
    w.lc = new(w, { "LevellingComponent_C" }, "LC_" .. w.id, { CurrentLevel = 2 }, {
        AddXP = function(self, xp, up, out) self._calls[#self._calls + 1] = { "AddXP", xp }; out.XPOutput = xp end,
    })
    w.pc._p.LevellingComponent = w.lc
end
local function visible(w, s)
    for _, c in ipairs(w.vb._children) do if c._p.NotificationDetailsStruct[MSG]:ToString() == s then return true end end
    return false
end
local function note(w, s) w.paths["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"]:CreateNotificationUI(FText(s)) end
-- the client's inventory: on the host (containers) and on the client (widgets)
local INV = { DA_Fuse = 1, DA_RedKeycard = 1, DA_AllAccessKeycard = 1 }
rjig._m.ServerFindThenConsumeByItemID = function(self, da, n, out)
    out.Result = (INV[da._name] or 0) > 0
    if out.Result then INV[da._name] = INV[da._name] - 1 end
end
CW.jig._m.FindJigItemByDA = function(self, da, t, a, b, n, out) out.Result = (INV[da._name] or 0) > 0 end

local function tl(w, name)
    local t = new(w, { "TimelineComponent" }, name, {}, {})
    t._pos, t._playing, t._rev = 0, false, false
    t._m.IsPlaying = function(self) return self._playing end
    t._m.IsReversing = function(self) return self._rev end
    t._m.GetPlaybackPosition = function(self) return self._pos end
    t._m.Play = function(self) self._playing, self._rev = true, false end
    t._m.PlayFromStart = function(self) self._pos, self._playing, self._rev = 0, true, false; self._calls[#self._calls + 1] = { "PlayFromStart" } end
    t._m.Reverse = function(self) self._playing, self._rev = true, true end
    return t
end
local OBJ = {}
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    local o = {}
    o.lgen = new(w, { "BP_LaboratoryGenerator_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryGenerator_C_1", { ["TurnedOn?"] = false }, {
        Event_TurnOn = function(self) self._p["TurnedOn?"] = not self._p["TurnedOn?"]; note(w, "Laboratory generator powered on") end,
    })
    o.pgen = new(w, { "BP_PowerGenerator_C", "BP_MasterObject_C" }, "BP_PowerGenerator_C_1", {
        ["TurnedOn?"] = false, ["GasAdded?"] = true, ["ItemUsed?"] = false, ["RequiredItemToPowerOn?"] = true,
        ["ConsumeItemOnUse?"] = true, RequiredItem = w.paths[DA_FUSE], DisplayItemName = FText("Fuse"), Actors = {} }, {
        Event_TurnOn = function(self) self._p["TurnedOn?"] = true; self._calls[#self._calls + 1] = { "Event_TurnOn" }; note(w, "Generator powered on...") end,
    })
    local dt = tl(w, "TL_DoorsKeycard_" .. w.id)
    o.sdoor = new(w, { "BP_LaboratorySlidingDoor_C", "BP_LaboratoryMaster_C" }, "BP_LaboratorySlidingDoor_C_1",
        { Unlocked = false, Locked = true, Warning = false, ["XPGiven?"] = false, Keycard = w.paths[DA_RED], TL_DoorsKeycard = dt }, {
        OnRep_Unlocked = function(self) if self._p.Unlocked then self._p.Locked = false end; note(w, "Door unlocked chime") end,
    })
    o.scan = new(w, { "BP_BunkerScanner_C", "BP_MasterObject_C" }, "BP_BunkerScanner_C_1",
        { ["Unlocked?"] = false, ["KeycardRequired?"] = true, _loc = { X = 5100, Y = 0, Z = 0 } }, {
        OnExecuteInteract = function(self, a, opt) fire(w, P.scan .. ":OnExecuteInteract", param(self), param(a), param(opt)) end,
    })
    local ht = tl(w, "Timeline_OpenDoor_H_" .. w.id)
    o.hangar = new(w, { "BP_HangarDoor_C", "BP_MasterDoor_C" }, "BP_HangarDoor_C_1",
        { ["Open?"] = false, ["XPGiven?"] = false, Timeline_OpenDoor = ht, _loc = { X = 5050, Y = 0, Z = 0 } }, {
        MC_OpenDoor = function(self, actor) self._calls[#self._calls + 1] = { "MC_OpenDoor", actor } end,
        OnExecuteInteract = function(self, a, opt) fire(w, P.hangar .. ":OnExecuteInteract", param(self), param(a), param(opt)) end,
    })
    OBJ[w.id] = o
end
local HO, CO = OBJ.host, OBJ.client

-- ---------------------------------------------------------------- a spy sdc_notes
local SPY = { calls = {}, sent = false }
function SPY.quietly(why, fn, ...)
    SPY.calls[#SPY.calls + 1] = { "quietly", why }
    return pcall(fn, ...)
end
function SPY.for_player(pc, fn, ...)
    SPY.calls[#SPY.calls + 1] = { "for_player", pc }
    return pcall(fn, ...)
end
function SPY.sent_to(pc, text, s)
    SPY.calls[#SPY.calls + 1] = { "sent_to", pc, text, s }
    return SPY.sent
end
local function spied(kind, arg)
    for _, c in ipairs(SPY.calls) do if c[1] == kind and (arg == nil or c[2] == arg) then return c end end
    return nil
end

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...) if k == "net_send_budget" then return false end return get0(k, ...) end
    m.net.install_hooks()
    m.world = require("sdc_world")
    return m
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
local function deliver()
    for _ = 1, 6 do
        local out = HW.outbox
        HW.outbox = {}
        WORLD = CW
        for _, msg in ipairs(out) do
            local kind, f = C.net.decode(msg)
            local h = C.net.handlers[kind]
            if h then h(f, CW.pc) end
        end
        out = CW.outbox
        CW.outbox = {}
        WORLD = HW
        for _, msg in ipairs(out) do
            local kind, f = H.net.decode(msg)
            local h = H.net.handlers[kind]
            if h then h(f, rpc) end
        end
    end
end
local function settle() for _ = 1, 3 do run_timers(HW); deliver(); run_timers(CW); deliver() end end

print("== Z0. sdc_world's own hooks next to sdc_notes' (both registered on the same functions)")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
-- sdc_notes registers its own callbacks on the same functions (UE4SS runs every callback)
local notes_ran = { gfl = 0, nest = 0 }
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    RegisterHook(P.gfl_fn, function() notes_ran.gfl = notes_ran.gfl + 1 end)
    RegisterHook(P.nest_fn, function() notes_ran.nest = notes_ran.nest + 1 end)
end
check(#HW.hooks[P.gfl_fn] == 2 and #HW.hooks[P.nest_fn] == 2, "two callbacks on CreateNotificationUI and on BP_Infestation.Damage_Object")
-- the client's shot on a nest still goes to the host (sdc_world's Damage_Object hook) while sdc_notes' runs too
WORLD = CW
local cnest = new(CW, { "BP_Infestation_C" }, "BP_Infestation_C_7", { ["IsDestroyed?"] = false })
new(HW, { "BP_Infestation_C" }, "BP_Infestation_C_7", { ["IsDestroyed?"] = false }, { Damage_Object = rec("Damage_Object") })
local cgun = new(CW, { "BP_M4Pickup_C", "BP_FirearmPickup_C" }, "BP_M4Pickup_C_78", { _owner = CW.pawn })
fire(CW, P.nest_fn, param(cnest), param(20), param(CW.pawn), param(nil))
fire(CW, "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Trace_Impact", param(cgun))
local wdmg = false
for _, m in ipairs(CW.outbox) do if m:find("|WDMG|", 1, true) then wdmg = true end end
check(wdmg and notes_ran.nest == 1, "the nest hit: sdc_world sent WDMG and sdc_notes' callback ran too")
CW.outbox = {}
WORLD = HW; fire(HW, P.gfl_fn, param(nil), param(FText("x")), param(nil), param(nil), param(2), param(false), param(HW.pc))
check(notes_ran.gfl == 1, "CreateNotificationUI: both callbacks ran (no error from sdc_world's)")
package.loaded["sdc_notes"] = SPY

print("== Z1. the client applies the host's state quietly (no 'powered on' for the host's action)")
WORLD = CW; C.net.handlers.WPWS({ "~LongdownValley~BP_LaboratoryGenerator_C_1=1" }, CW.pc)
local q = spied("quietly")
check(q and q[2] == "applying the host's BP_LaboratoryGenerator_C_1", "notes.quietly('applying the host's ...')")
check(CO.lgen._p["TurnedOn?"] == true, "and the state is applied")

print("== Z2. the host runs a client's step / try for that player")
SPY.calls = {}
WORLD = HW; H.net.handlers.WPSTEP({ "~LongdownValley~BP_LaboratoryGenerator_C_1", "1" }, rpc)
check(spied("for_player", rpc) ~= nil and HO.lgen._p["TurnedOn?"] == true, "WPSTEP: notes.for_player(that player, the step)")
SPY.calls = {}
WORLD = HW; H.net.handlers.WPTRY({ "~LongdownValley~BP_PowerGenerator_C_1", "item" }, rpc)
check(spied("for_player", rpc) ~= nil and called(HO.pgen, "Event_TurnOn") ~= nil and INV.DA_Fuse == 0,
    "WPTRY item: the fuse taken, Event_TurnOn through notes.for_player")
SPY.calls = {}
WORLD = HW; H.net.handlers.WPTRY({ "~LongdownValley~BP_LaboratorySlidingDoor_C_1", "key" }, rpc)
check(spied("for_player", rpc) ~= nil and HO.sdoor._p.Unlocked == true and INV.DA_RedKeycard == 0,
    "WPTRY key: the card taken, the door's set through notes.for_player")
deliver()

print("== Z3. a scanner's 'No Keycard Available' only once")
SPY.calls = {}; SPY.sent = true
HW.outbox = {}
WORLD = HW; H.world._t.locks.on_scan(param(HO.scan), param(rpawn))
local wp = false
for _, m in ipairs(HW.outbox) do if m:find("|WPNOTE|", 1, true) then wp = true end end
check(spied("sent_to", rpc) and not wp, "sdc_notes relayed the game's note already: no WPNOTE")
SPY.sent = false
WORLD = HW; H.world._t.locks.on_scan(param(HO.scan), param(rpawn))
wp = false
for _, m in ipairs(HW.outbox) do if m:find("|WPNOTE|", 1, true) then wp = true end end
check(wp, "not relayed: WPNOTE as before")
HW.outbox = {}

print("== Z4. hangar door: the client's keycard XP and note are the client's, not the host's")
check(H.world._t.kind_of_class("BP_HangarDoor_C") == "aim", "BP_HangarDoor is a scope ('aim') class")
WORLD = CW; fire(CW, P.hangar .. ":OnBeginInteract", param(CO.hangar), param(CW.pawn), param({}))
deliver()
WORLD = HW
check(H.world._t.resolver(HO.hangar) == rpc, "looking at it from 0.5 m: its player-0 calls are that player's")
note(CW, "No Keycard Available")   -- the client's own copy's check could not see the card the host took
HO.hangar._p["XPGiven?"] = true
fire(HW, P.hangar .. ":MC_OpenDoor", param(HO.hangar), param(rpawn))
deliver(); run_timers(CW)
local xp = CW.lc._calls[#CW.lc._calls]
check(xp ~= nil and xp[1] == "AddXP" and xp[2] == 400 and visible(CW, "Door Unlocked, XP Given: 400"), "the client: XP (level 2 x 200) and the game's note")
check(not visible(CW, "No Keycard Available"), "its own false 'No Keycard Available' is gone")
check(called(HW.lc, "AddXP") == nil, "the host got no XP")

print("== Z5. hangar door with an all-access card in the client's widgets")
HO.hangar._p["Open?"], CO.hangar._p["Open?"] = false, false
WORLD = CW; CO.hangar:OnExecuteInteract(CW.pawn, { TagName = FName("Jig.InteractOptions.Option1") })
deliver()
check(called(HO.hangar._p.Timeline_OpenDoor, "PlayFromStart") ~= nil, "the host opens it (its timeline, the step after the card check)")
-- the client missed it: the host's state opens its copy by the same step, not MC_OpenDoor(None)
HO.hangar._p["Open?"] = true
WORLD = HW; run_timers(HW); deliver(); run_timers(CW); run_timers(CW)
check(called(CO.hangar._p.Timeline_OpenDoor, "PlayFromStart") ~= nil and called(CO.hangar, "MC_OpenDoor") == nil,
    "the client's copy opened by its timeline")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
