-- Mock test, "stability" wave (2026-11-13): real modules against fake UE objects.
--   A. sdc_ctx client mode: "not another player's" answers kept CLIENT_KEEP
--      ticks, "another player's" asked again every tick; client misses in [PERF].
--   B. sdc_speed: game speed / time lost to hitches / pauses / timer period
--      per second, new world and gaps, [PERF] window text, sdcoop_status line.
--      A hitch as the engine makes it: real time adds the whole frame, game
--      time at most 0.4 s of it (dg < dr).
--   C. sdc_gaptrace: "clock" rows from sdc_speed's records.
--   D. sdc_perf: [PERF] carries the speed window; [MEM] estimates the
--      out-array buffers UE4SS keeps (GetAllActorsOfClass via ue.actors_of).
--   E. sdc_speed: a [PERF] window paused throughout prints "-", not x0.00.
-- usage: lua mock_stability.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; io.write("  ok   ", what, "\n") else fails = fails + 1; io.write("  FAIL ", what, "\n") end
end
local logged = {}
print = function(s) logged[#logged + 1] = tostring(s) end
local function last_log(pat)
    for i = #logged, 1, -1 do if logged[i]:find(pat, 1, true) then return logged[i] end end
    return nil
end

-- ------------------------------------------------------------ fake objects
local calls = { GetOuter = 0, GetOwner = 0, GetClass = 0, IsLocal = 0 }
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    return rawget(t, "_m")[k]
end
local next_addr = 4096
local classes = {}
local function class_obj(name)
    local c = classes[name]
    if not c then
        next_addr = next_addr + 16
        c = setmetatable({ _cls = "Class", _name = name, _p = {}, _m = {}, _addr = next_addr, _valid = true }, Obj)
        classes[name] = c
    end
    return c
end
function Obj:IsValid() return self._valid end
function Obj:GetAddress() return self._addr end
function Obj:GetFName() local s = self._name; return { ToString = function() return s end } end
function Obj:GetFullName() return self._cls .. " /Game/Levels/X.X:PersistentLevel." .. self._name end
function Obj:GetClass() calls.GetClass = calls.GetClass + 1; return class_obj(self._cls) end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
local NULL = setmetatable({ _cls = "None", _name = "None", _p = {}, _m = {}, _addr = 0, _valid = false }, Obj)
function Obj:GetOuter() calls.GetOuter = calls.GetOuter + 1; return self._outer or NULL end

local registry = {}
local function new(cls, name, props, opts)
    opts = opts or {}
    next_addr = next_addr + 16
    local o = setmetatable({ _cls = cls, _name = name, _p = props or {}, _m = {}, _addr = next_addr, _valid = true,
                             _outer = opts.outer }, Obj)
    if opts.actor then
        o._m.GetOwner = function(self) calls.GetOwner = calls.GetOwner + 1; return self._owner or NULL end
    end
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
local function param(v)
    local p = { n = 0 }
    function p.get(self) self.n = self.n + 1; return v end
    function p.set(self, x) v = x end
    function p.value() return v end
    return p
end

-- the client's world
local level = new("Level", "PersistentLevel")
local lp = new("LocalPlayer", "LocalPlayer_0")
local own_pc = new("BP_PlayerController_C", "OwnPC", { Player = lp }, { outer = level, actor = true })
local own_pawn = new("BP_PlayerCharacter_C", "OwnChar", { Controller = own_pc }, { outer = level, actor = true })
own_pawn._m.IsLocallyControlled = function() calls.IsLocal = calls.IsLocal + 1; return true end
local other_pawn = new("BP_PlayerCharacter_C", "OtherChar", {}, { outer = level, actor = true })
other_pawn._m.IsLocallyControlled = function() calls.IsLocal = calls.IsLocal + 1; return false end
local other_knife = new("BP_KnifePickup_C", "Knife_O", {}, { outer = level, actor = true })
other_knife._owner = other_pawn
local crate = new("Container_RandomLoot_TrashBag_C", "TrashBag_1", {}, { outer = level, actor = true })
local controllers = { own_pc }

-- GameplayStatics: player-0 functions (hooked), world clock (sdc_speed), actors (sdc_perf)
local G = { game = 0, real = 0, dil = 1, paused = false }
local gps = new("GameplayStatics", "Default__GameplayStatics")
gps._m.GetNumPlayerControllers = function() return #controllers end
gps._m.GetPlayerController = function(_, wc, i) return controllers[i + 1] or NULL end
gps._m.GetTimeSeconds = function() return G.game end
gps._m.GetRealTimeSeconds = function() return G.real end
gps._m.GetGlobalTimeDilation = function() return G.dil end
gps._m.IsGamePaused = function() return G.paused end
local zombies = {}
local gaoc = 0
gps._m.GetAllActorsOfClass = function(_, wc, cls, out)
    gaoc = gaoc + 1
    for i, z in ipairs(zombies) do out[i] = z end
end

local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = { pre = pre, post = post }; return 7, 8 end
function FindAllOf(cls)
    if cls == "PlayerController" then return controllers end
    return registry[cls] or {}
end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path)
    if path == "/Script/Engine.Default__GameplayStatics" then return gps end
    if path:find("BP_Zombie", 1, true) then return class_obj("BP_Zombie_C") end
    return nil
end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay() return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function RegisterConsoleCommandHandler() end
FName = function(s) return s end

local perf = require("sdc_perf")
local log = require("sdc_log")
local cfg = require("sdc_config")
local ue = require("sdc_ue")
check(perf.watch_out_arrays(ue) == true, "D0: out-array counter installed on ue.actors_of")
check(perf.watch_out_arrays(ue) == false, "D0: installed once only")
local ctx = require("sdc_ctx")

local function call(fname, wco)
    local h = hooks["/Script/Engine.GameplayStatics:" .. fname]
    local ip = param(0)
    h.pre(param(gps), param(wco), ip)
    return ip.value()
end
local function walks() return calls.GetOuter + calls.GetOwner + calls.GetClass end

-- ============================================================== A. sdc_ctx client cache
io.write("== A. sdc_ctx client mode cache\n")
do
    ctx.reset()
    ctx.tick_client(true)
    check(ctx.active and ctx.client_mode, "client mode on, hooks installed")
    local ps = ctx.pstats
    local m0 = ps.cmiss
    check(call("GetPlayerCharacter", crate) == 0, "a world container: player 0 stays this player")
    check(ps.cmiss == m0 + 1, "first call: one client miss (a walk)")
    local w0 = walks()
    for _ = 1, 10 do call("GetPlayerCharacter", crate) end
    check(ps.cmiss == m0 + 1 and walks() == w0, "same second: from the cache, no engine walk")
    -- the next ticks: the container's 'no' is kept (it asks about once a second);
    -- the whole cache goes every 5th tick (tick 1 was the one above)
    for i = 2, 4 do
        T = T + 1
        ctx.tick_client(true)
        call("GetPlayerCharacter", crate)
        check(ps.cmiss == m0 + 1 and walks() == w0, "tick " .. i .. ": the container's answer kept (no walk)")
    end
    T = T + 1
    ctx.tick_client(true)
    call("GetPlayerCharacter", crate)
    check(ps.cmiss == m0 + 2, "tick 5: the whole cache dropped, walked again")
    -- another player's knife: asked again every tick
    local m1 = ps.cmiss
    check(call("GetPlayerController", other_knife) == 64, "another player's knife -> no player (effect skipped)")
    check(call("GetPlayerController", other_knife) == 64 and ps.cmiss == m1 + 1, "same second: cached")
    T = T + 1
    ctx.tick_client(true)
    check(call("GetPlayerController", other_knife) == 64 and ps.cmiss == m1 + 2, "next tick: another player's object asked again")
    -- own character: kept like the world
    check(call("GetPlayerController", own_pawn) == 0, "own character -> own player")
    local l0 = calls.IsLocal
    T = T + 1
    ctx.tick_client(true)
    call("GetPlayerController", own_pawn)
    check(calls.IsLocal == l0, "own character: not asked again on the next tick")
    -- the knife is dropped (no owner any more): its 'another player's' answer goes at the next tick
    check(call("GetPlayerController", other_knife) == 64, "the knife still another player's this second")
    other_knife._owner = nil
    check(call("GetPlayerController", other_knife) == 64, "dropped this second: still the cached answer")
    T = T + 1
    ctx.tick_client(true)
    check(call("GetPlayerController", other_knife) == 0, "next tick: the dropped knife is the world's -> player 0")
    -- the other way (documented): a 'no' that becomes another player's waits for the full drop (<= 5 ticks)
    for _ = 1, 5 do T = T + 1; ctx.tick_client(true) end   -- a fresh full drop happened in these
    ctx.reset()
    ctx.tick_client(true)
    check(call("GetPlayerCharacter", crate) == 0, "fresh cache: the container -> 0")
    crate._owner = other_pawn
    local seen_other = nil
    for i = 1, 5 do
        T = T + 1
        ctx.tick_client(true)
        if call("GetPlayerCharacter", crate) == 64 then seen_other = i break end
    end
    check(seen_other ~= nil and seen_other <= 5, "a container taken by another player is seen within 5 ticks (tick "
        .. tostring(seen_other) .. ")")
    crate._owner = nil
    -- [PERF] ctx text has the client misses
    local s = ctx.perf_text(10)
    check(type(s) == "string" and s:find("client misses", 1, true) ~= nil, "[PERF] ctx: client misses shown: " .. tostring(s))
    -- reset drops everything
    ctx.reset()
    ctx.tick_client(true)
    local m2 = ps.cmiss
    call("GetPlayerCharacter", crate)
    check(ps.cmiss == m2 + 1, "after a world reset the container is walked again")
    ctx.reset()
end

-- ============================================================== B. sdc_speed
io.write("== B. sdc_speed\n")
local speed = require("sdc_speed")
do
    check(speed.status_line():find("not measured yet", 1, true) ~= nil, "before any sample: not measured yet")
    G.game, G.real = 50, 60
    check(speed.sample(T) == nil, "first sample: a baseline only")
    local function step(dc, dg, dr)
        T = T + dc
        G.game, G.real = G.game + dg, G.real + (dr or dc)
        return speed.sample(T)
    end
    local r = step(1.0, 1.0)
    check(r and math.abs(r.speed - 1) < 1e-9 and r.lost == 0, "normal second: speed x1.00, nothing lost to hitches")
    G.dil = 0.5
    r = step(1.0, 0.5)
    check(r and math.abs(r.speed - 0.5) < 1e-9 and r.dil == 0.5 and r.lost == 0,
        "dilation 0.5 (changed in this second): speed x0.50, not a hitch")
    G.dil = 1
    r = step(1.2, 1.2)
    check(r and math.abs(r.dt - 1.2) < 1e-9 and r.lost == 0, "a late timer: the period is 1.2 s (dilation back to 1: not a hitch)")
    -- a hitch as the engine makes it: one 0.6 s frame; real time adds all of
    -- it (MaxDeltaTime 0), game time at most 0.4 s (MaxUndilatedFrameTime)
    r = step(1.0, 0.8)
    check(r and math.abs(r.speed - 0.8) < 1e-9 and math.abs(r.lost - 0.2) < 1e-9, "a hitch: speed x0.80, 0.2 s lost")
    G.paused = true
    r = step(1.0, 0)
    check(r and r.paused and r.speed == nil, "paused: counted apart, no speed")
    G.paused = false
    r = step(1.0, 0)   -- the second that ended the pause still started paused
    check(r and r.paused, "the second leaving the pause is a paused one too")
    r = step(1.0, 1.0)
    check(r and not r.paused and math.abs(r.speed - 1) < 1e-9, "after the pause: x1.00 again")
    -- a long gap (loading): a new start, no record
    local seq = speed.seq
    r = step(8.0, 8.0)
    check(r == nil and speed.seq == seq, "8 s between samples: no record (a new start)")
    -- a new world: its clock starts at 0
    T = T + 1; G.game, G.real = 0.5, 0.5
    r = speed.sample(T)
    check(r == nil and speed.total.restarts >= 2, "game time went back (a new world): no record, restart counted")
    r = step(1.0, 1.0)
    check(r and math.abs(r.speed - 1) < 1e-9, "the new world measures from its own start")
    -- a new world with another controller (address)
    own_pc._valid = false
    local pc2 = new("BP_PlayerController_C", "OwnPC2", { Player = lp }, { outer = level, actor = true })
    controllers = { pc2 }
    ue.forget_world()
    r = step(1.0, 1.0)
    check(r == nil, "another local controller: a new baseline, no record")
    r = step(1.0, 1.0)
    check(r ~= nil, "and measured again from there")
    -- [PERF] window and status line
    local w = speed.window_text(false)
    check(w and w:find("slowest second x0.50", 1, true) and w:find("dilation 1.00", 1, true)
        and w:find("lost to hitches 0.2 s", 1, true) and not w:find("engine", 1, true)
        and w:find("paused 2 s", 1, true) and w:find("1 s timer every", 1, true), "window text: " .. tostring(w))
    check(speed.window_text(false) == w, "read-only window text leaves the window as it was")
    check(speed.window_text(true) == w and speed.window_text(true) == nil, "commit: a new window starts (empty)")
    local st = speed.status_line()
    check(st:find("over the last 9 s", 1, true) and st:find("below x0.95", 1, true) and st:find("2 s paused", 1, true),
        "status line: " .. st)
    -- unpaused seconds: game 6.5 s in 7.2 s of clock
    check(st:find("game x0.90", 1, true) ~= nil, "status: the last seconds' average game speed (x0.90 with the slow ones)")
    check(st:find("lost to hitches 0.2 s", 1, true) and st:find("0.2 s lost to hitches", 1, true),
        "status: time lost to hitches, last seconds and session")
end

-- ============================================================== C. sdc_gaptrace clock rows
io.write("== C. sdc_gaptrace clock rows\n")
do
    local gaptrace = require("sdc_gaptrace")
    gaptrace.clock_seen = 0
    gaptrace._count_clock()
    local rows = gaptrace._rows()
    local function n(key) return rows[key] and rows[key].n or 0 end
    check(n("clock|game_speed|x1.00|") >= 4, "game_speed x1.00 seconds counted (" .. n("clock|game_speed|x1.00|") .. ")")
    check(n("clock|game_speed|x0.50|") == 1, "one second at x0.50")
    check(n("clock|game_speed|x0.80|") == 1, "one second at x0.80 (the hitch)")
    check(n("clock|paused|-|") == 2, "two paused seconds")
    check(n("clock|dilation|0.50|") == 1, "the dilated second")
    check(n("clock|timer_period|1.10-1.25s|") == 1 and n("clock|timer_period|<1.02s|") >= 6, "timer periods by band")
    check(n("clock|hitches|0.05-0.5s|") == 1, "the hitch second: 0.2 s lost, band 0.05-0.5s")
    local hitches = 0
    for k, r in pairs(rows) do if k:find("^clock|hitches|") then hitches = hitches + r.n end end
    check(hitches == 1, "seconds with a dilation change are no hitches (" .. hitches .. " hitch rows)")
    local total = 0
    for k, r in pairs(rows) do if k:find("^clock|game_speed|") then total = total + r.n end end
    gaptrace._count_clock()
    local total2 = 0
    for k, r in pairs(rows) do if k:find("^clock|game_speed|") then total2 = total2 + r.n end end
    check(total2 == total, "the same records are not counted twice")
    -- switched on now: only the seconds after the switch
    cfg.values.gap_trace = true
    gaptrace.reset()
    gaptrace.clock_seen = 0   -- as on a fresh start: every record still unseen
    gaptrace.tick(T)
    check(gaptrace.clock_seen == speed.seq and next(gaptrace._rows()) == nil, "gap_trace switched on: history not counted")
    T = T + 1; G.game, G.real = G.game + 1, G.real + 1
    speed.sample(T)
    gaptrace.tick(T)
    rows = gaptrace._rows()
    check(rows["clock|game_speed|x1.00|"] and rows["clock|game_speed|x1.00|"].n == 1, "the next second is counted")
    cfg.values.gap_trace = false
    gaptrace.tick(T)
end

-- ============================================================== D. sdc_perf
io.write("== D. sdc_perf: speed in [PERF], out-array estimate in [MEM]\n")
do
    T = T + 1; G.game, G.real = G.game + 0.5, G.real + 1; G.dil = 0.5
    speed.sample(T)
    G.dil = 1
    -- the window: the x1.00 second of C and this x0.50 one
    local peek = perf.peek("status", {})
    check(peek:find("game speed x0.75 (slowest second x0.50", 1, true) ~= nil, "sdcoop_status (peek): the running speed window")
    local line = perf.report("window", {})
    check(line:find("| game speed x0.75 (slowest second x0.50", 1, true) ~= nil, "[PERF] line: game speed of the window")
    line = perf.report("window", {})
    check(not line:find("game speed", 1, true), "an empty window: no speed part")
    -- out arrays through ue.actors_of
    for i = 1, 300 do zombies[i] = new("BP_Zombie_C", "Z" .. i) end
    local out = ue.actors_of("/Game/Blueprints/AI/BP_Zombie.BP_Zombie_C")
    check(type(out) == "table" and #out == 300 and gaoc == 1, "the wrapped ue.actors_of returns the engine's list unchanged")
    out = ue.actors_of("/Game/Blueprints/AI/BP_Zombie.BP_Zombie_C")
    check(perf.out_arrays.calls == 2 and perf.out_arrays.elems == 600, "2 calls, 600 actors counted")
    local none = ue.actors_of("/Game/Nothing.Nothing_C")
    check(none == nil and perf.out_arrays.calls == 2, "no class: nil passed on, nothing counted")
    perf.mem_census()
    local mem = last_log("[MEM]") or ""
    check(mem:find("out-array buffers UE4SS keeps (estimate): >= 5 KB from 2 GetAllActorsOfClass calls (600 actors)", 1, true)
        ~= nil, "[MEM] line: estimate (600 x 8 bytes)")
    ue.actors_of("/Game/Blueprints/AI/BP_Zombie.BP_Zombie_C")
    perf.mem_census()
    mem = last_log("[MEM]") or ""
    check(mem:find("+2 KB since the last [MEM]", 1, true) ~= nil, "[MEM] line: growth since the last one")
end

-- ============================================================== E. a paused [PERF] window
io.write("== E. sdc_speed: a window paused throughout\n")
do
    G.paused = true
    for _ = 1, 2 do T = T + 1; G.real = G.real + 1; speed.sample(T) end
    local w = speed.window_text(false)
    check(w and w:find("game speed - (slowest second -,", 1, true) and w:find("lost to hitches -,", 1, true)
        and w:find("paused 2 s", 1, true) and not w:find("x0.00", 1, true), "paused window, no x0.00: " .. tostring(w))
    local line = perf.report("window", {})
    check(line:find("| game speed - (slowest second -,", 1, true) ~= nil, "[PERF] line: the paused window")
    for _ = 1, 8 do T = T + 1; G.real = G.real + 1; speed.sample(T) end
    local st = speed.status_line()
    check(st:find("game x- over the last 10 s", 1, true) and st:find("lost to hitches -,", 1, true)
        and st:find("paused 10 s", 1, true), "status, 10 paused seconds: " .. st)
    G.paused = false
    T = T + 1; G.game, G.real = G.game + 1, G.real + 1
    local r = speed.sample(T)
    check(r and r.paused, "the second leaving the pause")
    T = T + 1; G.game, G.real = G.game + 1, G.real + 1
    r = speed.sample(T)
    check(r and not r.paused and r.lost == 0, "after the pause: running, nothing lost")
    line = perf.report("window", {})
    check(line:find("| game speed x1.00 (slowest second x1.00,", 1, true) and line:find("lost to hitches 0.0 s,", 1, true),
        "[PERF] line after the pause: the running second only")
end

io.write(string.format("mock_stability: %d passed, %d failed\n", passed, fails))
io.write(fails == 0 and "ALL OK\n" or "FAILED\n")
os.exit(fails == 0 and 0 or 1)
