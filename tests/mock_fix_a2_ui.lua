-- Mock test (critic fixes 2026-11-13, group A2): the co-op panel (sdc_ui),
-- settings and strings (sdc_config, sdc_i18n, sdc_log).
--   A2  the status dot's colour is forgotten with the widgets
--   A3  "Open my world" only in the REAL main menu (sdc_lobby.live_main_menu)
--       or with a living character: not while dead in a world
--   A4  Kick / Ban redraw the row at once ("Sure?" before a second click)
--   A5  no Kick / Ban on a player still connecting or already kicked
--   A6  buttons in collapsed rows are not polled
--   A7  the build marker turns the panel off only after two starts in a row
--   A9  the players table is not "menu" while the player is dead in a world
--   C2  no "respawn near the host" row
--   Character tab: whether a co-op character exists (sdc_charcreate.stored)
--   Settings: ai_kill_log / stealth_trace off, persist_early_id, removed keys
-- The engine stubs are logic_ui_i18n.lua's.
-- usage: lua mock_fix_a2_ui.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path
-- the panel without the Steam link unless a test puts a stand-in into
-- package.loaded (the real sdc_steamlink needs the game)
table.insert(package.searchers, 1, function(name)
    if name == "sdc_steamlink" then return function() error("sdc_steamlink: not loaded in this test") end end
end)

local pass, fail = 0, 0
local function ok(cond, what)
    if cond then pass = pass + 1 else fail = fail + 1; io.stderr:write("FAIL: " .. what .. "\n") end
end

-- quiet UE4SS print; keep errors
local real_print = print
local log_lines = {}
print = function(s) log_lines[#log_lines + 1] = tostring(s) end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------
FName = function(s) return { name = s, ToString = function() return s end } end
FText = function(s) return s end

local function autostruct()
    return setmetatable({}, { __index = function(t, k)
        local s = autostruct(); rawset(t, k, s); return s
    end })
end

local created = {}          -- every widget made
local widget_mt
local function make_widget(class)
    local w = setmetatable({ _class = class, _children = {}, _text = "", _checked = false }, widget_mt)
    created[#created + 1] = w
    return w
end
local function slot() return make_widget("Slot") end
local STRUCT_PROPS = { Font = true, WidgetStyle = true, Background = true }
widget_mt = {
    __index = function(t, k)
        if STRUCT_PROPS[k] then local s = autostruct(); rawset(t, k, s); return s end
        if k == "IsValid" then return function() return true end end
        if k == "SetText" then return function(self, s) self._text = s end end
        if k == "GetText" then return function(self) return self._text end end
        if k == "SetToolTipText" then return function(self, s) self._tip = s end end
        if k == "SetHintText" then return function(self, s) self._hint = s end end
        if k == "SetIsChecked" then return function(self, v) self._checked = v end end
        if k == "IsChecked" then return function(self) return self._checked end end
        if k == "SetVisibility" then return function(self, v) self._vis = v end end
        if k == "IsHovered" or k == "IsPressed" then return function() return false end end
        if k == "IsInViewport" then return function() return true end end
        if k:find("^AddChild") or k == "SetContent" then
            return function(self, c) self._children[#self._children + 1] = c; return slot() end
        end
        return function() return nil end
    end,
}

local classes = {}
StaticConstructObject = function(cls, outer)
    return make_widget(cls and cls.name or "?")
end
StaticFindObject = function() return nil end
FindFirstOf = function() return nil end

local culture_lib = { GetCurrentCulture = function() return "en" end, IsValid = function() return true end }
local launched = {}
local ksl = { GetDefaultLanguage = function() return "ru-RU" end, IsValid = function() return true end,
              ConvertToAbsolutePath = function(_, rel) return "C:/Games/SurrounDead/Binaries/Win64/" .. rel end,
              LaunchURL = function(_, u) launched[#launched + 1] = u end }

local ue = {
    ROLE_AUTHORITY = 3,
    valid = function(o) return type(o) == "table" end,
    try = function(fn, ...) local okk, v = pcall(fn, ...); if okk then return v end end,
    str = function(v) if v == nil then return "" end return type(v) == "table" and (v.name or "") or tostring(v) end,
    fstring = function(v) return v == nil and "" or tostring(v) end,
    name = function(o) return o and "Obj" or "<none>" end,
    short = function() return "Obj" end,
    path = function() return "/Game/Fonts/Test.Test" end,
    class_name = function(o) return o and o._class or "" end,
    prop = function(o, k) return o and rawget(o, k) end,
    set_prop = function(o, k, v) if o then rawset(o, k, v) end return true end,
    find_object = function(path)
        local short = path:match("^/Script/UMG%.(.+)$")
        if short then classes[short] = classes[short] or { name = short, IsValid = function() return true end }; return classes[short] end
        if path:find("KismetInternationalizationLibrary", 1, true) then return culture_lib end
        return nil
    end,
    find_first = function() return nil end,
    ksl = function() return ksl end,
    game_instance = function() return { IsValid = function() return true end } end,
    local_pc = function() return { IsValid = function() return true end } end,
    local_pawn = function() return nil end,
    pawn_of = function() return {} end,
    ping_ms = function() return 42 end,
    in_main_menu = function() return true end,
    map_name = function() return "PersistentLevel" end,
    widget_lib = function() return nil end,
    has_pending_connection = function() return false end,
    delay = function() end,
}
package.loaded["sdc_ue"] = ue

local session = {
    VERSION = "0.6.99",
    state = { role = "standalone", remote = {}, remote_pcs = {}, join = { attempts = 0 } },
    world_reset_hooks = {}, ui_hooks = {},
    join = function() end, disconnect = function() end, host_on_next_load = function() end,
    start_fresh_server = function() end, request_respawn = function() end,
}
-- sdc_session.roster(): host = itself + its remote records, client = the
-- host's last ROSTER (sdc_session's own logic is tested in logic_roster.lua)
session.roster = function()
    local st = session.state
    if st.role == "host" then
        local out = { { name = "Me", state = "host", host = true, me = true } }
        for _, r in pairs(st.remote or {}) do out[#out + 1] = { name = r.name, state = "game", ping = 42 } end
        return out
    elseif st.role == "client" then
        return st.client and st.client.roster or {}
    end
    return {}
end
package.loaded["sdc_session"] = session
package.loaded["sdc_widgets"] = { child = function() return nil end, first_text = function() return nil end }

local log = require("sdc_log")
local errors = {}
local real_err = log.err
log.err = function(msg, ...) errors[#errors + 1] = string.format(tostring(msg), ...); real_err(msg, ...) end
local cfg = require("sdc_config")
local i18n = require("sdc_i18n")
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/fix_a2_ui"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '" 2>nul')
local function vis(w) return w ~= nil and w._vis ~= 1 end
local function exists(p) local fh = io.open(p, "r"); if fh then fh:close(); return true end; return false end

-- ---------------------------------------------------------------------------
-- Settings and strings
-- ---------------------------------------------------------------------------
ok(cfg.get("ai_kill_log") == false and cfg.get("stealth_trace") == false, "ai_kill_log / stealth_trace default off")
local row = i18n.schema_row("persist_early_id")
ok(row and row[2] == "bool" and row[3] == true and row[4]:find("без ожидания", 1, true) ~= nil,
    "persist_early_id: bool, default on, Russian description")
ok(i18n.DESC_EN.persist_early_id and i18n.DESC_EN.persist_early_id:find("saved place", 1, true) ~= nil, "persist_early_id: English description")
ok(i18n.LABEL.persist_early_id and i18n.group_of("persist_early_id") == "saves", "persist_early_id: label, group saves")
for _, k in ipairs({ "ui_show_steam", "host_by_ip", "steam_p2p" }) do
    ok(i18n.schema_row(k) == nil and cfg.get(k) == nil and i18n.DESC_EN[k] == nil and i18n.LABEL[k] == nil
        and i18n.GROUP_OF[k] == nil, "removed setting " .. k)
end
ok(i18n.HIDDEN == nil, "no hidden-settings list left")
ok(i18n.schema() == cfg.SCHEMA, "i18n.schema() is sdc_config.SCHEMA")
local pen = i18n.schema_row("player_event_notes")[4]
ok(not pen:find("волк", 1, true) and not i18n.DESC_EN.player_event_notes:find("wolf", 1, true),
    "player_event_notes no longer promises a cause (RU / EN)")
ok(i18n.schema_row("menu_in_main_menu")[4]:find("lobby = false", 1, true) ~= nil
    and i18n.DESC_EN.menu_in_main_menu:find("lobby = false", 1, true) ~= nil, "menu_in_main_menu: works only with lobby = false")
ok(i18n.LABEL.infestation_xp_radius_m == nil and i18n.GROUP_OF.banned_players == nil
    and i18n.GROUP_OF.steam_link_allow == nil and i18n.GROUP_OF.infestation_xp_radius_m == nil, "no labels / groups for non-bool settings")
for _, k in ipairs({ "f_name", "steam_later", "steam_off", "steam_no_steam", "steam_starting", "steam_ready", "steam_hosting",
                     "steam_joining", "steam_connected", "steam_error", "steam_friend_hosting", "steam_friend_playing",
                     "btn_respawn", "pe_died_zombie", "pe_died_wolf", "pe_died_bear", "pe_died_animal", "pe_died_human",
                     "pe_died_fall", "pe_died_player", "pe_died_you" }) do
    ok(i18n.STR.ru[k] == nil and i18n.STR.en[k] == nil, "string removed: " .. k)
end
ok(i18n.TOAST_EXACT["Мод включил серверную часть Steam. Перезапустите игру через Steam один раз и снова откройте мир для друзей."] == nil,
    "unused Steam toast translation removed")
ok(log.TEXT.you_died == nil and i18n.SAY_CLASS.you_died == nil and i18n.SAY.en.you_died == nil, "you_died removed")
for _, k in ipairs({ "btn_looks_new", "char_made", "char_made_named", "char_sex_female", "char_sex_male", "char_none", "char_off" }) do
    ok(i18n.STR.ru[k] ~= nil and i18n.STR.en[k] ~= nil, "new string RU + EN: " .. k)
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------
local UI = require("sdc_ui")
UI.VERSION = "0.7.3"
cfg.set("language", "ru")
local okb, errb = pcall(UI.build)
ok(okb, "UI.build runs: " .. tostring(errb))

-- C2
ok(UI.set_dead == nil and UI.respawn_row == nil and session.ui_hooks.dead == nil, "C2: no respawn row, no death hook")

-- A2
UI.set_open(true)
UI.refresh_status()
ok(UI.dot_color ~= nil, "A2: the status dot has a colour")
UI.forget_world("loadmap")
ok(UI.dot_color == nil, "A2: forgotten with the widgets")
pcall(UI.build)
UI.set_open(false)
UI.set_open(true)

-- A3: dead in a single-player world = in_main_menu() true, but no live menu
local live_menu = nil
package.loaded["sdc_lobby"] = { live_main_menu = function() return live_menu end }
session.state.role = "standalone"
cfg.set("listen_on_load", false)
ue.in_main_menu = function() return true end
ue.local_pawn = function() return nil end
UI.menu_at = nil
UI.refresh_status()
ok(not vis(UI.host_row), "A3: dead in a world (no live main menu): no «Open my world»")
ok(not vis(UI.char_row) and vis(UI.looks_off), "A3: dead in a world: no appearance button")
live_menu = { IsValid = function() return true end }
UI.menu_at = nil
UI.refresh_status()
ok(vis(UI.host_row) and vis(UI.host_caption_menu) and not vis(UI.host_caption_world), "A3: the real main menu: «Open my world» (menu caption)")
ok(vis(UI.char_row), "the real main menu: the appearance button")
live_menu = nil
ue.in_main_menu = function() return false end
ue.local_pawn = function() return {} end
UI.menu_at = nil
UI.refresh_status()
ok(vis(UI.host_row) and vis(UI.host_caption_world), "A3: alive in a world: «Open my world» (reload caption)")
ue.local_pawn = function() return nil end

-- A9: the players table while the host is dead (in_main_menu() true, no live menu)
session.state.role = "host"
session.state.remote_pcs = { {} }
session.state.remote = { k1 = { name = "Bob", pc = {} } }
UI.set_open(false)
ue.in_main_menu = function() return true end
UI.menu_at = nil
local hm = UI.players_hud_model()
ok(hm.visible and hm.why == nil, "A9: dead host: the players table stays (" .. tostring(hm.why) .. ")")
live_menu = { IsValid = function() return true end }
UI.menu_at = nil
hm = UI.players_hud_model()
ok(not hm.visible and hm.why == "menu", "A9: the real main menu: no table")
live_menu = nil
ue.in_main_menu = function() return false end
UI.menu_at = nil

-- A5 / A4 / A6: the players section with Kick / Ban
local kicks = {}
local admin = { banned_names = function() return {} end }
function admin.kick(key, ban) kicks[#kicks + 1] = { key = key, ban = ban }; return true end
package.loaded["sdc_admin"] = admin
local roster = {
    { name = "Me", state = "host", host = true, me = true },
    { name = "Bob", state = "game", ping = 42, key = "k_bob" },
    { name = "Player 3", state = "connecting", key = "k_new" },
    { name = "Gone", state = "game", ping = 10, key = "k_gone" },
    { name = "Vasya", state = "loading", ping = 90, key = "k_vasya" },
}
local saved_roster = session.roster
session.roster = function() return roster end
session.state.remote = { k_bob = { name = "Bob" }, k_gone = { name = "Gone", kicked = os.time() }, k_vasya = { name = "Vasya" } }
UI.set_open(true)
UI.refresh_status()
local pm = UI.players_model()
ok(pm.rows[2].acts == true and pm.rows[5].acts == true, "A5: Kick / Ban for players in game / loading")
ok(pm.rows[3].acts == false, "A5: no Kick / Ban for a player still connecting")
ok(pm.rows[4].acts == false, "A5: no Kick / Ban for a player already kicked (session record)")
admin.is_kicked = function(key) return key == "k_vasya" end
pm = UI.players_model()
ok(pm.rows[5].acts == false and pm.rows[4].acts == true, "A5: sdc_admin.is_kicked is asked when it exists")
admin.is_kicked = nil
UI.players_sig = nil
UI.refresh_status()
ok(vis(UI.player_rows[2].acts) and UI.player_rows[3].acts._vis == 2 and UI.off[UI.player_rows[3].acts] == true,
    "A5: the rows show it (the connecting row's buttons hidden, keeping their space)")
UI.on_kick(3)
ok(#kicks == 0, "A5: a click on a connecting player's row does nothing")
-- A6: the polled list
UI.frame_tick()
local function polled(label, row_i)
    for _, b in ipairs(UI.active) do
        if b.label == label then
            if not row_i then return true end
            for _, g in ipairs(b.gates) do if g == UI.player_rows[row_i].acts then return true end end
        end
    end
    return false
end
ok(polled("kick", 2) and polled("ban", 2), "A6: Kick / Ban of a row with buttons are polled")
ok(not polled("kick", 3) and not polled("ban", 3) and not polled("kick", 7), "A6: hidden / unused rows' buttons are not polled")
ok(not polled("btn_host") and not polled("btn_disconnect"), "A6: the host's hidden header buttons are not polled")
-- A4: Ban -> "Sure?" at once
UI.on_ban(2)
ok(UI.player_rows[2].ban_text._text == "Точно?", "A4: «Sure?» right after the first click: " .. tostring(UI.player_rows[2].ban_text._text))
UI.on_ban(2)
ok(#kicks == 1 and kicks[1].key == "k_bob" and kicks[1].ban == true, "A4: the second click bans")
session.state.remote.k_bob.kicked = os.time()
UI.on_kick(5)
ok(#kicks == 2 and kicks[2].key == "k_vasya" and kicks[2].ban == false, "kick")
session.state.remote.k_vasya.kicked = os.time()
UI.players_sig = nil
UI.refresh_status()
ok(not vis(UI.player_rows[2].acts) and not vis(UI.player_rows[5].acts), "kicked players lose their buttons")
UI.frame_tick()
ok(not polled("kick", 2) and not polled("ban", 5), "A6: and they are not polled any more")
session.roster = saved_roster
package.loaded["sdc_admin"] = nil
session.state.role, session.state.remote, session.state.remote_pcs = "client", {}, {}
session.state.client = { host_name = "Alice", roster = {} }
UI.refresh_status()
UI.frame_tick()
ok(polled("btn_disconnect"), "A6: a client's Disconnect is polled")
session.state.role, session.state.client = "standalone", nil

-- Character tab
package.loaded["sdc_charcreate"] = nil
UI.char_sig = nil
UI.pick_tab("char")
ok(not vis(UI.char_info) and UI.looks_text._text == "Изменить внешность", "char: no sdc_charcreate -> no line")
local opened = {}
local cc = { stored = nil, open_from_menu = function(src) opened[#opened + 1] = src end }
package.loaded["sdc_charcreate"] = cc
UI.pick_tab("ip"); UI.pick_tab("char")
ok(vis(UI.char_info) and UI.char_info._text == "Персонаж ещё не создан — редактор откроется при первом подключении.",
    "char: not made yet: " .. tostring(UI.char_info._text))
ok(UI.looks_text._text == "Создать персонажа", "char: button «Создать персонажа»")
cc.stored = { sex = "Female", first = "Анна", last = "", occ = 0, labels = {} }
UI.set_open(false); UI.set_open(true)
ok(UI.char_info._text == "Персонаж создан: Женщина, Анна." and UI.looks_text._text == "Изменить внешность",
    "char: made (opening the panel updates it): " .. tostring(UI.char_info._text))
cc.stored = { sex = "Male", forename = "Bob", surname = "Smith" }
UI.pick_tab("ip"); UI.pick_tab("char")
ok(UI.char_info._text == "Персонаж создан: Мужчина, Bob Smith.", "char: forename / surname fields: " .. tostring(UI.char_info._text))
cc.stored = { sex = "Female", first = "", last = "" }
UI.pick_tab("ip"); UI.pick_tab("char")
ok(UI.char_info._text == "Персонаж создан: Женщина.", "char: no name: " .. tostring(UI.char_info._text))
i18n.set("en")
ok(UI.char_info._text == "Character created: Female." and UI.looks_text._text == "Change appearance", "char: English")
cc.stored = nil
UI.pick_tab("ip"); UI.pick_tab("char")
ok(UI.looks_text._text == "Create a character" and UI.char_info._text:find("No character yet", 1, true) ~= nil, "char: English, not made")
i18n.set("en")
UI.relabel()
ok(UI.looks_text._text == "Create a character", "char: a relabel keeps the right button label")
cfg.set("char_create", false)
UI.pick_tab("ip"); UI.pick_tab("char")
ok(UI.char_info._text:find("off in the settings", 1, true) ~= nil and UI.looks_text._text == "Change appearance", "char: char_create off")
cfg.set("char_create", true)
cfg.set("language", "ru")
-- the button opens the creator through sdc_charcreate
ue.in_main_menu = function() return true end
live_menu = { IsValid = function() return true end }
UI.menu_at = nil
UI.set_open(true)
UI.refresh_status()
local looks = nil
for _, b in ipairs(UI.buttons) do if b.label == "looks" then looks = b end end
ok(looks ~= nil, "char: the appearance button is registered")
UI.frame_tick()
local polled_looks = false
for _, b in ipairs(UI.active) do if b == looks then polled_looks = true end end
ok(polled_looks, "char: polled in the real main menu")
looks.fn()
ok(opened[1] == "panel" and not UI.open, "char: it closes the panel and opens the creator")
live_menu = nil

ok(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- A7: the build marker (its own error line is expected)
os.remove(TMP .. "/ui_build.marker")
local f = io.open(TMP .. "/ui_build.marker", "w"); f:write("building\n"); f:close()   -- an older build's marker
UI.disabled = false
UI.check_crash_marker(TMP)
ok(UI.disabled == false and UI.marker_hits == 1, "A7: one start that crashed while building: the panel stays on")
UI.forget_world("loadmap")
UI.ensure()
ok(UI.widget ~= nil, "A7: built")
local fh = io.open(TMP .. "/ui_build.marker", "r")
local line = fh and fh:read("*l")
if fh then fh:close() end
ok(line == "1", "A7: this build's marker holds the earlier hit (" .. tostring(line) .. ")")
UI.check_crash_marker(TMP)
ok(UI.disabled == true, "A7: two starts in a row: the panel is off")
UI.disabled = false
os.remove(TMP .. "/ui_build.marker")
UI.check_crash_marker(TMP)
ok(UI.disabled == false and UI.marker_hits == 0, "A7: no marker: on")
print = real_print
print(string.format("fix a2 ui: %d checks, %d failed%s", pass + fail, fail, fail == 0 and ", ALL OK" or ""))
os.exit(fail == 0 and 0 or 1)
