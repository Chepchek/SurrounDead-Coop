-- 3 and 4 players in one vehicle (sdc_vehseats + sdc_vehicles): a seat per
-- player by number, "Seat N of M", the driver's exit moving nobody, the
-- seat key (the wheel when free, else the next free seat), exits by seat
-- (rear doors), deaths, disconnects, a full car (the host too), the host's
-- get-in again in its own seat, 2-seat classes, switched-off rows, the
-- seats switch, older clients (no "s2"), VSTATE / VOCC per client, the
-- client side, the check after a move to the wheel, sdcoop_seat on the host and in single
-- player. Harness as mock_vehicles.lua (the game's vehicle functions as far
-- as they touch player 0 and the vehicle).
-- usage: lua mock_vehicles_seats.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, passes = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
local registry = {}
local by_path = {}
local function reg(cls, o)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
end
local function new_obj(cls, short, props, methods, also)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }
    setmetatable(o, Obj)
    reg(cls, o)
    for _, c in ipairs(also or {}) do reg(c, o) end
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    local p = rawget(t, "_p")[k]
    if p ~= nil then return p end
    return nil
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName()
    if rawget(self, "_full") then return rawget(self, "_full") end
    return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short
end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return self._outer end
function Obj:GetOwner() return self._owner end
function Obj:SetOwner(o) self._owner = o end
function Obj:K2_DestroyActor() self._valid = false end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end
function Obj:GetAttachParentActor() return self._parent end
local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end
local function tarray(items)
    local a = { _items = items or {} }
    return setmetatable(a, {
        __index = function(t, k)
            if type(k) == "number" then
                local it = rawget(t, "_items")
                while #it < k do it[#it + 1] = false end
                return it[k]
            end
            if k == "GetArrayNum" then return function(s) return #rawget(s, "_items") end end
            if k == "Empty" then return function(s) rawset(s, "_items", {}) end end
            if k == "ForEach" then
                return function(s, cb) for i, v in ipairs(rawget(s, "_items")) do cb(i, { get = function() return v end }) end end
            end
            return nil
        end,
        __newindex = function(t, k, v) rawget(t, "_items")[k] = v end,
    })
end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = { pre = pre, post = post }; return 1, 2 end
function FindAllOf(cls) local l = {}; for _, o in ipairs(registry[cls] or {}) do if o._valid then l[#l + 1] = o end end; return l end
function FindFirstOf(cls) return FindAllOf(cls)[1] end
function StaticFindObject(path) return by_path[path] end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(ms, f) delayed[#delayed + 1] = f; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay(ms, f) delayed[#delayed + 1] = f end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end
setmetatable(by_path, { __index = function(_, k)
    if k:find(":") then return new_obj("Function", k) end
    return nil
end })

local net_mode = "host"
local timers = {}
local function tkey(o, fn) return tostring(o._addr) .. "|" .. fn end
-- KismetSystemLibrary; CapsuleTraceSingle at a door: a "wall" within the capsule
local walls, traces = {}, {}
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return net_mode == "standalone" end,
    IsServer = function() return net_mode == "host" end,
    K2_IsTimerActive = function(_, o, fn) return timers[tkey(o, fn)] == true end,
    K2_SetTimer = function(_, o, fn) timers[tkey(o, fn)] = true end,
    K2_ClearTimer = function(_, o, fn) timers[tkey(o, fn)] = nil end,
    CapsuleTraceSingle = function(_, wc, s, e, r, hh, chan, cx, ignore)
        traces[#traces + 1] = { wc = wc, at = s, r = r, half = hh, ignore = ignore }
        for _, w in ipairs(walls) do
            if math.abs(w.X - s.X) <= r and math.abs(w.Y - s.Y) <= r then return true end
        end
        return false
    end,
})
rawset(by_path, "/Script/Engine.Default__KismetSystemLibrary", ksl)
local controllers = {}
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {
    GetPlayerController = function(_, wc, i) return controllers[i + 1] end,
    GetNumPlayerControllers = function() return #controllers end,
})
rawset(by_path, "/Script/Engine.Default__GameplayStatics", gps)
local montage = new_obj("AnimMontage", "Chr_SitInCar_Montage", {}, {})
rawset(by_path, "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage", montage)
local floor_m = new_obj("AnimMontage", "Chr_SittingFloor_Montage", {}, {})
rawset(by_path, "/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage", floor_m)

-- ------------------------------------------------------------ modules
local cfg = require("sdc_config")
cfg.load(os.tmpname())
cfg.set("player_name", "Host")
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text) toasts[#toasts + 1] = text end
local errs = {}
local err0 = log.err
log.err = function(fmt, ...) errs[#errs + 1] = string.format(fmt, ...); return err0(fmt, ...) end
local ctx = require("sdc_ctx")
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...)
    local args = { ... }
    if kind == "VSTATE" and args[1] == "*" then
        for i = 2, #args, 12 do sent[#sent + 1] = { to = pc, kind = kind, args = table.move(args, i, i + 11, 1, {}) } end
        return true
    end
    if kind == "VOCC" and args[1] == "*" then
        for i = 2, #args, 5 do sent[#sent + 1] = { to = pc, kind = kind, args = table.move(args, i, i + 4, 1, {}) } end
        return true
    end
    sent[#sent + 1] = { to = pc, kind = kind, args = args }
    return true
end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
net.broadcast = function(pcs, kind, ...) for _, pc in ipairs(pcs) do net.send_to(pc, kind, ...) end end
local function last_sent(kind, to)
    for i = #sent, 1, -1 do
        local s = sent[i]
        if s.kind == kind and (to == nil or s.to == to) then return s end
    end
    return nil
end
local function count_sent(kind, to)
    local n = 0
    for _, s in ipairs(sent) do if s.kind == kind and (to == nil or s.to == to) then n = n + 1 end end
    return n
end
local function deliver(kind, args, from_pc)
    local h = net.handlers[kind]
    assert(h, "no handler " .. kind)
    h(args, from_pc)
end

local V = require("sdc_vehicles")
local VS = V.vseats
local S = { role = "host", remote = {}, remote_pcs = {}, client = nil }
V.install(S)
-- (the driver's exit moves nobody: a passenger takes the wheel with its seat
-- key, seat_key below; W / K check that and the key itself)
local commands = {}
V.register_commands(function(name, help, fn) commands[name] = fn; return help end)
local function seat_cmd(...)
    local out = {}
    commands.sdcoop_seat({ ... }, function(s) out[#out + 1] = s end)
    return out
end

-- ------------------------------------------------------------ world
local next_pid = 100
local CHAR_HOOK = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:VehicleInteraction"
local function new_char(name, loc, is_local)
    local cmc = new_obj("CharacterMovementComponent", name .. "_CMC", { MovementMode = 1, bServerAcceptClientAuthoritativePosition = true }, {})
    cmc._m.SetMovementMode = function(s, m) s._p.MovementMode = m end
    local dc = new_obj("VehicleDrivingComponent_C", name .. "_VDC", {}, {})
    local helper = new_obj("BP_JigHelperComp_C", name .. "_Helper", {}, {})
    local ch = new_obj("BP_PlayerCharacter_C", name, { __loc = loc, CharacterMovement = cmc, VehicleDrivingComponent = dc,
        BP_JigHelperComp = helper, ["InVehicle?"] = false, ["PlayerDead?"] = false }, {})
    dc._outer = ch
    helper._owner = ch
    ch._local = is_local
    next_pid = next_pid + 1
    local pid = next_pid
    ch._pid = pid
    local ps = new_obj("PlayerState", name .. "_PS", {}, { GetPlayerId = function() return pid end, GetPlayerName = function() return name end })
    -- channel 3 = Visibility (the interact trace), 4 = Camera
    local cap = new_obj("CapsuleComponent", name .. "_Capsule", { cam = 2 }, {})
    cap._m.UnWeldFromParent = function() ch._welded = false; ch._unwelds = (ch._unwelds or 0) + 1 end
    cap._m.GetCollisionResponseToChannel = function(c, n) if n == 4 then return c._p.cam end return 2 end
    cap._m.SetCollisionResponseToChannel = function(c, n, r) if n == 4 then c._p.cam = r end end
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { vis = 2, cam = 2, bOnlyAllowAutonomousTickPose = not is_local }, {})
    mesh._m.GetCollisionResponseToChannel = function(m, c) if c == 3 then return m._p.vis elseif c == 4 then return m._p.cam end return 2 end
    mesh._m.SetCollisionResponseToChannel = function(m, c, r) if c == 3 then m._p.vis = r elseif c == 4 then m._p.cam = r end end
    ch._p.PlayerState, ch._p.CapsuleComponent, ch._p.Mesh = ps, cap, mesh
    ch._m.IsLocallyControlled = function(s) return s._local == true end
    ch._m.K2_AttachToActor = function(s, parent, _sock, _l, _r, _sc, weld) s._parent = parent; s._welded = weld == true end
    ch._m.K2_DetachFromActor = function(s) s._parent = nil; s._welded = false end
    ch._m.StopMontage = function(s, m, inc) s._stop_everywhere = (s._stop_everywhere or 0) + 1 end
    ch._m.K2_SetActorLocationAndRotation = function(s, l, r) s._p.__loc = { X = l.X, Y = l.Y, Z = l.Z }; s._rot = r end
    ch._m.PlayMontage = function(s, m) s._montage = m end
    ch._m.PlayAnimMontage = function(s, m) s._montage = m end
    ch._m.GetCurrentMontage = function(s) return s._montage end
    ch._m.StopAnimMontage = function(s) s._montage = nil end
    ch._m.SetWeaponsAndBackpackVisibility = function(s, hide) s._weapons_hidden = hide end
    ch._m.ResetVehicleCameraArmLength = function(s) s._cams = (s._cams or 0) + 1 end
    ch._m.VehicleInteraction = function(s, enter, vref)
        s._p["InVehicle?"] = enter
        if enter then
            s._p.VehicleDrivingComponent._p.Vehicle = vref; cmc._p.MovementMode = 0; s._weapons_hidden = true
        else
            s._weapons_hidden = false
        end
        local h = hooks[CHAR_HOOK]
        if h and h.pre then h.pre(param(s), param(enter), param(vref)) end
    end
    return ch
end

local host_ch = new_char("HostChar", { X = 0, Y = 0, Z = 100 }, true)
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_ch, Player = new_obj("LocalPlayer", "LP", {}, {}) },
    { IsLocalController = function() return true end }, { "PlayerController" })
host_ch._p.Controller = host_pc

local function new_client(i, name)
    local conn = new_obj("IpConnection", "Conn" .. i, {}, {})
    local ch = new_char(name .. "Char", { X = 0, Y = 0, Z = 100 }, false)
    local pc = new_obj("BP_PlayerController_C", name .. "PC", { Pawn = ch, NetConnection = conn }, {}, { "PlayerController" })
    ch._p.Controller = pc
    ch._owner = pc
    local r = { key = pc:GetFullName(), pc = pc, name = name, index = i }
    S.remote[r.key] = r
    return { ch = ch, pc = pc, key = r.key, name = name, conn = conn, id = tostring(ch._pid) }
end
local A = new_client(1, "Friend")
local B = new_client(2, "Friend2")
local C = new_client(3, "Friend3")
local D = new_client(4, "Friend4")
local CL = { A, B, C, D }
controllers = { host_pc, A.pc, B.pc, C.pc, D.pc }
S.remote_pcs = { A.pc, B.pc, C.pc, D.pc }

local function player0(wco, fname)
    fname = fname or "GetPlayerCharacter"
    local h = hooks["/Script/Engine.GameplayStatics:" .. fname]
    local idx = param(0)
    if h and h.pre then h.pre(param(gps), param(wco), idx) end
    local pc = controllers[idx:get() + 1]
    if fname == "GetPlayerController" then return pc end
    return pc and pc._p.Pawn or nil
end
local function fire_post(fn, ...)
    local h = hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:" .. fn]
    if h and h.pre then h.pre(...) end
end
local host_vp = {}

-- A vehicle facing +X: PlayerLocation 20 cm ahead of its origin, 40 cm left,
-- 50 cm up; door sockets 200 cm to each side of PlayerLocation's x.
local function new_vehicle(name, loc, cls)
    local mc = new_obj("ChaosWheeledVehicleMovementComponent", name .. "_VMC",
        { bRequiresControllerForInputs = false, bUpdateOnlyIfRendered = true, hb = true }, {})
    mc._m.SetRequiresControllerForInputs = function(s, b) s._p.bRequiresControllerForInputs = b end
    mc._m.SetHandbrakeInput = function(s, b) s._p.hb = b end
    mc._m.SetBrakeInput = function() end
    local fc = new_obj("VehicleFuelComponent_C", name .. "_Fuel", { CurrentFuel = 300, MaxFuel = 1000, Empty = false }, {})
    fc._m.StartFuelSpend = function(s) timers[tkey(s, "FuelSpend")] = true end
    fc._m.StopSpendFuel = function(s) timers[tkey(s, "FuelSpend")] = nil end
    local hc = new_obj("VehicleHealthComponent_C", name .. "_Health", { CurrentHealth = 80, MaxHealth = 100 }, {})
    local snd = new_obj("AudioComponent", name .. "_Engine", { active = false }, {})
    snd._m.IsActive = function(s) return s._p.active end
    snd._m.Activate = function(s) s._p.active = true; s._p.fading = false end
    snd._m.FadeOut = function(s) if s._p.active then s._p.fading = true end end
    snd._m.GetPlayState = function(s) if not s._p.active then return 1 elseif s._p.fading then return 4 end return 0 end
    local resp = { [2] = 2, [4] = 2 }
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { visible = true }, {})
    mesh._m.GetCollisionResponseToChannel = function(_, c) return resp[c] end
    mesh._m.SetCollisionResponseToChannel = function(_, c, r) resp[c] = r end
    mesh._m.IsVisible = function(s) return s._p.visible end
    mesh._m.GetSocketLocation = function(_, n)
        local nm = n.ToString and n:ToString() or tostring(n)
        if nm == "PassengerSide" then return { X = loc.X + 20, Y = loc.Y + 200, Z = loc.Z } end
        return { X = loc.X + 20, Y = loc.Y - 200, Z = loc.Z }
    end
    mesh._m.SetMaterial = function() end
    local hb = new_obj("BoxComponent", name .. "_HitBox", { ov = true }, {})
    hb._m.GetGenerateOverlapEvents = function(s) return s._p.ov end
    local pl = new_obj("SceneComponent", name .. "_PlayerLocation", {}, {
        K2_GetComponentLocation = function() return { X = loc.X + 20, Y = loc.Y - 40, Z = loc.Z + 50 } end,
        K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
    })
    local v = new_obj(cls, name, {
        __loc = loc, VehicleMovementComponent = mc, FuelComponent = fc, VehicleHealthComponent = hc,
        EngineSound = snd, Mesh = mesh, HitBoxCollision = hb, PlayerLocation = pl, Colors = tarray({}),
        Tags = tarray({ FName("Vehicle") }), ["LightsOn?"] = false, ["EngineOn?"] = true, VehicleColor = 0, Role = 3 },
        {}, { "BP_VehicleMaster_C" })
    for _, c in ipairs({ mc, fc, hc, snd, mesh, hb, pl }) do c._outer = v end
    v._resp = resp
    v._m.GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end
    v._m.GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end
    v._m.GetActorUpVector = function() return { X = 0, Y = 0, Z = 1 } end
    -- the game's get-in: player 0 attached (welded) at PlayerLocation, sits, a
    -- VehicleUI, the driver's services; 0.1 s later VehicleInteraction(true)
    v._m.Interact_GetInVehicle = function(self, forced)
        mc:SetHandbrakeInput(false)
        resp[2], resp[4] = 0, 0
        local ch = forced or player0(self)
        ch:K2_AttachToActor(self, FName("None"), 1, 1, 1, true)
        ch:K2_SetActorLocationAndRotation(pl:K2_GetComponentLocation(), {})
        ch:PlayMontage(montage, 1)
        local ui = new_obj("VehicleUI_C", "VehicleUI_" .. tostring(#host_vp + 1), {}, {})
        ui._m.RemoveFromParent = function(u) for i, w in ipairs(host_vp) do if w == u then table.remove(host_vp, i) end end end
        host_vp[#host_vp + 1] = ui
        self._p.VehicleUI = ui
        fc:StartFuelSpend()
        timers[tkey(self, "CheckWater")] = true
        snd:Activate(true); timers[tkey(self, "VehicleSound")] = true; timers[tkey(self, "Event_Noise")] = true
        self._entered_by = ch
        delayed[#delayed + 1] = function() local c = forced or player0(self); c:VehicleInteraction(true, self) end
        fire_post("Interact_GetInVehicle", param(self))
    end
    v._m.Event_ExitVehicle = function(self)
        local ch = player0(self)
        ch:K2_DetachFromActor(1, 1, 1)
        ch:StopAnimMontage(montage)
        snd:FadeOut(2.5, 0, 0)
        timers[tkey(self, "VehicleSound")] = nil
        timers[tkey(self, "CheckWater")] = nil
        timers[tkey(self, "Event_Noise")] = nil
        local ui = self._p.VehicleUI
        if ui then ui:RemoveFromParent() end
        self._p.VehicleUI = nil
        self._exited_by = ch
        ch:K2_SetActorLocationAndRotation(mesh:GetSocketLocation(FName(self._p.GetOutPasseenger and "PassengerSide" or "DriverSide")), {})
        self._p.GetOutPasseenger = false
    end
    v._m.ExitVehicle = function(self)
        local ch = player0(self)
        self:Event_ExitVehicle()
        ch._p.CharacterMovement:SetMovementMode(1, 0)
        resp[2], resp[4] = 2, 2
        mc:SetHandbrakeInput(true)
        fc:StopSpendFuel()
        fire_post("ExitVehicle", param(self), param(true))
        ch:VehicleInteraction(false, nil)
    end
    v._m.TurnOnOffLights = function(self) self._p["LightsOn?"] = not self._p["LightsOn?"] end
    v._m.Horn = function(self) self._honks = (self._honks or 0) + 1 end
    v._m.VehicleEngineFX = function() end
    v._m["BndEvt__BP_MPLootContainer_AIOSubject_K2Node_ComponentBoundEvent_0_OnOptimizationUpdate__DelegateSignature"] = function() end
    return v
end

local function run_delayed() local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end
local function vstr(v) local l = v:K2_GetActorLocation(); return { tostring(l.X), tostring(l.Y), tostring(l.Z), v._cls } end
local function d(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
-- where seat idx of the vehicle is (rows of a rear-row class: 90 cm back)
local function seat_pos(v, idx, dz)
    local l = v._p.__loc
    return { X = l.X + 20 + (idx >= 3 and -90 or 0) + 0, Y = l.Y + ((idx % 2 == 1) and -40 or 40), Z = l.Z + 50 + (dz or 0) }
end
local function at_seat(ch, v, idx, dz) return ch._parent == v and d(ch._p.__loc, seat_pos(v, idx, dz)) < 1 end
local function tick(dt) T = T + (dt or 0.5); V.tick() end
local function vst(v) return V._t.vs()[v._addr] end
local function venter(c, v, old)
    local a = vstr(v)
    -- (a newer client: "s2" seats 3+, "sw" the seat key; an older one: neither)
    if not old then a[5], a[6] = "s2", "sw" end
    deliver("VENTER", a, c.pc)
end
local function vexit(c, v, side, idx)
    local a = vstr(v)
    a[5], a[6], a[7], a[8] = side or "d", "3.0", "x", idx and tostring(idx) or nil
    deliver("VEXIT", a, c.pc)
end
local function host_press(v)
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = v
    v:Interact_GetInVehicle()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
end
local function seat_args(c) local s = last_sent("VSEAT", c.pc); return s and s.args or {} end
-- The seat key (config vehicle_seat_key, G): a client's press is the VSWITCH
-- its game sends; the host's press runs SEATK.on_key, what main.lua's frame
-- loop calls on the key's down edge (the frame read itself: K8).
local function seat_key(who, v)
    if who == "H" or who == host_ch then V._t.seatk.on_key() return end
    deliver("VSWITCH", vstr(v), who.pc)
end
local function toast_since(n0, pat)
    for i = n0 + 1, #toasts do if toasts[i]:find(pat, 1, true) then return true end end
    return false
end
local ALL = { host_ch, A.ch, B.ch, C.ch, D.ch }
local function reset_chars(v)
    for i, c in ipairs(ALL) do
        c._parent = nil; c._welded = false; c._montage = nil; c._p["InVehicle?"] = false; c._p["PlayerDead?"] = false
        c._p.VehicleDrivingComponent._p.Vehicle = nil; c._p.CharacterMovement._p.MovementMode = 1
        local l = v._p.__loc
        c._p.__loc = { X = l.X - 100 + 40 * i, Y = (i % 2 == 0) and 300 or -300, Z = 100 }
    end
    for _, c in ipairs(CL) do c.pc._p.Pawn = c.ch; c.pc._p.NetConnection = c.conn end
    host_pc._p.Pawn = host_ch
    walls = {}
end
local nveh = 0
-- a fresh vehicle 100 m from the others, everyone out and next to it
local function fresh(cls)
    nveh = nveh + 1
    local v = new_vehicle(cls .. "_" .. (2147490000 + nveh), { X = 100000 + 10000 * nveh, Y = 0, Z = 80 }, cls)
    reset_chars(v)
    tick(3)
    return v
end
-- everyone out of v at the end of a scenario, the vehicle gone
local function done(v)
    v._valid = false
    reset_chars(v)
    tick(3)
    tick(3)
end

-- ------------------------------------------------------------ host setup
print("setup")
ctx.tick(S.remote_pcs)
check(ctx.active, "ctx redirection active")
V.tick()
check(hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:Interact_GetInVehicle"] ~= nil, "enter hook registered")
check(commands.sdcoop_seat ~= nil, "sdcoop_seat registered")

-- ------------------------------------------------------------ S1. four seats taken in order
print("S1. SUV: Friend drives, Friend2 seat 2, Friend3 seat 3, the host seat 4, Friend4 refused")
local suv = fresh("Vehicle_SUV_C")
do
    venter(A, suv)
    local s = seat_args(A)
    check(s[1] == "driver" and s[3] == "1" and s[4] == "1" and s[5] == "4" and s[13] == "0",
        "S1: VSEAT driver, seat 1 of 4, no notice (alone in the car)")
    T = T + 0.1
    run_delayed()
    venter(B, suv)
    s = seat_args(B)
    check(s[1] == "passenger" and s[2] == "Friend" and s[3] == "2" and s[4] == "2" and s[5] == "4" and s[6] == "R" and s[13] == "1",
        "S1: Friend2: passenger, seat 2 of 4, Friend drives (notice)")
    check(at_seat(B.ch, suv, 2), "S1: Friend2 in seat 2 (the mirror)")
    venter(C, suv)
    s = seat_args(C)
    check(#s == 14 and s[14] == "sw" and s[3] == "3" and s[4] == "3" and s[5] == "4" and s[6] == "L" and s[7] == "-90" and s[8] == "0"
        and s[9] == "0" and s[10] == "0" and s[11] == "car" and s[12] == "d" and s[13] == "1",
        "S2: VSEAT for Friend3: all fields (seat 3 of 4, L, 90 cm back, car pose, driver-side door, the seat key)")
    check(at_seat(C.ch, suv, 3), "S2: Friend3 in seat 3, 90 cm behind the driver")
    check(C.ch._welded == false and C.ch._montage == montage and C.ch._p["InVehicle?"] == true,
        "S2: attached without welding, sit pose, the game's driving state")
    tick(2)
    local n0 = #toasts
    host_press(suv)
    T = T + 0.1
    run_delayed()
    local st = vst(suv)
    check(at_seat(host_ch, suv, 4) and st.host_seat == "passenger" and st.host_idx == 4, "S1: the host in seat 4")
    check(toast_since(n0, "Место 4 из 4: машину ведёт Friend."), "S1: the host told 'Seat 4 of 4' (the game's notice)")
    check(host_ch._p.VehicleDrivingComponent._p.Vehicle == suv and host_ch._welded == false, "S1: the host has the driving state, unwelded")
    tick(2)
    venter(D, suv)
    s = seat_args(D)
    check(s[1] == "none" and s[2] == "full" and s[3] == "4" and D.ch._parent == nil, "S1: Friend4 refused: none|full|4")
    check(st.driver_key == A.key and st.pax[2] == B.key and st.pax[3] == C.key and st.pax[4] == nil and st.host_idx == 4,
        "S1: records: driver Friend, seats 2 Friend2, 3 Friend3, host 4")
    check(V.seat_idx(A.key) == 1 and V.seat_idx(B.key) == 2 and V.seat_idx(C.key) == 3 and V.seat_of(C.key) == "passenger",
        "S1: seat numbers per player")

    print("S4. VSTATE unchanged (12 fields), VOCC lists seats 2+")
    sent = {}
    st.dirty = true
    tick(0.5)
    local vs4 = last_sent("VSTATE", D.pc)
    check(vs4 and #vs4.args == 12 and vs4.args[11] == A.id and vs4.args[12] == B.id, "S4: VSTATE: 12 fields, f11 the driver, f12 seat 2")
    local vo = last_sent("VOCC", D.pc)
    local occ = vo and VS.parse_occ(vo.args[5]) or {}
    check(vo and vo.args[4] == "Vehicle_SUV_C" and #occ == 3 and occ[1].idx == 2 and occ[1].id == B.id and occ[2].idx == 3
        and occ[2].id == C.id and occ[2].geo.x == -90 and occ[3].idx == 4 and occ[3].id == tostring(host_ch._pid),
        "S4: VOCC: 2 Friend2, 3 Friend3 (its numbers), 4 the host")
    sent = {}
    tick(0.5)
    check(last_sent("VOCC") == nil and last_sent("VSTATE") == nil, "S4: nothing again without a change")

    print("S15. three or more seated: the others' capsule / mesh let the camera through")
    check(A.ch._p.CapsuleComponent._p.cam == 0 and A.ch._p.Mesh._p.cam == 0 and C.ch._p.CapsuleComponent._p.cam == 0,
        "S15: seated clients ignore the Camera channel on the host")
    check(host_ch._p.CapsuleComponent._p.cam == 2, "S15: the host's own character untouched")
    check(A.ch._p.Mesh._p.vis == 0, "S15: (and the interact trace passes them, as before)")

    print("S5. Friend (driver) gets out: everyone stays; Friend2 (seat 2) takes the wheel with its seat key")
    n0 = #toasts
    sent = {}
    vexit(A, suv, "d")
    check(A.ch._parent == nil and st.driver_key == nil and at_seat(B.ch, suv, 2) and at_seat(C.ch, suv, 3) and at_seat(host_ch, suv, 4)
        and st.pax[2] == B.key and st.pax[3] == C.key and count_sent("VSEAT") == 0,
        "S5: Friend out; Friend2 (2), Friend3 (3) and the host (4) stay in their seats, no seat messages")
    check(suv._p.VehicleMovementComponent._p.hb == true and suv._p.EngineSound._p.fading == true
        and timers[tkey(suv._p.FuelComponent, "FuelSpend")] == nil, "S5: the car parked (handbrake on, engine off, no fuel spent)")
    check(last_sent("VSWR", B.pc) and last_sent("VSWR", B.pc).args[1] == "wheel" and last_sent("VSWR", C.pc)
        and toast_since(n0, "Руль свободен: нажмите G, чтобы пересесть."), "S5: Friend2, Friend3 and the host told: the wheel is free (key G)")
    seat_key(B, suv)
    check(suv._entered_by == B.ch and seat_args(B)[1] == "driver" and seat_args(B)[13] == "1",
        "S5: Friend2's key: the game's get-in for it, VSEAT driver")
    check(at_seat(B.ch, suv, 1) and B.ch._welded == false, "S5: Friend2 at the wheel, unwelded again (its seat replicates)")
    check(at_seat(C.ch, suv, 3) and at_seat(host_ch, suv, 4), "S5: Friend3 (3) and the host (4) stay")
    check(st.driver_key == B.key and st.pax[2] == nil and st.pax[3] == C.key and suv._owner == B.pc, "S5: records / owner")
    check(A.ch._p.CapsuleComponent._p.cam == 2 and A.ch._p.Mesh._p.cam == 2, "S15: out: its camera response back")
    T = T + 0.1
    run_delayed()
    tick(2)

    print("S6. Friend2 gets out: seat 2 empty, Friend3 (seat 3) takes the wheel with its key")
    vexit(B, suv, "d")
    check(at_seat(C.ch, suv, 3) and at_seat(host_ch, suv, 4) and st.driver_key == nil, "S6: Friend3 (3) and the host (4) stay")
    seat_key(C, suv)
    check(suv._entered_by == C.ch and at_seat(C.ch, suv, 1) and st.driver_key == C.key and seat_args(C)[1] == "driver",
        "S6: Friend3 drives")
    check(at_seat(host_ch, suv, 4) and st.host_idx == 4, "S6: the host stays in seat 4")
    T = T + 0.1
    run_delayed()
    tick(2)

    print("S7. Friend3 gets out: the host (seat 4) takes the wheel with its key")
    n0 = #toasts
    vexit(C, suv, "d")
    check(at_seat(host_ch, suv, 4) and st.host_seat == "passenger", "S7: the host stays in seat 4")
    seat_key("H", suv)
    check(at_seat(host_ch, suv, 1) and st.host_seat == "driver" and st.host_idx == nil and st.driver_key == nil,
        "S7: the host at the wheel")
    check(suv._p.VehicleMovementComponent._p.hb == false and suv._p.EngineSound._p.active == true, "S7: handbrake off, engine sound on")
    check(toast_since(n0, "Место 1 из 4: вы за рулём."), "S7: the host told (the game's notice: seat 1 of 4)")
    sent = {}
    tick(0.5)
    local vo7 = last_sent("VOCC", D.pc)
    check(vo7 and vo7.args[5] == "", "S4: the seats 3+ emptied: an empty VOCC once")
    sent = {}
    st.dirty = true
    tick(0.5)
    check(last_sent("VOCC", D.pc) == nil and last_sent("VSTATE", D.pc) ~= nil, "S4: then no VOCC with the VSTATE")
    suv:ExitVehicle()
    tick(1)
    check(host_ch._parent == nil and next(st.pax) == nil and st.host_seat == nil, "S7: everyone out")
end
done(suv)

-- ------------------------------------------------------------ S8. doors by seat
print("S8. exits by seat: rear doors, a wall, all blocked")
do
    local v = fresh("Vehicle_Sheriff_C")
    local l = v._p.__loc
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); venter(D, v)
    local st = vst(v)
    check(st.pax[2] == B.key and st.pax[3] == C.key and st.pax[4] == D.key, "S8: four clients, no host")
    traces = {}
    vexit(C, v, "d", 3)
    check(C.ch._parent == nil and d(C.ch._p.__loc, { X = l.X + 20 - 90, Y = l.Y - 200, Z = l.Z }) < 1,
        "S8: seat 3 out at the rear left door (driver socket, 90 cm back)")
    check(#traces >= 1 and traces[1].r == 30 and traces[1].half == 50 and traces[1].ignore[1] == C.ch, "S8: the door checked (capsule 30/50)")
    check(st.pax[3] == nil and C.ch._p["InVehicle?"] == false and C.ch._montage == nil, "S8: seat free, out of the car's state, pose ended")
    venter(C, v)
    walls = { { X = l.X - 70, Y = l.Y - 200 } }
    vexit(C, v, "d", 3)
    check(d(C.ch._p.__loc, { X = l.X - 70, Y = l.Y + 200, Z = l.Z }) < 1, "S8: a wall at the rear left: out at the rear right")
    venter(C, v)
    walls = { { X = l.X - 70, Y = l.Y - 200 }, { X = l.X - 70, Y = l.Y + 200 } }
    vexit(C, v, "d", 3)
    check(d(C.ch._p.__loc, { X = l.X + 20, Y = l.Y - 200, Z = l.Z }) < 1, "S8: both rear doors blocked: its front door")
    venter(C, v)
    walls = { { X = l.X - 70, Y = l.Y - 200 }, { X = l.X - 70, Y = l.Y + 200 }, { X = l.X + 20, Y = l.Y - 200 }, { X = l.X + 20, Y = l.Y + 200 } }
    vexit(C, v, "d", 3)
    check(C.ch._parent == nil and d(C.ch._p.__loc, { X = l.X + 20, Y = l.Y - 200, Z = l.Z }) < 1,
        "S8: every door blocked: its own front door all the same")
    walls = {}
    vexit(D, v, "p", 4)
    check(d(D.ch._p.__loc, { X = l.X - 70, Y = l.Y + 200, Z = l.Z }) < 1, "S8: seat 4 out at the rear right door")
    vexit(B, v, "p", 2)
    check(d(B.ch._p.__loc, { X = l.X + 20, Y = l.Y + 200, Z = l.Z }) < 1, "S8: seat 2 at the passenger door (as before)")
    check(at_seat(A.ch, v, 1) and st.driver_key == A.key, "S8: the driver untouched")
    done(v)
end

-- ------------------------------------------------------------ S9. deaths and disconnects
print("S9. a death in seat 3 and a disconnect in seat 4 in one tick; a dead passenger's key does nothing")
do
    local v = fresh("Vehicle_Humvee_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); venter(D, v)
    local st = vst(v)
    tick(1)
    sent = {}
    st.dirty = true
    tick(0.5)
    check(last_sent("VOCC", A.pc) ~= nil and #VS.parse_occ(last_sent("VOCC", A.pc).args[5]) == 3, "S9: VOCC with 3 seats")
    C.ch._p["PlayerDead?"] = true
    D.pc._p.NetConnection = nil
    D.ch._parent = nil
    sent = {}
    tick(1)
    check(st.pax[3] == nil and st.pax[4] == nil and st.pax[2] == B.key and st.driver_key == A.key, "S9: both seats free in one tick")
    local vo = last_sent("VOCC", A.pc)
    check(vo and vo.args[5] == "", "S9: VOCC emptied for the others")
    check(V.seat_of(C.key) == nil and V.seat_of(D.key) == nil, "S9: no seat records left for them")
    -- Friend3 alive again, sits in 3; Friend2 (seat 2) dies, its body still attached; the driver gets out before the tick
    C.ch._p["PlayerDead?"] = false
    C.ch._parent = nil
    D.pc._p.NetConnection = D.conn
    venter(C, v)
    check(st.pax[3] == C.key, "S9: Friend3 in seat 3 again")
    B.ch._p["PlayerDead?"] = true
    vexit(A, v, "d")
    check(st.driver_key == nil and at_seat(C.ch, v, 3) and B.ch._parent == v, "S9: the driver out: nobody moved, the dead Friend2 (seat 2) neither")
    seat_key(B, v)
    check(st.driver_key == nil and B.ch._parent == v and seat_args(B)[1] ~= "driver", "S9: the dead one's seat key: nothing")
    seat_key(C, v)
    check(st.driver_key == C.key and at_seat(C.ch, v, 1) and v._entered_by == C.ch,
        "S9: Friend3 (seat 3) takes the wheel with its key")
    check(seat_args(B)[1] ~= "driver" and B.ch._parent == v, "S9: no VSEAT driver to the dead one")
    T = T + 0.1
    run_delayed()
    tick(1)
    check(st.pax[2] == nil and V.seat_of(B.key) == nil, "S9: the tick frees the dead one's seat")
    B.ch._p["PlayerDead?"] = false
    print("S10. the vehicle is gone: every seated client told")
    venter(B, v)
    venter(A, v)
    sent = {}
    v._valid = false
    tick(1)
    local gone = 0
    for _, c in ipairs({ A, B, C }) do
        local s = last_sent("VSEAT", c.pc)
        if s and s.args[1] == "none" and s.args[2] == "vehicle gone" then gone = gone + 1 end
    end
    check(gone == 3, "S10: driver, seat 2 and seat 3 told: none|vehicle gone")
    check(next(V._t.seats()) == nil, "S10: no seats left")
    done(v)
end

-- ------------------------------------------------------------ S11. 2-seat classes, the switch
print("S11. vehicle_seats off: SUV has 2 seats; Buggy / golf cart 2; old texts")
do
    cfg.set("vehicle_seats", false)
    local v = fresh("Vehicle_SUV_C")
    venter(A, v)
    check(seat_args(A)[5] == "2" and seat_args(A)[13] == "0", "S11: off: the driver: seat 1 of 2, no notice")
    T = T + 0.1; run_delayed()
    venter(B, v)
    check(seat_args(B)[3] == "2" and seat_args(B)[5] == "2", "S11: off: passenger seat 2 of 2")
    venter(C, v)
    local s = seat_args(C)
    check(s[1] == "none" and s[2] == "full" and s[3] == "2" and C.ch._parent == nil, "S11: off: the third refused (2 seats)")
    tick(1)
    sent = {}
    vst(v).dirty = true
    tick(0.5)
    check(last_sent("VOCC") == nil, "S11: off: no VOCC (VSTATE field 12 says it all)")
    check(A.ch._p.CapsuleComponent._p.cam == 2 and B.ch._p.CapsuleComponent._p.cam == 2, "S11: two seated: no camera change")
    local n0 = #toasts
    host_press(v)
    T = T + 0.1; run_delayed()
    check(host_ch._parent == nil and toast_since(n0, "В машине нет свободного места.") and not toast_since(n0, "всего мест"),
        "S11: off: the host refused with the old text")
    cfg.set("vehicle_seats", true)
    done(v)
    for _, cls in ipairs({ "Vehicle_Buggy_C", "Vehicle_GolfCart_C" }) do
        local b = fresh(cls)
        n0 = #toasts
        host_press(b)
        T = T + 0.1; run_delayed()
        check(at_seat(host_ch, b, 1) and not toast_since(n0, "Место"), "S11: " .. cls .. ": the host drives alone, no seat notice")
        tick(1)
        venter(A, b, false)
        check(seat_args(A)[3] == "2" and seat_args(A)[5] == "2" and at_seat(A.ch, b, 2), "S11: " .. cls .. ": seat 2 of 2")
        venter(B, b, false)
        check(seat_args(B)[1] == "none" and seat_args(B)[3] == "2", "S11: " .. cls .. ": the third refused (2 seats)")
        b:ExitVehicle()
        tick(1)
        done(b)
    end
    -- the host passenger in a 2-seat car is told as before
    local g = fresh("Vehicle_Buggy_C")
    venter(A, g); T = T + 0.1; run_delayed(); tick(2)
    n0 = #toasts
    host_press(g)
    T = T + 0.1; run_delayed()
    check(at_seat(host_ch, g, 2) and toast_since(n0, "Вы пассажир: машину ведёт Friend."), "S11: Buggy: host passenger, the old text")
    g:ExitVehicle()
    done(g)
end

-- ------------------------------------------------------------ S12. full car: the host refused; its get-in again in its own seat
print("S12. a full car refuses the host; the host's get-in again keeps its own seat")
do
    local v = fresh("Vehicle_Charger_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); venter(D, v)
    tick(2)
    local st = vst(v)
    local rej0, n0 = V.stats.rejected, #toasts
    traces = {}
    sent = {}
    host_press(v)
    check(host_ch._parent == nil and v._exited_by == host_ch, "S12: the host's get-in undone (the game's exit for the host)")
    check(#traces >= 1 and traces[1].ignore[1] == host_ch, "S12: the door checked for the host")
    check(toast_since(n0, "В машине нет свободного места (всего мест: 4).") and V.stats.rejected == rej0 + 1, "S12: the host told: no free seat (4 seats)")
    check(last_sent("VSEAT") == nil and st.driver_key == A.key and st.pax[2] == B.key and st.pax[3] == C.key and st.pax[4] == D.key,
        "S12: the clients' seats unchanged")
    T = T + 0.1; run_delayed()
    check(host_ch._p["InVehicle?"] == false and host_ch._p.CharacterMovement._p.MovementMode == 1, "S12: the delayed get-in step undone")
    tick(2)
    -- Friend3 out: the host takes seat 3; Friend3 back: none
    vexit(C, v, "d", 3)
    host_press(v)
    T = T + 0.1; run_delayed()
    check(at_seat(host_ch, v, 3) and st.host_idx == 3, "S12: the host in the freed seat 3")
    tick(2)
    venter(C, v)
    check(seat_args(C)[1] == "none" and seat_args(C)[3] == "4", "S12: Friend3 now refused (full, 4 seats)")
    -- the host's get-in again while it sits in seat 3 of a full car
    rej0, n0 = V.stats.rejected, #toasts
    host_press(v)
    check(at_seat(host_ch, v, 3) and host_ch._welded == false and st.host_seat == "passenger" and st.host_idx == 3,
        "S12b: the host stays in seat 3, unwelded again")
    check(V.stats.rejected == rej0 and not toast_since(n0, "нет свободного"), "S12b: not refused, no notice")
    check(st.pax[2] == B.key and st.pax[4] == D.key and at_seat(B.ch, v, 2) and at_seat(D.ch, v, 4), "S12b: nobody else moved")
    T = T + 0.1; run_delayed()
    check(host_ch._parent == v and host_ch._p.VehicleDrivingComponent._p.Vehicle == v, "S12b: the delayed get-in step kept (it sits)")
    tick(2)
    check(at_seat(host_ch, v, 3) and st.host_idx == 3, "S12b: still seat 3 after the tick")
    -- not full: seat 2 and 4 free, the host in 3 presses again: not moved to 2
    vexit(B, v, "p", 2)
    vexit(D, v, "p", 4)
    host_press(v)
    check(at_seat(host_ch, v, 3) and st.host_idx == 3, "S12b: a free seat 2 does not move the host either")
    T = T + 0.1; run_delayed()
    v:ExitVehicle()
    check(host_ch._parent == nil and d(host_ch._p.__loc, { X = v._p.__loc.X - 70, Y = v._p.__loc.Y - 200, Z = v._p.__loc.Z }) < 1,
        "S8: the host's own exit from seat 3: at its rear door")
    done(v)
end

-- ------------------------------------------------------------ S17. demote: a remote driver while the host holds the wheel
print("S17. a remote driver beside the host's wheel goes to the first free seat; an older client: full")
do
    local v = fresh("Vehicle_SUV_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(2)
    venter(B, v)
    local st = vst(v)
    check(at_seat(host_ch, v, 1) and st.pax[2] == B.key, "S17: the host drives, Friend2 seat 2")
    A.ch._parent = v
    V._t.seats()[A.key] = { vaddr = v._addr, vname = v._short, seat = "driver", idx = 1, cap = true, at = T }
    st.driver_key, st.host_till = A.key, 0
    tick(1)
    check(st.driver_key == nil and st.pax[3] == A.key and at_seat(A.ch, v, 3) and seat_args(A)[3] == "3",
        "S17: Friend to seat 3 (it knows seats 3+)")
    vexit(A, v, "d", 3)
    A.ch._parent = v
    V._t.seats()[A.key] = { vaddr = v._addr, vname = v._short, seat = "driver", at = T }
    st.driver_key, st.host_till = A.key, 0
    tick(1)
    check(seat_args(A)[1] == "none" and seat_args(A)[2] == "full" and seat_args(A)[3] == "2" and st.pax[3] == nil,
        "S17: an older client (no s2): refused, full (2 seats)")
    v:ExitVehicle()
    done(v)
end

-- ------------------------------------------------------------ R7. the check after a move to the wheel
print("R7. the get-in for the new driver seats the host instead: undone, nobody drives; the host's own key then")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v)
    tick(2)
    host_press(v); T = T + 0.1; run_delayed(); tick(2)
    local st = vst(v)
    check(at_seat(host_ch, v, 3) and st.pax[2] == B.key, "R7: Friend drives, Friend2 seat 2, the host seat 3")
    local good = v._m.Interact_GetInVehicle
    v._m.Interact_GetInVehicle = function(self) v._m.Interact_GetInVehicle = good; good(self, host_ch) end
    errs = {}
    sent = {}
    vexit(A, v, "d")
    check(st.driver_key == nil and at_seat(B.ch, v, 2) and at_seat(host_ch, v, 3), "R7: Friend out: Friend2 (2) and the host (3) stay")
    seat_key(B, v)
    check(#errs >= 1 and errs[#errs]:find("did not seat it at the wheel", 1, true) ~= nil, "R7: the wrong seating noticed (log error)")
    check(last_sent("VSWR", B.pc) and last_sent("VSWR", B.pc).args[1] == "no", "R7: Friend2's key answered: it could not be moved")
    check(st.pax[2] == B.key and at_seat(B.ch, v, 2) and seat_args(B)[1] == "passenger" and seat_args(B)[13] == "0",
        "R7: Friend2 a passenger again in seat 2 (told, no notice)")
    local drv = 0
    for _, s in ipairs(sent) do if s.kind == "VSEAT" and s.to == B.pc and s.args[1] == "driver" then drv = drv + 1 end end
    check(drv == 0, "R7: Friend2 never told it drives (no VSEAT driver before the check)")
    check(st.host_seat == "passenger" and at_seat(host_ch, v, 3) and v._owner == nil and st.driver_key == nil,
        "R7: the host back in its own seat 3; nobody drives; the car is not Friend2's")
    seat_key("H", v)
    check(st.host_seat == "driver" and at_seat(host_ch, v, 1), "R7: the host's own key: the wheel")
    T = T + 0.5
    sent = {}
    seat_key(B, v)
    check(at_seat(B.ch, v, 2) and last_sent("VSWR", B.pc) and last_sent("VSWR", B.pc).args[1] == "taken"
        and last_sent("VSWR", B.pc).args[2] == "Host",
        "R7: the undone move left the wheel waited for: Friend2's press right after the host took it: stays (VSWR taken|Host)")
    T = T + 0.1; run_delayed()
    v:ExitVehicle()
    T = T + 0.1; run_delayed()
    tick(2)
    done(v)
end

-- ------------------------------------------------------------ every order of 3 and 4 players
print("P. every order of the host and three clients into an SUV, out in the same order")
local function perms(list)
    local out = {}
    local function go(a, n)
        if n == 0 then out[#out + 1] = { table.unpack(a) } return end
        for i = 1, n do
            a[i], a[n] = a[n], a[i]
            go(a, n - 1)
            a[i], a[n] = a[n], a[i]
        end
    end
    go({ table.unpack(list) }, #list)
    return out
end
local function enter(who, v)
    if who == "H" then host_press(v) else venter(who, v) end
    T = T + 0.1
    run_delayed()
    tick(0.5)
end
local function leave(who, v)
    if who == "H" then v:ExitVehicle() else vexit(who, v, "d") end
    T = T + 0.1
    run_delayed()
    tick(0.5)
end
local function ch_of(who) return who == "H" and host_ch or who.ch end
local function label(order)
    local s = {}
    for _, w in ipairs(order) do s[#s + 1] = w == "H" and "H" or w.name:gsub("Friend", "F") end
    return table.concat(s, ",")
end
local function run_order(order, cls, cap)
    local v = fresh(cls)
    local st = nil
    local seated_ok, refused_ok = true, true
    for i, w in ipairs(order) do
        enter(w, v)
        st = st or vst(v)
        if i <= cap then
            if not at_seat(ch_of(w), v, i) then seated_ok = false end
        else
            if ch_of(w)._parent ~= nil then refused_ok = false end
            if w ~= "H" and seat_args(w)[1] ~= "none" then refused_ok = false end
        end
    end
    -- out in entry order: the driver's exit moves nobody; the next one in
    -- (the lowest seat left) takes the wheel with its seat key
    local hand_ok = true
    local inside = math.min(#order, cap)
    for i = 1, inside do
        leave(order[i], v)
        if i < inside then
            for j = i + 1, inside do
                if not at_seat(ch_of(order[j]), v, j) then hand_ok = false end
            end
            if st.driver_key ~= nil or st.host_seat == "driver" then hand_ok = false end
            local nxt = order[i + 1]
            seat_key(nxt, v)
            T = T + 0.1
            run_delayed()
            if not at_seat(ch_of(nxt), v, 1) then hand_ok = false end
            for j = i + 2, inside do
                if not at_seat(ch_of(order[j]), v, j) then hand_ok = false end
            end
            local drv_ok = (nxt == "H" and st.host_seat == "driver") or (nxt ~= "H" and st.driver_key == nxt.key)
            if not drv_ok then hand_ok = false end
        end
    end
    local empty = next(st.pax) == nil and st.driver_key == nil and st.host_seat == nil
    for _, w in ipairs(order) do if ch_of(w)._parent ~= nil then empty = false end end
    done(v)
    return seated_ok, refused_ok, hand_ok and empty
end
do
    local n_ok = 0
    local all4 = perms({ "H", A, B, C })
    for _, order in ipairs(all4) do
        local s1, s2, s3 = run_order(order, "Vehicle_SUV_C", 4)
        check(s1 and s2 and s3, "P4 " .. label(order) .. ": seats 1-4 in order of entry; each driver's exit moves nobody, the next seat's key takes the wheel")
        if s1 and s2 and s3 then n_ok = n_ok + 1 end
    end
    check(n_ok == 24, "P4: all 24 orders")
    local all3 = perms({ "H", A, B })
    for _, order in ipairs(all3) do
        local s1, s2, s3 = run_order(order, "Vehicle_4x4Jeep_C", 4)
        check(s1 and s2 and s3, "P3 " .. label(order) .. ": 3 players in a 4x4: seats 1-3, the wheel by key in seat order")
    end
    for _, order in ipairs(all3) do
        local s1, s2, s3 = run_order(order, "Vehicle_GolfCart_C", 2)
        check(s1 and s2 and s3, "P2 " .. label(order) .. ": 3 players at a golf cart: two seated, the third refused")
    end
    -- 4 clients, an older one among them: it gets seats 1-2 only
    local v = fresh("Vehicle_DamagedSedan_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v)
    venter(C, v, true)
    check(seat_args(C)[1] == "none" and seat_args(C)[3] == "2", "P: an older client at a sedan with seat 2 taken: full (2 seats), seat 3 free")
    venter(D, v)
    check(at_seat(D.ch, v, 3), "P: a newer one gets seat 3")
    vexit(B, v, "p", 2)
    venter(C, v, true)
    check(at_seat(C.ch, v, 2) and seat_args(C)[3] == "2", "P: seat 2 free: the older client gets it")
    done(v)
end

-- ------------------------------------------------------------ every exit order
print("X. four seated, every order of getting out: the driver's exit moves nobody; the highest seat's key takes the wheel")
local function run_exits(entry, exits)
    local v = fresh("Vehicle_SUV_C")
    local seat = {}
    for i, w in ipairs(entry) do enter(w, v); seat[w] = i end
    local st = vst(v)
    local ok = true
    for _, w in ipairs(entry) do if not at_seat(ch_of(w), v, seat[w]) then ok = false end end
    for _, w in ipairs(exits) do
        local was = seat[w]
        seat[w] = nil
        leave(w, v)
        if ch_of(w)._parent ~= nil then ok = false end
        -- nobody moved by an exit
        for x, i in pairs(seat) do if not at_seat(ch_of(x), v, i) then ok = false end end
        if was == 1 then
            if st.driver_key ~= nil or st.host_seat == "driver" then ok = false end
            -- any passenger may take the wheel: here the highest seat left
            local best = nil
            for x, i in pairs(seat) do if not best or i > seat[best] then best = x end end
            if best then
                seat_key(best, v)
                seat[best] = 1
                T = T + 0.1
                run_delayed()
                tick(0.5)
            end
        end
        for x, i in pairs(seat) do
            if not at_seat(ch_of(x), v, i) then ok = false end
            if i == 1 and not ((x == "H" and st.host_seat == "driver") or (x ~= "H" and st.driver_key == x.key)) then ok = false end
        end
    end
    ok = ok and next(st.pax) == nil and st.driver_key == nil and st.host_seat == nil
    done(v)
    return ok
end
do
    for _, entry in ipairs({ { "H", A, B, C }, { A, B, "H", C } }) do
        local n = 0
        for _, exits in ipairs(perms(entry)) do
            if run_exits(entry, exits) then n = n + 1 else print("    failed: in " .. label(entry) .. ", out " .. label(exits)) end
        end
        check(n == 24, "X: in " .. label(entry) .. ": all 24 exit orders keep one player per seat; nobody moved but by its key")
    end
end

-- ------------------------------------------------------------ H. the host dies, the driver disconnects
print("H. the host dies in seat 3 / at the wheel; a driver disconnects")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(C, v)
    local st = vst(v)
    check(at_seat(host_ch, v, 3) and at_seat(C.ch, v, 4), "H: Friend drives, Friend2 2, the host 3, Friend3 4")
    host_ch._p["PlayerDead?"] = true
    host_pc._p.Pawn = nil
    sent = {}
    tick(1)
    check(st.host_seat == nil and st.host_idx == nil and st.driver_key == A.key and st.pax[2] == B.key and st.pax[4] == C.key,
        "H: the dead host holds no seat; nobody else moves")
    check(last_sent("VSEAT") == nil, "H: no seat messages")
    local vo = last_sent("VOCC", A.pc)
    local occ = vo and VS.parse_occ(vo.args[5]) or {}
    check(#occ == 2 and occ[1].idx == 2 and occ[2].idx == 4, "H: VOCC: seats 2 and 4 left")
    host_pc._p.Pawn = host_ch
    host_ch._p["PlayerDead?"] = false
    host_ch._parent = nil
    -- the driver disconnects: nobody moves; Friend2 (seat 2) takes the wheel with its key
    A.pc._p.NetConnection = nil
    A.ch._parent = nil
    tick(1)
    check(st.driver_key == nil and at_seat(B.ch, v, 2) and at_seat(C.ch, v, 4), "H: the driver gone: Friend2 (2) and Friend3 (4) stay")
    seat_key(B, v)
    check(st.driver_key == B.key and at_seat(B.ch, v, 1) and v._entered_by == B.ch and at_seat(C.ch, v, 4),
        "H: Friend2's key: it drives, Friend3 stays in 4")
    A.pc._p.NetConnection = A.conn
    T = T + 0.1; run_delayed()
    done(v)
    -- the host dies at the wheel with three passengers: they stay; seat 2's key takes it
    v = fresh("Vehicle_SUV_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(A, v); venter(B, v); venter(C, v)
    st = vst(v)
    tick(1)
    host_ch._p["PlayerDead?"] = true
    host_pc._p.Pawn = nil
    tick(1)
    check(st.host_seat == nil and st.driver_key == nil and at_seat(A.ch, v, 2) and at_seat(B.ch, v, 3) and at_seat(C.ch, v, 4),
        "H: the host dead at the wheel: Friend (2), Friend2 (3), Friend3 (4) stay")
    seat_key(A, v)
    check(st.host_seat == nil and st.driver_key == A.key and at_seat(A.ch, v, 1) and v._entered_by == A.ch
        and at_seat(B.ch, v, 3) and at_seat(C.ch, v, 4) and st.pax[2] == nil,
        "H: Friend's key: it drives, seats 3 and 4 stay")
    host_pc._p.Pawn = host_ch
    host_ch._p["PlayerDead?"] = false
    host_ch._parent = nil
    T = T + 0.1; run_delayed()
    done(v)
end

-- ------------------------------------------------------------ U. stage 2 rows (untuned)
print("U. untuned rows: off by default, on with the test switch (floor pose in a pickup bed)")
do
    local v = fresh("Vehicle_PickupTruck_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v)
    venter(C, v)
    check(seat_args(C)[1] == "none" and seat_args(C)[3] == "2", "U: pickup bed off by default: 2 seats")
    cfg.set("vehicle_seats_untuned", true)
    venter(C, v)
    local s = seat_args(C)
    check(s[3] == "3" and s[5] == "4" and s[11] == "floor" and C.ch._montage == floor_m, "U: on: seat 3 of 4 in the bed, floor pose")
    check(d(C.ch._p.__loc, { X = v._p.__loc.X + 20 - 200, Y = v._p.__loc.Y - 40, Z = v._p.__loc.Z + 50 }) < 1, "U: 200 cm back")
    tick(1)
    check(C.ch._montage == floor_m, "U: the tick keeps the floor pose (not the car pose)")
    vexit(C, v, "d", 3)
    check(C.ch._montage == nil and (C.ch._stop_everywhere or 0) >= 2, "U: out: both poses stopped everywhere")
    cfg.set("vehicle_seats_untuned", false)
    done(v)
end

-- ------------------------------------------------------------ R2. VOCC per client (out of range)
print("R2. a client out of range when the rear seat empties gets the empty list when it is back")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v)
    sent = {}
    tick(1)
    check(last_sent("VOCC", D.pc) ~= nil and last_sent("VOCC", D.pc).args[5] ~= "", "R2: Friend4 near: has the list with seat 3")
    D.ch._p.__loc = { X = v._p.__loc.X + 50000, Y = 0, Z = 100 }
    tick(0.5)
    sent = {}
    vexit(C, v, "d", 3)
    tick(0.5)
    check(last_sent("VOCC", D.pc) == nil and last_sent("VOCC", A.pc) and last_sent("VOCC", A.pc).args[5] == "",
        "R2: in range: the empty list; far away: nothing")
    D.ch._p.__loc = { X = v._p.__loc.X + 100, Y = 300, Z = 100 }
    sent = {}
    tick(0.5)
    local back = last_sent("VOCC", D.pc)
    check(last_sent("VSTATE", D.pc) ~= nil and back and back.args[5] == "", "R2: back in range: VSTATE and the empty list")
    sent = {}
    tick(0.5)
    check(last_sent("VOCC", D.pc) == nil, "R2: once")
    done(v)
end

-- ------------------------------------------------------------ S16. sdcoop_seat on the host
print("S16. sdcoop_seat on the host: list, tune the seat someone sits in, print, keep across a reset")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(C, v)
    venter(B, v)
    tick(1)
    host_press(v); T = T + 0.1; run_delayed()
    tick(1)
    local st = vst(v)
    check(st.pax[2] == C.key and st.pax[3] == B.key and st.host_idx == 4, "S16: Friend3 seat 2, Friend2 seat 3, the host seat 4")
    local out = seat_cmd()
    local listed = table.concat(out, "\n")
    check(listed:find("Vehicle_SUV_C", 1, true) and listed:find("3: { side = \"L\", x = -90", 1, true) and listed:find("<- Friend2", 1, true)
        and listed:find("<- host", 1, true), "S16: list: rows and who sits there")
    sent = {}
    out = seat_cmd("3", "move", "0", "0", "5")
    check(at_seat(B.ch, v, 3, 5), "S16: Friend2 moved at once (5 cm up)")
    local s = seat_args(B)
    check(s[1] == "passenger" and s[3] == "3" and s[9] == "5" and s[13] == "0", "S16: its seat sent again with the new numbers, no notice")
    check(V._t.seats()[B.key].geo.z == 5, "S16: its record keeps the new numbers")
    tick(0.5)
    local vo = last_sent("VOCC", A.pc)
    local occ = vo and VS.parse_occ(vo.args[5]) or {}
    check(occ[2] and occ[2].idx == 3 and occ[2].geo.z == 5, "S16: VOCC follows with z 5")
    seat_cmd("4", "move", "0", "0", "3")
    check(at_seat(host_ch, v, 4, 3) and st.host_geo.z == 3, "S16: the host's own seat moved (record too)")
    out = seat_cmd("del")
    check(out[#out]:find("taken", 1, true) ~= nil and #VS.rows("Vehicle_SUV_C") == 2, "S16: del refused: the host sits in the last row")
    -- switched off while sat in: the seat stays, messages still go
    seat_cmd("3", "off")
    sent = {}
    venter(B, v)
    s = seat_args(B)
    check(s[1] == "passenger" and s[3] == "3" and s[4] == "3" and s[5] == "3", "S16: off while sat in: asked again, seat 3 (N = its number), 3 seats now")
    st.dirty = true
    tick(0.5)
    check(last_sent("VSTATE", A.pc) ~= nil and last_sent("VOCC", A.pc) ~= nil, "S16: VSTATE / VOCC keep going")
    seat_cmd("3", "on")
    out = seat_cmd("print")
    local f = load("return { " .. out[#out]:gsub("^%[SEATS%]%s*", "") .. " }")
    local rows = f and f().Vehicle_SUV_C or {}
    check(#rows == 2 and rows[1].z == 5 and rows[2].z == 3, "S16: print: the tuned rows, ready to paste")
    for _, c in ipairs(CL) do c.ch._parent = nil end
    host_ch._parent = nil
    done(v)
    V.reset("test: a role change")
    ctx.tick(S.remote_pcs)
    check(VS.edits.Vehicle_SUV_C ~= nil and VS.row("Vehicle_SUV_C", 3).z == 5, "S16: a reset (world / role change) keeps the live edits")
    local v2 = fresh("Vehicle_SUV_C")
    seat_cmd("reset")
    check(VS.edits.Vehicle_SUV_C == nil, "S16: sdcoop_seat reset drops the edits")
    done(v2)
end

print("S16b. single player: try / move only move the seated host, no records")
do
    local v = fresh("Vehicle_SUV_C")
    S.role = "standalone"
    net_mode = "standalone"
    V.tick()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = v
    v:Interact_GetInVehicle()   -- the game's own get-in (the mod does not run in single player)
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    check(host_ch._parent == v and host_ch._welded == true, "S16b: the game's get-in (welded, no mod seat)")
    local out = seat_cmd("3", "try")
    check(at_seat(host_ch, v, 3) and host_ch._welded == false, "S16b: try 3: the host moved there (unwelded first)")
    local st = V._t.vs()[v._addr]
    check(st == nil or (st.host_seat == nil and st.host_idx == nil), "S16b: no seat records written in single player")
    seat_cmd("3", "move", "0", "0", "5")
    check(at_seat(host_ch, v, 3, 5), "S16b: the seated host moves with the seat")
    host_ch:K2_DetachFromActor()
    host_ch._p.__loc = { X = v._p.__loc.X - 70, Y = v._p.__loc.Y - 40, Z = v._p.__loc.Z + 50 + 5 }
    seat_cmd("3", "move", "0", "0", "5")
    check(host_ch._parent == nil and host_ch._p.__loc.Z == v._p.__loc.Z + 55, "S16b: the host standing outside is not teleported")
    seat_cmd("reset")
    S.role = "host"
    net_mode = "host"
    V.tick()
    ctx.tick(S.remote_pcs)
    done(v)
end

-- ------------------------------------------------------------ E. the host's exit right after a client took the wheel
print("E. the host sits; a client takes the wheel: its get-in step runs at once, its player-0 window closes (the host's exit stays the host's)")
local function vseats_to(c, kind)
    local n = 0
    for _, s in ipairs(sent) do
        if s.kind == "VSEAT" and s.to == c.pc and (kind == nil or s.args[1] == kind) then n = n + 1 end
    end
    return n
end
do
    -- E1: Friend drives, Friend2 seat 2, the host seat 3; Friend gets out and
    -- the host presses exit 50 ms later, before the game's delayed step
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v)
    tick(2)
    host_press(v); T = T + 0.1; run_delayed(); tick(2)
    local st = vst(v)
    check(st.driver_key == A.key and st.pax[2] == B.key and at_seat(host_ch, v, 3), "E1: Friend drives, Friend2 seat 2, the host seat 3")
    local stray0 = V.stats.stray_vi
    sent = {}
    vexit(A, v, "d")
    check(at_seat(B.ch, v, 2) and st.driver_key == nil, "E1: Friend out: Friend2 stays in seat 2")
    seat_key(B, v)
    check(at_seat(B.ch, v, 1) and st.driver_key == B.key and v._entered_by == B.ch, "E1: Friend2's key: the wheel (the game's get-in)")
    check(B.ch._p["InVehicle?"] == true and B.ch._p.VehicleDrivingComponent._p.Vehicle == v and B.ch._p.CharacterMovement._p.MovementMode == 0,
        "E1: its get-in step ran at once (the driving state on the host's copy)")
    check(not (os.clock() < (st.scope_till or 0)), "E1: its player-0 window closed")
    T = T + 0.05
    v:ExitVehicle()     -- the host's own exit key, 50 ms after Friend2 took the wheel
    check(host_ch._parent == nil and v._exited_by == host_ch and st.host_seat == nil, "E1: the host's exit ran for the host: it is out")
    check(at_seat(B.ch, v, 1) and st.driver_key == B.key and B.ch._p["InVehicle?"] == true, "E1: Friend2 still at the wheel")
    -- the game's delayed step (0.1 s after the get-in) while the host looks at the car: it reaches the standing host
    host_ch._p.BP_JigHelperComp._p.CurrentTracActor = v
    T = T + 0.05
    run_delayed()
    host_ch._p.BP_JigHelperComp._p.CurrentTracActor = nil
    check(host_ch._parent == nil and host_ch._p["InVehicle?"] == false and host_ch._p.CharacterMovement._p.MovementMode == 1,
        "E1: the late step to the standing host undone (walking, no driving state)")
    check(V.stats.stray_vi == stray0, "E1: an expected step, not counted as a stray one")
    check(at_seat(B.ch, v, 1) and B.ch._p["InVehicle?"] == true, "E1: Friend2 keeps its driving state")
    tick(2); tick(2); tick(2)
    check(st.driver_key == B.key and at_seat(B.ch, v, 1) and V.seat_of(B.key) == "driver" and st.host_seat == nil,
        "E1: 6 s later Friend2 still drives, the host is not put back at the wheel")
    check(vseats_to(B, "driver") == 1 and vseats_to(B, "none") == 0, "E1: Friend2 got one VSEAT driver and no 'none'")
    vexit(B, v, "d")
    done(v)

    -- E2: the host stays in seat 3: the game's late step reaches it there (expected): seat kept, camera back
    local v2 = fresh("Vehicle_SUV_C")
    local tl = new_obj("TimelineComponent", "TL_VehicleCameraArmLength", { pos = 1.5 }, {
        GetTimelineLength = function() return 1.5 end,
        SetNewTime = function(s, t) s._p.pos = t end })
    host_ch._p.TL_VehicleCameraArmLength = tl
    local vi0 = host_ch._m.VehicleInteraction
    -- the game's VehicleInteraction(true) plays the camera boom from its start (@63193)
    host_ch._m.VehicleInteraction = function(s, enter, vref) if enter then tl._p.pos = 0 end return vi0(s, enter, vref) end
    venter(A, v2); T = T + 0.1; run_delayed()
    venter(B, v2)
    tick(2)
    host_press(v2); T = T + 0.1; run_delayed(); tick(2)
    tl._p.pos = 1.5
    local st2 = vst(v2)
    check(at_seat(host_ch, v2, 3) and st2.pax[2] == B.key, "E2: the host seat 3, Friend2 seat 2, Friend drives")
    stray0 = V.stats.stray_vi
    vexit(A, v2, "d")
    seat_key(B, v2)
    check(at_seat(B.ch, v2, 1) and st2.driver_key == B.key, "E2: Friend2 took the wheel with its key")
    T = T + 0.1
    run_delayed()       -- the game's step: player 0 is the host (it sits)
    check(at_seat(host_ch, v2, 3) and st2.host_seat == "passenger" and st2.host_idx == 3 and host_ch._p["InVehicle?"] == true
        and host_ch._p.VehicleDrivingComponent._p.Vehicle == v2, "E2: the late step reached the host in its seat: seat and driving state kept")
    check(tl._p.pos == 1.5, "E2: its camera boom back at the seated length (the step restarted it)")
    check(V.stats.stray_vi == stray0 and at_seat(B.ch, v2, 1) and st2.driver_key == B.key, "E2: not a stray step; Friend2 drives")
    tick(2)
    v2:ExitVehicle()
    check(host_ch._parent == nil and at_seat(B.ch, v2, 1) and st2.driver_key == B.key, "E2: later the host's exit: the host out, Friend2 drives")
    host_ch._m.VehicleInteraction = vi0
    host_ch._p.TL_VehicleCameraArmLength = nil
    vexit(B, v2, "d")
    done(v2)

    -- E3: a client gets in at a free wheel while the host sits as a passenger
    -- (the driver seat free, the host's seat kept: Friend's seat ended); the
    -- host presses exit 50 ms later
    local v3 = fresh("Vehicle_SUV_C")
    venter(A, v3); T = T + 0.1; run_delayed(); tick(2)
    host_press(v3); T = T + 0.1; run_delayed(); tick(2)
    local st3 = vst(v3)
    check(at_seat(host_ch, v3, 2) and st3.host_seat == "passenger", "E3: the host in seat 2")
    A.ch:K2_DetachFromActor()
    V._t.seats()[A.key] = nil
    st3.driver_key = nil
    sent = {}
    venter(B, v3)
    check(at_seat(B.ch, v3, 1) and st3.driver_key == B.key and B.ch._p["InVehicle?"] == true, "E3: Friend2 drives, its get-in step done at once")
    check(not (os.clock() < (st3.scope_till or 0)), "E3: its player-0 window closed")
    T = T + 0.05
    v3:ExitVehicle()
    check(host_ch._parent == nil and at_seat(B.ch, v3, 1) and st3.driver_key == B.key, "E3: the host's exit: the host out, Friend2 still drives")
    T = T + 0.05
    run_delayed()       -- the game's step: player 0 = the new driver (the host stands, not looking)
    check(at_seat(B.ch, v3, 1) and B.ch._p["InVehicle?"] == true and host_ch._p["InVehicle?"] == false, "E3: the late step to Friend2 again: harmless")
    tick(2); tick(2)
    check(st3.driver_key == B.key and vseats_to(B, "none") == 0, "E3: Friend2 still drives")
    vexit(B, v3, "d")
    done(v3)
    -- E3b: the same, but the game's get-in did not seat Friend2 (it seated the
    -- host): no early step for a client standing outside
    local v3b = fresh("Vehicle_SUV_C")
    venter(A, v3b); T = T + 0.1; run_delayed(); tick(2)
    host_press(v3b); T = T + 0.1; run_delayed(); tick(2)
    A.ch:K2_DetachFromActor()
    V._t.seats()[A.key] = nil
    vst(v3b).driver_key = nil
    local good3 = v3b._m.Interact_GetInVehicle
    v3b._m.Interact_GetInVehicle = function(self) v3b._m.Interact_GetInVehicle = good3; good3(self, host_ch) end
    venter(B, v3b)
    check(B.ch._parent == nil and B.ch._p["InVehicle?"] == false and B.ch._p.CharacterMovement._p.MovementMode == 1,
        "E3b: Friend2 not seated by the get-in: no driving state given to it outside the car")
    T = T + 0.1
    run_delayed()
    v3b:ExitVehicle()
    T = T + 0.1
    run_delayed()
    for _, c in ipairs(CL) do c.ch._parent = nil end
    host_ch._parent = nil
    done(v3b)

    -- E5: the host drove and got out; Friend2 takes the wheel with its key:
    -- the window stays for the game's step (the host is not in the car),
    -- which reaches Friend2 - not the host looking at the car
    local v5 = fresh("Vehicle_SUV_C")
    host_press(v5); T = T + 0.1; run_delayed(); tick(2)
    venter(B, v5)
    tick(2)
    local st5 = vst(v5)
    check(at_seat(host_ch, v5, 1) and st5.pax[2] == B.key, "E5: the host drives, Friend2 seat 2")
    local vi_h, vi5 = 0, host_ch._m.VehicleInteraction
    host_ch._m.VehicleInteraction = function(s, enter, vref) if enter then vi_h = vi_h + 1 end return vi5(s, enter, vref) end
    host_ch._p.BP_JigHelperComp._p.CurrentTracActor = v5
    stray0 = V.stats.stray_vi
    v5:ExitVehicle()
    check(host_ch._parent == nil and at_seat(B.ch, v5, 2) and st5.driver_key == nil, "E5: the host out, Friend2 stays in seat 2")
    seat_key(B, v5)
    check(at_seat(B.ch, v5, 1) and st5.driver_key == B.key, "E5: Friend2's key: the wheel")
    check(os.clock() < (st5.scope_till or 0), "E5: Friend2's player-0 window open (the host is not in the car)")
    T = T + 0.1
    run_delayed()
    host_ch._p.BP_JigHelperComp._p.CurrentTracActor = nil
    host_ch._m.VehicleInteraction = vi5
    check(vi_h == 0 and V.stats.stray_vi == stray0 and B.ch._p["InVehicle?"] == true, "E5: the game's step reached Friend2, the host got none")
    -- E6: the host stands; a client got in and its step came: the window ends
    -- there - the host looking at the car is player 0 for it again (its prompt)
    vexit(B, v5, "d")
    tick(2)
    venter(A, v5)
    check(st5.driver_key == A.key and os.clock() < (st5.scope_till or 0), "E6: Friend drives, its window open")
    T = T + 0.1
    run_delayed()
    check(A.ch._p["InVehicle?"] == true and not (os.clock() < (st5.scope_till or 0)), "E6: Friend's get-in step reached it: its window closed")
    host_ch._p.BP_JigHelperComp._p.CurrentTracActor = v5
    check(player0(v5) == host_ch, "E6: the host looking at the car is player 0 for it (not Friend)")
    host_ch._p.BP_JigHelperComp._p.CurrentTracActor = nil
    vexit(A, v5, "d")
    done(v5)

    -- E4: the camera with two left: the driver and seat 3 behind it
    local v4 = fresh("Vehicle_SUV_C")
    venter(A, v4); T = T + 0.1; run_delayed()
    venter(B, v4); venter(C, v4)
    tick(1)
    check(A.ch._p.CapsuleComponent._p.cam == 0 and C.ch._p.CapsuleComponent._p.cam == 0, "E4: three seated: camera passes them")
    vexit(B, v4, "p", 2)
    tick(1)
    check(at_seat(A.ch, v4, 1) and at_seat(C.ch, v4, 3) and A.ch._p.CapsuleComponent._p.cam == 0 and A.ch._p.Mesh._p.cam == 0
        and C.ch._p.CapsuleComponent._p.cam == 0 and C.ch._p.Mesh._p.cam == 0, "E4: the driver and seat 3 left (two): the camera still passes them")
    check(B.ch._p.CapsuleComponent._p.cam == 2 and B.ch._p.Mesh._p.cam == 2, "E4: Friend2 out: its camera response back")
    vexit(C, v4, "d", 3)
    tick(1)
    check(A.ch._p.CapsuleComponent._p.cam == 2 and A.ch._p.Mesh._p.cam == 2 and C.ch._p.CapsuleComponent._p.cam == 2,
        "E4: only the front row (the driver) left: camera responses back")
    -- the host in seat 3 behind a client driver (two in the car)
    venter(B, v4)
    tick(1)
    host_press(v4); T = T + 0.1; run_delayed()
    vexit(B, v4, "p", 2)
    tick(1)
    local st4 = vst(v4)
    check(st4.host_idx == 3 and at_seat(host_ch, v4, 3) and A.ch._p.CapsuleComponent._p.cam == 0 and A.ch._p.Mesh._p.cam == 0,
        "E4: the driver and the host in seat 3: the driver's camera response off on the host")
    check(host_ch._p.CapsuleComponent._p.cam == 2, "E4: the host's own character untouched")
    v4:ExitVehicle()
    tick(1)
    check(A.ch._p.CapsuleComponent._p.cam == 2, "E4: the host out (driver alone): back")
    vexit(A, v4, "d")
    done(v4)
end

-- ------------------------------------------------------------ W. the driver gets out: the passengers stay (13.11, the user)
-- Up to now the lowest seat was moved to the wheel 1.5 s after the driver's
-- exit (also a passenger that was getting out itself). Now every passenger
-- stays where it sat; the car stands parked (handbrake on, engine and timers
-- off) until somebody drives; a passenger takes the wheel only with its seat
-- key (K below).
print("W. the driver gets out: the passengers stay in their seats, the car parked until somebody drives")
local function parked(v)
    return v._p.VehicleMovementComponent._p.hb == true and timers[tkey(v._p.FuelComponent, "FuelSpend")] == nil
        and timers[tkey(v, "Event_Noise")] == nil and timers[tkey(v, "CheckWater")] == nil
end
local function tagged(v, name)
    for _, t in ipairs(rawget(v._p.Tags, "_items")) do
        if t and t._fname == name then return true end
    end
    return false
end
check(V._t.seatk.promote_after == nil and V._t.seatk.promote_later == nil and V._t.seatk.promote_due == nil,
    "W: no automatic hand-over left (promote_after / promote_later / promote_due gone)")
do
    -- W1: Friend drives, the host in seat 2; Friend gets out, the host 0.4 s later (13.11 17:12:13-14)
    local v = fresh("Vehicle_FlatbedTruck_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    local st = vst(v)
    check(st.driver_key == A.key and at_seat(host_ch, v, 2) and st.host_seat == "passenger", "W1: Friend drives, the host in seat 2")
    local n0, p0 = #toasts, V.stats.promoted
    vexit(A, v, "d")
    check(A.ch._parent == nil and st.driver_key == nil, "W1: Friend out")
    check(at_seat(host_ch, v, 2) and st.host_seat == "passenger" and st.host_idx == 2,
        "W1: the host stays in seat 2 (up to 0.9.0: moved to the wheel)")
    check(parked(v) and v._p.EngineSound._p.fading == true and v._resp[2] == 0,
        "W1: the car parked (handbrake on, no fuel spent, timers off, engine off), still 'occupied' for the host")
    check(toast_since(n0, "Руль свободен: нажмите G, чтобы пересесть."), "W1: the host told once: the wheel is free, its key")
    T = T + 0.4
    v:ExitVehicle()     -- the host's own exit key
    check(host_ch._parent == nil and st.host_seat == nil, "W1: the host out of its own seat")
    check(parked(v) and v._resp[2] == 2 and not tagged(v, "Player"), "W1: the last one out: the empty car parked (collision back, drive tags off)")
    tick(0.5); tick(0.5); tick(0.5); tick(0.5)
    check(V.stats.promoted == p0 and not toast_since(n0, "Теперь машину ведёте вы.") and host_ch._parent == nil,
        "W1: nobody was put at the wheel, no 'You now drive'")
    done(v)

    -- W2: the host drives, Friend in seat 2; the host gets out, Friend 0.7 s later (13.11 17:35:59-36:00)
    v = fresh("Vehicle_FlatbedTruck_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(A, v); tick(1)
    st = vst(v)
    check(st.host_seat == "driver" and st.pax[2] == A.key and at_seat(A.ch, v, 2), "W2: the host drives, Friend in seat 2")
    sent = {}
    p0 = V.stats.promoted
    v:ExitVehicle()
    check(host_ch._parent == nil and at_seat(A.ch, v, 2) and st.driver_key == nil and V.seat_of(A.key) == "passenger",
        "W2: the host out; Friend stays in seat 2")
    check(vseats_to(A) == 0 and v._entered_by == host_ch, "W2: no VSEAT, no game get-in for Friend")
    check(count_sent("VSWR", A.pc) == 1 and last_sent("VSWR", A.pc).args[1] == "wheel", "W2: Friend told once: the wheel is free (VSWR wheel)")
    check(parked(v) and v._resp[2] == 0, "W2: parked, still 'occupied' for Friend")
    tick(0.5); tick(0.5); tick(0.5); tick(0.5)
    check(at_seat(A.ch, v, 2) and st.driver_key == nil and vseats_to(A) == 0 and count_sent("VSWR", A.pc) == 1,
        "W2: 2 s later Friend still in seat 2, told nothing more")
    T = T + 0.2
    vexit(A, v, "p", 2)
    -- (the host's copy of Friend at the passenger-door socket; on Friend's own
    -- screen its game's exit picks the door: the driver's when that is free)
    check(A.ch._parent == nil and A.ch._p.__loc.Y > v._p.__loc.Y + 100, "W2: Friend out of seat 2 (the host's copy at the passenger-door socket)")
    check(parked(v) and v._resp[2] == 2 and v._resp[4] == 2 and not tagged(v, "Player"),
        "W2: the last one out: the empty car parked (collision back, drive tags off)")
    check(vseats_to(A, "driver") == 0 and v._entered_by == host_ch and V.stats.promoted == p0,
        "W2: Friend never put at the wheel (no VSEAT driver, no get-in for it)")
    check(st.driver_key == nil and next(st.pax) == nil, "W2: an empty car")
    done(v)

    -- W3: the passenger stays as long as it likes; its key takes the wheel - the host ...
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    vexit(A, v, "d")
    n0 = #toasts
    for _ = 1, 20 do tick(0.5) end
    check(at_seat(host_ch, v, 2) and st.host_seat == "passenger" and parked(v) and not toast_since(n0, "Руль свободен"),
        "W3: 10 s after the driver: the host still in seat 2, the car parked, told only once")
    seat_key("H", v)
    check(at_seat(host_ch, v, 1) and st.host_seat == "driver" and st.host_idx == nil, "W3: the host's key: the wheel")
    check(v._p.VehicleMovementComponent._p.hb == false and v._p.EngineSound._p.active == true and v._p.EngineSound._p.fading == false
        and timers[tkey(v._p.FuelComponent, "FuelSpend")] == true, "W3: handbrake off, engine running, fuel spent again")
    check(toast_since(n0, "Место 1 из 4: вы за рулём."), "W3: the host told 'Seat 1 of 4: you drive'")
    v:ExitVehicle()
    done(v)
    -- ... or a client (the game's get-in for it, VSEAT driver)
    v = fresh("Vehicle_SUV_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(A, v); tick(1)
    st = vst(v)
    sent = {}
    v:ExitVehicle()
    for _ = 1, 10 do tick(0.5) end
    check(at_seat(A.ch, v, 2) and vseats_to(A) == 0 and v._entered_by == host_ch and parked(v),
        "W3: 5 s after the host: Friend still in seat 2, no VSEAT, the car parked")
    seat_key(A, v)
    check(at_seat(A.ch, v, 1) and st.driver_key == A.key and v._entered_by == A.ch and seat_args(A)[1] == "driver" and v._owner == A.pc
        and v._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true,
        "W3: Friend's key: the wheel (the game's get-in, VSEAT driver, owner, its inputs)")
    T = T + 0.1; run_delayed()
    vexit(A, v, "d")
    done(v)

    -- W4: somebody gets in while the wheel is free: it drives (the first free seat)
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); tick(1)
    st = vst(v)
    p0 = V.stats.promoted
    vexit(A, v, "d")
    tick(0.5)
    venter(C, v)
    check(at_seat(C.ch, v, 1) and st.driver_key == C.key and seat_args(C)[1] == "driver" and at_seat(B.ch, v, 2),
        "W4: Friend3 gets in at the free wheel: it drives; Friend2 stays in seat 2")
    T = T + 0.1; run_delayed()
    tick(0.5); tick(0.5); tick(0.5)
    check(st.driver_key == C.key and at_seat(C.ch, v, 1) and at_seat(B.ch, v, 2) and st.pax[2] == B.key and V.stats.promoted == p0
        and vseats_to(B, "driver") == 0, "W4: later: Friend3 drives, Friend2 in seat 2")
    check(v._p.VehicleMovementComponent._p.hb == false and v._p.EngineSound._p.active == true, "W4: the new driver's car runs (not parked)")
    vexit(C, v, "d"); vexit(B, v, "p", 2)
    done(v)

    -- W5: three in the car: the driver and seat 2 get out together; seat 3 stays
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); tick(1)
    st = vst(v)
    sent = {}
    vexit(A, v, "d")
    T = T + 0.3
    vexit(B, v, "p", 2)
    tick(0.5); tick(0.5); tick(0.5); tick(0.5)
    check(at_seat(C.ch, v, 3) and st.driver_key == nil and vseats_to(B) == 0 and vseats_to(C) == 0 and B.ch._parent == nil,
        "W5: Friend and Friend2 out; Friend3 stays in seat 3, nobody moved")
    check(parked(v) and v._resp[2] == 0, "W5: parked, still 'occupied' for Friend3")
    seat_key(C, v)
    check(at_seat(C.ch, v, 1) and st.driver_key == C.key and v._entered_by == C.ch, "W5: Friend3's key: the wheel")
    T = T + 0.1; run_delayed()
    vexit(C, v, "d")
    done(v)

    -- W6: the driver disconnects, the host alone in seat 2 (no client left: the
    -- host's tick returns early): the host stays, its key still works
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    local pcs = S.remote_pcs
    S.remote_pcs = {}
    A.pc._p.NetConnection = nil
    A.ch._parent = nil
    n0 = #toasts
    tick(0.5)
    check(V.seat_of(A.key) == nil and at_seat(host_ch, v, 2) and st.host_seat == "passenger" and parked(v)
        and toast_since(n0, "Руль свободен"), "W6: Friend gone (no client left): the host stays in seat 2, told; the car parked")
    seat_key("H", v)
    check(at_seat(host_ch, v, 1) and st.host_seat == "driver" and v._p.VehicleMovementComponent._p.hb == false
        and v._p.EngineSound._p.active == true and v._p.EngineSound._p.fading == false, "W6: the host's key: the wheel, handbrake off, engine on")
    S.remote_pcs = pcs
    A.pc._p.NetConnection = A.conn
    v:ExitVehicle()
    done(v)

    -- W7: the host dies at the wheel, Friend in seat 2: Friend stays, told; its key takes it
    v = fresh("Vehicle_SUV_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(A, v); tick(1)
    st = vst(v)
    sent = {}
    host_ch._p["PlayerDead?"] = true
    host_pc._p.Pawn = nil
    tick(0.5)
    check(st.host_seat == nil and at_seat(A.ch, v, 2) and st.driver_key == nil and vseats_to(A) == 0
        and last_sent("VSWR", A.pc) and last_sent("VSWR", A.pc).args[1] == "wheel" and parked(v),
        "W7: the host dead at the wheel: Friend stays in seat 2, told the wheel is free; the car parked")
    seat_key(A, v)
    check(at_seat(A.ch, v, 1) and st.driver_key == A.key and v._entered_by == A.ch, "W7: Friend's key: the wheel")
    host_pc._p.Pawn = host_ch
    host_ch._p["PlayerDead?"] = false
    host_ch._parent = nil
    T = T + 0.1; run_delayed()
    vexit(A, v, "d")
    done(v)
    -- W8: a remote driver record beside the host's wheel ends (demote, no
    -- free seat): the host keeps driving - its car is not stopped
    v = fresh("Vehicle_SUV_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(2)
    venter(B, v)
    st = vst(v)
    A.ch._parent = v
    V._t.seats()[A.key] = { vaddr = v._addr, vname = v._short, seat = "driver", at = T }
    st.driver_key, st.host_till = A.key, 0
    tick(1)
    check(seat_args(A)[1] == "none" and V.seat_of(A.key) == nil and at_seat(host_ch, v, 1) and st.host_seat == "driver",
        "W8: the record beside the host's wheel ended (refused: full); the host at the wheel")
    check(v._p.VehicleMovementComponent._p.hb == false and v._p.EngineSound._p.active == true
        and v._p.EngineSound._p.fading == false and timers[tkey(v._p.FuelComponent, "FuelSpend")] == true,
        "W8: the host's car keeps running (handbrake off, engine, fuel)")
    v:ExitVehicle()
    vexit(B, v, "p", 2)
    done(v)

    -- W9: a driver alone gets out: the car is left as the exit leaves it, nobody told
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    sent = {}
    vexit(A, v, "d")
    check(v._resp[2] == 2 and v._p.VehicleMovementComponent._p.hb == true and count_sent("VSWR") == 0,
        "W9: the lone driver out: collision back, handbrake on, no 'wheel free' message")
    done(v)

    -- W10: the driver's connection drops (other clients still on): the host stays in seat 2
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    A.pc._p.NetConnection = nil
    tick(0.5)
    check(V.seat_of(A.key) == nil and at_seat(host_ch, v, 2) and st.host_seat == "passenger" and parked(v),
        "W10: Friend's connection drops (others still on): the host stays in seat 2, the car parked")
    A.pc._p.NetConnection = A.conn
    A.ch._parent = nil
    v:ExitVehicle()
    done(v)
    -- ... a client driver dies at the wheel: Friend (seat 2) stays, told; its key takes it
    v = fresh("Vehicle_SUV_C")
    venter(B, v); T = T + 0.1; run_delayed(); tick(1)
    venter(A, v); tick(1)
    st = vst(v)
    sent = {}
    B.ch._p["PlayerDead?"] = true
    tick(0.5)
    check(V.seat_of(B.key) == nil and at_seat(A.ch, v, 2) and st.driver_key == nil and vseats_to(A) == 0
        and last_sent("VSWR", A.pc) and last_sent("VSWR", A.pc).args[1] == "wheel",
        "W10: Friend2 dies at the wheel: Friend stays in seat 2, told the wheel is free")
    seat_key(A, v)
    check(at_seat(A.ch, v, 1) and st.driver_key == A.key and v._entered_by == A.ch and seat_args(A)[1] == "driver",
        "W10: Friend's key: the wheel (the game's get-in, VSEAT driver)")
    B.ch._p["PlayerDead?"] = false
    T = T + 0.1; run_delayed()
    vexit(A, v, "d")
    done(v)

    -- W11: the driver's seat ends while the host's copy still does 30 MPH (a
    -- disconnect at speed): the passenger stays, the car is braked (handbrake)
    v = fresh("Vehicle_SUV_C")
    v._p.VehicleMovementComponent._m.GetForwardSpeedMPH = function() return 30 end
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    A.pc._p.NetConnection = nil
    tick(0.5)
    check(at_seat(host_ch, v, 2) and st.host_seat == "passenger" and v._p.VehicleMovementComponent._p.hb == true,
        "W11: the driver gone at 30 MPH: the host stays in seat 2, handbrake on")
    A.pc._p.NetConnection = A.conn
    A.ch._parent = nil
    v:ExitVehicle()
    done(v)

    -- W12: the last passenger of a parked car dies / its connection drops:
    -- its seat freed on the tick, the empty car parked - collision back
    for _, how in ipairs({ "dies", "drops (no client left)" }) do
        v = fresh("Vehicle_SUV_C")
        host_press(v); T = T + 0.1; run_delayed(); tick(1)
        venter(A, v); tick(1)
        st = vst(v)
        p0 = V.stats.promoted
        v:ExitVehicle()
        tick(0.5); tick(0.5)
        check(at_seat(A.ch, v, 2) and v._resp[2] == 0, "W12 (" .. how .. "): 1 s after the host: Friend still in seat 2, the car 'occupied'")
        local pcs2 = S.remote_pcs
        if how == "dies" then
            A.ch._p["PlayerDead?"] = true
        else
            S.remote_pcs = {}
            A.pc._p.NetConnection = nil
        end
        tick(0.5)
        check(V.seat_of(A.key) == nil and st.driver_key == nil and next(st.pax) == nil and V.stats.promoted == p0,
            "W12: Friend " .. how .. ": its seat freed, nobody at the wheel")
        check(v._resp[2] == 2 and v._resp[4] == 2 and parked(v), "W12: Friend " .. how .. ": the empty car parked (collision back, handbrake on, timers off)")
        A.ch._p["PlayerDead?"] = false
        S.remote_pcs = pcs2
        A.pc._p.NetConnection = A.conn
        A.ch._parent = nil
        done(v)
    end

    -- W13: a passenger out of a car somebody still drives: not parked
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); tick(1)
    st = vst(v)
    vexit(B, v, "p", 2)
    check(st.driver_key == A.key and v._p.VehicleMovementComponent._p.hb == false and v._resp[2] == 0
        and v._p.EngineSound._p.active == true and v._p.EngineSound._p.fading == false,
        "W13: Friend2 out of seat 2 while Friend drives: the car runs on (handbrake off, collision off, engine on)")
    vexit(A, v, "d")
    done(v)
    -- ... the driver and seat 2 out together, Friend3 still in seat 3: 'occupied' for it
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); tick(1)
    st = vst(v)
    vexit(A, v, "d")
    T = T + 0.3
    vexit(B, v, "p", 2)
    check(at_seat(C.ch, v, 3) and v._resp[2] == 0 and parked(v), "W13: Friend2 out, Friend3 still in seat 3: parked, collision off (occupied)")
    vexit(C, v, "d", 3)
    check(v._resp[2] == 2 and not tagged(v, "Player"), "W13: Friend3 out last: collision back, drive tags off")
    done(v)
    -- ... the host still in seat 2: a client out of seat 3 does not empty it
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(B, v); tick(1)
    st = vst(v)
    check(st.host_seat == "passenger" and st.host_idx == 2 and st.pax[3] == B.key, "W13: Friend drives, the host in seat 2, Friend2 in seat 3")
    vexit(A, v, "d")
    T = T + 0.3
    vexit(B, v, "p", 3)
    check(at_seat(host_ch, v, 2) and v._resp[2] == 0, "W13: Friend2 out, the host still in seat 2: collision off (occupied)")
    v:ExitVehicle()
    check(host_ch._parent == nil and v._resp[2] == 2 and not tagged(v, "Player") and parked(v),
        "W13: the host (a passenger) out last: the empty car parked (collision back, drive tags off)")
    done(v)
    -- ... the host gets out of a parked car a client still sits in: still 'occupied'
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(B, v); tick(1)
    st = vst(v)
    vexit(A, v, "d")
    v:ExitVehicle()
    check(host_ch._parent == nil and at_seat(B.ch, v, 3) and v._resp[2] == 0 and tagged(v, "Player"),
        "W13: the host out of a parked car Friend2 still sits in: collision stays off, tags kept")
    vexit(B, v, "p", 3)
    done(v)
end

-- ------------------------------------------------------------ K. the seat key
print("K. the seat key: the wheel when free, else the next free seat, round; none free: a notice")
do
    -- K1: an older client (no "sw") is not told and never moved; a newer one is
    local v = fresh("Vehicle_Charger_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(C, v, true)       -- older: seats 1-2
    venter(B, v)
    local st = vst(v)
    check(st.pax[2] == C.key and st.pax[3] == B.key and V._t.seats()[C.key].sw ~= true and V._t.seats()[B.key].sw == true,
        "K1: Friend drives, Friend3 (older client) seat 2, Friend2 seat 3; only Friend2 has the seat key")
    sent = {}
    vexit(A, v, "d")
    check(count_sent("VSWR", C.pc) == 0 and count_sent("VSWR", B.pc) == 1, "K1: the wheel free: Friend2 told, the older client not")
    for _ = 1, 6 do tick(0.5) end
    check(at_seat(C.ch, v, 2) and at_seat(B.ch, v, 3) and vseats_to(C) == 0 and vseats_to(B) == 0, "K1: 3 s later both still in their seats")
    seat_key(B, v)
    check(at_seat(B.ch, v, 1) and st.driver_key == B.key and at_seat(C.ch, v, 2) and st.pax[2] == C.key,
        "K1: Friend2's key (seat 3): the wheel; the older client stays in seat 2")
    T = T + 0.1; run_delayed()
    vexit(B, v, "d")
    vexit(C, v, "p", 2)
    done(v)

    -- K2: the wheel taken: the next free seat in seat order, round; a double press moves once
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); tick(1)
    st = vst(v)
    sent = {}
    seat_key(B, v)
    local s = seat_args(B)
    check(at_seat(B.ch, v, 4) and st.pax[4] == B.key and st.pax[2] == nil and V.seat_idx(B.key) == 4 and V.seat_of(B.key) == "passenger",
        "K2: Friend2's key in seat 2 (3 taken): seat 4, its record")
    check(s[1] == "passenger" and s[2] == "Friend" and s[3] == "4" and s[4] == "4" and s[5] == "4" and s[13] == "1" and s[14] == "sw",
        "K2: VSEAT passenger: seat 4 of 4, Friend drives, with its notice")
    check(B.ch._montage == montage and B.ch._welded == false and v._entered_by == A.ch, "K2: the car pose, unwelded, no get-in for a passenger move")
    local n1 = vseats_to(B)
    seat_key(B, v)
    check(at_seat(B.ch, v, 4) and vseats_to(B) == n1, "K2: a second press within 0.4 s: nothing")
    T = T + 0.5
    seat_key(B, v)
    check(at_seat(B.ch, v, 2) and st.pax[2] == B.key and st.pax[4] == nil and seat_args(B)[3] == "2", "K2: again: round to seat 2")
    seat_key(C, v)
    check(at_seat(C.ch, v, 4) and st.pax[4] == C.key, "K2: Friend3's key in seat 3: seat 4")
    tick(0.5)
    local vo = last_sent("VOCC", D.pc)
    local occ = vo and VS.parse_occ(vo.args[5]) or {}
    check(#occ == 2 and occ[1].idx == 2 and occ[1].id == B.id and occ[2].idx == 4 and occ[2].id == C.id, "K2: VOCC follows (2 Friend2, 4 Friend3)")
    -- K3: nothing free: a notice, nobody moves
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    check(at_seat(host_ch, v, 3) and st.host_idx == 3, "K3: the host gets seat 3: the car is full")
    T = T + 0.5
    sent = {}
    seat_key(B, v)
    local r = last_sent("VSWR", B.pc)
    check(r and r.args[1] == "full" and r.args[2] == "4" and at_seat(B.ch, v, 2) and vseats_to(B) == 0, "K3: Friend2's key in a full car: VSWR full|4, stays")
    local n0 = #toasts
    seat_key("H", v)
    check(toast_since(n0, "Пересесть некуда: все места заняты.") and at_seat(host_ch, v, 3) and st.host_idx == 3,
        "K3: the host's key in a full car: the game's notice, stays")
    -- the driver's key moves nothing
    seat_key(A, v)
    check(at_seat(A.ch, v, 1) and st.driver_key == A.key and count_sent("VSWR", A.pc) == 0, "K3: the driver's key: nothing")
    v:ExitVehicle()
    vexit(A, v, "d"); vexit(B, v, "p", 2)
    vexit(C, v, "p", 4)
    check(C.ch._parent == nil and d(C.ch._p.__loc, { X = v._p.__loc.X - 70, Y = v._p.__loc.Y + 200, Z = v._p.__loc.Z }) < 1,
        "K3: Friend3 (moved 3 -> 4 by its key) gets out at seat 4's own (rear right) door")
    done(v)

    -- K4: the host switching: seat 2 -> 3 -> 4 -> 2 while Friend drives; the wheel once Friend left
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    n0 = #toasts
    seat_key("H", v)
    check(at_seat(host_ch, v, 3) and st.host_idx == 3 and st.host_geo and st.host_geo.x == -90 and toast_since(n0, "Место 3 из 4: машину ведёт Friend."),
        "K4: the host's key in seat 2: seat 3, 'Seat 3 of 4'")
    seat_key("H", v)
    seat_key("H", v)
    check(at_seat(host_ch, v, 2) and st.host_idx == 2 and host_ch._welded == false, "K4: twice more: seat 4, then round to seat 2")
    seat_key("H", v)
    tick(0.5)
    vo = last_sent("VOCC", B.pc)
    occ = vo and VS.parse_occ(vo.args[5]) or {}
    check(#occ == 1 and occ[1].idx == 3 and occ[1].id == tostring(host_ch._pid), "K4: VOCC lists the host in seat 3")
    v:ExitVehicle()
    check(host_ch._parent == nil and d(host_ch._p.__loc, { X = v._p.__loc.X - 70, Y = v._p.__loc.Y - 200, Z = v._p.__loc.Z }) < 1,
        "K4: the host's exit after its moves: at seat 3's own (rear left) door")
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    check(at_seat(host_ch, v, 2) and st.host_idx == 2, "K4: back in: the first free seat (2)")
    seat_key("H", v)
    check(at_seat(host_ch, v, 3), "K4: its key again: seat 3")
    vexit(A, v, "d")
    n0 = #toasts
    seat_key("H", v)
    check(at_seat(host_ch, v, 1) and st.host_seat == "driver" and v._p.VehicleMovementComponent._p.hb == false
        and toast_since(n0, "Место 1 из 4: вы за рулём."), "K4: the driver gone: the host's key in seat 3: the wheel, 'Seat 1 of 4'")
    n0 = #toasts
    seat_key("H", v)
    check(at_seat(host_ch, v, 1) and st.host_seat == "driver" and #toasts == n0, "K4: the host's key at the wheel: nothing")
    v:ExitVehicle()
    done(v)

    -- K5: 2-seat cars
    for _, cls in ipairs({ "Vehicle_Buggy_C", "Vehicle_GolfCart_C" }) do
        v = fresh(cls)
        venter(A, v); T = T + 0.1; run_delayed()
        venter(B, v); tick(1)
        st = vst(v)
        sent = {}
        seat_key(B, v)
        r = last_sent("VSWR", B.pc)
        check(r and r.args[1] == "full" and r.args[2] == "2" and at_seat(B.ch, v, 2), "K5: " .. cls .. ": Friend2's key with a driver: none free (2 seats)")
        vexit(A, v, "d")
        T = T + 0.5
        seat_key(B, v)
        check(at_seat(B.ch, v, 1) and st.driver_key == B.key and seat_args(B)[1] == "driver" and seat_args(B)[5] == "2",
            "K5: " .. cls .. ": the driver gone: Friend2's key: the wheel (seat 1 of 2)")
        T = T + 0.1; run_delayed()
        vexit(B, v, "d")
        done(v)
    end
    v = fresh("Vehicle_GolfCart_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    n0 = #toasts
    seat_key("H", v)
    check(at_seat(host_ch, v, 2) and toast_since(n0, "Пересесть некуда: все места заняты."), "K5: golf cart, the host's key beside Friend: none free")
    vexit(A, v, "d")
    seat_key("H", v)
    check(at_seat(host_ch, v, 1) and st.host_seat == "driver" and toast_since(n0, "Теперь машину ведёте вы."),
        "K5: golf cart: the host's key at a free wheel: 'You now drive' (2 seats)")
    v:ExitVehicle()
    done(v)

    -- K6: untuned / switched-off rows are skipped
    v = fresh("Vehicle_PickupTruck_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); tick(1)
    st = vst(v)
    sent = {}
    seat_key(B, v)
    r = last_sent("VSWR", B.pc)
    check(r and r.args[1] == "full" and r.args[2] == "2" and at_seat(B.ch, v, 2), "K6: pickup bed untuned (off): Friend2's key: none free (2 seats)")
    cfg.set("vehicle_seats_untuned", true)
    T = T + 0.5
    seat_key(B, v)
    check(st.pax[3] == B.key and seat_args(B)[3] == "3" and seat_args(B)[11] == "floor" and B.ch._montage == floor_m,
        "K6: untuned on: seat 3 in the bed, the floor pose")
    tick(0.5)
    check(B.ch._montage == floor_m, "K6: the tick keeps the floor pose")
    T = T + 0.5
    seat_key(B, v)
    T = T + 0.5
    seat_key(B, v)
    check(at_seat(B.ch, v, 2) and st.pax[2] == B.key and B.ch._montage == montage, "K6: round to seat 2: the car pose again")
    cfg.set("vehicle_seats_untuned", false)
    vexit(B, v, "p", 2); vexit(A, v, "d")
    done(v)
    v = fresh("Vehicle_Sheriff_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); tick(1)
    st = vst(v)
    seat_cmd("4", "off")
    sent = {}
    seat_key(B, v)
    r = last_sent("VSWR", B.pc)
    check(r and r.args[1] == "full" and r.args[2] == "3" and at_seat(B.ch, v, 2), "K6: a row switched off (sdcoop_seat 4 off): skipped, none free (3 seats)")
    seat_cmd("reset")
    vexit(C, v, "d", 3); vexit(B, v, "p", 2); vexit(A, v, "d")
    done(v)

    -- K7: driver-only controls and the kill credit follow the new driver
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    st = vst(v)
    check(v._p.Flipped == true, "K7: the host a passenger: its flip key held (Flipped)")
    vexit(A, v, "d")
    seat_key(B, v)
    T = T + 0.1; run_delayed()
    local lights = v._p["LightsOn?"]
    deliver("VLIGHT", { vstr(v)[1], vstr(v)[2], vstr(v)[3], v._cls, lights and "0" or "1" }, B.pc)
    check(v._p["LightsOn?"] ~= lights, "K7: Friend2 (took the wheel with its key): its lights count")
    check(V.seat_of(B.key) == "driver" and V.seat_idx(B.key) == 1, "K7: the kill credit's seat_of: Friend2 is the driver")
    vexit(B, v, "d")
    seat_key("H", v)
    tick(0.5)
    check(st.host_seat == "driver" and v._p.Flipped == false, "K7: the host's key: the wheel; its flip key free again")
    venter(C, v); tick(1)
    lights = v._p["LightsOn?"]
    deliver("VLIGHT", { vstr(v)[1], vstr(v)[2], vstr(v)[3], v._cls, lights and "0" or "1" }, C.pc)
    check(v._p["LightsOn?"] == lights and V.seat_of(C.key) == "passenger", "K7: a passenger's lights refused (the host drives)")
    v:ExitVehicle()
    vexit(C, v, "p", 2)
    done(v)

    -- K8: the key is read on the game thread only (main.lua's frame loop),
    -- only while this machine's player sits as a passenger; one press = one move
    local src = io.open(SCRIPTS .. "/sdc_vehicles.lua"):read("a")
    local binds = 0
    for line in src:gmatch("[^\n]+") do
        local code = line:gsub("%-%-.*$", "")
        if code:find("RegisterKeyBind", 1, true) then binds = binds + 1 end
    end
    check(binds == 0, "K8: no UE4SS key bind in sdc_vehicles (its thread)")
    local down, reads, in_frame = {}, {}, false
    host_pc._m.IsInputKeyDown = function(_, k)
        local name = k.KeyName:ToString()
        reads[#reads + 1] = { key = name, frame = in_frame }
        return down[name] == true
    end
    local function frame() in_frame = true; V.frame_tick(); in_frame = false end
    local function g_reads(only_out)
        local n = 0
        for _, x in ipairs(reads) do if x.key == "G" and (not only_out or not x.frame) then n = n + 1 end end
        return n
    end
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    reads = {}
    frame()
    check(g_reads() == 0, "K8: the host on foot: the key not read")
    host_press(v); T = T + 0.1; run_delayed(); tick(0.5)
    st = vst(v)
    frame()
    check(g_reads() == 1 and at_seat(host_ch, v, 2), "K8: a passenger, the key up: read in the frame")
    v:ExitVehicle()
    tick(0.5)
    reads = {}
    frame()
    check(g_reads() == 0 and host_ch._parent == nil, "K8: out again: not read")
    down.G = true      -- held while getting in: no press
    host_press(v); T = T + 0.1; run_delayed(); tick(0.5)
    frame(); frame()
    check(g_reads() >= 2 and at_seat(host_ch, v, 2), "K8: a passenger: read every frame; a key held while getting in is no press")
    down.G = false; frame()
    down.G = true; frame()
    check(at_seat(host_ch, v, 3), "K8: a press (down edge in the frame loop): seat 3")
    frame(); frame(); frame()
    check(at_seat(host_ch, v, 3), "K8: held: one move only")
    down.G = false; frame(); down.G = true; frame(); down.G = false; frame()
    check(at_seat(host_ch, v, 4), "K8: released and pressed again: seat 4")
    for _ = 1, 4 do tick(0.5) end
    check(g_reads(true) == 0, "K8: never read outside the frame loop (the 0.5 s tick, the handlers)")
    -- something holds the input: nothing
    package.loaded["sdc_chat"] = { is_open = function() return true end }
    down.G = true; frame(); down.G = false; frame()
    check(at_seat(host_ch, v, 4), "K8: the chat line open: the press does nothing")
    package.loaded["sdc_chat"] = nil
    host_pc._p.bShowMouseCursor = true
    down.G = true; frame(); down.G = false; frame()
    check(at_seat(host_ch, v, 4), "K8: the mouse cursor on (a game window): nothing")
    host_pc._p.bShowMouseCursor = nil
    -- another key from the config; none
    cfg.set("vehicle_seat_key", "U")
    tick(0.5)
    reads = {}
    frame(); down.U = true; frame(); down.U = false; frame()
    check(at_seat(host_ch, v, 2) and g_reads() == 0, "K8: vehicle_seat_key = U: U moves (round to seat 2), G is not read")
    cfg.set("vehicle_seat_key", "")
    tick(0.5)
    reads = {}
    frame(); down.U = true; frame(); down.U = false; frame()
    local other = 0
    for _, x in ipairs(reads) do if x.key ~= "Tab" then other = other + 1 end end
    check(#reads == 3 and other == 0 and at_seat(host_ch, v, 2), "K8: no key set: nothing read but Tab")
    n0 = #toasts
    vexit(A, v, "d")
    check(toast_since(n0, "Руль свободен: чтобы вести, выйдите и сядьте снова."), "K8: no key set: the 'wheel free' notice says get out and in")
    cfg.set("vehicle_seat_key", "G")
    tick(0.5)
    -- K9: the host passenger of a parked car: its own driving keys do not move it
    local mc = v._p.VehicleMovementComponent
    mc._m.GetHandbrakeInput = function(s) return s._p.hb end
    mc._m.SetThrottleInput = function(s, x) s._p.thr = x end
    mc._m.SetBrakeInput = function(s, x) s._p.brk = x end
    mc._p.hb, mc._p.thr, mc._p.brk = false, 1, 0.5    -- the game's handbrake release (Space up), throttle, reverse
    frame()
    check(mc._p.hb == true and mc._p.thr == 0 and mc._p.brk == 0, "K9: the host in seat 2 of a parked car: handbrake held, throttle / brake 0 every frame")
    venter(B, v)
    check(st.driver_key == B.key, "K9: Friend2 gets in at the free wheel")
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(mc._p.hb == false and mc._p.thr == 1, "K9: somebody drives: the hold is off")
    T = T + 0.1; run_delayed()
    vexit(B, v, "d")
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(mc._p.hb == true and mc._p.thr == 0, "K9: parked again: held again")
    down.G = true; frame(); down.G = false
    check(st.host_seat == "driver", "K9: the host's key: the wheel")
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(mc._p.hb == false and mc._p.thr == 1 and g_reads() > 0, "K9: the host drives: its keys are its own again")
    reads = {}
    tick(0.5)
    frame()
    check(g_reads() == 0, "K8: at the wheel: the key not read")
    v:ExitVehicle()
    host_pc._m.IsInputKeyDown = nil
    done(v)
end

print("K10. the wheel free, but the game's get-in cannot run for that player here (no player index): the next free seat, else 'could not'")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    local st = vst(v)
    check(st.host_idx == 4 and st.pax[2] == B.key and st.pax[3] == C.key, "K10: Friend drives, Friend2 2, Friend3 3, the host 4")
    vexit(A, v, "d")
    local io0 = ctx.index_of
    ctx.index_of = function(pc) if pc == B.pc then return nil end return io0(pc) end
    sent = {}
    seat_key(B, v)
    local r = last_sent("VSWR", B.pc)
    check(r and r.args[1] == "no" and at_seat(B.ch, v, 2) and st.driver_key == nil and v._entered_by ~= B.ch,
        "K10: Friend2 without a player index, the wheel free, the other seats taken: 'could not', it stays")
    vexit(C, v, "d", 3)
    T = T + 0.5
    seat_key(B, v)
    check(at_seat(B.ch, v, 3) and st.pax[3] == B.key and st.driver_key == nil, "K10: seat 3 free: Friend2 moves there, not to the wheel")
    check(seat_args(B)[1] == "passenger" and seat_args(B)[2] == "" and seat_args(B)[3] == "3",
        "K10: its VSEAT names no driver (nobody at the wheel; up to now the host's name, the host in seat 4)")
    ctx.index_of = io0
    T = T + 0.5
    seat_key(B, v)
    check(at_seat(B.ch, v, 1) and st.driver_key == B.key and at_seat(host_ch, v, 4), "K10: its player index back: the wheel; the host stays in 4")
    T = T + 0.1; run_delayed()
    v:ExitVehicle()
    vexit(B, v, "d")
    done(v)
end

-- ------------------------------------------------------------ K11-K15: the skeptic's findings (13.11)
print("K11. towing: a parked car the host sits in as a passenger is not held while another vehicle tows it")
do
    local v = fresh("Vehicle_SUV_C")
    -- the tower: 8 m behind, its tow box; the game's hitch as BP_VehicleMaster
    -- @197..1252 (the constraint a component of the towed car, its handbrake
    -- released a tick later), the detach @28529..28916
    local tw = new_vehicle("Vehicle_PickupTruck_C_2147499900", { X = v._p.__loc.X - 800, Y = 0, Z = 80 }, "Vehicle_PickupTruck_C")
    tw._m.AddTowingComp = function(self)
        self._p["TowingVehicle?"] = true
        local pcc = new_obj("PhysicsConstraintComponent", "NODE_AddPhysicsConstraintComponent-0", {}, {})
        pcc._owner = v
        self._p.PhysicsConstraintComp = pcc
        delayed[#delayed + 1] = function()
            local m = v._p.VehicleMovementComponent
            m:SetHandbrakeInput(false); m:SetThrottleInput(0.01)
        end
    end
    tw._m.RemoveTowingComp = function(self)
        self._p["TowingVehicle?"] = false
        self._p.PhysicsConstraintComp = nil
        local m = v._p.VehicleMovementComponent
        m:SetHandbrakeInput(true); m:SetThrottleInput(0)
    end
    local mc = v._p.VehicleMovementComponent
    mc._m.GetHandbrakeInput = function(s) return s._p.hb end
    mc._m.SetThrottleInput = function(s, x) s._p.thr = x end
    mc._m.SetBrakeInput = function(s, x) s._p.brk = x end
    host_pc._m.IsInputKeyDown = function() return false end
    local function frame() V.frame_tick() end
    local function vtow(c, on) local a = vstr(tw); a[5] = on and "1" or "0"; deliver("VTOW", a, c.pc) end
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    local st = vst(v)
    vexit(A, v, "d")
    tick(0.5)
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(st.host_seat == "passenger" and st.driver_key == nil and mc._p.hb == true and mc._p.thr == 0,
        "K11: Friend out, the host in seat 2: the car held parked (handbrake, throttle 0)")
    vtow(C, true)
    check(tw._p["TowingVehicle?"] == true and V._t.seatk.hold_va == nil,
        "K11: Friend3 hitches it to its pickup (VTOW): not held any more at once (before the game's release)")
    frame()
    run_delayed()     -- the game's release, a tick later
    frame()
    check(mc._p.hb == false and mc._p.thr == 0.01, "K11: the game's tow inputs stay (handbrake off, throttle 0.01): not dragged braked")
    tick(0.5)
    frame(); frame()
    check(V._t.seatk.hold_va == nil and mc._p.hb == false and mc._p.thr == 0.01, "K11: the tick: towed, still not held")
    V._t.seatk.hold_va = v._addr     -- (a driver's exit while towed sets it again: SEATK.wheel_free)
    tick(0.5)
    check(V._t.seatk.hold_va == nil, "K11: the tick lets a towed car go again")
    vtow(C, false)
    check(tw._p["TowingVehicle?"] == false and mc._p.hb == true, "K11: detached: the game's handbrake on")
    tick(0.5)
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(V._t.seatk.hold_va == v._addr and mc._p.hb == true and mc._p.thr == 0, "K11: no longer towed: held parked again")
    -- a constraint component left behind without the tow flag (a detach
    -- half-way, @28529 before @28605) is no tow
    local stale = new_obj("PhysicsConstraintComponent", "NODE_AddPhysicsConstraintComponent-0", {}, {})
    stale._owner = v
    tw._p.PhysicsConstraintComp = stale
    tick(0.5)
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(V._t.seatk.hold_va == v._addr and mc._p.hb == true, "K11: a leftover constraint without TowingVehicle?: still held")
    tw._p.PhysicsConstraintComp = nil
    -- a tow of another car leaves this hold alone
    local other = new_vehicle("Vehicle_Buggy_C_2147499901", { X = v._p.__loc.X + 3000, Y = 0, Z = 80 }, "Vehicle_Buggy_C")
    tw._m.AddTowingComp = function(self)
        self._p["TowingVehicle?"] = true
        local pcc = new_obj("PhysicsConstraintComponent", "NODE_AddPhysicsConstraintComponent-1", {}, {})
        pcc._owner = other
        self._p.PhysicsConstraintComp = pcc
    end
    vtow(C, true)
    tick(0.5)
    mc._p.hb, mc._p.thr = false, 1
    frame()
    check(V._t.seatk.hold_va == v._addr and mc._p.hb == true and mc._p.thr == 0, "K11: the pickup tows another car: this one still held")
    other._valid = false; tw._valid = false
    host_pc._m.IsInputKeyDown = nil
    v:ExitVehicle()
    done(v)
end

print("K12. the driver disconnects; the host's key before the tick: its record ends first, the host drives (handbrake off)")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(B, v); tick(1)
    local st = vst(v)
    local mc = v._p.VehicleMovementComponent
    check(st.driver_key == A.key and at_seat(host_ch, v, 2) and at_seat(B.ch, v, 3) and mc._p.hb == false,
        "K12: Friend drives, the host in seat 2, Friend2 in 3")
    A.pc._p.NetConnection = nil      -- Friend's connection gone, the tick has not ended its record yet
    A.ch._parent = nil
    local n0 = #toasts
    sent = {}
    seat_key("H", v)
    check(st.host_seat == "driver" and at_seat(host_ch, v, 1) and st.driver_key == nil and V._t.seats()[A.key] == nil,
        "K12: the host's key at once: at the wheel, Friend's record ended")
    check(mc._p.hb == false and timers[tkey(v, "CheckWater")] == true and timers[tkey(v._p.FuelComponent, "FuelSpend")] == true,
        "K12: the handbrake off, the driver's services on")
    check(toast_since(n0, "Место 1 из 4: вы за рулём.") and not toast_since(n0, "Руль свободен"), "K12: 'Seat 1 of 4', no 'wheel free' for the host")
    check(count_sent("VSWR", B.pc) == 0, "K12: no 'wheel free' for Friend2 either (the host took it at once)")
    tick(0.5)
    check(st.host_seat == "driver" and st.driver_key == nil and mc._p.hb == false and timers[tkey(v, "CheckWater")] == true,
        "K12: the tick after: still the host's car, the handbrake still off (up to now: on, the host's W did nothing)")
    check(at_seat(B.ch, v, 3) and st.pax[3] == B.key, "K12: Friend2 stays in seat 3")
    A.pc._p.NetConnection = A.conn
    v:ExitVehicle()
    vexit(B, v, "d", 3)
    done(v)
    -- a client's key in that half second: its get-in takes the wheel; the
    -- tick's late end of the old record leaves the new driver's car alone
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); tick(1)
    st = vst(v)
    mc = v._p.VehicleMovementComponent
    A.pc._p.NetConnection = nil
    A.ch._parent = nil
    sent = {}
    seat_key(B, v)
    T = T + 0.1; run_delayed()
    check(st.driver_key == B.key and at_seat(B.ch, v, 1) and mc._p.hb == false, "K12: Friend2's key before the tick: it drives")
    tick(0.5)
    check(st.driver_key == B.key and mc._p.hb == false and timers[tkey(v, "CheckWater")] == true and V._t.seats()[A.key] == nil,
        "K12: the tick ends Friend's record only: Friend2's car keeps running (handbrake off)")
    A.pc._p.NetConnection = A.conn
    vexit(B, v, "d")
    done(v)
end

print("K13. two presses for the free wheel together: the second stays where it sits ('X already took the wheel')")
do
    -- two clients
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); venter(C, v); tick(1)
    local st = vst(v)
    vexit(A, v, "d")
    sent = {}
    seat_key(C, v)
    seat_key(B, v)
    local r = last_sent("VSWR", B.pc)
    check(st.driver_key == C.key and at_seat(C.ch, v, 1) and at_seat(B.ch, v, 2) and st.pax[2] == B.key and st.pax[3] == nil,
        "K13: Friend3 (seat 3) took the wheel; Friend2's press right after: stays in seat 2 (up to now: moved to seat 3)")
    check(r and r.args[1] == "taken" and r.args[2] == "Friend3" and vseats_to(B) == 0, "K13: Friend2 told: VSWR taken|Friend3, no VSEAT")
    T = T + 1.1
    seat_key(B, v)
    check(at_seat(B.ch, v, 3) and st.pax[3] == B.key, "K13: its press a second later: the next free seat (3)")
    T = T + 0.1; run_delayed()
    vexit(C, v, "d"); vexit(B, v, "d", 3)
    done(v)
    -- the host and a client: the client first
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(B, v); tick(1)
    st = vst(v)
    vexit(A, v, "d")
    seat_key(B, v)
    local n0 = #toasts
    seat_key("H", v)
    check(st.driver_key == B.key and at_seat(host_ch, v, 2) and st.host_idx == 2 and toast_since(n0, "Руль уже занял Friend2.")
        and not toast_since(n0, "Место 3 из 4"), "K13: Friend2 took the wheel; the host's press right after: stays in seat 2, 'Friend2 already took the wheel'")
    T = T + 1.1
    seat_key("H", v)
    check(at_seat(host_ch, v, 3) and toast_since(n0, "Место 3 из 4: машину ведёт Friend2."), "K13: the host's press a second later: seat 3")
    T = T + 0.1; run_delayed()
    v:ExitVehicle(); vexit(B, v, "d")
    done(v)
    -- the host first, then the client
    v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    venter(B, v); tick(1)
    st = vst(v)
    vexit(A, v, "d")
    sent = {}
    seat_key("H", v)
    seat_key(B, v)
    r = last_sent("VSWR", B.pc)
    check(st.host_seat == "driver" and at_seat(B.ch, v, 3) and r and r.args[1] == "taken" and r.args[2] == "Host",
        "K13: the host took the wheel; Friend2's press right after: stays in seat 3, VSWR taken|Host")
    v:ExitVehicle()
    -- a newcomer takes the free wheel: the same (Friend2's last press 2 s ago)
    T = T + 2
    sent = {}
    venter(D, v)
    T = T + 0.5
    seat_key(B, v)
    r = last_sent("VSWR", B.pc)
    check(st.driver_key == D.key and at_seat(B.ch, v, 3) and r and r.args[1] == "taken" and r.args[2] == "Friend4",
        "K13: Friend4 gets in at the free wheel; Friend2's press right after: stays, VSWR taken|Friend4")
    T = T + 0.1; run_delayed()
    vexit(D, v, "d")
    -- the host's own get-in at the free wheel: the same
    T = T + 2
    sent = {}
    host_press(v); T = T + 0.1; run_delayed()
    seat_key(B, v)
    r = last_sent("VSWR", B.pc)
    check(st.host_seat == "driver" and at_seat(B.ch, v, 3) and r and r.args[1] == "taken" and r.args[2] == "Host",
        "K13: the host gets in at the free wheel; Friend2's press right after: stays, VSWR taken|Host")
    -- the car emptied after a 'wheel free': nobody waits any more
    v:ExitVehicle()
    vexit(B, v, "d", 3)
    T = T + 2
    venter(A, v)
    venter(B, v)
    sent = {}
    seat_key(B, v)
    check(st.driver_key == A.key and at_seat(B.ch, v, 3) and st.pax[3] == B.key and count_sent("VSWR", B.pc) == 0,
        "K13: emptied, then Friend at the wheel, Friend2 in 2: its press at once: seat 3 (nobody was waiting for the wheel)")
    T = T + 0.1; run_delayed()
    vexit(A, v, "d"); vexit(B, v, "d", 3)
    done(v)
    -- nobody waited for the wheel (a car taken from empty): a press right after moves at once
    v = fresh("Vehicle_SUV_C")
    venter(A, v)
    venter(B, v)
    sent = {}
    seat_key(B, v)
    st = vst(v)
    check(at_seat(B.ch, v, 3) and st.pax[3] == B.key and count_sent("VSWR", B.pc) == 0,
        "K13: Friend drove off an empty car; Friend2's press at once: seat 3 (no wait: nobody was told the wheel was free)")
    T = T + 0.1; run_delayed()
    vexit(A, v, "d"); vexit(B, v, "d", 3)
    done(v)
end

print("K14. vehicle_seat_key on one of the mod's own keys (chat_key = G, players_hud_key F8): the seat key is off, a warning")
do
    local warns = {}
    local w0 = log.warn
    log.warn = function(fmt, ...) warns[#warns + 1] = string.format(fmt, ...); return w0(fmt, ...) end
    local reads = {}
    host_pc._m.IsInputKeyDown = function(_, k) reads[#reads + 1] = k.KeyName:ToString(); return false end
    local function g_read()
        for _, n in ipairs(reads) do if n == "G" then return true end end
        return false
    end
    local function warned(pat)
        for _, w in ipairs(warns) do if w:find(pat, 1, true) then return true end end
        return false
    end
    cfg.set("chat_key", "g")
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed(); tick(1)
    host_press(v); T = T + 0.1; run_delayed(); tick(0.5)
    reads = {}
    V.frame_tick()
    check(at_seat(host_ch, v, 2) and not g_read() and V._t.seatk.key() == nil, "K14: chat_key = g: the seat key G is off (not read in the frame)")
    check(warned("vehicle_seat_key = G is also chat_key"), "K14: a warning in the log names the clash")
    local n0 = #toasts
    vexit(A, v, "d")
    check(toast_since(n0, "Руль свободен: чтобы вести, выйдите и сядьте снова."), "K14: the 'wheel free' notice says get out and in")
    cfg.set("chat_key", "Enter")
    tick(0.5)
    reads = {}
    V.frame_tick()
    check(g_read(), "K14: chat_key back to Enter: G is the seat key again")
    cfg.set("vehicle_seat_key", "F8")
    tick(0.5)
    check(V._t.seatk.key() == nil and warned("vehicle_seat_key = F8 is also players_hud_key"), "K14: vehicle_seat_key = F8 (players_hud_key's default): off too")
    cfg.set("vehicle_seat_key", "G")
    tick(0.5)
    check(V._t.seatk.key() ~= nil, "K14: G again: on")
    local src = io.open(SCRIPTS .. "/sdc_config.lua"):read("a")
    local line = src:match('"chat_key"[^\n]*')
    check(line and not line:find("Slash, G", 1, true), "K14: chat_key's description no longer suggests G")
    log.warn = w0
    host_pc._m.IsInputKeyDown = nil
    v:ExitVehicle()
    done(v)
end

-- ------------------------------------------------------------ C. the client side
print("C. client: its own seat 3, notices, old host, re-get-in, own exit, VOCC placement")
V.reset("test: client")
net_mode = "client"
S.role = "client"
S.client = { acked = true }
S.remote, S.remote_pcs = {}, {}
local me = A.ch
me._local = true
host_ch._local = false
host_pc._p.Player = nil
A.pc._p.Player = new_obj("LocalPlayer", "LP2", {}, {})
A.pc._p.NetConnection = nil
controllers = { A.pc }
ctx.reset()
local cv = new_vehicle("Vehicle_SUV_C_2147499001", { X = 5000, Y = 0, Z = 80 }, "Vehicle_SUV_C")
cv._p.Role = 1
for _, c in ipairs(ALL) do c._parent = nil; c._montage = nil; c._p["InVehicle?"] = false end
me._p.__loc = { X = 5050, Y = -250, Z = 100 }
V.tick()
deliver("VCAP", { "1" }, A.pc)
local function vseat(...) deliver("VSEAT", { ... }, A.pc) end
local function geo_fields(idx, n, m, side, x, z, tell, exit)
    return tostring(idx), tostring(n), tostring(m), side, tostring(x), "0", tostring(z or 0), "0", "car", exit or (side == "R" and "p" or "d"), tell
end
do
    sent = {}
    cv:Interact_GetInVehicle()
    local ve = last_sent("VENTER", "host")
    check(ve and ve.args[5] == "s2", "C: VENTER says it knows seats 3+ (s2)")
    local n0 = #toasts
    vseat("passenger", "Host", geo_fields(3, 3, 4, "L", -90, 0, "1"))
    check(at_seat(me, cv, 3) and V._t.local_seat().idx == 3, "C13: own character in seat 3 (the host's numbers)")
    check(toast_since(n0, "Место 3 из 4: машину ведёт Host."), "C13: the game's notice 'Seat 3 of 4'")
    check(cv._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "C13: a passenger's keys do not drive")
    n0 = #toasts
    vseat("passenger", "Host", geo_fields(3, 3, 4, "L", -90, 5, "0"))
    check(at_seat(me, cv, 3, 5) and #toasts == n0, "C13: the same seat with new numbers: moved, no notice")
    vseat("passenger", "Host", geo_fields(3, 3, 4, "L", -90, 0, "1"))
    check(#toasts == n0, "C13: the same seat again (tell 1): still no second notice")
    -- the game's get-in again while seated (R1): the seat stays
    sent = {}
    me._welded = false
    cv:Interact_GetInVehicle()
    check(V._t.local_seat().seat == "passenger" and V._t.local_seat().idx == 3 and at_seat(me, cv, 3) and me._welded == false,
        "C13: the game's get-in again: the seat stays (back in seat 3, unwelded)")
    check(last_sent("VENTER", "host") and last_sent("VENTER", "host").args[5] == "s2", "C13: and asks the host again")
    n0 = #toasts
    vseat("passenger", "Host", geo_fields(3, 3, 4, "L", -90, 0, "0"))
    check(#toasts == n0 and at_seat(me, cv, 3), "C13: the host's same answer: no notice")
    -- own exit from seat 3: at the rear door
    sent = {}
    me._parent = nil
    cv:ExitVehicle()
    local vx = last_sent("VEXIT", "host")
    check(vx and vx.args[8] == "3" and vx.args[7] == "passenger", "C14: VEXIT carries seat 3")
    check(d(me._p.__loc, { X = 5000 + 20 - 90, Y = -200, Z = 80 }) < 1, "C14: out at its rear door (not the front door the game used)")
    -- seat 2 exit: the game's door, as before
    cv:Interact_GetInVehicle()
    vseat("passenger", "Host", geo_fields(2, 2, 4, "R", 0, 0, "1"))
    check(at_seat(me, cv, 2), "C: seat 2 = the mirror")
    me._parent = nil
    cv:ExitVehicle()
    check(d(me._p.__loc, { X = 5020, Y = -200, Z = 80 }) < 1, "C: seat 2 out where the game put it (as before)")
    -- an older host: kind + name only
    cv:Interact_GetInVehicle()
    n0 = #toasts
    vseat("passenger", "Host")
    check(at_seat(me, cv, 2) and toast_since(n0, "Вы пассажир: машину ведёт Host.") and V._t.local_seat().idx == 2,
        "C: an older host: the mirror seat and the old notice")
    vseat("driver", "")
    check(at_seat(me, cv, 1) and toast_since(n0, "Теперь машину ведёте вы."), "C: promoted: at the wheel, the old notice")
    me._parent = nil
    cv:ExitVehicle()
    -- driver notices: alone (tell 0) nothing; with others in a 4-seat car "Seat 1 of 4"
    cv:Interact_GetInVehicle()
    n0 = #toasts
    vseat("driver", "", geo_fields(1, 1, 4, "L", 0, 0, "0"))
    check(#toasts == n0, "C: driver alone: no notice")
    me._parent = nil
    cv:ExitVehicle()
    cv:Interact_GetInVehicle()
    vseat("driver", "", geo_fields(1, 1, 4, "L", 0, 0, "1"))
    check(toast_since(n0, "Место 1 из 4: вы за рулём."), "C: driver with others in a 4-seat car: 'Seat 1 of 4'")
    me._parent = nil
    cv:ExitVehicle()
    cv:Interact_GetInVehicle()
    n0 = #toasts
    vseat("driver", "", geo_fields(1, 1, 2, "L", 0, 0, "1"))
    check(#toasts == n0, "C: a 2-seat car: no seat notice for the driver")
    me._parent = nil
    cv:ExitVehicle()
    -- refusals
    for _, case in ipairs({ { { "none", "full", "4" }, "В машине нет свободного места (всего мест: 4)." },
                            { { "none", "full", "2" }, "В машине нет свободного места." },
                            { { "none", "full" }, "В машине нет свободного места." } }) do
        cv:Interact_GetInVehicle()
        n0 = #toasts
        vseat(table.unpack(case[1]))
        check(me._parent == nil and toast_since(n0, case[2]) and (case[1][3] == "4" or not toast_since(n0, "всего мест")),
            "C: refused " .. table.concat(case[1], "|") .. ": " .. case[2])
    end
    check(V._t.local_seat() == nil, "C: no seat after a refusal")
end

print("C. client: the seat key (VSWITCH), the host's answers (VSWR / VSEAT), an older host, the frame read")
do
    local function sw_fields(idx, n, m, side, x, tell)
        local t = { geo_fields(idx, n, m, side, x, 0, tell) }
        t[#t + 1] = "sw"
        return table.unpack(t)
    end
    sent = {}
    cv:Interact_GetInVehicle()
    local ve = last_sent("VENTER", "host")
    check(ve and ve.args[5] == "s2" and ve.args[6] == "sw", "CK: VENTER says it has the seat key (sw)")
    vseat("passenger", "Host", sw_fields(2, 2, 4, "R", 0, "1"))
    check(V._t.local_seat().sw == true, "CK: the host's VSEAT with 'sw': the host takes the seat key")
    sent = {}
    V._t.seatk.on_key()
    local sw = last_sent("VSWITCH", "host")
    check(sw and #sw.args == 4 and sw.args[4] == "Vehicle_SUV_C" and sw.args[1] == "5000", "CK: a passenger's key: VSWITCH to the host (its vehicle)")
    check(at_seat(me, cv, 2), "CK: nothing moves before the host's answer")
    local n0 = #toasts
    vseat("passenger", "Host", sw_fields(4, 4, 4, "R", -90, "1"))
    check(at_seat(me, cv, 4) and V._t.local_seat().idx == 4 and toast_since(n0, "Место 4 из 4: машину ведёт Host."),
        "CK: the host moved it: own character in seat 4, 'Seat 4 of 4'")
    n0 = #toasts
    deliver("VSWR", { "full", "4" }, A.pc)
    check(toast_since(n0, "Пересесть некуда: все места заняты."), "CK: VSWR full: the game's notice")
    deliver("VSWR", { "no", "wheel" }, A.pc)
    check(toast_since(n0, "Не получилось пересесть."), "CK: VSWR no: the game's notice")
    deliver("VSWR", { "wheel" }, A.pc)
    check(toast_since(n0, "Руль свободен: нажмите G, чтобы пересесть."), "CK: VSWR wheel: 'The wheel is free: press G'")
    deliver("VSWR", { "taken", "Host" }, A.pc)
    check(toast_since(n0, "Руль уже занял Host.") and at_seat(me, cv, 4), "CK: VSWR taken|Host: 'Host already took the wheel', it stays")
    n0 = #toasts
    vseat("passenger", "", sw_fields(3, 3, 4, "L", -90, "1"))
    check(at_seat(me, cv, 3) and toast_since(n0, "Место 3 из 4: руль свободен.") and not toast_since(n0, "машину ведёт"),
        "CK: moved with nobody at the wheel (no name): 'Seat 3 of 4: nobody drives'")
    n0 = #toasts
    vseat("driver", "", sw_fields(1, 1, 4, "L", 0, "1"))
    check(at_seat(me, cv, 1) and toast_since(n0, "Место 1 из 4: вы за рулём.")
        and cv._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false,
        "CK: its key took it to the wheel: at the wheel, 'Seat 1 of 4', its own inputs drive")
    sent = {}
    n0 = #toasts
    V._t.seatk.on_key()
    deliver("VSWR", { "wheel" }, A.pc)
    check(last_sent("VSWITCH") == nil and #toasts == n0, "CK: at the wheel: the key sends nothing, a late 'wheel free' shows nothing")
    me._parent = nil
    cv:ExitVehicle()
    -- a 2-seat car: "You now drive"
    cv:Interact_GetInVehicle()
    vseat("passenger", "Host", sw_fields(2, 2, 2, "R", 0, "1"))
    n0 = #toasts
    vseat("driver", "", sw_fields(1, 1, 2, "L", 0, "0"))
    check(toast_since(n0, "Теперь машину ведёте вы."), "CK: to the wheel of a 2-seat car: 'You now drive'")
    me._parent = nil
    cv:ExitVehicle()
    -- an older host (no field 14): the key sends nothing there, a notice
    cv:Interact_GetInVehicle()
    vseat("passenger", "Host", geo_fields(2, 2, 4, "R", 0, 0, "1"))
    check(V._t.local_seat().sw == false, "CK: an older host's VSEAT (no field 14): no seat key there")
    sent = {}
    n0 = #toasts
    V._t.seatk.on_key()
    check(last_sent("VSWITCH") == nil and toast_since(n0, "Пересесть нельзя: у хоста старая версия мода."),
        "CK: the key with an older host: nothing sent, the game's notice")
    -- the frame loop: read only while a passenger, one press = one VSWITCH
    local down, reads = {}, 0
    A.pc._m.IsInputKeyDown = function(_, k)
        local name = k.KeyName:ToString()
        if name == "G" then reads = reads + 1 end
        return down[name] == true
    end
    vseat("passenger", "Host", sw_fields(2, 2, 4, "R", 0, "0"))
    tick(0.5)
    sent = {}
    V.frame_tick(); down.G = true; V.frame_tick(); V.frame_tick(); down.G = false; V.frame_tick()
    check(reads == 4 and count_sent("VSWITCH", "host") == 1, "CK: a passenger: the key read in the frame loop, a held press = one VSWITCH")
    vseat("driver", "", sw_fields(1, 1, 4, "L", 0, "0"))
    tick(0.5)
    reads = 0
    V.frame_tick()
    check(reads == 0, "CK: at the wheel: the key not read")
    A.pc._m.IsInputKeyDown = nil
    me._parent = nil
    cv:ExitVehicle()
    check(V._t.local_seat() == nil, "CK: out again")
end

print("C. VOCC: a rear seat placed when no attachment came, let go when free; stale / bad lists")
do
    local function vstate(f11, f12) deliver("VSTATE", { "*", "5000", "0", "80", "Vehicle_SUV_C", "0", "500.0", "80.0", "0", "1", "1", f11, f12 }, A.pc) end
    local function vocc(list) deliver("VOCC", { "*", "5000", "0", "80", "Vehicle_SUV_C", list }, A.pc) end
    local hid = tostring(host_ch._pid)
    for _, c in ipairs(ALL) do c._parent = nil; c._montage = nil end
    me._p.__loc = { X = 5050, Y = -300, Z = 100 }
    host_ch._p.Mesh._p.vis, host_ch._p.Mesh._p.cam = 2, 2
    vstate(hid, B.id)
    vocc(VS.occ_entry(2, B.id, VS.SEAT2) .. ";" .. VS.occ_entry(3, C.id, VS.geo("Vehicle_SUV_C", 3)))
    tick(0.5)
    check(C.ch._parent == nil, "C: not placed at once (the engine's attachment may still come)")
    tick(2)
    check(at_seat(host_ch, cv, 1) and at_seat(B.ch, cv, 2) and at_seat(C.ch, cv, 3), "C: the driver, seat 2 and seat 3 placed from VSTATE + VOCC")
    tick(0.5)
    check(C.ch._montage == montage and C.ch._p["InVehicle?"] == true, "C: seat 3 sits here (pose, InVehicle?)")
    check(host_ch._p.CapsuleComponent._p.cam == 0 and C.ch._p.Mesh._p.cam == 0, "S15: three seated on the client: their camera response off")
    -- the floor pose from VOCC
    local fl = VS.geo("Vehicle_SUV_C", 3)
    fl.pose = "floor"
    vstate(hid, B.id)
    vocc(VS.occ_entry(2, B.id, VS.SEAT2) .. ";" .. VS.occ_entry(3, C.id, fl))
    tick(0.5)
    check(C.ch._montage == floor_m, "C: a floor seat in VOCC: the floor pose here")
    -- the list empties
    vstate(hid, B.id)
    vocc("")
    tick(0.5)
    check(C.ch._parent == nil and at_seat(B.ch, cv, 2), "C: an empty list: seat 3 let go, seat 2 kept (field 12)")
    tick(0.5)
    check(C.ch._montage == nil and C.ch._p.Mesh._p.cam == 2, "C: standing again, camera response back")
    -- a stale list: the next VSTATE came without VOCC
    vstate(hid, B.id)
    vocc(VS.occ_entry(2, B.id, VS.SEAT2) .. ";" .. VS.occ_entry(3, C.id, VS.geo("Vehicle_SUV_C", 3)))
    tick(0.5)
    tick(2)
    check(at_seat(C.ch, cv, 3), "C: placed again")
    tick(1)
    vstate(hid, B.id)
    tick(0.5)
    check(C.ch._parent == nil and at_seat(B.ch, cv, 2), "C: a VSTATE without VOCC: the old list is stale, seat 3 let go")
    tick(0.5)
    check(at_seat(host_ch, cv, 1) and host_ch._p.CapsuleComponent._p.cam == 2 and B.ch._p.CapsuleComponent._p.cam == 2,
        "S15: the stale list does not count (the front row only): camera responses back")
    -- bad lists: no error, skipped
    local e0 = #errs
    vocc("3:x:L;99:1:Q:0:0:0:0:car;garbage")
    deliver("VOCC", { "*", "5000" }, A.pc)
    deliver("VOCC", { "5000", "0", "80" }, A.pc)
    tick(0.5)
    check(#errs == e0, "C: bad VOCC messages skipped without an error")
    -- the driver and seat 3 only (seat 2 empty): two seated, one behind the driver
    vstate(hid, "")
    vocc(VS.occ_entry(3, C.id, VS.geo("Vehicle_SUV_C", 3)))
    tick(0.5)
    tick(2)
    tick(0.5)
    check(at_seat(host_ch, cv, 1) and at_seat(C.ch, cv, 3) and B.ch._parent == nil, "C: the driver and seat 3 placed (seat 2 empty)")
    check(host_ch._p.CapsuleComponent._p.cam == 0 and C.ch._p.CapsuleComponent._p.cam == 0 and C.ch._p.Mesh._p.cam == 0,
        "S15: two seated, one in seat 3 (VOCC): their camera response off")
    vstate(hid, "")
    vocc("")
    tick(0.5)
    tick(0.5)
    check(C.ch._parent == nil and host_ch._p.CapsuleComponent._p.cam == 2, "C: seat 3 empty again: the driver's camera response back")
    -- this player in seat 3 behind the driver (its own seat; no VOCC)
    cv:Interact_GetInVehicle()
    T = T + 0.1
    run_delayed()
    vseat("passenger", "Host", geo_fields(3, 3, 4, "L", -90, 0, "0"))
    vstate(hid, "")
    tick(0.5)
    tick(2)
    tick(0.5)
    check(at_seat(me, cv, 3) and at_seat(host_ch, cv, 1) and host_ch._p.CapsuleComponent._p.cam == 0 and host_ch._p.Mesh._p.cam == 0,
        "S15: this player in seat 3 behind the driver: the driver's camera response off")
    check(me._p.CapsuleComponent._p.cam == 2, "S15: its own character untouched")
    me._parent = nil
    cv:ExitVehicle()
    vstate("", "")
    tick(1)
    check(host_ch._p.CapsuleComponent._p.cam == 2, "S15: nobody seated: the driver's camera response back")
end

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
