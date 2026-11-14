-- SDCoop: knockdown and revive by a teammate (host rule down_enabled,
-- default off; phases 1 and 2 of work\reports\18_nokdaun_proekt.md).
--
-- A deadly hit does not kill at once when somebody can help: the player
-- sits on the ground for down_bleedout_s seconds (60), a teammate gets it
-- up by looking at it and holding the interact key (F) for 5 s. Health
-- after the revive: as before the hit, at least 10 and at most 25. Hunger,
-- thirst, radiation, drowning and infection kill as usual (the victim is
-- its own causer and the damage is not an explosive's), so does a hit in
-- water. Single player: never. The host decides everything.
--
-- Who can help (a "rescuer"): the host while it stands; a client with this
-- version (DOWNCAP) that stands, or that is on its death screen while the
-- host lives (its "Respawn - Near Host" puts it next to the host). Players
-- with an older mod, or still joining, are not rescuers and never go down.
--
-- Host, the hit (entries on sdc_ai's shared ApplyDamage hook, after
-- sdc_ffire's; nothing here but number changes and marks):
--   pre  "down.damage": a watched character only (candidates, the downed,
--        open probes: one table lookup by address, no class read). Downed:
--        BaseDamage 0 (nobody finishes a downed player, friendly fire or
--        not). A probe younger than PROBE_TTL_S on it: the hit adds to the
--        probe, BaseDamage 0 (a shotgun's pellets). A candidate's hit of at
--        least its health that is not its own state's damage: a probe -
--        BaseDamage = half its health, the hit remembered.
--   post "down.measure": the health right after the probe hit (a post-hook
--        of a function with a return value gets (Context, ReturnValue,
--        params...): the victim is the third argument, as sdc_skilltree's).
--   The next frame (frame_tick): lost = h0 - h1, divisor = probe / lost (the
--   game's Toughness and armour only divide), real = hit / divisor. Not
--   deadly: health = h0 - real. Deadly: the game's own Deathbringer(out
--   Used?) for that character (its "player 0" is that player's, sdc_ctx);
--   used: it stands at 25. Else the player goes down - or dies the game's
--   way when the rule went off, it swims, or nobody can help any more. The
--   game's own Deathbringer fired during the probe hit (its flag turned on):
--   the game's result is kept. Measured lessened, but dead by the frame:
--   something else killed it (nothing done, no fuse).
--   ApplyRadialDamage pre "down.radial": the grenadier's blast (it never
--   calls ApplyDamage; one call per actor in its own sphere): candidates it
--   could kill in its radius get CanTakeDamage? off for that call and their
--   line of sight is traced right there, the way the game's own check does
--   it (Camera channel, the causer - the grenadier itself - ignored); the
--   next frame the flags come back first, then those in sight get the same
--   damage through ApplyDamage (the path above).
--   PauseScreen.RemoveSaveAndSuicideButton (Blueprint, post) "down.pause":
--   while somebody is down the host's pause menu has no Save, QuickSave,
--   Suicide (the 250 ms tick does the same as a fallback).
-- Going down: health 1, CanTakeDamage? off, the ZombieCanAttack tag renamed
--   SDCDown in place, a burn put out. In a vehicle: out first (sdc_vehicles:
--   the host's own exit / the client unseated), at most VEH_EXIT_S, else it
--   dies there. In the air or on a ladder: until it stands on the ground (at
--   most LAND_S, then the floor below). Then "down": the spot is kept, the
--   zombies within ZOMBIE_CM (their sight is lost at 50 m, sdc_stealth) that
--   target it drop it (the game's "lost sight" writes) - at once and every
--   second while it is down: without the tag the game never runs "lost
--   sight" for it, and the attack task may write its old target back
--   (BTTask_FindAttackTargetLocation @743) -, DOWN to the clients with DOWNCAP.
-- While down (host, 250 ms, each record in its own pcall): health held at
--   1, bound to its character (address + name; gone / dead / another one:
--   closed without damage), a client's copy kept within POS_CM of the spot
--   (it moves itself back on DOWN; POS_N moves in POS_WIN_S: dies), the
--   revive progress (one for all rescuers; it grows while at least one
--   rescuer holds within REVIVE_KEEP_CM, starts within REVIVE_START_CM, goes
--   back to 0 only when nobody holds), the bleed-out timer, a safety margin.
-- Ends: revived (health 10..25, the ordinary bleeding stopped), the rule
--   switched off (everybody up), bled out / gave up (hold F 3 s) / nobody
--   left to help / moved away -> ApplyDamage(999) with this module's bypass:
--   the game's own death (loot box, death screen, respawn); Deathbringer at
--   that moment counts as a revive.
-- Fuse: a failed BaseDamage write, a probe hit the game did not lessen (the
--   write had no effect: the player took more than the probe or died of
--   it), or FUSE_N errors of this module's hooks or tick within FUSE_WIN_S:
--   the module switches itself off until the game restarts, everybody gets
--   up, the host gets a notice.
-- Saves and leaving (phase 2): a downed client's sdc_persist record carries
--   down_left / down_h0 (its 5 s snapshot and the leave snapshot); on its
--   return (after its inventory is back, PSDONE) it goes down again with
--   max(left, RESTORE_MIN_S) once it is ready (DOWNCAP ready), stands up
--   (health 10..25) without the rule or with an older mod, dies the game's
--   way when nobody can help. The host's own downed state is not saved
--   (only a quick save / the game's autosave could catch it; the mod's own
--   autosave waits, the pause menu has no Save).
-- Messages (no names in them: PlayerId, the same on every machine):
--   RULES|down|<0/1>|<seconds>   host -> clients let in (sdc_admin routes it here)
--   DOWNCAP|1[|ready]             client -> host: this version knows knockdown; ready: own character, cover gone
--   DOWN|<id>|1|<left s>|<progress ms>|<rescuer ids ;>|x|y|z|yaw   host -> DOWNCAP clients, on a change and every DOWN_REPEAT_S
--   DOWN|<id>|0|<up/dead/left/off/gone>|<by id>                     host -> DOWNCAP clients, the end
--   REVIVE|<id>|<1/0>             client -> host: holding the key over that downed player
--   GIVEUP                        client -> host: held the key 3 s while down
--   DOWNQ|<id>                    client -> host: no DOWN about its own state for COPY_TIMEOUT_S: the state again
-- A client frees its own character only on DOWN|..|0, a world change, its
-- own death or another character; another player's copy after
-- COPY_TIMEOUT_S without DOWN.
-- Pose, keys, bars, notices on every machine: sdc_down_pose. Debug
-- commands (phase 0 checks): sdc_down_probe, loaded by the first
-- sdcoop_down command.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local ai = require("sdc_ai")
local net = require("sdc_net")

local M = {
    stats = { probes = 0, stood = 0, nothing = 0, saved = 0, downs = 0, revives = 0, deaths = 0, gaveup = 0,
              closed = 0, kill_failed = 0, post = 0, frame = 0, fuse = 0, hook_errors = 0, tick_errors = 0,
              radial = 0, radial_hits = 0, diag = 0, restores = 0, zombies = 0, moved = 0, off = 0, killed_direct = 0,
              other_death = 0, db_probe = 0 },
}

local C = {
    BLEED_S = 60, BLEED_MIN_S = 15, BLEED_MAX_S = 300,
    REVIVE_S = 5, GIVEUP_S = 3,
    REVIVE_START_CM = 250, REVIVE_KEEP_CM = 300,
    HP_MIN = 10, HP_MAX = 25, SAFETY_S = 30,
    DOWN_REPEAT_S = 10, COPY_TIMEOUT_S = 30, QUERY_EVERY_S = 10,
    VEH_EXIT_S = 2, LAND_S = 3,
    POS_CM = 200, POS_N = 3, POS_WIN_S = 10,
    PROBE_TTL_S = 1, RESTORE_MIN_S = 20, RESTORE_WAIT_S = 3, RESTORE_OLD_S = 20, RESTORE_MAX_S = 120,
    ZOMBIE_CM = 5000, ZOMBIE_LOG_S = 10, NOTICE_AT = { 30, 10 },
    FUSE_N = 5, FUSE_WIN_S = 60, REC_ERRORS = 3,
    DIAG_DROP = 5, NEAR_CM = 1000, CAP_AGAIN_S = 10,
}
M.C = C

local APPLY_DAMAGE = "/Script/Engine.GameplayStatics:ApplyDamage"
local APPLY_RADIAL = "/Script/Engine.GameplayStatics:ApplyRadialDamage"
local PAUSE_FN = "/Game/UI/Menus/PauseScreen/PauseScreen.PauseScreen_C:RemoveSaveAndSuicideButton"
local ZOMBIE_CLASS = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local BB_LIB = "/Script/AIModule.Default__AIBlueprintHelperLibrary"
local PUSH_LIB = "/Script/Engine.Default__NetPushModelHelpers"
local TAG, TAG_DOWN = "ZombieCanAttack", "SDCDown"
local PAUSE_BUTTONS = { "Save", "QuickSave", "Suicide" }
-- the explosives' DamageTypeClass (as sdc_ffire): one's own grenade puts one down
local BLAST_DAMAGE = { Damage_Body_C = true }
local NO_COLOR = { R = 0, G = 0, B = 0, A = 0 }
local OBJ_PAWN = 2            -- EObjectTypeQuery of ECC_Pawn (sdc_ai_hud's query)
local TRACE_CAMERA = 1        -- ETraceTypeQuery: TraceTypeQuery2 = the Camera channel the grenadier's blast uses (ECC 4)

local S = nil
local addr = ctx.addr
local clock = os.clock
local pose = nil              -- sdc_down_pose (install)

-- Host state. Kept: keys, addresses, names, numbers; never a game object.
local H = {
    downs = {},        -- [key] = record ("host" or the session key)
    pending = {},      -- [character address] = probe { key, h0, dmg, probe, extra, t, h1 }
    watch = {},        -- [character address] = true: what the damage hook looks at
    cand = {},         -- [character address] = key: may go down now
    down_addr = {},    -- [character address] = key: a record in any phase
    armed = false,     -- the rule on, a player connected, not fused
    probe_open = false,
    bypass = false,    -- our own deadly damage
    holding = {},      -- [rescuer key] = { target = key, t }
    restore = {},      -- [key] = { left, h0, name, at, paddr, gone_at }
    blasts = {},
    views = {},        -- [id] = view (sdc_down_pose)
    hit_at = {},       -- [character address] = clock() of its last ApplyDamage (diagnostics)
    hp_was = {},       -- [character address] = health a second ago (diagnostics)
    half = {},         -- [character address] = true: sdcoop_down half (one probe, no knockdown)
    log_causes = false, log_radial = false,
    pause_hidden = false,
    last_second = 0, last_tick = nil,
    fuse = { off = false, why = nil, errs = {} },
    rule_was = nil,
}
-- Client state.
local CL = {
    rule = nil, secs = nil, told = nil,
    cap_conn = nil, ready_sent = false,
    views = {},        -- [id] = view
    last_q = -100,
}
M.last_end = {}       -- [id] = { why, by, at }: the last end of each player's state (sdc_down_pose)
local hooks = {}
local last_role = nil

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function p_get(p) return p:get() end
local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(p_get, p)
    if ok then return v end
    return nil
end

local function rule_on() return cfg.get("down_enabled") == true end
local function bleed_s()
    local n = tonumber(cfg.get("down_bleedout_s")) or C.BLEED_S
    return math.max(C.BLEED_MIN_S, math.min(C.BLEED_MAX_S, math.floor(n)))
end
M.bleed_s = bleed_s
local function remote_present() return S ~= nil and #(S.remote_pcs or {}) > 0 end
local function is_host() return S ~= nil and S.role == "host" end

local function dead(p) return ue.prop(p, "PlayerDead?") == true end
local function med(p) return ue.prop(p, "MedicalComponent") end
local function health(p)
    local h = ue.prop(med(p), "Health")
    if type(h) == "number" then return h end
    return nil
end
local function set_health(p, v)
    if not ue.set_prop(med(p), "Health", v) then return false end
    pcall(function() p:SendHealthToClient(v) end)
    return true
end
local function clamp_hp(h0)
    return math.max(C.HP_MIN, math.min(C.HP_MAX, tonumber(h0) or C.HP_MIN))
end
M.clamp_hp = clamp_hp

local function cmc_is(p, fn)
    local cmc = ue.prop(p, "CharacterMovement")
    if not ue.valid(cmc) then return false end
    return ue.try(function() return cmc[fn](cmc) end) == true
end
local function attach_parent(p) return ue.try(function() return p:GetAttachParentActor() end) end
local function in_vehicle(p)
    if ue.prop(p, "InVehicle?") == true then return true end
    return ue.valid(attach_parent(p))
end
M.in_vehicle = in_vehicle
local function grounded(p)
    return not cmc_is(p, "IsFalling") and ue.prop(p, "ClimbingLadder?") ~= true and not in_vehicle(p)
end

local function hdist(a, b)
    if not a or not b then return math.huge end
    local dx, dy = a.X - b.X, a.Y - b.Y
    return math.sqrt(dx * dx + dy * dy)
end
local function dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
M.dist, M.hdist = dist, hdist

-- PlayerId of a character or a controller (its PlayerState), or nil.
local function player_id(o)
    local ps = ue.prop(o, "PlayerState")
    if not ue.valid(ps) then return nil end
    local ok, id = pcall(function() return ps:GetPlayerId() end)
    if ok and type(id) == "number" then return math.floor(id) end
    local v = ue.prop(ps, "PlayerId")
    if type(v) == "number" then return math.floor(v) end
    return nil
end
M.player_id = player_id

-- This machine's own PlayerId.
function M.my_id()
    local pc = ue.local_pc()
    return pc and player_id(pc) or nil
end

-- Host: the character of a session key ("host" = its own), or nil.
local function pawn_of_key(key)
    if key == "host" then return ue.local_pawn() end
    local r = S and S.remote and S.remote[key]
    if not r or not ue.valid(r.pc) then return nil end
    return ue.pawn_of(r.pc)
end
M.pawn_of_key = pawn_of_key

local function name_of_key(key)
    if key == "host" then return cfg.player_name() end
    local r = S and S.remote and S.remote[key]
    return r and tostring(r.name or "?") or "?"
end

local function id_of_key(key)
    if key == "host" then
        local pc = ue.local_pc()
        return pc and player_id(pc) or nil
    end
    local r = S and S.remote and S.remote[key]
    if not r or not ue.valid(r.pc) then return nil end
    return player_id(r.pc)
end

local function key_of_id(id)
    if id == nil then return nil end
    if id_of_key("host") == id then return "host" end
    for key, r in pairs(S and S.remote or {}) do
        if ue.valid(r.pc) and player_id(r.pc) == id then return key end
    end
    return nil
end
M.key_of_id = key_of_id

local function key_of_pc(pc)
    if not ue.valid(pc) then return nil end
    local key = ue.name(pc)
    if S and S.remote and S.remote[key] then return key end
    return nil
end

-- A player's name for a notice: the host's own records; a client: the
-- character's PlayerState (no names travel in DOWN), else nil.
function M.name_of_id(id)
    if id == nil then return nil end
    if is_host() then
        local key = key_of_id(id)
        return key and name_of_key(key) or nil
    end
    for _, p in ipairs(ue.player_chars() or {}) do
        if ue.valid(p) and player_id(p) == id then
            local ps = ue.prop(p, "PlayerState")
            local n = ue.valid(ps) and ue.str(ue.try(function() return ps:GetPlayerName() end)) or ""
            if n ~= "" then return n end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Texts (English log, Russian screen; the game's own notifications)
-- ---------------------------------------------------------------------------

local TEXT = {
    down_you          = { "You are badly wounded. Wait for help: %d s left. Hold [%s] for 3 s to give up.",
                          "Вы тяжело ранены. Ждите помощи — осталось %d с. Держите [%s] 3 с, чтобы сдаться." },
    down_left         = { "%d s left: wait for help.", "Осталось %d с — ждите помощи." },
    down_up_by        = { "%s got you back on your feet.", "Вас поднял %s." },
    down_up           = { "You're back on your feet.", "Вы снова на ногах." },
    down_up_off       = { "The host turned knockdown off: you're back on your feet.",
                          "Хост выключил нокдаун — вы снова на ногах." },
    down_hint         = { "Hold [%s] to get %s up.", "Держите [%s], чтобы поднять игрока %s." },
    down_on_host      = { "Knockdown is on: a deadly hit puts a player on the ground, a teammate can get them up.",
                          "Нокдаун включён: смертельный удар сажает игрока на землю, напарник может его поднять." },
    down_off_host     = { "Knockdown is off: a deadly hit kills at once.",
                          "Нокдаун выключен: смертельный удар убивает сразу." },
    down_join_on      = { "Knockdown is on in this world: a deadly hit puts you on the ground, a teammate can get you up (hold F).",
                          "В этом мире включён нокдаун: от смертельного удара вы сядете на землю, напарник может вас поднять (держать F)." },
    down_turned_on    = { "The host turned knockdown on: a deadly hit puts you on the ground, a teammate can get you up (hold F).",
                          "Хост включил нокдаун: от смертельного удара вы сядете на землю, напарник может вас поднять (держать F)." },
    down_turned_off   = { "The host turned knockdown off: a deadly hit kills at once.",
                          "Хост выключил нокдаун: смертельный удар убивает сразу." },
    down_save_refused = { "Saving is not available while someone is down.",
                          "Сохранение недоступно, пока кто-то лежит раненый." },
    down_fuse         = { "Knockdown is off until the game restarts: a mod error (details in UE4SS.log). Everybody is back on their feet.",
                          "Нокдаун выключен до перезапуска игры: ошибка мода (подробности в UE4SS.log). Все лежавшие встали." },
    pull_down         = { "%s is down: can't be pulled.", "%s лежит раненый — притянуть нельзя." },
    pull_host_down    = { "You are down: moving is not available.", "Вы лежите раненый — перенос недоступен." },
    goto_target_down  = { "%s is down: you can't go to them.", "%s лежит раненый — к нему нельзя переместиться." },
    goto_down         = { "You are down: moving is not available.", "Вы лежите раненый — перенос недоступен." },
    unstuck_down      = { "Your character is down: wait for help.", "Ваш персонаж лежит раненый: ждите помощи." },
}
M.TEXT = TEXT
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end
-- the bars' captions: sdc_i18n STR down_bar_* (sdc_down_pose, the player's language)

-- ---------------------------------------------------------------------------
-- Fuse
-- ---------------------------------------------------------------------------

local cleanup   -- (below)

local function fuse(why)
    if H.fuse.off then return end
    H.fuse.off, H.fuse.why = true, tostring(why)
    M.stats.fuse = M.stats.fuse + 1
    log.err("[DOWN] knockdown switched OFF until the game restarts: %s", tostring(why))
    pcall(cleanup, "fuse: " .. tostring(why), true)
    if is_host() then log.say("down_fuse", "err", 10) end
end
M.fuse = fuse

local function count_error(kind, err)
    local now = clock()
    local list = H.fuse.errs
    list[#list + 1] = now
    while #list > 0 and now - list[1] > C.FUSE_WIN_S do table.remove(list, 1) end
    log.err_throttled("down." .. kind, "[DOWN] %s: %s", kind, tostring(err))
    if #list >= C.FUSE_N then fuse(string.format("%d errors in %d s (last: %s: %s)", #list, C.FUSE_WIN_S, kind, tostring(err))) end
end

-- ---------------------------------------------------------------------------
-- Host: who can help, who can go down
-- ---------------------------------------------------------------------------

local function host_alive()
    local hp = ue.local_pawn()
    return hp ~= nil and not dead(hp)
end

-- A client that may take part: this version, let in, in the world.
local function client_ok(r)
    return r ~= nil and r.downcap == true and r.hello == true and r.access == "ok" and r.spawned_once == true
        and not r.kicked and ue.valid(r.pc)
end

-- Rescuers besides `except` (a key): a standing host, standing DOWNCAP
-- clients, DOWNCAP clients on their death screen while the host lives.
local function rescuers(except)
    local n = 0
    local hp = ue.local_pawn()
    local host_lives = hp ~= nil and not dead(hp)
    if except ~= "host" and host_lives and not H.downs.host then n = n + 1 end
    for key, r in pairs(S and S.remote or {}) do
        if key ~= except and client_ok(r) then
            local p = ue.pawn_of(r.pc)
            if p and not dead(p) then
                if not H.downs[key] then n = n + 1 end
            elseif (r.dead == true or (p and dead(p))) and host_lives then
                n = n + 1
            end
        end
    end
    return n
end
M.rescuers = rescuers

-- The candidates and the hook's watch list, again (each second and on
-- every change).
local function recount()
    local cand, watch, da = {}, {}, {}
    H.armed = is_host() and remote_present() and rule_on() and not H.fuse.off
    if H.armed then
        local hp = ue.local_pawn()
        local ha = hp and addr(hp)
        if ha and not dead(hp) and not H.downs.host and rescuers("host") > 0 then cand[ha] = "host" end
        for key, r in pairs(S.remote or {}) do
            if client_ok(r) and not H.downs[key] then
                local p = ue.pawn_of(r.pc)
                local a = p and addr(p)
                if a and not dead(p) and rescuers(key) > 0 then cand[a] = key end
            end
        end
    end
    for key, rec in pairs(H.downs) do
        if rec.paddr then
            watch[rec.paddr] = true
            da[rec.paddr] = key
        end
    end
    for a in pairs(H.pending) do watch[a] = true end
    for a in pairs(cand) do watch[a] = true end
    for a in pairs(H.half) do watch[a] = true end
    H.cand, H.watch, H.down_addr = cand, watch, da
end
M.recount = recount

-- ---------------------------------------------------------------------------
-- Host: the hooks
-- ---------------------------------------------------------------------------

local function blast_damage(type_p)
    local c = get(type_p)
    if not ue.valid(c) then return false end
    return BLAST_DAMAGE[ue.short(c)] == true
end

local function set_damage(dmg_p, v)
    return (pcall(function() dmg_p:set(v) end))
end

-- GameplayStatics.ApplyDamage(DamagedActor, BaseDamage, EventInstigator,
-- DamageCauser, DamageTypeClass), pre. Cheap for every hit in the game:
-- one address lookup unless the victim is watched. Every object is checked
-- with ue.valid before any call on it (the 17:36 crash: GetClass on a None
-- causer).
local function on_damage(_, victim_p, dmg_p, _, causer_p, type_p)
    if H.bypass then return end
    local victim = get(victim_p)
    if not ue.valid(victim) then return end
    local a = addr(victim)
    if a == nil or not H.watch[a] then return end
    local now = clock()
    H.hit_at[a] = now
    if H.log_causes then
        local causer = get(causer_p)
        local t = get(type_p)
        log.info("[DOWN] probe causes: %s hit for %s by %s (%s)", ue.short(victim), tostring(get(dmg_p)),
            ue.valid(causer) and ue.short(causer) or "None", ue.valid(t) and ue.short(t) or "None")
    end
    if H.down_addr[a] then
        set_damage(dmg_p, 0.0)
        return
    end
    local pr = H.pending[a]
    if pr and now - pr.t <= C.PROBE_TTL_S then
        pr.extra = pr.extra + (tonumber(get(dmg_p)) or 0)
        set_damage(dmg_p, 0.0)
        return
    end
    local key = H.cand[a]
    local half = H.half[a]
    if not key and not half then return end
    local dmg = tonumber(get(dmg_p)) or 0
    if dmg <= 0 then return end
    local hp = health(victim)
    if not hp then return end
    if not half then
        if dmg < hp then return end   -- the game only lessens damage: not deadly
        local causer = get(causer_p)
        if ue.valid(causer) and addr(causer) == a and not blast_damage(type_p) then return end   -- its own state
    end
    local probe = hp * 0.5
    if not set_damage(dmg_p, probe) then
        fuse("the hit's BaseDamage could not be changed (ApplyDamage pre-hook)")
        return
    end
    H.pending[a] = { key = key or "?", h0 = hp, dmg = dmg, probe = probe, extra = 0, t = now, half = half,
                     db0 = ue.prop(victim, "DeathbringerSkillUsed?") == true }
    if half then H.half[a] = nil end
    H.watch[a] = true
    H.probe_open = true
    M.stats.probes = M.stats.probes + 1
end

-- ApplyDamage, post: the health right after the probe hit. UE4SS passes a
-- post-hook of a function with a return value (Context, ReturnValue,
-- params...): the victim is the third argument (LuaMod.cpp, "we store that
-- as the second param"; sdc_skilltree's IsUnlocked post-hook).
local function on_damage_post(_, _ret, victim_p)
    local victim = get(victim_p)
    if not ue.valid(victim) then return end
    local pr = H.pending[addr(victim) or 0]
    if not pr or pr.h1 ~= nil then return end
    pr.h1 = health(victim)
end

-- The blast's line of sight from `o` to the character `p` at `l`, the way
-- the game's ApplyRadialDamage checks it (ComponentIsDamageableFrom: the
-- Camera channel, the causer and the victim ignored). Returns traced, seen.
local function blast_sight(p, o, l, causer)
    local ksl = ue.ksl()
    if not ksl or not l then return false, false end
    local ignore = {}
    if ue.valid(causer) then ignore[1] = causer end
    local hit = {}
    local ok, got = pcall(function()
        return ksl:LineTraceSingle(p, o, l, TRACE_CAMERA, false, ignore, 0, hit, true, NO_COLOR, NO_COLOR, 0.0)
    end)
    if not ok then return false, false end
    -- nothing in the way, or what it hit is right at the character
    local at = ue.vec(hit.ImpactPoint) or ue.vec(hit.Location)
    return true, got ~= true or (at ~= nil and dist(at, l) <= 120)
end

-- ApplyRadialDamage(WorldContext, BaseDamage, Origin, DamageRadius,
-- DamageTypeClass, IgnoreActors, DamageCauser, InstigatedBy, bDoFullDamage,
-- DamageChannel), pre: the grenadier's blast (BP_MasterZombie @4870-5050:
-- once per actor in its own sphere, before it kills itself @4802). The line
-- of sight is traced here, at the moment of the game's own check, with the
-- grenadier (the causer) still standing and ignored: nothing is kept to the
-- next frame but keys and the result.
local function on_radial(_, _, dmg_p, origin_p, radius_p, _, _, causer_p)
    if H.bypass then return end
    local dmg = tonumber(get(dmg_p))
    local o = ue.vec(get(origin_p))
    local radius = tonumber(get(radius_p))
    if H.log_radial then
        log.info("[DOWN] probe radial: ApplyRadialDamage %s damage at %s radius %s", tostring(dmg),
            o and string.format("%.0f,%.0f,%.0f", o.X, o.Y, o.Z) or "?", tostring(radius))
    end
    if not dmg or not o or not radius or dmg <= 0 then return end
    local hits = {}
    local causer = nil
    for a, key in pairs(H.cand) do
        local p = pawn_of_key(key)
        if p and addr(p) == a then
            local l = ue.location(p)
            local h = health(p)
            if l and h and dist(l, o) <= radius + 40 and h <= dmg then
                if ue.set_prop(med(p), "CanTakeDamage?", false) then
                    if causer == nil then causer = get(causer_p) or false end
                    local traced, seen = blast_sight(p, o, l, causer)
                    hits[#hits + 1] = { key = key, traced = traced, seen = seen }
                end
            end
        end
    end
    if #hits > 0 then
        H.blasts[#H.blasts + 1] = { o = o, dmg = dmg, hits = hits, t = clock() }
        M.stats.radial = M.stats.radial + 1
    end
end

-- PauseScreen_C.RemoveSaveAndSuicideButton, post (host): the game showed its
-- Save / QuickSave / Suicide again.
local W_mod = nil
local function widgets()
    W_mod = W_mod or package.loaded["sdc_widgets"]
    return W_mod
end
local function hide_pause(w)
    local W = widgets()
    if not W or not ue.valid(w) then return 0 end
    local n = 0
    for _, name in ipairs(PAUSE_BUTTONS) do
        local b = W.child(w, name)
        if ue.valid(b) and W.visible(b) then
            W.hide(b)
            n = n + 1
        end
    end
    if n > 0 then H.pause_hidden = true end
    return n
end
local function on_pause(ctx_p)
    local w = get(ctx_p)
    if not ue.valid(w) then return end
    local n = hide_pause(w)
    if n > 0 then log.info("[DOWN] the host's pause menu: Save / QuickSave / Suicide hidden (somebody is down)") end
end

local function guarded(kind, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            M.stats.hook_errors = M.stats.hook_errors + 1
            count_error("hook " .. kind, err)
        end
    end
end

local function any_down() return next(H.downs) ~= nil end
M.any_down_host = any_down

local function damage_gate()
    return is_host() and not H.fuse.off and (H.armed or next(H.downs) ~= nil or next(H.pending) ~= nil
        or next(H.half) ~= nil)
end
local function measure_gate() return H.probe_open == true end
local function radial_gate() return is_host() and not H.fuse.off and ((H.armed and next(H.cand) ~= nil) or H.log_radial) end
local function pause_gate() return is_host() and (any_down() or H.pause_hidden) end

-- ---------------------------------------------------------------------------
-- Host: protection, tags, zombies, bleeding
-- ---------------------------------------------------------------------------

-- The tag `from` renamed `to` in place (the list keeps its length). Returns
-- the index, or nil.
local function tag_swap(p, from, to)
    local idx = nil
    local ok = pcall(function()
        local tags = p.Tags
        local i = 0
        tags:ForEach(function(_, e)
            i = i + 1
            if idx == nil and ue.str(e:get()) == from then idx = i end
        end)
        if idx then tags[idx] = FName(to) end
    end)
    if not ok then return nil end
    return idx
end
M.tag_swap = tag_swap

local function protect(p, rec)
    local okc = ue.set_prop(med(p), "CanTakeDamage?", false)
    rec.tag = tag_swap(p, TAG, TAG_DOWN)
    if ue.prop(p, "Burning?") == true then
        rec.burn = pcall(function() p:StopBurning() end)
    end
    if not okc then log.warn("[DOWN] %s: CanTakeDamage? could not be set off (the hook still drops its damage)", rec.name) end
end

local function unprotect(p, rec)
    ue.set_prop(med(p), "CanTakeDamage?", true)
    if rec and rec.tag then tag_swap(p, TAG_DOWN, TAG) end
end
M.unprotect = unprotect

-- The ordinary bleeding stopped as sdc_consume's cure does it (the flag,
-- its replication mark, its OnRep). Heavy bleeding, bones, infection stay.
local function stop_bleed(p)
    local m = med(p)
    if not ue.valid(m) or ue.prop(m, "Bleed?") ~= true then return false end
    if not ue.set_prop(m, "Bleed?", false) then return false end
    local push = ue.find_object(PUSH_LIB)
    if push then pcall(function() push:MarkPropertyDirtyFromRepIndex(m, 2, FName("Bleed?")) end) end
    pcall(function() m["OnRep_Bleed?"](m) end)
    return true
end
M.stop_bleed = stop_bleed

-- The host's copy of a client: the action flags (not replicated: an
-- edited client's own shots / swings are refused there too).
local FLAGS = { "IsPlayerRolling?", "CurrentlyChangingWeapon?", "Attacking?" }
M.FLAGS = FLAGS
local function copy_flags(p, on)
    for _, f in ipairs(FLAGS) do ue.set_prop(p, f, on) end
end

-- Zombies within ZOMBIE_CM whose AttackTarget is `p` drop it the way the
-- game's "lost sight" branch does (BP_ZombieAIController @541-925). One
-- engine query, no pass over every zombie, nothing kept.
local function drop_zombies(p, loc)
    local ksl, wc, cls = ue.ksl(), ue.local_pc(), ue.find_object(ZOMBIE_CLASS)
    if not (ksl and wc and cls and loc) then return 0 end
    local out = {}
    local ok = pcall(function()
        ksl:SphereOverlapActors(wc, { X = loc.X, Y = loc.Y, Z = loc.Z }, C.ZOMBIE_CM, { OBJ_PAWN }, cls, {}, out)
    end)
    if not ok then return 0 end
    local pa = addr(p)
    local lib = ue.find_object(BB_LIB)
    local n = 0
    for i = 1, #out do
        local z = ue.elem(out[i])
        local ctrl = ue.valid(z) and ue.prop(z, "Controller") or nil
        if ue.valid(ctrl) then
            local bb = lib and ue.try(function() return lib:GetBlackboard(ctrl) end) or nil
            if not ue.valid(bb) then bb = ue.prop(ctrl, "Blackboard") end
            if ue.valid(bb) then
                local t = ue.try(function() return bb:GetValueAsObject(FName("AttackTarget")) end)
                if ue.valid(t) and addr(t) == pa then
                    pcall(function() bb:SetValueAsBool(FName("CanSeePlayer?"), false) end)
                    pcall(function() bb:ClearValue(FName("AttackTarget")) end)
                    ue.set_prop(ctrl, "Combat", false)
                    pcall(function() bb:SetValueAsBool(FName("IsAlert?"), true) end)
                    pcall(function() bb:SetValueAsVector(FName("LastHeardLocation"), { X = loc.X, Y = loc.Y, Z = loc.Z }) end)
                    n = n + 1
                end
            end
        end
    end
    M.stats.zombies = M.stats.zombies + n
    return n
end
M.drop_zombies = drop_zombies

-- The floor under `loc` (a line trace down), or nil.
local function floor_under(p, loc)
    local ksl = ue.ksl()
    if not ksl or not loc then return nil end
    local hit = {}
    local ok, got = pcall(function()
        return ksl:LineTraceSingle(p, { X = loc.X, Y = loc.Y, Z = loc.Z + 50 }, { X = loc.X, Y = loc.Y, Z = loc.Z - 5000 },
            0, false, { p }, 0, hit, true, NO_COLOR, NO_COLOR, 0.0)
    end)
    if not ok or got ~= true then return nil end
    local g = ue.vec(hit.ImpactPoint) or ue.vec(hit.Location)
    if not g then return nil end
    return { X = loc.X, Y = loc.Y, Z = g.Z + 95 }
end

-- ---------------------------------------------------------------------------
-- Host: messages
-- ---------------------------------------------------------------------------

local function down_pcs()
    local out = {}
    for _, r in pairs(S and S.remote or {}) do
        if r.downcap == true and r.access == "ok" and ue.valid(r.pc) and not r.kicked then out[#out + 1] = r.pc end
    end
    return out
end

local function rec_left(rec, now)
    return math.max(0, rec.bleed_s - ((now or clock()) - rec.t0))
end
M.rec_left = rec_left

local function resc_ids(rec)
    local ids = {}
    for k in pairs(rec.resc or {}) do
        local id = id_of_key(k)
        if id then ids[#ids + 1] = tostring(id) end
    end
    table.sort(ids)
    return table.concat(ids, ";")
end

local function down_fields(rec, now)
    local s = rec.spot or {}
    return tostring(rec.id or ""), "1", string.format("%d", math.ceil(rec_left(rec, now))),
        string.format("%d", math.floor((rec.prog or 0) * 1000)), resc_ids(rec),
        string.format("%.0f", s.X or 0), string.format("%.0f", s.Y or 0), string.format("%.0f", s.Z or 0),
        string.format("%.0f", s.yaw or 0)
end

local function send_down(rec, pc)
    if rec.phase ~= "down" or rec.id == nil then return end
    local now = clock()
    rec.sent_at = now
    local pcs = pc and { pc } or down_pcs()
    for _, x in ipairs(pcs) do net.send_to(x, "DOWN", down_fields(rec, now)) end
end

local function send_end(rec, why, by_key)
    if not rec or rec.id == nil then return end
    local by = by_key and id_of_key(by_key) or nil
    M.last_end[rec.id] = { why = why, by = by, at = clock() }
    if rec.phase ~= "down" and not rec.sent_at then return end   -- the clients never heard of it
    for _, pc in ipairs(down_pcs()) do
        net.send_to(pc, "DOWN", tostring(rec.id), "0", why, by and tostring(by) or "")
    end
end

-- The host's views for sdc_down_pose (the records in phase "down").
local function host_views()
    local v = {}
    local now = clock()
    for _, rec in pairs(H.downs) do
        if rec.phase == "down" and rec.id ~= nil then
            local ids = {}
            for k in pairs(rec.resc or {}) do
                local id = id_of_key(k)
                if id then ids[id] = true end
            end
            v[rec.id] = { id = rec.id, left = rec_left(rec, now), at = now, bleed_s = rec.bleed_s,
                          prog = rec.prog or 0, resc = ids, spot = rec.spot, name = rec.name, key = rec.key }
        end
    end
    H.views = v
end

-- ---------------------------------------------------------------------------
-- Host: going down, getting up, dying
-- ---------------------------------------------------------------------------

local function vehicles() return package.loaded["sdc_vehicles"] end

-- `key`'s character goes down (h0: health before the hit; left: seconds
-- left, nil = the whole time).
local function start(key, p, h0, left, why)
    local now = clock()
    H.restore[key] = nil
    local rec = {
        key = key, id = id_of_key(key), name = name_of_key(key),
        paddr = addr(p), pname = ue.short(p), h0 = h0,
        bleed_s = bleed_s(), t0 = now, phase = "land", t_phase = now,
        prog = 0, resc = {}, moved = {}, errs = 0, why = why,
    }
    if left then
        left = math.max(C.RESTORE_MIN_S, left)
        if left > rec.bleed_s then rec.bleed_s = left end
        rec.t0 = now - (rec.bleed_s - left)
    end
    H.downs[key] = rec
    set_health(p, 1)
    protect(p, rec)
    local veh = in_vehicle(p)
    if veh then
        rec.phase = "exit"
        local vm = vehicles()
        local fn = vm and (key == "host" and vm.force_out_host or vm.unseat_client) or nil
        local ok, res = false, "no sdc_vehicles"
        if type(fn) == "function" then
            if key == "host" then ok, res = pcall(fn, "downed") else ok, res = pcall(fn, key, "downed") end
        end
        rec.t_phase = clock()
        log.info("[DOWN] %s is down in a vehicle: out first (%s: %s)", rec.name, ok and "asked" or "FAILED", tostring(res))
    end
    M.stats.downs = M.stats.downs + 1
    log.info("[DOWN] %s goes down (%s): health before %.1f, %d s to bleed out, tag %s, phase %s", rec.name,
        tostring(why), tonumber(h0) or -1, math.floor(rec_left(rec, now)), rec.tag and "renamed" or "NOT renamed", rec.phase)
    recount()
    return rec
end
M._start = start

-- The record goes to phase "down" at `spot` (on the ground).
local function begin_down(rec, p, spot, how)
    local now = clock()
    local loc = ue.location(p)
    spot = spot or loc
    if not spot then return false end
    local yaw = ue.rotation(p).Yaw or 0
    rec.spot = { X = spot.X, Y = spot.Y, Z = spot.Z, yaw = yaw }
    if rec.key == "host" and loc and hdist(loc, spot) > 50 then ue.teleport(p, rec.spot) end
    rec.phase, rec.t_down = "down", now
    local nz = drop_zombies(p, rec.spot)
    send_down(rec)
    host_views()
    log.info("[DOWN] %s is down at %.0f,%.0f,%.0f (%s; %d zombie(s) dropped it; %d s left)", rec.name, rec.spot.X,
        rec.spot.Y, rec.spot.Z, tostring(how or "on the ground"), nz, math.floor(rec_left(rec, now)))
    return true
end

local function end_record(key)
    local rec = H.downs[key]
    H.downs[key] = nil
    for rk, h in pairs(H.holding) do
        if h.target == key or rk == key then H.holding[rk] = nil end
    end
    return rec
end

-- Up again: health 10..25 (from before the hit), the ordinary bleeding off.
local function revive(key, by_key, why)
    local rec = end_record(key)
    if not rec then return false end
    why = why or "up"
    local p = pawn_of_key(key)
    local same = p ~= nil and addr(p) == rec.paddr
    local hp, bled = nil, false
    if same then
        unprotect(p, rec)
        if key ~= "host" then copy_flags(p, false) end
        hp = clamp_hp(rec.h0)
        set_health(p, hp)
        bled = stop_bleed(p)
    end
    send_end(rec, why, by_key)
    if why == "off" then M.stats.off = M.stats.off + 1 else M.stats.revives = M.stats.revives + 1 end
    recount()
    host_views()
    log.info("[DOWN] %s is up (%s%s): health %s%s", rec.name, why, by_key and (", by " .. name_of_key(by_key)) or "",
        hp and string.format("%.0f", hp) or "?", bled and ", bleeding stopped" or "")
    return true
end
M.revive = revive

-- The game's own death: ApplyDamage(999) past this module's hooks. Returns
-- "dead" or "up" (alive afterwards: Deathbringer).
local function kill_pawn(p, why, who)
    local gps = ue.gameplay_statics()
    H.bypass = true
    local ok, err = false, "no GameplayStatics"
    if gps then ok, err = pcall(function() gps:ApplyDamage(p, 999, nil, nil, nil) end) end
    H.bypass = false
    local h = health(p)
    local gone = dead(p) or (h ~= nil and h <= 0)
    if not ok then
        M.stats.kill_failed = M.stats.kill_failed + 1
        log.err("[DOWN] %s: the deadly damage FAILED (%s): %s", tostring(who), tostring(why), tostring(err))
    end
    log.info("[DOWN] %s dies the game's way (%s): %s", tostring(who), tostring(why),
        gone and "dead" or string.format("still alive with %.0f health (Deathbringer?)", h or -1))
    return gone and "dead" or "up"
end
M.kill_pawn = kill_pawn

local function kill(key, why)
    local rec = end_record(key)
    if not rec then return false end
    local p = pawn_of_key(key)
    local outcome = "dead"
    if p and addr(p) == rec.paddr and not dead(p) then
        unprotect(p, rec)
        if key ~= "host" then copy_flags(p, false) end
        outcome = kill_pawn(p, why, rec.name)
        if outcome == "up" then stop_bleed(p) end
    end
    if why == "gave up" then M.stats.gaveup = M.stats.gaveup + 1 end
    if outcome == "dead" then M.stats.deaths = M.stats.deaths + 1 else M.stats.revives = M.stats.revives + 1 end
    send_end(rec, outcome, nil)
    recount()
    host_views()
    return true
end
M.kill = kill

-- Closed without damage: its character is gone, dead or another one, or the
-- player left (its sdc_persist snapshot keeps the time left).
local function close(key, why)
    local rec = end_record(key)
    if not rec then return false end
    local p = pawn_of_key(key)
    if p and addr(p) == rec.paddr then
        unprotect(p, rec)
        if key ~= "host" then copy_flags(p, false) end
    end
    M.stats.closed = M.stats.closed + 1
    send_end(rec, why, nil)
    recount()
    host_views()
    log.info("[DOWN] %s: closed without damage (%s)", rec.name, tostring(why))
    return true
end
M.close = close

-- ---------------------------------------------------------------------------
-- Host: the decision, the frame after the probe hit
-- ---------------------------------------------------------------------------

local function blocked(p)
    if ue.prop(med(p), "CanTakeDamage?") == false then return "CanTakeDamage? off" end
    if dead(p) then return "dead" end
    local ksl = ue.ksl()
    if ksl and ue.try(function() return ksl:GetConsoleVariableBoolValue("Debug.Invincibility") end) == true then
        return "Debug.Invincibility"
    end
    return nil
end

local function decide(a, pr)
    H.pending[a] = nil
    local key = pr.key
    local p = (key ~= "?") and pawn_of_key(key) or nil
    if pr.half and not p then
        for k, r in pairs(S.remote or {}) do
            local q = ue.pawn_of(r.pc)
            if q and addr(q) == a then p, key = q, k end
        end
        local hp = ue.local_pawn()
        if not p and hp and addr(hp) == a then p, key = hp, "host" end
    end
    if not p or addr(p) ~= a then
        log.info("[DOWN] probe on %s: its character is gone before the decision", tostring(key))
        return
    end
    local name = name_of_key(key)
    local hnow = health(p)
    local h1 = pr.h1 or hnow
    local how = pr.h1 ~= nil and "post" or "frame"
    if pr.h1 ~= nil then M.stats.post = M.stats.post + 1 else M.stats.frame = M.stats.frame + 1 end
    if h1 == nil then
        log.warn("[DOWN] %s: no health to read after the probe: left as it is", name)
        return
    end
    local h0, probe = pr.h0, pr.probe
    local dmg = pr.dmg + (pr.extra or 0)
    local lost = h0 - h1
    local div, real
    local died = dead(p)
    -- the probe took more than itself (the game only lessens damage), or the
    -- player died of it (measured right after it, or no measure and dead by
    -- now): the BaseDamage write did not reach the game - the knockdown
    -- cannot work at all, the hit stays the game's own
    local not_lessened = pr.h1 ~= nil and (pr.h1 <= 0 or lost > probe * 1.01 + 1e-6)
    if not_lessened or (died and pr.h1 == nil) then
        log.warn("[DOWN] %s: h0=%.2f damage=%.1f probe=%.2f lost=%.2f dead=%s measured=%s: the probe hit was not lessened",
            name, h0, dmg, probe, lost, tostring(died), how)
        fuse("the probe hit was not lessened (the BaseDamage write had no effect)")
        return
    end
    if died then
        -- right after the probe hit it was lessened as it should be: the
        -- player died of something else in the same frame (Suicide, a trap,
        -- the edge of a blast) - the write works, nothing to do
        M.stats.other_death = M.stats.other_death + 1
        log.info("[DOWN] %s: h0=%.2f probe=%.2f lost=%.2f (measured=post): the probe worked, but the player died of something else in the same frame: nothing done",
            name, h0, probe, lost)
        recount()
        return
    end
    if pr.db0 ~= true and ue.prop(p, "DeathbringerSkillUsed?") == true then
        -- the game's own Deathbringer fired during the probe hit (it runs only
        -- when the health reaches 0, a half-health probe never does): the hit
        -- was deadly after all (another one this frame, or a write the game
        -- ignored) - the game's own result is kept
        M.stats.db_probe = M.stats.db_probe + 1
        log.warn("[DOWN] %s: h0=%.2f damage=%.1f probe=%.2f lost=%.2f: the game's Deathbringer fired during the probe hit: the game's result kept (health %s)",
            name, h0, dmg, probe, lost, tostring(health(p)))
        recount()
        return
    end
    if lost <= math.max(probe * 1e-3, 1e-9) then
        local why = blocked(p)
        if why then
            M.stats.nothing = M.stats.nothing + 1
            log.info("[DOWN] %s: h0=%.2f damage=%.1f probe=%.2f lost=%.4f measured=%s: the game took nothing (%s): nothing done",
                name, h0, dmg, probe, lost, how, why)
            return
        end
        div, real = 1, dmg
    else
        div = math.max(1, probe / lost)
        real = dmg / div
    end
    if pr.half then
        local hn = math.max(0, h0 - real)
        if hn > 0 then set_health(p, hn) end
        log.info("[DOWN] probe half %s: h0=%.2f damage=%.1f probe=%.2f h1(post)=%s h(frame)=%s lost=%.3f divisor=%.3f real=%.2f -> health %.2f%s",
            name, h0, dmg, probe, tostring(pr.h1), tostring(hnow), lost, div, real, hn, hn > 0 and "" or " (deadly: left at the probe's health)")
        return
    end
    if real < h0 then
        local hn = h0 - real
        set_health(p, hn)
        M.stats.stood = M.stats.stood + 1
        log.info("[DOWN] %s: h0=%.2f damage=%.1f probe=%.2f lost=%.3f divisor=%.3f real=%.2f -> stands with %.2f (measured=%s)",
            name, h0, dmg, probe, lost, div, real, hn, how)
        return
    end
    -- deadly: the game's Deathbringer first
    local was = ue.prop(p, "DeathbringerSkillUsed?")
    local out = {}
    local okd, errd = pcall(function() p:Deathbringer(out) end)
    local used = okd and (out["Used?"] == true or (was ~= true and ue.prop(p, "DeathbringerSkillUsed?") == true))
    if not okd then log.warn("[DOWN] %s: the game's Deathbringer could not be called: %s", name, tostring(errd)) end
    if used then
        M.stats.saved = M.stats.saved + 1
        log.info("[DOWN] %s: h0=%.2f damage=%.1f divisor=%.3f real=%.2f: deadly, Deathbringer saved it (health %s, measured=%s)",
            name, h0, dmg, div, real, tostring(health(p)), how)
        recount()
        return
    end
    local why = nil
    if not rule_on() or H.fuse.off then
        why = "the rule is off"
    elseif cmc_is(p, "IsSwimming") then
        why = "in water"
    elseif rescuers(key) == 0 then
        why = "nobody can help"
    end
    log.info("[DOWN] %s: h0=%.2f damage=%.1f probe=%.2f lost=%.3f divisor=%.3f real=%.2f: deadly -> %s (measured=%s)",
        name, h0, dmg, probe, lost, div, real, why and ("dies: " .. why) or "down", how)
    if why then
        M.stats.killed_direct = M.stats.killed_direct + 1
        kill_pawn(p, why, name)
        recount()
        return
    end
    start(key, p, h0, nil, "deadly hit")
end

local function decide_all()
    local list = {}
    for a, pr in pairs(H.pending) do list[#list + 1] = { a, pr } end
    for _, x in ipairs(list) do
        local ok, err = pcall(decide, x[1], x[2])
        if not ok then
            H.pending[x[1]] = nil
            count_error("decision", err)
        end
    end
    H.probe_open = next(H.pending) ~= nil
    recount()
end

-- The grenadier's blasts of the last frame: every flag back first (each on
-- its own: an error later must not leave anybody unable to take damage),
-- then the damage again through ApplyDamage for those its blast saw.
local function blast_flag_back(key)
    local p = pawn_of_key(key)
    if p and not H.downs[key] then ue.set_prop(med(p), "CanTakeDamage?", true) end
end

local function blasts_step()
    local list = H.blasts
    H.blasts = {}
    for _, b in ipairs(list) do
        for _, x in ipairs(b.hits or {}) do
            local ok, err = pcall(blast_flag_back, x.key)
            if not ok then count_error("blast flag", err) end
        end
    end
    for _, b in ipairs(list) do
        for _, x in ipairs(b.hits or {}) do
            local p = pawn_of_key(x.key)
            if p and not H.downs[x.key] then
                if x.traced and x.seen then
                    local gps = ue.gameplay_statics()
                    if gps then pcall(function() gps:ApplyDamage(p, b.dmg, nil, nil, nil) end) end
                    M.stats.radial_hits = M.stats.radial_hits + 1
                end
                log.info("[DOWN] grenadier blast near %s: %s", name_of_key(x.key), not x.traced and "line of sight could not be traced: no damage"
                    or (x.seen and string.format("in sight: %.0f damage applied again", b.dmg) or "behind cover: no damage"))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: the 250 ms tick
-- ---------------------------------------------------------------------------

local function eligible(rk, key, rec, vl)
    if rk == key then return false end
    if rk ~= "host" and not client_ok(S.remote[rk]) then return false end
    if H.downs[rk] then return false end
    local p = pawn_of_key(rk)
    if not p or dead(p) or in_vehicle(p) then return false end
    local d = dist(ue.location(p), vl)
    return d <= ((rec.resc[rk] and C.REVIVE_KEEP_CM) or C.REVIVE_START_CM)
end

local function rec_step(key, rec, now, dt, second)
    if key ~= "host" and not (S.remote or {})[key] then return close(key, "left") end
    local p = pawn_of_key(key)
    if not p or addr(p) ~= rec.paddr or ue.short(p) ~= rec.pname then return close(key, "gone") end
    if dead(p) then return close(key, "dead") end
    if rec.phase == "exit" then
        if not in_vehicle(p) then
            rec.phase, rec.t_phase = "land", now
        elseif now - rec.t_phase > C.VEH_EXIT_S then
            return kill(key, "could not get out of the vehicle")
        end
        return
    end
    if rec.phase == "land" then
        if grounded(p) then return begin_down(rec, p, nil, "on the ground") end
        if now - rec.t_phase > C.LAND_S then
            local l = ue.location(p)
            local f = floor_under(p, l)
            return begin_down(rec, p, f or l, f and "not on the ground after 3 s: the floor below" or "not on the ground after 3 s: where it is")
        end
        return
    end
    local left = rec_left(rec, now)
    if left <= 0 then return kill(key, "bled out") end
    if now - rec.t0 > rec.bleed_s + C.SAFETY_S then return kill(key, "safety margin") end
    if rescuers(key) == 0 then return kill(key, "nobody can help any more") end
    -- the revive
    local vl = ue.location(p)
    local set, first = {}, nil
    for rk, h in pairs(H.holding) do
        if h.target == key and eligible(rk, key, rec, vl) then
            set[rk] = true
            if not first or (h.t or 0) < (H.holding[first].t or 0) then first = rk end
        end
    end
    local changed = false
    for k in pairs(set) do if not rec.resc[k] then changed = true end end
    for k in pairs(rec.resc) do if not set[k] then changed = true end end
    rec.resc = set
    if first then
        rec.prog = (rec.prog or 0) + dt
        if rec.prog >= C.REVIVE_S then return revive(key, first, "up") end
    elseif (rec.prog or 0) > 0 then
        rec.prog = 0
        changed = true
    end
    if key ~= "host" then copy_flags(p, true) end
    if changed then send_down(rec) end
    if second then
        local h = health(p)
        if h ~= 1 then set_health(p, 1) end
        if ue.prop(med(p), "CanTakeDamage?") ~= false then ue.set_prop(med(p), "CanTakeDamage?", false) end
        -- every second: a zombie still after it (one that chased it from
        -- further away, or whose attack task wrote it back) drops it again
        local nz = drop_zombies(p, rec.spot)
        if nz > 0 then
            rec.zn = (rec.zn or 0) + nz
            if now - (rec.zlog or -100) >= C.ZOMBIE_LOG_S then
                rec.zlog = now
                log.info("[DOWN] %s: %d more zombie(s) still after it dropped it (%d since it went down)", rec.name, nz, rec.zn)
            end
        end
        -- a client's copy away from its spot: DOWN again (it moves itself
        -- back); POS_N times within POS_WIN_S: it dies
        if key ~= "host" and rec.spot and vl and not cmc_is(p, "IsFalling") and hdist(vl, rec.spot) > C.POS_CM then
            local keep = {}
            for _, t in ipairs(rec.moved) do if now - t <= C.POS_WIN_S then keep[#keep + 1] = t end end
            keep[#keep + 1] = now
            rec.moved = keep
            M.stats.moved = M.stats.moved + 1
            log.info("[DOWN] %s's character is %.0f cm from its spot (%d time(s) in %d s)", rec.name, hdist(vl, rec.spot),
                #keep, C.POS_WIN_S)
            if #keep >= C.POS_N then return kill(key, "moved away from its spot") end
            send_down(rec)
        elseif now - (rec.sent_at or 0) >= C.DOWN_REPEAT_S then
            send_down(rec)
        end
    end
end

-- Persist's "come back down" records, once the player is ready.
local function restore_step(now)
    for key, w in pairs(H.restore) do
        local r = S.remote and S.remote[key]
        if not r then
            w.gone_at = w.gone_at or now
            if now - w.gone_at > 10 then H.restore[key] = nil end
        else
            w.gone_at = nil
            local p = ue.valid(r.pc) and ue.pawn_of(r.pc) or nil
            local function stand(why)
                H.restore[key] = nil
                if p and not dead(p) then
                    local hp = clamp_hp(w.h0)
                    set_health(p, hp)
                    log.info("[DOWN] %s came back down (saved %d s left) but %s: stands with %.0f health", w.name,
                        math.floor(w.left), why, hp)
                end
            end
            if not p or dead(p) then
                H.restore[key] = nil
                log.info("[DOWN] %s's saved knockdown dropped: no living character", w.name)
            elseif w.paddr and addr(p) ~= w.paddr then
                H.restore[key] = nil
                log.info("[DOWN] %s's saved knockdown dropped: another character", w.name)
            elseif now - w.at < C.RESTORE_WAIT_S then
                -- the saved spot's move first (sdc_persist UNSTUCKTO)
            elseif not rule_on() or H.fuse.off then
                stand("the rule is off")
            elseif not r.downcap then
                if now - w.at > C.RESTORE_OLD_S then stand("its mod has no knockdown (older version)") end
            elseif not r.down_ready or r.access ~= "ok" then
                if now - w.at > C.RESTORE_MAX_S then stand("it never got ready") end
            elseif H.downs[key] then
                H.restore[key] = nil
            elseif rescuers(key) == 0 then
                H.restore[key] = nil
                M.stats.restores = M.stats.restores + 1
                log.info("[DOWN] %s came back down (%d s left) and nobody can help: dies the game's way", w.name, math.floor(w.left))
                kill_pawn(p, "came back down, nobody can help", w.name)
                recount()
            else
                H.restore[key] = nil
                M.stats.restores = M.stats.restores + 1
                start(key, p, w.h0, w.left, "came back down")
            end
        end
    end
end

local function rules_send()
    local sig = (rule_on() and not H.fuse.off and "1" or "0") .. "|" .. tostring(bleed_s())
    for _, r in pairs(S.remote or {}) do
        if r.hello and r.access == "ok" and ue.valid(r.pc) and not r.kicked and r.down_rule_sent ~= sig then
            r.down_rule_sent = sig
            local on, secs = sig:match("^(%d)|(%d+)$")
            net.send_to(r.pc, "RULES", "down", on, secs)
            log.info("[DOWN] rule to %s: knockdown %s (%s s)", tostring(r.name), on == "1" and "ON" or "off", secs)
        end
    end
end

-- The host's pause menu on screen, or none. Only while the mouse cursor is
-- shown (the menu shows it, HUD_Game @562): the HUD's own PauseMenu (HUD_Game
-- creates it on every open, @340-401); a search over every object only when
-- the HUD has none, at most once a second.
local function open_pause_menus(now)
    local pc = ue.local_pc()
    if not pc or ue.prop(pc, "bShowMouseCursor") ~= true then return {} end
    local hud = ue.try(function() return pc:GetHUD() end)
    local w = ue.valid(hud) and ue.prop(hud, "PauseMenu") or nil
    if ue.valid(w) then
        if ue.try(function() return w:IsInViewport() end) == true then return { w } end
        return {}
    end
    if now - (H.pause_scan_at or -100) < 1 then return {} end
    H.pause_scan_at = now
    local out = {}
    for _, x in ipairs(ue.find_all("PauseScreen_C")) do
        if ue.valid(x) and ue.try(function() return x:IsInViewport() end) == true then out[#out + 1] = x end
    end
    return out
end

-- The host's open pause menu while somebody is down (fallback of the
-- hook), and the buttons back once nobody is.
local function pause_step(now)
    if any_down() then
        for _, w in ipairs(open_pause_menus(now)) do hide_pause(w) end
    elseif H.pause_hidden then
        H.pause_hidden = false
        for _, w in ipairs(open_pause_menus(now)) do
            pcall(function() w:RemoveSaveAndSuicideButton() end)
        end
        log.info("[DOWN] nobody is down: the host's pause menu buttons are the game's again")
    end
end

-- Diagnostics: a candidate's health fell by more than DIAG_DROP within a
-- second without an ApplyDamage on it (a trap, a blast, something else).
local function diag_step(now)
    local seen = {}
    for a, key in pairs(H.cand) do
        local p = pawn_of_key(key)
        if p and addr(p) == a then
            local h = health(p)
            local was = H.hp_was[a]
            if h and was and was - h > C.DIAG_DROP and now - (H.hit_at[a] or -100) > 1.2 then
                M.stats.diag = M.stats.diag + 1
                log.info("[DOWN] diag: %s lost %.1f health within a second without ApplyDamage (a trap, a blast or something else: no knockdown there)",
                    name_of_key(key), was - h)
            end
            H.hp_was[a] = h
            seen[a] = true
        end
    end
    for a in pairs(H.hp_was) do if not seen[a] then H.hp_was[a] = nil end end
end

local function host_tick(now, dt, second)
    if (not rule_on() or H.fuse.off) and any_down() then
        local keys = {}
        for k in pairs(H.downs) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            local ok, err = pcall(revive, k, nil, "off")
            if not ok then count_error("rule off", err); H.downs[k] = nil end
        end
    end
    local keys = {}
    for k in pairs(H.downs) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local rec = H.downs[k]
        if rec then
            local ok, err = pcall(rec_step, k, rec, now, dt, second)
            if ok then
                rec.errs = 0
            else
                rec.errs = (rec.errs or 0) + 1
                count_error("record " .. tostring(rec.name), err)
                if rec.errs >= C.REC_ERRORS and H.downs[k] == rec then
                    -- the record itself is broken: closed, its character free
                    pcall(revive, k, nil, "off")
                    H.downs[k] = nil
                end
            end
        end
    end
    if second then
        recount()
        rules_send()
        restore_step(now)
        diag_step(now)
    end
    pause_step(now)
    if not any_down() and next(H.holding) then H.holding = {} end
    host_views()
    if (H.armed or any_down()) and hooks.damage and not hooks.damage.installed then ai.install_now() end
    if any_down() and hooks.pause and not hooks.pause.installed then ai.install_now() end
end

-- ---------------------------------------------------------------------------
-- Client: the rule, DOWNCAP, the views
-- ---------------------------------------------------------------------------

-- sdc_admin's RULES|down|<0/1>|<seconds> (client).
function M.on_rule(on, secs)
    if not S or S.role ~= "client" then return end
    on = on == true
    if CL.rule ~= on then
        log.info("[DOWN] the host's rule: knockdown %s%s", on and "ON" or "off", CL.rule == nil and "" or " (changed)")
    end
    CL.rule = on
    CL.secs = tonumber(secs) or CL.secs
end

local function client_ready()
    local pawn = ue.local_pawn()
    if not pawn or ue.class_name(pawn) ~= "BP_PlayerCharacter_C" then return false end
    local cs = S.client
    if type(cs) == "table" and cs.access == "wait" then return false end
    local ui = package.loaded["sdc_ui"]
    if type(ui) == "table" and type(ui.join_cover_model) == "function" then
        local ok, m = pcall(ui.join_cover_model)
        if ok and type(m) == "table" and m.visible then return false end
    end
    return true
end

local function client_notices()
    if CL.rule == nil or CL.rule == CL.told or not client_ready() then return end
    local key
    if CL.told == nil then
        key = CL.rule and "down_join_on" or nil
    else
        key = CL.rule and "down_turned_on" or "down_turned_off"
    end
    CL.told = CL.rule
    if key then log.say(key, "info", 8) end
end

local function client_tick(now, second)
    local cs = S.client
    if type(cs) == "table" and cs.acked == true then
        if CL.cap_conn ~= cs then
            CL.cap_conn, CL.ready_sent = cs, false
            net.send_to_host("DOWNCAP", "1")
            CL.cap_at = now
            log.info("[DOWN] DOWNCAP sent to the host (this version knows knockdown)")
        end
        if not CL.ready_sent and second and client_ready() then
            CL.ready_sent, CL.cap_at = true, now
            net.send_to_host("DOWNCAP", "1", "ready")
        elseif now - (CL.cap_at or 0) >= C.CAP_AGAIN_S then
            -- No periodic repeat: the host's ROSTER tells this client what the
            -- host knows of it (cs.roster_cap: 0 nothing, 1 DOWNCAP, 2 DOWNCAP
            -- + ready). Less than what was sent = the host's record of this
            -- player is a new one (its world reset drops them) or the message
            -- was lost: say it again.
            local sent = CL.ready_sent and 2 or 1
            if type(cs.roster_cap) == "number" and cs.roster_cap < sent then
                CL.cap_at = now
                if sent == 2 then net.send_to_host("DOWNCAP", "1", "ready") else net.send_to_host("DOWNCAP", "1") end
                log.info("[DOWN] the host's list says it knows %d of %d about this client: DOWNCAP again", cs.roster_cap, sent)
            end
        end
    end
    local my = M.my_id()
    local me = ue.local_pawn()
    for id, v in pairs(CL.views) do
        if id == my then
            -- own: freed only by the host (or its own death / another
            -- character: sdc_down_pose); no DOWN for a while: ask
            if now - v.at > C.COPY_TIMEOUT_S and now - CL.last_q > C.QUERY_EVERY_S then
                CL.last_q = now
                net.send_to_host("DOWNQ", tostring(id))
                log.info("[DOWN] no word about this player's own knockdown for %d s: asked the host", C.COPY_TIMEOUT_S)
            end
            if me and (dead(me) or (v.paddr and addr(me) ~= v.paddr)) then
                CL.views[id] = nil
                M.last_end[id] = { why = "dead", at = now }
                log.info("[DOWN] this player's character died or changed while down: freed here")
            elseif me and not v.paddr then
                v.paddr = addr(me)
            end
        elseif now - v.at > C.COPY_TIMEOUT_S then
            CL.views[id] = nil
            log.info("[DOWN] no DOWN about player %s for %d s: its copy freed here", tostring(id), C.COPY_TIMEOUT_S)
        end
    end
    if second then client_notices() end
end

-- ---------------------------------------------------------------------------
-- The API (sdc_down_pose, sdc_vehicles, sdc_players, sdc_savecheck,
-- sdc_persist, sdc_session)
-- ---------------------------------------------------------------------------

-- The views of downed players this machine knows: [id] = { id, left, at,
-- bleed_s, prog, resc = { [id] = true }, spot, name }.
function M.views()
    if is_host() then return H.views end
    if S and S.role == "client" then return CL.views end
    return {}
end

-- Is this character down (any phase: getting out of a vehicle, landing,
-- down)? Host: its records; client: the views (by PlayerId).
function M.is_down(pawn)
    if not ue.valid(pawn) then return false end
    if is_host() then
        local a = addr(pawn)
        return a ~= nil and H.down_addr[a] ~= nil
    end
    if S and S.role == "client" then
        local id = player_id(pawn)
        return id ~= nil and CL.views[id] ~= nil
    end
    return false
end

-- Anybody down in this world (host: its records; client: its views).
function M.any_down()
    if is_host() then return any_down() end
    return S ~= nil and S.role == "client" and next(CL.views) ~= nil
end

-- Host: the session key's state for F7 ("down" or nil).
function M.state_of(key)
    if not is_host() then return nil end
    local rec = H.downs[key]
    return rec and "down" or nil
end

-- Host: a remote player's record has DOWNCAP (it knows "down" in F7).
function M.downcap(key)
    local r = S and S.remote and S.remote[key]
    return r ~= nil and r.downcap == true
end

-- Host (sdc_session's ROSTER): what is known of this client's cap: 0 nothing,
-- 1 DOWNCAP, 2 DOWNCAP + "ready". The client reads it back and says more
-- when it is less than what it sent.
function M.downcap_level(key)
    local r = S and S.remote and S.remote[key]
    if r == nil or r.downcap ~= true then return 0 end
    return r.down_ready == true and 2 or 1
end

-- Host (sdc_persist read_vitals): seconds left and health before the hit
-- of a downed character (or of one waiting to come back down), or nil.
function M.down_left(pawn)
    if not is_host() or not ue.valid(pawn) then return nil end
    local a = addr(pawn)
    for _, rec in pairs(H.downs) do
        if rec.paddr == a then return math.floor(rec_left(rec)), rec.h0 end
    end
    for _, w in pairs(H.restore) do
        if w.paddr == a then return math.floor(w.left), w.h0 end
    end
    return nil
end

-- Host (sdc_persist restore_character, after its inventory load): this
-- player left (or the world was saved) while down: down again once ready.
function M.restore_later(key, pawn, left, h0, name)
    if not is_host() or not key then return false end
    left = tonumber(left)
    if not left then return false end
    H.restore[key] = { left = math.max(C.RESTORE_MIN_S, left), h0 = tonumber(h0) or C.HP_MIN, name = tostring(name or key),
                       at = clock(), paddr = ue.valid(pawn) and addr(pawn) or nil }
    log.info("[DOWN] %s comes back down (saved: %d s left): once it is ready", tostring(name or key), math.floor(left))
    return true
end

-- sdc_down_pose: this machine's player holds the key over downed player
-- `id` (on) or stopped.
function M.hold(id, on)
    if is_host() then
        local key = key_of_id(id)
        if on and key then
            H.holding.host = { target = key, t = clock() }
        elseif H.holding.host and (not key or H.holding.host.target == key or not on) then
            H.holding.host = nil
        end
    elseif S and S.role == "client" then
        net.send_to_host("REVIVE", tostring(id), on and "1" or "0")
    end
end

-- sdc_down_pose: this machine's downed player held the key GIVEUP_S.
function M.give_up()
    if is_host() then
        if H.downs.host and H.downs.host.phase == "down" then
            log.info("[DOWN] the host gave up")
            kill("host", "gave up")
        end
    elseif S and S.role == "client" then
        net.send_to_host("GIVEUP")
        log.info("[DOWN] gave up: GIVEUP sent to the host")
    end
end

function M.fused() return H.fuse.off end
function M.rule_known()
    if is_host() then return rule_on() end
    return CL.rule
end

-- ---------------------------------------------------------------------------
-- Cleanup, wiring
-- ---------------------------------------------------------------------------

-- Everybody up (the rule off, the fuse, a role change); `quiet`: no log line
-- when nothing was down.
cleanup = function(why)
    if is_host() then
        local keys = {}
        for k in pairs(H.downs) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            local ok = pcall(revive, k, nil, "off")
            if not ok then H.downs[k] = nil end
        end
        for _, b in ipairs(H.blasts) do
            for _, x in ipairs(b.hits or {}) do
                local p = pawn_of_key(x.key)
                if p then ue.set_prop(med(p), "CanTakeDamage?", true) end
            end
        end
        if #keys > 0 then log.info("[DOWN] cleanup (%s): %d player(s) up", tostring(why), #keys) end
    end
    H.pending, H.blasts, H.holding, H.half = {}, {}, {}, {}
    H.probe_open = false
    recount()
    host_views()
end

-- World change (sdc_session.world_reset_hooks): the old world's objects go
-- away with it; nothing is touched, every record dropped.
function M.reset(why)
    H.downs, H.pending, H.watch, H.cand, H.down_addr = {}, {}, {}, {}, {}
    H.holding, H.restore, H.blasts, H.views, H.hit_at, H.hp_was, H.half = {}, {}, {}, {}, {}, {}, {}
    H.probe_open, H.bypass, H.armed, H.pause_hidden = false, false, false, false
    CL.rule, CL.secs, CL.told, CL.cap_conn, CL.ready_sent, CL.views = nil, nil, nil, nil, false, {}
    M.last_end = {}
    if pose and pose.reset then pcall(pose.reset, why) end
    log.debug("[DOWN] reset (%s)", tostring(why))
end

-- main.lua, every 250 ms.
function M.tick()
    if not S then return end
    if S.role ~= last_role then
        if last_role == "host" then pcall(cleanup, "role " .. tostring(S.role)) end
        -- the same world: this machine's own player freed properly first
        if last_role ~= nil and pose and pose.release then pcall(pose.release, "role") end
        if last_role ~= nil then M.reset("role " .. tostring(S.role)) end
        last_role = S.role
    end
    local now = clock()
    local dt = H.last_tick and math.min(1, math.max(0, now - H.last_tick)) or 0.25
    H.last_tick = now
    local second = now - H.last_second >= 1
    if second then H.last_second = now end
    local ok, err = true, nil
    if S.role == "host" then
        local on = rule_on()
        if on ~= H.rule_was then
            if H.rule_was ~= nil or on then
                log.info("[DOWN] knockdown %s (host setting down_enabled; %d s to bleed out)", on and "ON" or "off", bleed_s())
            end
            H.rule_was = on
        end
        ok, err = pcall(host_tick, now, dt, second)
    elseif S.role == "client" then
        ok, err = pcall(client_tick, now, second)
    end
    if not ok then
        M.stats.tick_errors = M.stats.tick_errors + 1
        count_error("tick", err)
    end
    if pose then
        local okp, errp = pcall(pose.tick, now)
        if not okp then count_error("pose tick", errp) end
    end
end

-- main.lua's frame loop: work this frame (a plain read).
function M.frame_wanted()
    return H.probe_open == true or #H.blasts > 0 or (pose ~= nil and pose.want_frame == true)
end

function M.frame_tick()
    if is_host() then
        if H.probe_open then decide_all() end
        if #H.blasts > 0 then
            local ok, err = pcall(blasts_step)
            if not ok then H.blasts = {}; count_error("blast", err) end
        end
    end
    if pose and pose.want_frame then
        local ok, err = pcall(pose.frame_tick)
        if not ok then count_error("pose frame", err) end
    end
end

local function register_handlers()
    -- client -> host
    net.on("DOWNCAP", function(f, pc)
        if not is_host() then return end
        local key = key_of_pc(pc)
        if not key then return end
        local r = S.remote[key]
        local first = r.downcap ~= true
        r.downcap = true
        if f[2] == "ready" then r.down_ready = true end
        if first then
            r.down_rule_sent = nil
            log.info("[DOWN] %s knows knockdown (DOWNCAP)", tostring(r.name))
            for _, rec in pairs(H.downs) do send_down(rec, pc) end
        end
        recount()
    end)
    net.on("REVIVE", function(f, pc)
        if not is_host() then return end
        local key = key_of_pc(pc)
        if not key then return end
        local target = key_of_id(tonumber(f[1]))
        if f[2] == "1" and target and H.downs[target] then
            H.holding[key] = { target = target, t = clock() }
        elseif H.holding[key] and (not target or H.holding[key].target == target) then
            H.holding[key] = nil
        end
    end)
    net.on("GIVEUP", function(_, pc)
        if not is_host() then return end
        local key = key_of_pc(pc)
        local rec = key and H.downs[key]
        if rec and rec.phase == "down" then
            log.info("[DOWN] %s gave up", rec.name)
            kill(key, "gave up")
        end
    end)
    net.on("DOWNQ", function(f, pc)
        if not is_host() then return end
        local key = key_of_pc(pc)
        if not key then return end
        local id = tonumber(f[1])
        local tk = key_of_id(id)
        local rec = tk and H.downs[tk]
        if rec and rec.phase == "down" then
            send_down(rec, pc)
        elseif id then
            net.send_to(pc, "DOWN", tostring(id), "0", "gone", "")
            log.info("[DOWN] %s asked about player %s's knockdown: nobody is down there (gone)", tostring(S.remote[key].name), tostring(id))
        end
    end)
    -- host -> client
    net.on("DOWN", function(f)
        if not S or S.role ~= "client" then return end
        local id = tonumber(f[1])
        if not id then return end
        if f[2] == "1" then
            local v = CL.views[id] or { id = id }
            local fresh = CL.views[id] == nil
            v.left = tonumber(f[3]) or v.left or 0
            v.prog = (tonumber(f[4]) or 0) / 1000
            local resc = {}
            for s in tostring(f[5] or ""):gmatch("[^;]+") do
                local n = tonumber(s)
                if n then resc[n] = true end
            end
            v.resc = resc
            local x, y, z = tonumber(f[6]), tonumber(f[7]), tonumber(f[8])
            if x and y and z then v.spot = { X = x, Y = y, Z = z, yaw = tonumber(f[9]) or 0 } end
            v.at = clock()
            v.bleed_s = CL.secs or C.BLEED_S
            CL.views[id] = v
            if fresh then log.info("[DOWN] player %s is down here (%d s left)", tostring(id), math.floor(v.left)) end
        else
            CL.views[id] = nil
            M.last_end[id] = { why = f[3] or "dead", by = tonumber(f[4]), at = clock() }
            log.info("[DOWN] player %s's knockdown ended here (%s)", tostring(id), tostring(f[3]))
        end
    end)
end

function M.install(state)
    S = state
    register_handlers()
    hooks.damage = ai.hook_external({ path = APPLY_DAMAGE, kind = "pre", name = "down.damage",
                                      fn = guarded("damage", on_damage), gate = damage_gate })
    hooks.measure = ai.hook_external({ path = APPLY_DAMAGE, kind = "post", name = "down.measure",
                                       fn = guarded("measure", on_damage_post), gate = measure_gate })
    hooks.radial = ai.hook_external({ path = APPLY_RADIAL, kind = "pre", name = "down.radial",
                                      fn = guarded("radial", on_radial), gate = radial_gate })
    hooks.pause = ai.hook_external({ path = PAUSE_FN, kind = "bp", name = "down.pause",
                                     fn = guarded("pause", on_pause), gate = pause_gate })
    local okp, pm = pcall(require, "sdc_down_pose")
    if okp and type(pm) == "table" then
        pose = pm
        pcall(pose.install, S, M)
    else
        log.err("[DOWN] sdc_down_pose did not load: %s", tostring(pm))
    end
    log.info("[DOWN] installed (down_enabled=%s, %d s to bleed out)", tostring(rule_on()), bleed_s())
end

function M.register_commands(add)
    add("sdcoop_down", "sdcoop_down <status|half|hp|god|kill|deathbringer|pose|freeze|prompt|zombies|capsule|causes|vehicle|pos|pause|radial|bleed|used|key|anim|down|up> [who] [...] - knockdown checks (sdcoop_down help)",
        function(params, reply)
            local ok, probe = pcall(require, "sdc_down_probe")
            if not ok then reply("sdc_down_probe: " .. tostring(probe)) return end
            probe.run(M, params, reply)
        end)
end

function M.status_line()
    local s = M.stats
    local downs = {}
    for _, rec in pairs(H.downs) do
        downs[#downs + 1] = string.format("%s(%s %ds prog %.1f)", rec.name, rec.phase, math.floor(rec_left(rec)), rec.prog or 0)
    end
    local nc = 0
    for _ in pairs(H.cand) do nc = nc + 1 end
    local nv = 0
    for _ in pairs(CL.views) do nv = nv + 1 end
    return string.format("down: rule=%s fused=%s | host: down=[%s] candidates=%d probes=%d stood=%d nothing=%d saved=%d db in probe=%d other death=%d downs=%d revives=%d deaths=%d gave up=%d closed=%d off=%d direct=%d moved=%d measured post=%d frame=%d radial=%d/%d diag=%d zombies=%d restores=%d errors hook=%d tick=%d | client: rule=%s views=%d | hooks damage=%s radial=%s pause=%s",
        tostring(M.rule_known()), tostring(H.fuse.off and H.fuse.why or false), table.concat(downs, ","), nc, s.probes,
        s.stood, s.nothing, s.saved, s.db_probe, s.other_death, s.downs, s.revives, s.deaths, s.gaveup, s.closed, s.off, s.killed_direct, s.moved,
        s.post, s.frame, s.radial, s.radial_hits, s.diag, s.zombies, s.restores, s.hook_errors, s.tick_errors,
        tostring(CL.rule), nv, tostring(hooks.damage and hooks.damage.installed),
        tostring(hooks.radial and hooks.radial.installed), tostring(hooks.pause and hooks.pause.installed))
end

-- tests / probes
M._H, M._CL = H, CL
M._t = { on_damage = on_damage, on_damage_post = on_damage_post, on_radial = on_radial, on_pause = on_pause,
         decide_all = decide_all, recount = recount, begin_down = begin_down, host_views = host_views,
         cleanup = function(why) return cleanup(why) end, blasts_step = blasts_step, hide_pause = hide_pause,
         damage_gate = damage_gate, radial_gate = radial_gate, pause_gate = pause_gate, count_error = count_error,
         pause_step = pause_step }

return M
