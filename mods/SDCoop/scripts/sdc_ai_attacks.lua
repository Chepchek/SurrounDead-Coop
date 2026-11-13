-- SDCoop zombie feature ai_attack_montages: clients see zombies attack, flinch,
-- get shoved and scream, zombie bosses attack and slam, wolves bite, bears
-- claw, and animals flinch.
--
-- The zombie's AI runs on the host only, and so do its montages:
--   attack  AttackPlayer -> PlayAttackMontage (@21105) -> PlayAnimMontage of a
--           weighted random entry of AttackMontages; the attack sound @21032
--   hit     DamageComponent.StandardDamage -> bound event -> PlayAnimMontage(
--           HitAnimation) (@16745)
--   other   PlayMontageCallbackProxy: shoved (@21535), scream (@10496),
--           agonize (@8771)
-- Nothing of that replicates (no root motion), so a client's copy just slides.
--
-- Host: post-hooks on PlayAttackMontage and the hit event read the zombie's
-- GetCurrentMontage (the one just started); a pre-hook on the proxy factory
-- takes the montage from its parameters. The montage goes to every client
-- whose pawn is within ~160 m (the zombie's net range) as AIM|kind|rate|path,
-- followed by the zombie itself through ClientRepObjRef (sdc_ai core): the
-- client's engine resolves it to its own copy. Rate limits: one per zombie and
-- montage per 0.25 s (an attack: per 90 % of its length), 20 per client and
-- second.
-- Client: Montage_Play on the copy's AnimInstance, plus the attack sound. An
-- attack / other montage already playing on the copy is not restarted (the
-- boss's attack re-sent every 0.3 s looked like a very fast attack).
--
-- Attack montages carry AnimNotify_BeginEvent("RightArmTrace" ...). Its
-- Received_NotifyBegin starts K2_SetTimer(zombie, name, delta, looping) whose
-- trace applies damage, bleeding, infection. On a client's copy that would be
-- a second, local hit: a post-hook on Received_NotifyBegin clears the timer
-- right away (a timer set this frame fires at the earliest next frame).
--
-- Zombie boss (BP_ZombieBoss and its types, a separate class): MeleeAttack
-- (@11396) -> PlayAnimMontage(Array_Random(AttackMontage)) right away (unless
-- an attack is already running: Start_MeleeAttacking); its two montages carry
-- AnimNotify_BeginEvent RightArmTrace / LeftArmTrace like the zombies'. Ranged
-- attack: Delay -> proxy ZombieBossSlam_Anim_Montage (@2224); the slam's
-- GroundSmashTrace starts from the proxy's own notify delegate, bound only on
-- the host. Host: MeleeAttack's post-hook forwards the montage it just started
-- (montage position ~0, so a refused attack does not restart the running one
-- on the clients); the proxy hook takes the slam. Client: the same play and
-- trace-timer clearing as for zombies.
--
-- Wolf and bear (BP_AnimalWolf / BP_AnimalBear): AttackPlayer (wolf @9119,
-- bear @7714) -> PlayAnimMontage(bite / random AttackMontage), local like the
-- zombies'. Its AnimNotify_BeginEvent "AttackTrace" is the bite. Host:
-- AttackPlayer's post-hook forwards the montage it just started (position
-- <= 0.2 s, as for the boss: AttackPlayer also runs while an attack plays).
-- Hit reactions of every animal (deer and rabbit too) come through the proxy
-- hook. Not forwarded: a montage that plays as networked root motion (the
-- engine replicates that one itself). Client: the same play and AttackTrace
-- clearing as for zombies. Whether the bite also lands on a client when the
-- host does not look at the animal is ai_offscreen_combat.

local log = require("sdc_log")
local ue = require("sdc_ue")
local ctx = require("sdc_ctx")

local M = {
    stats = { sent = 0, played = 0, kept = 0, unmatched = 0, dead = 0, no_montage = 0, traces_cleared = 0 },
}
local core

local clock = os.clock
local addr = ctx.addr

local PROXY_FN = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"
local NOTIFY_BEGIN = "/Game/Animations/Notifies/AnimNotify_BeginEvent.AnimNotify_BeginEvent_C:Received_NotifyBegin"
local HIT_EVENT = "BndEvt__DamageTester_DamageComponent_K2Node_ComponentBoundEvent_0_StandardDamage__DelegateSignature"
-- zombie functions started by AnimNotify_BeginEvent that hurt players
local TRACE_FUNCS = { RightArmTrace = true, LeftArmTrace = true, AttackTrace = true, BiteTrace = true,
                      GroundSmashTrace = true }
local FRESH_S = 0.2            -- boss, animals: a montage started by this call
local ANIMAL_GAP_S = 1.0       -- animals: one attack forwarded per second at most
local ANIMAL_ATTACKERS = {
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
    "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
}

local RANGE_CM = 16000       -- NetCullDistanceSquared default = 150 m, plus a margin
local GAP_S = 0.25
local PER_CLIENT_TICK = 20
local LEN_SHARE = 0.9         -- attacks: the same montage again within 90 % of its length is a restart

local last_sent = {}          -- host: [zombie address .. montage path] = clock
local playing = {}            -- client: [copy full name] = { path, t, len } (its last attack / other montage)

-- The montage's length in seconds at `rate` (1 s when unknown).
local function play_len(montage, rate)
    local len = ue.try(function() return montage:GetPlayLength() end)
    if type(len) ~= "number" or len <= 0 then len = 1.0 end
    local r = tonumber(rate) or 1
    if r <= 0.05 then r = 1 end
    return len / r
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function forward(z, montage, rate, kind)
    if not core.host.active or #core.host.viewers == 0 then return end
    if not ue.valid(z) or not ue.valid(montage) then return end
    local path = ue.path(montage)
    if path:sub(1, 6) ~= "/Game/" then return end
    local now = clock()
    local key = tostring(addr(z)) .. path
    local t = last_sent[key]
    -- an attack the host restarts (a boss whose montage does not advance while
    -- the host does not render it re-attacked every 0.3 s) goes out once per
    -- montage length
    local gap = GAP_S
    if kind == "a" then gap = math.max(GAP_S, play_len(montage, rate) * LEN_SHARE) end
    if t and now - t < gap then return end
    last_sent[key] = now
    local near = core.viewers_near(ue.location(z), RANGE_CM)
    if #near == 0 then return end
    local rate_s = string.format("%.2f", tonumber(rate) or 1)
    for _, v in ipairs(near) do
        if v.sent < PER_CLIENT_TICK then
            v.sent = v.sent + 1
            if core.send_with_obj(v.pc, z, "AIM", kind, rate_s, path) then
                M.stats.sent = M.stats.sent + 1
                if core.first(core.is_animal(z) and "attacks.sent.animal" or "attacks.sent", 3) then
                    log.info("ai: attacks: %s (%s) of %s -> %s", ue.short(montage), kind, ue.short(z), ue.short(v.pc))
                end
            end
        end
    end
end

-- BP_MasterZombie.PlayAttackMontage, post (host)
local function on_attack(c)
    if not core.host.active then return end
    local z = c:get()
    if not ue.valid(z) then return end
    forward(z, core.current_montage(z), 1.0, "a")
end

-- BP_ZombieBoss.MeleeAttack, post (host): the montage this call started
local function on_boss_melee(c)
    if not core.host.active then return end
    local z = c:get()
    if not ue.valid(z) then return end
    -- the montage this call started (position <= FRESH_S), not one already running
    local m = core.fresh_montage(z, FRESH_S)
    if m then forward(z, m, 1.0, "a") end
end

-- an animal montage the engine replicates itself (root motion)
local function engine_replicated(a)
    return ue.try(function() return a:IsPlayingNetworkedRootMotionMontage() end) == true
end

-- Does montage `m` move by root motion (the engine then replicates it to the
-- clients itself)? Its first segment's sequence's bEnableRootMotion, cached by
-- path; nil when that cannot be read.
local root_motion = {}        -- [montage path] = true | false
local function m_first_sequence(m) return m.SlotAnimTracks[1].AnimTrack.AnimSegments[1].AnimReference end
local function montage_root_motion(m)
    local path = ue.path(m)
    local v = root_motion[path]
    if v ~= nil then return v end
    local ok, seq = pcall(m_first_sequence, m)
    if not ok or not ue.valid(seq) then return nil end
    v = ue.prop(seq, "bEnableRootMotion")
    if type(v) ~= "boolean" then return nil end
    root_motion[path] = v
    return v
end

-- <Wolf / Bear>.AttackPlayer, post (host): the bite / claw this call started.
-- At most one per ANIMAL_GAP_S: a montage the host does not tick (unseen,
-- ai_offscreen_combat off) stays at position 0 while the BT keeps calling.
local function on_animal_attack(c)
    if not core.host.active then return end
    local a = c:get()
    if not ue.valid(a) or ue.prop(a, "IsDead?") == true then return end
    local m = core.fresh_montage(a, FRESH_S)
    if not m or engine_replicated(a) then return end
    local key = tostring(addr(a)) .. "|attack"
    local now = clock()
    if last_sent[key] and now - last_sent[key] < ANIMAL_GAP_S then return end
    last_sent[key] = now
    forward(a, m, 1.0, "a")
end

-- BP_MasterZombie's StandardDamage bound event, post (host): the hit reaction
local function on_hit(c)
    if not core.host.active then return end
    local z = c:get()
    if not ue.valid(z) then return end
    local m = core.current_montage(z)
    local hit = ue.prop(z, "HitAnimation")
    if m and ue.valid(hit) and addr(m) == addr(hit) then forward(z, m, 1.0, "h") end
end

-- PlayMontageCallbackProxy.CreateProxyObjectForPlayMontage(Mesh, Montage,
-- PlayRate, StartingPosition, StartingSection, bShouldStopAllMontages) -> proxy,
-- pre (host): (context, params...). The montage and rate come from the
-- parameters, so the call does not have to have run: one shared pre-only
-- engine hook (sdc_ue.hook_native) with sdc_combat and sdc_throw.
local function on_proxy(_, mesh_p, montage_p, rate_p)
    if not core.host.active or #core.host.viewers == 0 then return end
    local mesh = mesh_p and mesh_p:get()
    if not ue.valid(mesh) then return end
    local z = ue.try(function() return mesh:GetOwner() end)
    if not ue.valid(z) or not (core.is_zombie(z) or core.is_boss(z) or core.is_animal(z)) then return end
    local m = montage_p and montage_p:get()
    if not ue.valid(m) then return end
    if core.is_animal(z) then
        -- before the call the animal does not play `m` yet: the montage asset
        -- says whether it will be networked root motion (else, as a fallback,
        -- whether the animal plays such a montage now)
        local rm = montage_root_motion(m)
        if rm == true or (rm == nil and engine_replicated(z)) then return end
    end
    forward(z, m, rate_p and rate_p:get() or 1.0, "o")
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function play_attack_sound(z)
    local snd = ue.prop(z, "AttackSound")
    local gps = ue.gameplay_statics()
    local l = ue.location(z)
    if not ue.valid(snd) or not gps or not l then return end
    pcall(function()
        gps:PlaySoundAtLocation(z, snd, l, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil)
    end)
end

-- AIM|kind|rate|montage path: waits for its zombie (ClientRepObjRef)
local function on_aim(f)
    if core.S.role ~= "client" then return end
    local path = f[3] or ""
    if path:sub(1, 6) ~= "/Game/" then return end
    core.expect_obj("montage", { kind = f[1] or "o", rate = tonumber(f[2]) or 1.0, path = path })
end

-- zombie, boss or animal
local function is_ai(z)
    return core.is_zombie(z) or core.is_boss(z) or core.is_animal(z)
end

-- The client's copy of the host's zombie (fresh from the RPC, used now only).
local function play(z, d)
    if ue.role(z) == ue.ROLE_AUTHORITY or not is_ai(z) then
        M.stats.unmatched = M.stats.unmatched + 1
        return
    end
    if ue.prop(z, "IsDead?") == true then
        M.stats.dead = M.stats.dead + 1
        return
    end
    -- an asset path from the network: must be a loaded AnimMontage
    local montage = ue.find_object(d.path)
    if not montage or ue.class_name(montage) ~= "AnimMontage" then
        M.stats.no_montage = M.stats.no_montage + 1
        log.err_throttled("ai.attacks.montage", "ai: attacks: montage %s not loaded here", d.path)
        return
    end
    local mesh = ue.prop(z, "Mesh")
    local anim = ue.valid(mesh) and ue.try(function() return mesh:GetAnimInstance() end) or nil
    if not ue.valid(anim) then return end
    -- an attack / shove / scream already playing on this copy is not restarted
    -- (a restart every 0.3 s looked like a very fast attack); hit reactions
    -- restart with every hit, as on the host
    local key = ue.name(z)
    local now = clock()
    if d.kind ~= "h" then
        local p = playing[key]
        local busy = ue.try(function() return anim:Montage_IsPlaying(montage) end) == true
        if busy or (p and p.path == d.path and now - p.t < p.len) then
            M.stats.kept = M.stats.kept + 1
            local say = core.line("attacks.kept", 3)
            if say then say("ai: attacks: %s already plays %s; not restarted", ue.short(z), ue.short(montage)) end
            return
        end
    end
    if not pcall(function() anim:Montage_Play(montage, d.rate, 0, 0.0, true) end) then return end
    if d.kind ~= "h" then playing[key] = { path = d.path, t = now, len = play_len(montage, d.rate) * LEN_SHARE } end
    M.stats.played = M.stats.played + 1
    if d.kind == "a" then play_attack_sound(z) end
    local say = core.line(core.is_animal(z) and "attacks.played.animal" or "attacks.played", 3)
    if say then say("ai: attacks: played %s (%s) on %s", ue.short(montage), d.kind, ue.short(z)) end
end

-- AnimNotify_BeginEvent.Received_NotifyBegin(MeshComp, ...), post (client):
-- a zombie copy's damage trace timer is cleared before it can fire.
local function on_notify_begin(c, mesh_p)
    local notify = c:get()
    local name = ue.str(ue.prop(notify, "EventName"))
    if not TRACE_FUNCS[name] then return end
    local mesh = mesh_p and mesh_p:get()
    local z = ue.valid(mesh) and ue.try(function() return mesh:GetOwner() end) or nil
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY or not is_ai(z) then return end
    local ksl = ue.ksl()
    if ksl and pcall(function() ksl:K2_ClearTimer(z, name) end) then
        M.stats.traces_cleared = M.stats.traces_cleared + 1
        local say = core.line(core.is_animal(z) and "attacks.trace.animal" or "attacks.trace", 2)
        if say then say("ai: attacks: %s timer on %s cleared (the host applies the hit)", name, ue.short(z)) end
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function M.init(c)
    core = c
    core.hook({ path = core.ZM .. "PlayAttackMontage", kind = "bp", role = "host", feature = "attacks", fn = on_attack })
    core.hook({ path = core.BOSS .. "MeleeAttack", kind = "bp", role = "host", feature = "attacks",
                name = "attacks.boss", fn = on_boss_melee })
    core.hook({ path = core.ZM .. HIT_EVENT, kind = "bp", role = "host", feature = "attacks",
                name = "attacks.hit", fn = on_hit })
    for _, path in ipairs(ANIMAL_ATTACKERS) do
        local short = path:match("%.([%w_]+)$")
        core.hook({ path = path .. ":AttackPlayer", kind = "bp", role = "host", feature = "attacks",
                    name = "attacks." .. short, fn = on_animal_attack })
    end
    core.hook({ path = PROXY_FN, kind = "pre", role = "host", feature = "attacks", name = "attacks.proxy", fn = on_proxy })
    core.hook({ path = NOTIFY_BEGIN, kind = "bp", role = "client", feature = "attacks", name = "attacks.notify",
                fn = on_notify_begin })
    core.on_obj("montage", "attacks", play)
end

function M.host_tick(now)
    for k, t in pairs(last_sent) do
        if now - t > 5 then last_sent[k] = nil end
    end
end

function M.on_message(kind, f)
    if kind == "AIM" then on_aim(f) end
end

function M.client_tick(now)
    for k, p in pairs(playing) do
        if now - p.t > 10 then playing[k] = nil end
    end
end

function M.reset()
    last_sent, playing = {}, {}
end

function M.status_line()
    local s = M.stats
    return string.format("ai: attacks sent=%d played=%d not restarted=%d no copy/class=%d dead=%d montage missing=%d "
        .. "traces cleared=%d", s.sent, s.played, s.kept, s.unmatched, s.dead, s.no_montage, s.traces_cleared)
end

return M
