-- Vehicle run-over kill credit (sdc_ai_kills, the "Vehicles" part of its header).
-- The harness (fake UE4SS, two machines) is mock_ai2.lua's, copied.
-- usage: lua mock_ai_vehkill.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD_
local fails = 0
-- each machine is its own process: its own sdc_* modules (features load lazily)
local function swap_modules(old, new)
    if old then
        old.mods = {}
        for k, v in pairs(package.loaded) do if k:match("^sdc_") then old.mods[k] = v end end
    end
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    if new and new.mods then for k, v in pairs(new.mods) do package.loaded[k] = v end end
end
local function set_world(w)
    if WORLD_ ~= w then swap_modules(WORLD_, w) end
    WORLD_ = w
end
local function check(cond, what)
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    -- a UFunction the object does not have
    return nil
end
local next_addr = 4096
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end, _chain = chain }
end
local function new(w, chain, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _tags = {}, _calls = {} }, Obj)
    w.objects[#w.objects + 1] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:GetInstigatorController() return nil end
function Obj:ActorHasTag(fn) return self._tags[fn._s] == true end
function Obj:IsA(cls)
    for _, c in ipairs(self._chain) do if c == cls._target then return true end end
    return false
end
local function rec(o, what) o._calls[#o._calls + 1] = what end
local function called(o, what)
    for _, c in ipairs(o._calls) do if c == what then return true end end
    return false
end

local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end

-- ------------------------------------------------------------ UE4SS globals
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    if WORLD_.hook_fail and WORLD_.hook_fail[path] then error("no UFunction " .. path) end
    WORLD_.hooks[path] = WORLD_.hooks[path] or {}
    table.insert(WORLD_.hooks[path], { pre = a, post = b })
    WORLD_.registered = (WORLD_.registered or 0) + 1
    return 1, 2
end
NotifyOnNewObject = function() WORLD_.watches = (WORLD_.watches or 0) + 1 end
StaticFindObject = function(path)
    WORLD_.finds[path] = (WORLD_.finds[path] or 0) + 1
    local o = WORLD_.paths[path]
    if o and o._valid then return o end
    return nil
end
FindAllOf = function(cls)
    WORLD_.findall[cls] = (WORLD_.findall[cls] or 0) + 1
    local out = {}
    for _, o in ipairs(WORLD_.objects) do
        if o._valid then
            for _, c in ipairs(o._chain) do if c == cls then out[#out + 1] = o break end end
        end
    end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) WORLD_.loads = (WORLD_.loads or 0) + 1; return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(_, fn) WORLD_.timers[#WORLD_.timers + 1] = fn; return #WORLD_.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

-- fire a hook as UE4SS does: BP = one callback after the function; natives pre / post
local function fire(w, path, kind, ...)
    set_world(w)
    local hs = w.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local fn = (kind == "bp" or kind == "pre") and h.pre or h.post
        if fn then
            local r = fn(...)
            assert(r == nil, "hook returned a value: " .. path)
        end
    end
    return true
end

-- ------------------------------------------------------------ worlds
local function world(id) return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, finds = {}, findall = {} } end
local HW, CW = world("host"), world("client")

local ZPATH = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local ZM = ZPATH .. ":"
local BPATH = "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C"
local ATTACK = "/Game/Animations/Zombie/Anim_Zombie_attack1_Montage.Anim_Zombie_attack1_Montage"
local HURT = "/Game/Animations/Zombie/Hurt_Montage.Hurt_Montage"
local NOTIFY = "/Game/Animations/Notifies/AnimNotify_BeginEvent.AnimNotify_BeginEvent_C:Received_NotifyBegin"
local DAMAGE = "/Script/Engine.GameplayStatics:ApplyDamage"
local OBJREF = "/Script/Engine.PlayerController:ClientRepObjRef"
local PROXY = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"

local function asset(w, cls, path)
    local o = new(w, { cls }, path:match("([^%.]+)$"))
    o._full = cls .. " " .. path
    w.paths[path] = o
    return o
end

local function engine(w, is_server)
    set_world(w)
    w.cvars = { ["Game.XpPopUp"] = true, ["Game.AIHealthBar"] = true }
    w.cleared = {}
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "Default__KismetSystemLibrary", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
        GetConsoleVariableBoolValue = function(_, n) return w.cvars[n] == true end,
        K2_ClearTimer = function(_, o, n) w.cleared[#w.cleared + 1] = { o = o, n = n } end,
    })
    w.sounds = {}
    w.paths["/Script/Engine.Default__GameplayStatics"] = new(w, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
        GetPlayerController = function(_, _, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        PlaySoundAtLocation = function(_, _, snd) w.sounds[#w.sounds + 1] = snd end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        GetAllActorsOfClass = function(_, _, cls, out)
            w.actor_queries = (w.actor_queries or 0) + 1
            for _, o in ipairs(w.objects) do
                if o._valid and o:IsA(cls) then out[#out + 1] = param(o) end
            end
        end,
    })
    local zc = new(w, { "BlueprintGeneratedClass" }, "BP_MasterZombie_C")
    zc._target = "BP_MasterZombie_C"
    w.paths[ZPATH] = zc
    local bc = new(w, { "BlueprintGeneratedClass" }, "BP_MasterBandit_C")
    bc._target = "BP_MasterBandit_C"
    w.paths[BPATH] = bc
    w.paths["/Script/Engine.SceneComponent"] = new(w, { "Class" }, "SceneComponent")
    asset(w, "AnimMontage", ATTACK)
    asset(w, "AnimMontage", HURT)
    asset(w, "SoundCue", "/Game/Sounds/ZombieAttack.ZombieAttack")
    asset(w, "SkeletalMesh", "/Game/Zombies/SK_A.SK_A")
    asset(w, "SkeletalMesh", "/Game/Zombies/SK_B.SK_B")
    asset(w, "Material", "/Game/Zombies/M_A.M_A")
    asset(w, "Material", "/Game/Zombies/M_B.M_B")
    asset(w, "BlendSpace1D", "/Game/AI/Zombies/CrawlerAILocomotion.CrawlerAILocomotion")
    asset(w, "BlendSpace1D", "/Game/AI/Zombies/Walk.Walk")
    asset(w, "Texture2D", "/Game/UI/Textures/Survivors_Icon_Pack/256x256/Hunting_For_Food/T_HumanSkull_256x256.T_HumanSkull_256x256")
    w.notes = {}
    w.paths["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"] = new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        XpMultiplierCalc = function() return 6.0 end,
        CreateNotificationUI = function(_, text, icon) w.notes[#w.notes + 1] = { text = text:ToString(), icon = icon } end,
    })
end
engine(HW, true)
engine(CW, false)

local function make_zombie(w, role, loc, opts)
    set_world(w)
    opts = opts or {}
    local hidden = {}
    local anim = new(w, { "AnimBP_Zombie_C" }, "AnimBP_Zombie_C_" .. next_addr,
        { ["Movement Blendspace"] = w.paths["/Game/AI/Zombies/Walk.Walk"] }, {
        Montage_Play = function(self, m, rate) self._played = m; self._rate = rate; return 1.0 end,
    })
    local mid = new(w, { "MaterialInstanceDynamic" }, "MID_" .. next_addr, { Parent = w.paths[opts.mat or "/Game/Zombies/M_B.M_B"] })
    local mesh = new(w, { "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr,
        { SkeletalMeshAsset = w.paths[opts.mesh or "/Game/Zombies/SK_B.SK_B"] }, {
        GetMaterial = function(self) return self._mat end,
        SetMaterial = function(self, _, m) self._mat = m end,
        SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a end,
        IsBoneHiddenByName = function(_, fn) return hidden[fn._s] == true end,
        HideBoneByName = function(_, fn) hidden[fn._s] = true end,
        UnHideBoneByName = function(_, fn) hidden[fn._s] = nil end,
        GetAnimInstance = function() return anim end,
        K2_GetComponentLocation = function() return { X = loc.X, Y = loc.Y, Z = loc.Z - 90 } end,
        SetCollisionResponseToChannel = function(self, ch, r) rec(self, "resp" .. ch .. "=" .. r) end,
        SetCollisionEnabled = function(self, e) rec(self, "coll=" .. e) end,
        SetSimulatePhysics = function(self, b) rec(self, "physics=" .. tostring(b)) end,
        WakeAllRigidBodies = function(self) rec(self, "wake") end,
    })
    mesh._mat = mid
    local capsule = new(w, { "CapsuleComponent" }, "CollisionCylinder_" .. next_addr, {}, {
        SetCollisionEnabled = function(self, e) rec(self, "coll=" .. e) end,
    })
    local cmc = new(w, { "CharacterMovementComponent" }, "CMC_" .. next_addr, {}, {
        DisableMovement = function(self) rec(self, "disable") end,
    })
    local cue = new(w, { "AudioComponent" }, "Cue_" .. next_addr, {}, { Stop = function(self) rec(self, "stop") end })
    local dc = new(w, { "DamageComponent_C" }, "DamageComponent_" .. next_addr, {})
    local ai = new(w, { "SD_AIComponent_C" }, "SD_AI_" .. next_addr, {})
    local chain = opts.chain or { "BP_Zombie_Roamer_C", "BP_MasterZombie_C", "BP_Zombie_C", "Character" }
    local z = new(w, chain, chain[1] .. "_" .. (2147480000 + next_addr), {
        Role = role, Mesh = mesh, CapsuleComponent = capsule, CharacterMovement = cmc, Zombie_Cue = cue,
        Name = FText(opts.name or "Undead"), DamageComponent = dc, SD_AIComponent = ai, ["IsDead?"] = false, _loc = loc,
        HitAnimation = w.paths[HURT], AttackSound = w.paths["/Game/Sounds/ZombieAttack.ZombieAttack"],
        CrawlerArchetypeChance = 10, SprinterArchetypeChance = 10, BaseTranslationOffset = { X = 0, Y = 0, Z = -90 },
    })
    z._hidden, z._anim, z._root = hidden, anim, capsule
    z._m.GetCurrentMontage = function(self) return self._current end
    z._m.K2_GetRootComponent = function(self) return self._root end
    z._m.SetReplicateMovement = function(self, b) rec(self, "repmove=" .. tostring(b)) end
    z._m.AddComponentByClass = function(self, cls, manual, tf)
        rec(self, "addcomp")
        self._newtf = tf
        local c = new(w, { "SceneComponent" }, "SceneComponent_" .. next_addr)
        if not self._root and not manual then self._root = c end
        return c
    end
    z._m.Event_EyesCallback = function(self) rec(self, "eyes") end
    return z
end

-- players: own controller + pawn on each machine
local function players(w)
    set_world(w)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local lvl = new(w, { "LevellingComponent_C" }, "LevellingComponent",
        { CurrentLevel = 3, MultiplyValue = 1, Difficulty_MultiplierValue = 2 }, {
        AddXP = function(self, xp, _, out)
            assert(type(out) == "table", "AddXP out param must be a table")
            self._xp = (self._xp or 0) + xp
            out.XPOutput = xp * 2
        end,
        Event_LevelBarTimer = function(self) self._timer = true end,
    })
    local bar = new(w, { "W_EnemyHealthBarOverlay_C" }, "Bar_0", {}, { IsInViewport = function(self) return self._vp == true end })
    bar._vp = true
    local hud = new(w, { "HUD_Game_C" }, "HUD_Game_C_0", { EnemyHealthBarUI = bar }, {
        DaysSurvivedHUD = function(self) self._shown = true end,
        ["Re-Initialise"] = function(self) rec(self, "reinit"); self._p.EnemyHealthBarUI._vp = true end,
    })
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
        { Player = lp, ZombieKills = 10, HumanKills = 2, DaysSurvived = 3, LevellingComponent = lvl }, {
            GetHUD = function() return hud end,
            ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
            IsLocalController = function() return true end,
        })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, ["PlayerDead?"] = false })
    pawn._tags.Player = true
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn, w.lvl, w.hud, w.bar = pc, pawn, lvl, hud, bar
end
players(HW)
players(CW)

-- the remote player's controller on the host; its RPCs go to the client
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1", { _loc = { X = 500, Y = 0, Z = 0 } })
rpawn._tags.Player = true
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn, ZombieKills = 0, HumanKills = 0, DaysSurvived = 0 }, {
        ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end,
        ClientRepObjRef = function(_, o) HW.outbox[#HW.outbox + 1] = { objref = o } end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- host object -> client copy (what the client's net driver resolves)
local GUIDS = {}

-- ------------------------------------------------------------ modules per world
local CONFIG = {}
local function load_mods(w)
    set_world(w)
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx"), ai = require("sdc_ai") }
    m.cfg.load(nil)
    local get = m.cfg.get
    m.cfg.get = function(k)
        if CONFIG[k] ~= nil then return CONFIG[k] end
        return get(k)
    end
    m.net.install_hooks()
    return m
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = {} }
H.ai.init(HS)
H.ai.register_handlers()
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.ai.init(CS)
C.ai.register_handlers()

local function deliver()
    local out = HW.outbox
    HW.outbox = {}
    set_world(CW)
    for _, msg in ipairs(out) do
        if type(msg) == "table" then
            fire(CW, OBJREF, "pre", param(CW.pc), param(GUIDS[msg.objref]))
        else
            local kind, f = C.net.decode(msg)
            local h = C.net.handlers[kind]
            if h then h(f, CW.pc) end
        end
    end
end
local function host_tick() set_world(HW); H.ctx.tick({ rpc }); H.ai.host_tick({ rpc }) end
local function client_tick() set_world(CW); C.ai.client_tick() end
local function count_msgs(w, kind)
    local n = 0
    for _, m in ipairs(w.outbox) do if type(m) == "string" and m:find("|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end

local function run_timers(w)
    set_world(w)
    local t = w.timers
    w.timers = {}
    for _, fn in ipairs(t) do fn() end
end
local function last_msg(w) return w.outbox[#w.outbox] end

-- the log lines `fn` writes (sdc_log prints through the global print)
local function capture(fn)
    local lines, old = {}, print
    print = function(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(t, " ")
        old(...)
    end
    local ok, err = pcall(fn)
    print = old
    assert(ok, err)
    return lines
end
local function has_line(lines, s)
    for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end
    return false
end

-- ==================================================================== setup
print("== 0. defaults: kill hooks on the host")
host_tick(); client_tick()
check(HW.hooks[DAMAGE] ~= nil and HW.hooks[ZM .. "OnRep_IsDead?"] ~= nil and HW.hooks[ZM .. "Death"] ~= nil,
    "host: ApplyDamage, OnRep_IsDead?, Death hooked")

-- the vehicle class, the cars, the plain DamageType class, the seats
local VEH_PATH = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
set_world(HW)
local vcls = new(HW, { "BlueprintGeneratedClass" }, "BP_VehicleMaster_C")
vcls._target = "BP_VehicleMaster_C"
HW.paths[VEH_PATH] = vcls
local DT = new(HW, { "Class" }, "DamageType")                       -- BP_VehicleMaster @130 <DamageType>
local BODY = new(HW, { "BlueprintGeneratedClass" }, "Damage_Body_C")  -- weapons
local function car(name, loc)
    set_world(HW)
    local v = new(HW, { name:match("^(.-_C)_%d+$"), "BP_VehicleMaster_C", "WheeledVehiclePawn", "Pawn" }, name, { _loc = loc })
    HW.paths[v:GetFullName():match("^%S+%s+(.+)$")] = v
    return v
end
-- sdc_vehicles' seat API (host): [controller full name] = "driver" | "passenger"
local SEATS = {}
set_world(HW)
package.loaded["sdc_vehicles"] = { seat_of = function(key) return SEATS[key] end }
local function sit(pawn, v) pawn._m.GetAttachParentActor = function() return v end end
local function stand(pawn) pawn._m.GetAttachParentActor = nil end
local RKEY = rpc:GetFullName()

-- a second client (a 4-seat car)
set_world(HW)
local conn2 = new(HW, { "IpConnection" }, "IpConnection_1")
local rpawn2 = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_2", { _loc = { X = 900, Y = 0, Z = 0 } })
rpawn2._tags.Player = true
local rpc2 = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_2",
    { NetConnection = conn2, Player = conn2, Pawn = rpawn2, ZombieKills = 0 }, {
        ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end,
        ClientRepObjRef = function(_, o) HW.outbox[#HW.outbox + 1] = { objref = o } end,
    })
rpawn2._p.Controller = rpc2
local RKEY2 = rpc2:GetFullName()

-- one run-over of a zombie: BP_VehicleMaster.ApplyDamageToAIBasedOnSpeed ->
-- ApplyDamage(zombie, 320, None, <player 0 of the car>, DamageType) -> Death
local function run_over_zombie(loc, causer, dtype)
    HW.outbox = {}
    local z = make_zombie(HW, 3, loc)
    fire(HW, DAMAGE, "pre", param(nil), param(z), param(320.0), param(nil), param(causer), param(dtype or DT))
    fire(HW, ZM .. "OnRep_IsDead?", "bp", param(z))
    local who = H.ai.stand_in(z)
    fire(HW, ZM .. "Death", "bp", param(z), param(causer), param(false))
    fire(HW, DAMAGE, "post")
    return who, count_msgs(HW, "AIKILL"), z
end

local suv = car("Vehicle_SUV_C_2147400500", { X = 5000, Y = 0, Z = 0 })
CW.pc._p.BossZombieKills, CW.pc._p.AnimalKills = 0, 0

-- ==================================================================== A. the report
print("== A. a client drives, the host rides along (the report): the run-over is the driver's")
sit(rpawn, suv); sit(HW.pawn, suv)
SEATS[RKEY] = "driver"
local ck0 = CW.pc._p.ZombieKills
local hk0 = HW.pc._p.ZombieKills
-- sdc_vehicles answers player 0 of the car with the host (it sits in it): causer = the host's character
local who, n
local lines = capture(function() who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, HW.pawn) end)
check(who == rpc, "zombie dying: player 0 = the driver's controller (not the host)")
check(n == 1, "AIKILL sent to the driver")
check(has_line(lines, "ai: kills: vehicle: Vehicle_SUV_C_2147400500 hit BP_Zombie_Roamer_C_")
    and has_line(lines, "-> BP_PlayerController_C_1 (driver)"), "host log: the car's hit, credited to its driver")
check(has_line(lines, "(Zombie Killed, vehicle, redirected=true) -> credited to that player"),
    "host log: the kill line names the vehicle")
check(HW.pc._p.ZombieKills == hk0, "host's own ZombieKills untouched")
local xp0, notes0 = CW.lvl._xp or 0, #CW.notes
deliver()
check(CW.pc._p.ZombieKills == ck0 + 1, "client ZombieKills +1")
check((CW.lvl._xp or 0) > xp0, "client: XP added on its own controller")
check(#CW.notes == notes0 + 1 and CW.notes[#CW.notes].text:find("^Zombie Killed, XP Given: ") ~= nil,
    "client: popup 'Zombie Killed, XP Given: N': " .. tostring(CW.notes[#CW.notes] and CW.notes[#CW.notes].text))

print("== B. a client drives alone: still the driver's")
stand(HW.pawn)
who, n = run_over_zombie({ X = 5300, Y = 200, Z = 0 }, rpawn)
check(who == rpc and n == 1, "causer = the driver's character: credited to it")
deliver()

print("== C. a client drives, the host stands by looking at the car: the driver's")
-- sdc_vehicles gives the host's character while the host looks at it
who, n = run_over_zombie({ X = 5500, Y = -300, Z = 0 }, HW.pawn)
check(who == rpc and n == 1, "the car near the victim has a client at the wheel")
deliver()

print("== D. the host drives, a client rides along: the host's")
SEATS[RKEY] = "passenger"
sit(HW.pawn, suv)
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "host at the wheel: no stand-in, no AIKILL")
-- right after the passenger got in sdc_vehicles names it for 1 s: still the host's
who, n = run_over_zombie({ X = 5400, Y = 100, Z = 0 }, rpawn)
check(who == nil and n == 0, "causer = the passenger's character: the host drives, the host's")
HW.outbox = {}

print("== E. 4 seats: one client drives, the other rides behind, the host away: only the driver")
stand(HW.pawn)
HS.remote_pcs[2] = rpc2
HW.pcs[3] = rpc2
sit(rpawn2, suv); sit(rpawn, suv)
SEATS[RKEY2], SEATS[RKEY] = "driver", "passenger"
who = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, rpawn2)
check(who == rpc2, "causer = the driver: the driver's")
who = run_over_zombie({ X = 5400, Y = 50, Z = 0 }, rpawn)
check(who == rpc2, "causer = a passenger (sdc_vehicles' window): still the driver's")
HW.outbox = {}
HS.remote_pcs[2] = nil
HW.pcs[3] = nil
stand(rpawn2); SEATS[RKEY2] = nil

print("== F. the car rolls on after its client driver got out")
SEATS[RKEY] = "driver"
sit(rpawn, suv)
advance(1); host_tick()                   -- the tick sees the client at the wheel
SEATS[RKEY] = nil; stand(rpawn)           -- VEXIT
advance(1.5)
who, n = run_over_zombie({ X = 5600, Y = 0, Z = 0 }, HW.pawn)
check(who == rpc and n == 1, "within the grace window: the last driver's")
deliver()
advance(5); host_tick()
who, n = run_over_zombie({ X = 5600, Y = 100, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "long after: nobody drives, the host's (as the game)")
HW.outbox = {}

print("== G. the client got out, the host sits in the car (takes the wheel): the host's")
SEATS[RKEY] = "driver"; sit(rpawn, suv)
advance(1); host_tick()
SEATS[RKEY] = nil; stand(rpawn); sit(HW.pawn, suv)
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "no client at the wheel, the host in it: the host's")
-- the host drove it last (a tick saw it at the wheel), got out, the car rolls on
advance(0.5); host_tick()
stand(HW.pawn)
advance(0.5)
who, n = run_over_zombie({ X = 5600, Y = 0, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "the host drove it after the client: its roll is the host's, not the client's")
advance(5); host_tick()
HW.outbox = {}

print("== G2. the driver got out, a passenger stayed (parked) and took the wheel with its seat key: the new driver's")
-- (sdc_vehicles: the driver's exit moves nobody; the seat key makes the
-- passenger the driver - its seat_of answer "driver", mock_vehicles_seats K7)
HS.remote_pcs[2] = rpc2
HW.pcs[3] = rpc2
SEATS[RKEY], SEATS[RKEY2] = "driver", "passenger"
sit(rpawn, suv); sit(rpawn2, suv)
advance(1); host_tick()
SEATS[RKEY] = nil; stand(rpawn)            -- VEXIT: Friend2 stays in its seat, the car parked
advance(5); host_tick()
who, n = run_over_zombie({ X = 5600, Y = 0, Z = 0 }, rpawn2)
check(who == nil and n == 0, "parked, nobody at the wheel: a passenger as the causer gets nothing (the host's, as the game)")
HW.outbox = {}
SEATS[RKEY2] = "driver"                    -- its seat key: the wheel
advance(1); host_tick()
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, rpawn2)
check(who == rpc2 and n == 1, "after its seat key: the new driver's run-over is its kill")
who = run_over_zombie({ X = 5400, Y = 50, Z = 0 }, HW.pawn)
check(who == rpc2, "causer = the host's character (a player-0 window): still the new driver's")
HW.outbox = {}
SEATS[RKEY2] = nil; stand(rpawn2)
advance(5); host_tick()
HS.remote_pcs[2] = nil
HW.pcs[3] = nil

print("== H. weapons are not run-overs")
SEATS[RKEY] = "driver"; sit(rpawn, suv); sit(HW.pawn, suv)
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, HW.pawn, BODY)
check(who == nil and n == 0, "the host's bullet (Damage_Body_C) from the client's car: the host's")
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, rpawn, BODY)
check(who == rpc and n == 1, "the client's bullet: the client's, as before")
deliver()
-- a DamageType hit with an instigator (the stomp: its controller) is no car's
HW.outbox = {}
local zs = make_zombie(HW, 3, { X = 5400, Y = 0, Z = 0 })
fire(HW, DAMAGE, "pre", param(nil), param(zs), param(30.0), param(HW.pc), param(HW.pawn), param(DT))
fire(HW, ZM .. "OnRep_IsDead?", "bp", param(zs))
check(H.ai.stand_in(zs) == nil, "the host's stomp next to the client's car: the host's")
fire(HW, ZM .. "Death", "bp", param(zs), param(HW.pawn), param(false))
fire(HW, DAMAGE, "post")
check(count_msgs(HW, "AIKILL") == 0, "no AIKILL for the host's stomp")

print("== I. no car near the victim: the causer decides, as before")
lines = capture(function() who, n = run_over_zombie({ X = 9000, Y = 0, Z = 0 }, HW.pawn) end)
check(who == nil and n == 0, "host's character, no car within reach: the host's")
check(has_line(lines, "ai: kills: vehicle: a car-like hit on BP_Zombie_Roamer_C_")
    and has_line(lines, "no car within 12 m: the causer decides"), "host log: a car-like hit with no car near")
HW.outbox = {}
-- the host's hunger tick while riding in the client's car (ApplyDamage(self, d, None, self, DamageType)): no car's hit
set_world(HW)
local KM = package.loaded["sdc_ai_kills"]
local vd0, vh0 = KM.stats.veh_driver, KM.stats.veh_host
local hloc = HW.pawn._p._loc
HW.pawn._p._loc = { X = 5000, Y = 60, Z = 0 }   -- in its seat
fire(HW, DAMAGE, "pre", param(nil), param(HW.pawn), param(1.0), param(nil), param(HW.pawn), param(DT))
fire(HW, DAMAGE, "post")
HW.pawn._p._loc = hloc
check(KM.stats.veh_driver == vd0 and KM.stats.veh_host == vh0, "a player's own hunger damage is no vehicle hit")

print("== J. a bandit run over by the client-driven car, the host riding along")
set_world(HW)
local BM = "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C:"
local b = new(HW, { "BP_Bandit_C", "BP_MasterBandit_C", "Character" }, "BP_Bandit_C_2147400600",
    { BP_AIComponent = new(HW, { "BP_AIComponent_C" }, "AIC_V1", { Dead = false }), ["XpPopUpEnabled?"] = true,
      _loc = { X = 5400, Y = 0, Z = 0 } })
host_tick()
check(HW.hooks[BM .. "ReceiveAnyDamage"] ~= nil, "bandit hooks installed")
HW.outbox = {}
fire(HW, DAMAGE, "pre", param(nil), param(b), param(320.0), param(nil), param(HW.pawn), param(DT))
fire(HW, BM .. "ReceiveAnyDamage", "bp", param(b), param(320.0), param(nil), param(nil), param(HW.pawn))
fire(HW, DAMAGE, "post")
advance(0.1)
b._p.BP_AIComponent._p.Dead = true
fire(HW, BM .. "StopBurning", "bp", param(b))
check(H.ai.stand_in(b) == rpc, "bandit dying: player 0 = the driver's controller")
fire(HW, BM .. "Death", "bp", param(b), param(HW.pawn))
check(count_msgs(HW, "AIKILL") == 1 and last_msg(HW) == "SDC1|AIKILL|h|1|0", "AIKILL|h|1|0: " .. tostring(last_msg(HW)))
deliver()
-- the host drives, the passenger's window names the passenger: the host's
SEATS[RKEY] = "passenger"
local b2 = new(HW, { "BP_Bandit_C", "BP_MasterBandit_C", "Character" }, "BP_Bandit_C_2147400601",
    { BP_AIComponent = new(HW, { "BP_AIComponent_C" }, "AIC_V2", { Dead = false }), _loc = { X = 5400, Y = 0, Z = 0 } })
HW.outbox = {}
fire(HW, DAMAGE, "pre", param(nil), param(b2), param(320.0), param(nil), param(rpawn), param(DT))
fire(HW, BM .. "ReceiveAnyDamage", "bp", param(b2), param(320.0), param(nil), param(nil), param(rpawn))
fire(HW, DAMAGE, "post")
b2._p.BP_AIComponent._p.Dead = true
fire(HW, BM .. "StopBurning", "bp", param(b2))
check(H.ai.stand_in(b2) == nil, "host at the wheel: the bandit is the host's")
fire(HW, BM .. "Death", "bp", param(b2), param(rpawn))
check(count_msgs(HW, "AIKILL") == 0, "no AIKILL")
SEATS[RKEY] = "driver"

print("== K. the zombie boss run over (DeathEvent inside the damage call)")
local BOSSP = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C:"
HW.outbox = {}
HW.timers = {}
local boss = make_zombie(HW, 3, { X = 5400, Y = 0, Z = 0 }, { chain = { "BP_ZombieBoss_C", "BP_MainEnemy_C", "Character" } })
host_tick()
check(HW.hooks[BOSSP .. "DeathEvent"] ~= nil, "boss DeathEvent hooked")
fire(HW, DAMAGE, "pre", param(nil), param(boss), param(320.0), param(nil), param(HW.pawn), param(DT))
boss._p["IsDead?"] = true
fire(HW, BOSSP .. "DeathEvent", "bp", param(boss), param(HW.pawn))
fire(HW, DAMAGE, "post")
check(H.ai.stand_in(boss) == rpc, "boss credit frame: player 0 = the driver's controller")
advance(1.0); run_timers(HW)
check(last_msg(HW) == "SDC1|AIKILL|b||1", "AIKILL|b||1: " .. tostring(last_msg(HW)))
deliver()

print("== L. a deer run over (latent credit)")
local DM = "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C:"
set_world(HW)
local deer = new(HW, { "BP_AnimalDeer_C", "BP_Animal_C", "Character" }, "BP_AnimalDeer_C_2147400700",
    { ["IsDead?"] = false, _loc = { X = 5400, Y = 0, Z = 0 } })
host_tick()
HW.outbox = {}
fire(HW, DAMAGE, "pre", param(nil), param(deer), param(320.0), param(nil), param(HW.pawn), param(DT))
deer._p["IsDead?"] = true
fire(HW, DM .. "ReceiveAnyDamage", "bp", param(deer), param(320.0), param(nil), param(nil), param(HW.pawn))
fire(HW, DAMAGE, "post")
check(H.ai.stand_in(deer) == rpc, "deer credit frame: player 0 = the driver's controller")
advance(1.0); run_timers(HW)
check(last_msg(HW) == "SDC1|AIKILL|d||0", "AIKILL|d||0: " .. tostring(last_msg(HW)))
deliver()

print("== M. a soldier run over by the client-driven car: the kill line names the vehicle")
set_world(HW)
local SM = "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C:"
local sold = new(HW, { "BP_CoyoteSoldier_C", "BP_MasterCoyoteSoldier_C", "Character" }, "BP_CoyoteSoldier_C_2147400610",
    { BP_AIComponent = new(HW, { "BP_AIComponent_C" }, "AIC_V3", { Dead = false }), ["XpPopUpEnabled?"] = false,
      _loc = { X = 5400, Y = -100, Z = 0 } })
sit(rpawn, suv); sit(HW.pawn, suv); SEATS[RKEY] = "driver"
host_tick()
HW.outbox = {}
H.log.debug_enabled = true          -- the per-kill lines past their first few
lines = capture(function()
    fire(HW, DAMAGE, "pre", param(nil), param(sold), param(320.0), param(nil), param(HW.pawn), param(DT))
    fire(HW, SM .. "ReceiveAnyDamage", "bp", param(sold), param(320.0), param(nil), param(nil), param(HW.pawn))
    fire(HW, DAMAGE, "post")
    advance(0.1)
    sold._p.BP_AIComponent._p.Dead = true
    fire(HW, SM .. "StopBurning", "bp", param(sold))
    who = H.ai.stand_in(sold)
    fire(HW, SM .. "Death", "bp", param(sold), param(HW.pawn))
end)
H.log.debug_enabled = false
check(who == rpc, "soldier dying: player 0 = the driver's controller")
check(last_msg(HW) == "SDC1|AIKILL|s|0|0", "AIKILL|s|0|0: " .. tostring(last_msg(HW)))
check(has_line(lines, "killed BP_CoyoteSoldier_C_2147400610 (Soldier Killed, vehicle,"), "host log: source = vehicle")
deliver()

print("== N. the host drives, a client rides along: the boss and a deer are the host's")
SEATS[RKEY] = "passenger"
sit(rpawn, suv); sit(HW.pawn, suv)
HW.outbox = {}
HW.timers = {}
local boss2 = make_zombie(HW, 3, { X = 5400, Y = 0, Z = 0 }, { chain = { "BP_ZombieBoss_C", "BP_MainEnemy_C", "Character" } })
fire(HW, DAMAGE, "pre", param(nil), param(boss2), param(320.0), param(nil), param(rpawn), param(DT))
boss2._p["IsDead?"] = true
fire(HW, BOSSP .. "DeathEvent", "bp", param(boss2), param(rpawn))
fire(HW, DAMAGE, "post")
check(H.ai.stand_in(boss2) == nil, "boss: causer = the passenger (its window), the host drives: no stand-in")
local deer2 = new(HW, { "BP_AnimalDeer_C", "BP_Animal_C", "Character" }, "BP_AnimalDeer_C_2147400701",
    { ["IsDead?"] = false, _loc = { X = 5400, Y = 0, Z = 0 } })
fire(HW, DAMAGE, "pre", param(nil), param(deer2), param(320.0), param(nil), param(HW.pawn), param(DT))
deer2._p["IsDead?"] = true
fire(HW, DM .. "ReceiveAnyDamage", "bp", param(deer2), param(320.0), param(nil), param(nil), param(HW.pawn))
fire(HW, DAMAGE, "post")
check(H.ai.stand_in(deer2) == nil, "deer: the host drives: no stand-in")
advance(1.0); run_timers(HW)
check(count_msgs(HW, "AIKILL") == 0, "no AIKILL for the host-driven car's boss and deer")
SEATS[RKEY] = "driver"

print("== O. a bear run over by the client-driven car (credited inside the damage call)")
local EM = "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C:"
set_world(HW)
local bear = new(HW, { "BP_AnimalBear_C", "BP_Animal_C", "Character" }, "BP_AnimalBear_C_2147400702",
    { ["IsDead?"] = false, _loc = { X = 5400, Y = 0, Z = 0 } })
host_tick()
check(HW.hooks[EM .. "Death"] ~= nil, "bear Death hooked")
HW.outbox = {}
fire(HW, DAMAGE, "pre", param(nil), param(bear), param(320.0), param(nil), param(HW.pawn), param(DT))
bear._p["IsDead?"] = true
fire(HW, EM .. "Death", "bp", param(bear))
check(H.ai.stand_in(bear) == rpc, "bear credit: player 0 = the driver's controller")
fire(HW, EM .. "ReceiveAnyDamage", "bp", param(bear), param(320.0), param(nil), param(nil), param(HW.pawn))
fire(HW, DAMAGE, "post")
check(last_msg(HW) == "SDC1|AIKILL|e||0", "AIKILL|e||0: " .. tostring(last_msg(HW)))
deliver()

print("== P. two cars: the host drives its own car 8 m from the client's")
local van = car("Vehicle_Van_C_2147400510", { X = 5000, Y = 800, Z = 0 })
stand(HW.pawn); sit(HW.pawn, van)
sit(rpawn, suv); SEATS[RKEY] = "driver"
advance(5); host_tick()
who, n = run_over_zombie({ X = 5000, Y = 1200, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "the host's car hits (causer = the host in it): the host's")
who, n = run_over_zombie({ X = 4600, Y = -400, Z = 0 }, rpawn)
check(who == rpc and n == 1, "the client's car hits (causer = its driver): the client's")
deliver()
who, n = run_over_zombie({ X = 4600, Y = -400, Z = 0 }, HW.pawn)
check(who == rpc and n == 1, "the client's car hits, causer = the host (looking at it), the host's car 12.6 m off: the client's")
deliver()
stand(HW.pawn)

print("== Q. the car rolls on, but its last driver has left the game: the host's")
HS.remote_pcs[2] = rpc2
HW.pcs[3] = rpc2
sit(rpawn2, suv); sit(rpawn, van)
SEATS[RKEY2], SEATS[RKEY] = "driver", "driver"
advance(1); host_tick()
SEATS[RKEY2] = nil; stand(rpawn2)
HS.remote_pcs[2] = nil
HW.pcs[3] = nil
advance(1)
set_world(HW)
local qd, qh = KM.stats.veh_driver, KM.stats.veh_host
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "no controller for the last driver: the host's (as the game)")
check(KM.stats.veh_host == qh + 1 and KM.stats.veh_driver == qd, "counted as the host's hit")
HW.outbox = {}
stand(rpawn); SEATS[RKEY] = nil

print("== R. no seat record says \"driver\" (seat_of changed or lost it): a lone client driver keeps its kill, as before")
advance(5); host_tick()
sit(rpawn, suv); SEATS[RKEY] = nil
H.log.debug_enabled = true          -- the vehicle lines past their first 20
lines = capture(function() who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, rpawn) end)
H.log.debug_enabled = false
check(who == rpc and n == 1, "no seat record, causer = the client alone in its car: the client's")
check(has_line(lines, "-> BP_PlayerController_C_1 (its player 0, no driver seat record)"), "host log: the fallback named")
deliver()
SEATS[RKEY] = "seat1"                     -- an answer this module does not know
who, n = run_over_zombie({ X = 5400, Y = 100, Z = 0 }, rpawn)
check(who == rpc and n == 1, "an unknown seat word: the client's")
deliver()
-- the fallback noted it as the driver: the car rolls on after it got out
SEATS[RKEY] = nil; stand(rpawn)
advance(1)
who, n = run_over_zombie({ X = 5600, Y = 0, Z = 0 }, HW.pawn)
check(who == rpc and n == 1, "then it got out, the car rolls on: still its")
deliver()
advance(5); host_tick()
-- a client seated as a passenger is never the fallback's
sit(rpawn, suv); SEATS[RKEY] = "passenger"
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, rpawn)
check(who == nil and n == 0, "causer = a passenger, nobody at the wheel: not the passenger's")
-- the host rides along, no seat record: the host's, as before the vehicle credit
SEATS[RKEY] = nil; sit(HW.pawn, suv)
who, n = run_over_zombie({ X = 5400, Y = 0, Z = 0 }, HW.pawn)
check(who == nil and n == 0, "no seat record, the host in the car (causer = the host): the host's")
-- the client as the causer with the host in the car (sdc_vehicles' get-in window), no seat record: the host's
who, n = run_over_zombie({ X = 5400, Y = 50, Z = 0 }, rpawn)
check(who == nil and n == 0, "no seat record, the host in the car, causer = the client: the host's")
stand(HW.pawn); stand(rpawn)
HW.outbox = {}
-- the fallback is only for a causer sitting in the car that hit: a second
-- client drove it and got out, the first one stands by as the causer
HS.remote_pcs[2] = rpc2
HW.pcs[3] = rpc2
sit(rpawn2, suv); SEATS[RKEY2] = "driver"
advance(1); host_tick()
SEATS[RKEY2] = nil; stand(rpawn2)
advance(1)
who = run_over_zombie({ X = 5600, Y = 0, Z = 0 }, rpawn)
check(who == rpc2, "causer = a client outside the car: the roll is its last driver's")
HW.outbox = {}
HS.remote_pcs[2] = nil
HW.pcs[3] = nil
advance(5); host_tick()

print("== status")
set_world(HW)
local line
for _, l in ipairs(H.ai.status_lines()) do
    if l:find("ai: kills", 1, true) then line = l end
end
print("  host   " .. tostring(line))
check(line ~= nil and line:find("vehicle hits: driver=", 1, true) ~= nil, "status line counts vehicle hits")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
