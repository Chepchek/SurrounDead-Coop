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

-- ------------------------------------------------------------ skill tree
local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat) then return l end end
    return nil
end
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end
local net = require("sdc_net")
local sent = {}
net.send_to_host = function(kind, ...) sent[#sent + 1] = { kind = kind, args = { ... } }; return true end

local SK = { "Skill_CombatRoll", "Skill_CriticalHitter", "Skill_Deathbringer", "Skill_DemolitionExpert",
    "Skill_Distraction", "Skill_HarvestMaster", "Skill_HealthRegen", "Skill_Huntsman", "Skill_Lockpick",
    "Skill_NightCreature", "Skill_Parkour" }
local asset = {}
for _, n in ipairs(SK) do
    local o = new_obj("BP_SkillTreeAsset_C", n, {}, {})
    asset[n] = o
    rawset(by_path, "/Game/Blueprints/SkillTree/Skills/" .. n .. "." .. n, o)
end
local function tree_comp(short)
    local state = {}
    local c = new_obj("TechTreeComponent_C", short, { SkillPoints = 0, CurrentPoints = 0 }, {})
    c._m.IsTechnologyUnlocked = function(_, o) return state[o._short] == true end
    c._m.LockTechnology = function(_, o) state[o._short] = nil end
    c._state = state
    return c
end

local tech = tree_comp("ClientTech")
local lp = new_obj("LocalPlayer", "LP", {}, {})
local cpc = new_obj("BP_PlayerController_C", "ClientPC", { Player = lp, TechTreeComponent = tech }, {})
cpc._m.IsLocalController = function() return true end
registry["PlayerController"] = { cpc }

local S = { role = "client", client = {}, remote = {}, remote_pcs = {} }
local progress = require("sdc_progress")
local tree = require("sdc_skilltree")
progress.install(S)
check(loops.skilltree ~= nil, "skilltree tick scheduled (installed by sdc_progress)")
local LOAD = "/Script/TechTree.TechTreeManager:LoadTechStateFromSlot"
local ISU = "/Script/TechTree.TechTreeManager:IsTechnologyUnlocked"
check(hooks[LOAD] and hooks[LOAD].pre ~= nil, "load pre-hook registered at install")

-- 1. the game's tree load on a client goes to an empty slot
net_mode = "client"
local slot = param("SDCoop_ClientTemp_SkillTree")
hooks[LOAD].pre(param(tech), slot, param(0))
check(slot:get() == "SDCoop_NoSkillTree", "client load redirected to an empty slot")
net_mode = "standalone"
local slot2 = param("Slot 1_SkillTree")
hooks[LOAD].pre(param(tech), slot2, param(0))
check(slot2:get() == "Slot 1_SkillTree", "single player load untouched")
net_mode = "client"

-- 2. not before sdc_progress is ready
local ready = false
progress.client_ready = function() return ready end
tech._state.Skill_Parkour = true
tech._state.Skill_HealthRegen = true
loops.skilltree()
check(#sent == 0, "nothing sent before the reset")
ready = true
loops.skilltree()
check(#sent == 1 and sent[1].kind == "SKTREE" and sent[1].args[1] == "Skill_HealthRegen,Skill_Parkour", "unlocked list sent: " .. tostring(sent[1] and sent[1].args[1]))
loops.skilltree()
check(#sent == 1, "unchanged list not resent within 20 s")

-- 3. relock (sdc_progress reset) -> empty list
local locked = tree.relock(tech, "test")
check(#locked == 2 and not tech._state.Skill_Parkour, "relock locked both")
loops.skilltree()
check(#sent == 2 and sent[2].args[1] == "-", "empty list sent after relock")

-- 4. host side
S.role = "host"
local htech = tree_comp("HostCopyTech")
local conn = new_obj("IpConnection", "Conn", {}, {})
local rpc = new_obj("BP_PlayerController_C", "RemotePC", { NetConnection = conn, TechTreeComponent = htech }, {})
local key = rpc:GetFullName()
S.remote[key] = { pc = rpc, name = "bag" }
net.handlers.SKTREE({ "Skill_HealthRegen,Skill_CriticalHitter" }, rpc)
check(logged("skilltree: bag's unlocked skills: Skill_HealthRegen,Skill_CriticalHitter") ~= nil, "host logs the list")
loops.skilltree()
check(hooks[ISU] and hooks[ISU].post ~= nil, "IsTechnologyUnlocked post-hook registered")
local post = hooks[ISU].post
check(post(param(htech), param(false), param(asset.Skill_HealthRegen)) == true, "host answers true for the client's HealthRegen")
check(post(param(htech), param(false), param(asset.Skill_Parkour)) == false, "host answers false for a locked skill")
local own = tree_comp("HostOwnTech")
check(post(param(own), param(true), param(asset.Skill_Parkour)) == nil, "host's own tree untouched")
check(logged("the game asked on the host whether bag has Skill_HealthRegen %-> true") ~= nil, "first answer logged")
-- reset on the client side -> '-'
net.handlers.SKTREE({ "-" }, rpc)
check(post(param(htech), param(false), param(asset.Skill_HealthRegen)) == false, "after the client's reset: false")
-- config off
cfg.values.skilltree_sync = false
loops.skilltree()
check(post(param(htech), param(false), param(asset.Skill_HealthRegen)) == nil, "skilltree_sync off: engine answer")
cfg.values.skilltree_sync = nil
-- player left
S.remote = {}
loops.skilltree()
check(post(param(htech), param(false), param(asset.Skill_HealthRegen)) == nil, "left: engine answer")
check(progress.status_line():find("skilltree: sent=2") ~= nil, "status line: " .. progress.status_line())

print = real_print
for _, l in ipairs(lines) do if l:find("skilltree:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
