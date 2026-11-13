-- Mock harness: zombie AI in co-op, host side (2026-11-13):
--   ai_keep_chase       a zombie that loses sight of one player keeps chasing one it still sees
--   ai_spawn_check_all  spawners' "no spawn within 25 m of player 0" -> the living player nearest the point
--   ai_player_scaling   a zombie spawner's group grows with the living players within 140 m
--   world_infest_wave_target  an infestation's wave member goes for the last hitter / the nearest player
-- Real sdc_ctx, sdc_world, sdc_ai (+ features) against fake UE objects.
-- usage: lua mock_ai_coop_host.lua <scripts dir>
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
    m.world = require("sdc_world")
    m.ai = require("sdc_ai")
    return m
end
local H = load_mods()
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
H.ai.init(HS)
H.world._t.try_hooks(true)
local function tick()
    H.ctx.tick(HS.remote_pcs)
    H.ai.host_tick(HS.remote_pcs)
end
tick()

local G0 = "/Script/Engine.GameplayStatics:GetPlayerCharacter"
local GPC = "/Script/Engine.GameplayStatics:GetPlayerController"
-- the game's GetPlayerCharacter(wco, 0) through sdc_ctx's pre-hook: the index it ends with
local function player0(wco, fn)
    local idx = param(0)
    fire(fn or G0, "pre", param(gps), param(wco), idx)
    return idx._v()
end

say("== 0. features and hooks")
local lines = H.ai.status_lines()
check(lines[1]:find("chase=on", 1, true) and lines[1]:find("spawnnear=on", 1, true) and lines[1]:find("scale=on", 1, true)
    and lines[1]:find("optguard=off", 1, true), "chase / spawnnear / scale on, optguard off by default: " .. lines[1])
local CTRL = "/Game/AI/Zombies/BP_ZombieAIController.BP_ZombieAIController_C:PerceptionUpdate"
local KSLP = "/Script/Engine.KismetSystemLibrary:"
local SPAWNER = "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C:AddGroupToSpawn"
local INF = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
check(HW.hooks[CTRL] ~= nil and HW.hooks[SPAWNER] ~= nil, "host: PerceptionUpdate and AddGroupToSpawn hooked")
check(HW.hooks[KSLP .. "SphereOverlapActors"] ~= nil and HW.hooks[KSLP .. "SphereTraceMultiForObjects"] ~= nil,
    "host: the spawners' sphere queries hooked (natives)")
check(HW.hooks[G0] ~= nil and HW.hooks[INF .. ":LocToSpawn"] ~= nil, "player-0 hooks and the nest's LocToSpawn hooked")
check(H.ctx.spawn_scope ~= nil, "ctx.spawn_scope set by sdc_ai_spawnnear")

-- ===========================================================================
say("== 1. a zombie loses sight of one player and still sees another: it keeps chasing")
local SIGHT = new(HW, { "Class" }, "AISense_Sight", {}, {}, "/Script/AIModule.AISense_Sight")
local perceived = {}
local perc = new(HW, { "AIPerceptionComponent" }, "AIPerception_0", {}, {
    GetCurrentlyPerceivedActors = function(_, sense, out)
        assert(sense == SIGHT, "sight sense asked")
        for _, a in ipairs(perceived) do out[#out + 1] = param(a) end
    end,
})
local BB = {}
local bb = new(HW, { "BlackboardComponent" }, "BB_0", {}, {
    GetValueAsBool = function(_, key) return BB[key._s] == true end,
    SetValueAsBool = function(_, key, v) BB[key._s] = v end,
})
new(HW, { "AIBlueprintHelperLibrary" }, "Default__AIBlueprintHelperLibrary", {}, {
    GetBlackboard = function() return bb end,
}, "/Script/AIModule.Default__AIBlueprintHelperLibrary")
local zombie = new(HW, { "BP_Zombie_Roamer_C", "BP_MasterZombie_C" }, "BP_Zombie_Roamer_C_2147400001", { ["IsDead?"] = false })
local ctrl = new(HW, { "BP_ZombieRoamer_AIController_C", "BP_ZombieAIController_C" }, "BP_ZombieRoamer_AIController_C_1",
    { Pawn = zombie, AIPerception = perc, Combat = true })
-- what PerceptionUpdate's sight-lost branch (@541-984) leaves behind
local function lost_branch()
    BB["CanSeePlayer?"], BB["IsAlert?"] = false, true
    ctrl._p.Combat = false
end
-- sight stimuli keep strength 1 when lost; an expired damage stimulus has the damage
local function stim(sensed, tag, strength)
    return { bSuccessfullySensed = sensed, Tag = name_obj(tag or "None"), Strength = strength or 1.0 }
end
local function perception(actor, st)
    fire(CTRL, "bp", param(ctrl), param(actor), param(st))
end
place(hpawn, 300, 0, 0)
place(rpawn, 900, 0, 0)
lost_branch()
perceived = { hpawn }            -- the client left its sight, the host is still in front of it
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == true and BB["IsAlert?"] == false and ctrl._p.Combat == true,
    "CanSeePlayer? and Combat back, IsAlert? off")
check(find_log("ai: chase: BP_Zombie_Roamer_C_2147400001 lost sight of BP_PlayerCharacter_C_1 but still sees BP_PlayerCharacter_C_0: keeps chasing") ~= nil,
    "logged with the zombie, the lost and the seen player")
lost_branch()
perceived = {}
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false and BB["IsAlert?"] == true and ctrl._p.Combat == false, "nobody else seen: the game's branch stays")
local bandit = new(HW, { "BP_Bandit_Melee_C" }, "BP_Bandit_Melee_C_2147400002", {})
bandit._tags.ZombieCanAttack, bandit._tags.Dead = true, true
perceived = { bandit, rpawn }    -- (the lost one is skipped even if still listed)
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false and ctrl._p.Combat == false, "a dead bandit (tag Dead) and the lost player: no chase")
-- a scavenger's Death keeps ZombieCanAttack and adds no 'Dead' tag: the game's
-- "AI Is Dead?" reads BP_AIComponent.Dead (BP_MasterAICharacter:91)
local scav_ai = new(HW, { "BP_AIComponent_C" }, "BP_AIComponent_2147400003", { Dead = true })
local scav = new(HW, { "BP_Scavenger_Melee_C", "BP_MasterScavenger_C", "BP_MasterAICharacter_C" },
    "BP_Scavenger_Melee_C_2147400003", { BP_AIComponent = scav_ai })
scav._tags.ZombieCanAttack = true
perceived = { scav }
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false and BB["IsAlert?"] == true and ctrl._p.Combat == false,
    "a dead scavenger (ZombieCanAttack, no tag Dead, BP_AIComponent.Dead): no chase, the game's branch stays")
local dead_p = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_9", { ["PlayerDead?"] = true })
dead_p._tags.ZombieCanAttack = true
local boss = new(HW, { "BP_ZombieBoss_Juggernaut_C" }, "BP_ZombieBoss_Juggernaut_C_2147400004", { ["IsDead?"] = true })
boss._tags.ZombieCanAttack = true
local wolf = new(HW, { "BP_AnimalWolf_C", "BP_Animal_C" }, "BP_AnimalWolf_C_2147400005", { Dead = true })
wolf._tags.ZombieCanAttack = true
perceived = { dead_p, boss, wolf }
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false and ctrl._p.Combat == false,
    "a dead player (PlayerDead?), a dead boss (IsDead?), a dead animal (Dead) without the tag: no chase")
scav_ai._p.Dead = false
perceived = { scav }
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == true and ctrl._p.Combat == true, "the same scavenger alive: kept chasing")
for _, o in ipairs({ scav, dead_p, boss, wolf }) do o._valid = false end   -- not in the later sections
lost_branch()
perceived = { hpawn }
perception(rpawn, stim(false, nil, 35))
check(BB["CanSeePlayer?"] == false and BB["IsAlert?"] == true and ctrl._p.Combat == false,
    "an expired damage stimulus (Tag None, strength 35) with a living player in sight: untouched")
perception(rpawn, stim(false, "Noise"))
check(BB["CanSeePlayer?"] == false, "a hearing stimulus: untouched")
perception(rpawn, stim(true))
check(BB["CanSeePlayer?"] == false, "a sensed stimulus: untouched (the game's own branch)")
ctrl._p.Combat = true
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false, "Combat still on (the lost branch did not run): untouched")
lost_branch()
zombie._p["IsDead?"] = true
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false, "a dead zombie: untouched")
zombie._p["IsDead?"] = false
HS.remote_pcs = {}
tick()
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == false, "no client connected (single player): untouched")
HS.remote_pcs = { rpc }
tick()
perception(rpawn, stim(false))
check(BB["CanSeePlayer?"] == true and ctrl._p.Combat == true, "client back: kept again")
check(H.ai.status_lines()[1] ~= nil and H.ai_status == nil, "status lines build")

-- ===========================================================================
say("== 3. spawn checks: the living player nearest to the spawn point stands for player 0")
local zsp = new(HW, { "BP_AISpawner_Zombies_C", "BP_AISpawner_Master_C", "Actor" }, "BP_AISpawner_Zombies_C_12", {})
place(zsp, 0, 0, 0)
place(hpawn, -3000, 0, 0)     -- host 30 m from the spawner
place(rpawn, 2000, 0, 0)      -- client 20 m from it, at the spawn point's side
advance(5)
tick()
check(player0(zsp) == 0, "no query: the spawner's player-0 call stays the host's")
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(zsp), param({ X = 1500, Y = 0, Z = 0 }), param(2500))
check(player0(zsp) == 1, "SphereOverlapActors at a point 5 m from the client: GetPlayerCharacter -> the client")
check(player0(zsp) == 1, "every call of the same query (one per actor found)")
check(player0(zsp, GPC) == 0, "GetPlayerController of the spawner: not touched")
check(find_log("ai: spawn check: BP_AISpawner_Zombies_C_12 checks its spawn point 1500,0,0 against BP_PlayerCharacter_C_1") ~= nil,
    "logged once per query")
-- one query, a GetPlayerCharacter call per actor it found: the nearest player is searched once
local lp_n, lp0 = 0, H.ctx.live_players
H.ctx.live_players = function(...) lp_n = lp_n + 1; return lp0(...) end
advance(0.5)
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(zsp), param({ X = 1600, Y = 0, Z = 0 }), param(2500))
local all_client = true
for _ = 1, 6 do if player0(zsp) ~= 1 then all_client = false end end
check(all_client and lp_n == 1, "6 calls of one query: the client every time, the players looked up once (" .. lp_n .. ")")
local zsp2 = new(HW, { "BP_AISpawner_Zombies_C", "BP_AISpawner_Master_C", "Actor" }, "BP_AISpawner_Zombies_C_13", {})
place(zsp2, -2900, 0, 0)
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(zsp2), param({ X = -2900, Y = 0, Z = 0 }), param(2500))
check(player0(zsp2) == 0 and player0(zsp2) == 0 and lp_n == 2, "another spawner's query in the same frame: its own answer (the host), looked up once more (" .. lp_n .. ")")
advance(0.05)
check(player0(zsp) == 1 and lp_n == 3, "the first query's later call (50 ms on, still within its 0.25 s): looked up again (" .. lp_n .. ")")
H.ctx.live_players = lp0
advance(1)
check(player0(zsp) == 0, "a second later (no fresh query): the host again")
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(zsp), param({ X = -2800, Y = 0, Z = 0 }), param(2500))
check(player0(zsp) == 0, "a point next to the host: the host (false, no redirect)")
advance(1)
rpawn._p["PlayerDead?"] = true
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(zsp), param({ X = 1900, Y = 0, Z = 0 }), param(2500))
check(player0(zsp) == 0, "the client is dead: the nearest living player (the host)")
rpawn._p["PlayerDead?"] = nil
-- camps and their AI volumes: SphereTraceMultiForObjects
local psp = new(HW, { "BP_PrefabSpawner_Dynamic_C", "BP_PrefabSpawner_C", "Actor" }, "BP_PrefabSpawner_Dynamic_C_3", {})
place(psp, 2100, 0, 0)
advance(1)
tick()
fire(KSLP .. "SphereTraceMultiForObjects", "pre", param(ksl), param(psp), param({ X = 2100, Y = 0, Z = 0 }),
    param({ X = 2100, Y = 0, Z = 0 }), param(2500))
check(player0(psp) == 1, "CheckSurroundingArea of a prefab spawner next to the client: the client")
advance(3)
check(player0(psp) == 0, "its DistanceToPrefab later (no query): the host's, as before")
local vol = new(HW, { "BP_AISpawningVolume_Prefab_C", "Actor" }, "BP_AISpawningVolume_Prefab_C_2147400010", {})
fire(KSLP .. "SphereTraceMultiForObjects", "pre", param(ksl), param(vol), param({ X = 1800, Y = 300, Z = 0 }),
    param({ X = 1800, Y = 300, Z = 0 }), param(2500))
check(player0(vol) == 1, "a camp's AI volume: the client")
local other = new(HW, { "BP_Grenade_C", "Actor" }, "BP_Grenade_C_5", {})
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(other), param({ X = 2000, Y = 0, Z = 0 }), param(600))
check(player0(other) == 0, "another object's sphere query: nothing recorded, nothing changed")
CFGO.ai_spawn_check_all = false
advance(2)
tick()
fire(KSLP .. "SphereOverlapActors", "pre", param(ksl), param(zsp), param({ X = 1500, Y = 0, Z = 0 }), param(2500))
check(player0(zsp) == 0, "ai_spawn_check_all off: the host")
CFGO.ai_spawn_check_all = nil
advance(2)
tick()

-- ===========================================================================
say("== 4. player-count scaling of a zombie spawner's group")
local added = {}
local roamer_cls = new(HW, { "BlueprintGeneratedClass" }, "BP_Zombie_Roamer_C", {})
local function spawner(name, amount, cls, at)
    local sp
    sp = new(HW, { "BP_AISpawner_Zombies_C", "BP_AISpawner_Master_C", "Actor" }, name,
        { SpawnAmount = amount, SpawnedActorClass = cls, TotalSpawnedActors = 0 }, {
            -- the game's custom event; a Lua call of a hooked function runs its hook too
            AddGroupToSpawn = function(self, n)
                added[#added + 1] = { sp = self, n = n }
                fire(SPAWNER, "bp", param(self), param(n))
            end,
        })
    place(sp, at or 0, 0, 0)
    return sp
end
local function group(sp, n)   -- the game's own call (CheckStartSpawningWithRadius @1895)
    added = {}
    fire(SPAWNER, "bp", param(sp), param(n))
    return added
end
local s1 = spawner("BP_AISpawner_Zombies_C_20", 5, roamer_cls, 0)
place(hpawn, 1000, 0, 0)
place(rpawn, 5000, 0, 0)
local a = group(s1, 5)
check(#a == 1 and a[1].n == 2, "2 players within 140 m: 5 -> 7 (x1.35): one more group of 2 (" .. tostring(a[1] and a[1].n) .. ")")
check(find_log("ai: scaling: BP_AISpawner_Zombies_C_20 spawns 7 BP_Zombie_Roamer_C instead of 5: 2 living players within 140 m %(x1.35%)") ~= nil,
    "logged")
place(rpawn, 20000, 0, 0)
check(#group(s1, 5) == 0, "the client 200 m away: the game's group only")
place(rpawn, 5000, 0, 0)
check(#group(s1, 1) == 0, "a killed zombie's single respawn (1 != SpawnAmount): not scaled")
local s2 = spawner("BP_AISpawner_Zombies_C_21", 1, roamer_cls, 0)
check(#group(s2, 1) == 0, "SpawnAmount 1: not scaled (a respawn looks the same)")
local boss_cls = new(HW, { "BlueprintGeneratedClass" }, "BP_ZombieBoss_Juggernaut_C", {})
local deer_cls = new(HW, { "BlueprintGeneratedClass" }, "BP_AnimalDeer_C", {})
check(#group(spawner("BP_AISpawner_ZombieBosses_C_1", 3, boss_cls, 0), 3) == 0, "a boss spawner: not scaled")
check(#group(spawner("BP_AISpawner_Animals_C_1", 4, deer_cls, 0), 4) == 0, "an animal spawner: not scaled")
-- two more living players in range: x2.05 capped at x2
local more = {}
for i = 2, 3 do
    local c2 = new(HW, { "IpConnection" }, "IpConnection_" .. i)
    local p2 = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. i, { _loc = { X = 3000, Y = i * 100, Z = 0 } })
    local pc2 = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. i,
        { NetConnection = c2, Player = c2, Pawn = p2 })
    p2._p.Controller = pc2
    more[#more + 1] = p2
end
advance(1)
a = group(s1, 5)
check(#a == 1 and a[1].n == 5, "4 players: x2.05 capped at x2: 5 more (" .. tostring(a[1] and a[1].n) .. ")")
more[1]._p["PlayerDead?"] = true
advance(1)
a = group(s1, 5)
check(#a == 1 and a[1].n == 4, "one of them dead: 3 living players, x1.7: 5 -> 9 (" .. tostring(a[1] and a[1].n) .. ")")
for _, p in ipairs(more) do p._valid = false end
advance(1)
CFGO.ai_player_scaling_pct = 50
a = group(s1, 5)
check(#a == 1 and a[1].n == 3, "ai_player_scaling_pct 50, 2 players: 5 -> 8 (" .. tostring(a[1] and a[1].n) .. ")")
CFGO.ai_player_scaling_cap_pct = 120
a = group(s1, 5)
check(#a == 1 and a[1].n == 1, "cap 120 %: 5 -> 6 (" .. tostring(a[1] and a[1].n) .. ")")
CFGO.ai_player_scaling_pct, CFGO.ai_player_scaling_cap_pct = nil, nil
CFGO.ai_player_scaling = false
advance(1)
tick()
check(#group(s1, 5) == 0, "ai_player_scaling off: the game's group only")
CFGO.ai_player_scaling = nil
tick()
HS.remote_pcs = {}
tick()
check(#group(s1, 5) == 0, "no client connected: the game's group only")
HS.remote_pcs = { rpc }
tick()
check(s1._p.SpawnAmount == 5, "SpawnAmount never written")
-- the players counted are those within the spawner's own SpawnRadius (where its group starts;
-- level prefabs set their own, e.g. 75 m), not within a fixed 140 m
place(hpawn, 1000, 0, 0)
place(rpawn, 10000, 0, 0)     -- the client 100 m from the spawner
local s3 = spawner("BP_AISpawner_Zombies_C_22", 5, roamer_cls, 0)
s3._p.SpawnRadius = 7500
check(#group(s3, 5) == 0, "SpawnRadius 75 m, the client 100 m away: not counted, the game's group only")
s3._p.SpawnRadius = 12000
a = group(s3, 5)
check(#a == 1 and a[1].n == 2
    and find_log("BP_AISpawner_Zombies_C_22 spawns 7 BP_Zombie_Roamer_C instead of 5: 2 living players within 120 m %(x1.35%)") ~= nil,
    "SpawnRadius 120 m: the client counted, logged with the spawner's radius")
place(rpawn, 18000, 0, 0)     -- 180 m
s3._p.SpawnRadius = 20000
a = group(s3, 5)
check(#a == 1 and a[1].n == 2, "SpawnRadius 200 m, the client 180 m away (beyond the old fixed 140 m): counted")
s3._p.SpawnRadius = 0
check(#group(s3, 5) == 0, "SpawnRadius unreadable (0): the default 140 m, the client 180 m away not counted")
place(rpawn, 5000, 0, 0)

-- ===========================================================================
say("== 7. infestation waves: the last hitter while alive within 150 m, else the nearest living player")
local function nest(name, at)
    local n = new(HW, { "BP_Infestation_C" }, name, { ["IsDestroyed?"] = false, _loc = at })
    return n
end
local n1 = nest("BP_Infestation_C_31", { X = 0, Y = 0, Z = 0 })
place(hpawn, 3000, 0, 0)      -- host 30 m
place(rpawn, 8000, 0, 0)      -- client 80 m
advance(2)
tick()
H.world.tick()
check(player0(n1) == 0, "a living nest's player-0 call (health bar ...): the host, as before")
-- the client hits it (a shot from the client: WDMG on the host -> remember_hit)
fire(INF .. ":Damage_Object", "bp", param(n1), param(10), param(rpawn))
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1, GPC) == 0, "GetPlayerController right after LocToSpawn (its HUD): not touched")
check(player0(n1) == 1, "the wave member's GetPlayerCharacter: the client (the last hitter, 80 m)")
check(find_log("world: infestation BP_Infestation_C_31 sends its wave member at BP_PlayerCharacter_C_1 %(the last to hit it, 80 m from the nest%)") ~= nil,
    "logged")
check(player0(n1) == 0, "only the one call right after LocToSpawn")
place(rpawn, 20000, 0, 0)     -- the hitter 200 m away
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 0, "the hitter beyond 150 m: the nearest living player (the host)")
check(find_log("sends its wave member at BP_PlayerCharacter_C_0 %(the nearest living player, 30 m") ~= nil, "logged as the nearest")
place(rpawn, 8000, 0, 0)
fire(INF .. ":Damage_Object", "bp", param(n1), param(10), param(hpawn))   -- now the host hit it last
hpawn._p["PlayerDead?"] = true
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 1, "the host hit last but is dead: the nearest living player (the client)")
hpawn._p["PlayerDead?"] = nil
fire(INF .. ":LocToSpawn", "bp", param(n1))
advance(1)
check(player0(n1) == 0, "a LocToSpawn mark older than 0.5 s: nothing")
CFGO.world_infest_wave_target = false
fire(INF .. ":Damage_Object", "bp", param(n1), param(10), param(rpawn))
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 0, "world_infest_wave_target off: the host")
CFGO.world_infest_wave_target = nil
CFGO.world_sync = false
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 0, "world_sync off (every world_* option off): the host")
CFGO.world_sync = nil
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 1, "both on again: the client (last hitter)")
-- a hit from no player is no hit by the host: the wave goes for the player nearest to the nest.
-- In the game the one such hit is a grenadier zombie's death blast (BP_MasterZombie @3740:
-- PhysicsBody actors within 6 m, a nest among them -> @4465 Damage_Object(dmg, self, None)).
-- Landmines and barrels cannot hit a nest (they look for Characters only); every player weapon
-- passes the player's character.
place(hpawn, 10000, 0, 0)     -- host 100 m (alive, within 150 m)
place(rpawn, 2000, 0, 0)      -- client 20 m (also the last hitter so far)
local burst = new(HW, { "BP_Zombie_Roamer_C", "BP_MasterZombie_C" }, "BP_Zombie_Roamer_C_2147400051", { _loc = { X = 200, Y = 0, Z = 0 } })
local mark = #LOG + 1
fire(INF .. ":Damage_Object", "bp", param(n1), param(80), param(burst))
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 1, "a grenadier zombie's blast hit it last: the nearest living player (the client, 20 m), not the host")
check(find_log("sends its wave member at BP_PlayerCharacter_C_1 %(the nearest living player, 20 m", mark) ~= nil,
    "logged as the nearest (not as the last hitter)")
fire(INF .. ":Damage_Object", "bp", param(n1), param(10), param(hpawn))
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 0, "the host's own character hit it last: the host (100 m, alive), though the client is nearer")
check(find_log("sends its wave member at BP_PlayerCharacter_C_0 %(the last to hit it, 100 m", mark) ~= nil, "logged as the last hitter")
-- any other causer that is no player's character (an unknown source) replaces the host's hit the same way
local other = new(HW, { "BP_Unknown_C", "Actor" }, "BP_Unknown_C_2147400050", { _loc = { X = 300, Y = 0, Z = 0 } })
mark = #LOG + 1
fire(INF .. ":Damage_Object", "bp", param(n1), param(100), param(other))
fire(INF .. ":LocToSpawn", "bp", param(n1))
check(player0(n1) == 1, "after the host's hit, a non-player unknown source hit it last: the nearest living player (the client)")
check(find_log("sends its wave member at BP_PlayerCharacter_C_1 %(the nearest living player, 20 m", mark) ~= nil, "logged as the nearest")

say("")
for _, l in ipairs(H.ai.status_lines()) do say("  " .. l) end
check(find_log("%[ERROR%]") == nil, "no error lines")
print = real_print
say(string.format("ai coop host: %d checks, %d failed", checks, fails))
say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
