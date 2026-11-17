-- Mock test: frame-time spikes of the mod (0.12.2 "spikes" group).
--   P  sdc_perf: the worst call of every hook / task per window and the mod's
--      work per frame in the [PERF] line; nested calls counted once
--   G  the paced Lua collector: stopped automatic collector, small steps in
--      the frame loop, a cycle ends, the heap stays bounded, a failing driver
--      hands the collector back
--   S  sdc_session: the 1 s ticks and phase B run in slices of a few ms, in
--      order, a tick is not started over one still waiting, a world change drops
--      the rest
-- usage: lua mock_spikes.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local T = 1000.0
local real_clock = os.clock
os.clock = function() return T end
local TT = 1700000000
os.time = function() return TT end

local LOG = {}
print = function(s) LOG[#LOG + 1] = tostring(s) end
local function logged(p) for _, l in ipairs(LOG) do if l:find(p, 1, true) then return l end end end

-- ---------------------------------------------------------------- P: sdc_perf
print("P: worst calls and work per frame")
FName = function(s) return s end
RegisterHook = function(path, pre, post) return 1, 2 end
NotifyOnNewObject = function() end
local perf = require("sdc_perf")
local ue_stub = { running = nil, task_stats = {} }
package.loaded["sdc_ue"] = ue_stub
local rec_a = perf.record("/Game/X.X_C:Slow")
local rec_b = perf.record("/Game/X.X_C:Fast")
-- a hook of 12 ms, then 1 ms ones; outermost
perf.note_call(rec_a, 12, false)
perf.note_call(rec_b, 1, false)
perf.note_call(rec_b, 1.5, false)
check(rec_a.wmax == 12 and rec_a.over == 1, "hook max 12 ms, one call over SPIKE_MS")
check(rec_b.wmax == 1.5 and rec_b.over == 0, "fast hook: max 1.5 ms, none over")
check(math.abs(perf.work_ms - 14.5) < 1e-9, "the frame's work sums the outermost calls (14.5)")
-- nested: inside another hook, or inside a task: not added again
perf.note_call(rec_b, 30, true)
ue_stub.running = "session"
perf.note_call(rec_b, 40, false)
ue_stub.running = nil
check(math.abs(perf.work_ms - 14.5) < 1e-9, "nested calls are not added to the frame twice")
check(rec_b.wmax == 40, "but their own maximum is kept")
local ts = { calls = 1, ms = 6, wmax = 0, over = 0 }
perf.note_task(ts, 6, false)
check(ts.wmax == 6 and ts.over == 1 and math.abs(perf.work_ms - 20.5) < 1e-9, "a task: max, over, frame work")
perf.frame()
check(perf.work_ms == 0, "the frame reads and clears the work")
perf.note_call(rec_b, 2, false)
perf.frame()
ue_stub.task_stats["session"] = ts
local line = perf.report("window", ue_stub.task_stats)
check(line:find("worst calls: ", 1, true) and line:find("task session 6ms (1 >= 4 ms)", 1, true), "[PERF] names the worst task call: " .. (line:match("worst calls: [^|]*") or "?"))
check(line:find("hook X:Slow 12ms (1 >= 4 ms)", 1, true), "and the worst hook call")
check(line:find("mod work per frame: worst 20.5 ms, 2 of 2 frames >= 4 ms, 1 >= 16 ms", 1, true) ~= nil
    or line:find("mod work per frame: worst 20.5 ms, 1 of 2 frames >= 4 ms, 1 >= 16 ms", 1, true) ~= nil,
    "the frame summary: " .. (line:match("mod work per frame: [^|]*") or "?"))
check(rec_a.wmax == 0 and ts.wmax == 0 and ts.over == 0, "a real window resets the maxima")
local line2 = perf.peek("status", ue_stub.task_stats)
check(line2:find("worst calls: -", 1, true) ~= nil, "the next window starts empty")

-- ---------------------------------------------------------------- G: the paced collector
print("G: paced Lua collector")
local function heap() return collectgarbage("count") end
collectgarbage("collect")
check(perf.set_gc_mode("paced", 150, 200) == true, "paced mode accepted")
check(perf.gc_mode == "paced" and not perf.pace.on and perf.pace.want, "mode set, driver wanted but not started")
check(collectgarbage("isrunning") == true, "setting the mode does NOT stop the collector (main.lua may still die before the frame loop)")
perf.frame()
check(perf.pace.on and collectgarbage("isrunning") == false, "the first frame of the frame loop starts the driver and stops the collector")
-- the automatic collector is stopped: garbage stays until the frame loop collects it
local base = heap()
local keep
for i = 1, 20000 do keep = { i, tostring(i), { i } } end
local grown = heap()
check(grown > base + 500, "the collector is stopped: the heap grows by itself (" .. string.format("%.0f", grown - base) .. " KB)")
-- live data of ~8 MB so a cycle is long
local live = {}
for i = 1, 40000 do live[i] = { id = i, name = "obj" .. i, pos = { x = i, y = i } } end
local frames, worst_n = 0, 0
local cycles0 = perf.pace.cycles
-- frames of fake time: each frame allocates a little, perf.frame() drives the collector
for f = 1, 6000 do
    for i = 1, 40 do keep = { f, i, "s" .. i } end
    local c0 = os.clock
    perf.frame()
    frames = frames + 1
    if perf.pace.cycles >= cycles0 + 2 then break end
end
check(perf.pace.cycles >= cycles0 + 2, "cycles end through the frame loop (" .. (perf.pace.cycles - cycles0) .. " in " .. frames .. " frames)")
check(perf.pace.frames > 0 and perf.pace.frames < frames, "the collector worked only in some frames (" .. perf.pace.frames .. " of " .. frames .. ")")
check(heap() < grown + 20000, "the heap stays bounded (" .. string.format("%.1f", heap() / 1024) .. " MB)")
-- a step is one small piece: the number of steps per frame is capped even if the clock never moves
local steps = 0
local real_cg = collectgarbage
collectgarbage = function(opt, ...)
    if opt == "step" then steps = steps + 1; return false end
    return real_cg(opt, ...)
end
perf.pace.active = true
steps = 0
perf.frame()
check(steps >= 1 and steps <= 400, "a frame with a frozen clock runs at most 400 steps (" .. steps .. ")")
-- far behind (heap 5x the live data): a bigger share, still capped
perf.pace.base_kb = real_cg("count") / 6
steps = 0
perf.frame()
check(steps == 400, "behind: still capped by the step limit (" .. steps .. ")")
collectgarbage = real_cg
-- the 1 s watch: a heap far above the live data is collected there
perf.pace.active = false
perf.pace.base_kb = real_cg("count") / 4
local cyc = perf.pace.cycles
for _ = 1, 40 do perf.gc_watch(); perf.frame(); if perf.pace.cycles > cyc then break end end
check(perf.pace.cycles > cyc, "gc_watch finishes a cycle when the frame loop stood still")
-- the watchdog: no frame for 3 calls (3 s): the automatic collector comes back, the next frame stops it again
perf.pace.active = false
local fr0 = perf.frames
perf.gc_watch(); perf.gc_watch()
check(perf.pace.on and collectgarbage("isrunning") == false, "two silent seconds: still driven")
perf.gc_watch(); perf.gc_watch()
check(not perf.pace.on and collectgarbage("isrunning") == true, "three silent seconds: the automatic collector is back on")
check(logged("no frame for 3 s") ~= nil, "and it says so")
perf.frame()
check(perf.pace.on and collectgarbage("isrunning") == false, "frames again: the driver stops it again")
perf.gc_watch(); perf.frame(); perf.gc_watch(); perf.frame(); perf.gc_watch(); perf.frame(); perf.gc_watch()
check(perf.pace.on, "a watch with frames running between never trips")
-- the paced figures in the window line
local pl = perf.report("window", ue_stub.task_stats)
check(pl:find("paced: ", 1, true) ~= nil and pl:find("gc paced 150/200", 1, true) ~= nil, "[PERF] shows the paced collector: " .. (pl:match("lua heap[^|]*") or "?"))
-- a driver that fails hands the collector back
collectgarbage = function(opt, ...)
    if opt == "step" then error("boom") end
    return real_cg(opt, ...)
end
perf.pace.active = true
perf.frame()
collectgarbage = real_cg
check(perf.pace.on == false and perf.gc_mode == "incremental", "a failing driver: automatic collector back on")
check(collectgarbage("isrunning") == true, "a failing driver: the collector is running again")
perf.frame()
check(perf.pace.on == false and collectgarbage("isrunning") == true, "and the next frame does not start the driver again")
check(logged("paced Lua collector failed") ~= nil, "and it says so")
perf.set_gc_mode("paced", 150, 200); perf.frame()
check(collectgarbage("isrunning") == false, "(paced again)")
check(perf.set_gc_mode("generational") == true and perf.pace.on == false, "another mode switches the driver off")
check(collectgarbage("isrunning") == true, "leaving paced for generational restarts the collector")
perf.set_gc_mode("paced", 150, 200); perf.frame()
perf.set_gc_mode("incremental", 150, 200)
check(collectgarbage("isrunning") == true and not perf.pace.on, "leaving paced for incremental restarts the collector")

-- ---------------------------------------------------------------- S: session slices
print("S: the session ticks in slices")
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_session = true, sdc_log = true, sdc_config = true, sdc_perf = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FText = function(s) return s end
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end
os.execute = function(cmd) error("test tried to run a command: " .. tostring(cmd)) end

local W = { role = "host", menu = false, pc = { key = "pc1" }, pawn = {} }
local timers = {}
local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.net_role = function() return W.role end
ue.in_main_menu = function() return W.menu end
ue.local_pawn = function() return W.pawn end
ue.local_pc = function() return W.pc end
ue.map_name = function() return "PersistentLevel" end
ue.find_all = function() return {} end
ue.find_first = function() return nil end
ue.has_pending_connection = function() return false end
ue.exec_in_progress = false
local parts_run = {}
ue.sub_time = function(label, fn, ...)
    parts_run[#parts_run + 1] = label
    return pcall(fn, ...)
end
ue.delay = function(label, ms, fn) timers[#timers + 1] = { label = label, ms = ms, fn = fn }; return 1 end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_net"] = stub()
local net = package.loaded["sdc_net"]
net.on = function() end
local COST = 0.010
local function costly(name)
    return function() T = T + COST; return nil end
end
-- every part costs 10 ms of fake time
for _, m in ipairs({ "sdc_sync", "sdc_items", "sdc_combat", "sdc_gearfx", "sdc_damage", "sdc_ai", "sdc_ctx", "sdc_dialogue",
                     "sdc_quests", "sdc_players" }) do
    local mod = require(m)
    for _, fn in ipairs({ "host_sound_tick", "host_tick", "tick", "host_skip_save_tick" }) do mod[fn] = costly(m .. "." .. fn) end
end
require("sdc_net").tune_rates = costly("net.tune_rates")
local cfg = require("sdc_config")
cfg.values.listen_on_load = false
cfg.values.auto_join = false
cfg.save = function() return true end
local log = require("sdc_log")
local errs = {}
log.err_throttled = function(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
local session = require("sdc_session")
session.register_handlers()

local function pump()
    local list = timers
    timers = {}
    local worst = 0
    for _, t in ipairs(list) do
        local t0 = T
        t.fn()
        if T - t0 > worst then worst = T - t0 end
    end
    return worst, #list
end

-- the first tick: becoming the host (role change), then the 1 s tick in slices
local t0 = T
session.tick()
local first_slice = T - t0
check(first_slice <= 0.0125 + 1e-9, "the first slice of a tick runs about one part (" .. string.format("%.1f", first_slice * 1000) .. " ms)")
check(#timers >= 1, "the rest of the tick waits for later frames (" .. #timers .. " timer(s))")
local has_backup = false
for _, t in ipairs(timers) do if t.label == "saves-backup" then has_backup = true end end
check(has_backup, "becoming the host does not copy the saves in that frame: a task 'saves-backup' is waiting")
local ran_before = #parts_run
-- a second tick while the first still waits: skipped (no part of it runs)
TT = TT + 1
session.tick()
check(#parts_run == ran_before, "a tick over a tick still waiting is skipped")
-- pump slices until no timer is left (phase B comes 500 ms later: label session-host-b)
local slices, worst_slice, guard = 0, 0, 0
while #timers > 0 and guard < 200 do
    guard = guard + 1
    -- the 500 ms timer of phase B and the 1 ms slices: just run them
    local w = pump()
    slices = slices + 1
    if w > worst_slice then worst_slice = w end
end
check(worst_slice <= 0.0125 + 1e-9, "no later slice is longer than one 10 ms part (" .. string.format("%.1f", worst_slice * 1000) .. " ms)")
check(slices > 8, "the second took many slices (" .. slices .. ")")
local order = {}
for _, l in ipairs(parts_run) do order[#order + 1] = l end
local function index_of(label) for i, l in ipairs(order) do if l == label then return i end end end
check(index_of("h:states") and index_of("h:roster") and index_of("h:ctx") and index_of("h:items") and index_of("h:damage"),
    "every part ran")
check(index_of("h:states") < index_of("h:roster") and index_of("h:roster") < index_of("h:ctx")
    and index_of("h:ctx") < index_of("h:hostmenu"), "phase A parts keep their order")
check(index_of("h:hostmenu") < index_of("h:sounds") and index_of("h:sounds") < index_of("h:items")
    and index_of("h:items") < index_of("h:damage"), "phase B follows phase A, parts in their order")
check(#errs == 0, "no error from the slicing" .. (errs[1] and (": " .. errs[1]) or ""))
-- the next second starts a new run (nothing waits any more)
local before = #parts_run
TT = TT + 1
session.tick()
check(#parts_run > before, "when nothing waits, the next tick runs")
-- a lost timer: the busy flag of a tick would skip every later tick; after 10 s it is cleared
TT = TT + 1
session.tick()
timers = {}                            -- the slice timer never comes
local n_lost = #parts_run
TT = TT + 1
session.tick()
check(#parts_run == n_lost, "a flag younger than 10 s still skips the tick")
T = T + 11
TT = TT + 1
session.tick()
check(#parts_run > n_lost, "after 10 s the stale flag is cleared and the tick runs")
check(logged("its flag is cleared") ~= nil, "and it says so")
while #timers > 0 do pump() end
-- phase B: its 500 ms timer lost
TT = TT + 1
session.tick()
local guard2 = 0
while #timers > 0 and guard2 < 200 do
    guard2 = guard2 + 1
    local list = timers
    timers = {}
    for _, t in ipairs(list) do if not (t.label == "session-host-b" and t.ms == 500) then t.fn() end end
end
local function b_timers() local k = 0 for _, t in ipairs(timers) do if t.label == "session-host-b" and t.ms == 500 then k = k + 1 end end return k end
TT = TT + 1
session.tick()
while #timers > 0 and b_timers() == 0 do pump() end
check(b_timers() == 0, "phase B waiting for a lost timer is not scheduled again at once")
timers = {}
T = T + 11
TT = TT + 1
session.tick()
local guard3 = 0
while #timers > 0 and b_timers() == 0 and guard3 < 200 do guard3 = guard3 + 1; pump() end
check(b_timers() == 1, "after 10 s phase B is scheduled again")
timers = {}
T = T + 11

-- a world change between two slices drops the rest
TT = TT + 1
session.tick()                       -- a new host tick: its first slice runs, the rest waits
local n1 = #parts_run
check(#timers >= 1, "a new tick waits for its later slices")
W.role = "standalone"
TT = TT + 1
session.tick()                       -- the role changed: the waiting slices are of no use
local drained = 0
while #timers > 0 and drained < 50 do drained = drained + 1; pump() end
local host_parts_after = 0
for i = n1 + 1, #parts_run do if parts_run[i]:sub(1, 2) == "h:" then host_parts_after = host_parts_after + 1 end end
check(host_parts_after == 0, "no host part ran after the role changed (" .. host_parts_after .. ")")
check(#timers == 0 and #errs == 0, "the waiting slices ended without an error")

-- no module may use coroutines: UE4SS keys its Lua functions by lua_State, so every UE4SS call
-- (print, RegisterHook, UFunction calls) fails inside a coroutine (in-game, 14.11)
print("N: no coroutines")
do
    local BS = string.char(92)
    local p = io.popen('dir /b "' .. SCRIPTS:gsub("/", BS) .. '"')
    local files = {}
    if p then for l in p:lines() do l = l:gsub("%c", ""); if l:match("%.lua$") then files[#files + 1] = l end end p:close() end
    check(#files > 50, "the scripts folder was listed (" .. #files .. " files)")
    local bad = {}
    for _, f in ipairs(files) do
        local fh = io.open(SCRIPTS .. "/" .. f, "rb")
        if fh then
            local ln = 0
            for line in fh:lines() do
                ln = ln + 1
                local code = line:gsub("%-%-.*$", "")
                if code:find("coroutine%.") then bad[#bad + 1] = f .. ":" .. ln end
            end
            fh:close()
        end
    end
    check(#bad == 0, "no coroutine. in any module" .. (bad[1] and (": " .. table.concat(bad, ", ")) or ""))
end

os.clock = real_clock
print = io.write
io.write(string.format("spikes: %d checks, %d failed\n", checks, fails))
io.write(fails == 0 and "ALL OK\n" or "FAILED\n")
