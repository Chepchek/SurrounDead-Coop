-- SDCoop: NPC dialogues (traders, quest givers) and trading for every
-- player, and the client's Narrative HUD.
--
-- How the game does it (work\re\pseudo):
--   * Traders: BP_MasterTrader.OnExecuteInteract (@5682 CurrentActor =
--     InteractingActor, @4909 GetNarrativeComponent(self).BeginDialogue,
--     @5050 CharacterMovement.DisableMovement) and BP_TraderMaster (@2769 /
--     @2455; BP_MilitaryTrader, BP_ShakesConesTrader, BP_VehicleTrader... are
--     its children). OnExecuteInteract comes from BP_JigHelperComp.TryInteract
--     (@2065) = the F key, i.e. it runs on the machine that pressed F.
--   * Quest givers: BP_QuestGiver.OnServerExecuteInteract (host, after
--     SERVER_ForwardInteract) @1329 GetNarrativeComponent(self).BeginDialogue,
--     then @1109 GetNarrativeComponent(self).CompleteNarrativeDataTask.
--   * NarrativeFunctionLibrary::GetNarrativeComponent (exe 0x1448575c0) is
--     FindComponent(UGameplayStatics::GetPlayerController(ctx, 0)) as a direct
--     native call: sdc_ctx never sees it, the host always gets ITS component.
--     A null ctx is safe: GetWorldFromContextObject(null) -> null
--     (0x14448ea60), FindComponent(null) -> null (0x1448575e9).
--   * UNarrativeComponent::BeginDialogue is BlueprintAuthorityOnly (its
--     FunctionFlags in the exe's registration data: 0x04020404). The
--     Blueprint VM asks the owner (AActor::GetFunctionCallspace) and ABSORBS
--     such a call on a machine without authority: on a client the trader's
--     GetNarrativeComponent(self).BeginDialogue never reaches the native
--     function, no hook on it fires, nothing happens (0.6.46 session: 15
--     traced GetNarrativeComponent calls from three traders' F on the client,
--     not one BeginDialogue there, nothing on the host). On the host
--     (0x144851ec0) it starts the dialogue and sends ClientBeginDialogue to
--     the component's client.
--     Choices: TrySelectDialogueOption -> ServerSelectDialogueOption; exit:
--     ServerTryExitDialogue.
--   * The HUD that shows dialogues (BP_CustomNarrativeDefaultUI) is created
--     only in BP_PlayerController.ReceivePossess (@7972-8066), which never
--     runs on a client.
--   * Trade window: the trader dialogue's event Quest_Event_OnInteractNPC
--     reads Target.BP_JigHelperComp.InteractExecutedActor (set by TryInteract
--     on the machine that pressed F) and calls its
--     OnExecuteInteractDialogue(Target): BP_TraderMaster @1684 /
--     BP_MasterTrader @4435 SetupInventoryWidget, the player's
--     AddJigWidgetToContent and RequestServerData(trader's Jig component) ->
--     SERVER_RequestData on the player's own component -> the host answers
--     CLIENT_ContainerDataResponse with the trader's stock (sdc_stations logs
--     both ends).
--   * Buy / sell: SERVER_RequestMoveItemToAnotherComp on the player's own
--     component -> Handle Comp to Comp Move (host): TakeMoney +
--     CLIENT_UpdateCounts (buy), the trader's money in
--     CheckVendorAmountOfMoney, the coins added + CLIENT_NewItemAdded (sale),
--     the item moved (CLIENT_AddNewItem; the trader's stock through its MC_*
--     multicasts). The host holds every inventory; EMS saves the static
--     trader (ActorPreSave: its containers + CurrencyAmount), sdc_persist the
--     client's character. Wandering traders are not saved (as in the game).
--   * The trader's money (BP_JigComponent.VendorCurrentCurrencyAmount, the
--     "Currency:" line of W_TraderUI.GetText through JigComp_GetVendorInfo)
--     is NOT replicated: each machine rolls its own in BeginPlay.
--   * BP_MilitaryTraderSpawner / BP_ShakesConesSpawner are level actors that
--     do not replicate (BP_MasterObject) and spawn their trader in BeginPlay
--     without an authority check: a client had its own trader (role
--     Authority, spawned there) besides the host's replicated one (0.6.46:
--     the client's BP_ShakesConesTrader_C_2147478812 was made at its map
--     load 1.4 km away from it; the host's copy _2147229593 came later).
--     The host does not know such a copy: its window stays empty.
--
--   * Every NPC conversation in the game (the whole pak scanned for
--     BeginDialogue): BP_TraderMaster (+ its 10 traders), BP_MasterTrader
--     (wandering) and BP_QuestGiver (+ BP_QuestGiver_SettlementOfficer, the
--     only quest giver: Dialogue_SettlementIntelGiver). Radio / notes are
--     plain widgets, not Narrative.
--
-- What this module does:
--   host   GetNarrativeComponent pre-hook: when a trader / quest giver asks
--          on behalf of a remote player, its WorldContextObject is set to nil
--          (the Blueprint gets None and skips the host's BeginDialogue), and
--          next tick the dialogue starts on that player's own component.
--          UE4SS cannot null a class parameter (push_classproperty ignores
--          nil), and Blueprint hooks are post-only, hence this hook.
--          Quest givers with a remote player near: both of the giver's
--          GetNarrativeComponent calls get None and its OnServerExecuteInteract
--          post-hook starts the dialogue and credits the data task
--          (Quest_Task_InteractWithActor) on ByActor's component - exactly
--          the player who pressed F, the host included. Quest objects
--          (BP_BountyQuestManager, BP_StartQuestArea, BP_LaboratoryGenerator)
--          go to sdc_quests (M.quest_gnc).
--   client F on a trader: the GetNarrativeComponent pre-hook (the only hook
--          that fires there) sees the trader whose CurrentActor is this
--          player's character and asks the host (QD); the host starts the
--          dialogue on the client's component (the game's server path,
--          ClientBeginDialogue).
--   host   a wandering trader stops while a client talks / trades with it
--          (its own DisableMovement) and walks again when the client closes
--          the trade window (QE), walks away or leaves - unless another
--          client or the host's own player (its CurrentActor) still trades
--          with it; the host closing its own trade (the game lets it walk)
--          stops it again for a client still trading.
--   client creates the Narrative HUD the way the game does (Create, set
--          NarrativeComponent, AddToViewport(0)) and tells the host (QH).
--          The host routes dialogues only to clients that reported a HUD.
--   both   trade event: if the trade window did not open on the client by
--          itself, the host's copy of the event signals the client (QV),
--          which calls the trader's OnExecuteInteractDialogue itself.
--   host   the trader's money goes to the clients near it (QTM) when a
--          client's dialogue starts and after every trade (Handle Comp to
--          Comp Move / CheckVendorAmountOfMoney); the client writes it into
--          its copy of the trader's component, so its trade window shows the
--          host's (authoritative) value.
--   client the trader spawners' own spawn is blocked (the shared
--          BeginDeferredActorSpawnFromClass pre-hook swaps the class for
--          UObject, as sdc_world does for camps); a trader this machine made
--          anyway (authority + runtime-spawned) is removed.
--   both   "dlg-trace" / "dlg:" / "trade:" log lines for every step.
--
-- Messages: client -> host  QD|<dialogue class full name>|x|y|z   QH|1
--                           QE|<trader class>|x|y|z
--           host -> client  QV   QTM|<trader class>|x|y|z|<money>
--                           QF|nonpc|start|nochar|vmoney (shown in Russian)
--
-- Every hook callback is wrapped in pcall and returns nothing; objects are
-- re-validated right before use; nothing is kept across ticks except our own
-- HUD widget (re-validated, dropped untouched on a level change) and class
-- objects.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local consume = require("sdc_consume")   -- shared helpers (param, guid_str)

local M = {}

local S   -- sdc_session.state

-- ---------------------------------------------------------------------------
-- Game assets
-- ---------------------------------------------------------------------------

local GNC   = "/Script/Narrative.NarrativeFunctionLibrary:GetNarrativeComponent"
local BEGIN = "/Script/Narrative.NarrativeComponent:BeginDialogue"
local CLIENT_BEGIN = "/Script/Narrative.NarrativeComponent:ClientBeginDialogue"
local CLIENT_EXIT = "/Script/Narrative.NarrativeComponent:ClientExitDialogue"
local SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local NOT_AN_ACTOR = "/Script/CoreUObject.Object"
local TRADE_EVENT_CLASS = "/Game/Quests/Events/Quest_Event_OnInteractNPC.Quest_Event_OnInteractNPC_C"
local TRADE_EVENT_FN = TRADE_EVENT_CLASS .. ":ExecuteEvent"
local HUD_CLASS = "/Game/Quests/UI/BP_CustomNarrativeDefaultUI.BP_CustomNarrativeDefaultUI_C"
local HUD_CLASS_NAME = "BP_CustomNarrativeDefaultUI_C"
local JIG_CLASS = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local WANDERER = "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C"

local NPC_CLASSES = {
    { path = WANDERER, short = "BP_MasterTrader_C", kind = "trader" },
    { path = "/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C", short = "BP_TraderMaster_C", kind = "trader" },
    { path = "/Game/Quests/Blueprints/NPCs/BP_QuestGiver.BP_QuestGiver_C", short = "BP_QuestGiver_C", kind = "giver" },
}
local STATIC_TRADER = "BP_TraderMaster_C"
-- level spawners (not replicated) that spawn a replicated trader on every machine
local TRADER_SPAWNERS = { BP_MilitaryTraderSpawner_C = true, BP_ShakesConesSpawner_C = true }

local GIVER_RANGE = 550      -- BP_QuestGiver accepts ByActor closer than 500 (@1576-1694)
local REQUEST_RANGE = 900    -- client request: NPC within this of the client's character
local HANDLED_WINDOW = 0.5   -- s: later GetNarrativeComponent calls of the same NPC stay on the host
local MONEY_RANGE = 3000     -- cm: QM to the remote players this close to the trader
local MATCH_RANGE = 600      -- cm: client: its copy of the trader within this of the host's position
local HOLD_RANGE = 2000      -- cm: a held wandering trader walks again when its client is this far
local HOLD_MAX_S = 600
local GHOST_PASS_S = 10      -- client: look for traders only this machine has

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local addr = ctx.addr
local pget = consume.param

local function role()
    return S and S.role or "unknown"
end

local throttle = {}
local function trace(key, msg, ...)
    if not cfg.get("quest_trace") then return end
    local now = os.clock()
    if throttle[key] and now - throttle[key] < 2 then return end
    throttle[key] = now
    log.info("dlg-trace: " .. msg, ...)
end

-- On-screen notice (Russian) + the English log line; the same notice at most
-- every 10 s. The widget work runs on the next game-thread task, never
-- inside the hook that noticed it.
local toast_at = {}
local function notice(key, ru, en)
    local now = os.clock()
    if toast_at[key] and now - toast_at[key] < 10 then
        log.info("%s", en)
        return
    end
    toast_at[key] = now
    ue.game_thread("dlg-notice", function() log.toast(ru, "warn", 8, en) end)
end

local function f0(v) return string.format("%.0f", v) end

-- class objects, looked up again every 10 s while missing (not loaded yet)
local class_cache, class_tried = {}, {}
local function npc_class(i)
    local c = class_cache[i]
    if ue.valid(c) then return c end
    class_cache[i] = nil
    local now = os.clock()
    if class_tried[i] and now - class_tried[i] < 10 then return nil end
    class_tried[i] = now
    c = ue.find_object(NPC_CLASSES[i].path)
    class_cache[i] = c
    return c
end

-- "trader" / "giver" / nil, and whether every NPC class could be tested
local function npc_kind_of(o)
    local all = true
    for i, spec in ipairs(NPC_CLASSES) do
        local c = npc_class(i)
        if c then
            local ok, r = pcall(function() return o:IsA(c) end)
            if ok and r == true then return spec.kind, all end
        else
            all = false
        end
    end
    return nil, all
end

-- GetNarrativeComponent runs ~600 times a second on a host (quest journal UI,
-- characters); only traders / quest givers matter. The answer depends on the
-- object's class only, so it is kept per class object (address): two engine
-- calls instead of three IsA tests. A "no" is kept only when every NPC class
-- was loaded (an unloaded one cannot be tested); the table is dropped every
-- 30 s (classes outlive objects, but a level change can unload some).
local function o_class(o) return o:GetClass() end
local function o_addr(o) return o:GetAddress() end
local kind_by_class, kind_at = {}, 0
-- ue.valid first: a hook parameter with no object (GetNarrativeComponent's
-- Target, a spawn's WorldContextObject) or an empty InteractExecutedActor is
-- a null object, not nil, and GetClass on it crashes the game (pcall cannot
-- catch it; the host's ApplyDamage crash of 2026-11-13).
local function class_key(o)
    if not ue.valid(o) then return nil end
    local ok, c = pcall(o_class, o)
    if not ok or c == nil then return nil end
    local oka, a = pcall(o_addr, c)
    if oka and type(a) == "number" and a ~= 0 then return a end
    return nil
end

-- Quest objects that ask GetNarrativeComponent(self) for player 0's
-- component (sdc_quests handles them, M.quest_gnc): by exact class name,
-- decided once per class (other_by_class) whatever is loaded.
local OTHER_KINDS = {
    BP_BountyQuestManager_C = "bounty",     -- laptop bounty: BeginQuest (@436-457)
    BP_StartQuestArea_C = "area",           -- quest start area: BeginQuest (@664-685, @1031-1052)
    BP_LaboratoryGenerator_C = "generator", -- CompleteNarrativeDataTask (@1702-1723)
}
local other_by_class = {}   -- [class address] = kind / false

local function npc_kind(o)
    if o == nil then return nil end
    local now = os.clock()
    if now - kind_at > 30 then kind_by_class, other_by_class, kind_at = {}, {}, now end
    local ck = class_key(o)
    if ck then
        local k = kind_by_class[ck]
        if k ~= nil then return k or nil end
    end
    if not ue.valid(o) then return nil end
    local other = ck and other_by_class[ck]
    if other == nil then
        other = OTHER_KINDS[ue.class_name(o)] or false
        if ck then other_by_class[ck] = other end
    end
    if other then
        if ck then kind_by_class[ck] = other end
        return other
    end
    local kind, all = npc_kind_of(o)
    if ck and (kind or all) then kind_by_class[ck] = kind or false end
    return kind
end
M.npc_kind = npc_kind
-- set by sdc_quests: quest_gnc(role, kind, object, wco_param) for the
-- OTHER_KINDS (pre-hook context: may clear the parameter, returns nothing)
M.quest_gnc = nil

local function is_wanderer(o)
    local c = npc_class(1)
    if not c or not ue.valid(o) then return false end
    local ok, r = pcall(function() return o:IsA(c) end)
    return ok and r == true
end

-- A trader only this machine has: it was spawned here and this machine is
-- its authority (a replicated copy is a simulated proxy on a client).
local function client_only(o)
    return ue.role(o) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(o)
end

local function dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function short_class(c)
    if not ue.valid(c) then return "<none>" end
    return ue.short(c)
end

local function who(o)
    if not ue.valid(o) then return "none" end
    local ok, w = pcall(ctx.classify, o, role())
    return ok and tostring(w) or "?"
end

local function comp_actor(comp)
    if not ue.valid(comp) then return nil end
    local o = ue.try(function() return comp:GetOwner() end)
    if ue.valid(o) then return o end
    return nil
end

local function trader_money(trader)
    return tonumber(ue.prop(ue.prop(trader, "BP_JigMultiplayer"), "VendorCurrentCurrencyAmount"))
end

-- Every player character with its controller: host + remote (host side).
local function players()
    local out = {}
    local me = ue.local_pc()
    local mp = me and ue.pawn_of(me)
    if mp then out[#out + 1] = { pc = me, pawn = mp } end
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        if ue.valid(pc) then
            local p = ue.pawn_of(pc)
            if p then out[#out + 1] = { pc = pc, pawn = p } end
        end
    end
    return out
end

-- Who is talking to this NPC (host side). Traders store it right before
-- the call; the quest giver keeps ByActor only in its ubergraph frame, so:
-- the player in range who looks most directly at it.
local function acting_actor(npc, kind)
    if kind == "trader" then
        local cur = ue.prop(npc, "CurrentActor")
        if ue.valid(cur) then return cur, "CurrentActor" end
    end
    local at = ue.location(npc)
    if not at then return nil, "no location" end
    local best, best_score = nil, -2
    for _, p in ipairs(players()) do
        local loc = ue.location(p.pawn)
        if loc and dist2(loc, at) < GIVER_RANGE * GIVER_RANGE then
            local score = 0
            local okr, rot = pcall(function() return p.pc:GetControlRotation() end)
            if okr and rot then
                local yaw = math.rad(tonumber(rot.Yaw) or 0)
                local dx, dy = at.X - loc.X, at.Y - loc.Y
                local len = math.sqrt(dx * dx + dy * dy) + 1e-3
                score = (math.cos(yaw) * dx + math.sin(yaw) * dy) / len
            end
            if score > best_score then best, best_score = p.pawn, score end
        end
    end
    return best, "nearest facing"
end

local PARAMS
local function play_params()
    -- = the Blueprints' DialoguePlayParams{'None', -1, 0, true, 0, false, 0, false}
    if not PARAMS then
        PARAMS = {
            StartFromID = FName("None"), Priority = -1,
            bOverride_bFreeMovement = false, bFreeMovement = true,
            bOverride_bStopMovement = false, bStopMovement = false,
            bOverride_bUnskippable = false, bUnskippable = false,
        }
    end
    return PARAMS
end

-- Host: start `cls` on the component of remote controller `pc`. Both paths
-- (host routing and the client's QD) may fire for one key press if the
-- interaction ran on both machines: the second start within 3 s is skipped.
-- Returns "skipped", or ok, BeginDialogue's result.
local recent_start = {}   -- [controller name .. "|" .. class name] = os.clock()

local function start_for(pc, cls, npc, why)
    if not ue.valid(pc) or not ue.valid(cls) then
        log.warn("dlg: %s: controller or dialogue class gone before the start", why)
        return false, "gone"
    end
    local key = ue.name(pc) .. "|" .. short_class(cls)
    local now = os.clock()
    if recent_start[key] and now - recent_start[key] < 3 then
        log.info("dlg: host: %s: %s already started on the component of %s %.1f s ago, not again",
            why, short_class(cls), ue.short(pc), now - recent_start[key])
        return "skipped"
    end
    recent_start[key] = now
    local comp = ue.prop(pc, "NarrativeComponent")
    if not ue.valid(comp) then
        log.warn("dlg: %s: %s has no NarrativeComponent", why, ue.short(pc))
        return false, "no component"
    end
    local ok, r = pcall(function() return comp:BeginDialogue(cls, play_params()) end)
    log.info("dlg: host: %s: %s (npc %s) started on the component of %s -> %s",
        why, short_class(cls), ue.short(npc), ue.short(pc), ok and tostring(r) or ("error " .. tostring(r)))
    return ok, r
end

-- ---------------------------------------------------------------------------
-- Host: the trader's money to the clients near it (QTM; "QM" is
-- sdc_quests' quest marker message: one handler per kind)
-- ---------------------------------------------------------------------------

local money_last = {}   -- [trader full name] = { v = money, at = os.clock() } (one QM per change)

local function send_money(trader, why, only_pc)
    if not cfg.get("trade_vendor_money") or role() ~= "host" or not ue.valid(trader) then return end
    local amount = trader_money(trader)
    local loc = ue.location(trader)
    if not amount or not loc then return end
    local key = ue.name(trader)
    local now = os.clock()
    local last = money_last[key]
    if not only_pc and last and last.v == amount and now - last.at < 1 then return end
    money_last[key] = { v = amount, at = now }
    local sent = {}
    local targets = only_pc and { only_pc } or (S and S.remote_pcs) or {}
    for _, pc in ipairs(targets) do
        if ue.valid(pc) then
            local p = ue.pawn_of(pc)
            local pl = p and ue.location(p)
            if only_pc or (pl and dist2(pl, loc) <= MONEY_RANGE * MONEY_RANGE) then
                if net.send_to(pc, "QTM", ue.class_name(trader), f0(loc.X), f0(loc.Y), f0(loc.Z),
                        string.format("%.4f", amount)) then
                    sent[#sent + 1] = ue.short(pc)
                end
            end
        end
    end
    if #sent > 0 then
        log.info("trade: host: money of %s (%.0f) sent to %s (%s)", ue.short(trader), amount, table.concat(sent, ", "), why)
    end
end

-- ---------------------------------------------------------------------------
-- Host: a wandering trader stops while a client talks / trades with it
-- ---------------------------------------------------------------------------

-- [controller full name] = { path, name, who, at } of the stopped wandering
-- trader; [HOST_WAIT .. trader path] = { path, name, at, host = true }: a
-- client let go of it while the host's own player still talked / traded with
-- it (it walks once the host is done, check_held).
local held = {}
local HOST_WAIT = "host-wait:"
local release_wanderer   -- defined below

local function hold_wanderer(pc, npc)
    if not is_wanderer(npc) then return end
    if held[ue.name(pc)] then release_wanderer(ue.name(pc), "its player started another dialogue") end
    local cm = ue.prop(npc, "CharacterMovement")
    local ok = ue.valid(cm) and pcall(function() cm:DisableMovement() end)
    held[ue.name(pc)] = { path = ue.path(npc), name = ue.short(npc), who = ue.short(pc), at = os.clock() }
    log.info("trade: host: wandering trader %s stops while %s talks / trades with it (DisableMovement, as the game does on the machine that pressed F, BP_MasterTrader @5050): %s",
        ue.short(npc), ue.short(pc), ok and "ok" or "FAILED")
end

-- Who else keeps a wandering trader stopped: another client held for it, or
-- the host's own player talking / trading with it - the game's CurrentActor,
-- set by OnExecuteInteract on the machine that pressed F (@5682), cleared by
-- OnExecuteInteractEnded (@5586) and its CheckDistanceFromActor timer (@389),
-- with the host's character within HOLD_RANGE (a CurrentActor left behind by
-- a talk without trading does not hold it once the host walked off).
-- 13.11 host log: a client closed its window at 17:22:41, the trader walked
-- while the host still sold to it at 17:22:45.
-- Returns "client" / "host" and the reason, or nil.
local function wanderer_user(npc, path, except_key)
    for k, h in pairs(held) do
        if k ~= except_key and h.path == path and not h.host then
            return "client", "another player (" .. tostring(h.who) .. ") still talks / trades with it"
        end
    end
    local me = ue.local_pawn()
    local cur = ue.prop(npc, "CurrentActor")
    if me and ue.valid(cur) and addr(cur) == addr(me)
        and dist2(ue.location(me), ue.location(npc)) <= HOLD_RANGE * HOLD_RANGE then
        return "host", "the host's player still talks / trades with it (its CurrentActor)"
    end
    return nil
end

release_wanderer = function(key, why)
    local h = held[key]
    if not h then return end
    held[key] = nil
    local npc = ue.find_object(h.path)
    if not npc then
        log.info("trade: host: wandering trader %s is gone (%s)", h.name, why)
        return
    end
    if ue.prop(ue.prop(npc, "BP_AIComponent"), "Dead") == true then return end
    local user, busy = wanderer_user(npc, h.path, key)
    if user then
        -- the host's own trade: the game lets it walk when the host closes its
        -- window (@5545); a host that walks off without that is checked each
        -- second. Another client's entry lets it go itself.
        if user == "host" then
            local wk = HOST_WAIT .. h.path
            if not held[wk] then held[wk] = { path = h.path, name = h.name, at = h.host and h.at or os.clock(), host = true } end
        end
        if not h.host then log.info("trade: host: wandering trader %s stays stopped (%s): %s", h.name, why, busy) end
        return
    end
    local cm = ue.prop(npc, "CharacterMovement")
    local ok = ue.valid(cm) and pcall(function() cm:SetMovementMode(1, 0) end)
    log.info("trade: host: wandering trader %s walks again (%s; SetMovementMode Walking as its OnExecuteInteractEnded @5545): %s",
        h.name, why, ok and "ok" or "FAILED")
end

-- Every second (host). What to do is collected first: release_wanderer may
-- add a HOST_WAIT entry, and a table must not get new keys while pairs()
-- walks it.
local function check_held()
    if not next(held) then return end
    local by_key = {}
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        if ue.valid(pc) then by_key[ue.name(pc)] = pc end
    end
    local now = os.clock()
    local todo = {}   -- { key, why } (why false: gone, drop quietly)
    for key, h in pairs(held) do
        local npc = ue.find_object(h.path)
        if not npc then
            todo[#todo + 1] = { key, false }
            if not h.host then log.info("trade: host: wandering trader %s is gone", h.name) end
        elseif h.host then
            local user = wanderer_user(npc, h.path, key)
            if user == "client" then
                todo[#todo + 1] = { key, false }   -- that client's own entry lets it go
            elseif not user then
                todo[#todo + 1] = { key, "the host's player is done with it" }
            elseif now - h.at > HOLD_MAX_S then
                todo[#todo + 1] = { key, false }
            end
        else
            local pc = by_key[key]
            local pawn = pc and ue.pawn_of(pc)
            if not pawn then
                todo[#todo + 1] = { key, "its player left or has no character" }
            elseif dist2(ue.location(pawn), ue.location(npc)) > HOLD_RANGE * HOLD_RANGE then
                todo[#todo + 1] = { key, "its player walked away" }
            elseif now - h.at > HOLD_MAX_S then
                todo[#todo + 1] = { key, "10 minutes" }
            end
        end
    end
    for _, t in ipairs(todo) do
        if t[2] then release_wanderer(t[1], t[2]) else held[t[1]] = nil end
    end
end

-- Host: BP_MasterTrader.OnExecuteInteractEnded, post - the HOST's player
-- closed its trade window (the event runs on the machine that pressed F) and
-- the game has just let the trader walk (@5545). A client still trading with
-- it: stopped again; a release that waited for the host is done.
local function host_wanderer_end(npc)
    if not next(held) or not ue.valid(npc) then return end
    local path = ue.path(npc)
    held[HOST_WAIT .. path] = nil
    for _, h in pairs(held) do
        if h.path == path then
            local cm = ue.prop(npc, "CharacterMovement")
            local ok = ue.valid(cm) and pcall(function() cm:DisableMovement() end)
            log.info("trade: host: the host's player closed its trade with wandering trader %s; it stays stopped for %s (DisableMovement again): %s",
                h.name, tostring(h.who), ok and "ok" or "FAILED")
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: which clients have a Narrative HUD (QH)
-- ---------------------------------------------------------------------------

local hud_ready = {}   -- [controller full name] = os.time() of the last QH

local function client_has_hud(pc)
    local t = hud_ready[ue.name(pc)]
    return t ~= nil and os.time() - t < 90
end

-- ---------------------------------------------------------------------------
-- GetNarrativeComponent pre-hook (both roles)
-- ---------------------------------------------------------------------------

local handled = {}         -- [npc address] = { at = os.clock(), pc = controller } of the routed call (host)
local asked = {}           -- client: [npc address] = os.clock() of the last QD for its F press
local ghost_next = 0       -- client: next pass over traders only this machine has

M.hud_widget = nil
function M.hud_ok()
    return ue.valid(M.hud_widget) and ue.class_name(M.hud_widget) == HUD_CLASS_NAME
end

-- Client: F on a trader. Its OnExecuteInteract ran here (CurrentActor = this
-- player's character, set right before) and asks for player 0's component:
-- the BeginDialogue that follows is BlueprintAuthorityOnly and is skipped
-- by the engine here, so the host starts the dialogue (QD).
local function client_trader_f(npc, a, cur)
    local me = ue.local_pawn()
    if not me or not ue.valid(cur) or addr(cur) ~= addr(me) then return end
    local now = os.clock()
    if a and asked[a] and now - asked[a] < 1.5 then return end
    if a then asked[a] = now end
    local name = ue.short(npc)
    local own = client_only(npc)
    if not cfg.get("quest_dialogues") then
        log.info("trade: client: F on %s: quest_dialogues is off - its BeginDialogue is server-only, nothing opens here", name)
        return
    end
    if own and cfg.get("trade_host_traders") then
        ghost_next = 0
        notice("own-trader", "Это копия торговца только на вашем компьютере — она убирается. Подойдите к торговцу хоста и нажмите F снова.",
            string.format("trade: client: F on %s (%s): a trader only this machine has (role authority, spawned here); the host does not know it - not asking, it is removed", name, ue.class_name(npc)))
        return
    end
    local cls = ue.prop(npc, "Dialogue")
    if not ue.valid(cls) then
        log.warn("trade: client: F on %s: it has no Dialogue class", name)
        return
    end
    if not M.hud_ok() then
        notice("no-hud", "Окно диалогов ещё не готово — разговор с торговцем не начат. Попробуйте через несколько секунд.",
            string.format("trade: client: F on %s: no dialogue HUD here (quest_hud off or not built yet) - not asking the host", name))
        return
    end
    local full = ue.try(function() return cls:GetFullName() end)
    if not full then return end
    local loc = ue.location(npc)
    local x, y, z = "", "", ""
    if loc then x, y, z = f0(loc.X), f0(loc.Y), f0(loc.Z) end
    log.info("trade: client: F on %s (%s, %s): its BeginDialogue is server-only (BlueprintAuthorityOnly) and the engine skips it here; asking the host to start %s",
        name, ue.class_name(npc), own and "a copy only this machine has" or "the host's replicated trader", short_class(cls))
    ue.game_thread("dlg-ask", function() net.send_to_host("QD", full, x, y, z) end)
end

-- ---------------------------------------------------------------------------
-- Quest givers (host): BP_QuestGiver.OnServerExecuteInteract(Option,
-- ByActor, Payload) runs on the host after the presser's SERVER_ForwardInteract
-- and asks GetNarrativeComponent(self) twice: BeginDialogue (@1329-1350),
-- then CompleteNarrativeDataTask(Quest_Task_InteractWithActor,
-- InteractionArgument) (@1109-1130). With a remote player near, both get
-- None (the parameter is cleared) and the event's own post-hook, which knows
-- ByActor, does the same two calls on the component of the player who
-- pressed F (the host's own one included). Without that hook: the old guess
-- (the player in range who faces the giver).
-- ---------------------------------------------------------------------------

local giver = { defer = {}, hook_ok = false }   -- defer[npc address] = { at, n }
local LIB_CDO = "/Script/Narrative.Default__NarrativeFunctionLibrary"
local INTERACT_TASK = "/Game/Quests/Tasks/Quest_Task_InteractWithActor.Quest_Task_InteractWithActor"

-- quests per player (sdc_quests' quest_own; on until the key says otherwise)
local function quest_own() return cfg.get("quest_own") ~= false end
M.quest_own = quest_own

local function remote_near(npc, range)
    local at = ue.location(npc)
    if not at then return false end
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        local p = ue.valid(pc) and ue.pawn_of(pc)
        if p and dist2(ue.location(p), at) < range * range then return true end
    end
    return false
end

-- The giver's data task on `pc`'s component, the game's own library call.
local function credit_interact(pc, npc, why)
    local comp = ue.prop(pc, "NarrativeComponent")
    local task, lib = ue.find_object(INTERACT_TASK), ue.find_object(LIB_CDO)
    local arg = ue.str(ue.prop(npc, "InteractionArgument"))
    if not ue.valid(comp) or not task or not lib then
        log.warn("quests: host: talked to %s: data task not credited (component=%s task=%s library=%s)", ue.short(npc),
            tostring(ue.valid(comp)), tostring(task ~= nil), tostring(lib ~= nil))
        return
    end
    local ok, r = pcall(function() return lib:CompleteNarrativeDataTask(comp, task, arg, 1) end)
    log.info("quests: host: talked to %s (%s): data task Quest_Task_InteractWithActor(%s) credited to the quests of %s -> %s",
        ue.short(npc), why, arg, ue.short(pc), ok and tostring(r) or ("error " .. tostring(r)))
end

local function on_gnc(_, wco_p)
    local r = role()
    if r ~= "host" and r ~= "client" then return end
    local npc = pget(wco_p)
    local kind = npc_kind(npc)
    if not kind then return end
    if kind ~= "trader" and kind ~= "giver" then
        if M.quest_gnc then M.quest_gnc(r, kind, npc, wco_p) end
        return
    end
    local a = addr(npc)

    if r == "client" then
        local cur = ue.prop(npc, "CurrentActor")
        trace("gnc-c" .. tostring(a), "client: GetNarrativeComponent from %s (%s) actor=%s who=%s -> own component",
            ue.short(npc), kind, ue.short(cur), who(cur))
        if kind == "trader" then client_trader_f(npc, a, cur) end
        return
    end

    -- host
    local now = os.clock()
    if kind == "giver" and a and cfg.get("quest_dialogues") then
        local d = giver.defer[a]
        if d and now - d.at < HANDLED_WINDOW then
            d.n = d.n + 1
            pcall(function() wco_p:set(nil) end)
            trace("gnc-g2" .. tostring(a), "host: GetNarrativeComponent #%d from %s (quest giver) -> None (its OnServerExecuteInteract hook decides)",
                d.n, ue.short(npc))
            return
        end
        if giver.hook_ok and remote_near(npc, GIVER_RANGE) and pcall(function() wco_p:set(nil) end) then
            giver.defer[a] = { at = now, n = 1 }
            trace("gnc-g" .. tostring(a), "host: GetNarrativeComponent from %s (quest giver, a remote player near) -> None; the player who pressed F gets it (ByActor)",
                ue.short(npc))
            return
        end
    end
    local h = a and handled[a]
    if h and now - h.at < HANDLED_WINDOW then
        if kind == "giver" and quest_own() and ue.valid(h.pc) and pcall(function() wco_p:set(nil) end) then
            local pc = h.pc
            ue.game_thread("dlg-credit", function() credit_interact(pc, npc, "guessed player") end)
            trace("gnc-h2" .. tostring(a), "host: GetNarrativeComponent again from %s (%s) in the same interaction -> None (data task to %s)",
                ue.short(npc), kind, ue.short(h.pc))
            return
        end
        trace("gnc-h2" .. tostring(a), "host: GetNarrativeComponent again from %s (%s) in the same interaction -> host component (group quest log)",
            ue.short(npc), kind)
        return
    end
    local actor, how = acting_actor(npc, kind)
    local w = who(actor)
    local e = actor and ctx.player_for(actor)
    local outcome
    if not e or not ue.valid(e.pc) then
        outcome = "host component (host player or nobody)"
    elseif not cfg.get("quest_dialogues") then
        outcome = "host component (quest_dialogues off)"
    elseif not client_has_hud(e.pc) then
        outcome = "host component (client reported no dialogue HUD)"
    else
        local cls = ue.prop(npc, "Dialogue")
        if not ue.valid(cls) then
            outcome = "host component (NPC has no Dialogue class)"
        elseif not pcall(function() wco_p:set(nil) end) then
            outcome = "host component (could not clear the world context)"
        else
            if a then handled[a] = { at = now, pc = e.pc } end
            outcome = "None (routed to " .. ue.short(e.pc) .. ")"
            local pc = e.pc
            ue.game_thread("dlg-route", function()
                start_for(pc, cls, npc, kind == "trader" and "trader interaction" or "quest giver interaction")
            end)
        end
    end
    trace("gnc-h" .. tostring(a), "host: GetNarrativeComponent from %s (%s) actor=%s (%s) who=%s -> %s",
        ue.short(npc), kind, ue.short(actor), how, w, outcome)
end

-- ---------------------------------------------------------------------------
-- Log only, hooked with config debug_probes only: BeginDialogue pre / post
-- (host: it is BlueprintAuthorityOnly, a client's own call never runs it),
-- ClientBegin / ClientExit (client)
-- ---------------------------------------------------------------------------

local function comp_owner(comp_p)
    local comp = pget(comp_p)
    if not ue.valid(comp) then return nil, nil end
    return comp, ue.try(function() return comp:GetOwner() end)
end

local function on_begin_pre(comp_p, cls_p)
    if role() ~= "host" or not log.probes_enabled then return end
    local comp, owner = comp_owner(comp_p)
    trace("begin-pre" .. tostring(addr(comp)), "host: BeginDialogue %s on the component of %s (who=%s)",
        short_class(pget(cls_p)), ue.short(owner), who(owner))
end

local function on_begin_post(comp_p, ret_p, cls_p)
    if role() ~= "host" or not log.probes_enabled then return end
    local comp, owner = comp_owner(comp_p)
    trace("begin-post" .. tostring(addr(comp)), "host: BeginDialogue %s on the component of %s returned %s",
        short_class(pget(cls_p)), ue.short(owner), tostring(pget(ret_p)))
end

-- ClientBeginDialogue(Dialogue, NPCReplyChainIDs, AvailableResponseIDs) /
-- ClientExitDialogue(Reason): the host's dialogue arriving on this client.
local function on_client_begin(comp_p, dlg_p)
    if role() ~= "client" or not log.probes_enabled then return end
    local comp = pget(comp_p)
    local d = pget(dlg_p)
    log.info("dlg: client: the host started %s on %s (ClientBeginDialogue): the dialogue shows here%s",
        ue.valid(d) and ue.class_name(d) or "?", ue.short(comp), M.hud_ok() and "" or " - but this machine has no dialogue HUD")
end

local function on_client_exit(_, reason_p)
    if role() ~= "client" or not log.probes_enabled then return end
    log.info("dlg: client: dialogue ended (ClientExitDialogue, reason %s)", tostring(pget(reason_p)))
end

-- ---------------------------------------------------------------------------
-- Host: QD request
-- ---------------------------------------------------------------------------

local function find_npc(want, near, pawn_loc)
    local best, bd = nil, math.huge
    for i, spec in ipairs(NPC_CLASSES) do
        if npc_class(i) then
            for _, n in ipairs(ue.find_all(spec.short)) do
                if ue.valid(n) then
                    local c = ue.prop(n, "Dialogue")
                    local full = ue.valid(c) and ue.try(function() return c:GetFullName() end)
                    local loc = ue.location(n)
                    if full == want and loc and dist2(loc, pawn_loc) < REQUEST_RANGE * REQUEST_RANGE then
                        local d = dist2(loc, near or pawn_loc)
                        if d < bd then best, bd = n, d end
                    end
                end
            end
        end
    end
    return best
end

local function on_request(f, pc)
    ue.game_thread("dlg-request", function()
        if role() ~= "host" or not cfg.get("quest_dialogues") then return end
        if not ue.valid(pc) then return end
        local want = f[1]
        local pawn = ue.pawn_of(pc)
        local ploc = pawn and ue.location(pawn)
        if not want or want == "" or not ploc then
            log.warn("dlg: host: request from %s without a character or class", ue.short(pc))
            net.send_to(pc, "QF", "nochar")
            return
        end
        local x, y, z = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
        local near = (x and y and z) and { X = x, Y = y, Z = z } or nil
        local npc = find_npc(want, near, ploc)
        local short = tostring(want:match("([^%./]+)$"))
        if not npc then
            log.warn("dlg: host: request from %s for %s: no such NPC within %d of the character",
                ue.short(pc), short, REQUEST_RANGE)
            net.send_to(pc, "QF", "nonpc")
            return
        end
        log.info("dlg: host: %s asks for %s at %s (%s, %.0f cm from their character)", ue.short(pc), short,
            ue.short(npc), ue.class_name(npc), math.sqrt(dist2(ue.location(npc), ploc)))
        local ok, r = start_for(pc, ue.prop(npc, "Dialogue"), npc, "client request")
        if ok == "skipped" then return end
        if not ok or r ~= true then
            net.send_to(pc, "QF", "start")
            return
        end
        if npc_kind(npc) == "trader" then
            send_money(npc, "their dialogue started", pc)
            hold_wanderer(pc, npc)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Trade event (both roles) and the client fallback
-- ---------------------------------------------------------------------------

local last_local_trade = -100

local function on_trade_event(_, target_p, ctl_p)
    local r = role()
    if r ~= "host" and r ~= "client" then return end
    local target, ctl = pget(target_p), pget(ctl_p)
    local helper = ue.prop(target, "BP_JigHelperComp")
    local iea = ue.prop(helper, "InteractExecutedActor")
    trace("trade-" .. r, "%s: trade event ExecuteEvent target=%s (who=%s) controller=%s interact-actor=%s",
        r, ue.short(target), who(target), ue.short(ctl), ue.short(iea))
    if r == "client" then
        last_local_trade = os.clock()
        log.info("trade: client: trade event ran here (interact-actor %s): the trade window opens by itself", ue.short(iea))
        return
    end
    if not cfg.get("quest_vendor_fallback") then return end
    local e = ue.valid(ctl) and ctx.player_for(ctl)
    if e and ue.valid(e.pc) then
        local pc = e.pc
        log.info("trade: host: trade event of %s's dialogue ran here (the host's copy has no interact-actor for them); signalling their machine (QV)",
            ue.short(pc))
        ue.game_thread("dlg-vendor-send", function()
            if ue.valid(pc) then net.send_to(pc, "QV") end
        end)
    end
end

local function on_vendor_signal()
    if role() ~= "client" or not cfg.get("quest_vendor_fallback") then return end
    ue.delay("dlg-vendor", 700, function()
        if role() ~= "client" then return end
        if os.clock() - last_local_trade < 3 then
            log.info("dlg: client: trade event ran here, the trade window opened by itself (no fallback)")
            return
        end
        local pc = ue.local_pc()
        local pawn = pc and ue.pawn_of(pc)
        local helper = ue.prop(pawn, "BP_JigHelperComp")
        local npc = ue.prop(helper, "InteractExecutedActor")
        if npc_kind(npc) ~= "trader" then
            log.warn("dlg: client: trade fallback: last interacted actor %s is not a trader", ue.short(npc))
            return
        end
        local comp = ue.prop(pc, "NarrativeComponent")
        if ue.valid(comp) then pcall(function() comp:TryExitDialogue(0) end) end
        local ok, err = pcall(function() npc:OnExecuteInteractDialogue(pawn) end)
        log.info("dlg: client: trade event did not run here; opened the trade window of %s ourselves: %s",
            ue.short(npc), ok and "ok" or tostring(err))
    end)
end

-- QF|<code>: the host could not start the dialogue this machine asked for.
-- QF|vmoney: a sale the trader could not pay for (the game's notification
-- "Trader does not have enough money" from CheckVendorAmountOfMoney @1059
-- goes to the host's HUD only).
local QF_TEXT = {
    nonpc = { "Хост не нашёл этого торговца рядом с вашим персонажем — разговор не начат. Подойдите ближе и нажмите F снова.",
              "dialogue not started: the host found no such NPC near this player's character" },
    start = { "Хост не смог начать разговор с торговцем (подробности — в журнале хоста).",
              "dialogue not started: the host could not start it (see the host's log)" },
    nochar = { "Хост не видит вашего персонажа — разговор не начат.",
               "dialogue not started: the host has no character for this player" },
    nohud = { "Окно диалогов ещё не готово — разговор не начат. Попробуйте через несколько секунд.",
              "dialogue not started: the host has no dialogue HUD report from this machine yet" },
    vmoney = { "У торговца не хватает денег, чтобы это купить.",
               "sale refused by the host: the trader does not have enough money" },
}

local function on_refused(f)
    if role() ~= "client" then return end
    local t = QF_TEXT[f[1] or ""] or QF_TEXT.start
    notice("qf-" .. tostring(f[1]), t[1], "trade: client: " .. t[2])
end

-- ---------------------------------------------------------------------------
-- Trading: money (QTM), the host's trade log, the wandering trader's end (QE)
-- ---------------------------------------------------------------------------

-- Client: QTM|<trader class>|x|y|z|<money>: the host's money of that trader
-- into this machine's copy of its component (the trade window reads it).
local function on_money(f)
    if role() ~= "client" or not cfg.get("trade_vendor_money") then return end
    local cls = f[1]
    local x, y, z, amount = tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
    if not cls or cls == "" or not (x and y and z and amount) or amount ~= amount then return end
    local at = { X = x, Y = y, Z = z }
    local best, bd = nil, MATCH_RANGE * MATCH_RANGE
    for _, o in ipairs(ue.find_all(cls)) do
        if ue.valid(o) and ue.class_name(o) == cls and ue.role(o) ~= ue.ROLE_AUTHORITY then
            local d = dist2(ue.location(o), at)
            if d <= bd then best, bd = o, d end
        end
    end
    if not best then
        log.info("trade: client: the host's money of a %s (%.0f) - no copy of it near %.0f,%.0f,%.0f here", cls, amount, x, y, z)
        return
    end
    local comp = ue.prop(best, "BP_JigMultiplayer")
    local before = tonumber(ue.prop(comp, "VendorCurrentCurrencyAmount"))
    local ok = ue.valid(comp) and ue.set_prop(comp, "VendorCurrentCurrencyAmount", amount)
    log.info("trade: client: money of %s is the host's %.0f (this copy had %s)%s", ue.short(best), amount,
        before and f0(before) or "?", ok and "" or " - could not set it")
end

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"

local guid_str = consume.guid_str

-- The item with this UID in the component's main containers: name, count.
local function find_item(comp, uid)
    if not ue.valid(comp) or uid == nil then return nil end
    local want = ue.try(guid_str, uid)
    if not want then return nil end
    local name, count
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, ct)
            if name then return end
            ct:get()[F_ITEMS]:ForEach(function(_, it)
                if name then return end
                local item = it:get()
                if guid_str(item[F_USID]) == want then
                    local info = item[F_INFO]
                    name = (ue.short(info[F_ITEMID]):gsub("^DA_", ""))
                    count = info[F_COUNT]
                end
            end)
        end)
    end)
    return name, count
end

-- BP_JigComponent."Handle Comp to Comp Move"(From, To, ItemUID, FinalRotation,
-- ToIndex, ToContainer, VendorAmount, ...), post (host): a purchase (From =
-- a trader's component) or a sale (To = a trader's component), done.
local function on_comp_move(c, from_p, to_p, uid_p, _, _, _, amount_p)
    if role() ~= "host" then return end
    local from, to = pget(from_p), pget(to_p)
    local fo, tob = comp_actor(from), comp_actor(to)
    local trader, buying
    if fo and npc_kind(fo) == "trader" then trader, buying = fo, true
    elseif tob and npc_kind(tob) == "trader" then trader, buying = tob, false end
    if not trader then return end
    local e = ctx.player_for(pget(c))
    local player = e and ue.short(e.pawn) or "the host's player"
    local uid = pget(uid_p)
    local name, count = find_item(to, uid)
    if not name then name, count = find_item(from, uid) end
    local money = trader_money(trader)
    log.info("trade: host: %s %s %s %s %s (uid %s, amount asked %s, that stack now x%s); the trader's money now %s",
        player, buying and "bought" or "sold", name or "an item", buying and "from" or "to", ue.short(trader),
        ue.try(guid_str, uid) or "?", tostring(pget(amount_p)), tostring(count or "?"), money and f0(money) or "?")
    send_money(trader, buying and "after a purchase" or "after a sale")
end

-- BP_JigComponent.CheckVendorAmountOfMoney(Price, Comp, Selling?, Enough?),
-- post (host): the only place the trader's money changes in a trade.
local function on_vendor_money(c, price_p, comp_p, selling_p, enough_p)
    if role() ~= "host" then return end
    local trader = comp_actor(pget(comp_p))
    if not trader or npc_kind(trader) ~= "trader" then return end
    local money = trader_money(trader)
    local refused = pget(enough_p) == false
    local e = ctx.player_for(pget(c))
    log.info("trade: host: %s %s for %s (%s): the trader's money now %s%s", ue.short(trader),
        pget(selling_p) == true and "buys an item" or "sells an item", tostring(pget(price_p)),
        e and ue.short(e.pawn) or "the host's player", money and f0(money) or "?",
        refused and " (the trader does not have enough money: refused)" or "")
    if refused and e and ue.valid(e.pc) then
        -- the game's own note (@1059) reached that player through sdc_notes
        -- (its CreateNotificationUI post-hook ran inside this call): no toast
        local notes = package.loaded["sdc_notes"]
        if notes and notes.sent_to and notes.sent_to(e.pc, "Trader does not have enough money", 3) then
            log.info("trade: host: the game's 'Trader does not have enough money' went to %s (sdc_notes): no QF",
                ue.short(e.pc))
        else
            net.send_to(e.pc, "QF", "vmoney")
        end
    end
    send_money(trader, "money changed")
end

-- BP_QuestGiver.OnServerExecuteInteract(Option, ByActor, Payload), post
-- (host): the deferred interaction goes to ByActor's player.
local function on_giver_server(c, _, by_p)
    if role() ~= "host" then return end
    local npc = pget(c)
    local a = addr(npc)
    local d = a and giver.defer[a]
    if not d then return end
    giver.defer[a] = nil
    if os.clock() - d.at > 1 then return end
    local by = pget(by_p)
    local me = ue.local_pc()
    local mp = me and ue.pawn_of(me)
    local pc, remote = nil, false
    if ue.valid(by) and mp and addr(by) == addr(mp) then
        pc = me
    else
        local e = ue.valid(by) and ctx.player_for(by)
        if e and ue.valid(e.pc) then pc, remote = e.pc, true end
    end
    if not pc then
        log.warn("dlg: host: quest giver %s: interaction by %s, which is no player here: nothing started", ue.short(npc), ue.short(by))
        return
    end
    local cls = ue.prop(npc, "Dialogue")
    log.info("dlg: host: %s pressed F on quest giver %s (OnServerExecuteInteract, ByActor %s): its dialogue and data task go to that player",
        remote and ue.short(pc) or "the host's player", ue.short(npc), ue.short(by))
    if remote and not client_has_hud(pc) then
        log.warn("dlg: host: %s has reported no dialogue HUD: dialogue %s not started", ue.short(pc), short_class(cls))
        net.send_to(pc, "QF", "nohud")
    elseif ue.valid(cls) then
        local ok, r = start_for(pc, cls, npc, remote and "quest giver interaction" or "quest giver interaction (host's player)")
        if remote and ok ~= "skipped" and (not ok or r ~= true) then net.send_to(pc, "QF", "start") end
        -- the cleared parameter must have kept the host's own component out
        local hc = me and ue.prop(me, "NarrativeComponent")
        local hd = ue.valid(hc) and ue.prop(hc, "CurrentDialogue")
        if remote and ue.valid(hd) and ue.class_name(hd) == short_class(cls) then
            log.warn("dlg: host: %s is ALSO running on the host's own component (the cleared GetNarrativeComponent parameter did not hold?)",
                short_class(cls))
        end
    end
    if d.n >= 2 then
        -- the Blueprint got to its CompleteNarrativeDataTask (with None)
        local target = (remote and not quest_own()) and me or pc
        credit_interact(target, npc, remote and (quest_own() and "the player's own quests" or "group quests on the host") or "host's player")
    end
end

-- Client: BP_MasterTrader.OnExecuteInteractEnded, post: this player closed
-- the trade window of a wandering trader (BP_JigHelperComp @2569). (Host:
-- host_wanderer_end.)
local function on_wanderer_end(c)
    if role() == "host" then return host_wanderer_end(pget(c)) end
    if role() ~= "client" or not cfg.get("quest_dialogues") then return end
    local npc = pget(c)
    if not ue.valid(npc) or client_only(npc) then return end
    local loc = ue.location(npc)
    if not loc then return end
    log.info("trade: client: trade window of %s closed; the host lets it walk again (QE)", ue.short(npc))
    net.send_to_host("QE", ue.class_name(npc), f0(loc.X), f0(loc.Y), f0(loc.Z))
end

-- ---------------------------------------------------------------------------
-- Client: traders only this machine has
-- ---------------------------------------------------------------------------

local function world_is_client(o)
    local ksl = ue.ksl()
    if not ksl then return false end
    local oks, standalone = pcall(function() return ksl:IsStandalone(o) end)
    if not oks or standalone == true then return false end
    local ok, server = pcall(function() return ksl:IsServer(o) end)
    return ok and server == false
end

local spawner_by_class = {}   -- [class address] = true / false
local not_actor = nil         -- the UObject class (never unloaded)

-- GameplayStatics.BeginDeferredActorSpawnFromClass, pre (shared engine
-- hook): a trader spawner of this client's level about to spawn its own
-- trader. TSubclassOf<AActor> refuses a non-actor class: the spawn returns
-- None and FinishSpawningActor(None) does nothing; the host's trader comes
-- replicated. The net mode is the spawner's own world's (during a client's
-- map load the session role can still be stale).
local function on_trader_spawn(_, wco_p, class_p)
    if not wco_p or not class_p or role() == "host" then return end
    local wco = pget(wco_p)
    if wco == nil then return end
    local ck = class_key(wco)
    local is_sp = ck and spawner_by_class[ck]
    if is_sp == nil then
        is_sp = TRADER_SPAWNERS[ue.class_name(wco)] == true
        if ck then spawner_by_class[ck] = is_sp end
    end
    if not is_sp or not cfg.get("trade_host_traders") or not world_is_client(wco) then return end
    if not ue.valid(not_actor) then not_actor = ue.find_object(NOT_AN_ACTOR) end
    local cls = pget(class_p)
    local ok = not_actor ~= nil and pcall(function() class_p:set(not_actor) end)
    if ok then
        log.info("trade: client: %s's own spawn of %s blocked on this client (the host's trader comes replicated; a copy only this machine had could not trade)",
            ue.short(wco), short_class(cls))
    else
        log.warn("trade: client: cannot block %s's own spawn of %s; it is removed after it appears", ue.short(wco), short_class(cls))
    end
end

-- Client tick: a trader this machine made anyway (authority + runtime-spawned)
-- goes, as sdc_world removes client-only camps.
local function remove_own_traders()
    local now = os.clock()
    if now < ghost_next then return end
    ghost_next = now + GHOST_PASS_S
    if not cfg.get("trade_host_traders") then return end
    for _, t in ipairs(ue.find_all(STATIC_TRADER)) do
        -- in a client world only (the role flips while the old world is still loaded)
        if ue.valid(t) and client_only(t) and world_is_client(t) then
            local name, cls = ue.short(t), ue.class_name(t)
            local ok = pcall(function() t:K2_DestroyActor() end)
            log.info("trade: client: removed %s (%s): a trader only this machine had (role authority, spawned here); the host's own trader comes replicated%s",
                name, cls, ok and "" or " - FAILED")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Client: Narrative HUD
-- ---------------------------------------------------------------------------

local hud_pc_key = nil
local hud_tries, hud_next_try = 0, 0
local last_qh = 0

function M.hud()
    if M.hud_ok() then return M.hud_widget end
    return nil
end

local function build_hud(pc, now)
    local comp = ue.prop(pc, "NarrativeComponent")
    if not ue.valid(comp) then return false, "controller has no NarrativeComponent" end
    local cls = ue.find_object(HUD_CLASS)
    if not cls then
        ue.load_asset(HUD_CLASS, "dialogue")
        cls = ue.find_object(HUD_CLASS)
    end
    if not cls then return false, "class BP_CustomNarrativeDefaultUI_C not found" end
    local wbl = ue.widget_lib()
    if not wbl then return false, "WidgetBlueprintLibrary missing" end
    local ok, w = pcall(function() return wbl:Create(pc, cls, pc) end)
    if not ok or not ue.valid(w) then return false, "Create failed: " .. tostring(w) end
    -- as BP_PlayerController @8025: the component BEFORE AddToViewport, whose
    -- Construct binds the HUD to it (BP_CustomNarrativeDefaultUI @3003-3264)
    if not ue.set_prop(w, "NarrativeComponent", comp) then return false, "could not set NarrativeComponent" end
    local oka, erra = pcall(function() w:AddToViewport(0) end)
    if not oka then return false, "AddToViewport: " .. tostring(erra) end
    M.hud_widget = w
    log.info("dlg: client: Narrative HUD created for %s (bound to its own NarrativeComponent)", ue.short(pc))
    last_qh = 0
    return true
end

local ensure_bp_hooks   -- defined below

-- Client, every second (sdc_session client_tick).
function M.client_tick(now, pc, pawn)
    if role() ~= "client" then return end
    M.install()
    ensure_bp_hooks(now)
    remove_own_traders()
    if not cfg.get("quest_hud") then return end
    if not ue.valid(pc) or not pawn then return end
    local key = ue.name(pc)
    if key ~= hud_pc_key then
        -- a new controller: our widget (if any) belonged to the old one
        hud_pc_key, hud_tries, hud_next_try = key, 0, 0
        M.hud_widget = nil
    end
    if M.hud_ok() then
        -- the game removes every widget on death (BP_PlayerController @7918
        -- RemoveAllWidgets) and builds its HUD again on possess; so do we
        local okv, inv = pcall(function() return M.hud_widget:IsInViewport() end)
        if okv and inv == false then
            local old = M.hud_widget
            local comp = ue.prop(pc, "NarrativeComponent")
            if ue.valid(comp) then pcall(function() old["Unbind from Component"](old, comp) end) end
            M.hud_widget, hud_tries, hud_next_try = nil, 0, 0
            log.info("dlg: client: Narrative HUD was taken off screen (death / respawn); building it again")
        end
    end
    if not M.hud_ok() then
        M.hud_widget = nil
        if hud_tries >= 5 or now < hud_next_try then return end
        hud_tries = hud_tries + 1
        hud_next_try = now + 5
        local ok, err = build_hud(pc, now)
        if not ok then
            log.warn("dlg: client: Narrative HUD not created (try %d/5): %s", hud_tries, tostring(err))
            return
        end
    end
    if now - last_qh >= 20 then
        last_qh = now
        net.send_to_host("QH", "1")
    end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

local native_done = {}
local spawn_sub = false

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("dlg." .. name, "dlg: %s hook: %s", name, tostring(err)) end
    end
end

-- Native hooks (the Narrative module is loaded with the engine). Called at
-- load and again from the ticks until all are in; each is registered once.
-- sdc_gaptrace hooks the same natives read-only; native hooks stack.
-- probe = log only: registered with config debug_probes only.
local NATIVE_HOOKS = {
    -- pre only: an empty post callback made UE4SS wrap the parameters again on
    -- every call (~600 a second on a host)
    { GNC, "GetNarrativeComponent", function() return safe("gnc", on_gnc), nil end },
    { BEGIN, "BeginDialogue", function() return safe("begin", on_begin_pre), safe("begin-post", on_begin_post) end, probe = true },
    { CLIENT_BEGIN, "ClientBeginDialogue", function() return safe("client-begin", on_client_begin), nil end, probe = true },
    { CLIENT_EXIT, "ClientExitDialogue", function() return safe("client-exit", on_client_exit), nil end, probe = true },
}
function M.install()
    for i, h in ipairs(NATIVE_HOOKS) do
        if not native_done[i] and (not h.probe or log.probes_enabled) and ue.find_object(h[1]) then
            local pre, post = h[3]()
            local ok, err = pcall(RegisterHook, h[1], pre, post)
            native_done[i] = ok
            log.info("dlg: %s hook %s%s", h[2], ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
        end
    end
    -- the trader spawners' spawn: subscribed at load, before a client's map
    -- load runs their BeginPlay (one shared engine hook, sdc_ue.hook_native)
    if not spawn_sub then
        local ok, err = ue.hook_native(SPAWN_FN, "dlg.trader-spawn", safe("trader-spawn", on_trader_spawn))
        spawn_sub = ok == true
        log.info("trade: trader spawner hook %s%s", spawn_sub and "ok" or "FAILED", spawn_sub and "" or (" " .. tostring(err)))
    end
end

-- Blueprint hooks, each once its class is loaded. No other module hooks these
-- functions; each is registered once (a second RegisterHook on the same
-- function would add a second callback: they stack).
-- The trade event's class is loaded here (as before); the others are only
-- waited for (BP_JigComponent comes with every character, BP_MasterTrader
-- with the first wandering trader).
local BP_HOOKS = {
    { path = TRADE_EVENT_FN, load = TRADE_EVENT_CLASS, label = "trade event", fn = on_trade_event },
    { path = JIG_CLASS .. ":Handle Comp to Comp Move", label = "trade (Handle Comp to Comp Move)", fn = on_comp_move },
    { path = JIG_CLASS .. ":CheckVendorAmountOfMoney", label = "trader money (CheckVendorAmountOfMoney)", fn = on_vendor_money },
    { path = WANDERER .. ":OnExecuteInteractEnded", label = "wandering trader window closed", fn = on_wanderer_end },
    { path = NPC_CLASSES[3].path .. ":OnServerExecuteInteract", label = "quest giver interaction (OnServerExecuteInteract)",
      fn = on_giver_server, on_ok = function() giver.hook_ok = true end },
}
local bp_next_try = 0

ensure_bp_hooks = function(now)
    if now < bp_next_try then return end
    bp_next_try = now + 10
    if ue.in_main_menu() then return end
    for _, h in ipairs(BP_HOOKS) do
        if not h.done then
            if not ue.find_object(h.path) and h.load then ue.load_asset(h.load, "dialogue") end
            if ue.find_object(h.path) then
                local ok, err = pcall(RegisterHook, h.path, safe(h.label, h.fn))
                h.done = ok
                log.info("dlg: %s hook %s%s", h.label, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
                if not ok then h.done = "failed" elseif h.on_ok then h.on_ok() end
            end
        end
    end
end

-- Host, every second (sdc_session host_tick).
function M.host_tick(now)
    M.install()
    ensure_bp_hooks(now)
    -- drop routing marks of NPCs that are long done
    local c = os.clock()
    for a, h in pairs(handled) do
        if c - h.at > 5 then handled[a] = nil end
    end
    for a, d in pairs(giver.defer) do
        if c - d.at > 5 then giver.defer[a] = nil end
    end
    for k, v in pairs(money_last) do
        if c - v.at > 60 then money_last[k] = nil end
    end
    check_held()
end

function M.register_handlers()
    net.on("QD", function(f, pc) on_request(f, pc) end)
    net.on("QH", function(_, pc)
        if role() ~= "host" or not ue.valid(pc) then return end
        local key = ue.name(pc)
        if not hud_ready[key] then log.info("dlg: host: %s has a dialogue HUD", ue.short(pc)) end
        hud_ready[key] = os.time()
    end)
    net.on("QE", function(_, pc)
        if role() ~= "host" or not ue.valid(pc) then return end
        release_wanderer(ue.name(pc), "its player closed the trade window")
    end)
    net.on("QV", function() on_vendor_signal() end)
    net.on("QTM", function(f) on_money(f) end)
    net.on("QF", function(f) on_refused(f) end)
end

-- Role change / level change: drop every object reference without touching it.
-- (On a role change in the same world, e.g. the host's last client left, a
-- wandering trader stopped for a client walks again first.)
function M.reset(why)
    if tostring(why):find("^role") then
        local keys = {}   -- (release_wanderer may add an entry: not while pairs() walks held)
        for key, h in pairs(held) do if not h.host then keys[#keys + 1] = key end end
        for _, key in ipairs(keys) do pcall(release_wanderer, key, "session role changed") end
    end
    M.hud_widget = nil
    hud_pc_key, hud_tries, hud_next_try = nil, 0, 0
    handled, hud_ready, recent_start = {}, {}, {}
    asked, ghost_next, held, money_last = {}, 0, {}, {}
    class_cache, class_tried, spawner_by_class = {}, {}, {}
    giver.defer = {}
    log.info("dlg: reset (%s)", tostring(why))
end

function M.init(state)
    S = state
end

return M
