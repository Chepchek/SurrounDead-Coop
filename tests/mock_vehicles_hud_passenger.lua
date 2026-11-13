-- The host's vehicle panel (VehicleUI_C) as a passenger: the mock_vehicles harness (copied)
-- with panels that know whether they are on screen, and the passenger / seat key scenarios.
-- usage: lua mock_vehicles.lua <scripts dir>
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

-- TArray stand-in (UE4SS semantics: reading past the end grows the array)
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

-- every hookable function path "exists"
setmetatable(by_path, { __index = function(_, k)
    if k:find(":") then return new_obj("Function", k) end
    return nil
end })

local net_mode = "host"
local timers = {}   -- [addr|fn] = true
local function tkey(o, fn) return tostring(o._addr) .. "|" .. fn end
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return net_mode == "standalone" end,
    IsServer = function() return net_mode == "host" end,
    K2_IsTimerActive = function(_, o, fn) return timers[tkey(o, fn)] == true end,
    K2_SetTimer = function(_, o, fn) timers[tkey(o, fn)] = true end,
    K2_ClearTimer = function(_, o, fn) timers[tkey(o, fn)] = nil end,
})
rawset(by_path, "/Script/Engine.Default__KismetSystemLibrary", ksl)

local controllers = {}  -- world controller list (index order)
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {
    GetPlayerController = function(_, wc, i) return controllers[i + 1] end,
    GetNumPlayerControllers = function() return #controllers end,
})
rawset(by_path, "/Script/Engine.Default__GameplayStatics", gps)
local montage = new_obj("AnimMontage", "Chr_SitInCar_Montage", {}, {})
rawset(by_path, "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage", montage)
local truck_cls = new_obj("BlueprintGeneratedClass", "Vehicle_PickupTruck_C", {}, {})
rawset(by_path, "/Game/Blueprints/Vehicles/Types/PickupTruck/Vehicle_PickupTruck.Vehicle_PickupTruck_C", truck_cls)
local gas_da = new_obj("JigsawItem_DataAsset_C", "DA_GasCan", {}, {})
rawset(by_path, "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan", gas_da)
rawset(by_path, "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit",
    new_obj("JigsawItem_DataAsset_C", "DA_VehicleRepairKit", {}, {}))

-- ------------------------------------------------------------ modules
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text) toasts[#toasts + 1] = text end
local ctx = require("sdc_ctx")
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... } }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
net.broadcast = function(pcs, kind, ...) for _, pc in ipairs(pcs) do net.send_to(pc, kind, ...) end end
local function last_sent(kind, to)
    for i = #sent, 1, -1 do
        local s = sent[i]
        if s.kind == kind and (to == nil or s.to == to) then return s end
    end
    return nil
end
local function deliver(kind, args, from_pc)
    local h = net.handlers[kind]
    assert(h, "no handler " .. kind)
    h(args, from_pc)
end

-- a respawn-like resolver already installed (chain test)
local gi = new_obj("SD_GameInstance_C", "SD_GameInstance_C_0", {}, {})
local respawn_said = nil
ctx.scope_resolver = function(wco) if wco == gi then return respawn_said end return nil end

local V = require("sdc_vehicles")
local S = { role = "host", remote = {}, remote_pcs = {}, client = nil }
V.install(S)

-- ------------------------------------------------------------ world
local host_vp = {}      -- widgets in the host viewport
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
    ch._pid = pid
    local cap = new_obj("CapsuleComponent", name .. "_Capsule", {}, {})
    cap._m.UnWeldFromParent = function() ch._welded = false; ch._unwelds = (ch._unwelds or 0) + 1 end
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { vis = 2,
        bOnlyAllowAutonomousTickPose = not is_local }, {})
    mesh._m.GetCollisionResponseToChannel = function(m, c) if c == 3 then return m._p.vis end return 2 end
    mesh._m.SetCollisionResponseToChannel = function(m, c, r) if c == 3 then m._p.vis = r end end
    ch._p.PlayerState, ch._p.CapsuleComponent, ch._p.Mesh = ps, cap, mesh
    local jig = new_obj("BP_JigComponent_C", name .. "_Jig", {}, {})
    jig._n = { DA_GasCan = 0, DA_VehicleRepairKit = 0 }
    local function da_key(da)
        if da == rawget(by_path, "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan") then return "DA_GasCan" end
        if da == rawget(by_path, "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit") then
            return "DA_VehicleRepairKit"
        end
        return "?"
    end
    jig._m.FindJigItemByDA = function(s, da, _t, _a, _b, _c, out) out.Result = (s._n[da_key(da)] or 0) >= 1 end
    jig._m.ServerFindThenConsumeByItemID = function(s, da, n, out)
        local k = da_key(da)
        if (s._n[k] or 0) >= (n or 1) then
            s._n[k] = s._n[k] - (n or 1)
            out.Result = true
        else
            out.Result = false
        end
    end
    ch._p.BP_JigMultiplayer = jig
    ch._m.ActorHasTag = function(_, n) return (n.ToString and n:ToString() or n) == "Player" end
    ch._m.IsLocallyControlled = function(s) return s._local == true end
    -- KeepWorld rules: the world location stays
    ch._m.K2_AttachToActor = function(s, parent, _sock, _l, _r, _sc, weld) s._parent = parent; s._welded = weld == true end
    ch._m.K2_DetachFromActor = function(s) s._parent = nil; s._welded = false end
    ch._m.StopMontage = function(s, m, inc) s._stop_everywhere = (s._stop_everywhere or 0) + 1; if inc then s._montage = nil end end
    ch._m.K2_SetActorLocationAndRotation = function(s, loc) s._p.__loc = { X = loc.X, Y = loc.Y, Z = loc.Z } end
    ch._m.PlayMontage = function(s, m) s._montage = m end
    ch._m.PlayAnimMontage = function(s, m) s._montage = m end
    ch._m.GetCurrentMontage = function(s) return s._montage end
    ch._m.StopAnimMontage = function(s) s._montage = nil end
    ch._m.SetWeaponsAndBackpackVisibility = function(s, hide) s._weapons_hidden = hide end
    ch._m.ResetVehicleCameraArmLength = function() end
    ch._m.VehicleInteraction = function(s, enter, vref)
        s._p["InVehicle?"] = enter          -- @151395, before the checks
        s._vi = (s._vi or 0) + 1
        if enter then
            -- @62073..62266: the vehicle's per-vehicle flags stop it half-way
            local vp = vref and vref._p or {}
            if vp.IsHeld or vp["InRefuellingArea?"] or vp["InRepairingArea?"] or vp["InStorageArea?"] then
                s._aborted = (s._aborted or 0) + 1
                return
            end
            s._p.VehicleDrivingComponent._p.Vehicle = vref; cmc._p.MovementMode = 0; s._weapons_hidden = true
        else s._weapons_hidden = false end
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
local conn2 = new_obj("IpConnection", "Conn2", {}, {})
local cl2_ch = new_char("Client2Char", { X = 900, Y = -50, Z = 100 }, false)
local cl2_pc = new_obj("BP_PlayerController_C", "Client2PC", { Pawn = cl2_ch, NetConnection = conn2 }, {}, { "PlayerController" })
cl2_ch._p.Controller = cl2_pc
cl2_ch._owner = cl2_pc
controllers = { host_pc, cl_pc, cl2_pc }
local r1 = { key = cl_pc:GetFullName(), pc = cl_pc, name = "Friend", index = 1 }
local r2 = { key = cl2_pc:GetFullName(), pc = cl2_pc, name = "Friend2", index = 2 }
S.remote[r1.key] = r1
S.remote[r2.key] = r2
S.remote_pcs = { cl_pc, cl2_pc }

-- the game's player 0, as a Blueprint asks GameplayStatics (through sdc_ctx)
local function player0(wco, fname)
    fname = fname or "GetPlayerCharacter"
    local h = hooks["/Script/Engine.GameplayStatics:" .. fname]
    local idx = param(0)
    if h and h.pre then h.pre(param(gps), param(wco), idx) end
    local pc = controllers[idx:get() + 1]
    if fname == "GetPlayerController" then return pc end
    return pc and pc._p.Pawn or nil
end

local post_fired = {}
local function fire_post(fn, ...)
    local h = hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:" .. fn]
    post_fired[fn] = (post_fired[fn] or 0) + 1
    if h and h.pre then h.pre(...) end   -- BP hooks: the only callback = after the body
end

local function new_vehicle(name, loc)
    local mc = new_obj("ChaosWheeledVehicleMovementComponent", name .. "_VMC",
        { bRequiresControllerForInputs = false, bUpdateOnlyIfRendered = true, hb = true }, {})
    mc._m.SetRequiresControllerForInputs = function(s, b) s._p.bRequiresControllerForInputs = b end
    mc._m.SetHandbrakeInput = function(s, b) s._p.hb = b end
    mc._m.SetBrakeInput = function() end
    local fc = new_obj("VehicleFuelComponent_C", name .. "_Fuel", { CurrentFuel = 30, MaxFuel = 1000, Empty = false }, {})
    fc._m.StartFuelSpend = function(s) timers[tkey(s, "FuelSpend")] = true end
    fc._m.StopSpendFuel = function(s) timers[tkey(s, "FuelSpend")] = nil end
    fc._m.UpdateUIFuel = function() end
    local hc = new_obj("VehicleHealthComponent_C", name .. "_Health", { CurrentHealth = 25, MaxHealth = 100 }, {})
    hc._m.UpdateUIHealth = function() end
    local snd = new_obj("AudioComponent", name .. "_Engine", { active = false }, {})
    snd._m.IsActive = function(s) return s._p.active end
    snd._m.Activate = function(s) s._p.active = true; s._p.starts = (s._p.starts or 0) + 1 end
    snd._m.FadeOut = function(s) s._p.active = false end
    local resp = { [2] = 2, [4] = 2 }
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { visible = true, mat = nil }, {})
    mesh._m.GetCollisionResponseToChannel = function(_, c) return resp[c] end
    mesh._m.SetCollisionResponseToChannel = function(_, c, r) resp[c] = r end
    mesh._m.IsVisible = function(s) return s._p.visible end
    mesh._m.GetSocketLocation = function(_, n)
        local nm = n.ToString and n:ToString() or tostring(n)
        if nm == "PassengerSide" then return { X = loc.X, Y = loc.Y + 200, Z = loc.Z } end
        return { X = loc.X, Y = loc.Y - 200, Z = loc.Z }
    end
    mesh._m.SetMaterial = function(s, i, m) s._p.mat = m end
    mesh._m.AddForce = function(s, f) s._p.force = f end
    local hb = new_obj("BoxComponent", name .. "_HitBox", { ov = true }, {})
    hb._m.GetGenerateOverlapEvents = function(s) return s._p.ov end
    local pl = new_obj("SceneComponent", name .. "_PlayerLocation", {}, {
        K2_GetComponentLocation = function() return { X = loc.X + 20, Y = loc.Y - 40, Z = loc.Z + 50 } end,
        K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end,
    })
    local colors = tarray({ new_obj("Material", "Red", {}, {}), new_obj("Material", "Blue", {}, {}), new_obj("Material", "Green", {}, {}) })
    local v = new_obj("Vehicle_ModifiedPickupUtilityTruck_C", name, {
        __loc = loc, VehicleMovementComponent = mc, FuelComponent = fc, VehicleHealthComponent = hc,
        EngineSound = snd, Mesh = mesh, HitBoxCollision = hb, PlayerLocation = pl, Colors = colors,
        Tags = tarray({ FName("Vehicle") }), ["LightsOn?"] = false, ["EngineOn?"] = true, VehicleColor = 0,
        ["TowingVehicle?"] = false, Role = 3 }, {}, { "BP_VehicleMaster_C" })
    for _, c in ipairs({ mc, fc, hc, snd, mesh, hb, pl }) do c._outer = v end
    v._resp = resp
    v._m.GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end
    -- the game's own functions (only what they do to player 0 and the vehicle)
    v._m.Interact_GetInVehicle = function(self)
        resp[2], resp[4] = 0, 0
        local ch = player0(self)
        ch:K2_AttachToActor(self, FName("None"), 1, 1, 1, true)
        ch:K2_SetActorLocationAndRotation(pl:K2_GetComponentLocation(), {})   -- @11932: to PlayerLocation
        ch:PlayMontage(montage, 1)
        local ui = new_obj("VehicleUI_C", "VehicleUI_" .. tostring(#host_vp + 1), {}, {})
        ui._m.RemoveFromParent = function(u) for i, w in ipairs(host_vp) do if w == u then table.remove(host_vp, i) end end end
        ui._m.IsInViewport = function(u) for _, w in ipairs(host_vp) do if w == u then return true end end return false end
        ui._m.AddToViewport = function(u) for _, w in ipairs(host_vp) do if w == u then return end end host_vp[#host_vp + 1] = u end
        host_vp[#host_vp + 1] = ui
        self._p.VehicleUI = ui
        fc:StartFuelSpend()
        timers[tkey(self, "CheckWater")] = true
        if fc._p.CurrentFuel > 0 then snd:Activate(true); timers[tkey(self, "VehicleSound")] = true; timers[tkey(self, "Event_Noise")] = true end
        self._entered_by = ch
        delayed[#delayed + 1] = function() local c = player0(self); c:VehicleInteraction(true, self); self._vi_by = c end
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
    end
    v._m.ExitVehicle = function(self)   -- the host's own exit (input): checks pass
        local ch = player0(self)
        self:Event_ExitVehicle()
        ch._p.CharacterMovement:SetMovementMode(1, 0)
        resp[2], resp[4] = 2, 2
        mc:SetHandbrakeInput(true)
        fc:StopSpendFuel()
        fire_post("ExitVehicle", param(self), param(true))
        ch:VehicleInteraction(false, nil)
    end
    v._m.TurnOnOffLights = function(self) self._p["LightsOn?"] = not self._p["LightsOn?"]; fire_post("TurnOnOffLights", param(self)) end
    v._m.Horn = function(self) self._honks = (self._honks or 0) + 1; fire_post("Horn", param(self)) end
    v._m.Event_FlipVehicle = function(self) self._flips = (self._flips or 0) + 1; fire_post("Event_FlipVehicle", param(self)) end
    v._m.VehicleEngineFX = function(self, vis) self._fx = (self._fx or 0) + 1 end
    v._m.AddTowingComp = function(self) self._p["TowingVehicle?"] = not self._p["TowingVehicle?"]; fire_post("AddTowingComp", param(self)) end
    v._m.RemoveTowingComp = function(self) self._p["TowingVehicle?"] = false; fire_post("RemoveTowingComp", param(self)) end
    v._m[ "BndEvt__BP_MPLootContainer_AIOSubject_K2Node_ComponentBoundEvent_0_OnOptimizationUpdate__DelegateSignature" ] =
        function(self) mesh._p.visible = true; hb._p.ov = true; self._woken = (self._woken or 0) + 1 end
    return v
end

local truck = new_vehicle("Vehicle_ModifiedPickupUtilityTruck_C_2147480001", { X = 1050, Y = 0, Z = 80 })
local function run_delayed() local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end
local function vstr(v) local l = v:K2_GetActorLocation(); return { tostring(l.X), tostring(l.Y), tostring(l.Z), v._cls } end
local function with(t, ...) local r = {}; for _, x in ipairs(t) do r[#r + 1] = x end; for _, x in ipairs({ ... }) do r[#r + 1] = x end; return r end

-- ------------------------------------------------------------ the host as a passenger: its vehicle panel (0.6.62 report)
local function panels()
    local n = 0
    for _, w in ipairs(host_vp) do if w._cls == "VehicleUI_C" then n = n + 1 end end
    return n
end
local function getins() return post_fired["Interact_GetInVehicle"] or 0 end
local function press_getin(v)   -- the host's key: TryInteract -> the game's get-in
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = v
    v:Interact_GetInVehicle()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    T = T + 0.1
    run_delayed()
end

print("host setup")
ctx.tick(S.remote_pcs)
V.tick()
local truck = new_vehicle("Vehicle_FlatbedTruck_C_2147475976", { X = 1050, Y = 0, Z = 80 })
T = T + 3
V.tick()

print("P1. the client drives, the host gets in: passenger, one panel")
deliver("VENTER", vstr(truck), cl_pc)
T = T + 0.1
run_delayed()
check(cl_ch._parent == truck and panels() == 0, "P1: client drives; no panel on the host's screen")
T = T + 2
press_getin(truck)
check(host_ch._parent == truck and panels() == 1, "P1: host is a passenger with one panel")
T = T + 1.1
V.tick()
check(panels() == 1, "P1: the tick keeps the host's own panel")

print("P2. a repeated press while a passenger (the game's get-in again)")
host_ch._p["InVehicle?"] = false
T = T + 2
press_getin(truck)
T = T + 1.1
V.tick()
check(host_ch._parent == truck and panels() == 1, "P2: still one panel")

print("P3. the client leaves: the host stays; its seat key takes the wheel, no second get-in, its panel kept")
local n0 = getins()
deliver("VEXIT", with(vstr(truck), "d", "20.0", "driver"), cl_pc)
check(cl_ch._parent == nil and host_ch._parent == truck, "P3: client out, the host still sits")
check(getins() == n0, "P3: the client's exit runs no get-in")
check(panels() == 1 and truck._p.VehicleUI ~= nil and host_vp[1] == truck._p.VehicleUI,
    "P3: one panel, the host's own (not taken by the client's exit)")
T = T + 1.1
V.tick()
check(panels() == 1, "P3: still one after the tick")
-- the driver's exit moves nobody: the host stays a passenger until its seat
-- key (SEATK.on_key, what the frame loop calls on the key's down edge)
local hst = V._t.vs()[truck._addr]
T = T + 0.5
V.tick()
check(hst and hst.host_seat == "passenger" and host_ch._parent == truck, "P3: 1.6 s after the client's exit: the host still a passenger")
V._t.seatk.on_key()
check(hst.host_seat == "driver" and host_ch._parent == truck and V.stats.promoted >= 1, "P3: the host's seat key: the wheel")
check(getins() == n0, "P3: the move to the wheel runs no get-in")
check(panels() == 1 and host_vp[1] == truck._p.VehicleUI, "P3: after the move: one panel, the host's own")

print("P4. the host gets out after taking the wheel: none")
T = T + 0.2
truck:ExitVehicle()
check(host_ch._parent == nil and panels() == 0, "P4: out, no panel")

print("P5. the client leaves while the host stays a passenger (a second client still drives? no: one driver) - then the host gets out")
deliver("VENTER", vstr(truck), cl_pc)
T = T + 0.1
run_delayed()
T = T + 2
host_ch._p["InVehicle?"] = false
press_getin(truck)
check(panels() == 1, "P5: host passenger, one panel")
deliver("VEXIT", with(vstr(truck), "d", "5.0", "driver"), cl_pc)
check(panels() == 1, "P5: the client's exit leaves the host's panel")
T = T + 3
truck:ExitVehicle()
check(panels() == 0, "P5: the host's exit removes it")
T = T + 1.1
V.tick()
check(panels() == 0, "P5: none after the tick")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
