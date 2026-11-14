-- SDCoop: items moved in world containers (chests, loot boxes, bodies, station
-- and vehicle storage, traders) - the host's answer reaches the client's open
-- window.
-- Driven by sdc_items (init / host_tick / client_tick / reset /
-- register_handlers); fed by sdc_consume (the inventory server RPCs, host) and
-- sdc_stations (a container opened: SERVER_RequestData on the host,
-- CLIENT_ContainerDataResponse on the client).
--
-- How the plugin moves an item (BP_JigComponent):
--   client, the drop (Jig_UnhandledEvent, on the component of the container
--   the item was dropped on): DroppedItem.SetPending(true) (the FadeInOut
--   blink) + PendingRequests, then on its own component
--     SERVER_SameContainer_MoveToIndex(ref, uid, to container, index, ...)
--       (inside one container), or
--     SERVER_RequestMoveItemToAnotherComp(From, To, uid, ...) (between two).
--   host: HandleSameContainerMoveToIndex / Handle Comp to Comp Move. The
--   answer for a player's own inventory is a reliable Client RPC
--   (CLIENT_MoveItemToIndex, CLIENT_AddNewItem, CLIENT_ItemRemoved,
--   CLIENT_UpdateStack, Client_SameCompUpdateSplitRequest, CLIENT_NewItemAdded);
--   for a world container it is a NetMulticast WITHOUT NetReliable
--   (MC_MoveItemToIndex, MC_AddNewItem, MC_ItemRemoved, MC_UpdateStack,
--   MC_UpdateCount, MC_UpdateCounts, MC_SameCompUpdateSplitRequest,
--   MC_NewItemAdded, MC_UpdateDurability, MC_OnPendingDone). The engine drops unreliable multicasts
--   (at most net.MaxRPCPerNetUpdate = 2 per actor and net update, none on a
--   saturated connection). Dropped: the moved item keeps blinking where it
--   was, a taken item stays in the chest (moving it again: "Not found" on the
--   host, no answer, it blinks), a put item does not show - until the chest
--   is reopened (SERVER_RequestData -> CLIENT_ContainerDataResponse, reliable,
--   rebuilds it). Some refusals have no answer at all (HandleSameContainer-
--   MoveToIndex / Handle Comp to Comp Move return without one): blinking.
-- Fix:
--   host, each of those multicasts on a world container: the same data to the
--   remote players who have it open, through the mod's reliable channel
--   (JMC; the ops of one game tick go together, one message per viewer and
--   container, in their order); the client runs the multicast's own handler
--   on its copy of the component (HandleClientMoveItemToIndex, the removal of
--   MC_ItemRemoved, FuncHandleStackResponse, ClientUpdateCount). Each handler
--   leaves a view that already shows the result as it is. An added item is checked a
--   moment later; if it is still missing the client asks (JADD) and the host
--   sends it with the plugin's own reliable CLIENT_AddNewItem(item, content,
--   <container component>).
--   host, after each move request: the item where the request wanted it? If
--   not, the plugin's own failure answer CLIENT_MoveToIndexFailed(uid,
--   <component holding the pending slot>) - the blinking stops, the item
--   stays where it is (the host did not move it). A stack with fewer items
--   than before the request (ammo loaded into a magazine) moved in part: no
--   failure. An item the host has nowhere (a slot only the client shows): the
--   client is told it is gone (CLIENT_UpdateCount 0, tell_gone).
--   client: a pending slot of an open container that still waits after
--   STUCK_S stops blinking (RemoveRequestByUID(uid, false)) and is reported.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local net = require("sdc_net")
-- (a dead player's loot box that was emptied goes away; driven from here)
local deathbox = require("sdc_deathbox")

local M = {
    stats = { host_moves = 0, host_refused = 0, failed_sent = 0, forwards = 0, resends = 0,
              host_partial = 0, gone_sent = 0,
              client_moves = 0, applied = 0, already = 0, unknown = 0, asked = 0, stuck = 0 },
}
local S
function M.init(state)
    S = state
    deathbox.init(state)
end

local addr = ctx.addr

local JIG_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"
local U_UID = "UID_2_DC6DBB72457305316FAC19A4399A1CB5"
local U_COUNT = "NewCount_5_31E28E124BF695AFBB001A87164F9121"

local VIEW_KEEP = 1800      -- s an opened container counts as open for that player
local VIEW_REACH = 3000     -- cm: a player farther from the container has it closed
local ADD_CHECK_MS = 700     -- client: an added item is looked for this much later
local STUCK_S = 8           -- client: a pending slot of an open container waits at most this long
local OPEN_KEEP = 1800      -- client: an opened container's component is remembered this long
local LOG_FIRST = 40        -- info lines per kind, then debug

local ZERO = { A = 0, B = 0, C = 0, D = 0 }

local function on() return cfg.get("container_moves_reliable") ~= false end

local function guid_str(g)
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

local function guid_of(s)
    local a, b, c, d = tostring(s or ""):match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not a then return nil end
    return { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) }
end

local function param(p)
    if not p then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
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

local function owner_of(comp)
    local o = ue.try(function() return comp:GetOwner() end)
    if ue.valid(o) then return o end
    return nil
end

local function is_player_character(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

local function is_remote_character(p)
    if not is_player_character(p) then return false end
    return ue.valid(ue.prop(ue.prop(p, "Controller"), "NetConnection"))
end

-- A component of a world container (not a player's inventory).
local function is_world_comp(comp)
    if not ue.valid(comp) then return false end
    local o = owner_of(comp)
    return o ~= nil and not is_player_character(o)
end

local function comp_name(comp)
    local o = owner_of(comp)
    if is_player_character(o) then return "inventory of " .. ue.short(o) end
    return o and ue.short(o) or "?"
end

local logged = {}   -- [kind] = info lines written
local function counted(kind)
    local n = (logged[kind] or 0) + 1
    logged[kind] = n
    return n <= LOG_FIRST
end

local hooked = {}
local function try_hook(path, tag, fn)
    if hooked[path] then return end
    local ok = pcall(RegisterHook, path, function(c, ...)
        local okc, err = pcall(fn, c, ...)
        if not okc then log.err_throttled("containers." .. tag, "containers: %s hook: %s", tag, tostring(err)) end
    end)
    if ok then
        hooked[path] = true
        log.info("containers: %s hook ok", tag)
    end
end

-- ===========================================================================
-- Host
-- ===========================================================================

local views = {}    -- [component address] = { comp =, key =, by = { [pawn address] = { pawn =, name =, t = } } }
local by_key = {}   -- [container key] = component address

-- The container's key on both machines: its first main container UID (the
-- client's widgets get these as ContainerID from CLIENT_ContainerDataResponse).
local function main_key(comp)
    local ids = list_of(ue.prop(comp, "MainContainersIDs"))
    local g = ids[1]
    if g == nil then return nil end
    return ue.try(guid_str, g)
end

-- (the queue of the JMC ops, below)
local jmc = { q = {}, order = {}, due = false, PER_MSG = 24, FLUSH_MS = 30, vc = {}, sum = {}, sum_order = {} }
local VC_KEEP_S = 0.05

-- Host: a remote player has this world container open.
function M.note_view(pawn, comp)
    if S.role ~= "host" or not is_remote_character(pawn) or not is_world_comp(comp) then return end
    local k, pk = addr(comp), addr(pawn)
    if not k or not pk then return end
    local v = views[k]
    if not v then
        local key = main_key(comp)
        if not key then return end
        v = { comp = comp, key = key, by = {} }
        views[k] = v
        by_key[key] = k
    end
    v.comp = comp
    v.by[pk] = { pawn = pawn, name = ue.short(pawn), t = os.clock() }
    jmc.vc[k] = nil   -- (the batch window's viewers: this one counts from now)
end

local function dist2(a, b)
    if not a or not b then return 0 end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- A viewer entry still counts: not too old, the same remote character.
local function viewer_live(e, now)
    return now - e.t <= VIEW_KEEP and is_remote_character(e.pawn) and ue.short(e.pawn) == e.name
end

-- The remote players who have this container open: { { pawn =, pc = } }.
local function viewers_of(comp)
    local v = views[addr(comp) or -1]
    if not v then return {}, nil end
    local now = os.clock()
    local at = ue.location(owner_of(comp))
    local out = {}
    for pk, e in pairs(v.by) do
        local p = e.pawn
        if not viewer_live(e, now) then
            v.by[pk] = nil
        elseif dist2(at, ue.location(p)) <= VIEW_REACH * VIEW_REACH then
            out[#out + 1] = { pawn = p, pc = ue.prop(p, "Controller") }
        end
    end
    return out, v.key
end

-- The component a multicast hook ran on, if a remote player has it open (one
-- address lookup: the plugin multicasts on every loot container).
local function watched(c)
    if S.role ~= "host" then return nil end
    local comp = c and c:get()
    local k = comp and addr(comp)
    if not k or not views[k] then return nil end
    return comp
end

-- The JMC ops of this game tick, per (viewer, container) in their order,
-- sent together FLUSH_MS later (and by the host tick, if that delay never
-- ran): JMC|*|<container key>|<op,arg,arg>|<op,...>|... Up to 0.7.3 every op
-- was a message of its own to every viewer (a disassembly with N outputs:
-- N messages per viewer).
-- Batched for a run of many count changes (0.12.x: a client disassembling a
-- stack of 1000 made ~3500 ops, one 'cnt' per unit, 3550 log lines and a
-- freeze of seconds):
--   * a 'cnt' / 'dur' of an item replaces that item's pending one in the same
--     batch (only the last count counts) unless an op in between touched the
--     item (stk / rm / mv / add name it): then it is queued again, in order;
--   * the viewers of a container are worked out once per batch window
--     (VC_KEEP_S), not for every op; note_view forgets them;
--   * one log line per container and batch, not one per op.

local function jmc_flush()
    local q, order, sum, sum_order = jmc.q, jmc.order, jmc.sum, jmc.sum_order
    jmc.q, jmc.order, jmc.due, jmc.sum, jmc.sum_order = {}, {}, false, {}, {}
    local msgs = 0
    for _, bk in ipairs(order) do
        local b = q[bk]
        -- (the controller again: the same one, not a wrapper left from before)
        if ue.valid(b.pc) and ue.short(b.pc) == b.pname then
            local n = #b.ops
            for i = 1, n, jmc.PER_MSG do
                net.send_to(b.pc, "JMC", "*", b.key, table.unpack(b.ops, i, math.min(n, i + jmc.PER_MSG - 1)))
                msgs = msgs + 1
            end
        end
    end
    M.stats.jmc_msgs = (M.stats.jmc_msgs or 0) + msgs
    for _, ck in ipairs(sum_order) do
        local e = sum[ck]
        local kinds = {}
        for _, k in ipairs({ "add", "cnt", "rm", "mv", "stk", "dur", "done" }) do
            if e.by[k] then kinds[#kinds + 1] = k .. " " .. e.by[k] end
        end
        local line = string.format("containers: %d op(s) (%s)%s in %s -> %s (reliable copy of the plugin's multicast)",
            e.n, table.concat(kinds, ", "), e.merged > 0 and string.format(", %d merged", e.merged) or "", e.name, e.who)
        if e.n <= 3 then line = line .. " [" .. table.concat(e.items, " | ") .. "]" end
        if counted("forwards") then log.info("%s", line) else log.debug("%s", line) end
    end
end

-- Host: the queued JMC ops go now (sdc_stations, before its DISASMR).
function M.flush_viewers()
    if jmc.due or next(jmc.q) ~= nil then jmc_flush() end
end

-- The viewers of a world container for this batch window: { ok =, vs =, key =,
-- who = "names", name = container name, t = } (one walk per window).
local function viewer_cache(comp, ck)
    local now = os.clock()
    local c = jmc.vc[ck]
    if c and now - c.t <= VC_KEEP_S then return c end
    c = { t = now, ok = is_world_comp(comp), vs = {}, key = nil, who = "", name = "?" }
    if c.ok then
        local vs, key = viewers_of(comp)
        c.key = key
        local names = {}
        for _, e in ipairs(vs) do
            local pk = ue.valid(e.pc) and addr(e.pc)
            if pk then
                c.vs[#c.vs + 1] = { pc = e.pc, pk = pk, pname = ue.short(e.pc) }
                names[#names + 1] = ue.short(e.pawn)
            end
        end
        c.who = table.concat(names, ", ")
        c.name = comp_name(comp)
    end
    jmc.vc[ck] = c
    return c
end

-- One multicast of a world container to its remote viewers.
local function forward(comp, op, ...)
    if S.role ~= "host" or not on() then return end
    local ck = addr(comp)
    if not ck or not views[ck] then return end
    local c = viewer_cache(comp, ck)
    if not c.ok or #c.vs == 0 or not c.key then return end
    local parts = { op }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local item = table.concat(parts, ",")
    M.stats.forwards = M.stats.forwards + 1
    local merged = false
    for _, e in ipairs(c.vs) do
        local bk = tostring(e.pk) .. "|" .. c.key
        local b = jmc.q[bk]
        if not b then
            b = { pc = e.pc, pname = e.pname, key = c.key, ops = {}, last = {} }
            jmc.q[bk] = b
            jmc.order[#jmc.order + 1] = bk
        end
        local last = b.last
        if op == "cnt" or op == "dur" then
            local lk = op .. "|" .. parts[2]
            local at = last[lk]
            if at then
                b.ops[at] = item
                merged = true
            else
                b.ops[#b.ops + 1] = item
                last[lk] = #b.ops
            end
        else
            -- an op that names an item ends the merging of that item's earlier count
            for i = 2, #parts do
                last["cnt|" .. parts[i]] = nil
                last["dur|" .. parts[i]] = nil
            end
            b.ops[#b.ops + 1] = item
        end
    end
    if not jmc.due then
        jmc.due = true
        ue.delay("containers-jmc", jmc.FLUSH_MS, jmc_flush)
    end
    local e = jmc.sum[ck]
    if not e then
        e = { n = 0, merged = 0, by = {}, items = {}, name = c.name, who = c.who }
        jmc.sum[ck] = e
        jmc.sum_order[#jmc.sum_order + 1] = ck
    end
    e.n = e.n + 1
    if merged then e.merged = e.merged + 1 end
    e.by[op] = (e.by[op] or 0) + 1
    if #e.items < 3 then e.items[#e.items + 1] = item end
end

-- Host: a change the mod made itself in a world container's server data (no
-- multicast of the plugin went out), to its remote viewers the same way:
-- op "add" <uid> (the client checks and asks for a missing one), "cnt" <uid> <n>.
function M.notify_viewers(comp, op, ...)
    forward(comp, op, ...)
end

-- Host: a remote player has opened this world container (and not left it).
function M.has_viewers(comp)
    return views[addr(comp) or -1] ~= nil
end

-- MC_MoveItemToIndex(TargetComp, ItemUID, ToContainerUID, ToIndex, FinalRotation)
local function on_mc_move(c, _, uid_p, to_p, idx_p, rot_p)
    local comp = watched(c)
    if not comp then return end
    local u, to = ue.try(guid_str, param(uid_p)), ue.try(guid_str, param(to_p))
    if not u or not to then return end
    forward(comp, "mv", u, to, math.floor(tonumber(param(idx_p)) or 0), param(rot_p) == true and 1 or 0)
end

-- MC_ItemRemoved(ItemUID)
local function on_mc_removed(c, uid_p)
    local comp = watched(c)
    if not comp then return end
    local u = ue.try(guid_str, param(uid_p))
    if u then forward(comp, "rm", u) end
end

-- MC_AddNewItem(ItemInfo, Content)
local function on_mc_add(c, info_p)
    local comp = watched(c)
    if not comp then return end
    local info = param(info_p)
    local u = info and ue.try(function() return guid_str(info[F_USID]) end)
    if u then forward(comp, "add", u) end
end

-- MC_UpdateStack(DroppedUID, DropNewCount, RecUID, RecNewCount)
local function on_mc_stack(c, d_p, dn_p, r_p, rn_p)
    local comp = watched(c)
    if not comp then return end
    local d, r = ue.try(guid_str, param(d_p)), ue.try(guid_str, param(r_p))
    if not d or not r then return end
    forward(comp, "stk", d, math.floor(tonumber(param(dn_p)) or 0), r, math.floor(tonumber(param(rn_p)) or 0))
end

-- MC_UpdateCount(ItemUID, NewCount, RemovePending)
local function on_mc_count(c, uid_p, n_p)
    local comp = watched(c)
    if not comp then return end
    local u = ue.try(guid_str, param(uid_p))
    if u then forward(comp, "cnt", u, math.floor(tonumber(param(n_p)) or 0)) end
end

-- MC_UpdateCounts(Counts: S_UpdateCount[])
local function on_mc_counts(c, counts_p)
    local comp = watched(c)
    if not comp then return end
    for _, e in ipairs(list_of(param(counts_p))) do
        local u = ue.try(function() return guid_str(e[U_UID]) end)
        if u then forward(comp, "cnt", u, math.floor(tonumber(ue.try(function() return e[U_COUNT] end)) or 0)) end
    end
end

-- MC_SameCompUpdateSplitRequest(SourceUID, SourceNewCount, NewItem, NewItemUID,
-- TocontainerUID, ToIndex, Rotated): a stack split inside one world
-- container. The source's new count (ClientUpdateCount also ends its blink)
-- and the new stack (checked, asked for when missing).
local function on_mc_split(c, src_p, n_p, _, new_p)
    local comp = watched(c)
    if not comp then return end
    local src, new = ue.try(guid_str, param(src_p)), ue.try(guid_str, param(new_p))
    if src then forward(comp, "cnt", src, math.floor(tonumber(param(n_p)) or 0)) end
    if new then forward(comp, "add", new) end
end

-- MC_NewItemAdded(ItemInfo, UID, ToContainerUID, ToIndex, FinalRotation,
-- UpdateCount, SubContainers): a split from a player's inventory into a world
-- container, an item made into a station's container.
local function on_mc_new(c, _, uid_p, _, _, _, upd_p)
    local comp = watched(c)
    if not comp then return end
    local u = ue.try(guid_str, param(uid_p))
    if u then forward(comp, "add", u) end
    local upd = param(upd_p)
    local uu = upd and ue.try(function() return guid_str(upd[U_UID]) end)
    if uu and uu ~= "0:0:0:0" then
        forward(comp, "cnt", uu, math.floor(tonumber(ue.try(function() return upd[U_COUNT] end)) or 0))
    end
end

-- MC_UpdateDurability(ItemUID, NewDurab)
local function on_mc_dur(c, uid_p, dur_p)
    local comp = watched(c)
    if not comp then return end
    local u, d = ue.try(guid_str, param(uid_p)), param(dur_p)
    local x, y = d and tonumber(ue.try(function() return d.X end)), d and tonumber(ue.try(function() return d.Y end))
    if u and x and y then forward(comp, "dur", u, string.format("%.3f", x), string.format("%.3f", y)) end
end

-- MC_OnPendingDone(Item: ContainerPickupsInfo[]): timed station crafts done.
local function on_mc_done(c, items_p)
    local comp = watched(c)
    if not comp then return end
    for _, it in ipairs(list_of(param(items_p))) do
        local u = ue.try(function() return guid_str(it[F_USID]) end)
        if u then forward(comp, "done", u) end
    end
end

-- The item with this UID in a component's server data, or nil.
local function find_item(comp, u)
    local found = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if found then return end
            c:get()[F_ITEMS]:ForEach(function(_, it)
                if found then return end
                local item = it:get()
                if guid_str(item[F_USID]) == u then
                    found = { item = item, mother = guid_str(item[F_MOTHER]), slot = item[F_SLOT],
                              n = item[F_INFO][F_COUNT], name = item_name(item[F_INFO][F_ITEMID]) }
                end
            end)
        end)
    end)
    return found
end

-- The items inside an item's containers (what Handle Comp to Comp Move sends
-- as Content), from the server data.
local function content_of(comp, item, depth, out)
    out = out or {}
    if depth > 3 then return out end
    local subs = {}
    pcall(function()
        item[F_SUBS]:ForEach(function(_, s) subs[guid_str(s:get()[F_SUB_ID])] = true end)
    end)
    if next(subs) == nil then return out end
    local inner = {}
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local cont = c:get()
            if subs[guid_str(cont[F_CONT_UID])] then
                cont[F_ITEMS]:ForEach(function(_, it)
                    local x = it:get()
                    out[#out + 1] = x
                    inner[#inner + 1] = x
                end)
            end
        end)
    end)
    for _, x in ipairs(inner) do content_of(comp, x, depth + 1, out) end
    return out
end

local function is_vendor(comp)
    return ue.try(function() return comp:IsVendor() end) == true
end

-- The item at a slot of a container in a component's server data, or nil.
local function item_at(comp, mother, slot)
    local found = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if found then return end
            c:get()[F_ITEMS]:ForEach(function(_, it)
                if found then return end
                local item = it:get()
                if guid_str(item[F_MOTHER]) == mother and tonumber(item[F_SLOT]) == slot then
                    found = { uid = guid_str(item[F_USID]), n = item[F_INFO][F_COUNT], name = item_name(item[F_INFO][F_ITEMID]) }
                end
            end)
        end)
    end)
    return found
end

-- The plugin's own answer to a refused move: the pending slot in `holder`
-- stops blinking, the item stays where it is.
local function send_failed(mover_comp, holder, g)
    local ok, err = pcall(function() mover_comp:CLIENT_MoveToIndexFailed({ { A = g.A, B = g.B, C = g.C, D = g.D } }, holder) end)
    M.stats.failed_sent = M.stats.failed_sent + 1
    return ok and "the client was told (CLIENT_MoveToIndexFailed)" or ("telling the client FAILED: " .. tostring(err))
end

-- `again`: the same request again within gone.AGAIN s (a held click / fast
-- looting sends one 6-13 times in 0.1 s): a debug line only, its first one
-- said it all (0.8.1: 107 "gone from both" lines).
local function host_move_log(line, bad, again)
    if again then log.debug("%s", line)
    elseif bad then log.warn("%s", line)
    elseif counted("host_moves") then log.info("%s", line)
    else log.debug("%s", line) end
end

-- The host has the item in none of the places a move could have left it: a
-- stack merged into another one or loaded whole into a magazine (the plugin
-- answered that itself), or a slot only the client shows (0.8.1: Rags x2 that
-- the restore had replaced stayed in a client's pockets for 16 minutes;
-- moving them got no answer at all). The client is told it is gone the way
-- the game ends a stack: CLIENT_UpdateCount(holder, uid, 0, uid) removes a
-- slot of the own inventory that shows it and ends the pending request in
-- `holder`; the viewers of the world container it was shown in lose it there
-- (JMC rm). Nothing when the player's inventory here holds that UID (only
-- that container's view was old), and one answer per item in gone.AGAIN s (a
-- held click sends the request a dozen times; the second value: a repeat).
-- After a merge of the player's own stack the game answered there is
-- nothing left on the client to remove. A world container's stack merged
-- into one of the player's (looting onto a stack: no snapshot of the
-- container, so not told apart) gets the answer too, harmless: the client's
-- own inventory has no such UID (ClientUpdateCount finds nothing there, the
-- game's answer ended the pending request first: same connection, sent
-- before) and the container's viewers lose it as the host's copy did.
local gone = { told = {}, AGAIN = 2 }   -- told: ["pawn address|uid"] = os.clock() of the answer
local function tell_gone(mcomp, mover, holder, world, g, u, mine_checked)
    if not mine_checked and find_item(mcomp, u) then return " - it is in their inventory here: nothing sent" end
    local k = tostring(addr(mover)) .. "|" .. u
    local now = os.clock()
    if now - (gone.told[k] or -100) < gone.AGAIN then return " - the client was told a moment ago", true end
    gone.told[k] = now
    if world then forward(world, "rm", u) end
    local ok, err = pcall(function()
        mcomp:CLIENT_UpdateCount(holder, { A = g.A, B = g.B, C = g.C, D = g.D }, 0, { A = g.A, B = g.B, C = g.C, D = g.D })
    end)
    M.stats.gone_sent = M.stats.gone_sent + 1
    return ok and " - the client was told it is gone (CLIENT_UpdateCount 0)" or (" - telling the client FAILED: " .. tostring(err))
end

-- The count of an item in the mover's inventory before the request
-- (`before`: sdc_consume's snapshot, [uid] = { n = count }), when `comp` is
-- that inventory; nil = not known.
local function count_before(before, comp, mcomp, u)
    if not before or addr(comp) ~= addr(mcomp) then return nil end
    local pre = before[u]
    return pre and (tonumber(pre.n) or 0) or false
end

-- SERVER_SameContainer_MoveToIndex(JigMPCompRef, ItemUID, ToContainerUID,
-- ToIndex, Rotated?, InContainerIndex); `before`: see count_before. Ammo
-- dropped on a magazine (a capacity container) stays where it was with fewer
-- rounds, or goes whole into the magazine's stack; the plugin answers both
-- itself (CLIENT_UpdateCounts / CLIENT_UpdateCount; a full magazine: its own
-- CLIENT_MoveToIndexFailed). 0.8.1 called a loaded magazine "NOT moved" and
-- sent a failure on top.
local function on_same_move(mcomp, mover, before, ref_p, uid_p, to_p, idx_p)
    local ref = param(ref_p)
    local g, to = param(uid_p), ue.try(guid_str, param(to_p))
    local u = g and ue.try(guid_str, g)
    if not ue.valid(ref) or not u or not to then return end
    M.note_view(mover, ref)
    M.stats.host_moves = M.stats.host_moves + 1
    local idx = math.floor(tonumber(param(idx_p)) or -1)
    local it = find_item(ref, u)
    local was = count_before(before, ref, mcomp, u)
    local n = it and tonumber(it.n)
    local result, answer, bad, again = "done", "", false, false
    if it and it.mother == to and tonumber(it.slot) == idx then
        result = "done"
    elseif it and was and n and n < was then
        M.stats.host_partial = M.stats.host_partial + 1
        result = string.format("done (%d of %d went in, the rest stays at slot %s)", was - n, was, tostring(it.slot))
    elseif it then
        M.stats.host_refused = M.stats.host_refused + 1
        local at = item_at(ref, to, idx)
        result = string.format("NOT moved (still at slot %s, x%s; slot %d there holds %s)", tostring(it.slot),
            tostring(it.n), idx, at and string.format("%s x%s", at.name, tostring(at.n)) or "nothing")
        answer, bad = " - " .. send_failed(mcomp, ref, g), true
    elseif was then
        result = "done (merged whole into a stack there: the plugin answered)"
    else
        -- the host's snapshot of the inventory did not have it before either: a
        -- slot only the client shows
        bad = was == false
        result = bad and "NOT there (not in their inventory before either: shown only on the client)"
            or "NOT there (merged, or shown only on the client)"
        answer, again = tell_gone(mcomp, mover, ref, is_world_comp(ref) and ref or nil, g, u, addr(ref) == addr(mcomp))
    end
    host_move_log(string.format("containers: %s moved %s (uid %s) inside %s to slot %d: %s%s", ue.short(mover),
        it and it.name or "?", u, comp_name(ref), idx, result, answer), bad, again)
end

-- SERVER_RequestMoveItemToAnotherComp(From, To, ItemUID, FinalRotation,
-- ToIndex, ToContainer, ...); `before`: see count_before.
local function on_comp_move(mcomp, mover, before, from_p, to_p, uid_p, _, idx_p)
    local from, to = param(from_p), param(to_p)
    local g = param(uid_p)
    local u = g and ue.try(guid_str, g)
    if not u or not ue.valid(from) or not ue.valid(to) then return end
    M.note_view(mover, from)
    M.note_view(mover, to)
    M.stats.host_moves = M.stats.host_moves + 1
    if is_vendor(from) or is_vendor(to) then return end
    local in_to, in_from = find_item(to, u), find_item(from, u)
    local was = count_before(before, from, mcomp, u)
    local n = in_from and tonumber(in_from.n)
    local result, answer, bad, again = "NOT moved", "", false, false
    if in_to ~= nil and in_from == nil then
        result = "done"
    elseif in_from and not in_to and was and n and n < was then
        -- part of a stack went (a magazine there took what it had room for)
        M.stats.host_partial = M.stats.host_partial + 1
        result = string.format("done (%d of %d went in, the rest stays)", was - n, was)
    elseif in_from and not in_to then
        M.stats.host_refused = M.stats.host_refused + 1
        answer, bad = " - " .. send_failed(mcomp, to, g), true
    elseif not in_from and not in_to then
        if was then
            result = "gone from both: merged into a stack there (the plugin answered)"
        else
            bad = was == false
            result = bad and "gone from both, and not in their inventory before either (shown only on the client)"
                or "gone from both (merged, or shown only on the client)"
            answer, again = tell_gone(mcomp, mover, to, is_world_comp(from) and from or nil, g, u,
                addr(from) == addr(mcomp) or addr(to) == addr(mcomp))
        end
    else
        -- in both (one component as From and To): a WARN without an answer, as before
        bad = true
    end
    host_move_log(string.format("containers: %s moved %s x%s (uid %s) from %s to %s slot %s: %s%s", ue.short(mover),
        (in_to or in_from or {}).name or "?", tostring((in_to or in_from or {}).n or "?"), u, comp_name(from),
        comp_name(to), tostring(param(idx_p)), result, answer), bad, again)
end

-- SERVER_RequestStackItem(FromCom, ToComp, DroppedUID, ReceiverUID, MaxStack):
-- only the receiving component is told; a world container the dropped stack
-- came from gets its new state (gone / count) like its multicasts.
local function on_stack(mcomp, mover, from_p, to_p, d_p, r_p)
    local from, to = param(from_p), param(to_p)
    local d = ue.try(guid_str, param(d_p))
    M.note_view(mover, from)
    M.note_view(mover, to)
    if not d or not ue.valid(from) or addr(from) == addr(to) or not is_world_comp(from) then return end
    local it = find_item(from, d)
    if it then forward(from, "cnt", d, math.floor(tonumber(it.n) or 0)) else forward(from, "rm", d) end
    host_move_log(string.format("containers: %s stacked %s from %s onto %s in %s", ue.short(mover), d,
        comp_name(from), ue.try(guid_str, param(r_p)) or "?", comp_name(to)), false)
end

-- SERVER_RequestSplitItem(FromComp, ToComp, ItemUID, ToContainerUID, ToIndex,
-- SplitAmount, Rotated?): the client's source stack blinks (pending in ToComp)
-- until an answer; ServerHandleSplitRequest returns without one when it does
-- not find the stack or it is too small.
local function on_split(mcomp, mover, from_p, to_p, uid_p, cont_p, idx_p, amount_p)
    local from, to = param(from_p), param(to_p)
    local g = param(uid_p)
    local u, cont = g and ue.try(guid_str, g), ue.try(guid_str, param(cont_p))
    M.note_view(mover, from)
    M.note_view(mover, to)
    if not u or not cont or not ue.valid(to) then return end
    M.stats.host_moves = M.stats.host_moves + 1
    local idx = math.floor(tonumber(param(idx_p)) or -1)
    local at = item_at(to, cont, idx)
    local done = at ~= nil and at.uid ~= u
    local answer = ""
    if not done then
        M.stats.host_refused = M.stats.host_refused + 1
        answer = " - " .. send_failed(mcomp, to, g)
    end
    host_move_log(string.format("containers: %s split %s off %s (uid %s) to %s slot %d: %s%s", ue.short(mover),
        tostring(param(amount_p)), done and at.name or "?", u, comp_name(to), idx,
        done and ("done (new stack " .. at.uid .. " x" .. tostring(at.n) .. ")") or "NOT split", answer), not done)
end

-- Host: the post-hook of an inventory RPC of a remote player (sdc_consume
-- holds the one hook per function and calls this). `before`: that player's
-- inventory as sdc_consume had it just before the request ([uid] = { n =
-- count, ... }), or nil.
function M.host_rpc(rpc, c, before, ...)
    if S.role ~= "host" or not on() then return end
    local mcomp = c and c:get()
    local mover = ue.valid(mcomp) and owner_of(mcomp)
    if not is_remote_character(mover) then return end
    if type(before) ~= "table" then before = nil end
    if rpc == "SERVER_SameContainer_MoveToIndex" then
        on_same_move(mcomp, mover, before, ...)
    elseif rpc == "SERVER_RequestMoveItemToAnotherComp" then
        on_comp_move(mcomp, mover, before, ...)
    elseif rpc == "SERVER_RequestStackItem" then
        on_stack(mcomp, mover, ...)
    elseif rpc == "SERVER_RequestSplitItem" then
        on_split(mcomp, mover, ...)
    end
end

-- net JADD|<container key>|<uid>, client -> host: an item the client's open
-- container still does not show after its add.
local resend_at = {}
local function on_add_request(f, pc)
    if S.role ~= "host" or not on() then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local key, u = f[1] or "", f[2] or ""
    local k = by_key[key]
    local v = k and views[k]
    local comp = v and v.comp
    local mine = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) or main_key(comp) ~= key or not ue.valid(mine) then
        log.debug("containers: %s asked for item %s of container %s, unknown here", ue.short(pawn), u, key)
        return
    end
    local rk = tostring(addr(pawn)) .. "|" .. u
    local now = os.clock()
    if now - (resend_at[rk] or -100) < 2 then return end
    resend_at[rk] = now
    local it = find_item(comp, u)
    if not it then
        log.info("containers: %s asked for %s in %s, which is no longer there", ue.short(pawn), u, comp_name(comp))
        return
    end
    local content = content_of(comp, it.item, 0)
    local ok, err = pcall(function() mine:CLIENT_AddNewItem(it.item, content, comp, ZERO) end)
    M.stats.resends = M.stats.resends + 1
    log.info("containers: %s x%s (uid %s) of %s sent to %s again (CLIENT_AddNewItem, %d inside)%s", it.name,
        tostring(it.n), u, comp_name(comp), ue.short(pawn), #content, ok and "" or (" - FAILED: " .. tostring(err)))
end

-- ===========================================================================
-- Client
-- ===========================================================================

local opened = {}   -- [container key] = { comp =, at =, idx =, n = } (idx: its grid, of n, in the host's order)

-- Client: the host sent this world container's contents (it is open here).
function M.note_open(comp, uids)
    if S.role ~= "client" or not is_world_comp(comp) then return end
    local now = os.clock()
    local list = uids or {}
    for i, g in ipairs(list) do
        local key = ue.try(guid_str, g)
        if key then opened[key] = { comp = comp, at = now, idx = i, n = #list } end
    end
end

local function has_container(comp, key)
    for _, w in ipairs(list_of(ue.prop(comp, "LocalJSIContainers"))) do
        if ue.valid(w) and ue.try(function() return guid_str(w.ContainerID) end) == key then return true end
    end
    return false
end

-- This machine's component of the container the host named, still the same one.
local function resolve(key)
    local e = opened[key]
    if not e then return nil end
    local comp = e.comp
    if not ue.valid(comp) or not ue.class_name(comp):find("JigComponent", 1, true) or not has_container(comp, key) then
        opened[key] = nil
        return nil
    end
    return comp
end

local function find_shown(comp, g)
    local out = {}
    if not pcall(function() comp:DeepSearchForItem(g, out) end) then return nil end
    local s = out.ItemFound
    if ue.valid(s) then return s end
    return nil
end

local function client_log(kind, line)
    if counted(kind) then log.info("%s", line) else log.debug("%s", line) end
end

local function apply_move(comp, key, f)
    local g, to = guid_of(f[3]), guid_of(f[4])
    local idx, rot = math.floor(tonumber(f[5]) or 0), f[6] == "1"
    if not g or not to then return end
    local s = find_shown(comp, g)
    if s and ue.try(function() return guid_str(s.ContainerMother.ContainerID) end) == f[4]
        and tonumber(ue.prop(s, "SlotIndex")) == idx and ue.prop(s, "IsPending") ~= true then
        M.stats.already = M.stats.already + 1
        log.debug("containers: move of %s in %s already shown", f[3], key)
        return
    end
    local ok, err = pcall(function() comp:HandleClientMoveItemToIndex(g, to, idx, rot) end)
    M.stats.applied = M.stats.applied + 1
    client_log("applied", string.format("containers: the host's move of %s to slot %d of %s applied here%s%s", f[3], idx,
        ue.short(owner_of(comp)), s and "" or " (it was not shown here)", ok and "" or (" - FAILED: " .. tostring(err))))
end

local function apply_removed(comp, f)
    local g = guid_of(f[3])
    if not g then return end
    local s = find_shown(comp, g)
    if not s then
        M.stats.already = M.stats.already + 1
        return
    end
    local ok = pcall(function() s:RemoveFromJSIParent({}) end)
    M.stats.applied = M.stats.applied + 1
    client_log("applied", string.format("containers: %s is no longer in %s on the host: the copy shown here removed%s",
        f[3], ue.short(owner_of(comp)), ok and "" or " - FAILED"))
end

-- Where an added item is shown here, for a container of several grids (a
-- station's input / output, a death box): grid i of n in the host's order.
local function grid_note(comp, u, s, how)
    local m = ue.try(function() return guid_str(s.ContainerMother.ContainerID) end)
    local e = m and opened[m]
    if not e or not e.n or e.n < 2 then return end
    client_log("grid", string.format("containers: %s added on the host is shown here in grid %d of %d of %s%s", u,
        e.idx, e.n, ue.short(owner_of(comp)), how or ""))
end

local function apply_added(key, f)
    local u = f[3]
    ue.delay("containers-add", ADD_CHECK_MS, function()
        local comp = resolve(key)
        local g = guid_of(u)
        if not comp or not g then return end
        local s = find_shown(comp, g)
        if s then
            M.stats.already = M.stats.already + 1
            grid_note(comp, u, s, "")
            return
        end
        M.stats.asked = M.stats.asked + 1
        net.send_to_host("JADD", key, u)
        client_log("asked", string.format("containers: %s was added to %s on the host but is not shown here; asked for it",
            u, ue.short(owner_of(comp))))
        -- the host's CLIENT_AddNewItem puts it where the host has it
        ue.delay("containers-add", ADD_CHECK_MS * 2, function()
            local c2 = resolve(key)
            local s2 = c2 and find_shown(c2, g)
            if s2 then grid_note(c2, u, s2, " (after asking)") end
        end)
    end)
end

local function apply_stack(comp, f)
    local d, r = guid_of(f[3]), guid_of(f[5])
    if not d or not r then return end
    local ok = pcall(function() comp:FuncHandleStackResponse(d, math.floor(tonumber(f[4]) or 0), r, math.floor(tonumber(f[6]) or 0)) end)
    M.stats.applied = M.stats.applied + 1
    log.debug("containers: stack %s x%s -> %s x%s in %s applied%s", f[3], f[4], f[5], f[6], ue.short(owner_of(comp)),
        ok and "" or " - FAILED")
end

local function apply_count(comp, f)
    local g = guid_of(f[3])
    if not g then return end
    local n = math.floor(tonumber(f[4]) or 0)
    local ok = pcall(function() comp:ClientUpdateCount(g, n, true) end)
    M.stats.applied = M.stats.applied + 1
    log.debug("containers: count of %s in %s -> %d applied%s", f[3], ue.short(owner_of(comp)), n, ok and "" or " - FAILED")
end

local function apply_durability(comp, f)
    local g, x, y = guid_of(f[3]), tonumber(f[4]), tonumber(f[5])
    if not g or not x or not y then return end
    local ok = pcall(function() comp:ClientFunc_UpdateDurability(g, { X = x, Y = y }) end)
    M.stats.applied = M.stats.applied + 1
    log.debug("containers: durability of %s in %s -> %.1f/%.1f applied%s", f[3], ue.short(owner_of(comp)), x, y,
        ok and "" or " - FAILED")
end

local function apply_done(comp, f)
    local g = guid_of(f[3])
    local s = g and find_shown(comp, g)
    if not s then return end
    if ue.prop(s, "IsPending") ~= true then
        M.stats.already = M.stats.already + 1
        return
    end
    local ok = pcall(function() s:SetPending(false, 1.5, 0) end)
    M.stats.applied = M.stats.applied + 1
    client_log("applied", string.format("containers: %s in %s is done on the host: it stops blinking%s", f[3],
        ue.short(owner_of(comp)), ok and "" or " - FAILED"))
end

-- One op: { op, container key, args... }.
local function jmc_op(f)
    local op, key = f[1], f[2] or ""
    if op == "add" then
        if resolve(key) then apply_added(key, f) end
        return
    end
    local comp = resolve(key)
    if not comp then
        M.stats.unknown = M.stats.unknown + 1
        log.debug("containers: %s for container %s, which is not open here", tostring(op), key)
        return
    end
    if op == "mv" then apply_move(comp, key, f)
    elseif op == "rm" then apply_removed(comp, f)
    elseif op == "stk" then apply_stack(comp, f)
    elseif op == "cnt" then apply_count(comp, f)
    elseif op == "dur" then apply_durability(comp, f)
    elseif op == "done" then apply_done(comp, f) end
end

-- net JMC|*|<container key>|<op,args...>|<op,args...>|... (the ops of one
-- host tick for one container, in order), or JMC|<op>|<container key>|<args...>
-- (one op, as before 0.7.3), host -> client.
local function on_jmc_msg(f)
    if S.role ~= "client" or not on() then return end
    if f[1] ~= "*" then return jmc_op(f) end
    local key = f[2] or ""
    for i = 3, #f do
        local one = {}
        for part in (f[i] .. ","):gmatch("([^,]*),") do one[#one + 1] = part end
        table.insert(one, 2, key)
        jmc_op(one)
    end
end

-- BP_JigComponent.Jig_UnhandledEvent(FromContainer, ToContainer, ToIndex,
-- DroppedItem, Rotated, Amount), post (client): the move this player asked for.
local function on_drop(c, from_p, to_p, idx_p, item_p, _, amount_p)
    if S.role ~= "client" then return end
    local s = param(item_p)
    if not ue.valid(s) then return end
    local function cname(w)
        if not ue.valid(w) then return "?" end
        local n = ue.str(ue.prop(w, "ContainerName"))
        local comp = ue.prop(w, "JigMultiplayerComp")
        return string.format("%s%s", n ~= "" and n or ue.short(w), ue.valid(comp) and (" of " .. comp_name(comp)) or "")
    end
    M.stats.client_moves = M.stats.client_moves + 1
    client_log("client_moves", string.format("containers: move of %s x%s (uid %s) asked: %s -> %s slot %s (%s)",
        item_name(ue.prop(s, "JigDataAsset")), tostring(param(amount_p) or ue.prop(s, "ItemCount")),
        ue.try(function() return guid_str(s.ItemUniqueID) end) or "?", cname(param(from_p)), cname(param(to_p)),
        tostring(param(idx_p)), ue.prop(s, "IsPending") == true and "pending" or "not pending"))
end

-- Pending slots of the open containers that the host never answered.
local waiting = {}   -- ["component address|uid"] = first seen
local function check_stuck(now)
    local live, seen = {}, {}
    for key, e in pairs(opened) do
        if now - e.at > OPEN_KEEP then
            opened[key] = nil
        else
            local comp = resolve(key)
            local ck = comp and addr(comp)
            if ck and seen[ck] then comp = nil end
            if ck then seen[ck] = true end
            for _, s in ipairs(comp and list_of(ue.prop(comp, "PendingRequests")) or {}) do
                local u = ue.valid(s) and ue.try(function() return guid_str(s.ItemUniqueID) end)
                if u then
                    local wk = tostring(ck) .. "|" .. u
                    live[wk] = true
                    waiting[wk] = waiting[wk] or now
                    if now - waiting[wk] > STUCK_S then
                        local out = {}
                        pcall(function() comp:RemoveRequestByUID(guid_of(u), false, out) end)
                        M.stats.stuck = M.stats.stuck + 1
                        log.warn("containers: %s (uid %s) in %s waited %.0f s for the host; it stops blinking where it is%s",
                            item_name(ue.prop(s, "JigDataAsset")), u, ue.short(owner_of(comp)), now - waiting[wk],
                            out.Removed == true and "" or " (not removed)")
                        waiting[wk] = nil
                        live[wk] = nil
                    end
                end
            end
        end
    end
    for wk in pairs(waiting) do
        if not live[wk] then waiting[wk] = nil end
    end
end

-- ===========================================================================
-- Ticks
-- ===========================================================================

local hook_at = -100

function M.host_tick()
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        try_hook(JIG_FN .. "MC_MoveItemToIndex", "mc-move", on_mc_move)
        try_hook(JIG_FN .. "MC_ItemRemoved", "mc-removed", on_mc_removed)
        try_hook(JIG_FN .. "MC_AddNewItem", "mc-add", on_mc_add)
        try_hook(JIG_FN .. "MC_UpdateStack", "mc-stack", on_mc_stack)
        try_hook(JIG_FN .. "MC_UpdateCount", "mc-count", on_mc_count)
        try_hook(JIG_FN .. "MC_UpdateCounts", "mc-counts", on_mc_counts)
        try_hook(JIG_FN .. "MC_SameCompUpdateSplitRequest", "mc-split", on_mc_split)
        try_hook(JIG_FN .. "MC_NewItemAdded", "mc-new", on_mc_new)
        try_hook(JIG_FN .. "MC_UpdateDurability", "mc-dur", on_mc_dur)
        try_hook(JIG_FN .. "MC_OnPendingDone", "mc-done", on_mc_done)
    end
    -- (a delayed send that never ran)
    if jmc.due then jmc_flush() end
    for k, v in pairs(views) do
        -- viewers that left or went too long ago (up to 0.7.3 only a forward
        -- dropped them: a view nobody forwarded to stayed for good)
        for pk, e in pairs(v.by) do
            if not viewer_live(e, now) then v.by[pk] = nil end
        end
        if not ue.valid(v.comp) or next(v.by) == nil then
            views[k] = nil
            jmc.vc[k] = nil
            if by_key[v.key] == k then by_key[v.key] = nil end
        end
    end
    for k, t in pairs(resend_at) do
        if now - t > 10 then resend_at[k] = nil end
    end
    for k, t in pairs(gone.told) do
        if now - t > 10 then gone.told[k] = nil end
    end
    deathbox.host_tick()
end

function M.client_tick()
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        -- (log only: this player's own move requests; with config debug)
        if log.debug_enabled then try_hook(JIG_FN .. "Jig_UnhandledEvent", "move-asked", on_drop) end
    end
    if on() then check_stuck(now) end
    deathbox.client_tick()
end

function M.reset()
    views, by_key, resend_at = {}, {}, {}
    gone.told = {}
    jmc.q, jmc.order, jmc.due, jmc.vc, jmc.sum, jmc.sum_order = {}, {}, false, {}, {}, {}
    opened, waiting, logged = {}, {}, {}
    hook_at = -100
    deathbox.reset()
end

function M.register_handlers()
    -- host -> client: JMC|*|<container key>|<op,args>|...  (a world container's multicasts of one tick, reliably;
    -- op mv|rm|add|stk|cnt|dur|done; the old single form JMC|<op>|<container key>|<args> is still read)
    net.on("JMC", on_jmc_msg)
    -- client -> host: JADD|<container key>|<uid>   (an added item the open container does not show)
    net.on("JADD", on_add_request)
    deathbox.register_handlers()
end

return M
