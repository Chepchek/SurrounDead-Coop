-- Mock test: a join under join_access approve / list through the real
-- sdc_persist (PSID -> sdc_admin.on_early_id, the id gate), sdc_players
-- (the spawn decision, sdcoop_spawn) and sdc_admin: a waiting player gets no
-- verdict and no character - past PID_WAIT_S too - until the host lets it
-- in; then its next id gets the verdict, the id gate counts from that
-- moment and the first character spawns. A refused player never gets one;
-- open = as before. A player whose id never comes (an older mod,
-- persist_early_id off) gets no character past the id gate's 25 s either:
-- at 60 s list refuses it, approve makes it wait for the host.
-- usage: lua mock_access_flow.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end

-- every other sdc_ module: an automatic stub (any field is a function returning nil)
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_persist = true, sdc_players = true, sdc_admin = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
RegisterConsoleCommandHandler = function() end
-- no LOCALAPPDATA: the records stay in memory, nothing is written on this PC
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end

local NOW = 200000
os.time = function() return NOW end

local to_client, handlers = {}, {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
net.send_to = function(pc, kind, ...) to_client[#to_client + 1] = { to = pc.key, kind = kind, f = { ... } } return true end
net.broadcast = function() end
package.loaded["sdc_net"] = net
local function count(kind, to)
    local n = 0
    for _, m in ipairs(to_client) do if m.kind == kind and (to == nil or m.to == to) then n = n + 1 end end
    return n
end
local function last(kind, to)
    for i = #to_client, 1, -1 do
        local m = to_client[i]
        if m.kind == kind and (to == nil or m.to == to) then return m end
    end
    return { f = {} }
end

local W = { pc = nil, slot = "CoopSlot" }
local ue = stub()
ue.ROLE_SIMULATED, ue.ROLE_AUTONOMOUS, ue.ROLE_AUTHORITY = 1, 2, 3
ue.valid = function(o) return type(o) == "table" and not o.destroyed end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.role = function(a) return type(a) == "table" and (rawget(a, "Role") or -1) or -1 end
ue.local_pc = function() return W.pc end
ue.pawn_of = function(pc) return type(pc) == "table" and rawget(pc, "Pawn") or nil end
ue.in_main_menu = function() return false end
ue.ems_current_slot = function() return W.slot end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.find_all = function() return {} end
ue.find_object = function() return nil end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_progress"] = {
    decode_values = function() return {} end, encode_values = function() return "" end,
    major_key = function() return "" end, set_verdict = function() end,
}

local log = require("sdc_log")
local lines = {}
log.info = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then return l end end
    return nil
end
local cfg = require("sdc_config")
cfg.values.persist_player_id = "00112233445566778899aabb"
cfg.save = function() return true end

local S = { role = "host", remote = {}, remote_pcs = {}, in_menu = false, menu_since = 0 }
local players = require("sdc_players")
players.init(S, {})
local spawned = {}
players.spawn_for = function(r, mode) spawned[#spawned + 1] = { key = r.key, mode = mode } end
local persist = require("sdc_persist")
persist.install(S)
local admin = require("sdc_admin")
admin.install(S)
W.pc = { key = "HostPC", Role = ue.ROLE_AUTHORITY }
persist.tick()   -- the host's world is up; sdc_players' hooks are put in
check(players.access_gate == admin.access_gate and players.persist_gate == persist.gate, "both gates are in sdc_players")

local SID, GUID = "76561190000000042", "00112233445566778899aabb"
local n_idx = 0
local function join(key)
    n_idx = n_idx + 1
    local r = { key = key, pc = { key = key }, name = "Player " .. n_idx, index = n_idx, joined_at = NOW,
                pawnless_since = NOW, spawned_once = false, hello = false }
    S.remote[key] = r
    return r
end
local function spawns(key)
    local n = 0
    for _, s in ipairs(spawned) do if s.key == key then n = n + 1 end end
    return n
end
local function verdicts(key) return count("PSSET", key) + count("PSFRESH", key) end

print("approve: Bob waits for the host")
cfg.set("join_access", "approve")
local bob = join("BobPC")
NOW = NOW + 3
handlers.PSID({ SID, GUID, "Bob" }, bob.pc)
check(last("ACCESS", "BobPC").f[1] == "wait" and verdicts("BobPC") == 0, "its early id: ACCESS|wait, no verdict")
check(persist._P()[bob.key] == nil, "no persist record for it yet")
NOW = NOW + 4
players.host_player_tick(bob, NOW)
check(spawns("BobPC") == 0, "no first character while it waits")
NOW = NOW + 30   -- 37 s since it joined: past PID_WAIT_S (25 s)
handlers.PSID({ SID, GUID, "Bob" }, bob.pc)
check(persist.gate(bob, NOW) == false and persist._P()[bob.key] == nil, "past 25 s: the id gate does not give up")
check(not logged("no id from"), "no 'no id within 25 s' line")
players.host_player_tick(bob, NOW)
check(spawns("BobPC") == 0, "past 25 s: still no character")
players.force_spawn_all()
check(spawns("BobPC") == 0 and logged("is not let in (sdc_admin): no character for it") ~= nil, "sdcoop_spawn: not for it")
check(count("ACCESS", "BobPC") == 1, "ACCESS|wait sent once")

print("the host lets Bob in")
local allowed_at = NOW
check(admin.allow("BobPC") == true and last("ACCESS", "BobPC").f[1] == "ok", "Allow: ACCESS|ok")
players.host_player_tick(bob, NOW)
check(spawns("BobPC") == 0 and persist.gate(bob, NOW) == false, "no id since: the gate waits for it (from the Allow)")
NOW = NOW + 4
handlers.PSID({ SID, GUID, "Bob" }, bob.pc)   -- its client repeats the id
check(verdicts("BobPC") == 1, "its next id: the verdict")
local p = persist._P()[bob.key]
check(p and p.late == false, "not a late id: its character spawns where it should")
check(persist.gate(bob, NOW) == true, "the id gate opens")
players.host_player_tick(bob, NOW)
check(spawns("BobPC") == 1 and spawned[#spawned].mode == "join", "the first character spawns (" .. (NOW - allowed_at) .. " s after the Allow)")

print("let in, its id lost: the id gate gives up 25 s after the Allow (not after the join)")
local ann = join("AnnPC")
NOW = NOW + 1
handlers.PSID({ "-", "aabbccddeeff00112233aabb", "Ann" }, ann.pc)
NOW = NOW + 60
admin.allow("AnnPC")
local t0 = NOW
NOW = t0 + 24
check(persist.gate(ann, NOW) == false, "24 s after the Allow: still waiting for its id")
NOW = t0 + 25
check(persist.gate(ann, NOW) == true and logged("no id from Ann within 25 s") ~= nil, "25 s after the Allow: the usual give-up")

print("list: Cid is not on the list")
cfg.set("join_access", "list")
local cid = join("CidPC")
NOW = NOW + 2
handlers.PSID({ "76561190000000077", "ffeeddccbbaa998877665544", "Cid" }, cid.pc)
check(last("KICK", "CidPC").f[1] == "2" and verdicts("CidPC") == 0, "KICK|2, no verdict")
NOW = NOW + 40
players.host_player_tick(cid, NOW)
check(spawns("CidPC") == 0, "refused: never a character (past 25 s too)")

print("open: as before")
cfg.set("join_access", "open")
local dan = join("DanPC")
NOW = NOW + 2
handlers.PSID({ "76561190000000088", "112233445566778899aabbcc", "Dan" }, dan.pc)
check(verdicts("DanPC") == 1 and count("ACCESS", "DanPC") == 0 and count("KICK", "DanPC") == 0, "the verdict at once, nothing else")
check(persist.gate(dan, NOW) == true, "the gate opens")
players.host_player_tick(dan, NOW)
check(spawns("DanPC") == 1, "its character spawns")

print("list: no id at all (persist_early_id off, an older mod): no character past 25 s, refused at 60 s")
cfg.set("join_access", "list")
cfg.set("allowed_players", "76561190000000055:Eli")
local old = join("OldPC")
NOW = NOW + 26
players.host_player_tick(old, NOW)
check(spawns("OldPC") == 0 and old.access == nil, "26 s, no id: the id gate would give up, the access gate does not")
players.force_spawn_all()
check(spawns("OldPC") == 0, "sdcoop_spawn: not for it either")
NOW = NOW + 34
players.host_player_tick(old, NOW)
check(spawns("OldPC") == 0 and last("KICK", "OldPC").f[1] == "2" and old.access == "refused",
    "60 s, still no id: refused (KICK|2), never a character")

print("approve: no id within 60 s: it waits for the host, then its id comes and it is on the list")
cfg.set("join_access", "approve")
local eli = join("EliPC")
NOW = NOW + 60
players.host_player_tick(eli, NOW)
check(spawns("EliPC") == 0 and last("ACCESS", "EliPC").f[1] == "wait", "60 s, no id: ACCESS|wait, no character")
NOW = NOW + 5
handlers.PSID({ "76561190000000055", "0f0e0d0c0b0a090807060504", "Eli" }, eli.pc)
check(eli.access == "ok" and last("ACCESS", "EliPC").f[1] == "ok" and verdicts("EliPC") == 1,
    "its id: on the list, let in, the verdict")
players.host_player_tick(eli, NOW)
check(spawns("EliPC") == 1, "its character spawns")

print("approve: no id ever: the host lets it in, its character comes at once")
local anon = join("AnonPC")
NOW = NOW + 60
players.host_player_tick(anon, NOW)
check(spawns("AnonPC") == 0 and anon.access == "wait", "60 s, no id: waits for the host")
admin.allow("AnonPC")
players.host_player_tick(anon, NOW)
check(spawns("AnonPC") == 1, "Allow: the character spawns now (the id gate had its 25 s already)")

print = real_print
print(string.format("access_flow: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
