-- Mock harness, wave "ai" 2026-11-13, client side, against the real sdc_ai + features:
--   ai_client_far_movement  zombie copies at the L3 layer (122-150 m) keep their movement
--   ai_horde_beacon         the beacon on a client: music, the host's wave notices, the phantom pickup
-- usage: lua mock_ai_wave_client.lua <scripts dir>
-- (harness core from mock_ai_coop_host.lua, as a client)
-- (harness core copied from mock_world_infxp.lua)
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local LOG = {}
local real_print = print
print = function(s) LOG[#LOG + 1] = tostring(s) end
local function say(s) real_print(s) end
local function find_log(pat, from)
    for i = from or 1, #LOG do if LOG[i]:find(pat) then return LOG[i], i end end
    return nil
end

local WORLD
local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then say("  ok   " .. what) else say("  FAIL " .. what); fails = fails + 1 end
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
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[i]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _calls = {}, _tags = {} }, Obj)
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
function Obj:ActorHasTag(fn) return self._tags[fn._s] == true end
function Obj:K2_DestroyActor() self._valid = false end

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

-- every callback registered on `path` (natives: pre, else the one callback)
local function fire(path, kind, ...)
    local hs = WORLD.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local fn = (kind == "post") and h.post or h.pre
        if fn then
            local r = fn(...)
            assert(r == nil, "hook returned a value: " .. path)
        end
    end
    return true
end

-- ---------------------------------------------------------------- the host's world
local HW = { id = "host", objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
WORLD = HW
local ksl = new(HW, { "KismetSystemLibrary" }, "KSL", {}, {
    IsStandalone = function() return false end,
    IsServer = function() return false end,
}, "/Script/Engine.Default__KismetSystemLibrary")
local gps = new(HW, { "GameplayStatics" }, "GPS", {}, {
    GetPlayerController = function(_, wc, i) return HW.pcs[i + 1] end,
    GetNumPlayerControllers = function() return #HW.pcs end,
    GetCurrentLevelName = function() return "LongdownValley" end,
    GetAllActorsOfClass = function(_, wc, cls, out)
        for _, o in ipairs(HW.objects) do if o._valid and derives(o, cls._cname or "?") then out[#out + 1] = param(o) end end
    end,
}, "/Script/Engine.Default__GameplayStatics")
new(HW, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
new(HW, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {},
    "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")

local lp = new(HW, { "LocalPlayer" }, "LocalPlayer_0")
local hpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
    IsLocalController = function() return true end,
})
local hpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
    { Controller = hpc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true })
hpc._p.Pawn = hpawn
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1", { _loc = { X = 5000, Y = 0, Z = 0 } })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
HW.pcs = { hpc, rpc }
local function place(o, x, y, z) o._p._loc = { X = x, Y = y or 0, Z = z or 0 } end
function Obj:IsA(cls) return cls ~= nil and derives(self, cls._cname or "?") end
local function class_at(path, cname)
    local c = new(HW, { "BlueprintGeneratedClass" }, cname, {}, {}, path)
    c._cname = cname
    return c
end
local BEACON_PATH = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C"
local PICKUP_PATH = "/Game/Inventory/Items/Pickups/Buildable/HordeBeacon/BP_HordeBeaconPickup.BP_HordeBeaconPickup_C"
class_at("/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C", "BP_MasterZombie_C")
class_at(BEACON_PATH, "Buildable_HordeBeacon_C")
class_at(PICKUP_PATH, "BP_HordeBeaconPickup_C")
-- this machine is the client: its own controller and character; no remote players
HW.pcs = { hpc }
rpawn._valid, rpc._valid = false, false

local CFGO = {}
local function load_mods()
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if CFGO[k] ~= nil then return CFGO[k] end
        return get0(k, ...)
    end
    m.net.install_hooks()
    m.ai = require("sdc_ai")
    return m
end
local C = load_mods()
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley" }
C.ai.init(CS)
C.ai.register_handlers()
local function tick() C.ai.client_tick() end
tick()
local TOASTS = {}
C.log.toast_sink = function(text) TOASTS[#TOASTS + 1] = text end
local function toasted(pat)
    for _, t in ipairs(TOASTS) do if t:find(pat, 1, true) then return t end end
    return nil
end

say("== 0. features (client)")
local lines = C.ai.status_lines()
check(lines[1]:find("farmove=on", 1, true) and lines[1]:find("horde=on", 1, true), "far movement and horde on: " .. lines[1])

-- ===========================================================================
say("== 1. ai_client_far_movement: L3 copies keep moving")
local ZM = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:"
local FN = ZM .. "BndEvt__BP_Zombie_Master_AIOSubject_K2Node_ComponentBoundEvent_2_OnOptimizationUpdate__DelegateSignature"
check(HW.hooks[FN] ~= nil, "client: the zombie's OnOptimizationUpdate hooked")
local function copy(name, role, dead)
    local calls = {}
    local comp = new(HW, { "AIOSubjectComponent" }, "AIOSubject_" .. name, {}, {
        SetCharacterFeatures = function(_, who, f) calls[#calls + 1] = { who = who, f = f } end,
    })
    local z = new(HW, { "BP_Zombie_Roamer_C", "BP_MasterZombie_C", "BP_MainEnemy_C" }, name,
        { Role = role or 1, ["IsDead?"] = dead == true, AIOSubject = comp, _loc = { X = 13000, Y = 0, Z = 0 } })
    return z, calls
end
local function layer(z, idx, beyond)
    fire(FN, "bp", param(z), param(beyond == true), param(idx), param(true))
end
local z1, c1 = copy("BP_Zombie_Roamer_C_2147200001")
layer(z1, 3)
check(#c1 == 1 and c1[1].who == z1 and c1[1].f == 31, "L3 (122-150 m): the copy gets SetCharacterFeatures(self, 31) (movement on)")
check(find_log("ai: far movement: the host's BP_Zombie_Roamer_C_2147200001 is 122%-150 m from this player") ~= nil, "logged")
for _, idx in ipairs({ 0, 1, 2, 4 }) do layer(z1, idx) end
check(#c1 == 1, "L0 / L1 / L2 / L4: left to the game")
layer(z1, 3, true)
check(#c1 == 1, "beyond the last layer: left to the game")
local z2, c2 = copy("BP_Zombie_Roamer_C_2147200002", 3)
layer(z2, 3)
check(#c2 == 0, "this machine's own zombie (authority): not touched")
local z3, c3 = copy("BP_Zombie_Roamer_C_2147200003", 1, true)
layer(z3, 3)
check(#c3 == 0, "a dead copy: not touched")
local z4 = new(HW, { "BP_Zombie_Roamer_C", "BP_MasterZombie_C" }, "BP_Zombie_Roamer_C_2147200004", { Role = 1 })
layer(z4, 3)
check(find_log("ai: far movement: BP_Zombie_Roamer_C_2147200004: SetCharacterFeatures failed") ~= nil, "no AIOSubject: counted as failed, logged")
CFGO.ai_client_far_movement = false
tick()
layer(z1, 3)
check(#c1 == 1, "ai_client_far_movement off: nothing")
CFGO.ai_client_far_movement = nil
tick()
layer(z1, 3)
check(#c1 == 2, "on again: works")

-- ===========================================================================
say("== 2. ai_horde_beacon on a client")
local B = BEACON_PATH .. ":"
local music = { init = 0, next = 0, entry = nil }
local track = new(HW, { "AudioComponent" }, "AudioComponent_1")
local mlc = new(HW, { "MusicLayeringComponent_C" }, "MusicLayeringComponent", { CurrentTrack = nil }, {
    ExecuteUbergraph_MusicLayeringComponent = function(self, entry)
        music.init, music.entry = music.init + 1, entry
        self._p.CurrentTrack = track
    end,
    NextTrack = function() music.next = music.next + 1 end,
})
local beacon = new(HW, { "Buildable_HordeBeacon_C", "Buildable_MASTER_C", "Actor" }, "Buildable_HordeBeacon_C_2147200800",
    { Role = 1, ["HordeStarted?"] = true, CurrentWave = 0, MusicLayeringComponent = mlc, _loc = { X = 2000, Y = 100, Z = 50 } })
check(HW.hooks[B .. "Event_StartHorde"] ~= nil and HW.hooks[B .. "Event_SpawnBeacon"] ~= nil, "client: Event_StartHorde / Event_SpawnBeacon hooked")
check(HW.hooks[B .. "Event_NextWave"] == nil and HW.hooks[B .. "EnemyDefeatedCheck"] == nil, "client: the host's hooks not installed")
-- the multicast started the horde on this copy: the music, which the server RPC never brought here
fire(B .. "Event_StartHorde", "bp", param(beacon))
check(music.init == 1 and music.entry == 1128, "the copy started the horde: Initialise's body (entry 1128) runs here")
fire(B .. "Event_StartHorde", "bp", param(beacon))
check(music.init == 1, "a track already plays: not started twice")
mlc._p.CurrentTrack = nil
beacon._p["HordeStarted?"] = false
fire(B .. "Event_StartHorde", "bp", param(beacon))
check(music.init == 1, "the copy stopped the horde: no music started")
beacon._p["HordeStarted?"] = true
local own = new(HW, { "Buildable_HordeBeacon_C" }, "Buildable_HordeBeacon_C_5", { Role = 3, ["HordeStarted?"] = true,
    MusicLayeringComponent = mlc, _loc = { X = 0, Y = 0, Z = 0 } })
fire(B .. "Event_StartHorde", "bp", param(own))
check(music.init == 1, "a beacon of this machine's own (authority): its own Initialise works, not touched")
fire(B .. "Event_StartHorde", "bp", param(beacon))
check(music.init == 2, "started again after a stop: the music starts again")
-- the host's notices
local function horde(...)
    local kind, f = C.net.decode(C.net.encode("HORDE", ...))
    C.net.handlers[kind](f, hpc)
end
horde("wave", "2", "2000", "100", "50")
check(toasted("Волна 2 началась!") ~= nil, "HORDE|wave|2: the game notice 'Волна 2 началась!'")
check(music.next == 1, "wave 2: NextTrack on the copy at that place")
horde("wave", "3", "9000", "0", "0")
check(music.next == 1 and toasted("Волна 3 началась!") ~= nil, "no copy at that place: the notice only")
horde("done", "3", "2000", "100", "50")
check(toasted("Волна 3 отбита! Следующая через 15 секунд...") ~= nil, "HORDE|done|3")
horde("final", "10", "2000", "100", "50")
check(toasted("Последняя волна отбита!") ~= nil, "HORDE|final")
horde("kept", "4", "2000", "100", "50")
check(toasted("Игрок погиб, но орда продолжается, пока жив хоть один из вас.") ~= nil,
    "HORDE|kept: a player died, the horde goes on")
horde("over", "4", "2000", "100", "50", "all")
check(toasted("Орда остановлена: погибли все игроки.") ~= nil, "HORDE|over|...|all: every player is dead")
horde("over", "4", "2000", "100", "50", "bound")
check(toasted("Орда остановлена: погиб игрок, к которому привязан маяк.") ~= nil,
    "HORDE|over|...|bound: the game's end (the player the beacon is tied to)")
local n_over = #TOASTS
horde("over", "4", "2000", "100", "50")
check(#TOASTS == n_over + 1 and TOASTS[#TOASTS]:find("привязан маяк", 1, true) ~= nil,
    "HORDE|over from an older host (no reason): the game's end text")
local n_toasts = #TOASTS
horde("weird", "1", "0", "0", "0")
check(#TOASTS == n_toasts, "an unknown kind: nothing")
-- this player died near the host's beacon: its copy spawned a local beacon pickup
local phantom = new(HW, { "BP_HordeBeaconPickup_C", "Actor" }, "BP_HordeBeaconPickup_C_2147200900",
    { Role = 3, _loc = { X = 2050, Y = 120, Z = 60 } })
local hosts = new(HW, { "BP_HordeBeaconPickup_C", "Actor" }, "BP_HordeBeaconPickup_C_2147200901",
    { Role = 1, _loc = { X = 2050, Y = 120, Z = 60 } })
local far_one = new(HW, { "BP_HordeBeaconPickup_C", "Actor" }, "BP_HordeBeaconPickup_C_2147200902",
    { Role = 3, _loc = { X = 9000, Y = 0, Z = 0 } })
local placed = new(HW, { "BP_HordeBeaconPickup_C", "Actor" }, "BP_HordeBeaconPickup_C_3",
    { Role = 3, _loc = { X = 2050, Y = 120, Z = 60 } })
fire(B .. "Event_SpawnBeacon", "bp", param(beacon))
check(phantom._valid == false, "the local pickup next to the copy: removed")
check(hosts._valid and far_one._valid and placed._valid, "a host pickup, a far one, a level-placed one: kept")
check(find_log("ai: horde: this player died near the host's beacon Buildable_HordeBeacon_C_2147200800: 1 local beacon pickup") ~= nil, "logged")
CFGO.ai_horde_beacon = false
tick()
n_toasts = #TOASTS
horde("final", "10", "2000", "100", "50")
check(#TOASTS == n_toasts, "ai_horde_beacon off: no notice")
CFGO.ai_horde_beacon = nil

say("")
for _, l in ipairs(C.ai.status_lines()) do say("  " .. l) end
check(find_log("%[ERROR%]") == nil, "no error lines")
print = real_print
say(string.format("ai wave client: %d checks, %d failed", checks, fails))
say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
