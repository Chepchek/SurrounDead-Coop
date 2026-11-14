-- Mock harness for per-player quests: the real sdc_quests + sdc_dialogue +
-- sdc_ue / sdc_net / sdc_config / sdc_log against fake UE objects (sdc_ctx
-- stubbed). Phase 1 = host, phase 2 = client, phase 3 = host in the group
-- design. usage: lua mock_quests.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
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
local class_objs = {}
local function new(chain, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _calls = {} }, Obj)
    W.objects[#W.objects + 1] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass()
    if self._cls then return self._cls end
    local cn = self._chain[1]
    local c = class_objs[cn]
    if not c then
        next_addr = next_addr + 16
        local a = next_addr
        c = { IsValid = function() return true end, GetFName = function() return name_obj(cn) end,
              GetAddress = function() return a end, GetFullName = function() return "Class /Script/X." .. cn end }
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

local function tarray(list)
    return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end, _list = list }
end

local function fn_obj(path) local o = new({ "Function" }, path:match("([^:]+)$")); W.paths[path] = o; return o end
local function class_asset(path, isa_name)
    local o = new({ "BlueprintGeneratedClass" }, path:match("([^%.]+)$"))
    o._full = "BlueprintGeneratedClass " .. path
    o._isa = isa_name
    W.paths[path] = o
    return o
end
local function asset(cls, path)
    local o = new({ cls }, path:match("([^%.]+)$"))
    o._full = cls .. " " .. path
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
LoadAsset = function() return nil end
ExecuteInGameThread = function(fn) fn() end
local delayed = {}
ExecuteInGameThreadWithDelay = function(_, fn) delayed[#delayed + 1] = fn; return #delayed end
LoopInGameThreadWithDelay = function() return 1 end
local function run_delayed() local d = delayed; delayed = {}; for _, fn in ipairs(d) do fn() end end

local function fire(path, ...)
    local hs = W.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do assert(h.pre(...) == nil, "hook returned a value: " .. path) end
    return true
end

local GNC = "/Script/Narrative.NarrativeFunctionLibrary:GetNarrativeComponent"
local BEGIN = "/Script/Narrative.NarrativeComponent:BeginDialogue"
local CBEGIN = "/Script/Narrative.NarrativeComponent:ClientBeginDialogue"
local CEXIT = "/Script/Narrative.NarrativeComponent:ClientExitDialogue"
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local CNDT = "/Script/Narrative.NarrativeFunctionLibrary:CompleteNarrativeDataTask"
local TEVENT = "/Game/Quests/Events/Quest_Event_OnInteractNPC.Quest_Event_OnInteractNPC_C:ExecuteEvent"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local WANDERER = "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C"
local GIVER = "/Game/Quests/Blueprints/NPCs/BP_QuestGiver.BP_QuestGiver_C"
local GIVER_SERVER = GIVER .. ":OnServerExecuteInteract"
local SPAWN_MARKER = "/Game/Quests/Events/Quest_Event_SpawnMarker.Quest_Event_SpawnMarker_C:ExecuteEvent"
local REMOVE_MARKER = "/Game/Quests/Events/Quest_Event_RemoveMarker.Quest_Event_RemoveMarker_C:ExecuteEvent"
local REWARD_XP = "/Game/Quests/Events/Reward/Quest_Event_RewardPlayerXP.Quest_Event_RewardPlayerXP_C:ExecuteEvent"
local CRATE_OPEN = "/Game/Quests/Blueprints/Objects/BP_GuaranteedSpawner.BP_GuaranteedSpawner_C:OpenContainer"
local JOURNAL = "/Game/UI/Widgets/Journal/Journal_QuestsUI.Journal_QuestsUI_C"
local INTERACT_TASK = "/Game/Quests/Tasks/Quest_Task_InteractWithActor.Quest_Task_InteractWithActor"
local POWER_TASK = "/Game/Quests/Tasks/Quest_Task_PowerOnGenerator.Quest_Task_PowerOnGenerator"
local SAFEZONE = "/Game/Quests/Quests/Random/Quest_TheSafeZone.Quest_TheSafeZone_C"
local LAPTOP = "/Game/Inventory/Items/DataAssets/Quest/DA_MilitaryIntelLaptop.DA_MilitaryIntelLaptop"
local MARKER = "/Game/Quests/Blueprints/Objects/BP_QuestMarker.BP_QuestMarker_C"
local NC_BEGINQ = "/Script/Narrative.NarrativeComponent:BeginQuest"
local NC_FORGETQ = "/Script/Narrative.NarrativeComponent:ForgetQuest"
local NC_ONREP = "/Script/Narrative.NarrativeComponent:OnRep_PendingUpdateList"

local function new_world(is_server)
    W = { objects = {}, paths = {}, hooks = {}, out = {}, cndt = {} }
    class_objs = {}
    W.paths["/Script/Engine.Default__KismetSystemLibrary"] = new({ "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end, IsServer = function() return is_server end })
    W.paths["/Script/UMG.Default__WidgetBlueprintLibrary"] = new({ "WidgetBlueprintLibrary" }, "WBL", {}, {
        Create = function()
            return new({ "BP_CustomNarrativeDefaultUI_C" }, "HUD_" .. next_addr, {}, {
                AddToViewport = record("AddToViewport"), IsInViewport = function() return true end,
                ["Add Notification"] = record("AddNotification") })
        end })
    W.spawned = {}
    W.paths["/Script/Engine.Default__GameplayStatics"] = new({ "GameplayStatics" }, "GPS", {}, {
        DeleteGameInSlot = record("DeleteGameInSlot", true),
        BeginDeferredActorSpawnFromClass = function(_, _, _, tf)
            local m = new({ "BP_QuestMarker_C" }, "BP_QuestMarker_C_" .. (2147400000 - next_addr), { _loc = tf.Translation },
                { K2_DestroyActor = function(self) self._valid = false end })
            W.spawned[#W.spawned + 1] = m
            return m
        end,
        FinishSpawningActor = function(_, a) return a end,
    })
    W.paths["/Script/CoreUObject.Object"] = new({ "Class" }, "Object")
    W.paths["/Script/Narrative.Default__NarrativeFunctionLibrary"] = new({ "NarrativeFunctionLibrary" }, "Lib", {}, {
        CompleteNarrativeDataTask = function(_, comp, task, arg, qty)
            W.cndt[#W.cndt + 1] = { comp = comp, task = task, arg = arg, qty = qty }
            return true
        end })
    class_asset(WANDERER, "BP_MasterTrader_C")
    class_asset("/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C", "BP_TraderMaster_C")
    class_asset(GIVER, "BP_QuestGiver_C")
    class_asset("/Game/Quests/UI/BP_CustomNarrativeDefaultUI.BP_CustomNarrativeDefaultUI_C", "BP_CustomNarrativeDefaultUI_C")
    class_asset(MARKER, "BP_QuestMarker_C")
    for _, p in ipairs({ GNC, BEGIN, CBEGIN, CEXIT, SPAWN, CNDT, TEVENT, JIG .. ":Handle Comp to Comp Move",
            JIG .. ":CheckVendorAmountOfMoney", WANDERER .. ":OnExecuteInteractEnded", GIVER_SERVER,
            SPAWN_MARKER, REMOVE_MARKER, REWARD_XP, CRATE_OPEN, JOURNAL .. ":Show Quest", JOURNAL .. ":ForgetQuest",
            NC_BEGINQ, NC_FORGETQ, NC_ONREP }) do
        fn_obj(p)
    end
    W.interact = asset("NarrativeDataTask", INTERACT_TASK)
    W.power = asset("NarrativeDataTask", POWER_TASK)
    W.laptop = asset("JigsawItem_DataAsset_C", LAPTOP)
    W.safezone = class_asset(SAFEZONE, "Quest_TheSafeZone_C")
    W.bounties = {}
    for i = 1, 3 do
        W.bounties[i] = class_asset("/Game/Quests/Quests/Bounties/Quest_Bounty_" .. i .. ".Quest_Bounty_" .. i .. "_C", "Quest_Bounty_" .. i)
    end
    W.intel_dlg = class_asset("/Game/Quests/Dialogue/Settlement/Dialogue_SettlementIntelGiver.Dialogue_SettlementIntelGiver_C",
        "Dialogue_SettlementIntelGiver_C")
    W.lab_quest = class_asset("/Game/Quests/Quests/Dungeon/Quest_Dungeon_LaboratoryBunker.Quest_Dungeon_LaboratoryBunker_C", "LabQ")
end

local function make_comp(owner)
    local comp
    comp = new({ "NarrativeComponent" }, "NarrativeComponent_" .. next_addr, { _owner = owner, _started = {},
        QuestList = tarray({}) }, {
        BeginDialogue = function(self, cls, params) record("BeginDialogue")(self, cls, params); return true end,
        TryExitDialogue = record("TryExitDialogue", true),
        IsQuestStartedOrFinished = function(self, cls) return self._p._started[cls] == true end,
        BeginQuest = function(self, cls) record("BeginQuest")(self, cls); self._p._started[cls] = true
            return new({ "Quest" }, "Quest_" .. next_addr) end,
        ForgetQuest = function(self, cls) record("ForgetQuest")(self, cls); self._p._started[cls] = nil; return true end,
        Save = function(self, name, slot) record("Save")(self, name, slot); W.saved = W.saved or {}; W.saved[name] = true; return true end,
        Load = function(self, name, slot) record("Load")(self, name, slot); return (W.saved or {})[name] == true end,
    })
    return comp
end

local function make_pc(local_player, loc)
    local helper = new({ "BP_JigHelperComp_C" }, "BP_JigHelperComp_" .. next_addr, {})
    local pawn = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_" .. (2147478000 + next_addr),
        { _loc = loc, BP_JigHelperComp = helper }, {
            JigMP_OnRequestDropItem = function(self, info, name, out) record("Drop")(self, info, name); out.ActorRef = new({ "Pickup" }, "P") end })
    local player = new({ local_player and "LocalPlayer" or "NetConnection" }, "Player_" .. next_addr)
    local lev = new({ "LevellingComponent_C" }, "LevellingComponent_" .. next_addr, {}, {
        AddXP = function(self, amount, _, out) record("AddXP")(self, amount); out.XPOutput = amount end,
        Event_LevelBarTimer = record("Timer") })
    local pc = new({ "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. next_addr,
        { Pawn = pawn, Player = player, NetConnection = (not local_player) and player or nil, LevellingComponent = lev }, {
            ClientMessage = function(self, msg) W.out[#W.out + 1] = { pc = self, msg = msg } end,
            ServerExecRPC = function(self, msg) W.out[#W.out + 1] = { pc = self, msg = msg, up = true } end,
            IsLocalController = function() return local_player end,
        })
    local comp = make_comp(pc)
    pc._p.NarrativeComponent = comp
    pawn._p.Controller = pc
    W.paths["/Game/Levels/PL.PL:PersistentLevel." .. pc._name] = pc
    return pc, pawn, comp
end

local function msgs(kind, up)
    local out = {}
    for i, e in ipairs(W.out) do
        if e.msg and (e.msg:find("^SDC1|" .. kind .. "|") or e.msg == "SDC1|" .. kind) then
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
local function fresh_modules(values)
    for _, m in ipairs({ "sdc_quests", "sdc_dialogue", "sdc_net", "sdc_ue", "sdc_config", "sdc_log", "sdc_ctx" }) do package.loaded[m] = nil end
    package.loaded["sdc_ctx"] = {
        player_for = function(o)
            local e = ctx_map[o]
            if e then return e end
            local ow = o and o._p and o._p._owner
            return ow and ctx_map[ow] or nil
        end,
        classify = function(o) return ctx_map[o] and "remote" or "local" end,
        -- (sdc_dialogue / sdc_quests take addr from sdc_ctx)
        addr = function(o)
            local ok, a = pcall(function() return o:GetAddress() end)
            if ok then return a end
        end,
    }
    local cfg = require("sdc_config")
    cfg.values = values or {}
    -- the log-only quest hooks (BeginQuest, PendingUpdateList) need debug_probes
    require("sdc_log").probes_enabled = true
    local quests = require("sdc_quests")
    return quests, require("sdc_dialogue"), require("sdc_net")
end

local LIBCDO = { _name = "Default__NarrativeFunctionLibrary" }

-- ============================================================== host
quiet_print("== host (own quests)")
new_world(true)
ctx_map = {}
local quests, dlg, net = fresh_modules()
local hpc, hpawn, hcomp = make_pc(true, { X = 0, Y = 0, Z = 0 })
local rpc, rpawn, rcomp = make_pc(false, { X = 300, Y = 0, Z = 0 })
ctx_map[rpawn] = { pc = rpc, pawn = rpawn }
ctx_map[rpc] = { pc = rpc, pawn = rpawn }
local S = { role = "host", remote_pcs = { rpc } }
dlg.init(S); quests.init(S)
dlg.install(); quests.install()
dlg.register_handlers(); quests.register_handlers()
dlg.host_tick(1000); quests.host_tick(1000)
check(W.hooks[GIVER_SERVER] ~= nil, "host: quest giver OnServerExecuteInteract hook registered")
check(W.hooks[SPAWN_MARKER] and W.hooks[REWARD_XP] and W.hooks[JOURNAL .. ":ForgetQuest"], "host: quest event / journal hooks registered")
local function from_client(msg)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, rpc)
end
from_client("SDC1|QH|1")

-- quest giver: the client presses F (host runs OnServerExecuteInteract)
local giver = new({ "BP_QuestGiver_SettlementOfficer_C", "BP_QuestGiver_C" }, "BP_QuestGiver_SettlementOfficer_C_5",
    { _loc = { X = 400, Y = 0, Z = 0 }, Dialogue = W.intel_dlg, InteractionArgument = "Officer" })
local w1, w2 = param(giver), param(giver)
fire(GNC, param(LIBCDO), w1)
fire(GNC, param(LIBCDO), w2)
check(w1:get() == nil and w2:get() == nil, "host: both of the giver's GetNarrativeComponent calls get None (a client is near)")
fire(GIVER_SERVER, param(giver), param({}), param(rpawn), param({}))
local bd = called(rcomp, "BeginDialogue")
check(bd and bd[2] == W.intel_dlg, "host: giver dialogue started on the client's component (ByActor)")
check(called(hcomp, "BeginDialogue") == nil, "host: not on the host's component")
local c1 = W.cndt[#W.cndt]
check(c1 and c1.comp == rcomp and c1.task == W.interact and c1.arg == "Officer", "host: Quest_Task_InteractWithActor credited to the client's own component")
-- the host presses F with the client near
advance(4)
local w3, w4 = param(giver), param(giver)
fire(GNC, param(LIBCDO), w3); fire(GNC, param(LIBCDO), w4)
fire(GIVER_SERVER, param(giver), param({}), param(hpawn), param({}))
check(called(hcomp, "BeginDialogue") ~= nil and W.cndt[#W.cndt].comp == hcomp, "host: the host's own F: dialogue + data task on the host's component")
-- nobody remote near: the vanilla path
advance(4)
rpawn._p._loc = { X = 90000, Y = 0, Z = 0 }
local w5 = param(giver)
fire(GNC, param(LIBCDO), w5)
check(w5:get() == giver, "host: giver with no remote player near: untouched")
rpawn._p._loc = { X = 300, Y = 0, Z = 0 }

-- bounty: the client buys intel (its dialogue is the officer's)
local mgr = new({ "BP_BountyQuestManager_C" }, "BP_BountyQuestManager_C_1", { _loc = { X = 0, Y = 0, Z = 0 },
    Quests = tarray({ W.bounties[1], W.bounties[2], W.bounties[3] }) })
rcomp._p.CurrentDialogue = new({ "Dialogue_SettlementIntelGiver_C" }, "Dialogue_SettlementIntelGiver_C_1")
local m1, m2 = param(mgr), param(mgr)
fire(GNC, param(LIBCDO), m1)
fire(GNC, param(LIBCDO), m2)
check(m1:get() == nil and m2:get() == nil, "host: bounty manager's GetNarrativeComponent -> None for the client's purchase")
check(n_called(rcomp, "BeginQuest") == 1 and n_called(hcomp, "BeginQuest") == 0, "host: one bounty begun on the client's own log, none on the host's")
check(#msgs("QN", false) == 1 and msgs("QN", false)[1].f[3] == "pinned", "host: QN pinned to the client")
from_client("SDC1|QB")
check(n_called(rcomp, "BeginQuest") == 1 and logged("already given") ~= nil, "host: the client's own QB right after: not a second bounty")
-- all taken
advance(6)
for _, q in ipairs(W.bounties) do rcomp._p._started[q] = true end
from_client("SDC1|QB")
local drop = called(rpawn, "Drop")
check(drop and drop[2]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] == W.laptop, "host: all bounties taken: the laptop dropped at the client")
local qn = msgs("QN", false)
check(qn[#qn].f[3] == "bounty_all", "host: QN bounty_all")
-- the host's own purchase stays vanilla
rcomp._p.CurrentDialogue = nil
hcomp._p.CurrentDialogue = new({ "Dialogue_SettlementIntelGiver_C" }, "Dialogue_SettlementIntelGiver_C_2")
advance(1)
local m3 = param(mgr)
fire(GNC, param(LIBCDO), m3)
check(m3:get() == mgr, "host: the host's own intel purchase: untouched")
hcomp._p.CurrentDialogue = nil

-- start area
local box = new({ "BoxComponent" }, "Box", { _in = {} }, {
    IsOverlappingActor = function(self, a) return self._p._in[a] == true end })
local area = new({ "BP_StartQuestArea_C" }, "BP_StartQuestArea_C_3", { Box = box, Quest = W.lab_quest, _loc = { X = 0, Y = 0, Z = 0 } })
box._p._in[rpawn] = true
local a1 = param(area)
fire(GNC, param(LIBCDO), a1)
check(a1:get() == nil, "host: start area noticed the client (host not inside): None for the host's log")
box._p._in[hpawn] = true
local a2 = param(area)
fire(GNC, param(LIBCDO), a2)
check(a2:get() == area, "host: host inside the area: untouched")
box._p._in[hpawn] = nil
advance(11)
quests.host_tick(1011)
local bq = rcomp._calls[#rcomp._calls]
check(bq[1] == "BeginQuest" and bq[2] == W.lab_quest, "host: the area's quest begun on the client's own log")
fire(NC_BEGINQ, param(rcomp), param(W.lab_quest), param("None"))
check(logged("quests: host: BeginQuest Quest_Dungeon_LaboratoryBunker_C on a client's component") ~= nil, "host: BeginQuest logged with whose component")
local nbq = n_called(rcomp, "BeginQuest")
quests.host_tick(1012)
check(n_called(rcomp, "BeginQuest") == nbq, "host: not begun twice")

-- starting quest for a fresh client character
local fresh = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_2147479999", { _loc = { X = 300, Y = 0, Z = 0 },
    ["SpawnStartingItems?"] = true, Controller = rpc })
ctx_map[fresh] = { pc = rpc, pawn = fresh }
rpc._p.Pawn = fresh
box._p._in[rpawn] = nil
quests.host_tick(1013)
check(n_called(rcomp, "BeginQuest") == nbq, "host: fresh character seen: waits")
advance(6)
quests.host_tick(1019)
local sq = rcomp._calls[#rcomp._calls]
check(sq[1] == "BeginQuest" and sq[2] == W.safezone, "host: fresh client character gets Quest_TheSafeZone on its own log")
local kept = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_2147479888", { _loc = { X = 300, Y = 0, Z = 0 },
    ["SpawnStartingItems?"] = false, Controller = rpc })
rpc._p.Pawn = kept
quests.host_tick(1020); advance(6); quests.host_tick(1026)
check(n_called(rcomp, "BeginQuest") == nbq + 1, "host: a returning character (no starting kit): no starting quest")
rpc._p.Pawn = rpawn

-- data task from the client (generator powered there)
from_client("SDC1|QT|" .. POWER_TASK .. "|LaboratoryBunker|1")
local c2 = W.cndt[#W.cndt]
check(c2 and c2.comp == rcomp and c2.task == W.power and c2.arg == "LaboratoryBunker", "host: QT credited to the client's own component")
-- generator on the host away from the host's character (a client powered it,
-- the host's copy ran Event_TurnOn): the group's progress, the host's own
-- task counts too (before: None, the host's task stuck - the generator was on)
local gen = new({ "BP_LaboratoryGenerator_C" }, "BP_LaboratoryGenerator_C_1", { _loc = { X = 50000, Y = 0, Z = 0 }, QuestArgument = "LaboratoryBunker" })
local g1 = param(gen)
fire(GNC, param(LIBCDO), g1)
check(g1:get() == gen, "host: generator turned on 500 m from the host: untouched (the host's own task counts too)")
gen._p._loc = { X = 100, Y = 0, Z = 0 }
local g2 = param(gen)
fire(GNC, param(LIBCDO), g2)
check(g2:get() == gen, "host: generator at the host: untouched")

-- markers / XP of the client's quest
local hm_old = new({ "BP_QuestMarker_C" }, "BP_QuestMarker_C_2147400500", { Tags = tarray({ "Bounty1" }) },
    { K2_DestroyActor = function(self) self._valid = false end })
local hm_new = new({ "BP_QuestMarker_C" }, "BP_QuestMarker_C_2147300000", { Tags = tarray({ "Bounty1" }) },
    { K2_DestroyActor = function(self) self._valid = false end })
local ev = new({ "Quest_Event_SpawnMarker_C" }, "Event_SpawnMarker", { ActorTag = "Bounty1", Location = { X = 1, Y = 2, Z = 3 }, Text = "Camp" })
fire(SPAWN_MARKER, param(ev), param(rpawn), param(rpc), param(rcomp))
local qm = msgs("QM", false)
check(#qm == 1 and qm[1].pc == rpc and qm[1].f[3] == "a" and qm[1].f[4] == "Bounty1", "host: client's quest marker sent to that client only")
check(hm_new._valid == false and hm_old._valid == true, "host: the copy the client's quest placed in the host's world removed (the newest)")
fire(SPAWN_MARKER, param(ev), param(hpawn), param(hpc), param(hcomp))
check(#msgs("QM", false) == 1, "host: the host's own quest marker is not sent")
local rev = new({ "Quest_Event_RemoveMarker_C" }, "Event_RemoveMarker", { ActorTag = "Bounty1" })
fire(REMOVE_MARKER, param(rev), param(rpawn), param(rpc), param(rcomp))
qm = msgs("QM", false)
check(#qm == 2 and qm[2].f[3] == "d" and qm[2].pc == rpc, "host: marker removal to that client")
local xev = new({ "Quest_Event_RewardPlayerXP_C" }, "Event_RewardPlayerXP", { Amount = 400 })
fire(REWARD_XP, param(xev), param(rpawn), param(rpc), param(rcomp))
fire(REWARD_XP, param(xev), param(hpawn), param(hpc), param(hcomp))
local qx = msgs("QX", false)
check(#qx == 1 and qx[1].pc == rpc and qx[1].f[3] == "400", "host: XP of the client's quest to that client only; the host's own not sent")

-- journal forget, persistence
rcomp._p._started[W.lab_quest] = true
from_client("SDC1|QQ|forget|" .. W.lab_quest._full:match("^%S+%s+(.+)$"))
local fq = called(rcomp, "ForgetQuest")
check(fq and fq[2] == W.lab_quest, "host: QQ forget: ForgetQuest on the client's own component")
check(quests.persist_bind(rpc, "Slot1", "s765", true) == false and called(rcomp, "Load") ~= nil, "host: persist_bind loads (no save yet -> false)")
check(quests.persist_save(rpc, "test") == true and called(rcomp, "Save")[2] == "Slot1_SDQuests_s765", "host: persist_save: Narrative Save to <slot>_SDQuests_<key>")
check(quests.persist_bind(rpc, "Slot1", "s765", true) == true, "host: persist_bind loads the saved quests")
-- 13.11: Narrative refires a finished quest's events when its save loads (the
-- exe's UNarrativeEvent constructor: bRefireOnLoad = true); the start quest's
-- reward ran inside the mod's Load of the client's quests -> QX|300 and a
-- "+300 XP" toast at every join. Not sent now; a real reward later still is.
local function reward300() return new({ "Quest_Event_RewardPlayerXP_C" }, "Event_RewardPlayerXP", { Amount = 300 }) end
local nqx = #msgs("QX", false)
local load0 = rcomp._m.Load
rcomp._m.Load = function(self, name, slot)
    fire(REWARD_XP, param(reward300()), param(rpawn), param(rpc), param(rcomp))
    return load0(self, name, slot)
end
check(quests.persist_bind(rpc, "Slot1", "s765", true) == true and #msgs("QX", false) == nqx
    and logged("reward event (300 XP) ran again while their quests were loaded (Narrative refires quest events on Load): not sent") ~= nil,
    "host: the reward refired inside the Load of the client's quests: not sent")
rcomp._m.Load = load0
advance(1)
fire(REWARD_XP, param(reward300()), param(rpawn), param(rpc), param(rcomp))
check(#msgs("QX", false) == nqx, "host: 1 s after that Load (a deferred refire): not sent either")
advance(2)
fire(REWARD_XP, param(reward300()), param(rpawn), param(rpc), param(rcomp))
check(#msgs("QX", false) == nqx + 1, "host: 3 s later a reward of that quest log is real again: sent")
-- the host's own rewards are noted (sdc_savecheck explains the XP of the game's own quest load)
local hr = quests.host_rewards_since(0)
check(#hr == 1 and hr[1].amount == 400, "host: the host's own reward noted for the save check (" .. #hr .. ")")
-- review of fix 16: with the host's character then (a load's refires run on a
-- new one; sdc_savecheck leaves out the rewards of the character before it)
check(hr[1] and hr[1].pawn == hpawn:GetFullName(), "host: the noted reward carries the host's character (" .. tostring(hr[1] and hr[1].pawn) .. ")")
quests.host_tick(1030)   -- first signature
local nsave = n_called(rcomp, "Save")
rcomp._p.QuestList = tarray({ new({ "Quest" }, "Q1", { QuestCompletion = 1, QuestName = "Camp" }) })
quests.host_tick(1031)
check(n_called(rcomp, "Save") == nsave, "host: quest change: not saved at once")
advance(6)
quests.host_tick(1037)
check(n_called(rcomp, "Save") == nsave + 1, "host: quest change saved 5 s later")
check(quests.persist_delete("Slot1", "s765") == true, "host: persist_delete")
check(not msgs("QS", false)[1], "host: no group QS in the own-quests mode")

-- ============================================================== client
quiet_print("== client")
new_world(false)
LOG = {}
ctx_map = {}
quests, dlg, net = fresh_modules()
local cpc, cpawn, ccomp = make_pc(true, { X = 0, Y = 0, Z = 0 })
S = { role = "client", remote_pcs = {} }
dlg.init(S); quests.init(S)
dlg.install(); quests.install()
dlg.register_handlers(); quests.register_handlers()
dlg.client_tick(2000, cpc, cpawn); quests.client_tick(2000, cpc, cpawn)
local function deliver(msg)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, cpc)
end
local cmgr = new({ "BP_BountyQuestManager_C" }, "BP_BountyQuestManager_C_1", {})
fire(GNC, param(LIBCDO), param(cmgr))
fire(GNC, param(LIBCDO), param(cmgr))
check(#msgs("QB", true) == 1, "client: the bounty event ran here -> one QB to the host")
local cgen = new({ "BP_LaboratoryGenerator_C" }, "BP_LaboratoryGenerator_C_1", { QuestArgument = "LaboratoryBunker" })
fire(GNC, param(LIBCDO), param(cgen))
local qt = msgs("QT", true)
check(#qt == 1 and qt[1].f[3] == POWER_TASK and qt[1].f[4] == "LaboratoryBunker", "client: generator powered here -> QT with the data task")
-- XP: no local reward event -> added after the delay
deliver("SDC1|QX|400|Camp")
check(called(cpc._p.LevellingComponent, "AddXP") == nil, "client: QX waits")
run_delayed()
local ax = called(cpc._p.LevellingComponent, "AddXP")
check(ax and ax[2] == 400, "client: QX added on the own LevellingComponent")
-- XP: the reward event ran here too -> not added again
local cxev = new({ "Quest_Event_RewardPlayerXP_C" }, "Event_RewardPlayerXP", { Amount = 300 })
fire(REWARD_XP, param(cxev), param(cpawn), param(cpc), param(ccomp))
deliver("SDC1|QX|300|SafeZone")
run_delayed()
check(n_called(cpc._p.LevellingComponent, "AddXP") == 1 and logged("ran here already") ~= nil, "client: reward event ran here: QX not added twice")
-- markers: our own quest placed one already -> no second
new({ "BP_QuestMarker_C" }, "BP_QuestMarker_C_2147411111", { Tags = tarray({ "Bounty2" }) })
deliver("SDC1|QM|a|Bounty2|1|2|3||Camp|1|0|0|1|0")
check(#W.spawned == 0, "client: marker placed here by the own quest already: not spawned again")
deliver("SDC1|QM|a|Bounty3|1|2|3||Camp|1|0|0|1|0")
check(#W.spawned == 1, "client: marker from the host spawned")
deliver("SDC1|QM|BP_MilitaryTrader_C|1200|0|0|5")
check(#W.spawned == 1, "client: a stray QM (not a/d) is ignored")
-- journal forget
local jq = new({ "Quest_Dungeon_LaboratoryBunker_C" }, "Quest_LB")
jq._cls = W.lab_quest
fire(JOURNAL .. ":Show Quest", param(new({ "Journal_QuestsUI_C" }, "J")), param(jq))
fire(JOURNAL .. ":ForgetQuest", param(new({ "Journal_QuestsUI_C" }, "J")))
local qq = msgs("QQ", true)
check(#qq == 1 and qq[1].f[3] == "forget" and qq[1].f[4] == "/Game/Quests/Quests/Dungeon/Quest_Dungeon_LaboratoryBunker.Quest_Dungeon_LaboratoryBunker_C",
    "client: journal forget -> QQ with the quest class")
deliver("SDC1|QN|pinned")
check(logged("Quest pinned to your map") ~= nil, "client: QN pinned shown")
ccomp._p.PendingUpdateList = tarray({ { UpdateType = 2, QuestClass = W.bounties[1], Payload = "" },
    { UpdateType = 6, QuestClass = W.bounties[1], Payload = "Kill Bandits" } })
fire(NC_ONREP, param(ccomp))
check(logged("from the host, on this player's own quest log: quest begun Quest_Bounty_1_C") ~= nil
    and logged("task progress Quest_Bounty_1_C (Kill Bandits)") ~= nil, "client: the host's quest updates logged as they replicate")
local nlog = #LOG
fire(NC_ONREP, param(ccomp))
check(#LOG == nlog, "client: the same updates again: not logged twice")

-- ============================================================== host, group design
quiet_print("== host (group design)")
new_world(true)
LOG = {}
ctx_map = {}
quests, dlg, net = fresh_modules({ quest_own = false })
hpc, hpawn, hcomp = make_pc(true, { X = 0, Y = 0, Z = 0 })
rpc, rpawn, rcomp = make_pc(false, { X = 300, Y = 0, Z = 0 })
ctx_map[rpawn] = { pc = rpc, pawn = rpawn }
ctx_map[rpc] = { pc = rpc, pawn = rpawn }
S = { role = "host", remote_pcs = { rpc } }
dlg.init(S); quests.init(S)
dlg.install(); quests.install()
dlg.register_handlers(); quests.register_handlers()
dlg.host_tick(3000); quests.host_tick(3000)
local gx = new({ "Quest_Event_RewardPlayerXP_C" }, "Event_RewardPlayerXP", { Amount = 300 })
fire(REWARD_XP, param(gx), param(hpawn), param(hpc), param(hcomp))
check(#msgs("QX", false) == 1 and msgs("QX", false)[1].pc == rpc, "group: the host's quest XP to every client")
local kind, fields = net.decode("SDC1|QT|" .. POWER_TASK .. "|LaboratoryBunker|1")
net.handlers[kind](fields, rpc)
check(W.cndt[#W.cndt].comp == hcomp, "group: QT credited to the host's (group) log")
local gm = new({ "BP_BountyQuestManager_C" }, "BP_BountyQuestManager_C_1", { Quests = tarray({}) })
rcomp._p.CurrentDialogue = new({ "Dialogue_SettlementIntelGiver_C" }, "D")
local gp = param(gm)
fire(GNC, param(LIBCDO), gp)
check(gp:get() == gm, "group: bounty manager untouched")
check(#msgs("QS", false) == 1, "group: QS mirror sent")
-- the list is told again only as the verify (120 s), not every 30 s
quests.host_tick(3060)
check(#msgs("QS", false) == 1, "group: unchanged after 60 s: QS not repeated")
quests.host_tick(3125)
check(#msgs("QS", false) == 2, "group: the verify after 120 s: QS again")

quiet_print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
