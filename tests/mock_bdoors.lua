-- Mock harness for sdc_bdoors (placed doors / gates: the opener's swing side,
-- open / closed as on the host, garage door power from the host, clients'
-- generators leave power to the host). Two module instances, one per machine,
-- each with its own world and its own "player 0"; messages go through
-- sdc_net's real encode / decode.
-- usage: lua mock_bdoors.lua <scripts dir>
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
local function new_obj(cls, short, props, methods, where)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }
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
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local DOORS = "/Game/Blueprints/BuildingSystem/Actors/Doors/"
local P = {
    wood = DOORS .. "Buildable_WoodenDoor.Buildable_WoodenDoor_C",
    wood2 = DOORS .. "Buildable_WoodenDoor2.Buildable_WoodenDoor2_C",
    gate = DOORS .. "Buildable_WoodenGate.Buildable_WoodenGate_C",
    garage = DOORS .. "Buildable_GarageDoor.Buildable_GarageDoor_C",
    base = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C",
    gen = "/Game/Blueprints/BuildingSystem/Actors/Generator/Buildable_GeneratorMaster.Buildable_GeneratorMaster_C",
}
local F_POWER = P.base .. ":OnRep_PoweredOn?"
local F_GEN = P.gen .. ":OnRep_TurnedOn?"
local timers = {}   -- [object] = { [name] = true }
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    K2_IsTimerActive = function(_, o, n) return timers[o] ~= nil and timers[o][n] == true end,
    K2_ClearTimer = function(_, o, n) if timers[o] then timers[o][n] = nil end end,
}, false)
local loaded = true
function StaticFindObject(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return ksl end
    if not loaded then return nil end
    if path:find("/Game/", 1, true) then return new_obj("Object", path, {}, {}, false) end
    return nil
end
local hooks = { host = {}, client = {} }
local hook_machine = "host"
local registered = {}
function RegisterHook(path, fn) hooks[hook_machine][path] = fn; registered[#registered + 1] = hook_machine .. " " .. path; return 1, 2 end
function FindAllOf(cls)
    local out = {}
    for _, o in ipairs(worlds[machine]) do
        if o._valid and (o._cls == cls or (cls == "Buildable_GeneratorMaster_C" and o._gen)) then out[#out + 1] = o end
    end
    return #out > 0 and out or nil
end
function FindFirstOf(cls) local l = FindAllOf(cls); return l and l[1] or nil end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay() return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end

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

local function on(m) machine = m; ue.forget_world() end
local function fire(m, path, ...)
    local cb = hooks[m][path]
    if cb then return cb(...) end
end

-- ------------------------------------------------------------ door blueprints (the game's logic)
local player0 = { host = nil, client = nil }   -- who GetPlayerCharacter(self, 0) gives on each machine
local notes = { host = 0, client = 0 }          -- "Requires power"
local calls = { open = 0, update = 0 }

local function timeline(door, final)
    return new_obj("TimelineComponent", "Timeline", { __playing = false, __rev = false }, {
        IsPlaying = function(s) return s._p.__playing end,
        IsReversing = function(s) return s._p.__rev end,
        Play = function(s) s._p.__playing, s._p.__rev = true, false end,
        Reverse = function(s) s._p.__playing, s._p.__rev = true, true end,
    }, false)
end
local function finish(tl, door)
    tl._p.__playing = false
    if tl._p.__rev then door._p.IsClosed = true end
end

local function dot_of(door, pawn)
    local m, p = door._p.__loc, pawn._p.__loc
    local dx, dy = m.X - p.X, m.Y - p.Y
    local len = math.sqrt(dx * dx + dy * dy)
    return len > 0 and (dx * 1 + dy * 0) / len or 0   -- forward = +X
end

local function swing(where, cls, path, short, loc)
    local d
    local tl = timeline()
    local mesh = new_obj("StaticMeshComponent", "StaticMesh", {}, {
        K2_GetComponentLocation = function() return d._p.__loc end,
        GetForwardVector = function() return { X = 1, Y = 0, Z = 0 } end,
    }, false)
    d = new_obj(cls, short, { __loc = loc, IsClosed = true, DotProduct = 0, Timeline_OpenDoor = tl, StaticMesh = mesh,
        __yaw = 0 }, {
        Event_OpenDoor = function(self)
            calls.open = calls.open + 1
            if self._p.IsClosed then
                self._p.IsClosed = false
                self._p.DotProduct = dot_of(self, player0[machine])
                tl:Play()
            else
                tl:Reverse()
            end
        end,
        Timeline_OpenDoor__UpdateFunc = function(self)
            calls.update = calls.update + 1
            self._p.__yaw = self._p.DotProduct >= 0 and 90 or -90
        end,
        OnInteractBuildable = function(self, actor)
            self:Event_OpenDoor()
            fire(machine, path .. ":OnInteractBuildable", param(self), param(actor))
        end,
    }, where)
    d.__tl = tl
    return d
end

local function gate(where, short, loc)
    local d
    local t0, t1 = timeline(), timeline()
    d = new_obj("Buildable_WoodenGate_C", short, { __loc = loc, IsClosed = true, DotProduct = 0, Timeline_0 = t0, Timeline_1 = t1 }, {
        Event_OpenDoor = function(self)
            calls.open = calls.open + 1
            if self._p.IsClosed then self._p.IsClosed = false; t0:Play(); t1:Play() else t0:Reverse(); t1:Reverse() end
        end,
        OnInteractBuildable = function(self, actor)
            self:Event_OpenDoor()
            fire(machine, P.gate .. ":OnInteractBuildable", param(self), param(actor))
        end,
    }, where)
    d.__t0, d.__t1 = t0, t1
    return d
end

local function garage(where, short, loc, powered)
    return new_obj("Buildable_GarageDoor_C", short, { __loc = loc, ["Opened?"] = false, ["DoorOpening?"] = false,
        ["PoweredOn?"] = powered, ["RequiresPower?"] = true }, {
        OnInteractBuildable = function(self, actor)
            if not self._p["PoweredOn?"] then
                notes[machine] = notes[machine] + 1
            elseif not self._p["DoorOpening?"] then
                self._p["DoorOpening?"] = true
            end
            fire(machine, P.garage .. ":OnInteractBuildable", param(self), param(actor))
        end,
        ["Power On"] = function(self)
            if not self._p["PoweredOn?"] then self._p["PoweredOn?"] = true; fire(machine, F_POWER, param(self)) end
        end,
        ["Power Off"] = function(self)
            if self._p["PoweredOn?"] then self._p["PoweredOn?"] = false; fire(machine, F_POWER, param(self)) end
        end,
        ["OnRep_PoweredOn?"] = function() end,
    }, where)
end
local function garage_done(g)
    g._p["DoorOpening?"] = false
    g._p["Opened?"] = not g._p["Opened?"]
end

-- ------------------------------------------------------------ the machines
local function players(where, local_short)
    local lp = new_obj("LocalPlayer", "LocalPlayer_0", {}, {}, where)
    local pc = new_obj("PlayerController", local_short .. "_PC", { Player = lp }, {}, where)
    local pawn = new_obj("BP_PlayerCharacter_C", local_short, { Controller = pc }, {}, where)
    pc._p.Pawn = pawn
    return pc, pawn
end
local host_pc, host_pawn = players("host", "BP_PlayerCharacter_C_0")
host_pawn._p.__loc = { X = -300, Y = 0, Z = 0 }          -- the host stands on the -X side of the doors
local conn = new_obj("IpConnection", "IpConnection_1", {}, {}, "host")
local rpc_h = new_obj("BP_PlayerController_C", "BP_PlayerController_C_7", { Player = conn, NetConnection = conn }, {}, false)
local client_pc, client_pawn = players("client", "BP_PlayerCharacter_C_1")
client_pawn._p.__loc = { X = 300, Y = 0, Z = 0 }        -- the client on the +X side
local host_copy = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_9", { __loc = { X = -300, Y = 0, Z = 0 } }, {}, "client")
player0.host, player0.client = host_pawn, client_pawn

local A, B, C, D, E = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 1000, Z = 0 }, { X = 0, Y = 2000, Z = 0 }, { X = 0, Y = 3000, Z = 0 },
    { X = 0, Y = 4000, Z = 0 }
local hwood = swing("host", "Buildable_WoodenDoor_C", P.wood, "Buildable_WoodenDoor_C_2147000001", A)
local cwood = swing("client", "Buildable_WoodenDoor_C", P.wood, "Buildable_WoodenDoor_C_2146000001", { X = 0.3, Y = 0.2, Z = 0 })
local hwood2 = swing("host", "Buildable_WoodenDoor2_C", P.wood2, "Buildable_WoodenDoor2_C_2147000002", B)
local cwood2 = swing("client", "Buildable_WoodenDoor2_C", P.wood2, "Buildable_WoodenDoor2_C_2146000002", B)
local hgate = gate("host", "Buildable_WoodenGate_C_2147000003", C)
local cgate = gate("client", "Buildable_WoodenGate_C_2146000003", C)
local hgar = garage("host", "Buildable_GarageDoor_C_2147000004", D, true)
local cgar = garage("client", "Buildable_GarageDoor_C_2146000004", D, false)   -- its own generator copy said "no power"

-- ------------------------------------------------------------ module instances
local Sh = { role = "host", remote_pcs = { rpc_h }, map = "LongdownValley" }
local Sc = { role = "client", map = "LongdownValley", remote_pcs = {}, client = { acked = false, pc_key = "k" } }
on("host")
local host_mod = require("sdc_bdoors")
host_mod.install(Sh)
local hh = { WBDOOR = net.handlers.WBDOOR, WBDOORQ = net.handlers.WBDOORQ }
package.loaded["sdc_bdoors"] = nil
on("client")
local client_mod = require("sdc_bdoors")
client_mod.install(Sc)
local ch = { WBDOOR = net.handlers.WBDOOR, WBDOORQ = net.handlers.WBDOORQ }
check(host_mod ~= client_mod and hh.WBDOOR and ch.WBDOOR and hh.WBDOORQ, "two instances, handlers on both")

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
local function deliver(list)
    for _, m in ipairs(list) do
        local kind, fields = net.decode(m.msg)
        if m.to == "host" then on("host"); hh[kind](fields, rpc_h) else on("client"); ch[kind](fields, client_pc) end
    end
end
local function tick(m, mod) on(m); hook_machine = m; mod.tick() end
-- the host's interaction: OnInteractBuildable runs on the host (the multicast's local run)
local function host_use(d, presser)
    on("host"); player0.host = presser; d:OnInteractBuildable(presser); player0.host = host_pawn
end
local function client_mc(d, presser) on("client"); d:OnInteractBuildable(presser) end

-- ------------------------------------------------------------ 1. hooks
tick("host", host_mod)
tick("client", client_mod)
check(hooks.host[P.wood .. ":OnInteractBuildable"] and hooks.host[P.garage .. ":OnInteractBuildable"] and hooks.host[F_POWER],
    "host: door toggles + OnRep_PoweredOn? hooked")
check(hooks.host[F_GEN] == nil, "host: generators untouched")
check(hooks.client[P.gate .. ":OnInteractBuildable"] and hooks.client[F_GEN] and hooks.client[F_POWER] == nil,
    "client: door toggles + generator OnRep_TurnedOn? hooked")
local first_snap = take("WBDOOR")
check(#first_snap >= 1, "host: a snapshot goes out once a client is there")
deliver(first_snap)
local n0 = #registered
T = T + 3
tick("host", host_mod); tick("client", client_mod)
check(#registered == n0, "each hook once")

-- ------------------------------------------------------------ 2. the swing side: the opener's
-- the host opens its wooden door from -X: the door swings to +90 there
host_use(hwood, host_pawn)
check(hwood.DotProduct > 0, "host: player 0 = the host, dot > 0")
local ch1 = take("WBDOOR")
check(#ch1 == 1 and ch1[1].msg:find("Buildable_WoodenDoor_C 0,0,0 1 1.000 -", 1, true) ~= nil,
    "host: WBDOOR with open state and its DotProduct: " .. tostring(ch1[1] and ch1[1].msg))
-- the multicast on the client: the game used the CLIENT (other side) -> fixed from the opener
local u0 = calls.update
client_mc(cwood, host_copy)
check(cwood.DotProduct > 0 and cwood.__yaw == 90 and calls.update == u0 + 1,
    "client: swings away from the host (the opener), not from the client: dot " .. tostring(cwood.DotProduct))
check(logged("opened by BP_PlayerCharacter_C_9: swings away from that player here too") ~= nil, "client logs the side")
deliver(ch1)
check(cwood.DotProduct > 0 and not cwood.IsClosed, "client: state as on the host, nothing toggled")
-- the client opens its own door: the game's own side (no change)
cwood2.DotProduct = 0
u0 = calls.update
player0.client = client_pawn
client_mc(cwood2, client_pawn)
check(cwood2.DotProduct < 0 and calls.update == u0, "client's own opening: the game's side kept")
-- (put it back: that toggle was only on the client)
cwood2.__tl.Reverse(cwood2.__tl); finish(cwood2.__tl, cwood2)

-- ------------------------------------------------------------ 3. a dropped multicast: open / closed reconciled
host_use(hwood2, rpc_h and client_pawn or nil)   -- the CLIENT opened it on the host (scope: player 0 = the client)
local hdot = hwood2.DotProduct
check(hdot < 0, "host: the client's opening swings away from the client (dot < 0)")
deliver(take("WBDOOR"))       -- the reliable state arrives; the multicast was dropped
check(cwood2.IsClosed == true, "client: not toggled at once (the multicast may still come)")
T = T + 1
tick("client", client_mod)
check(cwood2.IsClosed == true, "client: still waiting within 2.5 s")
T = T + 2
local o0 = calls.open
tick("client", client_mod)
check(cwood2.IsClosed == false and calls.open == o0 + 1 and math.abs(cwood2.DotProduct - hdot) < 0.001,
    "client: the game's Event_OpenDoor once, with the host's side")
check(logged("was closed here, opened like on the host") ~= nil, "client logs the fix")
T = T + 3
tick("client", client_mod)
check(calls.open == o0 + 1, "client: no second toggle while it moves")
finish(cwood2.__tl, cwood2)
T = T + 3
tick("client", client_mod)
check(calls.open == o0 + 1, "client: settled, equal: nothing")
-- closing with both: the client's multicast arrives -> no extra toggle
host_use(hwood, host_pawn)
deliver(take("WBDOOR"))
client_mc(cwood, host_copy)
T = T + 3
o0 = calls.open
tick("client", client_mod)
check(calls.open == o0, "close reached both: nothing to fix")
finish(hwood.__tl, hwood); finish(cwood.__tl, cwood)
check(hwood.IsClosed and cwood.IsClosed, "both closed")
-- a copy opened only here (late / stray multicast): closed again like on the host
client_mc(cwood, host_copy); finish(cwood.__tl, cwood)
T = T + 3
tick("client", client_mod)
check(cwood.__tl._p.__rev == true, "client: a door open only here is closed again (the game's toggle)")
finish(cwood.__tl, cwood)

-- ------------------------------------------------------------ 4. gate
host_use(hgate, host_pawn)
deliver(take("WBDOOR"))
T = T + 3
tick("client", client_mod)
check(cgate.IsClosed == false and cgate.__t0._p.__playing and cgate.__t1._p.__playing, "gate: opened here like on the host (both leaves)")
finish(cgate.__t0, cgate); finish(cgate.__t1, cgate); finish(hgate.__t0, hgate); finish(hgate.__t1, hgate)

-- ------------------------------------------------------------ 5. garage door power + state
check(cgar["PoweredOn?"] == true, "client: garage copy got the host's power from the snapshot (no Requires power)")
check(logged("has power here, as on the host") ~= nil, "client logs the power fix")
host_use(hgar, host_pawn)       -- powered on the host: it opens there; the multicast is dropped
deliver(take("WBDOOR"))
garage_done(hgar)
T = T + 3
tick("client", client_mod)
check(cgar["DoorOpening?"] == true and notes.client == 0, "client: garage opens here with the game's OnInteractBuildable, no 'Requires power'")
garage_done(cgar)
-- the host's power goes off -> the client's copy too
on("host"); hgar["Power Off"](hgar)
deliver(take("WBDOOR"))
check(cgar["PoweredOn?"] == false, "client: the host's power off reaches the copy")
-- the host closes it while unpowered?  (its door can't move: Requires power on the host)
-- a client copy that is closed while the host's is open and unpowered: toggled with power only for that call
cgar._p["Opened?"] = false
T = T + 3
tick("client", client_mod)
check(cgar["DoorOpening?"] == true and notes.client == 0 and cgar["PoweredOn?"] == false,
    "client: unpowered host door open: opened here without 'Requires power', power left off")
garage_done(cgar)

-- ------------------------------------------------------------ 6. join: a client's new copies
local cw3 = swing("client", "Buildable_WoodenDoor_C", P.wood, "Buildable_WoodenDoor_C_2146000009", E)
local hw3 = swing("host", "Buildable_WoodenDoor_C", P.wood, "Buildable_WoodenDoor_C_2147000009", E)
host_use(hw3, host_pawn)
take("WBDOOR")                  -- the client was not there yet
finish(hw3.__tl, hw3)
Sc.client.acked = true
package.loaded["sdc_bdoors"] = nil
on("client")
local fresh = require("sdc_bdoors")
fresh.install(Sc)
ch.WBDOOR, ch.WBDOORQ = net.handlers.WBDOOR, net.handlers.WBDOORQ
hooks.client = {}
tick("client", fresh)
T = T + 3.5
tick("client", fresh)
local q = take("WBDOORQ")
check(#q == 1, "client: asks for the doors after joining (WBDOORQ)")
deliver(q)
local snap = take("WBDOOR")
check(#snap >= 1 and snap[1].msg:find("SDC1|WBDOOR|s|", 1, true) == 1, "host: snapshot to that client")
deliver(snap)
T = T + 2.1
tick("client", fresh)
check(cw3.IsClosed == false and cw3.DotProduct > 0, "client: a door open on the host opens on the new copy, host's side")

-- ------------------------------------------------------------ 7. generators on the client
local gen = new_obj("Buildable_SmallGenerator_C", "Buildable_SmallGenerator_C_2146000020", { __loc = { X = 9, Y = 9, Z = 0 } }, {}, "client")
gen._gen = true
timers[gen] = { GetObjects = true, FuelCost = true, Shake = true }
on("client"); hook_machine = "client"
T = T + 2.1
tick("client", fresh)
check(hooks.client[F_GEN] ~= nil, "client: generator hook in (new session)")
check(not timers[gen].GetObjects and not timers[gen].FuelCost and timers[gen].Shake,
    "client: the pass stopped its GetObjects / FuelCost timers (the shake stays)")
check(logged("its server timers GetObjects+FuelCost stopped here") ~= nil, "client logs it")
timers[gen].GetObjects = true
fire("client", F_GEN, param(gen))
check(not timers[gen].GetObjects, "client: OnRep_TurnedOn? restarted it: stopped at once")

-- ------------------------------------------------------------ 8. periodic, expiry, config off
on("host")
take()
-- traffic of an idle minute (nothing opens, one client): NETQ line for the net-quiet report
do
    local n, bytes = 0, 0
    for _ = 1, 720 do   -- 360 s of the 500 ms tick
        T = T + 0.5
        tick("host", host_mod)
    end
    for _, m in ipairs(take("WBDOOR")) do n = n + 1; bytes = bytes + #m.msg end
    io.write(string.format("NETQ WBDOOR idle msgs/min=%.1f bytes/min=%.0f", n / 6, bytes / 6), string.char(10))
end
T = T + 21
tick("host", host_mod)
take()
host_use(hwood, host_pawn)   -- a door the hook sees: WBDOOR|c to the clients now ...
check(#take("WBDOOR") == 1, "host: a toggled door goes out as one WBDOOR|c")
T = T + 21
tick("host", host_mod)
check(#take("WBDOOR") == 0, "host: ... and the next check does not repeat it inside a snapshot")
-- door A changes without its hook, door B is used: B's change must not hide A's from the next check
hgar._p["PoweredOn?"] = not hgar._p["PoweredOn?"]
host_use(hwood, host_pawn); take()
T = T + 21
tick("host", host_mod)
do
    local m = take("WBDOOR")
    check(#m >= 1 and m[1].msg:find("GarageDoor", 1, true) and not m[1].msg:find("WoodenDoor_C", 1, true),
        "host: door A's silent change goes with the next check (only A: it is B's own record that was marked)")
end
host_use(hwood, host_pawn)   -- back
take()
T = T + 21
tick("host", host_mod)
take()
T = T + 21
tick("host", host_mod)
check(#take("WBDOOR") == 0, "host: unchanged doors are not sent again after 20 s")
hgar._p["PoweredOn?"] = not hgar._p["PoweredOn?"]   -- a change no hook told the clients about
T = T + 21
tick("host", host_mod)
check(#take("WBDOOR") >= 1, "host: a door that differs from what the client was told goes within one check")
T = T + 21
tick("host", host_mod)
check(#take("WBDOOR") == 0, "host: and is not repeated")
T = T + 181
tick("host", host_mod)
check(#take("WBDOOR") >= 1, "host: the verify: all doors again after 180 s")
on("client")
net.handlers.WBDOOR({ "s", "Buildable_WoodenDoor_C 160579,129273,1735 0 - -" }, client_pc)
T = T + 300
tick("client", fresh)
check(fresh.status_line():find("known=0", 1, true) == nil, "client: a host state is still kept some minutes without a refresh (400 s)")
T = T + 450
tick("client", fresh)
check(fresh.status_line():find("known=0", 1, true) ~= nil, "client: states not refreshed for 400 s are forgotten")
cfg.set("world_build_doors", false)
host_use(hwood, host_pawn)
check(#take() == 0, "doors off: the host sends nothing on a toggle")
cfg.set("world_build_doors", true)
cfg.set("world_build_power", false)
timers[gen].GetObjects = true
fire("client", F_GEN, param(gen))
check(timers[gen].GetObjects == true, "power off: generators left alone")
cfg.set("world_build_power", true)
on("client")
ch.WBDOOR({ "c", "Bogus_C 0,0,0 1 - -;Buildable_WoodenDoor_C bad 1 - -" }, client_pc)
ch.WBDOOR({}, client_pc)
check(fresh.status_line():find("known=0", 1, true) ~= nil, "malformed entries ignored")
local bad = setmetatable({}, { __index = function() error("boom") end })
check(pcall(hooks.host[P.wood .. ":OnInteractBuildable"], bad, bad) and pcall(hooks.client[F_GEN], bad),
    "broken hook arguments are caught")
check(host_mod.status_line():find("bdoors: doors=true power=true", 1, true) ~= nil, "status line")

print = real_print
for _, l in ipairs(lines) do if l:find("bdoors:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
