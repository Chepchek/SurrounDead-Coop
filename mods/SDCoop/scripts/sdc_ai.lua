-- SDCoop: zombies in co-op. Core of the independent features below.
--
-- Zombies (BP_MasterZombie_C and its children) are server actors replicated
-- to the clients. Each feature has its own config key; a feature that is off
-- loads no module, registers no hook and does no tick work:
--   ai_kill_credit      sdc_ai_kills    the kill, its XP and popup go to the client that killed
--   ai_attack_montages  sdc_ai_attacks  zombie / boss / wolf / bear attack, hit, shove, scream montages on the clients' copies
--   ai_corpses          sdc_ai_corpses  zombie / boss / animal corpses stay on the clients, lootable
--   ai_healthbar        sdc_ai_hud      the enemy health bar: back after a respawn, with the host's health values
--   ai_zombie_looks     sdc_ai_looks    crawler / standing body, mesh, material, bones, name as on the host; clients roll no type
--   ai_offscreen_combat sdc_ai_offscreen wolves / bears bite clients, a client's knife hits, where the host does not look
--   ai_kill_log         sdc_ai_killlog  a log line per zombie death (type, look, crawler, killer, place) + kills per type
--   ai_client_ghosts    sdc_ai_ghosts   client: its own AI spawners stopped, zombies / bosses / animals that exist only there removed
--   ai_zombie_fx        sdc_ai_fx       the grenadier's beep / explosion and the acidic zombie's death burst on the clients
--   ai_keep_chase       sdc_ai_chase    host: a zombie that loses sight of one player keeps chasing another one it still sees
--   ai_spawn_check_all  sdc_ai_spawnnear host: the spawners' "no spawn within 25 m of player 0" uses the player nearest the spawn point
--   ai_player_scaling   sdc_ai_scale    host: a zombie spawner's group grows with the living players within its SpawnRadius
--   ai_client_optimizer_guard sdc_ai_optguard client (test, off): host AI copies kept from this client's AI optimizer while it is dead
--   ai_client_far_movement sdc_ai_farmove client: zombie copies 122-150 m away keep moving smoothly (the client's optimizer turned it off)
--   ai_host_cap         sdc_ai_cap      host: zombie spawners pause while the world has ai_host_cap_zombies living zombies
--   ai_toughness        sdc_ai_tough    host (off): zombies take less / deal more damage with more players near them
--   ai_horde_beacon     sdc_horde       the Horde Beacon: wave notices and the horde music for the clients
-- (sdc_ai_zombie: read-only zombie description helpers for looks / killlog.)
--
-- Rules (the old all-in-one module froze and then crashed the host):
--   * No zombie wrapper is kept beyond the call that got it. Zombies come only
--     as hook contexts / parameters (fresh), or from one engine actor query
--     (looks) used within the same tick. Kept state is strings and numbers.
--   * No StaticFindObject / FindAllOf on actors, no pass over every zombie,
--     no property tagging of zombies.
--   * Host -> client zombie identity is the engine's own: the host sends the
--     payload (ClientMessage, reliable) and right after it the zombie as the
--     parameter of APlayerController::ClientRepObjRef, a reliable client RPC
--     made for testing object replication (its body only logs). Both go over
--     the controller's channel in order; the client's net driver maps the
--     object to ITS copy of that zombie, or to nil when it has none.
--   * Hook callbacks never throw and return nothing (UE4SS writes a returned
--     value into the function's result).

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = {
    stats = { objref_sent = 0, objref_failed = 0, objref_got = 0, objref_nil = 0, objref_stale = 0 },
}

local clock = os.clock

-- Feature order = load / tick order.
local FEATURES = {
    { id = "kills",   key = "ai_kill_credit",     default = true,  module = "sdc_ai_kills" },
    { id = "attacks", key = "ai_attack_montages", default = true,  module = "sdc_ai_attacks" },
    { id = "corpses", key = "ai_corpses",         default = true,  module = "sdc_ai_corpses" },
    { id = "hud",     key = "ai_healthbar",       default = true,  module = "sdc_ai_hud" },
    -- was "ai_looks" (default off, and off in every config.ini written so far):
    -- a new key, so the fixed feature is on for everyone
    { id = "looks",   key = "ai_zombie_looks",    default = true,  module = "sdc_ai_looks" },
    { id = "offscreen", key = "ai_offscreen_combat", default = true, module = "sdc_ai_offscreen" },
    { id = "killlog", key = "ai_kill_log",        default = false, module = "sdc_ai_killlog" },
    { id = "ghosts",  key = "ai_client_ghosts",   default = true,  module = "sdc_ai_ghosts" },
    { id = "fx",      key = "ai_zombie_fx",       default = true,  module = "sdc_ai_fx" },
    { id = "chase",   key = "ai_keep_chase",      default = true,  module = "sdc_ai_chase" },
    { id = "spawnnear", key = "ai_spawn_check_all", default = true, module = "sdc_ai_spawnnear" },
    { id = "scale",   key = "ai_player_scaling",  default = true,  module = "sdc_ai_scale" },
    -- needs an in-game test first: off by default
    { id = "optguard", key = "ai_client_optimizer_guard", default = false, module = "sdc_ai_optguard" },
    { id = "farmove", key = "ai_client_far_movement", default = true, module = "sdc_ai_farmove" },
    -- sdc_ai_scale asks it (core.ai_full): a full world gets no bigger groups
    { id = "cap",     key = "ai_host_cap",        default = true,  module = "sdc_ai_cap" },
    -- a gameplay change: the host turns it on
    { id = "tough",   key = "ai_toughness",       default = false, module = "sdc_ai_tough" },
    { id = "horde",   key = "ai_horde_beacon",    default = true,  module = "sdc_horde" },
}
local FEAT = {}
for _, f in ipairs(FEATURES) do
    f.on = false
    FEAT[f.id] = f
end
-- not a config key: the ClientRepObjRef receiver, on while a feature uses it
FEAT.objref = { id = "objref", on = false }

local OBJ_TTL = 2.0             -- payload -> ClientRepObjRef: same packet in practice
local NATIVE_RETRY_S = 60
local BP_RETRY_S = 2            -- a Blueprint class not loaded yet: first retry, then doubled
local BP_RETRY_MAX_S = 30       -- ... up to this; again from BP_RETRY_S in a new world
local OBJREF_FN = "/Script/Engine.PlayerController:ClientRepObjRef"

-- ---------------------------------------------------------------------------
-- The API the feature modules get (they never require this module)
-- ---------------------------------------------------------------------------

local core = {
    S = { role = "unknown", remote_pcs = {} },
    ZOMBIE_CLASS = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C",
    BANDIT_CLASS = "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C",
    BOSS_CLASS = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C",
    ANIMAL_CLASS = "/Game/AI/Animals/BP_Animal.BP_Animal_C",
    -- host: remote players with a pawn this tick: { pc, key, X, Y, Z, sent }
    host = { active = false, viewers = {} },
}
core.ZM = core.ZOMBIE_CLASS .. ":"
core.BOSS = core.BOSS_CLASS .. ":"

function core.on(id)
    local f = FEAT[id]
    return f ~= nil and f.on == true
end

local first_counts = {}
-- true for the first `n` calls with this key (log the first few events only)
function core.first(key, n)
    local c = (first_counts[key] or 0) + 1
    first_counts[key] = c
    return c <= (n or 3) or log.debug_enabled == true
end

-- The log function for a per-actor event line: log.info for the first `n`
-- with this key, then log.debug while debug is on, else nil (nothing to
-- format: callers build the arguments only when they got one).
--   local say = core.line("looks.zeroed", 2)
--   if say then say("ai: looks: %s ...", ue.short(z)) end
-- Keys are not shared with core.first.
function core.line(key, n)
    local c = (first_counts[key] or 0) + 1
    first_counts[key] = c
    if c <= (n or 3) then return log.info end
    if log.debug_enabled == true then return log.debug end
    return nil
end

function core.is_remote_pc(o)
    return ue.valid(o) and ue.valid(ue.prop(o, "NetConnection"))
end

function core.has_tag(actor, tag)
    if not ue.valid(actor) then return false end
    local ok, r = pcall(function() return actor:ActorHasTag(FName(tag)) end)
    return ok and r == true
end

function core.cvar_bool(name, default)
    local ksl = ue.ksl()
    if not ksl then return default end
    local ok, v = pcall(function() return ksl:GetConsoleVariableBoolValue(name) end)
    if ok and type(v) == "boolean" then return v end
    return default
end

-- Is `o` an instance of the Blueprint class at `class_path`? Cached by class
-- name (strings only); the class object is looked up by its path each time a
-- new class name is seen.
local isa_cache = {}
local function isa(o, class_path)
    local cn = ue.class_name(o)
    if cn == "" then return false end
    local key = cn .. "|" .. class_path
    local c = isa_cache[key]
    if c ~= nil then return c end
    local cls = ue.find_object(class_path)
    if not cls then return false end   -- not loaded: no instance can exist; not cached
    local ok, r = pcall(function() return o:IsA(cls) end)
    if not ok then return false end
    isa_cache[key] = r == true
    return r == true
end
function core.is_zombie(o) return isa(o, core.ZOMBIE_CLASS) end
function core.is_bandit(o) return isa(o, core.BANDIT_CLASS) end
function core.is_boss(o) return isa(o, core.BOSS_CLASS) end
function core.is_animal(o) return isa(o, core.ANIMAL_CLASS) end
M.isa = isa   -- sdc_npc: the same class test and cache

-- Mesh pose ticking (CharacterMeshComponent.VisibilityBasedAnimTickOption):
-- the AI's mesh animates and refreshes its bones on the host even while the
-- host does not render it.
core.ALWAYS_TICK = 0             -- EVisibilityBasedAnimTickOption::AlwaysTickPoseAndRefreshBones
core.TICK_PROP = "VisibilityBasedAnimTickOption"

-- The mesh of `actor` -> AlwaysTickPoseAndRefreshBones. Returns its previous
-- value when this changed it (`unknown` when it could not be read), nil when
-- it was set already, or there is no mesh, or the write failed.
function core.full_pose(actor, unknown)
    local mesh = ue.prop(actor, "Mesh")
    if not ue.valid(mesh) then return nil end
    local v = ue.prop(mesh, core.TICK_PROP)
    if v == core.ALWAYS_TICK then return nil end
    if not ue.set_prop(mesh, core.TICK_PROP, core.ALWAYS_TICK) then return nil end
    if type(v) == "number" then return v end
    return unknown
end

local function m_current_montage(a) return a:GetCurrentMontage() end
local function m_anim_instance(mesh) return mesh:GetAnimInstance() end
local function m_montage_pos(anim, m) return anim:Montage_GetPosition(m) end

-- The montage `actor` plays now, or nil.
function core.current_montage(actor)
    local ok, m = pcall(m_current_montage, actor)
    if ok and ue.valid(m) then return m end
    return nil
end

-- The montage `actor` plays if it started at most `fresh_s` ago (its position;
-- an unknown position counts as fresh), or nil (none, or one already running).
function core.fresh_montage(actor, fresh_s)
    local m = core.current_montage(actor)
    if not m then return nil end
    local mesh = ue.prop(actor, "Mesh")
    local oka, anim = false, nil
    if ue.valid(mesh) then oka, anim = pcall(m_anim_instance, mesh) end
    if oka and ue.valid(anim) then
        local okp, pos = pcall(m_montage_pos, anim, m)
        if okp and type(pos) == "number" and pos > fresh_s then return nil end
    end
    return m
end
M.core = core   -- sdc_npc: the shared helpers above (full_pose, fresh_montage)

-- The remote player's controller behind a damage instigator / causer, or nil
-- (the host, an AI, the world). Used right away, never stored.
function core.remote_pc_of(instigator, causer)
    if core.is_remote_pc(instigator) then return instigator end
    if not ue.valid(causer) then return nil end
    local e = ctx.player_for(causer)
    if e and core.is_remote_pc(e.pc) then return e.pc end
    -- redirect_player0 off (empty ctx map), projectiles, traps: walk it here
    local o = causer
    for _ = 1, 4 do
        if not ue.valid(o) then break end
        if core.is_remote_pc(o) then return o end
        local c = ue.prop(o, "Controller")
        if core.is_remote_pc(c) then return c end
        c = ue.try(function() return o:GetInstigatorController() end)
        if core.is_remote_pc(c) then return c end
        o = ue.try(function() return o:GetOwner() end)
    end
    return nil
end

-- Remote controllers are remembered by full name; the live wrapper is the
-- session's of this tick.
function core.pc_by_key(key)
    if not key then return nil end
    for _, pc in ipairs(core.S.remote_pcs or {}) do
        if ue.valid(pc) and ue.name(pc) == key then return pc end
    end
    return nil
end

-- Host: viewers within `range` cm of `loc` (positions are this tick's).
function core.viewers_near(loc, range)
    local out = {}
    if not loc then return out end
    local r2 = range * range
    for _, v in ipairs(core.host.viewers) do
        local dx, dy, dz = v.X - loc.X, v.Y - loc.Y, v.Z - loc.Z
        if dx * dx + dy * dy + dz * dz <= r2 and ue.valid(v.pc) then out[#out + 1] = v end
    end
    return out
end

-- Host: payload message, then the object it is about (see the header).
function core.send_with_obj(pc, obj, kind, ...)
    if not ue.valid(obj) then return false end
    if not net.send_to(pc, kind, ...) then return false end
    local ok, err = pcall(function() pc:ClientRepObjRef(obj) end)
    if ok then
        M.stats.objref_sent = M.stats.objref_sent + 1
    else
        M.stats.objref_failed = M.stats.objref_failed + 1
        log.err_throttled("ai.objref", "ai: ClientRepObjRef failed: %s", tostring(err))
    end
    return ok
end

-- Client: the payload waits for its object (one slot: the host always sends
-- the pair back to back on one reliable channel).
local pending = nil            -- { what, data, t }
local OBJ_HANDLERS = {}        -- [what] = { feature, fn(obj, data) }
function core.expect_obj(what, data)
    pending = { what = what, data = data, t = clock() }
end
function core.on_obj(what, feature, fn)
    OBJ_HANDLERS[what] = { feature = feature, fn = fn }
end

-- ---------------------------------------------------------------------------
-- Hooks: one RegisterHook per function, shared by the features that need it
-- ---------------------------------------------------------------------------

local HOOKS = {}       -- [path] = { path, native, bp = {}, pre = {}, post = {}, installed, next_try, wait, label }
local HOOK_ORDER = {}

-- An entry runs now (dispatch): another module's entry (M.hook_external) by
-- its own gate, a feature's in its role while the feature is on (`always`:
-- also while it is off).
local function runs(x, role)
    if x.gate then
        local ok, on = pcall(x.gate)
        return ok and on == true
    end
    return x.role == role and (x.always or FEAT[x.feature].on)
end

local function dispatcher(list)
    return function(...)
        local role = core.S.role
        for i = 1, #list do
            local h = list[i]
            if runs(h, role) then
                local ok, err = pcall(h.fn, ...)
                if not ok then log.err_throttled("ai." .. h.name, "ai: %s: %s", h.name, tostring(err)) end
            end
        end
    end
end

local function hook_entry(path, kind)
    local h = HOOKS[path]
    if not h then
        h = { path = path, native = kind ~= "bp", bp = {}, pre = {}, post = {},
              installed = false, next_try = 0,
              label = path:match("([^%.:]+:[^:]+)$") or path }
        HOOKS[path] = h
        HOOK_ORDER[#HOOK_ORDER + 1] = h
    end
    return h
end

-- spec: { path, kind = "bp" | "pre" | "post", role = "host" | "client",
--         feature, name, fn, always (run even with the feature off: balanced
--         pre / post pairs), alone (host: needed with no client connected
--         too) }. Declares only; core installs on first need.
function core.hook(spec)
    local h = hook_entry(spec.path, spec.kind)
    local list = h[spec.kind]
    list[#list + 1] = { role = spec.role, feature = spec.feature, fn = spec.fn, always = spec.always,
                        alone = spec.alone, name = spec.name or (spec.feature .. "." .. h.label) }
end

-- Another module's callback on a function this core hooks too (sdc_npc: the
-- boss's MeleeAttack / DeathEvent, the humans' StopBurning): one engine hook
-- for both. spec: { path, kind = "bp" | "pre", name, fn, gate = fn() -> true
-- while fn may run, need = fn() -> true while the hook is wanted installed }.
-- Independent of the AI features and of this module's role (the gate decides);
-- installed by M.install_now (the caller's tick) or the AI ticks. Returns a
-- handle: handle.installed.
function M.hook_external(spec)
    local h = hook_entry(spec.path, spec.kind)
    local list = h[spec.kind]
    list[#list + 1] = { gate = spec.gate, need = spec.need, fn = spec.fn, name = spec.name or h.label }
    return h
end

-- Installed once a feature that is on needs it in this role; host hooks wait
-- for the first remote player unless marked `alone`. Another module's entry
-- is wanted while its gate and its need say so.
local function needed(h)
    local role = core.S.role
    for _, kind in ipairs({ "bp", "pre", "post" }) do
        for _, x in ipairs(h[kind]) do
            if x.gate then
                if x.gate() == true and (not x.need or x.need() == true) then return true end
            elseif x.role == role and FEAT[x.feature].on and (role ~= "host" or core.host.active or x.alone) then
                return true
            end
        end
    end
    return false
end

local function install_hooks(now)
    for _, h in ipairs(HOOK_ORDER) do
        if not h.installed and now >= h.next_try and needed(h) then
            local ok, err
            if h.native then
                if #h.post == 0 and ue.hook_native then
                    -- pre only: one shared engine hook (sdc_ue.hook_native), no empty
                    -- post callback (UE4SS wraps every parameter again for it)
                    ok, err = ue.hook_native(h.path, "ai." .. h.label, dispatcher(h.pre))
                else
                    ok, err = pcall(RegisterHook, h.path, dispatcher(h.pre), dispatcher(h.post))
                end
            else
                -- Blueprint function: UE4SS calls it after the function ran
                ok, err = pcall(RegisterHook, h.path, dispatcher(h.bp))
            end
            if ok then
                h.installed = true
                log.info("ai: hook %s ok", h.label)
            elseif h.native then
                h.next_try = now + NATIVE_RETRY_S
                log.warn("ai: hook %s FAILED: %s", h.label, tostring(err))
            else
                -- the Blueprint class is not loaded yet (it loads with its first
                -- actor): retry, less often each time (BP_RETRY_S .. BP_RETRY_MAX_S), log once
                ue.backoff(h, now, BP_RETRY_S, BP_RETRY_MAX_S)
                if not h.logged then
                    h.logged = true
                    log.debug("ai: hook %s not ready yet (%s)", h.label, tostring(err))
                end
            end
        end
    end
end

-- The caller's tick (sdc_npc): installs what is wanted now, at most once a
-- second (the AI ticks install too).
local install_last = -1e9
function M.install_now()
    local now = clock()
    if now - install_last < 1 then return end
    install_last = now
    install_hooks(now)
end

-- PlayerController.ClientRepObjRef(Object), pre (client): the zombie of the
-- payload that came just before. Cheap when nothing is pending.
local function on_objref(_, obj_p)
    local p = pending
    if not p then return end
    pending = nil
    if clock() - p.t > OBJ_TTL then
        M.stats.objref_stale = M.stats.objref_stale + 1
        return
    end
    local h = OBJ_HANDLERS[p.what]
    if not h or not FEAT[h.feature].on then return end
    local o = obj_p and obj_p:get()
    if not ue.valid(o) then
        -- the host's zombie is not replicated to this client (yet / any more)
        M.stats.objref_nil = M.stats.objref_nil + 1
        return
    end
    M.stats.objref_got = M.stats.objref_got + 1
    h.fn(o, p.data)
end
core.hook({ path = OBJREF_FN, kind = "pre", role = "client", feature = "objref", name = "objref", fn = on_objref })

-- ---------------------------------------------------------------------------
-- Features
-- ---------------------------------------------------------------------------

local function config_on(f)
    local v = cfg.get(f.key)
    if v == nil then v = f.default end   -- key not in sdc_config's SCHEMA yet
    return v == true
end

local function load_feature(f)
    local ok, mod = pcall(require, f.module)
    if ok and type(mod) == "table" then
        local oki, err = pcall(mod.init, core)
        if oki then
            f.mod = mod
            return true
        end
        mod = err
    end
    f.broken = true
    log.err("ai: cannot load %s: %s", f.module, tostring(mod))
    return false
end

local function refresh_features()
    for _, f in ipairs(FEATURES) do
        local on = config_on(f) and not f.broken
        if on and not f.mod and not load_feature(f) then on = false end
        if on ~= f.on then
            f.on = on
            log.info("ai: %s %s", f.key, on and "on" or "off")
            -- turned off: a feature that changed live objects gives them back
            -- (mod.off; sdc_ai_optguard: the host copies it froze)
            if not on and f.mod and f.mod.off then
                local ok, err = pcall(f.mod.off)
                if not ok then log.err_throttled("ai.off." .. f.id, "ai: %s off: %s", f.id, tostring(err)) end
            end
        end
    end
    FEAT.objref.on = FEAT.attacks.on or FEAT.looks.on or FEAT.corpses.on or FEAT.hud.on or FEAT.killlog.on
end

-- Any feature enabled in the config (no module loaded, nothing touched).
function M.any_enabled()
    for _, f in ipairs(FEATURES) do
        if config_on(f) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Ticks (1 s, from sdc_session)
-- ---------------------------------------------------------------------------

local function build_viewers(remote_pcs)
    local v = {}
    for _, pc in ipairs(remote_pcs) do
        local p = ue.pawn_of(pc)
        local l = p and ue.location(p)
        if l then v[#v + 1] = { pc = pc, key = ue.name(pc), X = l.X, Y = l.Y, Z = l.Z, sent = 0 } end
    end
    return v
end

-- sdc_ctx asks this for "player 0" of an object that is no remote player's own
-- (a dying zombie / bandit): the killer's controller.
function M.stand_in(wco)
    local f = FEAT.kills
    if not f.on or not f.mod then return nil end
    return f.mod.stand_in(wco)
end
-- sdc_ctx's idle check: M.stand_in answers nil without side effects
M.stand_in_idle = function(a)
    local f = FEAT.kills
    if not f.on or not f.mod then return true end
    local idle = f.mod.stand_in_idle
    if idle ~= nil and idle(a) == true then return true end
    ctx.note_busy("ai:an AI is dying (this object)")
    return false
end
if ctx.set_idle_check then ctx.set_idle_check(M.stand_in, M.stand_in_idle) end

local function update_stand_in()
    local want = nil
    if core.S.role == "host" and FEAT.kills.on and FEAT.kills.mod then want = M.stand_in end
    if want then
        ctx.stand_in = want
    elseif ctx.stand_in == M.stand_in then
        ctx.stand_in = nil
    end
end

function M.host_tick(remote_pcs)
    refresh_features()
    update_stand_in()
    local host = core.host
    remote_pcs = remote_pcs or {}
    host.active = core.S.role == "host" and #remote_pcs > 0
    if core.S.role ~= "host" then
        host.viewers = {}
        return
    end
    local now = clock()
    install_hooks(now)
    if host.active and (FEAT.attacks.on or FEAT.looks.on or FEAT.corpses.on or FEAT.hud.on or FEAT.killlog.on
            or FEAT.offscreen.on or FEAT.fx.on) then
        host.viewers = build_viewers(remote_pcs)
    else
        host.viewers = {}
    end
    for _, f in ipairs(FEATURES) do
        if f.on and f.mod.host_tick then
            local ok, err = pcall(f.mod.host_tick, now)
            if not ok then log.err_throttled("ai.tick." .. f.id, "ai: %s host tick: %s", f.id, tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Entries of AI copies that are gone
-- ---------------------------------------------------------------------------
-- The features keep per-actor entries keyed by the actor's full name. A
-- runtime-spawned actor's name ends in a number above 2,000,000,000 that
-- the engine counts down and never gives out again in this game process,
-- and a client gets a new copy - with a new name - every time a zombie comes
-- back into its net range: entries of copies that are gone are never read
-- again, they only pile up (a client's Lua heap floor grew 20 -> 34-46 MB in
-- 2.5 h; looks' `applied` was cleared only at 4000 entries). Once a minute
-- every registered table loses its keys of runtime-spawned actors that are
-- not in the world any more: one GetAllActorsOfClass(Character) with a name
-- per character, then the tables, in the same call (nothing can be added in
-- between). Level-placed actors (small numbers) are never touched: they can
-- stream back in under the same name. Nothing else changes: an existing
-- actor keeps every entry.
local SWEEP_S = 60
local SWEEP_LOG_S = 600
local CHARACTER_CLASS = "/Script/Engine.Character"
local swept = {}     -- { { label, fn } }; fn() -> { [table name] = table }
local sweep = { last = -1e9, runs = 0, dropped = 0, logged = -1e9 }
M.sweep_stats = sweep

-- feature modules (client side): register the tables keyed by actor full name
function core.forget_gone(label, fn)
    swept[#swept + 1] = { label = label, fn = fn }
end

-- unique for the whole game process (see above)
local function runtime_name(key)
    local n = tonumber(key:match("_(%d+)$"))
    return n ~= nil and n > 2000000000
end

local function sweep_gone(now)
    if #swept == 0 or now - sweep.last < SWEEP_S then return end
    sweep.last = now
    local tabs = {}
    for _, s in ipairs(swept) do
        local ok, list = pcall(s.fn)
        if ok and type(list) == "table" then
            for name, t in pairs(list) do
                if type(t) == "table" and next(t) ~= nil then tabs[#tabs + 1] = { label = s.label .. "." .. name, t = t } end
            end
        end
    end
    if #tabs == 0 then return end
    local t0 = clock()
    local out = ue.actors_of(CHARACTER_CLASS)
    if not out then return end
    local live, n = {}, 0
    for _, e in ipairs(out) do
        local a = ue.elem(e)
        if ue.valid(a) then
            live[ue.name(a)] = true
            n = n + 1
        end
    end
    -- the list must hold this player's own character, else nothing is trusted
    local own = ue.local_pawn()
    if n == 0 or (own and not live[ue.name(own)]) then return end
    local dropped, per = 0, {}
    for _, x in ipairs(tabs) do
        local c = 0
        for k in pairs(x.t) do
            if type(k) == "string" and not live[k] and runtime_name(k) then
                x.t[k] = nil
                c = c + 1
            end
        end
        if c > 0 then
            per[#per + 1] = x.label .. " " .. c
            dropped = dropped + c
        end
    end
    sweep.runs, sweep.dropped = sweep.runs + 1, sweep.dropped + dropped
    if dropped > 0 and now - sweep.logged >= SWEEP_LOG_S then
        sweep.logged = now
        log.info("ai: forgot %d entries of AI copies no longer in this world (%s); %d characters here, %.0f ms;"
            .. " %d forgotten since the start", dropped, table.concat(per, ", "), n, (clock() - t0) * 1000,
            sweep.dropped)
    end
end

-- ---------------------------------------------------------------------------
-- The client tick: timed per feature, at most CT.BUDGET_S of it per frame
-- ---------------------------------------------------------------------------
-- 13.11 (0.8.1): the client's [PERF] showed "c:ai (max 102-174 ms)" in 11 of
-- 38 windows and "[SLOW] mod task 'session-client-b' held the game for 118 /
-- 183 ms", with no way to tell which feature: they all ran back to back in
-- one call. Now every step (the hook install, each feature's client_tick,
-- the sweep) is timed as "c:ai.<feature>" and is the part [SLOWLOG] names
-- while it runs (sdc_ue.part). The steps of each [PERF] window get a line of
-- their own right after it, "[PERF] ai steps" (M.perf_report from main.lua:
-- ms/s and the worst call, "max N ms"), not [PERF] "parts": that list keeps
-- its top 10 and c:ai is in it whole already, so 5-7 c:ai.* entries would
-- push c:damage, c:widgets, f:ui ... out of it. [HITCH] names the slowest
-- step since its previous tick with the task it ran in (M.take_worst_step,
-- sdc_diag): sdc_ue's longest part is c:ai itself in session-client-b and
-- nothing in ai-client-rest.
-- Once the steps of one tick have used CT.BUDGET_S, the
-- rest runs CT.CARRY_MS later, in a task of its own ("ai-client-rest":
-- [PERF] tasks, [SLOW] lines) and again within the budget, so the steps of
-- one second no longer pile into one frame. Every step still runs once per
-- tick, in the same order. A step that is slow by itself stays slow (its
-- feature's own budget decides that, e.g. looks' PASS_BUDGET_S); a tick of
-- CT.SLOW_S or more is logged once a minute at most with each step's time
-- ("ai: client tick took ..."); sdcoop_status lists the slowest steps.
local CT = {
    BUDGET_S = 0.005,      -- feature work per frame; the rest of the tick goes to a later frame
    CARRY_MS = 30,         -- ... this much later
    SLOW_S = 0.05,         -- a tick (all its steps) this long is logged with each step's time
    SLOW_LOG_S = 60,
    gen = 0,               -- M.reset: a rest of the previous world / role does nothing
    round = nil,           -- the tick in progress: { gen, steps, i, ms = { [id] = ms }, order, total, carried }
    logged = -1e9,
    -- the [PERF] window's steps ("[PERF] ai steps"): t0, steps = { [id] = { calls, ms, max } },
    -- the client_tick_stats counters at its start
    win = { t0 = clock(), steps = {}, ticks = 0, carried = 0, late = 0 },
    worst = { ms = 0 },    -- the slowest step since sdc_diag took it ([HITCH]): { ms, label, task }
}
-- rests: carried rests that ran in their own task; late: run by the next tick instead
M.client_tick_stats = { ticks = 0, carried = 0, rests = 0, late = 0, slow = 0, worst_ms = 0, worst = nil,
                        steps = {} }   -- steps: [id] = { calls, ms, max }

-- One step, timed: the window's "[PERF] ai steps" (CT.win), the slowest
-- step for [HITCH] (CT.worst, with the task it ran in: sdc_ue.running),
-- sdcoop_status (client_tick_stats.steps), and sdc_ue.part while it runs.
local function timed_step(id, fn, now)
    local label = "c:ai." .. id
    local prev = ue.part
    ue.part = label
    local t0 = clock()
    local ok, err = pcall(fn, now)
    local ms = (clock() - t0) * 1000
    ue.part = prev
    if not ok then log.err_throttled("ai.tick." .. id, "ai: %s client tick: %s", id, tostring(err)) end
    local w = CT.win.steps[id]
    if not w then w = { calls = 0, ms = 0, max = 0 }; CT.win.steps[id] = w end
    w.calls, w.ms = w.calls + 1, w.ms + ms
    if ms > w.max then w.max = ms end
    local worst = CT.worst
    if ms > worst.ms then worst.ms, worst.label, worst.task = ms, label, ue.running end
    local st = M.client_tick_stats.steps[id]
    if not st then st = { calls = 0, ms = 0, max = 0 }; M.client_tick_stats.steps[id] = st end
    st.calls, st.ms = st.calls + 1, st.ms + ms
    if ms > st.max then st.max = ms end
    return ms
end

-- The steps of one tick, in FEATURES order, then the sweep. Each is looked
-- up again when it runs (a feature turned off meanwhile is skipped).
local function client_steps()
    local steps = {}
    for _, f in ipairs(FEATURES) do
        if f.on and f.mod and f.mod.client_tick then steps[#steps + 1] = f end
    end
    steps[#steps + 1] = "sweep"
    return steps
end

local function run_step(s)
    if s == "sweep" then return "sweep", sweep_gone end
    if s.on and s.mod and s.mod.client_tick then return s.id, s.mod.client_tick end
    return nil
end

local function round_done(r)
    CT.round = nil
    local cs = M.client_tick_stats
    if r.total > cs.worst_ms then cs.worst_ms, cs.worst = r.total, r.ms end
    if r.total < CT.SLOW_S * 1000 then return end
    cs.slow = cs.slow + 1
    local now = clock()
    if now - CT.logged < CT.SLOW_LOG_S then return end
    CT.logged = now
    local parts = {}
    for _, id in ipairs(r.order) do parts[#parts + 1] = string.format("%s %.0f", id, r.ms[id]) end
    log.info("ai: client tick took %.0f ms in all (%s ms)%s", r.total, table.concat(parts, ", "),
        r.carried > 0 and string.format("; %d part(s) of it ran in later frames", r.carried) or "")
end

local carry_rest

-- Runs the round's steps from r.i on until the budget of this frame is used;
-- `t0` = when this frame's share started (the prelude counts too). Returns
-- true when the rest was carried to a later frame.
local function run_round(r, t0)
    while r.i <= #r.steps do
        local id, fn = run_step(r.steps[r.i])
        r.i = r.i + 1
        if id then
            local ms = timed_step(id, fn, clock())
            r.ms[id] = (r.ms[id] or 0) + ms
            r.order[#r.order + 1] = id
            r.total = r.total + ms
        end
        if r.i <= #r.steps and not r.now_all and clock() - t0 >= CT.BUDGET_S then return carry_rest(r) end
    end
    round_done(r)
    return false
end

-- The rest of a round a few frames later (its own task); all of it at once
-- when no delayed call can be made (as before the budget). A rest whose
-- delayed call has not come by the next tick is run by that tick first.
carry_rest = function(r)
    local function rest()
        if CT.round ~= r or r.gen ~= CT.gen or core.S.role ~= "client" then return end
        M.client_tick_stats.rests = M.client_tick_stats.rests + 1
        run_round(r, clock())
    end
    local cs = M.client_tick_stats
    r.carried, cs.carried = r.carried + 1, cs.carried + 1
    local ok, h = false, nil
    if type(ue.delay) == "function" then ok, h = pcall(ue.delay, "ai-client-rest", CT.CARRY_MS, rest) end
    if not ok or h == false then
        r.carried, cs.carried = r.carried - 1, cs.carried - 1
        r.now_all = true
        return run_round(r, clock())
    end
    return true
end
M._CT = CT   -- tests

function M.client_tick()
    local t0 = clock()
    refresh_features()
    update_stand_in()
    core.host.active = false
    core.host.viewers = {}
    if core.S.role ~= "client" then
        CT.round = nil
        return
    end
    local now = clock()
    timed_step("hooks", install_hooks, now)
    if pending and now - pending.t > OBJ_TTL then
        pending = nil
        M.stats.objref_stale = M.stats.objref_stale + 1
    end
    -- the previous tick's rest did not get its frame (its delayed call is
    -- late or lost): it runs first, then this tick's own steps (no step is
    -- left out for good; under a long load the steps go round slower)
    local r = CT.round
    if r and r.gen == CT.gen then
        M.client_tick_stats.late = M.client_tick_stats.late + 1
        if run_round(r, t0) then return end
    end
    M.client_tick_stats.ticks = M.client_tick_stats.ticks + 1
    r = { gen = CT.gen, steps = client_steps(), i = 1, ms = {}, order = {}, total = 0, carried = 0 }
    CT.round = r
    run_round(r, t0)
end

-- sdcoop_status: the client tick's steps, slowest first (worst call / average)
local function client_tick_line()
    local cs = M.client_tick_stats
    if cs.ticks == 0 then return nil end
    local list = {}
    for id, s in pairs(cs.steps) do list[#list + 1] = { id = id, s = s } end
    table.sort(list, function(a, b) return a.s.max > b.s.max end)
    local parts = {}
    for i = 1, math.min(6, #list) do
        local e = list[i]
        parts[#parts + 1] = string.format("%s max %.0f avg %.1f", e.id, e.s.max, e.s.ms / math.max(1, e.s.calls))
    end
    return string.format("ai client tick: %d ticks, %d carried to a later frame (%d ran by the next tick), %d over"
        .. " %.0f ms | ms: %s", cs.ticks, cs.carried, cs.late, cs.slow, CT.SLOW_S * 1000, table.concat(parts, ", "))
end

-- "[PERF] ai steps" (main.lua, right after each [PERF] line): the client
-- tick's steps of that window, worst call first, and how often a rest went
-- to a later frame; then a new window. Nothing is logged when no step ran
-- (a host, the menus). Returns the line (tests).
function M.perf_report()
    local w, now, cs = CT.win, clock(), M.client_tick_stats
    CT.win = { t0 = now, steps = {}, ticks = cs.ticks, carried = cs.carried, late = cs.late }
    local list = {}
    for id, s in pairs(w.steps) do list[#list + 1] = { id = id, s = s } end
    if #list == 0 then return nil end
    table.sort(list, function(a, b)
        if a.s.max ~= b.s.max then return a.s.max > b.s.max end
        return a.id < b.id
    end)
    local dt = math.max(0.001, now - w.t0)
    local parts = {}
    for i, e in ipairs(list) do
        parts[i] = string.format("c:ai.%s %.1fms/s (max %.0fms)", e.id, e.s.ms / dt, e.s.max)
    end
    local line = string.format("[PERF] ai steps %.0fs: %s | %d ticks, %d carried to a later frame, %d run by the"
        .. " next tick", dt, table.concat(parts, ", "), cs.ticks - w.ticks, cs.carried - w.carried, cs.late - w.late)
    log.info("%s", line)
    return line
end

-- [HITCH] (sdc_diag, every second): the slowest step since the last call,
-- { ms, label, task } (task: sdc_ue.running then, e.g. "ai-client-rest"),
-- and a new record from now on.
function M.take_worst_step()
    local w = CT.worst
    CT.worst = { ms = 0 }
    return w
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- Touches no engine object: features load and hooks install from the ticks.
function M.init(state)
    core.S = state
end

-- Role or world change. Drops every per-session table without touching an
-- object; hooks stay registered (gated by role and feature).
function M.reset(why)
    pending = nil
    -- a client tick's rest still waiting belongs to the old world / role
    CT.gen, CT.round = CT.gen + 1, nil
    core.host.active = false
    core.host.viewers = {}
    -- a new world loads its classes again: hooks still missing are retried soon
    for _, h in ipairs(HOOK_ORDER) do
        if not h.installed and not h.native then h.wait, h.next_try = nil, 0 end
    end
    for _, f in ipairs(FEATURES) do
        if f.mod and f.mod.reset then
            local ok, err = pcall(f.mod.reset, why)
            if not ok then log.err("ai: %s reset: %s", f.id, tostring(err)) end
        end
    end
    log.debug("ai: reset (%s)", tostring(why))
end

-- Message kind -> feature. Registering a handler touches nothing; each runs
-- only while its feature is on.
local MESSAGES = { AIKILL = "kills", AIDAY = "kills", AIM = "attacks", AIAPP = "looks", AIAPPQ = "looks",
                   AIDEAD = "corpses", AIHP = "hud", AIHPQ = "hud", AIKL = "killlog", AIFX = "fx", HORDE = "horde" }

function M.register_handlers()
    for kind, id in pairs(MESSAGES) do
        net.on(kind, function(f, pc)
            local feat = FEAT[id]
            if not feat.on or not feat.mod or not feat.mod.on_message then return end
            feat.mod.on_message(kind, f, pc)
        end)
    end
end

function M.status_lines()
    local s = M.stats
    local parts, n_hooks, n_installed = {}, 0, 0
    for _, f in ipairs(FEATURES) do parts[#parts + 1] = f.id .. "=" .. (f.on and "on" or "off") end
    for _, h in ipairs(HOOK_ORDER) do
        if needed(h) or h.installed then
            n_hooks = n_hooks + 1
            if h.installed then n_installed = n_installed + 1 end
        end
    end
    local lines = {
        string.format("ai: %s | hooks %d/%d | objref sent=%d failed=%d got=%d nil=%d stale=%d",
            table.concat(parts, " "), n_installed, n_hooks, s.objref_sent, s.objref_failed, s.objref_got,
            s.objref_nil, s.objref_stale),
    }
    local ct = client_tick_line()
    if ct then lines[#lines + 1] = ct end
    for _, f in ipairs(FEATURES) do
        if f.mod and f.mod.status_line then
            local ok, line = pcall(f.mod.status_line)
            if ok and line then lines[#lines + 1] = line end
        end
    end
    return lines
end

return M
