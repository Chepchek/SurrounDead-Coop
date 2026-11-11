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

-- ------------------------------------------------------------ modules
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local log = require("sdc_log")
local out = {}
log.toast_sink = function(text) out[#out + 1] = text end
local ctx = require("sdc_ctx")
ctx.SCOPE_API = 1
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... } }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
local players = require("sdc_players")
local localinit = require("sdc_localinit")
local respawn = require("sdc_respawn")

local S = { role = "host", remote = {}, remote_pcs = {}, spawned = {}, in_menu = false, menu_since = 0 }
players.init(S, { remote_record = function(pc) return S.remote[pc:GetFullName()] end })
respawn.install(S)
check(ctx.scope_resolver ~= nil, "resolver installed")

-- world: GI, host pc + pawn, remote pc + dead body
local gi = new_obj("SD_GameInstance_C", "SD_GameInstance_C_0", {}, {})
local host_pawn = new_obj("BP_PlayerCharacter_C", "Host", { __loc = { X = 1000, Y = 0, Z = 100 } }, {})
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_pawn, Player = new_obj("LocalPlayer", "LP", {}, {}) }, {})
host_pc._m.IsLocalController = function() return true end
host_pawn._p.Controller = host_pc
registry["PlayerController"] = { host_pc }
local conn = new_obj("IpConnection", "Conn", {}, {})
local body = new_obj("BP_PlayerCharacter_C", "Body", { ["PlayerDead?"] = true }, {})
local rpc = new_obj("BP_PlayerController_C", "RemotePC", { NetConnection = conn, RespawnPointEnabled = false,
    RespawnLoc = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } } }, {})
local key = rpc:GetFullName()
local r = { key = key, pc = rpc, index = 1, name = "Friend", hello = true, pawn = body, dead = true, spawned_once = true }
S.remote[key] = r
S.remote_pcs = { rpc }


-- ======================= sdc_progress
print("progress")
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end
local progress = require("sdc_progress")
progress.install(S)
run_delayed()
check(loops.progress ~= nil, "progress tick scheduled")
local deleted = 0
local lib = new_obj("EMSFunctionLibrary", "Default__EMSFunctionLibrary", {}, {})
lib._m.DeleteAllSaveDataForSlot = function(_, wc, slot) if slot == "SDCoop_ClientTemp" then deleted = deleted + 1 end end
rawset(by_path, "/Script/EasyMultiSave.Default__EMSFunctionLibrary", lib)
-- host: startup cleanup + host copy check
S.role = "host"
loops.progress()
check(deleted == 1, "leftover slot emptied at startup")
-- client
local calls = {}
local function comp(cls, props)
    return new_obj(cls, cls, props, setmetatable({}, { __index = function(_, k) return function() calls[#calls + 1] = cls .. "." .. k end end }))
end
local lev = comp("LevellingComponent_C", { CurrentLevel = 5, CurrentXP = 1234, CurrentMaxXP = 2000 })
lev._m.Reset = function(self) self._p.CurrentLevel = 1; self._p.CurrentXP = 0; self._p.CurrentMaxXP = 500; calls[#calls+1]="Reset" end
local ps = comp("PassiveSkillsComponent_C", { CurrentFitnessLevel = 3 })
local tech = comp("TechTreeComponent_C", { SkillPoints = 4, CurrentPoints = 4 })
local cpc = new_obj("BP_PlayerController_C", "ClientPC", { Player = new_obj("LocalPlayer", "LP2", {}, {}),
    LevellingComponent = lev, PassiveSkillsComponent = ps, TechTreeComponent = tech, ZombieKills = 12 }, {})
cpc._m.BindPlayerRespawn = function() calls[#calls+1] = "BindPlayerRespawn" end
cpc._m.IsLocalController = function() return true end
registry["PlayerController"] = { cpc }
ue.forget_world()
S.role = "client"; S.client = {}
loops.progress()
check(deleted == 2, "slot emptied at a new connection")
local hud = new_obj("BP_Ingame_C", "HUD", {}, {})
local cpawn = new_obj("BP_PlayerCharacter_C", "ClientChar", { ["PlayerDead?"] = false, InGameUI = hud }, {})
cpc._p.Pawn = cpawn
loops.progress()
check(lev._p.CurrentLevel == 5, "not before 6 s")
-- sdc_persist: the host answers "no saved character" (PSFRESH); without an
-- answer the client would wait up to 15 s after its id / 45 s after joining
net.handlers.PSFRESH({ "g1", "1" })
os.time = (function(t0) return function() return t0 + 10 end end)(os.time())
loops.progress()
check(lev._p.CurrentLevel == 1 and lev._p.CurrentXP == 0, "level reset to 1 / XP 0")
check(tech._p.SkillPoints == 0 and cpc._p.ZombieKills == 0 and cpc._p.DaysSurvived == 1, "points and journal reset")
local seen = table.concat(calls, ",")
check(seen:find("ResetPassiveSkills_NewSave") and seen:find("Event_ComponentLoad") and seen:find("BindPlayerRespawn"), "game functions called: " .. seen)
-- the game's own load finishes later: reset again
lev._p.CurrentLevel = 7
local lh = hooks["/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:OnCompleted_F36E30354316ADD99BBAD29E4E315233"]
check(lh ~= nil and lh.post == nil, "load-finished hook, one callback")
lh.pre(param(cpc))
check(lev._p.CurrentLevel == 1, "reset after the game's own load")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
