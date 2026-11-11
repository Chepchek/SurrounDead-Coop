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
    tab_ip = "По IP",
    tab_char = "Персонаж",
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
    st_single_hint = "Чтобы открыть его, сохранитесь и выйдите в главное меню.",
    st_loading = "Загрузка…",
    -- play
    sec_join = "Подключиться к другу",
    f_ip = "IP хоста",
    f_ip_hint = "например 127.0.0.1",
    f_port = "Порт",
    btn_join = "Подключиться",
    btn_disconnect = "Отключиться",
    btn_host = "Открыть мир для друзей",
    host_caption = "Меню перезагрузится, затем загрузите сохранение.",
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
    -- Steam (sdc_steamlink)
    steam_later = "Подключение через Steam появится в версии 0.7.0. Пока играйте по IP.",
    steam_off = "Подключение через Steam выключено (настройка steam_link).",
    steam_no_steam = "Steam недоступен.",
    steam_starting = "Запускаю Steam-соединение…",
    steam_ready = "Steam готов: подключитесь к другу или пригласите его.",
    steam_hosting = "Друзья могут подключиться к вам через Steam.",
    steam_joining = "Подключаюсь через Steam…",
    steam_connected = "Подключено через Steam.",
    steam_error = "Ошибка Steam-соединения: %s",
    steam_error_plain = "Ошибка Steam-соединения.",
    steam_restart = "Перезапустите игру один раз: мод изменил её сетевые настройки.",
    steam_friends_only = "Подключиться могут только ваши друзья в Steam.",
    btn_steam_invite = "Пригласить друга",
    btn_steam_join = "Подключиться",
    steam_friends = "Друзья в SurrounDead",
    steam_no_friends = "Сейчас никто из друзей не играет в SurrounDead.",
    steam_friend_hosting = "открыл мир",
    steam_friend_playing = "играет",
    steam_more = "…и ещё %d",
    steam_join_failed = "Не удалось подключиться через Steam: %s",
    steam_invite_failed = "Не удалось открыть приглашение Steam: %s",
    help_steam = "Как это работает: хост нажимает «Открыть мир для друзей» вверху панели, друг находит его в списке «Друзья в SurrounDead» и нажимает «Подключиться». Без IP и VPN.",
    -- character
    sec_name = "Имя",
    f_name = "Ваше имя",
    f_name_hint = "как вас увидят другие",
    sec_looks = "Внешность",
    btn_looks = "Изменить внешность",
    looks_caption = "Персонаж для кооператива создаётся в редакторе игры.",
    looks_menu_only = "Внешность меняется в главном меню.",
    sec_rescue = "Если что-то пошло не так",
    btn_respawn = "Возродиться рядом с хостом",
    unstuck_caption = "Застряли или провалились?",
    btn_unstuck_host = "Перенести к хосту",
    btn_unstuck_start = "Перенести на точку старта",
    char_ingame_only = "Перенос и возрождение появляются здесь, когда вы играете в мире друга.",
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
    all_caption = "Наведите курсор на пункт, чтобы прочитать подробности. Числа и тексты (порт, задержки, сеть) меняются в config.ini.",
    group_count = "%s (%d)",
    settings_note = "Изменения применяются после «Сохранить», часть — после перезапуска игры.",
    -- footer
    btn_save = "Сохранить",
    btn_close = "Закрыть",
    hint_key = "%s — открыть или закрыть панель",
    -- notifications from the panel
    -- connection chip (in game, top right)
    chip_client = "Хост %s, пинг %d мс",
    chip_client_noping = "Хост %s",
    chip_client_via = "Хост %s · %s · пинг %d мс",
    chip_client_via_noping = "Хост %s · %s",
    chip_host = "Игроки: %s",
    chip_player = "%s (%s)",
    chip_ms = "%d мс",
    chip_via_steam = "Steam",
    chip_via_ip = "IP",
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
    pe_died_zombie = "%s погиб — убит зомби.",
    pe_died_wolf = "%s погиб — его загрыз волк.",
    pe_died_bear = "%s погиб — его задрал медведь.",
    pe_died_animal = "%s погиб — убит животным.",
    pe_died_human = "%s погиб — убит людьми.",
    pe_died_fall = "%s погиб — разбился при падении.",
    pe_died_player = "%s погиб — его убил %s.",
    pe_died_you = "%s погиб — его убили вы.",
    pe_back = "%s возродился.",
}

M.STR.en = {
    title = "Co-op",
    coop_button = "Co-op",
    version = "v%s",
    tab_steam = "Steam",
    tab_ip = "By IP",
    tab_char = "Character",
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
    st_single_hint = "To open it, save and quit to the main menu.",
    st_loading = "Loading…",
    sec_join = "Join a friend",
    f_ip = "Host IP",
    f_ip_hint = "for example 127.0.0.1",
    f_port = "Port",
    btn_join = "Join",
    btn_disconnect = "Disconnect",
    btn_host = "Open my world to friends",
    host_caption = "The menu reloads, then load your save.",
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
    steam_later = "Joining through Steam comes in version 0.7.0. Until then, play by IP.",
    steam_off = "Joining through Steam is off (setting steam_link).",
    steam_no_steam = "Steam isn't available.",
    steam_starting = "Starting the Steam link…",
    steam_ready = "Steam is ready: join a friend or invite one.",
    steam_hosting = "Friends can join you through Steam.",
    steam_joining = "Joining through Steam…",
    steam_connected = "Connected through Steam.",
    steam_error = "Steam link error: %s",
    steam_error_plain = "Steam link error.",
    steam_restart = "Restart the game once: the mod changed its network settings.",
    steam_friends_only = "Only your Steam friends can join.",
    btn_steam_invite = "Invite a friend",
    btn_steam_join = "Join",
    steam_friends = "Friends in SurrounDead",
    steam_no_friends = "None of your friends is playing SurrounDead right now.",
    steam_friend_hosting = "hosting",
    steam_friend_playing = "playing",
    steam_more = "…and %d more",
    steam_join_failed = "Couldn't join through Steam: %s",
    steam_invite_failed = "Couldn't open the Steam invite: %s",
    help_steam = "How it works: the host presses “Open my world to friends” at the top of the panel, the friend finds them under “Friends in SurrounDead” and presses “Join”. No IP, no VPN.",
    sec_name = "Name",
    f_name = "Your name",
    f_name_hint = "how others see you",
    sec_looks = "Appearance",
    btn_looks = "Change appearance",
    looks_caption = "Your co-op character is made in the game's editor.",
    looks_menu_only = "Appearance can be changed in the main menu.",
    sec_rescue = "If something went wrong",
    btn_respawn = "Respawn near the host",
    unstuck_caption = "Stuck or fell through the world?",
    btn_unstuck_host = "Move to the host",
    btn_unstuck_start = "Move to a start point",
    char_ingame_only = "Moving and respawning show up here while you play in a friend's world.",
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
    all_caption = "Hover an item for details. Numbers and text values (port, delays, network) are set in config.ini.",
    group_count = "%s (%d)",
    settings_note = "Changes apply after Save; some need a game restart.",
    btn_save = "Save",
    btn_close = "Close",
    hint_key = "%s opens or closes this panel",
    chip_client = "Host %s, ping %d ms",
    chip_client_noping = "Host %s",
    chip_client_via = "Host %s · %s · ping %d ms",
    chip_client_via_noping = "Host %s · %s",
    chip_host = "Players: %s",
    chip_player = "%s (%s)",
    chip_ms = "%d ms",
    chip_via_steam = "Steam",
    chip_via_ip = "IP",
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
    pe_died_zombie = "%s was killed by a zombie.",
    pe_died_wolf = "%s was killed by a wolf.",
    pe_died_bear = "%s was killed by a bear.",
    pe_died_animal = "%s was killed by an animal.",
    pe_died_human = "%s was killed by humans.",
    pe_died_fall = "%s died from a fall.",
    pe_died_player = "%s was killed by %s.",
    pe_died_you = "You killed %s.",
    pe_back = "%s respawned.",
}

-- ---------------------------------------------------------------------------
-- Config settings: English descriptions (Russian ones are in SCHEMA)
-- ---------------------------------------------------------------------------

M.DESC_EN = {
    host_ip = "Friend's code (Steam) or the host's IP to connect to",
    port = "Host port (UDP). The host always listens on 7777",
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
    ai_kill_log = "Log every zombie kill to UE4SS.log: type, look (model, material), crawler or not, killer, damage, place; once a minute, kill counts by type",
    ai_client_ghosts = "Client: the game's own AI spawners don't create zombies, bosses or animals, and ones that exist only on the client (standing still or floating) are removed; all AI comes from the host",
    ai_zombie_fx = "The client sees and hears special zombie effects: the grenadier zombie's beeping and explosion, the acid zombie bursting after death",
    npc_offscreen = "Host: zombie bosses hit and throw rocks, and people (bandits, soldiers, raiders) move and fight near the client even when the host isn't looking at them (otherwise a boss did no damage to the client and froze after a throw)",
    npc_boss_fx = "The client sees the rock a boss throws and hears the boss roar (attack, throw, death)",
    npc_effects = "The client sees fire on burning bosses and people and blood when they are hit",
    npc_health = "The client's health bar for bandits, soldiers, raiders and traders uses the maximum health from the host",
    npc_looks = "People look the same for the client as for the host (clothes, hair, beard, backpack, helmet, mask)",
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
    stealth_trace = "Host: log which sense (sight or hearing) and from how far a zombie noticed a player",
    shot_noise = "Zombies hear a client's shots: the host reports the noise of each client shot to the AI just as the game does for the shooter (weapon sound radius, suppressor and muzzle brake as the client's own game computed them); zombies used to not hear client shots",
    weapon_pose_fix = "Host: other players' weapon pose as in single player: the host fixes the combat state (weapon in hands, aiming) the client sends before a slot change, and passes the client's knife aiming and ADS to the others",
    client_weapon_stats = "Host: take the client's weapon stats from its report instead of the item record on the host (fallback)",
    host_weapon_fx_quiet = "Host: doesn't repeat the effects of a client's weapon (camera shake on shots and hits); the client does them itself",
    client_quiet_others = "Client: other characters don't affect you through \"player 0\" (camera shake from others' aiming and knife, others' illnesses, others' XP)",
    game_ui_input = "Client: game windows (inventory, trade, containers) keep the cursor and mouse control: neither the mod nor late game events (the end of a trader dialogue) switch back to camera control while a window is open",
    notes_relay = "Host and client: game notifications about a client's action that the game runs on the host (gas mask filter, \"too early to sleep\", spawn point, trader's money, generator, water well, hangar keycard and so on) appear on that client's screen, with the game's own text and icon",
    notes_owner_only = "Host and client: a game notification about another player's action (a client filled bottles at a well, hit a nest, the mod applies the host's state) is taken off the screen of the player who didn't do it",
    turret_sync = "Camp turrets and player-built turrets: the host's turret shots, aim, switching off, damage and health are shown to clients; a client switching a turret off and its hits reach the host. The host decides",
    player_event_notes = "Game-style notices about other players: \"<name> died\" (with the cause only when the mod knows it for sure: zombie, wolf, bear, humans, a fall, another player) and \"<name> respawned\". Everyone sees them except that player; at most once in 30 s per player. The host decides; on a client, turning it off only hides them on that client's screen. Players joining and leaving are announced as before",
    redirect_player0 = "Host: the client's game logic (\"player 0\" in BP) works with the client's character, not the host's (fractures, hunger, notifications)",
    client_cvars = "Console variables the client runs on connecting, separated by ';'",
    move_response_interval = "Debug: minimum interval (s) between the server's replies to the client's movement; 0 = engine default",
    replicate_items = "Items (worn, dropped, loot) are the host's network objects; the client's local loot is removed",
    prevent_client_loot = "Client: random loot spawners on your copy of the level don't create their own loot; loot comes from the host (otherwise extra items appeared next to the host's); when off, the extra loot is removed after it appears, as before",
    craft_one_at_a_time = "Client: crafting one item at a time: the next request goes after the host answers, \"craft N\" is done one by one (otherwise the host took the components once and created all the items; the client's components got stuck)",
    medical_host_cure = "Host: another player's bandage, medkit or medicine also removes bleeding, fractures and infection on the host's copy of the character; other players' bleeding and fractures also heal on the host (otherwise bleeding kept taking health)",
    item_gains_from_host = "Items the game gives on use (rags from tearing clothes, an empty can or bottle, a filled bottle, box contents) are added by the host; the client's blinking local copy is removed (otherwise the item existed only on the client and blinked)",
    craft_needs_components = "A client's crafting must be paid for with items the host also has: otherwise the client doesn't send it and the host takes the created item away (a \"ghost item\" on the client used to allow endless crafting)",
    menu_key = "Menu key (a name from the UE4SS Key table)",
    lobby = "Co-op pages in the game's menus (main menu and pause)",
    menu_in_main_menu = "Show the co-op panel in the main menu",
    language = "Language of the panel and the mod's messages: auto (the game's language, or Windows' if the game has no Russian; the Co-op button in the game's menu follows the game's language), ru or en",
    ui_show_steam = "Not used since the Steam block (0.7.0): the panel shows Steam by itself when the Steam link is installed",
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
    listen_ip_fallback = "If the game's own Steam net driver didn't open the world for friends, open it with plain UDP sockets (port 7777): both Steam joins and IP joins use them",
    steam_p2p = "Experiment: the game's built-in Steam P2P (SteamSockets) instead of the steam_link helper; it doesn't work in this version of the game",
    host_by_ip = "Open the world with plain UDP sockets (port 7777) right away, without trying the game's own Steam net driver: both Steam joins and IP joins use them",
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
    world_prefabs = "Camps, trucks, stashes and random events are the same for everyone: the host creates them (the client's own random ones don't appear)",
    world_events_sync = "Random world events (a crashed helicopter, an abandoned truck) for the client as for the host: the crash sound (if the client is within its hearing range), the game's message, the map marker and the wreck with its fire and smoke at any distance; a player who joins later gets the markers; no false crash sound of the client's own",
    world_poi_clear = "Clearing major locations (the location's boss and its special container) counts for a client too: the special container a client searches first gives that client its XP (the game's own function, as in single player) and counts as searched in the host's world (saved); every player's map tooltip of the location shows how many of its bosses are dead and whether the special container was searched, as in the host's world, also after joining",
    infestation_xp_shared = "XP and the 'infestations destroyed' count for a destroyed infestation nest (primary or secondary) go to every player nearby, not only the finisher; each by their own level, with their own notification",
    infestation_xp_radius_m = "Radius (m) around an infestation nest within which players share the XP for destroying it",
    vehicle_sync = "Co-op vehicles: the host itself seats a player in a vehicle and drives it by their controls (getting in and out, headlights, horn, flipping, towing, refuelling, repair, buying from a trader)",
    vehicle_passengers = "A second player gets into an occupied vehicle as a passenger (the seat next to the driver); when the driver gets out, the passenger moves to the wheel",
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
    npc_offscreen = { "Боссы и люди действуют рядом с клиентом", "Bosses and people act near clients" },
    npc_boss_fx = { "Камни и рёв боссов у клиента", "Boss rocks and roars for clients" },
    npc_effects = { "Огонь и кровь на боссах и людях", "Fire and blood on bosses and people" },
    npc_health = { "Здоровье людей у клиента как у хоста", "People's health matches the host" },
    npc_looks = { "Люди выглядят у всех одинаково", "People look the same for everyone" },
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
    turret_sync = { "Синхронизация турелей", "Turret sync" },
    redirect_player0 = { "Логика игры клиента — для его персонажа", "Client game logic uses their character" },
    replicate_items = { "Предметы общие через хоста", "Items shared through the host" },
    prevent_client_loot = { "Без лишнего лута у клиента", "No extra loot on clients" },
    craft_one_at_a_time = { "Крафт клиента по одному предмету", "Clients craft one item at a time" },
    medical_host_cure = { "Лечение снимает раны и у хоста", "Healing also cures on the host" },
    item_gains_from_host = { "Предметы от использования выдаёт хост", "Items from use come from the host" },
    craft_needs_components = { "Крафт только из настоящих предметов", "Crafting needs real components" },
    lobby = { "Кнопка «Кооператив» в меню игры", "\"Co-op\" button in the game menus" },
    menu_in_main_menu = { "Панель кооператива в главном меню", "Co-op panel in the main menu" },
    ui_show_steam = { "Показывать Steam в панели", "Show Steam in the panel" },
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
    listen_ip_fallback = { "Запасной сетевой драйвер, если Steam-драйвер не сработал", "Fallback net driver if the Steam one fails" },
    steam_p2p = { "Эксперимент: встроенный Steam P2P игры", "Experiment: the game's own Steam P2P" },
    host_by_ip = { "Сразу обычный сетевой драйвер", "Plain net driver right away" },
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
    world_prefabs = { "Общие лагеря и события", "Shared camps and events" },
    world_events_sync = { "Случайные события: звук, сообщение, метка", "Random events: sound, message, marker" },
    world_poi_clear = { "Зачистка локаций (босс, особый ящик) у всех", "Location clears (boss, crate) for all" },
    infestation_xp_shared = { "Опыт за гнёзда всем рядом", "Nest XP for everyone near" },
    infestation_xp_radius_m = { "Радиус общего опыта за гнёзда, м", "Shared nest XP radius, m" },
    vehicle_sync = { "Машины в кооперативе", "Vehicles in co-op" },
    vehicle_passengers = { "Пассажиры в машинах", "Vehicle passengers" },
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

-- «Основное»: the settings players understand and change.
M.MAIN = {
    "listen_on_load", "auto_join", "no_pause", "sync_env", "quest_own", "coop_autosave",
    "player_names", "gps_markers", "map_markers_shared", "explosion_shake_zone",
    "steam_link", "log_batch_always", "debug",
}

-- Groups of «Все функции мода», in order. A key goes to its GROUP_OF group,
-- else to the first matching prefix, else to "other".
M.GROUPS = { "connect", "players", "zombies", "npc", "combat", "world", "vehicles", "saves", "debug", "other" }

M.GROUP_OF = {
    listen_on_load = "connect", auto_join = "connect", auto_host = "connect", no_pause = "connect",
    sync_env = "connect", unload_menu_level = "connect", block_menu_level = "connect",
    lobby = "connect", menu_in_main_menu = "connect", ui_show_steam = "connect", ui_open_at_menu = "connect",
    listen_ip_fallback = "connect", steam_p2p = "connect", host_by_ip = "connect", steam_server_api = "connect",
    steam_link = "connect", steam_link_friends_only = "connect", steam_link_allow = "connect",
    coop_slowtime_off = "connect",
    respawn_native = "players", guard_player_sweeps = "players", fresh_client_progress = "players",
    skilltree_sync = "players", bed_for_client = "players", client_sleep_skips_night = "players",
    coop_sleep_all = "players",
    char_create = "players", fix_capsule_replication = "players", client_movement_authority = "players",
    player_names = "players", gps_markers = "players", gps_compass = "players", map_markers_shared = "players",
    map_shared = "players",
    relay_skill_xp = "players", redirect_player0 = "players", client_quiet_others = "players",
    game_ui_input = "players", notes_relay = "players", notes_owner_only = "players", player_event_notes = "players", turret_sync = "world",
    medical_host_cure = "players", radiation_exit_sync = "players", geiger_own_only = "players",
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
    container_moves_reliable = "combat", deathbox_remove_empty = "combat",
    perf_bench_no_bp_hooks = "debug",
    client_save_guard = "saves", autosave_watchdog = "saves", coop_autosave = "saves",
    persist_follow_host_save = "saves",
    infestation_xp_shared = "world", infestation_xp_radius_m = "world",
}

-- Settings «Все функции мода» leaves out (no longer used by the mod).
M.HIDDEN = { ui_show_steam = true }

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
toast_text("mod", "Мод включил серверную часть Steam. Перезапустите игру через Steam один раз и снова откройте мир для друзей.",
    "The mod turned on Steam's server part. Restart the game through Steam once and open your world to friends again.")
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
    you_died = "game", respawning = "game", respawn_wait_host = "game",
    respawn_no_point_host = "game", respawn_no_point_client = "game",
    bed_slept = "game", bed_sleep_off = "game", bed_early = "game", bed_spawn_set = "game",
    sleep_wait = "game", sleep_other = "game", sleep_all = "game", sleep_late = "game",
    unstuck_not_client = "game", unstuck_dead = "game", unstuck_vehicle = "game", unstuck_wait = "game",
    unstuck_asked = "game", unstuck_done = "game", unstuck_done_start = "game", unstuck_failed = "game",
    unstuck_refused = "game",
    persist_restored_client = "game", persist_inv_client = "game", persist_fresh_client = "game",
    persist_restored_host = "game", persist_map_client = "game",
    veh_full = "game", veh_rejected = "game", veh_passenger = "game", veh_driver_now = "game",
    veh_buy_money = "game", veh_buy_failed = "game", veh_radio_missing = "game", veh_radio_empty = "game",
    -- the mod: opening / joining / leaving, versions, settings, its failures
    menu_listen = "mod", already_host = "mod", is_client = "mod", single_world = "mod",
    server_needs_solo = "mod", server_starting = "mod", already_client = "mod", host_cannot_join = "mod",
    need_ip = "mod", connecting = "mod", disconnecting = "mod", host_quit_hint = "mod", no_connection = "mod",
    no_local_pawn = "mod", listen_failed = "mod", server_started = "mod", connected = "mod",
    connected_to = "mod", disconnected = "mod", connection_lost = "mod", server_closed = "mod",
    peer_version = "mod", host_version = "mod", settings_saved = "mod", settings_failed = "mod",
    persist_inv_failed = "mod",
    -- the panel's own (sdc_ui)
    steam_invite = "mod", steam_join = "mod", bug_open = "mod",
    -- Steam link (sdc_steamlink): progress / status = gameplay, failures and helper problems = mod
    sl_joining = "game", sl_wait_host = "game", sl_hosting = "game", sl_invite_menu = "game",
    sl_invite_host = "game", sl_st_off = "game", sl_st_starting = "game", sl_st_relay = "game",
    sl_st_ready = "game", sl_st_hosting = "game", sl_st_waiting = "game", sl_st_connected = "game",
    sl_join_failed = "mod", sl_rejected = "mod", sl_tunnel_lost = "mod", sl_no_helper = "mod",
    sl_self = "mod", sl_bad_id = "mod", sl_overlay = "mod", sl_st_no_steam = "mod", sl_st_no_dll = "mod",
    sl_st_crashed = "mod", sl_st_restart = "mod",
}

-- "game" | "mod" for a notification (`text` as the module wrote it).
function M.classify(text, kind, key)
    local c = key and M.SAY_CLASS[key] or nil
    if not c and type(text) == "string" then
        c = M.TOAST_CLASS[text]
        if not c then
            for _, p in ipairs(M.TOAST_PATTERNS) do
                if p[3] and text:match(p[1]) then c = p[3] break end
            end
        end
    end
    if c == "game" or c == "mod" then return c end
    return kind == "err" and "mod" or "game"
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
        you_died = "You died. Press “Respawn near the host” in the co-op panel.",
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

-- sdc_config's SCHEMA ({ key, type, default, Russian description } rows):
-- cfg.SCHEMA when exported, else the local the config functions close over.
local schema_cache = nil
function M.schema()
    if schema_cache then return schema_cache end
    local s = rawget(cfg, "SCHEMA")
    if type(s) ~= "table" and type(debug) == "table" and type(debug.getupvalue) == "function" then
        for _, fn in ipairs({ cfg.save, cfg.load }) do
            if type(fn) == "function" then
                for i = 1, 64 do
                    local name, v = debug.getupvalue(fn, i)
                    if name == nil then break end
                    if name == "SCHEMA" and type(v) == "table" then s = v break end
                end
            end
            if type(s) == "table" then break end
        end
    end
    if type(s) ~= "table" then s = {} end
    schema_cache = s
    return s
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
        if row[2] == "bool" and type(row[1]) == "string" and not M.HIDDEN[row[1]] then
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

return M
