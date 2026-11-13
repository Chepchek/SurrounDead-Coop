-- SDCoop: co-op panel + RU/EN checks (sdc_ui, sdc_i18n, sdc_log toast path).
--   lua logic_ui_i18n.lua <scripts dir>
-- 1. the i18n string tables cover every panel key in both languages;
-- 2. every SCHEMA key has an English description (and every bool a label);
-- 3. toast translation: real strings from the modules, patterns, log.say;
-- 4. sdc_ui.build runs against stub UMG classes: tabs, sections, every bool
--    setting reachable, relabel to English, open / status / frame tick.
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

-- ---------------------------------------------------------------------------
-- 1. string tables
-- ---------------------------------------------------------------------------
for k in pairs(i18n.STR.ru) do ok(i18n.STR.en[k] ~= nil, "EN string for panel key " .. k) end
for k in pairs(i18n.STR.en) do ok(i18n.STR.ru[k] ~= nil, "RU string for panel key " .. k) end

-- every literal key the panel asks for
local f = assert(io.open(dir .. "/sdc_ui.lua", "r"))
local src = f:read("a"); f:close()
local used = {}
for _, fn in ipairs({ "T", "ltext", "heading", "caption", "button", "lfn" }) do
    for key in src:gmatch("[^%w_]" .. fn .. "%(%s*\"([%w_]+)\"") do
        if not key:find("_$") then used[key] = true end
    end
end
for _, id in ipairs({ "steam", "ip", "char", "settings" }) do used["tab_" .. id] = true end
for _, v in ipairs({ "auto", "ru", "en" }) do used["lang_" .. v] = true end
for _, g in ipairs(i18n.GROUPS) do used["g_" .. g] = true end
local n_used = 0
for key in pairs(used) do
    n_used = n_used + 1
    ok(i18n.STR.ru[key] ~= nil, "RU string used by the panel: " .. key)
    ok(i18n.STR.en[key] ~= nil, "EN string used by the panel: " .. key)
end
ok(n_used >= 60, "the panel uses many catalog keys (" .. n_used .. ")")

-- ---------------------------------------------------------------------------
-- 2. SCHEMA descriptions and labels
-- ---------------------------------------------------------------------------
local schema = i18n.schema()
ok(#schema >= 140, "SCHEMA read through sdc_i18n.schema() (" .. #schema .. " rows)")
local nbool, nolabel = 0, {}
for _, row in ipairs(schema) do
    ok(type(i18n.DESC_EN[row[1]]) == "string" and i18n.DESC_EN[row[1]] ~= "", "EN description for " .. row[1])
    if row[2] == "bool" and not (i18n.HIDDEN or {})[row[1]] then
        nbool = nbool + 1
        if not i18n.LABEL[row[1]] then nolabel[#nolabel + 1] = row[1] end
    end
end
if #nolabel > 0 then
    io.stderr:write("note: bool settings without a hand-written label (cut from the description): "
        .. table.concat(nolabel, ", ") .. "\n")
end
for _, k in ipairs({ "language", "ui_open_at_menu", "persist_early_id" }) do
    ok(i18n.schema_row(k) ~= nil, "SCHEMA key " .. k)
end
ok(cfg.get("language") == "auto" and cfg.get("ui_open_at_menu") == false and cfg.get("persist_early_id") == true,
    "keys default to auto / false / true")
for _, k in ipairs({ "ui_show_steam", "host_by_ip", "steam_p2p" }) do
    ok(i18n.schema_row(k) == nil and i18n.DESC_EN[k] == nil and i18n.LABEL[k] == nil and i18n.GROUP_OF[k] == nil,
        "removed setting " .. k .. ": no SCHEMA row, description, label or group")
end
ok(cfg.get("ai_kill_log") == false and cfg.get("stealth_trace") == false, "diagnostic logs ai_kill_log / stealth_trace default off")
for _, k in ipairs(i18n.MAIN) do ok(i18n.schema_row(k) ~= nil, "curated setting exists: " .. k) end
-- every bool lands in exactly one group
local grouped = {}
for _, g in ipairs(i18n.groups()) do for _, k in ipairs(g.keys) do grouped[k] = (grouped[k] or 0) + 1 end end
local ng = 0
for _ in pairs(grouped) do ng = ng + 1 end
ok(ng == nbool, "every bool setting is in a group (" .. ng .. "/" .. nbool .. ")")
-- the label cutter on a description without a label
ok(i18n.short("Хост: любой загруженный мир (сохранение/новая игра) сразу открыт для друзей") ==
    "Любой загруженный мир сразу открыт для друзей", "short label from a description")

-- ---------------------------------------------------------------------------
-- 3. toast translation
-- ---------------------------------------------------------------------------
local shown = nil
log.toast_sink = function(text) shown = text end

-- language detection: the game's culture is "en" (no Russian in the game),
-- Windows is Russian -> auto = ru
ok(i18n.detect() == true and i18n.auto_lang == "ru", "auto language from a Russian Windows: ru")
ok(i18n.language() == "ru", "language auto -> ru")
log.toast("Подключение отменено.", "info")
ok(shown == "Подключение отменено.", "RU toast unchanged in Russian")

cfg.set("language", "en")
ok(i18n.language() == "en", "language en")
-- every literal toast text in the modules translates
local files = {}
local p = io.popen('ls "' .. dir .. '"')
if p then for name in p:lines() do if name:match("%.lua$") then files[#files + 1] = name end end p:close() end
local literals, missing = 0, {}
local function check_literal(s, where)
    if not s:find("[\208\209]") then return end
    literals = literals + 1
    shown = nil
    log.toast(s, "info")
    if not shown or shown:find("[\208\209]") then missing[#missing + 1] = where .. ": " .. s end
end
for _, name in ipairs(files) do if name ~= "sdc_i18n.lua" then
    local h = io.open(dir .. "/" .. name, "r")
    if h then
        local text = h:read("a"); h:close()
        -- whole literals passed to log.toast / a local toast(ru, ...) helper / dialogue notice(key, ru, en)
        for s in text:gmatch("[^%w_]toast%(%s*\"([^\"]+)\"%s*,") do check_literal(s, name) end
        for s in text:gmatch("notice%(%s*\"[^\"]+\"%s*,%s*\"([^\"]+)\"") do check_literal(s, name) end
        -- QF_TEXT / QN_TEXT style tables: { "Russian", "english log text" }
        for s in text:gmatch("{%s*\"([^\"]*[\208\209][^\"]*)\",%s*\n?%s*\"[%a][^\"]*\"%s*}") do check_literal(s, name) end
    end
end
end
io.stderr:write(string.format("toast literals checked: %d%s", literals, string.char(10)))
ok(literals >= 20, "found the modules' toast literals (" .. literals .. ")")
ok(#missing == 0, "every toast literal has English: " .. table.concat(missing, " | "))

local samples = {
    { "Рядом найден другой UE4SS-мод (UE4SS.dll, Mods/mods.txt). Он может сломать SDCoop: см. README_SDCoop.txt.",
      "Another UE4SS mod was found next to SDCoop (UE4SS.dll, Mods/mods.txt). It can break SDCoop: see README_SDCoop.txt." },
    { "Сохранения: «Продолжить» снова указывает на ваше сохранение Slot_3 (игра была закрыта во время подключения к другу).",
      "Saves: Continue points to your save Slot_3 again (the game was closed while connected to a friend)." },
    { "Мир сохранён в новый слот SDCoop_7 (текущим был временный слот клиента).",
      "The world was saved into a new slot SDCoop_7 (the current one was the client's temporary slot)." },
    { "Задание выполнено: Find the radio (+250 опыта)", "Quest completed: Find the radio (+250 XP)" },
    { "Новое задание: Clear the camp", "New quest: Clear the camp" },
    { "Задания группы: 3", "Group quests: 3" },
}
for _, s in ipairs(samples) do
    shown = nil
    log.toast(s[1], "info")
    ok(shown == s[2], "pattern: " .. s[2] .. " (got " .. tostring(shown) .. ")")
end

-- log.say: the catalog's English, overrides, Russian arguments translated
log.TEXT.unstuck_refused = log.TEXT.unstuck_refused or { "Unstuck: the host refused.", "Хост не перенёс персонажа: %s." }
log.say("unstuck_refused", "warn", 6, "нет места")
ok(shown == "The host didn't move your character: no free spot.", "say + Russian argument: " .. tostring(shown))
log.say("player_joined", "ok", 6, "Вася")
ok(shown == "Вася joined.", "say with a Cyrillic name: " .. tostring(shown))
log.say("listen_failed", "err", 10)
ok(shown and shown:find("New map without a save", 1, true) ~= nil, "listen_failed names the new button (EN)")
ok(log.tr("btn_respawn_host") == "Respawn: near the host", "log.tr in English")
cfg.set("language", "ru")
log.say("listen_failed", "err", 10)
ok(shown and shown:find("Новая карта без сохранения", 1, true) ~= nil, "listen_failed names the new button (RU)")
log.say("player_joined", "ok", 6, "Вася")
ok(shown == "Вася подключился.", "say in Russian")
ok(i18n.coop_label() == "Кооператив", "lobby label RU")
cfg.set("language", "en")
ok(i18n.coop_label() == "Co-op", "lobby label EN")
cfg.set("language", "auto")

-- ---------------------------------------------------------------------------
-- 4. the panel against stub UMG
-- ---------------------------------------------------------------------------
local UI = require("sdc_ui")
UI.VERSION = "0.6.99"
local okb, errb = pcall(UI.build)
ok(okb, "UI.build runs: " .. tostring(errb))
ok(UI.widget ~= nil and UI.panel ~= nil, "widget and panel made")
ok(UI.pages.steam and UI.pages.ip and UI.pages.char and UI.pages.settings and not UI.pages.play, "four tab pages")
ok(#UI.buttons >= 15, "buttons registered (" .. #UI.buttons .. ")")
ok(UI.inputs.host_ip and UI.inputs.port and UI.inputs.player_name, "inputs bound to config keys")
ok(UI.tab == "ip", "no Steam link: starts on the IP tab")
local function texts_with(pattern)
    local n = 0
    for _, w in ipairs(created) do
        if w._class == "TextBlock" and type(w._text) == "string" and w._text:find(pattern) then n = n + 1 end
    end
    return n
end
ok(texts_with("^Кооператив$") == 1, "title in Russian")
ok(texts_with("^Открыть мир для друзей$") == 1, "host button label")
UI.refresh_status()
ok(UI.steam_later == nil and UI.steam_status_row._vis ~= 1 and UI.steam_status._text == "Ошибка Steam-соединения.",
    "without sdc_steamlink: the status row says the Steam link is broken")
-- no text shows a raw catalog key
local raw = {}
for _, w in ipairs(created) do
    if w._class == "TextBlock" and type(w._text) == "string" and w._text:match("^[a-z][a-z0-9]*_[a-z0-9_]+$") then
        raw[#raw + 1] = w._text
    end
end
ok(#raw == 0, "no raw keys on screen: " .. table.concat(raw, ", "))

-- settings: «Основное» built (open), «Все функции мода» lazily
UI.pick_tab("settings")
ok(UI.tab == "settings", "settings tab")
-- (besides the World tab's own boxes: friendly_fire is not in «Основное»)
local main_n = 0
for k in pairs(UI.checks) do
    if not (UI.world_checks or {})[k] or #UI.checks[k] > 1 then main_n = main_n + 1 end
end
ok(main_n == #i18n.MAIN, "Основное: " .. main_n .. " checkboxes")
local all_sec = nil
for _, sec in ipairs(UI.sections) do if sec.name == "all" then all_sec = sec end end
ok(all_sec and not all_sec.built, "«Все функции мода» not built until opened")
UI.toggle_section(all_sec, true)
ok(all_sec.built, "«Все функции мода» built on open")
local groups = 0
for _, sec in ipairs(UI.sections) do
    if sec.name:find("^group ") then
        groups = groups + 1
        ok(not sec.open, "group collapsed by default: " .. sec.name)
        UI.toggle_section(sec, true)
    end
end
ok(groups >= 8, "setting groups (" .. groups .. ")")
local reach = 0
for _, row in ipairs(schema) do
    if row[2] == "bool" and not (i18n.HIDDEN or {})[row[1]] then
        if UI.checks[row[1]] then reach = reach + 1 else ok(false, "no checkbox for " .. row[1]) end
    end
end
ok(reach == nbool, "every bool setting has a checkbox (" .. reach .. "/" .. nbool .. ")")
-- number settings right under their switch (i18n.NUMS_OF): a label and a box bound to the key
local nnum = 0
for sw, list in pairs(i18n.NUMS_OF or {}) do
    ok(UI.checks[sw] ~= nil, "a switch with numbers has its checkbox: " .. sw)
    for _, nk in ipairs(list) do
        nnum = nnum + 1
        local row = i18n.schema_row(nk)
        ok(row ~= nil and row[2] == "int", "number setting is an int in SCHEMA: " .. nk)
        ok(i18n.LABEL[nk] ~= nil, "number setting has a label: " .. nk)
        local e = UI.inputs[nk]
        ok(e ~= nil and tostring(e._text) == tostring(cfg.get(nk)), "its box shows the setting: " .. nk)
        ok(e ~= nil and e._tip == i18n.desc(nk), "its box's tooltip = the full description: " .. nk)
    end
end
ok(nnum >= 8, "number rows: toughness, the zombie cap, player scaling (" .. nnum .. ")")
-- a typed number is kept with the footer's Save (a scratch config file)
local save_rec
for _, b in ipairs(UI.buttons) do if b.label == "btn_save" then save_rec = b end end
ok(save_rec ~= nil, "the footer's Save button")
local cfg_path0 = cfg.path
cfg.path = "../_tmp/ui_i18n_config.ini"
local tough_box, max_box = UI.inputs.ai_toughness_health_pct, UI.inputs.ai_host_cap_max
local dmg_box, per_box = UI.inputs.ai_toughness_damage_pct, UI.inputs.ai_host_cap_per_player
cfg.set("ai_host_cap_max", 320)          -- the host's own value before: kept when the box holds no number
if tough_box then tough_box._text = "40" end
if max_box then max_box._text = "abc" end
if dmg_box then dmg_box._text = "30 %" end
if per_box then per_box._text = "1,5" end
local n_lines = #log_lines
if save_rec then save_rec.fn() end
ok(cfg.get("ai_toughness_health_pct") == 40, "typed 40 + Save: ai_toughness_health_pct = 40")
ok(cfg.get("ai_host_cap_max") == 320, "not a number + Save: the value it had (320), not the default")
ok(max_box ~= nil and tostring(max_box._text) == "320", "its box shows the value kept: " .. tostring(max_box and max_box._text))
ok(cfg.get("ai_toughness_damage_pct") == 30 and dmg_box ~= nil and tostring(dmg_box._text) == "30",
    "'30 %' + Save: 30, its box shows 30")
ok(cfg.get("ai_host_cap_per_player") == 1 and per_box ~= nil and tostring(per_box._text) == "1",
    "'1,5' + Save: 1, its box shows 1")
local num_note
for i = n_lines + 1, #log_lines do
    if log_lines[i]:find("[TOAST] Not a number: ", 1, true) then num_note = log_lines[i] end
end
ok(num_note ~= nil and num_note:find(log.ascii(i18n.label("ai_host_cap_max")), 1, true) ~= nil
    and not num_note:find(log.ascii(i18n.label("ai_toughness_damage_pct")), 1, true),
    "a notice names the box with no number (only it): " .. tostring(num_note))
ok(cfg.set("ai_host_cap_max", "") == false and cfg.get("ai_host_cap_max") == 320, "an empty box: kept as well")
ok(cfg.set("ai_host_cap_max", "250 zombies") == true and cfg.get("ai_host_cap_max") == 250, "'250 zombies': 250")
ok(cfg.set("ai_host_cap_max", "1e3") == true and cfg.get("ai_host_cap_max") == 1000, "a number as Lua reads it: as before")
cfg.path = cfg_path0
cfg.set("ai_toughness_health_pct", 25)
cfg.set("ai_toughness_damage_pct", 15)
cfg.set("ai_host_cap_per_player", 25)
cfg.set("ai_host_cap_max", 300)
if tough_box then tough_box._text = "25" end
if max_box then max_box._text = "300" end
if dmg_box then dmg_box._text = "15" end
if per_box then per_box._text = "25" end
-- tooltips carry the full description
local cb = UI.checks.no_pause[1]
ok(cb._tip == i18n.desc("no_pause"), "tooltip = full description")
ok(#UI.checks.no_pause == 2, "a curated setting has its second copy in its group")
-- collapse hides the body; buttons in closed sections are not polled
local grp = nil
for _, sec in ipairs(UI.sections) do if sec.name == "group world" then grp = sec end end
UI.toggle_section(grp, false)
ok(grp.body._vis == 1, "collapse hides the body")
UI.frame_tick()     -- not open: nothing
UI.open = false
UI.set_open(true)
ok(UI.open, "opens")
UI.frame_tick()
local polled_in_closed = 0
for _, b in ipairs(UI.active) do if b.sec == grp then polled_in_closed = polled_in_closed + 1 end end
ok(polled_in_closed == 0, "no polling inside a collapsed section")

-- duplicate checkboxes follow each other
UI.checks.no_pause[1]._checked = not UI.checks.no_pause[2]._checked
UI.slow_tick()
ok(UI.checks.no_pause[1]._checked == UI.checks.no_pause[2]._checked, "duplicate checkboxes stay in sync")

-- English relabel in place
i18n.set("en")
ok(texts_with("^Co%-op$") == 1, "title relabelled to English")
ok(texts_with("^Open my world to friends$") == 1, "host button relabelled")
ok(cb._tip == i18n.DESC_EN.no_pause, "tooltip relabelled")
ok(texts_with("^Кооператив$") == 0, "no Russian title left")
local cyr = {}
for _, w in ipairs(created) do
    if w._class == "TextBlock" and type(w._text) == "string" and w._text:find("[\208\209]")
        and w._text ~= "Русский" then cyr[#cyr + 1] = w._text end
end
ok(#cyr == 0, "no Russian text left in English: " .. table.concat(cyr, " | "))

-- status line for each session state
UI.refresh_status()
ok(UI.status_title._text == "Your world is opening to friends…" or UI.status_title._text:find("world") ~= nil,
    "status (standalone, menu): " .. tostring(UI.status_title._text))
session.state.role = "host"
session.state.remote_pcs = { {} }
session.state.remote = { a = { name = "Bob", pc = {} } }
ue.in_main_menu = function() return false end
UI.refresh_status()
ok(UI.status_title._text == "Your world is open to friends.", "status host: " .. tostring(UI.status_title._text))
ok(UI.status_body._vis == 1, "host with players: no names in the status header")
ok(UI.players_title._text == "Players (2)" and UI.player_rows[1].name._text == "Me (you)"
    and UI.player_rows[2].name._text == "Bob" and UI.player_rows[2].ping._text == "42 ms"
    and UI.player_rows[2].state._text == "in game", "host: players section lists the host and Bob")
ok(UI.disconnect_row._vis == 1 and UI.host_row._vis == 1, "host in game: neither Disconnect nor Open the world")
-- the players table (top right): hidden while the panel is open (the panel lists them)
UI.update_players_hud()
ok(UI.players_hud._vis == 1 and UI.players_hud_model().why == "panel", "players table hidden while the panel is open")
UI.set_open(false)
ok(UI.players_hud._vis == 3, "players table shown when the panel closes (hit-test invisible)")
local hm = UI.players_hud_model()
ok(hm.visible and hm.title == "Players: 2" and hm.hint == "F8 to hide", "host table title / hint")
ok(hm.rows[1].name == "Me (you)" and hm.rows[1].ping == "" and hm.rows[2].name == "Bob" and hm.rows[2].ping == "42 ms",
    "host table: the host without a ping, then Bob with his ping")
ok(UI.hud_heads.name._text == "Player" and UI.hud_heads.ping._text == "Ping" and UI.hud_rows[2].name._text == "Bob"
    and UI.hud_rows[2].ping._text == "42 ms" and UI.hud_rows[3].row._vis == 1, "host table widgets: heads, Bob, no third row")
session.state.role = "client"
session.state.client = { host_name = "Alice", ping = 55, host_version = "0.6.99" }
session.state.client.roster = {
    { name = "Alice", state = "host", host = true },
    { name = "Me", state = "game", me = true, ping = 70 },
    { name = "Bob", state = "dead", ping = 90 },
}
UI.update_players_hud()
hm = UI.players_hud_model()
ok(hm.visible and hm.title == "Players: 3", "client table: three players")
ok(hm.rows[1].name == "Alice" and hm.rows[1].ping == "55 ms",
    "client table: its own ping to the host (its own measure) on the host's row")
ok(hm.rows[2].name == "Me (you)" and hm.rows[2].ping == "" and hm.rows[3].name == "Bob" and hm.rows[3].ping == "",
    "client table: no ping on its own row or another client's")
ok(UI.hud_rows[1].ping._text == "55 ms" and UI.hud_rows[3].name._text == "Bob" and UI.hud_rows[3].row._vis ~= 1,
    "client table widgets")
session.state.client.ping = nil
hm = UI.players_hud_model()
ok(hm.rows[1].ping == "70 ms", "client table: no own measure yet: the host's measure of this client")
session.state.client.ping = 55
-- the key hides / shows it and keeps the setting
UI.on_players_key()
ok(cfg.get("players_hud") == false and UI.players_hud._vis == 1 and UI.players_hud_model().why == "off",
    "key: table hidden, setting off")
UI.on_players_key()
ok(cfg.get("players_hud") == true and UI.players_hud._vis == 3, "key again: table shown")
-- nobody else: no table
local saved_roster = session.state.client.roster
session.state.role = "standalone"
UI.update_players_hud()
ok(UI.players_hud._vis == 1, "single player: no table")
session.state.role = "client"
session.state.client.roster = saved_roster
UI.set_open(true)
UI.refresh_status()
ok(UI.status_title._text == "You are in Alice's world.", "status client: " .. tostring(UI.status_title._text))
i18n.set("ru")
ok(UI.status_title._text == "Вы в мире хоста Alice.", "status relabelled to Russian: " .. tostring(UI.status_title._text))
UI.set_open(false)
UI.update_players_hud()
ok(UI.hud_title._text == "Игроки: 3" and UI.hud_heads.ping._text == "Пинг" and UI.hud_rows[2].name._text == "Me (вы)",
    "players table relabelled to Russian: " .. tostring(UI.hud_title._text))
-- no "respawn near the host" row any more (the game's own respawn buttons)
ok(UI.set_dead == nil and UI.respawn_row == nil and session.ui_hooks.dead == nil, "no respawn row, no death hook")
UI.set_open(false)
UI.pick_tab("char")
-- a world change drops every reference
UI.forget_world("loadmap")
ok(UI.widget == nil and #UI.buttons == 0 and next(UI.checks) == nil, "forget_world drops references")
local okb2 = pcall(UI.build)
ok(okb2 and UI.tab == "char", "rebuild keeps the last tab")

-- ---------------------------------------------------------------------------
-- 5. notification routing, the menu label, bug reports
-- ---------------------------------------------------------------------------
-- every catalog key the modules say (and the host sends as MSG) has a class
local say_keys = {}
for _, name in ipairs(files) do
    if name ~= "sdc_i18n.lua" and name ~= "sdc_log.lua" then
        local h = io.open(dir .. "/" .. name, "r")
        if h then
            local text = h:read("a"); h:close()
            for key in text:gmatch('log%.say%(%s*"([%w_]+)"') do say_keys[key] = name end
            for a, b in text:gmatch('log%.say%([^\n]-and%s+"([%w_]+)"%s+or%s+"([%w_]+)"') do
                say_keys[a] = name; say_keys[b] = name
            end
            for key in text:gmatch('"MSG",%s*"([%w_]+)"') do say_keys[key] = name end
        end
    end
end
local n_keys = 0
for key, name in pairs(say_keys) do
    n_keys = n_keys + 1
    if not (i18n.SAY_CLASS[key] == "game" or i18n.SAY_CLASS[key] == "mod") then
        io.stderr:write(string.format("note: log.say key %s (%s) has no class: %s by default%s", key, name,
            "game unless its kind is err", string.char(10)))
    end
end
ok(n_keys >= 50, "log.say keys found in the modules (" .. n_keys .. ")")
local counts = { game = 0, mod = 0 }
for _, c in pairs(i18n.SAY_CLASS) do counts[c] = counts[c] + 1 end
local tcounts = { game = 0, mod = 0 }
for _, c in pairs(i18n.TOAST_CLASS) do tcounts[c] = tcounts[c] + 1 end
for _, pt in ipairs(i18n.TOAST_PATTERNS) do tcounts[pt[3]] = tcounts[pt[3]] + 1 end
io.stderr:write(string.format("classes: log.say keys game=%d mod=%d; toast texts/patterns game=%d mod=%d%s",
    counts.game, counts.mod, tcounts.game, tcounts.mod, string.char(10)))

-- routing (rule of 2026-11-13): everything goes the game's way (toast_sink: its
-- widget in a world; sdc_lobby falls back to the mod's toast with no HUD or the
-- panel open); only the mod's own failures (kind err) -> the panel-style toast
local game_got = {}
log.toast_sink = function(text, kind, seconds, class) game_got[#game_got + 1] = { text = text, class = class } end
local function game_got_n() return game_got end
local function last_route_text()
    local g = game_got[#game_got]
    local m = UI.toasts[#UI.toasts]
    return (m and m.text) or (g and g.text)
end
UI.toasts = {}
cfg.set("language", "ru")
log.say("player_joined", "ok", 6, "Bob")
ok(#game_got == 1 and game_got[1].text == "Bob подключился." and #UI.toasts == 0, "player joined -> the game's widget")
log.toast("Задание отмечено на карте", "info", 6, "quest pinned")
ok(#game_got == 2 and #UI.toasts == 0, "a quest notice -> the game's widget")
log.say("listen_failed", "err", 10)
ok(#game_got == 2 and #UI.toasts == 1 and UI.toasts[1].class == "mod" and UI.toasts[1].kind == "err",
    "listen failed -> the mod's toast")
log.toast("Мод обновил сетевые настройки игры. Перезапустите игру один раз, чтобы открыть мир для друзей или подключиться.",
    "warn", 12, "steam restart")
ok(#game_got == 3 and #UI.toasts == 1, "a mod warning (not a failure) -> the game's way")
ok(i18n.topic("Мод обновил сетевые настройки игры. Перезапустите игру один раз, чтобы открыть мир для друзей или подключиться.")
    == "mod", "its topic is still the mod's")
log.toast("Some new mod failure", "err", 6)
ok(#UI.toasts == 2 and UI.toasts[2].class == "mod", "an unlisted error -> the mod's toast")
log.toast("Some new gameplay line", "info", 6)
ok(#game_got == 4, "an unlisted info -> the game's widget")
UI.slow_tick()
ok(UI.toast_box._vis == 3 and UI.toast_hint._vis == 3, "mod error toast shown with the report hint")
ok(type(UI.toast_hint._text) == "string" and UI.toast_hint._text:find("Сообщить об ошибке", 1, true) ~= nil,
    "hint names the panel's report section: " .. tostring(UI.toast_hint._text))
UI.toasts = {}
-- with the join cover on (the default) a lost connection shows on it (mock_join_cover); off: the mod's toast
log.say("connection_lost", "warn", 8)
ok(#UI.toasts == 0 and UI._jc.s and UI._jc.s.finished == "failed", "a lost connection with the join cover on: on the cover, no toast")
UI._jc.dismiss("test")
require("sdc_config").set("join_cover", false)
log.say("connection_lost", "warn", 8)
require("sdc_config").set("join_cover", true)
UI.toasts_dirty = true
UI.slow_tick()
ok(#UI.toasts == 0 and #game_got == 5 and game_got[5].text == "Соединение с хостом потеряно.",
    "a lost connection (cover off): the game's way, no mod toast")
UI.disabled = true
log.say("listen_failed", "err", 10)
ok(#game_got == 6, "menu disabled: even the mod's failures go the game's way")
UI.disabled = false
-- the game's fallback (no HUD) shows gameplay toasts without the hint
UI.toasts = {}
UI.toast("Bob подключился.", "ok", 6)
UI.toasts_dirty = true
UI.slow_tick()
ok(UI.toast_hint._vis == 1, "gameplay fallback toast: no report hint")

-- the game menu's button follows the GAME's language with auto
cfg.set("language", "auto")
ok(i18n.language() == "ru" and i18n.coop_label() == "Co-op", "auto: panel Russian, menu button like the game (Co-op)")
cfg.set("language", "ru")
ok(i18n.coop_label() == "Кооператив", "explicit ru wins for the menu button")
cfg.set("language", "auto")
ok(i18n.desc("language"):find("Кооператив", 1, true) ~= nil, "the language setting explains the menu button")

-- bug reports
session.state.role = "host"
local url = UI.issue_url()
ok(url == "https://github.com/Chepchek/SurrounDead-Coop/issues/new?template=bug_report.yml&version=0.6.99"
    .. "&role=%D0%A3%20%D1%85%D0%BE%D1%81%D1%82%D0%B0", "issue url (host): " .. url)
session.state.role = "client"
ok(UI.issue_url():find("&role=%D0%A3%20%D0%BA%D0%BB%D0%B8%D0%B5%D0%BD%D1%82%D0%B0", 1, true) ~= nil, "issue url (client)")
session.state.role = "standalone"
ok(not UI.issue_url():find("role=", 1, true), "no role outside a session")
UI.mod_dir, UI.log_dir_cache = "ue4ss/Mods/SDCoop", nil
ok(UI.log_dir() == [[C:\Games\SurrounDead\Binaries\Win64\ue4ss]], "log folder: " .. UI.log_dir())
UI.open_bug()
ok(UI.tab == "settings" and UI.bug_section and UI.bug_section.open and UI.bug_section.built, "the report section opens")
ok(UI.bug_path_box and UI.bug_path_box._text == UI.log_dir(), "the log path as selectable text")
local link = nil
for _, b in ipairs(UI.buttons) do if b.label == "bug link" then link = b end end
ok(link ~= nil and link.tab == nil, "footer link on every tab")
UI.toasts = {}
UI.on_bug_form()
ok(launched[#launched] == UI.issue_url(), "the form button launches the issue url")
ok(#UI.toasts + #game_got_n() >= 1, "a toast says where it opened (the game's way: the panel's toast while it is open)")
UI.on_bug_logs()
ok(launched[#launched] == "file:///C:/Games/SurrounDead/Binaries/Win64/ue4ss", "the folder button launches a file:// url: "
    .. tostring(launched[#launched]))
local saved_dir = UI.log_dir_cache
UI.log_dir_cache = [[C:\Program Files (x86)\Steam\SurrounDead\ue4ss]]
ok(UI.log_dir_url() == "file:///C:/Program%20Files%20(x86)/Steam/SurrounDead/ue4ss", "file url escapes spaces: " .. UI.log_dir_url())
UI.log_dir_cache = saved_dir
i18n.set("en")
ok(texts_with("^Report a bug$") >= 2, "report section and link relabelled to English")
i18n.set("ru")

-- quest notifications that go straight to the game's HUD get the player's language
local qh = io.open(dir .. "/sdc_quests.lua", "r")
local qsrc = qh and qh:read("a") or ""
if qh then qh:close() end
local nbody = qsrc:match("local function notify%(text, english%)(.-)\nend")
ok(nbody ~= nil and nbody:find("log.screen_text", 1, true) ~= nil and nbody:find("FText(shown)", 1, true) ~= nil,
    "sdc_quests notify translates the HUD text")

-- ---------------------------------------------------------------------------
-- 6. players section (every role) and the Steam block (every state)
-- ---------------------------------------------------------------------------
i18n.set("en")
UI.pick_tab("ip")
local function vis(w) return w ~= nil and w._vis ~= 1 end
local function shown_rows()
    local n = 0
    for _, r in ipairs(UI.player_rows) do if vis(r.row) then n = n + 1 end end
    return n
end
-- main menu, nothing open: no player list (the status line says it), Open the world
session.state.role, session.state.remote, session.state.remote_pcs = "standalone", {}, {}
cfg.set("listen_on_load", false)   -- else the menu is "opening" (no Open button)
ue.in_main_menu = function() return true end
UI.refresh_status()
ok(not vis(UI.players_box) and UI.status_title._text == "Your world is closed to friends.",
    "players: menu, world closed -> no list, the status says it")
ok(vis(UI.host_row) and not vis(UI.disconnect_row), "header: Open the world in the main menu")
-- single player: no list; no Open the world until there is a character
ue.in_main_menu = function() return false end
UI.refresh_status()
ok(not vis(UI.players_box) and not vis(UI.host_row), "players: single player, no character yet")
-- with a character: Open the world (the game saves and loads it again open)
local real_lp = ue.local_pawn
ue.local_pawn = function() return {} end
UI.refresh_status()
ok(vis(UI.host_row) and vis(UI.host_caption_world) and not vis(UI.host_caption_menu),
    "single player world: Open the world with the reload caption")
ok(UI.host_caption_world._text:find("loads this world again", 1, true) ~= nil, "reload caption: " .. tostring(UI.host_caption_world._text))
ue.local_pawn = real_lp
UI.refresh_status()
-- a connection pending: Disconnect in the header
ue.has_pending_connection = function() return true end
UI.refresh_status()
ok(not vis(UI.players_box) and vis(UI.disconnect_row) and not vis(UI.host_row), "players: connecting")
ue.has_pending_connection = function() return false end
-- host alone: the status line says nobody joined
session.state.role = "host"
UI.refresh_status()
ok(not vis(UI.players_box), "players: host alone -> no list")
ok(UI.status_body._text == "Nobody has joined yet. Friends join by your IP, port 7777 (UDP).",
    "host alone: what to do next in the header")
ok(not vis(UI.host_row) and not vis(UI.disconnect_row), "host: no header action")
-- host with clients in every state
local saved_roster = session.roster
session.roster = function()
    return { { name = "Me", state = "host", host = true, me = true },
             { name = "Bob", state = "game", ping = 42 }, { name = "Vasya", state = "loading", ping = 130 },
             { name = "Gleb", state = "connecting" }, { name = "Dana", state = "dead", ping = 70 } }
end
UI.refresh_status()
ok(vis(UI.players_box) and UI.players_title._text == "Players (5)" and shown_rows() == 5
    and UI.player_rows[1].name._text == "Me (you)" and UI.player_rows[1].state._text == "host", "players: host + 4")
ok(UI.player_rows[3].state._text == "loading" and UI.player_rows[4].state._text == "connecting"
    and UI.player_rows[4].ping._text == "" and UI.player_rows[5].state._text == "dead"
    and UI.player_rows[5].ping._text == "70 ms", "players: states and pings")
UI.pick_tab("settings")
UI.refresh_status()
ok(vis(UI.players_box), "players: seen on every tab (header)")
UI.pick_tab("ip")
-- more than the rows
session.roster = function()
    local out = { { name = "Me", state = "host", host = true, me = true } }
    for i = 1, 9 do out[#out + 1] = { name = "P" .. i, state = "game", ping = i } end
    return out
end
UI.refresh_status()
ok(shown_rows() == 8 and vis(UI.players_more) and UI.players_more._text == "…and 2 more", "players: overflow line")
-- a long name is cut
session.roster = function()
    return { { name = "Me", state = "host", host = true, me = true },
             { name = "An-Extremely-Long-Player-Name-From-Steam", state = "game", ping = 5 } }
end
UI.refresh_status()
ok(UI.player_rows[2].name._text == "An-Extremely-Long-Playe…",
    "players: long names cut past 24 characters: " .. UI.player_rows[2].name._text)
session.roster = saved_roster
-- client: the host's list, Disconnect in the header
session.state.role = "client"
session.state.client = { host_name = "Alice", ping = 55, host_version = "0.6.99", roster = {
    { name = "Alice", state = "host", host = true }, { name = "Me", state = "game", ping = 60, me = true },
    { name = "Gleb", state = "loading", ping = 90 } } }
UI.refresh_status()
ok(vis(UI.players_box) and UI.players_title._text == "Players (3)" and UI.player_rows[1].name._text == "Alice"
    and UI.player_rows[1].state._text == "host" and UI.player_rows[2].name._text == "Me (you)"
    and UI.player_rows[2].ping._text == "60 ms" and UI.player_rows[3].state._text == "loading", "players: client view")
ok(vis(UI.disconnect_row) and not vis(UI.host_row), "client: Disconnect in the header")
session.state.client.roster = nil
UI.refresh_status()
ok(not vis(UI.players_box), "players: client without any list")
i18n.set("ru")
session.state.client.roster = { { name = "Alice", state = "host", host = true }, { name = "Me", state = "game", me = true } }
UI.refresh_status()
ok(UI.players_title._text == "Игроки (2)" and UI.player_rows[2].name._text == "Me (вы)"
    and UI.player_rows[2].state._text == "в игре", "players: Russian")
i18n.set("en")
session.state.role, session.state.client = "standalone", nil
ue.in_main_menu = function() return true end

-- Steam block without the module (a broken install): an error line
package.loaded["sdc_steamlink"] = nil
UI.steam_missing_at = nil
UI.refresh_status()
ok(vis(UI.steam_status_row) and UI.steam_status._text == "Steam link error." and not vis(UI.steam_invite)
    and vis(UI.steam_to_ip) and not vis(UI.steam_help),
    "steam: no module -> an error line and the way to the IP tab: " .. tostring(UI.steam_status_row and UI.steam_status_row._vis)
    .. "/" .. tostring(UI.steam_status and UI.steam_status._text) .. "/" .. tostring(UI.steam_invite and UI.steam_invite._vis)
    .. "/" .. tostring(UI.steam_to_ip and UI.steam_to_ip._vis) .. "/" .. tostring(UI.steam_help and UI.steam_help._vis))
UI.user_tab = nil
ok(UI.default_tab() == "ip", "default tab without the Steam link: IP")
-- a stand-in module in every state
local sl_calls = {}
local sl_friends = {
    { id = "1", name = "Alice", joinable = true, status = "hosting, 0.7.0" },
    { id = "2", name = "Boris", joinable = false, status = "in the game" },
    { id = "3", name = "Cleo", joinable = true, status = "hosting" },
}
local sl_state, sl_detail, sl_restart, sl_key = "ready", nil, false, nil
local sl_join_result = { true }
package.loaded["sdc_steamlink"] = {
    status = function()
        return { state = sl_state, detail = sl_detail, detail_key = sl_key, friends_only = true, helper = true,
                 restart_needed = sl_restart, peers = 0 }
    end,
    friends = function() return sl_friends end,
    join = function(id) sl_calls[#sl_calls + 1] = "join " .. id return table.unpack(sl_join_result) end,
    invite = function() sl_calls[#sl_calls + 1] = "invite" return false, "The Steam overlay did not open.", "sl_overlay" end,
    tr = function(key) return key == "sl_st_restart" and "Restart the game once: the mod changed its network settings." or key end,
}
local expect = {
    off = "Joining through Steam is off (setting steam_link).", no_steam = "Steam is not running.",
    starting = "Starting the Steam link…", ready = "Steam is ready: join a friend or invite one.",
    hosting = "Open to your Steam friends. Connected: 1", joining = "Joining through Steam…",
    connected = "Connected through Steam.", error = "The Steam helper stopped.",
}
for _, st in ipairs({ "off", "no_steam", "starting", "ready", "hosting", "joining", "connected", "error" }) do
    sl_state = st
    sl_detail = expect[st]   -- the module's own sentence (sdc_steamlink.status gives one for every state)
    UI.refresh_status()
    local usable = st == "ready" or st == "hosting" or st == "connected"
    ok(vis(UI.steam_status_row) and UI.steam_status._text == expect[st] and not vis(UI.steam_later),
        "steam " .. st .. ": " .. tostring(UI.steam_status._text))
    ok(vis(UI.steam_invite) == usable, "steam " .. st .. ": invite button " .. tostring(usable))
    ok(vis(UI.friend_rows[1].row) == usable, "steam " .. st .. ": friends list " .. tostring(usable))
    ok(vis(UI.steam_note) == (st == "hosting"), "steam " .. st .. ": friends-only note")
    ok(not vis(UI.steam_detail), "steam " .. st .. ": no second line without a restart")
end
-- the restart the mod asks for: in error (its own sentence) and as a line under another state
sl_state, sl_detail, sl_key = "error", "Restart the game once: the mod changed its network settings.", "sl_st_restart"
UI.refresh_status()
ok(UI.steam_status._text == "Restart the game once: the mod changed its network settings."
    and not vis(UI.steam_invite) and vis(UI.steam_to_ip), "steam: restart needed (error state)")
sl_state, sl_detail, sl_key, sl_restart = "ready", expect.ready, nil, true
UI.refresh_status()
ok(vis(UI.steam_detail) and UI.steam_detail._text:find("Restart the game once", 1, true) ~= nil,
    "steam: restart needed under another state")
sl_restart = false
sl_state = "ready"
UI.refresh_status()
ok(UI.friend_rows[1].name._text == "Alice" and UI.friend_rows[2].name._text == "Cleo"
    and UI.friend_rows[3].name._text == "Boris", "steam: joinable friends first")
ok(vis(UI.friend_rows[1].join) and vis(UI.friend_rows[2].join) and not vis(UI.friend_rows[3].join),
    "steam: Join only on joinable friends")
ok(UI.friend_rows[1].status._text == "hosting, 0.7.0" and UI.friend_rows[3].status._text == "in the game",
    "steam: the module's status text")
ok(vis(UI.steam_help) and not vis(UI.steam_to_ip), "Steam ready: how it works, no pointer to IP")
sl_friends = {
    { id = "1", name = "Alice", joinable = true, version = session.VERSION, status = "hosting" },
    { id = "4", name = "Dmitry", joinable = true, version = "0.6.1", status = "other mod version: 0.6.1" },
}
UI.refresh_status()
ok(vis(UI.friend_rows[1].join) and not vis(UI.friend_rows[2].join)
    and UI.friend_rows[2].status._text == "other mod version: 0.6.1", "steam: no Join for another mod version")
ok(UI.can_join_friend({ joinable = true }) and not UI.can_join_friend({ joinable = false })
    and not UI.can_join_friend({ joinable = true, version = "0.1" }), "can_join_friend")
sl_friends = {
    { id = "1", name = "Alice", joinable = true, status = "hosting, 0.7.0" },
    { id = "2", name = "Boris", joinable = false, status = "in the game" },
    { id = "3", name = "Cleo", joinable = true, status = "hosting" },
}
UI.refresh_status()
UI.user_tab = nil
ok(UI.default_tab() == "steam", "default tab with the Steam link ready: Steam")
UI.set_open(false)
UI.set_open(true)
ok(UI.tab == "steam", "opening the panel shows the Steam tab")
UI.pick_tab("ip")
UI.set_open(false)
UI.set_open(true)
ok(UI.tab == "ip" and UI.default_tab() == "ip", "the picked tab is remembered")
local to_ip = nil
for _, b in ipairs(UI.buttons) do if b.label == "btn_go_ip" then to_ip = b end end
UI.pick_tab("steam")
to_ip.fn()
ok(UI.tab == "ip" and UI.user_tab == "ip", "the Steam tab's «Join by IP» opens the IP tab")
UI.user_tab = nil
local join_btn, invite_btn = nil, nil
for _, b in ipairs(UI.buttons) do
    if b.label == "btn_steam_join" and not join_btn then join_btn = b end
    if b.label == "btn_steam_invite" then invite_btn = b end
end
UI.toasts = {}
join_btn.fn()
ok(sl_calls[#sl_calls] == "join 1" and #UI.toasts == 0, "steam: Join calls join(id) of that row (started: no toast)")
sl_join_result = { false, "You are connected to another server.", "already_client" }
join_btn.fn()
ok(last_route_text() == "You are connected to another server.", "steam: a refused join shows the module's reason")
sl_join_result = { true }
UI.toasts = {}
invite_btn.fn()
ok(sl_calls[#sl_calls] == "invite" and last_route_text() == "The Steam overlay did not open.",
    "steam: Invite calls invite(); its failure is told")
sl_friends = {}
UI.refresh_status()
ok(vis(UI.steam_none) and not vis(UI.friend_rows[1].row), "steam: no friends playing")
session.state.role, session.state.remote_pcs = "host", {}
ue.in_main_menu = function() return false end
UI.refresh_status()
ok(UI.status_body._text == "Nobody has joined yet. Friends join through Steam or by your IP (port 7777, UDP).",
    "host hint mentions Steam")
package.loaded["sdc_steamlink"] = function() end   -- a broken module value
UI.refresh_status()
ok(UI.steam_status._text == "Steam link error." and vis(UI.steam_to_ip), "steam: a broken module counts as missing")
package.loaded["sdc_steamlink"] = nil
session.state.role = "standalone"

local slh = io.open(dir .. "/sdc_steamlink.lua", "r")
if slh then
    local slsrc = slh:read("a")
    slh:close()
    local n_sl = 0
    for key in slsrc:gmatch('notify%(%s*"(sl_[%w_]+)"') do
        n_sl = n_sl + 1
        ok(i18n.SAY_CLASS[key] == "game" or i18n.SAY_CLASS[key] == "mod", "class for the Steam link notice " .. key)
    end
    ok(n_sl >= 8, "Steam link notices found (" .. n_sl .. ")")
end
ok(i18n.SAY_CLASS.sl_join_failed == "mod" and i18n.SAY_CLASS.sl_no_helper == "mod" and i18n.SAY_CLASS.sl_joining == "game"
    and i18n.SAY_CLASS.sl_hosting == "game", "Steam link: failures are mod, progress is game")
log.TEXT.sl_st_hosting = log.TEXT.sl_st_hosting or { "Open to Steam friends · connected: %d", "Открыт для друзей в Steam · подключено: %d" }
cfg.set("language", "ru")
ok(log.tr("sl_st_hosting", 2) == "Мир открыт для друзей в Steam. Подключено: 2", "Steam link texts without '·' (RU)")
cfg.set("language", "en")
ok(log.tr("sl_st_hosting", 2) == "Open to your Steam friends. Connected: 2", "Steam link texts without '·' (EN)")
cfg.set("language", "auto")
for _, k in ipairs({ "steam_link", "steam_link_friends_only", "steam_link_allow", "game_ui_input", "notes_relay",
                     "notes_owner_only" }) do
    if i18n.schema_row(k) then ok(i18n.group_of(k) == (k:find("^steam") and "connect" or "players"), "group of " .. k) end
end

ok(#errors == 0, "no log errors: " .. table.concat(errors, " | "))
print = real_print
print(string.format("ui_i18n: %d checks, %d failed%s", pass + fail, fail, fail == 0 and ", ALL OK" or ""))
os.exit(fail == 0 and 0 or 1)
