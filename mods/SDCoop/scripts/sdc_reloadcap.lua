-- SDCoop: a loop reload (one round at a time) stops at the gun's capacity.
-- Driven by sdc_combat (init / install / register_handlers / reset /
-- status_line).
--
-- The game (work\re\pseudo, game 0.8.0; capacities from the data assets,
-- work\re\json_mags): a weapon with an internal magazine (shotguns, sawn-off,
-- Winchester, hunting rifle, Mosin, revolver, grenade launcher) holds its
-- rounds in a "loader" item (DA_*Loader, ContainerCapacity: sawn-off 6,
-- pump 6, Benelli 8, Exterminator 10, Winchester 6, hunting rifle 6, Mosin 5,
-- Marksman's Legacy 8, Deadeye 6, grenade launcher 6). The loaded count is
-- the count of the ammo stack in that loader's grid: on the host the
-- player's BP_JigMultiplayer.MainJigContainers, on a client only its
-- inventory widgets (MainJigContainers is empty there).
--   * Every Round_In / Shell_In of the loop montage on the OWNER's machine
--     (BP_PlayerCharacter @90435) -> BP_FirearmPickup.Jig_StartReloading ->
--     LocalStartReloadInternal: Cap = the loader's JSI_Slot.
--     GetContainerCapacity = the sum of JSI_Slot.ItemCount over its grid
--     widget's ArrayOfItems (JSI_Slot @878-905, JSIContainer.GetCapacity
--     @2854), Max = the loader's JigDataAsset.ContainerCapacity (@586).
--     "FULL!" only when Cap == Max (@267); else the round is asked for
--     (JigComp_CallRequestReloadInternal -> SERVER_RequestReloadInternal(
--     loader grid, ammo stack, Max)) and the loop goes on unless Max - Cap
--     == 1 (@678-787). Exact equality both times; the R key
--     (Local_CheckCanReloadInternal) refuses only Cap == Max.
--   * The host (BP_JigComponent.HandleLocalInternalReload @1340-1544): when
--     the loader already holds a stack of that ammo, the stack gets +1 and
--     the ammo stack -1 with NO capacity check; CurrentCap < MaxCap is
--     checked only for a first stack (@2850). The answer is absolute counts:
--     CLIENT_UpdateCounts([loader stack, ammo stack]) (@5216-5389; the ammo
--     stack at 0 = gone), or CLIENT_NewItemAdded for a first stack (@4701).
--     A request whose ammo stack or loader grid the host does not find
--     changes nothing and gets NO answer.
--   * The client applies an answer with ClientUpdateCount(uid, count,
--     RemoveIf0) (@2315: FindItemInContainer over LocalJSIContainers ->
--     JSI_Slot.UpdateCount, which sets ItemCount; 0 removes the widget).
-- In single player and for the host's own gun ItemCount changes inside the
-- insert itself, so Cap walks 3, 4, 5 and stops at 6. On a client it
-- changed only when the answer came back: every Round_In before that read
-- the old Cap - after a lag spike, and after a frame hitch when the montage
-- catches up and fires several Round_In in one frame (UE's montage advance
-- loops a section up to 10 times a frame). One round too many got in, and
-- past Max neither check ever matches again: that reload and every later
-- one of the gun took the whole reserve. No mod relay inserts rounds
-- (MC_Montage's proxy only runs HandleNotifies, @46394). 2026-11-13 host log
-- (0.11.0): a client's sawn-off went 3 -> 19 in one reload, 18 -> 42 in the
-- next. Magazines (box / drum) are not affected: a magazine swap moves whole
-- items and rounds put into a magazine are checked by the host
-- (ServerFunc_HandleMoveToCapacityContainer -> CheckCapacityContainer).
--
-- Client: the own reload is counted at once (prediction). Right after the
-- game sends a round request (post-hook of JigComp_CallRequestReloadInternal,
-- still inside LocalStartReloadInternal, before any later Round_In reads
-- Cap) the loader stack's widget shows +1 and the ammo stack's -1, through
-- the game's own ClientUpdateCount - what the answer will do. The game's own
-- checks then read the count the host will have and stop at Max by
-- themselves, at any ping and after a hitch. Bookkeeping per loader grid:
-- the host's last absolute count of the loader stack (auth) and the requests
-- it has not answered yet; each answer (a CLIENT_UpdateCounts naming the
-- loader stack, or CLIENT_NewItemAdded into the grid) answers the oldest
-- request (requests and answers are both reliable and in order). Shown =
-- auth + unanswered, never above Max minus the grid's other stacks; the ammo
-- stack shows auth - its unanswered requests. Every absolute count from the
-- host (an answer, a shot's CLIENT_UpdateCount, the host's correction below)
-- sets auth and the widget is shown again from it: the prediction never
-- counts twice and never drifts. A request the host never answers stops
-- counting after PRED_EXPIRE_S and the widget shows the host's count again;
-- an ammo stack whose last round this screen took away for it is asked for
-- again (RESEND). The widget is read at the first request of a reload only;
-- within the reload the host's count from its answers is kept (a frozen
-- widget cannot pull it back), never into the next reload (a chamber step
-- takes a round without a count message): the reload closes at its last
-- round, at a chamber step from its loader (JigComp_CallServerChamberWeapon),
-- at the own loop montage's end, at the latest CYCLE_GAP_S after its last
-- request or answer. A loader stack that does not exist
-- yet (empty loader) is shown from its CLIENT_NewItemAdded on; one not found
-- on this screen, or the wrong one of two stacks of a kind, from the first
-- answer that names it; rounds asked for before that are the host's to keep
-- within the capacity (below).
-- The same bookkeeping also ends the reload: when the round just asked for
-- makes the gun full by the host's counts, Jig_StartReloading's Result is
-- set false - the game's own end of the loop, even when the loader widget
-- the game reads does not follow the host's answers (tonight's client: 50 ms
-- ping, no frame hitch, yet 16 rounds in one reload, right after leaving a
-- vehicle; neither the game's vehicle exit nor sdc_vehicles touches the
-- inventory widgets, so the cause of that widget is not known). The Cap the
-- game read (MagContainer -> GetEquippedItemRef -> GetContainerCapacity) is
-- compared with the shown count and a difference logged once per reload.
--
-- Host: the host never keeps more rounds in a loader than it holds. After
-- each SERVER_RequestReloadInternal the loader's grid is read from the
-- host's data; past the capacity (the loader item's own ContainerCapacity)
-- the extra rounds go back onto the stack named in the request, else onto
-- another stack of that ammo in the inventory (never in a grid of a weapon or
-- an attachment: a chamber, a magazine), else at the player's feet; nothing is given
-- back unless the loader really lost those rounds. ServerUpdateCountByUID
-- (the plugin's count setter, which also fixes the weight), then
-- CLIENT_UpdateCount to the owner. This also repairs a gun loaded past its
-- capacity before (2026-11-13: a sawn-off with 42 of 6) at its next reload;
-- the player gets a note (RLNOTE) when more than one round was taken out or
-- rounds were dropped. Config reload_cap_fix.

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = { stats = { checks = 0, over = 0, taken = 0, back = 0, dropped = 0, failed = 0, unread = 0, notes = 0,
                      predicted = 0, answered = 0, expired = 0, no_widget = 0, ended = 0, resent = 0,
                      mismatch = 0, mismatch_lines = 0, restacked = 0, chambered = 0 } }
local S
function M.init(state) S = state end

local addr = ctx.addr

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:"
local HOOK_RETRY_MS = 2000
local INFO_LINES = 20      -- host corrections logged at info, then debug
local CAP_KEEP = 256       -- loader grids whose capacity is remembered
local NO_OWNER_RETRY_S = 30
local PRED_EXPIRE_S = 5    -- s: a request the host never answered stops counting
local CYCLE_GAP_S = 2      -- s: requests / answers this close belong to one reload (the host's count is kept)
local MISMATCH_LINES = 10  -- reloads whose widget does not follow the host: logged
local EXPIRE_TICK_MS = 500

-- BP struct members (GUID-suffixed names; S_ReplicatedContainerInfo, its
-- items, RepItemInfo, S_UpdateCount)
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_HOLDER = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF"
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB"
local F_UC_UID = "UID_2_DC6DBB72457305316FAC19A4399A1CB5"
local F_UC_COUNT = "NewCount_5_31E28E124BF695AFBB001A87164F9121"
local ZERO = { A = 0, B = 0, C = 0, D = 0 }

local function on()
    return cfg.get("reload_cap_fix") ~= false
end

local function guid_str(g)
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

local function guid_tbl(g)
    return { A = g.A, B = g.B, C = g.C, D = g.D }
end

-- "A:B:C:D" -> FGuid table
local function guid_of(s)
    local a, b, c, d = tostring(s or ""):match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not a then return nil end
    return { A = math.tointeger(tonumber(a)), B = math.tointeger(tonumber(b)), C = math.tointeger(tonumber(c)),
             D = math.tointeger(tonumber(d)) }
end

local function param(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function uid_of(v)
    if v == nil then return nil end
    return ue.try(guid_str, v)
end

local function list_of(arr)
    local out = {}
    if arr == nil then return out end
    pcall(function() arr:ForEach(function(_, e) out[#out + 1] = e:get() end) end)
    return out
end

local function is_player(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

-- the remote controller of a player character (nil: the host's own)
local function remote_pc_of(pawn)
    local pc = ue.prop(pawn, "Controller")
    if ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) then return pc end
    return nil
end

local function item_name(da)
    if not ue.valid(da) then return "?" end
    return (ue.short(da):gsub("^DA_", ""))
end

local function same_asset(a, b)
    if not ue.valid(a) or not ue.valid(b) then return false end
    local x, y = addr(a), addr(b)
    return x ~= nil and x == y
end

local function int(v)
    return math.floor(tonumber(v) or 0)
end

-- ===========================================================================
-- Host: the loader never holds more than its capacity
-- ===========================================================================

local function read_item(it, list, cuid, holder)
    local item = it:get()
    local g = item[F_USID]
    local info = item[F_INFO]
    list[#list + 1] = { uid = guid_str(g), g = guid_tbl(g), n = int(info[F_COUNT]), da = info[F_ITEMID],
                        cuid = cuid, holder = holder }
end

-- One grid by its UID: { holder = UID of the item it belongs to, items = {
-- { uid, g, n, da } } }; nil when it is not there or could not be read.
-- Stops at the grid.
local function find_grid(jig, cuid)
    local found = nil
    local ok = pcall(function()
        jig.MainJigContainers:ForEach(function(_, c)
            local cont = c:get()
            if guid_str(cont[F_CONT_UID]) ~= cuid then return false end
            local holder = guid_str(cont[F_HOLDER])
            found = { holder = holder, items = {} }
            cont[F_ITEMS]:ForEach(function(_, it)
                read_item(it, found.items, cuid, holder)
            end)
            return true   -- UE4SS stops a ForEach on true
        end)
    end)
    if not ok then return nil end
    return found
end

-- Every item of the inventory: [uid] = { uid, g, n, da, cuid, holder }.
local function all_items(jig)
    local by_uid = {}
    pcall(function()
        jig.MainJigContainers:ForEach(function(_, c)
            local cont = c:get()
            local cuid = guid_str(cont[F_CONT_UID])
            local holder = guid_str(cont[F_HOLDER])
            local list = {}
            pcall(function()
                cont[F_ITEMS]:ForEach(function(_, it) read_item(it, list, cuid, holder) end)
            end)
            for _, e in ipairs(list) do by_uid[e.uid] = e end
        end)
    end)
    return by_uid
end

-- [grid uid] = { cap = the capacity of the loader that owns it (nil: no
-- owner found, looked for again after NO_OWNER_RETRY_S), name, warned, at }
-- (data assets do not change; a grid UID lives as long as its loader)
local caps, caps_n = {}, 0

-- The loader grid's capacity: the owning item's ContainerCapacity (the
-- host's data), else the Max the reloading machine sent (`hint`).
local function capacity_of(jig, cuid, grid, hint)
    local c = caps[cuid]
    if c and c.cap == nil and os.clock() - c.at >= NO_OWNER_RETRY_S then c = nil end
    if not c then
        local all = all_items(jig)
        local holder = all[grid.holder]
        local v = holder and ue.valid(holder.da) and tonumber(ue.prop(holder.da, "ContainerCapacity")) or nil
        if caps_n >= CAP_KEEP then caps, caps_n = {}, 0 end
        if v and v > 0 then
            c = { cap = math.floor(v), name = item_name(holder.da), warned = false, at = os.clock() }
        else
            c = { cap = nil, name = "?", warned = false, at = os.clock() }
        end
        caps[cuid] = c
        caps_n = caps_n + 1
    end
    if c.cap == nil then
        if hint and hint > 0 then return math.floor(hint), "request" end
        return nil
    end
    if hint and hint > 0 and hint ~= c.cap and not c.warned then
        c.warned = true
        log.warn("reloadcap: the reload request says capacity %d, the loader %s holds %d here; %d is used",
            hint, c.name, c.cap, c.cap)
    end
    return c.cap, "data"
end

-- A stack's count in the host's data: a number, false when it is not
-- there, nil when the data could not be read.
local function stack_count(jig, cuid, uid)
    local grid = find_grid(jig, cuid)
    if grid then
        for _, e in ipairs(grid.items) do
            if e.uid == uid then return e.n end
        end
    end
    local all = all_items(jig)   -- (the grid read failed, or the item is elsewhere)
    local e = all[uid]
    if e then return e.n end
    if next(all) == nil then return nil end
    return false
end

-- The plugin's count setter on the host's data, checked by reading it back:
-- true; true + "unread" (the call ran, the data could not be read back: taken
-- as done - a second give-back would double rounds); false + why.
local function set_count(jig, e, n)
    local ok, err = pcall(function() jig:ServerUpdateCountByUID(e.g, n) end)
    if not ok then return false, tostring(err) end
    local now = stack_count(jig, e.cuid, e.uid)
    if now == n then return true end
    if now == nil then return true, "unread" end
    return false, now == false and "the stack is gone" or string.format("count %d, not %d", now, n)
end

local function tell(jig, e, n)
    local ok = pcall(function() jig:CLIENT_UpdateCount(jig, e.g, n, ZERO) end)
    return ok
end

-- n of `da` at the player's feet (the game's drop: JigMP_OnRequestDropItem,
-- then the pickup's count).
local function drop_at(pawn, da, n)
    local out = {}
    local ok, err = pcall(function()
        pawn:JigMP_OnRequestDropItem({ [F_ITEMID] = da, [F_COUNT] = n, [F_PENDING] = -1 }, FName("None"), out)
    end)
    local a = out.ActorRef
    if not ok or not ue.valid(a) then return false, ok and "no pickup came" or tostring(err) end
    pcall(function() a:SetPickupCount(n, {}) end)
    return true
end

-- A grid that belongs to a weapon or a weapon attachment: a gun's slots
-- (its chamber holds one round), a magazine / loader (ContainerCapacity), a
-- scope... (ItemType Jig.ItemType.MainFirearm / Sidearm / WeaponAttachment;
-- DA_SawnOffShotgun: Sidearm, DA_*Loader / DA_*Mag: WeaponAttachment).
local function weapon_grid(all, e)
    local holder = all[e.holder]
    if not holder or not ue.valid(holder.da) then return false end
    local hcap = tonumber(ue.prop(holder.da, "ContainerCapacity")) or 0
    if hcap > 0 then return true end
    local tag = ue.str(ue.try(function() return holder.da.ItemType.TagName end)) or ""
    return tag:find("Firearm", 1, true) ~= nil or tag:find("Sidearm", 1, true) ~= nil
        or tag:find("Weapon", 1, true) ~= nil
end

-- Stacks that take rounds back: the one the request named, then the
-- inventory's other stacks of that ammo, largest first - never the loader
-- itself nor a grid of a weapon or an attachment (weapon_grid).
local function back_targets(all, cuid, src, da)
    local list = {}
    if src and same_asset(src.da, da) then list[1] = src end
    local others = {}
    for _, e in pairs(all) do
        if e ~= src and e.cuid ~= cuid and same_asset(e.da, da) and not weapon_grid(all, e) then
            others[#others + 1] = e
        end
    end
    table.sort(others, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.uid < b.uid end)
    for _, e in ipairs(others) do list[#list + 1] = e end
    return list
end

-- Host: loader grid `cuid` of `jig` (owner `pawn`) after a reload request
-- that took a round from stack `src_uid`; `hint` = the Max the request
-- carried. nil when the grid is within its capacity, else a result
-- { had, cap, taken, back, dropped, failed, unread }.
function M.check(jig, pawn, cuid, src_uid, hint)
    M.stats.checks = M.stats.checks + 1
    local grid = find_grid(jig, cuid)
    if not grid or #grid.items == 0 then return nil end
    local total = 0
    for _, e in ipairs(grid.items) do total = total + e.n end
    -- the Max a request carries is the loader's ContainerCapacity (the
    -- requester's JSI_Slot @586): within it, no inventory walk until this
    -- grid's capacity is known
    if not caps[cuid] and hint and hint > 0 and total <= hint then return nil end
    local cap, cap_from = capacity_of(jig, cuid, grid, hint)
    if not cap or total <= cap then return nil end
    M.stats.over = M.stats.over + 1
    local res = { had = total, cap = cap, taken = 0, back = 0, dropped = 0, failed = 0, unread = 0, parts = {} }
    local all = all_items(jig)
    local src = src_uid and all[src_uid] or nil
    local src_gone = src_uid ~= nil and src == nil and next(all) ~= nil
    if src and src.cuid == cuid then src = nil end   -- (never back into the loader itself)
    -- the stack of the ammo just loaded first, then the larger ones
    local list = {}
    for _, e in ipairs(grid.items) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        local sa, sb = src and same_asset(a.da, src.da) or false, src and same_asset(b.da, src.da) or false
        if sa ~= sb then return sa end
        if a.n ~= b.n then return a.n > b.n end
        return a.uid < b.uid
    end)
    local excess = total - cap
    for _, e in ipairs(list) do
        if excess <= 0 then break end
        local r = math.min(excess, e.n - 1)   -- a stack is never emptied here
        if r > 0 then
            local ok, why = set_count(jig, e, e.n - r)
            if not ok then
                res.failed = res.failed + r
                res.parts[#res.parts + 1] = string.format("%s %s: taking %d out FAILED (%s)", item_name(e.da), e.uid, r,
                    tostring(why))
            else
                if why == "unread" then res.unread = res.unread + 1 end
                excess = excess - r
                res.taken = res.taken + r
                local okt = tell(jig, e, e.n - r)
                local part = string.format("%s %s %d -> %d%s%s", item_name(e.da), e.uid, e.n, e.n - r,
                    why == "unread" and " (not read back)" or "", okt and "" or " (telling the owner FAILED)")
                -- the rounds go back onto stacks of that ammo, the rest at the player's feet
                local left = r
                local max = int(ue.prop(e.da, "MaxStack"))
                for _, t in ipairs(back_targets(all, cuid, src, e.da)) do
                    if left <= 0 then break end
                    local fit = max > 0 and math.min(left, max - t.n) or left
                    if fit > 0 then
                        local okb, whyb = set_count(jig, t, t.n + fit)
                        if okb then
                            tell(jig, t, t.n + fit)
                            part = part .. string.format(", %d back onto %s (%d -> %d%s)", fit, t.uid, t.n, t.n + fit,
                                whyb == "unread" and ", not read back" or "")
                            if whyb == "unread" then res.unread = res.unread + 1 end
                            t.n = t.n + fit
                            left = left - fit
                            res.back = res.back + fit
                        else
                            part = part .. string.format(", back onto %s FAILED (%s)", t.uid, tostring(whyb))
                        end
                    end
                end
                if left > 0 then
                    local okd, whyd = drop_at(pawn, e.da, left)
                    if okd then
                        res.dropped = res.dropped + left
                        part = part .. string.format(", %d dropped at the player's feet%s", left,
                            src_gone and " (the stack they came from is gone)" or "")
                    else
                        res.failed = res.failed + left
                        part = part .. string.format(", %d NOT given back (drop failed: %s)", left, tostring(whyd))
                    end
                end
                res.parts[#res.parts + 1] = part
            end
        end
    end
    M.stats.taken = M.stats.taken + res.taken
    M.stats.back = M.stats.back + res.back
    M.stats.dropped = M.stats.dropped + res.dropped
    M.stats.failed = M.stats.failed + res.failed
    M.stats.unread = M.stats.unread + res.unread
    local line = string.format("reloadcap: %s's loader grid %s held %d round(s), capacity %d (%s): %s",
        ue.short(pawn), cuid, total, cap, cap_from, table.concat(res.parts, "; "))
    if res.failed > 0 or res.unread > 0 then
        log.warn("%s", line)
    elseif M.stats.over <= INFO_LINES then
        log.info("%s", line)
    else
        log.debug("%s", line)
    end
    return res
end

-- SERVER_RequestReloadInternal(MagContainerUID, AmmoToAdd, MaxCap), post
-- (host: the round is already in the loader).
local function on_reload_request(c, mag_p, ammo_p, max_p)
    if not S or S.role ~= "host" or not on() then return end
    local jig = c and c:get()
    if not ue.valid(jig) then return end
    local pawn = ue.try(function() return jig:GetOwner() end)
    if not is_player(pawn) then return end
    local cuid = uid_of(param(mag_p))
    if not cuid then return end
    local res = M.check(jig, pawn, cuid, uid_of(param(ammo_p)), tonumber(param(max_p)))
    if not res or res.taken == 0 then return end
    if res.had <= res.cap + 1 and res.dropped <= 0 then return end   -- one round: no note
    local fields = { tostring(res.cap), tostring(res.had), tostring(res.back), tostring(res.dropped) }
    local pc = remote_pc_of(pawn)
    if pc then
        net.send_to(pc, "RLNOTE", table.unpack(fields))
    else
        M.client_note(fields)   -- the host's own gun
    end
end

-- ===========================================================================
-- Client: the own reload counted at once
-- ===========================================================================

-- grids[grid uid] = { g, jig (the own component), max, stack (uid of the
-- loader stack being loaded), stack_g, auth (the host's last count of it),
-- others (the grid's other stacks), reqs = { { t, ammo uid } }, oldest
-- first }; ammo[uid] = { g, auth, pending }; just = the request made inside
-- the Jig_StartReloading call running now
local pred = { grids = {}, ammo = {}, just = nil }

local function own_jig(c)
    local jig = c and c:get()
    if not ue.valid(jig) then return nil end
    local owner = ue.try(function() return jig:GetOwner() end)
    local me = ue.local_pawn()
    if not ue.valid(owner) or not me or addr(owner) ~= addr(me) then return nil end
    return jig
end

-- the own inventory widget (JSI_Slot) of an item
local function find_slot(jig, g)
    local found = nil
    pcall(function()
        jig.LocalJSIContainers:ForEach(function(_, e)
            local out = {}
            pcall(function() jig:FindItemInContainer(e:get(), g, out) end)
            if ue.valid(out.Found) then
                found = out.Found
                return true
            end
            return false
        end)
    end)
    return found
end

-- the slots { uid, g, n, da } of a grid's widget (JSIContainer), nil when
-- there is no such widget
local function grid_slots(jig, g)
    local ref, fnd = {}, {}
    pcall(function() jig:FindJSIContainer(g, ref, fnd) end)
    local w = ref.JSIRef
    if not ue.valid(w) then return nil end
    local slots = {}
    for _, s in ipairs(list_of(ue.prop(w, "ArrayOfItems"))) do
        if ue.valid(s) then
            local sg = ue.prop(s, "ItemUniqueID")
            local u = uid_of(sg)
            if u then
                slots[#slots + 1] = { uid = u, g = guid_tbl(sg), n = int(ue.prop(s, "ItemCount")),
                                      da = ue.prop(s, "JigDataAsset") }
            end
        end
    end
    return slots
end

-- the game's own way to show a count (what an answer does)
local function show(jig, g, n)
    pcall(function() jig:ClientUpdateCount(g, n, true) end)
end

-- Shows grid G's loader stack and the ammo stacks `ammo_uids` from the
-- host's counts and the unanswered requests. `force`: also when nothing is
-- unanswered any more (requests expired: back to the host's counts).
local function apply(jig, G, force, ammo_uids)
    if G.stack and G.auth and G.auth > 0 and (#G.reqs > 0 or force) then
        local want = G.auth + #G.reqs
        if G.max and G.max > 0 and #G.reqs > 0 then
            want = math.max(1, math.min(want, G.max - (G.others or 0)))
        end
        show(jig, G.stack_g, want)
    end
    for u in pairs(ammo_uids or {}) do
        local A = pred.ammo[u]
        if A and A.auth and (A.pending > 0 or force) then
            show(jig, A.g, math.max(0, A.auth - A.pending))
        end
        if A and A.pending <= 0 then pred.ammo[u] = nil end
    end
end

local function ammo_of(G)
    local set = {}
    for _, r in ipairs(G.reqs) do set[r.ammo] = true end
    return set
end

-- A reload is still going: the host's count of its loader stack is kept
-- (answers and shots keep it current). The widget is read only at the
-- first request of a reload - a chamber step after a reload takes a round
-- with no count message (FireArmChamberWeapon sends only
-- CLIENT_UpdateChamberBulletUID), so the host's count is never carried over
-- to the next reload. A reload ends with its last round (Jig_StartReloading's
-- Result false), a chamber step from its loader, the own loop montage's end
-- (sdc_combat calls loop_ended), else after CYCLE_GAP_S without a request or
-- an answer.
local function same_cycle(G, now)
    return G.open == true and G.stack ~= nil and G.auth ~= nil and now - (G.last_at or -1e9) < CYCLE_GAP_S
end

-- JigComp_CallRequestReloadInternal(MagContainerUID, AmmoToAdd, MaxCap,
-- Result), post, the own component on a client: a round request is on its
-- way to the host.
local function on_own_request(c, mag_p, ammo_p, max_p)
    if not S or S.role ~= "client" or not on() then return end
    local jig = own_jig(c)
    if not jig then return end
    local mag, ammo = param(mag_p), param(ammo_p)
    local gu, au = uid_of(mag), uid_of(ammo)
    if not gu or not au then return end
    local now = os.clock()
    local G = pred.grids[gu]
    if not G then
        G = { g = guid_tbl(mag), reqs = {} }
        pred.grids[gu] = G
    end
    G.jig = jig
    local max = int(param(max_p))
    if max > 0 then G.max = max end
    local A = pred.ammo[au]
    local aslot = nil
    if not A or A.pending <= 0 then
        -- nothing unanswered from this stack: its widget shows the host's count
        aslot = find_slot(jig, guid_tbl(ammo))
        A = { g = guid_tbl(ammo), auth = aslot and int(ue.prop(aslot, "ItemCount")) or nil, pending = 0 }
        pred.ammo[au] = A
    end
    if #G.reqs == 0 and not same_cycle(G, now) then
        -- the first request of a reload: the loader's widget is the latest
        -- count (the own shots and chamber step included); the stack of this
        -- ammo is the first of its kind there, as the host's insert takes
        -- the first one (an answer naming another stack corrects it)
        aslot = aslot or find_slot(jig, guid_tbl(ammo))
        local ada = aslot and ue.prop(aslot, "JigDataAsset")
        local slots = grid_slots(jig, G.g)
        if not slots then
            M.stats.no_widget = M.stats.no_widget + 1
            if M.stats.no_widget <= 3 then
                log.warn("reloadcap: no widget of loader grid %s on this screen: this reload is counted by the host's answers only", gu)
            end
        end
        local pick = nil
        for _, s in ipairs(slots or {}) do
            if ue.valid(ada) and same_asset(s.da, ada) then
                pick = s
                break
            end
        end
        if not pick and not ue.valid(ada) and slots and #slots == 1 then pick = slots[1] end
        G.others = 0   -- the grid's other stacks (another kind of ammo) stay as they are
        for _, s in ipairs(slots or {}) do
            if not pick or s.uid ~= pick.uid then G.others = G.others + s.n end
        end
        if pick then
            G.stack, G.stack_g, G.auth = pick.uid, pick.g, pick.n
        else
            G.stack, G.stack_g, G.auth = nil, nil, nil   -- a first stack: from its CLIENT_NewItemAdded on
        end
        G.mismatch_logged = false
    end
    G.open, G.last_at = true, now
    G.reqs[#G.reqs + 1] = { t = now, ammo = au }
    A.pending = A.pending + 1
    M.stats.predicted = M.stats.predicted + 1
    apply(jig, G, false, { [au] = true })
    pred.just = { gu = gu, t = now }   -- for Jig_StartReloading's answer, right after this
end

-- The Cap the game's Round_In read through MagContainer (the weapon's mag
-- slot widget): GetEquippedItemRef -> GetContainerCapacity (BP_FirearmPickup.
-- LocalStartReloadInternal @150-305 reads it the same way).
local function game_cap(mag)
    if not ue.valid(mag) then return nil end
    local found, ref, pending = {}, {}, {}
    pcall(function() mag:GetEquippedItemRef(found, ref, pending) end)
    local item = ref.ItemRef
    if not ue.valid(item) then return nil end
    local cap, maxc = {}, {}
    pcall(function() item:GetContainerCapacity(cap, maxc) end)
    return tonumber(cap.Cap)
end

-- BP_FirearmPickup.Jig_StartReloading(MPCom, MagContainer, WithMag, Result),
-- post, client: the Round_In's own decision (@90647: Result false -> Delay
-- 0.25 -> StopAnimMontage -> ChamberAfterReloadWeapon, the normal end). When
-- the round just asked for makes the gun full by the host's own counts
-- (its last absolute count + the requests on their way), the reload ends
-- here even if the loader's widget the game read does not show it - the
-- game's own end, not an interrupt. With the prediction working this is
-- what the game decides anyway (Max - Cap == 1); it matters when that
-- widget does not follow the host's answers (2026-11-13: 16 rounds in one
-- reload at a 50 ms ping, no frame hitch on the client). The Cap the game
-- read is compared with the count shown from the host's: a difference is
-- logged (that widget is not the one the answers reach).
local function on_start_reloading(c, _, mag_p, _, res_p)
    if not S or S.role ~= "client" or not on() then return end
    local j = pred.just
    pred.just = nil
    if not j or os.clock() - j.t > 0.05 then return end
    local G = pred.grids[j.gu]
    if not G or not G.max or G.max <= 0 or not G.auth then return end
    local will = G.auth + #G.reqs + (G.others or 0)
    local cap = game_cap(param(mag_p))
    if cap and cap ~= math.min(G.max, will) then
        M.stats.mismatch = M.stats.mismatch + 1
        -- one line per reload (at most MISMATCH_LINES)
        if not G.mismatch_logged and M.stats.mismatch_lines < MISMATCH_LINES then
            G.mismatch_logged = true
            M.stats.mismatch_lines = M.stats.mismatch_lines + 1
            log.warn("reloadcap: the loader count this reload reads is %d, the count shown from the host's is %d (host %d + %d on the way + %d of another kind, capacity %d): the widget the game reads does not follow the host's answers%s",
                cap, math.min(G.max, will), G.auth, #G.reqs, G.others or 0, G.max,
                will >= G.max and " - the reload ends by the host's count" or "")
        end
    end
    local res = param(res_p)
    if will >= G.max and res == true then
        local ok = pcall(function() res_p:set(false) end)
        if ok then res = false end
        M.stats.ended = M.stats.ended + 1
        if M.stats.ended <= 5 then
            log.info("reloadcap: own reload ended after this round: the host's count %d + %d on the way%s = %d of %d (Result set %s)",
                G.auth, #G.reqs, (G.others or 0) > 0 and string.format(" + %d of another kind", G.others) or "", will, G.max,
                ok and "false" or "FAILED")
        end
    end
    -- this round ends the reload (the game's last round, or ours): the next
    -- reload reads the widget again (the chamber step follows)
    if res ~= true then G.open = false end
end

-- JigComp_CallServerChamberWeapon(ChamberContainerUID, MagContainerUID,
-- BulletToChamberUID, ChamberContainerIndex, SendChamberUID?, Result), post,
-- own component on a client: a round goes from the loader into the chamber
-- (BP_FirearmPickup.ChamberWeapon @1627-1940: TryUseBullet on this screen,
-- FireArmChamberWeapon on the host) with no count message - after a reload
-- and at every shot of a pump / bolt gun. The host's last count of that
-- loader is old from here: its reload is closed, the next one reads the
-- widget (the game took the round there too).
local function on_own_chamber(c, _, mag_p)
    if not S or S.role ~= "client" or not on() then return end
    local gu = uid_of(param(mag_p))
    local G = gu and pred.grids[gu]
    if not G or not own_jig(c) then return end
    G.open = false
    M.stats.chambered = M.stats.chambered + 1
end

-- the oldest unanswered request of G is answered: its ammo stack's uid
local function answered(G)
    local r = table.remove(G.reqs, 1)
    if not r then return nil end
    M.stats.answered = M.stats.answered + 1
    G.last_at = os.clock()
    local A = pred.ammo[r.ammo]
    if A and A.pending > 0 then A.pending = A.pending - 1 end
    return r.ammo
end

-- CLIENT_UpdateCounts(Counts, TempUID), post, own component: the game's
-- answer to a round request names the loader stack and the ammo stack.
local function on_counts(c, counts_p)
    if not S or S.role ~= "client" or not on() then return end
    if next(pred.grids) == nil and next(pred.ammo) == nil then return end
    local jig = own_jig(c)
    if not jig then return end
    local list = {}
    for _, e in ipairs(list_of(param(counts_p))) do
        local u = ue.try(function() return guid_str(e[F_UC_UID]) end)
        if u then list[#list + 1] = { uid = u, n = int(ue.try(function() return e[F_UC_COUNT] end)) } end
    end
    local done = {}
    for _, G in pairs(pred.grids) do
        local hit = false
        if #G.reqs > 0 and #list == 2 then
            -- the answer to the oldest request names the loader stack the
            -- host loaded, next to that request's ammo stack: shown from
            -- here on when it is not the one picked (not found on this
            -- screen, or two stacks of one kind in the loader)
            local a = G.reqs[1].ammo
            for i, e in ipairs(list) do
                local other = list[3 - i]
                if e.uid == a and other.uid ~= G.stack and not pred.ammo[other.uid] then
                    local slots = grid_slots(jig, G.g)
                    local inside = slots == nil
                    for _, s in ipairs(slots or {}) do
                        if s.uid == other.uid then inside = true end
                    end
                    if inside then
                        if G.stack and G.auth then show(jig, G.stack_g, G.auth) end   -- back to the host's count
                        G.stack, G.stack_g = other.uid, guid_of(other.uid)
                        if slots then
                            G.others = 0
                            for _, s in ipairs(slots) do
                                if s.uid ~= G.stack then G.others = G.others + s.n end
                            end
                        end
                        M.stats.restacked = M.stats.restacked + 1
                    end
                end
            end
        end
        for _, e in ipairs(list) do
            if G.stack and e.uid == G.stack then
                G.auth = e.n
                hit = true
            end
        end
        if hit and #G.reqs > 0 then
            local ammo_uids = ammo_of(G)
            answered(G)
            for _, e in ipairs(list) do
                local A = pred.ammo[e.uid]
                if A then
                    A.auth = e.n
                    ammo_uids[e.uid] = true
                    done[e.uid] = true
                end
            end
            apply(jig, G, false, ammo_uids)
        end
    end
    -- an ammo stack's absolute count in some other answer
    local loose = {}
    for _, e in ipairs(list) do
        local A = pred.ammo[e.uid]
        if A and not done[e.uid] then
            A.auth = e.n
            loose[e.uid] = true
        end
    end
    if next(loose) then apply(jig, { reqs = {} }, false, loose) end
end

-- CLIENT_NewItemAdded(ItemInfo, UID, ToContainerUID, ToIndex,
-- FinalRotation, UpdateCount, ...), post, own component: the answer to a
-- request into an empty loader (a first stack).
local function on_new_item(c, info_p, uid_p, to_p, _, _, upd_p)
    if not S or S.role ~= "client" or not on() then return end
    local to = uid_of(param(to_p))
    local G = to and pred.grids[to]
    if not G or #G.reqs == 0 then return end
    local jig = own_jig(c)
    if not jig then return end
    local ug = param(uid_p)
    local u = uid_of(ug)
    if not u then return end
    local info = param(info_p)
    G.stack, G.stack_g = u, guid_tbl(ug)
    G.auth = int(info and ue.try(function() return info[F_COUNT] end))
    local ammo_uids = ammo_of(G)
    answered(G)
    local upd = param(upd_p)
    local au = upd and ue.try(function() return guid_str(upd[F_UC_UID]) end)
    if au and pred.ammo[au] then
        pred.ammo[au].auth = int(ue.try(function() return upd[F_UC_COUNT] end))
        ammo_uids[au] = true
    end
    apply(jig, G, false, ammo_uids)
end

-- CLIENT_UpdateCount(TargetComp, ItemUID, NewCount, RemovedPending), post,
-- own component: an absolute count (a shot, the host's correction).
local function on_count(c, _, uid_p, n_p)
    if not S or S.role ~= "client" or not on() then return end
    if next(pred.grids) == nil and next(pred.ammo) == nil then return end
    local u = uid_of(param(uid_p))
    if not u then return end
    local n = int(param(n_p))
    local jig = nil
    for _, G in pairs(pred.grids) do
        if G.stack == u then
            G.auth = n
            if #G.reqs > 0 then
                jig = jig or own_jig(c)
                if jig then apply(jig, G, false, ammo_of(G)) end
            end
        end
    end
    local A = pred.ammo[u]
    if A and A.pending > 0 then
        A.auth = n
        jig = jig or own_jig(c)
        if jig then apply(jig, { reqs = {} }, false, { [u] = true }) end
    end
end

-- Client, every EXPIRE_TICK_MS: requests the host never answered (it found
-- that ammo stack or loader no more) stop counting; an ammo stack whose
-- last round this screen took away for such a request is asked for again
-- (RESEND: the host sends the item, sdc_consume).
local function expire_tick()
    if not S or S.role ~= "client" then return end
    local now = os.clock()
    for gu, G in pairs(pred.grids) do
        local gone, n = {}, 0
        while G.reqs[1] and now - G.reqs[1].t > PRED_EXPIRE_S do
            local r = table.remove(G.reqs, 1)
            n = n + 1
            local A = pred.ammo[r.ammo]
            if A and A.pending > 0 then A.pending = A.pending - 1 end
            gone[r.ammo] = true
        end
        if n > 0 then
            M.stats.expired = M.stats.expired + n
            local before = {}
            for u in pairs(gone) do
                local A = pred.ammo[u]
                if A then before[u] = { g = A.g, auth = A.auth, pending = A.pending } end
            end
            for u in pairs(ammo_of(G)) do gone[u] = true end
            local jig = G.jig
            if not ue.valid(jig) then
                local me = ue.local_pawn()
                jig = me and ue.prop(me, "BP_JigMultiplayer")
            end
            if ue.valid(jig) then
                apply(jig, G, true, gone)
                for u, b in pairs(before) do
                    if b.pending <= 0 and b.auth and b.auth > 0 and not find_slot(jig, b.g) then
                        net.send_to_host("RESEND", u)
                        M.stats.resent = M.stats.resent + 1
                        log.info("reloadcap: ammo stack %s (%d left on the host) is gone from this screen after an unanswered request: asked the host for it again (RESEND)",
                            u, b.auth)
                    end
                end
            end
            log.warn("reloadcap: %d round request(s) into loader grid %s got no answer from the host in %d s: the loaded count shows the host's again",
                n, gu, PRED_EXPIRE_S)
        end
        if #G.reqs == 0 and (not G.open or now - (G.last_at or -1e9) >= CYCLE_GAP_S) then pred.grids[gu] = nil end
    end
end

-- sdc_combat: the own loop montage ended (one reload is over).
function M.loop_ended()
    for _, G in pairs(pred.grids) do G.open = false end
end

-- ===========================================================================
-- Hooks, note, state
-- ===========================================================================

local HOOKS = {
    { fn = "SERVER_RequestReloadInternal", cb = on_reload_request },        -- host
    { fn = "JigComp_CallRequestReloadInternal", cb = on_own_request },      -- client
    { fn = "CLIENT_UpdateCounts", cb = on_counts },                         -- client
    { fn = "CLIENT_NewItemAdded", cb = on_new_item },                       -- client
    { fn = "CLIENT_UpdateCount", cb = on_count },                           -- client
    { fn = "JigComp_CallServerChamberWeapon", cb = on_own_chamber },       -- client
    { path = FIREARM .. "Jig_StartReloading", fn = "Jig_StartReloading", cb = on_start_reloading },   -- client
}
local hook = { looping = false, ticking = false }

local function try_hooks()
    local all = true
    for _, h in ipairs(HOOKS) do
        if not h.done then
            local cb, name = h.cb, h.fn
            local ok = pcall(RegisterHook, h.path or (JIG .. name), function(c, ...)
                local okc, err = pcall(cb, c, ...)
                if not okc then log.err_throttled("reloadcap." .. name, "reloadcap: %s hook: %s", name, tostring(err)) end
            end)
            if ok then
                h.done = true
                log.info("reloadcap: %s hook ok", name)
            else
                all = false
            end
        end
    end
    return all
end

-- Called once at startup (sdc_combat.install): the hooks are retried every
-- 2 s until BP_JigComponent is loaded.
function M.install()
    if not hook.ticking then
        hook.ticking = true
        ue.every("reloadcap-expire", EXPIRE_TICK_MS, expire_tick)
    end
    if hook.looping then return end
    hook.looping = true
    if try_hooks() then return end
    local function retry()
        if try_hooks() then return end
        ue.delay("reloadcap-hook", HOOK_RETRY_MS, retry)
    end
    ue.delay("reloadcap-hook", HOOK_RETRY_MS, retry)
end

-- fields: cap, had, back, dropped (RLNOTE, or the host's own gun).
function M.client_note(f)
    local cap, had = tonumber(f[1]), tonumber(f[2])
    local back, dropped = tonumber(f[3]) or 0, tonumber(f[4]) or 0
    if not cap or not had then return false end
    local i18n = package.loaded["sdc_i18n"]
    if i18n == nil then
        local ok, m = pcall(require, "sdc_i18n")
        if ok then i18n = m end
    end
    if type(i18n) ~= "table" or type(i18n.T) ~= "function" then return false end
    local text
    if dropped > 0 and back <= 0 then
        text = i18n.T("rlcap_floor", had, cap, dropped)
    elseif dropped > 0 then
        text = i18n.T("rlcap_drop", had, cap, back, dropped)
    else
        text = i18n.T("rlcap_back", had, cap, back)
    end
    M.stats.notes = M.stats.notes + 1
    log.toast(text, "info", 8, string.format("reloadcap: the gun held %d round(s), capacity %d: %d back in the inventory, %d at the feet",
        had, cap, back, dropped))
    return true
end

function M.register_handlers()
    -- host -> the player whose gun was set right: RLNOTE|cap|had|back|dropped
    net.on("RLNOTE", function(f)
        if not S or S.role ~= "client" then return end
        local ok, err = pcall(M.client_note, f)
        if not ok then log.err_throttled("reloadcap.note", "reloadcap: RLNOTE: %s", tostring(err)) end
    end)
end

function M.reset()
    caps, caps_n = {}, 0
    pred.grids, pred.ammo, pred.just = {}, {}, nil
end

function M.status_line()
    local s = M.stats
    local hooked = 0
    for _, h in ipairs(HOOKS) do if h.done then hooked = hooked + 1 end end
    return string.format("reloadcap: host checks=%d over capacity=%d rounds taken out=%d back=%d dropped=%d failed=%d not read back=%d notes=%d | own rounds predicted=%d answered=%d expired=%d no widget=%d reloads ended by the host's count=%d widget not following=%d stack corrected=%d stacks asked again=%d chamber steps=%d | hooks %d/%d",
        s.checks, s.over, s.taken, s.back, s.dropped, s.failed, s.unread, s.notes, s.predicted, s.answered, s.expired,
        s.no_widget, s.ended, s.mismatch, s.restacked, s.resent, s.chambered, hooked, #HOOKS)
end

-- tests: the client's bookkeeping and its expiry tick
M._t = { pred = pred, expire_tick = expire_tick, PRED_EXPIRE_S = PRED_EXPIRE_S }

return M
