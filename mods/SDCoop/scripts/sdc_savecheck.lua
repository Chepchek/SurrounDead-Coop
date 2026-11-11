-- SDCoop: the host's world save in co-op - checks and guards
-- (work\audit\host_save.md).
--
-- How the game saves (decompiled, work\re\pseudo):
--   Every save ends in BP_PlayerController.SaveGameToSlot of the saving
--   machine's own controller (CastToController(self) = player 0; the world
--   context is the host's own widget / GameMode / character, so sdc_ctx never
--   redirects it): autosave (GameMode.AutoSaveGame, a 600 s looping timer
--   started by EventSave / Event_AutoSave when Game.AutoSave is on; skipped
--   while paused, with permadeath, or when player 0 is dead), the pause
--   menu's Quick Save and Save (SaveMenu), sleeping (SleepingUI,
--   Game.SleepingSavesGame) and the quick-save key (BP_PlayerCharacter
--   IA_QuickSave). The game has no save on quit.
--   SaveGameToSlot @9611: "Saving Game..." -> thumbnail -> EMSAsyncSaveGame.
--   AsyncSaveActors(self, 3) (player + level actors, each saved actor's
--   ActorPreSave first) -> OnCompleted_9CDBA... @1891: BFL_SaveGames.
--   SaveObjects (SaveCustom: Save_General = General.sav, Save_Difficulties,
--   Save_Player = PlayerInfo.sav), SaveTechStateFromSlot("<slot>_SkillTree"),
--   NarrativeComponent.Save("<slot>_SDQuests"), Delay 2 ->
--   EMSAsyncCheck.CheckSaveFiles(3) -> OnCompleted_0E13... "{slot} Slot Saved"
--   (or "failed to saved correctly").
--   Save_Player is ONE object per slot. The host's controller (journal: name,
--   kills, days, respawn point; @3716) and the host's character (look,
--   location and, through BP_JigComponent.SERVER_RequestSaveGame ->
--   SaveJigComponent, the inventory; @148690) write it in their ActorPreSave.
--
-- What this module does (each guard is a config switch):
--   [SAVE] lines for every save of this machine (trigger, slot, who was
--     excluded, whether PlayerInfo.sav holds the host's own character, files
--     rewritten, timing; afterwards the world objects EMS saves, counted) and
--     for every load (the host's character compared with the last save of
--     that slot: Mods/SDCoop/savecheck_last.txt). Console: sdcoop_savecheck.
--   save_guard (host): right before EMS starts (native pre-hook of
--     AsyncSaveActors) every other player's character / controller is tagged
--     skip-save the game's way (sdc_players does it once a second: this closes
--     the gap right after a respawn); the host's own character / controller
--     must not carry the tag (it would drop the host's inventory from the
--     save). The host's world never goes into the client throwaway slot.
--   save_repair (host): PlayerInfo.sav was written with another player's
--     inventory (a client's own save sends SERVER_RequestSaveGame, which
--     writes the HOST's in-memory Save_Player) -> the game's save once more.
--   client_save_guard (client): the client's own saves (quick-save key,
--     sleeping) always go into the throwaway slot, also when the game picks a
--     new "QuickSave<date>" slot (Save.QuickSaveSlot), and the client's own
--     character is skip-save on the client, so that save never sends
--     SERVER_RequestSaveGame into the host's Save_Player.
--   autosave_watchdog (host): Game.AutoSave is on but the GameMode's 600 s
--     timer is not running -> the game's own EventSave(true).
--   coop_autosave (host, Game.AutoSave off): every 10 minutes after the last
--     save / load the mod calls the game's own GameMode.AutoSaveGame and
--     checks that a save started (see coop_autosave below).
--   Startup: a game closed while connected left EMS's current slot (kept in
--     Saved\Config\Windows\EmsUser.ini) at the throwaway slot: Continue
--     disappears, and a world opened without loading would be saved there and
--     deleted at the next start. It goes back to the slot remembered at the
--     join (Mods/SDCoop/savecheck_client_slot.txt) or the newest slot.
--   Backups (sdc_session.backup_saves -> M.after_backup): only the newest
--     backup_keep automatic backups stay (other folders are never touched).
--
-- Hook callbacks never throw and return nothing; no object wrapper is kept
-- between calls (names, addresses and numbers only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")

local M = {
    stats = {
        saves = 0, saves_ok = 0, saves_failed = 0, client_saves = 0, loads = 0,
        tagged_at_save = 0, host_untagged = 0, slot_guard = 0, client_slot_redirects = 0,
        remote_inv_writes = 0, player_mismatch = 0, repairs = 0, autosave_starts = 0,
        slot_restores = 0, backups_pruned = 0, coop_autosaves = 0, coop_autosaves_ok = 0,
    },
    last = nil,        -- summary of the last finished save (plain data)
    last_load = nil,
}

local S = nil
local clock = os.clock

-- ---------------------------------------------------------------------------
-- Settings (defaults apply until the keys are in sdc_config's SCHEMA)
-- ---------------------------------------------------------------------------

local DEFAULTS = {
    savecheck = true,
    savecheck_counts = true,
    save_guard = true,
    save_repair = true,
    client_save_guard = true,
    autosave_watchdog = true,
    coop_autosave = true,
    backup_keep = 10,
}

local function opt(key)
    local v = cfg.get(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

-- ---------------------------------------------------------------------------
-- Game assets
-- ---------------------------------------------------------------------------

local TEMP_SLOT = "SDCoop_ClientTemp"
local SKIP_TAG = "EMS_SkipSave"
local EMS_LIB = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"
local SAVE_PLAYER = "/Game/Blueprints/Saves/Save_Player.Save_Player_C"
local PC = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"
local GM = "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C"
local CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local SAVEMENU = "/Game/UI/Menus/SaveGame/SaveMenu.SaveMenu_C"
local SLEEPUI = "/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C"

local F_SAVE = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
local F_LOAD = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors"
local F_CUSTOM = "/Script/EasyMultiSave.EMSFunctionLibrary:SaveCustom"
local ACTORS_DONE = "OnCompleted_9CDBA9034C950D925C1539BE037C23EF"
local ACTORS_FAILED = "OnFailed_9CDBA9034C950D925C1539BE037C23EF"
local CHECK_DONE = "OnCompleted_0E13F8DC4FF1E81D4DC55BB17E7EC154"
local CHECK_FAILED = "OnFailed_0E13F8DC4FF1E81D4DC55BB17E7EC154"
local CHECK_VERSION = "OnVersionMismatch_0E13F8DC4FF1E81D4DC55BB17E7EC154"
local LOAD_DONE = "OnCompleted_F36E30354316ADD99BBAD29E4E315233"

-- S_ReplicatedContainerInfo / item members (BP_JigComponent, as sdc_consume)
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"

local JOURNAL = { "ZombieKills", "BossZombieKills", "HumanKills", "AnimalKills", "DaysSurvived", "InfestationsDestroyed" }

-- World objects EMS saves (EMSActorSaveInterface in the class chain), for the
-- count after a save; the last two are listed for the log only.
local COUNT_CLASSES = {
    { "containers", "BP_LootContainer_C" },
    { "containers", "BP_MASTER_PicklockContainer_C" },
    { "containers", "BP_MASTER_ToolRequiredContainer_C" },
    { "buildings", "Buildable_MASTER_C" },
    { "vehicles", "BP_VehicleMaster_C" },
    { "traders", "BP_TraderMaster_C" },
    { "infestations", "BP_Infestation_C", "IsDestroyed?" },
    { "trash", "TrashObject_C", "IsDestroyed" },
    { "wells", "BP_WaterWell_C" },
    { "deathbags", "Container_DeadPlayerLoot_C" },
}

local SAVE_TIMEOUT_S = 60
local REPAIR_GAP_S = 120
local AUTOSAVE_CHECK_S = 15
local COOP_AUTOSAVE_S = 600    -- co-op autosave: the game's own period (GameMode K2_SetTimer "AutoSaveGame" 600)
local COOP_RETRY_S = 60        -- a co-op autosave that did not save: tried again this much later
local COOP_VERIFY_MS = 5000    -- after the game's AutoSaveGame: a save must have started by then
local HOOK_RETRY_S = 3
local BACKUP_DIR_PAT = "^%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d$"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local hooked = {}           -- [path] = true (hooks stay registered)
local hook_try_at = -100
local rec = nil             -- the save in progress (plain data only)
local load_rec = nil        -- the load in progress
local counts_job = nil      -- { i, out, t0, n }: world counts after a save
local save_n = 0
local last_repair = -1000
local started = false       -- startup slot check done
local start_tries = 0
local world_state = { autosave_at = -100, autosave_logged = false, in_game_since = nil }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function obj(p)
    local v = get(p)
    if ue.valid(v) then return v end
    return nil
end

local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and a then return a end
    return ue.name(o)
end

local function role()
    return (S and S.role) or "unknown"
end

local function has_tag(actor, tag)
    local found = false
    pcall(function()
        actor.Tags:ForEach(function(_, e)
            if ue.str(e:get()) == tag then found = true end
        end)
    end)
    return found
end

local function num(v)
    if type(v) == "number" then return string.format("%g", v) end
    return tostring(v)
end

local function ems()
    return ue.find_object(EMS_LIB), ue.world_context()
end

local function slot_exists(name)
    if type(name) ~= "string" or name == "" then return false end
    local lib, wc = ems()
    if not lib or not wc then return nil end
    local ok, v = pcall(function() return lib:DoesSaveSlotExist(wc, name, false) end)
    if ok then return v == true end
    return nil
end

local function set_slot(name, why)
    if ue.is_wrapper_text(name) then
        log.warn("[SAVE] current save slot NOT set to '%s' (%s): a script value, not a save name", tostring(name), why)
        return false
    end
    local lib, wc = ems()
    if not lib or not wc then return false end
    local ok, err = pcall(function() lib:SetCurrentSaveGameName(wc, name) end)
    log.info("[SAVE] current save slot set to '%s' (%s; ok=%s%s)", name, why, tostring(ok),
        ok and "" or (" " .. tostring(err)))
    return ok
end

-- EMS's own list (the save menu's), newest first.
local function sorted_slots()
    local lib, wc = ems()
    if not lib or not wc then return nil end
    local ok, arr = pcall(function() return lib:GetSortedSaveSlots(wc) end)
    if not ok or arr == nil then return nil end
    local out = {}
    -- ue.fstring: the element's text, never a wrapper's tostring (0.6.46 set
    -- the host's slot to "RemoteUnrealParam: 00000222D764E2C8" from here)
    local okf = pcall(function()
        arr:ForEach(function(_, e)
            local s = ue.fstring(e)
            if s ~= "" and not ue.is_wrapper_text(s) then out[#out + 1] = s end
        end)
    end)
    if not okf and type(arr) == "table" then
        for _, s in ipairs(arr) do
            local t = ue.fstring(s)
            if t ~= "" and not ue.is_wrapper_text(t) then out[#out + 1] = t end
        end
    end
    return out
end

local function mod_dir()
    local p = cfg.path
    if type(p) ~= "string" then return nil end
    return p:match("^(.*)[/\\][^/\\]*$")
end

local function saves_dir()
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return nil end
    return base .. "\\SurrounDead\\Saved\\SaveGames\\"
end

local function read_file(path)
    local f = path and io.open(path, "r")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local function write_file(path, s)
    local f = path and io.open(path, "w")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local function file_exists(path)
    local f = path and io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

-- Size + hash of a save file: whole file up to 8 KB, else every 7th byte
-- of the first and last 32 KB (enough to see that EMS rewrote it).
local function file_print(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end") or 0
    f:seek("set", 0)
    local parts = {}
    if size <= 8192 then
        parts[1] = { f:read("a") or "", 1 }
    else
        parts[1] = { f:read(32768) or "", 7 }
        f:seek("set", math.max(32768, size - 32768))
        parts[2] = { f:read(32768) or "", 7 }
    end
    f:close()
    local h = size % 2147483647
    for _, p in ipairs(parts) do
        local s, step = p[1], p[2]
        for i = 1, #s, step do h = (h * 31 + s:byte(i)) % 2147483647 end
    end
    return { size = size, h = h }
end

-- The files of one slot: EMS's folder (Slot = slot info, Player = player
-- actors, PlayerInfo = Save_Player, Level = world actors, General = weather)
-- and the game's own <slot>_SkillTree / <slot>_SDQuests next to it.
local SLOT_FILES = { "Slot.sav", "Player.sav", "PlayerInfo.sav", "Level.sav", "General.sav", "Difficulties.sav" }
local SIDE_FILES = { "_SkillTree.sav", "_SDQuests.sav" }

local function slot_prints(slot)
    local dir = saves_dir()
    if not dir or type(slot) ~= "string" or slot == "" then return {} end
    local out = {}
    for _, f in ipairs(SLOT_FILES) do out[f] = file_print(dir .. slot .. "\\" .. f) end
    for _, f in ipairs(SIDE_FILES) do out[f] = file_print(dir .. slot .. f) end
    return out
end

local function short_file(f) return (f:gsub("^_", ""):gsub("%.sav$", "")) end

-- "Slot, PlayerInfo, Level 45 KB, ..." of the files rewritten since `before`.
local function files_report(before, after)
    local changed, same, missing = {}, {}, {}
    local all = {}
    for _, f in ipairs(SLOT_FILES) do all[#all + 1] = f end
    for _, f in ipairs(SIDE_FILES) do all[#all + 1] = f end
    for _, f in ipairs(all) do
        local a, b = after and after[f], before and before[f]
        local nm = short_file(f)
        if not a then
            missing[#missing + 1] = nm
        elseif not b or a.size ~= b.size or a.h ~= b.h then
            changed[#changed + 1] = a.size >= 4096 and string.format("%s %d KB", nm, math.floor(a.size / 1024 + 0.5)) or nm
        else
            same[#same + 1] = nm
        end
    end
    local s = "rewritten: " .. (#changed > 0 and table.concat(changed, ", ") or "none")
    if #same > 0 then s = s .. "; unchanged: " .. table.concat(same, ", ") end
    if #missing > 0 then s = s .. "; missing: " .. table.concat(missing, ", ") end
    return s, #changed, #missing
end

-- ---------------------------------------------------------------------------
-- Players: the host's own character / controller, remote ones
-- ---------------------------------------------------------------------------

local function remote_records()
    return (S and S.remote) or {}
end

local function remote_pc(pc)
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

-- Name of the remote player a character belongs to (nil = not known as remote).
local function remote_name_of_pawn(p)
    local a = addr(p)
    for _, r in pairs(remote_records()) do
        local rp = ue.pawn_of(r.pc)
        if (rp and addr(rp) == a) or (ue.valid(r.pawn) and addr(r.pawn) == a) then return r.name or "?" end
    end
    local c = ue.prop(p, "Controller")
    if remote_pc(c) then return "?" end
    return nil
end

-- Inventory fingerprint of a container array (MainJigContainers of a
-- component or of Save_Player): items, total count, hash of uid=count.
local function inv_print(containers)
    if containers == nil then return nil end
    local list, total = {}, 0
    local ok = pcall(function()
        containers:ForEach(function(_, c)
            c:get()[F_ITEMS]:ForEach(function(_, it)
                local item = it:get()
                local g = item[F_USID]
                local n = tonumber(item[F_INFO][F_COUNT]) or 0
                total = total + n
                list[#list + 1] = string.format("%d:%d:%d:%d=%d", g.A, g.B, g.C, g.D, n)
            end)
        end)
    end)
    if not ok then return nil end
    table.sort(list)
    local h = #list
    for _, s in ipairs(list) do
        for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    end
    return { n = #list, total = total, h = h }
end

local function inv_str(p)
    if not p then return "?" end
    return string.format("%d items/%d #%x", p.n, p.total, p.h)
end

local function pawn_inv(pawn)
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) then return nil end
    return inv_print(ue.prop(comp, "MainJigContainers"))
end

-- Level, XP, skill points and journal of a controller (plain table).
local function pc_stats(pc)
    if not ue.valid(pc) then return nil end
    local lev = ue.prop(pc, "LevellingComponent")
    local tech = ue.prop(pc, "TechTreeComponent")
    local t = {
        level = ue.prop(lev, "CurrentLevel"), xp = ue.prop(lev, "CurrentXP"),
        sp = ue.prop(tech, "SkillPoints"), cp = ue.prop(tech, "CurrentPoints"),
        name = ue.str(ue.prop(pc, "Forename")) .. " " .. ue.str(ue.prop(pc, "Surname")),
    }
    for _, k in ipairs(JOURNAL) do t[k] = ue.prop(pc, k) end
    return t
end

local function stats_str(t)
    if not t then return "?" end
    return string.format("level %s xp %s sp %s/%s kills z%s b%s h%s a%s days %s nests %s",
        num(t.level), num(t.xp), num(t.sp), num(t.cp), num(t.ZombieKills), num(t.BossZombieKills),
        num(t.HumanKills), num(t.AnimalKills), num(t.DaysSurvived), num(t.InfestationsDestroyed))
end

local function save_player_obj()
    local lib, wc = ems()
    local cls = ue.find_object(SAVE_PLAYER)
    if not lib or not wc or not cls then return nil end
    local ok, o = pcall(function() return lib:GetCustomSave(wc, cls, "", "") end)
    if ok and ue.valid(o) then return o end
    return nil
end

local function vec_of(t)
    local x = ue.try(function() return t.Translation.X end)
    local y = ue.try(function() return t.Translation.Y end)
    local z = ue.try(function() return t.Translation.Z end)
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

-- Save_Player (the object EMS wrote / is about to write) against the host's
-- own controller and character. Returns a plain table.
local function check_save_player(sp)
    local res = { ok = true, notes = {} }
    sp = sp or save_player_obj()
    if not ue.valid(sp) then
        res.ok = nil
        res.notes[#res.notes + 1] = "Save_Player not found"
        return res
    end
    local pc = ue.local_pc()
    local pawn = ue.local_pawn()
    res.file_inv = inv_print(ue.prop(sp, "MainJigContainers"))
    res.host_inv = pawn and pawn_inv(pawn) or nil
    res.stats = pc_stats(pc)
    res.loc = vec_of(ue.prop(sp, "PlayerLocation"))
    if res.file_inv and res.host_inv and res.file_inv.h ~= res.host_inv.h then
        res.ok = false
        res.notes[#res.notes + 1] = string.format("inventory in Save_Player %s, host's character %s",
            inv_str(res.file_inv), inv_str(res.host_inv))
        -- whose is it?
        for _, r in pairs(remote_records()) do
            local p = ue.pawn_of(r.pc) or (ue.valid(r.pawn) and r.pawn or nil)
            local ip = p and pawn_inv(p)
            if ip and ip.h == res.file_inv.h and ip.n > 0 then
                res.remote_inv = r.name or "?"
                res.notes[#res.notes + 1] = "it is " .. tostring(r.name) .. "'s inventory"
            end
        end
    end
    if res.stats then
        for _, k in ipairs(JOURNAL) do
            local a, b = ue.prop(sp, k), res.stats[k]
            if type(a) == "number" and type(b) == "number" and math.abs(a - b) > 0.001 then
                res.ok = false
                res.notes[#res.notes + 1] = string.format("%s %s in Save_Player, %s on the host", k, num(a), num(b))
            end
        end
    end
    return res
end

-- ---------------------------------------------------------------------------
-- Host: skip-save of other players' characters / controllers right before
-- EMS starts; the host's own must be saved
-- ---------------------------------------------------------------------------

-- apply = false: only count (console report).
local function host_guard(apply)
    local out = { chars = 0, tagged = 0, newly = 0, pcs = 0, pcs_tagged = 0, host_char = "none", host_pc = "?" }
    local lib = (apply and opt("save_guard")) and ue.find_object(EMS_LIB) or nil
    -- sdc_players' own pass first (the same tags, same rules)
    local players = package.loaded["sdc_players"]
    if lib and type(players) == "table" and players.host_skip_save_tick then pcall(players.host_skip_save_tick) end
    local me = ue.local_pawn()
    local me_a = me and addr(me)
    local mypc = ue.local_pc()
    for _, r in pairs(remote_records()) do
        if ue.valid(r.pc) then
            out.pcs = out.pcs + 1
            if not has_tag(r.pc, SKIP_TAG) and lib then
                pcall(function() lib:SetActorSaveProperties(r.pc, true, false, false, 0) end)
                out.newly = out.newly + 1
            end
            if has_tag(r.pc, SKIP_TAG) then out.pcs_tagged = out.pcs_tagged + 1 end
        end
    end
    for _, p in ipairs(ue.find_all("BP_PlayerCharacter_C")) do
        if ue.valid(p) then
            local a = addr(p)
            if me_a and a == me_a then
                local tagged = has_tag(p, SKIP_TAG)
                out.host_char = tagged and "TAGGED" or "saved"
                if tagged and lib and ue.prop(p, "PlayerDead?") ~= true then
                    -- the game tags a character only when it dies (AfterDeath @286):
                    -- an alive host character with the tag would lose its inventory
                    pcall(function() lib:SetActorSaveProperties(p, false, false, false, 0) end)
                    M.stats.host_untagged = M.stats.host_untagged + 1
                    out.host_char = has_tag(p, SKIP_TAG) and "TAGGED (could not clear)" or "saved (tag cleared)"
                    log.err("[SAVE] the host's own character was marked skip-save; cleared (%s)", ue.short(p))
                end
            else
                out.chars = out.chars + 1
                if not has_tag(p, SKIP_TAG) and lib then
                    -- only characters known to be other players' (the host's own
                    -- new character may not be possessed yet)
                    local who = me_a and "other" or remote_name_of_pawn(p)
                    if who then
                        pcall(function() lib:SetActorSaveProperties(p, true, false, false, 0) end)
                        out.newly = out.newly + 1
                        log.info("[SAVE] guard: character %s (%s) marked skip-save before the save", ue.short(p), tostring(who))
                    end
                end
                if has_tag(p, SKIP_TAG) then out.tagged = out.tagged + 1 end
            end
        end
    end
    if ue.valid(mypc) then
        local tagged = has_tag(mypc, SKIP_TAG)
        out.host_pc = tagged and "TAGGED" or "saved"
        if tagged and lib then
            -- BP_PlayerController BeginPlay @9243: (false, true, false, 0) = persistent
            pcall(function() lib:SetActorSaveProperties(mypc, false, true, false, 0) end)
            M.stats.host_untagged = M.stats.host_untagged + 1
            out.host_pc = has_tag(mypc, SKIP_TAG) and "TAGGED (could not clear)" or "saved (tag cleared)"
            log.err("[SAVE] the host's own controller was marked skip-save; set back to persistent")
        end
    end
    M.stats.tagged_at_save = M.stats.tagged_at_save + out.newly
    return out
end

-- ---------------------------------------------------------------------------
-- Client: own saves go to the throwaway slot, own character skip-save
-- ---------------------------------------------------------------------------

local function client_tag_own(why)
    if not opt("client_save_guard") then return false end
    local pawn = ue.local_pawn()
    if not pawn or has_tag(pawn, SKIP_TAG) then return false end
    local lib = ue.find_object(EMS_LIB)
    if not lib then return false end
    local ok = pcall(function() lib:SetActorSaveProperties(pawn, true, false, false, 0) end)
    log.info("[SAVE] client: own character %s marked skip-save (%s): this game's saves do not send its inventory to the host's Save_Player (ok=%s)",
        ue.short(pawn), why, tostring(ok))
    return ok
end

-- A slot folder the game named for a client save that went to the
-- throwaway slot instead: only its thumbnail was written there.
local function cleanup_junk(slot)
    local dir = saves_dir()
    if not dir or type(slot) ~= "string" or slot == "" or slot == TEMP_SLOT then return end
    if not slot:match("^[%w_%-]+$") then return end
    local d = dir .. slot
    if file_exists(d .. "\\Slot.sav") or file_exists(d .. "\\Level.sav") then return end
    local n = 0
    for _, f in ipairs({ "Thumb.sav", "Thumb.jpg", "Thumb.png" }) do
        if os.remove(d .. "\\" .. f) then n = n + 1 end
    end
    -- rmdir without /S removes only an empty folder
    pcall(os.execute, string.format('rmdir "%s" >nul 2>&1', d))
    log.info("[SAVE] client: thumbnail-only folder of '%s' removed (%d file(s))", slot, n)
end

-- ---------------------------------------------------------------------------
-- Remembered slot of a client (a game closed while connected)
-- ---------------------------------------------------------------------------

local function client_slot_file()
    local d = mod_dir()
    return d and (d .. "/savecheck_client_slot.txt") or nil
end

local function remembered_slot()
    local s = read_file(client_slot_file())
    s = s and s:match("^%s*(.-)%s*$") or nil
    if s == "" or s == TEMP_SLOT then return nil end
    return s
end

-- The newest slot that really is on disk (EMS's own check), never the
-- throwaway slot.
local function newest_slot()
    local list = sorted_slots()
    if not list then return nil end
    for _, s in ipairs(list) do
        if s ~= TEMP_SLOT and slot_exists(s) == true then return s end
    end
    return nil
end

-- sdc_session.client_save_redirect(true): the slot to come back to when the
-- player leaves (remembered on disk until then).
function M.client_slot_before_join(cur)
    local prev = cur
    if type(prev) ~= "string" or prev == "" or prev == TEMP_SLOT then
        prev = remembered_slot() or newest_slot() or prev
        log.info("[SAVE] client: current slot was '%s' (left by a game closed while connected); will come back to '%s'",
            tostring(cur), tostring(prev))
    end
    if type(prev) == "string" and prev ~= "" and prev ~= TEMP_SLOT then
        write_file(client_slot_file(), prev .. "\n")
    end
    return prev
end

-- sdc_session.client_save_redirect(false): back in the player's own slot.
function M.client_slot_restored(prev)
    write_file(client_slot_file(), "")
    log.debug("[SAVE] client: own slot '%s' restored, memory cleared", tostring(prev))
end

-- Once at start (not connected): the current slot still the throwaway one.
-- Returns true when done (false: EMS not reachable yet, try again).
local function startup_slot_check()
    local cur, err = ue.ems_current_slot()
    if cur == nil then
        log.debug("[SAVE] current save slot unknown at start: %s", tostring(err))
        return false
    end
    local on_disk = cur ~= "" and slot_exists(cur) or false
    log.info("[SAVE] current save slot at start: '%s'%s", cur, cur ~= "" and (on_disk and "" or " (not on disk)") or "")
    -- a wrapper's text as the slot name (0.6.40-0.6.48: "RemoteUnrealParam_...")
    -- that no save ever wrote: the same repair as the throwaway slot. Once the
    -- game saved into it, it is a real slot and stays.
    local broken = ue.is_wrapper_text(cur) and on_disk ~= true
    if cur ~= TEMP_SLOT and not broken then
        write_file(client_slot_file(), "")
        return true
    end
    local target = remembered_slot()
    local why = "remembered at the last join"
    if not target or ue.is_wrapper_text(target) or slot_exists(target) ~= true then
        target = newest_slot()
        why = "the newest save"
    end
    target = target or ""
    local cause = broken and ("the slot name was a script value ('" .. cur .. "'), no save on disk; " .. why)
        or ("the game was closed while connected to a friend; " .. why)
    if broken then M.stats.broken_slot_fixed = (M.stats.broken_slot_fixed or 0) + 1 end
    if set_slot(target, cause) then
        M.stats.slot_restores = M.stats.slot_restores + 1
        write_file(client_slot_file(), "")
        if target ~= "" then
            log.toast("Сохранения: «Продолжить» снова указывает на ваше сохранение " .. target
                .. (broken and " (имя прошлого слота было испорчено модом, сохранения с ним нет)."
                    or " (игра была закрыта во время подключения к другу)."), "info", 8,
                "[SAVE] Continue points to " .. target .. " again")
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Last save per slot (compared at the next load)
-- ---------------------------------------------------------------------------

local function history_file()
    local d = mod_dir()
    return d and (d .. "/savecheck_last.txt") or nil
end

local function history_read()
    local out = {}
    local s = read_file(history_file())
    if not s then return out end
    for line in s:gmatch("[^\n]+") do
        local f = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
        if #f >= 12 and f[1] ~= "" then
            out[f[1]] = { when = f[2], level = tonumber(f[3]), xp = tonumber(f[4]), sp = tonumber(f[5]),
                          zk = tonumber(f[6]), days = tonumber(f[7]), n = tonumber(f[8]), total = tonumber(f[9]),
                          h = tonumber(f[10]), x = tonumber(f[11]), y = tonumber(f[12]) }
        end
    end
    return out
end

local function history_write(slot, st, inv, loc)
    if type(slot) ~= "string" or slot == "" or not st then return end
    local all = history_read()
    all[slot] = { when = os.date("%Y-%m-%d %H:%M:%S"), level = st.level, xp = st.xp, sp = st.sp, zk = st.ZombieKills,
                  days = st.DaysSurvived, n = inv and inv.n, total = inv and inv.total, h = inv and inv.h,
                  x = loc and loc.X, y = loc and loc.Y }
    local lines, keys = {}, {}
    for k in pairs(all) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(all[a].when) > tostring(all[b].when) end)
    for i, k in ipairs(keys) do
        if i > 40 then break end
        local e = all[k]
        local function v(x) return x == nil and "" or tostring(x) end
        lines[#lines + 1] = table.concat({ k, v(e.when), v(e.level), v(e.xp), v(e.sp), v(e.zk), v(e.days),
            v(e.n), v(e.total), v(e.h), v(e.x), v(e.y) }, "\t")
    end
    write_file(history_file(), table.concat(lines, "\n") .. "\n")
end

-- ---------------------------------------------------------------------------
-- World counts after a host save (a few FindAllOf, spread over ticks)
-- ---------------------------------------------------------------------------

local function counts_step(job, budget)
    for _ = 1, budget do
        local c = COUNT_CLASSES[job.i]
        if not c then return true end
        job.i = job.i + 1
        local t0 = clock()
        local list = ue.find_all(c[2])
        local e = job.out[c[1]] or { n = 0, flagged = 0 }
        e.n = e.n + #list
        if c[3] then
            for _, a in ipairs(list) do
                if ue.valid(a) and ue.prop(a, c[3]) == true then e.flagged = e.flagged + 1 end
            end
            e.flag = true
        end
        job.out[c[1]] = e
        job.ms = job.ms + (clock() - t0) * 1000
    end
    return COUNT_CLASSES[job.i] == nil
end

local function counts_str(out)
    local function n(k) return out[k] and out[k].n or 0 end
    local function f(k) return out[k] and out[k].flagged or 0 end
    return string.format("containers %d, buildings %d, vehicles %d, traders %d, wells %d, infestations %d (%d destroyed), "
        .. "trash piles %d (%d broken); death bags %d (the game never saves those)",
        n("containers"), n("buildings"), n("vehicles"), n("traders"), n("wells"), n("infestations"), f("infestations"),
        n("trash"), f("trash"), n("deathbags"))
end

-- ---------------------------------------------------------------------------
-- Autosave (host)
-- ---------------------------------------------------------------------------

local function autosave_state()
    local ksl, gps, wc = ue.ksl(), ue.gameplay_statics(), ue.world_context()
    local st = {}
    if ksl then
        st.cvar = ue.try(function() return ksl:GetConsoleVariableBoolValue("Game.AutoSave") end)
        st.newslot_auto = ue.try(function() return ksl:GetConsoleVariableBoolValue("Save.AutoSaveSlot") end)
        st.newslot_quick = ue.try(function() return ksl:GetConsoleVariableBoolValue("Save.QuickSaveSlot") end)
        st.sleep = ue.try(function() return ksl:GetConsoleVariableBoolValue("Game.SleepingSavesGame") end)
        st.permadeath = ue.try(function() return ksl:GetConsoleVariableBoolValue("Difficulty.Permadeath") end)
    end
    local gm = gps and wc and ue.try(function() return gps:GetGameMode(wc) end)
    if ue.valid(gm) and ue.class_name(gm) == "BP_SurroundeadGameMode_C" then
        st.gm = true
        st.flag = ue.prop(gm, "Autosave")
        if ksl then
            st.active = ue.try(function() return ksl:K2_IsTimerActive(gm, "AutoSaveGame") end)
            st.left = ue.try(function() return ksl:K2_GetTimerRemainingTime(gm, "AutoSaveGame") end)
        end
    end
    return st, (ue.valid(gm) and gm or nil)
end

local function autosave_str(st)
    if not st.gm then return "no game mode here" end
    local t = st.active == true and string.format("timer on, next in %d s", math.floor(tonumber(st.left) or -1))
        or "timer NOT running"
    return string.format("Game.AutoSave=%s (GameMode.Autosave=%s), %s; new slot per autosave=%s, per quick save=%s, sleeping saves=%s",
        tostring(st.cvar), tostring(st.flag), t, tostring(st.newslot_auto), tostring(st.newslot_quick), tostring(st.sleep))
end

-- Co-op autosave (coop_autosave: the game's Game.AutoSave is off - its
-- default, SD_GameInstance @2373 - and this machine hosts). The game's own
-- 10-minute timer is not relied on for it: started by the mod with
-- GameMode.EventSave(true) (up to 0.7.1) it never saved at its first period
-- (2026-11-11: started 16:25:55 -> first save 16:45:21; 18:08:20 -> 18:27:44;
-- the sessions started 18:58:10 and 20:03:00 ended 14 / 10 minutes later
-- without any save, so the slot stayed at 18:31:46). Why the first firing
-- saves nothing is not known: AutoSaveGame (@0-591) only skips while the
-- game is paused, with permadeath or with player 0 dead, then calls player
-- 0's SaveGameToSlot (no gate there, @9611); its timer is also cleared by
-- the game's own menus (PauseScreen @656 "main menu", SaveMenu @1035 load).
-- So COOP_AUTOSAVE_S after this machine's last save (or load, or the start
-- of play) the mod calls GameMode.AutoSaveGame itself - the function that
-- timer calls: the game's own checks and slot choice (Save.AutoSaveSlot),
-- then SaveGameToSlot, so every hook of a save runs (sdc_persist commits
-- the clients' records on it) - and checks COOP_VERIFY_MS later that a save
-- really started (this module's save-pre hook); if not, it says why and
-- tries again COOP_RETRY_S later.
local function coop_autosave(now, gm, pawn)
    local ws = world_state
    if not ws.coop_on then
        ws.coop_on = true
        ws.coop_base = ws.in_game_since or now
        log.warn("[SAVE] autosave: co-op world, the game's autosave setting is off; the mod runs the game's own autosave"
            .. " (GameMode.AutoSaveGame) every %d minutes, the first in %d s (Game.AutoSave unchanged)",
            COOP_AUTOSAVE_S // 60, math.max(0, math.floor(ws.coop_base + COOP_AUTOSAVE_S - now)))
        if not ws.coop_autosave_told then
            ws.coop_autosave_told = true
            log.toast("Совместная игра: автосохранение мира каждые 10 минут включено (настройка игры не изменена).",
                "info", 8, "[SAVE] co-op autosave every 10 minutes on")
        end
    end
    if rec then return end   -- a save is running
    if ws.coop_verify then
        if now - ws.coop_verify < 30 then return end
        ws.coop_verify = nil   -- the check never ran: go on
    end
    local base = math.max(ws.last_save or ws.coop_base, ws.coop_base)
    if now - base < COOP_AUTOSAVE_S or now < (ws.coop_retry_at or 0) then return end
    if ue.prop(pawn, "PlayerDead?") == true then
        ws.coop_retry_at = now + COOP_RETRY_S   -- the game itself skips it (@115-280)
        return
    end
    local t_call = clock()
    local ok, err = pcall(function() gm:AutoSaveGame() end)
    M.stats.coop_autosaves = M.stats.coop_autosaves + 1
    ws.coop_verify = now
    ue.delay("savecheck-coopsave", COOP_VERIFY_MS, function()
        if ws ~= world_state then return end   -- another world by now
        ws.coop_verify = nil
        if (ws.last_save or -1) >= t_call then
            M.stats.coop_autosaves_ok = M.stats.coop_autosaves_ok + 1
            log.info("[SAVE] co-op autosave: the game's AutoSaveGame saved the world (save #%d, slot '%s'); the next in %d minutes",
                save_n, tostring(ue.ems_current_slot()), COOP_AUTOSAVE_S // 60)
            return
        end
        ws.coop_retry_at = clock() + COOP_RETRY_S
        local gps, wc = ue.gameplay_statics(), ue.world_context()
        local paused = gps and wc and ue.try(function() return gps:IsGamePaused(wc) end)
        local me = ue.local_pawn()
        log.warn("[SAVE] co-op autosave: the game's AutoSaveGame did NOT save (call ok=%s%s; game paused=%s, permadeath=%s,"
            .. " host dead=%s); again in %d s", tostring(ok), ok and "" or (" " .. tostring(err)), tostring(paused),
            tostring(autosave_state().permadeath), tostring(me == nil or ue.prop(me, "PlayerDead?") == true), COOP_RETRY_S)
    end)
end

local function autosave_watchdog(now)
    if now - world_state.autosave_at < AUTOSAVE_CHECK_S then return end
    world_state.autosave_at = now
    if ue.in_main_menu() then world_state.in_game_since = nil return end
    local pawn = ue.local_pawn()
    if not pawn then return end
    world_state.in_game_since = world_state.in_game_since or now
    if now - world_state.in_game_since < 30 then return end
    local st, gm = autosave_state()
    if not world_state.autosave_logged then
        world_state.autosave_logged = true
        local cur = ue.ems_current_slot()
        log.info("[SAVE] host world: slot '%s' (on disk: %s); autosave: %s", tostring(cur), tostring(slot_exists(cur)),
            autosave_str(st))
    end
    if not opt("autosave_watchdog") or not gm then return end
    if st.permadeath == true then return end
    -- Game.AutoSave is registered off by default (SD_GameInstance @2373), so
    -- most worlds never autosave. coop_autosave: a co-op world (this machine
    -- hosts) autosaves anyway (coop_autosave above), the setting itself
    -- stays as the player left it.
    if st.cvar ~= true then
        if opt("coop_autosave") == true then coop_autosave(now, gm, pawn) end
        return
    end
    if st.active == true then return end
    if ue.prop(pawn, "PlayerDead?") == true then return end
    -- Game.AutoSave on, its timer not running: what the CVar callback does
    -- (EventSave @822: GameMode.Autosave = value -> @803 -> @713 ->
    -- Event_AutoSave @571: K2_SetTimer AutoSaveGame 600 s, looping); at
    -- GameMode BeginPlay the host's character did not exist yet, so the
    -- callback started nothing
    local ok, err = pcall(function() gm:EventSave(true) end)
    local st2 = autosave_state()
    M.stats.autosave_starts = M.stats.autosave_starts + 1
    log.warn("[SAVE] autosave: Game.AutoSave is on but the game's 10-minute timer was not running; started it the game's way "
        .. "(EventSave(true) ok=%s%s) -> %s", tostring(ok), ok and "" or (" " .. tostring(err)), autosave_str(st2))
end

-- ---------------------------------------------------------------------------
-- The save record
-- ---------------------------------------------------------------------------

-- Guards that must act before EMS reads the slot / the actors (native
-- pre-hook of AsyncSaveActors); notes go into the record.
local function guards_before_save(r)
    local cur = r.slot
    if r.role == "client" then
        M.stats.client_saves = M.stats.client_saves + 1
        if not opt("client_save_guard") then return end
        client_tag_own("before this game's own save")
        if cur ~= TEMP_SLOT then
            -- quick save / sleep with Save.QuickSaveSlot named a new slot, or the
            -- redirect never happened: this world is the host's, not ours
            r.junk = cur
            if set_slot(TEMP_SLOT, "client save while connected; the game wanted '" .. tostring(cur) .. "'") then
                M.stats.client_slot_redirects = M.stats.client_slot_redirects + 1
                r.slot = TEMP_SLOT
                r.notes[#r.notes + 1] = "slot '" .. tostring(cur) .. "' replaced by the throwaway slot"
            end
        end
        return
    end
    if r.role ~= "host" then return end
    if cur == TEMP_SLOT and opt("save_guard") then
        local name = "CoopWorld_" .. os.date("%Y%m%d_%H%M%S")
        if set_slot(name, "the host's world must not go into the client throwaway slot") then
            M.stats.slot_guard = M.stats.slot_guard + 1
            r.slot = name
            r.notes[#r.notes + 1] = "throwaway slot replaced by new slot " .. name
            log.toast("Мир сохранён в новый слот " .. name .. " (текущим был временный слот клиента).", "warn", 10,
                "[SAVE] host world saved into new slot " .. name)
        end
    end
    local okg, g = pcall(host_guard, true)
    r.guard = okg and g or nil
    if not okg then r.notes[#r.notes + 1] = "guard error " .. tostring(g) end
end

local function begin_save(data)
    save_n = save_n + 1
    local r = {
        n = save_n, t0 = clock(), wall = os.date("%H:%M:%S"), role = role(), data = data,
        slot = ue.ems_current_slot(), trigger = nil, guess = nil, custom = {}, notes = {}, remote_inv = {},
    }
    -- the co-op autosave counts from this machine's last save (savecheck on or off)
    if r.role ~= "client" then world_state.last_save = r.t0 end
    guards_before_save(r)
    if not opt("savecheck") then return end   -- guards only, no record / lines
    if r.role ~= "client" then
        M.stats.saves = M.stats.saves + 1
        -- set by the host character's own SERVER_RequestSaveGame (its ActorPreSave)
        if hooked[JIG .. ":SERVER_RequestSaveGame"] then r.host_inv_saved = false end
        -- the pause menu's Quick Save has no hook of its own (it saves a tick later)
        local ps = ue.find_first("PauseScreen_C")
        if ps and ue.try(function() return ps:IsInViewport() end) == true then r.guess = "pause menu" end
    end
    r.before = slot_prints(r.slot)
    rec = r
end

local function finish_counts(job)
    log.info("[SAVE] world in save #%d (slot '%s'): %s [counted in %.0f ms]", job.n, tostring(job.slot),
        counts_str(job.out), job.ms)
    if M.last and M.last.n == job.n then M.last.world = counts_str(job.out) end
end

local function schedule_repair(r)
    if not opt("save_repair") or role() ~= "host" then return end
    if clock() - last_repair < REPAIR_GAP_S then
        log.err("[SAVE] PlayerInfo.sav of save #%d holds %s's inventory; already repaired recently - save again by hand", r.n,
            tostring(r.player and r.player.remote_inv))
        return
    end
    last_repair = clock()
    ue.delay("savecheck-repair", 2500, function()
        if rec then return end
        local pc = ue.local_pc()
        if not pc or not ue.local_pawn() then return end
        M.stats.repairs = M.stats.repairs + 1
        local ok, err = pcall(function() pc:SaveGameToSlot() end)
        log.warn("[SAVE] repair: the game's save runs again so the host's character writes its own inventory (ok=%s%s)",
            tostring(ok), ok and "" or (" " .. tostring(err)))
    end)
end

local function finish_save(result)
    local r = rec
    if not r then return end
    rec = nil
    local now = clock()
    local after = slot_prints(r.slot)
    local files, nchanged = files_report(r.before, after)
    local ok = result == "ok"
    if r.role == "client" then
        log.info("[SAVE] client save #%d %s in %.1f s: slot '%s' (this game's own throwaway copy; the world is saved by the host)%s",
            r.n, ok and "done" or result, now - r.t0, tostring(r.slot),
            #r.notes > 0 and (" - " .. table.concat(r.notes, "; ")) or "")
        if r.junk then ue.delay("savecheck-junk", 500, function() cleanup_junk(r.junk) end) end
        return
    end
    if ok then M.stats.saves_ok = M.stats.saves_ok + 1 else M.stats.saves_failed = M.stats.saves_failed + 1 end
    local trig = r.trigger or r.guess or "quick save / other"
    local excl
    if r.role == "host" and r.guard then
        local g = r.guard
        excl = string.format("other players excluded: %d/%d characters, %d/%d controllers skip-save%s; host character %s, host controller %s",
            g.tagged, g.chars, g.pcs_tagged, g.pcs, g.newly > 0 and string.format(" (%d tagged just now)", g.newly) or "",
            g.host_char, g.host_pc)
    else
        excl = "single player (nobody to exclude)"
    end
    local pl = "PlayerInfo.sav: not checked"
    local p = r.player
    if p then
        if p.ok == true then
            pl = string.format("PlayerInfo.sav = host's own (%s; inventory %s)", stats_str(p.stats), inv_str(p.file_inv))
        elseif p.ok == false then
            pl = "PlayerInfo.sav DIFFERS from the host: " .. table.concat(p.notes, "; ")
        else
            pl = "PlayerInfo.sav: " .. table.concat(p.notes, "; ")
        end
    end
    if r.host_inv_saved == false and r.t_actors then
        -- the host's character was not saved at all (dead: the game tags a dead
        -- character skip-save) or is tagged: its inventory is the last save's
        pl = pl .. "; the host character's inventory save (its ActorPreSave) did NOT run in this save"
    end
    local timing = string.format("%.1f s (actors %s)", now - r.t0,
        r.t_actors and string.format("%.1f s", r.t_actors - r.t0) or "?")
    local custom = {}
    for k, v in pairs(r.custom) do custom[#custom + 1] = k .. (v and "" or " FAILED") end
    table.sort(custom)
    local line = string.format("[SAVE] save #%d %s: slot '%s', trigger %s, %s; %s; %s; custom saves: %s; files %s",
        r.n, ok and "OK" or ("FAILED (" .. tostring(result) .. ")"), tostring(r.slot), trig, timing, excl, pl,
        #custom > 0 and table.concat(custom, ", ") or "none", files)
    if #r.remote_inv > 0 then
        line = line .. "; inventory saves from other players during it: " .. table.concat(r.remote_inv, ", ")
    end
    if #r.notes > 0 then line = line .. "; " .. table.concat(r.notes, "; ") end
    if ok and (not p or p.ok ~= false) and nchanged > 0 then
        log.info("%s", line)
    else
        log.warn("%s", line)
    end
    M.last = { n = r.n, wall = r.wall, ok = ok, slot = r.slot, trigger = trig, line = line }
    if p and p.ok == false then
        M.stats.player_mismatch = M.stats.player_mismatch + 1
        if p.remote_inv then schedule_repair(r) end
    end
    if ok and p and p.stats then pcall(history_write, r.slot, p.stats, p.host_inv or p.file_inv, p.loc) end
    if ok and r.role == "host" and opt("savecheck_counts") then
        counts_job = { i = 1, out = {}, ms = 0, n = r.n, slot = r.slot }
    end
end

-- ---------------------------------------------------------------------------
-- Hook callbacks
-- ---------------------------------------------------------------------------

-- EMSAsyncSaveGame.AsyncSaveActors (native pre): EMS is about to save.
local function on_save_pre(_, _, data_p)
    if rec and clock() - rec.t0 < SAVE_TIMEOUT_S then
        rec.notes[#rec.notes + 1] = "a second save started before this one finished"
        return
    end
    rec = nil
    begin_save(get(data_p))
end

-- (native post): the async node; None = EMS refused (another save / load running).
local function on_save_post(_, ret_p)
    if not rec or clock() - rec.t0 > 1 then return end
    if not obj(ret_p) then
        rec.notes[#rec.notes + 1] = "EMS did not start (another save or load in progress?)"
        finish_save("not started")
    end
end

local function own_pc(c)
    local pc = c and c:get()
    if not ue.valid(pc) then return false end
    local ok, isl = pcall(function() return pc:IsLocalController() end)
    return ok and isl == true
end

local function on_actors_saved(c)
    if not own_pc(c) then return end
    if not rec and not hooked[F_SAVE] then
        -- no native EMS hook here: the record starts late (no "before" files)
        begin_save(nil)
        if not rec then return end
        rec.notes[#rec.notes + 1] = "record started after the actors were saved (EMS hook missing)"
    end
    if not rec then return end
    rec.t_actors = clock()
end

local function on_actors_failed(c)
    if not rec or not own_pc(c) then return end
    finish_save("EMS could not save the actors")
end

local function on_verified(c)
    if not rec or not own_pc(c) then return end
    finish_save("ok")
end

local function on_verify_failed(c, why)
    if not rec or not own_pc(c) then return end
    finish_save("the game's file check: " .. why)
end

-- EMSFunctionLibrary.SaveCustom (native post): General / Difficulties / Save_Player.
local function on_save_custom(_, ret_p, _, save_p)
    if not rec then return end
    local so = obj(save_p)
    local cls = so and ue.class_name(so) or "?"
    local short = cls:gsub("^Save_", ""):gsub("_C$", "")
    rec.custom[short] = get(ret_p) == true
    if cls == "Save_Player_C" and rec.role ~= "client" then
        local ok, res = pcall(check_save_player, so)
        rec.player = ok and res or { ok = nil, notes = { "check error " .. tostring(res) } }
    end
end

-- The trigger's own function returned (it called SaveGameToSlot inside).
local function trigger(name)
    if rec and rec.trigger == nil and clock() - rec.t0 < 2 then rec.trigger = name end
end

-- BP_JigComponent.SERVER_RequestSaveGame (host, post): SaveJigComponent wrote
-- Save_Player's inventory. The host's own character does it in its
-- ActorPreSave; anyone else's call is a client's own save reaching the host.
local function on_inventory_save(c)
    if role() ~= "host" and role() ~= "standalone" then return end
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    local owner = ue.try(function() return comp:GetOwner() end)
    local me = ue.local_pawn()
    if ue.valid(owner) and me and addr(owner) == addr(me) then
        if rec then rec.host_inv_saved = true end
        return
    end
    local who = ue.valid(owner) and (remote_name_of_pawn(owner) or ue.short(owner)) or "?"
    M.stats.remote_inv_writes = M.stats.remote_inv_writes + 1
    if rec and rec.role ~= "client" then
        rec.remote_inv[#rec.remote_inv + 1] = who
        log.err("[SAVE] %s's game saved its inventory into the host's Save_Player WHILE the host was saving (save #%d); "
            .. "the check after PlayerInfo.sav tells whether it got in", who, rec.n)
    else
        log.warn("[SAVE] %s's game saved its inventory into the host's Save_Player (its own quick save / sleep; an old SDCoop "
            .. "on that machine?); the host's next save writes the host's own inventory again", who)
    end
end

local function host_load_report(r)
    local pc, pawn = ue.local_pc(), ue.local_pawn()
    local st = pc_stats(pc)
    local inv = pawn and pawn_inv(pawn) or nil
    local loc = pawn and ue.location(pawn) or nil
    local last = history_read()[r.slot or ""]
    local verdict = "no earlier save of this slot recorded"
    if last and st then
        local diffs = {}
        local function cmp(name, a, b)
            if a ~= nil and b ~= nil and math.abs(a - b) > 0.001 then
                diffs[#diffs + 1] = string.format("%s %s -> %s", name, num(a), num(b))
            end
        end
        cmp("level", last.level, tonumber(st.level))
        cmp("xp", last.xp, tonumber(st.xp))
        cmp("skill points", last.sp, tonumber(st.sp))
        cmp("zombie kills", last.zk, tonumber(st.ZombieKills))
        if inv and last.h then
            if last.h ~= inv.h then
                diffs[#diffs + 1] = string.format("inventory %s items/%s -> %s", num(last.n), num(last.total), inv_str(inv))
            end
        end
        if loc and last.x and last.y then
            local d = math.sqrt((loc.X - last.x) ^ 2 + (loc.Y - last.y) ^ 2) / 100
            if d > 5 then diffs[#diffs + 1] = string.format("position %.0f m away from the saved one", d) end
        end
        if #diffs == 0 then
            verdict = "matches the last save of this slot (" .. tostring(last.when) .. ")"
        else
            verdict = "DIFFERS from the last save of this slot (" .. tostring(last.when) .. "): " .. table.concat(diffs, ", ")
        end
    end
    local line = string.format("[SAVE] load from slot '%s' done in %.1f s: host %s, inventory %s - %s", tostring(r.slot),
        (r.t_done or clock()) - r.t0, stats_str(st), inv_str(inv), verdict)
    if verdict:find("DIFFERS", 1, true) then log.warn("%s", line) else log.info("%s", line) end
    M.last_load = { slot = r.slot, wall = r.wall, verdict = verdict }
end

-- EMSAsyncLoadGame.AsyncLoadActors (native pre)
local function on_load_pre(_, _, data_p)
    load_rec = { t0 = clock(), wall = os.date("%H:%M:%S"), slot = ue.ems_current_slot(), data = get(data_p), role = role() }
    M.stats.loads = M.stats.loads + 1
    -- the world is that save now: the co-op autosave counts from here (also a
    -- load during the session, which opens no new level)
    if load_rec.role ~= "client" then world_state.last_save, world_state.coop_retry_at = load_rec.t0, nil end
end

-- BP_PlayerController OnCompleted_F36E... (post): the game's load finished.
local function on_loaded(c)
    if not own_pc(c) then return end
    local r = load_rec or { t0 = clock(), wall = os.date("%H:%M:%S"), slot = ue.ems_current_slot(), role = role() }
    load_rec = nil
    r.t_done = clock()
    if r.role == "client" or role() == "client" then
        log.info("[SAVE] client: this game's own load from slot '%s' finished (throwaway; sdc_progress resets it)", tostring(r.slot))
        return
    end
    -- the inventory comes through LoadInventory right after; read a bit later
    ue.delay("savecheck-load", 3000, function()
        if role() == "client" then return end
        local ok, err = pcall(host_load_report, r)
        if not ok then log.err_throttled("savecheck.load", "[SAVE] load report: %s", tostring(err)) end
    end)
end

-- With savecheck off only the guards run (save-pre); every other hook only
-- feeds the record.
local function guarded(name, fn)
    return function(...)
        if name ~= "save-pre" and not opt("savecheck") then return end
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("savecheck." .. name, "[SAVE] %s hook: %s", name, tostring(err)) end
    end
end

-- { path, name, fn, post = fn (native only), native = true }
local HOOKS = {
    { F_SAVE, "save-pre", on_save_pre, post = on_save_post, native = true },
    { F_LOAD, "load-pre", on_load_pre, native = true },
    { F_CUSTOM, "save-custom", function() end, post = on_save_custom, native = true },
    { PC .. ":" .. ACTORS_DONE, "actors-saved", on_actors_saved },
    { PC .. ":" .. ACTORS_FAILED, "actors-failed", on_actors_failed },
    { PC .. ":" .. CHECK_DONE, "verified", on_verified },
    { PC .. ":" .. CHECK_FAILED, "verify-failed", function(c) on_verify_failed(c, "failed") end },
    { PC .. ":" .. CHECK_VERSION, "verify-failed", function(c) on_verify_failed(c, "version mismatch") end },
    { PC .. ":" .. LOAD_DONE, "loaded", on_loaded },
    { GM .. ":AutoSaveGame", "trigger", function() trigger("autosave") end },
    { SAVEMENU .. ":SaveGameToSlot", "trigger", function() trigger("save menu") end },
    { SLEEPUI .. ":BndEvt__Button_60_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", "trigger",
      function() trigger("sleep") end },
    { CHAR .. ":InpActEvt_IA_QuickSave_K2Node_EnhancedInputActionEvent_2", "trigger", function() trigger("quick save key") end },
    { JIG .. ":SERVER_RequestSaveGame", "inventory-save", on_inventory_save },
}

local function hooks_done()
    local n = 0
    for _, h in ipairs(HOOKS) do if hooked[h[1]] then n = n + 1 end end
    return n, #HOOKS
end

local function try_hooks(force)
    local now = clock()
    if not force and now - hook_try_at < HOOK_RETRY_S then return end
    hook_try_at = now
    for _, h in ipairs(HOOKS) do
        local path = h[1]
        if not hooked[path] and ue.find_object(path) then
            local ok, err
            if h.native then
                -- native: pre-hook (Context, params...), post-hook (Context, ReturnValue, params...)
                local post = h.post and guarded(h[2] .. "-post", h.post) or function() end
                ok, err = pcall(RegisterHook, path, guarded(h[2], h[3]), post)
            else
                -- Blueprint function: one callback, after it ran
                ok, err = pcall(RegisterHook, path, guarded(h[2], h[3]))
            end
            hooked[path] = ok == true
            log.info("[SAVE] hook %s %s%s", path:match("([%w_]+[.:][%w_]+)$") or path, ok and "ok" or "FAILED",
                ok and "" or (" " .. tostring(err)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Backups (sdc_session.backup_saves)
-- ---------------------------------------------------------------------------

local function backup_root()
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return nil end
    return base .. "\\SurrounDead\\Saved\\SDCoop_Backups"
end

-- Automatic backup folders (date-time names), oldest first.
local function list_backups()
    local root = backup_root()
    if not root then return nil end
    local okp, p = pcall(io.popen, string.format('dir /B /AD "%s" 2>nul', root))
    if not okp or not p then return nil end
    local out = {}
    for line in p:lines() do
        line = line:gsub("\r$", "")
        if line:match(BACKUP_DIR_PAT) then out[#out + 1] = line end
    end
    p:close()
    table.sort(out)
    return out, root
end

function M.prune_backups(keep)
    keep = tonumber(keep) or tonumber(opt("backup_keep")) or 10
    if keep <= 0 then return 0 end
    local list, root = list_backups()
    if not list or #list <= keep then return 0 end
    local cmds, removed = {}, {}
    for i = 1, #list - keep do
        cmds[#cmds + 1] = string.format('rmdir /S /Q "%s\\%s"', root, list[i])
        removed[#removed + 1] = list[i]
    end
    -- one shell for all (each os.execute starts cmd.exe); chunks stay well
    -- under cmd's 8191-character line limit
    local i = 1
    while i <= #cmds do
        local chunk = {}
        for j = i, math.min(i + 39, #cmds) do chunk[#chunk + 1] = cmds[j] end
        pcall(os.execute, table.concat(chunk, " & ") .. " >nul 2>&1")
        i = i + 40
    end
    local left = list_backups() or {}
    local n = #list - #left
    M.stats.backups_pruned = M.stats.backups_pruned + math.max(n, 0)
    log.info("[SAVE] backups: kept the newest %d of %d automatic backups, removed %d (oldest %s)", #left, #list, n,
        tostring(removed[1]))
    return n
end

-- After sdc_session copied SaveGames: check the copy, then prune.
function M.after_backup(dst, code)
    local ok = type(code) == "number" and code < 8
    local cur = ue.ems_current_slot()
    local dir = saves_dir()
    local verified = "not checked"
    if ok and dst and dir and type(cur) == "string" and cur ~= "" and cur ~= TEMP_SLOT
        and file_exists(dir .. cur .. "\\Slot.sav") then
        local a, b = file_print(dir .. cur .. "\\Level.sav"), file_print(dst .. "\\" .. cur .. "\\Level.sav")
        ok = a ~= nil and b ~= nil and a.size == b.size and a.h == b.h
        verified = string.format("slot '%s' Level.sav %s", cur, ok and "identical" or "MISSING or different")
    end
    log.info("[SAVE] backup %s: %s (robocopy exit %s, %s)", tostring(dst), ok and "ok" or "FAILED", tostring(code), verified)
    if ok then
        local okp, err = pcall(M.prune_backups)
        if not okp then log.err("[SAVE] backups: prune failed: %s", tostring(err)) end
    else
        log.warn("[SAVE] backups: old backups kept (this one did not succeed)")
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Report (console / status)
-- ---------------------------------------------------------------------------

function M.report(reply)
    reply = reply or function(s) log.info("%s", s) end
    local cur = ue.ems_current_slot()
    reply(string.format("[SAVE] role %s, current slot '%s' (on disk: %s), hooks %d/%d", role(), tostring(cur),
        tostring(slot_exists(cur)), hooks_done()))
    if M.last then reply("[SAVE] last save: " .. tostring(M.last.wall) .. " " .. M.last.line) else reply("[SAVE] no save since the mod started") end
    if M.last and M.last.world then reply("[SAVE] world in it: " .. M.last.world) end
    if M.last_load then
        reply(string.format("[SAVE] last load %s slot '%s': %s", tostring(M.last_load.wall), tostring(M.last_load.slot),
            M.last_load.verdict))
    end
    if rec then reply(string.format("[SAVE] save #%d in progress for %.1f s", rec.n, clock() - rec.t0)) end
    local r = role()
    if r == "host" or r == "standalone" then
        local st = autosave_state()
        reply("[SAVE] autosave: " .. autosave_str(st))
        local ws = world_state
        if ws.coop_on then
            local base = math.max(ws.last_save or ws.coop_base, ws.coop_base)
            reply(string.format("[SAVE] co-op autosave (the game's AutoSaveGame, run by the mod): next in %d s%s; %d run(s), %d saved",
                math.floor(base + COOP_AUTOSAVE_S - clock()), ws.coop_retry_at and " (retrying)" or "",
                M.stats.coop_autosaves, M.stats.coop_autosaves_ok))
        end
        local okg, g = pcall(host_guard, false)   -- count only
        if okg and g then
            reply(string.format("[SAVE] now: other players' characters %d (skip-save %d), controllers %d (skip-save %d); host character %s, host controller %s",
                g.chars, g.tagged, g.pcs, g.pcs_tagged, g.host_char, g.host_pc))
        end
        local okc, p = pcall(check_save_player)
        if okc and p then
            if p.ok == true then
                reply(string.format("[SAVE] Save_Player in memory = host's own (%s; inventory %s; host's character %s)",
                    stats_str(p.stats), inv_str(p.file_inv), inv_str(p.host_inv)))
            else
                reply("[SAVE] Save_Player in memory: " .. table.concat(p.notes, "; ")
                    .. " (between saves it may lag behind; the next save rewrites it)")
            end
        end
        local job = { i = 1, out = {}, ms = 0 }
        counts_step(job, #COUNT_CLASSES)
        reply(string.format("[SAVE] world now: %s [%.0f ms]", counts_str(job.out), job.ms))
        local list = list_backups()
        if list then
            reply(string.format("[SAVE] automatic backups: %d (keep %s), newest %s", #list, tostring(opt("backup_keep")),
                tostring(list[#list])))
        end
    elseif r == "client" then
        local pawn = ue.local_pawn()
        reply(string.format("[SAVE] client: own saves go to '%s' (now '%s'); own character skip-save: %s; slot to come back to: '%s'",
            TEMP_SLOT, tostring(cur), tostring(pawn and has_tag(pawn, SKIP_TAG)), tostring(remembered_slot())))
    end
    reply("[SAVE] " .. M.status_line())
end

function M.status_line()
    local s = M.stats
    local last = M.last and string.format("last #%d %s %s '%s' (%s)", M.last.n, M.last.wall, M.last.ok and "ok" or "FAILED",
        tostring(M.last.slot), M.last.trigger) or "no save yet"
    return string.format("savecheck: saves %d (ok %d, failed %d), client saves %d, loads %d; %s; guard: tagged at save %d, host untag %d, "
        .. "slot guard %d, client redirects %d, remote inventory writes %d, Save_Player mismatches %d, repairs %d, autosave starts %d, "
        .. "co-op autosaves %d (saved %d), slot restores %d, backups pruned %d",
        s.saves, s.saves_ok, s.saves_failed, s.client_saves, s.loads, last, s.tagged_at_save, s.host_untagged, s.slot_guard,
        s.client_slot_redirects, s.remote_inv_writes, s.player_mismatch, s.repairs, s.autosave_starts, s.coop_autosaves,
        s.coop_autosaves_ok, s.slot_restores, s.backups_pruned)
end

-- main.lua: savecheck.register_commands(add) with add(name, help, fn(params, reply))
function M.register_commands(add)
    add("sdcoop_savecheck", "save status: slot, autosave, who the host's save excludes, Save_Player check, world counts, backups",
        function(_, reply) M.report(reply) end)
end

-- ---------------------------------------------------------------------------
-- Tick / reset / install
-- ---------------------------------------------------------------------------

function M.tick()
    if not S then return end
    local now = clock()
    try_hooks(false)
    local r = role()
    if not started and (r == "standalone" or r == "host") then
        start_tries = start_tries + 1
        local ok, done = pcall(startup_slot_check)
        if not ok then log.err("[SAVE] startup slot check: %s", tostring(done)) end
        started = (ok and done == true) or start_tries >= 10
    end
    if r == "client" then
        if opt("client_save_guard") and not ue.in_main_menu() then client_tag_own("connected") end
    elseif r == "host" then
        local ok, err = pcall(autosave_watchdog, now)
        if not ok then log.err_throttled("savecheck.autosave", "[SAVE] autosave watchdog: %s", tostring(err)) end
    end
    if rec and now - rec.t0 > SAVE_TIMEOUT_S then
        rec.notes[#rec.notes + 1] = string.format("no end reported within %d s", SAVE_TIMEOUT_S)
        finish_save("timeout")
    end
    if counts_job then
        local done = counts_step(counts_job, 3)
        if done then
            local job = counts_job
            counts_job = nil
            finish_counts(job)
        end
    end
end

-- New world: drop what belonged to the old one (hooks stay).
function M.reset(why)
    if rec then
        log.warn("[SAVE] save #%d (slot '%s') still unfinished at a level change (%s)", rec.n, tostring(rec.slot), tostring(why))
        rec = nil
    end
    load_rec = nil
    counts_job = nil
    world_state = { autosave_at = -100, autosave_logged = false, in_game_since = nil }
end

local installed = false
function M.install(state)
    if installed then return end
    installed = true
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    if session and session.world_reset_hooks then
        session.world_reset_hooks.savecheck = function(why) M.reset(why) end
    end
    try_hooks(true)
    log.info("[SAVE] savecheck installed (guard=%s repair=%s client_guard=%s autosave_watchdog=%s counts=%s backup_keep=%s)",
        tostring(opt("save_guard")), tostring(opt("save_repair")), tostring(opt("client_save_guard")),
        tostring(opt("autosave_watchdog")), tostring(opt("savecheck_counts")), tostring(opt("backup_keep")))
end

return M
