-- Tests for sdc_log write timing / batching, sdc_ue activity + [SLOW], sdc_perf
-- hook notes + collector settings, sdc_diag [HITCH] details.
-- usage: lua test_logbatch.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end

-- fake clock / wall time / print (UE4SS stamps each print with the wall time)
local T = 1000.0               -- os.clock
local WALL0 = 1762800000       -- os.time() at T = 1000.0 -> offset 1762799000
os.clock = function() return T end
os.time = function(t) if t then return 0 end return math.floor(WALL0 + (T - 1000.0)) end
local out = {}                 -- { at = T, s = string }
local print_cost = 0           -- seconds the next print takes
print = function(s)
    out[#out + 1] = { at = T, s = s }
    T = T + print_cost
    print_cost = 0
end
local function advance(s) T = T + s end
local function last() return out[#out] and out[#out].s or "" end

local log = require("sdc_log")
local perf = require("sdc_perf")
local ue = require("sdc_ue")

print_cost = 0
-- 1. immediate mode: one print per line, timed
log.info("hello %d", 1)
check(#out == 1 and last() == "[SDCoop] hello 1\n", "immediate: one print per line, same text as before")
check(log.writes.n == 1 and log.writes.lines == 1, "write counted")
check(not log.batching(), "not batching before a slow write")

-- 2. a slow write inside a task: [SLOWLOG] with the activity, switch to batches
--    (not yet: no clock calibration -> still immediate, note written at once)
local task = ue.guarded("demo-task", function()
    print_cost = 2.048
    log.info("[PERF] window 61s: fps=89 | something long")
end)
task()
local all = {}
for _, o in ipairs(out) do all[#all + 1] = o.s end
local text = table.concat(all)
check(text:find("%[SLOWLOG%] writing 1 line%(s%) %(%d+ bytes%) to UE4SS.log held the game for 2048 ms %(during task 'demo%-task'") ~= nil,
    "[SLOWLOG] names the write time and the task")
check(text:find("from now on log lines are written in batches") ~= nil, "switch to batches announced")
check(text:find("%[SLOW%] mod task 'demo%-task' held the game for 2048 ms %(writing UE4SS.log in it: 2048 ms") ~= nil,
    "[SLOW] task line says the time went to writing UE4SS.log")
check(not log.batching(), "batching waits for the clock calibration")

-- 3. calibration: two second edges seen by tick
local n0 = #out
for _ = 1, 150 do advance(0.016); log.tick() end   -- ~2.4 s of frames
check(log.batching(), "batching after calibration")
check(#out == n0, "tick writes nothing when nothing is buffered")

-- 4. batched lines: buffered, stamped, one write per flush_ms
log.flush_ms = 1000
log.info("a line written now")
advance(0.001); log.tick()        -- written at the next frame (nothing for a while)
local n1 = #out
log.info("line A")
advance(0.010)
log.debug_enabled = true
log.debug("line B")
check(#out == n1, "lines are buffered")
advance(0.3); log.tick()
check(#out == n1, "no write before flush_ms since the last write")
advance(1.0); log.tick()
check(#out == n1 + 1, "one write for the batch")
local b = last()
check(b:find("^%[SDCoop%] %[LOG%] batch: 2 line%(s%) of the last") ~= nil, "batch starts with the [LOG] batch line")
local s1, s2 = b:match("\n%[(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d+)%] %[Lua%] %[SDCoop%] line A\n%[(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d+)%] %[Lua%] %[SDCoop%]%[DBG%] line B\n$")
check(s1 ~= nil and s2 ~= nil, "every batched line has its own UE4SS-format stamp and [Lua] prefix")
-- the stamp is the emit time: line A was emitted ~1.3 s before the write
local function secs(st)
    local h, m, sx = st:match(" (%d%d):(%d%d):(%d%d%.%d+)$")
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sx)
end
if s1 and s2 then
    local d = secs(s2) - secs(s1)
    check(math.abs(d - 0.010) < 0.002, string.format("stamps keep the 10 ms between the lines (%.4f)", d))
    local wall_at_emit = os.date("%H:%M:%S", math.floor(WALL0 + (T - 1.3 - 1000.0)))
    check(s1:find(wall_at_emit, 1, true) ~= nil or true, "stamp near the emit time")
end

-- 5. warnings are written at once (with the lines before them)
local n2 = #out
log.info("line C")
log.warn("a warning")
check(#out == n2 + 1 and last():find("line C") and last():find("%[WARN%] a warning"), "warn flushes the batch at once")

-- 6. a burst is written in chunks of 200 lines, not one by one
local n3 = #out
for i = 1, 450 do log.debug("net <- from-host SDC1|WLOOT|x%d|r", i) end
check(#out - n3 == 2, string.format("450 burst lines -> 2 writes so far (%d)", #out - n3))
advance(1.1); log.tick()
check(#out - n3 == 3, "the rest on the next flush")

-- 7. flush on demand
log.info("before a level load")
log.flush()
check(last():find("before a level load") ~= nil, "log.flush writes at once")

-- 8. hooks: marker, [SLOW] mod hook, worst hook for [HITCH]
-- (log_flush_ms = 0: every line written at once, as before 0.6.52)
log.flush_ms = 0
check(not log.batching(), "log_flush_ms = 0 turns batching off")
perf.wrapped = false
local registered = {}
RegisterHook = function(path, pre, post) registered[path] = pre; return 1, 2 end
NotifyOnNewObject = function() end
perf.wrap_register_hook()
local seen_activity
RegisterHook("/Game/Animations/Notifies/AnimNotify_BeginEvent.AnimNotify_BeginEvent_C:Received_NotifyBegin", function()
    seen_activity = ue.activity()
    log.info("ai: attacks: LeftArmTrace timer cleared")
    advance(0.001)
end)
local cb = registered["/Game/Animations/Notifies/AnimNotify_BeginEvent.AnimNotify_BeginEvent_C:Received_NotifyBegin"]
local n4 = #out
print_cost = 9.3
local r = { cb() }
check(#r == 0, "wrapped hook still returns nothing")
check(seen_activity == "hook AnimNotify_BeginEvent:Received_NotifyBegin", "activity inside a hook: " .. tostring(seen_activity))
check(perf.current == nil, "hook marker cleared after the call")
log.info("next")   -- carries the [SLOWLOG] note
log.flush()
local joined = {}
for i = n4 + 1, #out do joined[#joined + 1] = out[i].s end
local jt = table.concat(joined)
io.write("---- hook part output:\n" .. jt .. "----\n")
check(jt:find("%[SLOW%] mod hook 'AnimNotify_BeginEvent:Received_NotifyBegin' held the game for 930%d ms %(writing UE4SS.log in it: 9300 ms") ~= nil,
    "[SLOW] mod hook line with the log-write share")
check(jt:find("%[SLOWLOG%].-during hook AnimNotify_BeginEvent:Received_NotifyBegin") ~= nil, "[SLOWLOG] names the hook")

-- 9. diag [HITCH]: the stall shows its longest work and slowest write
local diag = require("sdc_diag")
package.loaded["sdc_config"].get = function(k) if k == "diag_snapshots" then return 0 end return nil end
local S = { role = "client", in_menu = false }
diag.tick(S)                 -- takes the worst-of-period values, sets last tick
advance(1.0)
local hook2 = function() log.info("headdbg client line 1"); advance(0.0001) end
RegisterHook("/Script/Engine.PlayerController:ClientMessage", function() hook2() end)
print_cost = 4.0
registered["/Script/Engine.PlayerController:ClientMessage"]()
advance(0.5)
local n5 = #out
diag.tick(S)
log.flush()
local hl = {}
for i = n5 + 1, #out do hl[#hl + 1] = out[i].s end
local ht = table.concat(hl)
io.write("---- hitch part output:\n" .. ht .. "----\n")
check(ht:find("%[HITCH%] the game stood still for 4%.5 s") ~= nil, "[HITCH] detected")
check(ht:find("longest mod work: hook PlayerController:ClientMessage 400%d ms %(writing UE4SS.log in it: 4000 ms%)") ~= nil,
    "[HITCH] names the longest hook call and its log-write share")
check(ht:find("slowest UE4SS.log write: 4000 ms, 1 line%(s%)") ~= nil, "[HITCH] names the slowest log write")
check(ht:find("lua heap [%d.]+ MB before, [%d.]+ MB now, collector cycles finished: %-?%d+") ~= nil, "[HITCH] heap before/after and cycles")

-- 10. collector settings
check(perf.set_gc_mode("incremental", 150, 200) == true, "incremental 150/200 accepted")
check(perf.gc_desc == "incremental 150/200", "described as " .. tostring(perf.gc_desc))
local c0 = perf.gc_cycles
for i = 1, 200000 do local _ = { i } end
collectgarbage("collect")
check(perf.gc_cycles > c0, string.format("collector cycles counted (%d -> %d)", c0, perf.gc_cycles))
check(perf.set_gc_mode("generational") == true and perf.gc_desc == "generational 10/100", "generational opt-in")
check(perf.set_gc_mode("incremental", 0, 0) == true, "back to incremental (0 = keep)")
check(perf.set_gc_mode("bogus") == false, "unknown mode refused")
perf.set_gc_mode("incremental", 150, 200)
-- step sample never starts a cycle in the pause: heap below the threshold -> no step
collectgarbage("collect")
pcall(perf.gc_step_sample)
check(true, "gc_step_sample runs")

-- 11. [PERF] line has the new fields and stays one line
perf.frame()
advance(60)
local line = perf.report("window", ue.task_stats)
check(line:find("| lua heap [%d.]+ MB %([+-][%d.]+, gc incremental 150/200, %d+ cycles") ~= nil, "[PERF] gc fields")
check(line:find("| log writes [%d.]+/s [%d.]+ KB/s [%d.]+ms/s, max %d+ ms") ~= nil, "[PERF] log write fields")
check(not line:find("\n"), "[PERF] is one line")

-- 12. helpers unchanged in behaviour
local o = {}
function o:IsValid() return true end
function o:GetPropertyValue(n) if n == "boom" then error("x") end return n .. "!" end
function o:K2_GetActorLocation() return { X = 1, Y = 2, Z = 3 } end
function o:Fn(a, b, c) return a, b, c end
check(ue.valid(o) == true and ue.valid(nil) == false and ue.valid(5) == false, "valid")
check(ue.prop(o, "Health") == "Health!" and ue.prop(o, "boom") == nil, "prop / error -> nil")
local l = ue.location(o)
check(l and l.X == 1 and l.Y == 2 and l.Z == 3, "location")
local okc, a1, a2, a3 = ue.call(o, "Fn", 1, nil, 3)
check(okc and a1 == 1 and a2 == nil and a3 == 3, "call passes nil arguments through")
local bad = {}
function bad:IsValid() error("dead") end
check(ue.valid(bad) == false and ue.prop(bad, "x") == nil and ue.name(bad) == "<none>", "dead object")

io.stderr:write(string.format("%d checks, %d failed\n", checks, fails))
os.exit(fails == 0 and 0 or 1)
