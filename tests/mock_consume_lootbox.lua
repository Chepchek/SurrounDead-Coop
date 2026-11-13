-- Loot boxes opened by a client (2026-11-13, 0.11.0 report: "the box and the
-- loot just vanish for the client; for the host it works"). The host added the
-- reward with the plugin's AddNewItemSomewhere, which took the first grid of
-- the SERVER data with room - a wallet, a med bag - whose widget on the client
-- refuses a weapon: HandleAddNewItem showed nothing, and the client's next
-- rebuild of that grid had the host delete it. The default attachments' notice
-- (CLIENT_NewItemAdded from the add's out-struct) failed in UE4SS.
-- Fixed in sdc_consume: the client's IGAIN says where ITS screen put the item
-- (grid / stack / no room); the host adds there, fits the default attachments
-- into the new item's slots and tells the client with one CLIENT_AddNewItem
-- (the item and what is inside it); no room -> at the player's feet, as single
-- player. An item the host adds that the client's grid widget still refuses is
-- told to the host (IGLOST) and dropped at the player's feet.
-- Runs the real sdc_consume twice (a client and a host instance) against fake
-- engine objects: the plugin's server data, the client's grid widgets (the
-- wallet takes money only, the med bag medical items), UE4SS's strict
-- parameter counts and its out-parameter tables.
-- usage: lua mock_consume_lootbox.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 1000.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- logs
local logs = {}
local WHO = "?"
local log = setmetatable({ debug_enabled = false, probes_enabled = false }, { __index = function(_, k)
    return function(a, ...)
        local fmt, args = a, { ... }
        if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
        local ok, s = pcall(string.format, fmt, table.unpack(args))
        logs[#logs + 1] = WHO .. " " .. k .. ": " .. tostring(ok and s or fmt)
    end
end })
local function log_has(pat, from)
    for i = (from or 0) + 1, #logs do if logs[i]:find(pat, 1, true) then return logs[i] end end
    return nil
end

-- ---------------------------------------------------------------- engine mocks
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o) return ue.valid(o) and (rawget(o, "__cls") or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all() return {} end
local assets = {}
function ue.find_object(p) return assets[p] end
function ue.load_asset() return true end
function ue.ksl() return nil end
ue.__me = nil
function ue.local_pawn() return ue.__me end
function ue.delay() return false end
function ue.pawn_of(pc) return pc.Pawn end
function ue.role(a) return a and a.Role or -1 end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local CFG = {}
package.loaded["sdc_config"] = { get = function(k) local v = CFG[k]; if v == nil then return true end return v end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and (rawget(o, "__name") or tostring(o)) or nil end }
package.loaded["sdc_containers"] = { host_rpc = function() end, init = function() end }
local CUR                        -- the instance being loaded / run: "client" | "host"
local hooks = { client = {}, host = {} }
local handlers = { client = {}, host = {} }
local outbox = { client = {}, host = {} }
local function fields(...)
    local f = {}
    for i = 1, select("#", ...) do local v = select(i, ...); f[i] = (v == nil) and "" or tostring(v) end
    return f
end
package.loaded["sdc_net"] = {
    send_to_host = function(kind, ...) table.insert(outbox.client, { kind = kind, f = fields(...) }); return true end,
    send_to = function(_, kind, ...) table.insert(outbox.host, { kind = kind, f = fields(...) }); return true end,
    broadcast = function() end,
    on = function(kind, fn) handlers[CUR][kind] = fn end,
}
RegisterHook = function(path, fn) hooks[CUR][path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end

-- a UFunction as UE4SS 3.0.1 calls it: exactly its number of parameters
local function strict(np, fn)
    return function(self, ...)
        local got = select("#", ...)
        if got ~= np then error(string.format("UFunction expected %d parameters, received %d", np, got)) end
        return fn(self, ...)
    end
end
local function arr(t) return { _t = t, ForEach = function(self, f)
    for i, v in ipairs(self._t) do if f(i, { get = function() return v end }) == true then break end end
end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 7, C = -3, D = 11 } end
local function gs(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end
local ZERO = { A = 0, B = 0, C = 0, D = 0 }

local F = {
    ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    REP = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332",
    INC = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF",
    USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD",
    MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D",
    SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE",
    SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7",
    PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB",
    A_ID = "ID_21_A45B60654D588805C5D52BA4BC5CD4FD",
    A_MIN = "MinCount_31_E62F0FA548FC7DB0BDB860B4C0D695B6",
    A_INDEX = "AddToContainerIndex_11_3CB23949434BAB8C7EEBE09362324A4C",
}

-- ---------------------------------------------------------------- item data assets
local DA = {}
local function da(name, max, subs, atts)
    local path = "/Game/Inventory/Items/DataAssets/" .. name .. "." .. name
    local d = { __name = name, __cls = "JigsawItem_DataAsset_C", __path = path, MaxStack = max, __subs = subs or 0,
                DefaultAttachments = arr(atts or {}), PickupClass = { __name = "BP_" .. name:gsub("^DA_", "") .. "Pickup_C" } }
    DA[name] = d
    assets[path] = d
    return d
end
da("DA_556Mag", 1, 1)
da("DA_SteyrAug", 1, 7, { { [F.A_ID] = DA.DA_556Mag, [F.A_MIN] = 1, [F.A_INDEX] = 3 } })
da("DA_Katana", 1, 0)
da("DA_Can", 10, 0)
da("DA_Cloth", 20, 0)
da("DA_Money", 1000, 0)
da("DA_Bandages", 10, 0)
da("DA_Wallet", 1, 1)
da("DA_MedBag", 1, 1)
da("DA_LargeBlackMilitaryBackpack", 1, 1)
da("DA_Tier1LootBox", 1, 0)

-- ---------------------------------------------------------------- the host's data of the client
local next_uid = 5000
local function newg() next_uid = next_uid + 1; return G(next_uid) end
local G_TOP, G_WALLET, G_MED, G_BP = G(21), G(22), G(23), G(24)
local U_WALLET, U_MED, U_BP = G(11), G(12), G(13)
-- in the server data's order: the top grid (full), the wallet's grid and the
-- med bag's (the plugin's AddNewItemSomewhere takes the wallet: it lists no
-- item types there), the backpack's
local server = {
    { [F.REP] = G_TOP, [F.INC] = ZERO, [F.ITEMS] = arr({}), cap = 2, name = "top" },
    { [F.REP] = G_WALLET, [F.INC] = U_WALLET, [F.ITEMS] = arr({}), cap = 20, name = "wallet" },
    { [F.REP] = G_MED, [F.INC] = U_MED, [F.ITEMS] = arr({}), cap = 20, name = "medbag" },
    { [F.REP] = G_BP, [F.INC] = U_BP, [F.ITEMS] = arr({}), cap = 20, name = "backpack" },
}
local function grid_of(g)
    for _, c in ipairs(server) do if gs(c[F.REP]) == gs(g) then return c end end
    return nil
end
local function server_item(d, n, c, u)
    local it = { [F.USID] = u or newg(), [F.INFO] = { [F.ID] = d, [F.COUNT] = n }, [F.SLOT] = #c[F.ITEMS]._t,
                 [F.MOTHER] = c[F.REP], [F.SUBS] = arr({}) }
    -- an item with slots of its own: its grids at the end of the data (TryAddNewItem: AppendNewContainers)
    for _ = 1, d.__subs do
        local sg = newg()
        table.insert(it[F.SUBS]._t, { [F.SUB_ID] = sg })
        server[#server + 1] = { [F.REP] = sg, [F.INC] = it[F.USID], [F.ITEMS] = arr({}), cap = 1, name = d.__name .. " slot" }
    end
    table.insert(c[F.ITEMS]._t, it)
    return it
end
server_item(DA.DA_LargeBlackMilitaryBackpack, 1, server[1], U_BP)
server_item(DA.DA_Wallet, 1, server[1], U_WALLET)
server_item(DA.DA_Money, 50, server[2])
server_item(DA.DA_Bandages, 3, server[3])
local CAN_STACK = server_item(DA.DA_Can, 3, server[4])
local function find_server(u)
    for _, c in ipairs(server) do
        for i, it in ipairs(c[F.ITEMS]._t) do if gs(it[F.USID]) == u then return it, c, i end end
    end
    return nil
end
local function server_count(name)
    local n = 0
    for _, c in ipairs(server) do
        for _, it in ipairs(c[F.ITEMS]._t) do if it[F.INFO][F.ID].__name == name then n = n + 1 end end
    end
    return n
end

-- the host's RPCs to the client, applied as the client's game does
local to_client = {}
local calls = {}
local function ncalls(name)
    local n = 0
    for _, c in ipairs(calls) do if c[1] == name then n = n + 1 end end
    return n
end
local function last_call(name)
    for i = #calls, 1, -1 do if calls[i][1] == name then return calls[i] end end
    return nil
end

-- ---------------------------------------------------------------- host objects
local conn = { __name = "IpConnection_0" }
local rpc = { __name = "BP_PlayerController_C_1", NetConnection = conn }
local rpawn = { __name = "BP_PlayerCharacter_C_1", __cls = "BP_PlayerCharacter_C", Controller = rpc, Role = 3 }
rpc.Pawn = rpawn
local rcomp = { __name = "BP_JigMultiplayer_1" }
rcomp.GetOwner = function() return rpawn end
rcomp.MainJigContainers = arr(server)
rpawn.BP_JigMultiplayer = rcomp
local pickups = {}
rcomp.AddNewItemSomewhere = strict(10, function(_, d, n, _, _, _, _, added, dropped, uid, to)
    calls[#calls + 1] = { "AddNewItemSomewhere", d.__name, n }
    for _, c in ipairs(server) do
        if #c[F.ITEMS]._t < c.cap and c.name ~= "top" then
            local it = server_item(d, n, c)
            to_client[#to_client + 1] = { kind = "add", item = it, content = {}, pending = ZERO }
            added.Added, dropped["Dropped?"] = true, false
            for k, v in pairs(it[F.USID]) do uid[k] = v end
            for k, v in pairs(c[F.REP]) do to[k] = v end
            return
        end
    end
    added.Added = false
end)
-- the plugin's add into one grid (TryAddNewItem, first free slot; no message)
rcomp.Generate_AddNewItemToContainer = strict(5, function(_, g, d, n, info, res)
    calls[#calls + 1] = { "Generate_AddNewItemToContainer", gs(g), d.__name, n }
    local c = grid_of(g)
    if not c or #c[F.ITEMS]._t >= c.cap then res["Added?"] = false return end
    local it = server_item(d, n, c)
    for k, v in pairs(it) do info[k] = v end   -- (a struct out-param: its fields into the table)
    res["Added?"] = true
end)
rcomp.ServerUpdateCountByUID = strict(2, function(_, g, nc)
    calls[#calls + 1] = { "ServerUpdateCountByUID", gs(g), nc }
    local it = find_server(gs(g))
    if it then it[F.INFO][F.COUNT] = nc end
end)
rcomp.CLIENT_AddNewItem = strict(4, function(self, it, content, comp, pending)
    calls[#calls + 1] = { "CLIENT_AddNewItem", gs(it[F.USID]), #content }
    assert(comp == self and type(content) == "table" and gs(pending) == "0:0:0:0", "CLIENT_AddNewItem arguments")
    to_client[#to_client + 1] = { kind = "add", item = it, content = content, pending = pending }
end)
rcomp.CLIENT_UpdateCount = strict(4, function(self, target, g, nc, pending)
    calls[#calls + 1] = { "CLIENT_UpdateCount", gs(g), nc }
    assert(target == self and gs(pending) == "0:0:0:0", "CLIENT_UpdateCount arguments")
    to_client[#to_client + 1] = { kind = "count", uid = gs(g), n = nc }
end)
rcomp.CLIENT_NewItemAdded = function() calls[#calls + 1] = { "CLIENT_NewItemAdded" }; error("not expected") end
-- the plugin's drop request as the game runs it (HandleServerDropRequest):
-- the item leaves the data first (RemoveGetInfo @1164), then the pickup is
-- spawned at the owner (JigMP_OnRequestDropItem) - which may give none
rcomp.SERVER_RequestDropItem = strict(3, function(self, g, n, target)
    calls[#calls + 1] = { "SERVER_RequestDropItem", gs(g), n }
    assert(target == self, "drop target")
    if self.__fail_drop then return end   -- (refused: still in the inventory)
    local it, c, i = find_server(gs(g))
    if not it then return end
    table.remove(c[F.ITEMS]._t, i)
    local out = {}
    rpawn:JigMP_OnRequestDropItem({ [F.ID] = it[F.INFO][F.ID], [F.COUNT] = n, [F.PENDING] = -1 }, "None", out)
    to_client[#to_client + 1] = { kind = "removed", uid = gs(g) }
end)
local PFN_DROP = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:JigMP_OnRequestDropItem"
rpawn.JigMP_OnRequestDropItem = strict(3, function(self, info, cname, out)
    calls[#calls + 1] = { "JigMP_OnRequestDropItem", info[F.ID].__name, info[F.COUNT] }
    assert(info[F.PENDING] == -1 and cname == "None", "drop info")
    local p = nil
    if not self.__fail_jdrop then
        p = { __name = "BP_Pickup_" .. (#pickups + 1), n = 1,
              BP_JigPickupComponent = { ItemDataAsset = info[F.ID].__pickup_da or info[F.ID] } }
        p.SetPickupCount = strict(2, function(s, cnt, r) s.n = cnt; r.Result = true end)
        pickups[#pickups + 1] = { name = info[F.ID].__name, actor = p, by = "game drop" }
        out.ActorRef = p
    end
    -- (UE4SS runs the host's post-hook on it, also for a call from Lua)
    local h = hooks.host[PFN_DROP]
    if h then
        local cur, who = CUR, WHO
        CUR, WHO = "host", "host"
        h({ get = function() return self end }, { get = function() return info end }, { get = function() return cname end },
            { get = function() return p end })
        CUR, WHO = cur, who
    end
end)

-- ---------------------------------------------------------------- client objects
local me = { __name = "BP_PlayerCharacter_C_0", __cls = "BP_PlayerCharacter_C", Role = 2 }
me.IsLocallyControlled = function() return true end
ue.__me = me
local mycomp = { __name = "BP_JigMultiplayer_0" }
mycomp.GetOwner = function() return me end
me.BP_JigMultiplayer = mycomp
local pending = {}
mycomp.PendingRequests = arr(pending)
mycomp.RemoveRequestByUID = function(_, g, clear, out)
    for i, s in ipairs(pending) do
        if gs(s.ItemUniqueID) == gs(g) then
            table.remove(pending, i)
            if clear then
                local w = s.ContainerMother
                for j, x in ipairs(w.__slots) do if x == s then table.remove(w.__slots, j) end end
                s.ContainerMother = nil
            end
            out.Removed = true
            return
        end
    end
    out.Removed = false
end
local widgets = {}
local function widget(name, g, accepts)
    local w = setmetatable({ __name = "JSIContainer_" .. name, ContainerName = name, ContainerID = g, __slots = {},
                             __accepts = accepts }, { __index = function(t, k)
        if k == "ArrayOfItems" then return arr(rawget(t, "__slots")) end
    end })
    widgets[gs(g)] = w
    return w
end
local w_top = widget("Pockets", G_TOP, function() return true end)
local w_wallet = widget("Wallet", G_WALLET, function(n) return n == "DA_Money" end)
local w_med = widget("MedBag", G_MED, function(n) return n == "DA_Bandages" end)
local w_bp = widget("Backpack", G_BP, function() return true end)
mycomp.LocalJSIContainers = arr({ w_top, w_bp, w_wallet, w_med })
local function slot_widget(w, idx, u, name, n)
    local s = { __name = "JSI_Slot_" .. w.__name .. "_" .. idx, ContainerMother = w, SlotIndex = idx, ItemUniqueID = u,
                JigDataAsset = DA[name], ItemCount = n, IsPending = false }
    table.insert(w.__slots, s)
    return s
end
-- what the client shows already (as the host's data)
for _, c in ipairs(server) do
    local w = widgets[gs(c[F.REP])]
    for _, it in ipairs(c[F.ITEMS]._t) do
        if w then slot_widget(w, it[F.SLOT], it[F.USID], it[F.INFO][F.ID].__name, it[F.INFO][F.COUNT]) end
    end
end
local function shown(u)
    local n, where = 0, nil
    for _, w in pairs(widgets) do
        for _, s in ipairs(w.__slots) do if gs(s.ItemUniqueID) == u then n = n + 1; where = w end end
    end
    return n, where
end
local function shown_name(name)
    local n = 0
    for _, w in pairs(widgets) do
        for _, s in ipairs(w.__slots) do if s.JigDataAsset and s.JigDataAsset.__name == name then n = n + 1 end end
    end
    return n
end

-- ---------------------------------------------------------------- the two instances
local function load(role)
    CUR = role
    package.loaded["sdc_consume"] = nil
    package.loaded["sdc_place"] = nil   -- (each instance its own: sdc_consume drives it)
    local m = require("sdc_consume")
    local S = { role = role, remote_pcs = role == "host" and { rpc } or {} }
    m.init(S)
    m.register_handlers()
    if role == "client" then m.client_tick() else m.host_tick({ rpc }) end
    return m, S
end
local CM = load("client")
local HM = load("host")
package.loaded["sdc_consume"] = nil

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local PFN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"

local function fire(role, path, ...)
    CUR = role
    WHO = role
    local h = hooks[role][path]
    assert(h, role .. " hook missing: " .. path)
    h(...)
end
-- the client's game applying the host's RPCs (HandleAddNewItem: the widget of
-- the item's grid takes it or not; SetupNewAddedItem: what is inside it)
local inside_shown = {}
local function client_apply()
    local q = to_client
    to_client = {}
    for _, r in ipairs(q) do
        if r.kind == "add" then
            local it = r.item
            local w = widgets[gs(it[F.MOTHER])]
            local name = it[F.INFO][F.ID].__name
            if w and w.__accepts(name) then
                slot_widget(w, it[F.SLOT], it[F.USID], name, it[F.INFO][F.COUNT])
                local subs = {}
                for _, s in ipairs(it[F.SUBS]._t) do subs[gs(s[F.SUB_ID])] = true end
                for _, x in ipairs(r.content) do
                    if subs[gs(x[F.MOTHER])] then inside_shown[#inside_shown + 1] = x[F.INFO][F.ID].__name end
                end
            end
            fire("client", JIG .. "CLIENT_AddNewItem", C(mycomp), P(it), P(r.content), P(r.comp or mycomp), P(r.pending))
        elseif r.kind == "count" then
            for _, w in pairs(widgets) do
                for _, s in ipairs(w.__slots) do if gs(s.ItemUniqueID) == r.uid then s.ItemCount = r.n end end
            end
        end
    end
end
-- messages client -> host
local function deliver()
    local q = outbox.client
    outbox.client = {}
    for _, m in ipairs(q) do
        CUR = "host"; WHO = "host"
        local h = handlers.host[m.kind]
        assert(h, "host handler missing: " .. m.kind)
        h(m.f, rpc)
    end
end
local function sent(kind)
    for i = #outbox.client, 1, -1 do if outbox.client[i].kind == kind then return outbox.client[i].f end end
    return nil
end

-- the client's single-player add of what a use gave: JigTryAddGetPendingRef
-- reserves a slot in the first grid widget that takes the item (or names the
-- stack it would grow, or none), then JigTryAddItemSomewhere
local local_n = 900
local function client_local_add(name, n, w, stack_slot)
    local slot = stack_slot
    if w then
        local_n = local_n + 1
        slot = slot_widget(w, 40 + local_n % 10, G(local_n), name, n)
        slot.IsPending = true
        pending[#pending + 1] = slot
    end
    fire("client", JIG .. "JigTryAddGetPendingRef", C(mycomp), P({ [F.ID] = DA[name], [F.COUNT] = n }), P(true),
        P(slot), P(stack_slot ~= nil))
    fire("client", JIG .. "JigTryAddItemSomewhere", C(mycomp), P(mycomp), P(DA[name]), P(n), P(false), P(ZERO))
    return slot
end
-- the client's use request reaching the host (SERVER_RequestConsumeItem post,
-- the box already used up): from a world container (TargetComp: the chest's
-- component) or from the own inventory (`own`: the box's server entry goes)
local chest = { __name = "BP_Infestation_Ceiling_C_7_Jig", MainJigContainers = arr({}) }
local function host_use(box_uid, own)
    local target = chest
    if own then
        local _, c, i = find_server(gs(box_uid))
        if c then table.remove(c[F.ITEMS]._t, i) end
        target = rcomp
    end
    fire("host", JIG .. "SERVER_RequestConsumeItem", C(rcomp), P(target), P(box_uid), P(1), P(""))
end

-- =====================================================================
print("== 0. hooks and messages")
check(hooks.client[JIG .. "CLIENT_AddNewItem"] ~= nil, "client: CLIENT_AddNewItem hook (is the host's add shown?)")
check(handlers.host.IGAIN ~= nil and handlers.host.IGLOST ~= nil, "host: IGAIN and IGLOST handled")

print("== 1. a loot box from a world container: a SteyrAug with its magazine, where the client's screen put it")
local n_log = #logs
local box = G(777)
local reserved = client_local_add("DA_SteyrAug", 1, w_bp)
local f = sent("IGAIN")
check(f and f[1] == DA.DA_SteyrAug.__path and f[2] == "1" and f[3] == "c" and f[4] == gs(G_BP) and f[5] == tostring(reserved.SlotIndex),
    "IGAIN carries the grid and slot the client's screen reserved (" .. table.concat(f or {}, "|") .. ")")
check(#pending == 0 and select(1, shown(gs(reserved.ItemUniqueID))) == 0, "the client's flickering placeholder is gone")
check(log_has("asked the host to add it into grid " .. gs(G_BP) .. ", where this screen put it", n_log), "client log names the grid")
-- the use request comes after the IGAIN (another channel): the gain waits for it
deliver()
check(ncalls("Generate_AddNewItemToContainer") == 0, "nothing added before the use request")
host_use(box)
check(ncalls("AddNewItemSomewhere") == 0, "the plugin's any-grid add is not used")
local gen = calls[1]
check(gen and gen[1] == "Generate_AddNewItemToContainer" and gen[2] == gs(G_BP) and gen[3] == "DA_SteyrAug",
    "the rifle went into the backpack grid the client's screen chose (not the wallet the plugin's add picks)")
local aug = nil
for _, it in ipairs(server[4][F.ITEMS]._t) do if it[F.INFO][F.ID].__name == "DA_SteyrAug" then aug = it end end
check(aug ~= nil and server_count("DA_SteyrAug") == 1, "one SteyrAug in the host's data, in the backpack")
local slot3 = aug and gs(aug[F.SUBS]._t[4][F.SUB_ID])
local g2 = calls[2]
check(g2 and g2[1] == "Generate_AddNewItemToContainer" and g2[2] == slot3 and g2[3] == "DA_556Mag" and g2[4] == 1,
    "its default magazine went into its own slot 3 (AddToContainerIndex)")
check(ncalls("CLIENT_AddNewItem") == 1 and last_call("CLIENT_AddNewItem")[2] == gs(aug[F.USID])
    and last_call("CLIENT_AddNewItem")[3] == 1, "ONE CLIENT_AddNewItem: the rifle with its magazine inside")
check(ncalls("CLIENT_NewItemAdded") == 0, "no CLIENT_NewItemAdded from an out-struct (UE4SS refused its ToContainerUID)")
check(log_has("gets SteyrAug x1 from using an item, where its screen put it", n_log)
    and log_has("attachments: 556Mag x1", n_log) and log_has("the client was told (CLIENT_AddNewItem, 1 inside)", n_log),
    "host log: where, the attachment, the client told")
client_apply()
local n_aug, w_aug = shown(gs(aug[F.USID]))
check(n_aug == 1 and w_aug == w_bp and shown_name("DA_SteyrAug") == 1, "the client shows the rifle exactly once, in the backpack")
check(inside_shown[#inside_shown] == "DA_556Mag", "the client got the magazine inside it")
check(sent("IGLOST") == nil, "nothing refused")
check(log_has("the host added SteyrAug x1 (uid " .. gs(aug[F.USID]) .. "): shown here (Backpack slot", n_log), "client log: shown")

print("== 2. a box in the client's own inventory: the gain right after the use request")
n_log = #logs
local box2 = server_item(DA.DA_Tier1LootBox, 1, server[4])
slot_widget(w_bp, box2[F.SLOT], box2[F.USID], "DA_Tier1LootBox", 1)
-- (the host's snapshot of the inventory has the box: the use is judged against it)
HM.host_tick({ rpc })
host_use(box2[F.USID], true)
client_local_add("DA_Katana", 1, w_bp)
deliver()
local kat = nil
for _, it in ipairs(server[4][F.ITEMS]._t) do if it[F.INFO][F.ID].__name == "DA_Katana" then kat = it end end
check(kat ~= nil and server_count("DA_Katana") == 1 and #server[2][F.ITEMS]._t == 1, "the Katana is in the backpack, not in the wallet")
client_apply()
check(shown_name("DA_Katana") == 1, "the client shows it once")

print("== 3. junk onto the stack the client's screen would grow")
n_log = #logs
local can_slot = nil
for _, s in ipairs(w_bp.__slots) do if gs(s.ItemUniqueID) == gs(CAN_STACK[F.USID]) then can_slot = s end end
host_use(G(778))
client_local_add("DA_Can", 1, nil, can_slot)
f = sent("IGAIN")
check(f and f[3] == "s" and f[4] == gs(CAN_STACK[F.USID]), "IGAIN names the stack")
deliver()
check(last_call("ServerUpdateCountByUID") and last_call("ServerUpdateCountByUID")[2] == gs(CAN_STACK[F.USID])
    and last_call("ServerUpdateCountByUID")[3] == 4, "the host counts that stack up (3 -> 4)")
check(last_call("CLIENT_UpdateCount") and last_call("CLIENT_UpdateCount")[3] == 4, "and tells the client its new count")
client_apply()
check(can_slot.ItemCount == 4 and server_count("DA_Can") == 1, "the client's stack shows 4, no second stack")
-- that stack full: a new stack in its grid
CAN_STACK[F.INFO][F.COUNT] = 10
can_slot.ItemCount = 10
host_use(G(779))
client_local_add("DA_Can", 1, nil, can_slot)
deliver()
check(last_call("Generate_AddNewItemToContainer")[2] == gs(G_BP) and last_call("Generate_AddNewItemToContainer")[3] == "DA_Can"
    and server_count("DA_Can") == 2, "its stack full here: a new stack in that stack's grid")
client_apply()
check(shown_name("DA_Can") == 2, "the client shows the new stack")

print("== 4. no room on the client's screen: at its feet, as single player")
n_log = #logs
local c0 = #calls
host_use(G(780))
client_local_add("DA_Cloth", 2, nil, nil)
f = sent("IGAIN")
check(f and f[3] == "n", "IGAIN: no room on this screen")
deliver()
local drop = last_call("JigMP_OnRequestDropItem")
check(drop and drop[2] == "DA_Cloth" and drop[3] == 2 and pickups[#pickups].actor and pickups[#pickups].actor.n == 2,
    "dropped at the player's feet with its count")
check(server_count("DA_Cloth") == 0 and ncalls("Generate_AddNewItemToContainer") == (function()
    local n = 0; for i = 1, c0 do if calls[i][1] == "Generate_AddNewItemToContainer" then n = n + 1 end end; return n end)(),
    "nothing added to the inventory")
check(log_has("gets Cloth x2 from using an item at their feet (its screen has no room for it)", n_log), "host log: at the feet")

print("== 5. what the host's data cannot take: at the feet, never into another grid")
n_log = #logs
server[4].cap = #server[4][F.ITEMS]._t   -- the backpack is full here (the views differ)
host_use(G(781))
client_local_add("DA_Katana", 1, w_bp)
deliver()
check(server_count("DA_Katana") == 1 and last_call("JigMP_OnRequestDropItem")[2] == "DA_Katana", "its grid full here: dropped at the feet")
check(log_has("has no room for it here", n_log), "log: why")
server[4].cap = 40
-- a grid the host does not know
host_use(G(782))
fire("client", JIG .. "JigTryAddGetPendingRef", C(mycomp), P({}), P(true), P(nil), P(false))
CUR = "host"; WHO = "host"
handlers.host.IGAIN({ DA.DA_Katana.__path, "1", "c", gs(G(99999)), "0" }, rpc)
check(last_call("JigMP_OnRequestDropItem")[2] == "DA_Katana" and log_has("is not in its inventory here", n_log),
    "an unknown grid: dropped at the feet")
-- no word at all
host_use(G(783))
handlers.host.IGAIN({ DA.DA_Katana.__path, "1" }, rpc)
check(ncalls("AddNewItemSomewhere") == 0 and log_has("no word where its screen put it", n_log), "no word: at the feet, not the plugin's add")
outbox.client = {}

print("== 6. an item the host puts where the client's widget refuses it: dropped at its feet")
n_log = #logs
-- (the plugin's add for other host code: the first grid with room in the data - the wallet)
CUR = "host"; WHO = "host"
local added, dropped, uid, to = {}, {}, {}, {}
rcomp:AddNewItemSomewhere(DA.DA_Katana, 1, nil, 1, true, "None", added, dropped, uid, to)
check(gs(to) == gs(G_WALLET), "(the plugin's add picked the wallet)")
client_apply()
f = sent("IGLOST")
check(f and f[1] == gs(uid), "the client's wallet widget refused it: IGLOST sent")
check(log_has("whose widget here does not take it (not shown): asked the host to drop it", n_log), "client log")
deliver()
local dr = last_call("SERVER_RequestDropItem")
check(dr and dr[2] == gs(uid) and dr[3] == 1 and find_server(gs(uid)) == nil, "the host dropped it with the plugin's drop (it keeps what is inside)")
check(log_has("dropped at their feet", n_log), "host log")
-- told once: the same add again within the wait
rcomp:AddNewItemSomewhere(DA.DA_Katana, 1, nil, 1, true, "None", added, dropped, uid, to)
local u2 = gs(uid)
client_apply()
outbox.client = {}
fire("client", JIG .. "CLIENT_AddNewItem", C(mycomp), P(find_server(u2)), P({}), P(mycomp), P(ZERO))
check(#outbox.client == 0, "the same item is told only once in " .. tostring(CM._t.gain.AGAIN_S) .. " s")
-- the host tries one item at most once in that time too (here its drop fails:
-- the item stays in the data)
CUR = "host"; WHO = "host"
rcomp.__fail_drop = true
local nd0 = ncalls("SERVER_RequestDropItem")
handlers.host.IGLOST({ u2 }, rpc)
local nd = ncalls("SERVER_RequestDropItem")
handlers.host.IGLOST({ u2 }, rpc)
check(nd == nd0 + 1 and ncalls("SERVER_RequestDropItem") == nd and log_has("NOT dropped (still in their inventory", n_log),
    "the host tries it once in " .. tostring(HM._t.gain.AGAIN_S) .. " s and says when the drop did not happen")
rcomp.__fail_drop = nil
advance(6)
handlers.host.IGLOST({ u2 }, rpc)
check(ncalls("SERVER_RequestDropItem") == nd + 1 and find_server(u2) == nil, "later it is tried again (and dropped)")
nd = ncalls("SERVER_RequestDropItem")
-- an item not in the player's inventory: nothing
handlers.host.IGLOST({ gs(G(123456)) }, rpc)
check(ncalls("SERVER_RequestDropItem") == nd and log_has("not in their inventory here either", n_log), "unknown item: nothing dropped")

print("== 7. what is not judged")
n_log = #logs
local wcomp = { __name = "BP_JigComponent_Chest" }
-- (a Katana for the med bag's grid: its widget here refuses it - only the
-- checks below keep it from being told)
local in_med = { [F.USID] = G(4141), [F.INFO] = { [F.ID] = DA.DA_Katana, [F.COUNT] = 1 }, [F.MOTHER] = G_MED,
                 [F.SLOT] = 1, [F.SUBS] = arr({}) }
fire("client", JIG .. "CLIENT_AddNewItem", C(mycomp), P(in_med), P({}), P(mycomp), P(G(5)))
check(sent("IGLOST") == nil, "the answer to a move (PendingUID set) is not judged")
fire("client", JIG .. "CLIENT_AddNewItem", C(mycomp), P(in_med), P({}), P(wcomp), P(ZERO))
check(sent("IGLOST") == nil, "a world container's item is not judged")
local ghost_mother = { [F.USID] = G(4242), [F.INFO] = { [F.ID] = DA.DA_Katana, [F.COUNT] = 1 }, [F.MOTHER] = G(31337),
                       [F.SLOT] = 0, [F.SUBS] = arr({}) }
fire("client", JIG .. "CLIENT_AddNewItem", C(mycomp), P(ghost_mother), P({}), P(mycomp), P(ZERO))
check(sent("IGLOST") == nil and log_has("which this screen has not built: not shown yet", n_log), "a grid this screen has not built is not judged")
-- refused_items_to_feet off: logged, not told
CFG.refused_items_to_feet = false
local refused = { [F.USID] = G(4343), [F.INFO] = { [F.ID] = DA.DA_Katana, [F.COUNT] = 1 }, [F.MOTHER] = G_MED,
                  [F.SLOT] = 2, [F.SUBS] = arr({}) }
fire("client", JIG .. "CLIENT_AddNewItem", C(mycomp), P(refused), P({}), P(mycomp), P(ZERO))
check(sent("IGLOST") == nil and log_has("refused_items_to_feet is off", n_log), "setting off: the client only logs it")
CUR = "host"; WHO = "host"
local nd2 = ncalls("SERVER_RequestDropItem")
handlers.host.IGLOST({ gs(CAN_STACK[F.USID]) }, rpc)
check(ncalls("SERVER_RequestDropItem") == nd2, "setting off: the host drops nothing")
CFG.refused_items_to_feet = nil

print("== 8. the host's own loot box: single-player code, untouched")
n_log = #logs
local hc = #calls
local hpawn = { __name = "BP_PlayerCharacter_C_host", __cls = "BP_PlayerCharacter_C", Controller = { __name = "PC_host" } }
hpawn.IsLocallyControlled = function() return true end
local hcomp = { __name = "BP_JigMultiplayer_host" }
hcomp.GetOwner = function() return hpawn end
local np = #pickups
fire("host", JIG .. "JigTryAddItemSomewhere", C(hcomp), P(hcomp), P(DA.DA_SteyrAug), P(1), P(true), P(G(55)))
check(#calls == hc and #pickups == np and #outbox.client == 0 and not log_has("SteyrAug", n_log),
    "the host's own add (its widgets took it) is left alone")
-- its own box's use is no remote player's use: no gain is paid for it
fire("host", JIG .. "SERVER_RequestConsumeItem", C(hcomp), P(hcomp), P(G(56)), P(1), P(""))
check(#calls == hc, "nothing added for the host's own use")

print("== 9. the gain needs a use request")
n_log = #logs
local gc = ncalls("Generate_AddNewItemToContainer")
advance(30)
CUR = "host"; WHO = "host"
handlers.host.IGAIN({ DA.DA_Katana.__path, "1", "c", gs(G_BP), "1" }, rpc)
advance(7)
HM.host_tick({ rpc })
check(ncalls("Generate_AddNewItemToContainer") == gc and log_has("with no item use around it; not added", n_log), "no use around it: nothing added")

-- =====================================================================
-- What the game's windows take (SC_Wallet: Currency / Keycard; SC_MedicalBag:
-- MedicalConsumable + its AlsoSupportTheseItems; an item data asset with no
-- ItemType of its own has the class default Jig.ItemType.Other) and the
-- items' kinds; the wallet's and the med bag's grids are those items' own.
local function kind(name, tag) DA[name].ItemType = { TagName = "Jig.ItemType." .. tag } end
da("DA_EmptyWaterBottle", 1, 0)
da("DA_DirtyWaterJug", 1, 0)
da("DA_Mystery", 1, 0)   -- (a kind that cannot be read: never judged)
da("DA_ResearchKeycard", 1, 0)
da("DA_FirstAidBook", 1, 0)
da("DA_Battery", 5, 0)
da("DA_556Ammo", 60, 0)
da("DA_NoPickup", 1, 0)
DA.DA_NoPickup.PickupClass = nil   -- (no pickup class: a drop of it would only take it out of the data)
da("DA_Briefcase", 1, 1)
da("DA_SmallToolbox", 1, 1)
da("DA_MilitaryPlateCarrier", 1, 3)
da("DA_OddBag", 1, 1)
da("DA_MilitaryPlateCarrier2", 1, 3)
-- (its pickup class is BP_MilitaryPlateCarrier1Pickup, whose component names
-- DA_MilitaryPlateCarrier: the item rides in its PickupInfo)
DA.DA_MilitaryPlateCarrier2.__pickup_da = DA.DA_MilitaryPlateCarrier
for name, tag in pairs({ DA_Katana = "Melee", DA_Can = "Other", DA_Cloth = "Material", DA_Money = "Currency",
                         DA_Bandages = "MedicalConsumable", DA_SteyrAug = "MainFirearm", DA_556Mag = "WeaponAttachment",
                         DA_Wallet = "Container", DA_MedBag = "Container", DA_LargeBlackMilitaryBackpack = "Backpack",
                         DA_Tier1LootBox = "Other", DA_EmptyWaterBottle = "Other", DA_DirtyWaterJug = "DrinkConsumable",
                         DA_ResearchKeycard = "Keycard", DA_FirstAidBook = "Other", DA_Battery = "Other",
                         DA_556Ammo = "Ammunition", DA_NoPickup = "Other", DA_Briefcase = "Container",
                         DA_SmallToolbox = "Container", DA_MilitaryPlateCarrier = "BodyArmor", DA_OddBag = "Container",
                         DA_MilitaryPlateCarrier2 = "BodyArmor" }) do
    kind(name, tag)
end
DA.DA_Wallet.SpecialContainerWidget = { __name = "SC_Wallet_C" }
DA.DA_MedBag.SpecialContainerWidget = { __name = "SC_MedicalBag_C" }
DA.DA_Briefcase.SpecialContainerWidget = { __name = "SC_Briefcase_C" }
DA.DA_SmallToolbox.SpecialContainerWidget = { __name = "SC_SmallToolbox_C" }
DA.DA_MilitaryPlateCarrier.SpecialContainerWidget = { __name = "SC_MilitaryPlateCarrier_C" }
DA.DA_OddBag.SpecialContainerWidget = { __name = "SC_SomethingElse_C" }
find_server(gs(U_WALLET))[F.SUBS]._t = { { [F.SUB_ID] = G_WALLET } }
local medbag_item = server_item(DA.DA_MedBag, 1, server[4], U_MED)
medbag_item[F.SUBS]._t = { { [F.SUB_ID] = G_MED } }
server[4].cap = 80
-- the remote player's character and the pickups the game drops at its feet
-- (their paths, as the host finds them again; sdc_items sees each one spawn)
rpawn.__path = "/Game/Levels/L.L:PersistentLevel." .. rpawn.__name
assets[rpawn.__path] = rpawn
local seen = {}
package.loaded["sdc_items"] = { recent_pickups = function(since)
    local out = {}
    for _, e in ipairs(seen) do if e.t >= since and ue.valid(e.a) then out[#out + 1] = e.a end end
    return out
end }
-- a destroyed actor stays valid for UE4SS until the garbage collector: only
-- the engine's IsValid (sdc_sweepguard.live) tells
package.loaded["sdc_sweepguard"] = { live = function(o) return rawget(o, "__live") ~= false end }
ue.location = function(a) return rawget(a, "__loc") end
local HP = package.loaded["sdc_place"]   -- (the host instance's)
-- (its walks so far learned the data assets before their kinds / windows
-- were set above: in the game those never change)
HP.reset()
for k in pairs(HP._t.TAGS) do HP._t.TAGS[k] = nil end
for k in pairs(HP._t.R.widget) do HP._t.R.widget[k] = nil end
local game_drop = rpawn.JigMP_OnRequestDropItem
rpawn.JigMP_OnRequestDropItem = strict(3, function(self, info, cname, out)
    local dropping = HP.dropping
    game_drop(self, info, cname, out)
    for i = #calls, 1, -1 do
        if calls[i][1] == "JigMP_OnRequestDropItem" then calls[i][5] = dropping break end
    end
    local pk = out.ActorRef
    if not pk then return end
    pk.__path = "/Game/Levels/L.L:PersistentLevel." .. pk.__name
    assets[pk.__path] = pk
    pk.K2_DestroyActor = function(a) a.__live = false end   -- (still "valid" for UE4SS)
    seen[#seen + 1] = { a = pk, t = T }
end)
-- the plugin's drop request as the game runs it (HandleServerDropRequest):
-- the item leaves the data first (RemoveGetInfo @1164), then the pickup is
-- spawned at the owner (JigMP_OnRequestDropItem) - which may give none
local base_drop_req = rcomp.SERVER_RequestDropItem
rcomp.SERVER_RequestDropItem = strict(3, function(self, g, n, target)
    local dropping = HP.dropping
    base_drop_req(self, g, n, target)
    for i = #calls, 1, -1 do
        if calls[i][1] == "SERVER_RequestDropItem" then calls[i][4] = dropping break end
    end
end)
-- the plugin's any-grid add finding no room and no drop at all
local any_add = rcomp.AddNewItemSomewhere
rcomp.AddNewItemSomewhere = strict(10, function(self, d, n, a, b, c, e, added, dropped, uid, to)
    if self.__no_room then
        calls[#calls + 1] = { "AddNewItemSomewhere", d.__name, n }
        added.Added, dropped["Dropped?"] = false, false
        return
    end
    return any_add(self, d, n, a, b, c, e, added, dropped, uid, to)
end)
-- host -> client messages
local function deliver_host()
    local q = outbox.host
    outbox.host = {}
    for _, m in ipairs(q) do
        CUR = "client"; WHO = "client"
        local h = handlers.client[m.kind]
        assert(h, "client handler missing: " .. m.kind)
        h(m.f)
    end
end
local function sent_host(kind_)
    for i = #outbox.host, 1, -1 do if outbox.host[i].kind == kind_ then return outbox.host[i].f end end
    return nil
end
local function all_sent_host(kind_)
    local out = {}
    for _, m in ipairs(outbox.host) do if m.kind == kind_ then out[#out + 1] = m.f end end
    return out
end
local function in_grid(c, name)
    for _, it in ipairs(c[F.ITEMS]._t) do if it[F.INFO][F.ID].__name == name then return it end end
    return nil
end
outbox.client, outbox.host = {}, {}

print("== 10. the drop at the feet fails: the plugin's add as the last way, else the player is told")
do
n_log = #logs
CUR = "host"; WHO = "host"
rpawn.__fail_jdrop = true
local a10 = ncalls("AddNewItemSomewhere")
local d10 = ncalls("SERVER_RequestDropItem")
host_use(G(790))
handlers.host.IGAIN({ DA.DA_Katana.__path, "1", "n", "", "" }, rpc)
local k10 = in_grid(server[2], "DA_Katana")
check(ncalls("AddNewItemSomewhere") == a10 + 1, "the drop failed: the plugin's add as the last way (the box is used up)")
check(log_has("the drop FAILED", n_log) and log_has("added by the plugin's add", n_log), "host log: the drop failed, the plugin's add")
check(k10 ~= nil and ncalls("SERVER_RequestDropItem") == d10,
    "it landed in the wallet: NOT dropped by the same failing way (that would only take it out of the data)")
local st10 = sent_host("IHID")
check(st10 and st10[1] == DA.DA_Katana.__path and st10[3] == DA.DA_Wallet.__path and st10[4] == "stuck"
    and log_has("whose window does not show it; the player was told", n_log) ~= nil,
    "the player is told it sits hidden in the wallet and cannot be dropped")
outbox.host = {}
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
check(find_server(gs(k10[F.USID])) ~= nil and ncalls("SERVER_RequestDropItem") == d10
    and log_has("NOT dropped: its drop gave no pickup lately", n_log) ~= nil, "nor by the 1 s walk while its drop fails lately")
-- no room and no drop at all: the player is told (RU/EN)
rcomp.__no_room = true
host_use(G(791))
outbox.host = {}
handlers.host.IGAIN({ DA.DA_Katana.__path, "1", "n", "", "" }, rpc)
local fl = sent_host("IFAIL")
check(fl and fl[1] == DA.DA_Katana.__path and fl[2] == "1", "nothing worked: IFAIL to that player")
check(log_has("LOST", n_log) ~= nil, "host log: lost")
deliver_host()
check(log_has("client say: place_lost", n_log) and log_has("could not give Katana x1", n_log), "the client shows it")
rpawn.__fail_jdrop, rcomp.__no_room = nil, nil
-- later, when drops work again, the walk takes it out of the wallet
advance(HP.NODROP_S + 1)
outbox.host = {}
HM.host_player(rpc)
check(find_server(gs(k10[F.USID])) == nil and #all_sent_host("IHID") == 1, "later (drops work again): to the feet, the player told")
outbox.host = {}

end
print("== 11. IGAIN onto a stack that holds ANOTHER item here: never counted onto it")
do
n_log = #logs
local cloth = server_item(DA.DA_Cloth, 5, server[4])
host_use(G(792))
local u11 = ncalls("ServerUpdateCountByUID")
local cans11 = server_count("DA_Can")
local d11 = ncalls("JigMP_OnRequestDropItem")
CUR = "host"; WHO = "host"
handlers.host.IGAIN({ DA.DA_Can.__path, "1", "s", gs(cloth[F.USID]), "" }, rpc)
check(ncalls("ServerUpdateCountByUID") == u11, "no count change on that stack")
check(cloth[F.INFO][F.COUNT] == 5 and cloth[F.INFO][F.ID] == DA.DA_Cloth, "that stack unchanged (Cloth x5)")
local g11 = last_call("Generate_AddNewItemToContainer")
check((server_count("DA_Can") == cans11 + 1 and g11 and g11[2] == gs(G_BP) and g11[3] == "DA_Can")
    or ncalls("JigMP_OnRequestDropItem") == d11 + 1, "the can: a new stack in that grid (or at the feet)")
check(log_has("holds Cloth here", n_log) ~= nil, "host log: why")
client_apply()
-- a UID mix-up naming a stack in the WALLET: never a new stack there
local money = in_grid(server[2], "DA_Money")
host_use(G(793))
local g11b = ncalls("Generate_AddNewItemToContainer")
outbox.host = {}
handlers.host.IGAIN({ DA.DA_Can.__path, "1", "s", gs(money[F.USID]), "" }, rpc)
check(ncalls("Generate_AddNewItemToContainer") == g11b and in_grid(server[2], "DA_Can") == nil,
    "a stack in the wallet: no new stack there (its window would refuse the can)")
check(last_call("JigMP_OnRequestDropItem")[2] == "DA_Can" and #HP._t.Q.pend == 1 and HP._t.Q.pend[1].due ~= nil,
    "the can at the feet, its screen asked a moment later")
check(log_has("does not take Can", n_log) ~= nil, "host log: why")
HP._t.Q.pend = {}

end
print("== 12. the host's own grants (the water well, a fish): where the client's screen puts them")
do
-- the client's widgets asked as single player asks them
-- (JigTryAddGetPendingRef: a stack it would grow, else a new pending slot in
-- the first widget that takes the item and has room; UE4SS runs its post-hook)
w_top.__cap = 2
mycomp.JigTryAddGetPendingRef = strict(4, function(self, info, check_stack, out_slot, out_stack)
    local d, n = info[F.ID], info[F.COUNT]
    local slot, stack = nil, false
    if check_stack and (d.MaxStack or 1) > 1 then
        for _, w in ipairs(mycomp.LocalJSIContainers._t) do
            for _, s in ipairs(w.__slots) do
                if s.JigDataAsset == d and not s.IsPending and (s.ItemCount or 0) + n <= d.MaxStack then slot, stack = s, true break end
            end
            if slot then break end
        end
    end
    if not slot then
        for _, w in ipairs(mycomp.LocalJSIContainers._t) do
            if w.__accepts(d.__name) and #w.__slots < (w.__cap or 30) then
                local_n = local_n + 1
                slot = slot_widget(w, 60 + #w.__slots, G(local_n), d.__name, n)
                slot.IsPending = true
                pending[#pending + 1] = slot
                break
            end
        end
    end
    out_slot.OutputPin = slot
    out_stack["Stack?"] = stack
    local h = hooks.client[JIG .. "JigTryAddGetPendingRef"]
    if h then h(C(self), P(info), P(check_stack), P(slot), P(stack)) end
end)
-- the game's server code giving the remote player an item: no widget on the
-- host -> its drop at the player's feet, Added? false
local function game_add(name, n)
    CUR = "host"; WHO = "host"
    local out = {}
    rpawn:JigMP_OnRequestDropItem({ [F.ID] = DA[name], [F.COUNT] = n, [F.PENDING] = -1 }, "None", out)
    fire("host", JIG .. "JigTryAddItemSomewhere", C(rcomp), P(rcomp), P(DA[name]), P(n), P(false), P(ZERO))
    return out.ActorRef
end
n_log = #logs
local a12, g12 = ncalls("AddNewItemSomewhere"), ncalls("Generate_AddNewItemToContainer")
outbox.host, outbox.client = {}, {}
local jug = game_add("DA_DirtyWaterJug", 1)
local wq = sent_host("WHERE")
check(wq and wq[2] == DA.DA_DirtyWaterJug.__path and wq[3] == "1", "the host asks that client's screen where it goes (WHERE)")
check(jug.__live ~= false and ncalls("AddNewItemSomewhere") == a12 and ncalls("Generate_AddNewItemToContainer") == g12,
    "nothing added yet: its pickup waits at the feet (never the any-grid add)")
local gt_ = CM._t.gate()
local slot0, add0, drop0 = gt_.local_slot, gt_.local_add, gt_.local_drop
deliver_host()
local wa = sent("WHEREIS")
check(wa and wa[1] == wq[1] and wa[2] == "c" and wa[3] == gs(G_BP), "the client's screen: the backpack grid its widgets chose")
check(#pending == 0, "the client's reservation given up at once")
check(gt_.local_slot == slot0 and gt_.local_add == add0 and gt_.local_drop == drop0,
    "the client's own pending-ref bookkeeping is not touched by the question")
deliver()
local g = last_call("Generate_AddNewItemToContainer")
check(g and g[2] == gs(G_BP) and g[3] == "DA_DirtyWaterJug" and server_count("DA_DirtyWaterJug") == 1,
    "the host put it into that grid")
check(jug.__live == false, "its pickup removed once the item is in")
client_apply()
check(shown_name("DA_DirtyWaterJug") == 1, "the client shows it once")
-- onto a stack its screen grows
local can_stack, can_n = nil, nil
for _, w in ipairs(mycomp.LocalJSIContainers._t) do
    for _, s in ipairs(w.__slots) do
        if not can_stack and s.JigDataAsset == DA.DA_Can and not s.IsPending and s.ItemCount < 10 then can_stack, can_n = s, s.ItemCount end
    end
end
check(can_stack ~= nil, "(a can stack with room on the client's screen)")
outbox.host, outbox.client = {}, {}
local can_pk = game_add("DA_Can", 1)
deliver_host()
wa = sent("WHEREIS")
check(wa and wa[2] == "s" and can_stack and wa[3] == gs(can_stack.ItemUniqueID), "the client's screen grows its can stack")
deliver()
local cu = last_call("ServerUpdateCountByUID")
check(cu and can_stack and cu[2] == gs(can_stack.ItemUniqueID) and cu[3] == can_n + 1 and can_pk.__live == false,
    "the host counts that stack up, the pickup goes")
-- no room on the client's screen: the pickup stays at the feet (single player)
n_log = #logs
w_bp.__cap = 0
local g12b = ncalls("Generate_AddNewItemToContainer")
outbox.host, outbox.client = {}, {}
local jug2 = game_add("DA_DirtyWaterJug", 1)
deliver_host()
check(sent("WHEREIS") and sent("WHEREIS")[2] == "n", "the client's screen: no room")
deliver()
check(jug2.__live ~= false and ncalls("Generate_AddNewItemToContainer") == g12b and server_count("DA_DirtyWaterJug") == 1,
    "no room: the pickup stays at the feet, nothing added")
check(log_has("stays at its feet: its screen has no room for it", n_log) ~= nil, "host log")
w_bp.__cap = nil
-- the pickup taken meanwhile (destroyed: still "valid" for UE4SS): nothing added
outbox.host, outbox.client = {}, {}
local jug3 = game_add("DA_DirtyWaterJug", 1)
jug3.__live = false
deliver_host()
deliver()
check(server_count("DA_DirtyWaterJug") == 1 and log_has("its pickup was taken meanwhile, nothing added", n_log) ~= nil,
    "its pickup destroyed meanwhile (UE4SS still calls it valid): nothing added, never twice")
outbox.host, outbox.client = {}, {}
local jug3b = game_add("DA_DirtyWaterJug", 1)
jug3b.__loc = { X = 0, Y = 0, Z = 0 }
deliver_host()
deliver()
check(server_count("DA_DirtyWaterJug") == 1, "a pickup reading 0,0,0 (destroyed): nothing added")
-- the character died before the answer: the pickup stays (its data is the death box's)
outbox.host, outbox.client = {}, {}
local jug3c = game_add("DA_DirtyWaterJug", 1)
deliver_host()
rpawn["PlayerDead?"] = true
deliver()
rpawn["PlayerDead?"] = nil
check(server_count("DA_DirtyWaterJug") == 1 and jug3c.__live ~= false and log_has("the character is dead", n_log) ~= nil,
    "the character dead before the answer: nothing added, the pickup stays")
-- another player's answer is not taken; the asked player's is
outbox.host, outbox.client = {}, {}
local jug4 = game_add("DA_DirtyWaterJug", 1)
deliver_host()
local mine = sent("WHEREIS")
CUR = "host"; WHO = "host"
handlers.host.WHEREIS({ mine[1], "c", gs(G_BP), "0" }, { __name = "PC_other", NetConnection = conn })
check(jug4.__live ~= false and server_count("DA_DirtyWaterJug") == 1, "another player's answer is not taken")
deliver()
check(jug4.__live == false and server_count("DA_DirtyWaterJug") == 2, "the asked player's answer is")
-- no answer in time: the pickup stays at the feet
n_log = #logs
outbox.host, outbox.client = {}, {}
local jug5 = game_add("DA_DirtyWaterJug", 1)
advance(HP.WAIT_S + 1)
HM.host_tick({ rpc })
outbox.host = {}
check(jug5.__live ~= false and server_count("DA_DirtyWaterJug") == 2 and log_has("no answer from its screen", n_log) ~= nil,
    "no answer: the pickup stays at the feet")
-- several grants in one moment all name the same grid; the second does not
-- fit there on the host: asked again a moment later, when the first shows
n_log = #logs
local G_P2 = newg()
local p2c = { [F.REP] = G_P2, [F.INC] = U_BP, [F.ITEMS] = arr({}), cap = 10, name = "pockets2" }
server[#server + 1] = p2c
local w_p2 = widget("Pockets2", G_P2, function() return true end)
table.insert(mycomp.LocalJSIContainers._t, 3, w_p2)   -- (after the backpack's widget)
server[4].cap = #server[4][F.ITEMS]._t + 1
w_bp.__cap = #w_bp.__slots + 1
outbox.host, outbox.client = {}, {}
local j6, j7 = game_add("DA_DirtyWaterJug", 1), game_add("DA_DirtyWaterJug", 1)
deliver_host()
local ans = {}
for _, m in ipairs(outbox.client) do if m.kind == "WHEREIS" then ans[#ans + 1] = m.f end end
check(#ans == 2 and ans[1][3] == gs(G_BP) and ans[2][3] == gs(G_BP), "(both answers name the backpack: the same moment)")
deliver()
check(j6.__live == false and j7.__live ~= false and #HP._t.Q.pend == 1 and HP._t.Q.pend[1].due ~= nil,
    "the first goes in; the second, full here, waits to be asked again")
client_apply()
advance(HP.REASK_S + 0.1)
HM.host_tick({ rpc })
deliver_host()
check(sent("WHEREIS") and sent("WHEREIS")[3] == gs(G_P2), "asked again: the client's screen names its other grid now")
deliver()
check(j7.__live == false and in_grid(p2c, "DA_DirtyWaterJug") ~= nil, "the second goes there")
check(log_has("asked again", n_log) ~= nil, "host log")
-- an IGAIN (a loot box of several items) the same way, its attachments kept
n_log = #logs
server[4].cap = #server[4][F.ITEMS]._t
outbox.host, outbox.client = {}, {}
host_use(G(794))
local augs0 = server_count("DA_SteyrAug")
handlers.host.IGAIN({ DA.DA_SteyrAug.__path, "1", "c", gs(G_BP), "0" }, rpc)
check(server_count("DA_SteyrAug") == augs0 and #HP._t.Q.pend == 1 and HP._t.Q.pend[1].atts == true,
    "a loot box item whose grid is full here: at the feet, asked again a moment later")
advance(HP.REASK_S + 0.1)
HM.host_tick({ rpc })
deliver_host()
deliver()
local aug2 = in_grid(p2c, "DA_SteyrAug")
local mag_in = false
for _, c in ipairs(server) do
    if aug2 and gs(c[F.REP]) == gs(aug2[F.SUBS]._t[4][F.SUB_ID]) and in_grid(c, "DA_556Mag") then mag_in = true end
end
check(aug2 ~= nil and mag_in, "then into the grid its screen names, with its default magazine")
server[4].cap = 80
w_bp.__cap = nil
client_apply()
-- asked again once only: the second answer full here too -> it stays, no third question
n_log = #logs
server[4].cap = #server[4][F.ITEMS]._t + 1
outbox.host, outbox.client = {}, {}
local j8, j9 = game_add("DA_DirtyWaterJug", 1), game_add("DA_DirtyWaterJug", 1)
deliver_host()
deliver()
check(j8.__live == false and j9.__live ~= false and #HP._t.Q.pend == 1, "(the second waits to be asked again)")
advance(HP.REASK_S + 0.1)
HM.host_tick({ rpc })
deliver_host()
check(sent("WHEREIS") and sent("WHEREIS")[3] == gs(G_BP), "(its screen names the backpack again)")
deliver()
outbox.host, outbox.client = {}, {}
advance(HP.REASK_S + 0.1)
HM.host_tick({ rpc })
advance(HP.WAIT_S + 1)
HM.host_tick({ rpc })
check(j9.__live ~= false and #HP._t.Q.pend == 0 and sent_host("WHERE") == nil and log_has("stays at its feet", n_log) ~= nil,
    "full here again: it stays at the feet, no third question")
server[4].cap = 80
check(ncalls("AddNewItemSomewhere") == a12 + 0, "the plugin's any-grid add never used")

end
print("== 13. items already hidden in the wallet / med bag / pouches: to the feet, nothing else touched")
do
n_log = #logs
-- (as 0.11.0 left them in the host's data: a Katana, a can and an empty
-- bottle in the wallet, a Katana in the med bag; money, a keycard,
-- bandages, cloth belong there; an item whose kind cannot be read is never
-- judged; a book in a briefcase, a battery in a toolbox, ammo in a vest pouch
-- belong there, a Katana in that pouch does not, its third grid takes all)
local k1 = server_item(DA.DA_Katana, 1, server[2])
local c1 = server_item(DA.DA_Can, 1, server[2])
local b1 = server_item(DA.DA_EmptyWaterBottle, 1, server[2])
server_item(DA.DA_Mystery, 1, server[2])
server_item(DA.DA_ResearchKeycard, 1, server[2])
local k2 = server_item(DA.DA_Katana, 1, server[3])
server_item(DA.DA_Cloth, 2, server[3])
local brief = server_item(DA.DA_Briefcase, 1, server[4])
local box = server_item(DA.DA_SmallToolbox, 1, server[4])
local vest = server_item(DA.DA_MilitaryPlateCarrier, 1, server[4])
local function sub(it, i) return grid_of(it[F.SUBS]._t[i][F.SUB_ID]) end
for _, c in ipairs({ sub(brief, 1), sub(box, 1), sub(vest, 1), sub(vest, 2), sub(vest, 3) }) do c.cap = 10 end
server_item(DA.DA_FirstAidBook, 1, sub(brief, 1))
local k5 = server_item(DA.DA_Katana, 1, sub(brief, 1))
server_item(DA.DA_Battery, 2, sub(box, 1))
local k6 = server_item(DA.DA_Katana, 1, sub(vest, 1))
server_item(DA.DA_556Ammo, 30, sub(vest, 2))
server_item(DA.DA_Katana, 1, sub(vest, 3))
local odd = server_item(DA.DA_OddBag, 1, server[4])
local k_odd = server_item(DA.DA_Katana, 1, sub(odd, 1))
local stay = {}
for _, c in ipairs({ server[2], server[3], sub(brief, 1), sub(box, 1), sub(vest, 2), sub(vest, 3), sub(odd, 1) }) do
    for _, it in ipairs(c[F.ITEMS]._t) do
        local nm = it[F.INFO][F.ID].__name
        if nm ~= "DA_Katana" and nm ~= "DA_Can" and nm ~= "DA_EmptyWaterBottle" then stay[#stay + 1] = it end
        if c == sub(vest, 3) or c == sub(odd, 1) then stay[#stay + 1] = it end
    end
end
local dr0 = ncalls("SERVER_RequestDropItem")
outbox.host = {}
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)   -- (the host's 1 s walk of that inventory)
local gone = 0
for _, it in ipairs({ k1, c1, b1, k2, k5, k6 }) do if find_server(gs(it[F.USID])) == nil then gone = gone + 1 end end
check(gone == 6 and ncalls("SERVER_RequestDropItem") == dr0 + 6,
    "dropped at the feet: the Katana, can and bottle in the wallet, the Katana in the med bag, in the briefcase, in a vest pouch")
local kept, kept_names = 0, {}
for _, it in ipairs(stay) do
    if find_server(gs(it[F.USID])) ~= nil then kept = kept + 1 else kept_names[#kept_names + 1] = it[F.INFO][F.ID].__name end
end
check(kept == #stay and #stay >= 9 and find_server(gs(k_odd[F.USID])) ~= nil,
    "money, keycard, bandages, cloth, book, battery, ammo, unknown kind, the vest's open grid, a window class the rules do not list: stay ("
    .. table.concat(kept_names, ",") .. ")")
check(#all_sent_host("IHID") == 6, "the player is told about each one (IHID)")
local ih = sent_host("IHID")
deliver_host()
check(ih and ih[3] ~= "" and ih[4] == "" and log_has("client say: place_hidden", n_log)
    and log_has("dropped at this player's feet", n_log), "the client shows it")
check(log_has("sat in its Wallet, whose window does not show it (inventory check): dropped at its feet", n_log) ~= nil, "host log")
-- nothing suspicious: the walk does not read the data again
local R = HP._t.R
local r0 = R.read_at[rcomp.__name]
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
check(r0 ~= nil and R.read_at[rcomp.__name] == r0, "nothing hidden: no further read of the data")
-- a container that came in since (a new briefcase: its grid not learned
-- yet) with a Katana inside: the walk learns it and the Katana goes
local brief2 = server_item(DA.DA_Briefcase, 1, server[4])
sub(brief2, 1).cap = 5
local k_new = server_item(DA.DA_Katana, 1, sub(brief2, 1))
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
check(find_server(gs(k_new[F.USID])) == nil, "a new container's grid is learned by the walk: its hidden Katana goes")
outbox.host = {}
-- an item with no pickup class: never dropped (it would only leave the data)
n_log = #logs
local np = server_item(DA.DA_NoPickup, 1, server[2])
dr0 = ncalls("SERVER_RequestDropItem")
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
check(find_server(gs(np[F.USID])) ~= nil and ncalls("SERVER_RequestDropItem") == dr0
    and log_has("NOT dropped: it has no pickup class", n_log) ~= nil, "no pickup class: not dropped, it stays")
local st13 = sent_host("IHID")
check(st13 and st13[1] == DA.DA_NoPickup.__path and st13[4] == "stuck", "the player is told it stays hidden there")
deliver_host()
check(log_has("client say: place_hidden_stuck", n_log) ~= nil, "the client shows it")
local r13 = HP._t.R.read_at[rcomp.__name]
advance(HP.AGAIN_S * 3)
HM.host_player(rpc)
check(HP._t.R.read_at[rcomp.__name] == r13 and sent_host("IHID") == nil,
    "never droppable: not tried, read for or told again (no toast every minute)")
-- a drop that gives no pickup: the item is gone - said so, not "at your feet"
n_log = #logs
local k7 = server_item(DA.DA_Katana, 1, server[2])
rpawn.__fail_jdrop = true
outbox.host = {}
advance(HP.AGAIN_S + 1)
HM.host_player(rpc)
rpawn.__fail_jdrop = nil
local ihl = sent_host("IHID")
check(find_server(gs(k7[F.USID])) == nil and ihl and ihl[4] == "lost" and log_has("LOST: out of its inventory, but no pickup of it came", n_log) ~= nil,
    "no pickup came: reported lost (IHID lost), never 'at your feet'")
deliver_host()
check(log_has("client say: place_hidden_lost", n_log) ~= nil, "the client shows the truth")
local k8 = server_item(DA.DA_Katana, 1, server[2])
dr0 = ncalls("SERVER_RequestDropItem")
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
check(find_server(gs(k8[F.USID])) ~= nil and ncalls("SERVER_RequestDropItem") == dr0, "that kind is not dropped again for a while")
advance(HP.NODROP_S + 1)
HM.host_player(rpc)
check(find_server(gs(k8[F.USID])) == nil, "later it is")
outbox.host = {}
-- a vest whose pickup class carries another data asset: any pickup that
-- drop made is the proof
n_log = #logs
local pc2 = server_item(DA.DA_MilitaryPlateCarrier2, 1, server[2])
outbox.host = {}
advance(HP.AGAIN_S + 1)
HM.host_player(rpc)
local ihv = sent_host("IHID")
check(find_server(gs(pc2[F.USID])) == nil and ihv and ihv[1] == DA.DA_MilitaryPlateCarrier2.__path and ihv[4] == ""
    and HP._t.R.nodrop.MilitaryPlateCarrier2 == nil, "a pickup of another data asset: dropped, not reported lost")
outbox.host = {}
-- the drop's own post-hook not in: a pickup cannot be proven - not "lost",
-- not marked, the player not told "at your feet" either
n_log = #logs
local k10b = server_item(DA.DA_Katana, 1, server[2])
local nd_k = HP._t.R.nodrop.Katana
HP.drop_hook = false
outbox.host = {}
check(HP.rescue(rpawn, "inventory check") == 1 and find_server(gs(k10b[F.USID])) == nil, "(dropped)")
HP.drop_hook = true
check(sent_host("IHID") == nil and HP._t.R.nodrop.Katana == nd_k
    and log_has("its pickup not confirmed: the player is not told", n_log) ~= nil, "no proof either way: no claim, no mark")
-- a drop that does not happen at all: tried once in AGAIN_S, then again
n_log = #logs
local k3 = server_item(DA.DA_Katana, 1, server[2])
rcomp.__fail_drop = true
dr0 = ncalls("SERVER_RequestDropItem")
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
advance(HP.SCAN_EVERY + 1)
HM.host_player(rpc)
check(ncalls("SERVER_RequestDropItem") == dr0 + 1 and log_has("NOT dropped (still in its inventory)", n_log) ~= nil,
    "a refused drop: tried once in " .. HP.AGAIN_S .. " s")
advance(HP.AGAIN_S + 1)
HM.host_player(rpc)
advance(HP.AGAIN_S + 1)
HM.host_player(rpc)
local stuck3 = 0
for _, m in ipairs(outbox.host) do
    if m.kind == "IHID" and m.f[4] == "stuck" and m.f[1] == DA.DA_Katana.__path then stuck3 = stuck3 + 1 end
end
check(ncalls("SERVER_RequestDropItem") == dr0 + 3 and stuck3 == 1,
    "tried again every " .. HP.AGAIN_S .. " s, the player told it is stuck once (" .. stuck3 .. ")")
outbox.host = {}
rcomp.__fail_drop = nil
advance(HP.AGAIN_S + 1)
HM.host_player(rpc)
check(ncalls("SERVER_RequestDropItem") == dr0 + 4 and find_server(gs(k3[F.USID])) == nil, "later tried again (dropped)")
-- a load of that player's inventory (the persist restore, the client's own
-- load): at once, the pickups where it stood then
n_log = #logs
local k4 = server_item(DA.DA_Katana, 1, server[3])
outbox.host = {}
CFG.refused_items_to_feet = false
fire("host", JIG .. "SERVER_RequestDataFromSave", C(rcomp), P(rcomp))
check(find_server(gs(k4[F.USID])) ~= nil, "refused_items_to_feet off: nothing moved")
CFG.refused_items_to_feet = nil
HP.loading = true   -- (inside sdc_persist's own load: it rescues after its count check)
fire("host", JIG .. "SERVER_RequestDataFromSave", C(rcomp), P(rcomp))
HP.loading = false
check(find_server(gs(k4[F.USID])) ~= nil, "inside sdc_persist's own load: nothing moved before its check")
fire("host", JIG .. "SERVER_RequestDataFromSave", C(rcomp), P(rcomp))
local ihd = sent_host("IHID")
check(find_server(gs(k4[F.USID])) == nil and ihd and ihd[4] == "load",
    "the client's own load (SERVER_RequestDataFromSave): moved in that call, told where (the load spot)")
deliver_host()
check(log_has("client say: place_hidden_load", n_log) ~= nil, "the client's text says where it lies")
-- one try per item in AGAIN_S, also when asked directly (sdc_persist)
local k9 = server_item(DA.DA_Katana, 1, server[2])
rcomp.__fail_drop = true
dr0 = ncalls("SERVER_RequestDropItem")
HP.rescue(rpawn, "restore")
HP.rescue(rpawn, "restore")
check(ncalls("SERVER_RequestDropItem") == dr0 + 1 and find_server(gs(k9[F.USID])) ~= nil, "asked twice at once: one try")
rcomp.__fail_drop = nil
-- the host's own inventory is never touched (its own windows show it); a dead character's neither
local hown = { __name = "BP_PlayerCharacter_C_host2", __cls = "BP_PlayerCharacter_C", Controller = { __name = "PC_h" },
               BP_JigMultiplayer = rcomp }
advance(HP.AGAIN_S + 1)
dr0 = ncalls("SERVER_RequestDropItem")
check(HP.rescue(hown, "restore") == 0 and ncalls("SERVER_RequestDropItem") == dr0 and find_server(gs(k9[F.USID])) ~= nil,
    "the host's own character: nothing")
rpawn["PlayerDead?"] = true
check(HP.rescue(rpawn, "restore") == 0 and find_server(gs(k9[F.USID])) ~= nil, "a dead character: nothing (its data is its box's)")
rpawn["PlayerDead?"] = nil
check(HP.rescue(rpawn, "restore") == 1 and find_server(gs(k9[F.USID])) == nil, "(that Katana: the remote player's, dropped)")
outbox.host = {}

end
print("== 14. the rules are the game's widget data")
do
-- generated from the game's SC_*.uasset/.uexp (0.8.0, repak + UAssetGUI):
-- window class -> { [grid index (AllContainers order)] = its lists }
local WIDGETS = {
    SC_AmmoTin_C = { [1] = { Also = { "MakeshiftWeaponCleaningKit", "WeaponCleaningKit", "Gunpowder", "BulletCasing", "ShellCasing", "LandMine" },
                             Types = { "Ammunition", "WeaponAttachment", "Throwable", "EquipmentAttachment" } } },
    SC_Briefcase_C = { [1] = { Also = { "FirstAidBook", "FishingBook", "FitnessBook", "MarksmanshipBook", "ReloadingBook", "ScavengingBook",
                                        "SneakingBook", "StrengthBook", "ThiefBook", "ToughnessBook", "FirstAidMagazine", "FishingMagazine",
                                        "FitnessMagazine", "MarksmanshipMagazine", "ReloadingMagazine", "ScavengingMagazine", "SneakingMagazine",
                                        "StrengthMagazine", "ThiefMagazine", "ToughnessMagazine" },
                               Types = { "Currency", "Keycard" } } },
    SC_LargeToolbox_C = { [1] = { Also = { "Battery", "Saw", "Hammer", "Can", "Can2" }, Types = { "Material", "Tool" } } },
    SC_LunchBox_C = { [1] = { Also = { "CanOpener", "EmptyWaterBottle", "EmptyWaterCanteen", "EmptyWaterJug", "PlasticBottle",
                                       "WaterPurificationTablets", "Pot" },
                              Types = { "FoodConsumable", "DrinkConsumable" } } },
    SC_MedicalBag_C = { [1] = { Also = { "BottleOfAntiseptic", "Cloth", "WaterPurificationTablets", "CharcoalTablets", "RadiationFilter",
                                         "InfestationSample" },
                                Types = { "MedicalConsumable" } } },
    SC_SmallToolbox_C = { [1] = { Also = { "Battery", "Saw", "Hammer", "Can", "Can2" }, Types = { "Material", "Tool" } } },
    SC_Wallet_C = { [1] = { Types = { "Currency", "Keycard" } } },
    SC_WeaponsCase_C = { [1] = { Types = { "WeaponAttachment", "Throwable", "Sidearm", "MainFirearm", "Melee", "Ammunition",
                                           "EquipmentAttachment" } } },
    SC_Battery_C = { [1] = { Only = { "Battery" } } },
    SC_GhillieBodyArmor_C = { [1] = { Types = { "Ammunition", "WeaponAttachment" } }, [2] = { Types = { "Ammunition", "WeaponAttachment" } } },
    SC_MilitaryPlateCarrier_C = { [1] = { Types = { "Ammunition", "WeaponAttachment" } }, [2] = { Types = { "Ammunition", "WeaponAttachment" } } },
    SC_NVG_C = { [1] = { Only = { "SpecOpsNVG", "CivilianNVG", "MilitaryNVG" }, Types = { "EquipmentAttachment" } } },
    SC_Respirator_C = { [1] = { Only = { "RadiationFilter" } } },
    SC_SpecOpsPlateCarrier_C = { [1] = { Types = { "Ammunition", "WeaponAttachment" } }, [2] = { Types = { "Ammunition", "WeaponAttachment" } } },
}
local function same_set(a, list, prefix)
    local want = {}
    for _, v in ipairs(list or {}) do want[(prefix or "") .. v] = true end
    for k in pairs(a or {}) do if not want[k] then return false end end
    for k in pairs(want) do if not (a or {})[k] then return false end end
    return true
end
local mism = {}
for cls, grids in pairs(WIDGETS) do
    local r = HP.RULES[cls]
    if not r then mism[#mism + 1] = cls .. " missing" end
    for i, gw in pairs(grids) do
        local gr = r and r[i]
        if not gr or not same_set(gr.types, gw.Types, "Jig.ItemType.") or not same_set(gr.also, gw.Also)
            or not same_set(gr.only, gw.Only) then
            mism[#mism + 1] = cls .. "[" .. i .. "]"
        end
    end
end
for cls, grids in pairs(HP.RULES) do
    for i in pairs(grids) do
        if not (WIDGETS[cls] and WIDGETS[cls][i]) then mism[#mism + 1] = cls .. "[" .. i .. "] not in the game's data" end
    end
end
check(#mism == 0, "RULES = the game's widget data, list for list (" .. table.concat(mism, ", ") .. ")")
local W, MB = HP.RULES.SC_Wallet_C[1], HP.RULES.SC_MedicalBag_C[1]
check(HP.refuses(W, "ResearchKeycard", "Jig.ItemType.Keycard") == false and HP.refuses(W, "Money", "Jig.ItemType.Currency") == false
    and HP.refuses(W, "Katana", "Jig.ItemType.Melee") == true and HP.refuses(W, "Can", "Jig.ItemType.Other") == true,
    "wallet: money and keycards stay, a Katana or a can does not")
check(HP.refuses(MB, "Cloth", "Jig.ItemType.Material") == false and HP.refuses(MB, "Bandages", "Jig.ItemType.MedicalConsumable") == false
    and HP.refuses(MB, "Rock", "Jig.ItemType.Material") == true and HP.refuses(MB, "Rock", nil) == nil,
    "med bag: cloth (its list) and medicine stay, rocks do not; an unread kind is not judged")
check(HP.refuses(HP.RULES.SC_Briefcase_C[1], "ThiefBook", "Jig.ItemType.Other") == false
    and HP.refuses(HP.RULES.SC_SmallToolbox_C[1], "Battery", "Jig.ItemType.Other") == false
    and HP.refuses(HP.RULES.SC_Battery_C[1], "Battery", nil) == false and HP.refuses(HP.RULES.SC_Battery_C[1], "Can", nil) == true
    and HP.refuses(HP.RULES.SC_NVG_C[1], "MilitaryNVG", "Jig.ItemType.EquipmentAttachment") == false
    and HP.refuses(HP.RULES.SC_NVG_C[1], "Flashlight", "Jig.ItemType.EquipmentAttachment") == true,
    "briefcase books, toolbox batteries, the battery / NVG slots' own lists")

end
print("== 15. the module's drops are marked for sdc_world's grant hook")
do
local seen_r, unmarked = 0, 0
for _, c in ipairs(calls) do
    if c[1] == "SERVER_RequestDropItem" and c[4] ~= nil then
        seen_r = seen_r + 1
        if c[4] ~= true then unmarked = unmarked + 1 end
    end
end
check(seen_r >= 8 and unmarked == 0, "the rescue's drop requests are marked (" .. seen_r .. ")")
-- IGLOST
CUR = "host"; WHO = "host"
local kl = server_item(DA.DA_Katana, 1, server[2])
advance(10)
handlers.host.IGLOST({ gs(kl[F.USID]) }, rpc)
local lc = last_call("SERVER_RequestDropItem")
check(lc and lc[2] == gs(kl[F.USID]) and lc[4] == true and find_server(gs(kl[F.USID])) == nil and HP.dropping == false,
    "IGLOST's drop request is marked")
-- GAIN.drop_at (an IGAIN with no room on that screen)
host_use(G(795))
CUR = "host"; WHO = "host"
handlers.host.IGAIN({ DA.DA_Cloth.__path, "1", "n", "", "" }, rpc)
local jd = last_call("JigMP_OnRequestDropItem")
check(jd and jd[2] == "DA_Cloth" and jd[5] == true and HP.dropping == false, "a gain's drop at the feet is marked, the mark cleared after")
-- IGLOST: an item with no pickup class is not dropped (it would only leave the data)
local npl = server_item(DA.DA_NoPickup, 1, server[3])
local dl0 = ncalls("SERVER_RequestDropItem")
handlers.host.IGLOST({ gs(npl[F.USID]) }, rpc)
check(ncalls("SERVER_RequestDropItem") == dl0 and find_server(gs(npl[F.USID])) ~= nil, "IGLOST: no pickup class, not dropped")
local st15 = sent_host("IHID")
check(st15 and st15[1] == DA.DA_NoPickup.__path and st15[3] == DA.DA_MedBag.__path and st15[4] == "stuck",
    "IGLOST: the player is told it stays hidden")
-- IGLOST: a refused drop (still in the inventory) -> told it is stuck
local kst = server_item(DA.DA_Katana, 1, server[3])
rcomp.__fail_drop = true
outbox.host = {}
handlers.host.IGLOST({ gs(kst[F.USID]) }, rpc)
rcomp.__fail_drop = nil
local stg = sent_host("IHID")
check(find_server(gs(kst[F.USID])) ~= nil and stg and stg[4] == "stuck" and stg[1] == DA.DA_Katana.__path,
    "IGLOST: a refused drop, the player told it stays hidden")
-- IGLOST: a drop that gives no pickup is said to be a loss
n_log = #logs
local kl2 = server_item(DA.DA_Katana, 1, server[3])
rpawn.__fail_jdrop = true
handlers.host.IGLOST({ gs(kl2[F.USID]) }, rpc)
rpawn.__fail_jdrop = nil
check(log_has("LOST - out of their inventory, but no pickup of it came", n_log) ~= nil, "IGLOST: no pickup came, said so")
local lo15 = sent_host("IHID")
check(lo15 and lo15[1] == DA.DA_Katana.__path and lo15[4] == "lost", "IGLOST: the player is told it is gone")

end
for _, l in ipairs(logs) do
    -- (the losses sections 13 / 15 provoke are errors on purpose)
    if l:find(" err", 1, true) and l:find("consume", 1, true) and not l:find("LOST", 1, true) then
        check(false, "no error logged: " .. l)
    end
end
print(string.format("mock_consume_lootbox: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
