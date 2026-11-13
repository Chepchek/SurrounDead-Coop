-- Mock test (critic fixes 2026-11-13, group A1): the early id.
-- sdc_persist's client_tick sends PSID as soon as this game is in the host's
-- world (its controller came from the host: Role AutonomousProxy) without a
-- character yet, so the host's id gate opens before PID_WAIT_S and the first
-- character can spawn at its saved spot (M.join_point). The host answers
-- only once its own world is up. Config persist_early_id = false: the id
-- goes only once the character exists (the old way).
-- usage: lua mock_fix_a1_early_id.lua <scripts dir>
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
local REAL = { sdc_persist = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
-- no LOCALAPPDATA: the records stay in memory, nothing is written on this PC
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end

local NOW = 100000
os.time = function() return NOW end

-- net: client -> host and host -> client messages are recorded
local to_host, to_client, handlers = {}, {}, {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
net.send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, f = { ... } } return true end
net.send_to = function(pc, kind, ...) to_client[#to_client + 1] = { to = pc.key, kind = kind, f = { ... } } return true end
net.broadcast = function() end
package.loaded["sdc_net"] = net
local function count(list, kind)
    local n = 0
    for _, m in ipairs(list) do if m.kind == kind then n = n + 1 end end
    return n
end

-- the engine as sdc_persist sees it
local W = { menu = true, pc = nil, slot = "CoopSlot" }
local ue = stub()
ue.ROLE_SIMULATED, ue.ROLE_AUTONOMOUS, ue.ROLE_AUTHORITY = 1, 2, 3
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.role = function(a) return type(a) == "table" and (rawget(a, "Role") or -1) or -1 end
ue.local_pc = function() return W.pc end
ue.pawn_of = function(pc) return type(pc) == "table" and rawget(pc, "Pawn") or nil end
ue.in_main_menu = function() return W.menu end
ue.ems_current_slot = function() return W.slot end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.find_all = function() return {} end
ue.find_object = function() return nil end
package.loaded["sdc_ue"] = ue

local SID = "76561190000000042"
package.loaded["sdc_steam"] = { own_id = function() return SID end }
local VERDICT = nil
package.loaded["sdc_progress"] = {
    decode_values = function() return {} end, encode_values = function() return "" end,
    major_key = function() return "" end, set_verdict = function(v) VERDICT = v end,
}
local S = { role = "client", client = { n = 1 }, remote = {}, remote_pcs = {}, in_menu = true, menu_since = 0 }
package.loaded["sdc_players"] = { PERSIST_HOOKS = true, record_for = function(pc) return S.remote[pc.key] end }

local log = require("sdc_log")
local lines = {}
log.info = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then return l end end
    return nil
end
local cfg = require("sdc_config")
cfg.values.persist_player_id = "00112233445566778899aabb"   -- no id is made (no config / player_id.txt write)

local persist = require("sdc_persist")
persist.install(S)
check(handlers.PSID and handlers.PSSET and handlers.PSFRESH, "PSID / PSSET / PSFRESH handlers")
local function tick(n)
    for _ = 1, n or 1 do NOW = NOW + 1; persist.tick() end
end

print("client: the menu world (the role is client already, its controller is the menu world's own)")
W.pc = { key = "MenuPC", Role = ue.ROLE_AUTHORITY }
tick(6)
check(count(to_host, "PSID") == 0, "no id from the menu world's controller")

print("client: in the host's world, no character yet")
W.pc = { key = "ClientPC", Role = ue.ROLE_AUTONOMOUS }
tick(1)
local first = to_host[1]
check(count(to_host, "PSID") == 1 and first.f[1] == SID and first.f[2] == "00112233445566778899aabb",
    "the id goes out at once: SteamID and own id")
check(logged("own id sent to the host early") ~= nil, "one clear log line for the early id")
tick(3)
check(count(to_host, "PSID") == 1, "not again within 4 s")
tick(1)
check(count(to_host, "PSID") == 2, "repeated every 4 s while there is no answer")
local n_early = 0
for _, l in ipairs(lines) do if l:find("sent to the host early", 1, true) then n_early = n_early + 1 end end
check(n_early == 1, "the early line is logged once")
tick(80)
check(count(to_host, "PSID") > 15, "early sends do not use up the 15 normal attempts (the host may still be in its menu): "
    .. count(to_host, "PSID"))
check(persist.client_join_state().verdict == nil, "no verdict yet")

print("client: the host answers before the character exists")
handlers.PSSET({ "g1", "", "-", "0", "" })
check(VERDICT and VERDICT.kind == "restore" and VERDICT.gen == "g1", "the saved character's verdict is handed to sdc_progress")
check(persist.client_join_state().verdict == "restore", "join state: restore verdict")
local n = count(to_host, "PSID")
tick(12)
check(count(to_host, "PSID") == n, "no more ids once the host answered")
check(count(to_host, "PSRDY") == 0 and count(to_host, "PSPROG") == 0, "nothing that needs the character is sent without it")

print("client: persist_early_id = false (the old way)")
persist.reset("new connection")
S.client = { n = 2 }
cfg.values.persist_early_id = false
to_host, lines = {}, {}
W.pc = { key = "ClientPC2", Role = ue.ROLE_AUTONOMOUS }
tick(10)
check(count(to_host, "PSID") == 0, "no id without a character")
W.menu = false
W.pc.Pawn = { key = "ClientChar2" }
tick(1)
check(count(to_host, "PSID") == 1 and logged("own id sent to the host (Steam " .. SID .. ")") ~= nil
    and not logged("early"), "with the character: the id, the usual line")
cfg.values.persist_early_id = nil

print("client: an unreadable controller role: the old way")
persist.reset("new connection")
S.client = { n = 3 }
to_host = {}
W.menu = true
W.pc = { key = "ClientPC3" }   -- no Role property (reads as -1)
tick(8)
check(count(to_host, "PSID") == 0, "no early id when the role is not known")

print("host: an id before its own world is up waits; then the gate opens before PID_WAIT_S")
persist.reset("host")
S.role, S.client, S.in_menu = "host", nil, true
W.pc, W.menu = { key = "HostPC", Role = ue.ROLE_AUTHORITY }, true
local bob = { key = "BobPC", pc = { key = "BobPC" }, name = "Bob", index = 1, joined_at = NOW, pawnless_since = NOW,
              spawned_once = false }
S.remote[bob.key] = bob
tick(1)
to_client = {}
handlers.PSID({ SID, "00112233445566778899aabb", "Bob" }, bob.pc)
check(count(to_client, "PSSET") + count(to_client, "PSFRESH") == 0, "host in its main menu: no verdict yet")
check(persist.gate(bob, NOW) == false, "the gate stays closed")
S.in_menu, W.menu = false, false
tick(1)
persist._live()["s" .. SID] = { name = "Bob", alive = true, pos = { x = 1000, y = 2000, z = 300, yaw = 90 },
                                prog = {}, tree = {} }
handlers.PSID({ SID, "00112233445566778899aabb", "Bob" }, bob.pc)
check(count(to_client, "PSSET") == 1, "the host's world is up: the saved character's verdict")
check(persist.gate(bob, NOW) == true and NOW - bob.joined_at < 25, "the id gate opens at once (" .. (NOW - bob.joined_at)
    .. " s after the join, PID_WAIT_S 25)")
local p = persist._P()[bob.key]
check(p and p.late == false, "not a late id: no move after the spawn")
local jp = persist.join_point(bob)
check(jp and jp.loc.X == 1000 and jp.loc.Y == 2000 and jp.loc.Z == 330 and jp.yaw == 90,
    "the first character spawns at the saved spot")

print = real_print
print(string.format("fix_a1_early_id: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
