-- Mock harness: the searched state of loot containers between host and client
-- (sdc_world world_containers), above all the camps' / POIs' containers
-- (PrefabMaster child actors, runtime-spawned on the host and replicated with
-- another name on the client). 0.7.0: the WLOOT / WLOOTS / WLOOTR sync named
-- containers by level path only (level_actor), so a camp chest the host
-- searched was unsearched on the client and the other way round: both searched
-- the same chests (host log 16:47-16:50: four host searches and five client
-- opens in one bandit camp, no WLOOT either way).
-- usage: lua mock_world_lootsync.lua <scripts dir>
-- (harness core copied from mock_world.lua / mock_world_crates.lua)
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
local find_all_calls = {}
FindAllOf = function(cls)
    find_all_calls[cls] = (find_all_calls[cls] or 0) + 1
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

-- NotifyOnNewObject: the engine constructed `o` (its class or a parent watched)
local function notify(w, o)
    WORLD = w
    local n = 0
    for _, x in ipairs(w.watch or {}) do
        local cls = x.path:match("%.([%w_]+)$")
        if cls and derives(o, cls) then
            local r = x.fn(o)
            assert(r == nil, "new-object callback returned a value (true would cancel it): " .. x.path)
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
end
local HW, CW = world("host"), world("client")

local function engine(w, is_server)
    WORLD = w
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    w.sounds = {}
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        PlaySoundAtLocation = function(_, wco, snd) w.sounds[#w.sounds + 1] = { snd = snd, at = wco } end,
        GetCurrentLevelName = function() return "LongdownValley" end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
    w.hearing = new(w, { "AISense_Hearing" }, "Hearing", {}, { ReportNoiseEvent = rec("ReportNoiseEvent") },
        "/Script/AIModule.Default__AISense_Hearing")
    new(w, { "SoundCue" }, "BreakOpen_Cue", {}, {}, "/Game/Audio/BreakOpen_Cue.BreakOpen_Cue")
end
engine(HW, true)
engine(CW, false)

local function players(w)
    WORLD = w
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local jig = new(w, { "BP_JigComponent_C" }, "BP_JigMultiplayer_0", {}, {})
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 16661, Y = 74430, Z = 1540 }, _local = true, BP_JigMultiplayer = jig })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
players(HW)
players(CW)

-- the remote player's controller and character on the host
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_2147466856",
    { _loc = { X = 16868, Y = 74481, Z = 1540 } })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_2147466895",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- containers
local LOOT_CHAIN = function(cls) return { cls, "BP_LootContainer_C", "BP_MasterObject_C" } end
local PICK_CHAIN = function(cls) return { cls, "BP_MASTER_PicklockContainer_C", "BP_LockPickObject_C", "BP_MasterObject_C" } end

-- a loot container as the game has it: ContainerLooted on the box, Looted? on
-- its BP_JigMultiplayer; Bind_Refill clears the box's flag (@2812)
local function box(w, chain, name, loc, extra)
    WORLD = w
    local comp = new(w, { "BP_JigComponent_C" }, name .. ".BP_JigMultiplayer", { ["Looted?"] = false },
        { StartRefillTimer = rec("StartRefillTimer") })
    local p = { ContainerLooted = false, BP_JigMultiplayer = comp, _loc = { X = loc.X, Y = loc.Y, Z = loc.Z } }
    for k, v in pairs(extra or {}) do p[k] = v end
    return new(w, chain, name, p, {
        Bind_Refill = function(self) self._p.ContainerLooted = false; self._calls[#self._calls + 1] = { "Bind_Refill" } end,
    })
end
local function off(l, dx, dy, dz) return { X = l.X + dx, Y = l.Y + dy, Z = l.Z + dz } end

-- a placed level box (same path on both machines)
local L_TRASH = { X = 1000, Y = 2000, Z = 300 }
local hlevel = box(HW, LOOT_CHAIN("Container_RandomLoot_TrashBag_C"), "Container_RandomLoot_TrashBag_C_93", L_TRASH)
local clevel = box(CW, LOOT_CHAIN("Container_RandomLoot_TrashBag_C"), "Container_RandomLoot_TrashBag_C_93", L_TRASH)

-- the bandit camp of the 16:47 log (Prefab_LargeBanditCamp2): the host's
-- children by their ChildActor names; the client's replicated copies have
-- their own names and the host's place to < 1 cm (spawn quantization)
local FUEL = { X = 16702.37, Y = 74120.66, Z = 1540.0 }
local SUPPLY = { X = 16910.12, Y = 74811.49, Z = 1540.5 }
local AMMO_A = { X = 16450.0, Y = 73390.0, Z = 1541.0 }
local AMMO_B = { X = 16510.0, Y = 73390.0, Z = 1541.0 }   -- the same class 60 cm away
local LOCKER = { X = 17100.0, Y = 74000.0, Z = 1540.0 }
local CAMP = {
    { cls = "Container_FuelLoot_FuelTank_C", h = "ChildActor8_GEN_VARIABLE_Container_FuelLoot_FuelTank_C_CAT_2147475779",
      c = "Container_FuelLoot_FuelTank_C_2147480011", loc = FUEL },
    { cls = "Container_MlitaryLoot_MilitarySupplies_C",
      h = "ChildActor4_GEN_VARIABLE_Container_MlitaryLoot_MilitarySupplies_C_CAT_2147475783",
      c = "Container_MlitaryLoot_MilitarySupplies_C_2147480012", loc = SUPPLY },
    { cls = "Container_AmmoLoot_AmmoCrate_C", h = "ChildActor6_GEN_VARIABLE_Container_AmmoLoot_AmmoCrate_C_CAT_2147475781",
      c = "Container_AmmoLoot_AmmoCrate_C_2147480013", loc = AMMO_A },
    { cls = "Container_AmmoLoot_AmmoCrate_C", h = "ChildActor9_GEN_VARIABLE_Container_AmmoLoot_AmmoCrate_C_CAT_2147475778",
      c = "Container_AmmoLoot_AmmoCrate_C_2147480014", loc = AMMO_B },
}
local H_, C_ = {}, {}
for i, e in ipairs(CAMP) do
    H_[i] = box(HW, LOOT_CHAIN(e.cls), e.h, e.loc, { Role = 3, bReplicates = true })
    C_[i] = box(CW, LOOT_CHAIN(e.cls), e.c, off(e.loc, 0.4, -0.3, 0.05), { Role = 1 })
end
local hfuel, hsupply, hammo_a, hammo_b = H_[1], H_[2], H_[3], H_[4]
local cfuel, csupply, cammo_a, cammo_b = C_[1], C_[2], C_[3], C_[4]
local hlocker = box(HW, PICK_CHAIN("PicklockContainer_MilitaryLocker_C"),
    "ChildActor2_GEN_VARIABLE_PicklockContainer_MilitaryLocker_C_CAT_2147475785", LOCKER, { Role = 3, ["IsLocked?"] = true })
local clocker = box(CW, PICK_CHAIN("PicklockContainer_MilitaryLocker_C"), "PicklockContainer_MilitaryLocker_C_2147480015",
    off(LOCKER, -0.2, 0.3, 0), { Role = 1, ["IsLocked?"] = true })

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
local function outbox_has(w, needle)
    for _, m in ipairs(w.outbox) do if m:find(needle, 1, true) then return m end end
    return nil
end
local function searched(o) return o._p.ContainerLooted == true and o._p.BP_JigMultiplayer._p["Looted?"] == true end

local LOOT = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:"
local PICK = "/Game/Inventory/Containers/PicklockContainer/BP_MASTER_PicklockContainer.BP_MASTER_PicklockContainer_C:"
-- the game's OpenContainer: ContainerLooted set (@4710), then the post-hook
local function open(w, o, path)
    o._p.ContainerLooted = true
    o._p.BP_JigMultiplayer._p["Looted?"] = true
    fire(w, (path or LOOT) .. "OpenContainer", param(o))
end

print("== S0. hooks and the new-object watch")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
check(HW.hooks[LOOT .. "OpenContainer"] ~= nil and HW.hooks[PICK .. "OpenContainer"] ~= nil, "OpenContainer hooks (loot, lock-pick)")
local watched = {}
for _, x in ipairs(HW.watch or {}) do watched[x.path:match("%.([%w_]+)$") or "?"] = true end
check(watched.BP_LootContainer_C and watched.BP_MASTER_PicklockContainer_C and watched.BP_MASTER_ToolRequiredContainer_C,
    "new loot / lock-pick / tool containers watched")
-- the level loads: the placed boxes are constructed (only their names read)
notify(HW, hlevel); notify(CW, clevel)
-- the host's camp spawns; the client's copies replicate in
for i = 1, #H_ do notify(HW, H_[i]) end
notify(HW, hlocker)
for i = 1, #C_ do notify(CW, C_[i]) end
notify(CW, clocker)
ticks(4)
local CB = C.world._t.camps
check(CB ~= nil, "camp container helpers exported")

print("== S1. placed level boxes: both ways as before")
open(CW, clevel)
check(outbox_has(CW, "WLOOT|~LongdownValley~Container_RandomLoot_TrashBag_C_93|") ~= nil, "client search -> WLOOT by level path")
deliver()
check(searched(hlevel) and called(hlevel._p.BP_JigMultiplayer, "StartRefillTimer") ~= nil, "host: searched, its refill timer started")
local hdesk = box(HW, LOOT_CHAIN("Container_ResidentialLoot_Desk_C"), "Container_ResidentialLoot_Desk18_0", { X = 1200, Y = 2000, Z = 300 })
local cdesk = box(CW, LOOT_CHAIN("Container_ResidentialLoot_Desk_C"), "Container_ResidentialLoot_Desk18_0", { X = 1200, Y = 2000, Z = 300 })
open(HW, hdesk)
check(outbox_has(HW, "WLOOT|~LongdownValley~Container_ResidentialLoot_Desk18_0|") ~= nil, "host search -> WLOOT by level path")
deliver()
check(searched(cdesk), "client: searched")

print("== S2. ROOT CAUSE: the host searches a camp chest -> searched on the client too")
open(HW, hfuel)
local m = outbox_has(HW, "|WLOOT|@Container_FuelLoot_FuelTank_C@")
check(m ~= nil, "the host's camp search goes out as @Class@x,y,z (0.7.0: nothing was sent)")
deliver()
check(searched(cfuel), "the client's copy (another name, 0.5 cm off) is searched: it opens at once, no second search")
local nout = #CW.outbox
open(CW, cfuel)
check(#CW.outbox == nout, "opening it on the client sends nothing back")

print("== S3. ROOT CAUSE: the client searches a camp chest -> searched on the host")
open(CW, cammo_a)
m = outbox_has(CW, "WLOOT|@Container_AmmoLoot_AmmoCrate_C@")
check(m ~= nil, "the client's camp search goes to the host (0.7.0: nothing was sent)")
deliver()
check(searched(hammo_a), "the host's container is searched (the host opens it at once)")
check(not searched(hammo_b), "its neighbour of the same class 60 cm away is not")
check(called(hammo_a._p.BP_JigMultiplayer, "StartRefillTimer") ~= nil, "the host's copy starts its refill timer")
open(HW, hammo_a)
check(outbox_has(HW, "WLOOT|") == nil, "the host opening it again sends nothing")

print("== S4. a client copy that leaves the network range comes back searched")
cfuel._valid = false
local cfuel2 = box(CW, LOOT_CHAIN("Container_FuelLoot_FuelTank_C"), "Container_FuelLoot_FuelTank_C_2147479990",
    off(FUEL, -0.3, 0.4, 0), { Role = 1 })
notify(CW, cfuel2)
ticks(1, 0.25)
check(cfuel2._p.ContainerLooted == false, "not touched before its BeginPlay settled (0.25 s)")
ticks(2, 0.25)
check(searched(cfuel2), "searched as on the host once settled (0.5 s)")
-- the client's own search is kept the same way
cammo_a._valid = false
local cammo_a2 = box(CW, LOOT_CHAIN("Container_AmmoLoot_AmmoCrate_C"), "Container_AmmoLoot_AmmoCrate_C_2147479991",
    off(AMMO_A, 0.2, 0.2, 0), { Role = 1 })
notify(CW, cammo_a2)
ticks(3, 0.25)
check(searched(cammo_a2) and not searched(cammo_b), "the client's own searched crate comes back searched, its neighbour not")

print("== S5. lock-pick containers in a camp: unlocked and searched on the client")
hlocker._p["IsLocked?"] = false
open(HW, hlocker, PICK)
check(outbox_has(HW, "WLOOT|@PicklockContainer_MilitaryLocker_C@") ~= nil, "the host's camp locker goes out")
check((outbox_has(HW, "WLOOT|@PicklockContainer_MilitaryLocker_C@") or ""):sub(-2) == "|u", "with its lock picked (u)")
deliver()
check(searched(clocker) and clocker._p["IsLocked?"] == false, "client: searched and unlocked")

print("== S6. host refill of a camp chest: the client's copy unsearched, and stays so")
WORLD = HW
hfuel._m.Bind_Refill(hfuel)
fire(HW, LOOT .. "Bind_Refill", param(hfuel))
check(outbox_has(HW, "WLOOTR") == nil, "not sent inside the hook")
ticks(2)
check(called(cfuel2, "Bind_Refill") ~= nil and cfuel2._p.ContainerLooted == false, "the client's copy ran Bind_Refill")
cfuel2._valid = false
local cfuel3 = box(CW, LOOT_CHAIN("Container_FuelLoot_FuelTank_C"), "Container_FuelLoot_FuelTank_C_2147479980",
    off(FUEL, 0.1, 0.1, 0), { Role = 1 })
notify(CW, cfuel3)
ticks(4)
check(cfuel3._p.ContainerLooted == false, "a copy that comes back after the refill stays unsearched")
-- the host searches it again: the new copy follows (the host's name was cleared by the refill)
open(HW, hfuel)
deliver()
check(searched(cfuel3), "searched again on the host -> searched on the client again")
hfuel._m.Bind_Refill(hfuel)
fire(HW, LOOT .. "Bind_Refill", param(hfuel))
ticks(2)
check(cfuel3._p.ContainerLooted == false, "(refilled again)")

print("== S7. a client's own leftover (authority, not on the host) is never named")
WORLD = CW
local cown = box(CW, LOOT_CHAIN("Container_MlitaryLoot_MilitaryCrate_C"),
    "ChildActor18_GEN_VARIABLE_Container_MlitaryLoot_MilitaryCrate_C_CAT_2147478574", { X = 90000, Y = 0, Z = 0 }, { Role = 3 })
notify(CW, cown)
open(CW, cown)
check(outbox_has(CW, "WLOOT|") == nil, "no WLOOT for the client's own runtime container")
ticks(2)

print("== S8. a client that joins: the host's list names the camp chests; copies get them now or when they come")
-- host state now: AMMO_A searched (client), LOCKER searched + unlocked; FUEL refilled
hsupply._p.ContainerLooted, hsupply._p.BP_JigMultiplayer._p["Looted?"] = true, true   -- searched on the host before the join
C.world.reset("mock: join again")
for _, o in ipairs({ cfuel3, csupply, cammo_a2, cammo_b, clocker }) do o._valid = false end
local j_ammo_a = box(CW, LOOT_CHAIN("Container_AmmoLoot_AmmoCrate_C"), "Container_AmmoLoot_AmmoCrate_C_2147479801", off(AMMO_A, 0.4, 0, 0), { Role = 1 })
local j_ammo_b = box(CW, LOOT_CHAIN("Container_AmmoLoot_AmmoCrate_C"), "Container_AmmoLoot_AmmoCrate_C_2147479802", off(AMMO_B, 0.4, 0, 0), { Role = 1 })
local j_locker = box(CW, PICK_CHAIN("PicklockContainer_MilitaryLocker_C"), "PicklockContainer_MilitaryLocker_C_2147479803",
    off(LOCKER, 0, 0.4, 0), { Role = 1, ["IsLocked?"] = true })
local j_fuel = box(CW, LOOT_CHAIN("Container_FuelLoot_FuelTank_C"), "Container_FuelLoot_FuelTank_C_2147479804", FUEL, { Role = 1 })
for _, o in ipairs({ j_ammo_a, j_ammo_b, j_locker, j_fuel }) do notify(CW, o) end
ticks(3)
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 20 do ticks(1) end
check(searched(j_ammo_a) and not searched(j_ammo_b), "the searched crate searched here, its neighbour not")
check(searched(j_locker) and j_locker._p["IsLocked?"] == false, "the locker searched and unlocked")
check(not searched(j_fuel), "the refilled fuel tank not searched")
-- the supply crate's copy comes into range only now
local j_supply = box(CW, LOOT_CHAIN("Container_MlitaryLoot_MilitarySupplies_C"), "Container_MlitaryLoot_MilitarySupplies_C_2147479805",
    off(SUPPLY, -0.4, 0.1, 0), { Role = 1 })
notify(CW, j_supply)
ticks(3)
check(searched(j_supply), "a copy that comes into range after the list: searched")

print("== S9. a camp chest's noise reaches the host's AI (WNOISE by class and place)")
WORLD = CW
local nh0 = #HW.hearing._calls
fire(CW, LOOT .. "PauseInteract", param(j_ammo_b))
check(outbox_has(CW, "WNOISE|@Container_AmmoLoot_AmmoCrate_C@") ~= nil, "the client's noisy camp search goes to the host")
deliver()
local nc = HW.hearing._calls[nh0 + 1]
check(nc ~= nil and nc[1] == "ReportNoiseEvent" and nc[2] == hammo_b, "the host reports the noise at its own crate B")

print("== S10. the host misses nothing it has; an unknown place is only logged")
WORLD = HW
H.world._t.loot_msg({ "@Container_FuelLoot_FuelTank_C@1,2,3", "" }, rpc)
check(H.world.stats.camp_missing == 1, "an unknown camp container: counted, nothing applied")
-- a container the watch missed (made before the mod loaded) is found by its class
local hlate = box(HW, LOOT_CHAIN("Container_RandomLoot_JunkPile_C"),
    "ChildActor3_GEN_VARIABLE_Container_RandomLoot_JunkPile_C_CAT_2147475700", { X = 18000, Y = 75000, Z = 1540 }, { Role = 3 })
local fa0 = find_all_calls.Container_RandomLoot_JunkPile_C or 0
H.world._t.loot_msg({ "@Container_RandomLoot_JunkPile_C@18000,75000,1540", "" }, rpc)
check(searched(hlate) and (find_all_calls.Container_RandomLoot_JunkPile_C or 0) == fa0 + 1, "found by one FindAllOf of its class")

print("== S11. status")
WORLD = HW; local sh = H.world.status_line(); print(sh)
WORLD = CW; local sc = C.world.status_line(); print(sc)
check(sc:find("(camps ", 1, true) ~= nil, "status: camp containers applied / missing / places kept")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
