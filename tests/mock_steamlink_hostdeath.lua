-- Mock test: the host's Steam hosting survives the host's death.
-- 0.7.0: ue.in_main_menu() is true while the host is dead (no own character
-- on the menu map); sdc_steamlink withdrew the Steam hosting 8 s later and the
-- helper closed every Steam friend's tunnel. Now hosting stays on while the
-- world is the same (same local controller) or players are connected, and is
-- still withdrawn back in the real main menu (a new controller: there
-- sdc_session.in_real_menu is true).
-- 13.11: the pause screen's "Quit to main menu" keeps the same controller
-- (the menu level streams into the same world): kept as a "death", the
-- friend left falling in a world without ground. The real main menu
-- (sdc_session.in_real_menu: its MenuWidget on screen) withdraws it - at
-- once with nobody connected, after the 8 s grace while the players told to
-- leave (HOSTMENU) are still there.
-- usage: lua mock_steamlink_hostdeath.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/sl_hostdeath"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '\\steamlink" 2>nul')

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local nop = function() end
package.loaded["sdc_log"] = setmetatable({ debug_enabled = false }, { __index = function() return nop end })
package.loaded["sdc_ue"] = setmetatable({}, { __index = function() return nop end })
function RegisterHook() return 1, 2 end
function ExecuteInGameThread(f) f() end
function LoopInGameThreadWithDelay() return 1 end
function FindFirstOf() return nil end
function FindAllOf() return {} end
function StaticFindObject() return nil end

-- sdc_session.in_real_menu: false = the death / respawn screen of the world;
-- "error" = the check itself fails
local REAL_MENU = false
package.loaded["sdc_session"] = { in_real_menu = function()
    if REAL_MENU == "error" then error("in_real_menu failed (test)") end
    return REAL_MENU
end }

local cfg = require("sdc_config")
local ini = TMP .. "/config.ini"
os.remove(ini)
cfg.load(ini)
local sl = require("sdc_steamlink")
local L = sl._L
L.dir = TMP .. "/steamlink"
-- a session of its own: a suite run at the same time (this _tmp folder is
-- shared) must not read and delete this run's commands
L.session = string.format("7%06d", math.random(0, 999999))

-- commands the helper would read
local function cmds()
    local out = {}
    local p = io.popen('dir /b /on "' .. L.dir:gsub("/", "\\") .. '\\cmd_' .. L.session .. '_*.txt" 2>nul')
    for name in p:lines() do
        local f = io.open(L.dir .. "/" .. name, "rb")
        if f then out[#out + 1] = (f:read("a") or ""):gsub("%s+$", ""); f:close() end
        os.remove(L.dir .. "/" .. name)
    end
    p:close()
    return out
end
cmds()

local S = { role = "host", in_menu = false, world_pc = "BP_PlayerController_C_100", remote_pcs = { {} } }
L.S = S
L.host_sent, L.host_sent_at = 1, 0   -- hosting already on (helper started earlier)

local t = 1000
sl._hosting_tick(t)
check(L.host_sent == 1 and #cmds() == 0, "in the world: hosting stays on, nothing sent")

-- the host dies: in_main_menu() true, same controller, the friend still connected
S.in_menu = true
for i = 1, 20 do sl._hosting_tick(t + i) end
check(L.host_sent == 1, "host dead for 20 s with a friend connected: hosting kept")
local c = cmds()
check(#c == 0, "no 'host 0' to the helper while the host is dead (" .. table.concat(c, ";") .. ")")

-- dead with nobody connected, same world: still kept (friends can join the respawned host)
S.remote_pcs = {}
for i = 21, 40 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "host dead, nobody connected, same world: hosting kept")

-- respawned
S.in_menu = false
sl._hosting_tick(t + 41)
check(L.host_sent == 1 and #cmds() == 0, "respawned: hosting on, nothing sent")

-- real main menu: the level was loaded again (a new controller, so
-- sdc_session.in_real_menu is true), nobody connected: withdrawn at once
S.in_menu = true
S.world_pc = "BP_PlayerController_C_200"
REAL_MENU = true
sl._hosting_tick(t + 42)
c = cmds()
check(L.host_sent == 0 and c[#c] == "host 0", "real main menu (new controller), nobody connected: withdrawn at once")

-- the same with a player still listed: kept through the 8 s grace (the
-- players are told to leave first, sdc_session HOSTMENU), then withdrawn
L.host_sent, L.host_sent_at, L.host_off_since = 1, t + 43, nil
S.remote_pcs = { {} }
for i = 44, 50 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "real main menu (new controller), a player still listed: kept through the 8 s grace")
sl._hosting_tick(t + 52)
c = cmds()
check(L.host_sent == 0 and c[#c] == "host 0", "real main menu (new controller), a player still listed: withdrawn after 8 s")

-- sdc_session cannot tell (its check fails: taken as not the real menu):
-- the players connected keep the hosting on even off the world
L.host_sent, L.host_sent_at, L.host_off_since = 1, t + 53, nil
REAL_MENU = "error"
for i = 54, 70 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "the real-menu check failing, a player connected: hosting kept even off the world")
-- ... nobody connected, another controller than the hosted world's: the old
-- rule, withdrawn after the 8 s grace (a short loading screen keeps it)
S.remote_pcs = {}
for i = 71, 77 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "the real-menu check failing, nobody connected, a new controller: kept through the 8 s grace")
sl._hosting_tick(t + 79)
c = cmds()
check(L.host_sent == 0 and c[#c] == "host 0", "the real-menu check failing, nobody connected, a new controller: withdrawn after 8 s")
REAL_MENU = false

-- a client role never hosts
L.host_sent, L.host_sent_at, L.host_off_since = 1, t + 80, nil
S.role = "client"
S.remote_pcs = {}
for i = 81, 89 do sl._hosting_tick(t + i) end
check(L.host_sent == 0, "role client: hosting withdrawn")

-- 13.11: the host quits to its main menu from the pause screen: the same
-- controller (one world), the friend still connected
S.role, S.in_menu, S.world_pc, S.remote_pcs = "host", false, "BP_PlayerController_C_300", { {} }
REAL_MENU = false
sl._hosting_tick(t + 90)
c = cmds()
check(L.host_sent == 1 and c[#c] == "host 1 7777", "back in a world: hosting on again (" .. table.concat(c, ";") .. ")")
S.in_menu = true   -- no character; the menu level still streaming in: no MenuWidget yet
for i = 91, 93 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "on the way to the menu (no MenuWidget yet): kept as the same world")
REAL_MENU = true   -- the main menu is up: the world is gone
for i = 94, 100 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "real main menu, the friend told to leave: not withdrawn before the 8 s grace")
sl._hosting_tick(t + 102)
c = cmds()
check(L.host_sent == 0 and c[#c] == "host 0", "real main menu, same controller, a friend still listed: withdrawn after 8 s")

-- the same, the friend already gone: at once
L.host_sent, L.host_sent_at, L.host_off_since = 1, t + 103, nil
S.in_menu, REAL_MENU, S.remote_pcs = false, false, {}
sl._hosting_tick(t + 104)
S.in_menu = true
REAL_MENU = true
sl._hosting_tick(t + 105)
c = cmds()
check(L.host_sent == 0 and c[#c] == "host 0", "real main menu, nobody connected: withdrawn at once")
-- the dead host still keeps it (the same world, no MenuWidget)
L.host_sent, L.host_sent_at, L.host_off_since = 1, t + 106, nil
S.in_menu, REAL_MENU = false, false
sl._hosting_tick(t + 107)
S.in_menu = true
for i = 108, 130 do sl._hosting_tick(t + i) end
check(L.host_sent == 1 and #cmds() == 0, "dead host after all that: hosting still kept")

print(string.format("steamlink host death: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.remove(ini)
