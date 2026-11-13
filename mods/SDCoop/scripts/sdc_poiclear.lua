-- SDCoop: clearing a major place (its boss and its special container)
-- counts for a client too, and every player's map shows it as the host's
-- world has it.
--
-- What it is in the game (work\re\pseudo\BP_POIManager.txt, BP_ZombieBoss.txt,
-- BP_LootContainer.txt, GameFunctionLibrary.txt; work\re\pseudo_poiclear\
-- W_POIMarkerTooltip.txt, Container_POICrate.txt):
--   * Every named place on the map is a level-placed BP_POIManager_C, not
--     replicated: each machine runs its own copy (same actor names). A MAJOR
--     one (Struct_POI.IsAMajorPOI?) has two goals, shown only in its map
--     marker's tooltip (W_POIMarkerTooltip.POIBossAmount "{A}/{B}" + " POI
--     Boss Defeated", POIContainer "0/1 Special Container Looted"). No
--     journal quest, no notice of its own.
--   * Bosses: 10 s after BeginPlay (+ InitialSpawnDelay, once any player is
--     within 120 m: IsAnyInvokerInRadius) the manager spawns BossToSpawn
--     (@340) and binds each BP_ZombieBoss's BossDeath to its own BossDeath
--     (@724-822). BP_ZombieBoss broadcasts BossDeath only from DeathEvent, a
--     server RPC (@7205 -> 7043). The manager's BossDeath (@10815-11649):
--     BossesDefeated + 1, the tooltip "{clamp(BossesDefeated, 0,
--     SpawnAmount)}/{SpawnAmount}", SpawnAmount - 1 (then the respawn timer
--     of Difficulty.RespawnPOIBosses). No XP of its own: the kill's XP is the
--     boss's (sdc_ai_kills credits the killer).
--   * Special container: the manager spawns Container_POICrate at its own
--     location + ContainerLocation (@2755-3221; rotation not applied to the
--     offset) and binds the crate's Looted to Event_Looted (@3273-3296).
--     BP_LootContainer broadcasts Looted in OpenContainer (@5560 -> 4845 ->
--     4710 -> 4459), on the machine whose player opened the window.
--     Event_Looted (@9884-10232): once per place (UniqueContainerLooted?),
--     XP = CurrentLevel x Random(75, 150) x MultiplyValue (XpMultiplierCalc)
--     for player 0 (GetLevellingComponent -> CastToController), and the
--     tooltip "1/1 Special Container Looted" (@10084).
--   * BossesDefeated and UniqueContainerLooted? are CPF_SaveGame (the host's
--     Level.sav); SpawnAmount is not. A load gives them back through
--     ActorLoaded (@10293 -> 10238: 5 s -> 8332): both tooltip texts, the
--     crate destroyed when it was searched, and (Explored?) the marker.
-- Why a client's did not count (the host's did):
--   * sdc_world blocks a client's own spawns of its manager copies (bosses,
--     crate: the host's replicate), so nothing is bound on the client: the
--     host's boss dies on the host (BossDeath counts on the HOST's copy
--     only), and a client opening the host's crate broadcasts Looted on its
--     copy of that crate, bound to nothing: no XP, no "1/1", and the host's
--     manager never heard of it either (UniqueContainerLooted? stayed false
--     in the save, the crate came back after a load);
--   * a client's copies start from the level's defaults on every join (its
--     world is never loaded from the host's save): what the host's world had
--     cleared showed as not cleared there.
-- Here (config world_poi_clear, under world_sync):
--   client OpenContainer (post) of a Container_POICrate: this machine's copy
--          of the major place whose crate stands there runs the game's
--          Event_Looted (its XP on this player's own progression, the map
--          text), then POICL to the host. Once per place, as in the game: the
--          first search pays; a place already searched in the host's world
--          pays nothing again.
--   host   POICL (that player near the crate): its copy counted the game's
--          way without the XP (the looter's own machine paid it):
--          UniqueContainerLooted? = true (Event_Looted @9899, saved with the
--          world) and the tooltip text (@10084).
--   host   every POLL_S while clients are connected: the major places'
--          BossesDefeated / UniqueContainerLooted? (a boss killed by anyone,
--          the host's own search, a client's POICL); changes -> every client
--          (POIST).
--   client POIQ once in a world; the host answers POIST with every major
--          place that has a boss down or its container searched.
--   client POIST -> its copy gets the host's values (only ever up), then the
--          game's load path, ActorLoaded, puts them on the map. A marker the
--          game makes again later (RespawnMarker after a respawn, the late
--          client minimap) starts from the widget's defaults: the load path
--          runs again for it.
-- Messages:
--   POIST|why|id,bosses,looted;id,bosses,looted...   host -> client(s)  (why: l = live, j = join)
--   POICL|id                                          client -> host
--   POIQ                                              client -> host
-- Hooks: post only, wrapped in pcall, return nothing; parameters are read
-- inside the callback; no engine object is kept between calls (actor paths
-- and numbers only). The OpenContainer hook is a second callback on the
-- function sdc_world hooks too (UE4SS 3.0.1 adds it to the first).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = { opened = 0, paid = 0, again = 0, unmatched = 0, cl_sent = 0, cl_applied = 0, cl_known = 0,
              cl_refused = 0, changes = 0, msgs = 0, snapshots = 0, applied = 0, reshown = 0, missing = 0 },
}

local POI_CLASS = "BP_POIManager_C"
local CRATE_CLASS = "Container_POICrate_C"
local LOOT_CLS = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
local LOOT_FN = LOOT_CLS .. ":OpenContainer"
local F_MAJOR = "IsAMajorPOI?_11_A87DDB26439CC030B3170C9A49D4FDEB"   -- Struct_POI.IsAMajorPOI? (bool)
local F_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"             -- Struct_POI.Name (FString)
local P_BOSSES = "BossesDefeated"
local P_LOOTED = "UniqueContainerLooted?"
M.LOOTED_TEXT = "1/1 Special Container Looted"   -- Event_Looted @10084 / ActorLoaded @9164

local POLL_S = 2            -- host: the major places' state read this often while clients are connected
local PASS_S = 2            -- client: places waiting for their copy / marker, markers made again
local HOOK_RETRY_S = 2
local SNAP_AFTER_S = 3      -- client: in the world this long before asking for the state
local MAJORS_RETRY_S = 5    -- the list of major places made again at most this often
local CRATE_MATCH = 500     -- cm: an opened crate -> the major place whose crate stands there
local POI_MATCH = 15000     -- cm: ... or the nearest major place when its crate place is unknown
local REACH = 6000          -- cm: the host counts a search from a player this close to that crate
local MISS_TRIES = 15       -- client: passes a place the host named may be missing here
local CHUNK = 16            -- places per POIST

local clock = os.clock
local S
local st = {
    role = nil,
    hooked = false, hook_logged = false, hook_at = -100,
    majors = nil,        -- [id] = { path =, name =, loc =, crate = } this machine's major places
    nmajors = 0,
    majors_at = -100,
    -- host
    sent = {},           -- [id] = "bosses,looted" the clients were last told (the poll's baseline)
    poll_at = -100,
    -- client
    want = {},           -- [id] = { bd =, l =, why = } the host's world (and this player's own search)
    dirty = {},          -- [id] = misses: still to be put on this machine's copy
    shown = {},          -- [id] = address of the marker the load path last ran for
    told = {},           -- [id] = true: POICL sent in this world
    pass_at = -100,
    asked = nil, since = nil,
    opened = {},         -- places of crates opened here, waiting for the game thread
    level_timer = {},
}

local function on()
    return cfg.get("world_sync") ~= false and cfg.get("world_poi_clear") ~= false
end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function addr(o)
    if not ue.valid(o) then return nil end
    return ctx.addr(o)
end

local function num(v) return type(v) == "number" and v or nil end

local function v3(t)
    if t == nil then return nil end
    local x = num(ue.try(function() return t.X end))
    local y = num(ue.try(function() return t.Y end))
    local z = num(ue.try(function() return t.Z end))
    if x and y and z then return { X = x, Y = y, Z = z } end
    return nil
end

local function d2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function fmt_loc(l)
    if not l then return "?" end
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

-- level actor names ("BP_POIManager_C_127"); never a class default object
local function id_ok(id)
    return type(id) == "string" and #id > 0 and #id <= 96 and id:match("^[%w_%-%.]+$") ~= nil
        and id:find("^Default__") == nil
end

local function who_of(pc)
    local p = ue.pawn_of(pc)
    return p and ue.short(p) or ue.short(pc)
end

-- ---------------------------------------------------------------------------
-- Major places (both)
-- ---------------------------------------------------------------------------

local function field(s, f)
    if s == nil then return nil end
    return ue.try(function() return s[f] end)
end

-- A major place's path, name, location and its crate's place, or nil.
local function place_of(a)
    local s = ue.prop(a, "POI")
    if field(s, F_MAJOR) ~= true then return nil end
    local loc = ue.location(a)
    local crate = nil
    local tf = ue.prop(a, "ContainerLocation")
    local off = not ue.missing(tf) and v3(ue.try(function() return tf.Translation end)) or nil
    if loc and off then crate = { X = loc.X + off.X, Y = loc.Y + off.Y, Z = loc.Z + off.Z } end
    local name = ue.fstring(field(s, F_NAME)):gsub("[%c|;,]", " ")
    if name == "" then name = ue.short(a) end
    return { path = ue.path(a), name = name, loc = loc, crate = crate }
end

-- This machine's major places (one FindAllOf per world; again when one is
-- missing, at most every MAJORS_RETRY_S).
local function majors(now, force)
    if st.majors and not force then return st.majors end
    if now - st.majors_at < MAJORS_RETRY_S then return st.majors end
    st.majors_at = now
    local out, n, total = {}, 0, 0
    for _, a in ipairs(ue.find_all(POI_CLASS)) do
        if ue.valid(a) then
            total = total + 1
            local id = ue.short(a)
            if id_ok(id) then
                local p = place_of(a)
                if p then out[id] = p; n = n + 1 end
            end
        end
    end
    if total == 0 then return st.majors end
    local first = st.majors == nil
    st.majors, st.nmajors = out, n
    if first then
        log.info("poiclear: %d major place(s) (a boss and a special container) among the %d places of this world", n, total)
    end
    return out
end

-- This machine's copy of a major place, and its entry.
local function find_poi(id, now)
    local list = majors(now or clock())
    local e = list and list[id]
    if not e then
        list = majors(now or clock(), true)
        e = list and list[id]
        if not e then return nil, nil end
    end
    local a = ue.find_object(e.path)
    if a and ue.short(a) == id then return a, e end
    return nil, e
end

local function state_of(a)
    return math.floor(tonumber(ue.prop(a, P_BOSSES)) or 0), ue.prop(a, P_LOOTED) == true
end

local function entry(id, bd, l) return string.format("%s,%d,%d", id, bd, l and 1 or 0) end

local function parse_entries(s)
    local out = {}
    for part in tostring(s or ""):gmatch("[^;]+") do
        local id, bd, l = part:match("^([^,]+),(%d+),([01])$")
        if id and id_ok(id) then out[#out + 1] = { id = id, bd = tonumber(bd) or 0, l = l == "1" } end
    end
    return out
end

-- The marker tooltip's text block `fname` of place `a` (the game's widgets).
local function set_tooltip_text(a, fname, text)
    local m = ue.prop(a, "Marker")
    local tt = ue.valid(m) and ue.prop(m, "MarkerTooltip") or nil
    local tb = ue.valid(tt) and ue.prop(tt, fname) or nil
    if not ue.valid(tb) or not FText then return false end
    return (pcall(function() tb:SetText(FText(text)) end))
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function remote_pcs() return (S and S.remote_pcs) or {} end

local function send_entries(pcs, why, entries)
    local n = 0
    for i = 1, #entries, CHUNK do
        local part = table.concat(entries, ";", i, math.min(#entries, i + CHUNK - 1))
        for _, pc in ipairs(pcs) do
            if net.send_to(pc, "POIST", why, part) then n = n + 1 end
        end
    end
    M.stats.msgs = M.stats.msgs + n
    return n
end

-- Every POLL_S while clients are connected: what changed goes to all of them.
local function host_poll(now)
    if #remote_pcs() == 0 or now - st.poll_at < POLL_S then return end
    st.poll_at = now
    local list = majors(now)
    if not list then return end
    local changed, lines = {}, {}
    for id, e in pairs(list) do
        local a = ue.find_object(e.path)
        if a then
            local bd, l = state_of(a)
            local key = bd .. "," .. (l and 1 or 0)
            local prev = st.sent[id]
            st.sent[id] = key
            if prev ~= nil and prev ~= key then
                changed[#changed + 1] = entry(id, bd, l)
                local pb, pl = prev:match("^(%d+),(%d)$")
                lines[#lines + 1] = string.format("%s (%s): bosses defeated %s -> %d, special container searched %s -> %s",
                    e.name, id, tostring(pb), bd, pl == "1" and "yes" or "no", l and "yes" or "no")
            end
        end
    end
    if #changed == 0 then return end
    table.sort(changed)
    table.sort(lines)
    local pcs = remote_pcs()
    send_entries(pcs, "l", changed)
    M.stats.changes = M.stats.changes + #changed
    log.info("poiclear: host: %s - sent to %d client(s) (POIST)", table.concat(lines, "; "), #pcs)
end

-- POIQ (client -> host): every major place with a boss down or its
-- container searched.
local function snap_msg(_, pc)
    if not S or S.role ~= "host" then return end
    if not on() then
        log.info("poiclear: host: %s asked for the major places' state: ignored (world_poi_clear or world_sync off)", who_of(pc))
        return
    end
    local list = majors(clock(), st.majors == nil)
    if not list then
        log.warn("poiclear: host: %s asked for the major places' state, but no place is in this world yet", who_of(pc))
        return
    end
    local entries = {}
    for id, e in pairs(list) do
        local a = ue.find_object(e.path)
        if a then
            local bd, l = state_of(a)
            if bd > 0 or l then entries[#entries + 1] = entry(id, bd, l) end
        end
    end
    table.sort(entries)
    if #entries > 0 then send_entries({ pc }, "j", entries) end
    M.stats.snapshots = M.stats.snapshots + 1
    log.info("poiclear: host: %s asked for the major places' state: %d of %d with a boss down or the special container searched%s",
        who_of(pc), #entries, st.nmajors, #entries > 0 and ", sent (POIST)" or "")
end

-- POICL|id (client -> host): that player searched the place's special
-- container first on its machine (the game's Event_Looted ran there).
local function cl_msg(f, pc)
    if not S or S.role ~= "host" then return end
    local who = who_of(pc)
    if not on() then
        log.info("poiclear: host: %s searched a special container: ignored (world_poi_clear or world_sync off)", who)
        return
    end
    local id = f[1]
    if not id_ok(id) then return end
    local a, e = find_poi(id)
    if not a then
        log.warn("poiclear: host: %s searched the special container of %s, but the host has no such major place: not counted",
            who, id)
        return
    end
    local _, l = state_of(a)
    if l then
        M.stats.cl_known = M.stats.cl_known + 1
        log.info("poiclear: host: %s searched the special container of %s (%s): already counted in the host's world", who,
            e.name, id)
        return
    end
    local at = e.crate or e.loc
    local lim = e.crate and REACH or POI_MATCH
    local pl = ue.location(ue.pawn_of(pc))
    if not (pl and at and d2(pl, at) <= lim * lim) then
        -- (nothing goes back: a client's values only ever go up, its own search stays on its screen)
        M.stats.cl_refused = M.stats.cl_refused + 1
        log.warn("poiclear: host: %s searched the special container of %s (%s) but is not near it here (%s, container at %s): not counted in the host's world (that player's own copy keeps its search)",
            who, e.name, id, fmt_loc(pl), fmt_loc(at))
        return
    end
    local ok = ue.set_prop(a, P_LOOTED, true)
    local txt = ok and set_tooltip_text(a, "POIContainer", M.LOOTED_TEXT)
    M.stats.cl_applied = M.stats.cl_applied + 1
    log.info("poiclear: host: %s searched the special container of %s (%s) first: counted in the host's world as the game's Event_Looted does (UniqueContainerLooted? = %s, saved with the world; map text %s); its XP is that player's, paid on its own machine",
        who, e.name, id, tostring(ue.prop(a, P_LOOTED) == true), txt and "set" or "not set (no marker here yet)")
    st.poll_at = -100   -- every client hears of it at the next tick
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- The XP bar's timer (moves added XP into the bar; sdc_ai_kills, sdc_world
-- and sdc_quests start it the same way). Once per controller.
local function level_timer(comp)
    if not ue.valid(comp) then return end
    local key = ue.name(comp)
    if st.level_timer[key] then return end
    st.level_timer[key] = true
    ue.call(comp, "Event_LevelBarTimer")
end

-- The major place whose crate stands at `loc` (the crate's place first, then
-- the nearest place itself when a crate place is unknown).
local function match_crate(loc, now)
    local list = majors(now)
    if not list or not loc then return nil end
    local best, bd2 = nil, nil
    for id, e in pairs(list) do
        if e.crate then
            local d = d2(e.crate, loc)
            if d <= CRATE_MATCH * CRATE_MATCH and (bd2 == nil or d < bd2) then best, bd2 = id, d end
        end
    end
    if best then return best, math.sqrt(bd2) end
    for id, e in pairs(list) do
        if not e.crate and e.loc then
            local d = d2(e.loc, loc)
            if d <= POI_MATCH * POI_MATCH and (bd2 == nil or d < bd2) then best, bd2 = id, d end
        end
    end
    if best then return best, math.sqrt(bd2) end
    return nil
end

-- A special container searched on this machine (its window opened here).
local function client_looted(loc)
    local now = clock()
    local id, dist = match_crate(loc, now)
    if not id then
        M.stats.unmatched = M.stats.unmatched + 1
        log.warn("poiclear: a special container was searched here at %s, but no major place's container stands there: nothing counted",
            fmt_loc(loc))
        return
    end
    local a, e = find_poi(id, now)
    if not a then
        M.stats.unmatched = M.stats.unmatched + 1
        log.warn("poiclear: the special container of %s was searched here, but this machine has no copy of that place: nothing counted", id)
        return
    end
    local _, was = state_of(a)
    local xp, err = nil, nil
    if not was then
        local comp = ue.prop(ue.local_pc(), "LevellingComponent")
        level_timer(comp)
        local before = num(ue.prop(comp, "BufferXP"))
        local ok, e2 = pcall(function() a:Event_Looted() end)
        if not ok then err = tostring(e2) end
        local after = num(ue.prop(comp, "BufferXP"))
        if before and after then xp = after - before end
    end
    local _, now_l = state_of(a)
    local w = st.want[id] or { bd = 0, l = false }
    w.l = w.l or now_l
    w.why = w.why or "own search"
    st.want[id] = w
    local m = ue.prop(a, "Marker")
    if st.shown[id] == nil and ue.valid(m) then st.shown[id] = addr(m) end
    local first_tell = not st.told[id]
    if first_tell and net.send_to_host("POICL", id) then
        st.told[id] = true
        M.stats.cl_sent = M.stats.cl_sent + 1
    end
    if was then
        M.stats.again = M.stats.again + 1
        local line = string.format("poiclear: the special container of %s (%s) searched here: already searched in this world before (no XP again, as in the game)%s",
            e.name, id, first_tell and "; the host is told (POICL)" or "")
        if first_tell then log.info("%s", line) else log.debug("%s", line) end
        return
    end
    if now_l then M.stats.paid = M.stats.paid + 1 end
    log.info("poiclear: the special container of %s (%s) searched here first (%.0f m from its place): the game's Event_Looted ran on this machine's copy (XP %s, special container searched=%s, map text '%s'); the host counts it in its world (POICL)%s",
        e.name, id, (dist or 0) / 100, xp and string.format("+%.0f", xp) or "?", tostring(now_l), M.LOOTED_TEXT,
        err and (" - Event_Looted FAILED: " .. err) or "")
end

-- Crates opened here since the last call (the hook queues them; run on the
-- game thread right after the hook, or from the tick).
function M.process_opened()
    local list = st.opened
    if #list == 0 then return end
    st.opened = {}
    for _, loc in ipairs(list) do
        M.stats.opened = M.stats.opened + 1
        local ok, err = pcall(client_looted, loc)
        if not ok then log.err_throttled("poiclear.looted", "poiclear: special container: %s", tostring(err)) end
    end
end

-- BP_LootContainer.OpenContainer (post), client: this player opened a
-- container's window here. Only the major places' crates matter.
local function on_open(c)
    if not S or S.role ~= "client" or not on() then return end
    local box = pget(c)
    if not ue.valid(box) or ue.class_name(box) ~= CRATE_CLASS then return end
    local loc = ue.location(box)
    if not loc then return end
    st.opened[#st.opened + 1] = loc
    ue.delay("poiclear-open", 100, M.process_opened)
end

-- The host's values onto this machine's copy, then the game's load path
-- (ActorLoaded: both tooltip texts 5 s later). False: wait (no marker yet).
local function apply_one(id, a, e, w)
    if not w then return true end
    local bd, l = state_of(a)
    local what = {}
    if w.bd > bd and ue.set_prop(a, P_BOSSES, w.bd) then
        what[#what + 1] = string.format("bosses defeated %d -> %d", bd, w.bd)
    end
    if w.l and not l and ue.set_prop(a, P_LOOTED, true) then what[#what + 1] = "special container searched" end
    local m = ue.prop(a, "Marker")
    if not ue.valid(m) then
        if #what > 0 then
            log.info("poiclear: %s (%s) here as in the host's world (%s): %s; its map marker is not made yet: shown once it is",
                e.name, id, w.why or "?", table.concat(what, ", "))
        end
        return false
    end
    local ma = addr(m)
    if #what == 0 and st.shown[id] == ma then return true end
    local ok, err = pcall(function() a:ActorLoaded() end)
    st.shown[id] = ma
    M.stats.applied = M.stats.applied + 1
    log.info("poiclear: %s (%s) here as in the host's world (%s): %s; the game's load path (ActorLoaded) puts it on the map%s",
        e.name, id, w.why or "?", #what > 0 and table.concat(what, ", ") or "its values were set here before",
        ok and "" or (" - FAILED: " .. tostring(err)))
    return true
end

local function client_apply(now)
    if next(st.dirty) == nil then return end
    for id, misses in pairs(st.dirty) do
        local a, e = find_poi(id, now)
        if a then
            if apply_one(id, a, e, st.want[id]) then st.dirty[id] = nil end
        elseif misses + 1 >= MISS_TRIES then
            st.dirty[id] = nil
            M.stats.missing = M.stats.missing + 1
            log.warn("poiclear: the host's major place %s is not in this world here: its state not shown", id)
        else
            st.dirty[id] = misses + 1
        end
    end
end

-- A marker the game made again (RespawnMarker: a respawn, the late client
-- minimap) shows the widget's defaults: the load path runs again for it.
local function client_reshow(now)
    for id, ma in pairs(st.shown) do
        if not st.dirty[id] then
            local a, e = find_poi(id, now)
            local m = a and ue.prop(a, "Marker") or nil
            if ue.valid(m) then
                local na = addr(m)
                if na ~= ma then
                    st.shown[id] = na
                    local ok = pcall(function() a:ActorLoaded() end)
                    M.stats.reshown = M.stats.reshown + 1
                    log.info("poiclear: %s (%s): the game made its map marker again: the load path shows its state again%s",
                        e and e.name or "?", id, ok and "" or " - FAILED")
                end
            end
        end
    end
end

-- POIST|why|entries (host -> client): the host's world.
local function st_msg(f)
    if not S or S.role ~= "client" or not on() then return end
    local why = f[1] == "j" and "join" or "live"
    local n = 0
    for _, en in ipairs(parse_entries(f[2])) do
        local w = st.want[en.id] or { bd = 0, l = false }
        w.bd = math.max(w.bd, en.bd)
        w.l = w.l or en.l
        w.why = why
        st.want[en.id] = w
        if st.dirty[en.id] == nil then st.dirty[en.id] = 0 end
        n = n + 1
    end
    if n > 0 then client_apply(clock()) end
end

-- Once per world (in it for SNAP_AFTER_S with the own character): POIQ.
local function client_ask(now)
    local cs = S.client
    if not (cs and cs.acked == true) or not ue.local_pawn() then return end
    local key = tostring(S.map) .. "|" .. tostring(cs.pc_key)
    if st.asked == key then return end
    if not st.since or st.since.key ~= key then
        st.since = { key = key, t = now }
        return
    end
    if now - st.since.t < SNAP_AFTER_S then return end
    if net.send_to_host("POIQ") then
        st.asked = key
        log.info("poiclear: asked the host for the major places' state (POIQ)")
    end
end

-- The OpenContainer hook (client): the loot container class exists once a
-- container is loaded; tried every HOOK_RETRY_S until it is in.
local function try_hook(now)
    if st.hooked or now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    if not ue.find_object(LOOT_CLS) then return end
    local ok, err = pcall(RegisterHook, LOOT_FN, function(...)
        local okc, e = pcall(on_open, ...)
        if not okc then log.err_throttled("poiclear.open", "poiclear: OpenContainer hook: %s", tostring(e)) end
    end)
    if ok then
        st.hooked = true
        log.info("poiclear: hook BP_LootContainer_C:OpenContainer ok (a special container searched here)")
    elseif not st.hook_logged then
        st.hook_logged = true
        log.warn("poiclear: cannot hook BP_LootContainer_C:OpenContainer yet (%s); retried", tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Tick, reset, install
-- ---------------------------------------------------------------------------

local function tick()
    if not S then return end
    local role = S.role
    if role ~= st.role then
        if st.role ~= nil then M.reset("role " .. tostring(st.role) .. " -> " .. tostring(role)) end
        st.role = role
    end
    if not on() then return end
    local now = clock()
    if role == "host" then
        host_poll(now)
    elseif role == "client" then
        try_hook(now)
        if #st.opened > 0 then M.process_opened() end
        client_ask(now)
        if now - st.pass_at >= PASS_S then
            st.pass_at = now
            client_apply(now)
            client_reshow(now)
        end
    end
end

-- main.lua, every 500 ms (any role).
function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("poiclear.tick", "poiclear: tick: %s", tostring(err)) end
end

-- World change / role change: every place and state belonged to the old world.
function M.reset(why)
    st.majors, st.nmajors, st.majors_at = nil, 0, -100
    st.sent, st.poll_at = {}, -100
    st.want, st.dirty, st.shown, st.told = {}, {}, {}, {}
    st.pass_at, st.asked, st.since = -100, nil, nil
    st.opened, st.level_timer = {}, {}
    log.debug("poiclear: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    net.on("POIST", st_msg)
    net.on("POICL", cl_msg)
    net.on("POIQ", snap_msg)
    log.info("poiclear: installed (world_poi_clear=%s): a client's search of a major place's special container runs the game's Event_Looted on its own machine (its XP, map text) and counts in the host's world (POICL); bosses down and containers searched in the host's world show on every client's map (POIST, POIQ on join; the game's load path ActorLoaded)",
        tostring(on()))
end

function M.status_line()
    local s = M.stats
    local waiting = 0
    for _ in pairs(st.dirty) do waiting = waiting + 1 end
    return string.format("poiclear: on=%s hook=%s majors=%d | client: crates searched here=%d (paid %d, again %d, no place %d), told host=%d, places shown=%d (again %d), waiting=%d, missing=%d | host: clients' searches counted=%d (known %d, refused %d), changes sent=%d (%d msgs), snapshots=%d",
        tostring(on()), tostring(st.hooked), st.nmajors, s.opened, s.paid, s.again, s.unmatched, s.cl_sent, s.applied,
        s.reshown, waiting, s.missing, s.cl_applied, s.cl_known, s.cl_refused, s.changes, s.msgs, s.snapshots)
end

-- tests
M._st = st
M.parse_entries = parse_entries

return M
