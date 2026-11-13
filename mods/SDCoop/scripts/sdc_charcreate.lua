-- SDCoop: a client's own co-op character, made BEFORE joining in the game's
-- own single-player character creator; the host spawns it with that look.
--
-- How the game does it (work\re\pseudo):
--   * Main menu "New Game" = MenuWidget's BndEvt__Play_..._11 (ubergraph
--     3266-3984): RemoveFromParent, BP_CharacterCreator.SetDefault, Create
--     CharacterCreatorMenu_C (Chr = preview), AddToViewport, the menu camera
--     sequence (MainMenuLevelSequence.Play), EMS SetCurrentSaveGameName("").
--   * CharacterCreatorMenu: every drop-down handler writes an asset into the
--     MainMenu level's BP_NewGameSettings actor (SetDefault 1118, Sex 1136,
--     SkinColor 1190, ...). Continue (BndEvt..ContinueButton..14 -> 2723)
--     removes the creator and opens NewGameDifficultySelectionPage
--     (695-785); nothing is loaded yet. Back / Esc (1506 / 786 = Exit):
--     MenuWidget again + the camera sequence in reverse.
--   * The difficulty page's Play (15-388) copies BP_NewGameSettings into the
--     Save_Player custom save and loads LongdownValley.
--   * BP_PlayerCharacter's construction script runs SetSexMesh (738 /
--     11748), which reads that Save_Player on the machine it runs on.
--
-- Main menu (any role but client):
--   * sdc_session.join -> M.before_join: without a stored co-op character
--     the join is held and the game's New Game is run (its click handler on
--     the live MenuWidget). The creator's Continue is post-hooked: the choice
--     is read from BP_NewGameSettings, the difficulty page it just opened is
--     removed and the creator's own Exit brings the main menu back (as Back
--     does). The choice goes to Mods\SDCoop\character.txt and the held join
--     runs. Back / Esc in the creator = the game's way back, join cancelled.
--   * The co-op panel's «Персонаж для кооператива» (M.open_from_menu) runs
--     the same without a join (to change the look; the creator is pre-filled).
--   * New Game sets EMS's current save name to ""; the previous name is put
--     back right after (the menu's Continue and the client save redirect use it).
-- In the host's world:
--   client: CHAR (the stored character) as soon as its controller of the
--     host's world is there (AutonomousProxy), again until the host's
--     CHARACK; CHARNONE without one; the look goes onto its own character the
--     game's way (Save_Player fields swapped in, SetSexMesh, old values back);
--     sdc_appearance publishes its look (MYLOOK) only after that
--     (M.own_look_pending).
--   host: a player's first character waits for CHAR / CHARNONE (join_gate:
--     up to JOIN_WAIT_S); sdc_players.spawn_character swaps the choice into the host's
--     Save_Player around FinishSpawningActor (the construction script's
--     SetSexMesh builds it) and restores the host's values. A CHAR for a
--     living character changes its look the same way.
--   Any failure: today's default character, with a log line.
--
-- Messages (fields never contain '|'):
--   client -> host  CHAR|1|sex|skin|hair|haircolor|brows|beard|beardcolor|mouth|acc1|acc2|acc3|forename|surname|age|occupation
--                   (asset paths relative to /Game/PlayerModel/, "" = none)
--   client -> host  CHARNONE|reason    no own character: spawn the default one now
--   host -> client  CHARACK|spawn|look|ok|direct|busy|failed   CHARACK|got|spawn (received, no character yet)

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local W = require("sdc_widgets")
local players = require("sdc_players")

local M = { stored = nil }

local CREATOR_CLASS = "/Game/UI/Menus/Menu/CharacterCreatorMenu.CharacterCreatorMenu_C"
local DIFF_PAGE_CLASS = "/Game/UI/Menus/Pages/NewGameDifficultySelectionPage.NewGameDifficultySelectionPage_C"
local MENU_CLASS = "/Game/UI/Menus/Menu/MenuWidget.MenuWidget_C"
local SAVE_CLASS = "/Game/Blueprints/Saves/Save_Player.Save_Player_C"
local SETTINGS_CLASS = "/Game/Blueprints/BP_NewGameSettings.BP_NewGameSettings_C"
local EMS_LIB = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"
local ASSET_ROOT = "/Game/PlayerModel/"

local FN_NEW_GAME = "BndEvt__Play_K2Node_ComponentBoundEvent_11_OnButtonClickedEvent__DelegateSignature"
local FN_CONTINUE = CREATOR_CLASS .. ":BndEvt__CharacterCreatorMenu_ContinueButton_K2Node_ComponentBoundEvent_14_OnButtonClickedEvent__DelegateSignature"
local FN_BACK = CREATOR_CLASS .. ":BndEvt__BackButton_K2Node_ComponentBoundEvent_13_OnButtonClickedEvent__DelegateSignature"
local FN_ESCAPE = CREATOR_CLASS .. ":InpActEvt_Escape_K2Node_InputKeyEvent_0"

local NO_REPLY_S = 8        -- host: a player that says nothing this long after its HI (older mod) gets the default character
local LOOK_COOLDOWN_S = 3   -- host: look changes per player
local MENU_WAIT_S = 120     -- main menu: how long a held join waits for the main menu to show up

-- key, Save_Player field, BP_NewGameSettings field, kind, default (SetDefault, pseudo 1118)
local FIELDS = {
    { "skin",       "SkinColor",      "SkinColor",      "mat",  "Materials/1/M_Chr_Texture_1A.M_Chr_Texture_1A" },
    { "hair",       "HairType",       "HairMesh",       "mesh", "" },
    { "haircolor",  "HairColor",      "HairColor",      "mat",  "Hair/Material/Brown/MI_CharacterHair_Brown.MI_CharacterHair_Brown" },
    { "brows",      "EyebrowsType",   "EyebrowsMesh",   "mesh", "Hair/Eyebrows/Chr_Eyebrows1.Chr_Eyebrows1" },
    { "beard",      "BeardType",      "BeardMesh",      "mesh", "" },
    { "beardcolor", "BeardColor",     "BeardColor",     "mat",  "Hair/Material/Brown/MI_CharacterHair_Brown.MI_CharacterHair_Brown" },
    { "mouth",      "MouthType",      "MouthMesh",      "mesh", "" },
    { "acc1",       "AccessoryType1", "Accessory1Mesh", "mesh", "" },
    { "acc2",       "AccessoryType2", "Accessory2Mesh", "mesh", "" },
    { "acc3",       "AccessoryType3", "Accessory3Mesh", "mesh", "" },
}

-- order of the CHAR fields after the version
local WIRE = { "sex", "skin", "hair", "haircolor", "brows", "beard", "beardcolor", "mouth",
               "acc1", "acc2", "acc3", "first", "last", "age", "occ" }

-- creator drop-downs and their handler functions; Sex first (the mouth and
-- accessory handlers depend on IsMale?)
local COMBOS = {
    { "DropDownSex", "Sex" }, { "DropDownSkinColor_2", "SkinColor" },
    { "DropDownHairType", "HairType" }, { "DropDownHairColor", "HairColor" },
    { "DropDownEyebrows", "EyebrowsType" }, { "DropDownBeard", "BeardType" },
    { "DropDownBeardColor", "BeardColor" }, { "DropDownMouth", "MouthType" },
    { "DropDownAccessory1", "AccessoryType1" }, { "DropDownAccessory2", "AccessoryType2" },
    { "DropDownAccessory3", "AccessoryType3" }, { "DropDownOccupation", false },
}

-- text box, selection key, BP_NewGameSettings / controller field
local TEXTS = {
    { "EditableTextBox_Forename", "first", "Forename" },
    { "EditableTextBox_Surname", "last", "Surname" },
    { "EditableTextBox_Age", "age", "Age" },
}

-- what SetSexMesh does per sex (BP_PlayerCharacter pseudo 1522-2931)
local BODY_PARTS = { "Torso", "Legs", "LowerLegs", "Hands", "Arms", "Feet", "Head" }
local function body_mesh(sex, part)
    if part == "Hands" then return "/Game/PlayerModel/BodyParts/SK_Chr_Hands.SK_Chr_Hands" end
    local n = string.format("SK_Chr_%s_%s", sex, part)
    return string.format("/Game/PlayerModel/BodyParts/%s/%s.%s", sex, n, n)
end

local S                -- sdc_session.state
local session_mod      -- sdc_session (join)
local file_path = nil  -- Mods\SDCoop\character.txt
local hooks = {}       -- [name] = true once registered
local last_role = nil
local cl = nil         -- client in the host's world (names only, no objects)
local hosts = {}       -- host: [remote controller key] = per-player record
local flow = nil       -- main menu: the creator flow (names only, no objects)
local bypass_join = false

-- ===========================================================================
-- Helpers
-- ===========================================================================

local function now_s() return os.time() end

local function load_object(path)
    local o = ue.find_object(path)
    if o then return o end
    local ok, loaded = ue.load_asset(path, "charcreate")
    if ok and ue.valid(loaded) then return loaded end
    return ue.find_object(path)
end

-- A Blueprint class: "/Game/A/B.B_C" (loaded through its package if needed).
local function load_class(path)
    local c = load_object(path)
    if c then return c end
    ue.load_asset((path:gsub("_C$", "")))
    return ue.find_object(path)
end

local function kind_ok(o, kind)
    local c = ue.class_name(o)
    if kind == "mesh" then return c == "StaticMesh" end
    return c == "Material" or c:find("MaterialInstance", 1, true) ~= nil
end

-- object -> path relative to /Game/PlayerModel/ ("" = none, nil = foreign asset)
local function to_wire(o)
    if not ue.valid(o) then return "" end
    local p = ue.path(o)
    if p:sub(1, #ASSET_ROOT) == ASSET_ROOT then return p:sub(#ASSET_ROOT + 1) end
    return nil
end

-- network / file input: "Dir/Sub/Name.Name" or ""
local function sane(rel)
    if rel == "" then return true end
    return type(rel) == "string" and #rel < 160 and rel:match("^[%w_/]+%.[%w_]+$") ~= nil
        and not rel:find("//", 1, true)
end

local function tail(rel)
    if not rel or rel == "" then return "-" end
    return rel:match("([^%./]+)$") or rel
end

local function clean_text(s, digits_only)
    s = tostring(s or ""):gsub("[%c|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if digits_only then
        if s:match("^%d+$") then return s:sub(1, 3) end
        return ""
    end
    local ok, n = pcall(utf8.len, s)
    if ok and n and n > 32 then
        local cut = utf8.offset(s, 33)
        if cut then s = s:sub(1, cut - 1) end
    elseif #s > 96 then
        s = s:sub(1, 96)
    end
    return s
end

local function describe_sel(sel)
    if not sel then return "none" end
    return string.format("sex=%s skin=%s hair=%s/%s brows=%s beard=%s/%s mouth=%s acc=%s,%s,%s",
        sel.sex, tail(sel.skin), tail(sel.hair), tail(sel.haircolor), tail(sel.brows), tail(sel.beard),
        tail(sel.beardcolor), tail(sel.mouth), tail(sel.acc1), tail(sel.acc2), tail(sel.acc3))
end

-- Live actors / objects of one (specific) class, no class default objects.
local function actors_of(short_cls)
    local out = {}
    for _, a in ipairs(ue.find_all(short_cls)) do
        if ue.valid(a) and not ue.short(a):find("^Default__") then out[#out + 1] = a end
    end
    return out
end

local class_cache = {}
local function class_obj(path)
    local c = class_cache[path]
    if ue.valid(c) then return c end
    c = ue.find_object(path)
    class_cache[path] = c
    return c
end

-- Widgets of a class that are on screen (WidgetBlueprintLibrary, as
-- sdc_lobby: FindAllOf misses some widget classes in this UE4SS build).
local function on_screen(class_path, short_cls)
    local out, seen = {}, {}
    local wbl, wc = ue.widget_lib(), ue.local_pc() or ue.game_instance()
    local cls = class_obj(class_path)
    if wbl and wc and cls then
        local arr = {}
        if pcall(function() wbl:GetAllWidgetsOfClass(wc, arr, cls, true) end) then
            for _, v in ipairs(arr) do
                local w = v
                if type(v) == "userdata" and not ue.valid(v) then w = ue.try(function() return v:get() end) end
                if ue.valid(w) and not ue.short(w):find("^Default__") then
                    local k = ue.name(w)
                    if not seen[k] then seen[k] = true; out[#out + 1] = w end
                end
            end
        end
    end
    if short_cls then
        for _, w in ipairs(ue.find_all(short_cls)) do
            if ue.valid(w) and not seen[ue.name(w)] and not ue.short(w):find("^Default__") then
                local ok, inv = pcall(function() return w:IsInViewport() end)
                if ok and inv == true then seen[ue.name(w)] = true; out[#out + 1] = w end
            end
        end
    end
    return out
end

local function remove_pages()
    local n = 0
    for _, w in ipairs(on_screen(DIFF_PAGE_CLASS, "NewGameDifficultySelectionPage_C")) do
        if ue.valid(w) and pcall(function() w:RemoveFromParent() end) then n = n + 1 end
    end
    return n
end

local function menu_on_screen()
    return on_screen(MENU_CLASS, "MenuWidget_C")[1]
end

local function toast(ru, kind, seconds, en)
    log.toast(ru, kind or "info", seconds or 6, "charcreate: " .. en)
end

-- ===========================================================================
-- Selection <-> objects, file, message
-- ===========================================================================

-- Selection -> objects for the Save_Player fields. Unknown / foreign / wrong
-- type assets fall back to the creator's defaults (logged by the caller).
local function resolve(sel)
    local res, bad = { sex = (sel.sex == "Female") and "Female" or "Male" }, {}
    for _, f in ipairs(FIELDS) do
        local key, kind, default = f[1], f[4], f[5]
        local rel = sel[key] or ""
        local obj = false
        if not sane(rel) then bad[#bad + 1] = key; rel = default end
        if rel ~= "" then
            local o = load_object(ASSET_ROOT .. rel)
            if o and kind_ok(o, kind) then
                obj = o
            else
                bad[#bad + 1] = key
                if default ~= "" then
                    local d = load_object(ASSET_ROOT .. default)
                    if d and kind_ok(d, kind) then obj = d end
                end
            end
        end
        res[key] = obj
    end
    return res, bad
end

local function decode_sel(f)
    if f[1] ~= "1" then return nil, "unknown format " .. tostring(f[1]) end
    local sel = {}
    for i, k in ipairs(WIRE) do sel[k] = f[i + 1] or "" end
    if sel.sex ~= "Male" and sel.sex ~= "Female" then return nil, "bad sex '" .. tostring(sel.sex) .. "'" end
    for _, fd in ipairs(FIELDS) do
        if not sane(sel[fd[1]]) then sel[fd[1]] = fd[5] end
    end
    sel.first, sel.last, sel.age = clean_text(sel.first), clean_text(sel.last), clean_text(sel.age, true)
    sel.occ = math.floor(tonumber(sel.occ) or 0)
    return sel
end

local function send_char(sel)
    local args = { "1" }
    for _, k in ipairs(WIRE) do args[#args + 1] = tostring(sel[k] or "") end
    return net.send_to_host("CHAR", table.unpack(args))
end

local function one_line(v) return (tostring(v or ""):gsub("[\r\n]", " ")) end

local function save_file(sel)
    if not file_path then return false end
    local f, err = io.open(file_path, "w")
    if not f then
        log.err("charcreate: cannot write %s: %s", tostring(file_path), tostring(err))
        return false
    end
    f:write("# SDCoop: your co-op character, made in the game's character creator.\n")
    f:write("# Change it: co-op panel in the main menu. Delete this file (or console: sdcoop_character reset) to make a new one.\n")
    f:write("version = 1\n")
    for _, k in ipairs(WIRE) do f:write(string.format("%s = %s\n", k, one_line(sel[k]))) end
    for _, c in ipairs(COMBOS) do
        local v = sel.labels and sel.labels[c[1]]
        if v and v ~= "" then f:write(string.format("label.%s = %s\n", c[1], one_line(v))) end
    end
    f:close()
    log.info("charcreate: character saved to %s", file_path)
    return true
end

local function load_file()
    if not file_path then return nil end
    local f = io.open(file_path, "r")
    if not f then return nil end
    local sel, labels, version = {}, {}, nil
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if not line:match("^%s*#") then
            local k, v = line:match("^%s*([%w_%.]+)%s*=%s?(.-)%s*$")
            if k == "version" then
                version = v
            elseif k and k:sub(1, 6) == "label." then
                labels[k:sub(7)] = v
            elseif k then
                sel[k] = v
            end
        end
    end
    f:close()
    if version ~= "1" or (sel.sex ~= "Male" and sel.sex ~= "Female") then
        log.warn("charcreate: %s is not a valid character file, ignored", file_path)
        return nil
    end
    for _, fd in ipairs(FIELDS) do
        if not sane(sel[fd[1]] or "") then sel[fd[1]] = fd[5] end
        sel[fd[1]] = sel[fd[1]] or fd[5]
    end
    sel.first, sel.last, sel.age = clean_text(sel.first), clean_text(sel.last), clean_text(sel.age, true)
    sel.occ = math.floor(tonumber(sel.occ) or 0)
    sel.labels = labels
    return sel
end

-- ===========================================================================
-- Applying a look the game's way (both sides)
-- ===========================================================================

local function player_save(wc)
    local lib, cls = ue.find_object(EMS_LIB), load_class(SAVE_CLASS)
    if not lib then return nil, "EMS library not found" end
    if not cls then return nil, "Save_Player class not found" end
    local ok, s = pcall(function() return lib:GetCustomSave(wc, cls, "", "") end)
    if ok and ue.valid(s) then return s end
    return nil, "GetCustomSave: " .. (ok and "no object" or tostring(s))
end

local function write_prop(o, name, v)
    if not ue.valid(o) then return false end
    return (pcall(function() o[name] = v end))
end

-- Writes `res` into the Save_Player object. Returns a function that puts the
-- old values back (and returns the number of fields it could not restore),
-- or nil + reason (then nothing is left changed).
local function swap_in(save, res)
    local undo = {}
    local function restore()
        local failed = 0
        for i = #undo, 1, -1 do
            if not write_prop(save, undo[i][1], undo[i][2]) then failed = failed + 1 end
        end
        return failed
    end
    local old_sex = ue.str(ue.prop(save, "Sex"))
    if not write_prop(save, "Sex", res.sex) then return nil, "cannot write Save_Player.Sex" end
    undo[#undo + 1] = { "Sex", old_sex }
    for _, f in ipairs(FIELDS) do
        local old = ue.prop(save, f[2])
        if not ue.valid(old) then old = nil end
        local new = res[f[1]]
        if new == false then new = nil end
        if not write_prop(save, f[2], new) then
            restore()
            return nil, "cannot write Save_Player." .. f[2]
        end
        undo[#undo + 1] = { f[2], old }
    end
    return restore
end

-- SetSexMesh on `pawn` with the choice in the Save_Player of this machine,
-- old values back right after (pseudo BP_PlayerCharacter 11748).
local function apply_game_way(pawn, res, wc)
    local save, why = player_save(wc)
    if not save then return false, why end
    local restore, err = swap_in(save, res)
    if not restore then return false, err end
    local ok, e = pcall(function() pawn:SetSexMesh() end)
    local failed = restore()
    if failed > 0 then log.err("charcreate: %d Save_Player field(s) could not be restored", failed) end
    if not ok then return false, "SetSexMesh: " .. tostring(e) end
    return true
end

-- Fallback: what SetSexMesh does, done from here.
local function apply_direct(pawn, res)
    local male = res.sex ~= "Female"
    ue.set_prop(pawn, "IsPlayerMale?", male)
    local skin = res.skin or nil
    for _, part in ipairs(BODY_PARTS) do
        local comp = ue.prop(pawn, part)
        local mesh = load_object(body_mesh(male and "Male" or "Female", part))
        if ue.valid(comp) and mesh then
            if not pcall(function() comp:SetSkeletalMeshAsset(mesh) end) then
                pcall(function() comp:SetSkinnedAssetAndUpdate(mesh, true) end)
            end
        end
        if ue.valid(comp) and skin then pcall(function() comp:SetMaterial(0, skin) end) end
    end
    local function static(comp_name, mesh, mat)
        local comp = ue.prop(pawn, comp_name)
        if not ue.valid(comp) then return end
        pcall(function() comp:SetStaticMesh(mesh or nil) end)
        if mat then pcall(function() comp:SetMaterial(0, mat) end) end
    end
    static("HairMesh", res.hair, res.haircolor)
    static("EyebrowsMesh", res.brows, res.haircolor)
    static("BeardMesh", res.beard, res.beardcolor)
    static("Mouth", res.mouth)
    static("Accessory1", res.acc1)
    static("Accessory2", res.acc2)
    static("Accessory3", res.acc3)
    if skin then ue.set_prop(pawn, "SkinColor", skin) end
    if res.haircolor then ue.set_prop(pawn, "Hair Color", res.haircolor) end
    if res.beardcolor then ue.set_prop(pawn, "Beard Color", res.beardcolor) end
end

-- Did SetSexMesh take the swapped values (sex and hair)? If GetCustomSave
-- handed us another object than the one SetSexMesh reads, it did not.
local function took(pawn, res)
    if (ue.prop(pawn, "IsPlayerMale?") == true) ~= (res.sex ~= "Female") then return false end
    local hair = ue.prop(pawn, "HairMesh")
    local mesh = ue.valid(hair) and ue.prop(hair, "StaticMesh") or nil
    local want = res.hair or nil
    if not ue.valid(mesh) then return want == nil end
    return want ~= nil and ue.path(mesh) == ue.path(want)
end

-- Returns "game" / "direct" / nil, reason.
local function apply_look(pawn, sel, wc)
    local res, bad = resolve(sel)
    if #bad > 0 then log.warn("charcreate: unusable asset(s) replaced by defaults: %s", table.concat(bad, ",")) end
    local ok, why = apply_game_way(pawn, res, wc)
    if ok and took(pawn, res) then return "game" end
    if ok then why = "SetSexMesh did not use the swapped Save_Player values" end
    log.warn("charcreate: game look path failed on %s (%s), setting the meshes directly", ue.short(pawn), tostring(why))
    local okd, errd = pcall(apply_direct, pawn, res)
    if okd then return "direct" end
    return nil, tostring(why) .. " / " .. tostring(errd)
end

-- ===========================================================================
-- Host
-- ===========================================================================

local function host_rec(key)
    local h = hosts[key]
    if not h then
        h = { state = "unknown", logged = {}, last_seen = now_s() }
        hosts[key] = h
    end
    return h
end

local function host_name(key)
    local r = S and S.remote and S.remote[key]
    return r and r.name or "player"
end

local function once(h, tag, msg, ...)
    if h.logged[tag] then return end
    h.logged[tag] = true
    log.info(msg, ...)
end

-- sdc_players.host_player_tick: may this player's FIRST character spawn now?
-- A client of this version sends CHAR / CHARNONE as soon as its controller
-- in this world is there; an older one says nothing and gets the default
-- character. A joining game loads the map before its controller in this
-- world can send anything (13.11: ~15 s; the host gave up after 8 s while the
-- client was still loading, spawned the default character, then changed its
-- look): the wait is JOIN_WAIT_S from the connection - as long as sdc_persist
-- waits for the player's id, which the client sends at the same moment as
-- CHAR - or NO_REPLY_S from its first HI (r.hello, sdc_session) when that
-- comes first.
local JOIN_WAIT_S = 25
function M.join_gate(r, now)
    if cfg.get("char_create") == false then return true end
    local h = host_rec(r.key)
    h.last_seen = now
    h.first_gate = h.first_gate or now
    if h.state == "char" or h.state == "default" then return true end
    if r.hello and not h.heard_at then h.heard_at = now end
    if h.heard_at and now - h.heard_at >= NO_REPLY_S then
        once(h, "silent", "charcreate: host: no character message from %s in %d s after its HI (older mod?), default character",
            r.name, NO_REPLY_S)
        return true
    end
    if now - h.first_gate < JOIN_WAIT_S then return false end
    once(h, "silent", "charcreate: host: no character message from %s in %d s since it connected (older mod?), default character",
        r.name, JOIN_WAIT_S)
    return true
end

-- sdc_players.spawn_character, between BeginDeferredActorSpawnFromClass and
-- FinishSpawningActor: the player's choice goes into the host's Save_Player
-- so the construction script's SetSexMesh uses it. Returns the restore
-- function (called right after FinishSpawningActor) or nil.
function M.before_finish_spawn(actor, r)
    if not r or cfg.get("char_create") == false then return nil end
    local h = hosts[r.key]
    if not h or not h.sel then return nil end
    local res, bad = resolve(h.sel)
    local save, why = player_save(ue.local_pc() or ue.game_instance())
    if not save then
        log.warn("charcreate: host: %s spawns with the default look (%s)", r.name, tostring(why))
        return nil
    end
    local restore, err = swap_in(save, res)
    if not restore then
        log.warn("charcreate: host: %s spawns with the default look (%s)", r.name, tostring(err))
        return nil
    end
    log.info("charcreate: host: spawning %s as their own character %s (%s)%s", r.name, ue.short(actor),
        describe_sel(h.sel), #bad > 0 and (" defaults for: " .. table.concat(bad, ",")) or "")
    local pc = r.pc
    return function()
        local failed = restore()
        if failed > 0 then
            log.err("charcreate: host: %d field(s) of the host's own Save_Player could not be restored", failed)
        end
        local how = "ok"
        if ue.valid(actor) and not took(actor, res) then
            how = pcall(apply_direct, actor, res) and "direct" or "failed"
            log.warn("charcreate: host: the construction script did not take %s's look, set directly: %s", r.name, how)
        end
        if ue.valid(pc) then net.send_to(pc, "CHARACK", "spawn", how) end
    end
end

local function host_on_char(f, pc)
    local key = ue.name(pc)
    local h = host_rec(key)
    h.last_seen = now_s()
    local name = host_name(key)
    local sel, err = decode_sel(f)
    if not sel then
        log.warn("charcreate: host: bad character from %s (%s), default character", name, tostring(err))
        if h.state ~= "char" then h.state = "default" end
        return
    end
    local again = h.state == "char"
    h.sel, h.state = sel, "char"
    local pawn = ue.pawn_of(pc)
    if not pawn then
        -- received (the client sends it again until a CHARACK)
        net.send_to(pc, "CHARACK", "got", "spawn")
        if not again then log.info("charcreate: host: character of %s received (%s), spawning it", name, describe_sel(sel)) end
        return
    end
    -- the character was there first (default spawn): change its look
    local now = now_s()
    if now - (h.last_apply or 0) < LOOK_COOLDOWN_S then
        net.send_to(pc, "CHARACK", "look", "busy")
        return
    end
    h.last_apply = now
    local how, why = apply_look(pawn, sel, ue.local_pc() or ue.game_instance())
    log.info("charcreate: host: look of %s (%s) changed: %s%s", name, ue.short(pawn), tostring(how or "FAILED"),
        how and "" or (" " .. tostring(why)))
    net.send_to(pc, "CHARACK", "look", how or "failed")
end

local function host_tick(now)
    for key, h in pairs(hosts) do
        if S.remote and S.remote[key] then
            h.last_seen = now
        elseif now - (h.last_seen or now) > 120 then
            hosts[key] = nil
        end
    end
end

-- ===========================================================================
-- Client in the host's world
-- ===========================================================================

-- Names / occupation into the local controller, as SetupPlayerLooks does
-- (journal page only).
local function set_controller_info(pc, sel)
    write_prop(pc, "Forename", sel.first or "")
    write_prop(pc, "Surname", sel.last or "")
    write_prop(pc, "Age", sel.age or "")
    write_prop(pc, "Occupation", sel.occ or 0)
    write_prop(pc, "Sex", sel.sex)
end

-- The stored look on the own character: once after it appears, then
-- re-checked (the client's own construction / save code can put its
-- single-player look back), at most 3 times per character.
local function looks_applied(pawn, sel)
    local male = ue.prop(pawn, "IsPlayerMale?") == true
    if male ~= (sel.sex ~= "Female") then return false end
    local hair = ue.prop(pawn, "HairMesh")
    local mesh = ue.valid(hair) and ue.prop(hair, "StaticMesh") or nil
    return (to_wire(mesh) or "?") == (sel.hair or "")
end

local function ensure_applied(pc, pawn, now)
    local key = ue.name(pawn)
    local rec = cl.applied[key]
    if not rec then
        cl.applied[key] = { tries = 0, at = 0 }   -- one tick for the new character
        return
    end
    if rec.tries >= 3 then return end
    if rec.tries > 0 and (now - rec.at < 5 or looks_applied(pawn, M.stored)) then return end
    rec.tries, rec.at = rec.tries + 1, now
    local how, why = apply_look(pawn, M.stored, pc)
    log.info("charcreate: client: look applied to own %s: %s (try %d)%s", ue.short(pawn), tostring(how or "FAILED"),
        rec.tries, how and "" or (" " .. tostring(why)))
end

-- sdc_appearance (client, MYLOOK): is the stored co-op look still to be put
-- on this own character? Its look is not published before (13.11: MYLOOK
-- with the default look went out 0.7 s before "look applied ... try 1" and
-- the host put that look back on the character it had just given the right
-- one). Not longer than LOOK_HOLD_S after the character appeared.
local LOOK_HOLD_S = 10
function M.own_look_pending(pawn)
    if not cl or not M.stored or cfg.get("char_create") == false or not S or S.role ~= "client" then return false end
    if not ue.valid(pawn) then return false end
    local key = ue.name(pawn)
    local rec = cl.applied[key]
    if rec and rec.tries > 0 then return false end
    cl.hold = cl.hold or {}
    local since = cl.hold[key] or now_s()
    cl.hold[key] = since
    return now_s() - since < LOOK_HOLD_S
end

-- CHAR goes out only from a controller of the host's world: one that came
-- from the host (Role AutonomousProxy, as sdc_persist's early id); the menu
-- world's own (Authority), still there when the session turns "client",
-- never reaches the host (13.11: CHAR sent at 16:59:46 from it was lost, the
-- host got it only from the second controller 16 s later). Then again every
-- CHAR_RESEND_S until the host's CHARACK, at most CHAR_TRIES times.
local CHAR_RESEND_S = 4
local CHAR_TRIES = 5

local function announce(pc, now)
    cl.announced, cl.sent_at, cl.tries = true, now, 1
    if cfg.get("char_create") == false then
        net.send_to_host("CHARNONE", "off")
        log.info("charcreate: client: own character off (config char_create)")
    elseif M.stored then
        cl.char_sent = true
        send_char(M.stored)
        pcall(set_controller_info, pc, M.stored)
        log.info("charcreate: client: character sent to the host (%s)", describe_sel(M.stored))
    else
        net.send_to_host("CHARNONE", "no character")
        log.info("charcreate: client: no co-op character stored, the host spawns the default one")
    end
end

local function resend(now)
    if not cl.char_sent or cl.acked or cl.tries >= CHAR_TRIES or now - cl.sent_at < CHAR_RESEND_S then return end
    if not M.stored or cfg.get("char_create") == false then return end
    cl.sent_at, cl.tries = now, cl.tries + 1
    send_char(M.stored)
    log.info("charcreate: client: no answer from the host yet: character sent again (try %d of %d)", cl.tries, CHAR_TRIES)
end

local function client_tick(now)
    local pc = ue.local_pc()
    if not pc then return end
    local key = ue.name(pc)
    if not cl or cl.pc_key ~= key then
        cl = { pc_key = key, announced = false, applied = {}, tries = 0 }
    end
    if not ue.valid(ue.prop(pc, "PlayerState")) then return end
    local pawn = ue.pawn_of(pc)
    -- (an own player character: in the host's world whatever the role reads)
    local own_char = pawn ~= nil and ue.class_name(pawn):find("PlayerCharacter", 1, true) ~= nil
    if not own_char and ue.role(pc) ~= ue.ROLE_AUTONOMOUS then
        if not cl.menu_logged then
            cl.menu_logged = true
            log.info("charcreate: client: controller %s is not the host's yet (role %s): the character goes out from the host's world",
                ue.short(pc), tostring(ue.role(pc)))
        end
        return
    end
    if not cl.announced then announce(pc, now) else resend(now) end
    if pawn and M.stored and cfg.get("char_create") ~= false then ensure_applied(pc, pawn, now) end
end

-- ===========================================================================
-- Main menu: the game's New Game creator, before joining
-- ===========================================================================

-- The MainMenu level's BP_NewGameSettings, found the creator's own way
-- (GameplayStatics.GetActorOfClass, pseudo 1586), not read from the
-- creator's NewGameSettings variable: CharacterCreatorMenu_C exists only in
-- the main menu and is reloaded with it, and a by-name read of a reloaded
-- widget Blueprint's variable can crash UE4SS 3.0.1 (see W.child in
-- sdc_widgets). BP_NewGameSettings_C itself stays loaded (GameFunctionLibrary
-- refers to it), so its fields are read by name as before.
local function settings_actor(w)
    local gps, cls = ue.gameplay_statics(), class_obj(SETTINGS_CLASS)
    local wc = (ue.valid(w) and w) or ue.local_pc() or ue.game_instance()
    if gps and cls and wc then
        local ok, a = pcall(function() return gps:GetActorOfClass(wc, cls) end)
        if ok and ue.valid(a) then return a end
    end
    return actors_of("BP_NewGameSettings_C")[1]
end

-- The choice, read in the Continue hook (widget alive) or by the poll
-- fallback (w = nil: only the BP_NewGameSettings actor).
local function read_selection(w)
    local settings = settings_actor(w)
    if not ue.valid(settings) then return nil end
    local sel = { labels = {} }
    sel.sex = (ue.str(ue.prop(settings, "Sex")) == "Female") and "Female" or "Male"
    for _, f in ipairs(FIELDS) do
        local rel = to_wire(ue.prop(settings, f[3]))
        if rel == nil then rel = f[5] end
        sel[f[1]] = rel
    end
    sel.occ = math.floor(tonumber(ue.prop(settings, "Occupation")) or 0)
    for _, t in ipairs(TEXTS) do
        local v = ""
        local box = w and W.child(w, t[1])
        if ue.valid(box) then v = ue.str(ue.try(function() return box:GetText() end)) end
        if v == "" then v = ue.str(ue.prop(settings, t[3])) end
        sel[t[2]] = clean_text(v, t[2] == "age")
    end
    if w then
        for _, c in ipairs(COMBOS) do
            local combo = W.child(w, c[1])
            if ue.valid(combo) then
                sel.labels[c[1]] = clean_text(ue.str(ue.try(function() return combo:GetSelectedOption() end)))
            end
        end
    end
    return sel
end

-- A stored choice back into the fresh creator: the handler functions set
-- BP_NewGameSettings and the preview, SetSelectedOption the drop-downs.
local function prefill(w, sel)
    local labels = sel.labels or {}
    for _, c in ipairs(COMBOS) do
        local label = labels[c[1]]
        if label and label ~= "" and ue.valid(w) then
            if c[2] then pcall(function() w[c[2]](w, label) end) end
            local combo = W.child(w, c[1])
            if ue.valid(combo) then pcall(function() combo:SetSelectedOption(label) end) end
        end
    end
    for _, t in ipairs(TEXTS) do
        local v = sel[t[2]]
        local box = ue.valid(w) and W.child(w, t[1]) or nil
        if v and v ~= "" and ue.valid(box) then pcall(function() box:SetText(FText(v)) end) end
    end
end

-- New Game cleared EMS's current save name (MenuWidget 3984); ours goes back.
local function restore_ems(f)
    if not f or f.ems_restored or not f.prev_save or f.prev_save == "" then return end
    f.ems_restored = true
    local lib, wc = ue.find_object(EMS_LIB), ue.local_pc() or ue.game_instance()
    if not lib or not wc then return end
    local ok, err = pcall(function() lib:SetCurrentSaveGameName(wc, f.prev_save) end)
    log.info("charcreate: menu: EMS current save name back to %s (ok=%s%s)", f.prev_save, tostring(ok),
        ok and "" or (" " .. tostring(err)))
end

local function close_panel()
    local ui = package.loaded["sdc_ui"]
    if type(ui) == "table" and type(ui.set_open) == "function" then pcall(ui.set_open, false) end
end

-- The held join, now (bypass: also without a character, after a failure).
local function run_join(pending, bypass)
    if not pending or not session_mod then return end
    bypass_join = bypass == true
    local ok, err = pcall(session_mod.join, pending.ip, pending.port, pending.is_auto)
    bypass_join = false
    if not ok then log.err("charcreate: menu: join failed: %s", tostring(err)) end
end

-- The flow could not run: today's behaviour (join with the default character).
local function fail_flow(why)
    local f = flow
    flow = nil
    if not f then return end
    restore_ems(f)
    log.warn("charcreate: menu: character creator flow failed (%s)%s", tostring(why),
        f.pending and "; joining with the default character" or "")
    if f.pending then
        toast("Редактор персонажа не открылся — подключение с персонажем по умолчанию.", "warn", 8, "flow failed")
        run_join(f.pending, true)
    else
        toast("Не удалось открыть редактор персонажа.", "err", 6, "flow failed")
    end
end

local function cancel_flow(why)
    local f = flow
    flow = nil
    if not f then return end
    restore_ems(f)
    log.info("charcreate: menu: creator left (%s)%s", tostring(why), f.pending and ", join cancelled" or "")
    if f.pending then toast("Подключение отменено.", "info", 5, "join cancelled") end
end

-- A main menu must be on screen after the flow (the creator's Exit makes
-- one; else the MainMenu level script's own CreateMenu, pseudo MainMenu 1251).
local function ensure_menu()
    if menu_on_screen() or on_screen(CREATOR_CLASS, "CharacterCreatorMenu_C")[1] then return "present" end
    for _, ls in ipairs(actors_of("MainMenu_C")) do
        if ue.valid(ls) and pcall(function() ls:CreateMenu() end) then return "made by CreateMenu" end
    end
    return "MISSING"
end

-- Back to the main menu the creator's way (Exit, pseudo 1850 -> 786).
local function creator_exit(name)
    for _, w in ipairs(actors_of("CharacterCreatorMenu_C")) do
        if ue.valid(w) and ue.name(w) == name then
            return (pcall(function() w:Exit() end))
        end
    end
    return false
end

local function confirmed(f, sel, how)
    flow = nil
    restore_ems(f)
    M.stored = sel
    save_file(sel)
    log.info("charcreate: menu: character made (%s, %s)", describe_sel(sel), how)
    if f.pending then
        toast("Персонаж сохранён. Подключение...", "ok", 6, "character saved, joining")
        local pending = f.pending
        ue.delay("charcreate-join", 1200, function()
            if not menu_on_screen() then log.info("charcreate: menu: main menu %s", ensure_menu()) end
            run_join(pending, false)
        end)
    else
        toast("Персонаж для кооператива сохранён.", "ok", 6, "character saved")
    end
end

local function install_hooks()
    local function hook(name, path, fn)
        if hooks[name] then return end
        local ok, err = pcall(RegisterHook, path, function(ctx)
            local okc, errc = pcall(fn, ctx)
            if not okc then log.err_throttled("charcreate." .. name, "charcreate: %s hook: %s", name, tostring(errc)) end
        end)
        if ok then hooks[name] = true end
        log.info("charcreate: hook %s %s%s", name, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    -- Continue: runs after the game's handler, which removed the creator
    -- and opened the difficulty page (pseudo 2723 -> 695).
    hook("continue", FN_CONTINUE, function(ctx)
        local f = flow
        local w = ctx and ctx:get()
        if not f or f.phase ~= "open" or not ue.valid(w) or ue.name(w) ~= f.creator then return end
        local oks, sel = pcall(read_selection, w)
        local n = remove_pages()
        -- the main menu back, as the creator's own Back does (camera reverse)
        local oke, erre = pcall(function() w:Exit() end)
        log.info("charcreate: menu: Continue pressed (choice %s, difficulty page removed: %d, Exit ok=%s%s)",
            (oks and sel) and "read" or ("UNREADABLE " .. tostring(sel)), n, tostring(oke),
            oke and "" or (" " .. tostring(erre)))
        f.phase = "done"
        f.result = (oks and sel) or false
        f.exited = oke
    end)
    -- Back / Esc: the game's own way back to the main menu ran.
    local function back(ctx)
        local f = flow
        local w = ctx and ctx:get()
        if not f or f.phase ~= "open" or not ue.valid(w) or ue.name(w) ~= f.creator then return end
        f.phase = "cancelled"
    end
    hook("back", FN_BACK, back)
    hook("escape", FN_ESCAPE, back)
end

-- Runs the game's New Game on the live main menu (its click handler).
local function start_creator(f, menu)
    if not load_class(CREATOR_CLASS) then return fail_flow("creator class not found") end
    install_hooks()
    f.prev_save = ue.ems_current_slot()
    local ok, err = pcall(function() menu[FN_NEW_GAME](menu) end)
    -- New Game cleared it; the main menu's Continue and our join need it
    restore_ems(f)
    if not ok then return fail_flow("New Game: " .. tostring(err)) end
    local w = on_screen(CREATOR_CLASS, "CharacterCreatorMenu_C")[1]
    if not w then
        log.info("charcreate: menu: main menu %s", ensure_menu())
        return fail_flow("no creator on screen after New Game")
    end
    f.creator, f.phase, f.opened_at = ue.name(w), "open", now_s()
    local filled = "no stored character"
    if M.stored then
        filled = pcall(prefill, w, M.stored) and "stored character" or "prefill FAILED"
    end
    log.info("charcreate: menu: creator opened through New Game (%s; %s; EMS save name '%s')",
        f.pending and "join held" or "look change", filled, tostring(f.prev_save))
    toast(f.pending and "Создайте персонажа для кооператива и нажмите «Continue» — затем начнётся подключение."
        or "Измените персонажа и нажмите «Continue».", "info", 10, "creator shown")
end

local function menu_tick(now)
    local f = flow
    if not f then return end
    if S.role == "client" then
        flow = nil
        return
    end
    if f.phase == "start" then
        if not ue.in_main_menu() and now - f.started_at >= 5 then return cancel_flow("not in the main menu") end
        local menu = menu_on_screen()
        if menu then return start_creator(f, menu) end
        if now - f.started_at >= MENU_WAIT_S then return cancel_flow("no main menu in " .. MENU_WAIT_S .. " s") end
        if not f.waiting_told then
            f.waiting_told = true
            toast("Откройте главное меню (любая клавиша) — там откроется редактор персонажа.", "info", 8,
                "waiting for the main menu")
        end
        return
    end
    if f.phase == "done" then
        if not f.exited then log.info("charcreate: menu: main menu %s", ensure_menu()) end
        if f.result then return confirmed(f, f.result, "Continue hook") end
        return fail_flow("the choice could not be read")
    end
    if f.phase == "cancelled" then return cancel_flow("Back / Esc") end
    -- phase "open": the creator on screen?
    for _, w in ipairs(on_screen(CREATOR_CLASS, "CharacterCreatorMenu_C")) do
        if ue.name(w) == f.creator then return end
        -- the difficulty page's Back makes a new creator (pseudo 389-594)
        f.creator = ue.name(w)
        log.info("charcreate: menu: following the creator the difficulty page reopened")
        return
    end
    if #on_screen(DIFF_PAGE_CLASS, "NewGameDifficultySelectionPage_C") > 0 then
        -- Continue without our hook: the data actor still has the choice
        local ok, sel = pcall(read_selection, nil)
        local n = remove_pages()
        local exited = creator_exit(f.creator)
        log.info("charcreate: menu: Continue seen by polling (difficulty page removed: %d, Exit ok=%s, main menu %s)",
            n, tostring(exited), exited and "back" or ensure_menu())
        if ok and sel then return confirmed(f, sel, "poll") end
        return fail_flow("the choice could not be read")
    end
    if menu_on_screen() then return cancel_flow("main menu back") end
    if now - (f.opened_at or now) >= 3 then
        log.info("charcreate: menu: main menu %s", ensure_menu())
        return cancel_flow("creator closed")
    end
end

local function start_flow(pending, source)
    flow = { phase = "start", pending = pending, started_at = now_s(), source = source }
    close_panel()
    log.info("charcreate: menu: character creator requested (%s%s)", tostring(source),
        pending and (", join to " .. tostring(pending.ip) .. " held") or "")
end

-- ===========================================================================
-- Public
-- ===========================================================================

function M.tick()
    if not S then return end
    local role = S.role
    if role ~= last_role then
        cl, hosts = nil, {}
        last_role = role
    end
    local now = now_s()
    if flow then menu_tick(now) end
    if role == "client" then
        client_tick(now)
    elseif role == "host" then
        host_tick(now)
    end
end

-- Level change: names only are kept, all dropped. A held join (no joins
-- start while it is held) survives: the main menu world reopened as a
-- listen server, say; the creator opens again in the new world.
function M.forget_world()
    if flow then
        restore_ems(flow)
        if flow.pending then
            flow = { phase = "start", pending = flow.pending, started_at = now_s(), source = flow.source }
            log.info("charcreate: menu: level change, the creator opens again for the held join")
        else
            log.info("charcreate: menu: creator flow dropped by a level change")
            flow = nil
        end
    end
    cl, hosts = nil, {}
end

-- The game's creator is open in our flow (sdc_session keeps the client's
-- MainMenu sublevel while this is true).
function M.is_open()
    return flow ~= nil and flow.phase == "open"
end

-- sdc_session.join: true = the join is held (no co-op character yet; the
-- creator opens and joins when it is done).
function M.before_join(ip, port, is_auto)
    if bypass_join or cfg.get("char_create") == false or M.stored then return false end
    if flow then
        flow.pending = { ip = ip, port = port, is_auto = is_auto }
        return true
    end
    if is_auto then
        log.info("charcreate: menu: automatic join without a co-op character: default character")
        return false
    end
    if not ue.in_main_menu() or (S and S.role == "client") then
        log.info("charcreate: menu: join from outside the main menu without a co-op character: default character")
        toast("Персонаж по умолчанию: своего можно создать в главном меню (панель кооператива).", "warn", 8,
            "join without a co-op character")
        return false
    end
    start_flow({ ip = ip, port = port, is_auto = is_auto }, "join")
    return true
end

-- Co-op panel / console in the main menu: the creator without a join.
function M.open_from_menu(source)
    if flow then return "already open" end
    -- the real main menu: ue.in_main_menu() is also true while dead in a world
    local sess = package.loaded["sdc_session"]
    local in_menu = ue.in_main_menu()
    if type(sess) == "table" and type(sess.in_real_menu) == "function" then
        local okm, real = pcall(sess.in_real_menu)
        if okm then in_menu = real == true end
    end
    if not S or S.role == "client" or not in_menu then
        toast("Персонажа для кооператива можно изменить только в главном меню.", "warn", 6,
            "creator requested outside the main menu")
        return "only in the main menu"
    end
    start_flow(nil, source or "request")
    return "opening"
end

function M.reset_stored()
    M.stored = nil
    local ok = file_path and os.remove(file_path)
    log.info("charcreate: stored character forgotten (file removed: %s)", tostring(ok and true or false))
    return "stored character forgotten; the creator opens on the next join"
end

function M.describe()
    local lines = { "stored: " .. describe_sel(M.stored) }
    if flow then lines[#lines + 1] = "menu flow: " .. tostring(flow.phase) end
    if cl then lines[#lines + 1] = "client: announced=" .. tostring(cl.announced) end
    for key, h in pairs(hosts) do
        lines[#lines + 1] = string.format("host: %s %s %s", host_name(key), h.state, describe_sel(h.sel))
    end
    return table.concat(lines, " | ")
end

local function host_on()
    return S ~= nil and S.role == "host" and cfg.get("char_create") ~= false
end

function M.register_handlers()
    net.on("CHAR", function(f, pc)
        if host_on() then host_on_char(f, pc) end
    end)
    net.on("CHARNONE", function(f, pc)
        if not host_on() then return end
        local h = host_rec(ue.name(pc))
        h.state, h.sel = "default", nil
        log.info("charcreate: host: %s takes the default character (%s)", host_name(ue.name(pc)), tostring(f[1]))
    end)
    net.on("CHARACK", function(f)
        if cl then cl.acked = true end
        if f[1] == "got" then
            log.info("charcreate: client: the host has the character (its character spawns with it)")
        else
            log.info("charcreate: client: host applied the character (%s: %s)", tostring(f[1]), tostring(f[2]))
        end
    end)
end

-- session: the sdc_session module; mod_dir: Mods\SDCoop
function M.init(session, mod_dir)
    S = session.state
    session_mod = session
    file_path = (mod_dir or "ue4ss/Mods/SDCoop") .. "/character.txt"
    M.stored = load_file()
    log.info("charcreate: %s", M.stored and ("stored character: " .. describe_sel(M.stored)) or "no stored character")
    session.world_reset_hooks.charcreate = function() M.forget_world() end
    players.join_gate = M.join_gate
    players.before_finish_spawn = M.before_finish_spawn
    -- read by sdc_session.join (see its diff)
    session.before_join = M.before_join
end

return M
