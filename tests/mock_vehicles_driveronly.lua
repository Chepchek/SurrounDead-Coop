-- Driver-only controls (sdc_vehicles SEATK.pass_here / pass_block / flip_hold):
-- a passenger's lights key / radial-menu light is switched back on its own
-- machine (the host's copy, or a client's), its horn is not relayed, its flip
-- key meets the game's own "Cannot flip vehicle" (the vehicle's Flipped held
-- while it sits there); the host refuses VLIGHT / VHORN / VFLIP from a client
-- that is not the driver. The driver keeps all of it; the radio is not
-- touched. Host passenger in a client-driven car (seat 2, and seat 3 behind
-- a client in seat 2: H4), client passengers in seats 2 and 3, the hand-over
-- to the wheel, the client side (seat 3 of the host's car: C; seat 2 of a car
-- another client drives: C2), the "driver only:" log lines (SEATK.not_driver
-- on the host, the passenger's own presses) and none for the driver.
-- A wreck (0 health: the game's TurnOnOffLights switches on only above 0):
-- a passenger's radial light leaves the lights on (H5, C3), nothing is
-- switched on that was off. A passenger's horn is muted on its machine (no
-- sound, no AI noise: PlaySoundAtLocation / ReportNoiseEvent pre hooks); the
-- driver's, a relayed one, other sounds and other cars are not.
-- Harness copied from mock_vehicles_seats.lua (2026-11-13); the lights / horn
-- / flip mocks fire their hooks as the game's functions do.
-- usage: lua mock_vehicles_driveronly.lua <scripts dir>
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
-- the log lines (the in-game check reads them: "driver only: ...")
local infos = {}
local info0 = log.info
log.info = function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    infos[#infos + 1] = ok and s or tostring(fmt)
    return info0(fmt, ...)
end
local function info_count(i0, pat)
    local n = 0
    for i = i0 + 1, #infos do if infos[i]:find(pat, 1, true) then n = n + 1 end end
    return n
end
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
-- key - the host's press runs SEATK.on_key, a client's is its VSWITCH; the
-- key itself: mock_vehicles_seats W / K)
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
-- the natives the game's Horn calls, through their (pre) hooks: true = still audible
local SND_FN = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local AI_FN = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent"
local horn_cue = new_obj("SoundCue", "Cue_Horn", {}, {})
local crash_cue = new_obj("SoundCue", "Cue_CarCrash", {}, {})
local hearing = new_obj("AISense_Hearing", "Default__AISense_Hearing", {}, {})
local snd_ro = false   -- true: the volume parameter ignores :set (UE4SS not taking it)
local last_noise = {}  -- the last ReportNoiseEvent's Loudness / MaxRange as the engine got them
local function play_sound(wco, cue)
    local vol = param(1.0)
    if snd_ro then vol.set = function() end end
    local h = hooks[SND_FN]
    if h and h.pre then
        h.pre(param(gps), param(wco), param(cue), param(wco:K2_GetActorLocation()), param({}), vol, param(1.0), param(0.0), param(nil))
    end
    return vol:get() > 0
end
local function report_noise(wco, inst, range)
    local loud, mr = param(1.0), param(range)
    local h = hooks[AI_FN]
    if h and h.pre then
        h.pre(param(hearing), param(wco), param(wco:K2_GetActorLocation()), loud, param(inst), mr, param(FName("Noise")))
    end
    last_noise = { loud = loud:get(), range = mr:get() }
    -- (MaxRange 0 = no limit)
    return loud:get() > 0 and (mr:get() == 0 or mr:get() > 100)
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
    -- BP_VehicleMaster TurnOnOffLights: off always; on only while CurrentHealth > 0 (@344..418)
    v._m.TurnOnOffLights = function(self)
        if self._p["LightsOn?"] then
            self._p["LightsOn?"] = false
        elseif (hc._p.CurrentHealth or 0) > 0 then
            self._p["LightsOn?"] = true
        end
        fire_post("TurnOnOffLights", param(self))
    end
    -- BP_VehicleMaster Horn: Cue_Horn at the vehicle (@90) and an AI noise
    -- (@191, Instigator = the vehicle, 8500), each native's pre hook first;
    -- _heard / _noise count what was left audible.
    v._m.Horn = function(self)
        self._honks = (self._honks or 0) + 1
        if play_sound(self, horn_cue) then self._heard = (self._heard or 0) + 1 end
        if report_noise(self, self, 8500) then self._noise = (self._noise or 0) + 1 end
        fire_post("Horn", param(self))
    end
    -- BP_VehicleMaster @25405: Flipped (the 1 s guard after a flip) -> "Cannot flip vehicle"
    v._m.Event_FlipVehicle = function(self)
        if self._p.Flipped == true then
            self._flip_refused = (self._flip_refused or 0) + 1
        else
            self._flips = (self._flips or 0) + 1
            self._p.Flipped = true
        end
        fire_post("Event_FlipVehicle", param(self))
    end
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
    if not old then a[5], a[6] = "s2", "sw" end
    deliver("VENTER", a, c.pc)
end
local function seat_key(who, v)
    if who == "H" then V._t.seatk.on_key() return end
    deliver("VSWITCH", vstr(v), who.pc)
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


-- ------------------------------------------------------------ helpers
local K = V._t.seatk
local NOTE = "Фарами и сигналом управляет только водитель."
local function with(a, ...) for _, x in ipairs({ ... }) do a[#a + 1] = x end; return a end

-- ------------------------------------------------------------ host setup
print("setup")
ctx.tick(S.remote_pcs)
check(ctx.active, "ctx redirection active")
V.tick()
check(hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:TurnOnOffLights"] ~= nil
    and hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:Horn"] ~= nil
    and hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:Event_FlipVehicle"] ~= nil,
    "lights / horn / flip hooks registered")
check(type(K.pass_here) == "function" and type(K.pass_block) == "function" and type(K.flip_hold) == "function",
    "SEATK.pass_here / pass_block / flip_hold exist")

-- ------------------------------------------------------------ H1. the host drives
print("H1. the host drives, Friend in seat 2, Friend2 in seat 3")
do
    local v = fresh("Vehicle_SUV_C")
    host_press(v); T = T + 0.1; run_delayed(); tick(1)
    local st = vst(v)
    check(st.host_seat == "driver", "H1: the host at the wheel")
    venter(A, v); venter(B, v)
    check(V.seat_idx(A.key) == 2 and V.seat_idx(B.key) == 3, "H1: Friend seat 2, Friend2 seat 3")
    tick(1)
    check(v._p.Flipped ~= true, "H1: the host drives: Flipped not held")
    check(not K.pass_here(v), "H1: the host is not a passenger here")
    local n0, i1 = #toasts, #infos
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == true and not toast_since(n0, NOTE), "H1: the driver's lights key works, no notice")
    check(st.dirty == true, "H1: the change goes to the clients (VSTATE)")
    sent = {}
    check(hooks[SND_FN] == nil and hooks[AI_FN] == nil, "H1: nobody sat as a passenger yet: the horn's natives not hooked")
    v:Horn()
    check(last_sent("VHORN", A.pc) ~= nil and last_sent("VHORN", B.pc) ~= nil, "H1: the driver's horn reaches the passengers")
    check(v._heard == 1 and v._noise == 1, "H1: the driver's horn: heard, an AI noise")
    v:Event_FlipVehicle()
    check(v._flips == 1, "H1: the driver's flip works")
    check(info_count(i1, "driver only:") == 0, "H1: the driver's lights / horn / flip: no driver-only line")
    v._p.Flipped = false    -- (the game's 1 s delay)
    -- the passengers' messages (an older or a changed client): refused
    deliver("VLIGHT", with(vstr(v), "0"), A.pc)
    check(v._p["LightsOn?"] == true, "H1: VLIGHT from seat 2: refused")
    deliver("VLIGHT", with(vstr(v), "0"), B.pc)
    check(v._p["LightsOn?"] == true, "H1: VLIGHT from seat 3: refused")
    local h = v._honks
    sent = {}
    deliver("VHORN", vstr(v), A.pc)
    deliver("VHORN", vstr(v), B.pc)
    check(v._honks == h and count_sent("VHORN") == 0, "H1: VHORN from seats 2 and 3: refused (no horn, nothing passed on)")
    deliver("VFLIP", vstr(v), A.pc)
    check(v._flips == 1, "H1: VFLIP from seat 2: refused")
    v:ExitVehicle()
    vexit(A, v, "p"); vexit(B, v, "d")
    done(v)
end

-- ------------------------------------------------------------ H2. the host as a passenger
print("H2. Friend drives, the host in seat 2, Friend2 in seat 3")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    host_press(v); T = T + 0.1; run_delayed()
    venter(B, v)
    local st = vst(v)
    check(st.driver_key == A.key and st.host_seat == "passenger" and st.host_idx == 2 and V.seat_idx(B.key) == 3,
        "H2: Friend drives, the host seat 2, Friend2 seat 3")
    tick(1)
    check(K.pass_here(v) == true, "H2: the host is a passenger here")
    check(v._p.Flipped == true, "H2: Flipped held on the host's copy while the host sits as a passenger")
    -- the host's lights key / radial-menu light (both call TurnOnOffLights)
    st.dirty = false
    local n0 = #toasts
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false, "H2: the host passenger's lights: switched back at once")
    check(toast_since(n0, NOTE), "H2: the notice: only the driver")
    check(st.dirty ~= true, "H2: nothing marked to send")
    sent = {}
    tick(0.5)
    local s2 = last_sent("VSTATE", A.pc)
    check(s2 == nil or s2.args[8] == "0", "H2: the clients still see the lights off")
    local h0 = v._honks or 0
    sent = {}
    n0 = #toasts
    check(hooks[SND_FN] ~= nil and hooks[AI_FN] ~= nil, "H2: the host sat as a passenger: the horn's natives hooked")
    local i2 = #infos
    v:Horn()
    check(count_sent("VHORN") == 0, "H2: the host passenger's horn: not passed to the clients")
    check(not toast_since(n0, NOTE), "H2: no second notice within 5 s")
    check((v._heard or 0) == 0 and (v._noise or 0) == 0, "H2: the host passenger's horn: muted, no AI noise (no zombie comes)")
    check(last_noise.loud == 0 and last_noise.range == 1, "H2: its AI noise: Loudness 0 and MaxRange 1 cm (not 0 = no limit)")
    check(info_count(i2, "honked in " .. v._short .. ": not passed on; muted here: sound yes, AI noise yes") == 1,
        "H2: logged: muted here")
    -- other sounds / noises at that vehicle, another vehicle's horn: untouched
    local v2 = new_vehicle("Vehicle_SUV_C_2147491999", { X = 900000, Y = 0, Z = 80 }, "Vehicle_SUV_C")
    check(play_sound(v, crash_cue) and play_sound(v2, horn_cue), "H2: another sound of the car, another car's horn: heard")
    check(report_noise(v, A.ch, 3500) and report_noise(v2, v2, 8500), "H2: the car's driving noise, another car's horn: AI noise kept")
    v2._valid = false
    T = T + 6
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false and toast_since(n0, NOTE), "H2: 6 s later: switched back, the notice again")
    v:Event_FlipVehicle()
    check((v._flips or 0) == 0 and v._flip_refused == 1, "H2: the host passenger's flip key: the game's refusal")
    -- the driver (Friend) through the host
    deliver("VLIGHT", with(vstr(v), "1"), A.pc)
    check(v._p["LightsOn?"] == true, "H2: the driver's VLIGHT: lights on on the host's copy")
    sent = {}
    deliver("VHORN", vstr(v), A.pc)
    check(v._honks == h0 + 2 and last_sent("VHORN", B.pc) ~= nil and last_sent("VHORN", A.pc) == nil,
        "H2: the driver's VHORN: played, passed to the others")
    check(v._heard == 1 and v._noise == 1, "H2: the driver's VHORN on the host passenger's machine: heard, an AI noise")
    deliver("VFLIP", vstr(v), A.pc)
    check(v._flips == 1, "H2: the driver's VFLIP runs (the hold let go for it)")
    v._p.Flipped = false    -- (the game's 1 s delay)
    tick(0.5)
    check(v._p.Flipped == true, "H2: held again for the host passenger")
    -- Friend2 (seat 3)
    deliver("VLIGHT", with(vstr(v), "0"), B.pc)
    check(v._p["LightsOn?"] == true, "H2: VLIGHT from seat 3: refused")
    local hb = v._honks
    sent = {}
    deliver("VHORN", vstr(v), B.pc)
    check(v._honks == hb and count_sent("VHORN") == 0, "H2: VHORN from seat 3: refused")
    v._p.Flipped = false
    deliver("VFLIP", vstr(v), B.pc)
    check(v._flips == 1, "H2: VFLIP from seat 3: refused")
    -- the driver leaves: the host stays in seat 2 - still a passenger of the
    -- parked car (driver only) - until its seat key takes the wheel
    vexit(A, v, "d")
    T = T + 0.1; run_delayed()
    tick(0.5)
    check(st.host_seat == "passenger" and K.pass_here(v) and v._p.Flipped == true, "H2: the driver out: the host still a passenger (held)")
    T = T + 6
    local lights_p = v._p["LightsOn?"]
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == lights_p, "H2: the parked car: the host passenger's lights still switched back")
    seat_key("H", v)
    check(st.host_seat == "driver" and not K.pass_here(v), "H2: the host's seat key: the host at the wheel")
    v._p.Flipped = true
    tick(0.5)
    check(v._p.Flipped == false, "H2: the host drives: the hold let go")
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false, "H2: the new driver's lights key works")
    v:Horn()
    check(v._heard == 2 and v._noise == 2, "H2: the new driver's horn: heard, an AI noise")
    v:Event_FlipVehicle()
    check(v._flips == 2, "H2: the new driver's flip works")
    v._p.Flipped = false
    v:ExitVehicle()
    vexit(B, v, "d")
    done(v)
end

-- ------------------------------------------------------------ H4. the host in a rear seat
print("H4. Friend drives, Friend2 in seat 2, the host in seat 3 (rear)")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    venter(B, v); T = T + 0.1; run_delayed()
    host_press(v); T = T + 0.1; run_delayed()
    local st = vst(v)
    check(st.driver_key == A.key and V.seat_idx(B.key) == 2 and st.host_seat == "passenger" and st.host_idx == 3,
        "H4: Friend drives, Friend2 seat 2, the host seat 3")
    tick(1)
    check(K.pass_here(v) == true and v._p.Flipped == true, "H4: the host in the rear seat is a passenger here: Flipped held")
    T = T + 6
    st.dirty = false
    local n0, i0 = #toasts, #infos
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false and st.dirty ~= true and toast_since(n0, NOTE),
        "H4: the rear-seat host's lights: switched back, nothing to send, the notice")
    check(info_count(i0, "driver only: this player (a passenger) switched the lights") == 1, "H4: logged (switched back)")
    sent = {}
    v:Horn()
    check(count_sent("VHORN") == 0, "H4: the rear-seat host's horn: not passed on")
    check((v._heard or 0) == 0 and (v._noise or 0) == 0, "H4: the rear-seat host's horn: muted, no AI noise")
    -- (the game not taking the new volume: the log says so)
    snd_ro = true
    i0 = #infos
    v:Horn()
    snd_ro = false
    check(v._heard == 1 and info_count(i0, "muted here: sound NO, AI noise yes") == 1, "H4: a volume that does not take: logged as NO")
    i0 = #infos
    v:Event_FlipVehicle()
    check((v._flips or 0) == 0 and v._flip_refused == 1, "H4: the rear-seat host's flip key: the game's refusal")
    check(info_count(i0, "driver only: this player (a passenger) pressed the flip key") == 1, "H4: the flip key logged")
    -- the front passenger (Friend2, a client; an older one sends its horn): refused, logged once per kind in 5 s
    i0 = #infos
    deliver("VLIGHT", with(vstr(v), "1"), B.pc)
    deliver("VLIGHT", with(vstr(v), "1"), B.pc)
    sent = {}
    deliver("VHORN", vstr(v), B.pc)
    v._p.Flipped = false
    deliver("VFLIP", vstr(v), B.pc)
    check(v._p["LightsOn?"] == false and count_sent("VHORN") == 0 and (v._flips or 0) == 0,
        "H4: VLIGHT / VHORN / VFLIP from seat 2: refused")
    check(info_count(i0, "driver only: VLIGHT from Friend2 refused: a passenger, seat 2") == 1,
        "H4: the VLIGHT refusal logged once in 5 s")
    check(info_count(i0, "driver only: VHORN from Friend2 refused: a passenger, seat 2") == 1
        and info_count(i0, "driver only: VFLIP from Friend2 refused") == 1, "H4: the VHORN / VFLIP refusals logged")
    tick(0.5)
    -- the driver: not refused, no refusal logged
    i0 = #infos
    deliver("VLIGHT", with(vstr(v), "1"), A.pc)
    sent = {}
    deliver("VHORN", vstr(v), A.pc)
    check(v._p["LightsOn?"] == true and last_sent("VHORN", B.pc) ~= nil, "H4: the driver's VLIGHT / VHORN work")
    check(info_count(i0, "refused") == 0, "H4: nothing logged as refused for the driver")
    -- the driver leaves: nobody moves; Friend2 (seat 2) takes the wheel with
    -- its key, the host stays in seat 3
    vexit(A, v, "d")
    deliver("VLIGHT", with(vstr(v), "0"), B.pc)
    check(v._p["LightsOn?"] == true and st.driver_key == nil, "H4: the parked car: Friend2 (still a passenger) refused")
    seat_key(B, v)
    T = T + 0.1; run_delayed()
    tick(0.5)
    check(st.driver_key == B.key and st.host_seat == "passenger" and K.pass_here(v) and v._p.Flipped == true,
        "H4: Friend2 drives, the host still a passenger in seat 3 (held)")
    deliver("VLIGHT", with(vstr(v), "0"), B.pc)
    check(v._p["LightsOn?"] == false, "H4: the new driver's VLIGHT counts")
    T = T + 6
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false, "H4: the host passenger's lights still switched back")
    -- the host gets out of its seat
    host_ch._parent = nil
    tick(0.5)
    check(v._p.Flipped == false and not K.pass_here(v), "H4: the host out: the hold let go, not a passenger")
    local hd = v._heard or 0
    v:Horn()
    check(v._heard == hd + 1, "H4: the host out: that car's horn not muted any more")
    vexit(B, v, "d")
    done(v)
end

-- ------------------------------------------------------------ H5. a wreck
print("H5. a wreck (0 health, engine off, lights on): Friend drives, the host in seat 2")
do
    local v = fresh("Vehicle_SUV_C")
    local hc = v._p.VehicleHealthComponent
    venter(A, v); T = T + 0.1; run_delayed()
    host_press(v); T = T + 0.1; run_delayed()
    local st = vst(v)
    check(st.driver_key == A.key and st.host_idx == 2, "H5: Friend drives, the host seat 2")
    -- the driver's lights on
    deliver("VLIGHT", with(vstr(v), "1"), A.pc)
    tick(0.5)
    -- (a healthy car: the game's own switch undoes the press, whatever the mod last saw - here a change it did not see)
    v._p["LightsOn?"] = false
    T = T + 6
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false, "H5: a healthy car: the game's switch undoes the press, nothing forced on")
    v._p["LightsOn?"] = true
    -- then wrecked: the game stops the engine and keeps the lights (@27198)
    hc._p.CurrentHealth = 0
    v._p["EngineOn?"] = false
    tick(0.5)
    check(v._p["LightsOn?"] == true and K.pass_here(v), "H5: a wreck with its lights on, the host a passenger")
    -- the host's radial-menu light (no engine check; the lights key needs the engine)
    T = T + 6
    st.dirty = false
    local n0, i0 = #toasts, #infos
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == true, "H5: the host passenger's radial light in a wreck: the lights stay on")
    check(hc._p.CurrentHealth == 0, "H5: the wreck's health back at 0")
    check(toast_since(n0, NOTE) and info_count(i0, "switched the lights in " .. v._short .. ": switched back (a wreck, health 0") == 1
        and info_count(i0, "STILL OFF") == 0, "H5: the notice; logged (a wreck, switched back)")
    sent = {}
    tick(0.5); tick(3)
    local s = last_sent("VSTATE", A.pc)
    check(s == nil or s.args[8] == "1", "H5: the driver still gets the lights on")
    -- again, a tick later
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == true and hc._p.CurrentHealth == 0, "H5: and again: on, health 0")
    -- the driver switches them off (the game can at 0); the passenger presses right after (no tick between)
    deliver("VLIGHT", with(vstr(v), "0"), A.pc)
    check(v._p["LightsOn?"] == false, "H5: the driver's VLIGHT off in a wreck works")
    i0 = #infos
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false and hc._p.CurrentHealth == 0, "H5: the passenger's press right after: the lights stay off, not switched on")
    check(info_count(i0, "a wreck") == 0, "H5: nothing switched on for the wreck")
    tick(0.5)
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false, "H5: a tick later too")
    -- the host at the wheel of the wreck (its seat key): the game's own rule, nothing switched on by the mod
    vexit(A, v, "d")
    seat_key("H", v)
    T = T + 0.1; run_delayed()
    tick(0.5)
    check(st.host_seat == "driver" and not K.pass_here(v), "H5: the host at the wheel")
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == false and hc._p.CurrentHealth == 0, "H5: the driver in a wreck: lights not on (the game's rule), health 0")
    hc._p.CurrentHealth = 50
    v:TurnOnOffLights()
    check(v._p["LightsOn?"] == true, "H5: repaired: the driver's lights on")
    v:ExitVehicle()
    done(v)
end

-- ------------------------------------------------------------ H3. a reset while held
print("H3. a world / role change while the host sits as a passenger")
do
    local v = fresh("Vehicle_SUV_C")
    venter(A, v); T = T + 0.1; run_delayed()
    host_press(v); T = T + 0.1; run_delayed()
    tick(0.5)
    check(v._p.Flipped == true, "H3: held")
    V.reset("test: world change")
    check(v._p.Flipped == false, "H3: let go by the reset")
end

-- ------------------------------------------------------------ C. the client side
print("C. client: a passenger in seat 3 of the host's car, then at the wheel")
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
local function geo_fields(idx, n, m, side, x, z, tell)
    return tostring(idx), tostring(n), tostring(m), side, tostring(x), "0", tostring(z or 0), "0", "car", side == "R" and "p" or "d", tell
end
do
    sent = {}
    cv:Interact_GetInVehicle()
    vseat("passenger", "Host", geo_fields(3, 3, 4, "L", -90, 0, "1"))
    T = T + 0.1; run_delayed()
    check(V._t.local_seat().seat == "passenger" and V._t.local_seat().idx == 3, "C: this player in seat 3")
    tick(0.5)
    check(K.pass_here(cv) == true and cv._p.Flipped == true, "C: a passenger here: Flipped held on this machine's copy")
    sent = {}
    T = T + 6
    local n0 = #toasts
    cv:TurnOnOffLights()
    check(cv._p["LightsOn?"] == false and last_sent("VLIGHT") == nil, "C: the passenger's lights key: switched back, nothing sent")
    check(toast_since(n0, NOTE), "C: the notice")
    cv:Horn()
    check(last_sent("VHORN") == nil, "C: the passenger's horn: not sent to the host")
    check((cv._heard or 0) == 0 and (cv._noise or 0) == 0, "C: the passenger's horn: muted here")
    cv:Event_FlipVehicle()
    check((cv._flips or 0) == 0 and cv._flip_refused == 1 and last_sent("VFLIP") == nil,
        "C: the passenger's flip key: the game's refusal, nothing sent")
    deliver("VSTATE", { "5000", "0", "80", cv._cls, "0", "300.0", "80.0", "1", "1", "1", "", "" }, A.pc)
    check(cv._p["LightsOn?"] == true, "C: the driver's lights (VSTATE) still shown here")
    -- at the wheel: the driver's keys
    vseat("driver", "")
    tick(0.5)
    check(not K.pass_here(cv) and cv._p.Flipped == false, "C: at the wheel: the hold let go")
    sent = {}
    local ic = #infos
    cv:TurnOnOffLights()
    local vl = last_sent("VLIGHT", "host")
    check(cv._p["LightsOn?"] == false and vl ~= nil and vl.args[5] == "0", "C: the driver's lights key: switched here and sent")
    cv:Horn()
    check(last_sent("VHORN", "host") ~= nil, "C: the driver's horn sent to the host")
    check(cv._heard == 1 and cv._noise == 1, "C: the driver's horn: heard here")
    cv:Event_FlipVehicle()
    check(cv._flips == 1 and last_sent("VFLIP", "host") ~= nil, "C: the driver's flip sent to the host")
    check(info_count(ic, "driver only:") == 0, "C: the driver's lights / horn / flip: no driver-only line")
    cv._p.Flipped = false
    -- a passenger again, then out
    vseat("passenger", "Host", geo_fields(2, 2, 4, "R", 0, 0, "1"))
    tick(0.5)
    check(cv._p.Flipped == true, "C: a passenger again: held")
    me._parent = nil
    cv:ExitVehicle()
    tick(0.5)
    check(V._t.local_seat() == nil and cv._p.Flipped == false, "C: out of the car: let go")
end

print("C2. client: a passenger in seat 2 (front) of a car another client drives")
do
    sent = {}
    cv:Interact_GetInVehicle()
    vseat("passenger", "Friend2", geo_fields(2, 2, 4, "R", 0, 0, "1"))
    T = T + 0.1; run_delayed()
    check(V._t.local_seat().seat == "passenger" and V._t.local_seat().idx == 2, "C2: this player in seat 2")
    tick(0.5)
    check(K.pass_here(cv) == true and cv._p.Flipped == true, "C2: a front passenger: Flipped held on this machine's copy")
    local l0, fr, fl = cv._p["LightsOn?"], cv._flip_refused or 0, cv._flips or 0
    T = T + 6
    local n0, i0 = #toasts, #infos
    sent = {}
    cv:TurnOnOffLights()
    check(cv._p["LightsOn?"] == l0 and last_sent("VLIGHT") == nil and toast_since(n0, NOTE),
        "C2: the front passenger's lights: switched back, nothing sent, the notice")
    local hd = cv._heard or 0
    cv:Horn()
    check(last_sent("VHORN") == nil, "C2: the front passenger's horn: not sent to the host")
    check(cv._heard == hd, "C2: the front passenger's horn: muted here")
    -- the driver's horn from the host (VHORN -> the game's Horn here): heard
    deliver("VHORN", { "5000", "0", "80", cv._cls }, A.pc)
    check(cv._heard == hd + 1, "C2: the driver's horn (VHORN) heard by the passenger")
    cv:Event_FlipVehicle()
    check(cv._flip_refused == fr + 1 and (cv._flips or 0) == fl and last_sent("VFLIP") == nil,
        "C2: the front passenger's flip key: the game's refusal, nothing sent")
    check(info_count(i0, "driver only: this player (a passenger) switched the lights") == 1
        and info_count(i0, "driver only: this player (a passenger) honked") == 1
        and info_count(i0, "driver only: this player (a passenger) pressed the flip key") == 1, "C2: all three logged")
    -- the radial menu's light runs the same TurnOnOffLights: the same answer, no second notice within 5 s
    n0 = #toasts
    cv:TurnOnOffLights()
    check(cv._p["LightsOn?"] == l0 and not toast_since(n0, NOTE), "C2: again within 5 s: switched back, no second notice")
    -- the driver's state from the host still shows here
    deliver("VSTATE", { "5000", "0", "80", cv._cls, "0", "300.0", "80.0", l0 and "0" or "1", "1", "1", "", "" }, A.pc)
    check(cv._p["LightsOn?"] == not l0, "C2: the driver's lights (VSTATE) shown here")
    me._parent = nil
    cv:ExitVehicle()
    tick(0.5)
    check(V._t.local_seat() == nil and cv._p.Flipped == false, "C2: out: let go")
end

print("C3. client: a passenger in a wreck (0 health) whose lights are on at the host")
do
    local hc = cv._p.VehicleHealthComponent
    deliver("VSTATE", { "5000", "0", "80", cv._cls, "0", "300.0", "80.0", "0", "1", "1", "", "" }, A.pc)
    check(cv._p["LightsOn?"] == false, "C3: lights off here")
    -- the host's state: wrecked with its lights on (this copy's game function cannot switch them on at 0)
    local i0 = #infos
    deliver("VSTATE", { "5000", "0", "80", cv._cls, "0", "300.0", "0.0", "1", "0", "1", "", "" }, A.pc)
    check(cv._p["LightsOn?"] == true and hc._p.CurrentHealth == 0, "C3: the host's lights shown on here, health 0")
    check(info_count(i0, "the host's lights are on: switched back (a wreck, health 0") == 1, "C3: logged (a wreck)")
    sent = {}
    cv:Interact_GetInVehicle()
    vseat("passenger", "Friend2", geo_fields(2, 2, 4, "R", 0, 0, "1"))
    T = T + 0.1; run_delayed()
    tick(0.5)
    check(K.pass_here(cv) == true, "C3: a passenger here")
    T = T + 6
    local n0 = #toasts
    cv:TurnOnOffLights()
    check(cv._p["LightsOn?"] == true and hc._p.CurrentHealth == 0 and last_sent("VLIGHT") == nil and toast_since(n0, NOTE),
        "C3: the passenger's radial light in the wreck: the lights stay on, health 0, nothing sent, the notice")
    -- the host switches them off (the driver did): shown off; the passenger's press does not switch them on
    deliver("VSTATE", { "5000", "0", "80", cv._cls, "0", "300.0", "0.0", "0", "0", "1", "", "" }, A.pc)
    check(cv._p["LightsOn?"] == false, "C3: the host's lights off: shown off")
    cv:TurnOnOffLights()
    check(cv._p["LightsOn?"] == false and hc._p.CurrentHealth == 0, "C3: the passenger's press: still off")
    me._parent = nil
    cv:ExitVehicle()
    tick(0.5)
    check(V._t.local_seat() == nil, "C3: out")
end

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
