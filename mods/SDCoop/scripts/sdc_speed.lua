-- SDCoop debug: how fast the world runs on this machine, and how late the
-- mod's 1 s timers come.
--
-- main.lua's 1 s "perf" task calls M.sample() once a second. A sample reads
-- the world's game time (GameplayStatics.GetTimeSeconds: dilated, stops
-- while the game is paused), its real time (GetRealTimeSeconds: the engine's
-- own undilated count), the global time dilation and the pause, next to this
-- machine's clock (os.clock). Between two samples of the same world:
--   speed  = d(game time) / d(clock): 1.00 = the world runs at normal speed
--            here; a time dilation (sleep, slow motion) or hitches make it
--            lower. Paused seconds are counted apart.
--   lost   = the world's time lost to hitches, in real seconds. The engine's
--            real time adds every frame in full (GameEngine MaxDeltaTime = 0
--            in BaseEngine.ini, unbound: it keeps pace with this PC's clock
--            and shows no hitch by itself); its game time adds at most
--            MaxUndilatedFrameTime (0.4 s, BaseGame.ini, not changed by the
--            game) x the dilation per frame. So lost = d(real) - d(game) /
--            dilation = the part of every frame over 0.4 s. The lower of the
--            two samples' dilations is used: a dilation change inside the
--            second never shows as a hitch (a hitch then shows less). A pause
--            shorter than a second between two samples shows here too.
--   timer  = d(clock): how far apart the 1 s timer really ran. UE4SS starts
--            the next wait at the end of the frame that ran it, so the frame
--            and the other tasks run in it add to every period.
-- A machine whose world runs slower than the others' drifts away from them
-- (zombies, day time, the game's own timers). Shown by sdcoop_status
-- (status_line), the [PERF] line (sdc_perf, window_text) and the gap
-- tracer's CSV (sdc_gaptrace: rows "clock", one count per second).
-- Cost: 4 engine calls a second; of the world only its controller's address
-- is kept (to notice a new world).

local ue = require("sdc_ue")

local M = { seq = 0, recent = {}, last = nil }

local PERIOD_S = 1      -- the nominal period of the task that samples
local RECENT = 60       -- per-second records kept (sdc_gaptrace reads the new ones)
local STATUS_S = 10     -- status_line: the last 10 records
local SLOW = 0.95       -- a second slower than this counts as slow
local MAX_GAP_S = 5     -- samples further apart (loading, a long freeze): a new start
local LOST_MIN = 0.01   -- lost below this is 0 (rounding; frames under MinUndilatedFrameTime run long)

local prev = nil        -- the last sample: { clock, game, real, dil, paused, world }
local win = nil         -- the [PERF] window (window_text)
local total = { secs = 0, slow = 0, paused = 0, restarts = 0, lost = 0 }
M.total = total

local function new_window()
    return { n = 0, clock = 0, game = 0, lost = 0, min = nil, slow = 0, paused = 0, periods = 0, period_n = 0,
             period_max = 0, dil = nil }
end
win = new_window()

local function m_time(gps, wc) return gps:GetTimeSeconds(wc) end
local function m_real(gps, wc) return gps:GetRealTimeSeconds(wc) end
local function m_dil(gps, wc) return gps:GetGlobalTimeDilation(wc) end
local function m_paused(gps, wc) return gps:IsGamePaused(wc) end
local function m_addr(o) return o:GetAddress() end

local function num(ok, v)
    if ok and type(v) == "number" then return v end
    return nil
end

-- One sample, or nil (no world or statics yet, the time not readable).
local function read(now)
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then return nil end
    local game = num(pcall(m_time, gps, wc))
    local real = num(pcall(m_real, gps, wc))
    if not game or not real then return nil end
    local okp, p = pcall(m_paused, gps, wc)
    return { clock = now, game = game, real = real, dil = num(pcall(m_dil, gps, wc)) or 1,
             paused = okp and p == true, world = num(pcall(m_addr, wc)) }
end

local function keep(rec)
    local r = M.recent
    r[#r + 1] = rec
    if #r > RECENT then table.remove(r, 1) end
end

-- Once a second (main.lua). `now` = os.clock() (tests pass their own).
-- Returns the record of the second just measured, or nil (first sample, a
-- new world, a gap).
function M.sample(now)
    now = now or os.clock()
    local s = read(now)
    local p = prev
    prev = s
    if not s or not p or p.world ~= s.world then return nil end
    local dc, dg, dr = s.clock - p.clock, s.game - p.game, s.real - p.real
    -- a new world (its clock starts at 0), a load or freeze between the samples
    if dc <= 0 or dc > MAX_GAP_S or dg < 0 or dr < 0 then
        total.restarts = total.restarts + 1
        return nil
    end
    M.seq = M.seq + 1
    local rec = { seq = M.seq, dt = dc, dil = s.dil, paused = s.paused or p.paused }
    local w = win
    w.periods, w.period_n = w.periods + dc, w.period_n + 1
    if dc > w.period_max then w.period_max = dc end
    w.dil = s.dil
    if rec.paused then
        w.paused = w.paused + dc
        total.paused = total.paused + dc
    else
        local d = math.min(p.dil, s.dil)
        local lost = d > 0 and dr - dg / d or 0
        rec.speed, rec.lost = dg / dc, lost >= LOST_MIN and lost or 0
        w.n, w.clock, w.game, w.lost = w.n + 1, w.clock + dc, w.game + dg, w.lost + rec.lost
        if not w.min or rec.speed < w.min then w.min = rec.speed end
        total.secs, total.lost = total.secs + dc, total.lost + rec.lost
        if rec.speed < SLOW then
            w.slow = w.slow + dc
            total.slow = total.slow + dc
        end
    end
    keep(rec)
    M.last = rec
    return rec
end

-- A new world / role: the next sample starts over (sdc_session's world reset
-- needs no call: a new world's controller has another address).
function M.reset()
    prev = nil
end

local function period_text(sum, n, max)
    if n <= 0 then return "?" end
    return string.format("%.3f s (max %.3f s)", sum / n, max)
end

-- [PERF] (sdc_perf): the window since the last committed one, or nil when
-- nothing was measured. `commit` starts a new window.
function M.window_text(commit)
    local w = win
    if commit then win = new_window() end
    if w.n == 0 and w.paused == 0 then return nil end
    -- a window paused throughout has no running second: "-", not x0.00
    local run = w.n > 0 and w.clock > 0
    return string.format("game speed %s (slowest second %s, %.0f s below x%.2f, dilation %.2f, lost to hitches %s,"
        .. " paused %.0f s), 1 s timer every %s", run and string.format("x%.2f", w.game / w.clock) or "-",
        run and w.min and string.format("x%.2f", w.min) or "-", w.slow, SLOW, w.dil or 1,
        run and string.format("%.1f s", w.lost) or "-", w.paused, period_text(w.periods, w.period_n, w.period_max))
end

-- sdcoop_status: the last STATUS_S seconds and the whole session.
function M.status_line()
    local r = M.recent
    if #r == 0 then return "speed: not measured yet (no world)" end
    local clock, game, lost, paused, periods, pmax, n = 0, 0, 0, 0, 0, 0, 0
    local last = r[#r]
    for i = math.max(1, #r - STATUS_S + 1), #r do
        local x = r[i]
        n = n + 1
        periods = periods + x.dt
        if x.dt > pmax then pmax = x.dt end
        if x.paused then
            paused = paused + x.dt
        else
            clock, game, lost = clock + x.dt, game + x.speed * x.dt, lost + (x.lost or 0)
        end
    end
    return string.format("speed: game x%s over the last %d s (dilation %.2f, lost to hitches %s, paused %.0f s),"
        .. " 1 s timer every %s | session: %.0f s measured, %.0f s below x%.2f, %.1f s lost to hitches, %.0f s paused,"
        .. " %d restarts", clock > 0 and string.format("%.2f", game / clock) or "-", n, last.dil or 1,
        clock > 0 and string.format("%.1f s", lost) or "-", paused, period_text(periods, n, pmax),
        total.secs, total.slow, SLOW, total.lost, total.paused, total.restarts)
end

M.PERIOD_S = PERIOD_S
M.SLOW = SLOW

return M
