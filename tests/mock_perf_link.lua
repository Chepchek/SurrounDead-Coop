-- Mock test for the 13.11 log review (SDCoop 0.8.1 session), group "perf_link":
--   item 2  sdc_ai client tick: every step timed as c:ai.<feature> (and
--           sdc_ue.part while it runs), in a line of its own after [PERF]
--           ("[PERF] ai steps", not the top 10 "parts"); at most 5 ms of
--           it per frame, the rest a few frames later (task ai-client-rest)
--           or by the next tick when that call never came (a stale delayed
--           call ends no newer tick; a waiting rest that uses the budget again
--           keeps its place); a slow tick is logged with each step's time; a
--           world reset drops a waiting rest; [HITCH] names the slowest step
--           in the task that stood still ("AI step c:ai.looks N ms")
--   item 20 sdc_diag: a client's "[SNAP] own" health is its HUD's (the value
--           the host sends), not its own MedicalComponent's 100/100 (that
--           component does not replicate); the host's lines stay as they were
-- (items 9 and 18 are in sdc_steamlink: tests/mock_steamlink.lua, M and N)
-- Real sdc_ai / sdc_ue / sdc_diag, fake feature modules and objects.
-- usage: lua mock_perf_link.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 1000.0
os.clock = function() return T end
local TT = 1700000000
os.time = function() return TT end

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local LOG = {}
print = function(s) LOG[#LOG + 1] = tostring(s) end
local function logged(p, from)
    for i = (from or 0) + 1, #LOG do if LOG[i]:find(p, 1, true) then return LOG[i] end end
    return nil
end
FName = function(s) return { ToString = function() return s end } end
RegisterHook = function() return 1, 2 end
FindAllOf = function() return {} end
StaticFindObject = function() return nil end
FindFirstOf = function() return nil end
ExecuteInGameThread = function(fn) fn() end
local timers = {}
ExecuteInGameThreadWithDelay = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn }; return #timers end
local function run_timers()
    local n = 0
    while #timers > 0 do
        local t = timers
        timers = {}
        for _, x in ipairs(t) do x.fn(); n = n + 1 end
    end
    return n
end

local CFG = { diag_snapshots = 30 }
package.loaded["sdc_config"] = { get = function(k) return CFG[k] end }
package.loaded["sdc_ctx"] = setmetatable({}, { __index = function() return function() end end })
local ue = require("sdc_ue")

-- ---------------------------------------------------------------- fake AI features
-- Each feature's client_tick costs COST[id] seconds of (fake) clock and
-- notes its call and the part sdc_ue says is running.
local COST = {}
local calls, parts_seen = {}, {}
local function fake(module, id, ticks)
    local m = { init = function() end }
    if ticks then
        m.client_tick = function()
            calls[#calls + 1] = id
            parts_seen[id] = ue.part
            T = T + (COST[id] or 0)
        end
    end
    package.loaded[module] = m
end
for _, id in ipairs({ "kills", "offscreen", "killlog", "fx", "chase", "spawnnear", "scale", "optguard", "farmove", "cap",
                      "tough" }) do
    fake("sdc_ai_" .. id, id, false)
end
fake("sdc_horde", "horde", false)
for _, id in ipairs({ "attacks", "corpses", "hud", "looks", "ghosts" }) do fake("sdc_ai_" .. id, id, true) end

local ai = require("sdc_ai")
local S = { role = "client", remote_pcs = {} }
ai.init(S)
local CT = ai._CT
local cs = ai.client_tick_stats
local function order() return table.concat(calls, ",") end
local function reset_calls() calls = {} end

-- ============================================================== item 2
io.write("== item 2: the client AI tick, timed and budgeted\n")
ai.client_tick()
check(order() == "attacks,corpses,hud,looks,ghosts", "a cheap tick runs every feature in one go: " .. order())
check(#timers == 0 and CT.round == nil, "nothing carried")
check(parts_seen.looks == "c:ai.looks" and parts_seen.ghosts == "c:ai.ghosts" and ue.part == nil,
    "each feature runs as part c:ai.<feature> ([SLOWLOG] / [HITCH] name it), restored after")
local ss = ue.sub_stats
local W = CT.win.steps
check(W.looks and W.looks.calls == 1 and W.corpses and W.sweep and W.hooks,
    "every step timed for the window: hooks, each feature, sweep")
local n_parts = 0
for label in pairs(ss) do if label:sub(1, 5) == "c:ai." then n_parts = n_parts + 1 end end
check(n_parts == 0, "... not in [PERF] \"parts\" (its top 10 would lose c:damage, f:ui ... to them; skeptic)")
local l_ps = #LOG
local ps = ai.perf_report()
check(ps ~= nil and (logged("[PERF] ai steps", l_ps) or ""):find(ps, 1, true) and ps:find("c:ai.hooks", 1, true) and ps:find("c:ai.attacks", 1, true)
    and ps:find("c:ai.ghosts", 1, true) and ps:find("c:ai.sweep", 1, true) and ps:find("| 1 ticks, 0 carried", 1, true),
    "a line of their own after [PERF]: " .. tostring(ps))
check(next(CT.win.steps) == nil and ai.perf_report() == nil, "a new window: nothing ran in it, nothing logged")

-- over the budget: the rest a few frames later
COST = { attacks = 0.001, corpses = 0.002, hud = 0, looks = 0.004, ghosts = 0.003 }
reset_calls()
T = T + 1
ai.client_tick()
check(order() == "attacks,corpses,hud,looks", "5 ms used after looks: the rest waits (" .. order() .. ")")
check(#timers == 1 and timers[1].ms == 30, "the rest is scheduled 30 ms later (one delayed call)")
local lk = CT.win.steps.looks or { max = -1 }
check(lk.max >= 3.9 and lk.max <= 4.1, "the window keeps c:ai.looks' worst call (4 ms)")
check(run_timers() == 1 and order() == "attacks,corpses,hud,looks,ghosts" and CT.round == nil,
    "the delayed call runs ghosts and the sweep: every step once this second")
check(cs.carried == 1 and cs.rests == 1, "counted: 1 carried, 1 rest run")
ps = ai.perf_report() or ""
check(ps:find("[PERF] ai steps 1s: c:ai.looks 4.0ms/s (max 4ms), c:ai.ghosts 3.0ms/s (max 3ms)", 1, true)
    and ps:find("| 1 ticks, 1 carried to a later frame, 0 run by the next tick", 1, true),
    "[PERF] ai steps: worst call first, ms/s, and the carried rest: " .. ps)

-- the delayed call never came: the next tick runs that rest first
reset_calls()
T = T + 1
ai.client_tick()
check(order() == "attacks,corpses,hud,looks", "carried again")
local stale = timers
timers = {}
reset_calls()
T = T + 1
local sweeps0 = cs.steps.sweep.calls
ai.client_tick()
check(order():sub(1, 15) == "ghosts,attacks," and cs.late == 1,
    "the next tick runs the waiting rest first, then its own steps (" .. order() .. ")")
check(order() == "ghosts,attacks,corpses" and CT.round ~= nil and #timers == 1,
    "... and this tick's own rest is carried in turn")
for _, x in ipairs(stale) do x.fn() end
check(order():find("ghosts", 8, true) == nil, "the late delayed call, when it comes after all, runs nothing twice")
check(CT.round ~= nil, "... nor ends the tick now under way (skeptic: a mutation without that guard survived)")
run_timers()
check(CT.round == nil, "the round ends")
check(order() == "ghosts,attacks,corpses,hud,looks,ghosts" and cs.steps.sweep.calls == sweeps0 + 2,
    "the current tick still runs all its steps down to the sweep (" .. order() .. ")")

-- the waiting rest itself uses up the budget: it is carried again and this
-- tick starts nothing new (else the new tick would take the place of the
-- waiting one and its steps would be lost; skeptic: a mutation survived)
COST = { attacks = 0.001, corpses = 0.005, hud = 0, looks = 0.006, ghosts = 0.003 }
reset_calls()
T = T + 1
ai.client_tick()
check(order() == "attacks,corpses" and #timers == 1, "carried after corpses")
timers = {}   -- that delayed call is lost
reset_calls()
T = T + 1
local ticks0, late0b, sweeps1 = cs.ticks, cs.late, cs.steps.sweep.calls
ai.client_tick()
check(order() == "hud,looks" and cs.ticks == ticks0 and cs.late == late0b + 1 and #timers == 1,
    "the next tick: the waiting rest (hud, looks) uses the budget, carried again, no new tick (" .. order() .. ")")
run_timers()
check(order() == "hud,looks,ghosts" and cs.steps.sweep.calls == sweeps1 + 1 and CT.round == nil,
    "its delayed call finishes it: ghosts and the sweep (" .. order() .. ")")
COST = { attacks = 0.001, corpses = 0.002, hud = 0, looks = 0.004, ghosts = 0.003 }

-- a slow tick: one line with each step's time, at most once a minute
COST = { attacks = 0.001, corpses = 0.002, hud = 0, looks = 0.060, ghosts = 0.003 }
local l0 = #LOG
T = T + 61
ai.client_tick()
run_timers()
local line = logged("ai: client tick took", l0)
check(line ~= nil and line:find("looks 60", 1, true) and line:find("ghosts 3", 1, true)
    and line:find("ran in later frames", 1, true), "a 66 ms tick logged with every step's time: " .. tostring(line))
local l1 = #LOG
T = T + 1
ai.client_tick()
run_timers()
check(logged("ai: client tick took", l1) == nil and cs.slow == 2, "the next slow tick within a minute: counted, not logged")
local st_lines = table.concat(ai.status_lines(), "\n")
check(st_lines:find("ai client tick:", 1, true) and st_lines:find("looks max 60", 1, true),
    "sdcoop_status: the client tick's slowest steps (looks max 60)")

-- a world reset drops a rest still waiting
COST = { attacks = 0.001, corpses = 0.002, hud = 0, looks = 0.004, ghosts = 0.003 }
reset_calls()
T = T + 1
ai.client_tick()
check(#timers == 1, "carried")
ai.reset("world change")
run_timers()
check(order() == "attacks,corpses,hud,looks" and CT.round == nil, "after a reset the old rest does nothing")
reset_calls()
T = T + 1
local late0 = cs.late
ai.client_tick()
check(order():sub(1, 8) == "attacks," and cs.late == late0, "the next tick starts from the first step")
run_timers()

-- no delayed call possible: everything at once, as before
local real_delay = ue.delay
ue.delay = function() error("no timers") end
reset_calls()
T = T + 1
ai.client_tick()
ue.delay = real_delay
check(order() == "attacks,corpses,hud,looks,ghosts" and #timers == 0 and CT.round == nil,
    "no delayed call possible: the whole tick runs at once")

-- a feature turned off before its carried step runs is skipped
reset_calls()
T = T + 1
ai.client_tick()
check(#timers == 1, "carried")
-- the setting goes off; the features are refreshed by any AI tick (here the
-- host tick, which leaves the client's waiting rest alone)
package.loaded["sdc_config"].get = function(k) if k == "ai_client_ghosts" then return false end return CFG[k] end
S.role = "host"
ai.host_tick({})
S.role = "client"
run_timers()
check(order() == "attacks,corpses,hud,looks", "ghosts switched off meanwhile: its carried step is skipped (" .. order() .. ")")
package.loaded["sdc_config"].get = function(k) return CFG[k] end

-- host role: no client tick work
S.role = "host"
reset_calls()
T = T + 1
ai.client_tick()
check(#calls == 0 and CT.round == nil, "host: the client tick does nothing")
S.role = "client"

-- ============================================================== item 20
io.write("== item 20: [SNAP] health on a client\n")
local Obj = {}
Obj.__index = Obj
local function obj(name, props, methods)
    local o = setmetatable({ _name = name, _p = props or {}, _valid = true }, Obj)
    for k, v in pairs(methods or {}) do o[k] = v end
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return "BP_PlayerCharacter_C /Game/Levels/PL.PL:PersistentLevel." .. self._name end
function Obj:GetFName() return FName(self._name) end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:K2_GetActorLocation() return { X = 1, Y = 2, Z = 3 } end
local med = obj("Medical", { Health = 100, MaxHealth = 100 })   -- the client's copy: never replicated
local bar = obj("HealthBar", { CurrentPercent = 0.8 })            -- the host sent 80 to the HUD
local hud = obj("InGameUI", { HealthBar = bar }, { IsInViewport = function() return true end })
local pawn = obj("BP_PlayerCharacter_C_2147400001", { MedicalComponent = med, InGameUI = hud, ["PlayerDead?"] = false })
local pc = obj("PC", { Pawn = pawn })
ue.local_pc = function() return pc end
local diag = require("sdc_diag")
diag.init("test")
local l2 = #LOG
diag.tick({ role = "client", remote = {}, in_menu = false, map = "PL" })
local own = logged("[SNAP] own ", l2)
check(own ~= nil and own:find("hp=80(hud)", 1, true) ~= nil and not own:find("hp=100/100", 1, true),
    "client: [SNAP] own health from the HUD (the host's 80), not the copy's 100/100: " .. tostring(own and own:match("hp=%S+")))
check(diag._hp_text(pawn, false) == "hp=100/100", "the copy's own component still says 100/100 (why the HUD is read)")
bar._p.CurrentPercent = nil
check(diag._hp_text(pawn, true) == "hp=?(client)", "client without a HUD value: hp=?(client)")
pawn._p.InGameUI = nil
check(diag._hp_text(pawn, true) == "hp=?(client)", "client without a HUD: hp=?(client)")
-- the host: its own values (authoritative), as before
med._p.Health = 80
TT = TT + 31
local l3 = #LOG
diag.tick({ role = "host", remote = {}, in_menu = false, map = "PL" })
own = logged("[SNAP] own ", l3)
check(own ~= nil and own:find("hp=80/100", 1, true) ~= nil, "host: [SNAP] own health from MedicalComponent: "
    .. tostring(own and own:match("hp=%S+")))

-- ============================================================== item 2: [HITCH]
-- (skeptic) [HITCH]'s "longest mod work" names the zombie step that stood
-- still: sdc_ue's own longest part is c:ai as a whole (session-client-b) or
-- none (ai-client-rest), the steps time themselves.
io.write("== item 2: [HITCH] names the zombie step\n")
local CS = { role = "client", remote = {}, in_menu = false, map = "PL" }
S.role = "client"
CT.round, timers = nil, {}
local function hitch_after(fn)
    diag.tick(CS)   -- the second before: takes (and so drops) what came earlier
    fn()
    local lh = #LOG
    diag.tick(CS)
    return logged("[HITCH]", lh) or ""
end
-- a) the step in the delayed rest (task ai-client-rest)
COST = { attacks = 0.001, corpses = 0.005, hud = 0, looks = 3.5, ghosts = 0.003 }
reset_calls()
local h = hitch_after(function()
    ai.client_tick()   -- attacks, corpses; the rest later
    run_timers()       -- ai-client-rest: hud, looks (3.5 s), carried again: ghosts, sweep
end)
check(order() == "attacks,corpses,hud,looks,ghosts" and h:find("task 'ai-client-rest' 3500 ms (AI step c:ai.looks 3500 ms)", 1, true),
    "a) looks stood still 3.5 s in the delayed rest: " .. h:match("longest mod work: [^|]*"))
-- b) in the first share, inside session-client-b's part c:ai
COST = { attacks = 0, corpses = 0, hud = 0, looks = 0.2, ghosts = 0 }
h = hitch_after(function()
    T = T + 3
    ue.guarded("session-client-b", function() ue.sub_time("c:ai", ai.client_tick) end)()
    run_timers()
end)
check(h:find("task 'session-client-b' 200 ms (part c:ai 200 ms) (AI step c:ai.looks 200 ms)", 1, true),
    "b) looks in session-client-b: part c:ai and the step: " .. h:match("longest mod work: [^|]*"))
-- c) another task was the longest: no AI step named for it
COST = { attacks = 0.001, corpses = 0.005, hud = 0, looks = 0.06, ghosts = 0 }
h = hitch_after(function()
    T = T + 3
    ai.client_tick()
    run_timers()       -- looks 60 ms in ai-client-rest
    ue.guarded("client-items", function() T = T + 0.3 end)()
end)
check(h:find("task 'client-items' 300 ms", 1, true) and not h:find("AI step", 1, true),
    "c) the longest task is another one: no AI step on it: " .. h:match("longest mod work: [^|]*"))
-- d) a step under 50 ms is not named, even in a task over 50 ms (looks 4.9 +
-- ghosts 46 ms in one rest)
COST = { attacks = 0.001, corpses = 0.005, hud = 0, looks = 0.0049, ghosts = 0.046 }
h = hitch_after(function()
    T = T + 3
    ai.client_tick()
    run_timers()
end)
check(h:find("task 'ai-client-rest' 51 ms", 1, true) and not h:find("AI step", 1, true),
    "d) a 46 ms step in a 51 ms task: not named (" .. h:match("longest mod work: [^|]*") .. ")")
S.role = "host"
check(ai.take_worst_step().ms == 0, "nothing left over")
S.role = "client"

io.write(string.format("mock_perf_link: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
