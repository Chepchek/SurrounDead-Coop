-- Mock harness: airdrop crates in one place for host and client (sdc_world EV crates):
-- the client plane's own drop blocked, the host's landing / settled place, the
-- client's copy placed with its physics off, pushes, joins, late copies.
-- usage: lua mock_world_crates.lua <scripts dir>
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
-- Airdrop crates (sdc_world EV crate section, 0.6.68). The fake crate is
-- Master_AirdropContainer: its root (DefaultSceneRoot) stays at the drop
-- point, its StaticMesh simulates physics on each machine on its own.
-- ===========================================================================
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local CRATE_P = "/Game/Inventory/Containers/Containers/Airdrop/Master_AirdropContainer.Master_AirdropContainer_C"
local DROP = { X = 50000, Y = -20000, Z = 48000 }   -- the plane's drop point (the crate's root on both machines)

local function vcopy(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function rcopy(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

local function crate(w, name, role, root, mesh_at)
    WORLD = w
    local mesh = new(w, { "StaticMeshComponent" }, name .. ".StaticMesh",
        { _wloc = vcopy(mesh_at), _wrot = { Pitch = 0, Yaw = 30, Roll = 0 }, _sim = true }, {
        K2_GetComponentLocation = function(self) return vcopy(self._p._wloc) end,
        K2_GetComponentRotation = function(self) return rcopy(self._p._wrot) end,
        SetSimulatePhysics = function(self, b) self._p._sim = b; self._calls[#self._calls + 1] = { "SetSimulatePhysics", b } end,
        IsSimulatingPhysics = function(self) return self._p._sim end,
        K2_SetWorldLocationAndRotation = function(self, l, r, sweep, hit, tp)
            self._p._wloc, self._p._wrot = vcopy(l), rcopy(r)
            self._calls[#self._calls + 1] = { "K2_SetWorldLocationAndRotation", tp }
        end,
    })
    local chute = new(w, { "StaticMeshComponent" }, name .. ".Parachute", { _vis = true, _col = 1 }, {
        SetVisibility = function(self, v) self._p._vis = v end,
        SetCollisionEnabled = function(self, c) self._p._col = c end,
    })
    return new(w, { "AirdropContainer_Supplies_C", "Master_AirdropContainer_C", "BP_MasterObject_C" }, name,
        { StaticMesh = mesh, Parachute = chute, _loc = vcopy(root), Role = role, bReplicates = true, bAlwaysRelevant = true })
end
local function mesh_of(c) return c._p.StaticMesh end
local function at(c) return mesh_of(c)._p._wloc end

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
local HEV, CEV = H.world._t.events, C.world._t.events

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
local function ticks(n, dt)
    for _ = 1, n do
        advance(dt or 0.25)
        WORLD = HW; H.world.tick(); deliver()
        WORLD = CW; C.world.tick(); deliver()
        settle()
    end
end
local function sent_crates(kind_flag)
    local n = 0
    for _, m in ipairs(HW.outbox) do if m:find("|WCRATE|", 1, true) and (not kind_flag or m:find("|" .. kind_flag .. "$")) then n = n + 1 end end
    return n
end

print("== K0. hooks; the client's first snapshot before any crate")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
check(HW.hooks[CRATE_P .. ":ReceiveHit"] ~= nil and C.net.handlers.WCRATE ~= nil, "landing hook and WCRATE handler")
ticks(24, 0.25)

print("== K1. the client's copy of the plane drops nothing of its own")
WORLD = CW
local cplane = new(CW, { "AirdropAircraft_C", "BP_MasterObject_C" }, "AirdropAircraft_C_2147482100", { Role = 1 })
local crate_cls = new(CW, { "BlueprintGeneratedClass" }, "AirdropContainer_Supplies_C", {}, {},
    "/Game/Inventory/Containers/Containers/Airdrop/AirdropContainer_Supplies.AirdropContainer_Supplies_C")
local cp = param(crate_cls)
fire(CW, SPAWN, param(nil), param(cplane), cp, param({}))
check(cp._v() ~= crate_cls and cp._v() == CW.paths["/Script/CoreUObject.Object"], "the client plane's own crate spawn is blocked")
WORLD = HW
local hplane = new(HW, { "AirdropAircraft_C", "BP_MasterObject_C" }, "AirdropAircraft_C_2147300001", { Role = 3 })
local hcls = new(HW, { "BlueprintGeneratedClass" }, "AirdropContainer_Supplies_C", {}, {},
    "/Game/Inventory/Containers/Containers/Airdrop/AirdropContainer_Supplies.AirdropContainer_Supplies_C")
local hp = param(hcls)
fire(HW, SPAWN, param(nil), param(hplane), hp, param({}))
check(hp._v() == hcls, "the host plane's drop goes on")

print("== K2. falling: each machine's own physics, nothing sent")
local hc = crate(HW, "AirdropContainer_Supplies_C_2147310001", 3, DROP, DROP)
-- the replicated copy: another name, the same root (drop point, replicated with cm rounding)
local cc = crate(CW, "AirdropContainer_Supplies_C_2147482300", 1, { X = DROP.X + 0.4, Y = DROP.Y - 0.3, Z = DROP.Z }, DROP)
run_timers(HW)   -- the drop's delayed listing tracks the crate
check(next(HEV.crates) ~= nil, "the host tracks the dropped crate")
for i = 1, 8 do
    at(hc).Z = DROP.Z - i * 1500; at(cc).Z = DROP.Z - i * 1490
    ticks(4, 0.25)
end
check(H.world.stats.crate_sent == 0, "no place sent while it falls")

print("== K3. landing on the slope: the host's place now, the final one when it stops")
local GROUND = { X = 50040, Y = -20010, Z = 30200 }
hc._p.StaticMesh._p._wloc = vcopy(GROUND)
cc._p.StaticMesh._p._wloc = { X = 50040, Y = -20010, Z = 30210 }
WORLD = HW; fire(HW, CRATE_P .. ":ReceiveHit", param(hc))
check(sent_crates("l") == 1, "landing: its place sent (l)")
deliver()
check(dist(at(cc), GROUND) < 1 and mesh_of(cc)._p._sim == false, "the client's copy at the host's landing place, its physics off")
check(cc._p.Parachute._p._vis == false and cc._p.Parachute._p._col == 0, "its parachute off as at its own landing")
check(mesh_of(hc)._p._sim == true, "the host's crate keeps the game's physics")
-- the host's crate slides 2 m and stops; the client's copy (physics off) waits
local REST = { X = 50040, Y = -19810, Z = 30150 }
hc._p.StaticMesh._p._wloc = vcopy(REST); hc._p.StaticMesh._p._wrot = { Pitch = 12, Yaw = 40, Roll = -6 }
ticks(5, 0.25)
check(dist(at(cc), GROUND) < 1, "(still at the landing place while the host's slides)")
ticks(5, 0.25)
check(dist(at(cc), REST) < 1 and math.abs(mesh_of(cc)._p._wrot.Pitch - 12) < 0.2 and math.abs(mesh_of(cc)._p._wrot.Roll + 6) < 0.2,
    "settled: the client's copy at the host's final place and rotation")
local placed = C.world.stats.crate_snapped
ticks(20, 0.25)
check(C.world.stats.crate_snapped == placed and H.world.stats.crate_sent == 2, "nothing more while both rest (2 sent)")

print("== K4. the client's copy rolls again on its own: put back")
mesh_of(cc)._p._sim = true; mesh_of(cc)._p._wloc = { X = 50040, Y = -18000, Z = 29000 }
ticks(10, 0.25)
check(dist(at(cc), REST) < 1 and mesh_of(cc)._p._sim == false, "the client's 2 s look put it back")

print("== K5. the host's crate is pushed: its new place when it stops again")
local PUSHED = { X = 50340, Y = -19810, Z = 30120 }
hc._p.StaticMesh._p._wloc = vcopy(PUSHED)
ticks(40, 0.25)
check(dist(at(cc), PUSHED) < 1, "the client's copy follows the push")

print("== K6. a joining client gets every crate; a falling one keeps its physics")
local hc2 = crate(HW, "AirdropContainer_Supplies_C_2147310002", 3, { X = 60000, Y = 0, Z = 47000 }, { X = 60000, Y = 0, Z = 40000 })
-- a fresh client world: its copies start at the drop points with their own physics
C.world.reset("mock: join again")
local cc_new = crate(CW, "AirdropContainer_Supplies_C_2147482400", 1, DROP, DROP)
cc._valid = false
local cc2 = crate(CW, "AirdropContainer_Supplies_C_2147482401", 1, { X = 60000, Y = 0, Z = 47000 }, { X = 60000, Y = 0, Z = 47000 })
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 20 do WORLD = HW; H.world.tick(); deliver() end
check(dist(at(cc_new), PUSHED) < 1 and mesh_of(cc_new)._p._sim == false, "the landed crate: at the host's place, physics off")
check(dist(at(cc2), { X = 60000, Y = 0, Z = 40000 }) < 1 and mesh_of(cc2)._p._sim == true, "the falling one: at the host's height, still falling")

print("== K7. a copy that is not here yet gets its place when it comes")
local hc3 = crate(HW, "AirdropContainer_Supplies_C_2147310003", 3, { X = -30000, Y = 5000, Z = 46000 }, { X = -30000, Y = 5000, Z = 46000 })
WORLD = HW; fire(HW, CRATE_P .. ":ReceiveHit", param(hc3))
deliver()
local pend = C.world._t.pending()
local has = false
for _, e in ipairs(pend) do if e.kind == "crate" then has = true end end
check(has, "kept for later on the client")
local cc3 = crate(CW, "AirdropContainer_Supplies_C_2147482500", 1, { X = -30000, Y = 5000, Z = 46000 }, { X = -30000, Y = 5000, Z = 46000 })
ticks(10, 0.25)
check(dist(at(cc3), { X = -30000, Y = 5000, Z = 46000 }) < 1 and mesh_of(cc3)._p._sim == false, "applied when it appeared")

print("== K8. looted and gone: no more looks")
hc._valid = false; cc_new._valid = false
ticks(12, 0.25)
local tracked = 0
for _ in pairs(HEV.crates) do tracked = tracked + 1 end
check(tracked == 2, "the host forgets the gone crate (" .. tracked .. " left)")
local ckeys = 0
for _ in pairs(CEV.ccrates) do ckeys = ckeys + 1 end
check(ckeys == 2, "the client forgets its copy (" .. ckeys .. " left)")

print("== K9. status")
WORLD = HW; local sh = H.world.status_line(); print(sh)
WORLD = CW; local scl = C.world.status_line(); print(scl)
check(sh:find("placed=", 1, true) ~= nil, "status: placed=sent/applied")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
