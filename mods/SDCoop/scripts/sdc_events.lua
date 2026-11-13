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
--          1 km). A player who joins later gets the events' markers (WEVT|o,
--          one list message).
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
-- Placed camps with a map marker (BP_PrefabSpawner, DynamicEvent? off: the
-- abandoned laboratory research tents - 6 spawners, Chance 5 x
-- Difficulty.RandomEventMultiplier -, abandoned camps / convoys, quarantine
-- tents, crashed planes...): rolled once per world load on every machine
-- (@613 Delay -> @226 Random Check -> CheckSurroundingArea -> the camp ->
-- @515 DistanceToPrefab timer -> @583 SpawnMarker); no event manager, no
-- sound, no notice. A client's own roll is blocked (sdc_world world_prefabs:
-- camp and marker) and the host's camp reaches it within 1 km: a client had
-- none of their map markers (audit world.md 1.10 "Remaining").
--   host   BP_PrefabSpawner.SpawnMarker (post) on a placed spawner whose
--          Marker was made: kept (st.camps) and sent like an event's
--          marker: in a joiner's WEVT o list, or at once to a client whose
--          list went before; at each join snapshot one FindAllOf over the
--          spawners takes any the hook missed.
--   client the marker as an earlier event's (WEVT o).
-- The host's world_prefabs off: its camps do not replicate and every client
-- rolls its own (with their markers): none of the host's camp markers goes.
--
-- A camp's marker goes when the camp is visited (2026-11-13: "the marker does
-- not go after you visit it"). The game: the timer set at @515 (looping, a
-- random 2-6 s, never stopped otherwise) runs DistanceToPrefab: player 0's
-- character (GetPlayerCharacter(self, 0)) closer than the spawner's
-- DistanceToDiscoverPrefab (class default 2000 = 20 m, every placed camp of
-- the level) -> if its Marker is valid: "Get Minimap Component" (player 0's
-- character's BPC_MinimapSystem) . "Remove World Marker"(Marker.Marker, Marker)
-- = that W_WorldMarker widget RemoveFromParent + the BP_Marker destroyed;
-- then K2_ClearTimer and the discovery XP (@313-461). Single player: the
-- marker goes on a visit. Nothing of it is saved: BP_PrefabSpawner has no
-- save interface (only BPI_RandomEvent), no SaveGame property; the camp
-- (PrefabMaster) and BP_Marker neither: every world load rolls the camps
-- again (a new marker where one rolls), in single player too. Gaps:
--   * per machine, player 0 only: a client's visit took nothing off the
--     host's map, nor its own copy (a marker of this module: no timer);
--   * the game's own: while player 0 has no character (death screen: the
--     body's AfterDeath UnPossesses @1387) GetDistanceTo(None) is 0: every
--     running check "discovers" its camp, pays the XP and stops its timer,
--     but "Get Minimap Component" is None then and the marker stays - and
--     no check is left to take it off later (that night the host died at
--     22:19, half an hour before the tents were reached);
--   * the mod's: a remote player's respawn re-adds every BP_Marker (the
--     game instance's respawn loop) to that player's off-screen map on the
--     host (sdc_respawn MARKER_CLASSES): its `Marker` then names a widget
--     nobody sees and the game's removal leaves the host's own one on the
--     map (W_WorldMarker has no timer of its own: MapWidget only skips a
--     marker whose Target Actor is gone).
-- Here (co-op rule: the world and its loot are the group's, so a camp one
-- player reached counts for everyone):
--   host   every second, for each kept camp not visited yet: a living player
--          (the host or a client, sdc_ctx.live_players) within its radius,
--          or its BP_Marker gone with the host's living character within
--          the radius + 60 m now or at the last pass (the game's own
--          discovery between two passes) -> visited: this map's widgets of
--          it go (Target Actor = the marker, or the widget noted for it on
--          this map: noted every 5 s from the map's "World Marker
--          References", a camp missed 6 times there not looked for again
--          until the host's next map), the game's Remove World Marker steps
--          (Marker.Marker RemoveFromParent, the BP_Marker destroyed: a later
--          respawn loop finds nothing to re-add), and WEVT|x|key;... to every
--          client. A joiner's list leaves visited camps out. A marker gone
--          with nobody near is no visit: the world is going (the pause /
--          respawn screen's quit to the menu, a save loaded in game:
--          GameFunctionLibrary.DestroyAllActors destroys every BP_Marker_C
--          before the load resets this module: pseudo PauseScreen @523,
--          RespawnScreen @560, SaveMenu @952) - that camp is dropped from the
--          list, nothing sent. The spawner's own timer is left alone: the
--          host's discovery XP comes when the host gets there itself (the
--          clients': sdc_world WCAMPXP). Kept for this world only (the game
--          rolls the camps again at the next load).
--   client WEVT x (whatever world_events_sync is here: a marker placed while
--          it was on goes too): the marker placed for that camp goes the
--          same way (all widgets of it on this map: sdc_players' late
--          minimap may have registered it twice), one still waiting for
--          this world's controller is not placed; a later WEVT o of it is
--          ignored. The key is the camp's place as loc_str prints it on both
--          machines ("-0" printed "0": the client's tonumber gives 0).
-- Random events' markers (helicopters, trucks) have no removal in the game
-- (no DistanceToPrefab timer) and are not touched.
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
              joiners = 0, got = 0, played = 0, not_played = 0, markers = 0, muted = 0, stale = 0, camps = 0,
              visited = 0, gone = 0 },
}

local P = {
    hook = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnRandomEvent",
    marker_hook = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C:SpawnMarker",
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
local CHUNK = 1500          -- characters of one joiner's WEVT o list message
local DISCOVER_CM = 2000    -- BP_PrefabSpawner.DistanceToDiscoverPrefab's class default (20 m)
local INDEX_S = 5           -- host: the map's widgets of the kept camps noted this often (until all are)
local INDEX_TRIES = 6       -- host: a camp whose widget this many passes did not find is not looked for again on that map
local NEAR_CM = 6000        -- host: a camp's marker gone with the host this much beyond its radius: the game's own discovery
-- BP_PrefabSpawner @1045 / @1158: the marker's size and colour
local SIZE0 = { X = 3.5, Y = 3.5 }
local COL0 = { R = 0.505208, G = 0.169744, B = 0.034207, A = 1 }

local S = nil
local st = {
    hooked = false, hook_at = -100, hook_logged = false, mhooked = false, mhook_logged = false,
    events = {},     -- host: { key, cls, sp, loc, snd, range, att, mk, title, mpath, t, notes, wreck, to = { [pc address] } }
    camps = {},      -- host: { key, cls, sp, mk, title, camp = true, to = { [pc address] }, loc, r, mpath,
                     --         gone = why | nil, wkey, waddr = { widget address }, mkey, miss } placed camps' markers
    camps_new = false, -- host: a camp noted since the last tick (a client whose list went before gets it)
    index_at = 0,
    host_prev = nil, -- host: its living character's place at the last camp pass (nil: none, or no pass)
    gone = {},       -- client: [camp key] = true: visited (its marker taken off, not placed again)
    done = {},       -- host: [spawner path] = true (relayed / camp noted)
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
-- the placed camps' markers: only while the host's camps are the clients'
-- (sdc_world world_prefabs; off: none replicates, every client rolls its own)
local function camps_on() return on() and cfg.get("world_prefabs") ~= false end
local function addr(o) return ue.valid(o) and ctx.addr(o) or nil end

-- An event's / camp's key, the same on both machines: the host makes it from
-- the spawner's place, a client from the key it got (parse_loc, then here).
-- A coordinate in (-0.5, 0] prints "-0" on the host but comes back as 0 from
-- tonumber("-0"): "0" on both (else WEVT x misses the client's marker).
local function coord(v)
    local s = string.format("%.0f", v)
    return s == "-0" and "0" or s
end
local function loc_str(l) return coord(l.X) .. "," .. coord(l.Y) .. "," .. coord(l.Z) end
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
    return (tostring(s or ""):gsub("[%%|>;\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
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

-- WEVT n and the notices of one new event to one client; sound: send the sound path.
local function send_event(pc, ev, sound)
    local ok = net.send_to(pc, "WEVT", "n", ev.cls, ev.key, sound and short_path(ev.snd) or "", ev.mk or "")
    if not ok then return false, 0 end
    local n = 0
    for _, nt in ipairs(ev.notes) do
        if notes.show_to(pc, nt.text, nt.icon, nt.col, nt.delay, "the host's random event " .. ev.cls) then n = n + 1 end
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
        local ok, n = send_event(pc, ev, sound)
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

-- Host: a placed camp's map marker (its spawner's Marker, made by
-- SpawnMarker @583), kept for every client. Returns true when noted.
function M.note_camp(sp, how)
    local key = ue.path(sp)
    if not key or st.done[key] or not camps_on() then return false end
    -- none: Marker? off, Difficulty.RandomEventMarker off, or the host found the camp already
    local m = ue.prop(sp, "Marker")
    local mk, title = marker_spec(m)
    local loc = mk and ue.location(sp)
    if not loc then return false end
    st.done[key] = true
    local pcls = ue.prop(sp, "Prefab")
    local r = num(ue.prop(sp, "DistanceToDiscoverPrefab"))
    local ev = { key = loc_str(loc), cls = ue.valid(pcls) and ue.short(pcls) or "?", sp = ue.short(sp), mk = mk,
                 title = title, camp = true, to = {}, loc = loc, r = (r and r > 0) and r or DISCOVER_CM,
                 mpath = ue.path(m) }
    -- its marker found by its path now: only then does "not found" later mean it went
    ev.findable = ue.find_object(ev.mpath) ~= nil
    st.camps[#st.camps + 1] = ev
    st.camps_new = true
    M.stats.camps = M.stats.camps + 1
    log.info("events: camp with a map marker on the host: %s by %s at %s, marker '%s' (%s): every client gets it (WEVT o)",
        ev.cls, ev.sp, ev.key, tostring(title), how)
    return true
end

-- Host, at a join snapshot: camps whose SpawnMarker the hook missed (one
-- FindAllOf per join).
local function scan_camps()
    if not camps_on() then return end
    for _, sp in ipairs(ue.find_all("BP_PrefabSpawner_C")) do
        if ue.valid(sp) and ue.prop(sp, "DynamicEvent?") ~= true then M.note_camp(sp, "found at a join") end
    end
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

-- Host: the markers of earlier events to a joiner, as lists of at most CHUNK
-- characters: WEVT|o|class>x,y,z>marker;class>x,y,z>marker... The placed
-- camps' markers go in the same list. Returns the events sent, the camps
-- sent and the camps' marker titles.
local function send_markers(pc, a)
    local list = {}
    for _, ev in ipairs(st.events) do
        if ev.mk and not ev.to[a] and (not ev.mpath or ue.find_object(ev.mpath)) then list[#list + 1] = ev end
    end
    for _, ev in ipairs(camps_on() and st.camps or {}) do
        if not ev.to[a] and not ev.gone then list[#list + 1] = ev end   -- a visited camp's marker is gone for everyone
    end
    local n, nc, titles, buf, evs, len = 0, 0, {}, {}, {}, 0
    local function flush()
        if #buf == 0 then return end
        if net.send_to(pc, "WEVT", "o", table.concat(buf, ";")) then
            for _, ev in ipairs(evs) do
                ev.to[a] = true
                if ev.camp then
                    nc = nc + 1
                    titles[#titles + 1] = tostring(ev.title)
                else
                    n = n + 1
                end
            end
        end
        buf, evs, len = {}, {}, 0
    end
    for _, ev in ipairs(list) do
        local it = table.concat({ ev.cls, ev.key, ev.mk }, ">")
        if len + #it + 1 > CHUNK then flush() end
        buf[#buf + 1] = it
        evs[#evs + 1] = ev
        len = len + #it + 1
    end
    flush()
    return n, nc, table.concat(titles, ", ")
end

-- Host (tick): a player who joined after events gets their markers and the
-- camps'; one whose list went before gets the camps noted since.
local function joiner_pass(now)
    local fresh = st.camps_new
    st.camps_new = false
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
                scan_camps()
                local n, nc, titles = send_markers(pc, a)
                if n > 0 or nc > 0 then M.stats.joiners = M.stats.joiners + 1 end
                if n > 0 then
                    log.info("events: %s joined after %d random event(s): their map markers sent (WEVT o)", pc_label(pc), n)
                end
                if nc > 0 then
                    log.info("events: %s joined: the map markers of %d camp(s) of the host sent (WEVT o): %s",
                        pc_label(pc), nc, titles)
                end
            elseif s == true and fresh then
                local n, nc, titles = send_markers(pc, a)
                if n + nc > 0 then
                    log.info("events: %s: %d more map marker(s) sent (WEVT o): %d random event(s), %d camp(s)%s",
                        pc_label(pc), n + nc, n, nc, nc > 0 and (": " .. titles) or "")
                end
            end
        end
    end
    -- a player who left: its controller's address may come back as another's
    for a in pairs(st.seen) do
        if not live[a] then
            st.seen[a] = nil
            for _, ev in ipairs(st.events) do ev.to[a] = nil end
            for _, ev in ipairs(st.camps) do ev.to[a] = nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Visited camps (the host decides; both machines take the marker off)
-- ---------------------------------------------------------------------------

-- This machine's own map: its character's BPC_MinimapSystem MapWidget and a
-- key for it (a respawn builds a new one); nil while there is no character.
local function own_map()
    local pawn = ue.local_pawn()
    local mw = pawn and ue.prop(ue.prop(pawn, "MinimapSystemComponent"), "MapWidget")
    local a = addr(mw)
    if not a then return nil end
    return mw, tostring(addr(pawn)) .. ":" .. tostring(a)
end

-- MapWidget."World Marker References" (AddWorldCreatedMarker's AddUnique; the
-- game never takes an entry out): { { w, wa, ta } } - the widget, its address,
-- its Target Actor's address (nil: gone) -; nil when unreadable.
local function world_widgets(mw)
    local arr = ue.prop(mw, "World Marker References")
    if arr == nil then return nil end
    local raw = {}
    if not pcall(function() arr:ForEach(function(_, e) raw[#raw + 1] = e:get() end) end) then return nil end
    local out = {}
    for _, w in ipairs(raw) do
        local wa = addr(w)
        if wa then out[#out + 1] = { w = w, wa = wa, ta = addr(ue.prop(w, "Target Actor")) } end
    end
    return out
end

-- A camp's marker off this machine's map: every widget of the map showing it
-- (Target Actor = the marker `m`) or noted for it (`noted`: widget addresses),
-- then the steps of the game's "Remove World Marker" (the marker's own widget
-- RemoveFromParent, the BP_Marker destroyed). Returns the widgets taken off
-- this map and whether the marker actor went.
local function unmark(m, noted)
    local ma = addr(m)
    local want = {}
    for _, wa in ipairs(noted or {}) do want[wa] = true end
    local n = 0
    local mw = own_map()
    for _, e in ipairs((mw and world_widgets(mw)) or {}) do
        if want[e.wa] or (ma ~= nil and e.ta == ma) then
            if pcall(function() e.w:RemoveFromParent() end) then n = n + 1 end
        end
    end
    local destroyed = false
    if ma then
        local w = ue.prop(m, "Marker")
        if ue.valid(w) then pcall(function() w:RemoveFromParent() end) end
        destroyed = pcall(function() m:K2_DestroyActor() end)
    end
    return n, destroyed
end

-- Index pass: this camp's widget is still to be looked for on the map `key`
-- (not known there yet, and fewer than INDEX_TRIES passes missed it there:
-- a widget the map never got - its marker unfindable by path, never added -
-- would have the pass walk the map's list every INDEX_S for good).
local function index_wanted(c, key)
    if c.gone or c.wkey == key then return false end
    return c.mkey ~= key or (c.miss or 0) < INDEX_TRIES
end

-- Host (every INDEX_S, until each kept camp's is known for this map): the
-- host's own widget of each camp's marker, by address, while the marker
-- stands. The game's discovery may take the marker before the next pass, and
-- after a remote player's respawn its `Marker` names that player's
-- off-screen widget: then only this note finds the one on the host's map.
-- A camp missed INDEX_TRIES times on one map is left until the map changes
-- (the host's respawn builds a new one: its widgets are noted again).
local function index_pass(now)
    if now - st.index_at < INDEX_S then return end
    st.index_at = now
    local mw, key = own_map()
    if not mw then return end
    local need = false
    for _, c in ipairs(st.camps) do
        if index_wanted(c, key) then need = true break end
    end
    if not need then return end
    local list = world_widgets(mw)
    local by = {}
    for _, e in ipairs(list or {}) do
        if e.ta then
            local t = by[e.ta]
            if not t then t = {}; by[e.ta] = t end
            t[#t + 1] = e.wa
        end
    end
    local quit = 0
    for _, c in ipairs(st.camps) do
        if index_wanted(c, key) then
            local ma = list and addr(c.mpath and ue.find_object(c.mpath))
            local ws = ma and by[ma]
            if ws then
                c.wkey, c.waddr, c.mkey, c.miss = key, ws, nil, nil
            else
                if c.mkey ~= key then c.mkey, c.miss = key, 0 end
                c.miss = c.miss + 1
                if c.miss >= INDEX_TRIES then quit = quit + 1 end
            end
        end
    end
    if quit > 0 then
        log.debug("events: the host's map widget of %d camp(s) not found in %d passes: not looked for again on this map", quit, INDEX_TRIES)
    end
end

-- The host's own living character's place now, or nil (none: its death /
-- respawn screen, the body unpossessed; dead).
local function host_place()
    local p = ue.local_pawn()
    if not p or ctx.is_dead_player(p) then return nil end
    return ue.location(p)
end

-- Camp `c`'s marker went on the host between two passes: the game's own
-- discovery only with the host's living character near the camp (within its
-- radius + NEAR_CM: a second's walk or drive) now or at the last pass. Else
-- the world is going (the pause / respawn screen's "quit", a save loaded in
-- game: GameFunctionLibrary.DestroyAllActors destroys every BP_Marker_C
-- before the load resets this module), or something else took it.
local function host_found(c, here, prev)
    local lim = c.r + NEAR_CM
    return (here ~= nil and dist(here, c.loc) < lim) or (prev ~= nil and dist(prev, c.loc) < lim)
end

-- Host (every tick): a kept camp a living player (the host or a client) has
-- reached, or whose marker the game's own discovery took meanwhile (the host
-- near it), is visited: its marker goes here and on every client (WEVT x). A
-- camp whose marker went with nobody near is dropped from the list: no
-- visit, nothing to the clients. Returns the number visited now.
local function camp_pass(now)
    if #st.camps == 0 or not camps_on() then
        st.host_prev = nil
        return 0
    end
    local live, here, keys, found, lost = nil, nil, {}, {}, nil
    local prev = st.host_prev
    for _, c in ipairs(st.camps) do
        if not c.gone then
            if not live then live, here = ctx.live_players(), host_place() end
            local who, d = nil, nil
            for _, e in ipairs(live) do
                local de = dist(e.loc, c.loc)
                if de < c.r then who, d = e, de break end
            end
            local m = c.mpath and ue.find_object(c.mpath)
            local why
            if who then
                why = string.format("%s came within %.0f m (the game's discovery radius %.0f m)",
                    who.remote and pc_label(who.pc) or "the host", d / 100, c.r / 100)
            elseif c.findable and not m then
                if host_found(c, here, prev) then
                    why = "its marker went on the host (the game's own discovery: the host was within its radius)"
                else
                    lost = lost or {}
                    lost[c] = true
                end
            end
            if why then
                c.gone = why
                M.stats.visited = M.stats.visited + 1
                local _, mkey = own_map()
                local n, destroyed = unmark(m, (mkey and c.wkey == mkey) and c.waddr or nil)
                keys[#keys + 1] = c.key
                found[#found + 1] = { c = c, why = why, n = n, destroyed = destroyed, had = m ~= nil }
            end
        end
    end
    st.host_prev = here
    if lost then
        local kept, titles = {}, {}
        for _, c in ipairs(st.camps) do
            if lost[c] then titles[#titles + 1] = tostring(c.title) else kept[#kept + 1] = c end
        end
        st.camps = kept
        log.info("events: the map markers of %d camp(s) went on the host with nobody near them (the world going: DestroyAllActors before a load?): dropped, not a visit, nothing to the clients: %s",
            #titles, table.concat(titles, ", "))
    end
    if #keys == 0 then
        index_pass(now)
        return 0
    end
    local sent = 0
    for _, pc in ipairs(remote_pcs()) do
        if net.send_to(pc, "WEVT", "x", table.concat(keys, ";")) then sent = sent + 1 end
    end
    for _, f in ipairs(found) do
        log.info("events: camp '%s' (%s at %s) visited: %s; its map marker taken off for everyone: here %s, on %d client(s) (WEVT x)",
            tostring(f.c.title), f.c.cls, f.c.key, f.why,
            f.had and string.format("%d map widget(s) off, its marker %s", f.n, f.destroyed and "destroyed" or "NOT destroyed")
                or string.format("%d map widget(s) off (its marker %s)", f.n,
                    f.c.findable and "was gone already" or "NOT found by its path: it may stay on the host's map"), sent)
    end
    return #keys
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

-- One event of the host here: n (live: its sound, its marker) or o (an
-- earlier one, for a joiner: its marker).
local function show_event(kind, cls, loc, sound, mkspec)
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
    if kind == "n" then parts[#parts + 1] = M.play_sound(sound, loc) end
    local mk = parse_marker(mkspec)
    if mk and st.gone[key] then
        parts[#parts + 1] = "camp visited by the group already: no map marker"
    else
        parts[#parts + 1] = mk and M.place_marker(key, loc, mk) or "no map marker"
    end
    local me = own_place()
    log.info("events: the host's %s %s at %s (%s from here): %s",
        kind == "n" and "random event" or "earlier random event / camp",
        cls, key, me and string.format("%.0f m", dist(me, loc) / 100) or "? m", table.concat(parts, "; "))
end

-- WEVT x: camps a player of the group reached (the host decides): the marker
-- placed here for each goes, and none is placed for them again.
local function camps_gone(list)
    for key in tostring(list or ""):gmatch("[^;]+") do
        if not st.gone[key] then
            st.gone[key] = true
            st.pend[key] = nil
            local p = st.markers[key]
            st.markers[key] = nil
            local m = p and ue.find_object(p)
            local what = "no marker of it here"
            if m then
                local n, destroyed = unmark(m, nil)
                M.stats.gone = M.stats.gone + 1
                what = string.format("its map marker taken off here (%d map widget(s) off, the marker %s)", n,
                    destroyed and "destroyed" or "NOT destroyed")
            end
            log.info("events: the host's camp at %s was visited by a player of the group: %s", key, what)
        end
    end
end

-- WEVT|n|class|x,y,z|sound|marker   (host -> client; o = an earlier event, for a joiner: its marker)
-- WEVT|o|class>x,y,z>marker;...     (host -> a joiner: the earlier events and the placed camps, one list)
-- WEVT|x|x,y,z;...                  (host -> every client: camps the group visited: their markers go)
local function on_wevt(f)
    if role() ~= "client" then return end
    if f[1] == "x" then
        -- whatever world_events_sync is here: a marker placed while it was on
        -- goes too (taking one off is always safe)
        camps_gone(f[2])
        return
    end
    if f[1] == "o" and f[3] == nil then
        for e in tostring(f[2] or ""):gmatch("[^;]+") do
            local cls, at, mk = e:match("^([^>]*)>([^>]*)>(.*)$")
            local loc = parse_loc(at)
            if loc then show_event("o", cls ~= "" and cls or "?", loc, "", mk) end
        end
        return
    end
    local loc = parse_loc(f[3])
    if not loc then return end
    show_event(f[1], tostring(f[2] or "?"), loc, tostring(f[4] or ""), f[5])
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

-- BP_PrefabSpawner.SpawnRandomEvent (post), host. On a client only its own
-- event manager's roll runs it: sdc_world blocked that spawn and
-- client_own_roll muted its sound (both logged there), nothing to do here.
local function on_spawn_event(c)
    if role() ~= "host" then return end
    local sp = c and c:get()
    if not ue.valid(sp) or not on() or ue.prop(sp, "DynamicEvent?") ~= true then return end
    M.host_event(sp)
end

-- BP_PrefabSpawner.SpawnMarker (post), host: a placed camp's marker (@583,
-- once at load); a dynamic event's (@31) is host_event's.
local function on_spawn_marker(c)
    if role() ~= "host" or not on() then return end
    local sp = c and c:get()
    if not ue.valid(sp) or ue.prop(sp, "DynamicEvent?") == true then return end
    M.note_camp(sp, "its camp spawned")
end

function M.try_hooks(force)
    local want_m = role() == "host"   -- SpawnMarker: the host's only
    if st.hooked and (st.mhooked or not want_m) then return end
    local now = clock()
    if not force and now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    if not st.hooked and ue.find_object(P.hook) then
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
    if want_m and not st.mhooked and ue.find_object(P.marker_hook) then
        local ok, err = pcall(RegisterHook, P.marker_hook, function(c)
            local okc, e = pcall(on_spawn_marker, c)
            if not okc then log.err_throttled("events.mhook", "events: SpawnMarker hook: %s", tostring(e)) end
        end)
        st.mhooked = ok
        if ok then
            log.info("events: hook BP_PrefabSpawner_C:SpawnMarker ok (the placed camps' map markers for the clients)")
        elseif not st.mhook_logged then
            st.mhook_logged = true
            log.warn("events: cannot hook %s: %s", P.marker_hook, tostring(err))
        end
    end
end

function M.reset(why)
    st.events, st.done, st.seen, st.recent, st.markers, st.pend, st.muted = {}, {}, {}, {}, {}, {}, {}
    st.camps, st.camps_new, st.gone = {}, false, {}   -- visits count for this world only: the game rolls the camps again
    st.wreck_at, st.index_at, st.host_prev = 0, 0, nil
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
    if not on() then
        st.host_prev = nil   -- (no camp pass: the next one has no "last pass" to go by)
        return
    end
    local now = clock()
    if r == "host" then
        wreck_pass(now)
        camp_pass(now)     -- before the joiners: a camp visited now is not in a list sent now
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
    return string.format("events: hook=%s/%s host: events=%d empty=%d sent=%d sound=%d beyond=%d notices=%d markers=%d wrecks=%d joiners=%d camps=%d visited=%d | client: got=%d played=%d not_played=%d markers=%d muted=%d stale_notices=%d camps_gone=%d",
        tostring(st.hooked), tostring(st.mhooked), s.events, s.empty, s.sent, s.sounds, s.far, s.notes, s.markers_sent,
        s.wrecks, s.joiners, s.camps, s.visited, s.got, s.played, s.not_played, s.markers, s.muted, s.stale, s.gone)
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
    log.info("events: installed (world_events_sync=%s): the host's random events (BP_PrefabSpawner_Dynamic: crashed helicopters, abandoned trucks) reach every client: sound, the game's notice, map marker, the wreck; the placed camps' map markers (laboratory research tents, abandoned camps / convoys...) too, taken off for everyone once any player reaches the camp (the game's discovery radius)",
        tostring(on()))
    log.info("sound relay WEVT (host): a random event's spawn sound (explosion_deep_low_1_Cue: Nuke 3500 m) to the clients within its own range + 5 m, played there at the spawner with its own attenuation; the notice through sdc_notes NOTE, the map marker to every client (joiners too); the wreck always relevant")
end

-- tests
M._t = { on_spawn_event = on_spawn_event, on_spawn_marker = on_spawn_marker, on_wevt = on_wevt, parse_marker = parse_marker, marker_spec = marker_spec,
         set_state = function(s) S = s end, RECENT_S = RECENT_S, JOIN_WAIT_S = JOIN_WAIT_S,
         camp_pass = camp_pass, unmark = unmark, INDEX_S = INDEX_S, DISCOVER_CM = DISCOVER_CM,
         INDEX_TRIES = INDEX_TRIES }

return M
