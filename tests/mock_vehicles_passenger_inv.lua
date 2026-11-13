-- The inventory key in a seat (0.7.0: "the passenger cannot open the inventory, the driver
-- can"; the host sat next to a client who drove). The mock_vehicles_hostexit harness (copied)
-- plus the game's inventory key: Tab -> IA_Inventory -> @108034 (ToggleInventory unless
-- IsAiming?() / UsingBinoculars? / JournalOpen? / BuildModeOn? / InMeleeStance?), the
-- BP_JigComponent.ToggleInventory window, the game's callers that close it, and the UE4SS Tab
-- key bind that tells a press the character never got.
-- usage: lua mock_vehicles_passenger_inv.lua <scripts dir>
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
local tab_cb = nil
Key = { TAB = 9 }
function RegisterKeyBind(k, cb) if k == Key.TAB then tab_cb = cb end; return 1 end

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
ctx.scope_resolver = function(wco) if wco == gi then return nil end return nil end

local V = require("sdc_vehicles")
local S = { role = "host", remote = {}, remote_pcs = {}, client = nil }
V.install(S)
-- (the driver's exit moves nobody: the host takes the wheel with its seat key,
-- SEATK.on_key; the key itself: mock_vehicles_seats W / K)

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


-- ------------------------------------------------------------ the inventory key
require("sdc_uiinput")   -- its game_ui_open() (which game window is up) is read on the host too
local CHAR = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local IA_HOOK = CHAR .. ":InpActEvt_IA_Inventory_K2Node_EnhancedInputActionEvent_63"
local INTERACT_HOOK = CHAR .. ":InpActEvt_IA_Interact_K2Node_EnhancedInputActionEvent_61"
local DIST_HOOK = CHAR .. ":OnInteractActorOverDistance"
local TOGGLE_HOOK = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:ToggleInventory"
local function fire(path, ...)
    local h = hooks[path]
    if h and h.pre then h.pre(...) end
end

-- Enhanced Input: the keys mapped to IA_Inventory (QueryKeysMappedToAction)
local ia_asset = new_obj("InputAction", "IA_Inventory", {}, {})
rawset(by_path, "/Game/Input/InventoryPlayerActions/IA_Inventory.IA_Inventory", ia_asset)
local inv_keys = { "Tab" }
new_obj("EnhancedInputLocalPlayerSubsystem", "EnhancedInputLocalPlayerSubsystem_0", {}, {
    QueryKeysMappedToAction = function(_, a)
        local l = {}
        if a == ia_asset then for _, k in ipairs(inv_keys) do l[#l + 1] = { KeyName = FName(k) } end end
        return tarray(l)
    end,
})
local held = {}
host_pc._m.IsInputKeyDown = function(_, k) return held[k.KeyName:ToString()] == true end
host_pc._p.bShowMouseCursor = false

-- the host's inventory window (BP_JigComponent.ToggleInventory @0..913)
local jig = host_ch._p.BP_JigMultiplayer
jig._owner = host_ch
local inv_w = new_obj("BP_MainJigInventory_C", "BP_MainJigInventory_C_1", {}, {})
inv_w._m.IsInViewport = function(s) return s._in == true end
jig._p.InventoryWidgetRef = inv_w
local toggles = 0
jig._m.ToggleInventory = function(s)
    toggles = toggles + 1
    inv_w._in = not inv_w._in
    host_pc._p.bShowMouseCursor = inv_w._in
    fire(TOGGLE_HOOK, param(s))
end
host_ch._p.BuildingComponent = new_obj("BuildingComponent_C", "HostChar_Build", { ["BuildModeOn?"] = false }, {})
host_ch._m.FlushNetDormancy = function() end
host_ch._m.Svr_SetADS = function(s, b) s._svr_ads = b; s._p["IsADS?"] = b end

-- InpActEvt_IA_Inventory_..._63 -> @136591 -> @108034, then its post hook
local function game_inventory_key(ch)
    local p = ch._p
    local melee = p["InMeleeStance?"] == true
    local aiming = p["IsADS?"] == true and not melee
    local bc = p.BuildingComponent
    if not (aiming or p["UsingBinoculars?"] == true or p["JournalOpen?"] == true
            or (bc and bc._p["BuildModeOn?"] == true) or melee) then
        p.BP_JigMultiplayer:ToggleInventory()   -- @107882
    end
    fire(IA_HOOK, param(ch))
end
-- Tab: the frame loop's key read (game thread: down, then up next frame) and,
-- when the key reaches the character, the game's input event (before or after it)
local function press_tab(reaches, event_first)
    if reaches and event_first then game_inventory_key(host_ch) end
    held.Tab = true
    V.frame_tick()
    held.Tab = false
    V.frame_tick()
    if reaches and not event_first then game_inventory_key(host_ch) end
end
-- CheckDistanceFromActor -> BP_PlayerCharacter.OnInteractActorOverDistance (@0..122)
local function game_distance_close(by)
    if inv_w._in then jig:ToggleInventory() end
    fire(DIST_HOOK, param(host_ch), param(by), param(false))
end
-- IA_Interact "Started" with the window open (@108341: ToggleInventory first)
local function game_interact_close()
    if inv_w._in then jig:ToggleInventory() end
    fire(INTERACT_HOOK, param(host_ch))
end
local function lost_check()   -- the Tab check (0.4 s) and its confirmation (0.1 s later)
    T = T + 0.4
    run_delayed()
    T = T + 0.1
    run_delayed()
end
local function n_lines(list, pat)
    local n = 0
    for _, s in ipairs(list) do if s:find(pat, 1, true) then n = n + 1 end end
    return n
end
local function last_warn() return warns[#warns] or "" end
local IK = V._t.ik

print("setup")
-- (0.7.3: the hooks that only name the cause of a quick close - the interact
-- key, the distance check, a loot window - are registered with config debug)
log.debug_enabled = true
ctx.tick(S.remote_pcs)
V.tick()
local truck = new_vehicle("Vehicle_FlatbedTruck_C_2147475976", { X = 1050, Y = 0, Z = 80 })
T = T + 3
V.tick()
check(hooks[IA_HOOK] ~= nil and hooks[TOGGLE_HOOK] ~= nil and hooks[DIST_HOOK] ~= nil and hooks[INTERACT_HOOK] ~= nil,
    "the inventory key / ToggleInventory / closing callers are hooked")
check(tab_cb == nil, "Tab is read on the game thread, no UE4SS key bind (its thread runs Lua beside the unlocked native hooks)")
-- not seated: no key read at all
local reads0 = 0
local key_read = host_pc._m.IsInputKeyDown
host_pc._m.IsInputKeyDown = function(s, k) reads0 = reads0 + 1; return key_read(s, k) end
V.frame_tick()
check(reads0 == 0, "no key read while nobody sits")
host_pc._m.IsInputKeyDown = key_read

print("P0. the client drives, the host gets in next to it")
deliver("VENTER", vstr(truck), cl_pc)
T = T + 0.1
run_delayed()
T = T + 2
V.tick()
host_look = truck
check(host_press() == "interact" and host_ch._parent == truck, "P0: the host sits in the client's car")
check(V._t.vs()[truck._addr].host_seat == "passenger", "P0: as the passenger")
T = T + 0.1
run_delayed()
host_look = nil
host_ch._p.BP_JigHelperComp._p.CurrentTracActor = nil
T = T + 1
V.tick()

print("P1. a press the character never got, before the IA_Inventory hook ever ran: only a line")
T = T + 1
press_tab(false)
lost_check()
check(not inv_w._in and toggles == 0, "P1: nothing toggled")
check(last_warn():find("never reached the character's input", 1, true) ~= nil
    and last_warn():find("has not run once yet", 1, true) ~= nil, "P1: logged, left as it is (hook not proven)")

print("P2. the game's own toggle in the passenger seat: one line, nothing added")
T = T + 2
local w0 = #warns
press_tab(true)
check(inv_w._in and toggles == 1, "P2: the game opened the window")
local l2 = said("in the passenger seat of Vehicle_FlatbedTruck_C_2147475976: the game's branch ran ToggleInventory -> window open")
check(l2 ~= nil and l2:find("InVehicle?=true", 1, true) ~= nil, "P2: logged with the seat and the state")
lost_check()
check(inv_w._in and toggles == 1 and #warns == w0, "P2: the Tab watch saw the event: no second toggle, no warning")
T = T + 5
press_tab(true, true)   -- this time the event before the key bind's callback
check(not inv_w._in and toggles == 2, "P2: closed by the key")
lost_check()
check(toggles == 2 and #warns == w0, "P2: event before the bind's callback: still no second toggle")

print("P3. a stuck melee aim (set in the seat, the game cannot end it there) ate the key: cleared, opened")
T = T + 5
host_ch._p["IsADS?"], host_ch._p["InMeleeStance?"] = true, true
press_tab(true)
check(inv_w._in and toggles == 3, "P3: the window is open")
check(host_ch._p["IsADS?"] == false and host_ch._p["InMeleeStance?"] == false and host_ch._svr_ads == false,
    "P3: both aim flags off, IsADS? through Svr_SetADS(false)")
check(V.stats.inv_fixed == 1 and last_warn():find("@108034: InMeleeStance?", 1, true) ~= nil
    and last_warn():find("an aim it cannot end in a vehicle", 1, true) ~= nil, "P3: logged with the condition the game saw")
lost_check()
check(toggles == 3, "P3: no extra toggle from the Tab watch")
T = T + 5
press_tab(true)
check(not inv_w._in and toggles == 4 and V.stats.inv_fixed == 1, "P3: the next press is the game's own again")

print("P4. a firearm aim left set: the same")
T = T + 5
host_ch._p["IsADS?"] = true
press_tab(true)
check(inv_w._in and host_ch._p["IsADS?"] == false and V.stats.inv_fixed == 2, "P4: cleared and opened")
T = T + 5
press_tab(true)
check(not inv_w._in, "P4: closed by the game")

print("P5. the journal is open: the game's own refusal stays")
T = T + 5
host_ch._p["JournalOpen?"] = true
local t5 = toggles
press_tab(true)
check(not inv_w._in and toggles == t5, "P5: not opened")
check(last_warn():find("left as the game has it", 1, true) ~= nil and last_warn():find("JournalOpen?", 1, true) ~= nil, "P5: logged")
host_ch._p["JournalOpen?"] = false

print("P6. the key never reached the character in the passenger seat: the window opens the game's way")
T = T + 5
local lost0 = V.stats.inv_lost
press_tab(false)
check(not inv_w._in, "P6: nothing yet")
T = T + 0.4
run_delayed()
check(not inv_w._in, "P6: not at the first check (it is confirmed a tick later)")
T = T + 0.1
run_delayed()
check(inv_w._in and V.stats.inv_lost == lost0 + 1 and V.stats.inv_fixed == 3, "P6: opened after the confirmation")
check(last_warn():find("never reached the character's input", 1, true) ~= nil
    and last_warn():find("the window opened the game's way", 1, true) ~= nil, "P6: logged")
T = T + 5
press_tab(true)
check(not inv_w._in, "P6: the game's own key closes it again")

print("P7. not acted on: the window open, a modifier held, Tab not the inventory key, the driver seat")
T = T + 5
press_tab(true)
check(inv_w._in, "P7: window open (the game)")
local t7 = toggles
T = T + 5
press_tab(false)
lost_check()
check(inv_w._in and toggles == t7 and last_warn():find("is open", 1, true) ~= nil, "P7: open window: left alone")
T = T + 5
press_tab(true)
check(not inv_w._in, "P7: closed")
T = T + 5
held.LeftShift = true
t7 = toggles
press_tab(false)
held.LeftShift = nil
lost_check()
check(toggles == t7 and last_warn():find("LeftShift was held", 1, true) ~= nil, "P7: Shift+Tab (Steam overlay): left alone")
T = T + 15
inv_keys = { "I" }
IK.tab = nil
press_tab(false)
lost_check()
check(toggles == t7 and last_warn():find("Tab is not the inventory key here", 1, true) ~= nil, "P7: remapped key: left alone")
inv_keys = { "Tab" }
IK.tab = nil

print("P8. a window closed right after it opened in the seat: the caller is named")
T = T + 5
press_tab(true)
check(inv_w._in, "P8: open")
T = T + 0.3
local box = new_obj("BP_LootContainer_C", "Container_Fridge_C_25", {}, {})
game_distance_close(box)
run_delayed()
check(not inv_w._in and last_warn():find("closed 0.30 s after it opened, by the 3 m distance check of Container_Fridge_C_25", 1, true) ~= nil,
    "P8: the distance check named")
T = T + 5
press_tab(true)
T = T + 0.4
game_interact_close()
run_delayed()
check(last_warn():find("by the interact key", 1, true) ~= nil, "P8: the interact key named")
T = T + 5
press_tab(true)
T = T + 0.3
press_tab(true)
run_delayed()
local quick_key = said("closed 0.30 s after it opened, by the inventory key again")
check(quick_key ~= nil, "P8: the key itself: an info line, not a warning")
T = T + 5
press_tab(true)
T = T + 0.2
jig:ToggleInventory()   -- nobody the hooks know
run_delayed()
check(last_warn():find("no caller seen", 1, true) ~= nil, "P8: an unknown caller is said so")
local n8 = n_lines(warns, "s after it opened") + n_lines(infos, "s after it opened")
T = T + 5
press_tab(true)
T = T + 3
press_tab(true)
run_delayed()
check(not inv_w._in and n_lines(warns, "s after it opened") + n_lines(infos, "s after it opened") == n8, "P8: a window open for 3 s: no quick-close line")

print("P9. the host takes the wheel (its seat key): lost presses there are only logged")
T = T + 5
deliver("VEXIT", with(vstr(truck), "d", "40.0", "driver"), cl_pc)
check(V._t.vs()[truck._addr].host_seat == "passenger", "P9: the driver out: the host stays a passenger")
V._t.seatk.on_key()
check(V._t.vs()[truck._addr].host_seat == "driver", "P9: the host's seat key: the host drives")
T = T + 1
V.tick()
local t9 = toggles
press_tab(false)
lost_check()
check(toggles == t9 and last_warn():find("left as it is (not the passenger seat)", 1, true) ~= nil, "P9: driver seat: logged only")
T = T + 2
press_tab(true)
check(inv_w._in and said("in the driver seat of Vehicle_FlatbedTruck_C_2147475976: the game's branch ran ToggleInventory -> window open") ~= nil,
    "P9: the driver's own press")
T = T + 2
press_tab(true)

print("P10. on foot: the key is the game's alone, nothing logged or watched")
host_look = nil
check(host_press() == "exit" and host_free(), "P10: the host is out")
T = T + 3
V.tick()
local wn, keys10 = #warns, V.stats.inv_keys
press_tab(false)
lost_check()
press_tab(true)
check(inv_w._in and #warns == wn and V.stats.inv_keys == keys10, "P10: no line, no seat counted")
press_tab(true)

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
