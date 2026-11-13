-- Mock harness: zombie AI in co-op, client side (2026-11-13):
--   ai_client_optimizer_guard  host AI copies kept from this client's AI optimizer while it is dead (test feature, off)
--   cheaper client sync        looks pass time budget, per-zombie lines info -> debug (core.line),
--                              sdc_ai_ghosts' spawners table pruned
-- Real sdc_ai core + modules against fake UE objects, one world for the host and one for the client.
-- usage: lua mock_ai_coop_client.lua <scripts dir>
-- (harness core copied from mock_zombie_sync.lua)
local SCRIPTS = assert(arg[1], "scripts dir")
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local LOG = {}
local real_print = print
print = function(s)
    LOG[#LOG + 1] = s
    real_print((tostring(s):gsub("\n$", "")))
end
local function say(s) real_print(s) end
local function find_log(pat, from)
    for i = from or 1, #LOG do if LOG[i]:find(pat) then return LOG[i], i end end
    return nil
end

local fails = 0
local function check(cond, what)
    if cond then say("  ok   " .. what) else say("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- fake objects
local WORLD
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    return rawget(t, "_m")[k]
end
local next_id = 4096
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_of(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods)
    next_id = next_id + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_id,
                             _valid = true, _tags = {}, _full = nil, _w = w }, Obj)
    w.objects[#w.objects + 1] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_of(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:GetInstigatorController() return nil end
function Obj:ActorHasTag(fn) return self._tags[fn._s] == true end
function Obj:IsA(cls) for _, c in ipairs(self._chain) do if c == cls._cname then return true end end return false end
function Obj:K2_DestroyComponent() self._valid = false; self._destroyed = true end

local function derives(o, cname)
    for _, c in ipairs(o._chain) do if c == cname then return true end end
    return false
end

local function asset(w, cls, path)
    local o = new(w, { cls }, path:match("([^%.]+)$"))
    o._full = cls .. " " .. path
    w.paths[path] = o
    return o
end

local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end

-- ---------------------------------------------------------------- UE4SS globals
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
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
LOADS = 0
LoadAsset = function(path) LOADS = LOADS + 1; return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(ms, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, mods = {} }
end
local HW, CW = world("host"), world("client")

-- each world keeps its own module instances
local function enter(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    for k, v in pairs(w.mods) do package.loaded[k] = v end
end
local function leave(w)
    for k, v in pairs(package.loaded) do if k:match("^sdc_") then w.mods[k] = v end end
end

local function run_timers(w)
    enter(w)
    local t = w.timers
    w.timers = {}
    for _, fn in ipairs(t) do fn() end
    leave(w)
end

-- a hook as UE4SS calls it: BP hooks one callback; natives pre / post
local function fire(w, path, kind, ...)
    enter(w)
    local hs = w.hooks[path]
    if not hs then leave(w); return false end
    for _, h in ipairs(hs) do
        local fn = (kind == "post") and h.post or h.pre
        if fn then
            local r = fn(...)
            assert(r == nil, "hook returned a value: " .. path)
        end
    end
    leave(w)
    return true
end

local CLASS_PATHS = {
    ["/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"] = "BP_MasterZombie_C",
    ["/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C"] = "BP_ZombieBoss_C",
    ["/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C"] = "BP_MasterBandit_C",
    ["/Game/AI/Animals/BP_Animal.BP_Animal_C"] = "BP_Animal_C",
    ["/Script/Engine.Pawn"] = "Pawn",
    ["/Script/Engine.SkeletalMeshComponent"] = "SkeletalMeshComponent",
    ["/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C"] = "BP_AISpawner_Master_C",
    ["/Game/AI/Other/BP_MainEnemy.BP_MainEnemy_C"] = "BP_MainEnemy_C",
    ["/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C"] = "BP_MasterAICharacter_C",
    ["/Game/AI/Other/BP_MainFriendly.BP_MainFriendly_C"] = "BP_MainFriendly_C",
}

local function engine(w, is_server)
    for path, cname in pairs(CLASS_PATHS) do
        local c = new(w, { "Class" }, cname)
        c._cname = cname
        w.paths[path] = c
    end
    w.timer_cleared = {}
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "Default__KismetSystemLibrary", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
        GetConsoleVariableBoolValue = function() return false end,
        IsValid = function(_, o) return o ~= nil and o._valid and not o._pending_kill end,
        K2_ClearTimer = function(_, o, fname) w.timer_cleared[#w.timer_cleared + 1] = fname end,
        SphereOverlapActors = function(_, wc, loc, r, types, cls, ignore, out)
            assert(type(out) == "table" and type(types) == "table" and type(ignore) == "table", "overlap params")
            for _, o in ipairs(w.objects) do
                local l = o._valid and o._p._loc
                if l and derives(o, cls._cname) then
                    local dx, dy, dz = l.X - loc.X, l.Y - loc.Y, l.Z - loc.Z
                    if dx * dx + dy * dy + dz * dz <= r * r then out[#out + 1] = param(o) end
                end
            end
        end,
    })
    w.paths["/Script/Engine.Default__GameplayStatics"] = new(w, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
        GetAllActorsOfClass = function(_, wc, cls, out)
            assert(type(out) == "table", "out param")
            for _, o in ipairs(w.objects) do
                if o._valid and not o._pending_kill and derives(o, cls._cname) then out[#out + 1] = param(o) end
            end
        end,
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
    })
    for _, p in ipairs({ "/Game/AI/Zombies/SK_A.SK_A", "/Game/AI/Zombies/SK_B.SK_B", "/Game/AI/Zombies/SK_C.SK_C" }) do
        asset(w, "SkeletalMesh", p)
    end
    for _, p in ipairs({ "/Game/AI/Zombies/M_A.M_A", "/Game/AI/Zombies/M_B.M_B" }) do asset(w, "Material", p) end
    w.bs_walk = asset(w, "BlendSpace1D", "/Game/AI/Zombies/ZombieAILocomotion.ZombieAILocomotion")
    w.bs_crawl = asset(w, "BlendSpace1D", "/Game/AI/Zombies/CrawlerAILocomotion.CrawlerAILocomotion")
    w.emerge = asset(w, "AnimMontage", "/Game/AI/Zombies/Zombie_EmergeAnim.Zombie_EmergeAnim")
    asset(w, "DamageType", "/Game/Blueprints/DT_Bullet.DT_Bullet")
end
engine(HW, true)
engine(CW, false)

local function players(w)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp, ZombieKills = 0 }, {
        ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character", "Pawn" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 90 } })
    pawn._tags.Player = true
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
players(HW)
players(CW)

-- the remote player's controller on the host
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character", "Pawn" }, "BP_PlayerCharacter_C_1", { _loc = { X = 500, Y = 0, Z = 90 } })
rpawn._tags.Player = true
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end,
        ClientRepObjRef = function(_, obj) HW.outbox[#HW.outbox + 1] = { obj = obj } end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

local NETMAP = {}      -- host zombie -> its client copy

-- ---------------------------------------------------------------- zombies
local function make_zombie(w, role, o)
    o = o or {}
    local chain = o.chain or { "BP_Zombie_Roamer_C", "BP_MasterZombie_C", "BP_Zombie_C", "BP_MainEnemy_C", "Character", "Pawn" }
    local id = next_id
    local anim = new(w, { "AnimBP_Zombie_C" }, "AnimBP_Zombie_C_" .. id, { ["Movement Blendspace"] = w.bs_walk }, {
        SetBlendspace = function(self, bs) self._p["Movement Blendspace"] = bs; self._setbs = true end,
        GetCurrentActiveMontage = function(self) return self._montage end,
        Montage_Stop = function(self, t, m) if self._montage == m then self._montage = nil; self._stopped = true end end,
    })
    local hidden = {}
    local mesh = new(w, { "SkeletalMeshComponent" }, "CharacterMesh0_" .. id, {
            SkeletalMeshAsset = w.paths[o.mesh or "/Game/AI/Zombies/SK_A.SK_A"],
            RelativeLocation = { X = 0, Y = 0, Z = -75 }, RelativeRotation = { Pitch = 0, Yaw = -90, Roll = 0 },
            VisibilityBasedAnimTickOption = 2 }, {
        GetMaterial = function(self) return self._mat end,
        SetMaterial = function(self, i, m) self._mat = m end,
        SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a end,
        IsBoneHiddenByName = function(_, fn) return hidden[fn._s] == true end,
        HideBoneByName = function(_, fn) hidden[fn._s] = true end,
        UnHideBoneByName = function(_, fn) hidden[fn._s] = nil end,
        GetAnimInstance = function() return anim end,
        K2_SetRelativeLocationAndRotation = function(self, l, r, sweep, hit, tp)
            assert(type(hit) == "table", "hit out param")
            self._p.RelativeLocation = { X = l.X, Y = l.Y, Z = l.Z }
        end,
        K2_GetComponentLocation = function(self)
            local zl, r = self._p._owner._p._loc, self._p.RelativeLocation
            return { X = zl.X + r.X, Y = zl.Y + r.Y, Z = zl.Z + r.Z }
        end,
    })
    local mid = new(w, { "MaterialInstanceDynamic" }, "MID_" .. id, { Parent = w.paths[o.mat or "/Game/AI/Zombies/M_A.M_A"] })
    mesh._mat = mid
    local cap = new(w, { "CapsuleComponent" }, "CollisionCylinder_" .. id, { CapsuleHalfHeight = 75 }, {
        SetCapsuleHalfHeight = function(self, hh, upd) self._p.CapsuleHalfHeight = hh end,
    })
    local dc = new(w, { "DamageComponent_C" }, "DamageComponent_" .. id, {})
    local z = new(w, chain, chain[1] .. "_" .. (2147480000 + id), {
            Role = role, Mesh = mesh, CapsuleComponent = cap, DamageComponent = dc, Name = FText(o.name or "Undead"),
            ["IsDead?"] = false, _loc = o.loc or { X = 1000, Y = 0, Z = 75 },
            BaseTranslationOffset = { X = 0, Y = 0, Z = -75 },
            CrawlerArchetypeChance = 10, SprinterArchetypeChance = 10, UltraRadiatedArchetypeChance = 5,
            AcidicArchetypeChance = 5, GrenadierArchetypeChance = 5, ScreamerArchetypeChance = 5,
        }, {
            CacheInitialMeshOffset = function(self, l, r) self._p.BaseTranslationOffset = { X = l.X, Y = l.Y, Z = l.Z }; self._cached = r end,
            Event_EyesCallback = function(self) self._eyes = true end,
        })
    mesh._p._owner, dc._p._owner, cap._p._owner, anim._p._owner = z, z, z, z
    z._hidden, z._anim, z._mesh, z._cap, z._dc = hidden, anim, mesh, cap, dc
    return z
end

-- what Archetype_Crawler does on the machine that runs it
local function make_crawler(w, z, legs)
    z._cap._p.CapsuleHalfHeight = 40
    z._p._loc.Z = z._p._loc.Z - 35
    z._mesh._p.RelativeLocation = { X = -3, Y = 0, Z = -32 }
    for _, b in ipairs(legs or { "calf_l", "Foot_R" }) do z._hidden[b] = true end
    z._anim._p["Movement Blendspace"] = w.bs_crawl
    z._p.Name = FText("Undead Crawler")
end

-- ---------------------------------------------------------------- modules per world
local MODS = { "sdc_log", "sdc_ue", "sdc_net", "sdc_config", "sdc_ctx", "sdc_ai", "sdc_ai_zombie", "sdc_ai_looks" }
local OFF = { "ai_kill_credit", "ai_attack_montages", "ai_corpses", "ai_healthbar", "ai_offscreen_combat",
              "ai_keep_chase", "ai_spawn_check_all", "ai_player_scaling" }
local function load_mods(w)
    enter(w)
    local m = {}
    for _, name in ipairs(MODS) do m[name:gsub("^sdc_", "")] = require(name) end
    for _, k in ipairs(OFF) do m.config.values[k] = false end
    m.config.values.player_name = "Boss"
    leave(w)
    return m
end
local H = load_mods(HW)
local C = load_mods(CW)
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc:GetFullName()] = { name = "guest", pc = rpc } } }
local CS = { role = "client", remote_pcs = {}, remote = {} }
enter(HW); H.ai.init(HS); H.ai.register_handlers(); leave(HW)
enter(CW); C.ai.init(CS); C.ai.register_handlers(); leave(CW)

local OBJREF = "/Script/Engine.PlayerController:ClientRepObjRef"

local function deliver()
    local n = 0
    for _ = 1, 4 do
        local out = HW.outbox
        HW.outbox = {}
        enter(CW)
        for _, item in ipairs(out) do
            n = n + 1
            if type(item) == "string" then
                local kind, f = C.net.decode(item)
                local h = C.net.handlers[kind]
                if h then h(f, CW.pc) end
            else
                leave(CW)
                fire(CW, OBJREF, "pre", param(CW.pc), param(NETMAP[item.obj]))
                enter(CW)
            end
        end
        leave(CW)
        out = CW.outbox
        CW.outbox = {}
        enter(HW)
        for _, msg in ipairs(out) do
            n = n + 1
            local kind, f = H.net.decode(msg)
            local h = H.net.handlers[kind]
            if h then h(f, rpc) end
        end
        leave(HW)
    end
    return n
end

local function host_tick(list) enter(HW); H.ai.host_tick(list or { rpc }); leave(HW) end
local function client_tick() enter(CW); C.ai.client_tick(); leave(CW) end
local function msgs(w, pat)
    local out = {}
    for _, m in ipairs(w.outbox) do if type(m) == "string" and m:find(pat, 1, true) then out[#out + 1] = m end end
    return out
end

local ZM = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:"
local DESPAWN = "/Script/AIOptimizer.AIOptimizerSubsystem:K2_DespawnSubject"
local function client_mod(name) return CW.mods[name] end

-- ===========================================================================
say("== A. ai_client_optimizer_guard: off by default")
host_tick()
client_tick()
enter(CW)
local cl = C.ai.status_lines()[1]
leave(CW)
check(cl:find("optguard=off", 1, true) ~= nil, "off by default: " .. cl)
check(CW.hooks[DESPAWN] == nil, "no K2_DespawnSubject hook while off")
-- the guard's own game-thread loop (sdc_session's client ticks stop on the death screen)
local LOOPS = {}
local loop_api = LoopInGameThreadWithDelay
LoopInGameThreadWithDelay = function(ms, fn) LOOPS[#LOOPS + 1] = { ms = ms, fn = fn, w = WORLD }; return #LOOPS end
enter(CW); C.config.values.ai_client_optimizer_guard = true; leave(CW)
client_tick()
LoopInGameThreadWithDelay = loop_api
check(CW.hooks[DESPAWN] ~= nil, "on: K2_DespawnSubject evidence hook (client)")
local og_loop = LOOPS[1]
check(#LOOPS == 1 and og_loop.ms == 1000 and og_loop.w == CW, "on: the guard's own 1 s game-thread loop")
local function guard_loop() enter(CW); og_loop.fn(); leave(CW) end
local HUMAN_BEGIN = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C:ReceiveBeginPlay"
check(CW.hooks[ZM .. "ReceiveBeginPlay"] ~= nil and CW.hooks[HUMAN_BEGIN] ~= nil
    and CW.hooks["/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C:ReceiveBeginPlay"] ~= nil,
    "on: BeginPlay hooks of the zombie, boss and Smart AI human masters (client)")

-- host copies with the optimizer's subject component
local switches = {}
local function subject(owner, with_setter)
    local comp = new(CW, { "AIOSubjectComponent" }, "AIOSubject_" .. owner._name, { bCanBeUpdatedBySubsystem = true, _owner = owner })
    if with_setter ~= false then
        comp._m.SetCanBeUpdatedBySubsystem = function(self, v)
            self._p.bCanBeUpdatedBySubsystem = v
            switches[#switches + 1] = { owner._name, v }
        end
    end
    owner._p.AIOSubject = comp
    return comp
end
local zc = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 300, Y = 0, Z = 75 } })
local zcomp = subject(zc)
local deer = new(CW, { "BP_AnimalDeer_C", "BP_Animal_C", "Character", "Pawn" }, "BP_AnimalDeer_C_2147470100",
    { Role = 1, _loc = { X = 400, Y = 0, Z = 0 } })
local dcomp = subject(deer, false)        -- no setter: the property itself
local mine = make_zombie(CW, 3, { name = "Undead Shambler", loc = { X = 500, Y = 0, Z = 75 } })
mine._name = "BP_Zombie_Roamer_C_7"         -- this machine's own (level-placed: the ghosts pass leaves it)
local mcomp = subject(mine)
make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 600, Y = 0, Z = 75 } })   -- a copy without AIOSubject
advance(1)
client_tick()
check(#switches == 0 and zcomp._p.bCanBeUpdatedBySubsystem == true, "alive: nothing touched")
-- the client's character dies: the server unpossesses it
CW.pawn._p["PlayerDead?"] = true
CW.pc._p.Pawn = nil
local mark = #LOG + 1
advance(1)
client_tick()
check(zcomp._p.bCanBeUpdatedBySubsystem == false and dcomp._p.bCanBeUpdatedBySubsystem == false,
    "dead: the host's zombie and deer copies no longer updated by this client's optimizer")
check(mcomp._p.bCanBeUpdatedBySubsystem == true, "this machine's own actor untouched")
check(switches[1] and switches[1][1] == zc._name and switches[1][2] == false, "the zombie through SetCanBeUpdatedBySubsystem(false)")
check(find_log("ai: optimizer guard: this player's character BP_PlayerCharacter_C_0 died", mark) ~= nil
    and find_log("2 host AI copies here no longer updated by this client's AI optimizer while this player is dead %(2 in all, 1 without an AIOSubject switch%)", mark) ~= nil,
    "logged: the death and the frozen copies (one copy has no switch)")
-- a zombie copy that comes into view while dead: frozen in its own BeginPlay, before any tick
local zc2 = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 700, Y = 0, Z = 75 } })
local z2comp = subject(zc2)
mark = #LOG + 1
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(zc2))
check(z2comp._p.bCanBeUpdatedBySubsystem == false, "a zombie copy that came in while dead: frozen in its BeginPlay (no tick yet)")
check(find_log(zc2._name .. " came into range while this player is dead: kept from this client's AI optimizer from its BeginPlay on %(3 in all%)", mark) ~= nil,
    "logged")
local mine2 = make_zombie(CW, 3, { name = "Undead Shambler", loc = { X = 750, Y = 0, Z = 75 } })
local m2comp = subject(mine2)
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(mine2))
check(m2comp._p.bCanBeUpdatedBySubsystem == true, "this machine's own zombie's BeginPlay: untouched")
-- an animal copy (no BeginPlay hook of its master class): the next tick, 1 s later
local wolf = new(CW, { "BP_AnimalWolf_C", "BP_Animal_C", "Character", "Pawn" }, "BP_AnimalWolf_C_2147470101",
    { Role = 1, _loc = { X = 450, Y = 0, Z = 0 } })
local wcomp = subject(wolf)
check(wcomp._p.bCanBeUpdatedBySubsystem == true, "a wolf copy (not hooked): not yet")
advance(1.1)
client_tick()
check(wcomp._p.bCanBeUpdatedBySubsystem == false, "a wolf copy that came in while dead: frozen by the next tick, 1 s later (was 3 s)")
-- this client's optimizer still despawns one: evidence
local sub = new(CW, { "AIOptimizerSubsystem" }, "AIOptimizerSubsystem_0")
mark = #LOG + 1
fire(CW, DESPAWN, "pre", param(sub), param({ HandleId = 0 }), param(1), param(zcomp), param(-1), param(false))
fire(CW, DESPAWN, "pre", param(sub), param({ HandleId = 0 }), param(1), param(mcomp), param(-1), param(false))
check(find_log("this client's AI optimizer despawns the host's " .. zc._name .. " %(beyond its last layer%) although frozen", mark) ~= nil,
    "a host copy despawned here is logged (frozen or not)")
enter(CW)
local og = client_mod("sdc_ai_optguard").status_line()
leave(CW)
check(og:find("deaths=1 copies frozen=4 (at arrival 1) handed back=0 no switch=1 | host copies despawned here=1 (frozen ones 1) | dead now, 4 frozen", 1, true) ~= nil,
    "status (the copy without a switch counted once, not retried): " .. og)
-- the new character is in
local np = new(CW, { "BP_PlayerCharacter_C", "Character", "Pawn" }, "BP_PlayerCharacter_C_2147470200",
    { Controller = CW.pc, _loc = { X = 0, Y = 0, Z = 90 } })
CW.pc._p.Pawn = np
zc2._valid = false                     -- left this client's net range meanwhile
mark = #LOG + 1
advance(1)
client_tick()
check(zcomp._p.bCanBeUpdatedBySubsystem == true and dcomp._p.bCanBeUpdatedBySubsystem == true
    and wcomp._p.bCanBeUpdatedBySubsystem == true, "new character: the copies are the optimizer's again")
check(find_log("new character BP_PlayerCharacter_C_2147470200 after %d+ s dead: 3 of 4 frozen host AI copies updated by this client's AI optimizer again", mark) ~= nil,
    "logged: handed back")
-- seated elsewhere (a vehicle as the pawn): not a death
local car = new(CW, { "BP_Vehicle_C", "Pawn" }, "BP_Vehicle_C_2147470300", { _loc = { X = 0, Y = 0, Z = 0 } })
CW.pc._p.Pawn = car
switches = {}
advance(4)
client_tick()
check(#switches == 0 and zcomp._p.bCanBeUpdatedBySubsystem == true, "the pawn is a vehicle, the character lives: nothing frozen")
CW.pc._p.Pawn = np
client_tick()
-- human AI copies: Smart AI bandits / traders (BP_MasterAICharacter_C) and civilians
-- (BP_MainFriendly_C) despawn through the same OnOptimizationUpdate handler
local HUMAN = { "BP_MasterAICharacter_C", "Character", "Pawn" }
local function human(cls, name, role)
    local chain = { cls }
    for _, c in ipairs(HUMAN) do chain[#chain + 1] = c end
    return new(CW, chain, name, { Role = role, _loc = { X = 800, Y = 0, Z = 0 } })
end
local bandit = human("BP_MasterBandit_C", "BP_Bandit_Rifle_C_2147470400", 1)
local bcomp = subject(bandit)
local trader = human("BP_MasterTrader_C", "BP_Trader_General_C_5", 1)
local tcomp = subject(trader)
local civ = new(CW, { "BP_RandomCivilian_C", "BP_MainFriendly_C", "BP_Human_C", "Character", "Pawn" },
    "BP_RandomCivilian_C_2147470401", { Role = 1, _loc = { X = 900, Y = 0, Z = 0 } })
local ccomp = subject(civ)
local own_b = human("BP_MasterBandit_C", "BP_Bandit_Melee_C_9", 3)
local obcomp = subject(own_b)
np._p["PlayerDead?"] = true
CW.pc._p.Pawn = nil
advance(1)
client_tick()
check(bcomp._p.bCanBeUpdatedBySubsystem == false and tcomp._p.bCanBeUpdatedBySubsystem == false
    and ccomp._p.bCanBeUpdatedBySubsystem == false,
    "dead again: the host's bandit, trader and civilian copies are frozen too")
check(obcomp._p.bCanBeUpdatedBySubsystem == true, "this machine's own human AI untouched")
local bandit2 = human("BP_MasterBandit_C", "BP_Bandit_Rifle_C_2147470402", 1)
local b2comp = subject(bandit2)
fire(CW, HUMAN_BEGIN, "bp", param(bandit2))
check(b2comp._p.bCanBeUpdatedBySubsystem == false, "a bandit copy that came in while dead: frozen in its BeginPlay")
local np2 = new(CW, { "BP_PlayerCharacter_C", "Character", "Pawn" }, "BP_PlayerCharacter_C_2147470500",
    { Controller = CW.pc, _loc = { X = 0, Y = 0, Z = 90 } })
CW.pc._p.Pawn = np2
advance(1)
client_tick()
check(bcomp._p.bCanBeUpdatedBySubsystem == true and tcomp._p.bCanBeUpdatedBySubsystem == true
    and ccomp._p.bCanBeUpdatedBySubsystem == true and b2comp._p.bCanBeUpdatedBySubsystem == true,
    "new character: the human AI copies handed back")
for _, o in ipairs({ bandit, trader, civ, own_b, bandit2 }) do o._valid = false end
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(zc))
check(zcomp._p.bCanBeUpdatedBySubsystem == true, "alive: a copy's BeginPlay touches nothing")

-- ===========================================================================
say("== A2. the death screen: sdc_ai's tick stops, the guard's own loop goes on; turned off while dead")
switches = {}
advance(1)
guard_loop()
check(#switches == 0, "alive: the loop touches nothing")
np2._p["PlayerDead?"] = true
CW.pc._p.Pawn = nil
mark = #LOG + 1
advance(1)
guard_loop()                     -- no client_tick(): the session's client ticks stop on the death screen
check(zcomp._p.bCanBeUpdatedBySubsystem == false and dcomp._p.bCanBeUpdatedBySubsystem == false
    and wcomp._p.bCanBeUpdatedBySubsystem == false, "dead, only the loop ticks: the death seen, the host copies frozen")
check(find_log("this player's character BP_PlayerCharacter_C_2147470500 died", mark) ~= nil, "logged: the death")
-- sdcoop_set ai_client_optimizer_guard false while dead: sdc_ai does not tick, the loop hands them back
enter(CW); C.config.values.ai_client_optimizer_guard = false; leave(CW)
mark = #LOG + 1
advance(1)
guard_loop()
check(zcomp._p.bCanBeUpdatedBySubsystem == true and dcomp._p.bCanBeUpdatedBySubsystem == true
    and wcomp._p.bCanBeUpdatedBySubsystem == true, "turned off while dead: the loop hands every frozen copy back")
check(find_log("optimizer guard turned off while this player is dead: 3 of 3 frozen host AI copies updated by this client's AI optimizer again", mark) ~= nil,
    "logged: turned off")
-- on again while still dead: the death is seen again
enter(CW); C.config.values.ai_client_optimizer_guard = true; leave(CW)
advance(1)
guard_loop()
check(zcomp._p.bCanBeUpdatedBySubsystem == false and wcomp._p.bCanBeUpdatedBySubsystem == false,
    "on again while still dead: frozen again")
-- turned off, and sdc_ai ticks (its on -> off): mod.off hands them back
enter(CW); C.config.values.ai_client_optimizer_guard = false; leave(CW)
mark = #LOG + 1
client_tick()
check(zcomp._p.bCanBeUpdatedBySubsystem == true and dcomp._p.bCanBeUpdatedBySubsystem == true
    and wcomp._p.bCanBeUpdatedBySubsystem == true, "sdc_ai turns the feature off while dead: every frozen copy handed back")
check(find_log("ai: ai_client_optimizer_guard off", mark) ~= nil
    and find_log("optimizer guard turned off while this player is dead: 3 of 3", mark) ~= nil, "logged: off and handed back")
switches = {}
advance(1)
guard_loop()
client_tick()
check(#switches == 0, "off: neither the loop nor sdc_ai's tick touches anything")
np2._p["PlayerDead?"] = nil
CW.pc._p.Pawn = np2
for _, o in ipairs({ wolf, mine2 }) do o._valid = false end
client_tick()
client_tick()

-- ===========================================================================
say("== B. core.line: the first few at info, then debug only")
enter(CW)
local core = C.ai.core
local l1, l2, l3 = core.line("test.line", 2), core.line("test.line", 2), core.line("test.line", 2)
check(l1 == C.log.info and l2 == C.log.info and l3 == nil, "info, info, then nothing (debug off)")
C.log.debug_enabled = true
check(core.line("test.line", 2) == C.log.debug, "debug on: log.debug")
C.log.debug_enabled = false
leave(CW)

-- ===========================================================================
say("== C. looks client pass: a slow apply leaves the rest to the next pass")
local hz, cz = {}, {}
local function batch(n, x0, slow)
    hz, cz = {}, {}
    advance(2.1)
    host_tick()             -- a new host tick (the per-tick look budget starts again) before these exist
    for i = 1, n do
        hz[i] = make_zombie(HW, 3, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_C.SK_C", loc = { X = x0 + i * 50, Y = 900, Z = 75 } })
        cz[i] = make_zombie(CW, 1, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_A.SK_A", loc = { X = x0 + i * 50, Y = 900, Z = 75 } })
        NETMAP[hz[i]] = cz[i]
        if slow then
            cz[i]._mesh._m.SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a; advance(0.03) end
        end
    end
    advance(0.2)
    HW.outbox = {}
    for i = 1, n do fire(HW, ZM .. "SelectArchetype", "bp", param(hz[i])) end
    deliver()
end
local function swapped()
    local n = 0
    for i = 1, #cz do
        if cz[i]._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"] then n = n + 1 end
    end
    return n
end
local looks = client_mod("sdc_ai_looks")
local spread0 = looks.stats.spread
batch(6, 2000, true)
check(swapped() == 2, "6 looks at once: 2 applied at once (event budget), 4 wait (" .. swapped() .. ")")
advance(1.1)
client_tick()
check(swapped() == 3 and looks.stats.spread == spread0 + 1, "slow applies (30 ms): one per pass (" .. swapped() .. ")")
for _ = 1, 3 do advance(1.1); client_tick() end
check(swapped() == 6, "the rest one per pass, 1 s apart (" .. swapped() .. ")")
batch(6, 4000, false)
check(swapped() == 2, "fast batch: 2 at once")
advance(1.1)
client_tick()
check(swapped() == 6, "fast applies: all 4 waiting ones in one pass (" .. swapped() .. ")")
-- C2 (wave ai, item 3): the slow-apply line tells a first use of a mesh here from a repeat
local function slow_one(x)
    advance(2.1)
    host_tick()
    local h = make_zombie(HW, 3, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_B.SK_B", loc = { X = x, Y = 900, Z = 75 } })
    local c = make_zombie(CW, 1, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_A.SK_A", loc = { X = x, Y = 900, Z = 75 } })
    NETMAP[h] = c
    c._mesh._m.SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a; advance(0.06) end
    advance(0.2)
    HW.outbox = {}
    fire(HW, ZM .. "SelectArchetype", "bp", param(h))
    local mark = #LOG + 1
    deliver()
    return find_log("ai: looks: applying the host's look to", mark)
end
local first_line = slow_one(6000)
check(first_line ~= nil and first_line:find("first use here: SK_B", 1, true) ~= nil,
    "a slow apply of a mesh never used here before: 'first use here: SK_B': " .. tostring(first_line))
local again_line = slow_one(6100)
check(again_line ~= nil and again_line:find("first use here: none", 1, true) ~= nil,
    "the same mesh again: 'first use here: none': " .. tostring(again_line))

-- ===========================================================================
say("== D. client ghosts: spawners that are gone are forgotten")
local stops = 0
local function spawner(role, name)
    return new(CW, { "BP_AISpawner_Zombies_C", "BP_AISpawner_Master_C" }, name,
        { Role = role, IsSpawningStopped = false, SpawnedActorClass = new(CW, { "Class" }, "BP_Zombie_Roamer_C") }, {
            SetIsSpawningStopped = function(self, stop) stops = stops + 1; self._p.IsSpawningStopped = stop end,
        })
end
local sps = {}
for i = 1, 10 do sps[i] = spawner(1, "BP_AISpawner_Zombies_C_" .. (2147460000 + i)) end
local own_sp = spawner(3, "BP_AISpawner_Zombies_C_2147460099")
local ghosts = client_mod("sdc_ai_ghosts")
local function known()
    local n = 0
    for _ in pairs(ghosts._t.spawners()) do n = n + 1 end
    return n
end
advance(3.1)
client_tick()
check(known() == 11 and stops == 1 and own_sp._p.IsSpawningStopped == true, "11 spawners known, the own one stopped")
for i = 1, 4 do sps[i]._valid = false end   -- a camp despawned with its spawners
for _ = 1, 6 do advance(3.1); client_tick() end
check(known() == 7, "the 4 gone ones forgotten after three rounds (" .. known() .. " known)")
check(ghosts.stats.spawners_forgotten == 4 and stops == 1, "counted; the own spawner (still here) not stopped again")
check(ghosts._t.spawners()[own_sp:GetFullName()] == "stopped", "a live spawner keeps its entry")
enter(CW)
local gl = ghosts.status_line()
leave(CW)
check(gl:find("known now=7 forgotten=4", 1, true) ~= nil, "status: " .. gl)

say("")
enter(CW)
for _, l in ipairs(C.ai.status_lines()) do say("  client: " .. l) end
leave(CW)
check(find_log("%[ERROR%]") == nil, "no error lines")
say(string.format("ai coop client: %d failed", fails))
say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
