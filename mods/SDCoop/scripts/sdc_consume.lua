-- SDCoop: using items up in co-op - crafting and medical items.
-- Driven by sdc_items (init / host_tick / host_player / client_tick / reset);
-- its inventory walk (inventory / equipment_of) is shared with sdc_tools and
-- sdc_items in the host tick.
--
-- Crafting (JigSInventory). The crafting widgets (W_PlayerCraftingUI,
-- W_CraftingWorkbenchUI, W_ConstructionWorkbenchUI, W_CookingUI) send
-- SERVER_RequestCraftItem from the player's own BP_JigMultiplayer with the
-- UIDs of the components found in the CLIENT's inventory widgets. The host's
-- HandleServerFuncRequestCraft adds the crafted item first and then consumes
-- whatever of those UIDs it still finds; it never checks that the recipe was
-- paid. CLIENT_ItemCraftedResponse later gives the client the new counts. In
-- single player all of that runs in one frame, so the widget always sees the
-- consumed state. On a client:
--   * "craft N" (the click handler's loop, W_PlayerCraftingUI @151-1005) sends
--     N requests at once, all with the same component UIDs: the host pays the
--     first and makes the others for free;
--   * after the loop the button is enabled again from the same unconfirmed
--     view (@1025-1062), so a quick second click does the same.
-- Fix: one craft request in flight per client. While the host has not
-- answered, the widget's own CheckIngredientsAvailability answers "not
-- available" (what the game does when the components are gone). The rest of
-- a "craft N" click is crafted one by one: after each answer the widget is
-- refreshed the way the game refreshes it on a count change (ClearContainer,
-- AddRequiredItems, SetCraftableItems) and its own craft button handler runs
-- again. The host's own crafting is unchanged (synchronous there).
-- Log lines on both machines show every craft: what the client asked for,
-- what the host had and consumed, what the client was told and shows.
--
-- Medical items. Using one sends SERVER_RequestConsumeItem; the host consumes
-- the item and runs ConsumeItem on ITS copy of the character: IncreaseHealth
-- there (health lives on the host), but the cure is
-- MedicalComponent.CLIENT_RemoveMedicalEffect, a Client RPC, so for a client's
-- character it runs only on the client's copy. The host's Bleed? /
-- HeavyBleed? / BrokenBone? and their damage timers never stop, and the
-- bleeding eats the healing. The natural end has the same problem: OnRep_Bleed?
-- starts it with Event_TimeToStopBleed, a Client RPC too.
-- Fix (host, other players' characters): after ConsumeItem the same cure on the
-- host's MedicalComponent (flag false + its own OnRep_*, or its own
-- InfectionState), and the component's own Time_Bleed / Time_HeavyBleed /
-- Time_BrokenBone stop timers on the host, with the game's durations.
--
-- Items a use gives. The context menu (JigContextMenuComp: ContextConsume ->
-- ItemGainedFromConsumption such as an empty can, ContextRipClothing ->
-- DA_Cloth x1-2, ContextFillBottle, ContextOpenLootBox) and HotBarConsume
-- send the consume to the host, then call JigTryAddItemSomewhere on the
-- CLIENT. That is single-player code: there it reserves a slot
-- (JigTryAddGetPendingRef: a new JSI_Slot with a local GUID, SetPending ->
-- the FadeInOut ping-pong animation, i.e. the item flickers) and fills it with
-- AddNewItemToSlot on MainJigContainers, which is empty on a client. The add
-- fails, nothing ever resolves the pending slot, and the host never adds the
-- item at all: a flickering item that exists only on the client.
-- Fix: the client removes its placeholder the way the game drops a failed
-- pending request (RemoveRequestByUID(uid, ClearWidget)) and asks the host
-- (IGAIN) for the item; the host adds it with the plugin's own server-side
-- add, AddNewItemSomewhere (stacks or a free slot, then CLIENT_UpdateCounts /
-- CLIENT_AddNewItem to the owner, or a drop at the player's feet when full;
-- the game uses it for animal loot). It is accepted only right after a use
-- request from that player. A pending slot the host never answers (20 s) is
-- removed the same way and logged.
-- The same single-player add run by the HOST for a remote player (the water
-- well filling empty containers, a caught fish) finds no inventory widget
-- there and drops the item at the player's feet; that drop goes into the
-- player's inventory (see on_host_add).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local net = require("sdc_net")
local containers = require("sdc_containers")

local M = {
    stats = { crafts_sent = 0, crafts_gated = 0, crafts_answered = 0, crafts_queued = 0, host_crafts = 0,
              host_unpaid = 0, uses = 0, cures = 0, stop_timers = 0, desync_reports = 0,
              gains_sent = 0, gains_added = 0, gains_refused = 0, stale_pending = 0,
              host_adds = 0, host_adds_lost = 0 },
}
local S
function M.init(state) S = state end

local addr = ctx.addr

local JIG_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local PLAYER_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local MEDICAL_FN = "/Game/Blueprints/Components/MedicalComponent.MedicalComponent_C:"
local CLICK_FN = "BndEvt__Button_81_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"

-- Crafting widgets: the same click loop, CheckIngredientsAvailability(out
-- Proceed), Button_81, CurrentFaded, CountIndex, CraftIndex, JSIContainer_1;
-- their refresh functions differ in name only.
local CRAFT_UIS = {}
for _, u in ipairs({
    { "W_PlayerCraftingUI",        "AddRequiredItems",   "Set Craftable Items" },
    { "W_CraftingWorkbenchUI",     "AddRequiredItems",   "SetCraftableItems" },
    { "W_ConstructionWorkbenchUI", "Add Required Items", "SetCraftableItems" },
    { "W_CookingUI",               "AddRequiredItems",   "SetCraftableItems" },
}) do
    CRAFT_UIS[#CRAFT_UIS + 1] = { name = u[1], class = u[1] .. "_C", required = u[2], list = u[3],
        path = string.format("/Game/Inventory/Widgets/Crafting/%s.%s_C", u[1], u[1]) }
end

-- BP struct members (GUID-suffixed names)
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_STATS = "Stats_26_C770972746930CB80CC49AB7A6D19359"
local F_STAT_NAME = "STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10"
local F_STAT_MAX = "MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"

local INFLIGHT_TIMEOUT = 8      -- s without the host's answer before the craft gate opens again
local SAME_CLICK = 0.5          -- s: hook calls this close together belong to one click
local WIDGET_KEEP = 30          -- s a crafting widget is remembered (well under the 60 s GC)
local DESYNC_EVERY = 5          -- s between client inventory checks
local SAME_CALL = 0.2           -- s: a nested hook call belongs to the call being handled
local GAIN_WINDOW = 6           -- s around a use request in which the host accepts its items
local GAIN_MAX = 12             -- items one use may give (a loot box gives several)
local STALE_PENDING = 20        -- s a pending slot may wait for the host before it is removed

local function guid_str(g)
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

local function guid_tbl(g)
    return { A = g.A, B = g.B, C = g.C, D = g.D }
end

local function is_player_character(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

local function is_locally_controlled(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

local function is_remote_character(p)
    if not is_player_character(p) then return false end
    return ue.valid(ue.prop(ue.prop(p, "Controller"), "NetConnection"))
end

local function owner_of(comp)
    local o = ue.try(function() return comp:GetOwner() end)
    if ue.valid(o) then return o end
    return nil
end

local function item_name(da)
    if not ue.valid(da) then return "?" end
    return (ue.short(da):gsub("^DA_", ""))
end

local function param(p)
    if not p then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

-- Array (param value or property) -> Lua list of element values.
local function list_of(arr)
    local out = {}
    if arr == nil then return out end
    pcall(function()
        arr:ForEach(function(_, e) out[#out + 1] = e:get() end)
    end)
    return out
end

-- sdc_items is loaded before this module is used (it drives it).
local function host_item_uids()
    local items = package.loaded["sdc_items"]
    if type(items) ~= "table" or not items.host_item_uids then return nil, 0, nil end
    return items.host_item_uids()
end

-- One RegisterHook per BP function (post-hooks: they run after the body).
local hooked = {}
local function try_hook(path, tag, fn)
    if hooked[path] then return end
    local ok = pcall(RegisterHook, path, function(c, ...)
        local okc, err = pcall(fn, c, ...)
        if not okc then log.err_throttled("consume." .. tag, "consume: %s hook: %s", tag, tostring(err)) end
    end)
    if ok then
        hooked[path] = true
        log.info("consume: %s hook ok (%s)", tag, path:match(":([^:]+)$") or path)
    end
end

-- ===========================================================================
-- Inventory views
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- One walk of an inventory (MainJigContainers), shared
-- ---------------------------------------------------------------------------
-- Every struct member read through UE4SS is a name lookup (Lua string ->
-- FName -> the struct's property list) plus a new userdata, a few us each.
-- The host's 1 s tick walked each remote player's inventory four times (the
-- ledger here, sdc_tools' night vision battery, sdc_items' equipment
-- durabilities and its ITEMS list; ~60 member reads per item, the item UID
-- read up to three times per walk): ~25-30 ms a second with one client. Now
-- one walk per player and second reads each member once (inventory(jig,
-- true), handed to sdc_tools and sdc_items through the tick's `pass`); the
-- ledger walks of the inventory hooks read only what the ledger needs.
-- Entry: { uid = "A:B:C:D", g = Guid table, n = count, id = item name } and,
-- full walk only, dur (Durability.X), idx (InContainerIndex), sub (UID of the
-- item's first sub-container), cuid (UID of its container).
-- Result: { list = entries in walk order, by_uid = [uid] = entry (the last
-- one, as the old maps), at0 = [container uid] = the entry at index 0 (the
-- last one), bad = the first read error (the old ITEMS walk failed on it) }.

local names = {}      -- [item data asset address] = item_name() (data assets stay loaded)
local names_n = 0
local function item_name_of(da)
    local k = da ~= nil and addr(da) or nil
    if type(k) ~= "number" or k == 0 then return item_name(da) end
    local s = names[k]
    if s == nil then
        s = item_name(da)
        if s ~= "?" then
            if names_n >= 4096 then names, names_n = {}, 0 end
            names[k] = s
            names_n = names_n + 1
        end
    end
    return s
end

local W = nil   -- the walk being filled (module-level callbacks: no closures per item)

local function rd_dur(info) return info[F_DUR].X end
local function rd_index(item) return item[F_INDEX] end
local function rd_cuid(cont) return guid_str(cont[F_CONT_UID]) end
local function sub_cb(_, s)
    if W.sub == nil then W.sub = guid_str(s:get()[F_SUB_ID]) end
    return true   -- only the first one is used (UE4SS stops a ForEach on true)
end
local function rd_sub(item) item[F_SUBS]:ForEach(sub_cb) end

local function rd_item(it)
    local item = it:get()
    local u = item[F_USID]
    local a, b, c, d = u.A, u.B, u.C, u.D
    local info = item[F_INFO]
    local w = W
    local e = { uid = string.format("%d:%d:%d:%d", a, b, c, d), g = { A = a, B = b, C = c, D = d },
                n = info[F_COUNT], id = item_name_of(info[F_ITEMID]) }
    w.list[#w.list + 1] = e
    w.by_uid[e.uid] = e
    if not w.full then return end
    local okd, x = pcall(rd_dur, info)
    if okd then e.dur = x elseif not w.bad then w.bad = x end
    local oki, i = pcall(rd_index, item)
    if oki then e.idx = i elseif not w.bad then w.bad = i end
    w.sub = nil
    pcall(rd_sub, item)
    e.sub = w.sub
    e.cuid = w.cuid
    if e.idx == 0 and w.cuid then w.at0[w.cuid] = e end
end

local function item_cb(_, it)
    local ok, err = pcall(rd_item, it)
    if not ok and not W.bad then W.bad = err end
end

local function rd_cont(c)
    local cont = c:get()
    local w = W
    w.cuid = nil
    if w.full then
        local ok, cu = pcall(rd_cuid, cont)
        if ok then w.cuid = cu elseif not w.bad then w.bad = cu end
    end
    cont[F_ITEMS]:ForEach(item_cb)
end

local function cont_cb(_, c)
    local ok, err = pcall(rd_cont, c)
    if not ok and not W.bad then W.bad = err end
end

local function rd_all(jig) jig.MainJigContainers:ForEach(cont_cb) end

-- Host: the inventory of a JigComponent (see above); `full` adds what
-- sdc_items / sdc_tools need (durabilities, sub-containers).
function M.inventory(jig, full)
    local w = { list = {}, by_uid = {}, at0 = {}, full = full == true }
    if not ue.valid(jig) then return w end
    local prev = W
    W = w
    local ok, err = pcall(rd_all, jig)
    W = prev
    if not ok and not w.bad then w.bad = err end
    w.full, w.cuid, w.sub = nil, nil, nil
    return w
end

-- Host: { [uid] = { n = count, id = item name, g = Guid table } } of a
-- JigComponent's authoritative inventory (MainJigContainers: every container,
-- worn items and the containers inside them included).
local function server_items(jig)
    if not ue.valid(jig) then return {} end
    return M.inventory(jig, false).by_uid
end

-- Host: a character's HelperComp.EquipmentUIDs as { { tag = slot tag, g =
-- "A:B:C:D" } } in map order, and the read error (the list holds what came
-- before it). equipment_of: once per tick's `pass` (sdc_tools: the helmet,
-- sdc_items: the UIDS message).
local eq_list = nil
local function eq_cb(k, v)
    local key, val = k:get(), v:get()
    eq_list[#eq_list + 1] = { tag = ue.str(key.TagName), g = guid_str(val) }
end
local function rd_equipment(helper) helper.EquipmentUIDs:ForEach(eq_cb) end

function M.equipment(helper)
    local list = {}
    local prev = eq_list
    eq_list = list
    local ok, err = pcall(rd_equipment, helper)
    eq_list = prev
    return list, (not ok) and err or nil
end

function M.equipment_of(pass, helper)
    if pass and pass.equip then return pass.equip, pass.equip_err end
    local list, err = M.equipment(helper)
    if pass then pass.equip, pass.equip_err = list, err end
    return list, err
end

-- Where a client slot widget is: "<container name> slot <index>[, pending]".
local function slot_where(slot, cont)
    cont = cont or ue.prop(slot, "ContainerMother")
    local cname = ue.str(ue.prop(cont, "ContainerName"))
    if cname == "" then cname = ue.short(cont) end
    return string.format("%s slot %s%s", cname, tostring(ue.prop(slot, "SlotIndex")),
        ue.prop(slot, "IsPending") == true and ", pending" or "")
end

-- One container widget and the containers inside its items: a worn
-- backpack / vest / clothing pockets (the slot's SpecialContainerRef, a
-- BP_MainSpecialContainer with AllContainers) or a plain inner container
-- (SlotContainer) - the way JigTryAddGetPendingRef walks them. The host's
-- MainJigContainers has all of these (flat), so the view must too.
local function scan_container(w, out, depth, seen)
    if depth > 4 or not ue.valid(w) then return end
    local k = addr(w)
    if not k or seen[k] then return end
    seen[k] = true
    for _, slot in ipairs(list_of(ue.prop(w, "ArrayOfItems"))) do
        if ue.valid(slot) then
            local ok, uid = pcall(function() return guid_str(slot.ItemUniqueID) end)
            if ok and uid ~= "0:0:0:0" and not out[uid] then
                out[uid] = { n = ue.prop(slot, "ItemCount"), name = item_name(ue.prop(slot, "JigDataAsset")),
                             da = ue.prop(slot, "JigDataAsset"), slot = slot, where = ue.try(slot_where, slot, w) or "?" }
            end
            local special = ue.prop(slot, "SpecialContainerRef")
            if ue.valid(special) then
                for _, c in ipairs(list_of(ue.prop(special, "AllContainers"))) do scan_container(c, out, depth + 1, seen) end
            end
            scan_container(ue.prop(slot, "SlotContainer"), out, depth + 1, seen)
        end
    end
end

-- Client: { [uid] = { n = count, name = item name, where = slot_where() } } of
-- what the own inventory widgets show (LocalJSIContainers -> JSI_Slot, and
-- the containers inside worn items).
local function client_view(jig)
    local out = {}
    if not ue.valid(jig) then return out end
    local seen = {}
    for _, w in ipairs(list_of(ue.prop(jig, "LocalJSIContainers"))) do
        pcall(scan_container, w, out, 0, seen)
    end
    return out
end

-- ===========================================================================
-- Crafting: client
-- ===========================================================================

local function new_gate()
    return {
        n = 0,            -- craft requests sent and not answered
        since = 0,        -- os.clock() of the last request
        armed = nil,      -- { w, at, name }: a widget's check passed, its request comes next
        click = nil,      -- { w, at }: the widget that sent the last request
        queue = nil,      -- { key, left, craft }: the rest of a "craft N" click
        touched = {},     -- [widget address] = true: left with a disabled button by the gate
        local_add = -100, -- os.clock() of a pending slot taken outside crafting
        local_slot = nil, -- { slot, stack, at }: that slot (JigTryAddGetPendingRef's OutputPin / Stack?)
        local_drop = -100, -- os.clock() of a local add that found no room (the game drops it here)
        logged = false,
    }
end
local gate = new_gate()
local widgets = {}        -- [widget address] = { w = widget, ui = CRAFT_UIS entry, at = os.clock() }

local function own_jig_comp(c)
    local comp = c and c:get()
    if not ue.valid(comp) then return nil end
    local owner = owner_of(comp)
    if not is_player_character(owner) or not is_locally_controlled(owner) then return nil end
    return comp
end

-- A remembered widget, still the same live object.
local function widget_of(k)
    local e = widgets[k]
    if not e or os.clock() - e.at > WIDGET_KEEP then return nil end
    if not ue.valid(e.w) or ue.class_name(e.w) ~= e.ui.class then return nil end
    return e
end

-- The game's own refresh on a count change, minus the count change: the
-- required items, the craft button (AddRequiredItems: SetIsEnabled(CanCraft?))
-- and the craftable list, now from the counts the host confirmed.
local function refresh_widget(e)
    local w = e.w
    if not ue.valid(ue.prop(w, "CurrentFaded")) or not ue.valid(ue.prop(w, "MPComponent")) then return false end
    pcall(function() w.JSIContainer_1:ClearContainer() end)
    local ok1 = pcall(function() w[e.ui.required](w) end)
    local ok2 = pcall(function() w[e.ui.list](w) end)
    log.debug("consume: %s refreshed (required=%s list=%s)", e.ui.name, tostring(ok1), tostring(ok2))
    return ok1
end

-- After an answer: the next craft of a "craft N" click, through the widget's
-- own craft button handler (it checks the components again itself).
local function continue_queue(q, refreshed)
    local e = widget_of(q.key)
    local stop = nil
    if not e then
        stop = "the crafting window is gone"
    elseif not refreshed then
        stop = "no recipe selected"
    elseif ue.prop(e.w, "CraftIndex") ~= q.craft then
        stop = "another recipe was selected"
    elseif ue.try(function() return e.w.Button_81:GetIsEnabled() end) ~= true then
        stop = "the components ran out"
    end
    if stop then
        gate.queue = nil
        log.info("consume: the remaining %d craft(s) stopped: %s", q.left, stop)
        return
    end
    ue.delay("consume.craft_next", 150, function()
        if gate.queue ~= q then return end
        if gate.n > 0 then return end   -- the player clicked meanwhile: after that answer
        local we = widget_of(q.key)
        if not we then gate.queue = nil; return end
        q.left = q.left - 1
        if q.left <= 0 then gate.queue = nil end
        M.stats.crafts_queued = M.stats.crafts_queued + 1
        local ok, err = pcall(function() we.w[CLICK_FN](we.w) end)
        if not ok then
            gate.queue = nil
            log.warn("consume: the next queued craft failed: %s", tostring(err))
        else
            log.debug("consume: next queued craft started (%d left)", q.left)
        end
    end)
end

local function release(success, why)
    if gate.n <= 0 then return end
    gate.n = gate.n - 1
    if gate.n > 0 then return end
    gate.logged = false
    local refreshed = {}
    for k in pairs(gate.touched) do
        local e = widget_of(k)
        if e then refreshed[k] = refresh_widget(e) end
    end
    gate.touched = {}
    local q = gate.queue
    if not q then return end
    if not success then
        gate.queue = nil
        log.info("consume: the remaining %d craft(s) cancelled (%s)", q.left, why)
        return
    end
    continue_queue(q, refreshed[q.key])
end

-- BP_JigComponent.JigTryAddGetPendingRef(Info, CheckStacking, out OutputPin,
-- out Stack?), post (client). A crafting widget calls it right after a passed
-- check and sends the request next. The game also calls it outside crafting
-- (JigTryAddItemSomewhere for the item a use gives), which is not a request to
-- the host: its slot is remembered for on_local_add.
local placeholders = {}   -- [uid string] = os.clock(): slots reserved here (no item on the host yet)

local function on_pending_ref(c, _, _, out_p, stack_p)
    if S.role ~= "client" then return end
    local now = os.clock()
    local a = gate.armed
    gate.armed = nil
    local own = own_jig_comp(c)
    local reserved = param(out_p)
    if ue.valid(reserved) and param(stack_p) ~= true then
        local u = ue.try(function() return guid_str(reserved.ItemUniqueID) end)
        if u then placeholders[u] = now end
    end
    -- (another component: a station's own inventory, from its single-player code)
    if not own or not a or now - a.at > SAME_CLICK then
        if own then gate.local_add = now end
        local slot = param(out_p)
        gate.local_slot = { slot = ue.valid(slot) and slot or nil, stack = param(stack_p) == true, at = now }
        if not ue.valid(slot) then gate.local_drop = now end
        return
    end
    gate.n = gate.n + 1
    gate.since = now
    gate.click = { w = a.w, at = now }
    M.stats.crafts_sent = M.stats.crafts_sent + 1
    local line = string.format("consume: craft request %d sent (%s), waiting for the host's answer",
        M.stats.crafts_sent, a.name)
    if M.stats.crafts_sent <= 5 then log.info("%s", line) else log.debug("%s", line) end
end

-- Components the widget picked (its RequestConsume, filled by the check) that
-- this inventory shows but the host does not have: the host would make the
-- item for nothing (it adds the item first and consumes only what it finds),
-- and the component stays here to be used again. Items in a station's own
-- containers are not in this inventory and are not judged here.
local ghost_logged = {}
local function ghost_components(w)
    if cfg.get("craft_needs_components") == false then return nil end
    local host, n = host_item_uids()
    if not host or n == 0 then return nil end
    local uids = list_of(ue.prop(w, "RequestConsume"))
    if #uids == 0 then return nil end
    local me = ue.local_pawn()
    local view = client_view(me and ue.prop(me, "BP_JigMultiplayer"))
    local bad = {}
    for _, g in ipairs(uids) do
        local u = ue.try(guid_str, g)
        local e = u and view[u]
        if e and host[u] == nil then
            bad[#bad + 1] = string.format("%s x%s (uid %s, %s)", e.name, tostring(e.n), u, e.where)
        end
    end
    if #bad == 0 then return nil end
    return table.concat(bad, "; ")
end

-- <crafting widget>.CheckIngredientsAvailability(out Proceed), post (client).
local function on_check_ingredients(ui, c, proceed_p)
    if S.role ~= "client" then return end
    local w = c and c:get()
    if not ue.valid(w) then return end
    local k = addr(w)
    if not k then return end
    widgets[k] = { w = w, ui = ui, at = os.clock() }
    if param(proceed_p) ~= true then return end
    -- a station the host does not have: refused; otherwise the host gets the
    -- recipe table of this window first (sdc_stations)
    local stations = package.loaded["sdc_stations"]
    if type(stations) == "table" and stations.client_craft_check then
        local ok_st = stations.client_craft_check(w)
        if not ok_st then
            pcall(function() proceed_p:set(false) end)
            return
        end
    end
    local ghost = ghost_components(w)
    if ghost then
        if pcall(function() proceed_p:set(false) end) then
            M.stats.crafts_held_unpaid = (M.stats.crafts_held_unpaid or 0) + 1
            if not ghost_logged[ghost] then
                ghost_logged[ghost] = true
                log.warn("consume: %s: craft held back - its components are not in the host's copy of this inventory: %s",
                    ui.name, ghost)
            end
        end
        return
    end
    if gate.n <= 0 or cfg.get("craft_one_at_a_time") == false then
        gate.armed = { w = k, at = os.clock(), name = ui.name }
        return
    end
    -- a request is in flight: its components are not confirmed yet
    if not pcall(function() proceed_p:set(false) end) then
        log.err_throttled("consume.gate", "consume: cannot hold the craft back (Proceed not writable)")
        return
    end
    M.stats.crafts_gated = M.stats.crafts_gated + 1
    gate.touched[k] = true
    local same_click = gate.click ~= nil and gate.click.w == k and os.clock() - gate.click.at < SAME_CLICK
    if same_click and not gate.queue then
        local count = math.floor(tonumber(ue.prop(w, "CountIndex")) or 1)
        if count > 1 then
            -- the rest after each answer; this click's XP and "N crafted" count the one sent
            gate.queue = { key = k, left = count - 1, craft = ue.prop(w, "CraftIndex") }
            ue.set_prop(w, "CountIndex", 1)
            log.info("consume: %s: %d more crafted one by one, each after the host's answer", ui.name, count - 1)
        end
    elseif not same_click and not gate.logged then
        gate.logged = true
        log.info("consume: %s: the next craft waits for the host's answer to the last one", ui.name)
    end
end

-- BP_JigComponent.CLIENT_ItemCraftedResponse(TempUID, ItemAdded, Success?,
-- UpdateUIDS, WithCounts, IsCraftingStation?, ItemInside), post (client): the
-- game has applied the answer.
local function on_craft_answer(c, _, added_p, ok_p, uids_p, counts_p)
    if S.role ~= "client" then return end
    local comp = own_jig_comp(c)
    if not comp then return end
    local success = param(ok_p) == true
    local added = param(added_p)
    local item = added and ue.try(function() return item_name(added[F_INFO][F_ITEMID]) end) or "?"
    local count = added and ue.try(function() return added[F_INFO][F_COUNT] end)
    -- the game's own local add (JigTryAddItemSomewhere on this machine)
    if os.clock() - gate.local_add < 0.2 then
        gate.local_add = -100
        log.debug("consume: item added locally by the game: %s x%s", item, tostring(count))
        return
    end
    if gate.n <= 0 then
        log.debug("consume: item added by the host: %s x%s (success=%s)", item, tostring(count), tostring(success))
        return
    end
    M.stats.crafts_answered = M.stats.crafts_answered + 1
    local uids = list_of(param(uids_p))
    local counts = list_of(param(counts_p))
    local view = client_view(comp)
    local parts, wrong = {}, 0
    for i, g in ipairs(uids) do
        local u = ue.try(function() return guid_str(g) end) or "?"
        local want = counts[i]
        local have = view[u]
        local shown = have and have.n or 0
        -- a count of 0 means the stack is gone
        if (tonumber(want) or 0) ~= (tonumber(shown) or 0) then wrong = wrong + 1 end
        parts[#parts + 1] = string.format("%s: host %s, shown %s", have and have.name or u, tostring(want),
            have and tostring(shown) or "gone")
    end
    local line = string.format("consume: craft answer: success=%s, %s x%s, %d component(s) [%s]",
        tostring(success), item, tostring(count), #uids, table.concat(parts, "; "))
    if wrong > 0 then
        log.warn("%s - %d not shown as the host has them", line, wrong)
    elseif success and #uids == 0 then
        log.warn("%s - the host consumed nothing", line)
    elseif M.stats.crafts_answered <= 5 then
        log.info("%s", line)
    else
        log.debug("%s", line)
    end
    -- The game resolves the reserved slot with the answer's UID but keeps the
    -- item the client expected there. If the host made something else (another
    -- recipe list, a station it does not have), this inventory shows item A
    -- under the UID of item B, and dropping / using "A" acts on B. The slot
    -- goes and the host sends the real item again (RESEND).
    local added_da = added and ue.try(function() return added[F_INFO][F_ITEMID] end)
    local added_u = added and ue.try(function() return guid_str(added[F_USID]) end)
    if success and ue.valid(added_da) and added_u and added_u ~= "0:0:0:0" then
        local e = view[added_u] or client_view(comp)[added_u]
        if e and ue.valid(e.da) and ue.name(e.da) ~= ue.name(added_da) then
            local removed = ue.valid(e.slot) and pcall(function() e.slot:RemoveFromJSIParent({}) end)
            net.send_to_host("RESEND", added_u)
            M.stats.crafts_mismatched = (M.stats.crafts_mismatched or 0) + 1
            log.warn("consume: craft answer: the host made %s (uid %s), this inventory showed %s there (%s); slot removed=%s, asked the host to send it again",
                item_name(added_da), added_u, e.name, e.where, tostring(removed))
        end
    end
    release(success, success and "answer" or "the host refused the craft")
end

-- ===========================================================================
-- Items a use gives: client
-- ===========================================================================

-- A slot widget of the own inventory removed the way the game drops a
-- failed pending request (ClientFuncItemCrafted: RemoveRequestByUID ->
-- SetPending(false), RemoveFromJSIParent); one that is no longer pending
-- (resolved locally) is taken out of its container directly.
local function remove_local_slot(comp, slot)
    local g = ue.try(function() return guid_tbl(slot.ItemUniqueID) end)
    if g then
        local out = {}
        if pcall(function() comp:RemoveRequestByUID(g, true, out) end) and out.Removed == true then
            return true, "pending request dropped"
        end
    end
    if ue.valid(slot) and ue.valid(ue.prop(slot, "ContainerMother")) then
        local out = {}
        if pcall(function() slot:RemoveFromJSIParent(out) end) and out.Removed == true then
            return true, "slot removed"
        end
    end
    return false, "NOT removed"
end

-- BP_JigComponent.JigTryAddItemSomewhere(LocalComp, ItemID, Count, out Added?,
-- out UID), post (client): single-player code adding an item on this machine
-- only. Its placeholder goes, and the host is asked for the item.
local function on_local_add(c, _, item_p, count_p)
    if S.role ~= "client" then return end
    local now = os.clock()
    local ls = gate.local_slot
    gate.local_slot = nil
    if ls and now - ls.at > SAME_CALL then ls = nil end
    local da = param(item_p)
    local count = math.floor(tonumber(param(count_p)) or 0)
    if not ue.valid(da) or count <= 0 then return end
    local comp = own_jig_comp(c)
    if not comp then
        -- a station's own inventory (the disassembly workbench): the host runs
        -- the station (sdc_stations); this machine's copy only goes
        local other = c and c:get()
        local here = "no placeholder"
        if ls and ls.slot and ue.valid(other) and cfg.get("item_gains_from_host") ~= false then
            local _, how = remove_local_slot(other, ls.slot)
            here = "placeholder " .. how
        end
        log.info("consume: %s x%d added on this machine only, to %s's inventory (%s); the host does the station's work",
            item_name(da), count, ue.class_name(owner_of(other)), here)
        return
    end
    if cfg.get("item_gains_from_host") == false then return end
    local here
    if not ls then
        here = "no placeholder"
    elseif ls.stack then
        here = "would stack, nothing changed here"
    elseif ls.slot then
        local where = ue.try(slot_where, ls.slot) or "?"
        local _, how = remove_local_slot(comp, ls.slot)
        here = string.format("placeholder in %s: %s", where, how)
    else
        here = "no room here, the game's local drop removed"
    end
    -- wood, stone and scrap from world objects: sdc_world has the host grant
    -- them to the player who chopped / salvaged (an IGAIN would duplicate them)
    local dn = ue.name(da) or ""
    if cfg.get("world_harvest") ~= false and (dn == "DA_WoodenLog" or dn == "DA_Rock" or dn == "DA_ScrapMetal") then
        log.info("consume: %s x%d from a world object: the host grants it (%s)", item_name(da), count, here)
        return
    end
    M.stats.gains_sent = M.stats.gains_sent + 1
    net.send_to_host("IGAIN", ue.path(da), count)
    log.info("consume: %s x%d from using an item: asked the host to add it (%s)", item_name(da), count, here)
end

-- BP_JigComponent.ServerFunc_UpdateDurabilityByUID(UID, NewDurability, out
-- Updated), post (client, own inventory): a repair / filter refill set a
-- durability in the empty data here. The host sets it (SETDUR, see the host
-- section) and the repair goes on as in single player (Updated = true).
local dur_sent = 0
local function on_client_set_dur(c, uid_p, dur_p, updated_p)
    if S.role ~= "client" or cfg.get("client_durability_from_host") == false then return end
    if param(updated_p) == true or not own_jig_comp(c) then return end
    local u = ue.try(function() return guid_str(param(uid_p)) end)
    local x = ue.try(function() return tonumber(param(dur_p).X) end)
    if not u or not x then return end
    net.send_to_host("SETDUR", u, string.format("%.3f", x))
    pcall(function() updated_p:set(true) end)
    dur_sent = dur_sent + 1
    local line = string.format("consume: durability of %s -> %.1f sent to the host", u, x)
    if dur_sent <= 10 then log.info("%s", line) else log.debug("%s", line) end
end

-- BP_PlayerCharacter.JigMP_OnRequestDropItem(ItemInfo, ContainerName, out
-- ActorRef), post (client): JigTryAddItemSomewhere found no room here and
-- dropped the item at this player's feet - a pickup only this machine has.
local function on_local_drop(c, _, _, actor_p)
    if S.role ~= "client" or os.clock() - gate.local_drop > SAME_CALL then return end
    gate.local_drop = -100
    local pawn = c and c:get()
    if not is_player_character(pawn) or not is_locally_controlled(pawn) then return end
    if cfg.get("item_gains_from_host") == false then return end
    local a = param(actor_p)
    if not ue.valid(a) or ue.role(a) ~= ue.ROLE_AUTHORITY then return end
    local name = ue.short(a)
    pcall(function() a:K2_DestroyActor() end)
    log.info("consume: local pickup %s removed (the host drops the real one if there is no room)", name)
end

-- Pending slots of the own inventory the host never answered (a request
-- lost on the way, a local add of single-player code): they flicker forever.
-- A slot reserved here (a craft, a local add) has no item on the host and
-- goes; a real item waiting for a move answer stops blinking where it is
-- (RemoveRequestByUID(uid, false), the game's own un-pend).
local pending_seen = {}   -- [uid string] = { first = os.clock(), name, where }

local function check_stale_pending(now)
    local me = ue.local_pawn()
    local comp = me and ue.prop(me, "BP_JigMultiplayer")
    if not ue.valid(comp) then return end
    local live = {}
    for _, slot in ipairs(list_of(ue.prop(comp, "PendingRequests"))) do
        if ue.valid(slot) then
            local u = ue.try(function() return guid_str(slot.ItemUniqueID) end)
            if u then
                live[u] = true
                local e = pending_seen[u]
                if not e then
                    e = { first = now, name = item_name(ue.prop(slot, "JigDataAsset")), where = ue.try(slot_where, slot) or "?" }
                    pending_seen[u] = e
                end
                if now - e.first > STALE_PENDING and gate.n <= 0 and cfg.get("item_gains_from_host") ~= false then
                    local ok, how
                    if placeholders[u] then
                        ok, how = remove_local_slot(comp, slot)
                        how = ok and ("removed: " .. how) or how
                    else
                        local out = {}
                        ok = pcall(function() comp:RemoveRequestByUID(guid_tbl(slot.ItemUniqueID), false, out) end)
                        how = (ok and out.Removed == true) and "a real item: it stops blinking where it is"
                            or "a real item: NOT un-pended"
                    end
                    placeholders[u] = nil
                    M.stats.stale_pending = M.stats.stale_pending + 1
                    log.warn("consume: %s (uid %s, %s) waited %.0f s for the host; %s", e.name, u, e.where,
                        now - e.first, how)
                    pending_seen[u] = nil
                    live[u] = nil
                end
            end
        end
    end
    for u in pairs(pending_seen) do
        if not live[u] then pending_seen[u] = nil end
    end
    for u, t in pairs(placeholders) do
        if now - t > 3 * STALE_PENDING and not live[u] then placeholders[u] = nil end
    end
end

-- ===========================================================================
-- Crafting and using items: host
-- ===========================================================================

local ledger = {}     -- [JigComponent address] = server_items() of a remote player's inventory

-- The mod's own server-side removes (a craft taken back) are not a player's use.
local self_remove = false
local function host_remove(comp, g, n)
    self_remove = true
    local ok, err = pcall(function() comp:SERVER_RequestRemoveItem(comp, g, n, false) end)
    self_remove = false
    return ok, err
end

local health = {}     -- [character address] = MedicalComponent.Health at the last host tick

-- BP_JigComponent.SERVER_RequestCraftItem(CompRef, CraftIndex, ConsumeUIDs, ...)
-- and SERVER_RequestCraftItemDrop(CompRef, CraftIndex, ConsumeUIDs), post (host).
local function on_craft_request(c, station_p, index_p, uids_p)
    if S.role ~= "host" then return end
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    M.stats.host_crafts = M.stats.host_crafts + 1
    local owner = owner_of(comp)
    if not is_remote_character(owner) then
        log.debug("consume: host craft (own inventory), %d requests so far", M.stats.host_crafts)
        return
    end
    local k = addr(comp)
    local before = k and ledger[k]
    local after = server_items(comp)
    if k then ledger[k] = after end
    local station = param(station_p)
    local uids = list_of(param(uids_p))
    local parts, known, consumed = {}, 0, 0
    for _, g in ipairs(uids) do
        local u = ue.try(function() return guid_str(g) end) or "?"
        local pre = before and before[u]
        local post = after[u]
        if pre then known = known + 1 end
        if pre and (not post or (tonumber(post.n) or 0) < (tonumber(pre.n) or 0)) then consumed = consumed + 1 end
        parts[#parts + 1] = string.format("%s %s->%s", (pre and pre.id) or (post and post.id) or u,
            pre and tostring(pre.n) or "unknown", post and tostring(post.n) or "gone")
    end
    -- what the craft added: new items and stacks that grew
    local new, outputs = {}, {}
    if before then
        for u, e in pairs(after) do
            local pre = before[u]
            local grew = (tonumber(e.n) or 0) - (pre and tonumber(pre.n) or 0)
            if not pre then new[#new + 1] = string.format("%s x%s", e.id, tostring(e.n)) end
            if grew > 0 then outputs[#outputs + 1] = { g = e.g, n = grew, id = e.id, stacked = pre ~= nil } end
        end
    end
    -- a station reference that does not resolve here (a station only the
    -- client has): the game falls back to the player's own recipe list, so
    -- the recipe index means another recipe
    local unresolved = not ue.valid(station)
    local where = unresolved and "a station the host does not have (the player's recipe list was used)"
        or ue.class_name(owner_of(station))
    local line = string.format("consume: %s crafted at %s (recipe %s): %d component(s) [%s], new: %s",
        ue.short(owner), where, tostring(param(index_p)), #uids, table.concat(parts, "; "),
        #new > 0 and table.concat(new, ", ") or "none")
    if unresolved and before and consumed == 0 and #outputs > 0 and cfg.get("craft_needs_components") ~= false then
        local back = {}
        for _, o in ipairs(outputs) do
            local ok, err = host_remove(comp, o.g, o.n)
            back[#back + 1] = string.format("%s x%d%s", o.id, o.n, ok and "" or (" FAILED: " .. tostring(err)))
        end
        if k then ledger[k] = server_items(comp) end
        M.stats.host_unpaid = M.stats.host_unpaid + 1
        log.warn("%s - wrong recipe, nothing consumed: taken back [%s]", line, table.concat(back, ", "))
    elseif unresolved then
        log.warn("%s - wrong recipe list (outputs kept: components were consumed)", line)
    elseif before and #uids > 0 and known == 0 then
        -- none of the components exists here (the snapshot is current: it is
        -- refreshed after every inventory request): the game made the item for
        -- nothing. It is taken back with the server's own remove, which also
        -- tells the client.
        M.stats.host_unpaid = M.stats.host_unpaid + 1
        if cfg.get("craft_needs_components") == false or #outputs == 0 then
            log.warn("%s - NOTHING consumed, none of them was here%s", line,
                #outputs == 0 and " (no output in the inventory to take back: dropped or at a station)" or "")
        else
            local back = {}
            for _, o in ipairs(outputs) do
                local ok, err = host_remove(comp, o.g, o.n)
                back[#back + 1] = string.format("%s x%d%s", o.id, o.n, ok and "" or (" FAILED: " .. tostring(err)))
            end
            if k then ledger[k] = server_items(comp) end
            log.warn("%s - none of them was here: taken back [%s]", line, table.concat(back, ", "))
        end
    elseif before and #uids > 0 and consumed == 0 then
        log.warn("%s - NOTHING consumed (%d of them were here)", line, known)
    else
        log.info("%s%s", line, before and "" or " (no earlier inventory snapshot)")
    end
end

-- Inventory requests of a remote player (pickups, moves, splits, stacks,
-- reloads): the snapshot of the inventories involved is renewed right after,
-- so a craft compares against the inventory as it was just before it.
local LEDGER_RPCS = {
    "SERVER_RequestAddActorToContainer", "SERVER_RequestActorAddStackItem", "SERVER_RequestEquipActorToContainer",
    "SERVER_RequestMoveItemToAnotherComp", "SERVER_RequestSplitItem", "SERVER_RequestStackItem",
    "SERVER_RequestReload", "SERVER_RequestReloadInternal", "SERVER_SameContainer_MoveToIndex",
}
local function renew_ledger(comp)
    if not ue.valid(comp) or not is_remote_character(owner_of(comp)) then return end
    local k = addr(comp)
    if k then ledger[k] = server_items(comp) end
end
local function on_inventory_rpc(c, ...)
    if S.role ~= "host" then return end
    renew_ledger(c and c:get())
    for i = 1, select("#", ...) do
        local v = param((select(i, ...)))
        if type(v) == "userdata" and ue.valid(v) and ue.class_name(v):find("JigComponent", 1, true) then renew_ledger(v) end
    end
end

-- MedicalComponent: CLIENT_RemoveMedicalEffect's body (ubergraph @614-825)
-- and the stop timers that OnRep_* start through Client RPCs (@1391-2050).
local EFFECTS = {
    ["Bleed"]            = { flag = "Bleed?",      rep = 2, onrep = "OnRep_Bleed?",      timer = "Time_Bleed",      lo = 10,  hi = 12 },
    ["Heavy Bleed"]      = { flag = "HeavyBleed?", rep = 3, onrep = "OnRep_HeavyBleed?", timer = "Time_HeavyBleed", lo = 14,  hi = 16 },
    ["Broken Bone"]      = { flag = "BrokenBone?", rep = 4, onrep = "OnRep_BrokenBone?", timer = "Time_BrokenBone", lo = 180, hi = 360 },
    ["Infection"]        = { infection = true },
    ["Subdue Infection"] = { infection = false },
}
local BY_ONREP = {}
for _, e in pairs(EFFECTS) do if e.onrep then BY_ONREP[e.onrep] = e end end

local push_obj = nil
local function mark_dirty(comp, e)
    if not ue.valid(push_obj) then push_obj = ue.find_object("/Script/Engine.Default__NetPushModelHelpers") end
    if push_obj then pcall(function() push_obj:MarkPropertyDirtyFromRepIndex(comp, e.rep, FName(e.flag)) end) end
end

local function med_flags(med)
    return string.format("bleed=%s heavy=%s bone=%s infection=%s", tostring(ue.prop(med, "Bleed?")),
        tostring(ue.prop(med, "HeavyBleed?")), tostring(ue.prop(med, "BrokenBone?")), tostring(ue.prop(med, "Infection?")))
end

local function stats_text(info)
    local parts = {}
    pcall(function()
        info[F_STATS]:ForEach(function(_, s)
            local st = s:get()
            local tag = ue.str(st[F_STAT_NAME].TagName):match("([^%.]+)$") or "?"
            parts[#parts + 1] = string.format("%s %+g", tag, tonumber(st[F_STAT_MAX]) or 0)
        end)
    end)
    return table.concat(parts, ", ")
end

local last_ci = nil   -- the last ConsumeItem on the host: { at, pawn (address), name }

-- BP_PlayerCharacter.ConsumeItem(Info), post (host): the item's effects ran on
-- the host's copy; its cure went to the client only.
local function on_consume_item(c, info_p)
    if S.role ~= "host" then return end
    local pawn = c and c:get()
    if not ue.valid(pawn) then return end
    local info = param(info_p)
    local da = info and ue.try(function() return info[F_ITEMID] end)
    last_ci = { at = os.clock(), pawn = addr(pawn), name = ue.short(pawn), item = item_name(da) }
    if not is_remote_character(pawn) or not ue.valid(da) then return end
    local med = ue.prop(pawn, "MedicalComponent")
    if not ue.valid(med) then return end
    local effects = {}
    if ue.prop(da, "CanBeConsumed?") == true then
        for _, n in ipairs(list_of(ue.prop(da, "RemoveMedicalEffects"))) do effects[#effects + 1] = ue.str(n) end
    end
    local done = {}
    if cfg.get("medical_host_cure") ~= false then
        for _, name in ipairs(effects) do
            local e = EFFECTS[name]
            if e and e.flag then
                if ue.prop(med, e.flag) == true and ue.set_prop(med, e.flag, false) then
                    mark_dirty(med, e)
                    pcall(function() med[e.onrep](med) end)
                    done[#done + 1] = name
                end
            elseif e and e.infection ~= nil then
                if ue.prop(med, "Infection?") == true and pcall(function() med:InfectionState(e.infection) end) then
                    done[#done + 1] = name
                end
            end
        end
    end
    if #done > 0 then M.stats.cures = M.stats.cures + 1 end
    local skills = ue.prop(ue.prop(pawn, "Controller"), "PassiveSkillsComponent")
    local pk = addr(pawn) or -1
    local hp = tonumber(ue.prop(med, "Health"))
    local before = health[pk]
    if hp then health[pk] = hp end
    log.info("consume: %s used %s on the host [%s]: health %s->%s/%s (first aid x%s), %s; cures [%s], cured on the host [%s]",
        ue.short(pawn), item_name(da), stats_text(info), before and string.format("%.0f", before) or "?",
        hp and string.format("%.0f", hp) or "?", tostring(ue.prop(med, "MaxHealth")),
        tostring(ue.prop(skills, "FirstAidMultiplier")), med_flags(med), table.concat(effects, ","), table.concat(done, ","))
end

-- Items a use gives (IGAIN from the client, see the header): added by the
-- plugin's server-side AddNewItemSomewhere(ItemID, Count, ItemInside,
-- ItemInsideCount, DropIfFailedToAdd?, SpecificContainer, out Added, out
-- Dropped?, out ItemUID, out AddedToUID) on the player's own JigComponent.
local uses = {}     -- [character address] = { at = os.clock(), gains = n } of the last use request
local queued = {}   -- { pc, key, path, count, at }: IGAIN that came before its use request

-- Default attachments of an item that came out of a loot box. Single player
-- (ContextOpenLootBox @3585-4781), for each ItemID.DefaultAttachments entry:
--   GetItemByUID(new UID) -> GetPickupInfoFromDT(ID, MinCount) ->
--   AddNewItemToSlot(info, Item.SubContainers[AddToContainerIndex].UniqueID, 0)
--   -> CLIENT_NewItemAdded(...) to the owner.
-- On the host: the same sub-container, Generate_AddNewItemToContainer(sub UID,
-- ID, MinCount) (the plugin's server-side add into one container), then the
-- same CLIENT_NewItemAdded to the owner. Only gains carry it: no consumable or
-- cloth has DefaultAttachments, so in practice these are loot-box weapons.
-- (F_SUBS / F_SUB_ID: at the top)
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_ROT = "Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56"
local A_ID = "ID_21_A45B60654D588805C5D52BA4BC5CD4FD"
local A_MIN = "MinCount_31_E62F0FA548FC7DB0BDB860B4C0D695B6"
local A_INDEX = "AddToContainerIndex_11_3CB23949434BAB8C7EEBE09362324A4C"
local U_UID = "UID_2_DC6DBB72457305316FAC19A4399A1CB5"
local U_COUNT = "NewCount_5_31E28E124BF695AFBB001A87164F9121"

local function sub_containers_of(comp, u)
    local subs = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if subs then return end
            c:get()[F_ITEMS]:ForEach(function(_, it)
                local item = it:get()
                if not subs and guid_str(item[F_USID]) == u then
                    subs = {}
                    item[F_SUBS]:ForEach(function(_, s) subs[#subs + 1] = guid_tbl(s:get()[F_SUB_ID]) end)
                end
            end)
        end)
    end)
    return subs
end

local function add_default_attachments(pawn, comp, da, u)
    local atts = list_of(ue.prop(da, "DefaultAttachments"))
    if #atts == 0 or cfg.get("loot_box_attachments") == false then return end
    local subs = sub_containers_of(comp, u)
    if not subs then
        log.warn("consume: %s of %s has default attachments, but the item %s is not in its inventory here",
            item_name(da), ue.short(pawn), u)
        return
    end
    local zero = { A = 0, B = 0, C = 0, D = 0 }
    local parts = {}
    for _, a in ipairs(atts) do
        local id = ue.try(function() return a[A_ID] end)
        local n = math.max(1, math.floor(tonumber(ue.try(function() return a[A_MIN] end)) or 1))
        local idx = math.floor(tonumber(ue.try(function() return a[A_INDEX] end)) or 0)
        local sub = subs[idx + 1]
        local what
        if not ue.valid(id) then
            what = "?: no item"
        elseif not sub then
            what = string.format("%s: no sub-container %d (of %d)", item_name(id), idx, #subs)
        else
            local info, added = {}, {}
            local ok, err = pcall(function() comp:Generate_AddNewItemToContainer(sub, id, n, info, added) end)
            if not ok or added["Added?"] ~= true then
                what = string.format("%s: NOT added%s", item_name(id), ok and "" or (" (" .. tostring(err) .. ")"))
            else
                local okc, errc = pcall(function()
                    comp:CLIENT_NewItemAdded(info[F_INFO], info[F_USID], info[F_MOTHER], info[F_SLOT], info[F_ROT] == true,
                        { [U_UID] = zero, [U_COUNT] = 1 }, zero, info[F_SUBS] or {}, false)
                end)
                what = string.format("%s x%d%s", item_name(id), n,
                    okc and "" or (" (added on the host, the client was NOT told: " .. tostring(errc) .. ")"))
            end
        end
        parts[#parts + 1] = what
    end
    log.info("consume: default attachments of %s for %s: %s", item_name(da), ue.short(pawn), table.concat(parts, "; "))
end

local function grant(pawn, path, count)
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) then return end
    local da = ue.find_object(path)
    if not da then
        ue.load_asset(path, "consume")
        da = ue.find_object(path)
    end
    if not da or not ue.class_name(da):find("DataAsset", 1, true) then
        M.stats.gains_refused = M.stats.gains_refused + 1
        log.warn("consume: %s asked for %s, which is not an item here; not added", ue.short(pawn), tostring(path))
        return
    end
    count = math.max(1, math.min(50, math.floor(count)))
    local added, dropped, uid, to = {}, {}, {}, {}
    local ok, err = pcall(function()
        comp:AddNewItemSomewhere(da, count, nil, 1, true, FName("None"), added, dropped, uid, to)
    end)
    if ok then M.stats.gains_added = M.stats.gains_added + 1 end
    local line = string.format("consume: %s gets %s x%d from using an item: added=%s dropped=%s uid %s%s", ue.short(pawn),
        item_name(da), count, tostring(added.Added), tostring(dropped["Dropped?"]),
        ue.try(guid_str, uid) or "?", ok and "" or (" - FAILED: " .. tostring(err)))
    if ok and (added.Added == true or dropped["Dropped?"] == true) then log.info("%s", line) else log.warn("%s", line) end
    -- (a dropped one has none either: the single-player code only fits them
    -- after an add)
    local u = ue.try(guid_str, uid)
    if ok and added.Added == true and u and u ~= "0:0:0:0" then add_default_attachments(pawn, comp, da, u) end
    renew_ledger(comp)
end

-- net RESEND|<uid>, client -> host: one item of the client's own inventory
-- again (its slot there showed another item), through the plugin's own
-- notification of a new item: CLIENT_AddNewItem(the item as the host has it,
-- no content, the component, no pending UID).
local resend_at = {}
local function on_resend_msg(f, pc)
    if S.role ~= "host" then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    local u = f[1] or ""
    local key = tostring(addr(pawn)) .. "|" .. u
    local now = os.clock()
    if not ue.valid(comp) or now - (resend_at[key] or -100) < 2 then return end
    resend_at[key] = now
    local found = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if found then return end
            c:get()[F_ITEMS]:ForEach(function(_, it)
                if not found then
                    local item = it:get()
                    if guid_str(item[F_USID]) == u then found = item end
                end
            end)
        end)
    end)
    if not found then
        log.warn("consume: %s asked for item %s again, which is not in their inventory here", ue.short(pawn), u)
        return
    end
    local name = ue.try(function() return item_name(found[F_INFO][F_ITEMID]) end) or "?"
    local ok, err = pcall(function() comp:CLIENT_AddNewItem(found, {}, comp, { A = 0, B = 0, C = 0, D = 0 }) end)
    log.info("consume: %s (uid %s) sent to %s again%s", name, u, ue.short(pawn), ok and "" or (" - FAILED: " .. tostring(err)))
end

-- SERVER_RequestDropItem(ItemUID, Count, CompTarget), post (host; called from
-- sdc_items' drop hook): which item a remote player's drop took. A drop is by
-- UID, so a wrong item means the client's slot showed another item.
local drops_logged = 0
function M.host_drop_report(c, uid_p, count_p, target_p)
    if S.role ~= "host" then return end
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    local owner = owner_of(comp)
    if not is_remote_character(owner) then return end
    local target = param(target_p)
    if not ue.valid(target) then target = comp end
    local k = addr(target)
    local before = k and ledger[k]
    local after = server_items(target)
    if before then ledger[k] = after end
    local u = ue.try(function() return guid_str(param(uid_p)) end) or "?"
    local pre, post = before and before[u], after[u]
    if before and not pre then
        log.warn("consume: %s asked to drop uid %s x%s, which is not in their inventory here: nothing dropped",
            ue.short(owner), u, tostring(param(count_p)))
        return
    end
    drops_logged = drops_logged + 1
    local line = string.format("consume: %s dropped %s x%s (uid %s: %s here before, %s after)", ue.short(owner),
        (pre and pre.id) or (post and post.id) or "?", tostring(param(count_p)), u, pre and tostring(pre.n) or "?",
        post and tostring(post.n) or "none")
    if drops_logged <= 30 then log.info("%s", line) else log.debug("%s", line) end
end

-- net IGAIN|<item data asset path>|<count>, client -> host.
local function on_gain_msg(f, pc)
    if S.role ~= "host" then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local path, count = f[1] or "", tonumber(f[2]) or 1
    if cfg.get("item_gains_from_host") == false then
        log.info("consume: %s asked for %s x%d (item_gains_from_host is off; not added)", ue.short(pawn), path, count)
        return
    end
    local k = addr(pawn)
    local u = k and uses[k]
    if u and os.clock() - u.at <= GAIN_WINDOW and u.gains < GAIN_MAX then
        u.gains = u.gains + 1
        grant(pawn, path, count)
    else
        -- its use request may still be on the way
        queued[#queued + 1] = { pc = pc, key = k, path = path, count = count, at = os.clock() }
    end
end

-- Items the host's own code gives a remote player. Server-side game code
-- calls JigTryAddItemSomewhere(<player's component>, ItemID, Count) too: the
-- water well filling empty containers (BP_WaterWell OnServerExecuteInteract,
-- option 1 @3255-4861: ServerFindThenConsumeByItemID(DA_EmptyWaterJug /
-- Canteen / Bottle / PlasticBottle, 1), then JigTryAddItemSomewhere(
-- DA_DirtyWater*, 1)) and a caught fish (FishingComponent @5449-5826, after the
-- bait). That function looks for a slot in the inventory WIDGETS
-- (JigTryAddGetPendingRef: LocalJSIContainers), which only the owning machine
-- has; on the host, for a remote player, it finds none and takes its no-room
-- branch: GetPlayerPawn(self, 0) (sdc_ctx: that player).JigMP_OnRequestDropItem,
-- a pickup at the player's feet, Added? = false. The client's empty containers
-- were gone and the filled ones lay on the ground. In single player the item
-- goes into the inventory; here the pickup this call just dropped goes into
-- the player's inventory with the server's add (AddNewItemSomewhere: stacks or
-- a free slot -> CLIENT_UpdateCounts / CLIENT_AddNewItem; no room: dropped at
-- the player again, as in single player). sdc_world turns the drops of its
-- world resources (trees, rocks, scrap, picked-up buildings) into inventory
-- adds itself, inside the same call (its on_player_drop): its counters tell,
-- and those are left to it.
local host_add = { claimed = {}, world_seen = 0 }

local function world_drops()
    local w = package.loaded["sdc_world"]
    local st = type(w) == "table" and w.stats
    if type(st) ~= "table" then return 0 end
    return (tonumber(st.grants) or 0) + (tonumber(st.grant_drops) or 0)
end

-- The pickup of `da` this call dropped (newest not yet claimed, spawned at or
-- after `since`, default the call's window), or nil.
local function claim_drop(da, since)
    local items = package.loaded["sdc_items"]
    if type(items) ~= "table" or not items.recent_pickups then return nil end
    local want = ue.name(da)
    local list = items.recent_pickups(since or (os.clock() - SAME_CALL))
    for i = #list, 1, -1 do
        local a = list[i]
        local k = addr(a)
        if k and not host_add.claimed[k] then
            local pda = ue.prop(ue.prop(a, "BP_JigPickupComponent"), "ItemDataAsset")
            if ue.valid(pda) and ue.name(pda) == want then
                host_add.claimed[k] = os.clock()
                return a
            end
        end
    end
    return nil
end

-- BP_JigComponent.JigTryAddItemSomewhere(LocalComp, ItemID, Count, out Added?,
-- out UID), post (host).
local function on_host_add(c, comp_p, item_p, count_p, added_p)
    local wn = world_drops()
    local by_world = wn ~= host_add.world_seen
    host_add.world_seen = wn
    if param(added_p) == true then return end
    local comp = param(comp_p)
    if not ue.valid(comp) then comp = c and c:get() end
    if not ue.valid(comp) then return end
    local pawn = owner_of(comp)
    if not is_remote_character(pawn) or cfg.get("host_adds_to_inventory") == false then return end
    local da = param(item_p)
    local n = math.floor(tonumber(param(count_p)) or 0)
    if not ue.valid(da) or n <= 0 then return end
    if by_world then
        log.debug("consume: %s x%d for %s: the world module took its drop", item_name(da), n, ue.short(pawn))
        return
    end
    local drop = claim_drop(da)
    if not drop then
        M.stats.host_adds_lost = M.stats.host_adds_lost + 1
        log.warn("consume: %s x%d for %s: the game's add found no inventory slot on the host and its drop was not found; nothing changed",
            item_name(da), n, ue.short(pawn))
        return
    end
    local added, dropped, uid, to = {}, {}, {}, {}
    local t0 = os.clock()
    local ok, err = pcall(function()
        comp:AddNewItemSomewhere(da, n, nil, 1, true, FName("None"), added, dropped, uid, to)
    end)
    local into = ok and added.Added == true
    if into or (ok and dropped["Dropped?"] == true) then pcall(function() drop:K2_DestroyActor() end) end
    -- (the server add's own drop, when full, is not the drop of a later call)
    while claim_drop(da, t0) do end
    host_add.world_seen = world_drops()
    renew_ledger(comp)
    M.stats.host_adds = M.stats.host_adds + 1
    local line = string.format("consume: %s x%d for %s (the host's code dropped it at the player): %s", item_name(da), n,
        ue.short(pawn), into and "into its inventory" or (ok and dropped["Dropped?"] == true) and "no room, dropped at its feet"
        or ("left on the ground" .. (ok and "" or (" - FAILED: " .. tostring(err)))))
    if ok then log.info("%s", line) else log.warn("%s", line) end
end

-- Durability set by the client's single-player code. Repairs (repair kits on
-- weapons / armor / attachments, from the context menu or dropped on the
-- item) and refilling a respirator filter call the server function
-- ServerFunc_UpdateDurabilityByUID(UID, NewDurability, out Updated) on the
-- CLIENT's component, where the inventory data is empty: nothing changes on
-- the host, and Updated = false stops the rest of the repair. The client
-- sends the value (SETDUR) and answers Updated; the host sets it with the same
-- function on its copy (CLIENT_UpdateDurability tells the client). A lower
-- value (a kit wearing down) is applied at once; a higher one (the repair)
-- only next to a lower one or a use request of that player (the kit), within
-- DUR_WINDOW, the way the game's repair always pairs them.
local DUR_WINDOW = 2
local dur_wait = {}   -- { key, pawn key, u, x, at }: raises waiting for their kit
local dur_paid = {}   -- [character address] = os.clock() of the last kit wear / use

local function item_durability(comp, u)
    local found = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if found then return end
            c:get()[F_ITEMS]:ForEach(function(_, it)
                if not found then
                    local item = it:get()
                    if guid_str(item[F_USID]) == u then
                        local d = item[F_INFO][F_DUR]
                        found = { g = guid_tbl(item[F_USID]), x = tonumber(d.X) or 0, y = tonumber(d.Y) or 0,
                                  id = item_name(item[F_INFO][F_ITEMID]) }
                    end
                end
            end)
        end)
    end)
    return found
end

local function apply_dur(pawn, u, x)
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    local it = ue.valid(comp) and item_durability(comp, u)
    if not it then
        log.warn("consume: %s set the durability of item %s, which is not in their inventory here", ue.short(pawn), u)
        return
    end
    local want = math.max(0, math.min(it.y, x))
    local out = {}
    local ok, err = pcall(function() comp:ServerFunc_UpdateDurabilityByUID(it.g, { X = want, Y = it.y }, out) end)
    log.info("consume: %s: %s durability %.1f -> %.1f / %.1f%s", ue.short(pawn), it.id, it.x, want, it.y,
        ok and "" or (" - FAILED: " .. tostring(err)))
    return want < it.x
end

local function flush_dur(pk, now)
    local keep = {}
    for _, q in ipairs(dur_wait) do
        if q.pk == pk and now - q.at <= DUR_WINDOW and ue.valid(q.pawn) then
            apply_dur(q.pawn, q.u, q.x)
        else
            keep[#keep + 1] = q
        end
    end
    dur_wait = keep
end

-- net SETDUR|<uid>|<new durability>, client -> host.
local function on_dur_msg(f, pc)
    if S.role ~= "host" or cfg.get("client_durability_from_host") == false then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local u, x = f[1] or "", tonumber(f[2])
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    local it = x and ue.valid(comp) and item_durability(comp, u)
    if not it then
        log.warn("consume: %s set the durability of item %s, which is not in their inventory here", ue.short(pawn), u)
        return
    end
    local pk = addr(pawn) or "?"
    local now = os.clock()
    if x <= it.x then
        apply_dur(pawn, u, x)
        dur_paid[pk] = now
        flush_dur(pk, now)
    elseif now - (dur_paid[pk] or -100) <= DUR_WINDOW then
        apply_dur(pawn, u, x)
    else
        dur_wait[#dur_wait + 1] = { pk = pk, pawn = pawn, u = u, x = x, at = now }
    end
end

local function expire_dur(now)
    local keep = {}
    for _, q in ipairs(dur_wait) do
        if now - q.at > DUR_WINDOW then
            log.warn("consume: %s raised the durability of %s with no repair kit used around it; not applied",
                ue.short(q.pawn), q.u)
        else
            keep[#keep + 1] = q
        end
    end
    dur_wait = keep
end

-- A use request from this player: its queued IGAIN are paid now (and a
-- waiting repair).
local function note_use(owner)
    local k = addr(owner)
    if not k then return end
    local now = os.clock()
    local u = { at = now, gains = 0 }
    uses[k] = u
    local keep = {}
    for _, q in ipairs(queued) do
        if q.key == k and now - q.at <= GAIN_WINDOW and u.gains < GAIN_MAX then
            u.gains = u.gains + 1
            grant(owner, q.path, q.count)
        else
            keep[#keep + 1] = q
        end
    end
    queued = keep
    dur_paid[k] = now
    flush_dur(k, now)
end

-- BP_JigComponent.SERVER_RequestRemoveItem(TargetComp, ItemUID, Amount,
-- CallbackToPlayer?), post (host): the game's other way to use items up
-- (water purification tablets and the dirty water, JigItemOverItemComp.
-- PurifyWater). Counts as a use for the item it gives (IGAIN). The mod's own
-- calls (a craft taken back) are not.
local function on_remove_request(c, target_p, uid_p, amount_p)
    if S.role ~= "host" or self_remove then return end
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    local owner = owner_of(comp)
    if not is_remote_character(owner) then return end
    local target = param(target_p)
    if not ue.valid(target) then target = comp end
    local k = addr(target)
    local before = k and ledger[k]
    local after = server_items(target)
    if before then ledger[k] = after end
    local u = ue.try(function() return guid_str(param(uid_p)) end) or "?"
    local pre, post = before and before[u], after[u]
    log.info("consume: %s used up %s x%s (uid %s: %s here before, %s after)", ue.short(owner),
        (pre and pre.id) or (post and post.id) or "?", tostring(param(amount_p)), u, pre and tostring(pre.n) or "?",
        post and tostring(post.n) or "none")
    note_use(owner)
end

-- Host tick: IGAIN with no use request around it are dropped.
local function expire_gains(now)
    local keep = {}
    for _, q in ipairs(queued) do
        if now - q.at > GAIN_WINDOW then
            M.stats.gains_refused = M.stats.gains_refused + 1
            log.warn("consume: %s asked for %s x%d with no item use around it; not added",
                ue.short(ue.pawn_of(q.pc)), q.path, q.count)
        else
            keep[#keep + 1] = q
        end
    end
    queued = keep
end

-- BP_JigComponent.SERVER_RequestConsumeItem(TargetComp, ItemUID, Amount,
-- CustomData), post (host): a remote player used an item. ConsumeItem (above)
-- ran inside it when the game found the item.
local function on_consume_request(c, target_p, uid_p, amount_p)
    if S.role ~= "host" then return end
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    local owner = owner_of(comp)
    if not is_remote_character(owner) then return end
    local target = param(target_p)
    if not ue.valid(target) then target = comp end
    local k = addr(target)
    -- only the player's own inventory has a snapshot; an item used from a
    -- container (a loot box, a station) is not judged ("?")
    local before = k and ledger[k]
    local after = server_items(target)
    if k and ledger[k] then ledger[k] = after end
    local u = ue.try(function() return guid_str(param(uid_p)) end) or "?"
    local pre = before and before[u]
    local post = after[u]
    local ci = last_ci
    last_ci = nil
    if ci and os.clock() - ci.at > SAME_CALL then ci = nil end
    local result, wrong = nil, false
    if not ci then
        result = "no ConsumeItem (not usable this way, or not found here)"
    elseif ci.pawn ~= addr(owner) then
        result, wrong = "ConsumeItem ran on " .. ci.name .. " - the WRONG character", true
    else
        result = "ConsumeItem ran on their character"
    end
    M.stats.uses = M.stats.uses + 1
    -- A slot the client still shows for an item its inventory here does not
    -- have (every container, worn items included): nothing was used. The
    -- client is told the way the game ends a stack (CLIENT_UpdateCount to 0:
    -- ClientUpdateCount removes the slot), and the use pays no item it gives.
    local ghost = before ~= nil and not pre and not post and not ci and addr(target) == addr(comp)
    if ghost then
        local g = ue.try(function() return guid_tbl(param(uid_p)) end)
        local ok, err = false, "no uid"
        if g then ok, err = pcall(function() comp:CLIENT_UpdateCount(comp, g, 0, { A = 0, B = 0, C = 0, D = 0 }) end) end
        M.stats.ghost_uses = (M.stats.ghost_uses or 0) + 1
        log.warn("consume: %s used uid %s x%s, which is not in their inventory here (a slot left on their screen): nothing used; %s",
            ue.short(owner), u, tostring(param(amount_p)),
            ok and "the client was told it is gone (CLIENT_UpdateCount 0)" or ("telling the client FAILED: " .. tostring(err)))
        return
    end
    local line = string.format("consume: %s used %s x%s (uid %s: %s here before, %s after) -> %s", ue.short(owner),
        (pre and pre.id) or (post and post.id) or (ci and ci.item) or "?", tostring(param(amount_p)), u,
        pre and tostring(pre.n) or (before and "? (newer than the snapshot)" or "?"), post and tostring(post.n) or "none",
        result)
    if wrong then
        log.warn("%s", line)
    elseif M.stats.uses <= 30 then
        log.info("%s", line)
    else
        log.debug("%s", line)
    end
    note_use(owner)
end

-- MedicalComponent.OnRep_Bleed? / OnRep_HeavyBleed? / OnRep_BrokenBone?, post
-- (host; the server calls them itself after changing the flag): a client's
-- character gets the stop timer the game starts on the client only.
local function on_med_onrep(c, onrep)
    if S.role ~= "host" or cfg.get("medical_host_cure") == false then return end
    local med = c and c:get()
    if not ue.valid(med) then return end
    local pawn = owner_of(med)
    if not is_remote_character(pawn) then return end
    local e = BY_ONREP[onrep]
    local ksl = ue.ksl()
    if not e or not ksl then return end
    if ue.prop(med, e.flag) == true then
        if ue.try(function() return ksl:K2_IsTimerActive(med, e.timer) end) == true then return end
        local t = e.lo + math.random() * (e.hi - e.lo)
        local ok = pcall(function() ksl:K2_SetTimer(med, e.timer, t, false, false, 0, 0) end)
        M.stats.stop_timers = M.stats.stop_timers + 1
        log.info("consume: %s of %s ends on the host in %.0f s (%s%s)", e.flag, ue.short(pawn), t, e.timer,
            ok and "" or ", timer FAILED")
    else
        pcall(function() ksl:K2_ClearTimer(med, e.timer) end)
    end
end

-- ===========================================================================
-- Using items: client (log only)
-- ===========================================================================

local function own_pawn_of(c)
    local o = c and c:get()
    if not ue.valid(o) then return nil end
    if not is_player_character(o) then o = owner_of(o) end
    if is_player_character(o) and is_locally_controlled(o) then return o end
    return nil
end

-- BP_PlayerCharacter.HotBarConsume(ItemRef), post (client): the request went out.
local function on_hotbar_consume(c, slot_p)
    if S.role ~= "client" or not own_pawn_of(c) then return end
    local slot = param(slot_p)
    if not ue.valid(slot) then return end
    local u = ue.try(function() return guid_str(slot.ItemUniqueID) end) or "?"
    local host, n = host_item_uids()
    local known = "host copy unknown"
    if host and n > 0 then known = host[u] ~= nil and "the host has it" or "NOT in the host's copy" end
    log.info("consume: using %s from the hotbar (uid %s, x%s here, %s)", item_name(ue.prop(slot, "JigDataAsset")), u,
        tostring(ue.prop(slot, "ItemCount")), known)
end

local function on_remove_effect_client(c, effects_p)
    if S.role ~= "client" or not own_pawn_of(c) then return end
    local names = {}
    for _, n in ipairs(list_of(param(effects_p))) do names[#names + 1] = ue.str(n) end
    if #names == 0 then return end
    log.info("consume: the host cured [%s] on this character (this copy now: %s)", table.concat(names, ","),
        med_flags(c:get()))
end

local last_health, health_logged = nil, -100
local function on_health_ui(c, health_p)
    if S.role ~= "client" or not own_pawn_of(c) then return end
    local h = tonumber(param(health_p))
    if not h then return end
    local now = os.clock()
    if last_health and h >= last_health + 3 and now - health_logged > 2 then
        health_logged = now
        log.info("consume: health from the host %.0f -> %.0f", last_health, h)
    end
    last_health = h
end

-- ===========================================================================
-- Client: inventory shown here vs. the host's copy (log only)
-- ===========================================================================

local desync = { at = -100, last = nil }

local function check_desync(now)
    if now - desync.at < DESYNC_EVERY then return end
    desync.at = now
    if gate.n > 0 then return end
    local host, n, at = host_item_uids()
    if not host or not at or n == 0 then return end
    local me = ue.local_pawn()
    local jig = me and ue.prop(me, "BP_JigMultiplayer")
    if not ue.valid(jig) then return end
    local only_here = {}
    for u, e in pairs(client_view(jig)) do
        if host[u] == nil then
            only_here[#only_here + 1] = string.format("%s x%s (uid %s, %s)", e.name, tostring(e.n), u, e.where or "?")
        end
    end
    table.sort(only_here)
    local key = table.concat(only_here, "; ")
    -- the same items twice in a row: not an answer still on its way
    if #only_here > 0 and key == desync.last then
        M.stats.desync_reports = M.stats.desync_reports + 1
        if M.stats.desync_reports <= 5 or M.stats.desync_reports % 20 == 0 then
            log.warn("consume: %d item(s) shown in this inventory are not in the host's copy (they cannot be used or moved): %s",
                #only_here, key)
        end
    end
    desync.last = key
end

-- ===========================================================================
-- Ticks
-- ===========================================================================

local hook_at = -100

-- JigTryAddItemSomewhere: one hook for both roles (one RegisterHook per
-- function): the client's single-player add of what a use gave, the host's
-- add for a remote player that dropped the item.
local function on_try_add(c, comp_p, item_p, count_p, added_p)
    if S.role == "client" then
        on_local_add(c, comp_p, item_p, count_p)
    elseif S.role == "host" then
        on_host_add(c, comp_p, item_p, count_p, added_p)
    end
end

local function try_hooks_client()
    try_hook(JIG_FN .. "JigTryAddGetPendingRef", "craft-pending", on_pending_ref)
    try_hook(JIG_FN .. "CLIENT_ItemCraftedResponse", "craft-answer", on_craft_answer)
    for _, ui in ipairs(CRAFT_UIS) do
        try_hook(ui.path .. ":CheckIngredientsAvailability", "craft-check-" .. ui.name,
            function(c, p) on_check_ingredients(ui, c, p) end)
    end
    try_hook(PLAYER_FN .. "HotBarConsume", "use-hotbar", on_hotbar_consume)
    try_hook(JIG_FN .. "JigTryAddItemSomewhere", "use-add", on_try_add)
    try_hook(PLAYER_FN .. "JigMP_OnRequestDropItem", "use-local-drop", on_local_drop)
    try_hook(JIG_FN .. "ServerFunc_UpdateDurabilityByUID", "dur-client", on_client_set_dur)
    try_hook(MEDICAL_FN .. "CLIENT_RemoveMedicalEffect", "med-cure-client", on_remove_effect_client)
    try_hook(PLAYER_FN .. "Client_UpdateHealthUI", "med-health-client", on_health_ui)
end

local function try_hooks_host()
    try_hook(JIG_FN .. "SERVER_RequestCraftItem", "craft-host", on_craft_request)
    try_hook(JIG_FN .. "SERVER_RequestCraftItemDrop", "craft-drop-host", on_craft_request)
    try_hook(JIG_FN .. "SERVER_RequestConsumeItem", "use-host", on_consume_request)
    try_hook(JIG_FN .. "SERVER_RequestRemoveItem", "remove-host", on_remove_request)
    try_hook(JIG_FN .. "JigTryAddItemSomewhere", "use-add", on_try_add)
    for _, rpc in ipairs(LEDGER_RPCS) do
        -- (sdc_containers: the outcome of a move, the world containers involved)
        try_hook(JIG_FN .. rpc, "ledger-" .. rpc, function(c, ...)
            on_inventory_rpc(c, ...)
            local ok, err = pcall(containers.host_rpc, rpc, c, ...)
            if not ok then log.err_throttled("consume.containers", "consume: containers (%s): %s", rpc, tostring(err)) end
        end)
    end
    try_hook(PLAYER_FN .. "ConsumeItem", "med-consume", on_consume_item)
    for onrep in pairs(BY_ONREP) do
        try_hook(MEDICAL_FN .. onrep, "med-" .. onrep, function(c) on_med_onrep(c, onrep) end)
    end
end

-- Host, one remote player (1 s; sdc_items spreads the players over the
-- second): snapshots of its inventory and health, which the craft / use
-- reports compare against. The walk is the tick's one full walk of that
-- inventory: left in `pass.inv` for sdc_tools and sdc_items.
function M.host_player(pc, pass)
    local pawn
    if pass then pawn = pass.pawn else pawn = ue.pawn_of(pc) end
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    local k = ue.valid(jig) and addr(jig)
    if k then
        local inv = M.inventory(jig, true)
        if pass then pass.inv = inv end
        ledger[k] = inv.by_uid
    end
    local pk = pawn and addr(pawn)
    if pk then health[pk] = tonumber(ue.prop(ue.prop(pawn, "MedicalComponent"), "Health")) end
end

-- Host tick (1 s): hooks, expiries; the snapshots of players who are no
-- longer remote go. With `split` the players' own snapshots are left to
-- host_player (sdc_items calls it for each remote player), else taken here.
function M.host_tick(remote_pcs, split)
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        try_hooks_host()
    end
    local inv, hp = {}, {}
    for _, pc in ipairs(remote_pcs or {}) do
        local pawn = ue.pawn_of(pc)
        local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
        local k = ue.valid(jig) and addr(jig)
        if k then inv[k] = ledger[k] end
        local pk = pawn and addr(pawn)
        if pk then hp[pk] = health[pk] end
    end
    ledger, health = inv, hp
    if not split then
        for _, pc in ipairs(remote_pcs or {}) do M.host_player(pc) end
    end
    expire_gains(now)
    expire_dur(now)
    for k, u in pairs(uses) do
        if now - u.at > 2 * GAIN_WINDOW then uses[k] = nil end
    end
    -- (only drops of the call being handled are claimed: older marks go, and
    -- the world module's counters are read again outside any add)
    for k, t in pairs(host_add.claimed) do
        if now - t > 5 then host_add.claimed[k] = nil end
    end
    host_add.world_seen = world_drops()
end

-- Client tick (1 s).
function M.client_tick()
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        try_hooks_client()
    end
    if gate.n > 0 and now - gate.since > INFLIGHT_TIMEOUT then
        log.warn("consume: no answer from the host to a craft request for %d s; crafting allowed again", INFLIGHT_TIMEOUT)
        gate.n = 1
        release(false, "no answer from the host")
    end
    -- forgotten without touching them: a closed window's widget may be freed
    for k, e in pairs(widgets) do
        if now - e.at > WIDGET_KEEP and not (gate.queue and gate.queue.key == k) then widgets[k] = nil end
    end
    check_stale_pending(now)
    check_desync(now)
end

function M.reset()
    gate = new_gate()
    widgets = {}
    ledger, health = {}, {}
    last_ci = nil
    uses, queued, pending_seen, resend_at, placeholders = {}, {}, {}, {}, {}
    dur_wait, dur_paid = {}, {}
    host_add = { claimed = {}, world_seen = world_drops() }
    desync = { at = -100, last = nil }
    last_health = nil
    hook_at = -100   -- a new role: its hooks right away
    names, names_n = {}, 0
end

function M.register_handlers()
    -- client -> host: IGAIN|<item data asset path>|<count>   (an item a use gave)
    net.on("IGAIN", on_gain_msg)
    -- client -> host: RESEND|<uid>   (an item of the own inventory again)
    net.on("RESEND", on_resend_msg)
    -- client -> host: SETDUR|<uid>|<durability>   (a repair / refill in the own inventory)
    net.on("SETDUR", on_dur_msg)
end

return M
