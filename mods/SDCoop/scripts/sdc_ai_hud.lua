-- SDCoop zombie feature ai_healthbar: the enemy health bar comes back after the
-- client's death and respawn, and shows the host's health values.
--
-- How the game shows it:
--   HUD_Game (the controller's AHUD) creates W_EnemyHealthBarOverlay in its
--   ReceiveBeginPlay (+2 s) and in Re-Initialise, and keeps it in
--   EnemyHealthBarUI. The own character's TraceForAI timer (0.05 s, started
--   in the local-player setup of BP_PlayerCharacter's BeginPlay) sphere-
--   traces from the camera, asks the hit AI's AIHealthBarInfo and calls
--   HUD.ToggleAIHealthBar / UpdateHealth, which only change the visibility
--   and values of EnemyHealthBarUI.
-- Why it stops in co-op:
--   on death BP_PlayerController.Client_Died runs RemoveAllWidgets (@7172 /
--   @7918): the overlay leaves the viewport, but EnemyHealthBarUI still holds
--   it (valid), so nothing recreates it. In single player the respawn goes
--   through SD_GameInstance.Survival_Respawn, whose first call is
--   GetGameHUD().Re-Initialise() (remove + recreate the notification and
--   health-bar widgets). A co-op client respawns through the host (sdc_players
--   RESPAWN), so Re-Initialise never ran: ToggleAIHealthBar kept toggling a
--   widget that was no longer on screen. The XP popups (HUD.NotificationUI)
--   were gone after a respawn for the same reason.
--   (A missed TraceForAI timer — the character getting its controller late —
--   is sdc_localinit's job.)
-- Fix (client): once the own character is alive for a few seconds, if the
-- HUD's EnemyHealthBarUI is not in the viewport, run the game's own
-- HUD.Re-Initialise, as Survival_Respawn does. At most twice per character.
--
-- The values it shows (health relay):
--   zombies / bosses: AIHealthBarInfo -> DamageComponent.GetValues ->
--   HUD.UpdateHealth(CurrentHealth, StandardHealth). DamageComponent_C has no
--   replicated variable: CurrentHealth / StandardHealthValue / MaxHealth live
--   on the host; a client's copy keeps what its own BeginPlay rolled
--   (SetHealth with its own random deviation), so its bar stayed full.
--   animals: AIHealthBarInfo -> UpdateHealth(self.Health, max); Health is not
--   replicated either. (Bandits, soldiers, traders use the replicated
--   BP_AIComponent.Health: fine.)
-- Host: post-hooks on DamageComponent_C.DamageTaken (every hit) and
--   FireDamageTaken (the burning timer), and on the animals' ReceiveAnyDamage,
--   send AIHP|kind|current|standard|max + ClientRepObjRef(AI) to the clients
--   within net range (per AI at most every 0.1 s; the dead are left to the
--   corpse feature).
-- Client: writes the values into its copy (DamageComponent's three fields /
--   the animal's Health); the game's own AIHealthBarInfo shows them. While the
--   player looks at an AI (AIHealthBarInfo's post-hook) whose values are
--   missing or older than 1 s, it asks the host (AIHPQ|x|y|z, at most every
--   0.5 s): a bar opened later, or a final value the 0.1 s limit held back.
--   The host answers for the live AIs within 2.5 m of that point (one engine
--   sphere-overlap query), to that client only.

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = { stats = { reinit = 0, failed = 0, pushed = 0, answered = 0, asked = 0, applied = 0 } }
local core

local clock = os.clock
local addr = ctx.addr

local DMG = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C:"
local ANIMALS = {
    "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C", "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C",
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C", "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
}
local PAWN_CLASS = "/Script/Engine.Pawn"
local OBJ_PAWN = 2             -- EObjectTypeQuery of ECC_Pawn (the zombies' own overlap queries use 2)

local SEND_CM = 15000          -- net range: a copy exists within 150 m
local PUSH_GAP_S = 0.1
local PER_CLIENT_TICK = 30
local REQ_GAP_S = 0.5          -- client: at most one question every 0.5 s
local STALE_S = 1.0            -- client: values older than this are asked again while looked at
local QUERY_CM = 250           -- host: the AIs around the asked point
local QUERY_MAX_CM = 20000     -- host: a point farther than this from the asking player is ignored
local HOST_REQ_GAP_S = 0.25    -- host: per client
local ANSWER_MAX = 6

local pushed = {}              -- host: [AI address] = clock
local asked_by = {}            -- host: [pc full name] = clock
local got = {}                 -- client: [copy full name] = clock
local last_req = -1000         -- client

local CHECK_S = 2
local SETTLE_S = 4            -- HUD_Game creates the overlay 2 s after its BeginPlay
local MAX_TRIES = 2

local st = { key = nil, since = 0, last = -1000, tries = 0, logged_ok = false }

local function in_viewport(w)
    if not ue.valid(w) then return false end
    local ok, v = pcall(function() return w:IsInViewport() end)
    return ok and v == true
end

function M.client_tick(now)
    for k, t in pairs(got) do
        if now - t > 60 then got[k] = nil end
    end
    if now - st.last < CHECK_S then return end
    st.last = now
    local pc = ue.local_pc()
    local pawn = pc and ue.pawn_of(pc)
    if not pawn then
        st.key = nil
        return
    end
    local key = ue.name(pawn)
    if key ~= st.key then
        st.key, st.since, st.tries, st.logged_ok = key, now, 0, false
    end
    if now - st.since < SETTLE_S or ue.prop(pawn, "PlayerDead?") == true then return end
    local hud = ue.try(function() return pc:GetHUD() end)
    if not ue.valid(hud) or ue.class_name(hud) ~= "HUD_Game_C" then return end
    if in_viewport(ue.prop(hud, "EnemyHealthBarUI")) then
        if st.tries > 0 and not st.logged_ok then
            st.logged_ok = true
            log.info("ai: hud: enemy health bar back on screen")
        end
        return
    end
    if st.tries >= MAX_TRIES then return end
    st.tries = st.tries + 1
    local ok, err = ue.call(hud, "Re-Initialise")
    if ok then
        M.stats.reinit = M.stats.reinit + 1
    else
        M.stats.failed = M.stats.failed + 1
    end
    log.info("ai: hud: enemy health bar not on screen for %s; HUD Re-Initialise (as the game's respawn): %s",
        ue.short(pawn), ok and "ok" or tostring(err))
end

-- ---------------------------------------------------------------------------
-- Health relay: host
-- ---------------------------------------------------------------------------

local function num(v)
    if type(v) == "number" then return v end
    return nil
end

-- kind, current, standard, max of a live AI the relay covers, or nil
local function health_of(o)
    if ue.prop(o, "IsDead?") == true then return nil end
    if core.is_zombie(o) or core.is_boss(o) then
        local comp = ue.prop(o, "DamageComponent")
        if not ue.valid(comp) then return nil end
        local cur, std, max = num(ue.prop(comp, "CurrentHealth")), num(ue.prop(comp, "StandardHealthValue")),
            num(ue.prop(comp, "MaxHealth"))
        if not cur or not std then return nil end
        return "d", cur, std, max or std
    end
    if core.is_animal(o) then
        local h = num(ue.prop(o, "Health"))
        if not h then return nil end
        return "h", h, h, h
    end
    return nil
end

local function fmt(v) return string.format("%.2f", v) end

local function send_hp(pc, o, kind, cur, std, max)
    return core.send_with_obj(pc, o, "AIHP", kind, fmt(cur), fmt(std), fmt(max))
end

-- An AI took damage: its values to the clients near it.
local function push(o)
    if not core.host.active or #core.host.viewers == 0 or not ue.valid(o) then return end
    local a = addr(o)
    local now = clock()
    if not a or (pushed[a] and now - pushed[a] < PUSH_GAP_S) then return end
    local kind, cur, std, max = health_of(o)
    if not kind then return end
    pushed[a] = now
    for _, v in ipairs(core.viewers_near(ue.location(o), SEND_CM)) do
        v.hp = v.hp or 0
        if v.hp < PER_CLIENT_TICK then
            v.hp = v.hp + 1
            if send_hp(v.pc, o, kind, cur, std, max) then
                M.stats.pushed = M.stats.pushed + 1
                if core.first("hud.push", 3) then
                    log.info("ai: hud: health of %s %.0f/%.0f -> %s", ue.short(o), cur, std, ue.short(v.pc))
                end
            end
        end
    end
end

-- DamageComponent_C.DamageTaken / FireDamageTaken, post (host): context = the component
local function on_damage_taken(c)
    local comp = c:get()
    local o = ue.valid(comp) and ue.try(function() return comp:GetOwner() end) or nil
    if ue.valid(o) and (core.is_zombie(o) or core.is_boss(o)) then push(o) end
end

-- <Animal>.ReceiveAnyDamage, post (host)
local function on_animal_damage(c)
    push(c:get())
end

-- AIHPQ|x|y|z (client -> host): the live AIs around that point, to that client.
local function on_question(f, pc)
    if core.S.role ~= "host" or not core.is_remote_pc(pc) then return end
    local key = ue.name(pc)
    local now = clock()
    if asked_by[key] and now - asked_by[key] < HOST_REQ_GAP_S then return end
    asked_by[key] = now
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
        log.err_throttled("ai.hud.query", "ai: hud: SphereOverlapActors: %s", tostring(err))
        return
    end
    local n = 0
    for i = 1, #out do
        if n >= ANSWER_MAX then break end
        -- out-array elements come as params (read with :get())
        local e = out[i]
        local okg, o = pcall(function() return e:get() end)
        if not okg then o = e end
        if ue.valid(o) and ue.role(o) == ue.ROLE_AUTHORITY then
            local kind, cur, std, max = health_of(o)
            if kind and send_hp(pc, o, kind, cur, std, max) then n = n + 1 end
        end
    end
    M.stats.answered = M.stats.answered + n
    if core.first("hud.answer", 3) then log.info("ai: hud: %s asked for health: %d sent", ue.short(pc), n) end
end

-- ---------------------------------------------------------------------------
-- Health relay: client
-- ---------------------------------------------------------------------------

-- AIHP|kind|current|standard|max: waits for its AI (ClientRepObjRef)
local function on_hp(f)
    if core.S.role ~= "client" then return end
    local cur, std, max = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    if not (cur and std and max) or (f[1] ~= "d" and f[1] ~= "h") then return end
    core.expect_obj("hp", { kind = f[1], cur = cur, std = std, max = max })
end

-- The client's copy of that AI: the host's values (never on a dead copy).
local function apply_hp(o, d)
    if ue.role(o) == ue.ROLE_AUTHORITY or ue.prop(o, "IsDead?") == true then return end
    local ok
    if d.kind == "d" then
        if not (core.is_zombie(o) or core.is_boss(o)) then return end
        local comp = ue.prop(o, "DamageComponent")
        if not ue.valid(comp) then return end
        ok = ue.set_prop(comp, "CurrentHealth", d.cur)
        ue.set_prop(comp, "StandardHealthValue", d.std)
        ue.set_prop(comp, "MaxHealth", d.max)
    else
        if not core.is_animal(o) then return end
        ok = ue.set_prop(o, "Health", d.cur)
    end
    if not ok then return end
    got[ue.name(o)] = clock()
    M.stats.applied = M.stats.applied + 1
    if core.first("hud.apply", 3) then
        log.info("ai: hud: health of %s = %.0f/%.0f (host)", ue.short(o), d.cur, d.std)
    end
end

-- <AI>.AIHealthBarInfo, post (client): the player looks at it (20 times a second)
local function on_bar_info(c)
    local now = clock()
    if now - last_req < REQ_GAP_S then return end
    local o = c:get()
    if not ue.valid(o) or ue.role(o) == ue.ROLE_AUTHORITY then return end
    local t = got[ue.name(o)]
    if t and now - t < STALE_S then return end
    local l = ue.location(o)
    if not l then return end
    last_req = now
    if net.send_to_host("AIHPQ", string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z)) then
        M.stats.asked = M.stats.asked + 1
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
        core.forget_gone("hud", function() return { got = got } end)
    end
    core.hook({ path = DMG .. "DamageTaken", kind = "bp", role = "host", feature = "hud", name = "hud.damage",
                fn = on_damage_taken })
    core.hook({ path = DMG .. "FireDamageTaken", kind = "bp", role = "host", feature = "hud", name = "hud.fire",
                fn = on_damage_taken })
    for _, path in ipairs(ANIMALS) do
        local short = path:match("%.([%w_]+)$")
        core.hook({ path = path .. ":ReceiveAnyDamage", kind = "bp", role = "host", feature = "hud",
                    name = "hud." .. short, fn = on_animal_damage })
        core.hook({ path = path .. ":AIHealthBarInfo", kind = "bp", role = "client", feature = "hud",
                    name = "hud.bar." .. short, fn = on_bar_info })
    end
    core.hook({ path = core.ZM .. "AIHealthBarInfo", kind = "bp", role = "client", feature = "hud",
                name = "hud.bar.zombie", fn = on_bar_info })
    core.hook({ path = core.BOSS .. "AIHealthBarInfo", kind = "bp", role = "client", feature = "hud",
                name = "hud.bar.boss", fn = on_bar_info })
    core.on_obj("hp", "hud", apply_hp)
end

function M.host_tick(now)
    for a, t in pairs(pushed) do
        if now - t > 5 then pushed[a] = nil end
    end
    for k, t in pairs(asked_by) do
        if now - t > 60 then asked_by[k] = nil end
    end
end

function M.on_message(kind, f, pc)
    if kind == "AIHP" then
        on_hp(f)
    elseif kind == "AIHPQ" then
        on_question(f, pc)
    end
end

function M.reset()
    st = { key = nil, since = 0, last = -1000, tries = 0, logged_ok = false }
    pushed, asked_by, got = {}, {}, {}
    last_req = -1000
end

function M.status_line()
    local s = M.stats
    return string.format("ai: hud re-initialised=%d failed=%d | health pushed=%d answered=%d | client asked=%d applied=%d",
        s.reinit, s.failed, s.pushed, s.answered, s.asked, s.applied)
end

return M
