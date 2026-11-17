-- Mock test: frame-time spikes of the mod (0.12.2 "spikes" group, part 3; first in-game self-test, 14.11).
--   W  sdc_world: a client's WLOOTS with a camp key held the game for 334 ms (CB.apply_all looked up every runtime
--      container of the map with the engine): now only the places of a class the host named a key for are looked at,
--      in slices of ~3 ms; CB.box_of and the 30 s prune likewise
--   N  sdc_npc: the client tick's hook pass (11 failing RegisterHook of animals, ~22 ms each = 250 ms) stops after
--      ~3 ms and goes on at the next tick
--   I  sdc_items: failed hooks (durability, battery, event hooks) are retried with a back-off, one failure per pass
-- (sdc_ai_looks: mock_ai_coop_client, section C)
-- usage: lua mock_spikes3.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local T = 5000.0
os.clock = function() return T end
os.time = function() return 1700000000 end
local real_print = print
local LOG = {}
print = function(s) LOG[#LOG + 1] = tostring(s) end
local function find_log(pat)
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end
    return nil
end

local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_world = true, sdc_log = true, sdc_config = true, sdc_npc = true, sdc_items = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
NotifyOnNewObject = function() end
local reg_calls, reg_fail, reg_cost = 0, true, 0.022
RegisterHook = function(path)
    reg_calls = reg_calls + 1
    if reg_fail then
        T = T + reg_cost
        error("Tried to register a hook for a UFunction that doesn't exist")
    end
    return 1, 2
end

-- one ue for all: objects are tables, a path finds an object of the table PATHS; an engine lookup costs 0.5 ms
local PATHS, find_calls, FIND_COST = {}, 0, 0.0005
local ue = stub()
ue.valid = function(o) return type(o) == "table" and o.__valid ~= false end
ue.find_object = function(p) find_calls = find_calls + 1; T = T + FIND_COST; return PATHS[p] end
ue.location = function(o) return o and o.__loc end
ue.find_all_recent = function() return {} end
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.set_prop = function(o, k, v) if type(o) ~= "table" then return false end o[k] = v; return true end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.class_name = function(o) return type(o) == "table" and o.__cls or "" end
ue.short = function(o) return type(o) == "table" and (o.__name or "obj") or "<none>" end
ue.name = ue.short
ue.is_runtime_spawned = function(o) return type(o) == "table" and o.__runtime == true end
ue.role = function(o) return type(o) == "table" and o.__role or -1 end
ue.ROLE_AUTHORITY = 3
ue.sub_time = function(_, fn, ...) return pcall(fn, ...) end
ue.backoff = function(rec, now, base, cap)
    local w = rec.wait and math.min(cap, rec.wait * 2) or base
    rec.wait, rec.next_try = w, now + w
    return w
end
ue.local_pc = function() return nil end
ue.hook_native = function() return false, "no native" end
local timers = {}
ue.delay = function(label, ms, fn) timers[#timers + 1] = { label = label, ms = ms, fn = fn }; return 1 end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_ai"] = { core = stub(), isa = function() return false end, hook_external = function() end, install_now = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__a or nil end }

-- ---------------------------------------------------------------- W: sdc_world
io.write("W: WLOOTS with a camp key, a map with many runtime containers\n")
local world = require("sdc_world")
local CB = world._t.camps
world._t.set_state({ role = "client", client = { acked = true } })
local CAMP = "Container_Camp_C"
local KEY = "@" .. CAMP .. "@1000,2000,300"
-- 1500 runtime containers of other classes, 3 camp copies (one near the key, one far, one gone)
local others = 0
for i = 1, 1500 do
    local p = "/Game/Levels/M.M:PersistentLevel.Container_POICrate_C_" .. (2000000000 + i)
    PATHS[p] = { __cls = "Container_POICrate_C", __runtime = true, __role = 1, __loc = { X = i * 1000, Y = 0, Z = 0 }, __name = "poi" .. i }
    CB.live[p], CB.cls[p] = 0, "Container_POICrate_C"
    others = others + 1
end
local near_p = "/Game/Levels/M.M:PersistentLevel.Container_Camp_C_2000009001"
local far_p = "/Game/Levels/M.M:PersistentLevel.Container_Camp_C_2000009002"
local gone_p = "/Game/Levels/M.M:PersistentLevel.Container_Camp_C_2000009003"
local near_o = { __cls = CAMP, __runtime = true, __role = 1, __loc = { X = 1010, Y = 2000, Z = 300 }, __name = "near" }
local far_o = { __cls = CAMP, __runtime = true, __role = 1, __loc = { X = 90000, Y = 2000, Z = 300 }, __name = "far" }
PATHS[near_p], PATHS[far_p] = near_o, far_o
for _, p in ipairs({ near_p, far_p, gone_p }) do CB.live[p], CB.cls[p] = 0, CAMP end
local say_count = 0
local net = require("sdc_net")
CB.keys, CB.nkeys = {}, 0
local loots = world._t.loots_msg
find_calls = 0
local t0 = T
loots({ KEY })
local sync_ms, sync_finds = (T - t0) * 1000, find_calls
check(sync_ms <= 4, "the message itself works at most one slice (" .. sync_finds .. " lookups, " .. string.format("%.1f", sync_ms) .. " ms)")
-- the slices (a task each) until the pass is done
local worst_slice, slices = 0, 0
local guard = 0
while #timers > 0 and guard < 200 do
    guard = guard + 1
    local tm = table.remove(timers, 1)
    local a = T
    tm.fn()
    slices = slices + 1
    if (T - a) * 1000 > worst_slice then worst_slice = (T - a) * 1000 end
end
check(near_o.ContainerLooted == true, "the camp copy near the key is searched, as before")
check(far_o.ContainerLooted == nil, "the far copy of the class is left alone")
check(find_calls <= 8, "only the places of the key's class were looked up, not the " .. others .. " other containers (" .. find_calls .. " lookups)")
local line = find_log("host's searched containers")
check(line ~= nil and line:find("camp containers: 1, 1 of them here now", 1, true) ~= nil, "the report line comes at the end of the pass: " .. tostring(line))
check(CB.run == nil, "no pass left running")

-- the same, with no class known for the entries (as before this change: the pass has to look at each one)
io.write("W2: entries without a known class are looked at in slices of ~3 ms and their class is learned\n")
LOG = {}
for p in pairs(CB.live) do CB.cls[p] = nil end
near_o.ContainerLooted = nil
CB.keys, CB.nkeys = {}, 0
timers = {}
find_calls = 0
t0 = T
loots({ KEY })
local first_ms = (T - t0) * 1000
check(first_ms < 5, "the message returns at once (" .. string.format("%.1f", first_ms) .. " ms)")
worst_slice, slices, guard = 0, 0, 0
while #timers > 0 and guard < 2000 do
    guard = guard + 1
    local tm = table.remove(timers, 1)
    local a = T
    tm.fn()
    slices = slices + 1
    if (T - a) * 1000 > worst_slice then worst_slice = (T - a) * 1000 end
end
check(slices > 100, "a pass over 1500 unknown entries took many slices (" .. slices .. ")")
check(worst_slice <= 4, "no slice longer than ~3 ms (" .. string.format("%.1f", worst_slice) .. " ms)")
check(near_o.ContainerLooted == true, "same end result: the camp copy is searched")
check(find_log("camp containers: 1, 1 of them here now") ~= nil, "same report line")
local learned = 0
for p, c in pairs(CB.cls) do if c ~= nil then learned = learned + 1 end end
check(learned >= 1500, "the class of each entry was learned (" .. learned .. ")")
-- the next list: only the key's class
find_calls = 0
near_o.ContainerLooted = nil
timers = {}
loots({ KEY })
while #timers > 0 do table.remove(timers, 1).fn() end
check(find_calls <= 8 and near_o.ContainerLooted == true, "the next list looks at the key's class only (" .. find_calls .. " lookups)")

-- two lists in a row share the next pass; each gets its report
io.write("W3: a list during a pass joins the next pass\n")
LOG = {}
for p in pairs(CB.live) do CB.cls[p] = nil end
timers = {}
loots({ KEY })
loots({ KEY })
check(#timers == 1, "one pass runs, the second list waits (" .. #timers .. " task)")
guard = 0
while #timers > 0 and guard < 3000 do table.remove(timers, 1).fn(); guard = guard + 1 end
local reports = 0
for _, l in ipairs(LOG) do if l:find("host's searched containers", 1, true) then reports = reports + 1 end end
check(reports == 2, "both lists reported (" .. reports .. ")")
check(CB.run == nil and CB.waiting == nil, "nothing left")

-- no timer available: all at once, as before the slicing
io.write("W4: no timer: the pass runs whole\n")
local saved_delay = ue.delay
ue.delay = nil
near_o.ContainerLooted = nil
LOG = {}
loots({ KEY })
check(near_o.ContainerLooted == true and find_log("camp containers: 1, 1 of them here now") ~= nil, "applied in the call itself")
ue.delay = saved_delay

-- CB.box_of: by class
io.write("W5: CB.box_of and the 30 s prune\n")
find_calls = 0
local got = CB.box_of(KEY)
check(got == near_o and find_calls <= 8, "box_of finds the copy with " .. find_calls .. " lookups (not " .. others .. ")")
-- the prune: 1500 entries, 600 of them gone, in slices
for i = 1, 600 do
    local p = "/Game/Levels/M.M:PersistentLevel.Container_POICrate_C_" .. (2000000000 + i)
    PATHS[p] = nil
end
T = T + 40
CB.prune_at = 0
local live0 = 0
for _ in pairs(CB.live) do live0 = live0 + 1 end
find_calls = 0
worst_slice, guard = 0, 0
repeat
    guard = guard + 1
    local a = T
    CB.pass(T)
    if (T - a) * 1000 > worst_slice then worst_slice = (T - a) * 1000 end
    T = T + 0.25
until CB.pr == nil or guard > 2000
local live1 = 0
for _ in pairs(CB.live) do live1 = live1 + 1 end
check(guard > 100 and worst_slice <= 4, "the prune goes over several ticks, each ~3 ms (" .. guard .. " ticks, worst "
    .. string.format("%.1f", worst_slice) .. " ms)")
check(live0 - live1 == 600, "and removes the gone entries (" .. (live0 - live1) .. ")")

-- a pass that throws does not block the next lists (MED-1)
io.write("W6: an apply that throws; a world change in the middle of a pass\n")
LOG = {}
for p in pairs(CB.live) do CB.cls[p] = nil end
CB.keys, CB.nkeys = {}, 0
timers = {}
local real_known = CB.apply_known
CB.apply_known = function() error("boom") end
loots({ KEY })
guard = 0
while #timers > 0 and guard < 3000 do table.remove(timers, 1).fn(); guard = guard + 1 end
CB.apply_known = real_known
check(CB.run == nil, "a throwing apply does not leave the pass running")
check(find_log("host's searched containers") ~= nil, "and the report still comes")
-- a stale run (its next slice never came) is dropped by the next list after 10 s
CB.run = { list = {}, i = 1, n = 0, looked = 0, t0 = T, dones = {} }
T = T + 11
timers = {}
near_o.ContainerLooted = nil
loots({ KEY })
while #timers > 0 do table.remove(timers, 1).fn() end
check(near_o.ContainerLooted == true and CB.run == nil, "a pass whose slice never came is replaced after 10 s")

-- world change mid-pass (MED-2)
for p in pairs(CB.live) do CB.cls[p] = nil end
near_o.ContainerLooted = nil
timers = {}
loots({ KEY })
local old_run = CB.run
local old_timer = timers[1]
check(old_run ~= nil and old_timer ~= nil, "a pass is in progress after its first slice")
world.reset("mock: new world")
check(CB.run == nil, "the world reset drops the pass")
near_o.ContainerLooted = nil
timers = { }
loots({ KEY })
local new_run = CB.run
check(new_run ~= nil and new_run ~= old_run, "a new pass of the new world is running")
local n_before, old_i = new_run.i, old_run.i
old_timer.fn()
check(CB.run == new_run and new_run.i == n_before, "the old timer does nothing: the new pass is untouched")
check(old_run.i == old_i, "and the old pass did not advance")

-- ---------------------------------------------------------------- N: sdc_npc
io.write("N: sdc_npc hook pass on a client\n")
local npc = require("sdc_npc")
local st = { role = "client", remote_pcs = {}, client = { acked = true } }
npc.install(st)
reg_fail, reg_calls = true, 0
local worst, ticks_n, total_calls = 0, 0, 0
for _ = 1, 40 do
    T = T + 0.25
    reg_calls = 0
    local a = T
    npc.tick()
    ticks_n = ticks_n + 1
    total_calls = total_calls + reg_calls
    if (T - a) * 1000 > worst then worst = (T - a) * 1000 end
end
check(worst < 50, "no tick took more than one failing registration (" .. string.format("%.0f", worst) .. " ms)")
check(total_calls >= 8, "the pass goes on over the following ticks (" .. total_calls .. " registrations tried in 40 ticks)")
-- every client hook is tried in the end, and a loaded class installs
reg_fail = false
T = T + 300
local tried = 0
for _ = 1, 40 do T = T + 0.25; reg_calls = 0; npc.tick(); tried = tried + reg_calls end
check(tried >= 8, "once the classes load, the hooks install (" .. tried .. ")")

-- ---------------------------------------------------------------- I: sdc_items
io.write("I: sdc_items hook retries\n")
local items = require("sdc_items")
local G = items._t.hook_gate
reg_fail, reg_calls = true, 0
items._t.try_hook_events()
check(reg_calls == 1, "a pass of the event hooks stops at the first failure (" .. reg_calls .. ")")
reg_calls = 0
items._t.try_hook_events()
check(reg_calls == 1, "the next call goes on with the next hook, never more than one failure per call (" .. reg_calls .. ")")
reg_calls = 0
for _ = 1, 10 do items._t.try_hook_events() end
check(reg_calls <= 5, "7 event hooks, all failing: each tried once, then its back-off (" .. reg_calls .. " more tries in 10 calls)")
reg_calls = 0
items._t.try_hook_durability()
local c1 = reg_calls
items._t.try_hook_durability()
check(c1 == 1 and reg_calls == 1, "a failing durability hook: one try, then the back-off")
reg_calls = 0
items._t.try_hook_battery()
items._t.try_hook_battery()
check(reg_calls == 1, "a failing battery hook: one try, then the back-off (" .. reg_calls .. ")")
-- the back-off ends: tried again (2 s, 4 s ... at most 10 s)
local before = reg_calls
for _ = 1, 8 do T = T + 1.5; items._t.try_hook_events() end
check(reg_calls > before, "tried again later")
local worst_wait = 0
for _, w in pairs(G.wait) do if w > worst_wait then worst_wait = w end end
check(worst_wait <= 4, "the wait is at most 4 s (" .. worst_wait .. ")")
-- a new world: failed hooks are tried at once
items._t.try_hook_durability()
items.reset()
reg_calls = 0
items._t.try_hook_durability()
check(reg_calls == 1, "a world change clears the back-off (" .. reg_calls .. ")")
reg_fail = false
T = T + 20
local n_ok0 = 0
for _ in pairs(items._t.event_hooked) do n_ok0 = n_ok0 + 1 end
for _ = 1, 10 do T = T + 11; items._t.try_hook_events() end

local n_ok = 0
for _ in pairs(items._t.event_hooked) do n_ok = n_ok + 1 end
check(n_ok == 7, "when the class loads all 7 event hooks install (" .. n_ok .. ")")

print = real_print
io.write(string.format("spikes3: %d checks, %d failed\n", checks, fails))
io.write(fails == 0 and "ALL OK\n" or "FAILED\n")
