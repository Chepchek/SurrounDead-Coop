-- Mock harness: the lockpick count a client's minigame shows and gates on
-- (sdc_world LK.count / LK.show / the broken-pick hold), with hooks called the
-- way UE4SS 3.0.1 calls a Blueprint hook (no ReturnValue parameter).
-- usage: lua mock_world_lockpick_count.lua <scripts dir>
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


-- ===========================================================================
-- The lockpick count on a client's minigame screen (sdc_world LK.show / hold)
-- ===========================================================================
-- Hooks are fired the way UE4SS 3.0.1 calls a Blueprint (script) hook:
-- LuaMod script_hook passes (Context, params...) WITHOUT the ReturnValue, so
-- GetLockpickAmount(out Lockpicks) -> Text gets (Context, Lockpicks)
-- (GetLockpickAmountText() -> Text is not hooked: it would get nothing to answer).
local lines = {}
for _, m in ipairs({ H, C }) do
    local info0 = m.log.info
    m.log.info = function(msg, ...)
        local ok, s = pcall(string.format, msg, ...)
        lines[#lines + 1] = ok and s or msg
        return info0(msg, ...)
    end
end
local function logged(pat)
    for _, s in ipairs(lines) do if s:find(pat, 1, true) then return s end end
    return nil
end
local function nlogged(pat)
    local n = 0
    for _, s in ipairs(lines) do if s:find(pat, 1, true) then n = n + 1 end end
    return n
end

local da_c = CW.paths[DA_LP]
local slot_n = 0
local function slot(da, n)
    slot_n = slot_n + 1
    return new(CW, { "JSI_Slot_C" }, "LS" .. slot_n, { JigDataAsset = da, ItemCount = n, ItemUniqueID = { A = 900 + slot_n, B = 0, C = 0, D = 0 } })
end
local pockets = new(CW, { "JSIContainer_C" }, "LPockets_0", { ArrayOfItems = {} })
local function have(n)
    -- the client's own inventory widgets (the host's changes land here)
    pockets._p.ArrayOfItems = n > 0 and { slot(da_c, n) } or {}
end
CW.jig._p.LocalJSIContainers = { pockets }

-- UTextBlock: Text bound to the widget's GetLockpickAmountText (UMG Bindings);
-- SetText stores the text and unbinds it (TextDelegate.Unbind()); GetText is
-- what the screen shows (the binding while bound).
local game_text = "Lockpicks: 0"   -- the game's own count over the client's empty MainJigContainers
local function lockpick_ui(name)
    local tb = new(CW, { "TextBlock" }, name .. "_Txt", { Text = FText("Lockpicks: 0") }, {})
    tb._gets, tb._sets = 0, 0
    tb._m.GetText = function(self)
        self._gets = self._gets + 1
        if self._bound then return self._bound() end
        return self._p.Text
    end
    tb._m.SetText = function(self, t)
        self._sets = self._sets + 1
        self._p.Text = t
        self._bound = nil
    end
    tb._bound = function() return FText(game_text) end
    local ui = new(CW, { "LockpickUI_C" }, name, { UseLockpick = true, LockpickTxt = tb,
        LPRef = new(CW, { "LockPickingComponent_C" }, name .. "_LP", { LPDurability = 25 }) })
    return ui, tb
end
-- one minigame frame (Tick @576): the gate (out Lockpicks) and the screen
local function frame(ui)
    WORLD = CW
    local out = param(0)
    fire(CW, UI .. ":GetLockpickAmount", param(ui), out)
    local tb = ui._p.LockpickTxt
    local g = tb._gets
    local shown = tb:GetText():ToString()
    tb._gets = g
    return out._v(), shown
end
local function break_pick(ui)
    WORLD = CW
    ui._p.LPRef._p.LPDurability = 25   -- @766: broke, back to 25
    fire(CW, UI .. ":BreakLockpick", param(ui))
end

print("== P1. the safe's minigame: the real count at the gate AND on the screen")
have(10)
advance(1)
local ui, tb = lockpick_ui("LockpickUI_C_2147480100")
check(tb:GetText():ToString() == "Lockpicks: 0", "(before the first frame the binding shows the game's 0, as in the bug)")
local n, shown = frame(ui)
check(n == 10, "out Lockpicks = 10 (the minigame's gate) - " .. tostring(n))
check(shown == "Lockpicks: 10", "the screen shows 'Lockpicks: 10', not the binding's 0 - " .. tostring(shown))
check(tb._bound == nil and tb._sets == 1, "SetText once: the game's binding unbound (UMG's own)")
check(logged("lockpick minigame text 'Lockpicks: 0' -> 'Lockpicks: 10' (this player's count; set ok, reads 'Lockpicks: 10')") ~= nil,
    "log: the text change, with what the screen reads back")
check(logged("lockpicks here: 10 (inventory widgets;") ~= nil, "log: the count and where it came from")
-- every frame: no new SetText, few GetText calls
local gets0 = tb._gets
for _ = 1, 30 do advance(0.016); frame(ui) end
check(tb._sets == 1, "30 more frames: no new SetText")
check(tb._gets - gets0 <= 3, "30 frames: the text re-read at most every 0.25 s (" .. (tb._gets - gets0) .. " reads)")
check(nlogged("lockpick minigame text") == 1, "the text logged once per change")

print("== P2. a pick breaks with more left: gone at once, the minigame goes on (single player)")
advance(1)
frame(ui)
break_pick(ui)
check(out_has(CW, "WLPBREAK"), "WLPBREAK sent")
check(logged("a lockpick broke here: 10 -> 9 lockpicks") ~= nil, "log: 10 -> 9 at once")
n, shown = frame(ui)
check(n == 9 and shown == "Lockpicks: 9", "the next frame: gate 9, screen 'Lockpicks: 9' (widgets still say 10) - " .. tostring(n) .. " " .. tostring(shown))
advance(0.6)
n = frame(ui)
check(n == 9, "the host's change not here yet, 0.6 s later: still 9 (not the stale 10)")
deliver()
check(logged("broke a lockpick: one taken out of its inventory") ~= nil, "the host took one out of that player's inventory")
have(9)
advance(0.6)
n, shown = frame(ui)
check(n == 9 and shown == "Lockpicks: 9", "the host's change arrived: 9 from the widgets")
check(logged("lockpicks here: 9 (inventory widgets, 1.2 s after the break: the host took the broken pick)") ~= nil,
    "log: the hold released when the host's change came")
check(nlogged("lockpicks here: 9 (") == 1, "no second count line for the same 9")

print("== P3. the last pick breaks: the minigame stops on the next frame (single player)")
have(1)
advance(1)
n, shown = frame(ui)
check(n == 1 and shown == "Lockpicks: 1", "one left: gate 1, screen 'Lockpicks: 1'")
advance(0.3)
break_pick(ui)
n, shown = frame(ui)
check(n == 0 and shown == "Lockpicks: 0", "broke: gate 0 at once (Lockpicks != 0 false: lock reset, pin hidden), screen 0")
for _ = 1, 40 do advance(0.016); n = frame(ui); if n ~= 0 then break end end
check(n == 0, "the stale widgets (still 1) do not let it go on before the host's change")
deliver()
have(0)
advance(1)
n, shown = frame(ui)
check(n == 0 and shown == "Lockpicks: 0", "the host's change arrived: 0")
check(logged("lockpicks here: 0 (inventory widgets") ~= nil, "log: 0 from the widgets")

print("== P4. the host never takes it: after the hold the widgets count again")
have(2)
advance(1)
frame(ui)
advance(0.3)
HW.outbox, CW.outbox = {}, {}
break_pick(ui)
CW.outbox = {}   -- lost on the way
n = frame(ui)
check(n == 1, "held at 1")
advance(3.5)
n, shown = frame(ui)
check(n == 2 and shown == "Lockpicks: 2", "3.5 s later still 2 in the widgets: 2 again")
check(logged("the host's change never came, the widgets count again") ~= nil, "log: the hold ran out")

print("== P5. a new minigame (new widget, same address too) shows the count from its first frame")
local ui2, tb2 = lockpick_ui("LockpickUI_C_2147480101")
advance(0.1)
n, shown = frame(ui2)
check(n == 2 and shown == "Lockpicks: 2" and tb2._bound == nil, "new widget: 2 on screen from the first frame")
-- the GC gave the next widget the old one's address
local ui3, tb3 = lockpick_ui("LockpickUI_C_2147480102")
ui3._addr = ui2._addr
n, shown = frame(ui3)
if shown ~= "Lockpicks: 2" then advance(0.3); n, shown = frame(ui3) end
check(shown == "Lockpicks: 2" and tb3._bound == nil, "same address, same count: set within 0.25 s")

print("== P6. count from the game's FindJigItemByDA (no widget slots): a break re-reads, no hold")
have(0)
CW.jig._m.FindJigItemByDA = function(self, da, t, a, b, nn, out) out.Result = da == da_c end
advance(1)
n = frame(ui2)
check(n == 1, "FindJigItemByDA: at least one")
advance(0.3)
break_pick(ui2)
check(logged("a lockpick broke here (count from the game's FindJigItemByDA") ~= nil, "log: re-read, not held")
CW.jig._m.FindJigItemByDA = function(self, da, t, a, b, nn, out) out.Result = false end
n = frame(ui2)
check(n == 0, "re-read at once: 0")

print("== P7. the host's own minigame and other roles are left alone")
WORLD = HW
local hui_tb = new(HW, { "TextBlock" }, "HTxt", { Text = FText("Lockpicks: 3") }, {
    GetText = function(self) return self._p.Text end,
    SetText = function(self, t) self._calls[#self._calls + 1] = { "SetText" }; self._p.Text = t end,
})
local hui = new(HW, { "LockpickUI_C" }, "LockpickUI_C_7", { LockpickTxt = hui_tb })
local hout = param(3)
fire(HW, UI .. ":GetLockpickAmount", param(hui), hout)
check(hout._v() == 3 and called(hui_tb, "SetText") == nil, "host: the game's own count and text")

-- 2026-11-13 log review: a client's Russian game showed "Отмычки: 0" and the
-- mod put the English "Lockpicks: 2" over it. Only the number changes now.
print("== P8. a Russian game: the game's own word stays, only the number changes")
do
    WORLD = CW
    game_text = "Отмычки: 0"
    have(2)
    advance(1)
    local ui8, tb8 = lockpick_ui("LockpickUI_C_2147480108")
    local n8, shown8 = frame(ui8)
    check(n8 == 2 and shown8 == "Отмычки: 2", "the screen shows 'Отмычки: 2', not 'Lockpicks: 2' - " .. tostring(shown8))
    check(logged("lockpick minigame text 'Отмычки: 0' -> 'Отмычки: 2'") ~= nil, "log: the game's word kept")
    have(1)
    advance(1)
    n8, shown8 = frame(ui8)
    check(n8 == 1 and shown8 == "Отмычки: 1", "the count changes on our own text, the word stays - " .. tostring(shown8))
    check(tb8._sets == 2, "SetText once per change (" .. tb8._sets .. ")")
    -- a screen whose text reads back without a number: the last game text seen with one
    local ui9, tb9 = lockpick_ui("LockpickUI_C_2147480109")
    tb9._bound = function() return FText("") end
    advance(1)
    n8, shown8 = frame(ui9)
    check(shown8 == "Отмычки: 1", "no number on screen: the game's last word with this count - " .. tostring(shown8))
    local tf = C.world._t.locks.text_for
    check(tf("Отмычки: 1 000", 7) == "Отмычки: 7", "a grouped number is replaced whole")
    check(tf("Lockpicks: 12", 3) == "Lockpicks: 3", "an English game: English text")
    check(tf("Lockpicks: {A}", 4) == "Lockpicks: 4", "no digits: the last text seen with one")
    game_text = "Lockpicks: 0"
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
