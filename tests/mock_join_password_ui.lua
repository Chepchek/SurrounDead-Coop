-- Mock harness: the join password in the co-op panel and on the join cover
-- (sdc_ui + the real sdc_admin / sdc_i18n / sdc_config / sdc_log; stub UMG
-- widgets, engine and session).
--   1. the World tab: four exclusive modes, two buttons a row (Все / По
--      паролю, По одобрению / Только приглашённые); the password box only
--      with «По паролю» (its own Save through the frame loop, the state
--      line, refilled when the panel opens); a wrong password in the
--      recently turned away (Add to list); English
--   2. the IP tab: the masked password field, kept per address (a field
--      left as shown is not carried to another address; an edit is kept,
--      an empty one forgets; a Steam code in the address field)
--   3. the join cover: KICK|6|0 / 6|1 - the reason, a masked field and
--      Join in place of Try again (polled by the cover); Join keeps the
--      password for the failed join's target (IP / Steam) and joins it
--      again; the IP tab's field follows; each new refusal empties the
--      field; KICK|6|2 - no field, no retry; KICK|6|3 (no password set by
--      the host) - says so, no field, no retry; no join recorded (a console
--      "open", or sdc_session forgot an old join at this connection's
--      start): an empty answer, no field / Join, the hint says to join from
--      the IP / Steam tab, Join keeps nothing for a guessed host and joins
--      nothing; join_cover off: the password prompt still comes up (the
--      field for a join from the panel), other refusals stay toasts; the next
--      join (the IP tab's Join) or a new connection takes the prompt down
--      (cover on or off); English
--   (2.) the footer's Save keeps the IP tab's password for the typed address
-- usage: lua mock_join_password_ui.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
table.insert(package.searchers, 1, function(name)
    if name == "sdc_steamlink" then return function() error("sdc_steamlink: not loaded in this test") end end
end)

local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local LOGS = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOGS[#LOGS + 1] = table.concat(parts, "\t")
end
local function logged(pat)
    for i = 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return LOGS[i] end end
    return nil
end

local CLK, NOW = 100.0, 5000000
os.clock = function() return CLK end
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end
local function advance(s) CLK = CLK + s; NOW = NOW + math.floor(s) end

-- ------------------------------------------------------------ UMG stubs
FName = function(s) return { name = s, ToString = function() return s end } end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
RegisterConsoleCommandHandler = function() end
local function autostruct()
    return setmetatable({}, { __index = function(t, k) local s = autostruct(); rawset(t, k, s); return s end })
end
local created = {}
local widget_mt
local function make_widget(class)
    local w = setmetatable({ _class = class, _children = {}, _text = "", _checked = false }, widget_mt)
    created[#created + 1] = w
    return w
end
local STRUCT_PROPS = { Font = true, WidgetStyle = true, Background = true }
widget_mt = {
    __index = function(t, k)
        if STRUCT_PROPS[k] then local s = autostruct(); rawset(t, k, s); return s end
        if k == "IsValid" then return function() return true end end
        if k == "SetText" then return function(self, s) self._text = s end end
        if k == "GetText" then return function(self) return self._text end end
        if k == "SetIsPassword" then return function(self, v) self._masked = v end end
        if k == "SetVisibility" then return function(self, v) self._vis = v end end
        if k == "SetBrushColor" then return function(self, c) self._color = c end end
        if k == "SetColorAndOpacity" then return function(self, c) self._fg = c end end
        if k == "SetToolTipText" then return function(self, s) self._tip = s end end
        if k == "SetIsChecked" then return function(self, v) self._checked = v end end
        if k == "IsChecked" then return function(self) return self._checked end end
        if k == "IsHovered" or k == "IsPressed" then return function() return false end end
        if k == "IsInViewport" then return function() return true end end
        if k:find("^AddChild") or k == "SetContent" then
            return function(self, c) self._children[#self._children + 1] = c; return make_widget("Slot") end
        end
        return function() return nil end
    end,
}
local classes = {}
StaticConstructObject = function(cls) return make_widget(cls and cls.name or "?") end
StaticFindObject = function() return nil end
FindFirstOf = function() return nil end

-- ------------------------------------------------------------ engine stub
local W = { pc = nil, pawn = nil, pending = false, menu = false }
local function mkpc(name, role) return { _name = name, _role = role, key = name, IsValid = function() return true end,
                                         IsInputKeyDown = function() return false end } end
local noop = function() return nil end
local culture_lib = { GetCurrentCulture = function() return "en" end, IsValid = function() return true end }
local ksl = { GetDefaultLanguage = function() return "ru-RU" end, IsValid = function() return true end }
local ue = setmetatable({
    ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3,
    valid = function(o) return type(o) == "table" and not rawget(o, "destroyed") end,
    try = function(fn, ...) local okk, v = pcall(fn, ...); if okk then return v end end,
    str = function(v) if v == nil then return "" end return type(v) == "table" and (v.name or "") or tostring(v) end,
    name = function(o) return o and (o._name or "Obj") or "<none>" end,
    short = function(o) return o and (o._name or "Obj") or "<none>" end,
    path = function() return "/Game/Fonts/Test.Test" end,
    class_name = function(o) return o and o._class or "" end,
    prop = function(o, k) return o and rawget(o, k) end,
    set_prop = function(o, k, v) if o then rawset(o, k, v) end return true end,
    role = function(a) return a and a._role end,
    find_object = function(p)
        local short = p:match("^/Script/UMG%.(.+)$")
        if short then classes[short] = classes[short] or { name = short, IsValid = function() return true end }; return classes[short] end
        if p:find("KismetInternationalizationLibrary", 1, true) then return culture_lib end
        return nil
    end,
    find_first = noop, find_all = function() return {} end,
    ksl = function() return ksl end,
    game_instance = function() return { IsValid = function() return true end } end,
    local_pc = function() return W.pc end,
    local_pawn = function() return W.pc and W.pawn or nil end,
    pawn_of = function(pc) if pc ~= nil and pc == W.pc then return W.pawn end return nil end,
    ping_ms = function() return 42 end,
    in_main_menu = function() return W.menu end,
    map_name = function() return "PersistentLevel" end,
    has_pending_connection = function() return W.pending end,
    pending_connection_live = function() return W.pending end,
    delay = noop, every = noop,
}, { __index = function() return noop end })
package.loaded["sdc_ue"] = ue

local stopped = nil
local joins = {}
local session = {
    VERSION = "0.7.3",
    state = { role = "standalone", remote = {}, remote_pcs = {}, join = { target = nil, started_at = 0, attempts = 0 } },
    world_reset_hooks = {}, ui_hooks = {},
    join = function(ip, port, auto) joins[#joins + 1] = { ip = ip, port = port, auto = auto } end,
    disconnect = noop, host_on_next_load = noop, start_fresh_server = noop, request_respawn = noop,
    roster = function() return {} end,
    stop_auto_join = function(why) stopped = why end,
}
package.loaded["sdc_session"] = session
package.loaded["sdc_widgets"] = { child = noop, first_text = noop, game_window_open = function() return false end }
package.loaded["sdc_steam"] = {
    code_of = function(a)
        local s = tostring(a or ""):gsub("^%s+", ""):gsub("%s+$", "")
        return (#s == 17 and s:match("^%d+$")) and s or nil
    end,
}
local sent, handlers = {}, {}
package.loaded["sdc_net"] = {
    on = function(k, f) handlers[k] = f end,
    send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, f = { ... } } return true end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end,
    broadcast = noop,
}
local function last_sent(kind, to)
    for i = #sent, 1, -1 do if sent[i].kind == kind and sent[i].to == to then return sent[i] end end
    return { f = {} }
end
package.loaded["sdc_persist"] = { steam_of = function() return nil end, client_join_state = function() return {} end }

local log = require("sdc_log")
local errors = {}
local real_err = log.err
log.err = function(msg, ...) errors[#errors + 1] = string.format(tostring(msg), ...); real_err(msg, ...) end
local game_got = {}
log.toast_sink = function(text) game_got[#game_got + 1] = text end
local cfg = require("sdc_config")
local saves = 0
cfg.save = function() saves = saves + 1 return true end
local i18n = require("sdc_i18n")
local admin = require("sdc_admin")
admin.install(session.state)
local UI = require("sdc_ui")
UI.VERSION = "0.7.3"
local JC = UI._jc
local function vis(w) return w ~= nil and w._vis ~= nil and w._vis ~= 1 end
local PW = "Сезам 1"

-- a button's record (its label; `gate_w`: one of its gates)
local function rec_of(label, gate_w)
    for _, b in ipairs(UI.buttons) do
        if b.label == label then
            if not gate_w then return b end
            for _, g in ipairs(b.gates) do if g == gate_w then return b end end
        end
    end
    return nil
end
local function polled(label)
    for _, b in ipairs(UI.active) do if b.label == label then return true end end
    return false
end
-- a click on `rec` through the frame loop (press, release over it)
local function click(rec)
    local down = true
    rawset(rec.w, "IsPressed", function() return down end)
    rawset(rec.w, "IsHovered", function() return true end)
    UI.frame_tick()
    down = false
    UI.frame_tick()
    rawset(rec.w, "IsPressed", nil)
    rawset(rec.w, "IsHovered", nil)
end

W.pc = mkpc("PC_menu", 3)
local okb, errb = pcall(UI.build)
check(okb, "UI.build runs: " .. tostring(errb))

-- ---------------------------------------------------------------- 1. the World tab
io.write("1. the World tab\n")
session.state.role = "host"
UI.set_open(true)
UI.pick_tab("world")
UI.refresh_world()
local MODES = { "open", "password", "approve", "list" }
local LABELS = { open = "Все", password = "По паролю", approve = "По одобрению", list = "Только приглашённые" }
local all4 = true
for _, v in ipairs(MODES) do
    local rec = UI.mode_buttons[v]
    if not (rec and rec.label == "wa_mode_" .. v) then all4 = false end
end
check(all4, "four mode buttons")
local labels_ok = true
for _, v in ipairs(MODES) do
    local found = false
    for _, w in ipairs(created) do if w._class == "TextBlock" and w._text == LABELS[v] then found = true end end
    if not found then labels_ok = false end
end
check(labels_ok, "labels: Все / По паролю / По одобрению / Только приглашённые")
-- the rows: each HorizontalBox holding mode buttons holds two, in order
local rows = {}
for _, w in ipairs(created) do
    if w._class == "HorizontalBox" then
        local got = {}
        for _, c in ipairs(w._children) do
            for _, v in ipairs(MODES) do if c == UI.mode_buttons[v].bg then got[#got + 1] = v end end
        end
        if #got > 0 then rows[#rows + 1] = table.concat(got, ",") end
    end
end
check(#rows == 2 and rows[1] == "open,password" and rows[2] == "approve,list", "two a row: " .. table.concat(rows, " / "))
local m = UI.world_model()
check(m.mode == "open" and not m.show_pw and not vis(UI.world_pw_box), "open: no password box")
UI.frame_tick()
check(not polled("wa_pw_save"), "its Save is not polled while hidden")
saves = 0
click(UI.mode_buttons.password)
m = UI.world_model()
check(cfg.get("join_access") == "password" and saves == 1, "«По паролю» (a click): saved at once")
check(UI.world_caption._text == "Игроки из списка входят сразу, остальные вводят пароль — и по IP, и через Steam. Верный пароль добавляет игрока в список."
    and UI.mode_buttons.password.colors == UI.lang_buttons.auto.colors and UI.mode_buttons.open.colors ~= UI.mode_buttons.password.colors,
    "its caption, its button the chosen one")
check(vis(UI.world_pw_box) and m.show_pw and not m.pw_set
    and UI.world_pw_state._text == "Пароль не задан: пока вы его не сохраните, новые игроки не войдут.",
    "the password box: no password yet (said)")
check(rawget(UI.world_pw, "_masked") == nil, "the host's field is not masked (to dictate it)")
UI.world_pw._text = "  " .. PW .. "  "
local n_game = #game_got
saves = 0
UI.frame_tick()
check(polled("wa_pw_save"), "Save polled while shown")
click(rec_of("wa_pw_save"))
check(cfg.get("join_password") == PW and saves == 1 and UI.world_pw._text == PW, "Save (a click): trimmed, saved, the field shows it")
check(#game_got == n_game + 1 and game_got[#game_got] == "Пароль для входа сохранён.", "a notice")
UI.refresh_world()
check(UI.world_pw_state._text == "Пароль задан.", "the state line: set")
UI.set_open(false)
UI.world_pw._text = "half typed"
UI.set_open(true)
check(UI.world_pw._text == PW, "the panel opened again: the saved password (an unsaved edit gone)")
UI.inputs.host_ip._text = "1.2.3.4"

UI.world_pw._text = "not saved"
rec_of("btn_save").fn()
check(cfg.get("join_password") == PW, "the footer's Save does not touch it")
UI.world_pw._text = PW
-- a wrong password: recently turned away
local n_idx = 0
local function join(key)
    n_idx = n_idx + 1
    local pc = mkpc(key, 2)
    session.state.remote[key] = { key = key, pc = pc, index = n_idx, name = "Player " .. n_idx, hello = false,
                                  joined_at = NOW, pawnless_since = NOW, spawned_once = false }
    return session.state.remote[key]
end
local pete = join("pete")
admin.on_early_id(pete, "Pete", "76561190000000077")
handlers.JPW({ "nope" }, pete.pc)
UI.refresh_world()
m = UI.world_model()
check(m.recent[1] and m.recent[1].name == "Pete" and m.recent[1].info == "неверный пароль" and m.recent[1].act
    and UI.world_rows.recent.rows[1].info._text == "неверный пароль", "recently turned away: «неверный пароль», Add to list")
UI.on_world_add(1)
check(cfg.get("allowed_players"):find("76561190000000077:Pete", 1, true) ~= nil, "Add to list: Pete gets in next time without it")
-- «По паролю» with no password saved: KICK|6|3, its own reason
admin.set_join_password("")
local nora = join("nora")
admin.on_early_id(nora, "Nora", "76561190000000078")
UI.refresh_world()
m = UI.world_model()
local kn = last_sent("KICK", "nora").f
check(kn[1] == "6" and kn[2] == "3" and m.recent[1] and m.recent[1].name == "Nora" and m.recent[1].info == "пароль не задан"
    and UI.world_rows.recent.rows[1].info._text == "пароль не задан",
    "no password saved: KICK|6|3, recently turned away «пароль не задан»")
admin.set_join_password(PW)
click(UI.mode_buttons.approve)
check(cfg.get("join_access") == "approve" and not vis(UI.world_pw_box), "«По одобрению»: the password box goes")
UI.frame_tick()
check(not polled("wa_pw_save"), "its Save is not polled")
click(UI.mode_buttons.list)
check(cfg.get("join_access") == "list" and UI.world_caption._text:find("отправляет ему приглашение", 1, true) ~= nil,
    "«Только приглашённые»: the caption names the Steam invite")
i18n.set("en")
click(UI.mode_buttons.password)
check(UI.world_caption._text:find("by IP and through Steam alike", 1, true) ~= nil and UI.world_pw_state._text == "The password is set.",
    "English: caption, state")
i18n.set("auto")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- ---------------------------------------------------------------- 2. the IP tab
io.write("2. the IP tab\n")
session.state.role = "standalone"
cfg.set("host_ip", "26.1.2.3")
cfg.set("port", 7777)
cfg.set("host_passwords", "26.1.2.3:7777=abc")
UI.set_open(false)
UI.set_open(true)
UI.pick_tab("ip")
check(UI.ip_pw ~= nil and UI.ip_pw._masked == true, "a masked password field")
check(UI.ip_pw._text == "abc", "it shows the password kept for this address")
check(UI.inputs.host_passwords == nil and UI.inputs.join_password == nil, "not a plain settings input (its own rules)")
joins = {}
click(rec_of("btn_join"))
check(#joins == 1 and joins[1].ip == "26.1.2.3" and cfg.get("host_passwords") == "26.1.2.3:7777=abc", "Join: as kept")
-- another address, the field left as shown: not carried over
UI.inputs.host_ip._text = "26.9.9.9"
click(rec_of("btn_join"))
check(joins[#joins].ip == "26.9.9.9" and admin.saved_pw("26.9.9.9:7777") == "" and UI.ip_pw._text == "",
    "another address, the field untouched: the old password is not kept for it (the field shows the new one's: none)")
UI.ip_pw._text = "xyz"
click(rec_of("btn_join"))
check(admin.saved_pw("26.9.9.9:7777") == "xyz" and admin.saved_pw("26.1.2.3:7777") == "abc", "an edit: kept for this address only")
UI.inputs.host_ip._text = "26.1.2.3"
click(rec_of("btn_join"))
check(UI.ip_pw._text == "abc", "back to the first address: its own password")
UI.ip_pw._text = ""
click(rec_of("btn_join"))
check(admin.saved_pw("26.1.2.3:7777") == "", "cleared: forgotten")
admin.save_pw("steam:76561190000000042", "steam-pw")
UI.inputs.host_ip._text = "76561190000000042"
click(rec_of("btn_join"))
check(UI.ip_pw._text == "steam-pw", "a friend's Steam code in the address: that friend's password")
-- the footer's «Сохранить» (no join): the typed address and password kept
-- together (auto_join after a restart answers with it)
UI.inputs.host_ip._text = "26.5.5.5"
UI.ip_pw._text = "footer-pw"
local nj = #joins
rec_of("btn_save").fn()
check(admin.saved_pw("26.5.5.5:7777") == "footer-pw" and cfg.get("host_ip") == "26.5.5.5" and #joins == nj,
    "the footer's Save: the typed password kept for the typed address (no join)")
check(game_got[#game_got] == "Настройки сохранены." and UI.ip_pw._text == "footer-pw" and UI.ip_pw_shown == "footer-pw",
    "  «Настройки сохранены», the field shows what is kept")
UI.inputs.host_ip._text = "26.6.6.6"
rec_of("btn_save").fn()
check(admin.saved_pw("26.6.6.6:7777") == "" and admin.saved_pw("26.5.5.5:7777") == "footer-pw" and UI.ip_pw._text == "",
    "the footer's Save, another address, the field left as shown: not carried over")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- ---------------------------------------------------------------- 3. the join cover
io.write("3. the join cover\n")
UI.set_open(false)
local function tick() UI.join_cover_tick(); return UI.join_cover_model() end
local function connect()
    session.state.role = "client"
    session.state.client = { connected_at = NOW }
    W.pc = mkpc("PC_client_" .. NOW, 2)
    W.pawn = nil
end
local function leave()
    session.state.role = "standalone"
    session.state.client = nil
    W.pawn, W.pending = nil, false
    W.pc = mkpc("PC_menu_" .. NOW, 3)
    tick()
end
local function ip_join(target)
    JC.s = nil
    leave()
    local j = session.state.join
    j.started_at, j.target, j.code, j.via = NOW + 1, target, target, "ip"
    W.pending = true
    tick()
    connect()
    W.pending = false
    return tick()
end
cfg.set("host_ip", "10.0.0.5")
cfg.set("port", 7777)
cfg.set("host_passwords", "")
UI.set_open(true)
UI.pick_tab("ip")
UI.set_open(false)
m = ip_join("10.0.0.5:7777")
check(m.visible and m.stage == "pawn", "in the host's world, no character")
handlers.ACCESS({ "pw" })
check(last_sent("JPW", "host").f[1] == "", "asked: nothing kept for this host, an empty answer")
stopped = nil
handlers.KICK({ "6", "0", "0" })
m = UI.join_cover_model()
check(JC.s.finished == "failed" and m.title == "Не удалось подключиться" and m.text == "Хост требует пароль" and #m.steps == 0,
    "KICK|6|0: «Хост требует пароль» (no steps)")
check(m.hint == "Узнайте пароль у хоста, впишите его ниже и нажмите «Войти»." and m.password == true, "what to do; the password prompt")
check(vis(UI.jc_pw_row) and vis(UI.jc_enter) and not vis(UI.jc_retry) and vis(UI.jc_close) and UI.jc_pw._masked == true,
    "a masked field, Join (no Try again), Close")
check(JC.enter_shown and not JC.retry_shown, "Join is polled, Try again is not")
check(stopped ~= nil, "the automatic join stops")
check(UI.jc_recs.enter ~= nil and not (function() for _, b in ipairs(UI.buttons) do if b == UI.jc_recs.enter then return true end end end)(),
    "Join is the cover's own button (not in the panel's list)")
leave()
m = UI.join_cover_model()
check(m.text == "Хост требует пароль" and m.password, "its 'disconnected' keeps the prompt")
UI.jc_pw._text = PW
joins = {}
click(UI.jc_recs.enter)
check(JC.s.finished == "closed" and admin.saved_pw("10.0.0.5:7777") == PW, "Join (a click): the password kept for this host")
check(#joins == 1 and joins[1].ip == "10.0.0.5" and joins[1].port == 7777, "and the same join again")
check(UI.ip_pw._text == PW and UI.ip_pw_shown == PW, "the IP tab's field shows it (the same address)")
check(logged("ui: join cover: Join with the typed password (10.0.0.5:7777)") ~= nil and not logged(PW), "logged, without the password")
-- the next attempt answers with it
m = ip_join("10.0.0.5:7777")
handlers.ACCESS({ "pw" })
check(last_sent("JPW", "host").f[1] == PW, "the next join answers with it")
-- wrong: a new refusal empties the field
handlers.KICK({ "6", "1", "0" })
m = UI.join_cover_model()
check(m.text == "Неверный пароль" and m.password and UI.jc_pw._text == "", "KICK|6|1: «Неверный пароль», an empty field")
UI.jc_pw._text = "typo"
JC.render(os.clock())
check(UI.jc_pw._text == "typo", "typing is kept while the same error shows")
JC.dismiss("test")
-- a Steam join: the friend's code
local FSID = "76561190000000042"
admin.save_pw("steam:" .. FSID, "steam-pw")
JC.s = nil
leave()
local j = session.state.join
j.started_at, j.target, j.code, j.via = NOW + 1, "steam:" .. FSID, "steam:" .. FSID, "ip"
W.pending = true
tick()
advance(2)
j.started_at, j.target, j.via = NOW + 2, "127.0.0.1:27500", "steam"
tick()
connect()
W.pending = false
tick()
handlers.ACCESS({ "pw" })
check(last_sent("JPW", "host").f[1] == "steam-pw", "a Steam join answers with the friend's own password")
handlers.KICK({ "6", "1", "0" })
m = UI.join_cover_model()
check(m.text == "Неверный пароль" and m.password and JC.s.first == "steam:" .. FSID, "a Steam join refused: the prompt, the friend's code")
UI.jc_pw._text = "right-one"
joins = {}
JC.enter()
check(admin.saved_pw("steam:" .. FSID) == "right-one" and joins[1] and joins[1].ip == FSID,
    "Join: kept for the Steam friend, the same friend again through Steam")
-- locked
m = ip_join("10.0.0.5:7777")
handlers.KICK({ "6", "2", "7" })
m = UI.join_cover_model()
check(m.text == "Слишком много неверных паролей — попробуйте через 7 мин." and m.hint == "Уточните пароль у хоста."
    and not m.retry and not m.password, "KICK|6|2: the minutes, ask the host; no field, no retry")
check(not vis(UI.jc_pw_row) and not vis(UI.jc_enter) and not vis(UI.jc_retry) and vis(UI.jc_close), "only Close")
JC.dismiss("test")
-- the host has set no password yet (KICK|6|3): say so; nothing to type, no retry
m = ip_join("10.0.0.5:7777")
handlers.KICK({ "6", "3", "0" })
m = UI.join_cover_model()
check(m.text == "Хост ещё не задал пароль" and m.hint:find("задать пароль на вкладке «Мир»", 1, true) ~= nil
    and not m.retry and not m.password, "KICK|6|3: «Хост ещё не задал пароль», ask the host; no field, no retry")
check(not vis(UI.jc_pw_row) and not vis(UI.jc_enter) and not vis(UI.jc_retry) and vis(UI.jc_close), "  only Close")
JC.dismiss("test")
-- no join recorded (a console "open" right after the game's start): an
-- empty answer, never the IP tab's address's password; Join keeps nothing
-- for a guessed host
check(admin.saved_pw("10.0.0.5:7777") == PW, "(the IP tab's address has a password kept)")
session.state.join = { target = nil, started_at = 0, attempts = 0 }
JC.s = nil
leave()
connect()
tick()
handlers.ACCESS({ "pw" })
check(last_sent("JPW", "host").f[1] == "" and logged("no join target known: an empty answer") ~= nil,
    "no join recorded: an empty answer (not the IP tab's address's password)")
handlers.KICK({ "6", "0", "0" })
m = UI.join_cover_model()
local HINT_WHERE = "Это подключение начато не из панели мода, поэтому мод не знает адрес хоста. Подключитесь к нему на вкладке «IP» (адрес и пароль) или «Steam» — там пароль можно ввести."
check(m.visible and m.text == "Хост требует пароль" and m.hint == HINT_WHERE and not m.password and not m.retry,
    "  refused: «Хост требует пароль», where to join it from; no field, no Join (no address to keep it for)")
check(not vis(UI.jc_pw_row) and not vis(UI.jc_enter) and not vis(UI.jc_retry) and vis(UI.jc_close)
    and not JC.enter_shown and not JC.retry_shown, "  only Close (Join / Try again not polled)")
UI.jc_pw._text = "for-another-host"
local nj0 = #joins
JC.enter()
check(admin.saved_pw("10.0.0.5:7777") == PW and #joins == nj0
    and logged("the failed join recorded no target, the password is not kept, no join") ~= nil,
    "  Join called anyway: nothing kept for the IP tab's address, no join to it (logged)")
JC.dismiss("test")
-- an old join's cover still waiting when sdc_session's bind_join forgot that
-- join at this connection's start (not that join's): the cover does not take
-- the old address for it
admin.save_pw("10.0.0.9:7777", "pw-old")
JC.s = nil
leave()
local jo = session.state.join
jo.started_at, jo.target, jo.code, jo.via = NOW + 1, "10.0.0.9:7777", "10.0.0.9:7777", "ip"
W.pending = true
tick()
check(JC.s and JC.s.first == "10.0.0.9:7777" and not JC.s.finished, "(a join to 10.0.0.9 armed the cover)")
jo.code, jo.target, jo.via = nil, nil, nil   -- as bind_join does for a connection that is not the join
connect()
W.pending = false
m = tick()
check(JC.s.why == "connected" and JC.s.first == nil and JC.s.target == nil, "  the new connection: a cover of its own, no address")
handlers.ACCESS({ "pw" })
check(last_sent("JPW", "host").f[1] == "", "  asked: an empty answer, not the old join's password")
handlers.KICK({ "6", "1", "0" })
m = UI.join_cover_model()
check(m.text == "Неверный пароль" and m.hint == HINT_WHERE and not m.password, "  refused: no field, the hint says where to join from")
UI.jc_pw._text = "x"
JC.enter()
check(admin.saved_pw("10.0.0.9:7777") == "pw-old", "  nothing kept for the old join's address")
JC.dismiss("test")
-- join_cover on: a console "open" while an earlier error shows takes it down
JC.s = nil
leave()
connect()
handlers.KICK({ "6", "0", "0" })
m = UI.join_cover_model()
check(m.visible and m.error and m.text == "Хост требует пароль", "join_cover on: a refusal shows")
leave()
connect()
m = tick()
check(m.visible and not m.error and m.stage ~= "failed" and JC.s.err == nil,
    "  a new connection (console open): the error goes, the new join's own cover shows (" .. tostring(m.stage) .. ")")
leave()
-- join_cover off: the password prompt still comes up; other refusals stay notices
cfg.set("join_cover", false)
-- a console "open" (no join recorded): the window says where to join it from
JC.s = nil
leave()
connect()
handlers.KICK({ "6", "0", "0" })
m = UI.join_cover_model()
check(m.visible and not m.password and m.hint == HINT_WHERE, "join_cover off, a console open refused: the window, where to join from (no field)")
JC.dismiss("test")
-- a join from the panel: the field
m = ip_join("10.0.0.5:7777")
handlers.KICK({ "6", "0", "0" })
m = UI.join_cover_model()
check(m.visible and m.password and m.text == "Хост требует пароль" and vis(UI.jc_pw_row) and JC.s.first == "10.0.0.5:7777",
    "join_cover off: the password prompt still shows (a join from the panel: the field)")
leave()
-- ... until the next join another way than its Join: the IP tab's «Подключиться»
-- (sdc_session.join stamps the join; also the Steam tab, sdcoop_join, a Steam invite)
local real_join, stamp = session.join, 10
session.join = function(ip, port, auto)
    joins[#joins + 1] = { ip = ip, port = port, auto = auto }
    local jj = session.state.join
    stamp = stamp + 1
    jj.started_at, jj.target, jj.via = NOW + stamp, string.format("%s:%d", ip, port), "ip"
    jj.code = jj.target
end
UI.set_open(true)
UI.pick_tab("ip")
joins = {}
click(rec_of("btn_join"))
UI.set_open(false)
check(#joins == 1, "the IP tab's Join")
m = tick()
check(not m.visible and JC.s.finished == "closed" and JC.s.closed_by == "a new join",
    "join_cover off: the next join takes the prompt down")
connect()
m = tick()
check(not m.visible, "  and it stays down over the host's world")
session.join = real_join
-- ... or a new connection (console "open": no join stamped)
JC.s = nil
leave()
connect()
handlers.KICK({ "6", "1", "0" })
check(UI.join_cover_model().password, "join_cover off: the prompt again")
leave()
connect()
m = tick()
check(not m.visible and JC.s.closed_by == "a new connection", "  a new connection takes it down")
leave()
JC.dismiss("test")
JC.s = nil
connect()
local ng = #game_got
handlers.KICK({ "3" })
m = UI.join_cover_model()
check(not m.visible and #game_got == ng + 1 and game_got[#game_got] == "Хост не впустил вас в мир.", "join_cover off: another refusal is a notice")
leave()
JC.s = nil
connect()
ng = #game_got
handlers.KICK({ "6", "3", "0" })
m = UI.join_cover_model()
check(not m.visible and #game_got == ng + 1
    and game_got[#game_got] == "Хост ещё не задал пароль для входа — попросите его задать пароль на вкладке «Мир».",
    "join_cover off: «no password set yet» is a notice (nothing to type)")
cfg.set("join_cover", true)
leave()
-- English
cfg.set("language", "en")
m = ip_join("10.0.0.5:7777")
handlers.KICK({ "6", "1", "0" })
m = UI.join_cover_model()
check(m.title == "Couldn't join" and m.text == "Wrong password" and m.hint == "Ask the host for the password, type it below and press Join."
    and i18n.T("jc_btn_enter") == "Join", "English: " .. m.text)
JC.dismiss("test")
JC.s = nil
leave()
session.state.join = { target = nil, started_at = 0, attempts = 0 }
connect()
tick()
handlers.KICK({ "6", "0", "0" })
m = UI.join_cover_model()
check(m.text == "The host requires a password" and not m.password
    and m.hint == "This join didn't start from the mod's panel, so the mod doesn't know the host's address. Join it from the IP tab (address and password) or the Steam tab, where you can enter the password.",
    "English, no join recorded: where to join it from")
cfg.set("language", "auto")
JC.dismiss("test")
leave()
local keys = { "f_host_pw", "f_host_pw_hint", "wa_mode_password", "wa_cap_password", "wa_pw_title", "wa_pw_hint", "wa_pw_save",
               "wa_pw_set", "wa_pw_unset", "wa_pw_cap", "wa_why_pw_none", "wa_why_pw_wrong", "wa_why_pw_locked",
               "wa_why_pw_unset", "jc_btn_enter", "jc_err_pw_hint_where" }
for _, k in ipairs({ "access_pw_need_you", "access_pw_wrong_you", "access_pw_locked_you", "access_pw_unset_you" }) do
    local e = JC.FAIL[k]
    if e and e.text then keys[#keys + 1] = e.text end
    keys[#keys + 1] = e and e.hint or ("missing FAIL " .. k)
end
local missing = {}
for _, k in ipairs(keys) do if not (i18n.STR.ru[k] and i18n.STR.en[k]) then missing[#missing + 1] = k end end
check(#missing == 0, "every new string in RU and EN: " .. table.concat(missing, ","))
check(JC.FAIL.access_pw_need_you.password and JC.FAIL.access_pw_wrong_you.password and JC.FAIL.access_pw_locked_you.no_retry
    and JC.FAIL.access_pw_need_you.door, "cover flags: password / no retry / at the door")
check(JC.FAIL.access_pw_unset_you.no_retry and not JC.FAIL.access_pw_unset_you.password and JC.FAIL.access_pw_unset_you.door,
    "unset: no retry, no field, at the door")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

io.write(nchecks, " checks, ", fails == 0 and "ALL OK" or (fails .. " FAILED"), "\n")
os.exit(fails == 0 and 0 or 1)
