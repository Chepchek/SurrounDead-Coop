-- SDCoop: zombies in co-op. Core of nine independent features.
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
    { id = "killlog", key = "ai_kill_log",        default = true,  module = "sdc_ai_killlog" },
    { id = "ghosts",  key = "ai_client_ghosts",   default = true,  module = "sdc_ai_ghosts" },
    { id = "fx",      key = "ai_zombie_fx",       default = true,  module = "sdc_ai_fx" },
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
local BP_RETRY_S = 2
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
core.BM = core.BANDIT_CLASS .. ":"
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

local HOOKS = {}       -- [path] = { path, native, bp = {}, pre = {}, post = {}, installed, next_try, label }
local HOOK_ORDER = {}

local function dispatcher(list)
    return function(...)
        local role = core.S.role
        for i = 1, #list do
            local h = list[i]
            if h.role == role and (h.always or FEAT[h.feature].on) then
                local ok, err = pcall(h.fn, ...)
                if not ok then log.err_throttled("ai." .. h.name, "ai: %s: %s", h.name, tostring(err)) end
            end
        end
    end
end

-- spec: { path, kind = "bp" | "pre" | "post", role = "host" | "client",
--         feature, name, fn, always (run even with the feature off: balanced
--         pre / post pairs), alone (host: needed with no client connected
--         too) }. Declares only; core installs on first need.
function core.hook(spec)
    local h = HOOKS[spec.path]
    if not h then
        h = { path = spec.path, native = spec.kind ~= "bp", bp = {}, pre = {}, post = {},
              installed = false, next_try = 0,
              label = spec.path:match("([^%.:]+:[^:]+)$") or spec.path }
        HOOKS[spec.path] = h
        HOOK_ORDER[#HOOK_ORDER + 1] = h
    end
    local list = h[spec.kind]
    list[#list + 1] = { role = spec.role, feature = spec.feature, fn = spec.fn, always = spec.always,
                        alone = spec.alone, name = spec.name or (spec.feature .. "." .. h.label) }
end

-- Installed once a feature that is on needs it in this role; host hooks wait
-- for the first remote player unless marked `alone`.
local function needed(h)
    local role = core.S.role
    for _, kind in ipairs({ "bp", "pre", "post" }) do
        for _, x in ipairs(h[kind]) do
            if x.role == role and FEAT[x.feature].on and (role ~= "host" or core.host.active or x.alone) then
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
                -- the Blueprint class is not loaded yet: retry, log once
                h.next_try = now + BP_RETRY_S
                if not h.logged then
                    h.logged = true
                    log.debug("ai: hook %s not ready yet (%s)", h.label, tostring(err))
                end
            end
        end
    end
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
M.stand_in_idle = function()
    local f = FEAT.kills
    if not f.on or not f.mod then return true end
    local idle = f.mod.stand_in_idle
    return idle ~= nil and idle() == true
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

local function m_get(e) return e:get() end
local function m_all_actors(gps, wc, cls, out) gps:GetAllActorsOfClass(wc, cls, out) end

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
    local cls = ue.find_object(CHARACTER_CLASS)
    local gps, wc = ue.gameplay_statics(), ue.local_pc()
    if not cls or not gps or not wc then return end
    local t0 = clock()
    local out = {}
    if not pcall(m_all_actors, gps, wc, cls, out) then return end
    local live, n = {}, 0
    for _, e in ipairs(out) do
        local ok, a = pcall(m_get, e)
        if not ok then a = e end
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

function M.client_tick()
    refresh_features()
    update_stand_in()
    core.host.active = false
    core.host.viewers = {}
    if core.S.role ~= "client" then return end
    local now = clock()
    install_hooks(now)
    if pending and now - pending.t > OBJ_TTL then
        pending = nil
        M.stats.objref_stale = M.stats.objref_stale + 1
    end
    for _, f in ipairs(FEATURES) do
        if f.on and f.mod.client_tick then
            local ok, err = pcall(f.mod.client_tick, now)
            if not ok then log.err_throttled("ai.tick." .. f.id, "ai: %s client tick: %s", f.id, tostring(err)) end
        end
    end
    local ok, err = pcall(sweep_gone, now)
    if not ok then log.err_throttled("ai.sweep", "ai: forgetting gone copies: %s", tostring(err)) end
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
    core.host.active = false
    core.host.viewers = {}
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
                   AIDEAD = "corpses", AIHP = "hud", AIHPQ = "hud", AIKL = "killlog", AIFX = "fx" }

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
    for _, f in ipairs(FEATURES) do
        if f.mod and f.mod.status_line then
            local ok, line = pcall(f.mod.status_line)
            if ok and line then lines[#lines + 1] = line end
        end
    end
    return lines
end

return M
