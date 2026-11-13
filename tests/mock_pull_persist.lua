-- Mock test: sdc_persist's side of the host's pull (host).
--   restoring(key): the id may still come (no record, within PID_WAIT_S of
--     the join), or the saved character is being put back;
--   note_moved(key): no fall check of the old spot, and a late id's restore
--     leaves a moved character where it is (the placeholder record's mark
--     goes over to the real one); without a move the late restore still
--     moves it to the saved spot (UNSTUCKTO saved);
--   the fall check after a saved-spot spawn goes through sdc_players'
--     host_move (clear spot + landing guard).
-- usage: lua mock_pull_persist.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
local LOGS = {}
print = function(s) LOGS[#LOGS + 1] = tostring(s) end
local function logged(pat)
    for i = 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return LOGS[i] end end
    return nil
end

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
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end

local NOW = 300000
os.time = function() return NOW end
local delayed = {}
local function run_delayed()
    local list = delayed
    delayed = {}
    for _, f in ipairs(list) do f() end
end

local to_client, handlers = {}, {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
net.send_to = function(pc, kind, ...) to_client[#to_client + 1] = { to = pc.key, kind = kind, f = { ... } } return true end
net.send_to_host = function() return true end
net.broadcast = function() end
package.loaded["sdc_net"] = net
local function last_to(key, kind)
    for i = #to_client, 1, -1 do
        local m = to_client[i]
        if m.to == key and m.kind == kind then return m end
    end
    return nil
end

local ue = stub()
ue.ROLE_AUTONOMOUS, ue.ROLE_AUTHORITY = 2, 3
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.local_pc = function() return { key = "HostPC" } end
ue.pawn_of = function(pc) return type(pc) == "table" and rawget(pc, "Pawn") or nil end
ue.location = function(o) return type(o) == "table" and rawget(o, "loc") or nil end
ue.rotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
ue.in_main_menu = function() return false end
ue.ems_current_slot = function() return "CoopSlot" end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.find_all = function() return {} end
ue.find_object = function() return { key = "fn" } end
ue.delay = function(_, _, fn) delayed[#delayed + 1] = fn end
ue.hook_native = function() return true end
ue.ksl = function() return { GetConsoleVariableBoolValue = function() return false end } end
package.loaded["sdc_ue"] = ue

package.loaded["sdc_progress"] = {
    decode_values = function() return {} end, encode_values = function() return "" end, major_key = function() return "" end,
}
local S = { role = "host", remote = {}, remote_pcs = {}, in_menu = false, menu_since = 0 }
local moves = {}
package.loaded["sdc_players"] = {
    PERSIST_HOOKS = true,
    record_for = function(pc) return S.remote[pc.key] end,
    host_move = function(r, where) moves[#moves + 1] = { key = r.key, where = where }; return true, { X = 1, Y = 2, Z = 3 } end,
}

local log = require("sdc_log")
local cfg = require("sdc_config")
local persist = require("sdc_persist")
persist.install(S)
local function tick(n)
    for _ = 1, n or 1 do NOW = NOW + 1; persist.tick() end
end
tick(1)
local P = persist._P

local function join(name, sid)
    local key = name .. "PC"
    local r = { key = key, pc = { key = key }, name = name, index = 1, joined_at = NOW, pawnless_since = NOW,
                spawned_once = false, dead = false, hello = true }
    S.remote[key] = r
    return r, "s" .. sid
end
local function spawn(r, loc)
    r.pc.Pawn = { key = r.name .. "Char", loc = loc }
    r.spawned_once = true
end

print("restoring: the id may still come")
local bob, kb = join("Bob", "76561190000000042")
check(persist.restoring(bob.key) == true, "joined, no id yet: restoring")
NOW = NOW + 26
check(persist.restoring(bob.key) == false, "past PID_WAIT_S without an id: not restoring")
check(persist.gate(bob, NOW) == true and P()[bob.key] and P()[bob.key].nokey, "the gate gives up: a placeholder record")
check(persist.restoring(bob.key) == false, "placeholder: not restoring")
check(persist.restoring("nobody") == false, "unknown player: no")
spawn(bob, { X = 1000, Y = 0, Z = 100 })

print("late id after a pull: the character stays")
persist._live()[kb] = { key = kb, name = "Bob", alive = true, vitals = { Health = 80 },
    pos = { x = 50000, y = 60000, z = 300, yaw = 90 } }
persist.note_moved(bob.key)
check(P()[bob.key].moved_by_host == NOW, "note_moved marks the placeholder")
handlers.PSID({ "76561190000000042", "00112233445566778899aabb", "Bob" }, bob.pc)
local p = P()[bob.key]
check(p and p.late == true and p.restore and p.restore.pos and p.moved_by_host ~= nil, "late id: the restore, the mark kept")
check(persist.restoring(bob.key) == true, "the saved character being put back: restoring (no pull now)")
handlers.PSRDY({ p.gen }, bob.pc)
tick(2)
check(p.restored == true and persist.restoring(bob.key) == false, "restored: not restoring any more")
check(last_to(bob.key, "UNSTUCKTO") == nil, "no move back to the saved spot")
check(logged("but the host has moved the character since: it stays where it is") ~= nil, "logged")

print("late id without a pull: moved to the saved spot as before")
local ann, ka = join("Ann", "76561190000000043")
NOW = NOW + 26
persist.gate(ann, NOW)
spawn(ann, { X = 1000, Y = 0, Z = 100 })
persist._live()[ka] = { key = ka, name = "Ann", alive = true, vitals = { Health = 80 },
    pos = { x = 40000, y = 30000, z = 300, yaw = 0 } }
handlers.PSID({ "76561190000000043", "00112233445566778899aabc", "Ann" }, ann.pc)
local pa = P()[ann.key]
check(pa and pa.late and pa.moved_by_host == nil, "no mark without a move")
-- (0.9.x review) the record restores no inventory: the character keeps the
-- starting kit it spawned with, so the client's screen is not cleared
local setA = last_to(ann.key, "PSSET")
check(setA and not tostring(setA.f[5]):find("clear", 1, true), "late id, no saved inventory: no UI clear (the kit stays on the screen)")
handlers.PSRDY({ pa.gen }, ann.pc)
tick(2)
local un = last_to(ann.key, "UNSTUCKTO")
check(un and un.f[1] == "40000" and un.f[5] == "saved", "UNSTUCKTO|..|saved as before")

print("the fall check")
-- Ann was moved to the saved spot: watched for a fall (FALL_CHECK_S = 6)
check(pa.fall ~= nil, "Ann watched for a fall")
ann.pc.Pawn.loc = { X = 40000, Y = 30000, Z = 300 - 2000 }
tick(7)
check(#moves == 1 and moves[1].key == ann.key and moves[1].where == "host", "fell: sdc_players.host_move(r, \"host\")")
check(logged("Ann fell from the saved spot (z 300 -> -1700): moved next to the host") ~= nil, "logged")
local n_un = 0
for _, m in ipairs(to_client) do if m.to == ann.key and m.kind == "UNSTUCKTO" then n_un = n_un + 1 end end
check(n_un == 1, "no second UNSTUCKTO of its own (host_move sends it)")
-- a pull before the check: no fall check
local cat, kc = join("Cat", "76561190000000044")
persist._live()[kc] = { key = kc, name = "Cat", alive = true, vitals = { Health = 80 },
    pos = { x = 20000, y = 10000, z = 5000, yaw = 0 } }
handlers.PSID({ "76561190000000044", "00112233445566778899aabd", "Cat" }, cat.pc)
local pc_ = P()[cat.key]
local jp = persist.join_point(cat)
check(jp and jp.loc.X == 20000 and pc_.fall ~= nil, "Cat spawns at the saved spot, watched for a fall")
spawn(cat, { X = 20000, Y = 10000, Z = 5030 })
tick(1)
persist.note_moved(cat.key)
check(pc_.fall == nil, "note_moved: no fall check of the old spot")
cat.pc.Pawn.loc = { X = 1000, Y = 0, Z = 100 }   -- next to the host, 49 m lower
tick(8)
check(#moves == 1, "pulled next to a host far below the saved spot: not moved again")

print = real_print
print(string.format("pull_persist: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
