-- Mock test: frame-time spikes of the mod (0.12.2 "spikes" group, part 2).
--   W  sdc_world: the hook registration pass stops after 3 ms and goes on at the next tick
--      (a failing RegisterHook costs ~22 ms); HV.find looks at the harvestable made by this very
--      swing first, not at every one seen before
--   B  sdc_session / sdc_savecheck: the save backup runs in a task of its own, the pruning of old
--      backups in another
--   C  sdc_consume: the craft check looks up only the components it asks about (one property per
--      slot, stops when all are found)
--   D  sdc_damage: one periodic weapon re-read per tick
-- usage: lua mock_spikes2.lua <scripts dir>
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
print = function() end

local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_world = true, sdc_log = true, sdc_config = true, sdc_consume = true, sdc_damage = true,
               sdc_session = true, sdc_savecheck = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
NotifyOnNewObject = function() end
local reg_calls, reg_fail = 0, true
RegisterHook = function(path)
    reg_calls = reg_calls + 1
    if reg_fail then
        T = T + 0.022
        error("Tried to register a hook for a UFunction that doesn't exist")
    end
    return 1, 2
end

-- one ue for all: objects are tables, a path finds an object of the table PATHS
local PATHS, find_calls = {}, 0
local ue = stub()
ue.valid = function(o) return type(o) == "table" and o.__valid ~= false end
ue.find_object = function(p) find_calls = find_calls + 1; return PATHS[p] end
ue.location = function(o) return o and o.__loc end
ue.find_all_recent = function() return {} end
local prop_reads = 0
ue.prop = function(o, k) prop_reads = prop_reads + 1; return type(o) == "table" and rawget(o, k) or nil end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.class_name = function(o) return type(o) == "table" and o.__cls or "" end
ue.short = function(o) return type(o) == "table" and (o.__name or "obj") or "<none>" end
ue.name = ue.short
ue.sub_time = function(_, fn, ...) return pcall(fn, ...) end
ue.pawn_of = function(pc) return pc and pc.Pawn end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__a or nil end }

-- ---------------------------------------------------------------- W: sdc_world
io.write("W: world hooks and HV.find\n")
local world = require("sdc_world")
local HOOKS = world._t.hooks
local n_hooks = #HOOKS
check(n_hooks > 60, "the hook list is long (" .. n_hooks .. ")")
-- the main menu: nothing is loaded, every registration fails and takes 22 ms
local ticks, t0 = 0, T
reg_calls = 0
world._t.try_hooks(false)
check(reg_calls >= 1 and reg_calls <= 3, "the first tick's pass stops after the first slow failure (" .. reg_calls .. " calls, "
    .. string.format("%.0f", (T - t0) * 1000) .. " ms)")
local worst = (T - t0) * 1000
while HOOKS.cursor and ticks < 500 do
    ticks = ticks + 1
    T = T + 0.25
    local a = T
    world._t.try_hooks(false)
    if (T - a) * 1000 > worst then worst = (T - a) * 1000 end
end
check(HOOKS.cursor == nil and ticks > 30, "the pass went on tick by tick until the end (" .. ticks .. " ticks)")
check(worst < 50, "no tick took more than one failing registration (" .. string.format("%.0f", worst) .. " ms)")
local calls_after_pass = reg_calls
T = T + 1
world._t.try_hooks(false)
check(reg_calls == calls_after_pass, "the next pass waits 3 s after the end of the last one")
T = T + 3.5
world._t.try_hooks(false)
check(reg_calls > calls_after_pass, "then a new pass starts")
-- forced (a test / natives): the whole list in one call
HOOKS.cursor = nil
local before = reg_calls
world._t.try_hooks(true)
check(reg_calls - before >= n_hooks - 10, "force: one call tries every hook (" .. (reg_calls - before) .. ")")
-- the main menu: the next pass comes 15 s after the end of the last, not 3 s
reg_fail = true
ue.in_main_menu = function() return true end
HOOKS.cursor = nil
T = T + 20
local guard = 0
repeat
    guard = guard + 1
    T = T + 0.25
    world._t.try_hooks(false)
until HOOKS.cursor == nil or guard > 500
check(HOOKS.idle == 15, "in the main menu a failed pass is retried after 15 s (idle " .. tostring(HOOKS.idle) .. ")")
local c15 = reg_calls
T = T + 10
world._t.try_hooks(false)
check(reg_calls == c15, "10 s later nothing is tried")
T = T + 6
world._t.try_hooks(false)
check(reg_calls > c15, "after 15 s the next pass starts")
ue.in_main_menu = function() return false end

-- the world is loaded: everything hooks quickly, over a few ticks at most
reg_fail = false
HOOKS.cursor = nil
T = T + 5
world._t.try_hooks(false)
check(HOOKS.cursor == nil, "registrations that work run in one pass (no slow call)")

-- reset: the first pass of a new world is not held back; a natives-only call leaves a pass in progress alone
HOOKS.idle, HOOKS.cursor = 15, 7
world._t.try_hooks(true, true)
check(HOOKS.cursor == 7, "try_hooks(true, true) (the reset's natives call) keeps the cursor of a pass in progress")
local ok_reset = pcall(world.reset, "test")
check(ok_reset and HOOKS.idle == nil and HOOKS.cursor == nil, "world reset clears the idle wait and the cursor")
reg_fail = false
local cr = reg_calls
world._t.try_hooks(false)
check(reg_calls > cr, "and the first pass of the new world starts at once (no 3 / 15 s wait)")
reg_fail = true

-- HV.find: the harvestable made by this swing first
local HV = world._t.harvest
HV.live = {}
for i = 1, 3000 do
    local p = "/p/old" .. i
    HV.live[p] = { kind = "r", t = 10 }
    PATHS[p] = { __loc = { X = 100000 + i, Y = 0, Z = 0 } }
end
HV.live["/p/new"] = { kind = "r", t = 100 }
PATHS["/p/new"] = { __loc = { X = 10, Y = 0, Z = 0 }, __name = "new" }
find_calls = 0
local got = HV.find("r", { X = 0, Y = 0, Z = 0 }, 99.5)
check(got == PATHS["/p/new"] and find_calls == 1, "the new harvestable is found with one engine lookup (" .. find_calls .. ")")
find_calls = 0
got = HV.find("r", { X = 0, Y = 0, Z = 0 })
check(got == PATHS["/p/new"] and find_calls == 3001, "without `since` every one seen is looked at (" .. find_calls .. ")")
find_calls = 0
got = HV.find("r", { X = 100000 + 7, Y = 0, Z = 0 }, 99.5)
check(got == PATHS["/p/old7"], "an older one is still found when no new one is near (fallback to all)")
HV.live["/p/gone"] = { kind = "r", t = 100 }
got = HV.find("r", { X = 10, Y = 0, Z = 0 }, 99.5)
check(got == PATHS["/p/new"] and HV.live["/p/gone"] == nil, "an entry the engine no longer has is dropped")

-- ---------------------------------------------------------------- B: backups
io.write("B: save backups\n")
local timers = {}
ue.delay = function(label, ms, fn) timers[#timers + 1] = { label = label, ms = ms, fn = fn }; return 1 end
local sc = require("sdc_savecheck")
check(type(sc.after_backup) == "function", "sdc_savecheck loads")
-- a successful, verified backup: the check at once, the pruning later
local pruned = 0
local real_prune = sc.prune_backups
sc.prune_backups = function() pruned = pruned + 1; return 0 end
ue.ems_current_slot = function() return nil end
local ok = sc.after_backup("C:\\none\\2026", 1, true)
check(ok == true and pruned == 0 and #timers == 1 and timers[1].label == "saves-prune", "deferred: no prune yet, a task 'saves-prune' waits")
timers[1].fn()
check(pruned == 1, "the task prunes")
timers = {}
sc.after_backup("C:\\none\\2026", 1)
check(pruned == 2 and #timers == 0, "without defer (a test, an old caller): at once")
sc.after_backup("C:\\none\\2026", 9, true)
check(pruned == 2 and #timers == 0, "a failed backup prunes nothing")
sc.prune_backups = real_prune

-- ---------------------------------------------------------------- C: consume
io.write("C: craft check lookups\n")
local consume = require("sdc_consume")
local function slot(uid, n)
    return { ItemUniqueID = { A = uid, B = 0, C = 0, D = 0 }, ItemCount = n, JigDataAsset = { __name = "DA_X" }, __valid = true }
end
local function arr(list)
    return { ForEach = function(self, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end }
end
local conts = {}
for c = 1, 3 do
    local slots = {}
    for i = 1, 30 do slots[i] = slot(c * 1000 + i, 1) end
    conts[c] = { __a = c, ArrayOfItems = arr(slots), __valid = true }
end
local jig = { LocalJSIContainers = arr(conts), __valid = true }
local function count_all(view) local n = 0 for _ in pairs(view) do n = n + 1 end return n end
local full = consume._t.client_view(jig)
check(count_all(full) == 90, "the full view has 90 items")
local sh = tostring(next(full))
local want = { left = 2, ["1005:0:0:0"] = true, ["1007:0:0:0"] = true }
local part = consume._t.client_view(jig, nil, want)
check(part["1005:0:0:0"] and part["1007:0:0:0"] and count_all(part) == 2, "a wanted view has only the wanted items")
check(want.left == 0, "and counts them off")
prop_reads = 0
consume._t.client_view(jig, nil, { left = 1, ["3030:0:0:0"] = true })
local reads_last = prop_reads
prop_reads = 0
consume._t.client_view(jig)
local reads_full = prop_reads
check(reads_last < reads_full / 2, "a lookup reads far fewer properties than the full scan (" .. reads_last .. " vs " .. reads_full .. ")")
prop_reads = 0
consume._t.client_view(jig, nil, { left = 1, ["1001:0:0:0"] = true })
check(prop_reads < reads_last / 3, "and stops early when the item is in the first container (" .. prop_reads .. ")")

-- ---------------------------------------------------------------- D: damage
io.write("D: weapon re-read per tick\n")
local equipped = {}
package.loaded["sdc_items"] = { equipped_of = function() return equipped end }
local damage = require("sdc_damage")
local dcfg = require("sdc_config")
local builds = 0
-- every weapon of the remote pawn
local weapons = {}
local slot_names = { "Jig.PlayerSlot.PrimaryWeapon", "Jig.PlayerSlot.SecondaryWeapon", "Jig.PlayerSlot.SidearmWeapon", "Jig.PlayerSlot.MeleeWeapon" }
local pawn = { __a = 99, __valid = true, __name = "Pawn" }
for i, sn in ipairs(slot_names) do
    local w = { __a = 200 + i, __valid = true, __name = "Weapon" .. i, __cls = "BP_Firearm_C" }
    weapons[i] = w
    equipped[w.__a] = { slot = sn, actor = w }
end
local pc = { __a = 50, Pawn = pawn, __valid = true, __name = "PC" }
local shorts = 0
ue.short = function(o) if type(o) == "table" and o.__cls == "BP_Firearm_C" then shorts = shorts + 1 end return type(o) == "table" and (o.__name or "obj") or "<none>" end
local S = { role = "host", remote_pcs = { pc } }
damage.init(S)
dcfg.values = dcfg.values or {}
local function tick() damage.host_tick({ pc }) end
shorts = 0
tick()
check(shorts == 4, "the first tick builds the four weapons (" .. shorts .. ")")
shorts = 0
T = T + 1; tick()
check(shorts == 0, "a second later: nothing is re-read")
T = T + 5; shorts = 0; tick()
check(shorts == 1, "after REFRESH_S only ONE weapon is re-read in the tick (" .. shorts .. ")")
T = T + 1; shorts = 0; tick()
check(shorts == 1, "the next tick re-reads the next one (" .. shorts .. ")")
T = T + 1; shorts = 0; tick()
T = T + 1; shorts = 0; tick()
T = T + 1; shorts = 0; tick()
check(shorts == 0, "when all four are fresh again, none (" .. shorts .. ")")
-- a changed weapon (another one in the slot) is built at once, not queued
local w5 = { __a = 300, __valid = true, __name = "Weapon5", __cls = "BP_Firearm_C" }
for k in pairs(equipped) do equipped[k] = nil end
equipped[300] = { slot = slot_names[1], actor = w5 }
shorts = 0
T = T + 1; tick()
check(shorts == 1, "a new weapon is built in its own tick (" .. shorts .. ")")

print = real_print
io.write(string.format("spikes2: %d checks, %d failed\n", checks, fails))
io.write(fails == 0 and "ALL OK\n" or "FAILED\n")
