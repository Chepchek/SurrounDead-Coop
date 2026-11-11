-- SDCoop: turrets in co-op - bandit camp / settlement turrets (BP_MasterTurret:
-- BP_BanditTurret_AI, BP_SurvivorTurret_AI) and the player's buildable ones
-- (Buildable_TurretMASTER: Buildable_Turret, Buildable_SmallTurret).
--
-- What the game does per machine (work\re\pseudo_turret, game 0.8.0):
--   * Everything that decides runs on the host only. The AI component's
--     BeginPlay (BP_TurretAIComponent @4680 -> @3141, BP_BuildableTurretAI-
--     Component @4726 -> @3187) starts the "Perception Check" (0.25 s) and
--     "Turret Fire" (AttackSpeed 0.3-0.5 s) timers only where IsServer: target
--     choice, the trace, ApplyDamage (players too: Reaction Tags hold 'Player';
--     Bleed), ammo, health (Deduct Health), death.
--   * What a client sees comes from the engine: the actor and its component
--     replicate (bReplicates on both CDOs), "Attack Target" is the only
--     replicated variable (push model) and the copy's own tick turns the head
--     ("Turret" mesh, RInterpTo @3768/@3814) at it; "Multicast Muzzle Effect"
--     (sound + muzzle flash), "Multicast Turret Idle Stop/Start" (the idle
--     sweep timeline) and "Multicast Spawn Emitter" (the death explosion) are
--     NetMulticast. Nothing of it is guaranteed to reach a client: the camp
--     turrets are runtime child actors of the host's camp (sdc_world makes the
--     camp replicate) with the default 150 m net range, the copy's head only
--     turns while its component ticks, and the host's AI optimizer
--     (AIOSubject, layers 100 / 150 m from the HOST's player) Deactivate()s
--     the component on the host: bIsActive replicates, OnRep_IsActive turns
--     the copy's tick off - a client next to a camp the host left saw the
--     turret shoot without turning. On the host itself that turret stopped
--     aiming (tick off) and its trace went where the frozen head pointed.
--   * The bandit turret's "Disable" (hold 5 s, BP_BanditTurret_AI @3232 ->
--     RetriggerableDelay -> @31) runs only on the interacting machine: Dead,
--     Can Attack = false, a BP_TurretGunPickup spawned there, the head mesh
--     destroyed. A client's disable stayed on the client (its log 19:08:49:
--     "items: kept local BP_TurretGunPickup_C (207 cm from own character)"):
--     the host's turret kept shooting it, and the client got a client-only
--     pickup. The host's disable left the head on the clients' copies (they
--     could disable it again: a second, client-only pickup).
--   * A client's bullets: BP_FirearmPickup.Trace_Impact -> Damage_Object
--     (client only, as for barrels) -> BP_MasterTurret @10 "Server Turret
--     Damaged", a NetServer RPC of a component the client does not own: the
--     engine drops it. Clients could not destroy a camp turret.
--   * Buildable turrets show their health (Widget, UpdateHealth) from
--     Current Health, which only the host changes (Deduct Health): a client's
--     bar stayed full.
--
-- What this module does (one message per client per 0.25 s at most, only to
-- the clients in range; no object wrapper kept beyond the call that got it:
-- paths, keys and numbers only; every hook callback returns nothing and is
-- wrapped in pcall). Turrets are named by class code and the host's place,
-- "BT,x,y,z" (a copy's place is the host's, replicated at its spawn); a
-- client matches its copy of the same class within 1.5 m.
--   host  Multicast Muzzle Effect (post, runs on the host for every shot):
--         the shot is counted with the head's rotation; every 0.25 s each
--         client within the fire sound's range gets one TURFIRE with every
--         turret that fired near it (shots, head pitch/yaw).
--   client the same hook marks the turrets whose engine multicast arrived
--         (then the relay's effects are skipped for 3 s: never twice). For
--         the others the copy's head is set to the host's aim (when the copy
--         has no target of its own or does not tick), its idle sweep stopped
--         ("Multicast Turret Idle Stop", resumed 3 s after the last shot) and
--         its own "Multicast Muzzle Effect" runs locally (a multicast called
--         on a client runs there only): the game's flash and fire sound. No
--         copy (beyond the net range): the fire sound at the turret's place,
--         with its attenuation, when it carries that far.
--   host  every second: a turret within 100 m of a remote player whose AI
--         component the host's optimizer switched off is woken with the
--         game's own optimizer handler (layer 0: Activate, meshes, tick);
--         state of the turrets within 140 m of each client (disabled, buildable
--         health) as TURSTATE when it changed for that client.
--   client every second: a copy within 100 m whose component does not tick
--         (the replicated deactivation) is woken the same way; a camp copy
--         that is Dead here without the host saying so was disabled by this
--         player: TUROFF to the host, and this client's own TurretGun pickup
--         next to it goes (the host's comes replicated). TURSTATE: a disabled
--         turret loses its head here (Dead, Can Attack, the head destroyed as
--         the game does); a buildable's health goes into its bar (UpdateHealth).
--   host  TUROFF: the bandit turret's own disable step (@31: IsHeld set
--         first) runs on the host's turret - it stops, its head goes, the
--         game spawns the TurretGun pickup there (replicated to everyone).
--   client Damage_Object (post) of a camp turret by the own character with a
--         firearm in hand (melee already hits on the host's copy of the
--         swing): damage summed per turret, TURHIT every 0.25 s.
--   host  TURHIT: the turret's own "Server Turret Damaged" (runs locally on
--         the server): Deduct Health, at 0 the game's death (explosion
--         multicast, actor destroyed and with it the clients' copies).
--
-- Messages:
--   host -> client  TURFIRE|<sound paths ;>|code,x,y,z,shots,pitch,yaw,sound#|...
--                   TURSTATE|code,x,y,z,dead,hp|...
--   client -> host  TUROFF|code|x|y|z
--                   TURHIT|code,x,y,z,damage|...
--
-- main.lua: require + install(session.state), world reset hook, a 250 ms tick.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = {
    stats = {
        -- host
        shots = 0, fire_msgs = 0, fire_entries = 0, wakes = 0, offs = 0, off_refused = 0, hits = 0, hit_dmg = 0,
        states = 0,
        -- client
        engine = 0, shown = 0, engine_skip = 0, aimed = 0, sound_only = 0, not_audible = 0, no_sound = 0,
        cwakes = 0, offs_sent = 0, pickups_removed = 0, states_applied = 0, heads_removed = 0, hits_sent = 0,
        hit_melee = 0,
    },
}

local S = nil
local clock = os.clock

-- Game paths and names (one table: few top-level locals)
local P = {
    MASTER = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterTurret.BP_MasterTurret_C",
    BUILD = "/Game/Blueprints/BuildingSystem/Actors/Turret/Buildable_TurretMASTER.Buildable_TurretMASTER_C",
    COMP = "/Game/SmartAI/Blueprints/AI/Components/BP_TurretAIComponent.BP_TurretAIComponent_C",
    BCOMP = "/Game/SmartAI/Blueprints/AI/Components/BP_BuildableTurretAIComponent.BP_BuildableTurretAIComponent_C",
    PICKUP = "/Game/Inventory/Items/Pickups/Other/BP_TurretGunPickup.BP_TurretGunPickup_C",
    -- the optimizer handler every turret class has (bIsBeyondLastLayer, LayerIndex, bIsSeen)
    AIO_EVENT = "BndEvt__BP_CookingStation_AIOSubject_K2Node_ComponentBoundEvent_0_OnOptimizationUpdate__DelegateSignature",
    BANDIT = "BP_BanditTurret_AI_C",
    DISABLE_FN = "ExecuteUbergraph_BP_BanditTurret_AI",
    DISABLE_ENTRY = 31,   -- @31: end of the 5 s "Disable" hold (IsHeld -> Dead, pickup, head destroyed)
    MUZZLE = "Multicast Muzzle Effect",
    DAMAGED = "Server Turret Damaged",
    IDLE_STOP = "Multicast Turret Idle Stop",
    IDLE_START = "Multicast Turret Idle Start",
    -- class -> short code on the wire, and its kind (camp: BP_TurretAIComponent, build: the buildable one)
    CODES = { BP_BanditTurret_AI_C = "BT", BP_SurvivorTurret_AI_C = "ST", Buildable_Turret_C = "PT",
              Buildable_SmallTurret_C = "PS" },
    KINDS = { BP_BanditTurret_AI_C = "camp", BP_SurvivorTurret_AI_C = "camp", Buildable_Turret_C = "build",
              Buildable_SmallTurret_C = "build" },
    FIREARM_SLOTS = { "PrimaryWeapon", "SecondaryWeapon", "SidearmWeapon" },
}

-- Tunables
local C = {
    FLUSH_S = 0.25,          -- TURFIRE / TURHIT batches
    PASS_S = 1.0,            -- registry, wake, state, disable passes
    WAKE_CM = 10000,         -- the optimizer's layer 0 (AIOSubject OptimizationLayers[0])
    NEAR_CM = 15000,         -- the turret's net range (copies exist within it)
    STATE_CM = 14000,        -- TURSTATE: a copy is there
    MATCH_CM = 150,          -- a key's place -> the copy here (same class), nearest
    FIRE_RANGE = 20000,      -- when the fire sound's range is unknown
    MARGIN = 500,            -- players move while a message travels
    ENGINE_S = 3.0,          -- an engine multicast this recent: the relay's effects are skipped
    IDLE_RESUME_S = 3.0,     -- after the last relayed shot: the idle sweep again
    MAX_ENTRIES = 16,        -- per message
    HIT_MAX = 1000,          -- damage per turret and message
    OFF_REACH_CM = 1500,     -- TUROFF: the player must be at the turret
    HIT_REACH_CM = 40000,    -- TURHIT: within a firearm's reach
    PICKUP_CM = 400,         -- this client's own TurretGun pickup next to its disabled copy
    PENDING_S = 30,          -- TURSTATE entries kept for a copy that is not here yet
    SUMMARY_S = 60,
    LOG_FIRST = 10,          -- first-event lines per kind
}

local st = {}

local function fresh_state()
    st.fire = {}             -- host: [key] = { code, x, y, z, n, pitch, yaw, sound = { path, range } }
    st.fired_logged = {}     -- host: [key] = true
    st.host_reg = {}         -- host: registry entries (path, code, kind, cls, x, y, z, key)
    st.sent = {}             -- host: [pc name] = { [key] = state text }
    st.woken = {}            -- host: [key] = times
    st.client_reg = {}       -- client: registry entries
    st.engine = {}           -- client: [copy path] = clock of the last engine multicast
    st.relayed = {}          -- client: [copy path] = { t, idle_stopped }
    st.seen = {}             -- client: [copy path] = true (first-seen line)
    st.off_sent = {}         -- client: [copy path] = clock
    st.off_host = {}         -- client: [copy path] = true (the host said: disabled)
    st.cwoken = {}           -- client: [copy path] = times
    st.pending = {}          -- client: [host key] = { code, x, y, z, dead, hp, t }
    st.hits = {}             -- client: [key] = { code, x, y, z, dmg, n }
    st.nocopy_logged = {}    -- client: [key] = true
    st.applying = false
    st.flush_t, st.pass_due = 0, 0
    st.counts = {}           -- first-event line counters
end
fresh_state()
st.hooks_next = 0
st.sounds = {}               -- host: [code] = { path, range } (the class's FireSound)
st.summary = { t = 0, last = "" }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function enabled()
    local v = cfg.get("turret_sync")
    if v == nil then return true end
    return v == true
end

local function coop() return S ~= nil and (S.role == "host" or S.role == "client") end

local function first(kind, n)
    local c = (st.counts[kind] or 0) + 1
    st.counts[kind] = c
    return c <= (n or C.LOG_FIRST)
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function pt(l) return { x = l.X, y = l.Y, z = l.Z } end

local function loc_text(e) return string.format("%.0f %.0f %.0f", e.x, e.y, e.z) end

local function key_of(code, x, y, z) return string.format("%s,%.0f,%.0f,%.0f", code, x, y, z) end

local function split(s, sep)
    local out = {}
    for part in ((s or "") .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
    return out
end

local function bool_text(v)
    if v == nil then return "?" end
    return tostring(v)
end

-- class code, kind, class name of a turret actor (nil when it is none)
local function code_of(a)
    local cls = ue.class_name(a)
    local code, kind = P.CODES[cls], P.KINDS[cls]
    if code then return code, kind, cls end
    if cls == "" then return nil end
    -- another child class: by its AI component
    if ue.valid(ue.prop(a, "BP_BuildableTurretAIComponent")) then return cls, "build", cls end
    if ue.valid(ue.prop(a, "BP_TurretAIComponent")) then return cls, "camp", cls end
    return nil
end

local function comp_of(a, kind)
    return ue.prop(a, kind == "build" and "BP_BuildableTurretAIComponent" or "BP_TurretAIComponent")
end

local function owner_of(comp)
    return ue.try(function() return comp:GetOwner() end)
end

local function is_active(comp) return ue.try(function() return comp:IsActive() end) end
local function is_ticking(comp) return ue.try(function() return comp:IsComponentTickEnabled() end) end

-- live actors of a class in this world; {} when the class is not loaded, false + error when the call failed
local function actors_of(class_path)
    local cls = ue.find_object(class_path)
    local gps = ue.gameplay_statics()
    local wc = ue.local_pc()
    if not cls or not gps or not wc then return {} end
    local out = {}
    local ok, err = pcall(function() gps:GetAllActorsOfClass(wc, cls, out) end)
    if not ok then return false, err end
    local list = {}
    for i = 1, #out do
        local e = out[i]
        local okg, o = pcall(function() return e:get() end)
        if not okg then o = e end
        if ue.valid(o) then list[#list + 1] = o end
    end
    return list
end

-- registry entry of a turret actor: { path, code, kind, cls, x, y, z, key }
local function describe(a)
    local code, kind, cls = code_of(a)
    if not code then return nil end
    local l = ue.location(a)
    if not l then return nil end
    local e = pt(l)
    e.path, e.code, e.kind, e.cls = ue.path(a), code, kind, cls
    e.key = key_of(code, e.x, e.y, e.z)
    return e
end

-- every turret of this world, described; fn(actor, entry) for each (the actor only during the call)
local function scan(fn)
    local reg = {}
    for _, cp in ipairs({ P.MASTER, P.BUILD }) do
        local list, err = actors_of(cp)
        if list == false then
            log.err_throttled("turrets.scan", "turrets: GetAllActorsOfClass failed: %s", tostring(err))
        else
            for _, a in ipairs(list) do
                local e = describe(a)
                if e then
                    reg[#reg + 1] = e
                    if fn then fn(a, e) end
                end
            end
        end
    end
    return reg
end

-- the registry entry of the same class nearest to x, y, z (within MATCH_CM)
local function find_entry(reg, code, x, y, z)
    local best, bd = nil, C.MATCH_CM
    local p = { x = x, y = y, z = z }
    for _, e in ipairs(reg) do
        if e.code == code then
            local d = dist(e, p)
            if d <= bd then best, bd = e, d end
        end
    end
    return best
end

-- the live actor of a registry entry, or nil
local function live(e)
    if not e or not e.path or e.path == "" then return nil end
    local a = ue.find_object(e.path)
    if a and ue.valid(a) then return a end
    return nil
end

local function snd_mod()
    return package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
end

-- the game's optimizer handler with layer 0 (what a player within 100 m gets)
local function wake(a, comp)
    local ok = ue.call(a, P.AIO_EVENT, false, 0, true)
    if not ok then
        -- no handler on this class: what its layer-0 branch does to the component
        ok = pcall(function()
            comp:Activate(true)
            comp:SetComponentTickEnabled(true)
        end)
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

-- the class's fire sound: { path, range } (cached per class code)
local function sound_of(comp, code)
    local s = st.sounds[code]
    if s then return s end
    local snd = ue.prop(comp, "FireSound")
    s = { path = nil, range = C.FIRE_RANGE }
    if ue.valid(snd) then
        local path = ue.path(snd)
        if path:sub(1, 6) == "/Game/" then s.path = path end
        local ok, r = pcall(function() return snd_mod().range_of(snd) end)
        if ok and type(r) == "number" and r > 0 then s.range = r end
    end
    st.sounds[code] = s
    return s
end

-- Multicast Muzzle Effect ran on the host: one shot of this turret.
local function host_on_fire(comp)
    if #(S.remote_pcs or {}) == 0 then return end
    local a = owner_of(comp)
    if not ue.valid(a) then return end
    local code = code_of(a)
    if not code then return end
    local l = ue.location(a)
    if not l then return end
    local key = key_of(code, l.X, l.Y, l.Z)
    local e = st.fire[key]
    if not e then
        e = { code = code, x = l.X, y = l.Y, z = l.Z, n = 0, sound = sound_of(comp, code) }
        st.fire[key] = e
    end
    e.n = e.n + 1
    M.stats.shots = M.stats.shots + 1
    local mesh = ue.prop(a, "Turret")
    if ue.valid(mesh) then
        local r = ue.try(function() return mesh:K2_GetComponentRotation() end)
        local p = r and ue.try(function() return r.Pitch end)
        local y = r and ue.try(function() return r.Yaw end)
        if type(p) == "number" and type(y) == "number" then e.pitch, e.yaw = p, y end
    end
    if not st.fired_logged[key] and first("host.fire") then
        st.fired_logged[key] = true
        local tgt = ue.prop(comp, "Attack Target")
        log.info("turrets: [host] %s (%s at %s) fires on the host: head pitch %.0f yaw %.0f, target %s, AI component"
            .. " active=%s tick=%s; clients within %.0f m get its shots as TURFIRE", ue.short(a), code, loc_text(e),
            e.pitch or 0, e.yaw or 0, ue.valid(tgt) and ue.short(tgt) or "none", bool_text(is_active(comp)),
            bool_text(is_ticking(comp)), (e.sound.range + C.MARGIN) / 100)
    end
end

-- every FLUSH_S: one TURFIRE per client with the turrets that fired within their sound's range of it
local function host_flush()
    if next(st.fire) == nil then return end
    local fire = st.fire
    st.fire = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        local pawn = ue.valid(pc) and ue.pawn_of(pc) or nil
        local l = pawn and ue.location(pawn)
        if l then
            local at = pt(l)
            local sounds, sidx, fields = {}, {}, {}
            for _, e in pairs(fire) do
                if #fields < C.MAX_ENTRIES and dist(at, e) <= e.sound.range + C.MARGIN then
                    local si = 0
                    if e.sound.path then
                        si = sidx[e.sound.path]
                        if not si then
                            sounds[#sounds + 1] = e.sound.path
                            si = #sounds
                            sidx[e.sound.path] = si
                        end
                    end
                    fields[#fields + 1] = string.format("%s,%.0f,%.0f,%.0f,%d,%.1f,%.1f,%d", e.code, e.x, e.y, e.z,
                        math.min(e.n, 99), e.pitch or 0, e.yaw or 0, si)
                end
            end
            if #fields > 0 and net.send_to(pc, "TURFIRE", table.concat(sounds, ";"), table.unpack(fields)) then
                M.stats.fire_msgs = M.stats.fire_msgs + 1
                M.stats.fire_entries = M.stats.fire_entries + #fields
            end
        end
    end
end

-- a turret near a remote player that the host's optimizer switched off
local function host_wake(a, comp, e, who, d)
    local active, ticking = is_active(comp), is_ticking(comp)
    if active ~= false and ticking ~= false then return end
    local ok = wake(a, comp)
    M.stats.wakes = M.stats.wakes + 1
    local n = (st.woken[e.key] or 0) + 1
    st.woken[e.key] = n
    if n <= 2 or n % 20 == 0 then
        log.info("turrets: [host] %s (%s at %s) was switched off by the host's AI optimizer (active=%s tick=%s):"
            .. " woken for %s %.0f m away (ok=%s, now active=%s tick=%s; %d time(s))", ue.short(a), e.code,
            loc_text(e), bool_text(active), bool_text(ticking), who, d / 100, tostring(ok),
            bool_text(is_active(comp)), bool_text(is_ticking(comp)), n)
    end
end

local function players_now()
    local out = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        if ue.valid(pc) then
            local pawn = ue.pawn_of(pc)
            local l = pawn and ue.location(pawn)
            if l then
                local p = pt(l)
                p.pc, p.name, p.who = pc, ue.name(pc), ue.short(pawn)
                out[#out + 1] = p
            end
        end
    end
    return out
end

-- TURSTATE to each client: the turrets within STATE_CM of it whose state changed for it
local function send_states(players, reg)
    local keep = {}
    for _, p in ipairs(players) do
        keep[p.name] = true
        local sent = st.sent[p.name]
        if not sent then
            sent = {}
            st.sent[p.name] = sent
        end
        local fields = {}
        for _, e in ipairs(reg) do
            if e.state and sent[e.key] ~= e.state and dist(p, e) <= C.STATE_CM then
                if e.state == "0,-1" then
                    -- a working camp turret is what the copy shows anyway: nothing to send
                    sent[e.key] = e.state
                elseif #fields < C.MAX_ENTRIES then
                    sent[e.key] = e.state
                    fields[#fields + 1] = string.format("%s,%.0f,%.0f,%.0f,%s", e.code, e.x, e.y, e.z, e.state)
                end
            end
        end
        if #fields > 0 and net.send_to(p.pc, "TURSTATE", table.unpack(fields)) then
            M.stats.states = M.stats.states + #fields
            if first("host.state") then
                log.info("turrets: [host] turret state to %s: %s", p.who, table.concat(fields, " | "))
            end
        end
    end
    for name in pairs(st.sent) do
        if not keep[name] then st.sent[name] = nil end
    end
end

local function host_pass()
    local players = players_now()
    if #players == 0 then
        st.host_reg = {}
        return
    end
    st.host_reg = scan(function(a, e)
        local near, dmin = nil, math.huge
        for _, p in ipairs(players) do
            local d = dist(p, e)
            if d < dmin then near, dmin = p, d end
        end
        if dmin > C.STATE_CM then return end
        local comp = comp_of(a, e.kind)
        if not ue.valid(comp) then return end
        local dead = ue.prop(comp, "Dead") == true
        local hp = -1
        if e.kind == "build" then hp = math.floor(tonumber(ue.prop(comp, "Current Health")) or -1) end
        -- a dead buildable is being destroyed by the game (the actor goes): only its health counts
        e.state = string.format("%d,%d", (dead and e.kind == "camp") and 1 or 0, hp)
        if not dead and dmin <= C.WAKE_CM then host_wake(a, comp, e, near.who, dmin) end
    end)
    send_states(players, st.host_reg)
end

-- TUROFF|code|x|y|z (client -> host): that player disabled the turret on its machine
local function off_msg(f, pc)
    if S == nil or S.role ~= "host" or not enabled() then return end
    local code, x, y, z = f[1], tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    if not (code and x and y and z) then return end
    local pawn = ue.pawn_of(pc)
    local who = ue.valid(pawn) and ue.short(pawn) or "?"
    if #st.host_reg == 0 then host_pass() end
    local e = find_entry(st.host_reg, code, x, y, z)
    local a = live(e)
    if not a then
        M.stats.off_refused = M.stats.off_refused + 1
        log.info("turrets: [host] %s disabled turret %s on its machine: no such turret here (not applied)", who,
            key_of(code, x, y, z))
        return
    end
    local pl = ue.valid(pawn) and ue.location(pawn) or nil
    if pl and dist(pt(pl), e) > C.OFF_REACH_CM then
        M.stats.off_refused = M.stats.off_refused + 1
        log.info("turrets: [host] %s disabled %s on its machine from %.0f m: too far, not applied", who, ue.short(a),
            dist(pt(pl), e) / 100)
        return
    end
    local comp = comp_of(a, e.kind)
    if not ue.valid(comp) then return end
    if ue.prop(comp, "Dead") == true then
        log.info("turrets: [host] %s disabled %s on its machine: it is off here already (state sent again)", who,
            ue.short(a))
    elseif e.cls ~= P.BANDIT then
        M.stats.off_refused = M.stats.off_refused + 1
        log.info("turrets: [host] %s reports %s (%s) disabled: that class has no disable here, not applied", who,
            ue.short(a), e.cls)
        return
    else
        -- the game's own end of the hold: IsHeld -> Dead, Can Attack, pickup, head destroyed
        ue.set_prop(a, "IsHeld", true)
        local ok, err = ue.call(a, P.DISABLE_FN, P.DISABLE_ENTRY)
        local dead = ue.prop(comp, "Dead") == true
        local fallback = false
        if not dead then
            fallback = true
            ue.set_prop(comp, "Dead", true)
            ue.set_prop(comp, "Can Attack", false)
            local mesh = ue.prop(a, "Turret")
            if ue.valid(mesh) then pcall(function() mesh:K2_DestroyComponent(a) end) end
        end
        M.stats.offs = M.stats.offs + 1
        log.info("turrets: [host] %s disabled %s (%s at %s) on its machine: the game's disable step @%d ran on the"
            .. " host (ok=%s%s): dead=%s, head left=%s%s", who, ue.short(a), e.code, loc_text(e), P.DISABLE_ENTRY,
            tostring(ok), ok and "" or (" " .. tostring(err)), tostring(ue.prop(comp, "Dead") == true),
            tostring(ue.valid(ue.prop(a, "Turret"))),
            fallback and " (fallback: Dead / Can Attack set, head destroyed, no pickup)"
                or ", the game spawned its TurretGun pickup here")
    end
    -- the state to every client near it on the next tick (this sender too)
    for _, sent in pairs(st.sent) do sent[e.key] = nil end
    st.pass_due = 0
end

-- TURHIT|code,x,y,z,damage|... (client -> host): that player's bullets hit these camp turrets
local function hit_msg(f, pc)
    if S == nil or S.role ~= "host" or not enabled() then return end
    local pawn = ue.pawn_of(pc)
    local who = ue.valid(pawn) and ue.short(pawn) or "?"
    local pl = ue.valid(pawn) and ue.location(pawn) or nil
    if #st.host_reg == 0 then host_pass() end
    for i = 1, math.min(#f, 8) do
        local t = split(f[i], ",")
        local code, x, y, z = t[1], tonumber(t[2]), tonumber(t[3]), tonumber(t[4])
        local dmg = math.max(0, math.min(C.HIT_MAX, tonumber(t[5]) or 0))
        local e = (code and x and y and z) and find_entry(st.host_reg, code, x, y, z) or nil
        local a = live(e)
        if a and dmg > 0 and e.kind == "camp" and not (pl and dist(pt(pl), e) > C.HIT_REACH_CM) then
            local comp = comp_of(a, e.kind)
            if ue.valid(comp) and ue.prop(comp, "Dead") ~= true then
                local hp0 = tonumber(ue.prop(comp, "Current Health"))
                local ok, err = pcall(function() comp[P.DAMAGED](comp, dmg) end)
                local hp1 = ue.valid(comp) and tonumber(ue.prop(comp, "Current Health")) or nil
                M.stats.hits = M.stats.hits + 1
                M.stats.hit_dmg = M.stats.hit_dmg + dmg
                if first("host.hit", 5) or (hp1 and hp1 <= 0) then
                    log.info("turrets: [host] %s's shots hit %s (%s at %s) for %.1f: Server Turret Damaged ran on the"
                        .. " host (ok=%s%s): health %s -> %s", who, ue.short(a), e.code, loc_text(e), dmg, tostring(ok),
                        ok and "" or (" " .. tostring(err)), tostring(hp0), tostring(hp1))
                end
            end
        elseif first("host.hit_miss", 3) then
            log.info("turrets: [host] %s's hit on turret %s not applied (found=%s, damage %.1f)", who, tostring(f[i]),
                tostring(a ~= nil), dmg)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- the engine's Multicast Muzzle Effect ran here for a copy
local function client_on_fire(comp)
    if st.applying then return end
    local a = owner_of(comp)
    if not ue.valid(a) then return end
    local path = ue.path(a)
    local seen = st.engine[path]
    st.engine[path] = clock()
    M.stats.engine = M.stats.engine + 1
    if seen == nil and first("client.engine") then
        log.info("turrets: [client] the host's fire multicast reached this client for %s (role=%s): the engine shows"
            .. " its shots here; the relay's effects are skipped for it", ue.short(a), tostring(ue.role(a)))
    end
end

local function play_muzzle(a, kind)
    local comp = comp_of(a, kind)
    if not ue.valid(comp) then return false end
    st.applying = true
    local ok, err = pcall(function() comp[P.MUZZLE](comp, { bBlockingHit = false }) end)
    st.applying = false
    if not ok then log.err_throttled("turrets.muzzle", "turrets: Multicast Muzzle Effect here: %s", tostring(err)) end
    return ok
end

-- a host turret fired: show it on this client's copy (the game's own effect functions)
local function show_fire(a, e, n, pitch, yaw, now)
    local comp = comp_of(a, e.kind)
    if not ue.valid(comp) then return end
    if ue.prop(comp, "Dead") == true then return end
    local seen = st.engine[e.path]
    local mesh = ue.prop(a, "Turret")
    local tgt = ue.prop(comp, "Attack Target")
    local ticking = is_ticking(comp)
    local aimed = false
    if ue.valid(mesh) and pitch and yaw and (not ue.valid(tgt) or ticking == false) then
        aimed = pcall(function() mesh:K2_SetWorldRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }, false, {}, false) end)
        if aimed then M.stats.aimed = M.stats.aimed + 1 end
    end
    if seen and now - seen < C.ENGINE_S then
        M.stats.engine_skip = M.stats.engine_skip + 1
        return
    end
    local rec = st.relayed[e.path]
    if not rec then
        rec = { t = now, idle_stopped = false }
        st.relayed[e.path] = rec
    end
    rec.t = now
    if not rec.idle_stopped then
        rec.idle_stopped = ue.call(a, P.IDLE_STOP) == true
    end
    local ok = play_muzzle(a, e.kind)
    if ok then M.stats.shown = M.stats.shown + 1 end
    if n >= 2 then
        local path, kind = e.path, e.kind
        ue.delay("turret-fx", 120, function()
            local a2 = ue.find_object(path)
            if a2 and ue.valid(a2) and play_muzzle(a2, kind) then M.stats.shown = M.stats.shown + 1 end
        end)
    end
    if not rec.logged and first("client.shown") then
        rec.logged = true
        log.info("turrets: [client] %s (%s at %s) fired on the host (%d shot(s)), no engine multicast here: shown by"
            .. " the copy's own Multicast Muzzle Effect (ok=%s); head set to the host's aim=%s (target here %s,"
            .. " tick=%s, role=%s)", ue.short(a), e.code, loc_text(e), n, tostring(ok), tostring(aimed),
            ue.valid(tgt) and ue.short(tgt) or "none", bool_text(ticking), tostring(ue.role(a)))
    end
end

-- a host turret fired where this client has no copy: its sound at its place
local function sound_only(path, x, y, z, key)
    if not path or path:sub(1, 6) ~= "/Game/" then
        M.stats.no_sound = M.stats.no_sound + 1
        return
    end
    local s = ue.find_object(path)   -- never loaded on a message
    if not s then
        M.stats.no_sound = M.stats.no_sound + 1
        if first("client.nosound", 2) then
            log.info("turrets: [client] fire sound %s not in memory here: a far turret's shot not played",
                path:match("([^%.]+)$") or path)
        end
        return
    end
    local snd = snd_mod()
    local range, att = snd.range_of(s)
    local loc = { X = x, Y = y, Z = z }
    local near, d = snd.audible_here(loc, range)
    if not near then
        M.stats.not_audible = M.stats.not_audible + 1
        return
    end
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then return end
    local ok, err = pcall(function()
        gps:PlaySoundAtLocation(wc, s, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, att, nil, nil, nil)
    end)
    if not ok then
        log.err_throttled("turrets.sound", "turrets: far turret shot: %s", tostring(err))
        return
    end
    M.stats.sound_only = M.stats.sound_only + 1
    if not st.nocopy_logged[key] and first("client.nocopy") then
        st.nocopy_logged[key] = true
        log.info("turrets: [client] host turret %s fired %.0f m from here, no copy of it here: its sound played at"
            .. " its place (carries %.0f m)", key, (d or 0) / 100, (range or 0) / 100)
    end
end

-- TURFIRE|sounds|code,x,y,z,n,pitch,yaw,sound#|...
local function fire_msg(f)
    if S == nil or S.role ~= "client" or not enabled() then return end
    local sounds = split(f[1] or "", ";")
    local now = clock()
    for i = 2, math.min(#f, 1 + C.MAX_ENTRIES) do
        local t = split(f[i], ",")
        local code, x, y, z = t[1], tonumber(t[2]), tonumber(t[3]), tonumber(t[4])
        if code and code ~= "" and x and y and z then
            local n = math.max(1, math.floor(tonumber(t[5]) or 1))
            local e = find_entry(st.client_reg, code, x, y, z)
            local a = live(e)
            if a then
                show_fire(a, e, n, tonumber(t[6]), tonumber(t[7]), now)
            else
                local si = math.floor(tonumber(t[8]) or 0)
                sound_only(si > 0 and sounds[si] or nil, x, y, z, key_of(code, x, y, z))
            end
        end
    end
end

-- the host disabled this copy's turret: the head goes as in the game
local function apply_off(a, e, why)
    local comp = comp_of(a, e.kind)
    if not ue.valid(comp) then return end
    st.off_host[e.path] = true
    local was = ue.prop(comp, "Dead") == true
    ue.set_prop(comp, "Dead", true)
    ue.set_prop(comp, "Can Attack", false)
    local mesh = ue.prop(a, "Turret")
    local removed = false
    if ue.valid(mesh) then removed = pcall(function() mesh:K2_DestroyComponent(a) end) end
    if removed then M.stats.heads_removed = M.stats.heads_removed + 1 end
    if removed or not was then
        log.info("turrets: [client] %s (%s at %s) is disabled on the host (%s): off here too (was dead here=%s, head"
            .. " removed=%s)", ue.short(a), e.code, loc_text(e), why, tostring(was), tostring(removed))
    end
end

-- this client's own TurretGun pickups next to a turret (spawned by its own disable)
local function remove_own_pickups(e)
    local list = actors_of(P.PICKUP)
    if list == false then return 0 end
    local n = 0
    for _, p in ipairs(list) do
        local l = ue.location(p)
        if l and ue.role(p) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(p) and dist(pt(l), e) <= C.PICKUP_CM then
            if pcall(function() p:K2_DestroyActor() end) then n = n + 1 end
        end
    end
    M.stats.pickups_removed = M.stats.pickups_removed + n
    return n
end

-- TURSTATE entry for a copy: true when it was applied
local function apply_state(p)
    local e = find_entry(st.client_reg, p.code, p.x, p.y, p.z)
    local a = live(e)
    if not a then return false end
    if p.dead == 1 and e.kind == "camp" then
        apply_off(a, e, "TURSTATE")
        if st.off_sent[e.path] then
            local n = remove_own_pickups(e)
            if n > 0 then log.info("turrets: [client] %d own TurretGun pickup(s) by %s removed", n, ue.short(a)) end
        end
    end
    if p.hp >= 0 and e.kind == "build" then
        local comp = comp_of(a, e.kind)
        if ue.valid(comp) then ue.set_prop(comp, "Current Health", p.hp) end
        local ok = ue.call(a, "UpdateHealth", p.hp)
        if first("client.hp", 3) then
            log.info("turrets: [client] %s (%s at %s): health %d from the host into its bar (ok=%s)", ue.short(a),
                e.code, loc_text(e), p.hp, tostring(ok))
        end
    end
    M.stats.states_applied = M.stats.states_applied + 1
    return true
end

-- TURSTATE|code,x,y,z,dead,hp|...
local function state_msg(f)
    if S == nil or S.role ~= "client" or not enabled() then return end
    local now = clock()
    for i = 1, math.min(#f, C.MAX_ENTRIES) do
        local t = split(f[i], ",")
        local code, x, y, z = t[1], tonumber(t[2]), tonumber(t[3]), tonumber(t[4])
        if code and code ~= "" and x and y and z then
            local p = { code = code, x = x, y = y, z = z, dead = tonumber(t[5]) or 0, hp = tonumber(t[6]) or -1,
                        t = now }
            if not apply_state(p) then st.pending[key_of(code, x, y, z)] = p end
        end
    end
end

local function send_off(e)
    st.off_sent[e.path] = clock()
    local ok = net.send_to_host("TUROFF", e.code, string.format("%.0f", e.x), string.format("%.0f", e.y),
        string.format("%.0f", e.z))
    M.stats.offs_sent = M.stats.offs_sent + 1
    local n = remove_own_pickups(e)
    log.info("turrets: [client] %s (%s at %s) was disabled on this machine (the game's 5 s hold runs on the"
        .. " interacting machine only): TUROFF sent to the host (ok=%s); %d client-only TurretGun pickup(s) removed"
        .. " (the host's comes replicated)", e.path:match("([^%.:]+)$") or e.path, e.code, loc_text(e), tostring(ok), n)
end

local function client_first_seen(a, comp, e, d)
    st.seen[e.path] = true
    if not first("client.seen", 12) then return end
    local role = ue.role(a)
    local tgt = ue.prop(comp, "Attack Target")
    log.info("turrets: [client] copy %s (%s at %s), %.0f m: role=%s (%s), AI component active=%s tick=%s, target=%s,"
        .. " dead here=%s", ue.short(a), e.code, loc_text(e), d / 100, tostring(role),
        role == ue.ROLE_AUTHORITY and "this client's own copy: the host does not drive it" or "the host's, replicated",
        bool_text(is_active(comp)), bool_text(is_ticking(comp)), ue.valid(tgt) and ue.short(tgt) or "none",
        tostring(ue.prop(comp, "Dead") == true))
end

local function client_wake(a, comp, e, d)
    if ue.prop(comp, "Dead") == true or is_ticking(comp) ~= false then return end
    local ok = wake(a, comp)
    M.stats.cwakes = M.stats.cwakes + 1
    local n = (st.cwoken[e.path] or 0) + 1
    st.cwoken[e.path] = n
    if n <= 2 or n % 20 == 0 then
        log.info("turrets: [client] copy %s (%s at %s, %.0f m) did not tick here (the host's optimizer switched its"
            .. " AI component off and that replicates): woken (ok=%s, tick now=%s; %d time(s))", ue.short(a), e.code,
            loc_text(e), d / 100, tostring(ok), bool_text(is_ticking(comp)), n)
    end
end

local function client_pass(now)
    local pawn = ue.local_pawn()
    local l = pawn and ue.location(pawn)
    local own = l and pt(l) or nil
    st.client_reg = scan(function(a, e)
        local d = own and dist(own, e) or math.huge
        if d > C.NEAR_CM then return end
        local comp = comp_of(a, e.kind)
        if not ue.valid(comp) then return end
        if not st.seen[e.path] then client_first_seen(a, comp, e, d) end
        if e.kind == "camp" and ue.prop(comp, "Dead") == true and not st.off_host[e.path] and not st.off_sent[e.path] then
            send_off(e)
        end
        if d <= C.WAKE_CM then client_wake(a, comp, e, d) end
    end)
    -- host states that came before the copy did
    for k, p in pairs(st.pending) do
        if apply_state(p) or now - p.t > C.PENDING_S then st.pending[k] = nil end
    end
    -- the idle sweep again after the last relayed shot
    for path, rec in pairs(st.relayed) do
        if now - rec.t > C.IDLE_RESUME_S then
            st.relayed[path] = nil
            if rec.idle_stopped then
                local a = ue.find_object(path)
                if a and ue.valid(a) then ue.call(a, P.IDLE_START) end
            end
        end
    end
    for path, t in pairs(st.engine) do
        if now - t > 60 then st.engine[path] = nil end
    end
end

-- the own active slot holds a firearm
local function firearm_in_hand(pawn)
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return false end
    local tag = ue.str(ue.try(function() return helper.ActiveWeapon.TagName end))
    for _, s in ipairs(P.FIREARM_SLOTS) do
        if tag:find(s, 1, true) then return true end
    end
    return false
end

-- BP_MasterTurret.Damage_Object(Damage, Damage Causer, Event Instigator), post, client
local function on_damage_object(c, dmg_p, causer_p)
    if S == nil or S.role ~= "client" or not enabled() then return end
    local t = c and get(c)
    if not ue.valid(t) then return end
    local causer = get(causer_p)
    if not ue.valid(causer) then return end
    if ue.try(function() return causer:IsLocallyControlled() end) ~= true then return end
    if not firearm_in_hand(causer) then
        M.stats.hit_melee = M.stats.hit_melee + 1
        return
    end
    local dmg = tonumber(get(dmg_p)) or 0
    if dmg <= 0 then return end
    local code, kind = code_of(t)
    if not code or kind ~= "camp" then return end
    local l = ue.location(t)
    if not l then return end
    local key = key_of(code, l.X, l.Y, l.Z)
    local h = st.hits[key]
    if not h then
        h = { code = code, x = l.X, y = l.Y, z = l.Z, dmg = 0, n = 0, name = ue.short(t) }
        st.hits[key] = h
    end
    h.dmg, h.n = h.dmg + dmg, h.n + 1
end

local function client_flush_hits()
    if next(st.hits) == nil then return end
    local hits = st.hits
    st.hits = {}
    local fields = {}
    for _, h in pairs(hits) do
        if #fields < 8 then
            fields[#fields + 1] = string.format("%s,%.0f,%.0f,%.0f,%.1f", h.code, h.x, h.y, h.z, math.min(h.dmg, C.HIT_MAX))
            if first("client.hit", 5) then
                log.info("turrets: [client] own shots hit %s (%s at %s) %d time(s) for %.1f: TURHIT to the host (the"
                    .. " game's Server Turret Damaged from a client is dropped by the engine)", h.name, h.code,
                    loc_text(h), h.n, h.dmg)
            end
        end
    end
    if net.send_to_host("TURHIT", table.unpack(fields)) then M.stats.hits_sent = M.stats.hits_sent + #fields end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- Multicast Muzzle Effect(Effect Hit), post: on the host for every shot, on a
-- client when the engine's multicast arrived (or this module ran it: skipped)
local function on_muzzle(c)
    if not coop() or not enabled() then return end
    local comp = c and get(c)
    if not ue.valid(comp) then return end
    if S.role == "host" then host_on_fire(comp) else client_on_fire(comp) end
end

local HOOKS = {
    { path = P.COMP .. ":" .. P.MUZZLE, fn = on_muzzle, label = "BP_TurretAIComponent Multicast Muzzle Effect" },
    { path = P.BCOMP .. ":" .. P.MUZZLE, fn = on_muzzle, label = "BP_BuildableTurretAIComponent Multicast Muzzle Effect" },
    { path = P.MASTER .. ":Damage_Object", fn = on_damage_object, label = "BP_MasterTurret Damage_Object" },
}

-- each once its class is loaded (a turret exists), retried every 5 s
local function ensure_hooks(now)
    if now < st.hooks_next then return end
    st.hooks_next = now + 5
    for _, h in ipairs(HOOKS) do
        if not h.done and ue.find_object(h.path) then
            local fn = h.fn
            local ok, err = pcall(RegisterHook, h.path, function(c, ...)
                local okc, e = pcall(fn, c, ...)
                if not okc then log.err_throttled("turrets.hook", "turrets: hook: %s", tostring(e)) end
            end)
            h.done = ok and true or "failed"
            log.info("turrets: hook %s %s%s", h.label, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Tick, wiring
-- ---------------------------------------------------------------------------

local function summary(now)
    if st.summary.t == 0 then st.summary.t = now end
    if now - st.summary.t < C.SUMMARY_S then return end
    st.summary.t = now
    local line = M.status_line()
    if line == st.summary.last then return end
    st.summary.last = line
    log.info("%s", line)
end

-- every 250 ms (main.lua)
function M.tick()
    if not coop() or not enabled() then return end
    local now = clock()
    ensure_hooks(now)
    local ok, err = true, nil
    if now - st.flush_t >= C.FLUSH_S - 0.01 then
        st.flush_t = now
        if S.role == "host" then ok, err = pcall(host_flush) else ok, err = pcall(client_flush_hits) end
        if not ok then log.err_throttled("turrets.flush", "turrets: flush: %s", tostring(err)) end
    end
    if now >= st.pass_due then
        st.pass_due = now + C.PASS_S
        if S.role == "host" then ok, err = pcall(host_pass) else ok, err = pcall(client_pass, now) end
        if not ok then log.err_throttled("turrets.pass", "turrets: pass: %s", tostring(err)) end
    end
    summary(now)
end

function M.install(state)
    S = state
    net.on("TURFIRE", fire_msg)
    net.on("TURSTATE", state_msg)
    net.on("TUROFF", off_msg)
    net.on("TURHIT", hit_msg)
    log.info("turrets: installed (turret_sync=%s): host shots -> TURFIRE every %.2f s to clients within the fire"
        .. " sound's range; optimizer wake within %.0f m of a remote player; disable / damage / buildable health"
        .. " synced (TUROFF, TURHIT, TURSTATE)", tostring(enabled()), C.FLUSH_S, C.WAKE_CM / 100)
end

function M.reset(why)
    fresh_state()
    log.debug("turrets: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    if S and S.role == "client" then
        return string.format("turrets: [client] engine multicasts %d, relayed shots shown %d (engine-skipped %d, head"
            .. " aimed %d), far shots heard %d (not audible %d, no sound %d), woken %d, disabled here %d (own pickups"
            .. " removed %d), host states %d (heads removed %d), hits sent %d (melee left to the host %d)", s.engine,
            s.shown, s.engine_skip, s.aimed, s.sound_only, s.not_audible, s.no_sound, s.cwakes, s.offs_sent,
            s.pickups_removed, s.states_applied, s.heads_removed, s.hits_sent, s.hit_melee)
    end
    return string.format("turrets: [host] shots %d, TURFIRE %d message(s) / %d entries, woken %d, disables applied %d"
        .. " (refused %d), client hits %d (%.0f damage), states sent %d", s.shots, s.fire_msgs, s.fire_entries,
        s.wakes, s.offs, s.off_refused, s.hits, s.hit_dmg, s.states)
end

return M
