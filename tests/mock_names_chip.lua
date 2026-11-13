-- Mock test: the player name from Steam and the connection chip.
--   * sdc_config.player_name(): config player_name -> Steam name (from the
--     Steam link helper's status.txt "persona=") -> Windows USERNAME -> "Player"
--   * sdc_steamlink.clean_name: no control characters / '|', trimmed, 32 chars max
--   * sdc_steamlink.persona(): kept after the helper's status goes stale
--   * sdc_steamlink.peer_ping / peer_count: only "up" peers of a live helper
--   * the players table's strings (RU / EN): title, column heads, key toasts
-- usage: lua mock_names_chip.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/names_chip"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '\\steamlink" 2>nul')

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local NOW = 1700000000
os.time = function() return NOW end
local ENV = { USERNAME = "User" }
local real_getenv = os.getenv
os.getenv = function(k) if ENV[k] ~= nil then return ENV[k] or nil end return real_getenv(k) end

-- quiet stubs for the modules sdc_config / sdc_steamlink pull in
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

-- ---------------------------------------------------------------- names
check(cfg.player_name() == "User", "no Steam module, empty setting: Windows user name")
ENV.USERNAME = false
check(cfg.player_name() == "Player", "no Windows user name either: Player")
ENV.USERNAME = "User"

local okl, sl = pcall(require, "sdc_steamlink")
check(okl and type(sl) == "table", "sdc_steamlink loads with stubs" .. (okl and "" or (": " .. tostring(sl))))
if not okl then
    print(string.format("names/chip: %d passed, %d failed", checks - fails, fails))
    print("FAILED")
    return
end
check(cfg.player_name() == "User", "Steam module loaded but no name yet: Windows user name")

-- clean_name
check(sl.clean_name("  Bob  ") == "Bob", "trimmed")
check(sl.clean_name("a|b\tc\nd") == "a b c d", "'|' and control characters become spaces")
check(sl.clean_name("   ") == nil and sl.clean_name("") == nil and sl.clean_name(nil) == nil, "empty -> nil")
local long = string.rep("Ж", 40)
local cut = sl.clean_name(long)
check(cut ~= nil and utf8.len(cut) == 32 and cut == string.rep("Ж", 32), "40 Cyrillic letters cut to 32 whole letters")
check(sl.clean_name("Игрок 1") == "Игрок 1", "Cyrillic kept")

-- a helper status file with persona and peers
local L = sl._L
L.dir = TMP .. "/steamlink"
L.session = "42"
local function status(extra)
    local f = assert(io.open(L.dir .. "/status.txt", "wb"))
    f:write("sdcoop_steamlink=1\nversion=1.0\npid=100\nsession=42\ntime=" .. NOW .. "\nsteam=ok\nsteamid=76561190000000001\n")
    f:write(extra or "")
    f:close()
end
status("persona=  Друг|Steam \npeer=76561190000000002 up 10 20 35\npeer=76561190000000003 connecting 0 0 -1\n")
sl._read_status(NOW)
check(sl.persona() == "Друг Steam", "persona read from status.txt and cleaned: " .. tostring(sl.persona()))
check(cfg.player_name() == "Друг Steam", "empty setting: the Steam name")
cfg.set("player_name", "Alice")
check(cfg.player_name() == "Alice", "a name in the setting wins over Steam")
cfg.set("player_name", "")

-- peers
check(sl.peer_ping("76561190000000002") == 35, "an up peer: its ping")
check(sl.peer_ping(76561190000000002) == 35 or sl.peer_ping("76561190000000002") == 35, "SteamID as a string works")
check(sl.peer_ping("76561190000000003") == nil, "a peer still connecting is not counted")
check(sl.peer_ping("76561190000000009") == nil, "not a peer: nil")
check(sl.peer_count() == 1, "one peer up")
status("persona=\npeer=76561190000000002 up 10 20 -1\n")
sl._read_status(NOW)
check(sl.peer_ping("76561190000000002") == -1, "up peer without a measured ping: -1")
check(sl.persona() == "Друг Steam", "an empty persona later keeps the known Steam name")
NOW = NOW + 60   -- the helper stopped writing its status
check(sl.peer_ping("76561190000000002") == nil and sl.peer_count() == 0, "stale helper status: no Steam peers")
check(cfg.player_name() == "Друг Steam", "stale helper: the Steam name is still used")

-- ---------------------------------------------------------------- players table strings
local i18n = require("sdc_i18n")
i18n.set("en")
check(i18n.T("hud_title", 3) == "Players: 3", "EN table title")
check(i18n.T("hud_hint", "F8") == "F8 to hide", "EN key hint")
check(i18n.T("hud_col_name") == "Player" and i18n.T("hud_col_ping") == "Ping", "EN column heads")
check(i18n.T("hud_hidden", "F8") == "Player table hidden. F8 to show it.", "EN hide toast")
check(i18n.T("hud_more", 2) == "and 2 more", "EN more rows")
i18n.set("ru")
check(i18n.T("hud_title", 3) == "Игроки: 3", "RU table title")
check(i18n.T("hud_hint", "F8") == "F8 — скрыть", "RU key hint")
check(i18n.T("hud_col_name") == "Игрок" and i18n.T("hud_col_ping") == "Пинг", "RU column heads")
check(i18n.T("hud_shown", "F8") == "Таблица игроков показана. F8 — скрыть.", "RU show toast")
check(i18n.label("players_hud") == "Таблица игроков на экране (F8)", "RU setting label")
check(cfg.get("players_hud") == true and cfg.get("players_hud_key") == "F8", "the table is on by default, key F8")

print(string.format("names/chip: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.remove(ini)
