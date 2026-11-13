-- Mock test (0.7.3 wave, group "session"): sdc_session.
--   1. the client's AI tick without an own character: not in the menu world
--      the role flips in, every second once a world loaded since the
--      connection began (joining, the death screen), never once the engine
--      role is no longer "client"; nothing else of phase B runs then
--   5. the engine's server address logged once per connection (a console
--      "open" the mod did not start), nothing decided by it
--   6. pak mods: the list (the game's own paks left out), HI / HELLO carry
--      it, the host and the client say what differs (once), an unknown list
--      ("?") or an older peer (no field) compares nothing
--   7. the client's pause menu to the host (AWAY): after the ack, on a
--      change, and again after a new handshake
-- (7, the player list's states: tests\loadtest\logic_roster.lua)
-- Every other module is an automatic stub.
-- usage: lua mock_wave_session.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local LOGS = {}
local real_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOGS[#LOGS + 1] = table.concat(parts, "\t")
end
local function logged(pat, from)
    for i = (from or 0) + 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return LOGS[i] end end
    return nil
end

local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_session = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end

-- the AI core: counts its client ticks
local AI = stub()
AI.any_enabled = function() return true end
AI.n = 0
AI.client_tick = function() AI.n = AI.n + 1 end
package.loaded["sdc_ai"] = AI
local ITEMS = stub()
ITEMS.n = 0
ITEMS.client_tick = function() ITEMS.n = ITEMS.n + 1 end
package.loaded["sdc_items"] = ITEMS

local sent = {}
local handlers = {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc and pc.key, kind = kind, f = { ... } } return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { pc = "host", kind = kind, f = { ... } } return true end
net.broadcast = function() end
package.loaded["sdc_net"] = net
local function last_sent(kind)
    for i = #sent, 1, -1 do if sent[i].kind == kind then return sent[i] end end
end

local W = { role = "client", menu = true, pc = { key = "menupc", Player = {} }, pawn = nil, addr = "" }
local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.try = function(f, ...) local ok, v = pcall(f, ...) if ok then return v end end
ue.fstring = function(v) if v == nil then return "" end return tostring(v) end
ue.is_wrapper_text = function(s) return tostring(s):find("RemoteUnrealParam", 1, true) ~= nil end
ue.pawn_of = function(pc) return type(pc) == "table" and pc.pawn or nil end
ue.local_pc = function() return W.pc end
ue.local_pawn = function() return W.pc and W.pc.pawn or nil end
ue.in_main_menu = function() return W.menu end
ue.net_role = function() return W.role end
ue.map_name = function() return "PersistentLevel" end
ue.find_all = function() return {} end
ue.sub_time = function(_, fn, ...) return pcall(fn, ...) end
local DEFER = nil   -- a table: phase B waits there (its 500 ms); nil: at once
ue.delay = function(_, _, fn) if DEFER then DEFER[#DEFER + 1] = fn return true end return false end
ue.has_pending_connection = function() return false end
package.loaded["sdc_ue"] = ue

local cfg = require("sdc_config")
cfg.set("player_name", "Tester")
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text, kind) toasts[#toasts + 1] = { text = text, kind = kind } end
local session = require("sdc_session")
session.register_handlers()
local st = session.state
local real_time = os.time
local NOW = 10000
os.time = function(t) if t then return real_time(t) end return NOW end
local function tick(s) NOW = NOW + (s or 1); session.tick() end

-- ===================================================================== 1
print("AI tick without an own character")
session.paks.list = {}   -- no "dir" in the test
tick()                   -- role unknown -> client: the menu world, no character
check(st.role == "client" and st.client and st.client.host_world == false, "role client in the menu world: no host world yet")
tick(); tick()
check(AI.n == 0, "menu world (the role flipped before the level load): no AI tick")
session.on_load_map()    -- the host's world starts loading
check(st.client.host_world == true, "a world loaded while connected: the host's")
W.pc = { key = "gamepc", Player = {} }
local mark = #LOGS
tick()
check(AI.n == 1 and ITEMS.n == 0, "no character yet: the AI tick runs, nothing else of phase B")
check(logged("zombie sync runs without an own character", mark) ~= nil, "logged once")
tick(); tick()
check(AI.n == 3, "every second")
local nlines = 0
for i = mark + 1, #LOGS do if LOGS[i]:find("zombie sync runs", 1, true) then nlines = nlines + 1 end end
check(nlines == 1, "the line only once")
-- a phase B left over (its 500 ms) after a disconnect's level load
DEFER = {}
tick()
local n0 = AI.n
W.role = "standalone"
for _, fn in ipairs(DEFER) do fn() end
check(#DEFER == 1 and AI.n == n0, "engine role no longer client when the waiting phase B runs: no AI tick")
W.role = "client"
-- ... or a new connection began meanwhile (its menu world)
DEFER = {}
tick()
n0 = AI.n
st.client.host_world = false
for _, fn in ipairs(DEFER) do fn() end
check(#DEFER == 1 and AI.n == n0, "the waiting phase B in a new connection's menu world: no AI tick")
st.client.host_world = true
DEFER = nil
n0 = AI.n
-- the character comes
W.menu = false
W.pc.pawn = { key = "mypawn" }
tick()
check(AI.n == n0 + 1 and ITEMS.n == 1, "with a character: the full phase B")
-- the death screen
W.menu, W.pc.pawn = true, nil
tick()
check(AI.n == n0 + 2 and ITEMS.n == 1, "death screen: the AI tick goes on, the rest waits")
-- a fresh connection in a world that had a character (role flip in a solo world with one)
st.client.host_world = false
W.menu = false
W.pc.pawn = { key = "mypawn2" }
tick()
check(st.client.host_world == true, "an own character seen: host world")
W.menu = true
W.pc.pawn = nil

-- ===================================================================== 5
print("server address")
st.client.addr_tries = 0
W.pc.GetServerNetworkAddress = function() return "" end
mark = #LOGS
for _ = 1, 3 do tick() end
check(logged("by the engine's account", mark) == nil and st.client.addr_tries == 3, "no address yet: tried each second")
W.pc.GetServerNetworkAddress = function() return "203.0.113.7" end
st.join.code, st.join.target = nil, nil
tick()
check(st.client.server_addr == "203.0.113.7", "the engine's address kept")
check(logged("join: connected to 203.0.113.7 by the engine's account (the join asked here: none - a connection the mod did not start", mark) ~= nil,
    "logged with 'no join asked'")
local tries = st.client.addr_tries
tick()
check(st.client.addr_tries == tries, "once per connection")
check(st.join.code == nil and st.join.target == nil, "nothing decided by it (no join address made up)")
st.client.addr_tries = 0
st.join.code = "198.51.100.2:7777"
mark = #LOGS
tick()
check(logged("the join asked here: 198.51.100.2:7777", mark) ~= nil, "next to the join asked here")
st.join.code = nil
st.client.addr_tries = 0
W.pc.GetServerNetworkAddress = function() return "RemoteUnrealParam_0000" end
for _ = 1, 10 do tick() end
check(st.client.server_addr == "203.0.113.7" and st.client.addr_tries == 10, "a wrapper's text is no address; gives up after 10 tries")

-- ===================================================================== 6
print("pak mods")
local P = session.paks
local list = P.read({
    "C:\\Games\\SurrounDead\\SurrounDead\\Content\\Paks\\SurrounDead-Windows.pak",
    "C:\\Games\\SurrounDead\\SurrounDead\\Content\\Paks\\pakchunk1-Windows.pak",
    "C:\\Games\\SurrounDead\\SurrounDead\\Content\\Paks\\LogicMods\\BiggerStacks.pak\r",
    "C:\\Games\\SurrounDead\\SurrounDead\\Content\\Paks\\~mods\\zzBackpack_P.pak",
    "C:\\Games\\SurrounDead\\SurrounDead\\Content\\Paks\\Extra_P.PAK",
    "C:\\Games\\SurrounDead\\SurrounDead\\Content\\Paks\\~mods\\pakchunk1-Windows.pak",
})
check(type(list) == "table" and #list == 4 and table.concat(list, ",") == "BiggerStacks,Extra_P,pakchunk1-Windows,zzBackpack_P",
    "the game's own paks left out (only at the top), others by name, sorted: " .. table.concat(list or {}, ","))
P.list, P.field = { "BiggerStacks", "zzBackpack_P" }, nil
check(P.mine() == "BiggerStacks;zzBackpack_P", "field: ';'-joined")
local a, b = P.diff("biggerstacks;OtherMod")
check(#a == 1 and a[1] == "OtherMod" and #b == 1 and b[1] == "zzBackpack_P", "diff: case-insensitive, both sides")
check(P.diff("?") == nil and P.diff(nil) == nil, "unknown / older peer: nothing compared")
P.field = "?"
check(P.diff("A") == nil, "own list unknown: nothing compared")
P.field = nil
-- HI from the client sends the list
st.client.acked, st.client.hello_attempts, st.client.hello_sent_at = false, 0, nil
st.client.pc_key = nil
W.menu, W.pc.pawn = false, { key = "mypawn3" }
sent = {}
tick(); tick(); tick()
local hi = last_sent("HI")
check(hi and hi.f[3] == "BiggerStacks;zzBackpack_P", "HI|version|name|paks")
-- HELLO from the host: compared once, the client told
local function pak_toasts()
    local out = {}
    for _, t in ipairs(toasts) do if t.text:find("pak", 1, true) then out[#out + 1] = t end end
    return out
end
toasts = {}
st.client.paks_checked = false
handlers.HELLO({ "?", "Host", "", "BiggerStacks;HostOnly1;HostOnly2" })
local pk = pak_toasts()
check(#pk == 1 and pk[1].kind == "warn"
    and pk[1].text == "У хоста другие pak-моды игры: только у хоста — HostOnly1, HostOnly2; только у вас — zzBackpack_P. Инвентари и лут могут расходиться.",
    "the client is told what differs: " .. tostring(pk[1] and pk[1].text))
handlers.HELLO({ "?", "Host", "ack", "BiggerStacks;HostOnly1;HostOnly2" })
check(#pak_toasts() == 1, "once per connection")
st.client.paks_checked = false
toasts = {}
handlers.HELLO({ "?", "Host", "ack" })
check(#pak_toasts() == 0 and st.client.paks_checked == false, "an older host (no field): nothing compared")
handlers.HELLO({ "?", "Host", "ack", "zzBackpack_P;biggerstacks" })
check(#pak_toasts() == 0 and st.client.paks_checked == true, "the same mods: no notice")
-- the host's side
st.role = "host"
W.role = "host"
local cpc = { key = "clientpc", NetConnection = {} }
toasts, sent = {}, {}
handlers.HI({ "?", "Вася", "BiggerStacks;A;B;C;D;E;F" }, cpc)
local hello = last_sent("HELLO")
check(hello and hello.f[3] == "ack" and hello.f[4] == "BiggerStacks;zzBackpack_P", "HELLO|version|name|ack|paks")
local pt = nil
for _, t in ipairs(toasts) do if t.text:find("pak", 1, true) then pt = t.text end end
check(pt == "У игрока Вася другие pak-моды игры: только у него — A, B, C, D, E и ещё 1; только у вас — zzBackpack_P. Инвентари и лут могут расходиться.",
    "the host is told, long lists cut: " .. tostring(pt))
toasts = {}
handlers.HI({ "?", "Вася", "X" }, cpc)
check(#toasts == 0, "HI again: not again")
local cpc2 = { key = "clientpc2", NetConnection = {} }
handlers.HI({ "?", "Петя" }, cpc2)
pt = nil
for _, t in ipairs(toasts) do if t.text:find("pak", 1, true) then pt = t.text end end
check(pt == nil, "an older client (no field): nothing said")
-- the first HELLO of a record (no ack yet): an empty ack field, then the list
sent = {}
local cpc3 = { key = "clientpc3", NetConnection = {} }
ue.find_all = function(cls) if cls == "PlayerController" then return { cpc3 } end return {} end
tick()
local h1 = last_sent("HELLO")
check(h1 and h1.pc == "clientpc3" and h1.f[3] == "" and h1.f[4] == "BiggerStacks;zzBackpack_P", "first HELLO: |version|name||paks")
ue.find_all = function() return {} end

-- ===================================================================== 7
-- the client's pause menu to the host (AWAY|1 / AWAY|0): after the host's
-- ack, on a change only, and told again after a new handshake (a new
-- controller: the host's record may be new)
print("the pause menu to the host")
local PAUSED = false
local LOBBY = package.loaded["sdc_lobby"] or stub()
package.loaded["sdc_lobby"] = LOBBY
LOBBY.pause_menu_shown = function() return PAUSED end
local function aways()
    local out = {}
    for _, m in ipairs(sent) do if m.kind == "AWAY" then out[#out + 1] = m.f[1] end end
    return table.concat(out, ",")
end
W.role, W.menu = "client", false
W.pc = { key = "awaypc", Player = {}, pawn = { key = "awaypawn" } }
sent = {}
tick(); tick(); tick()
check(st.role == "client" and last_sent("HI") ~= nil and aways() == "", "before the host's ack: no AWAY")
handlers.HELLO({ "?", "Host", "ack" })
tick()
check(aways() == "0", "after the ack: the state told once (AWAY|0)")
tick()
check(aways() == "0", "  not again while unchanged")
PAUSED = true
tick(); tick()
check(aways() == "0,1", "the pause menu opened: AWAY|1 once")
-- a new controller: a new handshake; the state is told again after its ack
W.pc = { key = "awaypc2", Player = {}, pawn = { key = "awaypawn2" } }
sent = {}
tick(); tick(); tick()
check(st.client.acked == false and last_sent("HI") ~= nil and aways() == "", "a new controller: HI again, no AWAY before the ack")
handlers.HELLO({ "?", "Host", "ack" })
tick()
check(aways() == "1", "after the new ack: AWAY|1 told again (still in the menu)")
PAUSED = false
tick()
check(aways() == "1,0", "the menu closed: AWAY|0")
package.loaded["sdc_lobby"] = nil

os.time = real_time
print = real_print
print(string.format("wave session: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
