-- Mock harness: friendly fire on the co-op panel's World tab (sdc_ui + the
-- real sdc_admin / sdc_i18n / sdc_config / sdc_log; stub UMG widgets,
-- engine and session; the harness of mock_access_ui.lua).
--   1. the World tab's rules: client_cheats and friendly_fire with its caption
--   2. the friendly_fire box is its only copy (its «Все функции» group is
--      built when opened): a click applies and saves at once, the host gets
--      a notice; client_cheats as before
--   2b. a click the 4 Hz poll has not seen yet is not lost: the panel closed
--      (F7) or another tab picked right after it applies it first
--   3. the «Бой» group opened: a second copy follows the World tab's box
--   4. English
-- usage: lua mock_ffire_ui.lua <scripts dir>
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

local function find_text(s)
    for _, w in ipairs(created) do if w._text == s then return w end end
    return nil
end

-- ---------------------------------------------------------------- 1. the rules
W.pc = mkpc("PC_world", 3)
local okb, errb = pcall(UI.build)
check(okb, "UI.build runs: " .. tostring(errb))
session.state.role = "host"
UI.set_open(true)
UI.pick_tab("world")
UI.refresh_world()
check(UI.open and UI.tab == "world" and vis(UI.world_host), "the host's World tab")
check(find_text("Правила мира") ~= nil, "a «Правила мира» heading")
check(UI.world_cheats ~= nil and UI.world_ff ~= nil and UI.world_checks.client_cheats == UI.world_cheats
    and UI.world_checks.friendly_fire == UI.world_ff, "client_cheats and friendly_fire boxes on the World tab")
check(UI.world_ff._checked == false and (find_text("Огонь по своим") ~= nil), "«Огонь по своим», off by default")
check(find_text("Выкл.: игроки не ранят друг друга. Зомби, падение, ловушки и своя граната ранят как обычно.") ~= nil,
    "its caption says what off means")
check(UI.world_ff._tip and UI.world_ff._tip:find("Хост: огонь по своим", 1, true) ~= nil, "its tooltip: the full description")
check(#UI.checks.friendly_fire == 1 and #UI.checks.client_cheats >= 2,
    "friendly_fire: its only copy so far (its group not built); client_cheats: a copy of «Основное»")

-- ---------------------------------------------------------------- 2. a click
UI.slow_tick()          -- its first run follows the world (in a world: the panel closes)
UI.set_open(true)
UI.pick_tab("world")
saves = 0
local n_got = #game_got
UI.world_ff._checked = true
UI.slow_tick()
check(cfg.get("friendly_fire") == true and saves >= 1, "a click: friendly_fire on, saved at once")
check(logged("ui: world: friendly_fire = true (saved: true)") ~= nil, "log line")
check(#game_got > n_got and game_got[#game_got] == "Огонь по своим включён: игроки могут ранить друг друга.",
    "the host's notice: " .. tostring(game_got[#game_got]))
saves = 0
UI.world_ff._checked = false
UI.slow_tick()
check(cfg.get("friendly_fire") == false and saves >= 1 and game_got[#game_got] == "Огонь по своим выключен: игроки не ранят друг друга.",
    "and off again: saved, «Огонь по своим выключен»")
saves = 0
UI.slow_tick()
check(saves == 0, "no click: nothing saved")
-- client_cheats as before
cfg.set("client_cheats", true)
UI.set_open(true)
UI.pick_tab("world")
UI.world_cheats._checked = false
UI.slow_tick()
local all_off = true
for _, cb in ipairs(UI.checks.client_cheats) do if cb._checked then all_off = false end end
check(cfg.get("client_cheats") == false and all_off, "client_cheats: set, saved, its other copies follow")
cfg.set("client_cheats", true)

-- ---------------------------------------------------------------- 2b. a click right before F7 / another tab
UI.set_open(true)
UI.pick_tab("world")
UI.slow_tick()
saves = 0
n_got = #game_got
UI.world_ff._checked = true           -- ticked, then F7 within 250 ms: no poll in between
UI.set_open(false)
check(cfg.get("friendly_fire") == true and saves >= 1, "a click then F7 at once: friendly_fire on, saved")
check(#game_got == n_got + 1 and game_got[#game_got] == "Огонь по своим включён: игроки могут ранить друг друга.",
    "  the host's notice (RULES|ff follows the saved value)")
UI.set_open(true)
check(UI.world_ff._checked == true, "  opened again: the box shows it (not reset from an old cfg)")
saves = 0
UI.world_ff._checked = false          -- unticked, then another tab within 250 ms, later F7
UI.pick_tab("ip")
check(cfg.get("friendly_fire") == false and saves >= 1, "a click then another tab at once: friendly_fire off, saved")
UI.set_open(false)
UI.set_open(true)
check(UI.world_ff._checked == false, "  closed and opened again: still off")
cfg.set("client_cheats", true)
UI.pick_tab("world")
UI.world_cheats._checked = false      -- client_cheats shares the path
UI.set_open(false)
check(cfg.get("client_cheats") == false, "client_cheats: a click then F7 at once, applied")
cfg.set("client_cheats", true)
UI.set_open(true)
saves = 0
UI.pick_tab("char")
UI.set_open(false)
check(saves == 0, "no click: closing / another tab saves nothing")

-- ---------------------------------------------------------------- 3. the «Бой» group
UI.set_open(true)
-- «Все функции мода», then its «Бой» group (each built when opened)
for _, name in ipairs({ "all", "group combat" }) do
    for _, sec in ipairs(UI.sections) do
        if sec.name == name then pcall(UI.toggle_section, sec, true) end
    end
end
check(#UI.checks.friendly_fire == 2, "the «Бой» group opened: a second copy (" .. #UI.checks.friendly_fire .. ")")
UI.pick_tab("settings")
saves = 0
local grp = UI.checks.friendly_fire[2]
grp._checked = true
UI.slow_tick()
check(UI.world_ff._checked == true and saves == 0, "a click on the group's copy: the World tab's box follows (saved with Save)")
grp._checked = false
UI.slow_tick()
check(UI.world_ff._checked == false, "and back")

-- ---------------------------------------------------------------- 4. English
i18n.set("en")
UI.pick_tab("world")
check(find_text("World rules") ~= nil and find_text("Friendly fire") ~= nil
    and find_text("Off: players can't hurt each other. Zombies, falls, traps and your own grenade hurt as usual.") ~= nil,
    "English: the heading, the box and the caption")
UI.world_ff._checked = true
UI.slow_tick()
check(game_got[#game_got] == "Friendly fire is on: players can hurt each other.", "English notice: " .. tostring(game_got[#game_got]))
cfg.set("friendly_fire", false)
check(#errors == 0, "no log errors: " .. table.concat(errors, " | "))

io.write(nchecks, " checks, ", fails == 0 and "ALL OK" or (fails .. " FAILED"), "\n")
os.exit(fails == 0 and 0 or 1)
