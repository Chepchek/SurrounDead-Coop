-- Mock harness: sdc_ctx's player-0 hook fast path and its caches (0.6.75 perf
-- work), sdc_world's resolver fast prefix, sdc_perf's bench switch / hook
-- kinds and sdcoop_bench (sdc_bench). Real modules against fake UE objects.
-- usage: lua mock_ctx_fastpath.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
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

-- ------------------------------------------------------------ 1. registration
print("== 1. hooks")
ctx.tick({ rpc })
check(ctx.active, "remote player connected: redirection active")
for _, f in ipairs({ "GetPlayerCharacter", "GetPlayerPawn", "GetPlayerController", "GetPlayerCameraManager" }) do
    check(hooks["/Script/Engine.GameplayStatics:" .. f] ~= nil, f .. " hooked")
end
check(perf.reg.native == 4 and perf.reg.bp == 0, "the four natives counted as native hooks")

-- ------------------------------------------------------------ 2. fast path, cache
print("== 2. fast path and the per-second cache")
do
    local h = hooks["/Script/Engine.GameplayStatics:GetPlayerController"]
    ctx.active = false
    local wp = param(hud)
    h.pre(param(gps), wp, param(0))
    check(wp.n == 0, "inactive: the context object is not even read")
    ctx.active = true
    local idx, wp2 = call("GetPlayerController", hud, 1)
    check(idx == 1 and wp2.n == 0, "PlayerIndex 1: untouched, context not read")
    check(ctx.pstats.idx == 1, "counted as index not 0")
end
do
    local m0 = ctx.pstats.miss
    local idx = call("GetPlayerController", hud)
    check(idx == 0, "host's HUD widget: player 0 stays the host")
    check(ctx.pstats.miss == m0 + 1, "first call: one player_for miss")
    check(calls.owner_missing == 1, "the widget's missing GetOwner was tried once")
    local before = { o = calls.GetOuter, c = calls.GetClass, w = calls.GetOwner, p = calls.GetProp, n = calls.owner_missing }
    for _ = 1, 50 do call("GetPlayerController", hud) end
    check(calls.GetOuter == before.o and calls.GetClass == before.c and calls.GetOwner == before.w
        and calls.GetProp == before.p and calls.owner_missing == before.n,
        "50 more calls the same second: no engine object touched besides the arguments")
    check(ctx.pstats.miss == m0 + 1, "no more misses")
    -- another widget of the same class: its class is known to have no GetOwner
    call("GetPlayerController", hud2)
    check(calls.owner_missing == 1, "same class: GetOwner not tried again (no error per miss)")
    check(ctx.pstats.miss == m0 + 2, "the second widget is its own miss")
    T = T + 1
    ctx.tick({ rpc })
    call("GetPlayerController", hud)
    check(ctx.pstats.miss == m0 + 3, "after the 1 s tick the cache is rebuilt (as before)")
    check(calls.owner_missing == 1, "the class memo survives the tick")
end

-- ------------------------------------------------------------ 3. remote contexts
print("== 3. a remote player's objects still resolve")
do
    local n0 = calls.NumPCs
    local idx = call("GetPlayerController", rstamina)
    check(idx == 1, "remote player's StaminaComponent -> its controller's index (1)")
    idx = call("GetPlayerController", rstamina)
    check(idx == 1, "again from the cache -> index 1")
    check(calls.NumPCs == n0 + 2, "every redirect still checks the controller count (a leaving controller)")
    check(ctx.pstats.redirect >= 2, "redirects counted")
    check(call("GetPlayerCharacter", rpawn) == 1, "remote character -> 1")
    check(call("GetPlayerCharacter", rknife) == 1, "remote player's knife (owner chain) -> 1")
    check(call("GetPlayerController", rknife) == 64, "remote player's knife asking its controller -> no player (weapon fx)")
    check(ctx.pstats.quiet >= 1, "weapon quiet counted")
    check(call("GetPlayerCharacter", host_pawn) == 0, "host's own character -> 0")
    -- a controller leaves: indices shift, seen at once (no per-frame cache)
    local third = new("BP_PlayerController_C", "Helper", {}, { outer = level, actor = true })
    controllers = { host_pc, third, rpc }
    check(call("GetPlayerController", rstamina) == 2, "a controller added before it: the new index at once")
    controllers = { host_pc, rpc }
    check(call("GetPlayerController", rstamina) == 1, "and back at once when it leaves")
end

-- ------------------------------------------------------------ 4. resolvers stay live
print("== 4. scope resolvers are asked on every call")
do
    local answer = nil
    local asked = 0
    ctx.scope_resolver = function(wco, a)
        asked = asked + 1
        check(a == wco:GetAddress(), "resolver gets the address") ; return answer
    end
    check(call("GetPlayerCharacter", crate) == 0, "crate, no opinion -> host")
    answer = rpc
    check(call("GetPlayerCharacter", crate) == 1, "same second, the resolver now names the remote player -> 1")
    answer = false
    check(call("GetPlayerController", rstamina) == 0, "resolver says 'the host's' -> even a remote object stays 0")
    answer = nil
    check(call("GetPlayerController", rstamina) == 1, "resolver silent again -> the cached remote entry")
    check(asked == 4, "asked 4 times for 4 calls")
    ctx.scope_resolver = nil
end

-- ------------------------------------------------------------ 5. cache lifetime
print("== 5. the per-second cache, bind")
do
    check(call("GetPlayerCharacter", crate) == 0, "crate without owner -> host")
    crate._owner = rpawn
    check(call("GetPlayerCharacter", crate) == 0, "owner set the same second: still the cached answer (1 s, as before)")
    T = T + 1
    ctx.tick({ rpc })
    check(call("GetPlayerCharacter", crate) == 1, "after the tick -> the remote player")
    crate._owner = nil
    local npawn = new("BP_PlayerCharacter_C", "RemoteChar2", {}, { outer = level, actor = true })
    local ncomp = new("MedicalComponent_C", "Med2", {}, { outer = npawn })
    check(call("GetPlayerController", ncomp) == 0, "a fresh character's component, not bound yet -> host")
    ctx.bind(npawn, rpc)
    check(call("GetPlayerController", ncomp) == 1, "bind() drops the cache at once -> the remote player")
end

-- ------------------------------------------------------------ 6. client mode
print("== 6. client mode")
do
    ctx.reset()
    ctx.tick_client(true)
    rpawn._m.IsLocallyControlled = function() calls.IsLocal = calls.IsLocal + 1; return false end
    host_pawn._m.IsLocallyControlled = function() calls.IsLocal = calls.IsLocal + 1; return true end
    check(call("GetPlayerController", rstamina) == 64, "another player's component -> no player")
    check(call("GetPlayerController", host_pawn) == 0, "own character -> own player")
    local n = calls.IsLocal
    for _ = 1, 20 do call("GetPlayerController", host_pawn) end
    check(calls.IsLocal == n, "own object again: the fast return (no engine call)")
    local seen = 0
    ctx.observer = function() seen = seen + 1 end
    call("GetPlayerController", host_pawn)
    check(seen == 1, "with the debug observer the call still reaches it")
    ctx.observer = nil
    ctx.reset()
    ctx.tick({ rpc })
end

-- ------------------------------------------------------------ 7. [PERF] text
print("== 7. perf text")
do
    T = T + 10
    local s = ctx.perf_text(10)
    check(type(s) == "string" and s:find("calls/s", 1, true) ~= nil, "ctx section: " .. tostring(s))
    check(ctx.perf_text(10) == nil, "an idle window gives no section")
end

-- ------------------------------------------------------------ 8. sdc_world resolver
print("== 8. sdc_world's resolver fast prefix")
do
    package.loaded["sdc_session"] = nil
    local S = { role = "host", remote = {}, remote_pcs = { rpc }, map = "X" }
    local prev_asked = 0
    ctx.scope_resolver = function() prev_asked = prev_asked + 1; return nil end
    local okw, world = pcall(require, "sdc_world")
    check(okw, "sdc_world loads (" .. tostring(okw or world) .. ")")
    if okw then
        local oki, err = pcall(world.install, S)
        check(oki, "sdc_world installs (" .. tostring(err) .. ")")
        check(ctx.scope_resolver == world.resolver, "world resolver chained in front")
        local c0 = calls.GetClass
        check(world.resolver(hud, hud:GetAddress()) == nil and prev_asked == 1, "HUD: no world kind -> the next resolver")
        local c1 = calls.GetClass
        check(c1 - c0 <= 2, "its class read once (sdc_ctx's class cache)")
        world.resolver(hud2, hud2:GetAddress())
        check(calls.GetClass - c1 == 1, "another widget of that class: one engine call (class address)")
        c1 = calls.GetClass
        for _ = 1, 10 do world.resolver(hud, hud:GetAddress()) end
        check(calls.GetClass == c1 and prev_asked == 12, "10 more calls: no class read, straight through")
        -- a container: CurrentActor is read on every call (it changes inside a frame)
        local p0 = calls.GetProp
        check(world.resolver(box, box:GetAddress()) == nil, "container nobody searches -> no opinion")
        check(calls.GetProp == p0 + 1, "CurrentActor read")
        box._p.CurrentActor = rpawn
        check(world.resolver(box, box:GetAddress()) == rpc, "the same second a remote player searches it -> that player")
        box._p.CurrentActor = host_pawn
        check(world.resolver(box, box:GetAddress()) == nil, "the host searches it -> no opinion (player 0 = host)")
        box._p.CurrentActor = NULL
        -- not the host: no world work at all
        S.role = "client"
        local c2, p2 = calls.GetClass, calls.GetProp
        world.resolver(box, box:GetAddress())
        check(calls.GetClass == c2 and calls.GetProp == p2, "not the host: straight to the next resolver")
        S.role = "host"
        -- one-argument callers (other modules, tests) still work
        check(world.resolver(hud) == nil, "resolver(obj) without an address")
        ctx.scope_resolver = nil
    end
end

-- ------------------------------------------------------------ 9. bench switch
print("== 9. perf_bench_no_bp_hooks")
do
    check(perf.hook_kind("/Script/Engine.GameplayStatics:GetPlayerController") == "native", "native by flags")
    check(perf.hook_kind("/Game/Blueprints/BP_X.BP_X_C:Foo") == "bp", "Blueprint function")
    check(perf.hook_kind("/Script/Engine.Actor:ReceiveTick") == "bp", "a C++ class's Blueprint event is a script hook (flags)")
    check(perf.bench_no_bp() == false, "switch off by default")
    local r0 = raw_regs
    local a1 = RegisterHook("/Game/Blueprints/BP_X.BP_X_C:Foo", function() end)
    check(a1 == 7 and raw_regs == r0 + 1 and perf.reg.bp == 1, "switch off: Blueprint hook registered and counted")
    -- a fresh sdc_perf reading a config.ini with the switch (the SCHEMA key through
    -- sdc_config once it exists there, else the raw line); the mod loads config.ini at startup
    local f = io.open(ini, "a"); f:write("\nperf_bench_no_bp_hooks = true\n"); f:close()
    cfg.load(ini)
    package.loaded["sdc_perf"] = nil
    local perf2 = require("sdc_perf")
    perf2.wrap_register_hook()
    check(perf2.bench_no_bp() == true, "switch read from config.ini")
    r0 = raw_regs
    local x, y = RegisterHook("/Game/Blueprints/BP_Y.BP_Y_C:Bar", function() end)
    check(x == -1 and y == -1 and raw_regs == r0, "switch on: Blueprint hook NOT registered (ids -1)")
    check(perf2.reg.skipped_bp == 1, "skipped counted")
    local n1 = RegisterHook("/Script/Engine.GameplayStatics:SpawnSound2D", function() end)
    check(n1 == 7 and raw_regs == r0 + 1, "native hook still registered")
    package.loaded["sdc_perf"] = perf
    -- sdc_ue.hook_native: also asks
    local ok1 = ue.hook_native("/Game/Blueprints/BP_Z.BP_Z_C:Baz", "t", function() end)
    check(ok1 == true, "hook_native returns ok in either case")
end

-- ------------------------------------------------------------ 10. sdcoop_bench
print("== 10. sdcoop_bench")
do
    local replies = {}
    local out = { Log = function(_, s) replies[#replies + 1] = s end }
    package.loaded["sdc_session"] = { state = { role = "host", remote = { k = { pc = rpc } } } }
    console.sdcoop_bench("sdcoop_bench 10", { "10" }, out)
    check(replies[#replies] and replies[#replies]:find("single player only", 1, true) ~= nil, "refused with a player connected")
    package.loaded["sdc_session"] = { state = { role = "host", remote = {} } }
    ctx.reset()
    console.sdcoop_bench("sdcoop_bench 10", { "10" }, out)
    check(replies[#replies]:find("starts in 5 s", 1, true) ~= nil, "accepted: " .. replies[#replies])
    run_delayed()
    check(perf.bench_frame ~= nil, "sampling on")
    for i = 1, 700 do
        delta_ms = (i % 50 == 0) and 50 or (1000 / 60)
        T = T + delta_ms / 1000
        perf.frame()
    end
    check(perf.bench_frame == nil, "window over: sampling off")
    local line = find_line("[BENCH] window")
    check(line ~= nil, "a [BENCH] line: " .. tostring(line))
    if line then
        check(line:find("p50 16.67", 1, true) ~= nil, "p50 = the normal frame")
        check(line:find("p99 50.00", 1, true) ~= nil and line:find("p95 16.67", 1, true) ~= nil, "p95 normal, p99 = the 2% spikes")
        check(line:find("world delta", 1, true) ~= nil, "from the world's delta time")
        check(line:find("Blueprint hooks on", 1, true) ~= nil, "mode on the line")
    end
    -- the floor
    console.sdcoop_bench("sdcoop_bench floor", { "floor" }, out)
    for _ = 1, 10 do run_delayed() end
    local fl = find_line("[BENCH] floor")
    check(fl ~= nil, "a floor line: " .. tostring(fl and fl:sub(1, 200)))
    check(bp_calls > 0 and ctx.active == false, "Blueprint call measured, sdc_ctx left inactive")
end

-- ------------------------------------------------------------ 11. idle shortcut
print("== 11. idle shortcut: PlayerIndex not even read")
do
    package.loaded["sdc_session"] = nil
    ctx.reset()
    ctx.tick({ rpc })
    local world = package.loaded["sdc_world"]
    local busy = false
    local function fake_respawn() if busy then return rpc end return nil end
    ctx.scope_resolver = fake_respawn
    local S = { role = "host", remote = {}, remote_pcs = { rpc }, map = "X" }
    world.install(S)
    check(ctx.scope_resolver == world.resolver, "world chained in front of a respawn-like resolver")
    call("GetPlayerController", hud)                 -- fills the caches
    local _, _, ip = call("GetPlayerController", hud)
    check(ip.n == 1, "a resolver without an idle check: the index is read as before")
    ctx.set_idle_check(fake_respawn, function() return not busy end)
    local i0 = ctx.pstats.idle
    local idx
    idx, _, ip = call("GetPlayerController", hud)
    check(idx == 0 and ip.n == 0 and ctx.pstats.idle == i0 + 1, "every resolver idle: returned before reading the index")
    for _ = 1, 20 do call("GetPlayerCameraManager", hud) end
    check(ctx.pstats.idle >= i0 + 20, "20 more calls through the shortcut")
    busy = true
    idx, _, ip = call("GetPlayerController", hud)
    check(ip.n == 1 and idx == 1, "the resolver gets busy the same second: index read, call redirected")
    busy = false
    -- a container is a world kind: never idle (CurrentActor can change any time)
    call("GetPlayerCharacter", box)
    idx, _, ip = call("GetPlayerCharacter", box)
    check(ip.n == 1 and idx == 0, "container: the full path every call")
    box._p.CurrentActor = rpawn
    check(call("GetPlayerCharacter", box) == 1, "container searched by the remote player -> 1 at once")
    box._p.CurrentActor = NULL
    -- a stand-in without an idle check switches the shortcut off; with one, on
    local function stand_in() return nil end
    ctx.stand_in = stand_in
    _, _, ip = call("GetPlayerController", hud)
    check(ip.n == 1, "stand_in without an idle check: index read")
    local dying = false
    ctx.set_idle_check(stand_in, function() return not dying end)
    _, _, ip = call("GetPlayerController", hud)
    check(ip.n == 0, "stand_in idle: shortcut")
    dying = true
    _, _, ip = call("GetPlayerController", hud)
    check(ip.n == 1, "an AI dying: index read")
    ctx.stand_in = nil
    -- the debug observer sees every call
    local seen = 0
    ctx.observer = function() seen = seen + 1 end
    _, _, ip = call("GetPlayerController", hud)
    check(ip.n == 1 and seen == 1, "observer set: the full path")
    ctx.observer = nil
    -- a remote player's own object is never idle (cache entry, not false)
    idx, _, ip = call("GetPlayerController", rstamina)
    check(idx == 1 and ip.n == 1, "remote stamina component: index read and redirected")
    -- index 1 from an idle object: untouched either way
    idx = call("GetPlayerController", hud, 1)
    check(idx == 1, "PlayerIndex 1 left alone")
    -- the host's role changes to client: world says idle (not host), still no redirect
    S.role = "client"
    _, _, ip = call("GetPlayerController", hud)
    check(ip.n == 0, "world not host: idle")
    S.role = "host"
    ctx.scope_resolver = nil
end

print(string.format("ctx fast path: %d passed, %d failed", passed, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.remove(ini)
