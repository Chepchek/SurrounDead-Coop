-- Mock harness: how far relayed sounds carry (0.6.72 work).
--   sdc_ownsounds: sound ranges from the game's attenuation, the guard for
--     another player's sound without attenuation, OSND sent / played only in range;
--   sdc_sync: shot sounds from MC_WeaponEffects with an attenuation, far shots only
--     up to the cue's own range, forwarded SND played only in range.
-- Real sdc_ue / sdc_net / sdc_ctx / sdc_config / sdc_log / sdc_appearance against
-- fake UE objects, one world for the host and one for the client.
-- usage: lua mock_sound_range.lua <scripts dir>
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
local next_addr = 20480
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _w = w }, Obj)
    o._full = chain[1] .. " " .. (path or ("/Game/Levels/PL.PL:PersistentLevel." .. name))
    w.objects[#w.objects + 1] = o
    w.paths[path or ("/Game/Levels/PL.PL:PersistentLevel." .. name)] = o
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
LoadAsset = function(path) WORLD.loads = (WORLD.loads or 0) + 1; return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(ms, fn) return 1 end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local function fire(w, path, kind, ...)
    local prev = WORLD
    WORLD = w
    for _, h in ipairs(w.hooks[path] or {}) do
        local fn = (kind == "post") and h.post or h.pre
        if fn then assert(fn(...) == nil, "hook returned a value: " .. path) end
    end
    WORLD = prev
end

-- ---------------------------------------------------------------- worlds
local FN_PLAY = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local FN_SPAWN = "/Script/Engine.GameplayStatics:SpawnSoundAtLocation"
local FN_MC = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:MC_WeaponEffects"
local WORLD_MAX = 2097152.0

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, outbox = {}, plays = {} }
end
local HW, CW = world("host"), world("client")

local function engine(w)
    w.gs = new(w, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
        -- the native call: its hooks see it first (they may change the attenuation)
        PlaySoundAtLocation = function(self, wco, s, loc, rot, vol, pitch, start, att)
            local ap = param(att)
            fire(w, FN_PLAY, "pre", param(self), param(wco), param(s), param(loc), param(rot), param(vol), param(pitch),
                param(start), ap)
            w.plays[#w.plays + 1] = { wco = wco, s = s, loc = loc, att = ap._v() }
        end,
    }, "/Script/Engine.Default__GameplayStatics")
    w.ksl = new(w, { "KismetSystemLibrary" }, "Default__KismetSystemLibrary", {}, {
        IsStandalone = function() return false end, IsServer = function() return w.id == "host" end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    w.att = {}
    for name, ext_fall in pairs({ FootSteps = 3100, BulletImpact = 1550, GunshotsPistolSuppressed = 15750,
                                  GunshotsRifle = 27000 }) do
        w.att[name] = new(w, { "SoundAttenuation" }, name, {}, {}, "/Game/Audio/Attenuation/" .. name .. "." .. name)
    end
    local function cue(name, max, att)
        return new(w, { "SoundCue" }, name, { MaxDistance = max, AttenuationSettings = att and w.att[att] or nil }, {},
            "/Game/Audio/X/" .. name .. "." .. name)
    end
    w.empty = new(w, { "SoundCue" }, "S_EmptyFire_Cue", { MaxDistance = 3100.0, AttenuationSettings = w.att.FootSteps }, {},
        "/Game/Audio/Sounds/Cue/S_EmptyFire_Cue.S_EmptyFire_Cue")
    w.rifle = cue("AR_Single_Shot_Cue", 27000.0, "GunshotsRifle")
    w.flare = cue("fire_flare_gun_Cue", WORLD_MAX)
    w.bolt = cue("bow_crossbow_arrow_shoot_type3_01_Cue", WORLD_MAX)
    w.torch = cue("Turning_Flashlight_On_Cue", WORLD_MAX)
    w.search = cue("Searching_Cue", WORLD_MAX)
    w.odd = cue("SomethingNew_Cue", WORLD_MAX)
    w.growl = new(w, { "SoundCue" }, "ZombieGrowlShort", { MaxDistance = 3100.0, AttenuationSettings = w.att.FootSteps }, {},
        "/Game/Audio/Zombie/ZombieGrowlShort.ZombieGrowlShort")
    w.wave = new(w, { "SoundWave" }, "SomeWave", { AttenuationSettings = w.att.BulletImpact }, {}, "/Game/Audio/X/SomeWave.SomeWave")
    w.ambient = cue("night_and_crickets_ambient_loop_Cue", WORLD_MAX)
end
engine(HW)
engine(CW)

local function player(w, name, id, loc, is_local, pc_props)
    local ps = new(w, { "PlayerState" }, "PS_" .. name, {}, { GetPlayerId = function() return id end })
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "PC_" .. name, pc_props or {}, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        ClientMessage = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
    })
    pc._p._local = is_local
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. name,
        { Controller = pc, _loc = loc, PlayerState = ps, _local = is_local })
    pc._p.Pawn = pawn
    return pc, pawn
end
-- host: its own player (256) and the client's (257); the client: its own (257) and the host's copy (256)
local lp_h = new(HW, { "LocalPlayer" }, "LocalPlayer_H")
local h_pc, h_pawn = player(HW, "host", 256, { X = 0, Y = 0, Z = 0 }, true, { Player = lp_h })
local conn = new(HW, { "IpConnection" }, "Conn")
local r_pc, r_pawn = player(HW, "client", 257, { X = 2000, Y = 0, Z = 0 }, false, { NetConnection = conn, Player = conn })
local lp_c = new(CW, { "LocalPlayer" }, "LocalPlayer_C")
local c_pc, c_pawn = player(CW, "me", 257, { X = 2000, Y = 0, Z = 0 }, true, { Player = lp_c })
local _, c_host = player(CW, "hostcopy", 256, { X = 0, Y = 0, Z = 0 }, false)
local function move(p, x) p._p._loc = { X = x, Y = 0, Z = 0 } end

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    return { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
             ctx = require("sdc_ctx"), own = require("sdc_ownsounds"), sync = require("sdc_sync") }
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { r_pc }, remote = {} }
H.own.init(HS); H.own.register_handlers(); H.sync.register_handlers()
H.log.debug_enabled = true
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.own.init(CS); C.own.register_handlers(); C.sync.register_handlers()
C.log.debug_enabled = true

local function deliver()
    local out = HW.outbox
    HW.outbox = {}
    WORLD = CW
    for _, msg in ipairs(out) do
        local kind, f = C.net.decode(msg)
        if C.net.handlers[kind] then C.net.handlers[kind](f, c_pc) end
    end
    out = CW.outbox
    CW.outbox = {}
    WORLD = HW
    for _, msg in ipairs(out) do
        local kind, f = H.net.decode(msg)
        if H.net.handlers[kind] then H.net.handlers[kind](f, r_pc) end
    end
end
local function count(w, kind)
    local n = 0
    for _, m in ipairs(w.outbox) do if m:find("SDC1|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end
-- a game call on this machine (BP -> the native function)
local function game_play(w, wco, s, att)
    WORLD = w
    w.gs:PlaySoundAtLocation(wco, s, { X = 0, Y = 0, Z = 0 }, {}, 1.0, 1.0, 0.0, att)
    return w.plays[#w.plays]
end

WORLD = HW; H.own.tick()
WORLD = CW; C.own.tick()
check(HW.hooks[FN_PLAY] ~= nil and HW.hooks[FN_SPAWN] ~= nil and CW.hooks[FN_PLAY] ~= nil, "PlaySound / SpawnSound hooks on both")

-- ================================================================ 1. ranges
print("== 1. how far sounds carry")
WORLD = CW
local r, a, l = C.own.range_of(CW.empty)
check(r == 3100 and a == nil, "S_EmptyFire_Cue: its own FootSteps 31 m, no attenuation passed (" .. tostring(l) .. ")")
r, a = C.own.range_of(CW.rifle)
check(r == 27000 and a == nil, "rifle shot: its own 270 m")
r, a = C.own.range_of(CW.flare)
check(r == 15750 and a == CW.att.GunshotsPistolSuppressed, "flare gun shot without attenuation: GunshotsPistolSuppressed 157.5 m")
r, a = C.own.range_of(CW.bolt)
check(r == 1550 and a == CW.att.BulletImpact, "crossbow shot: BulletImpact 15.5 m")
r, a = C.own.range_of(CW.odd)
check(r == 3100 and a == CW.att.FootSteps, "unknown sound without attenuation: FootSteps 31 m")
r, a = C.own.range_of(CW.wave)
check(r == 1550 and a == nil, "sound wave with an attenuation asset: that asset's range")

-- ================================================================ 2. guard
print("== 2. guard: another player's sound without attenuation")
local p = game_play(CW, c_host, CW.torch)
check(p.att == CW.att.BulletImpact, "client: the host's flashlight click gets BulletImpact")
p = game_play(CW, c_pawn, CW.torch)
check(p.att == nil, "client: the own flashlight click stays as in single player")
p = game_play(CW, c_host, CW.rifle)
check(p.att == nil, "attenuated sound untouched")
p = game_play(CW, c_host, CW.torch, CW.att.FootSteps)
check(p.att == CW.att.FootSteps, "the caller's attenuation kept")
local box = new(CW, { "BP_LootContainer_C" }, "Box1", { _loc = { X = 5, Y = 0, Z = 0 } })
p = game_play(CW, box, CW.search)
check(p.att == CW.att.FootSteps, "container search loop (a listed sound at a world object): FootSteps")
p = game_play(CW, box, CW.ambient)
check(p.att == nil, "a world object's other sound without attenuation untouched (ambient)")
local h_weapon = new(HW, { "BP_CrossbowPickup_C", "BP_FirearmPickup_C" }, "Crossbow_R", { _owner = r_pawn })
p = game_play(HW, h_weapon, HW.bolt)
check(p.att == HW.att.BulletImpact, "host: the client's crossbow (its item) gets BulletImpact")
p = game_play(HW, h_pawn, HW.odd)
check(p.att == nil, "host: its own sound untouched")
p = game_play(HW, r_pawn, HW.odd)
check(p.att == HW.att.FootSteps, "host: the client's unknown sound without attenuation: FootSteps")
H.cfg.values.sound_range_guard = false
p = game_play(HW, r_pawn, HW.odd)
check(p.att == nil, "sound_range_guard=false: untouched")
H.cfg.values.sound_range_guard = nil

-- ================================================================ 3. OSND
print("== 3. OSND only within the sound's range")
HW.outbox = {}
move(r_pawn, 2000)
game_play(HW, h_pawn, HW.empty)
check(count(HW, "OSND") == 1, "host's empty click sent to the client 20 m away")
deliver()
local last = CW.plays[#CW.plays]
check(last.s == CW.empty and last.wco == c_host and last.att == nil, "client plays it at the host with the cue's own attenuation")
move(r_pawn, 9000)
advance(1.1)
game_play(HW, h_pawn, HW.empty)
check(count(HW, "OSND") == 0, "client 90 m away: not sent (it carries 31 m)")
-- an OSND that comes anyway while far: not played
local before = #CW.plays
move(c_pawn, 9000)
WORLD = CW
C.net.handlers.OSND({ "/Game/Audio/Sounds/Cue/S_EmptyFire_Cue.S_EmptyFire_Cue", "1", "1", "256" }, c_pc)
check(#CW.plays == before, "client: a far one is not played")
-- the client's own click: sent only when another player is near
CW.outbox = {}
advance(1.1)
game_play(CW, c_pawn, CW.empty)
check(count(CW, "OSND") == 0, "client: nobody within 31 m, not sent")
move(c_pawn, 1500)
advance(1.1)
game_play(CW, c_pawn, CW.empty)
check(count(CW, "OSND") == 1, "client: host 15 m away, sent")
-- host forwards a client's click only to players near it
move(r_pawn, 1500)
local other_conn = new(HW, { "IpConnection" }, "Conn2")
local o_pc, o_pawn = player(HW, "third", 258, { X = 50000, Y = 0, Z = 0 }, false, { NetConnection = other_conn, Player = other_conn })
HS.remote_pcs = { r_pc, o_pc }
HW.outbox = {}
deliver()
check(count(HW, "OSND") == 0, "host: a third player 500 m away gets no forward")
move(o_pawn, 2500)
CW.outbox = { "SDC1|OSND|/Game/Audio/Sounds/Cue/S_EmptyFire_Cue.S_EmptyFire_Cue|1.00|1.00" }
deliver()
check(count(HW, "OSND") == 1, "host: a third player 10 m from the client gets it")
HS.remote_pcs = { r_pc }
o_pawn._valid = false

-- ================================================================ 4. shots and far shots (sdc_sync)
print("== 4. shot sounds and far shots")
local function weapon(w, cls, owner, sound, at)
    local comp = new(w, { "BP_WeaponsPickupComponent_C" }, cls .. "_Comp", { FirearmSound = sound })
    return new(w, { cls, "BP_FirearmPickup_C" }, cls .. "_W", { _owner = owner, _loc = at or { X = 0, Y = 0, Z = 0 },
        BP_WeaponsPickupComponent = comp })
end
local h_rifle = weapon(HW, "BP_AK_C", h_pawn, HW.rifle)
local h_flare = weapon(HW, "BP_FlareGunPickup_C", h_pawn, HW.flare)
local h_bow = weapon(HW, "BP_CrossbowPickup_C", h_pawn, HW.bolt)
WORLD = HW
H.cfg.set("shot_sounds", true)
H.sync.ensure_shot_sounds()
check(HW.hooks[FN_MC] ~= nil, "MC_WeaponEffects hook")
H.sync.host_sound_tick({ r_pc })
local function host_shot(wpn) HW.outbox = {}; fire(HW, FN_MC, "pre", param(wpn)) end
move(r_pawn, 20000)
host_shot(h_rifle)
check(count(HW, "SND") == 1, "rifle (270 m) at 200 m: far shot sent")
move(r_pawn, 30000)
host_shot(h_rifle)
check(count(HW, "SND") == 0, "rifle at 300 m: beyond its 270 m, not sent (before: up to 350 m)")
move(r_pawn, 14000)
host_shot(h_flare)
check(count(HW, "SND") == 1, "flare gun (157.5 m) at 140 m: sent")
move(r_pawn, 20000)
host_shot(h_flare)
check(count(HW, "SND") == 0, "flare gun at 200 m: not sent (before: played at full volume up to 350 m)")
move(r_pawn, 13000)
host_shot(h_bow)
check(count(HW, "SND") == 0, "crossbow (15.5 m): never a far shot")
-- the client's shot heard on the host through the multicast
local c_weapon_on_host = weapon(HW, "BP_FlareGunPickup_C", r_pawn, HW.flare, { X = 2000, Y = 0, Z = 0 })
HW.plays = {}
fire(HW, FN_MC, "pre", param(c_weapon_on_host))
-- (by name: in this harness the host's sdc_sync reaches the client's sdc_ownsounds
-- through package.loaded; in the game there is one of each)
check(#HW.plays == 1 and HW.plays[1].att and HW.plays[1].att._name == "GunshotsPistolSuppressed",
    "multicast shot of a cue without attenuation: GunshotsPistolSuppressed")
local c_rifle_on_host = weapon(HW, "BP_AK_C", r_pawn, HW.rifle, { X = 2000, Y = 0, Z = 0 })
fire(HW, FN_MC, "pre", param(c_rifle_on_host))
check(#HW.plays == 2 and HW.plays[2].att == nil, "multicast rifle shot: the cue's own attenuation")

-- ================================================================ 5. SND on the client
print("== 5. forwarded SND on the client")
WORLD = CW
move(c_pawn, 20000)
CW.plays = {}
c_host._valid = false   -- the shooter is beyond the net range: no copy here
C.net.handlers.SND({ "Audio/X/AR_Single_Shot_Cue.AR_Single_Shot_Cue", "0", "0", "0", "1.00", "1.00", "256" }, c_pc)
check(#CW.plays == 1 and CW.plays[1].att == nil, "far rifle shot at 200 m played with its own attenuation")
C.net.handlers.SND({ "Audio/X/fire_flare_gun_Cue.fire_flare_gun_Cue", "0", "0", "0", "1.00", "1.00", "256" }, c_pc)
check(#CW.plays == 1, "far flare shot at 200 m not played (it carries 157.5 m)")
move(c_pawn, 14000)
C.net.handlers.SND({ "Audio/X/fire_flare_gun_Cue.fire_flare_gun_Cue", "0", "0", "0", "1.00", "1.00", "256" }, c_pc)
check(#CW.plays == 2 and CW.plays[2].att == CW.att.GunshotsPistolSuppressed, "at 140 m: played with GunshotsPistolSuppressed")
move(c_pawn, 10000)
C.net.handlers.SND({ "Audio/Zombie/ZombieGrowlShort.ZombieGrowlShort", "0", "0", "0", "1.00", "1.00" }, c_pc)
check(#CW.plays == 2, "boss growl 100 m away not played (it carries 31 m; sdc_npc sends it within 160 m)")
move(c_pawn, 2000)
C.net.handlers.SND({ "Audio/Zombie/ZombieGrowlShort.ZombieGrowlShort", "0", "0", "0", "1.00", "1.00" }, c_pc)
check(#CW.plays == 3, "boss growl 20 m away played")
c_host._valid = true
C.net.handlers.SND({ "Audio/X/AR_Single_Shot_Cue.AR_Single_Shot_Cue", "0", "0", "0", "1.00", "1.00", "256" }, c_pc)
check(#CW.plays == 3, "shooter's copy here: its multicast plays it")
-- no own character (dead / loading): nothing is played
c_pc._p.Pawn = nil
C.net.handlers.SND({ "Audio/Zombie/ZombieGrowlShort.ZombieGrowlShort", "0", "0", "0", "1.00", "1.00" }, c_pc)
check(#CW.plays == 3, "no own character: not played")
c_pc._p.Pawn = c_pawn

-- ================================================================ 6. robustness
print("== 6. hooks survive bad parameters")
local ok = pcall(function()
    fire(CW, FN_PLAY, "pre", param(nil), param(nil), param(nil), param(nil), param(nil), param(nil), param(nil), param(nil), param(nil))
    fire(CW, FN_PLAY, "pre", param(nil), param(c_host), param(CW.torch), param({}), param({}), param(1), param(1), param(0), param(7))
    fire(HW, FN_SPAWN, "pre", nil, nil, nil)
end)
check(ok, "no error")
WORLD = CW
check(C.own.status_line():find("guard: attenuation given=", 1, true) ~= nil, "status: " .. C.own.status_line())

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
