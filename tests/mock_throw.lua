-- Mock harness: runs the real sdc_throw (+ sdc_ue / sdc_net / sdc_ctx / sdc_config /
-- sdc_log) against fake UE objects, one world for the host and one for the client.
-- usage: lua mock_throw.lua <scripts dir>
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
local next_num = 2147400000
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return {
        IsValid = function() return true end,
        GetFName = function() return name_obj(chain[1]) end,
    }
end
local function new(w, chain, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _full = nil, _w = w }, Obj)
    w.objects[#w.objects + 1] = o
    w.paths["/Game/Levels/PL.PL:PersistentLevel." .. name] = o
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
function Obj:K2_GetActorRotation() return self._p._rot or { Pitch = 0, Yaw = 0, Roll = 0 } end
function Obj:K2_SetActorLocation(loc, sweep, hit, tp)
    assert(type(hit) == "table", "K2_SetActorLocation out param must be a table")
    self._p._loc = { X = loc.X, Y = loc.Y, Z = loc.Z }
    self._moved = (self._moved or 0) + 1
end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:K2_DestroyActor() self._valid = false end

local function asset(w, cls, path, methods)
    local o = new(w, { cls }, path:match("([^%.:]+)$"), {}, methods)
    o._full = cls .. " " .. path
    w.paths[path] = o
    return o
end

local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v)
    return { get = function() return v end, set = function(_, nv) v = nv end, _v = function() return v end }
end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    if WORLD.refuse_hooks and WORLD.refuse_hooks[path] then error("function not found: " .. path) end
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
UnregisterHook = function() end
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
    local t = w.timers
    w.timers = {}
    for _, fn in ipairs(t) do fn() end
end

-- a hook as UE4SS calls it: BP hooks one callback; natives pre/post
local function fire(w, path, kind, ...)
    local prev = WORLD
    WORLD = w
    local hs = w.hooks[path]
    if not hs then WORLD = prev; return false end
    for _, h in ipairs(hs) do
        local fn = (kind == "post") and h.post or h.pre
        if fn then
            local r = fn(...)
            assert(r == nil, "hook returned a value: " .. path)
        end
    end
    WORLD = prev
    return true
end

-- ---------------------------------------------------------------- worlds
local FN_VELOCITY = "/Script/Engine.PrimitiveComponent:SetPhysicsLinearVelocity"
local FN_ROTATE = "/Script/Engine.SceneComponent:K2_SetWorldRotation"
local FN_PROXY = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"
local FN_PLAY_SOUND = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local FN_SPAWN_SOUND = "/Script/Engine.GameplayStatics:SpawnSoundAtLocation"
local FN_VIEWPORT = "/Script/UMG.UserWidget:AddToViewport"
local FN_NUMBERS = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:SpawnDamageNumbers"
local HIT = "BndEvt__BP_Throwable_Molotov_Capsule_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature"
local MONTAGE = "/Game/Character/Anims/Interaction/Chr_Throw_Montage.Chr_Throw_Montage"

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, refuse_hooks = {} }
end
local HW, CW = world("host"), world("client")

local THROWABLES = {
    BP_Throwable_Frag_C = { event = "Frag", delay = 3.0 },
    BP_Throwable_PipeBomb_C = { event = "PipeBomb", delay = 3.0 },
    BP_Throwable_NoiseMaker_C = { event = "NoiseMaker", delay = 3.0 },
    BP_Throwable_Molotov_C = { hit = true, delay = 4.0 },
    BP_Throwable_GlassBottle_C = { hit = true, delay = 3.0 },
}

-- a projectile as the game's BP class makes it
local function make_projectile(w, cls_short, tf, owner)
    local spec = THROWABLES[cls_short]
    next_num = next_num + 1
    local cap
    local a = new(w, { cls_short, "BP_MasterThrowable_C", "Actor" }, cls_short .. "_" .. next_num,
        { _loc = { X = tf.Translation.X, Y = tf.Translation.Y, Z = tf.Translation.Z }, _owner = owner,
          ExplosionDelay = spec.delay }, {})
    a._events = {}
    cap = new(w, { "CapsuleComponent" }, "Capsule_" .. next_num, { _notify = true, _sim = true, _owner = a }, {
        SetNotifyRigidBodyCollision = function(self, on) self._p._notify = on end,
        SetSimulatePhysics = function(self, on) self._p._sim = on end,
        SetPhysicsLinearVelocity = function(self, v, add, bone)
            -- the native hook fires for any UFunction call (BP or Lua)
            fire(w, FN_VELOCITY, "pre", param(self), param(v), param(add), param(bone))
            self._p._vel = { X = v.X, Y = v.Y, Z = v.Z }
            self._vel_calls = (self._vel_calls or 0) + 1
        end,
        GetPhysicsLinearVelocity = function(self) return self._p._vel or { X = 0, Y = 0, Z = 0 } end,
        GetPhysicsAngularVelocityInDegrees = function() return { X = 1, Y = 2, Z = 3 } end,
        SetPhysicsAngularVelocityInDegrees = function(self, v) self._p._ang = v end,
    })
    a._p.Capsule = cap
    if spec.event then
        a._m[spec.event] = function(self) self._events[#self._events + 1] = spec.event .. "@" .. tostring(self._p.ExplosionDelay) end
    end
    if spec.hit then
        a._m[HIT] = function(self, hc, oa, oc, imp, hit)
            assert(hc == nil or hc == cap, "hit component")
            self._events[#self._events + 1] = "hit"
        end
    end
    return a
end

local function engine(w, is_server)
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "Default__KismetSystemLibrary", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    })
    w.spawned = {}
    w.paths["/Script/Engine.Default__GameplayStatics"] = new(w, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf, coll, owner, scale)
            assert(type(tf) == "table" and tf.Rotation and tf.Rotation.W, "transform with a quaternion")
            assert(coll == 1, "AlwaysSpawn")
            local a = make_projectile(w, cls._name, tf, owner)
            w.spawned[#w.spawned + 1] = a
            return a
        end,
        FinishSpawningActor = function(_, a) return a end,
    })
    for short in pairs(THROWABLES) do
        local base = short:sub(1, -3)
        local c = asset(w, "BlueprintGeneratedClass", "/Game/Blueprints/Throwables/" .. base .. "." .. short)
        c._name = short
        if THROWABLES[short].hit then
            asset(w, "Function", "/Game/Blueprints/Throwables/" .. base .. "." .. short .. ":" .. HIT)
        end
    end
    w.montage = asset(w, "AnimMontage", MONTAGE, { GetPlayLength = function() return 2.18 end })
    w.gfl = new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C")
end
engine(HW, true)
engine(CW, false)

local function players(w)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local anim = new(w, { "AnimBP_PlayerCharacter_C" }, "AnimInstance_0", {}, {
        Montage_Play = function(self, m, rate, rt, at, stop) self._played = m; self._n = (self._n or 0) + 1; return 2.18 end,
    })
    local mesh = new(w, { "SkeletalMeshComponent" }, "CharacterMesh0", {}, { GetAnimInstance = function() return anim end })
    local capsule = new(w, { "CapsuleComponent" }, "CollisionCylinder", {})
    local ps = new(w, { "PlayerState" }, "PlayerState_0", {}, { GetPlayerId = function() return 256 end })
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 100 }, Mesh = mesh, CapsuleComponent = capsule, PlayerState = ps }, {
            GetCurrentMontage = function(self) return self._montage end,
        })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn, w.anim, w.mesh, w.capsule = pc, pawn, anim, mesh, capsule
end
players(HW)
players(CW)

-- the client's controller and character on the host
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rps = new(HW, { "PlayerState" }, "PlayerState_1", {}, { GetPlayerId = function() return 257 end })
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1",
    { _loc = { X = 0, Y = 0, Z = 100 }, PlayerState = rps })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    return { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
             ctx = require("sdc_ctx"), throw = require("sdc_throw") }
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = {} }
H.throw.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.throw.install(CS)

local function deliver()
    for _ = 1, 4 do
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
local function sent(w, kind)
    local n = 0
    for _, m in ipairs(w.outbox) do if m:find("SDC1|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end
local function host_tick() WORLD = HW; H.throw.tick() end
local function client_tick() WORLD = CW; C.throw.tick() end
local function live(w, short)
    local out = {}
    for _, o in ipairs(w.objects) do if o._valid and o._chain[1] == short then out[#out + 1] = o end end
    return out
end
local function game_throw(w, short, loc, vel)
    -- BP_PlayerCharacter @14507: deferred spawn, finish, Event_Throw, velocity
    WORLD = w
    local gs = w.paths["/Script/Engine.Default__GameplayStatics"]
    local tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local cls = w.paths["/Game/Blueprints/Throwables/" .. short:sub(1, -3) .. "." .. short]
    local a = gs:BeginDeferredActorSpawnFromClass(w.pawn, cls, tf, 1, nil, 0)
    a._p.Capsule:SetPhysicsLinearVelocity(vel, false, FName("None"))
    return a
end

-- ---------------------------------------------------------------- 1. hooks
print("== 1. hooks")
HW.refuse_hooks[FN_NUMBERS] = true   -- the Blueprint library is not loaded yet
host_tick()
client_tick()
check(HW.hooks[FN_VELOCITY] and HW.hooks[FN_PLAY_SOUND] and HW.hooks[FN_SPAWN_SOUND] and HW.hooks[FN_VIEWPORT], "host native hooks")
check(not HW.hooks[FN_ROTATE] and not HW.hooks[FN_PROXY], "no client gate hooks on the host")
check(not HW.hooks[FN_NUMBERS], "SpawnDamageNumbers not hooked while not loaded")
check(CW.hooks[FN_VELOCITY] and CW.hooks[FN_ROTATE] and CW.hooks[FN_PROXY], "client hooks")
check(not CW.hooks[FN_PLAY_SOUND], "no sound hook on the client")
HW.refuse_hooks[FN_NUMBERS] = nil
host_tick()
check(not HW.hooks[FN_NUMBERS], "retry waits 2 s")
advance(2.1)
host_tick()
check(HW.hooks[FN_NUMBERS] ~= nil, "SpawnDamageNumbers hooked on retry")

-- ---------------------------------------------------------------- 2. gate
print("== 2. one throw, one consume request")
WORLD = CW
fire(CW, FN_ROTATE, "pre", param(CW.capsule), param({ Pitch = 0, Yaw = 30, Roll = 0 }), param(false), param({}), param(false))
check(CW.anim._played == CW.montage and CW.anim._n == 1, "throw montage played locally at once")
CW.pawn._montage = CW.montage
fire(CW, FN_ROTATE, "pre", param(CW.capsule), param({}), param(false), param({}), param(false))
check(CW.anim._n == 1, "not twice")
local other = new(CW, { "SceneComponent" }, "Sun", {})
fire(CW, FN_ROTATE, "pre", param(other), param({}), param(false), param({}), param(false))
check(CW.anim._n == 1, "other components ignored")
advance(0.08)
local start = param(0.0)
fire(CW, FN_PROXY, "pre", param(CW.w and nil or new(CW, { "Default" }, "Default__PlayMontageCallbackProxy")), param(CW.mesh),
    param(CW.montage), param(1.0), start, param(FName("None")), param(true))
check(math.abs(start._v() - 0.08) < 1e-6, "server's MC_Montage continues at 0.08 s (got " .. tostring(start._v()) .. ")")
local start2 = param(0.0)
fire(CW, FN_PROXY, "pre", param(nil), param(CW.mesh), param(CW.montage), param(1.0), start2, param(FName("None")), param(true))
check(start2._v() == 0.0, "only the first MC_Montage is aligned")
CW.pawn._montage = nil

-- ---------------------------------------------------------------- 3. client's frag
print("== 3. client throws a frag")
local orig = game_throw(CW, "BP_Throwable_Frag_C", { X = 30, Y = 0, Z = 150 }, { X = 2000, Y = 0, Z = 300 })
check(sent(CW, "THROW") == 1, "THROW sent to the host")
check(CW.outbox[1]:find("BP_Throwable_Frag_C|30.0,0.0,150.0|", 1, true) ~= nil, "THROW carries class and spawn point: " .. CW.outbox[1])
check(orig._p.Capsule._p._notify == true, "fuse class keeps its hit events (bounce damping)")
-- the BP's own bounce damping later: ignored
orig._p.Capsule:SetPhysicsLinearVelocity({ X = 1000, Y = 0, Z = 0 }, false, FName("None"))
check(sent(CW, "THROW") == 1, "damping call is not a new throw")
run_timers(CW)
check(orig._valid == false, "game's projectile destroyed (its fuse with it)")
local copies = live(CW, "BP_Throwable_Frag_C")
check(#copies == 1, "one visual copy")
local copy = copies[1]
check(copy and copy._p.Capsule._p._vel.X == 1000 and copy._p.Capsule._p._ang ~= nil, "copy continues with the original's motion")
check(copy and #copy._events == 0, "copy has no fuse")
check(copy and copy._p.Capsule._vel_calls == 1, "copy's velocity call did not re-enter as a throw")
deliver()
local hcopy = live(HW, "BP_Throwable_Frag_C")[1]
check(hcopy ~= nil, "host spawned the frag")
check(hcopy and hcopy._p._owner == rpawn, "host's frag owned by the client's character")
check(hcopy and hcopy._p.Capsule._p._vel.X == 2000 and hcopy._p.Capsule._p._notify == true, "host's frag: client's velocity, hit events on")
check(hcopy and hcopy._p._loc.X == 30 and hcopy._p._loc.Z == 150, "host's frag at the client's spawn point")
WORLD = HW
check(H.ctx.player_for(hcopy) ~= nil, "sdc_ctx answers player 0 with the client inside the host's frag")
-- the same message twice
WORLD = HW
H.net.handlers.THROW({ "1", "BP_Throwable_Frag_C", "30.0,0.0,150.0", "0.0,0.0,0.0", "2000.0,0.0,300.0" }, rpc)
check(#live(HW, "BP_Throwable_Frag_C") == 1, "duplicate THROW ignored")
-- explosion on the host
advance(3.0)
fire(HW, FN_PLAY_SOUND, "pre", param(H.ue.gameplay_statics()), param(hcopy), param(asset(HW, "SoundCue", "/Game/explosion_large_06_Cue.explosion_large_06_Cue")),
    param({ X = 900, Y = 10, Z = 20 }))
check(sent(HW, "THRFX") == 1, "THRFX boom sent")
-- a second sound of the same projectile: nothing
fire(HW, FN_PLAY_SOUND, "pre", param(H.ue.gameplay_statics()), param(hcopy), param(nil), param({ X = 0, Y = 0, Z = 0 }))
check(sent(HW, "THRFX") == 1, "one THRFX per phase")
-- its damage numbers: the stray widget and the forward
local wdg = new(HW, { "FloatingDamageNumbersUI_C" }, "FloatingDamageNumbersUI_C_1", { InitialPosition = { X = 0, Y = 0 }, Damage = 97 }, {
    SetVisibility = function(self, v) self._vis = v end, RemoveFromParent = function(self) self._removed = true end })
fire(HW, FN_VIEWPORT, "pre", param(wdg), param(0))
check(wdg._vis == 1, "host's stray damage number collapsed")
run_timers(HW)
check(wdg._removed == true, "and removed")
local wdg2 = new(HW, { "FloatingDamageNumbersUI_C" }, "FloatingDamageNumbersUI_C_2", { InitialPosition = { X = 640, Y = 300 } }, {
    SetVisibility = function(self, v) self._vis = v end })
fire(HW, FN_VIEWPORT, "pre", param(wdg2), param(0))
check(wdg2._vis == nil, "a projected number stays")
fire(HW, FN_NUMBERS, "bp", param(HW.gfl), param(97.25), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 950, Y = 0, Z = 90 }), param(hcopy))
check(sent(HW, "DMGNUM") == 1, "damage number sent to the thrower")
local dm
for _, m in ipairs(HW.outbox) do if m:find("DMGNUM", 1, true) then dm = m end end
check(dm == "SDC1|DMGNUM|97.25|1.000,1.000,1.000,1.000|950.0,0.0,90.0", "DMGNUM format: " .. tostring(dm))
HW.outbox = (function() local k = {} for _, m in ipairs(HW.outbox) do if not m:find("DMGNUM", 1, true) then k[#k + 1] = m end end return k end)()
deliver()
check(copy._p._loc.X == 900 and copy._p._loc.Y == 10, "client copy moved to the host's blast point")
check(copy._p.Capsule._p._sim == false, "copy frozen")
check(copy._events[1] == "Frag@0.0", "copy set off by Frag with ExplosionDelay 0 (" .. tostring(copy._events[1]) .. ")")
-- sdc_ffire: who threw the blast whose damage runs now
WORLD = HW
local boom = H.throw.blast_now()
check(boom and boom.pc == rpc._addr and boom.short == "BP_Throwable_Frag_C" and boom.loc.X == 900,
    "blast_now: the client's frag, its controller and point (friendly fire)")
advance(5)
WORLD = HW
check(H.throw.blast_now() == nil, "blast_now: nothing 5 s later")
client_tick()
check(#copy._events == 1, "no fallback after the host's blast")

-- ---------------------------------------------------------------- 3b. client's noise maker
print("== 3b. client throws a noise maker")
-- its firecracker is a "boom" for the copies, but it hurts nobody: no blast
-- for sdc_ffire (a host's own damage right after it is the host's own)
game_throw(CW, "BP_Throwable_NoiseMaker_C", { X = 30, Y = 0, Z = 150 }, { X = 1500, Y = 0, Z = 0 })
run_timers(CW)
deliver()
local hnm = live(HW, "BP_Throwable_NoiseMaker_C")[1]
check(hnm ~= nil and hnm._p._owner == rpawn and hnm._events[1] == "NoiseMaker@3.0",
    "host spawned the client's noise maker, its fuse started")
HW.outbox = {}
advance(3.0)
fire(HW, FN_PLAY_SOUND, "pre", param(H.ue.gameplay_statics()), param(hnm), param(nil), param({ X = 700, Y = 0, Z = 20 }))
check(sent(HW, "THRFX") == 1, "its firecracker: THRFX boom to the client")
WORLD = HW
check(H.throw.blast_now() == nil, "blast_now: the noise maker is no blast (friendly fire)")
deliver()
-- the game destroys both after their 17.5 s of noise
for _, w in ipairs({ HW, CW }) do
    for _, o in ipairs(live(w, "BP_Throwable_NoiseMaker_C")) do o._valid = false end
end
advance(2.5)

-- ---------------------------------------------------------------- 4. host's molotov
print("== 4. host throws a Molotov")
HW.outbox = {}
local hm = game_throw(HW, "BP_Throwable_Molotov_C", { X = 0, Y = 30, Z = 150 }, { X = 0, Y = 2500, Z = 400 })
check(sent(HW, "THROWN") == 1, "THROWN to the client")
check(hm._p.Capsule._p._notify == true, "host's own Molotov untouched")
deliver()
local cm = live(CW, "BP_Throwable_Molotov_C")[1]
check(cm ~= nil and cm._p.Capsule._p._notify == false, "client copy without hit events")
check(cm and cm._p.Capsule._p._vel.Y == 2500, "client copy flies with the host's velocity")
advance(1.0)
fire(HW, FN_PLAY_SOUND, "pre", param(nil), param(hm), param(nil), param({ X = 0, Y = 2000, Z = 0 }))
deliver()
check(cm and cm._events[1] == "hit" and cm._p._loc.Y == 2000 and cm._p.Capsule._p._sim == false, "copy smashed at the host's impact point")
advance(0.1)
fire(HW, FN_SPAWN_SOUND, "pre", param(nil), param(hm), param(nil), param({ X = 0, Y = 2060, Z = 0 }))
deliver()
check(cm and cm._p._loc.Y == 2060 and #cm._events == 1, "fire point applied before the copy's fire started")
-- the same with the fire coming late
local hm2 = game_throw(HW, "BP_Throwable_Molotov_C", { X = 0, Y = 30, Z = 150 }, { X = 0, Y = 2500, Z = 400 })
deliver()
fire(HW, FN_PLAY_SOUND, "pre", param(nil), param(hm2), param(nil), param({ X = 5, Y = 1000, Z = 0 }))
deliver()
advance(0.25)
fire(HW, FN_SPAWN_SOUND, "pre", param(nil), param(hm2), param(nil), param({ X = 5, Y = 1100, Z = 0 }))
deliver()
local cms = live(CW, "BP_Throwable_Molotov_C")
local cm2 = cms[#cms]
check(cm2 and cm2._p._loc.Y == 1000, "late fire point ignored (the fire already burns at the hit point)")
-- sdc_ffire: whose Molotov fire burns near a player
WORLD = HW
local hf = H.throw.fires_near({ X = 0, Y = 2300, Z = 100 }, 600)
check(#hf == 1 and hf[1].pc == nil and hf[1].who == "host", "host fires_near: the host's own fire at 2060 (thrower: the host)")
check(#H.throw.fires_near({ X = 0, Y = 3000, Z = 100 }, 600) == 0, "host fires_near: nothing 9 m away")
WORLD = CW
local cf = C.throw.fires_near({ X = 0, Y = 2100, Z = 100 }, 600)
check(#cf == 1 and cf[1].own == false and cf[1].who == "256", "client fires_near: the host's copy, its thrower's PlayerId 256")
local cf2 = C.throw.fires_near({ X = 0, Y = 1050, Z = 100 }, 600)
check(#cf2 == 1 and cf2[1].d < 200, "client fires_near: the late fire burns at the hit point")
advance(12)
WORLD = HW
check(#H.throw.fires_near({ X = 0, Y = 2300, Z = 100 }, 600) == 0, "host fires_near: the fire is out 12 s later")
WORLD = CW
check(#C.throw.fires_near({ X = 0, Y = 2100, Z = 100 }, 600) == 0, "client fires_near: the copy's fire is out too")

-- ---------------------------------------------------------------- 5. fallbacks
print("== 5. no host answer / refusal")
CW.outbox = {}
local o2 = game_throw(CW, "BP_Throwable_PipeBomb_C", { X = 0, Y = 0, Z = 150 }, { X = 1500, Y = 0, Z = 0 })
run_timers(CW)
CW.outbox = {}   -- lost (host without sdc_throw)
local pc2 = live(CW, "BP_Throwable_PipeBomb_C")[1]
advance(1.0)
client_tick()
check(pc2 and #pc2._events == 0, "waits for the host")
advance(2.5)
client_tick()
check(pc2 and pc2._events[1] ~= nil and pc2._events[1]:find("^PipeBomb@") ~= nil, "goes off here after 3 s: " .. tostring(pc2 and pc2._events[1]))
local left = pc2 and tonumber(pc2._events[1]:match("@(.+)$"))
check(left and math.abs(left - 0.0) < 1e-6, "remaining fuse 3.0 - 3.5 -> 0")
-- refusal: spawn point far from the client's character on the host
local o3 = game_throw(CW, "BP_Throwable_GlassBottle_C", { X = 5000, Y = 0, Z = 150 }, { X = 1500, Y = 0, Z = 0 })
check(o3._p.Capsule._p._notify == false, "impact original loses its hit events at once")
run_timers(CW)
deliver()
check(#live(HW, "BP_Throwable_GlassBottle_C") == 0, "host refused the far throw")
local gb = live(CW, "BP_Throwable_GlassBottle_C")[1]
check(gb and gb._events[1] == "hit", "refused bottle smashes here (visual)")
-- rate limit
advance(2.5)
WORLD = CW
for _ = 1, 4 do
    game_throw(CW, "BP_Throwable_Frag_C", { X = 30, Y = 0, Z = 150 }, { X = 1500, Y = 0, Z = 0 })
end
run_timers(CW)
local before = #live(HW, "BP_Throwable_Frag_C")
deliver()
check(#live(HW, "BP_Throwable_Frag_C") - before == 3, "3 throws per 2 s")

-- ---------------------------------------------------------------- 6. THRFX without a copy
print("== 6. effect of a throw the client never saw fly")
WORLD = CW
C.net.handlers.THRFX({ "999", "BP_Throwable_NoiseMaker_C", "boom", "10.0,20.0,30.0" }, CW.pc)
local nm = live(CW, "BP_Throwable_NoiseMaker_C")[1]
check(nm and nm._p._loc.X == 10 and nm._events[1] == "NoiseMaker@0.0", "spawned at the point and set off")
C.net.handlers.THRFX({ "998", "BP_Evil_C", "boom", "10.0,20.0,30.0" }, CW.pc)
C.net.handlers.THRFX({ "997", "../../Bad", "boom", "10.0,20.0,30.0" }, CW.pc)
check(#live(CW, "BP_Evil_C") == 0, "foreign classes refused")

-- ---------------------------------------------------------------- 7. expiry / reset / status
print("== 7. expiry, reset, status")
advance(45)
client_tick()
host_tick()
WORLD = CW
check(C.throw.status_line():find("throw:", 1, true) ~= nil, "client status: " .. C.throw.status_line())
WORLD = HW
check(H.throw.status_line():find("tracked=0", 1, true) ~= nil, "host status: " .. H.throw.status_line())
C.throw.reset("test")
H.throw.reset("test")
CS.role = "standalone"
client_tick()
local o5 = game_throw(CW, "BP_Throwable_Frag_C", { X = 0, Y = 0, Z = 150 }, { X = 1500, Y = 0, Z = 0 })
run_timers(CW)
check(o5._valid and sent(CW, "THROW") == 0, "single player untouched")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
