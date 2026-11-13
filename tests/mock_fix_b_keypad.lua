-- Mock harness (critic fix 2026-11-13, group B, A1): a client's press on a
-- keypad door. The door's server path on the host opens the game's KeypadUI
-- on the HOST's screen; sdc_world closes it there and the presser opens the
-- keypad on its own screen (WKEYUI). The host's widget is a UMG widget:
-- FindAllOf does not see it (as in UE4SS 3.0.1), WidgetBlueprintLibrary
-- .GetAllWidgetsOfClass does.
-- usage: lua mock_fix_b_keypad.lua <scripts dir>
-- (harness core copied from mock_world_locks.lua)
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
-- FindAllOf does not see UMG widgets (UserWidget children) in this UE4SS build
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(WORLD.objects) do
        if o._valid and derives(o, cls) and not derives(o, "UserWidget") then out[#out + 1] = o end
    end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(ms, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

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

local function engine(w, is_server)
    WORLD = w
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        GetCurrentLevelName = function() return "LongdownValley" end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
end
engine(HW, true)
engine(CW, false)

local function players(w)
    WORLD = w
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
players(HW)
players(CW)

-- the remote player's controller and character on the host
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1", { _loc = { X = 5000, Y = 0, Z = 0 } })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- keypad doors and widgets
local KEYPAD = "/Game/Blueprints/Other/Doors/Keypad/BP_KeypadDoor.BP_KeypadDoor_C"
local KEYUI = "/Game/UI/Widgets/Other/KeypadUI.KeypadUI_C"
local DOOR_AT = { X = 5100, Y = 0, Z = 0 }

-- the door's front faces -X (the presser at X 5000 stands in front of it)
local function keypad(w, name, code, at)
    WORLD = w
    return new(w, { "BP_KeypadDoor_C", "BP_MasterDoor_C" }, name, { Code = code, ["Open?"] = false,
        ["OpenedInThisInstance?"] = false, _loc = at or DOOR_AT }, {
        GetActorForwardVector = function() return { X = -1, Y = 0, Z = 0 } end,
    })
end
local hkp = keypad(HW, "BP_KeypadDoor_C_1", 4321)
local hkp2 = keypad(HW, "BP_KeypadDoor_C_2", 1234, { X = 5100, Y = 300, Z = 0 })
keypad(CW, "BP_KeypadDoor_C_1", 4321)
keypad(CW, "BP_KeypadDoor_C_2", 1234, { X = 5100, Y = 300, Z = 0 })

-- the host's UMG: GetAllWidgetsOfClass lists the live widgets of a class (top level = in the viewport)
WORLD = HW
new(HW, { "BlueprintGeneratedClass" }, "KeypadUI_C", {}, {}, KEYUI)
local wbl_calls = 0
new(HW, { "WidgetBlueprintLibrary" }, "WBL", {}, {
    GetAllWidgetsOfClass = function(self, wc, arr, cls, top)
        wbl_calls = wbl_calls + 1
        for _, o in ipairs(HW.objects) do
            if o._valid and derives(o, cls._name) and (not top or o._p._inv) then arr[#arr + 1] = o end
        end
    end,
}, "/Script/UMG.Default__WidgetBlueprintLibrary")
local function host_keypad_ui(name, door)
    WORLD = HW
    return new(HW, { "KeypadUI_C", "UserWidget" }, name, { DoorRef = door, _inv = true }, {
        IsInViewport = function(self) return self._p._inv end,
        PausePressed = function(self) self._p._inv = false; self._calls[#self._calls + 1] = { "PausePressed" } end,
    })
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
local lines = {}
local info0 = H.log.info
H.log.info = function(msg, ...)
    local ok, s = pcall(string.format, msg, ...)
    lines[#lines + 1] = ok and s or msg
    return info0(msg, ...)
end
local function logged(pat)
    for _, s in ipairs(lines) do if s:find(pat, 1, true) then return s end end
    return nil
end
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)

local function keyui_msgs()
    local out = {}
    for _, m in ipairs(HW.outbox) do if m:find("|WKEYUI|", 1, true) then out[#out + 1] = m end end
    return out
end
local function press(door, who)
    HW.outbox = {}
    lines = {}
    fire(HW, KEYPAD .. ":OnServerExecuteInteract", param(door), param({}), param(who), param({}))
end

-- ===========================================================================
print("== A1-1. the host's KeypadUI (UMG, unseen by FindAllOf) is found and closed; the presser opens its own")
local hui = host_keypad_ui("KeypadUI_C_1", hkp)
local other = host_keypad_ui("KeypadUI_C_2", hkp2)   -- another door's keypad on the host's screen
WORLD = HW
check(#FindAllOf("KeypadUI_C") == 0, "FindAllOf sees no KeypadUI (as in the game)")
press(hkp, rpawn)
check(wbl_calls > 0, "WidgetBlueprintLibrary.GetAllWidgetsOfClass asked")
check(called(hui, "PausePressed") ~= nil and hui._p._inv == false, "the host's keypad of that door closed the widget's own way")
check(called(other, "PausePressed") == nil and other._p._inv == true, "another door's keypad stays")
local k = keyui_msgs()
check(#k == 1 and k[1]:find("|WKEYUI|~LongdownValley~BP_KeypadDoor_C_1|4321", 1, true) ~= nil, "WKEYUI with the door and the host's code: " .. tostring(k[1]))
check(logged("opened on that player's screen, not the host's (host's widget closed)") ~= nil, "host log line (widget closed)")
WORLD = HW
check(H.world._t.resolver(hkp) == rpc, "that player is at the door (its XP / noise on the host are that player's)")

print("== A1-2. no host widget found, but the door's path made one: WKEYUI all the same")
other._p._inv = false
advance(200)   -- (the aim of the press above times out)
press(hkp, rpawn)
k = keyui_msgs()
check(#k == 1, "WKEYUI sent although no widget was found here")
check(logged("(host's widget not found)") ~= nil, "host log line (not found)")

print("== A1-3. presses where the door's path makes no keypad: nothing")
hkp._p["OpenedInThisInstance?"] = true
press(hkp, rpawn)
check(#keyui_msgs() == 0, "opened by its code in this world already: the press only toggles it (MC_OpenDoor)")
hkp._p["OpenedInThisInstance?"] = false
rpawn._p._loc = { X = 4500, Y = 0, Z = 0 }
press(hkp, rpawn)
check(#keyui_msgs() == 0, "6 m away: the door's path did nothing")
rpawn._p._loc = { X = 5200, Y = 0, Z = 0 }
press(hkp, rpawn)
check(#keyui_msgs() == 0, "behind the door: it opens from behind (Event_OpenDoorBehind), no keypad")
rpawn._p._loc = { X = 5000, Y = 0, Z = 0 }

print("== A1-4. the host's own press: its keypad stays on the host's screen")
hui._p._inv = true
hui._calls = {}
press(hkp, HW.pawn)
check(called(hui, "PausePressed") == nil and hui._p._inv == true and #keyui_msgs() == 0, "untouched, nothing sent")

print("== A1-5. the client opens the game's keypad on WKEYUI")
WORLD = CW
new(CW, { "BlueprintGeneratedClass" }, "KeypadUI_C", {}, {}, KEYUI)
local cui
new(CW, { "WidgetBlueprintLibrary" }, "WBL", {}, {
    Create = function(self, wco, cls, pc)
        cui = new(CW, { "KeypadUI_C", "UserWidget" }, "KeypadUI_C_2147480001", { CurrentCode = "" }, {
            AddToViewport = function(s) s._p._inv = true end,
        })
        return cui
    end,
    SetInputMode_GameAndUIEx = function() end,
}, "/Script/UMG.Default__WidgetBlueprintLibrary")
CW.pawn._m.DisableInput = function() end
press(hkp, rpawn)
local msg = keyui_msgs()[1]
WORLD = CW
local kind, f = C.net.decode(msg or "")
if kind then C.net.handlers[kind](f, CW.pc) end
check(cui ~= nil and cui._p._inv == true and cui._p.AcceptedCode == 4321, "the client's own keypad: on screen, the host's code")

print("== horde beacon (2026-11-13): sdc_world's beacon kind asks sdc_horde (ctx.beacon_scope) first, else the build rule")
WORLD = HW
local hb = new(HW, { "Buildable_HordeBeacon_C", "Buildable_MASTER_C" }, "Buildable_HordeBeacon_C_1",
    { CurrentActor = rpawn, _loc = { X = 0, Y = 0, Z = 0 } })
local crate = new(HW, { "Buildable_AmmoCrate_C", "Buildable_MASTER_C" }, "Buildable_AmmoCrate_C_1",
    { CurrentActor = rpawn, _loc = { X = 0, Y = 0, Z = 0 } })
local asked, answer = {}, nil
H.ctx.beacon_scope = function(o) asked[#asked + 1] = o; return answer end
check(H.world._t.resolver(hb) == rpc and asked[#asked] == hb, "asked; no answer: the build rule (its presser, the client)")
answer = false
check(H.world._t.resolver(hb) == false, "its answer false (the host): false")
hb._p.CurrentActor = HW.pawn
answer = rpc
check(H.world._t.resolver(hb) == rpc, "its answer, a client: that client (the presser, the host, is dead)")
local n_asked = #asked
check(H.world._t.resolver(crate) == rpc and #asked == n_asked, "another buildable: not asked, the build rule")
H.ctx.beacon_scope = nil
hb._p.CurrentActor = rpawn
check(H.world._t.resolver(hb) == rpc, "no sdc_horde: the build rule")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
