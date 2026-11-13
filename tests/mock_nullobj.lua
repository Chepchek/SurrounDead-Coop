-- Mock test: a null UObject (a hook parameter / GetOwner / property with no
-- object) fed to the hooks and helpers that ask an object for its class or
-- outer. Host crash of 2026-11-13 17:36: ApplyDamage of a HeavyBleed tick
-- (MedicalComponent -> Svr_Damage) passes DamageCauser None; sdc_ffire's
-- pre-hook took it for an object (`== nil` does not catch UE4SS's null
-- object) and sdc_ctx's class lookup called GetClass on it: UE4SS 3.0.1
-- reads address 0x10 there and the game dies, pcall cannot catch it.
--
-- The fake null object behaves as UE4SS's: IsValid false, GetAddress 0,
-- IsA / Has*Flags false, GetFullName nil, any other member an empty object;
-- GetClass, GetFName, GetOuter, IsClass, IsAnyClass are a CRASH: recorded
-- (and raised, so the code under test goes on as it would not in the game).
-- Every section checks that no crash was recorded. Real sdc_ue, sdc_ctx,
-- sdc_ffire, sdc_ai_spawnnear, sdc_dialogue, sdc_quests, sdc_vehicles,
-- sdc_widgets; stub log / config / net / sdc_ai / sdc_consume.
--   1. sdc_ctx.class_name (the root): "" for the null object
--   2. sdc_ffire ApplyDamage pre: the crash's call (victim the host's
--      character, causer None), a None victim, a teammate's hit still dropped
--   3. sdc_ffire SetBurning post: a None character; an untracked Molotov
--      whose GetOwner is None (judge_host -> is_player)
--  3b. the same with friendly_fire = true (the stopgap): the ApplyDamage
--      entry is gated off, the SetBurning one still runs and must not crash
--   4. sdc_ffire's own check with an unguarded class lookup behind it
--   5. sdc_ai_spawnnear sphere-query pre-hook with a None WorldContextObject
--   6. sdc_dialogue: GetNarrativeComponent with a None target (host, client),
--      a trader spawner's spawn with a None context (client), npc_kind(None)
--   7. sdc_quests: the reward-XP event's quest (quest_of) of a None event
--   8. sdc_vehicles: the player-0 resolver with a None context (a car watched)
--   9. sdc_widgets.clone_button with a None source button
-- usage: lua mock_nullobj.lua <scripts dir>
local SCRIPTS = arg[1] or "."
package.path = SCRIPTS .. "/?.lua;" .. package.path

local CLK = 100.0
os.clock = function() return CLK end
local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
print = function() end

-- ------------------------------------------------------------ the null object
local crashes = {}
local function crash_count() return #crashes end
local function crashed_since(n)
    local t = {}
    for i = n + 1, #crashes do t[#t + 1] = crashes[i] end
    return table.concat(t, ", ")
end
local CRASHY = { GetClass = true, GetFName = true, GetOuter = true, IsClass = true, IsAnyClass = true }
local Null = {}
local NULL = setmetatable({}, Null)
Null.__index = function(_, k)
    if CRASHY[k] then
        return function()
            crashes[#crashes + 1] = k .. " " .. (debug.traceback("", 2):match("\n%s*([^\n]*sdc_[%w_]+%.lua:%d+)") or "?")
            error("GAME CRASH: " .. k .. " on a null object (reads address 0x10)")
        end
    end
    if k == "IsValid" then return function() return false end end
    if k == "GetAddress" then return function() return 0 end end
    if k == "GetFullName" then return function() return nil end end
    if k == "IsA" or k == "HasAnyFlags" or k == "HasAllFlags" then return function() return false end end
    if k == "GetWorld" or k == "GetPropertyValue" then return function() return NULL end end
    return NULL   -- any other member: an empty object (calling it is a Lua error)
end
Null.__tostring = function() return "UObject: 0000000000000000" end

-- ------------------------------------------------------------ live objects
local Obj = {}
local outer_calls = 0
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
local next_addr = 4096
local registry = {}
local classes = {}
local function class_obj(name)
    local c = classes[name]
    if not c then
        next_addr = next_addr + 16
        c = setmetatable({ _cls = "Class", _name = name, _p = {}, _m = {}, _addr = next_addr }, Obj)
        classes[name] = c
    end
    return c
end
function Obj:IsValid() return true end
function Obj:GetAddress() return self._addr end
function Obj:GetClass() return class_obj(self._cls) end
function Obj:GetFName() local s = self._name; return { ToString = function() return s end } end
function Obj:GetFullName() return self._cls .. " /Game/Levels/X.X:PersistentLevel." .. self._name end
function Obj:GetOuter() outer_calls = outer_calls + 1; return self._outer or NULL end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:IsA() return false end
local function new(cls, name, props, methods, outer)
    next_addr = next_addr + 16
    local o = setmetatable({ _cls = cls, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _outer = outer }, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
local function at(x, y) return function() return { X = x, Y = y, Z = 100 } end end

-- a hook parameter (RemoteUnrealParam: :get() / :set())
local function param(v)
    local p = {}
    function p.get() return v end
    function p.set(_, x) v = x end
    function p.value() return v end
    return p
end

-- ------------------------------------------------------------ the world
local level = new("Level", "PersistentLevel")
local lp = new("LocalPlayer", "LocalPlayer_0")
local conn = new("IpConnection", "IpConnection_0")
local host_pc = new("BP_PlayerController_C", "BP_PlayerController_C_1", { Player = lp }, {}, level)
local host_pawn = new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_1", { Controller = host_pc },
    { K2_GetActorLocation = at(0, 0) }, level)
host_pc._p.Pawn = host_pawn
local rpc = new("BP_PlayerController_C", "BP_PlayerController_C_2", { Player = conn, NetConnection = conn }, {}, level)
local stopped = 0
local rpawn = new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2", { Controller = rpc },
    { K2_GetActorLocation = at(300, 0), StopBurning = function() stopped = stopped + 1 end }, level)
rpc._p.Pawn = rpawn
-- a Molotov sdc_throw did not track (the host's own throw: no Owner)
new("BP_Throwable_Molotov_C", "BP_Throwable_Molotov_C_1", {},
    { K2_GetActorLocation = at(150, 0), GetOwner = function() return NULL end }, level)
local DTYPE = new("Class", "DamageType")
local BODY = new("BlueprintGeneratedClass", "Damage_Body_C")
local controllers = { host_pc, rpc }

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = { pre = pre, post = post }; return 1, 2 end
function FindAllOf(cls)
    if cls == "PlayerController" then return controllers end
    return registry[cls] or {}
end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
local found = {}
function StaticFindObject(path)
    -- every function / class / default object "exists" (a plain object)
    local o = found[path]
    if not o then o = new("Object", (path:match("([%w_]+)$") or path)); found[path] = o end
    return o
end
function LoadAsset() end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay() return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function RegisterConsoleCommandHandler() end
function RegisterKeyBind() end
FName = function(s) return s end
FText = function(s) return s end

-- ------------------------------------------------------------ stub modules
local logs = {}
local function noop() end
package.loaded["sdc_log"] = setmetatable({ debug_enabled = false, probes_enabled = false, TEXT = {} }, { __index = function(_, k)
    return function(a, ...)
        local fmt, args = a, { ... }
        if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
        if type(fmt) ~= "string" then return nil end
        local ok, s = pcall(string.format, fmt, table.unpack(args))
        logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
        if k == "tr" then return fmt end
        return nil
    end
end })
local function logged(pat)
    for _, l in ipairs(logs) do if l:find(pat, 1, true) then return l end end
    return nil
end
local CFG = { friendly_fire = false, quest_own = true, trade_host_traders = true }
package.loaded["sdc_config"] = setmetatable({ get = function(k) return CFG[k] end }, { __index = function() return noop end })
package.loaded["sdc_net"] = setmetatable({}, { __index = function() return noop end })
local ext = {}   -- [hook name] = spec (gate: sdc_ai runs fn only while it says true)
package.loaded["sdc_ai"] = {
    hook_external = function(spec) ext[spec.name] = spec; return { installed = true, spec = spec } end,
    install_now = noop,
}
local ue = require("sdc_ue")
package.loaded["sdc_consume"] = { param = ue.param, guid_str = function() return "" end }

local S = { role = "host", remote_pcs = { rpc }, remote = {} }
S.remote[ue.name(rpc)] = { name = "Ann", pc = rpc }

-- ------------------------------------------------------------ 1. sdc_ctx
local ctx = require("sdc_ctx")
local n0 = crash_count()
check(ctx.class_name(NULL) == "", "1 ctx.class_name(None) = \"\"")
check(ctx.class_name(host_pawn) == "BP_PlayerCharacter_C", "1 ctx.class_name of a live character still answers")
check(ctx.class_name(host_pawn) == "BP_PlayerCharacter_C", "1 ... and again from its class cache")
check(crash_count() == n0, "1 no GetClass on the null object " .. crashed_since(n0))

-- ------------------------------------------------------------ 2. ffire ApplyDamage
local ff = require("sdc_ffire")
ff.install(S)
check(ue.local_pawn() == host_pawn, "2 the host's character found (stub world)")
n0 = crash_count()
-- the crash: HeavyBleed's Svr_Damage -> ApplyDamage(host, 4.28, None, None, DamageType)
local dmg = param(4.2801)
local ok, err = pcall(ff._on_damage, nil, param(host_pawn), dmg, param(NULL), param(NULL), param(DTYPE))
check(ok, "2 bleeding tick (causer None): the hook ran " .. tostring(err))
check(crash_count() == n0, "2 bleeding tick (causer None): no crash " .. crashed_since(n0))
check(dmg.value() == 4.2801 and ff.stats.blocked == 0, "2 bleeding tick: damage untouched (world damage)")
-- a None victim (a Blueprint's ApplyDamage(None, ...))
n0 = crash_count()
local dmg2 = param(10.0)
ok, err = pcall(ff._on_damage, nil, param(NULL), dmg2, param(rpc), param(rpawn), param(BODY))
check(ok and crash_count() == n0, "2 victim None: no crash " .. crashed_since(n0) .. tostring(err or ""))
check(dmg2.value() == 10.0, "2 victim None: damage untouched")
-- still works: a teammate's hit on the host is dropped (friendly fire off)
n0 = crash_count()
local dmg3 = param(30.0)
ok, err = pcall(ff._on_damage, nil, param(host_pawn), dmg3, param(rpc), param(rpawn), param(BODY))
check(ok and dmg3.value() == 0 and ff.stats.blocked == 1, "2 a teammate's hit on the host still dropped " .. tostring(err or ""))
check(logged("ffire: 30.0 damage to host from Ann dropped") ~= nil, "2 ... and logged")
check(crash_count() == n0, "2 no crash on live objects")

-- ------------------------------------------------------------ 3. ffire SetBurning
n0 = crash_count()
ok, err = pcall(ff._on_burning, param(NULL), param(true))
check(ok and crash_count() == n0, "3 SetBurning of a None character: no crash " .. crashed_since(n0) .. tostring(err or ""))
-- the client's character next to an untracked Molotov without an Owner:
-- the thrower is the host (GetOwner None must not be asked for its class)
n0 = crash_count()
ok, err = pcall(ff._on_burning, param(rpawn), param(true))
check(ok, "3 untracked Molotov (Owner None): the hook ran " .. tostring(err))
check(crash_count() == n0, "3 untracked Molotov (Owner None): no crash " .. crashed_since(n0))
check(stopped == 1 and ff.stats.untracked == 1, "3 ... judged the host's fire and put out on the client's character")

-- ------------------------------------------------------------ 3b. friendly_fire = true
-- The stopgap until the fixed build is in the game: friendly_fire on gates
-- the ApplyDamage entry off (bleeding / falls / burns no longer reach it),
-- but the SetBurning entry still runs while a client is connected (it
-- remembers whose fire it was), so an untracked Molotov's None Owner still
-- reaches is_player there: only the source fix covers that one.
CFG.friendly_fire = true
local gd, gb = ext["ffire.damage"], ext["ffire.burn"]
check(gd and gd.gate and gd.gate() == false, "3b friendly_fire on: the ApplyDamage entry is gated off")
check(gb and gb.gate and gb.gate() == true, "3b friendly_fire on: the SetBurning entry still runs (client connected)")
n0 = crash_count()
ok, err = pcall(ff._on_burning, param(rpawn), param(true))
check(ok and crash_count() == n0, "3b friendly_fire on, untracked Molotov (Owner None): no crash " .. crashed_since(n0) .. tostring(err or ""))
check(stopped == 1, "3b ... and the burn is not put out (friendly fire on)")
CFG.friendly_fire = false

-- ------------------------------------------------------------ 4. ffire's own check
-- the same ffire behind a class lookup with no check of its own (as sdc_ctx's was)
package.loaded["sdc_ffire"] = nil
local real_ctx = package.loaded["sdc_ctx"]
package.loaded["sdc_ctx"] = setmetatable({
    class_name = function(o) return o:GetClass():GetFName():ToString() end,
}, { __index = real_ctx })
local ff2 = require("sdc_ffire")
package.loaded["sdc_ctx"] = real_ctx
ff2.install(S)
n0 = crash_count()
local dmg4 = param(4.2801)
pcall(ff2._on_damage, nil, param(host_pawn), dmg4, param(NULL), param(NULL), param(DTYPE))
check(crash_count() == n0, "4 ffire checks the causer itself (unguarded class lookup behind it) " .. crashed_since(n0))
pcall(ff2._on_damage, nil, param(NULL), param(1.0), param(NULL), param(rpawn), param(BODY))
check(crash_count() == n0, "4 ... and the victim " .. crashed_since(n0))
local dmg5 = param(30.0)
pcall(ff2._on_damage, nil, param(host_pawn), dmg5, param(rpc), param(rpawn), param(BODY))
check(dmg5.value() == 0, "4 ... and still drops a teammate's hit")

-- ------------------------------------------------------------ 5. spawnnear
local sn = require("sdc_ai_spawnnear")
local core = { host = { active = true }, S = S, hook = noop, on = function() return true end, line = function() return nil end }
sn.init(core)
n0 = crash_count()
ok, err = pcall(sn._t.on_query, nil, param(NULL), param({ X = 1, Y = 2, Z = 3 }))
check(ok and crash_count() == n0, "5 sphere query with a None WorldContextObject: no crash " .. crashed_since(n0) .. tostring(err or ""))
check(sn.stats.queries == 0, "5 ... and nothing noted")
local spawner = new("BP_AISpawner_Master_C", "BP_AISpawner_Master_C_1", {}, {}, level)
ok, err = pcall(sn._t.on_query, nil, param(spawner), param({ X = 1, Y = 2, Z = 3 }))
check(ok and sn.stats.queries == 1, "5 a spawner's query still noted " .. tostring(err or ""))

-- ------------------------------------------------------------ 6. dialogue
local dlg = require("sdc_dialogue")
dlg.init(S)
dlg.install()
local GNC = "/Script/Narrative.NarrativeFunctionLibrary:GetNarrativeComponent"
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
check(hooks[GNC] and hooks[GNC].pre, "6 GetNarrativeComponent hook registered")
check(hooks[SPAWN] and hooks[SPAWN].pre, "6 the spawn hook registered (shared engine hook)")
n0 = crash_count()
check(dlg.npc_kind(NULL) == nil and crash_count() == n0, "6 npc_kind(None) = nil, no crash " .. crashed_since(n0))
S.role = "host"
ok, err = pcall(hooks[GNC].pre, param(NULL), param(NULL))
check(ok and crash_count() == n0, "6 host: GetNarrativeComponent(None): no crash " .. crashed_since(n0) .. tostring(err or ""))
S.role = "client"
ok, err = pcall(hooks[GNC].pre, param(NULL), param(NULL))
check(ok and crash_count() == n0, "6 client: GetNarrativeComponent(None): no crash " .. crashed_since(n0) .. tostring(err or ""))
ok, err = pcall(hooks[SPAWN].pre, param(NULL), param(NULL), param(DTYPE))
check(ok and crash_count() == n0, "6 client: a spawn with a None WorldContextObject: no crash " .. crashed_since(n0) .. tostring(err or ""))
check(dlg.npc_kind(host_pawn) == nil and crash_count() == n0, "6 npc_kind of a live non-NPC: nil")
check(logged("dlg.gnc") == nil and logged("hook dlg.trader-spawn") == nil, "6 no hook errors logged")

-- ------------------------------------------------------------ 7. quests
local quests = require("sdc_quests")
quests.init(S)
S.role = "client"
pcall(quests.client_tick, CLK, host_pc, nil)
local REWARD = "/Game/Quests/Events/Reward/Quest_Event_RewardPlayerXP.Quest_Event_RewardPlayerXP_C:ExecuteEvent"
check(hooks[REWARD] and hooks[REWARD].pre, "7 the reward-XP event hook registered")
n0 = crash_count()
if hooks[REWARD] then
    ok, err = pcall(hooks[REWARD].pre, param(NULL), param(NULL), param(NULL))
    check(ok and crash_count() == n0, "7 reward event None: its quest asked without a crash " .. crashed_since(n0) .. tostring(err or ""))
end

-- ------------------------------------------------------------ 8. vehicles
S.role = "host"
local veh = require("sdc_vehicles")
local function upvalue(fn, name)
    for i = 1, 255 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then return nil end
        if n == name then return v, i end
    end
end
local my_resolver = upvalue(veh._t.resolve, "my_resolver")
check(type(my_resolver) == "function", "8 vehicles' resolver found")
if my_resolver then
    local _, wi = upvalue(my_resolver, "watch_n")
    local _, si = upvalue(my_resolver, "S")
    debug.setupvalue(my_resolver, wi, 1)     -- a car is watched (a client drives it)
    debug.setupvalue(my_resolver, si, S)
    n0 = crash_count()
    ok, err = pcall(veh._t.resolve, NULL)
    check(ok and crash_count() == n0, "8 player-0 call with a None context: no crash " .. crashed_since(n0) .. tostring(err or ""))
    check(logged("vehicles: resolver") == nil, "8 ... no resolver error logged")
    local before = outer_calls
    local thing = new("BP_Crate_C", "BP_Crate_C_1", {}, {}, level)
    ok, err = pcall(veh._t.resolve, thing)
    check(ok and outer_calls == before + 1, "8 a live context's outer still looked up " .. tostring(err or ""))
end

-- ------------------------------------------------------------ 9. widgets
local W = require("sdc_widgets")
n0 = crash_count()
ok, err = pcall(W.clone_button, NULL, "Co-op", noop)
check(not ok and crash_count() == n0, "9 clone_button(None): an error, no crash " .. crashed_since(n0))
check(tostring(err):find("source button is gone", 1, true) ~= nil, "9 ... saying why: " .. tostring(err))

check(#crashes == 0, "no crash anywhere: " .. table.concat(crashes, "; "))
io.write(string.format("mock_nullobj: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
