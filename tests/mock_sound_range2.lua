-- Mock harness: relayed sounds sent only within their own range (0.6.76 work).
--   sdc_ownsounds: range_of_path, pcs_near;
--   sdc_ai_fx: AIFX sounds within the cue's range (126 / 210 / 325 m), emitters
--     and decals within 160 m;
--   sdc_npc: boss growl / roar within 31 m + 5 m (the rock still 160 m);
--   sdc_whistle: host -> clients within 31 m + 5 m, client -> host always;
--   sdc_world: WNOISE forwarded within 31 m + 5 m.
-- Real sdc_ue / sdc_net / sdc_ctx / sdc_config / sdc_log / sdc_appearance against
-- fake UE objects.
-- usage: lua mock_sound_range2.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD
local fails = 0
local function check(cond, what)
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- fake objects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
local next_addr = 40960
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    path = path or ("/Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. name)
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _w = w }, Obj)
    o._full = chain[1] .. " " .. path
    w.objects[#w.objects + 1] = o
    w.paths[path] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:IsLocalController() return self._p._local == true end

local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v)
    return { get = function() return v end, set = function(_, nv) v = nv end, _v = function() return v end }
end
FName = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
NotifyOnNewObject = function() end
StaticFindObject = function(path)
    local o = WORLD.paths[path]
    if o and o._valid then return o end
    return nil
end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(WORLD.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function() return 1 end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local function fire(w, path, ...)
    local prev = WORLD
    WORLD = w
    for _, h in ipairs(w.hooks[path] or {}) do
        local fn = h.post or h.pre
        assert(fn(...) == nil, "hook returned a value: " .. path)
    end
    WORLD = prev
end

-- ---------------------------------------------------------------- the world (host)
local W = { objects = {}, paths = {}, hooks = {}, outbox = {}, plays = {}, noises = {} }
WORLD = W
new(W, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
    PlaySoundAtLocation = function(self, wco, s, loc) W.plays[#W.plays + 1] = { wco = wco, s = s, loc = loc } end,
}, "/Script/Engine.Default__GameplayStatics")
new(W, { "KismetSystemLibrary" }, "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return false end, IsServer = function() return true end,
}, "/Script/Engine.Default__KismetSystemLibrary")
new(W, { "AISense_Hearing" }, "Default__AISense_Hearing", {}, {
    ReportNoiseEvent = function(self, wco, loc, loud, inst, range) W.noises[#W.noises + 1] = { wco = wco, range = range } end,
}, "/Script/AIModule.Default__AISense_Hearing")
local function sound(name, path, max)
    return new(W, { "SoundCue" }, name, { MaxDistance = max }, {}, path)
end
local beep = sound("S_Beep_Cue", "/Game/Audio/Sounds/Cue/S_Beep_Cue.S_Beep_Cue", 12600.0)
local special = sound("Infected_SpecialCue", "/Game/Audio/Infected_SpecialCue.Infected_SpecialCue", 21000.0)
local boom = sound("explosion_large_06_Cue", "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue", 32500.0)
local flash = new(W, { "ParticleSystem" }, "FX_Explosion_Grenadier", {}, {}, "/Game/FX/FX_Explosion_Grenadier.FX_Explosion_Grenadier")
sound("Whistle_Cue", "/Game/Audio/Other/Whistle_Cue.Whistle_Cue", 3100.0)
sound("BreakOpen_Cue", "/Game/Audio/BreakOpen_Cue.BreakOpen_Cue", 3100.0)

local function player(name, id, x, is_local, remote)
    local ps = new(W, { "PlayerState" }, "PS_" .. name, {}, { GetPlayerId = function() return id end })
    local props = { PlayerState = ps }
    if remote then
        local conn = new(W, { "IpConnection" }, "Conn_" .. name)
        props.NetConnection, props.Player = conn, conn
    else
        props.Player = new(W, { "LocalPlayer" }, "LP_" .. name)
    end
    local pc = new(W, { "BP_PlayerController_C", "PlayerController" }, "PC_" .. name, props, {
        ClientMessage = function(self, msg) W.outbox[#W.outbox + 1] = { pc = self, msg = msg } end,
        ServerExecRPC = function(self, msg) W.outbox[#W.outbox + 1] = { pc = self, msg = msg, up = true } end,
    })
    pc._p._local = is_local
    local pawn = new(W, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. name,
        { Controller = pc, _loc = { X = x, Y = 0, Z = 0 }, PlayerState = ps, _local = is_local })
    pc._p.Pawn = pawn
    return pc, pawn
end
local h_pc, h_pawn = player("host", 256, 0, true, false)
local a_pc, a_pawn = player("near", 257, 2000, false, true)     -- 20 m from the host
local b_pc, b_pawn = player("far", 258, 20000, false, true)     -- 200 m
local function move(p, x) p._p._loc = { X = x, Y = 0, Z = 0 } end
local function sent(kind, pc)
    local n = 0
    for _, e in ipairs(W.outbox) do
        if e.msg:find("SDC1|" .. kind .. "|", 1, true) and (pc == nil or e.pc == pc) then n = n + 1 end
    end
    return n
end

local S = { role = "host", remote_pcs = { a_pc, b_pc }, remote = {} }
local own = require("sdc_ownsounds")
own.init(S)
local log = require("sdc_log")
log.debug_enabled = true

-- ================================================================ 1. helpers
print("== 1. range_of_path / pcs_near")
check(own.range_of_path("/Game/Audio/Infected_SpecialCue.Infected_SpecialCue", 1) == 21000, "range read from the cue in memory")
check(own.range_of_path("/Game/Audio/Missing.Missing", 3100) == 3100, "not in memory: the fallback from its data")
local near, far = own.pcs_near(S.remote_pcs, { X = 0, Y = 0, Z = 0 }, 3100)
check(#near == 1 and near[1] == a_pc and far == 1, "within 31 m + 5 m: the near client only")
near, far = own.pcs_near(S.remote_pcs, { X = 0, Y = 0, Z = 0 }, 3100, a_pc)
check(#near == 0 and far == 1, "except the sender")

-- ================================================================ 2. AIFX
print("== 2. sdc_ai_fx")
local hooks = {}
local core = {
    host = { active = true, viewers = {} },
    hook = function(spec) hooks[spec.name] = spec.fn end,
    is_zombie = function(o) return derives(o, "BP_MasterZombie_C") end,
    first = function() return false end,
}
function core.viewers_near(loc, range)
    local out = {}
    for _, v in ipairs(core.host.viewers) do
        local dx, dy, dz = v.X - loc.X, v.Y - loc.Y, v.Z - loc.Z
        if dx * dx + dy * dy + dz * dz <= range * range then out[#out + 1] = v end
    end
    return out
end
local fx = require("sdc_ai_fx")
fx.init(core)
local function viewers(xs)
    core.host.viewers = {}
    for i, x in ipairs(xs) do
        core.host.viewers[i] = { pc = (i == 1) and a_pc or b_pc, key = "v" .. i, X = x, Y = 0, Z = 0 }
    end
end
local zombie = new(W, { "BP_Zombie_Infected_C", "BP_MasterZombie_C" }, "Z1", { Role = 3, _loc = { X = 0, Y = 0, Z = 0 } })
local function zsound(s)
    W.outbox = {}
    hooks["fx.sound"](param(nil), param(zombie), param(s), param({ X = 0, Y = 0, Z = 0 }), param({}), param(1.0), param(1.0))
end
viewers({ 15000, 20000 })
zsound(special)
check(sent("AIFX", a_pc) == 1 and sent("AIFX", b_pc) == 1, "Infected_SpecialCue (210 m): clients at 150 m and 200 m (before: 160 m)")
viewers({ 15000, 30000 })
zsound(boom)
check(sent("AIFX", a_pc) == 1 and sent("AIFX", b_pc) == 1, "explosion (325 m): a client at 300 m gets it")
viewers({ 12000, 14000 })
zsound(beep)
check(sent("AIFX", a_pc) == 1 and sent("AIFX", b_pc) == 0, "S_Beep_Cue (126 m): 120 m yes, 140 m no (before: both)")
viewers({ 15000, 20000 })
W.outbox = {}
hooks["fx.emitter"](param(nil), param(zombie), param(flash), param({ X = 0, Y = 0, Z = 0 }), param({}), param({ X = 1, Y = 1, Z = 1 }))
check(sent("AIFX", a_pc) == 1 and sent("AIFX", b_pc) == 0, "the explosion's emitter stays within 160 m")

-- ================================================================ 3. sdc_npc
print("== 3. sdc_npc")
local npc = require("sdc_npc")
npc.install(S)
npc.tick()
advance(1.1); npc.tick()   -- the pass builds the viewers
local BOSS = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C"
local ROCK = "/Game/AI/Zombies/Boss/BP_ZombieBossRock.BP_ZombieBossRock_C"
check(W.hooks[BOSS .. ":DeathEvent"] ~= nil, "boss DeathEvent hook")
move(a_pawn, 3000)
move(b_pawn, 10000)
advance(1.1); npc.tick()
local boss = new(W, { "BP_ZombieBoss_C" }, "Boss1", { _loc = { X = 0, Y = 0, Z = 0 } })
W.outbox = {}
fire(W, BOSS .. ":DeathEvent", param(boss), param(nil))
check(sent("SND", a_pc) == 1 and sent("SND", b_pc) == 0, "death roar: 30 m yes, 100 m no (before: within 160 m)")
W.outbox = {}
fire(W, ROCK .. ":Launch", param(new(W, { "BP_ZombieBossRock_C" }, "Rock1")), param({ X = 0, Y = 0, Z = 100 }),
    param({ X = 3000, Y = 0, Z = 0 }))
check(sent("NPCROCK", a_pc) == 1 and sent("NPCROCK", b_pc) == 1, "the rock still goes to both (160 m)")
check(sent("SND", a_pc) == 1 and sent("SND", b_pc) == 0, "the throw growl only to the near one")

-- ================================================================ 4. sdc_whistle
print("== 4. sdc_whistle")
local whistle = require("sdc_whistle")
whistle.init(S)
whistle.register_handlers()
whistle.tick()
local MC = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:MC_Distract"
check(W.hooks[MC] ~= nil, "MC_Distract hook")
move(a_pawn, 2000); move(b_pawn, 20000)
h_pawn._p["DistractNoisePlaying?"] = true
W.outbox = {}
fire(W, MC, param(h_pawn))
check(sent("WHISTLE", a_pc) == 1 and sent("WHISTLE", b_pc) == 0, "host's whistle: 20 m yes, 200 m no (before: both)")
-- a client's whistle reaches the host: AI noise always, forwarded only near
local net = require("sdc_net")
W.outbox = {}
W.noises = {}
move(a_pawn, 2000); move(b_pawn, 4000)       -- b is 20 m from a
net.handlers.WHISTLE({ "1" }, a_pc)
check(#W.noises == 1, "the host reports the AI noise of the client's whistle")
check(sent("WHISTLE", b_pc) == 1, "forwarded to the other client 20 m from the whistler")
W.outbox = {}
move(b_pawn, 30000)
net.handlers.WHISTLE({ "1" }, a_pc)
check(#W.noises == 2 and sent("WHISTLE", b_pc) == 0, "AI noise again, but nothing to the other client 280 m away")
-- the client side: its own whistle always goes to the host (the AI noise)
S.role = "client"
h_pc._p._local = true
move(h_pawn, 0)
W.outbox = {}
fire(W, MC, param(h_pawn))
local up = 0
for _, e in ipairs(W.outbox) do if e.up and e.msg:find("SDC1|WHISTLE|", 1, true) then up = up + 1 end end
check(up == 1, "client -> host WHISTLE always sent")
S.role = "host"

-- ================================================================ 5. sdc_world WNOISE
print("== 5. sdc_world WNOISE")
local world = require("sdc_world")
world.install(S)
local box = new(W, { "BP_LootContainer_C" }, "Crate_7", { _loc = { X = 2000, Y = 0, Z = 0 } })
move(a_pawn, 2000); move(b_pawn, 4500)       -- b 25 m from the crate
W.outbox = {}
W.noises = {}
net.handlers.WNOISE({ world.pack("/Game/Levels/LongdownValley.LongdownValley:PersistentLevel.Crate_7") }, a_pc)
check(#W.noises == 1, "the host reports the search noise to the AI")
check(sent("WNOISE", b_pc) == 1 and sent("WNOISE", a_pc) == 0, "forwarded to the other client 25 m away, not back to the searcher")
W.outbox = {}
move(b_pawn, 20000)
net.handlers.WNOISE({ world.pack("/Game/Levels/LongdownValley.LongdownValley:PersistentLevel.Crate_7") }, a_pc)
check(#W.noises == 2 and sent("WNOISE", b_pc) == 0, "a client 180 m from the crate gets nothing (before: every client)")
-- the host's own noisy search (BP_LootContainer.PauseInteract, post)
local PAUSE = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:PauseInteract"
pcall(world.tick)
if W.hooks[PAUSE] then
    move(a_pawn, 3000); move(b_pawn, 20000)
    W.outbox = {}
    fire(W, PAUSE, param(box))
    check(sent("WNOISE", a_pc) == 1 and sent("WNOISE", b_pc) == 0, "host's own search: the client 10 m from the crate yes, 180 m no")
else
    check(false, "PauseInteract hook registered by the world tick")
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
