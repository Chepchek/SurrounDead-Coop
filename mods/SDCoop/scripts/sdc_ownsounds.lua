-- SDCoop: sounds the game plays only on the player's own machine, and how far
-- a player's sounds carry on the other machines.
--
-- Some sounds come from code that runs only where the player is (input
-- handlers, local-only events), e.g. the empty-gun click: BP_FirearmPickup
-- .Local_StartShooting @2585/2846/3156 plays S_EmptyFire_Cue with
-- PlaySoundAtLocation next to the "No ammo" notification; nothing of it is
-- replicated, so other players never hear it. Here a sound from the list
-- (config relay_sounds, asset names separated by ';') played by the own
-- character or one of its items is sent to the other players within the
-- sound's range (client -> host OSND, host -> clients OSND with the player
-- id), and they play the same asset at that player's character with the
-- sound's attenuation.
-- Sounds the game already plays everywhere (shots from MC_WeaponEffects,
-- montage notifies) must not be listed, or they would be heard twice.
--
-- How far a sound carries (work\re\json_snd, Audio/Attenuation/*):
--   PlaySoundAtLocation / SpawnSoundAtLocation use the sound's own
--   attenuation (USoundBase.AttenuationSettings; cooked MaxDistance = its shape
--   extent + falloff) and the engine does not play a one-shot beyond that
--   (FAudioDevice::PlaySoundAtLocation -> SoundIsAudible). A sound WITHOUT
--   attenuation (MaxDistance = WORLD_MAX 2097152) is heard at full volume at
--   any distance. In single player the game uses such sounds only for the
--   player's own actions, where the listener is the player: eating
--   (human_eating_v3_Cue), drinking (Drinking_6_Cue), injecting (Syringe_Cue),
--   the flashlight switch (Turning_Flashlight_On_Cue / _Off_3_Cue, through
--   MC_PlaySoundAtLocation), loop-reload inserts (Shotgun_Insert_Cue,
--   AR_Bullet_Insert_3_Cue: Jig_OnMontageNotify of the weapon, through
--   MC_Montage), Sniper_Mag_IN_Cue, the crossbow's and flare gun's shots and
--   reload (bow_crossbow_*_Cue, fire_flare_gun_Cue), the suppressed revolver
--   (Revolver_Single_Shot__Suppressed__3_Cue), the container search loop
--   (Searching_Cue). In co-op the same calls run for ANOTHER player (the
--   game's multicasts, the host's copy of a client, the mod's relays), and
--   that player was heard everywhere.
-- Guard (every machine, config sound_range_guard): a PlaySoundAtLocation /
--   SpawnSoundAtLocation of a sound without attenuation, called without one,
--   for another player's character or item (or one of the sounds above at a
--   world object) gets the attenuation the game gives the same kind of sound
--   (S_Eat / S_Drink: FootSteps 31 m; bandage, mag, cock sounds:
--   BulletImpact 15.5 m; suppressed pistol shots: GunshotsPistolSuppressed
--   157.5 m), default FootSteps. The own player's sounds stay as in single
--   player.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local appearance = require("sdc_appearance")

local M = { stats = { sent = 0, played = 0, skipped_far = 0, recv_far = 0, guarded = 0, guard_missing = 0 } }

local FN = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local FN_SPAWN = "/Script/Engine.GameplayStatics:SpawnSoundAtLocation"
local MAX_PER_S = 10

local S
local hooked = false
local list_raw, list = nil, {}
local paths = {}            -- asset name -> full object path (learned from the own play)
local window, window_n = 0, 0
local logged = {}

local function once(k, fmt, ...)
    if logged[k] then return end
    logged[k] = true
    log.info(fmt, ...)
end

-- the first `n` lines of a kind (debug)
local dbg_n = {}
local function dbg(k, n, fmt, ...)
    dbg_n[k] = (dbg_n[k] or 0) + 1
    if dbg_n[k] <= n then log.debug(fmt, ...) end
end

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function coop() return S ~= nil and (S.role == "host" or S.role == "client") end
local function guard_on() return cfg.get("sound_range_guard") ~= false end

-- ---------------------------------------------------------------------------
-- How far a sound carries
-- ---------------------------------------------------------------------------

local NO_RANGE = 1000000            -- cm: MaxDistance at or above = no attenuation (WORLD_MAX 2097152)
local MARGIN = 500                  -- cm: the players move while a message travels
local ATT_DIR = "/Game/Audio/Attenuation/"
-- the game's attenuation assets: max distance = shape extent + falloff (cm)
local ATT_RANGE = {
    FootSteps = 3100, BulletImpact = 1550, CampFire = 800, Radio = 3100, Zombies = 950, ZombieScream = 12600,
    GunshotsPistol = 21000, GunshotsPistolSuppressed = 15750, GunshotsRifle = 27000,
    GunshotsRifleSuppressed = 19000, GunshotsShotgun = 27500, GunshotsSniper = 32500,
}
-- the game's player / item sounds without attenuation: the attenuation the
-- game gives the same kind of sound. Users (work\re\extract_da: every item
-- data asset and weapon pickup): human_eating_v3 = ConsumeSound of 46 foods
-- (meat, fish, cans, MRE; S_Eat_Cue of the energy bar / rice: FootSteps),
-- Drinking_6 = canned soup (S_Drink_Cue of the water / energy drinks:
-- FootSteps), Syringe = infection cure (bandages, medkits, pills: BulletImpact),
-- Sniper_Mag_IN = Lechie / Barrett M82 / M2010 MagInSound,
-- Revolver_Single_Shot__Suppressed__3 = the Deadeye's suppressed shot (its
-- plain shot is GunshotsSniper; the game's suppressed sniper shot is
-- GunshotsRifleSuppressed), bow_crossbow_* = the crossbow, fire_flare_gun =
-- the flare gun, Shotgun_Insert / AR_Bullet_Insert_3 = BP_FirearmPickup's
-- loop-reload notifies.
local NO_ATT = {
    -- shots (BP_WeaponsPickupComponent.FirearmSound / FirearmSuppressedSound)
    fire_flare_gun_Cue = "GunshotsPistolSuppressed",
    Revolver_Single_Shot__Suppressed__3_Cue = "GunshotsRifleSuppressed",
    S_M1982Fire_Cue = "GunshotsPistol",        -- no weapon or item refers to it (0.8.0)
    bow_crossbow_arrow_shoot_type3_01_Cue = "BulletImpact",
    -- reload and weapon foley (mag / cock sounds: BulletImpact)
    Shotgun_Insert_Cue = "BulletImpact", AR_Bullet_Insert_3_Cue = "BulletImpact", Sniper_Mag_IN_Cue = "BulletImpact",
    bow_crossbow_arrow_draw_slide1_01_Cue = "BulletImpact", bow_crossbow_place_arrow_load2_01_Cue = "BulletImpact",
    -- consuming (S_Eat_Cue / S_Drink_Cue: FootSteps; bandage / medical box: BulletImpact)
    human_eating_v3_Cue = "FootSteps", Drinking_6_Cue = "FootSteps", Syringe_Cue = "BulletImpact",
    -- the flashlight switch (BP_PlayerCharacter @64 / @564 / @1082)
    Turning_Flashlight_On_Cue = "BulletImpact", Turning_Flashlight_Off_3_Cue = "BulletImpact",
    -- the container search loop (BP_LootContainer @230; BreakOpen_Cue: Radio 31 m)
    Searching_Cue = "FootSteps",
}
local DEFAULT_ATT = "FootSteps"
M.NO_ATT, M.ATT_RANGE, M.DEFAULT_ATT, M.MARGIN = NO_ATT, ATT_RANGE, DEFAULT_ATT, MARGIN

local infos = {}            -- [sound address] = { name, range, own, att }
local att_objs = {}         -- [attenuation name] = object (or false: not found)

-- { name, range (cm), own = true when the sound has its own attenuation, att = its name }
local function sound_info(s)
    local a = ue.try(function() return s:GetAddress() end)
    local name = ue.short(s)
    local i = a and infos[a]
    if i and i.name == name then return i end
    local max = tonumber(ue.prop(s, "MaxDistance"))
    local att = ue.prop(s, "AttenuationSettings")
    local att_name = ue.valid(att) and ue.short(att) or nil
    if max and max > 0 and max < NO_RANGE then
        i = { name = name, range = max, own = true, att = att_name }
    elseif att_name and not (max and max >= NO_RANGE) then
        -- MaxDistance not stored (a sound wave): its attenuation asset decides
        i = { name = name, range = ATT_RANGE[att_name] or ATT_RANGE.FootSteps, own = true, att = att_name }
    else
        local fb = NO_ATT[name] or DEFAULT_ATT
        i = { name = name, range = ATT_RANGE[fb], own = false, att = fb }
    end
    if a then infos[a] = i end
    return i
end
M.sound_info = sound_info

-- The game's attenuation asset `name` if it is in memory (the host may load
-- it once; a client never loads on a message / hook path).
local function att_object(name)
    local o = att_objs[name]
    if o and ue.valid(o) then return o end
    local path = ATT_DIR .. name .. "." .. name
    o = ue.find_object(path)
    if not o and S and S.role == "host" and att_objs[name] == nil then
        local ok, l = ue.load_asset(path, "ownsounds")
        if ok and ue.valid(l) then o = l end
    end
    att_objs[name] = o or false
    return o
end

-- How far `sound` carries (cm), the attenuation object to pass when it has
-- none of its own (nil when it has), and a label for the logs.
function M.range_of(sound)
    if not ue.valid(sound) then return nil end
    local i = sound_info(sound)
    if i.own then return i.range, nil, (i.att or "its own attenuation") end
    return i.range, att_object(i.att), i.att .. " (it has no attenuation of its own)"
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
M.dist = dist

-- How far the sound asset at `path` carries (cm): its range when it is in
-- memory (never loaded here), else `fallback` (the range read from its data).
function M.range_of_path(path, fallback)
    local s = (type(path) == "string" and path ~= "") and ue.find_object(path) or nil
    local r = s and M.range_of(s) or nil
    return r or fallback
end

-- Host: the controllers in `pcs` (but `except`) whose character is within
-- `range` (+ margin) of `at`, and the number of the others.
function M.pcs_near(pcs, at, range, except)
    local out, far = {}, 0
    local ex = except and ue.name(except) or nil
    for _, pc in ipairs(pcs or {}) do
        if ue.valid(pc) and (not ex or ue.name(pc) ~= ex) then
            local l = ue.location(ue.pawn_of(pc))
            if at and l and dist(l, at) <= (range or 0) + MARGIN then
                out[#out + 1] = pc
            else
                far = far + 1
            end
        end
    end
    return out, far
end

-- Where this machine hears from: the own character (nil without one).
function M.listener()
    local p = ue.local_pawn()
    return p and ue.location(p) or nil
end

-- true, distance when `at` is within `range` (+ margin) of this machine's
-- listener; a machine without a character hears nothing of it
function M.audible_here(at, range)
    local l = M.listener()
    if not l or not at then return false, nil end
    local d = dist(l, at)
    return d <= (range or 0) + MARGIN, d
end

-- ---------------------------------------------------------------------------
-- Guard: another player's sound never plays without attenuation
-- ---------------------------------------------------------------------------

local function guard(fn, wco_p, sound_p, att_p)
    if not guard_on() or not coop() or att_p == nil then return end
    local s = get(sound_p)
    if not ue.valid(s) then return end
    local i = sound_info(s)
    if i.own then return end                       -- the game's own attenuation applies
    local cur = get(att_p)
    if cur ~= nil then
        if type(cur) ~= "userdata" and type(cur) ~= "table" then
            once("guard-layout|" .. fn, "ownsounds: %s: unexpected parameter layout (attenuation is a %s); guard skipped",
                fn, type(cur))
            return
        end
        if ue.valid(cur) then return end           -- the caller chose one
    end
    local w = get(wco_p)
    local who = ue.valid(w) and ctx.classify(w, S.role) or "none"
    local name
    if who == "remote" or who == "other" then
        name = NO_ATT[i.name] or DEFAULT_ATT
    elseif who == "world" and NO_ATT[i.name] then
        name = NO_ATT[i.name]
    else
        return                                     -- the own player's sound: as in single player
    end
    local obj = att_object(name)
    if not obj then
        M.stats.guard_missing = M.stats.guard_missing + 1
        once("guard-missing|" .. name, "ownsounds: attenuation %s not in memory here; %s of %s plays without one",
            name, i.name, ue.class_name(w))
        return
    end
    if pcall(function() att_p:set(obj) end) then
        M.stats.guarded = M.stats.guarded + 1
        once("guard|" .. i.name, "ownsounds: %s of %s (%s) has no attenuation: played here with the game's %s (%.0f m)",
            i.name, ue.class_name(w), who, name, (ATT_RANGE[name] or 0) / 100)
    end
end

-- ---------------------------------------------------------------------------
-- OSND: sounds only the owner's game plays
-- ---------------------------------------------------------------------------

local function names()
    local raw = cfg.get("relay_sounds") or ""
    if raw ~= list_raw then
        list_raw, list = raw, {}
        for n in tostring(raw):gmatch("[^;,%s]+") do list[n] = true end
    end
    return list
end

-- Another player's character within `range` of `at`? On a client: the copies
-- it has (a player without one is beyond the 150 m net range anyway).
local function anyone_near(at, range)
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and ue.try(function() return p:IsLocallyControlled() end) ~= true then
            local l = ue.location(p)
            if l and dist(l, at) <= range + MARGIN then return true end
        end
    end
    return false
end

local function on_play(wco_p, sound_p, vol_p, pitch_p)
    if not S or (S.role ~= "host" and S.role ~= "client") then return end
    if S.role == "host" and #(S.remote_pcs or {}) == 0 then return end
    local s = sound_p and sound_p:get()
    if not ue.valid(s) then return end
    local sname = ue.try(function() return s:GetFName():ToString() end)
    if not sname or not names()[sname] then return end
    local w = wco_p and wco_p:get()
    if not ue.valid(w) then return end
    local who = ctx.classify(w, S.role)
    if who ~= "own" and who ~= "local" then return end      -- someone else's: received, not ours
    local now = os.clock()
    if now - window > 1 then window, window_n = now, 0 end
    window_n = window_n + 1
    if window_n > MAX_PER_S then return end
    paths[sname] = ue.path(s)
    local range, _, label = M.range_of(s)
    local me = ue.local_pawn()
    local at = me and ue.location(me)
    if not range or not at then return end
    once("range|" .. sname, "ownsounds: own %s carries %.0f m (%s): sent only to players within that", sname,
        range / 100, label)
    local vol = tonumber(vol_p and vol_p:get()) or 1
    local pitch = tonumber(pitch_p and pitch_p:get()) or 1
    local v, p = string.format("%.2f", vol), string.format("%.2f", pitch)
    if S.role == "client" then
        if not anyone_near(at, range) then
            M.stats.skipped_far = M.stats.skipped_far + 1
            dbg("osnd-skip", 20, "ownsounds: own %s not sent: no other player within %.0f m", sname, range / 100)
            return
        end
        if net.send_to_host("OSND", paths[sname], v, p) then M.stats.sent = M.stats.sent + 1 end
    else
        local id = appearance.player_id(me)
        if not id then return end
        local n = 0
        for _, pc in ipairs(S.remote_pcs or {}) do
            local l = ue.location(ue.pawn_of(pc))
            if l and dist(l, at) <= range + MARGIN then
                net.send_to(pc, "OSND", paths[sname], v, p, tostring(id))
                n = n + 1
            else
                M.stats.skipped_far = M.stats.skipped_far + 1
                dbg("osnd-skip", 20, "ownsounds: own %s not sent to %s: beyond %.0f m", sname, ue.short(pc), range / 100)
            end
        end
        if n > 0 then M.stats.sent = M.stats.sent + 1 end
    end
    once("sent|" .. sname, "ownsounds: own %s (from %s) sent to the other players near it", sname, ue.class_name(w))
end

local function load_sound(path)
    if type(path) ~= "string" or not path:match("^/Game/[%w_/%.]+$") then return nil end
    local s = ue.find_object(path)
    if ue.valid(s) then return s end
    -- a client plays only sounds already in memory: a synchronous load per
    -- OSND message could wait for the world's streaming and freeze it
    if S and S.role == "client" then return ue.loaded_asset(path, "ownsounds") end
    local ok, loaded = ue.load_asset(path, "ownsounds")
    if ok and ue.valid(loaded) then return loaded end
    return nil
end

local function play_at(pawn, path, vol, pitch)
    if not ue.valid(pawn) then return end
    local sname = path:match("%.([%w_]+)$")
    if not sname or not names()[sname] then return end       -- only listed sounds are played
    local s, gps = load_sound(path), ue.gameplay_statics()
    local loc = ue.location(pawn)
    if not s or not gps or not loc then return end
    local range, att = M.range_of(s)
    local near, d = M.audible_here(loc, range)
    if not near then
        M.stats.recv_far = M.stats.recv_far + 1
        dbg("osnd-far", 20, "ownsounds: %s of %s not played here: %s m away, it carries %.0f m", sname, ue.short(pawn),
            d and string.format("%.0f", d / 100) or "?", (range or 0) / 100)
        return
    end
    local ok, err = pcall(function()
        gps:PlaySoundAtLocation(pawn, s, { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = 0, Yaw = 0, Roll = 0 },
            vol, pitch, 0.0, att, nil, nil, nil)
    end)
    if ok then
        M.stats.played = M.stats.played + 1
        once("played|" .. sname, "ownsounds: played %s of %s (%.0f m away)", sname, ue.short(pawn), (d or 0) / 100)
    else
        log.err_throttled("ownsounds.play", "ownsounds: play %s failed: %s", sname, tostring(err))
    end
end

local function clamp(x, lo, hi)
    x = tonumber(x) or 1
    if x ~= x then return 1 end
    return math.max(lo, math.min(hi, x))
end

local function pawn_by_id(id)
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and appearance.player_id(p) == id then return p end
    end
    return nil
end

function M.register_handlers()
    net.on("OSND", function(f, pc)
        if not S then return end
        local path, vol, pitch = f[1] or "", clamp(f[2], 0, 4), clamp(f[3], 0.1, 4)
        if S.role == "host" then
            -- client -> host: OSND|path|vol|pitch
            local pawn = ue.pawn_of(pc)
            if not pawn then return end
            play_at(pawn, path, vol, pitch)
            local id = appearance.player_id(pawn)
            local at = ue.location(pawn)
            local s = load_sound(path)
            local range = s and M.range_of(s) or nil
            if not id or not at or not range then return end
            for _, other in ipairs(S.remote_pcs or {}) do
                if ue.valid(other) and ue.name(other) ~= ue.name(pc) then
                    local l = ue.location(ue.pawn_of(other))
                    if l and dist(l, at) <= range + MARGIN then
                        net.send_to(other, "OSND", path, f[2] or "1", f[3] or "1", tostring(id))
                    else
                        M.stats.skipped_far = M.stats.skipped_far + 1
                        dbg("osnd-skip", 20, "ownsounds: %s of %s not forwarded to %s: beyond %.0f m",
                            path:match("%.([%w_]+)$") or path, ue.short(pawn), ue.short(other), range / 100)
                    end
                end
            end
        elseif S.role == "client" then
            -- host -> client: OSND|path|vol|pitch|player id
            local id = tonumber(f[4])
            if not id then return end
            play_at(pawn_by_id(math.floor(id)), path, vol, pitch)
        end
    end)
end

-- The relays that play a sound on another machine and how far each carries
-- (one line each, when the hooks go in).
local function describe()
    local function r(n) return (ATT_RANGE[n] or 0) / 100 end
    local listed = 0
    for _ in pairs(NO_ATT) do listed = listed + 1 end
    log.info("sound relay OSND (sounds only the owner's game plays: %s): played at that player with the sound's own attenuation (S_EmptyFire_Cue: FootSteps %.0f m); sent and forwarded only to players within its range + %.0f m",
        tostring(cfg.get("relay_sounds") or ""), r("FootSteps"), MARGIN / 100)
    log.info("sound relay shots (sdc_sync, MC_WeaponEffects inside the 150 m net range): at the weapon with the cue's attenuation (pistol %.0f m, suppressed %.0f-%.0f m, rifle %.0f m, shotgun %.0f m, sniper %.0f m); a cue without one gets its kind's",
        r("GunshotsPistol"), r("GunshotsPistolSuppressed"), r("GunshotsRifleSuppressed"), r("GunshotsRifle"),
        r("GunshotsShotgun"), r("GunshotsSniper"))
    log.info("sound relay far shots (sdc_sync SND, host): to clients from 120 m up to the cue's own range (before: 350 m for every gun), played there with the cue's attenuation")
    log.info("sound relay SND (sdc_sync: boss growl / roar from sdc_npc, debug mirror): played at the source with the sound's attenuation, skipped beyond its range (ZombieGrowlShort / ZombieDeathShort: FootSteps %.0f m)",
        r("FootSteps"))
    log.info("sound relay WNOISE (sdc_world, a search's break-open sound): client -> host always (the AI noise); host -> clients only within BreakOpen_Cue's range + %.0f m (Radio %.0f m; before: every client), played at the container with its attenuation",
        MARGIN / 100, r("Radio"))
    log.info("sound guard (sound_range_guard=%s): another player's sound without attenuation gets the game's attenuation of its kind (%d listed, default %s %.0f m)",
        tostring(guard_on()), listed, DEFAULT_ATT, r(DEFAULT_ATT))
end

function M.tick()
    if hooked or not S or (S.role ~= "host" and S.role ~= "client") then return end
    -- PlaySoundAtLocation / SpawnSoundAtLocation(WorldContext, Sound, Location,
    -- Rotation, Volume, Pitch, StartTime, AttenuationSettings, ...)
    local ok, err = ue.hook_native(FN, "ownsounds", function(_, wco, sound, _, _, vol, pitch, _, att)
        if not S or (S.role ~= "host" and S.role ~= "client") then return end
        local okg, eg = pcall(guard, "PlaySoundAtLocation", wco, sound, att)
        if not okg then log.err_throttled("ownsounds.guard", "ownsounds: guard: %s", tostring(eg)) end
        local okc, e = pcall(on_play, wco, sound, vol, pitch)
        if not okc then log.err_throttled("ownsounds.hook", "ownsounds: hook: %s", tostring(e)) end
    end)
    local ok2, err2 = ue.hook_native(FN_SPAWN, "ownsounds", function(_, wco, sound, _, _, _, _, _, att)
        if not S or (S.role ~= "host" and S.role ~= "client") then return end
        local okg, eg = pcall(guard, "SpawnSoundAtLocation", wco, sound, att)
        if not okg then log.err_throttled("ownsounds.guard", "ownsounds: guard: %s", tostring(eg)) end
    end)
    hooked = true
    log.info("ownsounds: PlaySoundAtLocation hook %s%s, SpawnSoundAtLocation hook %s%s", ok and "ok" or "FAILED ",
        ok and "" or tostring(err), ok2 and "ok" or "FAILED ", ok2 and "" or tostring(err2))
    describe()
end

-- World change: sound and attenuation objects of the old world may go.
function M.reset()
    infos, att_objs = {}, {}
end

function M.status_line()
    local s = M.stats
    return string.format("ownsounds: OSND sent=%d played=%d skipped as too far: send=%d receive=%d | guard: attenuation given=%d missing=%d",
        s.sent, s.played, s.skipped_far, s.recv_far, s.guarded, s.guard_missing)
end

function M.init(state) S = state end

return M
