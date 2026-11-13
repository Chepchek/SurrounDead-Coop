-- Mock harness, wave "ai" 2026-11-13, host side, against the real sdc_ai + features:
--   ai_host_cap        zombie spawners pause while the world has the cap of living zombies (flexible:
--                      250 for up to four players, +25 per player beyond four, at most 300)
--   ai_player_scaling  no bigger group while the world is full
--   ai_toughness       damage to / from zombies with several players near (off by default)
--   ai_zombie_fx       the relayed assets by their paths: no stale "not wanted" cache
--   ai_horde_beacon    the beacon's waves / done / final relayed to clients near it; the co-op hold
--                      (ai_horde_continue: the horde goes on while a player is alive)
-- usage: lua mock_ai_wave_host.lua <scripts dir>
-- (harness core from mock_ai_coop_host.lua)
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
    IsServer = function() return true end,
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
for _, p in ipairs({ hpawn, rpawn }) do p._tags.ZombieCanAttack = true end
local function place(o, x, y, z) o._p._loc = { X = x, Y = y or 0, Z = z or 0 } end
function Obj:IsA(cls) return cls ~= nil and derives(self, cls._cname or "?") end

-- class objects (StaticFindObject by path: sdc_ai's isa, GetAllActorsOfClass)
local function class_at(path, cname)
    local c = new(HW, { "BlueprintGeneratedClass" }, cname, {}, {}, path)
    c._cname = cname
    return c
end
local ZOMBIE_PATH = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local SPAWNER_PATH = "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C"
local BEACON_PATH = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C"
class_at(ZOMBIE_PATH, "BP_MasterZombie_C")
class_at(SPAWNER_PATH, "BP_AISpawner_Master_C")
class_at("/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C", "BP_ZombieBoss_C")
class_at(BEACON_PATH, "Buildable_HordeBeacon_C")

-- ---------------------------------------------------------------- modules
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
local H = load_mods()
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.ai.init(HS)
H.ai.register_handlers()
local function tick()
    H.ctx.tick(HS.remote_pcs)
    H.ai.host_tick(HS.remote_pcs)
end
tick()
local function sent(kind)
    local out = {}
    for _, m in ipairs(HW.outbox) do
        if type(m) == "string" and m:find("|" .. kind .. "|", 1, true) then out[#out + 1] = m end
    end
    return out
end

say("== 0. features")
local lines = H.ai.status_lines()
check(lines[1]:find("cap=on", 1, true) and lines[1]:find("tough=off", 1, true) and lines[1]:find("horde=on", 1, true)
    and lines[1]:find("farmove=on", 1, true), "cap / horde / far movement on, toughness off by default: " .. lines[1])
local ADD = SPAWNER_PATH .. ":AddGroupToSpawn"
local STOP = SPAWNER_PATH .. ":SetIsSpawningStopped"
check(HW.hooks[ADD] ~= nil and HW.hooks[STOP] ~= nil, "host: AddGroupToSpawn and SetIsSpawningStopped hooked")

-- ===========================================================================
say("== 1. ai_host_cap: zombie spawners pause while the world is full")
local zombies = {}
local function zombie(i, dead, chain)
    local z = new(HW, chain or { "BP_Zombie_Roamer_C", "BP_MasterZombie_C", "BP_MainEnemy_C", "Character" },
        "BP_Zombie_Roamer_C_" .. (2147300000 + i), { ["IsDead?"] = dead == true, Role = 3, _loc = { X = 100 * i, Y = 0, Z = 0 } })
    zombies[#zombies + 1] = z
    return z
end
local roamer_cls = new(HW, { "BlueprintGeneratedClass" }, "BP_Zombie_Roamer_C", {})
local boss_cls = new(HW, { "BlueprintGeneratedClass" }, "BP_ZombieBoss_Juggernaut_C", {})
local added = {}
local stops = {}       -- every SetIsSpawningStopped call: { sp, stop }
local function spawner(name, amount, cls)
    return new(HW, { "BP_AISpawner_Zombies_C", "BP_AISpawner_Master_C", "Actor" }, name,
        { SpawnAmount = amount, SpawnedActorClass = cls, IsSpawningStopped = false, _loc = { X = 0, Y = 0, Z = 0 } }, {
            AddGroupToSpawn = function(self, n)
                added[#added + 1] = { sp = self, n = n }
                fire(ADD, "bp", param(self), param(n))
            end,
            -- the game's custom event: sets the switch; a Lua call runs its hook too
            SetIsSpawningStopped = function(self, stop)
                stops[#stops + 1] = { sp = self, stop = stop }
                self._p.IsSpawningStopped = stop
                fire(STOP, "bp", param(self), param(stop))
            end,
        })
end
local function group(sp, n)   -- the game's own call
    added = {}
    fire(ADD, "bp", param(sp), param(n))
    return added
end
CFGO.ai_host_cap_zombies = 50
for i = 1, 49 do zombie(i) end
for i = 50, 59 do zombie(i, true) end      -- corpses: not counted
place(hpawn, 1000, 0, 0)
place(rpawn, 5000, 0, 0)
advance(5); tick()
local s1 = spawner("BP_AISpawner_Zombies_C_1", 5, roamer_cls)
local a = group(s1, 5)
check(#a == 1 and a[1].n == 2 and s1._p.IsSpawningStopped == false,
    "49 living (+10 corpses), cap 50: not full, the group grows with 2 players (+2)")
zombie(60)
advance(5); tick()
check(find_log("ai: cap: 50 living zombies in this world %(cap 50 for 2 players%): zombie spawners pause") ~= nil,
    "50 living: full, logged")
check(find_log("ai: cap: 2 player%(s%) in this world: the cap is 50 living zombies %(50 for up to four players, %+25 for"
    .. " each player beyond four, at most 300%)") ~= nil, "the cap for the players in the world logged")
a = group(s1, 5)
check(s1._p.IsSpawningStopped == true, "full: the spawner queueing a group is paused (SetIsSpawningStopped true)")
check(#a == 0, "full: no bigger group from ai_player_scaling")
check(find_log("ai: cap: BP_AISpawner_Zombies_C_1 paused: 50 living zombies in this world %(cap 50%); it spawns when there are fewer than 45") ~= nil,
    "pause logged")
local n_stops = #stops
group(s1, 5)
check(#stops == n_stops, "already paused: not switched again")
local sb = spawner("BP_AISpawner_ZombieBosses_C_1", 1, boss_cls)
group(sb, 1)
check(sb._p.IsSpawningStopped == false, "a boss spawner is not paused")
local sg = spawner("BP_AISpawner_Zombies_C_2", 5, roamer_cls)
sg._p.IsSpawningStopped = true            -- the game stopped it itself
n_stops = #stops
group(sg, 5)
check(#stops == n_stops, "a spawner the game stopped itself: not ours, not touched")
local s3 = spawner("BP_AISpawner_Zombies_C_3", 5, roamer_cls)
group(s3, 5)
check(s3._p.IsSpawningStopped == true, "a second spawner paused")
-- the game switches s3 itself (a quest, a reset): it is the game's again
s3._m.SetIsSpawningStopped(s3, true)
check(find_log("ai: cap: the game switched the paused BP_AISpawner_Zombies_C_3 itself") ~= nil, "the game's own switch noticed")
-- hysteresis: 47 living, still full (full until below 90 % of the cap)
for i = 1, 3 do zombies[i]._p["IsDead?"] = true end
advance(5); tick()
local s3b = spawner("BP_AISpawner_Zombies_C_4", 5, roamer_cls)
group(s3b, 5)
check(s1._p.IsSpawningStopped == true and s3b._p.IsSpawningStopped == true,
    "full at 50, now 47 living (not below 45): still full, a new group waits too")
s3b._valid = false
-- zombies die: 44 living < 45 -> resume
for i = 4, 6 do zombies[i]._p["IsDead?"] = true end
advance(5); tick()
check(s1._p.IsSpawningStopped == false, "44 living (< 90 % of 50): the paused spawner spawns again")
check(s3._p.IsSpawningStopped == true and sg._p.IsSpawningStopped == true, "the game's own stops are left alone")
check(find_log("ai: cap: 1 zombie spawner%(s%) spawn again") ~= nil, "resume logged")
-- hysteresis: 47 living (between the mark and the cap): not full
for i = 1, 3 do zombies[i]._p["IsDead?"] = false end
advance(5); tick()
group(s1, 5)
check(s1._p.IsSpawningStopped == false, "47 living (between 45 and 50): not full, not paused")
-- many paused: at most 8 resumed per count
for i = 1, 3 do zombie(100 + i) end
advance(5); tick()
local many = {}
for i = 1, 10 do many[i] = spawner("BP_AISpawner_Zombies_C_" .. (10 + i), 5, roamer_cls); group(many[i], 5) end
local paused_now = 0
for _, sp in ipairs(many) do if sp._p.IsSpawningStopped then paused_now = paused_now + 1 end end
check(paused_now == 10, "50 living: 10 spawners paused")
for i = 1, 10 do zombies[i]._p["IsDead?"] = true end
advance(5); tick()
local back = 0
for _, sp in ipairs(many) do if not sp._p.IsSpawningStopped then back = back + 1 end end
check(back == 8, "below the mark: 8 resumed in one count (" .. back .. ")")
advance(5); tick()
back = 0
for _, sp in ipairs(many) do if not sp._p.IsSpawningStopped then back = back + 1 end end
check(back == 10, "the rest at the next count")
-- off while paused: all back at once
for i = 1, 10 do zombies[i]._p["IsDead?"] = false end
advance(5); tick()
local s4 = spawner("BP_AISpawner_Zombies_C_40", 5, roamer_cls)
group(s4, 5)
check(s4._p.IsSpawningStopped == true, "full again: paused")
CFGO.ai_host_cap = false
tick()
check(s4._p.IsSpawningStopped == false, "ai_host_cap turned off: the paused spawner spawns again")
local s5 = spawner("BP_AISpawner_Zombies_C_41", 5, roamer_cls)
group(s5, 5)
check(s5._p.IsSpawningStopped == false, "off: nothing paused")
CFGO.ai_host_cap = nil
tick()
-- a spawner gone while paused is forgotten
advance(5); tick()
local s6 = spawner("BP_AISpawner_Zombies_C_42", 5, roamer_cls)
group(s6, 5)
check(s6._p.IsSpawningStopped == true, "full: paused")
s6._valid = false
for i = 1, 20 do zombies[i]._p["IsDead?"] = true end
advance(5); tick()
local capline
for _, l in ipairs(H.ai.status_lines()) do if l:find("ai: cap ", 1, true) then capline = l end end
check(capline ~= nil and capline:find("paused now=0", 1, true) ~= nil and capline:find("gone=2", 1, true) ~= nil,
    "a spawner gone while paused is forgotten: " .. tostring(capline))
-- given back only with a living player within its SpawnRadius: the game spawns
-- only then (CanSpawnActors: IsAnyInvokerInRadius) and tries again only at the
-- spawner's next AddGroupToSpawn (its radius timer is one-shot, @1875)
local function spawner_at(name, x, y, radius)
    local sp = spawner(name, 5, roamer_cls)
    place(sp, x, y, 0)
    sp._p.SpawnRadius = radius
    return sp
end
for i = 1, 20 do zombies[i]._p["IsDead?"] = false end    -- 53 living: full
advance(5); tick()
local near1 = spawner_at("BP_AISpawner_Zombies_C_50", 0, 0)             -- the players 10 / 50 m away
local far1 = spawner_at("BP_AISpawner_Zombies_C_51", 100000, 0)         -- 1 km from both
local wide = spawner_at("BP_AISpawner_Zombies_C_52", 0, 25000, 30000)   -- 250 m, its own radius 300 m
local far2 = spawner_at("BP_AISpawner_Zombies_C_53", 0, 25000)          -- 250 m, the default 140 m
for _, sp in ipairs({ near1, far1, wide, far2 }) do group(sp, 5) end
check(near1._p.IsSpawningStopped == true and far1._p.IsSpawningStopped == true and wide._p.IsSpawningStopped == true
    and far2._p.IsSpawningStopped == true, "full: four spawners paused")
check(find_log("ai: cap: BP_AISpawner_Zombies_C_1 paused: .- fewer than 45 and a player is within its spawn radius %(140 m%)") ~= nil,
    "the pause logged with the spawner's radius (the first few pauses are logged)")
for i = 1, 20 do zombies[i]._p["IsDead?"] = true end      -- 33 living
advance(5); tick()
check(near1._p.IsSpawningStopped == false and wide._p.IsSpawningStopped == false,
    "below the mark: the spawners with a player within their spawn radius spawn again (its own radius read)")
check(far1._p.IsSpawningStopped == true and far2._p.IsSpawningStopped == true,
    "nobody within their spawn radius: still paused, their group waits (the game would not spawn it now)")
check(find_log("ai: cap: 2 zombie spawner%(s%) spawn again %(33 living zombies; 2 still paused, 2 of them until a player comes") ~= nil,
    "logged")
capline = nil
for _, l in ipairs(H.ai.status_lines()) do if l:find("ai: cap ", 1, true) then capline = l end end
check(capline ~= nil and capline:find("paused now=2 (waiting for a player 2)", 1, true) ~= nil, "status: " .. tostring(capline))
advance(5); tick()
check(far1._p.IsSpawningStopped == true, "the next count: still nobody near, still paused")
place(rpawn, 95000, 0, 0)                                   -- 50 m from far1
rpawn._p["PlayerDead?"] = true
advance(5); tick()
check(far1._p.IsSpawningStopped == true, "a dead player within its radius: still paused")
rpawn._p["PlayerDead?"] = nil
advance(5); tick()
check(far1._p.IsSpawningStopped == false, "a living player comes within 140 m: it spawns again")
check(far2._p.IsSpawningStopped == true, "the other one, nobody near: still waits")
place(rpawn, 5000, 0, 0)
-- turned off: every paused spawner back at once, a player near or not
CFGO.ai_host_cap = false
tick()
check(far2._p.IsSpawningStopped == false, "ai_host_cap off: the one with nobody near spawns again too")
check(find_log("ai: cap: 1 zombie spawner%(s%) spawn again %(ai_host_cap off; 1 of them with no player within their spawn radius") ~= nil,
    "logged")
CFGO.ai_host_cap = nil
tick()
-- the default cap, flexible: 250 for up to four players (as before: a usual session keeps it), +25 for
-- each player beyond four, at most 300
CFGO.ai_host_cap_zombies = nil
local CAP = require("sdc_ai_cap")
check(CAP.cap() == 250, "default cap: 250 living zombies (the host and one client)")
check(CAP.cap(1) == 250 and CAP.cap(2) == 250 and CAP.cap(3) == 250 and CAP.cap(4) == 250 and CAP.cap(5) == 275
    and CAP.cap(6) == 300 and CAP.cap(8) == 300, "1-4 players 250 (as before), 5 players 275, 6 and more 300")
CFGO.ai_host_cap_zombies = 5
check(CAP.cap() == 40, "at least 40")
CFGO.ai_host_cap_zombies, CFGO.ai_host_cap_per_player, CFGO.ai_host_cap_max = 200, 50, 1000
check(CAP.cap(2) == 200 and CAP.cap(4) == 200 and CAP.cap(5) == 250 and CAP.cap(8) == 400,
    "200 / +50 / 1000: 200 up to 4 players, 250 for 5, 400 for 8")
CFGO.ai_host_cap_per_player = 0
check(CAP.cap(8) == 200, "+0 per player: the same cap for any number of players")
CFGO.ai_host_cap_per_player, CFGO.ai_host_cap_max = nil, 100
check(CAP.cap(7) == 200, "a maximum below the cap for 2-4 players: that cap")
CFGO.ai_host_cap_per_player, CFGO.ai_host_cap_max = -10, nil
check(CAP.cap(7) == 200, "a negative step counts as 0")
CFGO.ai_host_cap_zombies, CFGO.ai_host_cap_per_player, CFGO.ai_host_cap_max = nil, nil, nil
advance(5); tick()
check(find_log("ai: cap: 2 player%(s%) in this world: the cap is 250 living zombies %(250 for up to four players, %+25"
    .. " for each player beyond four, at most 300%), was 50") ~= nil, "the default again: 250, logged")
-- a third and a fourth player join: still 250 (nothing logged); a fifth and a sixth: the cap follows
-- (logged), and back when they leave
local more_pcs = {}
for i = 1, 4 do
    local c = new(HW, { "IpConnection" }, "IpConnection_cap" .. i)
    more_pcs[i] = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_cap" .. i,
        { NetConnection = c, Player = c })
end
local n_cap = #LOG
HS.remote_pcs = { rpc, more_pcs[1] }
advance(5); tick()
HS.remote_pcs = { rpc, more_pcs[1], more_pcs[2] }
advance(5); tick()
check(find_log("ai: cap: %d player%(s%) in this world", n_cap + 1) == nil, "3 and 4 players: still 250, no change logged")
local function capstatus()
    for _, l in ipairs(H.ai.status_lines()) do if l:find("ai: cap ", 1, true) then return l end end
    return ""
end
check(capstatus():find("cap=250 (players 4)", 1, true) ~= nil, "status: " .. capstatus())
HS.remote_pcs = { rpc, more_pcs[1], more_pcs[2], more_pcs[3] }
advance(5); tick()
check(find_log("ai: cap: 5 player%(s%) in this world: the cap is 275 living zombies %(250 for up to four players, %+25"
    .. " for each player beyond four, at most 300%), was 250") ~= nil, "5 players: cap 275, logged")
HS.remote_pcs = { rpc, more_pcs[1], more_pcs[2], more_pcs[3], more_pcs[4] }
advance(5); tick()
check(find_log("ai: cap: 6 player%(s%) in this world: the cap is 300 living zombies .-, was 275") ~= nil,
    "6 players: cap 300 (the maximum), logged")
check(capstatus():find("cap=300 (players 6)", 1, true) ~= nil, "status: " .. capstatus())
HS.remote_pcs = { rpc }
for _, p in ipairs(more_pcs) do p._valid = false end
advance(5); tick()
check(find_log("ai: cap: 2 player%(s%) in this world: the cap is 250 living zombies .-, was 300") ~= nil,
    "back to 2 players: 250 again, logged")
for _, z in ipairs(zombies) do z._valid = false end
advance(5); tick()

-- ===========================================================================
say("== 2. ai_toughness: damage to and from zombies with several players near")
local DAMAGE = "/Script/Engine.GameplayStatics:ApplyDamage"
local function hit(victim, dmg, causer)
    local dp = param(dmg)
    fire(DAMAGE, "pre", param(gps), param(victim), dp, param(nil), param(causer), param(nil))
    return dp._v()
end
local z1 = zombie(500)
place(z1, 3000, 0, 0)
place(hpawn, 1000, 0, 0)
place(rpawn, 5000, 0, 0)
check(HW.hooks[DAMAGE] ~= nil, "ApplyDamage hooked (kill credit, friendly fire)")
check(hit(z1, 50, hpawn) == 50, "toughness off by default: 50 stays 50")
CFGO.ai_toughness = true
tick()
check(hit(z1, 50, hpawn) == 40, "2 players within 140 m: a zombie takes 50 / 1.25 = 40")
check(math.abs(hit(hpawn, 20, z1) - 23) < 1e-9, "its hit on a player: 20 x 1.15 = 23")
check(find_log("ai: toughness: BP_Zombie_Roamer_C_2147300500 takes 40.0 instead of 50.0 damage: 2 living players within 140 m %(x1.25 health%)") ~= nil,
    "logged")
place(rpawn, 30000, 0, 0)
advance(1)
check(hit(z1, 50, hpawn) == 50 and hit(hpawn, 20, z1) == 20, "the client 270 m from the zombie: one player near, unchanged")
place(rpawn, 5000, 0, 0)
local extra = {}
for i = 2, 3 do
    local c2 = new(HW, { "IpConnection" }, "IpConnection_" .. i)
    local p2 = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. i, { _loc = { X = 3500, Y = i * 100, Z = 0 } })
    local pc2 = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. i,
        { NetConnection = c2, Player = c2, Pawn = p2 })
    p2._p.Controller = pc2
    extra[#extra + 1] = p2
end
advance(1)
check(hit(z1, 70, hpawn) == 40, "4 players near: 70 / 1.75 = 40")
CFGO.ai_toughness_cap_pct = 150
check(hit(z1, 60, hpawn) == 40, "cap 150 %: 60 / 1.5 = 40")
CFGO.ai_toughness_cap_pct = nil
extra[1]._p["PlayerDead?"] = true
advance(1)
check(hit(z1, 60, hpawn) == 40, "one of them dead: 3 living, 60 / 1.5 = 40")
for _, p in ipairs(extra) do p._valid = false end
advance(1)
CFGO.ai_toughness_health_pct, CFGO.ai_toughness_damage_pct = 100, 50
check(hit(z1, 60, hpawn) == 30 and hit(rpawn, 20, z1) == 30, "pct 100 / 50: 60 / 2 = 30, 20 x 1.5 = 30")
CFGO.ai_toughness_health_pct, CFGO.ai_toughness_damage_pct = nil, nil
local boss = new(HW, { "BP_ZombieBoss_Juggernaut_C", "BP_ZombieBoss_C", "BP_MainEnemy_C" }, "BP_ZombieBoss_Juggernaut_C_2147300900",
    { Role = 3, _loc = { X = 3000, Y = 0, Z = 0 } })
check(hit(boss, 50, hpawn) == 50 and hit(hpawn, 20, boss) == 20, "a boss: unchanged")
local wall = new(HW, { "BP_Wall_C", "Actor" }, "BP_Wall_C_1", { _loc = { X = 3000, Y = 0, Z = 0 } })
check(hit(wall, 50, z1) == 50, "a zombie hitting something that is no player: unchanged")
check(hit(z1, 0, hpawn) == 0, "0 damage stays 0")
HS.remote_pcs = {}
tick()
check(hit(z1, 50, hpawn) == 50, "no client connected: unchanged")
HS.remote_pcs = { rpc }
tick()
CFGO.ai_toughness = nil
tick()
check(hit(z1, 50, hpawn) == 50, "turned off again: unchanged")
z1._valid = false

-- ===========================================================================
say("== 3. ai_zombie_fx: the relayed assets by their paths")
local GS = "/Script/Engine.GameplayStatics:"
local PATHS = {
    S_Beep_Cue = { "SoundCue", "/Game/Audio/Sounds/Cue/S_Beep_Cue.S_Beep_Cue" },
    explosion_large_06_Cue = { "SoundCue", "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue" },
    Infected_SpecialCue = { "SoundCue", "/Game/Audio/Infected_SpecialCue.Infected_SpecialCue" },
    FX_Explosion_Grenadier = { "ParticleSystem", "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_Grenadier.FX_Explosion_Grenadier" },
    FX_Explosion_RadiatedZombie = { "ParticleSystem", "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_RadiatedZombie.FX_Explosion_RadiatedZombie" },
    M_Burn = { "Material", "/Game/Blueprints/Other/ExplosiveBarrel/M_Burn.M_Burn" },
}
local assets = {}
for name, d in pairs(PATHS) do assets[name] = new(HW, { d[1] }, name, { MaxDistance = 12600 }, {}, d[2]) end
local gz = new(HW, { "BP_Zombie_Grenadier_C", "BP_MasterZombie_C", "BP_MainEnemy_C" }, "BP_Zombie_Grenadier_C_2147300700",
    { Role = 3, _loc = { X = 1000, Y = 0, Z = 0 } })
place(rpawn, 3000, 0, 0)
local function play(s)
    HW.outbox = {}
    fire(GS .. "PlaySoundAtLocation", "pre", param(gps), param(gz), param(s), param({ X = 1000, Y = 0, Z = 0 }),
        param({ Pitch = 0, Yaw = 0, Roll = 0 }), param(1.0), param(1.0))
    return #sent("AIFX")
end
advance(1); tick()
check(HW.hooks[GS .. "PlaySoundAtLocation"] ~= nil, "PlaySoundAtLocation hooked")
check(play(assets.S_Beep_Cue) == 1, "the beep at its path: relayed")
local other = new(HW, { "SoundCue" }, "Wood_Hit_Cue", {}, {}, "/Game/Audio/Wood_Hit_Cue.Wood_Hit_Cue")
local reads = 0
local fname0, full0 = Obj.GetFName, Obj.GetFullName
Obj.GetFName = function(self) if self == other then reads = reads + 1 end return fname0(self) end
Obj.GetFullName = function(self) if self == other then reads = reads + 1 end return full0(self) end
check(play(other) == 0 and reads == 0, "another sound: not relayed, its name never read (all six at their paths)")
-- the address of that sound is freed and the beep cue is loaded there (A3: before, its
-- cached "not wanted" kept the beep from the clients for up to 5 min)
local old_beep = assets.S_Beep_Cue
old_beep._valid = false
local new_beep = new(HW, { "SoundCue" }, "S_Beep_Cue", {}, {}, PATHS.S_Beep_Cue[2])
new_beep._addr = other._addr
other._valid = false
advance(1); tick()
check(play(new_beep) == 1, "the beep loaded again at an address another sound had: relayed after one host tick")
-- an address that held a relayed asset now holds another one
local imposter = new(HW, { "SoundCue" }, "Wind_Cue", {}, {}, "/Game/Audio/Wind_Cue.Wind_Cue")
imposter._addr = new_beep._addr
check(play(imposter) == 0, "another asset at a relayed asset's address: checked by name, not relayed")
Obj.GetFName, Obj.GetFullName = fname0, full0
-- the six not at their paths (a game update moved them): by name, as before, logged once
for _, d in pairs(PATHS) do HW.paths[d[2]] = nil end
local moved = new(HW, { "SoundCue" }, "S_Beep_Cue", {}, {}, "/Game/Audio/Moved/S_Beep_Cue.S_Beep_Cue")
advance(1); tick()
check(play(moved) == 1, "not at its path: found by its name, relayed")
check(find_log("ai: fx: S_Beep_Cue found by its name, not at /Game/Audio/Sounds/Cue/S_Beep_Cue.S_Beep_Cue %(0 of 6") ~= nil,
    "logged once")
local wind = new(HW, { "SoundCue" }, "Wind_Cue", {}, {}, "/Game/Audio/Wind2.Wind_Cue")
check(play(wind) == 0, "by name: another sound not relayed")
advance(1); tick()
check(play(moved) == 1, "a relayed asset met by name stays known after the next tick")

-- ===========================================================================
say("== 4. ai_horde_beacon: the host's waves, wave done, final -> clients near; the co-op hold")
local B = BEACON_PATH .. ":"
local PICKUP_PATH = "/Game/Inventory/Items/Pickups/Buildable/HordeBeacon/BP_HordeBeaconPickup.BP_HordeBeaconPickup_C"
class_at(PICKUP_PATH, "BP_HordeBeaconPickup_C")
local DEATH_UUID = 916395564
HW.timers = {}
-- the engine's latent actions: KismetSystemLibrary::Delay adds nothing while
-- an action with the same object and UUID is pending
local LATENT = {}     -- [object] = { [uuid] = { at, fn } }
local delays = {}     -- KismetSystemLibrary.Delay calls from Lua
local function add_latent(obj, uuid, dur, fn)
    LATENT[obj] = LATENT[obj] or {}
    if LATENT[obj][uuid] then return false end
    LATENT[obj][uuid] = { at = T + dur, fn = fn }
    return true
end
local delay_adds = true
ksl._m.Delay = function(self, wc, dur, info)
    delays[#delays + 1] = { wc = wc, dur = dur, info = info }
    if delay_adds then add_latent(info.CallbackTarget, info.UUID, dur, nil) end
end
-- the game's world time goes on: its latent actions that are due run
local function game_time(s)
    advance(s)
    for obj, acts in pairs(LATENT) do
        for uuid, a in pairs(acts) do
            if a.at <= T then
                acts[uuid] = nil
                if a.fn and obj._valid then a.fn() end
            end
        end
    end
end
-- this module's ue.delay callbacks
local function run_timers()
    local list = HW.timers
    HW.timers = {}
    for _, fn in ipairs(list) do fn() end
end
local pickups = {}
local next_pickup = 2147300950
-- the game's Event_SpawnBeacon (@5122): the pickup at RewardSpawnLoc, Delay 0.2 s, the beacon destroyed
local function game_spawn_beacon(b)
    next_pickup = next_pickup - 1
    local p = new(HW, { "BP_HordeBeaconPickup_C", "Actor" }, "BP_HordeBeaconPickup_C_" .. next_pickup,
        { Role = 3, _loc = { X = b._p._loc.X + 50, Y = b._p._loc.Y, Z = b._p._loc.Z }, _born = T },
        { GetGameTimeSinceCreation = function(self) return T - self._p._born end })
    pickups[#pickups + 1] = p
    add_latent(b, DEATH_UUID, 0.2, function() b._valid = false end)
    fire(B .. "Event_SpawnBeacon", "bp", param(b))
    return p
end
local function new_beacon(name, x, started, wave)
    return new(HW, { "Buildable_HordeBeacon_C", "Buildable_MASTER_C", "Actor" }, name,
        { Role = 3, ["HordeStarted?"] = started == true, CurrentWave = wave or 0, _loc = { X = x, Y = 100, Z = 50 } },
        { Event_SpawnBeacon = function(self) game_spawn_beacon(self) end })
end
local function hold_ticks(n) for _ = 1, n or 1 do advance(2); tick() end end
local function horde_line()
    for _, l in ipairs(H.ai.status_lines()) do if l:find("ai: horde ", 1, true) then return l end end
    return ""
end
-- a death as in the game: PlayerDead?, and AfterDeath's UnPossess (@1387): the body has no
-- controller, the controller no Pawn; the session keeps a dead client's last character (its body)
local PC_OF = { [hpawn] = hpc, [rpawn] = rpc }
local function die(p) p._p["PlayerDead?"] = true; p._p.Controller = nil; PC_OF[p]._p.Pawn = nil end
local function live(p) p._p["PlayerDead?"] = nil; p._p.Controller = PC_OF[p]; PC_OF[p]._p.Pawn = p end
local RREC = { pc = rpc, pawn = rpawn, name = "Friend" }
HS.remote[H.ue.name(rpc)] = RREC

local beacon = new_beacon("Buildable_HordeBeacon_C_2147300800", 2000, true, 0)
place(rpawn, 6000, 0, 0)
place(hpawn, 1000, 0, 0)
hold_ticks(1)
check(HW.hooks[B .. "Event_NextWave"] ~= nil and HW.hooks[B .. "EnemyDefeatedCheck"] ~= nil
    and HW.hooks[B .. "FinalWaveDefeated?"] ~= nil and HW.hooks[B .. "Event_SpawnBeacon"] ~= nil, "host: the beacon hooked")
-- the co-op hold: our Delay with the death path's UUID on the beacon
local d = delays[1]
check(#delays == 1 and d.wc == beacon and d.dur >= 1e6 and d.info.UUID == DEATH_UUID and d.info.Linkage == -1
    and d.info.CallbackTarget == beacon, "a client connected: the beacon held (Delay, the death path's UUID, never runs out,"
    .. " runs nothing)")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300800 held for co%-op") ~= nil, "the hold logged")
hold_ticks(1)
check(#delays == 1, "held once (not again every check)")
HW.outbox = {}
fire(B .. "Event_NextWave", "bp", param(beacon))
check(#sent("HORDE") == 0, "wave 1: nothing sent (each client's own copy shows it)")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300800 wave 1 begins %(0 client%(s%) told%)") ~= nil, "wave 1 logged")
beacon._p.CurrentWave = 1
fire(B .. "Event_NextWave", "bp", param(beacon))
local w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|wave|2|2000|100|50", 1, true) ~= nil, "wave 2: HORDE|wave|2 with the beacon's place: " .. tostring(w[1]))
HW.outbox = {}
fire(B .. "EnemyDefeatedCheck", "bp", param(beacon), param(false))
advance(1); tick()
check(#sent("HORDE") == 0, "enemies still alive: nothing")
fire(B .. "EnemyDefeatedCheck", "bp", param(beacon), param(true))
check(#sent("HORDE") == 0, "all dead: not yet (the final check comes in the same call)")
advance(0.5); tick()
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|done|2|", 1, true) ~= nil, "next host tick: HORDE|done|2")
HW.outbox = {}
beacon._p.CurrentWave = 9
fire(B .. "EnemyDefeatedCheck", "bp", param(beacon), param(true))
fire(B .. "FinalWaveDefeated?", "bp", param(beacon))
advance(1); tick()
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|final|10|", 1, true) ~= nil, "the final wave: HORDE|final only (no 'done')")
HW.outbox = {}
place(rpawn, 40000, 0, 0)
beacon._p.CurrentWave = 2
fire(B .. "Event_NextWave", "bp", param(beacon))
check(#sent("HORDE") == 0, "a client 380 m from the beacon: not told")
place(rpawn, 6000, 0, 0)

say("-- the host (the player the beacon is bound to) dies, the client is alive: the horde goes on")
HW.outbox = {}
die(hpawn)
local p1 = game_spawn_beacon(beacon)
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|kept|3|2000|100|50", 1, true) ~= nil, "HORDE|kept to the client: " .. tostring(w[1]))
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300800: the player the game ties it to died; 1 player%(s%) still"
    .. " alive: the beacon stays, its horde goes on %(wave 3%)") ~= nil, "logged")
check(LATENT[beacon][DEATH_UUID].fn == nil, "the game's 0.2 s removal was never added (our hold is the pending action)")
game_time(0.2); run_timers()
check(beacon._valid and p1._valid, "0.2 s later the beacon is still there; its pickup not taken back yet (0.2 s old)")
game_time(0.25); run_timers()
check(beacon._valid and not p1._valid, "0.45 s: the pickup the game spawned for the end is taken back, the beacon stays")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300800 stays: the pickup the game spawned for its end was taken back") ~= nil,
    "logged")
HW.outbox = {}
beacon._p.CurrentWave = 3
fire(B .. "Event_NextWave", "bp", param(beacon))
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|wave|4|", 1, true) ~= nil, "the horde goes on: wave 4 relayed")
check(horde_line():find("kept after a death=1 (deferred now 1)", 1, true) ~= nil, "status: " .. horde_line())
-- the host respawns, then the client dies: the host is alive, nothing ends
live(hpawn)
die(rpawn)
hold_ticks(3)
check(beacon._valid, "the host respawned, the client died: one player alive, the horde goes on")
-- the host dies again (no longer bound: nothing from the game) - nobody alive
HW.outbox = {}
die(hpawn)
hold_ticks(1)
check(beacon._valid, "everybody dead: not at once (ALL_DEAD_S)")
local n_pick = #pickups
hold_ticks(1)
w = sent("HORDE")
check(#pickups == n_pick + 1 and pickups[#pickups]._valid, "everybody dead for 2 s: the game's Event_SpawnBeacon (its pickup)")
check(#w == 1 and w[1]:find("HORDE|over|4|2000|100|50|all", 1, true) ~= nil,
    "HORDE|over ... |all to the dead client (no Pawn: its place is its body's): " .. tostring(w[1]))
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300800: every player is dead: it turns back into its pickup, the"
    .. " horde is over %(1 client%(s%) told%)") ~= nil, "logged")
check(find_log("%[TOAST%] The horde stopped: every player is dead%.") ~= nil, "the host is told too (horde_over_all)")
check(beacon._valid, "the beacon still there until the removal (the game's own is held)")
game_time(0.3); run_timers()
check(not beacon._valid and pickups[#pickups]._valid, "removed by this module; its pickup stays (as in the game)")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300800 removed %(the game's own removal after a death is held%)") ~= nil,
    "logged")
live(hpawn); live(rpawn)
hold_ticks(1)

say("-- an idle beacon: kept while someone is alive; ends when everybody is dead")
local idle = new_beacon("Buildable_HordeBeacon_C_2147300801", 6500, false)
hold_ticks(1)
check(#delays == 2 and delays[2].wc == idle, "the idle beacon held too")
HW.outbox = {}
die(hpawn)
local p2 = game_spawn_beacon(idle)
check(#sent("HORDE") == 0, "idle: no HORDE message")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300801: the player the game ties it to died; 1 player%(s%) still"
    .. " alive: the beacon stays %(idle%)") ~= nil, "logged")
game_time(0.5); run_timers()
check(idle._valid and not p2._valid, "the idle beacon stays, its pickup taken back")
die(rpawn)
hold_ticks(2)
check(not idle._valid or #HW.timers > 0, "everybody dead: its end comes")
game_time(0.3); run_timers()
check(not idle._valid and pickups[#pickups]._valid, "the deferred idle beacon turns into its pickup, as at the first death in the game")
check(#sent("HORDE") == 0, "idle: still no HORDE message")
live(hpawn); live(rpawn)
hold_ticks(1)

say("-- no client connected: exactly the game")
HS.remote_pcs = {}
rpawn._p.Controller = nil          -- a client that left: its character goes
tick()
local solo = new_beacon("Buildable_HordeBeacon_C_2147300802", 2000, true, 1)
hold_ticks(2)
check(#delays == 2, "no client connected: not held")
local n3 = #LOG
die(hpawn)
local p3 = game_spawn_beacon(solo)
check(LATENT[solo][DEATH_UUID].fn ~= nil, "the game's 0.2 s removal is pending")
check(find_log("ai: horde: the player the game ties Buildable_HordeBeacon_C_2147300802 to died %(no player is alive%): it"
    .. " turns back into its pickup, the horde is over") ~= nil, "logged as the game's end")
check(find_log("%[TOAST%]", n3 + 1) == nil, "no notice of the mod on the host (the game's end says nothing)")
game_time(0.2); run_timers()
check(not solo._valid and p3._valid, "the game removed the beacon itself; its pickup stays")
live(hpawn)
HS.remote_pcs = { rpc }
rpawn._p.Controller = rpc
tick()

say("-- ai_horde_continue off: the game's end on a death (a held beacon: removed by this module)")
local b3 = new_beacon("Buildable_HordeBeacon_C_2147300803", 2000, true, 2)
hold_ticks(1)
check(#delays == 3 and delays[3].wc == b3, "held")
CFGO.ai_horde_continue = false
local b4 = new_beacon("Buildable_HordeBeacon_C_2147300804", 9000, false)
hold_ticks(1)
check(#delays == 3, "off: a new beacon is not held")
HW.outbox = {}
die(hpawn)
local p4 = game_spawn_beacon(b3)
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|over|3|2000|100|50|bound", 1, true) ~= nil, "HORDE|over ... |bound: " .. tostring(w[1]))
check(find_log("ai: horde: the player the game ties Buildable_HordeBeacon_C_2147300803 to died %(ai_horde_continue is off%)") ~= nil,
    "logged")
game_time(0.3); run_timers()
check(not b3._valid and p4._valid, "removed (the game's own removal held, ours instead); its pickup stays")
live(hpawn)
CFGO.ai_horde_continue = nil
b4._valid = false
hold_ticks(1)

say("-- the hold did not take: the game removes the beacon, its pickup stays")
delay_adds = false
local b5 = new_beacon("Buildable_HordeBeacon_C_2147300805", 2000, true, 0)
hold_ticks(1)
delay_adds = true
HW.outbox = {}
die(hpawn)
local p5 = game_spawn_beacon(b5)
check(#sent("HORDE") == 1, "taken for held: HORDE|kept")
HW.outbox = {}
game_time(0.3); run_timers()
check(not b5._valid and p5._valid, "the game removed it; its pickup stays (not taken back)")
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|over|1|2000|100|50|bound", 1, true) ~= nil, "the clients told the horde is over: " .. tostring(w[1]))
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300805: the game removed the beacon after all %(the hold did not take%)") ~= nil,
    "logged")
check(horde_line():find("hold lost=1", 1, true) ~= nil, "status: " .. horde_line())
live(hpawn)
hold_ticks(1)

say("-- ai_horde_beacon turned off: deferred ends come now; a held beacon still gets its removal")
local b6 = new_beacon("Buildable_HordeBeacon_C_2147300806", 2000, true, 0)
local b7 = new_beacon("Buildable_HordeBeacon_C_2147300807", 9000, false)
hold_ticks(1)
die(hpawn)
game_spawn_beacon(b6)
game_time(0.5); run_timers()
check(b6._valid, "kept (the client alive)")
live(hpawn)
CFGO.ai_horde_beacon = false
tick()
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300806: ai_horde_beacon was turned off: it turns back into its pickup") ~= nil,
    "turned off: the deferred end comes now")
game_time(0.3); run_timers()
check(not b6._valid, "removed")
HW.outbox = {}
die(hpawn)
local p7 = game_spawn_beacon(b7)
game_time(0.3); run_timers()
check(not b7._valid and p7._valid, "off, a held beacon's bound player died: removed as the game would (its pickup stays)")
check(#sent("HORDE") == 0, "off: nothing sent")
local b8 = new_beacon("Buildable_HordeBeacon_C_2147300808", 2000, true, 3)
fire(B .. "Event_NextWave", "bp", param(b8))
check(#sent("HORDE") == 0, "ai_horde_beacon off: nothing")
live(hpawn)
CFGO.ai_horde_beacon = nil
tick()
b8._p["HordeStarted?"] = false
fire(B .. "Event_NextWave", "bp", param(b8))
check(#sent("HORDE") == 0, "not started: Event_NextWave sends nothing (the game pops it too)")
b8._valid = false

say("-- the bound player dies last (nobody alive): the game's end at once")
local b9 = new_beacon("Buildable_HordeBeacon_C_2147300809", 2000, true, 4)
hold_ticks(1)
die(rpawn)
HW.outbox = {}
local n9 = #LOG
die(hpawn)
local p9 = game_spawn_beacon(b9)
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|over|5|2000|100|50|all", 1, true) ~= nil,
    "HORDE|over ... |all at once, to the dead client (its body near): " .. tostring(w[1]))
check(find_log("%[TOAST%] The horde stopped: every player is dead%.", n9 + 1) ~= nil, "the host is told too")
check(find_log("ai: horde: the player the game ties Buildable_HordeBeacon_C_2147300809 to died %(no player is alive%)") ~= nil,
    "logged")
game_time(0.3); run_timers()
check(not b9._valid and p9._valid, "removed by this module (the game's own is held); its pickup stays")
live(hpawn); live(rpawn)
hold_ticks(1)

say("-- someone's beacon item lying next to it is never taken back")
local b10 = new_beacon("Buildable_HordeBeacon_C_2147300810", 2000, true, 0)
local item = new(HW, { "BP_HordeBeaconPickup_C", "Actor" }, "BP_HordeBeaconPickup_C_2147300990",
    { Role = 3, _loc = { X = 2030, Y = 100, Z = 50 }, _born = T - 30 },
    { GetGameTimeSinceCreation = function(self) return T - self._p._born end })
hold_ticks(1)
die(hpawn)
-- the game's end without its pickup (its spawn failed): only the old item is near
add_latent(b10, DEATH_UUID, 0.2, function() b10._valid = false end)
fire(B .. "Event_SpawnBeacon", "bp", param(b10))
for _ = 1, 20 do game_time(0.25); run_timers() end
check(b10._valid and item._valid and p9._valid, "the beacon stays; the item dropped 30 s before and the one 4 s before are not taken")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300810 stays; no new pickup found next to it") ~= nil, "logged")
live(hpawn)
hold_ticks(1)

say("-- a beacon on its way out is never ended twice")
b10._valid = false
local b11 = new_beacon("Buildable_HordeBeacon_C_2147300811", 2000, true, 0)
hold_ticks(1)
die(hpawn)
game_spawn_beacon(b11)
game_time(0.5); run_timers()
check(b11._valid, "kept")
die(rpawn)
CFGO.ai_horde_continue = false
local n11 = #pickups
hold_ticks(3)            -- the end (setting off), then "everyone dead" ticks before the removal ran
check(#pickups == n11 + 1, "one end only: one pickup (" .. (#pickups - n11) .. ")")
game_time(0.3); run_timers()
check(not b11._valid, "removed")
CFGO.ai_horde_continue = nil
live(hpawn); live(rpawn)
hold_ticks(1)

say("-- a dead client (no character): its place is its body's; unknown, it still gets the end")
local b13 = new_beacon("Buildable_HordeBeacon_C_2147300813", 2000, true, 1)
hold_ticks(1)
die(rpawn)
HW.outbox = {}
fire(B .. "Event_NextWave", "bp", param(b13))
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|wave|2|", 1, true) ~= nil, "its body 40 m from the beacon: told of wave 2")
place(rpawn, 40000, 0, 0)
HW.outbox = {}
fire(B .. "Event_NextWave", "bp", param(b13))
check(#sent("HORDE") == 0, "its body 380 m from the beacon: not told")
place(rpawn, 6000, 0, 0)
RREC.pawn = nil                    -- the body gone (the game destroyed it): no place known
HW.outbox = {}
fire(B .. "Event_NextWave", "bp", param(b13))
check(#sent("HORDE") == 0, "no place known: a wave notice does not go")
die(hpawn)
local p13 = game_spawn_beacon(b13)
w = sent("HORDE")
check(#w == 1 and w[1]:find("HORDE|over|2|2000|100|50|all", 1, true) ~= nil,
    "no place known: the end notice goes all the same: " .. tostring(w[1]))
game_time(0.3); run_timers()
check(not b13._valid and p13._valid, "removed; its pickup stays")
RREC.pawn = rpawn
live(hpawn); live(rpawn)
hold_ticks(1)

say("-- a running horde whose presser has no living character: its new waves run to the nearest living player")
local scope = H.ctx.beacon_scope
check(type(scope) == "function", "ctx.beacon_scope set by sdc_horde (asked by sdc_world's beacon kind)")
local b12 = new_beacon("Buildable_HordeBeacon_C_2147300812", 2000, true, 1)
b12._p.CurrentActor = hpawn
place(hpawn, 1000, 0, 0)
place(rpawn, 6000, 0, 0)
check(scope(b12) == nil, "the host pressed it and is alive: no answer (sdc_world's build rule: the presser)")
die(hpawn)
check(scope(b12) == rpc, "the host pressed it and is dead: the client (the living player nearest to the beacon)")
check(find_log("ai: horde: Buildable_HordeBeacon_C_2147300812: the player who started it has no living character: its new"
    .. " zombies run to BP_PlayerController_C_1 %(the living player nearest to the beacon%)") ~= nil, "logged")
local n12 = #LOG
check(scope(b12) == rpc and find_log("Buildable_HordeBeacon_C_2147300812: the player who started", n12 + 1) == nil,
    "the same answer again: logged once")
live(hpawn)
hpawn._p["PlayerDead?"] = true     -- dead, its body not unpossessed yet (AfterDeath before @1387)
check(scope(b12) == rpc, "the presser dead but still possessed: the client all the same")
die(hpawn)
b12._p["HordeStarted?"] = false
check(scope(b12) == nil, "not started (its death binding 2 s after BeginPlay asks too): no answer, as before")
b12._p["HordeStarted?"] = true
CFGO.ai_horde_continue = false
check(scope(b12) == nil, "ai_horde_continue off: no answer (as in the game)")
CFGO.ai_horde_continue = nil
CFGO.ai_horde_beacon = false
tick()
check(scope(b12) == nil, "ai_horde_beacon off: no answer")
CFGO.ai_horde_beacon = nil
tick()
check(scope(b12) == rpc, "on again: the client")
die(rpawn)
check(scope(b12) == nil, "nobody alive: no answer")
live(hpawn); live(rpawn)
b12._p.CurrentActor = rpawn
check(scope(b12) == nil, "the client pressed it and is alive: no answer (the build rule: that client)")
die(rpawn)
check(scope(b12) == false, "the client pressed it and is dead, the host alive: false (player 0 stays the host)")
live(rpawn)
b12._p.CurrentActor = nil
die(hpawn)
check(scope(b12) == rpc, "no presser known, the host dead: the client")
live(hpawn)
HS.role = "client"
check(scope(b12) == nil, "not the host: no answer")
HS.role = "host"
b12._valid = false
hold_ticks(1)

say("")
for _, l in ipairs(H.ai.status_lines()) do say("  " .. l) end
check(find_log("%[ERROR%]") == nil, "no error lines")
print = real_print
say(string.format("ai wave host: %d checks, %d failed", checks, fails))
say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
