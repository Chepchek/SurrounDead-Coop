-- SDCoop: the place markers (towns, traders, ...) on this machine's own map.
--
-- How the game marks a visited place (work\re\pseudo: BP_POIManager,
-- W_POIMarker, MapWidget, BPC_MinimapSystem, BFL_MinimapSystem, HUD_Game,
-- SD_GameInstance). Every named place is a level-placed BP_POIManager_C, not
-- replicated: each machine runs its own copy. Its marker: BeginPlay @9614
-- -> Delay 10 -> @3479 (waits for player 0's character) -> @3881
-- BFL_MinimapSystem."Get Minimap Component" (the BPC_MinimapSystem of
-- GetPlayerCharacter(self, 0)) -> "Add POI Marker" -> MapWidget.
-- AddPOICreatedMarker: a new W_POIMarker_C in the map's POI overlay and in
-- MapWidget."POI Marker References", Hidden (the class default: a place
-- nobody here explored is not on the map at all); the manager keeps it in
-- `Marker` (@4552). An unexplored manager runs a looping "DistanceCheck"
-- timer (2-5 s): player 0's character within ExploredCheckRadius -> @242
-- K2_ClearTimer, @268 Explored? = true (SaveGame: the world's Level.sav; the
-- only saved state - there is no separate list of discovered places), @279
-- broadcast Marker.POIExplored -> W_POIMarker.EventExplored (@249
-- SetVisibility(SelfHitTestInvisible), @265 the widget's own Explored?):
-- THE visited mark is the marker appearing; then AddXP 250 / 50 and the
-- HUD toast (HUD_Game.DiscoverPOI). The load path (ActorLoaded @8332) gives
-- the same event; RespawnMarker (SD_GameInstance's respawn functions call it
-- on every manager; sdc_players on a client's late minimap) -> Delay 2 ->
-- @5360 -> 3548: a NEW hidden marker on the map of whoever is player 0 at
-- that moment, `Marker` = that one, @5370 the event again if Explored?. The
-- marker's tooltip (W_POIMarkerTooltip) does not show the explored state.
--
-- 1. Host: the markers stay on the host's map. A remote player's respawn
--    through the game's own flow (sdc_respawn) runs RespawnMarker on every
--    manager while player 0 = that player for the markers (MARKER_WINDOW_S),
--    so the 100+ rebuilt markers go to the remote character's off-screen
--    server map instead of doubling the host's - but every manager's
--    `Marker` then points there, and from then on the host's own discoveries
--    (and the places shown from other players) went to widgets nobody sees:
--    XP and toast, nothing on the host's map (2026-11-11: a client respawned
--    at 22:36, the host found Gas Station, Ellwood, Wilson's Shop after it).
--    The host's own respawn rebuilds them on its new map the game's way.
--    Every GUARD_S (once a remote player was here) the host compares the
--    managers' markers with its own map (its character's MapWidget, "POI
--    Marker References") and gives a manager whose marker is not on it the
--    one that is there for the same place (W_POIMarker."Target Actor"); a
--    place explored meanwhile gets the game's own EventExplored on it.
-- 2. Places shown from other players (map_shared: sdc_persist SHARE.mark)
--    are drawn dimmed (RenderOpacity DIM): "seen by another player". The
--    player's own discovery (DistanceCheck / load: the marker's POIExplored
--    -> EventExplored, post-hooked here) puts the game's own full marker back
--    at once; sdc_persist's passes undim too (safety net). Nothing else in
--    the game touches a marker's render opacity (its Anim is a scale track).

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = {
    DIM = 0.45,      -- RenderOpacity of a place another player explored and this one did not
    GUARD_S = 5,     -- host: markers checked against the host's own map this often
    stats = { dimmed = 0, undimmed = 0, hook_undims = 0, restored = 0, restored_explored = 0, guard_passes = 0 },
}

local POI_CLASS = "BP_POIManager_C"
local POI_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"   -- Struct_POI.Name (FString)
local EXPLORED_FN = "/Game/Blueprints/MinimapSystem/Blueprints/Widget/Markers/W_POIMarker.W_POIMarker_C:EventExplored"
local HOOK_RETRY_S = 10
local MISS_PASSES = 3   -- guard passes a place's marker may be missing on the host's map before it is logged
local LOG_FIRST = 5     -- guard repairs logged in detail per world

local S = nil   -- sdc_session.state

local st = {
    dimmed = {},        -- [marker address] = true: dimmed here (a marker gone with a rebuild leaves its entry)
    map = nil,          -- "<pawn address>:<map widget address>" the caches below belong to
    good = {},          -- [marker address] = true: on the host's own map
    nilm = {},          -- [manager address] = true: no marker at all and none on the host's map (last pass)
    last_n = nil,       -- the host map's marker count at the last index
    armed = false,      -- a remote player was here in this world (only then can sdc_respawn move markers)
    at = -1e9, miss_passes = 0, logs = 0,
    hooked = false, hook_at = -1e9, hook_logged = false,
}

local function m_addr(o) return o:GetAddress() end
local function m_set_opacity(w, v) w:SetRenderOpacity(v) end
local function m_get_opacity(w) return w:GetRenderOpacity() end
local function m_explored(w) w:EventExplored() end

-- address of a live object, or nil
local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(m_addr, o)
    if ok and type(a) == "number" and a ~= 0 then return a end
    return nil
end

local function place_name(a)
    local s = ue.prop(a, "POI")
    if ue.missing(s) then return ue.short(a) end
    local n = ue.str(ue.try(function() return s[POI_NAME] end))
    if n == "" then return ue.short(a) end
    return n
end

-- ---------------------------------------------------------------------------
-- 2. "Seen by another player": dimmed until this player explores the place
-- ---------------------------------------------------------------------------

-- A marker shown for another player's place (sdc_persist SHARE.mark).
-- `force`: set it even when this address was dimmed before (a rebuilt marker
-- can come at a reused address). True when the marker is dimmed.
function M.dim(m, force)
    local a = addr(m)
    if not a then return false end
    if st.dimmed[a] and not force then return true end
    if not pcall(m_set_opacity, m, M.DIM) then return false end
    if not st.dimmed[a] then M.stats.dimmed = M.stats.dimmed + 1 end
    st.dimmed[a] = true
    return true
end

-- The game's own full marker again (this player explored the place).
-- `check`: also a marker not known as dimmed here (its opacity is read).
-- True when it was dimmed.
function M.undim(m, check)
    local a = addr(m)
    if not a then return false end
    if not st.dimmed[a] then
        if not check then return false end
        local ok, op = pcall(m_get_opacity, m)
        if not ok or type(op) ~= "number" or op >= 0.99 then return false end
    end
    st.dimmed[a] = nil
    if not pcall(m_set_opacity, m, 1.0) then return false end
    M.stats.undimmed = M.stats.undimmed + 1
    return true
end

-- Post-hook of W_POIMarker_C:EventExplored (the marker's own POIExplored
-- handler): the game's discovery / load event on a dimmed marker whose place
-- is now explored here. SHARE.mark's own call finds its place unexplored.
local function on_explored(c)
    if next(st.dimmed) == nil then return end
    local w = c and c:get()
    local a = addr(w)
    if not a or not st.dimmed[a] then return end
    local poi = ue.prop(w, "Target Actor")
    if ue.prop(poi, "Explored?") ~= true then return end
    if M.undim(w) then
        M.stats.hook_undims = M.stats.hook_undims + 1
        log.info("poimarks: %s explored by this player: the game's own full marker (it was dimmed: seen by another player)",
            place_name(poi))
    end
end

-- Hooked only once something was dimmed here (map_shared in use).
local function try_hook(now)
    if st.hooked or now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    if not ue.find_object(EXPLORED_FN) then return end
    local ok, err = pcall(RegisterHook, EXPLORED_FN, function(c)
        local okc, e = pcall(on_explored, c)
        if not okc then log.err_throttled("poimarks.hook", "poimarks: EventExplored hook: %s", tostring(e)) end
    end)
    st.hooked = ok
    if ok then
        log.info("poimarks: hook W_POIMarker_C:EventExplored (post) ok: a dimmed place this player explores gets the"
            .. " game's own full marker at once")
    elseif not st.hook_logged then
        st.hook_logged = true
        log.warn("poimarks: cannot hook %s: %s (dimmed places get their full marker from the 5 s map passes)",
            EXPLORED_FN, tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- 1. Host: every manager's marker on the host's own map
-- ---------------------------------------------------------------------------

-- The host's own map: { on = { [marker address] = true }, by = { [manager
-- address] = its latest marker there }, n }. The array only grows
-- (AddUnique at the end): a later entry of a place is a newer marker.
local function map_index(mw)
    local arr = ue.prop(mw, "POI Marker References")
    if arr == nil then return nil end
    local list = {}
    if not pcall(function() arr:ForEach(function(_, e) list[#list + 1] = e:get() end) end) then return nil end
    local idx = { on = {}, by = {}, n = 0 }
    for _, w in ipairs(list) do
        local wa = addr(w)
        if wa then
            idx.on[wa] = true
            idx.n = idx.n + 1
            local ta = addr(ue.prop(w, "Target Actor"))
            if ta then idx.by[ta] = w end
        end
    end
    return idx
end

local function marker_count(mw)
    local arr = ue.prop(mw, "POI Marker References")
    if arr == nil then return nil end
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    return nil
end

-- One pass (host). Returns the number of markers put back. Only addresses
-- are kept between passes (`good`: markers on the host's map; `nilm`:
-- managers with no marker at all): never an engine object.
function M.host_guard()
    local pawn = ue.local_pawn()
    if not pawn then return 0 end
    local mw = ue.prop(ue.prop(pawn, "MinimapSystemComponent"), "MapWidget")
    local mwa = addr(mw)
    if not mwa then return 0 end
    local key = tostring(addr(pawn)) .. ":" .. tostring(mwa)
    if key ~= st.map then
        st.map, st.good, st.nilm, st.last_n, st.miss_passes = key, {}, {}, nil, 0
    end
    M.stats.guard_passes = M.stats.guard_passes + 1
    -- markers not known to be on the host's map; a manager with none at all
    -- (not made yet, or an Add POI Marker that found no map) counts once
    local stale, need = nil, false
    for _, a in ipairs(ue.find_all(POI_CLASS)) do
        local ma = addr(ue.prop(a, "Marker"))
        if not (ma and st.good[ma]) then
            local aa = addr(a)
            stale = stale or {}
            stale[#stale + 1] = { a = a, ma = ma, aa = aa }
            if ma or (aa and not st.nilm[aa]) then need = true end
        end
    end
    if not stale then
        st.miss_passes = 0
        return 0
    end
    local n = marker_count(mw)
    if not n or n == 0 then return 0 end   -- the map's markers are not made yet (a respawn's rebuild comes)
    if not need and n == st.last_n then return 0 end   -- only managers without a marker, nothing new on the map
    local idx = map_index(mw)
    if not idx or idx.n == 0 then return 0 end
    st.last_n = n
    for wa in pairs(idx.on) do st.good[wa] = true end
    local fixed, missing, shown, nilm = {}, 0, {}, {}
    for _, s in ipairs(stale) do
        if not (s.ma and idx.on[s.ma]) then
            local w = s.aa and idx.by[s.aa] or nil
            if w and ue.set_prop(s.a, "Marker", w) then
                fixed[#fixed + 1] = place_name(s.a)
                if ue.prop(s.a, "Explored?") == true then
                    -- explored while its marker was elsewhere: the game's own event on the host's marker
                    if ue.prop(w, "Explored?") ~= true then
                        pcall(m_explored, w)
                        shown[#shown + 1] = place_name(s.a)
                    end
                    M.undim(w, true)
                end
            elseif s.ma then
                missing = missing + 1
            elseif s.aa then
                nilm[s.aa] = true
            end
        end
    end
    st.nilm = nilm
    M.stats.restored = M.stats.restored + #fixed
    M.stats.restored_explored = M.stats.restored_explored + #shown
    if missing > 0 then st.miss_passes = st.miss_passes + 1 else st.miss_passes = 0 end
    if #fixed > 0 then
        st.logs = st.logs + 1
        if st.logs <= LOG_FIRST then
            table.sort(fixed)
            table.sort(shown)
            log.info("poimarks: host: %d place marker(s) were not on the host's map (a remote player's respawn made them"
                .. " on that player's off-screen map): the host's own markers put back%s%s: %s", #fixed,
                #shown > 0 and string.format("; %d explored by the host meanwhile now shown (%s)", #shown,
                    table.concat(shown, ", ")) or "",
                missing > 0 and string.format("; %d place(s) have no marker on the host's map yet", missing) or "",
                #fixed <= 12 and table.concat(fixed, ", ") or (table.concat(fixed, ", ", 1, 12) .. ", ..."))
        end
    elseif st.miss_passes == MISS_PASSES then
        log.info("poimarks: host: %d place marker(s) are not on the host's map and it has none of them: left to the"
            .. " game (its next marker rebuild)", missing)
    end
    return #fixed
end

-- ---------------------------------------------------------------------------
-- Loop
-- ---------------------------------------------------------------------------

function M.tick()
    if not S then return end
    local now = os.clock()
    if not st.hooked and next(st.dimmed) ~= nil then try_hook(now) end
    local role = S.role
    if role == "client" then return end
    if role == "host" and type(S.remote) == "table" and next(S.remote) ~= nil and not st.armed then
        st.armed = true
        log.info("poimarks: host: a remote player is here: the place markers are checked against the host's own map"
            .. " every %d s from now on (this world)", M.GUARD_S)
    end
    if not st.armed or S.in_menu ~= false then return end
    if now - st.at < M.GUARD_S then return end
    st.at = now
    M.host_guard()
end

-- New world (sdc_session.world_reset_hooks): the old one's markers are gone.
function M.reset()
    st.dimmed, st.map, st.good, st.nilm, st.last_n = {}, nil, {}, {}, nil
    st.armed, st.at, st.miss_passes, st.logs = false, -1e9, 0, 0
end

function M.status()
    local n = 0
    for _ in pairs(st.dimmed) do n = n + 1 end
    local s = M.stats
    return string.format("marks: dimmed=%d (now %d) undimmed=%d (hook %d) host_restored=%d (explored %d) guard=%s/%d hook=%s",
        s.dimmed, n, s.undimmed, s.hook_undims, s.restored, s.restored_explored, tostring(st.armed), s.guard_passes,
        tostring(st.hooked))
end

local installed = false
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    if session and session.world_reset_hooks then session.world_reset_hooks.poimarks = M.reset end
    if installed then return end
    installed = true
    ue.every("poimarks", 1000, M.tick)
    log.info("poimarks: installed (host: place markers kept on the host's own map, checked every %d s once a remote"
        .. " player was here; places only other players explored dimmed to %.2f until this player gets there)",
        M.GUARD_S, M.DIM)
end

-- tests
M._st = st

return M
