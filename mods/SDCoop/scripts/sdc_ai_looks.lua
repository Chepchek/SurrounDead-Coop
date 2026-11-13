-- SDCoop zombie feature ai_zombie_looks: a client's copy of a zombie is the
-- host's zombie — standing or crawling (capsule and mesh height), mesh,
-- material, hidden bones, locomotion blendspace, Name (health bar), the hound's
-- armour — and the client never rolls a type of its own.
--
-- Why they differed (work\audit\zombie_sync.md): every machine rolls its own
-- look. BeginPlay -> Event_SetMeshAndMaterial (random mesh / material, async
-- load), then after Delay(1..1.25) SelectArchetype -> RandomIntegerInRange per
-- *ArchetypeChance -> one Archetype_* event. Nothing of it is replicated.
-- Archetype_Crawler also shrinks the capsule 75 -> 40, moves the root 35 cm
-- down and the mesh to (-3,0,-32). A host crawler's replicated location is
-- therefore 35 cm lower than a standing zombie's: the client's standing copy
-- (capsule 75) sat in the floor, its movement simulation pushed it out /
-- dropped it into Falling (AnimBP_Zombie Falling? pose: "hanging in the air")
-- and every position update pulled it back (vertical jerking); a copy that
-- rolled crawler itself under a standing host zombie floated / sank the other
-- way. Network smoothing also moves a simulated proxy's mesh to
-- ACharacter::BaseTranslationOffset (cached once at spawn), so a mesh offset
-- set later does not stay unless that cache is updated too.
--
-- Host: Archetype_* post-hooks note the letters; SelectArchetype's post-hook
--   takes a snapshot and sends it to every client within 145 m (the 150 m net
--   range: their copy exists): AIAPP|arch|mesh|material|bones|name|blendspace|
--   body|age, then the zombie through ClientRepObjRef (sdc_ai core). body =
--   "capsule half height,mesh x,y,z,yaw" (live zombies only), age = seconds
--   since the host's roll. A client that comes near later is served by a
--   budgeted pass (every 2 s: the engine's GetAllActorsOfClass, at most 96
--   zombies looked at, at most 12 looks per client); beyond 152 m the client's
--   copy is gone, so the zombie is sent again when it comes back. A zombie
--   whose async mesh / material load finished after the snapshot is sent
--   again. AIAPPQ|x|y|z (a client's copy without a look) is answered for the
--   zombies within 3 m of that point.
-- Client: a copy's *ArchetypeChance are zeroed in its BeginPlay post-hook (and
--   by a pass for copies that began play before the hook was in), so its own
--   roll ends as a plain "Shambler". The host's look is applied with the
--   engine functions the Archetype_* events use — SetSkinnedAssetAndUpdate,
--   SetMaterial, HideBoneByName, the AnimBP's SetBlendspace,
--   SetCapsuleHalfHeight, the mesh's relative location — plus
--   ACharacter::CacheInitialMeshOffset (the smoothing target). No Archetype_*
--   call: they start timers / effects and roll again. The body is applied at
--   once, the rest after the copy's own SelectArchetype (it renames the
--   zombie); a late async load (OnLoaded_*) is overridden again. Leftovers of
--   a type the copy rolled before the hooks were in are removed (timers, mist /
--   spit effects). The hound's armour: the dog's own armour branch (ubergraph
--   @264) or the two armour meshes removed. A horde zombie's emerge montage is
--   stopped on a new copy of a zombie the host spawned long ago.
--   Copies still without a look 2.5 s after their roll ask the host (AIAPPQ).
-- Client applies never load: only assets already in memory are used (a sync
--   LoadAsset in the RPC hook froze a client while it streamed a new area);
--   a missing mesh / material / blendspace is looked for again (find_object,
--   2 s backing off to 30 s) for 10 min, then given up with the asset named
--   (13.11 client: 156 waits, 101 came within 100 s - another copy's own
--   async load brought them in - 26 gave up at 2 min; the assets that never
--   came are listed in the status line). A load of our own is not done here:
--   KismetSystemLibrary.LoadAsset (the async one the zombies use) needs a
--   soft pointer and a latent action from Lua - untested in UE4SS 3.0.1.
--   At most 2 full applies per 100 ms from events; over that only the cheap
--   body now, the rest from the client pass (1 s while work is due, 4 per pass,
--   none after the first once the pass ran 25 ms: slow mesh swaps go one per
--   tick instead of stacking up to 300 ms in one). An apply longer than 50 ms
--   is logged with its assets. Per-zombie lines: the first few at info, then
--   debug only.
-- Cost: per zombie only strings are kept. UE4SS never frees an out-array's
--   buffer: ~8 bytes per zombie per pass (host every 2 s, client every 3 s).

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local zi = require("sdc_ai_zombie")

local M = {
    stats = { snapshots = 0, sent = 0, pass_sent = 0, answered = 0, resend = 0, applied = 0, bodies = 0,
              waited = 0, zeroed = 0, reloaded = 0, asked = 0, armour = 0, leftovers = 0, emerge = 0,
              deferred = 0, missing = 0, retried = 0, gave_up = 0, slow = 0, effects = 0, spread = 0 },
}
local core

local clock = os.clock

-- letter, BP event (order of SelectArchetype / the crawler path)
local ARCHETYPES = {
    { "c", "Archetype_Crawler" }, { "t", "Archetype_ToughenedCrawler" }, { "s", "Archetype_Sprinter" },
    { "u", "Archetype_UltraRadiated" }, { "a", "Archetype_Acidic" }, { "g", "Archetype_Grenadier" },
    { "r", "Archetype_Screamer" },
}
local CHANCE_PROPS = { "CrawlerArchetypeChance", "SprinterArchetypeChance", "UltraRadiatedArchetypeChance",
    "AcidicArchetypeChance", "GrenadierArchetypeChance", "ScreamerArchetypeChance" }
-- Event_SetMeshAndMaterial's async loads: material (@7101), mesh (@7386)
local ONLOADED = { "OnLoaded_A7754CBC40A1C76BCC74AEA37FCFF283", "OnLoaded_D22F5BA44A8E7DDA4516F49F1F1CEA1F" }
-- what a type the copy rolled itself leaves running: { timer function, effect component }
local LEFTOVERS = { u = { "Event_Rad", "ZombieMist" }, a = { false, "BloodSpitFX" }, g = { "Event_Grenadier", false },
                    r = { "Event_Screamer", false } }
local DOG_ARMOUR_ENTRY = 264    -- BP_Zombie_Dog ubergraph: Name, health, two armour meshes
local ARMOUR_PREFIX = "NODE_AddSkeletalMeshComponent"
local HORDE = "BP_Zombie_Infected_Horde_C"
local SKEL_COMPONENT = "/Script/Engine.SkeletalMeshComponent"
-- the archetypes' lasting effects (hard references of BP_MasterZombie: in memory with the class)
local NIAGARA_LIB = "/Script/Niagara.Default__NiagaraFunctionLibrary"
local BLOOD_SPIT = "/Game/FX/Blood/NS_BloodSpit.NS_BloodSpit"            -- Archetype_Acidic @24158
local RAD_MIST = "/Game/PolygonFiles/PolygonApocalypse/ParticleFX/FX_ZombieRadiationMist.FX_ZombieRadiationMist"

local RANGE_CM = 14500          -- inside the 150 m net range: the client's copy exists
local LEAVE_CM = 15200          -- beyond: the copy is gone; a new one gets the look again
local PER_CLIENT_SELECT = 8     -- looks sent at a roll, per client and tick
local PER_CLIENT_PASS = 12      -- looks sent by the pass, per client and pass
local SLICE = 96                -- zombies looked at per pass
local PASS_S = 2.0
local PEND_TTL = 10
local QUERY_CM = 300            -- host: zombies around an asked point
local QUERY_MAX_CM = 20000      -- host: farther from the asking player is ignored
local HOST_REQ_PER_S = 6         -- host: questions answered per client and second
local ANSWER_MAX = 4
local OBJ_PAWN = 2              -- EObjectTypeQuery of ECC_Pawn
local PAWN_CLASS = "/Script/Engine.Pawn"
local CPASS_S = 3.0             -- client pass
local CSLICE = 64
local ASK_AFTER_S = 2.5         -- client: after its roll, a copy without a look asks
local ASK_AGAIN_S = 8
local ASK_MAX = 3               -- per copy
local ASK_PER_PASS = 3
local EMERGE_HOST_AGE_S = 6     -- the host's zombie is older than its emerge
local EMERGE_COPY_AGE_S = 5     -- the copy is new (its emerge montage is still on)
local NO_ROLL_S = 5             -- client: a copy this old that never rolled is taken as rolled
-- client apply budget (a mesh swap re-creates the mesh's render / physics / anim state)
local APPLY_WINDOW_S = 0.1      -- event path: at most APPLY_PER_WINDOW full applies per 100 ms
local APPLY_PER_WINDOW = 2
local PASS_APPLY_MAX = 4        -- deferred / retried applies per client pass
local PASS_BUDGET_S = 0.025     -- ... and no further one once the pass ran this long (the rest: next pass)
local CPASS_BUSY_S = 1.0        -- client pass interval while applies wait
local RETRY_S = 2.0             -- a part whose asset is not in memory here is looked for again after this
local RETRY_FOR_S = 600         -- ... for this long (0.8.1: 120 s)
local DEFER_TTL = 30
local SLOW_APPLY_S = 0.05       -- an apply longer than this is logged
-- client: mesh / material paths applied in this game process (the slow-apply
-- line tells a first use - render resources, shaders built on that PC - from
-- a repeat; the friend's 65-89 ms per zombie, cause unknown); strings only
local used_assets = { n = 0, t = {} }
local USED_MAX = 2000
-- client: assets that never came into memory for a copy (short names, the status line)
local never = { t = {}, list = {}, more = 0 }
local NEVER_MAX = 12

local known = {}       -- host: [zombie full name] = { seen, born?, sent = { [pc full name] = true } }
local letters = {}     -- host: [zombie full name] = "cs" (Archetype_* seen)
local pass = { cursor = 0, last = -1000, broken = false }
local asked_by = {}    -- host: [pc full name] = { t = window start, n = questions in it }

local rolled = {}      -- client: [copy full name] = clock (own SelectArchetype seen)
local pend = {}        -- client: [copy full name] = { snap, t }
local applied = {}     -- client: [copy full name] = snapshot
local born = {}        -- client: [copy full name] = clock (BeginPlay or first seen)
local zeroed = {}      -- client: [copy full name] = true
local asks = {}        -- client: [copy full name] = { n, t }
local deferred = {}    -- client: [copy full name] = { snap, why, t } (over the apply budget)
local waiting = {}     -- client: [copy full name] = { text, parts, next, till } (assets not in memory yet)
local budget = { t = -1000, n = 0 }
local seq_n = 0        -- client: AIAPP order (a newer look wins over a deferred older one)
local cpass = { cursor = 0, last = -1000, broken = false }

-- ---------------------------------------------------------------------------
-- Helpers (nothing here keeps an object)
-- ---------------------------------------------------------------------------

-- out-array elements come as params (read with :get())
local elem = ue.elem

local function each(arr, fn)
    if type(arr) == "table" then
        for _, e in ipairs(arr) do fn(elem(e)) end
    elseif arr ~= nil then
        pcall(function() arr:ForEach(function(_, e) fn(elem(e)) end) end)
    end
end

-- live actors of a class in this world (engine iterator: pending-kill ones
-- excluded); nil = not ready, false + error = the call failed
local actors_of = ue.actors_of

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function snapshot(z, key)
    local mesh = ue.prop(z, "Mesh")
    if not ue.valid(mesh) then return nil end
    local name = ue.str(ue.prop(z, "Name"))
    local anim = zi.anim_of(mesh)
    local k = known[key]
    local s = {
        arch = letters[key] or zi.arch_of(z, name),
        -- the name's form: each client builds the name in its own language
        nf = zi.name_form(z, name),
        mesh = zi.obj_path(zi.mesh_asset(mesh)),
        mat = zi.obj_path(zi.base_material(mesh)),
        bones = zi.hidden_bones(mesh),
        name = name,
        bs = anim and zi.obj_path(ue.prop(anim, "Movement Blendspace")) or "",
        body = zi.body_string(z, mesh),
        age = (k and k.born) and string.format("%d", math.floor(clock() - k.born)) or "",
    }
    if s.arch == "" then s.arch = "-" end
    M.stats.snapshots = M.stats.snapshots + 1
    return s
end

local function send_look(pc, z, snap)
    return core.send_with_obj(pc, z, "AIAPP", snap.arch, snap.mesh, snap.mat, snap.bones, snap.name, snap.bs,
        snap.body, snap.age, snap.nf or "?")
end

-- BP_MasterZombie.Archetype_*, post (host)
local function on_archetype_host(letter, c)
    local z = c:get()
    if not ue.valid(z) then return end
    local key = ue.name(z)
    local cur = letters[key] or ""
    if not cur:find(letter, 1, true) then letters[key] = cur .. letter end
end

local function on_select_host(z)
    local key = ue.name(z)
    local k = known[key]
    if not k then
        k = { sent = {} }
        known[key] = k
    end
    k.seen = clock()
    k.born = k.born or k.seen
    if not core.host.active then return end
    local near = core.viewers_near(ue.location(z), RANGE_CM)
    if #near == 0 then return end
    local snap = snapshot(z, key)
    if not snap then return end
    for _, v in ipairs(near) do
        v.looks = v.looks or 0
        if not k.sent[v.key] and v.looks < PER_CLIENT_SELECT then
            v.looks = v.looks + 1
            if send_look(v.pc, z, snap) then
                k.sent[v.key] = true
                M.stats.sent = M.stats.sent + 1
                local say = core.line("looks.sent", 3)
                if say then
                    say("ai: looks: %s -> %s: arch=%s mesh=%s bones=%s body=%s name=%s", ue.short(z),
                        ue.short(v.pc), snap.arch, zi.short_asset(snap.mesh), snap.bones, snap.body, snap.name)
                end
            end
        end
    end
end

-- BP_MasterZombie.OnLoaded_* (async mesh / material load done), post (host):
-- a look already sent may be stale now; the pass sends it again.
local function on_loaded_host(c)
    if next(known) == nil then return end
    local z = c:get()
    if not ue.valid(z) then return end
    local k = known[ue.name(z)]
    if k and next(k.sent) ~= nil then
        k.sent = {}
        M.stats.resend = M.stats.resend + 1
    end
end

-- one zombie of the pass: send its look to clients that came near
local function visit(z, now)
    local key = ue.name(z)
    local k = known[key]
    if not k then
        -- rolled before this feature saw it (feature switched on, host joined late)
        if not zi.rolled(z, ue.str(ue.prop(z, "Name"))) then return end
        k = { sent = {} }
        known[key] = k
    end
    k.seen = now
    local loc = ue.location(z)
    if not loc then return end
    local snap
    for _, v in ipairs(core.host.viewers) do
        local dx, dy, dz = v.X - loc.X, v.Y - loc.Y, v.Z - loc.Z
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= RANGE_CM * RANGE_CM then
            v.looks = v.looks or 0
            if not k.sent[v.key] and v.looks < PER_CLIENT_PASS and ue.valid(v.pc) then
                snap = snap or snapshot(z, key)
                if not snap then return end
                v.looks = v.looks + 1
                if send_look(v.pc, z, snap) then
                    k.sent[v.key] = true
                    M.stats.pass_sent = M.stats.pass_sent + 1
                end
            end
        elseif d2 > LEAVE_CM * LEAVE_CM then
            -- out of net range: its copy there is gone; a new one gets the look again
            k.sent[v.key] = nil
        end
    end
end

local function proximity_pass(now)
    if pass.broken or #core.host.viewers == 0 or now - pass.last < PASS_S then return end
    pass.last = now
    -- the budget is per pass (viewers are rebuilt every tick anyway)
    for _, v in ipairs(core.host.viewers) do v.looks = 0 end
    local out, err = actors_of(core.ZOMBIE_CLASS)
    if out == false then
        pass.broken = true
        log.warn("ai: looks: GetAllActorsOfClass failed (%s); looks only at the zombies' rolls", tostring(err))
        return
    end
    if not out then return end
    local n = #out
    if n == 0 then return end
    for _ = 1, math.min(SLICE, n) do
        pass.cursor = pass.cursor % n + 1
        local z = elem(out[pass.cursor])
        if ue.valid(z) and ue.role(z) == ue.ROLE_AUTHORITY then visit(z, now) end
    end
end

-- AIAPPQ|x|y|z (client -> host): the looks of the zombies at that point, to that client.
local function on_question(f, pc)
    if core.S.role ~= "host" or not core.is_remote_pc(pc) then return end
    local pkey = ue.name(pc)
    local now = clock()
    local q = asked_by[pkey]
    if not q or now - q.t >= 1 then
        q = { t = now, n = 0 }
        asked_by[pkey] = q
    end
    if q.n >= HOST_REQ_PER_S then return end
    q.n = q.n + 1
    local x, y, z = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
    if not (x and y and z) then return end
    local pawn = ue.pawn_of(pc)
    local pl = pawn and ue.location(pawn)
    if not pl then return end
    local dx, dy, dz = pl.X - x, pl.Y - y, pl.Z - z
    if dx * dx + dy * dy + dz * dz > QUERY_MAX_CM * QUERY_MAX_CM then return end
    local ksl, wc, pawn_cls = ue.ksl(), ue.local_pc(), ue.find_object(PAWN_CLASS)
    if not ksl or not wc or not pawn_cls then return end
    local out = {}
    local ok, err = pcall(function()
        ksl:SphereOverlapActors(wc, { X = x, Y = y, Z = z }, QUERY_CM, { OBJ_PAWN }, pawn_cls, {}, out)
    end)
    if not ok then
        log.err_throttled("ai.looks.query", "ai: looks: SphereOverlapActors: %s", tostring(err))
        return
    end
    local n = 0
    each(out, function(o)
        if n >= ANSWER_MAX or not ue.valid(o) or ue.role(o) ~= ue.ROLE_AUTHORITY or not core.is_zombie(o) then return end
        local key = ue.name(o)
        if not known[key] and not zi.rolled(o, ue.str(ue.prop(o, "Name"))) then return end
        local k = known[key] or { sent = {} }
        known[key] = k
        k.seen = now
        local snap = snapshot(o, key)
        if snap and send_look(pc, o, snap) then
            k.sent[pkey] = true
            n = n + 1
        end
    end)
    M.stats.answered = M.stats.answered + n
    if core.first("looks.answer", 3) then log.info("ai: looks: %s asked for a look: %d sent", ue.short(pc), n) end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- An asset by path, only when it is in memory already. Never loaded here: a
-- synchronous LoadAsset inside the network RPC hook, while the client streamed
-- in a new area, froze the client for good (client_12.log 15:26:37, a new
-- zombie group, AIAPP every 0.5 s). The copies' own async loads bring the
-- zombie meshes / materials in soon; a missing part is retried (RETRY_S).
local function asset(path, class_part)
    if type(path) ~= "string" or path:sub(1, 6) ~= "/Game/" then return nil end
    local a = ue.find_object(path)
    if a and class_part and not ue.class_name(a):find(class_part, 1, true) then return nil end
    return a
end

-- A retry re-runs the whole apply (~18 ms); do it only when one of the
-- missing assets is in memory now (find_object, cheap), else back off.
local function missing_ready(snap, parts)
    if not snap then return false end
    for p in tostring(parts):gmatch("[^,]+") do
        if p == "mesh" then
            if asset(snap.mesh, "SkeletalMesh") then return true end
        elseif p == "material" then
            if asset(snap.mat, "Material") then return true end
        elseif p == "blendspace" then
            if asset(snap.bs, "BlendSpace") then return true end
        elseif p == "spit fx" then
            if asset(BLOOD_SPIT, "Niagara") then return true end
        elseif p == "mist fx" then
            if asset(RAD_MIST, "ParticleSystem") then return true end
        else
            return true
        end
    end
    return false
end

-- The assets of the missing parts, short names ("SK_Zombie_Punk_Male_01,
-- MI_Zombie_04"): the lines and the status name what never came.
local function missing_names(snap, parts)
    local out = {}
    for p in tostring(parts):gmatch("[^,]+") do
        local path = (p == "mesh" and snap and snap.mesh) or (p == "material" and snap and snap.mat)
            or (p == "blendspace" and snap and snap.bs) or nil
        out[#out + 1] = (path and path ~= "") and zi.short_asset(path) or p
    end
    return table.concat(out, ", ")
end

-- One entry per comma-separated name ("spit fx" stays one, not "spit", "fx").
local function note_never(names)
    for part in tostring(names):gmatch("[^,]+") do
        local n = part:match("^%s*(.-)%s*$")
        if n ~= "" and not never.t[n] then
            never.t[n] = true
            if #never.list < NEVER_MAX then never.list[#never.list + 1] = n else never.more = never.more + 1 end
        end
    end
end

local function set_mesh(mesh, a)
    -- what Event_SetMeshAndMaterial / the archetypes call (@7470, @25493)
    if pcall(function() mesh:SetSkinnedAssetAndUpdate(a, false) end) then return true end
    if pcall(function() mesh:SetSkeletalMeshAsset(a) end) then return true end
    return (pcall(function() mesh:SetSkeletalMesh(a, false) end))
end

local function zero_chances(z)
    local key = ue.name(z)
    if zeroed[key] then return end
    local n = 0
    for _, p in ipairs(CHANCE_PROPS) do
        if ue.set_prop(z, p, 0) then n = n + 1 end
    end
    zeroed[key] = true
    if n > 0 then
        M.stats.zeroed = M.stats.zeroed + 1
        local say = core.line("looks.zeroed", 2)
        if say then say("ai: looks: %s will not roll a type (the host decides)", ue.short(z)) end
    end
end

-- Capsule and mesh height as on the host (Archetype_Crawler @27785 / @27891)
-- and the smoothing target the engine keeps pulling the mesh back to.
local function apply_body(z, mesh, b)
    if not b or ue.prop(z, "IsDead?") == true then return false end
    local cap = ue.prop(z, "CapsuleComponent")
    if not ue.valid(cap) then return false end
    local did = false
    local hh = zi.capsule_hh(z)
    if not hh or math.abs(hh - b.hh) > 0.5 then
        if pcall(function() cap:SetCapsuleHalfHeight(b.hh, true) end) then did = true end
    end
    local loc = { X = b.X, Y = b.Y, Z = b.Z }
    local rot = { Pitch = 0, Yaw = b.Yaw, Roll = 0 }
    local function off(v) return not v or math.abs(v.X - b.X) + math.abs(v.Y - b.Y) + math.abs(v.Z - b.Z) > 0.5 end
    if off(zi.vec(ue.prop(z, "BaseTranslationOffset"))) then
        if not pcall(function() z:CacheInitialMeshOffset(loc, rot) end) then
            ue.set_prop(z, "BaseTranslationOffset", loc)
        end
        did = true
    end
    -- the mesh itself (a copy's own Archetype_Crawler moved it, or the cache just changed)
    if did or off(zi.vec(ue.prop(mesh, "RelativeLocation"))) then
        pcall(function() mesh:K2_SetRelativeLocationAndRotation(loc, rot, false, {}, true) end)
        did = true
    end
    if did then M.stats.bodies = M.stats.bodies + 1 end
    return did
end

-- The hound's armour as on the host (by the name's form; an older host:
-- its English name).
local function fix_armour(z, mesh, own_name, snap, changed)
    if not ue.class_name(z):find("Zombie_Dog", 1, true) then return end
    local want = snap.nf and snap.nf == "A" or (not snap.nf and zi.armored(snap.name))
    local have = zi.is_armored(z, own_name)
    if want == have then return end
    if want then
        -- the dog's own armour branch: Name, health, two armour meshes on the leader pose
        if pcall(function() z:ExecuteUbergraph_BP_Zombie_Dog(DOG_ARMOUR_ENTRY) end) then
            changed[#changed + 1] = "+armour"
            M.stats.armour = M.stats.armour + 1
        end
        return
    end
    local cls = ue.find_object(SKEL_COMPONENT)
    local arr = cls and ue.try(function() return z:K2_GetComponentsByClass(cls) end)
    local n = 0
    local mesh_name = ue.name(mesh)
    each(arr, function(c)
        if ue.valid(c) and ue.name(c) ~= mesh_name and ue.short(c):sub(1, #ARMOUR_PREFIX) == ARMOUR_PREFIX then
            if pcall(function() c:K2_DestroyComponent(z) end) then n = n + 1 end
        end
    end)
    if n > 0 then
        changed[#changed + 1] = "-armour"
        M.stats.armour = M.stats.armour + 1
    end
end

-- A type the copy rolled itself before the hooks were in: stop what it left
-- running (timers, mist / spit effects) when the host's zombie has no such type.
-- The host's type's lasting effects on the copy, as its Archetype_* events make
-- them (only the effect, no Archetype_* call): Acidic -> NS_BloodSpit at the
-- 'mouth' socket (@24158 NiagaraFunctionLibrary.SpawnSystemAttached(.., (0,0,0),
-- (0,0,0), KeepRelativeOffset, bAutoDestroy false, bAutoActivate true, pool 1,
-- precull true) -> BloodSpitFX); UltraRadiated -> the FX_ZombieRadiationMist
-- particle component on the root (@8249 AddComponent of that template, identity
-- transform -> ZombieMist). Stored in the same variables, so the death steps
-- (sdc_ai_corpses) switch them off like the host's. Not on a corpse.
local function add_effects(z, mesh, arch, changed, miss)
    if arch == "-" or ue.prop(z, "IsDead?") == true then return end
    if arch:find("a", 1, true) and not ue.valid(ue.prop(z, "BloodSpitFX")) then
        local sys, lib = asset(BLOOD_SPIT, "Niagara"), ue.find_object(NIAGARA_LIB)
        if not sys or not lib then
            miss[#miss + 1] = "spit fx"
        else
            local comp = ue.try(function()
                return lib:SpawnSystemAttached(sys, mesh, FName("mouth"), { X = 0, Y = 0, Z = 0 },
                    { Pitch = 0, Yaw = 0, Roll = 0 }, 0, false, true, 1, true)
            end)
            if ue.valid(comp) then
                ue.set_prop(z, "BloodSpitFX", comp)
                changed[#changed + 1] = "spit fx"
                M.stats.effects = M.stats.effects + 1
            end
        end
    end
    if arch:find("u", 1, true) and not ue.valid(ue.prop(z, "ZombieMist")) then
        local ps, gps = asset(RAD_MIST, "ParticleSystem"), ue.gameplay_statics()
        local root = ue.try(function() return z:K2_GetRootComponent() end)
        if not ps or not gps or not ue.valid(root) then
            miss[#miss + 1] = "mist fx"
        else
            local comp = ue.try(function()
                return gps:SpawnEmitterAttached(ps, root, FName("None"), { X = 0, Y = 0, Z = 0 },
                    { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, 0, false, 0, true)
            end)
            if ue.valid(comp) then
                ue.set_prop(z, "ZombieMist", comp)
                changed[#changed + 1] = "mist fx"
                M.stats.effects = M.stats.effects + 1
            end
        end
    end
end

local function remove_leftovers(z, own_arch, host_arch, changed)
    if own_arch == "-" then return end
    local ksl = ue.ksl()
    for letter, what in pairs(LEFTOVERS) do
        if own_arch:find(letter, 1, true) and not host_arch:find(letter, 1, true) then
            if what[1] and ksl then pcall(function() ksl:K2_ClearTimer(z, what[1]) end) end
            local fx = what[2] and ue.prop(z, what[2])
            if fx and ue.valid(fx) then pcall(function() fx:K2_DestroyComponent(z) end) end
            changed[#changed + 1] = "-" .. letter
            M.stats.leftovers = M.stats.leftovers + 1
        end
    end
end

-- A new copy of a horde zombie the host spawned long ago plays its emerge
-- montage again (BP_Zombie_Infected_Horde BeginPlay @382): stop it; the BP's
-- own OnInterrupted / OnBlendOut put it back to walking (@67).
local function stop_emerge(z, mesh, snap, changed)
    if ue.class_name(z) ~= HORDE then return end
    local age = tonumber(snap.age)
    local b = born[ue.name(z)]
    if not age or age < EMERGE_HOST_AGE_S or not b or clock() - b > EMERGE_COPY_AGE_S then return end
    local anim = zi.anim_of(mesh)
    local m = anim and ue.try(function() return anim:GetCurrentActiveMontage() end)
    if not ue.valid(m) or not ue.short(m):find("Emerge", 1, true) then return end
    if pcall(function() anim:Montage_Stop(0.2, m) end) then
        changed[#changed + 1] = "emerge stopped"
        M.stats.emerge = M.stats.emerge + 1
    end
end

local function apply(z, snap, why)
    local mesh = ue.prop(z, "Mesh")
    if not ue.valid(mesh) then return end
    local dkey = ue.name(z)
    local d = deferred[dkey]
    if d and (d.snap.seq or 0) <= (snap.seq or 0) then deferred[dkey] = nil end
    local t0 = clock()
    -- step times for the slow-apply line (which part of it is slow on a PC)
    local tl, steps = t0, {}
    local function step(n)
        local t = clock()
        steps[#steps + 1] = string.format("%s %.0f", n, (t - tl) * 1000)
        tl = t
    end
    local changed, miss = {}, {}
    local own_name = ue.str(ue.prop(z, "Name"))
    if snap.mesh ~= "" and zi.obj_path(zi.mesh_asset(mesh)) ~= snap.mesh then
        local a = asset(snap.mesh, "SkeletalMesh")
        if not a then miss[#miss + 1] = "mesh" end
        if a and set_mesh(mesh, a) then
            changed[#changed + 1] = "mesh"
            -- a corpse: the new mesh's bodies come back without physics; the
            -- ragdoll again (sdc_ai_corpses' pass would do it within 2 s)
            if ue.prop(z, "IsDead?") == true then
                pcall(function()
                    mesh:SetSimulatePhysics(true)
                    mesh:WakeAllRigidBodies()
                end)
                changed[#changed + 1] = "ragdoll kept"
            end
        end
    end
    step("mesh")
    if snap.mat ~= "" and zi.obj_path(zi.base_material(mesh)) ~= snap.mat then
        local m = asset(snap.mat, "Material")
        if not m then miss[#miss + 1] = "material" end
        if m and pcall(function() mesh:SetMaterial(0, m) end) then
            changed[#changed + 1] = "material"
            -- Event_EyesCallback(NewValue) -> EyesColour on the new slot 0 (@13409)
            ue.call(z, "Event_EyesCallback", core.cvar_bool("Game.DisableZombieEyes", false))
        end
    end
    step("mat")
    if snap.bones ~= "?" then
        local want = {}
        for b in snap.bones:gmatch("[^,]+") do want[b] = true end
        for _, b in ipairs(zi.BONES) do
            local fn = FName(b)
            local ok, hidden = pcall(function() return mesh:IsBoneHiddenByName(fn) end)
            if ok and want[b] and hidden == false then
                if pcall(function() mesh:HideBoneByName(fn, 0) end) then changed[#changed + 1] = b end
            elseif ok and not want[b] and hidden == true then
                if pcall(function() mesh:UnHideBoneByName(fn) end) then changed[#changed + 1] = "+" .. b end
            end
        end
    end
    step("bones")
    if snap.bs ~= "" then
        local bs = asset(snap.bs, "BlendSpace")
        local anim = zi.anim_of(mesh)
        if not bs then miss[#miss + 1] = "blendspace" end
        if bs and anim and zi.obj_path(ue.prop(anim, "Movement Blendspace")) ~= snap.bs then
            -- what SD_AIComponent.UpdateBlendspace does: the AnimBP's SetBlendspace (bound to it)
            ue.set_prop(ue.prop(z, "SD_AIComponent"), "MovementBlendspace", bs)
            if ue.call(anim, "SetBlendspace", bs) or ue.set_prop(anim, "Movement Blendspace", bs) then
                changed[#changed + 1] = "blendspace"
            end
        end
    end
    step("bs")
    local body = apply_body(z, mesh, snap.b)
    if body then changed[#changed + 1] = "body hh=" .. tostring(snap.b.hh) end
    step("body")
    fix_armour(z, mesh, own_name, snap, changed)
    remove_leftovers(z, zi.arch_of(z, own_name), snap.arch, changed)
    add_effects(z, mesh, snap.arch, changed, miss)
    stop_emerge(z, mesh, snap, changed)
    step("fx")
    -- the name in this game's language: the host's form built from this
    -- game's texts (the host's own text only when that cannot be done)
    local want_name = snap.name
    if snap.nf then
        local built = zi.build_name(z, snap.nf)
        if built and built ~= "" then
            want_name = built
            if built ~= snap.name and core.first("looks.name_local", 3) then
                log.info("ai: looks: %s named in this game's language: '%s' (the host's '%s', form %s)", ue.short(z),
                    log.ascii(built), log.ascii(snap.name), snap.nf == "" and "base" or snap.nf)
            end
        end
    end
    if FText and want_name ~= "" and ue.str(ue.prop(z, "Name")) ~= want_name then
        if pcall(function() z:SetPropertyValue("Name", FText(want_name)) end) then changed[#changed + 1] = "name" end
    end
    step("name")
    local key = ue.name(z)
    applied[key] = snap
    M.stats.applied = M.stats.applied + 1
    local now = clock()
    if #miss > 0 then
        local w = waiting[key]
        local same = w and w.text == snap.text
        waiting[key] = { text = snap.text, parts = table.concat(miss, ","), next = now + RETRY_S,
                         till = same and w.till or now + RETRY_FOR_S }
        if not same then
            M.stats.missing = M.stats.missing + 1
            local say = core.line("looks.missing", 5)
            if say then
                say("ai: looks: %s: %s of the host's look not in memory here yet (%s); the rest applied, retried",
                    ue.short(z), table.concat(miss, ","), missing_names(snap, table.concat(miss, ",")))
            end
        end
    else
        waiting[key] = nil
    end
    local say = core.line(body and "looks.body" or "looks.applied", body and 10 or 5)
    if say then
        say("ai: looks: %s looks like the host's (%s, arch=%s, changed: %s)", ue.short(z), why, snap.arch,
            #changed > 0 and table.concat(changed, " ") or "nothing")
    end
    local dt = now - t0
    local fresh = {}
    for _, p in ipairs({ snap.mesh or "", snap.mat or "" }) do
        if p ~= "" and not used_assets.t[p] then
            fresh[#fresh + 1] = zi.short_asset(p)
            if used_assets.n >= USED_MAX then used_assets.t, used_assets.n = {}, 0 end
            used_assets.t[p], used_assets.n = true, used_assets.n + 1
        end
    end
    if dt > SLOW_APPLY_S then
        M.stats.slow = M.stats.slow + 1
        log.warn("ai: looks: applying the host's look to %s took %.0f ms (%s; mesh=%s mat=%s; changed: %s; ms: %s;"
            .. " first use here: %s)", ue.short(z), dt * 1000, why, zi.short_asset(snap.mesh), zi.short_asset(snap.mat),
            #changed > 0 and table.concat(changed, " ") or "nothing", table.concat(steps, ", "),
            #fresh > 0 and table.concat(fresh, " ") or "none")
    end
end

-- Event path (an RPC, a hook): at most APPLY_PER_WINDOW full applies per 100 ms.
-- Over it, only the cheap body goes on now; the rest waits for the client pass.
local function take_budget(now)
    if now - budget.t >= APPLY_WINDOW_S then budget.t, budget.n = now, 0 end
    if budget.n >= APPLY_PER_WINDOW then return false end
    budget.n = budget.n + 1
    return true
end

local function apply_or_defer(z, snap, why)
    local now = clock()
    if take_budget(now) then
        apply(z, snap, why)
        return
    end
    local key = ue.name(z)
    local d = deferred[key]
    if d and (d.snap.seq or 0) > (snap.seq or 0) then return end   -- a newer one waits already
    local mesh = ue.prop(z, "Mesh")
    if ue.valid(mesh) then apply_body(z, mesh, snap.b) end
    deferred[key] = { snap = snap, why = why, t = now }
    M.stats.deferred = M.stats.deferred + 1
end

-- BP_MasterZombie.ReceiveBeginPlay, post (client): before its own roll (+1 s)
local function on_begin_play_client(c)
    local z = c:get()
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY then return end
    born[ue.name(z)] = clock()
    zero_chances(z)
end

-- BP_MasterZombie.SelectArchetype, post: host -> snapshot; client -> rolled
local function on_select(c)
    local z = c:get()
    if not ue.valid(z) then return end
    local is_auth = ue.role(z) == ue.ROLE_AUTHORITY
    if core.S.role == "host" then
        if is_auth then on_select_host(z) end
        return
    end
    if is_auth then return end
    local key = ue.name(z)
    rolled[key] = clock()
    local p = pend[key]
    if p then
        pend[key] = nil
        apply_or_defer(z, p.snap, "after its roll")
    end
end

-- BP_MasterZombie.OnLoaded_*, post (client): the copy's own random mesh /
-- material arrived after the host's look; put the host's back.
local function on_loaded_client(c)
    local z = c:get()
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY then return end
    local key = ue.name(z)
    local d = deferred[key]
    local snap = applied[key]
    if d and (not snap or (d.snap.seq or 0) > (snap.seq or 0)) then snap = d.snap end
    if not snap then return end
    M.stats.reloaded = M.stats.reloaded + 1
    apply_or_defer(z, snap, "after its late load")
end

-- AIAPP|arch|mesh|material|bones|name|blendspace|body|age|name form: waits
-- for its zombie. The name form ("?" unknown; absent from an older host).
local function on_aiapp(f)
    if core.S.role ~= "client" then return end
    local snap = { arch = f[1] or "-", mesh = f[2] or "", mat = f[3] or "", bones = f[4] or "?", name = f[5] or "",
                   bs = f[6] or "", body = f[7] or "", age = f[8] or "" }
    if f[9] ~= nil and f[9] ~= "?" then snap.nf = f[9] end
    snap.b = zi.parse_body(snap.body)
    snap.text = table.concat({ snap.arch, snap.mesh, snap.mat, snap.bones, snap.name, snap.bs, snap.body,
                               snap.nf or "?" }, "|")
    seq_n = seq_n + 1
    snap.seq = seq_n
    core.expect_obj("look", snap)
end

local function on_look_obj(z, snap)
    if ue.role(z) == ue.ROLE_AUTHORITY or not core.is_zombie(z) then return end
    local key = ue.name(z)
    local prev = applied[key]
    if prev and prev.text == snap.text then return end
    local b = born[key]
    if rolled[key] or zi.rolled(z, ue.str(ue.prop(z, "Name"))) or (b and clock() - b > NO_ROLL_S) then
        apply_or_defer(z, snap, prev and "update" or "look")
    else
        -- the body now (no more floating / sinking); the rest after its own roll renamed it
        local mesh = ue.prop(z, "Mesh")
        if ue.valid(mesh) then apply_body(z, mesh, snap.b) end
        pend[key] = { snap = snap, t = clock() }
        M.stats.waited = M.stats.waited + 1
    end
end

-- One more apply in this pass: within PASS_APPLY_MAX, and after the first one
-- only while the pass has run less than PASS_BUDGET_S (a slow apply leaves
-- the rest to the next pass, 1 s later while work waits).
local function take_apply(left)
    if left.applies <= 0 then return false end
    if left.done > 0 and clock() - left.t0 >= PASS_BUDGET_S then
        left.applies = 0
        M.stats.spread = M.stats.spread + 1
        return false
    end
    left.applies = left.applies - 1
    left.done = left.done + 1
    return true
end

-- One copy of the client pass: a deferred apply, a retry of parts whose assets
-- were not in memory, the zeroing, or a question. `left` = { asks, applies, t0, done }.
local function client_visit(z, now, left)
    local key = ue.name(z)
    if not born[key] then born[key] = now end
    local d = deferred[key]
    if d then
        if take_apply(left) then
            deferred[key] = nil
            apply(z, d.snap, d.why .. ", deferred")
        end
        return
    end
    local w = waiting[key]
    if w and applied[key] and now >= w.next then
        if now > w.till then
            waiting[key] = nil
            M.stats.gave_up = M.stats.gave_up + 1
            local names = missing_names(applied[key], w.parts)
            note_never(names)
            local say = core.line("looks.gave_up", 3)
            if say then
                say("ai: looks: %s: %s (%s) never came into memory here in %d s; left as it is", ue.short(z), w.parts, names,
                    RETRY_FOR_S)
            end
        elseif not missing_ready(applied[key], w.parts) then
            w.tries = (w.tries or 0) + 1
            -- (not past its end: the give-up line comes from the visit at w.till)
            w.next = math.min(w.till, now + math.min(30, RETRY_S * 2 ^ math.min(w.tries, 4)))
        elseif take_apply(left) then
            M.stats.retried = M.stats.retried + 1
            apply(z, applied[key], "retry: " .. w.parts)
        end
        return
    end
    if applied[key] or pend[key] then return end
    if not rolled[key] and not zi.rolled(z, ue.str(ue.prop(z, "Name"))) then
        zero_chances(z)    -- began play before the BeginPlay hook was in
        if now - born[key] < NO_ROLL_S then return end
    end
    if left.asks <= 0 or ue.prop(z, "IsDead?") == true then return end
    if now - (rolled[key] or born[key]) < ASK_AFTER_S then return end
    local a = asks[key]
    if a and (a.n >= ASK_MAX or now - a.t < ASK_AGAIN_S) then return end
    local l = ue.location(z)
    if not l then return end
    if not net.send_to_host("AIAPPQ", string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z)) then
        return
    end
    asks[key] = { n = (a and a.n or 0) + 1, t = now }
    left.asks = left.asks - 1
    M.stats.asked = M.stats.asked + 1
    local say = core.line("looks.ask", 3)
    if say then say("ai: looks: %s has no look from the host yet; asked", ue.short(z)) end
end

-- A missing asset is looked for again only when its time has come (backing
-- off to 30 s, for 10 min): copies merely waiting do not make the pass (an
-- engine GetAllActorsOfClass) run every second.
local function waiting_due(now)
    for _, w in pairs(waiting) do
        if now >= w.next then return true end
    end
    return false
end

local function client_pass(now)
    local busy = next(deferred) ~= nil or waiting_due(now)
    if cpass.broken or now - cpass.last < (busy and CPASS_BUSY_S or CPASS_S) then return end
    cpass.last = now
    local out, err = actors_of(core.ZOMBIE_CLASS)
    if out == false then
        cpass.broken = true
        log.warn("ai: looks: client GetAllActorsOfClass failed (%s); looks only as the host sends them", tostring(err))
        return
    end
    if not out then return end
    local n = #out
    if n == 0 then return end
    local left = { asks = ASK_PER_PASS, applies = PASS_APPLY_MAX, t0 = clock(), done = 0 }
    for _ = 1, math.min(CSLICE, n) do
        cpass.cursor = cpass.cursor % n + 1
        local z = elem(out[cpass.cursor])
        if ue.valid(z) and ue.role(z) ~= ue.ROLE_AUTHORITY then client_visit(z, now, left) end
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function M.init(c)
    core = c
    -- client tables keyed by copy full name: entries of copies that are gone
    -- are dropped once a minute (sdc_ai core)
    if core.forget_gone then
        core.forget_gone("looks", function()
            return { rolled = rolled, pend = pend, applied = applied, born = born, zeroed = zeroed, asks = asks,
                     deferred = deferred, waiting = waiting }
        end)
    end
    local zm = core.ZM
    for _, a in ipairs(ARCHETYPES) do
        local letter = a[1]
        core.hook({ path = zm .. a[2], kind = "bp", role = "host", feature = "looks",
                    fn = function(ctx_p) on_archetype_host(letter, ctx_p) end })
    end
    core.hook({ path = zm .. "SelectArchetype", kind = "bp", role = "host", feature = "looks", fn = on_select })
    core.hook({ path = zm .. "SelectArchetype", kind = "bp", role = "client", feature = "looks", fn = on_select })
    core.hook({ path = zm .. "ReceiveBeginPlay", kind = "bp", role = "client", feature = "looks", fn = on_begin_play_client })
    for i, fn in ipairs(ONLOADED) do
        core.hook({ path = zm .. fn, kind = "bp", role = "host", feature = "looks", name = "looks.loaded" .. i,
                    fn = on_loaded_host })
        core.hook({ path = zm .. fn, kind = "bp", role = "client", feature = "looks", name = "looks.loaded" .. i,
                    fn = on_loaded_client })
    end
    core.on_obj("look", "looks", on_look_obj)
end

function M.host_tick(now)
    proximity_pass(now)
    for k, rec in pairs(known) do
        if now - (rec.seen or 0) > 600 then known[k] = nil end
    end
    for k in pairs(letters) do
        if not known[k] then letters[k] = nil end
    end
    for k, q in pairs(asked_by) do
        if now - q.t > 60 then asked_by[k] = nil end
    end
end

function M.client_tick(now)
    for k, p in pairs(pend) do
        if now - p.t > PEND_TTL then pend[k] = nil end
    end
    for k, t in pairs(rolled) do
        if now - t > 120 then rolled[k] = nil end
    end
    for k, t in pairs(born) do
        if now - t > 1800 then
            born[k], zeroed[k], asks[k] = nil, nil, nil
        end
    end
    for k, d in pairs(deferred) do
        if now - d.t > DEFER_TTL then deferred[k] = nil end
    end
    -- (left past its end only when its copy was not visited: the pass gives
    -- a visited one up with its line first)
    for k, w in pairs(waiting) do
        if now > w.till + 60 then waiting[k] = nil end
    end
    local n = 0
    for _ in pairs(applied) do n = n + 1 end
    if n > 4000 then applied = {} end
    client_pass(now)
end

function M.on_message(kind, f, pc)
    if kind == "AIAPP" then
        on_aiapp(f)
    elseif kind == "AIAPPQ" then
        on_question(f, pc)
    end
end

function M.reset()
    known, letters, asked_by = {}, {}, {}
    pass = { cursor = 0, last = -1000, broken = false }
    rolled, pend, applied, born, zeroed, asks = {}, {}, {}, {}, {}, {}
    deferred, waiting = {}, {}
    budget = { t = -1000, n = 0 }
    cpass = { cursor = 0, last = -1000, broken = false }
end

function M.status_line()
    local s = M.stats
    return string.format("ai: looks snapshots=%d sent at roll=%d by pass=%d answered=%d resend=%d | client applied=%d "
        .. "bodies=%d waited=%d deferred=%d missing assets=%d retried=%d gave up=%d slow=%d zeroed=%d asked=%d "
        .. "reloaded=%d armour=%d leftovers=%d effects=%d emerge=%d passes cut short=%d",
        s.snapshots, s.sent, s.pass_sent, s.answered, s.resend, s.applied, s.bodies, s.waited, s.deferred, s.missing,
        s.retried, s.gave_up, s.slow, s.zeroed, s.asked, s.reloaded, s.armour, s.leftovers, s.effects, s.emerge,
        s.spread) .. (#never.list > 0 and string.format(" | never came into memory here: %s%s", table.concat(never.list, ", "),
        never.more > 0 and string.format(" +%d more", never.more) or "") or "")
end

return M
