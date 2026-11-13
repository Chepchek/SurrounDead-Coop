-- Mock test: the host quits to its main menu with players connected
-- (13.11 19:00). The pause / respawn screen's "Quit to main menu" only
-- streams the menu level into the same listening world: the clients stayed
-- connected, falling in a world without ground, the menu over their HUD.
-- Now (sdc_session.host_menu_tick): once the host's real main menu is up
-- (its MenuWidget on screen), every player connected since before the host
-- left its world gets HOSTMENU once; its mod leaves at once (the game's
-- disconnect) and says host_menu_you (the join cover); one still connected
-- 5 s later (an older mod) gets the engine's own return to the menu. The
-- dead host (respawn screen: the same world) keeps everyone; a player who
-- joins the host's menu afterwards is not sent away. "Connected before" is
-- counted from the real menu's first tick, not from the host's death: a
-- friend who joined the dead host is told when it quits from the respawn
-- screen (13.11 review).
-- usage: lua mock_host_menu.lua <scripts dir>
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
local REAL = { sdc_session = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return { text = s } end
RegisterHook = function() return 1, 2 end
-- no LOCALAPPDATA: becoming host must not copy the real saves of this PC
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end
local real_execute = os.execute
os.execute = function(cmd)
    if tostring(cmd):find("robocopy", 1, true) then error("test tried to run robocopy: " .. tostring(cmd)) end
    return real_execute(cmd)
end
-- the pak folder listing (a connection begins): nothing
io.popen = function() return nil end

local NOW = 7000
os.time = function() return NOW end

-- the world: the host's own controller stays the same through death and the
-- quit to the menu (one world); menu = ue.in_main_menu(); menu_widget = the
-- MenuWidget on screen (sdc_lobby.live_main_menu)
local W = { role = "host", menu = false, pawn = { ["PlayerDead?"] = false }, menu_widget = nil, map = "PersistentLevel",
            pc = { key = "BP_PlayerController_C_1" }, pcs = {} }
local execs, sent, returned, errors = {}, {}, {}, {}
local handlers = {}
local net = stub()
net.on = function(k, f) handlers[k] = f end
net.send_to = function(pc, kind) sent[#sent + 1] = { pc = pc.key, kind = kind } end
net.broadcast = function() end
package.loaded["sdc_net"] = net
local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.net_role = function() return W.role end
ue.in_main_menu = function() return W.menu end
ue.local_pawn = function() return W.pawn end
ue.local_pc = function() return W.pc end
ue.map_name = function() return W.map end
ue.has_pending_connection = function() return false end
ue.exec = function(cmd) execs[#execs + 1] = cmd end
ue.find_all = function(cls) if cls == "PlayerController" then return W.pcs end return {} end
ue.sub_time = function(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then errors[#errors + 1] = label .. ": " .. tostring(err) end
    return ok
end
ue.delay = function() return false end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_lobby"] = { live_main_menu = function() return W.menu_widget end }

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, ...) said[#said + 1] = key; return real_say(key, ...) end
local function was_said(key) for _, k in ipairs(said) do if k == key then return true end end return false end

local cfg = require("sdc_config")
cfg.set("listen_on_load", false)
local session = require("sdc_session")
session.register_handlers()
local st = session.state
local function tick(n)
    for _ = 1, n or 1 do NOW = NOW + 1; session.tick() end
end
-- a remote player's controller (the engine: a NetConnection)
local function player(key)
    local pc = { key = key, NetConnection = {}, returns = 0 }
    pc.ClientReturnToMainMenuWithTextReason = function(self, why)
        self.returns = self.returns + 1
        returned[#returned + 1] = { pc = self.key, why = why }
    end
    return pc
end
local function gone(pc)
    for i, p in ipairs(W.pcs) do if p == pc then table.remove(W.pcs, i); return end end
end
local function hostmenus(key)
    local n = 0
    for _, s in ipairs(sent) do if s.kind == "HOSTMENU" and (not key or s.pc == key) then n = n + 1 end end
    return n
end

check(type(handlers.HOSTMENU) == "function", "the client's HOSTMENU handler is registered")

print = real_print
print("host: in its world with two players")
print = function() end
local A, B = player("PC_A"), player("PC_B")
W.pcs = { A }
tick(2)
W.pcs[2] = B
tick(3)
check(st.role == "host" and st.remote.PC_A and st.remote.PC_B, "both players have records")
check(hostmenus() == 0, "in the world: no HOSTMENU")

print = real_print
print("the host dies (respawn screen: the same world, no MenuWidget)")
print = function() end
W.menu, W.pawn = true, nil
tick(12)
check(hostmenus() == 0 and #returned == 0, "dead host: nobody is sent away (12 s)")
W.menu, W.pawn = false, { ["PlayerDead?"] = false }
tick(2)
check(hostmenus() == 0, "respawned: nothing")

print = real_print
print("the host quits to its main menu")
print = function() end
W.menu, W.pawn = true, nil
tick(2)
check(hostmenus() == 0, "the menu level is still loading (no MenuWidget yet): nobody sent away yet")
W.menu_widget = { key = "MenuWidget_C_9" }
tick(1)
check(hostmenus("PC_A") == 1 and hostmenus("PC_B") == 1, "the real main menu: HOSTMENU to both players")
local C = player("PC_C")   -- joins the host's main menu (waits there for its next world)
W.pcs[#W.pcs + 1] = C
gone(A)                    -- A's mod leaves at once
tick(2)
check(hostmenus("PC_A") == 1 and hostmenus("PC_B") == 1, "told once each, not again")
check(hostmenus("PC_C") == 0, "a player who joined the host's menu is not sent away")
check(#returned == 0, "no engine return before 5 s")
tick(3)
check(B.returns == 1 and #returned == 1 and type(returned[1].why) == "table"
    and returned[1].why.text == "The host went to the main menu",
    "B still connected 5 s later (an older mod): the engine's return to the menu, once")
check(C.returns == 0, "not for the player who joined the menu")
tick(10)
check(B.returns == 1 and hostmenus() == 2, "no repeats")
check(#errors == 0, "no errors in the host's tick parts: " .. table.concat(errors, "; "))

print = real_print
print("back in a world, then out to the menu again")
print = function() end
gone(B)
W.menu, W.pawn, W.menu_widget = false, { ["PlayerDead?"] = false }, nil
tick(3)
check(hostmenus("PC_C") == 0, "in the world: C stays")
W.menu, W.pawn = true, nil
W.menu_widget = { key = "MenuWidget_C_10" }
tick(2)
check(hostmenus("PC_C") == 1, "the next quit to the menu: C (in that world since before) is told")

print = real_print
print("a friend joins the dead host, who then quits from the respawn screen")
print = function() end
gone(C)
W.menu, W.pawn, W.menu_widget = false, { ["PlayerDead?"] = false }, nil
tick(3)
local D = player("PC_D")
W.pcs = { D }
tick(2)
W.menu, W.pawn = true, nil          -- the host dies
tick(5)
local E = player("PC_E")             -- joins the dead host (the Steam hosting is kept for that)
W.pcs[#W.pcs + 1] = E
tick(5)
check(hostmenus("PC_D") == 0 and hostmenus("PC_E") == 0, "the host lies dead: nobody is sent away")
W.menu_widget = { key = "MenuWidget_C_11" }   -- "Quit to main menu" on the respawn screen
tick(1)
check(hostmenus("PC_D") == 1, "the real main menu: D (in the world before the death) is told")
check(hostmenus("PC_E") == 1, "E, who joined while the host lay dead, is told too")
local F = player("PC_F")             -- joins the host's main menu
W.pcs[#W.pcs + 1] = F
tick(2)
check(hostmenus("PC_F") == 0, "F, who joined the host's main menu, is not sent away")

print = real_print
print("the host's menu with nobody connected, its MenuWidget hidden a while")
print = function() end
W.pcs = {}
W.menu, W.pawn, W.menu_widget = false, { ["PlayerDead?"] = false }, nil
tick(3)
W.menu, W.pawn = true, nil
W.menu_widget = { key = "MenuWidget_C_12" }
tick(2)
W.menu_widget = nil                  -- e.g. the load screen over the menu
local G = player("PC_G")
W.pcs = { G }
tick(2)
W.menu_widget = { key = "MenuWidget_C_12" }
tick(3)
check(hostmenus("PC_G") == 0, "G, who joined the menu while its MenuWidget was hidden, is not sent away")

print = real_print
print("a player recorded in the very tick the real menu is first seen")
print = function() end
W.pcs = {}
W.menu, W.pawn, W.menu_widget = false, { ["PlayerDead?"] = false }, nil
tick(3)
local H = player("PC_H")
W.pcs = { H }
W.menu, W.pawn = true, nil
W.menu_widget = { key = "MenuWidget_C_13" }
tick(1)
check(hostmenus("PC_H") == 1, "recorded with the menu (a world reset records everyone anew): told")
check(#errors == 0, "no errors in the host's tick parts: " .. table.concat(errors, "; "))

print = real_print
print("client: HOSTMENU from the host")
print = function() end
W.pcs = {}
W.role, W.menu, W.pawn, W.menu_widget = "client", false, { ["PlayerDead?"] = false }, nil
W.pc = { key = "BP_PlayerController_C_77" }
tick(2)
check(st.role == "client" and type(st.client) == "table", "a client now")
execs, said = {}, {}
handlers.HOSTMENU({}, W.pc)
local disc = 0
for _, c in ipairs(execs) do if c == "disconnect" then disc = disc + 1 end end
check(was_said("host_menu_you") and disc == 1 and st.disconnect_requested == true,
    "leaves at once (the game's disconnect) and says why")
check(log.TEXT.host_menu_you and log.TEXT.host_menu_you[2] == "Хост вышел в главное меню."
    and log.TEXT.host_menu_you[1] == "The host went to the main menu.", "the message in RU and EN")
handlers.HOSTMENU({}, W.pc)
disc = 0
for _, c in ipairs(execs) do if c == "disconnect" then disc = disc + 1 end end
check(disc == 1, "a second HOSTMENU: no second disconnect")
said = {}
W.role, W.menu, W.pawn = "standalone", true, nil
tick(1)
check(was_said("disconnected") and not was_said("connection_lost"), "the leave: 'disconnected', not 'connection lost'")
check((st.join.attempts or 0) == 0, "the automatic join is not stopped (it finds the host's next world): attempts "
    .. tostring(st.join.attempts))

-- a host never leaves on a HOSTMENU (a stray message)
W.role, W.menu, W.pawn = "host", false, { ["PlayerDead?"] = false }
tick(1)
execs, said = {}, {}
handlers.HOSTMENU({}, W.pc)
check(#execs == 0 and not was_said("host_menu_you"), "host: HOSTMENU ignored")

print = real_print
print(string.format("host menu: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
