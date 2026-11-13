-- Mock harness for sdc_vehicles (+ the real sdc_ctx player-0 hook it chains into).
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
net.send_to = function(pc, kind, ...)
    local args = { ... }
    -- (0.7.3: VSTATE|*|<12 fields>|<12 fields>|...: one entry per vehicle record, as the single form was)
    if kind == "VSTATE" and args[1] == "*" then
        for i = 2, #args, 12 do sent[#sent + 1] = { to = pc, kind = kind, args = table.move(args, i, i + 11, 1, {}) } end
        return true
    end
    sent[#sent + 1] = { to = pc, kind = kind, args = args }; return true
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
-- (the driver's exit moves nobody: a passenger takes the wheel with its seat
-- key - the host's press runs SEATK.on_key, a client's is the VSWITCH it
-- sends; the key itself: mock_vehicles_seats W / K)
local function host_key() V._t.seatk.on_key() end

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

-- ------------------------------------------------------------ host: ctx on
print("host setup")
ctx.tick(S.remote_pcs)
check(ctx.active, "ctx redirection active")
V.tick()
check(ctx.scope_resolver ~= nil and ctx.scope_resolver(gi) == nil, "chained resolver: no opinion passes through")
respawn_said = cl_pc
check(ctx.scope_resolver(gi) == cl_pc, "chained resolver: the previous resolver still answers")
respawn_said = nil
check(hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:Interact_GetInVehicle"] ~= nil, "enter hook registered")
check(last_sent("VCAP", cl_pc) ~= nil, "VCAP sent to clients")
check(player0(truck) == host_ch, "an idle vehicle's player 0 is the host")

-- ------------------------------------------------------------ 1. client drives
print("1. client enters an empty vehicle")
deliver("VENTER", vstr(truck), cl_pc)
check(cl_ch._parent == truck, "the client's character is attached on the host")
check(host_ch._parent == nil, "the host is not attached")
check(truck._entered_by == cl_ch, "the game's entry ran with player 0 = the client")
check(#host_vp == 0, "the host-side VehicleUI was removed from the host's screen")
check(truck._p.VehicleUI == nil, "vehicle has no VehicleUI reference on the host")
check(truck._owner == cl_pc, "vehicle owner = the client's controller (its ServerUpdateState reaches the host)")
check(truck._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "host copy uses the replicated inputs")
check(truck._p.VehicleMovementComponent._p.bUpdateOnlyIfRendered == false, "host keeps simulating it unseen")
check(cl_ch._p.CharacterMovement._p.bServerAcceptClientAuthoritativePosition == false, "server keeps the seat position of the client")
local s = last_sent("VSEAT", cl_pc)
check(s and s.args[1] == "driver", "VSEAT driver sent to the client")
T = T + 0.1
run_delayed()
check(truck._vi_by == cl_ch, "the delayed VehicleInteraction(true) went to the client's character")
check(cl_ch._p["InVehicle?"] == true, "host copy of the client: InVehicle? true")
check(truck._resp[2] == 0, "mesh ignores pawns while driven")

print("1b. player 0 of the client-driven vehicle")
T = T + 2
V.tick()
check(player0(truck) == cl_ch, "noise / damage instigator of the vehicle = the client")
check(player0(truck, "GetPlayerController") == cl_pc, "GetHUD etc. = the client's controller (no HUD on the host)")
-- a component of the vehicle
check(player0(truck._p.FuelComponent) == cl_ch, "a component of the vehicle resolves to the driver too")

print("1c. AI optimizer hid the vehicle on the host")
truck._p.Mesh._p.visible = false
truck._p.HitBoxCollision._p.ov = false
V.tick()
check((truck._woken or 0) == 1 and truck._p.Mesh._p.visible == true, "the game's AIO handler woke it for the remote driver")

-- ------------------------------------------------------------ 2. host as passenger
print("2. host presses E on the client-driven vehicle")
host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = truck
truck:Interact_GetInVehicle()
check(host_ch._parent == truck, "the host's own entry attached the HOST (not the client)")
check(truck._entered_by == host_ch, "player 0 = host during the host's interaction")
check(math.abs(host_ch._p.__loc.Y - (0 + 40)) < 1, "host moved to the mirrored (passenger) seat")
check(#host_vp == 1, "the host keeps its own VehicleUI as a passenger")
host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
T = T + 0.1
run_delayed()
check(truck._vi_by == host_ch, "host's delayed VehicleInteraction went to the host")
T = T + 1
V.tick()
check(player0(truck) == host_ch, "while the host sits in it, the vehicle's player 0 is the host")
check(truck._owner == cl_pc, "owner stays the driver")

print("2b. second client tries: no seat")
deliver("VENTER", vstr(truck), cl2_pc)
s = last_sent("VSEAT", cl2_pc)
check(s and s.args[1] == "none" and s.args[2] == "full", "third player rejected: full")
check(cl2_ch._parent == nil, "not attached")

print("2c. a client sdc_ctx cannot redirect (no controller index)")
do
    local truck3 = new_vehicle("Vehicle_Van_C_2147480077", { X = 1000, Y = 300, Z = 80 })
    local conn3 = new_obj("IpConnection", "Conn3", {}, {})
    local cl3_ch = new_char("Client3Char", { X = 1000, Y = 350, Z = 100 }, false)
    local cl3_pc = new_obj("BP_PlayerController_C", "Client3PC", { Pawn = cl3_ch, NetConnection = conn3 }, {}, {})
    local r3 = { key = cl3_pc:GetFullName(), pc = cl3_pc, name = "Friend3", index = 3 }
    S.remote[r3.key] = r3
    deliver("VENTER", vstr(truck3), cl3_pc)
    local s3 = last_sent("VSEAT", cl3_pc)
    check(s3 and s3.args[1] == "none" and s3.args[2] == "no player index", "rejected instead of running the entry as the host")
    check(cl3_ch._parent == nil and truck3._entered_by == nil, "the game's entry was not run")
    S.remote[r3.key] = nil
    truck3._valid = false
end

-- ------------------------------------------------------------ 3. lights / horn / flip from the driver
print("3. relays")
deliver("VLIGHT", with(vstr(truck), "1"), cl_pc)
check(truck._p["LightsOn?"] == true, "driver's lights on, on the host")
deliver("VLIGHT", with(vstr(truck), "0"), cl2_pc)
check(truck._p["LightsOn?"] == true, "a non-occupant cannot switch them")
local n0 = #sent
deliver("VHORN", vstr(truck), cl_pc)
check((truck._honks or 0) == 1, "horn played on the host")
local hs = last_sent("VHORN", cl2_pc)
check(hs ~= nil and last_sent("VHORN", cl_pc) == nil, "horn forwarded to the others, not back to the driver")
deliver("VFLIP", vstr(truck), cl_pc)
check((truck._flips or 0) == 1, "flip ran on the host")
deliver("VTOW", with(vstr(truck), "1"), cl_pc)
check(truck._p["TowingVehicle?"] == true, "towing started on the host")
deliver("VFUEL", with(vstr(truck), "530.0"), cl2_pc)
check(truck._p.FuelComponent._p.CurrentFuel == 530, "refuel from a nearby player applied")
deliver("VFUEL", with(vstr(truck), "10.0"), cl2_pc)
check(truck._p.FuelComponent._p.CurrentFuel == 530, "fuel never goes down by message")
deliver("VREPAIR", with(vstr(truck), "75.0"), cl2_pc)
check(truck._p.VehicleHealthComponent._p.CurrentHealth == 75 and truck._p["EngineOn?"] == true, "repair applied")
deliver("VPUSH", with(vstr(truck), "1", "0", "0"), cl2_pc)
check(truck._p.Mesh._p.force and truck._p.Mesh._p.force.X == 4e7, "push force applied")
deliver("VPUSH", with(vstr(truck), "1", "0", "0"), cl2_pc)

-- ------------------------------------------------------------ 4. state broadcast
print("4. VSTATE")
sent = {}
V.tick()
local st = last_sent("VSTATE", cl2_pc)
check(st ~= nil, "VSTATE broadcast")
check(st and st.args[8] == "1" and st.args[10] == "1", "lights on, driver present")
sent = {}
T = T + 1
V.tick()
check(last_sent("VSTATE", cl2_pc) == nil, "no resend without a change")

-- ------------------------------------------------------------ 5. driver exits, the host passenger takes the wheel with its key
print("5. the client driver leaves: the host stays in its seat; its seat key: the wheel")
deliver("VEXIT", with(vstr(truck), "d"), cl_pc)
check(cl_ch._parent == nil and truck._exited_by == cl_ch, "Event_ExitVehicle ran for the client (detached)")
check(host_ch._parent == truck, "the host passenger stays attached")
check(truck._owner == nil, "owner cleared")
check(truck._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false, "host copy back to its own inputs")
check(cl_ch._p.CharacterMovement._p.bServerAcceptClientAuthoritativePosition == true, "client position authority restored")
check(cl_ch._p["InVehicle?"] == false, "host copy of the client: out of the vehicle")
check(math.abs(host_ch._p.__loc.Y - 40) < 1 and truck._p.VehicleMovementComponent._p.hb == true, "the host stays in the passenger seat; the car parked (handbrake on)")
host_key()
check(math.abs(host_ch._p.__loc.Y - (-40)) < 1, "the host's seat key: moved to the driver seat")
check(truck._p.VehicleMovementComponent._p.hb == false, "handbrake off for the host as the new driver")
check(truck._p.EngineSound._p.active == true, "engine sound running again for the host")
check(truck._resp[2] == 0, "mesh still ignores pawns (occupied)")
check(player0(truck) == host_ch, "player 0 = host again")

-- ------------------------------------------------------------ 6. passenger with the host driving
print("6. client enters the host-driven vehicle")
deliver("VENTER", vstr(truck), cl2_pc)
check(cl2_ch._parent == truck, "passenger attached on the host")
check(math.abs(cl2_ch._p.__loc.Y - 40) < 1, "at the mirrored seat")
check(cl2_ch._montage == montage, "sit montage played")
check(cl2_ch._p["InVehicle?"] == true, "host copy: InVehicle? (VehicleInteraction)")
s = last_sent("VSEAT", cl2_pc)
check(s and s.args[1] == "passenger", "VSEAT passenger")
check(truck._owner == nil, "owner unchanged (host drives)")
deliver("VLIGHT", with(vstr(truck), "0"), cl2_pc)
check(truck._p["LightsOn?"] == true, "a passenger does not switch the lights")
T = T + 3
V.tick()

print("6b. the host leaves; the passenger stays; its seat key: the wheel")
truck:ExitVehicle()
check(host_ch._parent == nil, "host out")
check(cl2_ch._parent == truck and truck._entered_by ~= cl2_ch and truck._owner == nil, "6b: the passenger stays in its seat (no get-in for it)")
deliver("VSWITCH", vstr(truck), cl2_pc)
check(cl2_ch._parent == truck and truck._entered_by == cl2_ch, "passenger re-entered as the driver through the game's entry")
check(truck._owner == cl2_pc, "owner = the client at the wheel")
s = last_sent("VSEAT", cl2_pc)
check(s and s.args[1] == "driver", "VSEAT driver to the client at the wheel")
check(cl2_ch._welded == false, "6b: the passenger at the wheel unwelded again after the game's get-in welded it (its seat replicates)")
T = T + 0.1
run_delayed()

print("6c. the driver's character dies")
cl2_ch._p["PlayerDead?"] = true
T = T + 3
V.tick()
check(truck._owner == nil, "seat released on death")
check(truck._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false, "flags back")
cl2_ch._p["PlayerDead?"] = false

-- ------------------------------------------------------------ 8. play report (0.6.44)
print("8. host drives while the client stands at the fuel box")
local truck4 = new_vehicle("Vehicle_Sheriff_C_2147476240", { X = 3000, Y = 0, Z = 80 })
do
    for _, c in ipairs({ host_ch, cl_ch, cl2_ch }) do
        c._parent = nil; c._p["InVehicle?"] = false; c._p.VehicleDrivingComponent._p.Vehicle = nil
    end
    host_ch._p.__loc = { X = 2950, Y = -150, Z = 100 }
    cl_ch._p.__loc = { X = 3050, Y = 160, Z = 100 }
    T = T + 5
    V.tick()
    truck4._p["InRefuellingArea?"] = true      -- the client's overlap of the fuel box, on the host's copy
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = truck4
    truck4:Interact_GetInVehicle()
    check(host_ch._parent == truck4, "8: the host's own entry attached the host")
    check(truck4._p["InRefuellingArea?"] == false, "8: the client's fuel-box flag cleared for the host's entry")

    print("8a. the client asks inside the 0.1 s before the host's VehicleInteraction")
    deliver("VENTER", vstr(truck4), cl_pc)
    local s4 = last_sent("VSEAT", cl_pc)
    check(s4 and s4.args[1] == "passenger", "8a: client seated as PASSENGER (the host is attached at the wheel)")
    check(truck4._owner == nil, "8a: vehicle owner not given to the client")
    check(truck4._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false, "8a: the host's own inputs drive")
    check(cl_ch._parent == truck4 and math.abs(cl_ch._p.__loc.Y - 40) < 1, "8a: client at the passenger seat")
    check(cl_ch._p.VehicleDrivingComponent._p.Vehicle == truck4, "8a: the client's host copy has the driving state")
    T = T + 0.1
    run_delayed()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    check(host_ch._p.VehicleDrivingComponent._p.Vehicle == truck4 and (host_ch._aborted or 0) == 0,
        "8: the host's VehicleInteraction was not stopped half-way")
    check(player0(truck4) == host_ch, "8: player 0 of the host-driven car = host")

    print("8b. stopped half-way anyway (flag set again): the tick repairs it")
    host_ch._p.VehicleDrivingComponent._p.Vehicle = nil
    truck4._p["InRepairingArea?"] = true
    T = T + 1; V.tick(); T = T + 1; V.tick()
    check(host_ch._p.VehicleDrivingComponent._p.Vehicle == truck4 and host_ch._p["InVehicle?"] == true,
        "8b: host's driving state repaired (exit key and driving work again)")
    check(truck4._p["InRepairingArea?"] == false, "8b: the stale area flag cleared")

    print("8c. the host gets out: the client passenger stays; its seat key: the wheel")
    truck4:ExitVehicle()
    check(host_ch._parent == nil, "8c: the host got out")
    check(cl_ch._parent == truck4 and truck4._owner == nil and math.abs(cl_ch._p.__loc.Y - 40) < 1, "8c: the client stays in the passenger seat")
    deliver("VSWITCH", vstr(truck4), cl_pc)
    check(cl_ch._parent == truck4 and truck4._owner == cl_pc, "8c: the client is the driver now (owner)")
    check(truck4._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "8c: host copy takes the client's inputs")
    s4 = last_sent("VSEAT", cl_pc)
    check(s4 and s4.args[1] == "driver", "8c: VSEAT driver")
    check(cl_ch._welded == false, "8c: the passenger at the wheel unwelded again after the game's get-in")
    T = T + 0.1
    run_delayed()

    print("8d. the host gets in while the client drives: passenger, and can get out")
    T = T + 2
    V.tick()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = truck4
    truck4:Interact_GetInVehicle()
    T = T + 0.1
    run_delayed()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    check(host_ch._parent == truck4 and math.abs(host_ch._p.__loc.Y - 40) < 1, "8d: host at the passenger seat")
    check(cl_ch._parent == truck4 and truck4._owner == cl_pc, "8d: the client still drives")
    T = T + 2
    V.tick()
    check(player0(truck4) == host_ch, "8d: the host's own exit / input resolves to the host")
    truck4:ExitVehicle()
    check(host_ch._parent == nil and truck4._exited_by == host_ch, "8d: the host got out (not the client)")
    check(cl_ch._parent == truck4 and truck4._owner == cl_pc, "8d: the client keeps driving")
    T = T + 1
    V.tick()
    check(truck4._p.EngineSound._p.active == true and truck4._resp[2] == 0, "8d: the client's engine / collision restored")

    print("8e. the client gets out, the host drives again, the client gets in: passenger")
    deliver("VEXIT", with(vstr(truck4), "d"), cl_pc)
    check(cl_ch._parent == nil and truck4._owner == nil, "8e: client out, vehicle released")
    T = T + 2
    V.tick()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = truck4
    truck4:Interact_GetInVehicle()
    T = T + 0.1
    run_delayed()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    T = T + 2
    V.tick()
    deliver("VENTER", vstr(truck4), cl_pc)
    s4 = last_sent("VSEAT", cl_pc)
    check(s4 and s4.args[1] == "passenger", "8e: passenger again (not driver)")
    check(math.abs(host_ch._p.__loc.Y - (-40)) < 1 and truck4._owner == nil, "8e: the host keeps the wheel")

    print("8f. the old state (client made driver of the host's car) is put right")
    local st4 = V._t.vs()[truck4._addr]
    local key1 = cl_pc:GetFullName()
    st4.pax[2], st4.driver_key = nil, key1
    V._t.seats()[key1].seat = "driver"
    truck4._owner = cl_pc
    truck4._p.VehicleMovementComponent._p.bRequiresControllerForInputs = true
    T = T + 2
    V.tick()
    check(st4.driver_key == nil and st4.pax[2] == key1, "8f: the client moved to the passenger seat")
    check(truck4._owner == nil and truck4._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false,
        "8f: owner / inputs back to the host")
    s4 = last_sent("VSEAT", cl_pc)
    check(s4 and s4.args[1] == "passenger", "8f: the client told it is a passenger")
    deliver("VEXIT", with(vstr(truck4), "p"), cl_pc)
    truck4:ExitVehicle()
    T = T + 2
    V.tick()
    truck4._valid = false
end

-- ------------------------------------------------------------ 9. seated players as every machine shows them (0.6.46)
print("9. host: seats unwelded, passenger pose, interact trace, seats in VSTATE")
local truck5 = new_vehicle("Vehicle_FlatbedTruck_C_2147475976", { X = 6000, Y = 0, Z = 80 })
do
    for _, c in ipairs({ host_ch, cl_ch, cl2_ch }) do
        c._parent = nil; c._p["InVehicle?"] = false; c._p.VehicleDrivingComponent._p.Vehicle = nil; c._montage = nil
    end
    host_ch._p.__loc = { X = 5950, Y = -150, Z = 100 }
    cl_ch._p.__loc = { X = 6050, Y = 160, Z = 100 }
    T = T + 5
    V.tick()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = truck5
    truck5:Interact_GetInVehicle()
    check(host_ch._parent == truck5 and host_ch._welded == false,
        "9a: the host's seat unwelded right after the game's entry (a welded seat does not replicate)")
    T = T + 0.1
    run_delayed()
    host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    check(host_ch._p.Mesh._p.vis == 2, "9a: the host's own mesh is left alone here")

    deliver("VENTER", vstr(truck5), cl_pc)
    check(cl_ch._parent == truck5 and cl_ch._welded == false, "9b: passenger attached without welding")
    T = T + 1
    V.tick()
    check(cl_ch._p.Mesh._p.vis == 0, "9b: the passenger's mesh lets the interact trace reach the car")
    check(cl_ch._p.Mesh._p.bOnlyAllowAutonomousTickPose == false, "9b: the passenger's pose ticks on the host")
    check(cl_ch._montage == montage, "9b: the passenger sits (sit montage)")
    cl_ch._montage = new_obj("AnimMontage", "Chr_Interact_Looting_Montage", {}, {})
    T = T + 0.5
    V.tick()
    check(cl_ch._montage == montage, "9b: sit montage started again after another montage replaced it")

    sent = {}
    local st5 = V._t.vs()[truck5._addr]
    st5.dirty = true
    V.tick()
    local vs5 = last_sent("VSTATE", cl_pc)
    check(vs5 and vs5.args[11] == tostring(host_ch._pid) and vs5.args[12] == tostring(cl_ch._pid),
        "9c: VSTATE: the host drives, the client is the passenger (PlayerIds)")

    print("9d. the host gets out: its sit pose ends on every machine")
    truck5:ExitVehicle()
    check((host_ch._stop_everywhere or 0) >= 1, "9d: the game's replicated StopMontage for the host")
    deliver("VSWITCH", vstr(truck5), cl_pc)
    check(cl_ch._parent == truck5 and truck5._owner == cl_pc, "9d: the passenger takes the wheel with its seat key")
    T = T + 0.1
    run_delayed()
    sent = {}
    st5.dirty = true
    T = T + 1
    V.tick()
    vs5 = last_sent("VSTATE", cl_pc)
    check(vs5 and vs5.args[11] == tostring(cl_ch._pid) and vs5.args[12] == "", "9d: VSTATE: the client drives, passenger seat free")

    print("9e. the client gets out 0.8 s later")
    deliver("VEXIT", with(vstr(truck5), "d", "0.8", "driver"), cl_pc)
    check(cl_ch._parent == nil, "9e: the client got out")
    check(cl_ch._p.Mesh._p.vis == 2 and cl_ch._p.Mesh._p.bOnlyAllowAutonomousTickPose == true,
        "9e: interact trace / pose tick back to the engine's")
    check((cl_ch._stop_everywhere or 0) >= 1 and cl_ch._montage == nil, "9e: the sit pose ended (here and everywhere)")
    T = T + 1
    V.tick()
    truck5._valid = false
end

-- ------------------------------------------------------------ 10. refuel / repair (0.6.48)
-- R: the game's fuel box / Refuel Vehicle / hold / UseGasCan (BP_VehicleMaster
-- @15292 @14726 @17947 @18506 @1866 @1887), as far as they touch state.
local R = { GAS = "Jig.InteractOptions.RefuelVehicle" }
function R.give_hud(pc)
    local hud = new_obj("HUD_Game_C", pc._short .. "_HUD", {}, {})
    hud._m.InteractTimerUI = function(s, open, text)
        if open then
            s._p.InteractTimerWidget = new_obj("InteractionTimerUI_C", "Timer", { MaxTime = 0 }, {})
            s._opens, s._text = (s._opens or 0) + 1, text
        else
            s._p.InteractTimerWidget = nil
        end
    end
    pc._m.GetHUD = function() return hud end
    return hud
end
function R.hud0(v)
    local c = player0(v, "GetPlayerController")
    return c and c._m.GetHUD and c:GetHUD() or nil
end
function R.fuel_game(v)
    local p = v._p
    local fc = p.FuelComponent
    p.Duration, p.IsHeld, p["InRefuellingArea?"], p["InRepairingArea?"] = 10, false, false, false
    p.InteractOptions = { ["Jig.InteractOptions.Interact"] = true }
    local inbox = {}
    p.FuelBoxCollision = new_obj("BoxComponent", v._short .. "_FuelBox", {}, {
        IsOverlappingActor = function(_, a) return inbox[a] == true end })
    p.RepairBoxCollision = new_obj("BoxComponent", v._short .. "_RepairBox", {}, {
        IsOverlappingActor = function() return false end })
    fc._m.AddFuel = function(s, frac)
        s._p.CurrentFuel = math.min(s._p.MaxFuel, s._p.CurrentFuel + frac * s._p.MaxFuel)
        s._p.Empty = s._p.CurrentFuel <= 0
        s._addfuel = (s._addfuel or 0) + 1
    end
    v._m.OnBeginFuelInteract = function(self, a)
        if not a._p["InVehicle?"] and not p["InRefuellingArea?"] then
            p["InRefuellingArea?"] = true
            p.InteractOptions[R.GAS] = true
        end
        fire_post("OnBeginFuelInteract", param(self), param(a))
    end
    v._m.OnEndFuelInteract = function(self, a)
        p.IsHeld = false
        local hud = R.hud0(self)
        if hud then hud:InteractTimerUI(false, "") end
        if p["InRefuellingArea?"] then
            p["InRefuellingArea?"] = false
            p.InteractOptions[R.GAS] = nil
        end
        fire_post("OnEndFuelInteract", param(self), param(a))
    end
    v._enter_box = function(a) inbox[a] = true; v:OnBeginFuelInteract(a) end
    v._leave_box = function(a) inbox[a] = nil; v:OnEndFuelInteract(a) end
    v._m.OnExecuteInteract = function(self, who, tag)
        who._p.BP_JigHelperComp._p.InteractExecutedActor = self      -- TryInteract @1363
        local function done()
            fire_post("OnExecuteInteract", param(self), param(who), param({ TagName = FName(tag) }))
            who._p.BP_JigHelperComp._p.InteractExecutedActor = nil   -- key released
        end
        if p.IsHeld then p.IsHeld = false; return done() end
        if tag ~= R.GAS then return done() end
        p.IsHeld = true
        if fc._p.CurrentFuel == fc._p.MaxFuel then self._said = "Gas full"; return done() end
        local ch = player0(self)
        local jig = ch and ch._p.BP_JigMultiplayer
        if not jig or (jig._n.DA_GasCan or 0) < 1 then return done() end
        local hud = R.hud0(self)
        if hud then hud:InteractTimerUI(true, "Refilling Vehicle") end
        self._hold = ch
        done()
    end
    v._m.UseGasCan = function(self)
        local ch = player0(self)
        local jig = ch and ch._p.BP_JigMultiplayer
        local out = {}
        if jig then jig:ServerFindThenConsumeByItemID(gas_da, 1, out) end
        if out.Result then
            fc._p.CurrentFuel = math.min(fc._p.MaxFuel, fc._p.CurrentFuel + fc._p.MaxFuel / 2)
            fc._p.Empty = false
            self._gas_by = ch
        else
            self._said = "No gas found"
        end
        fire_post("UseGasCan", param(self))
    end
    v._hold_end = function()
        if p.IsHeld then p.IsHeld = false; v:UseGasCan() end
    end
end

print("10. host: refuel / repair")
local host_hud = R.give_hud(host_pc)
local truck6 = new_vehicle("Vehicle_PickupTruck_C_2147475000", { X = 8000, Y = 0, Z = 80 })
R.fuel_game(truck6)
do
    for _, c in ipairs({ host_ch, cl_ch, cl2_ch }) do c._parent = nil; c._p["InVehicle?"] = false; c._montage = nil end
    host_ch._p.__loc = { X = 7900, Y = -150, Z = 100 }
    cl_ch._p.__loc = { X = 8100, Y = 150, Z = 100 }
    cl2_ch._p.__loc = { X = 8050, Y = -150, Z = 100 }
    T = T + 5
    V.tick()
    local fc6 = truck6._p.FuelComponent
    fc6._p.CurrentFuel = 100

    print("10a. a client's refuel: added with the game's AddFuel, its gas can taken here")
    cl_ch._p.BP_JigMultiplayer._n.DA_GasCan = 2
    sent = {}
    deliver("VFUEL", with(vstr(truck6), "620.0", "500.0"), cl_pc)
    check(fc6._p.CurrentFuel == 600 and (fc6._addfuel or 0) == 1, "10a: +500 with the game's AddFuel (the host had 100)")
    check(cl_ch._p.BP_JigMultiplayer._n.DA_GasCan == 1, "10a: one gas can taken from the client's inventory on the host")
    T = T + 0.5
    V.tick()
    local vs6 = last_sent("VSTATE", cl_pc)
    check(vs6 ~= nil and tonumber(vs6.args[6]) == 600, "10a: the clients get the new fuel at once")

    print("10b. no such vehicle near the sender: logged, nothing changes")
    deliver("VFUEL", { "90000", "0", "80", truck6._cls, "900.0", "500.0" }, cl_pc)
    check(fc6._p.CurrentFuel == 600 and cl_ch._p.BP_JigMultiplayer._n.DA_GasCan == 1, "10b: no change")

    print("10c. the host refuels a car the client drives: the host's gas can, the host's hold")
    deliver("VENTER", vstr(truck6), cl_pc)
    T = T + 0.2
    run_delayed()
    check(cl_ch._parent == truck6, "10c: the client drives")
    T = T + 1.5     -- past the entry's own player-0 window (SCOPE_S)
    V.tick()
    host_ch._p.BP_JigMultiplayer._n.DA_GasCan = 1
    truck6._enter_box(host_ch)
    truck6:OnExecuteInteract(host_ch, R.GAS)
    check(truck6._p.IsHeld == true and truck6._hold == host_ch, "10c: hold started with the host's inventory")
    T = T + 10
    V.tick()
    truck6._hold_end()
    check(truck6._gas_by == host_ch, "10c: UseGasCan used the host (not the driving client)")
    check(host_ch._p.BP_JigMultiplayer._n.DA_GasCan == 0 and cl_ch._p.BP_JigMultiplayer._n.DA_GasCan == 1,
        "10c: the host's gas can, not the driver's")
    check(fc6._p.CurrentFuel == 1000, "10c: fuel added on the host")

    print("10d. another player leaves the fuel box: this player's option and hold come back")
    fc6._p.CurrentFuel = 200
    host_ch._p.BP_JigMultiplayer._n.DA_GasCan = 1
    truck6._leave_box(host_ch)
    truck6._enter_box(cl2_ch)
    truck6._enter_box(host_ch)
    truck6:OnExecuteInteract(host_ch, R.GAS)
    check(truck6._p.IsHeld == true, "10d: hold running")
    T = T + 3
    truck6._leave_box(cl2_ch)
    check(truck6._p.IsHeld == true, "10d: the hold given back after the other player left the box")
    check(truck6._p["InRefuellingArea?"] == true and truck6._p.InteractOptions[R.GAS] == true,
        "10d: Refuel Vehicle offered to this player again")
    local tw = host_hud._p.InteractTimerWidget
    check(tw ~= nil and tw._p.MaxTime == 10, "10d: the timer bar back on the host's screen")
    T = T + 7
    truck6._hold_end()
    check(fc6._p.CurrentFuel == 700, "10d: the refuel completed")

    print("10e. tank full / no gas can: the game's hold flag does not swallow the next press")
    fc6._p.CurrentFuel = 1000
    truck6:OnExecuteInteract(host_ch, R.GAS)
    check(truck6._said == "Gas full" and truck6._p.IsHeld == false, "10e: full: the hold flag cleared")
    fc6._p.CurrentFuel = 300
    host_ch._p.BP_JigMultiplayer._n.DA_GasCan = 0
    truck6:OnExecuteInteract(host_ch, R.GAS)
    check(truck6._p.IsHeld == false, "10e: no gas can: the hold flag cleared")

    print("10f. this player leaves the box: its hold stops (the game's rule)")
    host_ch._p.BP_JigMultiplayer._n.DA_GasCan = 1
    truck6:OnExecuteInteract(host_ch, R.GAS)
    check(truck6._p.IsHeld == true, "10f: hold running")
    truck6._leave_box(host_ch)
    check(truck6._p.IsHeld == false, "10f: own leaving stops it")
    T = T + 11
    truck6._hold_end()
    check(fc6._p.CurrentFuel == 300, "10f: no refuel after leaving")

    print("10g. the host marked in a vehicle while in none: the game's exit path after 2 s")
    host_ch._p["InVehicle?"] = true
    V.tick()
    check(host_ch._p["InVehicle?"] == true, "10g: not at once")
    T = T + 2.5
    V.tick()
    check(host_ch._p["InVehicle?"] == false, "10g: InVehicle? cleared")

    print("10h. a client's repair: added, its repair kit taken here")
    truck6._p.VehicleHealthComponent._p.CurrentHealth = 20
    cl2_ch._p.BP_JigMultiplayer._n.DA_VehicleRepairKit = 1
    deliver("VREPAIR", with(vstr(truck6), "60.0", "50.0"), cl2_pc)
    check(truck6._p.VehicleHealthComponent._p.CurrentHealth == 70, "10h: +50 on the host's value")
    check(cl2_ch._p.BP_JigMultiplayer._n.DA_VehicleRepairKit == 0, "10h: the repair kit taken from its inventory on the host")

    print("10i. a client's refuel with no gas can in its inventory here: no fuel, its copy set back")
    fc6._p.CurrentFuel = 300
    cl_ch._p.BP_JigMultiplayer._n.DA_GasCan = 0
    local add0 = fc6._addfuel or 0
    sent = {}
    deliver("VFUEL", with(vstr(truck6), "800.0", "500.0"), cl_pc)
    check(fc6._p.CurrentFuel == 300 and (fc6._addfuel or 0) == add0, "10i: no gas can here: nothing added")
    T = T + 0.5
    V.tick()
    local vsi = last_sent("VSTATE", cl_pc)
    check(vsi ~= nil and tonumber(vsi.args[6]) == 300, "10i: the client's copy gets the host's fuel back")
    cl_ch._p.BP_JigMultiplayer._n.DA_GasCan = 1
    deliver("VFUEL", with(vstr(truck6), "800.0", "500.0"), cl_pc)
    check(fc6._p.CurrentFuel == 800 and cl_ch._p.BP_JigMultiplayer._n.DA_GasCan == 0,
        "10i: with the game's DA_GasCan object in its inventory: taken first, then added")

    print("10j. a client's repair with no repair kit here: no repair, its copy set back")
    truck6._p.VehicleHealthComponent._p.CurrentHealth = 30
    cl2_ch._p.BP_JigMultiplayer._n.DA_VehicleRepairKit = 0
    sent = {}
    deliver("VREPAIR", with(vstr(truck6), "80.0", "50.0"), cl2_pc)
    check(truck6._p.VehicleHealthComponent._p.CurrentHealth == 30, "10j: no repair kit here: nothing added")
    T = T + 0.5
    V.tick()
    local vsj = last_sent("VSTATE", cl2_pc)
    check(vsj ~= nil and tonumber(vsj.args[7]) == 30, "10j: the client's copy gets the host's health back")

    deliver("VEXIT", with(vstr(truck6), "d", "1.0", "driver"), cl_pc)
    T = T + 1
    V.tick()
    truck6._valid = false
end

-- ------------------------------------------------------------ 11. vehicle trader purchases (0.6.53)
-- The game: VehicleVendorButton click @230-876, BP_VehicleTraderSpawner.SpawnVehicle,
-- the Jig money functions (CheckIfHasEnoughMoney / TakeMoney / CLIENT_UpdateCounts).
R.F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
R.F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
R.F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
R.F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
R.F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
R.F_UC_UID = "UID_2_DC6DBB72457305316FAC19A4399A1CB5"
R.F_UC_NEW = "NewCount_5_31E28E124BF695AFBB001A87164F9121"
R.SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
R.TRUCK_PATH = "/Game/Blueprints/Vehicles/Types/PickupTruck/Vehicle_PickupTruck.Vehicle_PickupTruck_C"
truck_cls._full = "BlueprintGeneratedClass " .. R.TRUCK_PATH
R.money_da = new_obj("JigsawItem_DataAsset_C", "DA_Money", {}, {})
rawset(by_path, "/Game/Inventory/Items/DataAssets/Currency/DA_Money.DA_Money", R.money_da)
rawset(by_path, "/Script/CoreUObject.Object", new_obj("Class", "Object", {}, {}))
rawset(by_path, "/Game/Blueprints/Vehicles/Spawner/DT_VehicleInfo.DT_VehicleInfo", new_obj("DataTable", "DT_VehicleInfo", {}, {
    FindRow = function(_, row)
        if row ~= "Trader" then return nil end
        return { ["Vehicles_14_6F62AF3348A4068731BE22ACF609D1D5"] = tarray({
            { ["Vehicles_11_54A68FE74C492D4E1322A1A28870318A"] = truck_cls, ["Price_10_6F62AF3348A4068731BE22ACF609D1D5"] = 5000.0 } }) }
    end }))

-- a character's money (stacks of DA_Money in MainJigContainers) and the game's functions on it
function R.wallet(ch, stacks)
    local jig = ch._p.BP_JigMultiplayer
    local items = {}
    for _, st in ipairs(stacks) do
        items[#items + 1] = { [R.F_USID] = st.uid, [R.F_INFO] = { [R.F_ITEMID] = R.money_da, [R.F_COUNT] = st.n } }
    end
    jig._items, jig._updates = items, nil
    jig._p.MainJigContainers = tarray({ { [R.F_ITEMS] = tarray(items) } })
    jig._m.CheckIfHasEnoughMoney = function(j, price) return R.total(ch) >= price end
    jig._m.TakeMoney = function(j, price, _, out)
        if R.total(ch) < price then return false end
        local left, i = price, 1
        while left > 0 and i <= #j._items do
            local info = j._items[i][R.F_INFO]
            if info[R.F_COUNT] <= left then
                left = left - info[R.F_COUNT]
                table.remove(j._items, i)
            else
                info[R.F_COUNT] = info[R.F_COUNT] - left
                left = 0
                i = i + 1
            end
        end
        j._taken = (j._taken or 0) + price
        return true
    end
    jig._m.CLIENT_UpdateCounts = function(j, list) j._updates = list end
end
function R.total(ch)
    local t = 0
    for _, it in ipairs(ch._p.BP_JigMultiplayer._items or {}) do t = t + it[R.F_INFO][R.F_COUNT] end
    return t
end
function R.count_vehicles() return #FindAllOf("BP_VehicleMaster_C") end

R.spawner = new_obj("BP_VehicleTraderSpawner_C", "BP_VehicleTraderSpawner_C_7", { __loc = { X = 12000, Y = 0, Z = 80 }, Role = 3 }, {})
R.spawner._m.SpawnVehicle = function(self, cls)
    local cp = param(cls)
    local h = hooks[R.SPAWN_FN]
    if h and h.pre then h.pre(param(gps), param(self), cp) end
    if cp:get() == cls then
        R.n_spawn = (R.n_spawn or 0) + 1
        R.last_spawned = new_vehicle("Vehicle_PickupTruck_C_" .. tostring(2147400000 + R.n_spawn), { X = 12000, Y = 0, Z = 80 })
    end
    local hp = hooks["/Game/Inventory/Traders/Traders/BP_VehicleTraderSpawner.BP_VehicleTraderSpawner_C:SpawnVehicle"]
    if hp and hp.pre then hp.pre(param(self), param(cls)) end
end
-- VehicleVendorButton click on this machine (@230-876)
function R.click(b)
    local price = tonumber((b._p.Price:gsub("[^%d]", "")))
    local pawn = controllers[1]._p.Pawn                    -- GetPlayerPawn(0)
    local jig = pawn._p.BP_JigMultiplayer
    if not jig:CheckIfHasEnoughMoney(price, R.money_da) then R.said = "Not enough money"; return end
    jig:TakeMoney(price, R.money_da, {})
    jig:CLIENT_UpdateCounts({}, {})
    R.spawner:SpawnVehicle(b._p.Vehicle)
end

print("11. host: a client's vehicle purchase")
do
    T = T + 2
    V.tick()
    check(hooks[R.SPAWN_FN] ~= nil, "11: trader spawn hook on the shared engine hook")
    cl_ch._p.__loc = { X = 11800, Y = 300, Z = 100 }
    R.wallet(cl_ch, { { uid = { A = 1, B = 1, C = 1, D = 1 }, n = 3000 }, { uid = { A = 2, B = 2, C = 2, D = 2 }, n = 4000 } })
    local n0 = R.count_vehicles()
    sent = {}
    deliver("VBUY", { R.TRUCK_PATH, "12000", "0", "80", "5000", "a1b2.1" }, cl_pc)
    check(R.total(cl_ch) == 2000, "11a: 5000 taken from the client's money on the host (7000 -> 2000)")
    local up = cl_ch._p.BP_JigMultiplayer._updates
    local okup = up ~= nil and #up == 2 and up[1][R.F_UC_NEW] == 0 and up[2][R.F_UC_NEW] == 2000
        and up[1][R.F_UC_UID].A == 1 and up[2][R.F_UC_UID].A == 2
    check(okup, "11a: CLIENT_UpdateCounts to the client: stack 1 -> 0, stack 2 -> 2000")
    check(R.count_vehicles() == n0 + 1 and R.last_spawned ~= nil, "11a: one vehicle spawned on the host (the game's SpawnVehicle)")
    local r = last_sent("VBUYR", cl_pc)
    check(r ~= nil and r.args[2] == "ok" and r.args[3] == R.last_spawned._short and r.args[4] == "5000" and r.args[5] == "2000",
        "11a: VBUYR ok to the client (vehicle, price, money left)")
    T = T + 0.5
    V.tick()
    local vsn = last_sent("VSTATE", cl_pc)
    check(vsn ~= nil and vsn.args[1] == "12000", "11a: the new vehicle's state goes to the clients")

    print("11b. the same purchase message again: no second charge, no second car")
    deliver("VBUY", { R.TRUCK_PATH, "12000", "0", "80", "5000", "a1b2.1" }, cl_pc)
    check(R.total(cl_ch) == 2000 and R.count_vehicles() == n0 + 1, "11b: ignored")

    print("11c. not enough money on the host: refused, the client gets the host's numbers")
    sent = {}
    cl_ch._p.BP_JigMultiplayer._updates = nil
    deliver("VBUY", { R.TRUCK_PATH, "12000", "0", "80", "5000", "a1b2.2" }, cl_pc)
    r = last_sent("VBUYR", cl_pc)
    check(r ~= nil and r.args[2] == "no" and r.args[3] == "money" and r.args[4] == "2000" and r.args[5] == "5000",
        "11c: VBUYR no money (2000 of 5000)")
    up = cl_ch._p.BP_JigMultiplayer._updates
    check(up ~= nil and #up == 1 and up[1][R.F_UC_NEW] == 2000, "11c: its money shown from the host again (CLIENT_UpdateCounts)")
    check(R.total(cl_ch) == 2000 and R.count_vehicles() == n0 + 1, "11c: nothing taken, no car")

    print("11d. the client's game restarted (new token): purchase #1 again is a new one; the table's price wins")
    R.wallet(cl_ch, { { uid = { A = 3, B = 3, C = 3, D = 3 }, n = 9000 } })
    deliver("VBUY", { R.TRUCK_PATH, "12000", "0", "80", "4000", "c3d4.1" }, cl_pc)
    check(R.total(cl_ch) == 4000 and R.count_vehicles() == n0 + 2, "11d: charged 5000 (DT_VehicleInfo), car spawned")

    print("11e. the host's own purchase: the game's, only logged")
    local n1 = R.count_vehicles()
    R.spawner:SpawnVehicle(truck_cls)
    check(R.count_vehicles() == n1 + 1 and last_sent("VBUY") == nil, "11e: the host's car, no message")
end

-- ------------------------------------------------------------ 12. two seats, three players (0.7.3)
-- The game has one seat (the driver's); the mod adds one passenger seat. A
-- third player gets no seat - the host neither: up to 0.7.3 the host's
-- get-in into a car a client drove with another client beside it put the
-- host into that client's passenger seat (two characters in one seat).
print("12. two seats, three players")
do
    local Q = { CHAR_HOOK = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:VehicleInteraction", vi = {} }
    -- the game's VehicleInteraction ends with the mod's post hook (the
    -- harness above calls the body only)
    for _, c in ipairs({ host_ch, cl_ch, cl2_ch }) do
        local body = c._m.VehicleInteraction
        Q.vi[c] = body
        c._m.VehicleInteraction = function(s, enter, vref)
            s._vi_calls = s._vi_calls or {}
            s._vi_calls[#s._vi_calls + 1] = enter
            body(s, enter, vref)
            local h = hooks[Q.CHAR_HOOK]
            if h and h.pre then h.pre(param(s), param(enter), param(vref)) end
        end
    end
    Q.cam = host_ch._m.ResetVehicleCameraArmLength
    host_ch._m.ResetVehicleCameraArmLength = function(s) s._cams = (s._cams or 0) + 1 end
    -- Event_ExitVehicle places player 0 at the door socket (@24714)
    function Q.vehicle(name, loc)
        local v = new_vehicle(name, loc)
        local body = v._m.Event_ExitVehicle
        v._m.Event_ExitVehicle = function(self)
            body(self)
            local sock = self._p.Mesh:GetSocketLocation(FName(self._p.GetOutPasseenger and "PassengerSide" or "DriverSide"))
            self._exited_by:K2_SetActorLocationAndRotation(sock, {})
            self._p.GetOutPasseenger = false
        end
        -- the get-in lets the handbrake go for its driver (@7820)
        local get_in = v._m.Interact_GetInVehicle
        v._m.Interact_GetInVehicle = function(self)
            self._p.VehicleMovementComponent:SetHandbrakeInput(false)
            get_in(self)
        end
        -- UAudioComponent: a FadeOut keeps the component active (IsActive)
        -- until the sound has faded, GetPlayState() = FadingOut (4) meanwhile;
        -- Activate(true) restarts it
        local snd = v._p.EngineSound
        snd._m.FadeOut = function(s) if s._p.active then s._p.fading = true end end
        snd._m.Activate = function(s) s._p.active = true; s._p.fading = false; s._p.starts = (s._p.starts or 0) + 1 end
        snd._m.GetPlayState = function(s) if not s._p.active then return 1 elseif s._p.fading then return 4 end return 0 end
        return v
    end
    function Q.sound_on(v)
        local s = v._p.EngineSound._p
        return s.active == true and s.fading ~= true
    end
    -- KismetSystemLibrary.CapsuleTraceSingle at a door socket (the game's
    -- CheckCanExitCar*Side): blocked by a "wall" within the capsule there
    Q.walls, Q.traces = {}, {}
    ksl._m.CapsuleTraceSingle = function(_, wc, s, e, r, hh, chan, cx, ignore)
        Q.traces[#Q.traces + 1] = { wc = wc, at = s, r = r, half = hh, ignore = ignore }
        for _, w in ipairs(Q.walls) do
            if math.abs(w.X - s.X) <= r and math.abs(w.Y - s.Y) <= r then return true end
        end
        return false
    end
    -- the game's death in a vehicle on this machine (@13645..13863): its
    -- VehicleDrivingComponent.Death stops the car (@9291..9811), the body stays
    -- attached; AfterDeath's UnPossess (@1387) leaves the controller without it
    function Q.die_in(ch, v, pc)
        ch._p["PlayerDead?"] = true
        v._p.EngineSound:FadeOut(2.5, 0, 0)
        for _, fn in ipairs({ "CheckWater", "VehicleSound", "Event_Noise" }) do timers[tkey(v, fn)] = nil end
        v._p.VehicleMovementComponent:SetHandbrakeInput(true)
        v._p.FuelComponent:StopSpendFuel()
        ch._p.VehicleDrivingComponent._p.Vehicle = nil
        pc._p.Pawn = nil
    end
    function Q.free_all(at)
        for i, c in ipairs({ host_ch, cl_ch, cl2_ch }) do
            c._parent = nil; c._montage = nil; c._p["InVehicle?"] = false; c._p.VehicleDrivingComponent._p.Vehicle = nil
            c._p.CharacterMovement._p.MovementMode = 1
            c._p.__loc = { X = at.X - 60 + 40 * i, Y = (i % 2 == 0) and 160 or -160, Z = 100 }
        end
    end
    -- the host's interact key on the car (TryInteract sets the target first)
    function Q.host_press(v)
        host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = v
        v:Interact_GetInVehicle()
        host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    end
    function Q.at_seat(ch, v, passenger)
        local l, vl = ch._p.__loc, v._p.__loc
        return ch._parent == v and math.abs(l.Y - (vl.Y + (passenger and 40 or -40))) < 1
    end
    function Q.toast(pat)
        for i = Q.t0 + 1, #toasts do if toasts[i]:find(pat, 1, true) then return true end end
        return false
    end
    function Q.timer(o, fn) return timers[tkey(o, fn)] == true end

    local tk = Q.vehicle("Vehicle_Sheriff_C_2147471200", { X = 20000, Y = 0, Z = 80 })
    local st = nil
    Q.free_all({ X = 20000 })
    T = T + 5
    V.tick()

    print("12a. a client drives, another sits next to it, the host presses get-in: no seat")
    deliver("VENTER", vstr(tk), cl_pc)
    T = T + 0.1
    run_delayed()
    deliver("VENTER", vstr(tk), cl2_pc)
    T = T + 2
    V.tick()
    st = V._t.vs()[tk._addr]
    check(st.driver_key == r1.key and st.pax[2] == r2.key and Q.at_seat(cl_ch, tk, false) and Q.at_seat(cl2_ch, tk, true),
        "12a: Friend drives, Friend2 sits as the passenger")
    local mc = tk._p.VehicleMovementComponent
    local hb0, vp0 = mc._p.hb, #host_vp
    check(hb0 == false and Q.sound_on(tk), "12a: the driver's get-in let the handbrake go and runs the engine sound (as the game, @7820 / @8941)")
    Q.t0 = #toasts
    local rej0, stray0, cams0, stops0 = V.stats.rejected, V.stats.stray_vi, host_ch._cams or 0, host_ch._stop_everywhere or 0
    local starts0 = tk._p.EngineSound._p.starts or 0
    host_ch._vi_calls = {}
    sent = {}
    Q.traces = {}
    Q.host_press(tk)
    check(#host_ch._vi_calls == 1 and host_ch._vi_calls[1] == false,
        "12a: the character's own exit path ran on the host (VehicleInteraction(false), as after the game's exit)")
    check(tk._entered_by == host_ch, "12a: the game's get-in ran for the host")
    check(tk._exited_by == host_ch and host_ch._parent == nil, "12a: the game's exit took the HOST out (not the driver)")
    check(math.abs(host_ch._p.__loc.Y - (-200)) < 1, "12a: the host stands at the door, not in a seat")
    check(#Q.traces >= 1 and Q.traces[1].wc == tk and math.abs(Q.traces[1].at.Y - (-200)) < 1 and Q.traces[1].r == 30
        and Q.traces[1].half == 50 and Q.traces[1].ignore[1] == host_ch,
        "12a: the door was checked as the game's exit does (capsule 30/50 at the driver door, the host ignored)")
    check(tk._p.GetOutPasseenger == false, "12a: the car's exit-side flag is back to the driver side")
    check(not Q.at_seat(host_ch, tk, true) and Q.at_seat(cl2_ch, tk, true), "12a: the passenger seat is still Friend2's alone")
    check(host_ch._montage == nil and (host_ch._stop_everywhere or 0) == stops0 + 1, "12a: the host's sit pose ended here and on the clients")
    check(host_ch._p.CharacterMovement._p.MovementMode == 1, "12a: the host walks (movement on)")
    check(host_ch._p["InVehicle?"] == false and host_ch._p.VehicleDrivingComponent._p.Vehicle == nil, "12a: no driving state on the host")
    check((host_ch._cams or 0) > cams0, "12a: the host's camera back from the car")
    check(#host_vp == vp0 and tk._p.VehicleUI == nil, "12a: the vehicle panel the get-in made is gone from the host's screen")
    check(Q.toast("В машине нет свободного места."), "12a: the host told (the game's notice): no free seat")
    check(V.stats.rejected == rej0 + 1, "12a: counted as a refusal")
    check(last_sent("VSEAT") == nil, "12a: the clients' seats unchanged (no seat message)")
    check(st.driver_key == r1.key and st.pax[2] == r2.key and st.host_seat == nil, "12a: seat records: Friend driver, Friend2 passenger, host none")
    check(Q.at_seat(cl_ch, tk, false) and cl_ch._p["InVehicle?"] == true and cl_ch._p.VehicleDrivingComponent._p.Vehicle == tk,
        "12a: the driver still sits at the wheel with the game's driving state")
    check(tk._owner == cl_pc and mc._p.bRequiresControllerForInputs == true, "12a: owner / replicated inputs of the driver unchanged")
    check(mc._p.hb == false, "12a: the driver's handbrake stays off (the car counts as occupied: no handbrake on)")
    check(Q.timer(tk, "VehicleSound") and Q.timer(tk, "CheckWater") and Q.timer(tk, "Event_Noise")
        and Q.timer(tk._p.FuelComponent, "FuelSpend"), "12a: the driver's timers and fuel keep running")
    check(Q.sound_on(tk) and (tk._p.EngineSound._p.starts or 0) > starts0,
        "12a: the driver's engine sound did not fade out with the game's exit (started again at once)")
    check(tk._resp[2] == 0 and tk._resp[4] == 0, "12a: the car still ignores its seated players (collision)")
    T = T + 0.1
    run_delayed()
    check(tk._vi_by == host_ch, "12a: the get-in's delayed step reached the host")
    check(host_ch._p["InVehicle?"] == false and host_ch._p.VehicleDrivingComponent._p.Vehicle == nil
        and host_ch._p.CharacterMovement._p.MovementMode == 1 and host_ch._weapons_hidden == false,
        "12a: and was undone at once: no driving state, walking, weapons back")
    check(V.stats.stray_vi == stray0, "12a: an expected step, not counted as a stray one")
    T = T + 2
    V.tick()
    check(player0(tk) == cl_ch, "12a: the car's player 0 is its driver again")
    st.dirty = true
    sent = {}
    V.tick()
    local vsa = last_sent("VSTATE", cl_pc)
    check(vsa and vsa.args[11] == tostring(cl_ch._pid) and vsa.args[12] == tostring(cl2_ch._pid),
        "12a: VSTATE: Friend drives, Friend2 is the passenger")
    -- the car stands with its driver door at a wall: out at the passenger door
    Q.walls = { { X = 20000, Y = -200 } }
    Q.host_press(tk)
    check(math.abs(host_ch._p.__loc.Y - 200) < 1 and tk._p.GetOutPasseenger == false,
        "12a: driver door at a wall: the host steps out at the passenger door (flag reset after)")
    T = T + 0.1
    run_delayed()
    check(host_ch._parent == nil and V.stats.rejected == rej0 + 2 and Q.at_seat(cl2_ch, tk, true), "12a: a second press: refused again")
    -- both doors blocked: the driver door (the game would keep the player seated)
    Q.walls = { { X = 20000, Y = -200 }, { X = 20000, Y = 200 } }
    Q.host_press(tk)
    check(host_ch._parent == nil and math.abs(host_ch._p.__loc.Y - (-200)) < 1, "12a: both doors blocked: out at the driver door all the same")
    Q.walls = {}
    T = T + 0.1
    run_delayed()
    T = T + 2
    V.tick()

    print("12b. the passenger leaves: the host gets that seat; then a client asks: full")
    deliver("VEXIT", with(vstr(tk), "p", "5.0", "passenger"), cl2_pc)
    check(cl2_ch._parent == nil and st.pax[2] == nil, "12b: Friend2 out, its seat free")
    Q.host_press(tk)
    T = T + 0.1
    run_delayed()
    check(Q.at_seat(host_ch, tk, true) and st.host_seat == "passenger", "12b: the host sits in the free passenger seat")
    check(host_ch._p.VehicleDrivingComponent._p.Vehicle == tk, "12b: with the game's driving state (its exit key works)")
    T = T + 2
    V.tick()
    sent = {}
    deliver("VENTER", vstr(tk), cl2_pc)
    local s12 = last_sent("VSEAT", cl2_pc)
    check(s12 and s12.args[1] == "none" and s12.args[2] == "full", "12b: Friend2 refused: full")
    check(cl2_ch._parent == nil and Q.at_seat(host_ch, tk, true) and Q.at_seat(cl_ch, tk, false), "12b: nobody moved")

    print("12c. the driver leaves: the host takes the wheel with its key; a client sits beside it; a third: full")
    deliver("VEXIT", with(vstr(tk), "d", "9.0", "driver"), cl_pc)
    check(cl_ch._parent == nil and Q.at_seat(host_ch, tk, true) and st.host_seat == "passenger", "12c: the driver out: the host stays in its seat")
    host_key()
    check(Q.at_seat(host_ch, tk, false) and st.host_seat == "driver", "12c: the host's seat key: the wheel")
    T = T + 2
    V.tick()
    deliver("VENTER", vstr(tk), cl2_pc)
    s12 = last_sent("VSEAT", cl2_pc)
    check(s12 and s12.args[1] == "passenger" and Q.at_seat(cl2_ch, tk, true), "12c: Friend2 sits as the passenger")
    T = T + 0.1
    run_delayed()
    sent = {}
    deliver("VENTER", vstr(tk), cl_pc)
    s12 = last_sent("VSEAT", cl_pc)
    check(s12 and s12.args[1] == "none" and s12.args[2] == "full", "12c: Friend refused: full")
    check(cl_ch._parent == nil and Q.at_seat(host_ch, tk, false) and Q.at_seat(cl2_ch, tk, true) and tk._owner == nil,
        "12c: the host keeps the wheel, Friend2 the passenger seat")

    print("12d. seats freed: the passenger dies, the next one disconnects")
    cl2_ch._p["PlayerDead?"] = true
    T = T + 1
    V.tick()
    check(st.pax[2] == nil and cl2_ch._parent == nil, "12d: the dead passenger's seat is free")
    cl2_ch._p["PlayerDead?"] = false
    deliver("VENTER", vstr(tk), cl_pc)
    s12 = last_sent("VSEAT", cl_pc)
    check(s12 and s12.args[1] == "passenger" and Q.at_seat(cl_ch, tk, true), "12d: Friend takes the freed seat")
    T = T + 1
    V.tick()
    cl_pc._p.NetConnection = nil      -- Friend disconnects (the engine destroys its character)
    cl_ch._parent = nil
    T = T + 1
    V.tick()
    check(st.pax[2] == nil and V.seat_of(r1.key) == nil, "12d: the disconnected passenger's seat is free")
    cl_pc._p.NetConnection = conn
    cl2_ch._p.__loc = { X = 20050, Y = 160, Z = 100 }
    sent = {}
    deliver("VENTER", vstr(tk), cl2_pc)
    s12 = last_sent("VSEAT", cl2_pc)
    check(s12 and s12.args[1] == "passenger" and Q.at_seat(cl2_ch, tk, true), "12d: Friend2 takes it")
    deliver("VEXIT", with(vstr(tk), "p"), cl2_pc)
    tk:ExitVehicle()
    T = T + 2
    V.tick()
    check(host_ch._parent == nil and next(V._t.seats()) == nil, "12d: everyone out")

    print("12e. the driver disconnects; another client gets in before the tick noticed")
    local tk2 = Q.vehicle("Vehicle_Van_C_2147471300", { X = 24000, Y = 0, Z = 80 })
    Q.free_all({ X = 24000 })
    T = T + 2
    V.tick()
    deliver("VENTER", vstr(tk2), cl_pc)
    T = T + 0.1
    run_delayed()
    T = T + 2
    V.tick()
    Q.host_press(tk2)
    T = T + 0.1
    run_delayed()
    T = T + 2
    V.tick()
    local st2 = V._t.vs()[tk2._addr]
    check(Q.at_seat(cl_ch, tk2, false) and Q.at_seat(host_ch, tk2, true), "12e: Friend drives, the host rides along")
    cl_pc._p.NetConnection = nil      -- Friend's connection is gone; the tick has not run yet
    cl_ch._parent = nil
    sent = {}
    deliver("VENTER", vstr(tk2), cl2_pc)
    s12 = last_sent("VSEAT", cl2_pc)
    check(s12 and s12.args[1] == "driver" and Q.at_seat(cl2_ch, tk2, false), "12e: Friend2 takes the free wheel")
    T = T + 0.1
    run_delayed()
    T = T + 0.5
    V.tick()
    check(V.seat_of(r1.key) == nil, "12e: the tick ended the gone driver's seat")
    check(st2.driver_key == r2.key and tk2._owner == cl2_pc and tk2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true,
        "12e: the new driver keeps the car (owner, replicated inputs)")
    check(Q.at_seat(host_ch, tk2, true) and st2.host_seat == "passenger" and Q.at_seat(cl2_ch, tk2, false),
        "12e: the host stays in the passenger seat (not moved onto the new driver)")
    check(Q.sound_on(tk2) and Q.timer(tk2, "CheckWater"), "12e: the new driver's engine keeps running")
    cl_pc._p.NetConnection = conn
    T = T + 1
    V.tick()
    -- the host gets out while Friend2 drives on: the game's exit faded the
    -- car's engine sound out (Event_ExitVehicle @23409)
    local starts_e = tk2._p.EngineSound._p.starts or 0
    tk2:ExitVehicle()
    check(host_ch._parent == nil and st2.host_seat == nil and Q.at_seat(cl2_ch, tk2, false) and st2.driver_key == r2.key,
        "12e: the host got out as the passenger, Friend2 still drives")
    check(Q.sound_on(tk2) and (tk2._p.EngineSound._p.starts or 0) > starts_e and Q.timer(tk2, "VehicleSound"),
        "12e: the driver's engine sound did not fade out with the host's exit (started again at once)")
    deliver("VEXIT", with(vstr(tk2), "d"), cl2_pc)
    T = T + 2
    V.tick()
    check(host_ch._parent == nil and cl2_ch._parent == nil and next(V._t.seats()) == nil, "12e: everyone out")

    print("12f. the host dies at the wheel, a client beside it: the client stays; its seat key: the wheel")
    local tk3 = Q.vehicle("Vehicle_Pickup_C_2147471400", { X = 28000, Y = 0, Z = 80 })
    Q.free_all({ X = 28000 })
    T = T + 2
    V.tick()
    Q.host_press(tk3)
    T = T + 0.1
    run_delayed()
    T = T + 2
    V.tick()
    local st3 = V._t.vs()[tk3._addr]
    deliver("VENTER", vstr(tk3), cl2_pc)
    T = T + 0.1
    run_delayed()
    T = T + 2
    V.tick()
    check(Q.at_seat(host_ch, tk3, false) and st3.host_seat == "driver" and Q.at_seat(cl2_ch, tk3, true) and st3.pax[2] == r2.key,
        "12f: the host drives, Friend2 sits beside it")
    Q.die_in(host_ch, tk3, host_pc)
    sent = {}
    T = T + 1
    V.tick()
    check(st3.host_seat == nil, "12f: the dead host holds no seat")
    check(st3.driver_key == nil and Q.at_seat(cl2_ch, tk3, true) and last_sent("VSEAT", cl2_pc) == nil, "12f: Friend2 stays in its seat")
    deliver("VSWITCH", vstr(tk3), cl2_pc)
    s12 = last_sent("VSEAT", cl2_pc)
    check(st3.driver_key == r2.key and st3.pax[2] == nil and s12 and s12.args[1] == "driver" and Q.at_seat(cl2_ch, tk3, false)
        and tk3._entered_by == cl2_ch, "12f: Friend2's key: the wheel through the game's get-in")
    check(tk3._owner == cl2_pc and tk3._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true,
        "12f: the car is Friend2's now (owner, replicated inputs)")
    T = T + 0.1
    run_delayed()
    check(cl2_ch._p.VehicleDrivingComponent._p.Vehicle == tk3 and Q.sound_on(tk3) and tk3._p.VehicleMovementComponent._p.hb == false,
        "12f: Friend2 has the game's driving state, engine sound on, handbrake off")
    T = T + 1
    V.tick()
    check(st3.driver_key == r2.key and st3.host_seat == nil and Q.at_seat(cl2_ch, tk3, false), "12f: and it stays so on the next tick")
    -- the host respawns (the game destroys the body, a new character; here the same one)
    host_pc._p.Pawn = host_ch
    host_ch._p["PlayerDead?"] = false
    host_ch._parent = nil
    host_ch._p.__loc = { X = 28000, Y = -300, Z = 100 }

    print("12g. the host dies as the passenger of a client: the client drives on")
    T = T + 2
    V.tick()
    Q.host_press(tk3)
    T = T + 0.1
    run_delayed()
    T = T + 2
    V.tick()
    check(Q.at_seat(host_ch, tk3, true) and st3.host_seat == "passenger" and st3.driver_key == r2.key, "12g: Friend2 drives, the host rides along")
    Q.die_in(host_ch, tk3, host_pc)
    sent = {}
    T = T + 1
    V.tick()
    check(st3.host_seat == nil and st3.driver_key == r2.key and Q.at_seat(cl2_ch, tk3, false) and last_sent("VSEAT", cl2_pc) == nil,
        "12g: the dead host holds no seat; Friend2 keeps the wheel (no seat change)")
    check(Q.sound_on(tk3) and Q.timer(tk3, "VehicleSound") and Q.timer(tk3, "CheckWater") and Q.timer(tk3._p.FuelComponent, "FuelSpend"),
        "12g: the driver's engine sound and timers are back at once after the death stopped them")
    host_pc._p.Pawn = host_ch
    host_ch._p["PlayerDead?"] = false
    host_ch._parent = nil
    deliver("VEXIT", with(vstr(tk3), "d"), cl2_pc)
    T = T + 2
    V.tick()
    check(host_ch._parent == nil and cl2_ch._parent == nil and next(V._t.seats()) == nil and st3.host_seat == nil, "12g: everyone out")

    -- back to the harness as it was
    for c, body in pairs(Q.vi) do c._m.VehicleInteraction = body end
    host_ch._m.ResetVehicleCameraArmLength = Q.cam
    ksl._m.CapsuleTraceSingle = nil
    for i = #toasts, Q.t0 + 1, -1 do toasts[i] = nil end
    tk._valid, tk2._valid, tk3._valid = false, false, false
    Q.free_all({ X = 20000 })
    T = T + 2
    V.tick()
end

-- ------------------------------------------------------------ 7. client side
print("7. client")
V.reset("test")
net_mode = "client"
S.role = "client"
S.client = { acked = true }
S.remote, S.remote_pcs = {}, {}
local me = cl_ch
me._local = true
host_ch._local = false
me._parent, host_ch._parent, cl2_ch._parent = nil, nil, nil
host_pc._p.Player = nil
cl_pc._p.Player = new_obj("LocalPlayer", "LP2", {}, {})
cl_pc._p.NetConnection = nil
host_pc._p.NetConnection = nil
controllers = { cl_pc }   -- a client has only its own controller: player 0 = me
ctx.reset()
local truck2 = new_vehicle("Vehicle_ModifiedPickupUtilityTruck_C_2147470009", { X = 5000, Y = 0, Z = 80 })
truck._p.Role, truck2._p.Role = 1, 1
local ghost = new_vehicle("Vehicle_PickupTruck_C_2147460000", { X = 7000, Y = 0, Z = 80 })
local spawner = new_obj("BP_VehicleSpawner_C", "BP_VehicleSpawner_C_12", { Role = 3, ["SpawnerUsed?"] = false }, {})
V.tick()
check(ghost._valid == false, "client-only ghost vehicle destroyed")
check(spawner._p["SpawnerUsed?"] == true, "local vehicle spawner switched off")
check(truck._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "observer copies use replicated inputs")

print("7a. VSTATE applied")
deliver("VCAP", { "1" }, cl_pc)
truck._p.FuelComponent._p.CurrentFuel = 5
deliver("VSTATE", { "1050", "0", "80", truck._cls, "2", "640.0", "8.0", "1", "1", "1" }, cl_pc)
check(truck._p.VehicleColor == 2 and truck._p.Mesh._p.mat ~= nil, "colour applied (material set)")
check(truck._p.FuelComponent._p.CurrentFuel == 640, "fuel from the host")
check(truck._p.VehicleHealthComponent._p.CurrentHealth == 8, "health from the host")
check((truck._fx or 0) >= 1, "engine FX re-evaluated across the threshold")
check(truck._p["LightsOn?"] == true, "lights switched on like the host's")
check(#truck._p.Colors._items == 3, "colour lookup did not grow the TArray")

print("7b. the host drives: the client shows it")
host_ch._parent = truck
V.tick()
check(truck._p.EngineSound._p.active == true, "engine sound for the host-driven vehicle")
check(timers[tkey(truck, "VehicleSound")] == true, "RPM timer running")
check(truck._resp[2] == 0 and truck._resp[4] == 0, "mesh ignores the seated characters")
check(host_ch._p["InVehicle?"] == true, "remote occupant: InVehicle? for the AnimBP")
check(host_ch._montage == montage, "remote occupant: sit montage")
check(host_ch._weapons_hidden == true, "remote occupant: weapons hidden")
host_ch._parent = nil
deliver("VSTATE", { "1050", "0", "80", truck._cls, "2", "640.0", "8.0", "1", "1", "0" }, cl_pc)
V.tick()
check(host_ch._p["InVehicle?"] == false and host_ch._montage == nil, "left: sit montage stopped, InVehicle? off")
check(host_ch._weapons_hidden == false, "left: weapons shown")
check(truck._p.EngineSound._p.active == false, "no driver: engine sound off")
check(truck._resp[2] == 2, "empty: mesh blocks pawns again")

print("7c. local enter / seat answers")
sent = {}
me._parent = truck2
truck2:Interact_GetInVehicle()   -- player 0 on the client = me (ctx inactive)
local ve = last_sent("VENTER", "host")
check(ve ~= nil and ve.args[4] == truck2._cls, "VENTER sent with the vehicle's class")
check(truck2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "pending: no local inputs yet")
deliver("VSEAT", { "driver", "" }, cl_pc)
check(truck2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false, "driver: local inputs, predicted")
V.tick()
check(truck2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false, "tick keeps the driver's own vehicle local")
truck2:TurnOnOffLights()
local vl = last_sent("VLIGHT", "host")
check(vl and vl.args[5] == "1", "own lights sent to the host")
deliver("VSTATE", { "5000", "0", "80", truck2._cls, "1", "300.0", "50.0", "0", "1", "1" }, cl_pc)
check(truck2._p["LightsOn?"] == true, "a VSTATE right after the own toggle does not undo it")
truck2:Horn()
check(last_sent("VHORN", "host") ~= nil, "own horn sent to the host")
-- refuel here (consumed on the server by the game)
truck2._p.FuelComponent._p.CurrentFuel = 800
V.tick()
local vf = last_sent("VFUEL", "host")
check(vf and tonumber(vf.args[5]) == 800, "local refuel sent to the host")
sent = {}
V.tick()
check(last_sent("VFUEL", "host") == nil, "sent once")

print("7d. local exit")
me._parent = nil
truck2:ExitVehicle()
local vx = last_sent("VEXIT", "host")
check(vx ~= nil, "VEXIT sent")
check(truck2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "observer again after the exit")

print("7e. rejected")
-- the car stands with its driver door at a wall (the game's door check, a
-- capsule at the socket: CheckCanExitCarDriverSide); Event_ExitVehicle
-- places player 0 at the door its GetOutPasseenger flag names
local e7 = { flags = {}, ign = nil, exit_body = truck2._m.Event_ExitVehicle }
ksl._m.CapsuleTraceSingle = function(_, wc, s, e, r, hh, chan, cx, ignore)
    e7.ign = ignore
    return wc == truck2 and math.abs(s.Y - (-200)) <= r
end
truck2._m.Event_ExitVehicle = function(self)
    e7.flags[#e7.flags + 1] = self._p.GetOutPasseenger == true
    e7.exit_body(self)
end
me._parent = truck2
truck2:Interact_GetInVehicle()
local stops7e = me._stop_everywhere or 0
deliver("VSEAT", { "none", "full" }, cl_pc)
check(me._parent == nil, "forced out by the host's answer")
check(me._p.CharacterMovement._p.MovementMode == 1, "walking again")
check((me._stop_everywhere or 0) == stops7e + 1 and me._montage == nil,
    "7e: the sit pose our get-in started on every machine is stopped there too (the game's replicated stop)")
check(e7.flags[1] == true and truck2._p.GetOutPasseenger == false and e7.ign and e7.ign[1] == me,
    "7e: driver door at a wall: out at the passenger door (the game's own door check, this player ignored; flag reset after)")
local found = false
for _, t in ipairs(toasts) do if t:find("места", 1, true) then found = true end end
check(found, "Russian toast shown")
-- the driver door free: out there, as before
ksl._m.CapsuleTraceSingle = function() return false end
me._parent = truck2
truck2:Interact_GetInVehicle()
deliver("VSEAT", { "none", "full" }, cl_pc)
check(me._parent == nil and e7.flags[2] == false, "7e: driver door free: out at the driver door")
ksl._m.CapsuleTraceSingle = nil
truck2._m.Event_ExitVehicle = e7.exit_body

print("7f. seated as a passenger: moved to the passenger seat here; a stuck seat is repaired")
me._parent = nil
truck2:Interact_GetInVehicle()
check(me._parent == truck2, "7f: own entry attached this player")
deliver("VSEAT", { "passenger", "Host" }, cl_pc)
check(math.abs(me._p.__loc.Y - 40) < 1, "7f: this player moved to the passenger seat of its copy")
check(truck2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == true, "7f: a passenger's keys do not drive")
me._p["InVehicle?"] = true
me._p.VehicleDrivingComponent._p.Vehicle = nil
truck2._p["InRefuellingArea?"] = true
T = T + 1; V.tick(); T = T + 1; V.tick()
check(me._p.VehicleDrivingComponent._p.Vehicle == truck2, "7f: own driving state repaired (the exit key works)")
deliver("VSEAT", { "driver", "" }, cl_pc)
check(math.abs(me._p.__loc.Y - (-40)) < 1, "7f: promoted: moved to the driver seat")
check(truck2._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false, "7f: promoted: drives")

print("7g. the host's seat from VSTATE when no attachment arrived; let go when it frees")
do
    me._parent = nil
    truck2:ExitVehicle()
    host_ch._parent = nil; host_ch._montage = nil; host_ch._p["InVehicle?"] = false
    host_ch._p.Mesh._p.vis = 2
    deliver("VSTATE", { "1050", "0", "80", truck._cls, "2", "640.0", "8.0", "1", "1", "1", tostring(host_ch._pid), "" }, cl_pc)
    V.tick()
    check(host_ch._parent == nil, "7g: not placed at once (the engine's attachment may still come)")
    T = T + 2
    V.tick()
    check(host_ch._parent == truck and math.abs(host_ch._p.__loc.Y - (-40)) < 1, "7g: the host placed at the wheel here")
    check(host_ch._welded ~= true, "7g: a copy placed here is not welded")
    T = T + 0.5
    V.tick()
    check(host_ch._montage == montage and host_ch._p["InVehicle?"] == true, "7g: the host sits here (montage, InVehicle?)")
    check(host_ch._p.Mesh._p.vis == 0, "7g: our interact trace passes the seated host")
    deliver("VSTATE", { "1050", "0", "80", truck._cls, "2", "640.0", "8.0", "1", "1", "0", "", "" }, cl_pc)
    T = T + 0.5
    V.tick()
    check(host_ch._parent == nil, "7g: let go when the host says the seat is free")
    T = T + 0.5
    V.tick()
    check(host_ch._montage == nil and host_ch._p["InVehicle?"] == false and host_ch._p.Mesh._p.vis == 2,
        "7g: standing again here, our trace blocked by it again")
end

print("7h. own entry: unwelded here; the exit reports the time in the seat")
truck2:Interact_GetInVehicle()
check(me._parent == truck2 and me._welded == false, "7h: own seat unwelded (moves keep reaching the host)")
deliver("VSEAT", { "driver", "" }, cl_pc)
T = T + 0.8
me._parent = nil
truck2:ExitVehicle()
local ve2 = last_sent("VEXIT", "host")
check(ve2 and ve2.args[6] == "0.8" and ve2.args[7] == "driver", "7h: VEXIT carries 0.8 s in the driver seat")

print("7i. interact diagnostics next to an occupied car")
host_ch._parent = truck
V.tick()
local th = hooks["/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C:TryInteract"]
check(th ~= nil, "7i: TryInteract hook registered")
me._p.__loc = { X = 1100, Y = 100, Z = 100 }
me._p.BP_JigHelperComp._p.InteractExecutedActor = nil
local n_before = #toasts
if th then th.pre(param(me._p.BP_JigHelperComp)) end
check(#toasts == n_before, "7i: diagnostics only log")
host_ch._parent = nil
T = T + 1
V.tick()

print("7j. client refuel: the game's flow here, the amount to the host at once")
local cl_hud = R.give_hud(cl_pc)
local truck7 = new_vehicle("Vehicle_PickupTruck_C_2147474000", { X = 9000, Y = 0, Z = 80 })
truck7._p.Role = 1
R.fuel_game(truck7)
do
    me._parent, host_ch._parent = nil, nil
    me._p["InVehicle?"], host_ch._p["InVehicle?"] = false, false
    me._p.__loc = { X = 9050, Y = 150, Z = 100 }
    T = T + 1
    V.tick()
    deliver("VSTATE", { "9000", "0", "80", truck7._cls, "0", "100.0", "50.0", "0", "1", "0", "", "" }, cl_pc)
    local fc7 = truck7._p.FuelComponent
    check(fc7._p.CurrentFuel == 100, "7j: fuel from the host")
    me._p.BP_JigMultiplayer._n.DA_GasCan = 1
    truck7._enter_box(host_ch)   -- the host's character at the box too (as this machine sees it)
    truck7._enter_box(me)
    sent = {}
    truck7:OnExecuteInteract(me, R.GAS)
    check(truck7._p.IsHeld == true and truck7._hold == me, "7j: hold started here")
    T = T + 4
    truck7._leave_box(host_ch)   -- the host walks off: the game clears the box for everyone here
    check(truck7._p.IsHeld == true and truck7._p.InteractOptions[R.GAS] == true, "7j: this player's hold and option given back")
    check(cl_hud._p.InteractTimerWidget ~= nil, "7j: the timer bar back")
    T = T + 6
    truck7._hold_end()
    check(me._p.BP_JigMultiplayer._n.DA_GasCan == 0 and fc7._p.CurrentFuel == 600, "7j: the game's UseGasCan ran here (+500, the can used here)")
    local vf7 = last_sent("VFUEL", "host")
    check(vf7 ~= nil and tonumber(vf7.args[5]) == 600 and tonumber(vf7.args[6]) == 500, "7j: VFUEL at once: 600 here, +500")
    deliver("VSTATE", { "9000", "0", "80", truck7._cls, "0", "100.0", "50.0", "0", "1", "0", "", "" }, cl_pc)
    check(fc7._p.CurrentFuel == 600, "7j: a host state older than the report does not undo the refuel")
    sent = {}
    V.tick()
    check(last_sent("VFUEL", "host") == nil, "7j: sent once")
    deliver("VSTATE", { "9000", "0", "80", truck7._cls, "0", "600.0", "50.0", "0", "1", "0", "", "" }, cl_pc)
    check(fc7._p.CurrentFuel == 600, "7j: the host's confirmation")
    T = T + 5
    deliver("VSTATE", { "9000", "0", "80", truck7._cls, "0", "590.0", "50.0", "0", "1", "0", "", "" }, cl_pc)
    check(fc7._p.CurrentFuel == 590, "7j: later states apply as usual")

    print("7k. a repair done here, a host state arriving before the tick: reported first, not undone")
    truck7._p.VehicleHealthComponent._p.CurrentHealth = 100
    sent = {}
    deliver("VSTATE", { "9000", "0", "80", truck7._cls, "0", "590.0", "50.0", "0", "1", "0", "", "" }, cl_pc)
    local vr = last_sent("VREPAIR", "host")
    check(vr ~= nil and tonumber(vr.args[5]) == 100 and tonumber(vr.args[6]) == 50, "7k: VREPAIR (100, +50) before the state was applied")
    check(truck7._p.VehicleHealthComponent._p.CurrentHealth == 100, "7k: the repair is kept")

    print("7l. stuck 'in a vehicle' here: the game's exit path")
    truck7._leave_box(me)
    me._p["InVehicle?"] = true
    V.tick()
    check(me._p["InVehicle?"] == true, "7l: not at once")
    T = T + 2.5
    V.tick()
    check(me._p["InVehicle?"] == false, "7l: InVehicle? cleared after 2 s")
    truck7._valid = false
end

print("7m. client purchase at the vehicle trader")
do
    local btn = new_obj("VehicleVendorButton_C", "VehicleVendorButton_C_3", { Vehicle = truck_cls, Price = "5,000" }, {})
    R.wallet(me, { { uid = { A = 5, B = 5, C = 5, D = 5 }, n = 8000 } })
    local n0 = R.n_spawn or 0
    sent = {}
    T = T + 1
    R.click(btn)
    local vb = last_sent("VBUY", "host")
    check(vb ~= nil and vb.args[1] == R.TRUCK_PATH and vb.args[5] == "5000" and tostring(vb.args[6]):match("%.1$") ~= nil,
        "7m: VBUY to the host: class, spawner, price 5000, purchase #1")
    check((R.n_spawn or 0) == n0, "7m: the car only this client would have was not spawned")
    check(R.total(me) == 3000, "7m: the game took the money from this machine's view (8000 -> 3000)")
    deliver("VBUYR", { "1", "ok", "Vehicle_PickupTruck_C_2147400009", "5000", "3000" }, cl_pc)
    check(R.total(me) == 3000, "7m: confirmed by the host")

    print("7n. the host refuses: the client is told in Russian")
    local nt = #toasts
    deliver("VBUYR", { "2", "no", "money", "2000", "5000" }, cl_pc)
    local found = false
    for i = nt + 1, #toasts do if toasts[i]:find("Покупка отменена", 1, true) then found = true end end
    check(found, "7n: Russian toast for the host's refusal")
    nt = #toasts
    deliver("VBUYR", { "3", "no", "spawner", "-1", "5000" }, cl_pc)
    found = false
    for i = nt + 1, #toasts do if toasts[i]:find("нет точки выдачи", 1, true) then found = true end end
    check(found, "7n: other refusals named in Russian")

    print("7o. not enough money here: the game's own refusal, nothing sent")
    R.wallet(me, { { uid = { A = 6, B = 6, C = 6, D = 6 }, n = 1000 } })
    sent, R.said = {}, nil
    R.click(btn)
    check(R.said == "Not enough money" and last_sent("VBUY") == nil, "7o: refused here by the game, no VBUY")
end

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
