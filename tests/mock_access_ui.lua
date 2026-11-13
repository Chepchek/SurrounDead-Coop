-- Mock harness: the co-op panel's World tab and the join cover's access
-- stages (sdc_ui + the real sdc_admin / sdc_i18n / sdc_config / sdc_log;
-- stub UMG widgets, engine and session).
--   1. the tab: five tabs, the bans left the settings, the client_cheats copy
--   2. a client / single player: one line
--   3. the host: the mode buttons (saved at once, a caption), the waiting
--      players (seconds, Allow / Deny, polled only on shown rows), the
--      recently refused (Add to list; rows without it keep their place),
--      the allowed list (Remove, "…and N more"), bans (Unban, Clear all),
--      Save the world now; the default tab while someone waits; English
--   3b. clicks through the frame loop: a double-click on a row does not act
--      on the entry that moved up; Clear all asks first and ignores a press
--      right after a row went; lists grow past their first rows (newest
--      first); a player refused before its id: no Add to list
--   3c. the Steam tab while hosting: Invite on a friend's row (Steam invite
--      + the allowed list)
--   4. the join cover: the wait for the host (no timeout while it waits,
--      the minute after it; at most WAIT_MAX_S), the refusals (KICK|2..5)
--   5. the cover hidden while waiting: a notice and a note; a refusal then:
--      "couldn't join", Try again joins the same Steam friend
-- usage: lua mock_access_ui.lua <scripts dir>
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
        if k == "SetVisibility" then return function(self, v) self._vis = v end end
        if k == "SetBrushColor" then return function(self, c) self._color = c end end
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
local session = {
    VERSION = "0.7.3",
    state = { role = "standalone", remote = {}, remote_pcs = {}, join = { target = nil, started_at = 0, attempts = 0 } },
    world_reset_hooks = {}, ui_hooks = {},
    join = noop, disconnect = noop, host_on_next_load = noop, start_fresh_server = noop, request_respawn = noop,
    roster = function() return {} end,
    stop_auto_join = function(why) stopped = why end,
}
package.loaded["sdc_session"] = session
package.loaded["sdc_widgets"] = { child = noop, first_text = noop, game_window_open = function() return false end }
local sent, handlers = {}, {}
package.loaded["sdc_net"] = {
    on = function(k, f) handlers[k] = f end, send_to_host = function() return true end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end,
    broadcast = noop,
}
local function last_sent(kind, to)
    for i = #sent, 1, -1 do if sent[i].kind == kind and sent[i].to == to then return sent[i] end end
    return { f = {} }
end
local SIDS = {}
package.loaded["sdc_persist"] = { steam_of = function(key) return SIDS[key] end, client_join_state = function() return {} end }
local saves_now = {}
package.loaded["sdc_savecheck"] = { save_now = function(reason, done) saves_now[#saves_now + 1] = done end }

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

-- ---------------------------------------------------------------- 1. the tab
W.pc = mkpc("PC_menu", 3)
local okb, errb = pcall(UI.build)
check(okb, "UI.build runs: " .. tostring(errb))
check(UI.pages.world ~= nil and UI.tab_ui.world ~= nil and UI.tab_ui.world.text._text == "Мир", "a World tab: «Мир»")
local order = {}
for _, id in ipairs({ "steam", "ip", "char", "world", "settings" }) do order[#order + 1] = UI.pages[id] ~= nil end
check(not table.concat({ tostring(order[1]), tostring(order[2]), tostring(order[3]), tostring(order[4]), tostring(order[5]) }):find("false"),
    "five pages")
local secs = {}
for _, sec in ipairs(UI.sections) do secs[sec.name] = true end
check(not secs.bans and secs.bug and secs.main, "the settings keep their sections; Bans left them")
check(UI.world_cheats ~= nil and #UI.checks.client_cheats >= 2, "client_cheats on the World tab: a copy of the setting")
UI.set_open(true)

-- ---------------------------------------------------------------- 2. not the host
UI.pick_tab("world")
local m = UI.world_model()
check(not m.host and m.guest == "Миром управляет хост — тот, кто открыл свой мир для друзей.", "single player: one line")
check(vis(UI.world_guest) and not vis(UI.world_host), "only that line is shown")
session.state.role = "client"
UI.refresh_world()
check(not UI.world_model().host and vis(UI.world_guest), "a client: the same line")

-- ---------------------------------------------------------------- 3. the host
session.state.role = "host"
UI.refresh_world()
m = UI.world_model()
check(m.host and m.mode == "open" and m.caption == "Входят все, кроме забаненных." and not m.show_waiting and not m.show_recent,
    "host, open: the caption, nobody waits")
check(vis(UI.world_host) and not vis(UI.world_guest) and UI.world_caption._text == m.caption, "the host's controls shown")
check(UI.mode_buttons.open.colors == UI.lang_buttons.auto.colors and UI.mode_buttons.list.colors ~= UI.lang_buttons.auto.colors,
    "the chosen mode's button is the primary one (as the language buttons)")
check(not vis(UI.world_wait_box) and not vis(UI.world_recent_box) and not vis(UI.world_limit), "no waiting / refused lists, no limit line")
check(vis(UI.world_rows.allowed.empty)
    and UI.world_rows.allowed.empty._text == "Список пуст. Сюда попадают впущенные («Пустить»), вошедшие по паролю и приглашённые с вкладки «Steam».",
    "the allowed list: empty")
check(vis(UI.world_rows.bans.empty) and not vis(UI.world_unban_all), "bans: nobody, no Clear all")
check(vis(UI.world_save_row) and m.can_save, "in a world: Save the world now")
saves = 0
UI.on_world_mode("approve")
m = UI.world_model()
check(cfg.get("join_access") == "approve" and saves == 1, "Approval: saved at once")
check(UI.world_caption._text == "Игроки из списка входят сразу, остальных вы впускаете здесь — на ответ 2 минуты."
    and UI.mode_buttons.approve.colors == UI.lang_buttons.auto.colors and UI.mode_buttons.open.colors ~= UI.mode_buttons.approve.colors,
    "its caption and button")
check(vis(UI.world_wait_box) and vis(UI.world_rows.wait.empty) and UI.world_rows.wait.empty._text == "Никто не ждёт.",
    "approve: the waiting list (nobody yet)")
cfg.set("max_players", 4)
UI.refresh_world()
check(vis(UI.world_limit) and UI.world_limit._text == "Не больше 4 игроков в мире, считая вас (max_players в config.ini).",
    "max_players: a line")
cfg.set("max_players", 0)

-- a player waits
local n_idx = 0
local function join(key)
    n_idx = n_idx + 1
    local pc = mkpc(key, 2)
    session.state.remote[key] = { key = key, pc = pc, index = n_idx, name = "Player " .. n_idx, hello = false,
                                  joined_at = NOW, pawnless_since = NOW, spawned_once = false }
    return session.state.remote[key]
end
local eve = join("eve")
admin.on_early_id(eve, "Eve", "76561190000000005")
check(game_got[#game_got] == "Eve хочет войти в мир: F7 → «Мир».", "the host's notice: " .. tostring(game_got[#game_got]))
advance(7)
UI.refresh_world()
m = UI.world_model()
local wr = UI.world_rows.wait.rows
check(#m.waiting == 1 and m.waiting[1].name == "Eve" and m.waiting[1].info == "7 с", "the model: Eve, 7 s")
check(vis(wr[1].row) and wr[1].name._text == "Eve" and wr[1].info._text == "7 с" and vis(wr[1].acts) and not vis(wr[2].row),
    "row 1: Eve · 7 с · Пустить / Отказать; row 2 hidden")
check(not vis(UI.world_rows.wait.empty), "no 'nobody waits'")
advance(1)
UI.refresh_world()
check(wr[1].info._text == "8 с", "the seconds go on")
check(UI.default_tab() == "world", "someone waits: the panel opens on the World tab")
UI.frame_tick()
local function polled(label, row)
    for _, b in ipairs(UI.active) do
        if b.label == label then
            if not row then return true end
            for _, g in ipairs(b.gates) do if g == row.acts then return true end end
        end
    end
    return false
end
check(polled("allow", wr[1]) and polled("deny", wr[1]) and not polled("allow", wr[2]), "Allow / Deny polled on the shown row only")
check(not polled("add to list") and not polled("unban"), "hidden lists' buttons are not polled")
UI.pick_tab("ip")
UI.frame_tick()
check(not polled("allow"), "another tab: not polled")
UI.pick_tab("world")
-- Allow
UI.on_world_allow(1)
check(last_sent("ACCESS", "eve").f[1] == "ok" and eve.access == "ok", "Allow: Eve let in")
m = UI.world_model()
check(#m.waiting == 0 and m.allowed[1] and m.allowed[1].name == "Eve" and UI.world_rows.allowed.rows[1].name._text == "Eve",
    "the waiting list empties, Eve is on the allowed list")
UI.user_tab = "ip"
check(UI.default_tab() == "ip", "nobody waits: the tab picked last")
UI.user_tab = "world"
-- Deny, then the recently refused
local zed = join("zed")
admin.on_early_id(zed, "Zed", nil)
local yan = join("yan")
admin.on_early_id(yan, "Yan", nil)
UI.refresh_world()
check(UI.world_rows.wait.rows[1].name._text == "Zed" and UI.world_rows.wait.rows[2].name._text == "Yan", "two wait, in order")
UI.on_world_deny(1)
check(last_sent("KICK", "zed").f[1] == "3", "Deny: KICK|3 to Zed")
m = UI.world_model()
check(m.show_recent and m.recent[1].name == "Zed" and m.recent[1].info == "отказано" and m.recent[1].act, "Zed: recently turned away (отказано)")
check(vis(UI.world_recent_box) and UI.world_rows.recent.rows[1].info._text == "отказано", "shown")
UI.on_world_deny(1)   -- now Yan is the first row
local rr = UI.world_rows.recent.rows
check(rr[1].name._text == "Yan" and rr[2].name._text == "Zed", "Yan too, newest first")
UI.on_world_add(2)
check(cfg.get("allowed_players"):find("Zed", 1, true) ~= nil, "Add to list: Zed goes on the list")
UI.refresh_world()
check(vis(rr[1].acts) and rr[2].acts._vis == 2 and UI.off[rr[2].acts] == true,
    "Zed's row: no button, its place kept (hidden); Yan's button stays")
UI.on_world_add(2)
check(select(2, cfg.get("allowed_players"):gsub("Zed", "")) == 1, "a listed player: Add does nothing")
-- the allowed list: newest first (Zed was added after Eve), Remove, more than the first rows
check(UI.world_rows.allowed.rows[1].name._text == "Zed" and UI.world_rows.allowed.rows[2].name._text == "Eve",
    "the allowed list: the newest first")
UI.on_world_remove(2)
check(not cfg.get("allowed_players"):find("Eve", 1, true) and cfg.get("allowed_players"):find("Zed", 1, true) ~= nil,
    "Remove: Eve taken off")
cfg.set("allowed_players", "A1;A2;A3;A4;A5;A6;A7;A8")
UI.refresh_world()
local arows = UI.world_rows.allowed.rows
check(#arows == 8 and arows[1].name._text == "A8" and arows[8].name._text == "A1" and vis(arows[8].row)
    and vis(arows[8].acts) and not vis(UI.world_rows.allowed.more), "8 entries: 8 rows (2 built now), the newest first, all shown")
UI.frame_tick()
check(polled("remove from list", arows[8]), "a row built later: its button is polled")
UI.on_world_remove(8)
check(cfg.get("allowed_players") == "A2;A3;A4;A5;A6;A7;A8", "Remove on a row built later: A1 taken off")
local many = {}
for n = 1, 45 do many[n] = "M" .. n end
cfg.set("allowed_players", table.concat(many, ";"))
UI.refresh_world()
check(#arows == 40 and arows[1].name._text == "M45" and arows[40].name._text == "M6" and vis(UI.world_rows.allowed.more)
    and UI.world_rows.allowed.more._text == "…и ещё 5", "45 entries: at most 40 rows, the newest first, '…и ещё 5'")
-- bans
cfg.set("banned_players", "76561190000000011:Bob;Ivan")
UI.refresh_world()
local br = UI.world_rows.bans.rows
check(br[1].name._text == "Ivan" and br[2].name._text == "Bob" and vis(UI.world_unban_all) and not vis(UI.world_rows.bans.empty),
    "bans: each name, the newest first, Clear all")
UI.on_world_unban(1)
check(cfg.get("banned_players") == "76561190000000011:Bob" and not vis(br[2].row), "Unban: Ivan's ban lifted")
UI.on_world_unban_all()
check(cfg.get("banned_players") == "76561190000000011:Bob" and UI.world_unban_all_text._text == "Точно?",
    "Clear all: the first click only asks («Точно?»)")
UI.on_world_unban_all()
check(cfg.get("banned_players") == "" and vis(UI.world_rows.bans.empty) and not vis(UI.world_unban_all), "Clear all: the second click clears")
-- Save the world now
UI.on_world_save()
check(#saves_now == 1 and admin.saving(), "Save the world now: sdc_savecheck.save_now")
saves_now[1](true)
check(not admin.saving() and game_got[#game_got] == "Мир сохранён.", "done: «Мир сохранён.»")
W.menu = true
UI.refresh_world()
check(not vis(UI.world_save_row), "the main menu (no world loaded): no Save button")
W.menu = false
-- the client_cheats copy: applied and saved at once from this tab
UI.slow_tick()          -- its first run follows the world (in a world: the panel closes)
cfg.set("client_cheats", true)
UI.set_open(true)       -- every copy shows the setting
UI.pick_tab("world")
check(UI.open and UI.tab == "world" and UI.world_cheats._checked == true, "the panel open on the World tab")
saves = 0
UI.world_cheats._checked = false
UI.slow_tick()
local all_off = true
for _, cb in ipairs(UI.checks.client_cheats) do if cb._checked then all_off = false end end
check(cfg.get("client_cheats") == false and saves >= 1 and all_off, "the World tab's checkbox: set, saved, the other copies follow")
check(logged("ui: world: client_cheats = false (saved: true)") ~= nil, "log line")
-- English
i18n.set("en")
UI.refresh_world()
m = UI.world_model()
check(UI.tab_ui.world.text._text == "World" and UI.world_caption._text == "Players on the list join at once; you let the others in here (2 minutes to answer).",
    "English: the tab and the caption")
local yan_row = UI.world_rows.recent.rows[1]
check(yan_row.info._text == "denied" and UI.world_rows.allowed.more._text == "…and 5 more", "English: the rows")
local cyr = {}
for _, w in ipairs(created) do
    if w._class == "TextBlock" and type(w._text) == "string" and w._text:find("[\208\209]") and w._text ~= "Русский" then
        cyr[#cyr + 1] = w._text
    end
end
check(#cyr == 0, "no Russian text left in English: " .. table.concat(cyr, " | "))
i18n.set("auto")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- ---------------------------------------------------------------- 3b. clicks through the frame loop
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
-- the mouse on `rec`'s widget: held down or not, every frame
local function mouse_on(rec)
    local P = { down = false }
    rawset(rec.w, "IsPressed", function() return P.down end)
    rawset(rec.w, "IsHovered", function() return true end)
    return function(down) P.down = down; UI.frame_tick() end,
        function() rawset(rec.w, "IsPressed", nil); rawset(rec.w, "IsHovered", nil); UI.frame_tick() end
end
UI.set_open(true)
UI.pick_tab("world")
cfg.set("join_access", "approve")
cfg.set("allowed_players", "")
local dz, dy = join("dz"), join("dy")
admin.on_early_id(dz, "Dzed", nil)
admin.on_early_id(dy, "Dyan", nil)
UI.refresh_world()
local w1 = UI.world_rows.wait.rows[1]
check(w1.name._text == "Dzed" and UI.world_rows.wait.rows[2].name._text == "Dyan", "double-click: two players wait")
advance(1)
local allow1 = rec_of("allow", w1.acts)
local frame, off = mouse_on(allow1)
frame(true); frame(false)
check(dz.access == "ok" and dy.access == "wait" and w1.name._text == "Dyan", "the first click: Dzed let in; row 1 holds Dyan now")
advance(0.15)
frame(true); frame(false)       -- the double-click's second press, the same spot
check(dy.access == "wait" and not cfg.get("allowed_players"):find("Dyan", 1, true),
    "the double-click's second click does nothing: Dyan still waits, not on the list")
check(logged("'allow' on row 1 not done: the row got another entry right before the click") ~= nil, "log line")
advance(1)
frame(true); frame(false)
check(dy.access == "ok", "a deliberate click a moment later: Dyan let in")
off()
-- a row that changed while the button was held down
local dx = join("dx")
admin.on_early_id(dx, "Dxi", nil)
local dw = join("dw")
admin.on_early_id(dw, "Dwo", nil)
UI.refresh_world()
advance(1)
local deny1 = rec_of("deny", w1.acts)
frame, off = mouse_on(deny1)
frame(true)
admin.deny("dx")                -- Dxi goes while the button is held: Dwo comes up to row 1
UI.world_sig = nil
UI.refresh_world()
advance(0.2)
frame(false)
check(dw.access == "wait" and w1.name._text == "Dwo", "held while the row changed: Dwo is not turned away")
off()
admin.deny("dw")
-- more waiting players than the first rows: every one can be answered
local six = {}
for n = 1, 6 do six[n] = join("q" .. n); admin.on_early_id(six[n], "Q" .. n, nil) end
UI.refresh_world()
check(#UI.world_rows.wait.rows == 6 and vis(UI.world_rows.wait.rows[6].row) and not vis(UI.world_rows.wait.more)
    and UI.world_rows.wait.rows[6].name._text == "Q6", "6 waiting: 6 rows (2 built now), none hidden")
UI.on_world_allow(6)
check(six[6].access == "ok", "Allow on the 6th row")
for n = 1, 5 do admin.deny("q" .. n) end
-- Clear all: it slides up under a double-click on the last Unban
cfg.set("banned_players", "Ban1;Ban2")
UI.refresh_world()
local bl = UI.world_rows.bans
check(bl.rows[1].name._text == "Ban2" and bl.rows[2].name._text == "Ban1", "two bans, the newest first")
advance(1)
local unban2 = rec_of("unban", bl.rows[2].acts)
frame, off = mouse_on(unban2)
frame(true); frame(false)
off()
check(cfg.get("banned_players") == "Ban2" and not vis(bl.rows[2].row), "Unban on the last row: Ban1 lifted, the row goes")
local all_rec = rec_of("btn_unban")
frame, off = mouse_on(all_rec)
advance(0.15)
frame(true); frame(false)       -- the double-click's second press lands on Clear all
check(cfg.get("banned_players") == "Ban2" and UI.world_unban_all_text._text == "Снять все",
    "a press on Clear all right after a row went: nothing (not even «Точно?»)")
advance(1)
frame(true); frame(false)
check(cfg.get("banned_players") == "Ban2" and UI.world_unban_all_text._text == "Точно?", "Clear all: the first click asks")
advance(6)
UI.refresh_world()
check(UI.world_unban_all_text._text == "Снять все", "5 s without a second click: the question goes")
frame(true); frame(false)
check(cfg.get("banned_players") == "Ban2", "a click after that asks again, clears nothing")
advance(1)
frame(true); frame(false)
check(cfg.get("banned_players") == "" and not vis(UI.world_unban_all), "a second click within 5 s: cleared")
off()
-- a player refused before it said who it is: no «Добавить в список» for its placeholder name
cfg.set("join_access", "list")
local anon = join("anon")
admin.access_gate(anon, NOW + 60)
UI.refresh_world()
local rr1 = UI.world_rows.recent.rows[1]
check(anon.access == "refused" and rr1.name._text == anon.name and UI.off[rr1.acts] == true,
    "refused without its id: shown, no «Добавить в список» for '" .. tostring(anon.name) .. "'")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- ---------------------------------------------------------------- 3c. Steam: Invite on a friend's row
local sl_calls, sl_state, sl_invite_ok = {}, "hosting", true
package.loaded["sdc_steamlink"] = {
    status = function() return { state = sl_state, friends_only = true, detail = "Open", helper = true, peers = 0 } end,
    friends = function()
        return { { id = "76561190000000071", name = "Kate", joinable = false, status = "in SurrounDead" },
                 { id = "76561190000000072", name = "Lev", joinable = true, version = session.VERSION, status = "hosting" } }
    end,
    join = function(id) sl_calls[#sl_calls + 1] = "join " .. id return true end,
    invite = function() return true end,
    invite_friend = function(id)
        sl_calls[#sl_calls + 1] = "invite " .. id
        if sl_invite_ok then return true end
        return false, "Не удалось передать приглашение помощнику Steam.", "sl_invite_cmd"
    end,
}
cfg.set("allowed_players", "")
UI.pick_tab("steam")
UI.refresh_status()
local fr = UI.friend_rows
check(fr[1].name._text == "Lev" and fr[2].name._text == "Kate", "the friends: the one hosting first")
check(vis(fr[1].invite) and vis(fr[2].invite) and not vis(fr[1].join) and not vis(fr[2].join),
    "hosting: «Пригласить» on every friend's row, no «Подключиться»")
local inv1 = rec_of("btn_steam_invite_one", fr[2].row)
inv1.fn()
check(sl_calls[#sl_calls] == "invite 76561190000000071" and cfg.get("allowed_players") == "76561190000000071:Kate",
    "Invite: a Steam invite to Kate, Kate on the allowed list by SteamID")
check(game_got[#game_got] == "Приглашение через Steam отправлено: Kate (в списке допущенных).", "one notice: " .. tostring(game_got[#game_got]))
local kate = join("katepc")
check(admin.on_early_id(kate, "Kate", "76561190000000071") == false and kate.access == "ok", "invite only: Kate gets in")
UI.pick_tab("world")
UI.refresh_world()
check(UI.world_rows.allowed.rows[1].name._text == "Kate", "the World tab lists her")
UI.pick_tab("steam")
sl_invite_ok = false
local n_toasts = #UI.toasts + #game_got
rec_of("btn_steam_invite_one", fr[1].row).fn()
check(not cfg.get("allowed_players"):find("76561190000000072", 1, true) and #UI.toasts + #game_got == n_toasts + 1,
    "the invite failed: not on the list, told why")
sl_state = "ready"
UI.refresh_status()
check(not vis(fr[1].invite) and not vis(fr[2].invite) and vis(fr[1].join) and not vis(fr[2].join),
    "not hosting: «Подключиться» as before, no «Пригласить»")
package.loaded["sdc_steamlink"] = nil
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- ---------------------------------------------------------------- 4. the join cover
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
JC.s = nil
leave()
connect()
m = tick()
check(m.visible and m.stage == "pawn", "in the host's world, no character: pawn")
local toasts0 = #UI.toasts + #game_got
handlers.ACCESS({ "wait" })
m = tick()
check(session.state.client.access == "wait" and m.stage == "wait" and m.text == "Ждём, пока хост вас впустит…", "ACCESS|wait: the wait stage")
check(m.hint == "Хост видит ваш запрос в панели кооператива. Если он не ответит за 2 минуты, вход отменится.", "its hint")
check(m.steps[3].state == "now" and m.steps[2].state == "done", "steps: the character step")
check(#UI.toasts + #game_got == toasts0, "no toast: the cover says it")
check(logged("ui: join cover: stage pawn -> wait") ~= nil, "log: the stage")
advance(100)
m = tick()
check(m.visible and m.stage == "wait" and not JC.s.finished, "100 s of waiting: no timeout")
handlers.ACCESS({ "ok" })
m = tick()
check(m.stage == "pawn" and m.visible, "ACCESS|ok: waiting for the character again")
advance(59)
m = tick()
check(m.visible and m.stage == "pawn", "59 s after the wait: still covered")
advance(2)
m = tick()
check(JC.s.finished == "timeout", "the minute in the host's world counts from the end of the wait")
-- a wait never answered: at most WAIT_MAX_S
JC.s = nil
leave()
connect()
tick()
handlers.ACCESS({ "wait" })
tick()
advance(149)
m = tick()
check(m.stage == "wait", "149 s: still the wait")
advance(2)
m = tick()
check(m.stage == "pawn" and not JC.s.finished, "past WAIT_MAX_S: the usual pawn stage")
advance(61)
m = tick()
check(JC.s.finished == "timeout", "then the usual minute")
-- the toast while the cover is not up
JC.s = nil
leave()
cfg.set("join_cover", false)
connect()
local n0 = #game_got
handlers.ACCESS({ "wait" })
check(#game_got == n0 + 1 and game_got[#game_got] == "Хост должен вас впустить — ждём ответа (до 2 минут).",
    "join cover off: a notice says it")
cfg.set("join_cover", true)
-- refusals
local REFUSALS = {
    { "2", "Этот мир только по приглашению", "«Кооператив» → «Мир»", false },
    { "3", "Хост не впустил вас", "Подключиться снова можно", true },
    { "4", "Хост не ответил на запрос", "за 2 минуты", true },
    { "5", "Мир заполнен", "кто-нибудь выйдет", true },
}
for _, rf in ipairs(REFUSALS) do
    JC.s = nil
    leave()
    session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 1, "10.0.0.5:7777", "ip"
    W.pending = true
    tick()
    connect()
    W.pending = false
    tick()
    handlers.ACCESS({ "wait" })
    tick()
    stopped = nil
    handlers.KICK({ rf[1] })
    m = UI.join_cover_model()
    check(JC.s.finished == "failed" and m.title == "Не удалось подключиться" and m.text == rf[2] and #m.steps == 0,
        "KICK|" .. rf[1] .. ": " .. m.text .. " (no steps)")
    check(m.hint:find(rf[3], 1, true) ~= nil and m.retry == rf[4], "KICK|" .. rf[1] .. ": hint, Try again " .. tostring(rf[4]))
    check(stopped ~= nil, "KICK|" .. rf[1] .. ": the automatic join stops")
    leave()
    m = UI.join_cover_model()
    check(m.text == rf[2], "KICK|" .. rf[1] .. ": its 'disconnected' keeps the reason")
end
JC.dismiss("test")
cfg.set("language", "en")
JC.s = nil
connect()
tick()
handlers.KICK({ "4" })
m = UI.join_cover_model()
check(m.title == "Couldn't join" and m.text == "The host didn't answer your request" and not m.hint:find("[\208\209]"), "English: " .. m.text)
JC.dismiss("test")
leave()
connect()
tick()
handlers.ACCESS({ "ok" })
handlers.ACCESS({ "wait" })
m = tick()
check(m.text == "Waiting for the host to let you in…", "English wait: " .. m.text)
cfg.set("language", "auto")
local keys = { JC.TEXT.wait, JC.HINT.wait }
for _, k in ipairs({ "access_list_you", "access_denied_you", "access_timeout_you", "access_full_you" }) do
    local e = JC.FAIL[k]
    keys[#keys + 1] = e and e.text or ("missing FAIL " .. k)
    keys[#keys + 1] = e and e.hint or ("missing FAIL " .. k)
end
local missing = {}
for _, k in ipairs(keys) do if not (i18n.STR.ru[k] and i18n.STR.en[k]) then missing[#missing + 1] = k end end
check(#missing == 0, "every new cover string in RU and EN: " .. table.concat(missing, ","))
check(JC.STEP.wait == 3 and JC.FAIL.access_list_you.no_retry and not JC.FAIL.access_full_you.no_retry, "steps / retry flags")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

-- ---------------------------------------------------------------- 5. the cover hidden while waiting
local joins = {}
session.join = function(ip, port) joins[#joins + 1] = { ip = ip, port = port } end
local WAIT_RU = "Хост должен вас впустить — ждём ответа (до 2 минут)."
-- a Steam join: the code as asked, then the tunnel's loopback address (sdc_session.join_tunnel)
local FSID = "76561190000000042"
local function steam_join_waiting()
    JC.s = nil
    leave()
    session.state.join.started_at, session.state.join.target = NOW + 1, "steam:" .. FSID
    session.state.join.code, session.state.join.via = "steam:" .. FSID, "ip"   -- via: left from an earlier IP join
    W.pending = true
    tick()
    advance(2)
    session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 2, "127.0.0.1:27500", "steam"
    tick()
    connect()
    W.pending = false
    tick()
    handlers.ACCESS({ "wait" })
    return tick()
end
m = steam_join_waiting()
check(m.stage == "wait" and JC.s.first == "steam:" .. FSID, "a Steam join waits for the host; the cover keeps the friend's code")
local n_game = #game_got
JC.finish(os.clock(), "key", "Esc")
m = tick()
check(not m.visible and #game_got == n_game + 1 and game_got[#game_got] == WAIT_RU,
    "hidden (Esc) while waiting: the usual notice says it at once")
check(m.note == WAIT_RU, "and a dim note stays over the game: " .. tostring(m.note))
advance(30)
m = tick()
check(m.note == WAIT_RU, "30 s later: the note is still there (still waiting)")
handlers.KICK({ "3" })
m = UI.join_cover_model()
check(m.visible and m.title == "Не удалось подключиться" and m.text == "Хост не впустил вас" and m.retry == true
    and m.note == nil, "then refused (KICK|3): «Не удалось подключиться» (not «Соединение прервано»), Try again, no note")
JC.retry()
check(joins[#joins] and joins[#joins].ip == FSID,
    "Try again: the same friend through Steam, not host_ip (" .. tostring(joins[#joins] and joins[#joins].ip) .. ")")
-- no cover of this connection at all (join_cover was off meanwhile): the session's code
m = steam_join_waiting()
JC.s = nil
handlers.KICK({ "5" })
m = UI.join_cover_model()
check(m.visible and m.title == "Не удалось подключиться" and m.text == "Мир заполнен" and m.retry == true,
    "no cover before the refusal: a new one, «Не удалось подключиться»")
JC.retry()
check(joins[#joins].ip == FSID, "Try again: the friend's code from sdc_session (" .. tostring(joins[#joins].ip) .. ")")
-- a kick while playing keeps its title
JC.s = nil
leave()
connect()
W.pawn = { _class = "BP_PlayerCharacter_C", IsValid = function() return true end }
handlers.KICK({ "0" })
m = UI.join_cover_model()
check(m.title == "Соединение с хостом прервано", "a kick while playing: still «Соединение с хостом прервано»")
W.pawn = nil
-- hidden while waiting, then let in: the note goes
JC.s = nil
leave()
connect()
tick()
handlers.ACCESS({ "wait" })
tick()
UI.on_menu_key()
m = tick()
check(m.note == WAIT_RU, "hidden by the menu key while waiting: the note")
handlers.ACCESS({ "ok" })
m = tick()
check(m.note == nil and game_got[#game_got] == "Хост впустил вас.", "let in: the note goes, the notice says so")
check(logged("ui: join cover: the wait note taken off (let in)") ~= nil, "log line")
-- hidden before the wait (no ACCESS yet): no wait notice
JC.s = nil
leave()
connect()
tick()
n_game = #game_got
JC.finish(os.clock(), "key", "Esc")
m = tick()
check(#game_got == n_game and m.note == nil, "hidden before any wait: nothing said, no note")
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

io.write(nchecks, " checks, ", fails == 0 and "ALL OK" or (fails .. " FAILED"), "\n")
