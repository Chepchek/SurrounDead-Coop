-- Mock harness for the three combat gaps (0.6.62 work):
--   1. sdc_stealth: a client's gunshot reaches the AI on the host (Svr_WeaponEffects
--      -> ReportNoiseEvent), SHOTN from the client's own MuzzleEffects report.
--   2. sdc_throw: launcher / bow projectiles (FinishSpawningActor -> THROW, host spawn,
--      THROWN copies, THRFX boom / stop, PRJCAP, fallback).
--   3. sdc_dmgnum: the client's firearm hit marker (Client_HitUI, Trace_Headshot).
-- Real sdc_ue / sdc_net / sdc_ctx / sdc_config / sdc_log against fake UE objects, one
-- world for the host and one for the client (as mock_throw.lua).
-- usage: lua mock_combat_gaps.lua <scripts dir>
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
    return rawget(t, "_p")[k]
end
local next_addr = 8192
local next_num = 2147300000
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
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
end
function Obj:K2_SetActorRotation(rot) self._p._rot = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll } end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:K2_DestroyActor() self._valid = false end
function Obj:SetLifeSpan(s) self._life = s end

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
local function tarray(list)
    return { ForEach = function(_, cb)
        for i, v in ipairs(list) do cb(i, { get = function() return v end }) end
    end }
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

-- ---------------------------------------------------------------- paths
local FN_FINISH = "/Script/Engine.GameplayStatics:FinishSpawningActor"
local FN_PLAY_SOUND = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local FN_NOISE = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent"
local FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:"
local FN_SHOT_FX = FIREARM .. "Svr_WeaponEffects"
local FN_DAMAGE_EVENT = FIREARM .. "SERVER_DamageEvent"
local FN_HIT_UI = FIREARM .. "Client_HitUI"
local FN_TRACE_HEAD = FIREARM .. "Trace_Headshot"
local PROJ_DIR = "/Game/Inventory/Items/Other/ItemProjectiles/"
local GRENADE_HIT = "BndEvt__BP_ProjectileGrenade_StaticMesh_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature"
local F_ATTACHMENTS = "Attachments_6_38F2C7B64C1B85D80C3C35A8B1026969"
local F_ATT_ID = "AttachmentID_21_84163C9E4A907293E46F1888C9CBB5C8"
local F_ATT_STATS = "Stats_18_68B034314BEB7EDAE0C223A03FE6E474"
local F_STAT_NAME = "STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10"
local F_STAT_MAX = "MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, refuse_hooks = {}, noises = {} }
end
local HW, CW = world("host"), world("client")

local PROJ = {
    BP_ProjectileGrenade_C = { speed = 7500 },
    BP_ProjectileRocket_C = { speed = 8000 },
    BP_ProjectileArrow_C = { speed = 10000 },
    BP_FlareRoundProjectile_C = { speed = 3000 },
}

-- a projectile as BP_ProjectileMaster makes it (StaticMesh root + ProjectileMovement)
local function make_projectile(w, cls_short, tf, owner)
    next_num = next_num + 1
    local a = new(w, { cls_short, "BP_ProjectileMaster_C", "Actor" }, cls_short .. "_" .. next_num,
        { _loc = { X = tf.Translation.X, Y = tf.Translation.Y, Z = tf.Translation.Z }, _owner = owner }, {})
    a._events = {}
    local mesh = new(w, { "StaticMeshComponent" }, "StaticMesh_" .. next_num, { _coll = 3, _ignored = {} }, {
        SetCollisionEnabled = function(self, c) self._p._coll = c end,
        GetCollisionEnabled = function(self) return self._p._coll end,
        IgnoreActorWhenMoving = function(self, o, on) self._p._ignored[#self._p._ignored + 1] = o end,
    })
    local pmc = new(w, { "ProjectileMovementComponent" }, "ProjectileMovement_" .. next_num,
        { Velocity = { X = PROJ[cls_short].speed, Y = 0, Z = 0 }, UpdatedComponent = mesh }, {
        StopMovementImmediately = function(self) self._p.Velocity = { X = 0, Y = 0, Z = 0 } end,
        Deactivate = function(self) self._off = true end,
    })
    a._p.StaticMesh, a._p.ProjectileMovement = mesh, pmc
    if cls_short == "BP_ProjectileGrenade_C" then
        a._m[GRENADE_HIT] = function(self, hc, other, oc, imp, hit)
            assert(hc == mesh, "hit component is the StaticMesh")
            assert(other ~= nil and other ~= self._p.WeaponOwner and other ~= self._p._owner, "OtherActor passes the own-weapon test")
            self._events[#self._events + 1] = "hit"
            self._valid = false   -- K2_DestroyActor at the end of the blast
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
    local gs
    gs = new(w, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf, coll, owner, scale)
            assert(type(tf) == "table" and tf.Rotation and tf.Rotation.W, "transform with a quaternion")
            assert(coll == 1, "AlwaysSpawn")
            local a = make_projectile(w, cls._name, tf, owner)
            a._wc = wc
            w.spawned[#w.spawned + 1] = a
            return a
        end,
        -- the native hook fires for every call (the game's BP or Lua)
        FinishSpawningActor = function(self, a, tf, m)
            a._finished = true
            fire(w, FN_FINISH, "post", param(self), param(a), param(a), param(tf), param(m))
            return a
        end,
    })
    w.paths["/Script/Engine.Default__GameplayStatics"] = gs
    w.gs = gs
    for short in pairs(PROJ) do
        local c = asset(w, "BlueprintGeneratedClass", PROJ_DIR .. short:sub(1, -3) .. "." .. short)
        c._name = short
    end
    w.paths["/Script/AIModule.Default__AISense_Hearing"] = new(w, { "AISense_Hearing" }, "Default__AISense_Hearing", {}, {
        ReportNoiseEvent = function(self, wco, loc, loud, inst, range, tag)
            -- a native call: its hook sees it too (sdc_stealth's footstep cap)
            local rp = param(range)
            fire(w, FN_NOISE, "pre", param(self), param(wco), param(loc), param(loud), param(inst), rp, param(tag))
            w.noises[#w.noises + 1] = { wco = wco, loc = loc, loud = loud, inst = inst, range = rp._v(), tag = tag._s }
        end,
    })
end
engine(HW, true)
engine(CW, false)

local function make_ui(w)
    return new(w, { "BP_Ingame_C" }, "BP_Ingame_C_0", {}, {
        Hitmarker = function(self, col) self._marks = self._marks or {}; self._marks[#self._marks + 1] = col end,
    })
end

-- a firearm owned by a character; projectile class short name or nil (hitscan)
local function weapon(w, cls, pawn, proj, opts)
    opts = opts or {}
    local muzzle = { X = 0, Y = 0, Z = 0 }
    local mesh = new(w, { "SkeletalMeshComponent" }, cls .. "_Mesh", {}, {
        GetSocketLocation = function(self, s) assert(s._s == "Muzzle", "Muzzle socket"); return muzzle end,
    })
    local pclass = proj and w.paths[PROJ_DIR .. proj:sub(1, -3) .. "." .. proj] or nil
    local comp = new(w, { "BP_WeaponsPickupComponent_C" }, cls .. "_Comp", {
        DefaultSoundRadius = opts.radius or 5000, ["SuppressorAttached?"] = opts.suppressor == true,
        ["MuzzleBrakeAttached?"] = opts.brake == true,
        ["DoesWeaponUseAProjectile?"] = proj ~= nil, ProjectileClass = pclass,
        MuzzleFlash = new(w, { "ParticleSystem" }, "P_MuzzleFlash"), SuppressedMuzzleFlash = new(w, { "ParticleSystem" }, "P_SuppFlash"),
    })
    local rep = {}
    rep[F_ATTACHMENTS] = tarray(opts.attachments or {})
    local jig = new(w, { "BP_JigPickupComponent_C" }, cls .. "_Jig", { RepAttachments = rep })
    local a = new(w, { cls, "BP_FirearmPickup_C", "Actor" }, cls .. "_" .. (next_num + 1),
        { _owner = pawn, _loc = { X = 0, Y = 0, Z = 0 }, BP_WeaponsPickupComponent = comp, BP_JigPickupComponent = jig,
          SkeletalMeshComponent = mesh, ShotDistance = 0 })
    a._muzzle = muzzle
    a._comp = comp
    return a
end

local function players(w)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local ps = new(w, { "PlayerState" }, "PlayerState_0", {}, {
        GetPlayerId = function() return 256 end, GetPlayerName = function() return "Me" end })
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp, PlayerState = ps }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 100 }, PlayerState = ps, InGameUI = make_ui(w) })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
players(HW)
players(CW)

-- the client's controller and character on the host
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rps = new(HW, { "PlayerState" }, "PlayerState_1", {}, {
    GetPlayerId = function() return 257 end, GetPlayerName = function() return "Friend" end })
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1",
    { _loc = { X = 0, Y = 0, Z = 100 }, PlayerState = rps })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn, PlayerState = rps }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- weapons: the client's grenade launcher and crossbow (its own and the host's copies),
-- the host's own rifle; the client's rifle (its own and the host's copy)
local c_gl = weapon(CW, "BP_GrenadeLauncherPickup_C", CW.pawn, "BP_ProjectileGrenade_C")
local c_xb = weapon(CW, "BP_CrossbowPickup_C", CW.pawn, "BP_ProjectileArrow_C")
local c_rifle = weapon(CW, "BP_AK47Pickup_C", CW.pawn, nil)
local h_gl = weapon(HW, "BP_GrenadeLauncherPickup_C", rpawn, "BP_ProjectileGrenade_C")
local h_xb = weapon(HW, "BP_CrossbowPickup_C", rpawn, "BP_ProjectileArrow_C")
local muzzle_da = new(HW, { "JigsawItem_DataAsset_C" }, "DA_Suppressor", { Local_AttachmentType = { TagName = name_obj("Jig.AttachmentType.Muzzle") } })
local sight_da = new(HW, { "JigsawItem_DataAsset_C" }, "DA_RedDot", { Local_AttachmentType = { TagName = name_obj("Jig.AttachmentType.Sight") } })
local function stat(tag, v) local s = {}; s[F_STAT_NAME] = { TagName = name_obj(tag) }; s[F_STAT_MAX] = v; return s end
local function att(da, stats) local a = {}; a[F_ATT_ID] = da; a[F_ATT_STATS] = tarray(stats); return a end
local h_rifle = weapon(HW, "BP_AK47Pickup_C", rpawn, nil, { radius = 6000, suppressor = true, attachments = {
    att(sight_da, { stat("Jig.AttachmentStat.WeaponNoise", 50) }),
    att(muzzle_da, { stat("Jig.AttachmentStat.Recoil", -10), stat("Jig.AttachmentStat.WeaponNoise", -70) }),
} })
local host_rifle = weapon(HW, "BP_M4Pickup_C", HW.pawn, nil, { radius = 7000 })
local h_flare = weapon(HW, "BP_FlareGunPickup_C", HW.pawn, "BP_FlareRoundProjectile_C")
rpawn._p.Children = tarray({ h_rifle, h_gl, h_xb })

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    return { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
             ctx = require("sdc_ctx"), throw = require("sdc_throw"), stealth = require("sdc_stealth"),
             dmgnum = require("sdc_dmgnum") }
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = {} }
H.throw.install(HS); H.stealth.install(HS); H.dmgnum.init(HS); H.dmgnum.register_handlers()
-- the client's modules last: package.loaded holds them (sdc_throw <-> sdc_dmgnum lookups)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.throw.install(CS); C.stealth.install(CS); C.dmgnum.init(CS); C.dmgnum.register_handlers()

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
local function count(w, kind)
    local n = 0
    for _, m in ipairs(w.outbox) do if m:find("SDC1|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end
local function last(w, kind)
    local found
    for _, m in ipairs(w.outbox) do if m:find("SDC1|" .. kind .. "|", 1, true) then found = m end end
    return found
end
local function host_tick() WORLD = HW; H.throw.tick(); H.stealth.tick(); H.dmgnum.try_hooks() end
local function client_tick() WORLD = CW; C.throw.tick(); C.stealth.tick(); C.dmgnum.try_hooks() end
local function live(w, short)
    local out = {}
    for _, o in ipairs(w.objects) do if o._valid and o._chain[1] == short then out[#out + 1] = o end end
    return out
end
-- BP_FirearmPickup.FireBullet @1408-1800 on the shooter's machine
local function fire_bullet(w, wpn, proj, loc, rot)
    WORLD = w
    local cls = w.paths[PROJ_DIR .. proj:sub(1, -3) .. "." .. proj]
    local tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = w.gs:BeginDeferredActorSpawnFromClass(wpn, cls, tf, 1, nil, 0)
    a._p.WeaponOwner, a._p.MinDmg, a._p.MaxDmg = wpn, 90, 130
    a._p._rot = rot or { Pitch = -5, Yaw = 90, Roll = 0 }
    w.gs:FinishSpawningActor(a, tf, 0)
    return a
end

-- ================================================================ 0. hooks
print("== 0. hooks")
host_tick(); client_tick()
advance(1.1)
host_tick(); client_tick()
check(HW.hooks[FN_FINISH] and HW.hooks[FN_FINISH][1].post ~= nil, "host: FinishSpawningActor post hook")
check(CW.hooks[FN_FINISH] and CW.hooks[FN_FINISH][1].post ~= nil, "client: FinishSpawningActor post hook")
check(HW.hooks[FN_DAMAGE_EVENT] ~= nil and CW.hooks[FN_DAMAGE_EVENT] == nil, "SERVER_DamageEvent hooked on the host only")
check(HW.hooks[FN_SHOT_FX] ~= nil and CW.hooks[FN_SHOT_FX] == nil, "Svr_WeaponEffects hooked on the host only")
check(CW.hooks[FN_TRACE_HEAD] ~= nil and HW.hooks[FN_TRACE_HEAD] == nil, "Trace_Headshot hooked on the client only")
check(CW.hooks[FN_NOISE] ~= nil, "client ReportNoiseEvent hook (own shots)")
check(count(HW, "PRJCAP") == 1 and last(HW, "PRJCAP") == "SDC1|PRJCAP|1", "host tells the client it handles projectiles")
deliver()
WORLD = CW
check(C.throw.host_drives_projectiles() == true, "client knows the host handles projectiles")

-- ================================================================ 1. gunshot noise
print("== 1. gunshot noise")
local function shot_fx(w, wpn, emitter, attach)
    fire(w, FN_SHOT_FX, "post", param(wpn), param(emitter), param(attach), param(name_obj("Muzzle")))
end
HW.noises = {}
h_rifle._muzzle.X, h_rifle._muzzle.Y, h_rifle._muzzle.Z = 10, 20, 150
local supp_mesh = new(HW, { "StaticMeshComponent" }, "SuppressorMesh")
shot_fx(HW, h_rifle, h_rifle._comp._p.SuppressedMuzzleFlash, supp_mesh)
local n1 = HW.noises[1]
check(#HW.noises == 1, "client's suppressed shot reported once")
check(n1 and n1.wco == h_rifle and n1.inst == rpawn and n1.loud == 1.0 and n1.tag == "Noise",
    "ReportNoiseEvent(weapon, ..., 1, its character, ..., 'Noise')")
check(n1 and n1.loc.X == 10 and n1.loc.Z == 150, "at the muzzle socket")
check(n1 and math.abs(n1.range - 1800) < 1e-6, "suppressed: 6000 + 6000 * -70 / 100 = 1800 (got " .. tostring(n1 and n1.range) .. ")")
shot_fx(HW, h_rifle, h_rifle._comp._p.MuzzleFlash, h_rifle._p.SkeletalMeshComponent)
check(#HW.noises == 2 and HW.noises[2].range == 6000, "flash on the weapon's mesh (suppressor broken): DefaultSoundRadius")
-- the suppressor's mesh is a client-local attachment: over the RPC it may arrive as None
shot_fx(HW, h_rifle, h_rifle._comp._p.SuppressedMuzzleFlash, nil)
check(#HW.noises == 3 and math.abs(HW.noises[3].range - 1800) < 1e-6, "no component: the suppressed flash decides (1800)")
shot_fx(HW, h_rifle, h_rifle._comp._p.MuzzleFlash, nil)
check(#HW.noises == 4 and HW.noises[4].range == 6000, "no component, plain flash: 6000")
table.remove(HW.noises); table.remove(HW.noises)
-- the host's own shot: the game reported it already
shot_fx(HW, host_rifle, host_rifle._comp._p.MuzzleFlash, host_rifle._p.SkeletalMeshComponent)
check(#HW.noises == 2, "host's own shot not reported twice")
-- the client's own game reports its value: SHOTN
WORLD = CW
c_rifle._comp._p["SuppressorAttached?"] = true
fire(CW, FN_NOISE, "pre", param(nil), param(c_rifle), param({ X = 1, Y = 2, Z = 3 }), param(1.0), param(CW.pawn), param(2100.0), param(name_obj("Noise")))
fire(CW, FN_NOISE, "pre", param(nil), param(c_rifle), param({ X = 1, Y = 2, Z = 3 }), param(1.0), param(CW.pawn), param(2100.0), param(name_obj("Noise")))
advance(0.1); client_tick()
check(count(CW, "SHOTN") == 1 and last(CW, "SHOTN") == "SDC1|SHOTN|BP_AK47Pickup_C|1|2100.0", "SHOTN once: " .. tostring(last(CW, "SHOTN")))
fire(CW, FN_NOISE, "pre", param(nil), param(CW.pawn), param({ X = 0, Y = 0, Z = 100 }), param(1.0), param(CW.pawn), param(850.0), param(name_obj("Noise")))
advance(0.1); client_tick()
check(count(CW, "SHOTN") == 1, "a footstep is not a shot")
deliver()
HW.noises = {}
shot_fx(HW, h_rifle, h_rifle._comp._p.SuppressedMuzzleFlash, supp_mesh)
check(#HW.noises == 1 and HW.noises[1].range == 2100, "owner's own value used (2100)")
shot_fx(HW, h_rifle, h_rifle._comp._p.MuzzleFlash, h_rifle._p.SkeletalMeshComponent)
check(#HW.noises == 2 and HW.noises[2].range == 6000, "other branch: computed (no report for it)")
WORLD = HW
check(H.stealth.stats.capped == 0, "the shot noise is not taken for a footstep by the cap")
H.cfg.set("shot_noise", false)
shot_fx(HW, h_rifle, h_rifle._comp._p.MuzzleFlash, h_rifle._p.SkeletalMeshComponent)
check(#HW.noises == 2, "shot_noise=false: nothing reported")
H.cfg.set("shot_noise", true)

-- ================================================================ 2. client's grenade launcher
print("== 2. client fires the grenade launcher")
CW.outbox = {}
local own = fire_bullet(CW, c_gl, "BP_ProjectileGrenade_C", { X = 40, Y = 30, Z = 150 })
check(own._p.StaticMesh._p._coll == 0, "own projectile: collision off (it cannot hit or explode here)")
check(own._valid, "own projectile keeps flying as the visual copy")
local th = last(CW, "THROW")
check(th == "SDC1|THROW|1|BP_ProjectileGrenade_C|40.0,30.0,150.0|-5.0,90.0,0.0|7500.0,0.0,0.0|90.00,130.00",
    "THROW with spawn point, rotation, velocity, damage: " .. tostring(th))
deliver()
local hg = live(HW, "BP_ProjectileGrenade_C")[1]
check(hg ~= nil, "host spawned the grenade")
check(hg and hg._p.WeaponOwner == h_gl and hg._p._owner == rpawn and hg._wc == h_gl, "WeaponOwner = host's copy of the launcher, Owner = client's character")
check(hg and hg._p.MinDmg == 90 and hg._p.MaxDmg == 130, "client's MinDmg / MaxDmg")
check(hg and hg._p.StaticMesh._p._coll == 3, "host's grenade collides")
check(hg and #hg._p.StaticMesh._p._ignored == 2, "host's grenade ignores the shooter's character and weapon")
check(hg and hg._p._loc.X == 40 and hg._p._rot == nil, "at the client's muzzle point")
WORLD = HW
check(H.ctx.player_for(hg) ~= nil, "sdc_ctx: player 0 inside it is the client")
check(#live(HW, "BP_ProjectileGrenade_C") == 1, "the host's own spawn is not taken for a host shot")
-- boom on the host: its explosion sound
HW.outbox = {}
fire(HW, FN_PLAY_SOUND, "pre", param(H.ue.gameplay_statics()), param(hg), param(nil), param({ X = 900, Y = 40, Z = 120 }))
check(last(HW, "THRFX") == "SDC1|THRFX|1|BP_ProjectileGrenade_C|boom|900.0,40.0,120.0", "THRFX boom: " .. tostring(last(HW, "THRFX")))
deliver()
check(own._events[1] == "hit" and own._p._loc.X == 900, "own copy put at the host's point and set off by its hit event")
check(own._p.ProjectileMovement._off == true, "its movement stopped")

-- ================================================================ 3. client's crossbow: hit marker from the host
print("== 3. client fires the crossbow")
CW.outbox = {}
local bolt = fire_bullet(CW, c_xb, "BP_ProjectileArrow_C", { X = 30, Y = 0, Z = 150 })
check(bolt._p.StaticMesh._p._coll == 0, "own bolt: collision off (no local pickup, no local SERVER_DamageEvent)")
deliver()
local hb = live(HW, "BP_ProjectileArrow_C")[1]
check(hb and hb._p.WeaponOwner == h_xb, "host's bolt with the host's copy of the crossbow")
-- the bolt hits a zombie's head on the host: its hit event moved it, then SERVER_DamageEvent
hb._p._loc = { X = 2000, Y = 10, Z = 160 }
hb._p._rot = { Pitch = -2, Yaw = 91, Roll = 0 }
HW.outbox = {}
fire(HW, FN_DAMAGE_EVENT, "post", param(h_xb), param(true), param(new(HW, { "BP_Zombie_C" }, "Z1")), param({ X = 2010, Y = 10, Z = 165 }))
check(last(HW, "THRFX") == "SDC1|THRFX|2|BP_ProjectileArrow_C|stop|2000.0,10.0,160.0|-2.0,91.0,0.0|head",
    "THRFX stop with the head hit: " .. tostring(last(HW, "THRFX")))
-- poll later: the bolt stopped, nothing more
hb._p.ProjectileMovement._p.UpdatedComponent = nil
advance(0.1); host_tick()
check(count(HW, "THRFX") == 1, "one stop per bolt")
-- Client_HitUI of the bolt's damage reaches the client first: no marker from it
WORLD = CW
fire(CW, FN_HIT_UI, "bp", param(c_xb), param(55.0), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 2010, Y = 10, Z = 165 }))
check(CW.pawn._p.InGameUI._marks == nil, "crossbow Client_HitUI: no marker (the host's report brings it)")
deliver()
local marks = CW.pawn._p.InGameUI._marks or {}
check(#marks == 1 and marks[1].R == 1 and marks[1].G == 0, "red hit marker for the bolt's head hit")
check(bolt._p._loc.X == 2000 and bolt._life == 2.0 and bolt._p._rot.Yaw == 91, "own bolt held at the host's point, gone 2 s later")

-- ================================================================ 4. hit marker of hitscan shots
print("== 4. hit marker (rifle)")
CW.pawn._p.InGameUI._marks = nil
WORLD = CW
fire(CW, FN_TRACE_HEAD, "bp", param(c_rifle), param({ X = 500, Y = 20, Z = 170 }), param({}), param(nil))
fire(CW, FN_HIT_UI, "bp", param(c_rifle), param(80.0), param({ R = 0.8, G = 0.6, B = 0.1, A = 1 }), param({ X = 300, Y = 0, Z = 100 }))
fire(CW, FN_HIT_UI, "bp", param(c_rifle), param(160.0), param({ R = 0.8, G = 0.6, B = 0.1, A = 1 }), param({ X = 500.004, Y = 20, Z = 170 }))
fire(CW, FN_HIT_UI, "bp", param(c_rifle), param(160.0), param({ R = 0.8, G = 0.6, B = 0.1, A = 1 }), param({ X = 500, Y = 20, Z = 170 }))
marks = CW.pawn._p.InGameUI._marks or {}
check(#marks == 3, "a marker for every hit from the server")
check(marks[1] and marks[1].G == 1, "body hit: white")
check(marks[2] and marks[2].G == 0 and marks[2].R == 1, "the own Trace_Headshot point: red")
check(marks[3] and marks[3].G == 1, "the headshot point is used up once")
fire(CW, FN_HIT_UI, "bp", param(c_rifle), param(5.0), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 0, Y = 0, Z = 0 }))
check(#(CW.pawn._p.InGameUI._marks) == 3, "object hit (impact 0,0,0): no marker, as in the game")
local other_rifle = weapon(CW, "BP_GlockPickup_C", new(CW, { "BP_PlayerCharacter_C" }, "Other"), nil)
fire(CW, FN_HIT_UI, "bp", param(other_rifle), param(5.0), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 1, Y = 1, Z = 1 }))
check(#(CW.pawn._p.InGameUI._marks) == 3, "another player's weapon: no marker")
C.cfg.set("client_hitmarker", false)
fire(CW, FN_HIT_UI, "bp", param(c_rifle), param(80.0), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 7, Y = 7, Z = 7 }))
check(#(CW.pawn._p.InGameUI._marks) == 3, "client_hitmarker=false: none")
C.cfg.set("client_hitmarker", true)
advance(6)
fire(CW, FN_TRACE_HEAD, "bp", param(c_rifle), param({ X = 9, Y = 9, Z = 9 }), param({}), param(nil))
advance(6)
fire(CW, FN_HIT_UI, "bp", param(c_rifle), param(80.0), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 9, Y = 9, Z = 9 }))
marks = CW.pawn._p.InGameUI._marks
check(marks[#marks].G == 1, "a headshot point older than 5 s no longer counts")

-- ================================================================ 5. host's flare: copy and stop
print("== 5. host fires the flare gun")
HW.outbox = {}
local hf = fire_bullet(HW, h_flare, "BP_FlareRoundProjectile_C", { X = 0, Y = 50, Z = 150 })
check(hf._p.StaticMesh._p._coll == 3, "host's own flare untouched")
check(count(HW, "THROWN") == 1, "THROWN to the client")
deliver()
local cf = live(CW, "BP_FlareRoundProjectile_C")[1]
check(cf ~= nil and cf._p.StaticMesh._p._coll == 0, "client copy of the flare, collision off")
advance(0.1); host_tick()
check(count(HW, "THRFX") == 0, "still flying: no stop")
hf._p._loc = { X = 0, Y = 3000, Z = 5 }
hf._p.ProjectileMovement._p.Velocity = { X = 0, Y = 0, Z = 0 }
advance(0.1); host_tick()
check(last(HW, "THRFX") ~= nil and last(HW, "THRFX"):find("|stop|0.0,3000.0,5.0|", 1, true) ~= nil, "flare stop sent: " .. tostring(last(HW, "THRFX")))
deliver()
check(cf._p._loc.Y == 3000 and cf._valid and cf._life == nil and cf._p.ProjectileMovement._off, "client copy lies at the host's point and keeps glowing")
check(#(CW.pawn._p.InGameUI._marks) == #marks, "someone else's projectile: no marker")

-- ================================================================ 6. no PRJCAP / refusal
print("== 6. without the host's projectile sync")
WORLD = CW
C.net.handlers.PRJCAP({ "0" }, CW.pc)
check(C.throw.host_drives_projectiles() == false, "PRJCAP 0")
CW.outbox = {}
local loc_g = fire_bullet(CW, c_gl, "BP_ProjectileGrenade_C", { X = 40, Y = 30, Z = 150 })
check(loc_g._p.StaticMesh._p._coll == 3 and count(CW, "THROW") == 0, "the game's local projectile as before")
CW.pawn._p.InGameUI._marks = nil
fire(CW, FN_HIT_UI, "bp", param(c_xb), param(55.0), param({ R = 1, G = 1, B = 1, A = 1 }), param({ X = 5, Y = 5, Z = 5 }))
check(CW.pawn._p.InGameUI._marks and #CW.pawn._p.InGameUI._marks == 1, "crossbow Client_HitUI drives the marker again")
C.net.handlers.PRJCAP({ "1" }, CW.pc)
-- refusal: no such weapon on the host's copy
rpawn._p.Children = tarray({ h_rifle })
local ref = fire_bullet(CW, c_gl, "BP_ProjectileGrenade_C", { X = 40, Y = 30, Z = 150 })
check(ref._p.StaticMesh._p._coll == 0, "collision off while waiting")
deliver()
check(ref._p.StaticMesh._p._coll == 3, "refused: collision back, it acts here as before")
WORLD = CW
check(C.throw.host_drives_projectiles() == false, "after a local fallback Client_HitUI drives the marker again")
rpawn._p.Children = tarray({ h_rifle, h_gl, h_xb })
-- no answer at all
local lost = fire_bullet(CW, c_gl, "BP_ProjectileGrenade_C", { X = 40, Y = 30, Z = 150 })
CW.outbox = {}
advance(1.0); client_tick()
check(lost._p.StaticMesh._p._coll == 0, "waits for the host")
advance(0.6); client_tick()
check(lost._p.StaticMesh._p._coll == 3, "no answer in 1.5 s: collision back")
-- rate limit on the host
WORLD = CW
CW.outbox = {}
for _ = 1, 10 do fire_bullet(CW, c_gl, "BP_ProjectileGrenade_C", { X = 40, Y = 30, Z = 150 }) end
local before = #live(HW, "BP_ProjectileGrenade_C")
advance(3)
HW.outbox = {}
deliver()
check(#live(HW, "BP_ProjectileGrenade_C") - before == 8, "8 projectiles per 2 s")

-- ================================================================ 7. THRFX of an unseen projectile, bad input
print("== 7. edge cases")
WORLD = CW
C.net.handlers.THRFX({ "777", "BP_ProjectileRocket_C", "stop", "1.0,2.0,3.0", "0,0,0", "head" }, CW.pc)
local rk = live(CW, "BP_ProjectileRocket_C")
check(#rk == 1 and rk[1]._p._loc.X == 1 and rk[1]._p.StaticMesh._p._coll == 0, "stop of an unseen projectile: a held copy there")
local marks_n = #(CW.pawn._p.InGameUI._marks or {})
check(marks_n == 1, "and no marker (not the own shot)")
C.net.handlers.THRFX({ "778", "BP_ProjectileRocket_C", "fire", "1.0,2.0,3.0" }, CW.pc)
C.net.handlers.THROWN({ "779", "BP_ProjectileRocket_C", "1,2,3", "0,0,0", "99999999,0,0", "256" }, CW.pc)
check(#live(CW, "BP_ProjectileRocket_C") == 1, "bad phase / speed refused")
WORLD = HW
advance(3)   -- past the rate window of section 6
H.net.handlers.THROW({ "900", "BP_ProjectileGrenade_C", "0,0,100", "0,0,0", "100,0,0", "-5,1" }, rpc)
check(last(HW, "THRACK"):find("bad damage", 1, true) ~= nil, "negative damage refused")
H.net.handlers.SHOTN({ "../x", "1", "100" }, rpc)
H.net.handlers.SHOTN({ "BP_X_C", "2", "100" }, rpc)
H.net.handlers.SHOTN({ "BP_X_C", "1", "nan" }, rpc)
check(H.stealth.stats.shot_reports == 1, "bad SHOTN ignored")
local okh = pcall(function()
    fire(HW, FN_SHOT_FX, "post", param(nil), param(nil), param(nil), param(nil))
    fire(HW, FN_DAMAGE_EVENT, "post", param(nil), param(nil), param(nil), param(nil))
    fire(HW, FN_FINISH, "post", param(nil), param(nil), param(nil), param(nil), param(nil))
    fire(CW, FN_HIT_UI, "bp", param(nil), param(nil), param(nil), param(nil))
    fire(CW, FN_TRACE_HEAD, "bp", param(nil), param(nil), param(nil), param(nil))
end)
check(okh, "hooks survive nil parameters")
WORLD = HW
check(H.throw.status_line():find("projectiles", 1, true) ~= nil, "host status: " .. H.throw.status_line())
check(H.stealth.status_line():find("shots", 1, true) ~= nil, "stealth status has the shots")
WORLD = CW
check(C.throw.status_line():find("hit markers=1", 1, true) ~= nil, "client status: " .. C.throw.status_line())
local rep
C.dmgnum.report(function(s) rep = s end)
check(rep and rep:find("hit markers", 1, true) ~= nil, "dmgnum report: " .. tostring(rep))

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
