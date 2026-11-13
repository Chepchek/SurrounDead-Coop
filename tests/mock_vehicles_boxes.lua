-- A client's refuel / repair of a vehicle (0.7.1: "the client cannot refuel / repair; the host
-- can"): the mock_vehicles harness (copied) with the game's flow as BP_VehicleMaster runs it on
-- the machine whose key was pressed - the option, FindJigItemByDA on the inventory WIDGETS (a
-- client has them), the timer bar, the hold, then UseGasCan / the kit branch whose
-- ServerFindThenConsumeByItemID walks MainJigContainers: the host's data, empty on a client, so
-- there the game says "No gas found" / "No repair kits found" and adds nothing.
-- Host: VFUEL / VREPAIR asks: full / no item / no vehicle / ok, the item taken from that
-- player's inventory once, the amount added, the state to every client, the answer (VBOXR).
-- Client: that note asks the host once per hold, the false note goes, VBOXR applies the game's
-- success step (or the game's note), nothing is reported twice.
-- C7..C11 (13.11, 0.11.0: in the game that note never reached the mod, so a client's repair
-- never asked): the client's tick at the hold's end asks instead; UseGasCan's hook still asks
-- for a refuel (once); leaving the box, a flag the game never took down and another option
-- pressed during the hold ask nothing. The whole round with both machines:
-- mock_vehicles_boxes_e2e.lua.
-- usage: lua mock_vehicles_boxes.lua <scripts dir>
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
local function deliver(kind, args, from_pc)
    local h = net.handlers[kind]
    assert(h, "no handler " .. kind)
    h(args, from_pc)
end

local gi = new_obj("SD_GameInstance_C", "SD_GameInstance_C_0", {}, {})
ctx.scope_resolver = function(wco) if wco == gi then return nil end return nil end

local V = require("sdc_vehicles")
local S = { role = "host", remote = {}, remote_pcs = {}, client = nil }
V.install(S)

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


-- ------------------------------------------------------------ the game's refuel / repair
local GAS_PATH = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan"
local KIT_PATH = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit"
local gas_da = new_obj("JigItemDataAsset", "DA_GasCan", {}, {})
local kit_da = new_obj("JigItemDataAsset", "DA_VehicleRepairKit", {}, {})
rawset(by_path, GAS_PATH, gas_da)
rawset(by_path, KIT_PATH, kit_da)
local OPT_GAS, OPT_KIT = "Jig.InteractOptions.RefuelVehicle", "Jig.InteractOptions.RepairVehicle"
local GFL_PATH = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local NOTE_HOOK = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"
local NOTE_MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"

-- The inventory as the game reads it: FindJigItemByDA -> this machine's widgets,
-- ServerFindThenConsumeByItemID -> MainJigContainers (only the host fills them).
local function key_of(da) return da == gas_da and "gas" or da == kit_da and "kit" or "?" end
local function give_jig(ch)
    local jig = ch._p.BP_JigMultiplayer
    jig._widgets = { gas = 0, kit = 0 }
    jig._main = { gas = 0, kit = 0 }
    jig._m.FindJigItemByDA = function(s, da, _t, _a, _b, _c, out) out.Result = (s._widgets[key_of(da)] or 0) >= 1 end
    jig._m.ServerFindThenConsumeByItemID = function(s, da, n, out)
        local k = key_of(da)
        s._takes = (s._takes or 0) + 1
        if (s._main[k] or 0) >= (n or 1) then
            s._main[k] = s._main[k] - (n or 1)
            out.Result = true
        else
            out.Result = false
        end
    end
    return jig
end

-- A HUD with the game's notification box (NotificationUI.VerticalBox_31) and timer bar.
local function give_hud(pc)
    local box = new_obj("VerticalBox", pc._short .. "_NoteBox", {}, {})
    box._kids = {}
    box._m.GetChildrenCount = function(s) return #s._kids end
    box._m.GetChildAt = function(s, i) return s._kids[i + 1] end
    local hud = new_obj("HUD_Game_C", pc._short .. "_HUD", {
        NotificationUI = new_obj("NotificationUI_C", pc._short .. "_NoteUI", { VerticalBox_31 = box }, {}) }, {})
    hud._m.InteractTimerUI = function(s, open, text)
        if open then
            s._p.InteractTimerWidget = new_obj("InteractionTimerUI_C", "Timer", { MaxTime = 0 }, {})
            s._timer_text = text
        else
            s._p.InteractTimerWidget = nil
        end
    end
    pc._m.GetHUD = function() return hud end
    hud._box = box
    return hud
end
local function notes_on(hud)
    local l = {}
    for _, w in ipairs(hud._box._kids) do l[#l + 1] = w._p.NotificationDetailsStruct[NOTE_MSG] end
    return l
end
local function has_note(hud, text) for _, s in ipairs(notes_on(hud)) do if s == text then return true end end return false end

-- GameFunctionLibrary_C.CreateNotificationUI: a widget in player 0's notification box, then the hook.
local note_calls = {}
local gfl = new_obj("GameFunctionLibrary_C", "Default__GameFunctionLibrary_C", {}, {})
gfl._m.CreateNotificationUI = function(self, msg, icon, col, delay, force, wco)
    note_calls[#note_calls + 1] = { text = msg, wco = wco }
    local pc = controllers[1]
    local hud = pc and pc._m.GetHUD and pc:GetHUD()
    if hud then
        local w = new_obj("NotificationWidget_C", "Note_" .. tostring(next_addr), { NotificationDetailsStruct = { [NOTE_MSG] = msg } }, {})
        w._m.RemoveFromParent = function(s)
            for i, x in ipairs(hud._box._kids) do if x == s then table.remove(hud._box._kids, i) break end end
        end
        hud._box._kids[#hud._box._kids + 1] = w
    end
    local h = hooks[NOTE_HOOK]
    if h and h.pre then h.pre(param(self), param(msg), param(icon), param(col), param(delay), param(force), param(wco)) end
end
rawset(by_path, GFL_PATH, gfl)

-- BP_VehicleMaster's fuel / repair pieces and its OnExecuteInteract branches (@18506 refuel,
-- @19447 repair), the hold's end (@1866 UseGasCan, @1902 the kit branch).
local function box_game(v)
    local p = v._p
    local fc, hc = p.FuelComponent, p.VehicleHealthComponent
    p.Duration, p.IsHeld = 10, false
    fc._p.Empty = false
    fc._m.AddFuel = function(s, frac)
        s._p.CurrentFuel = math.min(s._p.MaxFuel, s._p.CurrentFuel + frac * s._p.MaxFuel)
        s._p.Empty = s._p.CurrentFuel <= 0
        s._addfuel = (s._addfuel or 0) + 1
    end
    fc._m.UpdateUIFuel = function() end
    hc._m.UpdateUIHealth = function() end
    local fw = new_obj("BP_FuelWidget_C", v._short .. "_FuelW", {}, { UpdateFuel = function(s, a, b) s._shown = { a, b } end })
    local rw = new_obj("BP_RepairWidget_C", v._short .. "_RepairW", {}, { UpdateHealth = function(s, a, b) s._shown = { a, b } end })
    p.FuelWidget = new_obj("WidgetComponent", v._short .. "_FuelWC", {}, { GetUserWidgetObject = function() return fw end })
    p.RepairWidget = new_obj("WidgetComponent", v._short .. "_RepairWC", {}, { GetUserWidgetObject = function() return rw end })
    v._fw, v._rw = fw, rw
    v._m.VehicleEngineFX = function(s, visible) s._fx = visible end
    local function note(text) gfl:CreateNotificationUI(text, nil, { R = 1, G = 1, B = 1, A = 1 }, 2, false, v) end
    local function hud0() local c = player0(v, "GetPlayerController"); return c and c._m.GetHUD and c:GetHUD() or nil end
    v._m.OnExecuteInteract = function(self, who, tag)
        local function done() fire_post("OnExecuteInteract", param(self), param(who), param({ TagName = FName(tag) })) end
        if p.IsHeld then p.IsHeld = false; return done() end
        p.IsHeld = true
        local ch = player0(self)
        local jig = ch and ch._p.BP_JigMultiplayer
        local out = {}
        if tag == OPT_GAS then
            if fc._p.CurrentFuel == fc._p.MaxFuel then note("Gas full"); return done() end
            jig:FindJigItemByDA(gas_da, {}, true, false, 1, out)
            if not out.Result then return done() end
            local hud = hud0()
            if hud then hud:InteractTimerUI(true, "Refilling Vehicle") end
        elseif tag == OPT_KIT then
            if hc._p.CurrentHealth > hc._p.MaxHealth - 1 then note("Vehicle repaired"); return done() end
            jig:FindJigItemByDA(kit_da, {}, true, false, 1, out)
            if not out.Result then return done() end
            local hud = hud0()
            if hud then hud:InteractTimerUI(true, "Repairing Vehicle") end
        end
        ch:PlayMontage("Chr_Interact_Looting_Montage", 1)
        self._hold = tag
        done()
    end
    v._m.UseGasCan = function(self)
        local ch = player0(self)
        local out = {}
        ch._p.BP_JigMultiplayer:ServerFindThenConsumeByItemID(gas_da, 1, out)
        if out.Result then
            fc._p.CurrentFuel = math.min(fc._p.MaxFuel, fc._p.CurrentFuel + fc._p.MaxFuel / 2)
            fc._p.Empty = false
            local hud = hud0()
            if hud then hud:InteractTimerUI(false, "") end
        else
            note("No gas found")
        end
        fire_post("UseGasCan", param(self))
    end
    v._hold_end = function()
        if not p.IsHeld then return end
        p.IsHeld = false
        if v._hold == OPT_GAS then return v:UseGasCan() end
        local ch = player0(v)
        local out = {}
        ch._p.BP_JigMultiplayer:ServerFindThenConsumeByItemID(kit_da, 1, out)
        if out.Result then
            v:VehicleEngineFX(false)
            p["EngineOn?"] = true
            hc._p.CurrentHealth = math.min(hc._p.MaxHealth, hc._p.CurrentHealth + hc._p.MaxHealth / 2)
            local hud = hud0()
            if hud then hud:InteractTimerUI(false, "") end
        else
            note("No repair kits found")
        end
    end
end

local function msgs(kind, to)
    local l = {}
    for _, s in ipairs(sent) do if s.kind == kind and (to == nil or s.to == to) then l[#l + 1] = s.args end end
    return l
end
local function last(kind, to) local l = msgs(kind, to); return l[#l] end

print("setup")
ctx.tick(S.remote_pcs)
V.tick()
local truck = new_vehicle("Vehicle_FlatbedTruck_C_2147475976", { X = 1050, Y = 0, Z = 80 })
box_game(truck)
for _, c in ipairs({ host_ch, cl_ch, cl2_ch }) do give_jig(c) end
local host_hud = give_hud(host_pc)
local fc, hc = truck._p.FuelComponent, truck._p.VehicleHealthComponent
fc._p.CurrentFuel, fc._p.MaxFuel = 300, 1000
hc._p.CurrentHealth, hc._p.MaxHealth = 30, 125
T = T + 3
V.tick()
check(hooks[NOTE_HOOK] ~= nil, "CreateNotificationUI hook registered")
check(net.handlers.VBOXR ~= nil and net.NOW.VBOXR, "VBOXR handler, never queued (a vehicle message)")

-- ------------------------------------------------------------ host
print("H1. a client asks for its refuel: its gas can taken on the host once, +500, everyone gets it")
local cjig = cl_ch._p.BP_JigMultiplayer
cjig._main.gas = 2
sent = {}
deliver("VFUEL", with(vstr(truck), "800.0", "500.0"), cl_pc)
check(fc._p.CurrentFuel == 800 and (fc._addfuel or 0) == 1, "H1: +500 with the game's AddFuel")
check(cjig._main.gas == 1 and cjig._takes == 1, "H1: exactly one gas can taken from the client's inventory on the host")
local r = last("VBOXR", cl_pc)
check(r and r[1] == "refuel" and r[2] == "ok" and r[3] == "1050" and tonumber(r[7]) == 800 and tonumber(r[8]) == 1000,
    "H1: the client is answered: ok, 800 of 1000")
check(last("VBOXR", cl2_pc) == nil, "H1: only the asking client is answered")
T = T + 0.5
V.tick()
local s1, s2 = last("VSTATE", cl_pc), last("VSTATE", cl2_pc)
check(s1 and tonumber(s1[6]) == 800 and s2 and tonumber(s2[6]) == 800, "H1: the new fuel goes to every client at once")
check(said("Friend refuelled Vehicle_FlatbedTruck_C_2147475976: 300 -> 800 of 1000") ~= nil, "H1: logged on the host")

print("H2. a client asks for its repair: its kit taken once, +62.5, the kit branch's steps")
cjig._main.kit = 1
truck._p["EngineOn?"] = false
sent = {}
deliver("VREPAIR", with(vstr(truck), "92.5", "62.5"), cl_pc)
check(hc._p.CurrentHealth == 92.5 and truck._p["EngineOn?"] == true and truck._fx == false,
    "H2: +62.5, engine on, engine FX off (the game's kit branch)")
check(cjig._main.kit == 0 and cjig._takes == 2, "H2: exactly one repair kit taken")
check(truck._rw._shown and truck._rw._shown[1] == 92.5, "H2: the repair widget shows it")
r = last("VBOXR", cl_pc)
check(r and r[1] == "repair" and r[2] == "ok" and tonumber(r[7]) == 92.5, "H2: answered ok, 92.5")
T = T + 0.5
V.tick()
s2 = last("VSTATE", cl2_pc)
check(s2 and tonumber(s2[7]) == 92.5, "H2: the new health goes to every client")

print("H3. no item in its inventory on the host / full / no vehicle near it: nothing taken, the game's answer")
sent = {}
local takes = cjig._takes
deliver("VREPAIR", with(vstr(truck), "125.0", "62.5"), cl_pc)
check(hc._p.CurrentHealth == 92.5 and cjig._takes == takes + 1, "H3: no repair kit there: nothing added")
r = last("VBOXR", cl_pc)
check(r and r[2] == "none" and tonumber(r[7]) == 92.5, "H3: answered none (the host's value)")
fc._p.CurrentFuel = 1000
cjig._main.gas = 1
deliver("VFUEL", with(vstr(truck), "1000.0", "500.0"), cl_pc)
check(cjig._main.gas == 1 and cjig._takes == takes + 1, "H3: full tank: no gas can taken")
r = last("VBOXR", cl_pc)
check(r and r[1] == "refuel" and r[2] == "full", "H3: answered full")
deliver("VFUEL", { "90000", "0", "80", truck._cls, "500.0", "500.0" }, cl_pc)
r = last("VBOXR", cl_pc)
check(r and r[2] == "far" and r[3] == "90000" and cjig._main.gas == 1, "H3: no such vehicle near it: answered far, nothing taken")

print("H4. the host's own refuel is the game's, untouched")
fc._p.CurrentFuel = 200
local hjig = host_ch._p.BP_JigMultiplayer
hjig._widgets.gas, hjig._main.gas = 1, 1
sent = {}
truck:OnExecuteInteract(host_ch, OPT_GAS)
check(truck._p.IsHeld == true and host_hud._p.InteractTimerWidget ~= nil, "H4: the host's hold and timer bar")
T = T + 10
truck._hold_end()
check(fc._p.CurrentFuel == 700 and hjig._main.gas == 0, "H4: the game's UseGasCan on the host: +500, its own can")
check(#msgs("VFUEL") == 0 and #msgs("VBOXR") == 0, "H4: no ask, no answer")

-- ------------------------------------------------------------ client
print("C0. client")
V.reset("test")
net_mode = "client"
S.role = "client"
S.client = { acked = true }
S.remote, S.remote_pcs = {}, {}
cl_ch._local = true
host_ch._local = false
host_ch._parent, cl_ch._parent, cl2_ch._parent = nil, nil, nil
host_pc._p.Player = nil
cl_pc._p.Player = new_obj("LocalPlayer", "LP2", {}, {})
cl_pc._p.NetConnection = nil
controllers = { cl_pc }   -- a client has only its own controller: player 0 = this player
ctx.reset()
truck._valid = false
local ctruck = new_vehicle("Vehicle_FlatbedTruck_C_2147400001", { X = 1050, Y = 0, Z = 80 })
ctruck._p.Role = 1
box_game(ctruck)
local cfc, chc = ctruck._p.FuelComponent, ctruck._p.VehicleHealthComponent
cfc._p.MaxFuel, chc._p.MaxHealth = 1000, 125
local cl_hud = give_hud(cl_pc)
local me = cl_ch
local mjig = me._p.BP_JigMultiplayer
mjig._main = { gas = 0, kit = 0 }       -- a client's MainJigContainers: empty
mjig._takes = 0
me._p.__loc = { X = 1100, Y = 150, Z = 100 }
V.tick()
deliver("VCAP", { "1" }, cl_pc)
deliver("VSTATE", { "1050", "0", "80", ctruck._cls, "0", "300.0", "30.0", "0", "1", "0", "", "" }, cl_pc)
check(cfc._p.CurrentFuel == 300 and chc._p.CurrentHealth == 30, "C0: the host's fuel and health here")

print("C1. this player refuels: the game's hold here, its take fails here, the host is asked once")
mjig._widgets.gas = 1
sent = {}
ctruck:OnExecuteInteract(me, OPT_GAS)
check(ctruck._p.IsHeld == true and cl_hud._p.InteractTimerWidget ~= nil and me._montage ~= nil,
    "C1: the game's hold, timer bar and montage here (the can is in this player's widgets)")
T = T + 10
ctruck._hold_end()
check(mjig._takes == 1 and cfc._p.CurrentFuel == 300, "C1: the game's own take found nothing here (MainJigContainers empty): no fuel")
local q = last("VFUEL", "host")
check(q and q[1] == "1050" and q[4] == ctruck._cls and tonumber(q[5]) == 800 and tonumber(q[6]) == 500,
    "C1: VFUEL to the host: +500 (half the tank, as the game's step)")
check(#msgs("VFUEL", "host") == 1, "C1: asked once (the note and UseGasCan's own hook)")
check(not has_note(cl_hud, "No gas found"), "C1: the false 'No gas found' taken off this screen")
check(said("could not take the gas can") ~= nil, "C1: logged")
deliver("VBOXR", { "refuel", "ok", "1050", "0", "80", ctruck._cls, "800.0", "1000.0" }, cl_pc)
check(cfc._p.CurrentFuel == 800 and cfc._p.Empty == false and ctruck._fw._shown and ctruck._fw._shown[1] == 800,
    "C1: the host's answer: the game's success step here (fuel, Empty, the fuel widget)")
check(cl_hud._p.InteractTimerWidget == nil, "C1: the timer bar closed")
sent = {}
T = T + 0.5
V.tick()
deliver("VSTATE", { "1050", "0", "80", ctruck._cls, "0", "800.0", "30.0", "0", "1", "0", "", "" }, cl_pc)
check(#msgs("VFUEL", "host") == 0 and cfc._p.CurrentFuel == 800, "C1: nothing reported a second time; the host's state agrees")

print("C2. this player repairs: the same, the kit branch's own steps here")
mjig._widgets.kit = 1
ctruck._p["EngineOn?"] = false
sent = {}
ctruck:OnExecuteInteract(me, OPT_KIT)
check(ctruck._p.IsHeld == true and cl_hud._timer_text == "Repairing Vehicle", "C2: the game's repair hold here")
T = T + 10
ctruck._hold_end()
q = last("VREPAIR", "host")
check(q and tonumber(q[5]) == 92.5 and tonumber(q[6]) == 62.5 and chc._p.CurrentHealth == 30,
    "C2: VREPAIR to the host: +62.5; nothing added here")
check(not has_note(cl_hud, "No repair kits found"), "C2: the false 'No repair kits found' taken off this screen")
deliver("VBOXR", { "repair", "ok", "1050", "0", "80", ctruck._cls, "92.5", "125.0" }, cl_pc)
check(chc._p.CurrentHealth == 92.5 and ctruck._p["EngineOn?"] == true and ctruck._fx == false
    and ctruck._rw._shown and ctruck._rw._shown[1] == 92.5, "C2: the kit branch's success here: health, engine on, FX off, widget")
sent = {}
T = T + 0.5
V.tick()
check(#msgs("VREPAIR", "host") == 0, "C2: not reported again")

print("C3. the note again within the same hold: no second ask")
sent = {}
gfl:CreateNotificationUI("No repair kits found", nil, {}, 2, false, ctruck)
check(#msgs("VREPAIR", "host") == 0, "C3: one ask per hold")

print("C4. the host has no kit for this player: the game's note, nothing asked again")
T = T + 6
mjig._widgets.kit = 1
chc._p.CurrentHealth = 40
ctruck:OnExecuteInteract(me, OPT_KIT)
T = T + 10
sent = {}
ctruck._hold_end()
check(#msgs("VREPAIR", "host") == 1, "C4: asked")
local n_notes = #note_calls
deliver("VBOXR", { "repair", "none", "1050", "0", "80", ctruck._cls, "40.0", "125.0" }, cl_pc)
check(#note_calls == n_notes + 1 and note_calls[#note_calls].text == "No repair kits found" and has_note(cl_hud, "No repair kits found"),
    "C4: the game's 'No repair kits found' shown")
check(#msgs("VREPAIR", "host") == 1 and chc._p.CurrentHealth == 40, "C4: our own note asks nothing; no repair")

print("C5. full on the host: the game's 'Gas full'")
deliver("VBOXR", { "refuel", "full", "1050", "0", "80", ctruck._cls, "1000.0", "1000.0" }, cl_pc)
check(note_calls[#note_calls].text == "Gas full", "C5: the game's 'Gas full'")

print("C6. a note of another kind or another object asks nothing")
sent = {}
T = T + 6
gfl:CreateNotificationUI("No gas found", nil, {}, 2, false, me)
gfl:CreateNotificationUI("Vehicle hitched", nil, {}, 2, false, ctruck)
check(#msgs("VFUEL", "host") == 0 and #msgs("VREPAIR", "host") == 0, "C6: nothing sent")

print("C7. the game's note never reaches the mod (13.11 in the game): the tick sees the hold's end and asks")
local note_hook = hooks[NOTE_HOOK]
hooks[NOTE_HOOK] = nil
T = T + 6
chc._p.CurrentHealth = 40
mjig._widgets.kit = 1
sent = {}
ctruck:OnExecuteInteract(me, OPT_KIT)
check(ctruck._p.IsHeld == true, "C7: the game's repair hold here")
T = T + 5
V.tick()
check(#msgs("VREPAIR", "host") == 0, "C7: nothing asked while the hold runs")
T = T + 5
ctruck._hold_end()
check(#msgs("VREPAIR", "host") == 0 and chc._p.CurrentHealth == 40, "C7: the kit branch ran here: nothing added, its note asked nothing")
T = T + 0.5
V.tick()
q = last("VREPAIR", "host")
check(q and tonumber(q[5]) == 102.5 and tonumber(q[6]) == 62.5, "C7: the tick asked the host: +62.5")
check(said("seen in the tick") ~= nil, "C7: logged")
T = T + 0.5
V.tick()
check(#msgs("VREPAIR", "host") == 1, "C7: asked once")
deliver("VBOXR", { "repair", "ok", "1050", "0", "80", ctruck._cls, "102.5", "125.0" }, cl_pc)
check(chc._p.CurrentHealth == 102.5, "C7: the host's answer applied here")

print("C8. refuel without the note: UseGasCan's own hook asks, the tick does not ask again")
T = T + 6
cfc._p.CurrentFuel = 300
mjig._widgets.gas = 1
sent = {}
ctruck:OnExecuteInteract(me, OPT_GAS)
T = T + 10
ctruck._hold_end()
check(#msgs("VFUEL", "host") == 1 and said("UseGasCan added nothing here") ~= nil, "C8: UseGasCan's hook asked")
T = T + 0.5
V.tick()
T = T + 0.5
V.tick()
check(#msgs("VFUEL", "host") == 1, "C8: one ask")

print("C9. this player leaves the box during the hold: nothing asked")
T = T + 6
chc._p.CurrentHealth = 40
mjig._widgets.kit = 1
sent = {}
ctruck:OnExecuteInteract(me, OPT_KIT)
T = T + 3
ctruck._p.IsHeld = false
fire_post("OnEndRepairInteract", param(ctruck), param(me))
T = T + 7.5
V.tick()
T = T + 3
V.tick()
check(#msgs("VREPAIR", "host") == 0, "C9: nothing asked")

print("C10. the game never started its delay (flag left up): dropped, nothing asked")
T = T + 6
mjig._widgets.kit = 1
sent = {}
ctruck:OnExecuteInteract(me, OPT_KIT)
T = T + 10.5
V.tick()
check(#msgs("VREPAIR", "host") == 0, "C10: flag still up at the hold's time: nothing asked yet")
T = T + 3
V.tick()
check(#msgs("VREPAIR", "host") == 0 and warned("its last step never ran"), "C10: dropped with a warning")
check(ctruck._p.IsHeld == false, "C10: the stuck flag cleared (the next press starts a hold, not only clears it)")
T = T + 1
V.tick()
check(#msgs("VREPAIR", "host") == 0, "C10: nothing asked later")

print("C11. another option pressed on the car during the hold: the hold is over, nothing asked")
T = T + 6
chc._p.CurrentHealth = 40
ctruck._p.IsHeld = false
mjig._widgets.kit = 1
sent = {}
ctruck:OnExecuteInteract(me, OPT_KIT)
T = T + 4
ctruck:OnExecuteInteract(me, "Jig.InteractOptions.Inspect")
check(ctruck._p.IsHeld == false and said("ended by another option") ~= nil, "C11: the game's press cleared the hold; logged")
T = T + 6.5
V.tick()
T = T + 3
V.tick()
check(#msgs("VREPAIR", "host") == 0, "C11: nothing asked")
hooks[NOTE_HOOK] = note_hook

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
