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
local PUNCT = { [0x2014] = "-", [0x2013] = "-", [0xAB] = "\"", [0xBB] = "\"", [0x2026] = "...", [0xB7] = "|",
                [0x2192] = "->" }

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
    -- the join cover (sdc_ui) takes the join's own messages: its progress and
    -- why a join failed show on it, not as a toast
    local js = M.join_sink
    if key and js then
        local ok, took = pcall(js, key, for_screen(text), kind or "info")
        if ok and took then return end
        if not ok then emit("[ERROR]", "join sink: " .. tostring(took)) end
    end
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
    reopen_saving     = { "Opening your world for friends: saving the game...",
                          "Открываю мир для друзей: сохраняю игру..." },
    reopen_loading    = { "Saved. Your world loads again, open for friends (a few seconds).",
                          "Сохранено. Мир загрузится заново — уже открытым для друзей (несколько секунд)." },
    reopen_done       = { "Your world is open for friends.", "Мир открыт для друзей." },
    reopen_save_failed = { "Couldn't save the game, so the world stays single player. Save by hand and try again.",
                          "Не удалось сохранить игру — мир остался одиночным. Сохранитесь вручную и попробуйте ещё раз." },
    reopen_continue_hand = { "Your world is open for friends: press Continue to load your save.",
                          "Мир открыт для друзей: нажмите Continue, чтобы загрузить сохранение." },
    reopen_busy       = { "Your world is already being opened for friends...", "Мир уже открывается для друзей..." },
    admin_kicked_you  = { "The host removed you from the world.", "Хост выгнал вас из мира." },
    admin_banned_you  = { "The host banned you from this world.", "Хост забанил вас в этом мире." },
    admin_kick_done   = { "%s was kicked.", "%s выгнан из мира." },
    admin_ban_done    = { "%s was banned.", "%s забанен и выгнан из мира." },
    admin_banned_join = { "%s is banned: not let in.", "%s забанен — в мир не пущен." },
    admin_player_kicked = { "The host kicked %s.", "Хост выгнал игрока %s." },
    admin_cheats_off  = { "The host has switched off the game's cheats and debug menu in this world.",
                          "Хост выключил читы и отладочное меню игры в своём мире." },
    admin_unbanned    = { "The ban list is cleared.", "Список банов очищен." },
    admin_unbanned_one = { "%s is unbanned.", "%s разбанен." },
    -- who may join (sdc_admin: join_access, allowed_players, max_players); the host's notices
    access_ask        = { "%s wants to join: %s → World.", "%s хочет войти в мир: %s → «Мир»." },
    access_allowed    = { "%s was let in and added to the list.", "%s впущен и добавлен в список." },
    access_allowed_once = { "%s was let in (not added to the list: it never said who it is).",
                            "%s впущен (в список не добавлен: игрок так и не назвал себя)." },
    access_denied     = { "%s was not let in.", "%s не впущен в мир." },
    access_timeout    = { "%s got no answer within 2 minutes and was not let in.", "%s не дождался ответа за 2 минуты — не впущен." },
    access_not_listed = { "%s is not on the list: not let in.", "%s нет в списке — не впущен." },
    access_full       = { "The world is full (%d of %d players): %s was not let in.",
                          "Мир заполнен (%d из %d игроков) — %s не впущен." },
    access_listed     = { "%s was added to the list.", "%s добавлен в список." },
    access_unlisted   = { "%s was taken off the list.", "%s убран из списка." },
    access_invited    = { "Steam invite sent: %s (on the allowed list).", "Приглашение через Steam отправлено: %s (в списке допущенных)." },
    world_saved       = { "The world is saved.", "Мир сохранён." },
    world_save_failed = { "Couldn't save the world (details in UE4SS.log).", "Не удалось сохранить мир (подробности в UE4SS.log)." },
    -- the join password (join_access password)
    access_pw_wrong   = { "%s gave a wrong password: not let in (%d of %d).", "%s ввёл неверный пароль — не впущен (%d из %d)." },
    -- no network address (Steam, a local tunnel): tries are not counted
    access_pw_wrong_nc = { "%s gave a wrong password: not let in.", "%s ввёл неверный пароль — не впущен." },
    access_pw_none    = { "%s gave no password: not let in.", "%s не ввёл пароль — не впущен." },
    access_pw_locked  = { "%s: too many wrong passwords, can't join for %d min.",
                          "%s: слишком много неверных паролей — вход закрыт на %d мин." },
    access_pw_unset   = { "%s was not let in: no join password is set (Co-op → World).",
                          "%s не впущен: пароль для входа не задан («Кооператив» → «Мир»)." },
    access_pw_ok      = { "%s gave the right password and was let in.", "%s ввёл верный пароль — впущен." },
    access_pw_set     = { "Join password saved.", "Пароль для входа сохранён." },
    access_pw_cleared = { "Join password cleared: new players can't get in until you save one.",
                          "Пароль для входа убран — новые игроки не войдут, пока вы его не сохраните." },
    -- ... and the joining player's (KICK|2..6, ACCESS)
    access_wait_you   = { "The host has to let you in: waiting for an answer (up to 2 minutes).",
                          "Хост должен вас впустить — ждём ответа (до 2 минут)." },
    access_ok_you     = { "The host let you in.", "Хост впустил вас." },
    access_list_you   = { "This world is invite-only: the host hasn't put you on its list.",
                          "Этот мир только по приглашению: хост не добавил вас в свой список." },
    access_denied_you = { "The host didn't let you in.", "Хост не впустил вас в мир." },
    access_timeout_you = { "The host didn't answer your request to join.", "Хост не ответил на ваш запрос на вход." },
    access_full_you   = { "The host's world is full.", "Мир хоста заполнен." },
    access_pw_need_you = { "The host requires a password to join.", "Хост требует пароль для входа." },
    access_pw_wrong_you = { "Wrong password.", "Неверный пароль." },
    access_pw_locked_you = { "Too many wrong passwords: try again in %d min.",
                             "Слишком много неверных паролей — попробуйте через %d мин." },
    access_pw_unset_you = { "The host hasn't set a join password yet: ask them to set one on the World tab.",
                            "Хост ещё не задал пароль для входа — попросите его задать пароль на вкладке «Мир»." },
    -- friendly fire (sdc_ffire): the host's switch on the World tab, the players' notices
    ff_on_host        = { "Friendly fire is on: players can hurt each other.",
                          "Огонь по своим включён: игроки могут ранить друг друга." },
    ff_off_host       = { "Friendly fire is off: players can't hurt each other.",
                          "Огонь по своим выключен: игроки не ранят друг друга." },
    ff_join_on        = { "Friendly fire is on in this world: players can hurt each other.",
                          "В этом мире включён огонь по своим: игроки могут ранить друг друга." },
    ff_turned_on      = { "The host turned friendly fire on: players can hurt each other.",
                          "Хост включил огонь по своим: игроки могут ранить друг друга." },
    ff_turned_off     = { "The host turned friendly fire off: players can't hurt each other.",
                          "Хост выключил огонь по своим: игроки не ранят друг друга." },
    reopen_need_alive ={ "Respawn first, then open your world for friends.",
                          "Сначала возродитесь, затем откройте мир для друзей." },
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
    host_no_answer    = { "The host did not answer at %s: check the address and the port (the host listens on UDP 7777, its world open for friends).",
                          "Хост не ответил по адресу %s: проверьте адрес и порт (хост слушает UDP 7777, его мир должен быть открыт для друзей)." },
    host_no_answer_steam = { "The host did not answer through Steam: its world must be open for friends.",
                          "Хост не ответил через Steam: его мир должен быть открыт для друзей." },
    server_closed     = { "Server closed.", "Сервер закрыт." },
    peer_version      = { "%s runs mod version %s, you run %s.", "У %s другая версия мода (%s, у вас %s)." },
    host_version      = { "Mod versions differ: host %s, you %s.", "Версии мода отличаются: у хоста %s, у вас %s." },
    respawning        = { "Respawning...", "Возрождение..." },
    settings_saved    = { "Settings saved.", "Настройки сохранены." },
    settings_failed   = { "Could not save settings.", "Не удалось сохранить настройки." },
    settings_num_bad  = { "Not a number: %s. The previous value was kept.",
                          "Не число: %s. Оставлено прежнее значение." },
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
