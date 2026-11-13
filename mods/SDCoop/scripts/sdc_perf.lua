-- SDCoop performance report: what the mod costs the game, per hook and task.
--
-- Every hook the mod registers (RegisterHook, native and Blueprint, and
-- NotifyOnNewObject) is counted: calls and time spent in its Lua callbacks.
-- Scheduled tasks are timed in sdc_ue.guarded (ue.task_stats). Frames are
-- counted from main.lua's per-frame loop. Every `perf_report` seconds one
-- "[PERF]" line lists the fps and the most expensive hooks and tasks of that
-- window, in calls/s and ms/s (ms of game time per second: 16 ms/s is a full
-- frame at 60 fps every second). sdcoop_status shows the running window so
-- far, read-only (M.peek: the window and its maxima go on).
-- os.clock has ~1 ms steps on Windows; summed over many calls it still gives
-- an unbiased total. The line ends with the Lua heap and collector (mode,
-- cycles finished, worst sampled step) and the UE4SS.log writes of the window
-- (sdc_log: writes/s, KB/s, ms/s, the slowest, how many held the game >= 100
-- ms, whether lines are batched).
-- A single hook call of 100 ms or more is logged as "[SLOW] mod hook" (like
-- sdc_ue's tasks); the hook running now is M.current (sdc_ue.activity).
-- While sdc_ctx's player-0 hooks run, the line ends with "ctx:" (calls,
-- cache misses, redirects and their ms, the argument-read floor per call);
-- before it, how fast the world ran here (sdc_speed: game speed, dilation,
-- world time lost to hitches, pauses, how far apart the 1 s timer ran).
-- Hooks are counted by kind (M.reg: Blueprint / native / new-object). Debug
-- switch perf_bench_no_bp_hooks: the mod registers NO Blueprint hook (UE4SS
-- then skips its search after every Blueprint call) - a single-player A/B
-- measurement with sdcoop_bench (sdc_bench); co-op does not work so.
--
-- wrap_register_hook() must run before any module registers a hook (main.lua
-- calls it first).

local log = require("sdc_log")

local clock = os.clock
local M = { hooks = {}, frames = 0, wrapped = false }
local win = { t0 = os.clock(), frames = 0, hooks = {}, tasks = {} }
-- UE4SS.log writes (sdc_log): the table lives as long as the module
local writes = type(log.writes) == "table" and log.writes or { n = 0, lines = 0, bytes = 0, ms = 0, max = 0, slow = 0 }

-- The hook callback running now (its record; nil between hooks): what the
-- mod was doing when a UE4SS.log write or the game stalled (sdc_ue.activity).
M.current = nil
-- the longest single hook call (>= NOTE_MS) since sdc_diag last took it
local NOTE_MS = 50
local SLOW_HOOK_MS = 100
local worst_hook = { ms = 0 }

-- A hook call of NOTE_MS or more: the longest one for [HITCH], and a
-- "[SLOW] mod hook" line like the tasks' (the worst of each hook again when
-- it gets worse, and every one of a second or more).
function M.note_hook(rec, ms, log_ms)
    if ms > worst_hook.ms then worst_hook = { ms = ms, name = rec.name, log_ms = log_ms } end
    if ms >= SLOW_HOOK_MS and (ms > (rec.slow or 0) * 1.5 or ms >= 1000) then
        rec.slow = math.max(ms, rec.slow or 0)
        log.warn("[SLOW] mod hook '%s' held the game for %.0f ms (writing UE4SS.log in it: %.0f ms; lua heap %.1f MB)",
            tostring(rec.name), ms, log_ms or 0, collectgarbage("count") / 1024)
    end
end

function M.take_worst_hook()
    local w = worst_hook
    worst_hook = { ms = 0 }
    return w
end

-- "Class:Function" of a hook path; a shared native hook's subscriber
-- (sdc_ue.hook_native: "<path>#<key>", the key may hold dots and colons, e.g.
-- "ai.PlayerController:ClientRepObjRef") keeps its key: "Class:Function#key".
local function short(path)
    path = tostring(path)
    local base, key = path:match("^(.-)#(.*)$")
    if base then return short(base) .. "#" .. key end
    local cls, fn = path:match("([%w_]+):([%w_ %-]+)$")
    if cls then return cls:gsub("_C$", "") .. ":" .. fn end
    return path:match("[^/.]+$") or path
end

local function record(path)
    local r = M.hooks[path]
    if not r then
        r = { name = short(path), calls = 0, ms = 0 }
        M.hooks[path] = r
    end
    return r
end
-- sdc_ue.hook_native: one engine hook per native function, its subscribers
-- counted here one by one ("Class:Function#subscriber").
M.record = record

-- keeps the callback's exact return values (none stays none)
local function wrap(fn, rec)
    if type(fn) ~= "function" then return fn end
    local function finish(t0, prev, w0, ...)
        local ms = (clock() - t0) * 1000
        rec.calls = rec.calls + 1
        rec.ms = rec.ms + ms
        M.current = prev
        if ms >= NOTE_MS then pcall(M.note_hook, rec, ms, writes.ms - w0) end
        return ...
    end
    return function(...)
        local prev = M.current
        M.current = rec
        return finish(clock(), prev, writes.ms, fn(...))
    end
end

-- ---------------------------------------------------------------------------
-- Hooks registered, by kind (sdcoop_bench, [PERF] in bench mode)
-- ---------------------------------------------------------------------------
-- UE4SS keeps two kinds (LuaMod.cpp RegisterHook): a native UFunction
-- (FUNC_Native) gets its own pre/post hook, called only for that function; a
-- Blueprint function goes into one list (m_script_hook_callbacks) that UE4SS
-- searches after EVERY Blueprint function call in the game while the list is
-- not empty (a lock, a vector of the function's names, a linear search).
M.reg = { bp = 0, native = 0, notify = 0, skipped_bp = 0, failed = 0 }
local FUNC_NATIVE = 0x00000400
local kind_cache = {}   -- [path] = "bp" | "native"
local function m_flags(f) return f:GetFunctionFlags() end
local function m_isvalid(o) return o:IsValid() end

-- "bp" | "native" for a hook path: the UFunction's own flags, else by path
-- (/Script/ = C++; the mod hooks no Blueprint events of C++ classes).
function M.hook_kind(path)
    path = tostring(path)
    local k = kind_cache[path]
    if k then return k end
    if type(StaticFindObject) == "function" then
        local okf, f = pcall(StaticFindObject, path)
        if okf and f ~= nil then
            local okv, valid = pcall(m_isvalid, f)
            if okv and valid == true then
                local okg, flags = pcall(m_flags, f)
                if okg and math.type(flags) == "integer" then
                    k = (flags & FUNC_NATIVE) ~= 0 and "native" or "bp"
                end
            end
        end
    end
    k = k or (path:sub(1, 8) == "/Script/" and "native" or "bp")
    kind_cache[path] = k
    return k
end

-- Debug switch perf_bench_no_bp_hooks: read once, at the first hook after
-- config.ini was loaded (all of the mod's hooks come after it), then fixed
-- for the session. sdc_config's SCHEMA key; before that key exists there,
-- the line in config.ini itself.
local bench_flag = nil
local function ini_flag(path, key)
    local f = path and io.open(path, "r")
    if not f then return false end
    local v = false
    for line in f:lines() do
        local k, val = line:match("^%s*([%w_]+)%s*=%s*(%S*)")
        if k == key then
            val = val:lower()
            v = val == "true" or val == "1" or val == "yes" or val == "on"
        end
    end
    f:close()
    return v
end

function M.bench_no_bp()
    if bench_flag ~= nil then return bench_flag end
    local cfg = package.loaded["sdc_config"]
    if type(cfg) ~= "table" or not cfg.path then return false end   -- config not loaded yet
    local known = false
    for _, s in ipairs(type(cfg.SCHEMA) == "table" and cfg.SCHEMA or {}) do
        if s[1] == "perf_bench_no_bp_hooks" then known = true break end
    end
    local ok, v
    if known then
        ok, v = pcall(cfg.get, "perf_bench_no_bp_hooks")
        v = ok and v == true
    else
        ok, v = pcall(ini_flag, cfg.path, "perf_bench_no_bp_hooks")
        v = ok and v == true
    end
    bench_flag = v
    if v then
        log.warn("perf: BENCH MODE (perf_bench_no_bp_hooks = true): the mod registers none of its Blueprint hooks this"
            .. " session, so UE4SS skips its per-Blueprint-call hook search; co-op does not work in this mode")
        local ue = package.loaded["sdc_ue"]
        if type(ue) == "table" and type(ue.delay) == "function" then
            pcall(ue.delay, "bench-mode-toast", 20000, function()
                log.toast("Режим замера: перехваты Blueprint мода выключены (perf_bench_no_bp_hooks). Кооператив в этом"
                    .. " режиме не работает - после замера выключите настройку.", "warn", 12,
                    "bench mode: the mod's Blueprint hooks are off (perf_bench_no_bp_hooks)")
            end)
        end
    end
    return v
end

-- sdc_ue.hook_native and the RegisterHook wrapper: true = do not register
-- this one (a Blueprint function while the bench switch is on).
function M.bench_skip(path)
    if M.hook_kind(path) ~= "bp" or not M.bench_no_bp() then return false end
    M.reg.skipped_bp = M.reg.skipped_bp + 1
    if M.reg.skipped_bp <= 3 then
        log.info("perf: bench mode: Blueprint hook %s not registered", short(path))
    end
    return true
end

-- An engine hook registered (sdc_ue.hook_native calls this for its own).
function M.note_hook_registered(path)
    local k = M.hook_kind(path)
    M.reg[k] = (M.reg[k] or 0) + 1
    return k
end

function M.wrap_register_hook()
    if M.wrapped then return end
    M.wrapped = true
    if type(RegisterHook) == "function" then
        local orig = RegisterHook
        M.raw_register_hook = orig   -- sdc_ue.hook_native times its subscribers itself
        RegisterHook = function(path, pre, post, ...)
            -- bench mode: a Blueprint hook is not registered; the caller
            -- sees ids as from UE4SS (no module unregisters hooks)
            if M.bench_skip(path) then return -1, -1 end
            local rec = record(path)
            local r1, r2 = orig(path, wrap(pre, rec), wrap(post, rec), ...)
            rec.kind = M.note_hook_registered(path)
            return r1, r2
        end
    end
    if type(NotifyOnNewObject) == "function" then
        local orig = NotifyOnNewObject
        NotifyOnNewObject = function(path, fn, ...)
            local rec = record("new " .. tostring(path))
            rec.kind = "notify"
            local r = table.pack(orig(path, wrap(fn, rec), ...))
            M.reg.notify = M.reg.notify + 1
            return table.unpack(r, 1, r.n)
        end
    end
    -- sdcoop_bench (sdc_bench): its console command and per-frame sampling
    local okb, bench = pcall(require, "sdc_bench")
    if okb and type(bench) == "table" and type(bench.install) == "function" then
        local oki, err = pcall(bench.install, M)
        if not oki then log.warn("perf: sdcoop_bench not installed: %s", tostring(err)) end
    elseif not okb then
        log.warn("perf: sdc_bench not loaded: %s", tostring(bench))
    end
end

-- ---------------------------------------------------------------------------
-- Lua collector (Lua 5.4.7 inside UE4SS; UE4SS itself never calls lua_gc)
-- ---------------------------------------------------------------------------
-- main.lua, config lua_gc / lua_gc_pause / lua_gc_stepmul. Measured with a
-- client-shaped model (scratchpad gcwork\gcbench.lua: ~20 MB live caches,
-- ~1 MB/s of hook-parameter wrappers with finalizers, closures, strings):
--   incremental 200/100 (Lua default): worst frame 24-26 ms, heap 21-71 MB
--   incremental 150/200 (default here): worst 15-21 ms, heap 21-38 MB,
--     ~+10% collector work (each cycle starts at 1.5x the live heap and runs
--     twice as fast)
--   generational 10/100: worst 6-8 ms, heap 21-33 MB, ~-20% total time; but
--     its major collections stop the game for the whole heap at once and it
--     has not run in the game yet: opt-in (lua_gc = generational).
-- None of these comes near a second: a full stop-the-world collection of the
-- client's largest heap (88 MB) measured ~140 ms.
M.gc_mode = "incremental"
M.gc_desc = "incremental"
M.gc_pause = 200
-- collector cycles finished since start (a finalizer that re-arms itself
-- runs once per cycle); gc_base_kb = the heap when the last one finished
M.gc_cycles = 0
M.gc_base_kb = nil
local function canary()
    setmetatable({}, { __gc = function()
        M.gc_cycles = M.gc_cycles + 1
        M.gc_base_kb = collectgarbage("count")
        pcall(canary)
    end })
end
canary()

function M.set_gc_mode(mode, pause, stepmul)
    mode = tostring(mode or "")
    if mode ~= "generational" and mode ~= "incremental" then return false end
    local ok, prev
    if mode == "incremental" then
        -- 0 / nil = keep Lua's value
        pause, stepmul = math.floor(tonumber(pause) or 0), math.floor(tonumber(stepmul) or 0)
        if pause < 0 or pause > 1000 then pause = 0 end
        if stepmul < 0 or stepmul > 1000 then stepmul = 0 end
        ok, prev = pcall(collectgarbage, "incremental", pause, stepmul)
        if ok then
            M.gc_pause = pause > 0 and pause or M.gc_pause
            M.gc_desc = string.format("incremental %d/%d", M.gc_pause, stepmul > 0 and stepmul or 100)
        end
    else
        ok, prev = pcall(collectgarbage, "generational", 10, 100)
        if ok then M.gc_desc = "generational 10/100" end
    end
    if ok then
        M.gc_mode = mode
        log.info("perf: Lua collector %s (was %s)", M.gc_desc, tostring(prev))
    else
        log.warn("perf: Lua collector %s refused: %s", mode, tostring(prev))
    end
    return ok
end

-- One incremental collector step, timed (sdc_diag, once a second): only in
-- the middle of a cycle (the heap well above where the next one starts), so
-- it never starts a cycle early. [PERF] "gc step" = the worst sample.
local gc_steps = { n = 0, ms = 0, max = 0 }
function M.gc_step_sample()
    if M.gc_mode ~= "incremental" or not M.gc_base_kb then return end
    if collectgarbage("count") < M.gc_base_kb * M.gc_pause / 100 * 1.1 then return end
    local t0 = clock()
    collectgarbage("step", 0)
    local ms = (clock() - t0) * 1000
    gc_steps.n, gc_steps.ms = gc_steps.n + 1, gc_steps.ms + ms
    if ms > gc_steps.max then gc_steps.max = ms end
end

-- Every frame (main.lua's per-frame loop). sdcoop_bench sets bench_frame for
-- the length of its window only.
M.bench_frame = nil
function M.frame()
    M.frames = M.frames + 1
    local bf = M.bench_frame
    if bf then bf() end
end

local function top(list, n)
    table.sort(list, function(a, b) return a.ms > b.ms end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

-- The window since the last report: deltas of every counter. `commit` =
-- a real window ([PERF] line): the window starts again and the maxima reset.
-- Without it (sdcoop_status) the same line is built read-only: the running
-- window, its maxima and sdc_ctx's counters stay as they are.
local function build(why, tasks, commit)
    local now = os.clock()
    local dt = math.max(0.001, now - win.t0)
    local fps = (M.frames - win.frames) / dt
    local hl, total_ms = {}, 0
    for path, r in pairs(M.hooks) do
        local prev = win.hooks[path] or { calls = 0, ms = 0 }
        local dc, dm = r.calls - prev.calls, r.ms - prev.ms
        if dc > 0 then
            hl[#hl + 1] = { name = r.name, calls = dc, ms = dm }
            total_ms = total_ms + dm
        end
        if commit then win.hooks[path] = { calls = r.calls, ms = r.ms } end
    end
    local tl, task_ms = {}, 0
    for label, r in pairs(tasks or {}) do
        local prev = win.tasks[label] or { calls = 0, ms = 0 }
        local dc, dm = r.calls - prev.calls, r.ms - prev.ms
        if dc > 0 then
            tl[#tl + 1] = { name = label, calls = dc, ms = dm }
            task_ms = task_ms + dm
        end
        if commit then win.tasks[label] = { calls = r.calls, ms = r.ms } end
    end
    local hs, ts = {}, {}
    for _, e in ipairs(top(hl, 8)) do
        hs[#hs + 1] = string.format("%s %.0f/s %.1fms/s", e.name, e.calls / dt, e.ms / dt)
    end
    for _, e in ipairs(top(tl, 5)) do
        ts[#ts + 1] = string.format("%s %.1fms/s", e.name, e.ms / dt)
    end
    -- Breakdowns (already inside the totals above, not added to them):
    -- parts of the session tick (sdc_ue.sub_time), incoming mod messages by
    -- kind (sdc_net), FindAllOf by class (sdc_ue.find_all).
    local ue = package.loaded["sdc_ue"]
    local net = package.loaded["sdc_net"]
    local function window_of(key, src, n, fmt_fn)
        local list = {}
        local wk = win[key] or {}
        if commit then win[key] = wk end
        for label, r in pairs(type(src) == "table" and src or {}) do
            local prev = wk[label] or { calls = 0, ms = 0, n = 0 }
            local dc, dm = r.calls - prev.calls, r.ms - prev.ms
            if dc > 0 then
                list[#list + 1] = { name = label, calls = dc, ms = dm, n = (r.n or 0) - (prev.n or 0), max = r.wmax or 0 }
            end
            if commit then
                r.wmax = 0   -- the worst single call of the next window
                wk[label] = { calls = r.calls, ms = r.ms, n = r.n or 0 }
            end
        end
        local out = {}
        for _, e in ipairs(top(list, n)) do out[#out + 1] = fmt_fn(e) end
        return #out > 0 and table.concat(out, ", ") or "-"
    end
    local parts = window_of("parts", type(ue) == "table" and ue.sub_stats, 10, function(e)
        return string.format("%s %.1fms/s (max %.0fms)", e.name, e.ms / dt, e.max)
    end)
    local msgs = window_of("msgs", type(net) == "table" and net.handler_stats, 4, function(e)
        return string.format("%s %.1f/s %.1fms/s", e.name, e.calls / dt, e.ms / dt)
    end)
    local finds = window_of("finds", type(ue) == "table" and ue.find_stats, 4, function(e)
        return string.format("%s %.1f/s %.1fms/s (%d objs/call)", e.name, e.calls / dt, e.ms / dt,
            math.floor(e.n / math.max(1, e.calls)))
    end)
    if commit then win.t0, win.frames = now, M.frames end
    -- Lua heap: its growth is garbage the collector has to walk (hook
    -- parameters, closures); a GC step lands in whatever callback allocates
    local kb = collectgarbage("count")
    local grow = kb - (win.kb or kb)
    -- collector: cycles finished in the window, worst sampled step
    local cycles = M.gc_cycles - (win.gc_cycles or M.gc_cycles)
    local step = gc_steps.n > 0 and string.format(", step max %.0f ms", gc_steps.max) or ""
    -- UE4SS.log writes in the window (sdc_log): rate, time, the slowest one
    local lw = win.log or { n = 0, bytes = 0, ms = 0, slow = 0 }
    local wn, wb, wms = (writes.n or 0) - lw.n, (writes.bytes or 0) - lw.bytes, (writes.ms or 0) - lw.ms
    local wslow = (writes.slow or 0) - lw.slow
    local wmax = writes.max or 0
    if commit then
        win.kb, win.gc_cycles = kb, M.gc_cycles
        gc_steps.n, gc_steps.ms, gc_steps.max = 0, 0, 0
        win.log = { n = writes.n or 0, bytes = writes.bytes or 0, ms = writes.ms or 0, slow = writes.slow or 0 }
        writes.max = 0
    end
    -- sdc_net send budget: messages that waited in this window (only when any)
    local queued = ""
    local bs = type(net) == "table" and type(net.budget_stats) == "table" and net.budget_stats or nil
    if bs then
        local prev = win.budget or { queued = 0, dropped = 0 }
        local dq, dd = (bs.queued or 0) - prev.queued, (bs.dropped or 0) - prev.dropped
        if commit then win.budget = { queued = bs.queued or 0, dropped = bs.dropped or 0 } end
        if dq > 0 or dd > 0 then
            queued = string.format(" | net send queue: %d waited, %d dropped, %d waiting now", dq, dd,
                type(net.queued_count) == "function" and net.queued_count() or 0)
        end
    end
    -- sdc_ctx's player-0 hooks: where their time goes (only while they ran);
    -- its text starts a new window of its own counters, so a real window only
    local ctxs = ""
    local cx = package.loaded["sdc_ctx"]
    if commit and type(cx) == "table" and type(cx.perf_text) == "function" then
        local okc, s = pcall(cx.perf_text, dt)
        if okc and s then ctxs = " | ctx: " .. s end
    end
    -- sdc_speed: how fast the world ran here in this window (read-only without commit)
    local sp = package.loaded["sdc_speed"]
    if type(sp) == "table" and type(sp.window_text) == "function" then
        local oks, s = pcall(sp.window_text, commit)
        if oks and s then ctxs = " | " .. s .. ctxs end
    end
    if M.reg.skipped_bp > 0 then
        ctxs = ctxs .. string.format(" | BENCH MODE: %d Blueprint hooks not registered", M.reg.skipped_bp)
    end
    local line = string.format("[PERF] %s %.0fs: fps=%.0f | mod hooks %.1fms/s: %s | mod tasks %.1fms/s: %s"
        .. " | parts: %s | msgs in: %s | FindAllOf: %s | lua heap %.1f MB (%+.1f, gc %s, %d cycles%s)"
        .. " | log writes %.1f/s %.1f KB/s %.1fms/s, max %.0f ms%s%s%s%s",
        why or "window", dt, fps, total_ms / dt, #hs > 0 and table.concat(hs, ", ") or "-",
        task_ms / dt, #ts > 0 and table.concat(ts, ", ") or "-", parts, msgs, finds,
        kb / 1024, grow / 1024, M.gc_desc or M.gc_mode or "incremental", cycles, step,
        wn / dt, wb / 1024 / dt, wms / dt, wmax, wslow > 0 and string.format(", %d slow (>= %d ms)", wslow,
            log.SLOW_WRITE_MS or 100) or "", (log.batching and log.batching()) and ", batched" or "", queued, ctxs)
    return line
end

-- A [PERF] window: logged, and the next window starts now.
function M.report(why, tasks)
    local line = build(why, tasks, true)
    log.info("%s", line)
    -- every 10th window: which mod tables are big (the heap floor's suspects)
    win.reports = (win.reports or 0) + 1
    if why == "window" and win.reports % 10 == 0 then pcall(M.mem_census) end
    return line
end

-- The running window so far, read-only (sdcoop_status): not logged here, the
-- next [PERF] window still covers its whole time.
function M.peek(why, tasks)
    return build(why, tasks, false)
end

-- ---------------------------------------------------------------------------
-- [MEM]: the largest tables the mod's modules hold
-- ---------------------------------------------------------------------------
-- Read-only walk: every sdc_* module table, its fields and the upvalues of
-- every function reachable from it (the modules' local caches), each table
-- counted once by its entries (raw next, at most COUNT_CAP each). One line
-- with the biggest ones, so a growing cache shows its name in the log. A few
-- ms, every 10th [PERF] window.
-- The same line counts this mod's Lua registry: UE4SS takes a registry
-- reference (luaL_ref) to every table passed for an out parameter of a
-- UFunction call (LuaUObject.cpp, the __call of a UFunction). The build we
-- ship (4fb9b61) releases it right after the call (luaL_unref); older UE4SS
-- 3.0.1 builds did not, and every such call then kept its table (an
-- FHitResult, an actor list) for the whole session. The references held
-- (slots minus luaL_ref's free list) must stay flat; and a probe call with
-- out parameters (KismetMathLibrary.BreakVector, pure math) must leave the
-- count as it was ("released") - "KEPT" means this UE4SS keeps them.
-- (Process memory - working set, private bytes - has no API reachable from
-- Lua here: no UE4SS global and no Blueprint function returns it.)
-- The same UE4SS call never destroys its parameter block either (zeroed,
-- filled by the engine, dropped): the heap buffer of a TArray the engine
-- fills for an out parameter stays allocated for good. The line estimates
-- it for GetAllActorsOfClass through sdc_ue.actors_of (the AI passes every
-- 2-3 s, hundreds of zombies): at least 8 bytes per actor returned
-- (watch_out_arrays below, installed by main.lua). Overlap queries, widget
-- lists and returned arrays elsewhere leave theirs too and are not counted.
-- A C++ fix must NOT just destroy the block right after the call: the
-- elements of an out-array reach Lua as RemoteUnrealParams that point into
-- that very buffer (push_arrayproperty, GetNonTrivialLocal -> each element
-- GetParam at array_data + i * size), and the mod reads them later with
-- :get() (sdc_ue.elem; the AI passes). Freed, every such read would see
-- freed memory. Copy the values first (the inner property with
-- Operation::Get: objects by value) and destroy after, or keep the buffer
-- alive as long as the Lua table that refers into it.
local COUNT_CAP = 200000
local REG_FREELIST = 3     -- lauxlib (Lua 5.4.3+): registry slot of luaL_ref's free list head
local reg_prev = nil

-- slots in use by references: the array part's length minus the free list
-- (freed slots hold the next free index, so the array has no holes)
local function registry_refs()
    if type(debug) ~= "table" or type(debug.getregistry) ~= "function" then return nil end
    local reg = debug.getregistry()
    if type(reg) ~= "table" then return nil end
    local n = #reg
    local free, k = 0, reg[REG_FREELIST]
    while math.type(k) == "integer" and k > REG_FREELIST and k <= n and free <= n do
        free = free + 1
        k = reg[k]
    end
    return n, free, math.max(0, n - REG_FREELIST - free)
end

local function m_break_vector(kml, out) kml:BreakVector({ X = 1, Y = 2, Z = 3 }, out, out, out) end

-- One UFunction call with three out parameters: how many registry references
-- it left behind (0 = released), or nil when it could not run.
function M.outparam_probe()
    local ue = package.loaded["sdc_ue"]
    local kml = type(ue) == "table" and type(ue.find_object) == "function"
        and ue.find_object("/Script/Engine.Default__KismetMathLibrary") or nil
    if not kml then return nil, "no KismetMathLibrary" end
    local _, _, before = registry_refs()
    if not before then return nil, "no registry" end
    local out = {}
    local ok, err = pcall(m_break_vector, kml, out)
    local _, _, after = registry_refs()
    if not ok then return nil, tostring(err) end
    return after - before, out.X
end

local function registry_text()
    local n, free, used = registry_refs()
    if not n then return "lua registry: not readable" end
    local grow = reg_prev and string.format(", %+d since the last [MEM]", used - reg_prev) or ""
    reg_prev = used
    local kept, info = M.outparam_probe()
    local probe
    if kept == nil then
        probe = "out-param probe n/a (" .. tostring(info) .. ")"
    elseif kept == 0 then
        probe = "out-param references released"
    else
        probe = string.format("out-param references KEPT (+%d from one call: this UE4SS leaks every out-parameter table)", kept)
    end
    return string.format("lua registry %d slots, %d free, %d references held%s; %s", n, free, used, grow, probe)
end
M.registry_refs = registry_refs

-- Out-array buffers UE4SS leaves allocated (estimate, see above).
local oa = { calls = 0, elems = 0, prev_elems = nil, wrapped = false }
M.out_arrays = oa
local function count_out(out, ...)
    if type(out) == "table" then
        oa.calls = oa.calls + 1
        oa.elems = oa.elems + #out
    end
    return out, ...
end
-- main.lua, right after sdc_ue loads (before the AI modules keep their copy
-- of ue.actors_of): every call is counted, its results passed on unchanged.
function M.watch_out_arrays(ue)
    if oa.wrapped or type(ue) ~= "table" or type(ue.actors_of) ~= "function" then return false end
    local orig = ue.actors_of
    ue.actors_of = function(...) return count_out(orig(...)) end
    oa.wrapped = true
    return true
end

local function out_array_text()
    if not oa.wrapped then return "out-array buffers: not counted" end
    local kb = oa.elems * 8 / 1024
    local grow = oa.prev_elems and string.format(", %+.0f KB since the last [MEM]", (oa.elems - oa.prev_elems) * 8 / 1024) or ""
    oa.prev_elems = oa.elems
    return string.format("out-array buffers UE4SS keeps (estimate): >= %.0f KB from %d GetAllActorsOfClass calls"
        .. " (%d actors)%s", kb, oa.calls, oa.elems, grow)
end

function M.mem_census()
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return end
    local t0 = clock()
    local seen, list, ntab = {}, {}, 0
    local function count(t)
        local n, k = 0, nil
        repeat
            k = next(t, k)
            if k ~= nil then n = n + 1 end
        until k == nil or n >= COUNT_CAP
        return n
    end
    local function note(t, name)
        if seen[t] then return end
        seen[t] = true
        ntab = ntab + 1
        local n = count(t)
        if n >= 50 then list[#list + 1] = { name = name, n = n } end
    end
    -- a function's table upvalues, then the functions among its upvalues
    local function walk_fn(f, mod)
        local todo = { f }
        while #todo > 0 do
            local fn = table.remove(todo)
            if not seen[fn] then
                seen[fn] = true
                for i = 1, 255 do
                    local uname, uv = debug.getupvalue(fn, i)
                    if uname == nil then break end
                    if type(uv) == "table" then
                        note(uv, mod .. "." .. tostring(uname))
                    elseif type(uv) == "function" and not seen[uv] then
                        todo[#todo + 1] = uv
                    end
                end
            end
        end
    end
    -- module tables (the mod's and Lua's: string, table, _G = _ENV) are not caches
    for _, m in pairs(package.loaded) do
        if type(m) == "table" then seen[m] = true end
    end
    seen[_G], seen[package], seen[package.loaded] = true, true, true
    for mod, m in pairs(package.loaded) do
        if type(mod) == "string" and mod:sub(1, 4) == "sdc_" and type(m) == "table" then
            for key, v in next, m do
                if type(v) == "table" then
                    note(v, mod .. "." .. tostring(key))
                elseif type(v) == "function" then
                    walk_fn(v, mod)
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, math.min(10, #list) do out[i] = list[i].name .. " " .. list[i].n end
    local okr, reg = pcall(registry_text)
    local oko, oat = pcall(out_array_text)
    log.info("[MEM] lua heap %.1f MB; largest mod tables (entries): %s (%d tables looked at, %.0f ms) | %s | %s",
        collectgarbage("count") / 1024, #out > 0 and table.concat(out, ", ") or "-", ntab, (clock() - t0) * 1000,
        okr and reg or ("lua registry: " .. tostring(reg)), oko and oat or ("out-array buffers: " .. tostring(oat)))
end

return M
