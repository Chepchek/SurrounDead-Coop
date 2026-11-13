-- SDCoop: the host's say over the players of its world (0.7.3): kick, ban,
-- who may join, and the game's cheats switched off on clients.
--
-- Kick (host, the co-op panel's player list): KICK|<code> to that client
--   (0 kick, 1 ban, 2..5 not let in: see Access; an older mod reads every
--   code but 1 as a kick). Its mod leaves at once (the game's own
--   "disconnect", as the panel's Disconnect button) and says why. If the
--   player is still there 6 s later (an older mod or none):
--   ClientReturnToMainMenuWithTextReason on its controller (the engine's own
--   way back to the menu); 12 s: its character and controller are destroyed
--   (what the engine's KickPlayer does).
-- Ban (host): config banned_players gets the player's SteamID (as its mod
--   reported it, sdc_persist.steam_of) and name - only after its handshake
--   (HI): a "connecting" player has neither and can only be kicked. A banned
--   player is kicked (KICK|1) as soon as its handshake or its SteamID
--   arrives. A player joining by IP can change its name and claimed id: a
--   ban holds for honest clients.
-- Access (host; config join_access open | password | approve | list,
--   allowed_players, max_players, join_password): decided once per player,
--   at its early id (sdc_persist's
--   PSID: in the host's world, no character yet), else at its hello (an
--   older mod, persist_early_id off: its character exists by then). With
--   password / approve / list an undecided player gets no character: no id within
--   ID_WAIT_S of its connection, the host decides by what it knows (no
--   SteamID, the placeholder name: approve - it waits; list - KICK|2). The
--   ban list first, then max_players (the host and everyone in or waiting
--   count, not an earlier connection of the same player that the engine has
--   not dropped yet; full: KICK|5), then the mode. open: everyone in (as
--   before). list ("invite only"): only players on allowed_players (the
--   Steam tab's Invite puts a friend there), the rest KICK|2. approve: players on the
--   list at once; anyone else waits - ACCESS|wait to its client, one notice
--   to the host, its first character held (sdc_players.access_gate, the id
--   gate of sdc_persist) - until the host's Allow (it goes on the list;
--   ACCESS|ok), Deny (KICK|3), or ACCESS_WAIT_S without an answer (KICK|4).
--   password: players on the list at once; anyone else - by IP or through
--   Steam alike - is asked (ACCESS|pw, again every PW_ASK_EVERY_S) and its
--   mod answers JPW|<the password it keeps for this host> (config
--   host_passwords, per join target); its first character is held as with
--   approve. Right: on the list (a later new password does not lock it out),
--   ACCESS|ok. Else KICK|6|<0 none, 1 wrong, 2 locked, 3 unset>|<minutes>: no
--   answer within PW_WAIT_S (an older mod) or an empty one = none; the host
--   has set no password yet = unset (an older mod reads it as none); PW_TRIES wrong
--   ones within PW_WINDOW_S from one network address lock that address out
--   for PW_LOCK_S (in memory, until the game restarts). Only a real address
--   counts, never the SteamID or name a client claims (they would let anyone
--   lock a friend out, or dodge the limit); loopback (a Steam friend, a
--   local tunnel) is no address: not counted, each try costs a world load. No log
--   line holds a password (sdc_net hides JPW). A client joining by IP still
--   says its own SteamID / name: a listed id skips the password.
--   The co-op panel's World tab shows the waiting and the recently refused
--   players, the list and the bans.
-- Cheats (host setting client_cheats = false): RULES|cheats|0 to every
--   client. The client's mod keeps the game's debug menu and its cheats off
--   while it is in that world - the AutoSettings CVars Debug.Allow (the
--   debug menu, BP_PlayerCharacter @61650), Debug.NoClip, Debug.Invincibility,
--   Debug.HungerStat, Debug.ThirstStat, Debug.StaminaStat (all false by
--   default, SD_GameInstance @2035-6459) - closes an open debug menu and
--   refuses the engine's cheat commands (god, fly, ghost, teleport, slomo,
--   summon) typed into a console. Its own values come back when it leaves.
--   A client with an edited mod can still cheat: this stops the game's own
--   cheats, not a determined player.
-- Friendly fire (host setting friendly_fire): RULES|ff|<0/1> to every client
--   the host let in (not while it waits for the host's answer), again after
--   a change; the client's sdc_ffire tells its player (an older mod ignores
--   it). The damage itself is the host's (sdc_ffire).
-- Knockdown (host setting down_enabled): RULES|down|<0/1>|<seconds> is sent
--   by sdc_down itself; a client's handler here hands it to sdc_down (an
--   older mod ignores it). "Save the world now" is refused while somebody
--   is down.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = {}

local S = nil                  -- sdc_session.state
local FALLBACK_MS, DESTROY_MS = 6000, 12000
local ACCESS_WAIT_S = 120      -- approve: a player the host has not answered is refused after this long
local SID_WAIT_S = 6           -- a hello before its SteamID: the access waits this long for the early id
local ID_WAIT_S = 60           -- approve / list: no id this long after the connection -> decided without it
local RECENT_MAX = 8           -- refused players kept for the panel
local PW_WAIT_S = 20           -- password: no answer this long -> refused (an older mod has no ACCESS|pw)
local PW_ASK_EVERY_S = 4       -- password: asked again this often while unanswered
local PW_TRIES, PW_WINDOW_S, PW_LOCK_S = 5, 600, 600   -- 5 wrong within 10 min -> refused for 10 min
local PW_MAX_CHARS = 64
local PW_KEEP = 20             -- client: passwords kept (host_passwords), the oldest dropped
-- KICK codes
local KICK_KICK, KICK_BAN, KICK_LIST, KICK_DENIED, KICK_TIMEOUT, KICK_FULL, KICK_PASSWORD = 0, 1, 2, 3, 4, 5, 6
M.KICK = { kick = KICK_KICK, ban = KICK_BAN, list = KICK_LIST, denied = KICK_DENIED, timeout = KICK_TIMEOUT,
           full = KICK_FULL, password = KICK_PASSWORD }
-- KICK|6|<sub>|<minutes>; unset: «По паролю» chosen, no password saved yet
-- (0.7.3 mods before it read 3 as none: the password prompt)
local PW_NONE, PW_WRONG, PW_LOCKED, PW_UNSET = 0, 1, 2, 3
M.PW = { none = PW_NONE, wrong = PW_WRONG, locked = PW_LOCKED, unset = PW_UNSET }
local KICK_LOG = { [KICK_LIST] = "not on allowed_players", [KICK_DENIED] = "the host said no",
                   [KICK_TIMEOUT] = "no answer from the host", [KICK_FULL] = "the world is full",
                   [KICK_PASSWORD] = "no or wrong join password" }
local REASON = { [KICK_LIST] = "list", [KICK_DENIED] = "denied", [KICK_TIMEOUT] = "timeout", [KICK_FULL] = "full" }
local PW_REASON = { [PW_NONE] = "pw_none", [PW_WRONG] = "pw_wrong", [PW_LOCKED] = "pw_locked", [PW_UNSET] = "pw_unset" }
local MODES = { open = true, password = true, approve = true, list = true }
local CHEAT_CVARS = { "Debug.Allow", "Debug.NoClip", "Debug.Invincibility", "Debug.HungerStat", "Debug.ThirstStat",
                      "Debug.StaminaStat" }
local CHEAT_COMMANDS = { "god", "fly", "ghost", "teleport", "slomo", "summon" }
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"

-- host
local checked_sid = {}         -- [session key] = the SteamID already checked against the bans
local sent_rules = {}          -- [session key] = the rules string sent to that client
local sent_ff = {}             -- [session key] = the friendly fire rule ("0" / "1") sent to that client
local seen = {}                -- [session key] = { name, sid } its early id said
local recent = {}              -- refused players, newest first: { name, sid, reason, at }
local saving = nil             -- os.time() of a running "save the world now"
local pw_fails = {}            -- [lock key] = { os.time() of each wrong password within PW_WINDOW_S }
local pw_locks = {}            -- [lock key] = os.time() its lock ends (kept across worlds, not on disk)
-- client
local rules = { cheats = true }        -- the host's rules for this client
local saved = {}                       -- [cvar] = this machine's own value before the host switched it off
local refused = {}                     -- [cvar] = true: would not switch off; not tried again in this world
local told_off = false

-- ---------------------------------------------------------------------------
-- Player lists: config banned_players / allowed_players = "<SteamID or
-- name>;..." (an entry may be "<SteamID>:<name>": the name is only shown).
-- An entry with a SteamID matches that SteamID only, one without matches
-- the name (any case).
-- ---------------------------------------------------------------------------

local function parse_list(key)
    local out = {}
    for item in tostring(cfg.get(key) or ""):gmatch("[^;]+") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then
            local sid, name = item:match("^(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d):?(.*)$")
            if sid then
                out[#out + 1] = { sid = sid, name = name ~= "" and name or nil }
            else
                out[#out + 1] = { name = item }
            end
        end
    end
    return out
end

local function save_list(key, list)
    local parts = {}
    for _, b in ipairs(list) do
        if b.sid then
            parts[#parts + 1] = b.sid .. (b.name and (":" .. b.name:gsub("[;:]", " ")) or "")
        elseif b.name then
            parts[#parts + 1] = (b.name:gsub("[;:]", " "))
        end
    end
    cfg.set(key, table.concat(parts, ";"))
    return cfg.save()
end

local function find_in(list, name, sid)
    for i, b in ipairs(list) do
        if sid and b.sid and b.sid == tostring(sid) then return i, "SteamID" end
        if not b.sid and name and b.name and b.name:lower() == tostring(name):lower() then return i, "name" end
    end
    return nil
end

-- An entry's id for the panel's row buttons: its SteamID, else its name.
function M.entry_id(e)
    if type(e) ~= "table" then return "" end
    return e.sid and tostring(e.sid) or ("n:" .. tostring(e.name or ""):lower())
end
local entry_id = M.entry_id

-- Takes the entry `id` off list `key`: the entry, or nil.
local function list_take(key, id)
    local list = parse_list(key)
    for i, b in ipairs(list) do
        if entry_id(b) == id then
            table.remove(list, i)
            return b, save_list(key, list)
        end
    end
    return nil
end

local function parse_bans() return parse_list("banned_players") end
local function save_bans(list) return save_list("banned_players", list) end
M.bans = parse_bans

-- Banned by SteamID, or by name when the ban has no SteamID.
function M.is_banned(name, sid)
    local i, how = find_in(parse_bans(), name, sid)
    if i then return true, how end
    return false
end

-- Names of the banned players, for the panel.
function M.banned_names()
    local out = {}
    for _, b in ipairs(parse_bans()) do out[#out + 1] = b.name or b.sid end
    return out
end

function M.unban_all()
    local n = #parse_bans()
    save_bans({})
    log.info("admin: ban list cleared (%d entr%s)", n, n == 1 and "y" or "ies")
    log.say("admin_unbanned", "ok", 6)
    return n
end

-- The panel: lifts one ban (its entry id). The name, or nil.
function M.unban(id)
    local b, ok = list_take("banned_players", id)
    if not b then return nil end
    local name = tostring(b.name or b.sid)
    log.info("admin: %s (%s) unbanned (saved: %s)", name, b.sid or "by name", tostring(ok))
    log.say("admin_unbanned_one", "info", 6, name)
    return name
end

-- allowed_players
function M.allowed() return parse_list("allowed_players") end

function M.is_allowed(name, sid)
    return find_in(parse_list("allowed_players"), name, sid) ~= nil
end

-- true when added (not when it is on the list already), then saved or not.
local function list_add(name, sid)
    local list = parse_list("allowed_players")
    if find_in(list, name, sid) then return false end
    list[#list + 1] = { sid = sid, name = name }
    return true, save_list("allowed_players", list)
end

-- The panel: a recently refused player goes on allowed_players.
function M.list_add(name, sid)
    if type(name) ~= "string" or name == "" then return false end
    local added, ok = list_add(name, sid)
    if not added then return false end
    log.info("admin: %s (%s) added to allowed_players (saved: %s)", name, sid or "no SteamID: by name", tostring(ok))
    log.say("access_listed", "info", 6, name)
    return true
end

-- The panel's Steam tab: a friend invited through Steam goes on
-- allowed_players by its SteamID ("invite only" lets it in; a listed one
-- stays as it is). One notice: invited, on the list.
function M.invited(name, sid)
    sid = tostring(sid or ""):match("^%d+$") and #tostring(sid) == 17 and tostring(sid) or nil
    if not sid then return false end
    name = (type(name) == "string" and name ~= "") and name or sid
    local added, ok = list_add(name, sid)
    log.info("admin: %s (%s) invited through Steam: %s", name, sid,
        added and string.format("added to allowed_players (saved: %s)", tostring(ok)) or "already on allowed_players")
    log.say("access_invited", "info", 8, name)
    return true
end

-- The panel: takes an entry off allowed_players (its entry id). The name, or nil.
function M.list_remove(id)
    local b, ok = list_take("allowed_players", id)
    if not b then return nil end
    local name = tostring(b.name or b.sid)
    log.info("admin: %s (%s) taken off allowed_players (saved: %s)", name, b.sid or "by name", tostring(ok))
    log.say("access_unlisted", "info", 6, name)
    return name
end

-- ---------------------------------------------------------------------------
-- Join passwords: the host's join_password, the client's host_passwords
-- ---------------------------------------------------------------------------

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A password as both sides compare it: no '|' or control characters (the
-- message channel turns '|' into a space), trimmed, at most PW_MAX_CHARS
-- characters (UTF-8: never half a character).
function M.norm_pw(s)
    s = trim(tostring(s or ""):gsub("[%c|]", " "))
    local n = utf8.len(s)
    if n and n > PW_MAX_CHARS then
        s = trim(s:sub(1, utf8.offset(s, PW_MAX_CHARS + 1) - 1))
    elseif not n and #s > PW_MAX_CHARS then
        s = trim(s:sub(1, PW_MAX_CHARS))
    end
    return s
end

-- Host: the password of join_access "password" ("" = none set yet).
function M.join_password() return M.norm_pw(cfg.get("join_password")) end

-- Host, the World tab's Save: the new password, saved at once. Players
-- already let in stay (they are on the list).
function M.set_join_password(pw)
    pw = M.norm_pw(pw)
    local old = M.join_password()
    cfg.set("join_password", pw)
    local ok = cfg.save()
    log.info("admin: join password %s (saved: %s)", pw == "" and "cleared"
        or (old == "" and "set" or (old == pw and "saved unchanged" or "changed")), tostring(ok))
    log.say(pw == "" and "access_pw_cleared" or "access_pw_set", pw == "" and "warn" or "ok", 6)
    return ok, pw
end

-- Client: passwords kept per join target (config host_passwords =
-- "<target>=<password>;...", the target as sdc_session.join's code:
-- "<ip>:<port>" or "steam:<SteamID>"; '%', ';' and '=' in a password as %XX).
local function pw_esc(s) return (s:gsub("[%%;=]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function pw_unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function target_key(t) return trim(t):lower() end

local function parse_pws()
    local out = {}
    for item in tostring(cfg.get("host_passwords") or ""):gmatch("[^;]+") do
        local t, p = item:match("^([^=]*)=(.*)$")
        if t and trim(t) ~= "" then out[#out + 1] = { t = target_key(t), pw = M.norm_pw(pw_unesc(p)) } end
    end
    return out
end

-- The password kept for join target `target`, or "".
function M.saved_pw(target)
    local k = target_key(target)
    if k == "" then return "" end
    for _, e in ipairs(parse_pws()) do
        if e.t == k then return e.pw end
    end
    return ""
end

-- Keeps the password for `target` (an empty one: forgets it); saved at once.
function M.save_pw(target, pw)
    local k = target_key(target)
    if k == "" then return false end
    pw = M.norm_pw(pw)
    local out = {}
    for _, e in ipairs(parse_pws()) do
        if e.t ~= k and e.pw ~= "" then out[#out + 1] = e end
    end
    if pw ~= "" then out[#out + 1] = { t = k, pw = pw } end
    while #out > PW_KEEP do table.remove(out, 1) end
    local parts = {}
    for _, e in ipairs(out) do parts[#parts + 1] = e.t .. "=" .. pw_esc(e.pw) end
    cfg.set("host_passwords", table.concat(parts, ";"))
    local ok = cfg.save()
    log.info("admin: join password for %s %s (saved: %s)", k, pw == "" and "forgotten" or "kept", tostring(ok))
    return ok
end

-- The join target of `ip` / `port` as sdc_session.join names it (a friend's
-- Steam code -> "steam:<SteamID>"), lower case.
function M.pw_target(ip, port)
    ip = trim(ip)
    if ip == "" then return "" end
    local steam = package.loaded["sdc_steam"]
    local okc, sid = pcall(function() return type(steam) == "table" and steam.code_of and steam.code_of(ip) or nil end)
    if okc and sid then return "steam:" .. tostring(sid) end
    return target_key(string.format("%s:%d", ip, math.floor(tonumber(port) or 7777)))
end

-- "open" | "password" | "approve" | "list" (config join_access; anything else is open).
function M.access_mode()
    local v = tostring(cfg.get("join_access") or "open"):lower():gsub("%s+", "")
    return MODES[v] and v or "open"
end

-- config max_players: the most players in the world, the host included; 0 = no limit.
function M.max_players()
    local n = tonumber(cfg.get("max_players")) or 0
    return n > 0 and math.floor(n) or 0
end

local function sid_of(key)
    local ps = package.loaded["sdc_persist"]
    local ok, sid = pcall(function() return ps and ps.steam_of and ps.steam_of(key) or nil end)
    return ok and sid or nil
end

-- The SteamID of session key `key`: sdc_persist's, else its early id's.
local function known_sid(key)
    local sid = sid_of(key)
    if sid then return sid end
    local id = seen[key]
    return id and id.sid or nil
end

-- ---------------------------------------------------------------------------
-- Kick (host)
-- ---------------------------------------------------------------------------

-- The kicked player's controller, re-read from its session record (nothing
-- is kept across the delays but the key); nil once it has left.
local function kicked_pc(key)
    local r = S and S.remote and S.remote[key]
    if not r or not r.kicked or not ue.valid(r.pc) then return nil end
    return r.pc, tostring(r.name or "?"), r
end

local function force_out(key, step)
    local pc, name, r = kicked_pc(key)
    if not pc then return end
    if step == 1 then
        local why = (r.kick_code or KICK_KICK) >= KICK_LIST and "Not let in by the host" or "Kicked by the host"
        local ok, err = pcall(function() pc:ClientReturnToMainMenuWithTextReason(FText(why)) end)
        log.warn("admin: %s still connected %d s after the kick: the engine's return to the menu (ok=%s%s)", name,
            FALLBACK_MS // 1000, tostring(ok), ok and "" or (" " .. tostring(err)))
        ue.delay("admin-kick-destroy", DESTROY_MS - FALLBACK_MS, function() force_out(key, 2) end)
        return
    end
    local pawn = ue.pawn_of(pc)
    local okp = pawn and pcall(function() pawn:K2_DestroyActor() end)
    local okc = pcall(function() pc:K2_DestroyActor() end)
    log.warn("admin: %s still connected %d s after the kick: character and controller destroyed (%s, %s)", name,
        DESTROY_MS // 1000, tostring(okp), tostring(okc))
end

-- Host: removes the player of session key `key` from the world; ban = also
-- keeps them out (why "ban list": already banned, the list stays as it is).
-- Returns true when there was such a player. A new ban needs the player's
-- hello (its name and SteamID): a "connecting" player can only be kicked.
-- `who`: the name to show (the early id's, before the hello). `code`: a
-- refusal at the door (KICK_LIST..KICK_PASSWORD; refuse below says it);
-- `sub`, `mins`: KICK|6's two more fields.
function M.kick(key, ban, why, who, code, sub, mins)
    if not S or S.role ~= "host" then return false end
    local r = S.remote and S.remote[key]
    if not r or not ue.valid(r.pc) then return false end
    if r.kicked then return false end   -- already on its way out
    if ban and not r.hello and why ~= "ban list" then
        log.info("admin: ban of %s (%s) refused: no hello yet (no name / SteamID to ban); kick it instead",
            tostring(r.name or "?"), key)
        return false
    end
    code = code or (ban and KICK_BAN or KICK_KICK)
    local name, pc = tostring(who or r.name or "?"), r.pc
    local sid = sid_of(key)
    if ban and why ~= "ban list" then
        local list = parse_bans()
        local dup = false
        for _, b in ipairs(list) do
            if (sid and b.sid == sid) or (not sid and not b.sid and b.name == name) then dup = true end
        end
        if not dup then list[#list + 1] = { sid = sid, name = name } end
        local saved_ok = save_bans(list)
        log.info("admin: %s (%s) banned by %s (saved: %s)", name, sid or "no SteamID: by name", why or "the host",
            tostring(saved_ok))
    end
    r.kicked, r.kick_code = os.time(), code
    if sub ~= nil then
        net.send_to(pc, "KICK", tostring(code), tostring(sub), tostring(mins or 0))
    else
        net.send_to(pc, "KICK", tostring(code))
    end
    if code > KICK_BAN then
        -- a refusal at the door: the others never saw this player join
        log.info("admin: %s (%s): KICK|%d (not let in: %s)", name, key, code, KICK_LOG[code] or "?")
    else
        log.info("admin: %s (%s) kicked%s by %s", name, key, ban and " and banned" or "", why or "the host")
        if why ~= "ban list" then log.say(ban and "admin_ban_done" or "admin_kick_done", "info", 6, name) end
        local others = {}
        for _, other in ipairs(S.remote_pcs or {}) do
            if other ~= pc then others[#others + 1] = other end
        end
        if #others > 0 then net.broadcast(others, "MSG", "admin_player_kicked", name) end
    end
    ue.delay("admin-kick-fallback", FALLBACK_MS, function() force_out(key, 1) end)
    return true
end

local function check_ban(r, sid, when)
    if r.kicked then return end
    local banned, how = M.is_banned(r.name, sid)
    if not banned then return end
    log.info("admin: %s is banned (%s, at %s): kicked", tostring(r.name), how, when)
    log.say("admin_banned_join", "warn", 8, tostring(r.name))
    M.kick(r.key, true, "ban list")   -- KICK|1: the player is told it is banned
end

-- ---------------------------------------------------------------------------
-- Access (host): join_access, allowed_players, max_players
-- ---------------------------------------------------------------------------
-- Per session record: r.access nil (not decided yet) | "ok" | "wait" (the
-- host's answer) | "pw" (its password) | "refused"; r.access_since
-- (waiting since), r.pw_sent_at (ACCESS|pw last sent), r.access_name / r.access_sid
-- (who it said it is), r.access_ok_at (let in after waiting: sdc_persist's
-- id gate counts from then), r.access_hello_at (a hello whose SteamID may
-- still come).

-- Is session record `r` (key `key`) the player `name` / `sid`? By SteamID
-- when either side has one, else by name (any case).
local function same_player(key, r, sid, name)
    local other = known_sid(key) or r.access_sid
    if sid or other then return sid ~= nil and other ~= nil and tostring(other) == tostring(sid) end
    local n = r.access_name or r.name
    return name ~= nil and n ~= nil and tostring(n):lower() == tostring(name):lower()
end

-- Players in this world or waiting to come in, besides session key
-- `except`, anyone on the way out and an earlier connection of the joining
-- player `sid` / `name` (back after a crash before the engine dropped the
-- old one: it must not count against itself). Also returns that record.
local function players_in(except, sid, name)
    local n, stale = 0, nil
    for key, r in pairs(S and S.remote or {}) do
        if key ~= except and not r.kicked and r.access ~= "refused"
            and (r.access == "ok" or r.access == "wait" or r.access == "pw" or r.hello or r.spawned_once) then
            if same_player(key, r, sid, name) then stale = r else n = n + 1 end
        end
    end
    return n, stale
end

-- A refused player, for the panel's "recently turned away" (newest first).
local function remember(r, name, sid, reason)
    local id = entry_id({ sid = sid, name = name })
    for i = #recent, 1, -1 do
        if entry_id(recent[i]) == id then table.remove(recent, i) end
    end
    -- guess: refused before it said who it is (its placeholder name): not for the list
    table.insert(recent, 1, { name = name, sid = sid, reason = reason, at = os.time(), guess = r.access_guess })
    while #recent > RECENT_MAX do table.remove(recent) end
end

-- Not let in (KICK|code): remembered for the panel, the host told in one
-- line, the client sent away as by a kick. `when`: what decided it (log).
local function refuse(r, code, name, sid, when, n, max)
    r.access = "refused"
    remember(r, name, sid, REASON[code])
    local who = string.format("%s (%s)", name, sid or "no SteamID")
    if code == KICK_FULL then
        log.info("admin: the world is full (%d of max_players %d, the host included): %s not let in (%s)", n, max, who, when)
        log.say("access_full", "info", 8, n, max, name)
    elseif code == KICK_LIST then
        log.info("admin: %s is not on allowed_players (join_access list): not let in (%s)", who, when)
        log.say("access_not_listed", "info", 8, name)
    elseif code == KICK_TIMEOUT then
        log.warn("admin: %s waited %d s without an answer from the host: not let in", who, ACCESS_WAIT_S)
        log.say("access_timeout", "warn", 8, name)
    else
        log.info("admin: %s not let in by the host (%s)", who, when)
        log.say("access_denied", "info", 6, name)
    end
    M.kick(r.key, false, "access", name, code)
end

-- A waiting player goes in: ACCESS|ok, its first character may spawn.
local function admit(r, why)
    local now = os.time()
    local waited = now - (r.access_since or now)
    -- decided without its id (ID_WAIT_S): the id gate had its time already
    r.access, r.access_ok_at, r.access_since = "ok", not r.access_guess and now or nil, nil
    r.pw_sent_at = nil
    if ue.valid(r.pc) then net.send_to(r.pc, "ACCESS", "ok") end
    log.info("admin: %s (%s) let in after %d s of waiting (%s)", tostring(r.access_name or r.name),
        r.access_sid or "no SteamID", waited, why)
end

-- approve: the host decides (ACCESS|wait, one notice). true = held.
local function ask_host(r, name, sid, when)
    r.access, r.access_since, r.access_name, r.access_sid = "wait", os.time(), name, sid
    r.pw_sent_at = nil
    if not r.hello then r.name = name end   -- the panel's player list says who it is
    net.send_to(r.pc, "ACCESS", "wait")
    log.info("admin: %s (%s) asks to join (join_access approve, not on allowed_players; %s): %s", name,
        sid or "no SteamID", when, r.spawned_once and "its character is already in the world"
            or "its first character waits for the host's answer")
    log.say("access_ask", "info", 15, name, tostring(cfg.get("menu_key") or "F7"))
    return not r.spawned_once
end

-- The network address of a player's connection (no port), when the engine
-- gives a real one: not loopback (a Steam friend comes through the helper's
-- 127.0.0.1, a local tunnel agent too), nothing that is not an address.
local function addr_of(pc)
    local ok, v = pcall(function() return pc:GetPlayerNetworkAddress() end)
    if not ok or v == nil then return nil end
    local s = type(v) == "string" and v or ""
    if s == "" and type(ue.str) == "function" then
        local oks, t = pcall(ue.str, v)
        s = oks and type(t) == "string" and t or ""
    end
    s = s:lower():gsub("%s+", "")
    local host = s:match("^%[([%x:%.]+)%]") or s:match("^(%d+%.%d+%.%d+%.%d+):%d+$") or s
    if host:match("^%d+%.%d+%.%d+%.%d+$") then
        if host:find("^127%.") or host == "0.0.0.0" then return nil end
        return host
    end
    local _, colons = host:gsub(":", "")
    if colons >= 2 and host:match("^[%x:%.]+$") then
        if host == "::1" or host:find("^::ffff:127%.") or host:match("^[0:]+$") then return nil end
        return host
    end
    return nil
end

-- The keys a wrong password counts on: the connection's real network
-- address only. Never the SteamID or name the client claims: anyone could
-- lock a friend out with them or dodge the limit by changing them. No
-- address (a Steam friend, a local tunnel): {} - not counted; each try
-- costs the joiner a world load.
local function pw_keys(r)
    local a = addr_of(r.pc)
    return a and { "a:" .. a } or {}
end

-- Minutes left of a lock on any of `keys`, or nil.
local function pw_locked(keys, now)
    local left = 0
    for _, k in ipairs(keys) do
        local u = pw_locks[k]
        if u and u > now then
            left = math.max(left, u - now)
        elseif u then
            pw_locks[k] = nil
        end
    end
    return left > 0 and math.max(1, math.ceil(left / 60)) or nil
end

-- A wrong password, counted on each key: the most wrong ones on one key
-- within PW_WINDOW_S (this one included), and whether a key got locked.
local function pw_count(keys, now)
    local most, locked = 1, false
    for _, k in ipairs(keys) do
        local list = {}
        for _, t in ipairs(pw_fails[k] or {}) do
            if now - t < PW_WINDOW_S then list[#list + 1] = t end
        end
        list[#list + 1] = now
        most = math.max(most, #list)
        if #list >= PW_TRIES then
            pw_locks[k], pw_fails[k], locked = now + PW_LOCK_S, nil, true
        else
            pw_fails[k] = list
        end
    end
    return most, locked
end

-- Not let in for its password: KICK|6|<sub>|<minutes>, the host's notice
-- `say` (with its arguments), remembered for the panel.
local function refuse_pw(r, sub, name, sid, when, mins, say, ...)
    r.access, r.pw_sent_at = "refused", nil
    remember(r, name, sid, PW_REASON[sub])
    log.info("admin: %s (%s) not let in (join_access password): %s", name, sid or "no SteamID", when)
    if say then log.say(say, (sub == PW_NONE or sub == PW_UNSET) and "info" or "warn", 8, ...) end
    M.kick(r.key, false, "access", name, KICK_PASSWORD, sub, mins or 0)
end

-- password: ACCESS|pw to the player (its mod answers JPW). true = held.
local function ask_password(r, name, sid, when)
    local now = os.time()
    r.access_name, r.access_sid = name, sid
    if not r.hello then r.name = name end
    if M.join_password() == "" then
        -- KICK|6|3: the joiner is told the host has to set one (no prompt:
        -- any password it typed would be refused the same way)
        refuse_pw(r, PW_UNSET, name, sid, "no join password is set yet (the World tab)", 0, "access_pw_unset", name)
        return true
    end
    local mins = pw_locked(pw_keys(r), now)
    if mins then
        refuse_pw(r, PW_LOCKED, name, sid, string.format("too many wrong passwords: locked for %d more min", mins),
            mins, "access_pw_locked", name, mins)
        return true
    end
    r.access, r.access_since, r.pw_sent_at = "pw", now, now
    net.send_to(r.pc, "ACCESS", "pw")
    log.info("admin: %s (%s) is not on allowed_players (join_access password; %s): asked for the join password; %s",
        name, sid or "no SteamID", when, r.spawned_once and "its character is already in the world"
            or "its first character waits for the answer")
    return not r.spawned_once
end

-- The access of a player, decided once. true = on its way out, or held
-- (waiting with no character yet); false = in (or waiting while its
-- character is already in the world: nothing to hold).
local function decide(r, name, sid, when)
    if r.kicked or r.access == "refused" then return true end
    if r.access == "ok" then return false end
    if r.access == "wait" or r.access == "pw" then
        -- waiting since ID_WAIT_S without its id: now it says who it is
        if r.access_guess and (sid or name ~= r.access_name) then
            r.access_guess = nil
            r.access_name, r.access_sid = name, sid
            if not r.hello then r.name = name end
            log.info("admin: the waiting %s said who it is (%s, %s)", name, sid or "no SteamID", when)
            if M.is_allowed(name, sid) then
                admit(r, "on allowed_players: its id came while it waited")
                return false
            end
        end
        return not r.spawned_once
    end
    r.access_hello_at = nil
    local max = M.max_players()
    local n = 0
    if max > 0 then
        local others, stale = players_in(r.key, sid, name)
        n = 1 + others
        if stale then
            log.info("admin: %s: its earlier connection %s is still open (not dropped by the engine yet): "
                .. "not counted against max_players", name, tostring(stale.key))
        end
        if n >= max then
            refuse(r, KICK_FULL, name, sid, when, n, max)
            return true
        end
    end
    local mode = M.access_mode()
    if mode == "open" then
        r.access = "ok"
        if max > 0 then log.info("admin: %s let in (%d of max_players %d with it; %s)", name, n + 1, max, when) end
        return false
    end
    if M.is_allowed(name, sid) then
        r.access = "ok"
        log.info("admin: %s (%s) is on allowed_players: let in (join_access %s; %s)", name, sid or "no SteamID", mode, when)
        return false
    end
    if mode == "list" then
        refuse(r, KICK_LIST, name, sid, when)
        return true
    end
    if mode == "password" then return ask_password(r, name, sid, when) end
    -- approve: the host decides
    return ask_host(r, name, sid, when)
end

-- 1 s and after a change: answers that came by themselves (the mode or the
-- list changed), the waits that ran out, hellos whose SteamID was awaited.
local function access_tick(now)
    local mode = M.access_mode()
    for key, r in pairs(S.remote or {}) do
        if not r.kicked and ue.valid(r.pc) then
            if r.access == "wait" then
                local name, sid = tostring(r.access_name or r.name or "?"), r.access_sid
                if mode == "open" then
                    admit(r, "join_access is open now")
                elseif M.is_allowed(name, sid) then
                    admit(r, "on allowed_players now")
                elseif mode == "list" then
                    refuse(r, KICK_LIST, name, sid, "join_access switched to list")
                elseif mode == "password" then
                    ask_password(r, name, sid, "join_access switched to password")
                elseif now - (r.access_since or now) >= ACCESS_WAIT_S then
                    refuse(r, KICK_TIMEOUT, name, sid, "no answer")
                end
            elseif r.access == "pw" then
                local name, sid = tostring(r.access_name or r.name or "?"), r.access_sid
                if mode == "open" then
                    admit(r, "join_access is open now")
                elseif M.is_allowed(name, sid) then
                    admit(r, "on allowed_players now")
                elseif mode == "list" then
                    refuse(r, KICK_LIST, name, sid, "join_access switched to list")
                elseif mode == "approve" then
                    ask_host(r, name, sid, "join_access switched to approve")
                elseif now - (r.access_since or now) >= PW_WAIT_S then
                    log.warn("admin: %s: no answer to the password request in %d s (an older mod?)", name, PW_WAIT_S)
                    refuse_pw(r, PW_NONE, name, sid, string.format("no answer in %d s", PW_WAIT_S), 0,
                        "access_pw_none", name)
                elseif now - (r.pw_sent_at or 0) >= PW_ASK_EVERY_S then
                    r.pw_sent_at = now
                    net.send_to(r.pc, "ACCESS", "pw")
                end
            elseif r.access == nil and r.access_hello_at then
                local sid = known_sid(key)
                if sid or now - r.access_hello_at >= SID_WAIT_S then
                    decide(r, tostring(r.name or "?"), sid, sid and "hello, then its SteamID" or "hello, no SteamID")
                end
            end
        end
    end
    for key in pairs(seen) do
        if not (S.remote or {})[key] then seen[key] = nil end
    end
end

-- The panel: the mode, saved at once; the waiting players follow it.
function M.set_access_mode(v)
    v = tostring(v or ""):lower()
    if not MODES[v] then return false end
    local old = M.access_mode()
    cfg.set("join_access", v)
    local ok = cfg.save()
    log.info("admin: join_access %s -> %s (saved: %s)", old, v, tostring(ok))
    if S and S.role == "host" and old ~= v then access_tick(os.time()) end
    return true
end

-- Players waiting for the host's answer, the longest first:
-- { { key, name, sid, since, secs } }.
function M.waiting()
    local out = {}
    if not S or S.role ~= "host" then return out end
    local now = os.time()
    for key, r in pairs(S.remote or {}) do
        if r.access == "wait" and not r.kicked then
            local since = r.access_since or now
            out[#out + 1] = { key = key, name = tostring(r.access_name or r.name or "?"), sid = r.access_sid,
                              since = since, secs = math.max(0, now - since), index = r.index or 0 }
        end
    end
    table.sort(out, function(a, b)
        if a.since ~= b.since then return a.since < b.since end
        return a.index < b.index
    end)
    return out
end

-- Recently refused players, newest first: { { name, sid, reason, at } };
-- reason "list" | "denied" | "timeout" | "full" | "pw_none" | "pw_wrong" | "pw_locked".
function M.recent()
    local out = {}
    for i, e in ipairs(recent) do out[i] = { name = e.name, sid = e.sid, reason = e.reason, at = e.at, guess = e.guess } end
    return out
end

-- The panel's Allow: the waiting player goes in and on allowed_players.
function M.allow(key)
    if not S or S.role ~= "host" then return false end
    local r = S.remote and S.remote[key]
    if not r or r.kicked or r.access ~= "wait" then return false end
    local name, sid = tostring(r.access_name or r.name or "?"), r.access_sid or known_sid(key)
    -- no id yet (its placeholder name): let in, not put on the list
    local added, ok = false, nil
    if not r.access_guess or sid then added, ok = list_add(name, sid) end
    admit(r, added and string.format("the host let it in; added to allowed_players, saved: %s", tostring(ok))
        or "the host let it in")
    log.say(r.access_guess and not sid and "access_allowed_once" or "access_allowed", "info", 6, name)
    return true
end

-- The panel's Deny: KICK|3 (it can ask again).
function M.deny(key)
    if not S or S.role ~= "host" then return false end
    local r = S.remote and S.remote[key]
    if not r or r.kicked or r.access ~= "wait" then return false end
    local waited = os.time() - (r.access_since or os.time())
    refuse(r, KICK_DENIED, tostring(r.access_name or r.name or "?"), r.access_sid,
        string.format("the host said no after %d s", waited))
    return true
end

-- Host, JPW|<password> (the client's answer to ACCESS|pw): only while it is
-- asked. Right: on allowed_players (unless it never said who it is) and in.
local function on_password(f, pc)
    if not S or S.role ~= "host" then return end
    local r
    for _, rec in pairs(S.remote or {}) do
        if rec.pc == pc then r = rec break end
    end
    if not r or r.kicked or r.access ~= "pw" then
        log.info("admin: a join password from %s that was not asked for now: ignored",
            r and tostring(r.access_name or r.name) or "an unknown connection")
        return
    end
    local name, sid, now = tostring(r.access_name or r.name or "?"), r.access_sid, os.time()
    local want = M.join_password()
    if want == "" then
        refuse_pw(r, PW_UNSET, name, sid, "no join password is set any more (the World tab)", 0, "access_pw_unset", name)
        return
    end
    local keys = pw_keys(r)
    local mins = pw_locked(keys, now)
    if mins then
        refuse_pw(r, PW_LOCKED, name, sid, string.format("too many wrong passwords: locked for %d more min", mins),
            mins, "access_pw_locked", name, mins)
        return
    end
    local got = M.norm_pw(f[1])
    if got == "" then
        refuse_pw(r, PW_NONE, name, sid, "it has no password for this host", 0, "access_pw_none", name)
        return
    end
    if got ~= want then
        if #keys == 0 then
            refuse_pw(r, PW_WRONG, name, sid, "a wrong password (no network address: not counted)", 0,
                "access_pw_wrong_nc", name)
            return
        end
        local n, locked = pw_count(keys, now)
        if locked then
            refuse_pw(r, PW_LOCKED, name, sid, string.format("a wrong password, %d within %d min: locked for %d min",
                n, PW_WINDOW_S // 60, PW_LOCK_S // 60), PW_LOCK_S // 60, "access_pw_locked", name, PW_LOCK_S // 60)
        else
            refuse_pw(r, PW_WRONG, name, sid, string.format("a wrong password (%d of %d within %d min)", n, PW_TRIES,
                PW_WINDOW_S // 60), 0, "access_pw_wrong", name, n, PW_TRIES)
        end
        return
    end
    for _, k in ipairs(keys) do pw_fails[k] = nil end
    -- never said who it is (its placeholder name): let in, not put on the list
    local added, ok = false, nil
    if not r.access_guess or sid then added, ok = list_add(name, sid) end
    admit(r, added and string.format("the right password; added to allowed_players, saved: %s", tostring(ok))
        or "the right password")
    log.say("access_pw_ok", "info", 6, name)
end

-- sdc_players: may the player's first character spawn? Not while the host
-- has not let it in (its answer or its password awaited), nor once it was
-- refused or kicked. With password / approve / list
-- not while undecided either: its id is awaited ID_WAIT_S from the
-- connection, then the host decides by what it knows (approve: it waits for
-- the host's answer; password: asked; list: refused).
function M.access_gate(r, now)
    if type(r) ~= "table" or not S or S.role ~= "host" then return true end
    if r.kicked then return false end
    if r.access == nil and M.access_mode() ~= "open" then
        now = now or os.time()
        if now - (r.joined_at or now) < ID_WAIT_S then return false end
        r.access_guess = true
        decide(r, tostring(r.name or "?"), known_sid(r.key), string.format("no id within %d s", ID_WAIT_S))
    end
    return r.access ~= "wait" and r.access ~= "pw" and r.access ~= "refused" and not r.kicked
end

-- Host, sdc_persist's PSID (the client's early id: in the host's world, no
-- character yet, before its hello): a banned player is refused as soon as
-- it says who it is, then the access is decided. true = this player is on
-- its way out, or waits for the host (no verdict for it yet: its client
-- repeats the id).
function M.on_early_id(r, name, sid)
    if not r or not S or S.role ~= "host" then return false end
    if r.kicked then return true end
    seen[r.key] = { name = name, sid = sid }
    local banned, how = M.is_banned(name, sid)
    if banned then
        log.info("admin: %s is banned (%s, at its early id): kicked before it gets a character", tostring(name), how)
        log.say("admin_banned_join", "warn", 8, tostring(name))
        M.kick(r.key, true, "ban list", name)
        return r.kicked ~= nil
    end
    return decide(r, tostring(name or r.name or "?"), sid, "early id")
end

-- Host, sdc_session's HI handler: the player said hello. true = this
-- player is on its way out (banned now, refused, or kicked before): no join
-- announcements.
function M.on_hello(r)
    if not r or not S or S.role ~= "host" then return false end
    local sid = known_sid(r.key)
    check_ban(r, sid, "hello")
    sent_rules[r.key], sent_ff[r.key] = nil, nil   -- (re)send the rules to this client
    -- no early id (an older mod, persist_early_id off): decided now; a list
    -- to check and no SteamID yet: once it comes (or SID_WAIT_S, access_tick)
    if not r.kicked and r.access == nil then
        if sid or M.access_mode() == "open" then
            decide(r, tostring(r.name or "?"), sid, "hello")
        else
            r.access_hello_at = r.access_hello_at or os.time()
        end
    end
    return r.kicked ~= nil
end

-- The panel's "Save the world now": the game's own save of the current slot
-- (sdc_savecheck.save_now, as opening a world for friends uses it). false
-- when it did not start.
function M.save_world()
    if not S or S.role ~= "host" then return false end
    if saving and os.time() - saving < 60 then return false end
    -- somebody is down (sdc_down): its state is not in the game's save
    local dn = package.loaded["sdc_down"]
    if type(dn) == "table" and type(dn.any_down) == "function" and dn.any_down() == true then
        log.info("admin: save the world now refused: somebody is down (knockdown)")
        log.say("down_save_refused", "warn", 6)
        return false
    end
    local sc = package.loaded["sdc_savecheck"]
    if type(sc) ~= "table" or type(sc.save_now) ~= "function" then
        log.warn("admin: save the world now: no sdc_savecheck")
        log.say("world_save_failed", "warn", 8)
        return false
    end
    saving = os.time()
    log.info("admin: save the world now (the co-op panel)")
    local ok, err = pcall(sc.save_now, "the co-op panel's Save the world now", function(done)
        saving = nil
        log.say(done and "world_saved" or "world_save_failed", done and "ok" or "warn", 8)
    end)
    if not ok then
        saving = nil
        log.warn("admin: save the world now: %s", tostring(err))
        log.say("world_save_failed", "warn", 8)
        return false
    end
    return true
end

function M.saving() return saving ~= nil end

-- ---------------------------------------------------------------------------
-- Cheats (client keeps the host's rules)
-- ---------------------------------------------------------------------------

local function get_cvar(name)
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu then
        local ok, v = pcall(function() return cu:GetBoolCVar(FName(name)) end)
        if ok and type(v) == "boolean" then return v end
    end
    local ksl = ue.ksl()
    if ksl then
        local ok, v = pcall(function() return ksl:GetConsoleVariableBoolValue(name) end)
        if ok and type(v) == "boolean" then return v end
    end
    return nil
end

local function set_cvar(name, on)
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu and pcall(function() cu:SetBoolCVar(FName(name), on) end) and get_cvar(name) == on then return true end
    ue.exec(name .. " " .. (on and "1" or "0"))
    return get_cvar(name) == on
end

local function close_debug_menu()
    local pawn = ue.local_pawn()
    local dm = pawn and ue.prop(pawn, "DebugMenu")
    if ue.valid(dm) then
        local ok = pcall(function() pawn:CloseDebugMenu() end)
        log.info("admin: the game's debug menu closed (the host does not allow cheats; ok=%s)", tostring(ok))
    end
end

local function enforce_rules()
    if rules.cheats then return end
    local changed = {}
    for _, name in ipairs(CHEAT_CVARS) do
        if not refused[name] and get_cvar(name) == true then
            if saved[name] == nil then saved[name] = true end
            local ok = set_cvar(name, false)
            -- a variable this build will not switch off: said once, not tried every second
            if not ok then refused[name] = true end
            changed[#changed + 1] = name .. (ok and "" or " (FAILED: not tried again in this world)")
        end
    end
    if #changed > 0 then
        log.info("admin: cheats off by the host: %s -> 0 (own values come back on leaving)", table.concat(changed, ", "))
        close_debug_menu()
    end
end

local function restore_own(why)
    for name, v in pairs(saved) do
        local ok = set_cvar(name, v)
        log.info("admin: %s back to this machine's own value %s (%s, ok=%s)", name, v and "1" or "0", why, tostring(ok))
    end
    saved, refused = {}, {}
    rules = { cheats = true }
    told_off = false
end

-- Console cheat commands (an engine console on a client): refused while the
-- host's rules say no cheats. Elsewhere (and on the host) they go on. A
-- shipping client has no CheatManager and the game never calls EnableCheats,
-- so these do nothing there; they are kept on purpose for a client that
-- installs a CheatManager enabler (cheap: six console handlers).
local function install_command_guards()
    for _, cmd in ipairs(CHEAT_COMMANDS) do
        pcall(RegisterConsoleCommandHandler, cmd, function(_, _, out)
            if S and S.role == "client" and not rules.cheats then
                if out and out.Log then pcall(function() out:Log("[SDCoop] The host does not allow cheats in this world.\n") end) end
                log.info("admin: console '%s' refused (the host does not allow cheats)", cmd)
                return true
            end
            return false
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Ticks, handlers
-- ---------------------------------------------------------------------------

local function rules_string()
    return cfg.get("client_cheats") == false and "0" or "1"
end

local function host_tick()
    local want = rules_string()
    local want_ff = cfg.get("friendly_fire") == true and "1" or "0"
    for key, r in pairs(S.remote or {}) do
        if r.hello and ue.valid(r.pc) and not r.kicked then
            if sent_rules[key] ~= want then
                sent_rules[key] = want
                net.send_to(r.pc, "RULES", "cheats", want)
                log.info("admin: rules to %s: cheats %s", tostring(r.name), want == "1" and "allowed" or "OFF")
            end
            -- friendly fire: only to a player the host let in (its notice
            -- would land on its join cover while it waits)
            if r.access == "ok" and sent_ff[key] ~= want_ff then
                sent_ff[key] = want_ff
                net.send_to(r.pc, "RULES", "ff", want_ff)
                log.info("admin: rules to %s: friendly fire %s", tostring(r.name), want_ff == "1" and "ON" or "off")
            end
            local sid = sid_of(key)
            if sid and checked_sid[key] ~= sid then
                checked_sid[key] = sid
                check_ban(r, sid, "SteamID")
            end
        end
    end
    for key in pairs(sent_rules) do
        if not (S.remote or {})[key] then sent_rules[key], checked_sid[key] = nil, nil end
    end
    for key in pairs(sent_ff) do
        if not (S.remote or {})[key] then sent_ff[key] = nil end
    end
end

-- 1 s (main.lua).
function M.tick()
    if not S then return end
    if S.role == "host" then
        host_tick()
        access_tick(os.time())
        return
    end
    if #recent > 0 or next(seen) then recent, seen = {}, {} end
    if S.role == "client" then
        enforce_rules()
    elseif next(saved) or not rules.cheats then
        restore_own("left the host's world")
    end
end

-- The joining player's words for a KICK code (an unknown, newer code: a kick).
local KICK_SAY = { [KICK_KICK] = "admin_kicked_you", [KICK_BAN] = "admin_banned_you", [KICK_LIST] = "access_list_you",
                   [KICK_DENIED] = "access_denied_you", [KICK_TIMEOUT] = "access_timeout_you",
                   [KICK_FULL] = "access_full_you", [KICK_PASSWORD] = "access_pw_need_you" }
local KICK_WHY = { [KICK_KICK] = "kicked by the host", [KICK_BAN] = "banned by the host",
                   [KICK_LIST] = "not on the host's list", [KICK_DENIED] = "the host did not let it in",
                   [KICK_TIMEOUT] = "no answer from the host", [KICK_FULL] = "the host's world is full",
                   [KICK_PASSWORD] = "no or wrong join password" }
-- KICK|6|<sub>: the joining player's words (the join cover asks for the
-- password; not for locked / unset). An unknown, newer sub-code: none.
local PW_SAY = { [PW_NONE] = "access_pw_need_you", [PW_WRONG] = "access_pw_wrong_you", [PW_LOCKED] = "access_pw_locked_you",
                 [PW_UNSET] = "access_pw_unset_you" }
local PW_WHY = { [PW_NONE] = "the host asks for a password and none is kept for it", [PW_WRONG] = "a wrong password",
                 [PW_LOCKED] = "too many wrong passwords", [PW_UNSET] = "the host has not set a join password yet" }

-- Client: the join this connection came from (sdc_session's code as asked:
-- "<ip>:<port>" or "steam:<SteamID>"), or nil: none recorded (a console
-- "open" before any join from this game; or after one: sdc_session's
-- bind_join forgets a join's address when a connection begins long after it
-- or after its own connection) - never the IP tab's address, the
-- connection may well be another host's.
local function join_target()
    local j = S and S.join
    local t = type(j) == "table" and (j.code or j.target) or nil
    if type(t) == "string" and t ~= "" then return t end
    return nil
end

-- Client, ACCESS|pw: the password kept for this join (or none: an empty
-- answer, the host says no and the join cover asks for it). Never logged.
local function answer_password(cs)
    local target = join_target()
    local pw = target and M.saved_pw(target) or ""
    net.send_to_host("JPW", pw)
    if type(cs) == "table" then
        cs.pw_asked = (cs.pw_asked or 0) + 1
        if cs.pw_asked > 1 then return end
    end
    log.info("admin: the host asks for its join password: %s", not target and "no join target known: an empty answer"
        or (pw ~= "" and string.format("sent the one kept for %s", target)
            or string.format("none kept for %s: an empty answer", target)))
end

function M.install(state)
    S = state
    install_command_guards()
    -- the first character of a player the host has not let in waits
    local pl = package.loaded["sdc_players"]
    if type(pl) == "table" then pl.access_gate = M.access_gate end
    -- client -> host: JPW|<password> (the answer to ACCESS|pw)
    net.on("JPW", on_password)
    -- host -> client: KICK|<code> (0 kick, 1 ban, 2..6 not let in; 6: |<sub>|<minutes>)
    net.on("KICK", function(f)
        if not S or S.role ~= "client" then return end
        local code = tonumber(f[1])
        if not code or not KICK_SAY[code] then code = KICK_KICK end
        local key, args, why = KICK_SAY[code], {}, KICK_WHY[code]
        if code == KICK_PASSWORD then
            local sub = tonumber(f[2])
            if not PW_SAY[sub] then sub = PW_NONE end
            key, why = PW_SAY[sub], PW_WHY[sub]
            if sub == PW_LOCKED then args[1] = math.max(1, math.floor(tonumber(f[3]) or PW_LOCK_S // 60)) end
        end
        if code > KICK_BAN then
            log.warn("admin: the host did not let this player in: %s (KICK|%d%s)", why, code,
                code == KICK_PASSWORD and ("|" .. tostring(f[2] or "?")) or "")
        else
            log.warn("admin: the host %s this player", code == KICK_BAN and "banned" or "kicked")
        end
        log.say(key, "warn", 12, table.unpack(args))
        -- the automatic join (auto_join) must not walk straight back in
        local sess = package.loaded["sdc_session"]
        if type(sess) == "table" and type(sess.stop_auto_join) == "function" then
            pcall(sess.stop_auto_join, why)
        end
        S.disconnect_requested = true
        ue.exec("disconnect")
    end)
    -- host -> client: ACCESS|wait (the host has to let this player in) | ACCESS|ok
    -- | ACCESS|pw (its join password: answered every time it is asked)
    net.on("ACCESS", function(f)
        if not S or S.role ~= "client" then return end
        local cs = S.client
        if f[1] == "pw" then return answer_password(cs) end
        local v = (f[1] == "wait" or f[1] == "ok") and f[1] or nil
        if type(cs) ~= "table" or not v or cs.access == v then return end
        cs.access, cs.access_at = v, os.time()
        if v == "wait" then
            log.info("admin: the host has to let this player in (its join_access is approve): waiting for its answer")
            log.say("access_wait_you", "info", 12)
        else
            log.info("admin: the host let this player in")
            log.say("access_ok_you", "ok", 6)
            -- its id again at once (sdc_persist repeats it every 4 s): the
            -- host's verdict and the character come sooner
            local ps = package.loaded["sdc_persist"]
            if type(ps) == "table" and type(ps.id_soon) == "function" then pcall(ps.id_soon) end
        end
    end)
    -- host -> client: RULES|cheats|<0/1>, RULES|ff|<0/1>
    net.on("RULES", function(f)
        if not S or S.role ~= "client" then return end
        if f[1] == "cheats" then
            local allowed = f[2] ~= "0"
            if rules.cheats ~= allowed then
                log.info("admin: the host %s the game's cheats", allowed and "allows" or "does NOT allow")
            end
            rules.cheats = allowed
            if not allowed and not told_off then
                told_off = true
                log.say("admin_cheats_off", "info", 8)
            end
            if allowed and next(saved) then restore_own("the host allows cheats again") end
            enforce_rules()
        elseif f[1] == "ff" then
            -- RULES|ff|<0/1>: friendly fire (sdc_ffire tells the player)
            local ff = package.loaded["sdc_ffire"]
            if type(ff) == "table" and type(ff.on_rule) == "function" then
                local ok, err = pcall(ff.on_rule, f[2] == "1")
                if not ok then log.err("admin: RULES|ff: %s", tostring(err)) end
            end
        elseif f[1] == "down" then
            -- RULES|down|<0/1>|<seconds>: knockdown (sdc_down)
            local dn = package.loaded["sdc_down"]
            if type(dn) == "table" and type(dn.on_rule) == "function" then
                local ok, err = pcall(dn.on_rule, f[2] == "1", tonumber(f[3]))
                if not ok then log.err("admin: RULES|down: %s", tostring(err)) end
            end
        end
    end)
end

function M.reset(why)
    checked_sid, sent_rules, sent_ff, refused, seen = {}, {}, {}, {}, {}
    if next(saved) and not (S and S.role == "client") then restore_own(why or "world reset") end
end

M._rules = function() return rules end
M._saved = function() return saved end
M._pw = function() return pw_fails, pw_locks end
M._addr_of = addr_of
M.PW_LIMITS = { tries = PW_TRIES, window_s = PW_WINDOW_S, lock_s = PW_LOCK_S, wait_s = PW_WAIT_S,
                ask_every_s = PW_ASK_EVERY_S, max_chars = PW_MAX_CHARS }

return M
