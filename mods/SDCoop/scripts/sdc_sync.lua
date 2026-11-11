-- SDCoop: world-state fixes on top of stock engine replication.
--
-- The game is built with listen-server RPCs (Svr_*/MC_*/Client_*), so player
-- movement, weapons and inventory replicate by themselves. What is left:
--   * time of day / weather  (Ultra Dynamic Sky + Weather actors)
--   * AI: on a client, level AI managers run with local authority and spawn
--     their own, unsynchronised zombies ("ghosts"); on the host, AI must be
--     replicated so the client sees the real ones
--   * pause: single-player pause would freeze every connected player
--   * stale local copies of player characters on the client
-- Every fix is data-driven by the actor's net role, so it does nothing when
-- the engine already replicates that actor.

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local cfg = require("sdc_config")
local appearance = require("sdc_appearance")

local M = {
    stats = { ai_replicated = 0, ai_ghosts_removed = 0, managers_disabled = 0, pawn_ghosts_hidden = 0,
              tod_fixes = 0, weather_fixes = 0 },
    env_report_logged = false,
}

-- Object identity (address) for fast comparisons / table keys.
local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

local TOD_PROP = "Time of Day"         -- Ultra_Dynamic_Sky_C, 0..2400
local TOD_TOLERANCE = 15               -- 15/100 h ~ 9 game minutes
local WEATHER_TRANSITION_S = 8.0

local function sky() return ue.find_first("Ultra_Dynamic_Sky_C") end
local function weather() return ue.find_first("Ultra_Dynamic_Weather_C") end

-- ---------------------------------------------------------------------------
-- Time of day and weather
-- ---------------------------------------------------------------------------

-- Current weather state. The game runs Ultra Dynamic Weather in "random
-- weather variation" mode (SD_GameInstance -> Change to Random Weather
-- Variation, a server RPC): the random weather is worked out on the host and
-- its result (the actor's Global Weather State object) never reaches clients;
-- the replicated preset stays Clear_Skies while it rains on the host. The
-- host sends the state values; a client puts them into the actor's own
-- per-channel manual overrides (replicated floats + "<channel> - Manual
-- Override", which the server never changes, so replication leaves them).
local WEATHER_CHANNELS = {
    { "cc", "Cloud Coverage" }, { "r", "Rain" }, { "s", "Snow" }, { "t", "Thunder/Lightning" },
    { "w", "Wind Intensity" }, { "f", "Fog" }, { "d", "Dust" }, { "mw", "Material Wetness" },
    { "ms", "Material Snow Coverage" }, { "md", "Material Dust Coverage" },
}

local function weather_state_string(w)
    if not ue.valid(w) then return "" end
    local gws = ue.prop(w, "Global Weather State")
    local src = ue.valid(gws) and gws or w
    local parts = {}
    for _, ch in ipairs(WEATHER_CHANNELS) do
        local v = ue.prop(src, ch[2])
        if type(v) == "number" then parts[#parts + 1] = string.format("%s=%.3f", ch[1], v) end
    end
    return table.concat(parts, ";")
end

-- Debug: what the sky actually shows (host and client print the same line,
-- every 30 s): sky actors, startup / animation flags, the time, the cached
-- sun vector and the sun light's pitch.
local sky_probe_at = -1000
function M.sky_probe(role)
    if not log.debug_enabled or os.clock() - sky_probe_at < 30 then return end
    sky_probe_at = os.clock()
    local all = ue.find_all("Ultra_Dynamic_Sky_C")
    local n = 0
    for _, o in ipairs(all) do if ue.valid(o) and not ue.name(o):find("Default__", 1, true) then n = n + 1 end end
    local s = sky()
    if not s then log.info("env-probe[%s]: no sky actor (%d found)", tostring(role), n) return end
    local function b(name) return tostring(ue.prop(s, name)) end
    local v = ue.prop(s, "Cached Sun Vector")
    local vz = v and ue.try(function() return v.Z end)
    local sun = ue.prop(s, "Sun")
    local rot = ue.valid(sun) and ue.try(function() return sun:K2_GetComponentRotation() end)
    local pitch = rot and ue.try(function() return rot.Pitch end)
    local inten = ue.valid(sun) and ue.prop(sun, "Intensity")
    log.info("env-probe[%s]: skies=%d %s role=%d tod=%s repl_tod=%s animate=%s init_repl=%s repl_to_clients=%s no_runtime=%s sunZ=%s sun_pitch=%s sun_int=%s",
        tostring(role), n, ue.short(s), ue.role(s), b("Time of Day"), b("Replicated Time of Day"),
        b("Animate Time of Day"), b("Initial Replication"), b("Replicate Time of Day to Clients"),
        b("Disable All Runtime Updating"), tostring(vz), tostring(pitch), tostring(inten))
end

-- Host: snapshot sent to clients.
local env_state_log_at = -1000
function M.env_snapshot()
    local s, w = sky(), weather()
    local tod = s and ue.prop(s, TOD_PROP) or nil
    local wobj = w and ue.prop(w, "Weather") or nil
    local wpath = ue.valid(wobj) and ue.path(wobj) or ""
    local state = weather_state_string(w)
    pcall(M.sky_probe, "host")
    if not M.env_report_logged then
        M.env_report_logged = true
        log.info("env: sky=%s role=%d tod=%s | weather=%s role=%d preset=%s",
            ue.short(s), s and ue.role(s) or -1, tostring(tod),
            ue.short(w), w and ue.role(w) or -1, wpath)
    end
    if os.clock() - env_state_log_at > 60 then
        env_state_log_at = os.clock()
        log.info("env: weather state %s", state)
    end
    if type(tod) ~= "number" then return nil end
    return { tod = tod, weather = wpath, state = state }
end

-- Client: the host's weather state into the manual overrides.
local weather_apply_log_at = -1000
local override_logged = {}
local function apply_weather_state(w, state)
    local t = {}
    for k, v in (state or ""):gmatch("(%a+)=([%-%d%.]+)") do t[k] = tonumber(v) end
    if not next(t) then return end
    local changed, overridden = 0, 0
    for _, ch in ipairs(WEATHER_CHANNELS) do
        local v = t[ch[1]]
        if v then
            local cur = ue.prop(w, ch[2])
            if type(cur) ~= "number" or math.abs(cur - v) > 0.001 then
                if ue.set_prop(w, ch[2], v) then changed = changed + 1 end
            end
            local ov = ch[2] .. " - Manual Override"
            local before = ue.prop(w, ov)
            if before ~= true then
                local okset = ue.set_prop(w, ov, true)
                local okrep = okset and ue.call(w, "OnRep_" .. ov)
                if okset then overridden = overridden + 1 end
                if not override_logged[ov] then
                    override_logged[ov] = true
                    log.info("env: %s was %s, set ok=%s, now %s, OnRep ok=%s", ov, tostring(before), tostring(okset),
                        tostring(ue.prop(w, ov)), tostring(okrep))
                end
            end
        end
    end
    if overridden > 0 or os.clock() - weather_apply_log_at > 60 then
        weather_apply_log_at = os.clock()
        log.info("env: host weather state applied (%d values changed, %d overrides on): %s", changed, overridden, state)
    end
end

local function tod_distance(a, b)
    local d = math.abs(a - b) % 2400
    return math.min(d, 2400 - d)
end

local last_weather_applied = nil
local last_weather_at = 0

-- Client: apply a host snapshot.
function M.apply_env(tod, weather_path, weather_state)
    if not cfg.get("sync_env") then return end
    pcall(M.sky_probe, "client")
    if weather_state and weather_state ~= "" then
        local wa = weather()
        if wa then
            local ok, err = pcall(apply_weather_state, wa, weather_state)
            if not ok then log.err_throttled("env-state", "weather state: %s", tostring(err)) end
        end
    end
    local s = sky()
    if s and type(tod) == "number" then
        local cur = ue.prop(s, TOD_PROP)
        if type(cur) == "number" and tod_distance(cur, tod) > TOD_TOLERANCE then
            if ue.set_prop(s, TOD_PROP, tod) then
                M.stats.tod_fixes = M.stats.tod_fixes + 1
                log.debug("env: time of day %.1f -> %.1f", cur, tod)
                if tod_distance(cur, tod) > 50 and M.note_time_cause then
                    M.note_time_cause(string.format("ENV: this sky had %s, set to the host's %s",
                        M.hhmm(cur), M.hhmm(tod)), 5)
                end
            end
        end
    end

    local w = weather()
    if w and weather_path and weather_path ~= "" then
        -- Replicated weather actor (role 1) follows the host by itself.
        if ue.role(w) == ue.ROLE_SIMULATED then return end
        local curobj = ue.prop(w, "Weather")
        local cur = ue.valid(curobj) and ue.path(curobj) or ""
        if cur == weather_path then return end
        -- A transition is already running towards this preset.
        if last_weather_applied == weather_path and os.time() - last_weather_at < 60 then return end
        -- only a preset already in memory: a synchronous load (every ENV, 5 s,
        -- while it is missing) could wait for the world's streaming and
        -- freeze the client; the channel overrides above carry the weather
        local preset = ue.loaded_asset(weather_path, "sync.ENV")
        if not preset then return end
        local ok = ue.call(w, "Change Weather", preset, WEATHER_TRANSITION_S)
        if not ok then ok = ue.set_prop(w, "Weather", preset) end
        if ok then
            last_weather_applied = weather_path
            last_weather_at = os.time()
            M.stats.weather_fixes = M.stats.weather_fixes + 1
            log.info("env: weather -> %s", weather_path)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Pause
-- ---------------------------------------------------------------------------

local saved_pauseable = nil

-- Host only. With remote players connected the world must keep running.
function M.pause_policy(has_remote_players)
    local gm = ue.find_first("GameModeBase")
    if not gm then return end
    if has_remote_players and cfg.get("no_pause") then
        if saved_pauseable == nil then
            local cur = ue.prop(gm, "bPauseable")
            saved_pauseable = (cur == nil) and true or cur
            ue.set_prop(gm, "bPauseable", false)
            log.info("pause: disabled while players are connected (was %s)", tostring(saved_pauseable))
        end
        if ue.is_paused() then
            ue.set_paused(false)
            log.info("pause: world was paused with players connected, unpaused")
        end
    elseif saved_pauseable ~= nil then
        ue.set_prop(gm, "bPauseable", saved_pauseable)
        log.info("pause: restored bPauseable=%s", tostring(saved_pauseable))
        saved_pauseable = nil
    end
end

-- ---------------------------------------------------------------------------
-- Game clock log
-- ---------------------------------------------------------------------------
-- The game's day: Ultra Dynamic Sky animates Time of Day (0..2400) on the
-- host; clients get Replicated Time of Day once a second. BP_SkySettings
-- (3 s after BeginPlay, then on every change) copies the world's difficulty
-- settings Difficulty.DayLength / Difficulty.NightLength (defaults 30 / 15,
-- saved per world in Difficulties.sav) into UDS "Day Length" / "Night
-- Length" (replicated): real minutes for the whole daytime (Dawn -> Dusk,
-- about 06:00 -> 19:00 on this map) and for the whole night. UDS Time of Day
-- Offset: units per second = Time Speed / 60 * span / length. At 24:00 UDS
-- Day Ended moves the date on (Offset Date) and Midnight adds a day to the
-- GameMode's DaysSurvived; UDW works its season out of the UDS date (Season
-- Mode 0); the save keeps date and time (General.sav, UDS_and_UDW_State).
-- Host / single player: one line per in-game hour (time, day, date, season,
-- snow). Every machine: one line per time jump, with its cause.
local clock = {
    sky = nil, sky_addr = nil, w = nil, tod = nil, at = nil, running = nil,
    hour = nil, hour_at = nil, world_at = 0, jump = nil,
    cause = nil, cause_until = -1000, ticking = false,
}
local SEASON_NAMES = { [0] = "spring", [1] = "summer", [2] = "autumn", [3] = "winter" }
local JUMP_MIN_UNITS = 50   -- a jump: at least 30 game minutes in one tick...
local JUMP_MIN_RATE = 10    -- ...at more than 10 units a real second (the menu's fastest day is far below)

-- "HH:MM" of a Time of Day value.
function M.hhmm(tod)
    if type(tod) ~= "number" then return "?" end
    local t = tod % 2400
    local h = math.floor(t / 100)
    return string.format("%02d:%02d", h, math.floor((t - h * 100) * 0.6))
end

-- Why the next time jump happens (sleep, ENV, ...), valid for `ttl_s`.
function M.note_time_cause(text, ttl_s)
    clock.cause = text
    clock.cause_until = os.clock() + (ttl_s or 20)
end

local function fnum(v, f) return type(v) == "number" and string.format(f or "%.2f", v) or "?" end

local function date_text(s)
    local y, m, d = tonumber(ue.prop(s, "Year")), tonumber(ue.prop(s, "Month")), tonumber(ue.prop(s, "Day"))
    if not (y and m and d) then return "?" end
    return string.format("%04d-%02d-%02d", y, m, d)
end

-- UDW Season: 0 spring, 1 summer, 2 autumn, 3 winter (fractional in between).
local function season_text(w)
    local v = ue.prop(w, "Season")
    if type(v) ~= "number" then return "?" end
    return string.format("%s (%.2f)", SEASON_NAMES[math.floor(v + 0.5) % 4] or "?", v)
end

local function weather_text(w)
    if not ue.valid(w) then return "no weather actor" end
    local gws = ue.prop(w, "Global Weather State")
    local src = ue.valid(gws) and gws or w
    local target = ue.prop(ue.prop(w, "Random Weather Manager"), "Target Random Weather Type")
    return string.format("weather %s: snow %s, snow cover %s, rain %s, dust %s",
        ue.valid(target) and ue.short(target) or "?", fnum(ue.prop(src, "Snow"), "%.1f"),
        fnum(ue.prop(src, "Material Snow Coverage")), fnum(ue.prop(src, "Rain"), "%.1f"),
        fnum(ue.prop(src, "Dust"), "%.1f"))
end

local function lengths_text(s)
    return string.format("day length %s min, night length %s min", fnum(ue.prop(s, "Day Length"), "%g"),
        fnum(ue.prop(s, "Night Length"), "%g"))
end

-- `note`: " (start)" / " (after the jump)": no whole hour behind it.
local function hour_line(s, w, tod, now, note)
    local took = (not note and clock.hour_at) and string.format("%.1f", (now - clock.hour_at) / 60) or "-"
    log.info("time: %s day %s, date %s, season %s | %s | the last hour took %s real min (%s)%s",
        M.hhmm(math.floor(tod / 100) * 100), tostring(ue.prop(ue.local_pc(), "DaysSurvived")), date_text(s),
        season_text(w), weather_text(w), took, lengths_text(s), note or "")
end

local function finish_jump(role, now)
    local j = clock.jump
    clock.jump = nil
    local cause = clock.cause
    if not cause or now > clock.cause_until then
        if role == "client" and now - clock.world_at < 90 then
            cause = "join: the host's time reached this client"
        else
            cause = "no sleep, load or join seen (subway travel, the console, another mod?)"
        end
    end
    clock.cause = nil
    log.info("time: jump %s -> %s (%+.2f game h in %.1f s): %s", M.hhmm(j.from), M.hhmm(j.to), j.units / 100,
        (j.last or now) - j.start, cause)
end

local function clock_actors()
    if not ue.valid(clock.sky) then clock.sky, clock.w = sky(), nil end
    if clock.sky and not ue.valid(clock.w) then clock.w = weather() end
    return clock.sky, clock.w
end

-- Every second (game thread): the hour line and the time jumps.
function M.time_tick()
    local sess = package.loaded["sdc_session"]
    local st = type(sess) == "table" and sess.state or nil
    local role = st and st.role or "unknown"
    if role == "unknown" or not st or st.in_menu ~= false then
        clock.tod, clock.sky_addr, clock.jump = nil, nil, nil
        return
    end
    local s, w = clock_actors()
    if not s then return end
    local now = os.clock()
    local tod = ue.prop(s, TOD_PROP)
    if type(tod) ~= "number" then return end
    local running = ue.prop(s, "Animate Time of Day") == true
    local a = addr(s)
    if a ~= clock.sky_addr then
        clock.sky_addr, clock.world_at = a, now
        clock.tod, clock.at, clock.hour, clock.hour_at, clock.jump, clock.running = nil, nil, nil, nil, nil, nil
        log.info("time: %s sky %s at %s (tod %.1f), running=%s, date %s, %s", role, ue.short(s), M.hhmm(tod), tod,
            tostring(running), date_text(s), lengths_text(s))
    end
    if not running then
        -- a sky that has not started yet (a world still loading)
        clock.tod, clock.at, clock.running = tod, now, false
        return
    end
    if clock.running == false and clock.tod then
        -- startup: the save's time (or the host's) replaces the level's default
        log.info("time: sky started at %s (it showed %s while the world loaded): %s, not a time skip",
            M.hhmm(tod), M.hhmm(clock.tod), role == "client" and "the host's time" or "the save's time")
        clock.tod, clock.hour = nil, nil
    end
    clock.running = true
    local prev, prev_at = clock.tod, clock.at
    clock.tod, clock.at = tod, now
    if prev and prev_at then
        local d = (tod - prev) % 2400
        if d > 1200 then d = d - 2400 end
        local dt = math.max(now - prev_at, 0.001)
        if (d >= JUMP_MIN_UNITS and d / dt >= JUMP_MIN_RATE) or d <= -5 then
            local j = clock.jump
            if not j then
                j = { from = prev, start = prev_at, units = 0 }
                clock.jump = j
            end
            j.units, j.to, j.last = j.units + d, tod, now
            return
        end
        if clock.jump then
            finish_jump(role, now)
            if role ~= "client" then hour_line(s, w, tod, now, " (after the jump)") end
            clock.hour, clock.hour_at = math.floor(tod / 100), now
            return
        end
    end
    local h = math.floor(tod / 100)
    if clock.hour == nil then
        clock.hour, clock.hour_at = h, nil
        if role ~= "client" then hour_line(s, w, tod, now, " (start)") end
        return
    end
    if h ~= clock.hour then
        if role ~= "client" then hour_line(s, w, tod, now) end
        clock.hour, clock.hour_at = h, now
    end
end

-- ---------------------------------------------------------------------------
-- AI
-- ---------------------------------------------------------------------------

local AI_CLASSES = { "BP_MasterAICharacter_C" }
local AI_SPAWNERS = { "BP_AIManager_C", "BP_AISpawnPoint_C" }

local function each_ai(fn)
    for _, cls in ipairs(AI_CLASSES) do
        for _, a in ipairs(ue.find_all(cls)) do
            if ue.valid(a) then fn(a) end
        end
    end
end

-- Network update rate of AI characters (host; config ai_net_rate, 0 = the
-- game's). They keep the engine default NetUpdateFrequency of 100 a second:
-- with a client connected the net driver re-checks every zombie in range
-- every frame (host CPU) and sends its movement as often as the client's
-- bandwidth allows, crowding out everything else. A client interpolates
-- other characters' movement between updates; 30 a second stays smooth.
M.AI_NET_RATE_DEFAULT = 30
local ai_rate_logged = nil

local function ai_net_rate()
    local r = tonumber(cfg.get("ai_net_rate"))
    if r == nil then r = M.AI_NET_RATE_DEFAULT end
    if r <= 0 then return nil end
    return math.max(5, math.min(100, r))
end

-- Host: make sure every runtime-spawned AI character replicates.
function M.host_ai_tick()
    if not cfg.get("ai_fix") then return end
    local rate = ai_net_rate()
    local total, fixed, slowed, failed = 0, 0, 0, 0
    each_ai(function(a)
        total = total + 1
        if ue.is_runtime_spawned(a) and ue.prop(a, "bReplicates") == false then
            local ok = pcall(function()
                a:SetReplicates(true)
                a:SetReplicateMovement(true)
            end)
            if ok then fixed = fixed + 1 end
        end
        if rate then
            local f = ue.prop(a, "NetUpdateFrequency")
            if type(f) == "number" and f > rate + 0.5 then
                local ok = ue.call(a, "SetNetUpdateFrequency", rate)
                if not ok then ok = ue.set_prop(a, "NetUpdateFrequency", rate) end
                if ok then slowed = slowed + 1 else failed = failed + 1 end
                if not ai_rate_logged then
                    ai_rate_logged = true
                    log.info("ai: NetUpdateFrequency %s -> %s on %s (ai_net_rate=%d, ok=%s)", tostring(f),
                        tostring(ue.prop(a, "NetUpdateFrequency")), ue.short(a), rate, tostring(ok))
                end
            end
        end
    end)
    if fixed > 0 then
        M.stats.ai_replicated = M.stats.ai_replicated + fixed
        log.info("ai: enabled replication on %d of %d AI characters", fixed, total)
    end
    if slowed > 0 or failed > 0 then
        M.stats.ai_rate_set = (M.stats.ai_rate_set or 0) + slowed
        log.info("ai: network update rate %d/s set on %d AI characters (%d failed, %d AI)", rate, slowed, failed, total)
    end
end

-- Client: the client must never own AI. Locally-authoritative AI (role 3)
-- is a ghost spawned by a level AI manager running on this machine.
local disabled_spawners = {}
local spawner_done = {}  -- [address] = true: disabled already (no full-name string per spawner every 3 s)
local ghost_tries = {}   -- actor name -> removal attempts (an actor that stays is not retried forever)
function M.client_ai_tick()
    if not cfg.get("ai_fix") then return end
    for _, cls in ipairs(AI_SPAWNERS) do
        for _, sp in ipairs(ue.find_all(cls)) do
            -- disabled on an earlier pass (spawners are level actors): skipped
            -- by address, without building its full name again
            local a = addr(sp)
            if not (a and spawner_done[a]) then
                local key = ue.name(sp)
                if ue.valid(sp) and not disabled_spawners[key] and ue.role(sp) == ue.ROLE_AUTHORITY then
                    disabled_spawners[key] = true
                    if a then spawner_done[a] = true end
                    local ok = ue.set_prop(sp, "Enable Spawn AI", false)
                    pcall(function() sp:SetActorTickEnabled(false) end)
                    M.stats.managers_disabled = M.stats.managers_disabled + 1
                    log.info("ai: disabled local spawner %s (prop ok=%s)", ue.short(sp), tostring(ok))
                end
            end
        end
    end
    local removed = 0
    local names = {}
    local ksl = ue.ksl()
    each_ai(function(a)
        if ue.role(a) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(a) then
            -- the host's own AI torn off on death (corpses) also turn into
            -- local authority here: they are not ghosts, leave them
            if ue.prop(a, "bTearOff") == true then return end
            -- destroyed already: FindAllOf lists it until the next garbage
            -- collection (UE4SS IsValid only checks reachability)
            if ksl and ue.try(function() return ksl:IsValid(a) end) == false then return end
            local key = ue.name(a)
            local n = (ghost_tries[key] or 0) + 1
            ghost_tries[key] = n
            if n > 2 then
                if n == 3 then
                    log.warn("ai: local AI %s survives removal (dead=%s), left alone", ue.short(a),
                        tostring(ue.prop(a, "IsDead?")))
                end
                return
            end
            local what = string.format("%s(dead=%s)", ue.short(a), tostring(ue.prop(a, "IsDead?")))
            if pcall(function() a:K2_DestroyActor() end) then
                removed = removed + 1
                if #names < 6 then names[#names + 1] = what end
            end
        end
    end)
    if removed > 0 then
        M.stats.ai_ghosts_removed = M.stats.ai_ghosts_removed + removed
        log.info("ai: removed %d local ghost AI on client: %s%s", removed, table.concat(names, " "),
            removed > #names and " ..." or "")
    end
end

function M.reset_client_state()
    disabled_spawners = {}
    spawner_done = {}
    ghost_tries = {}
    last_weather_applied = nil
    M.env_report_logged = false
end

-- ---------------------------------------------------------------------------
-- Player characters
-- ---------------------------------------------------------------------------

-- Client: a BP_PlayerCharacter with local authority that this machine does
-- not control is a stale copy created by the game's own save/load flow.
-- Replicated players (role 1, the host and other clients) are never touched:
-- v0.2.x hid exactly those (it tested role == 1), which made the host
-- invisible on the client.
local hidden = {}
function M.client_hide_stale_pawns()
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and ue.role(p) == ue.ROLE_AUTHORITY then
            local okLC, isLC = pcall(function() return p:IsLocallyControlled() end)
            if not (okLC and isLC) then
                local key = ue.name(p)
                pcall(function() p:SetActorHiddenInGame(true) end)
                pcall(function() p:SetActorEnableCollision(false) end)
                ue.teleport(p, { X = 0, Y = 0, Z = -200000 })
                if not hidden[key] then
                    hidden[key] = true
                    M.stats.pawn_ghosts_hidden = M.stats.pawn_ghosts_hidden + 1
                    log.info("players: hid stale local copy %s", ue.short(p))
                end
            end
        end
    end
end

-- Mesh components of an actor with their visibility flags.
function M.mesh_states(actor)
    local out = {}
    local cls = ue.find_object("/Script/Engine.MeshComponent")
    if not cls then return out end
    local ok, arr = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
    if not ok or arr == nil then
        log.debug("mesh_states: K2_GetComponentsByClass failed: %s", tostring(arr))
        return out
    end
    local function add(c)
        if c and type(c) == "userdata" and not ue.valid(c) then
            local okg, got = pcall(function() return c:get() end)
            if okg then c = got end
        end
        if not ue.valid(c) then return end
        local asset = nil
        for _, pname in ipairs({ "SkeletalMeshAsset", "SkeletalMesh", "StaticMesh" }) do
            local a = ue.prop(c, pname)
            if ue.valid(a) then asset = a break end
        end
        out[#out + 1] = {
            comp = c, name = ue.short(c), asset = asset and ue.path(asset) or "",
            visible = ue.prop(c, "bVisible"), hidden_in_game = ue.prop(c, "bHiddenInGame"),
            owner_no_see = ue.prop(c, "bOwnerNoSee"), only_owner_see = ue.prop(c, "bOnlyOwnerSee"),
        }
    end
    if type(arr) == "table" then
        for _, c in ipairs(arr) do add(c) end
    else
        local okf, e = pcall(function() arr:ForEach(function(_, el) add(el) end) end)
        if not okf then log.debug("mesh_states: ForEach failed: %s (type %s)", tostring(e), type(arr)) end
    end
    return out
end

local function log_mesh_states(tag, p)
    for _, m in ipairs(M.mesh_states(p)) do
        log.info("players: %s %s.%s asset=%s visible=%s hiddenInGame=%s ownerNoSee=%s onlyOwnerSee=%s",
            tag, ue.short(p), m.name, m.asset, tostring(m.visible), tostring(m.hidden_in_game),
            tostring(m.owner_no_see), tostring(m.only_owner_see))
    end
end
M.log_mesh_states = log_mesh_states

-- ---------------------------------------------------------------------------
-- Equipment attached to player characters (backpack, weapons, headwear...)
-- ---------------------------------------------------------------------------

-- Components attached under the pawn that belong to OTHER actors, i.e. the
-- root components of equipped item actors. Walks the attachment tree with
-- GetNumChildrenComponents / GetChildComponent (no out-params needed).
function M.attached_items(pawn)
    local out = {}
    local root = ue.try(function() return pawn:K2_GetRootComponent() end)
    if not ue.valid(root) then return out end
    local pawn_name = ue.name(pawn)
    local seen = {}
    local function walk(comp, depth)
        if depth > 5 then return end
        local n = ue.try(function() return comp:GetNumChildrenComponents() end)
        if type(n) ~= "number" then return end
        for i = 0, n - 1 do
            local child = ue.try(function() return comp:GetChildComponent(i) end)
            if ue.valid(child) then
                local owner = ue.try(function() return child:GetOwner() end)
                if ue.valid(owner) and ue.name(owner) ~= pawn_name then
                    local key = ue.name(owner)
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = {
                            actor = owner, comp = child, parent = comp,
                            socket = ue.str(ue.try(function() return child:GetAttachSocketName() end)),
                        }
                    end
                else
                    walk(child, depth + 1)
                end
            end
        end
    end
    walk(root, 0)
    return out
end

local SLOT_FLAGS = { "PrimaryWeaponEquipped?", "SecondaryWeaponEquipped?", "SidearmWeaponEquipped?",
    "MeleeWeaponEquipped?", "BackpackEquipped?", "HeadwearEquipped?", "BodyArmorEquipped?",
    "ContainerEquipped?", "FlashlightEquipped?", "ThrowableEquipped?", "EyewearEquipped?",
    "FacewearEquipped?", "AccessoryEquipped?" }

function M.log_equipment(tag, pawn)
    local flags = {}
    for _, f in ipairs(SLOT_FLAGS) do
        local v = ue.prop(pawn, f)
        if v ~= nil then flags[#flags + 1] = f:gsub("Equipped%?", "") .. "=" .. tostring(v) end
    end
    log.info("equip: %s %s slots: %s", tag, ue.short(pawn), table.concat(flags, " "))
    for _, it in ipairs(M.attached_items(pawn)) do
        local a = it.actor
        local meshes = {}
        for _, m in ipairs(M.mesh_states(a)) do
            if m.asset ~= "" then meshes[#meshes + 1] = m.name .. "=" .. m.asset:gsub("^/Game/", "") end
        end
        local loc = ue.prop(it.comp, "RelativeLocation")
        log.info("equip: %s   %s class=%s role=%d repl=%s hidden=%s parent=%s socket=%s rel=%s meshes=[%s]",
            tag, ue.short(a), ue.class_name(a), ue.role(a), tostring(ue.prop(a, "bReplicates")),
            tostring(ue.prop(a, "bHidden")), ue.short(it.parent), it.socket,
            loc and string.format("%.1f,%.1f,%.1f", ue.try(function() return loc.X end) or 0,
                ue.try(function() return loc.Y end) or 0, ue.try(function() return loc.Z end) or 0) or "?",
            table.concat(meshes, " "))
    end
end

-- ---------------------------------------------------------------------------
-- Message handlers (client side)
-- ---------------------------------------------------------------------------

-- Defined further down (movement / sound sections). Declared here so the
-- handlers below call those locals: a `local function` that comes later in
-- the file is invisible here and the name would resolve to a nil global.
local apply_setmove, play_forwarded

function M.register_handlers()
    net.on("ENV", function(f)
        M.apply_env(tonumber(f[1]), f[2], f[3])
    end)
    -- SETMOVE|<movement mode>|<disable>: host -> owning client (client_movement_authority)
    net.on("SETMOVE", function(f)
        local ok, err = pcall(apply_setmove, f)
        if not ok then log.err_throttled("setmove-apply", "movement: SETMOVE: %s", tostring(err)) end
    end)
    -- SND|<sound asset>|x|y|z|volume|pitch[|shooter id]  (forwarded by the host)
    net.on("SND", function(f) play_forwarded(f) end)
end

-- ---------------------------------------------------------------------------
-- Global time dilation
-- ---------------------------------------------------------------------------
-- Single-player slow motion goes through GameplayStatics.SetGlobalTimeDilation.
-- On a listen server that is the speed of the whole shared world
-- (AWorldSettings.TimeDilation replicates: the host opening its inventory
-- slowed every client to a quarter); on a client it only desynchronises its
-- own simulation from the server.
--
-- The game gates it itself:
--   * CVar Game.SlowTime (the "slow time" game setting, SD_GameInstance@2400):
--     BP_Inventory@1909-1952 (0.25), BP_JigComponent@1347-1394 (0.2),
--     BP_PlayerCharacter@48135-48178 (radial menu, 0.2);
--   * KismetSystemLibrary.IsStandalone: RespawnScreen@2286-2317 (0.1) never
--     slows a network game.
-- So in co-op the setting is switched off with the game's own CVar helper
-- (AutoSettings ConsoleUtils.SetBoolCVar, as the game sets its Debug.* CVars)
-- and switched back on when co-op ends. The SetGlobalTimeDilation hook stays
-- as a logged fallback for callers that do not check the setting.
local dilation = { hooked = false, logged = {} }

-- true / false; nil while the role is unknown (map loads)
local function coop_active()
    local role = ue.net_role()
    if role == "unknown" then return nil end
    return role == "client" or (role == "host" and #(M.remote_pcs or {}) > 0)
end

local function on_set_dilation(_, wco, value)
    if not value or not coop_active() then return end
    local ok, v = pcall(function() return value:get() end)
    if not ok or type(v) ~= "number" or math.abs(v - 1) < 1e-3 then return end
    pcall(function() value:set(1.0) end)
    local w = wco and wco:get()
    local who = ue.valid(w) and ue.class_name(w) or "?"
    if not dilation.logged[who] then
        dilation.logged[who] = true
        log.info("time: fallback: slow motion %.2f from %s set to 1.0 (co-op; caller does not check Game.SlowTime)",
            v, who)
    end
end

-- Game.SlowTime through the game's CVar helper, KismetSystemLibrary / the
-- console as fallbacks. nil when the value cannot be read.
local SLOWTIME = "Game.SlowTime"
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"
local slowtime = { forced = false, restore = false, unreadable_logged = false, ticking = false }

local function get_slowtime()
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu then
        local ok, v = pcall(function() return cu:GetBoolCVar(FName(SLOWTIME)) end)
        if ok and type(v) == "boolean" then return v end
    end
    local ksl = ue.ksl()
    if ksl then
        local ok, v = pcall(function() return ksl:GetConsoleVariableBoolValue(SLOWTIME) end)
        if ok and type(v) == "boolean" then return v end
    end
    return nil
end

local function set_slowtime(on)
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu and pcall(function() cu:SetBoolCVar(FName(SLOWTIME), on) end) and get_slowtime() == on then
        return true, "ConsoleUtils"
    end
    ue.exec(SLOWTIME .. " " .. (on and "1" or "0"))
    return get_slowtime() == on, "console"
end

-- 1 s: in co-op Game.SlowTime is kept off (the settings menu or a settings
-- reload may switch it back on); outside co-op the value it had is restored.
function M.slowtime_tick()
    local coop = coop_active()
    if coop == nil then return end   -- role unknown (loading): keep the current state
    local want_off = coop and cfg.get("coop_slowtime_off") ~= false
    if want_off then
        local cur = get_slowtime()
        if cur == nil then
            if not slowtime.unreadable_logged then
                slowtime.unreadable_logged = true
                log.warn("time: %s unreadable; only the SetGlobalTimeDilation fallback protects co-op", SLOWTIME)
            end
            return
        end
        if cur then
            local ok, how = set_slowtime(false)
            if ok then
                slowtime.forced, slowtime.restore = true, true
                log.info("time: co-op: %s 1 -> 0 (%s); restored when co-op ends", SLOWTIME, how)
            else
                log.err_throttled("slowtime-set", "time: could not switch %s off (%s)", SLOWTIME, how)
            end
        elseif not slowtime.forced then
            slowtime.forced = true
            log.info("time: co-op: %s already 0, nothing to restore later", SLOWTIME)
        end
    elseif slowtime.forced then
        slowtime.forced = false
        if slowtime.restore then
            slowtime.restore = false
            local ok, how = set_slowtime(true)
            log.info("time: co-op ended: %s back to 1 (%s, ok=%s)", SLOWTIME, how, tostring(ok))
        end
    end
end

function M.install_time_dilation_guard()
    if dilation.hooked then return end
    dilation.hooked = true
    local ok, err = ue.hook_native("/Script/Engine.GameplayStatics:SetGlobalTimeDilation", "sync.dilation", function(c, wco, value)
        local okc, e = pcall(on_set_dilation, c, wco, value)
        if not okc then log.err_throttled("dilation", "time dilation guard: %s", tostring(e)) end
    end)
    log.info("time: dilation fallback hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    if not slowtime.ticking then
        slowtime.ticking = true
        ue.every("slowtime", 1000, M.slowtime_tick)
    end
    -- the game clock log (hour lines, time jumps); here because main.lua
    -- installs this guard once at start
    if not clock.ticking then
        clock.ticking = true
        ue.every("timelog", 1000, M.time_tick)
    end
end

-- ---------------------------------------------------------------------------
-- Movement of remote players (host side)
-- ---------------------------------------------------------------------------
-- With stock settings the server re-simulates every client move and sends a
-- correction whenever the result differs even slightly; in this game that
-- happens constantly and the client sees its own character jitter (the
-- host sees it smooth). For co-op between friends the client is trusted:
-- the server skips the error check and takes the client's position.

local movement_done = {}
local netfreq_done = {}
local MIN_NET_FREQ = 60

-- Component replication of player characters. If the capsule (the root)
-- replicates, the server's position (one network trip + a server frame
-- behind) is written straight into the owning client's capsule through
-- OnRep_Transform: the client's own character jumps back along its path a
-- few times a second while its velocity stays forward (the client's "back
-- steps"). Stock ACharacter does not replicate these components; position
-- reaches others through the actor's ReplicatedMovement.
M.capsule_rep_wanted = false            -- experiment.txt "comprep on" restores the game's setting
local comprep_logged = {}

local function component_replication(p)
    local key = ue.name(p)
    local parts = {}
    for _, cname in ipairs({ "CapsuleComponent", "Mesh", "CharacterMovement" }) do
        local comp = ue.prop(p, cname)
        if ue.valid(comp) then
            -- GetIsReplicated is not a UFUNCTION: read the property itself
            local rep = ue.prop(comp, "bReplicates")
            parts[#parts + 1] = cname .. "=" .. tostring(rep)
            -- only the capsule: the game may rely on the mesh's replication
            if cname == "CapsuleComponent" and cfg.get("fix_capsule_replication") ~= false then
                local want = M.capsule_rep_wanted
                if rep ~= nil and rep ~= want then
                    local ok = pcall(function() comp:SetIsReplicated(want) end)
                    parts[#parts + 1] = string.format("(%s -> %s ok=%s)", cname, tostring(want), tostring(ok))
                end
            end
        end
    end
    local text = table.concat(parts, " ")
    if comprep_logged[key] ~= text then
        comprep_logged[key] = text
        log.info("movement: component replication of %s: %s", ue.short(p), text)
    end
end

-- Movement mode of a client's own character (client_movement_authority).
-- In a network game the owner learns the server's movement mode only through
-- the server's movement corrections, which a client-authoritative character
-- never receives. Game Blueprints change the mode on the server in two ways:
--   * Svr_SetMovement(NewMovementMode, Disable?) from the owner (BP @125682 ->
--     @72162), e.g. 1.5 s after a hard landing with a broken bone
--     (@123911 DisableMovement here -> @10351 Svr_SetMovement(Walking));
--   * directly on the server: ReceivePossessed's spawn sequence
--     (@9921 SetMovementMode(None) ... @9829 SetMovementMode(Walking/Swimming)).
-- Without the corrections the client stayed in MOVE_None (and the server copy
-- followed it). The host therefore forwards every Blueprint SetMovementMode /
-- DisableMovement on a client's character (native hooks: only calls from game
-- Blueprints pass through them, not the engine's own internal mode changes)
-- to that client (SETMOVE), which applies it as the correction would have.
local SETMODE_FN = "/Script/Engine.CharacterMovementComponent:SetMovementMode"
local DISABLE_FN = "/Script/Engine.CharacterMovementComponent:DisableMovement"
local setmove = { hooked = false, sent = 0, applied = 0, last = {} }

local function relay_mode(cmc, mode, dis)
    if not cfg.get("client_movement_authority") then return end
    if not ue.valid(cmc) then return end
    local pawn = ue.try(function() return cmc:GetOwner() end)
    if not ue.valid(pawn) or not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return end
    -- the host's copy of a remote player's character only
    if ue.try(function() return pawn:HasAuthority() end) ~= true then return end
    if ue.try(function() return pawn:IsLocallyControlled() end) == true then return end
    local pc = ue.prop(pawn, "Controller")
    if not ue.valid(pc) or not ue.valid(ue.prop(pc, "NetConnection")) then return end
    local key = ue.name(pawn)
    local val = dis and "d" or tostring(mode)
    local now = os.clock()
    local l = setmove.last[key]
    if l and l.v == val and now - l.t < 0.2 then return end
    setmove.last[key] = { v = val, t = now }
    if net.send_to(pc, "SETMOVE", tostring(math.floor(tonumber(mode) or 1)), dis and "1" or "0") then
        setmove.sent = setmove.sent + 1
        if setmove.sent <= 8 then
            log.info("movement: host %s on %s; sent to its owner", dis and "DisableMovement" or ("SetMovementMode(" .. tostring(mode) .. ")"), ue.short(pawn))
        end
    end
end

local function install_setmove_hook()
    if setmove.hooked then return end
    setmove.hooked = true
    local ok1, err1 = ue.hook_native(SETMODE_FN, "sync.setmove", function(ctx, mode_p)
        local okc, e = pcall(function() relay_mode(ctx and ctx:get(), tonumber(mode_p and mode_p:get()) or 1, false) end)
        if not okc then log.err_throttled("setmove", "movement: SetMovementMode hook: %s", tostring(e)) end
    end)
    local ok2, err2 = ue.hook_native(DISABLE_FN, "sync.setmove", function(ctx)
        local okc, e = pcall(function() relay_mode(ctx and ctx:get(), 0, true) end)
        if not okc then log.err_throttled("setmove", "movement: DisableMovement hook: %s", tostring(e)) end
    end)
    log.info("movement: movement-mode relay hooks SetMovementMode %s, DisableMovement %s",
        ok1 and "ok" or ("FAILED " .. tostring(err1)), ok2 and "ok" or ("FAILED " .. tostring(err2)))
end

-- Client: SETMOVE|<EMovementMode>|<disable 0/1> for the own character.
-- (assigns the local declared above M.register_handlers)
function apply_setmove(f)
    local pawn = ue.local_pawn()
    local cmc = pawn and ue.prop(pawn, "CharacterMovement")
    if not ue.valid(cmc) then return end
    local mode = tonumber(f[1])
    local dis = f[2] == "1"
    local before = ue.prop(cmc, "MovementMode")
    local ok, err
    if dis then
        ok, err = pcall(function() cmc:DisableMovement() end)
    elseif mode and mode >= 0 and mode <= 6 then
        ok, err = pcall(function() cmc:SetMovementMode(math.floor(mode), 0) end)
    else
        return
    end
    setmove.applied = setmove.applied + 1
    if setmove.applied <= 5 or not ok then
        log.info("movement: host set the own movement mode %s -> %s%s (%s)", tostring(before),
            dis and "disabled" or tostring(mode), ok and "" or (" FAILED " .. tostring(err)), ue.short(pawn))
    end
end

function M.host_movement_tick(remote_pcs)
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and ue.valid(ue.prop(p, "PlayerState")) then
            local ok, err = pcall(component_replication, p)
            if not ok then log.err_throttled("comprep", "component replication: %s", tostring(err)) end
        end
    end
    -- Every player character (host's own included) replicates often enough
    -- for smooth remote animation; a single-player game has no reason to.
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        local key = ue.valid(p) and ue.name(p)
        if key and not netfreq_done[key] and ue.valid(ue.prop(p, "PlayerState")) then
            netfreq_done[key] = true
            local before = ue.prop(p, "NetUpdateFrequency")
            if type(before) ~= "number" or before < MIN_NET_FREQ then
                local ok = ue.call(p, "SetNetUpdateFrequency", MIN_NET_FREQ)
                if not ok then ok = ue.set_prop(p, "NetUpdateFrequency", MIN_NET_FREQ) end
                log.info("movement: %s NetUpdateFrequency %s -> %d (ok=%s)", ue.short(p), tostring(before), MIN_NET_FREQ, tostring(ok))
            end
        end
    end

    if not cfg.get("client_movement_authority") then return end
    if #remote_pcs > 0 then install_setmove_hook() end
    for _, pc in ipairs(remote_pcs) do
        local pawn = ue.pawn_of(pc)
        local key = pawn and ue.name(pawn)
        if key and not movement_done[key] then
            local cmc = ue.prop(pawn, "CharacterMovement")
            if ue.valid(cmc) then
                movement_done[key] = true
                local a = ue.set_prop(cmc, "bIgnoreClientMovementErrorChecksAndCorrection", true)
                local b = ue.set_prop(cmc, "bServerAcceptClientAuthoritativePosition", true)
                local throttle = tonumber(cfg.get("move_response_interval")) or 0
                if throttle > 0 then
                    for _, pname in ipairs({ "NetworkMinTimeBetweenClientAckGoodMoves", "NetworkMinTimeBetweenClientAdjustments",
                                             "NetworkMinTimeBetweenClientAdjustmentsLargeCorrection" }) do
                        local before = ue.prop(cmc, pname)
                        local ok = ue.set_prop(cmc, pname, throttle)
                        log.info("movement: %s %s -> %s (ok=%s)", pname, tostring(before), tostring(ue.prop(cmc, pname)), tostring(ok))
                    end
                end
                log.info("movement: %s is client-authoritative (ignoreErrors=%s acceptClientPos=%s -> %s/%s)",
                    ue.short(pawn), tostring(a), tostring(b),
                    tostring(ue.prop(cmc, "bIgnoreClientMovementErrorChecksAndCorrection")),
                    tostring(ue.prop(cmc, "bServerAcceptClientAuthoritativePosition")))
            end
        end
    end
end

-- Debug: movement parameters of the client's character on both sides, to
-- spot server/client mismatches that cause constant corrections.
local MOVE_PROPS = { "MaxWalkSpeed", "MaxWalkSpeedCrouched", "MaxAcceleration", "BrakingDecelerationWalking",
    "GroundFriction", "MaxStepHeight", "GravityScale", "JumpZVelocity", "MovementMode",
    "bOrientRotationToMovement", "bUseControllerDesiredRotation" }

function M.log_movement_config(tag, pawn)
    local cmc = ue.prop(pawn, "CharacterMovement")
    if not ue.valid(cmc) then return end
    local parts = {}
    for _, pname in ipairs(MOVE_PROPS) do
        local v = ue.prop(cmc, pname)
        if type(v) == "number" then v = string.format("%.1f", v) end
        parts[#parts + 1] = pname .. "=" .. tostring(v)
    end
    local rr = ue.prop(cmc, "RotationRate")
    local yaw = rr and ue.try(function() return rr.Yaw end)
    parts[#parts + 1] = "RotYaw=" .. tostring(yaw)
    parts[#parts + 1] = "ctrlYaw=" .. tostring(ue.prop(pawn, "bUseControllerRotationYaw"))
    log.info("movecfg: %s %s %s", tag, ue.short(pawn), table.concat(parts, " "))
end

-- Asset path helpers (sound messages carry paths without "/Game/").
local function short_path(p) return (p:gsub("^/Game/", "")) end
local function full_path(p)
    if p == "" or p:sub(1, 1) == "/" then return p end
    return "/Game/" .. p
end
-- Forwarded sounds (client): only a sound already in memory is played. A
-- synchronous LoadAsset here (per SND message, e.g. far shots of a weapon this
-- client never loaded) could wait for the world's streaming and freeze the
-- client; such a sound is skipped (logged once per asset).
local function load_asset(path)
    return ue.loaded_asset(path, "sync.SND")
end

-- ---------------------------------------------------------------------------
-- Weapon shot sounds
-- ---------------------------------------------------------------------------
-- The game plays the gunshot only on the shooter's machine
-- (BP_FirearmPickup.MuzzleEffects@163/1319/2276 PlaySoundAtLocation); the
-- MC_WeaponEffects multicast carries the flash and the camera shake but no
-- sound. The sound itself is data every machine has: class defaults of the
-- weapon's BP_WeaponsPickupComponent (FirearmSound / FirearmSuppressedSound),
-- and the suppressor state is set on every machine by
-- BP_FirearmPickup.CheckAttachments@372/483 from the replicated
-- BP_JigPickupComponent.RepAttachments (SuppressorAttached? / CurrentSuppressor).
-- (Before 0.6.3 these were read from the weapon ACTOR, which has no such
-- properties; the host then had to learn class -> sound pairs and send them
-- as SNDMAP, and never heard a client's gun of a class it had not fired.)

-- The shot sound MuzzleEffects would play: suppressed sound with a
-- suppressor, else FirearmSound. nil, reason when the weapon has none.
local function weapon_shot_sound(weapon)
    local comp = ue.prop(weapon, "BP_WeaponsPickupComponent")
    if not ue.valid(comp) then return nil, "no BP_WeaponsPickupComponent" end
    local suppressed = ue.prop(comp, "SuppressorAttached?") == true or ue.valid(ue.prop(comp, "CurrentSuppressor"))
    local sound = suppressed and ue.prop(comp, "FirearmSuppressedSound") or nil
    if not ue.valid(sound) then sound = ue.prop(comp, "FirearmSound") end
    if not ue.valid(sound) then return nil, "no FirearmSound" end
    return sound, suppressed
end
M.weapon_shot_sound = weapon_shot_sound

-- Kept for sdc_session (HI handler); SNDMAP is gone, nothing to send.
function M.send_shot_map(_) end

local snd = { hooked = false, players = {}, remote = {}, seen = {}, sent = 0, window = 0, window_n = 0, far = 0 }

local function player_of(obj)
    local a = addr(obj)
    if a and snd.players[a] then return snd.players[a], true end
    local o = obj
    for _ = 1, 4 do
        o = ue.try(function() return o:GetOuter() end)
        if not ue.valid(o) then break end
        local e = snd.players[addr(o) or -1]
        if e then return e, true end
    end
    o = obj
    for _ = 1, 3 do
        o = ue.try(function() return o:GetOwner() end)
        if not ue.valid(o) then break end
        local e = snd.players[addr(o) or -1]
        if e then return e, false end
    end
    return nil
end

-- At most 40 forwarded sounds per second (automatic fire of several players).
local function snd_budget()
    local now = os.clock()
    if now - snd.window > 1 then snd.window, snd.window_n = now, 0 end
    snd.window_n = snd.window_n + 1
    return snd.window_n <= 40
end

-- How far a sound carries (cm) and the attenuation to pass with it: nil when
-- the sound has its own (the game's), else the game's attenuation of its
-- kind (sdc_ownsounds: a sound without attenuation is heard everywhere).
local sound_mod = nil
local function sound_range(s)
    sound_mod = sound_mod or package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
    return sound_mod.range_of(s)
end
local SND_MARGIN = 500     -- cm: the players move while a message travels
local snd_dbg = {}
local function snd_skip(k, fmt, ...)
    snd_dbg[k] = (snd_dbg[k] or 0) + 1
    if snd_dbg[k] <= 20 then log.debug(fmt, ...) end
end

-- Far shots (host). A client gets a copy of another player's character, and
-- with it the weapon multicast that plays the shot, only within the engine's
-- network range (150 m). Gunshots carry 160-325 m (the game's attenuation
-- assets GunshotsPistol ... GunshotsSniper: extent + falloff 157.5-325 m).
-- So a shot fired from 120 m up to its cue's own range from a client is also
-- sent to it as a sound at the shot's position; the client plays it (with
-- the cue's attenuation) only when it has no copy of the shooter (otherwise
-- the multicast already played it). Driven by MC_WeaponEffects on the host,
-- which runs there for every shooter (the host's own shots and the clients'
-- through Svr_WeaponEffects), so client -> client far shots are covered too.
-- (Before: up to 350 m for every gun, also a cue without attenuation -
-- crossbow, flare gun, suppressed revolver - heard at full volume.)
local FAR_MIN = 12000   -- cm

local function far_shots(weapon, shooter, sound)
    if #snd.remote == 0 then return end
    local entry = snd.players[addr(shooter) or -1]
    if not entry then return end
    -- with the debug mirror on, the host's own item sounds already go to everyone
    if cfg.get("mirror_sounds") and not entry.pc then return end
    local loc = ue.location(weapon)
    local id = appearance.player_id(entry.pawn)
    if not loc or not id then return end
    local range = sound_range(sound) or 0
    if range <= FAR_MIN then return end   -- it never carries beyond the net range: the multicast covers it
    local owner_pc = entry.pc and addr(entry.pc)
    local path
    for _, pc in ipairs(snd.remote) do
        if ue.valid(pc) and addr(pc) ~= owner_pc then
            local l = ue.location(ue.pawn_of(pc))
            local d = l and math.sqrt((l.X - loc.X) ^ 2 + (l.Y - loc.Y) ^ 2 + (l.Z - loc.Z) ^ 2)
            if d and d > FAR_MIN and d >= range + SND_MARGIN then
                snd.far_skipped = (snd.far_skipped or 0) + 1
                snd_skip("far", "shot: far shot %s of %s not sent to %s: %.0f m away, it carries %.0f m", ue.short(sound),
                    ue.short(entry.pawn), ue.short(pc), d / 100, range / 100)
            elseif d and d > FAR_MIN and snd_budget() then
                path = path or short_path(ue.path(sound))
                net.send_to(pc, "SND", path, string.format("%.0f", loc.X), string.format("%.0f", loc.Y),
                    string.format("%.0f", loc.Z), "1.00", "1.00", tostring(id))
                snd.far = snd.far + 1
                if snd.far <= 5 then
                    log.info("shot: far shot of %s sent to %s (%.0f m, %s carries %.0f m)", ue.short(entry.pawn),
                        ue.short(pc), d / 100, ue.short(sound), range / 100)
                end
            end
        end
    end
end

-- Debug mirror (mirror_sounds, off by default): the host forwards every
-- sound played by a player's item (PlaySoundAtLocation / SpawnSoundAtLocation)
-- to the other clients. With debug on, each new sound source is logged once.
local function on_sound(fn, wco, sound, loc, vol, pitch)
    if not snd.active then return end
    local w = wco and wco:get()
    local s = sound and sound:get()
    if not ue.valid(w) or not ue.valid(s) then return end
    local entry, direct = player_of(w)
    local cls = ue.class_name(w)
    local is_item = entry and not direct and cls:find("Pickup", 1, true) ~= nil
    if log.debug_enabled then
        local k = cls .. "|" .. ue.short(s)
        if not snd.seen[k] then
            snd.seen[k] = true
            log.info("sound-src: %s %s from %s (player=%s, item=%s)", fn, ue.short(s), cls,
                entry and ue.short(entry.pawn) or "-", tostring(is_item))
        end
    end
    if not is_item or not cfg.get("mirror_sounds") then return end
    if not snd_budget() then return end
    local l = loc and loc:get()
    local x, y, z = ue.try(function() return l.X end), ue.try(function() return l.Y end), ue.try(function() return l.Z end)
    if type(x) ~= "number" then
        -- entry.pawn is up to a second old (rebuilt by host_sound_tick)
        if not ue.valid(entry.pawn) then return end
        local pl = ue.location(entry.pawn)
        if not pl then return end
        x, y, z = pl.X, pl.Y, pl.Z
    end
    local v = vol and tonumber(vol:get()) or 1
    local p = pitch and tonumber(pitch:get()) or 1
    local path = short_path(ue.path(s))
    local owner_pc = entry.pc and addr(entry.pc)
    local range = sound_range(s) or 0
    for _, pc in ipairs(snd.remote) do
        if addr(pc) ~= owner_pc then
            local pl = ue.location(ue.pawn_of(pc))
            local d = pl and math.sqrt((pl.X - x) ^ 2 + (pl.Y - y) ^ 2 + (pl.Z - z) ^ 2)
            if d and d < range + SND_MARGIN then
                net.send_to(pc, "SND", path, string.format("%.0f", x), string.format("%.0f", y), string.format("%.0f", z),
                    string.format("%.2f", v), string.format("%.2f", p))
                snd.sent = snd.sent + 1
            else
                snd_skip("mirror", "sound: mirror of %s not sent to %s: beyond its %.0f m", ue.short(s), ue.short(pc), range / 100)
            end
        end
    end
end

local function install_sound_hooks()
    snd.hooked = true
    -- PlaySoundAtLocation / SpawnSoundAtLocation(WorldContext, Sound, Location, Rotation, Volume, Pitch, ...)
    for _, path in ipairs({ "/Script/Engine.GameplayStatics:PlaySoundAtLocation",
                            "/Script/Engine.GameplayStatics:SpawnSoundAtLocation" }) do
        local fn = path:match(":([%w_]+)$")
        local ok, err = ue.hook_native(path, "sync.mirror", function(_, wco, sound, loc, _, vol, pitch)
            if not snd.active then return end
            local okc, e = pcall(on_sound, fn, wco, sound, loc, vol, pitch)
            if not okc then log.err_throttled("snd", "sound mirror: %s", tostring(e)) end
        end)
        log.info("sound: mirror hook %s %s%s", fn, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
end

function M.host_sound_tick(remote_pcs)
    M.remote_pcs = remote_pcs
    local map = {}
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and ue.valid(ue.prop(p, "PlayerState")) then
            local a = addr(p)
            if a then
                local c = ue.prop(p, "Controller")
                map[a] = { pawn = p, pc = ue.valid(c) and ue.valid(ue.prop(c, "NetConnection")) and c or nil }
            end
        end
    end
    snd.players, snd.remote = map, remote_pcs
    snd.active = #remote_pcs > 0
    -- the PlaySoundAtLocation hooks only serve the debug mirror / the
    -- sound-source log; shot sounds come from MC_WeaponEffects
    if snd.active and not snd.hooked and (cfg.get("mirror_sounds") or log.debug_enabled) then
        install_sound_hooks()
    end
end

-- Level change, or this machine stopped hosting: drop every cached player
-- character / controller without touching it (the old world's objects are
-- freed by the load's garbage collection). The sound hooks stay installed
-- but do nothing while snd.active is false, as before hosting.
function M.forget_world()
    M.monitor_pawns = {}
    M.remote_pcs = {}
    snd.players, snd.remote, snd.active = {}, {}, false
end

-- Client: is there a copy of this player's character here?
local function has_copy_of(id)
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and appearance.player_id(p) == id then return true end
    end
    return false
end

-- Client: play a forwarded sound. A far shot (7th field = shooter's player
-- id) is skipped while the shooter's copy exists: its multicast plays it.
-- Played at its position with the sound's attenuation (the game's attenuation
-- of its kind when it has none), and not at all beyond that range.
-- (assigns the local declared above M.register_handlers)
local far_played = 0
function play_forwarded(f)
    local shooter = tonumber(f[7])
    if shooter and has_copy_of(math.floor(shooter)) then return end
    local s = load_asset(full_path(f[1] or ""))
    local gps, ctx = ue.gameplay_statics(), ue.world_context()
    if not s or not gps or not ctx then return end
    local loc = { X = tonumber(f[2]) or 0, Y = tonumber(f[3]) or 0, Z = tonumber(f[4]) or 0 }
    local range, att = sound_range(s)
    local near, d = sound_mod.audible_here(loc, range)
    if not near then
        snd.recv_far = (snd.recv_far or 0) + 1
        snd_skip("recv", "sound: forwarded %s not played: %s m away, it carries %.0f m", ue.short(s),
            d and string.format("%.0f", d / 100) or "?", (range or 0) / 100)
        return
    end
    local ok, err = pcall(function()
        gps:PlaySoundAtLocation(ctx, s, loc, { Pitch = 0, Yaw = 0, Roll = 0 },
            tonumber(f[5]) or 1, tonumber(f[6]) or 1, 0, att, nil, nil, nil)
    end)
    if not ok then log.err_throttled("snd-play", "play forwarded sound: %s", tostring(err)) end
    if shooter and ok then
        far_played = far_played + 1
        if far_played <= 5 then log.info("shot: far shot %s played (player %d)", ue.short(s), math.floor(shooter)) end
    end
    log.debug("sound: forwarded %s ok=%s", ue.short(s), tostring(ok))
end

-- ---------------------------------------------------------------------------
-- Shot sounds from the weapon multicast (every machine)
-- ---------------------------------------------------------------------------
-- MC_WeaponEffects reaches every machine that has a copy of the shooter (the
-- server executes it too, for every shooter). Wherever it runs for someone
-- else's weapon, the weapon's own shot sound is played at the weapon; on the
-- host it also drives the far-shot relay.

local shot = { hooked = false, played = 0, sources = {} }
local FIREARM_FX = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:MC_WeaponEffects"

local shot_why = {}
local function shot_skip(reason)
    if log.debug_enabled and (shot_why[reason] or 0) < 3 then
        shot_why[reason] = (shot_why[reason] or 0) + 1
        log.info("shot: skipped (%s)", reason)
    end
end

local function on_weapon_effects(weapon)
    if not cfg.get("shot_sounds") then return shot_skip("disabled") end
    if not ue.valid(weapon) then return shot_skip("no weapon") end
    local cls = ue.class_name(weapon)
    local sound, suppressed = weapon_shot_sound(weapon)
    if not sound then return shot_skip(tostring(suppressed) .. " on " .. cls) end   -- 2nd value = reason
    if not shot.sources[cls] then
        shot.sources[cls] = true
        log.info("shot: %s fires %s (%s, from its BP_WeaponsPickupComponent)", cls, ue.short(sound),
            suppressed and "suppressed" or "unsuppressed")
    end
    local shooter = ue.try(function() return weapon:GetOwner() end)
    if not ue.valid(shooter) then shooter = ue.try(function() return weapon:GetAttachParentActor() end) end
    if snd.active and ue.valid(shooter) then
        local okf, ef = pcall(far_shots, weapon, shooter, sound)
        if not okf then log.err_throttled("shot-far", "far shot: %s", tostring(ef)) end
    end
    local me = ue.local_pawn()
    local me_a, sh_a = me and addr(me), ue.valid(shooter) and addr(shooter)
    if me_a and sh_a and me_a == sh_a then return shot_skip("own shot") end
    local gps = ue.gameplay_statics()
    local loc = ue.location(weapon)
    if not gps or not loc then return shot_skip("no location") end
    -- the cue's own attenuation; a cue without one (crossbow, flare gun,
    -- suppressed revolver) gets its kind's, never heard everywhere
    local _, att = sound_range(sound)
    local ok, err = pcall(function()
        gps:PlaySoundAtLocation(weapon, sound, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, att, nil, nil, nil)
    end)
    shot.played = shot.played + 1
    if not ok then
        log.err_throttled("shot", "shot sound: %s", tostring(err))
    elseif log.debug_enabled then
        log.info("shot: played %s for %s (shooter %s, total %d)", ue.short(sound), ue.short(weapon),
            ue.short(shooter), shot.played)
    end
end

-- Lazy: the weapon class is only in memory once a weapon exists.
function M.ensure_shot_sounds()
    if shot.hooked or not cfg.get("shot_sounds") then return end
    if not ue.find_first("BP_FirearmPickup_C") then return end
    shot.hooked = true
    local ok, err = pcall(RegisterHook, FIREARM_FX, function(ctx)
        local weapon = ctx and ctx:get()
        if log.debug_enabled then
            M.fx_counts = M.fx_counts or {}
            M.fx_counts.MC_WeaponEffects = (M.fx_counts.MC_WeaponEffects or 0) + 1
            log.info("fx: MC_WeaponEffects on %s (total %d)", ue.short(weapon), M.fx_counts.MC_WeaponEffects)
        end
        local okc, e = pcall(on_weapon_effects, weapon)
        if not okc then log.err_throttled("shot", "shot sound: %s", tostring(e)) end
        -- other modules: one hook per BP function only
        for name, fn in pairs(M.fx_listeners) do
            local okl, el = pcall(fn, weapon)
            if not okl then log.err_throttled("fx-" .. name, "weapon fx listener %s: %s", name, tostring(el)) end
        end
    end)
    log.info("shot: weapon sound hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end


-- ---------------------------------------------------------------------------
-- Motion probes (debug): who moves the client's character?
-- ---------------------------------------------------------------------------
-- Counts every engine/Blueprint call that can set the position of a
-- watched character (client: its own; host: remote players), per 5 s.

M.fx_listeners = {}   -- [name] = fn(weapon), called after every MC_WeaponEffects

local probes = { installed = false, watched = {}, counts = {}, deltas = {}, last_log = 0,
                 resp = { n = 0, moved = 0, sum = 0, max = 0 } }

local PROBE_FUNCS = {
    "/Script/Engine.Actor:K2_SetActorLocation",
    "/Script/Engine.Actor:K2_SetActorLocationAndRotation",
    "/Script/Engine.Actor:K2_SetActorTransform",
    "/Script/Engine.Actor:K2_TeleportTo",
    "/Script/Engine.Actor:K2_AddActorWorldOffset",
    "/Script/Engine.Actor:K2_SetActorRotation",
    "/Script/Engine.SceneComponent:K2_SetWorldLocation",
    "/Script/Engine.SceneComponent:K2_SetWorldLocationAndRotation",
    "/Script/Engine.SceneComponent:K2_SetWorldTransform",
    "/Script/Engine.Controller:ClientSetLocation",
    "/Script/Engine.Controller:ClientSetRotation",
    "/Script/Engine.Character:ServerMovePacked",
    "/Script/Engine.Character:ClientAdjustPosition",
    "/Script/Engine.Character:ClientVeryShortAdjustPosition",
    "/Script/Engine.Actor:OnRep_ReplicatedMovement",
    "/Script/Engine.Actor:OnRep_ReplicateMovement",
    "/Script/Engine.Actor:OnRep_AttachmentReplication",
    "/Script/Engine.Character:OnRep_ReplicatedBasedMovement",
    "/Script/Engine.Character:OnRep_RootMotion",
    "/Script/Engine.Pawn:OnRep_Controller",
}
-- Character multicasts / server calls that drive the animation state.
-- (Svr_SetMovement left out: the movement-mode relay used to hook it; a second hook
-- on a BP function can replace the first)
for _, fn in ipairs({ "Svr_SetActorLocation", "Svr_SetActorRotation",
                      "MC_UpdateSpeed", "MC_UpdateCombatState", "MC_Montage", "MC_StopMontage",
                      "MC_CrouchSprint", "MC_ADS", "MC_StopADS", "MC_UpdateWeaponSpeed", "MC_SetCapsuleSize",
                      "MC_Crouch", "MC_UnCrouch", "MC_MeleeAim", "MC_SwimFast",
                      "Svr_UpdateSpeed", "Svr_UpdateSprintSpeed", "Svr_UpdateWalkSpeed", "Svr_Montage",
                      "Svr_UpdateCombatState", "Svr_CrouchSprint", "Svr_ADS" }) do
    PROBE_FUNCS[#PROBE_FUNCS + 1] = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:" .. fn
end

function M.probe_watch(pawns)
    local w = {}
    for _, p in ipairs(pawns) do
        if ue.valid(p) then
            local a = addr(p)
            if a then w[a] = true end
            local cap = ue.prop(p, "CapsuleComponent")
            local ca = ue.valid(cap) and addr(cap)
            if ca then w[ca] = true end
            local pc = ue.prop(p, "Controller")
            local pa = ue.valid(pc) and addr(pc)
            if pa then w[pa] = true end
        end
    end
    probes.watched = w
end

function M.install_motion_probes()
    if probes.installed or not log.probes_enabled then return end
    probes.installed = true
    for _, path in ipairs(PROBE_FUNCS) do
        local short = path:match(":([%w_]+)$") or path
        local cb = function(ctx)
            local obj = ctx and ctx:get()
            local a = obj and addr(obj)
            if a and probes.watched[a] then
                probes.counts[short] = (probes.counts[short] or 0) + 1
                -- on a client: the moment a move is sent to the server
                if short == "ServerMovePacked" then probes.last_send = os.clock() end
            end
        end
        local ok, err
        if path:sub(1, 8) == "/Script/" then
            ok, err = pcall(RegisterHook, path, cb, function() end)
        else
            ok, err = pcall(RegisterHook, path, cb)
        end
        if not ok then log.debug("probe: cannot hook %s: %s", short, tostring(err)) end
    end
    -- Server move responses on the owning client: does the response itself
    -- move the character (a correction) or is it only an acknowledgement?
    local okr, errr = pcall(RegisterHook, "/Script/Engine.Character:ClientMoveResponsePacked", function(ctx)
        local p = ctx and ctx:get()
        local a = p and addr(p)
        if a and probes.watched[a] then probes.resp_pre = ue.location(p) else probes.resp_pre = nil end
    end, function(ctx)
        local before = probes.resp_pre
        probes.resp_pre = nil
        local p = ctx and ctx:get()
        if not before or not p then return end
        local l = ue.location(p)
        if not l then return end
        local dx, dy, dz = l.X - before.X, l.Y - before.Y, l.Z - before.Z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        local r = probes.resp
        r.n = r.n + 1
        if d > 0.5 then
            r.moved = r.moved + 1
            r.sum = r.sum + d
            if d > r.max then r.max = d end
        end
    end)
    if not okr then log.debug("probe: cannot hook ClientMoveResponsePacked: %s", tostring(errr)) end
    log.info("probe: motion probes installed")
end

function M.probe_report()
    local now = os.time()
    if now - probes.last_log < 5 then return end
    probes.last_log = now
    local r = probes.resp
    if r.n > 0 then
        log.info("probe: server move responses=%d, moved the character in %d (avg %.1f cm, max %.1f cm)",
            r.n, r.moved, r.moved > 0 and r.sum / r.moved or 0, r.max)
        probes.resp = { n = 0, moved = 0, sum = 0, max = 0 }
    end
    if next(probes.counts) == nil then return end
    local parts = {}
    for k, v in pairs(probes.counts) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    log.info("probe: %s", table.concat(parts, " "))
    probes.counts = {}
end

-- A character spawned while the host's save is still being restored gets
-- MOVE_None (movement off: hanging in the air, WASD ignored) and the game
-- re-enables it only for player 0. Within the first 30 s after a pawn
-- appears, MOVE_None is switched to Falling (it lands and walks). Later
-- MOVE_None is left alone (vehicles, death, cutscenes use it).
local MOVE_NONE, MOVE_FALLING = 0, 3
local unstuck = {}
function M.unstick(pawn, since, tag)
    if not ue.valid(pawn) or not since or os.time() - since > 30 then return end
    local cmc = ue.prop(pawn, "CharacterMovement")
    if not ue.valid(cmc) or ue.prop(cmc, "MovementMode") ~= MOVE_NONE then return end
    -- seated in a vehicle (attached; the game's VehicleInteraction disabled movement)
    if ue.valid(ue.try(function() return pawn:GetAttachParentActor() end)) then return end
    local ok = pcall(function() cmc:SetMovementMode(MOVE_FALLING, 0) end)
    local key = ue.name(pawn)
    if not unstuck[key] then
        unstuck[key] = true
        log.info("movement: %s %s spawned with movement disabled (MOVE_None), switched to falling (ok=%s)",
            tag, ue.short(pawn), tostring(ok))
    end
end

-- Client: remote players (simulated proxies) need network smoothing,
-- otherwise they visibly hop between replication updates.
local SMOOTH_DISABLED, SMOOTH_EXPONENTIAL = 0, 2
local smoothing_done = {}
function M.client_smoothing_tick()
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        local key = ue.valid(p) and ue.name(p)
        if key and not smoothing_done[key] and ue.role(p) == ue.ROLE_SIMULATED then
            local cmc = ue.prop(p, "CharacterMovement")
            if ue.valid(cmc) then
                smoothing_done[key] = true
                local mode = ue.prop(cmc, "NetworkSmoothingMode")
                if mode == SMOOTH_DISABLED then
                    local ok = ue.set_prop(cmc, "NetworkSmoothingMode", SMOOTH_EXPONENTIAL)
                    log.info("movement: smoothing on for remote %s (was disabled, ok=%s)", ue.short(p), tostring(ok))
                else
                    log.info("movement: remote %s smoothing mode=%s", ue.short(p), tostring(mode))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Movement jitter monitor (client, debug only)
-- ---------------------------------------------------------------------------
-- Samples, every frame, the client's character: on the client its own one,
-- on the host every remote player's one. Tracks the actor location and the
-- mesh location (what you actually see, network smoothing included) and
-- counts back-steps (motion against the previous frame's direction) and
-- speed spikes. Also logs this window's frame rate, since a throttled
-- background window (two copies on one PC) makes remote players hop.

M.monitor_pawns = {}   -- host: remote players' pawns, set by the session tick

local mon_state = {}
local fps = { frames = 0, start = nil }

-- Live experiments (debug): Mods/SDCoop/experiment.txt is read every 2 s; when
-- it changes, its lines are applied once, so settings can be switched while a
-- tester keeps running and the movement monitor shows the effect per window.
--   exec <console command>
--   cmc <property> = <value>    host: remote players' CharacterMovement; client: own
--   pawn <property> = <value>   same targets, on the character itself
local exp_state = { text = nil }

local function exp_value(v)
    if v == "true" then return true end
    if v == "false" then return false end
    return tonumber(v) or v
end

function M.experiment_tick(mod_dir, role)
    if not mod_dir then return end
    local f = io.open(mod_dir .. "/experiment.txt", "r")
    if not f then return end
    local text = f:read("a")
    f:close()
    if text == exp_state.text then return end
    exp_state.text = text
    local targets = {}
    if role == "host" then
        for _, pc in ipairs(M.remote_pcs or {}) do
            local p = ue.pawn_of(pc)
            if p then targets[#targets + 1] = p end
        end
    else
        local p = ue.local_pawn()
        if p then targets[#targets + 1] = p end
    end
    log.info("experiment: file changed, %d target character(s)", #targets)
    -- loops not mentioned in the file are on
    local loops_off = {}
    -- "comprep on": give player characters' capsule / mesh back the game's
    -- own replication (default: off, see component_replication)
    M.capsule_rep_wanted = text:match("\ncomprep%s+on") ~= nil or text:match("^comprep%s+on") ~= nil
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        local lname, lstate = line:match("^loop%s+(%S+)%s+(%a+)$")
        if lname and lstate == "off" then loops_off[lname] = true end
        local preset = line:match("^weather%s+([%w_]+)$")
        if preset and role == "host" then
            local w = weather()
            local path = "/Game/UltraDynamicSky/Blueprints/Weather_Effects/Weather_Presets/" .. preset .. "." .. preset
            local obj = ue.find_object(path)
            if not ue.valid(obj) then
                local okl, loaded = ue.load_asset(path, "sync")
                obj = okl and ue.valid(loaded) and loaded or nil
            end
            local okw = w and obj and ue.call(w, "Change Weather", obj, 10.0)
            log.info("experiment: weather -> %s (preset %s, ok=%s)", preset, obj and "found" or "missing", tostring(okw))
        end
        local cmd = line:match("^exec%s+(.+)$")
        if cmd then
            ue.exec(cmd)
            local name = cmd:match("^(%S+)")
            local ksl = ue.ksl()
            local now = ksl and ue.try(function() return ksl:GetConsoleVariableFloatValue(name) end)
            log.info("experiment: exec '%s' (now %s)", cmd, tostring(now))
        end
        local kind, prop, val = line:match("^(%a+)%s+([%w_%?]+)%s*=%s*(%S+)$")
        if (kind == "cmc" or kind == "pawn") and prop then
            for _, p in ipairs(targets) do
                local obj = kind == "cmc" and ue.prop(p, "CharacterMovement") or p
                local before = ue.prop(obj, prop)
                ue.set_prop(obj, prop, exp_value(val))
                log.info("experiment: %s %s.%s %s -> %s", ue.short(p), kind, prop, tostring(before), tostring(ue.prop(obj, prop)))
            end
        end
    end
    local names = {}
    for k in pairs(loops_off) do names[#names + 1] = k end
    ue.disabled_loops = loops_off
    log.info("experiment: loops off: [%s]", table.concat(names, " "))
end

-- Jitter trace (debug, own character, once per session): 150 consecutive
-- frames once it runs, with the position also sampled inside the
-- character's own tick (ReceiveTick) and the camera position.
local jt = { done = false, rows = nil, tick = nil, hooked = false }

local function jt_hook()
    if jt.hooked then return end
    jt.hooked = true
    local ok, err = pcall(RegisterHook, "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:ReceiveTick", function(c)
        if jt.done or not jt.rows then return end
        local p = c and c:get()
        local me = ue.local_pawn()
        if p and me and addr(p) == addr(me) then jt.tick = ue.location(p) end
    end)
    log.info("jitter trace hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

local function jt_frame(pawn, t, p)
    if jt.done or not p then return end
    local v = ue.try(function() return pawn:GetVelocity() end)
    local vx, vy = v and ue.try(function() return v.X end) or 0, v and ue.try(function() return v.Y end) or 0
    local speed = math.sqrt(vx * vx + vy * vy)
    if not jt.rows then
        if speed < 300 then return end
        jt.rows = {}
        jt_hook()
    end
    local pc = ue.local_pc()
    local cam = ue.try(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local tk = jt.tick
    jt.tick = nil
    jt.rows[#jt.rows + 1] = string.format("%.4f %.4f pos=%.2f,%.2f v=%.0f,%.0f tick=%s cam=%s",
        t, os.clock(), p.X, p.Y, vx, vy,
        tk and string.format("%.2f,%.2f", tk.X, tk.Y) or "-",
        cam and ue.try(function() return string.format("%.2f,%.2f", cam.X, cam.Y) end) or "-")
    if #jt.rows >= 150 then
        jt.done = true
        log.info("jitter trace: %d frames (time, clock, actor pos, velocity, pos in own tick, camera)", #jt.rows)
        for i, r in ipairs(jt.rows) do log.info("jt %03d %s", i, r) end
        jt.rows = nil
    end
end

local function track(st, p, t)
    if st.prev and t > st.t_prev then
        local d = { p.X - st.prev.X, p.Y - st.prev.Y }
        local len = math.sqrt(d[1] * d[1] + d[2] * d[2])
        local speed = len / (t - st.t_prev)
        if len > 0.3 then
            st.frames = st.frames + 1
            st.dist = st.dist + len
            local reversed = st.prev_d and (d[1] * st.prev_d[1] + d[2] * st.prev_d[2]) < 0
            if reversed then st.back = st.back + 1 end
            -- zigzag: forward, back, forward on consecutive frames (twitching,
            -- as opposed to sliding off a slope)
            if reversed and st.prev_reversed then st.zig = (st.zig or 0) + 1 end
            if reversed and st.detail and st.detail_left > 0 then
                st.detail_left = st.detail_left - 1
                st.detail(d, st.prev_d, t - st.t_prev)
            end
            st.prev_reversed = reversed
            if st.ema > 50 and speed > st.ema * 2.5 then st.spikes = st.spikes + 1 end
            st.ema = st.ema == 0 and speed or (st.ema * 0.9 + speed * 0.1)
            st.prev_d = d
        end
    end
    st.prev, st.t_prev = p, t
end

local function new_track() return { frames = 0, back = 0, spikes = 0, dist = 0, ema = 0 } end

function M.movement_monitor_frame()
    if not log.probes_enabled then return end
    local gps, ctx = ue.gameplay_statics(), ue.world_context()
    local t = gps and ctx and ue.try(function() return gps:GetTimeSeconds(ctx) end)
    if type(t) ~= "number" then return end

    fps.frames = fps.frames + 1
    fps.start = fps.start or t
    if t - fps.start >= 10 then
        log.info("perf: %.0f fps (role %s)", fps.frames / (t - fps.start), tostring(ue.net_role()))
        fps.frames, fps.start = 0, t
    end

    local targets = {}
    local own = ue.local_pawn()
    if own then targets[#targets + 1] = own end
    for _, p in ipairs(M.monitor_pawns) do
        if ue.valid(p) then targets[#targets + 1] = p end
    end

    for _, pawn in ipairs(targets) do
        local key = ue.name(pawn)
        local st = mon_state[key]
        if not st then
            st = { actor = new_track(), mesh = new_track(), start = t }
            mon_state[key] = st
            if ue.role(pawn) == ue.ROLE_AUTONOMOUS then
                -- first reversals of the client's own character, with what drives the movement
                st.actor.detail_left = 40
                st.actor.detail = function(d, pd, dt)
                    local v = ue.try(function() return pawn:GetVelocity() end)
                    local cmc = ue.prop(pawn, "CharacterMovement")
                    local acc = ue.valid(cmc) and ue.try(function() return cmc:GetCurrentAcceleration() end)
                    local rot = ue.rotation(pawn)
                    local function xy(vec)
                        if not vec then return "?" end
                        local x, y = ue.try(function() return vec.X end), ue.try(function() return vec.Y end)
                        if type(x) ~= "number" then return "?" end
                        return string.format("%.1f,%.1f", x, y)
                    end
                    log.info("zig: dt=%.4f d=%.2f,%.2f prev=%.2f,%.2f vel=%s acc=%s mode=%s maxspeed=%s yaw=%.1f since_send=%.3f",
                        dt, d[1], d[2], pd[1], pd[2], xy(v), xy(acc),
                        tostring(ue.valid(cmc) and ue.prop(cmc, "MovementMode")),
                        tostring(ue.valid(cmc) and ue.prop(cmc, "MaxWalkSpeed")), rot.Yaw,
                        probes.last_send and (os.clock() - probes.last_send) or -1)
                end
            end
        end
        local p = ue.location(pawn)
        local mesh = ue.prop(pawn, "Mesh")
        local ml = ue.valid(mesh) and ue.try(function() return mesh:K2_GetComponentLocation() end)
        if p then track(st.actor, p, t) end
        if p and own and addr(pawn) == addr(own) and ue.role(pawn) == ue.ROLE_AUTONOMOUS then
            pcall(jt_frame, pawn, t, p)
        end
        if ml then
            local x, y = ue.try(function() return ml.X end), ue.try(function() return ml.Y end)
            if type(x) == "number" and type(y) == "number" then track(st.mesh, { X = x, Y = y }, t) end
        end
        if t - st.start >= 5 then
            local a, m = st.actor, st.mesh
            if a.dist > 100 then
                local kind = (pawn == own) and (ue.role(pawn) == ue.ROLE_AUTONOMOUS and "own-client" or "own-host") or "remote"
                log.info("move: %s %s dist=%.0f frames=%d | actor back=%d zig=%d spikes=%d | mesh back=%d zig=%d spikes=%d | speed=%.0f",
                    kind, ue.short(pawn), a.dist, a.frames, a.back, a.zig or 0, a.spikes,
                    m.back, m.zig or 0, m.spikes, a.ema)
            end
            for _, s in ipairs({ a, m }) do s.frames, s.back, s.spikes, s.dist, s.zig = 0, 0, 0, 0, 0 end
            st.start = t
        end
    end
end

return M
