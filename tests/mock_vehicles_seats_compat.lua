-- Mixed mod versions and the vehicle seats (sdc_vehseats): one process,
-- separate worlds. The new host's real messages (VSEAT with the seat fields,
-- VOCC, the packed VSTATE, "full" with the seat count) go to an older
-- client's modules through their own ClientMessage hook; an older host's
-- messages (VSEAT kind|name, single VSTATE records) go to the new client;
-- the new client's VENTER "s2" / VEXIT with the seat number go to an older
-- host. Checks: no error anywhere, an older client keeps seats 1-2 (the
-- mirror, its own texts), an older host seats a new client as before, the
-- new client falls back to VSTATE field 12.
-- usage: lua mock_vehicles_seats_compat.lua <scripts dir> [older scripts dir ...]
--   (default older: dist/snapshot_0.8.1 - the last build without the seats,
--   the version friends have - and dist/snapshot_0.7.2, next to the
--   scripts' project; a missing one is skipped)
local NEW = arg[1]
local OLDS = {}
for i = 2, #arg do OLDS[#OLDS + 1] = arg[i] end
if #OLDS == 0 then
    OLDS[1] = NEW .. "/../../../dist/snapshot_0.8.1"
    OLDS[2] = NEW .. "/../../../dist/snapshot_0.7.2"
end

local T = 100.0
os.clock = function() return T end
local fails, passes = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end
local function exists(dir)
    local f = io.open(dir .. "/sdc_vehicles.lua", "r")
    if f then f:close() return true end
    return false
end
local function d(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

-- ------------------------------------------------------------ one world (fresh modules from `dir`)
local function world(dir, role)
    for k in pairs(package.loaded) do
        if type(k) == "string" and k:find("^sdc_") then package.loaded[k] = nil end
    end
    package.path = dir .. "/?.lua;" .. package.path
    local W = { toasts = {}, sent = {}, errs = 0, hooks = {}, delayed = {} }
    ADDR_BASE = (ADDR_BASE or 0) + 1
    local Obj, registry, by_path, next_addr = {}, {}, {}, ADDR_BASE * 1048576
    local function new_obj(cls, short, props, methods, also)
        next_addr = next_addr + 16
        local o = setmetatable({ _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }, Obj)
        registry[cls] = registry[cls] or {}
        table.insert(registry[cls], o)
        for _, c in ipairs(also or {}) do registry[c] = registry[c] or {}; table.insert(registry[c], o) end
        return o
    end
    W.new_obj = new_obj
    Obj.__index = function(t, k)
        local base = rawget(Obj, k)
        if base ~= nil then return base end
        local m = rawget(t, "_m")[k]
        if m ~= nil then return m end
        return rawget(t, "_p")[k]
    end
    function Obj:IsValid() return self._valid end
    function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
    function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
    function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
    function Obj:GetPropertyValue(n) return self._p[n] end
    function Obj:SetPropertyValue(n, v) self._p[n] = v end
    function Obj:GetAddress() return self._addr end
    function Obj:GetOuter() return self._outer end
    function Obj:GetOwner() return self._owner end
    function Obj:SetOwner(o) self._owner = o end
    function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
    function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end
    function Obj:GetAttachParentActor() return self._parent end
    local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end
    W.param = param
    local function tarray() return setmetatable({ _items = {} }, { __index = function(t, k)
        if k == "GetArrayNum" then return function(s) return #rawget(s, "_items") end end
        if k == "ForEach" then return function() end end
        if k == "Empty" then return function() end end
        return nil
    end }) end
    RegisterHook = function(path, pre) W.hooks[path] = pre; return 1, 2 end
    FindAllOf = function(cls) local l = {}; for _, o in ipairs(registry[cls] or {}) do if o._valid then l[#l + 1] = o end end; return l end
    FindFirstOf = function(cls) return FindAllOf(cls)[1] end
    StaticFindObject = function(path) return by_path[path] end
    NotifyOnNewObject = function() end
    ExecuteInGameThread = function(f) f() end
    ExecuteInGameThreadWithDelay = function(ms, f) W.delayed[#W.delayed + 1] = f; return 1 end
    LoopInGameThreadWithDelay = function() return 1 end
    ExecuteWithDelay = function(ms, f) W.delayed[#W.delayed + 1] = f end
    LoopAsync = function() end
    FName = function(s) return { ToString = function() return s end, _fname = s } end
    FText = function(s) return s end
    LoadAsset = function() return nil end
    setmetatable(by_path, { __index = function(_, k) if k:find(":") then return new_obj("Function", k) end return nil end })
    local timers = {}
    local function tkey(o, fn) return tostring(o._addr) .. "|" .. fn end
    rawset(by_path, "/Script/Engine.Default__KismetSystemLibrary", new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return role == "host" end,
        K2_IsTimerActive = function(_, o, fn) return timers[tkey(o, fn)] == true end,
        K2_SetTimer = function(_, o, fn) timers[tkey(o, fn)] = true end,
        K2_ClearTimer = function(_, o, fn) timers[tkey(o, fn)] = nil end,
        CapsuleTraceSingle = function() return false end,
    }))
    local controllers = {}
    local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {
        GetPlayerController = function(_, wc, i) return controllers[i + 1] end,
        GetNumPlayerControllers = function() return #controllers end,
    })
    rawset(by_path, "/Script/Engine.Default__GameplayStatics", gps)
    W.montage = new_obj("AnimMontage", "Chr_SitInCar_Montage", {}, {})
    rawset(by_path, "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage", W.montage)

    local cfg = require("sdc_config")
    cfg.load(os.tmpname())
    if cfg.set then cfg.set("player_name", role == "host" and "Host" or "Friend") end
    local log = require("sdc_log")
    log.toast_sink = function(text) W.toasts[#W.toasts + 1] = text end
    local e0, e1 = log.err, log.err_throttled
    log.err = function(...) W.errs = W.errs + 1; return e0(...) end
    log.err_throttled = function(k, ...) W.errs = W.errs + 1; return e1(k, ...) end
    local ctx = require("sdc_ctx")
    local net = require("sdc_net")
    W.net = net
    -- what goes out: the encoded message, as the other side receives it
    net.send_to = function(pc, kind, ...)
        W.sent[#W.sent + 1] = { to = pc, kind = kind, raw = net.encode(kind, ...), args = { ... } }
        return true
    end
    net.send_to_host = function(kind, ...)
        W.sent[#W.sent + 1] = { to = "host", kind = kind, raw = net.encode(kind, ...), args = { ... } }
        return true
    end
    net.broadcast = function(pcs, kind, ...) for _, pc in ipairs(pcs) do net.send_to(pc, kind, ...) end end
    function W.last(kind, to)
        for i = #W.sent, 1, -1 do local s = W.sent[i]; if s.kind == kind and (to == nil or s.to == to) then return s end end
        return nil
    end
    local V = require("sdc_vehicles")
    W.V = V
    local S = { role = role, remote = {}, remote_pcs = {}, client = role == "client" and { acked = true } or nil }
    W.S = S
    V.install(S)
    if net.install_hooks then net.install_hooks() end

    local pid = 300
    local function new_char(name, loc, is_local)
        local cmc = new_obj("CharacterMovementComponent", name .. "_CMC", { MovementMode = 1, bServerAcceptClientAuthoritativePosition = true }, {})
        cmc._m.SetMovementMode = function(s, m) s._p.MovementMode = m end
        local dc = new_obj("VehicleDrivingComponent_C", name .. "_VDC", {}, {})
        local ch = new_obj("BP_PlayerCharacter_C", name, { __loc = loc, CharacterMovement = cmc, VehicleDrivingComponent = dc,
            BP_JigHelperComp = new_obj("BP_JigHelperComp_C", name .. "_Helper", {}, {}), ["InVehicle?"] = false, ["PlayerDead?"] = false }, {})
        pid = pid + 1
        local my = pid
        ch._pid = my
        ch._p.PlayerState = new_obj("PlayerState", name .. "_PS", {}, { GetPlayerId = function() return my end, GetPlayerName = function() return name end })
        local cap = new_obj("CapsuleComponent", name .. "_Capsule", {}, {})
        cap._m.UnWeldFromParent = function() ch._welded = false end
        ch._p.CapsuleComponent = cap
        local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { vis = 2 }, {})
        mesh._m.GetCollisionResponseToChannel = function(m, c) if c == 3 then return m._p.vis end return 2 end
        mesh._m.SetCollisionResponseToChannel = function(m, c, r) if c == 3 then m._p.vis = r end end
        ch._p.Mesh = mesh
        ch._local = is_local
        ch._m.IsLocallyControlled = function(s) return s._local == true end
        ch._m.K2_AttachToActor = function(s, p, _a, _b, _c, _e, weld) s._parent = p; s._welded = weld == true end
        ch._m.K2_DetachFromActor = function(s) s._parent = nil end
        ch._m.StopMontage = function() end
        ch._m.K2_SetActorLocationAndRotation = function(s, l) s._p.__loc = { X = l.X, Y = l.Y, Z = l.Z } end
        ch._m.PlayMontage = function(s, m) s._montage = m end
        ch._m.PlayAnimMontage = function(s, m) s._montage = m end
        ch._m.GetCurrentMontage = function(s) return s._montage end
        ch._m.StopAnimMontage = function(s) s._montage = nil end
        ch._m.SetWeaponsAndBackpackVisibility = function() end
        ch._m.ResetVehicleCameraArmLength = function() end
        ch._m.VehicleInteraction = function(s, enter, vref)
            s._p["InVehicle?"] = enter
            if enter then s._p.VehicleDrivingComponent._p.Vehicle = vref end
            local h = W.hooks["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:VehicleInteraction"]
            if h then h(param(s), param(enter), param(vref)) end
        end
        return ch
    end
    local function player0(wco)
        local h = W.hooks["/Script/Engine.GameplayStatics:GetPlayerCharacter"]
        local idx = param(0)
        if h then h(param(gps), param(wco), idx) end
        local pc = controllers[idx:get() + 1]
        return pc and pc._p.Pawn or nil
    end
    function W.vehicle(name, loc, cls)
        local mc = new_obj("ChaosWheeledVehicleMovementComponent", name .. "_VMC", { bRequiresControllerForInputs = false, bUpdateOnlyIfRendered = true }, {})
        mc._m.SetRequiresControllerForInputs = function(s, b) s._p.bRequiresControllerForInputs = b end
        mc._m.SetHandbrakeInput = function() end
        mc._m.SetBrakeInput = function() end
        local fc = new_obj("VehicleFuelComponent_C", name .. "_Fuel", { CurrentFuel = 300, MaxFuel = 1000 }, {})
        fc._m.StartFuelSpend = function() end
        fc._m.StopSpendFuel = function() end
        local snd = new_obj("AudioComponent", name .. "_Engine", { active = false }, {})
        snd._m.IsActive = function(s) return s._p.active end
        snd._m.Activate = function(s) s._p.active = true end
        snd._m.FadeOut = function(s) s._p.active = false end
        local resp = { [2] = 2, [4] = 2 }
        local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { visible = true }, {})
        mesh._m.GetCollisionResponseToChannel = function(_, c) return resp[c] end
        mesh._m.SetCollisionResponseToChannel = function(_, c, r) resp[c] = r end
        mesh._m.IsVisible = function() return true end
        mesh._m.GetSocketLocation = function(_, n)
            local nm = n.ToString and n:ToString() or tostring(n)
            return { X = loc.X + 20, Y = loc.Y + (nm == "PassengerSide" and 200 or -200), Z = loc.Z }
        end
        local pl = new_obj("SceneComponent", name .. "_PL", {}, {
            K2_GetComponentLocation = function() return { X = loc.X + 20, Y = loc.Y - 40, Z = loc.Z + 50 } end,
            K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
        })
        local v = new_obj(cls, name, { __loc = loc, VehicleMovementComponent = mc, FuelComponent = fc,
            VehicleHealthComponent = new_obj("VehicleHealthComponent_C", name .. "_Health", { CurrentHealth = 80, MaxHealth = 100 }, {}),
            EngineSound = snd, Mesh = mesh, HitBoxCollision = new_obj("BoxComponent", name .. "_HB", {}, { GetGenerateOverlapEvents = function() return true end }),
            PlayerLocation = pl, Colors = tarray(), Tags = tarray(), ["LightsOn?"] = false, ["EngineOn?"] = true, VehicleColor = 0,
            Role = role == "host" and 3 or 1 }, {}, { "BP_VehicleMaster_C" })
        for _, c in ipairs({ mc, fc, snd, mesh, pl }) do c._outer = v end
        v._m.GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end
        v._m.GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end
        v._m.GetActorUpVector = function() return { X = 0, Y = 0, Z = 1 } end
        v._m.Interact_GetInVehicle = function(self)
            local ch = player0(self)
            ch:K2_AttachToActor(self, FName("None"), 1, 1, 1, true)
            ch:K2_SetActorLocationAndRotation(pl:K2_GetComponentLocation(), {})
            ch:PlayMontage(W.montage, 1)
            self._entered_by = ch
            W.delayed[#W.delayed + 1] = function() player0(self):VehicleInteraction(true, self) end
            local h = W.hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:Interact_GetInVehicle"]
            if h then h(param(self)) end
        end
        v._m.Event_ExitVehicle = function(self)
            local ch = player0(self)
            ch:K2_DetachFromActor()
            ch:StopAnimMontage()
            ch:K2_SetActorLocationAndRotation(mesh:GetSocketLocation(FName(self._p.GetOutPasseenger and "PassengerSide" or "DriverSide")), {})
            self._exited_by = ch
        end
        v._m.ExitVehicle = function(self)
            local ch = player0(self)
            self:Event_ExitVehicle()
            local h = W.hooks["/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:ExitVehicle"]
            if h then h(param(self), param(true)) end
            ch:VehicleInteraction(false, nil)
        end
        v._m.TurnOnOffLights = function() end
        v._m.VehicleEngineFX = function() end
        return v
    end
    -- the host and three clients; on a client, the local one is Friend
    local host_ch = new_char("HostChar", { X = 0, Y = 0, Z = 100 }, role == "host")
    local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_ch }, { IsLocalController = function() return role == "host" end },
        { "PlayerController" })
    host_ch._p.Controller = host_pc
    W.host = { ch = host_ch, pc = host_pc }
    W.cl = {}
    for i, name in ipairs({ "Friend", "Friend2", "Friend3", "Friend4" }) do
        local ch = new_char(name .. "Char", { X = 0, Y = 0, Z = 100 }, role == "client" and i == 1)
        local pc = new_obj("BP_PlayerController_C", name .. "PC", { Pawn = ch }, {}, { "PlayerController" })
        if role == "host" then pc._p.NetConnection = new_obj("IpConnection", name .. "Conn", {}, {}) end
        ch._p.Controller = pc
        ch._owner = pc
        W.cl[i] = { ch = ch, pc = pc, key = pc:GetFullName(), name = name }
        if role == "host" then
            S.remote[W.cl[i].key] = { key = W.cl[i].key, pc = pc, name = name, index = i }
            S.remote_pcs[#S.remote_pcs + 1] = pc
        end
    end
    if role == "host" then
        host_pc._p.Player = new_obj("LocalPlayer", "LP", {}, {})
        controllers = { host_pc, W.cl[1].pc, W.cl[2].pc, W.cl[3].pc, W.cl[4].pc }
        ctx.tick(S.remote_pcs)
    else
        W.cl[1].pc._p.Player = new_obj("LocalPlayer", "LP", {}, {})
        controllers = { W.cl[1].pc }
    end
    function W.run_delayed() local dl = W.delayed; W.delayed = {}; for _, f in ipairs(dl) do f() end end
    function W.tick(dt) T = T + (dt or 0.5); V.tick() end
    -- a message as the other side's mod receives it (its own hook / handler)
    function W.receive(raw, from_pc)
        if role == "client" then
            local h = W.hooks["/Script/Engine.PlayerController:ClientMessage"]
            if h then
                h(param(W.cl[1].pc), param(raw))
            else
                local kind, fields = net.decode(raw)
                if net.handlers[kind] then net.handlers[kind](fields, W.cl[1].pc) end
            end
        else
            local kind, fields = net.decode(raw)
            if net.handlers[kind] then net.handlers[kind](fields, from_pc) end
        end
    end
    function W.vstr(v) local l = v:K2_GetActorLocation(); return tostring(l.X), tostring(l.Y), tostring(l.Z), v._cls end
    function W.toast(n0, pat) for i = n0 + 1, #W.toasts do if W.toasts[i]:find(pat, 1, true) then return true end end return false end
    W.tick(1)
    return W
end

-- ------------------------------------------------------------ 1. the new host's real messages
print("1. new host: the messages it sends (seat fields, VOCC, packed VSTATE, full with a count)")
local H = world(NEW, "host")
local car = H.vehicle("Vehicle_SUV_C_2147495001", { X = 5000, Y = 0, Z = 80 }, "Vehicle_SUV_C")
for i, c in ipairs(H.cl) do c.ch._p.__loc = { X = 5000 - 60 + 40 * i, Y = 300, Z = 100 } end
H.host.ch._p.__loc = { X = 5000, Y = -300, Z = 100 }
H.tick(2)
local function venter(c, s2)
    local x, y, z, cls = H.vstr(car)
    local raw = s2 and H.net.encode("VENTER", x, y, z, cls, "s2") or H.net.encode("VENTER", x, y, z, cls)
    H.receive(raw, c.pc)
end
venter(H.cl[1], true)
T = T + 0.1
H.run_delayed()
local m_driver = H.last("VSEAT", H.cl[1].pc)
venter(H.cl[2], false)
local m_p2 = H.last("VSEAT", H.cl[2].pc)
venter(H.cl[3], true)
local m_p3 = H.last("VSEAT", H.cl[3].pc)
venter(H.cl[4], false)
local m_full = H.last("VSEAT", H.cl[4].pc)
check(m_driver and m_driver.args[1] == "driver" and m_driver.args[3] == "1", "1: VSEAT driver with the seat fields")
check(m_p2 and m_p2.args[1] == "passenger" and m_p2.args[3] == "2" and m_p2.args[5] == "2",
    "1: an older client (no s2): seat 2 of 2, the fields in the tail")
check(m_p3 and m_p3.args[3] == "3" and m_p3.args[5] == "4", "1: a new client: seat 3 of 4")
check(m_full and m_full.args[1] == "none" and m_full.args[2] == "full" and m_full.args[3] == "2",
    "1: another older client refused: none|full|2 (seat 4 free)")
local st = H.V._t.vs()[car._addr]
H.sent = {}
st.dirty = true
H.tick(0.5)
local m_vstate = H.last("VSTATE", H.cl[1].pc)
local m_vocc = H.last("VOCC", H.cl[1].pc)
check(m_vstate and m_vstate.args[1] == "*" and m_vocc and m_vocc.args[1] == "*" and m_vocc.args[6]:find("3:", 1, true),
    "1: packed VSTATE and VOCC (seat 3 taken)")
check(H.errs == 0, "1: no error on the new host")
local MSG = { driver = m_driver.raw, p2 = m_p2.raw, p3 = m_p3.raw, full = m_full.raw, vstate = m_vstate.raw, vocc = m_vocc.raw,
    none_old = H.net.encode("VSEAT", "none", "full") }
local NEW_IDS = { host = H.host.ch._pid }

-- ------------------------------------------------------------ 2.. each older version as the client / the host
for _, old in ipairs(OLDS) do
    if not exists(old) then
        print("(skipped: no older scripts at " .. old .. ")")
    else
        print("2. an older client (" .. old .. ") gets the new host's messages")
        local O = world(old, "client")
        local me = O.cl[1].ch
        local cv = O.vehicle("Vehicle_SUV_C_2147495001", { X = 5000, Y = 0, Z = 80 }, "Vehicle_SUV_C")
        me._p.__loc = { X = 5020, Y = 300, Z = 100 }
        O.receive(O.net.encode("VCAP", "1"))
        O.tick(1)
        O.sent = {}
        cv:Interact_GetInVehicle()
        local ve = O.last("VENTER", "host")
        check(ve and #ve.args == 4, "2: its VENTER: 4 fields (no s2) - the new host gives it seats 1-2")
        local n0 = #O.toasts
        O.receive(MSG.p2)
        check(me._parent == cv and d(me._p.__loc, { X = 5020, Y = 40, Z = 130 }) < 1, "2: VSEAT seat 2 with the tail: in the mirror seat")
        check(O.toast(n0, "Вы пассажир: машину ведёт Friend."), "2: its own text (Friend drives)")
        O.receive(MSG.p3)
        check(me._parent == cv and d(me._p.__loc, { X = 5020, Y = 40, Z = 130 }) < 1, "2: even a seat 3 answer: the mirror, no error")
        O.receive(MSG.vocc)
        check(O.net.handlers.VOCC == nil and O.errs == 0, "2: VOCC: no handler there, skipped without an error")
        O.receive(MSG.vstate)
        check(O.errs == 0, "2: the packed VSTATE: no error")
        O.receive(MSG.driver)
        check(O.errs == 0 and d(me._p.__loc, { X = 5020, Y = -40, Z = 130 }) < 1 and cv._p.VehicleMovementComponent._p.bRequiresControllerForInputs == false,
            "2: VSEAT driver with the tail: at the wheel, drives")
        n0 = #O.toasts
        O.receive(MSG.full)
        check(me._parent == nil and O.toast(n0, "В машине нет свободного места."), "2: none|full|2: out, its own text")
        O.tick(1)
        check(O.errs == 0, "2: no error at all on the older client")

        print("3. an older host (" .. old .. ") gets the new client's messages")
        local OH = world(old, "host")
        local hc = OH.vehicle("Vehicle_SUV_C_2147495002", { X = 9000, Y = 0, Z = 80 }, "Vehicle_SUV_C")
        for i, c in ipairs(OH.cl) do c.ch._p.__loc = { X = 9000 - 60 + 40 * i, Y = 300, Z = 100 } end
        OH.tick(2)
        local hx, hy, hz, hcls = OH.vstr(hc)
        OH.receive(OH.net.encode("VENTER", hx, hy, hz, hcls, "s2"), OH.cl[1].pc)
        T = T + 0.1
        OH.run_delayed()
        local s1 = OH.last("VSEAT", OH.cl[1].pc)
        check(s1 and s1.args[1] == "driver" and OH.cl[1].ch._parent == hc, "3: VENTER with s2: seated as the driver, as before")
        OH.receive(OH.net.encode("VENTER", hx, hy, hz, hcls, "s2"), OH.cl[2].pc)
        local s2 = OH.last("VSEAT", OH.cl[2].pc)
        check(s2 and s2.args[1] == "passenger", "3: the second one: passenger (its 2 seats)")
        OH.receive(OH.net.encode("VENTER", hx, hy, hz, hcls, "s2"), OH.cl[3].pc)
        local s3 = OH.last("VSEAT", OH.cl[3].pc)
        check(s3 and s3.args[1] == "none" and s3.args[2] == "full", "3: a third: full (the older host has 2 seats)")
        OH.tick(1)
        OH.sent = {}
        local vst_old = nil
        OH.tick(10.5)
        vst_old = OH.last("VSTATE", OH.cl[1].pc)
        OH.receive(OH.net.encode("VEXIT", hx, hy, hz, hcls, "p", "2.0", "passenger", "2"), OH.cl[2].pc)
        check(OH.cl[2].ch._parent == nil and OH.errs == 0, "3: VEXIT with the seat number: out, no error")
        local old_p = s2 and s2.raw
        print("4. the new client gets the older host's messages")
        local N = world(NEW, "client")
        local nme = N.cl[1].ch
        local ncv = N.vehicle("Vehicle_SUV_C_2147495002", { X = 9000, Y = 0, Z = 80 }, "Vehicle_SUV_C")
        nme._p.__loc = { X = 9020, Y = 300, Z = 100 }
        N.receive(N.net.encode("VCAP", "1"))
        N.tick(1)
        ncv:Interact_GetInVehicle()
        local nn0 = #N.toasts
        if old_p then N.receive(old_p) end
        check(nme._parent == ncv and d(nme._p.__loc, { X = 9020, Y = 40, Z = 130 }) < 1 and N.V._t.local_seat().idx == 2,
            "4: VSEAT passenger|name: the mirror seat (seat 2)")
        check(N.toast(nn0, "Вы пассажир: машину ведёт"), "4: the old text")
        nn0 = #N.toasts
        N.receive(N.net.encode("VSEAT", "none", "full"))
        check(nme._parent == nil and N.toast(nn0, "В машине нет свободного места.") and not N.toast(nn0, "всего мест"),
            "4: none|full without a count: the old text")
        -- an older host's VSTATE (one record, or packed in 0.7.3) and no VOCC: field 12 seats the passenger
        local other = N.host.ch
        local mate = N.cl[2].ch
        local rec = { "9000", "0", "80", "Vehicle_SUV_C", "0", "300.0", "80.0", "0", "1", "1", tostring(other._pid), tostring(mate._pid) }
        if vst_old and vst_old.args[1] ~= "*" then
            N.receive(N.net.encode("VSTATE", table.unpack(rec)))
        else
            N.receive(N.net.encode("VSTATE", "*", table.unpack(rec)))
        end
        N.tick(0.5)
        N.tick(2)
        check(other._parent == ncv and mate._parent == ncv and d(mate._p.__loc, { X = 9020, Y = 40, Z = 130 }) < 1,
            "4: no VOCC from an older host: VSTATE fields 11 / 12 place the driver and seat 2")
        check(N.errs == 0, "4: no error on the new client")
    end
end

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
