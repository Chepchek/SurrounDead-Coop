-- SDCoop: logging and player-facing notifications.
--
-- UE4SS print() does not append a newline, so every line gets one here.
-- Notifications ("toasts") go to the UE4SS log and to whatever sink the UI
-- registers; PrintString is compiled out of shipping builds, so the mod draws
-- its own on-screen text (see sdc_ui.lua).

local M = {
    tag = "SDCoop",
    debug_enabled = false,
    probes_enabled = false,   -- heavy per-frame movement probes (config debug_probes)
    net_enabled = false,      -- every network message in the log (config debug_net)
    toast_sink = nil,
}

local function fmt(msg, ...)
    if select("#", ...) == 0 then return tostring(msg) end
    local ok, s = pcall(string.format, msg, ...)
    if ok then return s end
    local parts = { tostring(msg) }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

-- UE4SS.log / the UE4SS console cannot show Cyrillic (it comes out as "???"),
-- so everything written there is English, and any Cyrillic that still slips
-- through (player names) is transliterated. On-screen text stays Russian.
local TRANSLIT = {
    [0x410] = "A", [0x411] = "B", [0x412] = "V", [0x413] = "G", [0x414] = "D", [0x415] = "E",
    [0x416] = "Zh", [0x417] = "Z", [0x418] = "I", [0x419] = "Y", [0x41A] = "K", [0x41B] = "L",
    [0x41C] = "M", [0x41D] = "N", [0x41E] = "O", [0x41F] = "P", [0x420] = "R", [0x421] = "S",
    [0x422] = "T", [0x423] = "U", [0x424] = "F", [0x425] = "Kh", [0x426] = "Ts", [0x427] = "Ch",
    [0x428] = "Sh", [0x429] = "Shch", [0x42A] = "", [0x42B] = "Y", [0x42C] = "", [0x42D] = "E",
    [0x42E] = "Yu", [0x42F] = "Ya", [0x401] = "Yo",
}
for cp = 0x410, 0x42F do
    local up = TRANSLIT[cp]
    if up then TRANSLIT[cp + 0x20] = up:lower() end
end
TRANSLIT[0x451] = "yo"
local PUNCT = { [0x2014] = "-", [0x2013] = "-", [0xAB] = "\"", [0xBB] = "\"", [0x2026] = "...", [0xB7] = "|" }

function M.ascii(s)
    if not s:find("[\128-\255]") then return s end
    local ok, out = pcall(function()
        local parts = {}
        for _, cp in utf8.codes(s) do
            if cp < 128 then
                parts[#parts + 1] = string.char(cp)
            else
                parts[#parts + 1] = TRANSLIT[cp] or PUNCT[cp] or "?"
            end
        end
        return table.concat(parts)
    end)
    if ok then return out end
    return (s:gsub("[\128-\255]", "?"))
end

-- ---------------------------------------------------------------------------
-- Writing to UE4SS.log
-- ---------------------------------------------------------------------------
-- UE4SS's print() writes each line to UE4SS.log synchronously on the calling
-- (game) thread (WriteFile, no buffering). On a friend's machine (client,
-- 2026-11-10, 0.6.46) every one of 15 freezes of 1-9 s began right after a
-- line had been time-stamped by UE4SS and before print() returned - where the
-- Lua collector cannot run - while the host (same mod, more lines) never
-- froze: that machine holds some file writes for seconds (disk, a scanner or
-- write throttling). So:
--   * every write is timed; one that held the game >= SLOW_WRITE_MS is
--     reported ("[SLOWLOG] ...", with what the mod was doing);
--   * after such a write (or from the start with log_batch_always) lines are
--     collected and written together at most every log_flush_ms (config;
--     0 = never batch) from the per-frame loop (M.tick): one write instead of
--     several a second (and of thousands in a burst). Every batched line
--     keeps its own time stamp in UE4SS's format; each batch starts with a
--     "[LOG] batch" line that UE4SS stamps with the write time. Warnings and
--     errors are written at once (with the lines before them).
local clock = os.clock
M.SLOW_WRITE_MS = 100
M.flush_ms = 1000          -- sdc_config: log_flush_ms
M.batch_always = false     -- sdc_config: log_batch_always
-- totals since start ([PERF]); see also take_worst_write
M.writes = { n = 0, lines = 0, bytes = 0, ms = 0, max = 0, slow = 0 }
-- the slowest write since sdc_diag last took it
local worst = { ms = 0 }
-- what the mod is doing right now (sdc_ue sets it: "task 'x', part y" / "hook z")
M.activity = nil
-- batch state: buffered lines, the clock calibration for their time stamps
local W = { buf = {}, n = 0, bytes = 0, first = 0, last_write = 0, batch = false,
            offset = nil, last_sec = nil, prev_ms = 0, slow_note = nil }

local function activity()
    local f = M.activity
    if type(f) ~= "function" then return "?" end
    local ok, s = pcall(f)
    return ok and tostring(s) or "?"
end

local function batching()
    return (W.batch or M.batch_always) and W.offset ~= nil and (tonumber(M.flush_ms) or 0) > 0
end

-- "[2026-11-10 20:46:24.3504467] " like UE4SS (local time; offset from M.tick)
local function stamp(c)
    local wall = c + W.offset
    local sec = math.floor(wall)
    return string.format("[%s.%07d] ", os.date("%Y-%m-%d %H:%M:%S", sec), math.floor((wall - sec) * 1e7))
end

local function first_line(s)
    return (s:sub(1, 120):gsub("\n.*", ""))
end

-- One print() = one UE4SS.log write, timed.
local function write(s, lines)
    local t0 = clock()
    print(s)
    local t1 = clock()
    local ms = (t1 - t0) * 1000
    local w = M.writes
    w.n, w.lines, w.bytes, w.ms = w.n + 1, w.lines + lines, w.bytes + #s, w.ms + ms
    if ms > w.max then w.max = ms end
    W.last_write, W.prev_ms = t1, ms
    local slow = ms >= M.SLOW_WRITE_MS
    local what = slow and activity() or nil
    if ms > worst.ms then
        worst = { ms = ms, at = t1, lines = lines, text = first_line(s), activity = what }
    end
    if slow then
        w.slow = w.slow + 1
        local switch = not W.batch and not M.batch_always and (tonumber(M.flush_ms) or 0) > 0
        if switch then W.batch = true end
        -- written by emit right after this line (or queued with the batch)
        W.slow_note = string.format("[SLOWLOG] writing %d line(s) (%d bytes) to UE4SS.log held the game for %.0f ms"
            .. " (during %s; the line: '%s')%s", lines, #s, ms, what, first_line(s),
            switch and string.format("; from now on log lines are written in batches, at most one write every %d ms",
                M.flush_ms) or "")
    end
end

local function flush()
    if W.n == 0 then return end
    local n = W.n
    W.buf[0] = string.format("[%s] [LOG] batch: %d line(s) of the last %.1f s (previous write %.0f ms)\n",
        M.tag, n, clock() - W.first, W.prev_ms)
    local s = table.concat(W.buf, "", 0, n)
    W.buf, W.n, W.bytes = {}, 0, 0
    write(s, n + 1)
end

local function queue(line, now)
    local c = clock()
    if W.n == 0 then W.first = c end
    local entry = stamp(c) .. "[Lua] " .. line
    W.n = W.n + 1
    W.buf[W.n] = entry
    W.bytes = W.bytes + #entry
    if now or W.n >= 200 or W.bytes >= 32768 then flush() end
end

local function emit(level, text)
    local line = string.format("[%s]%s %s\n", M.tag, level, M.ascii(text))
    if batching() then
        queue(line, level == "[WARN]" or level == "[ERROR]")
    else
        write(line, 1)
    end
    local note = W.slow_note
    if note then
        W.slow_note = nil
        line = string.format("[%s][WARN] %s\n", M.tag, note)
        if batching() then queue(line, false) else write(line, 1) end
    end
end

-- Every frame (main.lua). Calibrates the batch time stamps: at each edge of
-- os.time()'s second, os.time() - os.clock() is at most the true offset
-- (seen up to a frame late); the largest recent value is kept, lowered by
-- 1 ms a second so it follows clock drift, reset on a jump. Then writes the
-- batch when it is due. Cheap when there is nothing to do.
function M.tick()
    local c = clock()
    local t = os.time()
    if t ~= W.last_sec then
        if W.last_sec then
            local off = t - c
            local cur = W.offset
            if not cur or off < cur - 0.5 then
                W.offset = off
            else
                W.offset = math.max(off, cur - 0.001)
            end
        end
        W.last_sec = t
    end
    if W.n > 0 and (c - W.last_write) * 1000 >= (tonumber(M.flush_ms) or 0) then flush() end
end

-- Writes the collected lines now (level change).
function M.flush()
    flush()
end

function M.batching()
    return batching()
end

-- The slowest write since the last call ({ ms, at, lines, text, activity }),
-- then starts a new period (sdc_diag's [HITCH]).
function M.take_worst_write()
    local w = worst
    worst = { ms = 0 }
    return w
end

function M.info(msg, ...) emit("", fmt(msg, ...)) end
function M.warn(msg, ...) emit("[WARN]", fmt(msg, ...)) end
function M.err(msg, ...) emit("[ERROR]", fmt(msg, ...)) end
function M.debug(msg, ...)
    if M.debug_enabled then emit("[DBG]", fmt(msg, ...)) end
end

-- One error line per `key` (the caller's stable key, not the message text,
-- which can carry changing names / numbers) every 30 s, so a broken tick
-- cannot flood UE4SS.log. The next line says how many were held back.
local throttle = {}   -- [key] = { at = os.time(), suppressed = n }
function M.err_throttled(key, msg, ...)
    local now = os.time()
    local k = tostring(key)
    local t = throttle[k]
    if t and now - t.at < 30 then
        t.suppressed = t.suppressed + 1
        return
    end
    local text = fmt(msg, ...)
    if t and t.suppressed > 0 then
        text = string.format("%s (%d more since the last report)", text, t.suppressed)
    end
    throttle[k] = { at = now, suppressed = 0 }
    emit("[ERROR]", text)
end

-- Screen language (sdc_i18n sets both; nil = Russian as written):
--   screen_text(text) -> the toast text for the screen (Russian -> English)
--   screen_say(key, entry, ...) -> a catalog message for the screen, or nil
M.screen_text = nil
M.screen_say = nil

local function for_screen(text)
    local f = M.screen_text
    if not f then return text end
    local ok, s = pcall(f, text)
    if ok and type(s) == "string" then return s end
    return text
end

local function say_text(key, t, ...)
    local f = M.screen_say
    if f then
        local ok, s = pcall(f, key, t, ...)
        if ok and type(s) == "string" then return s end
    end
    return fmt(t[2], ...)
end

-- Where a notification goes (sdc_i18n sets classify(text, kind, key) ->
-- "game" | "mod"; sdc_ui sets mod_sink):
--   "game" -> toast_sink: gameplay events, the game's own notification
--             widget (sdc_lobby; the overlay where there is no HUD);
--   "mod"  -> mod_sink: the mod's toast in the panel's style (connection,
--             versions, saves, the mod's warnings and errors).
M.classify = nil
M.mod_sink = nil

local function class_of(text, kind, key)
    local f = M.classify
    if not f then return "game" end
    local ok, c = pcall(f, text, kind, key)
    if ok and (c == "game" or c == "mod") then return c end
    return "game"
end

-- On-screen notification. `kind` is "info" | "ok" | "warn" | "err".
-- `log_text` is what goes to UE4SS.log (English); defaults to `text`.
-- `key`: the catalog key (log.say), used to pick the route.
function M.toast(text, kind, seconds, log_text, key)
    emit("[TOAST]", log_text or text)
    local class = class_of(text, kind, key)
    local sink = M.toast_sink
    if class == "mod" and M.mod_sink then sink = M.mod_sink end
    if sink then
        local ok, e = pcall(sink, for_screen(text), kind or "info", seconds or 6, class)
        if not ok then emit("[ERROR]", "toast sink: " .. tostring(e)) end
    end
end

-- Message catalog: key = { English (log), Russian (screen) }.
M.TEXT = {
    menu_listen       = { "Opening the world for friends: the menu reloads, then load your save (Continue / Load).",
                          "Открываю мир для друзей: меню перезагрузится, затем загрузите сохранение (Continue / Load)." },
    already_host      = { "The server is already running. Friends join through Steam or by your IP, port 7777 (UDP).",
                          "Сервер уже запущен. Друзья подключаются через Steam или по вашему IP, порт 7777 (UDP)." },
    is_client         = { "You are connected to another server. Disconnect first.",
                          "Вы подключены к чужому серверу. Сначала отключитесь." },
    single_world      = { "This world was loaded as single player. Save, quit to the main menu (it reopens for friends), then press Continue.",
                          "Этот мир загружен как одиночный. Сохранитесь и выйдите в главное меню — оно откроется для друзей, затем нажмите Continue." },
    server_needs_solo = { "A server can only be started from single player.",
                          "Сервер можно запустить только из одиночной игры." },
    server_starting   = { "Starting a server on %s...", "Запуск сервера на %s..." },
    already_client    = { "Already connected to a server.", "Уже подключено к серверу." },
    host_cannot_join  = { "You are hosting. Quit to the main menu to join a friend.",
                          "Вы сейчас хост. Чтобы подключиться к другу, выйдите в главное меню." },
    need_ip           = { "Enter the host IP.", "Укажите IP хоста." },
    connecting        = { "Connecting to %s...", "Подключение к %s..." },
    disconnecting     = { "Disconnecting...", "Отключение..." },
    host_quit_hint    = { "To close the server, quit to the main menu from the game menu; saving works as usual.",
                          "Чтобы закрыть сервер, выйдите в главное меню через меню игры — сохранение пройдёт как обычно." },
    no_connection     = { "No active connection.", "Нет активного подключения." },
    player_connecting = { "A player is connecting...", "Игрок подключается..." },
    player_joined     = { "%s joined.", "%s подключился." },
    player_left       = { "%s left.", "%s отключился." },
    no_local_pawn     = { "No local character.", "Нет локального персонажа." },
    listen_failed     = { "Could not open the world for friends. See UE4SS.log; try 'New server world'.",
                          "Не удалось открыть мир для друзей. Подробности в UE4SS.log; попробуйте «Новый мир-сервер»." },
    server_started    = { "Server started. Friends join through Steam (Join Game) or by your IP, port 7777 (UDP).",
                          "Сервер запущен. Друзья подключаются через Steam («Присоединиться к игре») или по вашему IP, порт 7777 (UDP)." },
    connected         = { "Connected to the server.", "Подключено к серверу." },
    connected_to      = { "Connected to %s.", "Подключено к %s." },
    disconnected      = { "You left the server.", "Вы отключились от сервера." },
    connection_lost   = { "Connection to the host was lost.", "Соединение с хостом потеряно." },
    server_closed     = { "Server closed.", "Сервер закрыт." },
    peer_version      = { "%s runs mod version %s, you run %s.", "У %s другая версия мода (%s, у вас %s)." },
    host_version      = { "Mod versions differ: host %s, you %s.", "Версии мода отличаются: у хоста %s, у вас %s." },
    you_died          = { "You died. Use 'Respawn near host' in the co-op menu.",
                          "Вы погибли. Нажмите «Возродиться рядом с хостом» в меню кооператива." },
    respawning        = { "Respawning...", "Возрождение..." },
    settings_saved    = { "Settings saved.", "Настройки сохранены." },
    settings_failed   = { "Could not save settings.", "Не удалось сохранить настройки." },
    -- labels of buttons placed into the game's own screens
    btn_respawn_host   = { "Respawn - Near Host", "Возрождение — рядом с хостом" },
    btn_respawn_random = { "Respawn - Random", "Возрождение — случайно" },
    btn_respawn_point  = { "Respawn - Spawn Point", "Возрождение — точка возрождения" },
}

-- Screen text for a catalog key (the player's language; Russian by default).
function M.tr(key, ...)
    local t = M.TEXT[key]
    if not t then return key end
    return say_text(key, t, ...)
end

-- log.say(key, kind, seconds, args...): English to the log, the player's
-- language (Russian by default) on screen.
function M.say(key, kind, seconds, ...)
    local t = M.TEXT[key]
    if not t then
        M.toast(key, kind, seconds, nil, key)
        return
    end
    M.toast(say_text(key, t, ...), kind, seconds, fmt(t[1], ...), key)
end

return M
