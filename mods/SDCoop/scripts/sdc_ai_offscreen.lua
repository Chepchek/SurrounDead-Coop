-- SDCoop AI feature ai_offscreen_combat: fights the host does not look at.
--
-- How far a skeletal mesh animates depends on what the machine renders
-- (CharacterMeshComponent.VisibilityBasedAnimTickOption, bRecentlyRendered).
-- On the host, "rendered" means "in the HOST's view". In single player the
-- player who fights is the one looking. In co-op a client fights where the
-- host may not look. Two things then break on the host, where all AI and all
-- melee traces run:
--
-- 1. Wolves and bears never hurt a client.
--    BP_AnimalWolf / BP_AnimalBear CharacterMesh0 use OnlyTickPoseWhenRendered
--    (zombies and BP_Animal use OnlyTickMontagesWhenNotRendered). Attack:
--    BTTask_CallAttackEvent -> CallAttackEvent -> AttackPlayer (wolf @9248,
--    bear @7639) -> PlayAnimMontage(bite / claw) -> the montage's
--    AnimNotify_BeginEvent "AttackTrace" starts the AttackTrace timer: a
--    SphereTraceSingleForObjects at the 'Jaw' socket -> Event_OnHit ->
--    ApplyDamage(HitActor, ScalingDamageMultiplier(DamageToDo)) + Bleed.
--    A wolf that the host does not render never advances that montage. The
--    notify never fires, so there is no trace and no damage. AttackPlayer then
--    returns early (GetCurrentMontage still valid) until the host looks at it.
--    Targeting is not the cause: BTTask_FindAttackTargetLocation takes the
--    nearest actor that the AIPerception sees with the tag WolfCanAttack /
--    BearCanAttack (every BP_PlayerCharacter has both by default), not
--    player 0. The player's ReceiveAnyDamage does not check the damage causer.
-- 2. A client's knife misses animals.
--    The swing montage is multicast. Its AnimNotify_MeleeHitDetect runs
--    BP_MeleePickup.MeleeTrace on the host every frame: a 32 cm sphere sweep
--    between the knife's 'Start' and 'End' sockets -> Event_OnHitNormal ->
--    (surface) HitBody / HitHead -> ApplyDamage. The host's copy of the client
--    (CharacterMesh0: OnlyTickMontagesWhenNotRendered) ticks the montage but
--    does not refresh its bones while the host does not render it. So the
--    knife stays where the host last saw it, and the sweep does not swing.
--    That can still touch a zombie at chest height, but it passes over deer,
--    wolves and rabbits. The client's local trace runs too. Its ApplyDamage
--    returns 0 on a non-authority, which is the "0" number the client saw.
--    Guns are not affected: the client traces itself and sends
--    SERVER_DamageEvent(actor), the same path as zombies. No animal-specific
--    gate exists on it.
--
-- Fix (host, with a client connected), as the game's settings for meshes that
-- must work unseen:
--   * AttackPlayer post-hook (wolf, bear): that animal's mesh is set to
--     AlwaysTickPoseAndRefreshBones. Its attack plays, its notify fires and its
--     jaw / claw moves as in single player. This is set again on each attack,
--     because the AI optimizer may change mesh settings between its layers.
--   * Every tick: each remote player's pawn mesh is set to
--     AlwaysTickPoseAndRefreshBones. The knife swings on the host, and AI
--     traces meet the client's real pose.
-- No object is kept: each comes from the hook or from this tick's controllers.
--
-- 3. Zombies hit a client from stale hands (work\audit\npc_bosses.md).
--    BP_MasterZombie CharacterMesh0 is OnlyTickMontagesWhenNotRendered: unseen
--    by the host, an attack montage (AttackPlayer -> PlayAttackMontage @611
--    PlayAnimMontage) still advances and its notifies start the AttackTrace /
--    LeftArmTrace / RightArmTrace / BiteTrace timers, but the bones are not
--    refreshed: the 40 cm sphere traces at the 'Hand_L' / arm / 'Mouth'
--    sockets run from the pose the host last rendered, so they miss or hit
--    wrongly. Fix, like the boss's in sdc_npc: PlayAttackMontage's post-hook
--    gives a zombie that attacks within 8 m of a remote player
--    AlwaysTickPoseAndRefreshBones (again on each attack: the AI optimizer may
--    change mesh settings). Its own value comes back after 10 s without an
--    attack, beyond 30 m from every remote player, or dead. Only strings are
--    kept: the revert finds the zombie in one engine actor query every 3 s,
--    run only while some zombie is switched (matched by address, then name).

local log = require("sdc_log")
local ue = require("sdc_ue")
local ctx = require("sdc_ctx")

local M = { stats = { animals = 0, pawns = 0, zombies = 0, zombies_back = 0 } }
local core

local clock = os.clock
local addr = ctx.addr

local ZOMBIE_DEFAULT = 2           -- OnlyTickMontagesWhenNotRendered (BP_MasterZombie CharacterMesh0)
local ZOMBIE_NEAR_CM = 800         -- an attack this close to a remote player
local ZOMBIE_FAR_CM = 3000         -- back to its own value beyond this from every remote player
local ZOMBIE_IDLE_S = 10           -- ... or this long after its last attack
local ZOMBIE_PASS_S = 3

local zticking = {}                -- host: [zombie address] = { key = full name, was = value, last = clock }
local zpass = { last = -1000, broken = false }
local ATTACKERS = {
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
    "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
}
local BB_LIB = "/Script/AIModule.Default__AIBlueprintHelperLibrary"

-- "<pawn> (client <pc>)" / "<pawn> (host)" / "<actor>", for log lines
local function who(actor)
    if not ue.valid(actor) then return "nobody" end
    local c = ue.prop(actor, "Controller")
    if core.is_remote_pc(c) then return string.format("%s (client %s)", ue.short(actor), ue.short(c)) end
    if ue.valid(c) and ue.name(c) == ue.name(ue.local_pc()) then return ue.short(actor) .. " (host)" end
    return ue.short(actor)
end

-- the animal's blackboard AttackTarget (log only)
local function target_of(a)
    local lib = ue.find_object(BB_LIB)
    if not lib then return nil end
    local bb = ue.try(function() return lib:GetBlackboard(a) end)
    if not ue.valid(bb) then return nil end
    local t = ue.try(function() return bb:GetValueAsObject(FName("AttackTarget")) end)
    if ue.valid(t) then return t end
    return nil
end

-- <Wolf / Bear>.AttackPlayer, post (host): the montage it starts must play
-- unseen.
local function on_attack(c)
    local a = c:get()
    if not ue.valid(a) or ue.prop(a, "IsDead?") == true then return end
    local was = core.full_pose(a, "?")
    if was == nil then return end
    M.stats.animals = M.stats.animals + 1
    if core.first("offscreen.animal", 5) then
        log.info("ai: offscreen: %s attacks %s: its pose ticks on the host now, seen or not (was %s)",
            ue.short(a), who(target_of(a)), tostring(was))
    end
end

-- The remote player nearest to `loc` within `range`: viewer, distance (cm).
local function nearest_viewer(loc, range)
    local best, bd = nil, nil
    for _, v in ipairs(core.viewers_near(loc, range)) do
        local dx, dy, dz = v.X - loc.X, v.Y - loc.Y, v.Z - loc.Z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if not bd or d < bd then best, bd = v, d end
    end
    return best, bd
end

-- BP_MasterZombie.PlayAttackMontage, post (host): the montage it just started
-- must move the hands its traces start from.
local function on_zombie_attack(c)
    if not core.host.active then return end
    local z = c:get()
    if not ue.valid(z) or ue.prop(z, "IsDead?") == true then return end
    local a = addr(z)
    local mesh = ue.prop(z, "Mesh")
    if not a or not ue.valid(mesh) then return end
    local key = ue.name(z)
    local rec = zticking[a]
    if rec and rec.key == key then
        rec.last = clock()
        if ue.prop(mesh, core.TICK_PROP) ~= core.ALWAYS_TICK then ue.set_prop(mesh, core.TICK_PROP, core.ALWAYS_TICK) end
        return
    end
    local loc = ue.location(z)
    if not loc then return end
    local v, d = nearest_viewer(loc, ZOMBIE_NEAR_CM)
    if not v then return end
    local was = ue.prop(mesh, core.TICK_PROP)
    if was == core.ALWAYS_TICK or not ue.set_prop(mesh, core.TICK_PROP, core.ALWAYS_TICK) then return end   -- not ours to revert
    zticking[a] = { key = key, was = type(was) == "number" and was or ZOMBIE_DEFAULT, last = clock() }
    M.stats.zombies = M.stats.zombies + 1
    if core.first("offscreen.zombie", 5) then
        log.info("ai: offscreen: %s attacks near %s (%.1f m): its pose and bones tick on the host now, seen or not (was %s)",
            ue.short(z), ue.short(v.pc), d / 100, tostring(was))
    end
end

-- Host, every 3 s while a zombie is switched: give it its own value back.
local function zombie_pass(now)
    if next(zticking) == nil or zpass.broken or now - zpass.last < ZOMBIE_PASS_S then return end
    zpass.last = now
    -- the engine's actor iterator: live actors of this world only
    local out, err = ue.actors_of(core.ZOMBIE_CLASS)
    if out == false then
        zpass.broken = true
        zticking = {}
        log.warn("ai: offscreen: GetAllActorsOfClass failed (%s); attacking zombies keep ticking", tostring(err))
        return
    end
    if not out then return end
    local live = {}
    for i = 1, #out do
        local z = ue.elem(out[i])
        local a = ue.valid(z) and addr(z) or nil
        local rec = a and zticking[a]
        if rec and ue.name(z) == rec.key then
            live[a] = true
            local why
            local loc = ue.location(z)
            if ue.prop(z, "IsDead?") == true then
                why = "dead"
            elseif now - rec.last > ZOMBIE_IDLE_S then
                why = "no attack for 10 s"
            elseif not loc or not nearest_viewer(loc, ZOMBIE_FAR_CM) then
                why = "no client within 30 m"
            end
            if why then
                local mesh = ue.prop(z, "Mesh")
                if ue.valid(mesh) and ue.prop(mesh, core.TICK_PROP) == core.ALWAYS_TICK then
                    ue.set_prop(mesh, core.TICK_PROP, rec.was)
                end
                zticking[a] = nil
                M.stats.zombies_back = M.stats.zombies_back + 1
                if core.first("offscreen.zombie_back", 5) then
                    log.info("ai: offscreen: %s back to its own pose ticking %s (%s)", ue.short(z), tostring(rec.was), why)
                end
            end
        end
    end
    -- gone from the world (destroyed, out of the level): nothing to give back
    for a in pairs(zticking) do
        if not live[a] then zticking[a] = nil end
    end
end

function M.init(c)
    core = c
    for _, path in ipairs(ATTACKERS) do
        local short = path:match("%.([%w_]+)$")
        core.hook({ path = path .. ":AttackPlayer", kind = "bp", role = "host", feature = "offscreen",
                    name = "offscreen." .. short, fn = on_attack })
    end
    core.hook({ path = core.ZM .. "PlayAttackMontage", kind = "bp", role = "host", feature = "offscreen",
                name = "offscreen.zombie", fn = on_zombie_attack })
end

-- Each remote player's character (tag Player; not a vehicle it drives): its
-- pose ticks on the host, seen or not. Switched zombies get their value back
-- (also after the last client left: no viewer is near then).
function M.host_tick(now)
    zombie_pass(now or clock())
    if not core.host.active then return end
    for _, pc in ipairs(core.S.remote_pcs or {}) do
        local pawn = ue.pawn_of(pc)
        local was = pawn and core.has_tag(pawn, "Player") and core.full_pose(pawn, "?")
        if was then
            M.stats.pawns = M.stats.pawns + 1
            if core.first("offscreen.pawn", 5) then
                log.info("ai: offscreen: %s of %s: its pose ticks on the host now, seen or not (was %s)",
                    ue.short(pawn), ue.short(pc), tostring(was))
            end
        end
    end
end

-- World / role change: the zombies of the old world are gone (no object touched).
function M.reset()
    zticking = {}
    zpass = { last = -1000, broken = false }
end

function M.status_line()
    local s = M.stats
    local n = 0
    for _ in pairs(zticking) do n = n + 1 end
    return string.format("ai: offscreen animals set=%d pawns set=%d zombies set=%d back=%d now=%d", s.animals, s.pawns,
        s.zombies, s.zombies_back, n)
end

return M
