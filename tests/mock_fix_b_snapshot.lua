-- Mock harness (critic fix 2026-11-13, group B, A2 / A3): the join snapshot
-- of sdc_world. Locked doors (WDOOR), replicated doors (WRDOOR), keypad codes
-- (WKEYCODE) and airdrop crates (WCRATE) go as one list message each, not one
-- message per object; barrels / the nuke that blew up earlier go silently
-- (WBOOM ... |s: K2_DestroyActor, no Event_Explode / MC_Explode at the join).
-- The receivers still take the old one-object messages.
-- usage: lua mock_fix_b_snapshot.lua <scripts dir>
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
function Obj:K2_DestroyActor() self._valid = false; self._calls[#self._calls + 1] = { "K2_DestroyActor" } end
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

WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1", { _loc = { X = 5000, Y = 0, Z = 0 } })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- the world's objects (same names on both)
local BARREL = "/Game/Blueprints/Other/ExplosiveBarrel/BP_ExplosiveBarrelMaster.BP_ExplosiveBarrelMaster_C"
local NUKE = "/Game/Blueprints/Other/EasterEggs/BP_EasterEgg_Nuke.BP_EasterEgg_Nuke_C"
local N_DOORS, N_RDOORS, N_KEYPADS, N_CRATES, N_BARRELS = 14, 10, 12, 3, 6

local function locked_door(w, i, closed, locked)
    WORLD = w
    return new(w, { "BP_LockedDoor_C", "BP_LockPickObject_C" }, "BP_LockedDoor_C_" .. i,
        { ["Closed?"] = closed, ["IsLocked?"] = locked }, {
        Event_Door = function(self) self._p["Closed?"] = not self._p["Closed?"]; self._calls[#self._calls + 1] = { "Event_Door" } end,
        EventDoorBehind = rec("EventDoorBehind"),
    })
end
local function warehouse(w, i, closed)
    WORLD = w
    return new(w, { "BP_WarehouseDoors_C" }, "BP_WarehouseDoors_C_" .. i, { IsClosed = closed }, {
        MC_OpenDoor = function(self) self._p.IsClosed = not self._p.IsClosed; self._calls[#self._calls + 1] = { "MC_OpenDoor" } end,
    })
end
local function keypad(w, i, code)
    WORLD = w
    local note = new(w, { "BP_KeypadNote_C" }, "BP_KeypadNote_C_" .. i, { Code = code })
    return new(w, { "BP_KeypadDoor_C" }, "BP_KeypadDoor_C_" .. i, { Code = code, NoteRef = note, ["Open?"] = false }), note
end
local function vcopy(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function rcopy(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
local function crate(w, name, role, root, mesh_at)
    WORLD = w
    local mesh = new(w, { "StaticMeshComponent" }, name .. ".StaticMesh",
        { _wloc = vcopy(mesh_at), _wrot = { Pitch = 0, Yaw = 30, Roll = 0 }, _sim = true }, {
        K2_GetComponentLocation = function(self) return vcopy(self._p._wloc) end,
        K2_GetComponentRotation = function(self) return rcopy(self._p._wrot) end,
        SetSimulatePhysics = function(self, b) self._p._sim = b end,
        IsSimulatingPhysics = function(self) return self._p._sim end,
        K2_SetWorldLocationAndRotation = function(self, l, r) self._p._wloc, self._p._wrot = vcopy(l), rcopy(r) end,
    })
    local chute = new(w, { "StaticMeshComponent" }, name .. ".Parachute", {}, {
        SetVisibility = function() end, SetCollisionEnabled = function() end,
    })
    return new(w, { "AirdropContainer_Supplies_C", "Master_AirdropContainer_C" }, name,
        { StaticMesh = mesh, Parachute = chute, _loc = vcopy(root), Role = role, bReplicates = true })
end
local function barrel(w, i)
    WORLD = w
    return new(w, { "BP_ExplosiveBarrel_C", "BP_ExplosiveBarrelMaster_C" }, "BP_ExplosiveBarrel_C_" .. i, {},
        { Event_Explode = rec("Event_Explode") })
end

local H_DOORS, C_DOORS, C_RDOORS, H_RDOORS, C_KEYPADS, C_NOTES, C_CRATES, H_BARRELS, C_BARRELS = {}, {}, {}, {}, {}, {}, {}, {}, {}
for i = 1, N_DOORS do
    -- host: 1-5 open, 6-9 closed but unlocked, the rest closed and locked (not sent)
    H_DOORS[i] = locked_door(HW, i, i > 5, i > 9)
    C_DOORS[i] = locked_door(CW, i, true, true)
end
for i = 1, N_RDOORS do
    H_RDOORS[i] = warehouse(HW, i, i % 2 == 0)   -- odd ones open on the host
    C_RDOORS[i] = warehouse(CW, i, true)
end
for i = 1, N_KEYPADS do
    keypad(HW, i, 2000 + i)
    C_KEYPADS[i], C_NOTES[i] = keypad(CW, i, 9000 + i)
end
local H_CRATE_AT = {}
for i = 1, N_CRATES do
    local root = { X = 10000 * i, Y = 0, Z = 48000 }
    H_CRATE_AT[i] = { X = 10000 * i + 300, Y = 50, Z = 120 }
    crate(HW, "AirdropContainer_Supplies_C_21473100" .. i, 3, root, H_CRATE_AT[i])
    C_CRATES[i] = crate(CW, "AirdropContainer_Supplies_C_21474800" .. i, 1, root, root)
end
for i = 1, N_BARRELS do
    H_BARRELS[i] = barrel(HW, i)
    C_BARRELS[i] = barrel(CW, i)
end
WORLD = HW
local hnuke = new(HW, { "BP_EasterEgg_Nuke_C" }, "BP_EasterEgg_Nuke_C_1", {}, { MC_Explode = rec("MC_Explode") })
WORLD = CW
local cnuke = new(CW, { "BP_EasterEgg_Nuke_C" }, "BP_EasterEgg_Nuke_C_1", {}, { MC_Explode = rec("MC_Explode") })

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
H.ctx.scope_resolver = function() return nil end
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)

local function to_client(msgs)
    WORLD = CW
    for _, msg in ipairs(msgs) do
        local kind, f = C.net.decode(msg)
        local h = C.net.handlers[kind]
        if h then h(f, CW.pc) end
    end
end
local function kind_of(msg) return (msg:match("^SDC1|([%w]+)|")) end

-- ===========================================================================
print("== B0. earlier in the session on the host: barrels and the nuke blew up")
for i = 1, N_BARRELS - 1 do fire(HW, BARREL .. ":Event_Explode", param(H_BARRELS[i])) end
fire(HW, NUKE .. ":MC_Explode", param(hnuke))
local live = {}
for _, m in ipairs(HW.outbox) do if kind_of(m) == "WBOOM" then live[#live + 1] = m end end
check(#live == N_BARRELS, "each explosion went out live (WBOOM): " .. #live)
check(not live[1]:find("|s$"), "a live explosion carries no silent flag: " .. live[1])
HW.outbox = {}   -- the client below joins after them

print("== B1. the join snapshot: one list message per kind")
-- the host's crates have landed and rest (no live WCRATE of their own during the snapshot)
local HEV = H.world._t.events
WORLD = HW
for _, a in ipairs(FindAllOf("Master_AirdropContainer_C")) do
    local c = HEV.crate_track(a)
    c.st, c.next, c.last = "rest", T + 1000, vcopy(a._p.StaticMesh._p._wloc)
end
WORLD = HW; H.world._t.snapshot(rpc)
local by_kind, all = {}, {}
for _ = 1, 40 do
    WORLD = HW; H.world.tick()
    for _, m in ipairs(HW.outbox) do
        local k = kind_of(m)
        by_kind[k] = by_kind[k] or {}
        table.insert(by_kind[k], m)
        all[#all + 1] = m
    end
    to_client(HW.outbox)
    HW.outbox = {}
    advance(0.25)
end
local function n_of(k) return by_kind[k] and #by_kind[k] or 0 end
local function entries(k)
    local n = 0
    for _, m in ipairs(by_kind[k] or {}) do
        local _, f = H.net.decode(m)
        for _ in tostring(f[1]):gmatch("[^;]+") do n = n + 1 end
    end
    return n
end
check(n_of("WDOOR") == 1 and entries("WDOOR") == 9, "WDOOR: 1 message, 9 doors (5 open + 4 unlocked): " .. n_of("WDOOR") .. "/" .. entries("WDOOR"))
-- (keypad doors are replicated doors too: their Open? goes in the same list)
check(n_of("WRDOOR") == 1 and entries("WRDOOR") == N_RDOORS + N_KEYPADS,
    "WRDOOR: 1 message, every replicated door (warehouse and keypad doors): " .. n_of("WRDOOR") .. "/" .. entries("WRDOOR"))
check(n_of("WKEYCODE") == 1 and entries("WKEYCODE") == N_KEYPADS, "WKEYCODE: 1 message, every keypad: " .. n_of("WKEYCODE") .. "/" .. entries("WKEYCODE"))
check(n_of("WCRATE") == 1 and entries("WCRATE") == N_CRATES, "WCRATE: 1 message, every crate: " .. n_of("WCRATE") .. "/" .. entries("WCRATE"))
check(n_of("WBOOM") == 1 and entries("WBOOM") == N_BARRELS and by_kind.WBOOM[1]:find("|s$") ~= nil,
    "WBOOM: 1 silent message (|s) with every barrel and the nuke: " .. tostring(by_kind.WBOOM and by_kind.WBOOM[1]))
check(#all == 5, "the whole snapshot: " .. #all .. " message(s) (one per object before: "
    .. (9 + N_RDOORS + 2 * N_KEYPADS + N_CRATES + 2) .. ")")

print("== B2. the client applies every list")
local opened, unlocked = 0, 0
for i = 1, N_DOORS do
    if C_DOORS[i]._p["Closed?"] == false then opened = opened + 1 end
    if C_DOORS[i]._p["IsLocked?"] == false then unlocked = unlocked + 1 end
end
check(opened == 5 and called(C_DOORS[1], "Event_Door") and not called(C_DOORS[6], "Event_Door"),
    "the 5 open locked doors opened here with their own Event_Door: " .. opened)
check(unlocked == 9 and C_DOORS[12]._p["IsLocked?"] == true, "9 unlocked here, the locked ones stay locked: " .. unlocked)
run_timers(CW); run_timers(CW)
local rmatch = 0
for i = 1, N_RDOORS do if C_RDOORS[i]._p.IsClosed == H_RDOORS[i]._p.IsClosed then rmatch = rmatch + 1 end end
check(rmatch == N_RDOORS and called(C_RDOORS[1], "MC_OpenDoor") and not called(C_RDOORS[2], "MC_OpenDoor"),
    "replicated doors: every one as on the host (the open ones toggled by MC_OpenDoor): " .. rmatch)
local codes = 0
for i = 1, N_KEYPADS do if C_KEYPADS[i]._p.Code == 2000 + i and C_NOTES[i]._p.Code == 2000 + i then codes = codes + 1 end end
check(codes == N_KEYPADS, "every keypad door and its note have the host's code: " .. codes)
local placed = 0
for i = 1, N_CRATES do
    local m = C_CRATES[i]._p.StaticMesh._p
    if m._wloc.X == H_CRATE_AT[i].X and m._wloc.Y == H_CRATE_AT[i].Y and m._sim == false then placed = placed + 1 end
end
check(placed == N_CRATES, "every crate at the host's place, physics off: " .. placed)

print("== B3. barrels and the nuke of the snapshot only go (no blast at the join)")
local gone, blasts = 0, 0
for i = 1, N_BARRELS - 1 do
    if not C_BARRELS[i]._valid and called(C_BARRELS[i], "K2_DestroyActor") then gone = gone + 1 end
    if called(C_BARRELS[i], "Event_Explode") then blasts = blasts + 1 end
end
check(gone == N_BARRELS - 1 and blasts == 0, "barrels destroyed, no Event_Explode (emitter, sound, AI noise, shake): " .. gone .. "/" .. blasts)
check(C_BARRELS[N_BARRELS]._valid and not called(C_BARRELS[N_BARRELS], "K2_DestroyActor"), "a barrel that never blew up stays")
check(not cnuke._valid and called(cnuke, "MC_Explode") == nil, "the nuke goes without its MC_Explode")

print("== B4. live messages and the old one-object forms still work")
-- a live explosion on the host now: the client's copy blows up the game's way
HW.outbox = {}
fire(HW, BARREL .. ":Event_Explode", param(H_BARRELS[N_BARRELS]))
to_client(HW.outbox)
check(called(C_BARRELS[N_BARRELS], "Event_Explode") ~= nil, "a live WBOOM: the client's barrel explodes (Event_Explode)")
HW.outbox = {}
-- old single forms
local d13 = C_DOORS[13]
to_client({ H.net.encode("WDOOR", "~LongdownValley~BP_LockedDoor_C_13", "d", "o", "u") })
check(d13._p["Closed?"] == false and d13._p["IsLocked?"] == false, "WDOOR|door|ev|want|unlocked (one door) applied")
local r2 = C_RDOORS[2]
to_client({ H.net.encode("WRDOOR", "~LongdownValley~BP_WarehouseDoors_C_2", "0") })
run_timers(CW); run_timers(CW)
check(r2._p.IsClosed == false, "WRDOOR|door|0 (one door) applied")
to_client({ H.net.encode("WKEYCODE", "~LongdownValley~BP_KeypadDoor_C_3", "7777") })
check(C_KEYPADS[3]._p.Code == 7777 and C_NOTES[3]._p.Code == 7777, "WKEYCODE|door|code (one door) applied")
to_client({ H.net.encode("WCRATE", "10000,0,48000", "10500,60,130", "0.0,45.0,0.0", "s") })
check(C_CRATES[1]._p.StaticMesh._p._wloc.X == 10500, "WCRATE|root|mesh|rot|flag (one crate) applied")
-- a malformed list entry is skipped, the rest applied
to_client({ H.net.encode("WKEYCODE", "garbage;~LongdownValley~BP_KeypadDoor_C_4!5555") })
check(C_KEYPADS[4]._p.Code == 5555, "a broken entry in a list is skipped, the others applied")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
