-- A client's refuel / repair END TO END with TWO machines: the host and one
-- client, each with its own copy of the mod's modules (sdc_vehicles,
-- sdc_vehseats, sdc_ctx, sdc_net, sdc_ue, ...), of the world and of the
-- vehicle; every message goes through sdc_net's encode / decode to the other
-- machine's handler. 13.11 (0.11.0): "the client cannot refuel or repair
-- vehicles" - in the game the note "No gas found" / "No repair kits found"
-- never reached the mod's hook, so a client's repair never asked the host
-- (its refuel got through only by UseGasCan's own hook).
-- The game as BP_VehicleMaster runs it on the machine whose key was pressed:
-- the fuel / repair box overlap (OnBegin/End...Interact: one flag, one option,
-- one IsHeld per vehicle, cleared by ANY player leaving), the option
-- (OnExecuteInteract: @17947 a press during a hold only clears IsHeld;
-- @18506 / @19447 IsHeld, "Gas full" / "Vehicle repaired", FindJigItemByDA on
-- the inventory as this machine sees it, the timer bar, the montage,
-- RetriggerableDelay(Duration)), the hold's end (@1866 UseGasCan / @1902 the
-- kit branch: IsHeld first, then ServerFindThenConsumeByItemID on
-- MainJigContainers - the host's data, empty on a client - +Max/2 or the
-- note). The note reaches the mod's hook only where a case says so
-- (note_live), as in the game.
--   E1 refuel, E2 repair: outside, an empty car - the whole round: press,
--      hold, the game's last step, VFUEL / VREPAIR, the host takes the item
--      and adds, VBOXR, the client sees it, VSTATE agrees.
--   E3 the note reaching the mod: one ask per hold all the same.
--   E4 the parked car: the client drove, the host stays in seat 2 (the wheel
--      free, handbrake on, timers off); the client repairs / refuels outside.
--   E5 after the seat key: the client in seat 2 -> 3 -> the wheel, out; then
--      repair / refuel.
--   E6 walking off as the bar fills (kept) / during the hold (nothing);
--      another player leaving the box during the hold (given back) or just
--      after it (the flag not set again); another option during the hold
--      (nothing); the game's own item check failing (flag cleared, nothing);
--      out of the box unseen (nothing); the key again / getting in right as
--      the bar fills (the first hold still asked); the flag down mid-hold by
--      an unseen path (nothing before the hold's time).
--   E7 the host has no kit for it / the tank full there: the game's note,
--      nothing taken.
--   E8 the host repairs the car itself during the client's hold: asked, "full".
--   E9 a client whose own take works: its add sent once, nothing on top.
--   E10 the host's own repair: the game's own step, nothing on the wire.
--   E11 two cars side by side, the client in the boxes of both (the game's
--      IsHeld and delay are per vehicle: a hold on each): repair on car 1,
--      then on car 2 during the first hold - both asked, the timer bar kept
--      for the hold still running; a second press on car 2 stops only car
--      2's hold; the host leaving car 1's box gives back car 1's hold while
--      car 2's runs, and raises no flag on car 1 when the client holds only
--      car 2; two presses at once - both seen in one tick; repair on car 1 +
--      refuel on car 3.
-- usage: lua mock_vehicles_boxes_e2e.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local real_print = print
local fails, passes = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; real_print("  ok   " .. what) else real_print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ machines
local ME = nil            -- the machine whose game thread runs now
local machines = {}
print = function(...) real_print(ME and ("<" .. ME.name .. ">") or "<->", ...) end

local function sdc_loaded()
    local t = {}
    for k, v in pairs(package.loaded) do
        if type(k) == "string" and k:sub(1, 4) == "sdc_" then t[k] = v end
    end
    return t
end
-- the machine's own module copies in package.loaded (each module keeps
-- its own upvalues; this is for the lazy package.loaded[...] lookups)
local function use(m)
    if ME then for k, v in pairs(sdc_loaded()) do ME.loaded[k] = v end end
    for k in pairs(sdc_loaded()) do package.loaded[k] = nil end
    ME = m
    if m then for k, v in pairs(m.loaded) do package.loaded[k] = v end end
end
local function in_m(m, fn, ...)
    local prev = ME
    use(m)
    local r = table.pack(pcall(fn, ...))
    use(prev)
    if not r[1] then error(r[2], 2) end
    return table.unpack(r, 2, r.n)
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
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

-- an object of the machine whose code runs now (ME)
local function new_obj(cls, short, props, methods, also)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true, _mach = ME }
    setmetatable(o, Obj)
    local reg = ME.registry
    reg[cls] = reg[cls] or {}
    table.insert(reg[cls], o)
    for _, c in ipairs(also or {}) do reg[c] = reg[c] or {}; table.insert(reg[c], o) end
    return o
end
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

-- ------------------------------------------------------------ UE4SS globals (per machine)
function RegisterHook(path, pre, post) ME.hooks[path] = { pre = pre, post = post }; return 1, 2 end
function FindAllOf(cls)
    local l = {}
    for _, o in ipairs(ME.registry[cls] or {}) do if o._valid then l[#l + 1] = o end end
    return l
end
function FindFirstOf(cls) return FindAllOf(cls)[1] end
function StaticFindObject(path) return ME.by_path[path] end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(ms, f) delayed[#delayed + 1] = { m = ME, f = f }; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay(ms, f) delayed[#delayed + 1] = { m = ME, f = f } end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end
local function run_delayed()
    local d = delayed
    delayed = {}
    for _, e in ipairs(d) do in_m(e.m, e.f) end
end

local timers = {}
local function tkey(o, fn) return tostring(o._addr) .. "|" .. fn end
local VEH = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local CHAR_HOOK = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:VehicleInteraction"
local NOTE_HOOK = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"
local GFL_PATH = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local GAS_PATH = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan"
local KIT_PATH = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit"
local NOTE_MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local OPT_GAS, OPT_KIT = "Jig.InteractOptions.RefuelVehicle", "Jig.InteractOptions.RepairVehicle"
local OPT_IN, OPT_INSPECT = "Jig.InteractOptions.Interact", "Jig.InteractOptions.Inspect"

-- The players' inventories as the HOST keeps them (MainJigContainers there);
-- a client's own widgets show its own (replicated), its MainJigContainers
-- are empty.
local INV = { host = { gas = 0, kit = 0 }, client = { gas = 0, kit = 0 } }

-- ------------------------------------------------------------ the wire
local wire = {}
local function sent_kinds(kind, from)
    local l = {}
    for _, w in ipairs(wire) do
        if w.kind == kind and (from == nil or w.from == from) then l[#l + 1] = w end
    end
    return l
end
local function count(kind, from) return #sent_kinds(kind, from) end
local function last(kind, from) local l = sent_kinds(kind, from); return l[#l] end

local function flush()
    local i = 1
    while i <= #wire do
        local w = wire[i]
        if not w.done then
            w.done = true
            local target = w.target
            in_m(target, function()
                local kind, fields = target.net.decode(w.raw)
                w.fields = fields
                local h = target.net.handlers[kind]
                if h then
                    local ok, err = pcall(h, fields, w.via)
                    if not ok then check(false, "handler " .. kind .. " on " .. target.name .. ": " .. tostring(err)) end
                else
                    target.no_handler[#target.no_handler + 1] = kind
                end
            end)
        end
        i = i + 1
    end
end

-- ------------------------------------------------------------ one machine
local function machine(name, role)
    local m = { name = name, role = role, registry = {}, hooks = {}, loaded = {}, controllers = {},
                infos = {}, warns = {}, toasts = {}, vehicles = {}, chars = {}, no_handler = {}, note_live = false,
                vp = {} }
    machines[name] = m
    local prev = ME
    use(m)
    m.by_path = setmetatable({}, { __index = function(t, k)
        if k:find(":") then local o = new_obj("Function", k); rawset(t, k, o); return o end
        return nil
    end })
    m.ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return role == "host" end,
        K2_IsTimerActive = function(_, o, fn) return timers[tkey(o, fn)] == true end,
        K2_SetTimer = function(_, o, fn) timers[tkey(o, fn)] = true end,
        K2_ClearTimer = function(_, o, fn) timers[tkey(o, fn)] = nil end,
        CapsuleTraceSingle = function() return false end,
    })
    rawset(m.by_path, "/Script/Engine.Default__KismetSystemLibrary", m.ksl)
    m.gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {
        GetPlayerController = function(_, wc, i) return m.controllers[i + 1] end,
        GetNumPlayerControllers = function() return #m.controllers end,
    })
    rawset(m.by_path, "/Script/Engine.Default__GameplayStatics", m.gps)
    m.montage = new_obj("AnimMontage", "Chr_SitInCar_Montage", {}, {})
    rawset(m.by_path, "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage", m.montage)
    m.gas_da = new_obj("JigItemDataAsset", "DA_GasCan", {}, {})
    m.kit_da = new_obj("JigItemDataAsset", "DA_VehicleRepairKit", {}, {})
    rawset(m.by_path, GAS_PATH, m.gas_da)
    rawset(m.by_path, KIT_PATH, m.kit_da)
    -- modules: fresh copies for this machine
    m.cfg = require("sdc_config")
    m.cfg.load(os.tmpname())
    m.log = require("sdc_log")
    m.log.toast_sink = function(text) m.toasts[#m.toasts + 1] = text end
    local info0, warn0 = m.log.info, m.log.warn
    m.log.info = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        m.infos[#m.infos + 1] = ok and s or fmt
        return info0(fmt, ...)
    end
    m.log.warn = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        m.warns[#m.warns + 1] = ok and s or fmt
        return warn0(fmt, ...)
    end
    m.ctx = require("sdc_ctx")
    m.net = require("sdc_net")
    -- (to = a host-side controller of a client, or "host")
    local function push(to, kind, ...)
        local target, via
        if to == "host" then
            target = machines.host
            via = target.pc_of_client
        else
            target = to._client
            via = target and target.local_pc
        end
        if not target then return false end
        wire[#wire + 1] = { from = m.name, to = target.name, kind = kind, raw = m.net.encode(kind, ...), target = target, via = via, t = T }
        return true
    end
    m.net.send_to = function(pc, kind, ...) return push(pc, kind, ...) end
    m.net.send_to_host = function(kind, ...) return push("host", kind, ...) end
    m.net.broadcast = function(pcs, kind, ...) for _, pc in ipairs(pcs) do push(pc, kind, ...) end end
    m.V = require("sdc_vehicles")
    m.S = role == "host" and { role = "host", remote = {}, remote_pcs = {} }
        or { role = "client", client = { acked = true }, remote = {}, remote_pcs = {} }
    use(prev)
    return m
end

local function said(m, pat, since)
    for i = (since or 0) + 1, #m.infos do if m.infos[i]:find(pat, 1, true) then return m.infos[i] end end
    return nil
end
local function warned(m, pat, since)
    for i = (since or 0) + 1, #m.warns do if m.warns[i]:find(pat, 1, true) then return m.warns[i] end end
    return nil
end

-- player 0 on machine m for an object (the ctx pre-hook may change the index)
local function player0(m, wco, fname)
    fname = fname or "GetPlayerCharacter"
    local h = m.hooks["/Script/Engine.GameplayStatics:" .. fname]
    local idx = param(0)
    if h and h.pre then h.pre(param(m.gps), param(wco), idx) end
    local pc = m.controllers[(idx:get() or -1) + 1]
    if fname == "GetPlayerController" then return pc end
    return pc and pc._p.Pawn or nil
end
local function fire_post(m, fn, ...)
    local h = m.hooks[VEH .. ":" .. fn]
    if h and h.pre then h.pre(...) end   -- BP hooks: the only callback = after the body
end

-- ------------------------------------------------------------ characters
local function key_of(m, da) return da == m.gas_da and "gas" or da == m.kit_da and "kit" or "?" end
local function new_char(m, name, who, is_local)
    local cmc = new_obj("CharacterMovementComponent", name .. "_CMC", { MovementMode = 1, bServerAcceptClientAuthoritativePosition = true }, {})
    cmc._m.SetMovementMode = function(s, mm) s._p.MovementMode = mm end
    local dc = new_obj("VehicleDrivingComponent_C", name .. "_VDC", {}, {})
    local helper = new_obj("BP_JigHelperComp_C", name .. "_Helper", {}, {})
    local ch = new_obj("BP_PlayerCharacter_C", name, { __loc = { X = 0, Y = 0, Z = 100 }, CharacterMovement = cmc,
        VehicleDrivingComponent = dc, BP_JigHelperComp = helper, ["InVehicle?"] = false, ["PlayerDead?"] = false }, {})
    dc._outer = ch
    helper._owner = ch
    ch._local = is_local
    ch._who = who
    ch._pid = who == "host" and 256 or 257
    local pid = ch._pid
    local ps = new_obj("PlayerState", name .. "_PS", {}, { GetPlayerId = function() return pid end, GetPlayerName = function() return name end })
    local cap = new_obj("CapsuleComponent", name .. "_Capsule", { cam = 2 }, {})
    cap._m.UnWeldFromParent = function() ch._welded = false end
    cap._m.GetCollisionResponseToChannel = function(c, n) if n == 4 then return c._p.cam end return 2 end
    cap._m.SetCollisionResponseToChannel = function(c, n, r) if n == 4 then c._p.cam = r end end
    local mesh = new_obj("SkeletalMeshComponent", name .. "_Mesh", { vis = 2, cam = 2, bOnlyAllowAutonomousTickPose = not is_local }, {})
    mesh._m.GetCollisionResponseToChannel = function(mm, c) if c == 3 then return mm._p.vis elseif c == 4 then return mm._p.cam end return 2 end
    mesh._m.SetCollisionResponseToChannel = function(mm, c, r) if c == 3 then mm._p.vis = r elseif c == 4 then mm._p.cam = r end end
    ch._p.PlayerState, ch._p.CapsuleComponent, ch._p.Mesh = ps, cap, mesh
    ch._m.ActorHasTag = function(_, n) return (n.ToString and n:ToString() or n) == "Player" end
    ch._m.IsLocallyControlled = function(s) return s._local == true end
    ch._m.K2_AttachToActor = function(s, parent, _sock, _l, _r, _sc, weld) s._parent = parent; s._welded = weld == true end
    ch._m.K2_DetachFromActor = function(s) s._parent = nil; s._welded = false end
    ch._m.StopMontage = function() end
    ch._m.K2_SetActorLocationAndRotation = function(s, l, r) s._p.__loc = { X = l.X, Y = l.Y, Z = l.Z }; s._rot = r end
    ch._m.PlayMontage = function(s, mm) s._montage = mm end
    ch._m.PlayAnimMontage = function(s, mm) s._montage = mm end
    ch._m.GetCurrentMontage = function(s) return s._montage end
    ch._m.StopAnimMontage = function(s) s._montage = nil end
    ch._m.SetWeaponsAndBackpackVisibility = function(s, hide) s._weapons_hidden = hide end
    ch._m.ResetVehicleCameraArmLength = function() end
    ch._m.VehicleInteraction = function(s, enter, vref)
        s._p["InVehicle?"] = enter
        if enter then
            dc._p.Vehicle = vref; cmc._p.MovementMode = 0; s._weapons_hidden = true
        else
            dc._p.Vehicle = nil; s._weapons_hidden = false
        end
        local h = m.hooks[CHAR_HOOK]
        if h and h.pre then h.pre(param(s), param(enter), param(vref)) end
    end
    -- the inventory: FindJigItemByDA reads what this machine shows (the
    -- host: everyone's; a client: its own), ServerFindThenConsumeByItemID
    -- walks MainJigContainers (the host's data; a client: empty)
    local jig = new_obj("BP_JigComponent_C", name .. "_Jig", {}, {})
    jig._m.FindJigItemByDA = function(_, da, _t, _a, _b, _c, out)
        local view = (m.role == "host" or is_local) and INV[who] or {}
        if ch._view then view = ch._view end
        out.Result = (view[key_of(m, da)] or 0) >= 1
    end
    jig._m.ServerFindThenConsumeByItemID = function(s, da, n, out)
        local k = key_of(m, da)
        s._takes = (s._takes or 0) + 1
        local main = m.role == "host" and INV[who] or {}
        -- (E9: a client whose own take works - not the game as of 13.11)
        if m.role ~= "host" and is_local and m.own_take then main = m.own_take end
        if (main[k] or 0) >= (n or 1) then
            main[k] = main[k] - (n or 1)
            out.Result = true
        else
            out.Result = false
        end
    end
    ch._p.BP_JigMultiplayer = jig
    m.chars[#m.chars + 1] = ch
    return ch
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

-- GameFunctionLibrary_C.CreateNotificationUI: a widget in player 0's box; the
-- mod's hook only where note_live (13.11: in the game it never got these)
local function give_gfl(m)
    m.note_calls = {}
    local gfl = new_obj("GameFunctionLibrary_C", "Default__GameFunctionLibrary_C", {}, {})
    gfl._m.CreateNotificationUI = function(self, msg, icon, col, delay, force, wco)
        m.note_calls[#m.note_calls + 1] = { text = msg, wco = wco }
        local pc = player0(m, wco, "GetPlayerController")
        local hud = pc and pc._m.GetHUD and pc:GetHUD()
        if hud then
            local w = new_obj("NotificationWidget_C", "Note_" .. tostring(next_addr), { NotificationDetailsStruct = { [NOTE_MSG] = msg } }, {})
            w._m.RemoveFromParent = function(s)
                for i, x in ipairs(hud._box._kids) do if x == s then table.remove(hud._box._kids, i) break end end
            end
            hud._box._kids[#hud._box._kids + 1] = w
        end
        local mod_text = msg == "No gas found" or msg == "No repair kits found"
        if m.note_live or not mod_text then
            local h = m.hooks[NOTE_HOOK]
            if h and h.pre then h.pre(param(self), param(msg), param(icon), param(col), param(delay), param(force), param(wco)) end
        end
    end
    rawset(m.by_path, GFL_PATH, gfl)
    m.gfl = gfl
end

-- ------------------------------------------------------------ the vehicle (per machine)
-- Facing +X; PlayerLocation 20 cm ahead, 40 cm left, 50 cm up; doors 200 cm
-- to each side. The fuel box at the rear left, the repair box at the front.
local FUEL_BOX = { dx = -250, dy = -150, hx = 100, hy = 100 }
local REPAIR_BOX = { dx = 320, dy = 0, hx = 100, hy = 150 }
local function in_box(v, b, l)
    local o = v._p.__loc
    return math.abs(l.X - (o.X + b.dx)) <= b.hx and math.abs(l.Y - (o.Y + b.dy)) <= b.hy
end
local function new_vehicle(m, name, loc, cls, role)
    local mc = new_obj("ChaosWheeledVehicleMovementComponent", name .. "_VMC",
        { bRequiresControllerForInputs = false, bUpdateOnlyIfRendered = true, hb = true }, {})
    mc._m.SetRequiresControllerForInputs = function(s, b) s._p.bRequiresControllerForInputs = b end
    mc._m.SetHandbrakeInput = function(s, b) s._p.hb = b end
    mc._m.SetBrakeInput = function() end
    mc._m.SetThrottleInput = function() end
    mc._m.SetSteeringInput = function() end
    mc._m.GetForwardSpeedMPH = function() return 0 end
    local fc = new_obj("VehicleFuelComponent_C", name .. "_Fuel", { CurrentFuel = 300, MaxFuel = 1000, Empty = false }, {})
    fc._m.StartFuelSpend = function(s) timers[tkey(s, "FuelSpend")] = true end
    fc._m.StopSpendFuel = function(s) timers[tkey(s, "FuelSpend")] = nil end
    fc._m.AddFuel = function(s, frac)
        s._p.CurrentFuel = math.min(s._p.MaxFuel, s._p.CurrentFuel + frac * s._p.MaxFuel)
        s._p.Empty = s._p.CurrentFuel <= 0
        s._addfuel = (s._addfuel or 0) + 1
    end
    fc._m.UpdateUIFuel = function() end
    local hc = new_obj("VehicleHealthComponent_C", name .. "_Health", { CurrentHealth = 80, MaxHealth = 125 }, {})
    hc._m.UpdateUIHealth = function() end
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
    local v
    local inbox = { fuel = {}, repair = {} }
    local fbox = new_obj("BoxComponent", name .. "_FuelBox", {}, { IsOverlappingActor = function(_, a) return inbox.fuel[a] == true end })
    local rbox = new_obj("BoxComponent", name .. "_RepairBox", {}, { IsOverlappingActor = function(_, a) return inbox.repair[a] == true end })
    local fw = new_obj("BP_FuelWidget_C", name .. "_FuelW", {}, { UpdateFuel = function(s, a, b) s._shown = { a, b } end })
    local rw = new_obj("BP_RepairWidget_C", name .. "_RepairW", {}, { UpdateHealth = function(s, a, b) s._shown = { a, b } end })
    v = new_obj(cls, name, {
        __loc = loc, VehicleMovementComponent = mc, FuelComponent = fc, VehicleHealthComponent = hc,
        EngineSound = snd, Mesh = mesh, HitBoxCollision = hb, PlayerLocation = pl, Colors = tarray({}),
        Tags = tarray({ FName("Vehicle") }), ["LightsOn?"] = false, ["EngineOn?"] = true, VehicleColor = 0, Role = role,
        Duration = 10, IsHeld = false, ["InRefuellingArea?"] = false, ["InRepairingArea?"] = false,
        InteractOptions = { [OPT_IN] = true }, FuelBoxCollision = fbox, RepairBoxCollision = rbox,
        FuelWidget = new_obj("WidgetComponent", name .. "_FuelWC", {}, { GetUserWidgetObject = function() return fw end }),
        RepairWidget = new_obj("WidgetComponent", name .. "_RepairWC", {}, { GetUserWidgetObject = function() return rw end }),
    }, {}, { "BP_VehicleMaster_C" })
    for _, c in ipairs({ mc, fc, hc, snd, mesh, hb, pl, fbox, rbox }) do c._outer = v end
    v._resp, v._fw, v._rw, v._inbox = resp, fw, rw, inbox
    local p = v._p
    v._m.GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end
    v._m.GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end
    v._m.GetActorUpVector = function() return { X = 0, Y = 0, Z = 1 } end
    v._m.VehicleEngineFX = function(s, on) s._fx = on end
    v._m.TurnOnOffLights = function(self) p["LightsOn?"] = not p["LightsOn?"] end
    v._m.Horn = function() end
    local function hud0() local c = player0(m, v, "GetPlayerController"); return c and c._m.GetHUD and c:GetHUD() or nil end
    local function note(text) m.gfl:CreateNotificationUI(text, nil, { R = 1, G = 1, B = 1, A = 1 }, 2, false, v) end
    -- the game's get-in (player 0 attached, welded, sits, services; 0.1 s
    -- later VehicleInteraction(true))
    v._m.Interact_GetInVehicle = function(self)
        mc:SetHandbrakeInput(false)
        resp[2], resp[4] = 0, 0
        local ch = player0(m, self)
        ch:K2_AttachToActor(self, FName("None"), 1, 1, 1, true)
        ch:K2_SetActorLocationAndRotation(pl:K2_GetComponentLocation(), {})
        ch:PlayMontage(m.montage, 1)
        local ui = new_obj("VehicleUI_C", "VehicleUI_" .. tostring(next_addr), {}, {})
        ui._m.RemoveFromParent = function(u) for i, w in ipairs(m.vp) do if w == u then table.remove(m.vp, i) end end end
        m.vp[#m.vp + 1] = ui
        p.VehicleUI = ui
        fc:StartFuelSpend()
        timers[tkey(self, "CheckWater")] = true
        snd:Activate(true); timers[tkey(self, "VehicleSound")] = true; timers[tkey(self, "Event_Noise")] = true
        self._entered_by = ch
        delayed[#delayed + 1] = { m = m, f = function() local c = player0(m, self); if c then c:VehicleInteraction(true, self) end end }
        fire_post(m, "Interact_GetInVehicle", param(self))
    end
    v._m.Event_ExitVehicle = function(self)
        local ch = player0(m, self)
        ch:K2_DetachFromActor(1, 1, 1)
        ch:StopAnimMontage(m.montage)
        snd:FadeOut(2.5, 0, 0)
        timers[tkey(self, "VehicleSound")] = nil
        timers[tkey(self, "CheckWater")] = nil
        timers[tkey(self, "Event_Noise")] = nil
        local ui = p.VehicleUI
        if ui then ui:RemoveFromParent() end
        p.VehicleUI = nil
        ch:K2_SetActorLocationAndRotation(mesh:GetSocketLocation(FName(p.GetOutPasseenger and "PassengerSide" or "DriverSide")), {})
        p.GetOutPasseenger = false
    end
    v._m.ExitVehicle = function(self)
        local ch = player0(m, self)
        self:Event_ExitVehicle()
        ch._p.CharacterMovement:SetMovementMode(1, 0)
        resp[2], resp[4] = 2, 2
        mc:SetHandbrakeInput(true)
        fc:StopSpendFuel()
        fire_post(m, "ExitVehicle", param(self), param(true))
        ch:VehicleInteraction(false, nil)
    end
    -- the boxes (@15292 / @16541 in, @14726 / @14038 out: ANY player)
    local function begin_box(kind, a)
        local flag = kind == "fuel" and "InRefuellingArea?" or "InRepairingArea?"
        if a:ActorHasTag(FName("Player")) and not a._p["InVehicle?"] and not p[flag] then
            p[flag] = true
            p.InteractOptions[kind == "fuel" and OPT_GAS or OPT_KIT] = true
        end
        fire_post(m, kind == "fuel" and "OnBeginFuelInteract" or "OnBeginRepairInteract", param(v), param(a))
    end
    local function end_box(kind, a)
        local flag = kind == "fuel" and "InRefuellingArea?" or "InRepairingArea?"
        if a:ActorHasTag(FName("Player")) then
            p.IsHeld = false
            local hud = hud0()
            if hud then hud:InteractTimerUI(false, "") end
            if p[flag] then
                p[flag] = false
                p.InteractOptions[kind == "fuel" and OPT_GAS or OPT_KIT] = nil
            end
        end
        fire_post(m, kind == "fuel" and "OnEndFuelInteract" or "OnEndRepairInteract", param(v), param(a))
    end
    v._m.OnBeginFuelInteract = function(_, a) begin_box("fuel", a) end
    v._m.OnEndFuelInteract = function(_, a) end_box("fuel", a) end
    v._m.OnBeginRepairInteract = function(_, a) begin_box("repair", a) end
    v._m.OnEndRepairInteract = function(_, a) end_box("repair", a) end
    -- this machine's overlaps after anyone moved (a seated character overlaps nothing)
    v._boxes = function()
        for _, kind in ipairs({ "fuel", "repair" }) do
            for _, ch in ipairs(m.chars) do
                local inside = ch._parent == nil and in_box(v, kind == "fuel" and FUEL_BOX or REPAIR_BOX, ch._p.__loc)
                local was = inbox[kind][ch] == true
                if inside and not was then
                    inbox[kind][ch] = true
                    begin_box(kind, ch)
                elseif was and not inside then
                    inbox[kind][ch] = nil
                    end_box(kind, ch)
                end
            end
        end
    end
    -- OnExecuteInteract (@17947 .. @20294), then the post hook
    v._m.OnExecuteInteract = function(self, who, tag)
        local function done() fire_post(m, "OnExecuteInteract", param(self), param(who), param({ TagName = FName(tag) })) end
        if p.IsHeld then p.IsHeld = false; return done() end      -- @17947: only cleared
        if tag == OPT_IN then self:Interact_GetInVehicle(); return done() end
        if tag ~= OPT_GAS and tag ~= OPT_KIT then return done() end
        p.IsHeld = true                                             -- @18506 / @19447
        local ch = player0(m, self)
        local jig = ch and ch._p.BP_JigMultiplayer
        local out = {}
        if tag == OPT_GAS then
            if fc._p.CurrentFuel == fc._p.MaxFuel then note("Gas full"); return done() end
            jig:FindJigItemByDA(m.gas_da, {}, true, false, 1, out)
            if not out.Result then return done() end                -- @18788: IsHeld stays
            local hud = hud0()
            if hud then hud:InteractTimerUI(true, "Refilling Vehicle") end
        else
            if hc._p.CurrentHealth > hc._p.MaxHealth - 1 then note("Vehicle repaired"); return done() end
            jig:FindJigItemByDA(m.kit_da, {}, true, false, 1, out)
            if not out.Result then return done() end                -- @19775: IsHeld stays
            local hud = hud0()
            if hud then hud:InteractTimerUI(true, "Repairing Vehicle") end
        end
        ch:PlayMontage("Chr_Interact_Looting_Montage", 1)
        -- RetriggerableDelay(Duration): a new hold restarts it
        self._hold = { tag = tag, at = T + p.Duration }
        done()
    end
    v._m.UseGasCan = function(self)
        local ch = player0(m, self)
        local out = {}
        ch._p.BP_JigMultiplayer:ServerFindThenConsumeByItemID(m.gas_da, 1, out)
        if out.Result then
            fc._p.CurrentFuel = math.min(fc._p.MaxFuel, fc._p.CurrentFuel + fc._p.MaxFuel / 2)
            fc._p.Empty = false
            local hud = hud0()
            if hud then hud:InteractTimerUI(false, "") end
        else
            note("No gas found")
        end
        fire_post(m, "UseGasCan", param(self))
    end
    -- the delay's end: @1866 / @1902
    v._hold_end = function()
        local h = v._hold
        v._hold = nil
        if not p.IsHeld then return end
        p.IsHeld = false
        if h.tag == OPT_GAS then return v:UseGasCan() end
        local ch = player0(m, v)
        local out = {}
        ch._p.BP_JigMultiplayer:ServerFindThenConsumeByItemID(m.kit_da, 1, out)
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
    m.vehicles[#m.vehicles + 1] = v
    return v
end

-- ------------------------------------------------------------ the two machines
local LOC = { X = 5000, Y = 0, Z = 80 }
local CLS = "Vehicle_SUV_C"   -- 4 seats (a rear row): the seat key has somewhere to go

local H = machine("host", "host")
local C = machine("client", "client")

in_m(H, function()
    give_gfl(H)
    H.host_ch = new_char(H, "HostChar", "host", true)
    H.host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = H.host_ch, Player = new_obj("LocalPlayer", "LP", {}, {}) },
        { IsLocalController = function() return true end }, { "PlayerController" })
    H.host_ch._p.Controller = H.host_pc
    H.hud = give_hud(H.host_pc)
    H.cl_ch = new_char(H, "ClientChar", "client", false)
    H.conn = new_obj("IpConnection", "Conn", {}, {})
    H.cl_pc = new_obj("BP_PlayerController_C", "ClientPC", { Pawn = H.cl_ch, NetConnection = H.conn }, {}, { "PlayerController" })
    H.cl_ch._p.Controller = H.cl_pc
    H.cl_ch._owner = H.cl_pc
    H.controllers = { H.host_pc, H.cl_pc }
    H.pc_of_client = H.cl_pc
    H.local_pc = H.host_pc
    local r = { key = H.cl_pc:GetFullName(), pc = H.cl_pc, name = "Friend", index = 1 }
    H.S.remote[r.key] = r
    H.S.remote_pcs = { H.cl_pc }
    H.client_key = r.key
    H.truck = new_vehicle(H, CLS .. "_2147480001", { X = LOC.X, Y = LOC.Y, Z = LOC.Z }, CLS, 3)
    H.V.install(H.S)
end)
in_m(C, function()
    give_gfl(C)
    C.cl_ch = new_char(C, "ClientChar", "client", true)
    C.cl_pc = new_obj("BP_PlayerController_C", "ClientPC", { Pawn = C.cl_ch, Player = new_obj("LocalPlayer", "LP2", {}, {}) },
        { IsLocalController = function() return true end }, { "PlayerController" })
    C.cl_ch._p.Controller = C.cl_pc
    C.cl_ch._owner = C.cl_pc
    C.hud = give_hud(C.cl_pc)
    C.host_ch = new_char(C, "HostChar", "host", false)   -- another player: no controller here
    C.controllers = { C.cl_pc }                          -- a client has only its own: player 0 = this player
    C.local_pc = C.cl_pc
    C.truck = new_vehicle(C, CLS .. "_2147400001", { X = LOC.X, Y = LOC.Y, Z = LOC.Z }, CLS, 1)
    C.V.install(C.S)
end)
H.cl_pc._client = C

-- every player has a copy on each machine
local P = { host = { H = H.host_ch, C = C.host_ch }, client = { H = H.cl_ch, C = C.cl_ch } }

-- the engine's replication of the host's character (its seat) to the client
local function replicate()
    local hh, ch = H.host_ch, C.host_ch
    local want = hh._parent == H.truck and C.truck or nil
    if ch._parent ~= want then
        ch._parent = want
        ch._p["InVehicle?"] = want ~= nil
    end
    if not want then ch._p.__loc = { X = hh._p.__loc.X, Y = hh._p.__loc.Y, Z = hh._p.__loc.Z } end
    -- the client's own character as the host has it (its moves reach the host)
    local cc, hcc = C.cl_ch, H.cl_ch
    if hcc._parent == nil and cc._parent == nil then hcc._p.__loc = { X = cc._p.__loc.X, Y = cc._p.__loc.Y, Z = cc._p.__loc.Z } end
end
local function boxes()
    in_m(H, function() for _, v in ipairs(H.vehicles) do if v._valid then v._boxes() end end end)
    in_m(C, function() for _, v in ipairs(C.vehicles) do if v._valid then v._boxes() end end end)
end
-- the game's latent delays whose time has come, on their machine
local function holds()
    for _, m in ipairs({ H, C }) do
        in_m(m, function()
            for _, v in ipairs(m.vehicles) do
                if v._valid and v._hold and T >= v._hold.at - 1e-6 then v._hold_end() end
            end
        end)
    end
end
local function tick_m(m)
    in_m(m, function()
        if m.role == "host" then m.ctx.tick(m.S.remote_pcs) else m.ctx.tick_client(true) end
        m.V.tick()
    end)
end
-- one 0.5 s step of the world: delays, the game's holds, both ticks, the wire
local function step(dt)
    T = T + (dt or 0.5)
    run_delayed()
    holds()
    replicate()
    boxes()
    tick_m(H); flush()
    tick_m(C); flush()
    run_delayed()
    flush()
    replicate()
    boxes()
end
local function run(secs) for _ = 1, math.floor(secs / 0.5 + 0.5) do step(0.5) end end
-- a player walks to loc (both machines see it)
local function place(who, loc)
    for _, ch in pairs(P[who]) do
        if ch._parent == nil then ch._p.__loc = { X = loc.X, Y = loc.Y, Z = loc.Z or 100 } end
    end
    boxes()
end
local function spot(b, dx) return { X = LOC.X + b.dx + (dx or 0), Y = LOC.Y + b.dy, Z = 100 } end
local AWAY_H, AWAY_C = { X = LOC.X - 900, Y = 700, Z = 100 }, { X = LOC.X + 900, Y = 700, Z = 100 }

-- on the client: its key on an option of its copy (the game's TryInteract)
local function press(opt) in_m(C, function() C.truck:OnExecuteInteract(C.cl_ch, opt) end); flush() end
local function host_press(opt)
    in_m(H, function()
        H.host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = H.truck
        H.truck:OnExecuteInteract(H.host_ch, opt)
        H.host_ch._p.BP_JigHelperComp._p.InteractExecutedActor = nil
    end)
    flush()
end
local function fuel(m) return m.truck._p.FuelComponent._p.CurrentFuel end
local function health(m) return m.truck._p.VehicleHealthComponent._p.CurrentHealth end
-- new values on the host's car (an earlier refuel / repair's report window,
-- fx.keep_s, over first), sent to the client with the next VSTATE
local function set_host_values(f, h)
    run(3.5)
    in_m(H, function()
        H.truck._p.FuelComponent._p.CurrentFuel = f
        H.truck._p.VehicleHealthComponent._p.CurrentHealth = h
        local st = H.V._t.vs()[H.truck._addr]
        if st then st.dirty = true end
    end)
end
local function parked_on_host()
    local v = H.truck
    return v._p.VehicleMovementComponent._p.hb == true and timers[tkey(v._p.FuelComponent, "FuelSpend")] == nil
        and timers[tkey(v, "Event_Noise")] == nil and timers[tkey(v, "CheckWater")] == nil
end
local function vfuels() return count("VFUEL", "client") end
local function vrepairs() return count("VREPAIR", "client") end

-- ------------------------------------------------------------ setup
print("setup")
place("host", AWAY_H)
place("client", AWAY_C)
run(3)
check(H.hooks[VEH .. ":OnExecuteInteract"] ~= nil and C.hooks[VEH .. ":OnExecuteInteract"] ~= nil
    and C.hooks[NOTE_HOOK] ~= nil and C.hooks[VEH .. ":UseGasCan"] ~= nil, "setup: both machines hooked the game's vehicle functions")
check(count("VCAP", "host") >= 1 and said(C, "the host runs the vehicle sync") ~= nil, "setup: the client knows the host runs the vehicle sync (VCAP over the wire)")
set_host_values(300, 30)
run(1)
check(fuel(C) == 300 and health(C) == 30, "setup: the client's copy has the host's fuel 300 and health 30 (VSTATE over the wire)")
check(#H.no_handler == 0 and #C.no_handler == 0, "setup: every message had a handler")

-- one whole client refuel / repair from outside; returns what happened
local function round(kind, opts)
    opts = opts or {}
    local is_gas = kind == "refuel"
    local box = is_gas and FUEL_BOX or REPAIR_BOX
    local n_ask = is_gas and vfuels() or vrepairs()
    local ni, nci = #H.infos, #C.infos
    place("client", spot(box))
    local flag = is_gas and "InRefuellingArea?" or "InRepairingArea?"
    local offered = C.truck._p[flag] == true and C.truck._p.InteractOptions[is_gas and OPT_GAS or OPT_KIT] == true
    press(is_gas and OPT_GAS or OPT_KIT)
    local started = C.truck._p.IsHeld == true and C.hud._p.InteractTimerWidget ~= nil
        and C.hud._timer_text == (is_gas and "Refilling Vehicle" or "Repairing Vehicle")
    run(5)
    local early = (is_gas and vfuels() or vrepairs()) - n_ask
    run(6)
    return { offered = offered, started = started, early = early, asks = (is_gas and vfuels() or vrepairs()) - n_ask, ni = ni, nci = nci }
end

-- ------------------------------------------------------------ E1 / E2
print("E1. refuel from outside an empty car: the whole round over the wire (the note does not reach the mod, as in the game)")
INV.client = { gas = 2, kit = 2 }
do
    local r = round("refuel")
    check(r.offered, "E1: the client in the fuel box: the game offers 'Refuel Vehicle' on its copy")
    check(r.started, "E1: the game's hold and timer bar 'Refilling Vehicle' on the client")
    check(r.early == 0, "E1: nothing asked while the hold runs")
    check(r.asks == 1, "E1: VFUEL went to the host once")
    local q = last("VFUEL", "client")
    check(q and q.fields[4] == CLS and tonumber(q.fields[6]) == 500, "E1: VFUEL: this car, +500 (half the tank, the game's step)")
    check(INV.client.gas == 1, "E1: exactly one gas can taken from the client's inventory on the host")
    check(fuel(H) == 800, "E1: the host's car 300 -> 800")
    check(last("VBOXR", "host") and last("VBOXR", "host").fields[1] == "refuel" and last("VBOXR", "host").fields[2] == "ok",
        "E1: the host answered VBOXR refuel ok")
    check(fuel(C) == 800 and C.truck._fw._shown and C.truck._fw._shown[1] == 800, "E1: the client sees 800 (its copy and the fuel widget)")
    check(not has_note(C.hud, "No gas found"), "E1: no false 'No gas found' left on the client's screen")
    check(C.hud._p.InteractTimerWidget == nil, "E1: the client's timer bar closed")
    check(said(H, "refuelled " .. H.truck._short .. ": 300 -> 800 of 1000", r.ni) ~= nil, "E1: host log: refuelled 300 -> 800, gas can taken")
    check(said(C, "the host did this player's refuel", r.nci) ~= nil, "E1: client log: the host did this player's refuel")
    run(2)
    check(fuel(C) == 800 and vfuels() == 1 + (0) and count("VFUEL", "client") == 1, "E1: the host's state agrees; nothing sent twice")
end

print("E2. repair from outside an empty car: the kit branch has no function to hook and its note does not reach the mod")
do
    local r = round("repair")
    check(r.offered and r.started, "E2: 'Repair Vehicle' offered, the game's hold 'Repairing Vehicle' on the client")
    check(r.early == 0, "E2: nothing asked while the hold runs")
    check(r.asks == 1, "E2: VREPAIR went to the host once (13.11: never)")
    local q = last("VREPAIR", "client")
    check(q and tonumber(q.fields[6]) == 62.5, "E2: VREPAIR: +62.5 (half of 125)")
    check(INV.client.kit == 1, "E2: exactly one repair kit taken from the client's inventory on the host")
    check(health(H) == 92.5 and H.truck._p["EngineOn?"] == true, "E2: the host's car 30 -> 92.5, engine on")
    check(health(C) == 92.5 and C.truck._rw._shown and C.truck._rw._shown[1] == 92.5, "E2: the client sees 92.5 (its copy and the repair widget)")
    check(not has_note(C.hud, "No repair kits found"), "E2: no false 'No repair kits found' left on the client's screen")
    check(said(C, "seen in the tick", r.nci) ~= nil, "E2: client log: asked from the tick at the hold's end")
    check(said(H, "repaired " .. H.truck._short .. ": 30 -> 92 of 125", r.ni) ~= nil, "E2: host log: repaired 30 -> 92 of 125, kit taken")
    run(2)
    check(health(C) == 92.5 and vrepairs() == 1, "E2: the host's state agrees; nothing sent twice")
end

print("E3. the note reaching the mod (as the design expected): still one ask per hold")
C.note_live = true
set_host_values(100, 20)
run(1)
do
    local nn = #C.infos
    local r = round("refuel")
    check(r.asks == 1 and fuel(H) == 600 and fuel(C) == 600 and INV.client.gas == 0, "E3: refuel: one VFUEL, 100 -> 600 on both, one gas can")
    check(said(C, "the game's note 'No gas found' seen here", nn) ~= nil, "E3: client log: the note seen (the in-game check line)")
    r = round("repair")
    check(r.asks == 1 and health(H) == 82.5 and health(C) == 82.5 and INV.client.kit == 0, "E3: repair: one VREPAIR, 20 -> 82.5 on both, one kit")
    check(said(C, "its note 'No repair kits found'", r.nci) ~= nil, "E3: asked by the note this time")
    run(2)
    check(vfuels() == 2 and vrepairs() == 2, "E3: nothing asked a second time by the tick")
end
C.note_live = false
place("client", AWAY_C)
run(1)

-- ------------------------------------------------------------ E4 the parked car
print("E4. the parked car: the client drove, the host stays in seat 2 (the wheel free); the client repairs / refuels outside")
INV.client = { gas = 1, kit = 1 }
set_host_values(250, 40)
run(1)
do
    place("client", { X = LOC.X + 20, Y = LOC.Y - 260, Z = 100 })   -- at the driver's door
    press(OPT_IN)
    run(1)
    local st = H.V._t.vs()[H.truck._addr]
    check(H.cl_ch._parent == H.truck and st and st.driver_key == H.client_key, "E4: the client drives (the host's copy)")
    check(C.V._t.local_seat() and C.V._t.local_seat().seat == "driver", "E4: the client's own record: driver")
    place("host", { X = LOC.X + 20, Y = LOC.Y + 260, Z = 100 })
    host_press(OPT_IN)
    run(1)
    check(H.host_ch._parent == H.truck and st.host_seat == "passenger", "E4: the host in seat 2")
    in_m(C, function() C.truck:ExitVehicle() end)
    flush()
    run(1)
    check(H.cl_ch._parent == nil and st.driver_key == nil and st.host_seat == "passenger", "E4: the client out; the host stays in seat 2")
    check(parked_on_host(), "E4: the host's car parked (handbrake on, no fuel spent, timers off)")
    check(C.cl_ch._p["InVehicle?"] == false and C.V._t.local_seat() == nil, "E4: the client is out on its own machine")
    local r = round("repair")
    check(r.offered and r.started, "E4: 'Repair Vehicle' offered and held on the client next to the parked car")
    check(r.asks == 1 and INV.client.kit == 0, "E4: VREPAIR once, the kit taken on the host")
    check(health(H) == 102.5 and health(C) == 102.5, "E4: 40 -> 102.5 on both machines")
    r = round("refuel")
    check(r.asks == 1 and INV.client.gas == 0 and fuel(H) == 750 and fuel(C) == 750, "E4: refuel: VFUEL once, 250 -> 750 on both")
    check(parked_on_host() and H.host_ch._parent == H.truck and st.host_seat == "passenger" and st.driver_key == nil,
        "E4: the car still parked with the host in seat 2")
    check(not warned(H, "driver only") and not said(H, "not the driver"), "E4: no 'driver only' refusal on the host")
    -- the host gets out: an empty car
    in_m(H, function() H.truck:ExitVehicle() end)
    flush()
    place("host", AWAY_H)
    place("client", AWAY_C)
    run(2)
    check(H.host_ch._parent == nil and st.host_seat == nil, "E4: the host out again")
end

-- ------------------------------------------------------------ E5 after the seat key
print("E5. after the seat key: the client in seat 2 -> seat 3 -> the wheel, out; then repair / refuel")
INV.client = { gas = 1, kit = 1 }
set_host_values(100, 10)
run(1)
do
    place("host", { X = LOC.X + 20, Y = LOC.Y - 260, Z = 100 })
    host_press(OPT_IN)
    run(1)
    local st = H.V._t.vs()[H.truck._addr]
    check(H.host_ch._parent == H.truck and st.host_seat == "driver", "E5: the host drives")
    place("client", { X = LOC.X + 20, Y = LOC.Y + 260, Z = 100 })
    press(OPT_IN)
    run(1)
    local ls = C.V._t.local_seat()
    check(st.pax[2] == H.client_key and ls and ls.seat == "passenger" and ls.idx == 2, "E5: the client in seat 2 (both machines)")
    in_m(C, function() C.V._t.seatk.on_key() end)
    flush()
    run(1)
    ls = C.V._t.local_seat()
    check(count("VSWITCH", "client") == 1 and ls and ls.idx == 3 and st.pax[3] == H.client_key, "E5: its seat key: seat 3")
    in_m(H, function() H.truck:ExitVehicle() end)
    flush()
    run(1)
    check(H.host_ch._parent == nil and st.driver_key == nil and parked_on_host(), "E5: the host out: the car parked, the wheel free")
    in_m(C, function() C.V._t.seatk.on_key() end)
    flush()
    run(1)
    ls = C.V._t.local_seat()
    check(ls and ls.seat == "driver" and st.driver_key == H.client_key, "E5: its seat key again: the wheel")
    in_m(C, function() C.truck:ExitVehicle() end)
    flush()
    run(3)
    check(H.cl_ch._parent == nil and st.driver_key == nil and C.V._t.local_seat() == nil, "E5: the client out (both machines)")
    check(C.cl_ch._p["InVehicle?"] == false, "E5: not 'in a vehicle' any more on its machine (the boxes take it)")
    place("host", AWAY_H)
    local r = round("repair")
    check(r.offered and r.started and r.asks == 1 and INV.client.kit == 0, "E5: repair after the seat moves: offered, held, VREPAIR once, kit taken")
    check(health(H) == 72.5 and health(C) == 72.5, "E5: 10 -> 72.5 on both machines")
    r = round("refuel")
    check(r.asks == 1 and INV.client.gas == 0 and fuel(H) == 600 and fuel(C) == 600, "E5: refuel: VFUEL once, 100 -> 600 on both")
    place("client", AWAY_C)
    run(1)
end

-- ------------------------------------------------------------ E6 the hold's edges
print("E6a. the client walks off just as the bar fills (the game's last step ran): still asked")
INV.client = { gas = 0, kit = 2 }
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(9.5)
    T = T + 0.5   -- the delay ends ...
    holds()
    check(C.truck._p.IsHeld == false and vrepairs() == n0, "E6a: the game's last step ran here (flag down), nothing asked yet")
    place("client", AWAY_C)   -- ... and the client walks off before the next tick
    run(1)
    check(vrepairs() == n0 + 1 and health(H) == 82.5 and health(C) == 82.5 and INV.client.kit == 1,
        "E6a: asked once all the same: 20 -> 82.5 on both, one kit")
    check(said(C, "walked off after its time") ~= nil, "E6a: client log says it walked off after the hold's time")
end

print("E6b. the client walks off during the hold: the game stops it, nothing asked")
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(4)
    place("client", AWAY_C)
    run(8)
    check(vrepairs() == n0 and health(H) == 20 and INV.client.kit == 1, "E6b: nothing asked, nothing added, the kit kept")
end

print("E6c. the host leaves the repair box during the client's hold: the hold given back, asked once")
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("host", spot(REPAIR_BOX, 40))
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(3)
    place("host", AWAY_H)   -- the game clears the flag and IsHeld for everyone on the client's copy
    check(C.truck._p.IsHeld == true and C.hud._p.InteractTimerWidget ~= nil, "E6c: the client's hold and timer bar given back at once")
    run(8)
    check(vrepairs() == n0 + 1 and health(H) == 82.5 and health(C) == 82.5 and INV.client.kit == 0, "E6c: asked once: 20 -> 82.5, the kit taken")
    place("client", AWAY_C)
    run(1)
end

print("E6d. another option on the car during the hold (the game's press only clears the flag): nothing asked")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(4)
    press(OPT_INSPECT)
    check(C.truck._p.IsHeld == false and said(C, "ended by another option") ~= nil, "E6d: the hold ended by the second press (logged)")
    run(8)
    check(vrepairs() == n0 and health(H) == 20 and INV.client.kit == 1, "E6d: nothing asked, nothing added")
    place("client", AWAY_C)
    run(1)
end

print("E6e. the game's own item check fails at the press (no kit shown here; the mod could not look): flag cleared, nothing asked")
do
    local n0 = vrepairs()
    local nw = #C.warns
    in_m(C, function()   -- the kit asset not in memory here (and not remembered by the mod)
        rawset(C.by_path, KIT_PATH, nil)
        local fxt = C.V._t.fx
        if fxt then fxt.da.repair = nil end
    end)
    C.cl_ch._view = { gas = 0, kit = 0 }
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    check(C.truck._p.IsHeld == true and C.hud._p.InteractTimerWidget == nil, "E6e: the game set its flag and stopped (no timer bar)")
    run(15)
    check(vrepairs() == n0 and health(H) == 20, "E6e: nothing asked")
    check(warned(C, "its last step never ran", nw) ~= nil and C.truck._p.IsHeld == false, "E6e: a warning; the stuck flag cleared")
    C.cl_ch._view = nil
    in_m(C, function() rawset(C.by_path, KIT_PATH, C.kit_da) end)
    place("client", AWAY_C)
    run(1)
end

print("E6f. the host leaves the repair box just after the client's hold ended (before the tick): the flag is not set again, asked once")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    local nw = #C.warns
    place("host", spot(REPAIR_BOX, 40))
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(9.5)
    T = T + 0.5
    holds()                     -- the game's last step: flag down
    T = T + 0.2
    place("host", AWAY_H)       -- the game's OnEnd for the host on the client's copy
    check(C.truck._p.IsHeld == false, "E6f: the client's flag not set again after its hold's time")
    run(1)
    check(vrepairs() == n0 + 1 and health(H) == 82.5 and INV.client.kit == 0, "E6f: asked once: 20 -> 82.5, the kit taken")
    check(warned(C, "its last step never ran", nw) == nil, "E6f: no 'never ran' warning")
    place("client", AWAY_C)
    run(1)
end

print("E6g. out of the box without the game's OnEnd (moved away unseen): the tick sees it outside, nothing asked")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    local nc = #C.infos
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(5)
    -- the overlap gone with no event on this machine (moved away unseen)
    C.truck._inbox.repair[C.cl_ch] = nil
    C.cl_ch._p.__loc = { X = AWAY_C.X, Y = AWAY_C.Y, Z = AWAY_C.Z }
    run(6)
    check(vrepairs() == n0 and health(H) == 20 and INV.client.kit == 1, "E6g: nothing asked, nothing added")
    check(said(C, "outside the repair box: nothing asked", nc) ~= nil, "E6g: logged")
    C.truck._p.IsHeld, C.truck._p["InRepairingArea?"] = false, false
    run(1)
end

print("E6h. the key again right as the bar fills (before the tick): the first hold asked at once, then the second")
INV.client.kit = 2
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(9.5)
    T = T + 0.5
    holds()                     -- the first hold's last step
    T = T + 0.1
    press(OPT_KIT)              -- the flag was down: a second hold starts
    check(vrepairs() == n0 + 1 and C.truck._p.IsHeld == true, "E6h: the first hold asked at once; the second hold runs")
    run(11)
    check(vrepairs() == n0 + 2 and health(H) == 125 and INV.client.kit == 0, "E6h: the second asked too: 20 -> 82.5 -> 125, two kits")
    place("client", AWAY_C)
    run(1)
end

print("E6i. getting in right after the bar filled (before the tick): asked once all the same")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", { X = LOC.X + 20, Y = LOC.Y - 120, Z = 100 })
    -- (a box reaching the driver's door: the repair box moved for this case)
    local rb = { dx = 20, dy = -120, hx = 60, hy = 60 }
    local old = { REPAIR_BOX.dx, REPAIR_BOX.dy, REPAIR_BOX.hx, REPAIR_BOX.hy }
    REPAIR_BOX.dx, REPAIR_BOX.dy, REPAIR_BOX.hx, REPAIR_BOX.hy = rb.dx, rb.dy, rb.hx, rb.hy
    boxes()
    press(OPT_KIT)
    run(9.5)
    T = T + 0.5
    holds()
    T = T + 0.1
    press(OPT_IN)               -- the game's get-in (the flag was down)
    flush()
    check(vrepairs() == n0 + 1, "E6i: asked at the get-in press")
    run(2)
    check(health(H) == 82.5 and INV.client.kit == 0 and H.cl_ch._parent == H.truck, "E6i: repaired (20 -> 82.5), the client seated")
    in_m(C, function() C.truck:ExitVehicle() end)
    flush()
    REPAIR_BOX.dx, REPAIR_BOX.dy, REPAIR_BOX.hx, REPAIR_BOX.hy = old[1], old[2], old[3], old[4]
    place("client", AWAY_C)
    run(3)
    check(H.cl_ch._parent == nil and C.V._t.local_seat() == nil, "E6i: out again")
end

print("E8. the host repairs the car itself during the client's hold: the client's hold still asks; the host: nothing left to do")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(4)
    in_m(H, function()   -- the host's own repair to the full 125
        H.truck._p.VehicleHealthComponent._p.CurrentHealth = 125
        H.V._t.vs()[H.truck._addr].dirty = true
    end)
    run(1)
    check(health(C) == 125, "E8: the host's state reached the client during its hold")
    run(6)
    check(vrepairs() == n0 + 1 and last("VBOXR", "host").fields[2] == "full", "E8: asked once; the host: nothing to repair")
    check(INV.client.kit == 1 and health(H) == 125, "E8: no kit taken")
    place("client", AWAY_C)
    run(1)
end

print("E9. a client whose own take works (not the game of 13.11): the add made there is sent once, nothing asked on top")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    local nc = #C.infos
    C.own_take = { gas = 0, kit = 1 }
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(11)
    check(C.own_take.kit == 0 and vrepairs() == n0 + 1, "E9: the game's kit branch added here; one VREPAIR")
    check(said(C, "this player repaired", nc) ~= nil and said(C, "added here and sent: nothing asked", nc) ~= nil,
        "E9: sent as the add made here; the hold's end asks nothing")
    check(health(H) == 82.5, "E9: the host: 20 -> 82.5")
    C.own_take = nil
    place("client", AWAY_C)
    run(1)
end

print("E9b. the same for a refuel whose UseGasCan hook does not fire: the tick sends the add, the hold's end asks nothing")
INV.client.gas = 1
set_host_values(300, 20)
run(1)
do
    local n0 = vfuels()
    local nc = #C.infos
    local gh = C.hooks[VEH .. ":UseGasCan"]
    C.hooks[VEH .. ":UseGasCan"] = nil
    C.own_take = { gas = 1, kit = 0 }
    place("client", spot(FUEL_BOX))
    press(OPT_GAS)
    run(11)
    check(C.own_take.gas == 0 and vfuels() == n0 + 1, "E9b: the game's UseGasCan added here; one VFUEL (from the tick)")
    check(said(C, "added here and sent: nothing asked", nc) ~= nil and fuel(H) == 800, "E9b: the hold's end asks nothing; the host: 300 -> 800")
    C.hooks[VEH .. ":UseGasCan"] = gh
    C.own_take = nil
    place("client", AWAY_C)
    run(1)
end

print("E6j. the game's flag down mid-hold by a path the mod does not see: nothing asked before the hold's time")
INV.client.kit = 1
set_host_values(500, 20)
run(1)
do
    local n0 = vrepairs()
    place("client", spot(REPAIR_BOX))
    press(OPT_KIT)
    run(3)
    C.truck._p.IsHeld = false
    run(5)
    check(vrepairs() == n0, "E6j: nothing asked while the hold's time runs")
    run(3)
    place("client", AWAY_C)
    run(1)
end

-- ------------------------------------------------------------ E7 the host says no
print("E7. the host has no kit for it / the tank is full there: the game's note on the client, nothing taken")
do
    INV.client = { gas = 1, kit = 0 }
    C.cl_ch._view = { gas = 1, kit = 1 }   -- an inventory view not updated yet
    set_host_values(500, 20)
    run(1)
    local n0 = vrepairs()
    local r = round("repair")
    check(r.asks == 1 and last("VBOXR", "host").fields[2] == "none", "E7: asked; the host: none")
    check(has_note(C.hud, "No repair kits found") and health(C) == 20 and health(H) == 20, "E7: the game's 'No repair kits found' on the client, nothing added")
    check(vrepairs() == n0 + 1, "E7: asked once")
    C.cl_ch._view = nil
    -- the tank: full on the host, the client's copy not told yet
    place("client", AWAY_C)
    run(1)
    in_m(C, function() C.truck._p.FuelComponent._p.CurrentFuel = 500 end)
    in_m(H, function() H.truck._p.FuelComponent._p.CurrentFuel = 1000 end)
    place("client", spot(FUEL_BOX))
    press(OPT_GAS)
    local nf = vfuels()
    -- (no tick until the hold's end: the host's state does not reach it first)
    T = T + 10
    holds()
    flush()
    check(vfuels() == nf + 1 and last("VBOXR", "host").fields[2] == "full", "E7: asked; the host: full")
    check(INV.client.gas == 1 and has_note(C.hud, "Gas full"), "E7: no gas can taken; the game's 'Gas full' on the client")
    run(2)
    check(fuel(C) == 1000, "E7: the host's state sets the client's copy right")
    place("client", AWAY_C)
    run(1)
end

print("E10. the host's own repair: the game's own step there, nothing on the wire; its hold record let go")
INV.host = { gas = 0, kit = 1 }
set_host_values(500, 20)
run(1)
do
    local n0, nb = count("VREPAIR"), count("VBOXR")
    place("host", spot(REPAIR_BOX))
    host_press(OPT_KIT)
    check(H.truck._p.IsHeld == true and H.hud._timer_text == "Repairing Vehicle", "E10: the host's hold and timer bar")
    run(11)
    check(health(H) == 82.5 and INV.host.kit == 0, "E10: the game's kit branch on the host: 20 -> 82.5, the host's kit")
    check(count("VREPAIR") == n0 and count("VBOXR") == nb, "E10: no ask, no answer on the wire")
    run(3)
    check(health(C) == 82.5, "E10: the client sees it (VSTATE)")
    check(next(H.V._t.fx.holds) == nil, "E10: the host's hold record let go after its time")
    place("host", AWAY_H)
    run(1)
end

-- ------------------------------------------------------------ E11 two cars side by side
-- Car 2 200 cm to the left of car 1: its repair box (x 220..420, y 50..350)
-- meets car 1's (y -150..150) - at (320, 100) the client is in both.
local L2 = { X = LOC.X, Y = LOC.Y + 200, Z = LOC.Z }
in_m(H, function() H.truck2 = new_vehicle(H, CLS .. "_2147480002", L2, CLS, 3) end)
in_m(C, function() C.truck2 = new_vehicle(C, CLS .. "_2147400002", { X = L2.X, Y = L2.Y, Z = L2.Z }, CLS, 1) end)
local BOTH = { X = LOC.X + 320, Y = LOC.Y + 100, Z = 100 }
local function hp(v) return v._p.VehicleHealthComponent._p.CurrentHealth end
local function fl(v) return v._p.FuelComponent._p.CurrentFuel end
local function hold_on(v) return C.V._t.fx.holds[v._addr] end
-- car 1 and car 2 at health 20 on the host, sent to the client
local function two_at_20()
    set_host_values(500, 20)
    in_m(H, function()
        H.truck2._p.VehicleHealthComponent._p.CurrentHealth = 20
        local st = H.V._t.vs()[H.truck2._addr]
        if st then st.dirty = true end
    end)
    run(2)
end
local function press2(opt) in_m(C, function() C.truck2:OnExecuteInteract(C.cl_ch, opt) end); flush() end

print("E11a. two cars side by side: Repair on car 1, then Repair on car 2 during the first hold: both asked")
INV.client = { gas = 0, kit = 2 }
two_at_20()
do
    check(health(C) == 20 and hp(C.truck2) == 20, "E11a: the client's copies of both cars at 20 (VSTATE matched each car)")
    local n0 = vrepairs()
    local nc = #C.infos
    place("client", BOTH)
    check(C.truck._p.InteractOptions[OPT_KIT] == true and C.truck2._p.InteractOptions[OPT_KIT] == true,
        "E11a: the client in both repair boxes: the game offers 'Repair Vehicle' on both")
    press(OPT_KIT)
    run(2)
    press2(OPT_KIT)
    check(C.truck._p.IsHeld == true and C.truck2._p.IsHeld == true and hold_on(C.truck) ~= nil and hold_on(C.truck2) ~= nil,
        "E11a: the game's hold runs on each car; the mod keeps a record for each")
    check(said(C, "hold still running beside it: repair on " .. C.truck._short, nc) ~= nil, "E11a: the second press's line names the first hold")
    run(9)   -- car 1's hold ended (10 s), car 2's runs till 12 s
    check(vrepairs() == n0 + 1 and health(H) == 82.5 and hp(H.truck2) == 20 and INV.client.kit == 1,
        "E11a: car 1's hold asked at its end: car 1 20 -> 82.5 on the host, one kit")
    check(health(C) == 82.5 and hold_on(C.truck) == nil and hold_on(C.truck2) ~= nil, "E11a: the client sees car 1 repaired; car 2's hold still kept")
    check(C.hud._p.InteractTimerWidget ~= nil, "E11a: the timer bar stays for car 2's running hold")
    run(2)
    check(vrepairs() == n0 + 2 and hp(H.truck2) == 82.5 and INV.client.kit == 0, "E11a: car 2's hold asked too: car 2 20 -> 82.5, the second kit")
    check(hp(C.truck2) == 82.5 and health(H) == 82.5, "E11a: the client sees car 2 repaired; car 1 still 82.5")
    check(C.hud._p.InteractTimerWidget == nil and next(C.V._t.fx.holds) == nil, "E11a: the timer bar closed; no hold record left")
    place("client", AWAY_C)
    run(1)
end

print("E11b. a second press on car 2 (the game only clears car 2's flag): car 2's hold stops, car 1's still asks")
INV.client = { gas = 0, kit = 2 }
two_at_20()
do
    local n0 = vrepairs()
    place("client", BOTH)
    press(OPT_KIT)
    run(1)
    press2(OPT_KIT)
    run(1)
    press2(OPT_KIT)          -- car 2's IsHeld was set: the game's press only clears it
    check(C.truck._p.IsHeld == true and C.truck2._p.IsHeld == false and hold_on(C.truck) ~= nil and hold_on(C.truck2) == nil,
        "E11b: car 2's hold stopped; car 1's runs on")
    run(10)
    check(vrepairs() == n0 + 1 and health(H) == 82.5 and hp(H.truck2) == 20 and INV.client.kit == 1,
        "E11b: car 1 asked once (20 -> 82.5); car 2 nothing, its kit kept")
    place("client", AWAY_C)
    run(1)
end

print("E11c. the host leaves car 1's repair box during the client's holds on both cars: car 1's hold given back, both asked")
INV.client = { gas = 0, kit = 2 }
two_at_20()
do
    local n0 = vrepairs()
    place("host", spot(REPAIR_BOX, 40))   -- in car 1's repair box only
    place("client", BOTH)
    press(OPT_KIT)
    run(1)
    press2(OPT_KIT)
    run(2)
    place("host", AWAY_H)                 -- the game clears car 1's flag and IsHeld on the client's copy
    check(C.truck._p.IsHeld == true and C.truck2._p.IsHeld == true, "E11c: car 1's hold given back at once; car 2's untouched")
    run(9)
    check(vrepairs() == n0 + 2 and health(H) == 82.5 and hp(H.truck2) == 82.5 and INV.client.kit == 0,
        "E11c: both asked: both cars 20 -> 82.5, two kits")
    place("client", AWAY_C)
    run(1)
end

print("E11e. both cars pressed at the same moment: both holds' ends seen in the same tick, both asked")
INV.client = { gas = 0, kit = 2 }
two_at_20()
do
    local n0 = vrepairs()
    place("client", BOTH)
    press(OPT_KIT)
    press2(OPT_KIT)
    run(10)      -- both holds' last steps at 10 s, the tick at 10.5 s not yet
    check(vrepairs() == n0, "E11e: nothing asked before the holds' ends were seen")
    run(0.5)
    check(vrepairs() == n0 + 2 and health(H) == 82.5 and hp(H.truck2) == 82.5 and INV.client.kit == 0,
        "E11e: both asked by the first tick after their end: both cars 20 -> 82.5")
    place("client", AWAY_C)
    run(1)
end

print("E11f. the host leaves car 1's repair box while the client holds car 2 only: car 1's flag not raised, car 2 asked")
INV.client = { gas = 0, kit = 1 }
two_at_20()
do
    local n0 = vrepairs()
    place("host", spot(REPAIR_BOX, 40))
    place("client", BOTH)
    press2(OPT_KIT)
    run(2)
    place("host", AWAY_H)
    check(C.truck._p.IsHeld == false and hold_on(C.truck) == nil and C.truck2._p.IsHeld == true,
        "E11f: car 1 (no hold of this player) keeps its flag down; car 2's hold runs")
    run(1)
    local nc = #C.infos
    place("client", { X = BOTH.X, Y = LOC.Y + 200, Z = 100 })   -- out of car 1's box, still in car 2's
    check(C.truck._inbox.repair[C.cl_ch] == nil and C.truck2._inbox.repair[C.cl_ch] == true and said(C, "hold stopped", nc) == nil
        and C.truck2._p.IsHeld == true and hold_on(C.truck2) ~= nil,
        "E11f: the client steps out of car 1's box only: no hold stopped, car 2's runs on")
    run(8)
    check(vrepairs() == n0 + 1 and hp(H.truck2) == 82.5 and health(H) == 20 and INV.client.kit == 0,
        "E11f: car 2 asked once (20 -> 82.5); car 1 untouched")
    check(C.truck._p.IsHeld == false, "E11f: car 1's flag still down (its next press is a new hold, not a clear)")
    place("client", AWAY_C)
    run(1)
end

print("E11d. Repair on car 1, then Refuel on car 3 (its fuel box at car 1's repair box): both done, the bar kept for the running hold")
-- car 3: its fuel box (rear left: -250, -150) on car 1's repair box (320, 0)
local L3 = { X = LOC.X + 570, Y = LOC.Y + 150, Z = LOC.Z }
in_m(H, function() H.truck3 = new_vehicle(H, CLS .. "_2147480003", L3, CLS, 3) end)
in_m(C, function() C.truck3 = new_vehicle(C, CLS .. "_2147400003", { X = L3.X, Y = L3.Y, Z = L3.Z }, CLS, 1) end)
INV.client = { gas = 1, kit = 1 }
set_host_values(500, 20)
run(2)
do
    local n0, nf = vrepairs(), vfuels()
    check(fl(C.truck3) == 300 and fl(H.truck3) == 300, "E11d: car 3 at fuel 300 of 1000 on both")
    place("client", spot(REPAIR_BOX))
    check(C.truck._p.InteractOptions[OPT_KIT] == true and C.truck3._p.InteractOptions[OPT_GAS] == true,
        "E11d: the client offered 'Repair Vehicle' on car 1 and 'Refuel Vehicle' on car 3")
    press(OPT_KIT)
    run(2)
    in_m(C, function() C.truck3:OnExecuteInteract(C.cl_ch, OPT_GAS) end); flush()
    check(C.hud._timer_text == "Refilling Vehicle" and hold_on(C.truck) ~= nil and hold_on(C.truck3) ~= nil,
        "E11d: both holds kept (the bar now says 'Refilling Vehicle')")
    run(9)
    check(vrepairs() == n0 + 1 and health(H) == 82.5 and INV.client.kit == 0, "E11d: car 1's repair asked: 20 -> 82.5, the kit")
    check(vfuels() == nf and C.hud._p.InteractTimerWidget ~= nil, "E11d: no refuel yet; the bar kept for car 3's running refuel")
    run(2)
    check(vfuels() == nf + 1 and fl(H.truck3) == 800 and fl(C.truck3) == 800 and INV.client.gas == 0,
        "E11d: car 3's refuel asked once: 300 -> 800 on both, the gas can")
    check(C.hud._p.InteractTimerWidget == nil and next(C.V._t.fx.holds) == nil, "E11d: the bar closed; no hold record left")
    place("client", AWAY_C)
    run(1)
end

check(#H.no_handler == 0 and #C.no_handler == 0, "end: every message had a handler")
print("status host: " .. in_m(H, function() return H.V.status_line() end))
print("status client: " .. in_m(C, function() return C.V.status_line() end))
real_print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
