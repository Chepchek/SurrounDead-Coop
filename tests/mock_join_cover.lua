-- Mock harness: the join cover (sdc_ui, config join_cover) - a client's dark
-- full-screen cover with the joining progress, from the join until its own
-- character stands where the host put it. Real sdc_ui / sdc_i18n /
-- sdc_config / sdc_log / sdc_persist; stub UMG widgets, engine and session.
--   1. host / single player: never; a join asked: nothing shown until its
--      connection attempt runs (no flash on an instant failure)
--   2. IP join: connect -> load -> (level change: refs dropped, rebuilt with
--      the cover already on) -> pawn -> verdict -> restore -> Ready -> fade
--   3. a respawn in the same connection: no cover
--   4. joined by console (no join asked here) -> armed on the connection;
--      60 s in the host's world -> timeout: game shown + dim note, which goes
--      once the character is ready
--   5. new character: fresh until set up here (sdc_progress applies it)
--   6. F7 / Esc hide it; the connection that follows stays uncovered
--   7. cancel: a join whose attempt never shows up
--   8. Steam: the tunnel's status as the hint; join_tunnel's second stamp is
--      the same join
--   9. join_cover = false; a mod reload in the middle of a game; English
--  10. setting, strings, sdc_persist.client_join_state
--  11. failed joins: the reason on the cover (no toast), Close / Esc / Try
--      again / the menu key, the auto join's countdown, a kick while playing,
--      the host gone to its main menu while playing (HOSTMENU)
-- usage: lua mock_join_cover.lua <scripts dir>
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

-- log lines (sdc_log prints each one)
local LOGS = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOGS[#LOGS + 1] = table.concat(parts, "\t")
end
local function mark() return #LOGS end
local function logged(pat, from)
    for i = (from or 0) + 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return LOGS[i] end end
    return nil
end

-- time: os.clock drives the cover, os.time the session stamps
local CLK, NOW = 100.0, 5000000
os.clock = function() return CLK end
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end
local function advance(s) CLK = CLK + s; NOW = NOW + math.floor(s) end

-- ------------------------------------------------------------ UMG stubs
FName = function(s) return { name = s, ToString = function() return s end } end
FText = function(s) return s end
local function autostruct()
    return setmetatable({}, { __index = function(t, k) local s = autostruct(); rawset(t, k, s); return s end })
end
local widget_mt
local function make_widget(class)
    return setmetatable({ _class = class, _children = {}, _text = "" }, widget_mt)
end
local STRUCT_PROPS = { Font = true, WidgetStyle = true, Background = true }
widget_mt = {
    __index = function(t, k)
        if STRUCT_PROPS[k] then local s = autostruct(); rawset(t, k, s); return s end
        if k == "IsValid" then return function() return true end end
        if k == "SetText" then return function(self, s) self._text = s end end
        if k == "SetVisibility" then return function(self, v) self._vis = v end end
        if k == "SetRenderOpacity" then return function(self, a) self._alpha = a end end
        if k == "SetBrushColor" then return function(self, c) self._color = c end end
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
local W = { pc = nil, pawn = nil, pending = false, esc = false }
local function mkpc(name, role)
    return { _name = name, _role = role, IsValid = function() return true end,
             IsInputKeyDown = function(_, k) return W.esc and k.KeyName.name == "Escape" end }
end
local function mkpawn() return { _name = "BP_PlayerCharacter_C_1", _class = "BP_PlayerCharacter_C", ["PlayerDead?"] = false } end
local noop = function() return nil end
local culture_lib = { GetCurrentCulture = function() return "en" end, IsValid = function() return true end }
local ksl = { GetDefaultLanguage = function() return "ru-RU" end, IsValid = function() return true end,
              ConvertToAbsolutePath = function(_, rel) return "C:/Games/" .. rel end, LaunchURL = noop }
local ue = setmetatable({
    ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3,
    valid = function(o) return type(o) == "table" end,
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
    in_main_menu = function() return W.pawn == nil end,
    map_name = function() return "PersistentLevel" end,
    widget_lib = noop,
    has_pending_connection = function() return W.pending end,
    pending_connection_live = function() return W.pending end,
    delay = noop, every = noop,
}, { __index = function() return noop end })
package.loaded["sdc_ue"] = ue

local session = {
    VERSION = "0.7.1",
    state = { role = "standalone", remote = {}, remote_pcs = {}, join = { target = nil, started_at = 0, attempts = 0 } },
    world_reset_hooks = {}, ui_hooks = {},
    join = noop, disconnect = noop, host_on_next_load = noop, start_fresh_server = noop, request_respawn = noop,
    roster = function() return {} end,
}
package.loaded["sdc_session"] = session
package.loaded["sdc_widgets"] = { child = noop, first_text = noop, game_window_open = function() return false end }

-- the real sdc_persist (client side driven by the host's messages)
local handlers = {}
package.loaded["sdc_net"] = { on = function(k, f) handlers[k] = f end, send_to_host = function() return true end,
    send_to = noop }
package.loaded["sdc_poimarks"] = { install = noop, status = function() return "" end }

local log = require("sdc_log")
local cfg = require("sdc_config")
local i18n = require("sdc_i18n")
local persist = require("sdc_persist")
persist.install(session.state)
local UI = require("sdc_ui")
local JC = UI._jc
local T = i18n.T

local function tick() UI.join_cover_tick(); return UI.join_cover_model() end
local function vis(w) return w and w._vis end
-- a new connection as sdc_session.on_role_change makes it
local function connect()
    session.state.role = "client"
    session.state.client = { connected_at = NOW, host_name = nil }
    persist.tick()   -- sdc_persist binds its client state to this connection (no character yet)
end
local function leave()
    session.state.role = "standalone"
    session.state.client = nil
    W.pawn, W.pending, W.esc = nil, false, false
    W.pc = mkpc("PC_menu_" .. NOW, 3)
    tick()
end
local gen_n = 0
local function verdict(kind)
    gen_n = gen_n + 1
    local g = "g" .. gen_n
    if kind == "restore" then handlers.PSSET({ g, "", "", "", "inv" }) else handlers.PSFRESH({ g, "1" }) end
    return g
end

check(cfg.get("join_cover") == true, "join_cover defaults to on")
W.pc = mkpc("PC_menu", 3)
check(pcall(UI.build), "UI.build runs with the cover")
check(UI.jc_root ~= nil and UI.jc_note ~= nil and #UI.jc_steps == 4, "cover, note and four steps built")
check(UI.canvas._children[1] == UI.jc_root, "the cover is the canvas's first child (toast and panel draw above it)")
check(UI.canvas._children[3] == UI.toast_box, "the toast comes after the cover and its note")
check(vis(UI.jc_root) == 1 and vis(UI.jc_note) == 1, "built collapsed")

-- ---------------------------------------------------------------- 1. never for a host / single player
local m = tick()
check(not m.visible and m.stage == "off", "single player: no cover")
session.state.role = "host"
session.state.remote_pcs = { {} }
m = tick()
check(not m.visible and JC.s == nil, "host: no cover")
session.state.role = "standalone"
session.state.remote_pcs = {}

-- ---------------------------------------------------------------- 2. IP join, saved character
local lm = mark()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW, "10.0.0.5:7777", "ip"
m = tick()
check(JC.s ~= nil and m.stage == "arming" and not m.visible, "join asked, no attempt seen yet: armed, not shown")
check(logged("ui: join cover: armed (join asked; target 10.0.0.5:7777)", lm), "log: armed")
advance(0.25)
W.pending = true
m = tick()
check(m.visible and m.stage == "connect", "pending connection: connect stage shown")
check(m.text == "Подключение к хосту…" and m.title == "Подключение к миру друга", "connect: text / title (RU)")
check(m.hint == "Хост: 10.0.0.5:7777", "connect: the address as the hint: " .. m.hint)
check(m.steps[1].state == "now" and m.steps[2].state == "todo" and m.steps[4].text == "Вещи и место", "connect: steps")
check(m.key == "0 с · F7 — показать игру", "elapsed + key line: " .. m.key)
check(vis(UI.jc_root) == 0 and UI.jc_text._text == "Подключение к хосту…", "widgets show it (visible: takes the clicks)")
check(UI.jc_steps[1].dot._color ~= nil and UI.jc_hint._text == "Хост: 10.0.0.5:7777", "step dot coloured, hint text")
check(logged("ui: join cover: stage arming -> connect", lm), "log: stage change")

advance(1.5)
connect()
m = tick()
check(m.visible and m.stage == "connect" and m.text == "Подключение к хосту…",
    "role client (first packet sent), no answer yet: still the connection")
check(JC.s.conn == session.state.client, "the join became this connection")
check(m.steps[1].state == "now" and m.steps[2].state == "todo", "connection step still running")

-- the level change: widget refs dropped, the cover state kept
UI.forget_world("loadmap")
check(UI.jc_root == nil and UI.jc_note == nil and UI.jc_steps == nil and UI.jc_sig == nil, "forget_world drops the cover's refs")
W.pc = nil
advance(5.6)
m = tick()
check(m.stage == "load" and JC.s and not JC.s.finished, "the host's map loading (it answered): load, state kept")
check(JC.s.answered ~= nil and m.steps[1].state == "done" and m.steps[2].state == "now", "load: steps")
-- the host's world: a client's own controller; the frame loop builds the widget at once
W.pc = mkpc("PC_client", 2)
UI.frame_tick()
check(UI.widget ~= nil and UI.jc_root ~= nil and vis(UI.jc_root) == 0, "frame loop rebuilt the widget with the cover already on")
m = tick()
check(m.stage == "pawn" and m.text == "Ожидание вашего персонажа…" and m.hint:find("30 секунд", 1, true), "no own character: pawn")
check(m.steps[2].state == "done" and m.steps[3].state == "now", "pawn: steps")
session.state.client.host_name = "Alice"
m = tick()
check(m.title == "Мир игрока Alice", "title with the host's name: " .. m.title)
check(logged("stage load -> pawn", lm), "log: load -> pawn")

advance(19.3)
W.pawn = mkpawn()
m = tick()
check(m.stage == "verdict" and m.text == "Загрузка данных персонажа…", "own character, no answer yet: verdict")
verdict("restore")
m = tick()
check(m.stage == "restore" and m.text == "Восстановление персонажа…" and m.steps[4].state == "now", "saved character: restore")
advance(8)
m = tick()
check(m.stage == "restore" and not JC.s.finished, "still restoring until PSDONE")
local g = "g" .. gen_n
lm = mark()
handlers.PSDONE({ g, "12", "2" })
m = tick()
check(JC.s.finished == "done" and m.visible and m.stage == "done" and m.text == "Готово" and m.alpha == 1, "PSDONE: Ready")
check(m.steps[4].state == "done" and m.key == "", "Ready: every step done, no key line")
check(logged("ui: join cover: done at stage restore after", lm) and logged("the host restored the saved character", lm),
    "log: done")
advance(0.5)
UI.frame_tick()
check(UI.jc_root._alpha == 1 and vis(UI.jc_root) == 3, "settle: still opaque, clicks pass through (hit-test invisible)")
advance(0.8)    -- 1.3 s after done: half way through the fade
UI.frame_tick()
check(UI.jc_root._alpha and UI.jc_root._alpha > 0.4 and UI.jc_root._alpha < 0.6, "fading: " .. tostring(UI.jc_root._alpha))
advance(0.5)
UI.frame_tick()
m = UI.join_cover_model()
check(not m.visible and vis(UI.jc_root) == 1 and UI.jc_root._alpha == 1, "faded out: collapsed, opacity back to 1")

-- ---------------------------------------------------------------- 3. a respawn: no cover
W.pawn = nil
advance(3)
m = tick()
check(not m.visible and JC.s.finished == "done", "own character gone (death / respawn): no cover")
W.pawn = mkpawn()
m = tick()
check(not m.visible, "respawned: still none")

-- ---------------------------------------------------------------- 4. joined by console; timeout
leave()
lm = mark()
connect()
m = tick()
check(JC.s and not JC.s.finished and JC.s.why == "connected" and m.stage == "load", "joined without the panel: armed on the connection")
check(logged("ui: join cover: armed (connected", lm), "log: armed on the connection")
W.pc = mkpc("PC_client2", 2)
m = tick()
check(m.stage == "pawn", "pawn stage")
advance(59)
m = tick()
check(m.visible and m.stage == "pawn", "59 s: still covered")
advance(1.5)
m = tick()
check(JC.s.finished == "timeout" and not m.visible and m.note ~= nil, "60 s in the host's world: timeout, game shown")
check(m.note:find("F7", 1, true) and m.note:find("Отключиться", 1, true), "note names the key and Disconnect: " .. tostring(m.note))
check(vis(UI.jc_root) == 1 and vis(UI.jc_note) == 3 and UI.jc_note_text._text == m.note, "note widget on, cover off")
check(logged("ui: join cover: timeout at stage pawn", lm), "log: timeout")
W.pawn = mkpawn()
verdict("fresh")
m = tick()
check(m.note == nil and vis(UI.jc_note) == 1, "the character is ready: note off")
check(logged("ui: join cover: note taken off (the character is ready)", lm), "log: note off")

-- ---------------------------------------------------------------- 5. new character (sdc_progress applies it)
local applied_v = nil
package.loaded["sdc_progress"] = { set_verdict = function(v) applied_v = v end }
leave()
connect()
W.pc = mkpc("PC_client3", 2)
tick()
advance(20)
W.pawn = mkpawn()
local gf = verdict("fresh")
m = tick()
check(m.stage == "fresh" and m.text == "Подготовка нового персонажа…" and m.hint == "Вы впервые в этом мире: новый персонаж.",
    "new character, not set up yet: fresh")
advance(6)
persist.client_applied(gf, "fresh")
lm = mark()
m = tick()
check(JC.s.finished == "done" and m.text == "Готово", "set up here: Ready")
check(logged("a new character, set up here", lm), "log: fresh done")
package.loaded["sdc_progress"] = nil

-- no answer from the host's save module (older host): done after 15 s
leave()
connect()
tick()
W.pc = mkpc("PC_client4", 2)
W.pawn = mkpawn()
m = tick()
check(m.stage == "verdict", "character, no answer: verdict")
advance(15.5)
m = tick()
check(JC.s.finished == "done", "no answer in 15 s: shown anyway")
-- own character dead while covered
leave()
connect()
tick()
W.pc = mkpc("PC_client5", 2)
W.pawn = mkpawn()
tick()
W.pawn["PlayerDead?"] = true
m = tick()
check(JC.s.finished == "dead" and not m.visible, "own character dead: the game (death screen) is shown")

-- ---------------------------------------------------------------- 6. F7 / Esc
leave()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 1, "10.0.0.5:7777", "ip"
W.pending = true
m = tick()
check(m.visible and m.stage == "connect", "second IP join: connect")
lm = mark()
UI.on_menu_key()
m = UI.join_cover_model()
check(JC.s.finished == "key" and not m.visible and vis(UI.jc_root) == 1, "F7: cover hidden at once")
check(UI.open == true, "F7 still opens the panel")
UI.set_open(false)
check(logged("ui: join cover: hidden by F7 at stage connect", lm), "log: F7")
connect()
m = tick()
check(not m.visible and JC.s.finished == "key" and JC.s.conn == session.state.client, "the connection after a dismissed join: no cover")

leave()
connect()
W.pc = mkpc("PC_client6", 2)
m = tick()
check(m.visible and m.stage == "pawn", "pawn stage again")
lm = mark()
W.esc = true
UI.frame_tick()
m = UI.join_cover_model()
check(JC.s.finished == "key" and not m.visible and vis(UI.jc_root) == 1, "Esc: cover hidden")
check(logged("ui: join cover: hidden by Esc at stage pawn", lm), "log: Esc")
W.esc = false

-- ---------------------------------------------------------------- 7. cancel
leave()
lm = mark()
session.state.join.started_at, session.state.join.target = NOW + 2, "10.0.0.9:7777"
m = tick()
check(JC.s and m.stage == "arming" and not m.visible, "join asked, nothing running")
advance(3.5)
m = tick()
check(JC.s.finished == "cancel" and not m.visible, "no attempt in 3 s: cancelled, never shown")
check(logged("ui: join cover: cancel at stage arming", lm), "log: cancel")
-- the role still turns client later: a cover for that connection
connect()
m = tick()
check(JC.s.why == "connected" and m.visible and m.stage == "load", "connected after all: covered")

-- ---------------------------------------------------------------- 8. Steam
leave()
local sl_state = { state = "joining", detail = "Подключение к Alice через Steam..." }
package.loaded["sdc_steamlink"] = { status = function() return sl_state end }
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 3, "steam:76561190000000001", nil
m = tick()
check(m.visible and m.stage == "connect" and m.hint == "Подключение к Alice через Steam...", "Steam tunnel being built: its status as the hint")
local at0 = JC.s.at
advance(1.5)
sl_state = { state = "connected" }
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 4, "127.0.0.1:57517", "steam"
W.pending = true
m = tick()
check(JC.s.at == at0 and m.stage == "connect" and m.hint == "Подключение через Steam.", "join_tunnel's stamp: the same join: " .. m.hint)
package.loaded["sdc_steamlink"] = nil

-- ---------------------------------------------------------------- 9. off; reload mid-game; English
leave()
cfg.set("join_cover", false)
session.state.join.started_at = NOW + 5
W.pending = true
m = tick()
check((JC.s == nil or JC.s.finished) and not m.visible, "join_cover off: never armed")
cfg.set("join_cover", true)
leave()
session.state.join.started_at = NOW + 6
W.pending = true
tick()
check(JC.s and not JC.s.finished, "armed again with the setting on")
cfg.set("join_cover", false)
m = tick()
check(JC.s.finished == "off" and not m.visible, "turned off while shown: gone")
cfg.set("join_cover", true)
-- a mod reload while already playing: a fresh client state, a character alive
leave()
local before = JC.s
session.state.role = "client"
session.state.client = { connected_at = NOW }
W.pc = mkpc("PC_client7", 2)
W.pawn = mkpawn()
m = tick()
check(JC.s == before and not m.visible, "a character already there: not armed")
-- English
leave()
cfg.set("language", "en")
connect()
W.pc = mkpc("PC_client8", 2)
m = tick()
check(m.text == "Waiting for your character…" and m.title == "Joining a friend's world"
    and m.key == "0 s · F7 to show the game" and m.steps[3].text == "Character", "English texts: " .. m.text .. " | " .. m.key)
check(not (m.text .. m.hint .. m.title):find("[\208\209]"), "no Russian in English")
cfg.set("language", "auto")

-- ---------------------------------------------------------------- 11. failed joins: the error on the cover
-- (the session's message comes through sdc_log.join_sink instead of a toast)
local joins = {}
session.join = function(ip, port, auto) joins[#joins + 1] = { ip = ip, port = port, auto = auto } end
-- a notification either way: the mod's toast or the game's (toast_sink)
local game_got = {}
log.toast_sink = function(text) game_got[#game_got + 1] = { text = text } end
local function ntoasts() return #UI.toasts + #game_got end
local function toasted(pat)
    for _, l in ipairs({ UI.toasts, game_got }) do
        for _, t in ipairs(l) do if tostring(t.text):find(pat, 1, true) then return true end end
    end
    return false
end
UI.toasts, game_got = {}, {}
-- a wrong port: the role turns client, the world never loads, then the session's "no answer"
leave()
lm = mark()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 20, "10.0.0.5:7778", "ip"
log.say("connecting", "info", 6, "10.0.0.5:7778")
check(ntoasts() == 0, "'connecting' goes to the cover, not a toast")
W.pending = true
m = tick()
check(m.visible and m.stage == "connect" and m.hint == "Хост: 10.0.0.5:7778", "connect stage shows the address")
connect()
log.say("connected", "ok")
m = tick()
check(m.stage == "connect" and ntoasts() == 0, "'connected' while the cover shows the connection: no toast")
check(m.hint == "Хост: 10.0.0.5:7778", "no answer for a moment: the address")
-- the failed connection loads the menu again: its new controller (Authority) is not the host's world
W.pc = mkpc("PC_menu_again", 3)
m = tick()
check(m.stage == "connect", "a new menu controller is not the host's world: still the connection")
advance(6)
m = tick()
check(m.hint == "Хост 10.0.0.5:7778 пока не отвечает. Обычно ответ приходит за пару секунд.",
    "no answer for 5 s: the hint says so: " .. m.hint)
advance(14)
W.pending = false   -- the engine gave up (cancelled: no live attempt)
log.say("host_no_answer", "warn", 10, "10.0.0.5:7778")
leave()
m = UI.join_cover_model()
check(JC.s.finished == "failed" and m.visible and m.stage == "failed" and m.error, "no answer: the cover shows the error")
check(ntoasts() == 0, "no toast for it")
check(m.title == "Не удалось подключиться" and m.text == "Хост не отвечает", "title / reason: " .. m.title .. " | " .. m.text)
check(m.hint:find("10.0.0.5:7778", 1, true) and m.hint:find("UDP 7777", 1, true), "what to do, with the address: " .. m.hint)
check(m.steps[1].state == "fail" and m.steps[2].state == "todo", "no answer: the connection step failed")
check(m.key == "Esc или F7 — закрыть" and m.retry == true and m.close == true, "close line, both buttons: " .. m.key)
check(vis(UI.jc_root) == 0 and UI.jc_text._text == "Хост не отвечает", "widgets: visible (takes the clicks), the reason")
check(vis(UI.jc_btns) == 4 and vis(UI.jc_retry) == 0 and vis(UI.jc_close) == 0, "buttons shown")
check(UI.jc_bar._color ~= nil and UI.jc_steps[2].dot._color ~= nil, "bar and failed step coloured")
check(logged("ui: join cover: failed at stage connect", lm) and logged("(host_no_answer)", lm), "log: failed")
check(logged("[TOAST] The host did not answer at 10.0.0.5:7778", lm), "UE4SS.log still has the message")
-- a lower message after it does not replace it; it is not toasted either
log.say("connection_lost", "warn", 8)
m = UI.join_cover_model()
check(m.text == "Хост не отвечает" and ntoasts() == 0, "a later 'connection lost' keeps the reason, no toast")
-- the level change: rebuilt with the error still on
UI.forget_world("loadmap")
W.pc = mkpc("PC_menu_err", 3)
UI.frame_tick()
check(UI.jc_root ~= nil and vis(UI.jc_root) == 0 and UI.jc_text._text == "Хост не отвечает", "after the level change: rebuilt, still shown")
-- the Close button (polled by the cover itself, not by the panel's loop)
local close = UI.jc_recs and UI.jc_recs.close
check(close ~= nil and not (function() for _, b in ipairs(UI.buttons) do if b == close then return true end end end)(),
    "Close is the cover's own button (not in the panel's list)")
local hov, prs = true, true
rawset(close.w, "IsHovered", function() return hov end)
rawset(close.w, "IsPressed", function() return prs end)
UI.frame_tick()
prs = false
lm = mark()
UI.frame_tick()
m = UI.join_cover_model()
check(JC.s.finished == "closed" and not m.visible and vis(UI.jc_root) == 1, "Close: gone")
check(logged("ui: join cover: error closed (Close)", lm), "log: closed")

-- the order the other way: the cover saw the role go first ("left"), the message within 3 s
leave()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 21, "10.0.0.5:7778", "ip"
W.pending = true
tick()
connect()
tick()
leave()
check(JC.s.finished == "left", "the role went first: left")
advance(1)
log.say("host_no_answer", "warn", 10, "10.0.0.5:7778")
m = UI.join_cover_model()
check(JC.s.finished == "failed" and m.text == "Хост не отвечает" and ntoasts() == 0, "a message 1 s later still shows on it")
-- Esc closes it (below); first: the host answered, then the connection broke -> not "no answer"
JC.dismiss("test")
leave()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 25, "10.0.0.5:7777", "ip"
W.pending = true
tick()
connect()
tick()
UI.forget_world("loadmap")   -- the host's world starts loading: it answered
W.pc = mkpc("PC_menu_x", 3)
m = tick()
check(m.stage == "load" and JC.s.answered ~= nil, "answered: load")
log.say("host_no_answer", "warn", 10, "10.0.0.5:7777")
leave()
m = UI.join_cover_model()
check(m.text == "Связь с хостом прервалась" and m.title == "Соединение с хостом прервано",
    "it had answered: 'the connection broke', not 'no answer': " .. m.text)
check(m.steps[1].state == "done" and m.steps[2].state == "fail", "the world step failed")
UI.toasts, game_got = {}, {}
log.say("disconnected", "info")
check(ntoasts() == 0, "'you left' is not toasted over the error")
W.esc = false
UI.frame_tick()
W.esc = true
UI.frame_tick()
W.esc = false
check(JC.s.finished == "closed" and not UI.join_cover_model().visible, "Esc closes the error")

-- Try again: the same address
leave()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 22, "10.0.0.7:7777", "ip"
W.pending = true
tick()
connect()
tick()
log.say("host_no_answer", "warn", 10, "10.0.0.7:7777")
joins = {}
local retry = UI.jc_recs.retry
hov, prs = true, true
rawset(retry.w, "IsHovered", function() return hov end)
rawset(retry.w, "IsPressed", function() return prs end)
UI.frame_tick()
prs = false
UI.frame_tick()
check(#joins == 1 and joins[1].ip == "10.0.0.7" and joins[1].port == 7777 and joins[1].auto == false,
    "Try again joins the same address: " .. tostring(joins[1] and joins[1].ip))
check(JC.s.finished == "closed", "the error goes with it")

-- the automatic join: its countdown; its next attempt replaces the error
leave()
session.auto_join_next = function() return 23.6 end
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 23, "10.0.0.5:7778", "ip"
W.pending = true
tick()
connect()
tick()
log.say("host_no_answer", "warn", 10, "10.0.0.5:7778")
leave()
m = UI.join_cover_model()
check(m.key == "Автоподключение: новая попытка через 23 с · Esc — закрыть", "auto join: the next try: " .. m.key)
session.state.join.started_at = NOW + 24
W.pending = true
m = tick()
check(not JC.s.finished and m.stage == "connect" and m.visible, "the next attempt: the joining cover again")
session.auto_join_next = nil
W.pending = false

-- while playing: a kick (then its "connection lost") -> the error comes up by itself
leave()
connect()
W.pc = mkpc("PC_client_k", 2)
W.pawn = mkpawn()
JC.s = nil
tick()
check(JC.s == nil, "playing: no cover")
lm = mark()
log.say("admin_kicked_you", "warn", 12)
m = UI.join_cover_model()
check(JC.s and JC.s.late and m.visible and m.stage == "failed", "kicked while playing: the error shows")
check(m.title == "Соединение с хостом прервано" and m.text == "Хост выгнал вас из мира" and #m.steps == 0,
    "kick: title, reason, no steps: " .. m.title)
log.say("connection_lost", "warn", 8)
m = UI.join_cover_model()
check(m.text == "Хост выгнал вас из мира" and ntoasts() == 0, "the kick's 'connection lost' keeps the kick")
log.say("admin_banned_you", "warn", 12)
m = UI.join_cover_model()
check(m.text == "Вы забанены в этом мире" and m.retry == false and m.hint:find("Баны", 1, true), "banned: higher, no Try again")
UI.on_menu_key()
check(JC.s.finished == "closed" and UI.open == true, "the menu key closes it and opens the panel")
UI.set_open(false)

-- while playing: the host went to its main menu (sdc_session's HOSTMENU, 13.11)
-- -> the reason on the cover, above the leave's "connection lost"
log.TEXT.host_menu_you = log.TEXT.host_menu_you or { "The host went to the main menu.", "Хост вышел в главное меню." }
leave()
session.state.join.code, session.state.join.target, session.state.join.via = nil, "10.0.0.5:7777", "ip"
connect()
W.pc = mkpc("PC_client_hm", 2)
W.pawn = mkpawn()
JC.s = nil
tick()
UI.toasts, game_got = {}, {}
lm = mark()
log.say("host_menu_you", "warn", 12)
m = UI.join_cover_model()
check(JC.s and JC.s.late and m.visible and m.stage == "failed", "host in its main menu while playing: the error shows")
check(m.title == "Соединение с хостом прервано" and m.text == "Хост вышел в главное меню" and #m.steps == 0,
    "host menu: title, reason, no steps: " .. m.title .. " | " .. m.text)
check(m.hint:find("загрузит сохранение", 1, true) ~= nil and m.retry == true and m.close == true,
    "host menu: what to do, Try again and Close: " .. m.hint)
check(ntoasts() == 0 and logged("(host_menu_you)", lm), "host menu: no toast, logged")
log.say("connection_lost", "warn", 8)
log.say("sl_tunnel_lost", "warn", 10)
m = UI.join_cover_model()
check(m.text == "Хост вышел в главное меню" and ntoasts() == 0, "the leave's 'connection lost' / 'tunnel lost' keep the reason")
check(JC.on_say("disconnected", "x") == true, "the leave's 'disconnected': not toasted while the reason shows")
cfg.set("language", "en")
m = UI.join_cover_model()
check(m.title == "Disconnected from the host" and m.text == "The host went to the main menu"
    and m.hint:find("loaded a save", 1, true) ~= nil and not (m.title .. m.text .. m.hint):find("[89]"),
    "host menu in English: " .. m.text .. " | " .. m.hint)
cfg.set("language", "auto")
JC.dismiss("test")
UI.toasts, game_got = {}, {}

-- banned while joining (the host refused the early id): no steps, no Try again
JC.dismiss("test")
leave()
session.state.join.started_at, session.state.join.target, session.state.join.via = NOW + 26, "10.0.0.5:7777", "ip"
W.pending = true
tick()
connect()
UI.forget_world("loadmap")
W.pc = mkpc("PC_client_b", 2)
W.pending = false
m = tick()
check(m.stage == "pawn", "in the host's world, no character")
log.say("admin_banned_you", "warn", 12)
m = UI.join_cover_model()
check(m.title == "Не удалось подключиться" and m.text == "Вы забанены в этом мире" and #m.steps == 0 and not m.retry,
    "banned at the join: title, reason, no steps, no Try again: " .. m.title)
JC.dismiss("test")
-- a host: its messages are toasts as before; a message the cover does not know: a toast
leave()
session.state.role = "host"
log.say("connection_lost", "warn", 8)
check(toasted("Соединение с хостом потеряно"), "host: not taken by the cover")
session.state.role = "standalone"
UI.toasts, game_got = {}, {}
log.say("settings_saved", "ok")
check(ntoasts() == 1, "other messages: toasts as before")
-- progress outside a cover: a toast
UI.toasts, game_got = {}, {}
JC.s = nil
log.say("connected", "ok")
check(ntoasts() == 1, "'connected' with no cover: a toast")
-- cover off: everything a toast
cfg.set("join_cover", false)
UI.toasts, game_got = {}, {}
log.say("host_no_answer", "warn", 10, "1.2.3.4:7777")
check(ntoasts() == 1 and JC.s == nil, "join_cover off: the toast")
cfg.set("join_cover", true)
-- English
cfg.set("language", "en")
leave()
log.say("connection_lost", "warn", 8)
m = UI.join_cover_model()
check(m.title == "Disconnected from the host" and m.text == "Lost the connection to the host" and m.key == "Esc or F7 to close",
    "English: " .. m.title .. " | " .. m.text .. " | " .. m.key)
check(not (m.title .. m.text .. m.hint .. m.key):find("[\208\209]"), "no Russian in English")
cfg.set("language", "auto")
JC.dismiss("test")
UI.toasts, game_got = {}, {}
local errkeys = { "jc_err_title", "jc_err_title_left", "jc_err_close", "jc_err_retry_in", "jc_btn_retry", "jc_btn_close" }
for _, e in pairs(JC.FAIL) do
    if e.text then errkeys[#errkeys + 1] = e.text end
    if e.hint then errkeys[#errkeys + 1] = e.hint end
end
local miss2 = {}
for _, k in ipairs(errkeys) do if not (i18n.STR.ru[k] and i18n.STR.en[k]) then miss2[#miss2 + 1] = k end end
check(#miss2 == 0, "every error string in RU and EN: " .. table.concat(miss2, ","))
check(log.TEXT.host_no_answer and log.TEXT.host_no_answer_steam, "the session's new messages are in the catalog")

-- ---------------------------------------------------------------- 10. setting, strings, persist accessor
local row = i18n.schema_row("join_cover")
check(row and row[2] == "bool" and row[3] == true, "SCHEMA: join_cover bool true")
check(type(i18n.DESC_EN.join_cover) == "string" and i18n.LABEL.join_cover ~= nil and i18n.GROUP_OF.join_cover == "connect",
    "EN description, label, group")
local keys = { "jc_title", "jc_title_host", "jc_hint_ip", "jc_hint_steam", "jc_key", "jc_note" }
for _, k in ipairs(JC.STEPS) do keys[#keys + 1] = k end
for _, k in pairs(JC.TEXT) do keys[#keys + 1] = k end
for _, k in pairs(JC.HINT) do keys[#keys + 1] = k end
local missing = {}
for _, k in ipairs(keys) do
    if not (i18n.STR.ru[k] and i18n.STR.en[k]) then missing[#missing + 1] = k end
end
check(#missing == 0, "every cover string in RU and EN: " .. table.concat(missing, ","))
session.state.role = "host"
check(next(persist.client_join_state()) == nil, "persist: a host has no join state")
session.state.role = "client"
session.state.client = { connected_at = NOW }
persist.tick()
check(persist.client_join_state().verdict == nil, "persist: new connection: no verdict")
local gr = verdict("restore")
local js = persist.client_join_state()
check(js.verdict == "restore" and js.applied == true and js.done == false, "persist: PSSET -> restore, applied, not done")
handlers.PSDONE({ gr, "3", "4" })
check(persist.client_join_state().done == true, "persist: PSDONE -> done")
session.state.client = { connected_at = NOW }
check(next(persist.client_join_state()) == nil, "persist: another connection: nothing until its own tick")

io.write(nchecks, " checks, ", fails == 0 and "ALL OK" or (fails .. " FAILED"), "\n")
