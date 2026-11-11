-- Mock harness for map_shared (sdc_persist: shared map discoveries). Three
-- machines - host H, clients A and B - each with its OWN instance of
-- sdc_persist (loaded once per machine) and its own copies of the places
-- (BP_POIManager_C, not replicated). The fake game follows
-- work\re\pseudo\BP_POIManager.txt / W_POIMarker.txt:
--   * the marker widget is made with the MANAGER's Explored? (MapWidget.
--     AddPOICreatedMarker), Hidden; RespawnMarker makes a new one;
--   * W_POIMarker.EventExplored (@249/@265): SetVisibility(4) + the
--     widget's own Explored?;
--   * DistanceCheck (@242-604) while its timer runs and player 0 is there:
--     clear the timer, manager Explored? = true, the marker event, AddXP
--     250, HUD.DiscoverPOI (toast);
--   * ActorLoaded (load path @8332): marker event + K2_ClearTimer.
-- A place shown from another player is dimmed (sdc_poimarks: RenderOpacity)
-- until this machine's own discovery; here without the EventExplored hook
-- (find_object finds nothing), so the persist passes undim.
-- Nothing is written to disk (no LOCALAPPDATA: records live in memory).
-- usage: lua mock_map_shared.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    print((c and "  ok   " or "  FAIL ") .. what)
    if not c then fails = fails + 1 end
end

-- ------------------------------------------------------------- time, env
local NOW = 2000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end
local CLK = 50.0
os.clock = function() return CLK end
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return nil end return real_getenv(k) end

-- ------------------------------------------------------------- fake objects
local nobj = 0
local function obj(class, t)
    nobj = nobj + 1
    t = t or {}
    t._class, t._valid, t._addr = class, true, 0x20000 + nobj * 16
    t._name = t._name or (class .. "_" .. nobj)
    t.GetAddress = function(self) return self._addr end
    t.IsValid = function(self) return self._valid end
    return t
end

local POI_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"

-- MapWidget.AddPOICreatedMarker: a new W_POIMarker with the manager's Explored?, Hidden
local function new_marker(a)
    local w = obj("W_POIMarker_C", { ["Explored?"] = a["Explored?"] == true, vis = 2, events = 0, opacity = 1.0 })
    w.EventExplored = function(self)                   -- @249 SetVisibility(4), @265 Explored? = true
        self.vis = 4
        self["Explored?"] = true
        self.events = self.events + 1
    end
    w.SetRenderOpacity = function(self, v) self.opacity = v end
    w.GetRenderOpacity = function(self) return self.opacity end
    return w
end

local CUR = nil   -- the machine whose code runs now

local function new_poi(m, i, name, explored)
    local a = obj("BP_POIManager_C", { _name = "BP_POIManager_C_" .. i, ["Explored?"] = explored == true,
        POI = { [POI_NAME] = name }, _timer = explored ~= true, _m = m })
    a.Marker = new_marker(a)
    if explored then a.Marker:EventExplored() end      -- the save's load path showed it
    a.ActorLoaded = function(self)                     -- @8332: if Explored? the marker event; clear the timer
        if self["Explored?"] and self.Marker and self.Marker._valid then self.Marker:EventExplored() end
        self._timer = false
    end
    a.RespawnMarker = function(self)                   -- @9879 -> 3548: a new widget; @5370 event if explored
        if self.Marker then self.Marker._valid = false end
        self.Marker = new_marker(self)
        if self["Explored?"] then self.Marker:EventExplored() end
    end
    return a
end

-- DistanceCheck with this machine's player 0 at the place (@0-649)
local function walk_to(m, i)
    local a = m.poi[i]
    if not a._timer then return false end
    a._timer = false                                   -- @242 K2_ClearTimer "DistanceCheck"
    a["Explored?"] = true                              -- @268
    if a.Marker and a.Marker._valid then a.Marker:EventExplored() end   -- @279
    m.xp = m.xp + 250                                  -- @503 AddXP
    m.discover_toasts = m.discover_toasts + 1          -- @604 HUD.DiscoverPOI
    return true
end

-- ------------------------------------------------------------- machines
local function new_machine(name, role, opts)
    opts = opts or {}
    local m = { name = name, handlers = {}, loops = {}, logs = {}, toasts = {}, xp = 0, discover_toasts = 0,
        poi = {}, pois = {}, active = role == "host",
        S = { role = role, remote = {}, in_menu = false, client = role == "client" and { id = name } or nil },
        cfg = { persist_clients = true, persist_map = true, map_shared = true, persist_period = 120,
                persist_player_id = opts.guid or "" } }
    for k, v in pairs(opts.cfg or {}) do m.cfg[k] = v end
    m.pc = obj("BP_PlayerController_C", { _name = name .. "_LocalPC" })
    m.pawn = obj("BP_PlayerCharacter_C", { _name = name .. "_Char" })
    m.pc.pawn = m.pawn
    m.hostpc = obj("BP_PlayerController_C", { _name = "BP_PlayerController_C_" .. name })   -- on the host
    return m
end

local function add_places(m, explored)
    explored = explored or {}
    local named = { "Pinewood", "Gas Station", "Old Church", "Radio Tower", "Farm", "Quarry" }
    for i = 1, 50 do
        local a = new_poi(m, i, named[i] or ("Place " .. i), explored[i])
        m.poi[i] = a
        m.pois[#m.pois + 1] = a
    end
end

-- ------------------------------------------------------------- module mocks
local queue = {}
local function strs(...)
    local t = {}
    for i = 1, select("#", ...) do local v = select(i, ...); t[i] = v == nil and "" or tostring(v) end
    return t
end
local MACHINES = {}

package.preload["sdc_log"] = function()
    local L = { TEXT = {} }
    local function put(lvl)
        return function(fmt, ...)
            local s = string.format(fmt, ...)
            if CUR then CUR.logs[#CUR.logs + 1] = lvl .. " " .. s end
            print("    [" .. (CUR and CUR.name or "?") .. " " .. lvl .. "] " .. s)
        end
    end
    L.info, L.warn, L.err, L.debug = put("I"), put("W"), put("E"), function() end
    L.err_throttled = function(k, fmt, ...)
        if k == "persist-nodir" then return end   -- no LOCALAPPDATA here on purpose
        put("E!")(fmt, ...)
        fails = fails + 1
    end
    L.say = function(key, kind, s, ...) if CUR then CUR.toasts[#CUR.toasts + 1] = key end end
    return L
end
package.preload["sdc_config"] = function()
    local C = {}
    C.get = function(k) return CUR and CUR.cfg[k] end
    C.set = function(k, v) if CUR then CUR.cfg[k] = v end end
    C.save = function() end
    C.player_name = function() return CUR and CUR.name or "?" end
    return C
end
package.preload["sdc_net"] = function()
    local N = { handlers = {} }
    N.on = function(kind, h) CUR.handlers[kind] = h end
    N.send_to = function(pc, kind, ...)
        local to = nil
        for _, m in ipairs(MACHINES) do if m.hostpc == pc then to = m end end
        if not to then return false end
        queue[#queue + 1] = { from = CUR, to = to, kind = kind, f = strs(...), pc = to.pc }
        return true
    end
    N.send_to_host = function(kind, ...)
        local from = CUR
        queue[#queue + 1] = { from = from, to = MACHINES[1], kind = kind, f = strs(...), pc = from.hostpc }
        return true
    end
    return N
end
package.preload["sdc_ue"] = function()
    local U = {}
    U.valid = function(o) return type(o) == "table" and o._valid == true end
    U.prop = function(o, k) if not U.valid(o) then return nil end return o[k] end
    U.set_prop = function(o, k, v) if not U.valid(o) then return false end o[k] = v; return true end
    U.name = function(o) return U.valid(o) and o._name or "<none>" end
    U.short = U.name
    U.class_name = function(o) return U.valid(o) and o._class or "" end
    U.path = U.name
    U.str = function(v) if type(v) == "string" then return v end return tostring(v or "") end
    U.try = function(f, ...) local ok, v = pcall(f, ...) if ok then return v end end
    U.find_all = function(c)
        if c ~= "BP_POIManager_C" then error("mock: FindAllOf " .. tostring(c) .. " (only the POI managers are listed)") end
        CUR.finds = (CUR.finds or 0) + 1
        local out = {}
        for _, a in ipairs(CUR.pois) do out[#out + 1] = a end
        return out
    end
    U.find_object = function() return nil end
    U.ksl = function()
        return { K2_ClearTimer = function(_, a, fn) if fn == "DistanceCheck" then a._timer = false end end }
    end
    U.local_pc = function() return CUR.pc end
    U.pawn_of = function(pc) return pc and pc.pawn end
    U.in_main_menu = function() return false end
    U.ems_current_slot = function() return "MockSlot" end
    U.every = function(label, ms, fn) CUR.loops[label] = fn end
    U.delay = function() end
    U.location = function() return nil end
    U.gameplay_statics = function() return nil end
    U.load_asset = function() return nil end
    return U
end
package.loaded["sdc_players"] = {
    record_for = function(pc)
        for _, r in pairs(CUR.S.remote) do if r.pc == pc then return r end end
        return nil
    end,
}

local function load_persist(m)
    CUR = m
    package.loaded["sdc_persist"] = nil
    package.loaded["sdc_poimarks"] = nil   -- its own instance per machine too
    local mod = require("sdc_persist")
    package.loaded["sdc_persist"] = nil
    package.loaded["sdc_poimarks"] = nil
    mod.install(m.S)
    m.persist = mod
    CUR = nil
end

-- every message in order (handlers may send more)
local function pump()
    local guard = 0
    while #queue > 0 do
        guard = guard + 1
        assert(guard < 10000, "message storm")
        local q = table.remove(queue, 1)
        if q.to.active then
            q.to.got = q.to.got or {}
            q.to.got[#q.to.got + 1] = q
            local h = q.to.handlers[q.kind]
            if h then
                CUR = q.to
                h(q.f, q.pc)
                CUR = nil
            end
        end
    end
end

local function step(machines)
    NOW = NOW + 1
    CLK = CLK + 1
    for _, m in ipairs(machines) do
        if m.active then
            CUR = m
            m.loops.persist()
            CUR = nil
            pump()
        end
    end
end
local function run(machines, s) for _ = 1, s do step(machines) end end

local function connect(H, m)
    local r = { key = m.hostpc._name, pc = m.hostpc, name = m.name, index = #MACHINES, joined_at = NOW }
    H.S.remote[r.key] = r
    m.active = true
end

local function got(m, kind)
    local out = {}
    for _, q in ipairs(m.got or {}) do if q.kind == kind then out[#out + 1] = q end end
    return out
end
local function sent_from(m, kind)
    local out = {}
    for _, q in ipairs(m.sent_log or {}) do if q.kind == kind then out[#out + 1] = q end end
    return out
end
local function has_log(m, pat)
    for _, s in ipairs(m.logs) do if s:find(pat, 1, true) then return true end end
    return false
end
local function shown(a) return a.Marker._valid and a.Marker.vis == 4 and a.Marker["Explored?"] == true end
local function dimmed(a) return a.Marker._valid and a.Marker.opacity < 0.99 end   -- "seen by another player"
local function places_in(msgs)
    local n = 0
    for _, q in ipairs(msgs) do for _ in q.f[5]:gmatch("[^;]+") do n = n + 1 end end
    return n
end

-- ======================================================================
print("1. host H: explored Pinewood itself (Level.sav); records: Anna saved Gas Station, offline Olga 42 places")
local H = new_machine("Host", "host")
local A = new_machine("Anna", "client", { guid = "aaaaaaaaaaaaaaaaaaaa" })
local B = new_machine("Boris", "client", { guid = "bbbbbbbbbbbbbbbbbbbb" })
MACHINES = { H, A, B }
add_places(H, { [1] = true })
add_places(A)
add_places(B)
for _, m in ipairs(MACHINES) do load_persist(m) end
check(H.handlers.MAPSHARE and A.handlers.MAPSHARE and H.handlers.PSMAP, "MAPSHARE / PSMAP handlers registered (one instance per machine)")
run({ H }, 1)
local doc = H.persist._docs()["MockSlot"]
check(doc ~= nil, "host: the world's slot document (memory)")
doc.players["gaaaaaaaaaaaaaaaaaaaa"] = { key = "gaaaaaaaaaaaaaaaaaaaa", guid = "aaaaaaaaaaaaaaaaaaaa", name = "Anna",
    alive = true, why = "left", map = { BP_POIManager_C_2 = "Gas Station" } }
local olga = {}
olga.BP_POIManager_C_3 = "Old Church"
for i = 10, 50 do olga["BP_POIManager_C_" .. i] = "Place " .. i end
doc.players["s76561190000000055"] = { key = "s76561190000000055", name = "Olga", alive = true, why = "left", map = olga }
local f0 = H.finds or 0
run({ H }, 6)
check((H.finds or 0) > f0, "host pass lists the POI managers (others' places to show)")
check(H.poi[1]["Explored?"] == true and shown(H.poi[1]), "host's own Pinewood: explored, marker shown")
check(shown(H.poi[2]) and shown(H.poi[3]) and shown(H.poi[25]), "host shows Anna's / Olga's places from the records")
check(H.poi[2]["Explored?"] == false and H.poi[3]["Explored?"] == false, "host: those places are NOT explored (Level.sav untouched)")
check(H.poi[2]._timer == true and H.poi[3]._timer == true, "host: their DistanceCheck timers still run")
check(not shown(H.poi[4]) and not shown(H.poi[5]), "nobody's places stay hidden on the host")
check(dimmed(H.poi[2]) and dimmed(H.poi[3]) and dimmed(H.poi[25]), "host: the others' places are dimmed (seen by another player)")
check(not dimmed(H.poi[1]), "host: its own Pinewood has the game's full marker")
check(has_log(H, "map share: the host has 1 explored place(s) of its own"), "log: the host's own places counted once")

print("2. Anna joins (record: Gas Station): saved place restored, the others' shown without exploring")
connect(H, A)
run({ H, A }, 12)
local aset = got(A, "PSSET")
check(#aset == 1, "Anna: PSSET (record)")
local amap = got(A, "PSMAPSET")
check(#amap == 1 and amap[1].f[4] == "BP_POIManager_C_2=Gas Station", "Anna: PSMAPSET with her saved place")
local ashare = got(A, "MAPSHARE")
check(#ashare == 2 and ashare[1].f[4] == "full" and ashare[1].f[3] == "2", "Anna: the join list as 'full', in 2 messages (MAP_CHUNK)")
check(places_in(ashare) == 43, "Anna: 43 places (host's 1 + Olga's 42), not her own Gas Station: " .. places_in(ashare))
local own_sent = false
for _, q in ipairs(ashare) do if q.f[5]:find("BP_POIManager_C_2=", 1, true) then own_sent = true end end
check(not own_sent, "Anna's own saved place is not in the share list")
check(A.poi[2]["Explored?"] == true and A.poi[2]._timer == false, "Anna: Gas Station explored (the load path)")
check(shown(A.poi[1]) and shown(A.poi[3]) and shown(A.poi[50]), "Anna: Pinewood, Old Church, Place 50 shown")
check(A.poi[1]["Explored?"] == false and A.poi[1]._timer == true, "Anna: Pinewood NOT explored, its distance check runs")
check(A.xp == 0 and A.discover_toasts == 0, "no XP / discovery toast from the share")
check(dimmed(A.poi[1]) and dimmed(A.poi[3]) and dimmed(A.poi[50]), "Anna: the others' places dimmed")
check(not dimmed(A.poi[2]), "Anna: her own Gas Station full")
check(has_log(H, "map share with Anna (join): 43 place(s) explored by others sent to the client (2 message(s)); 1 place(s) only Anna explored"),
    "host log: once per join, both ways")
check(has_log(A, "map share (join): the host sent 43 place(s) other players explored (2 message(s))"), "client log: the join list")
check(has_log(A, "map share: 43 place(s) other players explored shown on this map (43 first time"), "client log: first application")

print("3. Anna explores Radio Tower: reported, shown on the host and sent to the others")
check(walk_to(A, 4), "Anna's DistanceCheck at Radio Tower")
local hpm0 = #got(H, "PSMAP")
run({ H, A }, 6)
local reps = got(H, "PSMAP")
check(#reps > hpm0 and reps[#reps].f[2] == "BP_POIManager_C_4=Radio Tower" and reps[#reps].f[3] == nil,
    "Anna reports it (PSMAP gen, places: no 'nosave', as before)")
check(shown(H.poi[4]) and H.poi[4]["Explored?"] == false and H.poi[4]._timer == true, "host: Radio Tower shown, not explored")
local hp = nil
for _, p in pairs(H.persist._P()) do if p.name == "Anna" then hp = p end end
check(hp and hp.map and hp.map.BP_POIManager_C_4 == "Radio Tower", "host: kept in Anna's record (persist_map)")
local adds_to_anna = 0
for _, q in ipairs(got(A, "MAPSHARE")) do if q.f[4] == "add" then adds_to_anna = adds_to_anna + 1 end end
check(adds_to_anna == 0, "Anna is not sent her own discovery back")

print("4. Boris joins (no record): the full list, then Anna's next discovery as an addition")
connect(H, B)
run({ H, A, B }, 12)
local bfull = got(B, "MAPSHARE")
check(#bfull == 2 and bfull[1].f[4] == "full" and bfull[2].f[4] == "full", "Boris: 'full' list in 2 messages")
check(places_in(bfull) == 45, "Boris: 45 places (host 1 + Anna 2 + Olga 42): " .. places_in(bfull))
check(shown(B.poi[1]) and shown(B.poi[2]) and shown(B.poi[4]) and shown(B.poi[30]), "Boris: everyone's places shown")
local bexp = 0
for i = 1, 50 do if B.poi[i]["Explored?"] then bexp = bexp + 1 end end
check(bexp == 0, "Boris: nothing explored")
check(has_log(H, "map share with Boris (join): 45 place(s) explored by others sent to the client (2 message(s)); 0 place(s) only Boris explored"),
    "host log: Boris's join, both ways")
-- Anna explores Farm: Boris gets one 'add' message
check(walk_to(A, 5), "Anna's DistanceCheck at Farm")
local bn0 = #got(B, "MAPSHARE")
run({ H, A, B }, 8)
local badd = {}
for i = bn0 + 1, #got(B, "MAPSHARE") do badd[#badd + 1] = got(B, "MAPSHARE")[i] end
check(#badd == 1 and badd[1].f[4] == "add" and badd[1].f[5] == "BP_POIManager_C_5=Farm", "Boris: one 'add' message with Farm")
check(shown(B.poi[5]) and B.poi[5]["Explored?"] == false, "Boris: Farm shown, not explored")
check(shown(H.poi[5]) and H.poi[5]["Explored?"] == false, "host: Farm shown, not explored")
run({ H, A, B }, 15)
check(#got(B, "MAPSHARE") == bn0 + 1, "no repeats while nothing new")

print("5. Boris reaches Pinewood (shown from the host): the game's discovery, XP once")
local ev0 = B.poi[1].Marker.events
check(walk_to(B, 1), "Boris's DistanceCheck at Pinewood (the timer still ran)")
check(B.xp == 250 and B.discover_toasts == 1, "XP 250 and the discovery toast, once")
check(not walk_to(B, 1) and B.xp == 250, "the timer is gone: no second XP")
check(shown(B.poi[1]) and B.poi[1].Marker.events == ev0 + 1, "the marker stays shown (the game's own event once more)")
run({ H, A, B }, 6)
local brep = got(H, "PSMAP")
check(brep[#brep].f[2] == "BP_POIManager_C_1=Pinewood", "Boris reports Pinewood as his own discovery")
check(has_log(B, "(1 of them had been shown from other players"), "client log: a shared place explored here")
check(not dimmed(B.poi[1]) and has_log(B, "the full marker; 1 undimmed by this pass"),
    "Boris: Pinewood has the full marker now (the pass; no hook in this harness)")
check(dimmed(B.poi[2]), "Boris: the places he did not reach stay dimmed")
check(B.persist._C().share.BP_POIManager_C_1 == nil, "Boris: Pinewood left the shared set (his own now)")
run({ H, A, B }, 10)
check(B.xp == 250, "still one XP grant")

print("6. markers rebuilt (respawn: RespawnMarker): shown again, still not explored")
H.poi[2]:RespawnMarker()
B.poi[3]:RespawnMarker()
check(not shown(H.poi[2]) and not shown(B.poi[3]), "the new widgets are hidden (manager Explored? false)")
run({ H, A, B }, 6)
check(shown(H.poi[2]) and H.poi[2]["Explored?"] == false, "host: Gas Station shown again, not explored")
check(dimmed(H.poi[2]) and dimmed(B.poi[3]), "the rebuilt markers are dimmed again")
check(shown(B.poi[3]) and B.poi[3]["Explored?"] == false and B.poi[3]._timer == true, "Boris: Old Church shown again, timer runs")
-- a marker not made yet (client minimap built late): waits, then shown
B.poi[6].Marker._valid = false
check(walk_to(A, 6), "Anna explores Quarry")
run({ H, A, B }, 8)
check(not B.poi[6].Marker._valid and B.poi[6]["Explored?"] == false, "Boris: no marker widget yet, nothing forced")
B.poi[6]:RespawnMarker()
run({ H, A, B }, 6)
check(shown(B.poi[6]) and B.poi[6]["Explored?"] == false, "Boris: Quarry shown once its marker exists")

print("7. the host explores a place only clients had: its own discovery, then shared as usual")
local hxp = H.xp
check(walk_to(H, 4), "host's DistanceCheck at Radio Tower (shown from Anna)")
check(H.xp == hxp + 250, "host: the game's XP")
run({ H, A, B }, 6)
check(has_log(H, "the host explored 1 place(s) itself that it had been shown from other players"), "host log: own discovery of a shared place")
check(not dimmed(H.poi[4]) and shown(H.poi[4]) and has_log(H, "the full marker; 1 undimmed by this pass"),
    "host: Radio Tower has the game's full marker now")
check(dimmed(H.poi[5]), "host: Farm (only Anna's) still dimmed")
-- host explores a place nobody had: Boris gets it as an addition
local hb0 = #got(B, "MAPSHARE")
check(walk_to(H, 7), "host explores Place 7")
run({ H, A, B }, 6)
local last_b = got(B, "MAPSHARE")[#got(B, "MAPSHARE")]
check(#got(B, "MAPSHARE") == hb0 + 1 and last_b.f[4] == "add" and last_b.f[5] == "BP_POIManager_C_7=Place 7", "Boris: the host's new place as one addition")
check(shown(A.poi[7]) and shown(B.poi[7]) and not A.poi[7]["Explored?"], "both clients show it, not explored")

print("8. the host's Level.sav flags: only what the host reached itself")
local hexp = {}
for i = 1, 50 do if H.poi[i]["Explored?"] then hexp[#hexp + 1] = i end end
check(#hexp == 3 and hexp[1] == 1 and hexp[2] == 4 and hexp[3] == 7, "host Explored?: Pinewood, Radio Tower, Place 7 only")
check(H.persist.status_line():find("share: places=", 1, true) ~= nil, "status line has the share counters")
local nmsg = #got(B, "MAPSHARE")
check(nmsg <= 6, "Boris got " .. nmsg .. " MAPSHARE message(s) in the whole session (batched)")

-- ======================================================================
print("9. map_shared off on the host: nothing shared (today's behaviour)")
local H2 = new_machine("Host2", "host", { cfg = { map_shared = false } })
local C2 = new_machine("Cleo", "client", { guid = "cccccccccccccccccccc" })
MACHINES = { H2, C2 }
add_places(H2, { [1] = true })
add_places(C2)
for _, m in ipairs(MACHINES) do load_persist(m) end
run({ H2 }, 2)
connect(H2, C2)
run({ H2, C2 }, 12)
check(walk_to(C2, 2), "Cleo explores Gas Station")
run({ H2, C2 }, 12)
check(#got(C2, "MAPSHARE") == 0, "no MAPSHARE to the client")
check(not shown(C2.poi[1]) and not shown(H2.poi[2]), "nobody's place shown on the other's map")
check(not dimmed(C2.poi[1]) and not dimmed(H2.poi[2]), "nothing dimmed with map_shared off")
check(#got(H2, "PSMAP") >= 1, "the client's report still reaches the host (persist_map)")
local cp = nil
for _, p in pairs(H2.persist._P()) do if p.name == "Cleo" then cp = p end end
check(cp and cp.map and cp.map.BP_POIManager_C_2 == "Gas Station", "and is kept in her record as before")
check((H2.finds or 0) == 0, "host: no POI listing at all with map_shared off")

print("10. map_shared off on a client: the list comes, nothing is shown there")
local H3 = new_machine("Host3", "host")
local D3 = new_machine("Dina", "client", { guid = "dddddddddddddddddddd", cfg = { map_shared = false } })
local E3 = new_machine("Egor", "client", { guid = "eeeeeeeeeeeeeeeeeeee", cfg = { persist_map = false } })
MACHINES = { H3, D3, E3 }
add_places(H3, { [1] = true, [2] = true })
add_places(D3)
add_places(E3)
for _, m in ipairs(MACHINES) do load_persist(m) end
run({ H3 }, 2)
connect(H3, D3)
connect(H3, E3)
run({ H3, D3, E3 }, 12)
check(#got(D3, "MAPSHARE") >= 1, "Dina gets the list (the host decides)")
check(not shown(D3.poi[1]) and not shown(D3.poi[2]), "Dina: nothing shown (map_shared off here)")
check(has_log(D3, "map_shared is off here: not shown"), "client log: off here")
check(shown(E3.poi[1]) and shown(E3.poi[2]), "Egor (persist_map off, map_shared on): the host's places shown")
check(walk_to(E3, 3), "Egor explores Old Church")
run({ H3, D3, E3 }, 8)
local er = got(H3, "PSMAP")
check(#er >= 1 and er[#er].f[3] == "nosave", "Egor's report is for the share only ('nosave')")
local ep = nil
for _, p in pairs(H3.persist._P()) do if p.name == "Egor" then ep = p end end
check(ep and (ep.map == nil or ep.map.BP_POIManager_C_3 == nil), "host keeps nothing in Egor's record")
check(shown(H3.poi[3]) and not H3.poi[3]["Explored?"], "host shows Egor's place anyway")
check(not shown(D3.poi[3]), "Dina still shows nothing")
check(not dimmed(D3.poi[1]) and dimmed(E3.poi[1]) and dimmed(H3.poi[3]), "dimmed only where shown (Egor, host), not on Dina")

print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
