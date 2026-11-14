-- SDCoop: workbenches whose single-player code needs the host.
-- Driven by sdc_items (init / host_tick / client_tick / reset / register_handlers).
--
-- Disassembly workbench (W_DisassemblyWorkbenchUI, Buildable_DisassemblyWorkbench).
-- The "Disassemble" button handler is UI code that does the whole job itself:
--   All Items = <station JigComponent>.GetContainerItems(true)  (MainJigContainers)
--   for each item: if ItemID.CanBeDisassembled? and DisassemblyItems is not empty:
--     for each DisassemblyItems entry, once per unit of the stack:
--       RandomFloatInRange(0, 100) <= SpawnChance ->
--         JigTryAddItemSomewhere(station comp, entry.ItemID, RandomIntegerInRange(Min, Max))
--     <station comp>.SERVER_RequestConsumeItem(station comp, item UID, item Count, "")
--   else a "cannot be disassembled" notification.
-- On a client MainJigContainers is empty (the server's data), so the list is
-- empty and nothing happens; even if it were not, the consume RPC would go out
-- on the station's component, which the client does not own, and the engine
-- drops it. Fix: after the client's handler ran, the client asks the host
-- (DISASM, the station's class and place); the host finds the station this
-- player is using and runs the same steps on the station's own data with the
-- server's functions: the same rolls, the outputs into the station's output
-- grid, and the consume through the station component's own
-- SERVER_RequestConsumeItem (run on the host; HandleLocalRequestConsumeItem ->
-- MC_UpdateCount).
-- Where the outputs go. The station has two grids (Buildable_Disassembly-
-- Workbench's ContainersSettings): "Container" 12x8 = the window's
-- JSIContainer_1 (top, the input) and "Disassembled" 12x6 = JSIContainer
-- (bottom, the output). The handler sets NonAdd = [JSIContainer_1] and
-- JigTryAddItemSomewhere -> JigTryAddGetPendingRef leaves the NonAdd grids
-- out: in single player (and the host's own click) an output stacks onto the
-- same item in the bottom grid or takes a free slot there, else it drops at
-- the player's feet. 0.7.1 added a client's outputs with AddNewItemSomewhere,
-- which knows no window: it stacks onto that item in any grid and puts a new
-- stack in the first grid with room - the top one (its SpecificContainer is
-- ignored for stackable items and fails on an empty grid). The client's view
-- shows what the host's data says (CLIENT_AddNewItem / MC_AddNewItem place an
-- item by its ContainerMotherID and SlotIndex), so the client saw them in the
-- top grid. Now: AddItemToContainerByName("Disassembled", ...) - stacks only
-- in that grid, else TryAddNewItem there - and the change (a new stack or a
-- new count, read from the grid before and after) goes to the remote viewers
-- through sdc_containers (its own notice is CLIENT_NewItemAdded /
-- CLIENT_UpdateCount, no multicast). The grid full: dropped at the player's
-- feet, as single player. That function failing with room left: the old add
-- (any grid), logged. The client is told where the results went (DISASMR).
--
-- Other stations checked: the crafting / construction workbenches and the
-- campfire (W_CookingUI) send their RPCs through the player's own component
-- (PlayerMPComp); the battery charger's widget has no actions (charging is
-- the station's own timer on the host). Nothing to relay there.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local net = require("sdc_net")
local containers = require("sdc_containers")

local M = {
    stats = { disasm_sent = 0, disasm_runs = 0, disasm_items = 0, disasm_outputs = 0, disasm_refused = 0,
              disasm_to_grid = 0, disasm_fallback = 0 },
}
local S
function M.init(state) S = state end

local addr = ctx.addr

local DISASM_UI = "/Game/Inventory/Widgets/Crafting/W_DisassemblyWorkbenchUI.W_DisassemblyWorkbenchUI_C:"
    .. "BndEvt__W_DisassemblyWorkbenchUI_Button_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"
-- station classes a client may ask the host to run (class short name)
local STATIONS = { Buildable_DisassemblyWorkbench_C = true }
local PLAYER_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local JIG_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_SLOTS = "ContainerSlots_13_97B5C4324E23EC5C1D899EA59CCDD3AC"
local F_HOSTING = "HostingUID_12_7B8F2C70428BC8D03C43329582545C16"
local CS_NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982"
-- the disassembly station's output grid (its 2nd main container, the window's bottom grid)
local OUT_GRID = "Disassembled"
-- RandomContainerItem (DisassemblyItems entries)
local R_ID = "ItemID_41_8C5E69274AB445604263E4A2B3091BAD"
local R_CHANCE = "SpawnChance_9_0A1811814580181DD09AE78500C25A28"
local R_MIN = "RandomCountMin_17_2CF035DB43DEE23801AD29A29560BDA9"
local R_MAX = "RandomCountMax_18_C37B88104F52B02AA216B5912518580D"

local USE_REACH = 1000          -- cm: the player must be this close to the station
local PLACE_MATCH = 300         -- cm: a station this close to the place the client named is the one
local REQUEST_GAP = 0.5         -- s between two requests of one player

local function guid_str(g)
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

local function guid_tbl(g)
    return { A = g.A, B = g.B, C = g.C, D = g.D }
end

local function item_name(da)
    if not ue.valid(da) then return "?" end
    return (ue.short(da):gsub("^DA_", ""))
end

local function list_of(arr)
    local out = {}
    if arr == nil then return out end
    pcall(function()
        arr:ForEach(function(_, e) out[#out + 1] = e:get() end)
    end)
    return out
end

local function dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function is_remote_character(p)
    if not ue.valid(p) or not ue.class_name(p):find("PlayerCharacter", 1, true) then return false end
    return ue.valid(ue.prop(ue.prop(p, "Controller"), "NetConnection"))
end

local hooked = {}
local function try_hook(path, tag, fn)
    if hooked[path] then return end
    local ok = pcall(RegisterHook, path, function(c, ...)
        local okc, err = pcall(fn, c, ...)
        if not okc then log.err_throttled("stations." .. tag, "stations: %s hook: %s", tag, tostring(err)) end
    end)
    if ok then
        hooked[path] = true
        log.info("stations: %s hook ok", tag)
    end
end

-- ===========================================================================
-- Client
-- ===========================================================================

-- A station actor that exists only on this machine: spawned here (a
-- runtime name) and owned by this machine (local authority), e.g. a camp
-- prefab the host never spawned. The host cannot run anything for it.
local function client_only(station)
    return ue.role(station) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(station)
end

-- W_DisassemblyWorkbenchUI's button handler, post (client): it found nothing
-- here; the host disassembles.
local function on_disassemble_click(c)
    if S.role ~= "client" or cfg.get("stations_on_host") == false then return end
    local w = c and c:get()
    if not ue.valid(w) then return end
    local comp = ue.try(function() return w.JSIContainer_1.JigMultiplayerComp end)
    local station = ue.valid(comp) and ue.try(function() return comp:GetOwner() end)
    local loc = ue.valid(station) and ue.location(station)
    if not loc then
        log.warn("stations: disassemble clicked, but the station is unknown here; nothing sent")
        return
    end
    if client_only(station) then
        log.warn("stations: %s exists only on this machine (the host does not have it): disassembly refused",
            ue.short(station))
        return
    end
    M.stats.disasm_sent = M.stats.disasm_sent + 1
    net.send_to_host("DISASM", ue.class_name(station), string.format("%.0f", loc.X), string.format("%.0f", loc.Y),
        string.format("%.0f", loc.Z))
    log.info("stations: disassemble at %s: asked the host to do it", ue.class_name(station))
end

-- net DISASMR|<grid>|<of grids>|<grid name>|<to the grid>|<dropped>|<elsewhere>,
-- host -> client: where the host put the results of this player's disassembly
-- (the window shows them as the host's data has them).
local function on_disasm_result(f)
    if S.role ~= "client" then return end
    local idx, n = tonumber(f[1]) or 0, tonumber(f[2]) or 0
    local to_grid, dropped, other = tonumber(f[4]) or 0, tonumber(f[5]) or 0, tonumber(f[6]) or 0
    local where = idx > 0 and string.format("output grid %d of %d '%s'%s", idx, n, tostring(f[3] or ""),
        idx == n and " (the window's bottom grid)" or "") or "the first grid with room (no output grid)"
    log.info("stations: the host disassembled here: disassembly results -> %s (%d there, %d dropped at your feet, %d elsewhere)",
        where, to_grid, dropped, other)
end

-- Recipe lists. A station's JigComponent gets its ItemsToCraft from the
-- game's GameFunctionLibrary.SetItemsToCraft(table, comp, station) in the code
-- that opens its window - on the machine that opens it. World stations
-- (BP_CookingStation, BP_CraftingStation) open locally (OnExecuteInteract), so
-- for a client's use the host's copy keeps an empty list, and the
-- construction bench switches tables (standard / modular) in the window only.
-- The craft request carries only CraftIndex: HandleServerFuncRequestCraft
-- reads CompRef.ItemsToCraft[CraftIndex] on the host -> nothing (craft
-- fails) or another recipe. The client names the table its window uses
-- (STABLE); the host runs the same SetItemsToCraft on its copy.
local TABLE_OF_UI = { W_CookingUI_C = 2, W_CraftingWorkbenchUI_C = 1, W_ConstructionWorkbenchUI_C = "bench" }
local table_sent = {}   -- [station address|table] = os.clock()

local function station_of(w)
    local comp = ue.prop(w, "MPComponent")
    local st = ue.valid(comp) and ue.try(function() return comp:GetOwner() end)
    if ue.valid(st) and not ue.class_name(st):find("PlayerCharacter", 1, true) then return st end
    return nil
end

local function table_of(w)
    local t = TABLE_OF_UI[ue.class_name(w)]
    if t == "bench" then t = tonumber(ue.prop(ue.prop(w, "StationOwner"), "CurrentCraftingTable")) end
    return t
end

local function sync_table(w, st, why, force)
    local t = table_of(w)
    local loc = ue.location(st)
    if not t or not loc then return end
    local key = tostring(addr(st)) .. "|" .. tostring(t)
    local now = os.clock()
    if not force and now - (table_sent[key] or -100) < 2 then return end
    table_sent[key] = now
    net.send_to_host("STABLE", t, ue.path(st), ue.class_name(st), string.format("%.0f", loc.X),
        string.format("%.0f", loc.Y), string.format("%.0f", loc.Z))
    log.debug("stations: recipe table %d of %s sent to the host (%s)", t, ue.short(st), why)
end

-- Called by sdc_consume's craft check (client) before a craft request goes
-- out: false, reason when it must not (a station only this machine has).
local refused_logged = {}
function M.client_craft_check(w)
    if S.role ~= "client" or cfg.get("stations_on_host") == false then return true end
    local st = station_of(w)
    if not st then return true end
    if client_only(st) then
        local k = tostring(addr(st))
        if not refused_logged[k] then
            refused_logged[k] = true
            log.warn("stations: %s exists only on this machine (the host does not have it): crafting there is refused",
                ue.short(st))
        end
        return false, "station only on this machine"
    end
    sync_table(w, st, "craft", false)
    return true
end

-- <station crafting window>.InitializeInventory, post (client): the window
-- opened; the host gets the table right away.
local function on_station_window(c)
    if S.role ~= "client" or cfg.get("stations_on_host") == false then return end
    local w = c and c:get()
    if not ue.valid(w) then return end
    local st = station_of(w)
    if st and not client_only(st) then sync_table(w, st, "window opened", true) end
end

-- Loot containers (log only). Opening one asks the host for its contents
-- (RequestServerData -> SERVER_RequestData on the own component; the host
-- answers CLIENT_ContainerDataResponse with the items it has). A container
-- that stays empty shows here as a request without an answer, with what this
-- machine's copy is (replicated from the host, or spawned here). The
-- RequestServerData hook serves only that warning: with config debug only.
local loot_wait = {}   -- [component address] = { at, name, cls, role, here }

local function container_owner(comp)
    local o = ue.valid(comp) and ue.try(function() return comp:GetOwner() end)
    if ue.valid(o) and not ue.class_name(o):find("PlayerCharacter", 1, true) then return o end
    return nil
end

-- BP_PlayerCharacter.RequestServerData(TargetComp, out Result), post (client).
local function on_request_data(c, comp_p)
    if S.role ~= "client" then return end
    local p = c and c:get()
    local ok, own = pcall(function() return p:IsLocallyControlled() end)
    if not ok or own ~= true then return end
    local comp = comp_p and ue.try(function() return comp_p:get() end)
    local o = container_owner(comp)
    local k = o and addr(comp)
    if not k then return end
    loot_wait[k] = { at = os.clock(), name = ue.short(o), cls = ue.class_name(o), role = ue.role(o),
                     here = ue.is_runtime_spawned(o) }
end

-- BP_JigComponent.CLIENT_ContainerDataResponse(MainContainersUIDs,
-- ContainerItems, JigMPCompRef, ActionbarUIDs), post (client).
local function on_data_answer(c, uids_p, items_p, ref_p)
    if S.role ~= "client" then return end
    local comp = ref_p and ue.try(function() return ref_p:get() end)
    local o = container_owner(comp)
    if not o then return end
    -- (sdc_containers: this container is open here, by its container UIDs)
    containers.note_open(comp, list_of(uids_p and ue.try(function() return uids_p:get() end)))
    local k = addr(comp)
    local w = k and loot_wait[k]
    if k then loot_wait[k] = nil end
    local n = #list_of(items_p and ue.try(function() return items_p:get() end))
    log.info("stations: contents of %s (%s) from the host: %d item(s)%s", ue.short(o), ue.class_name(o), n,
        w and string.format(" after %.1f s", os.clock() - w.at) or "")
end

local function check_loot_waits(now)
    for k, w in pairs(loot_wait) do
        if now - w.at > 4 then
            loot_wait[k] = nil
            log.warn("stations: no contents from the host for %s (%s; this copy: %s, %s) - the host does not have it, or refused it",
                w.name, w.cls, w.role == ue.ROLE_AUTHORITY and "local authority" or ("role " .. tostring(w.role)),
                w.here and "spawned on this machine" or "placed in the level / replicated")
        end
    end
end

-- BP_JigComponent.SERVER_RequestData(JigMpCompRef), post (host): what a remote
-- player's open found here.
local function on_data_request(c, ref_p)
    if S.role ~= "host" then return end
    local pc_comp = c and c:get()
    local who = ue.valid(pc_comp) and ue.try(function() return pc_comp:GetOwner() end)
    if not is_remote_character(who) then return end
    local comp = ref_p and ue.try(function() return ref_p:get() end)
    if not ue.valid(comp) then
        log.warn("stations: %s opened a container the host does not have (it exists only on their machine)", ue.short(who))
        return
    end
    local o = container_owner(comp)
    if not o then return end
    -- (sdc_containers: this player has it open)
    containers.note_view(who, comp)
    local n = 0
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, ct)
            ct:get()[F_ITEMS]:ForEach(function() n = n + 1 end)
        end)
    end)
    local out = {}
    local can = ue.try(function() o:JigCanInteract(out); return out.Result end)
    log.info("stations: %s opened %s (%s): %d item(s) here, can interact=%s%s", ue.short(who), ue.short(o),
        ue.class_name(o), n, tostring(can), can == false and " - the game sends nothing" or "")
end

-- ===========================================================================
-- Host
-- ===========================================================================

-- The station this player is using: the one whose CurrentActor (set by the
-- server's interaction) is the player, else the one at the place the client
-- named; either way within reach of the player.
local function find_station(pawn, cls, at)
    local ploc = ue.location(pawn)
    local pk = addr(pawn)
    local best, best_d, used = nil, math.huge, false
    for _, a in ipairs(ue.find_all(cls)) do
        if ue.valid(a) and ue.class_name(a) == cls then
            local loc = ue.location(a)
            if dist2(loc, ploc) <= USE_REACH * USE_REACH then
                local is_user = addr(ue.prop(a, "CurrentActor")) == pk
                local d = dist2(loc, at)
                if (is_user and not used) or (is_user == used and d < best_d) then
                    best, best_d, used = a, d, is_user
                end
            end
        end
    end
    if best and not used and best_d > PLACE_MATCH * PLACE_MATCH then return nil end
    return best
end

-- An output that did not fit in the station: dropped at the player's feet, as
-- JigTryAddItemSomewhere's no-room branch drops it at the player.
local function drop_at(pawn, da, n)
    local info = { [F_ITEMID] = da, [F_COUNT] = n, [F_PENDING] = -1 }
    local out = {}
    local ok = pcall(function() pawn:JigMP_OnRequestDropItem(info, FName("None"), out) end)
    local a = out.ActorRef
    if ok and ue.valid(a) then
        pcall(function() a:SetPickupCount(n, {}) end)
        return true
    end
    return false
end

-- The station's output grid: { idx =, n =, uid =, name = } (idx of n main
-- containers), the grid named OUT_GRID, else the last one (the window's
-- input is the first); nil for a station of one grid.
function M.output_grid(comp)
    local ids = list_of(ue.prop(comp, "MainContainersIDs"))
    if #ids < 2 then return nil end
    local sets = list_of(ue.prop(comp, "ContainersSettings"))
    local function name_at(i)
        return sets[i] and ue.try(function() return ue.str(sets[i][CS_NAME]) end) or nil
    end
    local pick = #ids
    for i = 1, #ids do
        if name_at(i) == OUT_GRID then pick = i break end
    end
    local u = ue.try(guid_str, ids[pick])
    if not u then return nil end
    return { idx = pick, n = #ids, uid = u, name = name_at(pick) }
end

-- One grid of a component's server data: { [uid] = count }, and its free
-- slots (nil when unknown).
local function grid_items(comp, cuid, want_free)
    local items, rc = {}, nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local x = c:get()
            if not rc and guid_str(x[F_CONT_UID]) == cuid then rc = x end
        end)
    end)
    if not rc then return items, nil end
    pcall(function()
        rc[F_ITEMS]:ForEach(function(_, it)
            local item = it:get()
            items[guid_str(item[F_USID])] = math.floor(tonumber(item[F_INFO][F_COUNT]) or 0)
        end)
    end)
    if not want_free then return items, nil end
    local free = 0
    local ok = pcall(function()
        rc[F_SLOTS]:ForEach(function(_, sl)
            if guid_str(sl:get()[F_HOSTING]) == "0:0:0:0" then free = free + 1 end
        end)
    end)
    return items, ok and free or nil
end

local run_fallbacks = 0   -- adds of this disassembly that went the old way

-- A stack of this item in the grid with room left: its uid and the room
-- (MaxStack - count), or nil.
local function partial_stack(comp, cuid, da)
    local max = math.floor(tonumber(ue.prop(da, "MaxStack")) or 0)
    local dk = addr(da)
    if max < 2 or not dk then return nil end
    local uid, room = nil, 0
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local x = c:get()
            if uid or guid_str(x[F_CONT_UID]) ~= cuid then return end
            x[F_ITEMS]:ForEach(function(_, it)
                if uid then return end
                local item = it:get()
                local n = math.floor(tonumber(item[F_INFO][F_COUNT]) or 0)
                if n < max and addr(item[F_INFO][F_ITEMID]) == dk then uid, room = guid_str(item[F_USID]), max - n end
            end)
        end)
    end)
    return uid, room
end

-- One output into the output grid (single player's place for it). Returns
-- how it went (and, when nil, how much of n is still to add the old way): "" (added), " (stacked)", " dropped at the player (output grid
-- full)", " to the first grid with room (fallback)", or a failure.
local add_to_grid
function add_to_grid(comp, pawn, da, n, grid)
    local before = grid_items(comp, grid.uid)
    local ok, err = pcall(function() comp:AddItemToContainerByName(FName(grid.name), da, n, false, nil, 0) end)
    local after = grid_items(comp, grid.uid)
    local got, new, cnt = 0, {}, {}
    for u, c in pairs(after) do
        local b = before[u]
        if b == nil then
            got = got + c
            new[#new + 1] = u
        elseif c > b then
            got = got + (c - b)
            cnt[#cnt + 1] = { u, c }
        end
    end
    -- its own notice is a Client RPC (the host's view); the remote viewers get it like a multicast
    -- (sdc_containers sends a run's ops together: one message per viewer)
    local cont = package.loaded["sdc_containers"]
    if cont and cont.notify_viewers then
        for _, u in ipairs(new) do pcall(cont.notify_viewers, comp, "add", u) end
        for _, e in ipairs(cnt) do pcall(cont.notify_viewers, comp, "cnt", e[1], e[2]) end
    end
    if got > 0 then
        M.stats.disasm_to_grid = M.stats.disasm_to_grid + 1
        return #new == 0 and " (stacked)" or ""
    end
    -- (the free slots are counted only now: a walk of every slot per output was most of a run's cost)
    local _, free = grid_items(comp, grid.uid, true)
    if free == 0 then
        -- the grid is full, but a partial stack of this item can take part of it (the game's
        -- stacking: AddItemToContainerByName tops up only when the whole n fits): fill its room, then the rest
        local pu, room = partial_stack(comp, grid.uid, da)
        if pu and room > 0 and room < n then
            local how = add_to_grid(comp, pawn, da, room, grid)
            if how then
                local how2, rest = add_to_grid(comp, pawn, da, n - room, grid)
                if how2 then return how2 end
                return nil, rest or (n - room)
            end
        end
        if drop_at(pawn, da, n) then return " dropped at the player (output grid full)" end
        return " LOST (output grid full, no drop)"
    end
    -- one warning per run (a 1000-stack went through here once per output: 3500 lines); the count is in the run's summary line
    run_fallbacks = run_fallbacks + 1
    local line = string.format("stations: %s x%d did not go into grid %d '%s' (%s, %s free slot(s)): added the old way",
        item_name(da), n, grid.idx, grid.name, ok and "nothing added" or ("FAILED: " .. tostring(err)), tostring(free))
    if run_fallbacks == 1 then log.warn("%s", line) end
    return nil
end

-- One output of the disassembly into the station's own inventory: how it
-- went (for the log) and where: "grid" (the output grid), "dropped" (at the
-- player's feet) or "other" (a station of one grid, the fallback, lost).
local function add_output(comp, pawn, da, n, grid)
    local named = grid and grid.name and grid.name ~= ""
    if named then
        local how, rest = add_to_grid(comp, pawn, da, n, grid)
        if rest then n = rest end
        if how then
            if how:find("dropped", 1, true) then return how, "dropped" end
            return how, how:find("LOST", 1, true) and "other" or "grid"
        end
    end
    -- a station of one grid (or the named add failed): the plugin's add, any grid
    local added, dropped, uid, to = {}, {}, {}, {}
    local ok, err = pcall(function()
        comp:AddNewItemSomewhere(da, n, nil, 1, true, FName("None"), added, dropped, uid, to)
    end)
    if ok and (added.Added == true or dropped["Dropped?"] == true) then
        if not named then return "", "other" end
        M.stats.disasm_fallback = M.stats.disasm_fallback + 1
        return " to the first grid with room (fallback)", "other"
    end
    if drop_at(pawn, da, n) then return " dropped at the player", "dropped" end
    return ok and " LOST (no room, no drop)" or (" FAILED: " .. tostring(err)), "other"
end

-- The button handler's steps, on the host, for the station's own data.
local function disassemble(station, pawn)
    local comp = ue.prop(station, "BP_JigMultiplayer")
    if not ue.valid(comp) then return end
    -- the handler's GetContainerItems(true): every item of the station, taken once
    local list = {}
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            c:get()[F_ITEMS]:ForEach(function(_, it)
                local item = it:get()
                local info = item[F_INFO]
                list[#list + 1] = { uid = guid_tbl(item[F_USID]), u = guid_str(item[F_USID]), da = info[F_ITEMID],
                                    n = math.floor(tonumber(info[F_COUNT]) or 0) }
            end)
        end)
    end)
    M.stats.disasm_runs = M.stats.disasm_runs + 1
    run_fallbacks = 0
    -- where the results go: the output grid, as the station's window adds them
    local grid = M.output_grid(comp)
    local placed = { grid = 0, dropped = 0, other = 0 }
    local done, skipped = {}, {}
    local no_disasm = {}   -- the DAs' "name" (the game's 'Item "X" cannot be disassembled', handler @1797)
    for _, e in ipairs(list) do
        local da = e.da
        if not ue.valid(da) or e.n <= 0 then
            skipped[#skipped + 1] = "?"
        elseif ue.prop(da, "CanBeDisassembled?") ~= true then
            skipped[#skipped + 1] = item_name(da) .. " (cannot be disassembled)"
            local okn, nm = pcall(function() return ue.fstring(ue.prop(da, "name")) end)
            if not okn or type(nm) ~= "string" or nm == "" then nm = item_name(da) end
            no_disasm[#no_disasm + 1] = nm
        else
            local parts = list_of(ue.prop(da, "DisassemblyItems"))
            if #parts > 0 then
                local got = {}
                for _, p in ipairs(parts) do
                    local out_da = p[R_ID]
                    local chance = tonumber(p[R_CHANCE]) or 0
                    local lo, hi = math.floor(tonumber(p[R_MIN]) or 1), math.floor(tonumber(p[R_MAX]) or 1)
                    if hi < lo then hi = lo end
                    -- the rolls are the game's (once per unit); the hits of one output item are
                    -- added together, as stacks of at most its MaxStack (up to 0.12.0 every hit was
                    -- an add of its own: a stack of 1000 = ~3500 adds, each with two grid walks, a
                    -- reliable message per viewer and a log line)
                    local total, hits, hitlist = 0, 0, {}
                    if ue.valid(out_da) then
                        for _ = 1, e.n do
                            if math.random() * 100 <= chance then
                                local cnt = math.random(lo, hi)
                                if cnt > 0 then
                                    total = total + cnt
                                    hits = hits + 1
                                    hitlist[hits] = cnt
                                end
                            end
                        end
                    end
                    if total > 0 then
                        local max = math.floor(tonumber(ue.prop(out_da, "MaxStack")) or 0)
                        -- (MaxStack unreadable: every hit is an add of its own, as before)
                        local pieces = hitlist
                        if max >= 1 then
                            pieces = {}
                            for left = total, 1, -max do pieces[#pieces + 1] = math.min(left, max) end
                        end
                        local how_n, hows = 0, {}
                        for _, cnt in ipairs(pieces) do
                            local how, went = add_output(comp, pawn, out_da, cnt, grid)
                            M.stats.disasm_outputs = M.stats.disasm_outputs + 1
                            placed[went] = placed[went] + 1
                            how_n = how_n + 1
                            if how ~= "" and not hows[how] then hows[how] = true; hows[#hows + 1] = how end
                        end
                        got[#got + 1] = string.format("%s x%d (%d hit(s), %d add(s))%s", item_name(out_da), total, hits,
                            how_n, table.concat(hows))
                    end
                end
                local ok, err = pcall(function() comp:SERVER_RequestConsumeItem(comp, e.uid, e.n, "") end)
                M.stats.disasm_items = M.stats.disasm_items + 1
                done[#done + 1] = string.format("%s x%d -> %s%s", item_name(da), e.n,
                    #got > 0 and table.concat(got, ", ") or "nothing", ok and "" or (" (consume FAILED: " .. tostring(err) .. ")"))
            end
        end
    end
    local where = grid and string.format("output grid %d of %d '%s'", grid.idx, grid.n, tostring(grid.name))
        or "no output grid found: the first grid with room"
    if run_fallbacks > 1 then where = where .. string.format(" [%d adds went the old way]", run_fallbacks) end
    log.info("stations: %s disassembled at %s: %s%s; disassembly results -> %s (%d there, %d dropped at the player, %d elsewhere)",
        ue.short(pawn), ue.short(station), #done > 0 and table.concat(done, "; ") or "nothing to disassemble",
        #skipped > 0 and ("; skipped " .. table.concat(skipped, ", ")) or "", where, placed.grid, placed.dropped,
        placed.other)
    -- the window's changes first (queued by sdc_containers), then where the
    -- results went (the player's log)
    if containers.flush_viewers then pcall(containers.flush_viewers) end
    local pc = ue.prop(pawn, "Controller")
    if ue.valid(pc) then
        net.send_to(pc, "DISASMR", grid and grid.idx or 0, grid and grid.n or 0, grid and grid.name or "",
            placed.grid, placed.dropped, placed.other)
    end
    -- the game's own notice for each item it would refuse, on that player's screen (sdc_notes)
    local notes = package.loaded["sdc_notes"]
    if notes and notes.show_to and #no_disasm > 0 then
        for _, nm in ipairs(no_disasm) do
            pcall(notes.show_to, pc, string.format('Item "%s" cannot be disassembled', nm),
                "/Game/UI/Textures/over_250_survival_flat_icons/hammer.hammer", nil, 2, "stations: disassembly")
        end
    end
end

local last_request = {}   -- [character address] = os.clock()

-- net DISASM|<station class>|<x>|<y>|<z>, client -> host.
local function on_disasm_msg(f, pc)
    if S.role ~= "host" then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local cls = f[1] or ""
    local at = { X = tonumber(f[2]) or 0, Y = tonumber(f[3]) or 0, Z = tonumber(f[4]) or 0 }
    if cfg.get("stations_on_host") == false then
        log.info("stations: %s asked to disassemble (stations_on_host is off)", ue.short(pawn))
        return
    end
    local k = addr(pawn) or "?"
    local now = os.clock()
    if not STATIONS[cls] or now - (last_request[k] or -100) < REQUEST_GAP then
        M.stats.disasm_refused = M.stats.disasm_refused + 1
        log.warn("stations: %s asked to disassemble at %s: refused (%s)", ue.short(pawn), cls,
            STATIONS[cls] and "too soon" or "not a station")
        return
    end
    last_request[k] = now
    local station = find_station(pawn, cls, at)
    if not station then
        M.stats.disasm_refused = M.stats.disasm_refused + 1
        log.warn("stations: %s asked to disassemble at %s (%.0f, %.0f, %.0f): no such station in reach", ue.short(pawn),
            cls, at.X, at.Y, at.Z)
        return
    end
    disassemble(station, pawn)
end

-- net STABLE|<table>|<station path>|<station class>|<x>|<y>|<z>, client -> host:
-- the recipe table the client's window of that station uses.
local GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local TABLES = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
local table_set = {}   -- [station address] = { t = table, n = recipes } last set here

local function recipe_count(comp)
    return ue.try(function() return comp.ItemsToCraft:GetArrayNum() end)
end

local function on_table_msg(f, pc)
    if S.role ~= "host" or cfg.get("stations_on_host") == false then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local t, path, cls = tonumber(f[1]), f[2] or "", f[3] or ""
    local at = { X = tonumber(f[4]) or 0, Y = tonumber(f[5]) or 0, Z = tonumber(f[6]) or 0 }
    if not TABLES[t] or cls == "" or cls:find("PlayerCharacter", 1, true) then
        log.warn("stations: %s sent recipe table %s for %s: refused", ue.short(pawn), tostring(f[1]), cls)
        return
    end
    -- a level-placed station has the same path here; a built one is found by place
    local station = ue.find_object(path)
    if not station or ue.class_name(station) ~= cls
        or dist2(ue.location(station), ue.location(pawn)) > USE_REACH * USE_REACH then
        station = find_station(pawn, cls, at)
    end
    local comp = station and ue.prop(station, "BP_JigMultiplayer")
    if not ue.valid(comp) then
        M.stats.disasm_refused = M.stats.disasm_refused + 1
        log.warn("stations: %s uses a %s at (%.0f, %.0f, %.0f) that is not on the host: its crafts there will fail",
            ue.short(pawn), cls, at.X, at.Y, at.Z)
        return
    end
    local gfl = ue.find_object(GFL)
    local before = recipe_count(comp)
    local ok, err = false, "no GameFunctionLibrary"
    if gfl then ok, err = pcall(function() gfl:SetItemsToCraft(t, comp, station) end) end
    local n = recipe_count(comp)
    local k = tostring(addr(station))
    local last = table_set[k]
    if not ok or not last or last.t ~= t or last.n ~= n then
        log.info("stations: recipe table %d of %s set on the host for %s: %s recipes (were %s)%s", t, ue.short(station),
            ue.short(pawn), tostring(n), tostring(before), ok and "" or (" - FAILED: " .. tostring(err)))
    end
    table_set[k] = { t = t, n = n }
end

-- ===========================================================================
-- Ticks
-- ===========================================================================

local hook_at = -100
local WINDOWS = {
    "/Game/Inventory/Widgets/Crafting/W_CookingUI.W_CookingUI_C:InitializeInventory",
    "/Game/Inventory/Widgets/Crafting/W_CraftingWorkbenchUI.W_CraftingWorkbenchUI_C:InitializeInventory",
    "/Game/Inventory/Widgets/Crafting/W_ConstructionWorkbenchUI.W_ConstructionWorkbenchUI_C:InitializeInventory",
}

function M.client_tick()
    local now = os.clock()
    check_loot_waits(now)
    if now - hook_at < 5 then return end
    hook_at = now
    try_hook(DISASM_UI, "disassemble-click", on_disassemble_click)
    for _, path in ipairs(WINDOWS) do
        try_hook(path, "window-" .. (path:match("%.([%w_]+)_C:") or "?"), on_station_window)
    end
    -- (log only: its one use is the "no contents from the host" warning; with config debug)
    if log.debug_enabled then try_hook(PLAYER_FN .. "RequestServerData", "loot-request", on_request_data) end
    try_hook(JIG_FN .. "CLIENT_ContainerDataResponse", "loot-answer", on_data_answer)
end

function M.host_tick()
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        try_hook(JIG_FN .. "SERVER_RequestData", "loot-request-host", on_data_request)
    end
    for k, t in pairs(last_request) do
        if now - t > 60 then last_request[k] = nil end
    end
end

function M.reset()
    last_request = {}
    table_sent, table_set, refused_logged, loot_wait = {}, {}, {}, {}
    hook_at = -100
end

function M.register_handlers()
    -- client -> host: DISASM|<station class>|<x>|<y>|<z>   (the disassembly button)
    net.on("DISASM", on_disasm_msg)
    -- host -> client: DISASMR|<grid>|<of>|<name>|<there>|<dropped>|<elsewhere>   (where the results went)
    net.on("DISASMR", on_disasm_result)
    -- client -> host: STABLE|<table>|<station path>|<class>|<x>|<y>|<z>   (a station window's recipe table)
    net.on("STABLE", on_table_msg)
end

return M
