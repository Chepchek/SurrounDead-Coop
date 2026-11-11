-- Mock test: the host's Steam hosting survives the host's death.
-- 0.7.0: ue.in_main_menu() is true while the host is dead (no own character
-- on the menu map); sdc_steamlink withdrew the Steam hosting 8 s later and the
-- helper closed every Steam friend's tunnel. Now hosting stays on while the
-- world is the same (same local controller) or players are connected, and is
-- still withdrawn back in the real main menu (a new controller, nobody left).
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

local cfg = require("sdc_config")
local ini = TMP .. "/config.ini"
os.remove(ini)
cfg.load(ini)
local sl = require("sdc_steamlink")
local L = sl._L
L.dir = TMP .. "/steamlink"
L.session = "7"

-- commands the helper would read
local function cmds()
    local out = {}
    local p = io.popen('dir /b /on "' .. L.dir:gsub("/", "\\") .. '\\cmd_7_*.txt" 2>nul')
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

-- real main menu: the level was loaded again (new controller), nobody connected
S.in_menu = true
S.world_pc = "BP_PlayerController_C_200"
for i = 42, 48 do sl._hosting_tick(t + i) end
check(L.host_sent == 1, "main menu: not withdrawn before the 8 s grace")
sl._hosting_tick(t + 51)
c = cmds()
check(L.host_sent == 0 and c[#c] == "host 0", "real main menu after 8 s: hosting withdrawn ('host 0' sent)")

-- main menu with a player still listed (the old controller list not yet cleared): kept
L.host_sent, L.host_sent_at, L.host_off_since = 1, t + 52, nil
S.remote_pcs = { {} }
for i = 53, 70 do sl._hosting_tick(t + i) end
check(L.host_sent == 1, "players still connected: hosting kept even off the world")

-- a client role never hosts
S.role = "client"
S.remote_pcs = {}
for i = 71, 85 do sl._hosting_tick(t + i) end
check(L.host_sent == 0, "role client: hosting withdrawn")

print(string.format("steamlink host death: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.remove(ini)
