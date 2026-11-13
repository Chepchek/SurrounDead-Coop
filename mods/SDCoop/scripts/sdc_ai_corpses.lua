-- SDCoop zombie feature ai_corpses: zombie, boss and animal corpses stay on
-- the clients, fallen and lootable / harvestable.
--
-- Why zombie corpses vanished (BP_MasterZombie.Death, host only):
--   @5    CapsuleComponent.K2_DestroyComponent  - the capsule is the ROOT
--         component; UActorComponent::DestroyComponent sets the actor's
--         RootComponent to null
--   @38.. Mesh: collision QueryAndPhysics, SetSimulatePhysics(true) (ragdoll)
--   @239  IsDead? = true (replicated) ... OnRep_IsDead? is an EMPTY function
--   @293  Dead = true (BP_AI, not replicated)
--   later Delay(5) -> Mesh.bNoSkeletonUpdate, Delay(1200) -> K2_DestroyActor
-- With no root, GetActorLocation() is (0,0,0): APawn::IsNetRelevantFor's
-- distance check (150 m) then fails for every client not near the world
-- origin, the net driver closes the corpse's channel after RelevantTimeout
-- (5 s) and the client destroys its copy. The host keeps its corpse for 20
-- minutes. Before it vanished the client's copy only froze standing: the
-- ragdoll runs on the host and nothing of it replicates.
--
-- Looting is decided on the looking machine: BP_JigHelperComp.TraceToWorld
-- (the local player's interaction trace) asks the hit actor's JigCanInteract:
-- zombies / bosses answer `Dead`, animals `Health <= 0` — neither replicated,
-- so a client's copy also has to be told it is dead to be lootable.
--
-- Fix, zombies:
--   host:   Death's post-hook gives the corpse a plain SceneComponent as its
--           new root (AActor::AddComponentByClass: the first scene component
--           of a rootless actor becomes the root) at the capsule's place, so
--           it stays relevant like a live zombie, still replicated (IsDead?,
--           the loot container). Movement replication is switched off for
--           it first: every machine has its own ragdoll and the clients' copy
--           must not be moved to the new root.
--   client: OnRep_IsDead?'s post-hook (it runs when IsDead? arrives, also for
--           a corpse that becomes relevant later) does what Death does to the
--           mesh: collision, simulate physics, wake bodies; the copy's capsule
--           stops colliding, its movement and its groan / mist / spit stop;
--           Dead = true (lootable).
--           A copy that arrives dead (a client that joins later or walks up
--           to an old corpse) stood upright: its OnRep_IsDead? runs before
--           BeginPlay, and on a joining client before these hooks are even in
--           (they install with the client's first tick, once it has a
--           character, 30-55 s after joining in client_9/10.log). So the same
--           steps also run from the copy's ReceiveBeginPlay post-hook and from
--           a pass every 2 s (engine actor query) over the zombie copies: dead
--           and the mesh not simulating physics -> corpse (again after a mesh
--           swap: a late async load or the host's look recreate the bodies;
--           at most 3 times per copy).
-- Zombie boss (BP_ZombieBoss and its types): DeathEvent -> OnRep_IsDead?, which
-- here is NOT empty: it destroys the capsule (the root) and ragdolls the mesh,
-- on the host and on every client when IsDead? arrives. Host: the same scene
-- root after its OnRep_IsDead?. Client: Dead = true after its OnRep_IsDead?,
-- or from the pass for a boss copy that arrived dead.
-- Animals (BP_Animal: deer, rabbit, wolf, bear): IsDead? is NOT replicated.
--   The host's death code (deer @2804-2986 + @1834, wolf @4490-4672 + @1884,
--   rabbit @2627-2847 + @2214, bear Death @373-663) ragdolls the mesh and,
--   then or a frame later, destroys the capsule (root): the same vanishing.
--   host:   a post-hook on ActorComponent.K2_DestroyComponent (the Blueprint
--           node every one of them uses; its Object parameter is the animal)
--           gives a dead animal that just lost its root the scene root, then
--           sends AIDEAD + ClientRepObjRef(animal) to the clients within net
--           range. Every 4 s a pass over the live animals (engine actor query,
--           pending-kill ones excluded) sends it to clients that came near a
--           corpse later (their new copy stands again otherwise).
--   client: the copy gets the game's death steps: capsule collision off,
--           movement off, mesh QueryAndPhysics + simulate physics + wake +
--           bPauseAnims, noises stop; IsDead? = true, Dead = true, Health = 0
--           (JigCanInteract -> "Collect Meat").

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = {
    stats = { rooted = 0, root_kept = 0, root_failed = 0, ragdolls = 0, ragdoll_failed = 0, boss_lootable = 0,
              animal_roots = 0, dead_sent = 0, pass_sent = 0, animal_ragdolls = 0, came_dead = 0, stood = 0,
              re_ragdolls = 0 },
}
local core

local clock = os.clock

local SCENE_COMPONENT = "/Script/Engine.SceneComponent"
local DESTROY_COMPONENT = "/Script/Engine.ActorComponent:K2_DestroyComponent"
-- Death @38-193
local CH_VISIBILITY, CH_23, BLOCK, IGNORE, QUERY_AND_PHYSICS, NO_COLLISION = 3, 23, 2, 0, 3, 0
local ANIMAL_NOISES = { "Deer_Noises", "Wolf_Noises", "Bear_Noises" }

local SEND_CM = 15000          -- NetCullDistanceSquared default: a copy exists within 150 m
local FORGET_CM = 15200        -- beyond: the copy is gone; a new one needs AIDEAD again
local PASS_S = 4.0
local PASS_MAX = 64            -- animals looked at per pass
local PER_CLIENT_PASS = 8
local CPASS_S = 2.0            -- client: dead copies that still stand
local CPASS_MAX = 128          -- client: copies looked at per pass
local RAGDOLL_TRIES = 3        -- client: a corpse that keeps losing its ragdoll is left after this
local LIST_MAX = 8

local cpass = { last = -1000, broken = false, cursor = 0 }
local corpse_done = {}         -- client: [copy full name] = { t, n } (corpse steps done n times)

local told = {}                -- host: [animal full name] = { seen = clock, sent = { [pc full name] = true } }
local pass = { last = -1000, broken = false }

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

-- A corpse whose capsule (root) was destroyed gets a plain scene root.
-- Returns "added" | "kept" | "failed".
local function fix_root(z, quiet)
    if not ue.valid(z) then return "failed" end
    local root = ue.try(function() return z:K2_GetRootComponent() end)
    if ue.valid(root) then
        -- the capsule (or a root we added) is still there: nothing to do
        if not quiet then
            M.stats.root_kept = M.stats.root_kept + 1
            if core.first("corpses.kept", 2) then
                log.info("ai: corpses: %s still has its root %s after Death", ue.short(z), ue.class_name(root))
            end
        end
        return "kept"
    end
    local mesh = ue.prop(z, "Mesh")
    local ml = ue.valid(mesh) and ue.vec(ue.try(function() return mesh:K2_GetComponentLocation() end)) or nil
    local cls = ue.find_object(SCENE_COMPONENT)
    if not ml or not cls then
        M.stats.root_failed = M.stats.root_failed + 1
        return "failed"
    end
    -- the capsule's centre: the mesh sits BaseTranslationOffset below it
    -- (normally 0,0,-90; read as the character stored it at spawn)
    local off = ue.vec(ue.prop(z, "BaseTranslationOffset")) or { X = 0, Y = 0, Z = -90 }
    local tf = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = ml.X - off.X, Y = ml.Y - off.Y, Z = ml.Z - off.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    pcall(function() z:SetReplicateMovement(false) end)
    local ok, err = pcall(function() z:AddComponentByClass(cls, false, tf, false) end)
    local new_root = ue.try(function() return z:K2_GetRootComponent() end)
    if ok and ue.valid(new_root) then
        M.stats.rooted = M.stats.rooted + 1
        if core.first("corpses.rooted", 3) then
            log.info("ai: corpses: %s had no root after dying; new %s at %.0f %.0f %.0f (stays relevant)",
                ue.short(z), ue.class_name(new_root), tf.Translation.X, tf.Translation.Y, tf.Translation.Z)
        end
        return "added"
    end
    M.stats.root_failed = M.stats.root_failed + 1
    log.err_throttled("ai.corpses.root", "ai: corpses: no new root for %s: %s", ue.short(z), tostring(err))
    return "failed"
end

-- BP_MasterZombie.Death(Actor, Headshot), post (host)
local function on_death(c)
    fix_root(c:get())
end

-- BP_ZombieBoss.OnRep_IsDead?, post (host): called by DeathEvent after IsDead? = true
local function on_boss_dead(c)
    local b = c:get()
    if ue.valid(b) and ue.role(b) == ue.ROLE_AUTHORITY and ue.prop(b, "IsDead?") == true then fix_root(b) end
end

-- A dead animal (root fixed) -> AIDEAD to the clients near it that were not told.
local function announce(o, now, budget_field, limit)
    local key = ue.name(o)
    local rec = told[key]
    if not rec then
        rec = { sent = {} }
        told[key] = rec
    end
    rec.seen = now
    if not core.host.active then return 0 end
    local loc = ue.location(o)
    if not loc then return 0 end
    local n = 0
    for _, v in ipairs(core.host.viewers) do
        local dx, dy, dz = v.X - loc.X, v.Y - loc.Y, v.Z - loc.Z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 > FORGET_CM * FORGET_CM then
            rec.sent[v.key] = nil   -- its copy there is gone (or never was)
        elseif d2 <= SEND_CM * SEND_CM and not rec.sent[v.key] and ue.valid(v.pc) then
            local used = v[budget_field] or 0
            if not limit or used < limit then
                v[budget_field] = used + 1
                if core.send_with_obj(v.pc, o, "AIDEAD") then
                    rec.sent[v.key] = true
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- ActorComponent.K2_DestroyComponent(Object), post (host). Context = the
-- destroyed component (never read); Object = the actor whose Blueprint asked.
local function on_destroy_component(_, obj_p)
    local o = obj_p and obj_p:get()
    if not ue.valid(o) or not core.is_animal(o) then return end
    if ue.prop(o, "IsDead?") ~= true or ue.role(o) ~= ue.ROLE_AUTHORITY then return end
    -- the marker / burning effect go before the capsule: root still there -> "kept"
    if fix_root(o, true) ~= "added" then return end
    M.stats.animal_roots = M.stats.animal_roots + 1
    local n = announce(o, clock(), "dead")
    M.stats.dead_sent = M.stats.dead_sent + n
    if core.first("corpses.animal", 3) then
        log.info("ai: corpses: animal %s died: scene root, AIDEAD to %d client(s)", ue.short(o), n)
    end
end

-- Clients that came near a corpse later (a copy that became relevant again).
local function animal_pass(now)
    if pass.broken or #core.host.viewers == 0 or now - pass.last < PASS_S then return end
    pass.last = now
    -- the engine's actor iterator: live actors of this world only
    local out, err = ue.actors_of(core.ANIMAL_CLASS)
    if out == false then
        pass.broken = true
        log.warn("ai: corpses: GetAllActorsOfClass failed (%s); animal corpses only at death", tostring(err))
        return
    end
    if not out then return end
    local n = #out
    for _ = 1, math.min(n, PASS_MAX) do
        -- a cursor, so more than PASS_MAX animals are all visited over a few passes
        pass.cursor = (pass.cursor or 0) % n + 1
        local o = ue.elem(out[pass.cursor])
        if ue.valid(o) and ue.role(o) == ue.ROLE_AUTHORITY and ue.prop(o, "IsDead?") == true then
            -- died while this feature was off: root it now
            if fix_root(o, true) ~= "failed" then
                M.stats.pass_sent = M.stats.pass_sent + announce(o, now, "dead_pass", PER_CLIENT_PASS)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function call(o, label, fn)
    if not ue.valid(o) then return false end
    local ok = pcall(fn, o)
    if not ok then log.debug("ai: corpses: %s failed", label) end
    return ok
end

-- Is the copy's mesh a ragdoll already? true / false, nil when unknown.
local function simulating(mesh)
    if not ue.valid(mesh) then return nil end
    local v = ue.try(function() return mesh:IsSimulatingPhysics(FName("None")) end)
    if type(v) == "boolean" then return v end
    return nil
end

-- The game's death steps on a client's copy of a dead zombie (Death @5-1288,
-- what the host did to its own): capsule off, movement off, mesh ragdoll,
-- noises / effects off, lootable. Idempotent. Returns true when it ragdolled.
local function make_corpse(z)
    call(ue.prop(z, "CapsuleComponent"), "capsule", function(o) o:SetCollisionEnabled(NO_COLLISION) end)
    call(ue.prop(z, "CharacterMovement"), "movement", function(o) o:DisableMovement() end)
    local mesh = ue.prop(z, "Mesh")
    local ok = call(mesh, "mesh", function(o)
        o:SetCollisionResponseToChannel(CH_VISIBILITY, BLOCK)
        o:SetCollisionResponseToChannel(CH_23, IGNORE)
        o:SetCollisionEnabled(QUERY_AND_PHYSICS)
        o:SetSimulatePhysics(true)
        o:WakeAllRigidBodies()
    end)
    call(ue.prop(z, "Zombie_Cue"), "cue", function(o) o:Stop() end)
    for _, fx in ipairs({ "ZombieMist", "BloodSpitFX" }) do
        call(ue.prop(z, fx), fx, function(o) o:Deactivate() end)
    end
    -- JigCanInteract = Dead (Death @293): the corpse can be looted here
    ue.set_prop(z, "Dead", true)
    local key = ue.name(z)
    local d = corpse_done[key]
    corpse_done[key] = { t = clock(), n = (d and d.n or 0) + 1 }
    if not ok then M.stats.ragdoll_failed = M.stats.ragdoll_failed + 1 end
    return ok
end

-- BP_MasterZombie.OnRep_IsDead?, post (client): the copy's own ragdoll.
local function on_rep_dead(c)
    local z = c:get()
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY then return end
    if ue.prop(z, "IsDead?") ~= true then return end
    if simulating(ue.prop(z, "Mesh")) == true then return end
    if make_corpse(z) then
        M.stats.ragdolls = M.stats.ragdolls + 1
        local say = core.line("corpses.ragdoll", 3)
        if say then say("ai: corpses: %s died here: ragdoll, lootable", ue.short(z)) end
    end
end

-- BP_MasterZombie.ReceiveBeginPlay, post (client): a copy that came into view
-- dead (a client that joined later, or walked up to the corpse). Its OnRep_IsDead?
-- ran before BeginPlay, often before these hooks were in at all.
local function on_begin_play(c)
    local z = c:get()
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY or ue.prop(z, "IsDead?") ~= true then return end
    if simulating(ue.prop(z, "Mesh")) == true then return end
    if make_corpse(z) then
        M.stats.came_dead = M.stats.came_dead + 1
        local say = core.line("corpses.came_dead", 5)
        if say then say("ai: corpses: %s came into view dead: corpse here (ragdoll, lootable)", ue.short(z)) end
    end
end

-- live copies of a class on this client ({} when the class is not loaded;
-- false, error when the call failed)
local function copies_of(class_path)
    local out, err = ue.actors_of(class_path)
    if out == nil then return {} end
    return out, err
end

-- Client, every 2 s: a dead zombie copy that stands (joined / came into view
-- before the hooks were in, or its mesh was swapped after the ragdoll: a late
-- async load, the host's look) gets the corpse steps; a dead boss copy is
-- made lootable (its own OnRep_IsDead? ragdolls it, also on arrival).
local function client_corpse_pass(now)
    if cpass.broken or now - cpass.last < CPASS_S then return end
    cpass.last = now
    local fixed, new_n, again = {}, 0, 0
    local out, err = copies_of(core.ZOMBIE_CLASS)
    if out == false then
        cpass.broken = true
        log.warn("ai: corpses: client GetAllActorsOfClass failed (%s); only deaths seen live get corpses", tostring(err))
        return
    end
    local n = #out
    for _ = 1, math.min(n, CPASS_MAX) do
        cpass.cursor = cpass.cursor % n + 1
        local z = ue.elem(out[cpass.cursor])
        if ue.valid(z) and ue.role(z) ~= ue.ROLE_AUTHORITY and ue.prop(z, "IsDead?") == true then
            local sim = simulating(ue.prop(z, "Mesh"))
            local key = ue.name(z)
            local d = corpse_done[key]
            if sim == false or (sim == nil and not d) then
                if d and d.n >= RAGDOLL_TRIES then
                    if d.n == RAGDOLL_TRIES then   -- logged once
                        d.n = d.n + 1
                        log.warn("ai: corpses: %s keeps standing after %d ragdolls, left alone", ue.short(z), RAGDOLL_TRIES)
                    end
                elseif make_corpse(z) then
                    if d then
                        again = again + 1
                        M.stats.re_ragdolls = M.stats.re_ragdolls + 1
                    else
                        new_n = new_n + 1
                        M.stats.stood = M.stats.stood + 1
                        if #fixed < LIST_MAX then fixed[#fixed + 1] = ue.short(z) end
                    end
                end
            end
        end
    end
    if new_n > 0 then
        log.info("ai: corpses: %d dead zombie(s) stood on this client (joined / came into view earlier): corpses now: %s%s",
            new_n, table.concat(fixed, " "), new_n > #fixed and " ..." or "")
    end
    if again > 0 and core.first("corpses.again", 5) then
        log.info("ai: corpses: %d corpse(s) ragdolled again after a mesh change", again)
    end
    local bosses = copies_of(core.BOSS_CLASS)
    if bosses == false then return end
    for i = 1, #bosses do
        local b = ue.elem(bosses[i])
        if ue.valid(b) and ue.role(b) ~= ue.ROLE_AUTHORITY and ue.prop(b, "IsDead?") == true
            and ue.prop(b, "Dead") ~= true and ue.set_prop(b, "Dead", true) then
            M.stats.boss_lootable = M.stats.boss_lootable + 1
            log.info("ai: corpses: boss %s was dead already: lootable", ue.short(b))
        end
    end
end

-- BP_ZombieBoss.OnRep_IsDead?, post (client): it fell by itself; make it lootable.
local function on_boss_rep_dead(c)
    local b = c:get()
    if not ue.valid(b) or ue.role(b) == ue.ROLE_AUTHORITY or ue.prop(b, "IsDead?") ~= true then return end
    if ue.set_prop(b, "Dead", true) then
        M.stats.boss_lootable = M.stats.boss_lootable + 1
        local say = core.line("corpses.boss", 2)
        if say then say("ai: corpses: boss %s died here: lootable", ue.short(b)) end
    end
end

-- AIDEAD: waits for its animal (ClientRepObjRef)
local function on_aidead()
    if core.S.role ~= "client" then return end
    core.expect_obj("dead", true)
end

-- The client's copy of a dead animal: the game's death steps on it.
local function animal_died(o)
    if ue.role(o) == ue.ROLE_AUTHORITY or not core.is_animal(o) then return end
    if ue.prop(o, "IsDead?") == true then return end   -- done already (a resend)
    call(ue.prop(o, "CapsuleComponent"), "capsule", function(x) x:SetCollisionEnabled(NO_COLLISION) end)
    call(ue.prop(o, "CharacterMovement"), "movement", function(x) x:DisableMovement() end)
    local mesh = ue.prop(o, "Mesh")
    local ok = call(mesh, "mesh", function(x)
        x:SetCollisionEnabled(QUERY_AND_PHYSICS)
        x:SetSimulatePhysics(true)
        x:WakeAllRigidBodies()
    end)
    ue.set_prop(mesh, "bPauseAnims", true)
    for _, n in ipairs(ANIMAL_NOISES) do
        local a = ue.prop(o, n)
        if ue.valid(a) then call(a, n, function(x) x:Stop() end) end
    end
    -- the state the game's own checks read: health bar (IsDead?), JigCanInteract (Health <= 0)
    ue.set_prop(o, "IsDead?", true)
    ue.set_prop(o, "Dead", true)
    ue.set_prop(o, "Health", 0)
    if ok then
        M.stats.animal_ragdolls = M.stats.animal_ragdolls + 1
        local say = core.line("corpses.animal_client", 3)
        if say then say("ai: corpses: animal %s died on the host: ragdoll, harvestable", ue.short(o)) end
    else
        M.stats.ragdoll_failed = M.stats.ragdoll_failed + 1
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function M.init(c)
    core = c
    -- client table keyed by copy full name: entries of copies that are gone
    -- are dropped once a minute (sdc_ai core)
    if core.forget_gone then
        core.forget_gone("corpses", function() return { corpse_done = corpse_done } end)
    end
    -- also with nobody connected: a client that joins later must get the corpse
    core.hook({ path = core.ZM .. "Death", kind = "bp", role = "host", feature = "corpses", alone = true, fn = on_death })
    core.hook({ path = core.BOSS .. "OnRep_IsDead?", kind = "bp", role = "host", feature = "corpses", alone = true,
                name = "corpses.boss", fn = on_boss_dead })
    core.hook({ path = DESTROY_COMPONENT, kind = "post", role = "host", feature = "corpses", alone = true,
                name = "corpses.animal", fn = on_destroy_component })
    core.hook({ path = core.ZM .. "OnRep_IsDead?", kind = "bp", role = "client", feature = "corpses", fn = on_rep_dead })
    core.hook({ path = core.BOSS .. "OnRep_IsDead?", kind = "bp", role = "client", feature = "corpses",
                name = "corpses.boss_client", fn = on_boss_rep_dead })
    core.hook({ path = core.ZM .. "ReceiveBeginPlay", kind = "bp", role = "client", feature = "corpses",
                name = "corpses.came_dead", fn = on_begin_play })
    core.on_obj("dead", "corpses", animal_died)
end

function M.host_tick(now)
    animal_pass(now)
    for k, rec in pairs(told) do
        if now - (rec.seen or 0) > 900 then told[k] = nil end
    end
end

function M.client_tick(now)
    client_corpse_pass(now)
    for k, d in pairs(corpse_done) do
        if now - d.t > 1800 then corpse_done[k] = nil end
    end
end

function M.on_message(kind)
    if kind == "AIDEAD" then on_aidead() end
end

function M.reset()
    told = {}
    pass = { last = -1000, broken = false }
    cpass = { last = -1000, broken = false, cursor = 0 }
    corpse_done = {}
end

function M.status_line()
    local s = M.stats
    return string.format("ai: corpses host: new root=%d (animals %d) root kept=%d failed=%d AIDEAD at death=%d by pass=%d | "
        .. "client: ragdolls=%d came into view dead=%d stood then fixed=%d again after mesh change=%d animals=%d "
        .. "boss lootable=%d failed=%d", s.rooted, s.animal_roots, s.root_kept, s.root_failed, s.dead_sent, s.pass_sent,
        s.ragdolls, s.came_dead, s.stood, s.re_ragdolls, s.animal_ragdolls, s.boss_lootable, s.ragdoll_failed)
end

return M
