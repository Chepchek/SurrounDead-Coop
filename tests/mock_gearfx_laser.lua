-- Mock harness for sdc_gearfx: other players' lasers aim where their owner
-- aims (host and client), and their light / laser parts show only for the
-- weapon in hand (holster gate). Real sdc_gearfx + sdc_ue + sdc_log; sdc_items
-- and sdc_pawnstate are stubs (pawnstate.others as the real one picks other
-- players' characters).
-- usage: lua mock_gearfx_laser.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what) end
end

-- ------------------------------------------------------------ log capture
local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = tostring(s) end
local function out(s) real_print(s) end
check = function(cond, what)
    if cond then passed = passed + 1; out("  ok   " .. what) else fails = fails + 1; out("  FAIL " .. what) end
end
local function count_lines(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat) then n = n + 1 end end
    return n
end
local function last_line(pat)
    for i = #lines, 1, -1 do if lines[i]:find(pat) then return lines[i] end end
    return nil
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
local registry = {}          -- class -> list
local by_path = {}

local function name_obj(s) return { ToString = function() return s end } end
local function new_obj(cls, short, props, methods)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }
    setmetatable(o, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return rawget(t, "_p")[k]
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/L.L:PersistentLevel." .. self._short end
function Obj:GetFName() return name_obj(self._short) end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return name_obj(c) end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOwner() return self._p.__owner end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end

local function param(v) return { get = function() return v end, set = function(_, x) v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, cb, post)
    hooks[path] = hooks[path] or {}
    table.insert(hooks[path], cb)
    return 1, 2
end
function FindAllOf(cls) return registry[cls] or {} end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path) return by_path[path] end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay() return 1 end
local loops = {}
function LoopInGameThreadWithDelay(ms, f) loops[#loops + 1] = { ms = ms, f = f }; return #loops end
function LoopAsync() end
function FName(s) return name_obj(s) end

-- a BP hook as UE4SS calls it (post-run, one callback); never returns a value
local function fire(path, ...)
    local n = 0
    for _, cb in ipairs(hooks[path] or {}) do
        local r = cb(...)
        assert(r == nil, "hook returned a value: " .. path)
        n = n + 1
    end
    return n
end

-- ------------------------------------------------------------ world: traces
local walls = {}   -- X planes; the ground is Z = 0
local traces = {}
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {})
by_path["/Script/Engine.Default__KismetSystemLibrary"] = ksl
ksl._m.LineTraceSingle = function(self, wc, a, b, ch, complex, ignore, dbg, hit, ignore_self)
    assert(type(hit) == "table", "out hit must be a table")
    traces[#traces + 1] = { a = a, b = b, ch = ch, ignore = ignore }
    local best = nil
    local function try(t) if t and t >= 1e-6 and t <= 1 + 1e-9 and (not best or t < best) then best = t end end
    if a.Z > 0 and b.Z <= 0 then try(a.Z / (a.Z - b.Z)) end
    for _, w in ipairs(walls) do
        if a.X ~= b.X and (a.X - w) * (b.X - w) <= 0 then try((w - a.X) / (b.X - a.X)) end
    end
    if not best then return false end
    local p = { X = a.X + (b.X - a.X) * best, Y = a.Y + (b.Y - a.Y) * best, Z = a.Z + (b.Z - a.Z) * best }
    hit.ImpactPoint, hit.Location = p, p
    return true
end

-- ------------------------------------------------------------ stubs
local equipped = {}   -- [pawn] = { { actor =, slot = } }
package.loaded["sdc_items"] = { equipped_of = function(p) return equipped[p] or {} end }
local S = { role = "host", remote_pcs = {} }
-- sdc_pawnstate.others: host = every character not locally controlled,
-- client = simulated proxies
package.loaded["sdc_pawnstate"] = { others = function()
    local out = {}
    for _, p in ipairs(registry["BP_PlayerCharacter_C"] or {}) do
        if p._valid then
            if S.role == "host" then
                if not p:IsLocallyControlled() then out[#out + 1] = p end
            elseif p._p.Role == 1 then
                out[#out + 1] = p
            end
        end
    end
    return out
end }

local log = require("sdc_log")
local ue = require("sdc_ue")
local gearfx = require("sdc_gearfx")

-- ------------------------------------------------------------ actors
local function comp(cls, short, vis, extra)
    local c = new_obj(cls, short, extra or {}, {})
    c._vis = vis ~= false
    c._m.IsVisible = function(self) return self._vis end
    c._m.SetVisibility = function(self, v, prop) self._vis = v; self._setvis = (self._setvis or 0) + 1 end
    return c
end

local function make_module(cls, short, weapon, state, parts)
    local m = new_obj(cls, short, { __owner = weapon,
        ActivateState = { TagName = FName("Jig.AttachmentActivate." .. state) } }, {})
    m._m.Jig_SetAttachmentActiveState = function(self) self._state_calls = (self._state_calls or 0) + 1 end
    for name, c in pairs(parts) do m._p[name] = c end
    return m
end

local function laser_ns(short, loc, active)
    local ns = comp("NiagaraComponent", short, true, {})
    ns._m.K2_GetComponentLocation = function() return loc end
    ns._m.IsActive = function() return active end
    ns._m.SetVectorParameter = function(self, name, v)
        assert(name:ToString() == "User.Beam End")
        self._beam = { X = v.X, Y = v.Y, Z = v.Z }
        self._sets = (self._sets or 0) + 1
    end
    return ns
end

local function array_of(list)
    return { ForEach = function(self, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end }
end

local function make_weapon(cls, short, pawn, modules_list)
    local pc = new_obj("BP_JigPickupComponent_C", short .. "_pc", { InstalledAttachments = array_of(modules_list) }, {})
    local w = new_obj(cls, short, { __owner = pawn, BP_JigPickupComponent = pc }, {})
    pc._p.__owner = w
    return w, pc
end

local function make_pawn(short, opts)
    local helper = new_obj("BP_JigHelperComp_C", short .. "_helper",
        { ActiveWeapon = { TagName = FName(opts.active or "None") } }, {})
    local p = new_obj("BP_PlayerCharacter_C", short, { BP_JigHelperComp = helper, Role = opts.role or 3,
        __loc = opts.loc, BaseEyeHeight = 160 }, {})
    p._m.IsLocallyControlled = function() return opts.is_local == true end
    p._m.GetPawnViewLocation = function() local l = p._p.__loc; return { X = l.X, Y = l.Y, Z = l.Z + 160 } end
    p._m.GetBaseAimRotation = function() return p._p.__base_aim end
    return p, helper
end
local function set_active(helper, slot) helper._p.ActiveWeapon = { TagName = FName(slot) } end

-- client "Bob": MP5 (primary) with a laser sight, USP (sidearm) with a laser/light combo
local P, PH = make_pawn("BP_PlayerCharacter_C_2147473470", { loc = { X = 10000, Y = 0, Z = 0 }, active = "Jig.PlayerSlot.PrimaryWeapon" })
local L_NS = laser_ns("NS_LaserSight", { X = 10030, Y = 25, Z = 130 }, true)
local L_PL = comp("PointLightComponent", "PointLight", true, { Intensity = 250 })
local mods_mp5, mods_usp = {}, {}
local MP5 = make_weapon("BP_BlackOpsMP5Pickup_C", "BP_BlackOpsMP5Pickup_C_1", P, mods_mp5)
local L = make_module("BP_SmallTacticalLaserSightLocalAttachment_C", "Laser_1", MP5, "StateADS", { NS_LaserSight = L_NS, PointLight = L_PL })
local SCOPE = new_obj("BP_RedDotSightLocalAttachment_C", "Scope_1", { __owner = MP5 }, {})
rawset(SCOPE, "GetPropertyValue", function(self, n) self._p.__touched = true; return self._p[n] end)
mods_mp5[1], mods_mp5[2] = SCOPE, L
local C_NS = laser_ns("NS_LaserSight", { X = 10030, Y = 20, Z = 120 }, false)
local C_PL = comp("PointLightComponent", "PointLight", false, { Intensity = 0 })   -- invisible by design
local C_SL = comp("SpotLightComponent", "SpotLight", true, { Intensity = 115000 })
local USP = make_weapon("BP_BlackOpsUSPPickup_C", "BP_BlackOpsUSPPickup_C_1", P, mods_usp)
local C = make_module("BP_TacticalLaserLightComboLocalAttachment_C", "Combo_1", USP, "State2",
    { NS_LaserSight = C_NS, PointLight = C_PL, SpotLight = C_SL })
mods_usp[1] = C
local HAT = new_obj("BP_CapPickup_C", "Cap_1", { __owner = P }, {})
equipped[P] = { { actor = MP5, slot = "Jig.PlayerSlot.PrimaryWeapon" }, { actor = USP, slot = "Jig.PlayerSlot.SidearmWeapon" },
                { actor = HAT, slot = "Jig.PlayerSlot.Headwear" } }
-- the client's controller on the host
local CAM = new_obj("PlayerCameraManager", "PlayerCameraManager_1", {}, {})
CAM._m.GetCameraLocation = function() return CAM._p.__loc end
CAM._m.GetCameraRotation = function() return CAM._p.__rot end
local PC = new_obj("BP_PlayerController_C", "BP_PlayerController_C_2147479530", { PlayerCameraManager = CAM }, {})
PC._m.GetControlRotation = function() return PC._p.__cr end
P._p.Controller = PC

-- the host's own character with its own laser
local H, HH = make_pawn("BP_PlayerCharacter_C_host", { loc = { X = 0, Y = 0, Z = 0 }, is_local = true, active = "None" })
local HL_NS = laser_ns("NS_LaserSight", { X = 30, Y = 25, Z = 130 }, true)
local mods_h = {}
local HMP5 = make_weapon("BP_M4Pickup_C", "BP_M4Pickup_C_1", H, mods_h)
local HL = make_module("BP_SmallTacticalLaserSightLocalAttachment_C", "Laser_host", HMP5, "StateADS", { NS_LaserSight = HL_NS })
mods_h[1] = HL
equipped[H] = { { actor = HMP5, slot = "Jig.PlayerSlot.PrimaryWeapon" } }

local LASER_PATH = "/Game/Inventory/Items/LocalAttachments/Tactical/BP_SmallTacticalLaserSightLocalAttachment.BP_SmallTacticalLaserSightLocalAttachment_C:Event_Laser"
local COMBO_PATH = "/Game/Inventory/Items/LocalAttachments/Tactical/BP_TacticalLaserLightComboLocalAttachment.BP_TacticalLaserLightComboLocalAttachment_C:Event_Laser"

local function near(a, b, eps) return a and b and math.abs(a.X - b.X) < (eps or 1) and math.abs(a.Y - b.Y) < (eps or 1) and math.abs(a.Z - b.Z) < (eps or 1) end
local function laser(m, path) advance(0.02); return fire(path or LASER_PATH, param(m)) end
local function gate_tick() for _, l in ipairs(loops) do l.f() end end

-- ============================================================ setup
out("== setup (host)")
gearfx.init(S)
gearfx.host_tick()
check(hooks[LASER_PATH] == nil and #loops == 0, "host with nobody connected: no laser hook, no gate loop")
S.remote_pcs = { PC }
gearfx.host_tick()
check(hooks[LASER_PATH] and #hooks[LASER_PATH] == 1, "laser hook registered on the host too")
check(hooks[COMBO_PATH] and #hooks[COMBO_PATH] == 1, "combo laser hook registered")
check(#loops == 1 and loops[1].ms == 100, "holster gate loop every 100 ms")
check(count_lines("holster gate: other players") == 1, "gate start logged")
gearfx.host_tick()
check(#hooks[LASER_PATH] == 1 and #loops == 1, "second tick registers nothing again")

-- ============================================================ aim: host
out("== host sees the client's laser (weapon in hand)")
walls = { 11000 }
CAM._p.__loc, CAM._p.__rot = { X = 9700, Y = 40, Z = 210 }, { Pitch = 0, Yaw = 0, Roll = 0 }
PC._p.__cr = { Pitch = 0, Yaw = 0, Roll = 0 }
local before = #traces
laser(L)
check(near(L_NS._beam, { X = 11000, Y = 40, Z = 210 }), "beam end = the owner's crosshair point on the wall (owner camera)")
check(#traces - before == 2, "two traces like LaserEndPoint (camera ray, then module -> hit)")
check(traces[before + 1].ch == 6 and traces[before + 2].ch == 6, "the module's own trace channel (6)")
local ign = traces[before + 1].ignore
check(ign and ign[1] == L and ign[2] == MP5 and ign[3] == P, "ignores module, weapon, character")
check(near(traces[before + 2].a, { X = 10030, Y = 25, Z = 130 }), "second trace starts at NS_LaserSight")
check(count_lines("laser of BP_PlayerCharacter_C_2147473470 on BP_BlackOpsMP5Pickup_C %(BP_SmallTacticalLaserSightLocalAttachment_C%): aim from owner camera %(server copy%)") == 1,
    "per-class source line (owner camera)")
laser(L)
check(count_lines("laser of .* on BP_BlackOpsMP5Pickup_C") == 1, "logged once per weapon class and source")

-- the same frame: the 0.01 s timer fired twice -> no second trace
before = #traces
local sets = L_NS._sets
fire(LASER_PATH, param(L))
check(#traces == before and L_NS._sets == sets + 1, "same-frame repeat rewrites the end without tracing")

out("== host: camera copy unusable -> control rotation")
CAM._p.__loc, CAM._p.__rot = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }   -- never filled
walls = {}
PC._p.__cr = { Pitch = -10, Yaw = 0, Roll = 0 }
laser(L)
local expect_x = 10000 + 160 / math.tan(math.rad(10))
check(near(L_NS._beam, { X = expect_x, Y = 0, Z = 0 }, 2), "aimed 10 deg down: dot on the ground in front (control rotation from the eyes)")
check(count_lines("on BP_BlackOpsMP5Pickup_C .*aim from control rotation %(server copy%)") == 1, "per-class line for the fallback source")
CAM._p.__loc, CAM._p.__rot = { X = 9700, Y = 0, Z = 210 }, { Pitch = 0, Yaw = 90, Roll = 0 }   -- near, disagrees
PC._p.__cr = { Pitch = 0, Yaw = 0, Roll = 0 }
walls = { 11000 }
laser(L)
check(near(L_NS._beam, { X = 11000, Y = 0, Z = 160 }), "camera copy that disagrees with the control rotation is not used")
-- pitch over 180 (compressed axis) still agrees
CAM._p.__loc, CAM._p.__rot = { X = 9700, Y = 0, Z = 210 }, { Pitch = -10, Yaw = 0, Roll = 0 }
PC._p.__cr = { Pitch = 350, Yaw = 360, Roll = 0 }
walls = {}
laser(L)
check(L_NS._beam and L_NS._beam.Z < 1 and L_NS._beam.X > 10000, "350 / -10 pitch treated as the same aim")

out("== host: the host's own laser is the game's")
local hsets = HL_NS._sets
laser(HL)
check(HL_NS._sets == hsets, "local character's laser untouched")
-- the next ~100 calls a second: skipped by the module's address, no owner lookup
local owner_calls = 0
rawset(HL, "GetOwner", function(self) owner_calls = owner_calls + 1; return self._p.__owner end)
for _ = 1, 10 do laser(HL) end
check(owner_calls == 0 and HL_NS._sets == hsets, "own laser: no owner lookup within a second")
advance(1.0)
laser(HL)
check(owner_calls == 1 and HL_NS._sets == hsets, "looked up again after a second, still untouched")
rawset(HL, "GetOwner", nil)
-- nobody connected any more: the client's laser is not touched either
S.remote_pcs = {}
sets = L_NS._sets
laser(L)
check(L_NS._sets == sets, "host alone: Event_Laser does nothing")
S.remote_pcs = { PC }

-- ============================================================ holster gate
out("== holster gate (host)")
walls = { 11000 }
CAM._p.__loc, CAM._p.__rot = { X = 9700, Y = 40, Z = 210 }, { Pitch = 0, Yaw = 0, Roll = 0 }
PC._p.__cr = { Pitch = 0, Yaw = 0, Roll = 0 }
advance(1.5)
gate_tick()
check(L_NS._vis and L_PL._vis, "MP5 in hand: its laser shown")
check(not C_NS._vis and not C_SL._vis, "USP holstered: combo laser + light hidden")
check(not C_PL._vis and (C_PL._setvis or 0) == 0, "a part invisible by design is not touched")
check(count_lines("holster: BP_PlayerCharacter_C_2147473470 put BP_BlackOpsUSPPickup_C away: BP_TacticalLaserLightComboLocalAttachment_C light/laser hidden here %(module state State2, laser off, light on; first look%)") == 1,
    "holster line with the module state")
check(not SCOPE._p.__touched, "other modules ignored")
check(HL_NS._vis == true, "the host's own holstered laser untouched (local player)")

out("== swap primary -> sidearm")
local n_lines = #lines
set_active(PH, "Jig.PlayerSlot.SidearmWeapon")
advance(0.1)
gate_tick()
check(not L_NS._vis and not L_PL._vis, "MP5 to the back: laser + glow hidden at once")
check(C_NS._vis and C_SL._vis, "USP drawn: combo laser + light shown again")
check(not C_PL._vis, "design-invisible part stays invisible after the draw")
check(last_line("put BP_BlackOpsMP5Pickup_C away") and last_line("put BP_BlackOpsMP5Pickup_C away"):find("module state StateADS, laser on; slot Jig.PlayerSlot.PrimaryWeapon %-> Jig.PlayerSlot.SidearmWeapon", 1, false) ~= nil,
    "holster line names the swap and the owner's state")
check(last_line("drew BP_BlackOpsUSPPickup_C") ~= nil, "draw line for the USP")
check(#lines - n_lines == 2, "one line per module change")
sets = L_NS._sets
laser(L)
check(L_NS._sets == sets and not L_NS._vis, "holstered MP5's Event_Laser: no beam, stays hidden")
check(L._state_calls == nil and C._state_calls == nil, "module states never changed by the mod")
check(L._p.ActivateState.TagName:ToString() == "Jig.AttachmentActivate.StateADS", "owner's StateADS kept on the module")
check(C_SL._p.Intensity == 115000, "light intensity (battery state) untouched")

out("== swap back sidearm -> primary")
set_active(PH, "Jig.PlayerSlot.PrimaryWeapon")
advance(0.1)
gate_tick()
check(L_NS._vis and L_PL._vis, "MP5 drawn again: laser shown in the owner's state")
check(not C_NS._vis and not C_SL._vis, "USP holstered again: hidden")
sets = L_NS._sets
laser(L)
check(L_NS._sets == sets + 1 and near(L_NS._beam, { X = 11000, Y = 40, Z = 210 }), "MP5 beam aims again")

out("== laser hook reacts before the gate poll")
set_active(PH, "Jig.PlayerSlot.SidearmWeapon")
sets = L_NS._sets
laser(L)
check(not L_NS._vis and L_NS._sets == sets, "slot changed, no poll yet: Event_Laser hides the beam itself")
check(last_line("put BP_BlackOpsMP5Pickup_C away"):find("laser of a weapon not in hand", 1, true) ~= nil, "logged by the laser hook")
set_active(PH, "Jig.PlayerSlot.PrimaryWeapon")
laser(L)
check(L_NS._vis and L_NS._sets == sets + 1, "drawn, no poll yet: Event_Laser shows and aims it")

-- 0.8.1 host log: a friend's rifle on the back, its laser left in StateADS,
-- Event_Laser 100/s for 26 minutes at 12-20 ms/s (owner lookup, slot and
-- visibility checks on every call)
out("== holstered laser left in StateADS: Event_Laser skipped until drawn")
set_active(PH, "Jig.PlayerSlot.SidearmWeapon")
advance(0.1)
gate_tick()
check(not L_NS._vis and gearfx.gate.tags[P._addr] == "Jig.PlayerSlot.SidearmWeapon", "MP5 to the back, seen by the gate: hidden")
local owner_n, vis_n = 0, 0
rawset(L, "GetOwner", function(self) owner_n = owner_n + 1; return self._p.__owner end)
local real_is_vis = L_NS._m.IsVisible
L_NS._m.IsVisible = function(self) vis_n = vis_n + 1; return real_is_vis(self) end
sets = L_NS._sets
n_lines = #lines
for _ = 1, 100 do advance(0.01); fire(LASER_PATH, param(L)) end   -- one second of the 0.01 s timer
check(owner_n >= 2 and owner_n <= 4, "100 calls in a second: owner looked up " .. owner_n .. " times (every 0.5 s), not 100")
check(vis_n == owner_n, "visibility checked only on those look-ups (" .. vis_n .. ")")
check(L_NS._sets == sets and not L_NS._vis, "no beam written, stays hidden")
local away_rec = gearfx.gate.away[L._addr]
check(away_rec and away_rec.n >= 95 and away_rec.slot == "Jig.PlayerSlot.PrimaryWeapon",
    "skip record by module address with the weapon's slot (" .. tostring(away_rec and away_rec.n) .. " calls skipped)")
check(#lines == n_lines, "nothing logged while it stays away")
advance(0.6)
fire(LASER_PATH, param(L))       -- a fresh look-up: the record is new from here
check(owner_n >= 3, "looked up again after 0.5 s")
-- drawn: the gate's next poll ends the skip, never a wrong beam meanwhile
set_active(PH, "Jig.PlayerSlot.PrimaryWeapon")
advance(0.01)
fire(LASER_PATH, param(L))
check(not L_NS._vis and L_NS._sets == sets, "drawn, gate not polled yet: still skipped, parts still hidden")
advance(0.05)
gate_tick()
check(L_NS._vis and L_PL._vis, "the gate's poll shows the drawn MP5's laser")
check(gearfx.gate.away[L._addr] == nil, "skip record dropped on the draw")
check((last_line("drew BP_BlackOpsMP5Pickup_C") or ""):find("laser call%(s%) skipped while away") ~= nil, "draw line counts the skipped calls")
laser(L)
check(L_NS._sets == sets + 1 and near(L_NS._beam, { X = 11000, Y = 40, Z = 210 }), "the next Event_Laser aims the beam again")
laser(L)
check(L_NS._sets == sets + 2, "in hand: every call aims (no skip)")
rawset(L, "GetOwner", nil)
L_NS._m.IsVisible = real_is_vis

out("== gate loop down: the hook's own look-up every 0.5 s notices the draw")
set_active(PH, "Jig.PlayerSlot.SidearmWeapon")
advance(0.1)
gate_tick()
laser(L)
check(gearfx.gate.away[L._addr] ~= nil, "holstered: skip record")
set_active(PH, "Jig.PlayerSlot.PrimaryWeapon")   -- no gate poll from here on
sets = L_NS._sets
laser(L)
check(not L_NS._vis and L_NS._sets == sets, "within 0.5 s: skipped")
advance(0.6)
laser(L)
check(L_NS._vis and L_NS._sets == sets + 1, "after 0.5 s: looked up again, shown and aimed without the gate")
check(gearfx.gate.away[L._addr] == nil, "skip record dropped")
advance(0.1)
gate_tick()

out("== weapon moved to another slot while away, drawn there")
set_active(PH, "Jig.PlayerSlot.SidearmWeapon")
advance(0.1)
gate_tick()
laser(L)
check(gearfx.gate.away[L._addr] and gearfx.gate.away[L._addr].slot == "Jig.PlayerSlot.PrimaryWeapon", "skip record for the primary slot")
local eq_saved = equipped[P]
equipped[P] = { { actor = MP5, slot = "Jig.PlayerSlot.SecondaryWeapon" }, { actor = USP, slot = "Jig.PlayerSlot.SidearmWeapon" } }
set_active(PH, "Jig.PlayerSlot.SecondaryWeapon")
advance(0.1)
gate_tick()
check(L_NS._vis and gearfx.gate.away[L._addr] == nil, "the gate shows it in its new slot and drops the skip")
sets = L_NS._sets
laser(L)
check(L_NS._sets == sets + 1, "its beam is aimed at once")
equipped[P] = eq_saved
set_active(PH, "Jig.PlayerSlot.PrimaryWeapon")
advance(0.1)
gate_tick()
check(L_NS._vis and not C_NS._vis and not C_SL._vis, "back to the primary: MP5 shown, USP hidden")

out("== hands empty, module re-created by the game while holstered")
set_active(PH, "None")
advance(0.1)
gate_tick()
check(not L_NS._vis and not C_NS._vis and not C_SL._vis, "nothing in hand: every module hidden")
laser(L)
check(gearfx.gate.away[L._addr] ~= nil, "hands empty: the MP5 laser skipped too")
-- ProcessAttachments replaced the laser module with a new (visible) actor
local L2_NS = laser_ns("NS_LaserSight", { X = 10030, Y = 25, Z = 130 }, true)
local L2 = make_module("BP_SmallTacticalLaserSightLocalAttachment_C", "Laser_2", MP5, "StateADS", { NS_LaserSight = L2_NS })
mods_mp5[2] = L2
L._valid = false
advance(0.1)
gate_tick()
check(L2_NS._vis, "no slot change: new module not seen before the sweep")
advance(1.0)
gate_tick()
check(not L2_NS._vis, "sweep hides the re-created module of the holstered weapon")
check(gearfx.gate.hidden[L._addr] == nil and gearfx.gate.hidden[L2._addr] ~= nil, "record of the destroyed module dropped")
check(gearfx.gate.away[L._addr] == nil, "skip record of the destroyed module dropped")

out("== client sees the host (base aim)")
S.role = "client"
-- a client's view: the host's character is simulated, no controller
local Q, QH = make_pawn("BP_PlayerCharacter_C_hostchar", { loc = { X = 0, Y = 5000, Z = 0 }, role = 1, active = "Jig.PlayerSlot.SidearmWeapon" })
Q._p.__base_aim = { Pitch = 350, Yaw = 90, Roll = 0 }   -- RemoteViewPitch byte -> 0..360
local Q_NS = laser_ns("NS_LaserSight", { X = 25, Y = 5030, Z = 125 }, true)
local mods_q = {}
local QW = make_weapon("BP_BlackOpsUSPPickup_C", "BP_BlackOpsUSPPickup_C_2", Q, mods_q)
local QL = make_module("BP_TacticalLaserLightComboLocalAttachment_C", "Combo_2", QW, "StateADS", { NS_LaserSight = Q_NS })
mods_q[1] = QL
equipped[Q] = { { actor = QW, slot = "Jig.PlayerSlot.SidearmWeapon" } }
P._p.Role = 3   -- the host's copy of the client is not this client's: ignored by the gate as non-simulated
walls = {}
laser(QL, COMBO_PATH)
check(near(Q_NS._beam, { X = 0, Y = 5000 + 160 / math.tan(math.rad(10)), Z = 0 }, 2), "host aiming 10 deg down along +Y: dot on the ground ahead")
check(traces[#traces].ch == 5, "combo module's trace channel (5)")
check(count_lines("on BP_BlackOpsUSPPickup_C %(BP_TacticalLaserLightComboLocalAttachment_C%): aim from base aim %(RemoteViewPitch %+ actor yaw%), beam from the module to the aim point %(client%)") == 1,
    "per-class line for the client source")

out("== client: holster / draw of the host's sidearm")
advance(0.3)
gate_tick()
check(Q_NS._vis, "host's USP in hand: shown")
set_active(QH, "Jig.PlayerSlot.PrimaryWeapon")
advance(0.1)
gate_tick()
check(not Q_NS._vis, "host switched to the primary: USP laser hidden on the client")
local q_sets = Q_NS._sets
for _ = 1, 20 do advance(0.01); fire(COMBO_PATH, param(QL)) end
check(Q_NS._sets == q_sets and gearfx.gate.away[QL._addr] and gearfx.gate.away[QL._addr].n >= 18,
    "client: the host's holstered laser skipped too")
set_active(QH, "Jig.PlayerSlot.SidearmWeapon")
advance(0.1)
gate_tick()
check(Q_NS._vis, "host drew the USP again: shown")
check(gearfx.gate.away[QL._addr] == nil, "client: skip ended by the draw")
q_sets = Q_NS._sets
laser(QL, COMBO_PATH)
check(Q_NS._sets == q_sets + 1, "client: the drawn USP's beam aimed again")
-- holstered again before the host leaves view
set_active(QH, "Jig.PlayerSlot.PrimaryWeapon")
advance(0.1)
gate_tick()
laser(QL, COMBO_PATH)
check(gearfx.gate.away[QL._addr] ~= nil, "client: skip record again")

out("== pruning and failures")
Q._valid = false
advance(1.1)
gate_tick()
local left = 0
for _ in pairs(gearfx.gate.tags) do left = left + 1 end
check(gearfx.gate.tags[Q._addr] == nil, "gone character's records dropped")
check(gearfx.gate.away[QL._addr] == nil, "gone character's skip records dropped")
-- a module whose owner lookup throws: the hook swallows it
local BAD = make_module("BP_SmallTacticalLaserSightLocalAttachment_C", "Laser_bad", nil, "StateADS", {})
rawset(BAD, "GetOwner", function() error("stale object") end)
local okb = pcall(fire, LASER_PATH, param(BAD))
check(okb, "hook never throws")
-- the host alone again: every record goes, skip records too
S.role, S.remote_pcs = "host", {}
gate_tick()
gearfx.gate.away[12345] = { t = T, pk = 1, slot = "Jig.PlayerSlot.PrimaryWeapon", n = 0 }   -- the only record left
gate_tick()
check(next(gearfx.gate.away) == nil, "host alone: skip records dropped")
S.role = "standalone"
sets = Q_NS._sets
check(pcall(gate_tick) and pcall(laser, L2), "standalone: gate and hook do nothing")

io.stdout:write(string.format("gearfx laser: %d passed, %d failed\n", passed, fails))
real_print(fails == 0 and string.format("%d checks, ALL OK", passed) or string.format("%d checks, %d FAILED", passed + fails, fails))
os.exit(fails == 0 and 0 or 1)
