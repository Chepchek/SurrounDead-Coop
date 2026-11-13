-- SDCoop: joining friends through Steam (no IP, no VPN, no open ports).
--
-- The game keeps its plain UDP net driver (IpNetDriver; GameNetDriver is set
-- to it in memory at start, sdc_netdiag.switch_to_ip). A helper process,
-- Mods\SDCoop\steamlink\SDCoopSteamLink.exe (our own C#, source in
-- tools\steamlink), carries that UDP over Steam's peer-to-peer network
-- (ISteamNetworkingSockets through Steam relays) using the game's own
-- steam_api64.dll:
--   host:   the game listens on UDP 7777 as before; the helper accepts Steam
--           friends (and invited players) and gives each one a local
--           127.0.0.1 socket that talks to port 7777;
--   client: the helper connects to the host's SteamID and opens a local
--           tunnel port; the game does "open 127.0.0.1:<port>" through the
--           usual sdc_session join path.
-- Rich presence (set by the helper while this machine hosts its world):
-- friends see "Join Game" in the Steam friends list; the click (or an invite
-- accepted in the overlay) comes back through the helper and joins here.
-- Started by Steam with "+sdcoop_join <id>" on the command line, the game
-- joins from the main menu (sdc_steam.take_launch_code -> sdc_session.join).
--
-- The helper is started once per game start (os.execute: one short cmd.exe
-- window flash; `--launch` makes it restart itself without the game's
-- inherited handles and return at once) and exits with the game.
-- Files in the helper's folder (see tools\steamlink\Ipc.cs):
--   cmd_<session>_<n>.txt  mod -> helper, one command each (tmp + rename)
--   status.txt             helper -> mod, rewritten every second; read here
--                          once a second in the menus, every 3 s in a world
--                          (6 s while reads are slow), every tick (0.5 s)
--                          only while a join is under way or a command waits
--                          for its answer (status_due, read_gap; [PERF]: one
--                          read costs ~7 ms in the game thread, 0.9.0 still
--                          6-7.5 ms/s at one a second, a client once 274 ms)
--   friends.txt            helper -> mod, friends in SurrounDead right now
--   helper_log.txt         the helper's own log (English, SteamIDs only)
--
-- UI interface (work\steamlink_api.md): status(), friends(), join(id),
-- invite(), invite_friend(id). Nothing here touches engine objects except through
-- sdc_session.join_tunnel from the tick (game thread).
-- Config: steam_link, steam_link_friends_only, steam_link_allow.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")

local M = {}

local EXE_NAME = "SDCoopSteamLink.exe"
local STALE_S = 6          -- status older than this: the helper is not running
local START_GRACE_S = 20   -- after a start: time to come up before it counts as down
local RESTART_GAP_S = 30
local MAX_STARTS = 3
local HOST_OFF_DELAY_S = 8 -- out of the world this long before hosting is withdrawn
local JOIN_WAIT_S = 120    -- a join keeps retrying while the host has no world open
local JOIN_RETRY_S = 6
local JOIN_NO_ANSWER_S = 45
local OPEN_TIMEOUT_S = 75

local L = {
    S = nil, dir = nil, exe = nil, version = "?",
    enabled = false, off_reason = nil, exe_found = false,
    session = "0", seq = 0, req_n = 0,
    starts = 0, started_at = nil, down_logged = false,
    status = nil, status_at = nil, pid = nil,
    friends = {}, friends_seq = nil,
    host_sent = nil, host_sent_at = 0, host_off_since = nil, hosting_toasted = false,
    cfg_sent = nil,
    join = nil,
    invite_seen = 0, pending_invite = nil,
    ip_patched = false,
}
M._L = L   -- tests

-- ---------------------------------------------------------------------------
-- Text: { English (log / EN screen), Russian (screen) }
-- ---------------------------------------------------------------------------

local TEXT = {
    sl_joining      = { "Connecting to %s through Steam...", "Подключение к %s через Steam..." },
    sl_wait_host    = { "%s has not opened a world yet: waiting up to 2 minutes...", "%s ещё не открыл мир — жду до 2 минут..." },
    -- the host's Steam gives no answer at all (helper reason timeout / rendezvous)
    sl_host_silent  = { "%s does not answer through Steam: their game may be closed or may have crashed. Trying again for up to 2 minutes...",
                        "%s не отвечает через Steam — возможно, игра хоста закрыта или вылетела. Пробую снова до 2 минут..." },
    sl_host_silent_left = { "%s does not answer: their game seems to have closed or crashed (you were connected %d s ago). Trying again for up to 2 minutes...",
                        "%s не отвечает — похоже, игра хоста закрылась или вылетела (вы были подключены %d с назад). Пробую снова до 2 минут..." },
    sl_join_failed  = { "Could not connect to %s through Steam: %s.", "Не удалось подключиться к %s через Steam: %s." },
    sl_rejected     = { "%s lets in only Steam friends and invited players.", "%s пускает только друзей в Steam и приглашённых игроков." },
    sl_tunnel_lost  = { "The Steam connection to the host was lost.", "Связь с хостом через Steam потеряна." },
    sl_invite_menu  = { "Steam: to join %s, quit to the main menu - joining starts by itself.",
                        "Steam: чтобы подключиться к %s, выйдите в главное меню — подключение начнётся само." },
    sl_invite_host  = { "Steam: a join request arrived, but you are hosting your own world.",
                        "Steam: пришло приглашение, но вы сейчас хост своего мира." },
    sl_hosting      = { "Steam friends can join you now: Join Game in the Steam friends list.",
                        "Друзья в Steam могут подключиться: «Присоединиться к игре» в списке друзей Steam." },
    sl_no_helper    = { "Steam join is unavailable: SDCoopSteamLink.exe is missing (antivirus?). Reinstall the mod.",
                        "Подключение через Steam недоступно: нет SDCoopSteamLink.exe (антивирус?). Переустановите мод." },
    sl_self         = { "That is your own Steam code.", "Это ваш собственный код Steam." },
    sl_bad_id       = { "Not a Steam code (SteamID64, 17 digits).", "Это не код Steam (SteamID64, 17 цифр)." },
    sl_overlay      = { "The Steam overlay did not open (is it enabled for the game?).",
                        "Оверлей Steam не открылся (включён ли он для игры?)." },
    sl_invite_cmd   = { "The Steam invite could not be handed to the Steam helper.",
                        "Не удалось передать приглашение помощнику Steam." },
    -- status() details
    sl_st_off       = { "Steam join is off (setting steam_link).", "Подключение через Steam выключено (настройка steam_link)." },
    sl_st_starting  = { "Starting the Steam connection...", "Запуск подключения через Steam..." },
    sl_st_relay     = { "Connecting to the Steam network...", "Подключение к сети Steam..." },
    sl_st_ready     = { "Steam: ready.", "Steam: готово." },
    sl_st_hosting   = { "Open to Steam friends · connected: %d", "Открыт для друзей в Steam · подключено: %d" },
    sl_st_waiting   = { "Waiting for %s to open a world...", "Жду, пока %s откроет мир..." },
    sl_st_silent    = { "%s does not answer (game closed or crashed?): trying again...",
                        "%s не отвечает (игра закрыта или вылетела?) — пробую снова..." },
    sl_st_silent_left = { "%s does not answer: the host's game seems to have closed or crashed. Trying again...",
                        "%s не отвечает — похоже, игра хоста закрылась или вылетела. Пробую снова..." },
    sl_st_connected = { "Connected to %s through Steam (ping %s ms)", "Подключено к %s через Steam (пинг %s мс)" },
    sl_st_no_steam  = { "Steam is not available to the helper: start the game from Steam.",
                        "Steam недоступен помощнику: запустите игру через Steam." },
    sl_st_no_dll    = { "The game's steam_api64.dll was not found.", "Не найден steam_api64.dll игры." },
    sl_st_crashed   = { "The Steam helper stopped (see Mods\\SDCoop\\steamlink\\helper_log.txt).",
                        "Помощник Steam остановился (см. Mods\\SDCoop\\steamlink\\helper_log.txt)." },
    sl_st_restart   = { "Restart the game once: the mod changed its network settings.",
                        "Перезапустите игру один раз: мод изменил её сетевые настройки." },
    -- reasons (the second %s of sl_join_failed)
    sl_r_timeout    = { "no answer from the host", "хост не отвечает" },
    sl_r_not_hosting = { "the host has not opened a world", "хост не открыл мир" },
    sl_r_full       = { "the host's world is full", "мир хоста заполнен" },
    sl_r_network    = { "Steam network problem", "проблема сети Steam" },
    sl_r_no_steam   = { "Steam is not available", "Steam недоступен" },
    sl_r_no_helper  = { "the Steam helper does not answer", "помощник Steam не отвечает" },
    sl_r_host_left  = { "the host closed the connection", "хост закрыл соединение" },
    sl_r_error      = { "connection error", "ошибка соединения" },
    -- friends() status
    sl_f_hosting    = { "hosting · SDCoop %s", "открыл мир · SDCoop %s" },
    sl_f_other_ver  = { "hosting · other mod version %s", "открыл мир · другая версия мода %s" },
    sl_f_ingame     = { "in SurrounDead", "в SurrounDead" },
}
M.TEXT = TEXT

-- helper join_reason -> text key
local REASON = {
    timeout = "sl_r_timeout", not_hosting = "sl_r_not_hosting", rendezvous = "sl_r_timeout",
    full = "sl_r_full", nat = "sl_r_network", local_network = "sl_r_network", remote_problem = "sl_r_network",
    no_steam = "sl_r_no_steam", host_left = "sl_r_host_left", idle = "sl_r_host_left",
}
-- failures worth retrying while the host may still be loading its world
local RETRY = { not_hosting = true, timeout = true, rendezvous = true }
-- ... of them, the host's Steam not answering at all: its game (with its
-- helper) is not running - closed, crashed - or the network is in the way.
-- not_hosting: its game runs, the world is not open yet. (13.11: after the
-- host's game crashed, the client said "has not opened a world yet" for 2
-- minutes; every answer had been "timeout".)
local SILENT = { timeout = true, rendezvous = true }
local LEFT_RECENT_S = 180   -- a join this soon after a connection to the same host ended says so

-- The catalog joins sdc_log.TEXT, so log.say / log.tr (and sdc_i18n's
-- language) work for these keys; never with kind "err", so they go to the
-- game's own notification widget (class "game").
if type(log.TEXT) == "table" then
    for k, v in pairs(TEXT) do
        if log.TEXT[k] == nil then log.TEXT[k] = v end
    end
end

local function tr(key, ...)
    if type(log.tr) == "function" and type(log.TEXT) == "table" and log.TEXT[key] then
        local ok, s = pcall(log.tr, key, ...)
        if ok and type(s) == "string" then return s end
    end
    local t = TEXT[key]
    if not t then return key end
    local ok, s = pcall(string.format, t[2], ...)
    return ok and s or t[2]
end
M.tr = tr

local function en(key, ...)
    local t = TEXT[key]
    if not t then return key end
    local ok, s = pcall(string.format, t[1], ...)
    return ok and s or t[1]
end

-- Screen text in the player's language, English log line with `log_args`
-- (SteamIDs instead of names).
local function notify(key, kind, seconds, screen_args, log_args)
    screen_args = screen_args or {}
    log.toast(tr(key, table.unpack(screen_args)), kind, seconds,
        "steamlink: " .. en(key, table.unpack(log_args or screen_args)), key)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function opt(key, default)
    local v = cfg.get(key)
    if v == nil then return default end
    return v
end

local function friends_only() return opt("steam_link_friends_only", true) ~= false end

local function allow_list()
    local out = {}
    for id in tostring(opt("steam_link_allow", "") or ""):gmatch("%d+") do
        if #id == 17 then out[#out + 1] = id end
    end
    return table.concat(out, ",")
end

local function game_port()
    return tonumber(cfg.get("port")) or 7777
end

local function steam_mod()
    local s = package.loaded["sdc_steam"]
    return type(s) == "table" and s or nil
end

local function is_steam_id(s)
    return type(s) == "string" and #s == 17 and s:match("^7656119%d+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

local function path(name) return L.dir .. "/" .. name end

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- One command for the helper: written as .tmp, renamed to a name nobody uses
-- yet (atomic); queued until the helper reads it.
local function send(line)
    if not L.dir then return false end
    L.seq = L.seq + 1
    local base = path(string.format("cmd_%s_%06d", L.session, L.seq))
    local f = io.open(base .. ".tmp", "wb")
    if not f then
        log.warn("steamlink: cannot write a command for the helper (%s)", base)
        return false
    end
    f:write(line, "\n")
    f:close()
    local ok = os.rename(base .. ".tmp", base .. ".txt")
    if not ok then
        os.remove(base .. ".tmp")
        log.warn("steamlink: cannot hand a command to the helper (%s)", line:match("^%S+") or "?")
        return false
    end
    L.sent_t = os.time()   -- its answer comes in status.txt: read it every tick for a while
    log.debug("steamlink: -> helper: %s", line)
    return true
end

local function parse_status(text)
    if type(text) ~= "string" or not text:find("sdcoop_steamlink=1", 1, true) then return nil end
    local st = { peer_list = {} }
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k == "peer" then
            local sid, state, rx, tx, ping = v:match("^(%d+) (%S+) (%-?%d+) (%-?%d+) (%-?%d+)")
            if sid then
                st.peer_list[#st.peer_list + 1] = { id = sid, state = state, rx = tonumber(rx), tx = tonumber(tx), ping = tonumber(ping) }
            end
        elseif k then
            st[k] = v
        end
    end
    return st
end
M._parse_status = parse_status

-- A Steam name as a player name: no control characters or '|' (the net
-- message separator), trimmed, at most 32 characters; nil when empty.
function M.clean_name(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%c|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    local n = utf8 and utf8.len(s)
    if n and n > 32 then s = s:sub(1, utf8.offset(s, 33) - 1) end
    if not n and #s > 64 then s = s:sub(1, 64) end
    return s
end

-- This player's Steam name, once the helper has reported it (nil before / without Steam).
function M.persona()
    return L.persona
end

-- How far apart status.txt is read when nothing waits for the helper's
-- answer (status_due): once a second in the menus, every STATUS_GAME_S in a
-- world, at least SLOW_WAIT_S after a read that took SLOW_READ_MS or more.
-- 13.11 (0.9.0): one read cost the host 7 ms on average (sl:status 6-7.5
-- ms/s at one read a second, max 9-13 ms) and once held a client for 274 ms:
-- the file is opened in the game thread, and the helper rewrites it every
-- second (a virus scanner looks at it again each time).
local STATUS_GAME_S = 3
local SLOW_READ_MS = 30
local SLOW_WAIT_S = 6
local function read_gap()
    local gap = (L.S and L.S.in_menu == false) and STATUS_GAME_S or 1
    if L.read_slow then gap = math.max(gap, SLOW_WAIT_S) end
    return gap
end

-- The helper runs: its status was fresh when it was last read (the helper
-- rewrites it every second), and that read is recent for the current gap.
local function helper_alive(now)
    local st = L.status
    if not st then return false end
    local t = tonumber(st.time)
    if t == nil then return false end
    now = now or os.time()
    local at = L.status_at or now
    return math.abs(at - t) <= STALE_S and now - at <= STALE_S + read_gap()
end

-- Host: the ping (ms, -1 = not measured yet) of a player connected through
-- the Steam link, by SteamID64; nil when that player is not a Steam peer.
function M.peer_ping(sid)
    local st = L.status
    if not st or not sid or not helper_alive() then return nil end
    sid = tostring(sid)
    for _, p in ipairs(st.peer_list or {}) do
        if p.id == sid and p.state == "up" then return (p.ping and p.ping >= 0) and p.ping or -1 end
    end
    return nil
end

-- Host: how many players are connected through the Steam link right now.
function M.peer_count()
    local st = L.status
    if not st or not helper_alive() then return 0 end
    local n = 0
    for _, p in ipairs(st.peer_list or {}) do
        if p.state == "up" then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- The helper process
-- ---------------------------------------------------------------------------

local function file_exists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

local function start_helper(why)
    if not L.enabled or not L.exe_found then return false end
    if L.starts >= MAX_STARTS then return false end
    L.starts = L.starts + 1
    L.started_at = os.time()
    L.down_logged = false
    local exe = L.exe:gsub("/", "\\")
    local args = string.format(" --launch --session %s --mod-version %s --game-port %d --friends-only %d",
        L.session, (tostring(L.version):gsub("[^%w%.%-_]", "")), game_port(), friends_only() and 1 or 0)
    local allow = allow_list()
    if allow ~= "" then args = args .. " --allow " .. allow end
    -- cmd /c ""<exe>" <args>": the outer quotes go, the exe path keeps its own.
    -- cmd.exe flashes a console window once; --launch returns at once.
    local okp, r1, r2, r3 = pcall(os.execute, '""' .. exe .. '"' .. args .. '"')
    log.info("steamlink: helper start #%d (%s): ok=%s %s %s", L.starts, tostring(why), tostring(okp and r1),
        tostring(r2), tostring(r3))
    -- what the old helper knew is gone with it
    L.host_sent, L.cfg_sent = nil, nil
    return okp and r1 == true
end

local function ensure_helper(why, now)
    now = now or os.time()
    if helper_alive(now) then return true end
    if L.started_at and now - L.started_at < START_GRACE_S then return true end
    if L.started_at and now - L.started_at < RESTART_GAP_S then return false end
    return start_helper(why)
end

-- ---------------------------------------------------------------------------
-- Install (main.lua, at load)
-- ---------------------------------------------------------------------------

-- GameNetDriver -> IpNetDriver in memory, before any listen / connect: the
-- game's SteamSockets driver does not come up in this build, and both IP
-- play and the Steam tunnel need plain UDP. (sdc_session switches again
-- before each listen / join; this is the early one.)
local function patch_net_driver()
    if L.ip_patched then return true end
    local okn, nd = pcall(require, "sdc_netdiag")
    if not okn or type(nd) ~= "table" then return false end
    if nd.ip_fallback then
        L.ip_patched = true
        return true
    end
    local ok, changed = pcall(nd.switch_to_ip)
    L.ip_patched = ok and changed == true
    return L.ip_patched
end

function M.install(S, mod_dir, version)
    L.S = S
    L.version = version or "?"
    L.dir = (mod_dir or "ue4ss/Mods/SDCoop") .. "/steamlink"
    L.exe = L.dir .. "/" .. EXE_NAME
    L.session = string.format("%d", os.time())
    ue.game_thread("steamlink-netdriver", function()
        if patch_net_driver() then log.info("steamlink: GameNetDriver set to IpNetDriver at start") end
    end)
    local steam = steam_mod()
    if opt("steam_link", true) == false then
        L.enabled, L.off_reason = false, "config"
        log.info("steamlink: off (config steam_link = false)")
        return
    end
    L.enabled = true
    L.exe_found = file_exists(L.exe)
    if not L.exe_found then
        log.warn("steamlink: %s not found (antivirus?): Steam join is unavailable", L.exe)
        return
    end
    if steam then steam.presence_by_helper = true end
    -- leftovers of a helper that did not exit cleanly
    os.remove(path("status.txt"))
    os.remove(path("friends.txt"))
    start_helper("game start")
end

-- ---------------------------------------------------------------------------
-- Ticks (main.lua's loop, game thread)
-- ---------------------------------------------------------------------------

-- The real main menu (sdc_session.in_real_menu), not the own world without
-- a character: dead / respawn screen, where S.in_menu is true as well.
local function in_real_menu()
    local S = L.S or {}
    if not S.in_menu then return false end
    local session = package.loaded["sdc_session"]
    if type(session) == "table" and type(session.in_real_menu) == "function" then
        local ok, real = pcall(session.in_real_menu)
        return ok and real == true
    end
    return true
end

local function read_status(now)
    L.reads = (L.reads or 0) + 1
    local text = read_file(path("status.txt"))
    local st = parse_status(text)
    if not st then return end
    if st.session ~= "" and st.session ~= L.session then return end
    if st.pid ~= L.pid then
        if L.pid then log.info("steamlink: helper changed (pid %s -> %s)", tostring(L.pid), tostring(st.pid)) end
        L.pid = st.pid
        L.invite_seen = 0
        L.host_sent, L.cfg_sent = nil, nil
        log.info("steamlink: helper %s running (pid %s), Steam %s", tostring(st.version), tostring(st.pid), tostring(st.steam))
    end
    if L.status and L.status.steam ~= st.steam then
        log.info("steamlink: helper Steam state %s -> %s", tostring(L.status.steam), tostring(st.steam))
    end
    L.status = st
    L.status_at = now
    local name = M.clean_name(st.persona)
    if name and name ~= L.persona then
        L.persona = name   -- kept after the helper quits: still this player's Steam name
        log.info("steamlink: Steam name known (%d bytes)", #name)
    end
end
M._read_status = read_status   -- tests

local function friend_name(sid)
    for _, f in ipairs(L.friends) do
        if f.id == sid then return f.name end
    end
    return sid
end

local function config_tick()
    local want = string.format("config friends_only=%d allow=%s version=%s", friends_only() and 1 or 0,
        allow_list(), (tostring(L.version):gsub("[^%w%.%-_]", "")))
    if want ~= L.cfg_sent and send(want) then L.cfg_sent = want end
end

local function hosting_tick(now)
    local S = L.S
    local want = S ~= nil and S.role == "host" and S.in_menu == false
    if want then
        L.host_world = S.world_pc   -- the local controller of the world being hosted
        L.host_menu_logged = nil
    elseif S ~= nil and S.role == "host" and L.host_sent == 1 then
        -- ue.in_main_menu() is also true while the host is dead (no own
        -- character on the menu map): the death / respawn screen is still the
        -- hosted world - same local controller; back in the real main menu the
        -- game has loaded the level again (a new controller). Withdrawing the
        -- Steam hosting there closed every Steam friend's tunnel (0.7.0: a
        -- friend dropped 8 s after the host died). Players still connected keep
        -- it on in any case.
        -- The real main menu (its MenuWidget on screen) keeps the same
        -- controller too: the pause / respawn screen's "Quit to main menu"
        -- only streams the menu level into this world (13.11 19:00: kept as
        -- "death / respawn screen", the friend left falling in a world without
        -- ground). There the world is gone: sdc_session sends the players away
        -- (HOSTMENU) and the Steam hosting goes - at once with nobody
        -- connected, else after HOST_OFF_DELAY_S (their leaving goes through
        -- the tunnel first); a friend's join waits for the host's next world
        -- (not_hosting: sl_wait_host).
        local real_menu = in_real_menu()
        local same_world = not real_menu and L.host_world ~= nil and S.world_pc == L.host_world
        local players = #(S.remote_pcs or {}) > 0
        if same_world or (players and not real_menu) then
            want = true
            if not L.host_kept_logged then
                L.host_kept_logged = true
                log.info("steamlink: hosting kept while the host is out of its character (%s)",
                    same_world and "same world: death / respawn screen" or "players still connected")
            end
        elseif real_menu then
            if not L.host_menu_logged then
                L.host_menu_logged = true
                log.info("steamlink: the host is in its main menu: Steam hosting withdrawn %s",
                    players and string.format("in %d s (the players are told to leave first)", HOST_OFF_DELAY_S)
                        or "now (nobody connected)")
            end
            if not players then L.host_off_since = math.min(L.host_off_since or now, now - HOST_OFF_DELAY_S) end
        end
    end
    if want then
        if S.in_menu == false then L.host_kept_logged = nil end
        if L.host_off_since then log.info("steamlink: hosting stays on (back within %d s)", now - L.host_off_since) end
        L.host_off_since = nil
        if L.host_sent ~= 1 then
            if send("host 1 " .. game_port()) then
                L.host_sent, L.host_sent_at = 1, now
                log.info("steamlink: hosting on (game port %d)", game_port())
                ensure_helper("hosting", now)
            end
        end
    elseif L.host_sent == 1 then
        -- a short trip through a loading screen must not drop everyone
        L.host_off_since = L.host_off_since or now
        if now - L.host_off_since >= HOST_OFF_DELAY_S and send("host 0") then
            L.host_sent, L.host_sent_at = 0, now
            L.hosting_toasted = false
            log.info("steamlink: hosting off")
        end
    end
    local st = L.status
    if st and helper_alive(now) and st.steam == "ok" then
        -- the helper restarted or missed it: say it again
        if L.host_sent ~= nil and tonumber(st.hosting) ~= L.host_sent and now - L.host_sent_at >= 5 then
            if send("host " .. (L.host_sent == 1 and ("1 " .. game_port()) or "0")) then L.host_sent_at = now end
        end
        if L.host_sent == 1 and st.listen == "1" and not L.hosting_toasted then
            L.hosting_toasted = true
            notify("sl_hosting", "ok", 8)
        end
    end
end
M._hosting_tick = hosting_tick   -- tests

local function clear_join(why)
    if L.join then log.info("steamlink: join to %s ended (%s)", tostring(L.join.sid), tostring(why)) end
    L.join = nil
end

local function send_join(now)
    local j = L.join
    L.req_n = L.req_n + 1
    j.req = L.session .. "-" .. L.req_n
    j.attempt = (j.attempt or 0) + 1
    j.sent_at = now
    j.retry_at = nil
    ensure_helper("join", now)
    send("join " .. j.sid .. " " .. j.req)
end

local function fail_join(reason_key, name, sid)
    notify("sl_join_failed", "warn", 10, { name, tr(reason_key) }, { sid, en(reason_key) })
    clear_join(reason_key)
end

local function join_tick(now)
    local j = L.join
    if not j then return end
    local S = L.S or {}
    local st = L.status
    local mine = st and st.join_req == j.req
    if S.role == "client" then
        if not j.connected then log.info("steamlink: in the host's world through the Steam tunnel") end
        j.connected = true
        if mine and st.join_state == "closed" and not j.lost_toasted then
            j.lost_toasted = true
            notify("sl_tunnel_lost", "warn", 10)
        end
        return
    end
    if j.connected then
        -- left the host (or the connection dropped): close the tunnel
        send("leave")
        L.left = { sid = j.sid, t = now }   -- a join to it soon after that gets no answer: its game is gone
        clear_join("left the host")
        return
    end
    if j.opened then
        if mine and (st.join_state == "closed" or st.join_state == "failed") then
            send("leave")
            fail_join(REASON[st.join_reason] or "sl_r_error", j.name, j.sid)
        elseif now - j.opened_at > OPEN_TIMEOUT_S and not ue.has_pending_connection() then
            send("leave")
            clear_join("the game did not connect through the tunnel")
        end
        return
    end
    if j.retry_at then
        if now >= j.retry_at then send_join(now) end
        return
    end
    if not mine then
        if now - (j.sent_at or now) > JOIN_NO_ANSWER_S then fail_join("sl_r_no_helper", j.name, j.sid) end
        return
    end
    if st.join_state == "connecting" and now - (j.sent_at or now) > JOIN_NO_ANSWER_S + 15 then
        -- the helper's own limit is 30 s; this one covers "waiting for Steam"
        send("leave")
        fail_join("sl_r_timeout", j.name, j.sid)
        return
    end
    if st.join_state == "ready" then
        local port = tonumber(st.join_port)
        local session = package.loaded["sdc_session"]
        if not port or port <= 0 or type(session) ~= "table" or not session.join_tunnel then
            send("leave")
            fail_join("sl_r_error", j.name, j.sid)
            return
        end
        j.opened, j.opened_at = true, now
        log.info("steamlink: tunnel to %s ready on 127.0.0.1:%d (attempt %d)", j.sid, port, j.attempt or 1)
        local ok, res = pcall(session.join_tunnel, port, j.sid)
        if not ok or res == false then
            if not ok then log.err("steamlink: join through the tunnel: %s", tostring(res)) end
            send("leave")
            clear_join("the game refused to join")
        end
    elseif st.join_state == "failed" then
        local reason = st.join_reason or ""
        if reason == "not_friend" then
            notify("sl_rejected", "warn", 10, { j.name }, { j.sid })
            clear_join("rejected by the host")
        elseif reason == "self" then
            notify("sl_self", "warn", 6)
            clear_join("own id")
        elseif RETRY[reason] and now < j.deadline then
            j.retry_at = now + JOIN_RETRY_S
            j.silent = SILENT[reason] == true
            if j.silent then
                -- no answer at all: not "has not opened a world yet"
                if not j.silent_toasted then
                    j.silent_toasted = true
                    local left = L.left
                    if left and left.sid == j.sid and now - left.t <= LEFT_RECENT_S then
                        j.silent_left = true
                        notify("sl_host_silent_left", "warn", 10, { j.name, now - left.t }, { j.sid, now - left.t })
                    else
                        notify("sl_host_silent", "warn", 10, { j.name }, { j.sid })
                    end
                end
            elseif not j.wait_toasted then
                j.wait_toasted = true
                notify("sl_wait_host", "info", 8, { j.name }, { j.sid })
            end
            log.info("steamlink: join to %s: %s, retrying in %d s", j.sid, reason, JOIN_RETRY_S)
        else
            fail_join(REASON[reason] or "sl_r_error", j.name, j.sid)
        end
    end
end

local function own_id()
    local st = L.status
    if st and is_steam_id(st.steamid) then return st.steamid end
    local steam = steam_mod()
    return steam and steam.id or nil
end

local function handle_invite(host, now)
    local S = L.S or {}
    if host == own_id() then return end
    log.info("steamlink: Steam join request for host %s (role %s, %s)", host, tostring(S.role),
        S.in_menu and "main menu" or "in a world")
    if S.role == "client" then
        if L.join and L.join.sid == host then return end
        M.join(host)   -- says why it cannot
    elseif in_real_menu() then
        M.join(host)
    elseif S.role == "host" then
        notify("sl_invite_host", "warn", 10)
    else
        -- a single-player world: never leave it unsaved; join from the menu
        L.pending_invite = { sid = host, until_t = now + 300 }
        notify("sl_invite_menu", "info", 12, { friend_name(host) }, { host })
    end
end

local function invite_tick(now)
    local st = L.status
    if st then
        local seq = tonumber(st.invite_seq) or 0
        if seq > L.invite_seen then
            L.invite_seen = seq
            if is_steam_id(st.invite_host) then handle_invite(st.invite_host, now) end
        end
    end
    local p = L.pending_invite
    if p then
        local S = L.S or {}
        if now > p.until_t then
            L.pending_invite = nil
        elseif S.role ~= "client" and in_real_menu() then
            -- the real main menu: a death in the single-player world is not it
            L.pending_invite = nil
            M.join(p.sid)
        end
    end
end

local function parse_friends(text)
    if type(text) ~= "string" then return nil, nil end
    local seq = text:match("^seq=(%d+)")
    if not seq then return nil, nil end
    local list = {}
    for line in text:gmatch("[^\n]+") do
        local id, host, ver, name = line:match("^(%d+)\t([01])\t([^\t]*)\t(.*)$")
        if id then
            name = name:gsub("\r$", "")
            list[#list + 1] = { id = id, joinable = host == "1", version = ver ~= "" and ver or nil,
                name = name ~= "" and name or id }
        end
    end
    table.sort(list, function(a, b)
        if a.joinable ~= b.joinable then return a.joinable end
        return a.name:lower() < b.name:lower()
    end)
    return list, seq
end
M._parse_friends = parse_friends

-- A file read timed into sdc_ue's [PERF] "parts" ("sl:status", "sl:friends":
-- the steamlink task's share that reads files; the rest of the tick reads
-- none). A read of SLOW_READ_MS or more (either file: the same folder, the
-- same virus scanner) spaces the next status reads out (read_gap), logged
-- once and then at most every SLOW_LOG_S. Only a fast status.txt read ends
-- that: a quick friends.txt read in the same tick (the list changed) must not
-- cut short the pause a slow status read has just set (skeptic, 13.11 item 18).
local SLOW_LOG_S = 600
local function timed(label, fn, ...)
    local t0 = os.clock()
    local a, b = fn(...)
    local ms = (os.clock() - t0) * 1000
    local ss = ue.sub_stats
    if type(ss) == "table" then
        local s = ss[label]
        if not s then s = { calls = 0, ms = 0, wmax = 0 }; ss[label] = s end
        s.calls, s.ms = s.calls + 1, s.ms + ms
        if ms > (s.wmax or 0) then s.wmax = ms end
    end
    if ms >= SLOW_READ_MS then
        local now = os.time()
        if not L.slow_logged or now - L.slow_logged >= SLOW_LOG_S then
            L.slow_logged = now
            log.warn("steamlink: reading the helper's %s took %.0f ms (a virus scanner on the mod folder?);"
                .. " status.txt is read at most every %d s while reads are this slow",
                (label:gsub("^sl:", "")) .. ".txt", ms, SLOW_WAIT_S)
        end
        L.read_slow = true
    elseif label == "sl:status" then
        L.read_slow = false
    end
    return a, b
end

local function friends_tick()
    local st = L.status
    if not st or st.friends_seq == L.friends_seq then return end
    local list, seq = parse_friends(timed("sl:friends", read_file, path("friends.txt")))
    if list and seq == st.friends_seq then
        L.friends = list
        L.friends_seq = seq
    elseif st.friends_seq == "0" then
        L.friends, L.friends_seq = {}, "0"
    end
end

local function watch_helper(now)
    if helper_alive(now) then
        L.down_logged = false
        return
    end
    if L.started_at and now - L.started_at < START_GRACE_S then return end
    if not L.down_logged then
        L.down_logged = true
        log.warn("steamlink: the helper is not running (starts so far: %d); see %s", L.starts, path("helper_log.txt"))
    end
    -- bring it back only when it is needed right now
    local needed = L.host_sent == 1 or L.join ~= nil
    if needed then ensure_helper("needed again", now) end
end

-- Read status.txt on this tick? Every tick (0.5 s) while a join is under
-- way (its steps come ~100 ms apart) or for SENT_FAST_S after a command (its
-- answer: hosting, invite); else every read_gap() seconds (1 s in the menus,
-- 3 s in a world, 6 s after a slow read).
local SENT_FAST_S = 2
local function status_due(now)
    local j = L.join
    if j and not j.connected then return true end
    if L.sent_t ~= nil and now - L.sent_t <= SENT_FAST_S then return true end
    local last = L.read_t
    return last == nil or now < last or now - last >= read_gap()
end
M._status_due = status_due   -- tests
M._helper_alive = helper_alive   -- tests

function M.tick()
    if not L.ip_patched then patch_net_driver() end
    if not L.enabled or not L.exe_found then return end
    local now = os.time()
    if status_due(now) then
        L.read_t = now
        timed("sl:status", read_status, now)
    end
    config_tick()
    hosting_tick(now)
    join_tick(now)
    invite_tick(now)
    friends_tick()
    watch_helper(now)
end

-- ---------------------------------------------------------------------------
-- sdc_session.join -> here (a friend's Steam code)
-- ---------------------------------------------------------------------------

-- Can a Steam code be joined through the helper? (else sdc_session says why
-- not: status().detail_key sl_st_off / sl_no_helper)
function M.usable()
    return L.enabled and L.exe_found
end

local function restart_needed()
    local steam = steam_mod()
    return steam ~= nil and steam.server_api_pending == true
end

function M.request_tunnel(sid)
    if not M.usable() then return false, "off" end
    if not is_steam_id(sid) then return false, "bad_id" end
    local now = os.time()
    if L.join and L.join.sid == sid and not L.join.connected then return true end   -- already on it
    if restart_needed() then
        notify("sl_st_restart", "warn", 10)
        return false, "restart"
    end
    if sid == own_id() then
        notify("sl_self", "warn", 6)
        return false, "self"
    end
    L.join = { sid = sid, name = friend_name(sid), deadline = now + JOIN_WAIT_S, attempt = 0 }
    send_join(now)
    notify("sl_joining", "info", 6, { L.join.name }, { sid })
    return true
end

-- Stops a Steam join whose tunnel is still being built or retried (the game
-- is not connecting through it yet): for a Cancel on the join screen and
-- the console (sdcoop_steam cancel). Returns true when one was stopped.
function M.cancel(why)
    local j = L.join
    if not j or j.connected or j.opened then return false end
    send("leave")
    clear_join(why or "cancelled")
    return true
end

-- ---------------------------------------------------------------------------
-- UI interface (work\steamlink_api.md)
-- ---------------------------------------------------------------------------

local function detail(s, key, ...)
    s.detail_key = key
    s.detail = tr(key, ...)
    return s
end

function M.status()
    local now = os.time()
    local st = L.status
    local alive = helper_alive(now)
    local s = { state = "off", friends_only = friends_only(), peers = 0, restart_needed = restart_needed(),
        helper = alive, steamid = own_id() }
    if alive then s.peers = tonumber(st.peers) or 0 end
    if not L.enabled then
        s.state = "off"
        return detail(s, "sl_st_off")
    end
    if not L.exe_found then
        s.state = "error"
        return detail(s, "sl_no_helper")
    end
    if s.restart_needed then
        s.state = "error"
        return detail(s, "sl_st_restart")
    end
    if not alive then
        if L.starts >= MAX_STARTS or (L.started_at and now - L.started_at >= START_GRACE_S) then
            s.state = "error"
            return detail(s, "sl_st_crashed")
        end
        s.state = "starting"
        return detail(s, "sl_st_starting")
    end
    if st.steam == "starting" then
        s.state = "starting"
        return detail(s, "sl_st_starting")
    elseif st.steam == "no_dll" then
        s.state = "no_steam"
        return detail(s, "sl_st_no_dll")
    elseif st.steam ~= "ok" then
        s.state = "no_steam"
        return detail(s, "sl_st_no_steam")
    end
    local j = L.join
    if j then
        if st.join_req == j.req and st.join_state == "ready" then
            s.state = "connected"
            local ping = tonumber(st.join_ping)
            return detail(s, "sl_st_connected", j.name, (ping and ping >= 0) and tostring(ping) or "?")
        end
        s.state = "joining"
        s.silent = j.silent == true   -- the host's Steam gives no answer (its game closed / crashed?)
        if j.silent then return detail(s, j.silent_left and "sl_st_silent_left" or "sl_st_silent", j.name) end
        if j.retry_at or j.wait_toasted then return detail(s, "sl_st_waiting", j.name) end
        return detail(s, "sl_joining", j.name)
    end
    if st.listen == "1" then
        s.state = "hosting"
        return detail(s, "sl_st_hosting", s.peers)
    end
    if tonumber(st.relay) ~= 100 then
        s.state = "starting"
        return detail(s, "sl_st_relay")
    end
    s.state = "ready"
    return detail(s, "sl_st_ready")
end

-- Friends in SurrounDead right now (cached; joinable first, then by name).
function M.friends()
    local out = {}
    for i, f in ipairs(L.friends) do
        local status
        if f.joinable then
            status = (f.version == L.version) and tr("sl_f_hosting", f.version or "?")
                or tr("sl_f_other_ver", f.version or "?")
        else
            status = tr("sl_f_ingame")
        end
        out[i] = { id = f.id, name = f.name, joinable = f.joinable, version = f.version, status = status }
    end
    return out
end

local function refuse(key)
    return false, tr(key), key
end

-- Join friend `id` (SteamID64) through Steam, by the usual join path.
function M.join(id)
    id = tostring(id or ""):match("^%s*(%d+)%s*$")
    if not L.enabled then return refuse("sl_st_off") end
    if not L.exe_found then return refuse("sl_no_helper") end
    if not is_steam_id(id) then return refuse("sl_bad_id") end
    if id == own_id() then return refuse("sl_self") end
    if restart_needed() then return refuse("sl_st_restart") end
    local S = L.S or {}
    if S.role == "client" then return refuse("already_client") end
    -- a dead host is still in its world (clients connected, progress unsaved)
    if S.role == "host" and not in_real_menu() then return refuse("host_cannot_join") end
    if L.join and L.join.sid == id and not L.join.connected then return true end
    local session = package.loaded["sdc_session"]
    if type(session) ~= "table" or not session.join then return false, "no session", "no_session" end
    L.pending_invite = nil
    -- sdc_session.join: co-op character check, then request_tunnel (above)
    local ok, err = pcall(session.join, id, game_port(), false)
    if not ok then
        log.err("steamlink: join %s: %s", id, tostring(err))
        return refuse("sl_r_error")
    end
    return true
end

-- Steam overlay invite dialog (the game's SteamCore; connect string
-- "+sdcoop_join <own id>").
function M.invite()
    if not L.enabled then return refuse("sl_st_off") end
    local steam = steam_mod()
    if not steam or not steam.invite then return refuse("sl_st_no_steam") end
    local ok, why = steam.invite()
    if ok then return true end
    return refuse(why == "no_steam" and "sl_st_no_steam" or "sl_overlay")
end

-- Host: a Steam invite to friend `id` (SteamID64) by the helper ("invite":
-- Steam sends it, the helper lets that player in). Unlike the overlay
-- dialog the mod knows who it is: the panel puts the friend on the host's
-- allowed list (sdc_admin, join_access "invite only").
function M.invite_friend(id)
    id = tostring(id or ""):match("^%s*(%d+)%s*$")
    if not L.enabled then return refuse("sl_st_off") end
    if not L.exe_found then return refuse("sl_no_helper") end
    if not is_steam_id(id) then return refuse("sl_bad_id") end
    if id == own_id() then return refuse("sl_self") end
    if not send("invite " .. id) then return refuse("sl_invite_cmd") end
    log.info("steamlink: Steam invite to %s (sent by the helper)", id)
    return true
end

-- One line for sdcoop_status / logs.
function M.status_line()
    local s = M.status()
    return string.format("steamlink: %s (%s) helper=%s peers=%d friends=%d", s.state, tostring(s.detail_key),
        tostring(s.helper), s.peers or 0, #L.friends)
end

-- Console: sdcoop_steam [friends | join <n|SteamID> | invite | cancel]
function M.console(params, reply)
    local a1, a2 = params[1], params[2]
    a1 = a1 and tostring(a1) or nil
    if a1 == "friends" then
        local list = M.friends()
        if #list == 0 then reply("no friends in SurrounDead right now") end
        for i, f in ipairs(list) do
            reply(string.format("%d: %s %s%s", i, f.id, f.joinable and "[hosting] " or "", f.status or ""))
        end
    elseif a1 == "join" then
        local target = a2 and tostring(a2) or ""
        local n = tonumber(target)
        if n and n < 100 then
            local f = M.friends()[n]
            target = f and f.id or ""
        end
        local ok, why = M.join(target)
        reply(ok and ("joining " .. target) or ("cannot join: " .. tostring(why)))
    elseif a1 == "invite" then
        local ok, why = M.invite()
        reply(ok and "invite dialog opened" or ("invite: " .. tostring(why)))
    elseif a1 == "cancel" then
        reply(M.cancel("cancelled from the console") and "Steam join cancelled" or "no Steam join to cancel")
    else
        reply(M.status_line())
        local s = M.status()
        if s.detail then reply("  " .. s.detail) end
    end
end

return M
