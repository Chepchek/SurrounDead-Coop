-- SDCoop: quests in co-op.
--
-- How the game does it (work\re, the exe's UFunction flags):
--   * Narrative 3 runs quests on the server: BeginQuest / ForgetQuest /
--     RestartQuest / NarrativeComponent.Save / Load, NarrativeTask.AddProgress
--     / CompleteTask / SetProgress and NarrativeFunctionLibrary.
--     CompleteNarrativeDataTask are BlueprintAuthorityOnly (flags 0x04020404 /
--     0x04080404 / 0x04022405): on a client the Blueprint VM absorbs them, no
--     hook fires. The component's PendingUpdateList replicates to its owner
--     (OnRep_PendingUpdateList; QuestList itself does not): a quest begun on
--     the host on a CLIENT's component shows in that client's own journal /
--     HUD, its tasks run on the host (BPT_GoToLocation checks the quest's
--     group = that player's pawn @43-376; BPT_CompleteDataTask listens on the
--     group members' components @47-208), its events run where it runs.
--   * Every Blueprint asks NarrativeFunctionLibrary.GetNarrativeComponent(self)
--     (= player 0's component, native: sdc_ctx cannot redirect it), so on the
--     host every quest went to the HOST's log and clients' components stayed
--     empty.
--   * Quest sources (the whole pak scanned for BeginQuest / BeginDialogue /
--     CompleteNarrativeDataTask): BP_BountyQuestManager.CallRandomEvent (the
--     Settlement Officer's "intel for 2500 cash" dialogue, Condition_CheckMoney
--     + Quest_Event_RandomBounty: 16 laptop bounties), BP_StartQuestArea
--     (Quest_Dungeon_LaboratoryBunker), BP_PlayerCharacter @9557-9679
--     (Quest_TheSafeZone for a fresh character, IsLocalController only),
--     BP_QuestGiver (data task Quest_Task_InteractWithActor, sdc_dialogue),
--     BP_LaboratoryGenerator.Event_TurnOn (Quest_Task_PowerOnGenerator, on
--     the presser's machine). Tasks: go to (BPT_GoToLocation), kill
--     (Quest_Task_SpawnNPCsToKill: BP_Quest_Spawner_AI's AIDeath, host),
--     loot a classified case (Quest_Task_SpawnObject: BP_Quest_Spawner_Object's
--     QuestAddProgress <- BP_GuaranteedSpawner.OpenContainer), data tasks.
--     Rewards: Quest_Event_RewardPlayerXP only (Controller's
--     LevellingComponent.AddXP); markers: Quest_Event_SpawnMarker /
--     RemoveMarker (a BP_QuestMarker actor, not replicated); bounties forget
--     themselves when done (NE_ForgetQuest). The game saves the host's quests
--     with Narrative's own Save into <slot>_SDQuests (BP_PlayerController
--     @2053-2131) and loads them in BP_PlayerCharacter @14347-14446.
--
-- quest_own on (default): each player has their own quests, as in single
-- player. Everything runs on the host on the right player's component:
--   bounty       host GetNarrativeComponent(BP_BountyQuestManager): the
--                remote player whose component is in the Settlement Officer's
--                dialogue gets None for the Blueprint and the bounty itself
--                (the same random pick, BeginQuest on their component; all
--                taken: the laptop back at them, as @640-873). If the event
--                runs on the client, its own request (QB) does the same once.
--   start area   host GetNarrativeComponent(BP_StartQuestArea) -> None unless
--                the host's own character is in the box; each second the
--                host begins the area's quest on every remote player whose
--                character is in it (Box.IsOverlappingActor).
--   start quest  a fresh client character (SpawnStartingItems? on the host's
--                copy) gets Quest_TheSafeZone on its own component 5 s later.
--   givers       sdc_dialogue: dialogue + Quest_Task_InteractWithActor on the
--                pressing player's component.
--   generator    a powered generator is the group's progress (the co-op world
--                is shared): every player's PowerOnGenerator task counts,
--                whoever powered it and wherever they stand. The host's own
--                Event_TurnOn (its press, a client's step run there, the
--                save's restore) credits the host (player 0, the game's own
--                call, nothing cleared); each client's Event_TurnOn (its own
--                press or the host's state applied there by sdc_world)
--                -> QT -> the host completes the data task on that client's
--                component. (Up to 0.11.0 the host's call got None when the
--                host stood over 15 m away: a client powering it left the
--                host's task undone for good - the generator was on.)
--   rewards      Quest_Event_RewardPlayerXP of a client's quest (Controller =
--                its controller) -> QX to that client only; the client adds
--                it on its own LevellingComponent (the XP's owner, PSPROG),
--                unless the reward event ran there too. A reward refired by
--                the Load of that player's quests is not sent (see refire);
--                the host's own refired one is the game's (noted for
--                sdc_savecheck).
--   markers      the host's copy of a client's quest marker is removed, the
--                client gets QM; the host's own quests' markers stay its own.
--   journal      "Forget quest" on a client (absorbed there) -> QQ -> the
--                host forgets it on that client's component.
--   save         M.persist_bind / persist_save / persist_delete (sdc_persist
--                calls them): Narrative's own Save / Load of the client's
--                component on the host, <slot>_SDQuests_<key>, saved again 5 s
--                after each change of that player's quests.
-- quest_own off: the old group design (the host's log is everyone's; client
-- actions credit it; clients get a mirror QS, markers and XP of the host's
-- quests).
--
-- Messages: client -> host  QT|<task asset path>|<argument>|<quantity>
--                           QC|x|y|z   QB   QQ|forget|<quest class path>
--           host -> client  QS|<quest>|<quest>...   quest = name~task~task,
--                                                   task = desc^cur^req^flags
--                           QM|a|tag|x|y|z|texture|text|r|g|b|a|underground   QM|d|tag
--                           QX|<xp>|<quest name>   QN|<code>
--
-- Hook callbacks are wrapped in pcall and return nothing. Engine objects are
-- looked up again or re-validated right before use; only our own marker
-- actors and the client's last snapshot (plain data) are kept between ticks,
-- and dropped untouched on a level change.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local dialogue = require("sdc_dialogue")
local consume = require("sdc_consume")   -- shared helpers (param)

-- counters of the F7 panel lines (status_lines)
local M = {
    stats = { bounties = 0, areas = 0, starts = 0, forgets = 0, saves = 0, loads = 0 },
}

local S   -- sdc_session.state

local function own() return cfg.get("quest_own") ~= false end

-- ---------------------------------------------------------------------------
-- Game assets
-- ---------------------------------------------------------------------------

local LIB_CDO = "/Script/Narrative.Default__NarrativeFunctionLibrary"
local SPAWN_MARKER = "/Game/Quests/Events/Quest_Event_SpawnMarker.Quest_Event_SpawnMarker_C"
local REMOVE_MARKER = "/Game/Quests/Events/Quest_Event_RemoveMarker.Quest_Event_RemoveMarker_C"
local REWARD_XP = "/Game/Quests/Events/Reward/Quest_Event_RewardPlayerXP.Quest_Event_RewardPlayerXP_C"
local CRATE = "/Game/Quests/Blueprints/Objects/BP_GuaranteedSpawner.BP_GuaranteedSpawner_C"
local CRATE_SHORT = "BP_GuaranteedSpawner_C"
local MARKER = "/Game/Quests/Blueprints/Objects/BP_QuestMarker.BP_QuestMarker_C"
local MARKER_SHORT = "BP_QuestMarker_C"
local TEXTBLOCK = "/Script/UMG.TextBlock"
local GOTO_CLASS = "BPT_GoToLocation_C"
local JOURNAL = "/Game/UI/Widgets/Journal/Journal_QuestsUI.Journal_QuestsUI_C"

-- per-player quests (quest_own)
local Q = {
    SAFEZONE = "/Game/Quests/Quests/Random/Quest_TheSafeZone.Quest_TheSafeZone_C",
    POWER_TASK = "/Game/Quests/Tasks/Quest_Task_PowerOnGenerator.Quest_Task_PowerOnGenerator",
    LAPTOP = "/Game/Inventory/Items/DataAssets/Quest/DA_MilitaryIntelLaptop.DA_MilitaryIntelLaptop",
    MANAGER_SHORT = "BP_BountyQuestManager_C",
    AREA_SHORT = "BP_StartQuestArea_C",
    INTEL_DIALOGUE = "Dialogue_SettlementIntelGiver_C",
    F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    F_PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB",
    START_DELAY = 5,       -- s after a fresh client character appears
    SAVE_DELAY = 5,        -- s after a change of a client's quests
    BOUNTY_GAP = 5,        -- s: one bounty per player and intel purchase
}

local QC_STARTED = 1          -- EQuestCompletion::QC_Started
local MAX_QUESTS = 8
local TEXT_MAX = 80           -- characters per quest / task text in QS
local QS_RESEND_S = 30
local CRATE_MATCH = 400       -- uu between the client's crate and the host's
local CRATE_PAWN = 1200       -- uu between the crate and the client's character

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function role() return S and S.role or "unknown" end

local pget = consume.param

local function each(arr, fn)
    if arr == nil then return end
    pcall(function()
        arr:ForEach(function(_, e)
            local v = e:get()
            if v ~= nil then fn(v) end
        end)
    end)
end

-- An object by its path: loaded if needed on the host; on a client only one
-- already in memory (the marker class and texture come in a QM message:
-- no synchronous load on a client).
local function load_obj(path)
    if role() == "client" then return ue.loaded_asset(path, "quests") end
    local o = ue.find_object(path)
    if o then return o end
    ue.load_asset(path, "quests")
    return ue.find_object(path)
end

local function dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function vec(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

local function transform(loc)
    return {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
end

-- Text safe for one QS / QM field: no separators, no control characters,
-- at most TEXT_MAX characters (cut on a UTF-8 boundary).
local function clean(s)
    s = tostring(s or ""):gsub("[%c~%^|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local ok, cut = pcall(utf8.offset, s, TEXT_MAX + 1)
    if ok and cut then s = s:sub(1, cut - 1) end
    return s
end

local function split(s, sep)
    local out, i = {}, 1
    while true do
        local j = s:find(sep, i, true)
        if not j then out[#out + 1] = s:sub(i) break end
        out[#out + 1] = s:sub(i, j - 1)
        i = j + #sep
    end
    return out
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("quests." .. name, "quests: %s: %s", name, tostring(err)) end
    end
end

local function remote_pcs()
    local out = {}
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        if ue.valid(pc) then out[#out + 1] = pc end
    end
    return out
end

local function host_comp()
    local pc = ue.local_pc()
    local comp = pc and ue.prop(pc, "NarrativeComponent")
    if ue.valid(comp) then return comp end
    return nil
end

local function comp_of(pc)
    local comp = ue.prop(pc, "NarrativeComponent")
    if ue.valid(comp) then return comp end
    return nil
end

local function call_text(o, fname)
    local ok, v = pcall(function() return o[fname](o) end)
    if ok and v ~= nil then return ue.str(v) end
    return nil
end

local addr = ctx.addr

-- The remote controller among an event's parameters (Controller), or nil
-- for the host's own controller / none.
local function remote_owner(ctl)
    if not ue.valid(ctl) then return nil end
    if not ue.valid(ue.prop(ctl, "NetConnection")) then return nil end
    return ctl
end

-- Quest class path without the class prefix ("/Game/....Quest_X_C").
local function class_path(cls)
    return ue.valid(cls) and ue.path(cls) or ""
end

local function short_path(p) return tostring(p):match("([^%./]+)$") or tostring(p) end

-- ---------------------------------------------------------------------------
-- Host: snapshot of a quest log
-- ---------------------------------------------------------------------------

local function task_desc(t)
    local over = ue.str(ue.prop(t, "DescriptionOverride"))
    if over ~= "" then return over end
    return call_text(t, "GetTaskDescription") or ue.short(t)
end

-- A quest's name as its journal shows it (Journal_QuestButtonUI: Quest
-- .GetQuestName = QuestName); the class without "_C" when it has no text.
local function quest_title(q)
    if not ue.valid(q) then return "" end
    local s = ue.str(ue.prop(q, "QuestName"))
    if s == "" then s = call_text(q, "GetQuestName") or "" end
    if s == "" then s = (ue.class_name(q):gsub("_C$", "")) end
    return s
end
M._quest_title = quest_title

local function task_done(t, cur, req)
    local ok, v = pcall(function() return t:IsComplete() end)
    if ok and type(v) == "boolean" then return v end
    return cur >= req
end

-- { { name =, tasks = { { obj =, cls =, desc =, cur =, req =, done =, optional = } } } }
-- Task objects are only for this tick's go-to check.
local function snapshot(comp)
    local list = {}
    each(ue.prop(comp, "QuestList"), function(q)
        if #list >= MAX_QUESTS or not ue.valid(q) then return end
        if tonumber(ue.prop(q, "QuestCompletion")) ~= QC_STARTED then return end
        local entry = { name = quest_title(q), cls = ue.class_name(q), tasks = {} }
        local st = ue.prop(q, "CurrentState")
        if ue.valid(st) then
            each(ue.prop(st, "Branches"), function(b)
                if not ue.valid(b) or ue.prop(b, "bHidden") == true then return end
                each(ue.prop(b, "QuestTasks"), function(t)
                    if not ue.valid(t) or ue.prop(t, "bHidden") == true then return end
                    local cur = tonumber(ue.prop(t, "CurrentProgress")) or 0
                    local req = tonumber(ue.prop(t, "RequiredQuantity")) or 1
                    entry.tasks[#entry.tasks + 1] = {
                        obj = t, cls = ue.class_name(t), desc = task_desc(t),
                        cur = cur, req = req, done = task_done(t, cur, req),
                        optional = ue.prop(t, "bOptional") == true,
                    }
                end)
            end)
        end
        list[#list + 1] = entry
    end)
    return list
end

-- One snapshot per component and host tick: host_own_tick's save check and
-- shared_tick read the same quest logs in the same second. `tick_snaps` is a
-- table only while M.host_tick runs (no task object outlives the tick).
local tick_snaps = nil
local function snapshot_once(comp)
    if not tick_snaps then return snapshot(comp) end
    local k = ue.name(comp)
    local list = tick_snaps[k]
    if not list then
        list = snapshot(comp)
        tick_snaps[k] = list
    end
    return list
end

local function encode(list)
    local fields = {}
    for _, q in ipairs(list) do
        local parts = { clean(q.name) }
        for _, t in ipairs(q.tasks) do
            parts[#parts + 1] = table.concat({ clean(t.desc), tostring(t.cur), tostring(t.req),
                (t.done and "d" or "") .. (t.optional and "o" or "") }, "^")
        end
        fields[#fields + 1] = table.concat(parts, "~")
    end
    return fields
end

-- BPT_GoToLocation for remote characters in the group design (the task itself
-- checks only the quest owner = the host).
local function goto_check(list, pcs)
    local pawns = {}
    for _, pc in ipairs(pcs) do
        local p = ue.pawn_of(pc)
        local loc = p and ue.location(p)
        if loc then pawns[#pawns + 1] = { pc = pc, loc = loc } end
    end
    if #pawns == 0 then return end
    for _, q in ipairs(list) do
        for _, t in ipairs(q.tasks) do
            if t.cls == GOTO_CLASS and not t.done and ue.valid(t.obj) and ue.prop(t.obj, "Invert?") ~= true then
                local ga = ue.prop(t.obj, "GoalActor")
                local goal = (ue.valid(ga) and ue.location(ga)) or vec(ue.prop(t.obj, "GoalLocation"))
                local tol = tonumber(ue.prop(t.obj, "DistanceTolerance")) or 0
                if goal and tol > 0 then
                    for _, p in ipairs(pawns) do
                        local d2 = dist2(p.loc, goal)
                        if d2 < tol * tol then
                            local ok, err = pcall(function() t.obj:CompleteTask() end)
                            log.info("quests: host: go-to task '%s' of '%s' completed for the group by %s (%.0f m from the goal): %s",
                                t.desc, q.name, ue.short(p.pc), math.sqrt(d2) / 100, ok and "ok" or tostring(err))
                            break
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Shared laptop bounties (quest_own + quest_bounty_shared)
-- ---------------------------------------------------------------------------
-- A laptop bounty stays the buyer's quest: their journal, their tasks (the
-- kill task counts the spawner's AIDeath, whoever killed). A second
-- BeginQuest on the other players' components would spawn its camp and NPCs
-- again (Quest_Task_SpawnNPCsToKill.K2_BeginTask -> BP_Quest_Spawner_AI
-- .Quest_Spawn). So the others get a copy to look at: the marker (QM, the
-- host's copy stays), its tasks on the HUD tracker (QG to clients; the host
-- shows a client's bounty itself), the go-to task done by anyone near, and
-- the reward's XP for everyone.
local SH = {
    sent = {},     -- [controller name] = last QG string sent
    known = {},    -- [controller name] = true once its character got the markers
    markers = {},  -- [tag] = QM fields of a shared bounty's marker (for joiners)
    view = nil,    -- this machine's copy of the others' bounties (plain data)
}

local function is_bounty_class(name)
    return type(name) == "string" and name:sub(1, 13) == "Quest_Bounty_"
end

local function shared_on() return own() and cfg.get("quest_bounty_shared") ~= false end

-- The quest object an event of it belongs to: the first outer with a
-- QuestName (event -> QuestState / QuestBranch -> quest). ue.has_prop, not
-- "~= nil": UE4SS reads the state's missing QuestName as a TrivialObject, so
-- the state itself passed for the quest - its name logged and sent in QX as
-- "TrivialObject: <address>", and no laptop bounty recognised as one (logs
-- of 2026-11-11 / 12).
local function quest_of(ev)
    -- GetOuter on a null object (not nil) crashes the game: valid first
    if not ue.valid(ev) then return nil end
    local o = ev
    for _ = 1, 5 do
        o = ue.try(function() return o:GetOuter() end)
        if not ue.valid(o) then return nil end
        if ue.has_prop(o, "QuestName") then return o end
    end
    return nil
end

local function bounty_event(ev)
    if not shared_on() or not ue.valid(ev) then return false end
    local q = quest_of(ev)
    return q ~= nil and is_bounty_class(ue.class_name(q))
end

-- ---------------------------------------------------------------------------
-- Host: markers
-- ---------------------------------------------------------------------------

local function color_fields(c)
    local ok, r, g, b, a = pcall(function() return c.R, c.G, c.B, c.A end)
    if ok and type(r) == "number" then return r, g, b, a end
    return 1, 1, 1, 1
end

local function marker_fields(tag, loc, tex, text, color, ug)
    local r, g, b, a = color_fields(color)
    return "a", clean(tag), string.format("%.0f", loc.X), string.format("%.0f", loc.Y), string.format("%.0f", loc.Z),
        ue.valid(tex) and ue.path(tex) or "", clean(text),
        string.format("%.3f", r), string.format("%.3f", g), string.format("%.3f", b), string.format("%.3f", a),
        ug and "1" or "0"
end

local function first_tag(actor)
    local tag
    pcall(function()
        actor.Tags:ForEach(function(_, e)
            if not tag then tag = ue.str(e:get()) end
        end)
    end)
    return tag
end

-- A destroyed actor stays valid for ~30 s (until GC) and its location reads
-- 0,0,0: markers destroyed here are remembered by full name (60 s), and a
-- marker at 0,0,0 counts as gone.
local gone_markers = {}   -- [full name] = os.clock() of its K2_DestroyActor here

local function destroy_marker_actor(a)
    local now = os.clock()
    for k, t in pairs(gone_markers) do
        if now - t > 60 then gone_markers[k] = nil end
    end
    gone_markers[ue.name(a)] = now
    return (pcall(function() a:K2_DestroyActor() end))
end

-- A marker destroyed here, or one at 0,0,0 (destroyed elsewhere: the
-- game's RemoveMarker).
local function marker_gone(a)
    if gone_markers[ue.name(a)] then return true end
    local loc = ue.location(a)
    return loc ~= nil and loc.X == 0 and loc.Y == 0 and loc.Z == 0
end

-- All quest markers the host has now (also those of a loaded save): the
-- runtime-spawned BP_QuestMarker actors. Level-placed ones exist on clients.
local function send_all_markers(pc)
    local n = 0
    for _, a in ipairs(ue.find_all(MARKER_SHORT)) do
        if ue.valid(a) and ue.is_runtime_spawned(a) then
            local tag, loc = first_tag(a), not marker_gone(a) and ue.location(a)
            if tag and tag ~= "" and loc then
                net.send_to(pc, "QM", marker_fields(tag, loc, ue.prop(a, "Marker Texture"), ue.str(ue.prop(a, "Text")),
                    ue.prop(a, "Color"), ue.prop(a, "Underground?") == true))
                n = n + 1
            end
        end
    end
    if n > 0 then log.info("quests: host: %d quest marker(s) sent to %s", n, ue.short(pc)) end
end

-- The marker a client's quest just placed in the host's world (the newest
-- runtime-spawned BP_QuestMarker with that tag: names count down) goes.
local function drop_host_marker(tag)
    local best, best_n = nil, math.huge
    for _, a in ipairs(ue.find_all(MARKER_SHORT)) do
        if ue.valid(a) and ue.is_runtime_spawned(a) and not marker_gone(a) and first_tag(a) == tag then
            local n = tonumber(ue.short(a):match("_(%d+)$")) or math.huge
            if n < best_n then best, best_n = a, n end
        end
    end
    if not best then return false end
    return destroy_marker_actor(best)
end

local function on_spawn_marker(ev_p, _, ctl_p)
    if role() ~= "host" or not cfg.get("quest_markers") then return end
    local ev = pget(ev_p)
    local tag = ue.str(ue.prop(ev, "ActorTag"))
    local loc = vec(ue.prop(ev, "Location"))
    if tag == "" or not loc then return end
    local fields = table.pack(marker_fields(tag, loc, ue.prop(ev, "Marker Texture"), ue.str(ue.prop(ev, "Text")),
        ue.prop(ev, "Color"), ue.prop(ev, "Underground?") == true))
    if own() then
        local pc = remote_owner(pget(ctl_p))
        if bounty_event(ev) then
            -- a shared laptop bounty: every client gets it, the host's copy stays
            SH.markers[tag] = fields
            local pcs = remote_pcs()
            log.info("quests: host: quest marker '%s' of %s laptop bounty: shared, sent to %d client(s); the host's copy stays",
                tag, pc and (ue.short(pc) .. "'s") or "the host's", #pcs)
            ue.game_thread("quests-qm-shared", function()
                for _, p in ipairs(pcs) do
                    if ue.valid(p) then net.send_to(p, "QM", table.unpack(fields, 1, fields.n)) end
                end
            end)
            return
        end
        if not pc then
            log.info("quests: host: quest marker '%s' of the host's own quest (stays the host's)", tag)
            return
        end
        log.info("quests: host: quest marker '%s' of %s's quest: sent to them; the copy in the host's world goes", tag, ue.short(pc))
        ue.game_thread("quests-qm-own", function()
            local gone = drop_host_marker(tag)
            if ue.valid(pc) then net.send_to(pc, "QM", table.unpack(fields, 1, fields.n)) end
            if not gone then log.debug("quests: host: no host copy of marker '%s' found", tag) end
        end)
        return
    end
    local pcs = remote_pcs()
    log.info("quests: host: quest marker '%s' added, sent to %d client(s)", tag, #pcs)
    ue.game_thread("quests-qm", function()
        for _, pc in ipairs(pcs) do
            if ue.valid(pc) then net.send_to(pc, "QM", table.unpack(fields, 1, fields.n)) end
        end
    end)
end

local function on_remove_marker(ev_p, _, ctl_p)
    if role() ~= "host" or not cfg.get("quest_markers") then return end
    local ev = pget(ev_p)
    local tag = ue.str(ue.prop(ev, "ActorTag"))
    if tag == "" then return end
    local pcs = remote_pcs()
    if own() then
        if SH.markers[tag] or bounty_event(ev) then
            SH.markers[tag] = nil   -- a shared bounty's marker: off every client's map
        else
            local pc = remote_owner(pget(ctl_p))
            if not pc then return end
            pcs = { pc }
        end
    end
    log.info("quests: host: quest marker '%s' removed, sent to %d client(s)", tag, #pcs)
    ue.game_thread("quests-qm", function()
        for _, pc in ipairs(pcs) do
            if ue.valid(pc) then net.send_to(pc, "QM", "d", clean(tag)) end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- XP reward (both roles)
-- ---------------------------------------------------------------------------

local cl = {
    quests = nil,        -- last snapshot (plain data) or nil before the first QS
    xp_recent = {},      -- [quest name] = os.clock() of its XP reward
    markers = {},        -- [tag] = { rec = fields, actor = our BP_QuestMarker or nil }
    pawn_key = nil,
    level_timer = {},
    tb_class = nil,
    local_xp = nil,      -- { at, amount } of a reward event that ran on this machine
    qb_at = -100,        -- last bounty request (QB)
    qt_at = {},          -- [task path|argument] = os.clock() of the last QT
    journal_quest = nil, -- { path, at } of the quest the journal shows
}

local function quest_name_of(ev)
    return quest_title(quest_of(ev))
end

-- Rewards given again by a quest LOAD. Narrative refires a quest's events
-- when its save is loaded: UNarrativeEvent's constructor sets bRefireOnLoad
-- (offset 0x28, its SetBit at exe 0x1445b3b20) to true (exe 0x144850395),
-- and no event asset of the game changes it (json dumps: no bRefireOnLoad
-- anywhere). Quest_TheSafeZone ("My New Quest", every fresh character's)
-- ends in Event_RewardPlayerXP_C_0, Amount 300: each load runs it again and
-- LevellingComponent.AddXP multiplies it by the difficulty's XP multiplier.
--   * the host's own quests: loaded by the game itself (BP_PlayerCharacter
--     @14347-14446 "<slot>_SDQuests"): that XP is the game's own (13.11:
--     +1200 at each load, single player too); only noted (refire.host, read
--     by sdc_savecheck for its load line).
--   * a client's quests: loaded by this mod (M.persist_bind: Narrative Load
--     on the client's component) - a reward event that runs inside that Load
--     (or right after it) is not sent to the client (13.11: QX|300 and a
--     "+300 XP" toast at every join).
local REFIRE_S = 2
local refire = { key = nil, till = -1, host = {} }   -- key: the controller whose quests load now

-- pawn: the host's character when the reward ran (its full name). A load
-- starts from the main menu, where the old character is gone, and the game
-- refires the quests in the NEW character's Event_LoadPlayer: a real reward
-- of the world before the load has another pawn (sdc_savecheck tells them apart).
local function note_host_reward(amount, qname)
    local h = refire.host
    local p = ue.local_pawn()
    local pk = ue.valid(p) and ue.name(p) or nil
    h[#h + 1] = { at = os.clock(), amount = amount, name = qname, pawn = pk }
    if #h > 8 then table.remove(h, 1) end
end

-- The host's own quest rewards since os.clock() t: { amount, name, pawn }... (sdc_savecheck).
function M.host_rewards_since(t)
    local out = {}
    for _, e in ipairs(refire.host) do
        if e.at >= t then out[#out + 1] = { amount = e.amount, name = e.name, pawn = e.pawn } end
    end
    return out
end

local function on_reward_xp(ev_p, _, ctl_p)
    local ev, ctl = pget(ev_p), pget(ctl_p)
    local amount = tonumber(ue.prop(ev, "Amount")) or 0
    if role() == "client" then
        -- the reward ran here too (this machine's copy of the quest)
        cl.local_xp = { at = os.clock(), amount = amount }
        log.info("quests: client: quest '%s' reward event ran here (+%.0f XP on this player's own LevellingComponent)",
            clean(quest_name_of(ev)), amount)
        return
    end
    if role() ~= "host" or not cfg.get("quest_xp") or amount <= 0 then return end
    local qname = clean(quest_name_of(ev))
    local pcs
    if own() then
        local pc = remote_owner(ctl)
        if pc and refire.key == ue.name(pc) and os.clock() <= refire.till then
            log.info("quests: host: %s's quest '%s' reward event (%d XP) ran again while their quests were loaded (Narrative refires quest events on Load): not sent, no XP twice",
                ue.short(pc), qname, amount)
            return
        end
        if bounty_event(ev) then
            -- a shared laptop bounty: its XP for every player (the owner's
            -- comes from this event when it is the host's own)
            pcs = remote_pcs()
            log.info("quests: host: %s laptop bounty '%s' rewards %d XP: shared, sent to %d client(s)%s",
                pc and (ue.short(pc) .. "'s") or "the host's", qname, amount, #pcs,
                pc and "; the host gets it too" or "; the host's own from the event")
            if pc then
                ue.game_thread("quests-qx-host", function()
                    if role() == "host" and M._apply_xp then M._apply_xp(amount, qname) end
                end)
            end
            ue.game_thread("quests-qx", function()
                for _, p in ipairs(pcs) do
                    if ue.valid(p) then
                        net.send_to(p, "QX", string.format("%.0f", amount), qname)
                    end
                end
            end)
            return
        end
        if not pc then
            note_host_reward(amount, qname)
            log.info("quests: host: the host's quest '%s' rewards %d XP (the host's own)", qname, amount)
            return
        end
        pcs = { pc }
        log.info("quests: host: %s's quest '%s' rewards %d XP; sent to them (their XP lives on their machine)", ue.short(pc), qname, amount)
    else
        local me = ue.local_pc()
        if not ue.valid(ctl) or not me or ue.name(ctl) ~= ue.name(me) then return end   -- group (host) quests only
        note_host_reward(amount, qname)
        pcs = remote_pcs()
        log.info("quests: host: quest '%s' rewards %d XP; sending it to %d client(s)", qname, amount, #pcs)
    end
    ue.game_thread("quests-qx", function()
        for _, pc in ipairs(pcs) do
            if ue.valid(pc) then
                net.send_to(pc, "QX", string.format("%.0f", amount), qname)
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Host: per-player quests (quest_own)
-- ---------------------------------------------------------------------------

local P = {
    bounty_at = {},     -- [controller name] = os.clock() of the last bounty
    bounty_clear = {},  -- [manager address] = os.clock() until which its GetNarrativeComponent gets None
    areas = {}, areas_at = -100,
    starts = {},        -- [pawn full name] = { at, done }
    bound = {},         -- [controller full name] = { name, sig, dirty_at }
    logged = {},        -- [key] = os.clock() (throttle)
}

local function throttled(key, s)
    local now = os.clock()
    if P.logged[key] and now - P.logged[key] < (s or 10) then return false end
    P.logged[key] = now
    return true
end

local function started(comp, cls)
    local ok, r = pcall(function() return comp:IsQuestStartedOrFinished(cls) end)
    return ok and r == true, ok
end

local function begin_quest(pc, cls, why)
    local comp = comp_of(pc)
    if not comp or not ue.valid(cls) then return false end
    local ok, r = pcall(function() return comp:BeginQuest(cls, FName("None")) end)
    log.info("quests: host: %s begun on the own quest log of %s (%s) -> %s", ue.short(cls), ue.short(pc), why,
        ok and (ue.valid(r) and "ok" or "None") or ("error " .. tostring(r)))
    return ok and ue.valid(r)
end

-- The game's own notices of a bounty: Quest_Event_RandomBounty.ExecuteEvent
-- @114 (text, icon <map>, delay 2) and BP_BountyQuestManager.CallRandomEvent
-- @873 (no icon, delay 5).
local BOUNTY_NOTE = {
    pinned = { "Quest pinned to your map", "/Game/UI/Textures/over_250_survival_flat_icons/map.map", 2 },
    all = { "All Laptop Quests Completed. Come Back Later...", "", 5 },
}

-- That notice on that player's screen through sdc_notes (the game's widget,
-- text and icon); false without sdc_notes / with notes_relay off: the QN
-- toast as before.
local function bounty_note(pc, which)
    local notes = package.loaded["sdc_notes"]
    if not (notes and notes.show_to) or cfg.get("notes_relay") == false then return false end
    local b = BOUNTY_NOTE[which]
    return notes.show_to(pc, b[1], b[2], nil, b[3], "quests: the bounty's notice") == true
end

-- As BP_BountyQuestManager.CallRandomEvent (@0-873), on `pc`'s component.
local function give_bounty(pc, why)
    if not ue.valid(pc) then return end
    local key = ue.name(pc)
    local now = os.clock()
    if P.bounty_at[key] and now - P.bounty_at[key] < Q.BOUNTY_GAP then
        log.info("quests: host: bounty for %s already given %.1f s ago (%s): not again", ue.short(pc), now - P.bounty_at[key], why)
        return
    end
    P.bounty_at[key] = now
    local comp = comp_of(pc)
    local mgr = ue.find_first(Q.MANAGER_SHORT)
    if not comp or not mgr then
        log.warn("quests: host: bounty for %s (%s): component=%s manager=%s", ue.short(pc), why, tostring(comp ~= nil), tostring(mgr ~= nil))
        return
    end
    local list = {}
    each(ue.prop(mgr, "Quests"), function(q) list[#list + 1] = q end)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    for _, q in ipairs(list) do
        local is, ok = started(comp, q)
        if ok and not is then
            -- the quest's own events run inside BeginQuest: their notice
            -- ("Quest pinned to your map") is that player's (sdc_notes)
            local begun, raised = false, 0
            local notes = package.loaded["sdc_notes"]
            local why_q = "intel bought from the Settlement Officer: " .. why
            if notes and notes.for_player then
                local _, _, n = notes.for_player(pc, function() begun = begin_quest(pc, q, why_q) end)
                raised = tonumber(n) or 0
            else
                begun = begin_quest(pc, q, why_q)
            end
            if begun then
                M.stats.bounties = M.stats.bounties + 1
                if raised > 0 then
                    log.info("quests: host: the bounty's own notice went to %s (sdc_notes)", ue.short(pc))
                elseif not bounty_note(pc, "pinned") then
                    net.send_to(pc, "QN", "pinned")
                end
            end
            return
        end
    end
    -- every bounty is on their log: the game gives the laptop back at the
    -- player (@640-805) with "All Laptop Quests Completed. Come Back Later..."
    local pawn = ue.pawn_of(pc)
    local da = ue.find_object(Q.LAPTOP)
    local dropped = false
    if pawn and da then
        local out = {}
        dropped = pcall(function()
            pawn:JigMP_OnRequestDropItem({ [Q.F_ITEMID] = da, [Q.F_COUNT] = 1, [Q.F_PENDING] = -1 }, FName("None"), out)
        end) and ue.valid(out.ActorRef)
    end
    log.info("quests: host: %s already has all %d laptop bounties: military intel laptop dropped at them (%s)",
        ue.short(pc), #list, tostring(dropped))
    if not bounty_note(pc, "all") then net.send_to(pc, "QN", "bounty_all") end
end

-- The remote player whose component is in the Settlement Officer's dialogue
-- (nil when nobody is, or the host's own component is in it).
local function intel_buyer()
    local function in_intel(comp)
        local d = ue.prop(comp, "CurrentDialogue")
        return ue.valid(d) and ue.class_name(d) == Q.INTEL_DIALOGUE
    end
    local hc = host_comp()
    if hc and in_intel(hc) then return nil end
    for _, pc in ipairs(remote_pcs()) do
        local comp = comp_of(pc)
        if comp and in_intel(comp) then return pc end
    end
    return nil
end

local function overlapping(area, pawn)
    local box = ue.prop(area, "Box")
    if not ue.valid(box) or not pawn then return false end
    local ok, r = pcall(function() return box:IsOverlappingActor(pawn) end)
    return ok and r == true
end

local function clear_wco(wco_p)
    return (pcall(function() wco_p:set(nil) end))
end

-- GetNarrativeComponent(self) of a quest object (sdc_dialogue's native
-- pre-hook): role, kind, the object, its parameter.
local function quest_gnc(r, kind, obj, wco_p)
    if r == "client" then
        local now = os.clock()
        if kind == "bounty" then
            -- the intel event ran here; its BeginQuest is absorbed here
            if now - cl.qb_at > 3 then
                cl.qb_at = now
                log.info("quests: client: the bounty event ran here (its BeginQuest is server-only); asking the host (QB)")
                ue.game_thread("quests-qb", function() net.send_to_host("QB") end)
            end
        elseif kind == "generator" and cfg.get("quest_datatask") then
            -- Event_TurnOn @1702: its CompleteNarrativeDataTask is absorbed here
            local arg = ue.str(ue.prop(obj, "QuestArgument"))
            local key = Q.POWER_TASK .. "|" .. arg
            if not cl.qt_at[key] or now - cl.qt_at[key] > 5 then
                cl.qt_at[key] = now
                log.info("quests: client: %s powered on here: data task Quest_Task_PowerOnGenerator(%s) sent to the host (QT)",
                    ue.short(obj), arg)
                ue.game_thread("quests-qt-send", function() net.send_to_host("QT", Q.POWER_TASK, clean(arg), "1") end)
            end
        end
        return
    end
    if r ~= "host" or not own() then return end
    local now = os.clock()
    if kind == "bounty" then
        local a = addr(obj)
        if a and P.bounty_clear[a] and now < P.bounty_clear[a] then
            clear_wco(wco_p)
            return
        end
        local pc = intel_buyer()
        if not pc then return end
        if clear_wco(wco_p) then
            if a then P.bounty_clear[a] = now + 0.5 end
            log.info("quests: host: the bounty event runs for %s (in the Settlement Officer's dialogue): the Blueprint gets None, the bounty goes to their own log",
                ue.short(pc))
            ue.game_thread("quests-bounty", function() give_bounty(pc, "their dialogue's event on the host") end)
        end
    elseif kind == "area" then
        local me = ue.local_pawn()
        if overlapping(obj, me) then return end
        if clear_wco(wco_p) and throttled("area" .. tostring(addr(obj))) then
            log.info("quests: host: %s noticed another player (not the host's character): the host's quest log stays untouched (each player gets it in their own)",
                ue.short(obj))
        end
    end
    -- (kind "generator": the host's own data task counts too - the group's
    -- progress, wherever the host stands; see the header)
end
dialogue.quest_gnc = quest_gnc

-- Each second: start areas and the starting quest for remote players.
local function host_own_tick()
    local now = os.clock()
    local pcs = remote_pcs()
    if now - P.areas_at > 10 then
        P.areas_at = now
        P.areas = ue.find_all(Q.AREA_SHORT)
    end
    for _, pc in ipairs(pcs) do
        local pawn = ue.pawn_of(pc)
        local comp = comp_of(pc)
        if pawn and comp then
            for _, area in ipairs(P.areas) do
                if ue.valid(area) and overlapping(area, pawn) then
                    local cls = ue.prop(area, "Quest")
                    local is, ok = started(comp, cls)
                    if ok and not is and ue.valid(cls) then
                        if begin_quest(pc, cls, "their character entered " .. ue.short(area)) then M.stats.areas = M.stats.areas + 1 end
                    end
                end
            end
            -- a fresh character gets the starting quest (@9557-9679, as for
            -- the host's own new character)
            local key = ue.name(pawn)
            local st = P.starts[key]
            if not st then
                P.starts[key] = { at = now }
            elseif not st.done and now - st.at >= Q.START_DELAY then
                st.done = true
                if ue.prop(pawn, "SpawnStartingItems?") == true then
                    local cls = load_obj(Q.SAFEZONE)
                    local is, ok = started(comp, cls)
                    if ok and not is then
                        if begin_quest(pc, cls, "a fresh character, the game's starting quest") then M.stats.starts = M.stats.starts + 1 end
                    else
                        log.info("quests: host: %s's fresh character: starting quest already on their log", ue.short(pc))
                    end
                end
            end
        end
    end
    -- quest log changes of bound players: saved SAVE_DELAY s later
    for _, pc in ipairs(pcs) do
        local b = P.bound[ue.name(pc)]
        local comp = b and comp_of(pc)
        if comp then
            local sig = table.concat(encode(snapshot_once(comp)), "|")
            if b.sig == nil then
                b.sig = sig
            elseif sig ~= b.sig then
                if not b.dirty_at then b.dirty_at = now end
                if now - b.dirty_at >= Q.SAVE_DELAY then
                    b.dirty_at = nil
                    b.sig = sig
                    M.persist_save(pc, "their quests changed")
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: requests from clients
-- ---------------------------------------------------------------------------

local function on_task_request(f, pc)
    ue.game_thread("quests-qt", function()
        if role() ~= "host" or not cfg.get("quest_datatask") or not ue.valid(pc) then return end
        local path, arg, qty = f[1] or "", f[2] or "", tonumber(f[3]) or 1
        local task = path ~= "" and load_obj(path)
        local comp = own() and comp_of(pc) or host_comp()
        local lib = ue.find_object(LIB_CDO)
        if not task or not comp or not lib then
            log.warn("quests: host: data task %s from %s not credited (task=%s component=%s library=%s)",
                path, ue.short(pc), tostring(task ~= nil and task ~= false), tostring(comp ~= nil), tostring(lib ~= nil))
            return
        end
        local ok, r = pcall(function() return lib:CompleteNarrativeDataTask(comp, task, arg, qty) end)
        log.info("quests: host: data task %s(%s) x%d from %s credited to %s -> %s",
            ue.short(task), arg, qty, ue.short(pc), own() and "their own quest log" or "the group quest log",
            ok and tostring(r) or ("error " .. tostring(r)))
    end)
end

local function on_crate_request(f, pc)
    ue.game_thread("quests-qc", function()
        if role() ~= "host" or not cfg.get("quest_crate") or not ue.valid(pc) then return end
        local x, y, z = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
        local pawn = ue.pawn_of(pc)
        local ploc = pawn and ue.location(pawn)
        if not (x and y and z and ploc) then return end
        local want = { X = x, Y = y, Z = z }
        local best, bd = nil, CRATE_MATCH * CRATE_MATCH
        for _, c in ipairs(ue.find_all(CRATE_SHORT)) do
            local loc = ue.valid(c) and ue.location(c)
            local d = loc and dist2(loc, want)
            if d and d < bd and dist2(loc, ploc) < CRATE_PAWN * CRATE_PAWN then best, bd = c, d end
        end
        if not best then
            log.warn("quests: host: crate opened by %s at %.0f,%.0f,%.0f not found on the host", ue.short(pc), x, y, z)
            return
        end
        if ue.prop(best, "Opened") == true then
            log.info("quests: host: crate %s opened by %s is already open on the host", ue.short(best), ue.short(pc))
            return
        end
        ue.set_prop(best, "CurrentActor", pawn)
        local ok, err = pcall(function() best:OpenContainer() end)
        log.info("quests: host: crate %s opened for %s on the host (quest progress, lid, reward item): %s, Opened=%s",
            ue.short(best), ue.short(pc), ok and "ok" or tostring(err), tostring(ue.prop(best, "Opened")))
    end)
end

local function on_bounty_request(_, pc)
    ue.game_thread("quests-qb-recv", function()
        if role() ~= "host" or not own() or not ue.valid(pc) then return end
        give_bounty(pc, "the event ran on their machine (QB)")
    end)
end

-- QQ|forget|<quest class path>: the journal's "Forget quest" on a client.
local function on_quest_request(f, pc)
    ue.game_thread("quests-qq", function()
        if role() ~= "host" or not own() or not ue.valid(pc) or f[1] ~= "forget" then return end
        local path = f[2] or ""
        local cls = path ~= "" and ue.find_object(path)
        local comp = comp_of(pc)
        if not cls or not comp then
            log.warn("quests: host: %s asked to forget %s: not found here", ue.short(pc), short_path(path))
            return
        end
        local is = started(comp, cls)
        if not is then
            log.info("quests: host: %s asked to forget %s, which is not on their log", ue.short(pc), short_path(path))
            return
        end
        local ok, r = pcall(function() return comp:ForgetQuest(cls) end)
        M.stats.forgets = M.stats.forgets + 1
        log.info("quests: host: %s forgot %s (journal) on their own quest log -> %s", ue.short(pc), short_path(path),
            ok and tostring(r) or ("error " .. tostring(r)))
    end)
end

-- ---------------------------------------------------------------------------
-- Host: saving a client's quests (sdc_persist calls these)
-- ---------------------------------------------------------------------------

-- The player's record key is known (restore or a fresh record): their quests
-- are saved as <slot>_SDQuests_<key> (Narrative's own Save of their component,
-- next to the game's <slot>_SDQuests) and, with load = true, loaded now
-- (NarrativeComponent.Load on the host: ClientReceiveSave to that client).
function M.persist_bind(pc, slot, key, load)
    if role() ~= "host" or not ue.valid(pc) or not slot or slot == "" or not key or key == "" then return false end
    local name = tostring(slot) .. "_SDQuests_" .. tostring(key)
    P.bound[ue.name(pc)] = { name = name, sig = nil, dirty_at = nil }
    if not load or not own() then return true end
    local comp = comp_of(pc)
    if not comp then
        log.warn("quests: host: %s has no NarrativeComponent: quests %s not loaded", ue.short(pc), name)
        return false
    end
    -- its finished quests' reward events run again inside this Load (see
    -- refire above): not sent to the player
    refire.key, refire.till = ue.name(pc), math.huge
    local ok, r = pcall(function() return comp:Load(name, 0) end)
    refire.till = os.clock() + REFIRE_S
    if ok and r == true then M.stats.loads = M.stats.loads + 1 end
    log.info("quests: host: %s's own quests loaded from %s -> %s", ue.short(pc), name,
        ok and (r == true and "ok" or "no save yet") or ("error " .. tostring(r)))
    return ok and r == true
end

function M.persist_save(pc, why)
    if role() ~= "host" or not own() or not ue.valid(pc) then return false end
    local b = P.bound[ue.name(pc)]
    local comp = comp_of(pc)
    if not b or not comp then return false end
    local ok, r = pcall(function() return comp:Save(b.name, 0) end)
    if ok and r == true then M.stats.saves = M.stats.saves + 1 end
    log.info("quests: host: %s's own quests saved to %s (%s) -> %s", ue.short(pc), b.name, tostring(why or "save"),
        ok and tostring(r) or ("error " .. tostring(r)))
    return ok and r == true
end

function M.persist_delete(slot, key)
    local gs = ue.gameplay_statics()
    if not gs or not slot or not key then return false end
    local name = tostring(slot) .. "_SDQuests_" .. tostring(key)
    local ok, r = pcall(function() return gs:DeleteGameInSlot(name, 0) end)
    log.info("quests: host: quest save %s deleted -> %s", name, ok and tostring(r) or ("error " .. tostring(r)))
    return ok and r == true
end

-- ---------------------------------------------------------------------------
-- Client: hooks
-- ---------------------------------------------------------------------------

local function on_open_container(crate_p)
    if role() ~= "client" or not cfg.get("quest_crate") then return end
    local crate = pget(crate_p)
    local loc = ue.location(crate)
    if not loc then return end
    log.info("quests: client: crate %s opened here; asking the host to open its copy", ue.short(crate))
    ue.game_thread("quests-qc-send", function()
        net.send_to_host("QC", string.format("%.0f", loc.X), string.format("%.0f", loc.Y), string.format("%.0f", loc.Z))
    end)
end

-- Journal_QuestsUI."Show Quest"(Quest), post (client): the quest it shows.
local function on_journal_show(_, quest_p)
    if role() ~= "client" then return end
    local q = pget(quest_p)
    local cls = ue.valid(q) and ue.try(function() return q:GetClass() end)
    if ue.valid(cls) then cl.journal_quest = { path = class_path(cls), at = os.clock() } end
end

-- Journal_QuestsUI.ForgetQuest, post (client): its NarrativeComp.ForgetQuest
-- (@6497) is server-only and was absorbed here.
local function on_journal_forget()
    if role() ~= "client" then return end
    local j = cl.journal_quest
    if not j or j.path == "" or os.clock() - j.at > 1800 then
        log.warn("quests: client: journal 'forget quest' pressed, but which quest it showed is unknown: not sent")
        return
    end
    log.info("quests: client: journal 'forget quest' %s: server-only here, asking the host (QQ)", short_path(j.path))
    net.send_to_host("QQ", "forget", j.path)
end

-- ---------------------------------------------------------------------------
-- Client: showing the group quests (group design only)
-- ---------------------------------------------------------------------------

local function notify(text, english)
    local hud = dialogue.hud()
    if hud then
        -- the player's language (sdc_i18n, through sdc_log's toast path)
        local shown = text
        if log.screen_text then
            local okt, s = pcall(log.screen_text, text)
            if okt and type(s) == "string" then shown = s end
        end
        local ok = pcall(function() hud["Add Notification"](hud, FText(shown), false) end)
        if ok then
            log.info("quests: %s: notification: %s", role(), english)
            return
        end
    end
    log.toast(text, "info", 6, "quests: client: " .. english)
end

local function tracker_line(t)
    local s = "• " .. t.desc
    if t.done then
        s = s .. " — выполнено"
    elseif t.req > 1 then
        s = s .. string.format("  (%d/%d)", t.cur, t.req)
    end
    if t.optional then s = s .. " (необязательно)" end
    return s
end

local function tracker(q, subtitle)
    if not cfg.get("quest_tracker") then return end
    local hud = dialogue.hud()
    if not hud then return end
    local title, sub = ue.prop(hud, "QuestUpdatedText"), ue.prop(hud, "QuestUpdatedSubtext")
    local box, taskbox, tree = ue.prop(hud, "BranchesBox"), ue.prop(hud, "TaskBox"), ue.prop(hud, "WidgetTree")
    if not (ue.valid(title) and ue.valid(sub) and ue.valid(box) and ue.valid(taskbox) and ue.valid(tree)) then
        log.err_throttled("quests.tracker", "quests: client: HUD tracker parts missing, tracker not shown")
        return
    end
    if not ue.valid(cl.tb_class) then cl.tb_class = ue.find_object(TEXTBLOCK) end
    if not cl.tb_class then return end
    pcall(function() title:SetText(FText(q.name)) end)
    pcall(function() sub:SetText(FText(subtitle)) end)
    pcall(function() box:ClearChildren() end)
    for _, t in ipairs(q.tasks) do
        local ok, err = pcall(function()
            local tb = StaticConstructObject(cl.tb_class, tree)
            tb:SetText(FText(tracker_line(t)))
            local f = tb.Font
            f.Size = 16
            tb:SetFont(f)
            box:AddChildToVerticalBox(tb)
        end)
        if not ok then
            log.err_throttled("quests.tracker.line", "quests: client: tracker line: %s", tostring(err))
            break
        end
    end
    pcall(function() taskbox:SetVisibility(3) end)   -- HitTestInvisible, as Show Quest Update
    local anim = ue.prop(hud, "FadeInTasks")
    if ue.valid(anim) then pcall(function() hud:PlayAnimation(anim, 0, 1, 0, 1, false) end) end
end

local function parse_qs(fields)
    local list = {}
    for _, field in ipairs(fields) do
        if field ~= "" then
            local parts = split(field, "~")
            local q = { name = parts[1], tasks = {} }
            for i = 2, #parts do
                local p = split(parts[i], "^")
                local flags = p[4] or ""
                q.tasks[#q.tasks + 1] = {
                    desc = p[1] or "", cur = tonumber(p[2]) or 0, req = tonumber(p[3]) or 1,
                    done = flags:find("d", 1, true) ~= nil, optional = flags:find("o", 1, true) ~= nil,
                }
            end
            list[#list + 1] = q
        end
    end
    return list
end

local function apply_snapshot(list)
    local old = cl.quests
    cl.quests = list
    if old == nil then
        if #list > 0 then
            notify(string.format("Задания группы: %d", #list), string.format("%d group quest(s) on joining", #list))
            tracker(list[1], "ЗАДАНИЯ ГРУППЫ")
        end
        return
    end
    local by_name = {}
    for _, q in ipairs(old) do by_name[q.name] = q end
    local seen = {}
    for _, q in ipairs(list) do
        seen[q.name] = true
        local o = by_name[q.name]
        if not o then
            notify("Новое задание: " .. q.name, "new quest '" .. q.name .. "'")
            tracker(q, "НОВОЕ ЗАДАНИЕ")
        else
            local changed = #o.tasks ~= #q.tasks
            local old_tasks = {}
            for _, t in ipairs(o.tasks) do old_tasks[t.desc] = t end
            for _, t in ipairs(q.tasks) do
                local ot = old_tasks[t.desc]
                if not ot then
                    changed = true
                elseif t.done and not ot.done then
                    changed = true
                    notify("Выполнено: " .. t.desc, "task done '" .. t.desc .. "'")
                elseif t.cur ~= ot.cur then
                    changed = true
                    notify(string.format("%s: %d/%d", t.desc, t.cur, t.req),
                        string.format("task progress '%s' %d/%d", t.desc, t.cur, t.req))
                end
            end
            if changed then tracker(q, "ЗАДАНИЕ ОБНОВЛЕНО") end
        end
    end
    for _, o in ipairs(old) do
        if not seen[o.name] then
            local t = cl.xp_recent[o.name]
            if not (t and os.clock() - t < 10) then
                notify("Задание завершено: " .. o.name, "quest '" .. o.name .. "' left the log")
            end
        end
    end
end

-- The other players' laptop bounties (QG on a client; the host's own view of
-- the clients' bounties): notices and the HUD tracker, as apply_snapshot.
local function apply_shared(list)
    local old = SH.view or {}
    SH.view = list
    local by_name = {}
    for _, q in ipairs(old) do by_name[q.name] = q end
    local seen = {}
    for _, q in ipairs(list) do
        seen[q.name] = true
        local o = by_name[q.name]
        if not o then
            notify("Общее задание: " .. q.name, "shared laptop bounty '" .. q.name .. "' (another player's intel)")
            tracker(q, "ОБЩЕЕ ЗАДАНИЕ")
        else
            local changed = #o.tasks ~= #q.tasks
            local old_tasks = {}
            for _, t in ipairs(o.tasks) do old_tasks[t.desc] = t end
            for _, t in ipairs(q.tasks) do
                local ot = old_tasks[t.desc]
                if not ot then
                    changed = true
                elseif t.done and not ot.done then
                    changed = true
                    notify("Выполнено: " .. t.desc, "shared bounty task done '" .. t.desc .. "'")
                elseif t.cur ~= ot.cur then
                    changed = true
                    notify(string.format("%s: %d/%d", t.desc, t.cur, t.req),
                        string.format("shared bounty task progress '%s' %d/%d", t.desc, t.cur, t.req))
                end
            end
            if changed then tracker(q, "ОБЩЕЕ ЗАДАНИЕ") end
        end
    end
    for _, o in ipairs(old) do
        if not seen[o.name] then
            local t = cl.xp_recent[o.name]
            if not (t and os.clock() - t < 10) then
                notify("Общее задание завершено: " .. o.name, "shared laptop bounty '" .. o.name .. "' left its owner's log")
            end
        end
    end
end

-- F7 panel lines (sdc_session.status lines).
function M.status_lines(out)
    if role() == "host" and own() then
        out[#out + 1] = string.format("Задания у каждого свои: наград с ноутбуков %d, зон %d, стартовых %d, забыто %d, сохранено %d / загружено %d",
            M.stats.bounties, M.stats.areas, M.stats.starts, M.stats.forgets, M.stats.saves, M.stats.loads)
    end
    if SH.view and #SH.view > 0 then
        out[#out + 1] = string.format("Общие задания с ноутбуков других игроков: %d", #SH.view)
        for _, q in ipairs(SH.view) do
            out[#out + 1] = "  " .. q.name
            for _, t in ipairs(q.tasks) do out[#out + 1] = "    " .. tracker_line(t) end
        end
    end
    if role() ~= "client" or not cl.quests then return end
    out[#out + 1] = string.format("Задания группы: %d", #cl.quests)
    for _, q in ipairs(cl.quests) do
        out[#out + 1] = "  " .. q.name
        for _, t in ipairs(q.tasks) do out[#out + 1] = "    " .. tracker_line(t) end
    end
end

-- ---------------------------------------------------------------------------
-- Client: XP, markers, notices
-- ---------------------------------------------------------------------------

local function apply_xp(amount, qname)
    local pc = ue.local_pc()
    local comp = pc and ue.prop(pc, "LevellingComponent")
    if amount <= 0 or not ue.valid(comp) then return end
    local key = ue.name(comp)
    if not cl.level_timer[key] then
        cl.level_timer[key] = true
        ue.call(comp, "Event_LevelBarTimer")   -- the XP bar timer, as sdc_ai_kills
    end
    local out = {}
    local ok, err = pcall(function() comp:AddXP(amount, false, out) end)
    if not ok then
        log.err_throttled("quests.xp", "quests: client: AddXP: %s", tostring(err))
        return
    end
    cl.xp_recent[qname] = os.clock()
    local given = math.floor(tonumber(out.XPOutput) or amount)
    notify(string.format("Задание выполнено: %s (+%d опыта)", qname, given),
        string.format("quest '%s' done, +%d XP", qname, given))
end
M._apply_xp = apply_xp   -- the host's XP for a client's shared bounty (on_reward_xp, above)

-- QX|<xp>|<quest name>. A client's own quest may run its reward event here
-- too (the component replays the host's updates); the XP then is there
-- already: QX waits 2.5 s and gives it only if no reward event ran here.
local function on_xp(f)
    if role() ~= "client" or not cfg.get("quest_xp") then return end
    local amount = tonumber(f[1]) or 0
    local qname = f[2] or ""
    local got = os.clock()
    ue.delay("quests-xp", 2500, function()
        if role() ~= "client" then return end
        local lx = cl.local_xp
        if lx and math.abs(lx.at - got) < 8 then
            log.info("quests: client: quest '%s' +%.0f XP from the host: the reward event ran here already (+%.0f), not added again",
                qname, amount, lx.amount or 0)
            cl.local_xp = nil
            return
        end
        apply_xp(amount, qname)
    end)
end

local function marker_ok(a)
    return ue.valid(a) and ue.class_name(a) == MARKER_SHORT
end

local function destroy_marker(tag)
    local m = cl.markers[tag]
    if m and marker_ok(m.actor) then destroy_marker_actor(m.actor) end
    if m then m.actor = nil end
end

-- A live marker with this tag that this machine's own quest event placed
-- (not one destroyed here a moment ago: it stays valid until GC).
local function native_marker(tag, ours)
    for _, a in ipairs(ue.find_all(MARKER_SHORT)) do
        if marker_ok(a) and (not ours or ue.name(a) ~= ue.name(ours)) and not marker_gone(a) and first_tag(a) == tag then
            return a
        end
    end
    return nil
end

-- (m.retry: the marker class or the world was not there yet; client_tick
-- tries again)
local function spawn_marker(tag)
    local m = cl.markers[tag]
    if not m then return end
    m.retry = nil
    local r = m.rec
    if native_marker(tag, m.actor) then
        log.info("quests: client: quest marker '%s' is placed here by this player's own quest already", tag)
        return
    end
    local cls = load_obj(MARKER)
    local gs, wc = ue.gameplay_statics(), ue.local_pc()
    if not (cls and gs and wc) then
        m.retry = true
        log.err_throttled("quests.marker", "quests: client: BP_QuestMarker (in memory: %s) / GameplayStatics / controller missing; tried again later",
            tostring(cls ~= nil))
        return
    end
    local tf = transform(r.loc)
    local ok, a = pcall(function() return gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, 1, nil, 0) end)
    if not ok or not ue.valid(a) then
        log.err_throttled("quests.marker.spawn", "quests: client: marker spawn failed: %s", tostring(a))
        return
    end
    -- the path came over the network: a texture only
    local tex = r.tex ~= "" and load_obj(r.tex) or nil
    if tex and not ue.class_name(tex):find("Texture", 1, true) then tex = nil end
    if tex then ue.set_prop(a, "Marker Texture", tex) end
    ue.set_prop(a, "Color", r.color)
    ue.set_prop(a, "Text", r.text)
    ue.set_prop(a, "Underground?", r.ug)
    local okf, done = pcall(function() return gs:FinishSpawningActor(a, tf, 0) end)
    m.actor = (okf and marker_ok(done)) and done or (marker_ok(a) and a or nil)
    log.info("quests: client: quest marker '%s' placed (texture %s, finish ok=%s)", tag, tostring(tex ~= nil), tostring(okf))
end

local function on_marker(f)
    ue.game_thread("quests-qm-recv", function()
        if role() ~= "client" or not cfg.get("quest_markers") then return end
        local op, tag = f[1], f[2]
        if (op ~= "a" and op ~= "d") or not tag or tag == "" then return end
        if op == "d" then
            destroy_marker(tag)
            cl.markers[tag] = nil
            log.info("quests: client: quest marker '%s' removed", tag)
            return
        end
        local x, y, z = tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
        if not (x and y and z) then return end
        destroy_marker(tag)
        cl.markers[tag] = { rec = {
            loc = { X = x, Y = y, Z = z }, tex = f[6] or "", text = f[7] or "",
            color = { R = tonumber(f[8]) or 1, G = tonumber(f[9]) or 1, B = tonumber(f[10]) or 1, A = tonumber(f[11]) or 1 },
            ug = f[12] == "1",
        } }
        spawn_marker(tag)
    end)
end

-- QN|<code>: what the game shows the player at the host's (player 0's) HUD.
local QN_TEXT = {
    pinned = { "Задание отмечено на карте", "bounty begun on this player's own log (the game's 'Quest pinned to your map')" },
    bounty_all = { "Все задания с ноутбуков уже взяты. Приходите позже — ноутбук возвращён.",
                   "every laptop bounty is on this player's log: the laptop came back (the game's 'All Laptop Quests Completed')" },
}

local function on_notice(f)
    if role() ~= "client" then return end
    local t = QN_TEXT[f[1] or ""]
    if not t then return end
    ue.game_thread("quests-qn", function() notify(t[1], t[2]) end)
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- Blueprint functions hooked here and nowhere else in the mod (each is
-- registered once: a second RegisterHook on the same function would add a
-- second callback; they stack). Post-hooks. The journal's class is not
-- loaded for it (it comes with the game's UI).
local BP_HOOKS = {
    { cls = SPAWN_MARKER, fn = SPAWN_MARKER .. ":ExecuteEvent", cb = function(ev_p, t_p, c_p) on_spawn_marker(ev_p, t_p, c_p) end },
    { cls = REMOVE_MARKER, fn = REMOVE_MARKER .. ":ExecuteEvent", cb = function(ev_p, t_p, c_p) on_remove_marker(ev_p, t_p, c_p) end },
    { cls = REWARD_XP, fn = REWARD_XP .. ":ExecuteEvent", cb = function(ev_p, t_p, c_p) on_reward_xp(ev_p, t_p, c_p) end },
    { cls = CRATE, fn = CRATE .. ":OpenContainer", cb = function(c_p) on_open_container(c_p) end },
    { fn = JOURNAL .. ":Show Quest", cb = function(c_p, q_p) on_journal_show(c_p, q_p) end },
    { fn = JOURNAL .. ":ForgetQuest", cb = function() on_journal_forget() end },
}
local bp_done = {}
local bp_next_try = 0
-- Log only, hooked with config debug_probes only: where a quest begins / is
-- forgotten, and the host's quest updates arriving on this client's
-- component (its PendingUpdateList rep notify; EUpdateType: 1 CompleteTask,
-- 2 BeginQuest, 3 ForgetQuest, 4 RestartQuest, 5 QuestNewState,
-- 6 TaskProgressMade).
local UPDATE_NAME = { [0] = "none", "data task", "quest begun", "quest forgotten", "quest restarted", "quest new state", "task progress" }
local seen_update = {}   -- [update key] = os.clock(); entries older than 30 s go

local function comp_owner_name(comp)
    local o = ue.valid(comp) and ue.try(function() return comp:GetOwner() end)
    return ue.short(o), o
end

local function on_begin_quest(comp_p, cls_p)
    local r = role()
    if (r ~= "host" and r ~= "client") or not log.probes_enabled then return end
    local comp = pget(comp_p)
    local name, owner = comp_owner_name(comp)
    local whose = (r == "host" and remote_owner(owner)) and "a client's" or "this machine's own"
    log.info("quests: %s: BeginQuest %s on %s component (%s)", r, ue.short(pget(cls_p)), whose, name)
end

local function on_forget_quest(comp_p, cls_p)
    local r = role()
    if (r ~= "host" and r ~= "client") or not log.probes_enabled then return end
    log.info("quests: %s: ForgetQuest %s on the component of %s", r, ue.short(pget(cls_p)), (comp_owner_name(pget(comp_p))))
end

local function on_updates(comp_p)
    if role() ~= "client" or not log.probes_enabled then return end
    local comp = pget(comp_p)
    if not ue.valid(comp) then return end
    local now = os.clock()
    for k, t in pairs(seen_update) do
        if now - t > 30 then seen_update[k] = nil end
    end
    local n, new = 0, 0
    each(ue.prop(comp, "PendingUpdateList"), function(u)
        n = n + 1
        local t = tonumber(ue.try(function() return u.UpdateType end)) or -1
        local q = ue.try(function() return u.QuestClass end)
        local payload = ue.str(ue.try(function() return u.Payload end))
        local key = tostring(t) .. "|" .. ue.short(q) .. "|" .. payload .. "|" .. n
        if not seen_update[key] then
            seen_update[key] = now
            new = new + 1
            log.info("quests: client: from the host, on this player's own quest log: %s %s%s", UPDATE_NAME[t] or tostring(t),
                ue.short(q), payload ~= "" and (" (" .. payload .. ")") or "")
        end
    end)
    if new == 0 then log.debug("quests: client: quest update list replicated again (%d entries, nothing new)", n) end
end

-- (all log only: registered with config debug_probes only)
local NATIVES = {
    { "/Script/Narrative.NarrativeComponent:BeginQuest", "BeginQuest", function() return safe("begin-quest", on_begin_quest) end },
    { "/Script/Narrative.NarrativeComponent:ForgetQuest", "ForgetQuest", function() return safe("forget-quest", on_forget_quest) end },
    { "/Script/Narrative.NarrativeComponent:OnRep_PendingUpdateList", "OnRep_PendingUpdateList", function() return safe("updates", on_updates) end },
}
local native_done = {}

-- Native hooks (pre only); called at load and from the ticks until they are in.
function M.install()
    if not log.probes_enabled then return end
    for i, h in ipairs(NATIVES) do
        if not native_done[i] and ue.find_object(h[1]) then
            local ok, err = pcall(RegisterHook, h[1], h[3](), nil)
            native_done[i] = ok
            log.info("quests: %s hook %s%s", h[2], ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
        end
    end
end

local function ensure_bp_hooks(now)
    if now < bp_next_try or ue.in_main_menu() then return end
    bp_next_try = now + 10
    for i, h in ipairs(BP_HOOKS) do
        if not bp_done[i] then
            if not ue.find_object(h.fn) and h.cls then ue.load_asset(h.cls, "quests") end
            if ue.find_object(h.fn) then
                local name = h.fn:match("([%w_]+:[%w_ ]+)$") or h.fn
                local ok, err = pcall(RegisterHook, h.fn, safe(name, h.cb))
                bp_done[i] = ok
                log.info("quests: hook %s %s%s", name, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------

local host = { sent = {}, known = {}, resend_at = 0 }

-- The shared bounties' markers for a joiner: those placed this session, and
-- by their tag the ones a bounty from the save put in the host's world.
local function shared_markers_to(pc)
    local sent, n = {}, 0
    for tag, fields in pairs(SH.markers) do
        net.send_to(pc, "QM", table.unpack(fields, 1, fields.n))
        sent[tag], n = true, n + 1
    end
    for _, a in ipairs(ue.find_all(MARKER_SHORT)) do
        if ue.valid(a) and ue.is_runtime_spawned(a) then
            local tag, loc = first_tag(a), not marker_gone(a) and ue.location(a)
            if tag and loc and not sent[tag] and is_bounty_class(tag) then
                net.send_to(pc, "QM", marker_fields(tag, loc, ue.prop(a, "Marker Texture"), ue.str(ue.prop(a, "Text")),
                    ue.prop(a, "Color"), ue.prop(a, "Underground?") == true))
                sent[tag], n = true, n + 1
            end
        end
    end
    return n
end

-- Host, every second with clients (quest_own + quest_bounty_shared): every
-- player's laptop bounties go to the others (QG; the host shows the clients'
-- itself), a bounty's go-to task is done by any other player near its goal,
-- and a joiner gets the shared markers.
local function shared_tick(pcs)
    if not shared_on() then return end
    local me = ue.local_pc()
    local owners = {}
    local function add(pc, comp)
        if not (pc and comp) then return end
        local list = {}
        for _, q in ipairs(snapshot_once(comp)) do
            if is_bounty_class(q.cls) then list[#list + 1] = q end
        end
        owners[#owners + 1] = { pc = pc, key = ue.name(pc), list = list }
    end
    add(me, host_comp())
    for _, pc in ipairs(pcs) do add(pc, comp_of(pc)) end
    if cfg.get("quest_goto") then
        for _, o in ipairs(owners) do
            if #o.list > 0 then
                local others = {}
                for _, x in ipairs(owners) do
                    if x.key ~= o.key then others[#others + 1] = x.pc end
                end
                goto_check(o.list, others)
            end
        end
    end
    local function view_for(key)
        local v = {}
        for _, o in ipairs(owners) do
            if o.key ~= key then
                for _, q in ipairs(o.list) do v[#v + 1] = q end
            end
        end
        return v
    end
    local present = {}
    for _, pc in ipairs(pcs) do
        local key = ue.name(pc)
        present[key] = true
        local fields = encode(view_for(key))
        local str = table.concat(fields, "|")
        if SH.sent[key] ~= str then
            local first = SH.sent[key] == nil
            SH.sent[key] = str
            net.send_to(pc, "QG", table.unpack(fields))
            if #fields > 0 or not first then
                log.info("quests: host: the other players' laptop bounties to %s: %d (QG)", ue.short(pc), #fields)
            end
        end
        if not SH.known[key] and ue.pawn_of(pc) then
            SH.known[key] = true
            local n = shared_markers_to(pc)
            if n > 0 then log.info("quests: host: %d shared bounty marker(s) sent to %s (joined)", n, ue.short(pc)) end
        end
    end
    for key in pairs(SH.sent) do
        if not present[key] then SH.sent[key], SH.known[key] = nil, nil end
    end
    -- the host's own view: the clients' bounties (plain data, no task objects)
    if me then
        local fields = encode(view_for(ue.name(me)))
        local str = table.concat(fields, "|")
        if SH.host_str ~= str then
            SH.host_str = str
            apply_shared(parse_qs(fields))
        end
    end
end

-- Host, every second (sdc_session host_tick).
function M.host_tick(now)
    M.install()
    ensure_bp_hooks(now)
    local pcs = remote_pcs()
    if #pcs == 0 then return end
    if own() then
        tick_snaps = {}
        local ok, err = pcall(host_own_tick)
        if not ok then log.err_throttled("quests.own", "quests: host: own quests tick: %s", tostring(err)) end
        local oks, errs = pcall(shared_tick, pcs)
        if not oks then log.err_throttled("quests.shared", "quests: host: shared bounties tick: %s", tostring(errs)) end
        tick_snaps = nil
        return
    end
    -- group design: joiners get every quest marker the host has
    local present = {}
    for _, pc in ipairs(pcs) do
        local key = ue.name(pc)
        present[key] = true
        -- once the joiner has a character (its world is loaded)
        if not host.known[key] and ue.pawn_of(pc) then
            host.known[key] = true
            if cfg.get("quest_markers") then send_all_markers(pc) end
        end
    end
    for key in pairs(host.known) do
        if not present[key] then host.known[key], host.sent[key] = nil, nil end
    end
    if not (cfg.get("quest_sync") or cfg.get("quest_goto")) then return end
    local comp = host_comp()
    if not comp then return end
    local list = snapshot(comp)
    if cfg.get("quest_goto") then goto_check(list, pcs) end
    if not cfg.get("quest_sync") then return end
    if now >= host.resend_at then
        host.resend_at = now + QS_RESEND_S
        host.sent = {}
    end
    local fields = encode(list)
    local str = table.concat(fields, "|")
    for _, pc in ipairs(pcs) do
        local key = ue.name(pc)
        if host.sent[key] ~= str then
            host.sent[key] = str
            net.send_to(pc, "QS", table.unpack(fields))
            log.debug("quests: host: QS to %s: %d quest(s)", ue.short(pc), #fields)
        end
    end
end

-- Client, every second (sdc_session client_tick).
function M.client_tick(now, pc, pawn)
    M.install()
    ensure_bp_hooks(now)
    if not pawn then return end
    -- a new character has a new minimap: put our markers on it again
    local pk = ue.name(pawn)
    if pk ~= cl.pawn_key then
        local had = cl.pawn_key ~= nil
        cl.pawn_key = pk
        if had and cfg.get("quest_markers") then
            local n = 0
            for tag in pairs(cl.markers) do
                destroy_marker(tag)
                spawn_marker(tag)
                n = n + 1
            end
            if n > 0 then log.info("quests: client: new character, %d quest marker(s) placed again", n) end
        end
    end
    -- markers not placed yet (class not in memory, no world): again every 5 s
    if cfg.get("quest_markers") and now - (cl.marker_retry_at or -100) >= 5 then
        cl.marker_retry_at = now
        for tag, m in pairs(cl.markers) do
            if m.retry and not marker_ok(m.actor) then spawn_marker(tag) end
        end
    end
end

function M.register_handlers()
    net.on("QT", function(f, pc) on_task_request(f, pc) end)
    net.on("QC", function(f, pc) on_crate_request(f, pc) end)
    net.on("QB", function(f, pc) on_bounty_request(f, pc) end)
    net.on("QQ", function(f, pc) on_quest_request(f, pc) end)
    net.on("QS", function(f)
        if role() ~= "client" or not cfg.get("quest_sync") then return end
        local list = parse_qs(f)
        ue.game_thread("quests-qs", function()
            if role() == "client" then apply_snapshot(list) end
        end)
    end)
    net.on("QG", function(f)
        if role() ~= "client" then return end
        local list = parse_qs(f)
        ue.game_thread("quests-qg", function()
            if role() == "client" then apply_shared(list) end
        end)
    end)
    net.on("QM", function(f) on_marker(f) end)
    net.on("QX", function(f) on_xp(f) end)
    net.on("QN", function(f) on_notice(f) end)
end

-- Role change / level change: every object reference is dropped untouched
-- (marker actors die with their world).
function M.reset(why)
    cl.quests, cl.markers, cl.pawn_key, cl.xp_recent, cl.level_timer, cl.tb_class = nil, {}, nil, {}, {}, nil
    cl.local_xp, cl.qt_at, cl.journal_quest, cl.marker_retry_at = nil, {}, nil, nil
    gone_markers, seen_update = {}, {}
    host.sent, host.known, host.resend_at = {}, {}, 0
    P.bounty_at, P.bounty_clear, P.areas, P.areas_at, P.starts, P.bound = {}, {}, {}, -100, {}, {}
    SH.sent, SH.known, SH.markers, SH.view, SH.host_str = {}, {}, {}, nil, nil
    refire.key, refire.till = nil, -1   -- (refire.host: time-stamped, the load right after a reset reads it)
    log.info("quests: reset (%s)", tostring(why))
end

function M.init(state)
    S = state
end

return M
