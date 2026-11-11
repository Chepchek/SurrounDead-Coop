-- The vehicle radio in co-op (sdc_vehradio through sdc_vehicles): the mock_vehicles
-- harness (copied) with the game's radio as RadioComponent_C / RadioUI_C run it: a
-- looping MediaPlayer per machine opening "file://<game>/Radio/<CurrentSong>", the
-- vehicle's MediaSound, every machine with its own Radio folder (Found Files).
-- Host: its own window's changes go to every client, a seated client's change is
-- played on the host's copy and passed on, an unseated one is refused, a joining /
-- seating client gets the state, a radio already playing is taken, the 10 s repeat.
-- Client: the host's state played with the game's functions (track by name, any case;
-- a missing track -> one of its own + a note; an empty folder -> a note), position /
-- speed / pause once the track plays, its own change sent, a stale host state skipped,
-- off, and the vehicle_radio switch.
-- usage: lua mock_vehicles_radio.lua <scripts dir>
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


-- ------------------------------------------------------------ the game's radio
local GAME_DIR = "C:/Games/SurrounDead/"
local function list_copy(t) local c = {}; for i, x in ipairs(t) do c[i] = x end; return c end

-- RadioComponent_C with its MediaPlayer and the vehicle's MediaSound, as the game runs them
-- (work\re\pseudo_radio\RadioComponent.txt).
local function add_radio(v, files)
    local mp = new_obj("MediaPlayer", v._short .. "_MediaPlayer", {}, {})
    mp._st = { url = "", playing = false, paused = false, rate = 0, t = 0, dur = 180, opening = false, seeks = 0 }
    local m = mp._m
    m.GetUrl = function(s) return s._st.url end
    m.IsPlaying = function(s) return s._st.playing end
    m.IsPaused = function(s) return s._st.paused end
    m.IsReady = function(s) return s._st.url ~= "" and not s._st.opening end
    m.GetRate = function(s) return s._st.playing and s._st.rate or 0 end
    m.SetRate = function(s, r)
        if s._st.url == "" or s._st.opening then return false end
        s._st.rate, s._st.playing, s._st.paused = r, r > 0, r == 0
        return true
    end
    m.Play = function(s) return s:SetRate(1) end
    m.Pause = function(s) return s:SetRate(0) end
    m.Close = function(s) s._st.url, s._st.playing, s._st.paused, s._st.opening = "", false, false, false end
    m.OpenUrl = function(s, u)
        s._st.url, s._st.opening, s._st.playing, s._st.paused, s._st.t = u, true, false, false, 0
        return true
    end
    m.OpenFile = function(s, p) return s:OpenUrl("file://" .. p) end
    m.GetTime = function(s) return { Ticks = math.floor(s._st.t * 1e7) } end
    m.GetDuration = function(s) return { Ticks = math.floor(s._st.dur * 1e7) } end
    m.Seek = function(s, ts) s._st.t = ts.Ticks / 1e7; s._st.seeks = s._st.seeks + 1; return true end
    local ms = new_obj("MediaSoundComponent", v._short .. "_MediaSound", { mult = 1, active = false }, {})
    ms._m.SetVolumeMultiplier = function(s, x) s._p.mult = x end
    ms._m.Activate = function(s) s._p.active = true end
    ms._m.Deactivate = function(s) s._p.active = false end
    local rc = new_obj("RadioComponent_C", v._short .. "_RadioComponent", {
        ["TurnedOn?"] = false, ["Paused?"] = false, CurrentSong = "", PreviousSong = "",
        ["Found Files"] = tarray(list_copy(files)), Volume = 0.5, PlayRate = 1, MediaPlayer = mp, MediaSound = ms }, {})
    rc._calls = { start = 0, play = 0, stop = 0 }
    -- StartRadio: TurnedOn?, Paused? off, PreviousSong, a "random" CurrentSong (here: the last file)
    rc._m.StartRadio = function(s)
        s._calls.start = s._calls.start + 1
        s._p["TurnedOn?"], s._p["Paused?"] = true, false
        s._p.PreviousSong = s._p.CurrentSong
        local f = s._p["Found Files"]._items
        if #f > 0 then s._p.CurrentSong = f[#f] end
    end
    -- Event_PlayCurrentRadioSong (@1250): OpenUrl, MediaSound on; it plays when ready (PlayOnOpen)
    rc._m.Event_PlayCurrentRadioSong = function(s)
        s._calls.play = s._calls.play + 1
        mp:OpenUrl("file://" .. GAME_DIR .. "Radio/" .. s._p.CurrentSong)
        ms:Activate()
    end
    rc._m.ShuffleRadioSongs = function(s)
        s._p.PreviousSong = s._p.CurrentSong
        for _, f in ipairs(s._p["Found Files"]._items) do
            if f ~= s._p.PreviousSong then s._p.CurrentSong = f; break end
        end
        s:Event_PlayCurrentRadioSong()
    end
    rc._m.StopRadio = function(s)
        s._calls.stop = s._calls.stop + 1
        s._p["TurnedOn?"] = false
        mp:Close()
        ms:Deactivate()
    end
    v._p.RadioComponent, v._p.MediaSound = rc, ms
    return rc, mp, ms
end

-- The RadioUI window on this machine (@1963 play / resume, @3480 pause, @3726 volume,
-- @2210 speed, @3716 next)
local W = {}
function W.play(rc)
    if not rc._p["TurnedOn?"] then
        rc:StartRadio()
        rc:Event_PlayCurrentRadioSong()
    elseif rc._p["Paused?"] then
        rc._p["Paused?"] = false
        rc._p.MediaPlayer:Play()
    end
end
function W.pause(rc) if not rc._p["Paused?"] then rc._p["Paused?"] = true; rc._p.MediaPlayer:Pause() end end
function W.volume(rc, x) rc._p.Volume = x; rc._p.MediaSound:SetVolumeMultiplier(x) end
function W.speed(rc, x) rc._p.MediaPlayer:SetRate(x); rc._p.PlayRate = x end
function W.next(rc) rc:ShuffleRadioSongs() end
-- the opened file starts playing (PlayOnOpen)
local function ready(mp) if mp._st.opening then mp._st.opening, mp._st.playing, mp._st.rate = false, true, 1 end end

local function radios(to)
    local l = {}
    for _, s in ipairs(sent) do
        if s.kind == "VRADIO" and (to == nil or s.to == to) then l[#l + 1] = s.args end
    end
    return l
end
local function last_radio(to) local l = radios(to); return l[#l] end
local function radio_at(to, x) for _, a in ipairs(radios(to)) do if a[1] == x then return a end end return nil end
local function kinds(kind) local n = 0; for _, s in ipairs(sent) do if s.kind == kind then n = n + 1 end end; return n end
local function toasted(pat) for _, s in ipairs(toasts) do if s:find(pat, 1, true) then return s end end return nil end
local function url_song(mp) return (mp._st.url:match("([^/]+)$")) end
local function close(a, b, eps) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 0.05) end
-- VRADIO|x|y|z|class|on|paused|volume|speed|position|track
local function rmsg(v, on, paused, vol, rate, pos, song)
    return with(vstr(v), on and "1" or "0", paused and "1" or "0", string.format("%.2f", vol), string.format("%.2f", rate),
        string.format("%.1f", pos), song)
end
-- the module's stand-in for a missing track (sorted list, the name's hash)
local function stand_in(list, song)
    local s = list_copy(list)
    table.sort(s)
    local h, low = 5381, song:lower()
    for i = 1, #low do h = (h * 33 + low:byte(i)) % 2147483647 end
    return s[h % #s + 1]
end

print("setup")
ctx.tick(S.remote_pcs)
V.tick()
local truck = new_vehicle("Vehicle_FlatbedTruck_C_2147475976", { X = 1050, Y = 0, Z = 80 })
local HOST_FILES = { "Alpha.mp3", "Bravo.mp3", "Charlie.mp3" }
local rc, mp, ms = add_radio(truck, HOST_FILES)
T = T + 3
V.tick()
check(net.handlers.VRADIO ~= nil and net.handlers.VRADIOQ ~= nil, "VRADIO / VRADIOQ handlers registered")
check(net.NOW.VRADIO and net.NOW.VRADIOQ, "VRADIO / VRADIOQ never wait in the send queue (vehicle messages)")

print("R1. the host sits in the truck and turns its radio on: every client gets it")
host_look = truck
check(host_press() == "interact" and host_ch._parent == truck, "R1: the host sits in the truck")
T = T + 0.1
run_delayed()
T = T + 1
V.tick()
sent = {}
W.play(rc)
T = T + 0.5
V.tick()
local m1, m2 = last_radio(cl_pc), last_radio(cl2_pc)
check(m1 ~= nil and m2 ~= nil and #radios() == 2, "R1: one VRADIO to each client")
check(m1 and m1[1] == "1050" and m1[4] == truck._cls, "R1: names the truck by place and class")
check(m1 and m1[5] == "1" and m1[6] == "0" and m1[7] == "0.50" and m1[8] == "1.00" and m1[10] == "Charlie.mp3",
    "R1: on, playing, volume 0.50, speed 1.00, the track the MediaPlayer opened")
check(said("the host changed the radio in Vehicle_FlatbedTruck_C_2147475976") ~= nil, "R1: logged on the host")
ready(mp)
sent = {}
T = T + 0.5
V.tick()
check(#radios() == 0, "R1: the track starting to play is no change")

print("R2. pause, volume, resume + speed")
W.pause(rc)
T = T + 0.5
V.tick()
m1 = last_radio(cl_pc)
check(m1 and m1[6] == "1", "R2: paused sent")
sent = {}
W.volume(rc, 0.8)
T = T + 0.5
V.tick()
m1 = last_radio(cl_pc)
check(m1 and m1[7] == "0.80" and #radios() == 2, "R2: volume sent (once per client)")
W.play(rc)
W.speed(rc, 1.5)
mp._st.t = 12
sent = {}
T = T + 0.5
V.tick()
m1 = last_radio(cl_pc)
check(m1 and m1[6] == "0" and m1[8] == "1.50" and m1[9] == "12.0" and #radios() == 2, "R2: resumed at x1.5, position 12 s, one message")

print("R3. a client gets in as a passenger: its radio state at once")
sent = {}
deliver("VENTER", vstr(truck), cl_pc)
check(cl_ch._parent == truck and V._t.seats()[r1.key].seat == "passenger", "R3: the client sits as a passenger")
T = T + 0.5
V.tick()
m1 = last_radio(cl_pc)
check(m1 and m1[10] == "Charlie.mp3" and m1[8] == "1.50", "R3: the seated client got the radio state")
check(last_radio(cl2_pc) == nil, "R3: not the other client")
check(said("Friend sits in Vehicle_FlatbedTruck_C_2147475976: its radio state sent") ~= nil, "R3: logged")

print("R4. the seated client presses Next on its machine: the host plays it and passes it on")
sent = {}
local plays0 = rc._calls.play
deliver("VRADIO", rmsg(truck, true, false, 0.8, 1.0, 0.4, "Bravo.mp3"), cl_pc)
check(rc._p.CurrentSong == "Bravo.mp3" and url_song(mp) == "Bravo.mp3" and rc._calls.play == plays0 + 1,
    "R4: the host's copy: StartRadio + CurrentSong + Event_PlayCurrentRadioSong opened Bravo.mp3")
check(ms._p.mult == 0.8 and rc._p.Volume == 0.8, "R4: volume on the host's copy (MediaSound multiplier)")
local m = last_radio(cl2_pc)
check(m and m[10] == "Bravo.mp3" and m[9] == "0.4", "R4: passed to the other client")
check(last_radio(cl_pc) == nil, "R4: not echoed to the sender")
check(said("Friend (passenger) changed the radio in Vehicle_FlatbedTruck_C_2147475976") ~= nil, "R4: logged")
T = T + 0.5
V.tick()
check(#radios() == 1, "R4: while the track opens the host's own seat poll sends nothing")
ready(mp)
T = T + 0.5
V.tick()
check(#radios() == 1, "R4: nor once it plays (applied here, not the host's own change)")
check(mp._st.seeks == 0 and mp._st.rate == 1, "R4: 0.4 s is no position jump; speed 1 as sent")

print("R5. a client in no seat: refused, the host's state sent back")
sent = {}
plays0 = rc._calls.play
deliver("VRADIO", rmsg(truck, true, false, 0.3, 1.0, 0, "Alpha.mp3"), cl2_pc)
check(rc._calls.play == plays0 and rc._p.CurrentSong == "Bravo.mp3" and rc._p.Volume == 0.8, "R5: the host's copy unchanged")
m = last_radio(cl2_pc)
check(m and m[10] == "Bravo.mp3" and m[7] == "0.80", "R5: the host's state sent back to that client")
check(last_radio(cl_pc) == nil, "R5: nothing to the others")
check(said("Friend2 changed the radio in Vehicle_FlatbedTruck_C_2147475976") ~= nil, "R5: logged")

print("R6. a track the host does not have: one of its own plays, the note once, the name passed on")
sent = {}
toasts = {}
deliver("VRADIO", rmsg(truck, true, false, 0.8, 1.0, 0, "Zulu.mp3"), cl_pc)
local own = rc._p.CurrentSong
check(own == stand_in(HOST_FILES, "Zulu.mp3") and url_song(mp) == own, "R6: the host's copy plays its own stand-in " .. tostring(own))
check(toasted("Zulu.mp3") ~= nil and toasted("нет в вашей папке Radio") ~= nil, "R6: the note on the host's screen (Russian)")
m = last_radio(cl2_pc)
check(m and m[10] == "Zulu.mp3", "R6: the sender's track name is passed on")
check(V.radio._t.want()[truck._addr].st.song == "Zulu.mp3", "R6: the host keeps the sender's track as the state")
toasts = {}
deliver("VRADIO", rmsg(truck, true, false, 0.8, 1.0, 0, "Yankee.mp3"), cl_pc)
check(toasted("нет в вашей папке Radio") == nil, "R6: the note only once")
deliver("VRADIO", rmsg(truck, true, false, 0.8, 1.0, 0, "Zulu.mp3"), cl_pc)
check(rc._p.CurrentSong == own, "R6: the same stand-in for the same missing track")

print("R7. a client in the session asks: every radio state")
ready(mp)
T = T + 0.5
V.tick()
sent = {}
deliver("VRADIOQ", {}, cl2_pc)
m = last_radio(cl2_pc)
check(m and m[10] == "Zulu.mp3" and tonumber(m[9]) and tonumber(m[9]) >= 0, "R7: the truck's state with a position sent to the asking client")
check(said("Friend2 is in the session: 1 vehicle radio state(s) sent") ~= nil, "R7: logged")

print("R8. every 10 s: the states again")
sent = {}
T = T + 10
V.tick()
check(last_radio(cl_pc) ~= nil and last_radio(cl2_pc) ~= nil, "R8: repeated to every client")

print("R9. a radio already playing on the host's copy (turned on before anyone joined)")
local van = new_vehicle("Vehicle_PickupTruck_C_2147470001", { X = 4000, Y = 0, Z = 80 })
local vrc, vmp = add_radio(van, HOST_FILES)
W.play(vrc)
ready(vmp)
sent = {}
T = T + 6
V.tick()
m = radio_at(cl_pc, "4000")
check(m and m[5] == "1" and m[10] == "Charlie.mp3" and radio_at(cl2_pc, "4000") ~= nil, "R9: taken as the van's state and sent to every client")
check(said("found playing on the host's copy") ~= nil, "R9: logged")

print("R10. vehicle_radio off on the host: a client's change is not taken")
cfg.set("vehicle_radio", false)
sent = {}
plays0 = rc._calls.play
deliver("VRADIO", rmsg(truck, true, false, 0.8, 1.0, 0, "Alpha.mp3"), cl_pc)
check(rc._calls.play == plays0 and #radios() == 0, "R10: nothing applied or passed on")
cfg.set("vehicle_radio", true)
print("status: " .. V.status_line())
check(V.status_line():find("radio=true", 1, true) ~= nil, "status line has the radio part")

-- ------------------------------------------------------------ client side
print("C0. client: in the session -> asks the host once")
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
controllers = { cl_pc }   -- a client has only its own controller
ctx.reset()
truck._valid, van._valid = false, false
local ctruck = new_vehicle("Vehicle_FlatbedTruck_C_2147400001", { X = 1050, Y = 0, Z = 80 })
ctruck._p.Role = 1
local CLIENT_FILES = { "bravo.MP3", "Delta.mp3" }
local crc, cmp, cms = add_radio(ctruck, CLIENT_FILES)
sent = {}
V.tick()
check(kinds("VRADIOQ") == 1, "C0: VRADIOQ sent")
T = T + 0.5
V.tick()
check(kinds("VRADIOQ") == 1, "C0: only once")
deliver("VCAP", { "1" }, cl_pc)

print("C1. the host's state: the same file here (other letter case), position and speed once it plays")
sent = {}
deliver("VRADIO", rmsg(ctruck, true, false, 0.8, 1.5, 42, "Bravo.mp3"), cl_pc)
check(crc._p["TurnedOn?"] == true and crc._p.CurrentSong == "bravo.MP3" and url_song(cmp) == "bravo.MP3" and crc._calls.start == 1,
    "C1: this copy opened its own bravo.MP3 (StartRadio + CurrentSong + Event_PlayCurrentRadioSong)")
check(cms._p.mult == 0.8 and crc._p.Volume == 0.8 and cms._p.active == true, "C1: volume 0.8 on the vehicle's MediaSound")
T = T + 0.5
V.tick()
check(cmp._st.seeks == 0, "C1: no jump before the track plays")
-- the host's next state while the track still opens here (its volume changed)
deliver("VRADIO", rmsg(ctruck, true, false, 0.7, 1.5, 42.5, "Bravo.mp3"), cl_pc)
check(crc._calls.play == 1 and cms._p.mult == 0.7 and cmp._st.opening == true and cmp._st.seeks == 0,
    "C1: a second state while the track opens: no reopen, the volume now, position / speed kept for when it plays")
ready(cmp)
T = T + 0.5
V.tick()
check(cmp._st.seeks == 1 and close(cmp._st.t, 42.5 + 0.5 * 1.5, 0.01),
    "C1: jumped to the host's latest position + the time since at x1.5 (" .. cmp._st.t .. ")")
check(cmp._st.rate == 1.5 and crc._p.PlayRate == 1.5, "C1: speed x1.5 once it plays")
check(#radios() == 0, "C1: nothing sent back")
check(said("\"bravo.MP3\" plays here now: position 0:43") ~= nil, "C1: logged")

print("C2. the host's repeat of the same state")
local plays = crc._calls.play
deliver("VRADIO", rmsg(ctruck, true, false, 0.7, 1.5, 52, "Bravo.mp3"), cl_pc)
check(crc._calls.play == plays and cmp._st.seeks == 1 and cmp._st.rate == 1.5, "C2: changes nothing")

print("C3. a track not in this machine's Radio folder")
local ECHO = "Echo.mp3"
for i = 1, 20 do
    if stand_in(CLIENT_FILES, ECHO) ~= "bravo.MP3" then break end
    ECHO = "Echo" .. i .. ".mp3"
end
toasts = {}
deliver("VRADIO", rmsg(ctruck, true, false, 0.8, 1.0, 0, ECHO), cl_pc)
local cown = crc._p.CurrentSong
check(cown == "Delta.mp3" and url_song(cmp) == "Delta.mp3", "C3: its own stand-in plays (" .. tostring(cown) .. ")")
check(toasted(ECHO) ~= nil and toasted("нет в вашей папке Radio") ~= nil, "C3: the note on screen")
check(said("the sender's track is not in this machine's Radio folder") ~= nil, "C3: logged")

print("C4. pause / resume / speed / volume on the same track")
ready(cmp)
T = T + 0.5
V.tick()
deliver("VRADIO", rmsg(ctruck, true, true, 0.8, 1.0, 5, ECHO), cl_pc)
check(cmp._st.paused == true and crc._p["Paused?"] == true and crc._calls.play == plays + 1, "C4: paused (Paused? + MediaPlayer.Pause), no reopen")
deliver("VRADIO", rmsg(ctruck, true, false, 0.6, 2.0, 5, ECHO), cl_pc)
check(cmp._st.playing == true and cmp._st.rate == 2.0 and crc._p["Paused?"] == false and cms._p.mult == 0.6,
    "C4: resumed (MediaPlayer.Play) at x2.0, volume 0.6")

print("C5. this player sits in the truck and presses Next: sent to the host; an older host state skipped")
cl_ch._parent = ctruck
sent = {}
T = T + 0.5
V.tick()
check(#radios("host") == 0, "C5: sitting down is no change")
W.next(crc)
T = T + 0.5
V.tick()
m = last_radio("host")
check(m and m[5] == "1" and m[10] == crc._p.CurrentSong and m[10] == "bravo.MP3" and m[8] == "1.00",
    "C5: the new track sent to the host (speed 1: the game plays a new track at 1)")
check(said("this player changed the radio in Vehicle_FlatbedTruck_C_2147400001") ~= nil, "C5: logged")
deliver("VRADIO", rmsg(ctruck, true, false, 0.6, 2.0, 5, ECHO), cl_pc)
check(url_song(cmp) == "bravo.MP3", "C5: the host's state from before our change skipped")
T = T + 3
deliver("VRADIO", rmsg(ctruck, true, false, 0.6, 1.0, 0, "Delta.mp3"), cl_pc)
check(url_song(cmp) == "Delta.mp3", "C5: a later host state applies again")
ready(cmp)
T = T + 0.5
V.tick()
T = T + 0.5
V.tick()
check(#radios("host") == 1, "C5: applying it is not sent back as this player's change")

print("C6. a machine with no music in its Radio folder")
cl_ch._parent = nil
local fl = V.radio._t.files()
fl.set, fl.lower, fl.sorted, fl.n = {}, {}, {}, -1
crc._p["Found Files"] = tarray({})
toasts = {}
plays = crc._calls.play
deliver("VRADIO", rmsg(ctruck, true, false, 0.6, 1.0, 0, "Foxtrot.mp3"), cl_pc)
check(crc._calls.play == plays, "C6: nothing opened")
check(toasted("нет музыки") ~= nil, "C6: the note on screen")
check(said("no music in this machine's Radio folder") ~= nil, "C6: logged")
toasts = {}
local n_infos = #infos
T = T + 10
deliver("VRADIO", rmsg(ctruck, true, false, 0.6, 1.0, 30, "Foxtrot.mp3"), cl_pc)
check(#toasts == 0 and #infos == n_infos, "C6: the host's repeat: no second note, no retry, no log line")
crc._p["Found Files"] = tarray(list_copy(CLIENT_FILES))

print("C7. a vehicle not here, then the host says off")
deliver("VRADIO", with({ "90000", "90000", "0", ctruck._cls }, "1", "0", "0.50", "1.00", "0.0", "Delta.mp3"), cl_pc)
check(crc._calls.stop == 0, "C7: a state for a vehicle not here changes nothing")
deliver("VRADIO", rmsg(ctruck, false, false, 0.6, 1.0, -1, ""), cl_pc)
check(crc._p["TurnedOn?"] == false and crc._calls.stop == 1 and cmp._st.url == "" and cms._p.active == false, "C7: StopRadio on this copy")

print("C8. vehicle_radio off: nothing applied, nothing sent")
cfg.set("vehicle_radio", false)
plays = crc._calls.play
deliver("VRADIO", rmsg(ctruck, true, false, 0.6, 1.0, 0, "Delta.mp3"), cl_pc)
check(crc._calls.play == plays and crc._p["TurnedOn?"] == false, "C8: the host's state not applied")
cl_ch._parent = ctruck
sent = {}
W.play(crc)
T = T + 0.5
V.tick()
T = T + 0.5
V.tick()
check(#radios("host") == 0, "C8: this player's change not sent")
cfg.set("vehicle_radio", true)

print("status: " .. V.status_line())
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
