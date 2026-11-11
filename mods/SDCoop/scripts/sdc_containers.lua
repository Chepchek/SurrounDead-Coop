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
--   (JMC); the client runs the multicast's own handler on its copy of the
--   component (HandleClientMoveItemToIndex, the removal of MC_ItemRemoved,
--   FuncHandleStackResponse, ClientUpdateCount). Each handler leaves a view
--   that already shows the result as it is. An added item is checked a
--   moment later; if it is still missing the client asks (JADD) and the host
--   sends it with the plugin's own reliable CLIENT_AddNewItem(item, content,
--   <container component>).
--   host, after each move request: the item where the request wanted it? If
--   not, the plugin's own failure answer CLIENT_MoveToIndexFailed(uid,
--   <component holding the pending slot>) - the blinking stops, the item
--   stays where it is (the host did not move it).
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

local views = {}    -- [component address] = { comp =, key =, by = { [pawn address] = { pawn =, t = } } }
local by_key = {}   -- [container key] = component address

-- The container's key on both machines: its first main container UID (the
-- client's widgets get these as ContainerID from CLIENT_ContainerDataResponse).
local function main_key(comp)
    local ids = list_of(ue.prop(comp, "MainContainersIDs"))
    local g = ids[1]
    if g == nil then return nil end
    return ue.try(guid_str, g)
end

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
    v.by[pk] = { pawn = pawn, t = os.clock() }
end

local function dist2(a, b)
    if not a or not b then return 0 end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
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
        if now - e.t > VIEW_KEEP or not is_remote_character(p) then
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

-- One multicast of a world container to its remote viewers.
local function forward(comp, op, ...)
    if S.role ~= "host" or not on() or not views[addr(comp) or -1] or not is_world_comp(comp) then return end
    local vs, key = viewers_of(comp)
    if #vs == 0 or not key then return end
    local names = {}
    M.stats.forwards = M.stats.forwards + 1
    for _, e in ipairs(vs) do
        net.send_to(e.pc, "JMC", op, key, ...)
        names[#names + 1] = ue.short(e.pawn)
    end
    local line = string.format("containers: %s %s in %s -> %s (reliable copy of the plugin's multicast)", op,
        table.concat({ ... }, " "), comp_name(comp), table.concat(names, ", "))
    if counted("forwards") then log.info("%s", line) else log.debug("%s", line) end
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

-- The plugin's own answer to a refused move: the pending slot in `holder`
-- stops blinking, the item stays where it is.
local function send_failed(mover_comp, holder, g)
    local ok, err = pcall(function() mover_comp:CLIENT_MoveToIndexFailed({ { A = g.A, B = g.B, C = g.C, D = g.D } }, holder) end)
    M.stats.failed_sent = M.stats.failed_sent + 1
    return ok and "the client was told (CLIENT_MoveToIndexFailed)" or ("telling the client FAILED: " .. tostring(err))
end

local function host_move_log(line, bad)
    if bad then log.warn("%s", line)
    elseif counted("host_moves") then log.info("%s", line)
    else log.debug("%s", line) end
end

-- SERVER_SameContainer_MoveToIndex(JigMPCompRef, ItemUID, ToContainerUID, ToIndex, Rotated?, InContainerIndex)
local function on_same_move(mcomp, mover, ref_p, uid_p, to_p, idx_p)
    local ref = param(ref_p)
    local g, to = param(uid_p), ue.try(guid_str, param(to_p))
    local u = g and ue.try(guid_str, g)
    if not ue.valid(ref) or not u or not to then return end
    M.note_view(mover, ref)
    M.stats.host_moves = M.stats.host_moves + 1
    local idx = math.floor(tonumber(param(idx_p)) or -1)
    local it = find_item(ref, u)
    local done = it and it.mother == to and tonumber(it.slot) == idx
    local answer = ""
    if not done then
        M.stats.host_refused = M.stats.host_refused + 1
        answer = " - " .. send_failed(mcomp, ref, g)
    end
    host_move_log(string.format("containers: %s moved %s (uid %s) inside %s to slot %d: %s%s", ue.short(mover),
        it and it.name or "?", u, comp_name(ref), idx, done and "done" or (it and ("NOT moved (still at slot " ..
        tostring(it.slot) .. ")") or "NOT moved (not there)"), answer), not done)
end

-- SERVER_RequestMoveItemToAnotherComp(From, To, ItemUID, FinalRotation, ToIndex, ToContainer, ...)
local function on_comp_move(mcomp, mover, from_p, to_p, uid_p, _, idx_p)
    local from, to = param(from_p), param(to_p)
    local g = param(uid_p)
    local u = g and ue.try(guid_str, g)
    if not u or not ue.valid(from) or not ue.valid(to) then return end
    M.note_view(mover, from)
    M.note_view(mover, to)
    M.stats.host_moves = M.stats.host_moves + 1
    if is_vendor(from) or is_vendor(to) then return end
    local in_to, in_from = find_item(to, u), find_item(from, u)
    local done = in_to ~= nil and in_from == nil
    local answer = ""
    if not done and in_from and not in_to then
        M.stats.host_refused = M.stats.host_refused + 1
        answer = " - " .. send_failed(mcomp, to, g)
    end
    host_move_log(string.format("containers: %s moved %s x%s (uid %s) from %s to %s slot %s: %s%s", ue.short(mover),
        (in_to or in_from or {}).name or "?", tostring((in_to or in_from or {}).n or "?"), u, comp_name(from),
        comp_name(to), tostring(param(idx_p)), done and "done" or (in_from and "NOT moved" or "gone from both (merged?)"),
        answer), not done and in_from ~= nil)
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
-- holds the one hook per function and calls this).
function M.host_rpc(rpc, c, ...)
    if S.role ~= "host" or not on() then return end
    local mcomp = c and c:get()
    local mover = ue.valid(mcomp) and owner_of(mcomp)
    if not is_remote_character(mover) then return end
    if rpc == "SERVER_SameContainer_MoveToIndex" then
        on_same_move(mcomp, mover, ...)
    elseif rpc == "SERVER_RequestMoveItemToAnotherComp" then
        on_comp_move(mcomp, mover, ...)
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

-- net JMC|<op>|<container key>|<args...>, host -> client.
local function on_jmc_msg(f)
    if S.role ~= "client" or not on() then return end
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
    for k, v in pairs(views) do
        if not ue.valid(v.comp) or next(v.by) == nil then
            views[k] = nil
            if by_key[v.key] == k then by_key[v.key] = nil end
        end
    end
    for k, t in pairs(resend_at) do
        if now - t > 10 then resend_at[k] = nil end
    end
    deathbox.host_tick()
end

function M.client_tick()
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        try_hook(JIG_FN .. "Jig_UnhandledEvent", "move-asked", on_drop)
    end
    if on() then check_stuck(now) end
    deathbox.client_tick()
end

function M.reset()
    views, by_key, resend_at = {}, {}, {}
    opened, waiting, logged = {}, {}, {}
    hook_at = -100
    deathbox.reset()
end

function M.register_handlers()
    -- host -> client: JMC|<mv|rm|add|stk|cnt>|<container key>|<args>   (a world container's multicast, reliably)
    net.on("JMC", on_jmc_msg)
    -- client -> host: JADD|<container key>|<uid>   (an added item the open container does not show)
    net.on("JADD", on_add_request)
    deathbox.register_handlers()
end

return M
