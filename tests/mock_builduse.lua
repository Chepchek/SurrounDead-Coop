-- Mock harness for sdc_builduse (a buildable a client used last - garage door,
-- doors, gates, benches - keeps no left-over user on the host, so the host's
-- own look shows its prompt and the host can use it). Two module instances,
-- one per machine, each with its own world; messages go through sdc_net's
-- real encode / decode.
-- usage: lua mock_builduse.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local machine = "host"
local worlds = { host = {}, client = {} }
local Obj = {}
local next_addr = 4096

local function new_obj(cls, short, props, methods, bases, where)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true,
                _bases = bases or {} }
    o._bases[cls] = true
    setmetatable(o, Obj)
    if where ~= false then
        local w = worlds[where or machine]
        w[#w + 1] = o
    end
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
Obj.__newindex = function(t, k, v) rawget(t, "_p")[k] = v end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:IsA(c) return c ~= nil and self._bases[c._short] == true end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local BASE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local CONTAINER = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local GENERATOR = "/Game/Blueprints/BuildingSystem/Actors/Generator/Buildable_GeneratorMaster.Buildable_GeneratorMaster_C"
local F_BEGIN, F_BEGIN_C, F_BEGIN_G = BASE .. ":OnBeginInteract", CONTAINER .. ":OnBeginInteract", GENERATOR .. ":OnBeginInteract"
local F_PRESS, F_END, F_END_G = BASE .. ":OnExecuteInteract", BASE .. ":OnEndInteract", GENERATOR .. ":OnEndInteract"

local loaded = false
local base_cls = new_obj("BlueprintGeneratedClass", "Buildable_MASTER_C", {}, {}, nil, false)
local ksl_timers = {}   -- [object] = true: its CheckDistanceFromActor timer runs
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    K2_IsTimerActive = function(_, o, name) return name == "CheckDistanceFromActor" and ksl_timers[o] == true end,
}, nil, false)
function StaticFindObject(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return ksl end
    if not loaded then return nil end
    if path == BASE then return base_cls end
    if path:find(":", 1, true) then return new_obj("Function", path, {}, {}, nil, false) end
    return nil
end

local hooks = { host = {}, client = {} }
local hook_machine = "host"
local registered = {}
function RegisterHook(path, fn) hooks[hook_machine][path] = fn; registered[#registered + 1] = hook_machine .. " " .. path; return 1, 2 end
function FindAllOf(cls)
    local out = {}
    for _, o in ipairs(worlds[machine]) do if o._valid and o._bases[cls] then out[#out + 1] = o end end
    return #out > 0 and out or nil
end
function FindFirstOf(cls) local l = FindAllOf(cls); return l and l[1] or nil end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(ms, f) delayed[#delayed + 1] = { ms = ms, f = f, m = machine }; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end
local function run_delayed()
    local d = delayed
    delayed = {}
    for _, e in ipairs(d) do machine = e.m; e.f() end
end

local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function mark() return #lines + 1 end
local function logged(pat, from)
    for i = from or 1, #lines do if lines[i]:find(pat, 1, true) then return lines[i] end end
    return nil
end

local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
ue.every = function() end
local net = require("sdc_net")

-- ------------------------------------------------------------ the machines
local BUILD = function(extra)
    local b = { Buildable_MASTER_C = true, Actor = true }
    for k in pairs(extra or {}) do b[k] = true end
    return b
end
local ended = { host = 0, client = 0 }
local function buildable(where, cls, short, loc, cur, props, bases)
    local p = props or {}
    p.__loc, p.CurrentActor, p.IsHeld = loc, cur, p.IsHeld or false
    return new_obj(cls, short, p, {
        -- the game's OnExecuteInteractEnded (@4280: CurrentActor = None)
        OnExecuteInteractEnded = function(self) ended[machine] = ended[machine] + 1; self._p.CurrentActor = nil end,
    }, BUILD(bases), where)
end

-- host's world
machine = "host"
local host_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local host_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_0", { Player = host_lp }, {},
    { PlayerController = true })
local stops = 0
local host_helper = new_obj("BP_JigHelperComp_C", "BP_JigHelperComp", {}, {
    StopInteraction = function() stops = stops + 1 end,
})
local host_pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_0",
    { Controller = host_pc, BP_JigHelperComp = host_helper, __loc = { X = 0, Y = 0, Z = 0 } })
host_pc._p.Pawn = host_pawn
local conn = new_obj("IpConnection", "IpConnection_1", {})
local rpc_h = new_obj("BP_PlayerController_C", "BP_PlayerController_C_7", { Player = conn, NetConnection = conn }, {},
    { PlayerController = true })
local rpawn_h = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Controller = rpc_h })
rpc_h._p.Pawn = rpawn_h
local conn2 = new_obj("IpConnection", "IpConnection_2", {})
local rpc2 = new_obj("BP_PlayerController_C", "BP_PlayerController_C_8", { Player = conn2, NetConnection = conn2 }, {},
    { PlayerController = true })
local rpawn2 = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_8", { Controller = rpc2 })
rpc2._p.Pawn = rpawn2

local DOOR_AT = { X = 161347, Y = 128998, Z = 1623 }
local hdoor = buildable("host", "Buildable_GarageDoor_C", "Buildable_GarageDoor_C_2147224291", DOOR_AT, rpawn_h)
local hgate = buildable("host", "Buildable_WoodenGate_C", "Buildable_WoodenGate_C_2147200001", { X = 500, Y = 0, Z = 0 }, rpawn_h)
local hbench = buildable("host", "Buildable_CraftingWorkbench_C", "Buildable_CraftingWorkbench_C_2147200002",
    { X = 900, Y = 0, Z = 0 }, rpawn_h)
local hbed = buildable("host", "Buildable_Bed_C", "Buildable_Bed_C_2147200003", { X = 1200, Y = 0, Z = 0 }, rpawn_h)
local hheld = buildable("host", "Buildable_Table_C", "Buildable_Table_C_2147200004", { X = 1500, Y = 0, Z = 0 }, rpawn_h,
    { IsHeld = true })
local hcrate = buildable("host", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147200005", { X = 1800, Y = 0, Z = 0 },
    rpawn_h, nil, { BuildableMaster_Container_C = true })
local hown = buildable("host", "Buildable_WoodenDoor_C", "Buildable_WoodenDoor_C_2147200006", { X = 2100, Y = 0, Z = 0 }, host_pawn)
ksl_timers[hbench] = true

-- client's world
machine = "client"
local client_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local client_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_1", { Player = client_lp }, {},
    { PlayerController = true })
local client_pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_1", { Controller = client_pc })
client_pc._p.Pawn = client_pawn
local other_copy = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2", {})
local cdoor = buildable("client", "Buildable_GarageDoor_C", "Buildable_GarageDoor_C_2147100011",
    { X = 161347.3, Y = 128998.2, Z = 1622.8 }, nil)
local cgate = buildable("client", "Buildable_WoodenGate_C", "Buildable_WoodenGate_C_2147100012", { X = 500, Y = 0, Z = 0 }, nil)
local cbed = buildable("client", "Buildable_Bed_C", "Buildable_Bed_C_2147100013", { X = 1200, Y = 0, Z = 0 }, nil)

-- ------------------------------------------------------------ module instances
local function on(m) machine = m; ue.forget_world() end
local Sh = { role = "host", remote_pcs = { rpc_h, rpc2 }, map = "LongdownValley" }
local Sc = { role = "client", map = "LongdownValley", remote_pcs = {}, client = { acked = true, pc_key = "k" } }

on("host")
local host_mod = require("sdc_builduse")
host_mod.install(Sh)
local host_brel = net.handlers.BREL
package.loaded["sdc_builduse"] = nil
on("client")
local client_mod = require("sdc_builduse")
client_mod.install(Sc)
local client_brel = net.handlers.BREL
check(host_mod ~= client_mod and host_brel ~= nil and client_brel ~= nil, "two instances, BREL handler on both")

local wire = {}
net.send_to = function(pc, kind, ...) wire[#wire + 1] = { from = machine, to = pc, msg = net.encode(kind, ...) }; return true end
net.send_to_host = function(kind, ...) wire[#wire + 1] = { from = machine, to = "host", msg = net.encode(kind, ...) }; return true end
local function take(kind)
    local out, keep = {}, {}
    for _, m in ipairs(wire) do
        local k = net.decode(m.msg)
        if kind == nil or k == kind then out[#out + 1] = m else keep[#keep + 1] = m end
    end
    wire = keep
    return out
end
local function deliver(list, from_pc)
    for _, m in ipairs(list) do
        local kind, fields = net.decode(m.msg)
        on("host"); host_brel(fields, from_pc or rpc_h)
    end
end
local function tick(m, mod) on(m); hook_machine = m; mod.tick() end
local function fire(m, path, ...)
    on(m)
    local cb = hooks[m][path]
    if not cb then return "no hook" end
    return cb(...)
end

-- ------------------------------------------------------------ 1. hooks per role
tick("host", host_mod)
check(next(hooks.host) == nil, "no hook before the buildable classes load")
loaded = true
T = T + 3
tick("host", host_mod)
check(hooks.host[F_BEGIN] and hooks.host[F_BEGIN_C] and hooks.host[F_BEGIN_G], "host: OnBeginInteract hooks (base, container, generator)")
check(hooks.host[F_PRESS] == nil and hooks.host[F_END] == nil, "host: no client hooks")
tick("client", client_mod)
check(hooks.client[F_PRESS] and hooks.client[F_END] and hooks.client[F_END_G], "client: OnExecuteInteract / OnEndInteract hooks")
check(hooks.client[F_BEGIN] == nil, "client: no host hook")
local nreg = #registered
T = T + 3
tick("host", host_mod); tick("client", client_mod)
check(#registered == nreg, "each hook registered once")
-- a host alone hooks nothing more and does nothing
Sh.remote_pcs = {}
local m0 = mark()
local r = fire("host", F_BEGIN, param(hdoor), param(host_pawn), param({}))
check(r == nil and hdoor.CurrentActor == rpawn_h and logged("build:", m0) == nil, "no remote players: nothing done")
Sh.remote_pcs = { rpc_h, rpc2 }

-- ------------------------------------------------------------ 2. client: press, look away -> BREL
fire("client", F_END, param(cdoor))
check(#take() == 0, "client: a look-away without a press sends nothing")
fire("client", F_PRESS, param(cdoor), param(other_copy), param({}))
fire("client", F_END, param(cdoor))
check(#take() == 0, "client: another player's press (on this machine) is not this player's")
r = fire("client", F_PRESS, param(cdoor), param(client_pawn), param({ TagName = FName("Jig.InteractOptions.Option1") }))
check(r == nil, "hook returns nothing")
fire("client", F_END, param(cdoor))
local rel = take("BREL")
check(#rel == 1 and rel[1].to == "host" and rel[1].msg == "SDC1|BREL|Buildable_GarageDoor_C|161347,128998,1623",
    "client: its use is over -> BREL with class and place: " .. tostring(rel[1] and rel[1].msg))
check(logged("the host ends it on its copy (BREL)") ~= nil, "client logs it")
fire("client", F_END, param(cdoor))
check(#take() == 0, "client: one BREL per press")
-- beds are left alone
fire("client", F_PRESS, param(cbed), param(client_pawn), param({}))
fire("client", F_END, param(cbed))
check(#take() == 0, "client: bed: nothing sent")
-- an old press does not count
fire("client", F_PRESS, param(cgate), param(client_pawn), param({}))
T = T + 200
fire("client", F_END, param(cgate))
check(#take() == 0, "client: a press older than 120 s is forgotten")

-- ------------------------------------------------------------ 3. host: BREL -> release a second later
local he = ended.host
deliver(rel)
check(hdoor.CurrentActor == rpawn_h, "host: not at once (its own interaction RPC may still be on the way)")
check(#delayed == 1 and delayed[1].ms == 1000, "host: handled 1 s later")
m0 = mark()
run_delayed()
check(hdoor.CurrentActor == nil and ended.host == he + 1, "host: the game's OnExecuteInteractEnded released the client's left-over use")
check(logged("use of Buildable_GarageDoor_C_2147224291 is over", m0) ~= nil, "host logs it")
-- the door's user is someone else by now: nothing
hdoor._p.CurrentActor = rpawn2
deliver(rel); run_delayed()
check(hdoor.CurrentActor == rpawn2, "host: another player's use is not ended by this player's BREL")
-- the game still uses it (window open: distance check timer)
deliver({ { msg = net.encode("BREL", "Buildable_CraftingWorkbench_C", "900,0,0") } }); run_delayed()
check(hbench.CurrentActor == rpawn_h, "host: an open window (distance check running) is left to the game")
deliver({ { msg = net.encode("BREL", "Buildable_Table_C", "1500,0,0") } }); run_delayed()
check(hheld.CurrentActor == rpawn_h, "host: a hold to pick up is left to the game")
deliver({ { msg = net.encode("BREL", "Buildable_Bed_C", "1200,0,0") } }); run_delayed()
check(hbed.CurrentActor == rpawn_h, "host: a bed is left to sdc_respawn")
local function missing() return tonumber(host_mod.status_line():match("missing=(%d+)")) end
local mis = missing()
deliver({ { msg = net.encode("BREL", "Buildable_GarageDoor_C", "9000,9000,0") } }); run_delayed()
check(missing() == mis + 1 and hdoor.CurrentActor == rpawn2, "host: an unknown place: nothing")
deliver({ { msg = net.encode("BREL", "Buildable_GarageDoor_C", "bad") } })
deliver({ { msg = net.encode("BREL") } })
check(#delayed == 0, "host: malformed BREL ignored")

-- ------------------------------------------------------------ 4. host: its own look at a left-over door
hdoor._p.CurrentActor = rpawn_h
stops = 0
-- someone else's look (not the host's pawn) changes nothing
fire("host", F_BEGIN, param(hdoor), param(rpawn_h), param({}))
check(hdoor.CurrentActor == rpawn_h, "host: OnBeginInteract of another pawn: nothing")
m0 = mark()
r = fire("host", F_BEGIN, param(hdoor), param(host_pawn), param({}))
check(r == nil and hdoor.CurrentActor == nil, "host's look at the door the client used: released")
check(logged("the host looks at Buildable_GarageDoor_C_2147224291, last used by BP_PlayerCharacter_C_7", m0) ~= nil,
    "host logs it")
check(stops == 0 and #delayed == 1, "the re-trace waits for the next game-thread tick")
run_delayed()
check(stops == 1, "the game's StopInteraction on the host's helper: the look begins again (prompt)")
-- the trace begins again at once: no loop
hdoor._p.CurrentActor = rpawn_h
fire("host", F_BEGIN, param(hdoor), param(host_pawn), param({}))
check(hdoor.CurrentActor == rpawn_h and #delayed == 0, "within 1 s: not again (no re-trace loop)")
T = T + 1.5
fire("host", F_BEGIN, param(hdoor), param(host_pawn), param({}))
check(hdoor.CurrentActor == nil, "later: released again")
run_delayed()
-- gate (same base hook), crate (container hook)
fire("host", F_BEGIN, param(hgate), param(host_pawn), param({}))
fire("host", F_BEGIN_C, param(hcrate), param(host_pawn), param({}))
check(hgate.CurrentActor == nil and hcrate.CurrentActor == nil, "gate and crate after a client's use: released on the host's look")
run_delayed()
-- left alone: the host's own, an open window, a hold, a bed
stops = 0
fire("host", F_BEGIN, param(hown), param(host_pawn), param({}))
check(hown.CurrentActor == host_pawn, "the host's own last use: nothing")
m0 = mark()
fire("host", F_BEGIN, param(hbench), param(host_pawn), param({}))
check(hbench.CurrentActor == rpawn_h and logged("left to the game", m0) ~= nil, "bench with the client's window open: left to the game")
fire("host", F_BEGIN, param(hheld), param(host_pawn), param({}))
check(hheld.CurrentActor == rpawn_h, "a hold in progress: left to the game")
fire("host", F_BEGIN, param(hbed), param(host_pawn), param({}))
check(hbed.CurrentActor == rpawn_h, "bed: left alone")
run_delayed()
check(stops == 0, "no re-trace when nothing was released")
-- the window closed and the client walked away (timer stopped): released on the next look
ksl_timers[hbench] = nil
T = T + 1.5
fire("host", F_BEGIN, param(hbench), param(host_pawn), param({}))
check(hbench.CurrentActor == nil, "bench after the game's distance check stopped: released")
run_delayed()
-- OnExecuteInteractEnded missing / failing: CurrentActor set directly
local odd = buildable("host", "Buildable_Chair_C", "Buildable_Chair_C_2147200007", { X = 2400, Y = 0, Z = 0 }, rpawn_h)
odd._m.OnExecuteInteractEnded = function() error("no such function") end
fire("host", F_BEGIN, param(odd), param(host_pawn), param({}))
check(odd.CurrentActor == nil and logged("set to None directly") ~= nil, "fallback: CurrentActor set to None")
run_delayed()

-- ------------------------------------------------------------ 5. config off, robustness
cfg.set("world_build_release", false)
hdoor._p.CurrentActor = rpawn_h
T = T + 2
fire("host", F_BEGIN, param(hdoor), param(host_pawn), param({}))
check(hdoor.CurrentActor == rpawn_h, "off: the host changes nothing")
fire("client", F_PRESS, param(cdoor), param(client_pawn), param({}))
fire("client", F_END, param(cdoor))
check(#take() == 0, "off: the client sends nothing")
cfg.set("world_build_release", true)
cfg.set("world_sync", false)
fire("host", F_BEGIN, param(hdoor), param(host_pawn), param({}))
check(hdoor.CurrentActor == rpawn_h, "world_sync off: nothing")
cfg.set("world_sync", true)
local bad = setmetatable({}, { __index = function() error("boom") end })
check(pcall(hooks.host[F_BEGIN], bad, bad) and pcall(hooks.client[F_END], bad) and pcall(hooks.client[F_PRESS], param(nil), nil),
    "broken hook arguments are caught")
client_mod.reset("test")
check(client_mod.status_line():find("build: on=true", 1, true) ~= nil, "status line: " .. client_mod.status_line())

print = real_print
for _, l in ipairs(lines) do if l:find("build:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
