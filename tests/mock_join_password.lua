-- Mock test: the join password and invite only (sdc_admin, join_access
-- open | password | approve | list).
--   host: no password set yet (refused at once with KICK|6|3 "unset", also
--   when it is cleared while a player is asked); asked (ACCESS|pw, again
--   every 4 s, held: no character, no verdict); the right password (on the
--   list, ACCESS|ok, the id gate counts from then); a listed player is not
--   asked; Steam players are asked too; wrong / empty / no answer (an older
--   mod: 20 s); the guess limit (5 wrong in 10 min per real network
--   address -> 10 min lock; the window; loopback is no address: not
--   counted; a claimed SteamID / name never counts: a griefer by IP
--   claiming a friend's SteamID locks only its own address, the friend
--   through Steam still gets in; rotating ids through loopback: never locked);
--   the mode switched while a player is asked; the ban list and
--   max_players first; no id: asked at 60 s, let in but not listed; a new
--   password keeps listed friends; invite only + the Steam tab's Invite
--   client: the password kept per join target (IP / Steam, escaping, the
--   oldest dropped), the answer to ACCESS|pw (no join recorded, a console
--   "open": an empty answer, never the IP tab's address's password),
--   KICK|6|<sub>|<min> (texts, 6|3 unset; an unknown sub-code reads as
--   none; auto join stopped, disconnect), an unknown code reads as a kick,
--   ACCESS|ok sends the id again at once
--   the real sdc_session: a join from the panel is the connection that
--   begins within 5 min of it, and only its first one; a console "open"
--   later (15 min after, or right after that join's own connection) gets an
--   empty answer, never the old join's host's password; a Steam join's
--   tunnel opened late is still the join
--   sdc_net: JPW never in the log (sent / received), other kinds as before
-- usage: lua mock_join_password.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end
local function section(s) io.write(s, "\n") end

FName = function(s) return s end
FText = function(s) return s end
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn return 1, 2 end
RegisterConsoleCommandHandler = function() end

local NOW = 1000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end
local function advance(s) NOW = NOW + s end

-- net (stub: sdc_admin keeps this one; the real sdc_net is tested at the end)
local sent, handlers = {}, {}
local net_stub = {
    on = function(kind, fn) handlers[kind] = fn end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end,
    send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, f = { ... } } return true end,
    broadcast = function(pcs, kind, ...)
        for _, pc in ipairs(pcs) do sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } end
    end,
}
package.loaded["sdc_net"] = net_stub
local function sent_of(kind, to)
    local out = {}
    for _, m in ipairs(sent) do if m.kind == kind and (to == nil or m.to == to) then out[#out + 1] = m end end
    return out
end
local function last_of(kind, to)
    local l = sent_of(kind, to)
    return l[#l] or { f = {} }
end
local function fields(m) return table.concat(m.f, "|") end

-- engine
local execs = {}
local CLIENT_PC = nil
local ue_stub = {
    valid = function(o) return type(o) == "table" and not o.destroyed end,
    delay = function() end,
    every = function() end,
    exec = function(cmd) execs[#execs + 1] = cmd end,
    pawn_of = function(pc) return pc.pawn end,
    local_pawn = function() return nil end,
    local_pc = function() return CLIENT_PC end,
    prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end,
    ksl = function() return nil end,
    find_object = function() return nil end,
    str = function(v) if v == nil then return "" end return tostring(v) end,
    name = function(o) return type(o) == "table" and (o.key or "obj") or "none" end,
    short = function(o) return type(o) == "table" and (o.key or "obj") or "none" end,
    net_role = function() return "host" end,
}
package.loaded["sdc_ue"] = ue_stub
local SIDS = {}
local id_soon = 0
package.loaded["sdc_persist"] = { steam_of = function(key) return SIDS[key] end, id_soon = function() id_soon = id_soon + 1 end }
local players = {}
package.loaded["sdc_players"] = players
package.loaded["sdc_steam"] = {
    code_of = function(a)
        local s = tostring(a or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local id = s:match("^steam%.(%d+)$") or s
        return (#id == 17 and id:match("^%d+$")) and id or nil
    end,
}
local stopped = nil
package.loaded["sdc_session"] = { stop_auto_join = function(why) stopped = why end }

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, kind, secs, ...)
    said[#said + 1] = { key = key, kind = kind, args = { ... } }
    return real_say(key, kind, secs, ...)
end
local function said_n(key)
    local n = 0
    for _, s in ipairs(said) do if s.key == key then n = n + 1 end end
    return n
end
local function said_last(key)
    for i = #said, 1, -1 do if said[i].key == key then return said[i] end end
    return { args = {} }
end
local lines = {}
log.info = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
log.warn = function(fmt, ...) lines[#lines + 1] = "WARN " .. string.format(fmt, ...) end
log.err = function(fmt, ...) lines[#lines + 1] = "ERR " .. string.format(fmt, ...) end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then return l end end
    return nil
end
local function log_has_secret(secret)
    for _, l in ipairs(lines) do if l:find(secret, 1, true) then return l end end
    return nil
end
local cfg = require("sdc_config")
local saves = 0
cfg.save = function() saves = saves + 1 return true end
local i18n = require("sdc_i18n")

local admin = require("sdc_admin")
local S = { role = "host", remote = {}, remote_pcs = {} }
admin.install(S)
check(handlers.JPW ~= nil and handlers.KICK ~= nil and handlers.ACCESS ~= nil, "JPW / KICK / ACCESS handlers")

local n_idx = 0
local function actor(key, addr)
    local a = { key = key, calls = {} }
    a.K2_DestroyActor = function(self) self.destroyed = true end
    a.ClientReturnToMainMenuWithTextReason = function(self, txt) self.calls[#self.calls + 1] = "menu:" .. tostring(txt) end
    if addr then a.GetPlayerNetworkAddress = function() return addr end end
    return a
end
local function join(key, addr)
    n_idx = n_idx + 1
    local pc = actor(key, addr)
    S.remote[key] = { key = key, pc = pc, index = n_idx, name = "Player " .. n_idx, hello = false, joined_at = NOW,
                      pawnless_since = NOW, spawned_once = false }
    S.remote_pcs[#S.remote_pcs + 1] = pc
    return S.remote[key]
end
local function reset_world() S.remote, S.remote_pcs = {}, {} end
local function sid(n) return string.format("765611900000%05d", n) end
local PW = "Сезам 1"

-- ------------------------------------------------------------------ settings, strings
section("settings and strings")
for _, key in ipairs({ "join_password", "host_passwords" }) do
    local row = i18n.schema_row(key)
    check(row and row[2] == "string" and row[3] == "" and row[4]:find("[\208\209]") ~= nil and row[4]:find("открытым текстом", 1, true)
        and type(i18n.DESC_EN[key]) == "string" and i18n.DESC_EN[key]:find("plain text", 1, true) and i18n.GROUP_OF[key] == nil,
        key .. ": a string, empty, RU + EN (plain text said), no settings group")
end
check(i18n.schema_row("join_access")[4]:find("password", 1, true) and i18n.DESC_EN.join_access:find("password", 1, true),
    "join_access: password described")
check(i18n.T("wa_mode_open") == "Все" and i18n.T("wa_mode_password") == "По паролю" and i18n.T("wa_mode_approve") == "По одобрению"
    and i18n.T("wa_mode_list") == "Только приглашённые", "the four modes: Все / По паролю / По одобрению / Только приглашённые")
local keys = { "access_pw_wrong", "access_pw_none", "access_pw_locked", "access_pw_unset", "access_pw_ok", "access_pw_set",
               "access_pw_cleared", "access_pw_need_you", "access_pw_wrong_you", "access_pw_locked_you", "access_pw_wrong_nc",
               "access_pw_unset_you" }
local bad = {}
for _, k in ipairs(keys) do
    local t = log.TEXT[k]
    if not (t and t[1] and t[2] and not t[1]:find("[\208\209]") and t[2]:find("[\208\209]") and i18n.SAY_CLASS[k] == "game") then
        bad[#bad + 1] = k
    end
end
check(#bad == 0, "notices: English log, Russian screen, the game's notification: " .. table.concat(bad, ","))
check(admin.set_access_mode("password") and cfg.get("join_access") == "password" and admin.access_mode() == "password",
    "join_access password: a mode of its own")
check(admin.KICK.password == 6 and admin.PW.none == 0 and admin.PW.wrong == 1 and admin.PW.locked == 2 and admin.PW.unset == 3,
    "KICK|6|<0 none, 1 wrong, 2 locked, 3 unset>")

section("norm_pw")
check(admin.norm_pw("  a|b\tc \n") == "a b c" and admin.norm_pw(nil) == "", "'|' and control characters -> space, trimmed")
local long = admin.norm_pw(string.rep("я", 70))
check(utf8.len(long) == 64 and long == string.rep("я", 64), "at most 64 characters, never half a Cyrillic letter")

-- ------------------------------------------------------------------ host
section("no password set yet")
local p0 = join("p0")
check(admin.on_early_id(p0, "Nik", sid(1)) == true and fields(last_of("KICK", "p0")) == "6|3|0" and #sent_of("ACCESS", "p0") == 0,
    "refused at once (KICK|6|3: the host has set no password yet), not asked: " .. fields(last_of("KICK", "p0")))
check(said_last("access_pw_unset").args[1] == "Nik" and log.tr("access_pw_unset", "Nik"):find("не задан", 1, true),
    "the host is told: no password set")
check(admin.recent()[1].name == "Nik" and admin.recent()[1].reason == "pw_unset", "recently turned away: «пароль не задан» (pw_unset)")

section("asked")
local s0 = saves
local ok_set, stored = admin.set_join_password("  " .. PW .. "  ")
check(ok_set and stored == PW and cfg.get("join_password") == PW and saves == s0 + 1 and said_last("access_pw_set").kind == "ok",
    "set_join_password: trimmed, saved, a notice")
check(not log_has_secret(PW), "the password is not in the log")
local a = join("a")
check(admin.on_early_id(a, "Ann", sid(10)) == true and a.access == "pw" and last_of("ACCESS", "a").f[1] == "pw",
    "an unlisted player: held, ACCESS|pw")
check(admin.access_gate(a, NOW) == false and a.name == "Ann", "its first character waits; the panel says who it is")
check(admin.on_early_id(a, "Ann", sid(10)) == true and #sent_of("ACCESS", "a") == 1, "its id again: still held, not asked twice")
check(#admin.waiting() == 0, "not in the host's waiting list (no answer of the host needed)")
advance(3); admin.tick()
check(#sent_of("ACCESS", "a") == 1, "3 s: not asked again yet")
advance(1); admin.tick()
check(#sent_of("ACCESS", "a") == 2, "4 s: asked again")
handlers.JPW({ PW }, a.pc)
check(a.access == "ok" and last_of("ACCESS", "a").f[1] == "ok" and a.access_ok_at == NOW, "the right password: in (ACCESS|ok), the id gate counts from now")
check(cfg.get("allowed_players") == sid(10) .. ":Ann" and said_last("access_pw_ok").args[1] == "Ann", "on the list, the host told")
check(admin.access_gate(a, NOW) ~= false and admin.on_early_id(a, "Ann", sid(10)) == false, "the character may come, the verdict goes")
check(not log_has_secret(PW), "still no password in the log")
local a2 = join("a2")
check(admin.on_early_id(a2, "Ann", sid(10)) == false and a2.access == "ok" and #sent_of("ACCESS", "a2") == 0,
    "listed: the next time no password")

section("Steam players are asked too")
local b = join("b")   -- a friend through the Steam helper: 127.0.0.1, its SteamID
b.pc.GetPlayerNetworkAddress = function() return "127.0.0.1:61000" end
check(admin.on_early_id(b, "Bob", sid(20)) == true and last_of("ACCESS", "b").f[1] == "pw", "a SteamID does not skip the password")
local nw = said_n("access_pw_wrong")
handlers.JPW({ "wrong" }, b.pc)
check(b.access == "refused" and fields(last_of("KICK", "b")) == "6|1|0", "wrong: KICK|6|1")
local w = said_last("access_pw_wrong_nc")
check(w.args[1] == "Bob" and #w.args == 1 and w.kind == "warn" and said_n("access_pw_wrong") == nw
    and log.tr("access_pw_wrong_nc", "Bob") == "Bob ввёл неверный пароль — не впущен.",
    "loopback (not counted): the host gets «… не впущен.», no «(1 из 5)»")
check(log.tr("access_pw_wrong", "Bob", 1, 5) == "Bob ввёл неверный пароль — не впущен (1 из 5).", "the counted text: «… (1 из 5)»")
check(logged("a wrong password (no network address: not counted)") ~= nil, "the log says it was not counted")
local rc = admin.recent()[1]
check(rc.name == "Bob" and rc.sid == sid(20) and rc.reason == "pw_wrong", "recently turned away: wrong password")
handlers.JPW({ PW }, b.pc)
check(b.access == "refused" and not cfg.get("allowed_players"):find("Bob", 1, true), "an answer after the refusal: ignored")

section("empty answer, no answer")
local c = join("c", "26.10.0.30:7777")
admin.on_early_id(c, "Cid", sid(30))
handlers.JPW({ "" }, c.pc)
local pf, pl = admin._pw()
check(fields(last_of("KICK", "c")) == "6|0|0" and said_last("access_pw_none").args[1] == "Cid" and pf["a:26.10.0.30"] == nil,
    "no password kept by the player: KICK|6|0, not counted as a guess")
check(admin.recent()[1].reason == "pw_none", "recently turned away: no password")
local d = join("d")
admin.on_early_id(d, "Dan", sid(40))
advance(19); admin.tick()
check(d.access == "pw", "19 s without an answer: still asked")
advance(1); admin.tick()
check(fields(last_of("KICK", "d")) == "6|0|0" and logged("no answer to the password request in 20 s (an older mod?)") ~= nil,
    "20 s: refused (an older mod has no ACCESS|pw)")

section("guess limit: 5 wrong in 10 minutes (one address)")
local EVE = "26.10.0.50:7777"
for n = 1, 4 do
    local e = join("e" .. n, EVE)
    admin.on_early_id(e, "Eve", sid(50))
    handlers.JPW({ "guess" .. n }, e.pc)
    check(fields(last_of("KICK", "e" .. n)) == "6|1|0" and said_last("access_pw_wrong").args[2] == n, "wrong " .. n .. " of 5")
    advance(30)
end
local e5 = join("e5", EVE)
admin.on_early_id(e5, "Eve", sid(50))
handlers.JPW({ "guess5" }, e5.pc)
check(fields(last_of("KICK", "e5")) == "6|2|10" and said_last("access_pw_locked").args[2] == 10
    and log.tr("access_pw_locked", "Eve", 10) == "Eve: слишком много неверных паролей — вход закрыт на 10 мин.", "the 5th: locked for 10 min")
check(admin.recent()[1].reason == "pw_locked", "recently turned away: too many tries")
local e6 = join("e6", EVE)
check(admin.on_early_id(e6, "Eve", sid(50)) == true and #sent_of("ACCESS", "e6") == 0 and fields(last_of("KICK", "e6")) == "6|2|10",
    "locked: refused at once, not even asked")
check(pl["a:26.10.0.50"] ~= nil, "the lock is on the address")
advance(5 * 60)
local e7 = join("e7", EVE)
admin.on_early_id(e7, "Eve", sid(50))
check(fields(last_of("KICK", "e7")) == "6|2|5", "5 minutes later: 5 minutes left")
local f = join("f", "26.10.0.60:7777")
check(admin.on_early_id(f, "Fay", sid(60)) == true and last_of("ACCESS", "f").f[1] == "pw", "another address is not locked")
advance(5 * 60)
local e8 = join("e8", EVE)
check(admin.on_early_id(e8, "Eve", sid(50)) == true and last_of("ACCESS", "e8").f[1] == "pw", "10 minutes later: asked again")
handlers.JPW({ PW }, e8.pc)
check(e8.access == "ok" and cfg.get("allowed_players"):find(sid(50) .. ":Eve", 1, true), "the right password then: in")

section("the window")
for n = 1, 4 do
    local g = join("g" .. n, "26.10.0.70:7777")
    admin.on_early_id(g, "Gus", sid(70))
    handlers.JPW({ "x" }, g.pc)
end
advance(601)
local g5 = join("g5", "26.10.0.70:7777")
admin.on_early_id(g5, "Gus", sid(70))
handlers.JPW({ "x" }, g5.pc)
check(fields(last_of("KICK", "g5")) == "6|1|0" and said_last("access_pw_wrong").args[2] == 1, "older than 10 min: not counted (1 of 5)")
check(admin.recent()[1].name == "Gus" and #admin.recent() <= 8, "the recent list keeps one entry per player, at most 8")

section("by address only")
-- no SteamID, no address: a claimed name never counts
for n = 1, 5 do
    local h = join("h" .. n)
    admin.on_early_id(h, "Hal", nil)
    handlers.JPW({ "x" }, h.pc)
end
check(fields(last_of("KICK", "h5")) == "6|1|0" and said_last("access_pw_wrong_nc").args[1] == "Hal",
    "no address: a name is not counted (the 5th still only «wrong»)")
local h6 = join("h6")
check(admin.on_early_id(h6, "Hal", nil) == true and last_of("ACCESS", "h6").f[1] == "pw", "and the next one is still asked")
local addr = admin._addr_of
local function pcs(v) return { GetPlayerNetworkAddress = function() return v end } end
check(addr(pcs("26.10.0.5:7777")) == "26.10.0.5" and addr(pcs("26.10.0.5")) == "26.10.0.5", "IPv4 (the port cut)")
check(addr(pcs("[2001:db8::5]:7777")) == "2001:db8::5", "IPv6 in brackets")
check(addr(pcs("127.0.0.1:55000")) == nil and addr(pcs("[::1]:7777")) == nil and addr(pcs("[::ffff:127.0.0.1]:7777")) == nil,
    "loopback (the Steam helper, a local tunnel): no address")
check(addr(pcs("garbage")) == nil and addr(pcs("")) == nil and addr({}) == nil
    and addr({ GetPlayerNetworkAddress = function() error("no such function") end }) == nil, "not an address / no function: nil")
-- an edited mod changing its SteamID each time: the address still counts
for n = 1, 5 do
    local k = join("k" .. n, "26.10.0.9:7777")
    admin.on_early_id(k, "K" .. n, sid(100 + n))
    handlers.JPW({ "x" }, k.pc)
end
check(fields(last_of("KICK", "k5")) == "6|2|10", "a new SteamID each time from one address: locked by the address")
local k6 = join("k6", "26.10.0.9:7777")
check(admin.on_early_id(k6, "K6", sid(106)) == true and fields(last_of("KICK", "k6")) == "6|2|10", "the next one from it: refused at once")
local k7 = join("k7", "127.0.0.1:61001")
check(admin.on_early_id(k7, "K7", sid(107)) == true and last_of("ACCESS", "k7").f[1] == "pw", "a Steam friend (loopback): not locked")

section("a claimed SteamID locks nobody out")
-- a griefer by IP claims friend Fred's SteamID 5 times with wrong passwords
local FRED, GRIEFER = sid(900), "26.10.0.99:7777"
for n = 1, 5 do
    local z = join("z" .. n, GRIEFER)
    admin.on_early_id(z, "Fred", FRED)
    handlers.JPW({ "nope" .. n }, z.pc)
end
check(fields(last_of("KICK", "z5")) == "6|2|10" and pl["a:26.10.0.99"] ~= nil, "the griefer's own address is locked")
local function claimed_keys()
    local out = {}
    for _, t in ipairs({ pf, pl }) do
        for k in pairs(t) do
            if not k:find("^a:") or k:find(FRED, 1, true) then out[#out + 1] = k end
        end
    end
    return out
end
check(#claimed_keys() == 0, "no lock or count on a SteamID or name: " .. table.concat(claimed_keys(), ","))
local z6 = join("z6", GRIEFER)
check(admin.on_early_id(z6, "Zed", sid(902)) == true and fields(last_of("KICK", "z6")) == "6|2|10" and #sent_of("ACCESS", "z6") == 0,
    "the griefer with another SteamID: still locked by its address")
local fr1 = join("fr1", "26.10.0.98:7777")
check(admin.on_early_id(fr1, "Fred", FRED) == true and last_of("ACCESS", "fr1").f[1] == "pw", "Fred by IP from his own address: asked")
handlers.JPW({ "typo" }, fr1.pc)
check(fields(last_of("KICK", "fr1")) == "6|1|0" and said_last("access_pw_wrong").args[2] == 1, "his typo: 1 of 5 on his own address")
local fr2 = join("fr2", "127.0.0.1:61010")
check(admin.on_early_id(fr2, "Fred", FRED) == true and last_of("ACCESS", "fr2").f[1] == "pw" and #sent_of("KICK", "fr2") == 0,
    "Fred through Steam (loopback): asked, not locked")
handlers.JPW({ PW }, fr2.pc)
check(fr2.access == "ok" and last_of("ACCESS", "fr2").f[1] == "ok" and cfg.get("allowed_players"):find(FRED .. ":Fred", 1, true),
    "the right password: Fred is in")

section("rotating ids through loopback: never locked")
local nf, nl0 = 0, 0
for _ in pairs(pf) do nf = nf + 1 end
for _ in pairs(pl) do nl0 = nl0 + 1 end
local all_wrong = true
for n = 1, 8 do
    local y = join("y" .. n, "127.0.0.1:" .. (62000 + n))
    if not (admin.on_early_id(y, "Y" .. n, sid(910 + n)) == true and last_of("ACCESS", "y" .. n).f[1] == "pw") then all_wrong = false end
    handlers.JPW({ "guess" .. n }, y.pc)
    if fields(last_of("KICK", "y" .. n)) ~= "6|1|0" then all_wrong = false end
end
local nf2, nl2 = 0, 0
for _ in pairs(pf) do nf2 = nf2 + 1 end
for _ in pairs(pl) do nl2 = nl2 + 1 end
check(all_wrong and nf2 == nf and nl2 == nl0, "8 tries, a new SteamID each: each only «wrong», nothing counted or locked")
local y9 = join("y9", "127.0.0.1:62009")
admin.on_early_id(y9, "Yan", sid(919))
handlers.JPW({ PW }, y9.pc)
check(y9.access == "ok", "a right password through loopback: in")

section("the mode switched while a player is asked")
local m1 = join("m1")
admin.on_early_id(m1, "Max", sid(200))
admin.set_access_mode("open")
check(m1.access == "ok" and last_of("ACCESS", "m1").f[1] == "ok", "to open: let in")
admin.set_access_mode("password")
local m2 = join("m2")
admin.on_early_id(m2, "Mia", sid(201))
admin.set_access_mode("list")
check(fields(last_of("KICK", "m2")) == "2", "to invite only: KICK|2")
admin.set_access_mode("password")
local m3 = join("m3")
admin.on_early_id(m3, "Moe", sid(202))
admin.set_access_mode("approve")
check(m3.access == "wait" and last_of("ACCESS", "m3").f[1] == "wait" and said_last("access_ask").args[1] == "Moe",
    "to approve: waits for the host (ACCESS|wait)")
admin.set_access_mode("password")
check(m3.access == "pw" and last_of("ACCESS", "m3").f[1] == "pw", "back to password: asked")
admin.list_add("Moe", sid(202))
admin.tick()
check(m3.access == "ok" and last_of("ACCESS", "m3").f[1] == "ok", "the host puts it on the list: in")

section("the ban list and max_players first")
reset_world()
cfg.set("banned_players", sid(300) .. ":Xan")
local x = join("x")
check(admin.on_early_id(x, "Xan", sid(300)) == true and fields(last_of("KICK", "x")) == "1" and #sent_of("ACCESS", "x") == 0,
    "banned: KICK|1, not asked")
cfg.set("banned_players", "")
reset_world()
cfg.set("max_players", 2)
local q1 = join("q1")
admin.on_early_id(q1, "Quinn", sid(301))
check(q1.access == "pw", "one player asked")
local q2 = join("q2")
check(admin.on_early_id(q2, "Quill", sid(302)) == true and fields(last_of("KICK", "q2")) == "5",
    "max_players 2: the asked one counts, the next one: full (KICK|5)")
cfg.set("max_players", 0)

section("no id: asked at 60 s")
reset_world()
local before = cfg.get("allowed_players")
local n = join("n")
check(admin.access_gate(n, NOW) == false and n.access == nil, "undecided, held")
advance(60)
check(admin.access_gate(n, NOW) == false and n.access == "pw" and last_of("ACCESS", "n").f[1] == "pw", "60 s: asked")
handlers.JPW({ PW }, n.pc)
check(n.access == "ok" and cfg.get("allowed_players") == before, "the right password: in, not listed (it never said who it is)")

section("a new password")
admin.set_join_password("Новый 2")
local a3 = join("a3")
check(admin.on_early_id(a3, "Ann", sid(10)) == false and a3.access == "ok", "Ann (listed) still gets in")
local o = join("o")
admin.on_early_id(o, "Olga", sid(400))
handlers.JPW({ PW }, o.pc)
check(fields(last_of("KICK", "o")) == "6|1|0", "the old password: wrong")
local cl = join("cl")
admin.on_early_id(cl, "Cleo", sid(410))
check(cl.access == "pw" and last_of("ACCESS", "cl").f[1] == "pw", "Cleo is asked")
admin.set_join_password("")
check(cfg.get("join_password") == "" and said_last("access_pw_cleared").kind == "warn", "cleared: saved, the host warned")
handlers.JPW({ "Новый 2" }, cl.pc)
check(fields(last_of("KICK", "cl")) == "6|3|0" and admin.recent()[1].name == "Cleo" and admin.recent()[1].reason == "pw_unset",
    "cleared while she was asked: her answer -> KICK|6|3 (unset), «пароль не задан»")
admin.set_join_password(PW)

section("invite only, the Steam tab's Invite")
admin.set_access_mode("list")
check(admin.invited("Kate", sid(500)) == true and cfg.get("allowed_players"):find(sid(500) .. ":Kate", 1, true), "Invite: on the list")
local kt = join("kt")
check(admin.on_early_id(kt, "Kate", sid(500)) == false and kt.access == "ok", "invite only: the invited friend gets in")
local st = join("st")
check(admin.on_early_id(st, "Stranger", sid(501)) == true and fields(last_of("KICK", "st")) == "2", "anyone else: KICK|2")
admin.set_access_mode("password")
local kt2 = join("kt2")
check(admin.on_early_id(kt2, "Kate", sid(500)) == false and #sent_of("ACCESS", "kt2") == 0, "password: the invited friend is not asked")

section("a password not asked for")
local u = join("u")
local nl = #lines
handlers.JPW({ PW }, u.pc)
check(u.access == nil and logged("not asked for now: ignored") ~= nil, "before it is asked: ignored")
handlers.JPW({ PW }, actor("ghost"))
check(#lines > nl and logged("an unknown connection") ~= nil, "an unknown connection: ignored")
check(not log_has_secret(PW) and not log_has_secret("Новый 2"), "no password anywhere in the host's log")

-- ------------------------------------------------------------------ client
section("client: passwords kept per join target")
S.role, S.client = "client", {}
cfg.set("host_passwords", "")
check(admin.save_pw("26.1.2.3:7777", PW) and admin.save_pw("steam:" .. sid(777), "a;b=c%d"),
    "kept for an IP and for a Steam friend")
check(cfg.get("host_passwords") == "26.1.2.3:7777=" .. PW .. ";steam:" .. sid(777) .. "=a%3Bb%3Dc%25d",
    "config: <target>=<password>; ';' '=' '%' escaped: " .. cfg.get("host_passwords"))
check(admin.saved_pw("STEAM:" .. sid(777)) == "a;b=c%d" and admin.saved_pw("26.1.2.3:7777") == PW and admin.saved_pw("26.1.2.3:7778") == "",
    "read back (any case); another port: none")
check(admin.pw_target(" " .. sid(777) .. " ", 7777) == "steam:" .. sid(777) and admin.pw_target("steam." .. sid(777), 1) == "steam:" .. sid(777)
    and admin.pw_target("Host.LAN", 7778) == "host.lan:7778" and admin.pw_target("", 7777) == "", "targets as sdc_session.join names them")
admin.save_pw("26.1.2.3:7777", "")
check(admin.saved_pw("26.1.2.3:7777") == "" and not cfg.get("host_passwords"):find("26.1.2.3", 1, true), "an empty password: forgotten")
for k = 1, 25 do admin.save_pw("10.0.0." .. k .. ":7777", "p" .. k) end
check(admin.saved_pw("10.0.0.25:7777") == "p25" and admin.saved_pw("10.0.0.6:7777") == "p6" and admin.saved_pw("10.0.0.5:7777") == ""
    and admin.saved_pw("steam:" .. sid(777)) == "", "at most 20 kept: the oldest dropped")

section("client: the answer to ACCESS|pw")
admin.save_pw("26.1.2.3:7777", PW)
admin.save_pw("steam:" .. sid(777), "steam-pw")
S.join = { code = "26.1.2.3:7777", target = "26.1.2.3:7777", via = "ip" }
local nl2 = #lines
handlers.ACCESS({ "pw" })
check(last_of("JPW", "host").f[1] == PW, "an IP join: the password kept for that address")
check(logged("sent the one kept for 26.1.2.3:7777") ~= nil and not log_has_secret(PW), "logged without the password")
handlers.ACCESS({ "pw" })
check(#sent_of("JPW", "host") == 2 and #lines == nl2 + 1, "asked again: answered again, logged once")
S.client = {}
S.join = { code = "steam:" .. sid(777), target = "127.0.0.1:27500", via = "steam" }
handlers.ACCESS({ "pw" })
check(last_of("JPW", "host").f[1] == "steam-pw", "a Steam join: the friend's own password, not the IP one")
S.client = {}
S.join = { code = "10.0.0.99:7777", target = "10.0.0.99:7777", via = "ip" }
handlers.ACCESS({ "pw" })
check(last_of("JPW", "host").f[1] == "" and logged("none kept for 10.0.0.99:7777: an empty answer") ~= nil, "nothing kept: an empty answer")
S.client = {}
S.join = { target = nil, started_at = 0, attempts = 0 }   -- as after the game's start: no join from it yet
cfg.set("host_ip", "26.1.2.3")
cfg.set("port", 7777)
local nl3 = #lines
handlers.ACCESS({ "pw" })
check(last_of("JPW", "host").f[1] == "" and admin.saved_pw("26.1.2.3:7777") == PW,
    "no join recorded (a console open to some host): an empty answer, not the IP tab's address's password")
check(#lines == nl3 + 1 and lines[#lines]:find("no join target known: an empty answer", 1, true) ~= nil,
    "the log says no join target is known")
S.client = {}
S.join = { code = "", target = "" }
handlers.ACCESS({ "pw" })
check(last_of("JPW", "host").f[1] == "", "an empty code / target: the same")
check(S.client.access == nil, "ACCESS|pw leaves the wait / ok state alone")

section("client: KICK|6")
local KICKS = {
    { { "6", "0", "0" }, "access_pw_need_you", nil, "Хост требует пароль для входа." },
    { { "6", "1", "0" }, "access_pw_wrong_you", nil, "Неверный пароль." },
    { { "6", "2", "7" }, "access_pw_locked_you", 7, "Слишком много неверных паролей — попробуйте через 7 мин." },
    { { "6", "3", "0" }, "access_pw_unset_you", nil, "Хост ещё не задал пароль для входа — попросите его задать пароль на вкладке «Мир»." },
    { { "6" }, "access_pw_need_you", nil, "Хост требует пароль для входа." },
    -- a newer sub-code than this mod knows: the password prompt (as 0.7.3 mods read 3)
    { { "6", "9", "0" }, "access_pw_need_you", nil, "Хост требует пароль для входа." },
}
for _, kc in ipairs(KICKS) do
    stopped, execs = nil, {}
    handlers.KICK(kc[1])
    local sl = said[#said]
    check(sl.key == kc[2] and sl.args[1] == kc[3] and sl.kind == "warn" and log.tr(sl.key, table.unpack(sl.args)) == kc[4],
        "KICK|" .. table.concat(kc[1], "|") .. ": «" .. log.tr(sl.key, table.unpack(sl.args)) .. "»")
    check(stopped ~= nil and execs[1] == "disconnect" and S.disconnect_requested == true, "  the automatic join stops, back to the menu")
end
handlers.KICK({ "9" })
check(said[#said].key == "admin_kicked_you", "an unknown (newer) code reads as a kick, as an older mod reads 6")
check(logged("KICK|6|1") ~= nil, "the log names the sub-code")
local s1 = id_soon
S.client = { access = "wait" }
handlers.ACCESS({ "ok" })
check(id_soon == s1 + 1 and said[#said].key == "access_ok_you", "ACCESS|ok: the id goes again at once (sdc_persist.id_soon)")

-- ------------------------------------------------------------------ the real sdc_session
-- A join asked from the panel is the connection that begins soon after it,
-- and only its first one (sdc_session.bind_join). A console "open" to host
-- B long after a join to host A, or right after A's connection ended, must
-- not get A's password (the old join's address is forgotten).
section("client: an old join is not a later connection (the real sdc_session)")
package.loaded["sdc_session"] = nil
local function auto_stub()
    return setmetatable({}, { __index = function(t, k)
        local fn = function() return nil end
        rawset(t, k, fn)
        return fn
    end })
end
-- every sdc_ module not loaded yet (sync, ctx, items, ai ...): an automatic stub
local function stub_searcher(name)
    if name == "sdc_session" or not name:match("^sdc_") then return nil end
    return function() return auto_stub() end
end
table.insert(package.searchers, 2, stub_searcher)
players.init = players.init or function() end
local ROLE = "standalone"
local host_role = ue_stub.net_role   -- back after this part (sdc_net's hook below needs "host")
ue_stub.net_role = function() return ROLE end
ue_stub.map_name = function() return "PersistentLevel" end
ue_stub.in_main_menu = function() return true end
ue_stub.world_context = function() return nil end
ue_stub.find_first = function() return nil end
ue_stub.has_pending_connection = function() return false end
local steam_stub = package.loaded["sdc_steam"]
steam_stub.take_launch_code = function() return nil end
steam_stub.own_id = function() return nil end
steam_stub.set_presence = function() end
cfg.set("listen_on_load", false)
cfg.set("auto_join", false)
cfg.set("auto_host", false)
local okr, rsession = pcall(require, "sdc_session")
for i, f in ipairs(package.searchers) do if f == stub_searcher then table.remove(package.searchers, i) break end end
check(okr and type(rsession) == "table" and type(rsession.join) == "function", "the real sdc_session loads: " .. tostring(okr and "" or rsession))
local SS = rsession.state
admin.install(SS)
local function stick(n) for _ = 1, n or 1 do rsession.tick() end end
local function as_role(r) ROLE = r; stick() end
local A, A_PW = "26.1.1.1:7777", "pw-A"
admin.save_pw(A, A_PW)
admin.save_pw("steam:" .. sid(777), "steam-pw")
local function answer()
    handlers.ACCESS({ "pw" })
    return last_of("JPW", "host").f[1]
end
as_role("standalone")
-- 1. a join from the panel to A: its connection answers with A's password
rsession.join("26.1.1.1", 7777, false)
check(SS.join.code == A and execs[#execs] == "open " .. A, "the IP tab's join to A: recorded, opened")
advance(2)
as_role("client")
check(SS.join.code == A and SS.join.bound == true, "  its connection began 2 s later: it is that join")
check(answer() == A_PW, "  A asks: A's own password")
-- 2. Ann leaves A; 15 minutes later a console "open" to host B
as_role("standalone")
advance(15 * 60)
local nl4 = #lines
as_role("client")
check(SS.join.code == nil and SS.join.target == nil and SS.join.via == nil,
    "15 min later a connection with no join from the panel (console open to B): the old join's address forgotten")
check(logged("join: this connection is not the join to " .. A .. " (asked 902 s ago; that join had its connection already): its address is forgotten") ~= nil,
    "  the log says why")
check(answer() == "" and #lines > nl4 and lines[#lines]:find("no join target known: an empty answer", 1, true) ~= nil,
    "  B asks: an empty answer, never A's password; logged")
check(admin.saved_pw(A) == A_PW, "  A's password still kept for A")
-- 3. a second connection right after the join's own one (a console open 30 s later)
as_role("standalone")
rsession.join("26.1.1.1", 7777, false)
advance(1)
as_role("client")
check(answer() == A_PW, "a new join to A: A's password again")
as_role("standalone")
advance(30)
as_role("client")
check(SS.join.code == nil and logged("(asked 31 s ago; that join had its connection already)") ~= nil and answer() == "",
    "  30 s after it ended, another connection: not that join (an empty answer)")
-- 4. a slow start (connection + a slow load) is still the join; past 5 min it is not
as_role("standalone")
rsession.join("26.1.1.1", 7777, false)
advance(240)
as_role("client")
check(SS.join.bound == true and answer() == A_PW, "a connection 240 s after the join (a slow load): still that join")
as_role("standalone")
rsession.join("26.1.1.1", 7777, false)
advance(301)
as_role("client")
check(SS.join.code == nil and logged("not the join to " .. A .. " (asked 301 s ago): its address") ~= nil and answer() == "",
    "301 s after the join (its first connection): not that join any more")
-- a join that never came to a connection (a Steam tunnel never up), then a console open 15 min later
as_role("standalone")
rsession.join("26.1.1.1", 7777, false)
advance(15 * 60)
as_role("client")
check(SS.join.code == nil and answer() == "", "a join with no connection of its own, 15 min later a console open: not that join")
-- 5. a Steam join: the tunnel takes its time, join_tunnel opens it (the join again, fresh)
as_role("standalone")
package.loaded["sdc_steamlink"] = { usable = function() return true end, request_tunnel = function() return true end }
rsession.join(sid(777), 7777, false)
check(SS.join.code == "steam:" .. sid(777), "a Steam join: the friend's code")
advance(150)
check(rsession.join_tunnel(27500, sid(777)) == true and SS.join.target == "127.0.0.1:27500" and SS.join.code == "steam:" .. sid(777),
    "  the tunnel up 150 s later: opened through it, the code stays")
advance(1)
as_role("client")
check(SS.join.bound == true and answer() == "steam-pw", "  its connection: that join, the friend's own password")
as_role("standalone")
-- the record forgotten while the tunnel was built (a console open meanwhile):
-- the tunnel's connection is still that friend's
rsession.join(sid(777), 7777, false)
advance(310)
as_role("client")
check(SS.join.code == nil, "  a console open 310 s into a Steam join: the Steam join's record forgotten")
as_role("standalone")
check(rsession.join_tunnel(27501, sid(777)) == true and SS.join.code == "steam:" .. sid(777),
    "  then the tunnel up: the friend's code again (from the tunnel's friend)")
advance(1)
as_role("client")
check(SS.join.bound == true and answer() == "steam-pw", "  its connection: the friend's own password")
as_role("standalone")
package.loaded["sdc_steamlink"] = nil
ue_stub.net_role = host_role
admin.install(S)

-- ------------------------------------------------------------------ sdc_net
section("sdc_net: JPW never in the log")
package.loaded["sdc_net"] = nil
cfg.set("net_send_budget", false)
local dbg = {}
log.debug = function(fmt, ...) dbg[#dbg + 1] = string.format(fmt, ...) end
log.debug_enabled = true
local rnet = require("sdc_net")
check(rnet ~= net_stub and rnet.SECRET and rnet.SECRET.JPW == true, "the real sdc_net: JPW is secret")
local wire = {}
CLIENT_PC = { key = "client_pc", ServerExecRPC = function(_, msg) wire[#wire + 1] = msg end }
rnet.send_to_host("JPW", PW)
check(wire[1] == "SDC1|JPW|" .. PW, "sent whole")
local dl = dbg[#dbg] or ""
check(dl:find("SDC1|JPW|<hidden>", 1, true) ~= nil and not dl:find(PW, 1, true), "its debug line hides it: " .. dl)
rnet.send_to_host("PSID", "x")
check((dbg[#dbg] or ""):find("SDC1|PSID|x", 1, true) ~= nil, "other kinds logged as before")
local got
rnet.on("JPW", function(fl) got = fl[1] end)
rnet.install_hooks()
local hook = hooks["/Script/Engine.PlayerController:ServerExecRPC"]
local HPC = { key = "remote_pc", NetConnection = { key = "conn" } }
hook({ get = function() return HPC end }, { get = function() return "SDC1|JPW|" .. PW end })
dl = dbg[#dbg] or ""
check(got == PW and dl:find("SDC1|JPW|<hidden>", 1, true) ~= nil and not dl:find(PW, 1, true), "received: handled, hidden in the log")
local all = table.concat(dbg, "\n") .. table.concat(lines, "\n")
check(not all:find(PW, 1, true), "no password in any log line")

print = real_print
io.write(string.format("join_password: %d checks, %d failed\n", checks, fails))
io.write(fails == 0 and "ALL OK\n" or "SOME FAILED\n")
os.exit(fails == 0 and 0 or 1)
