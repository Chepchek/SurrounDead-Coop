-- Mock harness: landmines in co-op (sdc_world MN, WMINE). The host's mine
-- explosion reaches the clients in earshot (one message per client for the
-- mines of one moment) and is shown there once: the copy's own Event_Explode
-- while the copy stands, else the explosion's own emitter / sound / decal at
-- the host's point (the host's destroy removed the copy first). A client's own
-- mine explosion sets the host's mine off (damage there); the client does not
-- show it twice. Runtime (buildable) mines by class and place.
-- usage: lua mock_world_landmine.lua <scripts dir>
-- (harness core copied from mock_world_crates.lua)
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
local next_addr = 4096
local LVL = "/Game/Levels/LongdownValley.LongdownValley:PersistentLevel."
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain, i)
    i = i or 1
    if not chain[i] then return nil end
    return {
        IsValid = function() return true end,
        GetFName = function() return name_obj(chain[i]) end,
    }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _calls = {} }, Obj)
    o._full = chain[1] .. " " .. (path or (LVL .. name))
    w.objects[#w.objects + 1] = o
    w.paths[path or (LVL .. name)] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation()
    if self._p._loc_error then error("location unreadable") end
    return self._p._loc
end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:K2_DestroyActor() self._valid = false end
local function rec(name)
    return function(self, ...) self._calls[#self._calls + 1] = { name, ... } end
end

local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(self, nv) v = nv end, _v = function() return v end } end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
NotifyOnNewObject = function(path, fn) WORLD.watch = WORLD.watch or {}; table.insert(WORLD.watch, { path = path, fn = fn }) end
-- UE4SS: an actor destroyed in this frame stays findable (and IsValid) until
-- the garbage collection; the mock keeps _valid for those (_destroyed set)
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
ExecuteInGameThreadWithDelay = function(ms, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local function run_timers(w)
    WORLD = w
    for _ = 1, 3 do
        local t = w.timers
        w.timers = {}
        for _, fn in ipairs(t) do fn() end
    end
end

local function fire(w, path, ...)
    WORLD = w
    local hs = w.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local r = h.pre(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
    return true
end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, outbox_far = {} }
end
local HW, CW = world("host"), world("client")

local FX_P = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_New.FX_Explosion_New"
local CUE_P = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue"
local DECAL_P = "/Game/Blueprints/Other/ExplosiveBarrel/M_Burn.M_Burn"
local MINE_P = "/Game/Blueprints/Other/Objects/BP_Landmine.BP_Landmine_C"
local BUILT_P = "/Game/Blueprints/BuildingSystem/Actors/Traps/Buildable_LandMine.Buildable_LandMine_C"

-- KismetSystemLibrary.IsValid, a UFunction object called as fn(context, object)
local FnMT = { __index = Obj.__index, __call = function(_, _, o) return o._valid == true and not o._destroyed end }

local function engine(w, is_server)
    WORLD = w
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    setmetatable(new(w, { "Function" }, "IsValid", {}, {}, "/Script/Engine.KismetSystemLibrary:IsValid"), FnMT)
    w.sounds, w.emitters, w.decals = {}, {}, {}
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        PlaySoundAtLocation = function(_, wco, snd, loc, rot, vol, pitch)
            w.sounds[#w.sounds + 1] = { snd = snd, loc = loc, vol = vol, pitch = pitch }
        end,
        SpawnEmitterAtLocation = function(_, wco, tpl, loc, rot, scale, auto, pool, act)
            w.emitters[#w.emitters + 1] = { tpl = tpl, loc = loc, rot = rot, scale = scale, auto = auto }
        end,
        SpawnDecalAtLocation = function(_, wco, mat, size, loc, rot, life)
            w.decals[#w.decals + 1] = { mat = mat, size = size, loc = loc, rot = rot, life = life }
        end,
        GetCurrentLevelName = function() return "LongdownValley" end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
    new(w, { "AISense_Hearing" }, "Hearing", {}, { ReportNoiseEvent = rec("ReportNoiseEvent") }, "/Script/AIModule.Default__AISense_Hearing")
    -- the explosion's assets (hard references of the mine class: in memory on every machine)
    new(w, { "ParticleSystem" }, "FX_Explosion_New", {}, {}, FX_P)
    new(w, { "SoundCue" }, "explosion_large_06_Cue", { MaxDistance = 32500 }, {}, CUE_P)
    new(w, { "Material" }, "M_Burn", {}, {}, DECAL_P)
end
engine(HW, true)
engine(CW, false)

local function players(w)
    WORLD = w
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
players(HW)
players(CW)

-- two remote players on the host: one 50 m from the origin, one 100 km away
WORLD = HW
local function remote(i, loc, box)
    local conn = new(HW, { "IpConnection" }, "IpConnection_" .. i)
    local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. i, { _loc = loc })
    local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. i,
        { NetConnection = conn, Player = conn, Pawn = rpawn }, {
            ClientMessage = function(self, msg) HW[box][#HW[box] + 1] = msg end,
        })
    rpawn._p.Controller = rpc
    return rpc
end
local rpc = remote(1, { X = 5000, Y = 0, Z = 0 }, "outbox")
local rpc_far = remote(2, { X = 10000000, Y = 0, Z = 0 }, "outbox_far")
HW.pcs[2], HW.pcs[3] = rpc, rpc_far

-- ---------------------------------------------------------------- mines
local EXPLODE = MINE_P .. ":Event_Explode"
local EXPLODE_B = BUILT_P .. ":Event_Explode"
HW.damage = 0
-- Event_Explode as the game runs it: DoOnce; the explosion's own calls; damage
-- (counted on the host: pawns refuse it on a client); K2_DestroyActor (the host's
-- goes: destroyed, still findable until the collection; a client's copy is a
-- simulated proxy: refused); then UE4SS's post-hook.
local function mine(w, cls, name, loc, role, path)
    WORLD = w
    local hook = cls == "BP_Landmine_C" and EXPLODE or EXPLODE_B
    local m
    m = new(w, { cls, cls == "BP_Landmine_C" and "BP_MasterObject_C" or "Buildable_MASTER_C", "Actor" }, name,
        { _loc = loc, Role = role, bReplicates = true }, {
            Event_Explode = function(self)
                if not self._closed then
                    self._closed = true
                    self._booms = (self._booms or 0) + 1
                    w.sounds[#w.sounds + 1] = { snd = "own " .. name }
                    if role == 3 then w.damage = w.damage + 1 end
                    self:K2_DestroyActor()
                end
                fire(w, hook, param(self))
            end,
            SetActorHiddenInGame = function(self, b) self._p._hidden = b end,
            SetActorEnableCollision = function(self, b) self._p._col = b end,
        }, path)
    rawset(m, "K2_DestroyActor", function(self) if role == 3 then self._destroyed = true end end)
    return m
end
local function boom(m) WORLD = (m._p.Role == 3) and HW or CW; m:Event_Explode() end
local function at(x, y, z) return { X = x, Y = y, Z = z } end

-- ---------------------------------------------------------------- load modules per world
local logs = { host = {}, client = {} }
local errors = 0
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.off = {}
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if m.off[k] then return false end
        return get0(k, ...)
    end
    local info0 = m.log.info
    m.log.info = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        local l = logs[w.id]
        l[#l + 1] = ok and s or fmt
        return info0(fmt, ...)
    end
    local errt0 = m.log.err_throttled
    m.log.err_throttled = function(key, fmt, ...)
        errors = errors + 1
        print("  [error " .. w.id .. "] " .. string.format(fmt, ...))
        return errt0(key, fmt, ...)
    end
    m.net.install_hooks()
    m.world = require("sdc_world")
    return m
end
local H = load_mods(HW)
H.ctx.scope_resolver = function() return nil end
local HS = { role = "host", remote_pcs = { rpc, rpc_far }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)

local function logged(id, pat)
    for _, l in ipairs(logs[id]) do if l:find(pat, 1, true) then return l end end
    return nil
end
local function clear_logs() logs.host, logs.client = {}, {} end

local function deliver()
    for _ = 1, 6 do
        local out = HW.outbox
        HW.outbox = {}
        WORLD = CW
        for _, msg in ipairs(out) do
            local kind, f = C.net.decode(msg)
            local h = C.net.handlers[kind]
            if h then h(f, CW.pc) end
        end
        out = CW.outbox
        CW.outbox = {}
        WORLD = HW
        for _, msg in ipairs(out) do
            local kind, f = H.net.decode(msg)
            local h = H.net.handlers[kind]
            if h then h(f, rpc) end
        end
    end
end
local function settle() for _ = 1, 3 do run_timers(HW); deliver(); run_timers(CW); deliver() end end
local function count(box, kind)
    local n = 0
    for _, m in ipairs(box) do if m:find("|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end

-- the level's mines: the same path on both machines
local hm, cm = {}, {}
for i = 1, 7 do
    local name = "BP_Landmine_C_" .. (11 + i)
    local loc = at(1000 + i * 500, 0, 1650)
    hm[i] = mine(HW, "BP_Landmine_C", name, loc, 3)
    cm[i] = mine(CW, "BP_Landmine_C", name, at(loc.X, loc.Y, loc.Z), 1)
end
-- one near the far player only
local hfar = mine(HW, "BP_Landmine_C", "BP_Landmine_C_90", at(10000500, 0, 0), 3)
local cfar = mine(CW, "BP_Landmine_C", "BP_Landmine_C_90", at(10000500, 0, 0), 1)

print("== L0. hooks and handlers")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
check(HW.hooks[EXPLODE] ~= nil and HW.hooks[EXPLODE_B] ~= nil, "host: BP_Landmine / Buildable_LandMine Event_Explode post-hooks")
check(CW.hooks[EXPLODE] ~= nil and CW.hooks[EXPLODE_B] ~= nil, "client: the same hooks")
check(H.net.handlers.WMINE ~= nil and C.net.handlers.WMINE ~= nil, "WMINE handlers on both")
check(logged("host", "sound relay WMINE") ~= nil, "install line names the relay")

print("== L1. the host shoots a mine; its destroy reached the client first")
clear_logs()
boom(hm[1])
check(HW.damage == 1 and hm[1]._destroyed, "host: the mine went off there (damage, destroyed)")
check(#HW.outbox == 0, "nothing sent from inside the hook")
cm[1]._destroyed = true   -- the replicated destroy: still findable by its path until the collection
run_timers(HW)
check(count(HW.outbox, "WMINE") == 1 and count(HW.outbox_far, "WMINE") == 0, "one WMINE to the near client, none to the far one")
check(HW.outbox[1]:find("w>~LongdownValley~BP_Landmine_C_12>1500,0,1650", 1, true) ~= nil, "item: class, packed path, place")
check(logged("host", "1 mine(s) exploded on the host (BP_Landmine_C_12 at 1500,0,1650): WMINE to 1 client(s) in 1 message(s), 1 client(s) beyond 330 m") ~= nil,
    "host log line")
deliver()
check(cm[1]._booms == nil, "the destroyed copy is not run")
check(#CW.emitters == 1 and CW.emitters[1].tpl._name == "FX_Explosion_New" and CW.emitters[1].loc.X == 1500
    and CW.emitters[1].scale.X >= 1 and CW.emitters[1].scale.X <= 1.5 and CW.emitters[1].auto == true, "client: the game's emitter at the host's point")
check(#CW.sounds == 1 and CW.sounds[1].snd._name == "explosion_large_06_Cue" and CW.sounds[1].loc.Z == 1650
    and CW.sounds[1].vol == 1.0, "client: the game's explosion sound there")
check(#CW.decals == 1 and CW.decals[1].mat._name == "M_Burn" and CW.decals[1].size.Y == 512 and CW.decals[1].life == 30
    and CW.decals[1].rot.Pitch == -90, "client: the scorch decal there")
check(#CW.outbox == 0, "client: nothing sent back")
check(logged("client", "its copy is gone here (the host's destroy came first): emitter+sound+decal at 1500,0,1650") ~= nil,
    "client log line")

print("== L2. two mines at one moment: one message; a standing copy runs its own Event_Explode")
clear_logs()
boom(hm[2]); boom(hm[3])
cm[3]._destroyed = true
run_timers(HW)
check(count(HW.outbox, "WMINE") == 1 and HW.outbox[1]:find("BP_Landmine_C_13", 1, true) and HW.outbox[1]:find("BP_Landmine_C_14", 1, true),
    "both in one message")
local snd0, em0 = #CW.sounds, #CW.emitters
deliver()
run_timers(CW)
check(cm[2]._booms == 1 and cm[2]._p._hidden == true and cm[2]._p._col == false, "standing copy: its own Event_Explode, then hidden")
check(#CW.emitters == em0 + 1 and #CW.sounds == snd0 + 2, "destroyed copy: the effects; standing copy: its own explosion")
check(#CW.outbox == 0 and C.world.stats.mines_sent == 0, "the replay of the host's mine is not sent back")
check(logged("client", "the host's mine BP_Landmine_C_13 exploded here: its copy BP_Landmine_C_13 ran its own Event_Explode (ok=true)") ~= nil,
    "client log line (copy)")

print("== L3. the same word again: not shown twice")
local em1, so1 = #CW.emitters, #CW.sounds
WORLD = CW; C.net.handlers.WMINE({ "w>~LongdownValley~BP_Landmine_C_12>1500,0,1650;w>~LongdownValley~BP_Landmine_C_13>2000,0,1650" }, CW.pc)
check(#CW.emitters == em1 and #CW.sounds == so1 and cm[2]._booms == 1, "no second explosion")
check(C.world.stats.mines_dup == 2, "counted as already shown")
advance(60)
WORLD = CW; C.net.handlers.WMINE({ "w>~LongdownValley~BP_Landmine_C_12>1500,0,1650" }, CW.pc)
check(#CW.emitters == em1 and C.world.stats.mines_dup == 3, "a level mine stays shown for the world (a minute later too)")

print("== L4. the client shoots a mine: its own copy goes off, the host's mine too, shown once")
clear_logs()
local dmg0 = HW.damage
local so2, em2 = #CW.sounds, #CW.emitters
boom(cm[4])   -- Trace_Impact -> Damage_Object -> Event_Explode on the client only
check(cm[4]._booms == 1 and cm[4]._valid and not cm[4]._destroyed, "client: own explosion; its destroy refused")
run_timers(CW)
check(count(CW.outbox, "WMINE") == 1 and CW.outbox[1]:find("w>~LongdownValley~BP_Landmine_C_15>", 1, true), "client: WMINE to the host")
check(logged("client", "1 mine(s) went off here (own shot / step: BP_Landmine_C_15): sent to the host") ~= nil, "client log line (own)")
deliver()
check(hm[4]._booms == 1 and HW.damage == dmg0 + 1 and hm[4]._destroyed, "host: its mine went off (damage, destroyed)")
check(logged("host", "set off mine BP_Landmine_C_15 in its game: BP_Landmine_C_15 exploded on the host too (ok=true)") ~= nil, "host log line")
run_timers(HW)
check(count(HW.outbox, "WMINE") == 1, "host: the explosion reported back")
deliver()
check(cm[4]._booms == 1 and #CW.emitters == em2 and #CW.sounds == so2 + 1, "client: not shown a second time")
check(cm[4]._p._hidden == true, "client: the inert copy hidden until the host's destroy")
check(logged("client", "the host's mine BP_Landmine_C_15 went off here already (own shot / step): not shown again; its copy hidden") ~= nil,
    "client log line (already)")

print("== L5. the client's mine is gone on the host already: nothing more there")
clear_logs()
boom(hm[5]); run_timers(HW); deliver()          -- (the host's step; the client was shown it)
local b5, d5 = hm[5]._booms, HW.damage
rawset(cm[5], "_closed", nil); cm[5]._booms = nil; C.world._t.mines.here = {}   -- a copy that went off by itself later
boom(cm[5]); run_timers(CW); deliver()
check(hm[5]._booms == b5 and HW.damage == d5, "host: no second explosion of a destroyed mine")
check(logged("host", "not standing on the host") ~= nil, "host log line (gone)")
check(count(HW.outbox, "WMINE") == 0, "nothing reported back")

print("== L6. buildable mines: by class and place")
clear_logs()
local hb = mine(HW, "Buildable_LandMine_C", "Buildable_LandMine_C_2147400001", at(3000, 2000, 1600), 3)
local cb = mine(CW, "Buildable_LandMine_C", "Buildable_LandMine_C_2147482001", at(3000.4, 1999.7, 1600), 1)
boom(hb); run_timers(HW)
check(HW.outbox[1] and HW.outbox[1]:find("|b>>3000,2000,1600", 1, true) ~= nil, "item without a path, with its place")
deliver()
check(cb._booms == 1 and cb._p._hidden == true, "client: its copy (another name) found by its place, own explosion")
local hb2 = mine(HW, "Buildable_LandMine_C", "Buildable_LandMine_C_2147400002", at(-4000, 0, 1600), 3)
local cb2 = mine(CW, "Buildable_LandMine_C", "Buildable_LandMine_C_2147482002", at(-4000, 0.6, 1600), 1)
boom(cb2); run_timers(CW); deliver()          -- a zombie copy stepped on it on the client
check(hb2._booms == 1, "host: the client's buildable mine found by its place and set off")
run_timers(HW); deliver()
check(cb2._booms == 1, "client: not run twice")

print("== L7. the host cannot read the place: sent by name to everyone")
clear_logs()
hm[6]._p._loc_error = true
boom(hm[6]); run_timers(HW)
check(count(HW.outbox, "WMINE") == 1 and count(HW.outbox_far, "WMINE") == 1, "both clients get it")
check(HW.outbox[1]:find("BP_Landmine_C_17>|", 1, true) ~= nil or HW.outbox[1]:find("BP_Landmine_C_17>$") ~= nil,
    "item with the path, no place")
HW.outbox_far = {}
deliver()
check(cm[6]._booms == 1, "client: its copy found by the path")

print("== L8. the far mine goes to the far client only")
boom(hfar); run_timers(HW)
check(count(HW.outbox, "WMINE") == 0 and count(HW.outbox_far, "WMINE") == 1, "only the player in earshot")
HW.outbox_far = {}

print("== L9. no clients / switch off: nothing recorded")
HS.remote_pcs = {}
boom(hm[7]); run_timers(HW)
check(#HW.outbox == 0 and #H.world._t.mines.out == 0, "host alone: nothing recorded")
HS.remote_pcs = { rpc, rpc_far }
local hx = mine(HW, "BP_Landmine_C", "BP_Landmine_C_91", at(900, 900, 1600), 3)
H.off.world_objects = true
boom(hx); run_timers(HW)
check(#HW.outbox == 0, "world_objects off: nothing sent")
H.off.world_objects = nil

print("== L10. the tick sends what the delay did not")
local hy = mine(HW, "BP_Landmine_C", "BP_Landmine_C_92", at(1100, 900, 1600), 3)
boom(hy)
HW.timers = {}   -- the 30 ms delay never ran
advance(1.5)
WORLD = HW; H.world.tick()
check(count(HW.outbox, "WMINE") == 1, "flushed by the tick")
H.world._t.mines.flushing = false
deliver()

print("== L11. status, errors")
WORLD = HW; local sh = H.world.status_line(); print(sh)
WORLD = CW; local scl = C.world.status_line(); print(scl)
check(sh:find("mines host=", 1, true) ~= nil and scl:find("mines host=", 1, true) ~= nil, "status: mines segment")
check(H.world.stats.mines_host == 2 and C.world.stats.mines_sent == 3, "stats: set off for clients / own sent")
check(errors == 0, "no hook / handler errors (" .. errors .. ")")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
