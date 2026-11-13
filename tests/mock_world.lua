-- Mock harness: runs the real sdc_world / sdc_ctx / sdc_net / sdc_ue against
-- fake UE objects, one world for the host and one for the client.
-- usage: lua mock_world.lua <scripts dir>
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

-- world objects on both machines (same level paths)
local function both(fn) local h = fn(HW); local c = fn(CW); return h, c end
local hbox, cbox = both(function(w) WORLD = w
    local comp = new(w, { "BP_JigComponent_C" }, "Box_Jig_" .. w.id, {}, { StartRefillTimer = rec("StartRefillTimer") })
    return new(w, { "Container_RandomLoot_TrashBag_C", "BP_LootContainer_C" }, "Container_RandomLoot_TrashBag_C_7",
        { ContainerLooted = false, BP_JigMultiplayer = comp, _loc = { X = 100, Y = 0, Z = 0 } },
        { Bind_Refill = function(self) self._p.ContainerLooted = false; self._calls[#self._calls + 1] = { "Bind_Refill" } end })
end)
local hdoor, cdoor = both(function(w) WORLD = w
    local tl = new(w, { "TimelineComponent" }, "TL_" .. w.id, {}, { IsPlaying = function(self) return self._playing == true end })
    local d
    d = new(w, { "BP_LockedDoor_C", "BP_LockPickObject_C" }, "BP_LockedDoor_C_3",
        { ["Closed?"] = true, ["IsLocked?"] = true, Timeline_OpenDoor = tl, Timeline_OpenDoor__Direction_CA4B83EF45872B61E7779EAD32D6380C = 0 },
        { Event_Door = function(self)
              self._calls[#self._calls + 1] = { "Event_Door" }
              tl._playing = true
              self._p.Timeline_OpenDoor__Direction_CA4B83EF45872B61E7779EAD32D6380C = self._p["Closed?"] and 0 or 1
              fire(w, "/Game/Blueprints/Other/Doors/BP_LockedDoor.BP_LockedDoor_C:Event_Door", param(self))
          end })
    d._tl = tl
    return d
end)
local hwh, cwh = both(function(w) WORLD = w
    return new(w, { "BP_WarehouseDoors_C" }, "BP_WarehouseDoors_C_1", { IsClosed = true },
        { MC_OpenDoor = function(self) self._p.IsClosed = not self._p.IsClosed; self._calls[#self._calls + 1] = { "MC_OpenDoor" } end })
end)
local hism, cism = both(function(w) WORLD = w
    local ifa = new(w, { "InstancedFoliageActor" }, "InstancedFoliageActor_0")
    new(w, { "MaterialInstanceConstant" }, "M_Tree", {}, {}, "/Game/Foliage/M_Tree.M_Tree")
    local inst = { [0] = { X = 1000, Y = 0, Z = 0 }, [1] = { X = 2000, Y = 0, Z = 0 } }
    local ism
    ism = new(w, { "FoliageInstancedStaticMeshComponent" }, "InstancedFoliageActor_0.FoliageISMC_5",
        { _owner = ifa, StaticMesh = new(w, { "StaticMesh" }, "SM_Tree", {}, {}, "/Game/Foliage/SM_Tree.SM_Tree") }, {
        GetInstancesOverlappingSphere = function(self, loc, r)
            local out = {}
            for i, l in pairs(inst) do
                if math.abs(l.X - loc.X) < r and math.abs(l.Y - loc.Y) < r then out[#out + 1] = i end
            end
            return out
        end,
        GetInstanceTransform = function(self, i, out)
            out.OutInstanceTransform = { Translation = inst[i], Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
            return true
        end,
        RemoveInstance = function(self, i) inst[i] = nil; self._calls[#self._calls + 1] = { "RemoveInstance", i } end,
        GetMaterial = function() return w.paths["/Game/Foliage/M_Tree.M_Tree"] end,
    })
    ism._p._owner = ifa
    ism._inst = inst
    return ism
end)
local hbarrel, cbarrel = both(function(w) WORLD = w
    return new(w, { "BP_ExplosiveBarrel_Child_C", "BP_ExplosiveBarrelMaster_C" }, "BP_ExplosiveBarrel_Child_C_2", { Health = 40 }, {
        Event_Explode = function(self, inst)
            self._calls[#self._calls + 1] = { "Event_Explode", inst }
            self._valid = false
            fire(w, "/Game/Blueprints/Other/ExplosiveBarrel/BP_ExplosiveBarrelMaster.BP_ExplosiveBarrelMaster_C:Event_Explode", param(self), param(inst))
        end,
        Damage_Object = function(self, dmg, causer) self._calls[#self._calls + 1] = { "Damage_Object", dmg, causer } end,
    })
end)
local htrash, ctrash = both(function(w) WORLD = w
    return new(w, { "TrashObject_C", "StaticMeshActor" }, "TrashObject_C_9", { IsDestroyed = false, Health = 50 }, {
        ActorLoaded = rec("ActorLoaded"),
        BndEvt__TrashObject_WorldObjectComponent_K2Node_ComponentBoundEvent_0_ObjectDamaged__DelegateSignature = rec("ObjectDamaged"),
    })
end)
local hscrap, cscrap = both(function(w) WORLD = w
    local ps = new(w, { "ParticleSystemComponent" }, "PS_" .. w.id, {}, { K2_DestroyComponent = rec("K2_DestroyComponent") })
    return new(w, { "BP_HarvestableObject_ScrapMetal_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_ScrapMetal_C_4",
        { ["Salvaged?"] = false, ParticleSystem = ps, _loc = { X = 1, Y = 2, Z = 3 } }, { Svr_PlaySound = rec("Svr_PlaySound") })
end)
local hinf, cinf = both(function(w) WORLD = w
    return new(w, { "BP_PrimaryInfestation_C", "BP_Infestation_C" }, "BP_PrimaryInfestation_C_1", { ["IsDestroyed?"] = false },
        { Event_OnDestroyed = rec("Event_OnDestroyed"), Damage_Object = rec("Damage_Object") })
end)

-- weapons
WORLD = CW
local cknife = new(CW, { "BP_KnifePickup_C", "BP_MeleePickup_C" }, "BP_KnifePickup_C_77", { _owner = CW.pawn })
local cgun = new(CW, { "BP_M4Pickup_C", "BP_FirearmPickup_C" }, "BP_M4Pickup_C_78", { _owner = CW.pawn })
WORLD = HW
local hknife_r = new(HW, { "BP_KnifePickup_C", "BP_MeleePickup_C" }, "BP_KnifePickup_C_88", { _owner = rpawn, BP_WeaponsPickupComponent = rpawn })
local hknife_h = new(HW, { "BP_AxePickup_C", "BP_MeleePickup_C" }, "BP_AxePickup_C_89", { _owner = HW.pawn, BP_WeaponsPickupComponent = rpawn })

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    -- sdc_net's own send budget (0.6.58) drains from a game-thread loop this
    -- harness does not run: off here (it is sdc_net's to test)
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...) if k == "net_send_budget" then return false end return get0(k, ...) end
    m.net.install_hooks()
    m.world = require("sdc_world")
    return m
end
local H = load_mods(HW)
local prev_called = 0
H.ctx.scope_resolver = function() prev_called = prev_called + 1 return nil end
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)

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

local function tick_both()
    WORLD = HW; H.world.tick(); WORLD = CW; C.world.tick()
end

print("== 0. install, hooks")
check(H.ctx.scope_resolver == H.world.resolver, "host resolver installed in front")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
local nh = 0
for _ in pairs(HW.hooks) do nh = nh + 1 end
check(nh >= #H.world._t.hooks, "host hooks registered (" .. nh .. ")")
check(H.world._t.pack(LVL .. "X_C_1") == "~LongdownValley~X_C_1", "pack")
check(H.world._t.unpack("~LongdownValley~X_C_1") == LVL .. "X_C_1", "unpack")

local LOOT_OPEN = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:OpenContainer"
print("== 1. containers")
cbox._p.ContainerLooted = true
fire(CW, LOOT_OPEN, param(cbox))
deliver()
check(hbox._p.ContainerLooted == true, "client search -> host container searched")
check(hbox._p.BP_JigMultiplayer._p["Looted?"] == true, "host comp Looted?")
check(called(hbox._p.BP_JigMultiplayer, "StartRefillTimer") ~= nil, "host refill timer started")
fire(CW, LOOT_OPEN, param(cbox))
check(#CW.outbox == 0, "second open sends nothing")
fire(HW, "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:Bind_Refill", param(hbox))
check(#HW.outbox == 0, "refill not sent inside the hook (batched on the next tick)")
WORLD = HW; H.world.tick(); deliver(); WORLD = CW; C.world.tick()
check(called(cbox, "Bind_Refill") ~= nil and cbox._p.ContainerLooted == false, "host refill -> client Bind_Refill")
hbox._p.ContainerLooted = true
fire(HW, LOOT_OPEN, param(hbox))
deliver()
check(cbox._p.ContainerLooted == true, "host search -> client searched")

print("== 2. locked door")
cdoor:Event_Door()   -- the client's own interaction (fires the hook)
deliver()
check(called(hdoor, "Event_Door") ~= nil, "client door open -> host Event_Door")
check(#CW.outbox == 0, "no echo from the client's door")
-- host's door now opening; client's door already opening: no second toggle
local n_before = #cdoor._calls
deliver()
check(#cdoor._calls == n_before, "client door not toggled again by the host's relay")

print("== 3. harvesting")
local HARV = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C:"
local cls_tree = CW.paths["/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Tree.BP_HarvestableObject_Tree_C"]
local cp = param(cls_tree)
fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cknife), cp,
    param({ Translation = { X = 1000, Y = 0, Z = 0 } }))
check(cp._v()._name == "Object", "client harvestable spawn blocked (class " .. tostring(cp._v()._name) .. ")")
cism:RemoveInstance(0)
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(CW.paths[LVL .. "InstancedFoliageActor_0"]), param(nil), param(cism), param(0))
check(#CW.outbox == 1 and CW.outbox[1]:find("WHARV", 1, true) ~= nil, "client sent WHARV")
deliver()
run_timers(HW)
check(#HW.spawned == 1 and HW.spawned[1]._finished == true, "host spawned the harvestable")
check(hism._inst[0] == nil, "host instance removed")
deliver()
check(#CW.outbox == 0, "client ok")
-- host-side harvest of instance 1 by the client's copy -> WFOL
local hcls_tree = HW.paths["/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Tree.BP_HarvestableObject_Tree_C"]
fire(HW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(hknife_r), param(hcls_tree),
    param({ Translation = { X = 2000, Y = 0, Z = 0 } }))
hism:RemoveInstance(1)
fire(HW, HARV .. "HitFoliageTree", param(hknife_r), param(HW.paths[LVL .. "InstancedFoliageActor_0"]), param(nil), param(hism), param(1))
deliver()
check(cism._inst[1] == nil, "host harvest -> client instance removed (WFOL)")
-- the harvestable is hit by the remote player's knife: resource scope
local tree = new(HW, { "BP_HarvestableObject_Tree_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_Tree_C_5")
fire(HW, HARV .. "HitFoliageTree", param(hknife_r), param(tree), param(nil), param(nil), param(0))
WORLD = HW
check(H.world.resolver(tree) == rpc, "tree's player 0 = the remote player who hit it")
local info = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = HW.paths["/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal"],
               Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 9 }
local drop = new(HW, { "BP_StaticMeshPickup_C" }, "BP_StaticMeshPickup_C_3")
fire(HW, "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:JigMP_OnRequestDropItem", param(rpawn), param(info), param(nil), param(drop))
run_timers(HW)
-- (no word from that client's screen: the drop waits for one, then that
-- screen is asked where it goes - sdc_place - never the plugin's any-grid add)
check(called(rjig, "Add") == nil and drop._valid == true, "a world resource's drop waits for the client's word first")
local asked = {}
local prev_place = package.loaded["sdc_place"]
package.loaded["sdc_place"] = { ask = function(p, d, n, dp, why) asked[#asked + 1] = { p = p, d = d, n = n, dp = dp, why = why }; return true end }
advance(H.world._t.harvest.SPOT_WAIT + 0.1)
H.world._t.harvest.pend_pass(os.clock())
package.loaded["sdc_place"] = prev_place
check(called(rjig, "Add") == nil, "no word in time: not the plugin's any-grid add")
check(#asked == 1 and asked[1].p == rpawn and asked[1].n == 9 and asked[1].dp == LVL .. "BP_StaticMeshPickup_C_3",
    "no word in time: that client's screen is asked where it goes, with its drop")
check(drop._valid == true, "the drop waits at its feet for the answer (sdc_place removes it once the item is in)")
check(H.world.resolver(HW.paths[LVL .. "BP_WarehouseDoors_C_1"]) == nil and prev_called > 0, "other objects fall through to the previous resolver")

-- a rock / trash pile that hands out its resource inside the swing
local rock = new(HW, { "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_Rocks_C_6")
advance(1)
check(H.world.resolver(hknife_r) == nil, "a weapon's own player-0 call is left alone")
check(H.world.resolver(rock) == rpc, "rock hit inside the remote player's swing -> that player")
advance(1)
H.world.resolver(hknife_h)
check(H.world.resolver(htrash) == false, "trash hit inside the host's swing -> the host's own")
advance(1)
print("== 4. scrap salvage")
fire(CW, "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI", param(nil), param(FText("Scrap")),
    param(nil), param(nil), param(2), param(false), param(cscrap))
deliver()
check(hscrap._p["Salvaged?"] == true and called(hscrap, "Svr_PlaySound") ~= nil, "host salvaged the pile for the client")
local add = called(rjig, "Add")
check(add ~= nil, "scrap granted")

print("== 5. objects")
fire(CW, "/Game/Blueprints/Other/InteractableWorldObject/TrashObject.TrashObject_C:BndEvt__TrashObject_WorldObjectComponent_K2Node_ComponentBoundEvent_1_ObjectDestroyed__DelegateSignature", param(ctrash))
deliver()
run_timers(HW)
check(called(htrash, "ObjectDamaged") ~= nil and htrash._p.Health == 0, "client's broken trash breaks on the host")
-- the client's firearm hit on the barrel
fire(CW, "/Game/Blueprints/Other/ExplosiveBarrel/BP_ExplosiveBarrelMaster.BP_ExplosiveBarrelMaster_C:Damage_Object", param(cbarrel), param(12.5), param(CW.pawn), param(nil))
fire(CW, "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Trace_Impact", param(cgun), param(nil), param(nil), param(cbarrel))
deliver()
local dc = called(hbarrel, "Damage_Object")
check(dc ~= nil and dc[2] == 12.5 and dc[3] == rpawn, "client shot -> host Damage_Object with the client's pawn")
-- host barrel explodes -> client
hbarrel:Event_Explode(nil)
deliver()
check(called(cbarrel, "Event_Explode") ~= nil, "host explosion -> client barrel explodes")
fire(HW, "/Game/Infestation/BP_Infestation.BP_Infestation_C:Event_OnDestroyed", param(hinf), param(nil), param(false))
deliver()
local od = called(cinf, "Event_OnDestroyed")
check(od ~= nil and od[3] == true, "host infestation destroyed -> client load path")

print("== 6. replicated door reconcile")
hwh._p.IsClosed = false
fire(HW, "/Game/Blueprints/Other/Doors/BP_WarehouseDoors.BP_WarehouseDoors_C:MC_OpenDoor", param(hwh), param(nil))
run_timers(HW); deliver(); run_timers(CW); run_timers(CW)
check(cwh._p.IsClosed == false and called(cwh, "MC_OpenDoor") ~= nil, "client warehouse door toggled to the host's state")

print("== 7. build")
CW.bc._p["BuildModeOn?"] = true
CW.bc._p.DARef = CW.paths["/Game/Inventory/Items/DataAssets/Buildable/DA_WoodenWall.DA_WoodenWall"]
CW.bc._p.BuildUID = { A = 1, B = -2, C = 3, D = 4 }
fire(CW, "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C:Event_LaunchBuildMode", param(CW.bc), param(nil), param(false), param(nil))
run_timers(CW)
deliver()
check(rbc._p.DARef == HW.paths["/Game/Inventory/Items/DataAssets/Buildable/DA_WoodenWall.DA_WoodenWall"], "host copy got DARef")
check(rbc._p.BuildUID and rbc._p.BuildUID.B == -2, "host copy got BuildUID")
fire(HW, "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C:SpawnBuild", param(rbc), param(nil))
deliver()
check(called(CW.jig, "SERVER_RequestConsumeItem") ~= nil, "client consumed the placed item")
check(called(CW.bc, "Event_StopBuildMode") ~= nil, "client left build mode (no more items)")
-- placing from a ground pickup (PickupRef): no Blueprint of game 0.8.0 sets it; if
-- an update ever does, the tail still runs here and the log says it is not mirrored
local gpick = new(CW, { "BP_StaticMeshPickup_C" }, "BP_StaticMeshPickup_C_2147300001", {},
    { PickupBuildFromGround = rec("PickupBuildFromGround") })
CW.bc._p.PickupRef = gpick
local warned, warn0 = {}, C.log.warn
C.log.warn = function(m, ...) warned[#warned + 1] = string.format(m, ...); return warn0(m, ...) end
WORLD = CW; C.net.handlers.WBUILT({ "0" }, CW.pc)
C.log.warn = warn0
CW.bc._p.PickupRef = nil
check(called(gpick, "PickupBuildFromGround") ~= nil and #warned == 1 and warned[1]:find("ground pickup", 1, true) ~= nil,
    "a placement from a ground pickup: the game's tail here, and a warning that the host's pickup stays")

print("== 8. horde boss")
WORLD = HW
local boss = new(HW, { "BP_ZombieBossHorde_Infestation_C", "BP_ZombieBoss_C" }, "BP_ZombieBossHorde_Infestation_C_1",
    { _loc = { X = 4900, Y = 0, Z = 0 } }, { GetGameTimeSinceCreation = function() return 0.1 end })
check(H.world.resolver(boss) == rpc, "new horde boss binds to the nearest (remote) player")
advance(3)
check(H.world.resolver(boss) == nil, "later calls left alone")


print("== 10. prefab camps")
WORLD = CW
local cspawner = new(CW, { "BP_PrefabSpawner_C" }, "BP_PrefabSpawner_C_12", { Role = 3 })
local camp_cls = new(CW, { "BlueprintGeneratedClass" }, "Prefab_SmallScavengerCamp_C", {}, {}, "/Game/Prefabs/Camps/Scavenger/Prefab_SmallScavengerCamp.Prefab_SmallScavengerCamp_C")
local pcls = param(camp_cls)
fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cspawner), pcls, param({}))
check(pcls._v()._name == "Object", "client's own camp spawn blocked")
run_timers(CW)
check(cspawner._valid == false, "client's spawner removed (no phantom discovery / marker)")
-- the host spawner: nothing blocked
WORLD = HW
local hspawner = new(HW, { "BP_PrefabSpawner_C" }, "BP_PrefabSpawner_C_12", { Role = 3 })
local hcamp_cls = new(HW, { "BlueprintGeneratedClass" }, "Prefab_SmallScavengerCamp_C", {}, {}, "/Game/Prefabs/Camps/Scavenger/Prefab_SmallScavengerCamp.Prefab_SmallScavengerCamp_C")
local hp = param(hcamp_cls)
fire(HW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(hspawner), hp, param({}))
check(hp._v() == hcamp_cls, "host's camp spawn untouched")
-- the host's camp replicates (new-object watch)
local station = new(HW, { "BP_CraftingStation_C" }, "BP_CraftingStation_C_2147400001", { bReplicates = true, Role = 3 }, { ForceNetUpdate = rec("ForceNetUpdate") })
local volume = new(HW, { "BP_AISpawningVolume_Prefab_C" }, "BP_AISpawningVolume_Prefab_C_2147400002", { Role = 3 })
local camp = new(HW, { "Prefab_SmallScavengerCamp_C", "PrefabMaster_C" }, "Prefab_SmallScavengerCamp_C_2147400000", { Role = 3 }, {
    SetReplicates = function(self, v) self._p.bReplicates = v end,
    ForceNetUpdate = rec("ForceNetUpdate"),
    GetAllChildActors = function(self, out) out.ChildActors = { station, volume } end,
})
local watches_camps = false
for _, w in ipairs(HW.watch or {}) do if w.path == "/Game/Prefabs/PrefabMaster.PrefabMaster_C" then watches_camps = true end end
check(watches_camps, "host watches new camps")
for _, w in ipairs(HW.watch) do if w.path == "/Game/Prefabs/PrefabMaster.PrefabMaster_C" then assert(w.fn(camp) == nil) end end
run_timers(HW)
check(camp._p.bReplicates == true and camp._p.NetCullDistanceSquared == 1e10, "host camp replicates, 1 km cull")
check(station._p.NetCullDistanceSquared == 1e10 and volume._p.NetCullDistanceSquared == nil, "replicated station gets the range, the local AI volume not")
-- the client: its copy of the host's AI volume must not spawn AI
WORLD = CW
local cvol = new(CW, { "BP_AISpawningVolume_Prefab_C" }, "BP_AISpawningVolume_Prefab_C_2147400009", { Role = 3 })
local bandit = new(CW, { "BlueprintGeneratedClass" }, "BP_Bandit_Melee_C", {}, {}, "/Game/AI/Humans/BP_Bandit_Melee.BP_Bandit_Melee_C")
local bp = param(bandit)
fire(CW, "/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass", param(nil), param(cvol), bp)
check(bp._v()._name == "Object", "client AI volume spawn blocked")
-- client-only leftovers removed by the pass; the host's replicated copy kept
local local_camp = new(CW, { "Prefab_SmallScavengerCamp_C", "PrefabMaster_C" }, "Prefab_SmallScavengerCamp_C_2147400100", { Role = 3 })
local host_copy = new(CW, { "Prefab_SmallScavengerCamp_C", "PrefabMaster_C" }, "Prefab_SmallScavengerCamp_C_2147400101", { Role = 1, bReplicates = true })
local local_cache = new(CW, { "Container_HiddenCache_C", "BP_LootContainer_C" }, "Container_HiddenCache_C_2147400102", { Role = 3, bReplicates = true })
advance(10); WORLD = CW; C.world.tick(); advance(10); C.world.tick()
check(local_camp._valid == false and local_cache._valid == false, "client-only camp / cache removed")
check(host_copy._valid == true, "host's replicated camp kept")

print("== 11. crates / infestation caches / settlements")
-- the client's own destruction of a nest reaches the host
WORLD = HW
local hdc = new(HW, { "DamageComponent_C" }, "DamageComponent_inf2", { CurrentHealth = 900 }, { DamageTaken = rec("DamageTaken") })
local hinf2 = new(HW, { "BP_Infestation_Floor_C", "BP_Infestation_C" }, "BP_Infestation_Floor_C_3", { ["IsDestroyed?"] = false, DamageComponent = hdc })
WORLD = CW
local cinf2 = new(CW, { "BP_Infestation_Floor_C", "BP_Infestation_C" }, "BP_Infestation_Floor_C_3", { ["IsDestroyed?"] = true })
fire(CW, "/Game/Infestation/BP_Infestation.BP_Infestation_C:Event_OnDestroyed", param(cinf2), param(CW.pawn), param(false))
deliver()
local dt = called(hdc, "DamageTaken")
check(dt ~= nil and dt[2] > 900 and dt[4] == rpawn, "client-destroyed nest destroyed on the host (DamageTaken by the client's pawn)")
-- load-path destruction is not reported
local n_out = #CW.outbox
fire(CW, "/Game/Infestation/BP_Infestation.BP_Infestation_C:Event_OnDestroyed", param(cinf2), param(nil), param(true))
check(#CW.outbox == n_out, "game-load destruction not sent")
-- client-only loot containers go, the host's replicated ones and placed ones stay
WORLD = CW
local function notify(w, path, o) for _, x in ipairs(w.watch or {}) do if x.path == path then assert(x.fn(o) == nil) end end end
local LOOTP = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
local local_crate = new(CW, { "Container_HighTierMilitaryLoot_Crates_C", "BP_LootContainer_C" }, "Container_HighTierMilitaryLoot_Crates_C_2147400200", { Role = 3 })
local host_crate = new(CW, { "Container_HighTierMilitaryLoot_Crates_C", "BP_LootContainer_C" }, "Container_HighTierMilitaryLoot_Crates_C_2147400201", { Role = 1 })
local placed_crate = new(CW, { "Container_HighTierMilitaryLoot_Crates_C", "BP_LootContainer_C" }, "Container_HighTierMilitaryLoot_Crates_C_12", { Role = 1 })
local dead_loot = new(CW, { "Container_DeadPlayerLoot_C", "BP_LootContainer_C" }, "Container_DeadPlayerLoot_C_2147400202", { Role = 3 })
for _, o in ipairs({ local_crate, host_crate, placed_crate, dead_loot }) do notify(CW, LOOTP, o) end
run_timers(CW)
check(local_crate._valid == false, "client-only crate removed")
check(host_crate._valid and placed_crate._valid and dead_loot._valid, "host's / placed crates and dead-player loot kept")
-- the client's own settlement spawn is blocked
local csettle = new(CW, { "BP_SettlementCampSpawner_C" }, "BP_SettlementCampSpawner_C_2", { Role = 3 })
local scls = new(CW, { "BlueprintGeneratedClass" }, "Prefab_Settlement2_C", {}, {}, "/Game/Prefabs/Settlements/Prefab_Settlement2.Prefab_Settlement2_C")
local sp = param(scls)
fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(csettle), sp, param({}))
check(sp._v()._name == "Object", "client's own settlement spawn blocked")
-- a placed AI volume is left to the AI modules
local pvol = new(CW, { "BP_AISpawningVolume_RandomChanceToSpawn_C" }, "BP_AISpawningVolume_RandomChanceToSpawn_C_4", { Role = 3 })
local pb = param(bandit)
fire(CW, "/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass", param(nil), param(pvol), pb)
check(pb._v() == bandit, "placed AI volume untouched")

print("== 12. refill wave of 2500 containers")
local N, LOOTED = 2500, 120
local hboxes, cboxes = {}, {}
for i = 1, N do
    local name = "Container_RandomLoot_TrashBag_C_W" .. i
    WORLD = HW
    hboxes[i] = new(HW, { "Container_RandomLoot_TrashBag_C", "BP_LootContainer_C" }, name, { ContainerLooted = false })
    WORLD = CW
    cboxes[i] = new(CW, { "Container_RandomLoot_TrashBag_C", "BP_LootContainer_C" }, name,
        { ContainerLooted = false }, { Bind_Refill = function(self) self._p.ContainerLooted = false; self._calls[#self._calls + 1] = { "Bind_Refill" } end })
end
-- the host searched LOOTED of them: those go to the client as searched
for i = 1, LOOTED do
    hboxes[i]._p.ContainerLooted = true
    fire(HW, LOOT_OPEN, param(hboxes[i]))
end
for _ = 1, 80 do WORLD = HW; H.world.tick(); deliver() end
local cl = 0
for i = 1, N do if cboxes[i]._p.ContainerLooted then cl = cl + 1 end end
check(cl == LOOTED, "client shows the host's " .. LOOTED .. " searched boxes (" .. cl .. ")")
-- the wave: every container refills on the host within a second
HW.outbox = {}
for i = 1, N do
    hboxes[i]._p.ContainerLooted = false
    fire(HW, "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:Bind_Refill", param(hboxes[i]))
end
check(#HW.outbox == 0, "nothing sent from inside 2500 refill hooks")
local total, maxper, ticks = 0, 0, 0
for _ = 1, 40 do
    WORLD = HW; H.world.tick()
    ticks = ticks + 1
    maxper = math.max(maxper, #HW.outbox)
    total = total + #HW.outbox
    deliver()
    WORLD = CW; C.world.tick()
end
check(maxper <= 3, "at most 3 messages per host tick (max " .. maxper .. ")")
check(total <= 10, "the wave took " .. total .. " message(s), not one per container")
local still, calls = 0, 0
for i = 1, N do
    if cboxes[i]._p.ContainerLooted then still = still + 1 end
    if called(cboxes[i], "Bind_Refill") then calls = calls + 1 end
end
check(still == 0, "every client copy unsearched again (" .. still .. " left)")
check(calls == LOOTED, "Bind_Refill run only on the " .. LOOTED .. " boxes marked searched here (" .. calls .. ")")
advance(5); WORLD = HW; H.world.tick()
-- a second wave right after: nothing marked searched -> nothing sent
HW.outbox = {}
for i = 1, N do fire(HW, "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:Bind_Refill", param(hboxes[i])) end
local again = 0
for _ = 1, 10 do WORLD = HW; H.world.tick(); again = again + #HW.outbox; deliver() end
check(again == 0, "a wave of untouched boxes sends nothing (" .. again .. ")")
-- client-side budget: 300 refills queued at once are applied 25 per tick
WORLD = CW
for i = 1, 300 do cboxes[i]._p.ContainerLooted = true end
local items = {}
for i = 1, 300 do items[#items + 1] = C.world.pack(cboxes[i]._full:match("^%S+%s+(.+)$")) end
C.net.handlers["WLOOTR"]({ table.concat(items, ";") }, CW.pc)
local before = 0
for i = 1, 300 do if not cboxes[i]._p.ContainerLooted then before = before + 1 end end
C.world.tick()
local after1 = 0
for i = 1, 300 do if not cboxes[i]._p.ContainerLooted then after1 = after1 + 1 end end
check(before == 0 and after1 <= 25, "client applies at most 25 refills per tick (" .. after1 .. ")")
for _ = 1, 15 do C.world.tick() end
local after = 0
for i = 1, 300 do if not cboxes[i]._p.ContainerLooted then after = after + 1 end end
check(after == 300, "all 300 applied over the next ticks (" .. after .. ")")

print("== 13. trees: the host's harvestable shown on the client, the client's hits counted on the host")
local TREE_CLS = "/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Tree.BP_HarvestableObject_Tree_C"
local function notify_w(w, path, o) for _, x in ipairs(w.watch or {}) do if x.path == path then assert(x.fn(o) == nil) end end end
local function harv_actor(w, name, loc, role, mesh)
    WORLD = w
    local comp = new(w, { "StaticMeshComponent" }, name .. ".StaticMesh", { StaticMesh = mesh }, {
        SetStaticMesh = function(self, m) self._p.StaticMesh = m; self._calls[#self._calls + 1] = { "SetStaticMesh", m }; return true end,
        SetMaterial = function(self, i, m) self._calls[#self._calls + 1] = { "SetMaterial", i, m } end,
    })
    local a = new(w, { "BP_HarvestableObject_Tree_C", "BP_HarvestableObject_C" }, name,
        { _loc = loc, Role = role, MaxHits = 1, StaticMesh = comp })
    for k, fn in pairs(HARV_METHODS) do a._m[k] = fn end
    notify_w(w, TREE_CLS, a)
    return a, comp
end
local watched = false
for _, x in ipairs(CW.watch or {}) do if x.path == TREE_CLS then watched = true end end
check(watched, "both machines watch new trees / rocks (NotifyOnNewObject)")
hism._inst[2] = { X = 3000, Y = 0, Z = 0 }
cism._inst[2] = { X = 3000, Y = 0, Z = 0 }
-- the host's replay of the client's swing cuts instance 2: host tree + WFOL
local htree3 = harv_actor(HW, "BP_HarvestableObject_Tree_C_2147300003", { X = 3000, Y = 0, Z = 0 }, 3, HW.paths["/Game/Foliage/SM_Tree.SM_Tree"])
fire(HW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(hknife_r), param(hcls_tree),
    param({ Translation = { X = 3000, Y = 0, Z = 0 } }))
hism:RemoveInstance(2)
fire(HW, HARV .. "HitFoliageTree", param(hknife_r), param(HW.paths[LVL .. "InstancedFoliageActor_0"]), param({ X = 3000, Y = 0, Z = 100 }),
    param(hism), param(2), param(1))
check(called(htree3, "SetMaxHits") ~= nil and htree3._p.MaxHits == 7, "host primed its new tree (SetMaxHits: no class-default 1 on clients)")
local wfol = HW.outbox[#HW.outbox] or ""
check(wfol:find("WFOL", 1, true) ~= nil and wfol:find("|2$") ~= nil, "WFOL carries the instance index (" .. wfol .. ")")
-- the client: the replicated tree arrives without a mesh
local ctree3, ccomp3 = harv_actor(CW, "BP_HarvestableObject_Tree_C_2147400003", { X = 3000, Y = 0, Z = 0 }, 1, nil)
deliver()
check(cism._inst[2] == nil and called(cism, "RemoveInstance") ~= nil, "client removed the instance (index hint)")
WORLD = CW; C.world.tick()
check(ccomp3._p.StaticMesh == CW.paths["/Game/Foliage/SM_Tree.SM_Tree"], "client's copy of the host's tree got its mesh")
check(ctree3._p.Mesh == ccomp3._p.StaticMesh and ctree3._p.Material == CW.paths["/Game/Foliage/M_Tree.M_Tree"], "and Mesh / Material set like the swing does")
check(called(ccomp3, "SetMaterial") ~= nil, "material on the mesh component")
-- the client's own swing hits it (twice in one swing)
CW.outbox = {}
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(ctree3), param({ X = 3000, Y = 10, Z = 100 }), param(nil), param(0), param(1))
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(ctree3), param({ X = 3000, Y = 12, Z = 100 }), param(nil), param(0), param(1))
check(#CW.outbox == 0, "client hits are summed, not sent from the hook")
WORLD = CW; C.world.tick()
check(#CW.outbox == 1 and CW.outbox[1]:find("WHHIT|t|3000,0,0|2|", 1, true) ~= nil, "one WHHIT with 2 hits (" .. tostring(CW.outbox[1]) .. ")")
deliver()
local hh = called(htree3, "HitHarvestableObject")
check(hh ~= nil and hh[3] == 2 and htree3._p.MaxHits == 5, "host ran HitHarvestableObject x2 (MaxHits " .. tostring(htree3._p.MaxHits) .. ")")
WORLD = HW
check(H.world.resolver(htree3) == rpc, "the tree's player 0 = the client who hit it (its grant)")
-- the host's replay of the same swing hit first: the relay is the same swing
htree3:HitHarvestableObject({ X = 3000, Y = 0, Z = 100 }, 1)
fire(HW, HARV .. "HitFoliageTree", param(hknife_r), param(htree3), param({ X = 3000, Y = 0, Z = 100 }), param(nil), param(0), param(1))
local dup0 = H.world.stats.hits_dup
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(ctree3), param({ X = 3000, Y = 10, Z = 100 }), param(nil), param(0), param(1))
WORLD = CW; C.world.tick(); deliver()
check(H.world.stats.hits_dup == dup0 + 1 and htree3._p.MaxHits == 4, "a relay right after the host's replay hit is not counted twice")
-- felled by the client's power swing
advance(1)
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(ctree3), param({ X = 3000, Y = 10, Z = 100 }), param(nil), param(0), param(4))
WORLD = CW; C.world.tick(); deliver()
check(htree3._p.MaxHits == 0 and htree3._fell == 1, "client's hits fell the host's tree")
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(ctree3), param({ X = 3000, Y = 10, Z = 100 }), param(nil), param(0), param(1))
WORLD = CW; C.world.tick(); deliver()
check(htree3._p.MaxHits == 0 and htree3._fell == 1, "a hit on a felled tree changes nothing (one fall, one grant)")
-- another player's hits on the host's own swing are not relayed (client copy of the host's swing)
local hostknife_c = new(CW, { "BP_AxePickup_C", "BP_MeleePickup_C" }, "BP_AxePickup_C_90", { _owner = new(CW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_9", { _local = false }) })
CW.outbox = {}
fire(CW, HARV .. "HitFoliageTree", param(hostknife_c), param(ctree3), param({ X = 3000, Y = 10, Z = 100 }), param(nil), param(0), param(1))
WORLD = CW; C.world.tick()
check(#CW.outbox == 0, "the client's copy of someone else's swing sends nothing")
-- a hit that comes before the host's tree exists waits for it
WORLD = HW
H.net.handlers["WHHIT"]({ "t", "7000,0,0", "1", "7000,0,100" }, rpc)
check(#H.world._t.harvest.wait == 1, "hit on a tree not made here yet waits")
local htree4 = harv_actor(HW, "BP_HarvestableObject_Tree_C_2147300004", { X = 7000, Y = 0, Z = 0 }, 3, HW.paths["/Game/Foliage/SM_Tree.SM_Tree"])
WORLD = HW; H.world.tick()
check(called(htree4, "HitHarvestableObject") ~= nil and #H.world._t.harvest.wait == 0, "and is applied when it appears")

-- the watch never reported a harvestable on this client: found by a scan
WORLD = CW
C.world._t.harvest.seen_new = nil
local ctree5c = new(CW, { "StaticMeshComponent" }, "BP_HarvestableObject_Tree_C_2147400005.StaticMesh", {}, {
    SetStaticMesh = function(self, m) self._p.StaticMesh = m; return true end, SetMaterial = function() end })
local ctree5 = new(CW, { "BP_HarvestableObject_Tree_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_Tree_C_2147400005",
    { _loc = { X = 8000, Y = 0, Z = 0 }, Role = 1, StaticMesh = ctree5c })
C.net.handlers["WFOL"]({ C.world.pack(LVL .. "InstancedFoliageActor_0.FoliageISMC_5"), "8000,0,0", "" }, CW.pc)
advance(2.5); WORLD = CW; C.world.tick()
check(ctree5c._p.StaticMesh == CW.paths["/Game/Foliage/SM_Tree.SM_Tree"], "a harvestable the watch missed is found by a scan and shown")
check(called(ccomp3, "SetMobility") == nil, "a tree's mesh component is left as it is (its construction made it movable)")

print("== 13b. rocks: the host's rock (Static mesh component) shown on the client, the client's hits counted")
do
    local ROCK_CLS = "/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Rocks.BP_HarvestableObject_Rocks_C"
    local rlines = {}
    local w0, i0 = C.log.warn, C.log.info
    C.log.warn = function(msg, ...) rlines[#rlines + 1] = string.format(msg, ...); return w0(msg, ...) end
    C.log.info = function(msg, ...) rlines[#rlines + 1] = string.format(msg, ...); return i0(msg, ...) end
    local function rlogged(pat) for _, s in ipairs(rlines) do if s:find(pat, 1, true) then return s end end return nil end
    WORLD = CW
    local sm_rock = new(CW, { "StaticMesh" }, "SM_Rock01", {}, {}, "/Game/Foliage/SM_Rock01.SM_Rock01")
    new(CW, { "FoliageInstancedStaticMeshComponent" }, "InstancedFoliageActor_0.FoliageISMC_9",
        { _owner = CW.paths[LVL .. "InstancedFoliageActor_0"], StaticMesh = sm_rock }, {
        GetInstancesOverlappingSphere = function() return {} end,
        GetInstanceTransform = function() return false end,
        RemoveInstance = rec("RemoveInstance") })
    -- the engine: SetStaticMesh on a registered Static component after BeginPlay
    -- does nothing; SetMobility(Movable) on a parent makes its children Movable
    local function comp(name, mesh_comp, never)
        local m = { SetMobility = function(self, v)
            self._calls[#self._calls + 1] = { "SetMobility", v }
            self._p.Mobility = v
            if v == 2 then for _, ch in ipairs(self._kids or {}) do ch:SetMobility(2) end end
        end }
        if mesh_comp then
            m.SetStaticMesh = function(self, mesh)
                self._calls[#self._calls + 1] = { "SetStaticMesh", mesh }
                if never or self._p.Mobility ~= 2 then return false end
                self._p.StaticMesh = mesh
                return true
            end
        end
        return new(CW, { mesh_comp and "StaticMeshComponent" or "SceneComponent" }, name, { Mobility = 0 }, m)
    end
    local function crock_at(name, x, never)
        local sm = comp(name .. ".StaticMesh", true, never)
        local root = comp(name .. ".DefaultSceneRoot", false)
        root._kids = { sm }
        local a = new(CW, { "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_C" }, name,
            { _loc = { X = x, Y = 0, Z = 0 }, Role = 1, MaxHits = 5, StaticMesh = sm },
            { K2_GetRootComponent = function() return root end })
        notify_w(CW, ROCK_CLS, a)
        C.net.handlers["WFOL"]({ C.world.pack(LVL .. "InstancedFoliageActor_0.FoliageISMC_9"), x .. ",0,0", "" }, CW.pc)
        return a, sm, root
    end
    local crock, crsm, crroot = crock_at("BP_HarvestableObject_Rocks_C_2147400010", 9500)
    WORLD = CW; C.world.tick()
    check(crroot._p.Mobility == 2 and crsm._p.Mobility == 2, "client made the host's rock movable (root and mesh component)")
    check(crsm._p.StaticMesh == sm_rock and crock._p.Mesh == sm_rock, "client's copy of the host's rock got its mesh (was refused while Static)")
    check(rlogged("the host's rock BP_HarvestableObject_Rocks_C_2147400010 at 9500,0,0 shown here (mesh SM_Rock01, made movable)") ~= nil,
        "the first rock shown is logged at info")
    -- the host's rock at that place; the client's own swing hits its copy
    WORLD = HW
    local hrock = new(HW, { "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_Rocks_C_2147300010",
        { _loc = { X = 9500, Y = 0, Z = 0 }, Role = 3, MaxHits = 5 })
    for k, fn in pairs(HARV_METHODS) do hrock._m[k] = fn end
    advance(1)
    CW.outbox = {}
    fire(CW, HARV .. "HitFoliageRock", param(cknife), param(crock), param({ X = 9500, Y = 10, Z = 50 }), param(nil), param(0), param(1))
    WORLD = CW; C.world.tick()
    check(#CW.outbox == 1 and CW.outbox[1]:find("WHHIT|r|9500,0,0|1|", 1, true) ~= nil, "client sent its rock hit (" .. tostring(CW.outbox[1]) .. ")")
    deliver()
    check(called(hrock, "HitHarvestableObject") ~= nil and hrock._p.MaxHits == 6, "host ran the rock's HitHarvestableObject (MaxHits " .. tostring(hrock._p.MaxHits) .. ")")
    WORLD = HW
    check(H.world.resolver(hrock) == rpc, "the rock's player 0 = the client who hit it (its stone)")
    -- a component that still refuses: not called shown, said once, tried again
    local _, bsm = crock_at("BP_HarvestableObject_Rocks_C_2147400011", 9900, true)
    WORLD = CW; C.world.tick()
    check(bsm._p.StaticMesh == nil and rlogged("cannot be shown here: its mesh component did not take SM_Rock01") ~= nil,
        "a rock whose component still refuses the mesh is reported, not called shown")
    local n_set = 0
    advance(1.5); WORLD = CW; C.world.tick()
    for _, c in ipairs(bsm._calls) do if c[1] == "SetStaticMesh" then n_set = n_set + 1 end end
    check(n_set >= 2, "and tried again (" .. n_set .. " tries)")
    C.log.warn, C.log.info = w0, i0
end

print("== 14. foliage lookup when UE4SS fills the out table itself / the overlap query fails")
local function alt_ism(w, inst, inplace, overlap_fails)
    WORLD = w
    local ism = new(w, { "FoliageInstancedStaticMeshComponent" }, "InstancedFoliageActor_0.FoliageISMC_7",
        { _owner = w.paths[LVL .. "InstancedFoliageActor_0"], StaticMesh = w.paths["/Game/Foliage/SM_Tree.SM_Tree"] }, {
        GetInstancesOverlappingSphere = function(self, loc, r)
            if overlap_fails then error("unsupported return type") end
            local out = {}
            for i, l in pairs(inst) do if math.abs(l.X - loc.X) < r then out[#out + 1] = { get = function() return i end } end end
            return out
        end,
        GetInstanceTransform = function(self, i, out)
            if not inst[i] then return false end
            if inplace then
                out.Translation = inst[i]; out.Rotation = { X = 0, Y = 0, Z = 0, W = 1 }; out.Scale3D = { X = 1, Y = 1, Z = 1 }
            else
                out.OutInstanceTransform = { Translation = inst[i], Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
            end
            return true
        end,
        RemoveInstance = function(self, i) inst[i] = nil; self._calls[#self._calls + 1] = { "RemoveInstance", i } end,
        GetMaterial = function() return w.paths["/Game/Foliage/M_Tree.M_Tree"] end,
    })
    ism._inst = inst
    return ism
end
local hism7 = alt_ism(HW, { [0] = { X = 5000, Y = 0, Z = 0 }, [1] = { X = 6000, Y = 0, Z = 0 } }, true, true)
local cism7 = alt_ism(CW, { [0] = { X = 5000, Y = 0, Z = 0 }, [1] = { X = 6000, Y = 0, Z = 0 } }, false, false)
-- the client's own cut the host's trace missed: WHARV with the index
local cp7 = param(cls_tree)
fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cknife), cp7,
    param({ Translation = { X = 6000, Y = 0, Z = 0 } }))
cism7:RemoveInstance(1)
CW.outbox = {}
fire(CW, HARV .. "HitFoliageTree", param(cknife), param(CW.paths[LVL .. "InstancedFoliageActor_0"]), param({ X = 6000, Y = 0, Z = 90 }),
    param(cism7), param(1), param(1))
check(#CW.outbox == 1 and CW.outbox[1]:find("WHARV", 1, true) ~= nil and CW.outbox[1]:find("|t|1$") ~= nil, "WHARV carries kind and index (" .. tostring(CW.outbox[1]) .. ")")
local nspawn = #HW.spawned
deliver(); run_timers(HW)
check(#HW.spawned == nspawn + 1 and hism7._inst[1] == nil, "host found the instance by its index (in-place out table, no overlap query) and cut it")
local made = HW.spawned[#HW.spawned]
check(made._p._tf and made._p._tf.Translation and made._p._tf.Translation.X == 6000, "the host's harvestable at the instance's place")
check(called(made, "SetMaxHits") ~= nil, "and primed")
-- an overlap-only lookup (index out of step) on the client
cism7._inst[0] = nil
cism7._inst[5] = { X = 5000, Y = 0, Z = 0 }
WORLD = CW
local idx, how = C.world._t.harvest.instance(cism7, { X = 5000, Y = 0, Z = 0 }, 0)
check(idx == 5 and how == "overlap", "index out of step -> found among the overlapping ones (" .. tostring(idx) .. ", " .. tostring(how) .. ")")
local idx2, why2 = H.world._t.harvest.instance(hism7, { X = 9000, Y = 0, Z = 0 }, 0)
check(idx2 == nil and type(why2) == "string" and why2:find("overlap query failed", 1, true) ~= nil, "a miss says why (" .. tostring(why2) .. ")")

print("== 15. scrap: the client's own roll")
local hscrap2, cscrap2 = both(function(w) WORLD = w
    local ps = new(w, { "ParticleSystemComponent" }, "PS2_" .. w.id, {}, { K2_DestroyComponent = rec("K2_DestroyComponent") })
    return new(w, { "BP_HarvestableObject_ScrapMetal_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_ScrapMetal_C_8",
        { ["Salvaged?"] = false, ParticleSystem = ps, _loc = { X = 1, Y = 2, Z = 3 } }, { Svr_PlaySound = rec("Svr_PlaySound") })
end)
local cda_scrap = CW.paths["/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal"]
fire(CW, "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:JigTryAddItemSomewhere", param(CW.jig), param(CW.jig),
    param(cda_scrap), param(32), param(false), param(nil))
fire(CW, "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI", param(nil), param(FText("Scrap")),
    param(nil), param(nil), param(2), param(false), param(cscrap2))
deliver()
local last_add
for _, c in ipairs(rjig._calls) do if c[1] == "Add" then last_add = c end end
check(hscrap2._p["Salvaged?"] == true and last_add and last_add[3] == 32, "host added the client's roll (x" .. tostring(last_add and last_add[3]) .. ")")

print("== 16. moving furniture")
local function crate(w, name, loc, cur, methods)
    WORLD = w
    local m = methods or {}
    m.SetReplicateMovement = m.SetReplicateMovement or function(self, v) self._p.bReplicateMovement = v; self._calls[#self._calls + 1] = { "SetReplicateMovement", v } end
    m.ForceNetUpdate = m.ForceNetUpdate or rec("ForceNetUpdate")
    m.FlushNetDormancy = m.FlushNetDormancy or rec("FlushNetDormancy")
    m.K2_GetActorRotation = m.K2_GetActorRotation or function(self) return self._p._rot or { Pitch = 0, Yaw = 0, Roll = 0 } end
    m.K2_SetActorLocationAndRotation = m.K2_SetActorLocationAndRotation or function(self, l, r)
        self._p._loc = { X = l.X, Y = l.Y, Z = l.Z }; self._p._rot = r; self._calls[#self._calls + 1] = { "SetLocRot", l, r }
    end
    return new(w, { "Buildable_AmmoCrate_C", "BuildableMaster_Container_C", "Buildable_MASTER_C" }, name,
        { _loc = loc, CurrentActor = cur, PickupDataAsset = w.paths["/Game/Inventory/Items/DataAssets/Buildable/DA_WoodenWall.DA_WoodenWall"], Role = (w == HW) and 3 or 1 }, m)
end
local REPL = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C:ReplacingObject"
local SPAWNB = "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C:SpawnBuild"
local hcrate = crate(HW, "Buildable_AmmoCrate_C_2147166332", { X = 100, Y = 200, Z = 0 }, rpawn)
local ccrate = crate(CW, "Buildable_AmmoCrate_C_2147202574", { X = 100, Y = 200, Z = 0 }, nil)
fire(HW, REPL, param(hcrate))
check(hcrate._p.bReplicateMovement == true, "moved buildable replicates its movement on the host")
check(rbc._p["ReplacingObject?"] == true and rbc._p.ReplacingActor == hcrate, "host copy of the client's BuildingComponent in move mode")
-- the client's placement: SpawnBuild on the host moves it there
hcrate._p._loc = { X = 400, Y = 250, Z = 0 }
hcrate._p._rot = { Pitch = 0, Yaw = 90, Roll = 0 }
CW.bc._calls = {}
fire(HW, SPAWNB, param(rbc), param(nil))
check(called(hcrate, "ForceNetUpdate") ~= nil, "host pushes the moved buildable out now")
deliver()
check(ccrate._p._loc.X == 400 and ccrate._p._loc.Y == 250 and ccrate._p._rot and ccrate._p._rot.Yaw == 90, "client's copy moved to the new place (WMOVE)")
check(called(CW.bc, "Event_StopBuildMode") ~= nil, "client's move mode ended (WBUILT 1)")
-- the engine already moved it: nothing done twice
local n_calls = #ccrate._calls
HW.outbox = {}
WORLD = HW
-- the host's own move of another crate
local hcrate2 = crate(HW, "Buildable_AmmoCrate_C_2147166340", { X = -500, Y = 0, Z = 0 }, HW.pawn)
local ccrate2 = crate(CW, "Buildable_AmmoCrate_C_2147202580", { X = -500, Y = 0, Z = 0 }, nil)
fire(HW, REPL, param(hcrate2))
check(hcrate2._p.bReplicateMovement == true, "the host's own move: movement replicates too")
-- a new building placed by the host while that move was pending: no WMOVE
HW.outbox = {}
fire(HW, SPAWNB, param(HW.bc), param(nil))
check(#HW.outbox == 0, "a new building of the host sends no WMOVE")
hcrate2._p._loc = { X = -800, Y = 10, Z = 0 }
fire(HW, SPAWNB, param(HW.bc), param(nil))
deliver()
check(ccrate2._p._loc.X == -800, "the host's own move reaches the client")
-- a WMOVE for a copy the engine already moved
ccrate2._calls = {}
WORLD = CW
C.net.handlers["WMOVE"]({ "Buildable_AmmoCrate_C", "-800,10,0", "-800.0,10.0,0.0", "0,0,0" }, CW.pc)
check(called(ccrate2, "SetLocRot") == nil, "copy already at the new place is left alone")
check(#ccrate._calls == n_calls, "the first crate untouched by the second move")
-- a WMOVE before the copy is known here: retried
local late = { "Buildable_AmmoCrate_C", "3000,3000,0", "3100.0,3000.0,0.0", "0,0,0" }
WORLD = CW
C.net.handlers["WMOVE"](late, CW.pc)
local ccrate3 = crate(CW, "Buildable_AmmoCrate_C_2147202590", { X = 3000, Y = 3000, Z = 0 }, nil)
advance(3); WORLD = CW; C.world.tick()
check(ccrate3._p._loc.X == 3100, "a move for a copy that was not here yet is applied when it is")

print("== 17. random infestations come from the host")
-- the host's per-client queue still holds the end of section 12's traffic
local function pump() for _ = 1, 12 do WORLD = HW; H.world.tick(); deliver() end end
pump()
do
    local INF = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
    local MESH_N = "/Game/Infestation/Meshes/Infestations/InfestationLarge.InfestationLarge"
    local MESH_D = "/Game/Infestation/Meshes/Infestations/InfestationLarge_D.InfestationLarge_D"
    local function notify(w, path, o) for _, x in ipairs(w.watch or {}) do if x.path == path then assert(x.fn(o) == nil) end end end
    local meshes = {}
    for _, w in ipairs({ HW, CW }) do
        WORLD = w
        meshes[w.id] = {
            n = new(w, { "StaticMesh" }, "InfestationLarge", {}, {}, MESH_N),
            d = new(w, { "StaticMesh" }, "InfestationLarge_D", {}, {}, MESH_D),
            wall = new(w, { "StaticMesh" }, "InfestationWall", {}, {}, "/Game/Infestation/Meshes/Infestations/InfestationWall.InfestationWall"),
        }
    end
    local function nest(w, name, loc, role, mesh, dmesh)
        WORLD = w
        local sm = new(w, { "StaticMeshComponent" }, name .. ".StaticMesh", { StaticMesh = mesh }, {
            SetStaticMesh = function(self, m) self._p.StaticMesh = m; return true end })
        local dust = new(w, { "NiagaraComponent" }, name .. ".Dust", { _vis = false }, {
            SetVisibility = function(self, v) self._p._vis = v end })
        local dc = new(w, { "DamageComponent_C" }, name .. ".DamageComponent", { CurrentHealth = 900 }, { DamageTaken = rec("DamageTaken") })
        local a = new(w, { "BP_Infestation_C", "BP_MasterObject_C" }, name,
            { _loc = loc, Role = role, NormalMesh = mesh, DestroyedMesh = dmesh, StaticMesh = sm, NS_InfestationDust = dust,
              DamageComponent = dc, ["IsDestroyed?"] = false }, {
            SetReplicates = function(self, v) self._p.bReplicates = v end,
            ForceNetUpdate = rec("ForceNetUpdate"),
            Damage_Object = rec("Damage_Object"),
            Event_OnDestroyed = function(self, causer, load)
                self._p["IsDestroyed?"] = true
                self._calls[#self._calls + 1] = { "Event_OnDestroyed", causer, load }
                fire(w, INF .. ":Event_OnDestroyed", param(self), param(causer), param(load))
            end,
        })
        notify(w, INF, a)
        return a, sm, dust, dc
    end
    -- a client's own spawn point spawns nothing
    WORLD = CW
    local csp = new(CW, { "BP_RandomInfestationSpawnPoint_C" }, "BP_RandomInfestationSpawnPoint_C_4", { Role = 3 })
    local cinf_cls = new(CW, { "BlueprintGeneratedClass" }, "BP_Infestation_C", {}, {}, INF)
    local cp = param(cinf_cls)
    fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(csp), cp, param({}))
    check(cp._v()._name == "Object", "client's random infestation spawn blocked")
    check(csp._valid == true, "its spawn point stays (no prefab-style removal)")
    WORLD = HW
    local hsp = new(HW, { "BP_RandomInfestationSpawnPoint_C" }, "BP_RandomInfestationSpawnPoint_C_4", { Role = 3 })
    local hinf_cls = new(HW, { "BlueprintGeneratedClass" }, "BP_Infestation_C", {}, {}, INF)
    local hp = param(hinf_cls)
    fire(HW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(hsp), hp, param({}))
    check(hp._v() == hinf_cls, "host's spawn point untouched")
    -- the host's nest (spawned or loaded by EMS) replicates and is described
    local hnest = nest(HW, "BP_Infestation_C_2147500001", { X = 9000, Y = 0, Z = 0 }, 3, meshes.host.n, meshes.host.d)
    HW.outbox = {}
    advance(0.3); WORLD = HW; H.world.tick()
    check(hnest._p.bReplicates == true and hnest._p.bAlwaysRelevant == true, "host nest replicates, always relevant")
    local w1 = HW.outbox[1] or ""
    check(w1:find("WRINF|9000,0,0>" .. MESH_N .. ">" .. MESH_D .. ">0", 1, true) ~= nil, "WRINF with its meshes (" .. w1 .. ")")
    -- the client: its copy arrives with the class's default mesh
    local cnest, csm, cdust = nest(CW, "BP_Infestation_C_2147600001", { X = 9000, Y = 0, Z = 0 }, 1, meshes.client.wall, meshes.client.wall)
    pump()
    WORLD = CW; C.world.tick()
    check(csm._p.StaticMesh == meshes.client.n and cnest._p.NormalMesh == meshes.client.n and cnest._p.DestroyedMesh == meshes.client.d,
        "client's copy dressed with the host's meshes")
    check(cnest._p["RandomInfestation?"] == true and cdust._p._vis == true, "random flag and dust as on the host")
    -- the client shoots it: the host's nest takes the damage
    fire(CW, INF .. ":Damage_Object", param(cnest), param(12.5), param(CW.pawn), param(nil))
    fire(CW, "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Trace_Impact", param(cgun), param(nil), param(nil), param(cnest))
    local wdmg = CW.outbox[#CW.outbox] or ""
    check(wdmg:find("WDMG|~R~9000,0,0|12.50", 1, true) ~= nil, "client's shot named by place (" .. wdmg .. ")")
    deliver()
    local dmc = called(hnest, "Damage_Object")
    check(dmc ~= nil and dmc[2] == 12.5 and dmc[3] == rpawn, "host nest damaged by the client's pawn")
    -- the client destroys it: destroyed on the host for that player
    cnest:Event_OnDestroyed(CW.pawn, false)
    deliver()
    local hdc = hnest._p.DamageComponent
    check(called(hdc, "DamageTaken") ~= nil, "client's destruction reaches the host's nest (DamageTaken)")
    -- a second nest destroyed on the host only
    local hnest2 = nest(HW, "BP_Infestation_C_2147500002", { X = 12000, Y = 500, Z = 0 }, 3, meshes.host.n, meshes.host.d)
    advance(0.3); WORLD = HW; H.world.tick()
    local cnest2, csm2 = nest(CW, "BP_Infestation_C_2147600002", { X = 12000, Y = 500, Z = 0 }, 1, meshes.client.wall, meshes.client.wall)
    pump(); WORLD = CW; C.world.tick()
    hnest2:Event_OnDestroyed(rpawn, false)
    pump(); WORLD = CW; C.world.tick()
    local od2 = called(cnest2, "Event_OnDestroyed")
    check(od2 ~= nil and od2[3] == true, "host's destruction -> client copy runs the load path")
    check(csm2._p.StaticMesh == meshes.client.d, "client copy shows the destroyed mesh")
    check(H.world._t.nests.host["~R~12000,500,0"].d == true, "host remembers it destroyed (snapshot)")
    -- a WINF for a nest whose copy is not here yet: applied when it comes
    WORLD = CW
    C.net.handlers["WRINF"]({ "15000,0,0>" .. MESH_N .. ">" .. MESH_D .. ">0" }, CW.pc)
    C.net.handlers["WINF"]({ "~R~15000,0,0" }, CW.pc)
    local cnest3, csm3 = nest(CW, "BP_Infestation_C_2147600003", { X = 15000, Y = 0, Z = 0 }, 1, meshes.client.wall, meshes.client.wall)
    advance(1); WORLD = CW; C.world.tick()
    check(called(cnest3, "Event_OnDestroyed") ~= nil and csm3._p.StaticMesh == meshes.client.d, "late copy of a destroyed nest looks destroyed")
    -- a nest this client made itself goes; the host's copies stay
    local own = nest(CW, "BP_Infestation_C_2147600009", { X = 20000, Y = 0, Z = 0 }, 3, meshes.client.wall, meshes.client.wall)
    local placed = new(CW, { "BP_Infestation_Floor_C", "BP_Infestation_C" }, "BP_Infestation_Floor_C_9", { Role = 3 })
    WORLD = CW; C.world._t.client_only_pass()
    check(own._valid == false, "client-made random nest removed")
    check(cnest._valid and cnest2._valid and placed._valid, "host copies and placed nests kept")
end

print("== 17b. hordes of nests and POI spawns are the host's")
do
    WORLD = CW
    local cnestp = new(CW, { "BP_PrimaryInfestation_C", "BP_Infestation_C" }, "BP_PrimaryInfestation_C_7", { Role = 3 })
    local horde = new(CW, { "BlueprintGeneratedClass" }, "BP_Zombie_Infected_Horde_C", {}, {}, "/Game/AI/Zombies/BP_Zombie_Infected_Horde.BP_Zombie_Infected_Horde_C")
    local marker = new(CW, { "BlueprintGeneratedClass" }, "BP_Marker_C", {}, {}, "/Game/Blueprints/BP_Marker.BP_Marker_C")
    local hp1, mp1 = param(horde), param(marker)
    fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cnestp), hp1, param({}))
    fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cnestp), mp1, param({}))
    check(hp1._v()._name == "Object", "client nest's own horde wave blocked")
    check(mp1._v() == marker, "its map marker still made")
    local cpoi = new(CW, { "BP_POIManager_C" }, "BP_POIManager_C_44", { Role = 3 })
    local crate_cls = new(CW, { "BlueprintGeneratedClass" }, "Container_POICrate_C", {}, {}, "/Game/Inventory/Containers/Container_POICrate.Container_POICrate_C")
    local pc1 = param(crate_cls)
    fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cpoi), pc1, param({}))
    check(pc1._v()._name == "Object" and cpoi._valid, "client POI's own crate / boss blocked, the POI stays")
    WORLD = HW
    local hnestp = new(HW, { "BP_PrimaryInfestation_C", "BP_Infestation_C" }, "BP_PrimaryInfestation_C_7", { Role = 3 })
    local hhorde = new(HW, { "BlueprintGeneratedClass" }, "BP_Zombie_Infected_Horde_C", {}, {}, "/Game/AI/Zombies/BP_Zombie_Infected_Horde.BP_Zombie_Infected_Horde_C")
    local hp2 = param(hhorde)
    fire(HW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(hnestp), hp2, param({}))
    check(hp2._v() == hhorde, "host nest's wave untouched")
end

print("== 18. world events: airdrops, jets, blood moon")
do
    local EM = "/Game/Blueprints/Events/BP_EventManager.BP_EventManager_C"
    WORLD = HW
    local hem = new(HW, { "BP_EventManager_C", "BP_EventMaster_C" }, "BP_EventManager_C_1", { BloodMoonChance = 5.0, Role = 3 }, {
        SetBloodMoon = function(self, v)
            self._calls[#self._calls + 1] = { "SetBloodMoon", v }
            fire(HW, EM .. ":SetBloodMoon", param(self), param(v))
        end })
    WORLD = CW
    local cem = new(CW, { "BP_EventManager_C", "BP_EventMaster_C" }, "BP_EventManager_C_1", { BloodMoonChance = 5.0, Role = 3 }, {
        SetBloodMoon = function(self, v) self._calls[#self._calls + 1] = { "SetBloodMoon", v } end })
    -- the client's own plane / jet are not spawned
    local plane_cls = new(CW, { "BlueprintGeneratedClass" }, "AirdropAircraft_C", {}, {}, "/Game/Blueprints/Events/Airdrop/AirdropAircraft.AirdropAircraft_C")
    local pp = param(plane_cls)
    fire(CW, "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", param(nil), param(cem), pp, param({}))
    check(pp._v()._name == "Object", "client's own airdrop plane blocked")
    check(cem._valid == true, "its event manager stays")
    -- its blood moon roll goes off (the manager is looked up again at most every 10 s)
    C.world._t.events.next_try = 0
    advance(3); WORLD = CW; C.world.tick()
    check(cem._p.BloodMoonChance == 0, "client's own blood moon chance 0")
    -- the host's blood moon reaches it
    WORLD = HW; hem:SetBloodMoon(true)
    pump()
    local sb = called(cem, "SetBloodMoon")
    check(sb ~= nil and sb[2] == true, "host's blood moon rises on the client (SetBloodMoon)")
    local n = #cem._calls
    WORLD = CW; C.net.handlers["WBMOON"]({ "1" }, CW.pc)
    check(#cem._calls == n, "no second rise")
    WORLD = HW; hem:SetBloodMoon(false)
    pump()
    check(cem._calls[#cem._calls][1] == "SetBloodMoon" and cem._calls[#cem._calls][2] == false, "and ends with the host's")
    -- the host's jets are seen by every client
    WORLD = HW
    local jet = new(HW, { "BP_Event_JetActor_C" }, "BP_Event_JetActor_C_2147500100", { Role = 3, bReplicates = true }, { ForceNetUpdate = rec("ForceNetUpdate") })
    for _, x in ipairs(HW.watch or {}) do if x.path == "/Game/Blueprints/Events/Jet/BP_Event_JetActor.BP_Event_JetActor_C" then assert(x.fn(jet) == nil) end end
    H.world.tick()
    check(jet._p.bAlwaysRelevant == true, "host jet always relevant")
    -- a client-made plane / crate goes, the host's replicated ones stay
    WORLD = CW
    local own_plane = new(CW, { "AirdropAircraft_C" }, "AirdropAircraft_C_2147600200", { Role = 3 })
    local own_crate = new(CW, { "AirdropContainer_Supplies_C", "Master_AirdropContainer_C" }, "AirdropContainer_Supplies_C_2147600201", { Role = 3 })
    local host_crate = new(CW, { "AirdropContainer_Supplies_C", "Master_AirdropContainer_C" }, "AirdropContainer_Supplies_C_2147600202", { Role = 1 })
    C.world._t.client_only_pass()
    check(own_plane._valid == false and own_crate._valid == false, "client-made airdrop plane / crate removed")
    check(host_crate._valid == true, "host's airdrop crate kept")
end

print("== 9. snapshot")
CS.client.world_since = nil
for _, m in ipairs(CW.outbox) do print("  (pending before snapshot: " .. m .. ")") end
CW.outbox = {}; WORLD = CW; C.world.reset("mock: ask again")
WORLD = CW; C.world.tick(); advance(4); C.world.tick(); advance(4); C.world.tick()
for _, m in ipairs(CW.outbox) do print("  (outbox: " .. m .. ")") end
check(#CW.outbox == 1 and CW.outbox[1]:find("WHI", 1, true) ~= nil, "client asked for the snapshot")
deliver(); run_timers(HW)
local snap_msgs, snap_max = 0, 0
for _ = 1, 20 do
    WORLD = HW; H.world.tick()
    snap_max = math.max(snap_max, #HW.outbox); snap_msgs = snap_msgs + #HW.outbox
    deliver()
end
check(snap_msgs > 0 and snap_max <= 3, "snapshot sent through the queue (" .. snap_msgs .. " msgs, max " .. snap_max .. " per tick)")
WORLD = HW
print(H.world.status_line())
WORLD = CW
print(C.world.status_line())

-- ===========================================================================
-- 2026-11-13 log review (0.8.1), world group
-- ===========================================================================
local review_lines = {}
for _, m in ipairs({ H, C }) do
    for _, lv in ipairs({ "info", "warn", "debug" }) do
        local f0 = m.log[lv]
        m.log[lv] = function(msg, ...)
            local ok, s = pcall(string.format, msg, ...)
            review_lines[#review_lines + 1] = ok and s or tostring(msg)
            return f0(msg, ...)
        end
    end
end
local function nlogged(pat)
    local n = 0
    for _, s in ipairs(review_lines) do if s:find(pat, 1, true) then n = n + 1 end end
    return n
end

print("== 19. a client's camp AI volume: switched off at its first blocked spawn")
do
    WORLD = CW
    local SPAWN_AI = "/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass"
    local function tarray(items, broken)
        return { _items = items, Empty = function(self)
            if broken then error("Empty: no such method") end
            self._items = {}
        end }
    end
    local function camp_volume(w, name, broken)
        WORLD = w
        return new(w, { "BP_AISpawningVolume_Prefab_C" }, name, {
            Role = 3, ["Enable Spawn AI"] = true, ["Respawn AI"] = true, ["Spawn Retries"] = 5,
            ["Remaining Spawning AI"] = tarray({ { SpawnCount = 3 } }, broken),
            ["Spawning AI"] = tarray({ { SpawnCount = 3 } }, broken) })
    end
    -- the volume's own loop (BP_AISpawningVolume_Prefab): every Spawn Time a
    -- Spawn Location Trace while Remaining Spawning AI has entries (@98),
    -- Spawn Retries + 1 tries in it (@142); a failed spawn leaves the list as
    -- it was (@3168 only after a spawn), Restart Spawning starts over
    local function run_volume(w, vol, rounds)
        local calls = 0
        for _ = 1, rounds do
            if #vol._p["Remaining Spawning AI"]._items == 0 then break end   -- the loop @2908 ends
            local tries = 0
            while tries <= vol._p["Spawn Retries"] do
                local cp = param(bandit)
                fire(w, SPAWN_AI, param(nil), param(vol), cp)
                calls = calls + 1
                if cp._v() == bandit then break end   -- spawned (not blocked)
                tries = tries + 1
            end
        end
        return calls
    end
    local st = C.world.stats
    local s0, a0, b0 = st.prefab_ai_stopped, st.prefab_ai_again, st.prefab_ai_blocked
    local vol = camp_volume(CW, "BP_AISpawningVolume_Prefab_C_2147473800")
    local calls = run_volume(CW, vol, 30)
    check(calls == 1, "30 rounds of the volume's loop: one blocked spawn, then none (" .. calls .. " SpawnAIFromClass calls; 180 before)")
    check(vol._p["Spawn Retries"] == -1 and vol._p["Enable Spawn AI"] == false and vol._p["Respawn AI"] == false,
        "switched off its own way (Spawn Retries -1, Enable Spawn AI / Respawn AI false)")
    check(#vol._p["Remaining Spawning AI"]._items == 0 and #vol._p["Spawning AI"]._items == 0, "both spawn lists emptied")
    check(st.prefab_ai_stopped - s0 == 1 and st.prefab_ai_again == a0 and st.prefab_ai_blocked - b0 == 1,
        "counted: 1 blocked, 1 switched off, 0 again")
    check(nlogged("camp AI volume BP_AISpawningVolume_Prefab_C_2147473800 switched off on this client (3/3 settings, 2/2 spawn lists emptied)") == 1,
        "logged once, with what was set")
    -- lists that cannot be emptied: Spawn Retries -1 alone ends the tries
    local vol2 = camp_volume(CW, "BP_AISpawningVolume_Prefab_C_2147473801", true)
    calls = run_volume(CW, vol2, 30)
    check(calls == 1, "lists not emptied: still one call in 30 rounds (" .. calls .. ")")
    check(nlogged("BP_AISpawningVolume_Prefab_C_2147473801 switched off on this client (3/3 settings, 0/2 spawn lists emptied)") == 1,
        "the log says the lists stayed")
    -- the camp's copy made again (it came back in range): a new volume at the old address
    local vol3 = camp_volume(CW, "BP_AISpawningVolume_Prefab_C_2147473802")
    vol3._addr = vol._addr
    calls = run_volume(CW, vol3, 30)
    check(calls == 1 and vol3._p["Spawn Retries"] == -1, "a new volume at the old address is switched off too (" .. calls .. ")")
    -- a volume whose settings cannot be written: the loop goes on, counted as "again", warned once
    local vol4 = camp_volume(CW, "BP_AISpawningVolume_Prefab_C_2147473803", true)
    vol4.SetPropertyValue = function() error("SetPropertyValue failed") end
    calls = run_volume(CW, vol4, 3)
    check(calls == 18, "settings not written: the loop goes on (" .. calls .. " calls in 3 rounds)")
    check(st.prefab_ai_again - a0 == 17, "17 spawns blocked again after the switch-off (" .. (st.prefab_ai_again - a0) .. ")")
    check(nlogged("camp AI volume BP_AISpawningVolume_Prefab_C_2147473803 still tries to spawn after it was switched off") == 1,
        "warned once for that volume")
    check(nlogged("BP_AISpawningVolume_Prefab_C_2147473803 switched off on this client (0/3 settings") == 1, "its switch-off line says 0/3")
    -- [PERF] world: the window's counts, on the client's tick
    WORLD = CW
    C.world.tick()
    advance(61)
    C.world.tick()
    local perf = nil
    for _, s in ipairs(review_lines) do if s:find("[PERF] world", 1, true) then perf = s end end
    check(perf ~= nil and perf:find("camp AI spawns blocked on this client", 1, true) ~= nil
        and perf:find("blocked again after a switch-off 17", 1, true) ~= nil,
        "[PERF] world line with the blocked spawns - " .. tostring(perf))
    local nperf = nlogged("[PERF] world")
    advance(61)
    C.world.tick()
    check(nlogged("[PERF] world") == nperf, "a window without blocked spawns: no [PERF] world line")
    check(C.world.status_line():find("camp AI volumes switched off=", 1, true) ~= nil, "status line: volumes switched off")
    -- the host's own camp volume spawns its bandits as before
    local hvol = camp_volume(HW, "BP_AISpawningVolume_Prefab_C_2147473900")
    local hcp = param(bandit)
    fire(HW, SPAWN_AI, param(nil), param(hvol), hcp)
    check(hcp._v() == bandit and hvol._p["Spawn Retries"] == 5 and hvol._p["Enable Spawn AI"] == true
        and #hvol._p["Remaining Spawning AI"]._items == 1, "host: its camp volume untouched")
end

print("== 20. a client's door on the host: no echo back to it, the other clients told once")
do
    local DOOR_EV = "/Game/Blueprints/Other/Doors/BP_LockedDoor.BP_LockedDoor_C:Event_Door"
    local DIR = "Timeline_OpenDoor__Direction_CA4B83EF45872B61E7779EAD32D6380C"
    local other = {}
    WORLD = HW
    local conn2 = new(HW, { "IpConnection" }, "IpConnection_2")
    local rpc2 = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_2",
        { NetConnection = conn2, Player = conn2 }, { ClientMessage = function(self, msg) other[#other + 1] = msg end })
    HS.remote_pcs = { rpc, rpc2 }
    local function door(w)
        WORLD = w
        local tl = new(w, { "TimelineComponent" }, "TL12_" .. w.id, {}, { IsPlaying = function(self) return self._playing == true end })
        return new(w, { "BP_LockedDoor_C", "BP_LockPickObject_C" }, "BP_LockedDoor_C_12",
            { ["Closed?"] = true, ["IsLocked?"] = true, Timeline_OpenDoor = tl, [DIR] = 0 },
            { Event_Door = function(self)
                self._calls[#self._calls + 1] = { "Event_Door" }
                if w == CW then
                    tl._playing = true
                    self._p[DIR] = self._p["Closed?"] and 0 or 1
                    fire(w, DOOR_EV, param(self))
                else
                    -- the host as on 2026-11-13: inside the call the door still reads closed
                    fire(w, DOOR_EV, param(self))
                    tl._playing = true
                    self._p[DIR] = self._p["Closed?"] and 0 or 1
                end
            end })
    end
    local hd = door(HW)
    local cd = door(CW)
    local function host_out()
        local out = {}
        for _ = 1, 6 do
            WORLD = HW; H.world.tick()
            for _, m in ipairs(HW.outbox) do out[#out + 1] = m end
            HW.outbox = {}
        end
        return out
    end
    local function doors_in(list)
        local n, last = 0, nil
        for _, m in ipairs(list) do
            if m:find("WDOOR", 1, true) and m:find("BP_LockedDoor_C_12", 1, true) then n, last = n + 1, m end
        end
        return n, last
    end
    host_out()
    -- the client picked the lock and opens the door
    WORLD = CW
    cd._p["IsLocked?"] = false
    cd:Event_Door()
    local sent = CW.outbox
    CW.outbox = {}
    check(#sent == 1 and sent[1]:find("BP_LockedDoor_C_12", 1, true) ~= nil, "client sent its door")
    WORLD = HW
    for _, msg in ipairs(sent) do
        local kind, f = H.net.decode(msg)
        H.net.handlers[kind](f, rpc)
    end
    check(called(hd, "Event_Door") ~= nil and hd._p["IsLocked?"] == false, "host door opened and unlocked")
    local back = host_out()
    local nb = doors_in(back)
    check(nb == 0, "nothing back to the client that opened it (" .. nb .. " WDOOR)")
    local no, last = doors_in(other)
    check(no == 1 and last:find("|d|o|u", 1, true) ~= nil, "the other client told once: open, unlocked (" .. no .. ": " .. tostring(last) .. ")")
    check(H.world._t.locks.door_in == nil, "no door left marked as applied")
    -- the host's own use of the door still goes to every client
    other = {}
    WORLD = HW
    hd:Event_Door()
    local mine = host_out()
    local n1 = doors_in(mine)
    local n2 = doors_in(other)
    check(n1 == 1 and n2 == 1, "the host's own door use: each client told once (" .. n1 .. ", " .. n2 .. ")")
    HS.remote_pcs = { rpc }
end

print("== 21. a client-only camp destroyed once, not again every pass until the GC")
do
    WORLD = CW
    local camp = new(CW, { "Alternate_ZombiesObservatory_C", "PrefabMaster_C" }, "Alternate_ZombiesObservatory_C_2147473700", { Role = 3 })
    local destroys = 0
    -- the engine marks it for removal; FindAllOf and IsValid still see it until the GC
    camp.K2_DestroyActor = function() destroys = destroys + 1 end
    local r0 = C.world.stats.prefab_removed
    for _ = 1, 12 do advance(5); WORLD = CW; C.world._t.client_only_pass() end
    check(destroys == 1, "destroyed once in a minute of passes (" .. destroys .. ")")
    check(C.world.stats.prefab_removed - r0 == 1, "counted once (" .. (C.world.stats.prefab_removed - r0) .. ")")
    check(nlogged("removed client-only Alternate_ZombiesObservatory_C_2147473700") == 1, "logged once")
    -- the GC took it; another client-only camp gets the same address: removed
    camp._valid = false
    local camp2 = new(CW, { "Alternate_ZombiesObservatory_C", "PrefabMaster_C" }, "Alternate_ZombiesObservatory_C_2147473500", { Role = 3 })
    camp2._addr = camp._addr
    advance(5); C.world._t.client_only_pass()
    check(camp2._valid == false, "a new client-only camp at the freed address is removed")
end

print("== 22. a locked door's move as the game made it (Closed?), not the timeline's lagging Direction")
do
    local DOOR_EV = "/Game/Blueprints/Other/Doors/BP_LockedDoor.BP_LockedDoor_C:Event_Door"
    local DIR = "Timeline_OpenDoor__Direction_CA4B83EF45872B61E7779EAD32D6380C"
    local other = {}
    WORLD = HW
    local conn3 = new(HW, { "IpConnection" }, "IpConnection_3")
    local rpc3 = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_3",
        { NetConnection = conn3, Player = conn3 }, { ClientMessage = function(self, msg) other[#other + 1] = msg end })
    HS.remote_pcs = { rpc, rpc3 }
    -- BP_LockedDoor and its TimelineComponent as the engine runs them:
    -- Event_Door @4256: PlayFromStart if Closed?, else ReverseFromEnd. FTimeline's
    -- PlayFromStart / ReverseFromEnd: SetPlaybackPosition (writes the owner's
    -- Direction from the previous move), then Play / Reverse (bReversePlayback,
    -- IsReversing). Each tick writes the move's Direction; at the end the
    -- finished function @4587 sets Closed? from it. pre: the hook runs before
    -- the body (its timing is not what the sent move depends on).
    local function real_door(w, name, pre)
        WORLD = w
        local d
        local tl = new(w, { "TimelineComponent" }, "TL_" .. name .. "_" .. w.id, {}, {
            IsPlaying = function(self) return self._playing == true end,
            IsReversing = function(self) return self._rev == true end,
            PlayFromStart = function(self) d._p[DIR] = self._rev and 1 or 0; self._rev, self._playing = false, true end,
            ReverseFromEnd = function(self) d._p[DIR] = self._rev and 1 or 0; self._rev, self._playing = true, true end,
        })
        d = new(w, { "BP_LockedDoor_C", "BP_LockPickObject_C" }, name,
            { ["Closed?"] = true, ["IsLocked?"] = false, Timeline_OpenDoor = tl, [DIR] = 0 },
            { Event_Door = function(self)
                self._calls[#self._calls + 1] = { "Event_Door" }
                if pre then fire(w, DOOR_EV, param(self)) end
                if self._p["Closed?"] then tl:PlayFromStart() else tl:ReverseFromEnd() end
                if not pre then fire(w, DOOR_EV, param(self)) end
            end })
        return d
    end
    local function frame(d)    -- one tick of its timeline
        local tl = d._p.Timeline_OpenDoor
        if tl._playing then d._p[DIR] = tl._rev and 1 or 0 end
    end
    local function finish(d)   -- its timeline at the end
        local tl = d._p.Timeline_OpenDoor
        if not tl._playing then return end
        frame(d)
        tl._playing = false
        d._p["Closed?"] = d._p[DIR] ~= 0
    end
    local function truth(d)    -- what the door really does (test side)
        local tl = d._p.Timeline_OpenDoor
        if tl._playing then return tl._rev and "c" or "o" end
        return d._p["Closed?"] and "c" or "o"
    end
    local function host_sent(name)
        local out = {}
        for _ = 1, 6 do
            WORLD = HW; H.world.tick()
            for _, m in ipairs(HW.outbox) do
                if m:find("WDOOR", 1, true) and m:find(name, 1, true) then out[#out + 1] = m end
            end
            HW.outbox = {}
        end
        return out
    end
    local function others(name)
        local out = {}
        for _, m in ipairs(other) do
            if m:find("WDOOR", 1, true) and m:find(name, 1, true) then out[#out + 1] = m end
        end
        other = {}
        return out
    end
    local function to_client(list)
        WORLD = CW
        for _, msg in ipairs(list) do
            local kind, f = C.net.decode(msg)
            C.net.handlers[kind](f, CW.pc)
        end
    end
    local function says(list, want) return #list == 1 and list[1]:find("|d|" .. want .. "|", 1, true) ~= nil end
    local N = "BP_LockedDoor_C_14"
    local hd, cd = real_door(HW, N), real_door(CW, N)
    host_sent(N); others(N)
    -- the host opens, closes, opens, closes its own door; the client's follows
    for i, want in ipairs({ "o", "c", "o", "c" }) do
        WORLD = HW
        hd:Event_Door()
        local mine, them = host_sent(N), others(N)
        to_client(mine)
        check(says(mine, want) and says(them, want) and truth(hd) == want and truth(cd) == want,
            string.format("host's own press %d: \"%s\" to each client, the client's door follows (%s; client %s)",
                i, want, tostring(mine[1]), truth(cd)))
        finish(hd); finish(cd)
    end
    -- a press while it opens: the game opens it again, never "c" before it has opened
    WORLD = HW
    hd:Event_Door(); host_sent(N); others(N)
    frame(hd)
    hd:Event_Door()
    local again = host_sent(N)
    check(says(again, "o") and truth(hd) == "o", "a press while opening: \"o\" again (" .. tostring(again[1]) .. ")")
    to_client(again)
    finish(hd); finish(cd)
    hd:Event_Door(); to_client(host_sent(N)); others(N)
    finish(hd); finish(cd)
    check(truth(hd) == "c" and truth(cd) == "c", "both closed again")
    -- the client opens, then closes; the host follows silently, the other client is told
    for i, want in ipairs({ "o", "c" }) do
        WORLD = CW
        cd:Event_Door()
        local sent = CW.outbox
        CW.outbox = {}
        check(#sent == 1 and sent[1]:find("|d|" .. want .. "|", 1, true) ~= nil,
            string.format("client's press %d sends \"%s\" (%s)", i, want, tostring(sent[1])))
        WORLD = HW
        for _, msg in ipairs(sent) do
            local kind, f = H.net.decode(msg)
            H.net.handlers[kind](f, rpc)
        end
        local back, them = host_sent(N), others(N)
        check(#back == 0 and says(them, want) and truth(hd) == want,
            string.format("host door %s, nothing back, the other client told \"%s\" once (%d back, %s)",
                truth(hd), want, #back, tostring(them[1])))
        finish(hd); finish(cd)
    end
    -- the client's door applied twice in one frame (two "c" in a row): the
    -- second sees it closing and leaves it (Direction still said "open")
    WORLD = CW
    cd:Event_Door(); CW.outbox = {}
    finish(cd)
    WORLD = HW
    hd:Event_Door(); host_sent(N); others(N)
    finish(hd)
    local pk = H.world._t.pack(LVL .. N)
    local n0 = #cd._calls
    WORLD = CW
    C.net.handlers.WDOOR({ pk, "d", "c", "u" }, CW.pc)
    C.net.handlers.WDOOR({ pk, "d", "c", "u" }, CW.pc)
    check(#cd._calls - n0 == 1 and truth(cd) == "c", "two \"c\" in one frame: the client's door closed once ("
        .. (#cd._calls - n0) .. " Event_Door)")
    -- the hook run before the body: the same move goes out
    local N2 = "BP_LockedDoor_C_15"
    local hp = real_door(HW, N2, true)
    real_door(CW, N2, true)
    host_sent(N2); others(N2)
    for i, want in ipairs({ "o", "c" }) do
        WORLD = HW
        hp:Event_Door()
        local mine = host_sent(N2)
        others(N2)
        check(says(mine, want), string.format("hook before the body, press %d: \"%s\" (%s)", i, want, tostring(mine[1])))
        finish(hp)
    end
    HS.remote_pcs = { rpc }
end

print("== 23. a world reset forgets switched-off camp volumes and destroyed camps")
do
    WORLD = CW
    local SPAWN_AI = "/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass"
    local PFt = C.world._t.prefabs
    local st = C.world.stats
    local function list1() return { _items = { { SpawnCount = 3 } }, Empty = function(self) self._items = {} end } end
    local function vol_at(name, a)
        WORLD = CW
        local v = new(CW, { "BP_AISpawningVolume_Prefab_C" }, name, { Role = 3, ["Enable Spawn AI"] = true,
            ["Respawn AI"] = true, ["Spawn Retries"] = 5, ["Remaining Spawning AI"] = list1(), ["Spawning AI"] = list1() })
        if a then v._addr = a end
        return v
    end
    local VN = "BP_AISpawningVolume_Prefab_C_2147473810"
    local v1 = vol_at(VN)
    fire(CW, SPAWN_AI, param(nil), param(v1), param(bandit))
    check(v1._p["Spawn Retries"] == -1, "before the reset: the volume switched off")
    local camp = new(CW, { "Alternate_ZombiesObservatory_C", "PrefabMaster_C" }, "Alternate_ZombiesObservatory_C_2147473710", { Role = 3 })
    local destroys = 0
    camp.K2_DestroyActor = function() destroys = destroys + 1 end   -- findable until the GC
    advance(5); WORLD = CW; C.world._t.client_only_pass()
    check(destroys == 1, "before the reset: the camp destroyed once (" .. destroys .. ")")
    WORLD = CW
    C.world.reset("test: another world")
    check(next(PFt.vols) == nil and PFt.nvols == 0 and next(PFt.gone) == nil,
        "reset: no switched-off volume and no destroyed camp remembered")
    -- the next world's actors at the same address and name: handled anew
    v1._valid = false
    local v2 = vol_at(VN, v1._addr)
    local s0, a0 = st.prefab_ai_stopped, st.prefab_ai_again
    fire(CW, SPAWN_AI, param(nil), param(v2), param(bandit))
    check(v2._p["Spawn Retries"] == -1 and st.prefab_ai_stopped - s0 == 1 and st.prefab_ai_again == a0,
        "after the reset: a volume with the old address and name is switched off, not counted as \"again\"")
    advance(5); WORLD = CW; C.world._t.client_only_pass()
    check(destroys == 2, "after the reset: a camp with the old address and name is removed (" .. destroys .. ")")
    camp._valid = false
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
