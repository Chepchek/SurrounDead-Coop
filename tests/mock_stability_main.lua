-- Mock test: main.lua's debug timers and status wiring ("stability" wave,
-- 2026-11-13). main.lua runs for real; every sdc_* module it loads is a stub
-- (any field is a callable stub table), sdc_config is an in-memory fake, the
-- engine timers are recorded instead of run.
--   * the [REPORT] check (2 s) is not scheduled while debug is off; it starts
--     once when debug goes on: at start, sdcoop_debug, sdcoop_set debug, or
--     the settings panel (seen by the 1 s perf task); never twice;
--   * the 1 s perf task samples sdc_speed and starts the gap tracer when
--     gap_trace was switched on in the panel;
--   * sdcoop_status replies sdc_speed's line; ue.actors_of is wrapped by
--     sdc_perf.watch_out_arrays right after sdc_ue loads.
-- usage: lua mock_stability_main.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; io.write("  ok   ", what, "\n") else fails = fails + 1; io.write("  FAIL ", what, "\n") end
end
print = function() end

-- ------------------------------------------------------------ stubs
local function ustub()
    return setmetatable({}, {
        __index = function(self, k)
            local v = ustub()
            rawset(self, k, v)
            return v
        end,
        __call = function() return nil end,
    })
end
-- every sdc_* module main.lua requires is a stub, unless set below
table.insert(package.searchers, 2, function(name)
    if name:sub(1, 4) == "sdc_" then
        return function() return ustub() end
    end
    return nil
end)

-- config: in memory, never on disk
local values = { debug = false, gap_trace = false, perf_report = 60, menu_key = "F7", players_hud_key = "F8" }
local saves = 0
local cfg = {
    path = "(memory)", values = values,
    load = function() end,
    save = function() saves = saves + 1; return true end,
    get = function(k) return values[k] end,
    set = function(k, v)
        if v == "true" then v = true elseif v == "false" then v = false end
        values[k] = v
    end,
}
package.loaded["sdc_config"] = cfg

-- engine timers: recorded
local delays, everies = {}, {}
local ue = ustub()
rawset(ue, "delay", function(label, ms, fn) delays[label] = fn end)
rawset(ue, "every", function(label, ms, fn)
    everies[label] = everies[label] or { n = 0 }
    local e = everies[label]
    e.n, e.ms, e.fn = e.n + 1, ms, fn
end)
rawset(ue, "every_frame", function(label, fn) everies[label] = { n = 1, fn = fn } end)
rawset(ue, "find_all", function() return {} end)
rawset(ue, "in_main_menu", function() return false end)
rawset(ue, "map_name", function() return "TestMap" end)
rawset(ue, "str", function(v) return v ~= nil and tostring(v) or nil end)   -- console parameters
local actors_calls = 0
rawset(ue, "actors_of", function() actors_calls = actors_calls + 1; return { 1, 2 } end)
package.loaded["sdc_ue"] = ue

local log = ustub()
local infos = {}
rawset(log, "info", function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    infos[#infos + 1] = ok and s or tostring(fmt)
end)
package.loaded["sdc_log"] = log

local perf = ustub()
local wrapped_ue = nil
rawset(perf, "watch_out_arrays", function(u)
    wrapped_ue = u
    return true
end)
package.loaded["sdc_perf"] = perf

local samples = 0
local speed = ustub()
rawset(speed, "sample", function() samples = samples + 1 end)
rawset(speed, "status_line", function() return "speed: test line" end)
package.loaded["sdc_speed"] = speed

local gaptrace = ustub()
local gap_inits = 0
rawset(gaptrace, "init", function() gap_inits = gap_inits + 1 end)
package.loaded["sdc_gaptrace"] = gaptrace

local session = ustub()
local S = { role = "host", map = "TestMap", map_since = 0, menu_since = 0 }
rawset(session, "state", S)
rawset(session, "status", function() return { role = "host", title = "test", lines = {} } end)
package.loaded["sdc_session"] = session

-- UE4SS globals main.lua touches at load
local commands = {}
function RegisterConsoleCommandHandler(name, fn) commands[name] = fn end
function RegisterLoadMapPreHook() end

-- ------------------------------------------------------------ load main.lua
local okm, errm = pcall(dofile, SCRIPTS .. "/main.lua")
check(okm, "main.lua runs against the stubs (" .. tostring(errm) .. ")")
check(wrapped_ue == ue, "sdc_perf.watch_out_arrays gets sdc_ue at load")

local function console(name, ...)
    local replies = {}
    local out = { Log = function(_, s) replies[#replies + 1] = s end }
    commands[name](name, { ... }, out)
    return replies
end

-- ------------------------------------------------------------ boot
io.write("== boot, debug off\n")
check(delays.boot ~= nil and delays["report-boot"] ~= nil, "boot and report-boot delays scheduled")
delays.boot()
check(everies.perf ~= nil and everies.perf.ms == 1000, "1 s perf task scheduled")
check(everies.report == nil, "no [REPORT] timer before report-boot")
delays["report-boot"]()
check(everies.report == nil, "debug off at start: no [REPORT] timer at all")
everies.perf.fn()
everies.perf.fn()
check(everies.report == nil, "perf task with debug off: still none")
check(samples == 2, "the perf task samples sdc_speed every second")

-- ------------------------------------------------------------ settings panel: debug on
io.write("== debug switched on in the settings panel\n")
values.debug = true
everies.perf.fn()
check(everies.report and everies.report.n == 1 and everies.report.ms == 2000, "the next perf second starts the 2 s [REPORT] check")
everies.perf.fn()
console("sdcoop_set", "debug", "true")
check(everies.report.n == 1, "never scheduled twice (perf task, sdcoop_set)")
-- the check itself: one report per world, 15 s after it loaded
local n0 = #infos
everies.report.fn()
local reports = 0
for i = n0 + 1, #infos do if infos[i]:find("[REPORT] role=host map=TestMap", 1, true) then reports = reports + 1 end end
check(reports == 1, "[REPORT] written once for the world")
everies.report.fn()
local reports2 = 0
for i = n0 + 1, #infos do if infos[i]:find("[REPORT] role=", 1, true) then reports2 = reports2 + 1 end end
check(reports2 == 1, "and not again for the same world")
-- debug off again: the timer stays but writes nothing
values.debug = false
S.map_since = 5
local n1 = #infos
everies.report.fn()
check(#infos == n1, "debug off again: the check idles")

-- ------------------------------------------------------------ console paths on a fresh load
io.write("== sdcoop_debug / sdcoop_set on a fresh start\n")
delays, everies = {}, {}
values.debug = false
okm, errm = pcall(dofile, SCRIPTS .. "/main.lua")
check(okm, "main.lua loaded again (" .. tostring(errm) .. ")")
delays.boot()
delays["report-boot"]()
check(everies.report == nil, "fresh start, debug off: no timer")
console("sdcoop_debug")
check(values.debug == true and everies.report and everies.report.n == 1, "sdcoop_debug on: the [REPORT] check starts")
console("sdcoop_debug")
console("sdcoop_debug")
check((everies.report or { n = 0 }).n == 1, "toggled off and on: still one timer")
delays, everies = {}, {}
values.debug = false
pcall(dofile, SCRIPTS .. "/main.lua")
delays.boot()
console("sdcoop_set", "debug", "true")
check(everies.report and everies.report.n == 1, "sdcoop_set debug true: the [REPORT] check starts")
delays, everies = {}, {}
values.debug = true
pcall(dofile, SCRIPTS .. "/main.lua")
delays.boot()
delays["report-boot"]()
check(everies.report and everies.report.n == 1, "debug on at start: started 5 s after load")

-- ------------------------------------------------------------ gap trace from the panel
io.write("== gap_trace switched on in the settings panel\n")
delays, everies = {}, {}
values.debug, values.gap_trace = false, false
gap_inits = 0
pcall(dofile, SCRIPTS .. "/main.lua")
delays.boot()
check(everies.gaptrace == nil and gap_inits == 0, "gap_trace off: no tracer")
values.gap_trace = true
everies.perf.fn()
check(everies.gaptrace and everies.gaptrace.n == 1 and gap_inits == 1, "switched on in the panel: started by the perf task")
everies.perf.fn()
console("sdcoop_set", "gap_trace", "true")
check(everies.gaptrace.n == 1 and gap_inits == 1, "never started twice")

-- ------------------------------------------------------------ [PERF] window, then "[PERF] ai steps"
-- (13.11 review item 2, skeptic: a client's zombie steps get a line of their
-- own right after each [PERF] line instead of crowding its 10 "parts")
io.write("== [PERF] window, then sdc_ai's ai steps line\n")
local seq = {}
rawset(perf, "report", function(why) seq[#seq + 1] = "perf:" .. tostring(why) end)
local real_clock, fake_clock = os.clock, 0
os.clock = function() fake_clock = fake_clock + 100; return fake_clock end   -- each call: a new 60 s window
package.loaded["sdc_ai"] = { perf_report = function() seq[#seq + 1] = "ai" end }
everies.perf.fn()
check(table.concat(seq, ",") == "perf:window,ai", "the [PERF] line, then sdc_ai.perf_report (" .. table.concat(seq, ",") .. ")")
package.loaded["sdc_ai"] = { perf_report = function() error("test error") end }
check(pcall(everies.perf.fn) == true, "an error in it does not break the perf task")
package.loaded["sdc_ai"] = nil
seq = {}
everies.perf.fn()
check(table.concat(seq, ",") == "perf:window", "sdc_ai not loaded: the [PERF] line alone")
os.clock = real_clock

-- ------------------------------------------------------------ sdcoop_status
io.write("== sdcoop_status\n")
local replies = console("sdcoop_status")
local has = false
for _, r in ipairs(replies) do if r:find("speed: test line", 1, true) then has = true end end
check(has, "sdcoop_status replies sdc_speed's line")

io.write(string.format("mock_stability_main: %d passed, %d failed\n", passed, fails))
io.write(fails == 0 and "ALL OK\n" or "FAILED\n")
os.exit(fails == 0 and 0 or 1)
