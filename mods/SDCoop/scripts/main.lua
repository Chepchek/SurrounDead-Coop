-- SDCoop: SurrounDead co-op mod (UE4SS Lua entry point).
--
-- Source of truth: Documents\SDCoop\mods\SDCoop. tools\deploy.ps1 copies the
-- scripts into every game instance; per-instance settings live in
-- Mods\SDCoop\config.ini (written on first start, edited from the F7 menu).
--
-- Modules (all flat, the UE4SS module searcher does not map dots to folders):
--   sdc_log      logging + notifications
--   sdc_ue       safe engine helpers, game-thread scheduling
--   sdc_config   config.ini
--   sdc_net      host <-> client message channel (ClientMessage / ServerExecRPC)
--   sdc_ctx      "player 0" by context on the host
--   sdc_players  characters: spawn, death, respawn, HUD, death screen
--   sdc_widgets  UI made of the game's own widgets
--   sdc_items    item actors: replication, worn items on clients, drops
--   sdc_appearance  owner-published looks (body, hair, clothes)
--   sdc_pawnstate   owner-published local state (weapon held, sprint, lean, flashlight, head, aim, left hand IK)
--   sdc_gearfx      other players' lights and lasers
--   sdc_combat      camera shake, forwarded weapon montages
--   sdc_sync     time/weather, AI, pause, sounds, movement (see docs\PLAN_v0.4.md)
--   sdc_session  host / join / roles / handshake
--   sdc_ui       F7 panel + toasts (until the lobby in the game's menus)
--   sdc_charcreate  a client's own character from the game's character creator
--   sdc_stealth  a client's footstep noise as its own game computes it; zombie perception trace
--   sdc_vehicles vehicles: host-run entry/exit, passengers, lights/horn/fuel/colour sync
--   sdc_shake    explosion camera shake for every player inside the explosion's zone
--   sdc_npc      zombie bosses / human NPCs: unseen attacks, rock, roars, fire, blood, health bar, looks
--   sdc_world    world objects: searched containers, doors, harvesting, trash / barrels / infestations, client builds, horde-boss binding
--   sdc_events   random world events (crashed helicopters, trucks): sound, notice, map marker, wreck for every player
--   sdc_shower   decontamination shower: the host's cooldown / power / water for every player, decontamination for everyone in it
--   sdc_zones    a zone's "Now Entering" banner and warning (the observatory's mines) for every player who enters, on its own screen
--   sdc_throw  thrown items: a client's throw runs on the host; every throw is seen by everyone
--   sdc_ffire    friendly fire on / off (host rule friendly_fire): damage between players dropped on the host
--   sdc_down     knockdown and revive by a teammate (host rule down_enabled; sdc_down_pose on every machine)
--   sdc_chat     text chat between the players (Enter opens a line bottom left; host relays, names are the host's)
--   sdc_persist other players' characters saved with the host's world (installed by sdc_progress via sdc_respawn)

local VERSION = "0.12.0"

local log = require("sdc_log")
local perf = require("sdc_perf")         -- [PERF] cost of every mod hook and task; wraps RegisterHook first
perf.wrap_register_hook()
local ue = require("sdc_ue")
perf.watch_out_arrays(ue)                -- [MEM]: estimate of the out-array buffers UE4SS keeps (before the AI modules load)
local cfg = require("sdc_config")
local net = require("sdc_net")
local sync = require("sdc_sync")
local session = require("sdc_session")
local playermarks = require("sdc_playermarks")   -- names over other players, GPS players on map / compass
playermarks.init(session.state)                    -- registers MYGPS / PINFO / PPOS handlers
session.world_reset_hooks.playermarks = function(why) playermarks.forget_world(why) end
local widgets = require("sdc_widgets")
local items = require("sdc_items")
local pawnstate = require("sdc_pawnstate")
local gearfx = require("sdc_gearfx")
local ui = require("sdc_ui")
local charcreate = require("sdc_charcreate")

session.VERSION = VERSION
ui.VERSION = VERSION

-- ---------------------------------------------------------------------------
-- Config location: <Mods>\SDCoop\config.ini (parent of the scripts folder)
-- ---------------------------------------------------------------------------

local function mod_dir()
    local ok, info = pcall(debug.getinfo, 1, "S")
    if ok and info and type(info.source) == "string" then
        local src = info.source:gsub("^@", "")
        local scripts = src:match("^(.*)[/\\][^/\\]+$")
        local dir = scripts and scripts:match("^(.*)[/\\][^/\\]+$")
        if dir then return dir end
    end
    return "ue4ss/Mods/SDCoop"
end

local MOD_DIR = mod_dir()
cfg.load(MOD_DIR .. "/config.ini")
-- Lua collector: incremental 150/200 by default ("generational" = experiment); see sdc_perf
pcall(perf.set_gc_mode, cfg.get("lua_gc"), cfg.get("lua_gc_pause"), cfg.get("lua_gc_stepmul"))
pcall(require("sdc_steam").ensure_server_api, cfg)   -- Engine.ini: bUseSteamNetworking=False (plain UDP sockets under Steam)
local steamlink = require("sdc_steamlink")   -- Steam join: SDCoopSteamLink.exe carries the game's UDP over Steam P2P
steamlink.install(session.state, MOD_DIR, VERSION)   -- IpNetDriver in memory + starts the helper once
charcreate.init(session, MOD_DIR)
log.info("v%s loading (config: %s)", VERSION, cfg.path)
ui.check_crash_marker(MOD_DIR)
-- Another mod that brings its own UE4SS (SurrounDeadMP / MPFix) next to ours:
-- its installer replaces dwmapi.dll and mods.txt, its uninstaller deletes Mods.
do
    local found = {}
    for _, f in ipairs({ "UE4SS.dll", "Mods/MPFix/Scripts/main.lua", "Mods/mods.txt" }) do
        local h = io.open(f, "r")
        if h then h:close(); found[#found + 1] = f end
    end
    if #found > 0 then
        log.warn("another UE4SS install next to SDCoop (%s): it can stop SDCoop from loading", table.concat(found, ", "))
        log.toast("Рядом найден другой UE4SS-мод (" .. table.concat(found, ", ") .. "). Он может сломать SDCoop: см. README_SDCoop.txt.",
            "warn", 10, "startup: foreign UE4SS files found")
    end
end
local lobby = require("sdc_lobby")   -- co-op pages inside the game's own menus
lobby.install(MOD_DIR)
ui.lobby_active = not lobby.disabled
ui.pause_menu_shown = lobby.pause_menu_shown

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

log.toast_sink = lobby.toast_sink(ui.toast)
net.install_hooks()
local dialogue = require("sdc_dialogue")   -- NPC dialogues for every player + client Narrative HUD
local quests = require("sdc_quests")       -- shared group quests (the host's log), mirror for clients
dialogue.install()   -- native hooks; retried from the ticks until in
quests.install()
session.install_level_hooks()
session.register_handlers()
local diag = require("sdc_diag")         -- debug: periodic [SNAP] state lines (config diag_snapshots)
diag.init(VERSION)
local respawn = require("sdc_respawn")   -- the game's respawn RPCs / beds for the right player
respawn.install(session.state)
local world = require("sdc_world")   -- world objects: containers, doors, harvesting, trash / barrels / infestations, client builds
world.install(session.state)         -- W* handlers, world-reset hook, player-0 scope (chained in front of sdc_respawn's)
local vehicles = require("sdc_vehicles")  -- vehicles: host-run entry/exit for clients, passengers, state sync, client ghosts
vehicles.install(session.state)           -- message handlers + world-reset hook; game hooks come from the tick
local shake = require("sdc_shake")        -- explosion shake only for players inside the explosion's zone
shake.install(session.state)
session.world_reset_hooks.shake = function(why) shake.reset(why) end
local throw = require("sdc_throw")        -- thrown items: a client's throw runs on the host, every throw is seen by everyone
throw.install(session.state)              -- THROW/THRACK/THROWN/THRFX handlers; hooks come from the tick
session.world_reset_hooks.throw = function(why) throw.reset(why) end
local geiger = require("sdc_geiger")      -- each player hears only their own dosimeter; a client's zone exit stops its radiation timer on the host
geiger.install(session.state)             -- RADZ handler; hooks come from the tick
session.world_reset_hooks.geiger = function(why) geiger.reset(why) end
local uiinput = require("sdc_uiinput")    -- a client's game windows (inventory / trade / loot) keep the game's UI input
uiinput.install(session.state)           -- ToggleInventory / SetInputMode_GameOnly / container-open hooks come from its own 1 s tick on a client
session.world_reset_hooks.uiinput = function(why) uiinput.reset(why) end
local rename = require("sdc_rename")      -- storage containers: a client's Rename opens the game's window, the host renames, everyone sees the name
rename.install(session.state)             -- RNOPEN/RNREQ/RNAME/RNAMEQ handlers; hooks come from the tick
session.world_reset_hooks.rename = function(why) rename.reset(why) end
local builduse = require("sdc_builduse")  -- buildables a client used last (doors, gates...): no left-over user on the host, the host can use them
builduse.install(session.state)           -- BREL handler; hooks come from the tick
session.world_reset_hooks.builduse = function(why) builduse.reset(why) end
local bdoors = require("sdc_bdoors")      -- placed doors / gates: opener's swing side, open/closed and garage power as on the host
bdoors.install(session.state)             -- WBDOOR/WBDOORQ handlers; hooks come from the tick
session.world_reset_hooks.bdoors = function(why) bdoors.reset(why) end
-- decontamination shower: the host's cooldown / power / water for every player, decontamination for everyone in it
require("sdc_shower").install(session.state)   -- SHWR/SHWRQ/SHWRR/SHWRV handlers; hooks come from the tick
session.world_reset_hooks.shower = function(why) require("sdc_shower").reset(why) end
local poiclear = require("sdc_poiclear")  -- major places (boss + special container): a client's clearing counts for it; every map shows the host's world
poiclear.install(session.state)           -- POIST/POICL/POIQ handlers; the client's OpenContainer hook comes from the tick
session.world_reset_hooks.poiclear = function(why) poiclear.reset(why) end
session.world_reset_hooks.combat =function(why) require("sdc_combat").reset(why) end
-- sdc_ownsounds (set up by sdc_session): its sound / attenuation caches go with the world
session.world_reset_hooks.ownsounds = function() require("sdc_ownsounds").reset() end
charcreate.register_handlers()
sync.register_handlers()
local stealth = require("sdc_stealth")
stealth.install(session.state)          -- STEALTH handler; hooks are registered from the tick
local npc = require("sdc_npc")   -- zombie bosses / human NPCs: unseen attacks, rock, roars, fire, blood, health bar, looks
npc.install(session.state)       -- NPCSET/NPCFIRE/NPCBLOOD/NPCROCK handlers; hooks come from the tick
session.world_reset_hooks.npc = function(why) npc.reset("world:" .. tostring(why)) end
local savecheck = require("sdc_savecheck")   -- host save: [SAVE] lines, skip-save guard, client slot safety, backups
savecheck.install(session.state)
local notes = require("sdc_notes")   -- every game notification on the screen of the player it is for (host relay, take-off)
notes.install(session.state)         -- NOTE handler, world-reset hook; Blueprint hooks retried from the tick
require("sdc_zones").install(session.state)   -- zone entry banner / warning for each player's own entry; world-reset hook; hooks from the tick
local events = require("sdc_events")   -- random world events (crashed helicopters, trucks): sound, notice, map marker, wreck for every player
events.install(session.state)          -- WEVT handler, world-reset hook; the Blueprint hook retried from the tick
local turrets = require("sdc_turrets")   -- turrets: host shots/aim/disable/health reach clients; a client's disable and hits reach the host
turrets.install(session.state)           -- TURFIRE/TURSTATE/TUROFF/TURHIT handlers; Blueprint hooks come from the tick
session.world_reset_hooks.turrets = function(why) turrets.reset(why) end
local admin = require("sdc_admin")       -- host: kick / ban players, the game's cheats off on clients (client_cheats)
admin.install(session.state)             -- KICK/RULES handlers, console cheat-command guards
session.world_reset_hooks.admin = function(why) admin.reset(why) end
local ffire = require("sdc_ffire")       -- friendly fire on / off: the host drops damage between players (friendly_fire)
ffire.install(session.state)             -- entries on sdc_ai's shared ApplyDamage / SetBurning hooks; installed from the tick
session.world_reset_hooks.ffire = function(why) ffire.reset(why) end
local down = require("sdc_down")         -- knockdown and revive (down_enabled): its ApplyDamage entries after sdc_ffire's
down.install(session.state)              -- DOWN/DOWNCAP/REVIVE/GIVEUP/DOWNQ handlers, hook entries; installed from the tick
session.world_reset_hooks.down = function(why) down.reset(why) end
local chat = require("sdc_chat")         -- text chat between the players of one co-op world (Enter; config chat)
chat.install(session.state)              -- CHATON/CHAT/CHATM handlers; the line and feed are built from its tick
session.world_reset_hooks.chat = function(why) chat.reset(why) end
session.install_item_watch()
session.install_death_watch()
sync.install_time_dilation_guard()

-- Level change: drop every cached object of the old world while it is still
-- alive; the load's garbage collection frees it right after (see
-- sdc_session.reset_world). Without this hook the 1 s session tick notices
-- the new controller and resets then.
do
    local ok, err = pcall(RegisterLoadMapPreHook, function()
        local okr, e = pcall(session.on_load_map)
        if not okr then log.err("world reset on LoadMap failed: %s", tostring(e)) end
        pcall(log.flush)   -- batched log lines (sdc_log) before the load
    end)
    if ok then
        log.info("load-map hook ok")
    else
        log.warn("load-map hook unavailable (%s); world changes are handled by the 1 s tick only", tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Loops (all on the game thread)
-- ---------------------------------------------------------------------------

-- Key presses from UE4SS key binds, acted on by the frame loop. UE4SS runs a
-- key bind on its own thread while the game thread runs native hooks that take
-- no lock. So a bind only flips a field that already exists: no allocation, no
-- call. An ExecuteInGameThread from a bind wrote the shared Lua registry beside
-- the hooks; that was the 0.7.1 host crashes.
local KEYS = { menu = false, players = false, chat_esc = false }

-- Debug sync-gap tracer (sdc_gaptrace): loaded and ticked only once config
-- gap_trace is on (at start, or set with sdcoop_set); it stops counting when
-- the key goes off again.
local gaptrace_on = false
local function start_gaptrace()
    if gaptrace_on or cfg.get("gap_trace") ~= true then return end
    gaptrace_on = true
    local gaptrace = require("sdc_gaptrace")
    gaptrace.init(session.state, MOD_DIR)
    ue.every("gaptrace", 1000, function() gaptrace.tick(os.clock()) end)
end

-- Debug [REPORT] lines (debug = true): their 2 s check starts only once
-- debug is on (assigned below, after the report functions).
local start_report = function() end
-- How fast the world runs here (sdc_speed: sdcoop_status, [PERF], gap trace)
local speed = require("sdc_speed")

-- Give the engine a few seconds to finish booting before touching the world.
ue.delay("boot", 4000, function()
    ue.every("steamlink", 500, steamlink.tick)   -- before the session tick: Steam tunnel / hosting / invites
    ue.every("session", 1000, session.tick)
    ue.every("savecheck", 1000, savecheck.tick)
    ue.every("notes", 1000, notes.tick)
    ue.every("zones", 1000, require("sdc_zones").tick)   -- hooks (HUD_Game.ZoneAreaUI, BP_EnterArea entry / exit)
    ue.every("events", 1000, events.tick)
    ue.every("turrets", 250, turrets.tick)
    ue.every("admin", 1000, admin.tick)
    ue.every("ffire", 1000, ffire.tick)   -- hooks while wanted; client: the friendly fire notices
    ue.every("down", 250, down.tick)      -- knockdown: host records / progress, client DOWNCAP / views, poses here
    ue.every("ui", 250, ui.slow_tick)
    ue.every("lobby", 250, lobby.slow_tick)
    start_gaptrace()
    ue.every("hotbar", 1000, items.hotbar_tick)   -- safety net; OnRep_ActiveWeapon repaints at once
    ue.every("pawnstate", 100, pawnstate.fast_tick)
    ue.every("charcreate", 1000, charcreate.tick)
    ue.every("playermarks", 1000, playermarks.tick)
    ue.every("playermarks-fast", 100, playermarks.fast_tick)
    ue.every("stealth", 100, stealth.tick)  -- 100 ms: client send; host/client work once a second
    ue.every("vehicles", 500, vehicles.tick)
    ue.every("shake", 50, shake.tick)
    ue.every("throw", 100, throw.tick)
    ue.every("geiger", 250, geiger.tick)
    ue.every("rename", 500, rename.tick)    -- hooks, client: names asked on join and put on copies that appear
    ue.every("builduse", 500, builduse.tick)  -- hooks (host: own looks; client: presses / look-aways)
    ue.every("bdoors", 500, bdoors.tick)      -- hooks; host: door snapshot every 20 s; client: 2 s door / generator pass
    ue.every("shower", 250, require("sdc_shower").tick)  -- hooks; host: shower snapshot every 30 s; client: water stop, 2 s pass
    ue.every("poiclear", 500, poiclear.tick)  -- host: major places' state to clients (2 s); client: hook, POIQ, 2 s map pass
    ue.every("chat", 250, chat.tick)          -- who may talk, the feed's widget; nothing in single player
    local perf_last = os.clock()
    ue.every("perf", 1000, function()
        pcall(speed.sample)
        -- debug switches set in the settings panel take effect here
        start_gaptrace()
        start_report()
        local every = tonumber(cfg.get("perf_report")) or 60
        if every <= 0 or os.clock() - perf_last < every then return end
        perf_last = os.clock()
        perf.report("window", ue.task_stats)
        -- a client's zombie steps of the same window: "[PERF] ai steps" (sdc_ai;
        -- a line of their own, so they do not crowd the 10 "parts")
        local ai = package.loaded["sdc_ai"]
        if type(ai) == "table" and type(ai.perf_report) == "function" then pcall(ai.perf_report) end
    end)
    ue.every("npc", 250, npc.tick)
    ue.every("world", 250, world.tick)
    ue.every("diag", 1000, function()
        local ok, err = pcall(diag.tick, session.state)
        if not ok then log.err_throttled("diag", "diag: %s", tostring(err)) end
    end)
    ue.every_frame("ui-frame", function()
        perf.frame()
        log.tick()   -- batched UE4SS.log writes (after a slow write) and their clock
        if KEYS.menu then
            KEYS.menu = false
            ue.sub_time("f:menukey", ui.on_menu_key)
        end
        if KEYS.players then
            KEYS.players = false
            ue.sub_time("f:hudkey", ui.on_players_key)
        end
        ue.sub_time("f:ui", ui.frame_tick)
        -- lobby before widgets: it releases its pages' clicks first
        ue.sub_time("f:lobby", lobby.frame_tick)
        ue.sub_time("f:widgets", widgets.frame_tick)
        ue.sub_time("f:pawnstate", pawnstate.frame_tick)
        -- only while a local player may sit in a vehicle (set by its 0.5 s tick)
        if vehicles.frame_wanted() then ue.sub_time("f:vehicles", vehicles.frame_tick) end
        -- knockdown: the decision the frame after a probe hit, own downed player / rescuer keys (a plain read when idle)
        if down.frame_wanted() then ue.sub_time("f:down", down.frame_tick) end
        -- chat: Esc first (it acts only while the chat line is open), then the
        -- line itself (Enter read from its text) or the key that opens it
        if KEYS.chat_esc then
            KEYS.chat_esc = false
            ue.sub_time("f:chatkey", chat.on_esc)
        end
        if chat.frame_wanted() then ue.sub_time("f:chat", chat.frame_tick) end
    end)
    log.info("v%s running", VERSION)
end)

-- ---------------------------------------------------------------------------
-- Menu hotkey
-- ---------------------------------------------------------------------------

local key_name = tostring(cfg.get("menu_key") or "F7"):upper()
if Key and Key[key_name] then
    local ok, err = pcall(RegisterKeyBind, Key[key_name], function() KEYS.menu = true end)
    log.info("menu key %s %s%s", key_name, ok and "registered" or "FAILED", ok and "" or (" " .. tostring(err)))
else
    log.warn("menu key '%s' is not a UE4SS Key name, menu only via console 'sdcoop_menu'", key_name)
end

-- Players table key (F8): shows / hides the table of players, top right.
local hud_key = tostring(cfg.get("players_hud_key") or "F8"):upper()
if hud_key == key_name then
    log.warn("players table key %s is the menu key too: not registered (set players_hud_key in config.ini)", hud_key)
elseif Key and Key[hud_key] then
    local ok, err = pcall(RegisterKeyBind, Key[hud_key], function() KEYS.players = true end)
    log.info("players table key %s %s%s", hud_key, ok and "registered" or "FAILED", ok and "" or (" " .. tostring(err)))
else
    log.warn("players table key '%s' is not a UE4SS Key name: the table is shown / hidden only in the panel settings",
        hud_key)
end

-- Esc while the chat line is open (sdc_chat): the game gets no keys then
-- (UI-only input) and the line cannot report Esc, so UE4SS's own key read is
-- the only way. The bind only flips the field; the frame loop acts, and only
-- while the line is open (Enter is read from the line's text on the game
-- thread: no bind).
if Key and Key.ESCAPE then
    local ok, err = pcall(RegisterKeyBind, Key.ESCAPE, function() KEYS.chat_esc = true end)
    log.info("chat close key ESCAPE %s%s", ok and "registered" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- ---------------------------------------------------------------------------
-- Console commands (UE console: ~ / F10)
-- ---------------------------------------------------------------------------

local function command(name, help, fn)
    local ok, err = pcall(RegisterConsoleCommandHandler, name, function(full, params, out)
        local function reply(s)
            if out and out.Log then pcall(function() out:Log("[SDCoop] " .. s .. "\n") end) end
            log.info("%s", s)
        end
        local okc, errc = pcall(fn, params or {}, reply, full or "")
        if not okc then reply("error: " .. tostring(errc)) end
        return true
    end)
    if not ok then log.err("console command %s: %s", name, tostring(err)) end
    return help
end

local HELP = {}
local function add(name, help, fn) HELP[#HELP + 1] = string.format("%-20s %s", name, command(name, help, fn)) end

local function arg(params, i)
    local v = params[i]
    if v == nil then return nil end
    return ue.str(v)
end

savecheck.register_commands(add)
world.register_commands(add)    -- sdcoop_events, sdcoop_airdrop
vehicles.register_commands(add) -- sdcoop_seat (vehicle seats: list / tune live / print the table rows)
down.register_commands(add)     -- sdcoop_down (knockdown checks, phase 0)
-- sdcoop_bench is registered by sdc_bench itself (sdc_perf installs it); listed here for the help only
HELP[#HELP + 1] = string.format("%-20s %s", "sdcoop_bench", "sdcoop_bench [seconds|floor|stop] - single player: [BENCH] fps / frame times, or per-call hook costs")

add("sdcoop_help", "list SDCoop commands", function(_, reply)
    for _, line in ipairs(HELP) do reply(line) end
end)

add("sdcoop_version", "print mod version", function(_, reply)
    reply("v" .. VERSION)
end)

add("sdcoop_menu", "show / hide the co-op menu", function()
    ui.toggle()
end)

add("sdcoop_status", "session status", function(_, reply)
    local s = session.status()
    reply(string.format("role=%s map=%s | %s", s.role, tostring(ue.map_name()), tostring(s.title)))
    for _, l in ipairs(s.lines) do reply("  " .. l) end
    pcall(function() reply(respawn.status_line()) end)
    pcall(function() reply(diag.status_line()) end)
    pcall(function() reply(stealth.status_line()) end)
    pcall(function() reply(vehicles.status_line()) end)
    pcall(function() reply(shake.status_line()) end)
    pcall(function() reply(throw.status_line()) end)
    pcall(function() reply(geiger.status_line()) end)
    pcall(function() reply(rename.status_line()) end)
    pcall(function() reply(builduse.status_line()) end)
    pcall(function() reply(bdoors.status_line()) end)
    pcall(function() reply(require("sdc_shower").status_line()) end)
    pcall(function() reply(require("sdc_zones").status_line()) end)
    pcall(function() reply(poiclear.status_line()) end)
    pcall(function() reply(require("sdc_combat").status_line()) end)
    pcall(function() reply(ffire.status_line()) end)
    pcall(function() reply(down.status_line()) end)
    pcall(function() reply(chat.status_line()) end)
    pcall(function() reply(perf.peek("status", ue.task_stats)) end)   -- read-only: the [PERF] window goes on
    pcall(function() reply(speed.status_line()) end)   -- game speed / timer drift here (sdc_speed)
    pcall(function() reply(npc.status_line()) end)
    pcall(function() reply(world.status_line()) end)
    pcall(function() reply(savecheck.status_line()) end)
    pcall(function() reply(steamlink.status_line()) end)
    pcall(function() reply(notes.status_line()) end)
    pcall(function() reply(events.status_line()) end)
    pcall(function() reply(require("sdc_bench").status_line()) end)
    pcall(function() for _, l in ipairs(require("sdc_ai").status_lines()) do reply(l) end end)
    reply(string.format("net sent=%d recv=%d | ai replicated=%d ghosts=%d spawners=%d | pawns hidden=%d | tod fixes=%d weather=%d",
        net.stats.sent, net.stats.received, sync.stats.ai_replicated, sync.stats.ai_ghosts_removed,
        sync.stats.managers_disabled, sync.stats.pawn_ghosts_hidden, sync.stats.tod_fixes, sync.stats.weather_fixes))
end)

add("sdcoop_join", "sdcoop_join [ip] [port] - connect to a host", function(params)
    local ip, port = arg(params, 1), arg(params, 2)
    if ip then
        local h, p = ip:match("^(.-):(%d+)$")
        if h then ip, port = h, p end
        cfg.set("host_ip", ip)
        if port then cfg.set("port", port) end
        cfg.save()
    end
    session.join(cfg.get("host_ip"), cfg.get("port"), false)
end)

add("sdcoop_steam", "Steam join: sdcoop_steam [friends | join <n|SteamID> | invite | cancel]", function(params, reply)
    steamlink.console({ arg(params, 1), arg(params, 2) }, reply)
end)

add("sdcoop_disconnect", "leave the server", function()
    session.disconnect()
end)

add("sdcoop_host", "open the next loaded world for friends", function()
    session.host_on_next_load()
end)

add("sdcoop_server", "sdcoop_server [map] - start a fresh listen server", function(params)
    session.start_fresh_server(arg(params, 1))
end)

add("sdcoop_spawn", "host: spawn pawns for players without one", function()
    session.force_spawn_all()
end)

add("sdcoop_unstuck", "client: sdcoop_unstuck [start] - move your character next to the host (or to a start point)", function(params)
    require("sdc_players").request_unstuck(arg(params, 1) == "start" and "start" or "host")
end)

add("sdcoop_pull", "host: sdcoop_pull <name | row number in the F7 list> - move a player next to you", function(params, reply)
    -- a name with spaces comes split into several params
    local words, i = {}, 1
    while params[i] ~= nil do
        words[#words + 1] = arg(params, i)
        i = i + 1
    end
    reply(require("sdc_players").pull_console(table.concat(words, " "), session.roster()))
end)

-- "go to a player" (sdc_players; clients need the host's teleport_to_players)
add("sdcoop_goto", "sdcoop_goto <name | row number in the F7 list> - move your character next to that player", function(params, reply)
    local words, i = {}, 1
    while params[i] ~= nil do
        words[#words + 1] = arg(params, i)
        i = i + 1
    end
    reply(require("sdc_players").goto_console(table.concat(words, " "), session.roster()))
end)
add("sdcoop_goto_yes", "client: let the player who asks come to you", function(_, reply)
    reply(require("sdc_players").goto_answer(true))
end)
add("sdcoop_goto_no", "client: do not let the player who asks come to you", function(_, reply)
    reply(require("sdc_players").goto_answer(false))
end)

add("sdcoop_reinit", "client: re-apply input / camera to the local player", function()
    session.reinit_local()
end)

add("sdcoop_character", "sdcoop_character [reset|show] - main menu: make / change the co-op character in the game's creator", function(params, reply)
    local a = arg(params, 1)
    if a == "reset" then
        reply(charcreate.reset_stored())
    elseif a == "show" then
        reply(charcreate.describe())
    else
        reply(charcreate.open_from_menu("console"))
    end
end)

add("sdcoop_marks", "player names / GPS markers state", function(_, reply) playermarks.report(reply) end)

add("sdcoop_persist", "host: sdcoop_persist [save|list] - other players' characters saved with this world", function(params, reply)
    local persist = require("sdc_persist")
    if arg(params, 1) == "save" then persist.save_now(reply) else persist.list(reply) end
end)

add("sdcoop_set", "sdcoop_set <key> <value> - change a config value", function(params, reply)
    local k, v = arg(params, 1), arg(params, 2)
    if not k or v == nil then reply("usage: sdcoop_set <key> <value>") return end
    cfg.set(k, v)
    cfg.save()
    reply(k .. " = " .. tostring(cfg.get(k)))
    if k == "gap_trace" then start_gaptrace() end
    if k == "debug" then start_report() end
end)

add("sdcoop_netcheck", "list net drivers / connections / controllers", function(_, reply)
    for _, cls in ipairs({ "NetDriver", "IpNetDriver", "SteamSocketsNetDriver", "NetConnection", "SteamSocketsNetConnection", "PendingNetGame", "PlayerController" }) do
        reply(string.format("%s count=%d", cls, ue.count(cls)))
    end
    reply("net role: " .. ue.net_role())
end)

local function players_report(reply)
    for _, pc in ipairs(ue.find_all("PlayerController")) do
        local pawn = ue.pawn_of(pc)
        reply(string.format("PC %s player=%s conn=%s pawn=%s role=%d", ue.short(pc),
            ue.class_name(ue.prop(pc, "Player")), ue.short(ue.prop(pc, "NetConnection")),
            ue.short(pawn), pawn and ue.role(pawn) or -1))
    end
    for _, p in ipairs(ue.find_all("BP_PlayerCharacter_C")) do
        local loc = ue.location(p)
        local okLC, isLC = pcall(function() return p:IsLocallyControlled() end)
        reply(string.format("Pawn %s role=%d local=%s hidden=%s ctrl=%s pos=%s", ue.short(p), ue.role(p),
            tostring(okLC and isLC), tostring(ue.prop(p, "bHidden")),
            ue.short(ue.prop(p, "Controller")),
            loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "?"))
    end
end

local function scan_report(reply)
    local by_role = {}
    local total, runtime, replicated = 0, 0, 0
    for _, a in ipairs(ue.find_all("BP_MasterAICharacter_C")) do
        total = total + 1
        local r = ue.role(a)
        by_role[r] = (by_role[r] or 0) + 1
        if ue.is_runtime_spawned(a) then runtime = runtime + 1 end
        if ue.prop(a, "bReplicates") == true then replicated = replicated + 1 end
    end
    local roles = {}
    for r, n in pairs(by_role) do roles[#roles + 1] = string.format("role%d=%d", r, n) end
    reply(string.format("AI total=%d runtime=%d replicates=%d %s", total, runtime, replicated, table.concat(roles, " ")))
    for _, cls in ipairs({ "BP_AIManager_C", "BP_AISpawnPoint_C", "Ultra_Dynamic_Sky_C", "Ultra_Dynamic_Weather_C" }) do
        local list = ue.find_all(cls)
        local first = list[1]
        reply(string.format("%s count=%d first role=%d replicates=%s", cls, #list,
            first and ue.role(first) or -1, tostring(first and ue.prop(first, "bReplicates"))))
    end
    sync.env_report_logged = false
    local snap = sync.env_snapshot()
    reply("env: " .. (snap and string.format("tod=%.1f weather=%s", snap.tod, snap.weather) or "n/a"))
end

-- Debug builds write both reports once per world, 15 s after it loaded. The
-- 2 s check runs only once debug is on: from 5 s after start, from
-- sdcoop_debug / sdcoop_set, or the 1 s perf task (the settings panel); it
-- stays (and idles) if debug goes off again.
local reported = {}
local report_on = false
local function report_tick()
    if not cfg.get("debug") then return end
    local s = session.state
    if (s.role ~= "host" and s.role ~= "client") or not s.map or ue.in_main_menu() then return end
    local key = s.role .. "|" .. s.map .. "|" .. tostring(s.map_since) .. "|" .. tostring(s.menu_since)
    if reported[key] or os.time() - math.max(s.map_since, s.menu_since) < 15 then return end
    reported[key] = true
    local function out(line) log.info("[REPORT] %s", line) end
    out("role=" .. s.role .. " map=" .. s.map)
    players_report(out)
    scan_report(out)
    for _, p in ipairs(ue.find_all("BP_PlayerCharacter_C")) do
        if ue.role(p) ~= ue.ROLE_AUTHORITY or s.role == "host" then sync.log_equipment("report", p) end
    end
end
start_report = function()
    if report_on or not cfg.get("debug") then return end
    report_on = true
    ue.every("report", 2000, report_tick)
end
ue.delay("report-boot", 5000, function() start_report() end)

-- Reverse-engineering helper: if Mods/SDCoop/dump_usmap.flag exists at start,
-- dump the type mappings (Mappings.usmap) once the game world with the player
-- is loaded, so blueprint classes are included. The flag is removed after the
-- dump. Checked once 6 s after start; only with the flag it checks again
-- every 5 s until the dump (no timer runs without it).
local function dump_check()
    local flag = MOD_DIR .. "/dump_usmap.flag"
    local f = io.open(flag, "r")
    if not f then return end
    f:close()
    if ue.in_main_menu() or not ue.has_player_character() then
        ue.delay("dump-check", 5000, dump_check)
        return
    end
    os.remove(flag)
    local ok, err = pcall(function() DumpUSMAP() end)
    log.info("DumpUSMAP ok=%s %s", tostring(ok), tostring(err or ""))
end
ue.delay("dump-boot", 6000, dump_check)

add("sdcoop_players", "list controllers, pawns and net roles", function(_, reply)
    players_report(reply)
end)

add("sdcoop_scan", "AI / sky / weather replication report", function(_, reply)
    scan_report(reply)
end)

add("sdcoop_debug", "toggle verbose logging", function(_, reply)
    cfg.set("debug", not cfg.get("debug"))
    cfg.save()
    reply("debug = " .. tostring(cfg.get("debug")))
    start_report()
end)

log.info("v%s loaded; menu: %s, console: sdcoop_help", VERSION, key_name)
