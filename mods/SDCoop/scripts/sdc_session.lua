-- SDCoop: session management (host / join / roles / handshake).
--
-- Host flow   : the game's own "load save" / "new game" level open gets
--               "?listen" appended (listen_on_load), so the loaded world is a
--               listen server on UDP 7777. Characters of remote players are
--               handled by sdc_players, "player 0" by sdc_ctx.
-- Client flow : "open <ip>:<port>"; the own character's setup is in
--               sdc_players.
-- Everything runs from the 1 s game-thread tick in main.lua.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local sync = require("sdc_sync")
local ctx = require("sdc_ctx")
local players = require("sdc_players")
local items = require("sdc_items")
local appearance = require("sdc_appearance")
local pawnstate = require("sdc_pawnstate")
local combat = require("sdc_combat")
local gearfx = require("sdc_gearfx")
local damage = require("sdc_damage")
local steam = require("sdc_steam")
local netdiag = require("sdc_netdiag")
local ai = require("sdc_ai")
local localinit = require("sdc_localinit")
local dmgnum = require("sdc_dmgnum")
local whistle = require("sdc_whistle")
local ownsounds = require("sdc_ownsounds")
local dialogue = require("sdc_dialogue")
local quests = require("sdc_quests")
local W = require("sdc_widgets")

local M = {
    VERSION = "?",
}

local HOST_PORT = 7777
local JOIN_RETRY_S = 45
local JOIN_MAX_AUTO_ATTEMPTS = 20

local st = {
    role = "unknown",
    map = nil,
    map_since = os.time(),
    pc_key = nil,
    in_menu = nil,
    menu_since = os.time(),
    menu_listen_attempted = false,
    remote = {},            -- [pc full name] = record
    remote_pcs = {},
    next_index = 0,
    spawned = {},           -- [pawn full name] = pc key
    last_env = 0,
    last_ai = 0,
    listen_requested_at = nil,
    listen_warned = false,
    auto_host_done = false,
    join = { target = nil, started_at = 0, attempts = 0 },
    disconnect_requested = false,
    client = nil,
}
M.state = st

local ai_inited = false
local function zombies_on()
    if not ai_inited then
        if not ai.any_enabled() then return false end
        ai_inited = true
        ai.init(st)
    end
    return true
end
M.ui_hooks = {}   -- set by sdc_ui (kept for the F7 panel)
M.world_reset_hooks = {}   -- [name] = fn(why, pc_key): modules that cache objects (sdc_ui)

local function new_client_state()
    return {
        connected_at = os.time(), hello_sent_at = nil, hello_attempts = 0, acked = false, pc_key = nil,
        host_name = nil, host_version = nil,
        pawn_key = nil, pawn_seen_at = 0, setup_stage = 0, had_pawn = false,
        last_cleanup = 0, ping = nil,
    }
end

-- ---------------------------------------------------------------------------
-- Listen-on-load: rewrite the game's own level opens
-- ---------------------------------------------------------------------------

local function looks_like_address(t)
    return t:match("^%d+%.%d+%.%d+%.%d+") ~= nil or t:match(":%d+$") ~= nil
        or t:match("^steam%.") ~= nil
end

-- Keeps only values that really are a level path, map name or address;
-- anything else (an unreadable soft pointer printed as "Foo: 0x...") -> "".
local function normalize_target(s)
    s = s or ""
    local path = s:match("(/Game/[%w_/%.]+)") or s:match("(/Script/[%w_/%.]+)")
    if path then return path end
    if s:match("^[%w_]+$") then return s end
    if looks_like_address(s) then return s end
    return ""
end

-- Should this machine keep its worlds open for friends?
local function hosting_enabled()
    return cfg.get("listen_on_load") == true and cfg.get("auto_join") ~= true
end

-- `target` may be "" when the level reference could not be read. Every level
-- this machine opens on its own (menu included: the save is loaded into the
-- menu world) stays a listen server; joining an address never does.
local function want_listen(target)
    if not hosting_enabled() then return false end
    if ue.exec_in_progress then return false end
    if ue.net_role() == "client" then return false end
    local t = (target or ""):lower()
    if t:find("listen", 1, true) then return false end
    if t ~= "" and looks_like_address(t) then return false end
    return true
end

local function mark_listen(where, before, after)
    st.listen_requested_at = os.time()
    st.listen_warned = false
    log.info("host: %s '%s' -> '%s'", where, before, after)
end

-- nil when the options already ask for a listen server.
local function append_listen(opts)
    opts = opts or ""
    if opts:lower():find("listen", 1, true) then return nil end
    if opts == "" then return "listen" end
    return opts .. "?listen"
end

function M.install_level_hooks()
    local function hook(path, fn)
        local ok, err = pcall(RegisterHook, path, fn)
        log.info("hook %s %s%s", path, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end

    -- UGameplayStatics::OpenLevel(WorldContext, FName LevelName, bAbsolute, FString Options)
    hook("/Script/Engine.GameplayStatics:OpenLevel", function(_, _, LevelName, _, Options)
        local raw = ue.str(LevelName and LevelName:get())
        local target = normalize_target(raw)
        log.info("level: OpenLevel '%s' (from %s)", raw, tostring(ue.map_name()))
        if not want_listen(target) then return end
        local before = ue.str(Options:get())
        local after = append_listen(before)
        if not after then return end
        if pcall(function() Options:set(after) end) then mark_listen("OpenLevel " .. target, before, after) end
    end)

    -- UGameplayStatics::OpenLevelBySoftObjectPtr(WorldContext, TSoftObjectPtr<UWorld>, bAbsolute, FString Options)
    -- The save-load flow of the game goes through this one.
    hook("/Script/Engine.GameplayStatics:OpenLevelBySoftObjectPtr", function(_, _, Level, _, Options)
        local raw = ""
        pcall(function() raw = ue.str(Level:get()) end)
        local target = normalize_target(raw)
        log.info("level: OpenLevelBySoftObjectPtr '%s' -> '%s' (from %s)", raw, target, tostring(ue.map_name()))
        if not want_listen(target) then return end
        local before = ue.str(Options:get())
        local after = append_listen(before)
        if not after then return end
        if pcall(function() Options:set(after) end) then mark_listen("OpenLevelBySoftObjectPtr", before, after) end
    end)

    -- Console "open <map>" / "travel <map>" issued by Blueprints.
    hook("/Script/Engine.KismetSystemLibrary:ExecuteConsoleCommand", function(_, _, Command)
        if ue.exec_in_progress then return end
        local cmd = ue.str(Command and Command:get())
        local verb, target = cmd:match("^%s*(%a+)%s+(%S+)")
        if not verb then return end
        verb = verb:lower()
        if verb ~= "open" and verb ~= "travel" then return end
        log.info("level: console '%s'", cmd)
        if cmd:lower():find("listen", 1, true) then return end
        if not want_listen(normalize_target(target)) then return end
        local after = cmd .. "?listen"
        if pcall(function() Command:set(after) end) then mark_listen("console", cmd, after) end
    end)
end

-- ---------------------------------------------------------------------------
-- Actions (menu buttons / console commands)
-- ---------------------------------------------------------------------------

-- The main menu and the game share one world, so the menu world itself is
-- reopened as a listen server; "Continue"/"Load" then restore the save into
-- a world that friends can already join.
function M.open_menu_as_server()
    local path = ue.world_path() or "/Game/Levels/PersistentLevel"
    st.menu_listen_attempted = true
    st.listen_requested_at = os.time()
    st.listen_warned = false
    st.netdiag_done = false
    if (cfg.get("host_by_ip") == true or steam.ip_mode) and not netdiag.ip_fallback then pcall(netdiag.switch_to_ip) end
    log.say("menu_listen", "info", 10)
    ue.exec("open " .. path .. "?listen")
end

function M.host_on_next_load()
    cfg.set("listen_on_load", true)
    if cfg.get("auto_join") then cfg.set("auto_join", false) end
    cfg.save()
    local role = ue.net_role()
    if role == "host" then
        log.say("already_host", "ok")
    elseif role == "client" then
        log.say("is_client", "warn")
    elseif ue.in_main_menu() then
        M.open_menu_as_server()
    else
        log.say("single_world", "warn", 12)
    end
end

function M.start_fresh_server(map)
    map = map or cfg.get("auto_host_map")
    if ue.net_role() ~= "standalone" then
        log.say("server_needs_solo", "warn")
        return
    end
    log.say("server_starting", "info", 6, map)
    st.listen_requested_at = os.time()
    st.listen_warned = false
    st.netdiag_done = false
    if (cfg.get("host_by_ip") == true or steam.ip_mode) and not netdiag.ip_fallback then pcall(netdiag.switch_to_ip) end
    ue.exec("open " .. map .. "?listen")
end

function M.join(ip, port, is_auto)
    ip = tostring(ip or cfg.get("host_ip")):gsub("^%s+", ""):gsub("%s+$", "")
    port = tonumber(port) or cfg.get("port") or HOST_PORT
    local role = ue.net_role()
    if role == "client" then
        log.say("already_client", "info")
        return
    end
    -- with listen_on_load the main menu itself is a listen server; joining
    -- from it is fine ("open ip" replaces that world)
    if role == "host" and not ue.in_main_menu() then
        log.say("host_cannot_join", "warn")
        return
    end
    if ip == "" then
        log.say("need_ip", "warn")
        return
    end
    -- 127.0.0.1 is this computer. Launched through Steam (a real game with a
    -- friend) it is always the field's old default, not the friend's code:
    -- joining it only reloads this game's own menu.
    local low = ip:lower()
    if not is_auto and (low == "127.0.0.1" or low == "localhost") and steam.own_id() then
        log.toast("127.0.0.1 — это ваш собственный компьютер. Впишите IP хоста или подключитесь к другу на вкладке Steam.",
            "warn", 10, "join: refused 127.0.0.1 while running through Steam")
        return
    end
    -- sdc_charcreate: without a co-op character the join waits for the
    -- game's character creator in this main menu, which then joins again
    if M.before_join then
        local okh, held = pcall(M.before_join, ip, port, is_auto)
        if not okh then log.err("join: co-op character check: %s", tostring(held)) end
        if okh and held then return end
    end
    if not is_auto then st.join.attempts = 0 end
    st.join.attempts = st.join.attempts + 1
    -- a friend's code (SteamID64, or "steam.<id>"): through Steam, no IP
    local sid = steam.code_of(ip)
    local sl = package.loaded["sdc_steamlink"]
    if sid and type(sl) == "table" and sl.usable and sl.usable() then
        -- sdc_steamlink: the helper builds a Steam tunnel to the friend; the
        -- game opens 127.0.0.1:<tunnel port> once it is up (M.join_tunnel)
        st.join.target = "steam:" .. sid
        st.join.started_at = os.time()
        st.disconnect_requested = false
        local okt, started, why = pcall(sl.request_tunnel, sid)
        log.info("join: friend %s through the Steam tunnel (started=%s%s)", sid, tostring(okt and started),
            (okt and why) and (", " .. tostring(why)) or (okt and "" or (", " .. tostring(started))))
        return
    end
    if sid then
        st.join.target = string.format("steam.%s:%d", sid, port)
        st.join.via = "steam"
    else
        st.join.target = string.format("%s:%d", ip, port)
        st.join.via = "ip"
        -- an IP (Radmin VPN, ZeroTier, port forwarding): launched through
        -- Steam the game's net driver is SteamSockets, which does not work
        -- here; the plain IP driver does, as for a game started outside Steam
        if (steam.ip_mode or steam.own_id()) and cfg.get("listen_ip_fallback") ~= false then
            local okf, changed = pcall(netdiag.switch_to_ip)
            log.info("join: by IP through the IP net driver (switched=%s)", tostring(okf and changed))
        end
    end
    st.join.started_at = os.time()
    st.disconnect_requested = false
    log.say("connecting", "info", 6, st.join.target)
    ue.exec("open " .. st.join.target)
end

-- sdc_steamlink: the Steam tunnel to a friend is up on 127.0.0.1:<port>
-- (M.join already passed the co-op character check). The game connects
-- there as to any IP host, through the plain IP net driver. `label`: the
-- friend's SteamID64, for the log. Returns false when this game cannot join.
function M.join_tunnel(port, label)
    port = tonumber(port)
    if not port or port <= 0 or port > 65535 then return false end
    local role = ue.net_role()
    if role == "client" then
        log.say("already_client", "info")
        return false
    end
    if role == "host" and not ue.in_main_menu() then
        log.say("host_cannot_join", "warn")
        return false
    end
    if not netdiag.ip_fallback then pcall(netdiag.switch_to_ip) end
    st.join.target = string.format("127.0.0.1:%d", port)
    st.join.via = "steam"   -- the connection chip: "Steam", not the tunnel's loopback IP
    st.join.started_at = os.time()
    st.disconnect_requested = false
    log.info("join: friend %s through the Steam tunnel at %s", tostring(label), st.join.target)
    ue.exec("open " .. st.join.target)
    return true
end

function M.disconnect()
    local role = ue.net_role()
    if role == "client" or ue.has_pending_connection() then
        st.disconnect_requested = true
        log.say("disconnecting", "info")
        ue.exec("disconnect")
    elseif role == "host" then
        log.say("host_quit_hint", "info", 8)
    else
        log.say("no_connection", "info")
    end
end

-- ---------------------------------------------------------------------------
-- Host side
-- ---------------------------------------------------------------------------

local function remote_record(pc)
    local key = ue.name(pc)
    local r = st.remote[key]
    if r then
        r.pc = pc
        return r
    end
    st.next_index = st.next_index + 1
    r = {
        key = key, pc = pc, index = st.next_index,
        name = "Player " .. st.next_index, version = nil, hello = false,
        joined_at = os.time(), pawnless_since = os.time(),
        spawned_once = false, spawn_pending = false, spawned_key = nil,
        pawn = nil, dead = false,
    }
    st.remote[key] = r
    log.info("host: player connected %s", key)
    log.say("player_connecting", "info")
    net.send_to(pc, "HELLO", M.VERSION, cfg.player_name())
    return r
end

local function send_env(pcs)
    if not cfg.get("sync_env") then return end
    local snap = sync.env_snapshot()
    if not snap then return end
    net.broadcast(pcs, "ENV", string.format("%.2f", snap.tod), snap.weather, snap.state or "")
end

local function on_player_left(r)
    log.info("host: player left %s (%s)", r.name, r.key)
    log.say("player_left", "info", 6, r.name)
    players.on_left(r)
    net.broadcast(st.remote_pcs, "MSG", "player_left", r.name)
end

-- ---------------------------------------------------------------------------
-- Player list for the co-op panel (sdc_ui)
-- ---------------------------------------------------------------------------
-- M.roster(): { { name, state, ping, me, host }, ... }, the host first.
--   state: "host" | "connecting" (no HI yet) | "loading" (no character yet)
--          | "dead" | "game"; ping in ms (the host's measure), me = this machine.
-- Host -> clients: ROSTER|<name>|<state>|<ping>|<me>|<name>|... (4 fields a
-- player, the host first; me = 1 on the receiving client's own entry), on a
-- change and every ROSTER_EVERY_S. A client keeps the last list.
local ROSTER_EVERY_S = 5

-- Host: how a remote player is connected, "steam" (through the Steam link
-- helper) or "ip"; nil while that is not known yet.
local function via_of(key)
    local sl = package.loaded["sdc_steamlink"]
    local ps = package.loaded["sdc_persist"]
    local okp, sid = pcall(function() return ps and ps.steam_of and ps.steam_of(key) or nil end)
    sid = okp and sid or nil
    local okn, peers = pcall(function() return sl and sl.peer_count and sl.peer_count() or 0 end)
    peers = okn and tonumber(peers) or 0
    if sid and sl and sl.peer_ping then
        local okg, ping = pcall(sl.peer_ping, sid)
        return (okg and ping) and "steam" or "ip"
    end
    if peers == 0 then return "ip" end
    return nil
end
M._via_of = via_of

local function host_roster()
    local out = { { name = cfg.player_name(), state = "host", host = true, me = true } }
    local others = {}
    for key, r in pairs(st.remote) do
        local state = "game"
        if not r.hello then
            state = "connecting"
        elseif r.dead then
            state = "dead"
        elseif not ue.pawn_of(r.pc) then
            state = "loading"
        end
        local ping = ue.ping_ms(r.pc)
        others[#others + 1] = { name = tostring(r.name), state = state, key = key, index = r.index or 0,
                                ping = ping and math.floor(ping) or nil, via = via_of(key) }
    end
    table.sort(others, function(a, b) return a.index < b.index end)
    for _, o in ipairs(others) do out[#out + 1] = o end
    return out
end

function M.roster()
    if st.role == "host" then return host_roster() end
    local cs = st.client
    if st.role ~= "client" or not cs then return {} end
    if cs.roster then return cs.roster end
    -- before the first ROSTER (or from a host without it): the handshake
    local out = {}
    if cs.host_name then out[1] = { name = cs.host_name, state = "host", host = true } end
    out[#out + 1] = { name = cfg.player_name(), state = "game", me = true,
                      ping = cs.ping and math.floor(cs.ping) or nil }
    return out
end

local function send_roster(now)
    local pcs = st.remote_pcs or {}
    if #pcs == 0 then
        st.roster_sig = nil
        return
    end
    local list = host_roster()
    local sig = {}
    for _, e in ipairs(list) do sig[#sig + 1] = e.name .. "/" .. e.state end
    sig = table.concat(sig, ";")
    if sig == st.roster_sig and now - (st.roster_at or 0) < ROSTER_EVERY_S then return end
    st.roster_sig, st.roster_at = sig, now
    for _, pc in ipairs(pcs) do
        local key = ue.name(pc)
        local fields = {}
        for _, e in ipairs(list) do
            fields[#fields + 1] = e.name
            fields[#fields + 1] = e.state
            fields[#fields + 1] = e.ping and tostring(e.ping) or ""
            fields[#fields + 1] = (e.key == key) and "1" or "0"
        end
        net.send_to(pc, "ROSTER", table.unpack(fields))
    end
end

-- Every part of the 1 s ticks is timed ([PERF] "parts", sdc_ue.sub_time:
-- h:* host, c:* client) and runs in its own pcall: one failing part no longer
-- skips the rest of the second. The work is split in two phases half a
-- second apart (phase B: sdc_ue.delay 500 ms after phase A), so one frame
-- never carries all of it; every part still runs once a second, in the same
-- order.
local function part(label, fn, ...)
    if ue.sub_time then return ue.sub_time(label, fn, ...) end
    local ok, err = pcall(fn, ...)
    if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
    return ok
end

local PHASE_B_MS = 500
local phase_b_pending = false

local function schedule_phase_b(label, fn, now)
    if phase_b_pending then return end
    phase_b_pending = true
    local function run()
        phase_b_pending = false
        fn(now)
    end
    if type(ue.delay) ~= "function" or ue.delay(label, PHASE_B_MS, run) == false then run() end
end

-- Host phase B: items, combat, AI, sounds, movement, looks, state; with the
-- controller list phase A found (st.remote_pcs).
local function host_phase_b(now)
    if st.role ~= "host" then return end
    local list = st.remote_pcs or {}
    local pawns = {}
    for _, pc in ipairs(list) do
        local p = ue.pawn_of(pc)
        if p then pawns[#pawns + 1] = p end
    end
    sync.monitor_pawns = pawns
    part("h:sounds", sync.host_sound_tick, list)
    part("h:items", items.host_tick, list)
    part("h:combat", combat.host_tick)
    part("h:gearfx", gearfx.host_tick)
    part("h:damage", damage.host_tick, list)
    if #list > 0 then
        part("h:dmgnum", dmgnum.try_hooks)
        part("h:whistle", whistle.tick)
        part("h:ownsounds", ownsounds.tick)
    end
    if zombies_on() then part("h:ai", ai.host_tick, list) end
    if #list == 0 then return end
    part("h:shots", sync.ensure_shot_sounds)
    if log.probes_enabled then
        sync.install_motion_probes()
        sync.probe_watch(pawns)
        sync.probe_report()
        if now - (st.last_movecfg or 0) >= 10 then
            st.last_movecfg = now
            for _, p in ipairs(pawns) do sync.log_movement_config("server-copy", p) end
        end
    end
    if now - (st.last_move or 0) >= 2 then
        st.last_move = now
        part("h:movement", sync.host_movement_tick, list)
    end
    if now - st.last_env >= 5 then
        st.last_env = now
        part("h:env", send_env, list)
    end
    if now - (st.last_look or 0) >= 2 then
        st.last_look = now
        part("h:looks", appearance.tick, list)
    end
    part("h:pawnstate", pawnstate.tick, list)
    -- head-attachment probe: heavy (14% of a client log), only with debug_probes
    if log.probes_enabled and now - (st.last_headdbg or 0) >= 15 then
        st.last_headdbg = now
        part("h:headdbg", items.debug_head_report, "host")
    end
    if now - st.last_ai >= 10 then
        st.last_ai = now
        part("h:ai_repl", sync.host_ai_tick)
    end
end

local function host_tick(now)
    local present, list = {}, {}
    for _, pc in ipairs(ue.find_all("PlayerController")) do
        if ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) then
            local r = remote_record(pc)
            present[r.key] = true
            list[#list + 1] = pc
        end
    end
    for key, r in pairs(st.remote) do
        if not present[key] then
            st.remote[key] = nil
            on_player_left(r)
        end
    end
    st.remote_pcs = list
    -- the player list for the clients' co-op panels
    part("h:roster", send_roster, now)
    -- each client's bandwidth cap (engine default 100 KB/s; sdc_net.tune_rates)
    part("h:netrate", net.tune_rates, list, cfg.get("net_speed"))
    -- "player 0" redirection first: everything below may spawn / possess
    part("h:ctx", ctx.tick, list)
    part("h:dialogue", dialogue.host_tick, now)
    part("h:quests", quests.host_tick, now)
    part("h:skipsave", players.host_skip_save_tick)
    for _, r in pairs(st.remote) do
        part("h:players", function()
            players.host_player_tick(r, now)
            local pawn = ue.pawn_of(r.pc)
            if pawn then
                local pk = ue.name(pawn)
                if pk ~= r.pawn_key then r.pawn_key, r.pawn_since = pk, now end
                sync.unstick(pawn, r.pawn_since, "server")
            end
        end)
    end
    part("h:pause", sync.pause_policy, #list > 0)
    schedule_phase_b("session-host-b", host_phase_b, now)
end

function M.force_spawn_all()
    players.force_spawn_all()
end

-- ---------------------------------------------------------------------------
-- Client side
-- ---------------------------------------------------------------------------

-- Client phase B (half a second after phase A): items, gear, damage, AI,
-- looks, state, cleanup.
local function client_phase_b(now)
    if st.role ~= "client" or not st.client then return end
    local cs = st.client
    if ue.in_main_menu() then return end
    local pc = ue.local_pc()
    if not pc then return end
    part("c:items", items.client_tick)
    part("c:gearfx", gearfx.client_tick)
    part("c:damage", damage.client_tick)
    part("c:dmgnum", dmgnum.try_hooks)
    part("c:whistle", whistle.tick)
    part("c:ownsounds", ownsounds.tick)
    if zombies_on() then part("c:ai", ai.client_tick) end

    if now - (cs.last_look or 0) >= 2 then
        cs.last_look = now
        part("c:looks", appearance.tick)
    end
    part("c:pawnstate", pawnstate.tick)
    if log.probes_enabled and now - (cs.last_headdbg or 0) >= 15 then
        cs.last_headdbg = now
        part("c:headdbg", function()
            items.debug_head_report("client")
            items.debug_durability()
        end)
    end
    if now - cs.last_cleanup >= 3 then
        cs.last_cleanup = now
        part("c:stale_pawns", sync.client_hide_stale_pawns)
        part("c:ai_ghosts", sync.client_ai_tick)
        part("c:smoothing", sync.client_smoothing_tick)
        if log.debug_enabled and now - (cs.last_movecfg or 0) >= 10 then
            cs.last_movecfg = now
            local pawn = ue.pawn_of(pc)
            sync.log_movement_config("client-own", pawn or pc)
        end
        cs.ping = ue.ping_ms(pc)
    end
end

local function client_tick(now)
    local cs = st.client
    -- other players' characters must not act on this player through "player 0"
    ctx.tick_client(cfg.get("client_quiet_others") ~= false)
    -- The role flips to "client" while the menu world is still loaded; the
    -- controller of that world never reaches the server, so wait for the
    -- host's map and its controller.
    if ue.in_main_menu() then return end
    local pc = ue.local_pc()
    if not pc then return end
    local pc_key = ue.name(pc)
    if pc_key ~= cs.pc_key then
        cs.pc_key, cs.connected_at = pc_key, now
        cs.acked, cs.hello_attempts, cs.hello_sent_at = false, 0, nil
    end

    -- Handshake: HI until the host acknowledges it.
    if not cs.acked and cs.hello_attempts < 12
        and now - cs.connected_at >= 2
        and (not cs.hello_sent_at or now - cs.hello_sent_at >= 5) then
        cs.hello_attempts = cs.hello_attempts + 1
        cs.hello_sent_at = now
        net.send_to_host("HI", M.VERSION, cfg.player_name())
        if cs.hello_attempts == 12 then
            log.warn("client: host never acknowledged HI (client->host channel not working)")
        end
    end

    pcall(net.log_client_rate, pc)
    local pawn = ue.pawn_of(pc)
    if pawn then part("c:shots", sync.ensure_shot_sounds) end
    if log.probes_enabled and pawn then
        sync.install_motion_probes()
        sync.probe_watch({ pawn })
        sync.probe_report()
    end
    if pawn then part("c:unstick", sync.unstick, pawn, cs.pawn_seen_at or now, "client") end
    -- the game's own local-player setup of the character (health bar trace, timers)
    part("c:localinit", localinit.tick, pawn, now)
    -- the client's own MainMenu sublevel (sky, weather, menu script) goes,
    -- unless the character creator is using it
    if cfg.get("unload_menu_level") ~= false then
        local cc = package.loaded["sdc_charcreate"]
        local keep = type(cc) == "table" and cc.is_open and cc.is_open() or false
        part("c:menu_level", localinit.menu_level_tick, pawn, now, keep)
    end
    part("c:players", players.client_tick, cs, pc, pawn, now)
    part("c:widgets", players.client_widgets_tick)
    part("c:dialogue", dialogue.client_tick, now, pc, pawn)
    part("c:quests", quests.client_tick, now, pc, pawn)
    schedule_phase_b("session-client-b", client_phase_b, now)
end

-- F7 panel's respawn button and console helpers.
function M.request_respawn()
    players.request_respawn("host")
end

function M.reinit_local()
    players.reinit()
end

function M.install_death_watch()
    players.install_watches()
end

-- ---------------------------------------------------------------------------
-- Standalone (main menu / single player)
-- ---------------------------------------------------------------------------

local function standalone_tick(now, in_menu)
    if in_menu and st.launch_join then
        local code = st.launch_join
        st.launch_join = nil
        M.join(code, cfg.get("port"), false)
        return
    end
    if st.listen_requested_at and not st.netdiag_done and now - st.listen_requested_at >= 6 then
        st.netdiag_done = true
        pcall(netdiag.report, "6 s after the listen request")
    end
    if st.listen_requested_at and not st.listen_warned and now - st.listen_requested_at >= 25 then
        st.listen_warned = true
        pcall(netdiag.report, "listen failed")
        -- the game's own Steam net driver did not listen: try plain UDP
        -- sockets once (port 7777; the Steam link and IP joins both use them)
        if in_menu and not netdiag.ip_fallback and cfg.get("listen_ip_fallback") ~= false and steam.own_id() then
            local okf, changed = pcall(netdiag.switch_to_ip)
            if okf and changed then
                log.toast("Мир не открылся для друзей. Открываю его ещё раз через обычные сетевые сокеты (порт 7777): друзья подключатся через Steam или по IP.",
                    "warn", 12, "listen through Steam failed; retrying with IpNetDriver")
                st.netdiag_done = false
                M.open_menu_as_server()
                return
            end
        end
        if steam.server_api_pending then
            -- bUseSteamNetworking=False was written at this start: the game's
            -- UDP sockets work from the next start (sdc_steam)
            log.toast("Мод обновил сетевые настройки игры. Перезапустите игру один раз, чтобы открыть мир для друзей или подключиться.",
                "warn", 12, "listen failed; Engine.ini network setting was just written, restart needed")
        else
            log.say("listen_failed", "err", 10)
        end
    end
    if not in_menu then return end
    if cfg.get("auto_host") and not st.auto_host_done and now - st.menu_since >= 8 then
        st.auto_host_done = true
        M.start_fresh_server()
        return
    end
    if hosting_enabled() and not st.menu_listen_attempted and now - st.menu_since >= 3
        and not ue.has_pending_connection() then
        M.open_menu_as_server()
        return
    end
    if cfg.get("auto_join") and not ue.has_pending_connection()
        and st.join.attempts < JOIN_MAX_AUTO_ATTEMPTS
        and now - st.menu_since >= 6
        and now - st.join.started_at >= JOIN_RETRY_S then
        M.join(cfg.get("host_ip"), cfg.get("port"), true)
    end
end

-- ---------------------------------------------------------------------------
-- Role transitions and the main tick
-- ---------------------------------------------------------------------------

-- Host: a copy of the save folder once per game start, before anyone joins.
-- With other players' characters in the world the game's own save may pick
-- up their data (another co-op mod for this game reports exactly that), so
-- a known good copy comes first. Saved\SDCoop_Backups\<date-time>\; only the
-- newest backup_keep of them stay (sdc_savecheck.after_backup checks the copy
-- and prunes; other folders there are never touched).
local saves_backed_up = false
local function backup_saves()
    if saves_backed_up then return end
    saves_backed_up = true
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return end
    local src = base .. "\\SurrounDead\\Saved\\SaveGames"
    local dst = base .. "\\SurrounDead\\Saved\\SDCoop_Backups\\" .. os.date("%Y-%m-%d_%H-%M-%S")
    -- os.execute -> true|nil, "exit", code; robocopy: 0-7 done (1 = files copied), 8+ failed
    local ok, _, _, code = pcall(os.execute, string.format(
        'robocopy "%s" "%s" /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP >nul 2>&1', src, dst))
    log.info("saves: backup to %s (ok=%s, robocopy exit %s)", dst, tostring(ok), tostring(code))
    local sc = package.loaded["sdc_savecheck"]
    if type(sc) == "table" and sc.after_backup then pcall(sc.after_backup, dst, ok and code or nil) end
end

-- Client: the quick-save key and sleeping still run the game's save on the
-- client's own controller, which would overwrite the client's current
-- single-player slot with a half-empty copy of the host's world. While
-- connected, Easy Multi Save's current slot points at a throwaway slot; the
-- previous name comes back (and the throwaway slot is deleted) on leaving.
local EMS_LIB = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"
local CLIENT_TEMP_SLOT = "SDCoop_ClientTemp"
local client_prev_slot = nil
local function client_save_redirect(on)
    local lib, wc = ue.find_object(EMS_LIB), ue.world_context()
    if not lib or not wc then
        log.warn("saves: EMS library not found, client saves are not redirected")
        return
    end
    if on then
        local cur, cerr = ue.ems_current_slot()
        if not cur then log.warn("saves: current save slot unknown: %s", tostring(cerr)) end
        client_prev_slot = cur
        -- crash-safe: the slot to come back to is kept on disk until the leave
        -- (a game closed / crashed while connected left EMS's current slot at
        -- the throwaway one; sdc_savecheck restores it at the next start)
        local sc = package.loaded["sdc_savecheck"]
        if type(sc) == "table" and sc.client_slot_before_join then
            local okp, prev = pcall(sc.client_slot_before_join, cur)
            if okp then client_prev_slot = prev end
        end
        -- leftovers of a crash or a closed game: the game's own load would bring their progress back
        local okd, derr = ue.ems_delete_slot(CLIENT_TEMP_SLOT)
        if not okd then log.warn("saves: deleting %s: %s", CLIENT_TEMP_SLOT, tostring(derr)) end
        local prog = package.loaded["sdc_progress"]
        if type(prog) == "table" and prog.wipe_slot_files then pcall(prog.wipe_slot_files, CLIENT_TEMP_SLOT) end
        local ok, err = pcall(function() lib:SetCurrentSaveGameName(wc, CLIENT_TEMP_SLOT) end)
        log.info("saves: client saves go to %s while connected (was %s, old temp deleted ok=%s, ok=%s%s)", CLIENT_TEMP_SLOT,
            tostring(client_prev_slot), tostring(okd), tostring(ok), ok and "" or (" " .. tostring(err)))
    else
        if client_prev_slot and client_prev_slot ~= "" and client_prev_slot ~= CLIENT_TEMP_SLOT then
            pcall(function() lib:SetCurrentSaveGameName(wc, client_prev_slot) end)
        end
        local sc = package.loaded["sdc_savecheck"]
        if type(sc) == "table" and sc.client_slot_restored then pcall(sc.client_slot_restored, client_prev_slot) end
        local okd, derr = ue.ems_delete_slot(CLIENT_TEMP_SLOT)
        if not okd then log.warn("saves: deleting %s: %s", CLIENT_TEMP_SLOT, tostring(derr)) end
        local prog = package.loaded["sdc_progress"]
        if type(prog) == "table" and prog.wipe_slot_files then pcall(prog.wipe_slot_files, CLIENT_TEMP_SLOT) end
        log.info("saves: client save slot back to %s (temp slot deleted ok=%s)", tostring(client_prev_slot), tostring(okd))
        client_prev_slot = nil
    end
end

local function on_role_change(old, new)
    ai.reset("role")
    pcall(dialogue.reset, "role " .. tostring(new))
    pcall(quests.reset, "role " .. tostring(new))
    log.info("role: %s -> %s (map=%s)", old, new, tostring(st.map))
    if old == "host" and new ~= "host" then
        pcall(steam.set_presence, false)
        -- remote players' characters / controllers cached for the per-frame
        -- monitor and the sound hooks belong to the closed server
        sync.forget_world()
    end
    if new == "host" then
        st.listen_requested_at = nil
        st.remote, st.remote_pcs, st.next_index = {}, {}, 0
        ctx.reset()
        items.reset()
        appearance.reset()
        pawnstate.reset()
        damage.reset()
        backup_saves()
        log.info("net: listening through %s, own SteamID %s",
            ue.find_first("SteamSocketsNetDriver") and "Steam (SteamSocketsNetDriver)"
                or (ue.find_first("IpNetDriver") and "IP (IpNetDriver)" or "?"),
            tostring(steam.own_id()))
        log.say("server_started", "ok", 10)
    elseif new == "client" then
        st.client = new_client_state()
        st.join.attempts = 0
        sync.reset_client_state()
        items.reset()
        appearance.reset()
        pawnstate.reset()
        damage.reset()
        pcall(client_save_redirect, true)
        for cmd in tostring(cfg.get("client_cvars") or ""):gmatch("[^;]+") do
            cmd = cmd:gsub("^%s+", ""):gsub("%s+$", "")
            if cmd ~= "" then
                ue.exec(cmd)
                -- read it back: a shipping build may refuse some variables
                local name = cmd:match("^(%S+)")
                local ksl = ue.ksl()
                local v = ksl and ue.try(function() return ksl:GetConsoleVariableFloatValue(name) end)
                log.info("client cvar: '%s' -> %s now %s", cmd, tostring(name), tostring(v))
            end
        end
        log.say("connected", "ok")
    elseif new == "standalone" then
        if old == "client" then
            pcall(client_save_redirect, false)
            ctx.reset()
            if st.disconnect_requested then
                log.say("disconnected", "info")
            else
                log.say("connection_lost", "warn", 8)
            end
            st.client = nil
        elseif old == "host" then
            log.say("server_closed", "info")
            sync.pause_policy(false)
            ctx.reset()
        end
        st.disconnect_requested = false
        st.remote, st.remote_pcs = {}, {}
        damage.reset()
    end
end

-- Level change. Every object of the old world is freed by the load's garbage
-- collection, so every cached wrapper (controllers, characters, widgets) is
-- dropped WITHOUT touching it: remote player records go without on_left (no
-- DestroyActor on old-world characters), the "player 0" map, item / look /
-- state caches, sound and monitor lists, polled buttons, the cached local
-- controller and the F7 panel (world_reset_hooks).
function M.reset_world(why, pc_key)
    local dropped = 0
    for _ in pairs(st.remote) do dropped = dropped + 1 end
    st.remote, st.remote_pcs, st.spawned = {}, {}, {}
    if st.client then st.client.last_pawn = nil end
    ctx.reset()
    items.reset()
    appearance.reset()
    pawnstate.reset()
    damage.reset()
    ai.reset("world:" .. tostring(why))
    pcall(dialogue.reset, "world:" .. tostring(why))
    pcall(quests.reset, "world:" .. tostring(why))
    sync.forget_world()
    W.forget_all()
    ue.forget_world()
    for name, fn in pairs(M.world_reset_hooks) do
        local ok, err = pcall(fn, why, pc_key)
        if not ok then log.err("world reset: %s: %s", tostring(name), tostring(err)) end
    end
    log.info("world reset (%s): cached objects of the old world dropped (%d remote player record(s))", why, dropped)
end

-- RegisterLoadMapPreHook (main.lua). The old world is still alive here; it
-- is torn down and garbage collected right after.
function M.on_load_map()
    st.loadmap_reset = true
    M.reset_world("loadmap")
end

function M.tick()
    local now = os.time()
    local map = ue.map_name()
    -- A reopened level keeps its name; a new local controller means a new world.
    local pc_key = ue.name(ue.local_pc())
    if map and (map ~= st.map or pc_key ~= st.pc_key) then
        log.info("world: %s -> %s", tostring(st.map), map)
        st.map, st.map_since, st.pc_key = map, now, pc_key
        st.in_menu = nil
        -- Fallback for a level change the LoadMap hook did not report: reset
        -- before any tick below uses the old world's objects.
        if pc_key ~= "<none>" then
            local by_loadmap = st.loadmap_reset
            st.loadmap_reset = false
            if st.world_pc and pc_key ~= st.world_pc and not by_loadmap then
                M.reset_world("new controller", pc_key)
            end
            st.world_pc = pc_key
        end
    end
    local in_menu = ue.in_main_menu()
    if in_menu ~= st.in_menu then
        st.in_menu, st.menu_since = in_menu, now
        log.info("state: %s", in_menu and "main menu" or "in game")
    end
    -- a friend's invite accepted while this game was not running: Steam put
    -- "+sdcoop_join <id>" on the command line
    if in_menu and not st.launch_checked and now - (st.menu_since or now) >= 1 then
        st.launch_checked = true
        st.launch_join = steam.take_launch_code()
    end
    local role = ue.net_role()
    if role == "unknown" then return end
    if role ~= st.role then
        local old = st.role
        st.role = role
        on_role_change(old, role)
    end
    if role == "host" then
        -- friends see "Join game" while the host is in its world
        pcall(steam.set_presence, not in_menu)
        if in_menu and st.launch_join then
            local code = st.launch_join
            st.launch_join = nil
            M.join(code, cfg.get("port"), false)
            return
        end
        host_tick(now)
    elseif role == "client" then
        if not st.client then st.client = new_client_state() end
        client_tick(now)
    else
        standalone_tick(now, in_menu)
    end
end

-- ---------------------------------------------------------------------------
-- Status for the menu / console
-- ---------------------------------------------------------------------------

function M.status()
    local role = st.role
    local s = { role = role, lines = {} }
    if role == "host" then
        s.title = string.format("Сервер · игроков онлайн: %d · порт %d (UDP)", #st.remote_pcs, HOST_PORT)
        if ue.in_main_menu() then
            s.lines[#s.lines + 1] = "Мир открыт для друзей. Загрузите сохранение (Continue / Load)."
        end
        -- the Steam link (sdc_steamlink) hosting: friends join through Steam as well
        local okl, sl = pcall(require, "sdc_steamlink")
        local okst, sls = false, nil
        if okl and type(sl) == "table" and type(sl.status) == "function" then okst, sls = pcall(sl.status) end
        if okst and type(sls) == "table" and sls.state == "hosting" then
            s.lines[#s.lines + 1] = "Друзья подключаются через Steam («Присоединиться к игре») или по вашему IP, порт 7777"
        else
            s.lines[#s.lines + 1] = "Друзья подключаются по вашему IP (Radmin VPN / ZeroTier / проброс порта), порт 7777"
        end
        s.lines[#s.lines + 1] = "• " .. cfg.player_name() .. " (вы, хост)"
        for _, r in pairs(st.remote) do
            local ping = ue.ping_ms(r.pc)
            s.lines[#s.lines + 1] = string.format("• %s%s%s", r.name,
                ping and string.format(" · %d мс", math.floor(ping)) or "",
                ue.pawn_of(r.pc) and "" or " · ждёт персонажа")
        end
    elseif role == "client" then
        local cs = st.client or {}
        s.title = string.format("Клиент · %s%s", cs.host_name and ("хост " .. cs.host_name) or "подключено",
            cs.ping and string.format(" · пинг %d мс", math.floor(cs.ping)) or "")
        if cs.host_version and cs.host_version ~= M.VERSION then
            s.lines[#s.lines + 1] = "! Версия мода у хоста " .. cs.host_version .. ", у вас " .. M.VERSION
        end
        pcall(quests.status_lines, s.lines)
    elseif ue.has_pending_connection() then
        s.title = "Подключение к " .. tostring(st.join.target or cfg.get("host_ip")) .. "..."
    elseif role == "standalone" then
        if ue.in_main_menu() then
            s.title = "Главное меню"
            s.lines[#s.lines + 1] = hosting_enabled()
                and "Мир сейчас откроется для друзей (меню перезагрузится)."
                or "Чтобы стать хостом, нажмите «Открыть мир для друзей»."
            if cfg.get("auto_join") then
                s.lines[#s.lines + 1] = string.format("Автоподключение к %s:%d (попыток: %d)",
                    cfg.get("host_ip"), cfg.get("port"), st.join.attempts)
            end
        else
            s.title = "Одиночная игра (мир закрыт для подключения)"
        end
    else
        s.title = "Загрузка..."
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Message handlers
-- ---------------------------------------------------------------------------

function M.register_handlers()
    -- client -> host: HI|version|name
    net.on("HI", function(f, pc)
        local r = remote_record(pc)
        local first = not r.hello
        r.hello, r.version = true, f[1]
        if f[2] and f[2] ~= "" then r.name = f[2] end
        net.send_to(pc, "HELLO", M.VERSION, cfg.player_name(), "ack")
        send_env({ pc })
        appearance.send_all(pc)
        pawnstate.send_all(pc)
        sync.send_shot_map(pc)
        if first then
            log.say("player_joined", "ok", 6, r.name)
            local others = {}
            for _, other in ipairs(st.remote_pcs) do
                if ue.name(other) ~= r.key then others[#others + 1] = other end
            end
            net.broadcast(others, "MSG", "player_joined", r.name)
            if r.version ~= M.VERSION then
                log.say("peer_version", "warn", 10, r.name, tostring(r.version), M.VERSION)
            end
        end
    end)

    -- host -> client: HELLO|version|name
    net.on("HELLO", function(f)
        local cs = st.client
        if not cs then return end
        local first = cs.host_name == nil
        cs.host_version, cs.host_name = f[1], (f[2] ~= "" and f[2]) or "host"
        if f[3] == "ack" and not cs.acked then
            cs.acked = true
            log.info("client: host acknowledged handshake")
        end
        if first then
            log.say("connected_to", "ok", 6, cs.host_name)
            if cs.host_version ~= M.VERSION then
                log.say("host_version", "warn", 10, tostring(cs.host_version), M.VERSION)
            end
        end
    end)

    -- host -> client: MSG|text
    net.on("MSG", function(f)
        -- MSG|<catalog key>|<arg>...: localised on the receiving side
        if f[1] and log.TEXT[f[1]] then log.say(f[1], "info", 6, f[2], f[3]) end
    end)

    -- host -> client: ROSTER|<name>|<state>|<ping>|<me>|...   (the panel's player list)
    net.on("ROSTER", function(f)
        local cs = st.client
        if not cs then return end
        local list = {}
        for i = 1, #f - 3, 4 do
            list[#list + 1] = { name = f[i], state = f[i + 1], ping = tonumber(f[i + 2]),
                                me = f[i + 3] == "1", host = f[i + 1] == "host" }
        end
        cs.roster, cs.roster_at = list, os.time()
    end)

    -- RESPAWN / SPAWNED
    players.register_handlers()
    appearance.register_handlers()
    items.register_handlers()
    pawnstate.register_handlers()
    combat.register_handlers()
    damage.register_handlers()
    dmgnum.register_handlers()
    whistle.register_handlers()
    ownsounds.register_handlers()
    dialogue.register_handlers()
    quests.register_handlers()
    ai.register_handlers()   -- message handlers only; each runs while its feature is on
end

players.init(st, { remote_record = remote_record })
items.init(st)
appearance.init(st)
pawnstate.init(st)
combat.init(st)
gearfx.init(st)
damage.init(st)
dmgnum.init(st)
whistle.init(st)
ownsounds.init(st)
dialogue.init(st)
quests.init(st)

function M.install_item_watch()
    items.install()
    combat.install()
end

return M
