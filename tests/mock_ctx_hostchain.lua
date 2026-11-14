-- Mock harness: sdc_ctx's player-0 hook fast path and its caches (0.6.75 perf
-- work), sdc_world's resolver fast prefix, sdc_perf's bench switch / hook
-- kinds and sdcoop_bench (sdc_bench). Real modules against fake UE objects.
-- usage: lua mock_ctx_hostchain.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
local real_clock = os.clock
os.clock = function() return T end
local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what) end
end

-- ------------------------------------------------------------ fake objects
-- engine-call counters: the fast path must not touch engine objects
local calls = { GetOuter = 0, GetOwner = 0, owner_missing = 0, GetClass = 0, GetProp = 0, IsLocal = 0, NumPCs = 0 }
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    if k == "GetOwner" then calls.owner_missing = calls.owner_missing + 1 end
    return nil   -- a missing member: calling it is "attempt to call a nil value"
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
function Obj:GetPropertyValue(n) calls.GetProp = calls.GetProp + 1; return self._p[n] end
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

-- a hook parameter; counts its reads
local function param(v)
    local p = { n = 0 }
    function p.get(self) self.n = self.n + 1; return v end
    function p.set(self, x) v = x end
    function p.value() return v end
    return p
end

-- ------------------------------------------------------------ the world
local level = new("Level", "PersistentLevel")
local lp = new("LocalPlayer", "LocalPlayer_0")
local host_pc = new("BP_PlayerController_C", "HostPC", { Player = lp }, { outer = level, actor = true })
local host_pawn = new("BP_PlayerCharacter_C", "HostChar", { Controller = host_pc }, { outer = level, actor = true })
host_pc._p.Pawn = host_pawn
local conn = new("IpConnection", "Conn")
local rpc = new("BP_PlayerController_C", "RemotePC", { NetConnection = conn }, { outer = level, actor = true })
local rpawn = new("BP_PlayerCharacter_C", "RemoteChar", { Controller = rpc }, { outer = level, actor = true })
rpc._p.Pawn = rpawn
local rstamina = new("StaminaComponent_C", "Stamina_R", {}, { outer = rpawn, actor = true })
rstamina._m.GetOwner = function() calls.GetOwner = calls.GetOwner + 1; return rpawn end
local hud = new("BP_Ingame_C", "BP_Ingame_C_0", {}, { outer = host_pc })            -- a widget: no GetOwner
local hud2 = new("BP_Ingame_C", "BP_Ingame_C_1", {}, { outer = host_pc })
local rknife = new("BP_KnifePickup_C", "Knife_R", {}, { outer = level, actor = true })
rknife._owner = rpawn
rknife._p.BP_WeaponsPickupComponent = new("BP_WeaponsPickupComponent_C", "WPC", {}, { outer = rknife })
local crate = new("BP_Crate_C", "Crate_1", {}, { outer = level, actor = true })
local box = new("Container_RandomLoot_TrashBag_C", "TrashBag_1", { CurrentActor = NULL }, { outer = level, actor = true })
local controllers = { host_pc, rpc }

local gps = new("GameplayStatics", "Default__GameplayStatics")
gps._m.GetNumPlayerControllers = function() calls.NumPCs = calls.NumPCs + 1; return #controllers end
gps._m.GetPlayerController = function(_, wc, i) return controllers[i + 1] or NULL end
gps._m.GetPlayerControllerFromID = function(_, wc, i) return controllers[i + 1] or NULL end
local delta_ms = 1000 / 60
gps._m.GetWorldDeltaSeconds = function() return delta_ms / 1000 end
gps._m.GetGlobalTimeDilation = function() return 1.0 end
gps._m.IsGamePaused = function() return false end
host_pawn._m.K2_GetActorLocation = function() return { X = 100, Y = 200, Z = 300 } end
host_pawn._m.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end
local gfl = new("GameFunctionLibrary_C", "Default__GameFunctionLibrary_C")
local bp_calls = 0
gfl._m.GetGameMode = function(_, wc, out) bp_calls = bp_calls + 1; out.GameMode = NULL end

-- ------------------------------------------------------------ UE4SS globals
local FUNC_NATIVE = 0x400
local hooks, raw_regs = {}, 0
function RegisterHook(path, pre, post) raw_regs = raw_regs + 1; hooks[path] = { pre = pre, post = post }; return 7, 8 end
function FindAllOf(cls)
    if cls == "PlayerController" then return controllers end
    return registry[cls] or {}
end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path)
    if path == "/Script/Engine.Default__GameplayStatics" then return gps end
    if path == "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C" then return gfl end
    if path:find(":", 1, true) then
        -- a UFunction: native for /Script/ ones except the Blueprint event below
        local flags = (path:sub(1, 8) == "/Script/" and not path:find("ReceiveTick", 1, true)) and FUNC_NATIVE or 0
        local f = new("Function", path)
        f._m.GetFunctionFlags = function() return flags end
        return f
    end
    return nil
end
function NotifyOnNewObject() end
local delayed = {}
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay(_, f) delayed[#delayed + 1] = f; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay(_, f) delayed[#delayed + 1] = f end
function LoopAsync() end
local console = {}
function RegisterConsoleCommandHandler(name, fn) console[name] = fn end
local function run_delayed() local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end

-- ------------------------------------------------------------ modules
local ini = os.tmpname()
local perf = require("sdc_perf")
perf.wrap_register_hook()
local log = require("sdc_log")
local lines = {}
local info0 = log.info
log.info = function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    lines[#lines + 1] = ok and s or tostring(fmt)
    return info0(fmt, ...)
end
local function find_line(pat)
    for i = #lines, 1, -1 do if lines[i]:find(pat, 1, true) then return lines[i] end end
    return nil
end
local cfg = require("sdc_config")
cfg.load(ini)
local ue = require("sdc_ue")
local ctx = require("sdc_ctx")
check(console.sdcoop_bench ~= nil, "sdcoop_bench console command registered by sdc_perf")

-- calls one player-0 hook the way UE4SS does: (Context, WorldContextObject, PlayerIndex)
local function call(fname, wco, idx)
    local h = hooks["/Script/Engine.GameplayStatics:" .. fname]
    local wp, ip = param(wco), param(idx or 0)
    h.pre(param(gps), wp, ip)
    return ip.value(), wp, ip
end

-- ============================================================================
-- Host chain: the real sdc_vehicles + sdc_world + sdc_respawn resolvers and the
-- real sdc_ai_kills stand-in behind sdc_ctx's hooks
-- (why the host's idle shortcut never fired: sdc_respawn's bed routing is on for
-- the whole game, so its idle check said "busy" for EVERY object).
-- Measures the Lua side only (the fake engine calls cost nothing here: the
-- real ones, ~2 us each, are counted instead).
-- ============================================================================
print("== host chain: real respawn + world behind the hooks")
-- upvalue access: the real modules keep their state in locals
local function upv(f, name)
    for i = 1, 60 do
        local n, v = debug.getupvalue(f, i)
        if not n then return nil end
        if n == name then return v, i end
    end
end
local reset_hooks = {}   -- other caches the real game drops on their own period (world / vehicles)
local ue2 = require("sdc_ue")
local loops = {}
ue2.every = function(label, ms, fn) loops[label] = fn end
ctx.SCOPE_API = 1
local S = { role = "host", remote = {}, remote_pcs = { rpc }, map = "X" }
S.remote[rpc:GetFullName()] = { key = rpc:GetFullName(), pc = rpc, name = "Friend", index = 1 }
local players = require("sdc_players")
pcall(players.init, S, { remote_record = function(pc) return S.remote[pc:GetFullName()] end })
local respawn = require("sdc_respawn")
respawn.install(S)
local respawn_fn = ctx.scope_resolver
run_delayed()
check(loops.respawn ~= nil, "respawn tick scheduled")
local okt, terr = pcall(loops.respawn)
check(okt, "respawn tick runs (" .. tostring(terr) .. ")")
check(respawn.status_line():find("bed_routing=true", 1, true) ~= nil, "bed routing is on (the normal host state)")
local world = require("sdc_world")
world.install(S)
check(ctx.scope_resolver == world.resolver, "world chained in front of respawn")
-- sdc_world drops its class cache every 2-4 s (its slow tick): modelled every 3rd second
do
    local _, i = upv(world.resolver, "cls_cache")
    check(i ~= nil, "world's cls_cache upvalue reached")
    reset_hooks[#reset_hooks + 1] = function(sec) if sec % 3 == 0 and i then debug.setupvalue(world.resolver, i, {}) end end
end

-- the host's world: many objects of the kinds seen in the log
local objs = {}
local function add(o, w) objs[#objs + 1] = { o = o, w = w } end
for i = 1, 8 do add(new("BP_Ingame_C", "HUD" .. i, {}, { outer = host_pc }), 6) end              -- widgets
for i = 1, 6 do add(new("BP_PlayerCameraManager_C", "Cam" .. i, {}, { outer = level, actor = true }), 3) end
for i = 1, 10 do add(new("Sky_C", "Sky" .. i, {}, { outer = level, actor = true }), 2) end
for i = 1, 10 do add(new("StaminaComponent_C", "HStam" .. i, {}, { outer = host_pawn }), 3) end
add(host_pawn, 8)
for i = 1, 4 do add(new("Container_RandomLoot_TrashBag_C", "Bag" .. i, { CurrentActor = NULL }, { outer = level, actor = true }), 1) end
for i = 1, 3 do add(new("BP_KnifePickup_C", "HKnife" .. i, {}, { outer = level, actor = true }), 1) end   -- 'weapon' kind
local bedowner = new("Buildable_Bed_C", "Bed", { CurrentActor = NULL }, { outer = level, actor = true })
local bedcomp = new("BedComponent_C", "BedComp", {}, { outer = bedowner, actor = true })
bedcomp._m.GetOwner = function() return bedowner end
add(bedcomp, 1)
-- a remote player's objects: must be redirected (index 1)
local remote_objs = { rstamina, rpawn }
add(rstamina, 3); add(rpawn, 2)
local rknife2 = new("BP_KnifePickup_C", "Knife_R2", {}, { outer = level, actor = true })
rknife2._owner = rpawn
rknife2._p.BP_WeaponsPickupComponent = new("BP_WeaponsPickupComponent_C", "WPC2", {}, { outer = rknife2 })
add(rknife2, 1)
local zombie = new("BP_Zombie_Roamer_C", "Zombie_1", {}, { outer = level, actor = true })
add(zombie, 1)
local FNAMES = { "GetPlayerController", "GetPlayerCameraManager", "GetPlayerCharacter" }
local wsum = 0
for _, e in ipairs(objs) do wsum = wsum + e.w end

-- expected answers (what the redirects must give): the same before and after
local function expected(o)
    if o == rstamina or o == rpawn then return 1 end
    if o == rknife2 then return "knife" end
    if o == bedcomp then return bedowner._p.CurrentActor == rpawn and 1 or 0 end
    if o == zombie then return zombie._dying and 1 or 0 end
    return 0
end
-- the REAL sdc_ai_kills stand-in; "dying" is its own table, core its keys -> controllers
local kills = require("sdc_ai_kills")
local dying = upv(kills.stand_in, "dying")
check(type(dying) == "table", "the real stand_in's dying table reached")
do
    local _, i = upv(kills.stand_in, "core")
    debug.setupvalue(kills.stand_in, i, { pc_by_key = function() return rpc end })
end
local stand_in = kills.stand_in
local function setup_dying(on)
    zombie._dying = on
    dying[zombie._addr] = on and { key = "k", t = os.clock(), ttl = 1e9, used = false, kind = "zombie" } or nil
end
local sec = 0
local function reset_second()
    T = T + 1
    sec = sec + 1
    ctx.tick({ rpc })
    for _, f in ipairs(reset_hooks) do f(sec) end
    -- the respawn tick drops its class cache every second too
    pcall(loops.respawn)
end
local calls_total = 1250
function Obj:GetAddress() calls.Addr = (calls.Addr or 0) + 1; return self._addr end
local function engine_total()
    local t = calls.Addr or 0
    for _, k in ipairs({ "GetOuter", "GetOwner", "GetClass", "GetProp", "NumPCs" }) do t = t + calls[k] end
    return t
end
local gp = param(gps)
local rng = 42
local plan = nil   -- one second of calls, prepared once: the harness adds no allocation to the timing
local function make_plan()
    ctx.tick({ rpc })   -- active: the hooks get registered
    plan = {}
    local seq = 0
    for _, e in ipairs(objs) do
        local reps = math.floor(calls_total * e.w / wsum + 0.5)
        for _ = 1, reps do
            seq = seq + 1
            local fname = FNAMES[seq % 3 + 1]
            plan[#plan + 1] = { h = hooks["/Script/Engine.GameplayStatics:" .. fname].pre, wp = param(e.o), ip = param(0),
                                fname = fname, o = e.o }
        end
    end
    -- interleave the objects (the game's calls do not come grouped)
    local n = #plan
    for i = n, 2, -1 do
        rng = (rng * 1103515245 + 12345) % 2147483648
        local j = rng % i + 1
        plan[i], plan[j] = plan[j], plan[i]
    end
end
local function run(label, secs)
    if not plan then make_plan() end
    local before = { idle = ctx.pstats.idle }
    local wrong, n, spent = 0, 0, 0
    local e0, g0 = engine_total(), 0
    for i = 1, #plan do g0 = g0 + plan[i].wp.n + plan[i].ip.n end
    for _ = 1, secs do
        reset_second()
        for i = 1, #plan do plan[i].ip:set(0) end
        local t0 = real_clock()
        for i = 1, #plan do
            local c = plan[i]
            c.h(gp, c.wp, c.ip)
        end
        spent = spent + (real_clock() - t0)
        for i = 1, #plan do
            local c = plan[i]
            local want = expected(c.o)
            if want == "knife" then want = (c.fname == "GetPlayerController") and 64 or 1 end
            if c.ip.value() ~= want then wrong = wrong + 1 end
        end
        n = n + #plan
    end
    local idle = ctx.pstats.idle - before.idle
    local g1 = 0
    for i = 1, #plan do g1 = g1 + plan[i].wp.n + plan[i].ip.n end
    local eng = (engine_total() - e0 + g1 - g0) / n
    return { eng = eng, us = spent * 1e6 / n, n = n, idle = idle, wrong = wrong, label = label, idx_reads = n - idle }
end
local function show(r)
    print(string.format("  %-34s %6d calls, %5.2f us/call (mock), idle shortcut %5.1f%%, index read %5.1f%%, wrong answers %d, engine reads/call %.2f",
        r.label, r.n, r.us, 100 * r.idle / r.n, 100 * r.idx_reads / r.n, r.wrong, r.eng))
end

ctx.stand_in = stand_in
local stand_dying_global = false
local OLD = function() return false end
-- A. "before": respawn's old check (busy whenever bed routing is on)
ctx.set_idle_check(respawn_fn, OLD)
ctx.set_idle_check(stand_in, function() return not zombie._dying end)
setup_dying(false)
run("warm-up", 2)
local rA0 = run("A. calm, before (old respawn check)", 10)
show(rA0)
-- A. "after": the real new check
ctx.set_idle_check(respawn_fn, respawn.resolver_idle)
ctx.set_idle_check(stand_in, kills.stand_in_idle)
local rA1 = run("A. calm, after", 10)
show(rA1)
check(rA0.idle == 0, "before: the shortcut never fires (as in the host log: idle 0/s)")
check(rA1.idle > rA1.n * 0.6, "after: most calls take the shortcut")
check(rA0.wrong == 0 and rA1.wrong == 0, "calm: every answer correct before and after")
-- B. an AI is dying (its killer is the remote player): old = global check
setup_dying(true)
ctx.set_idle_check(respawn_fn, OLD)
ctx.set_idle_check(stand_in, function() return not zombie._dying end)
local rB0 = run("B. AI dying, before", 10)
show(rB0)
ctx.set_idle_check(respawn_fn, respawn.resolver_idle)
ctx.set_idle_check(stand_in, kills.stand_in_idle)
local rB1 = run("B. AI dying, after (per object)", 10)
show(rB1)
check(rB1.idle > rB1.n * 0.6, "AI dying: the other objects still take the shortcut")
check(rB0.wrong == 0 and rB1.wrong == 0, "AI dying: the zombie's player 0 is the killer, the rest unchanged")
-- C. a remote player uses a bed: the bed component answers, others stay idle
setup_dying(false)
ctx.set_idle_check(stand_in, kills.stand_in_idle)
bedowner._p.CurrentActor = rpawn
local rC1 = run("C. remote player in a bed, after", 6)
show(rC1)
check(rC1.wrong == 0, "bed of a remote player -> that player's index")
bedowner._p.CurrentActor = NULL
-- C2. the bed is used by the remote player in the middle of a second, after the
-- component was cached "nobody's": it must still answer at once (the class
-- check of the idle test is what keeps the shortcut off for it)
do
    reset_second()
    local function pass()
        for i = 1, #plan do plan[i].ip:set(0) end
        for i = 1, #plan do local c = plan[i]; c.h(gp, c.wp, c.ip) end
    end
    pass()
    bedowner._p.CurrentActor = rpawn
    pass()
    local bad = 0
    for i = 1, #plan do
        local c = plan[i]
        if c.o == bedcomp and c.ip.value() ~= 1 then bad = bad + 1 end
    end
    check(bad == 0, "C2. the bed gets used mid-second: its calls go to that player at once (" .. bad .. " wrong)")
    bedowner._p.CurrentActor = NULL
end
-- C3. an AI starts dying mid-second, after its zombie was cached "nobody's"
do
    reset_second()
    local function pass()
        for i = 1, #plan do plan[i].ip:set(0) end
        for i = 1, #plan do local c = plan[i]; c.h(gp, c.wp, c.ip) end
    end
    pass()
    setup_dying(true)
    pass()
    local bad = 0
    for i = 1, #plan do
        local c = plan[i]
        if c.o == zombie and c.ip.value() ~= 1 then bad = bad + 1 end
    end
    check(bad == 0, "C3. an AI starts dying mid-second: its calls go to the killer at once (" .. bad .. " wrong)")
    setup_dying(false)
end
-- C4. a respawn scope opens mid-second (the game's respawn RPC of the remote
-- player): objects of its classes answer for that player at once, even if they
-- were cached "nobody's" a moment ago; with it closed they are idle again
do
    local scopes = upv(respawn.resolver_idle, "scopes")
    check(type(scopes) == "table", "respawn's scopes table reached")
    local sky1 = nil
    for _, e in ipairs(objs) do if e.o._cls == "Sky_C" then sky1 = e.o; break end end
    reset_second()
    local function pass()
        for i = 1, #plan do plan[i].ip:set(0) end
        for i = 1, #plan do local c = plan[i]; c.h(gp, c.wp, c.ip) end
    end
    pass()
    scopes[#scopes + 1] = { pc = rpc, till = os.clock() + 100, classes = { Sky_C = true } }
    pass()
    local bad, n = 0, 0
    for i = 1, #plan do
        local c = plan[i]
        if c.o._cls == "Sky_C" then n = n + 1; if c.ip.value() ~= 1 then bad = bad + 1 end end
    end
    check(n > 0 and bad == 0, "C4. scope open mid-second: the Sky objects' calls go to that player (" .. bad .. "/" .. n .. " wrong)")
    for i = #scopes, 1, -1 do scopes[i] = nil end
    reset_second()
    local r = run("C4. scope closed again", 2)
    check(r.idle > r.n * 0.6 and r.wrong == 0, "C4. scope closed: the shortcut is back")
end
-- D. the REAL vehicles resolver in front of world and respawn, a vehicle watched
-- (a client drives it): its parts stay busy (answered for the driver), every
-- other object is still idle; the outer cache is dropped every 4th second
do
    local V = require("sdc_vehicles")
    local okv, verr = pcall(V.install, S)
    check(okv, "sdc_vehicles installs (" .. tostring(verr) .. ")")
    pcall(V.tick)
    local top = ctx.scope_resolver
    check(top ~= world.resolver, "vehicles chained in front of world")
    local truck = new("Vehicle_FlatbedTruck_C", "Truck_1", {}, { outer = level, actor = true })
    local part = new("VehicleMovementComponent_C", "TruckMC", {}, { outer = truck })
    -- a second vehicle that is watched but has no opinion (a window open, nobody
    -- driving): its calls stay with the host (0) yet must take the full path
    local truck2 = new("Vehicle_FlatbedTruck_C", "Truck_2", {}, { outer = level, actor = true })
    local part2 = new("VehicleMovementComponent_C", "Truck2MC", {}, { outer = truck2 })
    add(truck, 1); add(part, 2); add(truck2, 1); add(part2, 2)
    local vs = V._t.vs()
    vs[truck2._addr] = { name = ue.short(truck2), cls = "Vehicle_FlatbedTruck_C", pax = {}, scope_till = os.clock() + 1000, watch = true }
    vs[truck._addr] = { name = ue.short(truck), cls = "Vehicle_FlatbedTruck_C", pax = {}, driver_key = rpc:GetFullName() }
    -- watch_n is the resolver's own counter: recount the way the module does
    local _, wi = upv(top, "watch_n")
    check(wi ~= nil, "vehicles' watch_n upvalue reached")
    local idle_fn = upv(ctx.set_idle_check, "idle_of")[top]
    local _, oi = upv(idle_fn, "outer_cache")
    reset_hooks[#reset_hooks + 1] = function(sec) if sec % 4 == 0 and oi then debug.setupvalue(idle_fn, oi, {}) end end
    local function watch(on)
        vs[truck._addr].watch = on
        debug.setupvalue(top, wi, 2)
    end
    local old_expected = expected
    expected = function(o)
        if o == truck or o == part then return 1 end   -- the driver's
        return old_expected(o)
    end
    plan = nil
    watch(true)
    local r = run("D. vehicle watched, after", 8)
    show(r)
    check(r.wrong == 0, "D. a watched vehicle and its part answer for the driver, the rest unchanged")
    check(r.idle > r.n * 0.6, "D. other objects keep the shortcut while a vehicle is watched")
    check(ctx.busy["vehicles:a watched vehicle"] and ctx.busy["vehicles:part of a watched vehicle"],
        "D. the vehicle and its part are counted busy")
    -- the part never takes the shortcut: its calls all went the full way
    local truck_idle = 0
    -- (a part cached "nobody's" before the vehicle got watched answers at once)
    watch(false)
    reset_second()
    local function pass()
        for i = 1, #plan do plan[i].ip:set(0) end
        for i = 1, #plan do local c = plan[i]; c.h(gp, c.wp, c.ip) end
    end
    pass()
    -- the vehicles' own cache is dropped in the middle of the second (its own
    -- period, not the ctx's): an object whose outer is unknown must NOT be idle
    if oi then debug.setupvalue(idle_fn, oi, {}) end
    watch(true)
    pass()
    local bad = 0
    for i = 1, #plan do
        local c = plan[i]
        if (c.o == part or c.o == truck) and c.ip.value() ~= 1 then bad = bad + 1 end
    end
    check(bad == 0, "D. the vehicle gets watched mid-second: its part answers for the driver at once (" .. bad .. " wrong)")
    watch(false)
    expected = old_expected
end
-- the debug lines
T = T + 10
local line = ctx.perf_text(10)
print("  [PERF] ctx: " .. tostring(line))
check(line and line:find("slow path because", 1, true) and line:find("world:", 1, true)
    and line:find("first call of the object", 1, true) and line:find("remote player's object", 1, true),
    "[PERF] names what still forces the slow path")
check(rA1.eng < rA0.eng - 0.5, string.format("fewer engine reads per call: %.2f -> %.2f", rA0.eng, rA1.eng))

print(string.format("ctx host chain: %d passed, %d failed", passed, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.remove(ini)
