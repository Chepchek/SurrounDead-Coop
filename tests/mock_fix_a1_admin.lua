-- Mock test (critic fixes 2026-11-13, group A1): sdc_admin.
--   A7: a ban needs the player's hello (a "connecting" player can only be kicked);
--   ui A5: a player already kicked is not kicked again;
--   A9: a banned player who comes back gets KICK|1 and on_hello says so (no join announcements);
--   A11: a cheat CVar that will not switch off is logged once, not retried every second;
--   A12: the kick's fallbacks keep only the session key and re-read the controller.
-- usage: lua mock_fix_a1_admin.lua <scripts dir>
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
RegisterConsoleCommandHandler = function() end

-- delayed calls with a fake clock
local T = 0
local delayed = {}
local function advance(ms)
    T = T + ms
    local keep, due = {}, {}
    for _, d in ipairs(delayed) do if d.at <= T then due[#due + 1] = d else keep[#keep + 1] = d end end
    delayed = keep
    for _, d in ipairs(due) do d.fn() end
end

local sent = {}
local handlers = {}
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

local CV, STUCK, sets = {}, {}, {}
local ue = {
    valid = function(o) return type(o) == "table" and not o.destroyed end,
    delay = function(_, ms, fn) delayed[#delayed + 1] = { at = T + ms, fn = fn } end,
    exec = function() end,
    pawn_of = function(pc) return pc.pawn end,
    local_pawn = function() return nil end,
    prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end,
    ksl = function() return nil end,
    find_object = function(path)
        if path:find("ConsoleUtils", 1, true) then
            return {
                GetBoolCVar = function(_, name) return CV[name] end,
                SetBoolCVar = function(_, name, v)
                    sets[#sets + 1] = name
                    if not STUCK[name] then CV[name] = v end
                end,
            }
        end
    end,
}
package.loaded["sdc_ue"] = ue
local SIDS = {}
package.loaded["sdc_persist"] = { steam_of = function(key) return SIDS[key] end }

local log = require("sdc_log")
local said, infos = {}, {}
local real_say = log.say
log.say = function(key, ...) said[#said + 1] = key; return real_say(key, ...) end
log.info = function(fmt, ...) infos[#infos + 1] = string.format(fmt, ...) end
local function was_said(key) for _, k in ipairs(said) do if k == key then return true end end return false end
local function n_infos(pat)
    local n = 0
    for _, l in ipairs(infos) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end
local cfg = require("sdc_config")
cfg.set("banned_players", "")
cfg.save = function() return true end   -- the test never writes a config file

local admin = require("sdc_admin")
local function actor(key)
    local a = { key = key, calls = {} }
    a.K2_DestroyActor = function(self) self.destroyed = true end
    a.ClientReturnToMainMenuWithTextReason = function(self, txt) self.calls[#self.calls + 1] = "menu:" .. tostring(txt) end
    return a
end
local S = { role = "host", remote = {}, remote_pcs = {} }
admin.install(S)
local function player(key, name, hello, sid)
    local pc = actor(key)
    pc.pawn = actor(key .. "pawn")
    S.remote[key] = { key = key, pc = pc, name = name, hello = hello }
    S.remote_pcs[#S.remote_pcs + 1] = pc
    SIDS[key] = sid
    return S.remote[key]
end

print("A7: a ban needs the hello")
local conn = player("connpc", "Player 3", false, nil)
sent = {}
check(admin.kick("connpc", true) == false, "ban of a connecting player refused")
check(#sent_of("KICK", "connpc") == 0 and cfg.get("banned_players") == "", "nothing sent, no name ban stored")
check(not conn.kicked, "the record is not marked kicked")
check(admin.kick("connpc", false) == true and sent_of("KICK", "connpc")[1].f[1] == "0", "a kick still works (KICK|0)")

print("ui A5: a player already kicked is not kicked again")
sent = {}
check(admin.kick("connpc", false) == false and admin.kick("connpc", true) == false, "second kick / ban: false")
check(#sent_of("KICK") == 0 and #sent_of("MSG") == 0, "no second KICK, no second message to the others")
check(cfg.get("banned_players") == "", "still no ban stored")
advance(13000)

print("A9: a banned player comes back")
local bob = player("bobpc", "Bob", true, "76561190000000011")
check(admin.kick("bobpc", true) == true and cfg.get("banned_players") == "76561190000000011:Bob", "Bob banned")
S.remote.bobpc = nil
sent, said = {}, {}
local bob2 = player("bob2pc", "Bobby", true, "76561190000000011")
local gone = admin.on_hello(bob2)
check(gone == true, "on_hello: true (no join announcements)")
local k = sent_of("KICK", "bob2pc")
check(#k == 1 and k[1].f[1] == "1", "KICK|1: told it is banned")
check(was_said("admin_banned_join") and not was_said("admin_ban_done"), "the host is told it was the ban list")
check(cfg.get("banned_players") == "76561190000000011:Bob", "the ban list stays as it was")
local ann = player("annpc", "Ann", true, "76561190000000022")
check(admin.on_hello(ann) == false, "a player who is not banned: on_hello false")
check(admin.on_hello(bob2) == true, "a kicked player saying hello again: true")
S.remote.bob2pc, S.remote.annpc = nil, nil
advance(13000)

print("A12: the fallbacks re-read the controller by the key")
local gleb = player("glebpc", "Gleb", true, nil)
local old_pc = gleb.pc
admin.kick("glebpc", false)
local new_pc = actor("glebpc")          -- the same player's record, a new wrapper of its controller
new_pc.pawn = actor("glebpawn2")
gleb.pc = new_pc
advance(6000)
check(#old_pc.calls == 0 and new_pc.calls[1] == "menu:Kicked by the host", "6 s: the engine's return to the menu on the current controller")
advance(6000)
check(new_pc.destroyed and new_pc.pawn.destroyed and not old_pc.destroyed, "12 s: the current controller and character destroyed")
-- a new player under the same session key (not kicked): nothing forced
local zed = player("zedpc", "Zed", true, nil)
admin.kick("zedpc", false)
local zed2 = player("zedpc", "Zed2", true, nil)
advance(13000)
check(#zed2.pc.calls == 0 and not zed2.pc.destroyed and #zed.pc.calls == 0, "a new record under that key: nothing forced")

print("A11: a CVar that will not switch off")
S.role, S.remote, S.remote_pcs = "client", {}, {}
CV["Debug.Allow"], CV["Debug.NoClip"] = true, true
STUCK["Debug.NoClip"] = true
infos, sets = {}, {}
handlers.RULES({ "cheats", "0" })
check(CV["Debug.Allow"] == false and CV["Debug.NoClip"] == true, "Debug.Allow off, Debug.NoClip stays on")
check(n_infos("Debug.NoClip (FAILED") == 1, "the failure is logged")
local tries = 0
for _, s in ipairs(sets) do if s == "Debug.NoClip" then tries = tries + 1 end end
for _ = 1, 10 do admin.tick() end
local tries2 = 0
for _, s in ipairs(sets) do if s == "Debug.NoClip" then tries2 = tries2 + 1 end end
check(tries2 == tries and n_infos("Debug.NoClip (FAILED") == 1, "not tried again, not logged again (10 ticks)")
CV["Debug.Allow"] = true   -- switched on again by hand: still kept off
admin.tick()
check(CV["Debug.Allow"] == false, "the other CVars are still kept off")
S.role = "standalone"
admin.tick()
STUCK["Debug.NoClip"] = nil
S.role = "client"
CV["Debug.NoClip"] = true
handlers.RULES({ "cheats", "0" })
check(CV["Debug.NoClip"] == false, "after leaving the world it is tried again (and now switches off)")

print = real_print
print(string.format("fix_a1_admin: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
