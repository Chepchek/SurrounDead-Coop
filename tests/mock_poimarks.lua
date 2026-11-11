-- Mock harness: sdc_poimarks - the place markers on this machine's own map.
-- usage: lua mock_poimarks.lua <scripts dir>
--
-- The fake game follows work\re\pseudo (BP_POIManager, W_POIMarker,
-- MapWidget, BPC_MinimapSystem, BFL_MinimapSystem, SD_GameInstance):
--   * a marker is made on the map of whoever is player 0 at that moment
--     (Get Minimap Component -> Add POI Marker -> AddPOICreatedMarker: a new
--     W_POIMarker, Hidden, its Explored? = the manager's, Target Actor = the
--     manager, appended to MapWidget."POI Marker References"); no map -> the
--     manager's Marker = None;
--   * W_POIMarker.EventExplored: SetVisibility(4) + the widget's Explored?
--     (post-hooks of EXPLORED_FN run after it);
--   * DistanceCheck: the manager's Explored? = true, broadcast to its Marker,
--     XP and toast;
--   * RespawnMarker (SD_GameInstance's respawn): a new marker on player 0's
--     map; the event again if explored. A remote player's respawn on the host
--     runs it with player 0 = that player (sdc_respawn's marker scope): the
--     new markers land on that character's off-screen server map.
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    print((c and "  ok   " or "  FAIL ") .. what)
    if not c then fails = fails + 1 end
end

local CLK = 100.0
os.clock = function() return CLK end

-- ------------------------------------------------------------- fake objects
local nobj = 0
local function obj(class, t)
    nobj = nobj + 1
    t = t or {}
    t._class, t._valid, t._addr = class, true, 0x40000 + nobj * 16
    t._name = t._name or (class .. "_" .. nobj)
    t.GetAddress = function(self) return self._valid and self._addr or 0 end
    t.IsValid = function(self) return self._valid end
    return t
end

local EXPLORED_FN = "/Game/Blueprints/MinimapSystem/Blueprints/Widget/Markers/W_POIMarker.W_POIMarker_C:EventExplored"
local POI_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"
local HOOKS = {}
local hook_calls = 0
RegisterHook = function(path, fn)
    hook_calls = hook_calls + 1
    HOOKS[path] = HOOKS[path] or {}
    table.insert(HOOKS[path], fn)
    return 1, 2
end

local opacity_sets = 0
local function new_map()
    local mw = obj("MapWidget_C", { list = {}, foreach_n = 0 })
    mw["POI Marker References"] = {
        ForEach = function(_, f)
            mw.foreach_n = mw.foreach_n + 1
            for i, w in ipairs(mw.list) do f(i, { get = function() return w end }) end
        end,
        GetArrayNum = function() return #mw.list end,
    }
    return mw
end

local function event_explored(w)                  -- @249 SetVisibility(4), @265 Explored? = true; then post-hooks
    w.vis = 4
    w["Explored?"] = true
    w.events = w.events + 1
    for _, fn in ipairs(HOOKS[EXPLORED_FN] or {}) do fn({ get = function() return w end }) end
end

local function add_marker(mw, a)                  -- MapWidget.AddPOICreatedMarker
    local w = obj("W_POIMarker_C", { ["Explored?"] = a["Explored?"] == true, ["Target Actor"] = a, vis = 2,
        opacity = 1.0, events = 0, map = mw })
    w.EventExplored = function(self) event_explored(self) end
    w.SetRenderOpacity = function(self, v) self.opacity = v; opacity_sets = opacity_sets + 1 end
    w.GetRenderOpacity = function(self) return self.opacity end
    table.insert(mw.list, w)
    return w
end

local function new_pawn(mw)
    return obj("BP_PlayerCharacter_C", { MinimapSystemComponent = obj("BPC_MinimapSystem_C", { MapWidget = mw }) })
end

-- the machine: places, player 0's pawn (whose map gets the markers)
local W = { pois = {}, xp = 0, toasts = 0, finds = 0 }

local function build_marker(a, pawn)              -- @3548-4552, @5370
    local mm = pawn and pawn.MinimapSystemComponent
    local mw = mm and mm.MapWidget
    if mw and mw._valid then a.Marker = add_marker(mw, a) else a.Marker = nil end
    if a["Explored?"] and a.Marker then event_explored(a.Marker) end
end

local function new_poi(i, name, explored)
    local a = obj("BP_POIManager_C", { _name = "BP_POIManager_C_" .. i, ["Explored?"] = explored == true,
        POI = { [POI_NAME] = name }, _timer = explored ~= true })
    return a
end

local function walk_to(a)                         -- DistanceCheck with player 0 there
    if not a._timer then return false end
    a._timer = false
    a["Explored?"] = true
    if a.Marker and a.Marker._valid then event_explored(a.Marker) end
    W.xp = W.xp + 250
    W.toasts = W.toasts + 1
    return true
end

local function respawn_markers(player0_pawn)      -- RespawnMarker on every manager (after its Delay 2)
    for _, a in ipairs(W.pois) do build_marker(a, player0_pawn) end
end

local function on_map(a, mw)                      -- the place's newest marker on map `mw`
    local last = nil
    for _, w in ipairs(mw.list) do if w["Target Actor"] == a then last = w end end
    return last
end

-- ------------------------------------------------------------- module mocks
local LOGS = {}
package.preload["sdc_log"] = function()
    local L = {}
    local function put(lvl)
        return function(fmt, ...)
            local s = string.format(fmt, ...)
            LOGS[#LOGS + 1] = lvl .. " " .. s
            print("    [" .. lvl .. "] " .. s)
        end
    end
    L.info, L.warn, L.err, L.debug = put("I"), put("W"), put("E"), function() end
    L.err_throttled = function(_, fmt, ...)
        put("E!")(fmt, ...)
        fails = fails + 1
    end
    return L
end
local loops = {}
local PAWN = nil
local LOADED = true   -- W_POIMarker_C is in memory (StaticFindObject finds its function)
package.preload["sdc_ue"] = function()
    local U = {}
    U.valid = function(o) return type(o) == "table" and o._valid == true end
    U.prop = function(o, k) if not U.valid(o) then return nil end return o[k] end
    U.set_prop = function(o, k, v) if not U.valid(o) then return false end o[k] = v; return true end
    U.short = function(o) return U.valid(o) and o._name or "<none>" end
    U.str = function(v) if type(v) == "string" then return v end return tostring(v or "") end
    U.try = function(f, ...) local ok, v = pcall(f, ...) if ok then return v end end
    U.find_all = function(c)
        assert(c == "BP_POIManager_C", "mock: FindAllOf " .. tostring(c))
        W.finds = W.finds + 1
        local out = {}
        for _, a in ipairs(W.pois) do out[#out + 1] = a end
        return out
    end
    U.find_object = function(p) if p == EXPLORED_FN and LOADED then return { _valid = true } end return nil end
    U.local_pawn = function() return PAWN end
    U.every = function(label, _, fn) loops[label] = fn end
    return U
end

local function has_log(pat, from)
    for i = from or 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return true end end
    return false
end

local pm = require("sdc_poimarks")
local S = { role = "host", remote = {}, in_menu = false }
pm.install(S)
local function tick(s)
    for _ = 1, s do
        CLK = CLK + 1
        loops.poimarks()
    end
end

-- ======================================================================
print("1. host world: 20 places, Pinewood and Gas Station explored; the host's map has their markers")
local mw1 = new_map()
PAWN = new_pawn(mw1)
local names = { "Pinewood", "Gas Station", "Ellwood", "Wilson's Shop", "Roadside Building" }
for i = 1, 20 do W.pois[i] = new_poi(i, names[i] or ("Place " .. i), i <= 2) end
respawn_markers(PAWN)   -- BeginPlay's markers
local P = W.pois
check(loops.poimarks ~= nil, "poimarks loop scheduled")
check(P[1].Marker.vis == 4 and P[3].Marker.vis == 2, "explored places shown, the others hidden (the game)")
tick(30)
check(W.finds == 0, "no remote player yet: no guard pass at all (solo costs nothing)")
check(hook_calls == 0, "nothing dimmed: EventExplored not hooked")

print("2. a client joins: the guard runs every 5 s; the first pass indexes the host's map, then nothing to do")
S.remote = { c1 = { name = "Client" } }
tick(1)
check(has_log("a remote player is here"), "log: guard armed")
tick(5)
local f1, fe1 = W.finds, mw1.foreach_n
check(f1 >= 1 and fe1 == 1, "first pass: one FindAllOf, one read of the map's marker list")
tick(10)
check(W.finds > f1 and mw1.foreach_n == fe1, "later passes: markers known to be on the map, the list not read again")
check(pm.stats.restored == 0, "nothing put back")

print("3. the client respawns through the game's flow: RespawnMarker with player 0 = the client")
local mw_r = new_map()
local rpawn = new_pawn(mw_r)          -- the remote character's server-side map (off-screen on the host)
local h_ell = P[3].Marker
respawn_markers(rpawn)
check(P[3].Marker.map == mw_r and P[1].Marker.map == mw_r, "the managers' Marker now points to the off-screen map (the bug)")
local xp0 = W.xp
check(walk_to(P[3]), "the host reaches Ellwood (DistanceCheck: player 0 = the host)")
check(W.xp == xp0 + 250 and W.toasts == 1, "XP and toast")
check(h_ell.vis == 2, "without the guard nothing shows on the host's map (what the host saw)")
local lg = #LOGS
tick(5)
check(pm.stats.restored == 20, "guard: all 20 markers put back on the host's map: " .. pm.stats.restored)
local all_home = true
for _, a in ipairs(P) do if a.Marker.map ~= mw1 then all_home = false end end
check(all_home, "every manager's Marker is its marker on the host's map again")
check(P[3].Marker == h_ell and h_ell.vis == 4 and h_ell["Explored?"] == true, "Ellwood (explored meanwhile) shown on the host's map")
check(has_log("place marker(s) were not on the host's map", lg) and has_log("1 explored by the host meanwhile now shown (Ellwood)", lg),
    "log: the repair, with the place explored meanwhile")
check(P[1].Marker.vis == 4 and P[1].Marker.events == 1, "Pinewood: its old marker, no second event")
check(#mw_r.list == 20 and #mw1.list == 20, "no marker made or moved: the off-screen ones stay there, the host's map has no doubles")
check(walk_to(P[4]) and P[4].Marker.map == mw1 and P[4].Marker.vis == 4, "the host's next discovery (Wilson's Shop) shows on its map at once")
local fe2 = mw1.foreach_n
tick(10)
check(mw1.foreach_n == fe2 and pm.stats.restored == 20, "quiet again: no index, nothing put back")

print("4. a respawn whose remote character had no map yet: Add POI Marker gives None")
local nomap = new_pawn(nil)
respawn_markers(nomap)
check(P[5].Marker == nil, "the managers' Marker = None")
tick(5)
check(pm.stats.restored == 40 and P[5].Marker == on_map(P[5], mw1), "guard: put back from the host's map (None case)")

print("5. the host's own respawn: new character, new map; the game's own rebuild comes 2 s later")
local mw2 = new_map()
PAWN = new_pawn(mw2)
local r0 = pm.stats.restored
tick(5)
check(pm.stats.restored == r0 and P[1].Marker.map == mw1, "new map still empty: nothing moved back to the old map")
respawn_markers(PAWN)
tick(5)
check(pm.stats.restored == r0, "after the game's rebuild: every marker on the new map, nothing to do")
check(P[1].Marker.map == mw2 and P[1].Marker.vis == 4 and P[5].Marker.vis == 2, "explored shown, unexplored hidden (the game)")

print("6. a place shown from another player: dimmed; the own discovery gives the full marker (hook)")
local roadside = P[5].Marker
P[5].Marker["Explored?"] = true; P[5].Marker.vis = 4      -- what sdc_persist SHARE.mark did (EventExplored)
check(pm.dim(roadside, true) and roadside.opacity == pm.DIM, "dim: RenderOpacity " .. tostring(pm.DIM))
local sets = opacity_sets
check(pm.dim(roadside) and opacity_sets == sets, "dimmed again (\"had\"): no engine call")
check(pm.dim(roadside, true) and opacity_sets == sets + 1, "forced (a rebuilt marker): set again")
tick(1)
check(hook_calls == 1 and HOOKS[EXPLORED_FN] and has_log("hook W_POIMarker_C:EventExplored (post) ok"), "hooked once something is dimmed")
tick(20)
check(hook_calls == 1, "hooked once")
event_explored(roadside)                                   -- the share's own call again: place not explored here
check(roadside.opacity == pm.DIM, "the share's own EventExplored keeps it dimmed")
local lg2 = #LOGS
check(walk_to(P[5]), "the host reaches Roadside Building (the game's discovery)")
check(roadside.opacity == 1.0 and W.xp == xp0 + 750 and W.toasts == 3, "full marker at once (hook), XP and toast once")
check(has_log("Roadside Building explored by this player: the game's own full marker", lg2), "log: undimmed by the hook")
check(not walk_to(P[5]) and W.toasts == 3, "no second discovery")
check(not pm.undim(roadside, true), "undim again: nothing to do")
-- a dimmed marker the hook missed (opacity read)
local m6 = P[6].Marker
m6.opacity = 0.3
check(pm.undim(m6, true) and m6.opacity == 1.0, "undim(check): a dimmed marker not known here is read and restored")
check(not pm.undim(P[7].Marker) and P[7].Marker.opacity == 1.0, "undim without check: unknown marker untouched")

print("7. a dimmed place the host reaches while its marker is on the off-screen map")
local m8 = P[8].Marker
m8["Explored?"] = true; m8.vis = 4
pm.dim(m8, true)
local mw_r2 = new_map()
respawn_markers(new_pawn(mw_r2))          -- another remote respawn
check(walk_to(P[8]) and m8.opacity == pm.DIM, "discovery went to the off-screen marker: the host's stays dimmed")
tick(5)
check(P[8].Marker == m8 and m8.opacity == 1.0 and m8.vis == 4, "guard: marker put back and given the full look")

print("8. clients and solo worlds: no guard; a new world forgets everything")
local f2 = W.finds
S.role = "client"
tick(20)
check(W.finds == f2, "client: no guard pass")
S.role = "host"
pm.reset("test")
S.remote = {}
tick(20)
check(W.finds == f2, "after a world reset with nobody here: not armed")
check(next(pm._st.dimmed) == nil, "dimmed set forgotten")
S.remote = { c1 = {} }
S.in_menu = true
tick(20)
check(W.finds == f2, "host dead / in the menu: no pass")
S.in_menu = false
tick(6)
check(W.finds > f2, "alive again: passes")
check(pm.status():find("host_restored=", 1, true) ~= nil, "status line")

print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
