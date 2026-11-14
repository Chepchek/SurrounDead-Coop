-- SDCoop: zombie bosses and human NPCs in co-op (audit: work\audit\npc_bosses.md).
--
-- Already handled elsewhere (not repeated here):
--   sdc_ai_kills    a boss / bandit / soldier / scavenger / trader killed by a
--                   client: its kill counter, XP, skill point and popup
--   sdc_ai_attacks  the boss's attack and throw montages on the clients' copies
--   sdc_ai_hud      the boss's health values (DamageComponent) on the clients
--   sdc_ai_corpses  the boss's corpse stays on the clients, lootable
--   sdc_dialogue    traders / quest givers talk and trade with the asking player
--   the engine      bandits, Coyote soldiers, scavengers and wandering traders
--                   are Smart AI characters: BP_SmartAIComponent replicates and
--                   drives everything through multicasts (Multicast Play
--                   Montage / Sound / Range Attack Partical / Projectile Spawn
--                   / Start Aim Offset / AI Dead / Set Collision Profile) and
--                   replicated Health / Dead / AI Current Behaviour; their
--                   weapons (BP_AIWeapon_*) replicate with their own effect
--                   multicasts. sdc_sync makes the runtime-spawned ones replicate.
--
-- What this module fixes (each part has its own config key):
--
-- npc_offscreen (host). How far a skeletal mesh animates depends on what the
--   machine renders; on the host that is the HOST's view. BP_ZombieBoss and
--   its types (not the horde bosses) use CharacterMesh0 OnlyTickPoseWhenRendered.
--   A boss the host does not render never advances a montage on the host:
--   MeleeAttack (@11396) plays Anim_Zombie_attack1/2, whose AnimNotify_BeginEvent
--   RightArmTrace / LeftArmTrace is the hit -> never fires: the boss never hurts
--   a client fighting it while the host looks elsewhere (session 14:39-14:41:
--   host 1.2 km away, the client hit the boss 70 times and its health only
--   rose; the host re-sent the attack every 0.3 s because the montage stayed at
--   position 0). RangedAttack (@11197) -> Delay -> slam montage, SetMovementMode
--   (None) (@2685); its 'Throw' notify (@2846, the rock) and OnCompleted
--   (@2805 SetMovementMode(Walking)) never come: no rock, and the boss stands
--   frozen until the host looks at it. Fix: the MeleeAttack / RangedAttack
--   post-hooks set the boss's mesh to AlwaysTickPoseAndRefreshBones (the horde
--   bosses' own setting; sdc_ai_offscreen does the same for wolves / bears),
--   again on every attack because the AI optimizer may change mesh settings.
--   Human NPCs (BP_MasterAICharacter: same mesh option; melee traces from the
--   hand sockets / weapon trace points, shots from the weapon's RangeStartPoint)
--   within 60 m of a remote player get the same once a second and their own
--   value back beyond 90 m.
-- npc_boss_fx. The boss's throw spawns BP_ZombieBossRock (not replicated, no
--   collision: only a visual) on the host only; the client saw nothing fly.
--   BP_ZombieBossRock.Launch's post-hook (host) sends NPCROCK(origin, target);
--   the client spawns the rock the boss's way (deferred spawn, Launch(Origin,
--   Target): the same BlueprintSuggestProjectileVelocity trajectory) with an
--   8 s life. The growls at an attack's start (@11532) and at the throw
--   (@2953) and the death roar (@3549) are PlaySoundAtLocation on the host
--   only: sent as SND (sdc_sync plays it) to the clients near the boss.
-- npc_effects. SetBurning(true) of a boss or human NPC adds the fire particle
--   component on the host only (@3962 / @1350); clients never saw it burn.
--   The SetBurning / StopBurning post-hooks (host) send NPCFIRE; the client
--   calls the copy's own SetBurning(true, 0, None) / StopBurning(): with Dmg 0
--   the copy's Event_Fire timer applies nothing (ApplyDamage ignores 0 damage).
--   The blood splatter on a hit (human: ReceiveAnyDamage -> Event_BloodSplatter
--   @966; boss: StandardDamage -> DamageComponent.Event_BloodSplatterFX
--   @6821) also runs on the host only: NPCBLOOD, the client calls the same event.
--   The boss's hit comes from its own StandardDamage bound event (@6953 ->
--   @6821, every hit); until 0.7.3 the hook was DamageComponent.
--   Event_BloodSplatterFX, which runs on every hit of every zombie as well.
-- npc_health. BP_SmartAIComponent.MaxHealth is not replicated. Each machine
--   computes it in BeginPlay (AI_Health -> HealthMultiplier ->
--   ScalingHealthMultiplier: a random factor, player 0's level and days
--   survived, the local Difficulty.* CVars) and writes Health locally too, so a
--   client's health bar (AIHealthBarInfo: UpdateHealth(Health, MaxHealth))
--   showed the host's Health over its own maximum (stuck full or jumping).
--   The host sends MaxHealth and Health of the human NPCs near each client
--   (NPCSET, once 1.5 s after the NPC came within 145 m, again every 30 s).
-- npc_looks. Human NPCs roll their look in BeginPlay on every machine
--   (SetMeshAndMaterial: body mesh, hair + material, beard + material,
--   backpack + its transform; soldiers: body material, headwear, mask): a
--   client saw other clothes. NPCSET carries the host's look; the client
--   applies it with the functions SetMeshAndMaterial uses (SetSkinnedAssetAndUpdate,
--   SetStaticMesh, SetMaterial, the relative transform), with assets already
--   in memory only (never a load in the hook; a part whose asset is not there
--   waits for the host's next NPCSET).
--   Also the settlements' civilians (BP_RandomCivilian: body, hair, beard,
--   backpack, and the name on their name plate, SetName @515 / @782: a random
--   first name and surname per machine) and the pet dog (BP_AnimalDog
--   SetMeshAndMaterial: model and material), every FRIENDLY_PASS_S (GetAllActorsOfClass,
--   not FindAllOf); their name goes as the host shows it (its language).
--   Not synced: petting the dog (the petting player's own montage and the
--   dog's, OnExecuteInteract on that machine only).
-- npc_marker (client). The enemy marker (MarkEnemy key) is local to the
--   marking machine; the AI's Event_Marker timer (1 s) keeps it while
--   GetPlayerController(0).LineOfSightTo(GetAIController(self)) and removes
--   it 60 s after the last sight (RetriggerableDelay 60: @3874 boss, @29294
--   zombie, bandits / traders / soldiers / scavengers, wolf / bear / deer /
--   rabbit the same). A client's copy has no AI controller: the line of sight
--   was never true, the marker never went (until the AI died). Post-hook
--   Event_Marker on the copies: the line of sight to the copy itself; 60 s
--   after the last sight the game's own removal (@581: the marker component
--   destroyed, CanAddMarker? = true where the class has it, the Event_Marker
--   timer cleared and its handle invalidated - a zombie's CanAddMarkerToAI?
--   is "no valid MarkerTimer").
--
-- Object identity host -> client as sdc_ai does it: the payload (ClientMessage)
-- and right after it the NPC as the parameter of PlayerController.
-- ClientRepObjRef (reliable, same channel, in order); the client's engine maps
-- it to ITS copy, or nil when it has none. The client checks the class name.
-- No NPC wrapper is kept beyond the call that got it; kept state is strings
-- and numbers. Every hook callback returns nothing and never throws.
-- Hooks: this module's own (installed from the tick, retried with a growing
-- wait while their Blueprint class is not loaded), and the ones sdc_ai's
-- features hook too (the boss's MeleeAttack / DeathEvent, the humans'
-- StopBurning), which sdc_ai installs once for both (shared_hook).
-- The host's offscreen ticking of human NPCs is given back when the last
-- client leaves.
--
-- Messages host -> client:
--   NPCSET|<class>|<max health>|<health>|<look>[|<name>]   + ClientRepObjRef(npc)
--   NPCFIRE|<class>|1/0                            + ClientRepObjRef(npc)
--   NPCBLOOD|<class>                               + ClientRepObjRef(npc)
--   NPCROCK|ox|oy|oz|tx|ty|tz
--   SND|<sound>|x|y|z|volume|pitch                 (handler in sdc_sync)

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local cfg = require("sdc_config")
local ai = require("sdc_ai")   -- shared helpers (ai.core) and the hooks it installs for both (M.hook_external)
local core = ai.core

local M = {
    stats = { boss_tick = 0, human_tick = 0, human_back = 0, rocks_sent = 0, rocks_spawned = 0, rocks_failed = 0,
              sounds = 0, fire_sent = 0, fire_applied = 0, blood_sent = 0, blood_applied = 0,
              set_sent = 0, set_applied = 0, looks = 0, look_parts = 0, look_failed = 0, look_later = 0,
              objref_got = 0, objref_nil = 0, objref_stale = 0, objref_other = 0, objref_failed = 0,
              friendly_set = 0, names = 0, marks_seen = 0, marks_removed = 0, marks_failed = 0, slow_objref = 0 },
}

local S = nil   -- sdc_session.state
local clock = os.clock

-- ---------------------------------------------------------------------------
-- Settings (defaults apply until the keys are in sdc_config's SCHEMA)
-- ---------------------------------------------------------------------------

local DEFAULTS = { npc_offscreen = true, npc_boss_fx = true, npc_effects = true, npc_health = true, npc_looks = true,
                   npc_marker = true }

local function opt(key)
    local v = cfg.get(key)
    if v == nil then v = DEFAULTS[key] end
    return v == true
end

-- ---------------------------------------------------------------------------
-- Game assets
-- ---------------------------------------------------------------------------

local BOSS = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C"
local ROCK = "/Game/AI/Zombies/Boss/BP_ZombieBossRock.BP_ZombieBossRock_C"
local HUMAN = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C"
-- the boss's DamageComponent.StandardDamage bound event (@6953 -> @6821 Event_BloodSplatterFX)
local BOSS_HIT = "BndEvt__DamageTester_DamageComponent_K2Node_ComponentBoundEvent_0_StandardDamage__DelegateSignature"
local HUMANS = {   -- each defines its own SetBurning / StopBurning
    "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C",
    "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C",
    "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C",
    "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C",
}
local HUMAN_CLASS = "BP_MasterAICharacter_C"
-- friendly NPCs whose look (and the civilian's name) is rolled per machine
local CIVILIAN = "/Game/AI/SafeZoneAndCivilians/RandomCivilian/BP_RandomCivilian.BP_RandomCivilian_C"
local DOG = "/Game/AI/Animals/Dog/BP_AnimalDog.BP_AnimalDog_C"
-- every class with its own Event_Marker (the enemy marker's 1 s timer)
local MARKED = {
    "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C", BOSS,
    HUMANS[1], HUMANS[2], HUMANS[3], HUMANS[4],
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C", "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
    "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C", "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C",
}
local OBJREF_FN = "/Script/Engine.PlayerController:ClientRepObjRef"
-- SND paths (sdc_sync adds /Game/): BP_ZombieBoss @2953 / @11532, @3549
local GROWL = "Audio/Zombie/ZombieGrowlShort.ZombieGrowlShort"
local ROAR = "Audio/Zombie/ZombieDeathShort.ZombieDeathShort"
-- what SetMeshAndMaterial changes (bandit, trader, scavenger, soldier, civilian)
local LOOK_PARTS = { "Mesh", "HairMesh", "BeardMesh", "BackpackMesh", "HeadwearMesh", "MaskMesh" }

local ALWAYS = core.ALWAYS_TICK        -- EVisibilityBasedAnimTickOption::AlwaysTickPoseAndRefreshBones
local TICK_PROP = core.TICK_PROP

local PASS_S = 1.0          -- host pass over the human NPCs
local TICK_NEAR = 6000      -- cm: a human NPC this close to a remote player animates unseen on the host
local TICK_FAR = 9000       -- cm: ... and gets its own setting back beyond this
local SET_RANGE = 14500     -- cm: NPCSET to clients this close (their copy exists: net range 150 m)
local GONE_RANGE = 15200    -- cm: beyond this the client's copy is gone; send again when it comes back
local SET_DELAY_S = 1.5     -- the NPC near that client for this long first (its actor channel is open)
local RESEND_S = 30           -- an NPC near a client is compared with what that client was told this often
local WARM_S = 120            -- the first minutes of an NPC for a viewer: every RESEND_S (its look may wait for an asset there)
local VERIFY_S = 180          -- ... and told again (the full NPCSET) only when it differs, or this often
local SET_PER_PASS = 10     -- NPCSET per client and pass
local MAX_NPCS = 96         -- human NPCs looked at per pass
local FX_RANGE = 16000      -- cm: rock / sounds / fire to clients this close
local BLOOD_RANGE = 10000
local BLOOD_GAP_S = 0.25    -- per NPC
local GROWL_GAP_S = 1.2     -- per boss (the game's own attack Delay is 1.35-1.75 s)
local FRESH_S = 0.2         -- a montage this call started
local OBJ_TTL = 2.0
local ROCK_LIFE_S = 8.0
local ROCKS_PER_S = 4
local BP_RETRY_S, BP_RETRY_MAX_S = 2, 30   -- a hook whose Blueprint class is not loaded yet: retry, doubling
local FRIENDLY_PASS_S = 3   -- host: civilians / dogs looked at this often (their look is sent once, then every 30 s)
local MAX_FRIENDLY = 48     -- ... at most this many per pass
local MARK_KEEP_S = 60      -- the marker goes this long after the last sight (the game's RetriggerableDelay)
local MARKS_PRUNE_S = 60    -- client: marks of copies gone (no timer any more) forgotten after 10 min

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

local get = ue.param
local vec_of = ue.vec

local function d2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function num(s)
    local n = tonumber(s)
    if n and n == n and n > -1e9 and n < 1e9 then return n end
    return nil
end

local function short_path(p) return (p:gsub("^/Game/", "")) end
local function full_path(p)
    if p == "" or p:sub(1, 1) == "/" then return p end
    return "/Game/" .. p
end

-- true for the first `n` calls with this key (sdc_ai's counter; keys "npc.*")
local function first(key, n) return core.first("npc." .. key, n) end

-- Is `o` an instance of the Blueprint class at `path`? (sdc_ai's test, cached by class name)
local function is_boss(o) return ai.isa(o, BOSS) end

local function human_dead(npc)
    return ue.prop(ue.prop(npc, "BP_AIComponent"), "Dead") == true
end

-- ---------------------------------------------------------------------------
-- Hooks (declared once, installed from the tick when their role / feature
-- needs them; Blueprint classes load late, so those are retried)
-- ---------------------------------------------------------------------------

local HOOKS = {}   -- { path, kind = "bp" | "pre", role, keys = { config keys }, fn, installed, next_try, wait, logged }
local SHARED = {}  -- handles of the hooks sdc_ai installs for this module too (shared_hook below)

local function label_of(path) return path:match("([^%.]+:[^:]+)$") or path end

local function hook(path, kind, role, keys, fn)
    HOOKS[#HOOKS + 1] = { path = path, kind = kind, role = role, keys = keys, fn = fn,
                          installed = false, next_try = 0, label = label_of(path) }
end

local function keys_any(keys)
    for _, k in ipairs(keys) do
        if opt(k) then return true end
    end
    return false
end

local function wanted(h) return keys_any(h.keys) end

local function guarded(h)
    return function(...)
        if not S or S.role ~= h.role or not keys_any(h.keys) then return end
        local ok, err = pcall(h.fn, ...)
        if not ok then log.err_throttled("npc." .. h.label, "npc: %s: %s", h.label, tostring(err)) end
    end
end

local function install_hooks(now, role)
    for _, h in ipairs(HOOKS) do
        if not h.installed and h.role == role and now >= h.next_try and wanted(h) then
            local g = guarded(h)
            local ok, err
            if h.kind == "pre" then
                ok, err = ue.hook_native(h.path, "npc." .. tostring(h.label), g)
            else
                ok, err = pcall(RegisterHook, h.path, g)
            end
            if ok then
                h.installed = true
                log.info("npc: hook %s ok", h.label)
            elseif h.kind == "pre" then
                h.next_try = now + 60
                log.warn("npc: hook %s FAILED: %s", h.label, tostring(err))
            else
                -- the Blueprint class is not loaded yet (it loads with its first
                -- actor): retry, less often each time
                ue.backoff(h, now, BP_RETRY_S, BP_RETRY_MAX_S)
                if not h.logged then
                    h.logged = true
                    log.debug("npc: hook %s not ready yet (%s)", h.label, tostring(err))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local host = {
    active = false,
    viewers = {},   -- this pass: { pc, key, X, Y, Z } per remote player with a pawn
    last_pass = -1000,
    ticking = {},   -- [npc full name] = its own tick option (we changed it)
    sent = {},      -- [npc full name] = { [pc full name] = { first = t, at = t|nil } }
    looks = {},     -- [npc full name] = look string
    growl = {},     -- [boss full name] = clock
    roared = {},    -- [boss full name] = clock
    blood = {},     -- [npc full name] = clock
    burning = {},   -- [npc full name] = true (NPCFIRE 1 sent)
    friendly = {},  -- [civilian / dog full name] = true: seen in the last friendly pass (its sent / looks entries kept)
    last_friendly = -1000,
}

local function viewers_near(loc, range)
    local out = {}
    if not loc then return out end
    local r2 = range * range
    for _, v in ipairs(host.viewers) do
        if d2(v, loc) <= r2 and ue.valid(v.pc) then out[#out + 1] = v end
    end
    return out
end

-- payload, then the object it is about
local function send_obj(pc, obj, kind, ...)
    if not ue.valid(obj) then return false end
    if not net.send_to(pc, kind, ...) then return false end
    local ok, err = pcall(function() pc:ClientRepObjRef(obj) end)
    if not ok then
        M.stats.objref_failed = M.stats.objref_failed + 1
        log.err_throttled("npc.objref", "npc: ClientRepObjRef failed: %s", tostring(err))
    end
    return ok
end

-- A growl / roar goes only as far as it carries: ZombieGrowlShort and
-- ZombieDeathShort have the FootSteps attenuation (100 + 3000 cm = 31 m, their
-- data), read from the asset when it is in memory; + 5 m for the movement.
-- (Before: FX_RANGE 160 m; the client then played it with that attenuation, so
-- past 31 m only the message was wasted.)
local SOUND_RANGE = 3100
local SOUND_MARGIN = 500
local sound_skips = 0
local function send_sound(path, loc, range)
    if not loc then return end
    local snd = package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
    local r = math.min(range or FX_RANGE, snd.range_of_path("/Game/" .. path, SOUND_RANGE) + SOUND_MARGIN)
    local near = viewers_near(loc, r)
    if #near < #host.viewers then
        sound_skips = sound_skips + 1
        if sound_skips <= 20 then
            log.debug("npc: %s not sent to %d client(s) beyond %.0f m", path:match("([^%.]+)$") or path,
                #host.viewers - #near, r / 100)
        end
    end
    for _, v in ipairs(near) do
        if net.send_to(v.pc, "SND", path, string.format("%.0f", loc.X), string.format("%.0f", loc.Y),
                string.format("%.0f", loc.Z), "1.00", "1.00") then
            M.stats.sounds = M.stats.sounds + 1
        end
    end
end

-- The mesh of `actor` -> full ticking. Returns its previous value when this
-- changed it (3, OnlyTickPoseWhenRendered, when unreadable), nil when it was
-- already set (or there is no mesh).
local function full_pose(actor) return core.full_pose(actor, 3) end

local function keep_ticking(boss, why)
    if not opt("npc_offscreen") or ue.prop(boss, "IsDead?") == true then return end
    local was = full_pose(boss)
    if was == nil then return end
    M.stats.boss_tick = M.stats.boss_tick + 1
    if first("tick.boss", 5) then
        log.info("npc: offscreen: %s %s: its pose ticks on the host now, seen or not (was %s)", ue.short(boss), why,
            tostring(was))
    end
end


-- BP_ZombieBoss.MeleeAttack, post (host)
local function on_boss_melee(c)
    if not host.active then return end
    local boss = c:get()
    if not ue.valid(boss) then return end
    keep_ticking(boss, "attacks")
    -- a growl only with a montage this call started (position <= FRESH_S)
    if not opt("npc_boss_fx") or #host.viewers == 0 or not core.fresh_montage(boss, FRESH_S) then return end
    local key = ue.name(boss)
    local now = clock()
    if host.growl[key] and now - host.growl[key] < GROWL_GAP_S then return end
    host.growl[key] = now
    send_sound(GROWL, ue.location(boss), FX_RANGE)   -- @11532, played before the montage
end

-- BP_ZombieBoss.RangedAttack(Target), post (host): the throw starts after a delay
local function on_boss_ranged(c)
    if not host.active then return end
    local boss = c:get()
    if ue.valid(boss) then keep_ticking(boss, "throws") end
end

-- BP_ZombieBoss.DeathEvent(Player), post (host): the roar (@3428 DoOnce -> @3549)
local function on_boss_death(c)
    if not host.active or not opt("npc_boss_fx") then return end
    local boss = c:get()
    if not ue.valid(boss) then return end
    local key = ue.name(boss)
    if host.roared[key] then return end
    host.roared[key] = clock()
    send_sound(ROAR, ue.location(boss), FX_RANGE)
    if first("roar", 2) then log.info("npc: boss_fx: %s died: death roar sent to the clients near it", ue.short(boss)) end
end

-- BP_ZombieBossRock.Launch(Origin, Target), post (host): the boss threw it
local function on_rock_launch(_, origin_p, target_p)
    if not host.active or not opt("npc_boss_fx") then return end
    local o, t = vec_of(get(origin_p)), vec_of(get(target_p))
    if not o or not t then return end
    local near = viewers_near(o, FX_RANGE)
    if #near == 0 then return end
    local f = function(v) return string.format("%.0f", v) end
    for _, v in ipairs(near) do
        if net.send_to(v.pc, "NPCROCK", f(o.X), f(o.Y), f(o.Z), f(t.X), f(t.Y), f(t.Z)) then
            M.stats.rocks_sent = M.stats.rocks_sent + 1
        end
    end
    send_sound(GROWL, o, FX_RANGE)   -- @2953, at the 'Throw' notify with the rock
    if first("rock", 3) then
        log.info("npc: boss_fx: a boss threw a rock %.0f,%.0f,%.0f -> %.0f,%.0f,%.0f: sent to %d client(s)",
            o.X, o.Y, o.Z, t.X, t.Y, t.Z, #near)
    end
end

-- <NPC>.SetBurning(Burning?, Dmg, Actor), post (host)
local function on_set_burning(c, burning_p)
    if not host.active or #host.viewers == 0 then return end
    local npc = c:get()
    if not ue.valid(npc) then return end
    local on = get(burning_p) == true
    local key = ue.name(npc)
    if not on and not host.burning[key] then return end
    host.burning[key] = on or nil
    local cls = ue.class_name(npc)
    for _, v in ipairs(viewers_near(ue.location(npc), FX_RANGE)) do
        if send_obj(v.pc, npc, "NPCFIRE", cls, on and "1" or "0") then M.stats.fire_sent = M.stats.fire_sent + 1 end
    end
    if first("fire", 3) then log.info("npc: effects: %s %s burning (sent)", ue.short(npc), on and "started" or "stopped") end
end

-- <NPC>.StopBurning, post (host). Humans' Death calls it too: only a fire we
-- told the clients about is put out.
local function on_stop_burning(c)
    if not host.active then return end
    local npc = c:get()
    if not ue.valid(npc) then return end
    local key = ue.name(npc)
    if not host.burning[key] then return end
    host.burning[key] = nil
    local cls = ue.class_name(npc)
    for _, v in ipairs(viewers_near(ue.location(npc), FX_RANGE)) do
        if send_obj(v.pc, npc, "NPCFIRE", cls, "0") then M.stats.fire_sent = M.stats.fire_sent + 1 end
    end
end

local function send_blood(npc)
    if #host.viewers == 0 or not ue.valid(npc) then return end
    local key = ue.name(npc)
    local now = clock()
    if host.blood[key] and now - host.blood[key] < BLOOD_GAP_S then return end
    host.blood[key] = now
    local cls = ue.class_name(npc)
    for _, v in ipairs(viewers_near(ue.location(npc), BLOOD_RANGE)) do
        if send_obj(v.pc, npc, "NPCBLOOD", cls) then M.stats.blood_sent = M.stats.blood_sent + 1 end
    end
end

-- BP_MasterAICharacter.Event_BloodSplatter, post (host): a human NPC was hit
local function on_human_blood(c)
    if not host.active then return end
    send_blood(c:get())
end

-- BP_ZombieBoss's StandardDamage bound event, post (host): the boss was hit
-- (its handler runs DamageComponent.Event_BloodSplatterFX on every hit).
local function on_boss_hit(c)
    if not host.active then return end
    send_blood(c:get())
end

-- -- the pass over the human NPCs (once a second) ----------------------------

local function build_viewers()
    local v = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        local p = ue.pawn_of(pc)
        local l = p and ue.location(p)
        if l then v[#v + 1] = { pc = pc, key = ue.name(pc), X = l.X, Y = l.Y, Z = l.Z, budget = SET_PER_PASS } end
    end
    return v
end

local function fmt_num(n, digits)
    if type(n) ~= "number" then return "0" end
    return string.format("%." .. tostring(digits) .. "f", n)
end

local function asset_path_of(comp)
    for _, pname in ipairs({ "SkeletalMeshAsset", "SkeletalMesh", "StaticMesh" }) do
        local a = ue.prop(comp, pname)
        if ue.valid(a) then return ue.path(a) end
    end
    local a = ue.try(function() return comp:GetSkinnedAsset() end)
    if ue.valid(a) then return ue.path(a) end
    return ""
end

local function material_path_of(comp)
    local m = ue.try(function() return comp:GetMaterial(0) end)
    if not ue.valid(m) then return "" end
    if ue.class_name(m):find("Dynamic", 1, true) then
        local parent = ue.prop(m, "Parent")
        if ue.valid(parent) then return ue.path(parent) end
        return ""
    end
    return ue.path(m)
end

local function is_skeletal(comp)
    return ue.class_name(comp):find("SkeletalMesh", 1, true) ~= nil
end

-- "<part>=<asset>,<material>[,lx,ly,lz,pitch,yaw,roll,sx,sy,sz];..." (paths
-- without /Game/; the transform for static parts only)
local function look_of(npc)
    local parts = {}
    for _, name in ipairs(LOOK_PARTS) do
        local comp = ue.prop(npc, name)
        if ue.valid(comp) then
            local a, m = asset_path_of(comp), material_path_of(comp)
            if a:sub(1, 6) ~= "/Game/" then a = "" end
            if m:sub(1, 6) ~= "/Game/" then m = "" end
            if a ~= "" or m ~= "" then
                local s = name .. "=" .. short_path(a) .. "," .. short_path(m)
                if not is_skeletal(comp) then
                    local l = vec_of(ue.prop(comp, "RelativeLocation")) or { X = 0, Y = 0, Z = 0 }
                    local r = ue.prop(comp, "RelativeRotation")
                    local p, y, ro = ue.try(function() return r.Pitch end), ue.try(function() return r.Yaw end),
                        ue.try(function() return r.Roll end)
                    local sc = vec_of(ue.prop(comp, "RelativeScale3D")) or { X = 1, Y = 1, Z = 1 }
                    s = s .. "," .. table.concat({ fmt_num(l.X, 1), fmt_num(l.Y, 1), fmt_num(l.Z, 1), fmt_num(p, 1),
                        fmt_num(y, 1), fmt_num(ro, 1), fmt_num(sc.X, 3), fmt_num(sc.Y, 3), fmt_num(sc.Z, 3) }, ",")
                end
                parts[#parts + 1] = s
            end
        end
    end
    return table.concat(parts, ";")
end

-- The text on a civilian's name plate (NameWidget -> BP_InteractWidgetCivilian
-- .Txt, set by its SetName in BeginPlay), or nil.
local function name_plate(npc)
    local wc = ue.prop(npc, "NameWidget")
    if not ue.valid(wc) then return nil end
    local w = ue.try(function() return wc:GetUserWidgetObject() end)
    local txt = ue.valid(w) and ue.prop(w, "Txt") or nil
    if not ue.valid(txt) then return nil end
    return txt
end

local function civilian_name(npc)
    local txt = name_plate(npc)
    if not txt then return "" end
    local s = ue.str(ue.try(function() return txt:GetText() end))
    return (s:gsub("[|;%c]", " "))
end

-- st: the record of this NPC for this viewer (its last NPCSET: sig, at)
local function send_set(v, npc, key, st, now)
    local comp = ue.prop(npc, "BP_AIComponent")
    local max, hp = "", ""
    if opt("npc_health") and ue.valid(comp) then
        local mx, h = ue.prop(comp, "MaxHealth"), ue.prop(comp, "Health")
        if type(mx) == "number" and mx > 0 then max = tostring(math.floor(mx)) end
        if type(h) == "number" then hp = tostring(math.floor(h)) end
    end
    local look = ""
    if opt("npc_looks") then
        look = host.looks[key]
        if not look or look == "" then
            look = look_of(npc)
            host.looks[key] = look
        end
    end
    local name = ""
    if opt("npc_looks") and host.friendly[key] and ue.has_prop(npc, "NameWidget") then name = civilian_name(npc) end
    if max == "" and look == "" and name == "" then return false end
    -- the same thing again is not told before the verify
    local sig = max .. "|" .. hp .. "|" .. look .. "|" .. name
    if st and st.sig == sig and st.at and now - st.at < VERIFY_S and now - (st.first or 0) >= WARM_S then
        st.chk = now
        return "same"
    end
    local ok
    if name ~= "" then
        ok = send_obj(v.pc, npc, "NPCSET", ue.class_name(npc), max, hp, look, name)
    else
        ok = send_obj(v.pc, npc, "NPCSET", ue.class_name(npc), max, hp, look)
    end
    if not ok then return false end
    if st then st.sig = sig end
    M.stats.set_sent = M.stats.set_sent + 1
    if first("set", 3) then
        log.info("npc: set: %s -> %s: max health %s, health %s, look %d chars", ue.short(npc), ue.short(v.pc), max, hp,
            #look)
    end
    return true
end

-- NPCSET of one NPC to each viewer: 1.5 s after it came within SET_RANGE,
-- again every RESEND_S; forgotten for a viewer beyond GONE_RANGE.
local function set_for_viewers(npc, key, loc, now)
    local set2, gone2 = SET_RANGE * SET_RANGE, GONE_RANGE * GONE_RANGE
    local per = host.sent[key]
    for _, v in ipairs(host.viewers) do
        local d = d2(v, loc)
        local st = per and per[v.key]
        if d > gone2 then
            if st then per[v.key] = nil end
        elseif d <= set2 then
            if not per then
                per = {}
                host.sent[key] = per
            end
            if not st then
                per[v.key] = { first = now }
            elseif v.budget > 0 and ((not st.at and now - st.first >= SET_DELAY_S)
                    or (st.at and now - (st.chk or st.at) >= RESEND_S)) then
                v.budget = v.budget - 1
                local r = send_set(v, npc, key, st, now)
                if r == true then st.at, st.chk = now, now
                elseif r == "same" then st.chk = now; v.budget = v.budget + 1   -- nothing went out
                else st.at, st.chk = now - RESEND_S + 5, nil end
            end
        end
    end
end

-- Civilians and pet dogs (look, the civilian's name), every FRIENDLY_PASS_S:
-- the engine's actor list of their class (nil while the class is not loaded).
local function friendly_pass(now)
    host.last_friendly = now
    local seen, n = {}, 0
    for _, path in ipairs({ CIVILIAN, DOG }) do
        local out = ue.actors_of(path)
        if type(out) == "table" then
            for i = 1, #out do
                if n >= MAX_FRIENDLY then break end
                local a = ue.elem(out[i])
                local loc = ue.valid(a) and ue.location(a) or nil
                if loc then
                    n = n + 1
                    local key = ue.name(a)
                    seen[key] = true
                    host.friendly[key] = true
                    set_for_viewers(a, key, loc, now)
                end
            end
        end
    end
    for k in pairs(host.friendly) do
        if not seen[k] then
            host.friendly[k], host.sent[k], host.looks[k] = nil, nil, nil
        end
    end
end

local function host_pass(now)
    host.viewers = build_viewers()
    local seen = {}
    local tick_on = opt("npc_offscreen")
    local set_on = opt("npc_health") or opt("npc_looks")
    local near2, far2 = TICK_NEAR * TICK_NEAR, TICK_FAR * TICK_FAR
    for i, npc in ipairs(ue.find_all(HUMAN_CLASS)) do
        if i > MAX_NPCS then break end
        local loc = ue.valid(npc) and ue.location(npc) or nil
        if loc then
            local key = ue.name(npc)
            seen[key] = true
            local nearest = nil
            for _, v in ipairs(host.viewers) do
                local d = d2(v, loc)
                if not nearest or d < nearest then nearest = d end
            end
            -- offscreen animation
            local dead = human_dead(npc)
            if tick_on and not dead and nearest and nearest <= near2 then
                local was = full_pose(npc)
                if was ~= nil then
                    if host.ticking[key] == nil then host.ticking[key] = was end
                    M.stats.human_tick = M.stats.human_tick + 1
                    if first("tick.human", 5) then
                        log.info("npc: offscreen: %s is near a client: its pose ticks on the host now (was %s)",
                            ue.short(npc), tostring(was))
                    end
                end
            elseif host.ticking[key] ~= nil and (dead or not tick_on or not nearest or nearest > far2) then
                local mesh = ue.prop(npc, "Mesh")
                if ue.valid(mesh) and ue.prop(mesh, TICK_PROP) == ALWAYS then
                    ue.set_prop(mesh, TICK_PROP, host.ticking[key])
                    M.stats.human_back = M.stats.human_back + 1
                end
                host.ticking[key] = nil
            end
            -- health / look per client
            if set_on then set_for_viewers(npc, key, loc, now) end
        end
    end
    if opt("npc_looks") and now - host.last_friendly >= FRIENDLY_PASS_S then friendly_pass(now) end
    -- NPCs that are gone: their strings go (civilians / dogs: their own pass)
    for _, t in ipairs({ host.ticking, host.sent, host.looks }) do
        for k in pairs(t) do
            if not seen[k] and not host.friendly[k] then t[k] = nil end
        end
    end
    for _, t in ipairs({ host.growl, host.roared, host.blood }) do
        for k, at in pairs(t) do
            if now - at > 600 then t[k] = nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local client = {
    pending = nil,     -- { kind, cls, data, t }: payload waiting for its object
    applied = {},      -- [copy full name] = look string applied completely
    applied_n = 0,
    bad = {},          -- [asset path] = true: not an asset of the kind the part needs
    rocks = { t = 0, n = 0 },
    marks = {},        -- [copy full name] = clock of the last sight of its marker's AI (npc_marker)
    marks_pruned = 0,
}

local function expect(kind, cls, data)
    client.pending = { kind = kind, cls = cls or "", data = data, t = clock() }
end

-- An asset by path (/Game/ only) whose class contains `class_part`, from
-- memory only: this runs in the ClientRepObjRef hook, where a synchronous
-- load could wait for the world's streaming and freeze the client. nil and
-- `true` when it is not in memory (yet): the look stays incomplete, and the
-- host's next NPCSET (every RESEND_S while the client is near) tries again.
-- (The NPC classes refer to their look assets directly, so they are normally
-- in memory with the class.)
local function asset(path, class_part)
    if type(path) ~= "string" or path:sub(1, 6) ~= "/Game/" or client.bad[path] then return nil end
    local a = ue.loaded_asset(path, "npc looks")
    if not a then return nil, true end
    local cn = ue.class_name(a)
    local good = cn:find(class_part, 1, true) ~= nil
    if class_part == "Material" then good = cn == "Material" or cn:find("MaterialInstance", 1, true) ~= nil end
    if not good then
        client.bad[path] = true
        return nil
    end
    return a
end

local function set_mesh(comp, a, skeletal)
    if skeletal then
        if pcall(function() comp:SetSkinnedAssetAndUpdate(a, true) end) then return true end
        if pcall(function() comp:SetSkeletalMeshAsset(a) end) then return true end
        return (pcall(function() comp:SetSkeletalMesh(a, true) end))
    end
    return (pcall(function() comp:SetStaticMesh(a) end))
end

local function differs(a, b, eps) return math.abs((a or 0) - (b or 0)) > eps end

-- One "<part>=..." entry onto the copy's component. Returns complete?
local function apply_part(npc, entry)
    local name, rest = entry:match("^([%w_]+)=(.*)$")
    if not name then return true end
    local known = false
    for _, p in ipairs(LOOK_PARTS) do if p == name then known = true end end
    if not known then return true end
    local comp = ue.prop(npc, name)
    if not ue.valid(comp) then return true end
    local f = {}
    for v in (rest .. ","):gmatch("([^,]*),") do f[#f + 1] = v end
    local skeletal = is_skeletal(comp)
    local complete = true
    local a_path, m_path = full_path(f[1] or ""), full_path(f[2] or "")
    if a_path ~= "" and asset_path_of(comp) ~= a_path then
        local a, later = asset(a_path, skeletal and "SkeletalMesh" or "StaticMesh")
        if a and set_mesh(comp, a, skeletal) then
            M.stats.look_parts = M.stats.look_parts + 1
        elseif later then
            complete = false
            M.stats.look_later = M.stats.look_later + 1
        else
            M.stats.look_failed = M.stats.look_failed + 1
        end
    end
    if m_path ~= "" and material_path_of(comp) ~= m_path then
        local m, later = asset(m_path, "Material")
        if m and pcall(function() comp:SetMaterial(0, m) end) then
            M.stats.look_parts = M.stats.look_parts + 1
        elseif later then
            complete = false
            M.stats.look_later = M.stats.look_later + 1
        else
            M.stats.look_failed = M.stats.look_failed + 1
        end
    end
    if not skeletal and #f >= 11 then
        local l = { X = num(f[3]), Y = num(f[4]), Z = num(f[5]) }
        local r = { Pitch = num(f[6]), Yaw = num(f[7]), Roll = num(f[8]) }
        local s = { X = num(f[9]), Y = num(f[10]), Z = num(f[11]) }
        if l.X and l.Y and l.Z and r.Pitch and r.Yaw and r.Roll then
            local cl = vec_of(ue.prop(comp, "RelativeLocation")) or { X = 0, Y = 0, Z = 0 }
            local cr = ue.prop(comp, "RelativeRotation")
            local cp, cy, cro = ue.try(function() return cr.Pitch end), ue.try(function() return cr.Yaw end),
                ue.try(function() return cr.Roll end)
            if differs(cl.X, l.X, 0.5) or differs(cl.Y, l.Y, 0.5) or differs(cl.Z, l.Z, 0.5)
                    or differs(cp, r.Pitch, 0.5) or differs(cy, r.Yaw, 0.5) or differs(cro, r.Roll, 0.5) then
                pcall(function() comp:K2_SetRelativeLocationAndRotation(l, r, false, {}, false) end)
            end
        end
        if s.X and s.Y and s.Z and s.X > 0 and s.Y > 0 and s.Z > 0 then
            local cs = vec_of(ue.prop(comp, "RelativeScale3D")) or { X = 1, Y = 1, Z = 1 }
            if differs(cs.X, s.X, 0.005) or differs(cs.Y, s.Y, 0.005) or differs(cs.Z, s.Z, 0.005) then
                pcall(function() comp:SetRelativeScale3D(s) end)
            end
        end
    end
    return complete
end

-- NPCSET onto the client's copy
local function apply_set(npc, d)
    local comp = ue.prop(npc, "BP_AIComponent")
    local max, hp = num(d.max), num(d.hp)
    if ue.valid(comp) and max and max > 0 then
        if ue.prop(comp, "MaxHealth") ~= math.floor(max) then ue.set_prop(comp, "MaxHealth", math.floor(max)) end
        if hp and ue.prop(comp, "Dead") ~= true and ue.prop(comp, "Health") ~= math.floor(hp) then
            ue.set_prop(comp, "Health", math.floor(hp))
        end
    end
    local look = d.look or ""
    if look ~= "" and opt("npc_looks") then
        local key = ue.name(npc)
        if client.applied[key] ~= look then
            local complete = true
            for entry in (look .. ";"):gmatch("([^;]*);") do
                if entry ~= "" and not apply_part(npc, entry) then complete = false end
            end
            if complete then
                client.applied_n = client.applied_n + 1
                if client.applied_n > 600 then client.applied, client.applied_n = {}, 1 end   -- copies come and go
                client.applied[key] = look
                M.stats.looks = M.stats.looks + 1
                if first("look.applied", 3) then log.info("npc: looks: %s now looks as on the host", ue.short(npc)) end
            end
        end
    end
    -- a civilian's name plate: the host's name (its own SetName rolled another)
    local name = d.name or ""
    if name ~= "" and opt("npc_looks") then
        local txt = name_plate(npc)
        local now_name = txt and ue.str(ue.try(function() return txt:GetText() end)) or nil
        if txt and now_name ~= name and pcall(function() txt:SetText(FText(name)) end) then
            M.stats.names = M.stats.names + 1
            if first("name.applied", 3) then log.info("npc: looks: %s: name plate as on the host", ue.short(npc)) end
        end
    end
    M.stats.set_applied = M.stats.set_applied + 1
    if first("set.applied", 3) then
        log.info("npc: set: %s: max health %s health %s (host)", ue.short(npc), tostring(d.max), tostring(d.hp))
    end
end

local function apply_fire(npc, d)
    local burning = ue.prop(npc, "Is Burning?") == true
    if d.on and not burning then
        -- Dmg 0: the copy's own Event_Fire timer then applies no damage
        if not pcall(function() npc:SetBurning(true, 0.0, nil) end) then return end
    elseif not d.on and burning then
        if not pcall(function() npc:StopBurning() end) then return end
    else
        return
    end
    M.stats.fire_applied = M.stats.fire_applied + 1
    if first("fire.applied", 3) then log.info("npc: effects: %s %s burning here", ue.short(npc), d.on and "started" or "stopped") end
end

local function apply_blood(npc)
    local ok
    if is_boss(npc) then
        local dc = ue.prop(npc, "DamageComponent")
        ok = ue.valid(dc) and pcall(function() dc:Event_BloodSplatterFX() end)
    else
        ok = pcall(function() npc:Event_BloodSplatter() end)
    end
    if ok then M.stats.blood_applied = M.stats.blood_applied + 1 end
end

local APPLY = { set = apply_set, fire = apply_fire, blood = apply_blood }

-- PlayerController.ClientRepObjRef(Object), pre (client): the NPC of the
-- payload that came just before. Cheap when nothing is pending.
local function on_objref(_, obj_p)
    local p = client.pending
    if not p then return end
    client.pending = nil
    if clock() - p.t > OBJ_TTL then
        M.stats.objref_stale = M.stats.objref_stale + 1
        return
    end
    local o = get(obj_p)
    if not ue.valid(o) then
        M.stats.objref_nil = M.stats.objref_nil + 1   -- no copy of it here (yet / any more)
        return
    end
    if ue.role(o) == ue.ROLE_AUTHORITY or (p.cls ~= "" and ue.class_name(o) ~= p.cls) then
        M.stats.objref_other = M.stats.objref_other + 1
        return
    end
    M.stats.objref_got = M.stats.objref_got + 1
    local fn = APPLY[p.kind]
    if not fn then return end
    local t0 = clock()
    fn(o, p.data)
    -- one 104 ms hitch at a ClientRepObjRef was seen once (0.7.1, not explained):
    -- name what it was if it happens again
    local ms = (clock() - t0) * 1000
    if ms >= 30 then
        M.stats.slow_objref = M.stats.slow_objref + 1
        log.info("npc: [SLOW] %s on %s took %.0f ms (look %d chars, %d look parts applied so far, %d not in memory)",
            p.kind, ue.short(o), ms, #(p.data and p.data.look or ""), M.stats.look_parts, M.stats.look_later)
    end
end

-- ---------------------------------------------------------------------------
-- Client: the enemy marker (npc_marker)
-- ---------------------------------------------------------------------------

local function m_los(pc, a) return pc:LineOfSightTo(a, { X = 0, Y = 0, Z = 0 }, false) end

-- What the game does 60 s after the last sight (@581 boss, @5242 zombie,
-- @247 bandit, @341 wolf): the marker component destroyed, the marker allowed
-- again, its timer cleared and the handle invalidated.
local function remove_marker(a, marker)
    local ok = pcall(function() marker:K2_DestroyComponent(a) end)
    if ue.has_prop(a, "CanAddMarker?") then ue.set_prop(a, "CanAddMarker?", true) end
    local ksl = ue.ksl()
    if ksl then pcall(function() ksl:K2_ClearTimer(a, "Event_Marker") end) end
    ue.set_prop(a, "MarkerTimer", { Handle = 0 })
    return ok
end

-- <AI>.Event_Marker, post (client): the marker's 1 s timer on a host copy.
local function on_marker(c)
    local a = c:get()
    if not ue.valid(a) or ue.role(a) == ue.ROLE_AUTHORITY then return end
    local marker = ue.prop(a, "Marker")
    if not ue.valid(marker) then return end
    local pc = ue.local_pc()
    if not pc then return end
    local key = ue.name(a)
    local now = clock()
    local ok, seen = pcall(m_los, pc, a)
    if ok and seen == true then
        if not client.marks[key] then M.stats.marks_seen = M.stats.marks_seen + 1 end
        client.marks[key] = now
        return
    end
    local last = client.marks[key]
    if not last or now - last < MARK_KEEP_S then return end
    client.marks[key] = nil
    if remove_marker(a, marker) then
        M.stats.marks_removed = M.stats.marks_removed + 1
        if first("marker", 3) then
            log.info("npc: marker: %s out of sight for %.0f s: its enemy marker removed here (the game's own"
                .. " removal; a client's copy has no AI controller to check the sight with)", ue.short(a), now - last)
        end
    else
        M.stats.marks_failed = M.stats.marks_failed + 1
        log.err_throttled("npc.marker", "npc: marker: %s: the marker could not be removed", ue.short(a))
    end
end

-- NPCROCK|ox|oy|oz|tx|ty|tz: the boss's throw, spawned here the boss's way
local function spawn_rock(f)
    local o = { X = num(f[1]), Y = num(f[2]), Z = num(f[3]) }
    local t = { X = num(f[4]), Y = num(f[5]), Z = num(f[6]) }
    if not (o.X and o.Y and o.Z and t.X and t.Y and t.Z) then return end
    local now = clock()
    if now - client.rocks.t >= 1 then client.rocks.t, client.rocks.n = now, 0 end
    if client.rocks.n >= ROCKS_PER_S then return end
    client.rocks.n = client.rocks.n + 1
    local cls = ue.find_object(ROCK)   -- loaded with BP_ZombieBoss (its hard reference)
    local gs, wc = ue.gameplay_statics(), ue.local_pc()
    if not cls or not gs or not wc then
        M.stats.rocks_failed = M.stats.rocks_failed + 1
        if first("rock.noclass", 2) then log.warn("npc: boss_fx: BP_ZombieBossRock class / statics not here, rock skipped") end
        return
    end
    local tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = o, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, a = pcall(function() return gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, 1, nil, 0) end)
    if not ok or not ue.valid(a) then
        M.stats.rocks_failed = M.stats.rocks_failed + 1
        log.err_throttled("npc.rock", "npc: boss_fx: rock spawn failed: %s", tostring(a))
        return
    end
    local okf, done = pcall(function() return gs:FinishSpawningActor(a, tf, 0) end)
    local rock = (okf and ue.valid(done)) and done or a
    if not ue.valid(rock) then return end
    pcall(function() rock:SetLifeSpan(ROCK_LIFE_S) end)
    if not pcall(function() rock:Launch(o, t) end) then
        M.stats.rocks_failed = M.stats.rocks_failed + 1
        pcall(function() rock:K2_DestroyActor() end)
        return
    end
    M.stats.rocks_spawned = M.stats.rocks_spawned + 1
    if first("rock.spawned", 3) then log.info("npc: boss_fx: the boss's rock flies here too") end
end

local function client_message(kind, f)
    if not S or S.role ~= "client" then return end
    if kind == "NPCROCK" then
        if opt("npc_boss_fx") then spawn_rock(f) end
    elseif kind == "NPCSET" then
        if opt("npc_health") or opt("npc_looks") then
            expect("set", f[1], { max = f[2], hp = f[3], look = f[4] or "", name = f[5] or "" })
        end
    elseif kind == "NPCFIRE" then
        if opt("npc_effects") then expect("fire", f[1], { on = f[2] == "1" }) end
    elseif kind == "NPCBLOOD" then
        if opt("npc_effects") then expect("blood", f[1], {}) end
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- A Blueprint function sdc_ai's features hook too: sdc_ai installs ONE engine
-- hook for both and runs this callback while the gate says so (host, one of
-- `keys` on), installed once a remote player is here (host.active).
local function shared_hook(path, keys, fn)
    SHARED[#SHARED + 1] = ai.hook_external({ path = path, kind = "bp", name = "npc." .. label_of(path), fn = fn,
        gate = function() return S ~= nil and S.role == "host" and keys_any(keys) end,
        need = function() return host.active end })
end

local function shared_missing()
    for _, h in ipairs(SHARED) do
        if not h.installed then return true end
    end
    return false
end

shared_hook(BOSS .. ":MeleeAttack", { "npc_offscreen", "npc_boss_fx" }, on_boss_melee)   -- sdc_ai_attacks
hook(BOSS .. ":RangedAttack", "bp", "host", { "npc_offscreen" }, on_boss_ranged)
shared_hook(BOSS .. ":DeathEvent", { "npc_boss_fx" }, on_boss_death)                     -- sdc_ai_kills, _killlog
hook(ROCK .. ":Launch", "bp", "host", { "npc_boss_fx" }, on_rock_launch)
hook(BOSS .. ":SetBurning", "bp", "host", { "npc_effects" }, on_set_burning)
hook(BOSS .. ":StopBurning", "bp", "host", { "npc_effects" }, on_stop_burning)
for _, path in ipairs(HUMANS) do
    hook(path .. ":SetBurning", "bp", "host", { "npc_effects" }, on_set_burning)
    shared_hook(path .. ":StopBurning", { "npc_effects" }, on_stop_burning)               -- sdc_ai_kills
end
hook(HUMAN .. ":Event_BloodSplatter", "bp", "host", { "npc_effects" }, on_human_blood)
hook(BOSS .. ":" .. BOSS_HIT, "bp", "host", { "npc_effects" }, on_boss_hit)
hook(OBJREF_FN, "pre", "client", { "npc_health", "npc_looks", "npc_effects" }, on_objref)
for _, path in ipairs(MARKED) do
    hook(path .. ":Event_Marker", "bp", "client", { "npc_marker" }, on_marker)
end

local last_role, last_world = nil, nil

-- Host: the human NPCs this module set to AlwaysTickPoseAndRefreshBones get
-- their own value back at once (the last client left, or the role changed in
-- this world): host_pass, which does it by distance, runs only with a client.
local function revert_ticking(why)
    if next(host.ticking) == nil then return end
    local n = 0
    for _, npc in ipairs(ue.find_all(HUMAN_CLASS)) do
        local key = ue.valid(npc) and ue.name(npc) or nil
        local was = key and host.ticking[key]
        if was ~= nil then
            local mesh = ue.prop(npc, "Mesh")
            if ue.valid(mesh) and ue.prop(mesh, TICK_PROP) == ALWAYS and ue.set_prop(mesh, TICK_PROP, was) then
                n = n + 1
            end
        end
    end
    host.ticking = {}
    M.stats.human_back = M.stats.human_back + n
    if n > 0 then log.info("npc: offscreen: %d human NPC(s) back to their own pose ticking (%s)", n, why) end
end

-- Role or world change: every string of the old session goes; no object is
-- touched. Hooks stay registered (gated by role and config).
function M.reset(why)
    host.active, host.viewers, host.last_pass = false, {}, -1000
    host.ticking, host.sent, host.looks, host.growl, host.roared, host.blood, host.burning = {}, {}, {}, {}, {}, {}, {}
    client.pending, client.applied, client.applied_n, client.bad = nil, {}, 0, {}
    client.marks, client.marks_pruned = {}, 0
    host.friendly, host.last_friendly = {}, -1000
    -- a new world loads its classes again: hooks still missing are retried soon
    for _, h in ipairs(HOOKS) do
        if not h.installed then h.wait, h.next_try = nil, 0 end
    end
    log.debug("npc: reset (%s)", tostring(why))
end

-- Every 250 ms (main.lua): hooks, the host's pass once a second.
function M.tick()
    if not S then return end
    local now = clock()
    local pc = ue.local_pc()
    local world = pc and addr(pc) or nil
    if S.role ~= last_role or world ~= last_world then
        if last_role == "host" and world == last_world then
            local ok, err = pcall(revert_ticking, "no longer the host")
            if not ok then log.err_throttled("npc.revert", "npc: tick revert: %s", tostring(err)) end
        end
        if last_role ~= nil then M.reset(S.role ~= last_role and "role" or "world") end
        last_role, last_world = S.role, world
    end
    if S.role == "host" then
        host.active = #(S.remote_pcs or {}) > 0
        if not host.active then
            host.viewers = {}
            if next(host.ticking) ~= nil then
                local ok, err = pcall(revert_ticking, "no client connected")
                if not ok then log.err_throttled("npc.revert", "npc: tick revert: %s", tostring(err)) end
            end
            return
        end
        install_hooks(now, "host")
        if shared_missing() then ai.install_now() end
        if now - host.last_pass >= PASS_S then
            host.last_pass = now
            local ok, err = pcall(host_pass, now)
            if not ok then log.err_throttled("npc.pass", "npc: host pass: %s", tostring(err)) end
        end
    elseif S.role == "client" then
        host.active = false
        install_hooks(now, "client")
        local p = client.pending
        if p and now - p.t > OBJ_TTL then
            client.pending = nil
            M.stats.objref_stale = M.stats.objref_stale + 1
        end
        -- marks of copies gone (their timer stopped with them): forgotten
        if now - client.marks_pruned >= MARKS_PRUNE_S then
            client.marks_pruned = now
            for k, t in pairs(client.marks) do
                if now - t > 10 * MARKS_PRUNE_S then client.marks[k] = nil end
            end
        end
    end
end

function M.install(state)
    S = state
    for _, kind in ipairs({ "NPCROCK", "NPCSET", "NPCFIRE", "NPCBLOOD" }) do
        net.on(kind, function(f) client_message(kind, f) end)
    end
    log.info("npc: installed (offscreen=%s boss_fx=%s effects=%s health=%s looks=%s marker=%s)", tostring(opt("npc_offscreen")),
        tostring(opt("npc_boss_fx")), tostring(opt("npc_effects")), tostring(opt("npc_health")), tostring(opt("npc_looks")),
        tostring(opt("npc_marker")))
    log.info("sound relay SND (boss growl / roar, host): to the clients within the sound's range + %.0f m (ZombieGrowlShort / ZombieDeathShort: FootSteps %.0f m; before: %.0f m); the rock itself still goes %.0f m",
        SOUND_MARGIN / 100, SOUND_RANGE / 100, FX_RANGE / 100, FX_RANGE / 100)
end

function M.status_line()
    local s = M.stats
    local n, shared = 0, 0
    for _, h in ipairs(HOOKS) do if h.installed then n = n + 1 end end
    for _, h in ipairs(SHARED) do if h.installed then shared = shared + 1 end end
    return string.format("npc: hooks=%d (+%d shared with sdc_ai) | host: boss ticking=%d humans ticking=%d back=%d rocks=%d sounds=%d fire=%d blood=%d set=%d objref failed=%d | client: rocks=%d failed=%d fire=%d blood=%d set=%d looks=%d parts=%d failed=%d not in memory=%d names=%d objref got=%d nil=%d stale=%d other=%d slow=%d | markers seen=%d removed=%d failed=%d",
        n, shared, s.boss_tick, s.human_tick, s.human_back, s.rocks_sent, s.sounds, s.fire_sent, s.blood_sent, s.set_sent,
        s.objref_failed, s.rocks_spawned, s.rocks_failed, s.fire_applied, s.blood_applied, s.set_applied, s.looks,
        s.look_parts, s.look_failed, s.look_later, s.names, s.objref_got, s.objref_nil, s.objref_stale, s.objref_other,
        s.slow_objref, s.marks_seen, s.marks_removed, s.marks_failed)
end

return M
