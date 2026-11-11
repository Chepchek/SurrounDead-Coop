-- SDCoop: the vehicle radio in co-op (config vehicle_radio, under vehicle_sync).
-- Part of the vehicle sync: sdc_vehicles passes its pieces in (attach) and
-- runs this module's tick, message handlers and reset.
--
-- How the game's radio works (work\re\pseudo_radio: RadioComponent_C,
-- RadioUI_C; work\re\pseudo: BP_VehicleMaster_C, VehicleDrivingComponent_C):
--   * every BP_VehicleMaster_C has a RadioComponent (RadioComponent_C,
--     "Vehicle Radio") and a MediaSound (MediaSoundComponent: spatialised,
--     attenuation /Game/Audio/Attenuation/PlayerRadio - 10 m, then 50 m of
--     falloff -, sound class RadioMusicAudio, not auto-activated).
--   * the music is the player's own files: the component's BeginPlay (+0.2 s)
--     lists <game folder>\Radio (BlueprintFileUtils FindFiles -> "Found
--     Files") and spawns a looping MediaPlayer (PlayOnOpen). Each machine
--     lists its own folder: a track plays on another machine only if the same
--     file is in that machine's Radio folder.
--   * IA_VehicleRadio (seated, inventory closed; VehicleDrivingComponent
--     @2270) -> RadioComponent.ToggleRadioUI(false): the RadioUI window on
--     that machine's screen. Play: StartRadio (TurnedOn?, Paused? off, a
--     random CurrentSong) + Event_PlayCurrentRadioSong (MediaPlayer.OpenUrl
--     "file://<game>/Radio/<CurrentSong>", MediaSound on, Play when ready);
--     when paused: Paused? off + MediaPlayer.Play. Pause: Paused? on +
--     MediaPlayer.Pause. Next: ShuffleRadioSongs (another CurrentSong +
--     Event_PlayCurrentRadioSong). Previous: PreviousRadioSong
--     (MediaPlayer.OpenFile <game>/Radio/<PreviousSong>; CurrentSong stays).
--     Volume slider (0..1): Volume + MediaSound.SetVolumeMultiplier. Speed
--     slider (0.5..3): MediaPlayer.SetRate + PlayRate. Getting out only closes
--     the window (ToggleRadioUI(true)): the music goes on. StopRadio (off)
--     exists; the vehicle's window never calls it.
--   * none of it replicates: it all happens on the machine whose window was
--     used, on its own copy of the vehicle.
--
-- What this module does (host-authoritative, as the rest of the vehicle sync):
--   * the machine whose player sits in a vehicle reads that vehicle's radio
--     every vehicle tick (0.5 s): on, the track its MediaPlayer opened (the
--     URL), paused, volume, speed. A change made there goes out: a client's to
--     the host (VRADIO), the host's to every client.
--   * the host keeps each vehicle's radio state (the last change of a seated
--     player, or a radio found playing on its copy), applies a client's change
--     on its copy, passes it to the other clients, sends it to a client that
--     joins (VRADIOQ) or sits down in that vehicle, and repeats it every 10 s
--     (a vehicle that comes back into a client's view).
--   * applying = the game's own functions on that machine's copy of the
--     vehicle (StartRadio + CurrentSong + Event_PlayCurrentRadioSong;
--     StopRadio; Paused? + MediaPlayer.Pause / Play; Volume + MediaSound.
--     SetVolumeMultiplier; MediaPlayer.SetRate + PlayRate): the sound comes
--     from that vehicle with the game's attenuation. A track missing from this
--     machine's Radio folder: one of its own tracks plays instead (always the
--     same one for the same missing track), with a one-time note on screen. A
--     copy that starts a track late (join, the vehicle came into view) jumps
--     to the sender's position in it (MediaPlayer.Seek).
--
-- VRADIO|x|y|z|class|on|paused|volume|speed|position s (-1 = unknown)|track
--   client -> host: a seated player's change; host -> client: the state.
-- VRADIOQ: client -> host once it is in the session: "send me every radio".
--
-- Rules: no UObject is kept between ticks (vehicles by address + short name,
-- looked up again); every engine call is pcall-ed.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = {
    stats = { sent = 0, applied = 0, relayed = 0, refused = 0, missing = 0, seeks = 0 },
}

local api = nil   -- sdc_vehicles' pieces (M.attach)

local REFRESH_S = 10      -- host: every known radio state again
local SCAN_S = 5          -- host: radios found playing on its copies
local LOCAL_WINS_S = 2    -- client: a host state this soon after our own change is older than it
local PENDING_S = 6       -- s: waiting for an opened track to play (seek, speed, pause after it)
local SEEK_MIN_S = 3      -- s: a smaller position is not worth a jump
local FILES_S = 60        -- s: Found Files read again
local HEAR_CM = 6000      -- PlayerRadio: 10 m + 50 m falloff (the on-screen note only near the vehicle)
local VOL_MIN, VOL_MAX = 0, 1          -- RadioUI VolumeSlider
local RATE_MIN, RATE_MAX = 0.5, 3      -- RadioUI SpeedSlider

local TEXT = {
    veh_radio_missing = { "Vehicle radio: \"%s\" is not in your Radio folder; your \"%s\" plays instead.",
                          "Радио в машине: трека «%s» нет в вашей папке Radio — вместо него играет ваш «%s»." },
    veh_radio_empty   = { "Vehicle radio: another player plays \"%s\", but your Radio folder (in the game folder) has no music.",
                          "Радио в машине: другой игрок включил «%s», но в вашей папке Radio (в папке игры) нет музыки." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end

-- rad[vehicle address] = { name, last = this copy as read after our own
--   apply / the last poll, sig = the state applied or sent from here,
--   local_at = this machine's own change, pend = { song, pos, at, rate,
--   paused, till } while an opened track has not started }
local rad = {}
-- host: want[vehicle address] = { name, st, at }: the vehicle's radio state
local want = {}
local host = { refresh_at = -100, scan_at = -100, seen_seat = {} }
local client = { asked = false, nocap_logged = false }
local said = {}
local files = { set = {}, lower = {}, sorted = {}, n = -1, at = -100 }

local function on() return cfg.get("vehicle_radio") ~= false end

local function num(v)
    if type(v) == "number" then return v end
    return tonumber(v)
end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function b(x) return x and "1" or "0" end

-- What a change is: on, paused, track, volume, speed (not the position; an
-- off radio has no track or pause).
local function sig(st)
    return string.format("%s|%s|%s|%.2f|%.2f", b(st.on), b(st.on and st.paused), st.on and (st.song or ""):lower() or "",
        st.vol or 0.5, st.rate or 1)
end

local function describe(st)
    if not st.on then return "off" end
    return string.format("%s \"%s\", volume %d%%, speed x%.2f", st.paused and "paused on" or "playing", tostring(st.song),
        math.floor((st.vol or 0) * 100 + 0.5), st.rate or 1)
end

local function rad_of(a, v)
    local r = rad[a]
    local name = ue.short(v)
    if not r or r.name ~= name then
        r = { name = name }
        rad[a] = r
    end
    return r
end

-- ---------------------------------------------------------------------------
-- The game's radio pieces on this machine's copy of a vehicle
-- ---------------------------------------------------------------------------

local function parts(v)
    local rc = ue.prop(v, "RadioComponent")
    if not ue.valid(rc) then return nil end
    local mp = ue.prop(rc, "MediaPlayer")
    if not ue.valid(mp) then mp = nil end
    local ms = ue.prop(rc, "MediaSound")
    if not ue.valid(ms) then ms = ue.prop(v, "MediaSound") end
    if not ue.valid(ms) then ms = nil end
    return rc, mp, ms
end

local function pct_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- This machine's Radio folder as the game listed it (every vehicle's radio
-- lists the same folder; one that has not listed it yet - 0.2 s after its
-- BeginPlay - leaves the last list).
local function file_list(rc)
    local arr = ue.prop(rc, "Found Files")
    local n = arr and num(ue.try(function() return arr:GetArrayNum() end)) or 0
    local t = os.clock()
    if n > 0 and (n ~= files.n or t - files.at > FILES_S) then
        local set, lower, sorted = {}, {}, {}
        pcall(function()
            arr:ForEach(function(_, el)
                local s = ue.str(el:get())
                if s ~= "" and not set[s] then
                    set[s] = true
                    lower[s:lower()] = s
                    sorted[#sorted + 1] = s
                end
            end)
        end)
        table.sort(sorted)
        files.set, files.lower, files.sorted, files.n, files.at = set, lower, sorted, n, t
    end
    return files
end

-- The track a MediaPlayer URL names ("file://<game>/Radio/<file>"; OpenFile
-- gives the same with the full path).
local function song_of(url, rc, fl)
    local seg = url:match("([^/\\]+)$")
    if seg and seg ~= "" then
        if fl.set[seg] then return seg end
        local d = pct_decode(seg)
        if fl.lower[d:lower()] then return fl.lower[d:lower()] end
        return d
    end
    return ue.str(ue.prop(rc, "CurrentSong"))
end

local function seconds(ts)
    local ticks = ts ~= nil and num(ue.try(function() return ts.Ticks end)) or nil
    if ticks then return ticks / 1e7 end
    return nil
end

-- This copy's radio: { on, paused, song, vol, rate, pos }, rc, mp, ms.
-- Paused: the MediaPlayer's own state (Next / Previous while paused play the
-- new track and leave Paused? set). The speed is the MediaPlayer's while it
-- plays (Next / Previous play at 1 and leave PlayRate as it was); else the
-- last one read.
local function read(v, prev)
    local rc, mp, ms = parts(v)
    if not rc then return nil end
    local fl = file_list(rc)
    local st = {
        on = ue.prop(rc, "TurnedOn?") == true,
        vol = num(ue.prop(rc, "Volume")) or 0.5,
        rate = prev and prev.rate or 1,
        pos = -1,
    }
    if mp then
        st.paused = ue.try(function() return mp:IsPaused() end) == true
    else
        st.paused = ue.prop(rc, "Paused?") == true
    end
    local url = mp and ue.fstring(ue.try(function() return mp:GetUrl() end)) or ""
    st.song = song_of(url, rc, fl)
    if mp and ue.try(function() return mp:IsPlaying() end) == true then
        local r = num(ue.try(function() return mp:GetRate() end))
        if r and r > 0 then st.rate = r end
    elseif prev and (prev.song or "") ~= st.song then
        st.rate = 1   -- a track still opening: the game's Play() runs it at 1
    end
    if mp and url ~= "" then st.pos = seconds(ue.try(function() return mp:GetTime() end)) or -1 end
    return st, rc, mp, ms
end

local function set_song(rc, song)
    ue.set_prop(rc, "CurrentSong", song)
    if ue.str(ue.prop(rc, "CurrentSong")) == song then return true end
    local k = ue.ksl()
    if k then pcall(function() k:SetStringPropertyByName(rc, FName("CurrentSong"), song) end) end
    return ue.str(ue.prop(rc, "CurrentSong")) == song
end

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end

-- The file of this machine to play for `song`: the same file (any case), or
-- one of its own (the same one for the same song), or nil.
local function local_track(fl, song)
    if song == "" then return nil, "none" end
    if fl.set[song] then return song, "same" end
    local low = fl.lower[song:lower()] or fl.lower[pct_decode(song):lower()]
    if low then return low, "same" end
    if #fl.sorted == 0 then return nil, "empty" end
    return fl.sorted[hash(song:lower()) % #fl.sorted + 1], "other"
end

local function near(v)
    local lp = ue.local_pawn()
    local p, q = lp and ue.location(lp), ue.location(v)
    if not (p and q) then return false end
    local dx, dy, dz = p.X - q.X, p.Y - q.Y, p.Z - q.Z
    return dx * dx + dy * dy + dz * dz <= HEAR_CM * HEAR_CM
end

local function note(key, v, ...)
    if said[key] or not near(v) then return end
    said[key] = true
    log.say(key, "info", 8, ...)
end

-- The radio window open on this screen shows the applied state.
local function ui_refresh(rc, song, st)
    local ui = ue.prop(rc, "RadioUI")
    if not ue.valid(ui) then return end
    if song then pcall(function() ui:SetCurrentSong(song) end) end
    local vs, vt = ue.prop(ui, "VolumeSlider"), ue.prop(ui, "Volume")
    local ss, sp = ue.prop(ui, "SpeedSlider"), ue.prop(ui, "Speed")
    if ue.valid(vs) then pcall(function() vs:SetValue(st.vol) end) end
    if ue.valid(vt) then pcall(function() vt:SetText(FText(string.format("%d%%", math.floor(st.vol * 100 + 0.5)))) end) end
    if ue.valid(ss) then pcall(function() ss:SetValue(st.rate) end) end
    if ue.valid(sp) then pcall(function() sp:SetText(FText(string.format("x%.1f", st.rate))) end) end
end

-- Applies `st` (another machine's state) on this machine's copy `v`.
-- Returns the text of what was done, or nil, why not.
local function apply_state(v, a, st)
    local r = rad_of(a, v)
    local cur, rc, mp, ms = read(v, r.last)
    if not cur then return nil, "no RadioComponent on this copy" end
    local t = os.clock()
    local did = {}
    local song = nil
    if not st.on then
        r.pend = nil
        if cur.on then
            local ok = pcall(function() rc:StopRadio() end)
            did[#did + 1] = ok and "turned off (StopRadio)" or "StopRadio FAILED"
        else
            did[#did + 1] = "already off here"
        end
    else
        local fl = file_list(rc)
        local track, how = local_track(fl, st.song or "")
        song = track
        if how == "other" then note("veh_radio_missing", v, st.song, track) end
        if not track then
            -- nothing this machine can play (counted as applied: the host's
            -- 10 s repeat does not try it again)
            r.pend = nil
            if how == "empty" then
                M.stats.missing = M.stats.missing + 1
                note("veh_radio_empty", v, st.song)
                did[#did + 1] = "nothing played: no music in this machine's Radio folder"
            else
                did[#did + 1] = "nothing played: the sender names no track"
            end
        elseif not cur.on or (cur.song or ""):lower() ~= track:lower() then
            if how == "other" then M.stats.missing = M.stats.missing + 1 end
            if not mp then return nil, "its MediaPlayer does not exist yet" end
            pcall(function() rc:StartRadio() end)
            local named = set_song(rc, track)
            local ok, err = pcall(function() rc:Event_PlayCurrentRadioSong() end)
            if not ok then return nil, "Event_PlayCurrentRadioSong failed: " .. tostring(err) end
            r.pend = { song = track, pos = st.pos, at = t, rate = st.rate, paused = st.paused, till = t + PENDING_S }
            did[#did + 1] = string.format("%s \"%s\"%s (StartRadio + Event_PlayCurrentRadioSong%s)",
                cur.on and "switched to" or "turned on with", track,
                how == "other" and " - the sender's track is not in this machine's Radio folder" or "",
                named and "" or "; CurrentSong NOT set")
        elseif r.pend and r.pend.song:lower() == track:lower() and ue.try(function() return mp:IsPlaying() end) ~= true then
            -- that track is still opening here: speed / pause / position once it plays
            r.pend.rate, r.pend.paused = st.rate, st.paused
            if (st.pos or -1) >= 0 then r.pend.pos, r.pend.at = st.pos, t end
            did[#did + 1] = "its track is still opening here: speed / pause / position set for when it plays"
        else
            r.pend = nil
            local now_rate = cur.rate or 1
            if st.paused and not cur.paused then
                ue.set_prop(rc, "Paused?", true)
                pcall(function() mp:Pause() end)
                did[#did + 1] = "paused"
            elseif not st.paused and cur.paused then
                -- the window's resume (@61); Play() runs at speed 1
                ue.set_prop(rc, "Paused?", false)
                pcall(function() mp:Play() end)
                now_rate = 1
                did[#did + 1] = "resumed"
            end
            if not st.paused and math.abs((st.rate or 1) - now_rate) > 0.01 then
                pcall(function() mp:SetRate(st.rate) end)
                ue.set_prop(rc, "PlayRate", st.rate)
                did[#did + 1] = string.format("speed x%.2f", st.rate)
            end
        end
        -- always: the multiplier stays 1.0 until this machine's own window set it
        if math.abs((cur.vol or 0) - st.vol) > 0.005 then did[#did + 1] = string.format("volume %d%%", math.floor(st.vol * 100 + 0.5)) end
        ue.set_prop(rc, "Volume", st.vol)
        if ms then pcall(function() ms:SetVolumeMultiplier(st.vol) end) end
    end
    ui_refresh(rc, song, st)
    r.last = read(v, r.last)
    M.stats.applied = M.stats.applied + 1
    if #did == 0 then did[1] = "nothing to change" end
    return table.concat(did, ", ")
end

-- A track opened by apply_state plays now: position, speed, pause.
local function finish(v, r, rc, mp, p, t)
    local did = {}
    if p.pos and p.pos >= SEEK_MIN_S then
        local target = p.pos + (p.paused and 0 or (t - p.at) * (p.rate or 1))
        local dur = seconds(ue.try(function() return mp:GetDuration() end))
        if dur and dur > 1 then target = target % dur end
        local ok = ue.try(function() return mp:Seek({ Ticks = math.floor(target * 1e7) }) end)
        if ok == true then
            M.stats.seeks = M.stats.seeks + 1
            did[#did + 1] = string.format("position %d:%02d (the sender's %.0f s + %.1f s since)",
                math.floor(target / 60), math.floor(target % 60), p.pos, t - p.at)
        else
            did[#did + 1] = string.format("position NOT set (MediaPlayer.Seek gave %s)", tostring(ok))
        end
    end
    if p.rate and math.abs(p.rate - 1) > 0.01 then
        pcall(function() mp:SetRate(p.rate) end)
        ue.set_prop(rc, "PlayRate", p.rate)
        did[#did + 1] = string.format("speed x%.2f", p.rate)
    end
    if p.paused then
        ue.set_prop(rc, "Paused?", true)
        pcall(function() mp:Pause() end)
        did[#did + 1] = "paused"
    end
    r.last = read(v, r.last)
    log.info("vehicles: radio: %s: \"%s\" plays here now%s", r.name, tostring(p.song),
        #did > 0 and (": " .. table.concat(did, ", ")) or "")
end

local function pending_tick(t)
    for a, r in pairs(rad) do
        local p = r.pend
        if p then
            local v = api.vehicle_by(a, r.name)
            local rc, mp
            if v then rc, mp = parts(v) end
            if not (rc and mp) then
                r.pend = nil
            elseif ue.try(function() return mp:IsPlaying() end) == true then
                r.pend = nil
                finish(v, r, rc, mp, p, t)
            elseif t > p.till then
                r.pend = nil
                r.last = read(v, r.last)
                log.warn("vehicles: radio: %s: \"%s\" did not start playing here within %d s (the game's MediaPlayer could not open it?)",
                    r.name, tostring(p.song), PENDING_S)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

local function fields(st)
    return b(st.on), b(st.paused), string.format("%.2f", st.vol or 0.5), string.format("%.2f", st.rate or 1),
        string.format("%.1f", st.pos or -1), st.song or ""
end

local function parse(f)
    return {
        on = f[5] == "1", paused = f[6] == "1",
        vol = clamp(num(f[7]) or 0.5, VOL_MIN, VOL_MAX),
        rate = clamp(num(f[8]) or 1, RATE_MIN, RATE_MAX),
        pos = num(f[9]) or -1,
        song = f[10] or "",
    }
end

local function send_pc(pc, v, st)
    local x, y, z, cls = api.local_pos(v)
    if not x then return false end
    net.send_to(pc, "VRADIO", x, y, z, cls, fields(st))
    M.stats.sent = M.stats.sent + 1
    return true
end

-- Host -> every client but `except` (a pc). Returns how many.
local function broadcast(v, st, except)
    local S = api.S()
    local ea = except and api.addr(except)
    local n = 0
    for _, pc in ipairs(S.remote_pcs or {}) do
        if not ea or api.addr(pc) ~= ea then
            if send_pc(pc, v, st) then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function copy(st)
    local c = {}
    for k, x in pairs(st) do c[k] = x end
    return c
end

-- The vehicle's state as the host sends it now (position: the host's copy
-- when it plays the same track, else the sender's moved on).
local function host_state(v, a, t)
    local w = want[a]
    if not w or w.name ~= ue.short(v) then return nil end
    local st = copy(w.st)
    local r = rad[a]
    local cur = read(v, r and r.last)
    if st.on and cur and cur.on and (cur.song or ""):lower() == (st.song or ""):lower() and (cur.pos or -1) >= 0 then
        st.pos = cur.pos
    elseif st.on and (st.pos or -1) >= 0 then
        st.pos = st.pos + (st.paused and 0 or (t - w.at) * (st.rate or 1))
    else
        st.pos = -1
    end
    return st
end

local function set_want(v, a, st, t)
    want[a] = { name = ue.short(v), st = copy(st), at = t }
end

local function host_msg(f, pc)
    local key = api.sender(pc)
    if not key then return end
    local t = os.clock()
    local st = parse(f)
    local v = api.msg_vehicle(f, pc)
    local who = api.name_of(key)
    if not v then
        log.info("vehicles: radio: %s changed a vehicle radio (%s) but no vehicle of the host is next to its character: not taken",
            who, describe(st))
        return
    end
    local a = api.addr(v)
    local vname = ue.short(v)
    local seat = api.seat_in(key, v)
    if not seat then
        M.stats.refused = M.stats.refused + 1
        local back = host_state(v, a, t)
        if not back then
            local cur = read(v)
            if cur then back = cur end
        end
        if back then send_pc(pc, v, back) end
        log.info("vehicles: radio: %s changed the radio in %s (%s) but sits in no seat there: not taken; the host's state sent back (%s)",
            who, vname, describe(st), back and describe(back) or "no radio on the host's copy")
        return
    end
    set_want(v, a, st, t)
    local did, err = apply_state(v, a, st)
    local r = rad_of(a, v)
    r.sig = sig(st)
    local n = broadcast(v, st, pc)
    M.stats.relayed = M.stats.relayed + n
    log.info("vehicles: radio: %s (%s) changed the radio in %s: %s -> on the host's copy: %s; passed to %d other client(s)",
        who, seat, vname, describe(st), did or ("not applied: " .. tostring(err)), n)
end

-- A radio the host's copy plays that the host has no state for yet (turned on
-- before a client joined, or the host sits in it): it is the vehicle's state.
local function adopt(v, a, st, t, why)
    set_want(v, a, st, t)
    local r = rad_of(a, v)
    r.sig = sig(st)
    local n = broadcast(v, st, nil)
    log.info("vehicles: radio: %s: %s (%s) -> sent to %d client(s)", ue.short(v), describe(st), why, n)
end

local function host_scan(t)
    for _, v in ipairs(api.list()) do
        if ue.valid(v) then
            local a = api.addr(v)
            local w = a and want[a]
            if a and (not w or w.name ~= ue.short(v)) then
                local rc = ue.prop(v, "RadioComponent")
                if ue.valid(rc) and ue.prop(rc, "TurnedOn?") == true then
                    local r = rad_of(a, v)
                    local st = read(v, r.last)
                    if st then
                        r.last = st
                        adopt(v, a, st, t, "found playing on the host's copy")
                    end
                end
            end
        end
    end
end

local function host_refresh(t)
    for a, w in pairs(want) do
        local v = api.vehicle_by(a, w.name)
        if v then
            local st = host_state(v, a, t)
            if st then broadcast(v, st, nil) end
        else
            want[a] = nil
        end
    end
end

-- A client that just sat down in a vehicle gets its radio state at once.
local function host_seats(t)
    local seats = api.seats()
    for key, s in pairs(seats) do
        if host.seen_seat[key] ~= s.vaddr then
            host.seen_seat[key] = s.vaddr
            local w = want[s.vaddr]
            local pc = w and api.remote_pc_of(key)
            local v = pc and api.vehicle_by(s.vaddr, s.vname)
            local st = v and host_state(v, s.vaddr, t)
            if st and send_pc(pc, v, st) then
                log.info("vehicles: radio: %s sits in %s: its radio state sent (%s)", api.name_of(key), s.vname, describe(st))
            end
        end
    end
    for key in pairs(host.seen_seat) do
        if not seats[key] then host.seen_seat[key] = nil end
    end
end

local function on_query(_, pc)
    if not api or not on() then return end
    local S = api.S()
    if not S or S.role ~= "host" then return end
    local key = api.sender(pc)
    if not key then return end
    local t = os.clock()
    host_scan(t)
    local n, list = 0, {}
    for a, w in pairs(want) do
        local v = api.vehicle_by(a, w.name)
        local st = v and host_state(v, a, t)
        if st and send_pc(pc, v, st) then
            n = n + 1
            list[#list + 1] = w.name .. ": " .. describe(st)
        end
    end
    log.info("vehicles: radio: %s is in the session: %d vehicle radio state(s) sent%s", api.name_of(key), n,
        n > 0 and (" (" .. table.concat(list, "; ") .. ")") or "")
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function client_msg(f)
    if not api.client_ready() then return end
    local st = parse(f)
    local v = api.vehicle_at(num(f[1]), num(f[2]), num(f[3]), f[4], api.MATCH_M)
    if not v then
        log.debug("vehicles: radio: the host's radio state (%s) names a vehicle not here at %s,%s,%s", describe(st),
            tostring(f[1]), tostring(f[2]), tostring(f[3]))
        return
    end
    local a = api.addr(v)
    local r = rad_of(a, v)
    local t = os.clock()
    if r.local_at and t - r.local_at < LOCAL_WINS_S then
        log.info("vehicles: radio: the host's radio state for %s (%s) skipped: this player changed it %.1f s ago (that change is on its way to the host)",
            r.name, describe(st), t - r.local_at)
        return
    end
    local s = sig(st)
    if r.sig == s then return end   -- applied already (the host's 10 s repeat)
    local did, err = apply_state(v, a, st)
    if did then r.sig = s end
    log.info("vehicles: radio: the host's radio state for %s: %s -> %s", r.name, describe(st),
        did or ("not applied: " .. tostring(err)))
end

-- ---------------------------------------------------------------------------
-- This machine's player in a seat: its own changes
-- ---------------------------------------------------------------------------

local function local_change(v, a, r, st, before, t, role)
    r.sig = sig(st)
    local what = string.format("%s (was %s)", describe(st), describe(before))
    if role == "host" then
        set_want(v, a, st, t)
        local n = broadcast(v, st, nil)
        log.info("vehicles: radio: the host changed the radio in %s: %s -> sent to %d client(s)", r.name, what, n)
        return
    end
    r.local_at = t
    if not api.host_cap() then
        if not client.nocap_logged then
            client.nocap_logged = true
            log.info("vehicles: radio: this player changed the radio in %s (%s); not sent: the host runs no vehicle sync", r.name, what)
        end
        return
    end
    local x, y, z, cls = api.local_pos(v)
    local ok = x ~= nil and net.send_to_host("VRADIO", x, y, z, cls, fields(st))
    if ok then M.stats.sent = M.stats.sent + 1 end
    log.info("vehicles: radio: this player changed the radio in %s: %s -> %s", r.name, what,
        ok and "sent to the host" or "NOT sent (no connection)")
end

local function poll(t, role)
    local v = api.local_vehicle()
    if not v then return end
    local a = api.addr(v)
    if not a then return end
    local r = rad_of(a, v)
    if r.pend then return end   -- our own apply is still opening its track
    local st = read(v, r.last)
    if not st then return end
    if not r.last then
        r.last = st
        local w = want[a]
        if role == "host" and st.on and (not w or w.name ~= r.name) then
            adopt(v, a, st, t, "the radio of the vehicle the host sits in")
        end
        return
    end
    local before = r.last
    r.last = st
    if sig(st) ~= sig(before) then local_change(v, a, r, st, before, t, role) end
end

-- ---------------------------------------------------------------------------
-- Tick, reset, wiring
-- ---------------------------------------------------------------------------

local function tick(role)
    local S = api.S()
    if not S then return end
    local t = os.clock()
    if role == "host" then
        if #(S.remote_pcs or {}) == 0 then return end
        pending_tick(t)
        poll(t, "host")
        host_seats(t)
        if t - host.scan_at >= SCAN_S then
            host.scan_at = t
            host_scan(t)
        end
        if t - host.refresh_at >= REFRESH_S then
            host.refresh_at = t
            host_refresh(t)
        end
    elseif role == "client" then
        if not api.client_ready() then return end
        if not client.asked then
            client.asked = true
            local ok = net.send_to_host("VRADIOQ")
            log.info("vehicles: radio: asked the host for the vehicle radios (%s)", ok and "sent" or "NOT sent")
        end
        pending_tick(t)
        poll(t, "client")
    end
end

-- sdc_vehicles' tick (game thread), after its own host / client tick.
function M.tick(role)
    if not api or not on() then return end
    local ok, err = pcall(tick, role)
    if not ok then log.err_throttled("veh.radio", "vehicles: radio: %s", tostring(err)) end
end

-- VRADIO, both ways (as VHORN): role decides.
function M.on_msg(f, pc)
    if not api or not on() then return end
    local S = api.S()
    if not S then return end
    if S.role == "client" then
        client_msg(f)
    elseif S.role == "host" then
        host_msg(f, pc)
    end
end

M.on_query = on_query

function M.reset(why)
    rad, want, said = {}, {}, {}
    host.refresh_at, host.scan_at, host.seen_seat = -100, -100, {}
    client.asked, client.nocap_logged = false, false
    files.set, files.lower, files.sorted, files.n, files.at = {}, {}, {}, -1, -100
    if why then log.debug("vehicles: radio: reset (%s)", tostring(why)) end
end

-- sdc_vehicles.install: its pieces (S, vehicle_at, vehicle_by, list, addr,
-- local_vehicle, local_pos, sender, msg_vehicle, seat_in, seats,
-- remote_pc_of, name_of, client_ready, host_cap, MATCH_M).
function M.attach(pieces)
    api = pieces
end

function M.status()
    local s = M.stats
    local n = 0
    for _ in pairs(want) do n = n + 1 end
    return string.format("radio=%s states=%d sent=%d applied=%d relayed=%d refused=%d missing tracks=%d seeks=%d",
        tostring(on()), n, s.sent, s.applied, s.relayed, s.refused, s.missing, s.seeks)
end

-- Test access (mock harness).
M._t = {
    rad = function() return rad end,
    want = function() return want end,
    files = function() return files end,
}

return M
