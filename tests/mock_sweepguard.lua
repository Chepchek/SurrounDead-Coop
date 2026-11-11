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
-- extra fakes for the guard
local log = require("sdc_log")
local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat) then return l end end
    return nil
end
function Obj:GetWorld() return self._p.__world end
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {})
rawset(by_path, "/Script/Engine.Default__KismetSystemLibrary", ksl)
local isvalid_calls = 0
local isvalid_fn = setmetatable({}, {
    __call = function(_, k, o) isvalid_calls = isvalid_calls + 1; assert(k == ksl); return o._valid and not o._garbage end,
    __index = { IsValid = function() return true end },
})
rawset(by_path, "/Script/Engine.KismetSystemLibrary:IsValid", isvalid_fn)
local char_class = new_obj("BlueprintGeneratedClass", "BP_PlayerCharacter_C", {}, {})
rawset(by_path, "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C", char_class)
local marker_class = new_obj("BlueprintGeneratedClass", "BP_Marker_C", {}, {})

local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end
local guard = require("sdc_sweepguard")

local W = new_obj("World", "LongdownValley", {}, {})
local W2 = new_obj("World", "MainMenu", {}, {})
local function char(short, props)
    props = props or {}
    props.__world = props.__world or W
    local c = new_obj("BP_PlayerCharacter_C", short, props, {})
    rawset(c, "ClearUI", function(self) self._cleared = (self._cleared or 0) + 1 end)
    rawset(c, "K2_DestroyActor", function(self) self._destroyed = true; self._garbage = true
        local ctl = self._p.Controller
        if ctl and ctl._p.Pawn == self then ctl._p.Pawn = nil end
        self._p.Controller = nil
    end)
    return c
end
local lp = new_obj("LocalPlayer", "LP", {}, {})
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Player = lp, __world = W }, {})
host_pc._m.IsLocalController = function() return true end
registry["PlayerController"] = { host_pc }
local conn = new_obj("IpConnection", "Conn", {}, {})
local rpc = new_obj("BP_PlayerController_C", "RemotePC", { NetConnection = conn, Player = conn, __world = W }, {})
local host_body = char("HostOld", { ["PlayerDead?"] = true })          -- dead, unpossessed
local client_char = char("ClientChar", { ["PlayerDead?"] = false, Controller = rpc })
rpc._p.Pawn = client_char
local cdo = char("Default__BP_PlayerCharacter_C", {})
local other_world = char("MenuLeftover", { __world = W2 })
local garbage = char("OldGarbage", {}); garbage._garbage = true

local S = { role = "host", remote = {}, remote_pcs = {} }
guard.install(S)
check(loops.sweepguard ~= nil, "tick scheduled")
loops.sweepguard()
local H = hooks["/Script/Engine.GameplayStatics:GetAllActorsOfClass"]
check(H == nil, "no hook without remote players")

local r = { pc = rpc, name = "guest", pawn = client_char }
S.remote["RemotePC"] = r
S.remote_pcs = { rpc }
loops.sweepguard()
H = hooks["/Script/Engine.GameplayStatics:GetAllActorsOfClass"]
check(H ~= nil and H.pre ~= nil, "pre-hook registered with remote players")

-- 1. the host's random respawn on its death screen
local screen = new_obj("RespawnScreen_C", "RespawnScreen_C_1", {}, {})
local wp, cp = param(screen), param(char_class)
H.pre(param(gps), wp, cp, param({}))
check(wp:get() == nil, "screen's world context emptied")
check(host_body._destroyed and host_body._cleared == 1, "host's old body: ClearUI + destroy")
check(not client_char._destroyed and not client_char._cleared and rpc._p.Pawn == client_char, "client's character untouched")
check(not cdo._destroyed and not other_world._destroyed and not garbage._cleared, "default object / other world / destroyed ones skipped")
check(logged("guard: RespawnScreen_C was about to remove every player character: kept 1 of remote players %[ClientChar of guest%]") ~= nil, "guard line")
check(isvalid_calls > 0, "engine IsValid used")

-- 2. another class: untouched
local wp2 = param(screen)
H.pre(param(gps), wp2, param(marker_class), param({}))
check(wp2:get() == screen, "other classes pass")

-- 3. not a guarded caller: warn only
local zombie = new_obj("BP_MasterZombie_C", "Zombie_1", {}, {})
local wp3 = param(zombie)
H.pre(param(gps), wp3, param(char_class), param({}))
check(wp3:get() == zombie, "unguarded caller passes")
check(logged("guard: BP_MasterZombie_C asks for every player character") ~= nil, "unguarded warning")

-- 4. the client's character dead and unpossessed (waiting on its death screen): still kept
client_char._p["PlayerDead?"] = true
client_char._p.Controller = nil
rpc._p.Pawn = nil
local host_new = char("HostNew", { ["PlayerDead?"] = false, Controller = host_pc })
host_pc._p.Pawn = host_new
local pause = new_obj("PauseScreen_C", "PauseScreen_C_1", {}, {})
local wp4 = param(pause)
H.pre(param(gps), wp4, param(char_class), param({}))
check(wp4:get() == nil and host_new._destroyed and not client_char._destroyed, "suicide: host's live body removed, client's dead body kept")

-- 5. watch: a living remote character destroyed by something else -> warn
client_char._p["PlayerDead?"] = false
local c2 = char("ClientChar2", { ["PlayerDead?"] = false, Controller = rpc })
rpc._p.Pawn = c2
r.pawn = c2
loops.sweepguard()
c2:K2_DestroyActor()
loops.sweepguard()
check(logged("guard: guest lost their living character ClientChar2 %(destroyed%); their controller has no pawn") ~= nil, "lost-character warning")

-- 6. disabled by config
cfg.values.guard_player_sweeps = false
loops.sweepguard()
local c3 = char("ClientChar3", { ["PlayerDead?"] = false, Controller = rpc })
rpc._p.Pawn = c3
local wp6 = param(screen)
H.pre(param(gps), wp6, param(char_class), param({}))
check(wp6:get() == screen, "off when the config says so (key unknown to this config: nil -> on)")

-- 7. host without remote players: inactive
cfg.values.guard_player_sweeps = nil
S.remote = {}
loops.sweepguard()
local wp7 = param(screen)
H.pre(param(gps), wp7, param(char_class), param({}))
check(wp7:get() == screen, "inactive without remote players")
check(guard.status_line():find("guard: hook=true") ~= nil, "status line")

print = real_print
for _, l in ipairs(lines) do if l:find("guard:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
