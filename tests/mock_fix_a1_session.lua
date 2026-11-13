-- Mock test (critic fixes 2026-11-13, group A1): sdc_session / sdc_steamlink.
--   A1: dead in a single-player world, "open my world" never reloads without a save;
--   A2: a world loaded by hand during the reopen's menu step ends the reopen;
--   A4: a dead host is still in its world: no join (session.join, join_tunnel,
--       steamlink.join), a Steam invite waits for the real main menu;
--   A8: a Steam code without the Steam link helper says why (no "open steam.<id>");
--   A9: the HI of a banned player (sdc_admin.on_hello true) is not announced;
--   A10: the level hooks run in a pcall and return nothing.
-- usage: lua mock_fix_a1_session.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end

-- every other sdc_ module: an automatic stub (any field is a function returning nil)
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_session = true, sdc_log = true, sdc_config = true, sdc_steam = true, sdc_steamlink = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
local HOOKS = {}
RegisterHook = function(path, fn) HOOKS[path] = fn; return 1, 2 end
-- no LOCALAPPDATA: becoming host must not copy the real saves of this PC
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end
local real_execute = os.execute
os.execute = function(cmd)
    error("test tried to run a command: " .. tostring(cmd))
end

local NOW = 5000
os.time = function() return NOW end

-- the world
local W = { role = "standalone", menu = false, pawn = { ["PlayerDead?"] = false }, menu_widget = nil,
            map = "PersistentLevel", pc = { key = "pc1" } }
local execs, handlers, broadcasts, sent = {}, {}, {}, {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end
net.broadcast = function(pcs, kind, ...) broadcasts[#broadcasts + 1] = { kind = kind, f = { ... } } end
package.loaded["sdc_net"] = net
local netdiag = stub()
netdiag.switched = 0
netdiag.switch_to_ip = function() netdiag.switched = netdiag.switched + 1; netdiag.ip_fallback = true; return true end
netdiag.ip_fallback = false
package.loaded["sdc_netdiag"] = netdiag
local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.net_role = function() return W.role end
ue.in_main_menu = function() return W.menu end
ue.local_pawn = function() return W.pawn end
ue.local_pc = function() return W.pc end
ue.map_name = function() return W.map end
ue.world_path = function() return "/Game/Levels/PersistentLevel" end
ue.has_pending_connection = function() return false end
ue.exec = function(cmd) execs[#execs + 1] = cmd end
ue.ems_current_slot = function() return "MySlot" end
ue.find_first = function() return nil end
ue.find_object = function() return nil end
ue.find_all = function() return {} end
ue.sub_time = function(_, fn, ...) return pcall(fn, ...) end
ue.delay = function() return false end
ue.game_thread = function() end
ue.exec_in_progress = false
package.loaded["sdc_ue"] = ue
package.loaded["sdc_lobby"] = { live_main_menu = function() return W.menu_widget end }
local SAVE = { calls = 0, done = nil }
package.loaded["sdc_savecheck"] = { save_now = function(_, done) SAVE.calls = SAVE.calls + 1; SAVE.done = done end }

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, ...) said[#said + 1] = key; return real_say(key, ...) end
local function was_said(key) for _, k in ipairs(said) do if k == key then return true end end return false end
local errs = {}
log.err_throttled = function(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end

local cfg = require("sdc_config")
cfg.values.listen_on_load = false
cfg.values.auto_join = false
cfg.save = function() return true end   -- the test never writes a config file
local session = require("sdc_session")
session.register_handlers()
local sl = require("sdc_steamlink")
local L = sl._L
L.S = session.state
L.dir = "Z:/sdcoop_no_such_dir"       -- no helper files: nothing is read or written
L.starts = 3                          -- never starts the helper
local function tick(n)
    for _ = 1, n or 1 do NOW = NOW + 1; session.tick() end
end
local function reset_io() execs, said, broadcasts, sent = {}, {}, {}, {} end

print("A1: dead in a single-player world")
tick(2)   -- alive in the world: this controller had a character
W.menu, W.pawn = true, nil   -- dead: no own character (ue.in_main_menu() is true now)
tick(1)
check(session.in_real_menu() == false, "dead in the world: not the real main menu")
reset_io()
session.host_on_next_load()
check(#execs == 0 and SAVE.calls == 0, "no reload, no save")
check(was_said("reopen_need_alive"), "says: respawn first")
check(session.reopen_state() == nil, "nothing started")
W.menu_widget = { key = "MenuWidget_C_0" }
check(session.in_real_menu() == true, "the main menu widget on screen: the real menu")
W.menu_widget = nil
print("A1: the real main menu (the game loaded the level again: a new controller)")
W.pc = { key = "pc2" }
tick(1)
check(session.in_real_menu() == true, "a new controller without a character: the real main menu")
reset_io()
netdiag.switched, netdiag.ip_fallback = 0, false
session.host_on_next_load()
check(execs[1] == "open /Game/Levels/PersistentLevel?listen" and SAVE.calls == 0, "the menu reopens as a listen server")
check(netdiag.switched == 1, "through the plain IP net driver (no steam_p2p / host_by_ip any more)")

print("A2: the save loaded by hand while the reopen waits in the menu step")
cfg.values.listen_on_load = false
W.pc, W.menu, W.pawn, W.role = { key = "pc3" }, false, { ["PlayerDead?"] = false }, "standalone"
tick(1)
reset_io()
check(session.open_world_now() == true and session.reopen_state().step == "save", "reopen started")
SAVE.done(true, nil, "MySlot")
check(session.reopen_state().step == "menu", "saved: the menu step")
W.pc, W.menu, W.pawn, W.role = { key = "pc4" }, true, nil, "host"   -- the reopened world listens
tick(2)
check(session.reopen_state() and session.reopen_state().step == "menu", "no menu widget yet: waits")
W.menu, W.pawn = false, { ["PlayerDead?"] = false }                  -- the player pressed Continue itself
tick(1)
check(session.reopen_state() == nil and was_said("reopen_done"), "loaded by hand: done, says so")
tick(80)
check(not was_said("reopen_continue_hand"), "no 'press Continue' message later")

print("A4: a dead host is still in its world")
W.role, W.menu, W.pawn, W.pc = "host", false, { ["PlayerDead?"] = false }, { key = "hpc" }
tick(2)
W.menu, W.pawn = true, nil
tick(1)
reset_io()
session.join("10.0.0.5", 7777)
check(#execs == 0 and was_said("host_cannot_join"), "session.join refused")
check(session.join_tunnel(50123, "76561190000000300") == false and #execs == 0, "join_tunnel refused")
L.enabled, L.exe_found = true, true
local ok, _, key = sl.join("76561190000000300")
check(not ok and key == "host_cannot_join", "steamlink.join refused (" .. tostring(key) .. ")")
W.pc = { key = "hpc2" }   -- the real main menu (still listening)
tick(1)
reset_io()
session.join("10.0.0.5", 7777)
check(execs[1] == "open 10.0.0.5:7777", "from the real main menu: joins")

print("A4: a Steam invite while dead in a single-player world waits for the real main menu")
W.role, W.menu, W.pawn, W.pc = "standalone", false, { ["PlayerDead?"] = false }, { key = "spc" }
tick(2)
W.menu, W.pawn = true, nil
tick(1)
L.join, L.pending_invite = nil, { sid = "76561190000000300", until_t = NOW + 300 }
reset_io()
sl.tick()
check(L.pending_invite ~= nil and L.join == nil and #execs == 0, "dead: the invite waits, nothing joined")
W.pc = { key = "spc2" }
tick(1)
sl.tick()
check(L.pending_invite == nil and L.join and L.join.sid == "76561190000000300", "real main menu: the join starts")
L.join = nil

print("A8: a Steam code without the Steam link helper")
W.role, W.menu, W.pawn, W.pc = "standalone", true, nil, { key = "mpc" }
tick(1)
L.enabled, L.exe_found = false, false
reset_io()
session.join("76561190000000300", 7777)
check(#execs == 0 and was_said("sl_st_off"), "helper off by config: says so, no 'open steam.<id>'")
L.enabled = true
reset_io()
session.join("76561190000000300", 7777)
check(#execs == 0 and was_said("sl_no_helper"), "helper missing: says so")
L.enabled = false

print("A9: the HI of a banned player")
W.role, W.menu, W.pawn, W.pc = "host", false, { ["PlayerDead?"] = false }, { key = "hostpc" }
tick(1)
package.loaded["sdc_admin"] = { on_hello = function() return true end }
reset_io()
local bob = { key = "bobpc" }
handlers.HI({ session.VERSION, "Bob" }, bob)
check(not was_said("player_joined") and #broadcasts == 0, "banned: no join announcement")
local acked = false
for _, m in ipairs(sent) do if m.kind == "HELLO" and m.f[3] == "ack" then acked = true end end
check(acked, "the handshake is still acknowledged")
package.loaded["sdc_admin"] = { on_hello = function() return false end }
reset_io()
handlers.HI({ session.VERSION, "Ann" }, { key = "annpc" })
check(was_said("player_joined"), "not banned: announced as before")
package.loaded["sdc_admin"] = nil

print("A10: the level hooks")
session.install_level_hooks()
local h = HOOKS["/Script/Engine.GameplayStatics:OpenLevel"]
check(type(h) == "function", "OpenLevel hooked")
local bad = { get = function() error("stale param") end }
errs = {}
local okc, r = pcall(h, nil, nil, bad, nil, bad)
check(okc and r == nil and #errs == 1, "an error inside the hook stays inside it (logged, nothing returned)")
cfg.values.listen_on_load, cfg.values.auto_join = true, false
W.role = "standalone"
local opts = { v = "", get = function(s) return s.v end, set = function(s, x) s.v = x end }
local okc2, r2 = pcall(h, nil, nil, { get = function() return "LongdownValley" end }, nil, opts)
check(okc2 and r2 == nil and opts.v == "listen", "the hook still appends ?listen")
cfg.values.listen_on_load = false

os.execute = real_execute
print = real_print
print(string.format("fix_a1_session: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
