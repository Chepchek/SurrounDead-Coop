-- Mock harness for sdc_dialogue's trader flow: the real sdc_dialogue /
-- sdc_ue / sdc_net / sdc_config / sdc_log against fake UE objects (sdc_ctx
-- stubbed). Phase 1 = client, phase 2 = host (fresh module loads).
-- usage: lua mock_trade.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails = 0
local function check(cond, what)
    if cond then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local quiet_print = print
local LOG = {}
print = function(s)
    LOG[#LOG + 1] = s
    if os.getenv("MOCK_VERBOSE") then io.write(s) end
end
local function logged(pat)
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end
    return nil
end
local function count_logged(pat)
    local n = 0
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------- fake objects
local W
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return rawget(t, "_p")[k]
end
local next_addr = 4096
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function new(chain, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _calls = {} }, Obj)
    W.objects[#W.objects + 1] = o
    return o
end
local class_objs = {}
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass()
    local cn = self._chain[1]
    local c = class_objs[cn]
    if not c then
        next_addr = next_addr + 16
        local a = next_addr
        c = { IsValid = function() return true end, GetFName = function() return name_obj(cn) end,
              GetAddress = function() return a end }
        class_objs[cn] = c
    end
    return c
end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:IsA(cls)
    for _, c in ipairs(self._chain) do if c == cls._isa then return true end end
    return false
end
local function called(o, fn)
    for _, c in ipairs(o._calls) do if c[1] == fn then return c end end
    return nil
end
local function n_called(o, fn)
    local n = 0
    for _, c in ipairs(o._calls) do if c[1] == fn then n = n + 1 end end
    return n
end
local function record(fn, ret) return function(self, ...) self._calls[#self._calls + 1] = { fn, ... }; return ret end end

local function fn_obj(path) local o = new({ "Function" }, path:match("([^:]+)$")); W.paths[path] = o; return o end
local function class_asset(path, isa_name)
    local o = new({ "BlueprintGeneratedClass" }, path:match("([^%.]+)$"))
    o._full = "BlueprintGeneratedClass " .. path
    o._isa = isa_name
    W.paths[path] = o
    return o
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end
FName = function(s) return name_obj(s) end
FText = function(s) return s end
RegisterHook = function(path, a, b)
    if not W.paths[path] then error("no such function " .. path) end
    W.hooks[path] = W.hooks[path] or {}
    table.insert(W.hooks[path], { pre = a, post = b })
    return 1, 2
end
StaticFindObject = function(path)
    local o = W.paths[path]
    if o and o._valid then return o end
    return nil
end
local function derives(o, cls) for _, c in ipairs(o._chain) do if c == cls then return true end end return false end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(W.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) W.loads[#W.loads + 1] = path; return nil end
ExecuteInGameThread = function(fn) fn() end
local delayed = {}
ExecuteInGameThreadWithDelay = function(ms, fn) delayed[#delayed + 1] = fn; return #delayed end
LoopInGameThreadWithDelay = function() return 1 end
local function run_delayed() local d = delayed; delayed = {}; for _, fn in ipairs(d) do fn() end end

local LIBCDO = { _name = "Default__NarrativeFunctionLibrary" }
local function fire(path, ...)
    local hs = W.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local r = h.pre(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
    return true
end
local function fire_post(path, ...)
    local hs = W.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        if h.post then assert(h.post(...) == nil, "post hook returned a value: " .. path) end
    end
    return true
end

local GNC = "/Script/Narrative.NarrativeFunctionLibrary:GetNarrativeComponent"
local BEGIN = "/Script/Narrative.NarrativeComponent:BeginDialogue"
local CBEGIN = "/Script/Narrative.NarrativeComponent:ClientBeginDialogue"
local CEXIT = "/Script/Narrative.NarrativeComponent:ClientExitDialogue"
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local EVENT = "/Game/Quests/Events/Quest_Event_OnInteractNPC.Quest_Event_OnInteractNPC_C:ExecuteEvent"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local MOVE = JIG .. ":Handle Comp to Comp Move"
local VMONEY = JIG .. ":CheckVendorAmountOfMoney"
local WANDERER = "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C"
local WEND = WANDERER .. ":OnExecuteInteractEnded"
local HUD_CLASS = "/Game/Quests/UI/BP_CustomNarrativeDefaultUI.BP_CustomNarrativeDefaultUI_C"
local DLG_MIL = "/Game/Quests/Dialogue/Traders/Special/Dialogue_MilitaryTrader.Dialogue_MilitaryTrader_C"
local DLG_WAND = "/Game/Quests/Dialogue/Traders/Dialogue_WanderingTrader.Dialogue_WanderingTrader_C"

local function new_world(is_server)
    W = { objects = {}, paths = {}, hooks = {}, out = {}, loads = {} }
    class_objs = {}
    W.paths["/Script/Engine.Default__KismetSystemLibrary"] = new({ "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end, IsServer = function() return is_server end })
    W.paths["/Script/UMG.Default__WidgetBlueprintLibrary"] = new({ "WidgetBlueprintLibrary" }, "WBL", {}, {
        Create = function(_, _, cls)
            return new({ "BP_CustomNarrativeDefaultUI_C" }, "HUD_" .. next_addr, {}, {
                AddToViewport = record("AddToViewport"), IsInViewport = function() return true end })
        end })
    W.paths["/Script/Engine.Default__GameplayStatics"] = new({ "GameplayStatics" }, "GPS", {}, {})
    W.paths["/Script/CoreUObject.Object"] = new({ "Class" }, "Object")
    class_asset(HUD_CLASS, "BP_CustomNarrativeDefaultUI_C")
    class_asset(WANDERER, "BP_MasterTrader_C")
    class_asset("/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C", "BP_TraderMaster_C")
    class_asset("/Game/Quests/Blueprints/NPCs/BP_QuestGiver.BP_QuestGiver_C", "BP_QuestGiver_C")
    for _, p in ipairs({ GNC, BEGIN, CBEGIN, CEXIT, SPAWN, EVENT, MOVE, VMONEY, WEND }) do fn_obj(p) end
    W.dlg_mil = class_asset(DLG_MIL, "Dialogue_MilitaryTrader_C")
    W.dlg_wand = class_asset(DLG_WAND, "Dialogue_WanderingTrader_C")
end

local function make_pc(local_player, loc)
    local helper = new({ "BP_JigHelperComp_C" }, "BP_JigHelperComp_" .. next_addr, {})
    local jig = new({ "BP_JigComponent_C" }, "BP_JigMultiplayer_" .. next_addr, { MainJigContainers = nil })
    local pawn = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_" .. (2147478000 + next_addr),
        { _loc = loc, BP_JigHelperComp = helper, BP_JigMultiplayer = jig })
    jig._p._owner = pawn
    local player = new({ local_player and "LocalPlayer" or "NetConnection" }, "Player_" .. next_addr)
    local comp
    local pc = new({ "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. next_addr,
        { Pawn = pawn, Player = player, NetConnection = (not local_player) and player or nil }, {
            ClientMessage = function(self, msg) W.out[#W.out + 1] = { pc = self, msg = msg } end,
            ServerExecRPC = function(self, msg) W.out[#W.out + 1] = { pc = self, msg = msg, up = true } end,
            IsLocalController = function() return local_player end,
        })
    comp = new({ "NarrativeComponent" }, "NarrativeComponent_" .. next_addr, { _owner = pc }, {
        BeginDialogue = function(self, cls, params) record("BeginDialogue")(self, cls, params); return W.begin_result ~= false end,
        TryExitDialogue = record("TryExitDialogue", true),
    })
    pc._p.NarrativeComponent = comp
    pawn._p.Controller = pc
    return pc, pawn, comp
end

-- a trader: class chain, location, role, dialogue class, money
local function make_trader(chain, name, loc, role, dlg, money)
    local jig = new({ "BP_JigComponent_C" }, "BP_JigMultiplayer_" .. next_addr, { VendorCurrentCurrencyAmount = money })
    local cm = new({ "CharacterMovementComponent" }, "CharMoveComp_" .. next_addr, {}, {
        DisableMovement = record("DisableMovement"), SetMovementMode = record("SetMovementMode") })
    local ai = new({ "BP_SmartAIComponent_C" }, "BP_AIComponent_" .. next_addr, { Dead = false })
    local t = new(chain, name, { _loc = loc, Role = role, Dialogue = dlg, BP_JigMultiplayer = jig,
        CharacterMovement = cm, BP_AIComponent = ai }, {
            K2_DestroyActor = function(self) record("K2_DestroyActor")(self); self._valid = false end,
            OnExecuteInteractDialogue = record("OnExecuteInteractDialogue"),
        })
    jig._p._owner = t
    W.paths["/Game/Levels/PL.PL:PersistentLevel." .. name] = t
    return t, jig, cm
end
local MIL_CHAIN = { "BP_MilitaryTrader_C", "BP_TraderMaster_C" }
local WAND_CHAIN = { "BP_MasterTrader_C", "BP_MasterAICharacter_C" }

local function msgs(kind, up)
    local out = {}
    for i, e in ipairs(W.out) do
        if e.msg and e.msg:find("^SDC1|" .. kind .. "|") or (e.msg == "SDC1|" .. kind) then
            if up == nil or (up and e.up) or (not up and not e.up) then
                local f = {}
                for part in (e.msg .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
                out[#out + 1] = { i = i, msg = e.msg, pc = e.pc, f = f }
            end
        end
    end
    return out
end

local ctx_map = {}
local function fresh_modules()
    for _, m in ipairs({ "sdc_dialogue", "sdc_net", "sdc_ue", "sdc_config", "sdc_log", "sdc_ctx" }) do package.loaded[m] = nil end
    package.loaded["sdc_ctx"] = {
        player_for = function(o)
            local e = ctx_map[o]
            if e then return e end
            local ow = o and o._p and o._p._owner
            return ow and ctx_map[ow] or nil
        end,
        classify = function(o) return ctx_map[o] and "remote" or "local" end,
    }
    local cfg = require("sdc_config")
    cfg.values = {}
    return require("sdc_dialogue"), require("sdc_net")
end

-- ============================================================== client
quiet_print("== client")
new_world(false)
local dlg, net = fresh_modules()
local cpc, cpawn, ccomp = make_pc(true, { X = 1000, Y = 0, Z = 0 })
local S = { role = "client", remote_pcs = {} }
dlg.init(S)
dlg.install()
dlg.register_handlers()
check(W.hooks[GNC] and W.hooks[BEGIN] and W.hooks[CBEGIN] and W.hooks[CEXIT], "client: native hooks (GNC, BeginDialogue, ClientBegin/Exit)")
check(W.hooks[SPAWN] ~= nil, "client: trader spawner hook subscribed at install")
dlg.client_tick(os.time(), cpc, cpawn)
check(dlg.hud_ok(), "client: Narrative HUD built")
check(W.hooks[EVENT] and W.hooks[MOVE] and W.hooks[VMONEY] and W.hooks[WEND], "client: BP hooks registered once their functions exist")

-- the host's military trader (replicated) and a copy only this client has
local mil, miljig = make_trader(MIL_CHAIN, "BP_MilitaryTrader_C_2147385499", { X = 1200, Y = 0, Z = 0 }, 1, W.dlg_mil, 4000)
mil._p.CurrentActor = cpawn

-- F on the replicated trader: GetNarrativeComponent(self) pre on the client
fire(GNC, param(LIBCDO), param(mil))
local qd = msgs("QD", true)
check(#qd == 1 and qd[1].f[3] == W.dlg_mil:GetFullName() and qd[1].f[4] == "1200" and qd[1].f[5] == "0",
    "client: F on a trader asks the host (QD with the dialogue class and the trader's location)")
check(logged("its BeginDialogue is server-only") ~= nil, "client: log says why (BlueprintAuthorityOnly)")
fire(GNC, param(LIBCDO), param(mil))
check(#msgs("QD", true) == 1, "client: a second GetNarrativeComponent within 1.5 s does not ask again")
-- the absorbed BeginDialogue would not fire; if a native call does, no double request
fire(BEGIN, param(ccomp), param(W.dlg_mil), param({}))
check(#msgs("QD", true) == 1, "client: BeginDialogue right after the F path does not ask again")
advance(2.0)
-- someone else's interaction (CurrentActor is not this player's character)
local other = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_2147400000", { _loc = { X = 0, Y = 0, Z = 0 } })
mil._p.CurrentActor = other
fire(GNC, param(LIBCDO), param(mil))
check(#msgs("QD", true) == 1, "client: GetNarrativeComponent for another character's interaction: nothing")
mil._p.CurrentActor = cpawn
-- no HUD: not asked, notice
local hud = dlg.hud_widget
dlg.hud_widget = nil
advance(2.0)
fire(GNC, param(LIBCDO), param(mil))
check(#msgs("QD", true) == 1 and logged("no dialogue HUD here") ~= nil, "client: no HUD: not asked, logged + notice")
dlg.hud_widget = hud
advance(2.0)
fire(GNC, param(LIBCDO), param(mil))
check(#msgs("QD", true) == 2, "client: HUD back: asks again")

-- the host started it: ClientBeginDialogue arrives (log only)
fire(CBEGIN, param(ccomp), param(new({ "Dialogue_MilitaryTrader_C" }, "Dialogue_MilitaryTrader_C_1")), param({}), param({}))
check(logged("the host started Dialogue_MilitaryTrader_C") ~= nil, "client: ClientBeginDialogue logged")
fire(CEXIT, param(ccomp), param(0))
check(logged("dialogue ended (ClientExitDialogue") ~= nil, "client: ClientExitDialogue logged")

-- trade event: did not run here -> QV fallback opens the window with the game's function
cpawn._p.BP_JigHelperComp._p.InteractExecutedActor = mil
local function deliver(msg)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, cpc)
end
deliver("SDC1|QV")
run_delayed()
check(called(mil, "OnExecuteInteractDialogue") ~= nil and called(ccomp, "TryExitDialogue") ~= nil,
    "client: QV without a local trade event: TryExitDialogue + the trader's OnExecuteInteractDialogue")
-- trade event ran here: no fallback
local n_open = n_called(mil, "OnExecuteInteractDialogue")
fire_post(EVENT, param(new({ "Quest_Event_OnInteractNPC_C" }, "ev")), param(cpawn), param(cpc), param(ccomp))
fire(EVENT, param(new({ "Quest_Event_OnInteractNPC_C" }, "ev")), param(cpawn), param(cpc), param(ccomp))
deliver("SDC1|QV")
run_delayed()
check(n_called(mil, "OnExecuteInteractDialogue") == n_open, "client: trade event ran here: no second window")

-- QM: the host's money into the replicated copy only
local own, ownjig = make_trader(MIL_CHAIN, "BP_MilitaryTrader_C_2147478812", { X = 1210, Y = 0, Z = 0 }, 3, W.dlg_mil, 777)
deliver("SDC1|QTM|BP_MilitaryTrader_C|1200|0|0|1234.5000")
check(miljig._p.VendorCurrentCurrencyAmount == 1234.5, "client: QM sets the replicated trader's money")
check(ownjig._p.VendorCurrentCurrencyAmount == 777, "client: QM does not touch a copy only this machine has")
deliver("SDC1|QTM|BP_MilitaryTrader_C|90000|0|0|5")
check(miljig._p.VendorCurrentCurrencyAmount == 1234.5 and logged("no copy of it near") ~= nil, "client: QM far from any copy: nothing")
deliver("SDC1|QTM|BP_MilitaryTrader_C|1200|0|0|nan")
check(miljig._p.VendorCurrentCurrencyAmount == 1234.5, "client: bad QM ignored")

-- F on the client-only copy: not asked, removed on the next tick
own._p.CurrentActor = cpawn
advance(2.0)
local n_qd = #msgs("QD", true)
fire(GNC, param(LIBCDO), param(own))
check(#msgs("QD", true) == n_qd and logged("a trader only this machine has") ~= nil, "client: F on its own trader copy: not asked")
dlg.client_tick(os.time(), cpc, cpawn)
check(called(own, "K2_DestroyActor") ~= nil and logged("removed BP_MilitaryTrader_C_2147478812") ~= nil, "client: own trader copy removed")
check(called(mil, "K2_DestroyActor") == nil, "client: the host's replicated trader stays")

-- the spawners' own spawn is blocked
local sp = new({ "BP_MilitaryTraderSpawner_C" }, "BP_MilitaryTraderSpawner_C_1")
local cls_p = param(class_asset("/Game/Inventory/Traders/Traders/BP_MilitaryTrader.BP_MilitaryTrader_C", "BP_MilitaryTrader_C"))
fire(SPAWN, param(nil), param(sp), cls_p, param({}))
check(cls_p:get() == W.paths["/Script/CoreUObject.Object"], "client: BP_MilitaryTraderSpawner's spawn gets UObject (spawn refused)")
local sp2 = new({ "BP_ShakesConesSpawner_C" }, "BP_ShakesConesSpawner_C_1")
local cls2 = param(class_asset("/Game/Inventory/Traders/Traders/BP_ShakesConesTrader.BP_ShakesConesTrader_C", "x"))
fire(SPAWN, param(nil), param(sp2), cls2, param({}))
check(cls2:get() == W.paths["/Script/CoreUObject.Object"], "client: BP_ShakesConesSpawner's spawn refused too")
local zsp = new({ "BP_AISpawner_Zombies_C" }, "BP_AISpawner_Zombies_C_1")
local zcls = param(class_asset("/Game/AI/Zombies/BP_Zombie.BP_Zombie_C", "BP_Zombie_C"))
fire(SPAWN, param(nil), param(zsp), zcls, param({}))
check(zcls:get() ~= W.paths["/Script/CoreUObject.Object"], "client: other spawns untouched")
fire(SPAWN, param(nil), param(zsp), zcls, param({}))   -- cached class answer
check(zcls:get() ~= W.paths["/Script/CoreUObject.Object"], "client: other spawns untouched (cached)")

-- wandering trader: the window closed -> QE
local wand = make_trader(WAND_CHAIN, "BP_MasterTrader_C_2147373087", { X = 1500, Y = 0, Z = 0 }, 1, W.dlg_wand, 300)
fire_post(WEND, param(wand))
fire(WEND, param(wand))
local qe = msgs("QE", true)
check(#qe >= 1 and qe[1].f[3] == "BP_MasterTrader_C" and qe[1].f[4] == "1500", "client: wandering trader's window closed -> QE")

-- QF -> notice
deliver("SDC1|QF|nonpc")
check(logged("dialogue not started: the host found no such NPC") ~= nil, "client: QF logged / shown")

-- role check: a host machine's GetNarrativeComponent does not use the client path
check(dlg.stats.requested == 2, "client: stats requested = 2")
local lines = {}
dlg.status_lines(lines)
check(#lines == 2 and lines[2]:find("Торговля", 1, true) ~= nil, "client: status lines (Russian)")

-- ============================================================== host
quiet_print("== host")
new_world(true)
LOG = {}
ctx_map = {}
dlg, net = fresh_modules()
local hpc, hpawn = make_pc(true, { X = 0, Y = 0, Z = 0 })
local rpc, rpawn, rcomp = make_pc(false, { X = 1000, Y = 0, Z = 0 })
ctx_map[rpawn] = { pc = rpc, pawn = rpawn }
ctx_map[rpc] = { pc = rpc, pawn = rpawn }
S = { role = "host", remote_pcs = { rpc } }
dlg.init(S)
dlg.install()
dlg.register_handlers()
dlg.host_tick(os.time())
check(W.hooks[MOVE] and W.hooks[VMONEY], "host: trade hooks registered")

local hmil, hmiljig = make_trader(MIL_CHAIN, "BP_MilitaryTrader_C_2147478722", { X = 1200, Y = 0, Z = 0 }, 3, W.dlg_mil, 4000)
local function from_client(msg)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, rpc)
end
-- QD from the client
from_client("SDC1|QD|" .. W.dlg_mil:GetFullName() .. "|1200|0|0")
local bd = called(rcomp, "BeginDialogue")
check(bd and bd[2] == W.dlg_mil, "host: QD starts the dialogue on the client's NarrativeComponent")
check(bd and bd[3] and bd[3].bFreeMovement == true and bd[3].Priority == -1, "host: with the Blueprints' DialoguePlayParams")
local qm = msgs("QTM", false)
check(#qm == 1 and qm[1].pc == rpc and qm[1].f[3] == "BP_MilitaryTrader_C" and tonumber(qm[1].f[7]) == 4000,
    "host: trader's money sent to that client at the dialogue start")
from_client("SDC1|QD|" .. W.dlg_mil:GetFullName() .. "|1200|0|0")
check(n_called(rcomp, "BeginDialogue") == 1, "host: same dialogue again within 3 s: not restarted")
-- no such NPC near
from_client("SDC1|QD|" .. W.dlg_wand:GetFullName() .. "|1500|0|0")
local qf = msgs("QF", false)
check(#qf == 1 and qf[1].f[3] == "nonpc", "host: no such NPC near the client: QF nonpc")
-- BeginDialogue false -> QF start
advance(4.0)
W.begin_result = false
from_client("SDC1|QD|" .. W.dlg_mil:GetFullName() .. "|1200|0|0")
qf = msgs("QF", false)
check(#qf == 2 and qf[2].f[3] == "start", "host: BeginDialogue false: QF start")
W.begin_result = nil

-- wandering trader: stops for the client, walks on QE
local hw, _, hwcm = make_trader(WAND_CHAIN, "BP_MasterTrader_C_2147320101", { X = 1500, Y = 0, Z = 0 }, 3, W.dlg_wand, 300)
advance(4.0)
from_client("SDC1|QD|" .. W.dlg_wand:GetFullName() .. "|1500|0|0")
check(called(hwcm, "DisableMovement") ~= nil, "host: wandering trader stops while the client talks (DisableMovement)")
from_client("SDC1|QE|BP_MasterTrader_C|1500|0|0")
local smm = called(hwcm, "SetMovementMode")
check(smm and smm[2] == 1, "host: QE: the wandering trader walks again (SetMovementMode Walking)")
-- again, then the client walks away
advance(4.0)
from_client("SDC1|QD|" .. W.dlg_wand:GetFullName() .. "|1500|0|0")
rpawn._p._loc = { X = 9000, Y = 0, Z = 0 }
dlg.host_tick(os.time())
check(n_called(hwcm, "SetMovementMode") == 2 and logged("its player walked away") ~= nil, "host: client walked away: walks again")
rpawn._p._loc = { X = 1000, Y = 0, Z = 0 }

-- a purchase: Handle Comp to Comp Move (From = the trader's component), post
local uid = { A = 1, B = 2, C = 3, D = 4 }
local item = { ["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] = uid,
    ["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"] = {
        ["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] = new({ "JigsawItem_DataAsset_C" }, "DA_M4"),
        ["Count_8_DD79AF2A46126A338C8DCCB4616D91CD"] = 1 } }
local function tarray(list)
    return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end }
end
rpawn._p.BP_JigMultiplayer._p.MainJigContainers = tarray({ { ["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] = tarray({ item }) } })
hmiljig._p.VendorCurrentCurrencyAmount = 4100
local n_qm = #msgs("QTM", false)
fire_post(VMONEY, param(rpawn._p.BP_JigMultiplayer), param(100), param(hmiljig), param(false), param(true))
fire(VMONEY, param(rpawn._p.BP_JigMultiplayer), param(100), param(hmiljig), param(false), param(true))
check(#msgs("QTM", false) == n_qm + 1 and tonumber(msgs("QTM", false)[n_qm + 1].f[7]) == 4100, "host: trader's money changed -> QM to the client near it")
fire(MOVE, param(rpawn._p.BP_JigMultiplayer), param(hmiljig), param(rpawn._p.BP_JigMultiplayer), param(uid),
    param(false), param(0), param({}), param(1), param({}), param(0))
check(#msgs("QTM", false) == n_qm + 1, "host: the same money right after: no second QM")
local tl = logged("trade: host: BP_PlayerCharacter_C_")
check(tl ~= nil and tl:find("bought M4 from BP_MilitaryTrader_C_2147478722", 1, true) ~= nil and tl:find("money now 4100", 1, true) ~= nil,
    "host: purchase logged with the item, the trader and its money")
-- a sale by the host's own player, trader money changes
hmiljig._p.VendorCurrentCurrencyAmount = 3900
fire(MOVE, param(hpawn._p.BP_JigMultiplayer), param(hpawn._p.BP_JigMultiplayer), param(hmiljig), param(uid),
    param(false), param(0), param({}), param(1), param({}), param(0))
check(logged("the host's player sold") ~= nil and #msgs("QTM", false) == n_qm + 2, "host: the host's own sale logged, money to the client near it")
-- an ordinary chest move: nothing
local chest = new({ "Container_Chest_C" }, "Chest_1", { _loc = { X = 0, Y = 0, Z = 0 } })
local chestjig = new({ "BP_JigComponent_C" }, "ChestJig", { _owner = chest })
local n_log = #LOG
fire(MOVE, param(rpawn._p.BP_JigMultiplayer), param(chestjig), param(rpawn._p.BP_JigMultiplayer), param(uid),
    param(false), param(0), param({}), param(1), param({}), param(0))
check(#LOG == n_log, "host: a move between a chest and a player: no trade line")
-- a client far away gets no QM
rpawn._p._loc = { X = 90000, Y = 0, Z = 0 }
hmiljig._p.VendorCurrentCurrencyAmount = 3800
fire(VMONEY, param(hpawn._p.BP_JigMultiplayer), param(100), param(hmiljig), param(true), param(true))
check(#msgs("QTM", false) == n_qm + 2, "host: no QM to a client far from the trader")
rpawn._p._loc = { X = 1000, Y = 0, Z = 0 }
-- the client sells, the trader cannot pay: the game's notification would go to the host's HUD
local n_qf = #msgs("QF", false)
fire(VMONEY, param(rpawn._p.BP_JigMultiplayer), param(9000), param(hmiljig), param(true), param(false))
qf = msgs("QF", false)
check(#qf == n_qf + 1 and qf[#qf].f[3] == "vmoney" and qf[#qf].pc == rpc and logged("not have enough money: refused") ~= nil,
    "host: the trader cannot pay the client: QF vmoney to that client")
fire(VMONEY, param(hpawn._p.BP_JigMultiplayer), param(9000), param(hmiljig), param(true), param(false))
check(#msgs("QF", false) == n_qf + 1, "host: the host's own refused sale: no QF")

-- the trade event of the client's dialogue on the host -> QV
fire(EVENT, param(new({ "Quest_Event_OnInteractNPC_C" }, "ev")), param(rpawn), param(rpc), param(rcomp))
check(#msgs("QV", false) == 1, "host: trade event of the client's dialogue -> QV to that client")

-- the host's spawner spawns as usual
local hsp = new({ "BP_MilitaryTraderSpawner_C" }, "BP_MilitaryTraderSpawner_C_1")
local hcls = param(W.dlg_mil)
fire(SPAWN, param(nil), param(hsp), hcls, param({}))
check(hcls:get() == W.dlg_mil, "host: trader spawners untouched on the host")

-- host routing still: a trader whose CurrentActor is the client, client has a HUD
from_client("SDC1|QH|1")
advance(4.0)
hmil._p.CurrentActor = rpawn
local wco = param(hmil)
fire(GNC, param(LIBCDO), wco)
check(wco:get() == nil, "host: GetNarrativeComponent for a client's interaction: world context cleared (routed)")
check(n_called(rcomp, "BeginDialogue") >= 3, "host: routed dialogue started on the client's component")

-- a wandering trader held for the client walks again when the host's role changes
advance(4.0)
local n_smm = n_called(hwcm, "SetMovementMode")
from_client("SDC1|QD|" .. W.dlg_wand:GetFullName() .. "|1500|0|0")
dlg.reset("role standalone")
check(n_called(hwcm, "SetMovementMode") == n_smm + 1, "host: role change: the held wandering trader walks again")
-- reset clears everything without touching objects
dlg.reset("test")
check(logged("dlg: reset (test)") ~= nil, "reset")

quiet_print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
