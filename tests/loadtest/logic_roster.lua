-- SDCoop: the co-op panel's player list in sdc_session (0.7.0 UI).
--   lua logic_roster.lua <scripts dir>
-- sdc_session.roster() on the host (itself + remote records with their state
-- and ping), the host's ROSTER messages from its 1 s tick (on a change, every
-- 5 s, "me" per receiving client), the client's ROSTER handler and its
-- fallback before the first list. 0.7.3 wave: "lag" (nothing received for
-- 4 s), "menu" (AWAY: the pause menu), the host's own entry dead / in the
-- menu, and a client taking the first entry as the host's whatever its
-- state. Every other module is an automatic stub.
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function ok(cond, what)
    if cond then pass = pass + 1 else fail = fail + 1; io.stderr:write("FAIL: " .. what .. "\n") end
end
local real_print = print
print = function() end

-- an automatic stub: any field is a function returning nil
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_session = true, sdc_log = true, sdc_config = true, sdc_netsync = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)

-- engine-side stubs
FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end

local now_clock = 1000
local sent = {}           -- { pc = key, kind = , fields = {} }
local handlers = {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
local FAIL_SEND = false
net.send_to = function(pc, kind, ...) if FAIL_SEND then return false end sent[#sent + 1] = { pc = pc.key, kind = kind, fields = { ... } } return true end
net.broadcast = function() end
net.send_to_host = function() return true end
package.loaded["sdc_net"] = net

local function pc(key, hello_ping, pawn)
    return { key = key, NetConnection = {}, ping = hello_ping, pawn = pawn }
end
local PCS = {}
local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.pawn_of = function(p) return type(p) == "table" and p.pawn or nil end
ue.ping_ms = function(p) return type(p) == "table" and p.ping or nil end
ue.find_all = function(cls) if cls == "PlayerController" then return PCS end return {} end
ue.sub_time = function(_, fn, ...) return pcall(fn, ...) end
ue.delay = function() return false end
ue.map_name = function() return "LongdownValley" end
ue.local_pc = function() return { key = "hostpc", Player = {} } end
ue.in_main_menu = function() return false end
ue.net_role = function() return "host" end
ue.has_pending_connection = function() return false end
-- the host's own character (its roster entry: "host" while alive, 0.7.3 wave)
local HOSTPAWN = { key = "hostpawn" }
ue.local_pawn = function() return HOSTPAWN end
package.loaded["sdc_ue"] = ue

local cfg = require("sdc_config")
cfg.set("player_name", "Hosty")
local session = require("sdc_session")
session.register_handlers()
local st = session.state
local real_time = os.time
local fake_now = 5000
os.time = function() return fake_now end
local fake_clock = 1000
os.clock = function() return fake_clock end   -- sdc_netsync's verify clock

ok(type(session.roster) == "function", "sdc_session.roster exists")
ok(handlers.ROSTER ~= nil, "ROSTER handler registered")

-- host: nobody yet
st.role = "host"
local r = session.roster()
ok(#r == 1 and r[1].name == "Hosty" and r[1].state == "host" and r[1].me and r[1].host, "host alone: itself first")

-- two clients: one in game (handshake + pawn), one still connecting
local bob = pc("bobpc", 40, { key = "bobpawn" })
local gleb = pc("glebpc", nil, nil)
PCS = { bob, gleb }
session.tick()        -- remote_record() for both
ok(st.remote.bobpc and st.remote.glebpc, "remote records made by the host tick")
st.remote.bobpc.name, st.remote.bobpc.hello = "Bob", true
st.remote.glebpc.name = "Gleb"
r = session.roster()
ok(#r == 3 and r[2].name == "Bob" and r[2].state == "game" and r[2].ping == 40
    and r[3].name == "Gleb" and r[3].state == "connecting", "host: Bob in game (40 ms), Gleb connecting")
st.remote.glebpc.hello = true
r = session.roster()
ok(r[3].state == "loading", "host: handshake done, no character -> loading")
st.remote.bobpc.dead = true
r = session.roster()
ok(r[2].state == "dead", "host: a dead player")
st.remote.bobpc.dead = false

-- ROSTER from the host tick: one per client, "me" on its own entry
sent = {}
fake_now = fake_now + 1
session.tick()
local rosters = {}
for _, m in ipairs(sent) do if m.kind == "ROSTER" then rosters[m.pc] = m.fields end end
ok(rosters.bobpc and rosters.glebpc, "ROSTER sent to both clients")
local f = rosters.bobpc or {}
ok(#f == 12 and f[1] == "Hosty" and f[2] == "host" and f[4] == "0" and f[5] == "Bob" and f[6] == "game"
    and f[7] == "40" and f[8] == "1" and f[9] == "Gleb" and f[12] == "0", "ROSTER fields for Bob: " .. table.concat(f, "|"))
ok((rosters.glebpc or {})[12] == "1" and (rosters.glebpc or {})[8] == "0", "Gleb's copy marks Gleb")
-- unchanged: nothing (not even after 5 s, pings wobbling by a few ms); the verify
-- after 30 s; on a change: at once; a ping that moved a lot: at once
local function count_rosters()
    local k = 0
    for _, m in ipairs(sent) do if m.kind == "ROSTER" then k = k + 1 end end
    return k
end
local function step(dt)
    fake_now = fake_now + dt
    fake_clock = fake_clock + dt
    session.tick()
end
sent = {}
step(1)
ok(count_rosters() == 0, "no ROSTER when nothing changed")
bob.ping = 52          -- +12 ms: not worth a list
step(5)
ok(count_rosters() == 0, "no ROSTER after 5 s: a ping wobble of 12 ms is not told")
sent = {}
bob.ping = 90          -- +50 ms from what was told
step(1)
ok(count_rosters() == 2, "a ping that moved by 50 ms goes at once")
local hf0
for _, m in ipairs(sent) do if m.kind == "ROSTER" and m.pc == "glebpc" then hf0 = m.fields end end
ok(hf0 and hf0[7] == "90", "... with the new ping")
sent = {}
step(20)
ok(count_rosters() == 0, "20 s later: still nothing")
step(11)
ok(count_rosters() == 2, "the verify: the list again after 30 s")
sent = {}
step(1)
gleb.pawn = { key = "glebpawn" }
step(1)
ok(count_rosters() == 2, "ROSTER at once when a state changes")
-- what the host knows of a client's knockdown cap goes into its own "me" field
package.loaded["sdc_down"] = { downcap_level = function(key) return key == "bobpc" and 2 or 0 end,
                               downcap = function(key) return key == "bobpc" end, state_of = function() return nil end }
sent = {}
step(1)
local bobf, glebf
for _, m in ipairs(sent) do
    if m.kind == "ROSTER" and m.pc == "bobpc" then bobf = m.fields end
    if m.kind == "ROSTER" and m.pc == "glebpc" then glebf = m.fields end
end
ok(bobf and bobf[8] == "3" and bobf[4] == "0", "Bob's me field says 3: the host knows DOWNCAP + ready")
ok(glebf == nil, "Gleb's list did not change: not sent")
package.loaded["sdc_down"] = nil
sent = {}
step(1)
ok(count_rosters() >= 1, "the cap forgotten again: the list goes again")
-- a client that says HI again knows nothing: its list goes at once
sent = {}
step(1)
ok(count_rosters() == 0, "quiet again")
handlers.HI({ "0.1", "Bob" }, bob)
sent = {}
step(1)
local after_hi = false
for _, m in ipairs(sent) do if m.kind == "ROSTER" and m.pc == "bobpc" then after_hi = true end end
ok(after_hi, "after a client's HI its list goes at once")

-- a send that failed is not counted as told: the next check sends it again
FAIL_SEND = true
bob.ping = 150
sent = {}
step(1)
ok(count_rosters() == 0, "failed sends: nothing went out")
FAIL_SEND = false
step(1)
ok(count_rosters() == 2, "the failed list goes with the next check")
-- a client that is gone is forgotten (prune); back again it gets its list although the text is the same
local netsync = require("sdc_netsync")
PCS = { bob }
step(1)
ok(netsync.known("bobpc", "ROSTER") and not netsync.known("glebpc", "ROSTER"), "prune: the client that left is forgotten, the other not")
PCS = { bob, gleb }
sent = {}
step(1)
local gleb_back = false
for _, m in ipairs(sent) do if m.kind == "ROSTER" and m.pc == "glebpc" then gleb_back = true end end
ok(gleb_back, "back again: its list goes at once")

-- traffic of an idle host with two clients, 6 minutes, the pings wobbling by a few ms:
-- NETQ line for the net-quiet report
do
    sent = {}
    for i = 1, 360 do
        bob.ping = 90 + (i % 3) * 5
        step(1)
    end
    local n, bytes = 0, 0
    for _, m in ipairs(sent) do
        if m.kind == "ROSTER" then
            n = n + 1
            bytes = bytes + 12
            for _, v in ipairs(m.fields) do bytes = bytes + #tostring(v) + 1 end
        end
    end
    io.write(string.format("NETQ ROSTER idle (2 clients) msgs/min=%.1f bytes/min=%.0f", n / 6, bytes / 6), string.char(10))
end

-- 0.7.3 wave: "lag" (nothing received for 4 s), "menu" (AWAY), the host's own state
local function state_of(name)
    for _, e in ipairs(session.roster()) do if e.name == name then return e.state end end
end
bob.NetConnection.LastReceiveTime = 10.0
fake_now = fake_now + 1; session.tick()
fake_now = fake_now + 3; session.tick()
ok(state_of("Bob") == "game", "lag: 3 s without a packet is still in game")
fake_now = fake_now + 1; session.tick()
ok(state_of("Bob") == "lag", "lag: 4 s without a packet -> lag")
st.remote.bobpc.dead = true
ok(state_of("Bob") == "lag", "lag: shown before dead (silent is what matters)")
st.remote.bobpc.dead = false
local bobpawn = bob.pawn
bob.pawn = nil
ok(state_of("Bob") == "loading", "silent while it has no character (a level load): loading, not lag")
bob.pawn = bobpawn
bob.NetConnection.LastReceiveTime = 14.5
fake_now = fake_now + 1; session.tick()
ok(state_of("Bob") == "game", "lag: a packet again -> in game")
handlers.AWAY({ "1" }, bob)
ok(state_of("Bob") == "menu", "AWAY|1: menu")
st.remote.bobpc.dead = true
ok(state_of("Bob") == "dead", "dead before menu")
st.remote.bobpc.dead = false
handlers.AWAY({ "0" }, bob)
ok(state_of("Bob") == "game", "AWAY|0: in game again")
handlers.AWAY({ "1" }, { key = "strangerpc" })
ok(st.remote.strangerpc == nil, "AWAY from an unknown controller: no record made")
-- the host's own entry
HOSTPAWN["PlayerDead?"] = true
sent = {}
fake_now = fake_now + 1; session.tick()
ok(session.roster()[1].state == "dead" and session.roster()[1].host, "host dead: its entry says dead, still the host")
local hf = nil
for _, m in ipairs(sent) do if m.kind == "ROSTER" and m.pc == "bobpc" then hf = m.fields end end
ok(hf and hf[1] == "Hosty" and hf[2] == "dead", "ROSTER sent at once: the host is dead")
HOSTPAWN["PlayerDead?"] = nil
local saved_lp = ue.local_pawn
ue.local_pawn = function() return nil end   -- the body unpossessed: the death screen
fake_now = fake_now + 1; session.tick()
ok(session.roster()[1].state == "dead", "host without a character in its world: dead")
ue.local_pawn = saved_lp
package.loaded["sdc_lobby"] = { pause_menu_shown = function() return true end }
fake_now = fake_now + 1; session.tick()
ok(session.roster()[1].state == "menu", "host's pause menu open: menu")
package.loaded["sdc_lobby"] = nil
fake_now = fake_now + 1; session.tick()
ok(session.roster()[1].state == "host", "host alive, no menu: host")

-- client side: the handler and the fallback
st.role = "client"
st.client = { host_name = "Hosty", ping = 77 }
r = session.roster()
ok(#r == 2 and r[1].name == "Hosty" and r[1].host and r[2].me and r[2].ping == 77, "client before ROSTER: host + itself")
handlers.ROSTER({ "Hosty", "host", "", "0", "Bob", "game", "40", "1", "Gleb", "loading", "", "0" })
r = session.roster()
ok(#r == 3 and r[1].host and r[2].name == "Bob" and r[2].me and r[2].ping == 40 and r[3].state == "loading"
    and r[3].ping == nil, "client: the host's list")
handlers.ROSTER({ "Hosty", "dead", "", "0", "Bob", "menu", "40", "1", "Gleb", "lag", "", "0" })
r = session.roster()
ok(r[1].host and r[1].state == "dead" and not r[2].host and r[2].state == "menu" and r[3].state == "lag",
    "client: a dead host is still the host (the first entry); menu / lag states")
st.client = nil
ok(#session.roster() == 0, "no client state: empty list")
st.role = "standalone"
ok(#session.roster() == 0, "standalone: empty list")

-- a new world: everybody is told again
st.role = "host"
step(1)
ok(netsync.known("bobpc", "ROSTER"), "(a record exists before the reset)")
session.reset_world("test")
ok(not netsync.known("bobpc", "ROSTER") and not netsync.known("glebpc", "ROSTER"), "reset_world: nobody has a record")

os.time = real_time
print = real_print
print(string.format("roster: %d checks, %d failed%s", pass + fail, fail, fail == 0 and ", ALL OK" or ""))
os.exit(fail == 0 and 0 or 1)
