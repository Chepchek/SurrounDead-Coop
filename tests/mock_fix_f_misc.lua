-- Group F fixes (critic 2026-11-13, AI core / ue / perf / diag / main), against
-- the real modules on fake UE objects:
--   A3  sdc_ai_fx: the relayed-asset cache keyed by address is checked by name
--       and dropped with the world / every 5 min
--   A4  sdc_diag: [SNAP] held= is the Jig helper's ActiveWeapon slot
--   A5  sdc_perf: a shared native hook's subscriber keeps its key in [PERF]
--   A6  sdc_perf.peek (sdcoop_status) leaves the [PERF] window running
--   B3  sdc_shake subscribes nothing with explosion_shake_zone = false
--   B4  sdc_ownsounds subscribes only what is on (guard / relay list)
--   C1-C4, C7 (static): sdc_movedbg gone, no experiment loop / movement
--       monitor / loop switches / forever dump-check timer in main.lua,
--       gaptrace started only when on; sdc_ue helpers
-- usage: lua mock_fix_f_misc.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local LOG = {}
print = function(s) LOG[#LOG + 1] = tostring(s); if os.getenv("MOCK_VERBOSE") then io.write(tostring(s)) end end
local function say(s) io.write(s .. "\n") end
local function logged(pat)
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end
    return nil
end

-- ---------------------------------------------------------------- fake objects
local W = { objects = {}, paths = {}, hooks = {}, out = {} }
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    return rawget(t, "_m")[k]
end
local next_addr = 8192
local function name_obj(s) return { ToString = function() return s end } end
local function new(chain, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true }, Obj)
    W.objects[#W.objects + 1] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass()
    local chain = self._chain
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end

local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end
FName = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    W.hooks[path] = W.hooks[path] or {}
    table.insert(W.hooks[path], { pre = a, post = b })
    return 1, 2
end
StaticFindObject = function(path)
    local o = W.paths[path]
    if o and o._valid then return o end
    return nil
end
local function derives(o, cls) for _, c in ipairs(o._chain) do if c == cls then return true end end return false end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(W.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function() return nil end
ExecuteInGameThread = function(fn) fn() end
ExecuteInGameThreadWithDelay = function() return 1 end
LoopInGameThreadWithDelay = function() return 1 end

W.paths["/Script/Engine.Default__KismetSystemLibrary"] = new({ "KismetSystemLibrary" }, "KSL", {}, {
    IsStandalone = function() return false end, IsServer = function() return true end })

local cfg = require("sdc_config")
cfg.values = {}
local perf = require("sdc_perf")
local ue = require("sdc_ue")

local function make_pc(local_player, loc)
    local helper = new({ "BP_JigHelperComp_C" }, "BP_JigHelperComp_" .. next_addr, {},
        { ActiveWeapon = { TagName = FName("Jig.PlayerSlot.Primary") } })
    local pawn = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_" .. next_addr,
        { _loc = loc, BP_JigHelperComp = helper, ["PlayerDead?"] = false })
    local player = new({ local_player and "LocalPlayer" or "NetConnection" }, "Player_" .. next_addr)
    local pc = new({ "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. next_addr,
        { Pawn = pawn, Player = player, NetConnection = (not local_player) and player or nil }, {
            ClientMessage = function(self, msg) W.out[#W.out + 1] = { pc = self, msg = msg } end,
        })
    return pc, pawn
end
local host_pc, host_pawn = make_pc(true, { X = 0, Y = 0, Z = 0 })
local rpc = make_pc(false, { X = 500, Y = 0, Z = 0 })

-- ============================================================== sdc_ue
say("== sdc_ue: helpers, debug switches gone")
check(ue.disabled_loops == nil and ue.loop_on == nil, "C3: no experiment loop switches (disabled_loops / loop_on)")
check(ue.watch_state == nil, "C7: watch_state (unused) gone")
check(ue.param(param(7)) == 7 and ue.param(nil) == nil and ue.param({}) == nil, "param")
local vv = ue.vec({ X = 1, Y = 2, Z = 3 })
check(vv and vv.X == 1 and vv.Z == 3 and ue.vec({ X = 1 }) == nil and ue.vec(nil) == nil, "vec")
check(ue.elem(param("a")) == "a" and ue.elem("b") == "b", "elem")
local r, waits = {}, {}
for _ = 1, 7 do waits[#waits + 1] = ue.backoff(r, 0, 2, 30) end
check(table.concat(waits, ",") == "2,4,8,16,30,30,30" and r.next_try == 30, "C10: backoff 2 s doubling up to 30 s")

-- ============================================================== sdc_perf
say("== sdc_perf: names, read-only status")
local ai_path = "/Script/Engine.PlayerController:ClientRepObjRef#ai.PlayerController:ClientRepObjRef"
local npc_path = "/Script/Engine.PlayerController:ClientRepObjRef#npc.PlayerController:ClientRepObjRef"
local ra, rn = perf.record(ai_path), perf.record(npc_path)
check(ra.name == "PlayerController:ClientRepObjRef#ai.PlayerController:ClientRepObjRef", "A5: ai subscriber keeps its key: " .. ra.name)
check(rn.name ~= ra.name and rn.name:find("#npc.", 1, true) ~= nil, "A5: npc subscriber told apart: " .. rn.name)
check(perf.record("/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:MC_AttachClothing").name
    == "BP_PlayerCharacter:MC_AttachClothing", "A5: plain Blueprint hook name unchanged")
check(perf.record("/Script/Engine.GameplayStatics:PlaySoundAtLocation#shake").name == "GameplayStatics:PlaySoundAtLocation#shake",
    "A5: simple key unchanged")
perf.report("window", {})
advance(10)
ra.calls, ra.ms = ra.calls + 50, ra.ms + 20
local p1 = perf.peek("status", {})
local p2 = perf.peek("status", {})
check(p1:find("ai.PlayerController:ClientRepObjRef 5/s", 1, true) ~= nil, "A6: status shows the running window: " .. p1:sub(1, 120))
check(p2:find("ai.PlayerController:ClientRepObjRef 5/s", 1, true) ~= nil, "A6: a second status still shows it (window not restarted)")
local nlog = #LOG
local w1 = perf.report("window", {})
check(w1:find("ai.PlayerController:ClientRepObjRef 5/s", 1, true) ~= nil, "A6: the [PERF] window still has the calls the status saw")
check(#LOG > nlog, "A6: [PERF] logged")
advance(10)
local w2 = perf.report("window", {})
check(w2:find("ai.PlayerController:ClientRepObjRef", 1, true) == nil, "A6: the next window starts after the report")

-- ============================================================== sdc_shake
say("== sdc_shake: hooks only with explosion_shake_zone")
local SHAKE_FN = "/Script/Engine.PlayerController:ClientStartCameraShake"
local SND = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local SPAWN = "/Script/Engine.GameplayStatics:SpawnSoundAtLocation"
local S = { role = "host", remote_pcs = { rpc } }
local shake = require("sdc_shake")
cfg.values.explosion_shake_zone = false
shake.install(S)
shake.tick(); shake.tick()
check(ue.natives[SHAKE_FN] == nil and ue.natives[SND] == nil, "B3: explosion_shake_zone=false: nothing subscribed")
cfg.values.explosion_shake_zone = true
shake.tick()
check(ue.natives[SHAKE_FN] ~= nil and ue.natives[SND] ~= nil and ue.natives[SPAWN] ~= nil, "B3: turned on: subscribed")
local okc = pcall(W.hooks[SHAKE_FN][1].pre, param(nil), param(nil), param(1.0))
check(okc, "C8: shake subscriber survives nil parameters (sdc_ue's pcall)")

-- ============================================================== sdc_ownsounds
say("== sdc_ownsounds: only what is on")
local snd = require("sdc_ownsounds")
snd.init(S)
local function keys(path)
    local h = ue.natives[path]
    local out = {}
    for _, s in ipairs(h and h.subs or {}) do if s.key:find("^ownsounds") then out[#out + 1] = s.key end end
    return table.concat(out, ",")
end
cfg.values.sound_range_guard, cfg.values.relay_sounds = false, ""
snd.tick()
check(keys(SND) == "" and keys(SPAWN) == "", "B4: guard off, no relayed sound: nothing subscribed")
cfg.values.relay_sounds = "S_EmptyFire_Cue"
snd.tick()
check(keys(SND) == "ownsounds.relay" and keys(SPAWN) == "", "B4: a relayed sound: the relay only")
cfg.values.sound_range_guard = true
snd.tick()
check(keys(SND) == "ownsounds.relay,ownsounds.guard" and keys(SPAWN) == "ownsounds.guard", "B4: guard on: both functions")
check(logged("sound guard (sound_range_guard=") ~= nil, "relay description logged once")
snd.tick()
check(keys(SND) == "ownsounds.relay,ownsounds.guard", "subscribed once")

-- ============================================================== sdc_ai_fx
say("== sdc_ai_fx: relayed assets by address, checked by name")
local fx = require("sdc_ai_fx")
local specs = {}
local core
core = {
    S = S, host = { active = true, viewers = {} },
    hook = function(spec) specs[spec.name] = spec end,
    viewers_near = function() return core.host.viewers end,
    first = function() return false end,
    is_zombie = function(o) return o._zombie == true end,
}
fx.init(core)
core.host.viewers = { { pc = rpc, key = "rpc", X = 500, Y = 0, Z = 0 } }
local z = new({ "BP_Zombie_Grenadier_C" }, "BP_Zombie_Grenadier_C_1", { Role = 3, _loc = { X = 0, Y = 0, Z = 0 } })
z._zombie = true
local function cue(name)
    local a = new({ "SoundCue" }, name, { MaxDistance = 12600 })
    a._full = "SoundCue /Game/Audio/" .. name .. "." .. name
    return a
end
local function play(s)
    local n = #W.out
    specs["fx.sound"].fn(param(nil), param(z), param(s), param({ X = 1, Y = 2, Z = 3 }), param({ Pitch = 0, Yaw = 0, Roll = 0 }),
        param(1.0), param(1.0))
    return #W.out - n
end
local beep = cue("S_Beep_Cue")
check(play(beep) == 1, "a grenadier beep relayed")
-- the address of the beep cue now holds another sound (freed, taken again)
beep._name = "Wood_Hit_Cue"
beep._full = "SoundCue /Game/Audio/Wood_Hit_Cue.Wood_Hit_Cue"
check(play(beep) == 0, "A3: another asset at a relayed address: not relayed")
local other = cue("Wind_Cue")
check(play(other) == 0, "not a relayed asset")
other._name = "S_Beep_Cue"
other._full = "SoundCue /Game/Audio/S_Beep_Cue.S_Beep_Cue"
fx.reset()
check(play(other) == 1, "A3: the cache goes with the world: a relayed asset at a known address is relayed")
other._name = "Wind_Cue"
play(other)
other._name = "S_Beep_Cue"
advance(301)
fx.host_tick(T)
check(play(other) == 1, "A3: the cache is dropped every 5 min too")

-- ============================================================== sdc_diag
say("== sdc_diag: held item")
local diag = require("sdc_diag")
diag.init("test")
diag.tick({ role = "host", remote = {}, in_menu = false, map = "PL" })
local own = logged("[SNAP] own ")
check(own ~= nil and own:find("held=Primary", 1, true) ~= nil, "A4: held= the active slot: " .. tostring(own and own:match("held=%S+")))

-- ============================================================== static: main.lua, files
say("== main.lua / files")
local function read(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end
local main = read(SCRIPTS .. "/main.lua") or ""
check(read(SCRIPTS .. "/sdc_movedbg.lua") == nil and not main:find("movedbg", 1, true), "C1: sdc_movedbg removed with its wiring")
check(not main:find("experiment_tick", 1, true) and not main:find("movement_monitor_frame", 1, true)
    and not main:find("loop_on", 1, true), "C3: no experiment loop, movement monitor call or loop switches in main.lua")
local _, n_gap = main:gsub('ue%.every%("gaptrace"', "")
check(n_gap == 1 and main:find("local function start_gaptrace", 1, true) ~= nil
    and main:find('cfg.get("gap_trace") ~= true', 1, true) ~= nil, "C2: the gaptrace tick starts only with gap_trace on")
check(not main:find('ue.every("dump-check"', 1, true), "C4: no dump-check timer running forever")
check(main:find("perf.peek(", 1, true) ~= nil and not main:find('perf.report("status"', 1, true), "A6: sdcoop_status reads [PERF] read-only")
check(main:find("world_reset_hooks.ownsounds", 1, true) ~= nil, "C7: sdc_ownsounds.reset runs on a world change")

io.write(string.format("mock_fix_f_misc: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
