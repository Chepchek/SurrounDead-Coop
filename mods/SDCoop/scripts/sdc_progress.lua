-- SDCoop: a player's progression in co-op (level / XP, passive skills, skill
-- points, journal stats). A client plays the character the host saved for it
-- in this world (sdc_persist), or a NEW character's progression when there
-- is none.
--
-- Where it lives (decompiled, work\re):
--   * BP_PlayerController holds it in its own components: LevellingComponent
--     (CurrentLevel, CurrentXP, CurrentMaxXP, ... all CPF_SaveGame, none
--     replicated; CDO: level 1, max XP 500), PassiveSkillsComponent (the
--     skills' XP / levels), TechTreeComponent (SkillPoints, CurrentPoints;
--     the unlocked technologies in its C++ TechTreeManager) and the journal
--     stats (ZombieKills ... DaysSurvived) as plain controller variables.
--     Nothing of it replicates: host and client each have their own copy of
--     a client's controller, and the client's HUD shows the client's copy.
--     M.FIELDS lists exactly the SaveGame properties of those components
--     (from the classes' property flags) plus the journal: what EMS saves.
--   * It is filled only by EasyMultiSave: ComponentsToSave (Levelling,
--     PassiveSkills, TechTree) + ActorLoaded (@4871: the journal from
--     Save_Player), during LoadGameFromSlot (@9606 -> CheckSaveFiles ->
--     AsyncLoadActors(3) -> OnCompleted_F36E... @1414), from EMS's CURRENT
--     slot. The client runs that itself: its own copy of the LongdownValley
--     level script calls SD_GameInstance.Survival_SpawnPlayer, whose load
--     branch (@1001-1057) runs CastToController(GI).LoadGameFromSlot() on the
--     client's own controller.
--   * The host's copy of a client's controller is a new object at login (CDO
--     values, level 1); EMS on the host loads only player 0. sdc_players
--     marks it skip-save, so it never writes the host's Save_Player either.
-- So a client "already level N" comes from the client's own EMS load: while
-- connected, the client's current slot is sdc_session's throwaway slot
-- SDCoop_ClientTemp. It is deleted only on a clean leave; after a crash or a
-- closed game it still holds what that client saved during the last session
-- (the sleep widget and quick-save save on the client), and the next join
-- loads it. Here, all through the game's own functions:
--   * the throwaway slot is emptied when the mod starts (crash leftovers) and
--     when a connection begins (sdc_session should do it before pointing EMS
--     at it; this is the fallback);
--   * the host answers who this player is (sdc_persist: PSSET with the saved
--     record, or PSFRESH). Once per connection, when the own character and
--     its HUD exist (and again right after the game's own load finishes on
--     this client: the BP_PlayerController OnCompleted_F36E... hook; Blueprint
--     hook = after the handler), the client's copy first goes back to a new
--     character the way the game's new-game path does (BFL_SaveGames."Reset
--     Player Stats" @69-413, GameMode.ResetStats @800-1320):
--     LevellingComponent.Reset (level 1, XP 0, UpdateLevelUI / UpdateXPUI),
--     PassiveSkillsComponent.ResetPassiveSkills_NewSave + Event_ComponentLoad
--     (its UI, 4 s later), TechTreeComponent.ResetTreeComplete (points 0,
--     UpdatePointsUI, a fresh AssignTechTree; only with the HUD up, it reads
--     the journal widget), the journal stats, then BindPlayerRespawn (the
--     level / XP widgets). With a saved record the saved values are then set
--     (the SaveGame properties, as EMS would) and the same UI functions run
--     again; the saved skills are unlocked (sdc_skilltree.unlock) and the
--     respawn point goes onto this client's controller (the death screen's
--     "spawn point" button reads it here). No answer from the host (older
--     host): a new character, as before.
--   * Host: the host's copy of each client's controller is checked once; if
--     it is not a new character's it is reset the same way (logged: it would
--     mean something loaded it) - unless sdc_persist restored it.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")

local M = { stats = { client_resets = 0, host_resets = 0, slot_cleared = 0, restored = 0, values_set = 0 } }

local S = nil
local TEMP_SLOT = "SDCoop_ClientTemp"
local LOAD_DONE_FN = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:OnCompleted_F36E30354316ADD99BBAD29E4E315233"
local RESET_AFTER_S = 6
local VERDICT_MAX_S = 45   -- client: longest wait for the host's answer from the connection's start

-- GameMode.ResetStats @800-1320 (the controller's journal)
local JOURNAL = {
    { "ZombieKills", 0 }, { "BossZombieKills", 0 }, { "AnimalKills", 0 }, { "HumanKills", 0 },
    { "DaysSurvived", 1 }, { "DistanceTravelled", 0 }, { "InfestationsDestroyed", 0 },
}

-- What is saved of a player's progression: { tag, controller component
-- (nil = the controller), the SaveGame properties }. The lists are the
-- CPF_SaveGame properties of the decompiled components (work\re\json).
M.FIELDS = {
    { "L", "LevellingComponent", { "CurrentLevel", "CurrentXP", "CurrentMaxXP", "CurrentPercentage", "BufferXP",
        "RemainingXP" } },
    { "P", "PassiveSkillsComponent", {
        "CurrentFitnessXP", "MaxFitnessXP", "CurrentFitnessLevel", "CurrentStrengthXP", "MaxStrengthXP",
        "CurrentStrengthLevel", "CurrentToughessXP", "MaxToughnessXP", "CurrentToughessLevel", "CurrentSneakingXP",
        "MaxSneakingXP", "CurrentSneakingLevel", "CurrentFirstAidXP", "MaxFirstAidXP", "CurrentFirstAidLevel",
        "CurrentMarksmanshipXP", "MaxMarksmanshipXP", "CurrentMarksmanshipLevel", "CurrentReloadingXP",
        "MaxReloadingXP", "CurrentReloadingLevel", "FitnessPercentage", "StrengthPercentage", "ToughnessPercentage",
        "SneakingPercentage", "FirstAidPercentage", "MarksmanshipPercentage", "ReloadingPercentage",
        "FitnessMultiplier", "StrengthMultiplier", "ToughnessMultiplier", "SneakingMultiplier", "FirstAidMultiplier",
        "ReloadingMultiplier", "MarksmanshipMultiplier", "StrengthSpeedMultiplier", "FitnessStaminaMultiplier",
        "CurrentThiefXP", "MaxThiefXP", "CurrentThiefLevel", "ThiefPercentage", "ThiefMultiplier",
        "CurrentFishingXP", "MaxFishingXP", "CurrentFishingLevel", "FishingPercentage", "FishingMultiplier",
        "FitnessMultiplierUsed?", "StrengthMultiplierUsed?", "ToughnessMultiplierUsed?", "SneakingMultiplierUsed?",
        "FirstAidMultiplierUsed?", "MarksmanshipMultiplierUsed?", "ReloadingMultiplierUsed?", "ThiefMultiplierUsed?",
        "FishingMultiplierUsed?", "CurrentScavengingXP", "MaxScavengingXP", "CurrentScavengingLevel",
        "ScavengingPercentage", "ScavengingMultiplier", "ScavengingMultiplierUsed?" } },
    { "T", "TechTreeComponent", { "SkillPoints", "CurrentPoints" } },
    { "J", nil, { "ZombieKills", "BossZombieKills", "AnimalKills", "HumanKills", "DaysSurvived", "DistanceTravelled",
        "InfestationsDestroyed" } },
}
local INT_FIELDS = {
    CurrentLevel = true, SkillPoints = true, CurrentPoints = true, ZombieKills = true, BossZombieKills = true,
    AnimalKills = true, HumanKills = true, DaysSurvived = true, InfestationsDestroyed = true,
}
-- a change of these is reported to the host at once (sdc_persist); XP that
-- trickles in (sprinting) waits for the next regular report, and so does
-- DistanceTravelled (it changes all the time a player moves)
local MAJOR = { ["L.CurrentLevel"] = true, ["T.SkillPoints"] = true, ["T.CurrentPoints"] = true }
for _, j in ipairs(JOURNAL) do
    if j[1] ~= "DistanceTravelled" then MAJOR["J." .. j[1]] = true end
end

local st = {
    started = false, conn = nil, pawn_key = nil, pawn_since = 0, done = false,
    host_checked = {}, load_hook = false, sig_logged = false, verdict = nil, applied_gen = nil,
}

local function enabled()
    return cfg.get("fresh_client_progress") ~= false
end

local function persist_mod() return package.loaded["sdc_persist"] end

-- The slot on disk: Easy Multi Save keeps SaveGames\<slot>\*.sav, the game
-- itself writes <slot>_SkillTree.sav and <slot>_SDQuests.sav next to it (EMS
-- deletion does not know those). Removing the files is enough: a missing
-- file loads as a new character.
local SLOT_FILES = { "Slot.sav", "Player.sav", "PlayerInfo.sav", "Level.sav", "General.sav",
    "Difficulties.sav", "Thumb.jpg" }

function M.wipe_slot_files(slot)
    slot = slot or TEMP_SLOT
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return 0 end
    local dir = base .. "/SurrounDead/Saved/SaveGames/"
    local n = 0
    for _, f in ipairs(SLOT_FILES) do
        if os.remove(dir .. slot .. "/" .. f) then n = n + 1 end
    end
    -- the game 0.8 writes <slot>_SDQuests.sav (older builds _Quests.sav)
    for _, f in ipairs({ "_SkillTree.sav", "_SDQuests.sav", "_Quests.sav" }) do
        if os.remove(dir .. slot .. f) then n = n + 1 end
    end
    return n
end

local function clear_temp_slot(why)
    local ok, err = ue.ems_delete_slot(TEMP_SLOT)
    local okf, files = pcall(M.wipe_slot_files, TEMP_SLOT)
    M.stats.slot_cleared = M.stats.slot_cleared + 1
    log.info("progress: save slot %s emptied (%s, ok=%s%s, files removed=%s)", TEMP_SLOT, why, tostring(ok),
        ok and "" or (" " .. tostring(err)), okf and tostring(files) or ("error " .. tostring(files)))
    return ok or (okf and files > 0)
end

local function num(v)
    if type(v) == "number" then return string.format("%g", v) end
    return tostring(v)
end

local function describe(pc)
    local lev = ue.prop(pc, "LevellingComponent")
    local ps = ue.prop(pc, "PassiveSkillsComponent")
    local tech = ue.prop(pc, "TechTreeComponent")
    return string.format("level %s xp %s/%s, fitness %s toughness %s marksmanship %s, skill points %s/%s, zombie kills %s",
        num(ue.prop(lev, "CurrentLevel")), num(ue.prop(lev, "CurrentXP")), num(ue.prop(lev, "CurrentMaxXP")),
        num(ue.prop(ps, "CurrentFitnessLevel")), num(ue.prop(ps, "CurrentToughessLevel")),
        num(ue.prop(ps, "CurrentMarksmanshipLevel")), num(ue.prop(tech, "SkillPoints")),
        num(ue.prop(tech, "CurrentPoints")), num(ue.prop(pc, "ZombieKills")))
end

local function is_new_character(pc)
    local lev = ue.prop(pc, "LevellingComponent")
    local tech = ue.prop(pc, "TechTreeComponent")
    local level, xp = ue.prop(lev, "CurrentLevel"), ue.prop(lev, "CurrentXP")
    return (level == nil or level == 1) and (xp == nil or xp == 0)
        and (ue.prop(tech, "SkillPoints") or 0) == 0 and (ue.prop(pc, "ZombieKills") or 0) == 0
end

-- ---------------------------------------------------------------------------
-- Values (sdc_persist: the client reports them, the host saves them)
-- ---------------------------------------------------------------------------

-- { L = { CurrentLevel = 3, ... }, P = {...}, T = {...}, J = {...} } of one
-- controller copy.
function M.read_values(pc)
    local out = {}
    for _, g in ipairs(M.FIELDS) do
        local obj = g[2] and ue.prop(pc, g[2]) or pc
        if ue.valid(obj) then
            local t = {}
            for _, name in ipairs(g[3]) do
                local v = ue.prop(obj, name)
                if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
                    t[name] = v
                elseif type(v) == "boolean" then
                    t[name] = v
                end
            end
            out[g[1]] = t
        end
    end
    return out
end

local function fmt_value(v)
    if type(v) == "boolean" then return v and "1" or "0" end
    if math.type(v) == "integer" then return tostring(v) end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.9g", v)
end

-- "L.CurrentLevel=3;P.CurrentFitnessXP=12.5;..." (stable order)
function M.encode_values(vals)
    local parts = {}
    if type(vals) ~= "table" then return "" end
    for _, g in ipairs(M.FIELDS) do
        local t = vals[g[1]]
        if type(t) == "table" then
            for _, name in ipairs(g[3]) do
                local v = t[name]
                if type(v) == "number" or type(v) == "boolean" then
                    parts[#parts + 1] = g[1] .. "." .. name .. "=" .. fmt_value(v)
                end
            end
        end
    end
    return table.concat(parts, ";")
end

local KNOWN = {}
for _, g in ipairs(M.FIELDS) do
    for _, name in ipairs(g[3]) do KNOWN[g[1] .. "." .. name] = { g[1], name } end
end

function M.decode_values(s)
    local out = {}
    for k, v in tostring(s or ""):gmatch("([^;=]+)=([^;]*)") do
        local spec = KNOWN[k]
        local n = tonumber(v)
        if spec and n and n == n then
            local tag, name = spec[1], spec[2]
            out[tag] = out[tag] or {}
            if name:sub(-1) == "?" then
                out[tag][name] = n ~= 0
            elseif INT_FIELDS[name] then
                out[tag][name] = math.floor(n + 0.5)
            else
                out[tag][name] = n
            end
        end
    end
    return out
end

-- The fields whose change is reported at once, from an encoded string.
function M.major_key(encoded)
    local parts = {}
    for k, v in tostring(encoded or ""):gmatch("([^;=]+)=([^;]*)") do
        if MAJOR[k] then parts[#parts + 1] = k .. "=" .. v end
    end
    return table.concat(parts, ";")
end

-- Sets saved values on one controller copy, the way EMS's load sets the
-- SaveGame properties; `ui` (this client's own copy, `pawn` its character)
-- runs the components' own UI refresh. Returns the number of values set.
function M.apply_values(pc, pawn, vals, who, ui)
    if not ue.valid(pc) or type(vals) ~= "table" then return 0 end
    local n, bad = 0, {}
    for _, g in ipairs(M.FIELDS) do
        local t = vals[g[1]]
        local obj = g[2] and ue.prop(pc, g[2]) or pc
        if type(t) == "table" and ue.valid(obj) then
            for _, name in ipairs(g[3]) do
                local v = t[name]
                if v ~= nil then
                    if name:sub(-1) == "?" then
                        v = (v == true or v == 1)
                    elseif INT_FIELDS[name] then
                        v = math.tointeger(math.floor((tonumber(v) or 0) + 0.5))
                    else
                        v = tonumber(v)
                    end
                    if name == "CurrentLevel" and v then v = math.max(1, math.min(v, 10000)) end
                    if v ~= nil and ue.set_prop(obj, name, v) then n = n + 1 else bad[#bad + 1] = name end
                end
            end
        end
    end
    M.stats.values_set = M.stats.values_set + n
    if ui then
        local ps = ue.prop(pc, "PassiveSkillsComponent")
        local tech = ue.prop(pc, "TechTreeComponent")
        if ue.valid(ps) then pcall(function() ps:Event_ComponentLoad() end) end
        -- the points widget: ComponentLoaded broadcasts UpdatePointsUI 4 s later
        if ue.valid(tech) then pcall(function() tech:ComponentLoaded() end) end
        if pawn then pcall(function() pc:BindPlayerRespawn() end) end
    end
    log.info("progress: %s: %d saved value(s) set%s; now %s", tostring(who), n,
        #bad > 0 and (" (NOT set: " .. table.concat(bad, ",") .. ")") or "", describe(pc))
    return n
end

-- The game's new-character values on one controller copy. `pawn` may be nil
-- (then the tech tree's UI part is skipped: ResetTreeComplete reads the
-- character's journal widget).
local function reset(pc, pawn, who, why)
    local before = describe(pc)
    local steps = {}
    local function step(name, fn)
        local ok, err = pcall(fn)
        steps[#steps + 1] = name .. (ok and "" or ("=ERR " .. tostring(err)))
    end
    local lev = ue.prop(pc, "LevellingComponent")
    local ps = ue.prop(pc, "PassiveSkillsComponent")
    local tech = ue.prop(pc, "TechTreeComponent")
    if ue.valid(lev) then step("Levelling.Reset", function() lev:Reset() end) end
    if ue.valid(ps) then
        step("PassiveSkills.ResetPassiveSkills_NewSave", function() ps:ResetPassiveSkills_NewSave() end)
        step("PassiveSkills.Event_ComponentLoad", function() ps:Event_ComponentLoad() end)
    end
    if ue.valid(tech) then
        local hud = pawn and ue.prop(pawn, "InGameUI")
        local journal = ue.prop(hud, "JournalUI")
        local skills = ue.prop(journal, "Journal_SkillsUI")
        if ue.valid(ue.prop(skills, "SkillTreeUI")) then
            step("TechTree.ResetTreeComplete", function() tech:ResetTreeComplete() end)
        else
            ue.set_prop(tech, "SkillPoints", 0)
            ue.set_prop(tech, "CurrentPoints", 0)
            steps[#steps + 1] = "TechTree points 0 (no journal widget)"
            -- the points widget: ComponentLoaded broadcasts UpdatePointsUI 4 s later
            if pawn then step("TechTree.ComponentLoaded", function() tech:ComponentLoaded() end) end
        end
        -- ResetTreeComplete re-assigns the tree only with the journal widget;
        -- whatever is still unlocked is locked one by one (sdc_skilltree)
        local okt, tree = pcall(require, "sdc_skilltree")
        if okt then
            local okr, locked = pcall(tree.relock, tech, who)
            steps[#steps + 1] = okr and ("skills locked " .. #locked) or ("skills lock=ERR " .. tostring(locked))
        end
    end
    for _, j in ipairs(JOURNAL) do ue.set_prop(pc, j[1], j[2]) end
    if pawn then step("BindPlayerRespawn", function() pc:BindPlayerRespawn() end) end
    log.info("progress: %s set to a new character (%s): was %s; now %s [%s]", who, why, before, describe(pc),
        table.concat(steps, ", "))
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- sdc_skilltree: may this client's tree be reported yet (after the reset /
-- restore, or 30 s into the connection whatever happened)?
function M.client_ready()
    if st.done then return true end
    if not enabled() and not st.verdict then return true end
    return st.conn_since ~= nil and os.time() - st.conn_since >= 30
end

-- The host's answer (sdc_persist): v = { kind = "restore" | "fresh", gen,
-- vals, tree, respawn, conn, saving }.
local apply_verdict   -- below

function M.set_verdict(v)
    st.verdict = v
    log.info("progress: the host says: %s", v.kind == "restore" and "this player's saved character" or "a new character")
    -- the character was already set up without the answer: once more now
    if S and S.role == "client" and st.done and st.conn == v.conn then apply_verdict("the host's late answer") end
end

apply_verdict = function(why)
    local v = st.verdict
    local pc = ue.local_pc()
    if not v or not pc then return false end
    local pawn = ue.pawn_of(pc)
    local who = "this client's controller"
    if v.kind == "restore" then
        reset(pc, pawn, who, why)
        M.apply_values(pc, pawn, v.vals or {}, who, true)
        local tech = ue.prop(pc, "TechTreeComponent")
        local okt, tree = pcall(require, "sdc_skilltree")
        if okt and ue.valid(tech) and type(v.tree) == "table" and #v.tree > 0 and tree.unlock then
            local oku, err = pcall(tree.unlock, tech, v.tree, "saved character")
            if not oku then log.err("progress: unlocking the saved skills: %s", tostring(err)) end
        end
        local rp = v.respawn
        local persist = persist_mod()
        if rp and rp.en and rp.t and rp.q and persist and persist.write_transform then
            local okw = persist.write_transform(pc, "RespawnLoc", rp.t, rp.q)
            ue.set_prop(pc, "RespawnPointEnabled", okw)
            log.info("progress: respawn point of the saved character on this controller: %s", okw and "set" or "NOT set")
        end
        if st.applied_gen ~= v.gen then
            M.stats.restored = M.stats.restored + 1
            local lvl = v.vals and v.vals.L and v.vals.L.CurrentLevel
            log.say("persist_restored_client", "ok", 7, tostring(lvl or "?"))
        end
    else
        if enabled() then
            reset(pc, pawn, who, why)
        else
            log.info("progress: no saved character, fresh_client_progress is off: this controller is left as it is")
        end
        if st.applied_gen ~= v.gen and v.saving ~= false then log.say("persist_fresh_client", "info", 7) end
    end
    st.applied_gen = v.gen
    local persist = persist_mod()
    if persist and persist.client_applied then pcall(persist.client_applied, v.gen, v.kind) end
    return true
end

local function client_tick(now)
    if S.client ~= st.conn then
        st.conn, st.done, st.pawn_key, st.pawn_since, st.conn_since = S.client, false, nil, 0, now
        st.applied_gen = nil
        if st.verdict and st.verdict.conn ~= S.client then st.verdict = nil end
        -- before the game's own load in the host's world reads this slot
        clear_temp_slot("new connection")
    end
    if st.done then return end
    local pc = ue.local_pc()
    local pawn = pc and ue.pawn_of(pc)
    if not pawn then return end
    local key = ue.name(pawn)
    if key ~= st.pawn_key then st.pawn_key, st.pawn_since = key, now end
    if now - st.pawn_since < RESET_AFTER_S or ue.prop(pawn, "PlayerDead?") == true then return end
    if not ue.valid(ue.prop(pawn, "InGameUI")) then return end   -- the HUD first (sdc_players.ensure_hud)
    if not st.verdict then
        local persist = persist_mod()
        local pending = persist and persist.client_verdict_pending and persist.client_verdict_pending(now)
        if pending and now - st.conn_since < VERDICT_MAX_S then return end   -- the host's answer first
        st.done = true
        M.stats.client_resets = M.stats.client_resets + 1
        if enabled() then
            reset(pc, pawn, "this client's controller", "joined; the host has no saved characters (older host?)")
        end
        return
    end
    st.done = true
    M.stats.client_resets = M.stats.client_resets + 1
    apply_verdict("joined")
end

-- After BP_PlayerController's EMS load handler (Blueprint hook: after it).
local function on_load_done(pc_p)
    if not S or S.role ~= "client" then return end
    local pc = pc_p and pc_p:get()
    if not ue.valid(pc) then return end
    local okl, is_local = pcall(function() return pc:IsLocalController() end)
    if not okl or is_local ~= true then return end
    log.info("progress: the game's own save load finished on this client (slot %s)", TEMP_SLOT)
    if st.verdict and st.verdict.conn == S.client then
        M.stats.client_resets = M.stats.client_resets + 1
        apply_verdict("after the game's own load")
    elseif enabled() then
        M.stats.client_resets = M.stats.client_resets + 1
        reset(pc, ue.pawn_of(pc), "this client's controller", "after the game's own load")
    end
end

local function install_load_hook()
    if st.load_hook or not ue.find_object(LOAD_DONE_FN) then return end
    -- Blueprint function: one callback, after the handler
    local ok, err = pcall(RegisterHook, LOAD_DONE_FN, function(pc_p)
        local okc, e = pcall(on_load_done, pc_p)
        if not okc then log.err_throttled("progress-load", "progress: load hook: %s", tostring(e)) end
    end)
    st.load_hook = ok
    log.info("progress: EMS load-finished hook (post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function host_tick()
    local persist = persist_mod()
    for key, r in pairs(S.remote or {}) do
        if not st.host_checked[key] and ue.valid(r.pc) then
            st.host_checked[key] = true
            if persist and persist.host_owns and persist.host_owns(key) then
                log.info("progress: host copy of %s's controller: the saved character (sdc_persist)", r.name)
            elseif is_new_character(r.pc) then
                log.info("progress: host copy of %s's controller is a new character (%s)", r.name, describe(r.pc))
            else
                M.stats.host_resets = M.stats.host_resets + 1
                log.warn("progress: host copy of %s's controller was NOT a new character", r.name)
                reset(r.pc, ue.pawn_of(r.pc), "host copy of " .. r.name .. "'s controller", "joined")
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Tick / install
-- ---------------------------------------------------------------------------

-- Diagnostic: the current save slot when the mod starts (EMS, read the way
-- the game's save menu reads it).
local function log_ems_signature()
    if st.sig_logged then return end
    st.sig_logged = true
    local cur, cerr = ue.ems_current_slot()
    log.info("progress: current save slot at startup: %s", cur and ("'" .. cur .. "'") or ("unknown (" .. tostring(cerr) .. ")"))
end

local function tick()
    if not S then return end
    local now = os.time()
    local role = S.role
    if not st.started and (role == "standalone" or role == "host") then
        st.started = true
        log_ems_signature()
        -- a crash / closed game while connected leaves the throwaway slot
        -- with that session's client data; it must not load next time
        clear_temp_slot("left over from an earlier session")
    end
    install_load_hook()
    if role == "client" then
        client_tick(now)
    elseif role == "host" then
        st.conn = nil
        if enabled() then host_tick() end
    else
        st.conn = nil
    end
end

local function reset_world()
    st.host_checked = {}
    st.pawn_key = nil
end

local installed = false
function M.install(state)
    if installed then return end
    installed = true
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    if session and session.world_reset_hooks then session.world_reset_hooks.progress = reset_world end
    -- the skill tree: client's own unlocks count on the host (sdc_skilltree)
    local okt, terr = pcall(function() require("sdc_skilltree").install(S) end)
    if not okt then log.err("progress: sdc_skilltree install: %s", tostring(terr)) end
    -- other players' characters saved with the host's world (sdc_persist)
    local okp, perr = pcall(function() require("sdc_persist").install(S) end)
    if not okp then log.err("progress: sdc_persist install: %s", tostring(perr)) end
    ue.delay("progress-boot", 5000, function() ue.every("progress", 1000, tick) end)
    log.info("progress: installed (fresh_client_progress=%s)", tostring(enabled()))
end

function M.status_line()
    local line = string.format("progress: client resets=%d restored=%d values set=%d host resets=%d slot cleared=%d load hook=%s",
        M.stats.client_resets, M.stats.restored, M.stats.values_set, M.stats.host_resets, M.stats.slot_cleared,
        tostring(st.load_hook))
    local tree = package.loaded["sdc_skilltree"]
    if type(tree) == "table" and tree.status_line then line = line .. " || " .. tree.status_line() end
    local persist = persist_mod()
    if type(persist) == "table" and persist.status_line then line = line .. " || " .. persist.status_line() end
    return line
end

return M
