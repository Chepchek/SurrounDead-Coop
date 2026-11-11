-- Mock harness: sdc_geiger - radiation zones find a client's character again
-- after its respawn (the respirator filter / radiation run on the host again).
-- usage: lua mock_respawn_filter.lua <scripts dir>
--
-- BP_RadiationArea_Sphere is simulated after work\re\pseudo\
-- BP_RadiationArea_Sphere.txt: overlaps and the 0.2 s poll react only to
-- GetPlayerCharacter(0) (the local controller's pawn); Event_EnteredRadZone /
-- Event_ExitedRadZone are complementary DoOnces (each reopens the other);
-- the entry sends UpdateRadiation (a Server RPC: recorded, not run here);
-- Event_Respawn arms the poll, which stops once it found the player.
-- Host part: the UpdateRadiation / UseFilter post-hooks for a client's
-- character only log.
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local LOG = {}
local real_print = print
print = function(s)
    s = tostring(s)
    for line in s:gmatch("[^\n]+") do LOG[#LOG + 1] = line end
end
local function say(s) real_print(s) end
local function logged(pat, from)
    for i = from or 1, #LOG do if LOG[i]:find(pat) then return LOG[i], i end end
    return nil
end
local function count_logged(pat, from)
    local n = 0
    for i = from or 1, #LOG do if LOG[i]:find(pat) then n = n + 1 end end
    return n
end

local WORLD
local fails = 0
local function check(cond, what)
    if cond then say("  ok   " .. what) else say("  FAIL " .. what); fails = fails + 1 end
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
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true }, Obj)
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
function Obj:GetOwner() return self._p._owner end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:IsLocalController() return self._p._local == true end
function Obj:K2_GetActorLocation() return self._p._loc end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end
local ZONE_FN = "/Game/Blueprints/Zones/BP_RadiationArea_Sphere.BP_RadiationArea_Sphere_C:"
local RAD_FN = "/Game/Blueprints/Components/RadiationComponent.RadiationComponent_C:"
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    if WORLD.zone_class_missing and path:find(ZONE_FN, 1, true) then
        error("function not found: " .. path)
    end
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { a = a, b = b })
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

-- a Blueprint function's post-hooks (UE4SS: one callback, after the body)
local function bp_post(w, path, ctx, ...)
    local prev = WORLD
    WORLD = w
    local args = { param(ctx) }
    for _, v in ipairs({ ... }) do args[#args + 1] = param(v) end
    for _, h in ipairs(w.hooks[path] or {}) do
        assert(h.a(table.unpack(args)) == nil, "hook returned a value: " .. path)
    end
    WORLD = prev
end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, outbox = {}, rpcs = {}, hud = {}, zones = {} }
end

local function engine(w)
    WORLD = w
    new(w, { "GameplayStatics" }, "GPS", {}, {
        SpawnSound2D = function() return nil end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return w.id == "host" end,
        K2_IsTimerActive = function() return false end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    w.pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp, _local = true }, {
        ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
    })
end

-- a player character with its RadiationComponent; UpdateRadiation /
-- CheckStats are Server RPCs: on a client they go to the host (recorded)
local function character(w, name, loc, is_local)
    local pawn
    local comp = new(w, { "RadiationComponent_C" }, "RadiationComponent_" .. name,
        { InRadArea = false, CurrentRadiation = 100.0, MaxRadiation = 100.0 }, {
            UpdateRadiation = function(_, t) w.rpcs[#w.rpcs + 1] = { fn = "UpdateRadiation", pawn = pawn, t = t } end,
            CheckStats = function() w.rpcs[#w.rpcs + 1] = { fn = "CheckStats", pawn = pawn } end,
            StopRadiation = function(self) self._stops = (self._stops or 0) + 1 end,
            StopGeiger = function() end,
        })
    pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, name,
        { RadiationComponent = comp, ["PlayerDead?"] = false, _loc = loc, _local = is_local })
    comp._p._owner = pawn
    return pawn, comp
end

local function updates_for(w, pawn)
    local n = 0
    for _, r in ipairs(w.rpcs) do if r.fn == "UpdateRadiation" and r.pawn == pawn then n = n + 1 end end
    return n
end
local function hud_count(w, what, zone)
    local n = 0
    for _, e in ipairs(w.hud) do if e.what == what and (zone == nil or e.zone == zone) then n = n + 1 end end
    return n
end

-- BP_RadiationArea_Sphere: capsule at `c`, radius r, half height h
local function zone(w, name, label, c, r, h)
    local z
    local cap = new(w, { "CapsuleComponent" }, "Capsule_" .. name, {}, {
        K2_GetComponentLocation = function() return { X = c.X, Y = c.Y, Z = c.Z } end,
        GetScaledCapsuleRadius = function() return r end,
        GetScaledCapsuleHalfHeight = function() return h end,
    })
    local function player0()
        return w.pc._p.Pawn   -- GetPlayerCharacter(0): the local controller's pawn
    end
    local function inside(a)
        local p = a and a._valid and a._p._loc
        if not p then return false end
        local dx, dy, dz = p.X - c.X, p.Y - c.Y, p.Z - c.Z
        local seg = math.max(h - r, 0)
        local ez = dz > seg and dz - seg or (dz < -seg and dz + seg or 0)
        return dx * dx + dy * dy + ez * ez <= r * r
    end
    z = new(w, { "BP_RadiationArea_Sphere_C", "BP_MasterObject_C" }, name,
        { Capsule = cap, Name = FText(label), RadiationLevel = 2 }, {
        -- @2299: DoOnce (enter), reopens the exit; HUD; UpdateRadiation + CheckStats
        Event_EnteredRadZone = function(self, actor)
            if not self._enter_closed then
                self._enter_closed, self._exit_closed = true, false
                w.hud[#w.hud + 1] = { what = "enter", zone = self }
                local comp = actor and actor._valid and actor._p.RadiationComponent
                if comp then comp:UpdateRadiation(0.04); comp:CheckStats() end
            end
            bp_post(w, ZONE_FN .. "Event_EnteredRadZone", self, actor)
        end,
        -- @2238: DoOnce (exit), reopens the entry @1930; HUD; StopRadiation
        Event_ExitedRadZone = function(self, actor)
            if not self._exit_closed then
                self._exit_closed, self._enter_closed = true, false
                w.hud[#w.hud + 1] = { what = "leave", zone = self }
                local comp = actor and actor._valid and actor._p.RadiationComponent
                if comp then comp:StopRadiation() end
            end
            bp_post(w, ZONE_FN .. "Event_ExitedRadZone", self, actor)
        end,
        Event_Respawn = function(self) self._poll = true; self._respawns = (self._respawns or 0) + 1 end,
    })
    z._poll = true   -- armed by its BeginPlay
    -- the 0.2 s poll @2248
    function z.poll_tick()
        if not z._poll then return end
        for _, a in ipairs(FindAllOf("BP_PlayerCharacter_C")) do
            if inside(a) and a == player0() then
                z._poll = false
                z:Event_EnteredRadZone(a)
                a._p.RadiationComponent._p.InRadArea = true
                return
            end
        end
    end
    -- the capsule's overlap events (@3571 / @3732)
    function z.begin_overlap(a)
        if a == player0() then z:Event_EnteredRadZone(a); a._p.RadiationComponent._p.InRadArea = true end
    end
    function z.end_overlap(a)
        if a == player0() then z:Event_ExitedRadZone(a); a._p.RadiationComponent._p.InRadArea = false end
    end
    z.inside = inside
    w.zones[#w.zones + 1] = z
    return z
end
local function polls(w)
    local prev = WORLD
    WORLD = w
    for _, z in ipairs(w.zones) do z.poll_tick() end
    WORLD = prev
end

-- ---------------------------------------------------------------- load modules per world
local CFGO = {}
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if CFGO[k] ~= nil then return CFGO[k] end
        return get0(k, ...)
    end
    m.geiger = require("sdc_geiger")
    return m
end
local function tick(w, M, dt)
    advance(dt or 0.25)
    WORLD = w
    M.geiger.tick()
end

local P_OUT = { X = 0, Y = 0, Z = 100 }               -- outside every zone
local P_Z1 = { X = -95000, Y = -46400, Z = 1700 }     -- death spot, zone 1
local P_Z1B = { X = -99540, Y = -40544, Z = 1736 }    -- respawn spot next to the host, zone 1
local P_Z2 = { X = 50000, Y = 50000, Z = 0 }

-- =================================================================== client
say("== R0. client: hooks")
local CW = world("client")
engine(CW)
local Z1 = zone(CW, "BP_RadiationArea_Sphere_C_1", "Longdown Valley", { X = -97000, Y = -43500, Z = 1700 }, 60000, 50000)
local Z2 = zone(CW, "BP_RadiationArea_Sphere_C_2", "Military Base", { X = 50000, Y = 50000, Z = 0 }, 5000, 5000)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.geiger.install(CS)
tick(CW, C)
check(CW.hooks[ZONE_FN .. "Event_EnteredRadZone"] and CW.hooks[ZONE_FN .. "Event_ExitedRadZone"], "zone hooks registered")
check(logged("radiation zone hooks ok") ~= nil, "logged: radiation zone hooks ok")

say("== R1. first join: the zone's own poll finds the character (works before any death)")
local A, compA = character(CW, "BP_PlayerCharacter_C_A", P_OUT, true)
CW.pc._p.Pawn = A
tick(CW, C)
polls(CW)
check(updates_for(CW, A) == 0, "outside: no UpdateRadiation")
A._p._loc = P_Z1
polls(CW)
check(updates_for(CW, A) == 1, "inside zone 1: the poll ran the entry -> UpdateRadiation to the host")
check(compA._p.InRadArea == true and not Z1._poll, "InRadArea set, the poll stopped (@951)")
check(logged("own character BP_PlayerCharacter_C_A entered radiation zone BP_RadiationArea_Sphere_C_1") ~= nil,
    "logged: own character entered radiation zone")
Z1.begin_overlap(A)               -- the same character's second entry call (single player has it too)
check(updates_for(CW, A) == 1, "second entry call: DoOnce, nothing sent")
check(logged("ignored the entry") == nil, "not reported as an ignored entry (same character)")
tick(CW, C)

say("== R2. death inside zone 1; MC_PlayerDead comes after the unpossess (the exit is skipped here)")
A._p["PlayerDead?"] = true
tick(CW, C)
CW.pc._p.Pawn = nil
Z1.end_overlap(A)                 -- capsule off, but GetPlayerCharacter(0) is None now
check(Z1._enter_closed == true, "zone 1's entry DoOnce is still closed")
tick(CW, C)
local respawn_from = #LOG + 1

say("== R3. respawn next to the host, inside zone 1: the bug, then the fix")
local B, compB = character(CW, "BP_PlayerCharacter_C_B", P_Z1B, true)
Z1.begin_overlap(B)               -- spawned before it is possessed here: ignored
CW.pc._p.Pawn = B                 -- possessed
polls(CW)
check(updates_for(CW, B) == 0, "without the fix: no BeginOverlap, no poll (no PlayerRespawned here) -> no UpdateRadiation")
local hud_leave0 = hud_count(CW, "leave")
tick(CW, C)                       -- sdc_geiger sees the new own character
check(Z1._respawns == 1 and Z2._respawns == 1, "Event_Respawn on every zone (as PlayerRespawned)")
check(hud_count(CW, "leave", Z1) == 1 and hud_count(CW, "leave") == hud_leave0 + 1,
    "Event_ExitedRadZone only on zone 1 (the zone the old character never left here)")
check(hud_count(CW, "leave", Z2) == 0, "zone 2 (never entered): no exit, no 'leaving' text")
check(Z1._enter_closed == false, "zone 1's entry reopened")
check(compB._stops == 1, "the exit's StopRadiation ran on the new character's component (local only)")
local l = logged("own character replaced %(BP_PlayerCharacter_C_A %-> BP_PlayerCharacter_C_B%): 2 radiation zone%(s%) look for it again", respawn_from)
check(l ~= nil and l:find("in 1 zone%(s%): BP_RadiationArea_Sphere_C_1 'Longdown Valley' %(entered, no exit seen%)") ~= nil,
    "logged: re-check line with the reopened zone")
advance(0.2)
polls(CW)                         -- the zone's own poll, 0.2 s later
check(updates_for(CW, B) == 1, "the zone's own entry ran for the new character -> UpdateRadiation to the host")
check(compB._p.InRadArea == true, "InRadArea of the new character set by the zone")
check(Z2._poll == true, "zone 2 keeps polling (the character is not inside it), as in single player")
check(logged("own character BP_PlayerCharacter_C_B entered radiation zone BP_RadiationArea_Sphere_C_1 'Longdown Valley' %(0%.2 s after the respawn re%-check%)", respawn_from) ~= nil,
    "logged: entry after the respawn re-check")
tick(CW, C)
tick(CW, C)
check(Z1._respawns == 1, "no second re-check for the same character")

say("== R4. the zone exit sync still works for the new character")
CW.outbox = {}
B._p._loc = P_OUT
Z1.end_overlap(B)
tick(CW, C)
local radz = 0
for _, m in ipairs(CW.outbox) do if m:find("RADZ|0|1", 1, true) then radz = radz + 1 end end
check(radz == 1, "RADZ|0|1 sent to the host on the exit")

say("== R5. death where the game's exit ran (MC_PlayerDead before the unpossess): nothing to reopen")
B._p._loc = P_Z1
Z1.begin_overlap(B)
check(updates_for(CW, B) == 2, "walked back in: entry ran again")
tick(CW, C)
B._p["PlayerDead?"] = true
Z1.end_overlap(B)                 -- still possessed: the game's own exit
tick(CW, C)
CW.pc._p.Pawn = nil
tick(CW, C)
local Cc, compC = character(CW, "BP_PlayerCharacter_C_C", P_OUT, true)
CW.pc._p.Pawn = Cc
local leave1 = hud_count(CW, "leave")
tick(CW, C)
check(hud_count(CW, "leave") == leave1, "no exit call (no 'leaving' text): the zone's state was known")
check(Z1._respawns == 2 and Z2._respawns == 2, "Event_Respawn on every zone again")
advance(0.2)
polls(CW)
check(updates_for(CW, Cc) == 0, "respawned outside: no entry")
Cc._p._loc = P_Z1
Z1.begin_overlap(Cc)
check(updates_for(CW, Cc) == 1, "walks into zone 1: its entry runs (DoOnce open)")
check(compC._p.InRadArea == true, "InRadArea set")

say("== R6. a blocked entry is logged (radiation_exit_sync off: no re-check)")
tick(CW, C)
CFGO.radiation_exit_sync = false
Cc._p["PlayerDead?"] = true
tick(CW, C)
CW.pc._p.Pawn = nil
Z1.end_overlap(Cc)                -- skipped (unpossessed)
tick(CW, C)
local D = character(CW, "BP_PlayerCharacter_C_D", P_Z1B, true)
CW.pc._p.Pawn = D
local r6 = #LOG + 1
tick(CW, C)
check(Z1._respawns == 2, "setting off: no Event_Respawn")
D._p._loc = P_Z1
Z1.begin_overlap(D)
check(updates_for(CW, D) == 0, "the zone ignores the entry (DoOnce closed): the bug as it was")
check(logged("radiation zone BP_RadiationArea_Sphere_C_1 'Longdown Valley' ignored the entry of BP_PlayerCharacter_C_D", r6) ~= nil,
    "logged: the zone ignored the entry")
CFGO.radiation_exit_sync = nil

say("== R7. fallback: zone hooks came after the character appeared -> its last position decides")
local FW = world("client2")
engine(FW)
FW.zone_class_missing = true
local F1 = zone(FW, "BP_RadiationArea_Sphere_C_1", "Longdown Valley", { X = -97000, Y = -43500, Z = 1700 }, 60000, 50000)
local F2 = zone(FW, "BP_RadiationArea_Sphere_C_2", "Military Base", { X = 50000, Y = 50000, Z = 0 }, 5000, 5000)
local F = load_mods(FW)
F.geiger.install({ role = "client", remote_pcs = {}, remote = {} })
local E, compE = character(FW, "BP_PlayerCharacter_C_E", P_Z1, true)
FW.pc._p.Pawn = E
tick(FW, F)                         -- the character appears; zone hooks fail
polls(FW)                           -- its entry, unseen by the module
check(updates_for(FW, E) == 1 and compE._p.InRadArea == true, "entry ran before the zone hooks")
FW.zone_class_missing = false
tick(FW, F, 2.5)                    -- hooks in now
check(FW.hooks[ZONE_FN .. "Event_EnteredRadZone"] ~= nil, "zone hooks registered late")
E._p["PlayerDead?"] = true
tick(FW, F)
FW.pc._p.Pawn = nil
tick(FW, F)
local G = character(FW, "BP_PlayerCharacter_C_G", P_Z1B, true)
FW.pc._p.Pawn = G
local r7 = #LOG + 1
tick(FW, F)
check(hud_count(FW, "leave", F1) == 1 and hud_count(FW, "leave", F2) == 0,
    "exit only for the zone around the last living position")
check(logged("%(last position inside%)", r7) ~= nil, "logged: reopened by position")
advance(0.2)
polls(FW)
check(updates_for(FW, G) == 1, "the new character's entry runs -> UpdateRadiation")

say("== R8. world reset forgets the zones and the previous character")
WORLD = CW
C.geiger.reset("test")
local H2 = character(CW, "BP_PlayerCharacter_C_H", P_OUT, true)
CW.pc._p.Pawn = H2
local z1r = Z1._respawns
tick(CW, C)
check(Z1._respawns == z1r, "first character of a new world: no re-check")

-- =================================================================== host
say("== H1. host: a client's zone entry and filter use are logged")
local HW = world("host")
engine(HW)
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1", { Player = conn, NetConnection = conn })
local R, compR = character(HW, "BP_PlayerCharacter_C_R", P_Z1B, false)
R._p.Controller = rpc
rpc._p.Pawn = R
local Hh, compHh = character(HW, "BP_PlayerCharacter_C_0", P_OUT, true)
HW.pc._p.Pawn = Hh
local Hm = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc._full] = { name = "Friend" } } }
Hm.geiger.install(HS)
tick(HW, Hm)
check(HW.hooks[RAD_FN .. "UseFilter"] ~= nil and HW.hooks[RAD_FN .. "UpdateRadiation"] ~= nil, "UseFilter / UpdateRadiation hooks")
local h0 = #LOG + 1
bp_post(HW, RAD_FN .. "UpdateRadiation", compR, 0.04)
check(logged("BP_PlayerCharacter_C_R %(Friend%) entered a radiation zone on its machine %(UpdateRadiation%): its radiation timer runs on the host every 0%.040 s", h0) ~= nil,
    "logged: the client's zone entry reached the host")
bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 87.5, true)
check(logged("BP_PlayerCharacter_C_R %(Friend%)'s respirator filter used on the host %(RadiationTimer %-> UseFilter%): durability 87%.50, ok=true", h0) ~= nil,
    "logged: first filter use")
for _ = 1, 30 do advance(1); bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 80, true) end
check(count_logged("'s respirator filter", h0) == 1, "no line per use")
for _ = 1, 31 do advance(1); bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 75.25, true) end
check(logged("respirator filter: used %d+ more time%(s%) in 6%d s on the host, durability now 75%.25", h0) ~= nil,
    "logged: summary after 60 s")
local h1 = #LOG + 1
bp_post(HW, RAD_FN .. "UpdateRadiation", compHh, 0.04)
bp_post(HW, RAD_FN .. "UseFilter", compHh, 0.1, 50, true)
check(logged("geiger", h1) == nil, "the host's own character: nothing logged")
advance(40)
bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 70, true)
check(logged("filter used on the host %(RadiationTimer %-> UseFilter%): durability 70%.00", h1) ~= nil,
    "after 30 s without use: logged as a new first use")

say("== S. status line")
WORLD = HW
local sl = Hm.geiger.status_line()
say("  " .. sl)
check(sl:find("filter uses=", 1, true) ~= nil and sl:find("respawn re-checks=", 1, true) ~= nil, "status line with the new counters")

say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
