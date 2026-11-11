-- SDCoop: a client's stealth (sneaking footsteps) as its own game computes it.
--
-- How the game decides that a zombie notices a player (work\audit\stealth.md):
--   * Zombie AI runs on the host only. BP_ZombieAIController (the Roamer /
--     Infected / Radiated controllers are subclasses) has an AIPerception with
--     Sight (25 m, lost at 50 m, 70 deg each side), Hearing (150 m) and Damage.
--     Its PerceptionUpdate: seeing an actor tagged ZombieCanAttack ->
--     CanSeePlayer? (chase); a heard noise -> IsAlert? + LastHeardLocation
--     (investigate). It never asks for player 0, and sight ignores crouching.
--   * The only stealth input is footstep noise: AnimBP_PlayerCharacter
--     AnimNotify_Footstep (@2505) -> BP_PlayerCharacter."Footstep Sound" ->
--     AISense_Hearing.ReportNoiseEvent(self, ActorLocation, 1, self,
--     MaxRange / SneakingMultiplier, 'Noise') (@272). MaxRange: 2000 sprinting
--     (@3428), 250 crouch-sprinting / 1 crouched (@5182), 850 walking (@6162).
--     SneakingMultiplier = the Sneaking skill (x1.035 per level) of player 0's
--     PassiveSkillsComponent (@41-147).
--   * A client's steps reach the zombies from the HOST's copy of its character:
--     the copy's anim notify runs Footstep Sound on the host with the copy's
--     state. The crouch itself arrives natively (saved-move flag), but
--     Sprinting? and CrouchSprinting? are owner-only variables that some of
--     the owner's own code changes without any RPC (sdc_pawnstate copies them
--     later), and the multiplier is the host's copy of the client's
--     controller. The copy can therefore be louder than the owner's game.
--
-- Fix: the owner's own game decides, as for its own steps in single player.
--   client: a pre-hook on AISense_Hearing.ReportNoiseEvent reads the MaxRange
--           of its own Footstep Sound (own crouch, gait and Sneaking skill) and
--           sends it to the host when it changes: STEALTH|range|kind|mult.
--   host:   the same pre-hook, for a footstep noise of a remote player's
--           character (WorldContext = Instigator = that character, tag 'Noise',
--           loudness 1, at its location, none of the other player noises
--           150 / 500 / 1500 / 4000), lowers MaxRange to the owner's value when
--           the copy computed a louder one. It never raises it: the game's own
--           noise event, its timing and its location stay.
--   trace:  a post-hook on BP_ZombieAIController.PerceptionUpdate logs which
--           sense noticed a player (sight / hearing, distance, crouch, gait),
--           at most one line per zombie, player and sense every 10 s.
-- Config: stealth_sync (cap), stealth_trace (log). Kept state: addresses,
-- numbers and strings only; objects come from hook parameters or this tick.
--
-- Gunshots (combat.md section 4, surroundsync_compare.md C2). The game reports
-- a shot in BP_FirearmPickup.MuzzleEffects, which FireBullet runs on the
-- shooter's machine only:
--   AISense_Hearing.ReportNoiseEvent(weapon, Muzzle socket, 1, GetOwner(),
--   MaxRange, 'Noise') @925 / @2081 / @2705, MaxRange =
--     suppressor (its durability allows it): R + R * WeaponNoise / 100 @417
--     muzzle brake (likewise): the same formula @1573
--     otherwise: R @2654
--   R = BP_WeaponsPickupComponent.DefaultSoundRadius (a class default),
--   WeaponNoise = FindSpecificAttachmentStat(Muzzle, WeaponNoise): the first
--   muzzle attachment's stat in the replicated RepAttachments (1 if none).
--   Then Svr_WeaponEffects(SuppressedMuzzleFlash, the suppressor's mesh) or
--   Svr_WeaponEffects(MuzzleFlash, the weapon's mesh) @1062 / @2137 / @2761.
-- A client has no AI system, so its report reached no zombie.
--   host:   Svr_WeaponEffects (the shot's server RPC, hooked after it ran)
--           of a remote player's weapon -> the same ReportNoiseEvent on the
--           host's copy: muzzle socket, loudness 1, the character as
--           instigator, tag 'Noise'. MaxRange: what the owner's own game
--           computed for that weapon class and branch (SHOTN), else the same
--           formula from the host's copy (the branch is the one the owner's
--           MuzzleEffects took: the flash comes on the suppressor's mesh).
--           The host's own shots stay with the game (their MuzzleEffects
--           runs here).
--   client: the pre-hook sees its own shot's report (context = own firearm,
--           instigator = own character) and sends its MaxRange when it is new
--           for that class and suppressor state: SHOTN|class|0/1|range.
-- Config shot_noise.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local function kind_counts() return { c = 0, r = 0, w = 0, s = 0, ["0"] = 0, ["?"] = 0 } end

local M = {
    stats = {
        own = kind_counts(),    -- client: own footstep noises seen
        sent = 0,               -- client: STEALTH messages sent
        host = kind_counts(),   -- host: footstep noises of remote players' copies
        capped = 0, cap_failed = 0, host_quieter = 0, no_info = 0, received = 0,
        cap_pairs = {},         -- ["<copy kind>><owner kind>"] = lowered steps, e.g. "r>c"
        seen = 0, heard = 0, lost = 0,   -- trace: zombie perceptions of players
        -- gunshots: host reported (owner's value / computed here), failures,
        -- SHOTN received; client: own shot reports seen, SHOTN sent
        shots = 0, shot_owner = 0, shot_computed = 0, shot_failed = 0, shot_reports = 0,
        own_shots = 0, shot_sent = 0,
    },
}

local S = nil
local addr = ctx.addr

local HEARING_FN = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent"
local PERCEPTION_FN = "/Game/AI/Zombies/BP_ZombieAIController.BP_ZombieAIController_C:PerceptionUpdate"
local MSG = "STEALTH"

-- Footstep MaxRange before the Sneaking division (AnimBP_PlayerCharacter @2505-6162)
local KINDS = { { "c", 1 }, { "r", 250 }, { "w", 850 }, { "s", 2000 } }
local KIND_NAME = { c = "crouch", r = "crouch-sprint", w = "walk", s = "sprint", ["0"] = "unlimited", ["?"] = "other" }
-- Other noises a player character reports with itself as context and instigator:
-- LandedSoundEffect 150 (@1366), PlayerStompTrace 500 (@1645), whistle 1500 / 4000
-- (@11221, sdc_whistle). Raw MaxRange values, never divided.
local NOT_STEPS = { 150, 500, 1500, 4000 }
local AT_ACTOR_CM = 50       -- Footstep Sound reports at K2_GetActorLocation of the character
local SILENT_CM = 30         -- no zombie's centre gets this close to a player's: inaudible either way
local RESEND_S = 20          -- client: an unchanged value goes again this often while stepping
local SLOW_S = 1.0
local SUMMARY_S = 60
local TRACE_EVERY_S = 10
local DIAG_LINES = 6
local KIND_LINES = 8

local SHOT_FX_FN = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Svr_WeaponEffects"
local HEARING_CDO = "/Script/AIModule.Default__AISense_Hearing"
local SHOT_MSG = "SHOTN"
local SHOT_LINES = 6
local MAX_SHOT_RANGE = 1000000   -- cm: a SHOTN value above this is garbage
-- BP_JigPickupComponent.RepAttachments members (BP structs, GUID-suffixed)
local F_ATTACHMENTS = "Attachments_6_38F2C7B64C1B85D80C3C35A8B1026969"
local F_ATT_ID = "AttachmentID_21_84163C9E4A907293E46F1888C9CBB5C8"
local F_ATT_STATS = "Stats_18_68B034314BEB7EDAE0C223A03FE6E474"
local F_STAT_NAME = "STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10"
local F_STAT_MAX = "MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"
local TAG_MUZZLE = "Jig.AttachmentType.Muzzle"
local TAG_WEAPON_NOISE = "Jig.AttachmentStat.WeaponNoise"

-- module state
local hooks = { noise = false, trace = false }
local trace_fail_logged = false
local slow_at, summary_at, summary_sig = -1000, -1000, ""
local last_role, last_world = nil, nil
local host_active, client_active, trace_active = false, false, false

-- host
local remote_pawn = {}   -- [pawn address] = its controller's address
local pawn_of_pc = {}    -- [controller address] = pawn address
local name_of_pc = {}    -- [controller address] = player name (logs)
local mult_of = {}       -- [controller address] = SneakingMultiplier of the host's copy of that controller
local host_mult = 1
local host_pawn = nil    -- the host's own pawn address
local owner = {}         -- [controller address] = { range =, kind =, mult = } from the owner's game
local diag_n, kind_lines = 0, 0
local first_kind = {}    -- ["<pc>|<kind>"] = true: first step of that kind from that copy logged

-- client
local own = { pawn = nil, mult = 1, last = nil, sent = nil, sent_t = -1000, dirty = false }

-- trace
local trace_last = {}    -- [key] = os.clock()
local trace_keys = 0

-- gunshots
--   host:   owner[pc address] = { ["<weapon class>|<0/1>"] = range }, lines
--   client: own[key] = { range =, sent = }, dirty
local shot = { hooked = false, fail_logged = false, owner = {}, lines = 0, own = {}, dirty = false, any = false }

local function cap_on() return cfg.get("stealth_sync") ~= false end
local function trace_on() return cfg.get("stealth_trace") ~= false end
local function shot_on() return cfg.get("shot_noise") ~= false end

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function near(a, b, tol) return math.abs(a - b) <= tol end

local function excluded(raw)
    for _, v in ipairs(NOT_STEPS) do
        if near(raw, v, 0.01) then return true end
    end
    return false
end

local function kind_for(base)
    for _, k in ipairs(KINDS) do
        if near(base, k[2], k[2] * 0.003 + 0.02) then return k[1] end
    end
    return nil
end

-- Footstep kind of a MaxRange the game divided by m1 (or m2).
local function classify(raw, m1, m2)
    if raw <= 0 then return "0" end
    if type(m1) == "number" and m1 > 0 then
        local k = kind_for(raw * m1)
        if k then return k end
    end
    if type(m2) == "number" and m2 > 0 then
        local k = kind_for(raw * m2)
        if k then return k end
    end
    return "?"
end

local function sneak_mult(pc)
    if not ue.valid(pc) then return nil end
    local comp = ue.prop(pc, "PassiveSkillsComponent")
    if not ue.valid(comp) then return nil end
    local m = ue.prop(comp, "SneakingMultiplier")
    if type(m) == "number" and m > 0 then return m end
    return nil
end

local function flag(o, name)
    local v = ue.prop(o, name)
    if v == nil then return "?" end
    return (v == true) and "1" or "0"
end

local function vec(v)
    if v == nil then return nil end
    local x, y, z = ue.try(function() return v.X end), ue.try(function() return v.Y end), ue.try(function() return v.Z end)
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
    return nil
end

-- MaxRange of a footstep noise of `inst` (address a), or nil when the call is
-- another noise. Footstep Sound @272: ReportNoiseEvent(self, ActorLocation, 1,
-- self, MaxRange / SneakingMultiplier, 'Noise').
local function step_range(inst, a, wco_p, loc_p, loud_p, range_p, tag_p)
    local wco = get(wco_p)
    if wco == nil or addr(wco) ~= a then return nil end
    local raw = get(range_p)
    if type(raw) ~= "number" or raw ~= raw or excluded(raw) then return nil end
    local loud = get(loud_p)
    if type(loud) ~= "number" or not near(loud, 1, 1e-3) then return nil end
    if ue.str(get(tag_p)) ~= "Noise" then return nil end
    local x, y, z = vec(get(loc_p))
    if x then
        local al = ue.location(inst)
        if al then
            local dx, dy, dz = x - al.X, y - al.Y, z - al.Z
            if dx * dx + dy * dy + dz * dz > AT_ACTOR_CM * AT_ACTOR_CM then return nil end
        end
    end
    return raw
end

-- ---------------------------------------------------------------------------
-- Client: the own footsteps' MaxRange, as the own game computed it
-- ---------------------------------------------------------------------------

-- Client: the own shot's report (MuzzleEffects: context = the own firearm,
-- instigator = its owner = the own character). Its MaxRange is remembered per
-- weapon class and suppressor state; client_send_shots sends what is new.
local function own_shot(wco, loud_p, range_p, tag_p)
    local comp = ue.prop(wco, "BP_WeaponsPickupComponent")
    if not ue.valid(comp) then return end
    if ue.str(get(tag_p)) ~= "Noise" then return end
    local loud = get(loud_p)
    if type(loud) ~= "number" or not near(loud, 1, 1e-3) then return end
    local raw = get(range_p)
    if type(raw) ~= "number" or raw ~= raw or raw < 0 or raw > MAX_SHOT_RANGE then return end
    M.stats.own_shots = M.stats.own_shots + 1
    local key = ue.class_name(wco) .. "|" .. ((ue.prop(comp, "SuppressorAttached?") == true) and "1" or "0")
    local e = shot.own[key]
    if e and math.abs(e.range - raw) <= 0.5 then return end
    shot.own[key] = { range = raw, sent = false }
    shot.dirty = true
end

local function on_noise_client(wco_p, loc_p, loud_p, inst_p, range_p, tag_p)
    if not own.pawn then return end
    local inst = get(inst_p)
    if inst == nil or addr(inst) ~= own.pawn then return end
    local wco = get(wco_p)
    if wco ~= nil and addr(wco) ~= own.pawn then
        -- not a footstep (Footstep Sound's context is the character itself)
        if shot_on() then own_shot(wco, loud_p, range_p, tag_p) end
        return
    end
    if not cap_on() then return end
    local raw = step_range(inst, own.pawn, wco_p, loc_p, loud_p, range_p, tag_p)
    if not raw then return end
    local kind = classify(raw, own.mult)
    M.stats.own[kind] = (M.stats.own[kind] or 0) + 1
    own.last = { range = raw, kind = kind }
    own.dirty = true
end

local function client_send(now)
    local l = own.last
    if not l or not own.dirty then return end
    local s = own.sent
    local changed = (s == nil) or s.kind ~= l.kind or math.abs(s.range - l.range) > math.max(0.05, l.range * 0.005)
    if not changed and now - own.sent_t < RESEND_S then return end
    if net.send_to_host(MSG, string.format("%.3f", l.range), l.kind, string.format("%.4f", own.mult or 1)) then
        M.stats.sent = M.stats.sent + 1
        if changed and M.stats.sent <= KIND_LINES then
            log.info("stealth: own steps now %s (%.1f cm, Sneaking x%.3f), sent to the host",
                KIND_NAME[l.kind] or l.kind, l.range, own.mult or 1)
        end
        own.sent = { range = l.range, kind = l.kind }
        own.sent_t = now
        own.dirty = false
    end
end

-- Client: SHOTN|weapon class|0/1 (suppressor)|MaxRange for every new value.
local function client_send_shots()
    if not shot.dirty then return end
    shot.dirty = false
    for key, e in pairs(shot.own) do
        if not e.sent then
            local cls, sup = key:match("^(.+)|([01])$")
            if cls and net.send_to_host(SHOT_MSG, cls, sup, string.format("%.1f", e.range)) then
                e.sent = true
                M.stats.shot_sent = M.stats.shot_sent + 1
                if M.stats.shot_sent <= SHOT_LINES then
                    log.info("stealth: own shots with %s (%s) carry %.0f cm in this game (MuzzleEffects), sent to the host",
                        cls, sup == "1" and "suppressor" or "no suppressor", e.range)
                end
            elseif cls then
                shot.dirty = true   -- no connection yet: next tick
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: a remote copy's footstep is never louder than its owner's
-- ---------------------------------------------------------------------------

local function diag_line(inst, pca, raw, kind, o, outcome)
    diag_n = diag_n + 1
    log.info("stealth: step of %s on the host: copy %.1f cm (%s; bIsCrouched=%s Sprinting?=%s CrouchSprinting?=%s, Sneaking x%.3f) vs owner %.1f cm (%s, x%.3f): %s",
        name_of_pc[pca] or ue.short(inst), raw, KIND_NAME[kind] or kind, flag(inst, "bIsCrouched"), flag(inst, "Sprinting?"),
        flag(inst, "CrouchSprinting?"), mult_of[pca] or 0, o.range, KIND_NAME[o.kind] or o.kind, o.mult or 0, outcome)
end

local function on_noise_host(wco_p, loc_p, loud_p, inst_p, range_p, tag_p)
    local inst = get(inst_p)
    if inst == nil then return end
    local a = addr(inst)
    local pca = a and remote_pawn[a]
    if not pca then return end
    local raw = step_range(inst, a, wco_p, loc_p, loud_p, range_p, tag_p)
    if not raw then return end
    local kind = classify(raw, mult_of[pca], host_mult)
    M.stats.host[kind] = (M.stats.host[kind] or 0) + 1
    local o = owner[pca]
    local fk = tostring(pca) .. "|" .. kind
    if not first_kind[fk] then
        first_kind[fk] = true
        log.info("stealth: first %s step of %s's copy on the host: %.1f cm (owner's game: %s)",
            KIND_NAME[kind] or kind, name_of_pc[pca] or ue.short(inst), raw,
            o and string.format("%s %.1f cm", KIND_NAME[o.kind] or o.kind, o.range) or "no report yet")
    end
    if not o then
        M.stats.no_info = M.stats.no_info + 1
        return
    end
    if not cap_on() then return end
    local eff = raw > 0 and raw or math.huge   -- MaxRange 0 = no limit (only the 150 m hearing range)
    if eff <= SILENT_CM and o.range <= SILENT_CM then return end   -- both inaudible (crouched steps)
    if o.range < eff - 0.01 then
        local ok = pcall(function() range_p:set(o.range) end)
        local back = ok and get(range_p) or nil
        if type(back) == "number" and near(back, o.range, 0.01) then
            M.stats.capped = M.stats.capped + 1
            local pair = kind .. ">" .. o.kind
            M.stats.cap_pairs[pair] = (M.stats.cap_pairs[pair] or 0) + 1
            if diag_n < DIAG_LINES then diag_line(inst, pca, raw, kind, o, "lowered to the owner's") end
        else
            M.stats.cap_failed = M.stats.cap_failed + 1
            log.err_throttled("stealth.cap", "stealth: could not lower a footstep noise of %s (set ok=%s, reads %s)",
                name_of_pc[pca] or ue.short(inst), tostring(ok), tostring(back))
        end
    elseif o.range > eff + 0.5 then
        M.stats.host_quieter = M.stats.host_quieter + 1
        if diag_n < DIAG_LINES then diag_line(inst, pca, raw, kind, o, "copy quieter, kept") end
    end
end

-- One native hook for both roles: AISense_Hearing.ReportNoiseEvent(
-- WorldContextObject, NoiseLocation, Loudness, Instigator, MaxRange, Tag).
local function on_noise(_, wco_p, loc_p, loud_p, inst_p, range_p, tag_p)
    local ok, err = pcall(function()
        if not S then return end
        if S.role == "host" then
            if host_active then on_noise_host(wco_p, loc_p, loud_p, inst_p, range_p, tag_p) end
        elseif S.role == "client" then
            if client_active then on_noise_client(wco_p, loc_p, loud_p, inst_p, range_p, tag_p) end
        end
    end)
    if not ok then log.err_throttled("stealth.noise", "stealth: ReportNoiseEvent hook: %s", tostring(err)) end
end

-- Host: STEALTH|range|kind|mult from a client (its own footsteps).
local function on_msg(f, pc)
    if not S or S.role ~= "host" then return end
    local range, kind, mult = tonumber(f[1]), tostring(f[2] or "?"), tonumber(f[3])
    if not range or range ~= range or range < 0 or range > 100000 then return end
    if not KIND_NAME[kind] then kind = "?" end
    local pca = addr(pc)
    if not pca then return end
    M.stats.received = M.stats.received + 1
    if range == 0 then
        -- the owner's game itself reports without a limit (no skills component there): no cap
        owner[pca] = nil
        return
    end
    local prev = owner[pca]
    owner[pca] = { range = range, kind = kind, mult = mult or 1 }
    if not prev or prev.kind ~= kind then
        kind_lines = kind_lines + 1
        local line = string.format("stealth: %s's steps now %s (%.1f cm, Sneaking x%.3f) in its own game",
            name_of_pc[pca] or ue.short(pc), KIND_NAME[kind] or kind, range, mult or 1)
        if kind_lines <= KIND_LINES then log.info("%s", line) else log.debug("%s", line) end
    end
end

-- ---------------------------------------------------------------------------
-- Host: a remote player's gunshot reaches the AI
-- ---------------------------------------------------------------------------

local fnames = {}
local function fname_of(s)
    local f = fnames[s]
    if f == nil and FName then
        f = FName(s)
        fnames[s] = f
    end
    return f
end

local function tag_name(t)
    if t == nil then return "" end
    return ue.str(ue.try(function() return t.TagName end))
end

-- FindSpecificAttachmentStat(Muzzle, WeaponNoise) (BP_FirearmPickup@0-1357)
-- from the same replicated data: the first muzzle attachment in RepAttachments,
-- its first WeaponNoise stat's MaxValue; 1 when there is none (the game's
-- "not found" value).
local function muzzle_noise(weapon)
    local rep = ue.prop(ue.prop(weapon, "BP_JigPickupComponent"), "RepAttachments")
    local list = rep ~= nil and ue.try(function() return rep[F_ATTACHMENTS] end) or nil
    if list == nil then return 1 end
    local value, done = 1, false
    pcall(function()
        list:ForEach(function(_, ep)
            if done then return end
            local a = ep:get()
            local da = a[F_ATT_ID]
            if not ue.valid(da) or tag_name(ue.prop(da, "Local_AttachmentType")) ~= TAG_MUZZLE then return end
            done = true
            local stats = a[F_ATT_STATS]
            local found = false
            stats:ForEach(function(_, sp)
                if found then return end
                local s = sp:get()
                if tag_name(s[F_STAT_NAME]) == TAG_WEAPON_NOISE then
                    local v = tonumber(s[F_STAT_MAX])
                    if v and v == v then value, found = v, true end
                end
            end)
        end)
    end)
    return value
end

-- Which MuzzleEffects branch the owner's game took: the suppressed flash is
-- attached to the suppressor's StaticMesh (@1062), the others to the weapon's
-- own mesh (@2137 / @2761).
local function suppressed_shot(weapon, comp, emitter, attach)
    local mesh = ue.prop(weapon, "SkeletalMeshComponent")
    if ue.valid(attach) and ue.valid(mesh) then return addr(attach) ~= addr(mesh) end
    local sf, mf = ue.prop(comp, "SuppressedMuzzleFlash"), ue.prop(comp, "MuzzleFlash")
    return ue.valid(emitter) and ue.valid(sf) and addr(emitter) == addr(sf)
        and not (ue.valid(mf) and addr(mf) == addr(sf))
end

-- MaxRange of the shot: the owner's own value for this class and branch,
-- else MuzzleEffects' formula on the host's copy. Returns range, source.
local function shot_range(pca, weapon, comp, sup)
    local cls = ue.class_name(weapon)
    local t = shot.owner[pca]
    local v = t and t[cls .. "|" .. (sup and "1" or "0")]
    if v then return v, "the owner's game" end
    local r = tonumber(ue.prop(comp, "DefaultSoundRadius"))
    if not r or r ~= r or r < 0 then return nil, "no DefaultSoundRadius" end
    if sup or ue.prop(comp, "MuzzleBrakeAttached?") == true then
        local wn = muzzle_noise(weapon)
        return r + r * wn / 100, string.format("computed here: DefaultSoundRadius %.0f, WeaponNoise %.1f", r, wn)
    end
    return r, string.format("computed here: DefaultSoundRadius %.0f", r)
end

local hearing_cdo = nil
local function hearing()
    if ue.valid(hearing_cdo) then return hearing_cdo end
    hearing_cdo = ue.find_object(HEARING_CDO)
    return hearing_cdo
end

-- BP_FirearmPickup.Svr_WeaponEffects(EmitterTemplate, AttachToComponent,
-- AttachPointName), after it ran on the host: one per shot of the owner's
-- MuzzleEffects (an unreliable RPC, like the flash it carries).
local function on_shot_fx(c, emitter_p, attach_p)
    if not S or S.role ~= "host" or not shot.any or not shot_on() then return end
    local weapon = get(c)
    if not ue.valid(weapon) then return end
    local pawn = ue.try(function() return weapon:GetOwner() end)
    if not ue.valid(pawn) then return end
    local pa = addr(pawn)
    local pca = pa and remote_pawn[pa]
    if not pca then
        -- the host's own shot (its MuzzleEffects reported it), or a player
        -- whose new character the slow tick has not seen yet
        local pc = ue.prop(pawn, "Controller")
        if not ue.valid(pc) or not ue.valid(ue.prop(pc, "NetConnection")) then return end
        pca = addr(pc)
    end
    local comp = ue.prop(weapon, "BP_WeaponsPickupComponent")
    if not ue.valid(comp) then return end
    local sup = suppressed_shot(weapon, comp, get(emitter_p), get(attach_p))
    local range, src = shot_range(pca, weapon, comp, sup)
    local hs = hearing()
    if not range or not hs then
        M.stats.shot_failed = M.stats.shot_failed + 1
        log.err_throttled("stealth.shot", "stealth: shot of %s not reported to the AI (%s)", ue.short(weapon),
            tostring(range and "no AISense_Hearing" or src))
        return
    end
    local mesh = ue.prop(weapon, "SkeletalMeshComponent")
    local loc = ue.valid(mesh) and ue.try(function() return mesh:GetSocketLocation(fname_of("Muzzle")) end) or nil
    if not (loc and type(ue.try(function() return loc.X end)) == "number") then loc = ue.location(weapon) end
    if not loc then return end
    local ok, err = pcall(function() hs:ReportNoiseEvent(weapon, loc, 1.0, pawn, range, fname_of("Noise")) end)
    if not ok then
        M.stats.shot_failed = M.stats.shot_failed + 1
        log.err_throttled("stealth.shotnoise", "stealth: ReportNoiseEvent for a shot failed: %s", tostring(err))
        return
    end
    M.stats.shots = M.stats.shots + 1
    if src == "the owner's game" then M.stats.shot_owner = M.stats.shot_owner + 1
    else M.stats.shot_computed = M.stats.shot_computed + 1 end
    local key = tostring(pca) .. "|" .. ue.class_name(weapon) .. "|" .. tostring(sup) .. "|" .. src
    if not first_kind[key] then
        first_kind[key] = true
        shot.lines = shot.lines + 1
        local line = string.format("stealth: shot of %s (%s, %s) reported to the AI here: %.0f cm at the muzzle (%s)",
            name_of_pc[pca] or ue.short(pawn), ue.class_name(weapon), sup and "suppressed" or "unsuppressed", range, src)
        if shot.lines <= SHOT_LINES * 2 then log.info("%s", line) else log.debug("%s", line) end
    end
end

-- Host: SHOTN|weapon class|0/1|MaxRange from a client (its own MuzzleEffects).
local function on_shot_msg(f, pc)
    if not S or S.role ~= "host" then return end
    local cls, sup, range = tostring(f[1] or ""), f[2], tonumber(f[3])
    if not cls:match("^[%w_]+_C$") or (sup ~= "0" and sup ~= "1") then return end
    if not range or range ~= range or range < 0 or range > MAX_SHOT_RANGE then return end
    local pca = addr(pc)
    if not pca then return end
    local t = shot.owner[pca]
    if not t then
        t = {}
        shot.owner[pca] = t
    end
    t[cls .. "|" .. sup] = range
    M.stats.shot_reports = M.stats.shot_reports + 1
    if M.stats.shot_reports <= SHOT_LINES then
        log.info("stealth: %s's shots with %s (%s) carry %.0f cm in its own game", name_of_pc[pca] or ue.short(pc), cls,
            sup == "1" and "suppressor" or "no suppressor", range)
    end
end

-- ---------------------------------------------------------------------------
-- Trace (host): which sense of which zombie noticed a player
-- ---------------------------------------------------------------------------

local function dist_m(a, b)
    local ax, ay, az = vec(a)
    local bx, by, bz = vec(b)
    if not ax or not bx then return -1 end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz) / 100
end

-- BP_ZombieAIController.PerceptionUpdate(Actor, Stimulus), post.
local function on_perception(c, actor_p, stim_p)
    if not trace_active then return end
    local actor = get(actor_p)
    if actor == nil then return end
    local a = addr(actor)
    if not a then return end
    local pca = remote_pawn[a]
    local who
    if pca then
        who = "client " .. (name_of_pc[pca] or "?")
    elseif a == host_pawn then
        who = "host"
    else
        return
    end
    local st = get(stim_p)
    if st == nil then return end
    local tag = ue.str(ue.try(function() return st.Tag end))
    local sensed = ue.try(function() return st.bSuccessfullySensed end) == true
    local hearing = (tag == "Noise" or tag == "LoudNoise")
    -- untagged stimuli: sight (strength 1) or damage (strength = the damage;
    -- PerceptionUpdate itself ignores damage)
    local strength = ue.try(function() return st.Strength end)
    local sense = "sight"
    if hearing then
        sense = "hearing '" .. tag .. "'"
    elseif type(strength) == "number" and not near(strength, 1, 1e-3) then
        sense = string.format("damage? (strength %.1f)", strength)
    end
    if sensed and hearing then M.stats.heard = M.stats.heard + 1
    elseif sensed and sense == "sight" then M.stats.seen = M.stats.seen + 1
    elseif not sensed then M.stats.lost = M.stats.lost + 1 end
    local ctrl = c and get(c)
    local z = ctrl and ue.prop(ctrl, "Pawn")
    local zname = ue.valid(z) and ue.short(z) or ue.short(ctrl)
    local key = zname .. "|" .. tostring(a) .. "|" .. sense:sub(1, 5) .. "|" .. tostring(sensed)
    local now = os.clock()
    local last = trace_last[key]
    if last and now - last < TRACE_EVERY_S then return end
    if not last then
        trace_keys = trace_keys + 1
        if trace_keys > 400 then trace_last, trace_keys = {}, 1 end
    end
    trace_last[key] = now
    local d = dist_m(ue.try(function() return st.StimulusLocation end), ue.try(function() return st.ReceiverLocation end))
    local state = string.format("bIsCrouched=%s Sprinting?=%s CrouchSprinting?=%s",
        flag(actor, "bIsCrouched"), flag(actor, "Sprinting?"), flag(actor, "CrouchSprinting?"))
    if sensed then
        log.info("stealth: %s noticed %s by %s at %.1f m (%s)", zname, who, sense, d, state)
    else
        log.debug("stealth: %s lost %s (%s, %.1f m)", zname, who, sense, d)
    end
end

-- ---------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------

local function try_hooks()
    local want_noise = (S.role == "host" and host_active) or (S.role == "client" and client_active)
    if want_noise and not hooks.noise then
        local ok, err = ue.hook_native(HEARING_FN, "stealth.noise", on_noise)
        if ok then
            hooks.noise = true
            log.info("stealth: ReportNoiseEvent hook ok (%s)", S.role)
        else
            log.err_throttled("stealth.hook", "stealth: ReportNoiseEvent hook failed: %s", tostring(err))
        end
    end
    if S.role == "host" and shot.any and shot_on() and not shot.hooked then
        -- the firearm class loads with the first firearm: retried every second until then
        local ok, err = pcall(RegisterHook, SHOT_FX_FN, function(c, emitter_p, attach_p)
            local okc, e = pcall(on_shot_fx, c, emitter_p, attach_p)
            if not okc then log.err_throttled("stealth.shotfx", "stealth: Svr_WeaponEffects hook: %s", tostring(e)) end
        end)
        if ok then
            shot.hooked = true
            log.info("stealth: Svr_WeaponEffects hook ok (clients' gunshots reach the AI)")
        elseif not shot.fail_logged then
            shot.fail_logged = true
            log.debug("stealth: Svr_WeaponEffects hook not ready (%s)", tostring(err))
        end
    end
    if trace_active and not hooks.trace then
        -- the class loads with the first zombie: retried every second until then
        local ok, err = pcall(RegisterHook, PERCEPTION_FN, function(c, actor_p, stim_p)
            local okc, e = pcall(on_perception, c, actor_p, stim_p)
            if not okc then log.err_throttled("stealth.trace", "stealth: PerceptionUpdate hook: %s", tostring(e)) end
        end)
        if ok then
            hooks.trace = true
            log.info("stealth: zombie PerceptionUpdate hook ok")
        elseif not trace_fail_logged then
            trace_fail_logged = true
            log.debug("stealth: PerceptionUpdate hook not ready (%s)", tostring(err))
        end
    end
end

local function player_name(pc)
    local ps = ue.prop(pc, "PlayerState")
    local n = ue.valid(ps) and ue.try(function() return ue.str(ps:GetPlayerName()) end) or nil
    if n and n ~= "" then return n end
    return ue.short(pc)
end

local function host_slow()
    local pcs = S.remote_pcs or {}
    local rp, pp, live, mults = {}, {}, {}, {}
    for _, pc in ipairs(pcs) do
        local pca = ue.valid(pc) and addr(pc) or nil
        if pca then
            live[pca] = true
            local pawn = ue.pawn_of(pc)
            local pa = pawn and addr(pawn) or nil
            if pa then
                rp[pa] = pca
                pp[pca] = pa
            end
            -- a new character (respawn): its owner reports again on its first step
            if owner[pca] and pawn_of_pc[pca] and pa ~= pawn_of_pc[pca] then owner[pca] = nil end
            mults[pca] = sneak_mult(pc)
            if not name_of_pc[pca] then name_of_pc[pca] = player_name(pc) end
        end
    end
    for pca in pairs(owner) do
        if not live[pca] then owner[pca] = nil end
    end
    for pca in pairs(name_of_pc) do
        if not live[pca] then name_of_pc[pca] = nil end
    end
    for pca in pairs(shot.owner) do
        if not live[pca] then shot.owner[pca] = nil end
    end
    remote_pawn, pawn_of_pc, mult_of = rp, pp, mults
    host_mult = sneak_mult(ue.local_pc()) or 1
    local me = ue.local_pawn()
    host_pawn = me and addr(me) or nil
    local any = next(live) ~= nil
    host_active = any and (cap_on() or trace_on())
    trace_active = any and trace_on()
    shot.any = any
    client_active = false
end

local function client_slow()
    local me = ue.local_pawn()
    local pa = me and addr(me) or nil
    if pa ~= own.pawn then
        -- a new own character: the host forgets the old one's value, so send again
        own.pawn, own.last, own.sent, own.dirty = pa, nil, nil, false
    end
    own.mult = sneak_mult(ue.local_pc()) or 1
    -- footsteps (stealth_sync) and own shots (shot_noise) share the hook
    client_active = cap_on() or shot_on()
    host_active, trace_active = false, false
    shot.any = false
end

local function kinds_str(t)
    return string.format("c=%d r=%d w=%d s=%d 0=%d ?=%d", t.c or 0, t.r or 0, t.w or 0, t.s or 0, t["0"] or 0, t["?"] or 0)
end

function M.status_line()
    local st = M.stats
    local owners = 0
    for _ in pairs(owner) do owners = owners + 1 end
    local pairs_t = {}
    for k, n in pairs(st.cap_pairs) do pairs_t[#pairs_t + 1] = k .. "=" .. n end
    table.sort(pairs_t)
    return string.format("stealth: sync=%s trace=%s hooks noise=%s trace=%s | host: copies' steps %s capped=%d [%s] failed=%d copy-quieter=%d no-report=%d reports=%d owners=%d | zombies noticed players: sight=%d hearing=%d lost=%d | client: own steps %s sent=%d | shots (shot_noise=%s hook=%s): host reported=%d (owner's value %d, computed %d) failed=%d SHOTN in=%d | client own=%d SHOTN out=%d",
        tostring(cap_on()), tostring(trace_on()), tostring(hooks.noise), tostring(hooks.trace),
        kinds_str(st.host), st.capped, table.concat(pairs_t, " "), st.cap_failed, st.host_quieter, st.no_info,
        st.received, owners, st.seen, st.heard, st.lost, kinds_str(st.own), st.sent,
        tostring(shot_on()), tostring(shot.hooked), st.shots, st.shot_owner, st.shot_computed, st.shot_failed,
        st.shot_reports, st.own_shots, st.shot_sent)
end

-- Role change / level change: every address and value of the old session goes.
function M.reset(why)
    local had = next(owner) ~= nil or next(remote_pawn) ~= nil or own.pawn ~= nil
    remote_pawn, pawn_of_pc, name_of_pc, mult_of, owner = {}, {}, {}, {}, {}
    host_mult, host_pawn = 1, nil
    own = { pawn = nil, mult = 1, last = nil, sent = nil, sent_t = -1000, dirty = false }
    trace_last, trace_keys, first_kind = {}, 0, {}
    host_active, client_active, trace_active = false, false, false
    shot.owner, shot.own, shot.dirty, shot.any = {}, {}, false, false
    if had then log.info("stealth: reset (%s)", tostring(why)) end
end

-- Every 100 ms (main.lua): the client's send; the rest once a second.
function M.tick()
    if not S then return end
    local now = os.clock()
    if S.role == "client" and client_active then
        if cap_on() then client_send(now) end
        client_send_shots()
    end
    if now - slow_at < SLOW_S then return end
    slow_at = now
    local pc = ue.local_pc()
    local world = pc and addr(pc) or nil
    if S.role ~= last_role or world ~= last_world then
        if last_role ~= nil then M.reset(S.role ~= last_role and "role" or "world") end
        last_role, last_world = S.role, world
    end
    if S.role == "host" then
        host_slow()
    elseif S.role == "client" then
        client_slow()
    else
        host_active, client_active, trace_active = false, false, false
        return
    end
    try_hooks()
    if host_active and now - summary_at >= SUMMARY_S then
        summary_at = now
        local sig = kinds_str(M.stats.host) .. M.stats.capped .. "|" .. M.stats.seen .. "|" .. M.stats.heard
        if sig ~= summary_sig then
            summary_sig = sig
            log.info("%s", M.status_line())
        end
    end
end

function M.install(state)
    S = state
    net.on(MSG, function(f, pc) on_msg(f, pc) end)
    -- client -> host: SHOTN|weapon class|0/1|MaxRange (own shots, when new)
    net.on(SHOT_MSG, function(f, pc)
        local ok, err = pcall(on_shot_msg, f, pc)
        if not ok then log.err_throttled("stealth.shotn", "stealth: SHOTN: %s", tostring(err)) end
    end)
    log.info("stealth: installed (sync=%s trace=%s shot_noise=%s)", tostring(cap_on()), tostring(trace_on()), tostring(shot_on()))
end

return M
