-- Mock harness for sdc_poiclear (a major place's boss and special container:
-- a client's clearing counts for it; every map shows the host's world). Two
-- instances of the module run side by side, one per machine, each with its
-- own world of objects; messages go through sdc_net's real encode / decode.
-- The game's BP_POIManager / Container_POICrate behaviour is modelled from
-- work\re\pseudo\BP_POIManager.txt and BP_LootContainer.txt.
-- usage: lua mock_poiclear.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local machine = "host"        -- whose world the engine calls see
local worlds = { host = {}, client = {} }
local Obj = {}
local next_addr = 4096
local LEVEL = "/Game/Levels/LongdownValley.LongdownValley:PersistentLevel."

local function new_obj(cls, short, props, methods, bases, where)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true,
                _bases = bases or {}, _where = where or machine }
    o._bases[cls] = true
    setmetatable(o, Obj)
    local w = worlds[where or machine]
    w[#w + 1] = o
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    local p = rawget(t, "_p")[k]
    if p ~= nil then return p end
    return nil
end
Obj.__newindex = function(t, k, v) rawget(t, "_p")[k] = v end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " " .. LEVEL .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:GetOwner() return nil end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local LOOT_CLS = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
local F_OPEN = LOOT_CLS .. ":OpenContainer"
local class_loaded = false
local class_obj = new_obj("BlueprintGeneratedClass", "BP_LootContainer_C", {}, {}, nil, "host")
table.remove(worlds.host)

local hooks = { host = {}, client = {} }
local hook_machine = "host"
local registered = {}
function RegisterHook(path, fn) hooks[hook_machine][path] = fn; registered[#registered + 1] = hook_machine .. " " .. path; return 1, 2 end
function FindAllOf(cls)
    local out = {}
    for _, o in ipairs(worlds[machine]) do if o._valid and o._bases[cls] then out[#out + 1] = o end end
    return #out > 0 and out or nil
end
function FindFirstOf(cls) local l = FindAllOf(cls); return l and l[1] or nil end
function StaticFindObject(path)
    if path == LOOT_CLS then return class_loaded and class_obj or nil end
    for _, o in ipairs(worlds[machine]) do
        if o._valid and LEVEL .. o._short == path then return o end
    end
    return nil
end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delays = {}
function ExecuteInGameThreadWithDelay(_, f) delays[#delays + 1] = { m = machine, f = f }; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end

local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function mark() return #lines + 1 end
local function logged(pat, from)
    for i = from or 1, #lines do if lines[i]:find(pat, 1, true) then return lines[i] end end
    return nil
end

local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
ue.every = function() end
local net = require("sdc_net")

local function on(m) machine = m; ue.forget_world() end
local function run_delays()
    local list = delays
    delays = {}
    for _, d in ipairs(list) do on(d.m); d.f() end
end
local function fire(path, ...)
    local cb = hooks[machine][path]
    if not cb then return nil end
    return cb(...)
end

-- ------------------------------------------------------------ the game's objects
local level_timers = { host = 0, client = 0 }
local function new_levelling(where)
    return new_obj("LevellingComponent_C", "LevellingComponent_" .. where, { CurrentLevel = 10, MultiplyValue = 1, BufferXP = 0 }, {
        AddXP = function(self, xp, _, out)
            self._p.BufferXP = self._p.BufferXP + xp
            if type(out) == "table" then out.XPOutput = xp end
        end,
        Event_LevelBarTimer = function() level_timers[where] = level_timers[where] + 1 end,
    }, nil, where)
end

local function new_textblock(where, text)
    return new_obj("TextBlock", "TextBlock", { __text = text }, {
        SetText = function(self, t) self._p.__text = t end,
    }, nil, where)
end
local function text_of(tb) return tb._p.__text end

-- W_POIMarker + its W_POIMarkerTooltip (the widget's defaults)
local function new_marker(where, bd, sa)
    local tt = new_obj("W_POIMarkerTooltip_C", "W_POIMarkerTooltip_C", {
        POIBossAmount = new_textblock(where, string.format("%d/%d", bd or 0, sa or 1)),
        POIContainer = new_textblock(where, "0/1 Special Container Looted"),
    }, {}, nil, where)
    return new_obj("W_POIMarker_C", "W_POIMarker_C", { MarkerTooltip = tt }, {}, nil, where)
end

local F_MAJOR = "IsAMajorPOI?_11_A87DDB26439CC030B3170C9A49D4FDEB"
local F_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"
local local_pcs = {}
local calls = { host = { loaded = 0, looted = 0 }, client = { loaded = 0, looted = 0 } }

local function boss_text(o)
    local sa = o._p.SpawnAmount
    local a = math.max(0, math.min(o._p.BossesDefeated, sa))
    return string.format("%d/%d", a, sa)
end

-- BP_POIManager_C (level actor, one copy per machine, same name)
local function new_poi(where, short, name, major, loc, off, bd, looted)
    return new_obj("BP_POIManager_C", short, {
        __loc = loc,
        POI = { [F_MAJOR] = major, [F_NAME] = name },
        ContainerLocation = { Translation = off, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } },
        BossesDefeated = bd or 0, SpawnAmount = 1,
        ["UniqueContainerLooted?"] = looted == true, ["Explored?"] = false,
        Marker = new_marker(where, bd, 1),
    }, {
        -- @9884-10232: once per place; XP for player 0 of the machine that runs it
        Event_Looted = function(self)
            calls[self._where].looted = calls[self._where].looted + 1
            if self._p["UniqueContainerLooted?"] then return end
            self._p["UniqueContainerLooted?"] = true
            local comp = local_pcs[self._where]._p.LevellingComponent
            comp:AddXP(comp._p.CurrentLevel * 100 * comp._p.MultiplyValue, false, {})
            local m = self._p.Marker
            if m and m._valid then m._p.MarkerTooltip._p.POIContainer:SetText("1/1 Special Container Looted") end
        end,
        -- @10815-11649 (host: the boss it spawned died)
        BossDeath = function(self)
            self._p.BossesDefeated = self._p.BossesDefeated + 1
            self._p.Marker._p.MarkerTooltip._p.POIBossAmount:SetText(boss_text(self))
            self._p.SpawnAmount = self._p.SpawnAmount - 1
        end,
        -- @10293 -> 10238 (5 s) -> 8332: the texts from the SaveGame values (run at once here)
        ActorLoaded = function(self)
            calls[self._where].loaded = calls[self._where].loaded + 1
            local m = self._p.Marker
            if not (m and m._valid) then return end
            if self._p["UniqueContainerLooted?"] then
                m._p.MarkerTooltip._p.POIContainer:SetText("1/1 Special Container Looted")
            end
            m._p.MarkerTooltip._p.POIBossAmount:SetText(boss_text(self))
        end,
    }, nil, where)
end

-- Container_POICrate_C: the host's (bound to its manager's Event_Looted) and
-- the client's replicated copy (bound to nothing)
local function new_crate(where, short, loc, bound)
    return new_obj("Container_POICrate_C", short, { __loc = loc, __bound = bound, ContainerLooted = false }, {
        -- OpenContainer @5560 -> 4710 ContainerLooted = true -> 4459 broadcast Looted; UE4SS post-hook after it
        OpenContainer = function(self)
            self._p.ContainerLooted = true
            local b = self._p.__bound
            if b then b:Event_Looted() end
            fire(F_OPEN, param(self))
        end,
    }, { BP_LootContainer_C = true, Actor = true }, where)
end

-- host's world
machine = "host"
local host_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local host_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_0", { Player = host_lp,
    LevellingComponent = new_levelling("host") }, {}, { PlayerController = true })
local host_pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_0", { Controller = host_pc, __loc = { X = 0, Y = 0, Z = 0 } })
host_pc._p.Pawn = host_pawn
local_pcs.host = host_pc
local conn = new_obj("IpConnection", "IpConnection_1", {})
local rpc_h = new_obj("BP_PlayerController_C", "BP_PlayerController_C_7", { Player = conn, NetConnection = conn,
    LevellingComponent = new_levelling("host") }, {}, { PlayerController = true })
local rpawn_h = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Controller = rpc_h, __loc = { X = 10200, Y = 0, Z = 0 } })
rpc_h._p.Pawn = rpawn_h
-- P1 Gas Station: crate at 10000+300, 0+50, 0; P2 Whitewood (one boss down in the save); P3 a small place;
-- P4 Hidden Houses: a major place nobody has been to
local hp1 = new_poi("host", "BP_POIManager_C_12", "Gas Station", true, { X = 10000, Y = 0, Z = 0 }, { X = 300, Y = 50, Z = 0 })
local hp2 = new_poi("host", "BP_POIManager_C_20", "Whitewood", true, { X = 50000, Y = 0, Z = 0 }, { X = 0, Y = -200, Z = 10 }, 1)
new_poi("host", "BP_POIManager_C_33", "Abandoned House", false, { X = 70000, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 })
local hp4 = new_poi("host", "BP_POIManager_C_44", "Hidden Houses", true, { X = 90000, Y = 0, Z = 0 }, { X = 100, Y = 0, Z = 0 })
local hcrate1 = new_crate("host", "Container_POICrate_C_2147400001", { X = 10300, Y = 50, Z = 0 }, hp1)
local hcrate2 = new_crate("host", "Container_POICrate_C_2147400002", { X = 50000, Y = -200, Z = 10 }, hp2)

-- client's world: the same level actors (same names), its own runtime names for the crates
machine = "client"
local client_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local client_comp = new_levelling("client")
local client_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_1", { Player = client_lp,
    LevellingComponent = client_comp }, {}, { PlayerController = true })
local client_pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_1", { Controller = client_pc, __loc = { X = 10200, Y = 0, Z = 0 } })
client_pc._p.Pawn = client_pawn
local_pcs.client = client_pc
local cp1 = new_poi("client", "BP_POIManager_C_12", "Gas Station", true, { X = 10000, Y = 0, Z = 0 }, { X = 300, Y = 50, Z = 0 })
local cp2 = new_poi("client", "BP_POIManager_C_20", "Whitewood", true, { X = 50000, Y = 0, Z = 0 }, { X = 0, Y = -200, Z = 10 })
new_poi("client", "BP_POIManager_C_33", "Abandoned House", false, { X = 70000, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 })
local cp4 = new_poi("client", "BP_POIManager_C_44", "Hidden Houses", true, { X = 90000, Y = 0, Z = 0 }, { X = 100, Y = 0, Z = 0 })
cp4._p.Marker = nil   -- its marker is not made yet (no character when it began play)
local ccrate1 = new_crate("client", "Container_POICrate_C_2147300011", { X = 10300.4, Y = 49.8, Z = 0 }, nil)
local ccrate2 = new_crate("client", "Container_POICrate_C_2147300012", { X = 50000, Y = -200, Z = 10 }, nil)

-- ------------------------------------------------------------ two module instances
local Sh = { role = "host", remote_pcs = { rpc_h }, map = "LongdownValley" }
local Sc = { role = "client", map = "LongdownValley", remote_pcs = {}, client = { acked = true, pc_key = "BP_PlayerController_C_1" } }
local KINDS = { "POIST", "POICL", "POIQ" }

on("host")
local host_mod = require("sdc_poiclear")
host_mod.install(Sh)
local host_handlers = {}
for _, k in ipairs(KINDS) do host_handlers[k] = net.handlers[k] end
package.loaded["sdc_poiclear"] = nil
on("client")
local client_mod = require("sdc_poiclear")
client_mod.install(Sc)
local client_handlers = {}
for _, k in ipairs(KINDS) do client_handlers[k] = net.handlers[k] end
check(host_mod ~= client_mod, "two independent module instances")
for _, k in ipairs(KINDS) do check(host_handlers[k] ~= nil and client_handlers[k] ~= nil, "handler for " .. k) end
check(cfg.get("world_poi_clear") == true, "config world_poi_clear defaults to on")

local wire = {}
net.send_to = function(pc, kind, ...) wire[#wire + 1] = { from = machine, to = pc, msg = net.encode(kind, ...) }; return true end
net.send_to_host = function(kind, ...) wire[#wire + 1] = { from = machine, to = "host", msg = net.encode(kind, ...) }; return true end
local function take(kind)
    local out, keep = {}, {}
    for _, m in ipairs(wire) do
        local k = net.decode(m.msg)
        if kind == nil or k == kind then out[#out + 1] = m else keep[#keep + 1] = m end
    end
    wire = keep
    return out
end
local function deliver(list)
    for _, m in ipairs(list) do
        local kind, fields = net.decode(m.msg)
        if m.to == "host" then
            on("host"); host_handlers[kind](fields, rpc_h)
        else
            on("client"); client_handlers[kind](fields, client_pc)
        end
    end
end
local function tick(m, mod) on(m); hook_machine = m; mod.tick() end
local function both(dt)
    T = T + (dt or 2.1)
    tick("host", host_mod); tick("client", client_mod)
end

-- ------------------------------------------------------------ 1. hooks, baseline
both(0)
check(next(hooks.client) == nil, "client: no hook while the loot container class is not loaded")
class_loaded = true
both()
check(hooks.client[F_OPEN] ~= nil, "client: BP_LootContainer_C:OpenContainer hooked")
check(hooks.host[F_OPEN] == nil, "host: no OpenContainer hook (its crates are bound by the game)")
local nreg = #registered
both(); both()
check(#registered == nreg, "the hook is registered once")
check(logged("3 major place(s) (a boss and a special container) among the 4 places") ~= nil, "both: 3 major places found")
check(#take("POIST") == 0, "host: the first poll is the baseline (nothing sent)")

-- ------------------------------------------------------------ 2. join: the host's saved state
local q = take("POIQ")
check(#q == 1 and q[1].to == "host", "client: asks the host for the state once in the world (POIQ)")
both()
check(#take("POIQ") == 0, "client: asks once per world")
local m0 = mark()
deliver(q)
local snap = take("POIST")
check(#snap == 1 and snap[1].to == rpc_h and snap[1].msg == "SDC1|POIST|j|BP_POIManager_C_20,1,0",
    "host: only the place with a boss down goes back: " .. tostring(snap[1] and snap[1].msg))
check(logged("1 of 3 with a boss down", m0) ~= nil, "host logs the snapshot")
deliver(snap)
check(cp2.BossesDefeated == 1, "client: Whitewood's copy has the host's bosses defeated")
check(calls.client.loaded == 1 and text_of(cp2.Marker.MarkerTooltip.POIBossAmount) == "1/1",
    "client: the game's load path shows '1/1' on its map")
check(text_of(cp2.Marker.MarkerTooltip.POIContainer) == "0/1 Special Container Looted", "client: Whitewood's container not searched")
check(logged("Whitewood (BP_POIManager_C_20) here as in the host's world (join): bosses defeated 0 -> 1") ~= nil, "client logs it")

-- ------------------------------------------------------------ 3. the client kills Gas Station's boss
on("host")
hp1:BossDeath()   -- the host's copy counted it (its boss died on the host)
check(text_of(hp1.Marker.MarkerTooltip.POIBossAmount) == "1/1", "host: its own map shows 1/1 (the game)")
check(cp1.BossesDefeated == 0, "client: nothing yet")
m0 = mark()
both()
local live = take("POIST")
check(#live == 1 and live[1].msg == "SDC1|POIST|l|BP_POIManager_C_12,1,0", "host: the change goes to the client: " .. tostring(live[1] and live[1].msg))
check(logged("Gas Station (BP_POIManager_C_12): bosses defeated 0 -> 1", m0) ~= nil, "host logs the change")
deliver(live)
check(cp1.BossesDefeated == 1 and text_of(cp1.Marker.MarkerTooltip.POIBossAmount) == "1/1", "client: its map shows 1/1")
both()
check(#take("POIST") == 0, "host: nothing new, nothing sent")

-- ------------------------------------------------------------ 4. the client searches Gas Station's crate first
on("client")
local xp0 = client_comp.BufferXP
local open_box = new_obj("BP_LootContainer_C", "BP_LootContainer_C_99", { __loc = { X = 10300, Y = 50, Z = 0 } }, {
    OpenContainer = function(self) fire(F_OPEN, param(self)) end }, { BP_LootContainer_C = true }, "client")
open_box:OpenContainer()   -- an ordinary container at the same place
run_delays()
check(#take() == 0 and client_comp.BufferXP == xp0, "client: an ordinary container counts nothing")
m0 = mark()
ccrate1:OpenContainer()
check(cp1["UniqueContainerLooted?"] == false, "client: nothing inside the hook itself")
run_delays()
check(cp1["UniqueContainerLooted?"] == true, "client: its copy's Event_Looted ran (searched)")
check(client_comp.BufferXP == xp0 + 1000, "client: the game's XP on its own progression: +" .. tostring(client_comp.BufferXP - xp0))
check(level_timers.client == 1, "client: the XP bar timer started")
check(text_of(cp1.Marker.MarkerTooltip.POIContainer) == "1/1 Special Container Looted", "client: its map shows 1/1 Special Container Looted")
check(logged("searched here first", m0) ~= nil and logged("XP +1000", m0) ~= nil, "client logs the search and the XP")
local cl = take("POICL")
check(#cl == 1 and cl[1].to == "host" and cl[1].msg == "SDC1|POICL|BP_POIManager_C_12", "client: POICL to the host")
local hxp, rxp = host_pc.LevellingComponent.BufferXP, rpc_h.LevellingComponent.BufferXP
m0 = mark()
deliver(cl)
check(hp1["UniqueContainerLooted?"] == true, "host: counted in the host's world (saved)")
check(text_of(hp1.Marker.MarkerTooltip.POIContainer) == "1/1 Special Container Looted", "host: its map shows it too")
check(host_pc.LevellingComponent.BufferXP == hxp and rpc_h.LevellingComponent.BufferXP == rxp, "host: no XP on the host for the client's search")
check(calls.host.looted == 0, "host: its Event_Looted did not run")
check(logged("searched the special container of Gas Station (BP_POIManager_C_12) first", m0) ~= nil, "host logs it")
both(0.6)
local echo = take("POIST")
check(#echo == 1 and echo[1].msg == "SDC1|POIST|l|BP_POIManager_C_12,1,1", "host: the change to every client at the next tick")
local nl = calls.client.loaded
deliver(echo)
check(calls.client.loaded == nl, "client: already so here - no load path again")
-- again
xp0 = client_comp.BufferXP
on("client"); ccrate1:OpenContainer(); run_delays()
check(client_comp.BufferXP == xp0 and #take() == 0, "client: a second search pays nothing and sends nothing")

-- ------------------------------------------------------------ 5. the host searches Whitewood's crate
on("host")
hxp = host_pc.LevellingComponent.BufferXP
hcrate2:OpenContainer()
check(hp2["UniqueContainerLooted?"] == true and host_pc.LevellingComponent.BufferXP == hxp + 1000, "host: the game paid the host")
both()
local hl = take("POIST")
check(#hl == 1 and hl[1].msg == "SDC1|POIST|l|BP_POIManager_C_20,1,1", "host: Whitewood's change to the client")
xp0 = client_comp.BufferXP
deliver(hl)
check(cp2["UniqueContainerLooted?"] == true and text_of(cp2.Marker.MarkerTooltip.POIContainer) == "1/1 Special Container Looted",
    "client: its map shows Whitewood's container searched")
check(client_comp.BufferXP == xp0, "client: no XP for the host's search")
m0 = mark()
on("client"); ccrate2:OpenContainer(); run_delays()
check(client_comp.BufferXP == xp0, "client: searching it afterwards pays nothing (searched in this world)")
check(logged("already searched in this world before", m0) ~= nil, "client logs why")
local cl2 = take("POICL")
check(#cl2 == 1, "client: the host is told once")
m0 = mark()
deliver(cl2)
check(logged("already counted in the host's world", m0) ~= nil and #take() == 0, "host: already counted, nothing else")

-- ------------------------------------------------------------ 6. a marker the game made again
on("client")
cp1._p.Marker = new_marker("client", 1, 1)   -- RespawnMarker: the widget's defaults
check(text_of(cp1.Marker.MarkerTooltip.POIContainer) == "0/1 Special Container Looted", "client: the new marker starts from the defaults")
m0 = mark()
both()
check(text_of(cp1.Marker.MarkerTooltip.POIContainer) == "1/1 Special Container Looted", "client: the load path shows its state again")
check(logged("made its map marker again", m0) ~= nil, "client logs it")
both()
check(calls.client.loaded == nl + 2, "client: once per new marker")

-- ------------------------------------------------------------ 7. a place whose marker is not made yet, a refused search
on("host"); hp4:BossDeath()
both()
deliver(take("POIST"))
check(cp4.BossesDefeated == 1, "client: Hidden Houses' copy gets the value at once")
m0 = mark()
cp4._p.Marker = new_marker("client", 1, 1)
both()
check(text_of(cp4.Marker.MarkerTooltip.POIBossAmount) == "1/1" and logged("Hidden Houses (BP_POIManager_C_44) here as in the host's world", m0) ~= nil,
    "client: shown once its marker is made")
m0 = mark()
on("host"); host_handlers.POICL({ "BP_POIManager_C_44" }, rpc_h)   -- the client is at Gas Station
check(hp4["UniqueContainerLooted?"] == false and logged("is not near it here", m0) ~= nil, "host: a search from far away is refused")
local back = take("POIST")
check(#back == 1 and back[1].to == rpc_h and back[1].msg == "SDC1|POIST|j|BP_POIManager_C_44,1,0", "host: its state goes back to that client")
deliver(back)
m0 = mark()
on("host"); host_handlers.POICL({ "BP_POIManager_C_33" }, rpc_h)
check(logged("no such major place", m0) ~= nil and hp4["UniqueContainerLooted?"] == false, "host: not a major place: not counted")
-- a crate where no major place has one
m0 = mark()
on("client")
local stray = new_crate("client", "Container_POICrate_C_2147300099", { X = 30000, Y = 30000, Z = 0 }, nil)
stray:OpenContainer(); run_delays()
check(logged("no major place's container stands there", m0) ~= nil and #take() == 0, "client: a crate of no major place counts nothing")

-- ------------------------------------------------------------ 8. a place the client does not have; values only go up
m0 = mark()
on("client"); client_handlers.POIST({ "l", "BP_POIManager_C_77,2,1" }, client_pc)
for _ = 1, 16 do both() end
check(logged("BP_POIManager_C_77 is not in this world here", m0) ~= nil, "client: an unknown place is given up after a while")
on("client"); client_handlers.POIST({ "j", "BP_POIManager_C_12,0,0" }, client_pc)
check(cp1.BossesDefeated == 1 and cp1["UniqueContainerLooted?"] == true, "client: an older state never undoes one")

-- ------------------------------------------------------------ 9. host alone, config off
Sh.remote_pcs = {}
on("host"); hp1.BossesDefeated = 2
both()
check(#take() == 0, "host alone: nothing sent")
Sh.remote_pcs = { rpc_h }
both()
check(#take("POIST") == 1, "a client back: the change is sent")
cfg.set("world_poi_clear", false)
on("client")
local cp5 = new_poi("client", "BP_POIManager_C_55", "Farm", true, { X = 0, Y = 90000, Z = 0 }, { X = 0, Y = 0, Z = 0 })
local cc5 = new_crate("client", "Container_POICrate_C_2147300055", { X = 0, Y = 90000, Z = 0 }, nil)
cc5:OpenContainer(); run_delays()
check(cp5["UniqueContainerLooted?"] == false and #take() == 0, "off: the client counts and sends nothing")
m0 = mark()
on("host"); host_handlers.POICL({ "BP_POIManager_C_44" }, rpc_h)
host_handlers.POIQ({}, rpc_h)
check(logged("world_poi_clear or world_sync off", m0) ~= nil and #take() == 0, "off: the host ignores searches and questions")
on("host"); hp2.BossesDefeated = 3
both()
check(#take() == 0, "off: the host sends no changes")
cfg.set("world_poi_clear", true)
cfg.set("world_sync", false)
both()
check(#take() == 0, "world_sync off: nothing sent")
cfg.set("world_sync", true)

-- ------------------------------------------------------------ 10. robustness, reset
on("client")
check(pcall(hooks.client[F_OPEN], param(nil)) and hooks.client[F_OPEN](param(ccrate1)) == nil, "hook callback never throws and returns nothing")
local bad = setmetatable({}, { __index = function() error("boom") end })
check(pcall(hooks.client[F_OPEN], bad), "a broken hook argument is caught")
run_delays()
take()
on("client")
client_handlers.POIST({}, client_pc)
client_handlers.POIST({ "l", "x;;BP_POIManager_C_12,a,1;Default__BP_POIManager_C,1,1;../x,1,1" }, client_pc)
on("host")
host_handlers.POICL({}, rpc_h)
host_handlers.POICL({ "../../etc" }, rpc_h)
check(#take() == 0, "malformed messages are ignored")
local pe = client_mod.parse_entries("BP_POIManager_C_12,1,0;bad;BP_POIManager_C_20,3,1")
check(#pe == 2 and pe[2].bd == 3 and pe[2].l == true, "entries parsed")
check(client_mod.status_line():find("poiclear: on=true hook=true majors=3", 1, true) ~= nil, "client status line: " .. client_mod.status_line())
check(host_mod.status_line():find("clients' searches counted=1", 1, true) ~= nil, "host status line: " .. host_mod.status_line())
client_mod.reset("test")
check(next(client_mod._st.want) == nil and client_mod._st.majors == nil, "reset forgets the old world")

print = real_print
for _, l in ipairs(lines) do if l:find("poiclear:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
