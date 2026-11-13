-- Mock test for sdc_steamlink (Steam join through the helper
-- SDCoopSteamLink.exe) and its wiring in sdc_session / sdc_steam / sdc_netdiag:
-- helper start command, command files (atomic, ordered), status / friends
-- files, hosting flag with hysteresis and resend, the join flow
-- (sdc_session.join -> request_tunnel -> helper -> join_tunnel "open
-- 127.0.0.1:<port>"), retries while the host loads, rejection, overlay
-- "Join Game" requests, helper restarts, the UI interface (status / friends /
-- join / invite), Engine.ini (bUseSteamNetworking only, restart only under
-- Steam), presence owned by the helper. The test plays the helper's part
-- through the same files. No engine, no Steam.
-- usage: lua mock_steamlink.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/steamlink"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '\\Mods\\SDCoop\\steamlink" 2>nul')
local MOD = TMP .. "/Mods/SDCoop"
local DIR = MOD .. "/steamlink"

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

-- ------------------------------------------------------------ clock, env, processes
local T = 1700000000
os.time = function() return T end
local real_getenv = os.getenv
local ENV = { LOCALAPPDATA = TMP .. "/appdata" }
os.getenv = function(k) if ENV[k] ~= nil then return ENV[k] or nil end return real_getenv(k) end
local executed = {}
local real_execute = os.execute
os.execute = function(cmd) executed[#executed + 1] = cmd; return true, "exit", 0 end
local logged = {}
print = function(s) logged[#logged + 1] = tostring(s) end
local function logged_has(pat)
    for _, l in ipairs(logged) do if l:find(pat, 1, true) then return true end end
    return false
end

-- ------------------------------------------------------------ UE4SS globals
local FN = {}
function FName(s) return setmetatable({ s = s }, { __index = { ToString = function(self) return self.s end } }) end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay(_, f) return 1 end
function LoopInGameThreadWithDelay() return 1 end
function RegisterHook() return 1, 2 end
local found_objects = 0
function StaticFindObject() found_objects = found_objects + 1; return nil end
-- GameEngine with the game's own net driver definition (SteamSockets)
local def = { DefName = FName("GameNetDriver"), DriverClassName = FName("/Script/SteamSockets.SteamSocketsNetDriver"),
    DriverClassNameFallback = FName("/Script/OnlineSubsystemUtils.IpNetDriver") }
local defs = { ForEach = function(_, fn) fn(1, { get = function() return def end }) end }
local engine = { IsValid = function() return true end, GetPropertyValue = function(_, n) if n == "NetDriverDefinitions" then return defs end end }
function FindFirstOf(cls) if cls == "GameEngine" then return engine end return nil end
function FindAllOf() return {} end

-- ------------------------------------------------------------ heavy modules of sdc_session: stubs
local function stubmod()
    return setmetatable({}, { __index = function() return function() return nil end end })
end
for _, m in ipairs({ "sdc_net", "sdc_sync", "sdc_ctx", "sdc_players", "sdc_items", "sdc_appearance", "sdc_pawnstate",
    "sdc_combat", "sdc_gearfx", "sdc_damage", "sdc_ai", "sdc_localinit", "sdc_dmgnum", "sdc_whistle", "sdc_ownsounds",
    "sdc_dialogue", "sdc_quests", "sdc_widgets" }) do
    package.loaded[m] = stubmod()
end

local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text, kind, seconds, class)
    toasts[#toasts + 1] = { text = text, kind = kind, class = class }
end
local function last_toast() return toasts[#toasts] end
local function toast_has(pat)
    for _, t in ipairs(toasts) do if t.text:find(pat, 1, true) then return true end end
    return false
end

local ue = require("sdc_ue")
local ROLE, MENU, PENDING = "standalone", true, false
local opened = {}
ue.net_role = function() return ROLE end
ue.in_main_menu = function() return MENU end
ue.has_pending_connection = function() return PENDING end
ue.exec = function(cmd) opened[#opened + 1] = cmd; return true end

local cfg = require("sdc_config")
cfg.load(TMP .. "/config.ini")
local steam = require("sdc_steam")
local netdiag = require("sdc_netdiag")
local session = require("sdc_session")
local S = session.state
S.role, S.in_menu = "standalone", true

-- ------------------------------------------------------------ the helper's side
local SESSION
local function rd(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function wr(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function take_cmds(L)
    local out = {}
    for i = 1, L.seq do
        local p = string.format("%s/cmd_%s_%06d.txt", DIR, L.session, i)
        local s = rd(p)
        if s then
            out[#out + 1] = (s:gsub("\n$", ""))
            os.remove(p)
        end
    end
    return out
end
local H = { steam = "ok", relay = 100, hosting = 0, listen = 0, peers = 0, join_req = "", join_state = "idle",
    join_port = 0, join_reason = "", invite_seq = 0, invite_host = "", friends_seq = 0, pid = 4242, steamid = "76561190000000100" }
local function helper_status()
    local lines = { "sdcoop_steamlink=1", "version=1.0", "pid=" .. H.pid, "game_pid=1", "session=" .. SESSION,
        "time=" .. T, "steam=" .. H.steam, "steamid=" .. H.steamid, "relay=" .. H.relay,
        "hosting=" .. H.hosting, "listen=" .. H.listen, "friends_only=1", "peers=" .. H.peers }
    if H.peers > 0 then lines[#lines + 1] = "peer=76561190000000201 up 1000 2000 35" end
    for _, k in ipairs({ "join_req", "join_state", "join_port", "join_reason", "invite_seq", "invite_host", "friends_seq" }) do
        lines[#lines + 1] = k .. "=" .. tostring(H[k])
    end
    lines[#lines + 1] = "join_ping=42"
    wr(DIR .. "/status.txt", table.concat(lines, "\n") .. "\n")
end

-- ------------------------------------------------------------ A. install
io.write("A. install\n")
wr(DIR .. "/SDCoopSteamLink.exe", "MZ")
wr(DIR .. "/status.txt", "stale")
local sl = require("sdc_steamlink")
local L = sl._L
sl.install(S, MOD, "0.7.0")
SESSION = L.session
check(#executed == 1, "the helper is started once at install")
local cmd = executed[1] or ""
check(cmd:sub(1, 2) == '""' and cmd:sub(-1) == '"', "cmd /c quoting: outer quotes around the whole command")
check(cmd:find('\\steamlink\\SDCoopSteamLink.exe" --launch --session ' .. SESSION .. ' --mod-version 0.7.0 --game-port 7777 --friends-only 1', 1, true) ~= nil,
    "start arguments (launch trampoline, session, version, game port, friends only)")
check(not cmd:find("/", 1, true), "Windows path separators in the command")
check(rd(DIR .. "/status.txt") == nil, "a stale status file is removed before the start")
check(steam.presence_by_helper == true, "rich presence is the helper's")
check(tostring(def.DriverClassName):find("IpNetDriver", 1, true) ~= nil or def.DriverClassName:ToString():find("IpNetDriver", 1, true) ~= nil,
    "GameNetDriver switched to IpNetDriver at start")
check(netdiag.ip_fallback == true and L.ip_patched == true, "net driver patch recorded")
check(sl.status().state == "starting" and sl.status().detail_key == "sl_st_starting", "status: starting before the helper answers")

-- ------------------------------------------------------------ B. helper up, config
io.write("B. helper up\n")
T = T + 2
helper_status()
sl.tick()
local cmds = take_cmds(L)
check(cmds[1] == "config friends_only=1 allow= version=0.7.0", "config sent to the helper: " .. tostring(cmds[1]))
check(sl.status().state == "ready" and sl.status().helper == true, "status: ready")
check(sl.status().steamid == "76561190000000100", "own SteamID from the helper")
local leftovers = 0
for i = 1, L.seq do if rd(string.format("%s/cmd_%s_%06d.tmp", DIR, L.session, i)) then leftovers = leftovers + 1 end end
check(leftovers == 0, "no .tmp left behind (rename is the hand-over)")
H.relay = 3
helper_status()
sl.tick()
check(sl.status().state == "starting" and sl.status().detail_key == "sl_st_relay", "status: relay network not ready yet")
H.relay = 100

-- ------------------------------------------------------------ C. hosting
io.write("C. hosting\n")
ROLE, MENU = "host", false
S.role, S.in_menu = "host", false
T = T + 1
helper_status()
sl.tick()
cmds = take_cmds(L)
check(cmds[1] == "host 1 7777", "hosting on as soon as the host is in its world")
H.hosting, H.listen, H.peers = 1, 1, 1
helper_status()
local nt = #toasts
sl.tick()
check(sl.status().state == "hosting" and sl.status().peers == 1, "status: hosting, 1 friend connected")
check(#toasts == nt + 1 and last_toast().text:find("Присоединиться", 1, true) ~= nil and last_toast().class == "game",
    "one gameplay notification: friends can join through Steam")
sl.tick()
check(#toasts == nt + 1, "the hosting notification is not repeated")
S.in_menu = true
for _ = 1, 5 do T = T + 1; helper_status(); sl.tick() end
check(#take_cmds(L) == 0, "a few seconds out of the world keep hosting (loading screens)")
for _ = 1, 4 do T = T + 1; helper_status(); sl.tick() end
cmds = take_cmds(L)
check(cmds[1] == "host 0", "hosting off after 8 s out of the world")
H.hosting, H.listen, H.peers = 0, 0, 0
S.in_menu = false
T = T + 1
helper_status()
sl.tick()
cmds = take_cmds(L)
check(cmds[1] == "host 1 7777", "back in the world: hosting on again")
-- the helper restarted and does not know: say it again after 5 s
for _ = 1, 6 do T = T + 1; helper_status(); sl.tick() end
cmds = take_cmds(L)
check(cmds[1] == "host 1 7777", "hosting resent when the helper reports otherwise")
H.hosting, H.listen = 1, 1
helper_status()
sl.tick()
check(found_objects == 0 and pcall(steam.set_presence, true) and found_objects == 0, "sdc_steam leaves the presence to the helper")
-- the host cannot join anybody from its world
local ok, why, key = sl.join("76561190000000300")
check(not ok and key == "host_cannot_join", "join refused while hosting a world (" .. tostring(why) .. ")")
S.role, S.in_menu, ROLE, MENU = "standalone", true, "standalone", true
for _ = 1, 9 do T = T + 1; helper_status(); sl.tick() end
take_cmds(L)
H.hosting, H.listen = 0, 0

-- ------------------------------------------------------------ D. friends
io.write("D. friends\n")
wr(DIR .. "/friends.txt", "seq=3\n76561190000000301\t0\t\tZed\n76561190000000300\t1\t0.7.0\tАня\n76561190000000302\t1\t0.6.70\tbob\n")
H.friends_seq = 3
T = T + 1
helper_status()
sl.tick()
local fr = sl.friends()
check(#fr == 3, "three friends in SurrounDead")
check(fr[1].joinable and fr[2].joinable and not fr[3].joinable, "hosting friends first")
local byid = {}
for _, f in ipairs(fr) do byid[f.id] = f end
check(fr[1].name == "bob" and byid["76561190000000300"].name == "Аня", "names (UTF-8) and ids, hosting ones sorted by name")
check(byid["76561190000000300"].status:find("0.7.0", 1, true) ~= nil and byid["76561190000000302"].status:find("0.6.70", 1, true) ~= nil
    and byid["76561190000000300"].status ~= byid["76561190000000302"].status, "status shows the host's mod version and a different version")
check(fr[3].status == sl.tr("sl_f_ingame"), "not hosting: in the game")

-- ------------------------------------------------------------ E. join
io.write("E. join\n")
ok, why, key = sl.join("123")
check(not ok and key == "sl_bad_id", "bad id refused")
ok, why, key = sl.join("76561190000000100")
check(not ok and key == "sl_self", "own id refused")
ok = sl.join("76561190000000300")
check(ok and L.join and L.join.sid == "76561190000000300", "join started")
check(S.join.target == "steam:76561190000000300", "sdc_session.join routed the Steam code to the tunnel")
cmds = take_cmds(L)
local req = L.join.req
check(cmds[1] == "join 76561190000000300 " .. req, "join command with a request id")
check(last_toast().text:find("Аня", 1, true) ~= nil and last_toast().class == "game", "connecting notification with the friend's name")
check(logged_has("76561190000000300") and not logged_has("Аня"), "the log line has the SteamID, not the name")
check(sl.status().state == "joining", "status: joining")
check(sl.join("76561190000000300") == true and #take_cmds(L) == 0, "a second click does not start another join")
H.join_req, H.join_state, H.join_port = req, "connecting", 0
T = T + 1; helper_status(); sl.tick()
check(#opened == 0, "no open while the tunnel is being built")
H.join_state, H.join_port = "ready", 50123
T = T + 1; helper_status(); sl.tick()
check(opened[1] == "open 127.0.0.1:50123", "the game opens the tunnel port: " .. tostring(opened[1]))
check(S.join.target == "127.0.0.1:50123", "session join target is the tunnel")
check(sl.status().state == "connected" and sl.status().detail:find("42", 1, true) ~= nil, "status: connected (with ping)")
ROLE, S.role, MENU, S.in_menu = "client", "client", false, false
T = T + 1; helper_status(); sl.tick()
ok, why, key = sl.join("76561190000000302")
check(not ok and key == "already_client", "no second join while connected")
H.join_state = "closed"
-- in a world status.txt is read every 3 s (0.9.x: once a second cost ~7 ms/s)
for _ = 1, 3 do T = T + 1; helper_status(); sl.tick() end
check(last_toast().text == sl.tr("sl_tunnel_lost"), "tunnel closed while playing: notification (within 3 s)")
ROLE, S.role, MENU, S.in_menu = "standalone", "standalone", true, true
T = T + 1; helper_status(); sl.tick()
cmds = take_cmds(L)
check(cmds[1] == "leave" and L.join == nil, "back in the menu: the tunnel is closed")
H.join_state = "idle"

-- ------------------------------------------------------------ F. retries, rejection, failure
io.write("F. retries\n")
opened = {}
sl.join("76561190000000302")
cmds = take_cmds(L)
req = L.join.req
H.join_req, H.join_state, H.join_reason = req, "failed", "not_hosting"
T = T + 1; helper_status(); sl.tick()
check(last_toast().text:find("ещё не открыл мир", 1, true) ~= nil, "host not hosting yet: waiting notification")
check(sl.status().detail_key == "sl_st_waiting", "status: waiting for the host")
for _ = 1, 6 do T = T + 1; helper_status(); sl.tick() end
cmds = take_cmds(L)
check(#cmds == 1 and cmds[1]:match("^join 76561190000000302 ") and L.join.req ~= req, "retried with a new request id")
H.join_req, H.join_reason = L.join.req, "not_friend"
T = T + 1; helper_status(); sl.tick()
check(last_toast().text:find("только друзей", 1, true) ~= nil and L.join == nil, "not a friend: rejected, join ends")
-- keeps timing out past the 2 minutes
sl.join("76561190000000302")
take_cmds(L)
local started = T
local final
while T - started < 200 do
    H.join_req, H.join_state, H.join_reason = L.join and L.join.req or H.join_req, "failed", "timeout"
    T = T + 1; helper_status(); sl.tick()
    take_cmds(L)
    if not L.join then final = last_toast(); break end
end
check(final and final.text:find("хост не отвечает", 1, true) ~= nil, "after 2 minutes: failed notification with the reason")
check(T - started >= 120 and T - started < 140, "gave up after about 2 minutes (" .. (T - started) .. " s)")
check(logged_has("no answer from the host"), "English reason in the log")
check(#opened == 0, "nothing opened for failed joins")
-- the helper never answers
sl.join("76561190000000302")
take_cmds(L)
for _ = 1, 50 do T = T + 1; helper_status(); sl.tick() end
check(L.join == nil and last_toast().text:find("помощник Steam не отвечает", 1, true) ~= nil, "no answer from the helper: failed")
H.join_state = "idle"

-- ------------------------------------------------------------ G. Steam "Join Game" / invites
io.write("G. invites\n")
ROLE, S.role, MENU, S.in_menu = "standalone", "standalone", false, false   -- single-player world
H.invite_seq, H.invite_host = 1, "76561190000000300"
for _ = 1, 3 do T = T + 1; helper_status(); sl.tick() end
check(last_toast().text:find("выйдите в главное меню", 1, true) ~= nil and L.join == nil,
    "in a single-player world: asks to quit to the menu (status read within 3 s)")
take_cmds(L)
MENU, S.in_menu = true, true
T = T + 1; helper_status(); sl.tick()
cmds = take_cmds(L)
check(L.join and L.join.sid == "76561190000000300" and cmds[1]:match("^join 76561190000000300 "), "in the menu: the join starts by itself")
L.join = nil
H.invite_seq = 2
T = T + 1; helper_status(); sl.tick()
cmds = take_cmds(L)
check(L.join and cmds[1] and cmds[1]:match("^join 76561190000000300 "), "Join Game clicked in the menu: joins at once")
L.join = nil
ROLE, S.role, MENU, S.in_menu = "host", "host", false, false
H.invite_seq = 3
T = T + 1; helper_status(); sl.tick()
check(last_toast().text:find("вы сейчас хост", 1, true) ~= nil and L.join == nil, "while hosting: notification only")
take_cmds(L)
H.pid = 5555   -- a new helper counts its requests from 0 again
H.invite_seq = 1
T = T + 1; helper_status(); sl.tick()
check(L.invite_seen == 1, "a restarted helper's requests are seen again")
ROLE, S.role, MENU, S.in_menu = "standalone", "standalone", true, true
for _ = 1, 10 do T = T + 1; helper_status(); sl.tick() end
take_cmds(L)

-- ------------------------------------------------------------ H. invite(), restart needed, helper down
io.write("H. misc\n")
steam.invite = function() return true end
check(sl.invite() == true, "invite(): overlay dialog through SteamCore")
steam.invite = function() return false, "no_steam" end
ok, why, key = sl.invite()
check(not ok and key == "sl_st_no_steam", "invite(): no Steam")
-- the host's Invite on a friend's row: the helper's own "invite" (Steam sends it, the helper lets that friend in)
take_cmds(L)
check(sl.invite_friend(" 76561190000000300 ") == true and take_cmds(L)[1] == "invite 76561190000000300",
    "invite_friend(id): 'invite <SteamID>' to the helper")
ok, why, key = sl.invite_friend("12345")
check(not ok and key == "sl_bad_id" and #take_cmds(L) == 0, "invite_friend: not a SteamID, nothing sent")
ok, why, key = sl.invite_friend("76561190000000100")
check(not ok and key == "sl_self", "invite_friend: not oneself")
steam.server_api_pending = true
check(sl.status().state == "error" and sl.status().restart_needed, "status: restart needed after the Engine.ini write")
ok, why, key = sl.join("76561190000000300")
check(not ok and key == "sl_st_restart", "join refused until the restart")
steam.server_api_pending = false
local starts = #executed
-- the helper stops while a join is wanted: started again once, at most 3 starts in all
T = T + 30
L.join = { sid = "76561190000000300", name = "x", deadline = T + 120, attempt = 1, req = "z", sent_at = T }
sl.tick()
check(#executed == starts + 1 and executed[#executed]:find("--launch", 1, true), "helper restarted when needed")
check(sl.status().state == "starting", "status: starting again")
T = T + 40; sl.tick(); T = T + 40; sl.tick(); T = T + 40; sl.tick(); T = T + 40; sl.tick()
check(L.starts == 3, "never more than 3 starts per game")
check(sl.status().state == "error" and sl.status().detail_key == "sl_st_crashed", "status: helper stopped")
L.join = nil

-- ------------------------------------------------------------ I. parsing
io.write("I. parsing\n")
local st = sl._parse_status("sdcoop_steamlink=1\npeers=2\npeer=76561190000000201 up 10 20 30\npeer=76561190000000202 connecting 0 0 -1\njoin_state=ready\n")
check(st and #st.peer_list == 2 and st.peer_list[2].ping == -1 and st.join_state == "ready", "status file parser")
check(sl._parse_status("garbage") == nil, "not a status file")
local list, seq = sl._parse_friends("seq=9\nbad line\n76561190000000301\t1\t\t\n")
check(seq == "9" and #list == 1 and list[1].name == "76561190000000301", "friends parser (empty name -> id)")
check(type(sl.status_line()) == "string", "status line")

-- ------------------------------------------------------------ J. Engine.ini (sdc_steam)
io.write("J. Engine.ini\n")
local ini_dir = TMP .. "/appdata/SurrounDead/Saved/Config/Windows"
real_execute('mkdir "' .. ini_dir:gsub("/", "\\") .. '" 2>nul')
local ini = ini_dir .. "/Engine.ini"
real_execute('attrib -R "' .. ini:gsub("/", "\\") .. '" >nul 2>&1')
wr(ini, "[Core.System]\nPaths=../../../Engine/Content\n")
ENV.SteamAppId, ENV.SteamGameId = false, false
steam.server_api_pending = false
steam.ensure_server_api(cfg)
local text = rd(ini) or ""
check(text:find("bUseSteamNetworking=False", 1, true) and not text:find("bInitServerOnClient", 1, true), "Engine.ini: bUseSteamNetworking=False only")
check(text:find("Paths=../../../Engine/Content", 1, true) ~= nil, "Engine.ini: the rest kept")
check(steam.server_api_pending == false, "started outside Steam: no restart needed")
os.execute = function(c) executed[#executed + 1] = c; return true, "exit", 0 end
real_execute('attrib -R "' .. ini:gsub("/", "\\") .. '" >nul 2>&1')
wr(ini, "[OnlineSubsystemSteam]\nbInitServerOnClient=True\n")
ENV.SteamAppId = "1645820"
nt = #toasts
steam.ensure_server_api(cfg)
text = rd(ini) or ""
check(text:find("bUseSteamNetworking=False", 1, true) and text:find("bInitServerOnClient=True", 1, true), "an old bInitServerOnClient line is left alone")
check(steam.server_api_pending == true and #toasts == nt + 1, "started by Steam: one restart notice")
steam.server_api_pending = false
nt = #toasts
steam.ensure_server_api(cfg)
check(steam.server_api_pending == false and #toasts == nt, "already set: no notice, no restart")
real_execute('attrib -R "' .. ini:gsub("/", "\\") .. '" >nul 2>&1')
ENV.SteamAppId = false

-- ------------------------------------------------------------ L. status.txt reads
-- The tick runs every 0.5 s (two ticks per os.time second here); the status
-- file is read once a second, every tick only during a join or right after a
-- command (its answer).
io.write("L. status reads\n")
S.role, S.in_menu, ROLE, MENU = "standalone", true, "standalone", true
L.join, L.pending_invite = nil, nil
-- command files of an earlier run in this folder (same session id: os.time is
-- fixed here) would make a rename fail and the config be sent again each tick
for i = 1, L.seq + 100 do os.remove(string.format("%s/cmd_%s_%06d.txt", DIR, L.session, i)) end
T = T + 10
helper_status()
sl.tick()
take_cmds(L)
L.sent_t = nil
T = T + 1
helper_status()
sl.tick()
local r0 = L.reads
sl.tick()
check(L.reads == r0, "idle: the second tick of the same second does not read status.txt")
T = T + 1; helper_status(); sl.tick(); sl.tick()
check(L.reads == r0 + 1, "idle: once in the next second")
check(sl.invite_friend("76561190000000300") == true, "a command to the helper")
take_cmds(L)
sl.tick()
check(L.reads == r0 + 2, "right after a command: read on the next tick of the same second (its answer)")
T = T + 3; helper_status(); sl.tick(); sl.tick()
check(L.reads == r0 + 3, "3 s after the command: once a second again")
L.join = { sid = "76561190000000300", name = "x", deadline = T + 120, attempt = 1, req = "rq", sent_at = T }
sl.tick(); sl.tick()
check(L.reads == r0 + 5, "a join under way: every tick")
S.role = "client"
L.join.connected = true
T = T + 1; helper_status(); sl.tick(); sl.tick()
check(L.reads == r0 + 6, "connected through the tunnel: once a second")
S.role = "standalone"
L.join = nil
L.sent_t = nil
check(sl._status_due(L.read_t) == false and sl._status_due(L.read_t + 1) == true, "status_due: a new second is due, the same one not")
local sls = ue.sub_stats["sl:status"]
check(sls ~= nil and sls.calls == L.reads, "every read timed in [PERF] parts as sl:status (" .. tostring(sls and sls.calls) .. ")")

-- ------------------------------------------------------------ M. the host does not answer (13.11 review, item 9)
-- The host's game crashed; the client's "Try again" got "timeout" from the
-- helper five times and showed "has not opened a world yet" for 2 minutes.
io.write("M. host does not answer\n")
S.role, S.in_menu, ROLE, MENU = "standalone", true, "standalone", true
L.join, L.pending_invite, L.left, L.sent_t = nil, nil, nil, nil
H.join_state, H.join_reason = "idle", ""
T = T + 5; helper_status(); sl.tick(); take_cmds(L)
local function toasted_since(n, pat)
    for i = n + 1, #toasts do if toasts[i].text:find(pat, 1, true) then return true end end
    return false
end
local function fail_current(reason)
    H.join_req, H.join_state, H.join_reason = L.join and L.join.req or H.join_req, "failed", reason
end
local nt0 = #toasts
check(sl.join("76561190000000302") == true, "M1 join a friend who never connected here")
take_cmds(L)
fail_current("timeout")
T = T + 1; helper_status(); sl.tick()
check(toasted_since(nt0, "не отвечает через Steam") and toasted_since(nt0, "закрыта или вылетела"),
    "M1 timeout: 'does not answer through Steam - closed or crashed?' (" .. tostring(last_toast().text) .. ")")
check(not toasted_since(nt0, "ещё не открыл мир"), "M1 ... and not 'has not opened a world yet'")
check(sl.status().detail_key == "sl_st_silent" and sl.status().silent == true
    and sl.status().detail:find("не отвечает", 1, true) ~= nil, "M1 status line (join screen): the host does not answer")
check(logged_has("does not answer through Steam"), "M1 English text in the log")
local n1 = #toasts
for _ = 1, 8 do fail_current("timeout"); T = T + 1; helper_status(); sl.tick(); take_cmds(L) end
check(#toasts == n1 and L.join ~= nil and (L.join.attempt or 0) >= 2, "M1 still no answer: retried, the notice not repeated")
-- the host's game is back, its world still loading: the other notice
local n2 = #toasts
for _ = 1, 8 do fail_current("not_hosting"); T = T + 1; helper_status(); sl.tick(); take_cmds(L) end
check(toasted_since(n2, "ещё не открыл мир") and sl.status().detail_key == "sl_st_waiting",
    "M1 then 'not_hosting': 'has not opened a world yet' and the waiting status")
-- Cancel (join screen / console)
local replies = {}
sl.console({ "cancel" }, function(s) replies[#replies + 1] = s end)
cmds = take_cmds(L)
check(L.join == nil and cmds[#cmds] == "leave" and replies[1] == "Steam join cancelled", "M2 sdcoop_steam cancel: tunnel closed, join over")
check(sl.cancel() == false, "M2 nothing to cancel any more")
check(sl.status().state ~= "joining", "M2 status no longer 'joining'")
-- connected to a host, the connection drops, Try again: the host's game is gone
H.join_state, H.join_reason = "idle", ""
sl.join("76561190000000300")
take_cmds(L)
H.join_req, H.join_state, H.join_port = L.join.req, "ready", 50124
T = T + 1; helper_status(); sl.tick()
-- Cancel never closes a tunnel the game already uses (skeptic: a mutation
-- without that guard survived)
local function no_leave() for _, c in ipairs(take_cmds(L)) do if c == "leave" then return false end end return true end
take_cmds(L)
check(L.join and L.join.opened == true and sl.cancel("test") == false and no_leave() and L.join ~= nil,
    "M2b tunnel open, the game connecting through it: cancel refused, no 'leave'")
ROLE, S.role, MENU, S.in_menu = "client", "client", false, false
T = T + 1; helper_status(); sl.tick()
check(L.join and L.join.connected == true, "M3 playing at the host through the tunnel")
take_cmds(L)
local creplies = {}
sl.console({ "cancel" }, function(s) creplies[#creplies + 1] = s end)
check(no_leave() and L.join ~= nil and L.join.connected == true and creplies[1] == "no Steam join to cancel",
    "M2b playing: sdcoop_steam cancel leaves the tunnel alone")
ROLE, S.role, MENU, S.in_menu = "standalone", "standalone", true, true   -- connection lost
T = T + 1; helper_status(); sl.tick()
cmds = take_cmds(L)
check(L.join == nil and L.left and L.left.sid == "76561190000000300", "M3 the end of that connection is remembered")
H.join_state, H.join_reason = "idle", ""
T = T + 13
local n3 = #toasts
sl.join("76561190000000300")
take_cmds(L)
fail_current("timeout")
T = T + 1; helper_status(); sl.tick()
check(toasted_since(n3, "похоже, игра хоста закрылась или вылетела (вы были подключены 14 с назад)"),
    "M3 timeout 14 s after that: says the host's game seems to have closed or crashed (" .. tostring(last_toast().text) .. ")")
check(logged_has("you were connected 14 s ago"), "M3 English text in the log")
check(sl.status().detail_key == "sl_st_silent_left" and sl.status().detail:find("игра хоста закрылась", 1, true) ~= nil,
    "M3 the join screen's line says it too (the notice itself is quiet under the join screen)")
do
    local f = io.open(SCRIPTS .. "/sdc_ui.lua", "rb")
    local src = f and f:read("a") or ""
    if f then f:close() end
    local quiet = src:match("JC%.QUIET = (%b{})") or ""
    check(quiet:find("sl_host_silent = true", 1, true) and quiet:find("sl_host_silent_left = true", 1, true),
        "M3 sdc_ui: the two notices are quiet while the join screen shows its own line")
end
sl.cancel()
take_cmds(L)
-- rendezvous counts as no answer too; much later the plain notice
T = T + 200
local n4 = #toasts
sl.join("76561190000000300")
take_cmds(L)
fail_current("rendezvous")
T = T + 1; helper_status(); sl.tick()
check(toasted_since(n4, "не отвечает через Steam") and not toasted_since(n4, "вы были подключены"),
    "M4 rendezvous 3+ min after the connection ended: the plain 'does not answer' notice")
sl.cancel()
take_cmds(L)
H.join_state, H.join_reason = "idle", ""

-- ------------------------------------------------------------ N. status.txt reads in a world (item 18)
io.write("N. status reads in a world\n")
ROLE, S.role, MENU, S.in_menu = "standalone", "standalone", false, false   -- a single-player world
L.join, L.sent_t = nil, nil
T = T + 5; helper_status(); sl.tick()
local rw = L.reads
for _ = 1, 2 do T = T + 1; helper_status(); sl.tick(); sl.tick() end
check(L.reads == rw, "N1 in a world: no read for 2 s")
T = T + 1; helper_status(); sl.tick(); sl.tick()
check(L.reads == rw + 1, "N1 in a world: one read every 3 s (" .. (L.reads - rw) .. ")")
check(sl._helper_alive(T + 9) == true and sl._helper_alive(T + 10) == false,
    "N1 the helper counts as running between reads (6 s + the 3 s gap after the last read), not longer")
-- a slow read (a virus scanner): logged, the next one 6 s later
local real_clock = os.clock
local fake_c = 0
os.clock = function() fake_c = fake_c + 0.05; return fake_c end
T = T + 3; helper_status(); sl.tick()
os.clock = real_clock
check(L.read_slow == true and logged_has("status.txt is read at most every 6 s"), "N2 a slow read (50 ms) is logged")
local rs = L.reads
for _ = 1, 5 do T = T + 1; helper_status(); sl.tick() end
check(L.reads == rs, "N2 after a slow read: no read for 5 s")
T = T + 1; helper_status(); sl.tick()
check(L.reads == rs + 1 and L.read_slow == false, "N2 read again 6 s later; a fast read goes back to every 3 s")
check(L.down_logged == false and sl.status().helper == true, "N2 the helper never counted as stopped meanwhile")
local nlog = #logged
os.clock = function() fake_c = fake_c + 0.05; return fake_c end
T = T + 3; helper_status(); sl.tick()
os.clock = real_clock
local again = false
for i = nlog + 1, #logged do if logged[i]:find("status.txt is read at most", 1, true) then again = true end end
check(L.read_slow == true and not again, "N2 a second slow read soon after: not logged again")
-- a join under way still reads every tick, even in a world
L.join = { sid = "76561190000000300", name = "x", deadline = T + 120, attempt = 1, req = "rq2", sent_at = T }
local rj = L.reads
sl.tick(); sl.tick()
check(L.reads == rj + 2, "N3 a join under way: every tick")
L.join = nil
local slf = ue.sub_stats["sl:status"]
check(slf ~= nil and slf.wmax >= 50, "N4 [PERF] parts sl:status keeps the slow read as its max")
-- N5 / N6 (skeptic): a slow status read and, in the same tick, a quick
-- friends.txt read (the list changed): the 6 s pause stays; a slow
-- friends.txt read sets the pause too, only a fast status read ends it.
-- Reads cost what the file costs: 50 ms for `slow_file`, else 1 ms.
L.join, L.sent_t, L.read_slow = nil, nil, false
local real_open = io.open
local slow_file, fc = nil, 0
os.clock = function() return fc end
io.open = function(p, m)
    if slow_file and type(p) == "string" and p:find(slow_file, 1, true) then fc = fc + 0.05 else fc = fc + 0.001 end
    return real_open(p, m)
end
local function next_read_after()
    local r0, first = L.reads, nil
    for i = 1, 7 do
        T = T + 1; helper_status(); sl.tick()
        if L.reads > r0 then first = i; break end
    end
    return first
end
T = T + 3; helper_status(); sl.tick()   -- an ordinary read: the 3 s rhythm starts here
slow_file = "status.txt"
H.friends_seq = H.friends_seq + 1
wr(DIR .. "/friends.txt", "seq=" .. H.friends_seq .. "\n76561190000000301\t1\t0.7.0\tBob\n")
T = T + 3; helper_status(); sl.tick()
slow_file = nil
check(L.friends_seq == tostring(H.friends_seq) and L.read_slow == true,
    "N5 slow status read + quick friends.txt read in the same tick: the pause stays on")
local gap5 = next_read_after()
check(gap5 == 6, "N5 ... the next status read comes 6 s later, not 3 (" .. tostring(gap5) .. " s)")
check(L.read_slow == false, "N5 that read was fast: back to every 3 s")
slow_file = "friends.txt"
L.slow_logged = nil
H.friends_seq = H.friends_seq + 1
wr(DIR .. "/friends.txt", "seq=" .. H.friends_seq .. "\n76561190000000301\t0\t\tBob\n")
local nl6 = #logged
T = T + 3; helper_status(); sl.tick()
slow_file = nil
local said6 = false
for i = nl6 + 1, #logged do if logged[i]:find("reading the helper's friends.txt took 50 ms", 1, true) then said6 = true end end
check(L.friends_seq == tostring(H.friends_seq) and L.read_slow == true and said6,
    "N6 a slow friends.txt read (status fast): logged by its file name, status reads paused too")
local gap6 = next_read_after()
check(gap6 == 6 and L.read_slow == false, "N6 ... next status read 6 s later; fast, so the pause ends (" .. tostring(gap6) .. " s)")
io.open = real_open
os.clock = real_clock
MENU, S.in_menu = true, true
L.read_slow = false

-- ------------------------------------------------------------ K. off by config / missing exe
io.write("K. off\n")
package.loaded["sdc_steamlink"] = nil
local sl2 = require("sdc_steamlink")
os.remove(DIR .. "/SDCoopSteamLink.exe")
local n0 = #executed
sl2.install(S, MOD, "0.7.0")
check(#executed == n0, "missing exe: nothing started")
check(sl2.status().state == "error" and sl2.status().detail_key == "sl_no_helper", "status: helper missing")
check(sl2.usable() == false, "sdc_session falls back to its own Steam path")
ok, why, key = sl2.join("76561190000000300")
check(not ok and key == "sl_no_helper", "join refused: helper missing")
package.loaded["sdc_steamlink"] = nil
cfg.values.steam_link = false
local sl3 = require("sdc_steamlink")
sl3.install(S, MOD, "0.7.0")
check(sl3.status().state == "off" and #executed == n0, "steam_link = false: off, nothing started")
cfg.values.steam_link = nil

io.write(string.format("mock_steamlink: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
