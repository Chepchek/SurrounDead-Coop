-- SDCoop: other players' characters saved with the host's world.
--
-- Until now a client's character lived only as long as the connection: every
-- join the host spawned a new character with the starting kit, and
-- sdc_progress reset the client's level / skills. Here the HOST keeps one
-- record per player and per world save slot and gives it back on the next
-- join. Findings and the full design: work\audit\client_persistence.md.
--
-- What the game itself saves for the (single) player, decompiled (work\re):
--   * inventory: BP_PlayerCharacter.ActorPreSave @148690 sends the action bar
--     UIDs (InGameUI.GetActionbarUIDs = the 3 consumable slots) to
--     BP_JigMultiplayer.SERVER_RequestSaveGame -> SaveJigComponent copies the
--     component's MainJigContainers (every container, sub-containers of
--     backpacks / weapons / magazines included, flat; each item with its UID,
--     ItemInfo {data asset, count, durability, stats, custom data}, slot and
--     sub-container UIDs), MainContainersIDs and InventoryWeight into the EMS
--     custom save Save_Player. Load: Event_LoadPlayer (owning machine)
--     ClearJSIItems + InGameUI.ClearContainers + SERVER_RequestDataFromSave ->
--     server: InitNoStartingItems, LoadJigComponent (the three arrays back),
--     OnLoadSavedDataRequested (BP_JigHelperComp.OnLoadDataRequested destroys
--     the equipped actors), CLIENT_ContainerDataResponse(main UIDs, items,
--     action bar UIDs) to the owner (UI + hot bar) and
--     HandleMainPlayerRequestedData (JigMP_OnMainContainerItemAdded spawns
--     the worn / holstered item actors).
--     The Jig plugin has the same load with the data as parameters:
--     BP_JigComponent.SERVER_LoadSaveDataFromClientSide(MainJigContainers,
--     MainContainersIDs, InventoryWeight, ActionbarUIDs) (@15473 -> 15366,
--     57) - that is what the restore here calls on the host's copy of the
--     player's character. Its own per-player save object
--     BP_JigMPComponentSave_C (JigContainers, MainUIDs, Weights,
--     ActionbarUIDs, PlayerLocation, MapName : SaveGame) is the file format:
--     the arrays are copied into one (UE4SS deep-copies a TArray assigned
--     from another TArray) and written with GameplayStatics.SaveGameToSlot,
--     the engine's own SaveGame serialization (every struct member, data
--     assets as paths). Item actor references (PickupRef) are cleared in the
--     copy: they point into the running world.
--   * level / skills / skill points: components of BP_PlayerController
--     (ComponentsToSave = Levelling, PassiveSkills, TechTree; SaveGame
--     properties, see sdc_progress.FIELDS), the journal on the controller
--     (Save_Player via its ActorPreSave @3716), unlocked skills in
--     <slot>_SkillTree.sav. None of it replicates: the CLIENT's copy is the
--     truth (its HUD shows it). The client reports it (PSPROG) and applies a
--     saved record itself (sdc_progress / sdc_skilltree).
--   * health, hunger, thirst, stamina, radiation, bleeding / heavy bleeding /
--     broken bone / infection (+ time left), Deathbringer used: SaveGame
--     properties of the character's components, all live on the host.
--   * position / rotation (Save_Player.PlayerLocation, PlayerRotation), the
--     bed / sleeping bag respawn point (controller RespawnPointEnabled /
--     RespawnLoc: on the host's copy, sdc_respawn bed_for_client).
--
-- Storage (host): next to the world's slot, the way the game keeps
-- <slot>_SkillTree.sav and <slot>_Quests.sav beside the EMS slot folder:
--   SaveGames\<slot>_SDCoop.json          every player's record of this slot
--   SaveGames\<slot>_SDCoop_<key>.sav     that player's inventory (Jig save)
-- each with a previous copy (.json.bak / _<key>_bak.sav), written as a temp
-- file and renamed. <key> = s<SteamID64>, or g<id> (an id the client makes
-- once and keeps in its config) without Steam.
--
-- When (host): the game's save (BP_PlayerController.SaveGameToSlot: quick
-- save, sleep, auto save, save menu, pause menu - all of them go through it;
-- also EMSAsyncSaveGame.AsyncSaveActors inside it, one write for both; a
-- save to another slot takes the records of players who are not here
-- along), a player's inventory change (10 s), a level / skill / kill change
-- (15 s), death, leaving, every persist_period seconds, and before a world
-- change. The game destroys the character of a player who disconnects
-- before any mod code runs, so leaving writes what was gathered while the
-- player was here (5 s / 10 s old at most). sdc_session's throwaway slot
-- SDCoop_ClientTemp never holds records (sdc_savecheck keeps the host's
-- saves out of it).
-- Those records are LIVE; what the host's SAVES hold of them is a second
-- copy, committed at each save and put back when a save is loaded
-- (persist_follow_host_save, section "Host: the clients' records follow the
-- host's saves" below): <slot>_SDCoop_commit.json + _<key>_c<gen>.sav /
-- _<key>_q<gen>.sav (inventory / quest save of that commit).
-- Restore (host): the first character of a returning player waits for the
-- player's id (sdc_players.persist_gate), spawns at the saved spot
-- (join_point) without the starting kit (starting_items); the host's copy of
-- the controller gets the saved progression and respawn point, the client is
-- sent the record (PSSET) and applies it, and once its HUD is up (PSRDY) the
-- host restores health & co. and the inventory. No record: a new character,
-- as before (PSFRESH). Weapon modules: the inventory load gives the host's
-- copy everything (attachments are items in the weapon's sub-container; the
-- game's OnMainAdded fits each spawned weapon). The weapons reach the client
-- already fitted, which is the one case the game's client code misses: the
-- modules sit on the weapon but sight / suppressor / muzzle brake do nothing
-- there until a module is re-installed. sdc_gearfx refits such weapons when
-- they begin play on the client; PSDONE adds two passes (3 s / 10 s) for
-- weapons that came before that hook was in.
--
-- Map discoveries (record field `map` = { [POI actor name] = "POI name" }):
-- every named place on the map is a level-placed BP_POIManager_C
-- (work\re\pseudo\BP_POIManager.txt). Not replicated (no bReplicates, no
-- CPF_Net): each machine runs its own copy. 10 s after BeginPlay an
-- unexplored one starts a looping "DistanceCheck" timer (2-5 s): player 0's
-- character closer than ExploredCheckRadius (40 m) -> Explored? = true
-- (CPF_SaveGame; the class implements EMSActorSaveInterface, so it is in
-- the world's Level.sav), Marker.POIExplored (W_POIMarker.EventExplored:
-- the marker, Hidden by default, becomes visible), 250 / 50 XP and the HUD
-- toast (HUD_Game.DiscoverPOI). A load gives it back through ActorLoaded
-- (@10238 -> 8332: POIExplored + K2_ClearTimer "DistanceCheck"). So a
-- client discovers places on ITS copies (its own player 0), and nothing of
-- it is saved: its own save goes to the throwaway slot, the host's copies
-- only know the host. The client reports its explored POIs (PSMAP), the
-- host keeps them in the record (only ever added to) and sends them back on
-- the next join (PSMAPSET); once the record is applied the client sets
-- Explored?, clears the distance check and runs ActorLoaded, as a load does.
--
-- Shared map discoveries (map_shared, see SHARE below): every player SEES
-- every place any player explored, without it being explored for them. The
-- marker is shown the game's way, by its own POIExplored handler
-- W_POIMarker.EventExplored (@249 SetVisibility(4), @265 the WIDGET's
-- Explored?; the only function bound to that delegate, @106-129); the
-- manager's Explored? stays false and its looping DistanceCheck keeps
-- running, so reaching the place still gives the game's XP and toast once.
-- Host: union of its own explored places, every record's `map` and the live
-- PSMAP reports; each client gets what it lacks (MAPSHARE: the whole list
-- after its verdict, then additions, batched per pass); the host's own
-- copies show the clients' places the same way (Level.sav never changes).
-- A place shown this way is drawn dimmed ("seen by another player",
-- sdc_poimarks) until this player gets there: the game's own discovery then
-- gives the full marker back. sdc_poimarks also keeps the host's managers'
-- markers on the host's own map (a remote player's respawn moved them).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local poimarks = require("sdc_poimarks")

local M = {
    FORMAT = 1,
    stats = { records_written = 0, blobs_written = 0, blobs_copied = 0, docs_written = 0, restores = 0, fresh = 0,
              inv_restored = 0, inv_fallback = 0, write_errors = 0, load_fallbacks = 0, host_saves = 0,
              leaves = 0, periodic = 0, prog_reports = 0, deleted_slots = 0,
              map_reports = 0, map_new = 0, map_sent = 0, map_restored = 0,
              share_sent = 0, share_got = 0, share_shown = 0, share_found = 0,
              commits = 0, commit_files = 0, commits_dropped = 0, migrations = 0, resets = 0, reset_files = 0 },
}

local S = nil   -- sdc_session.state

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local NOSLOT = "SDCoop_NoSlot"     -- a world that was never saved (new game): this session only
local TAG = "_SDCoop"
local JIG_SAVE_CLASS = "/Game/JigSInventory/Jigsaw/Components/Save/BP_JigMPComponentSave.BP_JigMPComponentSave_C"
local PC_FN = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:"
local SAVE_FN = PC_FN .. "SaveGameToSlot"
local SAVED_FN = PC_FN .. "OnCompleted_9CDBA9034C950D925C1539BE037C23EF"
local SAVE_FAILED_FN = PC_FN .. "OnFailed_9CDBA9034C950D925C1539BE037C23EF"
local DELETE_FN = "/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot"
local EMS_SAVE_FN = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
local TEMP_SLOT = "SDCoop_ClientTemp"   -- sdc_session's throwaway slot: never a world's records
local PUSH_LIB = "/Script/Engine.Default__NetPushModelHelpers"

-- Jig struct members (BP structs: GUID-suffixed names, as in sdc_items)
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_PICKUP = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657"
-- Struct_KeepInventory (BP_PlayerController.KeepInventory, Difficulty.KeepInventory)
local K_CONT = "MainJigContainers_15_DA110C204443D2AB30E541A1550FC694"
local K_UIDS = "MainUIDs_16_CFDC4BBB4BB8861F7FAD1A9EED2D8711"
local K_WEIGHTS = "Weights_10_948F84EE41B20820DD51D98A692CD033"

-- character vitals: { component property, field, replicated index for
-- NetPushModelHelpers (the index the game's own code marks), UI RPC }
local VITALS = {
    { "MedicalComponent", "Health", nil, "Client_UpdateHealthUI" },
    { "Hunger&ThirstComponent", "CurrentHunger", 2, "Client_UpdateHungerUI" },
    { "Hunger&ThirstComponent", "CurrentThirst", 4, "Client_UpdateThirstUI" },
    { "StaminaComponent", "CurrentStamina", 2, "Client_UpdateStaminaUI" },
    { "RadiationComponent", "CurrentRadiation", 2, "Client_UpdateRadiationUI" },
}
-- MedicalComponent states; its ComponentLoaded (the EMS load event) re-runs
-- their OnRep_* (timers, effects, replication) the way a load does
local MEDICAL = { "Bleed?", "HeavyBleed?", "BrokenBone?", "Infection?", "InfectionTimeLeft" }

local PID_WAIT_S = 25       -- host: a first character waits this long for the player's id (a Steam join loads slower; later: moved to its saved spot)
local LIGHT_S = 5           -- host: position / vitals / respawn point gathered this often
local INV_CHECK_S = 10      -- host: inventory change check (the file is written on a change)
local READY_WAIT_S = 30     -- host: restore without the client's PSRDY after this long
local FALL_CHECK_S = 6      -- host: a character put at its saved spot is checked this much later
local PROG_WRITE_S = 15     -- host: a level / skill / kill change is written at most this often
local CLIENT_PID_EVERY = 4
local CLIENT_PID_MAX = 15
local CLIENT_PROG_CHECK = 3
local CLIENT_PROG_MINOR_S = 20
local CLIENT_PROG_RESEND_S = 120
local CLIENT_READY_EVERY = 5
local CLIENT_MAP_CHECK = 5  -- client: own explored POIs looked at this often (one FindAllOf)
local MAP_MISS_TRIES = 3    -- client: passes a saved POI that is not in this world is looked for
local MAP_CHUNK = 40        -- POIs per PSMAP / PSMAPSET message
local REFIT_AFTER_MS = { 3000, 10000 }   -- client: restored weapons' modules checked (sdc_gearfx.refit_own)

-- map discoveries (see the header)
local POI_CLASS = "BP_POIManager_C"
local POI_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"   -- Struct_POI.Name (FString)

local TEXT = {
    persist_restored_client = { "Your character in this world was restored (level %s).",
                                "Ваш персонаж в этом мире восстановлен (уровень %s)." },
    persist_inv_client      = { "Inventory restored (%s items).", "Инвентарь восстановлен (предметов: %s)." },
    persist_fresh_client    = { "No saved character in this world yet: you start a new one.",
                                "В этом мире у вас ещё нет сохранённого персонажа — начинаете заново." },
    persist_restored_host   = { "%s: character restored from the world save.",
                                "%s: персонаж восстановлен из сохранения мира." },
    persist_inv_failed      = { "%s: the saved inventory could not be loaded (see UE4SS.log).",
                                "%s: не удалось загрузить сохранённый инвентарь (подробности в UE4SS.log)." },
    persist_map_client      = { "Discovered map locations restored: %s.",
                                "Открытые места на карте восстановлены: %s." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end

local function enabled() return cfg.get("persist_clients") ~= false end

local function period_s()
    local n = tonumber(cfg.get("persist_period"))
    if n == nil then return 120 end
    return n
end

local function clock() return os.time() end

-- ---------------------------------------------------------------------------
-- JSON (records are written for people too: indented, keys sorted)
-- ---------------------------------------------------------------------------

local JSON_ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function json_str(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return JSON_ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function json_encode(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.type(v) == "integer" then return tostring(v) end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.10g", v)
    end
    if t == "string" then return json_str(v) end
    if t ~= "table" then return "null" end
    local arr, n = is_array(v)
    local inner = indent .. "  "
    if arr then
        if n == 0 then return "[]" end
        local simple = true
        for i = 1, n do if type(v[i]) == "table" then simple = false break end end
        local parts = {}
        for i = 1, n do parts[i] = json_encode(v[i], inner) end
        if simple then return "[" .. table.concat(parts, ", ") .. "]" end
        return "[\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return "{}" end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        parts[#parts + 1] = json_str(k) .. ": " .. json_encode(val, inner)
    end
    return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. "\n" .. indent .. "}"
end
M.json_encode = json_encode

local function json_decode(s)
    local pos = 1
    local function err(what) error(string.format("json: %s at %d", what, pos), 0) end
    local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == "" then err("unterminated string") end
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[e] then
                    out[#out + 1] = map[e]
                    pos = pos + 2
                elseif e == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    local cp = tonumber(hex, 16)
                    if not cp then err("bad \\u") end
                    out[#out + 1] = utf8.char(cp)
                    pos = pos + 6
                else
                    err("bad escape")
                end
            else
                local j = s:find('["\\]', pos)
                if not j then err("unterminated string") end
                out[#out + 1] = s:sub(pos, j - 1)
                pos = j
            end
        end
        return table.concat(out)
    end
    value = function()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local t = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then err("key expected") end
                local k = str()
                ws()
                if s:sub(pos, pos) ~= ":" then err("':' expected") end
                pos = pos + 1
                t[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                if d ~= "," then err("',' or '}' expected") end
            end
        elseif c == "[" then
            pos = pos + 1
            local t = {}
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            while true do
                t[#t + 1] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return t end
                if d ~= "," then err("',' or ']' expected") end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif s:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif s:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" or num == "-" then err("value expected") end
            pos = pos + #num
            local n = tonumber(num)
            if n == nil then err("bad number") end
            return n
        end
    end
    local ok, res = pcall(function()
        local v = value()
        ws()
        if pos <= #s then err("trailing data") end
        return v
    end)
    if ok then return res end
    return nil, res
end
M.json_decode = json_decode

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

local dir_cache = nil
local function savegames_dir()
    if dir_cache then return dir_cache end
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return nil end
    dir_cache = base:gsub("\\", "/") .. "/SurrounDead/Saved/SaveGames/"
    return dir_cache
end
M.savegames_dir = savegames_dir

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

local function write_file(p, data)
    local f, err = io.open(p, "wb")
    if not f then return false, tostring(err) end
    local ok, werr = f:write(data)
    local cok, cerr = f:close()
    if not ok then return false, tostring(werr) end
    if not cok then return false, tostring(cerr) end
    return true
end

-- tmp -> main, the old main kept as bak. Windows: rename does not replace.
local function rotate(main, bak, tmp)
    if file_exists(main) then
        os.remove(bak)
        local ok, err = os.rename(main, bak)
        if not ok then return false, "keeping the previous copy: " .. tostring(err) end
    end
    local ok, err = os.rename(tmp, main)
    if not ok then return false, "renaming the new file: " .. tostring(err) end
    return true
end

-- A slot name as a file name part: the game's own names (QuickSave..,
-- AutoSave..) stay as they are; anything else (a typed name, Cyrillic) gets
-- the unsafe characters replaced and a hash of the full name.
local function safe_slot(slot)
    slot = tostring(slot or "")
    if slot:match("^[%w_%-]+$") then return slot end
    local h = 5381
    for i = 1, #slot do h = (h * 33 + slot:byte(i)) % 4294967296 end
    return (slot:gsub("[^%w_%-]", "_")) .. string.format("_%08x", h)
end
M.safe_slot = safe_slot

local function doc_paths(slot)
    local dir = savegames_dir()
    if not dir then return nil end
    local base = dir .. safe_slot(slot) .. TAG
    return base .. ".json", base .. ".json.bak", base .. ".json.tmp"
end

-- the inventory file of one player in one slot, as an engine save slot name
local function blob_slot(slot, key, suffix)
    return safe_slot(slot) .. TAG .. "_" .. key .. (suffix or "")
end
M.blob_slot = blob_slot

local function blob_path(name)
    local dir = savegames_dir()
    return dir and (dir .. name .. ".sav") or nil
end

-- ---------------------------------------------------------------------------
-- Slot documents (<slot>_SDCoop.json)
-- ---------------------------------------------------------------------------

local docs = {}   -- [slot] = document (this session's view of the file)

local function new_doc(slot)
    return { format = M.FORMAT, slot = slot, players = {} }
end

local function valid_doc(d)
    return type(d) == "table" and type(d.players) == "table"
end

local function load_doc(slot, fresh)
    if not fresh and docs[slot] then return docs[slot] end
    local main, bak = doc_paths(slot)
    local doc, from = nil, nil
    if main then
        for _, p in ipairs({ { main, "main" }, { bak, "backup" } }) do
            local data = read_file(p[1])
            if data then
                local d, derr = json_decode(data)
                if valid_doc(d) then
                    doc, from = d, p[2]
                    break
                end
                log.warn("persist: %s is damaged (%s)%s", p[1], tostring(derr or "no player table"),
                    p[2] == "main" and ", trying the previous copy" or "")
                M.stats.load_fallbacks = M.stats.load_fallbacks + 1
            end
        end
    end
    doc = doc or new_doc(slot)
    if from == "backup" then log.warn("persist: records of slot %s were taken from the previous copy (.bak)", slot) end
    docs[slot] = doc
    return doc
end
M.load_doc = load_doc

local function save_doc(slot, doc, why)
    local main, bak, tmp = doc_paths(slot)
    docs[slot] = doc
    if not main then
        log.err_throttled("persist-nodir", "persist: LOCALAPPDATA is not set: client records are kept in memory only")
        return false
    end
    doc.format, doc.slot = M.FORMAT, slot
    doc.updated = clock()
    doc.updated_at = os.date("%Y-%m-%d %H:%M:%S")
    local session = package.loaded["sdc_session"]
    doc.mod = session and session.VERSION or nil
    doc.note = "SDCoop: characters of the other players in this world (host). Inventory: " .. safe_slot(slot) .. TAG .. "_<key>.sav"
    local ok, err = write_file(tmp, json_encode(doc) .. "\n")
    if ok then ok, err = rotate(main, bak, tmp) end
    if not ok then
        M.stats.write_errors = M.stats.write_errors + 1
        log.err("persist: writing %s failed (%s): %s", main, tostring(why), tostring(err))
        return false
    end
    M.stats.docs_written = M.stats.docs_written + 1
    return true
end

-- ---------------------------------------------------------------------------
-- Engine helpers
-- ---------------------------------------------------------------------------

local function guid_str(g)
    if g == nil then return "0:0:0:0" end
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

local function guid_tbl(s)
    local a, b, c, d = tostring(s or ""):match("^(-?%d+):(-?%d+):(-?%d+):(-?%d+)$")
    if not a then return { A = 0, B = 0, C = 0, D = 0 } end
    return { A = math.tointeger(tonumber(a)) or 0, B = math.tointeger(tonumber(b)) or 0,
             C = math.tointeger(tonumber(c)) or 0, D = math.tointeger(tonumber(d)) or 0 }
end

local function num(v, digits)
    if type(v) ~= "number" or v ~= v then return nil end
    if digits then
        local m = 10 ^ digits
        return math.floor(v * m + 0.5) / m
    end
    return v
end

local jig_class_obj = nil
local function jig_class()
    if ue.valid(jig_class_obj) then return jig_class_obj end
    jig_class_obj = ue.find_object(JIG_SAVE_CLASS)
    if not jig_class_obj and S and S.role == "host" then
        -- the host only: BP_JigComponent references it, so it is normally in memory
        local ok, o = ue.load_asset(JIG_SAVE_CLASS, "persist")
        if ok and ue.valid(o) then jig_class_obj = o end
    end
    return jig_class_obj
end

local function arr_num(a)
    if a == nil then return 0 end
    local ok, n = pcall(function() return a:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    return 0
end

-- Containers and items of a MainJigContainers-like array; sig is a stable
-- text of every item (uid, count, durability, slot, container) for change
-- detection; list (want_list) a readable copy for the record.
local function inv_walk(conts, want_list)
    local sig, list, nc, ni = {}, want_list and {} or nil, 0, 0
    local ok, err = pcall(function()
        conts:ForEach(function(_, c)
            local cont = c:get()
            nc = nc + 1
            local cu = guid_str(cont[F_CONT_UID])
            cont[F_ITEMS]:ForEach(function(_, it)
                local item = it:get()
                ni = ni + 1
                local info = item[F_INFO]
                local uid = guid_str(item[F_USID])
                local cnt = info[F_COUNT]
                local dur = ue.try(function() return info[F_DUR].X end) or 0
                local slot = ue.try(function() return item[F_SLOT] end) or -1
                sig[#sig + 1] = string.format("%s=%s/%.1f/%s@%s", uid, tostring(cnt), dur, tostring(slot), cu)
                if list then
                    local da = info[F_ITEMID]
                    list[#list + 1] = { uid = uid, id = ue.short(da), path = ue.path(da), n = cnt,
                                        dur = num(dur, 1), c = cu, s = slot }
                end
            end)
        end)
    end)
    if not ok then return nil, 0, 0, nil, tostring(err) end
    table.sort(sig)
    return table.concat(sig, ";"), nc, ni, list
end
M.inv_walk = inv_walk

local function clear_pickups(conts)
    local n = 0
    pcall(function()
        conts:ForEach(function(_, c)
            c:get()[F_ITEMS]:ForEach(function(_, it)
                local item = it:get()
                if ue.valid(item[F_PICKUP]) then
                    item[F_PICKUP] = nil
                    n = n + 1
                end
            end)
        end)
    end)
    return n
end

local function load_blob_raw(name)
    local gs = ue.gameplay_statics()
    if not gs then return nil, "no GameplayStatics" end
    local okx, exists = pcall(function() return gs:DoesSaveGameExist(name, 0) end)
    if okx and exists ~= true then return nil, "missing" end
    local ok, obj = pcall(function() return gs:LoadGameFromSlot(name, 0) end)
    if not ok then return nil, tostring(obj) end
    if not ue.valid(obj) then return nil, "unreadable" end
    if ue.class_name(obj) ~= "BP_JigMPComponentSave_C" then return nil, "not an inventory save (" .. ue.class_name(obj) .. ")" end
    return obj
end

-- The saved inventory of `key` in `slot`, checked against the record's
-- counts; the previous copy when the main file is missing / damaged.
local function load_blob(slot, key, expect)
    for _, suffix in ipairs({ "", "_bak" }) do
        local name = blob_slot(slot, key, suffix)
        local obj, err = load_blob_raw(name)
        if obj then
            local c = ue.prop(obj, "JigContainers")
            local _, nc, ni = inv_walk(c, false)
            if not expect or (nc == expect.containers and ni == expect.items) then
                if suffix ~= "" then
                    M.stats.load_fallbacks = M.stats.load_fallbacks + 1
                    log.warn("persist: inventory of %s in slot %s taken from the previous copy (%s)", key, slot, name)
                end
                return obj, name
            end
            log.warn("persist: %s holds %d container(s) / %d item(s), the record says %s / %s: not used",
                name, nc, ni, tostring(expect.containers), tostring(expect.items))
        elseif err ~= "missing" or suffix == "" then
            log.warn("persist: %s: %s", name, tostring(err))
        end
    end
    return nil
end
M.load_blob = load_blob

-- Writes an inventory (src = { conts, uids, weights } arrays) as the
-- player's file in `slot`: temp slot, read back and counted, then renamed.
local function write_blob(slot, key, src, hotbar, loc)
    local gs, cls = ue.gameplay_statics(), jig_class()
    if not gs or not cls then return nil, "no GameplayStatics / BP_JigMPComponentSave class" end
    local ok, obj = pcall(function() return gs:CreateSaveGameObject(cls) end)
    if not ok or not ue.valid(obj) then return nil, "CreateSaveGameObject: " .. tostring(obj) end
    local set_ok = ue.set_prop(obj, "JigContainers", src.conts)
        and ue.set_prop(obj, "MainUIDs", src.uids)
        and ue.set_prop(obj, "Weights", src.weights)
    if not set_ok then return nil, "copying the inventory arrays failed" end
    local hot = {}
    for i, g in ipairs(hotbar or {}) do hot[i] = guid_tbl(g) end
    ue.set_prop(obj, "ActionbarUIDs", hot)
    if loc then ue.set_prop(obj, "PlayerLocation", { X = loc.x or 0, Y = loc.y or 0, Z = loc.z or 0 }) end
    ue.set_prop(obj, "MapName", "SDCoop " .. key)
    local conts = ue.prop(obj, "JigContainers")
    local cleared = clear_pickups(conts)
    local sig, nc, ni, list = inv_walk(conts, true)
    if not sig then return nil, "reading the copy failed" end
    local name, tmp = blob_slot(slot, key), blob_slot(slot, key, "_tmp")
    local okw, saved = pcall(function() return gs:SaveGameToSlot(obj, tmp, 0) end)
    if not okw or saved ~= true then return nil, "SaveGameToSlot(" .. tmp .. "): " .. tostring(saved) end
    local back, berr = load_blob_raw(tmp)
    if not back then return nil, "reading " .. tmp .. " back: " .. tostring(berr) end
    local _, bc, bi = inv_walk(ue.prop(back, "JigContainers"), false)
    if bc ~= nc or bi ~= ni then
        return nil, string.format("%s read back %d/%d instead of %d/%d", tmp, bc, bi, nc, ni)
    end
    local main_p, bak_p, tmp_p = blob_path(name), blob_path(blob_slot(slot, key, "_bak")), blob_path(tmp)
    if main_p then
        local rok, rerr = rotate(main_p, bak_p, tmp_p)
        if not rok then return nil, rerr end
    else
        -- no LOCALAPPDATA: the engine writes the main file directly
        pcall(function() gs:SaveGameToSlot(obj, name, 0) end)
    end
    M.stats.blobs_written = M.stats.blobs_written + 1
    return { file = name, slot = slot, containers = nc, items = ni, list = list, cleared = cleared }, sig
end

-- The inventory file of (from_slot, from_key) as the one of (to_slot,
-- to_key) (another slot: a save to a new slot; another key: the same player
-- under another id). A byte copy of the engine's file.
local function copy_blob(from_slot, to_slot, key, to_key)
    to_key = to_key or key
    if from_slot == to_slot and key == to_key then return true end
    if not savegames_dir() then return false, "LOCALAPPDATA is not set" end
    local src = blob_path(blob_slot(from_slot, key))
    local data = read_file(src)
    if not data then
        src = blob_path(blob_slot(from_slot, key, "_bak"))
        data = read_file(src)
    end
    if not data then return false, "no inventory file of " .. key .. " in slot " .. from_slot end
    local tmp = blob_path(blob_slot(to_slot, to_key, "_tmp"))
    local ok, err = write_file(tmp, data)
    if ok then
        ok, err = rotate(blob_path(blob_slot(to_slot, to_key)), blob_path(blob_slot(to_slot, to_key, "_bak")), tmp)
    end
    if ok then M.stats.blobs_copied = M.stats.blobs_copied + 1 end
    return ok, err
end

local function delete_blobs(slot, key)
    for _, s in ipairs({ "", "_bak", "_tmp" }) do
        local p = blob_path(blob_slot(slot, key, s))
        if p then os.remove(p) end
    end
end

local push_lib = nil
local function mark_dirty(obj, index, name)
    if not index then return end
    push_lib = ue.valid(push_lib) and push_lib or ue.find_object(PUSH_LIB)
    if not push_lib then return end
    pcall(function() push_lib:MarkPropertyDirtyFromRepIndex(obj, index, FName(name)) end)
end

local function keep_inventory_on()
    local k = ue.ksl()
    local ok, v = pcall(function() return k:GetConsoleVariableBoolValue("Difficulty.KeepInventory") end)
    return ok and v == true
end

local function read_transform(tf)
    if tf == nil then return nil end
    local ok, v = pcall(function()
        local t, q = tf.Translation, tf.Rotation
        return { t = { x = t.X, y = t.Y, z = t.Z }, q = { x = q.X, y = q.Y, z = q.Z, w = q.W } }
    end)
    if ok and type(v) == "table" and type(v.t.x) == "number" and type(v.q.w) == "number" then return v end
    return nil
end

local function yaw_of_quat(q)
    if not q then return 0 end
    return math.deg(2 * math.atan(q.z or 0, q.w or 1))
end

-- ---------------------------------------------------------------------------
-- Map discoveries: { [POI actor name] = "POI name" } (record field `map`)
-- ---------------------------------------------------------------------------

local function map_on() return cfg.get("persist_map") ~= false end

-- a POI's name as kept / sent: no message or list separators, short
local function map_clean(s)
    s = tostring(s or ""):gsub("[%c;=|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 60 then s = s:sub(1, 60) end
    return s
end

-- level actor names ("BP_POIManager_C_12"); never a class default object
local function map_id_ok(id)
    return type(id) == "string" and #id > 0 and #id <= 96 and id:match("^[%w_%-%.]+$") ~= nil
        and id:find("^Default__") == nil
end

local function map_copy(m)
    local out = {}
    if type(m) ~= "table" then return out end
    for id, name in pairs(m) do
        if map_id_ok(id) then out[id] = map_clean(name) end
    end
    return out
end

local function map_count(m)
    local n = 0
    if type(m) == "table" then for _ in pairs(m) do n = n + 1 end end
    return n
end

-- "actor=name;actor=name" pieces of at most MAP_CHUNK entries (sorted)
local function map_pack(m)
    local ids = {}
    for id in pairs(m or {}) do if map_id_ok(id) then ids[#ids + 1] = id end end
    table.sort(ids)
    local out, cur = {}, {}
    for _, id in ipairs(ids) do
        cur[#cur + 1] = id .. "=" .. map_clean(m[id])
        if #cur >= MAP_CHUNK then
            out[#out + 1] = table.concat(cur, ";")
            cur = {}
        end
    end
    if #cur > 0 then out[#out + 1] = table.concat(cur, ";") end
    return out
end

local function map_unpack(s, into)
    into = into or {}
    for part in tostring(s or ""):gmatch("[^;]+") do
        local id, name = part:match("^([^=]+)=?(.*)$")
        if id and map_id_ok(id) then into[id] = map_clean(name) end
    end
    return into
end

-- "Pinewood, Gas Station, ..." of `ids` (their names, else the actor names)
local function map_names(m, ids, cap)
    local names = {}
    for _, id in ipairs(ids) do
        local n = type(m) == "table" and m[id] or nil
        names[#names + 1] = (type(n) == "string" and n ~= "") and n or id
    end
    table.sort(names)
    cap = cap or 40
    if #names <= cap then return table.concat(names, ", ") end
    local more = #names - cap
    for i = #names, cap + 1, -1 do names[i] = nil end
    return table.concat(names, ", ") .. string.format(", ... (+%d)", more)
end

-- This machine's POI managers (level actors, one FindAllOf; used only in
-- the calling pass, never kept): { [actor name] = actor }.
local function own_pois()
    local out = {}
    for _, a in ipairs(ue.find_all(POI_CLASS)) do
        if ue.valid(a) then
            local id = ue.short(a)
            if map_id_ok(id) then out[id] = a end
        end
    end
    return out
end

local function poi_name(a)
    local s = ue.prop(a, "POI")
    if s == nil then return "" end
    return map_clean(ue.str(ue.try(function() return s[POI_NAME] end)))
end

-- ---------------------------------------------------------------------------
-- Shared map discoveries (map_shared): what every machine does with places
-- someone else explored. The host part (union, MAPSHARE) is under "Host:
-- shared map discoveries", the client part next to client_map. One table:
-- this file is near Lua's 200-locals limit, and fields resolve at call time.
--
-- Pseudocode (work\re\pseudo): the marker of a place is made by the manager
-- right after BeginPlay (@9684 -> 3479-4552: BPC_MinimapSystem.Add POI Marker
-- -> MapWidget.AddPOICreatedMarker, which copies the MANAGER's Explored?
-- into the new W_POIMarker; the widget is Hidden by default) and again on
-- RespawnMarker (@9879 -> 9824 Delay 2 -> 5360 -> 3548: a new, hidden widget
-- after a respawn or sdc_players' late client minimap). Shown = the marker's
-- POIExplored broadcast; its only listener is the widget's own EventExplored
-- (W_POIMarker @106-129), whose whole body is @249 SetVisibility(4)
-- (SelfHitTestInvisible) and @265 self.Explored? = true - the widget's own
-- flag, read by nothing else. So calling Marker:EventExplored() shows the
-- place and touches neither the manager's Explored? (the Level.sav flag)
-- nor its "DistanceCheck" timer (set @3338-3413 because Explored? was false
-- 10 s after BeginPlay; cleared only by DistanceCheck @242 and the load path
-- @8393). The real discovery later: DistanceCheck @242 K2_ClearTimer, @268
-- Explored? = true, @279 the same marker event again (stays visible), @503
-- AddXP(250 / 50), @604 HUD.DiscoverPOI - once, the timer is gone after it.
-- A rebuilt marker is hidden again: every pass looks at the widget's flag.
-- ---------------------------------------------------------------------------

local SHARE = {
    CHECK_S = 5,       -- host pass (one FindAllOf of the POI managers), as CLIENT_MAP_CHECK
    DUE_S = 1,         -- a pass this soon after a new place came in (PSMAP / MAPSHARE)
    LOG_FIRST = 5,     -- applications logged in detail per machine and join (then counted only)
}

function SHARE.on() return cfg.get("map_shared") ~= false end

-- The manager of `id` among `pois`; a name a game update changed: the one
-- with the same place name, if only one has it (`cache` is per pass).
function SHARE.find(pois, id, name, cache)
    local a = pois[id]
    if a or name == nil or name == "" then return a end
    if not cache.by_name then
        cache.by_name = {}
        for _, pa in pairs(pois) do
            local pn = poi_name(pa)
            if pn ~= "" then cache.by_name[pn] = (cache.by_name[pn] == nil) and pa or false end
        end
    end
    return cache.by_name[name] or nil
end

-- One place someone else explored, on this machine's manager `a`:
--   "own"   explored here (the manager's Explored?): nothing to show
--   "wait"  no marker widget yet (minimap not built): next pass
--   "had"   the marker shows already
--   "shown" shown now (W_POIMarker.EventExplored, see above)
--   "fail"  the call did not take
-- Never sets the manager's Explored? and never clears its distance check.
-- A shown marker is dimmed (sdc_poimarks: "seen by another player"; one
-- dimmed before costs no engine call).
function SHARE.mark(a)
    if ue.prop(a, "Explored?") == true then return "own" end
    local m = ue.prop(a, "Marker")
    if not ue.valid(m) then return "wait" end
    if ue.prop(m, "Explored?") == true then
        poimarks.dim(m)
        return "had"
    end
    pcall(function() m:EventExplored() end)
    if ue.prop(m, "Explored?") == true then
        poimarks.dim(m, true)
        return "shown"
    end
    return "fail"
end

-- Shows the places of `want` ({ [id] = name }) except the ids in `skip`
-- (this player's own). `miss` counts passes a place was not in this world
-- (given up after MAP_MISS_TRIES).
function SHARE.apply(pois, want, skip, miss)
    local cache = {}
    local r = { shown = {}, own = {}, gone = {}, wait = 0, fail = 0 }
    for id, name in pairs(want) do
        if not (skip and skip[id]) and (miss[id] or 0) < MAP_MISS_TRIES then
            local a = SHARE.find(pois, id, name, cache)
            if a then
                miss[id] = nil
                local s = SHARE.mark(a)
                if s == "shown" then r.shown[#r.shown + 1] = id
                elseif s == "own" then r.own[#r.own + 1] = id
                elseif s == "wait" then r.wait = r.wait + 1
                elseif s == "fail" then r.fail = r.fail + 1 end
            else
                miss[id] = (miss[id] or 0) + 1
                if miss[id] >= MAP_MISS_TRIES then r.gone[#r.gone + 1] = id end
            end
        end
    end
    return r
end

-- The log of an apply pass: the first few in detail, then counted only.
-- `st` keeps the counters (the host's share state / the client's C).
function SHARE.note(st, whose, r, names)
    st.shown_ids = st.shown_ids or {}
    local fresh, again = {}, 0
    for _, id in ipairs(r.shown) do
        if st.shown_ids[id] then again = again + 1 else st.shown_ids[id] = true fresh[#fresh + 1] = id end
    end
    M.stats.share_shown = M.stats.share_shown + #r.shown
    if #r.shown == 0 and #r.gone == 0 and r.fail == 0 then return end
    st.share_logs = (st.share_logs or 0) + 1
    if st.share_logs > SHARE.LOG_FIRST then return end
    local ids = {}
    for _, id in ipairs(r.shown) do ids[#ids + 1] = id end
    log.info("persist: map share: %d place(s) %s explored shown on this map (%d first time, %d again after a marker"
        .. " rebuild; dimmed: seen by another player; Explored? stays false, the distance check runs: the discovery XP"
        .. " and the full marker are still due here)%s%s%s%s: %s",
        #r.shown, whose, #fresh, again,
        r.wait > 0 and string.format(", %d waiting for their marker", r.wait) or "",
        r.fail > 0 and string.format(", %d FAILED to show", r.fail) or "",
        #r.gone > 0 and string.format(", %d not in this world: %s", #r.gone, map_names(names, r.gone, 10)) or "",
        st.share_logs == SHARE.LOG_FIRST and " (further passes: status line only)" or "",
        #ids > 0 and map_names(names, ids, 12) or "-")
end

-- ---------------------------------------------------------------------------
-- Host: players
-- ---------------------------------------------------------------------------

local P = {}        -- [session record key (controller name)] = player state
local live = {}     -- [player key] = latest record of every player seen in this world
local hs = {        -- host state
    world_slot = nil, world_seen = false, last_period = 0, gen_n = 0, hooks = {}, last_save = nil,
    integration_logged = false,
}

local function players_mod() return package.loaded["sdc_players"] end
-- sdc_quests keeps a client's own quests (Narrative's own Save of its
-- component) as <slot>_SDQuests_<key>, next to the record
local function quests_mod() return package.loaded["sdc_quests"] end
local function quests_bind(pc, slot, key, load)
    local q = quests_mod()
    if q and q.persist_bind and pc then pcall(q.persist_bind, pc, slot, key, load) end
end
local function progress_mod() return package.loaded["sdc_progress"] end
local function skilltree_mod() return package.loaded["sdc_skilltree"] end

local function cur_world_slot()
    return hs.world_slot or NOSLOT
end

-- EMS's current slot as this world's slot ("" / the throwaway slot: none)
local function world_slot_of(slot)
    if not slot or slot == "" or slot == TEMP_SLOT then return NOSLOT end
    return slot
end

local function new_gen()
    hs.gen_n = hs.gen_n + 1
    return string.format("%x%02x", os.time() % 0x1000000, hs.gen_n % 256)
end

local function clean_sid(s)
    s = tostring(s or "")
    if #s == 17 and s:match("^7656119%d+$") then return s end
    return nil
end

local function clean_guid(s)
    s = tostring(s or ""):lower()
    if #s >= 16 and #s <= 40 and s:match("^%x+$") then return s end
    return nil
end

-- A record of this world for a player: this session's first, then the slot.
local function find_record(p)
    local rec = live[p.key]
    if rec then return rec, "this session" end
    local slot = cur_world_slot()
    if slot == NOSLOT then return nil, nil end
    local doc = load_doc(slot)
    rec = doc.players[p.key]
    if rec then return rec, "slot " .. slot end
    -- the same player under the other id (Steam now, not then, or back):
    -- the record and its inventory file move to the new key
    for k, r in pairs(doc.players) do
        if type(r) == "table" and k ~= p.key and ((p.sid and r.steam == p.sid) or (p.guid and r.guid == p.guid)) then
            local moved = {}
            for kk, vv in pairs(r) do moved[kk] = vv end
            if r.inv then
                local ok, err = copy_blob(r.inv.slot or slot, slot, k, p.key)
                if ok then
                    local inv = {}
                    for kk, vv in pairs(r.inv) do inv[kk] = vv end
                    inv.slot, inv.file = slot, blob_slot(slot, p.key)
                    moved.inv = inv
                else
                    moved.inv = nil
                    log.warn("persist: %s's inventory file under %s could not be taken over: %s", p.name, k, tostring(err))
                end
            end
            moved.key, moved.steam, moved.guid = p.key, p.sid or r.steam, p.guid or r.guid
            doc.players[k] = nil
            doc.players[p.key] = moved
            if moved.inv then delete_blobs(slot, k) end
            log.info("persist: %s's record found under %s: kept as %s from now on", p.name, k, p.key)
            return moved, "slot " .. slot .. " (as " .. k .. ")"
        end
    end
    return nil, nil
end

local function describe_rec(rec)
    if not rec then return "none" end
    local lvl = rec.prog and rec.prog.L and rec.prog.L.CurrentLevel
    local inv = rec.inv and string.format("%d item(s) in %d container(s)", rec.inv.items or 0, rec.inv.containers or 0) or "no inventory"
    local where = rec.pos and string.format("%.0f,%.0f,%.0f", rec.pos.x or 0, rec.pos.y or 0, rec.pos.z or 0) or "-"
    local nmap = map_count(rec.map)
    return string.format("level %s, %s, %s at %s%s, saved %s (%s)", tostring(lvl or "?"), inv,
        rec.alive == false and "dead" or "alive", where, nmap > 0 and string.format(", %d map location(s)", nmap) or "",
        tostring(rec.updated_at or "?"), tostring(rec.why or "?"))
end

-- the record as written, from what the host gathered for the player
local function make_record(p, why)
    local base = p.base or {}
    local s = p.snap or {}
    local alive = s.alive
    if alive == nil then alive = base.alive ~= false end
    local rec = {
        key = p.key, steam = p.sid, guid = p.guid, name = p.name,
        updated = clock(), updated_at = os.date("%Y-%m-%d %H:%M:%S"), why = why,
        alive = alive,
        pos = s.pos or base.pos,
        vitals = alive and (s.vitals or base.vitals) or nil,
        respawn = s.respawn or base.respawn,
        prog = p.prog or base.prog,
        tree = p.tree or base.tree,
        hotbar = p.hot or base.hotbar,
        inv = p.inv,
    }
    if p.inv == nil and not p.restored then rec.inv = base.inv end
    -- a dead player's items are in the loot box in the world (or, with the
    -- "keep inventory" difficulty, in the controller's KeepInventory)
    if not alive and rec.inv and rec.inv.source ~= "keep" then rec.inv = nil end
    -- the places this player discovered on the map (alive or dead; a record
    -- written before this field existed has none)
    local m = p.map
    if m == nil then m = base.map end
    if map_count(m) > 0 then rec.map = map_copy(m) end
    return rec
end

-- Every record of the world (live ones over the slot's) written into `slot`;
-- inventory files that live in another slot are copied over. The players
-- here are taken as last gathered (no engine object is touched).
local function flush(slot, why, carry_from)
    slot = slot or cur_world_slot()
    for _, p in pairs(P) do
        if p.key and p.restored and not p.off then
            live[p.key] = make_record(p, p.last_why or "playing")
            p.flushed_at, p.prog_dirty, p.map_dirty = clock(), false, false
        end
    end
    local doc
    if carry_from and carry_from ~= slot then
        doc = new_doc(slot)
        if carry_from ~= NOSLOT then
            for k, r in pairs(load_doc(carry_from).players) do doc.players[k] = r end
        end
    else
        doc = (slot ~= NOSLOT) and load_doc(slot) or (docs[slot] or new_doc(slot))
    end
    for k, r in pairs(live) do doc.players[k] = r end
    local copied, failed = 0, {}
    for k, r in pairs(doc.players) do
        if type(r) == "table" and r.inv and r.inv.slot and r.inv.slot ~= slot then
            local from_slot = r.inv.slot
            local ok, err = copy_blob(from_slot, slot, k)
            if ok then
                r.inv.slot, r.inv.file = slot, blob_slot(slot, k)
                copied = copied + 1
                -- their quest save (sdc_quests) goes along, never over a newer one
                local qsrc = blob_path(tostring(from_slot) .. "_SDQuests_" .. k)
                local qdst = blob_path(tostring(slot) .. "_SDQuests_" .. k)
                if qsrc and qdst and file_exists(qsrc) and not file_exists(qdst) then
                    local data = read_file(qsrc)
                    if data then write_file(qdst, data) end
                end
            else
                failed[#failed + 1] = k .. " (" .. tostring(err) .. ")"
            end
        end
    end
    local ok = save_doc(slot, doc, why)
    local n = 0
    for _ in pairs(doc.players) do n = n + 1 end
    M.stats.records_written = M.stats.records_written + n
    log.info("persist: %d player record(s) written to slot %s (%s)%s%s", n, slot, why,
        copied > 0 and string.format(", %d inventory file(s) copied from older slots", copied) or "",
        #failed > 0 and (" | NOT copied: " .. table.concat(failed, ", ")) or "")
    return ok
end
M.flush = flush

-- ---------------------------------------------------------------------------
-- Host: the clients' records follow the host's saves (persist_follow_host_save)
-- ---------------------------------------------------------------------------
-- The records above are LIVE: rewritten while the players play (inventory
-- change, progression, map, death, leaving, periodic). The host's own
-- character and the world only change when the game saves; after a load (a
-- crash, Continue, an older save) the host and the world are back at that
-- save while a live record is not: the client stood where it left and kept
-- items whose containers the load refilled. So:
--   commit  every save of the game (on_host_save: the SaveGameToSlot / EMS
--           AsyncSaveActors hooks - quick save, pause / save menu, sleep, the
--           game's autosave and the co-op autosave sdc_savecheck starts with
--           GameMode.EventSave(true), the savecheck repair save) first writes
--           the live records as before; once the game reports the actors
--           saved (BP_PlayerController.OnCompleted_9CDBA...; OnFailed: nothing
--           is committed, the last commit stays) the live record of every
--           client of that slot (connected or not) is committed, a few
--           players per STEP_MS: inventory file -> <slot>_SDCoop_<key>_c<gen>.sav,
--           quest save <slot>_SDQuests_<key> -> <slot>_SDCoop_<key>_q<gen>.sav,
--           record + those names -> <slot>_SDCoop_commit.json (temp file,
--           renamed in last; the previous one stays as .bak). A crash before
--           that rename leaves the previous commit whole: generation files
--           are new names, and those of the commit before the previous one
--           are deleted only once the new one is in place.
--   load    a world opened from a slot (host_tick, world_seen): the commit's
--           records become the live document at once (memory), its files are
--           copied back over the live ones (live -> _bak), then the document
--           is written (the dropped live one stays as .json.bak). Players
--           without a committed record start new. A PSID before the copy is
--           done finishes it at once; the same running world never reloads
--           (a client back in it gets this session's live record).
--   migration  a slot written before this setting (live records, no commit)
--           takes its live records as the commit at its first load.
--   off     a load keeps the live records (commits are still written, so
--           turning the setting on later starts from the last save).
-- One table (CM): this file is near Lua's 200-locals limit; fields resolve
-- at call time. Plain data only (no engine object), file I/O on the game
-- thread: the persist tick and the job's own ue.delay steps.

local CM = {
    STEP_BYTES = 256 * 1024,   -- a job step copies players until this much was written (at least one)
    STEP_MS = 100,             -- between job steps (the persist tick steps too)
    SAVE_END_S = 60,           -- the game's "actors saved" is awaited this long (sdc_savecheck SAVE_TIMEOUT_S)
}

function CM.follow() return cfg.get("persist_follow_host_save") ~= false end

function CM.paths(slot)
    local dir = savegames_dir()
    if not dir then return nil end
    local base = dir .. safe_slot(slot) .. TAG .. "_commit"
    return base .. ".json", base .. ".json.bak", base .. ".json.tmp"
end

-- a committed file of one player: kind "c" inventory, "q" quest save
function CM.file(slot, key, kind, gen)
    return blob_slot(slot, key, "_" .. kind .. tostring(gen))
end

-- sdc_quests' save of a client (raw slot name, as sdc_quests builds it)
function CM.qname(slot, key)
    return tostring(slot) .. "_SDQuests_" .. tostring(key)
end

function CM.copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = CM.copy(x) end
    return out
end

function CM.count(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

-- doc or nil, the file existed, error
function CM.read_one(path)
    local data = path and read_file(path)
    if not data then return nil, false end
    local d, derr = json_decode(data)
    if valid_doc(d) then return d, true end
    return nil, true, tostring(derr or "no player table")
end

-- The committed document of `slot`: doc, "main" | "backup"; nil when none.
function CM.read(slot)
    local main, bak = CM.paths(slot)
    if not main then return nil end
    local d, had, err = CM.read_one(main)
    if d then return d, "main" end
    if had then
        M.stats.load_fallbacks = M.stats.load_fallbacks + 1
        log.warn("persist: %s is damaged (%s), trying the previous copy", main, tostring(err))
    end
    local b, bhad, berr = CM.read_one(bak)
    if b then return b, "backup" end
    if bhad then log.warn("persist: %s is damaged too (%s)", bak, tostring(berr)) end
    return nil
end

-- the committed files a document names: { [name] = true }
function CM.refs(doc)
    local out = {}
    for _, r in pairs(type(doc) == "table" and type(doc.players) == "table" and doc.players or {}) do
        if type(r) == "table" then
            if type(r.inv) == "table" and type(r.inv.cfile) == "string" then out[r.inv.cfile] = true end
            if type(r.cq) == "string" then out[r.cq] = true end
        end
    end
    return out
end

-- Deletes the files of `doc` that neither `keep1` nor `keep2` names.
function CM.drop_files(doc, keep1, keep2)
    local k1, k2, n = CM.refs(keep1), CM.refs(keep2), 0
    for name in pairs(CM.refs(doc)) do
        if not k1[name] and not k2[name] then
            local p = blob_path(name)
            if p and os.remove(p) then n = n + 1 end
        end
    end
    return n
end

-- A whole file under a new name: temp file, then renamed.
function CM.put(name, data)
    local path, tmp = blob_path(name), blob_path(name .. "_tmp")
    local ok, err = write_file(tmp, data)
    if not ok then
        os.remove(tmp)
        return false, err
    end
    os.remove(path)
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        os.remove(tmp)
        return false, tostring(rerr)
    end
    return true
end

-- data over a live file: temp, the live one kept as `bak_name`
function CM.put_live(name, bak_name, data)
    local tmp = blob_path(name .. "_tmp")
    local ok, err = write_file(tmp, data)
    if ok then ok, err = rotate(blob_path(name), blob_path(bak_name), tmp) end
    if not ok then os.remove(tmp) end
    return ok, err
end

-- One job at a time (hs.job): "commit" or "reset", one step = players until
-- STEP_BYTES were written, then the end. True when the job is over.
function CM.step(job)
    if hs.job ~= job then return true end
    local ok, err = pcall(function()
        local written = 0
        while job.i < #job.keys do
            job.i = job.i + 1
            local key = job.keys[job.i]
            local okp, n = pcall(job.kind == "commit" and CM.commit_one or CM.reset_one, job, key)
            if not okp then
                job.errs[#job.errs + 1] = key .. " (" .. tostring(n) .. ")"
                n = 0
            end
            written = written + (tonumber(n) or 0)
            if written >= CM.STEP_BYTES and job.i < #job.keys then return end
        end
        hs.job = nil
        if job.kind == "commit" then CM.commit_end(job) else CM.reset_end(job) end
    end)
    if not ok then
        hs.job = nil
        M.stats.write_errors = M.stats.write_errors + 1
        log.err("persist: %s of slot %s stopped: %s", job.kind, tostring(job.slot), tostring(err))
    end
    return hs.job ~= job
end

function CM.pump(job)
    if CM.step(job) then return end
    ue.delay("persist-commit", CM.STEP_MS, function() CM.pump(job) end)
end

-- whatever is left of the job, now (world change, a join, the next save)
function CM.finish_now()
    local job = hs.job
    local guard = 0
    while job and hs.job == job and guard < 10000 do
        guard = guard + 1
        CM.step(job)
    end
end

-- A slot's job / pending commit is dropped (the game deletes the slot).
function CM.cancel(slot)
    local job = hs.job
    if job and job.slot == slot then
        hs.job = nil
        if job.kind == "commit" then CM.drop_files({ players = job.out }, job.old_main, job.old_bak) end
    end
    if hs.commit_wait and hs.commit_wait.slot == slot then hs.commit_wait = nil end
end

-- -------- commit

function CM.start_commit(slot, why, from)
    if not slot or slot == NOSLOT or slot == TEMP_SLOT or not CM.paths(slot) then return end
    CM.finish_now()
    local doc = docs[slot] or load_doc(slot)
    local keys = {}
    for k, r in pairs(doc.players) do
        if type(r) == "table" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local main, bak = CM.paths(slot)
    local md = CM.read_one(main)
    local bd = CM.read_one(bak)
    local gen = math.max(math.tointeger(tonumber(md and md.gen) or 0) or 0, math.tointeger(tonumber(bd and bd.gen) or 0) or 0) + 1
    local job = { kind = "commit", slot = slot, why = why, from = from, keys = keys, i = 0, gen = gen, out = {},
                  old_main = md, old_bak = bd, main_bad = file_exists(main) and md == nil,
                  errs = {}, inv = 0, quests = 0, t0 = os.clock() }
    hs.job = job
    CM.pump(job)
end

-- One player's live record + files -> this commit's copies. The record and
-- its inventory file are read in the same step (written together, see
-- inv_check + flush), so they always match.
function CM.commit_one(job, key)
    local doc = docs[job.slot] or load_doc(job.slot)
    local r = doc.players[key]
    if type(r) ~= "table" then return 0 end
    local rec = CM.copy(r)
    rec.cq = nil
    local n = 0
    if type(rec.inv) == "table" then
        rec.inv.cfile = nil
        local from = rec.inv.slot or job.slot
        local data = read_file(blob_path(blob_slot(from, key))) or read_file(blob_path(blob_slot(from, key, "_bak")))
        if data then
            local name = CM.file(job.slot, key, "c", job.gen)
            local ok, err = CM.put(name, data)
            if ok then
                rec.inv.cfile = name
                job.inv, n = job.inv + 1, n + #data
            else
                job.errs[#job.errs + 1] = string.format("%s inventory (%s)", tostring(r.name or key), tostring(err))
            end
        else
            job.errs[#job.errs + 1] = string.format("%s inventory (no file of %s)", tostring(r.name or key), tostring(from))
        end
    end
    -- the player's own quests (sdc_quests): this slot's, else the slot the
    -- world came from (a save to a new slot)
    local qd = read_file(blob_path(CM.qname(job.slot, key)))
    if not qd and job.from and job.from ~= job.slot then qd = read_file(blob_path(CM.qname(job.from, key))) end
    if qd then
        local name = CM.file(job.slot, key, "q", job.gen)
        local ok, err = CM.put(name, qd)
        if ok then
            rec.cq = name
            job.quests, n = job.quests + 1, n + #qd
        else
            job.errs[#job.errs + 1] = string.format("%s quests (%s)", tostring(r.name or key), tostring(err))
        end
    elseif safe_slot(job.slot) == tostring(job.slot) then
        -- no quest save of this player at this save (a plain slot name: the
        -- file would have opened); one made later is not this save's
        rec.cq = false
    end
    job.out[key] = rec
    return n
end

function CM.commit_end(job)
    local main, bak, tmp = CM.paths(job.slot)
    local n = CM.count(job.out)
    local session = package.loaded["sdc_session"]
    local doc = {
        format = M.FORMAT, kind = "commit", slot = job.slot, gen = job.gen, why = job.why,
        committed = clock(), committed_at = os.date("%Y-%m-%d %H:%M:%S"), mod = session and session.VERSION or nil,
        note = "SDCoop: the other players' characters as of the host's last save of this slot (a load of the slot gives"
            .. " them back). Files: " .. safe_slot(job.slot) .. TAG .. "_<key>_c<gen>.sav (inventory), _q<gen>.sav (quests)",
        players = job.out,
    }
    local ok, err = write_file(tmp, json_encode(doc) .. "\n")
    if ok then
        -- a damaged previous commit is not kept as .bak over the good older one
        if job.main_bad then os.remove(main) end
        ok, err = rotate(main, bak, tmp)
    end
    if not ok then
        os.remove(tmp)
        CM.drop_files(doc, job.old_main, job.old_bak)
        M.stats.write_errors = M.stats.write_errors + 1
        M.stats.commits_dropped = M.stats.commits_dropped + 1
        log.err("persist: committing %d client record(s) to slot %s FAILED (%s): %s; the slot's last committed records stay",
            n, job.slot, tostring(job.why), tostring(err))
        return
    end
    -- the commit before the previous one is gone (rotated out): its files too
    local dropped = 0
    if job.old_main and job.old_bak then dropped = CM.drop_files(job.old_bak, job.old_main, doc) end
    M.stats.commits = M.stats.commits + 1
    M.stats.commit_files = M.stats.commit_files + job.inv + job.quests
    if tostring(job.why):find("^migration") then M.stats.migrations = M.stats.migrations + 1 end
    hs.last_commit = os.date("%H:%M:%S") .. " " .. job.slot .. " #" .. job.gen
    log.info("persist: committed %d client record(s) to slot %s (%s): %d inventory / %d quest file(s), generation %d, %.0f ms%s%s%s",
        n, job.slot, tostring(job.why), job.inv, job.quests, job.gen, (os.clock() - job.t0) * 1000,
        dropped > 0 and string.format(", %d file(s) of an older commit deleted", dropped) or "",
        #job.errs > 0 and (" | NOT copied: " .. table.concat(job.errs, ", ")) or "",
        CM.follow() and "" or " (persist_follow_host_save is off: a load keeps the live records)")
end

-- on_host_save: the live records of `slot` are written; the commit waits for
-- the game's own "actors saved" (or failed). The end may come first.
function CM.save_started(slot, why, from)
    if not CM.paths(slot) or slot == NOSLOT or slot == TEMP_SLOT then return end
    hs.commit_wait = { slot = slot, why = why, from = from, at = clock() }
    local e = hs.save_end
    hs.save_end = nil
    if not hs.hooks.saved_ok then
        CM.save_end(true, "the game's save end is not hooked here")
    elseif e and clock() - e.at <= 5 then
        CM.save_end(e.ok, e.note)
    end
end

-- The game's save of the host's world ended (hooks): commit or drop.
function CM.save_end(ok, note)
    local w = hs.commit_wait
    if not w then
        hs.save_end = { ok = ok, at = clock(), note = note }   -- before on_host_save: it takes this
        return
    end
    hs.commit_wait = nil
    if ok then
        CM.start_commit(w.slot, w.why, w.from)
    else
        M.stats.commits_dropped = M.stats.commits_dropped + 1
        log.warn("persist: the game's save of slot %s FAILED%s: the clients' records are NOT committed (a load of that slot"
            .. " gives the last committed ones)", w.slot, note and (" (" .. note .. ")") or "")
    end
end

function CM.wait_tick(now)
    local w = hs.commit_wait
    if w and now - w.at >= CM.SAVE_END_S then
        hs.commit_wait = nil
        M.stats.commits_dropped = M.stats.commits_dropped + 1
        log.warn("persist: the game did not report its save of slot %s done within %d s: the clients' records are NOT committed",
            w.slot, CM.SAVE_END_S)
    end
end

-- -------- load

-- The world was opened from `slot` (live document `ldoc` just read): the
-- committed records become the live ones (see above).
function CM.world_loaded(slot, ldoc)
    hs.loaded = nil
    CM.finish_now()
    if slot == NOSLOT or slot == TEMP_SLOT or not enabled() or not CM.paths(slot) then return end
    local live_n = CM.count(ldoc and ldoc.players)
    local live_at = ldoc and ldoc.updated_at or "-"
    if not CM.follow() then
        hs.loaded = { slot = slot, mode = "live", why = "persist_follow_host_save is off", fresh = true }
        if live_n > 0 then
            log.info("persist: slot %s loaded: persist_follow_host_save is off: the %d live client record(s) (from %s) are used as they are",
                slot, live_n, live_at)
        end
        return
    end
    local cdoc, from = CM.read(slot)
    if not cdoc then
        hs.loaded = { slot = slot, mode = "live", why = "no committed records yet (a slot from before persist_follow_host_save)",
                      fresh = true }
        if live_n > 0 then
            log.info("persist: slot %s has no committed client records yet (written before persist_follow_host_save):"
                .. " its %d live record(s) (from %s) are taken as this save's", slot, live_n, live_at)
            CM.start_commit(slot, "migration: the live records of a slot from before persist_follow_host_save")
        end
        return
    end
    local newdoc, keys, src = new_doc(slot), {}, {}
    local at = tostring(cdoc.committed_at or "?")
    local loaded = { slot = slot, mode = "save", at = at, keys = {}, dropped = {}, fresh = true }
    for k, r in pairs(cdoc.players) do
        if type(r) == "table" then
            local rec = CM.copy(r)
            rec.cq = nil
            if type(rec.inv) == "table" then
                if type(rec.inv.cfile) ~= "string" then
                    -- the save's inventory file was not committed: no live file may stand in for
                    -- it (its counts can never match) - the record's item list is used
                    rec.inv.containers, rec.inv.items = -1, -1
                end
                rec.inv.cfile = nil
                rec.inv.slot, rec.inv.file = slot, blob_slot(slot, k)
            end
            newdoc.players[k] = rec
            src[k] = r
            keys[#keys + 1] = k
            loaded.keys[k] = true
        end
    end
    table.sort(keys)
    -- players who came after that save: their record goes, and their quest
    -- save aside (a new character must not pick it up with a later commit)
    local gone, qaside = {}, 0
    for k, r in pairs(ldoc and ldoc.players or {}) do
        if not loaded.keys[k] then
            loaded.dropped[k] = true
            gone[#gone + 1] = tostring(type(r) == "table" and r.name or k)
            if CM.aside(CM.qname(slot, k)) then qaside = qaside + 1 end
        end
    end
    table.sort(gone)
    docs[slot] = newdoc   -- find_record / the map share see the save's records from now on
    hs.loaded = loaded
    M.stats.resets = M.stats.resets + 1
    log.info("persist: slot %s loaded: %d client record(s) back to the save (live ones from %s dropped); the save's records:"
        .. " committed %s (%s)%s%s", slot, #keys, live_at, at, tostring(cdoc.why or "?"),
        #gone > 0 and string.format("; %d player(s) who came after that save start as new characters: %s", #gone,
            table.concat(gone, ", ")) or "",
        from == "backup" and "; taken from the previous copy (.bak)" or "")
    local job = { kind = "reset", slot = slot, keys = keys, src = src, doc = newdoc, i = 0, errs = {}, inv = 0,
                  quests = 0, qmoved = qaside, t0 = os.clock() }
    hs.job = job
    CM.pump(job)
end

-- A load of the game DURING the session. The main menu and the world are one
-- level here (GameInstance.Event_LoadLevel -> SmoothLoadLevel streams the
-- map): the death screen / pause menu "main menu" and then Load / Continue
-- open no new level, so no world change reaches M.reset and host_tick's
-- world_seen stays true (2026-11-11 20:07: the host died, loaded the slot
-- from the main menu, the client came back with its live record). The load
-- itself is EMSAsyncLoadGame.AsyncLoadActors (BP_PlayerController @806,
-- after LoadGameFromSlot - only a load from a save calls it; a respawn does
-- not): native pre-hook, the host's own controller.
CM.LOAD_FN = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors"

function CM.load_started(wco_p)
    if not S or S.role ~= "host" then return end
    local pc = wco_p and wco_p:get()
    if ue.valid(pc) then
        local okl, isl = pcall(function() return pc:IsLocalController() end)
        if okl and isl == false then return end
    end
    hs.load_wait = clock()   -- PSIDs wait for this (on_pid)
    ue.delay("persist-load", 50, function() CM.game_loaded() end)
end

-- The world goes back to the slot being loaded: the players' live state
-- before it goes (written to the old slot as at a world change), the
-- records go back to the save (CM.world_loaded), and players still
-- connected get the save's state again (hs.redo, host_tick).
function CM.game_loaded()
    hs.load_wait = nil
    if not S or S.role ~= "host" or not enabled() then return end
    local slot = world_slot_of(ue.ems_current_slot())
    local l = hs.loaded
    if l and l.slot == slot and l.fresh then
        -- the first load after a world change: done at world_seen already
        log.info("persist: the game's load of slot %s: the clients' records are already as at its save (nobody joined since)", slot)
        return
    end
    local old = cur_world_slot()
    if not CM.follow() and slot == old then
        log.info("persist: the game loaded slot %s again during the session; persist_follow_host_save is off: the live records stay", slot)
        return
    end
    CM.finish_now()
    local any = false
    for _, p in pairs(P) do
        if p.key and p.restored then p.last_why, any = "world reloaded", true end
    end
    if any then
        local okf, ferr = pcall(flush, old, "world closed (the game loaded slot " .. tostring(slot) .. ")")
        if not okf then log.err("persist: writing the records before the load: %s", tostring(ferr)) end
    end
    local redo, nredo = {}, 0
    for skey, p in pairs(P) do
        local r = (S.remote or {})[skey]
        if p.key and r and ue.valid(r.pc) then
            redo[skey] = { key = p.key, sid = p.sid, guid = p.guid, name = p.name }
            nredo = nredo + 1
        end
        P[skey] = nil
    end
    for k in pairs(live) do live[k] = nil end
    hs.share = nil
    hs.world_slot, hs.world_seen, hs.loaded = slot, true, nil
    log.info("persist: the game loaded slot %s during the session (the world was %s)%s", slot, old,
        nredo > 0 and string.format(": %d connected player(s) get that save's state again", nredo) or "")
    if slot ~= NOSLOT then CM.world_loaded(slot, load_doc(slot, true)) end
    hs.redo = nredo > 0 and redo or nil
end

-- host_tick: players who stayed connected through a load, once the world is
-- up and the records are back: a new verdict, as for a late id (the client
-- applies a second verdict of the same connection: sdc_progress.set_verdict).
function CM.redo_tick(decide_fn)
    if not hs.redo or hs.job or S.in_menu ~= false then return end
    for skey, q in pairs(hs.redo) do
        hs.redo[skey] = nil
        local r = (S.remote or {})[skey]
        if r and ue.valid(r.pc) and not P[skey] then
            local p = { key = q.key, sid = q.sid, guid = q.guid, name = r.name or q.name, joined = clock(), late = true }
            P[skey] = p
            log.info("persist: %s stayed connected through the load: given the save's state again", p.name)
            decide_fn(r, p)
        end
    end
    if not next(hs.redo) then hs.redo = nil end
end

-- One player's committed files back over the live ones.
function CM.reset_one(job, key)
    local c = job.src[key]
    local n = 0
    if type(c.inv) == "table" and type(c.inv.cfile) == "string" then
        local data = read_file(blob_path(c.inv.cfile))
        local ok, err = false, "committed file " .. c.inv.cfile .. " missing"
        if data then ok, err = CM.put_live(blob_slot(job.slot, key), blob_slot(job.slot, key, "_bak"), data) end
        if ok then
            job.inv, n = job.inv + 1, n + #data
        else
            -- the live file is not the save's: it must not be restored (the record's item list is)
            job.errs[#job.errs + 1] = string.format("%s inventory (%s: the record's item list is used)", tostring(c.name or key),
                tostring(err))
            local rec = job.doc.players[key]
            if rec and rec.inv then rec.inv.containers, rec.inv.items = -1, -1 end
        end
    end
    local qn = CM.qname(job.slot, key)
    if type(c.cq) == "string" then
        local data = read_file(blob_path(c.cq))
        local ok, err = false, "committed file " .. c.cq .. " missing"
        if data then ok, err = CM.put_live(qn, qn .. "_bak", data) end
        if ok then
            job.quests, n = job.quests + 1, n + #data
        else
            job.errs[#job.errs + 1] = string.format("%s quests (%s)", tostring(c.name or key), tostring(err))
        end
    elseif c.cq == false and CM.aside(qn) then
        job.qmoved = job.qmoved + 1   -- no quest save at that save: a later one is not the save's
    end
    return n
end

-- A live file that is not the save's goes aside (<name>_bak). True if moved.
function CM.aside(name)
    local p, b = blob_path(name), blob_path(name .. "_bak")
    if not file_exists(p) then return false end
    os.remove(b)
    return os.rename(p, b) == true
end

function CM.reset_end(job)
    local ok = save_doc(job.slot, job.doc, "world loaded: back to the save")
    M.stats.reset_files = M.stats.reset_files + job.inv + job.quests
    local fn = (#job.errs > 0 or not ok) and log.warn or log.info
    fn("persist: slot %s: the save's client records are in place (%d inventory / %d quest file(s) put back%s, %.0f ms)%s%s",
        job.slot, job.inv, job.quests, job.qmoved > 0 and string.format(", %d later quest save(s) set aside", job.qmoved) or "",
        (os.clock() - job.t0) * 1000, ok and "" or "; the live document could NOT be written (memory only)",
        #job.errs > 0 and (" | " .. table.concat(job.errs, ", ")) or "")
end

-- -------- logs / status

-- which version of the record a joining player gets (decide's log)
function CM.origin(key, src)
    if src == "this session" then return " (this session's live record: the world was not reloaded since)" end
    local l = hs.loaded
    if not l then return "" end
    if l.mode == "save" then
        if l.keys[key] then return " (the save's record, committed " .. tostring(l.at) .. ")" end
        return ""
    end
    return " (live record: " .. tostring(l.why) .. ")"
end

function CM.fresh_note(key)
    local l = hs.loaded
    if l and l.mode == "save" and l.dropped[key] then
        return " (a live record from after the save was dropped when the world was loaded)"
    end
    return ""
end

-- The game deletes a slot: its committed documents and files go too. Adds
-- the committed players to `keys`; returns how many committed records.
function CM.delete_slot(slot, keys)
    local main, bak, tmp = CM.paths(slot)
    if not main then return 0 end
    local n = 0
    for _, p in ipairs({ main, bak }) do
        local d = CM.read_one(p)
        if d then
            CM.drop_files(d)
            for k in pairs(d.players) do
                keys[k] = true
                n = n + 1
            end
        end
    end
    os.remove(main)
    os.remove(bak)
    os.remove(tmp)
    return n
end

function CM.status()
    local l = hs.loaded
    local load = "-"
    if l then
        load = l.mode == "save" and string.format("%s back to the save of %s (%d record(s), %d dropped)", l.slot, tostring(l.at),
            CM.count(l.keys), CM.count(l.dropped)) or string.format("%s live (%s)", l.slot, tostring(l.why))
    end
    local s = M.stats
    return string.format("commit: follow=%s commits=%d files=%d dropped=%d migrations=%d last=%s%s%s | load: %s (%d reset(s), %d file(s))",
        tostring(CM.follow()), s.commits, s.commit_files, s.commits_dropped, s.migrations, tostring(hs.last_commit),
        hs.commit_wait and (" waiting for the game's save of " .. hs.commit_wait.slot) or "",
        hs.job and (" " .. hs.job.kind .. " running " .. hs.job.i .. "/" .. #hs.job.keys) or "",
        load, s.resets, s.reset_files)
end
M._CM = CM

-- ---------------------------------------------------------------------------
-- Host: reading the live character
-- ---------------------------------------------------------------------------

local function read_vitals(pawn)
    local v = {}
    for _, d in ipairs(VITALS) do
        local comp = ue.prop(pawn, d[1])
        local x = ue.prop(comp, d[2])
        if type(x) == "number" then v[d[2]] = num(x, 3) end
    end
    local med = ue.prop(pawn, "MedicalComponent")
    for _, f in ipairs(MEDICAL) do
        local x = ue.prop(med, f)
        if x ~= nil then v[f] = type(x) == "number" and num(x, 2) or x end
    end
    v.MaxHealth = num(ue.prop(med, "MaxHealth"), 3)
    v["DeathbringerSkillUsed?"] = ue.prop(pawn, "DeathbringerSkillUsed?")
    return v
end

local function read_pos(r, pawn)
    local loc = ue.location(pawn)
    if not loc then return nil end
    local yaw = ue.rotation(pawn).Yaw or 0
    local okc, cr = pcall(function() return r.pc:GetControlRotation() end)
    if okc and cr then
        local y = ue.try(function() return cr.Yaw end)
        if type(y) == "number" then yaw = y end
    end
    local pos = { x = num(loc.X, 1), y = num(loc.Y, 1), z = num(loc.Z, 1), yaw = num(yaw, 1) }
    -- in a vehicle: the game saves the driver side door (ActorPreSave @149888)
    if ue.prop(pawn, "InVehicle?") == true then
        pos.vehicle = true
        local veh = ue.prop(ue.prop(pawn, "VehicleDrivingComponent"), "Vehicle")
        local mesh = ue.prop(veh, "Mesh")
        local okd, door = pcall(function() return mesh:GetSocketLocation(FName("DriverSide")) end)
        if okd and door then
            local x, y, z = ue.try(function() return door.X end), ue.try(function() return door.Y end), ue.try(function() return door.Z end)
            if type(x) == "number" and type(y) == "number" and type(z) == "number" and (x ~= 0 or y ~= 0) then
                pos.x, pos.y, pos.z = num(x, 1), num(y, 1), num(z, 1) + 60
            end
        end
    end
    return pos
end

local function read_respawn(pc)
    if not ue.valid(pc) then return nil end
    local en = ue.prop(pc, "RespawnPointEnabled")
    if en == nil then return nil end
    local tf = read_transform(ue.prop(pc, "RespawnLoc"))
    return { en = en == true, t = tf and tf.t or nil, q = tf and tf.q or nil }
end

local function light_snapshot(r, p, pawn, now)
    local s = p.snap or {}
    p.snap = s
    local dead = r.dead == true or (pawn ~= nil and ue.prop(pawn, "PlayerDead?") == true)
    local was_alive = s.alive
    s.alive = pawn ~= nil and not dead
    if s.alive then
        s.pos = read_pos(r, pawn) or s.pos
        s.vitals = read_vitals(pawn)
    elseif pawn == nil and not dead and was_alive ~= nil then
        s.alive = was_alive   -- pawnless for a moment (respawn in progress): no change
    end
    s.respawn = read_respawn(r.pc) or s.respawn
    s.at = now
    return was_alive == true and s.alive == false
end

-- Inventory check: on a change (or forced) the file is written into the
-- world's slot. Returns true when a file was written.
local function inv_check(r, p, pawn, now, force, why)
    p.inv_at = now
    local slot = cur_world_slot()
    local src, source = nil, nil
    if p.snap and p.snap.alive and pawn then
        local jig = ue.prop(pawn, "BP_JigMultiplayer")
        if not ue.valid(jig) then return false end
        src = { conts = ue.prop(jig, "MainJigContainers"), uids = ue.prop(jig, "MainContainersIDs"),
                weights = ue.prop(jig, "InventoryWeight") }
        source = "character"
    elseif keep_inventory_on() and ue.valid(r.pc) then
        local k = ue.prop(r.pc, "KeepInventory")
        local conts = k and ue.try(function() return k[K_CONT] end)
        if conts == nil or arr_num(conts) == 0 then
            if p.inv and p.inv.source ~= "keep" then p.inv, p.inv_sig = nil, nil end
            return false
        end
        src = { conts = conts, uids = ue.try(function() return k[K_UIDS] end),
                weights = ue.try(function() return k[K_WEIGHTS] end) }
        source = "keep"
    else
        -- dead: the items are in the loot box in the world
        if p.inv then
            log.info("persist: %s is dead: the saved inventory is dropped (the items are in the loot box)", p.name)
        end
        p.inv, p.inv_sig = nil, nil
        return false
    end
    if src.conts == nil or src.uids == nil or src.weights == nil then return false end
    local sig, nc, ni, _, werr = inv_walk(src.conts, false)
    if not sig then
        log.err_throttled("persist-inv-" .. p.key, "persist: reading %s's inventory failed: %s", p.name, tostring(werr))
        return false
    end
    if not force and sig == p.inv_sig and p.inv and p.inv.slot == slot and p.inv.source == source then return false end
    local info, sig2 = write_blob(slot, p.key, src, p.hot or (p.base and p.base.hotbar), p.snap and p.snap.pos)
    if not info then
        M.stats.write_errors = M.stats.write_errors + 1
        log.err("persist: writing %s's inventory to slot %s failed (%s): %s", p.name, slot, tostring(why), tostring(sig2))
        return false
    end
    info.source = source
    p.inv, p.inv_sig = info, sig
    log.info("persist: %s's inventory written to %s (%s): %d container(s), %d item(s)%s", p.name, info.file,
        tostring(why), nc, ni, source == "keep" and " [kept through death]" or "")
    return true
end

-- ---------------------------------------------------------------------------
-- Host: restore
-- ---------------------------------------------------------------------------

local function write_transform(o, prop, t, q)
    local tf = {
        Rotation = { X = q.x or 0, Y = q.y or 0, Z = q.z or 0, W = q.w or 1 },
        Translation = { X = t.x or 0, Y = t.y or 0, Z = t.z or 0 },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    ue.set_prop(o, prop, tf)
    local back = read_transform(ue.prop(o, prop))
    if back and math.abs(back.t.x - (t.x or 0)) < 1 and math.abs(back.t.y - (t.y or 0)) < 1 then return true end
    pcall(function()
        local cur = o:GetPropertyValue(prop)
        cur.Translation.X, cur.Translation.Y, cur.Translation.Z = t.x or 0, t.y or 0, t.z or 0
        cur.Rotation.X, cur.Rotation.Y, cur.Rotation.Z, cur.Rotation.W = q.x or 0, q.y or 0, q.z or 0, q.w or 1
    end)
    back = read_transform(ue.prop(o, prop))
    return back ~= nil and math.abs(back.t.x - (t.x or 0)) < 1 and math.abs(back.t.y - (t.y or 0)) < 1
end
M.write_transform = write_transform

local function respawn_str(rp)
    if not rp or not rp.en or not rp.t or not rp.q then return "0" end
    return string.format("1,%.1f,%.1f,%.1f,%.6f,%.6f,%.6f,%.6f", rp.t.x, rp.t.y, rp.t.z, rp.q.x, rp.q.y, rp.q.z, rp.q.w)
end

local function parse_respawn(s)
    local parts = {}
    for x in tostring(s or ""):gmatch("[^,]+") do parts[#parts + 1] = tonumber(x) end
    if #parts ~= 8 or parts[1] ~= 1 then return nil end
    return { en = true, t = { x = parts[2], y = parts[3], z = parts[4] }, q = { x = parts[5], y = parts[6], z = parts[7], w = parts[8] } }
end
M.parse_respawn = parse_respawn

local function tree_str(list)
    if type(list) ~= "table" or #list == 0 then return "-" end
    return table.concat(list, ",")
end

local function parse_list(s)
    local out = {}
    for x in tostring(s or ""):gmatch("[^,]+") do
        if x ~= "-" and x ~= "?" then out[#out + 1] = x end
    end
    return out
end

local function sane_pos(pos)
    if type(pos) ~= "table" then return false end
    for _, k in ipairs({ "x", "y", "z" }) do
        local v = pos[k]
        if type(v) ~= "number" or v ~= v or math.abs(v) > 5e6 then return false end
    end
    if pos.x == 0 and pos.y == 0 then return false end
    return pos.z > -100000
end

-- The host's copy of the player's controller: saved progression (skill
-- checks / damage the host computes for this player use it), journal,
-- respawn point; the host's skill-tree answers (sdc_skilltree.seed).
local function apply_host_copy(r, p)
    local rec = p.base
    if not rec or not ue.valid(r.pc) then return end
    local parts = {}
    local prog = progress_mod()
    if rec.prog and prog and prog.apply_values then
        local ok, n = pcall(prog.apply_values, r.pc, nil, rec.prog, "host copy of " .. p.name, false)
        parts[#parts + 1] = ok and string.format("progression %s value(s)", tostring(n)) or ("progression ERR " .. tostring(n))
    end
    local rp = rec.respawn
    if rp and rp.en and rp.t and rp.q then
        local okw = write_transform(r.pc, "RespawnLoc", rp.t, rp.q)
        ue.set_prop(r.pc, "RespawnPointEnabled", okw)
        parts[#parts + 1] = "respawn point " .. (okw and "set" or "NOT set")
    end
    local tree = skilltree_mod()
    if rec.tree and tree and tree.seed then
        pcall(tree.seed, r.pc, tree_str(rec.tree), p.name)
        parts[#parts + 1] = string.format("%d skill(s)", #rec.tree)
    end
    log.info("persist: host copy of %s's controller restored: %s", p.name, table.concat(parts, ", "))
end

local function apply_vitals(pawn, v, name)
    local parts = {}
    for _, d in ipairs(VITALS) do
        local x = v[d[2]]
        local comp = ue.prop(pawn, d[1])
        if type(x) == "number" and ue.valid(comp) then
            if d[2] == "Health" then
                local maxh = ue.prop(comp, "MaxHealth")
                if type(maxh) == "number" and maxh > 0 then x = math.min(x, maxh) end
                x = math.max(x, 1)
            end
            if ue.set_prop(comp, d[2], x) then
                mark_dirty(comp, d[3], d[2])
                pcall(function() pawn[d[4]](pawn, x) end)
                parts[#parts + 1] = string.format("%s=%.0f", d[2], x)
            end
        end
    end
    local med = ue.prop(pawn, "MedicalComponent")
    local states = {}
    if ue.valid(med) then
        for _, f in ipairs(MEDICAL) do
            if v[f] ~= nil then
                ue.set_prop(med, f, v[f])
                if v[f] == true then states[#states + 1] = f end
            end
        end
        -- the EMS load event: re-runs the OnRep_* of the states (timers, replication)
        pcall(function() med:ComponentLoaded() end)
    end
    if v["DeathbringerSkillUsed?"] ~= nil then ue.set_prop(pawn, "DeathbringerSkillUsed?", v["DeathbringerSkillUsed?"] == true) end
    log.info("persist: %s's health & co. restored: %s%s", name, table.concat(parts, " "),
        #states > 0 and (" | " .. table.concat(states, ",")) or "")
end

-- Last resort (both inventory files unusable): the record's item list added
-- one by one by the plugin's own server-side add (sdc_consume IGAIN path).
local function restore_from_list(pawn, list, name)
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) or type(list) ~= "table" then return 0, 0 end
    local added, failed = 0, 0
    for _, it in ipairs(list) do
        local da = it.path and it.path ~= "" and ue.find_object(it.path)
        if not da and it.path and it.path:find("^/") then
            local ok, o = ue.load_asset(it.path, "persist")
            if ok and ue.valid(o) then da = o end
        end
        local n = math.max(1, math.floor(tonumber(it.n) or 1))
        if da then
            local a, d, u, t = {}, {}, {}, {}
            local ok = pcall(function() comp:AddNewItemSomewhere(da, n, nil, 1, true, FName("None"), a, d, u, t) end)
            if ok and (a.Added == true or d["Dropped?"] == true) then added = added + 1 else failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    log.warn("persist: %s's inventory rebuilt from the record's item list: %d added, %d failed (no attachments, durability or slots)",
        name, added, failed)
    return added, failed
end

local function restore_character(r, p, pawn, why)
    local rs = p.restore
    rs.done = true
    if not pawn then
        log.warn("persist: %s has no character for the restore (%s): skipped", p.name, why)
        p.restored = true
        return
    end
    if rs.vitals then
        local ok, err = pcall(apply_vitals, pawn, rs.vitals, p.name)
        if not ok then log.err("persist: %s's health & co.: %s", p.name, tostring(err)) end
    end
    local items = nil
    if rs.inv then
        local obj, file = load_blob(rs.inv.slot or cur_world_slot(), p.key, rs.inv)
        local comp = ue.prop(pawn, "BP_JigMultiplayer")
        if obj and ue.valid(comp) then
            local ok, err = pcall(function()
                comp:SERVER_LoadSaveDataFromClientSide(ue.prop(obj, "JigContainers"), ue.prop(obj, "MainUIDs"),
                    ue.prop(obj, "Weights"), ue.prop(obj, "ActionbarUIDs"))
            end)
            local _, nc, ni = inv_walk(ue.prop(comp, "MainJigContainers"), false)
            if ok and nc == rs.inv.containers and ni == rs.inv.items then
                items = ni
                M.stats.inv_restored = M.stats.inv_restored + 1
                log.info("persist: %s's inventory restored from %s (%s): %d container(s), %d item(s)", p.name,
                    tostring(file), why, nc, ni)
                -- this file is the player's inventory until the next write
                p.inv = { file = blob_slot(rs.inv.slot or cur_world_slot(), p.key), slot = rs.inv.slot or cur_world_slot(),
                          containers = nc, items = ni, list = rs.inv.list, source = "character" }
                p.inv_sig = nil
            else
                log.err("persist: %s's inventory restore %s: the character holds %d/%d after the load (expected %s/%s)%s",
                    p.name, ok and "did not take" or "FAILED", nc, ni, tostring(rs.inv.containers), tostring(rs.inv.items),
                    ok and "" or (": " .. tostring(err)))
            end
        end
        if not items then
            M.stats.inv_fallback = M.stats.inv_fallback + 1
            if rs.inv.list then
                local added = restore_from_list(pawn, rs.inv.list, p.name)
                items = added
            end
            if ue.valid(r.pc) then log.say("persist_inv_failed", "err", 8, p.name) end
        end
    end
    -- The id came after the first character spawned (the gate gave up,
    -- PID_WAIT_S): it stands at the join point next to the host, not where
    -- the player left. Move it there now, the way "unstuck" moves a client
    -- (UNSTUCKTO: the client owns its movement), and watch it for a fall.
    if p.late and rs.pos and not rs.dead and cfg.get("persist_restore_position") ~= false then
        local spot = { X = rs.pos.x, Y = rs.pos.y, Z = rs.pos.z + 30 }
        local cur = ue.location(pawn)
        local dx, dy = cur and (cur.X - spot.X) or 1e9, cur and (cur.Y - spot.Y) or 1e9
        if dx * dx + dy * dy > 300 * 300 then
            if ue.valid(r.pc) then
                net.send_to(r.pc, "UNSTUCKTO", string.format("%.0f", spot.X), string.format("%.0f", spot.Y),
                    string.format("%.0f", spot.Z), string.format("%.0f", rs.pos.yaw or 0), "saved")
            end
            if cfg.get("client_movement_authority") == false then ue.teleport(pawn, spot) end
            p.fall = { z = rs.pos.z, at = clock() + FALL_CHECK_S }
            log.info("persist: %s's id came after its character spawned (at the join point): moved to the saved spot %.0f,%.0f,%.0f",
                p.name, spot.X, spot.Y, rs.pos.z)
        end
    end
    p.restored = true
    p.inv_at = 0
    M.stats.restores = M.stats.restores + 1
    local lvl = p.base and p.base.prog and p.base.prog.L and p.base.prog.L.CurrentLevel
    if ue.valid(r.pc) then net.send_to(r.pc, "PSDONE", p.gen, tostring(lvl or "?"), tostring(items or 0)) end
    log.say("persist_restored_host", "ok", 6, p.name)
end

-- ---------------------------------------------------------------------------
-- Host: identity and the verdict
-- ---------------------------------------------------------------------------

local on_left   -- below (Host tick)

local function send_verdict(r, p)
    if not ue.valid(r.pc) then return end
    if p.verdict == "restore" then
        local prog = progress_mod()
        local vals = (p.base.prog and prog and prog.encode_values) and prog.encode_values(p.base.prog) or ""
        local flags = {}
        if p.restore.inv then flags[#flags + 1] = "inv" end
        if p.restore.dead then flags[#flags + 1] = "dead" end
        -- the character has (or gets) the starting kit: the client clears its
        -- inventory UI first, as the game's own load does
        if p.late or not (players_mod() or {}).PERSIST_HOOKS then flags[#flags + 1] = "clear" end
        net.send_to(r.pc, "PSSET", p.gen, vals, tree_str(p.base.tree), respawn_str(p.base.respawn), table.concat(flags, ","))
        -- the places this player had discovered: right behind the record (the
        -- client sets them once the record is applied); older clients ignore it
        local nmap = map_count(p.map)
        if nmap > 0 and map_on() then
            local parts = map_pack(p.map)
            for i, s in ipairs(parts) do net.send_to(r.pc, "PSMAPSET", p.gen, tostring(i), tostring(#parts), s) end
            if not p.map_sent then
                p.map_sent = true
                M.stats.map_sent = M.stats.map_sent + nmap
                log.info("persist: %s: %d saved map location(s) sent to the client (%d message(s))", p.name, nmap, #parts)
            end
        end
    else
        net.send_to(r.pc, "PSFRESH", p.gen, enabled() and "1" or "0")
    end
end

local function decide(r, p)
    p.gen = new_gen()
    if hs.loaded then hs.loaded.fresh = false end   -- a load after this one is not redundant
    if not enabled() then
        p.verdict, p.off = "fresh", true
        send_verdict(r, p)
        log.info("persist: %s (%s): persist_clients is off, a new character", p.name, p.key)
        return
    end
    local rec, src = find_record(p)
    if not rec then
        p.verdict, p.restore = "fresh", nil
        M.stats.fresh = M.stats.fresh + 1
        send_verdict(r, p)
        quests_bind(r.pc, cur_world_slot(), p.key, false)
        log.info("persist: %s is %s: no record in this world (slot %s): a new character%s", p.name, p.key, cur_world_slot(),
            CM.fresh_note(p.key))
        return
    end
    p.base = rec
    p.prog, p.tree, p.hot = rec.prog, rec.tree, rec.hotbar
    p.map = map_copy(rec.map)   -- a record from before map discoveries were kept: none
    local alive = rec.alive ~= false
    local inv = nil
    if rec.inv then
        local obj = load_blob(rec.inv.slot or cur_world_slot(), p.key, rec.inv)
        if obj then
            inv = rec.inv
        else
            log.err("persist: %s's saved inventory files are missing or damaged%s", p.name,
                rec.inv.list and ": the item list of the record will be used" or "")
            if rec.inv.list then inv = { slot = rec.inv.slot, list = rec.inv.list, containers = -1, items = -1 } end
        end
    end
    p.restore = {
        inv = inv, vitals = alive and rec.vitals or nil, pos = alive and sane_pos(rec.pos) and rec.pos or nil,
        dead = not alive, respawn = rec.respawn,
    }
    p.verdict = "restore"
    send_verdict(r, p)
    quests_bind(r.pc, cur_world_slot(), p.key, true)
    log.info("persist: %s is %s: record from %s%s: %s -> restoring", p.name, p.key, tostring(src), CM.origin(p.key, src),
        describe_rec(rec))
end

local function on_pid(f, pc)
    if not S or S.role ~= "host" then return end
    local pl = players_mod()
    local r = pl and pl.record_for and pl.record_for(pc)
    if not r then return end   -- the session record comes with the next tick; the client repeats
    local p = P[r.key]
    if p and p.gen then
        send_verdict(r, p)   -- answer lost or late: the same verdict again
        return
    end
    -- the game is loading a save (CM.load_started): after it (the client repeats)
    if hs.load_wait and clock() - hs.load_wait < 10 then return end
    -- the save's records still being put back (world just loaded): done now
    if hs.job and hs.job.kind == "reset" then CM.finish_now() end
    local sid, guid = clean_sid(f[1]), clean_guid(f[2])
    local name = (f[3] and f[3] ~= "") and f[3] or r.name
    local key = sid and ("s" .. sid) or (guid and ("g" .. guid)) or nil
    if not key then
        log.warn("persist: %s sent no usable id (%s / %s): this character is not saved", r.name, tostring(f[1]), tostring(f[2]))
        P[r.key] = { name = r.name, nokey = true }
        return
    end
    for k, q in pairs(P) do
        if k ~= r.key and q.key == key then
            if (S.remote or {})[k] then
                log.warn("persist: %s and %s have the same id %s: the second one is not saved", q.name, name, key)
                P[r.key] = { name = name, nokey = true }
                return
            end
            -- back faster than the tick that notices the leave: that first
            on_left(k, q)
        end
    end
    -- an id that comes after the first character spawned (the gate gave up):
    -- the restore still runs, on the character as it is
    p = { key = key, sid = sid, guid = guid, name = name, joined = clock(), late = r.spawned_once == true }
    P[r.key] = p
    decide(r, p)
end

local function on_prog(f, pc, final)
    if not S or S.role ~= "host" then return end
    local pl = players_mod()
    local r = pl and pl.record_for and pl.record_for(pc)
    local p = r and P[r.key]
    if not p or not p.gen or f[1] ~= p.gen then return end
    local prog = progress_mod()
    if prog and prog.decode_values and f[2] and f[2] ~= "" then
        local vals = prog.decode_values(f[2])
        if vals and next(vals) then p.prog = vals end
    end
    if f[3] and f[3] ~= "" and f[3] ~= "?" then p.tree = parse_list(f[3]) end
    if f[4] and f[4] ~= "" and f[4] ~= "?" then p.hot = parse_list(f[4]) end
    -- a level, skill point, kill or skill-tree change is written soon
    -- (host_player), trickling XP with the next write
    local major = ((prog and prog.major_key) and prog.major_key(f[2]) or "") .. "|" .. tostring(f[3])
    if major ~= p.prog_major then p.prog_dirty = true end
    p.prog_major = major
    p.prog_at = clock()
    p.acked = true
    M.stats.prog_reports = M.stats.prog_reports + 1
    if final then log.info("persist: %s's last progression report received", p.name) end
end

-- ---------------------------------------------------------------------------
-- Host: shared map discoveries (map_shared; SHARE above)
-- ---------------------------------------------------------------------------
-- hs.share: union = { [id] = name } every place explored in this world;
-- by = { [id] = { ["host" | player key] = true } } who explored it; own =
-- the host's own explored places (never set by the share); miss /
-- shown_ids / share_logs: the passes over the host's copies. Per player:
-- p.share_has = what that client has (its own places, all sent to it),
-- p.share_gen = the gen its whole list went out with.

function SHARE.host()
    local sh = hs.share
    if not sh then
        sh = { union = {}, by = {}, own = {}, miss = {}, at = 0, due = false, scanned = false }
        hs.share = sh
    end
    return sh
end

-- One explorer of a place; true when the place is new to the union.
function SHARE.learn(sh, id, name, who)
    if not map_id_ok(id) then return false end
    name = map_clean(name)
    local had = sh.union[id]
    if had == nil or (had == "" and name ~= "") then sh.union[id] = name end
    local by = sh.by[id]
    if not by then
        by = {}
        sh.by[id] = by
    end
    by[who] = true
    return had == nil
end

-- What a client has: its saved places (they went out in PSMAPSET when
-- persist_map is on), what it reported, everything sent to it.
function SHARE.has(p)
    if not p.share_has then
        p.share_has = {}
        if map_on() and type(p.map) == "table" then
            for id in pairs(p.map) do p.share_has[id] = true end
        end
    end
    return p.share_has
end

-- Every record of this world: the slot file's, this session's, the players
-- here (memory only: the slot file is read once per world, load_doc caches).
function SHARE.from_records(sh)
    local function take(key, m)
        if type(key) ~= "string" or type(m) ~= "table" then return end
        for id, name in pairs(m) do SHARE.learn(sh, id, name, key) end
    end
    local slot = cur_world_slot()
    if slot ~= NOSLOT then
        for k, rec in pairs(load_doc(slot).players) do
            if type(rec) == "table" then take(k, rec.map) end
        end
    end
    for k, rec in pairs(live) do
        if type(rec) == "table" then take(k, rec.map) end
    end
    for _, p in pairs(P) do
        if p.key then take(p.key, p.map) end
    end
end

-- One client: what it lacks, in MAPSHARE pieces of MAP_CHUNK places (the
-- whole list once per verdict, "full", even when empty; then "add").
function SHARE.send(sh, r, p)
    local has = SHARE.has(p)
    local out, ids = {}, {}
    for id, name in pairs(sh.union) do
        if not has[id] then
            out[id] = name
            ids[#ids + 1] = id
        end
    end
    local full = p.share_gen ~= p.gen
    if #ids == 0 and not full then return end
    local parts = map_pack(out)
    if #parts == 0 then parts = { "" } end
    for i, s in ipairs(parts) do
        if not net.send_to(r.pc, "MAPSHARE", p.gen, tostring(i), tostring(#parts), full and "full" or "add", s) then
            return   -- the whole batch again next pass (the client skips what it has)
        end
    end
    for _, id in ipairs(ids) do has[id] = true end
    p.share_gen = p.gen
    M.stats.share_sent = M.stats.share_sent + #ids
    if not full then
        log.info("persist: map share: %d new place(s) sent to %s: %s", #ids, p.name, map_names(out, ids, 8))
        return
    end
    -- once per join, both ways
    local only = 0
    for _, by in pairs(sh.by) do
        if by[p.key] then
            local alone = true
            for w in pairs(by) do
                if w ~= p.key then
                    alone = false
                    break
                end
            end
            if alone then only = only + 1 end
        end
    end
    log.info("persist: map share with %s (join): %d place(s) explored by others sent to the client (%d message(s));"
        .. " %d place(s) only %s explored are shown to the host and the other players", p.name, #ids, #parts, only, p.name)
end

-- A client's report (PSMAP): new places go to the host's map and the others.
function SHARE.reported(p, got)
    local sh = SHARE.host()
    local has = SHARE.has(p)
    local new = {}
    for id, name in pairs(got) do
        has[id] = true
        if SHARE.learn(sh, id, name, p.key) then new[#new + 1] = id end
    end
    if #new == 0 then return end
    sh.due = true   -- shown here and sent to the others within DUE_S
    log.info("persist: map share: %s explored %d place(s) nobody had: %s", p.name, #new, map_names(got, new, 8))
end

-- Every CHECK_S (DUE_S after a report): the union gathered, the host's own
-- places read (one FindAllOf), the others' shown on the host's copies, each
-- client sent what it lacks. Nothing at all while there is nobody to share
-- with and no other player's place to show.
function SHARE.host_pass(now)
    local sh = SHARE.host()
    if S.in_menu ~= false or not hs.world_seen then return end
    if now - sh.at < (sh.due and SHARE.DUE_S or SHARE.CHECK_S) then return end
    sh.at, sh.due = now, false
    SHARE.from_records(sh)
    local targets = {}
    for skey, r in pairs(S.remote or {}) do
        local p = P[skey]
        if p and p.gen and p.key and ue.valid(r.pc) then targets[#targets + 1] = { r = r, p = p } end
    end
    local others = false
    for id in pairs(sh.union) do
        if not sh.own[id] then
            others = true
            break
        end
    end
    if #targets == 0 and not others then return end
    local pois = own_pois()
    if next(pois) == nil then return end   -- the level is not there (yet)
    -- the host's own explored places: the save's at the first pass, then new ones
    local fresh, found = {}, {}
    for id, a in pairs(pois) do
        if not sh.own[id] and ue.prop(a, "Explored?") == true then
            sh.own[id] = true
            if SHARE.learn(sh, id, poi_name(a), "host") then
                fresh[#fresh + 1] = id
            elseif sh.shown_ids and sh.shown_ids[id] then
                found[#found + 1] = id
            end
        end
    end
    if #fresh > 0 then
        if sh.scanned then
            log.info("persist: map share: the host explored %d new place(s): %s", #fresh, map_names(sh.union, fresh, 8))
        else
            log.info("persist: map share: the host has %d explored place(s) of its own", #fresh)
        end
    end
    if #found > 0 then
        M.stats.share_found = M.stats.share_found + #found
        -- the full marker (sdc_poimarks' hook on the game's event usually did it already)
        local full = 0
        for _, id in ipairs(found) do
            if poimarks.undim(ue.prop(pois[id], "Marker"), true) then full = full + 1 end
        end
        log.info("persist: map share: the host explored %d place(s) itself that it had been shown from other players"
            .. " (the game's own discovery: Explored?, XP, toast, the full marker%s): %s", #found,
            full > 0 and string.format("; %d undimmed by this pass", full) or "", map_names(sh.union, found, 8))
    end
    sh.scanned = true
    -- the other players' places on the host's own copies (never Explored?)
    local res = SHARE.apply(pois, sh.union, sh.own, sh.miss)
    SHARE.note(sh, "other players", res, sh.union)
    for _, t in ipairs(targets) do SHARE.send(sh, t.r, t.p) end
end

-- PSMAP: places the client discovered (its own BP_POIManager copies). Only
-- ever added to the record: a discovered place stays discovered. A 3rd
-- field "nosave": the client keeps no map discoveries (its persist_map is
-- off), the report is for map_shared only.
local function on_map(f, pc)
    if not S or S.role ~= "host" or not (map_on() or SHARE.on()) then return end
    local pl = players_mod()
    local r = pl and pl.record_for and pl.record_for(pc)
    local p = r and P[r.key]
    if not p or not p.gen or f[1] ~= p.gen then return end
    local got = map_unpack(f[2])
    if SHARE.on() and p.key then SHARE.reported(p, got) end
    if not map_on() or f[3] == "nosave" then return end
    p.map = p.map or {}
    local new = {}
    for id, name in pairs(got) do
        local had = p.map[id]
        if had == nil then new[#new + 1] = id end
        if had == nil or (had == "" and name ~= "") then p.map[id] = name end
    end
    M.stats.map_reports = M.stats.map_reports + 1
    if #new == 0 then return end
    M.stats.map_new = M.stats.map_new + #new
    p.map_dirty = true   -- written within PROG_WRITE_S (host_player)
    log.info("persist: %s: %d new map location(s) recorded: %s (%d in total)", p.name, #new, map_names(p.map, new),
        map_count(p.map))
end

local function on_ready(f, pc)
    if not S or S.role ~= "host" then return end
    local pl = players_mod()
    local r = pl and pl.record_for and pl.record_for(pc)
    local p = r and P[r.key]
    if not p or not p.gen or f[1] ~= p.gen then return end
    p.ready = true
    if p.restore and p.restore.done and ue.valid(r.pc) then
        net.send_to(r.pc, "PSDONE", p.gen, "-", "-")
    end
end

-- ---------------------------------------------------------------------------
-- Host: hooks for sdc_players (see its PERSIST_HOOKS)
-- ---------------------------------------------------------------------------

-- May the player's first character spawn now? Waits for the id (PSID).
function M.gate(r, now)
    if not S or S.role ~= "host" then return true end
    local p = P[r.key]
    if p and (p.gen or p.nokey) then return true end
    if (now or clock()) - (r.joined_at or clock()) >= PID_WAIT_S then
        if not p then
            P[r.key] = { name = r.name, nokey = true }
            -- not a loss: a later PSID still restores and saves (on_id "late");
            -- only a client with no mod / an older mod never sends one
            log.info("persist: no id from %s within %d s (still loading?): its first character spawns now; "
                .. "its saved record is applied when the id comes (an older mod never sends one)", r.name, PID_WAIT_S)
        end
        return true
    end
    return false
end

-- Spot of the first character: where the player left (alive), or a dead
-- player's bed / sleeping bag.
function M.join_point(r)
    local p = P[r.key]
    local rs = p and p.restore
    if not rs then return nil end
    if rs.pos and cfg.get("persist_restore_position") ~= false then
        p.fall = { z = rs.pos.z, at = nil }
        return { loc = { X = rs.pos.x, Y = rs.pos.y, Z = rs.pos.z + 30 }, yaw = rs.pos.yaw or 0 }
    end
    local rp = rs.respawn
    if rs.dead and rp and rp.en and rp.t and sane_pos(rp.t) then
        p.fall = { z = rp.t.z, at = nil }
        return { loc = { X = rp.t.x, Y = rp.t.y, Z = rp.t.z + 60 }, yaw = yaw_of_quat(rp.q) }
    end
    return nil
end

-- false: the saved inventory replaces the starting kit.
function M.starting_items(r)
    local p = P[r.key]
    if p and p.restore and p.restore.inv then return false end
    return nil
end

-- sdc_progress: the host's copy of this controller is restored here.
function M.host_owns(session_key)
    local p = P[session_key]
    return p ~= nil and p.verdict == "restore"
end

-- sdc_session (connection chip): the SteamID64 this player sent, nil when
-- not known yet or the player has none.
function M.steam_of(session_key)
    local p = P[session_key]
    return p and p.sid or nil
end

local function install_player_hooks()
    local pl = players_mod()
    if not pl then return end
    if pl.PERSIST_HOOKS then
        pl.persist_gate, pl.join_point, pl.starting_items = M.gate, M.join_point, M.starting_items
    end
    if not hs.integration_logged then
        hs.integration_logged = true
        if pl.PERSIST_HOOKS then
            log.info("persist: sdc_players hooks in (id gate, saved spot, no starting kit on restore)")
        else
            log.warn("persist: sdc_players has no PERSIST_HOOKS: returning players spawn next to the host with the starting kit, then get their inventory")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: game hooks (save, delete)
-- ---------------------------------------------------------------------------

local function on_host_save(why)
    hs.save_pending = false
    if not S or S.role ~= "host" or not enabled() then return end
    CM.finish_now()   -- a load / commit job still running: its files first
    local slot, err = ue.ems_current_slot()
    local named = not (not slot or slot == "" or slot == TEMP_SLOT)
    if not named then
        log.warn("persist: the game saved, but the slot name is %s: records stay with slot %s (and are not committed:"
            .. " that slot was not the one saved)",
            slot == TEMP_SLOT and "the throwaway slot" or ("unknown (" .. tostring(err) .. ")"), cur_world_slot())
        slot = cur_world_slot()
    end
    local from = cur_world_slot()
    hs.world_slot = slot
    M.stats.host_saves = M.stats.host_saves + 1
    hs.last_save = os.date("%H:%M:%S") .. " " .. slot
    -- what the players have right now, written into the slot being saved
    local now = clock()
    for key, r in pairs(S.remote or {}) do
        local p = P[key]
        if p and p.key and p.restored and ue.valid(r.pc) then
            local pawn = ue.pawn_of(r.pc)
            light_snapshot(r, p, pawn, now)
            inv_check(r, p, pawn, now, true, "game save")
            p.last_why = "game save"
            -- their own quests into the slot being saved (it may be a new one)
            quests_bind(r.pc, slot, p.key, false)
            local q = quests_mod()
            if q and q.persist_save then pcall(q.persist_save, r.pc, "game save") end
        end
    end
    flush(slot, "game save" .. (why and (" " .. why) or ""), from ~= slot and from or nil)
    if from ~= slot then
        log.info("persist: the game saved to slot %s (this world came from %s): records moved along", slot, from)
    end
    -- these records are this save's once the game reports it done (persist_follow_host_save)
    if named then CM.save_started(slot, "game save" .. (why and (" " .. why) or ""), from ~= slot and from or nil) end
end

local function on_delete_slot(name_p)
    local slot = ue.str(name_p and name_p:get())
    if slot == "" or slot == NOSLOT or slot == TEMP_SLOT then return end
    local main, bak, tmp = doc_paths(slot)
    local cmain, cbak = CM.paths(slot)
    if not main or not (file_exists(main) or file_exists(bak) or file_exists(cmain) or file_exists(cbak)) then return end
    CM.cancel(slot)
    local doc = load_doc(slot, true)
    local keys = {}
    for k in pairs(doc.players) do keys[k] = true end
    -- the committed copies (persist_follow_host_save) and their players' files
    local nc = CM.delete_slot(slot, keys)
    local n = 0
    for k in pairs(keys) do
        delete_blobs(slot, k)
        os.remove(blob_path(CM.qname(slot, k) .. "_bak"))
        os.remove(blob_path(CM.qname(slot, k) .. "_tmp"))
        local q = quests_mod()
        if q and q.persist_delete then pcall(q.persist_delete, slot, k) end
        n = n + 1
    end
    os.remove(main)
    os.remove(bak)
    os.remove(tmp)
    docs[slot] = nil
    M.stats.deleted_slots = M.stats.deleted_slots + 1
    log.info("persist: save slot %s deleted by the game: its %d player record(s) and inventory files deleted too%s", slot, n,
        nc > 0 and string.format(" (with %d committed record(s) and their files)", nc) or "")
end

-- Both hooks of one save (the controller's SaveGameToSlot and EMS's
-- AsyncSaveActors inside it) give one write, 50 ms later (out of the
-- game's own call; sdc_savecheck's pre-save slot fix has run by then).
local function schedule_save(why)
    if not S or S.role ~= "host" or hs.save_pending then return end
    hs.save_pending = true
    ue.delay("persist-save", 50, function() on_host_save(why) end)
end

local function install_game_hooks()
    local h = hs.hooks
    if not h.save and ue.find_object(SAVE_FN) then
        h.save = true
        -- Blueprint function: one callback, after the body (the async EMS
        -- save has started; the slot name is set). Every save of the game
        -- ends here (autosave, quick save key, pause menu, save menu, sleep).
        local ok, err = pcall(RegisterHook, SAVE_FN, function(ctx_p)
            local okc, e = pcall(function()
                if not S or S.role ~= "host" then return end
                schedule_save("(" .. ue.short(ctx_p and ctx_p:get()) .. ")")
            end)
            if not okc then log.err_throttled("persist-savehook", "persist: save hook: %s", tostring(e)) end
        end)
        log.info("persist: game save hook (SaveGameToSlot, post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    if not h.ems_save and ue.find_object(EMS_SAVE_FN) then
        h.ems_save = true
        -- native static function (any EMS actor save, whoever starts it):
        -- post (Context, ReturnValue, WorldContextObject, Data)
        local ok, err = pcall(RegisterHook, EMS_SAVE_FN, function() end, function()
            local okc, e = pcall(schedule_save, "(EMS AsyncSaveActors)")
            if not okc then log.err_throttled("persist-emssave", "persist: EMS save hook: %s", tostring(e)) end
        end)
        log.info("persist: EMS save hook (AsyncSaveActors, post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    -- The game's "actors saved" / "could not save" of the host's own save
    -- (Blueprint, post): the clients' records of that save are committed /
    -- not (CM.save_end), out of the game's call.
    local function own_save(ctx_p)
        if not S or S.role ~= "host" then return false end
        local pc = ctx_p and ctx_p:get()
        if not ue.valid(pc) then return true end
        local okl, isl = pcall(function() return pc:IsLocalController() end)
        return not okl or isl ~= false
    end
    if not h.saved and ue.find_object(SAVED_FN) then
        h.saved = true
        local ok = pcall(RegisterHook, SAVED_FN, function(ctx_p)
            local okc, e = pcall(function()
                if not own_save(ctx_p) then return end
                log.info("persist: the game's save finished (slot %s)", cur_world_slot())
                ue.delay("persist-saved", 50, function() CM.save_end(true) end)
            end)
            if not okc then log.err_throttled("persist-savedhook", "persist: save end hook: %s", tostring(e)) end
        end)
        h.saved_ok = ok == true
    end
    if not h.failed and ue.find_object(SAVE_FAILED_FN) then
        h.failed = true
        pcall(RegisterHook, SAVE_FAILED_FN, function(ctx_p)
            local okc, e = pcall(function()
                if not own_save(ctx_p) then return end
                log.warn("persist: the game's save FAILED (slot %s); the player records were written anyway", cur_world_slot())
                ue.delay("persist-saved", 50, function() CM.save_end(false, "EMS could not save the actors") end)
            end)
            if not okc then log.err_throttled("persist-failhook", "persist: save failed hook: %s", tostring(e)) end
        end)
    end
    if not h.load and ue.find_object(CM.LOAD_FN) then
        h.load = true
        -- native static: pre (Context, WorldContextObject, ...): a load of
        -- the game, also during the session (CM.load_started)
        local ok, err = pcall(RegisterHook, CM.LOAD_FN, function(_, wco_p)
            local okc, e = pcall(CM.load_started, wco_p)
            if not okc then log.err_throttled("persist-loadhook", "persist: load hook: %s", tostring(e)) end
        end, function() end)
        log.info("persist: game load hook (EMS AsyncLoadActors, pre) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    if not h.delete and ue.find_object(DELETE_FN) then
        h.delete = true
        -- native: pre (Context, WorldContextObject, SaveGameName, UserIndex)
        local ok, err = pcall(RegisterHook, DELETE_FN, function(_, _, name_p)
            local okc, e = pcall(on_delete_slot, name_p)
            if not okc then log.err_throttled("persist-delete", "persist: slot delete hook: %s", tostring(e)) end
        end, function() end)
        log.info("persist: slot delete hook (EMS DeleteAllSaveDataForSlot, pre) %s%s", ok and "ok" or "FAILED",
            ok and "" or (" " .. tostring(err)))
    end
end

-- ---------------------------------------------------------------------------
-- Host tick
-- ---------------------------------------------------------------------------

on_left = function(skey, p)
    P[skey] = nil
    if not p.key then return end
    M.stats.leaves = M.stats.leaves + 1
    if not p.restored then
        -- left before the character was restored / ever played: whatever was
        -- saved stays as it was
        if p.base then live[p.key] = p.base end
        log.info("persist: %s left before the character was ready: %s", p.name,
            p.base and "the saved record is kept unchanged" or "nothing to save")
        return
    end
    live[p.key] = make_record(p, "left")
    if enabled() then flush(cur_world_slot(), p.name .. " left") end
    log.info("persist: %s left: %s", p.name, describe_rec(live[p.key]))
end

local function host_player(r, p, now)
    local pawn = ue.pawn_of(r.pc)
    -- restore steps
    local rs = p.restore
    if rs and not rs.host_done and pawn and r.spawned_once then
        rs.host_done, rs.spawned_at = true, now
        local ok, err = pcall(apply_host_copy, r, p)
        if not ok then log.err("persist: %s host copy: %s", p.name, tostring(err)) end
        if p.fall then p.fall.at = now + FALL_CHECK_S end
        if not rs.inv and not rs.vitals then
            rs.done, p.restored = true, true
            M.stats.restores = M.stats.restores + 1
            net.send_to(r.pc, "PSDONE", p.gen, "-", "0")
        end
    end
    if rs and rs.host_done and not rs.done then
        if p.ready then
            restore_character(r, p, pawn, "client ready")
        elseif now - rs.spawned_at >= READY_WAIT_S then
            restore_character(r, p, pawn, "no PSRDY from the client in " .. READY_WAIT_S .. " s")
        end
    end
    if not rs and pawn and r.spawned_once and not p.restored then p.restored = true end
    -- a character put at its saved spot that is falling through the world
    if p.fall and p.fall.at and now >= p.fall.at then
        local z0 = p.fall.z
        p.fall = nil
        local loc = pawn and ue.location(pawn)
        if loc and loc.Z < z0 - 1500 then
            local pl = players_mod()
            local spot, yaw = pl and pl.helpers and pl.helpers.near_host_spot(r.index or 1, 1)
            if spot then
                net.send_to(r.pc, "UNSTUCKTO", string.format("%.0f", spot.X), string.format("%.0f", spot.Y),
                    string.format("%.0f", spot.Z), string.format("%.0f", yaw or 0), "host")
                if cfg.get("client_movement_authority") == false then ue.teleport(pawn, spot) end
                log.warn("persist: %s fell from the saved spot (z %.0f -> %.0f): moved next to the host", p.name, z0, loc.Z)
            end
        end
    end
    if not p.restored then return end
    -- gathering
    if now - (p.snap_at or 0) >= LIGHT_S then
        p.snap_at = now
        local died = light_snapshot(r, p, pawn, now)
        if died then
            log.info("persist: %s died", p.name)
            inv_check(r, p, pawn, now, true, "death")
            p.keep_check = now + 4
            p.last_why = "death"
            if enabled() then flush(cur_world_slot(), p.name .. " died") end
        end
    end
    if p.keep_check and now >= p.keep_check then
        p.keep_check = nil
        if keep_inventory_on() and inv_check(r, p, pawn, now, false, "kept through death") then
            p.last_why = "death"
            if enabled() then flush(cur_world_slot(), p.name .. " died (kept inventory)") end
        end
    end
    if now - (p.inv_at or 0) >= INV_CHECK_S then
        if inv_check(r, p, pawn, now, false, "inventory changed") then
            p.last_why = "inventory changed"
            if enabled() then flush(cur_world_slot(), p.name .. "'s inventory changed") end
        end
    end
    if p.prog_dirty and now - (p.flushed_at or 0) >= PROG_WRITE_S then
        p.last_why = "progression"
        if enabled() then flush(cur_world_slot(), p.name .. "'s level / skills changed") end
        p.prog_dirty = false
    end
    if p.map_dirty and now - (p.flushed_at or 0) >= PROG_WRITE_S then
        p.last_why = "map discovery"
        if enabled() then flush(cur_world_slot(), p.name .. " discovered a map location") end
        p.map_dirty = false
    end
end

local function host_tick(now)
    install_game_hooks()
    install_player_hooks()
    -- a running commit / load job (it also steps itself every STEP_MS); one
    -- started below waits for its own timer
    if hs.job then CM.step(hs.job) end
    -- players who stayed connected through a load of the game
    if hs.redo then CM.redo_tick(decide) end
    -- the world's own slot: the one it was loaded from (the save menu changes
    -- EMS's current name while the player only browses)
    if not hs.world_seen and S.in_menu == false then
        hs.world_seen = true
        hs.world_slot = world_slot_of(ue.ems_current_slot())
        local n, ldoc = 0, nil
        if hs.world_slot ~= NOSLOT then
            ldoc = load_doc(hs.world_slot, true)
            for _ in pairs(ldoc.players) do n = n + 1 end
        end
        log.info("persist: this world's slot is %s (%d saved player record(s))", hs.world_slot, n)
        -- loaded from that slot: the clients go back to its save (persist_follow_host_save)
        if ldoc then
            local okw, werr = pcall(CM.world_loaded, hs.world_slot, ldoc)
            if not okw then log.err("persist: putting the save's client records back (slot %s): %s", hs.world_slot, tostring(werr)) end
        end
    end
    CM.wait_tick(now)
    for skey, r in pairs(S.remote or {}) do
        local p = P[skey]
        if p and p.key and not p.off and ue.valid(r.pc) then
            p.name = r.name or p.name
            local ok, err = pcall(host_player, r, p, now)
            if not ok then log.err_throttled("persist-player-" .. skey, "persist: %s: %s", tostring(p.name), tostring(err)) end
        end
    end
    for skey, p in pairs(P) do
        if not (S.remote or {})[skey] then on_left(skey, p) end
    end
    local per = period_s()
    if per > 0 and enabled() and now - hs.last_period >= per then
        hs.last_period = now
        local n = 0
        for skey, r in pairs(S.remote or {}) do
            local p = P[skey]
            if p and p.key and p.restored and ue.valid(r.pc) then
                local pawn = ue.pawn_of(r.pc)
                light_snapshot(r, p, pawn, now)
                inv_check(r, p, pawn, now, false, "periodic")
                p.last_why = "periodic"
                n = n + 1
            end
        end
        if n > 0 then
            M.stats.periodic = M.stats.periodic + 1
            flush(cur_world_slot(), "periodic")
        end
    end
    -- shared map discoveries (map_shared)
    if SHARE.on() then
        local oks, serr = pcall(SHARE.host_pass, now)
        if not oks then log.err_throttled("persist-share", "persist: map share: %s", tostring(serr)) end
    end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local C = { conn = nil }

-- This player's own id (for hosts that cannot see a SteamID): made once,
-- kept in config.ini (persist_player_id), or in player_id.txt next to it.
local guid_cache = nil
local function own_guid()
    if guid_cache then return guid_cache end
    local g = clean_guid(cfg.get("persist_player_id"))
    local idfile = cfg.path and (tostring(cfg.path):gsub("[^/\\]+$", "") .. "player_id.txt") or nil
    if not g and idfile then g = clean_guid((read_file(idfile) or ""):match("%x+")) end
    local made = false
    if not g then
        local seed = tostring({}):match("0x(%x+)") or ""
        local parts = {}
        for i = 1, 4 do
            parts[i] = string.format("%08x", (math.random(0, 0x7fffffff) + os.time() * (i + 7)
                + math.floor(os.clock() * 1e6) + (tonumber(seed:sub(-6), 16) or 0)) % 0x100000000)
        end
        g, made = table.concat(parts), true
    end
    if clean_guid(cfg.get("persist_player_id")) ~= g then
        cfg.set("persist_player_id", g)
        if cfg.get("persist_player_id") == g then
            cfg.save()
        elseif idfile and not file_exists(idfile) then
            write_file(idfile, g .. "\n")
        end
    end
    guid_cache = g
    if made then log.info("persist: this player's id for hosts' saves: g%s (made now, kept in config / player_id.txt)", g) end
    return g
end

local function read_hotbar(pawn)
    local ui = ue.prop(pawn, "InGameUI")
    if not ue.valid(ui) then return "?" end
    local out = {}
    for i = 1, 3 do
        local c = ue.prop(ui, "JSIContainer_Consumable" .. i)
        local g = "0:0:0:0"
        if ue.valid(c) then
            local f, ref, pend = {}, {}, {}
            local ok = pcall(function() c:GetEquippedItemRef(f, ref, pend) end)
            local item = ok and ref.ItemRef
            if ok and f["Found?"] == true and ue.valid(item) then
                g = ue.try(function() return guid_str(item.ItemUniqueID) end) or g
            end
        end
        out[i] = g
    end
    return table.concat(out, ",")
end

-- sdc_progress: the record (or "new character") is applied on this client.
function M.client_applied(gen, kind)
    if C.gen and gen == C.gen then
        C.applied, C.applied_kind = gen, kind
        C.map_at = 0   -- the saved map discoveries go on at the next tick
    end
end

local function client_progress_line(pc, pawn)
    local prog = progress_mod()
    local tree = skilltree_mod()
    local vals = (prog and prog.read_values and prog.encode_values) and prog.encode_values(prog.read_values(pc)) or ""
    local tlist = "?"
    local tech = ue.prop(pc, "TechTreeComponent")
    if tree and tree.unlocked and ue.valid(tech) then
        local okl, l = pcall(tree.unlocked, tech)
        if okl and type(l) == "table" then tlist = #l > 0 and table.concat(l, ",") or "-" end
    end
    local hot = pawn and read_hotbar(pawn) or "?"
    return vals, tlist, hot
end

-- (own_pois / poi_name: with the map helpers above)

-- A place known from the save, the way the game's load gives it back
-- (BP_POIManager.ActorLoaded @10238 -> 8332): Explored? (the SaveGame
-- property) set; the distance check stopped at once (K2_ClearTimer
-- "DistanceCheck", as 8393 does: no second discovery toast / XP while the
-- load event waits); then the load event itself, which 5 s later shows the
-- map marker (Marker.POIExplored -> W_POIMarker.EventExplored). A marker
-- made later (minimap built, respawn: RespawnMarker) reads Explored? itself.
local function explore_poi(a)
    if not ue.set_prop(a, "Explored?", true) then return false end
    local ksl = ue.ksl()
    if ksl then pcall(function() ksl:K2_ClearTimer(a, "DistanceCheck") end) end
    pcall(function() a:ActorLoaded() end)
    return ue.prop(a, "Explored?") == true
end

-- The saved places (PSMAPSET) set on this client's POIs. Matched by actor
-- name; a name a game update changed: the POI with the same place name, if
-- only one has it.
local function client_map_restore(pois)
    local want = C.map_want
    local by_name = nil
    local set, already, gone = {}, {}, {}
    for id, name in pairs(want) do
        local a = pois[id]
        if not a and name ~= "" then
            if not by_name then
                by_name = {}
                for _, pa in pairs(pois) do
                    local pn = poi_name(pa)
                    if pn ~= "" then by_name[pn] = (by_name[pn] == nil) and pa or false end
                end
            end
            a = by_name[name] or nil
        end
        if a then
            want[id] = nil
            if ue.prop(a, "Explored?") == true then
                already[#already + 1] = id
            elseif explore_poi(a) then
                set[#set + 1] = id
            else
                gone[#gone + 1] = id
            end
        else
            C.map_miss[id] = (C.map_miss[id] or 0) + 1
            if C.map_miss[id] >= MAP_MISS_TRIES then
                want[id] = nil
                gone[#gone + 1] = id
            end
        end
    end
    local n = #set + #already
    local gone_s = #gone > 0 and map_names(C.map_known, gone) or ""
    if n == 0 then
        if #gone > 0 then
            log.warn("persist: %s: %d saved map location(s) NOT set (not in this world?): %s", cfg.player_name(), #gone, gone_s)
        end
        return
    end
    M.stats.map_restored = M.stats.map_restored + #set
    local ids = {}
    for _, id in ipairs(set) do ids[#ids + 1] = id end
    for _, id in ipairs(already) do ids[#ids + 1] = id end
    log.info("persist: %s: %d map location(s) restored (%d set now, %d already discovered here%s): %s", cfg.player_name(),
        n, #set, #already, #gone > 0 and string.format(", %d NOT set (not in this world?): %s", #gone, gone_s) or "",
        map_names(C.map_known, ids))
    if not C.map_toast then
        C.map_toast = true
        log.say("persist_map_client", "ok", 6, tostring(n))
    end
end

-- Places other players explored (MAPSHARE), shown on this client's map
-- without being explored here (SHARE.mark). A place this player explored
-- itself meanwhile is its own: client_map reports it as a discovery.
function SHARE.client_apply(pois)
    C.share_miss = C.share_miss or {}
    for id in pairs(C.share) do
        if C.map_known[id] ~= nil then C.share[id] = nil end   -- this player's own (saved / reported)
    end
    local res = SHARE.apply(pois, C.share, nil, C.share_miss)
    SHARE.note(C, "other players", res, C.share)
    for _, id in ipairs(res.gone) do C.share[id] = nil end
end

-- Map discoveries on this client: the saved ones set, the shared ones
-- shown, new ones reported.
local function client_map()
    local pois = own_pois()
    if next(pois) == nil then return end   -- not in the world (yet)
    C.map_known, C.map_miss = C.map_known or {}, C.map_miss or {}
    if map_on() and C.map_want and next(C.map_want) then client_map_restore(pois) end
    if SHARE.on() and C.share and next(C.share) then SHARE.client_apply(pois) end
    -- places this player discovered that the host does not have yet
    local new, ids = {}, {}
    for id, a in pairs(pois) do
        if C.map_known[id] == nil and ue.prop(a, "Explored?") == true then
            new[id] = poi_name(a)
            ids[#ids + 1] = id
        end
    end
    if #ids == 0 then return end
    for _, s in ipairs(map_pack(new)) do
        -- persist_map off here: for map_shared only, the host keeps nothing
        local ok
        if map_on() then ok = net.send_to_host("PSMAP", C.gen, s) else ok = net.send_to_host("PSMAP", C.gen, s, "nosave") end
        if not ok then return end   -- tried again next time
    end
    local shared, full = 0, 0
    for id, name in pairs(new) do
        C.map_known[id] = name
        if C.share and C.share[id] ~= nil then
            C.share[id] = nil
            shared = shared + 1
            -- the full marker (sdc_poimarks' hook on the game's event usually did it already)
            if poimarks.undim(ue.prop(pois[id], "Marker"), true) then full = full + 1 end
        end
    end
    M.stats.share_found = M.stats.share_found + shared
    log.info("persist: %d new map location(s) discovered here, sent to the host: %s%s", #ids, map_names(new, ids),
        shared > 0 and string.format(" (%d of them had been shown from other players: explored here by the game's own"
            .. " distance check now, the full marker%s)", shared,
            full > 0 and string.format("; %d undimmed by this pass", full) or "") or "")
end

local function client_tick(now)
    if S.client ~= C.conn then
        C = { conn = S.client, pid_n = 0 }
    end
    if ue.in_main_menu() then return end
    local pc = ue.local_pc()
    if not pc then return end
    if not C.gen and C.pid_n < CLIENT_PID_MAX and (not C.pid_at or now - C.pid_at >= CLIENT_PID_EVERY) then
        C.first_try = C.first_try or now
        local steam = package.loaded["sdc_steam"]
        local sid = steam and steam.own_id and steam.own_id() or nil
        if sid or now - C.first_try >= 3 then
            if net.send_to_host("PSID", sid or "-", own_guid(), cfg.player_name()) then
                C.pid_n, C.pid_at = C.pid_n + 1, now
                C.first_pid = C.first_pid or now
                if C.pid_n == 1 then log.info("persist: own id sent to the host (%s)", sid and ("Steam " .. sid) or "no Steam") end
            end
        end
    end
    if not C.gen or C.applied ~= C.gen then return end
    local pawn = ue.pawn_of(pc)
    if not C.acked then
        C.acked = true
        log.info("persist: the host's record is applied (%s); reporting progression from now on", tostring(C.applied_kind))
    end
    -- map discoveries: the saved ones set (once the record is applied), the
    -- shared ones shown, new ones reported
    if pawn and (map_on() or SHARE.on()) and now - (C.map_at or 0) >= CLIENT_MAP_CHECK then
        C.map_at = now
        local okm, merr = pcall(client_map)
        if not okm then log.err_throttled("persist-map", "persist: map discoveries: %s", tostring(merr)) end
    end
    -- the host restores health / inventory once this character's HUD is up
    if C.want_ready and not C.done and (C.ready_n or 0) < 12 and now - (C.ready_at or 0) >= CLIENT_READY_EVERY then
        if pawn and ue.valid(ue.prop(pawn, "InGameUI")) and ue.prop(pawn, "PlayerDead?") ~= true then
            if C.clear_ui and not C.cleared then
                -- the character came with the starting kit (older host): the
                -- game's own load clears the inventory UI first (Event_LoadPlayer)
                C.cleared = true
                pcall(function() pawn.BP_JigMultiplayer:ClearJSIItems() end)
                pcall(function() pawn.InGameUI:ClearContainers() end)
                log.info("persist: inventory UI cleared for the host's restore (the game's load order)")
            end
            net.send_to_host("PSRDY", C.gen)
            C.ready_n, C.ready_at = (C.ready_n or 0) + 1, now
        end
    end
    if now - (C.prog_check or 0) < CLIENT_PROG_CHECK then return end
    C.prog_check = now
    local ok, vals, tlist, hot = pcall(client_progress_line, pc, pawn)
    if not ok then
        log.err_throttled("persist-prog", "persist: reading own progression: %s", tostring(vals))
        return
    end
    local prog = progress_mod()
    local major = (prog and prog.major_key and prog.major_key(vals) or "") .. "|" .. tlist .. "|" .. hot
    local full = vals .. "|" .. tlist .. "|" .. hot
    local send = false
    if C.last_major ~= major then send = true
    elseif C.last_full ~= full and now - (C.prog_at or 0) >= CLIENT_PROG_MINOR_S then send = true
    elseif now - (C.prog_at or 0) >= CLIENT_PROG_RESEND_S then send = true end
    if send and net.send_to_host("PSPROG", C.gen, vals, tlist, hot) then
        C.last_major, C.last_full, C.prog_at = major, full, now
    end
end

local function on_set(f)
    if not S or S.role ~= "client" then return end
    if C.gen and C.gen == f[1] then return end   -- the same answer again (two PSID crossed it)
    local prog = progress_mod()
    local vals = (prog and prog.decode_values) and prog.decode_values(f[2] or "") or {}
    local flags = {}
    for x in tostring(f[5] or ""):gmatch("[^,]+") do flags[x] = true end
    C.gen, C.verdict_at = f[1], clock()
    C.want_ready, C.clear_ui = true, flags.clear == true
    C.done, C.ready_n, C.ready_at, C.cleared = nil, nil, nil, nil   -- a 2nd verdict (the host loaded a save): its own restore
    C.map_want, C.map_known, C.map_miss, C.map_toast = nil, {}, {}, nil   -- PSMAPSET follows (if any)
    C.share, C.share_miss, C.share_full_n = nil, nil, nil                 -- MAPSHARE follows (map_shared)
    local v = { kind = "restore", gen = f[1], vals = vals, tree = parse_list(f[3]), respawn = parse_respawn(f[4]),
                inv = flags.inv == true, dead = flags.dead == true, conn = S.client }
    log.info("persist: the host has this player's character (level %s, %d skill(s)%s%s)",
        tostring(vals.L and vals.L.CurrentLevel or "?"), #v.tree, v.inv and ", inventory" or "", v.dead and ", was dead" or "")
    if prog and prog.set_verdict then prog.set_verdict(v) else M.client_applied(f[1], "restore") end
end

local function on_fresh(f)
    if not S or S.role ~= "client" then return end
    if C.gen and C.gen == f[1] then return end
    C.gen, C.verdict_at, C.want_ready = f[1], clock(), false
    C.done, C.ready_n, C.ready_at, C.cleared = nil, nil, nil, nil
    C.map_want, C.map_known, C.map_miss, C.map_toast = nil, {}, {}, nil
    C.share, C.share_miss, C.share_full_n = nil, nil, nil
    log.info("persist: the host has no saved character of this player%s", f[2] == "0" and " (saving is off there)" or "")
    local prog = progress_mod()
    local v = { kind = "fresh", gen = f[1], conn = S.client, saving = f[2] ~= "0" }
    if prog and prog.set_verdict then prog.set_verdict(v) else M.client_applied(f[1], "fresh") end
end

-- The restored weapons reach this client fitted: their modules' effects
-- (sight, suppressor, muzzle brake) are set up by sdc_gearfx's refit when
-- each weapon begins play here; these passes catch weapons that came before
-- that hook was in. Nothing is kept across the delay but the connection.
local function schedule_refit(conn)
    for _, ms in ipairs(REFIT_AFTER_MS) do
        ue.delay("persist-refit", ms, function()
            if not S or S.role ~= "client" or S.client ~= conn then return end
            local gearfx = package.loaded["sdc_gearfx"]
            if gearfx and gearfx.refit_own then gearfx.refit_own(string.format("%d s after the host's restore", ms // 1000)) end
        end)
    end
end

local function on_done(f)
    if not S or S.role ~= "client" or f[1] ~= C.gen or C.done then return end
    C.done = true
    log.info("persist: the host finished restoring this character (items %s)", tostring(f[3]))
    if f[3] and f[3] ~= "-" and f[3] ~= "0" then
        log.say("persist_inv_client", "ok", 6, f[3])
        schedule_refit(S.client)
    end
end

-- PSMAPSET gen, part, parts, "actor=name;...": the places this player had
-- discovered in this world (set by client_map once the record is applied).
local function on_mapset(f)
    if not S or S.role ~= "client" or not C.gen or f[1] ~= C.gen then return end
    C.map_want = C.map_want or {}
    C.map_known = C.map_known or {}
    local got = map_unpack(f[4])
    for id, name in pairs(got) do
        if C.map_known[id] == nil then C.map_want[id] = name end
        C.map_known[id] = name
    end
    if f[2] == f[3] then
        log.info("persist: the host has %d discovered map location(s) of this player", map_count(C.map_known))
    end
end

-- MAPSHARE gen, part, parts, "full" | "add", "actor=name;...": places other
-- players explored (the host's own, the other clients', every saved
-- record's) - shown by client_map without being explored here (map_shared).
local function on_mapshare(f)
    if not S or S.role ~= "client" or not C.gen or f[1] ~= C.gen then return end
    if not SHARE.on() then
        if not C.share_off then
            C.share_off = true
            log.info("persist: map share: the host shares explored map places; map_shared is off here: not shown")
        end
        return
    end
    C.share = C.share or {}
    local got = map_unpack(f[5])
    local ids = {}
    for id, name in pairs(got) do
        if C.share[id] == nil and not (C.map_known and C.map_known[id] ~= nil) then
            C.share[id] = name
            ids[#ids + 1] = id
        end
    end
    M.stats.share_got = M.stats.share_got + #ids
    if f[4] == "full" then
        C.share_full_n = (C.share_full_n or 0) + #ids
        if f[2] == f[3] then
            log.info("persist: map share (join): the host sent %d place(s) other players explored (%s message(s)):"
                .. " shown on this map, not explored by this player", C.share_full_n, tostring(f[3]))
        end
    elseif #ids > 0 then
        log.info("persist: map share: %d new place(s) other players explored: %s", #ids, map_names(got, ids, 8))
    end
    if #ids > 0 then C.map_at = 0 end   -- shown at the next tick
end

-- sdc_progress: has the host answered (a record or a new character)?
function M.client_verdict_pending(now)
    if C.gen then return false end
    if not C.first_pid then return true end
    return (now or clock()) - C.first_pid < 15
end

-- ---------------------------------------------------------------------------
-- Tick / install / status
-- ---------------------------------------------------------------------------

function M.tick()
    if not S then return end
    local now = clock()
    if S.role == "host" then
        host_tick(now)
    elseif S.role == "client" then
        client_tick(now)
    end
end

-- New world (sdc_session.world_reset_hooks): what the players had is
-- written into the old world's slot (from memory: the old objects are not
-- touched), then everything of the old world is forgotten.
function M.reset(why)
    -- a commit / load job of the old world ends first; a save the game never
    -- reported done is not committed (its slot keeps its last commit)
    CM.finish_now()
    if hs.commit_wait then
        M.stats.commits_dropped = M.stats.commits_dropped + 1
        log.warn("persist: the world closed before the game reported its save of slot %s done: the clients' records"
            .. " are NOT committed", hs.commit_wait.slot)
        hs.commit_wait = nil
    end
    local any = false
    if S and S.role == "host" and enabled() then
        for _, p in pairs(P) do
            if p.key and p.restored then
                p.last_why, any = "world closed", true
            end
        end
    end
    if any then
        local ok, err = pcall(flush, cur_world_slot(), "world closed (" .. tostring(why) .. ")")
        if not ok then log.err("persist: writing the records at the world change: %s", tostring(err)) end
    end
    P, live, docs = {}, {}, {}
    hs.world_slot, hs.world_seen, hs.last_period = nil, false, clock()
    hs.loaded, hs.save_end, hs.redo, hs.load_wait = nil, nil, nil, nil
    hs.share = nil   -- map_shared: the next world gathers its own
    C = { conn = nil }
end

-- Console: save now (host).
function M.save_now(reply)
    if not S or S.role ~= "host" then
        if reply then reply("persist: only the host saves player records") end
        return
    end
    local now = clock()
    local n = 0
    for skey, r in pairs(S.remote or {}) do
        local p = P[skey]
        if p and p.key and p.restored and ue.valid(r.pc) then
            local pawn = ue.pawn_of(r.pc)
            light_snapshot(r, p, pawn, now)
            inv_check(r, p, pawn, now, true, "console")
            p.last_why = "console"
            n = n + 1
        end
    end
    flush(cur_world_slot(), "console")
    if reply then reply(string.format("persist: %d connected player(s) written to slot %s", n, cur_world_slot())) end
end

function M.list(reply)
    reply = reply or function(s) log.info("%s", s) end
    local slot = cur_world_slot()
    reply(string.format("persist: slot %s (file %s)", slot, tostring((doc_paths(slot)))))
    local doc = slot ~= NOSLOT and load_doc(slot) or { players = {} }
    local seen = {}
    for k, r in pairs(live) do seen[k] = true reply(string.format("  %s %s [this session]: %s", k, tostring(r.name), describe_rec(r))) end
    for k, r in pairs(doc.players) do
        if not seen[k] then reply(string.format("  %s %s: %s", k, tostring(r.name), describe_rec(r))) end
    end
    local cdoc = slot ~= NOSLOT and CM.read(slot) or nil
    if cdoc then
        reply(string.format("persist: committed with the save of %s (%s, generation %s): %d record(s) - what a load of this slot gives back%s",
            tostring(cdoc.committed_at), tostring(cdoc.why), tostring(cdoc.gen), CM.count(cdoc.players),
            CM.follow() and "" or " (persist_follow_host_save is off)"))
        for k, r in pairs(cdoc.players) do reply(string.format("  %s %s [save]: %s", k, tostring(r.name), describe_rec(r))) end
    else
        reply("persist: no committed records for this slot yet")
    end
    reply("persist: " .. CM.status())
end

function M.status_line()
    local n, c = 0, 0
    for _ in pairs(live) do n = n + 1 end
    for _, p in pairs(P) do if p.key then c = c + 1 end end
    local s = M.stats
    return string.format("persist: slot=%s records=%d connected=%d restores=%d (inv %d, fallback %d) fresh=%d | writes: docs=%d inv=%d copies=%d errors=%d | game saves=%d last=%s periodic=%d leaves=%d | hooks save=%s ems=%s saved=%s delete=%s | %s | map: recorded=%d sent=%d restored=%d (persist_map=%s) | share: places=%d sent=%d got=%d shown=%d explored_after=%d (map_shared=%s)",
        cur_world_slot(), n, c, s.restores, s.inv_restored, s.inv_fallback, s.fresh, s.docs_written, s.blobs_written,
        s.blobs_copied, s.write_errors, s.host_saves, tostring(hs.last_save), s.periodic, s.leaves,
        tostring(hs.hooks.save == true), tostring(hs.hooks.ems_save == true), tostring(hs.hooks.saved_ok == true),
        tostring(hs.hooks.delete == true), CM.status(),
        s.map_new, s.map_sent, s.map_restored, tostring(map_on()),
        map_count(hs.share and hs.share.union or C.share), s.share_sent, s.share_got, s.share_shown, s.share_found,
        tostring(SHARE.on())) .. " | " .. poimarks.status()
end

local installed = false
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    if session and session.world_reset_hooks then session.world_reset_hooks.persist = M.reset end
    poimarks.install(S)   -- the place markers on this machine's own map (its own 1 s loop)
    if installed then return end
    installed = true
    net.on("PSID", on_pid)
    net.on("PSPROG", function(f, pc) on_prog(f, pc, false) end)
    net.on("PSRDY", on_ready)
    net.on("PSSET", on_set)
    net.on("PSFRESH", on_fresh)
    net.on("PSDONE", on_done)
    net.on("PSMAP", on_map)
    net.on("PSMAPSET", on_mapset)
    net.on("MAPSHARE", on_mapshare)
    hs.last_period = clock()
    ue.every("persist", 1000, M.tick)
    log.info("persist: installed (persist_clients=%s, persist_period=%s s, persist_map=%s, map_shared=%s,"
        .. " persist_follow_host_save=%s, files in %s)", tostring(enabled()), tostring(period_s()), tostring(map_on()),
        tostring(SHARE.on()), tostring(CM.follow()), tostring(savegames_dir()))
end

-- tests
M._P, M._live, M._hs, M._C, M._docs = function() return P end, function() return live end, hs, function() return C end,
    function() return docs end
M.NOSLOT = NOSLOT

return M
