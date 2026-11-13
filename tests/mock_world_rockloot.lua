-- Rock / wood / scrap for a client (2026-11-13, 0.10.0 report: a client broke
-- a rock, it vanished for both, the stones never showed in its inventory).
-- The host's add for a remote player (the plugin's AddNewItemSomewhere) took
-- the first grid of the server data with room - a med bag in a backpack
-- pocket - whose WIDGET on the client takes medical items only: the client
-- refused CLIENT_AddNewItem, every later rock was counted onto that unseen
-- stack, and the game's note said "Rocks dropped on ground".
-- Fixed in sdc_world: the client's own copy of the object runs the grant
-- first; where its screen puts it (JigTryAddGetPendingRef) goes to the host
-- (WSPOT) and the host adds there; no room -> the game's drop stays; the
-- game's Added? answer and its note follow what happened.
-- Review round (same day): the count-up of a stack had a third argument
-- UE4SS refuses (the plugin calls here take exactly their parameters now,
-- as UE4SS checks); the client's word often comes a moment AFTER the host's
-- grant (the host's replay of the swing fells it; trees grant 0.2 s after
-- the fall on both machines) - the grant waits for it (13-17); words queue
-- per item (18); salvaged scrap with no room on that screen drops at the
-- player's feet, not into any grid (20).
-- Runs the real sdc_world / sdc_net / sdc_ctx / sdc_ue against fake objects
-- (a host world and a client world), a model of the plugin's server data and
-- of the client's widgets (the med bag widget refuses a rock).
-- usage: lua mock_world_rockloot.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD
local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- fake objects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    return rawget(t, "_m")[k]
end
local next_addr = 4096
local LVL = "/Game/Levels/LongdownValley.LongdownValley:PersistentLevel."
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _calls = {} }, Obj)
    o._full = chain[1] .. " " .. (path or (LVL .. name))
    w.objects[#w.objects + 1] = o
    w.paths[path or (LVL .. name)] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:K2_DestroyActor() self._valid = false end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end
local function ncalls(o, name)
    local n = 0
    for _, c in ipairs(o._calls) do if c[1] == name then n = n + 1 end end
    return n
end
-- a UFunction as UE4SS 3.0.1 calls it: exactly its number of parameters
-- (LuaUObject.cpp __call: "UFunction expected N parameters, received M")
local function strict(np, fn)
    return function(self, ...)
        local got = select("#", ...)
        if got ~= np then
            error(string.format("[UFunction::setup_metamethods -> __call] UFunction expected %d parameters, received %d", np, got))
        end
        return fn(self, ...)
    end
end
-- a TArray as UE4SS gives it: ForEach(i, element with :get())
local function arr(t)
    return { _t = t, ForEach = function(self, fn)
        for i, v in ipairs(self._t) do fn(i, { get = function() return v end }) end
    end }
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v)
    local p = { _v = function() return v end }
    function p.get() return v end
    function p.set(_, nv) v = nv end
    return p
end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], a)
    return 1, 2
end
NotifyOnNewObject = function() end
StaticFindObject = function(path)
    local o = WORLD.paths[path]
    if o and o._valid then return o end
    return nil
end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(WORLD.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(_, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local function run_timers(w)
    WORLD = w
    for _ = 1, 3 do
        local t = w.timers
        w.timers = {}
        for _, fn in ipairs(t) do fn() end
    end
end
local function fire(w, path, ...)
    WORLD = w
    for _, h in ipairs(w.hooks[path] or {}) do assert(h(...) == nil, "hook returned a value: " .. path) end
end

-- ---------------------------------------------------------------- worlds
local function world(id) return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} } end
local HW, CW = world("host"), world("client")
local RES = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/"
local function engine(w, is_server)
    WORLD = w
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, _, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        GetCurrentLevelName = function() return "LongdownValley" end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
    w.da = {}
    for _, d in ipairs({ { "DA_Rock", 50 }, { "DA_WoodenLog", 30 }, { "DA_ScrapMetal", 100 }, { "DA_Cloth", 10 },
                         { "DA_LargeBlackMilitaryBackpack", 1 }, { "DA_MedBag", 1 } }) do
        w.da[d[1]] = new(w, { "JigsawItem_DataAsset_C" }, d[1], { MaxStack = d[2] }, {}, RES .. d[1] .. "." .. d[1])
    end
end
engine(HW, true)
engine(CW, false)

local function players(w)
    WORLD = w
    local jig = new(w, { "BP_JigComponent_C" }, "BP_JigMultiplayer_0", {}, {})
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true, BP_JigMultiplayer = jig })
    jig._p._owner = pawn
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn, w.jig = pc, pawn, jig
end
players(HW)
players(CW)

-- ---------------------------------------------------------------- the plugin's server data (host)
local F = {
    ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    REP = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332",
    INC = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF",
    USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD",
    MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D",
    ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
}
local ZERO = { A = 0, B = 0, C = 0, D = 0 }
local guid_n = 1000
local function G(a) return { A = a, B = -7, C = 3, D = -1714241284 } end
local function gs(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end
local function newg() guid_n = guid_n + 1; return G(guid_n) end

-- grids in the order the server data has them: the top grid (full), the med
-- bag inside the backpack (listed before the backpack's own grid), the backpack
local BACKPACK, MEDBAG = G(11), G(12)
local G_TOP, G_MED, G_BP = G(21), G(22), G(23)
local server = {
    { [F.REP] = G_TOP, [F.INC] = ZERO, [F.ITEMS] = arr({}), full = true, name = "top" },
    { [F.REP] = G_MED, [F.INC] = MEDBAG, [F.ITEMS] = arr({}), name = "medbag" },
    { [F.REP] = G_BP, [F.INC] = BACKPACK, [F.ITEMS] = arr({}), name = "backpack" },
}
local function item(da, n, grid, slot, u)
    return { [F.USID] = u or newg(), [F.INFO] = { [F.ID] = da, [F.COUNT] = n }, [F.SLOT] = slot, [F.MOTHER] = grid }
end
-- the backpack and the med bag themselves (items of the top grid)
table.insert(server[1][F.ITEMS]._t, item(HW.da.DA_LargeBlackMilitaryBackpack, 1, G_TOP, 0, BACKPACK))
table.insert(server[1][F.ITEMS]._t, item(HW.da.DA_MedBag, 1, G_TOP, 1, MEDBAG))
local function grid_of(u)
    for _, c in ipairs(server) do if gs(c[F.REP]) == gs(u) then return c end end
    return nil
end
local function all_items()
    local out = {}
    for _, c in ipairs(server) do
        for _, it in ipairs(c[F.ITEMS]._t) do out[#out + 1] = { it = it, grid = c } end
    end
    return out
end
local function rocks_on_host()
    local list, total = {}, 0
    for _, e in ipairs(all_items()) do
        if e.it[F.INFO][F.ID]._name == "DA_Rock" then list[#list + 1] = e; total = total + e.it[F.INFO][F.COUNT] end
    end
    return list, total
end
local function add_new(c, da, n)
    local it = item(da, n, c[F.REP], #c[F.ITEMS]._t)
    table.insert(c[F.ITEMS]._t, it)
    return it
end

-- the client's widgets: the med bag's takes medical items only (SC_MedicalBag)
WORLD = CW
local function widget(name, guid, accepts)
    return new(CW, { "JSIContainer_C" }, "JSIContainer_" .. name, { ContainerID = guid, ContainerName = name,
        ArrayOfItems = arr({}) }, {}), accepts
end
local w_top = widget("Pockets", G_TOP)
local w_med = widget("MedBag", G_MED)
local w_bp = widget("Backpack", G_BP)
local W = { [gs(G_TOP)] = w_top, [gs(G_MED)] = w_med, [gs(G_BP)] = w_bp }
CW.jig._p.LocalJSIContainers = arr({ w_top, w_bp, w_med })
local function slot_widget(w, idx, u, n)
    return new(CW, { "JSI_Slot_C" }, "JSI_Slot_" .. idx, { ContainerMother = w, SlotIndex = idx, ItemUniqueID = u,
        ItemCount = n })
end
local function client_rocks()
    local list, total = {}, 0
    for _, w in ipairs({ w_top, w_bp, w_med }) do
        for _, s in ipairs(w._p.ArrayOfItems._t) do
            if s._p._name == "DA_Rock" then list[#list + 1] = { s = s, w = w }; total = total + s._p.ItemCount end
        end
    end
    return list, total
end

-- the host's RPCs to the client, applied as the client's game does
local to_client = {}
local function client_apply()
    local q = to_client
    to_client = {}
    for _, r in ipairs(q) do
        if r.kind == "add" then
            local it = r.item
            local w = W[gs(it[F.MOTHER])]
            local name = it[F.INFO][F.ID]._name
            -- HandleAddNewItem: the grid's widget refuses what it does not take
            if w and not (w == w_med and name ~= "DA_Bandage") then
                table.insert(w._p.ArrayOfItems._t, slot_widget(w, it[F.SLOT], it[F.USID], it[F.INFO][F.COUNT]))
                w._p.ArrayOfItems._t[#w._p.ArrayOfItems._t]._p._name = name
            end
            fire(CW, "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:CLIENT_AddNewItem",
                param(CW.jig), param({ [F.USID] = it[F.USID], [F.INFO] = { [F.ID] = CW.da[name], [F.COUNT] = it[F.INFO][F.COUNT] } }),
                param({}), param(r.comp == "own" and CW.jig or w_top), param(ZERO))
        elseif r.kind == "count" then
            for _, w in ipairs({ w_top, w_bp, w_med }) do
                for _, s in ipairs(w._p.ArrayOfItems._t) do
                    if gs(s._p.ItemUniqueID) == gs(r.uid) then s._p.ItemCount = r.n end
                end
            end
            fire(CW, "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:CLIENT_UpdateCount",
                param(CW.jig), param(CW.jig), param(r.uid), param(r.n), param(ZERO))
        elseif r.kind == "counts" then
            for _, c in ipairs(r.list) do
                for _, w in ipairs({ w_top, w_bp, w_med }) do
                    for _, s in ipairs(w._p.ArrayOfItems._t) do
                        if gs(s._p.ItemUniqueID) == gs(c.uid) then s._p.ItemCount = c.n end
                    end
                end
            end
        end
    end
end

-- the remote player's controller, character and component on the host
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rjig
rjig = new(HW, { "BP_JigComponent_C" }, "BP_JigMultiplayer_1", {}, {
    MainJigContainers = arr(server),
    -- the plugin's add: a stack with room anywhere, else the first grid with room
    -- (no widget check: the med bag takes anything here)
    AddNewItemSomewhere = strict(10, function(self, da, n, _, _, drop_if_failed, _, added, dropped, uid, to)
        self._calls[#self._calls + 1] = { "AddNewItemSomewhere", da._name, n }
        for _, e in ipairs(all_items()) do
            local info = e.it[F.INFO]
            if info[F.ID] == da and info[F.COUNT] + n <= da._p.MaxStack then
                info[F.COUNT] = info[F.COUNT] + n
                to_client[#to_client + 1] = { kind = "counts", list = { { uid = e.it[F.USID], n = info[F.COUNT] } } }
                added.Added, dropped["Dropped?"] = true, false
                for k, v in pairs(ZERO) do uid[k] = v; to[k] = v end
                return
            end
        end
        for _, c in ipairs(server) do
            if not c.full then
                local it = add_new(c, da, n)
                to_client[#to_client + 1] = { kind = "add", item = it, comp = "own" }
                added.Added, dropped["Dropped?"] = true, false
                for k, v in pairs(it[F.USID]) do uid[k] = v end
                for k, v in pairs(c[F.REP]) do to[k] = v end
                return
            end
        end
        added.Added, dropped["Dropped?"] = false, drop_if_failed == true
    end),
    -- the plugin's add into one grid (TryAddNewItem, first free slot)
    Generate_AddNewItemToContainer = strict(5, function(self, g, da, n, info, res)
        self._calls[#self._calls + 1] = { "Generate_AddNewItemToContainer", gs(g), da._name, n }
        local c = grid_of(g)
        if not c or c.full then res["Added?"] = false return end
        local it = add_new(c, da, n)
        for k, v in pairs(it) do info[k] = v end
        res["Added?"] = true
    end),
    -- ItemUID, NewCount (OldCount is a local of the function, no parameter)
    ServerUpdateCountByUID = strict(2, function(self, g, nc)
        self._calls[#self._calls + 1] = { "ServerUpdateCountByUID", gs(g), nc }
        if self._fail_count then self._fail_count = nil; error("count change failed (test)") end
        for _, e in ipairs(all_items()) do
            if gs(e.it[F.USID]) == gs(g) then e.it[F.INFO][F.COUNT] = nc end
        end
    end),
    CLIENT_AddNewItem = strict(4, function(self, it, content, comp, pending)
        self._calls[#self._calls + 1] = { "CLIENT_AddNewItem", gs(it[F.USID]) }
        assert(comp == rjig and gs(pending) == "0:0:0:0" and type(content) == "table")
        to_client[#to_client + 1] = { kind = "add", item = it, comp = "own" }
    end),
    CLIENT_UpdateCount = strict(4, function(self, target, g, nc, pending)
        self._calls[#self._calls + 1] = { "CLIENT_UpdateCount", gs(g), nc }
        assert(target == rjig and gs(pending) == "0:0:0:0")
        to_client[#to_client + 1] = { kind = "count", uid = g, n = nc }
    end),
})
-- the game's drop at the character (BP_JigHelperComp.RequestDropAsPickup):
-- a pickup at its feet; called from Lua it runs the hooks on it too
local drops_n = 0
local rpawn
rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1",
    { _loc = { X = 5000, Y = 0, Z = 0 }, BP_JigMultiplayer = rjig }, {
    JigMP_OnRequestDropItem = strict(3, function(self, info, cname, out)
        self._calls[#self._calls + 1] = { "JigMP_OnRequestDropItem", info[F.ID]._name, info[F.COUNT] }
        assert(info[F.ID] ~= nil and info[F.COUNT] ~= nil and info["Pending?_31_C3AE39044666796C0FA128BA521590CB"] == -1)
        if self._fail_drop then out.ActorRef = nil return end
        drops_n = drops_n + 1
        local pk
        -- (the plugin's own drop sets the count after it: SetPickupCount)
        pk = new(HW, { "BP_StaticMeshPickup_C" }, "BP_StaticMeshPickup_C_own" .. drops_n, { _count = 1,
            _da = info[F.ID] }, {
            SetPickupCount = strict(2, function(s, cnt, res) s._p._count = cnt; res.Result = true end),
        })
        out.ActorRef = pk
        local hooks = HW.hooks["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:JigMP_OnRequestDropItem"] or {}
        local function pm(v) return { get = function() return v end, set = function() end } end
        for _, h in ipairs(hooks) do h(pm(self), pm(info), pm(cname), pm(pk)) end
    end),
})
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, { ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end })
rpawn._p.Controller = rpc
rjig._p._owner = rpawn
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- load modules per world
local logs = {}
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if w.cfg and w.cfg[k] ~= nil then return w.cfg[k] end
        return get0(k, ...)
    end
    for _, lv in ipairs({ "info", "warn", "debug" }) do
        m.log[lv] = function(fmt, ...)
            local ok, s = pcall(string.format, fmt, ...)
            logs[#logs + 1] = w.id .. " " .. lv .. ": " .. (ok and s or tostring(fmt))
        end
    end
    m.log.err_throttled = function(_, fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        logs[#logs + 1] = w.id .. " ERR: " .. (ok and s or tostring(fmt))
    end
    m.net.install_hooks()
    m.world = require("sdc_world")
    return m
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
-- sdc_place (no usable word: the drop waits at the feet and that client's
-- screen is asked where it goes, WHERE): a spy here - mock_place runs the
-- real one end to end
local asked = {}
package.loaded["sdc_place"] = { ask = function(p, d, n, dp, why)
    asked[#asked + 1] = { pawn = p, da = d, n = n, drop = dp, why = why }
    return true
end, live = function(a)
    -- (the engine's view: a destroyed actor stays valid for UE4SS until the
    -- garbage collector - _gone here)
    return a._valid ~= false and not a._gone
end }

local function deliver()
    for _ = 1, 4 do
        local out = HW.outbox
        HW.outbox = {}
        WORLD = CW
        for _, msg in ipairs(out) do
            local kind, f = C.net.decode(msg)
            local h = C.net.handlers[kind]
            if h then h(f, CW.pc) end
        end
        out = CW.outbox
        CW.outbox = {}
        WORLD = HW
        for _, msg in ipairs(out) do
            local kind, f = H.net.decode(msg)
            local h = H.net.handlers[kind]
            if h then h(f, rpc) end
        end
    end
end
local function log_has(pat, from)
    for i = (from or 0) + 1, #logs do if logs[i]:find(pat, 1, true) then return logs[i] end end
    return nil
end

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local DROP = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:JigMP_OnRequestDropItem"

-- The client's own copy of a rock (or a scrap pile) grants on that machine:
-- JigTryAddItemSomewhere -> JigTryAddGetPendingRef picks the slot its widgets
-- take (slot), the stack it would grow (stack = true) or none (nil).
local function client_local_add(name, n, slot, stack, comp)
    comp = comp or CW.jig
    local da = CW.da[name]
    fire(CW, JIG .. "JigTryAddGetPendingRef", param(comp), param({ [F.ID] = da, [F.COUNT] = n }), param(true),
        param(slot), param(stack == true))
    fire(CW, JIG .. "JigTryAddItemSomewhere", param(comp), param(comp), param(da), param(n), param(false), param(ZERO))
end

-- The host's rock grant for the player who felled it (HitHarvestableObject
-- @725-1436): GetPlayerCharacter(self, 0) (sdc_ctx -> the scope resolver),
-- its JigTryAddItemSomewhere: no widget for a remote player -> its drop at
-- the player's feet (JigMP_OnRequestDropItem, Added? = false); the note by
-- Added?. Returns { added = Added?, note = text, drop = the pickup }.
local rock_n = 0
local function host_grant(name, n, hitter_pc)
    WORLD = HW
    rock_n = rock_n + 1
    local cls = name == "DA_Rock" and "BP_HarvestableObject_Rocks_C" or "BP_HarvestableObject_Tree_C"
    local rock = new(HW, { cls, "BP_HarvestableObject_C" }, cls .. "_" .. rock_n, { MaxHits = 0, _loc = { X = rock_n * 1000, Y = 0, Z = 0 } })
    local hits = H.world._t.hitters()
    hits[rock._addr] = { name = rock._name, pc = hitter_pc, t = T }
    local who = H.world.resolver(rock)
    local pawn = who and who._p.Pawn or HW.pawn
    local comp = pawn._p.BP_JigMultiplayer
    local added = param(false)
    local drop = nil
    if who then
        drop = new(HW, { "BP_RockPickup_C" }, "BP_RockPickup_C_" .. rock_n, {})
        fire(HW, DROP, param(pawn), param({ [F.ID] = HW.da[name], [F.COUNT] = n }), param("None"), param(drop))
    else
        added = param(true)   -- the host's own: its widgets took it (single player)
    end
    fire(HW, JIG .. "JigTryAddItemSomewhere", param(comp), param(comp), param(HW.da[name]), param(n), added, param(ZERO))
    run_timers(HW)
    local word = name == "DA_Rock" and "Rocks" or "Wood"
    return { added = added.get(), note = added.get() and (word .. " added to inventory") or (word .. " dropped on ground"),
             drop = drop }
end
local HV = H.world._t.harvest
-- the host's ticks after the wait for a word (SPOT_WAIT) ran out
local function settle()
    advance(HV.SPOT_WAIT + 0.1)
    WORLD = HW
    HV.pend_pass(T)
end
-- the module's grant counters as sdc_consume reads them (per call of the game's add)
local function world_drops() return H.world.stats.grants + H.world.stats.grant_drops end

-- =====================================================================
print("== 0. the message")
check(H.net.NOW.WSPOT == true, "WSPOT is sent past the send queue (as WHHIT, which fells the rock after it)")
check(H.net.handlers.WSPOT ~= nil, "the host handles WSPOT")
local nh = 0
for _ in pairs(HW.hooks) do nh = nh + 1 end
check(HW.hooks[JIG .. "JigTryAddGetPendingRef"] ~= nil and HW.hooks[JIG .. "CLIENT_AddNewItem"] ~= nil
    and HW.hooks[JIG .. "CLIENT_UpdateCount"] ~= nil, "hooks registered (" .. nh .. ")")

print("== 1. the client breaks a rock: a new stack where its screen put it")
local n_log = #logs
client_local_add("DA_Rock", 12, slot_widget(w_bp, 0, ZERO, 12), false)
check(#CW.outbox == 1 and CW.outbox[1]:find("WSPOT|DA_Rock|c|" .. gs(G_BP), 1, true) ~= nil,
    "client: its screen's grid sent (" .. tostring(CW.outbox[1]) .. ")")
check(log_has("client info: world: DA_Rock x12 added here by the game: this screen puts it in Backpack slot 0; the host is told", n_log) ~= nil,
    "client: logged where its screen puts it")
deliver()
local r1 = host_grant("DA_Rock", 11, rpc)
local list, total = rocks_on_host()
check(#list == 1 and total == 11 and list[1].grid.name == "backpack",
    "host: Rock x11 in the backpack grid the client's screen named, not the med bag (" .. #list .. " stack(s), " .. total .. ")")
check(ncalls(rjig, "AddNewItemSomewhere") == 0, "host: the plugin's any-grid add not used")
check(ncalls(rjig, "CLIENT_AddNewItem") == 1, "host: the client told once (CLIENT_AddNewItem)")
check(r1.drop._valid == false, "host: the game's drop at its feet removed")
check(r1.added == true and r1.note == "Rocks added to inventory", "the game's answer Added? = true: its note '" .. r1.note .. "'")
check(log_has("host info: world: DA_Rock x11 for BP_PlayerCharacter_C_1 went to its inventory where its screen put it: new stack", n_log) ~= nil
    and log_has("in DA_LargeBlackMilitaryBackpack slot 0, the client was told (CLIENT_AddNewItem)", n_log) ~= nil,
    "host: logged where it went")
check(H.world.stats.grants == 1 and H.world.stats.grant_drops == 0, "host: counted as a grant (sdc_consume leaves the drop to it)")
client_apply()
local cl, ctot = client_rocks()
check(#cl == 1 and ctot == 11 and cl[1].w == w_bp, "client: Rock x11 shown in its backpack, exactly once (" .. #cl .. ", " .. ctot .. ")")
check(log_has("client info: world: the host added DA_Rock x11", n_log) ~= nil
    and log_has("to this inventory: on this screen yes (Backpack slot 0, x11)", n_log) ~= nil, "client: logged 'on this screen yes'")

print("== 2. the next rock: onto the stack its screen grows")
n_log = #logs
local stack_uid = list[1] and list[1].it[F.USID] or ZERO
client_local_add("DA_Rock", 10, cl[1] and cl[1].s or slot_widget(w_bp, 0, ZERO, 1), true)
check(#CW.outbox == 1 and CW.outbox[1]:find("WSPOT|DA_Rock|s|" .. gs(stack_uid), 1, true) ~= nil, "client: the stack sent")
deliver()
local r2 = host_grant("DA_Rock", 9, rpc)
list, total = rocks_on_host()
check(#list == 1 and total == 20, "host: 11 + 9 on that one stack (" .. #list .. ", " .. total .. ")")
check(ncalls(rjig, "ServerUpdateCountByUID") == 1 and ncalls(rjig, "CLIENT_UpdateCount") == 1
    and ncalls(rjig, "CLIENT_AddNewItem") == 1, "host: the game's count change, the client told once (CLIENT_UpdateCount)")
check(r2.added == true and r2.note == "Rocks added to inventory" and r2.drop._valid == false, "note right, drop removed")
client_apply()
cl, ctot = client_rocks()
check(#cl == 1 and ctot == 20, "client: one stack of 20 shown (" .. #cl .. ", " .. ctot .. ")")
check(log_has("client info: world: the host counted a world resource onto stack " .. gs(stack_uid) .. ": x20; on this screen yes", n_log) ~= nil,
    "client: logged the new count shown")

print("== 3. a full inventory on the client's screen: the game's drop stays, its note says so")
n_log = #logs
client_local_add("DA_Rock", 8, nil, false)
check(#CW.outbox == 1 and CW.outbox[1]:find("WSPOT|DA_Rock|n", 1, true) ~= nil, "client: 'no room' sent")
deliver()
local before_calls = #rjig._calls
local drops0 = H.world.stats.grant_drops
local r3 = host_grant("DA_Rock", 10, rpc)
check(#rjig._calls == before_calls, "host: nothing added to its inventory")
check(r3.drop._valid == true, "host: the game's drop lies at the client's feet")
check(r3.added == false and r3.note == "Rocks dropped on ground", "note: '" .. r3.note .. "' (true)")
check(H.world.stats.grant_drops == drops0 + 1, "counted as the world module's drop (sdc_consume does not add it)")
check(log_has("stays on the ground at its feet: its screen has no room", n_log) ~= nil, "host: logged")
list, total = rocks_on_host()
check(total == 20, "host: still 20 rocks in its inventory")

print("== 4. no word from the client's screen: it waits for one, then that screen is asked (never the plugin's add)")
n_log = #logs
-- (its stack is full now: the plugin's add would open a new stack in the first grid with room - the med bag)
list[1].it[F.INFO][F.COUNT] = 50
local wd0 = world_drops()
local r4 = host_grant("DA_Rock", 9, rpc)
check(ncalls(rjig, "AddNewItemSomewhere") == 0 and r4.drop._valid == true and #HV.pend == 1,
    "host: nothing added yet, the game's drop waits for the word")
check(world_drops() == wd0 + 1, "counted as the world module's grant inside the game's call (sdc_consume leaves it)")
check(r4.added == true and r4.note == "Rocks added to inventory", "the game's answer: added (" .. r4.note .. ")")
check(log_has("no word from its screen yet; its drop waits up to 1.0 s for it", n_log) ~= nil, "host: logged")
local ask0 = #asked
settle()
check(#HV.pend == 0 and ncalls(rjig, "AddNewItemSomewhere") == 0, "no word in time: NOT the plugin's any-grid add")
check(#asked == ask0 + 1 and asked[#asked].pawn == rpawn and asked[#asked].n == 9
    and asked[#asked].drop == LVL .. r4.drop._name, "no word in time: that screen is asked where it goes, with the game's drop")
check(r4.drop._valid == true and #server[2][F.ITEMS]._t == 0, "the drop waits at its feet for the answer; nothing in the med bag")
check(world_drops() == wd0 + 1, "the counters sdc_consume compares per call: unchanged outside the game's call")
check(log_has("lies at its feet (no word from its screen within 1.0 s): its screen is asked where it goes", n_log) ~= nil,
    "host: logged")
list[1].it[F.INFO][F.COUNT] = 20
to_client = {}

print("== 5. a word used once; an old word not at all")
n_log = #logs
client_local_add("DA_Rock", 12, slot_widget(w_bp, 1, ZERO, 12), false)
deliver()
advance(31)
local adds0 = ncalls(rjig, "AddNewItemSomewhere")
local gen00 = ncalls(rjig, "Generate_AddNewItemToContainer")
ask0 = #asked
host_grant("DA_Rock", 9, rpc)
settle()
check(ncalls(rjig, "Generate_AddNewItemToContainer") == gen00 and ncalls(rjig, "AddNewItemSomewhere") == adds0
    and #asked == ask0 + 1, "a word 31 s old: not waited on as a word, then that screen is asked")
check(log_has("its screen's word is 32 s old", n_log) ~= nil, "logged")
client_local_add("DA_Rock", 12, slot_widget(w_bp, 1, ZERO, 12), false)
deliver()
local gen0 = ncalls(rjig, "Generate_AddNewItemToContainer")
ask0 = #asked
host_grant("DA_Rock", 9, rpc)
host_grant("DA_Rock", 9, rpc)
settle()
check(ncalls(rjig, "Generate_AddNewItemToContainer") == gen0 + 1 and ncalls(rjig, "AddNewItemSomewhere") == adds0
    and #asked == ask0 + 1, "one word, two grants: the word for the first only (the second asks that screen)")

print("== 6. the named grid full here: that screen is asked again, never the plugin's add")
n_log = #logs
client_local_add("DA_Rock", 12, slot_widget(w_bp, 3, ZERO, 12), false)
deliver()
server[3].full = true
local _, tot0 = rocks_on_host()
adds0 = ncalls(rjig, "AddNewItemSomewhere")
ask0 = #asked
local r6 = host_grant("DA_Rock", 7, rpc)
local _, tot1 = rocks_on_host()
check(tot1 == tot0, "nothing added into another grid (" .. tot0 .. " -> " .. tot1 .. ")")
check(ncalls(rjig, "AddNewItemSomewhere") == adds0 and #asked == ask0 + 1 and r6.drop._valid == true,
    "its screen asked again, the drop waits at its feet")
check(log_has("has no room for it here", n_log) ~= nil, "logged")
server[3].full = false

print("== 7. the stack its screen grows is full on the host: a new stack in that stack's grid")
n_log = #logs
list = rocks_on_host()
local big
for _, e in ipairs(list) do if e.grid.name == "backpack" then big = e break end end
check(big ~= nil, "a rock stack in the backpack to grow")
big = big or { it = item(HW.da.DA_Rock, 48, G_BP, 0) }
big.it[F.INFO][F.COUNT] = 48
client_local_add("DA_Rock", 2, slot_widget(w_bp, big.it[F.SLOT], big.it[F.USID], 48), true)
deliver()
gen0 = ncalls(rjig, "Generate_AddNewItemToContainer")
local upd0 = ncalls(rjig, "ServerUpdateCountByUID")
host_grant("DA_Rock", 9, rpc)
check(big.it[F.INFO][F.COUNT] == 48 and ncalls(rjig, "ServerUpdateCountByUID") == upd0, "the full stack untouched")
check(ncalls(rjig, "Generate_AddNewItemToContainer") == gen0 + 1
    and rjig._calls[#rjig._calls - 1][2] == gs(G_BP), "a new stack in the backpack grid that stack is in")

print("== 8. the host mines its own rock: nothing for the client, the host's own add untouched")
n_log = #logs
client_local_add("DA_Rock", 12, slot_widget(w_bp, 6, ZERO, 12), false)   -- the client's copy of that rock granted too
deliver()
local calls0 = #rjig._calls
local _, host_tot0 = rocks_on_host()
local r8 = host_grant("DA_Rock", 10, false)
local _, host_tot1 = rocks_on_host()
check(#rjig._calls == calls0 and host_tot1 == host_tot0, "the client's inventory unchanged")
check(r8.added == true and r8.note == "Rocks added to inventory", "the host's own add answers as before")
check(log_has("host info: world: DA_Rock", n_log) == nil, "no world grant line for the host's own rock")

print("== 9. the client's own scrap salvage: the host's grant where its screen put it")
n_log = #logs
-- (the word from step 8 was for a rock; the scrap word comes with the salvage)
client_local_add("DA_ScrapMetal", 14, slot_widget(w_bp, 7, ZERO, 14), false)
deliver()
WORLD = HW
local pile = new(HW, { "BP_HarvestableObject_ScrapMetal_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_ScrapMetal_C_4",
    { ["Salvaged?"] = false, _loc = { X = 1, Y = 2, Z = 3 } }, { Svr_PlaySound = function() end })
HW.paths["/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal"] = HW.da.DA_ScrapMetal
H.net.handlers.WSALV({ H.world._t.pack(LVL .. pile._name), "14" }, rpc)
local scrap = 0
for _, e in ipairs(all_items()) do
    if e.it[F.INFO][F.ID]._name == "DA_ScrapMetal" then scrap = scrap + e.it[F.INFO][F.COUNT]; check(e.grid.name == "backpack", "scrap in the backpack grid") end
end
check(scrap == 14, "scrap metal x14 added once (" .. scrap .. ")")
check(log_has("gets DA_ScrapMetal x14 where its screen put it", n_log) ~= nil, "logged")

print("== 10. the client: no word for others' adds")
n_log = #logs
local station = new(CW, { "BP_JigComponent_C" }, "BP_JigComponent_Station", { _owner = new(CW, { "BP_Workbench_C" }, "Bench") })
client_local_add("DA_ScrapMetal", 5, slot_widget(w_bp, 8, ZERO, 5), false, station)
check(#CW.outbox == 0, "a station's own inventory: no word")
client_local_add("DA_Cloth", 2, slot_widget(w_bp, 8, ZERO, 2), false)
check(#CW.outbox == 0, "an item a use gave (cloth): no word (sdc_consume asks for it)")
CW.cfg = { world_harvest = false }
client_local_add("DA_Rock", 9, slot_widget(w_bp, 8, ZERO, 9), false)
check(#CW.outbox == 0, "world_harvest off: no word")
CW.cfg = nil
-- a world container's item sent again (sdc_containers: Comp = that container)
to_client = {}
to_client[#to_client + 1] = { kind = "add", item = item(HW.da.DA_Rock, 3, G_TOP, 9), comp = "world" }
client_apply()
check(log_has("to this inventory", n_log) == nil, "a world container's rock: no 'on this screen' line")

print("== 11. the host: words it does not take")
WORLD = HW
advance(31)   -- (step 8's word, unused: the host's own swing, too old now)
local hs = #logs
H.net.handlers.WSPOT({ "DA_Pistol", "c", gs(G_BP) }, rpc)
H.net.handlers.WSPOT({ "DA_Rock", "c", "not-a-guid" }, rpc)
H.net.handlers.WSPOT({ "DA_Rock", "x" }, rpc)
check(log_has("puts", hs) == nil, "not a resource / a bad uid / an unknown kind: ignored")
adds0 = ncalls(rjig, "AddNewItemSomewhere")
ask0 = #asked
host_grant("DA_Rock", 9, rpc)
settle()
check(ncalls(rjig, "AddNewItemSomewhere") == adds0 and #asked == ask0 + 1, "and the next grant asks that screen")
-- a word for one player is not another's (the host's own drop is no remote grant at all)
H.net.handlers.WSPOT({ "DA_WoodenLog", "c", gs(G_BP) }, HW.pc)
adds0 = ncalls(rjig, "AddNewItemSomewhere")
ask0 = #asked
host_grant("DA_WoodenLog", 10, rpc)
check(#HV.pend == 1, "another player's word: this grant still waits for its own")
settle()
check(ncalls(rjig, "AddNewItemSomewhere") == adds0 and #asked == ask0 + 1, "another player's word: not used for this one")
advance(31)   -- (that other player's word, unused)

print("== 12. the game's answer is set for that player's add only")
client_local_add("DA_Rock", 12, slot_widget(w_bp, 9, ZERO, 12), false)
deliver()
WORLD = HW
rock_n = rock_n + 1
local rk = new(HW, { "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_Rocks_C_" .. rock_n, { MaxHits = 0 })
H.world._t.hitters()[rk._addr] = { name = rk._name, pc = rpc, t = T }
H.world.resolver(rk)
local dropx = new(HW, { "BP_RockPickup_C" }, "BP_RockPickup_C_x", {})
fire(HW, DROP, param(rpawn), param({ [F.ID] = HW.da.DA_Rock, [F.COUNT] = 9 }), param("None"), param(dropx))
local other = param(false)
fire(HW, JIG .. "JigTryAddItemSomewhere", param(HW.jig), param(HW.jig), param(HW.da.DA_Rock), param(9), other, param(ZERO))
check(other.get() == false, "another player's add in the same instant: its answer untouched")
local mine = param(false)
fire(HW, JIG .. "JigTryAddItemSomewhere", param(rjig), param(rjig), param(HW.da.DA_Rock), param(9), mine, param(ZERO))
check(mine.get() == false, "(the mark was taken by that first call: no late answer)")
run_timers(HW)

-- the client's slot widget that shows item `u` (nil: not on its screen)
local function client_slot(u)
    for _, w in ipairs({ w_top, w_bp, w_med }) do
        for _, s in ipairs(w._p.ArrayOfItems._t) do if gs(s._p.ItemUniqueID) == gs(u) then return s, w end end
    end
    return nil
end
local function newest(name)
    local last
    for _, e in ipairs(all_items()) do if e.it[F.INFO][F.ID]._name == name then last = e end end
    return last
end

print("== 13. the host's replay of the swing fells the rock: its grant comes BEFORE the client's word")
n_log = #logs
to_client = {}
local wd13 = world_drops()
local adds13, gen13 = ncalls(rjig, "AddNewItemSomewhere"), ncalls(rjig, "Generate_AddNewItemToContainer")
local r13 = host_grant("DA_Rock", 10, rpc)
check(r13.drop._valid == true and #HV.pend == 1 and ncalls(rjig, "Generate_AddNewItemToContainer") == gen13
    and ncalls(rjig, "AddNewItemSomewhere") == adds13, "nothing added yet: the game's drop waits for the word")
check(r13.added == true and r13.note == "Rocks added to inventory", "the game's answer: added")
check(world_drops() == wd13 + 1, "inside the game's call: the module's grant (sdc_consume leaves it)")
advance(0.05)
client_local_add("DA_Rock", 12, slot_widget(w_bp, 10, ZERO, 12), false)   -- the client's copy breaks a moment later
deliver()
check(#HV.pend == 0, "the word settles it the moment it comes (no wait for the timeout)")
check(ncalls(rjig, "Generate_AddNewItemToContainer") == gen13 + 1 and ncalls(rjig, "AddNewItemSomewhere") == adds13
    and newest("DA_Rock").grid.name == "backpack" and newest("DA_Rock").it[F.INFO][F.COUNT] == 10,
    "Rock x10 where its screen put it (the backpack grid), not by the plugin's add")
check(r13.drop._valid == false, "the drop removed")
check(world_drops() == wd13 + 1, "the counters sdc_consume compares: unchanged outside the game's call")
check(log_has("went to its inventory where its screen put it (its word came 0.05 s after the grant): new stack", n_log) ~= nil,
    "host: logged how late the word came")
client_apply()
check(client_slot(newest("DA_Rock").it[F.USID]) ~= nil, "client: shown on its screen")
settle()
check(ncalls(rjig, "AddNewItemSomewhere") == adds13, "no second add when the wait would have run out")

print("== 14. trees: the host's grant before the client's word, three trees (the 11-11 pattern)")
n_log = #logs
to_client = {}
-- (step 11's logs went the old way, into the med bag: out of the way)
for i = #server[2][F.ITEMS]._t, 1, -1 do
    if server[2][F.ITEMS]._t[i][F.INFO][F.ID]._name == "DA_WoodenLog" then table.remove(server[2][F.ITEMS]._t, i) end
end
local function logs_on_host()
    local l, tot = {}, 0
    for _, e in ipairs(all_items()) do
        if e.it[F.INFO][F.ID]._name == "DA_WoodenLog" then l[#l + 1] = e; tot = tot + e.it[F.INFO][F.COUNT] end
    end
    return l, tot
end
local function client_logs()
    local tot, n = 0, 0
    for _, w in ipairs({ w_top, w_bp, w_med }) do
        for _, s in ipairs(w._p.ArrayOfItems._t) do
            if s._p._name == "DA_WoodenLog" then tot = tot + s._p.ItemCount; n = n + 1 end
        end
    end
    return tot, n
end
local adds14 = ncalls(rjig, "AddNewItemSomewhere")
local t1 = host_grant("DA_WoodenLog", 10, rpc)
advance(0.03)
client_local_add("DA_WoodenLog", 11, slot_widget(w_bp, 11, ZERO, 11), false)
deliver()
client_apply()
local hl, ht = logs_on_host()
check(ht == 10 and #hl == 1 and hl[1].grid.name == "backpack", "tree 1: WoodenLog x10 in the backpack grid")
local cslot = hl[1] and client_slot(hl[1].it[F.USID])
check(cslot ~= nil, "tree 1: on the client's screen")
advance(20)
local t2 = host_grant("DA_WoodenLog", 8, rpc)
advance(0.05)
client_local_add("DA_WoodenLog", 9, cslot or slot_widget(w_bp, 11, ZERO, 1), true)
deliver()
client_apply()
advance(35)
local t3 = host_grant("DA_WoodenLog", 12, rpc)
advance(0.02)
client_local_add("DA_WoodenLog", 12, cslot or slot_widget(w_bp, 11, ZERO, 1), true)
deliver()
client_apply()
hl, ht = logs_on_host()
local ctot, cn = client_logs()
check(ht == 30 and #hl == 1 and hl[1].grid.name == "backpack", "host: 10 + 8 + 12 on one stack in the backpack, none in the med bag ("
    .. ht .. " in " .. #hl .. ")")
check(ctot == 30 and cn == 1, "client: one stack of 30 shown (" .. ctot .. " in " .. cn .. ")")
check(t1.drop._valid == false and t2.drop._valid == false and t3.drop._valid == false, "the three drops removed")
check(ncalls(rjig, "AddNewItemSomewhere") == adds14, "the plugin's any-grid add never used")
check(log_has("onto its stack " .. (hl[1] and gs(hl[1].it[F.USID]) or "?") .. " in grid " .. gs(G_BP) .. " in DA_LargeBlackMilitaryBackpack (18 -> 30)", n_log) ~= nil,
    "host: the third tree counted onto that stack (ServerUpdateCountByUID with its two parameters)")

print("== 15. the word that comes late says 'no room': the drop stays at its feet")
n_log = #logs
local calls15 = #rjig._calls
local r15 = host_grant("DA_Rock", 7, rpc)
client_local_add("DA_Rock", 8, nil, false)
deliver()
check(#HV.pend == 0 and #rjig._calls == calls15 and r15.drop._valid == true, "nothing added, the game's drop lies at its feet")
check(log_has("stays on the ground at its feet: its screen has no room for it", n_log) ~= nil, "host: logged")
check(r15.added == true, "(the game's answer was given before the word: 'added' - the known exception)")

print("== 16. the drop picked up while it waited: nothing added")
n_log = #logs
local calls16 = #rjig._calls
local r16 = host_grant("DA_Rock", 9, rpc)
r16.drop:K2_DestroyActor()   -- the client walked over and took it
client_local_add("DA_Rock", 12, slot_widget(w_bp, 12, ZERO, 12), false)
deliver()
check(#HV.pend == 0 and #rjig._calls == calls16, "nothing added (the pickup gave it)")
check(log_has("its drop was picked up meanwhile, nothing added", n_log) ~= nil, "host: logged")
advance(31)   -- (that word was used: none left; to be sure)

print("== 17. two grants waiting, two words: each grant its own word, in order")
n_log = #logs
local gen17 = ncalls(rjig, "Generate_AddNewItemToContainer")
local r17a = host_grant("DA_Rock", 5, rpc)
local r17b = host_grant("DA_Rock", 6, rpc)
check(#HV.pend == 2, "two grants wait")
client_local_add("DA_Rock", 6, slot_widget(w_bp, 13, ZERO, 6), false)
client_local_add("DA_Rock", 7, nil, false)
deliver()
check(#HV.pend == 0 and ncalls(rjig, "Generate_AddNewItemToContainer") == gen17 + 1 and newest("DA_Rock").it[F.INFO][F.COUNT] == 5,
    "the first: x5 into the grid of the first word")
check(r17a.drop._valid == false and r17b.drop._valid == true, "the second: no room on its screen, its drop stays")

print("== 18. two words before two grants (one swing broke two rocks): each grant its own word")
n_log = #logs
local gen18 = ncalls(rjig, "Generate_AddNewItemToContainer")
client_local_add("DA_Rock", 6, slot_widget(w_bp, 14, ZERO, 6), false)
client_local_add("DA_Rock", 7, nil, false)
deliver()
local r18a = host_grant("DA_Rock", 4, rpc)
local r18b = host_grant("DA_Rock", 3, rpc)
check(#HV.pend == 0, "no grant waits: both had a word")
check(ncalls(rjig, "Generate_AddNewItemToContainer") == gen18 + 1 and newest("DA_Rock").it[F.INFO][F.COUNT] == 4
    and r18a.drop._valid == false, "the first rock: x4 into the grid of the first word")
check(r18b.drop._valid == true and log_has("x3 for BP_PlayerCharacter_C_1 stays on the ground at its feet: its screen has no room", n_log) ~= nil,
    "the second rock: the second word (no room), its drop stays")
for i = 1, 6 do client_local_add("DA_ScrapMetal", i, nil, false) end
deliver()
local q = HV.spots[rpc._addr] and HV.spots[rpc._addr].DA_ScrapMetal
check(q ~= nil and #q == HV.SPOT_MAX, "at most " .. HV.SPOT_MAX .. " words kept per player and item (" .. (q and #q or 0) .. ")")
advance(31)

print("== 19. counting a stack up fails in the game: one new stack in its grid instead, and a WARN line")
n_log = #logs
local st19 = newest("DA_Rock")
st19.it[F.INFO][F.COUNT] = 10
local _, tot19 = rocks_on_host()
client_local_add("DA_Rock", 5, slot_widget(w_bp, st19.it[F.SLOT], st19.it[F.USID], 10), true)
deliver()
rjig._fail_count = true
local gen19, upd19 = ncalls(rjig, "Generate_AddNewItemToContainer"), ncalls(rjig, "ServerUpdateCountByUID")
host_grant("DA_Rock", 5, rpc)
local _, tot19b = rocks_on_host()
check(ncalls(rjig, "ServerUpdateCountByUID") == upd19 + 1 and ncalls(rjig, "Generate_AddNewItemToContainer") == gen19 + 1,
    "tried the count change once, then one new stack")
check(tot19b == tot19 + 5 and st19.it[F.INFO][F.COUNT] == 10, "5 stones added once (" .. tot19 .. " -> " .. tot19b .. ")")
check(log_has("host warn: world: counting BP_PlayerController_C_1's stack " .. gs(st19.it[F.USID]) .. " up to 15 FAILED", n_log) ~= nil,
    "host: WARN logged")

print("== 20. salvage with no room on the client's screen: dropped at its feet, not into any grid")
n_log = #logs
-- (a rock grant of that player just now: the drop hook would act if it were the game's)
rock_n = rock_n + 1
local rk20 = new(HW, { "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_Rocks_C_" .. rock_n, { MaxHits = 0 })
H.world._t.hitters()[rk20._addr] = { name = rk20._name, pc = rpc, t = T }
client_local_add("DA_ScrapMetal", 15, nil, false)
deliver()
WORLD = HW
H.world.resolver(rk20)
local adds20, gen20 = ncalls(rjig, "AddNewItemSomewhere"), ncalls(rjig, "Generate_AddNewItemToContainer")
local pile2 = new(HW, { "BP_HarvestableObject_ScrapMetal_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_ScrapMetal_C_20",
    { ["Salvaged?"] = false, _loc = { X = 1, Y = 2, Z = 3 } }, { Svr_PlaySound = function() end })
H.net.handlers.WSALV({ H.world._t.pack(LVL .. pile2._name), "15" }, rpc)
local pk = HW.paths[LVL .. "BP_StaticMeshPickup_C_own" .. drops_n]
check(ncalls(rpawn, "JigMP_OnRequestDropItem") == 1 and pk ~= nil and pk._p._count == 15 and pk._p._da == HW.da.DA_ScrapMetal,
    "ScrapMetal x15 dropped at its feet (the game's drop, its count set)")
check(ncalls(rjig, "AddNewItemSomewhere") == adds20 and ncalls(rjig, "Generate_AddNewItemToContainer") == gen20,
    "not into any grid of its inventory (no med bag)")
check(#HV.pend == 0 and log_has("for BP_PlayerCharacter_C_1: no word", n_log) == nil, "the module's own drop is no game drop to wait on")
check(log_has("gets DA_ScrapMetal x15 dropped at its feet: its screen has no room for it", n_log) ~= nil, "host: logged")
-- the drop fails: the plugin's add, so the scrap is not lost
advance(1)
client_local_add("DA_ScrapMetal", 13, nil, false)
deliver()
rpawn._fail_drop = true
local pile3 = new(HW, { "BP_HarvestableObject_ScrapMetal_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_ScrapMetal_C_21",
    { ["Salvaged?"] = false, _loc = { X = 1, Y = 2, Z = 3 } }, { Svr_PlaySound = function() end })
WORLD = HW
H.net.handlers.WSALV({ H.world._t.pack(LVL .. pile3._name), "13" }, rpc)
rpawn._fail_drop = nil
check(ncalls(rjig, "AddNewItemSomewhere") == adds20 + 1, "the drop failed: the plugin's add (nothing lost)")
check(log_has("its screen has no room for it, and the drop at its feet FAILED; the plugin's add", n_log) ~= nil, "logged")

print("== 21. salvage with no word from the client's screen: dropped at its feet and that screen asked, not the plugin's add")
n_log = #logs
advance(31)   -- (no young scrap word left)
local adds21, gen21, ask21, drops21 = ncalls(rjig, "AddNewItemSomewhere"), ncalls(rjig, "Generate_AddNewItemToContainer"),
    #asked, ncalls(rpawn, "JigMP_OnRequestDropItem")
local pile4 = new(HW, { "BP_HarvestableObject_ScrapMetal_C", "BP_HarvestableObject_C" }, "BP_HarvestableObject_ScrapMetal_C_22",
    { ["Salvaged?"] = false, _loc = { X = 1, Y = 2, Z = 3 } }, { Svr_PlaySound = function() end })
WORLD = HW
H.net.handlers.WSALV({ H.world._t.pack(LVL .. pile4._name), "16" }, rpc)
local pk21 = HW.paths[LVL .. "BP_StaticMeshPickup_C_own" .. drops_n]
check(ncalls(rpawn, "JigMP_OnRequestDropItem") == drops21 + 1 and pk21 and pk21._p._count == 16, "ScrapMetal x16 at its feet first")
check(#asked == ask21 + 1 and asked[#asked].drop == LVL .. pk21._name and asked[#asked].n == 16,
    "that screen asked where it goes, with that pickup")
check(ncalls(rjig, "AddNewItemSomewhere") == adds21 and ncalls(rjig, "Generate_AddNewItemToContainer") == gen21,
    "nothing into any grid meanwhile (no med bag)")

print("== 22. a drop destroyed while it waited (still valid for UE4SS), a dead character, another module's drop")
n_log = #logs
advance(31)
local calls22 = #rjig._calls
local r22 = host_grant("DA_Rock", 9, rpc)
r22.drop._gone = true   -- (picked up: destroyed, not yet collected)
client_local_add("DA_Rock", 12, slot_widget(w_bp, 13, ZERO, 12), false)
deliver()
check(#HV.pend == 0 and #rjig._calls == calls22 and log_has("its drop was picked up meanwhile", n_log) ~= nil,
    "a destroyed drop UE4SS still calls valid: nothing added (never twice)")
advance(31)
calls22 = #rjig._calls
local r22b = host_grant("DA_Rock", 9, rpc)
rpawn._p["PlayerDead?"] = true
client_local_add("DA_Rock", 12, slot_widget(w_bp, 14, ZERO, 12), false)
deliver()
rpawn._p["PlayerDead?"] = nil
check(#HV.pend == 0 and #rjig._calls == calls22 and r22b.drop._valid ~= false and not r22b.drop._gone,
    "the character dead when its word came: nothing added, the drop stays")
advance(31)
calls22 = #rjig._calls
local ask22 = #asked
package.loaded["sdc_place"].dropping = true   -- (inside sdc_place's / IGLOST's / a gain's drop)
local r22c = host_grant("DA_Rock", 9, rpc)
package.loaded["sdc_place"].dropping = nil
settle()
check(#HV.pend == 0 and #rjig._calls == calls22 and #asked == ask22 and r22c.drop._valid ~= false,
    "another module's drop in the grant window: left alone (a real pickup, no fresh resource)")

WORLD = HW
local sl = H.world.status_line()
local seg = sl:match("resource places[^|]*") or "?"
local function stat(key) return tonumber(seg:match(key .. "=(%d+)")) or -1 end
check(stat("sent") == 0 and stat("heard") > 10 and stat("stacked") >= 3 and stat("new stack") >= 5 and stat("no room") >= 4
    and stat("plugin's add") >= 4 and stat("grants that waited for the word") >= 10 and stat("word came late") >= 6,
    "host status line counts them (" .. seg .. ")")
WORLD = CW
check(C.world.status_line():find("resource places from clients' screens sent=", 1, true) ~= nil, "client status line counts its words")

local bad = 0
for _, l in ipairs(logs) do if l:find(" ERR: ", 1, true) then print("    " .. l); bad = bad + 1 end end
check(bad == 0, "no hook / handler errors")

if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
