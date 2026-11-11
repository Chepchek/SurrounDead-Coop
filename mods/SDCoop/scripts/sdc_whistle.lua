-- SDCoop: the distraction whistle of other players.
--
-- The game (BP_PlayerCharacter): the whistle key calls MC_Distract on the
-- host / Svr_Distract -> MC_Distract from a client (input @40690). The
-- multicast runs on EVERY machine and there checks the Distraction skill of
-- "player 0" (@133516: GetPlayerController(self,0) -> TechTreeComponent
-- .IsTechnologyUnlocked(Skill_Distraction)); only then it sets
-- DistractNoisePlaying?, plays Whistle_Cue at the mesh (volume 0.25 crouched,
-- 1 standing) and 0.5 s later reports an AI hearing noise (1500 / 4000 uu)
-- @11063. So on another machine the check asks the wrong player (on a client
-- sdc_ctx blanks it, before that it showed "Distraction Skill Not Unlocked"),
-- and nobody else hears the whistle; a client's whistle also never reaches
-- the zombies (AI perception runs on the host only).
--
-- Here the whistler's own machine decides, as in single player: when its
-- own MC_Distract played the whistle (DistractNoisePlaying? set), it tells
-- the others (client -> host WHISTLE|vol, host -> the clients within the
-- whistle's 31 m WHISTLE|id|vol).
-- A receiver whose copy did not play it already plays Whistle_Cue at that
-- character; the host also reports the AI noise for it.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local appearance = require("sdc_appearance")

local M = { stats = { sent = 0, played = 0, noise = 0 } }

local MC_PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:MC_Distract"
local CUE_PATH = "/Game/Audio/Other/Whistle_Cue.Whistle_Cue"
local HEARING = "/Script/AIModule.Default__AISense_Hearing"

local S
local hooked = false
local logged = {}

local function once(k, fmt, ...)
    if logged[k] then return end
    logged[k] = true
    log.info(fmt, ...)
end

local function enabled() return cfg.get("whistle_sync") ~= false end

local function cue()
    local s = ue.find_object(CUE_PATH)
    if ue.valid(s) then return s end
    local ok, loaded = ue.load_asset(CUE_PATH, "whistle")
    if ok and ue.valid(loaded) then return loaded end
    return nil
end

local function crouched(pawn)
    local cmc = ue.prop(pawn, "CharacterMovement")
    return ue.valid(cmc) and ue.try(function() return cmc:IsCrouching() end) == true
end

-- Host: the clients (but `except`) that can hear a whistle of `pawn`:
-- Whistle_Cue has the FootSteps attenuation (100 + 3000 cm = 31 m, its data;
-- the volume multiplier does not change that range), read from the cue when
-- it is in memory, + 5 m. The client -> host WHISTLE always goes: the host
-- reports the AI noise for it.
local WHISTLE_RANGE = 3100
local skipped = 0
local function near_pcs(pawn, except)
    local snd = package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
    local range = snd.range_of_path(CUE_PATH, WHISTLE_RANGE)
    local out, far = snd.pcs_near(S.remote_pcs, ue.location(pawn), range, except)
    if far > 0 then
        skipped = skipped + 1
        if skipped <= 20 then
            log.debug("whistle: %s's whistle not sent to %d client(s) beyond %.0f m", ue.short(pawn), far, range / 100)
        end
    end
    return out
end

-- Play the whistle at a character (another player's copy on this machine).
local function play_at(pawn, vol, noise)
    if not ue.valid(pawn) then return end
    -- the game already played it here (its own check passed)
    if ue.prop(pawn, "DistractNoisePlaying?") == true then return end
    local s, gps = cue(), ue.gameplay_statics()
    local mesh = ue.prop(pawn, "Mesh")
    local loc = ue.valid(mesh) and ue.try(function() return mesh:K2_GetComponentLocation() end) or ue.location(pawn)
    if not s or not gps or not loc then return end
    local p = { X = loc.X, Y = loc.Y, Z = loc.Z }
    local ok, err = pcall(function()
        gps:PlaySoundAtLocation(pawn, s, p, { Pitch = 0, Yaw = 0, Roll = 0 }, vol, 1.0, 0.0, nil, nil, nil, nil)
    end)
    if ok then
        M.stats.played = M.stats.played + 1
        once("played", "whistle: played another player's whistle (%s, vol %.2f)", ue.short(pawn), vol)
    else
        log.err_throttled("whistle.play", "whistle: play failed: %s", tostring(err))
    end
    if noise then
        local hearing = ue.find_object(HEARING)
        local range = vol < 0.5 and 1500 or 4000
        local okn, errn = pcall(function()
            hearing:ReportNoiseEvent(pawn, ue.location(pawn) or p, 1.0, pawn, range, FName("Noise"))
        end)
        if okn then
            M.stats.noise = M.stats.noise + 1
            once("noise", "whistle: AI noise reported for %s (range %d)", ue.short(pawn), range)
        else
            log.err_throttled("whistle.noise", "whistle: ReportNoiseEvent failed: %s", tostring(errn))
        end
    end
end

-- MC_Distract finished on this machine (post-hook): for the own character,
-- tell the others when the whistle played.
local function on_mc(pawn)
    if not S or not enabled() or not ue.valid(pawn) then return end
    local loc_ok, is_local = pcall(function() return pawn:IsLocallyControlled() end)
    if not loc_ok or is_local ~= true then return end
    if ue.prop(pawn, "DistractNoisePlaying?") ~= true then return end   -- skill not unlocked
    local vol = crouched(pawn) and "0.25" or "1"
    if S.role == "client" then
        if net.send_to_host("WHISTLE", vol) then M.stats.sent = M.stats.sent + 1 end
    elseif S.role == "host" then
        local id = appearance.player_id(pawn)
        if not id then return end
        for _, pc in ipairs(near_pcs(pawn, nil)) do net.send_to(pc, "WHISTLE", tostring(id), vol) end
        M.stats.sent = M.stats.sent + 1
    end
    once("sent", "whistle: own whistle announced (%s)", S.role)
end

function M.tick()
    if hooked or not S or not enabled() then return end
    if S.role ~= "host" and S.role ~= "client" then return end
    local ok = pcall(RegisterHook, MC_PATH, function(ctx)
        local okc, err = pcall(function() on_mc(ctx and ctx:get()) end)
        if not okc then log.err_throttled("whistle.mc", "whistle: MC_Distract hook: %s", tostring(err)) end
    end)
    if ok then
        hooked = true
        log.info("whistle: MC_Distract hook ok")
        log.info("sound relay WHISTLE: client -> host always (the AI noise); host -> clients only within the whistle's range + 5 m (Whistle_Cue: FootSteps %.0f m; before: every client), played at that player with the cue's attenuation",
            WHISTLE_RANGE / 100)
    end
end

local function pawn_by_id(id)
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and appearance.player_id(p) == id then return p end
    end
    return nil
end

function M.register_handlers()
    net.on("WHISTLE", function(f, pc)
        if not S or not enabled() then return end
        if S.role == "host" then
            -- client -> host: WHISTLE|vol
            local vol = tonumber(f[1]) or 1
            if vol ~= 0.25 then vol = 1 end
            local pawn = ue.pawn_of(pc)
            if not pawn then return end
            play_at(pawn, vol, true)
            local id = appearance.player_id(pawn)
            if not id then return end
            for _, other in ipairs(near_pcs(pawn, pc)) do
                net.send_to(other, "WHISTLE", tostring(id), tostring(vol))
            end
        elseif S.role == "client" then
            -- host -> client: WHISTLE|player id|vol
            local id, vol = tonumber(f[1]), tonumber(f[2]) or 1
            if not id then return end
            if vol ~= 0.25 then vol = 1 end
            play_at(pawn_by_id(math.floor(id)), vol, false)
        end
    end)
end

function M.init(state) S = state end

return M
