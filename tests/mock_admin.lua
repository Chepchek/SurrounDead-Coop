-- Mock test: sdc_admin (0.7.3) - the host kicks / bans players and switches
-- the game's cheats off on clients.
-- usage: lua mock_admin.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end

FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
local COMMANDS = {}
RegisterConsoleCommandHandler = function(name, fn) COMMANDS[name] = fn end

-- delayed calls with a fake clock
local T = 0
local delayed = {}
local function advance(ms)
    T = T + ms
    local keep = {}
    local due = {}
    for _, d in ipairs(delayed) do if d.at <= T then due[#due + 1] = d else keep[#keep + 1] = d end end
    delayed = keep
    for _, d in ipairs(due) do d.fn() end
end

-- net
local sent, handlers = {}, {}
local net = {
    on = function(kind, fn) handlers[kind] = fn end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end,
    broadcast = function(pcs, kind, ...)
        for _, pc in ipairs(pcs) do sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } end
    end,
}
package.loaded["sdc_net"] = net
local function sent_of(kind, to)
    local out = {}
    for _, m in ipairs(sent) do if m.kind == kind and (to == nil or m.to == to) then out[#out + 1] = m end end
    return out
end

-- engine
local CV = {}                    -- the CVars of this machine
local execs = {}
local LOCAL = { pawn = nil }
local ue = {
    valid = function(o) return type(o) == "table" and not o.destroyed end,
    delay = function(_, ms, fn) delayed[#delayed + 1] = { at = T + ms, fn = fn } end,
    exec = function(cmd) execs[#execs + 1] = cmd end,
    pawn_of = function(pc) return pc.pawn end,
    local_pawn = function() return LOCAL.pawn end,
    prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end,
    ksl = function() return nil end,
    find_object = function(path)
        if path:find("ConsoleUtils", 1, true) then
            return {
                GetBoolCVar = function(_, name) return CV[name] end,
                SetBoolCVar = function(_, name, v) CV[name] = v end,
            }
        end
    end,
}
package.loaded["sdc_ue"] = ue
local SIDS = {}
package.loaded["sdc_persist"] = { steam_of = function(key) return SIDS[key] end }

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, ...) said[#said + 1] = key; return real_say(key, ...) end
local function was_said(key) for _, k in ipairs(said) do if k == key then return true end end return false end
local cfg = require("sdc_config")

local admin = require("sdc_admin")
local function actor(key)
    local a = { key = key, calls = {} }
    a.K2_DestroyActor = function(self) self.destroyed = true end
    a.ClientReturnToMainMenuWithTextReason = function(self, txt) self.calls[#self.calls + 1] = "menu:" .. tostring(txt) end
    return a
end
local bob_pc, gleb_pc = actor("bobpc"), actor("glebpc")
bob_pc.pawn, gleb_pc.pawn = actor("bobpawn"), actor("glebpawn")
local S = { role = "host", remote = {}, remote_pcs = { bob_pc, gleb_pc } }
S.remote.bobpc = { key = "bobpc", pc = bob_pc, name = "Bob", hello = true }
S.remote.glebpc = { key = "glebpc", pc = gleb_pc, name = "Gleb", hello = true }
SIDS.bobpc = "76561190000000011"
admin.install(S)
check(handlers.KICK and handlers.RULES, "KICK / RULES handlers")
check(COMMANDS.god and COMMANDS.fly and COMMANDS.ghost and COMMANDS.slomo, "console cheat commands guarded")

print("host: rules")
cfg.set("client_cheats", true)
admin.tick()
check(#sent_of("RULES", "bobpc") == 1 and sent_of("RULES", "bobpc")[1].f[2] == "1", "cheats allowed: RULES cheats 1 to Bob")
admin.tick()
check(#sent_of("RULES", "bobpc") == 1, "sent once")
cfg.set("client_cheats", false)
admin.tick()
local rb = sent_of("RULES", "bobpc")
check(#rb == 2 and rb[2].f[1] == "cheats" and rb[2].f[2] == "0" and #sent_of("RULES", "glebpc") == 2, "switched off: RULES cheats 0 to everyone")

print("host: kick")
sent = {}
check(admin.kick("glebpc", false) == true, "kick Gleb")
check(#sent_of("KICK", "glebpc") == 1 and sent_of("KICK", "glebpc")[1].f[1] == "0", "KICK|0 to Gleb")
local m = sent_of("MSG", "bobpc")
check(#m == 1 and m[1].f[1] == "admin_player_kicked" and m[1].f[2] == "Gleb", "Bob is told")
check(was_said("admin_kick_done"), "the host is told")
check(cfg.get("banned_players") == "", "a kick bans nobody")
advance(6000)
check(gleb_pc.calls[1] == "menu:Kicked by the host", "still there after 6 s: the engine's return to the menu")
advance(6000)
check(gleb_pc.destroyed and gleb_pc.pawn.destroyed, "still there after 12 s: character and controller destroyed")
-- a player who leaves in time: nothing forced
local zed = actor("zedpc"); zed.pawn = actor("zedpawn")
S.remote.zedpc = { key = "zedpc", pc = zed, name = "Zed", hello = true }
admin.kick("zedpc", false)
S.remote.zedpc = nil
advance(13000)
check(#zed.calls == 0 and not zed.destroyed, "left by itself: nothing forced")
check(admin.kick("nobody", false) == false, "no such player: false")

print("host: ban")
sent = {}
check(admin.kick("bobpc", true) == true, "ban Bob")
check(sent_of("KICK", "bobpc")[1].f[1] == "1", "KICK|1 to Bob")
check(cfg.get("banned_players") == "76561190000000011:Bob", "ban list: SteamID:Name (" .. tostring(cfg.get("banned_players")) .. ")")
check(admin.is_banned("Someone", "76561190000000011") and not admin.is_banned("Bob", "76561190000000099"),
    "banned by SteamID, not by name when the ban has a SteamID")
check(admin.banned_names()[1] == "Bob", "names for the panel")
-- Bob comes back: kicked at his hello
sent = {}
local bob2 = actor("bob2pc")
S.remote.bob2pc = { key = "bob2pc", pc = bob2, name = "Bobby", hello = true }
SIDS.bob2pc = "76561190000000011"
admin.on_hello(S.remote.bob2pc)
check(#sent_of("KICK", "bob2pc") == 1 and was_said("admin_banned_join"), "banned SteamID joins: kicked, the host is told")
-- the SteamID arrives later than the hello
sent = {}
local bob3 = actor("bob3pc")
S.remote.bob3pc = { key = "bob3pc", pc = bob3, name = "B", hello = true }
admin.on_hello(S.remote.bob3pc)
check(#sent_of("KICK", "bob3pc") == 0, "no SteamID yet: let in")
SIDS.bob3pc = "76561190000000011"
admin.tick()
check(#sent_of("KICK", "bob3pc") == 1, "its SteamID arrives: kicked")
-- a ban by name (no SteamID: IP join without one)
sent = {}
local ivan = actor("ivanpc")
S.remote.ivanpc = { key = "ivanpc", pc = ivan, name = "Ivan", hello = true }
admin.kick("ivanpc", true)
check(cfg.get("banned_players"):find(";Ivan$") ~= nil, "no SteamID: banned by name")
check(admin.is_banned("ivan", nil), "name match ignores case")
-- the early id (PSID, before the character and the hello): a banned player is refused at once
sent, said = {}, {}
local ivan2 = actor("ivan2pc")
S.remote.ivan2pc = { key = "ivan2pc", pc = ivan2, name = "Player 2" }   -- no hello yet
check(admin.on_early_id(S.remote.ivan2pc, "Ivan", nil) == true, "banned name at the early id: on its way out")
check(#sent_of("KICK", "ivan2pc") == 1 and sent_of("KICK", "ivan2pc")[1].f[1] == "1", "KICK|1 before its hello")
check(was_said("admin_banned_join") and not was_said("admin_ban_done"), "the host is told once: banned, not let in")
local mk = sent_of("MSG", "bobpc")
check(#mk == 1 and mk[1].f[2] == "Ivan", "the others hear the early id's name, not 'Player 2'")
check(admin.on_early_id(S.remote.ivan2pc, "Ivan", nil) == true and #sent_of("KICK", "ivan2pc") == 1,
    "the id repeated: no second kick")
check(admin.on_hello(S.remote.ivan2pc) == true, "its hello later: still on its way out")
local fine = actor("finepc")
S.remote.finepc = { key = "finepc", pc = fine, name = "Player 3" }
check(admin.on_early_id(S.remote.finepc, "Fine", nil) == false and #sent_of("KICK", "finepc") == 0, "not banned: let in")
check(admin.kick("finepc", true) == false, "a NEW ban still needs the hello")
check(admin.unban_all() == 2 and cfg.get("banned_players") == "" and not admin.is_banned("Ivan", nil), "bans cleared")

print("client: rules and kick")
S.role, S.remote, S.remote_pcs = "client", {}, {}
said, execs = {}, {}
CV["Debug.Allow"], CV["Debug.NoClip"], CV["Debug.Invincibility"] = true, true, false
local closed = 0
LOCAL.pawn = { DebugMenu = { key = "dm" }, CloseDebugMenu = function() closed = closed + 1 end }
check(COMMANDS.god(nil, nil, nil) == false, "cheats allowed (default): console god goes on")
handlers.RULES({ "cheats", "0" })
check(CV["Debug.Allow"] == false and CV["Debug.NoClip"] == false and CV["Debug.Invincibility"] == false,
    "cheats off: the debug menu and its cheats switched off")
check(closed == 1 and was_said("admin_cheats_off"), "open debug menu closed, the player is told")
check(COMMANDS.god(nil, nil, nil) == true and COMMANDS.fly(nil, nil, nil) == true, "console god / fly refused")
CV["Debug.NoClip"] = true          -- switched on again by hand
admin.tick()
check(CV["Debug.NoClip"] == false, "kept off every second")
handlers.RULES({ "cheats", "0" })
local n_off = 0
for _, k in ipairs(said) do if k == "admin_cheats_off" then n_off = n_off + 1 end end
check(n_off == 1, "told once")
-- leaving: own values back
S.role = "standalone"
admin.tick()
check(CV["Debug.Allow"] == true and CV["Debug.NoClip"] == true and CV["Debug.Invincibility"] == false,
    "left the world: this machine's own values back (only the changed ones)")
check(COMMANDS.god(nil, nil, nil) == false, "after leaving: console commands go on")
-- the host allows cheats again while connected
S.role = "client"
handlers.RULES({ "cheats", "0" })
check(CV["Debug.Allow"] == false, "off again")
handlers.RULES({ "cheats", "1" })
check(CV["Debug.Allow"] == true, "the host allows cheats again: own values back")
-- kicked
said, execs = {}, {}
handlers.KICK({ "1" })
check(was_said("admin_banned_you") and execs[1] == "disconnect" and S.disconnect_requested == true,
    "KICK|1: told 'banned', the game's disconnect")
S.role = "host"
handlers.KICK({ "0" })
check(#execs == 1, "the host ignores KICK")
-- a kicked client stops its automatic join (it must not walk straight back in)
local stopped = nil
package.loaded["sdc_session"] = { stop_auto_join = function(why) stopped = why end }
S.role = "client"
handlers.KICK({ "1" })
check(stopped == "banned by the host", "banned: the automatic join stops (" .. tostring(stopped) .. ")")
package.loaded["sdc_session"] = nil

print = real_print
print(string.format("admin: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
