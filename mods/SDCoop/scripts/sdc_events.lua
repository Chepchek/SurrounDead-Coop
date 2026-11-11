-- SDCoop: the game's random world events (BP_PrefabSpawner_Dynamic: crashed
-- helicopters, abandoned supply trucks) for every player.
--
-- How the game runs one (work\re\pseudo; the level's spawners decoded from
-- LongdownValley.umap, work\re\extract_level):
--   * BP_EventManager (a level actor, not replicated: every machine runs its
--     own timers) -> SpawnRandomEvent timer (60-3600 s) -> @6302: DaysSurvived
--     > 3, the next shuffled BP_PrefabSpawner_Dynamic_C out of the player's
--     view -> its SpawnRandomEvent (BPI_RandomEvent).
--   * BP_PrefabSpawner.SpawnRandomEvent @672: CheckSurroundingArea -> the
--     Prefab spawned at the spawner (BeginDeferredActorSpawnFromClass +
--     FinishSpawningActor: the prefab's BeginPlay runs inside) -> @15
--     Spawned? = true, SpawnMarker (@1361: Marker? and the CVar
--     Difficulty.RandomEventMarker, default on -> @850 a BP_Marker_C at the
--     spawner with its Marker Texture / Title / Description, Texture Size 3.5,
--     Color 0.51,0.17,0.03: the map marker; BP_Marker registers itself with the
--     minimap) -> @46 SoundOnSpawn with GameplayStatics.PlaySoundAtLocation at
--     the spawner (no attenuation passed: the sound's own). A dynamic event
--     sets no DistanceToPrefab timer: its marker stays.
--   * LongdownValley has 46 dynamic spawners, all Marker? on: 22 crashed
--     helicopters (Prefab_CrashedHelicopter01 x12 / 02 x5, Prefab_CrashedApache01
--     x5; marker "Crashed Military Helicopter" / "Crashed Military Apache",
--     texture Helicopter or ExclamationPointWhite; SoundOnSpawn = the class
--     default explosion_deep_low_1_Cue: attenuation Nuke, 1500 m full volume +
--     2000 m falloff = 3.5 km) and 24 abandoned supply trucks
--     (Prefab_Abandoned*SuppliesTruck_*; marker "Abandoned Truck", texture
--     Jeep, SoundOnSpawn None).
--   * Prefab_CrashedHelicopter01 / 02 / Apache01 ReceiveBeginPlay @10:
--     GameFunctionLibrary.CreateNotificationUI("A helicopter has crashed in
--     The Valley...", no icon, white, 4 s, not forced, the prefab). Their Fire
--     and Smoke particle components are components of the prefab actor.
-- In co-op all of that ran on the host only: the spawner and the marker do
-- not replicate, the sound is a local call, the notice was the host's (a
-- world object's notice: sdc_notes keeps it on the host's screen). A client
-- got the EXPL shake message (sdc_shake: no sound) and the wreck only within
-- the camps' 1 km (sdc_world replicates prefabs). The client's own event
-- manager can roll events of its own (local authority, its own DaysSurvived;
-- not seen in a log yet): sdc_world blocks their spawn (world_prefabs), but
-- the spawner would go on to play its sound - a crash only that player hears.
--
-- Here (config world_events_sync, under world_sync):
--   host   BP_PrefabSpawner.SpawnRandomEvent (post) on a spawner with
--          DynamicEvent? whose Spawned? is set: WEVT|n|prefab class|x,y,z|
--          sound|marker to every client - the sound path only to clients
--          within its range + 5 m (sdc_ownsounds: the cue's own MaxDistance),
--          the marker as the host's BP_Marker shows it; the notice the host's
--          screen showed for the prefab within that call (sdc_notes
--          .shown_since) to every client through sdc_notes (NOTE: the game's
--          widget, the same text); the wreck (sdc_world's replicated prefab)
--          made always relevant like the airdrop and the jets (its mesh, fire
--          and smoke at any distance; its loot / AI parts keep the camps'
--          1 km). A player who joins later gets the events' markers (WEVT|o).
--   client WEVT: the sound (only if in memory - never loaded -, with its own
--          attenuation, only within its range); a BP_Marker_C spawned the
--          spawner's way (deferred, the same properties, finish). A notice
--          the host's wreck raises when it reaches this client later (a join,
--          out of and back into its relevance) is not an event: sdc_notes
--          asks stale_note and takes it off; the event's own (within 60 s of
--          its WEVT) stays and the relayed NOTE is not shown twice.
--          This client's own roll: its spawner's SoundOnSpawn is cleared
--          right after sdc_world blocked the spawn (client_own_roll), so the
--          spawner plays nothing (@46 IsValid fails).
-- Hooks: post only, wrapped in pcall, return nothing; the hook's object is
-- read inside the callback; only paths, numbers and strings are kept.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local notes = require("sdc_notes")

local M = {
    stats = { events = 0, empty = 0, sent = 0, sounds = 0, far = 0, notes = 0, markers_sent = 0, wrecks = 0,
              joiners = 0, got = 0, played = 0, not_played = 0, markers = 0, muted = 0, stale = 0 },
}

local P = {
    hook = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnRandomEvent",
    marker = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_Marker.BP_Marker_C",
}
M.PATHS = P
local NOTE_WINDOW_S = 2.0   -- host: the prefab's notice was shown inside the spawn (same call)
local RECENT_S = 60         -- client: a wreck's notice this soon after the host's event is the event's own
local MATCH_CM = 300        -- the wreck stands at its spawner (the spawner's transform)
local HOOK_RETRY_S = 2
local JOIN_WAIT_S = 5       -- host: a joiner gets the markers this long after its character appeared
local WRECK_TRY_S = 30      -- host: an event's wreck is looked for this long (sdc_world replicates it within 10 s)
local MAX_EVENTS = 64
-- BP_PrefabSpawner @1045 / @1158: the marker's size and colour
local SIZE0 = { X = 3.5, Y = 3.5 }
local COL0 = { R = 0.505208, G = 0.169744, B = 0.034207, A = 1 }

local S = nil
local st = {
    hooked = false, hook_at = -100, hook_logged = false,
    events = {},     -- host: { key, cls, sp, loc, snd, range, att, mk, title, mpath, t, notes, wreck, to = { [pc address] } }
    done = {},       -- host: [spawner path] = true (relayed)
    seen = {},       -- host: [pc address] = clock its character was first seen, or true (joiner snapshot done)
    wreck_at = 0,
    recent = {},     -- client: { cls, loc, t } the host's events
    markers = {},    -- client: [event key] = path of the marker placed here
    pend = {},       -- client: [event key] = { loc, mk } markers waiting for this world's controller
    muted = {},      -- client: [spawner path] = true: own roll, sound cleared
    role = nil,
}
M._st = st

local clock = os.clock

local function on()
    if cfg.get("world_sync") == false then return false end
    return cfg.get("world_events_sync") ~= false
end
local function role() return S and S.role or nil end
local function addr(o) return ue.valid(o) and ctx.addr(o) or nil end

local function loc_str(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function parse_loc(s)
    local x, y, z = tostring(s or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end
local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function esc(s)
    return (tostring(s or ""):gsub("[%%|>\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unesc(s)
    return (tostring(s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function short_path(p) return (tostring(p or ""):gsub("^/Game/", "")) end
local function full_path(p)
    p = tostring(p or "")
    if p == "" or p:sub(1, 1) == "/" then return p end
    return "/Game/" .. p
end
local function asset_name(p) return tostring(p or ""):match("([^%./]+)$") or tostring(p) end
local function line(text) return (tostring(text or ""):gsub("[\r\n]+", " / ")) end
local function snd_mod() return package.loaded["sdc_ownsounds"] or require("sdc_ownsounds") end
local function num(v) return type(v) == "number" and v or nil end
local function text_of(v)
    local s = ue.fstring(v)
    if ue.is_wrapper_text(s) then return "" end
    return s
end

-- ---------------------------------------------------------------------------
-- The map marker on the wire: texture>title>description>sx,sy>r,g,b,a>compass
-- ---------------------------------------------------------------------------

-- Host: the spawner's BP_Marker_C as the host shows it; spec, title.
local function marker_spec(m)
    if not ue.valid(m) then return nil end
    local tex = ue.prop(m, "MarkerTexture")
    local title, desc = text_of(ue.prop(m, "MarkerTitle")), text_of(ue.prop(m, "MarkerDescription"))
    local sz, c = ue.prop(m, "Texture Size"), ue.prop(m, "Color")
    local function f(o, k) return num(ue.try(function() return o[k] end)) end
    local sx, sy = sz and f(sz, "X"), sz and f(sz, "Y")
    local r, g, b, a = c and f(c, "R"), c and f(c, "G"), c and f(c, "B"), c and f(c, "A")
    local spec = table.concat({
        ue.valid(tex) and short_path(ue.path(tex)) or "", esc(title), esc(desc),
        string.format("%.3f,%.3f", sx or SIZE0.X, sy or SIZE0.Y),
        string.format("%.4f,%.4f,%.4f,%.4f", r or COL0.R, g or COL0.G, b or COL0.B, a or COL0.A),
        ue.prop(m, "AddMarkerToCompass?") == true and "1" or "0",
    }, ">")
    return spec, title
end

local function parse_marker(s)
    if type(s) ~= "string" or s == "" then return nil end
    local f = {}
    for part in (s .. ">"):gmatch("(.-)>") do f[#f + 1] = part end
    if #f < 3 then return nil end
    local sx, sy = tostring(f[4] or ""):match("^([%d%.%-]+),([%d%.%-]+)$")
    local r, g, b, a = tostring(f[5] or ""):match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
    return {
        tex = f[1] or "", title = unesc(f[2]), desc = unesc(f[3]),
        size = { X = tonumber(sx) or SIZE0.X, Y = tonumber(sy) or SIZE0.Y },
        col = { R = tonumber(r) or COL0.R, G = tonumber(g) or COL0.G, B = tonumber(b) or COL0.B, A = tonumber(a) or COL0.A },
        compass = f[6] == "1",
    }
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function pc_label(pc)
    local r = S and S.remote and S.remote[ue.name(pc)]
    if type(r) == "table" and type(r.name) == "string" and r.name ~= "" then return r.name end
    return ue.short(pc)
end

local function remote_pcs()
    local out = {}
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        if ue.valid(pc) then out[#out + 1] = pc end
    end
    return out
end

-- WEVT and the notices of one event to one client; sound: send the sound path.
local function send_event(pc, ev, kind, sound)
    local ok = net.send_to(pc, "WEVT", kind, ev.cls, ev.key, sound and short_path(ev.snd) or "", ev.mk or "")
    if not ok then return false, 0 end
    local n = 0
    if kind == "n" then
        for _, nt in ipairs(ev.notes) do
            if notes.show_to(pc, nt.text, nt.icon, nt.col, nt.delay, "the host's random event " .. ev.cls) then n = n + 1 end
        end
    end
    return true, n
end

-- Host: one event to every connected client.
function M.relay(ev)
    local pcs = remote_pcs()
    if #pcs == 0 then
        log.info("events: %s at %s: no client connected; kept for players who join (%s)", ev.cls, ev.key,
            ev.mk and ("its map marker '" .. tostring(ev.title) .. "'") or "no marker to give them")
        return 0
    end
    local snd = snd_mod()
    local near = {}
    if ev.snd ~= "" and ev.range then
        for _, pc in ipairs(snd.pcs_near(pcs, ev.loc, ev.range)) do
            local a = addr(pc)
            if a then near[a] = true end
        end
    end
    local sent, with_sound, nn, far = 0, 0, 0, {}
    for _, pc in ipairs(pcs) do
        local a = addr(pc)
        local sound = a ~= nil and near[a] == true
        local ok, n = send_event(pc, ev, "n", sound)
        if ok then
            sent = sent + 1
            nn = nn + n
            if a then ev.to[a] = true end   -- (reached it: not in its joiner snapshot)
            if sound then
                with_sound = with_sound + 1
            elseif ev.snd ~= "" then
                local l = ue.location(ue.pawn_of(pc))
                far[#far + 1] = string.format("%s %s m", pc_label(pc), l and string.format("%.0f", dist(l, ev.loc) / 100) or "?")
            end
        end
    end
    M.stats.sent = M.stats.sent + sent
    M.stats.sounds = M.stats.sounds + with_sound
    M.stats.far = M.stats.far + #far
    M.stats.notes = M.stats.notes + nn
    if ev.mk then M.stats.markers_sent = M.stats.markers_sent + sent end
    local sound_part
    if ev.snd == "" then
        sound_part = "no spawn sound"
    else
        sound_part = string.format("sound %s to %d (within %.0f m)%s", asset_name(ev.snd), with_sound,
            ((ev.range or 0) + (snd.MARGIN or 500)) / 100, #far > 0 and (", not to " .. table.concat(far, ", ") .. " (beyond)") or "")
    end
    log.info("events: %s at %s: WEVT to %d client(s): %s; %s; %s", ev.cls, ev.key, sent, sound_part,
        #ev.notes > 0 and string.format("the game's notice '%s' to %d (sdc_notes NOTE)", line(ev.notes[1].text), nn)
            or "no notice",
        ev.mk and string.format("map marker '%s' to %d", tostring(ev.title), sent) or "no map marker")
    return sent
end

-- Host: a spawner's SpawnRandomEvent ran (post). Returns true when relayed.
function M.host_event(sp)
    local key = ue.path(sp)
    if st.done[key] then return false end
    local name = ue.short(sp)
    if ue.prop(sp, "Spawned?") ~= true then
        M.stats.empty = M.stats.empty + 1
        log.info("events: %s's random event roll on the host spawned nothing (the game's area check refused it): nothing to relay", name)
        return false
    end
    local loc = ue.location(sp)
    if not loc then
        log.warn("events: %s's random event: its place is unreadable; not relayed", name)
        return false
    end
    st.done[key] = true
    local pcls = ue.prop(sp, "Prefab")
    local cls = ue.valid(pcls) and ue.short(pcls) or "?"
    local sound = ue.prop(sp, "SoundOnSpawn")
    local spath, range, att = "", nil, nil
    if ue.valid(sound) then
        local r, _, label = snd_mod().range_of(sound)
        spath, range, att = ue.path(sound), r, label
    end
    local m = ue.prop(sp, "Marker")
    local mk, title = marker_spec(m)
    local list = notes.shown_since and notes.shown_since(clock() - NOTE_WINDOW_S, cls) or {}
    local ev = { key = loc_str(loc), cls = cls, sp = name, loc = loc, snd = spath, range = range, att = att,
                 mk = mk, title = title, mpath = mk and ue.path(m) or nil, t = clock(), notes = list, to = {} }
    if #st.events >= MAX_EVENTS then table.remove(st.events, 1) end
    st.events[#st.events + 1] = ev
    M.stats.events = M.stats.events + 1
    log.info("events: random event on the host: %s by %s at %s (%s; %s; %s)", cls, name, ev.key,
        spath ~= "" and string.format("sound %s carries %.0f m, %s", asset_name(spath), (range or 0) / 100, tostring(att))
            or "no spawn sound",
        #list > 0 and string.format("the game's notice '%s'", line(list[1].text)) or "no notice",
        mk and string.format("map marker '%s'", tostring(title))
            or "no map marker (the spawner's Marker? or Difficulty.RandomEventMarker is off)")
    M.relay(ev)
    return true
end

-- Host: the wreck replicates at any distance (its fire and smoke too).
local function make_relevant(a, ev, how)
    ue.set_prop(a, "bAlwaysRelevant", true)
    pcall(function() a:ForceNetUpdate() end)
    ev.wreck = ue.path(a)
    M.stats.wrecks = M.stats.wrecks + 1
    log.info("events: the wreck %s of the random event at %s made always relevant (%s): its mesh, fire and smoke reach every client at any distance (its loot / AI parts keep the camps' 1 km)",
        ue.short(a), ev.key, how)
end

-- sdc_world PF.replicate_prefab (host): a camp now replicates; the event's?
function M.on_prefab_replicated(a)
    if role() ~= "host" or not on() or not ue.valid(a) then return end
    local cls = ue.class_name(a)
    local l = ue.location(a)
    if not l then return end
    for i = #st.events, 1, -1 do
        local ev = st.events[i]
        if not ev.wreck and ev.cls == cls and dist(l, ev.loc) <= MATCH_CM then
            make_relevant(a, ev, "replicated by world_prefabs")
            return
        end
    end
end

-- Host (tick): a wreck the replication call did not name.
local function wreck_pass(now)
    if now - st.wreck_at < 2 then return end
    st.wreck_at = now
    for _, ev in ipairs(st.events) do
        if not ev.wreck and now - ev.t >= 2 and now - ev.t <= WRECK_TRY_S then
            for _, a in ipairs(ue.find_all(ev.cls)) do
                local l = ue.valid(a) and ue.location(a)
                if l and dist(l, ev.loc) <= MATCH_CM and ue.prop(a, "bReplicates") == true then
                    make_relevant(a, ev, "found replicated")
                    break
                end
            end
        end
    end
end

-- Host (tick): a player who joined after events gets their markers.
local function joiner_pass(now)
    local live = {}
    for _, pc in ipairs(remote_pcs()) do
        local a = addr(pc)
        if a then
            live[a] = true
            local s = st.seen[a]
            if s == nil then
                if ue.pawn_of(pc) then st.seen[a] = now end
            elseif s ~= true and now - s >= JOIN_WAIT_S then
                st.seen[a] = true
                local n = 0
                for _, ev in ipairs(st.events) do
                    if ev.mk and not ev.to[a] and (not ev.mpath or ue.find_object(ev.mpath)) and send_event(pc, ev, "o", false) then
                        ev.to[a] = true
                        n = n + 1
                    end
                end
                if n > 0 then
                    M.stats.joiners = M.stats.joiners + 1
                    log.info("events: %s joined after %d random event(s): their map markers sent (WEVT o)", pc_label(pc), n)
                end
            end
        end
    end
    for a in pairs(st.seen) do if not live[a] then st.seen[a] = nil end end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function own_place()
    local p = ue.local_pawn()
    return p and ue.location(p) or nil
end

-- The host's sound at the event's place, the game's way (in memory only).
function M.play_sound(sp, loc)
    if sp == "" then return "no sound here (the event has none, or this player was beyond its range on the host)" end
    local path = full_path(sp)
    local s = ue.loaded_asset(path, "events")
    if not s then
        M.stats.not_played = M.stats.not_played + 1
        return "sound " .. asset_name(path) .. " not played: not in memory here (never loaded on this path)"
    end
    local snd = snd_mod()
    local range, att, label = snd.range_of(s)
    local near, d = snd.audible_here(loc, range)
    if not near then
        M.stats.not_played = M.stats.not_played + 1
        return string.format("sound %s not played: %s m away, it carries %.0f m", asset_name(path),
            d and string.format("%.0f", d / 100) or "?", (range or 0) / 100)
    end
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then
        M.stats.not_played = M.stats.not_played + 1
        return "sound not played: no world here"
    end
    local ok, err = pcall(function()
        gps:PlaySoundAtLocation(wc, s, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, att, nil, nil, nil)
    end)
    if not ok then
        M.stats.not_played = M.stats.not_played + 1
        log.err_throttled("events.sound", "events: playing the host's event sound failed: %s", tostring(err))
        return "sound " .. asset_name(path) .. " FAILED"
    end
    M.stats.played = M.stats.played + 1
    return string.format("sound %s played here (%s m away, it carries %.0f m, %s)", asset_name(path),
        d and string.format("%.0f", d / 100) or "?", (range or 0) / 100, tostring(label))
end

-- A BP_Marker_C at the event's place, as BP_PrefabSpawner @850-1341 makes it.
function M.place_marker(key, loc, mk)
    local have = st.markers[key]
    if have and ue.find_object(have) then return string.format("map marker '%s' already here", mk.title) end
    local pc = ue.local_pc()
    if not pc then
        st.pend[key] = { loc = loc, mk = mk }
        return string.format("map marker '%s' waits for this world's controller", mk.title)
    end
    local cls = ue.loaded_asset(P.marker, "events")
    local gs = ue.gameplay_statics()
    if not cls or not gs then return "map marker not placed (BP_Marker_C / GameplayStatics not in memory here)" end
    local tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, a = pcall(function() return gs:BeginDeferredActorSpawnFromClass(pc, cls, tf, 1, nil, 1) end)
    if not ok or not ue.valid(a) then
        log.err_throttled("events.marker", "events: the host's event marker: spawn failed: %s", tostring(a))
        return "map marker spawn FAILED"
    end
    local tex = mk.tex ~= "" and ue.loaded_asset(full_path(mk.tex), "events") or nil
    if tex then ue.set_prop(a, "MarkerTexture", tex) end
    ue.set_prop(a, "MarkerTitle", FText(mk.title))
    ue.set_prop(a, "MarkerDescription", FText(mk.desc))
    ue.set_prop(a, "Texture Size", { X = mk.size.X, Y = mk.size.Y })
    ue.set_prop(a, "Color", { R = mk.col.R, G = mk.col.G, B = mk.col.B, A = mk.col.A })
    ue.set_prop(a, "AddMarkerToCompass?", mk.compass)
    local okf, done = pcall(function() return gs:FinishSpawningActor(a, tf, 1) end)
    local actor = (okf and ue.valid(done)) and done or a
    st.markers[key] = ue.path(actor)
    st.pend[key] = nil
    M.stats.markers = M.stats.markers + 1
    return string.format("map marker '%s' placed (texture %s, finish ok=%s)", mk.title,
        tex and asset_name(mk.tex) or (mk.tex ~= "" and "the marker's default: " .. asset_name(mk.tex) .. " not in memory" or "the marker's default"),
        tostring(okf))
end

-- WEVT|n|class|x,y,z|sound|marker   (host -> client; o = an earlier event, for a joiner: its marker)
local function on_wevt(f)
    if role() ~= "client" then return end
    local kind, cls, loc = f[1], tostring(f[2] or "?"), parse_loc(f[3])
    if not loc then return end
    M.stats.got = M.stats.got + 1
    local key = loc_str(loc)
    if not on() then
        log.info("events: the host's random event %s at %s not shown here (world_events_sync off here)", cls, key)
        return
    end
    if kind == "n" then
        st.recent[#st.recent + 1] = { cls = cls, loc = loc, t = clock() }
        if #st.recent > 16 then table.remove(st.recent, 1) end
    end
    local parts = {}
    if kind == "n" then parts[#parts + 1] = M.play_sound(tostring(f[4] or ""), loc) end
    local mk = parse_marker(f[5])
    parts[#parts + 1] = mk and M.place_marker(key, loc, mk) or "no map marker"
    local me = own_place()
    log.info("events: the host's %s %s at %s (%s from here): %s", kind == "n" and "random event" or "earlier random event",
        cls, key, me and string.format("%.0f m", dist(me, loc) / 100) or "? m", table.concat(parts, "; "))
end

-- sdc_world PF.block_spawner (client): this client's own event manager rolled
-- an event and its spawn was blocked; the spawner would still play its sound.
function M.client_own_roll(sp, cname)
    if role() ~= "client" or not on() or not ue.valid(sp) then return end
    if ue.prop(sp, "DynamicEvent?") ~= true then return end
    local key = ue.path(sp)
    if st.muted[key] then return end
    st.muted[key] = true
    local s = ue.prop(sp, "SoundOnSpawn")
    local had = ue.valid(s) and ue.short(s) or nil
    if had then ue.set_prop(sp, "SoundOnSpawn", nil) end
    M.stats.muted = M.stats.muted + 1
    log.info("events: this client's own event manager rolled a random event at %s (%s; its spawn blocked by world_prefabs): %s; the host's events come from the host",
        ue.short(sp), tostring(cname), had and ("its spawn sound " .. had .. " muted here (a crash only this player would hear)")
            or "it has no spawn sound")
end

-- The post-hook on a client: only this client's own roll runs it here.
local function client_after_roll(sp)
    if not on() or ue.prop(sp, "DynamicEvent?") ~= true then return end
    log.info("events: %s's SpawnRandomEvent ran on this client (its own event manager): %s", ue.short(sp),
        st.muted[ue.path(sp)] and "blocked and silent here" or "nothing spawned here")
end

-- sdc_notes (client): a notice raised here by `wco`. True, why when it is the
-- host's wreck arriving through replication long after its event (a join, out
-- of and back into its relevance): not an event here.
function M.stale_note(wco, text)
    if role() ~= "client" or not on() or not ue.valid(wco) then return false end
    if ue.role(wco) == ue.ROLE_AUTHORITY then return false end   -- this machine's own object
    local cls = ue.class_name(wco)
    if not cls:find("^Prefab_") and not ue.valid(ue.prop(wco, "FoliageRemover")) then return false end
    local l = ue.location(wco)
    local now = clock()
    for i = #st.recent, 1, -1 do
        local e = st.recent[i]
        if e.cls == cls and now - e.t <= RECENT_S and (not l or dist(l, e.loc) <= MATCH_CM) then return false end
    end
    M.stats.stale = M.stats.stale + 1
    return true, string.format("the host's %s reaching this client through replication, no random event of it from the host in the last %d s",
        cls, RECENT_S)
end

-- ---------------------------------------------------------------------------
-- Hook, tick, install
-- ---------------------------------------------------------------------------

-- BP_PrefabSpawner.SpawnRandomEvent (post), every machine.
local function on_spawn_event(c)
    local r = role()
    if r ~= "host" and r ~= "client" then return end
    local sp = c and c:get()
    if not ue.valid(sp) then return end
    if r == "client" then
        client_after_roll(sp)
        return
    end
    if not on() or ue.prop(sp, "DynamicEvent?") ~= true then return end
    M.host_event(sp)
end

function M.try_hooks(force)
    if st.hooked then return end
    local now = clock()
    if not force and now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    if not ue.find_object(P.hook) then return end
    local ok, err = pcall(RegisterHook, P.hook, function(c)
        local okc, e = pcall(on_spawn_event, c)
        if not okc then log.err_throttled("events.hook", "events: SpawnRandomEvent hook: %s", tostring(e)) end
    end)
    st.hooked = ok
    if ok then
        log.info("events: hook BP_PrefabSpawner_C:SpawnRandomEvent ok")
    elseif not st.hook_logged then
        st.hook_logged = true
        log.warn("events: cannot hook %s: %s", P.hook, tostring(err))
    end
end

function M.reset(why)
    st.events, st.done, st.seen, st.recent, st.markers, st.pend, st.muted = {}, {}, {}, {}, {}, {}, {}
    st.wreck_at = 0
    log.debug("events: state dropped (%s)", tostring(why or "?"))
end

-- 1 s tick (main.lua).
function M.tick()
    local r = role()
    if r ~= st.role then
        if st.role ~= nil then M.reset("role " .. tostring(st.role) .. " -> " .. tostring(r)) end
        st.role = r
    end
    if r ~= "host" and r ~= "client" then return end
    M.try_hooks(false)
    if not on() then return end
    local now = clock()
    if r == "host" then
        wreck_pass(now)
        joiner_pass(now)
        return
    end
    for i = #st.recent, 1, -1 do
        if now - st.recent[i].t > RECENT_S * 2 then table.remove(st.recent, i) end
    end
    if next(st.pend) ~= nil and ue.local_pc() then
        local list = st.pend
        st.pend = {}
        for key, p in pairs(list) do
            log.info("events: the host's event marker at %s: %s", key, M.place_marker(key, p.loc, p.mk))
        end
    end
end

function M.status_line()
    local s = M.stats
    return string.format("events: hook=%s host: events=%d empty=%d sent=%d sound=%d beyond=%d notices=%d markers=%d wrecks=%d joiners=%d | client: got=%d played=%d not_played=%d markers=%d muted=%d stale_notices=%d",
        tostring(st.hooked), s.events, s.empty, s.sent, s.sounds, s.far, s.notes, s.markers_sent, s.wrecks, s.joiners,
        s.got, s.played, s.not_played, s.markers, s.muted, s.stale)
end

local installed = false
function M.install(state)
    S = state or S
    if installed then return end
    installed = true
    net.on("WEVT", on_wevt)
    local session = package.loaded["sdc_session"]
    if session and session.world_reset_hooks then
        session.world_reset_hooks.events = function(why) M.reset("world:" .. tostring(why)) end
    end
    M.try_hooks(true)
    log.info("events: installed (world_events_sync=%s): the host's random events (BP_PrefabSpawner_Dynamic: crashed helicopters, abandoned trucks) reach every client: sound, the game's notice, map marker, the wreck",
        tostring(on()))
    log.info("sound relay WEVT (host): a random event's spawn sound (explosion_deep_low_1_Cue: Nuke 3500 m) to the clients within its own range + 5 m, played there at the spawner with its own attenuation; the notice through sdc_notes NOTE, the map marker to every client (joiners too); the wreck always relevant")
end

-- tests
M._t = { on_spawn_event = on_spawn_event, on_wevt = on_wevt, parse_marker = parse_marker, marker_spec = marker_spec,
         set_state = function(s) S = s end, RECENT_S = RECENT_S, JOIN_WAIT_S = JOIN_WAIT_S }

return M
