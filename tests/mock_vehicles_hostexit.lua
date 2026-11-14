-- The host's own exit (0.7.0: "as the host I press exit twice to get my character back"):
-- the mock_vehicles harness (copied) with the game's real interact key: TryInteract sets
-- InteractExecutedActor and NOTHING clears it on release (only the inventory closing does);
-- the get-in's VehicleInteraction(true) runs 0.1 s later on whoever player 0 is then; the
-- key runs ExitVehicle only while the character has InVehicle? and a Vehicle.
-- usage: lua mock_vehicles_hostexit.lua <scripts dir>
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
local registry = {}          -- class -> list
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
                return function(s, cb)
                    for i, v in ipairs(rawget(s, "_items")) do cb(i, { get = function() return v end }) end
                end
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
function FindFirstOf(cls) local l = FindAllOf(cls); return l[1] end
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
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return net_mode == "standalone" end,
    IsServer = function() return net_mode == "host" end,
    K2_IsTimerActive = function(_, o, fn) return timers[tkey(o, fn)] == true end,
    K2_SetTimer = function(_, o, fn) timers[tkey(o, fn)] = true end,
    K2_ClearTimer = function(_, o, fn) timers[tkey(o, fn)] = nil end,
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

-- ------------------------------------------------------------ modules
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text) toasts[#toasts + 1] = text end
local warns = {}
do
    local w = log.warn
    log.warn = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        warns[#warns + 1] = ok and s or fmt
        return w(fmt, ...)
    end
end
local function warned(pat)
    for _, s in ipairs(warns) do if s:find(pat, 1, true) then return true end end
    return false
end
local infos = {}
do
    local i = log.info
    log.info = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        infos[#infos + 1] = ok and s or fmt
        return i(fmt, ...)
    end
end
local function said(pat)
    for _, s in ipairs(infos) do if s:find(pat, 1, true) then return s end end
    return nil
end
local ctx = require("sdc_ctx")
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... } }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
net.broadcast = function(pcs, kind, ...) for _, pc in ipairs(pcs) do net.send_to(pc, kind, ...) end end
local function deliver(kind, args, from_pc)
    local h = net.handlers[kind]
    assert(h, "no handler " .. kind)
    h(args, from_pc)
end

local gi = new_obj("SD_GameInstance_C", "SD_GameInstance_C_0", {}, {})
local fake_prev = function(wco) if wco == gi then return nil end return nil end
ctx.scope_resolver = fake_prev

local V = require("sdc_vehicles")
local S = { role = "host", remote = {}, remote_pcs = {}, client = nil }
V.install(S)
-- (the driver's exit moves nobody: a passenger takes the wheel with its seat
-- key - the host's press runs SEATK.on_key, a client's is its VSWITCH; the
-- key itself: mock_vehicles_seats W / K)

-- ------------------------------------------------------------ world
local CHAR_HOOK = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:VehicleInteraction"
local TRY_HOOK = "/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C:TryInteract"
local host_vp = {}
local next_pid = 100
local function new_char(name, loc, is_local)
    local cmc = new_obj("CharacterMovementComponent", name .. "_CMC",
        { MovementMode = 1, bServerAcceptClientAuthoritativePosition = true }, {})
    cmc._m.SetMovementMode = function(s, m) s._p.MovementMode = m end
    cmc._m.DisableMovement = function(s) s._p.MovementMode = 0 end
    local dc = new_obj("VehicleDrivingComponent_C", name .. "_VDC", {}, {})
    local helper = new_obj("BP_JigHelperComp_C", name .. "_Helper", {}, {})
    local ch = new_obj("BP_PlayerCharacter_C", name, {
        __loc = loc, CharacterMovement = cmc, VehicleDrivingComponent = dc, BP_JigHelperComp = helper,
        ["InVehicle?"] = false, ["PlayerDead?"] = false }, {})
    dc._outer = ch
    helper._owner = ch
    ch._local = is_local
    next_pid = next_pid + 1
    local pid = next_pid
    local ps = new_obj("PlayerState", name .. "_PS", {}, {
        GetPlayerId = function() return pid end, GetPlayerName = function() return name end })
    local cap = new_obj("CapsuleComponent", name .. "_Capsule", {}, {})
    cap._m.UnWeldFromParent = function() ch._welded = false end
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { vis = 2, bOnlyAllowAutonomousTickPose = not is_local }, {})
    mesh._m.GetCollisionResponseToChannel = function(m, c) if c == 3 then return m._p.vis end return 2 end
    mesh._m.SetCollisionResponseToChannel = function(m, c, r) if c == 3 then m._p.vis = r end end
    ch._p.PlayerState, ch._p.CapsuleComponent, ch._p.Mesh = ps, cap, mesh
    ch._p.BP_JigMultiplayer = new_obj("BP_JigComponent_C", name .. "_Jig", {}, {})
    ch._m.ActorHasTag = function(_, n) return (n.ToString and n:ToString() or n) == "Player" end
    ch._m.IsLocallyControlled = function(s) return s._local == true end
    ch._m.K2_AttachToActor = function(s, parent, _sock, _l, _r, _sc, weld) s._parent = parent; s._welded = weld == true end
    ch._m.K2_DetachFromActor = function(s) s._parent = nil; s._welded = false end
    ch._m.StopMontage = function(s) end
    ch._m.K2_SetActorLocationAndRotation = function(s, l) s._p.__loc = { X = l.X, Y = l.Y, Z = l.Z } end
    ch._m.PlayMontage = function(s, m) s._montage = m end
    ch._m.PlayAnimMontage = function(s, m) s._montage = m end
    ch._m.GetCurrentMontage = function(s) return s._montage end
    ch._m.StopAnimMontage = function(s) s._montage = nil end
    ch._m.SetWeaponsAndBackpackVisibility = function(s, hide) s._weapons_hidden = hide end
    ch._m.ResetVehicleCameraArmLength = function(s) s._cam_resets = (s._cam_resets or 0) + 1 end
    -- BP_PlayerCharacter.VehicleInteraction (@151395 -> @62059), then the post hook
    ch._m.VehicleInteraction = function(s, enter, vref)
        s._p["InVehicle?"] = enter
        s._vi = (s._vi or 0) + 1
        local ran = true
        if enter then
            local vp = vref and vref._p or {}
            if vp.IsHeld or vp["InRefuellingArea?"] or vp["InRepairingArea?"] or vp["InStorageArea?"] then ran = false end
            if ran then dc._p.Vehicle = vref; cmc._p.MovementMode = 0; s._weapons_hidden = true end
        else s._weapons_hidden = false end
        local h = hooks[CHAR_HOOK]
        if h and h.pre then h.pre(param(s), param(enter), param(vref)) end
    end
    return ch
end

local host_ch = new_char("HostChar", { X = 1000, Y = 0, Z = 100 }, true)
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_ch, Player = new_obj("LocalPlayer", "LP", {}, {}) },
    { IsLocalController = function() return true end }, { "PlayerController" })
host_ch._p.Controller = host_pc
local conn = new_obj("IpConnection", "Conn", {}, {})
local cl_ch = new_char("ClientChar", { X = 1100, Y = 50, Z = 100 }, false)
local cl_pc = new_obj("BP_PlayerController_C", "ClientPC", { Pawn = cl_ch, NetConnection = conn }, {}, { "PlayerController" })
cl_ch._p.Controller = cl_pc
cl_ch._owner = cl_pc
controllers = { host_pc, cl_pc }
local r1 = { key = cl_pc:GetFullName(), pc = cl_pc, name = "Friend", index = 1 }
S.remote[r1.key] = r1
S.remote_pcs = { cl_pc }

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
    if h and h.pre then h.pre(...) end   -- BP hooks: the only callback = after the body
end

local exits_run = 0   -- ExitVehicle calls (the key in a car)
local function new_vehicle(name, loc)
    local mc = new_obj("ChaosWheeledVehicleMovementComponent", name .. "_VMC",
        { bRequiresControllerForInputs = false, bUpdateOnlyIfRendered = true, hb = true }, {})
    mc._m.SetRequiresControllerForInputs = function(s, b) s._p.bRequiresControllerForInputs = b end
    mc._m.SetHandbrakeInput = function(s, b) s._p.hb = b end
    mc._m.SetBrakeInput = function() end
    mc._m.GetForwardSpeedMPH = function(s) return s._p.mph or 0 end
    local fc = new_obj("VehicleFuelComponent_C", name .. "_Fuel", { CurrentFuel = 30, MaxFuel = 1000 }, {})
    fc._m.StartFuelSpend = function(s) timers[tkey(s, "FuelSpend")] = true end
    fc._m.StopSpendFuel = function(s) timers[tkey(s, "FuelSpend")] = nil end
    local hc = new_obj("VehicleHealthComponent_C", name .. "_Health", { CurrentHealth = 90, MaxHealth = 100 }, {})
    local snd = new_obj("AudioComponent", name .. "_Engine", { active = false }, {})
    snd._m.IsActive = function(s) return s._p.active end
    snd._m.Activate = function(s) s._p.active = true end
    snd._m.FadeOut = function(s) s._p.active = false end
    local resp = { [2] = 2, [4] = 2 }
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { visible = true }, {})
    mesh._m.GetCollisionResponseToChannel = function(_, c) return resp[c] end
    mesh._m.SetCollisionResponseToChannel = function(_, c, r) resp[c] = r end
    mesh._m.IsVisible = function(s) return s._p.visible end
    mesh._m.GetSocketLocation = function(_, n)
        local nm = n.ToString and n:ToString() or tostring(n)
        if nm == "PassengerSide" then return { X = loc.X, Y = loc.Y + 200, Z = loc.Z } end
        return { X = loc.X, Y = loc.Y - 200, Z = loc.Z }
    end
    local hb = new_obj("BoxComponent", name .. "_HitBox", { ov = true }, {})
    hb._m.GetGenerateOverlapEvents = function(s) return s._p.ov end
    local pl = new_obj("SceneComponent", name .. "_PlayerLocation", {}, {
        K2_GetComponentLocation = function() return { X = loc.X + 20, Y = loc.Y - 40, Z = loc.Z + 50 } end,
        K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end,
    })
    local v = new_obj("Vehicle_FlatbedTruck_C", name, {
        __loc = loc, VehicleMovementComponent = mc, FuelComponent = fc, VehicleHealthComponent = hc,
        EngineSound = snd, Mesh = mesh, HitBoxCollision = hb, PlayerLocation = pl,
        Tags = tarray({ FName("Vehicle") }), ["LightsOn?"] = false, ["EngineOn?"] = true, VehicleColor = 0,
        ["TowingVehicle?"] = false, Role = 3 }, {}, { "BP_VehicleMaster_C" })
    for _, c in ipairs({ mc, fc, hc, snd, mesh, hb, pl }) do c._outer = v end
    v._m.GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end
    -- Interact_GetInVehicle (@11069..12484): player 0 attached at once, its
    -- VehicleInteraction(true) on whoever player 0 is 0.1 s later (@1706..1818)
    v._m.Interact_GetInVehicle = function(self)
        resp[2], resp[4] = 0, 0
        local ch = player0(self)
        ch:K2_AttachToActor(self, FName("None"), 1, 1, 1, true)
        ch:K2_SetActorLocationAndRotation(pl:K2_GetComponentLocation(), {})
        ch:PlayMontage(montage, 1)
        local ui = new_obj("VehicleUI_C", "VehicleUI_" .. tostring(next_addr), {}, {})
        ui._m.RemoveFromParent = function(u) for i, w in ipairs(host_vp) do if w == u then table.remove(host_vp, i) end end end
        ui._m.IsInViewport = function(u) for _, w in ipairs(host_vp) do if w == u then return true end end return false end
        ui._m.AddToViewport = function(u) for _, w in ipairs(host_vp) do if w == u then return end end host_vp[#host_vp + 1] = u end
        host_vp[#host_vp + 1] = ui
        self._p.VehicleUI = ui
        fc:StartFuelSpend()
        self._entered_by = ch
        delayed[#delayed + 1] = function() local c = player0(self); self._vi_by = c; c:VehicleInteraction(true, self) end
        fire_post("Interact_GetInVehicle", param(self))
    end
    -- Event_ExitVehicle (@24714..23482)
    v._m.Event_ExitVehicle = function(self)
        local ch = player0(self)
        ch:K2_DetachFromActor(1, 1, 1)
        local sock = mesh:GetSocketLocation(FName(self._p.GetOutPasseenger and "PassengerSide" or "DriverSide"))
        ch:K2_SetActorLocationAndRotation(sock, {})
        ch:StopAnimMontage(montage)
        local ui = self._p.VehicleUI
        if ui then ui:RemoveFromParent() end
        self._p.VehicleUI = nil
        self._p.GetOutPasseenger = false
        self._exited_by = ch
    end
    -- ExitVehicle (@0..719): player 0 must be in a vehicle; the tail on player 0
    v._m.ExitVehicle = function(self)
        exits_run = exits_run + 1
        local ch = player0(self)
        -- (@163: 10 MPH or more; @482..519: both door sockets blocked)
        local can = ch ~= nil and ch._p["InVehicle?"] == true and (mc._p.mph or 0) < 10 and not self._doors_blocked
        if can then
            self:Event_ExitVehicle()
            ch._p.CharacterMovement:SetMovementMode(1, 0)
            resp[2], resp[4] = 2, 2
            mc:SetHandbrakeInput(true)
            fc:StopSpendFuel()
        end
        fire_post("ExitVehicle", param(self), param(can))
        return can
    end
    v._m.OnExecuteInteract = function(self, who) self:Interact_GetInVehicle() end
    return v
end

local function run_delayed() local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end
local function vstr(v) local l = v:K2_GetActorLocation(); return { tostring(l.X), tostring(l.Y), tostring(l.Z), v._cls } end
local function with(t, ...) local r = {}; for _, x in ipairs(t) do r[#r + 1] = x end; for _, x in ipairs({ ... }) do r[#r + 1] = x end; return r end

-- The host's interact key, as BP_PlayerCharacter runs it (@108341..108673,
-- @87451..87570): in a vehicle (InVehicle? + a valid Vehicle) the game's exit,
-- then the character's own exit steps; otherwise TryInteract on what it looks
-- at. Nothing here clears InteractExecutedActor (the game does not either).
local host_look = nil
local function host_press()
    local dc = host_ch._p.VehicleDrivingComponent
    local hc = host_ch._p.BP_JigHelperComp
    if host_ch._p["InVehicle?"] then
        local veh = dc._p.Vehicle
        if veh and veh._valid then
            if veh:ExitVehicle() then
                host_ch:ResetVehicleCameraArmLength()
                host_ch:VehicleInteraction(false, nil)   -- @88168
                dc._p.Vehicle = nil                       -- @88192
                host_ch._p["InVehicle?"] = false          -- @88225
            end
            return "exit"
        end
        return "nothing"
    end
    hc._p.CurrentTracActor = host_look
    if host_look then
        hc._p.InteractExecutedActor = host_look      -- @1363
        host_look:OnExecuteInteract(host_ch, "GetIn")
    end
    local h = hooks[TRY_HOOK]
    if h and h.pre then h.pre(param(hc)) end
    return "interact"
end
local function host_free()
    return host_ch._parent == nil and host_ch._p["InVehicle?"] == false
        and host_ch._p.CharacterMovement._p.MovementMode == 1 and host_ch._p.VehicleDrivingComponent._p.Vehicle == nil
end

print("setup")
ctx.tick(S.remote_pcs)
V.tick()
local truck = new_vehicle("Vehicle_FlatbedTruck_C_2147475976", { X = 1050, Y = 0, Z = 80 })
T = T + 3
V.tick()
check(hooks[CHAR_HOOK] ~= nil, "VehicleInteraction hook registered")

print("H1. 0.7.0 16:33: the host drives, the client rides along, the host gets out with ONE press")
host_look = truck
check(host_press() == "interact" and host_ch._parent == truck, "H1: the host's key seats it")
check(host_ch._p.BP_JigHelperComp._p.InteractExecutedActor == nil, "H1: the press is over: no vehicle left as the host's interact target")
T = T + 0.1
run_delayed()
check(truck._vi_by == host_ch and host_ch._p["InVehicle?"] == true, "H1: the host's own get-in step reached the host")
T = T + 1
V.tick()
deliver("VENTER", vstr(truck), cl_pc)
check(cl_ch._parent == truck and V._t.seats()[r1.key].seat == "passenger", "H1: the client sits as a passenger")
T = T + 30
V.tick()
local n_exit = exits_run
host_look = nil
check(host_press() == "exit", "H1: the key in the car runs the game's exit")
check(host_ch._parent == nil and V._t.seats()[r1.key].seat == "passenger" and cl_ch._parent == truck,
    "H1: host out, the passenger stays in its seat")
deliver("VSWITCH", vstr(truck), cl_pc)
check(V._t.seats()[r1.key].seat == "driver" and cl_ch._parent == truck,
    "H1: the passenger's seat key: the wheel (the game's get-in for it)")
T = T + 0.1
run_delayed()   -- that get-in's step: VehicleInteraction(true) 0.1 s later
check(truck._vi_by == cl_ch, "H1: the delayed get-in step went to the new driver, not the host")
check(host_free(), "H1: the host is free right after ONE press (no driving state, walking)")
check((V.stats.stray_vi or 0) == 0, "H1: nothing had to be undone")
T = T + 0.5
V.tick()
check(host_press() == "interact" and exits_run == n_exit + 1, "H1: the next press is an ordinary interact, not a second exit")
check(cl_ch._p["InVehicle?"] == true and cl_ch._p.VehicleDrivingComponent._p.Vehicle == truck, "H1: the client drives with the game's state")
deliver("VEXIT", with(vstr(truck), "d", "3.0", "driver"), cl_pc)
T = T + 2
V.tick()
check(cl_ch._parent == nil and next(V._t.seats()) == nil, "H1: the client got out too")

print("H2. the seat swap: the client drives, the host rides along, the client leaves, the host exits with ONE press")
T = T + 5
V.tick()
cl_ch._p.__loc = { X = 1100, Y = 50, Z = 100 }
deliver("VENTER", vstr(truck), cl_pc)
T = T + 0.1
run_delayed()
check(cl_ch._parent == truck and truck._vi_by == cl_ch, "H2: the client drives")
T = T + 2
V.tick()
host_look = truck
check(host_press() == "interact" and host_ch._parent == truck and truck._entered_by == host_ch, "H2: the host's key seats the HOST")
check(V._t.vs()[host_ch._addr] == nil and V._t.vs()[truck._addr].host_seat == "passenger", "H2: as a passenger")
host_ch._p.BP_JigHelperComp._p.CurrentTracActor = nil
T = T + 0.1
run_delayed()
check(truck._vi_by == host_ch and host_ch._p["InVehicle?"] == true, "H2: the host's own get-in step reached the host")
T = T + 20
V.tick()
deliver("VEXIT", with(vstr(truck), "d", "22.0", "driver"), cl_pc)
check(cl_ch._parent == nil and host_ch._parent == truck and V._t.vs()[truck._addr].host_seat == "passenger",
    "H2: the client is out, the host stays in its seat")
V._t.seatk.on_key()
check(host_ch._parent == truck and V._t.vs()[truck._addr].host_seat == "driver", "H2: the host's seat key: the wheel")
check(host_ch._p["InVehicle?"] == true and host_ch._p.VehicleDrivingComponent._p.Vehicle == truck,
    "H2: the host keeps the game's driving state")
T = T + 0.1
run_delayed()
T = T + 60
V.tick()
n_exit = exits_run
host_look = nil
check(host_press() == "exit" and host_free(), "H2: ONE press: the host is out and free")
T = T + 0.1
run_delayed()
T = T + 0.5
V.tick()
check(host_free(), "H2: still free after the tick")
check(host_press() == "interact" and exits_run == n_exit + 1, "H2: the next press is an ordinary interact")

print("H3. the client gets in again as the driver while the host stands at the car looking at it")
T = T + 5
V.tick()
host_ch._p.BP_JigHelperComp._p.CurrentTracActor = truck
deliver("VENTER", vstr(truck), cl_pc)
T = T + 0.1
run_delayed()
check(truck._vi_by == cl_ch and cl_ch._p["InVehicle?"] == true, "H3: the client's get-in step went to the client")
check(host_free(), "H3: the host standing at the car keeps its control")
-- sdc_ctx's idle check while the client drives (the vehicle is watched): the
-- host's fast exit works for objects that are no part of a watched vehicle
do
    ctx.set_idle_check(fake_prev, function() return true end)
    local probe = new_obj("StaminaComponent_C", "IdleProbe", {}, {})
    local part = new_obj("VehicleMovementComponent_C", "IdlePart", {}, {})
    part._outer = truck
    local pa, ta = ctx.addr(probe), ctx.addr(part)
    local rs = ctx.scope_resolver
    check(ctx.resolver_idle(rs, ctx.addr(truck)) == false, "H3 idle: the watched vehicle itself is busy")
    check(ctx.resolver_idle(rs, pa) == false, "H3 idle: an object not seen yet is busy (its outer is unknown)")
    rs(probe, pa); rs(part, ta)
    check(ctx.resolver_idle(rs, pa) == true, "H3 idle: ... idle once its outer is known not to be a vehicle")
    check(ctx.resolver_idle(rs, ta) == false, "H3 idle: a part of the watched vehicle stays busy")
    check(ctx.busy["vehicles:a watched vehicle"] and ctx.busy["vehicles:part of a watched vehicle"]
        and ctx.busy["vehicles:outer of the object not read yet"], "H3 idle: reasons counted")
    ctx.set_idle_check(fake_prev, nil)
end
T = T + 3
V.tick()
deliver("VEXIT", with(vstr(truck), "d", "3.0", "driver"), cl_pc)
T = T + 3
V.tick()

print("H4. a fresh press inside a client's entry window still seats the host (0.6.62)")
T = T + 5
V.tick()
deliver("VENTER", vstr(truck), cl_pc)
T = T + 0.1
run_delayed()
T = T + 0.3
host_look = truck
host_press()
check(host_ch._parent == truck and truck._entered_by == host_ch, "H4: the host's own get-in attached the HOST")
check(cl_ch._parent == truck, "H4: the client still drives")
T = T + 0.1
run_delayed()
check(cl_ch._p["InVehicle?"] == true and host_ch._p["InVehicle?"] == true, "H4: both have the game's state")
T = T + 2
V.tick()
host_look = nil
host_press()   -- out (passenger)
T = T + 0.2
deliver("VEXIT", with(vstr(truck), "d", "3.0", "driver"), cl_pc)
T = T + 3
V.tick()
check(host_free() and cl_ch._parent == nil, "H4: both out")

print("H5. race: the passenger takes the wheel (its key) and leaves again within the get-in's 0.1 s")
T = T + 5
V.tick()
host_look = truck
host_press()
T = T + 0.1
run_delayed()
T = T + 1
V.tick()
cl_ch._p.__loc = { X = 1100, Y = 50, Z = 100 }
deliver("VENTER", vstr(truck), cl_pc)
check(V._t.seats()[r1.key].seat == "passenger", "H5: client passenger")
T = T + 10
V.tick()
host_look = nil
host_press()                                                      -- the host gets out
deliver("VSWITCH", vstr(truck), cl_pc)                            -- the client takes the wheel with its key
check(V._t.seats()[r1.key].seat == "driver", "H5: the client at the wheel")
deliver("VEXIT", with(vstr(truck), "d", "0.0", "driver"), cl_pc)  -- and leaves before the 0.1 s step
T = T + 0.1
local cams = host_ch._cam_resets or 0
run_delayed()                                                     -- that step: player 0 = the host (released window)
check((V.stats.stray_vi or 0) == 1 and warned("who does not sit in it"), "H5: the misrouted get-in step was seen and logged")
check(host_free(), "H5: and undone: the host is free without a second press")
check((host_ch._cam_resets or 0) == cams + 1, "H5: the camera arm reset as the game's own exit does")
check(host_press() == "interact", "H5: the next press is an ordinary interact")
T = T + 3
V.tick()

print("H6. diagnostics: a press that runs the game's exit while the host sits in no seat")
T = T + 5
V.tick()
host_ch._p["InVehicle?"] = true                       -- the frozen state of 0.7.0
host_ch._p.VehicleDrivingComponent._p.Vehicle = truck
host_ch._p.CharacterMovement._p.MovementMode = 0
local promoted = V.stats.promoted
check(host_press() == "exit" and host_free(), "H6: the second press frees it (the game's exit)")
check((V.stats.stray_exits or 0) == 1 and warned("although the host sat in no seat there"), "H6: logged as a stray exit")
check(V.stats.promoted == promoted, "H6: nobody moved to the wheel")

print("H7. a trader stays the host's interact target (the dialogue's trade event reads it later)")
local npc = new_obj("BP_TraderMaster_C", "BP_Trader_C_1", { __loc = { X = 2000, Y = 0, Z = 100 } }, {})
npc._m.OnExecuteInteract = function() end
host_look = npc
host_press()
check(host_ch._p.BP_JigHelperComp._p.InteractExecutedActor == npc, "H7: the trader is kept")
host_look = nil

print("H8. a press the game refuses (moving, doors blocked) leaves a line; the next one gets out")
T = T + 5
V.tick()
host_look = truck
host_press()
T = T + 0.1
run_delayed()
T = T + 1
V.tick()
host_look = nil
truck._p.VehicleMovementComponent._p.mph = 23
local n8 = exits_run
check(host_press() == "exit" and host_ch._parent == truck and exits_run == n8 + 1, "H8: moving: the game's exit refused, the host still sits")
local line = said("but the host still sits there")
check(line ~= nil and line:find("CanExit=false", 1, true) ~= nil and line:find("23.0 MPH", 1, true) ~= nil,
    "H8: logged with CanExit=false and the speed")
check((V.stats.stray_exits or 0) == 1, "H8: not counted as a stray exit")
truck._p.VehicleMovementComponent._p.mph = 0
check(host_press() == "exit" and host_free(), "H8: stopped: the next press gets out")

print("H9. left frozen beside the car without pressing: the 2 s safety net walks again too")
T = T + 5
V.tick()
host_ch._p["InVehicle?"] = true
host_ch._p.VehicleDrivingComponent._p.Vehicle = truck
host_ch._p.CharacterMovement._p.MovementMode = 0
V.tick()
T = T + 2.5
V.tick()
check(host_free(), "H9: InVehicle? cleared and walking again")
check(warned("walking again (its movement was off)"), "H9: logged")

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
