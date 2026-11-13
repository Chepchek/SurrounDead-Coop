-- Mock harness: a client's locks, keys and tools (sdc_world LK): the lockpick
-- minigame's count, broken picks, picked locks, tool wear, keypad doors, and the
-- host's scope for scanners / keycard doors (XP and notes to the client).
-- usage: lua mock_world_locks.lua <scripts dir>
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
-- Locks, keys and tools of a client (sdc_world LK section, 0.6.69)
-- ===========================================================================
local UI = "/Game/UI/Lockpick/LockpickUI.LockpickUI_C"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local DOOR = "/Game/Blueprints/Other/Doors/BP_LockedDoor.BP_LockedDoor_C"
local PICK = "/Game/Inventory/Containers/PicklockContainer/BP_MASTER_PicklockContainer.BP_MASTER_PicklockContainer_C"
local TOOL = "/Game/Inventory/Containers/ToolRequiredContainer/BP_MASTER_ToolRequiredContainer.BP_MASTER_ToolRequiredContainer_C"
local KEYPAD = "/Game/Blueprints/Other/Doors/Keypad/BP_KeypadDoor.BP_KeypadDoor_C"
local KEYUI = "/Game/UI/Widgets/Other/KeypadUI.KeypadUI_C"
local SCAN = "/Game/Blueprints/Bunker/BP_BunkerScanner.BP_BunkerScanner_C"
local KDOOR = "/Game/Blueprints/Other/Doors/BP_KeycardDoor.BP_KeycardDoor_C"
local DA_LP = "/Game/Inventory/Items/DataAssets/Other/DA_Lockpick.DA_Lockpick"

for _, w in ipairs({ HW, CW }) do
    WORLD = w
    new(w, { "JigsawItem_DataAsset_C" }, "DA_Lockpick", {}, {}, DA_LP)
    -- notes, XP, widgets
    local vb = new(w, { "VerticalBox" }, "VerticalBox_31_" .. w.id, {}, {})
    vb._children = {}
    vb._m.GetChildrenCount = function(self) return #self._children end
    vb._m.GetChildAt = function(self, i) return self._children[i + 1] end
    local hud = new(w, { "HUD_Game_C" }, "HUD_" .. w.id, { NotificationUI = new(w, { "NotificationParentWidget_C" }, "NP_" .. w.id, { VerticalBox_31 = vb }) })
    w.pc._m.GetHUD = function() return hud end
    w.notes = {}
    local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
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
    w.lc = new(w, { "LevellingComponent_C" }, "LC_" .. w.id, { CurrentLevel = 4 }, {
        AddXP = function(self, xp, up, out) self._calls[#self._calls + 1] = { "AddXP", xp }; out.XPOutput = xp end,
    })
    w.pc._p.LevellingComponent = w.lc
    w.jig._p._owner = w.pawn
end
local function shown(w, s)
    for _, n in ipairs(w.notes) do if n == s then return true end end
    return false
end
local function visible(w, s)
    local vb = w.pc._m.GetHUD()._p.NotificationUI._p.VerticalBox_31
    for _, c in ipairs(vb._children) do
        if c._p.NotificationDetailsStruct["Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"]:ToString() == s then return true end
    end
    return false
end
-- the host's containers of the client's inventory
local consumed = {}
rjig._m.ServerFindThenConsumeByItemID = function(self, da, n, out) consumed[#consumed + 1] = da._name; out.Result = true end
rjig._m.ServerFuncUpdateDurabilityByUID = function(self, g, m, destroy, out)
    self._calls[#self._calls + 1] = { "ServerFuncUpdateDurabilityByUID", g, m, destroy }
    out.NewDur = 90 - m
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
local function out_has(w, kind)
    for _, m in ipairs(w.outbox) do if m:find("|" .. kind .. "|", 1, true) or m:find("|" .. kind .. "$") then return true end end
    return false
end
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)

print("== L1. the lockpick minigame counts this player's own lockpicks")
WORLD = CW
local function slot(w, name, da, n, uid)
    return new(w, { "JSI_Slot_C" }, name, { JigDataAsset = da, ItemCount = n, ItemUniqueID = { A = uid, B = 0, C = 0, D = 0 } })
end
local da_c = CW.paths[DA_LP]
local other = new(CW, { "JigsawItem_DataAsset_C" }, "DA_Bandage", {}, {}, "/Game/X/DA_Bandage.DA_Bandage")
local bag = new(CW, { "JSIContainer_C" }, "Backpack_0", { ArrayOfItems = { slot(CW, "S3", da_c, 2, 13) } })
local cont = new(CW, { "JSIContainer_C" }, "Pockets_0", { ArrayOfItems = {
    slot(CW, "S1", da_c, 3, 11), slot(CW, "S2", other, 5, 12), new(CW, { "JSI_Slot_C" }, "S4", { SlotContainer = bag }) } })
-- the same container seen twice (two widgets): counted once
CW.jig._p.LocalJSIContainers = { cont, cont }
local lpui = new(CW, { "LockpickUI_C" }, "LockpickUI_C_1", { UseLockpick = true, LPRef = new(CW, { "LockPickingComponent_C" }, "LP_0", { LPDurability = 25 }) })
-- (as UE4SS 3.0.1 calls a Blueprint hook: (Context, Lockpicks), no ReturnValue)
local n_p = param(0)
fire(CW, UI .. ":GetLockpickAmount", param(lpui), n_p)
check(n_p._v() == 5, "out Lockpicks = 5 (3 + 2 in a bag; the bandages not; one container seen twice) - " .. tostring(n_p._v()))
check(CW.hooks[UI .. ":GetLockpickAmountText"] == nil, "no hook on GetLockpickAmountText (a Blueprint hook gets no return value)")
-- none in the widgets, the game's own lookup finds one
CW.jig._p.LocalJSIContainers = {}
CW.jig._m.FindJigItemByDA = function(self, da, t, a, b, n, out) out.Result = da == da_c end
advance(1)
local n2 = param(0)
fire(CW, UI .. ":GetLockpickAmount", param(lpui), n2)
check(n2._v() == 1, "no widget slots: the game's FindJigItemByDA (>= 1)")
WORLD = HW
local hn = param(0)
fire(HW, UI .. ":GetLockpickAmount", param(lpui), hn)
check(hn._v() == 0, "the host's own minigame is left alone")

print("== L2. a broken pick: the host takes it out of the client's inventory")
WORLD = CW
lpui._p.LPRef._p.LPDurability = 23.3
fire(CW, UI .. ":BreakLockpick", param(lpui))
check(not out_has(CW, "WLPBREAK"), "a wrong try that did not break it: nothing")
lpui._p.LPRef._p.LPDurability = 25   -- @766: broke, back to 25
fire(CW, UI .. ":BreakLockpick", param(lpui))
check(out_has(CW, "WLPBREAK"), "it broke: sent")
deliver()
check(#consumed == 1 and consumed[1] == "DA_Lockpick", "the host consumed one DA_Lockpick from that player")
lpui._p.UseLockpick = false
advance(1)
fire(CW, UI .. ":BreakLockpick", param(lpui))
check(not out_has(CW, "WLPBREAK"), "UseLockpick off: nothing")

print("== L3. a picked lock is open on the host at once")
local hsafe, csafe
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    local s = new(w, { "PicklockContainer_Safe_C", "BP_MASTER_PicklockContainer_C", "BP_LockPickObject_C" }, "PicklockContainer_Safe_C_4",
        { ["IsLocked?"] = true, ContainerLooted = false })
    if w == HW then hsafe = s else csafe = s end
end
local hdoor2, cdoor2
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    local d = new(w, { "BP_LockedDoor_C", "BP_LockPickObject_C" }, "BP_LockedDoor_C_8", { ["IsLocked?"] = true })
    if w == HW then hdoor2 = d else cdoor2 = d end
end
WORLD = CW; csafe._p["IsLocked?"] = false; fire(CW, PICK .. ":LockpickSuccessful", param(csafe))
cdoor2._p["IsLocked?"] = false; fire(CW, DOOR .. ":LockpickSuccessful", param(cdoor2))
deliver()
check(hsafe._p["IsLocked?"] == false and hdoor2._p["IsLocked?"] == false, "safe and door unlocked on the host")

print("== L4. a tool's wear goes to the host")
WORLD = CW
local tbox = new(CW, { "BP_ToolRequired_Crate_C", "BP_MASTER_ToolRequiredContainer_C" }, "BP_ToolRequired_Crate_C_2", {})
fire(CW, JIG .. ":ServerFuncUpdateDurabilityByUID", param(CW.jig), param({ A = 7, B = 8, C = 9, D = 10 }), param(10.0), param(true), param(0))
fire(CW, TOOL .. ":FindItem", param(tbox), param(CW.pawn), param(true))
check(out_has(CW, "WTOOLDUR"), "the crowbar's wear of that use sent")
deliver()
local wc = called(rjig, "ServerFuncUpdateDurabilityByUID")
check(wc and wc[2].A == 7 and wc[2].D == 10 and wc[3] == 10 and wc[4] == true, "the host wore that item (its UID, 10, destroy at 0)")
-- a durability call not from a world tool (a weapon): nothing
fire(CW, JIG .. ":ServerFuncUpdateDurabilityByUID", param(CW.jig), param({ A = 1, B = 1, C = 1, D = 1 }), param(0.5), param(false), param(0))
advance(1)
fire(CW, TOOL .. ":FindItem", param(tbox), param(CW.pawn), param(true))
check(not out_has(CW, "WTOOLDUR"), "another item's wear (a weapon) is not sent")
-- another player's component: nothing
fire(CW, JIG .. ":ServerFuncUpdateDurabilityByUID", param(new(CW, { "BP_JigComponent_C" }, "J9", { _owner = new(CW, { "BP_PlayerCharacter_C" }, "P9", { _local = false }) })),
    param({ A = 2, B = 2, C = 2, D = 2 }), param(5.0), param(true), param(0))
fire(CW, DOOR .. ":FindCrowbar", param(cdoor2), param(CW.pawn), param(true))
check(not out_has(CW, "WTOOLDUR"), "not this player's item: nothing")

print("== L5. keypad doors: the host's code, the keypad on the presser's screen, the host checks")
local function keypad(w, code)
    WORLD = w
    local note = new(w, { "BP_KeypadNote_C" }, "BP_KeypadNote_C_1", { Code = code })
    local d
    d = new(w, { "BP_KeypadDoor_C" }, "BP_KeypadDoor_C_1", { Code = code, NoteRef = note, ["Open?"] = false, _loc = { X = 5100, Y = 0, Z = 0 } }, {
        CorrectCode = function(self) self._calls[#self._calls + 1] = { "CorrectCode", self._p.CurrentActor } end,
        IncorrectCode = function(self) self._calls[#self._calls + 1] = { "IncorrectCode" } end,
    })
    return d, note
end
local hkp = keypad(HW, 4321)
local ckp, cnote = keypad(CW, 1111)
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 20 do WORLD = HW; H.world.tick(); deliver() end
check(ckp._p.Code == 4321 and cnote._p.Code == 4321, "the client's door and note show the host's code")
-- the client's press -> the host's server path opened a keypad on the host's screen (@622)
WORLD = HW
local hui = new(HW, { "KeypadUI_C" }, "KeypadUI_C_1", { DoorRef = hkp, _inv = true }, {
    IsInViewport = function(self) return self._p._inv end,
    PausePressed = function(self) self._p._inv = false; self._calls[#self._calls + 1] = { "PausePressed" } end,
})
-- UMG widgets: the game's WidgetBlueprintLibrary.GetAllWidgetsOfClass finds them (FindAllOf does not)
new(HW, { "BlueprintGeneratedClass" }, "KeypadUI_C", {}, {}, KEYUI)
new(HW, { "WidgetBlueprintLibrary" }, "WBL", {}, {
    GetAllWidgetsOfClass = function(self, wc, arr, cls, top)
        for _, o in ipairs(HW.objects) do
            if o._valid and derives(o, cls._name) and (not top or o._p._inv) then arr[#arr + 1] = o end
        end
    end,
}, "/Script/UMG.Default__WidgetBlueprintLibrary")
fire(HW, KEYPAD .. ":OnServerExecuteInteract", param(hkp), param({}), param(rpawn), param({}))
check(called(hui, "PausePressed") ~= nil, "the host's screen: that keypad closed the widget's own way")
check(out_has(HW, "WKEYUI"), "the presser is told to open its keypad")
-- the client opens the game's KeypadUI
local cui
WORLD = CW
new(CW, { "BlueprintGeneratedClass" }, "KeypadUI_C", {}, {}, KEYUI)
local wl = CW.paths["/Script/UMG.Default__WidgetBlueprintLibrary"] or new(CW, { "WidgetBlueprintLibrary" }, "WBL", {}, {}, "/Script/UMG.Default__WidgetBlueprintLibrary")
wl._m.Create = function(self, wco, cls, pc)
    cui = new(CW, { "KeypadUI_C" }, "KeypadUI_C_2147480001", { CurrentCode = "" }, {
        AddToViewport = function(s) s._p._inv = true end,
    })
    return cui
end
wl._m.SetInputMode_GameAndUIEx = function(self, pc, w) self._calls[#self._calls + 1] = { "SetInputMode_GameAndUIEx", w } end
CW.pawn._m.DisableInput = function(self) self._calls[#self._calls + 1] = { "DisableInput" } end
deliver()
check(cui ~= nil and cui._p._inv == true and cui._p.DoorRef == ckp and cui._p.AcceptedCode == 4321, "the client's own keypad: on screen, its door, the host's code")
check(called(wl, "SetInputMode_GameAndUIEx") ~= nil and called(CW.pawn, "DisableInput") ~= nil and CW.pc._p.bShowMouseCursor == true,
    "input as the door's own path sets it")
-- a wrong code, then the right one (each full entry goes to the host)
cui._p.CurrentCode = "12"
fire(CW, KEYUI .. ":SetCurrentCode", param(cui), param("2"))
check(not out_has(CW, "WKEYTRY"), "half a code: nothing yet")
cui._p.CurrentCode = "1234"
fire(CW, KEYUI .. ":SetCurrentCode", param(cui), param("4"))
deliver()
check(called(hkp, "IncorrectCode") ~= nil and called(hkp, "CorrectCode") == nil, "a wrong code: the host's door plays the wrong code (noise)")
-- the game opens a fresh keypad next time; this one is done
WORLD = HW
hui._p._inv = true
fire(HW, KEYPAD .. ":OnServerExecuteInteract", param(hkp), param({}), param(rpawn), param({}))
deliver()
advance(1)
cui._p.CurrentCode = "4321"
WORLD = CW; fire(CW, KEYUI .. ":SetCurrentCode", param(cui), param("1"))
deliver()
local cc = called(hkp, "CorrectCode")
check(cc ~= nil and cc[2] == rpawn, "the right code: CorrectCode on the host for that player (MC_OpenDoor for everyone)")
-- the host's own press: its keypad stays
WORLD = HW
hui._p._inv = true
hui._calls = {}
fire(HW, KEYPAD .. ":OnServerExecuteInteract", param(hkp), param({}), param(HW.pawn), param({}))
check(called(hui, "PausePressed") == nil, "the host's own keypad stays on the host's screen")

print("== L6. scanner: the client at it gets its XP and its note, not the host")
local hscan, cscan
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    local s
    s = new(w, { "BP_BunkerScanner_C", "BP_MasterObject_C" }, "BP_BunkerScanner_C_3",
        { ["Unlocked?"] = false, ["KeycardRequired?"] = true, GiveXPOnInteraction = true, _loc = { X = 5200, Y = 0, Z = 0 } })
    if w == HW then hscan = s else cscan = s end
end
WORLD = HW
check(H.world._t.resolver(hscan) == nil, "nobody at it: player 0 stays the host")
WORLD = CW; fire(CW, SCAN .. ":OnBeginInteract", param(cscan), param(CW.pawn), param({}))
deliver()
WORLD = HW
check(H.world._t.resolver(hscan) == rpc, "the client looks at it from 2 m: its player-0 calls are that player's")
-- the host's check (with the card in the client's inventory there): unlocked, XP asked for player 0
hscan._p["Unlocked?"], hscan._p["KeycardRequired?"] = true, false
fire(HW, SCAN .. ":MC_CallInteract", param(hscan), param(rpawn))
deliver()
local xp = called(CW.lc, "AddXP")
check(xp ~= nil and xp[2] == 800, "the client got the scanner's XP (level 4 x 200)")
check(not shown(CW, "Door Unlocked, XP Given: 800"), "(without a note, as the scanner's own XP)")
-- another scanner the client cannot open: its note goes to the client
local hscan2
WORLD = HW
hscan2 = new(HW, { "BP_BunkerScanner_C", "BP_MasterObject_C" }, "BP_BunkerScanner_C_4",
    { ["Unlocked?"] = false, ["KeycardRequired?"] = true, _loc = { X = 5300, Y = 0, Z = 0 } })
WORLD = CW; new(CW, { "BP_BunkerScanner_C", "BP_MasterObject_C" }, "BP_BunkerScanner_C_4", { _loc = { X = 5300, Y = 0, Z = 0 } })
fire(HW, SCAN .. ":MC_CallInteract", param(hscan2), param(rpawn))
deliver()
check(shown(CW, "No Keycard Available"), "no card: 'No Keycard Available' on the client's screen")
-- the host standing nearer to it: the host's own use
HW.pawn._p._loc = { X = 5210, Y = 0, Z = 0 }
WORLD = HW
check(H.world._t.resolver(hscan) == nil, "the host stands nearer: player 0 stays the host")
HW.pawn._p._loc = { X = 0, Y = 0, Z = 0 }
-- far away / looking elsewhere: the host again
rpawn._p._loc = { X = 9000, Y = 0, Z = 0 }
WORLD = HW
check(H.world._t.resolver(hscan) == nil, "the client 38 m away: player 0 is the host again")
rpawn._p._loc = { X = 5000, Y = 0, Z = 0 }
WORLD = CW; fire(CW, SCAN .. ":OnEndInteract", param(cscan))
deliver()
WORLD = HW
check(H.world._t.resolver(hscan) == nil, "it looked away: the host again")

print("== L7. keycard door: the host's check passed for the client -> the XP is the client's")
local hk, ck
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    local d = new(w, { "BP_KeycardDoor_C", "BP_MasterDoor_C" }, "BP_KeycardDoor_C_2", { ["Open?"] = false, ["XPGiven?"] = false, _loc = { X = 5100, Y = 50, Z = 0 } })
    if w == HW then hk = d else ck = d end
end
WORLD = CW; CW.notes = {}
fire(CW, KDOOR .. ":OnBeginInteract", param(ck), param(CW.pawn), param({}))
CW.gfl = CW.paths["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"]
CW.gfl:CreateNotificationUI(FText("No Keycard Available"))   -- its own copy's check failed (@3077)
deliver()
WORLD = HW
check(H.world._t.resolver(hk) == rpc, "its XP / note on the host are that player's")
hk._p["XPGiven?"] = true
fire(HW, KDOOR .. ":MC_OpenDoor", param(hk), param(rpawn))
deliver(); run_timers(CW)
local xps = {}
for _, c in ipairs(CW.lc._calls) do if c[1] == "AddXP" then xps[#xps + 1] = c[2] end end
check(xps[#xps] == 800 and visible(CW, "Door Unlocked, XP Given: 800"), "the client: XP 800 and the game's note")
check(not visible(CW, "No Keycard Available"), "its own false 'No Keycard Available' is gone")
check(ck._p["XPGiven?"] == true, "XP once (its door says given)")
local nxp = #xps
WORLD = HW; fire(HW, KDOOR .. ":MC_OpenDoor", param(hk), param(rpawn))
deliver()
local n2xp = 0
for _, c in ipairs(CW.lc._calls) do if c[1] == "AddXP" then n2xp = n2xp + 1 end end
check(n2xp == nxp, "no second XP for the same door")

print("== L8. status")
WORLD = HW; local sl = H.world.status_line(); print(sl)
check(sl:find("locks picked=", 1, true) ~= nil, "status: locks picked / breaks / tools / keypads")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
