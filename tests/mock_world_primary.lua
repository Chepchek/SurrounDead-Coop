-- Mock harness: a primary infestation is locked until its secondaries are down, on
-- the host and the client alike (sdc_world IX): host kills, client kills, join, refused hits.
-- usage: lua mock_world_primary.lua <scripts dir>
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
-- Primary infestations locked until their secondaries are down (sdc_world IX, 0.6.74)
-- ===========================================================================
local INF = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
local FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C"
local NOTE = "Secondary Infestations Not Destroyed In Surrounding Area."
-- SecondaryInfestations as a TArray (Empty())
local LIST_MT = { __index = { Empty = function(t) for k = #t, 1, -1 do t[k] = nil end end } }

for _, w in ipairs({ HW, CW }) do
    WORLD = w
    w.notes = {}
    new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(self, text) w.notes[#w.notes + 1] = type(text) == "string" and text or text:ToString() end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
end

-- one area on a machine: a primary and its secondaries, as BP_Infestation runs them there
local function area(w, tag, nsec)
    WORLD = w
    local a = { sec = {} }
    local function nest(name, primary)
        local n
        local dc = new(w, { "DamageComponent_C" }, name .. "_DC", { CurrentHealth = 100 }, {
            -- the death (@7817): its own InfestationDestroyed broadcast -> its Event_OnDestroyed and the primary's Event_SecondaryDestroyed
            DamageTaken = function(self, dmg, typ, causer)
                self._p.CurrentHealth = self._p.CurrentHealth - dmg
                if self._p.CurrentHealth <= 0 and not n._p["IsDestroyed?"] then
                    n:Event_OnDestroyed(causer, false)
                    if not primary and a.primary then a.primary:Event_SecondaryDestroyed(causer, false) end
                end
            end,
        })
        n = new(w, primary and { "BP_PrimaryInfestation_C", "BP_Infestation_C" } or { "BP_Infestation_C" }, name,
            { ["IsDestroyed?"] = false, ["PrimaryInfestation?"] = primary, ["CanDamagePrimary?"] = false, DamageComponent = dc,
              _loc = { X = 1000, Y = 0, Z = 0 } }, {
            -- the event itself (the load path calls it directly: no broadcast)
            Event_OnDestroyed = function(self, causer, load)
                if self._p["IsDestroyed?"] then return end
                self._p["IsDestroyed?"] = true
                -- a primary's load path (@9752 -> @9688 -> @3573-3735, @9713): its secondaries go, the list is emptied
                if load and primary then
                    for _, s in ipairs(self._p.SecondaryInfestations) do if s._valid then s:K2_DestroyActor() end end
                    self._p.SecondaryInfestations = setmetatable({}, LIST_MT)
                end
                fire(w, INF .. ":Event_OnDestroyed", param(self), param(causer), param(load))
            end,
            -- @11379: AreSecondariesDestroyed? -> CanDamagePrimary?, the blast when not from a load
            Event_SecondaryDestroyed = function(self, causer, load)
                self._calls[#self._calls + 1] = { "Event_SecondaryDestroyed", causer, load }
                for _, s in ipairs(self._p.SecondaryInfestations) do if not s._p["IsDestroyed?"] then return end end
                self._p["CanDamagePrimary?"] = true
                if not load then self._blast = (self._blast or 0) + 1 end
            end,
            -- @7847-7946
            Damage_Object = function(self, dmg, causer, inst)
                self._calls[#self._calls + 1] = { "Damage_Object", dmg }
                if not self._p["IsDestroyed?"] then
                    if not primary or self._p["CanDamagePrimary?"] then dc:DamageTaken(dmg, nil, causer)
                    else w.paths["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"]:CreateNotificationUI(NOTE) end
                end
                fire(w, INF .. ":Damage_Object", param(self), param(dmg), param(causer), param(inst))
            end,
        })
        return n
    end
    for k = 1, nsec do a.sec[k] = nest("BP_Infestation_C_" .. tag .. k, false) end
    a.primary = nest("BP_PrimaryInfestation_C_" .. tag, true)
    a.primary._p.SecondaryInfestations = setmetatable({ table.unpack(a.sec) }, LIST_MT)
    return a
end

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
local function pump() for _ = 1, 10 do advance(0.25); WORLD = HW; H.world.tick(); deliver() end; settle() end
local function sent(w, kind) local n = 0 for _, m in ipairs(w.outbox) do if m:find("|" .. kind .. "|", 1, true) then n = n + 1 end end return n end
local cgun = new(CW, { "BP_M4Pickup_C", "BP_FirearmPickup_C" }, "BP_M4Pickup_C_78", { _owner = CW.pawn })
local function client_shot(o, dmg)
    WORLD = CW
    o:Damage_Object(dmg, CW.pawn, nil)
    fire(CW, FIREARM .. ":Trace_Impact", param(cgun))
end
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
pump()

print("== Y1. the host destroys the secondaries: the client's primary unlocks the game's way")
local HA, CA = area(HW, "A", 2), area(CW, "A", 2)
WORLD = HW
for k = 1, 2 do HA.sec[k]._p.DamageComponent:DamageTaken(500, nil, HW.pawn) end
check(HA.primary._p["CanDamagePrimary?"] == true, "(the host's primary: unlocked by its secondaries' deaths)")
check(sent(HW, "WINF") == 2, "both deaths sent")
pump()
check(CA.sec[1]._p["IsDestroyed?"] and CA.sec[2]._p["IsDestroyed?"], "(the client's copies died by the load path)")
check(CA.primary._p["CanDamagePrimary?"] == true, "the client's primary can be damaged now")
local es = called(CA.primary, "Event_SecondaryDestroyed")
check(es ~= nil and es[3] == false and CA.primary._blast == 1, "by the game's Event_SecondaryDestroyed, live: with its blast")

print("== Y2. the client's hit on it now goes through on both")
client_shot(CA.primary, 30)
check(CA.primary._p.DamageComponent._p.CurrentHealth == 70 and not (CW.notes[#CW.notes] == NOTE), "the client's copy takes it (no note)")
check(sent(CW, "WDMG") == 1, "and the hit goes to the host")
pump()
check(HA.primary._p.DamageComponent._p.CurrentHealth == 70, "the host's primary takes it too")

print("== Y3. only one secondary down: still locked on both, and a refused hit stays refused")
local HB, CB = area(HW, "B", 2), area(CW, "B", 2)
WORLD = HW; HB.sec[1]._p.DamageComponent:DamageTaken(500, nil, HW.pawn)
pump()
check(CB.primary._p["CanDamagePrimary?"] == false and HB.primary._p["CanDamagePrimary?"] == false, "one of two down: locked on both")
CW.notes = {}
client_shot(CB.primary, 30)
check(CW.notes[1] == NOTE, "the client sees the game's note")
check(sent(CW, "WDMG") == 0, "its refused hit is not sent")
pump()
check(HB.primary._p.DamageComponent._p.CurrentHealth == 100, "the host's primary took nothing")

print("== Y4. a hit reaching the host while its primary is still locked: no note on the host's screen")
HW.notes = {}
WORLD = HW; H.net.handlers.WDMG({ "~LongdownValley~BP_PrimaryInfestation_C_B", "30" }, rpc)
check(#HW.notes == 0 and called(HB.primary, "Damage_Object") == nil, "not applied on the host (it would show the note there)")

print("== Y5. a client joining later gets the unlocked primary (no blast: as a load)")
local HC, CC = area(HW, "C", 3), area(CW, "C", 3)
WORLD = HW
for k = 1, 3 do HC.sec[k]._p.DamageComponent:DamageTaken(500, nil, HW.pawn) end
HW.outbox = {}   -- (the client was not here yet)
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 30 do WORLD = HW; H.world.tick(); deliver() end
check(CC.primary._p["CanDamagePrimary?"] == true, "the joiner's primary can be damaged")
local es5 = called(CC.primary, "Event_SecondaryDestroyed")
check(es5 ~= nil and es5[3] == true and not CC.primary._blast, "as a load (no blast)")

print("== Y6. the client destroys the secondaries: both primaries unlock")
local HD, CD = area(HW, "D", 2), area(CW, "D", 2)
for k = 1, 2 do
    WORLD = CW
    CD.sec[k]._p.DamageComponent:DamageTaken(500, nil, CW.pawn)   -- its own kill: its own broadcast
end
check(CD.primary._p["CanDamagePrimary?"] == true, "the client's own primary (its own broadcast)")
pump()
check(HD.sec[1]._p["IsDestroyed?"] and HD.sec[2]._p["IsDestroyed?"] and HD.primary._p["CanDamagePrimary?"] == true,
    "the host's secondaries died for that player and its primary unlocked")

print("== Y8. the host destroys a primary: the client's secondaries stay (the wrecks and their loot), as on the host")
HW.outbox = {}
WORLD = HW; HA.primary._p.DamageComponent:DamageTaken(500, nil, HW.pawn)
check(HA.primary._p["IsDestroyed?"] == true and HA.sec[1]._valid and HA.sec[2]._valid,
    "(the host's primary died live: its secondaries stand there)")
check(sent(HW, "WINF") == 1, "its death sent")
pump()
check(CA.primary._p["IsDestroyed?"] == true, "the client's primary died by the load path")
check(CA.sec[1]._valid and CA.sec[2]._valid and CA.sec[1]._p["IsDestroyed?"] and CA.sec[2]._p["IsDestroyed?"],
    "its secondaries are still there, destroyed (the load path did not remove them)")

-- a snapshot to a joiner, counting the WINF messages of one primary with flag fl
local function join_snapshot(name, fl)
    HW.outbox = {}   -- (the client was not here yet)
    WORLD = HW; H.world._t.snapshot(rpc)
    local n = 0
    for _ = 1, 30 do
        WORLD = HW; H.world.tick()
        for _, m in ipairs(HW.outbox) do if m:find("|WINF|", 1, true) and m:find(name .. "|" .. fl, 1, true) then n = n + 1 end end
        deliver()
    end
    return n
end

print("== Y9. a joiner after the host's live kill of a primary (same run): its secondaries stay there too, as on the host")
local HE, CE = area(HW, "E", 2), area(CW, "E", 2)
WORLD = HW
for k = 1, 2 do HE.sec[k]._p.DamageComponent:DamageTaken(500, nil, HW.pawn) end
HE.primary._p.DamageComponent:DamageTaken(500, nil, HW.pawn)
check(HE.sec[1]._valid and HE.sec[2]._valid, "(the host's secondaries stand there)")
check(join_snapshot("BP_PrimaryInfestation_C_E", "s") == 1, "the primary sent as one whose secondaries the host still has (s)")
check(CE.primary._p["IsDestroyed?"] == true, "the joiner's primary destroyed (load path)")
check(CE.sec[1]._valid and CE.sec[2]._valid and CE.sec[1]._p["IsDestroyed?"] and CE.sec[2]._p["IsDestroyed?"],
    "the joiner's secondaries are still there, destroyed (as on the host)")

print("== Y10. a joiner when the host loaded the primary destroyed: the game's load result on both")
local HF, CF = area(HW, "F", 2), area(CW, "F", 2)
WORLD = HW
for k = 1, 2 do HF.sec[k]:Event_OnDestroyed(nil, true) end
HF.primary:Event_OnDestroyed(nil, true)   -- the host's own load: its secondaries removed there
check(not HF.sec[1]._valid and not HF.sec[2]._valid, "(the host's load removed its secondaries)")
check(join_snapshot("BP_PrimaryInfestation_C_F", "s") == 0, "no s for it")
check(CF.primary._p["IsDestroyed?"] == true and not CF.sec[1]._valid and not CF.sec[2]._valid,
    "the joiner's primary removed its secondaries too (as on the host)")

print("== Y7. status")
WORLD = CW; local sl = C.world.status_line(); print(sl)
check(sl:find("primaries unlocked=", 1, true) ~= nil, "status: primaries unlocked=N")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
