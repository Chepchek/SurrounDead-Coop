-- SDCoop: a dead player's loot box (Container_DeadPlayerLoot) that has been
-- emptied disappears, on every machine.
-- Driven by sdc_containers (init / host_tick / client_tick / reset /
-- register_handlers).
--
-- The game (blueprints of 0.8, read 2026-11-11):
--   BP_PlayerCharacter.AfterDeath (server only) -> SpawnDeadPlayerLoot: spawns
--   Container_DeadPlayerLoot (bReplicates) and copies the dead character's
--   BP_JigMultiplayer.MainJigContainers / MainContainersIDs into the box's own
--   BP_JigMultiplayer: the 22 main containers (FACEWEAR .. FISHINGROD,
--   POCKETS; W_DeadPlayerLootUI shows exactly these) and the sub-containers of
--   the items in them (backpack, rig, pockets of clothes, weapons). All of it
--   lives on the host; a client's window gets it from SERVER_RequestData.
--   Taking an item out (Handle Comp to Comp Move, server) only removes it and
--   multicasts MC_ItemRemoved. Nothing in the game destroys the box: its own
--   graph destroys only its map marker (on open, after DelayUntilNextTick) and
--   the floating DeathWidget; BP_JigComponent.IsEmpty? has no caller in any
--   asset (headers of Blueprints, Inventory, JigSInventory, UI, AI, SmartAI
--   scanned), and only BP_PlayerCharacter refers to the class (to spawn it).
--   So in co-op an emptied box stood there for good, "[Looted]", for everyone
--   (0.7.1: a client took 26 things out of their box; the host still counted
--   one item in it and the box stayed).
-- Host (config deathbox_remove_empty): every death box's server data is
-- checked once a second. Items are "visible" when they are in one of the
-- box's main containers or inside a visible item (its SubContainers, or a
-- container whose InContainerUID is that item); anything else is a leftover
-- nobody can see or take. A box with no visible item left - after it held
-- some, or after someone opened it - is destroyed with K2_DestroyActor 2 s
-- later: the actor replicates, so every client's copy goes too; the host's
-- marker of it goes with it and the clients are told (DBOXGONE) to drop
-- theirs. While a few items are left they are logged with their container
-- and slot: what keeps a box that looks empty.
-- Client: DBOXGONE removes the "Location of your death" marker of that box
-- (BP_Marker, spawned locally by the box's BeginPlay) and logs it.
--
-- A destroyed actor stays valid for a while (until the garbage collector; the
-- shared box list is kept 30 s) and its location then reads (0, 0, 0). In
-- 0.7.1 (2026-11-12, three players) the host destroyed the same box again
-- every 3 s for half a minute and sent DBOXGONE at (0, 0, 0) each time; a
-- client's copy of a box that had gone out of its network range also read
-- (0, 0, 0), so the client took it for the removed one and dropped the marker
-- of that player's own, still full, death box. Now: the host never checks a
-- box it destroyed again, skips boxes at (0, 0, 0) and sends no DBOXGONE
-- without a real place; the client keeps the last real place of a box,
-- ignores DBOXGONE at (0, 0, 0) and removes the marker of one box only - the
-- nearest one, a box whose copy here has already gone first.
--
-- A client's copy that comes into range lies where the host has it (section
-- FL below; 2026-11-13: a copy made again after the player came back sank
-- under the ground at once - the box "vanished" for that player).
--
-- Death boxes saved with the world (config deathbox_persist, section BS
-- below): the game saves no Container_DeadPlayerLoot, so a restart or a load
-- lost the things of whoever had died - in co-op a client's too, whose
-- record (sdc_persist) says "dead, the items are in the box". The host's
-- saves now hold the boxes (<slot>_SDCoop_boxes.json + _box<gen>_<n>.sav,
-- kept only for a save the game reports done) and a load of a save puts
-- them back the game's own way.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local net = require("sdc_net")

local M = {
    stats = { checks = 0, scans = 0, removed = 0, markers = 0 },
}
local S
function M.init(state) S = state end

local addr = ctx.addr

local CLASS = "Container_DeadPlayerLoot_C"
local CLASS_PATH = "/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C"

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_IN_ITEM = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"
local CS_NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982"

local CHECK_S = 1.0         -- host: boxes checked at most this often
local LIST_TTL = 30         -- s the shared box list is reused (a new box rescans it at once)
local EMPTY_GRACE_S = 2.0   -- host: empty this long before it goes
local LEFT_SHOWN = 3        -- host: at most this many items left are listed in the log
local MARKER_REACH = 400    -- cm: a marker of a box this close to the removed one is that box's
local NIL_GUID = "0:0:0:0"

-- the boxes saved with the world (section BS below; one table, its functions are fields)
local BS = { LOAD_WAIT_S = 3, LOAD_GIVE_UP_S = 180, MAX = 64, SAVE_END_S = 60,
             hooks = {}, pending = nil, save_due = false, pend = nil, early = nil,
             stats = { saved = 0, restored = 0, removed = 0, failed = 0, dropped = 0 } }

local function on() return cfg.get("deathbox_remove_empty") ~= false end

local function guid_str(g)
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

local function list_of(arr)
    local out = {}
    if arr == nil then return out end
    pcall(function()
        arr:ForEach(function(_, e) out[#out + 1] = e:get() end)
    end)
    return out
end

local function item_name(da)
    if not ue.valid(da) then return "?" end
    return (ue.short(da):gsub("^DA_", ""))
end

local function dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- A place, or nil when there is none: a destroyed actor (or one being
-- destroyed) reads (0, 0, 0); no death box lies exactly there.
local function real_loc(l)
    if type(l) ~= "table" then return nil end
    local x, y, z = tonumber(l.X), tonumber(l.Y), tonumber(l.Z)
    if not x or not y or not z then return nil end
    if math.abs(x) < 1 and math.abs(y) < 1 and math.abs(z) < 1 then return nil end
    return l
end
M._real_loc = real_loc

local watch_tried = false
local function boxes()
    if not watch_tried then
        watch_tried = true
        pcall(ue.watch_new, CLASS, CLASS_PATH)
    end
    local ok, list = pcall(ue.find_all_recent, CLASS, LIST_TTL)
    local out = {}
    for _, b in ipairs((ok and type(list) == "table") and list or {}) do
        if ue.valid(b) and ue.class_name(b) == CLASS then out[#out + 1] = b end
    end
    return out
end

-- ===========================================================================
-- Host: what is left in a box
-- ===========================================================================

-- Items in the box's server data (cheap: only the array sizes).
local function total_items(comp)
    local n = 0
    local ok = pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            n = n + c:get()[F_ITEMS]:GetArrayNum()
        end)
    end)
    if not ok then return nil end
    return n
end

-- Every item of the box, which of them a player can reach, and where the
-- reachable ones are: { total, visible, orphans = { lines }, left = { lines } }.
function M.scan(comp)
    local mains, main_name = {}, {}
    local sets = list_of(ue.prop(comp, "ContainersSettings"))
    for i, g in ipairs(list_of(ue.prop(comp, "MainContainersIDs"))) do
        local u = ue.try(guid_str, g)
        if u then
            mains[u] = true
            main_name[u] = sets[i] and ue.try(function() return ue.str(sets[i][CS_NAME]) end) or ("main " .. i)
        end
    end
    local items, host_of = {}, {}   -- host_of[container uid] = uid of the item it is inside
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local rc = c:get()
            local cu = ue.try(function() return guid_str(rc[F_CONT_UID]) end)
            local hu = ue.try(function() return guid_str(rc[F_IN_ITEM]) end)
            if cu and hu and hu ~= NIL_GUID then host_of[cu] = hu end
            rc[F_ITEMS]:ForEach(function(_, it)
                local x = it:get()
                local e = {
                    uid = ue.try(function() return guid_str(x[F_USID]) end) or "?",
                    mother = ue.try(function() return guid_str(x[F_MOTHER]) end) or "?",
                    slot = ue.try(function() return x[F_SLOT] end),
                    n = ue.try(function() return x[F_INFO][F_COUNT] end),
                    name = ue.try(function() return item_name(x[F_INFO][F_ITEMID]) end) or "?",
                    subs = {},
                }
                pcall(function()
                    x[F_SUBS]:ForEach(function(_, s) e.subs[#e.subs + 1] = guid_str(s:get()[F_SUB_ID]) end)
                end)
                items[#items + 1] = e
            end)
        end)
    end)
    -- reachable containers: the main ones, then those of reachable items
    local open, by_uid = {}, {}
    for u in pairs(mains) do open[u] = true end
    for _, e in ipairs(items) do by_uid[e.uid] = e end
    local seen = {}
    local grew = true
    while grew do
        grew = false
        for _, e in ipairs(items) do
            if not seen[e] and open[e.mother] then
                seen[e] = true
                grew = true
                for _, su in ipairs(e.subs) do open[su] = true end
                for cu, hu in pairs(host_of) do
                    if hu == e.uid then open[cu] = true end
                end
            end
        end
    end
    local r = { total = #items, visible = 0, orphans = {}, left = {} }
    for _, e in ipairs(items) do
        local what = string.format("%s x%s (uid %s)", e.name, tostring(e.n or "?"), e.uid)
        if seen[e] then
            r.visible = r.visible + 1
            if #r.left < LEFT_SHOWN then
                local where = main_name[e.mother]
                if not where then
                    local parent = by_uid[host_of[e.mother] or ""]
                    if not parent then
                        for _, p in ipairs(items) do
                            for _, su in ipairs(p.subs) do if su == e.mother then parent = p end end
                        end
                    end
                    where = parent and ("inside " .. parent.name) or ("container " .. e.mother)
                end
                r.left[#r.left + 1] = string.format("%s in %s slot %s", what, where, tostring(e.slot or "?"))
            end
        else
            r.orphans[#r.orphans + 1] = string.format("%s in container %s, which no main container or item holds",
                what, e.mother)
        end
    end
    return r
end

-- ===========================================================================
-- Host: removing an emptied box
-- ===========================================================================

local state = {}   -- [box address] = { name, peak, total, visible, sig, empty_since, logged_first }
local gone = {}    -- [box name] = os.clock() when the host destroyed it (never checked again)
local GONE_KEEP_S = 300
local check_at = -100

local function remove_marker(m)
    if not ue.valid(m) then return false end
    local mw = ue.prop(m, "Marker")
    if ue.valid(mw) then pcall(function() mw:RemoveFromParent() end) end
    return pcall(function() m:K2_DestroyActor() end) == true
end

local function was_opened(box, comp)
    if ue.prop(box, "Looted?") == true then return true end   -- the host opened it here (SetInspected)
    local cont = package.loaded["sdc_containers"]
    return cont ~= nil and cont.has_viewers ~= nil and cont.has_viewers(comp) == true
end

local function destroy(box, why)
    local loc = real_loc(ue.location(box))
    local name = ue.short(box)
    local marker = ue.prop(box, "DeathMarker")
    local ok, err = pcall(function() box:K2_DestroyActor() end)
    if not ok then
        log.warn("deathbox: %s is empty on the host, but destroying it FAILED: %s", name, tostring(err))
        return false
    end
    gone[name] = os.clock()
    M.stats.removed = M.stats.removed + 1
    local m = remove_marker(marker) and ", its map marker here removed" or ""
    log.info("deathbox: %s is empty on the host (%s) -> destroyed (K2_DestroyActor on the host; the box replicates, so it goes on every machine)%s",
        name, why, m)
    if S and #(S.remote_pcs or {}) > 0 then
        if loc then
            net.broadcast(S.remote_pcs, "DBOXGONE", name, string.format("%.0f", loc.X), string.format("%.0f", loc.Y),
                string.format("%.0f", loc.Z))
        else
            log.warn("deathbox: %s had no place on the host: no DBOXGONE sent (the clients' copy goes with the replicated actor, its marker stays)",
                name)
        end
    end
    return true
end

local function check_box(box, now)
    local k = addr(box)
    if not k then return end
    local name = ue.short(box)
    -- destroyed already (it stays valid until the garbage collector) or
    -- being destroyed by someone else: (0, 0, 0)
    if gone[name] then return end
    if not real_loc(ue.location(box)) then
        state[k] = nil
        return
    end
    local st = state[k]
    if not st or st.name ~= name then
        st = { name = name, peak = 0 }
        state[k] = st
    end
    st.seen = now
    local comp = ue.prop(box, "BP_JigMultiplayer")
    if not ue.valid(comp) then return end
    local total = total_items(comp)
    if total == nil then return end
    if total ~= st.total or st.visible == nil then
        local r = M.scan(comp)
        M.stats.scans = M.stats.scans + 1
        st.total, st.visible = r.total, r.visible
        if r.visible > st.peak then st.peak = r.visible end
        local sig = string.format("%d/%d", r.visible, #r.orphans)
        if sig ~= st.sig then
            st.sig = sig
            if (r.visible > 0 and r.visible <= LEFT_SHOWN) or #r.orphans > 0 then
                log.info("deathbox: %s on the host: %d item(s) left%s%s%s", st.name, r.visible,
                    #r.left > 0 and (": " .. table.concat(r.left, "; ")) or "",
                    #r.orphans > 0 and string.format("; %d leftover(s) nobody can see or take: ", #r.orphans) or "",
                    table.concat(r.orphans, "; "))
            elseif r.visible == 0 and st.peak == 0 and not st.logged_first then
                st.logged_first = true
                log.info("deathbox: %s on the host holds nothing (the player carried nothing): it goes once someone opens it",
                    st.name)
            end
        end
    end
    if st.visible ~= 0 or (st.peak == 0 and not was_opened(box, comp)) then
        st.empty_since = nil
        return
    end
    st.empty_since = st.empty_since or now
    if now - st.empty_since < EMPTY_GRACE_S then return end
    if not on() then
        if not st.kept_logged then
            st.kept_logged = true
            log.info("deathbox: %s is empty on the host; kept (deathbox_remove_empty is off)", st.name)
        end
        return
    end
    local why = st.peak > 0 and string.format("all %d item(s) taken", st.peak) or "nothing was in it, opened"
    if st.total and st.total > 0 then why = why .. string.format(", %d leftover(s) nobody can take", st.total) end
    if destroy(box, why) then state[k] = nil end
end

function M.host_tick()
    if S == nil or S.role ~= "host" then return end
    local now = os.clock()
    if now - check_at < CHECK_S then return end
    check_at = now
    M.stats.checks = M.stats.checks + 1
    if not (BS.hooks.save and BS.hooks.load and BS.hooks.saved) then pcall(BS.install) end
    M.floor_install()
    for _, b in ipairs(boxes()) do
        local ok, err = pcall(check_box, b, now)
        if not ok then log.err_throttled("deathbox.check", "deathbox: check of %s: %s", ue.short(b), tostring(err)) end
    end
    for k, st in pairs(state) do
        if now - (st.seen or now) > 10 then state[k] = nil end
    end
    for n, at in pairs(gone) do
        if now - at > GONE_KEEP_S then gone[n] = nil end
    end
end

-- ===========================================================================
-- Client
-- ===========================================================================

-- Boxes seen here and their markers: [box address] = { name, path, loc,
-- mpath }. Names and paths only - no engine object is kept between ticks:
-- up to 0.7.3 the box and marker wrappers were kept for good (one could
-- alias another actor after the garbage collector), and the entry of a new
-- box at a reused address kept the old box's marker, which DBOXGONE then
-- destroyed. The box and its marker are looked up again by path, and must
-- still have their name / class.
local track = {}
local track_at = -100
local MARKER_CLASS = "BP_Marker_C"

-- The tracked box, still the same one, or nil.
local function box_of(e)
    local b = e.path and ue.find_object(e.path)
    if b and ue.short(b) == e.name and ue.class_name(b) == CLASS then return b end
    return nil
end

-- Its death marker, or nil.
local function marker_of(e)
    local m = e.mpath and ue.find_object(e.mpath)
    if m and ue.class_name(m) == MARKER_CLASS then return m end
    return nil
end

function M.client_tick()
    if S == nil or S.role ~= "client" then return end
    local now = os.clock()
    if now - track_at < 2 then return end
    track_at = now
    M.floor_install()
    for _, b in ipairs(boxes()) do
        local k = addr(b)
        if k then
            local name = ue.short(b)
            local e = track[k]
            -- another box at a reused address: a new entry (the old one's marker is not this box's)
            if not e or e.name ~= name then e = { name = name, path = ue.path(b) } end
            -- a copy out of network range (or being destroyed) reads (0, 0, 0):
            -- keep its last real place
            e.loc = real_loc(ue.location(b)) or e.loc
            local m = ue.prop(b, "DeathMarker")
            if ue.valid(m) and ue.class_name(m) == MARKER_CLASS then e.mpath = ue.path(m) end
            track[k] = e
        end
    end
    -- a box out of reach is gone here but may come back: its marker is kept
    -- until the host says the box is gone (or the marker's own life span ends)
    for k, e in pairs(track) do
        if not box_of(e) and not marker_of(e) then track[k] = nil end
    end
end

-- net DBOXGONE|<box name on the host>|<x>|<y>|<z>, host -> client.
local function on_gone(f)
    if S == nil or S.role ~= "client" then return end
    local at = { X = tonumber(f[2]) or 0, Y = tonumber(f[3]) or 0, Z = tonumber(f[4]) or 0 }
    if not real_loc(at) then
        log.info("deathbox: the host removed the emptied death box %s, but sent no place (0, 0, 0): no marker removed here",
            tostring(f[1] or "?"))
        return
    end
    -- one box: the nearest in reach; a box whose copy here has gone (the
    -- host's destroy replicated) before one that is still standing here
    local best, best_k, best_rank = nil, nil, nil
    for k, e in pairs(track) do
        local d = e.loc and dist2(e.loc, at) or math.huge
        if d <= MARKER_REACH * MARKER_REACH then
            local b = box_of(e)
            local standing = b ~= nil and real_loc(ue.location(b)) ~= nil
            local rank = (standing and 1 or 0) * 1e15 + d
            if best_rank == nil or rank < best_rank then best, best_k, best_rank = e, k, rank end
        end
    end
    local removed, here = 0, nil
    if best then
        here = best.name
        if remove_marker(marker_of(best)) then removed = 1 end
        track[best_k] = nil
    end
    M.stats.markers = M.stats.markers + removed
    log.info("deathbox: the host removed the emptied death box %s at (%.0f, %.0f, %.0f)%s%s", tostring(f[1] or "?"),
        at.X, at.Y, at.Z, here and (" (here " .. here .. ")") or " (not near this player)",
        removed > 0 and "; its death marker here removed" or "")
end

-- ===========================================================================
-- Client: a box copy that comes into range lies where the host has it
-- ===========================================================================
-- 2026-11-13 (logs dbox_1113_1901): the host died, a client opened the
-- host's box (189 items), drove 190 m away and came back: the box was gone
-- for it, while the host still had it (no destroy, no DBOXGONE). The box is
-- spawned with no owner (BP_PlayerCharacter.SpawnDeadPlayerLoot @527, Owner
-- None) and its class sets only bReplicates: the engine's default range,
-- 150 m. Out of it the client's copy is closed; back in range a new copy is
-- made (18:59:48, the same second as the new copies of the boss and zombie
-- corpses there). Every copy runs the box's BeginPlay, which starts the
-- looping timer "TraceForFloor" (every 0.01 s, @1083): a trace 1 cm down from
-- the mesh (WorldStatic / WorldDynamic) and, while it hits nothing, the box
-- 1 cm lower (TraceForFloor @0-847). The copy made at the death comes in at
-- the body's chest and falls onto the ground. A later copy comes in where the
-- host's box lies - on the ground, its place rounded to 0.1 cm by the
-- engine's spawn packet: rounded down, the 1-cm trace starts under the
-- surface, never crosses it, and the copy sinks 1 m/s for good (the client
-- stood at the spot from 18:59:58 and looted the boss next to it, not the
-- box). The same for the client's own box after a far respawn and for boxes
-- put back from a save (BS.spawn).
-- Now, on every machine with a replicated copy (a post-hook on the box's
-- ReceiveBeginPlay): a copy whose floor trace runs is lifted LIFT cm, so the
-- game's own trace meets the ground from above and sets it down where the
-- host has it. It is watched for a few seconds: a copy that still falls
-- DROP_MAX cm below where it came in (no ground for that trace under it) gets
-- its trace stopped and is put on the ground found below that place (a trace
-- of the same object types), else back where it came in. Each copy's outcome
-- is one log line. Kept: names, paths and places (no engine object).
local FL = { LIFT = 5, DROP_MAX = 300, STEP_MS = 500, CHECKS = 16, UP = 50, DOWN = 20000, TRY_S = 5,
             FN = "/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C:ReceiveBeginPlay",
             TIMER = "TraceForFloor", NO_COLOR = { R = 0, G = 0, B = 0, A = 0 },
             hooked = false, gave_up = false, tried_at = -100,
             stats = { came = 0, lifted = 0, set_down = 0, sank = 0 } }

-- The game's floor trace still runs on this box: true / false; nil = unknown.
function FL.trace_on(box)
    local ksl = ue.ksl and ue.ksl()
    if not ksl then return nil end
    local ok, v = pcall(function() return ksl:K2_IsTimerActive(box, FL.TIMER) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- The ground below `at` (the object types of the box's own trace), or nil.
function FL.ground(box, at)
    local ksl = ue.ksl and ue.ksl()
    if not ksl then return nil end
    local hit = {}
    local from = { X = at.X, Y = at.Y, Z = at.Z + FL.UP }
    local to = { X = at.X, Y = at.Y, Z = at.Z - FL.DOWN }
    local ok, blocked = pcall(function()
        return ksl:LineTraceSingleForObjects(box, from, to, { 0, 1 }, false, { box }, 0, hit, true, FL.NO_COLOR,
            FL.NO_COLOR, 0.0)
    end)
    if not ok or blocked ~= true then return nil end
    return real_loc(ue.vec(hit.ImpactPoint) or ue.vec(hit.Location))
end

local function where(l) return string.format("(%.0f, %.0f, %.0f)", l.X, l.Y, l.Z) end

-- A replicated copy came in (the hook below, after the box's BeginPlay).
function FL.came(box)
    if S == nil or S.role == "host" or not ue.valid(box) then return end
    if ue.role(box) ~= ue.ROLE_SIMULATED then return end   -- the host's own box, single player
    local at = real_loc(ue.location(box))
    if not at then return end
    FL.stats.came = FL.stats.came + 1
    local e = { name = ue.short(box), path = ue.path(box), at = { X = at.X, Y = at.Y, Z = at.Z }, lifted = false }
    local me = ue.local_pawn and ue.try(ue.local_pawn)
    local ml = me and real_loc(ue.location(me))
    if ml then e.far = math.sqrt(dist2(ml, at)) / 100 end
    if FL.trace_on(box) == true and ue.teleport(box, { X = at.X, Y = at.Y, Z = at.Z + FL.LIFT }) then
        e.lifted = true
        FL.stats.lifted = FL.stats.lifted + 1
    end
    ue.delay("deathbox-floor", FL.STEP_MS, function() FL.watch(e, 1) end)
end

-- Check n of a copy that came in: set down, still falling, or sunk.
function FL.watch(e, n)
    local box = box_of(e)
    local loc = box and real_loc(ue.location(box))
    if not loc then return end   -- out of range again, or removed
    local on = FL.trace_on(box)
    local drop = e.at.Z - loc.Z
    local came = string.format("deathbox: %s came into range here at %s%s%s", e.name, where(e.at),
        e.far and string.format(", %.0f m from this player", e.far) or "",
        e.lifted and string.format(" (lifted %d cm for the game's floor trace)", FL.LIFT) or "")
    if on == false or (on == nil and drop <= FL.DROP_MAX and n >= FL.CHECKS) then
        FL.stats.set_down = FL.stats.set_down + 1
        log.info("%s: set down at z=%.0f, %d cm below where it came in%s", came, loc.Z, math.floor(drop + 0.5),
            on == nil and " (its floor trace is not readable here)" or "")
        return
    end
    if drop <= FL.DROP_MAX and n < FL.CHECKS then
        ue.delay("deathbox-floor", FL.STEP_MS, function() FL.watch(e, n + 1) end)
        return
    end
    -- still falling: the game's trace finds no ground under it here
    local ksl = ue.ksl and ue.ksl()
    if ksl then pcall(function() ksl:K2_ClearTimer(box, FL.TIMER) end) end
    local g = FL.ground(box, e.at)
    local moved = ue.teleport(box, { X = e.at.X, Y = e.at.Y, Z = (g or e.at).Z })
    FL.stats.sank = FL.stats.sank + 1
    log.info("%s: it went %.0f cm below that and still fell (no ground for the game's floor trace under it here):"
        .. " trace stopped, %s%s", came, drop,
        g and string.format("put on the ground found below that place (z=%.0f)", g.Z)
            or "put back where it came in (no ground found below it)",
        moved and "" or " - moving it FAILED")
end

-- The post-hook on the box's ReceiveBeginPlay, once its class is loaded
-- (it is with BP_PlayerCharacter; tried from the ticks and at install).
function FL.install()
    if FL.hooked or FL.gave_up then return end
    local now = os.clock()
    if now - FL.tried_at < FL.TRY_S then return end
    FL.tried_at = now
    if not ue.find_object(FL.FN) then return end
    local ok, err = pcall(RegisterHook, FL.FN, function(c)
        local okc, e2 = pcall(function() FL.came(c and c:get()) end)
        if not okc then log.err_throttled("deathbox.floor", "deathbox: a box copy came in: %s", tostring(e2)) end
    end)
    FL.hooked, FL.gave_up = ok == true, ok ~= true
    local say = ok and log.info or log.warn
    say("deathbox: box copy hook (Container_DeadPlayerLoot ReceiveBeginPlay: a copy that comes into range lies"
        .. " where the host has it) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end
function M.floor_install() pcall(FL.install) end

-- ===========================================================================
-- Death boxes saved with the world (config deathbox_persist)
-- ===========================================================================
-- The game saves no Container_DeadPlayerLoot (no EMSActorSaveInterface; the
-- single-player host's own box is not saved either): after a restart or the
-- load of a save the dead player's things were gone - in co-op a client's
-- box too, while its record (sdc_persist) says "dead, the items are in the
-- box". And the main menu and the world are one level here (sdc_persist,
-- CM.LOAD_FN): a load opens no new level, so a box from after the save may
-- stand through a load of that save while the dead player's inventory went
-- back to it (items twice). Here the boxes are part of the save, like the
-- actors EMS saves:
--   save   EMS AsyncSaveActors (every save of the game), on the host and in
--          single player (a client's own saves go to a throwaway slot):
--          50 ms later every box with items a player can reach is written
--          the way sdc_persist writes an inventory (the game's own SaveGame
--          of the Jig arrays, sdc_persist.files): <slot>_SDCoop_box<gen>_<n>.sav
--          (gen: one number per list, so a new list never overwrites the
--          files of the one in use). The list itself (<slot>_SDCoop_boxes.json:
--          place, name, items, file) is put in place only once the game
--          reports this save done (BP_PlayerController's OnCompleted, the
--          signal sdc_persist commits the clients' records on); the list
--          before stays as .bak, the files of the one before that go. The
--          game reports it FAILED, does not report it within SAVE_END_S,
--          the world closes first or a newer save starts: the new files go
--          and the slot keeps its last list (2026-11-13: a failed save had
--          rewritten the list, so a client back with the items of the last
--          good save found the box from after it too - items twice). No end
--          hook here: the list is put in place at once. A save with
--          deathbox_persist off deletes the slot's list (an older one must
--          not come back with it).
--   load   EMS AsyncLoadActors (every load of a save; not a respawn): the
--          boxes standing as the load starts are noted; once the world is up
--          (in_menu false, LOAD_WAIT_S later), host or single player, those
--          go - they are not in this save. A box that appeared after the
--          load started (a death in those seconds) is not the save's to
--          remove and stays (2026-11-13: it was removed with its items).
--          persist_follow_host_save off on a host: nothing is removed or
--          put back - the clients' records stay live then, and a box looted
--          empty after the save would come back full to a client who kept
--          the items (2026-11-13); the boxes behave as before this section.
--          A slot without a list (a save from before this, or made with the
--          setting off): nothing is removed or added. Then each saved box is
--          spawned as BP_PlayerCharacter.SpawnDeadPlayerLoot does it
--          (BeginDeferredActorSpawnFromClass, FinishSpawningActor,
--          InitializeJigComponent, MainJigContainers / MainContainersIDs,
--          MarkPropertyDirtyFromRepIndex 3, OnRep_MainContainersIDs) at its
--          saved place. Its BeginPlay starts "TraceForFloor" (moves the box
--          down every 10 ms until a line trace hits): cleared at once - the
--          saved place is where it lay, and the ground far from the players
--          may not be loaded yet. The box replicates to the clients; its
--          BeginPlay makes the death marker on each machine, as the game's.
--   delete EMS DeleteAllSaveDataForSlot: that slot's box files go.

BS.SAVE_FN = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
BS.LOAD_FN = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors"
BS.DELETE_FN = "/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot"
BS.PUSH_LIB = "/Script/Engine.Default__NetPushModelHelpers"
-- the game's "actors saved" / "could not save" (Blueprint; sdc_persist and
-- sdc_savecheck hook the same two)
BS.SAVED_FN = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:OnCompleted_9CDBA9034C950D925C1539BE037C23EF"
BS.FAILED_FN = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:OnFailed_9CDBA9034C950D925C1539BE037C23EF"

function BS.on() return cfg.get("deathbox_persist") ~= false end

-- sdc_persist's files (the same SaveGame format and folder), or nil
function BS.files()
    local p = package.loaded["sdc_persist"]
    if type(p) == "table" and type(p.files) == "table" and p.savegames_dir and p.json_encode then return p.files, p end
    return nil
end

function BS.paths(slot)
    local F, P = BS.files()
    local dir = F and P.savegames_dir()
    if not dir then return nil end
    local base = dir .. F.safe_slot(slot) .. F.TAG .. "_boxes.json"
    return base, base .. ".bak", base .. ".tmp"
end

-- One list file: the list, false when it is damaged, nil when there is none.
function BS.doc_at(path)
    local F, P = BS.files()
    local data = F and path and F.read(path)
    if not data then return nil end
    local d = P.json_decode(data)
    if type(d) == "table" and type(d.boxes) == "table" then return d end
    return false
end

-- The slot's box list ({ gen, slot, saved_at, boxes = { { key, file, x, y,
-- z, name, items, containers, what } } }), the previous copy if the main one
-- is damaged, or nil.
function BS.read(slot)
    local main, bak = BS.paths(slot)
    if not main then return nil end
    for _, path in ipairs({ main, bak }) do
        local d = BS.doc_at(path)
        if d then return d end
        if d == false then log.warn("deathbox: %s is damaged%s", path, path == main and ", trying the previous copy" or "") end
    end
    return nil
end

-- The file key of box i of a list (a list without gen, the first test
-- builds of this: box<i>).
function BS.key_of(doc, i, e)
    return e.key or (doc.gen == nil and ("box" .. i) or nil)
end

-- The box files of list `doc`, except those a list in `...` still names.
function BS.del_files(F, slot, doc, ...)
    if type(doc) ~= "table" or type(doc.boxes) ~= "table" then return 0 end
    local used = {}
    for j = 1, select("#", ...) do
        local k = select(j, ...)
        if type(k) == "table" and type(k.boxes) == "table" then
            for i, e in ipairs(k.boxes) do
                local key = BS.key_of(k, i, e)
                if key then used[key] = true end
            end
        end
    end
    local n = 0
    for i, e in ipairs(doc.boxes) do
        local key = BS.key_of(doc, i, e)
        if key and not used[key] then
            F.blob_delete(slot, key)
            n = n + 1
        end
    end
    return n
end

function BS.slot_ok(slot, F)
    return type(slot) == "string" and slot ~= "" and slot ~= F.TEMP_SLOT
end

function BS.short_list(comp)
    local r = M.scan(comp)
    local names = {}
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            c:get()[F_ITEMS]:ForEach(function(_, it)
                if #names < 6 then names[#names + 1] = ue.try(function() return item_name(it:get()[F_INFO][F_ITEMID]) end) or "?" end
            end)
        end)
    end)
    return r, table.concat(names, ", ") .. (r.total > #names and ", ..." or "")
end

-- The slot's box files go (the game deleted the slot; or it was saved with
-- deathbox_persist off: an older list must not come back with this save).
function BS.drop(F, slot)
    local main, bak, tmp = BS.paths(slot)
    if not main then return nil end
    local pd = BS.pend
    if pd and pd.slot == slot then
        BS.pend = nil
        BS.del_files(F, slot, pd.doc)
    end
    if not (F.exists(main) or F.exists(bak)) then return nil end
    local dm, db = BS.doc_at(main), BS.doc_at(bak)
    BS.del_files(F, slot, dm)
    BS.del_files(F, slot, db)
    F.remove(main)
    F.remove(bak)
    F.remove(tmp)
    return dm and #dm.boxes or 0
end

-- The game saves (50 ms after its AsyncSaveActors): the boxes into its
-- slot, as the list that waits for the game's "actors saved" (BS.saved).
function BS.save(why)
    BS.save_due = false
    -- the game's end of this save, when it came before this ran (used below;
    -- never kept for a later save)
    local early = BS.early
    BS.early = nil
    if S == nil or S.role == "client" then return end
    local F, P = BS.files()
    if not F then
        if BS.on() then log.warn("deathbox: the game saved, but sdc_persist's files are not here: death boxes not saved") end
        return
    end
    local slot = ue.ems_current_slot()
    if not BS.slot_ok(slot, F) then return end
    -- the save end hooks: BP_PlayerController's class is in memory now
    -- (a save runs in it), in single player too
    pcall(BS.install)
    if not BS.on() then
        local n = BS.drop(F, slot)
        if n then log.info("deathbox: slot %s saved with deathbox_persist off: its older list of %d death box(es) deleted", slot, n) end
        return
    end
    -- an older save the game has not reported done yet: this one replaces it
    if BS.pend then BS.discard(BS.pend, "a newer save started before it was reported done", true) end
    local old = BS.read(slot)
    local gen = math.floor(tonumber(old and old.gen) or 0) + 1
    local list, failed = {}, {}
    for _, b in ipairs(boxes()) do
        local name = ue.short(b)
        local loc = real_loc(ue.location(b))
        local comp = ue.prop(b, "BP_JigMultiplayer")
        if #list < BS.MAX and loc and not gone[name] and ue.valid(comp) then
            local okr, r, what = pcall(BS.short_list, comp)
            if okr and r.visible > 0 then
                local key = string.format("box%d_%d", gen, #list + 1)
                local src = { conts = ue.prop(comp, "MainJigContainers"), uids = ue.prop(comp, "MainContainersIDs"),
                              weights = ue.prop(comp, "InventoryWeight") or {} }
                local info, err = F.blob_write(slot, key, src, nil, { x = loc.X, y = loc.Y, z = loc.Z })
                if info then
                    list[#list + 1] = { key = key, file = info.file, x = loc.X, y = loc.Y, z = loc.Z, name = name,
                                        items = info.items, containers = info.containers, what = what }
                else
                    failed[#failed + 1] = name .. " (" .. tostring(err) .. ")"
                end
            end
        end
    end
    local doc = { format = 2, gen = gen, slot = slot, saved_at = os.date("%Y-%m-%d %H:%M:%S"), why = why, boxes = list,
                  note = "SDCoop: dead players' loot boxes of this save (the game saves none); restored when it is loaded" }
    local pd = { slot = slot, doc = doc, failed = failed, old_n = old and #old.boxes or 0 }
    BS.pend = pd
    if not BS.hooks.saved_ok then
        BS.saved(true, "the game's save end is not hooked here: the list is put in place at once")
        return
    end
    if early and os.clock() - early.at <= 5 then
        BS.saved(early.ok, early.note)
        return
    end
    ue.delay("deathbox-save-end", BS.SAVE_END_S * 1000, function()
        if BS.pend == pd then BS.saved(false, string.format("the game did not report it done within %d s", BS.SAVE_END_S)) end
    end)
end

-- The game's save ended (its hooks, 50 ms later): the waiting list is put
-- in place, or dropped. An end before BS.save ran is kept for it.
function BS.saved(ok, note)
    local pd = BS.pend
    if not pd then
        if BS.save_due then BS.early = { ok = ok, note = note, at = os.clock() } end
        return
    end
    BS.pend = nil
    if ok then BS.commit(pd, note) else BS.discard(pd, note) end
end

-- The list of a save the game reported done: written, the one before kept as
-- .bak, the files of the one before that deleted.
function BS.commit(pd, note)
    local F, P = BS.files()
    if not F then return end
    local slot, doc = pd.slot, pd.doc
    local main, bak, tmp = BS.paths(slot)
    if not main then return end
    local old_main, old_bak, had_main = BS.doc_at(main), BS.doc_at(bak), F.exists(main)
    local ok, err = F.write(tmp, P.json_encode(doc) .. "\n")
    if ok then ok, err = F.rotate(main, bak, tmp) end
    if not ok then
        BS.stats.failed = BS.stats.failed + 1
        BS.del_files(F, slot, doc, old_main, old_bak)
        log.err("deathbox: writing %s failed: %s (the slot keeps its last list)", tostring(main), tostring(err))
        return
    end
    -- the main list became the .bak one: the .bak list before it is gone
    if had_main and old_bak then BS.del_files(F, slot, old_bak, doc, old_main) end
    BS.stats.saved = BS.stats.saved + #doc.boxes
    local names = {}
    for _, e in ipairs(doc.boxes) do names[#names + 1] = string.format("%s (%d item(s): %s)", e.name, e.items, e.what) end
    if #doc.boxes > 0 or pd.old_n > 0 or #pd.failed > 0 then
        log.info("deathbox: %d death box(es) saved with slot %s%s%s%s", #doc.boxes, slot,
            #names > 0 and (": " .. table.concat(names, "; ")) or "",
            #pd.failed > 0 and (" | NOT saved: " .. table.concat(pd.failed, "; ")) or "",
            note and (" (" .. note .. ")") or "")
    end
end

-- The list of a save that did not end well: its files go, the slot keeps
-- its last list (the clients' records keep their last commit the same way).
function BS.discard(pd, why, quiet)
    local F = BS.files()
    if not F then return end
    local main, bak = BS.paths(pd.slot)
    BS.del_files(F, pd.slot, pd.doc, BS.doc_at(main), BS.doc_at(bak))
    BS.stats.dropped = BS.stats.dropped + 1
    if quiet then
        if #pd.doc.boxes > 0 then
            log.info("deathbox: slot %s: %s: its list of %d death box(es) is replaced", pd.slot, tostring(why), #pd.doc.boxes)
        end
        return
    end
    log.warn("deathbox: the game's save of slot %s did not end well (%s): its list of %d death box(es) is NOT kept;"
        .. " a load of that slot puts back the boxes of its last good save", pd.slot, tostring(why), #pd.doc.boxes)
end

-- A box of the world that is not in the save being loaded.
function BS.remove(b)
    local name = ue.short(b)
    local loc = real_loc(ue.location(b))
    local marker = ue.prop(b, "DeathMarker")
    if not pcall(function() b:K2_DestroyActor() end) then return false end
    gone[name] = os.clock()
    remove_marker(marker)
    if S and S.role == "host" and loc and #(S.remote_pcs or {}) > 0 then
        net.broadcast(S.remote_pcs, "DBOXGONE", name, string.format("%.0f", loc.X), string.format("%.0f", loc.Y),
            string.format("%.0f", loc.Z))
    end
    return true
end

function BS.class()
    local cls = ue.find_object(CLASS_PATH)
    if not cls and ue.load_asset then
        local ok, o = ue.load_asset(CLASS_PATH, "deathbox")
        if ok and ue.valid(o) then cls = o end
    end
    return cls
end

-- One saved box back into the world (see above). Returns the box, or nil
-- and why not.
function BS.spawn(F, e)
    local obj, err = F.blob_load(e.file)
    if not obj then return nil, tostring(e.file) .. ": " .. tostring(err) end
    local conts, uids = ue.prop(obj, "JigContainers"), ue.prop(obj, "MainUIDs")
    local _, _, ni = F.inv_walk(conts, false)
    if e.items and ni ~= e.items then return nil, string.format("%s holds %d item(s), the list says %d", e.file, ni, e.items) end
    local x, y, z = tonumber(e.x), tonumber(e.y), tonumber(e.z)
    if not (x and y and z) or not real_loc({ X = x, Y = y, Z = z }) then return nil, "no place" end
    local gs, cls, wc = ue.gameplay_statics(), BS.class(), ue.world_context()
    if not gs or not cls or not wc then return nil, "no GameplayStatics / box class / world" end
    local tf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, a = pcall(function() return gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, 2, nil, 0) end)
    if not ok or not ue.valid(a) then return nil, "spawn: " .. tostring(a) end
    local okf, done = pcall(function() return gs:FinishSpawningActor(a, tf, 0) end)
    local box = (okf and ue.valid(done)) and done or a
    local ksl = ue.ksl and ue.ksl()
    if ksl then pcall(function() ksl:K2_ClearTimer(box, "TraceForFloor") end) end
    local comp = ue.prop(box, "BP_JigMultiplayer")
    if not ue.valid(comp) then
        pcall(function() box:K2_DestroyActor() end)
        return nil, "the spawned box has no BP_JigMultiplayer"
    end
    pcall(function() comp:InitializeJigComponent() end)
    if not (ue.set_prop(comp, "MainJigContainers", conts) and ue.set_prop(comp, "MainContainersIDs", uids)) then
        pcall(function() box:K2_DestroyActor() end)
        return nil, "copying the saved arrays into the box failed"
    end
    local push = ue.find_object(BS.PUSH_LIB)
    if push then pcall(function() push:MarkPropertyDirtyFromRepIndex(comp, 3, FName("MainContainersIDs")) end) end
    pcall(function() comp:OnRep_MainContainersIDs() end)
    local n = total_items(comp)
    if n ~= ni then log.warn("deathbox: %s put back holds %s item(s), its file %d", ue.short(box), tostring(n), ni) end
    return box
end

-- The boxes standing now: [name] = address (BS.on_load: as the load starts).
function BS.standing_now()
    local out = {}
    for _, b in ipairs(boxes()) do
        local name = ue.short(b)
        if not gone[name] and real_loc(ue.location(b)) then out[name] = addr(b) or "?" end
    end
    return out
end

-- The world of a loaded save is up: its boxes back (see above). `before`:
-- the boxes that stood as the load started (BS.standing_now), the only ones
-- it removes.
function BS.restore(why, before)
    if S == nil or S.role == "client" or not BS.on() then return end
    local F = BS.files()
    if not F then
        log.warn("deathbox: a save was loaded, but sdc_persist's files are not here: death boxes not put back")
        return
    end
    local slot = ue.ems_current_slot()
    if not BS.slot_ok(slot, F) then return end
    local doc = BS.read(slot)
    before = before or {}
    local standing, late = {}, 0
    for _, b in ipairs(boxes()) do
        local name = ue.short(b)
        if not gone[name] and real_loc(ue.location(b)) then
            local a = before[name]
            if a ~= nil and (a == "?" or a == addr(b)) then standing[#standing + 1] = b else late = late + 1 end
        end
    end
    local late_s = late > 0 and string.format("; %d box(es) from after the load started stay (a death meanwhile)", late) or ""
    if not doc then
        -- a save from before deathbox_persist (or made with it off): which
        -- boxes it had is not known - nothing is removed or added
        if #standing + late > 0 then
            log.info("deathbox: slot %s loaded (%s): it has no saved list of death boxes; the %d standing in the world stay",
                slot, tostring(why), #standing + late)
        end
        return
    end
    local saved = doc.boxes
    if S.role == "host" and cfg.get("persist_follow_host_save") == false then
        -- the clients' records stay live: so do the boxes (a box looted empty
        -- after the save would come back full to a client who kept the items)
        if #saved > 0 or #standing > 0 then
            log.info("deathbox: slot %s loaded (%s): persist_follow_host_save is off - the %d death box(es) of that save are"
                .. " NOT put back and the %d standing in the world stay (the friends' records do not follow the save)",
                slot, tostring(why), #saved, #standing + late)
        end
        return
    end
    local removed = {}
    for _, b in ipairs(standing) do
        local name = ue.short(b)
        if BS.remove(b) then removed[#removed + 1] = name end
    end
    BS.stats.removed = BS.stats.removed + #removed
    local made, failed = {}, {}
    for _, e in ipairs(saved) do
        local ok, box, err = pcall(BS.spawn, F, e)
        if ok and box then
            made[#made + 1] = string.format("%s (was %s, %s item(s): %s)", ue.short(box), tostring(e.name),
                tostring(e.items), tostring(e.what))
        else
            failed[#failed + 1] = tostring(e.name) .. ": " .. tostring(ok and err or box)
        end
    end
    BS.stats.restored = BS.stats.restored + #made
    BS.stats.failed = BS.stats.failed + #failed
    if #saved > 0 or #removed > 0 or late > 0 then
        log.info("deathbox: slot %s loaded (%s): %d death box(es) of that save put back%s%s%s%s", slot, tostring(why), #made,
            #made > 0 and (": " .. table.concat(made, "; ")) or "",
            #removed > 0 and string.format("; %d box(es) standing in the world removed (not in that save): %s", #removed,
                table.concat(removed, ", ")) or "",
            late_s,
            #failed > 0 and (" | NOT put back: " .. table.concat(failed, "; ")) or "")
    end
end

-- After the load hook: waits until the world is up, then restores once.
function BS.wait()
    local pd = BS.pending
    if not pd then return end
    local age = os.clock() - pd.at
    if S == nil or S.in_menu ~= false or age < BS.LOAD_WAIT_S then
        if age > BS.LOAD_GIVE_UP_S then
            BS.pending = nil
            log.warn("deathbox: a save was loaded, but the world was not up within %d s: death boxes not put back", BS.LOAD_GIVE_UP_S)
            return
        end
        ue.delay("deathbox-restore", 1000, BS.wait)
        return
    end
    BS.pending = nil
    local ok, err = pcall(BS.restore, "the game loaded a save", pd.before)
    if not ok then log.err("deathbox: putting the saved death boxes back: %s", tostring(err)) end
end

-- EMS AsyncLoadActors (pre): the boxes standing now are the ones this load
-- may remove; a second load before the restore notes them again.
function BS.on_load()
    if S == nil or S.role == "client" or not BS.on() then return end
    local again = BS.pending ~= nil
    local ok, before = pcall(BS.standing_now)
    BS.pending = { at = os.clock(), before = ok and before or {} }
    if not ok then log.warn("deathbox: a save is loading; the boxes standing now could not be listed (%s): none is removed", tostring(before)) end
    if not again then ue.delay("deathbox-restore", 1000, BS.wait) end
end

-- BP_PlayerController's "actors saved" / "could not save" (Blueprint post
-- hook): the own save of the host / single player; 50 ms later, out of the
-- game's call.
function BS.end_hook(ctx_p, ok)
    if S == nil or S.role == "client" or not (BS.pend or BS.save_due) then return end
    local pc = ctx_p and ctx_p:get()
    if ue.valid(pc) then
        local okl, isl = pcall(function() return pc:IsLocalController() end)
        if okl and isl == false then return end
    end
    -- noted at once: a world change inside these 50 ms ("open for friends"
    -- reopens the world right after its save) still applies it (M.reset)
    local seen = { ok = ok, note = not ok and "the game reported it FAILED" or nil }
    BS.end_seen = seen
    ue.delay("deathbox-saved", 50, function()
        if BS.end_seen ~= seen then return end   -- applied by M.reset meanwhile
        BS.end_seen = nil
        BS.saved(seen.ok, seen.note)
    end)
end

function BS.on_delete(name_p)
    local F = BS.files()
    local slot = ue.str(name_p and name_p:get())
    if not F or not BS.slot_ok(slot, F) then return end
    local n = BS.drop(F, slot)
    if n then log.info("deathbox: save slot %s deleted by the game: its %d saved death box(es) deleted too", slot, n) end
end

-- Native pre-only hooks, shared with other modules (sdc_ue.hook_native).
function BS.install()
    local h = BS.hooks
    if not ue.hook_native then return end
    if not h.save and ue.find_object(BS.SAVE_FN) then
        h.save = true
        local ok, err = ue.hook_native(BS.SAVE_FN, "deathbox", function()
            if BS.save_due or S == nil or S.role == "client" then return end
            BS.save_due = true
            ue.delay("deathbox-save", 50, function() BS.save("game save") end)
        end)
        log.info("deathbox: save hook (EMS AsyncSaveActors) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    if not h.load and ue.find_object(BS.LOAD_FN) then
        h.load = true
        local ok, err = ue.hook_native(BS.LOAD_FN, "deathbox", function() BS.on_load() end)
        log.info("deathbox: load hook (EMS AsyncLoadActors) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    if not h.delete and ue.find_object(BS.DELETE_FN) then
        h.delete = true
        ue.hook_native(BS.DELETE_FN, "deathbox", function(_, _, name_p) BS.on_delete(name_p) end)
    end
    -- the save's end (Blueprint functions: in memory once BP_PlayerController is)
    if not h.saved and ue.find_object(BS.SAVED_FN) then
        h.saved = true
        local ok, err = pcall(RegisterHook, BS.SAVED_FN, function(ctx_p) pcall(BS.end_hook, ctx_p, true) end)
        h.saved_ok = ok == true
        log.info("deathbox: save end hook (BP_PlayerController OnCompleted) %s%s", ok and "ok" or "FAILED",
            ok and "" or (" " .. tostring(err)))
    end
    if not h.failed and ue.find_object(BS.FAILED_FN) then
        h.failed = true
        pcall(RegisterHook, BS.FAILED_FN, function(ctx_p) pcall(BS.end_hook, ctx_p, false) end)
    end
end

function M.store_status()
    local s = BS.stats
    return string.format("death boxes with the save: on=%s saved=%d put back=%d removed at load=%d failed=%d not kept=%d hooks=%s/%s/%s%s",
        tostring(BS.on()), s.saved, s.restored, s.removed, s.failed, s.dropped, tostring(BS.hooks.save == true),
        tostring(BS.hooks.load == true), tostring(BS.hooks.saved_ok == true),
        BS.pend and string.format(" (list of %d box(es) waiting for the save of %s)", #BS.pend.doc.boxes, BS.pend.slot) or "")
end

-- ===========================================================================

function M.reset()
    state, track, gone = {}, {}, {}
    check_at, track_at = -100, -100
    -- a new world: the end the game reported in the last 50 ms is applied
    -- now; a save it never reported done is not kept (the clients' records
    -- are not committed then either, sdc_persist.reset)
    local seen = BS.end_seen
    BS.end_seen = nil
    if BS.pend and seen then
        pcall(BS.saved, seen.ok, seen.note)
    elseif BS.pend then
        pcall(BS.saved, false, "the world closed before the game reported it done")
    end
    BS.save_due, BS.early = false, nil
    -- the old world's boxes are not this world's (a name / address may come again)
    if BS.pending then BS.pending.before = {} end
end

function M.register_handlers()
    -- host -> client: DBOXGONE|<box>|<x>|<y>|<z>   (an emptied death box was destroyed on the host)
    net.on("DBOXGONE", on_gone)
    -- the boxes saved with the world: hooks from the start (single player too)
    pcall(BS.install)
    -- a client's copy that comes into range lies where the host has it (FL)
    M.floor_install()
end

M._state = function() return state end
M._track = function() return track end
M._store = BS
M._floor = FL

return M
