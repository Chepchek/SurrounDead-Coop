-- Mock test: shared laptop bounties (quest_own + quest_bounty_shared). A
-- laptop bounty stays its buyer's quest; the other players get its marker
-- (QM, the host's copy stays), its tasks (QG / the host's own tracker), the
-- go-to task done by anyone near, and the reward's XP. The harness (fake UE
-- objects, real sdc_quests / sdc_dialogue / sdc_net / sdc_ue / sdc_config /
-- sdc_log) is mock_quests.lua's, except that a property the object does not
-- have reads as a TrivialObject, as in UE4SS 3.0.1 (logs of 2026-11-11 / 12:
-- the event's QuestState passed for its quest, "TrivialObject: <address>"
-- logged and sent as the quest's name, no bounty recognised).
-- usage: lua mock_quests_bounty_shared.lua <scripts dir>
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
-- UE4SS 3.0.1: a missing property is not nil but a TrivialObject (no methods)
local Trivial = { __tostring = function(t) return string.format("TrivialObject: %016X", t._a) end }
local trivial_addr = 0x1AF5CDE0000
local function trivial()
    trivial_addr = trivial_addr + 0x48
    return setmetatable({ _a = trivial_addr }, Trivial)
end
function Obj:GetPropertyValue(n)
    local v = self._p[n]
    if v == nil then return trivial() end
    return v
end
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
    local quests = require("sdc_quests")
    return quests, require("sdc_dialogue"), require("sdc_net")
end

local LIBCDO = { _name = "Default__NarrativeFunctionLibrary" }

-- ============================================================== helpers
local function bounty(cls_name, qname, tasks)
    local tl = {}
    for _, t in ipairs(tasks) do
        tl[#tl + 1] = new({ t.cls or "Quest_Task_SpawnNPCsToKill_C", "NarrativeTask" }, "Task_" .. next_addr,
            { CurrentProgress = t.cur, RequiredQuantity = t.req, DescriptionOverride = t.desc,
              GoalLocation = t.goal, DistanceTolerance = t.tol },
            { IsComplete = function(self) return self._p.CurrentProgress >= self._p.RequiredQuantity end,
              CompleteTask = function(self) record("CompleteTask")(self); self._p.CurrentProgress = self._p.RequiredQuantity end })
    end
    local branch = new({ "QuestBranch" }, "QuestBranch_" .. next_addr, { QuestTasks = tarray(tl) })
    local state = new({ "QuestState" }, "QuestState_" .. next_addr, { Branches = tarray({ branch }) })
    local q = new({ cls_name, "Quest" }, cls_name .. "_" .. next_addr,
        { QuestCompletion = 1, QuestName = qname, CurrentState = state })
    state._m.GetOuter = function() return q end
    branch._m.GetOuter = function() return state end
    return q, tl, state
end
-- an event object of that quest (outer chain event -> state -> quest)
local function quest_event(chain, state, props)
    return new(chain, chain[1] .. "_" .. next_addr, props, { GetOuter = function() return state end })
end
local function world_marker(tag)
    return new({ "BP_QuestMarker_C" }, "BP_QuestMarker_C_" .. (2147300000 - next_addr), { Tags = tarray({ tag }) },
        { K2_DestroyActor = function(self) self._valid = false end })
end
local function last(kind, pc)
    local l = msgs(kind, false)
    for i = #l, 1, -1 do if l[i].pc == pc then return l[i] end end
    return nil
end

-- ============================================================== host
quiet_print("== host: shared laptop bounties")
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
quests.host_tick(1000)
check(W.hooks[SPAWN_MARKER] and W.hooks[REMOVE_MARKER] and W.hooks[REWARD_XP], "host: marker / reward hooks in")

print("H1. the host bought the intel: its bounty")
local TAG1 = "Quest_Bounty_EliminateCoyotes001"
local q1, t1, st1 = bounty("Quest_Bounty_EliminateCoyotes001_C", "Coyote Checkpoint", {
    { desc = "Go to the checkpoint", cur = 0, req = 1, cls = "BPT_GoToLocation_C", goal = { X = 50000, Y = 0, Z = 0 }, tol = 2000 },
    { desc = "Kill the coyotes", cur = 0, req = 5 },
})
hcomp._p.QuestList = tarray({ q1 })
local hm1 = world_marker(TAG1)   -- the copy the quest's event placed in the host's world
local ev1 = quest_event({ "Quest_Event_SpawnMarker_C" }, st1, { ActorTag = TAG1, Location = { X = 50000, Y = 0, Z = 0 }, Text = "Coyote Checkpoint" })
fire(SPAWN_MARKER, param(ev1), param(hpawn), param(hpc), param(hcomp))
local qm = last("QM", rpc)
check(qm and qm.f[3] == "a" and qm.f[4] == TAG1 and qm.f[5] == "50000", "host: the host's bounty marker sent to the client")
check(hm1._valid == true, "host: the host's own copy of the marker stays")
quests.host_tick(1001)
local qg = last("QG", rpc)
check(qg and qg.msg:find("Coyote Checkpoint~Go to the checkpoint^0^1^~Kill the coyotes^0^5^", 1, true) ~= nil,
    "host: QG to the client: the host's bounty with its tasks")
local nqg = #msgs("QG", false)
quests.host_tick(1002)
check(#msgs("QG", false) == nqg, "host: nothing changed: no QG again")
-- the client reaches the go-to goal: the host's task is done for the group
rpawn._p._loc = { X = 49000, Y = 300, Z = 0 }
quests.host_tick(1003)
check(called(t1[1], "CompleteTask") ~= nil, "host: the client at the goal completes the host's go-to task")
-- a kill by anyone: progress (the game's AIDeath counter)
t1[2]._p.CurrentProgress = 3
quests.host_tick(1004)
qg = last("QG", rpc)
check(qg and qg.msg:find("Go to the checkpoint^1^1^d~Kill the coyotes^3^5^", 1, true) ~= nil, "host: progress goes out in QG")
-- reward: the host's own XP is the event's; the client gets QX
local xev1 = quest_event({ "Quest_Event_RewardPlayerXP_C" }, st1, { Amount = 300 })
fire(REWARD_XP, param(xev1), param(hpawn), param(hpc), param(hcomp))
local qx = last("QX", rpc)
check(qx and qx.f[3] == "300" and qx.f[4] == "Coyote Checkpoint", "host: the bounty's XP to the client too")
check(logged("the host's laptop bounty 'Coyote Checkpoint' rewards 300 XP: shared") ~= nil,
    "host: the reward recognised as the host's laptop bounty, logged with the quest's name")
check(called(hpc._p.LevellingComponent, "AddXP") == nil, "host: the host's own bounty: its XP stays the game's (not added twice)")
local rev1 = quest_event({ "Quest_Event_RemoveMarker_C" }, st1, { ActorTag = TAG1 })
fire(REMOVE_MARKER, param(rev1), param(hpawn), param(hpc), param(hcomp))
qm = last("QM", rpc)
check(qm and qm.f[3] == "d" and qm.f[4] == TAG1, "host: the marker's removal to the client")
hcomp._p.QuestList = tarray({})   -- NE_ForgetQuest
quests.host_tick(1005)
qg = last("QG", rpc)
check(qg and qg.msg == "SDC1|QG", "host: the bounty left the log: an empty QG")

print("H2. the client bought the intel: its bounty")
local TAG2 = "Quest_Bounty_ClassifiedContainer001"
local q2, t2, st2 = bounty("Quest_Bounty_ClassifiedContainer001_C", "Classified case", {
    { desc = "Kill the guards", cur = 0, req = 3 },
})
rcomp._p.QuestList = tarray({ q2 })
local hm2 = world_marker(TAG2)
local ev2 = quest_event({ "Quest_Event_SpawnMarker_C" }, st2, { ActorTag = TAG2, Location = { X = 7000, Y = 8000, Z = 100 }, Text = "Case" })
fire(SPAWN_MARKER, param(ev2), param(rpawn), param(rpc), param(rcomp))
qm = last("QM", rpc)
check(qm and qm.f[3] == "a" and qm.f[4] == TAG2, "host: the client's bounty marker sent to the client")
check(hm2._valid == true, "host: its copy in the host's world stays (the host sees it)")
local nqg2 = #msgs("QG", false)
quests.host_tick(1006)
check(#msgs("QG", false) == nqg2, "host: the client's own bounty is not sent back to it")
check(logged("shared laptop bounty 'Classified case'") ~= nil, "host: the client's bounty shown on the host's screen")
t2[1]._p.CurrentProgress = 2
quests.host_tick(1007)
check(logged("shared bounty task progress 'Kill the guards' 2/3") ~= nil, "host: its progress shown on the host's screen")
local xev2 = quest_event({ "Quest_Event_RewardPlayerXP_C" }, st2, { Amount = 500 })
fire(REWARD_XP, param(xev2), param(rpawn), param(rpc), param(rcomp))
qx = last("QX", rpc)
check(qx and qx.f[3] == "500", "host: the client's bounty XP to the client")
local ax = called(hpc._p.LevellingComponent, "AddXP")
check(ax and ax[2] == 500, "host: the host gets the client's bounty XP too")
local lines = {}
quests.status_lines(lines)
check(table.concat(lines, "\n"):find("Общие задания с ноутбуков других игроков: 1", 1, true) ~= nil, "host: F7 panel lists the shared bounty")

print("H3. not a bounty: the client's own quest stays its own")
local _, _, st3 = bounty("Quest_Dungeon_LaboratoryBunker_C", "Lab", { { desc = "Find the lab", cur = 0, req = 1 } })
local hm3 = world_marker("Lab")
local ev3 = quest_event({ "Quest_Event_SpawnMarker_C" }, st3, { ActorTag = "Lab", Location = { X = 1, Y = 2, Z = 3 }, Text = "Lab" })
fire(SPAWN_MARKER, param(ev3), param(rpawn), param(rpc), param(rcomp))
check(hm3._valid == false, "host: a client's other quest marker: the host's copy goes (as before)")
local xev3 = quest_event({ "Quest_Event_RewardPlayerXP_C" }, st3, { Amount = 50 })
fire(REWARD_XP, param(xev3), param(rpawn), param(rpc), param(rcomp))
check(n_called(hpc._p.LevellingComponent, "AddXP") == 1, "host: a client's other quest XP: not the host's")

print("H4. a joiner gets the shared markers")
local jpc = make_pc(false, { X = 900, Y = 0, Z = 0 })
S.remote_pcs = { rpc, jpc }
quests.host_tick(1008)
local jm = {}
for _, m in ipairs(msgs("QM", false)) do if m.pc == jpc and m.f[3] == "a" then jm[m.f[4]] = true end end
check(jm[TAG2] == true and not jm["Lab"], "host: the joiner gets the shared bounty marker (not the other quest's)")
local jqg = last("QG", jpc)
check(jqg and jqg.msg:find("Classified case~", 1, true) ~= nil, "host: the joiner's QG has the other client's bounty")

local function no_trivial(where)
    local bad
    for _, l in ipairs(LOG) do if l:find("TrivialObject", 1, true) then bad = l break end end
    for _, e in ipairs(W.out) do if not bad and e.msg and e.msg:find("TrivialObject", 1, true) then bad = e.msg end end
    check(bad == nil, where .. ": no 'TrivialObject' in the log or the messages" .. (bad and (" (" .. bad:gsub("%s+$", "") .. ")") or ""))
end
no_trivial("host")

print("H5. a quest name with no text: the class name")
local _, _, st5 = bounty("Quest_Bounty_EliminateCoyotes003_C", "", { { desc = "Kill the coyotes", cur = 0, req = 5 } })
local xev5 = quest_event({ "Quest_Event_RewardPlayerXP_C" }, st5, { Amount = 300 })
fire(REWARD_XP, param(xev5), param(rpawn), param(rpc), param(rcomp))
qx = last("QX", rpc)
check(qx and qx.f[4] == "Quest_Bounty_EliminateCoyotes003", "host: no QuestName text: the quest's class name in QX")
-- (pcall: the checks also run against a build without these helpers)
local function try(f) local ok, v = pcall(f); return ok and v end
check(try(function() return quests._quest_title(nil) == "" end), "quest_title(nil) is empty")

print("U. sdc_ue and UE4SS's missing property")
local ue = require("sdc_ue")
local tv = st5:GetPropertyValue("QuestName")
check(tostring(tv):find("^TrivialObject: ") ~= nil, "mock: a state's QuestName reads as a TrivialObject (as UE4SS)")
check(ue.str(tv) == "", "ue.str: a TrivialObject is no text")
check(try(function() return ue.missing(tv) and ue.missing(nil) and not ue.missing("") and not ue.missing(false)
    and not ue.missing(st5) end), "ue.missing: nil and TrivialObject only")
check(try(function() return ue.has_prop(q1, "QuestName") and not ue.has_prop(st5, "QuestName")
    and not ue.has_prop(nil, "QuestName") end), "ue.has_prop: the quest has QuestName, its state not")
check(ue.str(q1:GetPropertyValue("QuestName")) == "Coyote Checkpoint" and ue.str(42) == "42", "ue.str: real values unchanged")

-- ============================================================== off
quiet_print("== host: quest_bounty_shared off")
new_world(true)
ctx_map = {}
LOG = {}
quests, dlg, net = fresh_modules({ quest_bounty_shared = false })
hpc, hpawn, hcomp = make_pc(true, { X = 0, Y = 0, Z = 0 })
rpc, rpawn, rcomp = make_pc(false, { X = 300, Y = 0, Z = 0 })
ctx_map[rpawn] = { pc = rpc, pawn = rpawn }
ctx_map[rpc] = { pc = rpc, pawn = rpawn }
S = { role = "host", remote_pcs = { rpc } }
dlg.init(S); quests.init(S)
dlg.install(); quests.install()
dlg.register_handlers(); quests.register_handlers()
quests.host_tick(1000)
local q4, _, st4 = bounty("Quest_Bounty_EliminateCoyotes001_C", "Coyote Checkpoint", { { desc = "Kill the coyotes", cur = 0, req = 5 } })
hcomp._p.QuestList = tarray({ q4 })
local ev4 = quest_event({ "Quest_Event_SpawnMarker_C" }, st4, { ActorTag = TAG1, Location = { X = 5, Y = 6, Z = 7 }, Text = "C" })
fire(SPAWN_MARKER, param(ev4), param(hpawn), param(hpc), param(hcomp))
quests.host_tick(1001)
check(#msgs("QM", false) == 0 and #msgs("QG", false) == 0, "off: the host's bounty stays the host's (no QM, no QG)")

-- ============================================================== client
quiet_print("== client: the other players' bounties")
new_world(false)
LOG = {}
ctx_map = {}
quests, dlg, net = fresh_modules()
local cpc, cpawn = make_pc(true, { X = 0, Y = 0, Z = 0 })
S = { role = "client", remote_pcs = {} }
dlg.init(S); quests.init(S)
dlg.install(); quests.install()
dlg.register_handlers(); quests.register_handlers()
quests.client_tick(2000, cpc, cpawn)
local function deliver(msg)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, cpc)
end
deliver("SDC1|QG|Coyote Checkpoint~Kill the coyotes^0^5^")
check(logged("shared laptop bounty 'Coyote Checkpoint'") ~= nil, "client: the host's bounty shown (notice + tracker)")
deliver("SDC1|QG|Coyote Checkpoint~Kill the coyotes^3^5^")
check(logged("shared bounty task progress 'Kill the coyotes' 3/5") ~= nil, "client: its progress shown")
lines = {}
quests.status_lines(lines)
check(table.concat(lines, "\n"):find("Coyote Checkpoint", 1, true) ~= nil, "client: F7 panel lists it")
deliver("SDC1|QG")
check(logged("shared laptop bounty 'Coyote Checkpoint' left its owner's log") ~= nil, "client: done / gone: shown")
-- the client's own quest's reward event ran here (the 2026-11-12 log line)
local _, _, cst = bounty("Quest_TheSafeZone_C", "The Safe Zone", { { desc = "Go to The Valley Safe Zone", cur = 1, req = 1 } })
local cxev = quest_event({ "Quest_Event_RewardPlayerXP_C" }, cst, { Amount = 300 })
fire(REWARD_XP, param(cxev), param(cpawn), param(cpc), param(cpc._p.NarrativeComponent))
check(logged("quests: client: quest 'The Safe Zone' reward event ran here (+300 XP") ~= nil,
    "client: the reward event logged with the quest's name")
deliver("SDC1|QX|300|The Safe Zone")
run_delayed()
check(logged("quest 'The Safe Zone' +300 XP from the host: the reward event ran here already") ~= nil,
    "client: the host's QX for it: same name, not added again")
no_trivial("client")

quiet_print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
