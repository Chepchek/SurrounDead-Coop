-- SDCoop: on-screen language (Russian / English).
--
--   language()      "ru" | "en": config `language` (auto | ru | en). Auto is
--                   the game's culture (KismetInternationalizationLibrary);
--                   the game ships only English text, so its culture falls
--                   back to "en" on every PC: the Windows language
--                   (KismetSystemLibrary.GetDefaultLanguage) decides then.
--                   ru* -> ru, anything else -> en. Read once on the game
--                   thread (M.detect, from the UI tick); "ru" until then.
--   T(key, ...)     a panel string in the current language (string.format).
--   desc(key)       a config setting's full description (RU = SCHEMA text).
--   label(key)      a short label for a config setting.
--   groups()        every bool setting of SCHEMA, grouped by area.
--   screen_text(s)  sdc_log's toast path: a Russian notification -> English
--                   (exact strings, then patterns) when the language is en.
--   screen_say(key, entry, ...)  sdc_log.say / tr: catalog text per language.
-- Log lines stay English; nothing here touches UE4SS.log text.

local log = require("sdc_log")
local cfg = require("sdc_config")

local M = {
    auto_lang = nil,       -- "ru" | "en" once detected
    culture = nil,         -- the game's culture ("en", "ru-RU", ...)
    os_language = nil,     -- the platform language
    detect_tries = 0,
    listeners = {},        -- [name] = fn(lang): called after a language change
}

-- ---------------------------------------------------------------------------
-- Panel strings
-- ---------------------------------------------------------------------------

M.STR = {}
M.STR.ru = {
    title = "Кооператив",
    coop_button = "Кооператив",
    version = "v%s",
    tab_steam = "Steam",
    tab_ip = "IP",
    tab_char = "Персонаж",
    tab_world = "Мир",
    tab_settings = "Настройки",
    -- status line (dot + one sentence + one dim line)
    st_host = "Мир открыт для друзей.",
    st_host_menu_hint = "Загрузите сохранение: Continue или Load.",
    st_host_wait = "Пока никто не подключился. Друзья подключаются по вашему IP, порт 7777 (UDP).",
    st_host_wait_steam = "Пока никто не подключился. Друзья подключаются через Steam или по вашему IP (порт 7777, UDP).",
    st_client = "Вы в мире хоста %s.",
    st_client_noname = "Вы подключены к хосту.",
    st_ping = "Пинг %d мс.",
    st_version = "Версия мода у хоста %s, у вас %s.",
    st_connecting = "Подключение к %s…",
    st_opening = "Мир открывается для друзей…",
    st_opening_hint = "Меню перезагрузится.",
    st_closed = "Мир закрыт для друзей.",
    st_closed_hint = "Откройте свой мир или подключитесь к другу.",
    st_autojoin = "Автоподключение к %s:%d, попытка %d.",
    st_single = "Одиночная игра: мир закрыт для друзей.",
    st_single_hint = "«Открыть мир для друзей»: игра сохранится и загрузит этот мир заново — уже открытым.",
    st_loading = "Загрузка…",
    -- play
    sec_join = "Подключиться к другу",
    f_ip = "IP хоста",
    f_ip_hint = "например 127.0.0.1",
    f_port = "Порт",
    f_host_pw = "Пароль (если хост его задал)",
    f_host_pw_hint = "пароль хоста",
    btn_join = "Подключиться",
    btn_disconnect = "Отключиться",
    btn_host = "Открыть мир для друзей",
    host_caption = "Меню перезагрузится, затем загрузите сохранение.",
    host_caption_world = "Игра сохранится и загрузит этот мир заново — уже открытым для друзей (несколько секунд).",
    btn_fresh = "Новая карта без сохранения",
    fresh_caption = "Чистая карта как сервер — чтобы быстро проверить связь.",
    sec_help = "Как играть по IP",
    sec_test = "Проверка связи",
    btn_go_ip = "Подключиться по IP",
    help_text = "1. Все ставят Radmin VPN или ZeroTier и входят в одну сеть (или хост пробрасывает порт 7777 UDP на роутере).\n"
        .. "2. Хост нажимает «Открыть мир для друзей» и загружает сохранение.\n"
        .. "3. Друг вводит IP хоста из Radmin VPN и нажимает «Подключиться».\n"
        .. "Не подключается? Хосту нужно разрешить игру в брандмауэре Windows: входящие подключения UDP.",
    -- players
    pl_title = "Игроки (%d)",
    pl_title_none = "Игроки",
    pl_closed_menu = "Мир закрыт — никого нет.",
    pl_single = "Одиночная игра — никого нет.",
    pl_waiting = "Пока никто не подключился.",
    pl_connecting = "Подключение к хосту…",
    pl_loading = "Загрузка…",
    pl_you = "%s (вы)",
    pl_more = "…и ещё %d",
    pl_ping = "%d мс",
    pl_state_host = "хост",
    pl_state_connecting = "подключается",
    pl_state_loading = "загружается",
    pl_state_dead = "погиб",
    pl_state_game = "в игре",
    -- Steam (sdc_steamlink: its status lines and friend states are its own)
    steam_error_plain = "Ошибка Steam-соединения.",
    steam_restart = "Перезапустите игру один раз: мод изменил её сетевые настройки.",
    steam_friends_only = "Подключиться могут только ваши друзья в Steam.",
    btn_steam_invite = "Пригласить друга",
    btn_steam_join = "Подключиться",
    btn_steam_invite_one = "Пригласить",
    steam_friends = "Друзья в SurrounDead",
    steam_no_friends = "Сейчас никто из друзей не играет в SurrounDead.",
    steam_more = "…и ещё %d",
    steam_join_failed = "Не удалось подключиться через Steam: %s",
    steam_invite_failed = "Не удалось открыть приглашение Steam: %s",
    help_steam = "Как это работает: хост нажимает «Открыть мир для друзей» вверху панели, друг находит его в списке «Друзья в SurrounDead» и нажимает «Подключиться». Без IP и VPN.",
    -- character
    sec_name = "Имя",
    f_name_hint = "как вас увидят другие",
    sec_looks = "Внешность",
    btn_looks = "Изменить внешность",
    btn_looks_new = "Создать персонажа",
    looks_caption = "Персонаж для кооператива создаётся в редакторе игры.",
    looks_menu_only = "Внешность меняется в главном меню.",
    -- the co-op character (sdc_charcreate, Mods/SDCoop/character.txt)
    char_made = "Персонаж создан: %s.",
    char_made_named = "Персонаж создан: %s, %s.",
    char_sex_female = "Женщина",
    char_sex_male = "Мужчина",
    char_none = "Персонаж ещё не создан — редактор откроется при первом подключении.",
    char_off = "Свой персонаж для кооператива выключен в настройках — подключение с персонажем по умолчанию.",
    sec_rescue = "Если что-то пошло не так",
    unstuck_caption = "Застряли или провалились?",
    btn_unstuck_host = "Перенести к хосту",
    btn_unstuck_start = "Перенести на точку старта",
    char_ingame_only = "Перенос к хосту появляется здесь, когда вы играете в мире друга.",
    -- settings
    sec_lang = "Язык",
    lang_auto = "Авто",
    lang_ru = "Русский",
    lang_en = "English",
    lang_caption = "Авто — язык игры или Windows.",
    lang_tip = "Авто: панель и сообщения мода — на языке игры, а если в игре нет русского — на языке Windows. "
        .. "Кнопка «Кооператив» в меню игры — на языке самой игры, как соседние пункты. "
        .. "Русский или English — этот язык везде.",
    -- bug reports
    sec_bug = "Сообщить об ошибке",
    bug_link = "Сообщить об ошибке",
    bug_text = "Создайте отчёт на GitHub. Приложите UE4SS.log с обоих компьютеров, взятый сразу после ошибки "
        .. "(до перезапуска игры), версию мода (%s) и кто был хостом, а кто клиентом.",
    bug_template = "Что написать в форме:\n"
        .. "• Что случилось и чего вы ждали\n"
        .. "• Как повторить: шаги по порядку\n"
        .. "• Как подключались: Radmin VPN, ZeroTier, Steam или напрямую\n"
        .. "• Логи: перетащите оба UE4SS.log в поле «Логи»",
    btn_bug_form = "Открыть форму на GitHub",
    btn_bug_logs = "Открыть папку с логом",
    bug_path = "UE4SS.log лежит здесь (можно выделить и скопировать):",
    bug_opening_web = "Форма откроется в браузере. Если игра на весь экран — переключитесь (Alt+Tab).",
    bug_opening_folder = "Папка с UE4SS.log откроется в проводнике (Alt+Tab, если игра на весь экран).",
    bug_open_failed = "Не удалось открыть: %s",
    toast_err_hint = "Ошибка мода — сообщите о ней: %s → «Сообщить об ошибке»",
    sec_main = "Основное",
    sec_all = "Все функции мода",
    all_caption = "Наведите курсор на пункт, чтобы прочитать подробности. Числа под некоторыми пунктами (проценты, пределы зомби) меняются здесь и сохраняются кнопкой «Сохранить»; остальные числа и тексты (порт, задержки, сеть) — в config.ini.",
    group_count = "%s (%d)",
    settings_note = "Изменения применяются после «Сохранить», часть — после перезапуска игры.",
    -- footer
    btn_save = "Сохранить",
    btn_close = "Закрыть",
    hint_key = "%s — открыть или закрыть панель",
    -- notifications from the panel
    -- players table (in game, top right; players_hud / players_hud_key)
    btn_kick = "Кик",
    btn_ban = "Бан",
    btn_ban_sure = "Точно?",
    kick_tip = "Выгнать игрока из мира (сможет зайти снова)",
    ban_tip = "Забанить: выгнать и больше не пускать (второе нажатие подтверждает)",
    -- a player's row: «Ещё ›» opens a strip with the rarer actions (not next to Kick / Ban)
    btn_more = "Ещё",
    more_tip = "Другие действия с этим игроком",
    btn_pull = "Притянуть к себе",
    pull_tip = "Перенести игрока к себе — если он застрял, провалился под землю или потерялся",
    sec_bans = "Баны",
    bans_none = "Никто не забанен.",
    btn_unban = "Снять все",
    -- the World tab (host: who can join, the waiting and turned-away players, the list, bans; sdc_admin)
    wa_guest = "Миром управляет хост — тот, кто открыл свой мир для друзей.",
    wa_sec_access = "Кто может войти",
    wa_mode_open = "Все",
    wa_mode_password = "По паролю",
    wa_mode_approve = "По одобрению",
    wa_mode_list = "Только приглашённые",
    wa_mode_tip = "Кто может войти в ваш мир (сохраняется сразу)",
    wa_cap_open = "Входят все, кроме забаненных.",
    wa_cap_password = "Игроки из списка входят сразу, остальные вводят пароль — и по IP, и через Steam. Верный пароль добавляет игрока в список.",
    wa_cap_approve = "Игроки из списка входят сразу, остальных вы впускаете здесь — на ответ 2 минуты.",
    wa_cap_list = "Входят только игроки из списка ниже, остальным — сразу отказ. «Пригласить» у друга на вкладке «Steam» отправляет ему приглашение и добавляет в список.",
    wa_pw_title = "Пароль для входа",
    wa_pw_hint = "впишите пароль",
    wa_pw_save = "Сохранить",
    wa_pw_set = "Пароль задан.",
    wa_pw_unset = "Пароль не задан: пока вы его не сохраните, новые игроки не войдут.",
    wa_pw_cap = "Его спрашивают у всех, кого нет в списке, — и по IP, и через Steam. Новый пароль не выгонит тех, кто уже в списке. Хранится в config.ini открытым текстом: не ставьте пароль от Steam или почты.",
    wa_limit = "Не больше %d игроков в мире, считая вас (max_players в config.ini).",
    wa_sec_waiting = "Ждут разрешения",
    wa_waiting_none = "Никто не ждёт.",
    wa_secs = "%d с",
    wa_btn_allow = "Пустить",
    wa_btn_deny = "Отказать",
    wa_allow_tip = "Впустить игрока и добавить его в список",
    wa_deny_tip = "Не впускать (игрок сможет попроситься снова)",
    wa_sec_recent = "Недавно не впущены",
    wa_why_list = "нет в списке",
    wa_why_denied = "отказано",
    wa_why_timeout = "нет ответа",
    wa_why_full = "мир заполнен",
    wa_why_pw_none = "без пароля",
    wa_why_pw_wrong = "неверный пароль",
    wa_why_pw_locked = "много попыток",
    wa_why_pw_unset = "пароль не задан",
    wa_btn_add = "Добавить в список",
    wa_add_tip = "Игрок из списка входит сразу — без пароля, без одобрения и в режиме «Только приглашённые»",
    wa_sec_allowed = "Список допущенных",
    wa_allowed_none = "Список пуст. Сюда попадают впущенные («Пустить»), вошедшие по паролю и приглашённые с вкладки «Steam».",
    wa_btn_remove = "Убрать",
    wa_remove_tip = "Убрать из списка допущенных",
    wa_btn_unban = "Снять бан",
    wa_unban_tip = "Снять бан с этого игрока",
    wa_btn_save = "Сохранить мир сейчас",
    wa_save_cap = "Обычное сохранение игры в текущий слот — вместе с персонажами друзей.",
    wa_sec_rules = "Правила мира",
    wa_ff_cap = "Выкл.: игроки не ранят друг друга. Зомби, падение, ловушки и своя граната ранят как обычно.",
    hud_title = "Игроки: %d",
    hud_hint = "%s — скрыть",
    hud_col_name = "Игрок",
    hud_col_ping = "Пинг",
    hud_more = "и ещё %d",
    hud_shown = "Таблица игроков показана. %s — скрыть.",
    hud_hidden = "Таблица игроков скрыта. %s — показать.",
    hud_shown_later = "Таблица игроков включена: она появится, когда в мире будут другие игроки. %s — скрыть.",
    -- join cover (a client joining a friend; sdc_ui, config join_cover)
    jc_title = "Подключение к миру друга",
    jc_title_host = "Мир игрока %s",
    jc_load = "Загрузка мира хоста…",
    jc_pawn = "Ожидание вашего персонажа…",
    jc_restore = "Восстановление персонажа…",
    jc_fresh = "Подготовка нового персонажа…",
    jc_verdict = "Загрузка данных персонажа…",
    jc_done = "Готово",
    jc_hint_ip = "Хост: %s",
    jc_hint_wait = "Хост %s пока не отвечает. Обычно ответ приходит за пару секунд.",
    jc_hint_steam = "Подключение через Steam.",
    jc_hint_load = "Загружается тот же мир, в котором играет хост.",
    jc_hint_pawn = "Хост ставит вашего персонажа в мир — обычно это занимает до 30 секунд.",
    jc_hint_restore = "Вещи, здоровье и место, где вы вышли из игры.",
    jc_hint_fresh = "Вы впервые в этом мире: новый персонаж.",
    jc_hint_verdict = "Хост проверяет, играли ли вы уже в этом мире.",
    jc_access_wait = "Ждём, пока хост вас впустит…",
    jc_hint_access_wait = "Хост видит ваш запрос в панели кооператива. Если он не ответит за 2 минуты, вход отменится.",
    jc_key = "%d с · %s — показать игру",
    jc_step_connect = "Связь",
    jc_step_world = "Мир",
    jc_step_char = "Персонаж",
    jc_step_items = "Вещи и место",
    jc_note = "Хост ещё не закончил с вашим персонажем — игра показана. Если что-то не так: %s → «Отключиться».",
    jc_err_title = "Не удалось подключиться",
    jc_err_title_left = "Соединение с хостом прервано",
    jc_err_no_answer = "Хост не отвечает",
    jc_err_no_answer_hint = "Адрес: %s. Проверьте IP и порт: хост слушает UDP 7777, а его мир должен быть открыт для друзей. Если вы не в одной сети, нужен Radmin VPN, ZeroTier или проброс порта.",
    jc_err_no_answer_steam = "Хост не отвечает через Steam",
    jc_err_no_answer_steam_hint = "Друг должен быть в своём мире, открытом для друзей, и в сети Steam.",
    jc_err_lost = "Связь с хостом прервалась",
    jc_err_lost_hint = "Хост вышел из мира или из игры, либо пропала сеть. Подключитесь снова, когда хост будет в мире.",
    jc_err_kicked = "Хост выгнал вас из мира",
    jc_err_kicked_hint = "Подключиться снова можно, если хост не против.",
    jc_err_banned = "Вы забанены в этом мире",
    jc_err_banned_hint = "Пустить вас снова может только хост: «Кооператив» → «Мир» → «Баны».",
    jc_err_list = "Этот мир только по приглашению",
    jc_err_list_hint = "Хост пускает только игроков из своего списка. Попросите его добавить вас: «Кооператив» → «Мир».",
    jc_err_denied = "Хост не впустил вас",
    jc_err_denied_hint = "Хост отклонил ваш запрос на вход. Подключиться снова можно, если хост не против.",
    jc_err_no_reply = "Хост не ответил на запрос",
    jc_err_no_reply_hint = "Хост не впустил вас за 2 минуты — возможно, он отошёл. Напишите ему и подключитесь снова.",
    jc_err_full = "Мир заполнен",
    jc_err_full_hint = "В мире хоста уже столько игроков, сколько он разрешил. Подключитесь, когда кто-нибудь выйдет.",
    jc_err_steam_hint = "Проверьте, что друг в своём мире, открытом для друзей, и попробуйте ещё раз.",
    jc_err_rejected_hint = "Попросите друга пригласить вас через Steam.",
    jc_err_pw_need = "Хост требует пароль",
    jc_err_pw_wrong = "Неверный пароль",
    jc_err_pw_hint = "Узнайте пароль у хоста, впишите его ниже и нажмите «Войти».",
    jc_err_pw_hint_where = "Это подключение начато не из панели мода, поэтому мод не знает адрес хоста. Подключитесь к нему на вкладке «IP» (адрес и пароль) или «Steam» — там пароль можно ввести.",
    jc_err_pw_locked_hint = "Уточните пароль у хоста.",
    jc_err_pw_unset = "Хост ещё не задал пароль",
    jc_err_pw_unset_hint = "Хост пускает только по паролю, но сам пароль не сохранил. Попросите его задать пароль на вкладке «Мир» и подключитесь снова.",
    jc_err_close = "Esc или %s — закрыть",
    jc_err_retry_in = "Автоподключение: новая попытка через %d с · Esc — закрыть",
    jc_btn_retry = "Повторить",
    jc_btn_close = "Закрыть",
    jc_btn_enter = "Войти",
    -- setting groups
    g_connect = "Подключение",
    g_players = "Игроки и персонажи",
    g_zombies = "Зомби и звери",
    g_npc = "Люди, торговцы и задания",
    g_combat = "Бой и предметы",
    g_world = "Мир",
    g_vehicles = "Машины",
    g_saves = "Сохранения",
    g_debug = "Сеть и отладка",
    g_other = "Другое",
    -- other players' events (sdc_playernotes; the game's notification widget)
    pe_died = "%s погиб.",
    pe_back = "%s возродился.",
}

M.STR.en = {
    title = "Co-op",
    coop_button = "Co-op",
    version = "v%s",
    tab_steam = "Steam",
    tab_ip = "IP",
    tab_char = "Character",
    tab_world = "World",
    tab_settings = "Settings",
    st_host = "Your world is open to friends.",
    st_host_menu_hint = "Load your save: Continue or Load.",
    st_host_wait = "Nobody has joined yet. Friends join by your IP, port 7777 (UDP).",
    st_host_wait_steam = "Nobody has joined yet. Friends join through Steam or by your IP (port 7777, UDP).",
    st_client = "You are in %s's world.",
    st_client_noname = "You are connected to the host.",
    st_ping = "Ping %d ms.",
    st_version = "The host runs mod version %s, you run %s.",
    st_connecting = "Connecting to %s…",
    st_opening = "Opening your world to friends…",
    st_opening_hint = "The menu will reload.",
    st_closed = "Your world is closed to friends.",
    st_closed_hint = "Open your world or join a friend.",
    st_autojoin = "Auto-joining %s:%d, attempt %d.",
    st_single = "Single player: your world is closed to friends.",
    st_single_hint = "“Open my world to friends”: the game saves and loads this world again, open.",
    st_loading = "Loading…",
    sec_join = "Join a friend",
    f_ip = "Host IP",
    f_ip_hint = "for example 127.0.0.1",
    f_port = "Port",
    f_host_pw = "Password (if the host set one)",
    f_host_pw_hint = "host's password",
    btn_join = "Join",
    btn_disconnect = "Disconnect",
    btn_host = "Open my world to friends",
    host_caption = "The menu reloads, then load your save.",
    host_caption_world = "The game saves and loads this world again, open for friends (a few seconds).",
    btn_fresh = "New map without a save",
    fresh_caption = "A clean map as a server, to test the connection quickly.",
    sec_help = "How to play by IP",
    sec_test = "Connection test",
    btn_go_ip = "Join by IP",
    help_text = "1. Everyone installs Radmin VPN or ZeroTier and joins one network (or the host forwards port 7777 UDP on the router).\n"
        .. "2. The host presses “Open my world to friends” and loads a save.\n"
        .. "3. A friend enters the host's Radmin VPN IP and presses “Join”.\n"
        .. "Can't connect? The host must allow the game in Windows Firewall: inbound UDP.",
    pl_title = "Players (%d)",
    pl_title_none = "Players",
    pl_closed_menu = "Your world is closed: nobody is here.",
    pl_single = "Single player: nobody else is here.",
    pl_waiting = "Nobody has joined yet.",
    pl_connecting = "Connecting to the host…",
    pl_loading = "Loading…",
    pl_you = "%s (you)",
    pl_more = "…and %d more",
    pl_ping = "%d ms",
    pl_state_host = "host",
    pl_state_connecting = "connecting",
    pl_state_loading = "loading",
    pl_state_dead = "dead",
    pl_state_game = "in game",
    steam_error_plain = "Steam link error.",
    steam_restart = "Restart the game once: the mod changed its network settings.",
    steam_friends_only = "Only your Steam friends can join.",
    btn_steam_invite = "Invite a friend",
    btn_steam_join = "Join",
    btn_steam_invite_one = "Invite",
    steam_friends = "Friends in SurrounDead",
    steam_no_friends = "None of your friends is playing SurrounDead right now.",
    steam_more = "…and %d more",
    steam_join_failed = "Couldn't join through Steam: %s",
    steam_invite_failed = "Couldn't open the Steam invite: %s",
    help_steam = "How it works: the host presses “Open my world to friends” at the top of the panel, the friend finds them under “Friends in SurrounDead” and presses “Join”. No IP, no VPN.",
    sec_name = "Name",
    f_name_hint = "how others see you",
    sec_looks = "Appearance",
    btn_looks = "Change appearance",
    btn_looks_new = "Create a character",
    looks_caption = "Your co-op character is made in the game's editor.",
    looks_menu_only = "Appearance can be changed in the main menu.",
    char_made = "Character created: %s.",
    char_made_named = "Character created: %s, %s.",
    char_sex_female = "Female",
    char_sex_male = "Male",
    char_none = "No character yet: the editor opens when you first join a friend.",
    char_off = "Your own co-op character is off in the settings: you join with the default character.",
    sec_rescue = "If something went wrong",
    unstuck_caption = "Stuck or fell through the world?",
    btn_unstuck_host = "Move to the host",
    btn_unstuck_start = "Move to a start point",
    char_ingame_only = "Moving to the host shows up here while you play in a friend's world.",
    sec_lang = "Language",
    lang_auto = "Auto",
    lang_ru = "Русский",
    lang_en = "English",
    lang_caption = "Auto uses the game's or Windows' language.",
    lang_tip = "Auto: the panel and the mod's messages use the game's language, or Windows' language if the game has no Russian. "
        .. "The game menu's Co-op button uses the game's own language, like the items next to it. "
        .. "Русский or English: that language everywhere.",
    sec_bug = "Report a bug",
    bug_link = "Report a bug",
    bug_text = "Open a report on GitHub. Attach UE4SS.log from both PCs, taken right after the problem "
        .. "(before restarting the game), the mod version (%s), and who was the host and who the client.",
    bug_template = "What to write in the form:\n"
        .. "• What happened and what you expected\n"
        .. "• How to repeat it, step by step\n"
        .. "• How you connected: Radmin VPN, ZeroTier, Steam or direct\n"
        .. "• Logs: drag both UE4SS.log files into the “Logs” field",
    btn_bug_form = "Open the GitHub form",
    btn_bug_logs = "Open the log folder",
    bug_path = "UE4SS.log is here (you can select and copy it):",
    bug_opening_web = "The form opens in your browser. If the game is full screen, switch to it (Alt+Tab).",
    bug_opening_folder = "The UE4SS.log folder opens in Explorer (Alt+Tab if the game is full screen).",
    bug_open_failed = "Couldn't open: %s",
    toast_err_hint = "A mod error. Please report it: %s → “Report a bug”",
    sec_main = "Main",
    sec_all = "All mod features",
    all_caption = "Hover an item for details. The numbers under some items (percentages, zombie limits) are changed here and kept with Save; other numbers and text values (port, delays, network) are set in config.ini.",
    group_count = "%s (%d)",
    settings_note = "Changes apply after Save; some need a game restart.",
    btn_save = "Save",
    btn_close = "Close",
    hint_key = "%s opens or closes this panel",
    btn_kick = "Kick",
    btn_ban = "Ban",
    btn_ban_sure = "Sure?",
    kick_tip = "Remove the player from the world (they can join again)",
    ban_tip = "Ban: remove the player and keep them out (a second click confirms)",
    btn_more = "More",
    more_tip = "More actions for this player",
    btn_pull = "Pull to me",
    pull_tip = "Move the player next to you: stuck, fell through the ground or lost",
    sec_bans = "Bans",
    bans_none = "Nobody is banned.",
    btn_unban = "Clear all",
    wa_guest = "The world is managed by its host: the player who opened it to friends.",
    wa_sec_access = "Who can join",
    wa_mode_open = "Anyone",
    wa_mode_password = "Password",
    wa_mode_approve = "Approval",
    wa_mode_list = "Invite only",
    wa_mode_tip = "Who may join your world (saved at once)",
    wa_cap_open = "Everyone gets in except banned players.",
    wa_cap_password = "Players on the list join at once; everyone else gives the password, by IP and through Steam alike. The right password puts the player on the list.",
    wa_cap_approve = "Players on the list join at once; you let the others in here (2 minutes to answer).",
    wa_cap_list = "Only players on the list below get in; everyone else is turned away. Invite on a friend's row (Steam tab) sends them a Steam invite and puts them on the list.",
    wa_pw_title = "Join password",
    wa_pw_hint = "type a password",
    wa_pw_save = "Save",
    wa_pw_set = "The password is set.",
    wa_pw_unset = "No password yet: new players can't get in until you save one.",
    wa_pw_cap = "Everyone not on the list is asked for it, by IP and through Steam alike. A new password doesn't lock out players already on the list. Stored in config.ini as plain text: don't reuse your Steam or email password.",
    wa_limit = "At most %d players in the world, you included (max_players in config.ini).",
    wa_sec_waiting = "Waiting to join",
    wa_waiting_none = "Nobody is waiting.",
    wa_secs = "%d s",
    wa_btn_allow = "Allow",
    wa_btn_deny = "Deny",
    wa_allow_tip = "Let the player in and add them to the list",
    wa_deny_tip = "Turn the player away (they can ask again)",
    wa_sec_recent = "Recently turned away",
    wa_why_list = "not on the list",
    wa_why_denied = "denied",
    wa_why_timeout = "no answer",
    wa_why_full = "world full",
    wa_why_pw_none = "no password",
    wa_why_pw_wrong = "wrong password",
    wa_why_pw_locked = "too many tries",
    wa_why_pw_unset = "no password set",
    wa_btn_add = "Add to list",
    wa_add_tip = "A player on the list gets in at once: no password, no approval, and with Invite only",
    wa_sec_allowed = "Allowed players",
    wa_allowed_none = "The list is empty. Players you Allow, players who gave the password and friends you invite from the Steam tab go here.",
    wa_btn_remove = "Remove",
    wa_remove_tip = "Take the player off the allowed list",
    wa_btn_unban = "Unban",
    wa_unban_tip = "Lift this player's ban",
    wa_btn_save = "Save the world now",
    wa_save_cap = "The game's own save into the current slot, friends' characters included.",
    wa_sec_rules = "World rules",
    wa_ff_cap = "Off: players can't hurt each other. Zombies, falls, traps and your own grenade hurt as usual.",
    hud_title = "Players: %d",
    hud_hint = "%s to hide",
    hud_col_name = "Player",
    hud_col_ping = "Ping",
    hud_more = "and %d more",
    hud_shown = "Player table shown. %s to hide it.",
    hud_hidden = "Player table hidden. %s to show it.",
    hud_shown_later = "Player table on: it appears when other players are in the world. %s to hide it.",
    jc_title = "Joining a friend's world",
    jc_title_host = "%s's world",
    jc_load = "Loading the host's world…",
    jc_pawn = "Waiting for your character…",
    jc_restore = "Restoring your character…",
    jc_fresh = "Setting up your new character…",
    jc_verdict = "Getting your character's data…",
    jc_done = "Ready",
    jc_hint_ip = "Host: %s",
    jc_hint_wait = "No answer from %s yet. It usually comes within a couple of seconds.",
    jc_hint_steam = "Connecting through Steam.",
    jc_hint_load = "Loading the same world the host is playing in.",
    jc_hint_pawn = "The host is placing your character in the world; this usually takes up to 30 seconds.",
    jc_hint_restore = "Your items, health and the place where you left.",
    jc_hint_fresh = "Your first time in this world: a new character.",
    jc_hint_verdict = "The host is checking whether you've played in this world before.",
    jc_access_wait = "Waiting for the host to let you in…",
    jc_hint_access_wait = "The host sees your request in the co-op panel. If they don't answer within 2 minutes, joining is cancelled.",
    jc_key = "%d s · %s to show the game",
    jc_step_connect = "Connection",
    jc_err_title = "Couldn't join",
    jc_err_title_left = "Disconnected from the host",
    jc_err_no_answer = "The host isn't answering",
    jc_err_no_answer_hint = "Address: %s. Check the IP and the port: the host listens on UDP 7777, with its world open for friends. If you're not on the same network, use Radmin VPN, ZeroTier or port forwarding.",
    jc_err_no_answer_steam = "The host isn't answering through Steam",
    jc_err_no_answer_steam_hint = "Your friend must be in their own world, open for friends, and online in Steam.",
    jc_err_lost = "Lost the connection to the host",
    jc_err_lost_hint = "The host left the world or the game, or the network dropped. Join again once the host is back in the world.",
    jc_err_kicked = "The host removed you from the world",
    jc_err_kicked_hint = "You can join again if the host agrees.",
    jc_err_banned = "You're banned from this world",
    jc_err_banned_hint = "Only the host can let you back in: Co-op → World → Bans.",
    jc_err_list = "This world is invite-only",
    jc_err_list_hint = "The host lets in only players on their list. Ask them to add you: Co-op → World.",
    jc_err_denied = "The host didn't let you in",
    jc_err_denied_hint = "The host turned down your request to join. You can try again if the host agrees.",
    jc_err_no_reply = "The host didn't answer your request",
    jc_err_no_reply_hint = "The host didn't let you in within 2 minutes; maybe they're away. Message them and join again.",
    jc_err_full = "The world is full",
    jc_err_full_hint = "The host's world already has as many players as they allow. Join again when someone leaves.",
    jc_err_steam_hint = "Make sure your friend is in their own world, open for friends, and try again.",
    jc_err_rejected_hint = "Ask your friend to invite you through Steam.",
    jc_err_pw_need = "The host requires a password",
    jc_err_pw_wrong = "Wrong password",
    jc_err_pw_hint = "Ask the host for the password, type it below and press Join.",
    jc_err_pw_hint_where = "This join didn't start from the mod's panel, so the mod doesn't know the host's address. Join it from the IP tab (address and password) or the Steam tab, where you can enter the password.",
    jc_err_pw_locked_hint = "Check the password with the host.",
    jc_err_pw_unset = "The host hasn't set a password yet",
    jc_err_pw_unset_hint = "The host lets players in by password only but hasn't saved one. Ask them to set it on the World tab, then join again.",
    jc_err_close = "Esc or %s to close",
    jc_err_retry_in = "Auto join: next try in %d s · Esc to close",
    jc_btn_retry = "Try again",
    jc_btn_close = "Close",
    jc_btn_enter = "Join",
    jc_step_world = "World",
    jc_step_char = "Character",
    jc_step_items = "Items and place",
    jc_note = "The host hasn't finished with your character yet; the game is shown. If something is wrong: %s → Disconnect.",
    g_connect = "Connection",
    g_players = "Players and characters",
    g_zombies = "Zombies and animals",
    g_npc = "People, traders and quests",
    g_combat = "Combat and items",
    g_world = "World",
    g_vehicles = "Vehicles",
    g_saves = "Saves",
    g_debug = "Network and debug",
    g_other = "Other",
    -- other players' events (sdc_playernotes; the game's notification widget)
    pe_died = "%s died.",
    pe_back = "%s respawned.",
}

-- ---------------------------------------------------------------------------
-- Config settings: English descriptions (Russian ones are in SCHEMA)
-- ---------------------------------------------------------------------------

M.DESC_EN = {
    host_ip = "Friend's code (Steam) or the host's IP to connect to",
    port = "Host port (UDP). The host always listens on 7777",
    host_passwords = "Client: hosts' join passwords, one per address: <IP:port or steam:SteamID>=<password>;... (IP tab → Password, or Join on the connection screen). A password goes only to the host you join, and only when it asks. Stored here as plain text",
    player_name = "Your name for other players; empty = your Steam name (without Steam: your Windows user name)",
    listen_on_load = "Host: every world you load (a save or a new game) is open to friends right away",
    auto_join = "Client: connect to host_ip automatically from the main menu",
    auto_host = "Test: open auto_host_map as a server straight from the main menu",
    auto_host_map = "Map for auto_host and the sdcoop_server command",
    no_pause = "Don't pause the world while other players are connected",
    sync_env = "Sync the time of day and the weather with the host",
    unload_menu_level = "Client: unload your own main-menu scene in game (its sky and weather were drawn over the host's world: endless day, snow)",
    block_menu_level = "Client: don't load your own main-menu scene when connecting (its sky and weather were drawn over the host's world; \"Quit to menu\" on the death screen disconnects you from the host)",
    respawn_native = "Client: respawn with the game's own buttons (its \"keep inventory\" by difficulty, death stats); off = the mod's buttons",
    guard_player_sweeps = "Host: the game's death, pause and load screens remove only the host's character, not connected players",
    fresh_client_progress = "Client: if the host has no saved character for this player, start with a new character's progress (level 1, no skills or points); off = leave it as is",
    persist_clients = "Host: characters of players who joined (inventory and gear, level, skills, health, position, respawn point) are saved with the host's world (<slot>_SDCoop files in SaveGames) and come back when they rejoin",
    persist_period = "Host: also write players' characters to disk every N seconds (insurance against a crash); 0 = only on a game save, an inventory change, a death and when a player leaves",
    persist_restore_position = "Host: a returning player appears where they left (if they were alive); off = next to the host",
    persist_early_id = "The client tells the host its player number as soon as it is in the host's world, and the host puts its character straight at the saved place (no ~20 s wait under the map)",
    persist_follow_host_save = "Host: friends' characters follow the world's saves like a single-player character: when a save is loaded (also after a crash) each friend comes back exactly as they were at that save (position, inventory, health, level, skills, discovered map places, respawn point, quests); whoever came into the world after that save starts anew. Off = a friend continues from their latest state even when the world was loaded from an older save (items from containers can get duplicated)",
    persist_map = "Host and client: map places a player discovered (towns, locations) are saved with their character on the host and shown on the map again when they rejoin",
    map_shared = "Map places (towns, locations) any player discovered are shown on everyone's map - the host's and every client's, right away and after joining. Someone else's place is only shown, with a dimmed marker ('seen by another player'): when a player gets there themselves, the marker turns normal and they get the discovery XP and message. The host decides; off = everyone sees only their own places (on a client, off only hides others' places on its map)",
    persist_player_id = "Client: permanent player number for saves on the host when the game runs without Steam (created automatically; don't change it, or the host won't recognise the character)",
    skilltree_sync = "Host: skills from the client's skill tree (health regen, second chance, critical hit, night bonus) also count in the host's calculations",
    bed_for_client = "Host: a player's bed or sleeping bag gives that player, not the host, the sleep window, the \"too early to sleep\" check and the respawn point",
    client_sleep_skips_night = "Host: a player sleeping in a bed skips the night for everyone, like the host sleeping",
    coop_sleep_all = "Co-op: the night is skipped only when every connected player sleeps (each lies down in a bed or sleeping bag and presses Sleep); a sleeper waits for the others with 'Waiting for all players to fall asleep (1/2)', Esc gets up. Off = as before: any player's sleep skips the night for everyone",
    unstuck_cooldown = "Client: how often \"Move to the host\" can be used (seconds)",
    ai_fix = "Server-only zombies: replicate them from the host and remove the client's local copies",
    respawn_delay = "Seconds without a character before the host creates one for a player",
    char_create = "Your own co-op character: made in the game's character editor in the main menu before the first join (Mods/SDCoop/character.txt); the host creates a character with these looks",
    fix_capsule_replication = "Host: players' character capsules are not replicated (otherwise the server's position can push the client's character back)",
    ai_kill_credit = "Zombies, bosses, people and animals killed by a client: the kill, XP, skill point and message go to the client, not the host",
    ai_attack_montages = "The client sees attacks of zombies, bosses, wolves and bears, hit reactions, knockback and screams",
    ai_corpses = "Corpses of zombies, bosses and animals stay for clients: they lie there and can be searched or butchered",
    ai_healthbar = "The client's enemy health bar shows the health from the host and comes back after death and respawn",
    ai_offscreen_combat = "Wolves and bears bite the client, and the client's knife hits animals, even when the host isn't looking at them",
    ai_zombie_looks = "Zombies look the same for the client as for the host: crawling or standing (capsule and model height, no floating or sinking), model, material, hidden bones, walk animation, name, dog armour; the client doesn't pick zombie types itself",
    ai_kill_log = "Debug, host: log every zombie kill to UE4SS.log: type, look (model, material), crawler or not, killer, damage, place; once a minute, kill counts by type",
    ai_client_ghosts = "Client: the game's own AI spawners don't create zombies, bosses or animals, and ones that exist only on the client (standing still or floating) are removed; all AI comes from the host",
    ai_zombie_fx = "The client sees and hears special zombie effects: the grenadier zombie's beeping and explosion, the acid zombie bursting after death",
    ai_keep_chase = "Host: a zombie doesn't give up the chase when one player leaves its sight while another player (or another target) is still in front of it: it keeps chasing the one it sees (before, it walked to where the first player vanished, past the second one)",
    ai_spawn_check_all = "Host: the game's rule \"don't spawn zombies, animals or camps within 25 m of the player\" checks every player: each spawn point is checked against the living player nearest to it (before, only the host was checked, and zombies or a camp could appear right next to a client)",
    ai_player_scaling = "Host: more zombies with more players: the group a zombie (or hound) spawner spawns when a player comes near is ai_player_scaling_pct % bigger for each further living player within the spawner's trigger radius (usually 140 m), at most ai_player_scaling_cap_pct % of the normal size; the game's difficulty settings are not changed",
    ai_player_scaling_pct = "How many percent more zombies a spawner's group gets for each further player nearby (ai_player_scaling)",
    ai_player_scaling_cap_pct = "Upper limit of a spawner group's size with ai_player_scaling, in percent of the normal size (200 = at most twice)",
    ai_client_optimizer_guard = "Test, client: while the client's character is dead, the game's AI optimizer on the client leaves the copies of the host's zombies and animals alone (before, a few seconds after a death it \"despawned\" every copy around); once the new character is in, the copies are the optimizer's again. The log says when this acts and when the client's optimizer still removes a host copy. Off until tested in the game",
    ai_client_far_movement = "Client: the host's far zombies (122-150 m) move smoothly: the game's AI optimizer on the client no longer switches their movement off (before, they could move in jumps, \"teleport\"). Needs a test in the game",
    ai_host_cap = "Host: a limit on living zombies in the world. The limit is flexible and follows the number of players in the world: ai_host_cap_zombies while there are at most four players, plus ai_host_cap_per_player for each player beyond four, but never above ai_host_cap_max. By default: 2-4 players - 250 zombies (as before), 5 - 275, 6 or more - 300. At that many living zombies, zombie spawners hold their next groups back until there are fewer than 90 % of the limit and a player is near the spawner; held groups are not lost. The limit is soft: a new group's first zombie and single respawns still come above it. Useful when 3-4 players are far apart",
    ai_host_cap_zombies = "Host: the limit of living zombies in the world while there are at most four players (ai_host_cap); at least 40",
    ai_host_cap_per_player = "Host: how many zombies the limit grows by for each player in the world beyond four - the fifth, the sixth and so on (ai_host_cap); 0 = the limit does not depend on the number of players",
    ai_host_cap_max = "Host: the zombie limit never goes above this, however many players there are (ai_host_cap) - it protects the host's computer; never below the limit for 2-4 players",
    ai_toughness = "Host: zombies are tougher when several players are near: for each further living player within 140 m of a zombie it takes less damage (by ai_toughness_health_pct %) and hits harder (by ai_toughness_damage_pct %), at most ai_toughness_cap_pct % of normal. By default +25 % toughness and +15 % damage per player, at most twice. Bosses, animals and people are not changed. Off: it changes the game, the host decides (on a client the setting does nothing)",
    ai_toughness_health_pct = "Host: how many percent tougher a zombie is for each further player nearby (ai_toughness): at 25, damage to it is divided by 1.25 with two players and by 1.5 with three",
    ai_toughness_damage_pct = "Host: how many percent harder a zombie hits for each further player nearby (ai_toughness): at 15, its hit is x1.15 with two players and x1.3 with three",
    ai_toughness_cap_pct = "Host: the upper limit of both ai_toughness factors, in percent of normal (200 = at most twice; 100 = zombies are not tougher)",
    ai_horde_beacon = "Horde beacon: nearby clients see the wave notices (wave begins, wave completed, final wave defeated, a player died - the horde goes on, the horde stopped) and hear the horde music; a client who dies near the beacon gets no extra beacon item",
    ai_horde_continue = "Host: the beacon's horde goes on while at least one player is alive. In the game the host's death stopped the horde for everyone (the beacon turned back into an item); now one player's death does not stop it - the others see \"A player died, but the horde goes on\", the dead player respawns and can come back to the fight. While the player who pressed the beacon is dead, a new wave's zombies run to the living player nearest to the beacon. When every player is dead, the beacon turns back into an item as in the game and the horde ends - everyone is told, the dead too. With no players connected everything is as in single player. Off = as in the game",
    npc_offscreen = "Host: zombie bosses hit and throw rocks, and people (bandits, soldiers, raiders) move and fight near the client even when the host isn't looking at them (otherwise a boss did no damage to the client and froze after a throw)",
    npc_boss_fx = "The client sees the rock a boss throws and hears the boss roar (attack, throw, death)",
    npc_effects = "The client sees fire on burning bosses and people and blood when they are hit",
    npc_health = "The client's health bar for bandits, soldiers, raiders and traders uses the maximum health from the host",
    npc_looks = "People look the same for the client as for the host (clothes, hair, beard, backpack, helmet, mask), and so do settlement civilians (with the names on their name plates) and the dog",
    npc_marker = "Client: the enemy marker (mark key) goes 60 s after the enemy left sight, as in single player (before, a client's marker stayed until the enemy died)",
    client_movement_authority = "The host trusts the client's position (removes jitter of the client's character)",
    player_names = "Another player's name above them when you look at them or stand close (a name plate, like the civilians')",
    player_names_range = "How far (m) you can see the name of the player you look at",
    player_names_near = "Closer than this (m) the name shows without looking at the player",
    gps_markers = "Players with a GPS are shown to the others on the big map (a dot with a name; map markers show only if you have a GPS too)",
    gps_compass = "All other players are marked with a dot on the compass (shown while you wear one)",
    map_markers_shared = "Markers players put on the big map (double-click) are seen by everyone: others' in the player's colour, the name in a tooltip; deleting a marker removes it for everyone. The host decides; off = everyone sees only their own markers (on a client, off only hides others' markers on its map)",
    hide_zero_damage_numbers = "Client: don't show \"0\" on a knife hit (a local client hit without server rights; the real damage comes from the host)",
    client_hitmarker = "Client: a hit marker at the crosshair when a firearm or crossbow hits, as in single player (white for the body, red for the head); clients used to have none",
    relay_sounds = "Sounds the game plays only for the player themselves (separated by ';'): the others hear them too. Empty-gun click",
    whistle_sync = "Other players hear the whistle (distraction); a client's whistle distracts zombies. Only the whistler's skill is checked",
    shot_sounds = "Other players' gunshots: the weapon's sound (from its BP_WeaponsPickupComponent) where MC_WeaponEffects arrived; the host relays distant shots (120–350 m)",
    mirror_sounds = "Fallback: the host relays players' item sounds to clients with an SND message",
    sound_range_guard = "Other players' sounds that have no distance falloff in the game (flashlight, eating and drinking, syringe, loading shells, crossbow shot and reload, flare gun shot, suppressed revolver) are heard only near them, with the falloff the game gives similar sounds; before, they could be heard across the whole map",
    melee_client_hits = "A client's normal melee hit: the client decides the hit, the host deals the damage with the game's HitBody/HitHead (the host's copy of the swing missed moving zombies)",
    reload_loop_fix = "One-round reloads (hunting rifle, Mosin, shotguns, Winchester, revolver, grenade launcher): when the player finishes reloading, the animation stops for other players too (it used to loop forever)",
    geiger_own_only = "Dosimeter: everyone hears only their own Geiger counter (the host no longer hears the client's, the client hears their own)",
    radiation_exit_sync = "Host: when a client leaves a radiation zone, their radiation stops rising (the zone timer used to keep running on the host)",
    fix_client_damage = "Host: clients' weapon damage, damage falloff and (knife) strength use their own stats",
    coop_slowtime_off = "Co-op: the game's \"Slow motion\" option (inventory, radial menu) is off while other players are connected and comes back afterwards",
    relay_skill_xp = "Host: skill XP the game gives only on the server (marksmanship, toughness, first aid, stamina) and the skill reset after death reach the client",
    stealth_sync = "Client stealth: zombies hear the client's footsteps no louder than the client's own game computes them (crouch, run, Stealth skill)",
    stealth_trace = "Debug, host: log which sense (sight or hearing) and from how far a zombie noticed a player",
    shot_noise = "Zombies hear a client's shots: the host reports the noise of each client shot to the AI just as the game does for the shooter (weapon sound radius, suppressor and muzzle brake as the client's own game computed them); zombies used to not hear client shots",
    weapon_pose_fix = "Host: other players' weapon pose as in single player: the host fixes the combat state (weapon in hands, aiming) the client sends before a slot change, and passes the client's knife aiming and ADS to the others",
    client_weapon_stats = "Host: take the client's weapon stats from its report instead of the item record on the host (fallback)",
    host_weapon_fx_quiet = "Host: doesn't repeat the effects of a client's weapon (camera shake on shots and hits); the client does them itself",
    client_quiet_others = "Client: other characters don't affect you through \"player 0\" (camera shake from others' aiming and knife, others' illnesses, others' XP)",
    game_ui_input = "Client: game windows (inventory, trade, containers) keep the cursor and mouse control: neither the mod nor late game events (the end of a trader dialogue) switch back to camera control while a window is open",
    notes_relay = "Host and client: game notifications about a client's action that the game runs on the host (gas mask filter, \"too early to sleep\", spawn point, trader's money, generator, water well, hangar keycard and so on) appear on that client's screen, with the game's own text and icon",
    notes_owner_only = "Host and client: a game notification about another player's action (a client filled bottles at a well, hit a nest, the mod applies the host's state) is taken off the screen of the player who didn't do it",
    turret_sync = "Camp turrets and player-built turrets: the host's turret shots, aim, switching off, damage and health are shown to clients; a client switching a turret off and its hits reach the host. The host decides",
    player_event_notes = "Game-style notices about other players: \"<name> died\" and \"<name> respawned\" (no cause of death). Everyone sees them except that player; at most once in 30 s per player. The host decides; on a client, turning it off only hides them on that client's screen. Players joining and leaving are announced as before",
    redirect_player0 = "Host: the client's game logic (\"player 0\" in BP) works with the client's character, not the host's (fractures, hunger, notifications)",
    client_cvars = "Console variables the client runs on connecting, separated by ';'",
    move_response_interval = "Debug: minimum interval (s) between the server's replies to the client's movement; 0 = engine default",
    replicate_items = "Items (worn, dropped, loot) are the host's network objects; the client's local loot is removed",
    prevent_client_loot = "Client: random loot spawners on your copy of the level don't create their own loot; loot comes from the host (otherwise extra items appeared next to the host's); when off, the extra loot is removed after it appears, as before",
    craft_one_at_a_time = "Client: crafting one item at a time: the next request goes after the host answers, \"craft N\" is done one by one (otherwise the host took the components once and created all the items; the client's components got stuck)",
    medical_host_cure = "Host: another player's bandage, medkit or medicine also removes bleeding, fractures and infection on the host's copy of the character; other players' bleeding and fractures also heal on the host (otherwise bleeding kept taking health)",
    client_infection_hud = "The infection bar on a client's screen (the dark plate with a bar and a virus icon at the left middle of the screen after a zombie bite): the game showed it only to the host; the host tells the client whether its character is infected and by how much",
    item_gains_from_host = "Items the game gives on use (rags from tearing clothes, an empty can or bottle, a filled bottle, box contents) are added by the host; the client's blinking local copy is removed (otherwise the item existed only on the client and blinked)",
    craft_needs_components = "A client's crafting must be paid for with items the host also has: otherwise the client doesn't send it and the host takes the created item away (a \"ghost item\" on the client used to allow endless crafting)",
    menu_key = "Menu key (a name from the UE4SS Key table)",
    players_hud = "The player table in the top right corner while playing: who is in the world and the ping (the host sees every client's ping, a client its own ping to the host). The players_hud_key key (F8) shows and hides it",
    players_hud_key = "Key that shows / hides the player table (a name from the UE4SS Key table)",
    client_cheats = "Host: clients may use the game's debug menu and cheats (Debug.Allow: items and XP, invincibility, no-clip, no hunger, thirst or fatigue). Off = the client's mod keeps them off while the client is in your world and gives its own settings back afterwards (only an edited mod gets around it)",
    friendly_fire = "Host: friendly fire: players can hurt each other (bullets, blows, stomps, grenades, launcher shells and rockets, Molotov fire). Off = the host drops that damage, while zombies, people, animals, falls, traps, barrels and turrets hurt as usual, and so do your own grenade and fire. Players get a notice when the rule changes; clients don't need to set it: the host decides",
    banned_players ="Host: banned players separated by ';': a SteamID (optionally SteamID:Name) or a name. The Ban button in the player list adds a player here; bans are lifted on the co-op panel's World tab",
    join_access = "Host: who may join your world: open (anyone), password (players on allowed_players at once; everyone else, by IP and through Steam alike, gives join_password), approve (players on allowed_players at once; you let the others in on the co-op panel's World tab, no answer in 2 minutes = turned away) or list (invite only: only players on allowed_players; Invite on the Steam tab puts a friend there)",
    join_password = "Host: the password for join_access = password, set on the World tab. The right password puts the player on allowed_players. Stored here as plain text: don't reuse your Steam or email password",
    allowed_players = "Host: players allowed in, separated by ';': a SteamID (optionally SteamID:Name) or a name. Allow on the World tab adds a player here",
    max_players = "Host: how many players can be in your world at once, you included; 0 = no limit. A full world turns new players away",
    lobby = "Co-op pages in the game's menus (main menu and pause)",
    menu_in_main_menu = "The co-op panel opens by itself in the main menu. Only without the Co-op button in the game's menu (lobby = false): with the button, the panel opens from it",
    join_cover = "Client: while you join a friend, a dark cover with the joining progress (connection to the host, loading the world, your character, items and place) hides the screen until your character stands where you left (no view from under the ground). At most a minute in the host's world; the menu key (F7) or Esc shows the game at once",
    language ="Language of the panel and the mod's messages: auto (the game's language, or Windows' if the game has no Russian; the Co-op button in the game's menu follows the game's language), ru or en",
    ui_open_at_menu = "Test: the co-op panel opens by itself in the main menu (for screenshots; Mods/SDCoop/ui_test.txt picks the tab)",
    quest_dialogues = "A conversation with an NPC (traders, quest givers) opens for whoever started it, not for the host",
    quest_hud = "Client: the dialogue window and quest notifications (the game's Narrative interface); without it dialogues stay with the host",
    quest_vendor_fallback = "Client: if the trade window didn't open by itself after a dialogue, open it on the host's signal",
    trade_host_traders = "Client: the military trader and the \"Shakes & Cones\" trader are the host's only; the client doesn't create its own copy (a spawner on your copy of the level makes it) and removes it: the host doesn't know it, and you can't trade with it",
    trade_vendor_money = "The trader's money in the client's trade window matches the host's: the host sends it when a conversation starts and after each deal (the game doesn't send it over the network, and the client had its own random number)",
    quest_trace = "Debug: dlg-trace lines in UE4SS.log: where and for whom NPC dialogues start",
    quest_own = "Host: each player has their own quests, as in single player: a client takes quests from NPCs (paid intel, zones, the starting one), completes them and gets the XP; the quest lives in the client's journal. Off = the old \"host's shared journal\" mode (the group quest settings below work only in it)",
    quest_bounty_shared = "Laptop (intel) bounties are shared: the quest stays in the buyer's journal, but its marker, its tasks in the tracker and the completion XP go to every player; anyone may kill the targets and a \"go to a place\" task counts for anyone (with own quests on)",
    quest_sync = "The client sees the group's quests (the host's journal): notifications about new quests and progress",
    quest_tracker = "Show group quests in the game's quest tracker (the \"quest updated\" panel)",
    quest_datatask = "A client's actions for quests (the lab generator) count toward group quests",
    quest_goto = "A \"go to a place\" task is done when any player gets there",
    quest_crate = "A classified crate opened by a client also opens for the host (quest progress, reward)",
    quest_markers = "Group quest markers on the client's map and compass",
    quest_xp = "Every client also gets XP for a completed group quest",
    diag_snapshots = "Debug: every N seconds log a state snapshot (character, health, HUD, controls, ping, zombies nearby), and at once a lost character, HUD or controls; 0 = off",
    gap_trace = "Debug: count what the game does for each player (Mods/SDCoop/gaptrace_<role>.csv; compare with tools/gapdiff.py)",
    listen_ip_fallback = "Before an IP join, switch the game's net driver to plain UDP sockets (port 7777) if the mod has not done it at start (both helper Steam joins and IP joins use them)",
    steam_server_api = "Add bUseSteamNetworking=False to the game's Engine.ini (plain UDP sockets when the game runs through Steam: needed both for joining through Steam and by IP); takes effect from the next start",
    steam_link = "Joining through Steam without IP or VPN: the SDCoopSteamLink.exe helper carries the game's traffic over the Steam network; friends see \"Join Game\" while your world is open",
    steam_link_friends_only = "Host: only your Steam friends (and players in steam_link_allow) can join through Steam; off = anyone who knows your Steam code",
    steam_link_allow = "Host: Steam codes (SteamID64, comma-separated) of players who aren't your friends but may join through Steam",
    explosion_shake_zone = "Screen shake from an explosion (exploding zombie, barrel) for every player whose character is in the blast zone, and only for them (the game shook \"player 0\": the host, even when only a client was near the blast)",
    throw_sync = "Grenades, pipe bombs, firecrackers, Molotov cocktails and bottles: the host performs a client's throw (explosion, damage, fire, noise for zombies; kills and XP go to the client), and everyone sees every throw: flight, explosion, fire",
    throw_single_consume = "Client: the throw animation starts at once, as in single player; holding the throw key no longer uses up several grenades for one throw",
    launcher_sync = "Grenade launcher, rocket launcher, flare gun and crossbow: a client's projectile flies on the host (damage, explosion, noise for zombies, flare fire, the bolt can be picked up; kills and XP go to the client), and everyone sees any player's projectile: flight, explosion, flare light, a stuck bolt",
    stations_on_host = "A client's dismantling workbench: the host does the dismantling (the button did nothing for the client: the station's data exists only on the host)",
    loot_box_attachments = "A weapon from a loot box gets its standard attachments for the client, as in single player",
    client_tools = "A client's binoculars and night vision: the \"is it worn\" check and the battery use the host's data (otherwise the game said there were no binoculars and the night vision didn't turn on)",
    client_gear_hud = "The icon with a percent above a client's hunger, thirst and radiation circles, as the host has it: the respirator filter in a radiation zone (the host sends the percent), the battery of the handheld flashlight and the night vision. Weapon modules (light, laser) have no such icon even in single player",
    client_durability_from_host = "A client's repair kit and filter change: the host changes the durability (otherwise the repair wasn't kept)",
    host_adds_to_inventory = "Items the host's code gives a client (bottles, flasks and canisters filled at a well, caught fish) go into their inventory instead of dropping at their feet",
    inventory_walk_events = "Host: a connected player's inventory is read again only after that player acts on items (a move, a use, a craft, a pickup, a grant by the host), and checked with a quick fingerprint every 10 s; off = as before: a full read of every inventory every second (if something in a client's inventory does not update on the host)",
    refused_items_to_feet = "If the host puts an item into a client's pocket that doesn't take such items there (a wallet, a medical bag), the item drops at the client's feet instead of staying invisible (otherwise the game deleted it the next time that bag was rebuilt)",
    container_moves_reliable = "Item moves by a client in chests, crates, corpses and storage: the host's answer arrives reliably (no blinking until the container is reopened)",
    deathbox_remove_empty = "An emptied dead player's loot box disappears for everyone (the host removes it 2 s after its last item was taken; one that was empty from the start, once it has been opened)",
    world_sync = "Co-op world: the state of world objects is shared by all players (off = every world_* option is off)",
    world_containers = "A container searched by anyone is searched for everyone (no magnifier and no second wait), a picked lock is open for everyone; the host tells players who join",
    world_loot_noise = "Zombies and other players hear the noise of a client searching; the \"search\" shake is only for the one searching",
    world_doors = "Doors, gates, picked locks: opening and closing is seen by everyone, including players who joined later or were far away",
    world_harvest = "Trees, rocks, scrap piles: what was chopped disappears for everyone; the log, stone or metal goes to whoever chopped it",
    world_objects = "Trash piles, exploding barrels, infestation nests: a client's shots and hits work on the host, destruction is seen by everyone",
    world_build = "Building by a client: the host places or moves the building, the item is taken from the builder; a dismantled building goes back to whoever dismantled it",
    world_build_release = "Buildables a client used last (garage and wooden doors, gates, workbenches, generators, storage) keep no left-over user on the host: the host sees the prompt and uses them as its own (before, the host couldn't open a door the client had placed, moved or opened)",
    world_build_doors = "Placed doors and gates (wooden, metal, bunker, gates, garage) are the same for everyone: a door swings to the same side as for the player who opened it (before, on a client it swung away from that client), and it is open or closed as on the host, also when the game's signal got lost, the door was far away or the player joined later (the host sends the states on change, on joining and every 20 seconds; a client fixes a door with the door's own open / close)",
    world_build_power = "Generator power of buildables (garage door, lamps) on a client is as on the host: a client's generators no longer compute power and fuel use themselves (that is the host's job), and the garage door gets \"powered / not powered\" from the host - nobody sees \"Requires power\" while the host's door has power",
    world_rename = "Renaming placed storage (crates, cupboards, safes): a client gets the game's own Rename window, the host sets the new name with the game's own function (saved with the host's world), and every player sees that name, including players who join later; names the host gives show for clients too",
    world_resource_to_inventory = "A client's resources from world objects (wood, stone, scrap, a dismantled building) go into their inventory, not onto the ground at their feet",
    world_horde_bosses = "A horde boss dies with the death of the player nearest to it (as in single player), not always with the host's death",
    world_infest_wave_target = "Host: an infestation nest's wave of enemies goes for the player who hit the nest last if they are alive and within 150 m of it, else for the nearest living player (before: always the host)",
    world_prefabs = "Camps, trucks, stashes and random events are the same for everyone: the host creates them (the client's own random ones don't appear)",
    world_events_sync = "Random world events (a crashed helicopter, an abandoned truck) for the client as for the host: the crash sound (if the client is within its hearing range), the game's message, the map marker and the wreck with its fire and smoke at any distance; a player who joins later gets the markers; no false crash sound of the client's own",
    world_poi_clear = "Clearing major locations (the location's boss and its special container) counts for a client too: the special container a client searches first gives that client its XP (the game's own function, as in single player) and counts as searched in the host's world (saved); every player's map tooltip of the location shows how many of its bosses are dead and whether the special container was searched, as in the host's world, also after joining",
    infestation_xp_shared = "XP and the 'infestations destroyed' count for a destroyed infestation nest (primary or secondary) go to every player nearby, not only the finisher; each by their own level, with their own notification",
    infestation_xp_radius_m = "Radius (m) around an infestation nest within which players share the XP for destroying it",
    vehicle_sync = "Co-op vehicles: the host itself seats a player in a vehicle and drives it by their controls (getting in and out, headlights, horn, flipping, towing, refuelling, repair, buying from a trader)",
    vehicle_passengers = "Players get into an occupied vehicle as passengers (how many seats: by the vehicle, see \"More seats in vehicles\"). When the driver gets out, the passengers stay in their seats and the vehicle stands on the handbrake with the engine off until somebody drives; a passenger moves with the vehicle_seat_key key (G): to the wheel when it is free, else to the next free seat",
    vehicle_seat_key = "The key a passenger changes seats with (an Unreal key name: G, U, P, I...): to the wheel when it is free, else to the next free seat, round; none free: a notice. The driver does not move with it. Empty = no key (to drive, get out and in again). The game's own keys (F, WASD, Space, H, K, R, digits) do not suit: their action runs too",
    vehicle_seats = "More than two players in a vehicle: the 4x4 jeep, damaged sedan, Charger, sheriff car, SUV and Humvee have four seats - the driver, the one next to them and two in the back; the Buggy and golf cart have two; the other vehicles have two for now (the seats in truck beds and vans are still being tuned). A player takes the first free seat and sees \"Seat 3 of 4\". The host decides; off = as before, two seats",
    vehicle_seats_untuned = "Test, host: turn on the seats not tuned yet - pickup beds, the flatbed, the semi truck's frame (sitting on the floor), benches in the van, ambulance, RV, SWAT van, APC and military truck. Such a seat may hang in the air or go into a wall: they are tuned with the sdcoop_seat command. Off until checked in the game",
    vehicle_state = "The client sees vehicles as the host does: colour, fuel, durability, headlights, engine sound, players in the seats",
    vehicle_ghosts = "Client: don't create your own ghost vehicles (vehicle spawners fired on the client separately from the host) and remove such vehicles",
    vehicle_radio = "Shared vehicle radio: on, track, pause, volume and speed chosen by any player sitting in the vehicle are heard by everyone from that vehicle (players who join later hear the track from the same point). The music is the files in the Radio folder in each player's game folder: a player without that file hears one of their own tracks instead",
    savecheck = "Saves: after every save and load write a [SAVE] line to UE4SS.log: slot, who is excluded, whether the host's inventory matches, which files were written; console sdcoop_savecheck",
    savecheck_counts = "Saves: after the host saves, count the saved world objects (containers, buildings, vehicles, traders, nests) for the [SAVE] line",
    save_guard = "Host: before every save, other players' characters and controllers are excluded from the save, the host's character is not; the host's world is never saved into the client's temporary slot",
    save_repair = "Host: if another player's inventory got into the host's save, the game saves once more",
    client_save_guard = "Client: your quick saves and sleep write only to the temporary slot and don't send your inventory into the host's save",
    autosave_watchdog = "Host: if the game's autosave is on but its 10-minute timer isn't running, start it the way the game does",
    coop_autosave = "Host: in co-op the game saves the world every 10 minutes, even if autosave is off in the game's settings (the setting itself isn't changed)",
    backup_keep = "How many recent automatic save backups to keep in Saved/SDCoop_Backups (0 = all)",
    debug = "Detailed log in UE4SS.log",
    net_speed = "Host: transfer rate limit per player, bytes/s. The engine uses 100000, which wasn't enough with many zombies near a client (stutter, zombies and players \"teleporting\"). 0 = engine default",
    ai_net_rate = "Host: how many times a second zombies and other AI are sent to clients (the game uses 100). Lower = less load on the host and the network; the client smooths the movement. 0 = game default",
    net_send_budget = "Mod messages to each player (and from a client to the host) don't come as a flood: up to 48 at once, then no more than 24 a second, the rest wait in order; movement, combat, vehicles and joining skip the queue. While nothing comes from the other side (its game is stalled), the queue waits. Without this, 2569 messages in 4 s kicked a client out of the game",
    lua_gc = "Debug: Lua garbage collector mode: incremental (in steps, as before) or generational (by generations: shorter pauses and less work in measurements, but not yet tested in the game)",
    lua_gc_pause = "Lua garbage collector (incremental mode): a new cycle starts when Lua memory reaches N% of the live data. Lua uses 200; at 150 the mod's peak memory is about half. 0 = Lua default",
    lua_gc_stepmul = "Lua garbage collector (incremental mode): collection speed relative to allocation, %. Lua uses 100; at 200 a cycle ends twice as fast. 0 = Lua default",
    log_flush_ms = "Log: if writing a line to UE4SS.log ever held the game (100 ms or more: a slow disk or an antivirus; on a client such writes stopped the game for 2–9 s), lines are then written in batches at most once every N ms. 0 = always write each line at once",
    log_batch_always = "Log: write UE4SS.log in batches (every log_flush_ms) from the start, without waiting for the first slow write. If the game crashes, the last log lines are lost (at most log_flush_ms)",
    perf_report = "Debug: every N seconds write [PERF] to the log: FPS and how much of the game's time the heaviest mod hooks and tasks take; 0 = off",
    perf_bench_no_bp_hooks = "Debug, single player only: the mod registers none of its Blueprint function hooks (UE4SS then skips its check after every Blueprint call). For sdcoop_bench: a run with and without it shows what UE4SS's check costs. Co-op does NOT work in this mode; takes effect after a game restart",
    debug_net = "Debug: log every network message of the mod (dozens a second; without it frequent messages aren't logged)",
    debug_probes = "Debug: heavy movement probes (hooks on movement and replication functions every frame); they load the game heavily; only for hunting movement stutter",
}

-- Short labels for bool settings: { Russian, English }. A setting without
-- one gets a label cut from its description (M.label).
M.LABEL = {
    listen_on_load = { "Открывать мой мир для друзей", "Keep my world open to friends" },
    auto_join = { "Автоподключение к хосту из меню", "Auto-join the host from the menu" },
    auto_host = { "Тест: сразу запускать сервер из меню", "Test: start a server from the menu" },
    no_pause = { "Без паузы, пока подключены игроки", "No pause while players are connected" },
    sync_env = { "Общее время суток и погода", "Shared time of day and weather" },
    unload_menu_level = { "Выгружать сцену меню у клиента", "Unload the menu scene on clients" },
    block_menu_level = { "Не загружать сцену меню при подключении", "Skip the menu scene when joining" },
    respawn_native = { "Возрождение кнопками игры", "Respawn with the game's buttons" },
    guard_player_sweeps = { "Экраны игры не удаляют чужих персонажей", "Game screens keep other players' characters" },
    fresh_client_progress = { "Новый игрок начинает с 1 уровня", "New players start at level 1" },
    persist_clients = { "Сохранять персонажей друзей в моём мире", "Save friends' characters in my world" },
    persist_restore_position = { "Возвращать игрока туда, где он вышел", "Return players where they left" },
    persist_early_id = { "Персонаж сразу на сохранённом месте", "Character straight at the saved place" },
    persist_follow_host_save = { "Персонажи друзей — по сохранению мира", "Friends' characters follow the world save" },
    persist_map = { "Сохранять открытые места на карте", "Keep discovered map places" },
    map_shared = { "Общие открытые места на карте", "Shared discovered map places" },
    skilltree_sync = { "Навыки клиента действуют у хоста", "Client skills work on the host" },
    bed_for_client = { "Кровать игрока работает для него", "A player's bed works for that player" },
    client_sleep_skips_night = { "Сон игрока пропускает ночь", "A player's sleep skips the night" },
    coop_sleep_all = { "Ночь проходит, когда спят все", "Night passes when everyone sleeps" },
    ai_fix = { "Зомби только с сервера", "Zombies only from the server" },
    char_create = { "Свой персонаж для кооператива", "Own co-op character" },
    fix_capsule_replication = { "Без откидывания персонажа назад", "No rubber-banding of characters" },
    ai_kill_credit = { "Убийство и опыт — тому, кто убил", "Kills and XP go to the killer" },
    ai_attack_montages = { "Атаки зомби и зверей видны клиенту", "Clients see zombie and animal attacks" },
    ai_corpses = { "Трупы остаются у клиентов", "Corpses stay for clients" },
    ai_healthbar = { "Полоса здоровья врага у клиента", "Enemy health bar for clients" },
    ai_offscreen_combat = { "Звери атакуют клиента вдали от хоста", "Animals fight clients away from the host" },
    ai_zombie_looks = { "Зомби выглядят у всех одинаково", "Zombies look the same for everyone" },
    ai_kill_log = { "Писать убийства зомби в лог", "Log zombie kills" },
    ai_client_ghosts = { "Убирать зомби, которые есть только у клиента", "Remove client-only zombies" },
    ai_zombie_fx = { "Эффекты особых зомби у клиента", "Special zombie effects for clients" },
    ai_keep_chase = { "Зомби гонится за тем, кого видит", "Zombies chase whoever they still see" },
    ai_spawn_check_all = { "Не создавать зомби рядом с любым игроком", "No spawns next to any player" },
    ai_player_scaling = { "Больше зомби при нескольких игроках", "More zombies with more players" },
    ai_client_optimizer_guard = { "Проверка: копии ИИ хоста, пока клиент мёртв", "Test: host AI copies while a client is dead" },
    ai_client_far_movement = { "Дальние зомби двигаются плавно", "Far zombies move smoothly" },
    ai_host_cap = { "Предел зомби в мире хоста", "Zombie limit in the host's world" },
    ai_toughness = { "Зомби крепче при нескольких игроках", "Tougher zombies with more players" },
    ai_horde_beacon = { "Маяк орды у клиентов", "Horde beacon for clients" },
    ai_horde_continue = { "Орда идёт, пока жив хоть один игрок", "The horde goes on while anyone is alive" },
    -- number rows (M.NUMS_OF): the text left of the box
    ai_player_scaling_pct = { "+ % зомби в группе за каждого игрока", "+% zombies in a group per player" },
    ai_player_scaling_cap_pct = { "Группа не больше, % от обычной", "A group at most, % of normal" },
    ai_host_cap_zombies = { "Предел при 2–4 игроках", "The limit with 2-4 players" },
    ai_host_cap_per_player = { "+ зомби за каждого игрока сверх четырёх", "+ zombies per player beyond four" },
    ai_host_cap_max = { "Предел не выше", "The limit at most" },
    ai_toughness_health_pct = { "Крепость зомби: + % за каждого игрока", "Zombie toughness: +% per player" },
    ai_toughness_damage_pct = { "Удар зомби: + % за каждого игрока", "Zombie hits: +% per player" },
    ai_toughness_cap_pct = { "Не больше, % от обычного", "At most, % of normal" },
    npc_offscreen = { "Боссы и люди действуют рядом с клиентом", "Bosses and people act near clients" },
    npc_boss_fx = { "Камни и рёв боссов у клиента", "Boss rocks and roars for clients" },
    npc_effects = { "Огонь и кровь на боссах и людях", "Fire and blood on bosses and people" },
    npc_health = { "Здоровье людей у клиента как у хоста", "People's health matches the host" },
    npc_looks = { "Люди выглядят у всех одинаково", "People look the same for everyone" },
    npc_marker = { "Метка врага исчезает у клиента", "Enemy markers expire for clients" },
    client_movement_authority = { "Движение клиента без дёрганья", "Smooth client movement" },
    player_names = { "Имена над игроками", "Names above players" },
    gps_markers = { "Игроки на карте (GPS)", "Players on the map (GPS)" },
    gps_compass = { "Игроки на компасе", "Players on the compass" },
    map_markers_shared = { "Общие метки на карте", "Shared map markers" },
    hide_zero_damage_numbers = { "Не показывать «0» при ударе ножом", "Hide \"0\" on knife hits" },
    client_hitmarker = { "Хитмаркер у клиента", "Hit marker for clients" },
    whistle_sync = { "Свист слышат все", "Everyone hears whistling" },
    shot_sounds = { "Звуки чужих выстрелов", "Other players' gunshot sounds" },
    mirror_sounds = { "Запасная пересылка звуков предметов", "Fallback item sound relay" },
    sound_range_guard = { "Чужие звуки только рядом", "Other players' sounds only nearby" },
    melee_client_hits = { "Удары клиента холодным оружием", "Client melee hits" },
    reload_loop_fix = { "Перезарядка по патрону не зацикливается", "Single-round reloads don't loop" },
    geiger_own_only = { "Каждый слышит только свой дозиметр", "Each hears only their own dosimeter" },
    radiation_exit_sync = { "Радиация не растёт после выхода из зоны", "Radiation stops after leaving a zone" },
    fix_client_damage = { "Урон клиента по его оружию", "Client damage uses their own weapon" },
    coop_slowtime_off = { "Без замедления времени в кооперативе", "No slow motion in co-op" },
    relay_skill_xp = { "Опыт навыков клиента от хоста", "Skill XP from the host to clients" },
    stealth_sync = { "Скрытность клиента как в одиночной игре", "Client stealth as in single player" },
    stealth_trace = { "Писать в лог, как зомби заметил игрока", "Log how zombies spot players" },
    shot_noise = { "Зомби слышат выстрелы клиента", "Zombies hear client shots" },
    weapon_pose_fix = { "Поза оружия других игроков", "Other players' weapon pose" },
    client_weapon_stats = { "Характеристики оружия из отчёта клиента", "Weapon stats from the client's report" },
    host_weapon_fx_quiet = { "Хост не повторяет тряску оружия клиента", "Host skips clients' weapon shake" },
    client_quiet_others = { "Чужие персонажи не трясут ваш экран", "Others don't shake your screen" },
    game_ui_input = { "Курсор в окнах игры (инвентарь, торговля)", "Cursor in game windows (inventory, trade)" },
    notes_relay = { "Уведомления игры — тому, кто действовал", "Game notices go to the acting player" },
    notes_owner_only = { "Убирать уведомления о чужих действиях", "Hide notices about others' actions" },
    player_event_notes = { "Уведомления: игрок погиб / возродился", "Notices: a player died / respawned" },
    players_hud = { "Таблица игроков на экране (F8)", "Player table on screen (F8)" },
    client_cheats = { "Клиентам можно читы и отладочное меню игры", "Clients may use the game's cheats and debug menu" },
    friendly_fire = { "Огонь по своим", "Friendly fire" },
    turret_sync ={ "Синхронизация турелей", "Turret sync" },
    redirect_player0 = { "Логика игры клиента — для его персонажа", "Client game logic uses their character" },
    replicate_items = { "Предметы общие через хоста", "Items shared through the host" },
    prevent_client_loot = { "Без лишнего лута у клиента", "No extra loot on clients" },
    craft_one_at_a_time = { "Крафт клиента по одному предмету", "Clients craft one item at a time" },
    medical_host_cure = { "Лечение снимает раны и у хоста", "Healing also cures on the host" },
    client_infection_hud = { "Полоса заражения у клиента", "Infection bar for clients" },
    item_gains_from_host = { "Предметы от использования выдаёт хост", "Items from use come from the host" },
    craft_needs_components = { "Крафт только из настоящих предметов", "Crafting needs real components" },
    lobby = { "Кнопка «Кооператив» в меню игры", "\"Co-op\" button in the game menus" },
    menu_in_main_menu = { "Панель кооператива в главном меню", "Co-op panel in the main menu" },
    join_cover = { "Заставка при подключении к другу", "Cover screen while joining a friend" },
    ui_open_at_menu = { "Тест: открывать панель в меню", "Test: open the panel in the menu" },
    quest_dialogues = { "Разговор с NPC — у того, кто заговорил", "NPC talks open for whoever talks" },
    quest_hud = { "Окно диалогов и заданий у клиента", "Dialogue and quest window for clients" },
    quest_vendor_fallback = { "Открывать торговлю по сигналу хоста", "Open trading on the host's signal" },
    trade_host_traders = { "Только торговцы хоста", "Only the host's traders" },
    trade_vendor_money = { "Деньги торговца как у хоста", "Trader money matches the host" },
    quest_trace = { "Писать диалоги NPC в лог", "Log NPC dialogues" },
    quest_own = { "Свои задания у каждого игрока", "Each player has their own quests" },
    quest_bounty_shared = { "Задания с ноутбуков общие", "Laptop bounties are shared" },
    quest_sync = { "Задания группы видны клиенту", "Clients see group quests" },
    quest_tracker = { "Задания группы в трекере", "Group quests in the tracker" },
    quest_datatask = { "Действия клиента идут в задания группы", "Client actions count for group quests" },
    quest_goto = { "«Дойти до места» — любой игрок", "\"Go to a place\": any player" },
    quest_crate = { "Ящик, открытый клиентом, открыт у хоста", "Crates opened by clients open for the host" },
    quest_markers = { "Метки заданий группы у клиента", "Group quest markers for clients" },
    quest_xp = { "Опыт за задание группы каждому", "Group quest XP for everyone" },
    gap_trace = { "Отладка: счёт действий игры по игрокам", "Debug: game actions per player" },
    listen_ip_fallback = { "Обычные UDP-сокеты перед подключением по IP", "Plain UDP sockets before an IP join" },
    steam_server_api = { "Сетевая настройка игры в Engine.ini", "Game network setting in Engine.ini" },
    steam_link = { "Подключение через Steam (без IP и VPN)", "Join through Steam (no IP, no VPN)" },
    steam_link_friends_only = { "Через Steam — только друзья", "Steam joins: friends only" },
    explosion_shake_zone = { "Тряска от взрыва — только вблизи", "Explosion shake only near the blast" },
    throw_sync = { "Броски гранат и бутылок видны всем", "Everyone sees thrown grenades and bottles" },
    throw_single_consume = { "Одна граната за бросок", "One grenade per throw" },
    launcher_sync = { "Гранатомёт, ракеты и арбалет — у всех", "Launchers and crossbow for everyone" },
    stations_on_host = { "Разборочный верстак у клиента", "Dismantling bench for clients" },
    loot_box_attachments = { "Обвесы на оружии из коробок", "Attachments on loot-box weapons" },
    client_tools = { "Бинокль и ПНВ у клиента", "Binoculars and night vision for clients" },
    client_gear_hud = { "Значок фильтра и батареи у клиента", "Filter and battery icon for clients" },
    client_durability_from_host = { "Ремонт и фильтры у клиента", "Repairs and filters for clients" },
    host_adds_to_inventory = { "Предметы от хоста — в инвентарь", "Host-given items go to the inventory" },
    refused_items_to_feet = { "Невидимый предмет — под ноги", "Unseen items drop at your feet" },
    inventory_walk_events = { "Чтение инвентаря по событию", "Read inventories on change" },
    container_moves_reliable = { "Надёжные перемещения в сундуках", "Reliable item moves in containers" },
    deathbox_remove_empty = { "Пустой ящик погибшего исчезает", "An emptied death box disappears" },
    world_sync = { "Общий мир (все пункты «Мир»)", "Shared world (all World options)" },
    world_containers = { "Обысканное обыскано у всех", "Searched containers stay searched" },
    world_loot_noise = { "Шум обыска слышат зомби", "Zombies hear searching" },
    world_doors = { "Общие двери и ворота", "Shared doors and gates" },
    world_harvest = { "Общие деревья, камни и металлолом", "Shared trees, rocks and scrap" },
    world_objects = { "Общие мусор, бочки и гнёзда", "Shared trash, barrels and nests" },
    world_build = { "Строительство клиента через хоста", "Client building through the host" },
    world_build_release = { "Хост пользуется постройками клиента", "Host can use the client's buildables" },
    world_build_doors = { "Двери и ворота построек у всех одинаковые", "Placed doors and gates match for everyone" },
    world_build_power = { "Питание построек — от хоста", "Buildable power comes from the host" },
    world_rename = { "Переименование хранилищ у всех", "Storage renaming for everyone" },
    world_resource_to_inventory = { "Ресурсы — в инвентарь", "Resources go to the inventory" },
    world_horde_bosses = { "Босс орды привязан к ближайшему игроку", "Horde boss tied to the nearest player" },
    world_infest_wave_target = { "Волна гнезда идёт к ближайшему игроку", "Nest waves go for the nearest player" },
    world_prefabs = { "Общие лагеря и события", "Shared camps and events" },
    world_events_sync = { "Случайные события: звук, сообщение, метка", "Random events: sound, message, marker" },
    world_poi_clear = { "Зачистка локаций (босс, особый ящик) у всех", "Location clears (boss, crate) for all" },
    infestation_xp_shared = { "Опыт за гнёзда всем рядом", "Nest XP for everyone near" },
    vehicle_sync = { "Машины в кооперативе", "Vehicles in co-op" },
    vehicle_passengers = { "Пассажиры в машинах", "Vehicle passengers" },
    vehicle_seats = { "Больше мест в машинах", "More seats in vehicles" },
    vehicle_seats_untuned = { "Неподобранные места (проверка)", "Untuned seats (test)" },
    vehicle_state = { "Машины у клиента как у хоста", "Vehicles match the host" },
    vehicle_ghosts = { "Без машин-призраков у клиента", "No ghost vehicles on clients" },
    vehicle_radio = { "Общее радио в машине", "Shared vehicle radio" },
    savecheck = { "Строки [SAVE] в логе", "[SAVE] lines in the log" },
    savecheck_counts = { "Считать сохраняемые объекты", "Count saved world objects" },
    save_guard = { "Чужие персонажи не попадают в сохранение", "Keep others out of the host's save" },
    save_repair = { "Пересохранять, если попал чужой инвентарь", "Re-save if another inventory got in" },
    client_save_guard = { "Сохранения клиента — во временный слот", "Client saves go to a temporary slot" },
    autosave_watchdog = { "Следить за таймером автосохранения", "Watch the autosave timer" },
    coop_autosave = { "Автосохранение каждые 10 минут", "Autosave every 10 minutes" },
    perf_bench_no_bp_hooks = { "Замер: без перехватов Blueprint", "Bench: no Blueprint hooks" },
    debug = { "Подробный лог", "Detailed log" },
    net_send_budget = { "Сообщения мода без лавины", "No message floods" },
    log_batch_always = { "Лог пачками (меньше подвисаний)", "Log in batches (fewer stalls)" },
    debug_net = { "Писать в лог все сетевые сообщения", "Log every network message" },
    debug_probes = { "Тяжёлые датчики движения", "Heavy movement probes" },
}

-- Number settings shown in «Все функции мода» right under the switch they
-- belong to (sdc_ui: a label and a box; kept with the footer's Save).
M.NUMS_OF = {
    ai_player_scaling = { "ai_player_scaling_pct", "ai_player_scaling_cap_pct" },
    ai_host_cap = { "ai_host_cap_zombies", "ai_host_cap_per_player", "ai_host_cap_max" },
    ai_toughness = { "ai_toughness_health_pct", "ai_toughness_damage_pct", "ai_toughness_cap_pct" },
}

-- «Основное»: the settings players understand and change.
M.MAIN = {
    "listen_on_load", "auto_join", "no_pause", "sync_env", "quest_own", "coop_autosave",
    "player_names", "players_hud", "client_cheats", "gps_markers", "map_markers_shared", "explosion_shake_zone",
    "steam_link", "log_batch_always", "debug",
}

-- Groups of «Все функции мода», in order. A key goes to its GROUP_OF group,
-- else to the first matching prefix, else to "other".
M.GROUPS = { "connect", "players", "zombies", "npc", "combat", "world", "vehicles", "saves", "debug", "other" }

M.GROUP_OF = {
    listen_on_load = "connect", auto_join = "connect", auto_host = "connect", no_pause = "connect",
    sync_env = "connect", unload_menu_level = "connect", block_menu_level = "connect",
    lobby = "connect", menu_in_main_menu = "connect", ui_open_at_menu = "connect",
    join_cover = "connect",
    listen_ip_fallback = "connect", steam_server_api = "connect",
    steam_link = "connect", steam_link_friends_only = "connect",
    coop_slowtime_off = "connect",
    respawn_native = "players", guard_player_sweeps = "players", fresh_client_progress = "players",
    skilltree_sync = "players", bed_for_client = "players", client_sleep_skips_night = "players",
    coop_sleep_all = "players",
    char_create = "players", fix_capsule_replication = "players", client_movement_authority = "players",
    player_names = "players", gps_markers = "players", gps_compass = "players", map_markers_shared = "players",
    map_shared = "players",
    relay_skill_xp = "players", redirect_player0 = "players", client_quiet_others = "players",
    game_ui_input = "players", notes_relay = "players", notes_owner_only = "players", player_event_notes = "players", turret_sync = "world",
    players_hud = "players", client_cheats = "connect",
    medical_host_cure = "players", radiation_exit_sync = "players", geiger_own_only = "players",
    client_infection_hud = "players",
    stealth_sync = "players", explosion_shake_zone = "players", whistle_sync = "players",
    ai_kill_log = "debug", quest_trace = "debug", stealth_trace = "debug", gap_trace = "debug",
    melee_client_hits = "combat", reload_loop_fix = "combat", fix_client_damage = "combat",
    weapon_pose_fix = "combat", client_weapon_stats = "combat", host_weapon_fx_quiet = "combat",
    hide_zero_damage_numbers = "combat", client_hitmarker = "combat", shot_noise = "combat",
    throw_sync = "combat", throw_single_consume = "combat", launcher_sync = "combat",
    shot_sounds = "combat", mirror_sounds = "combat", sound_range_guard = "combat", replicate_items = "combat",
    prevent_client_loot = "combat", craft_one_at_a_time = "combat", item_gains_from_host = "combat",
    craft_needs_components = "combat", stations_on_host = "combat", loot_box_attachments = "combat",
    client_tools = "combat", client_gear_hud = "combat", client_durability_from_host = "combat", host_adds_to_inventory = "combat",
    container_moves_reliable = "combat", deathbox_remove_empty = "combat", refused_items_to_feet = "combat",
    inventory_walk_events = "combat",
    friendly_fire = "combat",
    perf_bench_no_bp_hooks = "debug",
    client_save_guard = "saves", autosave_watchdog = "saves", coop_autosave = "saves",
    persist_follow_host_save = "saves",
    infestation_xp_shared = "world",
    ai_keep_chase = "zombies", ai_spawn_check_all = "zombies", ai_player_scaling = "zombies",
    ai_client_optimizer_guard = "zombies", world_infest_wave_target = "world",
}

M.PREFIX_GROUP = {
    { "ai_", "zombies" }, { "npc_", "npc" }, { "quest_", "npc" }, { "trade_", "npc" },
    { "world_", "world" }, { "vehicle_", "vehicles" }, { "persist_", "saves" }, { "save", "saves" },
    { "net_", "debug" }, { "debug", "debug" }, { "log", "debug" }, { "ui_", "connect" },
    { "steam", "connect" }, { "listen", "connect" }, { "throw_", "combat" }, { "craft_", "combat" },
    { "weapon", "combat" }, { "melee", "combat" }, { "player", "players" }, { "respawn", "players" },
}

-- ---------------------------------------------------------------------------
-- Notifications from other modules: Russian -> English, and where they show
-- ---------------------------------------------------------------------------
-- Every notification has a class:
--   "game" - a gameplay event (seats, respawn, deaths, players joined / left,
--            quests, items, trading, map, skills, beds): the game's own
--            notification widget (sdc_lobby: GameFunctionLibrary_C.
--            CreateNotificationUI; the mod's toast where there is no HUD);
--   "mod"  - the mod itself (connection, versions, saves and their repair,
--            settings, Steam, the mod's warnings and errors): the mod's toast
--            in the panel's style; kind "err" adds "a mod error - report it".
-- A message not listed here: kind "err" -> "mod", anything else -> "game".

M.TOAST_EXACT = {}   -- [Russian] = English (whole toasts, and Russian arguments)
M.TOAST_CLASS = {}   -- [Russian] = "game" | "mod" (whole toasts only)
local function toast_text(class, ru, en)
    M.TOAST_EXACT[ru] = en
    if class ~= "arg" then M.TOAST_CLASS[ru] = class end
end

-- sdc_charcreate: the co-op character in the game's creator (main menu)
toast_text("mod", "Редактор персонажа не открылся — подключение с персонажем по умолчанию.",
    "The character editor didn't open: joining with the default character.")
toast_text("mod", "Не удалось открыть редактор персонажа.", "Couldn't open the character editor.")
toast_text("mod", "Подключение отменено.", "Joining cancelled.")
toast_text("mod", "Персонаж сохранён. Подключение...", "Character saved. Connecting...")
toast_text("mod", "Персонаж для кооператива сохранён.", "Co-op character saved.")
toast_text("mod", "Создайте персонажа для кооператива и нажмите «Continue» — затем начнётся подключение.",
    "Create your co-op character and press Continue: connecting starts after that.")
toast_text("mod", "Измените персонажа и нажмите «Continue».", "Change your character and press Continue.")
toast_text("mod", "Откройте главное меню (любая клавиша) — там откроется редактор персонажа.",
    "Open the main menu (press any key): the character editor opens there.")
toast_text("mod", "Персонаж по умолчанию: своего можно создать в главном меню (панель кооператива).",
    "Default character: you can make your own in the main menu (co-op panel).")
toast_text("mod", "Персонажа для кооператива можно изменить только в главном меню.",
    "The co-op character can only be changed in the main menu.")
-- sdc_dialogue: traders and NPC talks (its notices are always "warn")
toast_text("game", "Это копия торговца только на вашем компьютере — она убирается. Подойдите к торговцу хоста и нажмите F снова.",
    "This trader exists only on your computer and is being removed. Go to the host's trader and press F again.")
toast_text("game", "Окно диалогов ещё не готово — разговор с торговцем не начат. Попробуйте через несколько секунд.",
    "The dialogue window isn't ready yet, so the conversation didn't start. Try again in a few seconds.")
toast_text("game", "Хост не нашёл этого торговца рядом с вашим персонажем — разговор не начат. Подойдите ближе и нажмите F снова.",
    "The host found no such trader near your character, so the conversation didn't start. Come closer and press F again.")
toast_text("mod", "Хост не смог начать разговор с торговцем (подробности — в журнале хоста).",
    "The host couldn't start the conversation with the trader (details in the host's log).")
toast_text("mod", "Хост не видит вашего персонажа — разговор не начат.",
    "The host can't see your character, so the conversation didn't start.")
toast_text("game", "Окно диалогов ещё не готово — разговор не начат. Попробуйте через несколько секунд.",
    "The dialogue window isn't ready yet, so the conversation didn't start. Try again in a few seconds.")
toast_text("game", "У торговца не хватает денег, чтобы это купить.", "The trader doesn't have enough money to buy this.")
-- sdc_quests: what the game shows at the host's HUD
toast_text("game", "Задание отмечено на карте", "Quest marked on the map")
toast_text("game", "Все задания с ноутбуков уже взяты. Приходите позже — ноутбук возвращён.",
    "All laptop quests are already taken. Come back later; the laptop is back.")
-- sdc_savecheck, sdc_steam, sdc_session
toast_text("mod", "Совместная игра: автосохранение мира каждые 10 минут включено (настройка игры не изменена).",
    "Co-op: the world autosaves every 10 minutes (the game's setting is unchanged).")
toast_text("mod", "Мод обновил сетевые настройки игры. Перезапустите игру один раз, чтобы открыть мир для друзей или подключиться.",
    "The mod updated the game's network settings. Restart the game once to open your world to friends or to join.")
toast_text("mod", "127.0.0.1 — это ваш собственный компьютер. Впишите IP хоста или подключитесь к другу на вкладке Steam.",
    "127.0.0.1 is your own computer. Enter the host's IP, or join a friend on the Steam tab.")
toast_text("mod", "Мир не открылся для друзей. Открываю его ещё раз через обычные сетевые сокеты (порт 7777): друзья подключатся через Steam или по IP.",
    "The world didn't open for friends. Opening it again with plain network sockets (port 7777): friends join through Steam or by IP.")
-- arguments of catalog messages (sdc_players REFUSE_RU, sdc_vehicles buy.WHY)
toast_text("arg", "нет персонажа", "no character")
toast_text("arg", "персонаж мёртв", "the character is dead")
toast_text("arg", "персонаж в транспорте", "the character is in a vehicle")
toast_text("arg", "слишком часто", "too often")
toast_text("arg", "нет места", "no free spot")
toast_text("arg", "машина не найдена", "vehicle not found")
toast_text("arg", "нет точки выдачи машин", "no vehicle delivery point")
toast_text("arg", "цена неизвестна", "price unknown")
toast_text("arg", "инвентарь не найден", "inventory not found")
toast_text("arg", "деньги не списались", "the money wasn't taken")

-- Strings with names / numbers: { Lua pattern, English with %1.., class }.
-- Captures that are Russian themselves go through TOAST_EXACT.
-- sdc_bench / sdc_perf: the single-player benchmark (sdcoop_bench)
toast_text("mod", "Режим замера: перехваты Blueprint мода выключены (perf_bench_no_bp_hooks). Кооператив в этом режиме не работает - после замера выключите настройку.",
    "Bench mode: the mod's Blueprint hooks are off (perf_bench_no_bp_hooks). Co-op does not work in this mode: turn the setting off after measuring.")
toast_text("arg", " (игрок сдвинулся - замер не сравнивать)", " (the player moved: do not compare this run)")

M.TOAST_PATTERNS = {
    { "^Замер окончен: FPS ([%d%.]+), кадр p50 ([%d%.]+) / p95 ([%d%.]+) / p99 ([%d%.]+) мс(.-)%. Строка %[BENCH%] в UE4SS%.log%.$",
      "Benchmark done: FPS %1, frame p50 %2 / p95 %3 / p99 %4 ms%5. The [BENCH] line is in UE4SS.log.", "mod" },
    { "^Замер затрат: перехват ([%d%.%-]+) мкс, наш Lua ([%d%.%-]+) мкс, вызов Blueprint ([%d%.%-]+) мкс%. Строка %[BENCH%] floor в UE4SS%.log%.$",
      "Cost measured: hook %1 us, our Lua %2 us, Blueprint call %3 us. The [BENCH] floor line is in UE4SS.log.", "mod" },
    { "^Рядом найден другой UE4SS%-мод %((.-)%)%. Он может сломать SDCoop: см%. README_SDCoop%.txt%.$",
      "Another UE4SS mod was found next to SDCoop (%1). It can break SDCoop: see README_SDCoop.txt.", "mod" },
    { "^Сохранения: «Продолжить» снова указывает на ваше сохранение (.-) %(имя прошлого слота было испорчено модом, сохранения с ним нет%)%.$",
      "Saves: Continue points to your save %1 again (the previous slot name was broken by the mod; there is no save with it).", "mod" },
    { "^Сохранения: «Продолжить» снова указывает на ваше сохранение (.-) %(игра была закрыта во время подключения к другу%)%.$",
      "Saves: Continue points to your save %1 again (the game was closed while connected to a friend).", "mod" },
    { "^Мир сохранён в новый слот (.-) %(текущим был временный слот клиента%)%.$",
      "The world was saved into a new slot %1 (the current one was the client's temporary slot).", "mod" },
    { "^Задания группы: (%d+)$", "Group quests: %1", "game" },
    { "^Новое задание: (.+)$", "New quest: %1", "game" },
    { "^Выполнено: (.+)$", "Done: %1", "game" },
    { "^Задание завершено: (.+)$", "Quest finished: %1", "game" },
    { "^Задание выполнено: (.+) %(%+(%d+) опыта%)$", "Quest completed: %1 (+%2 XP)", "game" },
}

-- Catalog messages (log.say keys, sdc_log.TEXT and the modules' additions).
M.SAY_CLASS = {
    -- players, respawn, beds, unstuck, characters coming back, vehicles
    player_connecting = "game", player_joined = "game", player_left = "game",
    respawning = "game", respawn_wait_host = "game",
    respawn_no_point_host = "game", respawn_no_point_client = "game",
    bed_slept = "game", bed_sleep_off = "game", bed_early = "game", bed_spawn_set = "game",
    sleep_wait = "game", sleep_other = "game", sleep_all = "game", sleep_late = "game",
    unstuck_not_client = "game", unstuck_dead = "game", unstuck_vehicle = "game", unstuck_wait = "game",
    unstuck_asked = "game", unstuck_done = "game", unstuck_done_start = "game", unstuck_failed = "game",
    unstuck_refused = "game",
    -- the host's pull (sdc_players): the host's notices, the pulled player's
    pull_asked = "game", pull_done_host = "game", pull_failed_host = "game", pull_unconfirmed = "game",
    pull_dead = "game", pull_vehicle = "game", pull_ladder = "game", pull_sitting = "game", pull_joining = "game",
    pull_waiting = "game", pull_no_char = "game", pull_gone = "game", pull_gone_anon = "game", pull_wait = "game",
    pull_host_dead = "game",
    pull_host_nochar = "game", pull_host_vehicle = "game", pull_host_air = "game",
    pull_done_client = "game", pull_failed_client = "game",
    persist_restored_client = "game", persist_inv_client = "game", persist_fresh_client = "game",
    persist_restored_host = "game", persist_map_client = "game",
    veh_full = "game", veh_rejected = "game", veh_passenger = "game", veh_driver_now = "game",
    veh_seat = "game", veh_seat_driver = "game", veh_full_n = "game",
    veh_wheel_free = "game", veh_wheel_free_nokey = "game", veh_switch_none = "game", veh_switch_failed = "game",
    veh_switch_old_host = "game", veh_wheel_taken = "game", veh_seat_free = "game",
    veh_buy_money = "game", veh_buy_failed = "game", veh_radio_missing = "game", veh_radio_empty = "game",
    -- the horde beacon (sdc_horde): the host's wave notices, a death the horde goes on after, its end
    horde_wave = "game", horde_done = "game", horde_final = "game", horde_kept = "game", horde_over = "game",
    horde_over_all = "game",
    -- the mod: opening / joining / leaving, versions, settings, its failures
    menu_listen = "mod", already_host = "mod", is_client = "mod", single_world = "mod",
    reopen_saving = "mod", reopen_loading = "mod", reopen_done = "mod", reopen_save_failed = "mod",
    reopen_continue_hand = "mod", reopen_busy = "mod", reopen_need_alive = "mod",
    admin_kicked_you = "mod", admin_banned_you = "mod", admin_kick_done = "game", admin_ban_done = "game",
    admin_banned_join = "game", admin_player_kicked = "game", admin_cheats_off = "mod", admin_unbanned = "mod",
    -- who may join (sdc_admin): the host's notices and the joining player's
    admin_unbanned_one = "game", access_ask = "game", access_allowed = "game", access_allowed_once = "game",
    access_denied = "game",
    access_timeout = "game", access_not_listed = "game", access_full = "game", access_listed = "game",
    access_unlisted = "game", access_invited = "game", world_saved = "game", world_save_failed = "game",
    access_wait_you = "game", access_ok_you = "game", access_list_you = "game", access_denied_you = "game",
    access_timeout_you = "game", access_full_you = "game",
    -- the join password (join_access password): the host's notices and the joining player's
    access_pw_wrong = "game", access_pw_none = "game", access_pw_locked = "game", access_pw_unset = "game",
    access_pw_ok = "game", access_pw_set = "game", access_pw_cleared = "game", access_pw_wrong_nc = "game",
    access_pw_need_you = "game", access_pw_wrong_you = "game", access_pw_locked_you = "game",
    access_pw_unset_you = "game",
    -- friendly fire (sdc_ffire): the host's switch, the players' notices
    ff_on_host = "game", ff_off_host = "game", ff_join_on = "game", ff_turned_on = "game", ff_turned_off = "game",
    server_needs_solo = "mod", server_starting = "mod", already_client = "mod", host_cannot_join = "mod",
    need_ip = "mod", connecting = "mod", disconnecting = "mod", host_quit_hint = "mod", no_connection = "mod",
    no_local_pawn = "mod", listen_failed = "mod", server_started = "mod", connected = "mod",
    connected_to = "mod", disconnected = "mod", connection_lost = "mod", server_closed = "mod",
    host_no_answer = "mod", host_no_answer_steam = "mod",
    peer_version = "mod", host_version = "mod", settings_saved = "mod", settings_failed = "mod",
    settings_num_bad = "mod",
    persist_inv_failed = "mod",
    -- the panel's own (sdc_ui)
    steam_invite = "mod", steam_join = "mod", bug_open = "mod", players_hud = "mod",
    -- Steam link (sdc_steamlink): progress / status = gameplay, failures and helper problems = mod
    sl_joining = "game", sl_wait_host = "game", sl_hosting = "game", sl_invite_menu = "game",
    sl_invite_host = "game", sl_st_off = "game", sl_st_starting = "game", sl_st_relay = "game",
    sl_st_ready = "game", sl_st_hosting = "game", sl_st_waiting = "game", sl_st_connected = "game",
    sl_join_failed = "mod", sl_rejected = "mod", sl_tunnel_lost = "mod", sl_no_helper = "mod",
    sl_self = "mod", sl_bad_id = "mod", sl_overlay = "mod", sl_st_no_steam = "mod", sl_st_no_dll = "mod",
    sl_st_crashed = "mod", sl_st_restart = "mod",
    -- the host's Steam does not answer while a join retries (its game closed / crashed?)
    sl_host_silent = "game", sl_host_silent_left = "game", sl_st_silent = "game", sl_st_silent_left = "game",
}

-- The topic of a notification: "game" (play) | "mod" (the mod's own:
-- connection, versions, saves, settings), or nil when not listed.
function M.topic(text, key)
    local c = key and M.SAY_CLASS[key] or nil
    if not c and type(text) == "string" then
        c = M.TOAST_CLASS[text]
        if not c then
            for _, p in ipairs(M.TOAST_PATTERNS) do
                if p[3] and text:match(p[1]) then c = p[3] break end
            end
        end
    end
    return c
end

-- Where a notification goes: "game" | "mod". The rule (2026-11-13, the
-- user): in a world as much as possible the game's own way - its
-- notification widget under its HUD; sdc_lobby falls back to the mod's
-- toast where the game shows none (main menu, loading, pause menu) and
-- while the co-op panel covers the game's notifications. Only the mod's own
-- failures (kind "err") keep the mod's toast: it points to "Report a bug".
-- (Join messages go to the join cover before this: sdc_log.join_sink.)
function M.classify(text, kind, key)
    if kind == "err" then return "mod" end
    return "game"
end

-- Catalog messages (log.say / log.tr) whose screen text differs from the
-- catalog's: [lang][key] = format. English otherwise = the catalog's
-- English (log) text.
M.SAY = {
    en = {
        unstuck_not_client = "Moving to the host works only for a connected player.",
        unstuck_dead = "Your character is dead: use the respawn buttons.",
        unstuck_vehicle = "Leave the vehicle first.",
        unstuck_wait = "Moving will be available again in %d s.",
        unstuck_asked = "Moving your character to the host...",
        unstuck_done = "Your character was moved to the host.",
        unstuck_done_start = "Your character was moved to a start point.",
        unstuck_failed = "No free spot found: try again or ask the host to step aside.",
        unstuck_refused = "The host didn't move your character: %s.",
        listen_failed = "Couldn't open the world for friends. Details in UE4SS.log; try “New map without a save”.",
        btn_respawn_host = "Respawn: near the host",
        btn_respawn_random = "Respawn: random",
        btn_respawn_point = "Respawn: spawn point",
        sl_st_ready = "Steam is ready: join a friend or invite one.",
        sl_st_hosting = "Open to your Steam friends. Connected: %d",
        sl_st_connected = "Connected to %s through Steam, ping %s ms",
        sl_f_hosting = "hosting",
        sl_f_other_ver = "other mod version: %s",
        sl_f_ingame = "in the game",
    },
    ru = {
        sl_st_ready = "Steam готов: подключитесь к другу или пригласите его.",
        sl_st_hosting = "Мир открыт для друзей в Steam. Подключено: %d",
        sl_st_connected = "Подключено к %s через Steam, пинг %s мс",
        sl_f_hosting = "открыл мир",
        sl_f_other_ver = "другая версия мода: %s",
        sl_f_ingame = "в игре",
        -- the panel's button is «Новая карта без сохранения» now
        listen_failed = "Не удалось открыть мир для друзей. Подробности в UE4SS.log; попробуйте «Новая карта без сохранения».",
    },
}

-- ---------------------------------------------------------------------------
-- Language
-- ---------------------------------------------------------------------------

local function fmt(s, ...)
    if select("#", ...) == 0 then return s end
    local ok, r = pcall(string.format, s, ...)
    if ok then return r end
    return s
end

-- The config value: "auto" | "ru" | "en".
function M.setting()
    local ok, v = pcall(cfg.get, "language")
    v = ok and tostring(v or "auto"):lower() or "auto"
    if v ~= "ru" and v ~= "en" then v = "auto" end
    return v
end

-- "ru" | "en"
function M.language()
    local v = M.setting()
    if v == "auto" then return M.auto_lang or "ru" end
    return v
end

local function lang_of(culture)
    if type(culture) ~= "string" or culture == "" then return nil end
    return culture:lower():sub(1, 2) == "ru" and "ru" or "en"
end

-- Game thread only (engine calls). Returns true once the culture is known.
function M.detect()
    if M.auto_lang then return true end
    if M.detect_tries >= 20 then return true end
    M.detect_tries = M.detect_tries + 1
    local okue, ue = pcall(require, "sdc_ue")
    if not okue then return false end
    local lib = ue.find_object("/Script/Engine.Default__KismetInternationalizationLibrary")
    local culture = lib and ue.fstring(ue.try(function() return lib:GetCurrentCulture() end)) or ""
    local ksl = ue.ksl()
    local os_lang = ksl and ue.fstring(ue.try(function() return ksl:GetDefaultLanguage() end)) or ""
    if culture == "" and os_lang == "" then
        if M.detect_tries >= 20 then
            M.auto_lang = "ru"
            log.warn("i18n: culture unknown after %d tries; auto language = ru", M.detect_tries)
        end
        return M.auto_lang ~= nil
    end
    M.culture, M.os_language = culture, os_lang
    -- the game has only English text: its culture is "en" whenever the
    -- player's own language has no translation, so a Russian Windows decides
    local lang = lang_of(culture)
    if lang ~= "ru" and lang_of(os_lang) == "ru" then lang = "ru" end
    M.auto_lang = lang or "en"
    log.info("i18n: game culture '%s', Windows language '%s' -> auto language %s (setting %s)",
        log.ascii(culture), log.ascii(os_lang), M.auto_lang, M.setting())
    M.notify()
    return true
end

-- Tells the listeners (the panel) that the language may have changed.
M.shown = nil
function M.notify()
    local lang = M.language()
    if lang == M.shown then return end
    M.shown = lang
    for name, fn in pairs(M.listeners) do
        local ok, err = pcall(fn, lang)
        if not ok then log.err("i18n: listener %s: %s", tostring(name), tostring(err)) end
    end
end

-- Config `language` = v ("auto" | "ru" | "en"), in memory (the panel saves).
function M.set(v)
    v = tostring(v or "auto"):lower()
    if v ~= "ru" and v ~= "en" then v = "auto" end
    pcall(cfg.set, "language", v)
    M.notify()
    return v
end

function M.T(key, ...)
    local lang = M.language()
    local s = (M.STR[lang] and M.STR[lang][key]) or M.STR.ru[key] or M.STR.en[key] or tostring(key)
    return fmt(s, ...)
end

-- The «Кооператив» button in the game's menus (sdc_lobby; game thread).
-- With language = auto it follows the GAME's language (its culture: the
-- game ships English only, so "Co-op"), like the menu items around it; an
-- explicit ru / en still wins. The panel keeps M.language().
function M.menu_language()
    local v = M.setting()
    if v ~= "auto" then return v end
    pcall(M.detect)
    return lang_of(M.culture) or M.language()
end

function M.coop_label()
    local lang = M.menu_language()
    return (M.STR[lang] and M.STR[lang].coop_button) or M.T("coop_button")
end

-- ---------------------------------------------------------------------------
-- Config settings
-- ---------------------------------------------------------------------------

-- sdc_config's SCHEMA ({ key, type, default, Russian description } rows).
function M.schema()
    return type(cfg.SCHEMA) == "table" and cfg.SCHEMA or {}
end

function M.schema_row(key)
    for _, row in ipairs(M.schema()) do
        if row[1] == key then return row end
    end
    return nil
end

-- Full description in the current language.
function M.desc(key)
    if M.language() == "en" and M.DESC_EN[key] then return M.DESC_EN[key] end
    local row = M.schema_row(key)
    if row and type(row[4]) == "string" then return row[4] end
    return M.DESC_EN[key] or tostring(key)
end

local CYR_UPPER = {}
do
    local lower = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
    local upper = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
    local lo, up = {}, {}
    for _, c in utf8.codes(lower) do lo[#lo + 1] = utf8.char(c) end
    for _, c in utf8.codes(upper) do up[#up + 1] = utf8.char(c) end
    for i = 1, #lo do CYR_UPPER[lo[i]] = up[i] end
end

local function capitalize(s)
    local first = s:match("^[\0-\127\194-\244][\128-\191]*")
    if not first then return s end
    local up = CYR_UPPER[first] or first:upper()
    return up .. s:sub(#first + 1)
end

-- A label cut from a description: the first clause, without a role prefix
-- ("Хост:", "Client:"...) and parentheses, at most ~56 characters.
function M.short(desc)
    local s = tostring(desc or "")
    local colon = s:find(": ", 1, true)
    if colon then
        local head = s:sub(1, colon - 1)
        if (utf8.len(head) or #head) <= 22 and not head:find("[%(%)%.]") then s = s:sub(colon + 2) end
    end
    s = s:gsub("%s*%b()", "")
    local cut = #s
    for _, sep in ipairs({ ". ", " — ", "; ", ": ", " – " }) do
        local i = s:find(sep, 1, true)
        if i and i - 1 < cut then cut = i - 1 end
    end
    s = s:sub(1, cut):gsub("%s+$", ""):gsub("[%.;,]$", "")
    if (utf8.len(s) or #s) > 56 then
        local out, n = {}, 0
        for word in s:gmatch("%S+") do
            n = n + (utf8.len(word) or #word) + 1
            if n > 54 then break end
            out[#out + 1] = word
        end
        s = table.concat(out, " ") .. "…"
    end
    return capitalize(s)
end

function M.label(key)
    local l = M.LABEL[key]
    local lang = M.language()
    if l then return lang == "en" and l[2] or l[1] end
    if lang == "en" and not M.DESC_EN[key] then
        local h = tostring(key):gsub("_", " ")
        return capitalize(h)
    end
    return M.short(M.desc(key))
end

function M.group_of(key)
    local g = M.GROUP_OF[key]
    if g then return g end
    for _, p in ipairs(M.PREFIX_GROUP) do
        if key:sub(1, #p[1]) == p[1] then return p[2] end
    end
    return "other"
end

-- { { id = "connect", keys = { ... } }, ... } for every bool setting, in
-- SCHEMA order; empty groups are left out.
function M.groups()
    local by = {}
    for _, row in ipairs(M.schema()) do
        if row[2] == "bool" and type(row[1]) == "string" then
            local g = M.group_of(row[1])
            by[g] = by[g] or {}
            table.insert(by[g], row[1])
        end
    end
    local out = {}
    for _, id in ipairs(M.GROUPS) do
        if by[id] and #by[id] > 0 then out[#out + 1] = { id = id, keys = by[id] } end
    end
    return out
end

function M.group_name(id)
    return M.T("g_" .. tostring(id))
end

-- ---------------------------------------------------------------------------
-- Toast path (installed into sdc_log below)
-- ---------------------------------------------------------------------------

local function has_cyrillic(s)
    return type(s) == "string" and s:find("[\208\209]") ~= nil
end

local function arg_en(v)
    if type(v) ~= "string" then return v end
    return M.TOAST_EXACT[v] or v
end

M.misses = {}   -- untranslated toasts seen (text -> count), for the log

-- Russian notification text -> the text for the screen.
function M.screen_text(text)
    if M.language() ~= "en" or not has_cyrillic(text) then return text end
    local exact = M.TOAST_EXACT[text]
    if exact then return exact end
    for _, p in ipairs(M.TOAST_PATTERNS) do
        local caps = { text:match(p[1]) }
        if caps[1] ~= nil then
            local out = p[2]:gsub("%%(%d)", function(d)
                local c = caps[tonumber(d)]
                return c ~= nil and tostring(arg_en(c)) or ""
            end)
            return out
        end
    end
    if not M.misses[text] then
        M.misses[text] = 1
        log.debug("i18n: no English for a notification: %s", text)
    end
    return text
end

-- log.say / log.tr: the catalog entry { English, Russian } of `key` for the
-- screen in the current language; nil = sdc_log's default (Russian).
function M.screen_say(key, entry, ...)
    local lang = M.language()
    local over = M.SAY[lang] and M.SAY[lang][key]
    if lang == "en" then
        local n = select("#", ...)
        local args = { ... }
        for i = 1, n do args[i] = arg_en(args[i]) end
        local tpl = over or (type(entry) == "table" and entry[1]) or nil
        if not tpl then return nil end
        return fmt(tpl, table.unpack(args, 1, n))
    end
    if over then return fmt(over, ...) end
    return nil
end

log.screen_text = M.screen_text
log.screen_say = M.screen_say
log.classify = M.classify

-- sdc_deathbox: the death boxes saved with the world (config deathbox_persist)
M.DESC_EN.deathbox_persist = "Dead players' loot boxes are saved with the host's world: after loading a save or restarting the game they are back in place with the same items (the game itself does not save them); boxes that were not in the loaded save are removed. With persist_follow_host_save off, a load neither puts boxes back nor removes them (otherwise a friend who took the items after the save would get them twice)"
M.LABEL.deathbox_persist = { "Ящики погибших сохраняются", "Death boxes are saved" }
M.GROUP_OF.deathbox_persist = "saves"

-- 0.7.3 wave, group "session" (sdc_session / sdc_players / sdc_playermarks / sdc_sync)
-- the player list's new states (sdc_session.roster)
M.STR.ru.pl_state_menu = "в меню"
M.STR.ru.pl_state_lag = "не отвечает"
M.STR.en.pl_state_menu = "in the menu"
M.STR.en.pl_state_lag = "not responding"
-- settings
M.DESC_EN.sync_weather_overrides = "Client: the host's weather comes every 5 s and is written into the weather channels by hand (the client's weather is exactly the host's, but changes in steps). Off = a test of the game's own random weather: smooth changes, and once a minute a \"native weather check\" line in UE4SS.log compares the host's weather with yours; turn it back on if the weather differs from the host's"
M.DESC_EN.teleport_to_players = "Host: players can move to any teammate (console sdcoop_goto <name or row number in the list>): to the host at once, to another player only after that player agrees (sdcoop_goto_yes). Not more often than every 10 s. The host can always move to a player with the same command"
M.DESC_EN.host_difficulty_sync = "Host: the difficulty settings the game works out on each player's own machine are the host's on the clients - the XP multiplier, search time, weapon and suppressor wear, jams, headshot-only mode, backpack in backpack, selling to traders, the map without a GPS. A client gets its own values back when it leaves (and at the next start if the game closed while connected). Off = only the map without a GPS, as before"
M.LABEL.sync_weather_overrides = { "Погода хоста по каналам (шагами)", "Host weather by channels (in steps)" }
M.LABEL.teleport_to_players = { "Перенос к любому напарнику", "Move to any teammate" }
M.LABEL.host_difficulty_sync = { "Сложность хоста у клиентов", "The host's difficulty on clients" }
M.GROUP_OF.sync_weather_overrides = "connect"
M.GROUP_OF.teleport_to_players = "players"
M.GROUP_OF.host_difficulty_sync = "players"
-- notifications: the game's own notification widget (sdc_log TEXT entries are
-- added by sdc_session: peer_paks / host_paks, and sdc_players: goto_*)
for _, k in ipairs({ "peer_paks", "host_paks", "goto_off", "goto_gone", "goto_self", "goto_nopawn", "goto_dead",
                     "goto_vehicle", "goto_soon", "goto_target_nochar", "goto_target_dead", "goto_target_vehicle",
                     "goto_target_air", "goto_pending", "goto_asked", "goto_denied", "goto_noanswer", "goto_nospot",
                     "goto_done", "goto_failed", "goto_arrived", "goto_ask", "goto_allowed_you",
                     "goto_ladder", "goto_sitting", "goto_noreply" }) do
    M.SAY_CLASS[k] = "game"
end

-- sdc_chat: the text chat (0.7.3): its line, feed notes and settings
M.STR.ru.chat_hint = "Enter — отправить, Esc — закрыть"   -- one line of the input line (414 px): the longer one took two
M.STR.en.chat_hint = "Enter to send, Esc to close"
M.STR.ru.chat_slow = "не так быстро"
M.STR.en.chat_slow = "not so fast"
M.STR.ru.chat_undelivered = "не доставлено"
M.STR.en.chat_undelivered = "not delivered"
M.STR.ru.chat_old_host = "Чата нет: у хоста старая версия мода."
M.STR.en.chat_old_host = "No chat: the host has an older version of the mod."
M.DESC_EN.chat = "Text chat in co-op: Enter opens a line at the bottom left, Enter sends, Esc closes. Off = you do not see messages and cannot write; the host still passes the others' messages on"
M.DESC_EN.chat_sound = "A quiet click when another player's message comes (at most every 3 seconds)"
M.DESC_EN.chat_key = "The key that opens the chat, as an Unreal key name: Enter, Slash... (not the names menu_key uses; not vehicle_seat_key, G). Sending is always Enter, closing Esc"
M.LABEL.chat = { "Чат (Enter)", "Chat (Enter)" }
M.LABEL.chat_sound = { "Звук сообщений чата", "Chat message sound" }
M.GROUP_OF.chat = "players"
M.GROUP_OF.chat_sound = "players"
-- «Основное»: right after the players table
do
    local at = #M.MAIN + 1
    for i, k in ipairs(M.MAIN) do if k == "players_hud" then at = i + 1 end end
    table.insert(M.MAIN, at, "chat")
end

-- sdc_down: knockdown and revive by a teammate (host rule down_enabled)
M.DESC_EN.down_enabled = "Host: knockdown and revive by a teammate. A deadly hit does not kill at once when someone in the world can help (a player with this version of the mod): the player sits on the ground for down_bleedout_s seconds, a teammate gets them up by looking at them and holding the interact key (F) for 5 seconds; health after that: as before the hit, at least 10 and at most 25. Zombies leave a downed player alone and players can't hurt them; hold F for 3 seconds to give up. Hunger, thirst, radiation, drowning and infection kill as usual. Never in single player; clients don't need to set it: the host decides"
M.DESC_EN.down_bleedout_s = "Host: how many seconds a downed player lies before dying (knockdown: down_enabled; 15 to 300)"
M.LABEL.down_enabled = { "Нокдаун и подъём напарником", "Knockdown and revive by a teammate" }
M.LABEL.down_bleedout_s = { "Секунд до смерти лёжа", "Seconds before a downed player dies" }
M.GROUP_OF.down_enabled = "combat"
M.GROUP_OF.down_bleedout_s = "combat"
M.NUMS_OF.down_enabled = { "down_bleedout_s" }
M.STR.ru.wa_down_cap = "Вкл.: смертельный удар сажает игрока на землю, если рядом есть кому помочь; напарник поднимает его, держа F 5 с. Голод, жажда, радиация, утопление и инфекция убивают как обычно."
M.STR.en.wa_down_cap = "On: a deadly hit puts a player on the ground when someone can help; a teammate gets them up by holding F for 5 s. Hunger, thirst, radiation, drowning and infection kill as usual."
M.STR.ru.pl_state_down = "ранен"
M.STR.en.pl_state_down = "down"
M.STR.ru.down_bar_bleed = "Истекаете кровью"
M.STR.en.down_bar_bleed = "Bleeding out"
M.STR.ru.down_bar_reviving = "Поднимаю: %s"
M.STR.en.down_bar_reviving = "Reviving %s"
M.STR.ru.down_bar_being = "Вас поднимают"
M.STR.en.down_bar_being = "You're being revived"
M.STR.ru.down_bar_giveup = "Сдаться"
M.STR.en.down_bar_giveup = "Giving up"
M.STR.ru.down_mate = "напарника"
M.STR.en.down_mate = "a teammate"
for _, k in ipairs({ "down_you", "down_left", "down_up_by", "down_up", "down_up_off", "down_hint", "down_on_host",
                     "down_off_host", "down_join_on", "down_turned_on", "down_turned_off", "down_save_refused",
                     "pull_down", "pull_host_down", "goto_target_down", "goto_down", "unstuck_down" }) do
    M.SAY_CLASS[k] = "game"
end
M.SAY_CLASS.down_fuse = "mod"

-- sdc_reloadcap: a loop reload stops at the gun's capacity (reload_cap_fix)
M.DESC_EN.reload_cap_fix = "A one-round-at-a-time reload stops at the gun's capacity (on a client a network delay used to fill a sawn-off with dozens of shells). Client: every round put in counts on its screen at once, without waiting for the host, so the game itself stops the reload when the gun is full, at any ping. Host: never keeps more rounds in a gun than it holds - the extra round goes back onto the player's ammo stack (or at their feet when there is none); a gun already loaded past its capacity is set right at its next reload"
M.LABEL.reload_cap_fix = { "Перезарядка не больше ёмкости", "Reloads stay within capacity" }
M.GROUP_OF.reload_cap_fix = "combat"
M.STR.ru.rlcap_back = "Оружие было заряжено сверх нормы (%d патр. при ёмкости %d): лишние (%d) возвращены в инвентарь."
M.STR.en.rlcap_back = "The gun was loaded past its capacity (%d rounds, holds %d): the extra ones (%d) went back to your inventory."
M.STR.ru.rlcap_drop = "Оружие было заряжено сверх нормы (%d патр. при ёмкости %d): лишние возвращены в инвентарь (%d) и выпали под ноги (%d)."
M.STR.en.rlcap_drop = "The gun was loaded past its capacity (%d rounds, holds %d): the extra ones went back to your inventory (%d) and to the ground at your feet (%d)."
M.STR.ru.rlcap_floor = "Оружие было заряжено сверх нормы (%d патр. при ёмкости %d): лишние (%d) выпали под ноги."
M.STR.en.rlcap_floor = "The gun was loaded past its capacity (%d rounds, holds %d): the extra ones (%d) are on the ground at your feet."

-- sdc_shower: the decontamination shower the same for every player
M.DESC_EN.world_build_shower = "The decontamination shower is the same for everyone: one cooldown per shower (5 minutes, kept by the host; a player who joins later gets the time left), its water and lights (green - ready, orange - cooling down, red - no power) are seen by everyone, whoever turned it on; its power is the host's (together with world_build_power). The host removes the radiation - once for every player standing in the shower. A client that presses the shower sees \"No power\" / the cooldown note at once, from the host's state, without waiting for the host's answer"
M.LABEL.world_build_shower = { "Душ обеззараживания у всех одинаковый", "Decontamination shower matches for everyone" }

return M
