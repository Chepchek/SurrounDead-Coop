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
    local find = ue.find_all_recent or ue.find_all
    local ok, list = false, nil
    if type(find) == "function" then ok, list = pcall(find, CLASS, LIST_TTL) end
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

local track = {}   -- [box address] = { name, loc, marker } boxes seen here (their markers)
local track_at = -100

function M.client_tick()
    if S == nil or S.role ~= "client" then return end
    local now = os.clock()
    if now - track_at < 2 then return end
    track_at = now
    for _, b in ipairs(boxes()) do
        local k = addr(b)
        if k then
            local e = track[k] or { name = ue.short(b) }
            e.box = b
            -- a copy out of network range (or being destroyed) reads (0, 0, 0):
            -- keep its last real place
            e.loc = real_loc(ue.location(b)) or e.loc
            local m = ue.prop(b, "DeathMarker")
            if ue.valid(m) then e.marker = m end
            track[k] = e
        end
    end
    -- a box out of reach is gone here but may come back: its marker is kept
    -- until the host says the box is gone (or the marker's own life span ends)
    for k, e in pairs(track) do
        if not ue.valid(e.box) and not ue.valid(e.marker) then track[k] = nil end
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
            local standing = ue.valid(e.box) and real_loc(ue.location(e.box)) ~= nil
            local rank = (standing and 1 or 0) * 1e15 + d
            if best_rank == nil or rank < best_rank then best, best_k, best_rank = e, k, rank end
        end
    end
    local removed, here = 0, nil
    if best then
        here = best.name
        if remove_marker(best.marker) then removed = 1 end
        track[best_k] = nil
    end
    M.stats.markers = M.stats.markers + removed
    log.info("deathbox: the host removed the emptied death box %s at (%.0f, %.0f, %.0f)%s%s", tostring(f[1] or "?"),
        at.X, at.Y, at.Z, here and (" (here " .. here .. ")") or " (not near this player)",
        removed > 0 and "; its death marker here removed" or "")
end

-- ===========================================================================

function M.reset()
    state, track, gone = {}, {}, {}
    check_at, track_at = -100, -100
end

function M.register_handlers()
    -- host -> client: DBOXGONE|<box>|<x>|<y>|<z>   (an emptied death box was destroyed on the host)
    net.on("DBOXGONE", on_gone)
end

M._state = function() return state end
M._track = function() return track end

return M
