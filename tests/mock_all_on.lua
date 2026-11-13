-- Mock harness for sdc_ai_looks / sdc_ai_killlog / sdc_ai_zombie: runs the real
-- sdc_ai core + modules against fake UE objects, one world for the host and one
-- for the client, each with its own module instances.
-- usage: lua mock_zombie_sync.lua <scripts dir>
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
local MODS = { "sdc_log", "sdc_ue", "sdc_net", "sdc_config", "sdc_ctx", "sdc_ai", "sdc_ai_zombie", "sdc_ai_looks",
               "sdc_ai_killlog" }
local OFF = {}
local function load_mods(w)
    enter(w)
    local m = {}
    for _, name in ipairs(MODS) do m[name:gsub("^sdc_", "")] = require(name) end
    for _, k in ipairs(OFF) do m.config.values[k] = false end
    m.config.values.player_name = "Boss"
    m.config.values.ai_kill_log = true   -- default off since 2026-11-13 (a debug log); this test covers it
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
local DMG = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C:"
local LOADED_MESH = ZM .. "OnLoaded_D22F5BA44A8E7DDA4516F49F1F1CEA1F"

-- ===========================================================================
say("== 0. features and hooks")
host_tick()
client_tick()
enter(HW)
local lines = H.ai.status_lines()
leave(HW)
check(lines[1]:find("looks=on", 1, true) and lines[1]:find("killlog=on", 1, true), "looks + killlog on by default: " .. lines[1])
check(HW.hooks[ZM .. "SelectArchetype"] and HW.hooks[ZM .. "Death"] and HW.hooks[DMG .. "DamageTaken"], "host hooks installed")
check(HW.hooks[LOADED_MESH] ~= nil, "host OnLoaded hook installed")
check(CW.hooks[ZM .. "ReceiveBeginPlay"] and CW.hooks[ZM .. "OnRep_IsDead?"] and CW.hooks[OBJREF], "client hooks installed")
check(#(HW.hooks[ZM .. "Death"]) == 1, "one Death RegisterHook (shared dispatcher)")

say("== 1. host crawler -> client standing copy: body, then the look after the copy's roll")
local hz = make_zombie(HW, 3, { loc = { X = 1000, Y = 0, Z = 75 } })
make_crawler(HW, hz)
local cz = make_zombie(CW, 1, { mesh = "/Game/AI/Zombies/SK_B.SK_B", mat = "/Game/AI/Zombies/M_B.M_B",
                                 loc = { X = 1000, Y = 0, Z = 40 } })
NETMAP[hz] = cz
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(cz))
check(cz._p.CrawlerArchetypeChance == 0 and cz._p.ScreamerArchetypeChance == 0, "client copy will not roll a type")
fire(HW, ZM .. "Archetype_Crawler", "bp", param(hz))
fire(HW, ZM .. "SelectArchetype", "bp", param(hz))
local app = msgs(HW, "|AIAPP|")
check(#app == 1, "AIAPP sent at the host's roll")
check(app[1] and app[1]:find("|c|/Game/AI/Zombies/SK_A.SK_A|/Game/AI/Zombies/M_A.M_A|calf_l,Foot_R|Undead Crawler|"
    .. "/Game/AI/Zombies/CrawlerAILocomotion.CrawlerAILocomotion|40,-3,0,-32,-90|0", 1, true) ~= nil, "AIAPP payload: " .. tostring(app[1]))
deliver()
check(cz._cap._p.CapsuleHalfHeight == 40, "copy capsule half height 40 at once")
check(cz._p.BaseTranslationOffset.Z == -32 and cz._p.BaseTranslationOffset.X == -3 and cz._cached.Yaw == -90,
    "CacheInitialMeshOffset(-3,0,-32 / yaw -90)")
check(cz._mesh._p.RelativeLocation.Z == -32, "mesh moved to -32")
check(cz._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_B.SK_B"], "mesh waits for the copy's own roll")
cz._p.Name = FText("Undead Shambler")          -- the copy's own (zeroed) roll
advance(1.1)
fire(CW, ZM .. "SelectArchetype", "bp", param(cz))
check(cz._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_A.SK_A"], "copy mesh = host mesh")
check(cz._mesh._mat == CW.paths["/Game/AI/Zombies/M_A.M_A"] and cz._eyes, "copy material = host material, eyes refreshed")
check(cz._hidden.calf_l and cz._hidden.Foot_R and not cz._hidden.calf_r, "copy legs hidden like the host's")
check(cz._anim._setbs and cz._anim._p["Movement Blendspace"] == CW.bs_crawl, "crawler blendspace via SetBlendspace")
check(cz._p.Name:ToString() == "Undead Crawler", "copy Name = host Name")
check(find_log("looks like the host's %(after its roll") ~= nil, "apply logged")

say("== 2. copy that rolled crawler itself under a standing host zombie: undone by the pass")
local hz2 = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 1300, Y = 200, Z = 75 } })
local cz2 = make_zombie(CW, 1, { loc = { X = 1300, Y = 200, Z = 75 } })
make_crawler(CW, cz2, { "calf_r", "Foot_L" })
cz2._p._loc.Z = 75      -- replication keeps the host's place
NETMAP[hz2] = cz2
HW.outbox = {}
advance(2.1)
host_tick()
check(#msgs(HW, "|AIAPP|") >= 1, "pass sent the standing look")
deliver()
check(cz2._cap._p.CapsuleHalfHeight == 75, "copy capsule back to 75")
check(cz2._mesh._p.RelativeLocation.Z == -75 and cz2._mesh._p.RelativeLocation.X == 0, "copy mesh back to (0,0,-75)")
check(not cz2._hidden.calf_r and not cz2._hidden.Foot_L, "copy legs shown again")
check(cz2._anim._p["Movement Blendspace"] == CW.bs_walk, "walking blendspace back")
check(cz2._p.Name:ToString() == "Undead Shambler", "Name back")

say("== 3. client pass: zero a copy that began play before the hook, then ask for a missing look")
local hz3 = make_zombie(HW, 3, { name = "Undead Sprinter", mesh = "/Game/AI/Zombies/SK_C.SK_C", loc = { X = -4000, Y = 300, Z = 75 } })
hz3._anim._p["Movement Blendspace"] = HW.bs_walk
local cz3 = make_zombie(CW, 1, { loc = { X = -4000, Y = 300, Z = 75 } })   -- its BeginPlay hook was not in yet
NETMAP[hz3] = cz3
advance(3.1)
client_tick()
check(cz3._p.SprinterArchetypeChance == 0, "pass zeroed the copy's chances")
cz3._p.Name = FText("Undead Shambler")
fire(CW, ZM .. "SelectArchetype", "bp", param(cz3))
HW.outbox, CW.outbox = {}, {}
advance(3.1)
client_tick()
check(#CW.outbox == 1 and CW.outbox[1]:find("^SDC1|AIAPPQ|%-4000|300|75$") ~= nil, "copy without a look asked: " .. tostring(CW.outbox[1]))
-- the remote player must be near the asked point
rpawn._p._loc = { X = -3800, Y = 300, Z = 90 }
deliver()
check(cz3._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"] and cz3._p.Name:ToString() == "Undead Sprinter",
    "host answered; copy looks like the host's")
advance(3.1)
CW.outbox = {}
client_tick()
check(#CW.outbox == 0, "no more questions once applied")
-- three copies without a look in one pass: all three questions answered;
-- one of them never rolls (its look came while pending and expired)
local trio = {}
for i = 1, 3 do
    local hzq = make_zombie(HW, 3, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_C.SK_C",
                                     loc = { X = -4000 + i * 1000, Y = 2000, Z = 75 } })
    local czq = make_zombie(CW, 1, { name = i < 3 and "Undead Shambler" or "Undead",
                                     loc = { X = -4000 + i * 1000, Y = 2000, Z = 75 } })
    NETMAP[hzq] = czq
    trio[i] = czq
end
advance(3.1)
client_tick()           -- first sight: zeroes the unrolled one, too young to ask
advance(5.1)
CW.outbox = {}
client_tick()
check(#CW.outbox == 3, "three questions in one pass (" .. #CW.outbox .. ")")
deliver()
advance(1.1)
client_tick()           -- the third answer came over the apply budget: the pass applies it
check(trio[1]._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"]
    and trio[2]._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"], "both rolled copies answered")
check(trio[3]._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"], "copy that never rolled answered after 5 s")
rpawn._p._loc = { X = 500, Y = 0, Z = 90 }

say("== 4. late async load on the client is overridden")
advance(0.2)
fire(CW, ZM .. "OnLoaded_D22F5BA44A8E7DDA4516F49F1F1CEA1F", "bp", param(cz), param(CW.paths["/Game/AI/Zombies/SK_B.SK_B"]))
check(cz._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_A.SK_A"], "nothing to undo when the mesh is right")
cz._mesh._p.SkeletalMeshAsset = CW.paths["/Game/AI/Zombies/SK_B.SK_B"]     -- the late OnLoaded set its own
advance(0.2)
fire(CW, LOADED_MESH, "bp", param(cz), param(CW.paths["/Game/AI/Zombies/SK_B.SK_B"]))
check(cz._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_A.SK_A"], "host mesh put back after a late load")

say("== 5. late async load on the host: sent again")
enter(HW)
local resend0, pass0 = H.ai_looks.stats.resend, H.ai_looks.stats.pass_sent
leave(HW)
hz._mesh._p.SkeletalMeshAsset = HW.paths["/Game/AI/Zombies/SK_C.SK_C"]
fire(HW, LOADED_MESH, "bp", param(hz), param(hz._mesh._p.SkeletalMeshAsset))
HW.outbox = {}
advance(2.1)
host_tick()
enter(HW)
check(H.ai_looks.stats.resend == resend0 + 1 and H.ai_looks.stats.pass_sent > pass0, "host resends a look whose load finished late")
leave(HW)
deliver()
check(cz._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"], "client got the new mesh")

say("== 6. hound armour")
local DOG = { "BP_Zombie_Dog_C", "BP_MasterZombie_C", "BP_Zombie_C", "BP_MainEnemy_C", "Character", "Pawn" }
local hd = make_zombie(HW, 3, { chain = DOG, name = "Armored Undead Feral Hound Shambler", loc = { X = 1500, Y = -300, Z = 75 } })
local cd = make_zombie(CW, 1, { chain = DOG, name = "Undead Feral Hound Shambler", loc = { X = 1500, Y = -300, Z = 75 } })
cd._m.ExecuteUbergraph_BP_Zombie_Dog = function(self, entry) self._armour_entry = entry end
NETMAP[hd] = cd
local hd2 = make_zombie(HW, 3, { chain = DOG, name = "Undead Feral Hound Shambler", loc = { X = 1500, Y = -600, Z = 75 } })
local cd2 = make_zombie(CW, 1, { chain = DOG, name = "Armored Undead Feral Hound Shambler", loc = { X = 1500, Y = -600, Z = 75 } })
local arm1 = new(CW, { "SkeletalMeshComponent" }, "NODE_AddSkeletalMeshComponent-0")
local arm2 = new(CW, { "SkeletalMeshComponent" }, "NODE_AddSkeletalMeshComponent-1")
cd2._m.K2_GetComponentsByClass = function(self) return { cd2._mesh, arm1, arm2 } end
NETMAP[hd2] = cd2
HW.outbox = {}
advance(2.1)
host_tick()
deliver()
check(cd._armour_entry == 264, "copy without armour ran the dog's armour branch (@264)")
check(arm1._destroyed and arm2._destroyed and cd2._mesh._valid, "copy with its own armour lost the two armour meshes only")
check(cd2._p.Name:ToString() == "Undead Feral Hound Shambler", "hound Name as on the host")

say("== 7. new copy of an old horde zombie: emerge montage stopped")
local HORDE = { "BP_Zombie_Infected_Horde_C", "BP_MasterZombie_C", "BP_Zombie_C", "BP_MainEnemy_C", "Character", "Pawn" }
local hh = make_zombie(HW, 3, { chain = HORDE, name = "Undead Shambler", loc = { X = 900, Y = 900, Z = 75 } })
fire(HW, ZM .. "SelectArchetype", "bp", param(hh))   -- the client has no copy yet: objref -> nil there
enter(CW)
local nil0 = C.ai.stats.objref_nil
leave(CW)
deliver()
enter(CW)
check(C.ai.stats.objref_nil == nil0 + 1, "look for a zombie the client has no copy of: objref nil")
leave(CW)
advance(10)
local ch = make_zombie(CW, 1, { chain = HORDE, loc = { X = 900, Y = 900, Z = 75 } })
ch._anim._montage = CW.emerge
NETMAP[hh] = ch
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(ch))
advance(1.1)
ch._p.Name = FText("Undead Shambler")
fire(CW, ZM .. "SelectArchetype", "bp", param(ch))
host_tick()
check(#msgs(HW, "|AIAPP|") == 0, "host thinks it was sent: no resend by the pass")
advance(2.6)
CW.outbox = {}
client_tick()
check(#CW.outbox == 1 and CW.outbox[1]:find("|AIAPPQ|900|900|75", 1, true) ~= nil, "copy asked the host: " .. tostring(CW.outbox[1]))
deliver()
check(ch._anim._stopped == true, "emerge montage of a new copy of a 14 s old horde zombie stopped")
local hh2 = make_zombie(HW, 3, { chain = HORDE, name = "Undead Shambler", loc = { X = 950, Y = 950, Z = 75 } })
local ch2 = make_zombie(CW, 1, { chain = HORDE, loc = { X = 950, Y = 950, Z = 75 } })
ch2._anim._montage = CW.emerge
NETMAP[hh2] = ch2
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(ch2))
advance(1.1)
fire(HW, ZM .. "SelectArchetype", "bp", param(hh2))   -- spawned together: both emerge
ch2._p.Name = FText("Undead Shambler")
fire(CW, ZM .. "SelectArchetype", "bp", param(ch2))
deliver()
check(not ch2._anim._stopped and ch2._anim._montage == CW.emerge, "fresh horde zombie keeps its emerge")

say("== 8. kill log")
local mark = #LOG + 1
-- the remote player's headshot on the crawler
local dt = HW.paths["/Game/Blueprints/DT_Bullet.DT_Bullet"]
fire(HW, DMG .. "DamageTaken", "bp", param(hz._dc), param(30.0), param(dt), param(rpawn), param(true))
hz._p["IsDead?"] = true
hz._p.CapsuleComponent = setmetatable({ _valid = false, _p = {}, _m = {}, _chain = { "CapsuleComponent" } }, Obj)  -- Death @5
HW.outbox = {}
fire(HW, ZM .. "Death", "bp", param(hz), param(rpawn), param(true))
local hl = find_log("ai: kill %[host%]", mark)
check(hl and hl:find('Zombie_Roamer "Undead Crawler" arch=c crawler=yes (hh=40) mesh=SK_C mat=M_A', 1, true) ~= nil,
    "host line has type / name / crawler / skin: " .. tostring(hl))
check(hl and hl:find("by guest (headshot, dmg=DamageType, causer=BP_PlayerCharacter_C) at 997 0 8", 1, true) ~= nil,
    "host line has killer / damage / place")
check(#msgs(HW, "|AIKL|guest|1|") == 1, "AIKL to the client near it")
deliver()
advance(1.0)
cz._p["IsDead?"] = true
fire(CW, ZM .. "OnRep_IsDead?", "bp", param(cz))
local cl = find_log("ai: kill %[client%]", mark)
check(cl and cl:find('"Undead Crawler" arch=c crawler=yes (hh=40) mesh=SK_C mat=M_A | by guest (headshot', 1, true) ~= nil,
    "client line: " .. tostring(cl))
check(cl and cl:find("-> same", 1, true) ~= nil, "client line: look same as the host's")
-- the host's own kill, a copy with another skin, no note -> delayed line
mark = #LOG + 1
local hz5 = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 700, Y = 0, Z = 75 } })
local cz5 = make_zombie(CW, 1, { mesh = "/Game/AI/Zombies/SK_B.SK_B", name = "Undead Shambler", loc = { X = 700, Y = 0, Z = 75 } })
NETMAP[hz5] = cz5
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(cz5))
advance(2)
local wpn = new(HW, { "BP_FirearmPickup_C" }, "BP_FirearmPickup_C_1", { _owner = HW.pawn })
fire(HW, ZM .. "Death", "bp", param(hz5), param(wpn), param(false))
hl = find_log("ai: kill %[host%]", mark)
check(hl and hl:find("by Boss (host) (causer=BP_FirearmPickup_C)", 1, true) ~= nil, "host's own kill named: " .. tostring(hl))
deliver()
cz5._p["IsDead?"] = true
fire(CW, ZM .. "OnRep_IsDead?", "bp", param(cz5))
cl = find_log("ai: kill %[client%]", mark)
check(cl and cl:find("DIFFERS: mesh", 1, true) ~= nil, "client line flags a different skin: " .. tostring(cl))
-- no killer at all; the client gets no note (out of range) -> line after the delay
mark = #LOG + 1
local hz6 = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 90000, Y = 0, Z = 75 } })
local cz6 = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 90000, Y = 0, Z = 75 } })
NETMAP[hz6] = cz6
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(cz6))
advance(2)
fire(HW, ZM .. "Death", "bp", param(hz6), param(nil), param(false))
check(find_log("by none at", mark) ~= nil, "Death without a killer: by none")
check(#msgs(HW, "|AIKL|") == 0, "no note beyond net range")
cz6._p["IsDead?"] = true
fire(CW, ZM .. "OnRep_IsDead?", "bp", param(cz6))
check(find_log("ai: kill %[client%]", mark) == nil, "client line waits for the host's note")
run_timers(CW)
check(find_log("ai: kill %[client%].-by %? %(no word from the host%)", mark) ~= nil, "client line after the delay without a note")
-- a corpse that only comes into view: OnRep before BeginPlay
mark = #LOG + 1
local cz7 = make_zombie(CW, 1, { name = "Undead Shambler" })
cz7._p["IsDead?"] = true
fire(CW, ZM .. "OnRep_IsDead?", "bp", param(cz7))
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(cz7))
check(find_log("ai: kill", mark) == nil, "corpse coming into view is not a kill")
enter(HW)
local hs = H.ai_killlog.status_line()
leave(HW)
enter(CW)
local cs = C.ai_killlog.status_line()
leave(CW)
check(hs:find("host=3", 1, true) and hs:find("Zombie_Roamer=2", 1, true) and hs:find("Zombie_Roamer/c=1", 1, true),
    "host status counts per type: " .. hs)
check(cs:find("client=3", 1, true) and cs:find("corpses come into view=1", 1, true), "client status: " .. cs)
advance(61)
host_tick()
check(find_log("ai: kill log: host=3", mark) ~= nil, "periodic summary line")

say("== 8b. offscreen: a zombie attacking near a client refreshes its bones unseen, then reverts")
enter(HW); H.config.values.ai_offscreen_combat = true; leave(HW)
host_tick()
check(HW.hooks[ZM .. "PlayAttackMontage"] ~= nil, "host PlayAttackMontage hook installed")
local TICK = "VisibilityBasedAnimTickOption"
local za = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 650, Y = 0, Z = 75 } })    -- 1.5 m from the client
local zf = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 5000, Y = 0, Z = 75 } })   -- 45 m away
local zd = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 300, Y = 200, Z = 75 } })
mark = #LOG + 1
fire(HW, ZM .. "PlayAttackMontage", "bp", param(za))
fire(HW, ZM .. "PlayAttackMontage", "bp", param(zf))
fire(HW, ZM .. "PlayAttackMontage", "bp", param(zd))
check(za._mesh._p[TICK] == 0 and zd._mesh._p[TICK] == 0, "zombies attacking near the client: AlwaysTickPoseAndRefreshBones")
check(zf._mesh._p[TICK] == 2, "zombie attacking far from any client: untouched")
check(find_log("attacks near BP_PlayerController_C_1 %(1%.5 m%): its pose and bones tick", mark) ~= nil, "switch logged")
za._mesh._p[TICK] = 2                     -- the AI optimizer changed it back
advance(5)
fire(HW, ZM .. "PlayAttackMontage", "bp", param(za))
check(za._mesh._p[TICK] == 0, "set again on the next attack")
zd._p["IsDead?"] = true
advance(3.1)
host_tick()
check(zd._mesh._p[TICK] == 2 and za._mesh._p[TICK] == 0, "dead zombie reverted at once, attacker keeps ticking")
check(find_log("back to its own pose ticking 2 %(dead%)", mark) ~= nil, "revert logged (dead)")
advance(11)
host_tick()
check(za._mesh._p[TICK] == 2, "reverted 10 s after its last attack")
enter(HW)
local os_line = HW.mods.sdc_ai_offscreen.status_line()
leave(HW)
check(os_line:find("zombies set=2 back=2 now=0", 1, true) ~= nil, "offscreen status: " .. os_line)

say("== 10. client ghosts: own spawners stopped, local AI removed, boss copies kept from despawning")
local function spawner(role, name, cls)
    local sp = new(CW, { "BP_AISpawner_ZombieBosses_C", "BP_AISpawner_Master_C" }, name,
        { Role = role, IsSpawningStopped = false, SpawnedActorClass = new(CW, { "Class" }, cls) }, {
            SetIsSpawningStopped = function(self, stop) self._p.IsSpawningStopped = stop end,
        })
    return sp
end
local sp_host = spawner(1, "BP_AISpawner_ZombieBosses_C_1", "BP_ZombieBoss_Survivor_Small_C")
local sp_own = spawner(3, "BP_AISpawner_ZombieBosses_C_2", "BP_ZombieBoss_Survivor_Small_C")
local BOSS = { "BP_ZombieBoss_Survivor_Small_C", "BP_ZombieBoss_C", "BP_MainEnemy_C", "Character", "Pawn" }
local boss_copy = make_zombie(CW, 1, { chain = BOSS, loc = { X = 2000, Y = 0, Z = 120 } })
boss_copy._p.SD_AIComponent = new(CW, { "SD_AIComponent_C" }, "SD_AIComponent_1", { ["CanSystemDespawnAI?"] = true })
local ghost_boss = make_zombie(CW, 3, { chain = BOSS, loc = { X = 2010, Y = 0, Z = 400 } })
local ghost_wolf = new(CW, { "BP_AnimalWolf_C", "BP_Animal_C", "Character", "Pawn" }, "BP_AnimalWolf_C_2147470001",
    { Role = 3, _loc = { X = 0, Y = 0, Z = 0 } }, { K2_DestroyActor = function(self) self._valid = false end })
local level_zombie = make_zombie(CW, 3, { loc = { X = 0, Y = 0, Z = 0 } })
level_zombie._name = "BP_Zombie_Roamer_C_5"                     -- placed in a level: not runtime-spawned
ghost_boss._m.K2_DestroyActor = function(self) self._valid = false end
level_zombie._m.K2_DestroyActor = function(self) self._valid = false end
mark = #LOG + 1
advance(3.1)
client_tick()
check(sp_own._p.IsSpawningStopped == true and sp_host._p.IsSpawningStopped == false, "own spawner stopped, host copy untouched")
check(find_log("stopped 1 spawner%(s%) of this client's own .-BP_AISpawner_ZombieBosses_C_2%(BP_ZombieBoss_Survivor_Small_C%)", mark) ~= nil,
    "spawner stop logged")
check(not ghost_boss._valid and not ghost_wolf._valid, "local boss and wolf removed")
check(level_zombie._valid and boss_copy._valid, "level-placed actor and host copy kept")
check(find_log("removed 2 AI that existed only on this client: BP_ZombieBoss_Survivor_Small_C_%d+%(dead=false at 2010 0 400%) BP_AnimalWolf_C_2147470001", mark) ~= nil,
    "ghosts named in the log")
check(boss_copy._p.SD_AIComponent._p["CanSystemDespawnAI?"] == false, "boss copy: CanSystemDespawnAI? = false")
-- 2026-11-13 (critic B8): the client's optimizer despawns are no longer hooked (that was evidence only)
check(CW.hooks["/Script/AIOptimizer.AIOptimizerSubsystem:K2_DespawnSubject"] == nil, "no K2_DespawnSubject hook on the client")

say("== 11. client: an attack already playing on a copy is not restarted")
enter(CW); C.config.values.ai_attack_montages = true; leave(CW)
client_tick()
local atk = asset(CW, "AnimMontage", "/Game/Animations/Zombie/ZombieBoss/Anim_Zombie_attack2_Montage.Anim_Zombie_attack2_Montage")
atk._m.GetPlayLength = function() return 2.0 end
local plays = 0
boss_copy._anim._m.Montage_Play = function(self, m) plays = plays + 1; self._playing = m; return 2.0 end
boss_copy._anim._m.Montage_IsPlaying = function(self, m) return self._playing == m end
local PATH = "/Game/Animations/Zombie/ZombieBoss/Anim_Zombie_attack2_Montage.Anim_Zombie_attack2_Montage"
local function aim(kind)
    enter(CW); C.net.handlers.AIM({ kind, "1.00", PATH }, CW.pc); leave(CW)
    fire(CW, OBJREF, "pre", param(CW.pc), param(boss_copy))
end
aim("a")
advance(0.3)
aim("a")
advance(0.3)
aim("a")
check(plays == 1, "three AIM in 0.6 s: one play (" .. plays .. ")")
boss_copy._anim._playing = nil          -- it ended / blended out
advance(1.5)
aim("a")
check(plays == 2, "a new attack after the montage: played")
aim("h")
check(plays == 3, "hit reactions still restart")
check(find_log("already plays Anim_Zombie_attack2_Montage; not restarted") ~= nil, "skip logged")

say("== 12. client: zombies already dead when they arrive become corpses (join / come into view)")
local function physics(z)
    local m = z._mesh
    m._m.SetCollisionResponseToChannel = function() end
    m._m.SetCollisionEnabled = function() end
    m._m.SetSimulatePhysics = function(self, on) self._sim = on end
    m._m.WakeAllRigidBodies = function(self) self._woken = true end
    m._m.IsSimulatingPhysics = function(self) return self._sim == true end
    z._cap._m.SetCollisionEnabled = function(self, v) self._coll = v end
end
-- copies that replicated in dead before the client's hooks were in: no OnRep / BeginPlay seen
local stood = {}
for i = 1, 3 do
    local zc = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 3000 + i * 100, Y = 0, Z = 75 } })
    zc._p["IsDead?"] = true
    physics(zc)
    stood[i] = zc
end
enter(CW); C.config.values.ai_corpses = true; leave(CW)
mark = #LOG + 1
advance(2.1)
client_tick()
check(stood[1]._mesh._sim and stood[2]._mesh._sim and stood[3]._mesh._sim, "pass: all three dead copies ragdolled")
check(stood[1]._p.Dead == true and stood[1]._cap._coll == 0, "lootable, capsule off")
check(find_log("ai: corpses: 3 dead zombie%(s%) stood on this client %(joined / came into view earlier%): corpses now: BP_Zombie_Roamer_C_", mark) ~= nil,
    "join fix logged with names")
-- a copy that comes into view dead after the hooks are in: BeginPlay post-hook
local late = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 3500, Y = 0, Z = 75 } })
late._p["IsDead?"] = true
physics(late)
fire(CW, ZM .. "ReceiveBeginPlay", "bp", param(late))
check(late._mesh._sim == true, "BeginPlay: came into view dead -> corpse at once")
check(find_log("came into view dead: corpse here", mark) ~= nil, "came-into-view logged")
check(late._p.CrawlerArchetypeChance == 0, "looks still zeroed its roll")
-- a mesh swap (late async load) drops the ragdoll: the pass puts it back
stood[2]._mesh._sim = false
advance(2.1)
client_tick()
check(stood[2]._mesh._sim == true and find_log("corpse%(s%) ragdolled again after a mesh change", mark) ~= nil, "re-ragdoll after a mesh change")
-- the host's look on a corpse keeps it lying
stood[3]._mesh._sim = true
local hz9 = make_zombie(HW, 3, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_C.SK_C", loc = { X = 3300, Y = 0, Z = 75 } })
hz9._p["IsDead?"] = true
NETMAP[hz9] = stood[3]
stood[3]._mesh._m.SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a; self._sim = false end
HW.outbox = {}
advance(2.1)
host_tick()
deliver()
check(stood[3]._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"] and stood[3]._mesh._sim == true,
    "host look on a corpse: mesh swapped, ragdoll kept")
check(stood[3]._cap._p.CapsuleHalfHeight == 75, "no body change on a corpse")
-- a dead boss copy that arrived dead: lootable
local BOSS2 = { "BP_ZombieBoss_Survivor_Small_C", "BP_ZombieBoss_C", "BP_MainEnemy_C", "Character", "Pawn" }
local dead_boss = make_zombie(CW, 1, { chain = BOSS2, loc = { X = 3600, Y = 0, Z = 75 } })
dead_boss._p["IsDead?"] = true
advance(2.1)
client_tick()
check(dead_boss._p.Dead == true and find_log("boss BP_ZombieBoss_Survivor_Small_C_%d+ was dead already: lootable", mark) ~= nil,
    "dead boss copy made lootable")

say("== 13. client applies: never a load, a budget, missing assets retried, slow ones logged")
enter(CW); C.config.values.ai_corpses = false; leave(CW)
local LOADS0 = LOADS
local five, hfive = {}, {}
for i = 1, 5 do
    hfive[i] = make_zombie(HW, 3, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_C.SK_C", loc = { X = 600 + i * 50, Y = 600, Z = 75 } })
    five[i] = make_zombie(CW, 1, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_A.SK_A", loc = { X = 600 + i * 50, Y = 600, Z = 75 } })
    NETMAP[hfive[i]] = five[i]
end
advance(0.2)
enter(HW); H.ai_looks.reset(); leave(HW)
HW.outbox = {}
for i = 1, 5 do fire(HW, ZM .. "SelectArchetype", "bp", param(hfive[i])) end
deliver()
local function swapped()
    local n = 0
    for i = 1, 5 do
        if five[i]._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_C.SK_C"] then n = n + 1 end
    end
    return n
end
check(swapped() == 2, "5 looks at once: 2 applied now (" .. swapped() .. ")")
advance(1.1)
client_tick()
check(swapped() == 5, "the other 3 from the next client pass (" .. swapped() .. ")")
-- the host's mesh not in memory on this client: the rest applied, the mesh later
local NEWMESH = "/Game/AI/Zombies/SK_Zombie_Firefighter_Male_01.SK_Zombie_Firefighter_Male_01"
local hf = make_zombie(HW, 3, { name = "Undead Shambler", loc = { X = 900, Y = 700, Z = 75 } })
local cf = make_zombie(CW, 1, { name = "Undead Shambler", mat = "/Game/AI/Zombies/M_B.M_B", loc = { X = 900, Y = 700, Z = 75 } })
NETMAP[hf] = cf
asset(HW, "SkeletalMesh", NEWMESH)
hf._mesh._p.SkeletalMeshAsset = HW.paths[NEWMESH]
mark = #LOG + 1
advance(0.2)
HW.outbox = {}
fire(HW, ZM .. "SelectArchetype", "bp", param(hf))
deliver()
check(cf._mesh._mat == CW.paths["/Game/AI/Zombies/M_A.M_A"], "material applied although the mesh is missing")
check(cf._mesh._p.SkeletalMeshAsset == CW.paths["/Game/AI/Zombies/SK_A.SK_A"], "mesh not loaded here: left as it is")
check(find_log("mesh of the host's look not in memory here yet %(SK_Zombie_Firefighter_Male_01%)", mark) ~= nil, "missing asset logged")
asset(CW, "SkeletalMesh", NEWMESH)        -- another copy's own async load brought it in
advance(2.1)
client_tick()
check(cf._mesh._p.SkeletalMeshAsset == CW.paths[NEWMESH], "retried: mesh applied once in memory")
check(LOADS == LOADS0, "no LoadAsset on the client (" .. (LOADS - LOADS0) .. ")")
-- a slow apply is named
local hs = make_zombie(HW, 3, { name = "Undead Shambler", mesh = "/Game/AI/Zombies/SK_C.SK_C", loc = { X = 950, Y = 750, Z = 75 } })
local cs = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 950, Y = 750, Z = 75 } })
NETMAP[hs] = cs
cs._mesh._m.SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a; advance(0.08) end
advance(0.2)
HW.outbox = {}
fire(HW, ZM .. "SelectArchetype", "bp", param(hs))
deliver()
check(find_log("applying the host's look to BP_Zombie_Roamer_C_%d+ took 80 ms %(look; mesh=SK_C mat=M_A", mark) ~= nil, "slow apply logged with assets")

say("== 14. archetype effects: acid spit / radiation mist on copies, grenadier beep + explosion relayed")
local FXP = {
    spit = "/Game/FX/Blood/NS_BloodSpit.NS_BloodSpit",
    mist = "/Game/PolygonFiles/PolygonApocalypse/ParticleFX/FX_ZombieRadiationMist.FX_ZombieRadiationMist",
    beep = "/Game/Audio/Sounds/Cue/S_Beep_Cue.S_Beep_Cue",
    boom = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_Grenadier.FX_Explosion_Grenadier",
    burn = "/Game/Blueprints/Other/ExplosiveBarrel/M_Burn.M_Burn",
    groan = "/Game/Audio/ZombieGrowlShort.ZombieGrowlShort",
}
for _, w in ipairs({ HW, CW }) do
    asset(w, "NiagaraSystem", FXP.spit)
    asset(w, "ParticleSystem", FXP.mist)
    asset(w, "ParticleSystem", FXP.boom)
    asset(w, "Material", FXP.burn)
    asset(w, "SoundCue", FXP.groan)
end
asset(HW, "SoundCue", FXP.beep)          -- not in memory on the client at first
CW.fx = {}
local nlib = new(CW, { "NiagaraFunctionLibrary" }, "Default__NiagaraFunctionLibrary", {}, {
    SpawnSystemAttached = function(_, sys, comp, socket, l, r, lt, autod, autoa, pool, precull)
        CW.fx[#CW.fx + 1] = { "niagara", sys, comp, socket._s, autod, autoa, pool }
        return new(CW, { "NiagaraComponent" }, "NiagaraComponent_" .. #CW.fx)
    end,
})
CW.paths["/Script/Niagara.Default__NiagaraFunctionLibrary"] = nlib
local cgps = CW.paths["/Script/Engine.Default__GameplayStatics"]
cgps._m.SpawnEmitterAttached = function(_, ps, comp, socket, l, r, sc, lt, autod, pool, autoa)
    CW.fx[#CW.fx + 1] = { "emitter_attached", ps, comp, socket._s }
    return new(CW, { "ParticleSystemComponent" }, "ParticleSystemComponent_" .. #CW.fx)
end
cgps._m.PlaySoundAtLocation = function(_, wc, snd, l) CW.fx[#CW.fx + 1] = { "sound", snd, l } end
cgps._m.SpawnEmitterAtLocation = function(_, wc, ps, l, r, sc) CW.fx[#CW.fx + 1] = { "emitter", ps, l, sc } end
cgps._m.SpawnDecalAtLocation = function(_, wc, m, size, l, r, life) CW.fx[#CW.fx + 1] = { "decal", m, size, life } end
local function fx_of(kind)
    local out = {}
    for _, e in ipairs(CW.fx) do if e[1] == kind then out[#out + 1] = e end end
    return out
end
-- acidic + ultra-radiated host zombies, plain copies
local ha = make_zombie(HW, 3, { name = "Acidic Undead", loc = { X = 700, Y = -800, Z = 75 } })
local ca = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 700, Y = -800, Z = 75 } })
local hu = make_zombie(HW, 3, { name = "Ultra-Radiated Undead", loc = { X = 760, Y = -800, Z = 75 } })
local cu = make_zombie(CW, 1, { name = "Undead Shambler", loc = { X = 760, Y = -800, Z = 75 } })
for _, z in ipairs({ ca, cu }) do z._m.K2_GetRootComponent = function(self) return self._cap end end
NETMAP[ha], NETMAP[hu] = ca, cu
advance(0.3)
host_tick()             -- a new host tick: the per-tick look budget starts again
fire(HW, ZM .. "Archetype_Acidic", "bp", param(ha))
fire(HW, ZM .. "SelectArchetype", "bp", param(ha))
advance(0.3)
fire(HW, ZM .. "Archetype_UltraRadiated", "bp", param(hu))
fire(HW, ZM .. "SelectArchetype", "bp", param(hu))
deliver()
-- the host's passes / the client's deferred applies bring the looks within a few seconds
for _ = 1, 6 do
    if ca._p.BloodSpitFX ~= nil and cu._p.ZombieMist ~= nil then break end
    advance(2.1)
    host_tick()
    deliver()
    advance(1.1)
    client_tick()
end
local ns = fx_of("niagara")
check(#ns == 1 and ns[1][2] == CW.paths[FXP.spit] and ns[1][3] == ca._mesh and ns[1][4] == "mouth"
    and ns[1][5] == false and ns[1][6] == true and ns[1][7] == 1, "acidic copy: NS_BloodSpit at the mouth, the game's parameters")
check(ca._p.BloodSpitFX ~= nil, "BloodSpitFX set on the copy")
local ms = fx_of("emitter_attached")
check(#ms == 1 and ms[1][2] == CW.paths[FXP.mist] and ms[1][3] == cu._cap, "ultra-radiated copy: radiation mist on the root")
check(cu._p.ZombieMist ~= nil, "ZombieMist set on the copy")
-- applied again (late load): no second spit
advance(0.3)
fire(CW, LOADED_MESH, "bp", param(ca), param(nil))
check(#fx_of("niagara") == 1, "no second spit effect on a re-apply")
-- grenadier: beep, explosion, burn decal relayed; others not
mark = #LOG + 1
local hg = make_zombie(HW, 3, { name = "Undead Grenadier", loc = { X = 800, Y = -800, Z = 75 } })
local hgps = HW.paths["/Script/Engine.Default__GameplayStatics"]
local GS = "/Script/Engine.GameplayStatics:"
HW.outbox = {}
fire(HW, GS .. "PlaySoundAtLocation", "pre", param(hgps), param(hg), param(HW.paths[FXP.beep]),
    param({ X = 800, Y = -800, Z = 0 }), param({ Pitch = 0, Yaw = 0, Roll = 0 }), param(0.75), param(1.0))
fire(HW, GS .. "PlaySoundAtLocation", "pre", param(hgps), param(hg), param(HW.paths[FXP.groan]),
    param({ X = 800, Y = -800, Z = 0 }), param({ Pitch = 0, Yaw = 0, Roll = 0 }), param(1), param(1))
fire(HW, GS .. "PlaySoundAtLocation", "pre", param(hgps), param(HW.pawn), param(HW.paths[FXP.beep]),
    param({ X = 0, Y = 0, Z = 0 }), param({ Pitch = 0, Yaw = 0, Roll = 0 }), param(1), param(1))
fire(HW, GS .. "SpawnEmitterAtLocation", "pre", param(hgps), param(hg), param(HW.paths[FXP.boom]),
    param({ X = 800, Y = -800, Z = 0 }), param({ Pitch = 0, Yaw = 123, Roll = 0 }), param({ X = 1.1, Y = 1.2, Z = 1.1 }))
fire(HW, GS .. "SpawnDecalAtLocation", "pre", param(hgps), param(hg), param(HW.paths[FXP.burn]),
    param({ X = 400, Y = 800, Z = 800 }), param({ X = 800, Y = -800, Z = 0 }), param({ Pitch = -90, Yaw = 10, Roll = 0 }), param(30))
check(#msgs(HW, "|AIFX|") == 3, "3 AIFX: beep, explosion, decal (not the groan, not a player's sound) (" .. #msgs(HW, "|AIFX|") .. ")")
deliver()
check(#fx_of("sound") == 0 and find_log("S_Beep_Cue not in memory here; skipped", mark) ~= nil, "beep not in memory on the client: skipped, logged")
check(#fx_of("emitter") == 1 and fx_of("emitter")[1][2] == CW.paths[FXP.boom] and fx_of("emitter")[1][4].Y == 1.2,
    "explosion played with the host's scale")
check(#fx_of("decal") == 1 and fx_of("decal")[1][3].X == 400 and fx_of("decal")[1][4] == 30, "burn decal with the host's size / life")
asset(CW, "SoundCue", FXP.beep)
fire(HW, GS .. "PlaySoundAtLocation", "pre", param(hgps), param(hg), param(HW.paths[FXP.beep]),
    param({ X = 800, Y = -800, Z = 0 }), param({ Pitch = 0, Yaw = 0, Roll = 0 }), param(0.75), param(1.0))
deliver()
check(#fx_of("sound") == 1 and fx_of("sound")[1][2] == CW.paths[FXP.beep], "beep played once in memory")
check(LOADS == LOADS0, "still no LoadAsset on the client")

say("== 9. objects never kept; reset")
enter(CW); C.ai.reset("world:loadmap"); leave(CW)
enter(HW); H.ai.reset("role"); leave(HW)
host_tick()
client_tick()
enter(HW)
for _, l in ipairs(H.ai.status_lines()) do say("  host: " .. l) end
leave(HW)
enter(CW)
for _, l in ipairs(C.ai.status_lines()) do say("  client: " .. l) end
leave(CW)
check(find_log("%[ERROR%]") == nil, "no error lines")

say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
