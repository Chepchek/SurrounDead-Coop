-- SDCoop: sdcoop_bench - numbers for the "build our own UE4SS?" decision.
--
-- UE4SS 3.0.1 (LuaMod.cpp script_hook, ProcessLocalScriptFunction post
-- callback) runs after EVERY Blueprint function call in the game while any
-- mod has a Blueprint hook registered: it takes a lock, builds the called
-- function's name chain (a std::vector<FName>: heap allocations) and searches
-- the list of hooked Blueprint functions (~120-200 of ours) one by one. Only
-- our own UE4SS build could make that a hash lookup before the lock. Single
-- player only (no remote player, not a client), three ways to measure it:
--
--   sdcoop_bench [seconds]   (default 60, 10..600) - after 5 s (close the
--       console, stand still) samples every frame for the given time, then
--       logs one "[BENCH]" line: average fps, frame time p50/p95/p99/max
--       (the world's own delta time, GameplayStatics.GetWorldDeltaSeconds;
--       os.clock deltas when that is not available or time is dilated), the
--       hooks this mod registered by kind, the mod's own Lua time in its
--       hooks (Blueprint / native / new-object) and tasks in the window, the
--       Lua heap, where the player stood and looked (start / end).
--       Run it once normally and once with the debug switch
--       perf_bench_no_bp_hooks = true (sdc_perf: the mod then registers no
--       Blueprint hook at all, so UE4SS's search is skipped): same save,
--       same spot, same view.
--   sdcoop_bench floor - a micro-measure in game code: the same native
--       GameplayStatics call without a hook (GetPlayerControllerFromID), with
--       UE4SS's native hook and an empty Lua callback (GetPlayerController,
--       sdc_ctx inactive) and with sdc_ctx's fast path; plus one Blueprint
--       function call (GameFunctionLibrary.GetGameMode), whose cost differs
--       between a normal run and a perf_bench_no_bp_hooks run by exactly
--       UE4SS's per-Blueprint-call search. Registers sdc_ctx's player-0 hooks
--       for the rest of the session (inactive, as after any co-op game): run
--       the fps windows first.
--   sdcoop_bench stop - ends a window early (its line is still written).
--
-- Cost while no window runs: one nil check per frame (sdc_perf.frame).
-- During a window: one GetWorldDeltaSeconds call per frame (its own time is
-- in the line: "bench sampling").

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = { running = nil, waiting = false, stats = { runs = 0, floors = 0 } }
local perf = nil          -- sdc_perf (install)
local clock = os.clock

local START_DELAY_MS = 5000
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"

local function m_delta(gps, wc) return gps:GetWorldDeltaSeconds(wc) end
local function m_dilation(gps, wc) return gps:GetGlobalTimeDilation(wc) end
local function m_from_id(gps, wc) return gps:GetPlayerControllerFromID(wc, 0) end
local function m_num_pcs(gps, wc) return gps:GetNumPlayerControllers(wc) end
local function m_gpc(gps, wc) return gps:GetPlayerController(wc, 0) end
local function m_bp_call(cdo, wc, out) return cdo:GetGameMode(wc, out) end

local function session_state()
    local s = package.loaded["sdc_session"]
    return type(s) == "table" and type(s.state) == "table" and s.state or nil
end

-- single player: not a client, nobody connected
local function single_player()
    local S = session_state()
    if S and S.role == "client" then return false, "this game is connected to a host" end
    for _ in pairs(S and S.remote or {}) do return false, "other players are connected" end
    return true
end

local function where()
    local pawn = ue.local_pawn()
    if not pawn then return nil end
    local l = ue.location(pawn)
    if not l then return nil end
    local r = ue.rotation(pawn)
    return { X = l.X, Y = l.Y, Z = l.Z, yaw = r and r.Yaw or 0 }
end

local function where_text(p)
    if not p then return "?" end
    return string.format("%.0f,%.0f,%.0f yaw %.0f", p.X, p.Y, p.Z, p.yaw)
end

local function dilation()
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then return nil end
    local ok, v = pcall(m_dilation, gps, wc)
    if ok and type(v) == "number" then return v end
    return nil
end

-- [path] = { calls, ms } of every hook record now
local function hook_snapshot()
    local t = {}
    for path, r in pairs(perf and perf.hooks or {}) do t[path] = { calls = r.calls, ms = r.ms } end
    return t
end

local function task_snapshot()
    local t = {}
    for label, r in pairs(ue.task_stats or {}) do t[label] = { calls = r.calls, ms = r.ms } end
    return t
end

local function hook_kind_of(path, rec)
    if rec.kind then return rec.kind end
    path = tostring(path)
    if path:sub(1, 4) == "new " then return "notify" end
    if path:find("#", 1, true) then return "native" end   -- sdc_ue.hook_native subscriber
    return perf and perf.hook_kind and perf.hook_kind(path) or "?"
end

local function pct(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    local i = math.ceil(p * n)
    if i < 1 then i = 1 elseif i > n then i = n end
    return sorted[i]
end

local function say(reply, fmt, ...)
    local s = string.format(fmt, ...)
    if reply then reply(s) else log.info("%s", s) end
end

-- ---------------------------------------------------------------------------
-- The fps / frame-time window
-- ---------------------------------------------------------------------------
local function finish(why)
    local r = M.running
    if not r then return end
    M.running = nil
    if perf then perf.bench_frame = nil end
    local elapsed = math.max(0.001, clock() - r.t0)
    local fps = r.frames / elapsed
    local dts = r.dt
    table.sort(dts)
    -- the mod's Lua time in its hooks during the window, by hook kind
    local by = { bp = { calls = 0, ms = 0 }, native = { calls = 0, ms = 0 }, notify = { calls = 0, ms = 0 } }
    for path, rec in pairs(perf and perf.hooks or {}) do
        local p0 = r.h0[path] or { calls = 0, ms = 0 }
        local k = hook_kind_of(path, rec)
        local b = by[k] or by.native
        b.calls = b.calls + (rec.calls - p0.calls)
        b.ms = b.ms + (rec.ms - p0.ms)
    end
    local task_ms = 0
    for label, rec in pairs(ue.task_stats or {}) do
        local p0 = r.t0s[label] or { calls = 0, ms = 0 }
        task_ms = task_ms + (rec.ms - p0.ms)
    end
    local reg = perf and perf.reg or {}
    local p1 = where()
    local moved = r.where0 and p1 and (math.abs(p1.X - r.where0.X) + math.abs(p1.Y - r.where0.Y) > 50
        or math.abs(p1.yaw - r.where0.yaw) > 5)
    local dil1 = dilation()
    local src = r.nworld == #dts and #dts > 0 and "world delta" or
        (r.nworld > 0 and string.format("world delta %d + os.clock %d", r.nworld, #dts - r.nworld) or "os.clock, 1 ms steps")
    local gc = perf and (tonumber(perf.gc_cycles) or 0) - r.gc0 or 0
    local line = string.format("[BENCH] %s %.1fs, Blueprint hooks %s: fps %.1f (%d frames) | frame ms p50 %.2f p95 %.2f"
        .. " p99 %.2f max %.1f (%s, %d samples) | hooks registered by SDCoop: Blueprint %d (not registered: %d),"
        .. " native %d, new-object watches %d | mod Lua in hooks %.2f ms/s (Blueprint %.2f in %.0f calls/s,"
        .. " native %.2f in %.0f calls/s, new-object %.2f) | mod tasks %.2f ms/s (bench sampling %.2f ms/s)"
        .. " | lua heap %.1f MB, %d gc cycles | time dilation %s / %s | frame loop %s | player %s -> %s%s",
        why or "window", elapsed, (reg.skipped_bp or 0) > 0 and "OFF (perf_bench_no_bp_hooks)" or "on",
        fps, r.frames, pct(dts, 0.50), pct(dts, 0.95), pct(dts, 0.99), dts[#dts] or 0, src, #dts,
        reg.bp or 0, reg.skipped_bp or 0, reg.native or 0, reg.notify or 0,
        (by.bp.ms + by.native.ms + by.notify.ms) / elapsed, by.bp.ms / elapsed, by.bp.calls / elapsed,
        by.native.ms / elapsed, by.native.calls / elapsed, by.notify.ms / elapsed,
        task_ms / elapsed, r.sample_ms / elapsed, collectgarbage("count") / 1024, gc,
        r.dil0 and string.format("%.2f", r.dil0) or "?", dil1 and string.format("%.2f", dil1) or "?",
        EngineTickAvailable and "every engine tick" or "16 ms timer (not frame-locked)",
        where_text(r.where0), where_text(p1), moved and " (MOVED: this run is not comparable)" or "")
    log.info("%s", line)
    M.last = line
    M.stats.runs = M.stats.runs + 1
    pcall(log.toast, string.format("Замер окончен: FPS %.1f, кадр p50 %.1f / p95 %.1f / p99 %.1f мс%s. Строка [BENCH] в UE4SS.log.",
        fps, pct(dts, 0.50), pct(dts, 0.95), pct(dts, 0.99), moved and " (игрок сдвинулся - замер не сравнивать)" or ""),
        "info", 10, "bench done: " .. line:sub(1, 80))
end

-- one frame (sdc_perf.frame -> bench_frame)
local function sample()
    local r = M.running
    if not r then return end
    local t = clock()
    r.frames = r.frames + 1
    local d = nil
    if r.use_world then
        local gps, wc = ue.gameplay_statics(), ue.world_context()
        if gps and wc then
            local ok, v = pcall(m_delta, gps, wc)
            if ok and type(v) == "number" and v > 0 then d = v * 1000 end
        end
    end
    local cd = (t - r.last) * 1000
    r.last = t
    if r.frames > 1 then   -- the first frame has no previous one
        local n = #r.dt + 1
        r.dt[n] = d or cd
        if d then r.nworld = r.nworld + 1 end
    end
    local t1 = clock()
    r.sample_ms = r.sample_ms + (t1 - t) * 1000
    if t1 >= r.t_end then finish("window") end
end

local function start(seconds)
    local dil = dilation()
    local r = {
        t0 = clock(), frames = 0, dt = {}, nworld = 0, sample_ms = 0,
        h0 = hook_snapshot(), t0s = task_snapshot(), gc0 = perf and tonumber(perf.gc_cycles) or 0,
        where0 = where(), dil0 = dil,
        -- the world's delta is scaled by time dilation: os.clock then
        use_world = dil == nil or math.abs(dil - 1) < 0.001,
    }
    r.last = r.t0
    r.t_end = r.t0 + seconds
    M.running = r
    if perf then perf.bench_frame = sample end
    log.info("[BENCH] window started: %d s, Blueprint hooks %s, player at %s, time dilation %s, paused=%s", seconds,
        (perf and perf.reg and (perf.reg.skipped_bp or 0) > 0) and "OFF" or "on", where_text(r.where0),
        dil and string.format("%.2f", dil) or "?", tostring(ue.is_paused()))
end

-- ---------------------------------------------------------------------------
-- The floor: per-call costs measured in game code
-- ---------------------------------------------------------------------------
local FLOOR_N, FLOOR_ROUNDS = 500, 8

local function timed(n, fn, a, b, c)
    local t0 = clock()
    for _ = 1, n do pcall(fn, a, b, c) end
    return (clock() - t0) * 1000
end

local function floor_run(reply)
    local ok, why = single_player()
    if not ok then say(reply, "sdcoop_bench floor: single player only (%s)", why) return end
    local gps, wc = ue.gameplay_statics(), ue.local_pc()
    if not gps or not wc then say(reply, "sdcoop_bench floor: load a world first (no local player controller)") return end
    local ctx = require("sdc_ctx")
    local nh = ctx.install_hooks and ctx.install_hooks() or 0
    -- the unhooked baseline: same parameters (object, int) and result (a controller)
    local base_fn, base_name = m_from_id, "GetPlayerControllerFromID"
    if not pcall(m_from_id, gps, wc) then base_fn, base_name = m_num_pcs, "GetNumPlayerControllers" end
    local cdo = ue.find_object(GFL_CDO)
    local out = {}
    local bp_ok = cdo ~= nil and pcall(m_bp_call, cdo, wc, out)
    local acc = { A = 0, B = 0, C = 0, E = 0 }
    local round = 0
    say(reply, "sdcoop_bench floor: %d rounds of %d calls each, about 1 s (short stalls are expected)", FLOOR_ROUNDS, FLOOR_N)
    local function step()
        if not M.floor_running then return end
        round = round + 1
        local was = ctx.active
        local okr, err = pcall(function()
            local g, w = ue.gameplay_statics(), ue.local_pc()
            if not g or not w then error("the world went away") end
            acc.A = acc.A + timed(FLOOR_N, base_fn, g, w)
            ctx.active = false
            acc.B = acc.B + timed(FLOOR_N, m_gpc, g, w)
            ctx.active = true
            acc.C = acc.C + timed(FLOOR_N, m_gpc, g, w)
            ctx.active = was
            if bp_ok then
                local c = ue.find_object(GFL_CDO)
                if c then acc.E = acc.E + timed(FLOOR_N, m_bp_call, c, w, out) end
            end
        end)
        ctx.active = was
        if not okr then
            M.floor_running = false
            log.warn("[BENCH] floor stopped: %s", tostring(err))
            return
        end
        if round < FLOOR_ROUNDS then
            ue.delay("bench-floor", 100, step)
            return
        end
        M.floor_running = false
        M.stats.floors = M.stats.floors + 1
        local n = FLOOR_N * FLOOR_ROUNDS
        local A, B, C, E = acc.A * 1000 / n, acc.B * 1000 / n, acc.C * 1000 / n, acc.E * 1000 / n
        local reg = perf and perf.reg or {}
        local line = string.format("[BENCH] floor (%d calls each, us per call, os.clock sums): GameplayStatics.%s"
            .. " without a hook %.2f | GetPlayerController with UE4SS's native hook and a near-empty Lua callback"
            .. " (sdc_ctx inactive; sdc_perf's timing wrapper included) %.2f -> native hook floor %.2f us/call"
            .. " | with sdc_ctx's fast path (no remote"
            .. " player) %.2f -> our Lua %.2f us/call | a Blueprint function call (GameFunctionLibrary.GetGameMode)"
            .. " %s us/call, Blueprint hooks %s (%d registered by SDCoop, %d not registered): compare this number"
            .. " between a normal run and a perf_bench_no_bp_hooks run - the difference is UE4SS's search after"
            .. " every Blueprint call | sdc_ctx hooks registered: %d",
            n, base_name, A, B, B - A, C, C - B, bp_ok and string.format("%.2f", E) or "n/a",
            (reg.skipped_bp or 0) > 0 and "OFF" or "on", reg.bp or 0, reg.skipped_bp or 0, nh)
        log.info("%s", line)
        M.last_floor = line
        pcall(log.toast, string.format("Замер затрат: перехват %.1f мкс, наш Lua %.1f мкс, вызов Blueprint %s мкс."
            .. " Строка [BENCH] floor в UE4SS.log.", B - A, C - B, bp_ok and string.format("%.1f", E) or "-"),
            "info", 10, "bench floor done")
    end
    M.floor_running = true
    ue.delay("bench-floor", 100, step)
end

-- ---------------------------------------------------------------------------
-- Console command
-- ---------------------------------------------------------------------------
local function command(params, reply)
    local a = params[1] ~= nil and ue.str(params[1]) or nil
    a = a and a:lower() or nil
    if a == "stop" then
        if M.running then finish("stopped") reply("bench window stopped; [BENCH] line written") else reply("no bench window running") end
        return
    end
    if a == "floor" then
        if M.running or M.waiting or M.floor_running then reply("a bench is running already") return end
        floor_run(reply)
        return
    end
    if M.running or M.waiting or M.floor_running then reply("a bench is running already (sdcoop_bench stop)") return end
    local ok, why = single_player()
    if not ok then reply("sdcoop_bench: single player only (" .. why .. ")") return end
    if not perf then reply("sdcoop_bench: sdc_perf is not loaded") return end
    local secs = math.floor(tonumber(a or "") or 60)
    if secs < 10 then secs = 10 elseif secs > 600 then secs = 600 end
    M.waiting = true
    reply(string.format("bench: starts in %d s and runs %d s, Blueprint hooks %s. Close the console now and stand still"
        .. " (same spot, same view, no menus).", START_DELAY_MS // 1000, secs,
        (perf.reg and (perf.reg.skipped_bp or 0) > 0) and "OFF (perf_bench_no_bp_hooks)" or "on"))
    ue.delay("bench-start", START_DELAY_MS, function()
        M.waiting = false
        local ok2, why2 = single_player()
        if not ok2 then log.warn("[BENCH] not started: %s", why2) return end
        start(secs)
    end)
end

-- sdc_perf.wrap_register_hook (main.lua, first thing at load).
function M.install(p)
    if M.installed then return end
    M.installed = true
    perf = p
    if type(RegisterConsoleCommandHandler) ~= "function" then return end
    local ok, err = pcall(RegisterConsoleCommandHandler, "sdcoop_bench", function(full, params, out)
        local function reply(s)
            if out and out.Log then pcall(function() out:Log("[SDCoop] " .. s .. "\n") end) end
            log.info("%s", s)
        end
        local okc, errc = pcall(command, params or {}, reply, full)
        if not okc then reply("error: " .. tostring(errc)) end
        return true
    end)
    if not ok then log.err("console command sdcoop_bench: %s", tostring(err)) end
end

function M.status_line()
    return string.format("bench: windows=%d floors=%d running=%s%s", M.stats.runs, M.stats.floors,
        tostring(M.running ~= nil), M.last and (" | last: " .. M.last:sub(1, 160)) or "")
end

return M
