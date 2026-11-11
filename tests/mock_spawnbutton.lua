-- Mock harness for sdc_respawn / sdc_players (unstuck, respawn screen, skip-save)
-- / sdc_localinit (Event_LoadLevel block). usage: lua mock_respawn.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails = 0
local function check(cond, what)
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
local registry = {}          -- class -> list
local by_path = {}           -- path -> object

local function new_obj(cls, short, props, methods)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }
    setmetatable(o, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    local p = rawget(t, "_p")[k]
    if p ~= nil then return p end
    return nil
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:GetOwner() return self._p.__owner end
function Obj:K2_DestroyActor() self._valid = false end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = { pre = pre, post = post }; return 1, 2 end
function FindAllOf(cls) return registry[cls] or {} end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path) return by_path[path] end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(ms, f) delayed[#delayed + 1] = f; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay(ms, f) delayed[#delayed + 1] = f end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end
local function run_delayed() local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end

-- every hookable path "exists"
setmetatable(by_path, { __index = function(_, k)
    if k:find(":") then return new_obj("Function", k) end
    return nil
end })

local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {})
local net_mode = "client"
ksl._m.IsStandalone = function(_, w) return net_mode == "standalone" end
ksl._m.IsServer = function(_, w) return net_mode ~= "client" end
ksl._m.K2_IsTimerActive = function() return true end
ksl._m.GetCommandLine = function() return "" end
rawset(by_path, "/Script/Engine.Default__KismetSystemLibrary", ksl)
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {})
rawset(by_path, "/Script/Engine.Default__GameplayStatics", gps)

local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat) then return l end end
    return nil
end
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text) toasts[#toasts + 1] = text end
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end
ue.delay = function(label, ms, fn) fn() end
local ctx = require("sdc_ctx")
ctx.SCOPE_API = 1
local players = require("sdc_players")
local respawn = require("sdc_respawn")

local lp = new_obj("LocalPlayer", "LP", {}, {})
local pawn = new_obj("BP_PlayerCharacter_C", "HostChar", { ["PlayerDead?"] = false }, {})
local pc = new_obj("BP_PlayerController_C", "HostPC", { Player = lp, Pawn = pawn, RespawnPointEnabled = false,
    RespawnLoc = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } } }, {})
pc._m.IsLocalController = function() return true end
pawn._p.Controller = pc
registry["PlayerController"] = { pc }
local S = { role = "host", remote = {}, remote_pcs = {}, spawned = {}, in_menu = false, menu_since = 0 }
players.init(S, { remote_record = function() return nil end })
respawn.install(S)
check(loops.respawn ~= nil, "respawn tick scheduled")
loops.respawn()
local FN = "/Game/UI/Widgets/Player/RespawnScreen.RespawnScreen_C:BndEvt__RespawnScreen_RespawnSpawnPointButton_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature"
check(hooks[FN] and hooks[FN].pre ~= nil and hooks[FN].post == nil, "spawn-point button hook: one callback")
check(logged("own respawn point not set") ~= nil, "own point logged")
-- no point: Russian notice
local screen = new_obj("RespawnScreen_C", "RespawnScreen_C_1", {}, {})
hooks[FN].pre(param(screen))
check(#toasts == 1 and toasts[1]:find("Точка возрождения не задана") and toasts[1]:find("случайно%.$"), "host notice: " .. tostring(toasts[1]))
-- client wording
S.role = "client"
hooks[FN].pre(param(screen))
check(#toasts == 2 and toasts[2]:find("рядом с хостом"), "client notice")
S.role = "host"
-- with a point: no notice, logged
pc._p.RespawnPointEnabled = true
pc._p.RespawnLoc = { Translation = { X = 100, Y = 200, Z = 300 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
hooks[FN].pre(param(screen))
check(#toasts == 2, "no notice with a point")
check(logged("respawns at the respawn point %(set at 100,200,300%)") ~= nil, "point respawn logged")
loops.respawn()
check(logged("own respawn point set at 100,200,300 %(was not set%)") ~= nil, "point change logged")
-- own character: death
pawn._p["PlayerDead?"] = true
loops.respawn()
check(logged("own character HostChar died") ~= nil, "death logged")
-- new character, then lost while alive
local p2 = new_obj("BP_PlayerCharacter_C", "HostChar2", { ["PlayerDead?"] = false, Controller = pc }, {})
pc._p.Pawn = p2
loops.respawn()
pc._p.Pawn = nil
p2._p.Controller = nil
loops.respawn()
check(logged("own controller lost its living character HostChar2 without a death") ~= nil, "loss while alive logged")
check(respawn.status_line():find("no_point=2") ~= nil, "status: " .. respawn.status_line():sub(1, 80))
print = real_print
for _, l in ipairs(lines) do if l:find("FAIL") or l:find("own ") or l:find("spawn%-point") or l:find("TOAST") then io.write(l, string.char(10)) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
