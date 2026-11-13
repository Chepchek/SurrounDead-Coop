-- SDCoop: thrown items in co-op - frag grenade, pipe bomb, noise maker,
-- Molotov cocktail, glass bottle (work\audit\throwables.md).
--
-- How the game throws (BP_PlayerCharacter; the input runs only on the
-- thrower's own machine):
--   IA_Throwable has no trigger, so it fires every frame while the key is
--   held. @53799: return if a montage plays, the inventory is open, swimming,
--   in a vehicle, fishing, photo mode, or hotbar slot 4 is empty. Otherwise
--   Svr_Montage(Chr_Throw_Montage) (server RPC -> MC_Montage plays it), the
--   capsule turns to the camera yaw (K2_SetWorldRotation), Delay 0.8 and
--   BP_JigMultiplayer.SERVER_RequestConsumeItem(Throwable slot UID, 1).
--   @14507 after the delay: BeginDeferredActorSpawnFromClass(the item's
--   ThrowableClass, Hand_R socket, actor rotation, Owner None),
--   FinishSpawningActor, Event_Throw broadcast,
--   Capsule.SetPhysicsLinearVelocity(camera forward * GrenadeThrowSpeed
--   1500..3000).
-- BP_Throwable_* actors do not replicate and do everything where they were
-- spawned:
--   Frag / PipeBomb: Event_Throw -> Frag/PipeBomb -> Delay(ExplosionDelay 3)
--     -> emitter, explosion_large_06 sound, decal, SphereOverlapActors
--     400/300 cm: Damage_Object, ApplyDamage on AI (causer = player 0),
--     damage numbers, radial impulse; ReportNoiseEvent 7500 cm; destroy.
--   NoiseMaker: Event_Throw -> NoiseMaker -> Delay(3) -> firecracker FX and
--     sound, 'LoudNoise' every 2 s for 17.5 s.
--   Molotov: first capsule hit -> glass smash sound, 0.2 s -> fire FX and
--     MolotovFire sound, decal, noise; Fire_Damage every 0.8 s for 10 s:
--     SphereOverlapActors 500 cm -> Damage_Object, SetBurning (players, AI).
--   GlassBottle: first hit -> smash FX + sound, noise 6000 cm.
-- In co-op:
--   * a client's throw existed on the client only: its damage is refused
--     there (no authority over pawns), its noise reaches no AI (none there),
--     the host saw nothing;
--   * the host's throw existed on the host only: clients saw nothing, but
--     its damage and the Molotov's burning reached them;
--   * the client's montage gate stays open for a round trip (MC_Montage
--     comes back from the server), so a held key sent several consume
--     requests per throw (0.6.25 log: one grenade thrown, 3 requests,
--     2 grenades gone).
-- Here:
--   client: its own throw goes to the host (THROW: class, spawn point,
--     rotation, velocity); the game's local projectile is swapped for a
--     visual copy that does nothing by itself (impact classes: no hit
--     events; fuse classes: no Event_Throw);
--   host: spawns the same class at that point with that velocity and
--     Owner = the thrower's character; sdc_ctx then answers "player 0" with
--     that player inside it (damage causer, kill credit, noise instigator,
--     Demolition Expert skill). The host's own throws are tracked too. Each
--     tracked throw is announced to the clients that did not throw it
--     (THROWN); when it goes off - its first sound: explosion, firecracker,
--     glass smash; the Molotov's fire sound - the host sends where (THRFX);
--   client: THROWN spawns a visual copy; THRFX moves the copy to the host's
--     point and sets it off with the game's own event (fuse: ExplosionDelay
--     0 + Frag / PipeBomb / NoiseMaker; impact: its capsule hit event). FX,
--     sound, decal, fire and burning visuals are the game's own; their damage
--     and noise do nothing on a client. No answer from the host (no sdc_throw
--     there) or a refusal: the own copy goes off by itself, as before;
--   client: the throw montage starts locally the moment the throw begins
--     (as in single player), so the gate closes at once and one throw sends
--     one consume request; the server's MC_Montage continues it from the
--     same position;
--   host: a client's grenade asks for damage numbers through that player's
--     controller: they go to that player (DMGNUM, sdc_dmgnum shows them) and
--     the host's stray copy at the screen corner is hidden.
-- Config: throw_sync, throw_single_consume.
--
-- Launcher and bow projectiles (grenade launcher, rocket launcher, flare gun,
-- crossbow), work\re\pseudo\BP_FirearmPickup.txt, BP_Projectile*.txt:
--   BP_FirearmPickup.FireBullet (the shooter's machine only), when
--   BP_WeaponsPickupComponent.DoesWeaponUseAProjectile?: @1408
--   ProjectileTraceFromCamera (muzzle socket, looking at the camera's aim
--   point), BeginDeferredActorSpawnFromClass(self, ProjectileClass, that
--   transform, AlwaysSpawn, Owner None), WeaponOwner = self, MinDmg / MaxDmg =
--   FindStat(FirearmDamage) (the owner's inventory widget), @1800
--   FinishSpawningActor. ProjectileMovement flies it (InitialSpeed along its
--   rotation, class gravity); the actor does not replicate. On its first
--   StaticMesh hit:
--     BP_ProjectileGrenade / BP_ProjectileRocket: explosion emitter,
--       explosion_large_06 sound, decal, CalculateDmg (Min..Max, Demolition
--       Expert of player 0), ReportNoiseEvent 7500 cm (instigator player 0),
--       SphereOverlapActors 600 / 1200 cm: Damage_Object, ApplyDamage on AI
--       (causer player 0), SpawnDamageNumbers; radial impulse; destroy.
--     BP_ProjectileArrow (crossbow bolt): flesh -> WeaponOwner.SERVER_DamageEvent
--       (body / head), other -> WeaponOwner.Trace_Impact; a BP_BoltAmmoPickup
--       at the bolt (the bolt to pick up again); the bolt goes 2 s later.
--     BP_FlareRoundProjectile: an AI it hits burns (SetBurning, causer player
--       0); the flare (a 40 m point light) lies where it stopped, for good.
--   A client's projectile therefore did nothing that counts (pawns refuse its
--   damage, no AI hears it, the bolt pickup existed on the client only), and
--   nobody else saw any projectile.
-- Here, the same way as the throws above (same messages):
--   client: FinishSpawningActor (post) of the own weapon's projectile: THROW
--     with its spawn point, rotation and MinDmg / MaxDmg; the game's
--     projectile flies on as the own visual copy with its collision off (it
--     cannot hit anything here). Only after the host said it handles them
--     (PRJCAP); otherwise, or when the host refuses / does not answer, it stays
--     the game's local projectile as before.
--   host: spawns the same class the game's way with WeaponOwner = its copy of
--     the client's weapon, Owner = the client's character (sdc_ctx: "player 0"
--     inside it is that player: kill credit, XP, Demolition Expert, noise and
--     burn instigator) and the client's MinDmg / MaxDmg; it ignores the
--     shooter's character and weapon while it moves (the host's copy of a
--     moving shooter lags behind the muzzle point). The bolt's
--     SERVER_DamageEvent runs on the host (damage numbers reach the client
--     natively through Client_HitUI); its BP_BoltAmmoPickup is spawned by the
--     host (a replicated item, sdc_items). The host's own projectiles are
--     tracked too. Announced as THROWN; THRFX when it goes off: boom (its
--     explosion sound) or stop (bolt / flare stopped: point, rotation, and
--     body / head when the bolt's SERVER_DamageEvent ran).
--   client: THROWN -> a copy (collision off) flies the same way; THRFX boom ->
--     the copy is put at the host's point and set off by its own hit event
--     (the game's explosion here; its damage does nothing on a client);
--     THRFX stop -> the copy stops at the host's point and rotation (a bolt
--     goes 2 s later, as in the game), and the shooter gets its hit marker
--     (sdc_dmgnum) for a bolt that hit flesh.
-- Config: launcher_sync.
-- sdc_ffire (friendly fire) asks who threw a blast that just went off and
-- whose Molotov fire burns near a player (M.blast_now, M.fires_near).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local appearance = require("sdc_appearance")   -- player_id
local consume = require("sdc_consume")         -- shared helpers (param)

local M = {
    stats = {
        own = 0, sent = 0, acked = 0, refused = 0, fallback = 0, swaps = 0, swap_failed = 0,
        host_spawned = 0, host_refused = 0, host_own = 0, announced = 0, fx_sent = 0,
        dmgnum = 0, numbers_hidden = 0,
        copies = 0, copy_failed = 0, set_off = 0, set_off_failed = 0, fire_moved = 0,
        montage = 0, aligned = 0,
        -- projectiles: client own / kept local; host spawned for clients /
        -- refused / own announced; stops sent; copies stopped / set off
        proj_own = 0, proj_local = 0, proj_host = 0, proj_refused = 0, proj_host_own = 0,
        proj_stops = 0, proj_stopped = 0, proj_boom = 0, proj_markers = 0,
    },
}

local S = nil
local addr = ctx.addr
local clock = os.clock

local THROW_DIR = "/Game/Blueprints/Throwables/"
local PREFIX = "BP_Throwable_"
-- fuse: set off by the event bound to Event_Throw; impact: by the capsule hit.
-- harmless: its "boom" (the firecracker) hurts nobody - not a blast for
-- sdc_ffire (M.blast_now). No flare or smoke throwable exists (the flare gun's
-- round is a "stick" projectile below, silent).
local KNOWN = {
    BP_Throwable_Frag_C        = { kind = "fuse", event = "Frag" },
    BP_Throwable_PipeBomb_C    = { kind = "fuse", event = "PipeBomb" },
    BP_Throwable_NoiseMaker_C  = { kind = "fuse", event = "NoiseMaker", harmless = true },
    BP_Throwable_Molotov_C     = { kind = "impact" },
    BP_Throwable_GlassBottle_C = { kind = "impact" },
}
-- the capsule hit event of BP_Throwable_Molotov and BP_Throwable_GlassBottle
-- (the bottle was made from the Molotov: same name)
local HIT_EVENT = "BndEvt__BP_Throwable_Molotov_Capsule_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature"
local THROW_MONTAGE = "/Game/Character/Anims/Interaction/Chr_Throw_Montage.Chr_Throw_Montage"
local NUMBERS_CLASS = "FloatingDamageNumbersUI_C"

local FN_VELOCITY = "/Script/Engine.PrimitiveComponent:SetPhysicsLinearVelocity"
local FN_ROTATE = "/Script/Engine.SceneComponent:K2_SetWorldRotation"
local FN_PROXY = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"
local FN_PLAY_SOUND = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local FN_SPAWN_SOUND = "/Script/Engine.GameplayStatics:SpawnSoundAtLocation"
local FN_VIEWPORT = "/Script/UMG.UserWidget:AddToViewport"
local FN_NUMBERS = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:SpawnDamageNumbers"

local MAX_SPAWN_DIST = 800   -- cm: reported spawn point -> host's copy of the thrower
local MAX_SPEED = 5000       -- cm/s (GrenadeThrowSpeed gives 1500..3000)
local RATE_N, RATE_S = 3, 2  -- throws per player and window (the montage alone takes 2.2 s)
local NO_ACK_S = 3           -- s without THRACK: no sdc_throw on the host -> the copy goes off here
local LIFE_S = 40            -- s a throw is remembered (Molotov ~11 s, noise maker ~21 s)
local SEEN_S = 60            -- s a handled projectile name is remembered
local FIRE_WINDOW = 0.17     -- s after the copy's hit in which the Molotov fire (0.2 s later) can still move
local BLAST_S = 0.5          -- s after a client's blast on the host in which stray numbers are hidden
local ALIGN_S = 3            -- s a local throw montage waits for the server's MC_Montage
local MONTAGE_LEN = 2.18     -- s, Chr_Throw_Montage (fallback when GetPlayLength fails)
local SEQ_KEEP = 64          -- host: client sequence numbers remembered per player
-- sdc_ffire (friendly fire): who threw a blast / a Molotov fire
local MOLOTOV = "BP_Throwable_Molotov_C"
local BOOM_MATCH_S = 0.25    -- a blast's damage loop runs right after its sound (one Blueprint call)
local FIRE_LIFE_S = 11       -- the Molotov's fire: 0.2 s after its hit, then 10 s (@837)

-- Launcher / bow projectiles (BP_ProjectileMaster children). blast: goes off
-- on its first hit (its hit event); stick: stops where it hits.
local PROJ_DIR = "/Game/Inventory/Items/Other/ItemProjectiles/"
local PROJ = {
    BP_ProjectileGrenade_C = { kind = "blast",
        hit = "BndEvt__BP_ProjectileGrenade_StaticMesh_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature" },
    BP_ProjectileRocket_C = { kind = "blast",
        hit = "BndEvt__BP_ProjectileRocket_StaticMesh_K2Node_ComponentBoundEvent_0_ComponentHitSignature__DelegateSignature" },
    BP_ProjectileArrow_C = { kind = "stick", life = 2.0 },   -- the bolt goes 2 s after its hit (@1566)
    BP_FlareRoundProjectile_C = { kind = "stick" },          -- the flare stays
}
local FN_FINISH = "/Script/Engine.GameplayStatics:FinishSpawningActor"
local FN_DAMAGE_EVENT = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:SERVER_DamageEvent"
local COLL_NONE = 0             -- ECollisionEnabled::NoCollision
local COLL_DEFAULT = 3          -- QueryAndPhysics, if the original could not be read
local PROJ_RATE_N, PROJ_RATE_S = 8, 2   -- projectiles per player and window
local PROJ_NO_ACK_S = 1.5       -- s without THRACK: the own projectile is the game's local one again
local PROJ_MAX_SPEED = 20000    -- cm/s (InitialSpeed 3000..10000)
local PROJ_MAX_DMG = 100000
local STOP_MATCH_CM = 300       -- bolt -> SERVER_DamageEvent impact point
local CAP_RESEND_S = 60         -- host: PRJCAP again this often

local st = {
    hooks = {},                 -- [key] = true once registered (or failed: never retried)
    numbers_hooked = false, numbers_next = 0,
    seen = {},                  -- [projectile name] = clock(): handled by the velocity hook
    tracked = {},               -- host: [actor address] = entry
    next_g = 0,
    rate = {},                  -- host: [pc address] = { t, n }
    seqs = {},                  -- host: [pc address] = { [seq] = clock() }
    copies = {},                -- client: [key] = entry; "c<seq>" own throw, "h<id>" host id (alias)
    seq = 0,
    spawning = false,
    blast_until = 0,
    own_at = -100, my_pawn = nil, my_capsule = nil, my_mesh = nil,
    montage_at = nil, align_pending = false, montage_addr = nil,
    host_at = -100,
    logged = {},
    -- projectiles
    sticks = {},                -- host: [actor address] = entry of a flying bolt / flare
    prate = {},                 -- host: [pc address] = { t, n }
    cap_sent = {},              -- host: [pc address] = "<pawn address><0/1>" last PRJCAP
    cap_at = {},                -- host: [pc address] = clock() of that PRJCAP
    host_proj = false,          -- client: the host handles projectiles (PRJCAP 1)
    damage_hooked = false, damage_next = 0,
    hooks_at = -100,            -- clock() of the last install_hooks pass
    last_boom = nil,            -- host: { pc, who, short, loc, t } of the last tracked blast (sdc_ffire)
}

local function coop() return S ~= nil and (S.role == "host" or S.role == "client") end
local function sync_on() return cfg.get("throw_sync") ~= false end
local function gate_on() return cfg.get("throw_single_consume") ~= false end
local function proj_on() return cfg.get("launcher_sync") ~= false end

local function once(key, fmt, ...)
    if st.logged[key] then return end
    st.logged[key] = true
    log.info(fmt, ...)
end

-- the first `limit` lines of a kind as info, the rest as debug
local function counted(n, limit, fmt, ...)
    if n <= limit then log.info(fmt, ...) else log.debug(fmt, ...) end
end

local function num(v)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local get = consume.param

local function vec(v)
    if v == nil then return nil end
    local x = num(ue.try(function() return v.X end))
    local y = num(ue.try(function() return v.Y end))
    local z = num(ue.try(function() return v.Z end))
    if not (x and y and z) then return nil end
    return { X = x, Y = y, Z = z }
end

local function rot_of(actor)
    local r = ue.try(function() return actor:K2_GetActorRotation() end)
    if r == nil then return { Pitch = 0, Yaw = 0, Roll = 0 } end
    return { Pitch = num(ue.try(function() return r.Pitch end)) or 0,
             Yaw = num(ue.try(function() return r.Yaw end)) or 0,
             Roll = num(ue.try(function() return r.Roll end)) or 0 }
end

local function f3(v) return string.format("%.1f,%.1f,%.1f", v.X, v.Y, v.Z) end
local function r3(r) return string.format("%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll) end

local function p3(s)
    local a, b, c = tostring(s or ""):match("^(%-?[%d.]+),(%-?[%d.]+),(%-?[%d.]+)$")
    a, b, c = num(a), num(b), num(c)
    if not (a and b and c) then return nil end
    return a, b, c
end

local function parse_vec(s)
    local x, y, z = p3(s)
    if not x then return nil end
    return { X = x, Y = y, Z = z }
end

local function parse_rot(s)
    local p, y, r = p3(s)
    if not p then return nil end
    return { Pitch = p, Yaw = y, Roll = r }
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function len(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end

-- FRotator -> FQuat, the engine's formula (FRotator::Quaternion)
local function quat(r)
    local h = math.pi / 360
    local sp, cp = math.sin(r.Pitch * h), math.cos(r.Pitch * h)
    local sy, cy = math.sin(r.Yaw * h), math.cos(r.Yaw * h)
    local sr, cr = math.sin(r.Roll * h), math.cos(r.Roll * h)
    return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
             Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end

local function pc_by_addr(a)
    if not a or not S then return nil end
    for _, pc in ipairs(S.remote_pcs or {}) do
        if addr(pc) == a then return pc end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Classes, spawning, the game's own triggers
-- ---------------------------------------------------------------------------

local infos = {}
local function class_info(short)
    if type(short) ~= "string" then return nil end
    local p = PROJ[short]
    if p then
        local pi = infos[short]
        if not pi then
            pi = { short = short, path = PROJ_DIR .. short:sub(1, -3) .. "." .. short, kind = p.kind, hit = p.hit,
                   life = p.life, proj = true }
            infos[short] = pi
        end
        return pi
    end
    if not short:match("^BP_Throwable_[%w_]+_C$") then return nil end
    local i = infos[short]
    if i then return i end
    local base = short:sub(1, -3)
    local path = THROW_DIR .. base .. "." .. short
    local k = KNOWN[short]
    if k then
        i = { short = short, path = path, kind = k.kind, event = k.event, harmless = k.harmless }
    else
        -- a throwable added later: a function named after it means a fuse
        local ev = base:sub(#PREFIX + 1)
        if not ue.find_object(path) then
            return { short = short, path = path, kind = "impact" }   -- not cached: not loaded yet
        end
        if ue.find_object(path .. ":" .. ev) then
            i = { short = short, path = path, kind = "fuse", event = ev }
        else
            i = { short = short, path = path, kind = "impact" }
        end
    end
    infos[short] = i
    return i
end

-- The class of a throwable / projectile. Host: loaded if needed (a client's
-- throw spawns there); client: only one already in memory - its copies come
-- from messages (THROWN / THRFX), and a synchronous load there can wait for
-- the world's streaming. A projectile's class comes with its weapon (a hard
-- reference), a throwable's with its item.
local function load_class(info)
    if S and S.role == "client" then return ue.loaded_asset(info.path, "throw") end
    local c = ue.find_object(info.path)
    if c then return c end
    local ok, l = ue.load_asset(info.path, "throw")
    if ok and ue.valid(l) then return l end
    return nil
end

-- A live projectile by its path, if it still is one of that class.
local function find_actor(path, short)
    if not path then return nil end
    local a = ue.find_object(path)
    if not a or ue.class_name(a) ~= short then return nil end
    return a
end

-- The game's spawn: BeginDeferredActorSpawnFromClass (AlwaysSpawn) ->
-- FinishSpawningActor -> Capsule.SetPhysicsLinearVelocity.
-- opt.owner: the thrower's character (host); opt.quiet: a visual copy of an
-- impact class gets no hit events; opt.ang: angular velocity (deg/s).
local function spawn(info, loc, rot, vel, opt)
    opt = opt or {}
    local cls = load_class(info)
    local gs = ue.gameplay_statics()
    local wc = (opt.owner and ue.valid(opt.owner)) and opt.owner or ue.world_context()
    if not cls then return nil, "class " .. info.short .. " not loaded" end
    if not gs or not wc then return nil, "no GameplayStatics / world" end
    local tf = { Rotation = quat(rot), Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local actor, why = nil, nil
    st.spawning = true
    local ok, err = pcall(function()
        local a = gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, 1, opt.owner, 0)
        if not ue.valid(a) then why = "BeginDeferredActorSpawnFromClass gave None"; return end
        local done = gs:FinishSpawningActor(a, tf, 0)
        actor = ue.valid(done) and done or a
        local cap = ue.prop(actor, "Capsule")
        if not ue.valid(cap) then why = "no Capsule"; return end
        if opt.quiet and info.kind == "impact" then cap:SetNotifyRigidBodyCollision(false) end
        cap:SetPhysicsLinearVelocity(vel, false, FName("None"))
        if opt.ang then cap:SetPhysicsAngularVelocityInDegrees(opt.ang, false, FName("None")) end
    end)
    st.spawning = false
    if ue.valid(actor) then st.seen[ue.short(actor)] = clock() end
    if not ok then
        if ue.valid(actor) then pcall(function() actor:K2_DestroyActor() end) end
        return nil, tostring(err)
    end
    if not ue.valid(actor) then return nil, why or "no actor" end
    if why then
        pcall(function() actor:K2_DestroyActor() end)
        return nil, why
    end
    return actor
end

local function freeze_at(actor, loc)
    local cap = ue.prop(actor, "Capsule")
    if ue.valid(cap) then pcall(function() cap:SetSimulatePhysics(false) end) end
    if loc then ue.teleport(actor, loc) end
end

-- ---------------------------------------------------------------------------
-- Projectiles: spawning, holding, setting off (the game's own code)
-- ---------------------------------------------------------------------------

local function proj_mesh(actor)
    local m = ue.prop(actor, "StaticMesh")   -- the root: ProjectileMovement sweeps it
    if ue.valid(m) then return m end
    return nil
end

-- FireBullet's spawn @1431-1800: BeginDeferredActorSpawnFromClass(AlwaysSpawn),
-- WeaponOwner / MinDmg / MaxDmg, FinishSpawningActor; ProjectileMovement
-- starts it along the rotation.
-- opt.owner: the shooter's character (host); opt.weapon: WeaponOwner (and the
-- world context, as FireBullet's self); opt.dmg = { min, max };
-- opt.quiet: a visual copy, collision off (no hit, no hit event);
-- opt.ignore: actors its movement ignores.
local function spawn_proj(info, loc, rot, opt)
    opt = opt or {}
    local cls = load_class(info)
    local gs = ue.gameplay_statics()
    local wc = (opt.weapon and ue.valid(opt.weapon)) and opt.weapon or ue.world_context()
    if not cls then return nil, "class " .. info.short .. " not loaded" end
    if not gs or not wc then return nil, "no GameplayStatics / world" end
    local tf = { Rotation = quat(rot), Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local actor, why = nil, nil
    st.spawning = true
    local ok, err = pcall(function()
        local a = gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, 1, opt.owner, 0)
        if not ue.valid(a) then why = "BeginDeferredActorSpawnFromClass gave None"; return end
        if opt.weapon then ue.set_prop(a, "WeaponOwner", opt.weapon) end
        if opt.dmg then
            ue.set_prop(a, "MinDmg", opt.dmg[1])
            ue.set_prop(a, "MaxDmg", opt.dmg[2])
        end
        local done = gs:FinishSpawningActor(a, tf, 0)
        actor = ue.valid(done) and done or a
        local mesh = proj_mesh(actor)
        if not mesh then why = "no StaticMesh"; return end
        if opt.quiet then mesh:SetCollisionEnabled(COLL_NONE) end
        for _, o in ipairs(opt.ignore or {}) do
            if ue.valid(o) then mesh:IgnoreActorWhenMoving(o, true) end
        end
    end)
    st.spawning = false
    if ue.valid(actor) then st.seen[ue.short(actor)] = clock() end
    if not ok then
        if ue.valid(actor) then pcall(function() actor:K2_DestroyActor() end) end
        return nil, tostring(err)
    end
    if not ue.valid(actor) then return nil, why or "no actor" end
    if why then
        pcall(function() actor:K2_DestroyActor() end)
        return nil, why
    end
    return actor
end

-- Stops a copy where the host's projectile is: its movement off, the host's
-- rotation and point.
local function hold_at(actor, loc, rot)
    local pmc = ue.prop(actor, "ProjectileMovement")
    if ue.valid(pmc) then
        pcall(function() pmc:StopMovementImmediately() end)
        pcall(function() pmc:Deactivate() end)
    end
    if rot then pcall(function() actor:K2_SetActorRotation(rot, true) end) end
    if loc then ue.teleport(actor, loc) end
end

-- Sets a blast copy off with its own StaticMesh hit event. OtherActor is the
-- copy itself: never its WeaponOwner or Owner, so the handler's own-weapon
-- test (Grenade / Rocket @1454) lets it go off.
local function proj_set_off(actor, info)
    local ev = info.hit
    if not ev then return false, "no hit event for " .. info.short end
    local mesh = proj_mesh(actor)
    return pcall(function() actor[ev](actor, mesh, actor, nil, nil, nil) end)
end

-- true when the projectile's movement has stopped (StopSimulating clears
-- UpdatedComponent and the velocity).
local function proj_stopped(actor)
    local pmc = ue.prop(actor, "ProjectileMovement")
    if not ue.valid(pmc) then return true end
    if not ue.valid(ue.prop(pmc, "UpdatedComponent")) then return true end
    local v = vec(ue.prop(pmc, "Velocity"))
    return v ~= nil and len(v) < 1
end

-- The capsule hit event of an impact class: the known name, or (a class added
-- later) the class's own *ComponentHitSignature__DelegateSignature function.
local function hit_event(info)
    if info.hit then return info.hit end
    if ue.find_object(info.path .. ":" .. HIT_EVENT) then
        info.hit = HIT_EVENT
        return HIT_EVENT
    end
    local cls = ue.find_object(info.path)
    local found = nil
    if cls then
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = ue.short(fn)
                if not found and n:find("ComponentHitSignature__DelegateSignature", 1, true) then found = n end
            end)
        end)
    end
    info.hit = found or HIT_EVENT
    return info.hit
end

-- Sets a copy off with the game's own code: fuse -> ExplosionDelay 0 and the
-- event bound to Event_Throw; impact -> the capsule hit event.
local function set_off(actor, info)
    if info.kind == "fuse" then
        ue.set_prop(actor, "ExplosionDelay", 0.0)
        return pcall(function() actor[info.event](actor) end)
    end
    local cap = ue.prop(actor, "Capsule")
    if not ue.valid(cap) then cap = nil end
    local ev = hit_event(info)
    return pcall(function() actor[ev](actor, cap, nil, nil, nil, nil) end)
end

-- ---------------------------------------------------------------------------
-- Client: own throws and visual copies
-- ---------------------------------------------------------------------------

-- No answer / a refusal from the host: the own copy goes off here as the
-- game's own projectile would have (visual only, as before this module).
local function fallback(e, why)
    if e.done or e.kept then return end
    e.done = true
    local copy = find_actor(e.path, e.info.short)
    M.stats.fallback = M.stats.fallback + 1
    if e.info.proj then
        -- the game's own projectile is the copy: its collision back, it acts
        -- here as it did before this module (visual only)
        e.kept = true
        st.last_proj_kept = true   -- its bolt's hit marker comes with Client_HitUI again
        local mesh = copy and proj_mesh(copy)
        local ok = mesh ~= nil and pcall(function() mesh:SetCollisionEnabled(e.coll or COLL_DEFAULT) end)
        M.stats.proj_local = M.stats.proj_local + 1
        log.warn("throw: own %s #%d: %s; it stays the game's local projectile (%s)", e.info.short, e.seq or -1, why,
            ok and "collision back" or "already gone")
        return
    end
    if not copy then
        log.warn("throw: own %s #%d: %s; its copy is gone", e.info.short, e.seq or -1, why)
        return
    end
    local ok, err
    if e.info.kind == "fuse" then
        local delay = num(ue.prop(copy, "ExplosionDelay")) or 3
        local left = math.max(0, delay - (clock() - e.t0))
        ue.set_prop(copy, "ExplosionDelay", left)
        ok, err = pcall(function() copy[e.info.event](copy) end)
    else
        ok, err = set_off(copy, e.info)
    end
    e.hit_at = clock()
    log.warn("throw: own %s #%d: %s; it goes off here only (visual): %s", e.info.short, e.seq or -1, why,
        ok and "ok" or tostring(err))
end

-- Next frame after the throw: the game's projectile is replaced by a copy in
-- the same place with the same motion; the original (its fuse already
-- running) is destroyed.
local function swap_original(e, loc0, rot0, vel0)
    local orig = find_actor(e.orig, e.info.short)
    if e.done then
        -- the host's blast came first and showed its own copy
        if orig then pcall(function() orig:K2_DestroyActor() end) end
        return
    end
    local loc, rot, vel, ang = loc0, rot0, vel0, nil
    if orig then
        loc = ue.location(orig) or loc0
        rot = rot_of(orig)
        local cap = ue.prop(orig, "Capsule")
        if ue.valid(cap) then
            vel = vec(ue.try(function() return cap:GetPhysicsLinearVelocity(FName("None")) end)) or vel0
            ang = vec(ue.try(function() return cap:GetPhysicsAngularVelocityInDegrees(FName("None")) end))
        end
    end
    local copy, why = spawn(e.info, loc, rot, vel, { quiet = true, ang = ang })
    if not copy then
        e.kept = true
        M.stats.swap_failed = M.stats.swap_failed + 1
        if orig and e.info.kind == "impact" then
            local cap = ue.prop(orig, "Capsule")
            if ue.valid(cap) then pcall(function() cap:SetNotifyRigidBodyCollision(true) end) end
        end
        log.warn("throw: own %s #%d: no visual copy (%s); the game's own projectile stays here (it goes off here too)",
            e.info.short, e.seq, tostring(why))
        return
    end
    e.path = ue.path(copy)
    if orig then pcall(function() orig:K2_DestroyActor() end) end
    M.stats.swaps = M.stats.swaps + 1
    counted(M.stats.swaps, 5, "throw: own %s #%d replaced by a visual copy %s (the host's one does the damage)",
        e.info.short, e.seq, ue.short(copy))
end

-- SetPhysicsLinearVelocity on a new projectile of the own player's throw.
local function client_own_throw(actor, comp, info, loc, rot, vel)
    st.seq = st.seq + 1
    local seq = st.seq
    -- an impact class must not burst here before the swap
    if info.kind == "impact" then pcall(function() comp:SetNotifyRigidBodyCollision(false) end) end
    local e = { key = "c" .. seq, seq = seq, info = info, t0 = clock(), own = true, orig = ue.path(actor) }
    st.copies[e.key] = e
    M.stats.own = M.stats.own + 1
    local sent = net.send_to_host("THROW", tostring(seq), info.short, f3(loc), r3(rot), f3(vel))
    if sent then M.stats.sent = M.stats.sent + 1 end
    counted(M.stats.own, 10, "throw: own %s #%d at %.0f,%.0f,%.0f, %.0f cm/s: %s", info.short, seq, loc.X, loc.Y, loc.Z,
        len(vel), sent and "sent to the host" or "NOT sent (no connection)")
    ue.delay("throw-swap", 1, function() swap_original(e, loc, rot, vel) end)
end

-- FinishSpawningActor (post) of the own weapon's projectile (FireBullet @1800):
-- THROW to the host; the game's projectile flies on as the own visual copy.
local function client_own_proj(actor, info, loc, rot)
    if not st.host_proj then
        M.stats.proj_local = M.stats.proj_local + 1
        once("proj-nocap", "throw: own %s: the host did not announce launcher sync (PRJCAP); it stays the game's local projectile",
            info.short)
        return
    end
    local mesh = proj_mesh(actor)
    if not mesh then return end
    local coll = num(ue.try(function() return mesh:GetCollisionEnabled() end))
    if not pcall(function() mesh:SetCollisionEnabled(COLL_NONE) end) then
        log.err_throttled("throw.projquiet", "throw: own %s: collision could not be turned off; it stays local", info.short)
        return
    end
    st.seq = st.seq + 1
    st.last_proj_kept = false
    local seq = st.seq
    local e = { key = "c" .. seq, seq = seq, info = info, t0 = clock(), own = true, path = ue.path(actor), coll = coll }
    st.copies[e.key] = e
    local lo, hi = num(ue.prop(actor, "MinDmg")) or 0, num(ue.prop(actor, "MaxDmg")) or 0
    local vel = vec(ue.prop(ue.prop(actor, "ProjectileMovement"), "Velocity")) or { X = 0, Y = 0, Z = 0 }
    M.stats.proj_own = M.stats.proj_own + 1
    local sent = net.send_to_host("THROW", tostring(seq), info.short, f3(loc), r3(rot), f3(vel),
        string.format("%.2f,%.2f", lo, hi))
    if sent then M.stats.sent = M.stats.sent + 1 end
    counted(M.stats.proj_own, 10, "throw: own %s #%d at %.0f,%.0f,%.0f (damage %.1f-%.1f): %s; it flies on here as the visual copy (collision off)",
        info.short, seq, loc.X, loc.Y, loc.Z, lo, hi, sent and "sent to the host" or "NOT sent (no connection)")
end

-- THRFX of a projectile: boom (blast class went off at loc) or stop (bolt /
-- flare stopped at loc, rot; flesh = body / head when the bolt hit one).
local function apply_proj_fx(key, g, e, info, phase, loc, rot, flesh)
    if e and e.kept then return end
    if e and e.own and phase == "stop" and (flesh == "body" or flesh == "head") and not e.marked then
        e.marked = true
        local d = package.loaded["sdc_dmgnum"]
        if type(d) == "table" and type(d.hitmarker) == "function" and d.hitmarker(flesh == "head", "the host's " .. info.short) then
            M.stats.proj_markers = M.stats.proj_markers + 1
        end
    end
    if e and e.done then return end
    local copy = e and find_actor(e.path, info.short) or nil
    if not copy then
        local why
        copy, why = spawn_proj(info, loc, rot or { Pitch = 0, Yaw = 0, Roll = 0 }, { quiet = true })
        if not copy then
            M.stats.copy_failed = M.stats.copy_failed + 1
            log.err_throttled("throw.projfx", "throw: %s %s of the host's %d not shown: %s", info.short, phase, g, tostring(why))
            return
        end
        if not e then
            e = { key = key, g = g, info = info, t0 = clock(), own = false }
            st.copies[key] = e
        end
        e.path = ue.path(copy)
    end
    local before = ue.location(copy)
    hold_at(copy, loc, rot)
    e.done, e.hit_at = true, clock()
    local moved = before and dist(before, loc) or -1
    if phase == "boom" then
        local ok, err = proj_set_off(copy, info)
        if ok then
            M.stats.set_off = M.stats.set_off + 1
            M.stats.proj_boom = M.stats.proj_boom + 1
            counted(M.stats.proj_boom, 10, "throw: %s boom (host's %d%s) at %.0f,%.0f,%.0f: copy moved %.0f cm and set off by its hit event",
                info.short, g, e.own and string.format(", own #%d", e.seq or -1) or "", loc.X, loc.Y, loc.Z, moved)
        else
            M.stats.set_off_failed = M.stats.set_off_failed + 1
            log.err_throttled("throw.projsetoff", "throw: %s could not be set off: %s", info.short, tostring(err))
        end
        return
    end
    if info.life then pcall(function() copy:SetLifeSpan(info.life) end) end
    M.stats.proj_stopped = M.stats.proj_stopped + 1
    counted(M.stats.proj_stopped, 10, "throw: %s stopped (host's %d%s) at %.0f,%.0f,%.0f%s: copy moved %.0f cm and held there",
        info.short, g, e.own and string.format(", own #%d", e.seq or -1) or "", loc.X, loc.Y, loc.Z,
        (flesh ~= nil and flesh ~= "") and (", hit " .. flesh) or "", moved)
end

-- THRFX: the host's throw went off at loc. phase: boom (fuse), hit (impact),
-- fire (the Molotov's fire, 0.2 s after its hit).
local function apply_fx(key, g, e, info, phase, loc)
    if e and e.kept then return end
    local copy = e and find_actor(e.path, info.short) or nil
    if phase == "fire" then
        if e and e.hit_at then
            if copy and clock() - e.hit_at < FIRE_WINDOW then
                freeze_at(copy, loc)
                e.fire_loc = loc
                M.stats.fire_moved = M.stats.fire_moved + 1
                log.debug("throw: %s fire point from the host applied before the fire started", info.short)
            end
            return
        end
        phase = "hit"   -- no hit seen here: start from the fire point
    end
    if e and e.done then return end
    if not copy then
        local why
        copy, why = spawn(info, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 0, Y = 0, Z = 0 }, { quiet = true })
        if not copy then
            M.stats.copy_failed = M.stats.copy_failed + 1
            log.err_throttled("throw.fxspawn", "throw: %s %s of the host's throw %d not shown: %s", info.short, phase, g,
                tostring(why))
            return
        end
        if not e then
            e = { key = key, g = g, info = info, t0 = clock(), own = false }
            st.copies[key] = e
        end
        e.path = ue.path(copy)
    end
    local before = ue.location(copy)
    freeze_at(copy, loc)
    local ok, err = set_off(copy, info)
    e.done, e.hit_at, e.fire_loc = true, clock(), loc
    if ok then
        M.stats.set_off = M.stats.set_off + 1
        counted(M.stats.set_off, 10, "throw: %s %s (host's %d%s) at %.0f,%.0f,%.0f: copy moved %.0f cm and set off by the game's %s",
            info.short, phase, g, e.own and string.format(", own #%d", e.seq or -1) or "", loc.X, loc.Y, loc.Z,
            before and dist(before, loc) or -1, info.kind == "fuse" and info.event or "hit event")
    else
        M.stats.set_off_failed = M.stats.set_off_failed + 1
        log.err_throttled("throw.setoff", "throw: %s could not be set off: %s", info.short, tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Host: tracking, a client's throw, announcements
-- ---------------------------------------------------------------------------

local function host_track(actor, info, pc, seq)
    st.next_g = st.next_g + 1
    local e = { g = st.next_g, info = info, name = ue.short(actor), t0 = clock(), seq = seq, sent = {},
                pc = pc and addr(pc) or nil, who = pc and ue.short(pc) or "host" }
    local a = addr(actor)
    if a then st.tracked[a] = e end
    return e
end

local function announce(e, loc, rot, vel, pawn)
    local n = 0
    local id = pawn and appearance.player_id(pawn)
    local who = id and tostring(id) or "?"
    for _, pc in ipairs(S.remote_pcs or {}) do
        if addr(pc) ~= e.pc and net.send_to(pc, "THROWN", tostring(e.g), e.info.short, f3(loc), r3(rot), f3(vel), who) then
            n = n + 1
        end
    end
    M.stats.announced = M.stats.announced + n
    return n
end

local function host_own_throw(actor, info, loc, rot, vel)
    if #(S.remote_pcs or {}) == 0 then return end
    local e = host_track(actor, info, nil, nil)
    local pawn = ue.local_pawn()
    local n = announce(e, loc, rot, vel, pawn)
    M.stats.host_own = M.stats.host_own + 1
    counted(M.stats.host_own, 10, "throw: host's %s as %d at %.0f,%.0f,%.0f: shown to %d client(s)", info.short, e.g,
        loc.X, loc.Y, loc.Z, n)
end

-- The host's copy of the shooter's weapon whose ProjectileClass is `short`
-- (an actor the character owns: AActor.Children).
local function proj_weapon_of(pawn, short)
    local found = nil
    pcall(function()
        pawn.Children:ForEach(function(_, ep)
            if found then return end
            local a = ep:get()
            local comp = ue.prop(a, "BP_WeaponsPickupComponent")
            if ue.valid(comp) and ue.prop(comp, "DoesWeaponUseAProjectile?") == true
                and ue.short(ue.prop(comp, "ProjectileClass")) == short then
                found = a
            end
        end)
    end)
    return found
end

local function track_proj(actor, info, pc, seq, weapon)
    local e = host_track(actor, info, pc, seq)
    e.path = ue.path(actor)
    e.weapon = weapon and addr(weapon) or nil
    if info.kind == "stick" then
        local a = addr(actor)
        if a then st.sticks[a] = e end
    end
    return e
end

-- THROW of a projectile class (client -> host):
-- THROW|seq|class|x,y,z|pitch,yaw,roll|vx,vy,vz|min,max
local function host_proj_shot(f, pc, pk, seq, info, loc, rot, vel, refuse)
    local function no(why)
        M.stats.proj_refused = M.stats.proj_refused + 1
        return refuse(why)
    end
    local now = clock()
    local r = st.prate[pk]
    if not r or now - r.t > PROJ_RATE_S then r = { t = now, n = 0 }; st.prate[pk] = r end
    r.n = r.n + 1
    if r.n > PROJ_RATE_N then return no("too many shots") end
    local lo, hi = tostring(f[6] or ""):match("^(%-?[%d.]+),(%-?[%d.]+)$")
    lo, hi = num(lo), num(hi)
    if not lo or not hi or lo < 0 or hi < 0 or lo > PROJ_MAX_DMG or hi > PROJ_MAX_DMG then return no("bad damage") end
    if len(vel) > PROJ_MAX_SPEED then return no(string.format("speed %.0f cm/s", len(vel))) end
    local pawn = ue.pawn_of(pc)
    if not pawn or not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return no("no character") end
    if ue.prop(pawn, "PlayerDead?") == true then return no("the character is dead") end
    local pl = ue.location(pawn)
    local d = pl and dist(pl, loc) or -1
    if d < 0 or d > MAX_SPAWN_DIST then return no(string.format("spawn point %.0f cm from the character", d)) end
    local weapon = proj_weapon_of(pawn, info.short)
    if not weapon then return no("no weapon firing " .. info.short .. " on the host's copy") end
    -- "player 0" inside the projectile is this player (sdc_ctx walks its owner)
    pcall(ctx.bind, pawn, pc)
    local actor, why = spawn_proj(info, loc, rot, { owner = pawn, weapon = weapon, dmg = { lo, hi },
                                                     ignore = { pawn, weapon } })
    if not actor then return no("spawn failed: " .. tostring(why)) end
    local e = track_proj(actor, info, pc, seq, weapon)
    net.send_to(pc, "THRACK", tostring(seq), tostring(e.g), "1", "")
    local n = announce(e, loc, rot, vel, pawn)
    M.stats.proj_host = M.stats.proj_host + 1
    counted(M.stats.proj_host, 10, "throw: %s fired %s (#%d) from %s: spawned on the host as %d (%s, owner %s, damage %.1f-%.1f, %.0f cm from its character), shown to %d other client(s)",
        ue.short(pc), info.short, seq, ue.short(weapon), e.g, ue.short(actor), ue.short(pawn), lo, hi, d, n)
end

-- FinishSpawningActor (post) on the host: the host's own projectile.
local function host_own_proj(actor, info, weapon, loc, rot)
    if #(S.remote_pcs or {}) == 0 then return end
    local e = track_proj(actor, info, nil, nil, weapon)
    local vel = vec(ue.prop(ue.prop(actor, "ProjectileMovement"), "Velocity")) or { X = 0, Y = 0, Z = 0 }
    local n = announce(e, loc, rot, vel, ue.local_pawn())
    M.stats.proj_host_own = M.stats.proj_host_own + 1
    counted(M.stats.proj_host_own, 10, "throw: host's %s as %d at %.0f,%.0f,%.0f: shown to %d client(s)", info.short, e.g,
        loc.X, loc.Y, loc.Z, n)
end

-- Host: THRFX stop of a bolt / flare where it stopped.
local function send_stop(e, actor, flesh)
    if e.stop_sent then return end
    e.stop_sent = true
    local l = ue.location(actor)
    if not l then return end
    local r = rot_of(actor)
    local n = 0
    for _, pc in ipairs(S.remote_pcs or {}) do
        if net.send_to(pc, "THRFX", tostring(e.g), e.info.short, "stop", f3(l), r3(r), flesh or "") then n = n + 1 end
    end
    M.stats.fx_sent = M.stats.fx_sent + 1
    M.stats.proj_stops = M.stats.proj_stops + 1
    counted(M.stats.proj_stops, 15, "throw: %d %s of %s stopped at %.0f,%.0f,%.0f%s (%.1f s after the shot): sent to %d client(s)",
        e.g, e.info.short, e.who, l.X, l.Y, l.Z, (flesh and flesh ~= "") and (", hit " .. flesh) or "", clock() - e.t0, n)
end

-- Host, every tick: flying bolts and flares that stopped (a bolt that hit flesh
-- was sent from its SERVER_DamageEvent already).
local function stick_tick()
    for a, e in pairs(st.sticks) do
        local actor = (not e.stop_sent) and find_actor(e.path, e.info.short) or nil
        if not actor then
            st.sticks[a] = nil   -- sent, or gone without stopping (its life span): the copies have the same one
        elseif proj_stopped(actor) then
            send_stop(e, actor, "")
            st.sticks[a] = nil
        end
    end
end

-- BP_FirearmPickup.SERVER_DamageEvent(Headshot, DamagedActor, ImpactPoint),
-- after it ran on the host: a flying bolt of that weapon hit flesh
-- (BP_ProjectileArrow @1330 body / @1802 head). Its hit event runs while the
-- bolt already is at its hit point.
local function on_damage_event(c, head_p, _, imp_p)
    if not S or S.role ~= "host" or next(st.sticks) == nil then return end
    local w = get(c)
    local wa = w ~= nil and addr(w) or nil
    if not wa then return end
    local imp = vec(get(imp_p))
    local best, best_actor, best_d = nil, nil, STOP_MATCH_CM
    for _, e in pairs(st.sticks) do
        if e.weapon == wa and not e.stop_sent then
            local actor = find_actor(e.path, e.info.short)
            local l = actor and ue.location(actor)
            local d = (l and imp) and dist(l, imp) or math.huge
            if d <= best_d then best, best_actor, best_d = e, actor, d end
        end
    end
    if not best then return end
    send_stop(best, best_actor, get(head_p) == true and "head" or "body")
end

-- GameplayStatics.FinishSpawningActor (post, both roles): a projectile that
-- FireBullet of this machine's own player just finished (@1800).
local function on_finish(...)
    if st.spawning or not coop() or not proj_on() then return end
    local actor, info = nil, nil
    for i = 1, select("#", ...) do
        local v = get((select(i, ...)))
        if v ~= nil and ue.valid(v) then
            info = class_info(ue.class_name(v))
            if info and info.proj then
                actor = v
                break
            end
            info = nil
        end
    end
    if not actor then return end
    local name = ue.short(actor)
    if st.seen[name] then return end
    st.seen[name] = clock()
    local weapon = ue.prop(actor, "WeaponOwner")
    local pawn = ue.valid(weapon) and ue.try(function() return weapon:GetOwner() end) or nil
    local me = ue.local_pawn()
    if not me or not ue.valid(pawn) or addr(pawn) ~= addr(me) then return end
    local loc = ue.location(actor)
    if not loc then return end
    local rot = rot_of(actor)
    if S.role == "client" then
        client_own_proj(actor, info, loc, rot)
    elseif S.role == "host" then
        host_own_proj(actor, info, weapon, loc, rot)
    end
end

-- THROW|seq|class|x,y,z|pitch,yaw,roll|vx,vy,vz (client -> host)
local function host_throw(f, pc)
    if not S or S.role ~= "host" or not ue.valid(pc) then return end
    local seq = num(f[1])
    if not seq then return end
    seq = math.floor(seq)
    local function refuse(why)
        M.stats.host_refused = M.stats.host_refused + 1
        log.warn("throw: %s's throw #%d (%s) refused: %s", ue.short(pc), seq, tostring(f[2]), why)
        net.send_to(pc, "THRACK", tostring(seq), "0", "0", why)
    end
    local info = class_info(f[2])
    if info and info.proj then
        if not proj_on() then return refuse("launcher_sync is off on the host") end
    elseif not sync_on() then
        return refuse("throw_sync is off on the host")
    end
    local pk = addr(pc)
    if not pk then return end
    local seqs = st.seqs[pk]
    if not seqs then seqs = {}; st.seqs[pk] = seqs end
    if seqs[seq] then return end   -- the same throw twice
    seqs[seq] = clock()
    local loc, rot, vel = parse_vec(f[3]), parse_rot(f[4]), parse_vec(f[5])
    if not info or not loc or not rot or not vel then return refuse("bad message") end
    if info.proj then return host_proj_shot(f, pc, pk, seq, info, loc, rot, vel, refuse) end
    local now = clock()
    local r = st.rate[pk]
    if not r or now - r.t > RATE_S then r = { t = now, n = 0 }; st.rate[pk] = r end
    r.n = r.n + 1
    if r.n > RATE_N then return refuse("too many throws") end
    local pawn = ue.pawn_of(pc)
    if not pawn or not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return refuse("no character") end
    if ue.prop(pawn, "PlayerDead?") == true then return refuse("the character is dead") end
    local pl = ue.location(pawn)
    local d = pl and dist(pl, loc) or -1
    if d < 0 or d > MAX_SPAWN_DIST then return refuse(string.format("spawn point %.0f cm from the character", d)) end
    if len(vel) > MAX_SPEED then return refuse(string.format("speed %.0f cm/s", len(vel))) end
    -- the projectile's "player 0" is this player (sdc_ctx walks its owner)
    pcall(ctx.bind, pawn, pc)
    local actor, why = spawn(info, loc, rot, vel, { owner = pawn })
    if not actor then return refuse("spawn failed: " .. tostring(why)) end
    -- a fuse class only starts its fuse on Event_Throw, which the thrower's
    -- character broadcasts after its own spawn (BP_PlayerCharacter @14507;
    -- BP_Throwable_Frag binds Event_Throw -> Frag @2788). Spawned here, nobody
    -- broadcast it: up to 0.7.2 a client's frag / pipe bomb / noise maker lay
    -- on the host without going off (no damage, no THRFX boom; the clients'
    -- copies "never went off"). The event bound to it, with its own
    -- ExplosionDelay, as the game's throw.
    if info.kind == "fuse" then
        local okf, errf = pcall(function() actor[info.event](actor) end)
        if not okf then log.warn("throw: %s's %s: its fuse (%s) did not start: %s", ue.short(pc), info.short, info.event,
            tostring(errf)) end
    end
    local e = host_track(actor, info, pc, seq)
    net.send_to(pc, "THRACK", tostring(seq), tostring(e.g), "1", "")
    local n = announce(e, loc, rot, vel, pawn)
    M.stats.host_spawned = M.stats.host_spawned + 1
    counted(M.stats.host_spawned, 10, "throw: %s threw %s (#%d): spawned on the host as %d (%s, owner %s, %.0f cm from its character, %.0f cm/s), shown to %d other client(s)",
        ue.short(pc), info.short, seq, e.g, ue.short(actor), ue.short(pawn), d, len(vel), n)
end

-- PlaySoundAtLocation / SpawnSoundAtLocation (pre, host): the first sound of a
-- tracked projectile is the moment it goes off.
local function on_sound(fn, wco_p, loc_p)
    if not S or S.role ~= "host" or next(st.tracked) == nil then return end
    local w = get(wco_p)
    local a = w ~= nil and addr(w) or nil
    local e = a and st.tracked[a]
    if not e then return end
    if ue.short(w) ~= e.name then st.tracked[a] = nil; return end   -- another object at that address
    local phase
    if fn == "SpawnSoundAtLocation" then
        if e.info.kind ~= "impact" then return end
        phase = "fire"
    elseif e.info.kind == "stick" then
        return   -- bolts and flares stop silently (stick_tick / on_damage_event)
    else
        -- a launcher grenade / rocket: its explosion sound (@1938 / @1842)
        phase = (e.info.kind == "fuse" or e.info.kind == "blast") and "boom" or "hit"
    end
    if e.sent[phase] then return end
    e.sent[phase] = true
    local l = vec(get(loc_p)) or ue.location(w)
    if not l then return end
    if e.pc and phase == "boom" then st.blast_until = clock() + BLAST_S end
    -- sdc_ffire: the blast's damage loop runs right after this sound (not
    -- the noise maker's firecracker: no damage); the Molotov's fire burns
    -- players around this point
    if phase == "boom" then
        if not e.info.harmless then st.last_boom = { pc = e.pc, who = e.who, short = e.info.short, loc = l, t = clock() } end
    elseif phase == "fire" and e.info.short == MOLOTOV then
        e.fire_loc, e.fire_at = l, clock()
    end
    local n = 0
    for _, pc in ipairs(S.remote_pcs or {}) do
        if net.send_to(pc, "THRFX", tostring(e.g), e.info.short, phase, f3(l)) then n = n + 1 end
    end
    M.stats.fx_sent = M.stats.fx_sent + 1
    counted(M.stats.fx_sent, 15, "throw: %d %s of %s %s at %.0f,%.0f,%.0f (%.1f s after the throw): sent to %d client(s)",
        e.g, e.info.short, e.who, phase, l.X, l.Y, l.Z, clock() - e.t0, n)
end

-- GameFunctionLibrary.SpawnDamageNumbers(Dmg, Color, ImpactPoint,
-- __WorldContext), post (host): numbers of a client's projectile go to it.
local function on_numbers(...)
    if not S or S.role ~= "host" or next(st.tracked) == nil then return end
    local dmg, col, imp, e = nil, nil, nil, nil
    for i = 1, select("#", ...) do
        local v = get((select(i, ...)))
        if type(v) == "number" then
            if dmg == nil then dmg = num(v) end
        elseif v ~= nil then
            -- structs first (their wrappers may answer IsValid too)
            if not col and num(ue.try(function() return v.R end)) then
                col = v
            elseif not imp and vec(v) then
                imp = vec(v)
            elseif ue.valid(v) then
                local te = st.tracked[addr(v) or -1]
                if te and ue.short(v) == te.name then e = te end
            end
        end
    end
    if not e or not e.pc or not col or not imp then return end
    local pc = pc_by_addr(e.pc)
    if not pc then return end
    local c = string.format("%.3f,%.3f,%.3f,%.3f", num(ue.try(function() return col.R end)) or 1,
        num(ue.try(function() return col.G end)) or 1, num(ue.try(function() return col.B end)) or 1,
        num(ue.try(function() return col.A end)) or 1)
    if net.send_to(pc, "DMGNUM", string.format("%.2f", math.max(0, dmg or 0)), c,
        string.format("%.1f,%.1f,%.1f", imp.X, imp.Y, imp.Z)) then
        M.stats.dmgnum = M.stats.dmgnum + 1
        once("dmgnum", "throw: damage numbers of %s's %s sent to that player", e.who, e.info.short)
    end
end

-- UserWidget.AddToViewport (pre, host): a client's blast projected its damage
-- numbers through that client's controller, which has no screen here: the
-- number lands at 0,0 of the host's screen. Hidden like sdc_dmgnum's zeros.
local function on_viewport(ctx_p)
    if not S or S.role ~= "host" or clock() > st.blast_until then return end
    local w = get(ctx_p)
    if not ue.valid(w) or ue.class_name(w) ~= NUMBERS_CLASS then return end
    local p = ue.prop(w, "InitialPosition")
    local x, y = num(ue.try(function() return p.X end)), num(ue.try(function() return p.Y end))
    if x ~= 0 or y ~= 0 then return end
    pcall(function() w:SetVisibility(1) end)   -- Collapsed
    ue.delay("throw-numbers", 30, function()
        if ue.valid(w) and ue.class_name(w) == NUMBERS_CLASS then pcall(function() w:RemoveFromParent() end) end
    end)
    M.stats.numbers_hidden = M.stats.numbers_hidden + 1
    once("hidden", "throw: a client's damage number at the host's screen corner hidden (it went to that player)")
end

-- ---------------------------------------------------------------------------
-- Both roles: the game's throw (velocity of a new projectile)
-- ---------------------------------------------------------------------------

-- PrimitiveComponent.SetPhysicsLinearVelocity(NewVel, bAddToCurrent,
-- BoneName), pre. In the game only BP_PlayerCharacter's throw (@15269) and
-- the projectiles' own bounce damping call it.
local function on_velocity(ctx_p, vel_p)
    if st.spawning or not coop() or not sync_on() then return end
    local comp = get(ctx_p)
    if not ue.valid(comp) then return end
    local actor = ue.try(function() return comp:GetOwner() end)
    if not ue.valid(actor) then return end
    local short = ue.class_name(actor)
    if short:sub(1, #PREFIX) ~= PREFIX then return end
    local name = ue.short(actor)
    if st.seen[name] then return end
    st.seen[name] = clock()
    local info = class_info(short)
    local vel = vec(get(vel_p))
    local loc = ue.location(actor)
    if not info or not vel or not loc then return end
    local rot = rot_of(actor)
    if S.role == "client" then
        client_own_throw(actor, comp, info, loc, rot, vel)
    elseif S.role == "host" then
        host_own_throw(actor, info, loc, rot, vel)
    end
end

-- ---------------------------------------------------------------------------
-- Client: one throw, one consume request
-- ---------------------------------------------------------------------------

-- SceneComponent.K2_SetWorldRotation (pre, client): on the own character's
-- capsule only the throw calls it (@54709, right after Svr_Montage).
local function throw_started()
    local now = clock()
    if st.montage_at and now - st.montage_at < 1.0 then return end
    local pawn = ue.local_pawn()
    if not pawn or addr(pawn) ~= st.my_pawn then return end
    if ue.valid(ue.try(function() return pawn:GetCurrentMontage() end)) then return end
    local montage = ue.find_object(THROW_MONTAGE)
    local mesh = ue.prop(pawn, "Mesh")
    local anim = ue.valid(mesh) and ue.try(function() return mesh:GetAnimInstance() end) or nil
    if not montage or not ue.valid(anim) then return end
    if pcall(function() anim:Montage_Play(montage, 1.0, 0, 0.0, true) end) then
        st.montage_at, st.align_pending, st.montage_addr = now, true, addr(montage)
        M.stats.montage = M.stats.montage + 1
        counted(M.stats.montage, 3, "throw: throw montage started here at once (as in single player): one consume request per throw")
    end
end

-- Runs for every K2_SetWorldRotation on the client (the sky's lights turn
-- every frame): the context's address is compared without making a closure.
local function o_addr(o) return o:GetAddress() end
local function on_rotate(ctx_p)
    local cap = st.my_capsule
    if not cap or not S or S.role ~= "client" then return end
    local c = get(ctx_p)
    if c == nil then return end
    local oka, a = pcall(o_addr, c)
    if not oka or a ~= cap or not gate_on() then return end
    throw_started()
end

-- PlayMontageCallbackProxy.CreateProxyObjectForPlayMontage (pre, client): the
-- server's MC_Montage for the throw started here goes on from where the
-- local one is instead of restarting it.
local function on_proxy(_, mesh_p, montage_p, rate_p, start_p)
    if not st.align_pending or not S or S.role ~= "client" then return end
    local el = clock() - (st.montage_at or -100)
    if el > ALIGN_S then st.align_pending = false; return end
    local m = get(montage_p)
    if m == nil or addr(m) ~= st.montage_addr then return end
    local mesh = get(mesh_p)
    if mesh == nil or addr(mesh) ~= st.my_mesh then return end
    if type(get(start_p)) ~= "number" then return end
    st.align_pending = false
    local rate = num(get(rate_p)) or 1
    local length = num(ue.try(function() return m:GetPlayLength() end)) or MONTAGE_LEN
    local pos = math.max(0, math.min(el * rate, length - 0.05))
    if pcall(function() start_p:set(pos) end) then
        M.stats.aligned = M.stats.aligned + 1
        counted(M.stats.aligned, 3, "throw: the server's throw montage continues the local one at %.2f s", pos)
    end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- One shared engine hook per native function (sdc_ue.hook_native: pre only,
-- no empty post callback - K2_SetWorldRotation runs every frame for the sky).
local function hook_native(key, path, pre)
    if st.hooks[key] then return end
    st.hooks[key] = true   -- a failure is logged, not retried
    local ok, err = ue.hook_native(path, "throw." .. key, function(...)
        local okc, e = pcall(pre, ...)
        if not okc then log.err_throttled("throw." .. key, "throw: %s hook: %s", key, tostring(e)) end
    end)
    log.info("throw: %s hook %s%s", key, ok and "ok" or "FAILED ", ok and "" or tostring(err))
end

-- FinishSpawningActor needs its result: a post callback of its own (the
-- shared sdc_ue.hook_native is pre only). A failure is logged, not retried.
local function hook_finish()
    if st.hooks.finish then return end
    st.hooks.finish = true
    local ok, err = pcall(RegisterHook, FN_FINISH, function() end, function(_, ...)
        local okc, e = pcall(on_finish, ...)
        if not okc then log.err_throttled("throw.finish", "throw: FinishSpawningActor hook: %s", tostring(e)) end
    end)
    log.info("throw: finish hook %s%s", ok and "ok (launcher / bow projectiles)" or "FAILED ", ok and "" or tostring(err))
end

local function install_hooks(now)
    if sync_on() then
        hook_native("velocity", FN_VELOCITY, function(c, vel_p) on_velocity(c, vel_p) end)
    end
    if proj_on() then hook_finish() end
    if S.role == "host" and proj_on() and not st.damage_hooked and now >= st.damage_next then
        -- the firearm class loads with the first firearm: retried every 2 s
        st.damage_next = now + 2
        local ok = pcall(RegisterHook, FN_DAMAGE_EVENT, function(c, head_p, actor_p, imp_p)
            local okc, e = pcall(on_damage_event, c, head_p, actor_p, imp_p)
            if not okc then log.err_throttled("throw.damage", "throw: SERVER_DamageEvent hook: %s", tostring(e)) end
        end)
        if ok then
            st.damage_hooked = true
            log.info("throw: SERVER_DamageEvent hook ok (bolts that hit flesh)")
        end
    end
    if S.role == "host" then
        if sync_on() or proj_on() then
            -- (Context, WorldContextObject, Sound, Location, ...)
            hook_native("play-sound", FN_PLAY_SOUND, function(_, wco_p, _sound, loc_p)
                on_sound("PlaySoundAtLocation", wco_p, loc_p)
            end)
            hook_native("spawn-sound", FN_SPAWN_SOUND, function(_, wco_p, _sound, loc_p)
                on_sound("SpawnSoundAtLocation", wco_p, loc_p)
            end)
            hook_native("viewport", FN_VIEWPORT, function(c) on_viewport(c) end)
            -- a Blueprint function library: hookable once its class is loaded
            if not st.numbers_hooked and now >= st.numbers_next then
                st.numbers_next = now + 2
                local ok = pcall(RegisterHook, FN_NUMBERS, function(_, ...)
                    local okc, e = pcall(on_numbers, ...)
                    if not okc then log.err_throttled("throw.numbers", "throw: SpawnDamageNumbers hook: %s", tostring(e)) end
                end)
                if ok then
                    st.numbers_hooked = true
                    log.info("throw: SpawnDamageNumbers hook ok")
                end
            end
        end
    elseif S.role == "client" and gate_on() then
        hook_native("rotate", FN_ROTATE, function(c) on_rotate(c) end)
        hook_native("montage", FN_PROXY, function(...) on_proxy(...) end)
    end
end

-- ---------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------

local function refresh_own(now)
    if now - st.own_at < 0.5 then return end
    st.own_at = now
    local pawn = ue.local_pawn()
    if not pawn then
        st.my_pawn, st.my_capsule, st.my_mesh = nil, nil, nil
        return
    end
    st.my_pawn = addr(pawn)
    local cap, mesh = ue.prop(pawn, "CapsuleComponent"), ue.prop(pawn, "Mesh")
    st.my_capsule = ue.valid(cap) and addr(cap) or nil
    st.my_mesh = ue.valid(mesh) and addr(mesh) or nil
end

local function client_tick(now)
    for key, e in pairs(st.copies) do
        if e.own and not e.acked and not e.done and not e.kept
            and now - e.t0 > (e.info.proj and PROJ_NO_ACK_S or NO_ACK_S) then
            fallback(e, "no answer from the host (no sdc_throw there?)")
        end
        if now - e.t0 > LIFE_S then
            if not e.done and not e.kept then
                local copy = find_actor(e.path, e.info.short)
                if copy then pcall(function() copy:K2_DestroyActor() end) end
                log.debug("throw: copy %s of %s never went off; removed", key, e.info.short)
            end
            st.copies[key] = nil
        end
    end
end

-- Host, once a second: tells each client whether the host handles its
-- launcher / bow shots (PRJCAP|1/0): again for a new character of that player
-- (a new world there) and every CAP_RESEND_S.
local function send_caps(now)
    local want = proj_on() and "1" or "0"
    local live = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        local k = addr(pc)
        local pawn = ue.pawn_of(pc)
        if k and pawn then
            live[k] = true
            local sig = tostring(addr(pawn)) .. want
            if (st.cap_sent[k] ~= sig or now - (st.cap_at[k] or -1000) >= CAP_RESEND_S)
                and net.send_to(pc, "PRJCAP", want) then
                if st.cap_sent[k] ~= sig then
                    log.info("throw: launcher sync %s told to %s", want == "1" and "on" or "off", ue.short(pc))
                end
                st.cap_sent[k], st.cap_at[k] = sig, now
            end
        end
    end
    for k in pairs(st.cap_sent) do
        if not live[k] then st.cap_sent[k], st.cap_at[k] = nil, nil end
    end
    return live
end

local function host_tick(now)
    if next(st.sticks) ~= nil then stick_tick() end
    if now - st.host_at < 1 then return end
    st.host_at = now
    local live = send_caps(now)
    for a, e in pairs(st.tracked) do
        if now - e.t0 > LIFE_S then st.tracked[a] = nil end
    end
    -- seqs of a player who left go: a client restarted at a reused controller
    -- address numbers its throws from 1 again, and its first throws were
    -- taken for repeats and dropped (the item already used up)
    local connected = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        local k = addr(pc)
        if k then connected[k] = true end
    end
    for pk, seqs in pairs(st.seqs) do
        if not connected[pk] then
            st.seqs[pk] = nil
        else
            local n, oldest, oldest_t = 0, nil, math.huge
            for s, t in pairs(seqs) do
                n = n + 1
                if t < oldest_t then oldest, oldest_t = s, t end
            end
            if n > SEQ_KEEP and oldest then seqs[oldest] = nil end
            if n == 0 then st.seqs[pk] = nil end
        end
    end
    for pk, r in pairs(st.rate) do
        if now - r.t > 60 then st.rate[pk] = nil end
    end
    for pk, r in pairs(st.prate) do
        if now - r.t > 60 then st.prate[pk] = nil end
    end
end

-- Client: the throwable classes, loaded once per world 10 s after this
-- player's character exists, one a second. load_class takes only classes
-- already in memory on a client (no synchronous load on a message path), so
-- a class nobody here has used yet would leave a teammate's throw invisible.
-- These five are small and loaded once, off the message path.
local PRELOAD = { "BP_Throwable_Frag_C", "BP_Throwable_PipeBomb_C", "BP_Throwable_NoiseMaker_C",
                  "BP_Throwable_Molotov_C", "BP_Throwable_GlassBottle_C" }
local function client_preload(now)
    if st.preload_done then return end
    if not ue.local_pawn() then st.preload_from = nil return end
    st.preload_from = st.preload_from or now
    if now - st.preload_from < 10 or now - (st.preload_at or -100) < 1 then return end
    st.preload_at = now
    st.preload_i = (st.preload_i or 0) + 1
    local short = PRELOAD[st.preload_i]
    if not short then
        st.preload_done = true
        log.debug("throw: throwable classes preloaded here")
        return
    end
    local info = class_info(short)
    if info and info.path and not ue.find_object(info.path) then ue.load_asset(info.path, "throw preload") end
end
M._client_preload = client_preload

function M.tick()
    if not coop() then
        if next(st.copies) or next(st.tracked) then M.reset("not in co-op") end
        return
    end
    local now = clock()
    -- (each call builds the hook closures: once a second, not every 100 ms)
    if now - st.hooks_at >= 1 then
        st.hooks_at = now
        install_hooks(now)
    end
    for name, t in pairs(st.seen) do
        if now - t > SEEN_S then st.seen[name] = nil end
    end
    if S.role == "client" then
        refresh_own(now)
        client_preload(now)
        client_tick(now)
    else
        host_tick(now)
    end
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

function M.install(state)
    S = state
    -- client -> host: THROW|seq|class|x,y,z|pitch,yaw,roll|vx,vy,vz
    net.on("THROW", host_throw)
    -- host -> thrower: THRACK|seq|host id|1/0|reason
    net.on("THRACK", function(f)
        if not S or S.role ~= "client" then return end
        local seq, g = num(f[1]), num(f[2])
        local e = seq and st.copies["c" .. math.floor(seq)]
        if not e then return end
        e.acked = true
        if f[3] == "1" and g then
            g = math.floor(g)
            e.g = g
            st.copies["h" .. g] = e
            M.stats.acked = M.stats.acked + 1
            counted(M.stats.acked, 5, "throw: own %s #%d is the host's %d", e.info.short, e.seq, g)
        else
            M.stats.refused = M.stats.refused + 1
            fallback(e, "the host refused it (" .. tostring(f[4]) .. ")")
        end
    end)
    -- host -> clients that did not throw it: THROWN|id|class|x,y,z|p,y,r|vx,vy,vz|thrower PlayerId
    net.on("THROWN", function(f)
        if not S or S.role ~= "client" then return end
        local g, info = num(f[1]), class_info(f[2])
        local loc, rot, vel = parse_vec(f[3]), parse_rot(f[4]), parse_vec(f[5])
        if not g or not info or not loc or not rot or not vel then return end
        if info.proj then
            if not proj_on() or len(vel) > 2 * PROJ_MAX_SPEED then return end
        elseif not sync_on() or len(vel) > 2 * MAX_SPEED then
            return
        end
        if ue.in_main_menu() then return end
        g = math.floor(g)
        local key = "h" .. g
        if st.copies[key] then return end
        if info.proj then
            -- the same class from the same point and rotation flies the same
            -- way (InitialSpeed along the rotation); collision off
            local pcopy, pwhy = spawn_proj(info, loc, rot, { quiet = true })
            st.copies[key] = { key = key, g = g, info = info, t0 = clock(), own = false, path = pcopy and ue.path(pcopy) or nil }
            if pcopy then
                M.stats.copies = M.stats.copies + 1
                counted(M.stats.copies, 10, "throw: player %s's %s (host's %d) flies here as %s", tostring(f[6]), info.short, g,
                    ue.short(pcopy))
            else
                M.stats.copy_failed = M.stats.copy_failed + 1
                log.err_throttled("throw.pcopy", "throw: copy of %s (host's %d) not spawned: %s", info.short, g, tostring(pwhy))
            end
            return
        end
        local copy, why = spawn(info, loc, rot, vel, { quiet = true })
        -- who: the thrower's PlayerId (sdc_ffire: whose Molotov fire this is)
        st.copies[key] = { key = key, g = g, info = info, t0 = clock(), own = false, path = copy and ue.path(copy) or nil,
                           who = tonumber(f[6]) and tostring(math.floor(tonumber(f[6]))) or nil }
        if copy then
            M.stats.copies = M.stats.copies + 1
            counted(M.stats.copies, 10, "throw: player %s's %s (host's %d) flies here as %s", tostring(f[6]), info.short, g,
                ue.short(copy))
        else
            M.stats.copy_failed = M.stats.copy_failed + 1
            log.err_throttled("throw.copy", "throw: copy of %s (host's %d) not spawned: %s", info.short, g, tostring(why))
        end
    end)
    -- host -> clients: THRFX|id|class|boom/hit/fire|x,y,z
    -- (projectiles: THRFX|id|class|boom|x,y,z or THRFX|id|class|stop|x,y,z|p,y,r|""/body/head)
    net.on("THRFX", function(f)
        if not S or S.role ~= "client" then return end
        local g, info, phase, loc = num(f[1]), class_info(f[2]), f[3], parse_vec(f[4])
        if not g or not info or not loc then return end
        if info.proj then
            if not proj_on() or (phase ~= "boom" and phase ~= "stop") then return end
        elseif not sync_on() or (phase ~= "boom" and phase ~= "hit" and phase ~= "fire") then
            return
        end
        if ue.in_main_menu() then return end
        g = math.floor(g)
        local key = "h" .. g
        if info.proj then
            local flesh = f[6]
            if flesh ~= "body" and flesh ~= "head" then flesh = "" end
            apply_proj_fx(key, g, st.copies[key], info, phase, loc, parse_rot(f[5]), flesh)
            return
        end
        apply_fx(key, g, st.copies[key], info, phase, loc)
    end)
    -- host -> client: PRJCAP|1/0 - the host handles launcher / bow shots
    net.on("PRJCAP", function(f)
        if not S or S.role ~= "client" then return end
        local on = f[1] == "1"
        if on ~= st.host_proj then
            log.info("throw: the host %s launcher / bow shots (PRJCAP)", on and "handles" or "does not handle")
        end
        st.host_proj = on
    end)
    log.info("throw: installed (throw_sync=%s, throw_single_consume=%s, launcher_sync=%s)", tostring(sync_on()),
        tostring(gate_on()), tostring(proj_on()))
    -- the copies play the game's own sounds where the host's throw went off
    log.info("sound relay THROWN / THRFX: the copy at the host's point plays the game's own sounds with their attenuation (explosion_large_06 GunshotsSniper 325 m, firecracker GunshotsRifle 270 m, Molotov smash and fire Radio 31 m); nothing is played 2D")
end

-- sdc_dmgnum: a client's bolt flies on the host, so its hit marker comes
-- with the host's THRFX stop, not with Client_HitUI (unless the last own
-- projectile stayed local: refused / no answer).
function M.host_drives_projectiles()
    return S ~= nil and S.role == "client" and proj_on() and st.host_proj == true and st.last_proj_kept ~= true
end

-- sdc_ffire, host: the tracked blast (frag, pipe bomb, launcher grenade /
-- rocket; not the harmless noise maker) that went off within max_s (default
-- BOOM_MATCH_S): { pc = the thrower's controller address (nil: the host),
-- who, short, loc, t }, else nil. Its explosion sound comes first, then its
-- damage loop in the same Blueprint call (BP_Throwable_Frag @355 / @2411).
function M.blast_now(max_s)
    local b = st.last_boom
    if not b or clock() - b.t > (max_s or BOOM_MATCH_S) then return nil end
    return b
end

-- sdc_ffire: Molotov fires burning within `radius` cm of loc now:
-- { { pc, own, who, d } }. Host: its tracked throws (their fire sound's
-- point), pc = the thrower's controller address, nil = the host. Client:
-- its copies (frozen at the host's fire point), own = this player's throw,
-- who = the thrower's PlayerId (THROWN) or nil.
function M.fires_near(loc, radius)
    local out = {}
    if not S or not loc then return out end
    local now = clock()
    if S.role == "host" then
        for _, e in pairs(st.tracked) do
            if e.fire_loc and now - e.fire_at <= FIRE_LIFE_S then
                local d = dist(e.fire_loc, loc)
                if d <= radius then out[#out + 1] = { pc = e.pc, own = false, who = e.who, d = d } end
            end
        end
    elseif S.role == "client" then
        local seen = {}   -- an own throw is kept under two keys
        for _, e in pairs(st.copies) do
            if not seen[e] and e.info.short == MOLOTOV and e.hit_at and now - e.hit_at <= FIRE_LIFE_S then
                seen[e] = true
                local l = e.fire_loc
                if not l then
                    local copy = find_actor(e.path, e.info.short)
                    l = copy and ue.location(copy) or nil
                end
                local d = l and dist(l, loc) or math.huge
                if d <= radius then out[#out + 1] = { own = e.own == true, who = e.who, d = d } end
            end
        end
    end
    return out
end

-- Level change / role change: every remembered object is dropped untouched.
function M.reset(why)
    st.copies, st.tracked, st.seen, st.rate, st.seqs = {}, {}, {}, {}, {}
    st.sticks, st.prate, st.cap_sent, st.cap_at, st.host_proj = {}, {}, {}, {}, false
    st.last_proj_kept, st.last_boom = nil, nil
    st.my_pawn, st.my_capsule, st.my_mesh, st.own_at = nil, nil, nil, -100
    st.montage_at, st.align_pending, st.montage_addr = nil, false, nil
    st.blast_until = 0
    st.hooks_at = -100   -- a new role: its hooks right away
    st.preload_done, st.preload_from, st.preload_at, st.preload_i = nil, nil, nil, nil
    log.debug("throw: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    local copies = 0
    for _ in pairs(st.copies) do copies = copies + 1 end
    local tracked = 0
    for _ in pairs(st.tracked) do tracked = tracked + 1 end
    local sticks = 0
    for _ in pairs(st.sticks) do sticks = sticks + 1 end
    return string.format("throw: own=%d sent=%d acked=%d refused=%d fallback=%d swaps=%d/%d | host: client throws=%d refused=%d own=%d announced=%d fx=%d dmgnum=%d hidden=%d tracked=%d | copies=%d (now %d) set off=%d failed=%d/%d fire moved=%d | montage local=%d aligned=%d | projectiles (launcher_sync=%s, host handles=%s): own=%d kept local=%d | host: client shots=%d refused=%d own=%d stops=%d flying=%d | copies boom=%d stopped=%d hit markers=%d",
        s.own, s.sent, s.acked, s.refused, s.fallback, s.swaps, s.swap_failed, s.host_spawned, s.host_refused, s.host_own,
        s.announced, s.fx_sent, s.dmgnum, s.numbers_hidden, tracked, s.copies, copies, s.set_off, s.set_off_failed,
        s.copy_failed, s.fire_moved, s.montage, s.aligned, tostring(proj_on()), tostring(st.host_proj),
        s.proj_own, s.proj_local, s.proj_host, s.proj_refused, s.proj_host_own, s.proj_stops, sticks, s.proj_boom,
        s.proj_stopped, s.proj_markers)
end

return M
