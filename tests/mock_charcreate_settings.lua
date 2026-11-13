-- Mock test: the main menu's character creator flow (sdc_charcreate) reads the
-- choice WITHOUT reading CharacterCreatorMenu_C's Blueprint variables by name.
-- Why: UE4SS 3.0.1 (4fb9b615) keeps every by-name property lookup forever,
-- keyed by (class address, name); the creator's class exists only in the main
-- menu and is reloaded with it (every failed join of a client reloads the
-- menu world), and a reloaded class at its old address gets the freed
-- property of the old one (crash 2026-11-13, MenuWidget_C's "Load").
--   A  New Game -> creator -> Continue (post-hook): the choice comes from the
--      BP_NewGameSettings actor found with GameplayStatics.GetActorOfClass
--      (as the creator itself does) and from the creator's text boxes /
--      drop-downs found with GetWidgetFromName; character.txt written
--   B  GetActorOfClass gives nothing: the actor from FindAllOf
-- Any ue.prop / ue.set_prop on the creator or the main menu widget is recorded.
-- usage: lua mock_charcreate_settings.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/charcreate_settings"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '" 2>nul')
os.remove(TMP .. "/character.txt")

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

-- every other sdc_ module: an automatic stub (any field is a function returning nil)
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_charcreate = true, sdc_widgets = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)

local LOG = {}
local function logline(kind) return function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    LOG[#LOG + 1] = kind .. (ok and s or tostring(fmt))
end end
local nop = function() end
package.loaded["sdc_log"] = setmetatable({
    info = logline(""), warn = logline("[WARN] "), err = logline("[ERROR] "),
    err_throttled = function(_, fmt, ...) logline("[ERROR] ")(fmt, ...) end,
    debug = nop, ascii = function(s) return s end, toast = nop,
}, { __index = function() return nop end })
package.loaded["sdc_config"] = { get = function() return nil end, set = nop, save = nop }

FName = function(s) return { ToString = function() return s end } end
FText = function(s) return s end
local HOOKS = {}
RegisterHook = function(path, fn) HOOKS[path] = fn; return 1, 2 end

-- ---------------------------------------------------------------- fake objects
-- o.props: Blueprint variables (read through ue.prop); methods are fields
local function obj(cls, key, props, methods)
    local o = methods or {}
    o.cls, o.key, o.props = cls, key, props or {}
    o.IsValid = function(self) return not self.dead end
    o.GetFName = function() return { ToString = function() return key end } end
    o.GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end
    return o
end
local function asset(rel) return obj("StaticMesh", rel, {}, { path = "/Game/PlayerModel/" .. rel }) end

local PROP_READS = {}   -- by-name reads on the creator / menu widgets
local TRAPPED = {}
local ue = stub()
ue.valid = function(o) return type(o) == "table" and not o.dead end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.class_name = function(o) return type(o) == "table" and (o.cls or "") or "" end
ue.path = function(o) return type(o) == "table" and (o.path or o.key) or "" end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.prop = function(o, k)
    if type(o) ~= "table" then return nil end
    if TRAPPED[o] then PROP_READS[#PROP_READS + 1] = o.cls .. "." .. tostring(k); return { stale = true } end
    return o.props[k]
end
ue.set_prop = function(o, k, v)
    if type(o) ~= "table" then return false end
    if TRAPPED[o] then PROP_READS[#PROP_READS + 1] = o.cls .. "." .. tostring(k) .. "="; return false end
    o.props[k] = v
    return true
end
ue.in_main_menu = function() return true end
ue.ems_current_slot = function() return "MySlot" end
ue.load_asset = function() return false end

local PATHS, ALL, LIVE = {}, {}, {}
ue.find_object = function(path) return PATHS[path] end
ue.find_all = function(cls) return ALL[cls] or {} end

local CREATOR_CLASS = "/Game/UI/Menus/Menu/CharacterCreatorMenu.CharacterCreatorMenu_C"
local MENU_CLASS = "/Game/UI/Menus/Menu/MenuWidget.MenuWidget_C"
local SETTINGS_CLASS = "/Game/Blueprints/BP_NewGameSettings.BP_NewGameSettings_C"
local FN_CONTINUE = CREATOR_CLASS .. ":BndEvt__CharacterCreatorMenu_ContinueButton_K2Node_ComponentBoundEvent_14_OnButtonClickedEvent__DelegateSignature"
for _, p in ipairs({ CREATOR_CLASS, MENU_CLASS, SETTINGS_CLASS }) do
    PATHS[p] = obj("BlueprintGeneratedClass", p:match("%.([^%.]+)$"))
end
PATHS["/Script/EasyMultiSave.Default__EMSFunctionLibrary"] = obj("EMSFunctionLibrary", "Default__EMSFunctionLibrary",
    {}, { SetCurrentSaveGameName = function() end })

local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_0")
ue.local_pc = function() return pc end
ue.game_instance = function() return nil end
local wbl = obj("WidgetBlueprintLibrary", "Default__WidgetBlueprintLibrary", {}, {
    GetAllWidgetsOfClass = function(_, _, arr, cls)
        for _, w in ipairs(LIVE[cls.key] or {}) do if not w.dead then arr[#arr + 1] = w end end
    end,
})
ue.widget_lib = function() return wbl end
local GAOC = { calls = 0, answer = true }
local settings          -- the MainMenu level's BP_NewGameSettings actor
local gps = obj("GameplayStatics", "Default__GameplayStatics", {}, {
    GetActorOfClass = function(_, wc, cls)
        GAOC.calls, GAOC.ctx, GAOC.cls = GAOC.calls + 1, wc, cls
        if GAOC.answer then return settings end
        return obj("Actor", "None", {}, { dead = true })
    end,
})
ue.gameplay_statics = function() return gps end
package.loaded["sdc_ue"] = ue

-- the creator: its text boxes and drop-downs are designer widgets
local function creator_widget()
    local kids = {
        EditableTextBox_Forename = obj("EditableTextBox", "EditableTextBox_Forename", {}, { GetText = function() return "Anna" end }),
        EditableTextBox_Surname = obj("EditableTextBox", "EditableTextBox_Surname", {}, { GetText = function() return "Berg" end }),
        EditableTextBox_Age = obj("EditableTextBox", "EditableTextBox_Age", {}, { GetText = function() return "31" end }),
        DropDownSex = obj("ComboBoxString", "DropDownSex", {}, { GetSelectedOption = function() return "Female" end }),
        DropDownHairType = obj("ComboBoxString", "DropDownHairType", {}, { GetSelectedOption = function() return "Long" end }),
    }
    local w = obj("CharacterCreatorMenu_C", "CharacterCreatorMenu_C_2147480100", {
        NewGameSettings = settings,   -- the Blueprint variable: must not be read
    }, {
        GetWidgetFromName = function(_, fname) return kids[fname:ToString()] end,
        Exit = function(self) self.exited = true end,
    })
    TRAPPED[w] = true
    return w
end
local creator
local menu = obj("MenuWidget_C", "MenuWidget_C_2147482001", {}, {
    BndEvt__Play_K2Node_ComponentBoundEvent_11_OnButtonClickedEvent__DelegateSignature = function()
        creator = creator_widget()
        LIVE.CharacterCreatorMenu_C = { creator }
    end,
})
TRAPPED[menu] = true

local function new_settings(sex)
    settings = obj("BP_NewGameSettings_C", "BP_NewGameSettings_2", {
        Sex = sex, SkinColor = asset("Materials/2/M_Chr_Texture_2A.M_Chr_Texture_2A"),
        HairMesh = asset("Hair/Long/SM_Hair_Long.SM_Hair_Long"), HairColor = asset("Hair/Material/Black/MI_Black.MI_Black"),
        EyebrowsMesh = asset("Hair/Eyebrows/Chr_Eyebrows2.Chr_Eyebrows2"), Occupation = 2,
        Forename = "Settings", Surname = "Only", Age = "40",
    })
    ALL.BP_NewGameSettings_C = { settings }
end

local session = { state = { role = "standalone" }, world_reset_hooks = {} }
local cc = require("sdc_charcreate")
cc.init(session, TMP)
check(cc.stored == nil, "no stored character at the start")

local function run_flow()
    LIVE.MenuWidget_C, LIVE.CharacterCreatorMenu_C = { menu }, nil
    creator = nil
    check(cc.open_from_menu("test") == "opening", "creator requested in the main menu")
    cc.tick()
    check(creator ~= nil and cc.is_open(), "New Game ran: the creator is open")
    local hook = HOOKS[FN_CONTINUE]
    check(type(hook) == "function", "Continue post-hook registered")
    if hook then hook({ get = function() return creator end }) end
    check(creator and creator.exited == true, "the creator's Exit brought the main menu back")
    LIVE.CharacterCreatorMenu_C = nil
    cc.tick()
end

print("A: Continue -> the choice, without the creator's NewGameSettings variable")
new_settings("Female")
run_flow()
local s = cc.stored
check(s ~= nil, "a character is stored")
if s then
    check(s.sex == "Female" and s.hair == "Hair/Long/SM_Hair_Long.SM_Hair_Long" and s.occ == 2,
        "fields from the BP_NewGameSettings actor (sex, hair, occupation)")
    check(s.first == "Anna" and s.last == "Berg" and s.age == "31", "names from the creator's text boxes")
    check(s.labels and s.labels.DropDownSex == "Female" and s.labels.DropDownHairType == "Long",
        "drop-down labels from the creator's combos")
end
check(GAOC.calls >= 1 and GAOC.cls == PATHS[SETTINGS_CLASS], "GameplayStatics.GetActorOfClass(BP_NewGameSettings_C) asked")
check(GAOC.ctx == creator, "with the creator as the world context")
check(#PROP_READS == 0, "no by-name read of CharacterCreatorMenu_C / MenuWidget_C variables ("
    .. table.concat(PROP_READS, " ") .. ")")
local f = io.open(TMP .. "/character.txt", "r")
local body = f and f:read("a") or ""
if f then f:close() end
check(body:find("sex = Female", 1, true) ~= nil and body:find("first = Anna", 1, true) ~= nil, "character.txt written")

print("B: GetActorOfClass finds nothing -> the actor from FindAllOf")
cc.reset_stored()
new_settings("Male")
GAOC.answer = false
run_flow()
check(cc.stored ~= nil and cc.stored.sex == "Male", "the choice from the FindAllOf actor")
check(#PROP_READS == 0, "still no by-name read of the creator's variables (" .. table.concat(PROP_READS, " ") .. ")")

os.remove(TMP .. "/character.txt")
print(string.format("charcreate settings: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
