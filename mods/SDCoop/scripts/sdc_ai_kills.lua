-- SDCoop zombie feature ai_kill_credit: an AI killed by a client counts for
-- that client — its kill counter, its XP (and skill point), its popup — not
-- for the host.
--
-- Every killable AI credits "player 0" of itself (host side): CastToController
-- (self) -> <Kind>Kills + 1, GetLevellingComponent(self).AddXP(CurrentLevel *
-- Random(min, max) * MultiplyValue), sometimes GetSkillTreeManager(self).Add
-- Skill Points, CreateNotificationUI("<X> Killed, XP Given: N", ..., self).
-- Each of those asks GameplayStatics for player 0 with the dying AI as world
-- context. sdc_ctx's player-0 pre-hook asks M.stand_in for such an object;
-- while that AI is "dying" it answers with the killer's controller, so on the
-- host the counter / XP / skill point land on the host's copy of the client's
-- controller (not replicated: no effect) and the popup finds no HUD there. The
-- killer's client gets AIKILL|kind|popup|skill and runs the same steps on its
-- own controller (the game's XpMultiplierCalc, AddXP, Add Skill Points,
-- CreateNotificationUI). Only killers tagged Player / PlayerTrap count, as in
-- the game.
--
-- Where the "dying" window comes from (all host):
--   zombie   BP_MasterZombie.Death: OnRep_IsDead? (@279) runs before the credit
--            (@1460) -> mark; Death's post-hook settles. Killer: the innermost
--            ApplyDamage-family call in progress (pre / post hooks keep a stack)
--            or DamageComponent.CurrentFireDamageGiver.
--   humans   bandit / trader / coyote soldier / scavenger (BP_MasterAICharacter
--            template): ReceiveAnyDamage -> Delay(0.1) -> Death(DamageCauser).
--            ReceiveAnyDamage remembers a remote player's hit, Death's first call
--            StopBurning marks, Death's post-hook settles.
--   boss     BP_ZombieBoss.DeathEvent(Player) runs OnRep_IsDead? then Delay(0);
--            the credit (BossZombieKills @1077, XP @1364, skill point @1563,
--            popup @1822) runs on the next frame. DeathEvent's post-hook marks;
--            settled 1 s later.
--   animals  deer / rabbit / wolf: ReceiveAnyDamage sets IsDead? and Delay(0)s
--            into the credit (AnimalKills, XP, popup). ReceiveAnyDamage's post-
--            hook marks when this very damage call killed it (IsDead? false
--            before, read in the damage pre-hook); settled 1 s later.
--            bear: ReceiveAnyDamage -> Death() -> credit, all in one call:
--            Death's post-hook marks, ReceiveAnyDamage's post-hook settles.
-- If the redirect did not happen (redirect_player0 off), the host's counter is
-- put back; the host's XP / popup cannot be (logged).
--
-- Days survived: GameMode.EventBindMidnight adds a day on the host's
-- controller only -> AIDAY -> the client adds one to its own.
--
-- Messages (host -> client): AIKILL|kind|popup(1/0, empty = the CVar)|skill(1/0)   AIDAY

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = { marked = 0, redirected = 0, sent = 0, undone = 0, host_kept_xp = 0, got = 0, skill_points = 0,
              days_sent = 0, days_got = 0 },
}
local core

local clock = os.clock
local addr = ctx.addr

local GM_MIDNIGHT = "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:EventBindMidnight"
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local ICON_PATH = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/Hunting_For_Food/"
local HUMAN_ICON = ICON_PATH .. "T_HumanSkull_256x256.T_HumanSkull_256x256"
local ANIMAL_ICON = ICON_PATH .. "T_Animal_Skull_256x256.T_Animal_Skull_256x256"

-- What the client does per kind, as each class's own credit does it.
-- popup "cvar": the CVar Game.XpPopUp of the machine showing it; "host": the
-- AI's XpPopUpEnabled? (sent). skill: chance of a skill point when eligible.
local KINDS = {
    z = { field = "ZombieKills", xp = { 4, 8 }, text = "Zombie Killed", icon = HUMAN_ICON, popup = "cvar" },
    b = { field = "BossZombieKills", xp = { 200, 400 }, text = "Zombie Boss Killed", icon = HUMAN_ICON, popup = "cvar",
          skill = 0.25 },
    h = { field = "HumanKills", xp = { 10, 20 }, text = "Bandit Killed", icon = HUMAN_ICON, popup = "host", skill = 0.25 },
    t = { field = "HumanKills", xp = { 5, 10 }, text = "Wandering Trader Killed", icon = HUMAN_ICON, popup = "host" },
    s = { field = "HumanKills", xp = { 15, 25 }, text = "Soldier Killed", icon = HUMAN_ICON, popup = "host", skill = 0.25 },
    v = { field = "HumanKills", xp = { 5, 10 }, text = "Scavenger Killed", icon = HUMAN_ICON, popup = "host" },
    d = { field = "AnimalKills", xp = { 5, 10 }, text = "Deer Killed", icon = ANIMAL_ICON, popup = "cvar" },
    r = { field = "AnimalKills", xp = { 7.5, 15 }, text = "Rabbit Killed", icon = ANIMAL_ICON, popup = "cvar" },
    w = { field = "AnimalKills", xp = { 10, 20 }, text = "Wolf Killed", icon = ANIMAL_ICON, popup = "cvar" },
    e = { field = "AnimalKills", xp = { 10, 20 }, text = "Bear Killed", icon = ANIMAL_ICON, popup = "cvar" },
}

-- Host-side classes. Humans: Death(Player) with StopBurning first; skill = the
-- class has the bandit's "Boss? -> 25 % skill point" branch.
local HUMANS = {
    { path = "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C", kind = "h", boss_skill = true },
    { path = "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C", kind = "t" },
    { path = "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C", kind = "s", boss_skill = true },
    { path = "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C", kind = "v" },
}
local ANIMALS = {
    { path = "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C", kind = "d" },
    { path = "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C", kind = "r" },
    { path = "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C", kind = "w" },
    { path = "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C", kind = "e", sync = true },
}
local BOSS = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C"

-- { path, victim, instigator, causer } parameter positions after the context
local DAMAGE_FUNCS = {
    { "/Script/Engine.GameplayStatics:ApplyDamage", 1, 3, 4 },
    { "/Script/Engine.GameplayStatics:ApplyPointDamage", 1, 5, 6 },
    { "/Script/Engine.GameplayStatics:ApplyRadialDamage", nil, 8, 7 },
    { "/Script/Engine.GameplayStatics:ApplyRadialDamageWithFalloff", nil, 11, 10 },
}

local SYNC_TTL = 2.0         -- a window inside one call; only guards a missed post-hook
local LATENT_S = 1.0         -- boss / animals: the credit runs on the next frame; settle after this
local LATENT_TTL = 3.0
local HIT_TTL = 3.0          -- humans: Death runs 0.1 s + a tick after the damage
local DAY_GAP_S = 30

local scope = {}             -- host: damage calls in progress: false | { key, victim, radial, was_dead, tagged }
local dying = {}             -- host: [address] = { key, t, ttl, used, src, before, kind, popup, skill, vkey, latent }
local hits = {}              -- host: [address] = { key, t, tagged } (humans' last remote hit)
local credited = {}          -- host: [victim full name] = clock
local seen_dead = {}         -- host: [animal full name] = clock (seen dead in a damage call)
local last_day = -1000
local level_timer = {}       -- client: [component full name] = true
local icons_tried = {}       -- client: [icon path] = true

-- ---------------------------------------------------------------------------
-- Host: who is killing
-- ---------------------------------------------------------------------------

local function arg_value(args, i)
    if not i or not args[i] then return nil end
    local ok, v = pcall(function() return args[i]:get() end)
    if ok then return v end
    return nil
end

local function tagged(actor)
    return core.has_tag(actor, "Player") or core.has_tag(actor, "PlayerTrap")
end

local function dead_now(o)
    return ue.prop(o, "IsDead?") == true
end

local function scope_entry(spec, args)
    local causer = arg_value(args, spec[4])
    local pc = core.remote_pc_of(arg_value(args, spec[3]), causer)
    if not pc then return false end
    local victim = spec[2] and arg_value(args, spec[2]) or nil
    local valid_victim = ue.valid(victim)
    return { key = ue.name(pc), victim = valid_victim and addr(victim) or nil, radial = spec[2] == nil,
             was_dead = valid_victim and dead_now(victim) or false, tagged = tagged(causer) }
end

-- Pre / post of every damage call: always push, always pop (run with the
-- feature off too, so a call that started before a toggle stays balanced).
local function damage_pre(spec, ...)
    local entry = false
    if core.on("kills") and core.host.active then
        local ok, e = pcall(scope_entry, spec, { ... })
        if ok then
            entry = e or false
        else
            log.err_throttled("ai.kills.damage", "ai: kills: damage hook: %s", tostring(e))
        end
    end
    scope[#scope + 1] = entry
end

local function damage_post()
    local n = #scope
    if n > 0 then scope[n] = nil end
end

-- the innermost damage call by a remote player on `a`
local function scope_for(a)
    for i = #scope, 1, -1 do
        local s = scope[i]
        if s and (s.radial or s.victim == a) then return s end
    end
    return nil
end

local function host_count(field)
    local v = ue.prop(ue.local_pc(), field)
    if type(v) == "number" then return v end
    return nil
end

local function mark(a, key, src, kind, extra)
    local d = { key = key, t = clock(), ttl = SYNC_TTL, used = false, src = src, kind = kind,
                before = host_count(KINDS[kind].field) }
    for k, v in pairs(extra or {}) do d[k] = v end
    dying[a] = d
    M.stats.marked = M.stats.marked + 1
    return d
end

-- sdc_ctx: player 0 for `wco` (no remote player's own object). Two table
-- lookups unless an AI is dying right now.
-- sdc_ctx's idle check (through sdc_ai): stand_in answers nil without side
-- effects while no AI is dying
function M.stand_in_idle() return next(dying) == nil end

function M.stand_in(wco)
    if next(dying) == nil then return nil end
    local a = addr(wco)
    local d = a and dying[a]
    if not d then return nil end
    if clock() - d.t > d.ttl then
        dying[a] = nil
        return nil
    end
    local pc = core.pc_by_key(d.key)
    if pc and not d.used then
        d.used = true
        M.stats.redirected = M.stats.redirected + 1
    end
    return pc
end

-- ---------------------------------------------------------------------------
-- Host: the credit
-- ---------------------------------------------------------------------------

local function undo_host(field, before)
    local pc = ue.local_pc()
    local v = host_count(field)
    if not v or v <= 0 then return end
    if before and v <= before then return end   -- the host's counter did not move
    if not ue.set_prop(pc, field, v - 1) then return end
    M.stats.undone = M.stats.undone + 1
    M.stats.host_kept_xp = M.stats.host_kept_xp + 1
    log.info("ai: kills: host %s %d -> %d (the kill was a client's)", field, v, v - 1)
    if core.first("kills.xp", 3) then
        log.warn("ai: kills: player 0 was not redirected (redirect_player0 off?): the host keeps that kill's XP and popup")
    end
end

-- The decision is made: tell the killer (once per victim).
local function settle(vkey, label, d)
    if credited[vkey] then return end
    credited[vkey] = clock()
    local pc = core.pc_by_key(d.key)
    if not pc then return end
    local spec = KINDS[d.kind]
    if not d.used then undo_host(spec.field, d.before) end
    local popup = ""
    if spec.popup == "host" then popup = d.popup and "1" or "0" end
    local ok = net.send_to(pc, "AIKILL", d.kind, popup, d.skill and "1" or "0")
    if ok then M.stats.sent = M.stats.sent + 1 end
    if core.first("kills.sent", 8) then
        log.info("ai: kills: %s killed %s (%s, %s, redirected=%s) -> credited to that player", ue.short(pc), label,
            spec.text, tostring(d.src), tostring(d.used))
    end
end

-- Death post-hooks (zombie, humans): `killer` is Death's own parameter.
local function credit_now(victim, killer, d, kind, extra)
    if not tagged(killer) then return end
    if not d then
        -- a damage path the hooks did not see: the killer actor itself
        local pc = core.remote_pc_of(nil, killer)
        if not pc then return end   -- the host's own kill
        d = { key = ue.name(pc), used = false, src = "killer", kind = kind }
    end
    d.kind = kind
    for k, v in pairs(extra or {}) do d[k] = v end
    settle(ue.name(victim), ue.short(victim), d)
end

-- Boss / animals: the credit runs a frame later; settle after LATENT_S.
local function settle_later(a, vkey, label)
    ue.delay("ai-kill", math.floor(LATENT_S * 1000), function()
        local d = dying[a]
        if not d or d.vkey ~= vkey then return end
        dying[a] = nil
        settle(vkey, label, d)
    end)
end

local function mark_latent(o, a, key, src, kind, extra)
    local vkey = ue.name(o)
    if credited[vkey] then return end
    local d = mark(a, key, src, kind, extra)
    d.ttl, d.latent, d.vkey, d.label = LATENT_TTL, true, vkey, ue.short(o)
    settle_later(a, vkey, d.label)
end

-- -- zombies -------------------------------------------------------------------

-- BP_MasterZombie.OnRep_IsDead?, post (host): inside Death, before the credit.
local function on_zombie_dying(c)
    if not core.host.active then return end
    local z = c:get()
    local a = ue.valid(z) and addr(z) or nil
    if not a then return end
    local s = scope_for(a)
    local key, src = s and s.key, "damage"
    if not key then
        local giver = ue.prop(ue.prop(z, "DamageComponent"), "CurrentFireDamageGiver")
        local pc = ue.valid(giver) and core.remote_pc_of(nil, giver) or nil
        if pc then key, src = ue.name(pc), "fire" end
    end
    if key then mark(a, key, src, "z") end
end

-- BP_MasterZombie.Death(Actor, Headshot), post (host)
local function on_zombie_death(c, actor_p)
    if not core.host.active then return end
    local z = c:get()
    if not ue.valid(z) then return end
    local a = addr(z)
    local d = a and dying[a] or nil
    if a then dying[a] = nil end
    credit_now(z, actor_p and actor_p:get(), d, "z")
end

-- -- humans (bandit template) -------------------------------------------------

-- <Human>.ReceiveAnyDamage(Damage, DamageType, InstigatedBy, DamageCauser), post
local function on_human_damage(c, _, _, inst_p, causer_p)
    if not core.host.active then return end
    local b = c:get()
    local a = ue.valid(b) and addr(b) or nil
    if not a then return end
    local causer = causer_p and causer_p:get()
    local pc = core.remote_pc_of(inst_p and inst_p:get(), causer)
    if pc then
        hits[a] = { key = ue.name(pc), t = clock() }
    else
        hits[a] = nil
    end
end

-- <Human>.StopBurning, post: Death's first call (also when a fire goes out)
local function on_human_stop_burning(kind, c)
    if next(hits) == nil then return end
    local b = c:get()
    local a = ue.valid(b) and addr(b) or nil
    local h = a and hits[a]
    if not h or clock() - h.t > HIT_TTL then return end
    if ue.prop(ue.prop(b, "BP_AIComponent"), "Dead") ~= true then return end
    mark(a, h.key, "damage", kind)
end

-- <Human>.Death(Player), post
local function on_human_death(human, c, player_p)
    if not core.host.active then return end
    local b = c:get()
    if not ue.valid(b) then return end
    local a = addr(b)
    local d = a and dying[a] or nil
    if a then
        dying[a] = nil
        hits[a] = nil
    end
    credit_now(b, player_p and player_p:get(), d, human.kind, {
        popup = ue.prop(b, "XpPopUpEnabled?") == true,            -- Death @987 / @798
        skill = human.boss_skill == true and ue.prop(b, "Boss?") == true,   -- Death @793
    })
end

-- -- zombie boss ---------------------------------------------------------------

-- BP_ZombieBoss.DeathEvent(Player), post (host): the credit follows next frame.
local function on_boss_death_event(c, player_p)
    if not core.host.active then return end
    local boss = c:get()
    local a = ue.valid(boss) and addr(boss) or nil
    if not a then return end
    local killer = player_p and player_p:get()
    if not tagged(killer) then return end
    local pc = core.remote_pc_of(nil, killer)
    if not pc then return end
    mark_latent(boss, a, ue.name(pc), "killer", "b", { skill = true })   -- @1419: 25 % skill point
end

-- -- animals -------------------------------------------------------------------

-- <Animal>.ReceiveAnyDamage, post (host). Latent kinds: this call killed it ->
-- mark. The bear credited inside this call (Death post marked it) -> settle.
local function on_animal_damage(animal, c)
    if not core.host.active then return end
    local o = c:get()
    local a = ue.valid(o) and addr(o) or nil
    if not a then return end
    local d = dying[a]
    if animal.sync then
        if d and not d.latent then
            dying[a] = nil
            settle(ue.name(o), ue.short(o), d)
        end
        return
    end
    if d or not dead_now(o) then return end
    local vkey = ue.name(o)
    local before = seen_dead[vkey]
    seen_dead[vkey] = clock()
    local s = scope_for(a)
    if not s or not s.tagged then return end
    -- killed by this very damage call: alive when it started (an explosion
    -- does not name its victims: then "not seen dead before")
    if s.was_dead or (s.radial and before) then return end
    mark_latent(o, a, s.key, "damage", animal.kind)
end

-- BP_AnimalBear.Death, post (host): inside ReceiveAnyDamage, before the credit.
local function on_bear_death(c)
    if not core.host.active then return end
    local o = c:get()
    local a = ue.valid(o) and addr(o) or nil
    if not a or dying[a] then return end
    local s = scope_for(a)
    if s and s.tagged and not credited[ue.name(o)] then mark(a, s.key, "damage", "e") end
end

-- BP_SurroundeadGameMode.EventBindMidnight, post (host): DaysSurvived + 1 on
-- the host's controller only.
local function on_midnight()
    if not core.host.active then return end
    local now = clock()
    if now - last_day < DAY_GAP_S then return end
    last_day = now
    net.broadcast(core.S.remote_pcs or {}, "AIDAY")
    M.stats.days_sent = M.stats.days_sent + 1
    log.info("ai: kills: midnight, a survived day sent to %d player(s)", #(core.S.remote_pcs or {}))
end

-- ---------------------------------------------------------------------------
-- Client: apply what the host decided, the game's way
-- ---------------------------------------------------------------------------

local function ensure_level_timer(comp)
    -- the XP bar timer (Event_LevelBarTimer, a multicast the server's
    -- LoadComponent sends); K2_SetTimerDelegate reuses the handle
    local key = ue.name(comp)
    if level_timer[key] then return end
    level_timer[key] = true
    local ok = ue.call(comp, "Event_LevelBarTimer")
    log.info("ai: kills: XP bar timer of the own controller %s", ok and "started" or "not started")
end

-- The popup icon, only when in memory (the zombie / animal classes reference
-- it): no synchronous load on a client (a LoadAsset while the world streams
-- can hold the game; see sdc_ai_looks.asset). Without it the popup has no icon.
local function icon_of(path)
    local icon = ue.find_object(path)
    if not icon and not icons_tried[path] then
        icons_tried[path] = true
        log.info("ai: kills: popup icon %s not in memory; popups without it", path:match("([^%.]+)$") or path)
    end
    return icon
end

local function give_xp(pc, spec, popup)
    local comp = ue.prop(pc, "LevellingComponent")
    if not ue.valid(comp) then return end
    ensure_level_timer(comp)
    local gfl = ue.find_object(GFL_CDO)
    local lo, hi = spec.xp[1], spec.xp[2]
    -- every class: CurrentLevel * Random(lo, hi) * MultiplyValue = the game's XpMultiplierCalc
    local xp
    if gfl then
        local ok, v = pcall(function() return gfl:XpMultiplierCalc(lo, hi, pc) end)
        if ok and type(v) == "number" then xp = v end
    end
    if not xp then
        local lvl = tonumber(ue.prop(comp, "CurrentLevel")) or 1
        local mult = tonumber(ue.prop(comp, "MultiplyValue")) or 1
        xp = lvl * (lo + math.random() * (hi - lo)) * mult
    end
    -- AddXP(XP, LevelUp?, out XPOutput): UE4SS fills an out param into a table
    local out = {}
    local ok, err = pcall(function() comp:AddXP(xp, false, out) end)
    if not ok then
        log.err_throttled("ai.kills.xp", "ai: kills: AddXP: %s", tostring(err))
        return
    end
    if not popup or not FText or not gfl then return end
    local given = tonumber(out.XPOutput)
        or xp * (tonumber(ue.prop(comp, "Difficulty_MultiplierValue")) or 1)
    local text = spec.text .. ", XP Given: " .. tostring(math.floor(given))
    local icon = icon_of(spec.icon)
    pcall(function()
        gfl:CreateNotificationUI(FText(text), icon, { R = 1, G = 1, B = 1, A = 1 }, 2.0, false, pc)
    end)
end

local function skill_point(pc, chance)
    if math.random() > chance then return end
    -- GetSkillTreeManager(self).Add Skill Points(): the controller's TechTreeComponent
    local tech = ue.prop(pc, "TechTreeComponent")
    if ue.valid(tech) and ue.call(tech, "Add Skill Points") then
        M.stats.skill_points = M.stats.skill_points + 1
        log.info("ai: kills: a skill point (as the game gives for this kill)")
    end
end

-- AIKILL|kind|popup|skill
local function on_kill(f)
    if core.S.role ~= "client" then return end
    local kind = f[1] or "z"
    local spec = KINDS[kind]
    if not spec then
        log.err_throttled("ai.kills.kind", "ai: kills: unknown kind %s", tostring(kind))
        return
    end
    local pc = ue.local_pc()
    local v = ue.prop(pc, spec.field)
    if type(v) ~= "number" then
        log.err_throttled("ai.kills.field", "ai: kills: own controller has no %s", spec.field)
        return
    end
    ue.set_prop(pc, spec.field, v + 1)
    M.stats.got = M.stats.got + 1
    local popup
    if spec.popup == "cvar" then popup = core.cvar_bool("Game.XpPopUp", false) else popup = f[2] == "1" end
    give_xp(pc, spec, popup)
    if spec.skill and f[3] == "1" then skill_point(pc, spec.skill) end
    if core.first("kills.got", 8) then
        log.info("ai: kills: %s: own %s %d -> %d (popup %s)", spec.text, spec.field, v, v + 1, tostring(popup))
    end
end

-- AIDAY
local function on_day()
    if core.S.role ~= "client" then return end
    local pc = ue.local_pc()
    local v = ue.prop(pc, "DaysSurvived")
    if type(v) ~= "number" then return end
    ue.set_prop(pc, "DaysSurvived", v + 1)
    M.stats.days_got = M.stats.days_got + 1
    log.info("ai: kills: own DaysSurvived %d -> %d", v, v + 1)
    -- as EventBindMidnight: Delay(2) -> GetGameHUD.DaysSurvivedHUD()
    ue.delay("ai-day-hud", 2000, function()
        if core.S.role ~= "client" then return end
        local p = ue.local_pc()
        local hud = p and ue.try(function() return p:GetHUD() end)
        if ue.valid(hud) then ue.call(hud, "DaysSurvivedHUD") end
    end)
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local function bp(path, fn, name)
    core.hook({ path = path, kind = "bp", role = "host", feature = "kills", fn = fn, name = name })
end

function M.init(c)
    core = c
    for _, spec in ipairs(DAMAGE_FUNCS) do
        local short = spec[1]:match(":([%w_]+)$")
        core.hook({ path = spec[1], kind = "pre", role = "host", feature = "kills", always = true,
                    name = "kills." .. short, fn = function(_, ...) damage_pre(spec, ...) end })
        core.hook({ path = spec[1], kind = "post", role = "host", feature = "kills", always = true,
                    name = "kills." .. short, fn = damage_post })
    end
    bp(core.ZM .. "OnRep_IsDead?", on_zombie_dying)
    bp(core.ZM .. "Death", on_zombie_death)
    for _, human in ipairs(HUMANS) do
        local short = human.path:match("%.([%w_]+)$")
        bp(human.path .. ":ReceiveAnyDamage", on_human_damage, "kills." .. short .. ".damage")
        bp(human.path .. ":StopBurning", function(ctx_p) on_human_stop_burning(human.kind, ctx_p) end,
            "kills." .. short .. ".stopburning")
        bp(human.path .. ":Death", function(ctx_p, player_p) on_human_death(human, ctx_p, player_p) end,
            "kills." .. short .. ".death")
    end
    bp(BOSS .. ":DeathEvent", on_boss_death_event, "kills.boss")
    for _, animal in ipairs(ANIMALS) do
        local short = animal.path:match("%.([%w_]+)$")
        bp(animal.path .. ":ReceiveAnyDamage", function(ctx_p) on_animal_damage(animal, ctx_p) end,
            "kills." .. short .. ".damage")
        if animal.sync then bp(animal.path .. ":Death", on_bear_death, "kills." .. short .. ".death") end
    end
    bp(GM_MIDNIGHT, on_midnight)
end

function M.host_tick(now)
    -- no damage call spans ticks: anything left is an unbalanced pre / post
    if #scope > 0 then
        log.debug("ai: kills: %d damage scope(s) left over, cleared", #scope)
        scope = {}
    end
    for a, d in pairs(dying) do
        if now - d.t > d.ttl then
            dying[a] = nil
            -- a latent kill whose delayed settle did not run
            if d.latent then settle(d.vkey, d.label, d) end
        end
    end
    for a, h in pairs(hits) do
        if now - h.t > HIT_TTL then hits[a] = nil end
    end
    for k, t in pairs(credited) do
        if now - t > 120 then credited[k] = nil end
    end
    for k, t in pairs(seen_dead) do
        if now - t > 900 then seen_dead[k] = nil end
    end
end

function M.on_message(kind, f)
    if kind == "AIKILL" then
        on_kill(f)
    elseif kind == "AIDAY" then
        on_day()
    end
end

function M.reset()
    scope, dying, hits, credited, seen_dead = {}, {}, {}, {}, {}
    last_day = -1000
    level_timer = {}
end

function M.status_line()
    local s = M.stats
    return string.format("ai: kills marked=%d redirected=%d sent=%d host undone=%d host kept XP=%d got=%d skill points=%d days sent=%d got=%d",
        s.marked, s.redirected, s.sent, s.undone, s.host_kept_xp, s.got, s.skill_points, s.days_sent, s.days_got)
end

return M
