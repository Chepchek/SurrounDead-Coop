-- SDCoop: Steam identity and the game's Engine.ini network setting.
--
-- Joining through Steam is done by sdc_steamlink: the game stays on plain
-- UDP (IpNetDriver) and the helper SDCoopSteamLink.exe carries it over
-- Steam P2P. The game's own SteamSocketsNetDriver (`open steam.<id>:7777`)
-- never came up in this build; that path is used only with config
-- steam_p2p = true (an experiment) or when the helper is off.
--
-- This module, through the game's SteamCore plugin (static functions on the
-- class default objects):
--   * own SteamID64: SteamCore returns an FSteamID with no reflected fields
--     (UE4SS hands Lua an empty table), so GetSteamID is post-hooked and the
--     value is turned into a string with SteamUtilities.BreakSteamID inside
--     the hook;
--   * the host's "code for friends" (= its SteamID64), the overlay invite
--     dialog, and rich presence "connect" (friends see "Join game") when the
--     helper of sdc_steamlink is off (it sets the presence itself);
--   * a join code passed by Steam on the command line when a friend accepts
--     an invite while the game is not running (+sdcoop_join <id>).
-- Accepting an invite while the game already runs: the helper of
-- sdc_steamlink receives it (GameRichPresenceJoinRequested) and the mod joins.

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = { id = nil, presence = false }

local USER = "/Script/SteamCore.Default__User"
local UTIL = "/Script/SteamCore.Default__SteamUtilities"
local FRIENDS = "/Script/SteamCore.Default__Friends"
local GET_ID = "/Script/SteamCore.User:GetSteamID"
local CONNECT_PREFIX = "+sdcoop_join "

local function is_steam_id(s)
    return type(s) == "string" and #s == 17 and s:match("^7656119%d+$") ~= nil
end
M.is_steam_id = is_steam_id

-- ---------------------------------------------------------------------------
-- Own SteamID64
-- ---------------------------------------------------------------------------

local id_hooked, id_failed_logged, id_asks = false, false, 0

local function on_get_id(ret)
    if M.id or not ret then return end
    local util = ue.find_object(UTIL)
    if not util then return end
    local ok, s = pcall(function() return util:BreakSteamID(ret:get()) end)
    s = ok and ue.str(s) or nil
    if is_steam_id(s) then
        M.id = s
        log.info("steam: own SteamID %s", s)
    elseif not id_failed_logged then
        id_failed_logged = true
        log.info("steam: no SteamID (%s): Steam is not running for this game, or it was started outside Steam",
            ok and tostring(s) or "BreakSteamID failed")
    end
end

-- The own SteamID64 as a string, or nil (Steam not initialised for this
-- game). Cheap after the first success; otherwise asks again at most every
-- call until 10 attempts.
function M.own_id()
    if M.id then return M.id end
    if id_asks >= 10 then return nil end
    id_asks = id_asks + 1
    if not id_hooked then
        id_hooked = true
        -- post callback: (Context, ReturnValue). Returns nothing.
        local ok, err = pcall(RegisterHook, GET_ID, function() end, function(_, ret)
            local okc, e = pcall(on_get_id, ret)
            if not okc then log.err_throttled("steam-id", "steam id: %s", tostring(e)) end
        end)
        if not ok then
            log.warn("steam: cannot hook %s: %s", GET_ID, tostring(err))
            return nil
        end
    end
    local user = ue.find_object(USER)
    if user then pcall(function() user:GetSteamID() end) end
    return M.id
end

-- ---------------------------------------------------------------------------
-- Engine.ini: plain UDP sockets under Steam
-- ---------------------------------------------------------------------------
-- GameEngine.NetDriverDefinitions is switched to IpNetDriver in memory
-- (sdc_netdiag / sdc_steamlink), no Engine.ini needed for that. What cannot
-- be changed while the game runs is the DEFAULT socket subsystem: the
-- SteamSockets plugin decides it once, at engine start, from
-- [OnlineSubsystemSteam] bUseSteamNetworking (default True = Steam sockets
-- replace the Windows ones, and IpNetDriver can neither listen nor connect -
-- seen 2026-11-10 under Steam). So bUseSteamNetworking=False must be in the
-- user's Saved/Config/Windows/Engine.ini BEFORE the game starts: the first
-- start after installing writes it and needs one restart (only when the game
-- was launched through Steam; outside Steam the setting does not matter).
-- bInitServerOnClient (Steam game-server API, needed only for OSS sessions)
-- is no longer added; a line already there is left alone.
-- Config steam_server_api = false leaves the file alone.
M.server_api_pending = false

-- Launched by Steam (its client puts the app id into the environment)?
local function launched_by_steam()
    local id = os.getenv("SteamAppId") or os.getenv("SteamGameId")
    return id ~= nil and id ~= ""
end

-- The engine rewrites Engine.ini from memory when it exits, so a line added
-- while the game runs (always the case for a mod) would be gone by the next
-- start. The file is therefore made read-only once the line is in it: the
-- engine keeps reading it, it only cannot overwrite it any more.
local function set_readonly(path, on)
    local cmd = string.format('attrib %sR "%s"', on and "+" or "-", path:gsub("/", "\\"))
    local ok = pcall(os.execute, cmd)
    return ok
end

local function writable(path)
    local f = io.open(path, "a")
    if f then f:close() return true end
    return false
end

-- The setting this mod keeps in the game's Engine.ini ([OnlineSubsystemSteam]):
--   bUseSteamNetworking=False  (unless config steam_p2p) the SteamSockets
--     plugin reads this at start: True makes Steam Sockets the DEFAULT socket
--     subsystem, so even the plain IpNetDriver listened through Steam and
--     failed (2026-11-10: launched through Steam, neither SteamSockets nor
--     IpNetDriver opened the world; outside Steam IP works). False keeps the
--     Windows sockets: the world opens over UDP (the Steam tunnel of
--     sdc_steamlink, or IP: Radmin VPN, ZeroTier, port 7777); Steam itself
--     (ID, invites, presence) stays.
-- Takes effect at the next game start; the file is kept read-only.
M.ip_mode = true

function M.ensure_server_api(cfg)
    M.ip_mode = not (cfg and cfg.get("steam_p2p") == true)
    if cfg and cfg.get("steam_server_api") == false then return end
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return end
    local path = base .. "/SurrounDead/Saved/Config/Windows/Engine.ini"
    local f = io.open(path, "r")
    local text = f and f:read("a") or ""
    if f then f:close() end
    local want = { { "bUseSteamNetworking", M.ip_mode and "False" or "True" } }
    local missing = {}
    for _, kv in ipairs(want) do
        local cur = text:match(kv[1] .. "%s*=%s*(%a+)")
        if not cur or cur:lower() ~= kv[2]:lower() then missing[#missing + 1] = kv end
    end
    if #missing == 0 then
        if writable(path) then set_readonly(path, true) end
        log.info("steam: Engine.ini ok (bUseSteamNetworking=%s, read-only=%s)",
            M.ip_mode and "False" or "True", tostring(not writable(path)))
        return
    end
    if not writable(path) then set_readonly(path, false) end
    -- a value of ours that is wrong now (steam_p2p switched): drop that line
    for _, kv in ipairs(missing) do
        text = text:gsub("\n?" .. kv[1] .. "%s*=%s*%a+", "")
    end
    local w = io.open(path, "w")
    if not w then
        log.warn("steam: cannot write %s; opening the world for friends may fail", path)
        return
    end
    if text ~= "" and not text:match("\n$") then text = text .. "\n" end
    local block = "\n[OnlineSubsystemSteam]\n"
    for _, kv in ipairs(missing) do block = block .. kv[1] .. "=" .. kv[2] .. "\n" end
    w:write(text .. block)
    w:close()
    set_readonly(path, true)
    local names = {}
    for _, kv in ipairs(missing) do names[#names + 1] = kv[1] .. "=" .. kv[2] end
    -- outside Steam the Windows sockets are the default anyway: no restart
    if not launched_by_steam() then
        log.info("steam: Engine.ini updated (%s), read-only; the game was not started by Steam, nothing to restart",
            table.concat(names, ", "))
        return
    end
    M.server_api_pending = true
    log.info("steam: Engine.ini updated (%s), read-only; takes effect at the next game start", table.concat(names, ", "))
    log.toast("Мод обновил сетевые настройки игры. Перезапустите игру один раз, чтобы открыть мир для друзей или подключиться.",
        "warn", 12, "steam: Engine.ini updated, restart needed")
end

-- ---------------------------------------------------------------------------
-- Host: code, rich presence, invites
-- ---------------------------------------------------------------------------

function M.connect_string()
    local id = M.own_id()
    return id and (CONNECT_PREFIX .. id) or nil
end

-- Friends see "Join game" while this host has its world open.
-- With sdc_steamlink on, its helper owns the rich presence (its "connect"
-- leads to the helper's tunnel); a ClearRichPresence from here would wipe it.
M.presence_by_helper = false
function M.set_presence(on)
    if M.presence_by_helper then return end
    local fr = ue.find_object(FRIENDS)
    if not fr then return end
    if on then
        local cs = M.connect_string()
        if not cs or M.presence then return end
        local ok1 = pcall(function() fr:SetRichPresence("connect", cs) end)
        pcall(function() fr:SetRichPresence("status", "SurrounDead — кооператив (SDCoop)") end)
        M.presence = ok1
        log.info("steam: rich presence on (%s, ok=%s)", cs, tostring(ok1))
    elseif M.presence then
        pcall(function() fr:ClearRichPresence() end)
        M.presence = false
        log.info("steam: rich presence off")
    end
end

-- Opens the Steam overlay's invite dialog. Returns ok, reason.
function M.invite()
    local cs = M.connect_string()
    if not cs then return false, "no_steam" end
    local fr = ue.find_object(FRIENDS)
    if not fr then return false, "no_steamcore" end
    local ok, err = pcall(function() fr:ActivateGameOverlayInviteDialogConnectString(cs) end)
    log.info("steam: invite dialog (ok=%s%s)", tostring(ok), ok and "" or (" " .. tostring(err)))
    return ok, ok and nil or "overlay"
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- "steam.<id>", a bare SteamID64 or anything else (IP / host name): the
-- SteamID64 when it is a Steam code.
function M.code_of(address)
    local s = tostring(address or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id = s:match("^steam%.(%d+)$") or s:match("^steam%.(%d+):%d+$") or s
    if is_steam_id(id) then return id end
    return nil
end

-- A join code Steam put on the command line (invite accepted while the game
-- was not running), once per game start.
local launch_used = false
function M.take_launch_code()
    if launch_used then return nil end
    launch_used = true
    local ksl = ue.ksl()
    local ok, cl = pcall(function() return ksl:GetCommandLine() end)
    local s = ok and ue.str(cl) or ""
    local id = s:match("%+sdcoop_join%s+(%d+)")
    if is_steam_id(id) then
        log.info("steam: join code from the command line: %s", id)
        return id
    end
    return nil
end

return M
