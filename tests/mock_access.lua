-- Mock test: who may join the host's world (sdc_admin 0.7.3, config
-- join_access open | approve | list, allowed_players, max_players).
--   host: open = as before; list; approve (wait, Allow, Deny, 120 s);
--   max_players; the ban list first; the hello as the fallback (its
--   SteamID awaited a few seconds); the mode switched while players wait;
--   the panel's lists (recent, allowed, bans), Save the world now;
--   max_players and a reconnect before the old connection is dropped;
--   approve / list: no id - no character, decided without it at 60 s (a
--   late id still counts); a friend invited through Steam goes on the list
--   client: KICK|2..5 (texts, auto join stopped, disconnect), ACCESS|wait/ok
-- usage: lua mock_access.lua <scripts dir>
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

local NOW = 1000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end

-- delayed calls with a fake clock (ms)
local T = 0
local delayed = {}
local function advance_ms(ms)
    T = T + ms
    local keep, due = {}, {}
    for _, d in ipairs(delayed) do if d.at <= T then due[#due + 1] = d else keep[#keep + 1] = d end end
    delayed = keep
    for _, d in ipairs(due) do d.fn() end
end

-- net
local sent, handlers = {}, {}
package.loaded["sdc_net"] = {
    on = function(kind, fn) handlers[kind] = fn end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end,
    broadcast = function(pcs, kind, ...)
        for _, pc in ipairs(pcs) do sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } end
    end,
}
local function sent_of(kind, to)
    local out = {}
    for _, m in ipairs(sent) do if m.kind == kind and (to == nil or m.to == to) then out[#out + 1] = m end end
    return out
end
local function last_of(kind, to)
    local l = sent_of(kind, to)
    return l[#l] or { f = {} }
end

-- engine
local execs = {}
package.loaded["sdc_ue"] = {
    valid = function(o) return type(o) == "table" and not o.destroyed end,
    delay = function(_, ms, fn) delayed[#delayed + 1] = { at = T + ms, fn = fn } end,
    exec = function(cmd) execs[#execs + 1] = cmd end,
    pawn_of = function(pc) return pc.pawn end,
    local_pawn = function() return nil end,
    prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end,
    ksl = function() return nil end,
    find_object = function() return nil end,
}
local SIDS = {}
package.loaded["sdc_persist"] = { steam_of = function(key) return SIDS[key] end }
local players = {}                                   -- sdc_players: the admin puts its gate here
package.loaded["sdc_players"] = players

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
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then return l end end
    return nil
end
local cfg = require("sdc_config")
local saves = 0
cfg.save = function() saves = saves + 1 return true end   -- no config file is written
local i18n = require("sdc_i18n")

local admin = require("sdc_admin")
local S = { role = "host", remote = {}, remote_pcs = {} }
admin.install(S)
check(players.access_gate == admin.access_gate, "the access gate is put into sdc_players")
check(handlers.KICK and handlers.ACCESS and handlers.RULES, "KICK / ACCESS / RULES handlers")

local n_idx = 0
local function actor(key)
    local a = { key = key, calls = {} }
    a.K2_DestroyActor = function(self) self.destroyed = true end
    a.ClientReturnToMainMenuWithTextReason = function(self, txt) self.calls[#self.calls + 1] = "menu:" .. tostring(txt) end
    return a
end
-- a player connects: its session record (no hello, no character yet)
local function join(key)
    n_idx = n_idx + 1
    local pc = actor(key)
    S.remote[key] = { key = key, pc = pc, index = n_idx, name = "Player " .. n_idx, hello = false, joined_at = NOW,
                      pawnless_since = NOW, spawned_once = false }
    S.remote_pcs[#S.remote_pcs + 1] = pc
    return S.remote[key]
end
local function reset_world()
    S.remote, S.remote_pcs = {}, {}
end

print("settings and strings")
check(cfg.get("join_access") == "open" and cfg.get("allowed_players") == "" and cfg.get("max_players") == 0,
    "defaults: open, an empty list, no limit")
local rows = { join_access = "string", allowed_players = "string", max_players = "int" }
for key, kind in pairs(rows) do
    local row = i18n.schema_row(key)
    check(row and row[2] == kind and type(row[4]) == "string" and row[4]:find("[\208\209]") ~= nil
        and type(i18n.DESC_EN[key]) == "string" and i18n.GROUP_OF[key] == nil, key .. ": " .. kind .. ", RU + EN, no group")
end
check(not i18n.schema_row("banned_players")[4]:find("в настройках", 1, true)
    and not i18n.DESC_EN.banned_players:find("in the settings", 1, true), "banned_players: bans are lifted on the World tab")
local new_keys = { "admin_unbanned_one", "access_ask", "access_allowed", "access_denied", "access_timeout",
                   "access_not_listed", "access_full", "access_listed", "access_unlisted", "world_saved",
                   "world_save_failed", "access_wait_you", "access_ok_you", "access_list_you", "access_denied_you",
                   "access_timeout_you", "access_full_you" }
local bad = {}
for _, k in ipairs(new_keys) do
    local t = log.TEXT[k]
    if not (t and t[1] and t[2] and not t[1]:find("[\208\209]") and t[2]:find("[\208\209]")
        and i18n.SAY_CLASS[k] == "game") then bad[#bad + 1] = k end
end
check(#bad == 0, "new notices: English log, Russian screen, class game: " .. table.concat(bad, ","))
check(log.ascii("a → b") == "a -> b", "the log writes → as ->")

print("open (the default): as before")
local a1 = join("a1pc")
sent, said = {}, {}
check(admin.on_early_id(a1, "Ann", "76561190000000001") == false, "the early id lets the player in")
check(#sent == 0 and #said == 0, "no message to anyone")
check(admin.access_gate(a1) == true and a1.name == "Player 1", "its first character may spawn; the record unchanged")
check(admin.on_hello(a1) == false and #sent == 0, "its hello: as before")
local a2 = join("a2pc")
a2.hello, a2.name = true, "Abe"
check(admin.on_hello(a2) == false and a2.access == "ok" and #said == 0, "no early id: the hello lets it in at once")
check(admin.waiting()[1] == nil and admin.recent()[1] == nil, "nobody waits, nobody refused")

print("list: only players on allowed_players")
reset_world()
cfg.set("join_access", "list")
cfg.set("allowed_players", "76561190000000002:Bob;Carl")
local b = join("bpc")
check(admin.on_early_id(b, "Bobby", "76561190000000002") == false, "on the list by SteamID (another name): in")
local c = join("cpc")
check(admin.on_early_id(c, "carl", nil) == false, "a name entry matches in any case")
local d = join("dpc")
sent, said = {}, {}
check(admin.on_early_id(d, "Bob", "76561190000000099") == true, "Bob with another SteamID: an entry with a SteamID never matches by name")
check(last_of("KICK", "dpc").f[1] == "2", "KICK|2 (not on the list)")
check(said_n("access_not_listed") == 1 and said_last("access_not_listed").args[1] == "Bob", "the host is told once")
check(#sent_of("MSG") == 0 and said_n("admin_kick_done") == 0, "no kick notice, the others hear nothing")
check(d.access == "refused" and admin.access_gate(d) == false, "refused: no first character")
local rc = admin.recent()[1]
check(rc and rc.name == "Bob" and rc.sid == "76561190000000099" and rc.reason == "list", "remembered for the panel")
check(admin.on_early_id(d, "Bob", "76561190000000099") == true and #sent_of("KICK", "dpc") == 1, "its next id: no second KICK")
check(admin.on_hello(d) == true, "a refused player's hello: no join announcements")
check(logged("is not on allowed_players (join_access list): not let in (early id)") ~= nil, "log line")
advance_ms(6000)
check(d.pc.calls[1] == "menu:Not let in by the host", "still there after 6 s: the engine's return to the menu says why")
advance_ms(6000)

print("approve: the host decides")
reset_world()
cfg.set("join_access", "approve")
local e = join("epc")
sent, said, saves = {}, {}, 0
check(admin.on_early_id(e, "Eve", "76561190000000005") == true, "not on the list: held (on_early_id true)")
check(last_of("ACCESS", "epc").f[1] == "wait" and #sent_of("KICK", "epc") == 0, "ACCESS|wait to the client")
local ask = said_last("access_ask")
check(said_n("access_ask") == 1 and ask.args[1] == "Eve" and ask.args[2] == "F7" and ask.kind == "info",
    "the host: one info notice 'Eve wants to join: F7 → World'")
check(log.tr("access_ask", "Eve", "F7") == "Eve хочет войти в мир: F7 → «Мир».", "its Russian text: " .. log.tr("access_ask", "Eve", "F7"))
check(e.name == "Eve" and e.access == "wait", "the record shows the name before the hello")
check(admin.access_gate(e) == false, "its first character waits")
NOW = NOW + 4
check(admin.on_early_id(e, "Eve", "76561190000000005") == true and said_n("access_ask") == 1
    and #sent_of("ACCESS", "epc") == 1, "the id again (every 4 s): still held, nothing said or sent twice")
local w = admin.waiting()
check(#w == 1 and w[1].key == "epc" and w[1].name == "Eve" and w[1].secs == 4, "waiting(): Eve for 4 s")
local f = join("fpc")
check(admin.on_early_id(f, "Bob", "76561190000000002") == false and f.access == "ok", "a listed player gets in at once")
local f2 = join("f2pc")
check(admin.on_early_id(f2, "Zed", nil) == true and #admin.waiting() == 2 and admin.waiting()[1].key == "epc",
    "a second one waits too; the longest waiting first")
-- Allow
sent, said = {}, {}
check(admin.allow("epc") == true, "Allow")
check(last_of("ACCESS", "epc").f[1] == "ok" and e.access == "ok" and e.access_ok_at == NOW, "ACCESS|ok; let in now")
check(cfg.get("allowed_players"):find("76561190000000005:Eve", 1, true) ~= nil and saves >= 1,
    "Eve goes on the list (SteamID:Name), saved: " .. cfg.get("allowed_players"))
check(said_n("access_allowed") == 1 and said_last("access_allowed").args[1] == "Eve", "the host: Eve let in")
check(admin.on_early_id(e, "Eve", "76561190000000005") == false, "its next id: in (sdc_persist gives the verdict)")
check(admin.access_gate(e) == true and admin.allow("epc") == false and admin.deny("epc") == false,
    "its character may spawn; Allow / Deny again: nothing")
-- Deny
sent, said = {}, {}
check(admin.deny("f2pc") == true and last_of("KICK", "f2pc").f[1] == "3", "Deny: KICK|3")
check(said_n("access_denied") == 1 and admin.recent()[1].name == "Zed" and admin.recent()[1].reason == "denied",
    "the host is told, the player remembered")
check(#sent_of("MSG") == 0 and not cfg.get("allowed_players"):find("Zed", 1, true), "no broadcast, not on the list")
check(admin.deny("nobody") == false and admin.allow("nobody") == false, "no such player: false")
-- no answer
local h = join("hpc")
admin.on_early_id(h, "Hana", nil)
sent, said = {}, {}
NOW = NOW + 119
admin.tick()
check(#sent_of("KICK", "hpc") == 0 and h.access == "wait", "119 s: still waiting")
NOW = NOW + 1
admin.tick()
check(last_of("KICK", "hpc").f[1] == "4" and said_n("access_timeout") == 1 and said_last("access_timeout").kind == "warn",
    "120 s without an answer: KICK|4, the host warned")
check(admin.recent()[1].name == "Hana" and admin.recent()[1].reason == "timeout", "remembered: no answer")

print("approve: the mode switched while players wait")
reset_world()
local i1 = join("i1pc")
admin.on_early_id(i1, "Ivy", nil)
local j1 = join("j1pc")
admin.on_early_id(j1, "Jon", nil)
sent, saves = {}, 0
check(admin.set_access_mode("open") == true and cfg.get("join_access") == "open" and saves == 1, "switched to open, saved")
check(i1.access == "ok" and j1.access == "ok" and last_of("ACCESS", "i1pc").f[1] == "ok"
    and last_of("ACCESS", "j1pc").f[1] == "ok", "the waiting are let in at once")
admin.set_access_mode("approve")
local k1 = join("k1pc")
admin.on_early_id(k1, "Kim", nil)
sent = {}
admin.set_access_mode("list")
check(last_of("KICK", "k1pc").f[1] == "2", "switched to list: a waiting player not on the list is turned away")
check(admin.set_access_mode("bogus") == false and cfg.get("join_access") == "list", "an unknown mode: refused")
cfg.set("join_access", " Approve ")
check(admin.access_mode() == "approve", "the config value: case and spaces do not matter")
cfg.set("join_access", "everyone")
check(admin.access_mode() == "open", "anything else: open")

print("max_players: the host and everyone in or waiting count")
reset_world()
cfg.set("join_access", "open")
cfg.set("max_players", 3)
local p1 = join("p1")
check(admin.on_early_id(p1, "P1", nil) == false, "1 + 1 of 3: in")
local p2 = join("p2")
check(admin.on_early_id(p2, "P2", nil) == false, "1 + 2 of 3: in")
local p3 = join("p3")
sent, said = {}, {}
check(admin.on_early_id(p3, "P3", nil) == true and last_of("KICK", "p3").f[1] == "5", "the 4th: KICK|5")
local full = said_last("access_full")
check(full.args[1] == 3 and full.args[2] == 3 and full.args[3] == "P3", "the host: full (3 of 3), P3 not let in")
check(admin.recent()[1].reason == "full", "remembered: world full")
local still_connecting = join("p4")   -- connecting, not decided: does not count
check(admin.on_early_id(join("p5"), "P5", nil) == true, "a refused player and one still connecting do not free a place")
S.remote.p2 = nil                     -- P2 left
check(admin.on_early_id(still_connecting, "P4", nil) == false, "a player left: its place is free")
cfg.set("banned_players", "Ban")
sent = {}
check(admin.on_early_id(join("p6"), "Ban", nil) == true and last_of("KICK", "p6").f[1] == "1",
    "full, but banned: the ban comes first (KICK|1)")
cfg.set("banned_players", "")
reset_world()
cfg.set("join_access", "approve")
local q1 = join("q1")
admin.on_early_id(q1, "Q1", nil)                    -- waiting
local q2 = join("q2")
q2.hello = true                                     -- in the world (decided before)
q2.access = "ok"
sent = {}
check(admin.on_early_id(join("q3"), "Q3", nil) == true and last_of("KICK", "q3").f[1] == "5",
    "a waiting player counts: 1 + 2 of 3, the next one is turned away")
check(admin.allow("q1") == true and q1.access == "ok", "the waiting one can always be let in (its place was kept)")
cfg.set("max_players", 0)

print("the hello as the fallback (no early id: an older mod, persist_early_id off)")
reset_world()
cfg.set("join_access", "list")
cfg.set("allowed_players", "76561190000000002:Bob")
local r1 = join("r1pc")
r1.hello, r1.name, r1.spawned_once = true, "Bob", true      -- its character came after 25 s
sent = {}
check(admin.on_hello(r1) == false and r1.access == nil and r1.access_hello_at == NOW,
    "a hello before its SteamID: not decided yet (an entry may need it)")
NOW = NOW + 2
SIDS.r1pc = "76561190000000002"
admin.tick()
check(r1.access == "ok" and #sent_of("KICK", "r1pc") == 0, "its SteamID came: on the list, in")
local r2 = join("r2pc")
r2.hello, r2.name, r2.spawned_once = true, "Rex", true
admin.on_hello(r2)
NOW = NOW + 5
admin.tick()
check(r2.access == nil and #sent_of("KICK", "r2pc") == 0, "5 s: its SteamID is still awaited")
NOW = NOW + 1
admin.tick()
check(last_of("KICK", "r2pc").f[1] == "2", "6 s without a SteamID: decided by its name: not on the list")
local r3 = join("r3pc")
r3.hello, r3.name = true, "Ray"
admin.on_early_id(r3, "Ray", "76561190000000003")   -- its early id came first (persist had no record yet)
check(r3.access == "refused", "list: refused at its id")
local r4 = join("r4pc")
r4.hello, r4.name, r4.spawned_once = true, "Bob", true
SIDS.r4pc = "76561190000000002"
check(admin.on_hello(r4) == false and r4.access == "ok", "a hello with its SteamID known: decided at once")
cfg.set("join_access", "approve")
local r5 = join("r5pc")
r5.spawned_once = true                               -- its character is already in the world
sent = {}
check(admin.on_early_id(r5, "Sam", "76561190000000007") == false and r5.access == "wait"
    and last_of("ACCESS", "r5pc").f[1] == "wait", "approve, its character already there: waits, nothing to hold")
SIDS.r1pc, SIDS.r4pc = nil, nil

print("the panel's lists")
cfg.set("allowed_players", "76561190000000002:Bob;Carl")
check(#admin.allowed() == 2 and admin.allowed()[2].name == "Carl", "allowed(): the entries")
check(admin.entry_id(admin.allowed()[1]) == "76561190000000002" and admin.entry_id(admin.allowed()[2]) == "n:carl", "entry ids")
said = {}
check(admin.list_remove("n:carl") == "Carl" and cfg.get("allowed_players") == "76561190000000002:Bob"
    and said_n("access_unlisted") == 1, "Remove by its id")
check(admin.list_remove("76561190000000002") == "Bob" and cfg.get("allowed_players") == "", "Remove a SteamID entry")
check(admin.list_remove("nope") == nil, "an unknown id: nothing")
check(admin.list_add("Dana", nil) == true and admin.list_add("dana", nil) == false and cfg.get("allowed_players") == "Dana",
    "Add to list (a refused player); no duplicate")
check(admin.list_add("Eve", "76561190000000005") == true and admin.is_allowed("Someone", "76561190000000005"),
    "a SteamID entry")
cfg.set("banned_players", "76561190000000011:Bob;Ivan")
said = {}
check(admin.unban("n:ivan") == "Ivan" and cfg.get("banned_players") == "76561190000000011:Bob"
    and said_n("admin_unbanned_one") == 1, "Unban one")
check(admin.unban("nope") == nil and #admin.bans() == 1, "an unknown ban id: nothing")
reset_world()
cfg.set("join_access", "list")
for n = 1, 10 do admin.on_early_id(join("x" .. n), "X" .. n, nil) end
admin.on_early_id(join("x11"), "X3", nil)
local rl = admin.recent()
check(#rl == 8 and rl[1].name == "X3" and rl[2].name == "X10", "recent: at most 8, newest first, one entry a player")
S.role = "client"
admin.tick()
S.role = "host"
check(#admin.recent() == 0, "not the host any more: forgotten")
cfg.set("join_access", "open")

print("Save the world now")
local sc = {}
package.loaded["sdc_savecheck"] = { save_now = function(reason, done) sc[#sc + 1] = { reason = reason, done = done } end }
said = {}
check(admin.save_world() == true and admin.saving() and #sc == 1, "sdc_savecheck.save_now is asked")
check(admin.save_world() == false and #sc == 1, "one at a time")
sc[1].done(true, nil, "Slot_1")
check(not admin.saving() and said_n("world_saved") == 1, "done: the host is told")
admin.save_world()
sc[2].done(false, "no character")
check(said_n("world_save_failed") == 1 and said_last("world_save_failed").kind == "warn", "failed: a warning")
package.loaded["sdc_savecheck"] = nil
check(admin.save_world() == false and said_n("world_save_failed") == 2, "no sdc_savecheck: failed at once")
S.role = "client"
check(admin.save_world() == false, "a client: no")
S.role = "host"

print("max_players: a player back before the engine dropped its old connection")
reset_world()
cfg.set("join_access", "open")
cfg.set("max_players", 2)
local bob_old = join("bob_old")
check(admin.on_early_id(bob_old, "Bob", "76561190000000002") == false, "Bob in: 1 + 1 of 2")
bob_old.hello, bob_old.spawned_once, bob_old.name = true, true, "Bob"
SIDS.bob_old = "76561190000000002"
local bob_new = join("bob_new")
sent, said, lines = {}, {}, {}
check(admin.on_early_id(bob_new, "Bob", "76561190000000002") == false and bob_new.access == "ok"
    and #sent_of("KICK", "bob_new") == 0 and said_n("access_full") == 0,
    "Bob back on a new connection, the old one still open: let in, not 'the world is full'")
check(logged("Bob: its earlier connection bob_old is still open") ~= nil, "log line")
sent = {}
check(admin.on_early_id(join("eve_x"), "Eve", "76561190000000005") == true and last_of("KICK", "eve_x").f[1] == "5",
    "someone else: still full")
SIDS.bob_old = nil
reset_world()
local c_old = join("c_old")
admin.on_early_id(c_old, "Carl", nil)
c_old.hello, c_old.name = true, "Carl"
check(admin.on_early_id(join("c_new"), "carl", nil) == false, "no SteamID on either side: the same name is the same player")
reset_world()
admin.on_early_id(join("d_old"), "Dan", "76561190000000008")
check(admin.on_early_id(join("d_new"), "Dan", nil) == true, "a SteamID on one side only: someone else (full)")
cfg.set("max_players", 0)

print("approve / list: no id from the player - no character, then decided without it")
reset_world()
cfg.set("join_access", "list")
cfg.set("allowed_players", "76561190000000002:Bob")
local u1 = join("u1pc")
sent, said = {}, {}
check(admin.access_gate(u1, NOW) == false and u1.access == nil, "list, undecided: no first character")
check(admin.access_gate(u1, NOW + 59) == false and u1.access == nil and #sent == 0, "59 s without an id: held, undecided")
check(admin.access_gate(u1, NOW + 60) == false and u1.access == "refused" and last_of("KICK", "u1pc").f[1] == "2",
    "60 s without an id: refused (KICK|2), never a character")
check(admin.recent()[1].name == u1.name and admin.recent()[1].guess == true, "remembered as refused before it said who it is")
check(logged("not on allowed_players (join_access list): not let in (no id within 60 s)") ~= nil, "log line")
cfg.set("join_access", "approve")
local u2 = join("u2pc")
sent, said = {}, {}
check(admin.access_gate(u2, NOW + 60) == false and u2.access == "wait" and last_of("ACCESS", "u2pc").f[1] == "wait"
    and said_n("access_ask") == 1, "approve, no id within 60 s: it waits for the host's Allow / Deny")
check(admin.on_early_id(u2, "Bob", "76561190000000002") == false and u2.access == "ok" and u2.name == "Bob"
    and last_of("ACCESS", "u2pc").f[1] == "ok", "its id came late and it is on the list: let in")
local u3 = join("u3pc")
admin.access_gate(u3, NOW + 60)
check(admin.on_early_id(u3, "Zoe", "76561190000000009") == true and u3.access == "wait", "its id came late, not on the list: still waits")
local w3
for _, w in ipairs(admin.waiting()) do if w.key == "u3pc" then w3 = w end end
check(w3 and w3.name == "Zoe" and w3.sid == "76561190000000009", "the waiting list shows who it says it is now")
check(admin.allow("u3pc") and cfg.get("allowed_players"):find("76561190000000009:Zoe", 1, true) ~= nil, "Allow: on the list by its SteamID")
local u4 = join("u4pc")
admin.access_gate(u4, NOW + 60)
local list_before = cfg.get("allowed_players")
said = {}
check(admin.allow("u4pc") == true and u4.access == "ok" and u4.access_ok_at == nil and cfg.get("allowed_players") == list_before,
    "Allow with no id at all: let in, its placeholder name not put on the list, the id gate does not wait again")
check(said_n("access_allowed_once") == 1 and said_n("access_allowed") == 0
    and log.tr("access_allowed_once", "P") == "P впущен (в список не добавлен: игрок так и не назвал себя).",
    "the host is told it is not on the list")
cfg.set("join_access", "open")
local u5 = join("u5pc")
check(admin.access_gate(u5, NOW) == true and u5.access == nil, "open: not held while undecided (as before)")
u5.kicked = NOW
check(admin.access_gate(u5, NOW) == false, "a kicked player: no character")

print("Steam: a friend invited from the panel goes on the list")
reset_world()
cfg.set("allowed_players", "")
said = {}
check(admin.invited("Kate", "76561190000000033") == true and cfg.get("allowed_players") == "76561190000000033:Kate"
    and said_n("access_invited") == 1 and said_last("access_invited").args[1] == "Kate", "invited: on the list by SteamID, one notice")
check(admin.invited("Kate", "76561190000000033") == true and cfg.get("allowed_players") == "76561190000000033:Kate",
    "invited again: no second entry")
check(admin.invited("X", "123") == false and admin.invited("X", nil) == false, "not a SteamID: nothing")
check(log.tr("access_invited", "Kate") == "Приглашение через Steam отправлено: Kate (в списке допущенных)."
    and i18n.SAY_CLASS.access_invited == "game", "its notice: Russian on screen, the game's notification")
cfg.set("join_access", "list")
check(admin.on_early_id(join("katepc"), "Kate", "76561190000000033") == false, "invite only: the invited friend gets in")
cfg.set("join_access", "open")
cfg.set("allowed_players", "")

print("client: KICK codes and ACCESS")
S.role, S.client = "client", {}
local stopped = nil
package.loaded["sdc_session"] = { stop_auto_join = function(why) stopped = why end }
local CODES = { ["2"] = "access_list_you", ["3"] = "access_denied_you", ["4"] = "access_timeout_you",
                ["5"] = "access_full_you", ["0"] = "admin_kicked_you", ["1"] = "admin_banned_you",
                ["9"] = "admin_kicked_you", [""] = "admin_kicked_you" }
for code, key in pairs(CODES) do
    said, execs, stopped = {}, {}, nil
    S.disconnect_requested = false
    handlers.KICK({ code })
    check(said_n(key) == 1 and said[1].kind == "warn" and execs[1] == "disconnect" and S.disconnect_requested == true
        and stopped ~= nil, "KICK|" .. code .. ": " .. key .. ", the automatic join stops (" .. tostring(stopped) .. "), disconnect")
end
handlers.KICK({ "1" })
check(stopped == "banned by the host", "KICK|1: 'banned by the host' as before")
for code = 2, 5 do
    local old_reads_ban = tostring(code) == "1"   -- an older client: local ban = f[1] == "1"
    check(not old_reads_ban, "KICK|" .. code .. " is a kick for an older client's mod")
end
said = {}
handlers.ACCESS({ "wait" })
check(S.client.access == "wait" and said_n("access_wait_you") == 1, "ACCESS|wait: kept for the join cover, said once")
handlers.ACCESS({ "wait" })
check(said_n("access_wait_you") == 1, "the same again: nothing")
handlers.ACCESS({ "ok" })
check(S.client.access == "ok" and said_n("access_ok_you") == 1, "ACCESS|ok")
handlers.ACCESS({ "maybe" })
check(S.client.access == "ok", "an unknown value: ignored")
S.role = "host"
S.client = { }
handlers.ACCESS({ "wait" })
handlers.KICK({ "2" })
check(S.client.access == nil, "the host ignores ACCESS / KICK")
package.loaded["sdc_session"] = nil

print = real_print
print(string.format("access: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
