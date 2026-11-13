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

-- ------------------------------------------------------------ 1. scope resolve
print("scope")
check(ctx.scope_resolver(gi) == nil, "no scope: no opinion")

-- respawn RPC: pre -> (game would spawn+possess) -> post
print("native respawn")
local h = hooks["/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:Svr_RequestRespawn_SpawnPoint"]
check(h == nil, "hooks only after the tick")
-- run the module tick by hand: it is local; call through the delayed boot
run_delayed()
-- respawn's tick is scheduled with ue.every (stubbed): call install hooks via a host tick surrogate
local tick_fn = nil
for name, fn in pairs(package.loaded["sdc_respawn"]) do _ = name end
-- emulate: register hooks the way tick() does
do
    local M = package.loaded["sdc_respawn"]
    -- the tick is local; reach it through ue.every's callback capture
end
-- capture ue.every callbacks
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end
respawn.install(S)
run_delayed()
check(loops.respawn ~= nil, "tick scheduled")
loops.respawn()
h = hooks["/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:Svr_RequestRespawn_SpawnPoint"]
check(h ~= nil, "SpawnPoint hook registered")
check(hooks["/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:Event_ConstructMap"] ~= nil, "minimap hook registered")
do
    local mh = hooks["/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:Event_ConstructMap"]
    check(mh.post == nil, "minimap hook: one callback")
    local removed = false
    local mw = new_obj("MapWidget_C", "MW", {}, { IsInViewport = function() return true end, RemoveFromParent = function() removed = true end })
    local rpawn = new_obj("BP_PlayerCharacter_C", "RemoteChar", {}, { IsLocallyControlled = function() return false end })
    local mcomp = new_obj("BPC_MinimapSystem_C", "MM", { __owner = rpawn, MapWidget = mw }, {})
    mh.pre(param(mcomp))
    check(removed, "remote character's minimap taken off the host's screen")
    removed = false
    host_pawn._m.IsLocallyControlled = function() return true end
    local hcomp = new_obj("BPC_MinimapSystem_C", "MM2", { __owner = host_pawn, MapWidget = mw }, {})
    mh.pre(param(hcomp))
    check(not removed, "host's own minimap kept")
end
local capsent = false
for _, m in ipairs(sent) do if m.kind == "RSPCAP" then capsent = true end end
check(capsent, "RSPCAP sent to the client")

-- BeginPlay-time call (no character yet): nothing
r.spawned_once = false
local gih = hooks["/Script/Engine.GameplayStatics:GetGameInstance"]
check(gih ~= nil and gih.post == nil, "GetGameInstance native pre-hook registered (sdc_ue.hook_native: pre only, no empty post)")
gih.pre(nil, param(rpc))
check(ctx.scope_resolver(gi) == nil, "BeginPlay GetGameInstance: no scope")
r.spawned_once = true
-- the RPC body: GetGameInstance(self) (native pre) ...
gih.pre(nil, param(rpc))
check(body:IsValid(), "dead body kept until the post")
check(ctx.scope_resolver(gi) == rpc, "GI -> remote pc inside the call")
gih.pre(nil, param(rpc))   -- once per request
local marker = new_obj("BP_PlayerMarker_C", "PM", {}, {})
check(ctx.scope_resolver(marker) == rpc, "marker -> remote pc")
check(ctx.scope_resolver(host_pawn) == nil, "host pawn: no opinion")
-- ... Survival_Respawn spawns + possesses
local newp = new_obj("BP_PlayerCharacter_C", "NewChar", { ["ShowStartingQuests?"] = true }, {})
check(ctx.scope_resolver(newp) == rpc, "new character before possession -> remote pc")
newp._p.Controller = rpc
rpc._p.Pawn = newp
check(ctx.scope_resolver(newp) == rpc, "new character after possession -> remote pc")
-- ... then the RPC's Blueprint hook (single callback, after the body)
h.pre(param(rpc))
check(not body:IsValid(), "dead body destroyed in the post")
check(newp._p["ShowStartingQuests?"] == false, "starting quest cleared")
check(r.pawn == newp and r.dead == false and not r.spawn_pending, "record updated")
check(ctx.scope_resolver(gi) == nil, "GI scope closed after the call")
check(ctx.scope_resolver(marker) == rpc, "marker window still open")
T = T + 5
check(ctx.scope_resolver(marker) == nil, "marker window closed after 4.5 s")
run_delayed()
check(newp:IsValid() and rpc._p.Pawn == newp, "timer after the post: nothing more happens")
-- a GetGameInstance(remote pc) that is no respawn: alive, same pawn -> untouched
newp._p["PlayerDead?"] = false
gih.pre(nil, param(rpc))
run_delayed()
check(newp:IsValid() and rpc._p.Pawn == newp, "not a respawn after all: character untouched")

-- ------------------------------------------------------------ 2. beds (host)
print("beds host")
loops.respawn()
local bedh = hooks["/Game/Blueprints/Components/BedComponent.BedComponent_C:SetSpawnPoint"]
local goh = hooks["/Game/Blueprints/Components/BedComponent.BedComponent_C:GoToBed"]
check(bedh and goh and bedh.post == nil, "bed hooks registered with one callback")
local bed = new_obj("Buildable_Bed_C", "Bed", { CurrentActor = newp, __loc = { X = 50, Y = 60, Z = 70 } }, {})
local comp = new_obj("BedComponent_C", "BedComponent", { __owner = bed }, {})
check(ctx.scope_resolver(comp) == rpc, "bed component -> its CurrentActor's (remote) controller")
sent = {}
local tf = { Translation = { X = 11, Y = 22, Z = 33 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } }
bedh.pre(param(comp), param(tf))   -- the single callback = after SetSpawnPoint
check(sent[1] and sent[1].kind == "BED" and sent[1].args[1] == "spawn", "BED spawn sent")
local sky = new_obj("Ultra_Dynamic_Sky_C", "Sky", { ["Time of Day"] = 2100 }, {})
sent = {}
goh.pre(param(comp), param(1930), param(630))
check(sent[1] and sent[1].args[1] == "sleep", "BED sleep at 21:00")
sky._p["Time of Day"] = 1200
sent = {}
goh.pre(param(comp), param(1930), param(630))
check(sent[1] and sent[1].args[1] == "early", "BED early at 12:00")
-- host's own use
bed._p.CurrentActor = host_pawn
check(ctx.scope_resolver(comp) == false, "host's own bed use: player 0 stays")
sent = {}
goh.pre(param(comp), param(1930), param(630))
check(#sent == 0, "host's own use: no message")
bed._p.CurrentActor = nil
check(ctx.scope_resolver(comp) == nil, "no CurrentActor: no opinion")

-- SLEEP from the client
print("sleep")
local transitioned = nil
sky._m["Transition Time of Day"] = function(_, t) transitioned = t end
sky._p["Time of Day"] = 2200
players.register_handlers()
local handlers = net.handlers
cfg.values.coop_sleep_all = false   -- the older rule; the co-op rule: mock_coopsleep.lua
handlers.SLEEP({}, rpc)
check(transitioned == 650, "host ran Transition Time of Day(650)")
cfg.values.coop_sleep_all = nil

-- SPAWNPT
handlers.SPAWNPT({ "5", "6", "7", "0", "0", "0", "1" }, rpc)
check(rpc._p.RespawnPointEnabled == true and rpc._p.RespawnLoc.Translation.X == 5, "SPAWNPT copied to the host-side controller")

-- ------------------------------------------------------------ 3. unstuck (host side)
print("unstuck host")
newp._p["PlayerDead?"] = false
cfg.set("client_movement_authority", true)
sent = {}
handlers.UNSTUCK({ "host" }, rpc)
check(sent[1] and sent[1].kind == "UNSTUCKTO", "client-authoritative: spot sent")
sent = {}
handlers.UNSTUCK({ "host" }, rpc)
check(sent[1] and sent[1].kind == "UNSTUCKOK" and sent[1].args[1] == "refused" and sent[1].args[2] == "soon", "rate-limited")
r.unstuck_at = -1000
cfg.set("client_movement_authority", false)
local tele = nil
newp._m.K2_TeleportTo = function(_, dest) tele = dest; return true end
sent = {}
handlers.UNSTUCK({ "host" }, rpc)
check(tele ~= nil and sent[1].kind == "UNSTUCKOK" and sent[1].args[1] == "ok", "host teleported the server copy")

-- skip-save
print("skip-save")
local lib = new_obj("EMSFunctionLibrary", "Default__EMSFunctionLibrary", {}, {})
local marked = {}
lib._m.SetActorSaveProperties = function(_, a) marked[a._short] = true end
rawset(by_path, "/Script/EasyMultiSave.Default__EMSFunctionLibrary", lib)
players.host_skip_save_tick()
check(marked.RemotePC and marked.NewChar and not marked.Host, "remote pc + remote char marked, host not")

-- ------------------------------------------------------------ 4. client side
print("client")
S.role = "client"
S.client = {}
loops.respawn()
handlers.RSPCAP({ "1" })
check(players.native_respawn_ok() == true, "native respawn ok after RSPCAP")
cfg.values.respawn_native = false
check(players.native_respawn_ok() == false, "config off")
cfg.values.respawn_native = nil
-- BED spawn on the client, no bed copy found: direct write
local cpc = new_obj("BP_PlayerController_C", "ClientPC", { Player = new_obj("LocalPlayer", "LP2", {}, {}),
    RespawnPointEnabled = false, RespawnLoc = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } } }, {})
registry["PlayerController"] = { cpc }
ue.forget_world()
registry["BedComponent_C"] = {}
handlers.BED({ "spawn", "900", "900", "900", "1", "2", "3", "0", "0", "0", "1" })
check(cpc._p.RespawnPointEnabled == true and cpc._p.RespawnLoc.Translation.X == 1, "client respawn point set directly")
-- sleep button
local sleeph = hooks["/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C:BndEvt__Button_60_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"]
check(sleeph ~= nil, "sleep button hook")
sent = {}
check(sleeph.post == nil, "sleep hook: one callback")
sleeph.pre(param(nil))
check(sent[1] and sent[1].kind == "SLEEP", "SLEEP sent")
-- unstuck request
local cpawn = new_obj("BP_PlayerCharacter_C", "ClientChar", { ["PlayerDead?"] = false }, {})
cpc._p.Pawn = cpawn
sent = {}
check(players.request_unstuck("host") == true and sent[1].kind == "UNSTUCK", "unstuck asked")
check(players.request_unstuck("host") == false, "client cooldown")
handlers.UNSTUCKTO({ "1", "2", "3", "0", "host" })

-- Event_LoadLevel block
print("menu level")
local lh = hooks["/Script/Engine.GameplayStatics:LoadStreamLevel"]
check(lh ~= nil, "LoadStreamLevel hook")
local lp = param(FName("MainMenu"))
net_mode = "client"
lh.pre(nil, param(gi), lp)
check(lp._v._fname == "None", "MainMenu -> None on a client")
lp = param(FName("MainMenu"))
net_mode = "standalone"
lh.pre(nil, param(gi), lp)
check(lp._v._fname == "MainMenu", "standalone untouched")
lp = param(FName("LongdownValley"))
net_mode = "client"
lh.pre(nil, param(gi), lp)
check(lp._v._fname == "LongdownValley", "other levels untouched")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
for _, t in ipairs(out) do _ = t end
