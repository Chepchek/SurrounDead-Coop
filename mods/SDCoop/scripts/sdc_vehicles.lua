-- SDCoop: vehicles in co-op, host-authoritative, with the game's own vehicle
-- functions. Audit: work\audit\vehicles.md.
--
-- How the game drives (BP_VehicleMaster_C : WheeledVehiclePawn, Chaos):
--   * nobody possesses the vehicle. The interact key runs, on the machine
--     where it was pressed, BP_JigHelperComp.TryInteract -> the vehicle's
--     OnExecuteInteract -> Interact_GetInVehicle (@11069): player 0 is
--     attached to the vehicle (K2_AttachToActor KeepWorld, welded), sits
--     (SitInCar montage), is moved to PlayerLocation; then @7691: VehicleUI,
--     handbrake off, tags, fuel timer, CheckWater / VehicleSound / Noise
--     timers, engine sound; 0.1 s later player 0's VehicleInteraction(true).
--   * the character's VehicleDrivingComponent turns the IA_Vehicle* input
--     into SetThrottle/Steering/Brake/HandbrakeInput on the vehicle's
--     ChaosVehicleMovementComponent (bRequiresControllerForInputs = False,
--     so every machine simulates its own raw input).
--   * ExitVehicle -> Event_ExitVehicle (@24714: detach player 0, place it at
--     the DriverSide / PassengerSide socket, timers and sound off) + a tail
--     (walking, collision back, handbrake, fuel timer off).
--   * fuel, health, lights, engine, colour: plain BP variables, nothing
--     replicates; BeginPlay rolls random fuel / health / colour on EVERY
--     machine. The vehicle actor and its physics movement do replicate
--     (APawn), and the movement component replicates ReplicatedState and
--     has the ServerUpdateState RPC (needs an owning connection).
--
-- What this module does (config vehicle_sync, per-feature keys below):
--   Host, a client enters (VENTER): the vehicle gets the client's controller
--     as Owner (its ServerUpdateState RPCs reach the host), the host's copy
--     takes the replicated inputs (SetRequiresControllerForInputs(true)),
--     and the game's own Interact_GetInVehicle runs on the host with player 0
--     = that client (sdc_ctx scope_resolver, chained to sdc_respawn's): the
--     attachment, sit montage, fuel spend, water damage, noise and engine
--     sound now exist on the server. The VehicleUI it creates on the host's
--     screen is removed. While seated, the host keeps the client's server-side
--     position (bServerAcceptClientAuthoritativePosition off) so the driver
--     does not hover beside the car. Exit (VEXIT): Event_ExitVehicle + the
--     ExitVehicle tail on the host, owner and flags back.
--   Passengers (vehicle_passengers, vehicle_seats; module sdc_vehseats): the
--     game has one seat. Seat 2 is the mirror of the driver's next to it,
--     seats 3+ come from a table per vehicle class (the rear row of six cars;
--     beds / benches of the others once tuned). A newcomer takes the first
--     free seat (attach + sit montage + VehicleInteraction on the host; the
--     host the same way when it enters a client-driven car) and is told
--     "Seat N of M" where a car has more than 2. The wheel is the first free
--     seat (the game's only seat in single player): whoever gets into a car
--     nobody drives drives it. When the driver gets out (its exit key, death,
--     disconnect) every passenger stays in its seat and the car stands
--     parked as after the game's own exit - handbrake on, engine and timers
--     off (SEATK.wheel_free; a host passenger's own driving keys do not move
--     it, SEATK.hold_frame) - until somebody drives; the passengers are told
--     once "The wheel is free: press G". A passenger moves only with the
--     seat key (config vehicle_seat_key, G; read on the game thread,
--     SEATK.frame): to the wheel when nobody drives, else to the next free
--     seat in seat order, round; none free: a notice (SEATK.host_key /
--     client_key, VSWITCH, the host decides: SEATK.client_switch). The user,
--     13.11: up to then the passenger was moved to the wheel 1.5 s after the
--     driver got out, also when it was getting out itself. The last one out
--     of a car nobody drives parks it (SEATK.park_empty). One
--     player per seat: in a full car the newcomer is refused ("No free
--     seat"), the host too (the game's get-in it ran is undone,
--     SEATK.host_out); SEATK.free_seat decides. A rear seat gets out at its
--     own (rear) door when that is free.
--   Client: vehicles it does not drive use the replicated inputs (no local
--     handbrake fighting the physics replication, no ServerUpdateState
--     spam); its own driven vehicle predicts locally. Lights / horn / flip /
--     tow / push / refuel / repair / trader purchases done on the client are
--     sent to the host, which runs the game's function on its copy.
--   Driver only (every machine): lights, horn and flip are the driver's; a
--     passenger's (a client, or the host in a client-driven car, any seat)
--     lights are switched back at once (a wreck's too: SEATK.lights_back),
--     its horn is muted - no sound, no AI noise (SEATK.hush_snd / hush_ai) -
--     and not passed on, its flip key meets the game's "Cannot flip vehicle"
--     (SEATK.pass_block / flip_hold); the host takes VLIGHT / VHORN / VFLIP
--     only from the driver (SEATK.not_driver logs a refusal). Log lines:
--     "driver only:".
--   Refuel / repair (every machine): the game's own flow where the key was
--     pressed (option, timer bar, montage, hold). Its last step cannot take
--     the gas can / repair kit on a client (the host's data): the client asks
--     the host (VFUEL / VREPAIR) - from the game's note of that, UseGasCan's
--     hook (refuel) or, as the note never reached the mod in the game (13.11:
--     no client repair ever asked), its tick at the hold's end (fx.hold_end:
--     time up, the game's flag down, nothing added, not outside the box;
--     one ask per hold) - and the host takes the item from
--     that player's inventory, adds the fuel (FuelComponent.AddFuel) / health,
--     sends the state to everyone and answers (VBOXR: the game's success step
--     on the client's copy, or the game's note). Another player's
--     character leaving a fuel / repair box no longer takes the option and
--     the running hold from this machine's player (one flag per vehicle).
--   Vehicle trader: a client's click runs the game's purchase on its own view
--     (money out of its view only); its own car spawn is blocked. VBUY: the
--     host checks / takes the money from that player's inventory on the host
--     (CheckIfHasEnoughMoney, TakeMoney, CLIENT_UpdateCounts to the client),
--     spawns the car with the trader spawner's SpawnVehicle and answers
--     VBUYR (ok / refused: shown in Russian, the host's money numbers sent).
--   State (vehicle_state): the host sends each vehicle's colour, fuel,
--     health, lights, engine and "has a driver" (VSTATE: per client, only
--     the vehicles within ~200 m of its character, packed into one message
--     a tick, see vsync); clients apply them
--     and show other players' driving: engine sound + RPM timer, sit montage,
--     InVehicle? for the AnimBP, weapons hidden, and the vehicle mesh ignoring
--     the attached characters (Pawn / Camera, as the game does on entry).
--   Ghosts (vehicle_ghosts): BP_VehicleSpawner is not replicated, so on a
--     client it has authority and spawned its own local cars (none on the
--     host, overlapping the host's). Client: spawners are marked used and
--     client-owned runtime vehicles are destroyed.
--   Inventory key in a seat (every machine, its own player): every press
--     logged with what the game did; an aim flag the game cannot end in a
--     vehicle no longer eats the key; a Tab press the passenger's character
--     never got opens the window the game's way (see "The inventory key in a
--     seat").
--   Radio (vehicle_radio, module sdc_vehradio): a seated player's radio
--     (on, track, pause, volume, speed) on every machine's copy of the
--     vehicle with the game's own radio functions (VRADIO / VRADIOQ).
--
-- Rules: no UObject is kept between ticks except the per-tick discovery list;
-- state is keyed by address + short name and looked up again. Every hook
-- callback returns nothing and never throws.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    -- promoted: a passenger took the wheel (its seat key); switches: every seat key move
    stats = { enters = 0, passengers = 0, exits = 0, rejected = 0, promoted = 0, switches = 0, relays = 0,
              states_sent = 0, states_applied = 0, ghosts = 0, spawners = 0, buys = 0,
              stray_vi = 0, stray_exits = 0, inv_keys = 0, inv_fixed = 0, inv_lost = 0 },
}

local S = nil   -- sdc_session.state

-- The vehicle radio (config vehicle_radio): its own module, given this
-- module's pieces in M.install and run from tick / reset / the handlers (a
-- field, not a local: this chunk is at Lua's 200-locals limit).
M.radio = require("sdc_vehradio")
-- The seats of a vehicle (config vehicle_seats): the table per class, the
-- seat a newcomer gets, where it is, the seat messages' fields, the host's
-- console command sdcoop_seat (a field too).
M.vseats = require("sdc_vehseats")

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local VEH_CLASS = "BP_VehicleMaster_C"
local VEH_PATH = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local CHAR_CLASS = "BP_PlayerCharacter_C"
local CHAR_PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local SPAWNER_CLASSES = { "BP_VehicleSpawner_C", "BP_VehicleUniqueSpawner_C" }
local TRADER_CLASS = "BP_VehicleTraderSpawner_C"
local TRADER_PATH = "/Game/Inventory/Traders/Traders/BP_VehicleTraderSpawner.BP_VehicleTraderSpawner_C"
local SIT_MONTAGE = "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage"
local AIO_EVENT = "BndEvt__BP_MPLootContainer_AIOSubject_K2Node_ComponentBoundEvent_0_OnOptimizationUpdate__DelegateSignature"
local DRIVE_TAGS = { "ScaresAnimals", "Player", "AI", "BanditCanAttack", "MilitaryCanAttack" }   -- @8004..8431

local ECC_PAWN, ECC_CAMERA = 2, 4
local ECR_IGNORE, ECR_BLOCK = 0, 2
local KEEP_WORLD = 1
local MOVE_WALKING = 1
local PUSH_FORCE = 4e7          -- Interact_PushVehicle @12585
local SCOPE_S = 1.0             -- our own calls + the BP's 0.1 s delayed VehicleInteraction
local HOST_WINDOW_S = 0.6       -- the host's own interaction with a client-driven vehicle
local RELEASE_S = 1.5           -- sdc_ctx caches player_for per second
local MATCH_M = 2500            -- cm: host / client copies of one vehicle
local NEAR_M = 1500             -- cm: a player acting on a vehicle stands this close (host copies)
local STATE_EVERY_S = 10
local CAP_EVERY_S = 10
local PENDING_S = 4
local PUSH_COOLDOWN_S = 2

local TEXT = {
    veh_full        = { "No free seat in this vehicle.", "В машине нет свободного места." },
    veh_rejected    = { "The host did not seat you (%s).", "Хост не посадил вас в машину (%s)." },
    veh_passenger   = { "You are a passenger: %s drives.", "Вы пассажир: машину ведёт %s." },
    veh_driver_now  = { "You now drive this vehicle.", "Теперь машину ведёте вы." },
    veh_buy_money   = { "Purchase cancelled: the host has %d money for you, the vehicle costs %d.",
                        "Покупка отменена: на хосте у вас %d денег, машина стоит %d." },
    veh_buy_failed  = { "The vehicle purchase did not go through on the host (%s).",
                        "Покупка машины не прошла на хосте (%s)." },
    veh_driver_only = { "Only the driver uses the lights and the horn.", "Фарами и сигналом управляет только водитель." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function on(key) return cfg.get(key) ~= false end
local function enabled() return on("vehicle_sync") end

local function num(v)
    if type(v) == "number" then return v end
    return tonumber(v)
end

local function addr(o)
    if o == nil then return nil end
    return ctx.addr(o)
end

local function vec(v)
    if v == nil then return nil end
    local x = ue.try(function() return v.X end)
    local y = ue.try(function() return v.Y end)
    local z = ue.try(function() return v.Z end)
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

local function d2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function f0(x) return string.format("%.0f", tonumber(x) or 0) end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("veh." .. name, "vehicles: %s: %s", name, tostring(err)) end
    end
end

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local logged = {}
local function info_once(key, msg, ...)
    if logged[key] then return end
    logged[key] = true
    log.info(msg, ...)
end

-- Guard for our own calls into the game's vehicle functions: their hooks
-- (post) see them and must not report them as player actions.
local applying = 0
local function apply(fn)
    applying = applying + 1
    local ok, err = pcall(fn)
    applying = applying - 1
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Discovery (one FindAllOf per tick; objects are used only until the next)
-- ---------------------------------------------------------------------------

local cur = { list = {}, by = {}, at = -100 }

local cls_of = {}   -- [address] = { s = short name, cls = class name } (a class never changes)

local function discover(force)
    local t = os.clock()
    if not force and t - cur.at < 0.25 then return end
    local list, by, cls = {}, {}, {}
    for _, v in ipairs(ue.find_all(VEH_CLASS)) do
        if ue.valid(v) then
            local s = ue.short(v)
            if s ~= "" and s ~= "<none>" and not s:find("^Default__") then
                local a = addr(v)
                if a then
                    list[#list + 1] = v
                    by[a] = v
                    local c = cls_of[a]
                    if not c or c.s ~= s then c = { s = s, cls = ue.class_name(v) } end
                    cls[a] = c
                end
            end
        end
    end
    cls_of = cls
    cur = { list = list, by = by, at = t }
end

-- The ticks refresh the list every 2 s (a vehicle bought / destroyed shows up
-- that much later; vehicle_by refreshes at once on a miss).
local function discover_slow()
    if os.clock() - cur.at >= 2 or os.clock() < cur.at then discover(true) end
end

local function vehicle_by(a, name)
    if not a then return nil end
    local v = cur.by[a]
    if v and ue.valid(v) and ue.short(v) == name then return v end
    discover(true)
    v = cur.by[a]
    if v and ue.valid(v) and ue.short(v) == name then return v end
    return nil
end

-- The copy of one vehicle on this machine: nearest, same class preferred.
-- (a packed VSTATE matches several records against one list: the location
-- in one call, the class from discover's cache; `nodisc`: the caller keeps
-- the list fresh itself)
local function loc_xyz(v)
    local l = v:K2_GetActorLocation()
    return l.X, l.Y, l.Z
end

local function vehicle_at(x, y, z, cls, maxd, nodisc)
    if not (x and y and z) then return nil end
    if not nodisc then discover(false) end
    local best, bestd = nil, (maxd or MATCH_M) ^ 2
    for _, v in ipairs(cur.list) do
        if ue.valid(v) then
            local ok, lx, ly, lz = pcall(loc_xyz, v)
            if ok and type(lx) == "number" and type(ly) == "number" and type(lz) == "number" then
                local d = (lx - x) * (lx - x) + (ly - y) * (ly - y) + (lz - z) * (lz - z)
                if cls and cls ~= "" then
                    local c = cls_of[addr(v) or -1]
                    if (c and c.cls or ue.class_name(v)) ~= cls then d = d * 4 + 1 end
                end
                if d <= bestd then best, bestd = v, d end
            end
        end
    end
    return best
end

local function chars()
    local t = {}
    -- (shared with the other ticks for a quarter second)
    for _, c in ipairs(ue.find_all_recent(CHAR_CLASS) or {}) do
        if ue.valid(c) and not ue.short(c):find("^Default__") then t[#t + 1] = c end
    end
    return t
end

-- Address of the known vehicle a character is attached to, or nil.
local function parent_vehicle(ch)
    local p = ue.try(function() return ch:GetAttachParentActor() end)
    if not ue.valid(p) then return nil end
    local a = addr(p)
    if a and cur.by[a] then return a end
    return nil
end

local function locally_controlled(ch)
    return ue.try(function() return ch:IsLocallyControlled() end) == true
end

-- ---------------------------------------------------------------------------
-- The game's vehicle pieces
-- ---------------------------------------------------------------------------

local function mcomp(v)
    local m = ue.prop(v, "VehicleMovementComponent")
    if ue.valid(m) then return m end
    return nil
end

-- true: the engine uses the replicated inputs (ReplicatedState); false: this
-- machine's own raw inputs (the game's setting).
local function set_requires(v, want)
    local m = mcomp(v)
    if not m then return false end
    if ue.prop(m, "bRequiresControllerForInputs") == want then return true end
    pcall(function() m:SetRequiresControllerForInputs(want) end)
    if ue.prop(m, "bRequiresControllerForInputs") ~= want then ue.set_prop(m, "bRequiresControllerForInputs", want) end
    local ok = ue.prop(m, "bRequiresControllerForInputs") == want
    if not ok then log.err_throttled("veh.requires", "vehicles: cannot set bRequiresControllerForInputs on %s", ue.short(v)) end
    return ok
end

local function fuel_of(v)
    local fc = ue.prop(v, "FuelComponent")
    if not ue.valid(fc) then return nil, nil, nil end
    return num(ue.prop(fc, "CurrentFuel")), num(ue.prop(fc, "MaxFuel")), fc
end

local function health_of(v)
    local hc = ue.prop(v, "VehicleHealthComponent")
    if not ue.valid(hc) then return nil, nil, nil end
    return num(ue.prop(hc, "CurrentHealth")), num(ue.prop(hc, "MaxHealth")), hc
end

local function timer_active(o, fn)
    local k = ue.ksl()
    return k ~= nil and ue.try(function() return k:K2_IsTimerActive(o, fn) end) == true
end

-- Timers by function name are the same timers the Blueprint sets with
-- bind(self.X) (K2_SetTimer / K2_ClearTimer find the same dynamic delegate).
local function set_timer(o, fn, secs)
    local k = ue.ksl()
    if k then pcall(function() k:K2_SetTimer(o, fn, secs, true, false, 0, 0) end) end
end

local function clear_timer(o, fn)
    local k = ue.ksl()
    if k then pcall(function() k:K2_ClearTimer(o, fn) end) end
end

local function engine_sound(v, run)
    local snd = ue.prop(v, "EngineSound")
    if not ue.valid(snd) then return false end
    local active = ue.try(function() return snd:IsActive() end) == true
    if run then
        -- A FadeOut (the game's exit @23409, its death in a vehicle @9456,
        -- stop_services) keeps the component active until the sound has
        -- faded, 2.5 s: GetPlayState() is then FadingOut (4). Started again
        -- at once (Activate(true) restarts it): a car that keeps its driver
        -- went quiet for ~3 s on the host after the host's refused get-in or
        -- its exit as a passenger (up to 0.7.3).
        if not active or ue.try(function() return snd:GetPlayState() end) == 4 then
            pcall(function() snd:Activate(true) end)
        end
        if not timer_active(v, "VehicleSound") then set_timer(v, "VehicleSound", 0.2) end
    else
        if active then pcall(function() snd:FadeOut(2.5, 0, 0) end) end
        clear_timer(v, "VehicleSound")
    end
    return true
end

-- Mesh vs. characters, as Interact_GetInVehicle (@11074) / ExitVehicle (@304).
local function set_collision(v, occupied)
    local mesh = ue.prop(v, "Mesh")
    if not ue.valid(mesh) then return end
    for _, chan in ipairs({ ECC_PAWN, ECC_CAMERA }) do
        local r = ue.try(function() return mesh:GetCollisionResponseToChannel(chan) end)
        if occupied and r ~= ECR_IGNORE then
            pcall(function() mesh:SetCollisionResponseToChannel(chan, ECR_IGNORE) end)
        elseif not occupied and r == ECR_IGNORE then
            pcall(function() mesh:SetCollisionResponseToChannel(chan, ECR_BLOCK) end)
        end
    end
end

local function tag_names(v)
    local tags = ue.prop(v, "Tags")
    if not tags then return nil, nil end
    local names = {}
    local ok = pcall(function()
        tags:ForEach(function(_, el) names[#names + 1] = ue.str(el:get()) end)
    end)
    if not ok then return nil, nil end
    return tags, names
end

-- The tags the game adds while someone drives (AI targets the vehicle).
local function ensure_tags(v)
    local tags, names = tag_names(v)
    if not tags then return end
    local have = {}
    for _, n in ipairs(names) do have[n] = true end
    local n = #names
    for _, t in ipairs(DRIVE_TAGS) do
        if not have[t] then
            n = n + 1
            local i = n
            if not pcall(function() tags[i] = FName(t) end) then return end
        end
    end
end

local function strip_tags(v)
    local tags, names = tag_names(v)
    if not tags then return end
    local drop, keep, changed = {}, {}, false
    for _, t in ipairs(DRIVE_TAGS) do drop[t] = true end
    for _, n in ipairs(names) do
        if drop[n] then changed = true else keep[#keep + 1] = n end
    end
    if not changed then return end
    pcall(function()
        tags:Empty()
        for i, n in ipairs(keep) do tags[i] = FName(n) end
    end)
end

-- The sit montage. The host may load it once (a host that never ran an entry
-- itself); a client takes it only from memory (no synchronous load there: it
-- is in memory once that machine ran any get-in).
local sit = { obj = nil, tried = false }
local function sit_montage()
    if sit.obj and ue.valid(sit.obj) then return sit.obj end
    if S and S.role == "host" and not sit.tried then
        sit.tried = true
        ue.load_asset(SIT_MONTAGE, "vehicles")
    end
    sit.obj = ue.loaded_asset(SIT_MONTAGE, "vehicles")
    return sit.obj
end

-- A seat's pose (sdc_vehseats: "car" | "floor"): Chr_SittingFloor_Montage
-- for "floor" (the game's own sit-down pose, BP_PlayerCharacter @58424; same
-- loading rule as the sit montage; its Sitting? / regeneration branch is not
-- touched), Chr_SitInCar otherwise or when it is not in memory.
sit.FLOOR = "/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage"
function sit.pose(pose)
    if pose == "floor" then
        if not (sit.floor and ue.valid(sit.floor)) then
            if S and S.role == "host" and not sit.floor_tried then
                sit.floor_tried = true
                ue.load_asset(sit.FLOOR, "vehicles")
            end
            sit.floor = ue.loaded_asset(sit.FLOOR, "vehicles")
        end
        if sit.floor and ue.valid(sit.floor) then return sit.floor end
    end
    return sit_montage()
end

local function playing_sit(ch)
    local m = ue.try(function() return ch:GetCurrentMontage() end)
    if not ue.valid(m) then return false, m end
    local s = ue.short(m)
    return s:find("SitInCar", 1, true) ~= nil or s:find("SittingFloor", 1, true) ~= nil, m
end

local function stop_sit(ch)
    local yes, m = playing_sit(ch)
    if yes then pcall(function() ch:StopAnimMontage(m) end) end
end

-- Driver seat (PlayerLocation, as @11537) or its mirror across the vehicle's
-- centre line (the passenger seat the game does not have).
local function seat_transform(v, passenger)
    local pl = ue.prop(v, "PlayerLocation")
    if not ue.valid(pl) then return nil, nil end
    local loc = vec(ue.try(function() return pl:K2_GetComponentLocation() end))
    local r = ue.try(function() return pl:K2_GetComponentRotation() end)
    if not loc then return nil, nil end
    local rot = {
        Pitch = num(ue.try(function() return r.Pitch end)) or 0,
        Yaw = num(ue.try(function() return r.Yaw end)) or 0,
        Roll = 0,
    }
    if passenger then
        local o = ue.location(v)
        local rv = vec(ue.try(function() return v:GetActorRightVector() end))
        if not (o and rv) then return nil, nil end
        local s = (loc.X - o.X) * rv.X + (loc.Y - o.Y) * rv.Y + (loc.Z - o.Z) * rv.Z
        loc = { X = loc.X - 2 * s * rv.X, Y = loc.Y - 2 * s * rv.Y, Z = loc.Z - 2 * s * rv.Z }
    end
    return loc, rot
end

local function socket_loc(v, name)
    local mesh = ue.prop(v, "Mesh")
    if not ue.valid(mesh) then return nil end
    return vec(ue.try(function() return mesh:GetSocketLocation(FName(name)) end))
end

-- A character out of a vehicle on this machine (the host's copy of it):
-- VehicleInteraction(false) as the character's own exit path (@88168).
local function char_out(ch)
    apply(function() ch:VehicleInteraction(false, nil) end)
    local dc = ue.prop(ch, "VehicleDrivingComponent")
    if ue.valid(dc) then ue.set_prop(dc, "Vehicle", nil) end
    if ue.prop(ch, "InVehicle?") == true then ue.set_prop(ch, "InVehicle?", false) end
end

-- ExitVehicle's tail after Event_ExitVehicle (@216..519). With someone left
-- inside (a passenger who takes the wheel) the vehicle keeps running.
local function exit_tail(v, ch, still_occupied)
    local cmc = ch and ue.prop(ch, "CharacterMovement")
    if ue.valid(cmc) then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
    set_collision(v, still_occupied)
    if still_occupied then return end
    local m = mcomp(v)
    if m then pcall(function() m:SetHandbrakeInput(true) end) end
    local _, _, fc = fuel_of(v)
    if fc then pcall(function() fc:StopSpendFuel() end) end
end

-- Everything a driver keeps running (@7691..9142), without a character.
local function stop_services(v, still_occupied)
    engine_sound(v, false)
    clear_timer(v, "CheckWater")
    clear_timer(v, "Event_Noise")
    local _, _, fc = fuel_of(v)
    if fc then pcall(function() fc:StopSpendFuel() end) end
    local m = mcomp(v)
    if m then pcall(function() m:SetHandbrakeInput(true) end) end
    set_collision(v, still_occupied)
    if not still_occupied then strip_tags(v) end
end

-- ---------------------------------------------------------------------------
-- Host state
-- ---------------------------------------------------------------------------

-- vs[vehicle address] = { name, cls, driver_key, pax = { [seat] = client key }
--   (the passengers, seats 2+; sdc_vehseats), host_seat ("driver" |
--   "passenger"), host_idx / host_geo (the host's passenger seat and its
--   geometry), scope_key, scope_till, host_till, released_till, watch,
--   dirty, sig, got, occ_got, sent_at, upd, push_at }
local vs = {}
-- seats[remote pc key] = { vaddr, vname, seat = "driver" | "passenger", idx (1
--   = driver; nil = 2), geo (its seat's geometry, a copy), cap (knows seats
--   3+: VENTER "s2"), at, accept }
local seats = {}
local watch_n = 0
local outer_cache = {}
local prev_resolver = nil
local my_resolver = nil
local last_cap = -100

local function state_for(a, v)
    local st = vs[a]
    local name = ue.short(v)
    if not st or st.name ~= name then
        st = { name = name, cls = ue.class_name(v), pax = {} }
        vs[a] = st
    end
    st.pax = st.pax or {}
    return st
end

-- Vehicles whose player-0 calls the resolver decides: a client drives it,
-- our own call is running, or a client just left it.
local function recount_watch()
    local t, n = os.clock(), 0
    for _, st in pairs(vs) do
        st.watch = st.driver_key ~= nil or t < (st.scope_till or 0) or t < (st.released_till or 0)
        if st.watch then n = n + 1 end
    end
    watch_n = n
end

local function remote_pc_of(key)
    local r = S and S.remote and key and S.remote[key]
    if r and ue.valid(r.pc) and ue.valid(ue.prop(r.pc, "NetConnection")) then return r.pc end
    return nil
end

local function name_of(key)
    local r = S and S.remote and key and S.remote[key]
    return r and r.name or "?"
end

-- The game's vehicle functions can run for this client on the host only if
-- sdc_ctx can turn player 0 into its controller's index; otherwise they
-- would grab the host's character.
local function can_redirect(pc)
    if not ctx.active or not pc then return false end
    local n = ctx.index_of(pc)
    return n ~= nil and n ~= 0
end

local function host_in(vaddr)
    local hp = ue.local_pawn()
    if not hp or ue.prop(hp, "InVehicle?") ~= true then return false end
    local dc = ue.prop(hp, "VehicleDrivingComponent")
    local hv = ue.valid(dc) and ue.prop(dc, "Vehicle")
    return ue.valid(hv) and addr(hv) == vaddr
end

local function host_attached(vaddr)
    local hp = ue.local_pawn()
    return hp ~= nil and parent_vehicle(hp) == vaddr
end

-- The host sits in this vehicle: attached by the game's entry (synchronous)
-- or in its driving state. The attachment alone counts: the game's
-- VehicleInteraction(true) can stop half-way (see clear_area_flags).
local function host_seated(vaddr)
    return host_attached(vaddr) or host_in(vaddr)
end

-- ---------------------------------------------------------------------------
-- Seat log and the game's driving state
-- ---------------------------------------------------------------------------

-- One line for every seat change: who, which vehicle, which seat, why.
local function seat_log(who, vname, seat, why)
    log.info("vehicles: seat: %s -> %s in %s (%s)", tostring(who), tostring(seat), tostring(vname), tostring(why))
end

-- BP_PlayerCharacter.VehicleInteraction(true) (@151395 -> @62059) sets
-- InVehicle? = true, then RETURNS before VehicleDrivingComponent.Vehicle =
-- the vehicle (@62267) if the vehicle's IsHeld / InRefuellingArea? /
-- InRepairingArea? / InStorageArea? is set. Those are one flag per vehicle,
-- set by ANY player's overlap of the fuel / repair boxes (@15512 / @16795)
-- on this machine: in co-op the other player standing at the car sets them.
-- The character is then attached with InVehicle? = true and no Vehicle: the
-- exit key (@108525 IsValid(Vehicle)) and the driving input do nothing.
local SEATK = {
    area_flags = { "InRefuellingArea?", "InRepairingArea?", "InStorageArea?" },
    heal_after = 0.6, heal_every = 3,     -- s
    vis = 3,                              -- ECC_Visibility: the interact trace
    place_after = 1.5, place_every = 3,   -- s: client seat placement from VSTATE
    near = 800,                           -- cm: interact diagnostics
    helper = "/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C",
    -- CheckCanExitCarDriverSide / PassengerSide (@336 / @113): a capsule
    -- r 30, half height 50, TraceTypeQuery1 (Visibility) at the door socket
    door = { r = 30, half = 50, chan = 0, color = { R = 0, G = 0, B = 0, A = 0 } },
}

-- The door a player the mod puts out of a car steps out of (Event_ExitVehicle
-- places player 0 at the socket GetOutPasseenger names, without a check, and
-- resets the flag, @23482..24254). As the game's ExitVehicle picks it: the
-- driver side unless something stands there, then the passenger side if
-- that is free. Both blocked (the game would keep the player seated,
-- "Cannot exit vehicle"; a refused player cannot stay): the driver side.
-- Returns "d" / "p" and why. Up to 0.7.3 the refused host / client always
-- went to the driver door, into a wall or the next car if it stood there.
-- A seat 3+ (idx, geo: sdc_vehseats) gets out at its own door (its row's
-- exit), moved back by the row's x - a rear seat at the rear door: its own
-- side, else the other side, else the front doors; returns side, why, the
-- point and free (true: checked free; false: all blocked - its own front
-- door; nil: no trace).
function SEATK.exit_side(v, ch, idx, geo)
    local ksl = ue.ksl()
    local d = SEATK.door
    local function blocked_at(loc)
        if not (ksl and loc) then return nil end
        local ok, hit = pcall(function()
            return ksl:CapsuleTraceSingle(v, loc, loc, d.r, d.half, d.chan, false, { ch }, 0, {}, true,
                d.color, d.color, 0.0)
        end)
        if not ok or type(hit) ~= "boolean" then return nil end
        return hit
    end
    if not (idx and idx >= 3 and geo) then
        if not ksl then return "d", "no trace" end
        local db = blocked_at(socket_loc(v, "DriverSide"))
        if db ~= true then return "d", db == nil and "no trace" or "driver side free" end
        if blocked_at(socket_loc(v, "PassengerSide")) == false then return "p", "driver side blocked" end
        return "d", "both sides blocked"
    end
    local own = geo.exit == "p" and "p" or "d"
    local other = own == "p" and "d" or "p"
    local back = math.min(0, tonumber(geo.x) or 0)
    local fwd = back ~= 0 and M.vseats.axis(v, "GetActorForwardVector") or nil
    local function point(side, shifted)
        local s = socket_loc(v, side == "p" and "PassengerSide" or "DriverSide")
        if s and shifted and fwd then return { X = s.X + fwd.X * back, Y = s.Y + fwd.Y * back, Z = s.Z + fwd.Z * back } end
        return s
    end
    if not ksl then return own, "no trace", point(own, true), nil end
    for _, t in ipairs({ { own, true, "its own door" }, { other, true, "its own door blocked: the other side" },
                         { own, false, "both doors of its row blocked: the front door" },
                         { other, false, "both doors of its row blocked: the other front door" } }) do
        local loc = point(t[1], t[2])
        if loc then
            local b = blocked_at(loc)
            if b == false then return t[1], t[3], loc, true end
            if b == nil then return own, "no trace", point(own, true), nil end
        end
    end
    return own, "all doors blocked", point(own, false), false
end

-- Refuel / repair state of this machine's player (functions further down,
-- "Refuel / repair"). holds[vehicle address] = { va, vname, kind, t0, till,
-- dur, v0, has, out } while the game's hold (RetriggerableDelay(Duration) ->
-- UseGasCan / the repair kit) runs and until a client's tick has looked at
-- its end (fx.hold_end). One per vehicle, as the game's IsHeld and its delay:
-- a player standing in the boxes of two cars runs a hold on each.
local fx = {
    holds = {}, stuck_since = nil, da = {}, box_log = {},
    REFUEL = "Jig.InteractOptions.RefuelVehicle", REPAIR = "Jig.InteractOptions.RepairVehicle",
    GASCAN = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan",
    KIT = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_VehicleRepairKit.DA_VehicleRepairKit",
    keep_s = 3,     -- s: a VSTATE older than our report does not undo a refuel / repair done here
    stuck_s = 2,    -- s: "in a vehicle" while in none before the game's exit path runs
    -- a client's last step done by the host (fx.ask): the game's notes of its
    -- failed take (UseGasCan @585, the kit branch @2805) and of a full vehicle
    NO_GAS = "No gas found", NO_KIT = "No repair kits found",
    FULL = { refuel = "Gas full", repair = "Vehicle repaired" },
    GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
    GFL_NOTE = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI",
    NOTE_MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE",   -- S_NotificationDetails.Message
    asked = {},     -- [vehicle address .. kind] = os.clock() of this client's last ask
    ask_gap_s = 5,  -- s: one ask per hold (a hold lasts Duration, 10 s)
    end_s = 0.4,    -- s past the hold's time before a client's tick looks at its end (fx.hold_end)
    late_s = 2,     -- s past `till` with the game's flag still up: its last step never ran
}

-- Vehicle trader purchases (functions in "Vehicle trader"): asset paths and
-- the Blueprint struct field names (S_UpdateCount, the Jig item, the
-- DT_VehicleInfo "Trader" row).
local buy = {
    serial = 0, seen = {}, blocked = nil, spawn_hooked = false, spawn_tries = 0,
    MONEY = "/Game/Inventory/Items/DataAssets/Currency/DA_Money.DA_Money",
    DT = "/Game/Blueprints/Vehicles/Spawner/DT_VehicleInfo.DT_VehicleInfo",
    NOT_ACTOR = "/Script/CoreUObject.Object",
    SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass",
    F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    F_UC_UID = "UID_2_DC6DBB72457305316FAC19A4399A1CB5",
    F_UC_NEW = "NewCount_5_31E28E124BF695AFBB001A87164F9121",
    F_ROWS = "Vehicles_14_6F62AF3348A4068731BE22ACF609D1D5",
    F_CLASS = "Vehicles_11_54A68FE74C492D4E1322A1A28870318A",
    F_PRICE = "Price_10_6F62AF3348A4068731BE22ACF609D1D5",
    -- the host's refusal, as the client shows it
    WHY = { class = "машина не найдена", spawner = "нет точки выдачи машин", price = "цена неизвестна",
            inventory = "инвентарь не найден", take = "деньги не списались" },
}

local function clear_area_flags(v, held)
    local was = {}
    for _, f in ipairs(SEATK.area_flags) do
        if ue.prop(v, f) == true then
            ue.set_prop(v, f, false)
            was[#was + 1] = f
        end
    end
    -- IsHeld only for this machine's own player (a hold interaction runs where
    -- the key is held)
    if held and ue.prop(v, "IsHeld") == true then
        ue.set_prop(v, "IsHeld", false)
        was[#was + 1] = "IsHeld"
    end
    return was
end

local function driving_state(ch, vaddr)
    local inv = ue.prop(ch, "InVehicle?") == true
    local dc = ue.prop(ch, "VehicleDrivingComponent")
    local hv = ue.valid(dc) and ue.prop(dc, "Vehicle")
    return inv, ue.valid(hv) and addr(hv) == vaddr
end

-- A character attached to vehicle v for a while must have the game's driving
-- state for it; if VehicleInteraction stopped half-way, run it again.
local att = {}   -- [character address] = { vaddr, t, healed }

-- Dead, or down (sdc_down's knockdown, any of its phases): no seat heal, no
-- get-in; the host's tick unseats a downed client (VSEAT none|downed).
function SEATK.out_cold(ch)
    if ue.prop(ch, "PlayerDead?") == true then return true end
    local dn = package.loaded["sdc_down"]
    if type(dn) ~= "table" or type(dn.is_down) ~= "function" then return false end
    local ok, v = pcall(dn.is_down, ch)
    return ok and v == true
end

local function heal_seated(ch, v, who, held)
    local ca, va = addr(ch), addr(v)
    if not ca or not va then return end
    local t = os.clock()
    local r = att[ca]
    if not r or r.vaddr ~= va then
        att[ca] = { vaddr = va, t = t }
        return
    end
    if t - r.t < SEATK.heal_after or t - (r.healed or -100) < SEATK.heal_every then return end
    if SEATK.out_cold(ch) then return end
    local inv, has = driving_state(ch, va)
    if inv and has then return end
    r.healed = t
    local flags = clear_area_flags(v, held)
    apply(function() ch:VehicleInteraction(true, v) end)
    local inv2, has2 = driving_state(ch, va)
    log.warn("vehicles: seat: %s sat in %s without the game's driving state (InVehicle?=%s, Vehicle=%s; flags cleared: %s) -> VehicleInteraction again: InVehicle?=%s Vehicle=%s",
        tostring(who), ue.short(v), tostring(inv), tostring(has), #flags > 0 and table.concat(flags, ",") or "none",
        tostring(inv2), tostring(has2))
end

local function forget_att(ch)
    local ca = ch and addr(ch)
    if ca then att[ca] = nil end
end

-- ---------------------------------------------------------------------------
-- Seated characters as every machine shows them
-- ---------------------------------------------------------------------------
-- The game shows its one driver (Interact_GetInVehicle @11180 / @11348) by
--   K2_AttachToActor(vehicle, KeepWorld x3, bWeldSimulatedBodies = true) at
--   the PlayerLocation seat, and PlayMontage(Chr_SitInCar_Montage) = Svr_Montage
--   -> MC_Montage: a one-frame montage looping in DefaultSlot (section
--   Default -> Default) until Event_ExitVehicle's StopAnimMontage (@23932,
--   local only). The AnimBP itself has no sitting state (InVehicle? only
--   turns the foot / spine IK and the aim offset off).
-- Engine rules that break it for the other machines in co-op:
--  1. A welded root "simulates physics" (its body is the vehicle's), so
--     AActor::GatherCurrentMovement replicates NO attachment for it, only the
--     vehicle body's state as its ReplicatedMovement (bRepPhysics off): the
--     others see the player detached at the vehicle's origin - "the host
--     sits under the car" on the client.
--  2. On the host a client's mesh ticks its pose only from that client's
--     moves (ACharacter::PossessedBy sets bOnlyAllowAutonomousTickPose). A
--     client welded into its own copy of the vehicle sends no moves (the
--     movement component skips a root that simulates physics), so the host
--     keeps the pose it had at the door: "the passenger stands in the car".
--  3. The exit stops the sit montage only where it ran: the others keep the
--     seated pose after the player got out.
--  4. A character's mesh blocks Visibility, the channel of the interact trace
--     (BP_JigHelperComp.TryInteract @431 / TraceToWorld @436), and a
--     character's JigCanInteract is false: a player sitting in the car hides
--     the car from everyone else's interact key and prompt (the host could
--     not get into a car the client drove).
-- So, on every machine, for every character attached to a vehicle:
--   * attached without welding (host: every seated copy; client: its own
--     player) - the attachment replicates, moves keep coming;
--   * mesh ignores Visibility while seated (others' characters);
--   * the sit montage plays (started here when something else is playing);
--   * host: a client's mesh ticks its own pose while seated;
-- and when they get out: montage stopped, Visibility / pose tick restored.
local seated = {}   -- [character address] = { name, vaddr, vname, vis, tickpose, unwelded, sit_n, since }

-- PlayerState.PlayerId: the same number on every machine.
local function pawn_id(p)
    local ps = p and ue.prop(p, "PlayerState")
    if not ue.valid(ps) then return nil end
    local ok, id = pcall(function() return ps:GetPlayerId() end)
    if ok and type(id) == "number" then return id end
    local v = ue.prop(ps, "PlayerId")
    if type(v) == "number" then return v end
    return nil
end

local function char_label(ch)
    if locally_controlled(ch) then
        return (S and S.role == "host") and "host" or "this player"
    end
    local ps = ue.prop(ch, "PlayerState")
    local n = ue.valid(ps) and ue.str(ue.try(function() return ps:GetPlayerName() end)) or ""
    if n == "" then n = ue.short(ch) end
    return n
end

-- Attached, not welded. UnWeldFromParent keeps the attachment; without it a
-- re-attach without welding does the same (DetachFromActor unwelds).
local function unweld(ch, v)
    local cap = ue.prop(ch, "CapsuleComponent")
    if ue.valid(cap) and ue.call(cap, "UnWeldFromParent") then return "unwelded" end
    local ok = pcall(function()
        ch:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD)
        ch:K2_AttachToActor(v, FName("None"), KEEP_WORLD, KEEP_WORLD, KEEP_WORLD, false)
    end)
    return ok and "re-attached unwelded" or "unweld FAILED"
end

-- A seat 3+ taken (SEATK.rear_set; or three or more in one vehicle): the
-- camera boom of a front seat passes through the players behind it, whose
-- capsule / mesh would push the camera into the head - with two as well (the
-- driver and seat 3 behind it, after the others got out). While so, another
-- player's seated capsule and mesh ignore the Camera channel (as the vehicle
-- mesh does for its seated players, @11114); back when they get out or only
-- the front row is taken again. r.cam keeps the old responses by component
-- name (no UObject kept).
SEATK.CAM_PARTS = { "CapsuleComponent", "Mesh" }
function SEATK.cam(ch, r, want)
    if want and r.cam == nil then
        local was = {}
        for _, part in ipairs(SEATK.CAM_PARTS) do
            local c = ue.prop(ch, part)
            local cr = ue.valid(c) and ue.try(function() return c:GetCollisionResponseToChannel(ECC_CAMERA) end)
            if type(cr) == "number" and cr ~= ECR_IGNORE then
                was[part] = cr
                pcall(function() c:SetCollisionResponseToChannel(ECC_CAMERA, ECR_IGNORE) end)
            end
        end
        r.cam = was
    elseif not want and r.cam ~= nil then
        for part, cr in pairs(r.cam) do
            local c = ue.prop(ch, part)
            if ue.valid(c) then pcall(function() c:SetCollisionResponseToChannel(ECC_CAMERA, cr) end) end
        end
        r.cam = nil
    end
end

-- pose: "car" | "floor" (the seat's, sdc_vehseats); crowd: three or more sit
-- in this vehicle on this machine (SEATK.cam; nil: left as it is - the
-- seat changes between ticks, seat_tick decides).
local function seat_mark(ch, v, va, label, is_local, pose, crowd)
    local ca = addr(ch)
    if not ca then return end
    local name = ue.short(ch)
    local r = seated[ca]
    local fresh = false
    if not r or r.name ~= name or r.vaddr ~= va then
        r = { name = name, vaddr = va, vname = ue.short(v), since = os.clock(), sit_n = 0 }
        seated[ca] = r
        fresh = true
    end
    local host = S and S.role == "host"
    if not r.unwelded and (host or is_local) then r.unwelded = unweld(ch, v) end
    local mesh = ue.prop(ch, "Mesh")
    if ue.valid(mesh) then
        if not is_local then
            local cur_r = ue.try(function() return mesh:GetCollisionResponseToChannel(SEATK.vis) end)
            if type(cur_r) == "number" and cur_r ~= ECR_IGNORE then
                if r.vis == nil then r.vis = cur_r end
                pcall(function() mesh:SetCollisionResponseToChannel(SEATK.vis, ECR_IGNORE) end)
            end
        end
        if host and not is_local and ue.prop(mesh, "bOnlyAllowAutonomousTickPose") == true then
            if r.tickpose == nil then r.tickpose = true end
            ue.set_prop(mesh, "bOnlyAllowAutonomousTickPose", false)
        end
    end
    if not is_local and crowd ~= nil then SEATK.cam(ch, r, crowd) end
    -- the seat's pose: started when another montage (or none) plays
    local sm = sit.pose(pose)
    local m = ue.try(function() return ch:GetCurrentMontage() end)
    if not (sm and ue.valid(m) and ue.short(m) == ue.short(sm)) then
        if sm and pcall(function() ch:PlayAnimMontage(sm, 1.0, FName("None")) end) then
            r.sit_n = r.sit_n + 1
            if r.sit_n <= 3 or r.sit_n % 20 == 0 then
                log.info("vehicles: pose: %s in %s: %s started here (%d; was playing %s)",
                    label, r.vname, ue.short(sm), r.sit_n, ue.valid(m) and ue.short(m) or "nothing")
            end
        elseif not sm then
            info_once("nosit", "vehicles: pose: Chr_SitInCar_Montage not loaded here; seated players keep their pose")
        end
    end
    if fresh then
        -- attach: unwelded / re-attached unwelded / unweld FAILED (we fixed the
        -- weld here) or "replicated" (left to the engine); interact trace: our
        -- trace now passes this player's mesh ("opened"), "own player" or
        -- "unchanged"; pose tick: "forced on" (host, remote player) or "engine's"
        log.info("vehicles: pose: %s seated in %s here (attach: %s; interact trace: %s; pose tick: %s; sit montage: %s)",
            label, r.vname, tostring(r.unwelded or "replicated"),
            is_local and "own player" or (r.vis ~= nil and "opened" or "unchanged"),
            r.tickpose ~= nil and "forced on" or "engine's", playing_sit(ch) and "playing" or "missing")
    end
end

local function seat_clear(ca, r, ch, label)
    seated[ca] = nil
    if not ch then return end
    SEATK.cam(ch, r, false)
    local mesh = ue.prop(ch, "Mesh")
    if ue.valid(mesh) then
        if r.vis ~= nil then pcall(function() mesh:SetCollisionResponseToChannel(SEATK.vis, r.vis) end) end
        if r.tickpose ~= nil then
            -- the engine's rule again: only while a remote player controls it
            local pc = ue.prop(ch, "Controller")
            if ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) then
                ue.set_prop(mesh, "bOnlyAllowAutonomousTickPose", true)
            end
        end
    end
    local was = playing_sit(ch)
    stop_sit(ch)
    log.info("vehicles: pose: %s out of %s here (sit montage %s; interact trace / pose tick restored)",
        label, r.vname, was and "stopped" or "already off")
end

-- Every machine, every tick: everyone attached to a vehicle shown seated,
-- everyone who left shown standing (clients also set InVehicle? and hide the
-- weapons of other players, as the game does for its own player).
local function seat_tick(list)
    local seen = {}
    local host = S and S.role == "host"
    -- who sits in which vehicle (one attachment read each), how many per
    -- vehicle and which have a seat 3+ taken (SEATK.cam), whose seat has the
    -- floor pose (SEATK.floor_set)
    local pv, n_in = {}, {}
    for i, ch in ipairs(list) do
        local va = parent_vehicle(ch)
        pv[i] = va or false
        if va then n_in[va] = (n_in[va] or 0) + 1 end
    end
    local floor = next(n_in) and SEATK.floor_set(list) or {}
    local rear = next(n_in) and SEATK.rear_set() or {}
    for i, ch in ipairs(list) do
        local va = pv[i] or nil
        local v = va and cur.by[va]
        local ca = addr(ch)
        if ca and v and ue.valid(v) then
            seen[ca] = true
            local is_local = locally_controlled(ch)
            local first = not seated[ca] or seated[ca].vaddr ~= va
            seat_mark(ch, v, va, char_label(ch), is_local, floor[ca] and "floor" or "car", n_in[va] >= 3 or rear[va] == true)
            if not host and not is_local then
                if ue.prop(ch, "InVehicle?") ~= true then ue.set_prop(ch, "InVehicle?", true) end
                if first then pcall(function() ch:SetWeaponsAndBackpackVisibility(true) end) end
            end
        end
    end
    for ca, r in pairs(seated) do
        if not seen[ca] then
            local ch = nil
            for _, c in ipairs(list) do
                if addr(c) == ca and ue.short(c) == r.name then ch = c break end
            end
            if ch and not host and not locally_controlled(ch) then
                ue.set_prop(ch, "InVehicle?", false)
                pcall(function() ch:SetWeaponsAndBackpackVisibility(false) end)
            end
            if ch then seat_clear(ca, r, ch, char_label(ch)) else seated[ca] = nil end
        end
    end
    -- seat-heal records of characters that sit nowhere now (out, or gone
    -- while seated: a client that left had no character to forget)
    for ca in pairs(att) do
        if not seen[ca] then att[ca] = nil end
    end
end

-- The game's own replicated stop (BPI_Player.StopMontage -> Svr_StopMontage
-- -> MC_StopMontage): the sit montage of a player who got out ends on every
-- other machine too (IncludeLocal false: the exit already stopped it here).
local function stop_sit_everywhere(ch)
    local sm = sit_montage()
    if ch and sm then pcall(function() ch:StopMontage(sm, false) end) end
    -- (a floor seat's pose: only once that montage was in use here)
    if ch and sit.floor and ue.valid(sit.floor) then pcall(function() ch:StopMontage(sit.floor, false) end) end
end

-- The host is pressing the interact key on this vehicle right now
-- (TryInteract @1363 sets InteractExecutedActor before OnExecuteInteract).
-- The game does NOT clear it when the key is released (@107351 only calls
-- OnStopExecuteInteract on it), only when the inventory closes (@107919 ->
-- @107660, BP_JigHelperComp @2655 -> @2478): for a vehicle host_press_done
-- clears it after every TryInteract, so here it means "inside that press".
-- `skip_press`: the caller read the key press already in this same call (no
-- game code ran since), only the look is left to check.
local function host_interacting(vaddr, press_only, skip_press)
    local hp = ue.local_pawn()
    local hc = hp and ue.prop(hp, "BP_JigHelperComp")
    if not ue.valid(hc) then return false end
    if not skip_press then
        local ie = ue.prop(hc, "InteractExecutedActor")
        if ue.valid(ie) and addr(ie) == vaddr then return true end
    end
    if press_only then return false end
    -- looking at it: TraceToWorld sets CurrentTracActor (@2382) before
    -- OnBeginInteract shows the prompt through GetHUD(vehicle) = player 0
    local ta = ue.prop(hc, "CurrentTracActor")
    return ue.valid(ta) and addr(ta) == vaddr
end

local function vehicle_context(wco, a0)
    local a = a0 or addr(wco)
    if not a then return nil, nil end
    local st = vs[a]
    if st and st.watch then return a, st end
    local c = outer_cache[a]
    if c == nil then
        c = false
        -- ue.valid first: GetOuter on a null object (address 0, not nil)
        -- crashes the game, pcall cannot catch it
        local o = ue.valid(wco) and ue.try(function() return wco:GetOuter() end) or nil
        local oa = ue.valid(o) and addr(o)
        if oa and vs[oa] then c = oa end
        outer_cache[a] = c
    end
    if c then
        st = vs[c]
        if st and st.watch then return c, st end
    end
    return nil, nil
end

-- sdc_ctx asks this (through the chain) for every player-0 call on the host
-- while remote players are connected: a remote controller, false (the
-- host's player 0) or nil (no opinion).
local function resolve(wco, a0)
    if watch_n == 0 or not S or S.role ~= "host" then return nil end
    local a, st = vehicle_context(wco, a0)
    if not st then return nil end
    local t = os.clock()
    -- the window after a client's entry (its 0.1 s delayed VehicleInteraction)
    -- is that client's - but not the host's own key press on this vehicle in
    -- that second: its get-in is the host's (0.6.62: the host pressed 0.4 s
    -- after a client got in; the game's get-in seated the client again and
    -- put a VehicleUI on the host's screen that no exit ever removed)
    -- (the host's key press is read at most once per call: ~10 engine reads)
    local press = nil
    if st.scope_key and t < (st.scope_till or 0) then
        local take = applying > 0
        if not take then
            press = host_interacting(a, true)
            take = not press
        end
        if take then
            local pc = remote_pc_of(st.scope_key)
            if pc then return pc end
        end
    end
    if press == nil then press = host_interacting(a, true) end
    if press then
        st.host_till = t + HOST_WINDOW_S
        return false
    end
    if st.driver_key then
        -- not pressing (just read): looking at it?
        if host_interacting(a, false, true) then st.host_till = t + HOST_WINDOW_S end
        if t < (st.host_till or 0) then return false end
        -- the host's own refuel / repair hold on it: UseGasCan / the repair
        -- kit (@1887 / @1923, Duration after the press) and the timer bar's
        -- GetGameHUD (every 0.01 s) are the host's, not the driver's
        local h = fx.holds[a]
        if h and t < h.till then return false end
        -- the host sits in it (as a passenger): its own exit / input is the host's
        if host_seated(a) then return false end
        local pc = remote_pc_of(st.driver_key)
        if pc then return pc end
    end
    if t < (st.released_till or 0) then return false end
    return nil
end

my_resolver = function(wco, a)
    -- fast: no vehicle watched (nobody drives, no window open) or not the
    -- host - resolve() would answer nil: straight to the next resolver
    if watch_n == 0 or not S or S.role ~= "host" then
        if prev_resolver then return prev_resolver(wco, a) end
        return nil
    end
    local ok, r = pcall(resolve, wco, a)
    if not ok then
        log.err_throttled("veh.resolve", "vehicles: resolver: %s", tostring(r))
        r = nil
    end
    if r ~= nil then return r end
    if prev_resolver then return prev_resolver(wco, a) end
    return nil
end

-- sdc_ctx's idle check: true exactly when my_resolver would answer nil for
-- this address now without side effects (its fast branch + the chain behind).
local function resolver_idle(a)
    if watch_n == 0 or not S or S.role ~= "host" then
        return ctx.resolver_idle ~= nil and ctx.resolver_idle(prev_resolver, a)
    end
    return false
end

local function ensure_resolver()
    if not ctx.SCOPE_API then
        info_once("noscope", "vehicles: sdc_ctx has no SCOPE_API: clients cannot drive through the host")
        return false
    end
    if ctx.scope_resolver ~= my_resolver then
        prev_resolver = ctx.scope_resolver
        ctx.scope_resolver = my_resolver
        if ctx.set_idle_check then ctx.set_idle_check(my_resolver, resolver_idle) end
        log.info("vehicles: player-0 scope for vehicles installed (chained: %s)", prev_resolver and "yes" or "no")
    end
    return true
end

-- The server-side copy of a seated client keeps the vehicle's position
-- instead of the client's reported one (client_movement_authority).
local function hold_position(ch, seat)
    local cmc = ue.prop(ch, "CharacterMovement")
    if not ue.valid(cmc) then return end
    if seat.accept == nil then seat.accept = ue.prop(cmc, "bServerAcceptClientAuthoritativePosition") == true end
    ue.set_prop(cmc, "bServerAcceptClientAuthoritativePosition", false)
end

local function release_position(ch, seat)
    if seat.accept == nil or not ch then return end
    local cmc = ue.prop(ch, "CharacterMovement")
    if ue.valid(cmc) then ue.set_prop(cmc, "bServerAcceptClientAuthoritativePosition", seat.accept) end
    seat.accept = nil
end

-- The host-side copy of a remote driver's vehicle must keep simulating and
-- hitting zombies when the host does not look at it: the AI optimizer's
-- "beyond the last layer" (@28247) hides the mesh and turns the hit boxes
-- off; the game's own handler with "visible" turns them back on.
local function keep_awake(v, st)
    local m = mcomp(v)
    if m and ue.prop(m, "bUpdateOnlyIfRendered") == true then
        if st.upd == nil then st.upd = true end
        ue.set_prop(m, "bUpdateOnlyIfRendered", false)
    end
    local mesh = ue.prop(v, "Mesh")
    local hb = ue.prop(v, "HitBoxCollision")
    local hidden = ue.valid(mesh) and ue.try(function() return mesh:IsVisible() end) == false
    local nohits = ue.valid(hb) and ue.try(function() return hb:GetGenerateOverlapEvents() end) == false
    if hidden or nohits then
        local ok = ue.call(v, AIO_EVENT, false, 0, true)
        info_once("aio:" .. st.name, "vehicles: %s was optimized away on the host (hidden=%s hitbox off=%s): woken for its remote driver (ok=%s)",
            st.name, tostring(hidden), tostring(nohits), tostring(ok))
    end
end

-- Services the game's entry flow starts for a driver; re-asserted while a
-- client drives (the host's own exit as a passenger stops them).
local function host_services(v)
    local fuel = fuel_of(v)
    local _, _, fc = fuel_of(v)
    local running = fuel ~= nil and fuel > 0
    if running and ue.prop(v, "EngineOn?") ~= false then engine_sound(v, true) end
    if not timer_active(v, "CheckWater") then set_timer(v, "CheckWater", 0.5) end
    if fc and not timer_active(fc, "FuelSpend") then pcall(function() fc:StartFuelSpend() end) end
    if running and not timer_active(v, "Event_Noise") then set_timer(v, "Event_Noise", 2) end
    ensure_tags(v)
end

-- Interact_GetInVehicle creates a VehicleUI on the screen of the machine
-- that runs it: on the host that is the host's screen. Ours goes again; one
-- the host already had (it sits in this vehicle) stays.
local function drop_new_ui(v, old)
    local ui = ue.prop(v, "VehicleUI")
    if ue.valid(ui) and (not old or addr(ui) ~= addr(old)) then
        pcall(function() ui:RemoveFromParent() end)
    end
    if old and ue.valid(old) then
        ue.set_prop(v, "VehicleUI", old)
    else
        ue.set_prop(v, "VehicleUI", nil)
    end
end

-- The vehicle panel (VehicleUI_C: fuel, health, MPH). The game's get-in
-- (@7890) creates one on the screen of the machine that runs it and keeps
-- it in self.VehicleUI, over any earlier one; the exit removes only
-- self.VehicleUI (@23977, then None @23318). A second get-in without an exit
-- leaves the first panel on screen for good. Here: a panel only for this
-- machine's player, only for the vehicle it sits in. The once-a-second
-- safety net (a FindAllOf) runs only while this player sits, and AFTER_S
-- after it got out or after any seat event (hud.check).
local hud = { next_at = -100, logged = {}, until_at = -100, AFTER_S = 10 }

function hud.widgets()
    local out = {}
    for _, w in ipairs(ue.find_all("VehicleUI_C")) do
        if ue.valid(w) and not ue.short(w):find("^Default__")
            and ue.try(function() return w:IsInViewport() end) == true then
            out[#out + 1] = w
        end
    end
    return out
end

-- Every panel on this screen except `keep` goes; returns how many.
function hud.prune(keep, why)
    local ka = keep and ue.valid(keep) and addr(keep) or nil
    local n = 0
    for _, w in ipairs(hud.widgets()) do
        if addr(w) ~= ka and pcall(function() w:RemoveFromParent() end) then
            n = n + 1
            local k = ue.short(w)
            if not hud.logged[k] then
                hud.logged[k] = true
                log.info("vehicles: hud: removed %s from this screen (%s)", k, why)
            end
        end
    end
    return n
end

-- This machine's player: the panel of the vehicle it sits in, or none.
function hud.scan(why)
    local lp = ue.local_pawn()
    local la = lp and parent_vehicle(lp)
    local v = la and cur.by[la]
    if v then
        local own = ue.prop(v, "VehicleUI")
        -- (no panel of its own: which one is right cannot be told; all stay)
        if not ue.valid(own) then return 0 end
        return hud.prune(own, why)
    end
    return hud.prune(nil, why)
end

-- A seat event (get-in, exit, refusal, a seat ended): check now, and keep
-- the safety net on for AFTER_S.
function hud.check(why)
    hud.until_at = math.max(hud.until_at, os.clock() + hud.AFTER_S)
    return hud.scan(why)
end

-- Safety net, at most once a second, only while this machine's player sits
-- or AFTER_S after it sat (0.7.3: a FindAllOf every second on every machine,
-- 0.5-0.7 ms/s, almost always finding nothing).
function hud.tick()
    local t = os.clock()
    if t < hud.next_at then return end
    hud.next_at = t + 1
    local lp = ue.local_pawn()
    if lp and parent_vehicle(lp) then hud.until_at = t + hud.AFTER_S end
    if t >= hud.until_at then return end
    hud.scan("left on screen: this player sits in no vehicle, or it is another vehicle's panel")
end

local host_seat_driver   -- forward (promotion calls it from host_unseat)

-- VSEAT|kind|extra|... (the seat fields of sdc_vehseats.vseat_fields)
local function send_seat(pc, kind, extra, ...)
    if pc then net.send_to(pc, "VSEAT", kind, extra or "", ...) end
end

-- The seats that count for remote player `key` in this vehicle (`cap`: it
-- knows seats 3+; nil = its record's).
function SEATK.layout(st, key, cap)
    local seat = key and seats[key]
    if cap == nil then cap = seat and seat.cap end
    return M.vseats.layout(st.cls, { cap = cap == true, passengers = on("vehicle_passengers") })
end

-- Somebody besides remote player `key` sits in vehicle a.
function SEATK.others(a, st, key)
    for _, k in pairs(st.pax or {}) do
        if k ~= key then return true end
    end
    return host_seated(a)
end

-- VSEAT passenger: the driver's name, the seat, its geometry (the client
-- sits where the host put it). tell = false: the same seat again, no notice.
-- Nobody at the wheel (a move by the seat key while it is free, K10): no
-- name - the client says "Seat N of M: nobody drives" (up to then the
-- host's name, also with the host out of the car).
function SEATK.tell_pass(pc, st, key, idx, geo, tell, driver_name)
    local lay = SEATK.layout(st, key)
    local seat = seats[key]
    local dn = driver_name or (st.driver_key and name_of(st.driver_key))
        or ((seat and host_seated(seat.vaddr) and st.host_seat ~= "passenger") and cfg.player_name()) or ""
    send_seat(pc, "passenger", dn, table.unpack(M.vseats.vseat_fields(idx, lay.rank[idx] or idx, lay.count, geo, tell)))
end

-- VSEAT driver: "Seat 1 of M" only in a car of more than 2 seats with
-- somebody else in it (a driver alone is told nothing, as before).
function SEATK.tell_driver(pc, st, key, a, tell)
    local lay = SEATK.layout(st, key)
    if tell == nil then tell = lay.count > 2 and SEATK.others(a, st, key) end
    send_seat(pc, "driver", "", table.unpack(M.vseats.vseat_fields(1, 1, lay.count, M.vseats.SEAT1, tell)))
end

-- The host sits in the car a client now takes the wheel of (a passenger
-- with its seat key, or a client getting in while the host sits as a
-- passenger): the
-- get-in's delayed step (VehicleInteraction(true) on player 0 0.1 s later,
-- @1706..1818) runs now for the new driver, and that client's player-0
-- window closes at once. Kept open for the game's step, the window also took
-- the host's own exit key (ExitVehicle asks for player 0 as that step does,
-- the two cannot be told apart): the game's exit ran for the new driver (out
-- of the car), the host stayed seated, 2 s later the driver was put out for
-- good and the host moved to the wheel (3-4 players getting out together;
-- up to 0.8.1 also with two). The game's own step still comes, to whoever player 0 is
-- then: the host in its seat (it has that driving state already;
-- SEATK.step_seen), the new driver again, or the host who got out in
-- between (undone in on_vi_post).
function SEATK.early_step(v, a, st, key, ch)
    if parent_vehicle(ch) ~= a then return end
    apply(function() ch:VehicleInteraction(true, v) end)
    st.scope_till = os.clock()
    st.step_till = os.clock() + SCOPE_S
    log.info("vehicles: seat: the host sits in %s: the get-in's delayed step ran now for %s, its player-0 window closed (the host's own exit stays the host's)",
        st.name, name_of(key))
end

-- The game's own delayed step of a get-in that SEATK.early_step ran already
-- reached the host. In its seat it changed only the camera: the step plays
-- the boom timeline from its start (@63193: the on-foot length, then out
-- again), so it goes back to its end (the seated length). Out of the car
-- (in_seat false) on_vi_post undid it.
function SEATK.step_seen(hp, st, in_seat)
    st.step_till = nil
    local how = "undone (it got out in between)"
    if in_seat then
        local tl = ue.prop(hp, "TL_VehicleCameraArmLength")
        local len = ue.valid(tl) and ue.try(function() return tl:GetTimelineLength() end)
        local ok = type(len) == "number" and pcall(function() tl:SetNewTime(len) end)
        how = "kept (it sits there); camera " .. (ok and "back at its seated length" or "left to the game")
    end
    log.info("vehicles: seat: the game's get-in step for the new driver of %s reached the host (expected, it ran for the driver already): %s",
        st.name, how)
end

-- `cap`: the client knows seats 3+ (nil: as its record says); `tell`: nil =
-- SEATK.tell_driver decides, "later" = no VSEAT here (the caller sends it
-- once it checked the seat: SEATK.take_wheel). Returns the game's get-in's ok.
host_seat_driver = function(key, pc, ch, v, st, why, cap, tell)
    local a = addr(v)
    st.driver_key = key
    st.scope_key, st.scope_till = key, os.clock() + SCOPE_S
    st.released_till = nil
    recount_watch()
    pcall(function() v:SetOwner(pc) end)
    local seat = seats[key] or {}
    seats[key] = seat
    seat.vaddr, seat.vname, seat.seat, seat.at = a, st.name, "driver", os.clock()
    seat.idx, seat.geo = 1, nil
    if cap ~= nil then seat.cap = cap end
    M.vseats.drop(st, key)
    SEATK.took(st, name_of(key))
    hold_position(ch, seat)
    local old_ui = ue.prop(v, "VehicleUI")
    if not ue.valid(old_ui) then old_ui = nil end
    local host_was = host_attached(a)
    -- the host standing at the fuel / repair box must not stop the game's
    -- VehicleInteraction(true) for this client (runs 0.1 s after the entry)
    clear_area_flags(v, false)
    local ok, err = apply(function() v:Interact_GetInVehicle() end)
    clear_area_flags(v, false)
    -- the host sits in this car: its own exit key must not meet this
    -- client's player-0 window (the attachment: right after the host's own
    -- exit as the driver its InVehicle? is still set, and its key is done)
    if host_was then SEATK.early_step(v, a, st, key, ch) end
    drop_new_ui(v, host_seated(a) and old_ui or nil)
    hud.check("the game's get-in for " .. name_of(key) .. " ran on this machine")
    if parent_vehicle(ch) ~= a then
        log.err("vehicles: the game's entry did not seat %s in %s (player-0 redirect?)", name_of(key), st.name)
    end
    if host_attached(a) and not host_was then
        local hp = ue.local_pawn()
        if hp then pcall(function() hp:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end) end
        log.err("vehicles: the game's entry for %s attached the HOST to %s; detached again", name_of(key), st.name)
    end
    -- the game welded the character: unweld now, so its seat replicates (a
    -- passenger taking the wheel was unwelded in its seat already: the
    -- get-in welded it again, so its record's "unwelded" goes first - up to
    -- 0.8.1 a promoted passenger stayed welded: the others saw it at its old
    -- seat or under the car)
    local r = seated[addr(ch) or -1]
    if r then r.unwelded = nil end
    if parent_vehicle(ch) == a then seat_mark(ch, v, a, name_of(key), false) end
    local req = set_requires(v, true)
    keep_awake(v, st)
    st.dirty = true
    M.stats.enters = M.stats.enters + 1
    if tell ~= "later" then SEATK.tell_driver(pc, st, key, a, tell) end
    seat_log(name_of(key), st.name, "driver", why or "driver seat free")
    log.info("vehicles: %s drives %s (game entry ok=%s%s, replicated inputs=%s, owner set)",
        name_of(key), st.name, tostring(ok), ok and "" or (" " .. tostring(err)), tostring(req))
    return ok
end

-- idx: the seat (2.., sdc_vehseats); cap: the client knows seats 3+.
local function host_seat_passenger(key, pc, ch, v, st, driver_name, why, idx, cap)
    local a = addr(v)
    idx = idx or 2
    local geo = M.vseats.geo(st.cls, idx) or M.vseats.geo(st.cls, 2)
    local loc, rot = M.vseats.xf_geo(v, geo)
    if not loc then
        loc, rot = seat_transform(v, true)
        if idx > 2 then log.warn("vehicles: seat %d of %s has no world position here; %s put in the mirror seat", idx, st.name, name_of(key)) end
    end
    local seat = seats[key] or {}
    seats[key] = seat
    seat.vaddr, seat.vname, seat.seat, seat.at = a, st.name, "passenger", os.clock()
    seat.idx, seat.geo = idx, geo
    if cap ~= nil then seat.cap = cap end
    M.vseats.set(st, idx, key)
    hold_position(ch, seat)
    -- the game's driving state first (InVehicle?, its Vehicle): then the
    -- seat's overlap with the fuel / repair box no longer counts this player
    clear_area_flags(v, false)
    apply(function() ch:VehicleInteraction(true, v) end)
    -- not welded: a welded seat would not replicate (see "Seated characters")
    pcall(function() ch:K2_AttachToActor(v, FName("None"), KEEP_WORLD, KEEP_WORLD, KEEP_WORLD, false) end)
    if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
    local m = sit.pose(geo.pose)
    if m then pcall(function() ch:PlayMontage(m, 1.0) end) end
    clear_area_flags(v, false)
    if parent_vehicle(ch) == a then seat_mark(ch, v, a, name_of(key), false, geo.pose) end
    set_collision(v, true)
    st.dirty = true
    M.stats.passengers = M.stats.passengers + 1
    SEATK.tell_pass(pc, st, key, idx, geo, true, driver_name)
    seat_log(name_of(key), st.name, "passenger seat " .. idx, why or (tostring(driver_name) .. " drives"))
    log.info("vehicles: %s sits as a passenger in %s next to %s (seat %d at %s)", name_of(key), st.name,
        tostring(driver_name), idx, loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "?")
end

-- Client `key` in seat idx takes the wheel (its seat key, nobody drives:
-- SEATK.client_switch) through the game's get-in (player 0 = that client).
-- Checked after: the client at the wheel, a host passenger still in its own
-- seat. A get-in that seated the host instead (the player-0 redirect did not
-- work: with the host in the car the older checks in host_seat_driver cannot
-- see it) is undone - the client back in its seat, the host in its own,
-- nobody drives. Returns true when the client drives.
function SEATK.take_wheel(v, a, st, key, pc, ch, idx)
    local seat = seats[key]
    local geo = (seat and seat.geo) or M.vseats.geo(st.cls, idx)
    local hp = ue.local_pawn()
    local hidx = M.vseats.host_idx(st)
    local h0 = hidx and hp and host_attached(a) and ue.location(hp) or nil
    local waited = st.wheel_wait
    M.stats.promoted = M.stats.promoted + 1
    -- (its VSEAT driver only once the check passed: a client told "you now
    -- drive" and put back in its seat a moment later kept that wrong notice)
    host_seat_driver(key, pc, ch, v, st, string.format("the passenger in seat %d takes the free wheel (its seat key)", idx), nil, "later")
    local near = M.vseats.NEAR * M.vseats.NEAR
    local l1, cl = seat_transform(v, false), ue.location(ch)
    local ok_c = not (l1 and cl) or d2(l1, cl) <= near
    local h1 = h0 and ue.location(hp)
    local ok_h = not (h0 and h1) or d2(h0, h1) <= near
    if ok_c and ok_h then
        SEATK.tell_driver(pc, st, key, a, nil)
        return true
    end
    log.err("vehicles: seat: the game's get-in for %s (seat %d of %s) did not seat it at the wheel (it is %s cm from the wheel, the host moved %s cm): undone, %s stays a passenger",
        name_of(key), idx, st.name, l1 and cl and f0(math.sqrt(d2(l1, cl))) or "?", h0 and h1 and f0(math.sqrt(d2(h0, h1))) or "0",
        name_of(key))
    st.driver_key, st.scope_key = nil, nil
    st.released_till = os.clock() + RELEASE_S
    -- (the wheel free again: still waited for, SEATK.took)
    if waited then st.took_at, st.wheel_wait = nil, true end
    pcall(function() v:SetOwner(nil) end)
    set_requires(v, false)
    local m = mcomp(v)
    if m and st.upd ~= nil then ue.set_prop(m, "bUpdateOnlyIfRendered", st.upd) end
    st.upd = nil
    if seat then
        seat.seat, seat.idx, seat.geo = "passenger", idx, geo
        M.vseats.set(st, idx, key)
        local loc, rot = M.vseats.xf_geo(v, geo)
        if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
        SEATK.tell_pass(pc, st, key, idx, geo, false)
    end
    if h0 then
        local hl, hr = M.vseats.xf_geo(v, st.host_geo or M.vseats.geo(st.cls, hidx))
        if hl then pcall(function() hp:K2_SetActorLocationAndRotation(hl, hr, false, {}, true) end) end
        local r = seated[addr(hp) or -1]
        if r then r.unwelded = nil end
        if host_attached(a) then seat_mark(hp, v, a, "host", true) end
    end
    st.dirty = true
    recount_watch()
    return false
end

-- The driver left (its exit key, death, disconnect, a record that ended)
-- with somebody still in the car: every passenger stays in its seat (the
-- user, 13.11: "the player should stay in the seat it sat in and move only
-- with a key"; up to then the lowest seat was moved to the wheel 1.5 s
-- later - also a passenger that was getting out itself). The car stands as
-- the game's own exit leaves it: engine sound and timers off, no fuel spent,
-- handbrake on (the collision stays the occupied car's) until somebody
-- drives - a newcomer (the wheel is the first free seat) or a passenger with
-- its seat key (SEATK.host_key / client_switch). The passengers are told
-- once: the host on its screen, a client that knows the key (VENTER "sw")
-- by VSWR wheel; an older client is not moved and not told (it gets out
-- and in again). A host passenger's own driving keys would still reach its
-- copy of a car nobody drives: held parked every frame (SEATK.hold_frame).
function SEATK.wheel_free(v, st, why)
    local a = addr(v)
    -- somebody holds the wheel (the host, beside which a remote driver record
    -- just ended: demote_remote_driver), or nobody is left inside: nothing to
    -- do. The host keeps driving: that record's Event_ExitVehicle stopped the
    -- car's engine sound and timers - the host's car's (a remote driver's are
    -- re-asserted each tick).
    if st.driver_key then return end
    local host_in_car = host_attached(a)
    if host_in_car and st.host_seat ~= "passenger" then return host_services(v) end
    if not (M.vseats.any(st) or host_in_car) then return end
    stop_services(v, true)
    st.dirty = true
    st.wheel_wait = true   -- (SEATK.took)
    local told = {}
    for _, o in ipairs(M.vseats.occupants(st)) do
        if o.who == "host" then
            if host_in_car then
                SEATK.hold_va = a
                SEATK.say_wheel_free()
                told[#told + 1] = "host"
            end
        else
            local seat = seats[o.who]
            local pc = remote_pc_of(o.who)
            if pc and seat and seat.sw then
                net.send_to(pc, "VSWR", "wheel")
                told[#told + 1] = name_of(o.who)
            end
        end
    end
    log.info("vehicles: seat: the driver left %s (%s): passengers %s stay in their seats; parked (engine off, handbrake on) until somebody drives (told: %s)",
        st.name, tostring(why), SEATK.seats_text(st), #told > 0 and table.concat(told, ", ") or "nobody - older clients only")
end

-- This machine's player (the host) told the wheel is free: with its seat
-- key's name (none set: get out and in again).
function SEATK.say_wheel_free()
    local _, name = SEATK.key()
    if name then log.say("veh_wheel_free", "info", 6, name) else log.say("veh_wheel_free_nokey", "info", 6) end
end

-- The host (a passenger, nobody drives) to the wheel with its seat key: it
-- moves there (no get-in: the game's driving state is its own already, from
-- its own get-in), the services the game's get-in starts for a driver run
-- again and, as @7820, the handbrake goes off. "Seat 1 of M" in a car of more
-- than 2, else "You now drive this vehicle".
function SEATK.host_wheel(v, a, st, from)
    local hp = ue.local_pawn()
    local loc, rot = seat_transform(v, false)
    if not (hp and loc) then return false end
    pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    st.host_seat, st.host_idx, st.host_geo = "driver", nil, nil
    SEATK.took(st, cfg.player_name())
    SEATK.hold_va = nil
    local m = mcomp(v)
    if m then
        pcall(function() m:SetHandbrakeInput(false) end)
        pcall(function() m:SetBrakeInput(0) end)
    end
    set_requires(v, false)
    host_services(v)
    -- (a floor seat's pose back to the driver's)
    seat_mark(hp, v, a, "host", true, "car")
    st.dirty = true
    M.stats.promoted = M.stats.promoted + 1
    M.stats.switches = M.stats.switches + 1
    local n = M.vseats.layout(st.cls, { host = true }).count
    if n > 2 then log.say("veh_seat_driver", "info", 5, n) else log.say("veh_driver_now", "info", 4) end
    seat_log("host", st.name, "driver", string.format("its seat key in seat %s: the wheel was free", tostring(from)))
    recount_watch()
    return true
end

-- A passenger's seat ended (host_unseat) and the car is empty now: nobody at
-- the wheel, no other passenger, not the host. Parked as the game's exit
-- leaves an empty car - collision back, drive tags off (the driver's exit
-- had left the car "occupied" for the passengers; without this the host and
-- zombies walked through the empty car until the next get-in).
function SEATK.park_empty(v, st, a)
    if st.driver_key or M.vseats.any(st) or host_attached(a) then return end
    stop_services(v, false)
    st.dirty = true
    st.wheel_wait = nil
    log.info("vehicles: seat: %s: the last passenger out, nobody at the wheel: parked (engine off, handbrake on, collision back)", st.name)
end

-- opts: side ("p" = passenger side), tell (send VSEAT none), reason, count
-- (the seats it had: "none|full|M"), exit_key (a driver's own exit key;
-- either way its passengers stay in their seats: SEATK.wheel_free), taken
-- (a driver's record: the host takes the wheel right after - no "wheel
-- free" for anyone: SEATK.host_key)
local function host_unseat(key, why, opts)
    opts = opts or {}
    local seat = seats[key]
    if not seat then return end
    seats[key] = nil
    local st = vs[seat.vaddr]
    local v = vehicle_by(seat.vaddr, seat.vname)
    local pc = remote_pc_of(key)
    local ch = pc and ue.pawn_of(pc)
    local attached = ch ~= nil and v ~= nil and parent_vehicle(ch) == seat.vaddr
    -- A driver who left (disconnected) before the tick freed its seat: in
    -- that half second has_driver let the next player take the wheel. The
    -- car's driving state is the new driver's now: only this player's seat
    -- ends (0.7.3: the late cleanup stopped the new driver's engine, took
    -- its owner / inputs and promoted the passenger into the occupied
    -- driver seat - two characters in one seat).
    local other = seat.seat == "driver" and st ~= nil and st.driver_key ~= nil and st.driver_key ~= key
    if other then
        log.info("vehicles: seat: %s's driver seat in %s ended late: %s drives it now (its driving state stays)",
            name_of(key), seat.vname, name_of(st.driver_key))
    end
    if seat.seat == "driver" and not other then
        if v then
            local others = (st ~= nil and M.vseats.any(st)) or host_attached(seat.vaddr)
            if attached and can_redirect(pc) then
                if st then st.scope_key, st.scope_till = key, os.clock() + SCOPE_S end
                recount_watch()
                ue.set_prop(v, "GetOutPasseenger", opts.side == "p")
                -- Event_ExitVehicle removes self.VehicleUI (@23977): with the
                -- host sitting in this car that is the HOST's own panel
                local host_ui = host_attached(seat.vaddr) and ue.prop(v, "VehicleUI") or nil
                if not ue.valid(host_ui) then host_ui = nil end
                apply(function() v:Event_ExitVehicle() end)
                if host_ui and host_attached(seat.vaddr) then
                    if ue.try(function() return host_ui:IsInViewport() end) ~= true then
                        pcall(function() host_ui:AddToViewport(0) end)
                    end
                    ue.set_prop(v, "VehicleUI", host_ui)
                    log.info("vehicles: hud: the host's own panel %s kept on screen (%s's exit from %s took it)",
                        ue.short(host_ui), name_of(key), seat.vname)
                end
                exit_tail(v, ch, others)
            elseif attached then
                -- no player-0 redirect: the same steps without the game's function
                pcall(function() ch:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
                local loc = socket_loc(v, opts.side == "p" and "PassengerSide" or "DriverSide")
                if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, ue.rotation(ch), false, {}, false) end) end
                stop_sit(ch)
                stop_services(v, others)
                exit_tail(v, ch, others)
            else
                stop_services(v, others)
            end
            clear_timer(v, "Event_Noise")
            pcall(function() v:SetOwner(nil) end)
            set_requires(v, false)
            local m = mcomp(v)
            if m and st and st.upd ~= nil then ue.set_prop(m, "bUpdateOnlyIfRendered", st.upd) end
        end
        if st then
            st.driver_key, st.scope_key = nil, nil
            st.released_till = os.clock() + RELEASE_S
            st.upd = nil
            st.dirty = true
        end
        M.stats.exits = M.stats.exits + 1
    else
        local idx = seat.idx or (st and M.vseats.idx_of(st, key)) or 2
        if attached and v then
            pcall(function() ch:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
            -- seat 2 at the passenger door (as before); a seat 3+ at its own
            -- door, moved back to its row (the other side when that is blocked)
            local loc, side_why = nil, nil
            if idx >= 3 then
                local _, sw, l = SEATK.exit_side(v, ch, idx, seat.geo or (st and M.vseats.geo(st.cls, idx)))
                loc, side_why = l, sw
            end
            loc = loc or socket_loc(v, "PassengerSide")
            if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, ue.rotation(ch), false, {}, false) end) end
            if side_why then log.info("vehicles: seat: %s out of seat %d of %s at %s", name_of(key), idx, seat.vname, side_why) end
            stop_sit(ch)
            local cmc = ue.prop(ch, "CharacterMovement")
            if ue.valid(cmc) then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
        end
        if st and M.vseats.drop(st, key) then st.dirty = true end
        M.stats.exits = M.stats.exits + 1
    end
    if ch then
        char_out(ch)
        release_position(ch, seat)
        forget_att(ch)
        if parent_vehicle(ch) ~= seat.vaddr then
            -- out: the sit pose ends on every machine, here at once
            stop_sit_everywhere(ch)
            local ca = addr(ch)
            local r = ca and seated[ca]
            if r and r.vaddr == seat.vaddr then seat_clear(ca, r, ch, name_of(key)) end
        end
    end
    recount_watch()
    if opts.tell then
        if opts.count then
            send_seat(pc, "none", opts.reason or why, tostring(opts.count))
        else
            send_seat(pc, "none", opts.reason or why)
        end
    end
    seat_log(name_of(key), seat.vname, "out", "was " .. tostring(seat.seat)
        .. (seat.seat == "passenger" and (" in seat " .. tostring(seat.idx or 2)) or "") .. "; " .. tostring(why))
    if seat.seat == "driver" and v and st and not other then
        if not opts.taken then SEATK.wheel_free(v, st, name_of(key) .. ": " .. tostring(why)) end
    elseif v and st then
        SEATK.park_empty(v, st, seat.vaddr)
    end
end

-- count: the seats the refused player had (VSEAT none|full|M: "No free seat
-- (M seats)" on a client that knows seats 3+).
local function host_reject(pc, why, count)
    M.stats.rejected = M.stats.rejected + 1
    if count then send_seat(pc, "none", why, tostring(count)) else send_seat(pc, "none", why) end
    local r = S and S.remote and S.remote[ue.name(pc)]
    seat_log(r and r.name or ue.short(pc), "-", "refused", why .. (count and (" (" .. count .. " seats)") or ""))
end

-- Who has the driver seat: a remote driver, or the host sitting in it (not
-- as a passenger). The host's attachment counts at once (the game's entry
-- attaches synchronously; its driving state comes 0.1 s later, or not at all
-- when VehicleInteraction stopped half-way).
local function has_driver(a, st)
    if st.driver_key and remote_pc_of(st.driver_key) then return true end
    return host_seated(a) and st.host_seat ~= "passenger"
end

-- The seats of a vehicle: the game's one seat (the driver's, PlayerLocation),
-- the mod's passenger seats (sdc_vehseats: 2 = its mirror, 3+ from the table
-- per class), held by st.driver_key / st.pax[idx] (clients) and st.host_seat
-- / st.host_idx (the host). The seat a newcomer gets in vehicle `a`:
-- "driver", 1 | "passenger", idx | nil (no free seat). Every entry asks this
-- one place. `host`: the host's own get-in, which the game has already run
-- (the host is attached; a remote driver's record counts until the tick
-- ends it; the host's own seat does not count as taken). `cap`: the client
-- knows seats 3+ (VENTER "s2"; an older one gets seats 1-2).
function SEATK.free_seat(a, st, host, cap)
    if host then
        if not st.driver_key then return "driver", 1 end
        local idx = M.vseats.free_idx(st, st.cls, { host = true })
        if idx then return "passenger", idx end
        return nil
    end
    if not has_driver(a, st) then return "driver", 1 end
    if not on("vehicle_passengers") then return nil end
    local idx = M.vseats.free_idx(st, st.cls, { cap = cap == true, passengers = true })
    if idx then return "passenger", idx end
    return nil
end

-- A remote driver while the host sits in the driver seat (up to 0.6.44 the
-- seat test made a client the driver of the host's car): the client goes
-- to the first free passenger seat, the host keeps the wheel.
local function demote_remote_driver(v, st, why)
    local key = st.driver_key
    local a = addr(v)
    local pc = remote_pc_of(key)
    local ch = pc and ue.pawn_of(pc)
    st.driver_key, st.scope_key = nil, nil
    st.released_till = os.clock() + RELEASE_S
    pcall(function() v:SetOwner(nil) end)
    set_requires(v, false)
    local m = mcomp(v)
    if m and st.upd ~= nil then ue.set_prop(m, "bUpdateOnlyIfRendered", st.upd) end
    st.upd = nil
    local seat = key and seats[key]
    local idx = seat and ch and parent_vehicle(ch) == a
        and M.vseats.free_idx(st, st.cls, { cap = seat.cap == true, passengers = true }) or nil
    if not idx then
        if seat then host_unseat(key, why, { tell = true, reason = "full", count = SEATK.layout(st, key).count }) end
        return
    end
    seat.seat, seat.idx, seat.geo = "passenger", idx, M.vseats.geo(st.cls, idx)
    M.vseats.set(st, idx, key)
    local loc, rot = M.vseats.xf_geo(v, seat.geo)
    if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
    st.dirty = true
    recount_watch()
    SEATK.tell_pass(pc, st, key, idx, seat.geo, true, cfg.player_name())
    seat_log(name_of(key), st.name, "passenger seat " .. idx, why)
end

-- ---------------------------------------------------------------------------
-- Host: messages from clients
-- ---------------------------------------------------------------------------

local function sender(pc)
    if not enabled() or not S or S.role ~= "host" or not ue.valid(pc) then return nil end
    return ue.name(pc)
end

-- The vehicle a message is about, on the host, near the sender.
local function msg_vehicle(f, pc, i)
    i = i or 1
    local v = vehicle_at(tonumber(f[i]), tonumber(f[i + 1]), tonumber(f[i + 2]), f[i + 3], MATCH_M)
    if not v then return nil end
    local ch = ue.pawn_of(pc)
    local cl, vl = ch and ue.location(ch), ue.location(v)
    if not (cl and vl) or d2(cl, vl) > NEAR_M * NEAR_M * 4 then return nil end
    return v
end

-- The passengers of a vehicle for the log: "2 Friend2, 3 host".
function SEATK.seats_text(st)
    local parts = {}
    for _, o in ipairs(M.vseats.occupants(st)) do
        parts[#parts + 1] = o.idx .. " " .. (o.who == "host" and "host" or name_of(o.who))
    end
    return #parts > 0 and table.concat(parts, ", ") or "-"
end

-- VENTER|x|y|z|class[|s2[|sw]]: "s2" = the client knows seats 3+
-- (sdc_vehseats; an older client sends 4 fields and gets seats 1-2), "sw" =
-- it has the seat key (VSWITCH; it is told when the wheel is free).
local function on_venter(f, pc)
    local key = sender(pc)
    if not key then return end
    local ch = ue.pawn_of(pc)
    if not ch or ue.prop(ch, "PlayerDead?") == true then return host_reject(pc, "no character") end
    if SEATK.out_cold(ch) then return host_reject(pc, "downed") end
    if not ensure_resolver() then return host_reject(pc, "no scope api") end
    discover(true)
    local v = vehicle_at(tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), f[4], MATCH_M)
    if not v then return host_reject(pc, "vehicle not found") end
    local cl, vl = ue.location(ch), ue.location(v)
    if not (cl and vl) or d2(cl, vl) > NEAR_M * NEAR_M then return host_reject(pc, "too far") end
    local a = addr(v)
    local st = state_for(a, v)
    local cap = f[5] == "s2"
    local sw = f[6] == "sw"
    local had = seats[key]
    if had and had.vaddr == a and parent_vehicle(ch) == a then
        -- its game ran the get-in again while it sits here (a second press
        -- with its in-vehicle flag unset): the seat stays, the answer repeats
        -- with the same seat (no notice there), no second get-in here
        had.cap, had.sw = cap, sw
        if had.seat == "passenger" then
            local idx = had.idx or 2
            SEATK.tell_pass(pc, st, key, idx, had.geo or M.vseats.geo(st.cls, idx), false)
        else
            SEATK.tell_driver(pc, st, key, a, false)
        end
        log.info("vehicles: seat: %s asked again for a seat in %s while sitting there as %s (seat %s): the seat stays (no second get-in)",
            name_of(key), st.name, tostring(had.seat), tostring(had.idx or (had.seat == "driver" and 1 or 2)))
        return
    end
    if had then host_unseat(key, "re-enter") end
    local hs = host_seated(a)
    log.info("vehicles: %s asks for a seat in %s: remote driver=%s, host seated=%s (host seat=%s %s, driving state=%s), passengers=%s, knows seats 3+=%s, seat key=%s",
        name_of(key), st.name, st.driver_key and name_of(st.driver_key) or "-", tostring(hs), tostring(st.host_seat),
        tostring(st.host_idx or ""), tostring(host_in(a)), SEATK.seats_text(st), tostring(cap), tostring(sw))
    local free, idx = SEATK.free_seat(a, st, false, cap)
    if free == "driver" then
        if not can_redirect(pc) then return host_reject(pc, "no player index") end
        host_seat_driver(key, pc, ch, v, st, hs and "the host sits as a passenger; driver seat free" or "driver seat free", cap)
    elseif free == "passenger" then
        local dn = st.driver_key and name_of(st.driver_key) or cfg.player_name()
        host_seat_passenger(key, pc, ch, v, st, dn,
            st.driver_key and (dn .. " drives") or "the host drives", idx, cap)
    else
        host_reject(pc, "full", SEATK.layout(st, key, cap).count)
    end
    if seats[key] then seats[key].sw = sw end
end

local function on_vexit(f, pc)
    local key = sender(pc)
    if not key or not seats[key] then return end
    -- f[6]: seconds the client sat in that seat, f[7]: its seat there, f[8]:
    -- its seat number (diagnostics; the exit itself is the client's interact key)
    local age = tonumber(f[6])
    host_unseat(key, age and string.format("client exit with the interact key after %.1f s in its %s seat%s", age,
        tostring(f[7] or "?"), (f[8] and f[8] ~= "") and (" " .. f[8]) or "")
        or "client exit", { side = f[5], exit_key = true })
end

-- ---------------------------------------------------------------------------
-- The seat key (config vehicle_seat_key): the host moves the passengers
-- ---------------------------------------------------------------------------

SEATK.SWITCH_GAP = 0.4   -- s: one move per client per this (a double press)
SEATK.TOOK_S = 1.0       -- s: a seat key this soon after somebody took the free wheel moves nobody

-- The free wheel (its passengers were told: SEATK.wheel_free sets
-- st.wheel_wait) taken now - by a passenger's seat key, the host's or a
-- newcomer's get-in: when and by whom (SEATK.too_late).
function SEATK.took(st, name)
    if st.wheel_wait then st.took_at, st.took_by, st.wheel_wait = os.clock(), name, nil end
end

-- Two passengers pressed their key for the free wheel together: the second
-- press, a moment after the first took it, meant the wheel as well - it
-- does not move that player to the next free seat (a back seat it never
-- asked for), a notice "<name> already took the wheel" instead. The taker's
-- name within SEATK.TOOK_S of it, else nil.
function SEATK.too_late(st)
    local t = st.took_at
    if t and os.clock() - t >= 0 and os.clock() - t < SEATK.TOOK_S then return st.took_by or "?" end
    return nil
end

-- Somebody holds the wheel for the seat key: a remote driver still
-- connected, or the host attached at it - the attachment, not the driving
-- state (as has_driver for a newcomer otherwise): right after the host's own
-- exit, or with a stale one after its death, InVehicle? / Vehicle are still
-- set although nobody sits there.
function SEATK.wheel_taken(a, st)
    if st.driver_key and remote_pc_of(st.driver_key) then return true end
    return host_attached(a) and st.host_seat ~= "passenger"
end

-- The host (a passenger) to free passenger seat idx of its car: moved there
-- in its attachment, its record (host_idx / host_geo) and the seat's pose;
-- "Seat N of M: <driver> drives" (the wheel is taken: it would go there).
function SEATK.move_host(v, a, st, idx, lay, from)
    local hp = ue.local_pawn()
    local geo = M.vseats.geo(st.cls, idx)
    local loc, rot = M.vseats.xf_geo(v, geo)
    if not (hp and loc) then return false end
    pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    st.host_idx, st.host_geo = idx, geo
    seat_mark(hp, v, a, "host", true, geo.pose)
    st.dirty = true
    M.stats.switches = M.stats.switches + 1
    log.say("veh_seat", "info", 5, lay.rank[idx] or idx, lay.count, st.driver_key and name_of(st.driver_key) or "?")
    seat_log("host", st.name, "passenger seat " .. idx, "its seat key in seat " .. tostring(from))
    return true
end

-- This machine's player is the host and pressed its seat key (game thread,
-- SEATK.on_key): a passenger moves - to the wheel when nobody drives, else
-- to the next free seat of the host's layout, round; none free: a notice.
-- At the wheel nothing changes. Returns the log text.
function SEATK.host_key()
    local hp = ue.local_pawn()
    local a = hp and parent_vehicle(hp)
    local st = a and vs[a]
    local v = a and cur.by[a]
    if not (st and v and ue.valid(v)) then return "not seated" end
    if st.host_seat ~= "passenger" then return "at the wheel of " .. st.name .. ": nothing to change (the key moves passengers)" end
    if ue.prop(hp, "PlayerDead?") == true then return "dead" end
    local from = M.vseats.host_idx(st)
    local free = not SEATK.wheel_taken(a, st)
    local late = not free and SEATK.too_late(st)
    if late then
        log.say("veh_wheel_taken", "info", 4, late)
        return string.format("seat %s of %s: %s took the free wheel just before: stays (the press meant the wheel)",
            tostring(from), st.name, tostring(late))
    end
    local idx, lay = M.vseats.next_idx(st, st.cls, { host = true }, from, free)
    local ok
    if idx == 1 then
        -- A driver whose player left keeps its record until the tick ends
        -- it (up to 0.5 s; wheel_taken does not count it): ended here first,
        -- without a "wheel free" - the host takes it now. Ended by the tick
        -- after, it stopped the host's car under it (handbrake on: the
        -- host's W did nothing until it pressed Space).
        local gone = st.driver_key
        if gone then
            host_unseat(gone, "player left (its record ended at the host's seat key, before the tick)", { taken = true })
            if st.driver_key == gone then st.driver_key, st.scope_key = nil, nil end
        end
        ok = SEATK.host_wheel(v, a, st, from)
        if not ok and gone then SEATK.wheel_free(v, st, name_of(gone) .. ": player left") end
    elseif idx then
        ok = SEATK.move_host(v, a, st, idx, lay, from)
    else
        log.say("veh_switch_none", "info", 4)
        return string.format("seat %s of %s: no free seat (%d seats: %s)", tostring(from), st.name, lay.count, SEATK.seats_text(st))
    end
    if not ok then log.say("veh_switch_failed", "warn", 4) end
    return string.format("seat %s of %s -> %s%s", tostring(from), st.name, idx == 1 and "the wheel" or ("seat " .. idx),
        ok and "" or ": no world position for it here (stays)")
end

-- Client `key` (a passenger; its record `seat`) to free passenger seat idx:
-- its character moved there on the host (the attachment replicates), its
-- record, the seat's pose; VSEAT passenger with the new seat - its own copy
-- moves it there, its notice "Seat N of M".
function SEATK.move_client(v, a, st, key, pc, ch, seat, idx, from)
    local geo = M.vseats.geo(st.cls, idx)
    local loc, rot = M.vseats.xf_geo(v, geo)
    if not loc then return false end
    seat.seat, seat.idx, seat.geo = "passenger", idx, geo
    M.vseats.set(st, idx, key)
    pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    seat_mark(ch, v, a, name_of(key), false, geo.pose)
    st.dirty = true
    recount_watch()
    M.stats.switches = M.stats.switches + 1
    SEATK.tell_pass(pc, st, key, idx, geo, true)
    seat_log(name_of(key), st.name, "passenger seat " .. idx, "its seat key in seat " .. tostring(from))
    return true
end

-- Client `key`'s seat key (VSWITCH): the wheel when nobody drives and the
-- game's get-in can run for it here (SEATK.take_wheel, checked after), else
-- the next free seat of its layout (seats 1-2 for a client without "s2"),
-- round; none: VSWR full ("no" when the free wheel cannot be its). Returns
-- the log text.
function SEATK.client_switch(v, a, st, key, pc, ch, seat)
    local from = seat.idx or 2
    local free = not SEATK.wheel_taken(a, st)
    local late = not free and SEATK.too_late(st)
    if late then
        net.send_to(pc, "VSWR", "taken", late)
        return string.format("%s took the free wheel just before: stays in seat %s (the press meant the wheel)", tostring(late), tostring(from))
    end
    local wheel = free and can_redirect(pc)
    local idx, lay = M.vseats.next_idx(st, st.cls, { cap = seat.cap == true, passengers = true }, from, wheel)
    if idx == 1 then
        if SEATK.take_wheel(v, a, st, key, pc, ch, from) then
            M.stats.switches = M.stats.switches + 1
            return "the wheel"
        end
        net.send_to(pc, "VSWR", "no", "wheel")
        return "the wheel: the game's get-in did not seat it there (back in seat " .. from .. ")"
    end
    if idx then
        if SEATK.move_client(v, a, st, key, pc, ch, seat, idx, from) then return "seat " .. idx end
        net.send_to(pc, "VSWR", "no", "position")
        return "seat " .. idx .. ": no world position for it here (stays)"
    end
    net.send_to(pc, "VSWR", free and "no" or "full", tostring(lay.count))
    return string.format("no free seat (%d seats: %s)%s", lay.count, SEATK.seats_text(st),
        free and "; the wheel is free but the game's get-in cannot run for this player here (no player index)" or "")
end

-- VSWITCH|x|y|z|class: a client's seat key (only a client that has one
-- sends it; an older host has no handler). Its seat is the host's record.
function SEATK.on_vswitch(f, pc)
    local key = sender(pc)
    if not key then return end
    local seat = seats[key]
    if not seat then
        log.info("vehicles: seat key: %s pressed it but sits in no seat here (%s)", name_of(key), tostring(f[4]))
        return
    end
    seat.sw = true
    local t = os.clock()
    if t - (seat.sw_at or -100) < SEATK.SWITCH_GAP then return end
    seat.sw_at = t
    local v = vehicle_by(seat.vaddr, seat.vname)
    local st = vs[seat.vaddr]
    local ch = ue.pawn_of(pc)
    local where = string.format("the %s seat%s of %s", tostring(seat.seat),
        seat.seat == "passenger" and (" " .. tostring(seat.idx or 2)) or "", tostring(seat.vname))
    local res
    if not (v and st) then
        res = "its vehicle is gone"
    elseif seat.seat ~= "passenger" then
        res = "at the wheel: nothing to change (the key moves passengers)"
    elseif not ch or parent_vehicle(ch) ~= seat.vaddr or ue.prop(ch, "PlayerDead?") == true then
        res = "not seated here (dead / detached): stays"
    else
        res = "-> " .. SEATK.client_switch(v, addr(v), st, key, pc, ch, seat)
    end
    log.info("vehicles: seat key: %s in %s: %s", name_of(key), where, res)
end

-- The sender's seat in the vehicle the message names.
local function seat_in(key, v)
    local seat = seats[key]
    if seat and v and seat.vaddr == addr(v) then return seat.seat end
    return nil
end

-- VLIGHT / VHORN / VFLIP count only from the vehicle's driver (driver only,
-- see SEATK.pass_block): true = refused. One log line per sender and kind
-- every 5 s (the in-game check; an older client still sends its horn from a
-- passenger seat).
function SEATK.not_driver(kind, key, v)
    local seat = seat_in(key, v)
    if seat == "driver" then return false end
    SEATK.nd_at = SEATK.nd_at or {}
    local k, t = kind .. "|" .. tostring(key), os.clock()
    if t - (SEATK.nd_at[k] or -100) >= 5 then
        SEATK.nd_at[k] = t
        local idx = seat == "passenger" and M.vseats.idx_of(vs[addr(v)] or {}, key)
        log.info("vehicles: driver only: %s from %s refused: %s in %s, only the driver's counts", kind, name_of(key),
            seat == "passenger" and ("a passenger, seat " .. tostring(idx or "?")) or "not seated", ue.short(v))
    end
    return true
end

local function on_vlight(f, pc)
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v or SEATK.not_driver("VLIGHT", key, v) then return end
    local want = f[5] == "1"
    if (ue.prop(v, "LightsOn?") == true) ~= want then
        apply(function() v:TurnOnOffLights() end)
        M.stats.relays = M.stats.relays + 1
    end
    local st = vs[addr(v)]
    if st then st.dirty = true end
end

local function host_horn_broadcast(v, except_pc)
    local l = ue.location(v)
    if not l then return end
    local ea = except_pc and addr(except_pc)
    for _, pc in ipairs(S.remote_pcs or {}) do
        if not ea or addr(pc) ~= ea then
            net.send_to(pc, "VHORN", f0(l.X), f0(l.Y), f0(l.Z), ue.class_name(v))
        end
    end
end

local function on_vflip(f, pc)
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v or SEATK.not_driver("VFLIP", key, v) then return end
    -- the host sits in it as a passenger: its flip key's hold (SEATK.flip_hold) is not for the driver
    if SEATK.flip_va == addr(v) then ue.set_prop(v, "Flipped", false) end
    apply(function() v:Event_FlipVehicle() end)
    M.stats.relays = M.stats.relays + 1
    log.info("vehicles: %s flipped %s", name_of(key), ue.short(v))
end

-- VTOW|x|y|z|class|1 or 0: a client chose "Tow Vehicle" / "Detach Vehicle"
-- on its copy. The game offers that option only to a player standing at the
-- tow box, not in a vehicle (BP_VehicleMaster @9949-10009 -> AddTowingComp
-- @12539), so no seat is asked for: the vehicle must be near the sender's
-- character here (msg_vehicle). The game's own steps on the host's copy; its
-- notes (no notification for the hitch; "No vehicle to tow found", "Towed
-- vehicle detached", "Unable to detach") are the client's, not the host's.
fx.TOW_NOTES = { "No vehicle to tow found", "Towed vehicle detached", "Unable to detach. Try again" }
local function on_vtow(f, pc)
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v then
        if key then
            log.info("vehicles: %s's tow request: no %s at %s,%s,%s near its character here: not applied",
                name_of(key), tostring(f[4]), tostring(f[1]), tostring(f[2]), tostring(f[3]))
        end
        return
    end
    local want = f[5] == "1"
    if (ue.prop(v, "TowingVehicle?") == true) == want then return end
    if want then
        apply(function() v:AddTowingComp(false, true) end)
        -- the car it hitched may be one the host sits in as a passenger,
        -- held parked: let go now, before the game's next-tick release of it
        -- (SEATK.tower_of)
        local held = SEATK.hold_va
        if held and SEATK.towed_by(v) == held then
            SEATK.hold_va = nil
            log.info("vehicles: tow: %s hitched %s, where the host sits as a passenger: no longer held parked (the game releases its handbrake)",
                name_of(key), vs[held] and vs[held].name or "?")
        end
    else
        apply(function() v:RemoveTowingComp() end)
    end
    for _, n in ipairs(fx.TOW_NOTES) do fx.unnote(n) end
    M.stats.relays = M.stats.relays + 1
    log.info("vehicles: %s %s towing with %s (now %s)", name_of(key), want and "started" or "stopped",
        ue.short(v), tostring(ue.prop(v, "TowingVehicle?")))
end

-- ---------------------------------------------------------------------------
-- Refuel / repair. The game (BP_VehicleMaster): a player's capsule in the
-- fuel / repair box (@15292 / @16541) sets the vehicle's one flag
-- InRefuellingArea? / InRepairingArea? and adds "Refuel Vehicle" / "Repair
-- Vehicle" to its InteractOptions; leaving it (@14726 / @14038) clears
-- IsHeld, the flag and the option - for ANY player's character, on every
-- machine that sees the overlap. Choosing the option (OnExecuteInteract
-- @18427 / @18349) sets IsHeld, finds a gas can / repair kit in player 0's
-- inventory (FindJigItemByDA: the inventory widgets, which a client has),
-- starts the timer bar, the Looting montage and RetriggerableDelay(Duration);
-- then, if IsHeld is still set, UseGasCan (@1887) / the kit branch (@1902):
-- ServerFindThenConsumeByItemID(gas can / kit), and only if it took one
-- +MaxFuel/2 (UseGasCan @234..990) / VehicleEngineFX(false), EngineOn?,
-- +MaxHealth/2 (@2073..2706); else the note "No gas found" / "No repair kits
-- found". All of it on the machine that pressed the key, on its own copy.
-- ServerFindThenConsumeByItemID walks MainJigContainers, which only the host
-- fills (sdc_world: the generator's gas can): on a client it never finds the
-- item, so a client's refuel / repair ended in that note with nothing added
-- (0.7.1: "the client cannot refuel / repair"). Svr_UpdateFuel /
-- Svr_UpdateEngine need the vehicle's owner and only refresh a widget.
-- Now: the client's note (GameFunctionLibrary.CreateNotificationUI, post, with
-- its copy of the vehicle as context) asks the host for that last step
-- (VFUEL / VREPAIR with +Max/2, fx.ask); the host checks "full", takes the
-- item from that player's inventory with the same server function (host
-- data; the inventory update reaches the client as for the water well), adds
-- it (FuelComponent.AddFuel / the kit branch's steps), sends the vehicle state
-- to everyone and answers that client (VBOXR): the game's success step on its
-- copy, or the game's note. The client's false note is taken off its screen.
-- 13.11 (0.11.0, "the client cannot refuel or repair"): in the game that note
-- never reached fx.on_note (no "its note" line in any log since 0.7.2): the
-- refuel got through only by UseGasCan's own hook, and the repair - whose
-- kit branch is no function to hook - never asked at all. Each ask path now:
-- the note (fx.on_note), UseGasCan's hook (refuel), and the client's tick at
-- the hold's end (fx.hold_end: the hold's time is up, the game's flag down,
-- nothing added here, this player not outside the box). One ask per hold.
-- ---------------------------------------------------------------------------

function fx.kind_of(tag)
    if tag == fx.REFUEL then return "refuel" end
    if tag == fx.REPAIR then return "repair" end
    return nil
end

function fx.item_name(kind) return kind == "refuel" and "gas can" or "repair kit" end

function fx.asset(kind)
    local da = fx.da[kind]
    if da and ue.valid(da) then return da end
    -- (a client takes it only from memory: buy.asset)
    da = buy.asset(kind == "refuel" and fx.GASCAN or fx.KIT)
    fx.da[kind] = da
    return da
end

-- The item in pawn's inventory as this machine sees it (the game's own
-- FindJigItemByDA, as @18690); nil: cannot tell.
function fx.has_item(pawn, kind)
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    local da = fx.asset(kind)
    if not (ue.valid(jig) and da) then return nil end
    local out = {}
    if not pcall(function() jig:FindJigItemByDA(da, {}, true, false, 1, out) end) then return nil end
    return out.Result == true
end

-- Host: one gas can / repair kit out of a remote player's inventory.
function fx.take_item(pawn, kind)
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    local da = fx.asset(kind)
    if not ue.valid(jig) then return "no (no inventory component)" end
    if not da then return "no (item asset not loaded)" end
    local out = {}
    if not pcall(function() jig:ServerFindThenConsumeByItemID(da, 1, out) end) then return "no (call failed)" end
    return out.Result == true and "yes" or "no (none in its inventory on the host)"
end

-- The numbers on the vehicle's own fuel / repair widgets (shown at the boxes).
function fx.widgets(v)
    local fuel, maxf = fuel_of(v)
    local hp, maxh = health_of(v)
    if fuel and maxf then
        pcall(function() v.FuelWidget:GetUserWidgetObject():UpdateFuel(fuel, maxf) end)
    end
    if hp and maxh then
        pcall(function() v.RepairWidget:GetUserWidgetObject():UpdateHealth(hp, maxh) end)
    end
end

-- VBOXR|kind|result|x|y|z|class|value|max (host -> the client that asked):
-- result ok / full / none (no item in its inventory here) / far (no such
-- vehicle near its character here); x..class as the client sent them.
function fx.reply(pc, kind, f, res, value, max)
    net.send_to(pc, "VBOXR", kind, res, f[1] or "", f[2] or "", f[3] or "", f[4] or "",
        value and string.format("%.1f", value) or "", max and string.format("%.1f", max) or "")
end

-- VFUEL|x|y|z|class|fuel there|added: a client's refuel of its copy (the
-- amount its game's UseGasCan adds: its own add, or fx.ask after the add
-- failed there). Answered with VBOXR.
local function on_vfuel(f, pc)
    local key = sender(pc)
    if not key then return end
    local v = msg_vehicle(f, pc)
    local there, add = tonumber(f[5]), tonumber(f[6])
    local asked = add ~= nil and add > 0
    if not v then
        log.warn("vehicles: refuel: %s refuelled a %s at %s,%s,%s on its machine; no such vehicle within reach here: not applied",
            name_of(key), tostring(f[4]), tostring(f[1]), tostring(f[2]), tostring(f[3]))
        if asked then fx.reply(pc, "refuel", f, "far") end
        return
    end
    local fuel, maxf, fc = fuel_of(v)
    if not (fc and fuel and maxf and maxf > 0) then
        log.warn("vehicles: refuel: %s refuelled %s on its machine; no fuel component here", name_of(key), ue.short(v))
        if asked then fx.reply(pc, "refuel", f, "far") end
        return
    end
    local want = nil
    if add and add > 0 then
        want = math.min(maxf, fuel + add)
    elseif there then
        want = math.min(maxf, there)
    end
    -- the next VSTATE carries the host's value either way (a refused refuel
    -- is undone on the client)
    state_for(addr(v), v).dirty = true
    -- the gas can first: no can in its inventory here, no fuel
    local took = "not asked (old message)"
    if asked then
        if fuel >= maxf - 0.05 then
            -- the game's check at the hold's start (@18517), on the host's value
            log.info("vehicles: refuel: %s's refuel of %s: the tank is full here (%.0f of %.0f): no gas can taken, nothing added ('Gas full' there)",
                name_of(key), ue.short(v), fuel, maxf)
            fx.reply(pc, "refuel", f, "full", fuel, maxf)
            return
        end
        took = fx.take_item(ue.pawn_of(pc), "refuel")
        if took ~= "yes" then
            log.warn("vehicles: refuel: %s has no gas can here (%s): not added (%s stays at %.0f of %.0f; its copy is set back)",
                name_of(key), took, ue.short(v), fuel, maxf)
            fx.reply(pc, "refuel", f, "none", fuel, maxf)
            return
        end
    end
    if not want or want <= fuel + 0.05 then
        log.info("vehicles: refuel: %s refuelled %s on its machine (%s there); here %.0f of %.0f already: nothing added; gas can taken here: %s",
            name_of(key), ue.short(v), there and string.format("%.0f", there) or "?", fuel, maxf, took)
        if asked then fx.reply(pc, "refuel", f, "ok", fuel, maxf) end
        return
    end
    -- the game's own add (a fraction of MaxFuel; clamps, VehicleUI, Empty)
    local ok = apply(function() fc:AddFuel((want - fuel) / maxf) end)
    local now = fuel_of(v)
    if not now or now < want - 0.5 then
        ok = false
        ue.set_prop(fc, "CurrentFuel", want)
        ue.set_prop(fc, "Empty", false)
        pcall(function() fc:UpdateUIFuel(want, maxf) end)
        now = want
    end
    fx.widgets(v)
    M.stats.relays = M.stats.relays + 1
    log.info("vehicles: refuel: %s refuelled %s: %.0f -> %.0f of %.0f here (+%.0f; %s on its machine; AddFuel %s); gas can taken from its inventory here: %s",
        name_of(key), ue.short(v), fuel, now, maxf, now - fuel, there and string.format("%.0f", there) or "?",
        ok and "ok" or "failed, set directly", took)
    if asked then fx.reply(pc, "refuel", f, "ok", now, maxf) end
end

-- VREPAIR|x|y|z|class|health there|added (as VFUEL)
local function on_vrepair(f, pc)
    local key = sender(pc)
    if not key then return end
    local v = msg_vehicle(f, pc)
    local there, add = tonumber(f[5]), tonumber(f[6])
    local asked = add ~= nil and add > 0
    if not v then
        log.warn("vehicles: repair: %s repaired a %s at %s,%s,%s on its machine; no such vehicle within reach here: not applied",
            name_of(key), tostring(f[4]), tostring(f[1]), tostring(f[2]), tostring(f[3]))
        if asked then fx.reply(pc, "repair", f, "far") end
        return
    end
    local hp, maxh, hc = health_of(v)
    if not (hc and hp and maxh) then
        if asked then fx.reply(pc, "repair", f, "far") end
        return
    end
    local want = nil
    if add and add > 0 then
        want = math.min(maxh, hp + add)
    elseif there then
        want = math.min(maxh, there)
    end
    state_for(addr(v), v).dirty = true
    -- the repair kit first: none in its inventory here, no repair
    local took = "not asked (old message)"
    if asked then
        if hp > maxh - 1 then
            -- the game's check at the hold's start (@19458), on the host's value
            log.info("vehicles: repair: %s's repair of %s: nothing to repair here (%.0f of %.0f): no repair kit taken ('Vehicle repaired' there)",
                name_of(key), ue.short(v), hp, maxh)
            fx.reply(pc, "repair", f, "full", hp, maxh)
            return
        end
        took = fx.take_item(ue.pawn_of(pc), "repair")
        if took ~= "yes" then
            log.warn("vehicles: repair: %s has no repair kit here (%s): not added (%s stays at %.0f of %.0f; its copy is set back)",
                name_of(key), took, ue.short(v), hp, maxh)
            fx.reply(pc, "repair", f, "none", hp, maxh)
            return
        end
    end
    if not want or want <= hp + 0.5 then
        log.info("vehicles: repair: %s repaired %s on its machine; here %.0f of %.0f already: nothing added; repair kit taken here: %s",
            name_of(key), ue.short(v), hp, maxh, took)
        if asked then fx.reply(pc, "repair", f, "ok", hp, maxh) end
        return
    end
    -- the kit branch's steps (@2073..2706): engine FX off, engine on, +health
    apply(function() v:VehicleEngineFX(false) end)
    ue.set_prop(v, "EngineOn?", true)
    ue.set_prop(hc, "CurrentHealth", want)
    pcall(function() hc:UpdateUIHealth(want, maxh) end)
    fx.widgets(v)
    M.stats.relays = M.stats.relays + 1
    log.info("vehicles: repair: %s repaired %s: %.0f -> %.0f of %.0f here (+%.0f); repair kit taken from its inventory here: %s",
        name_of(key), ue.short(v), hp, want, maxh, want - hp, took)
    if asked then fx.reply(pc, "repair", f, "ok", want, maxh) end
end

local function on_vpush(f, pc)
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    local dx, dy, dz = tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
    if not v or not (dx and dy and dz) then return end
    local st = state_for(addr(v), v)
    local t = os.clock()
    if t - (st.push_at or -100) < PUSH_COOLDOWN_S then return end
    st.push_at = t
    local mesh = ue.prop(v, "Mesh")
    if not ue.valid(mesh) then return end
    local ok = pcall(function()
        mesh:AddForce({ X = dx * PUSH_FORCE, Y = dy * PUSH_FORCE, Z = dz * PUSH_FORCE }, FName("None"), false)
    end)
    M.stats.relays = M.stats.relays + 1
    log.info("vehicles: %s pushed %s (ok=%s)", name_of(key), ue.short(v), tostring(ok))
end

-- ---------------------------------------------------------------------------
-- Vehicle trader. The game (VehicleVendorButton click @230-876, on the machine
-- whose player clicks): price = Text to Int(Price) (W_VehicleTraderUI fills
-- it from DT_VehicleInfo row "Trader"); GetPlayerPawn(0)'s BP_JigComponent
-- .CheckIfHasEnoughMoney(price, DA_Money) - if not: "Not enough money" there;
-- TakeMoney(price, DA_Money) takes money stacks out of that machine's
-- MainJigContainers and returns the S_UpdateCount list; CLIENT_UpdateCounts
-- (list); GetActorOfClass(BP_VehicleTraderSpawner).SpawnVehicle(class):
-- BeginDeferredActorSpawnFromClass at the spawner (AdjustIfPossibleButAlways
-- Spawn, no owner). On a client every step is local: the money leaves only
-- the client's view (the host's inventory, the real one, keeps it) and the
-- car is an actor only that client has. The host repeats the purchase with
-- the same functions on the client's component (CLIENT_UpdateCounts then
-- reaches the client) and spawns the car; EMS saves it with the host's world
-- (SetSaveProperties @7640) and sdc_persist the client's inventory.
-- ---------------------------------------------------------------------------

-- An asset by path. The host may load it (ue.load_asset: timed, logs a slow
-- load); a client takes it only from memory (ue.loaded_asset: a synchronous
-- load there can wait for the world's streaming and freeze the game).
function buy.asset(path)
    if S and S.role == "host" then
        local ok, o = ue.load_asset(path, "vehicles")
        if ok and ue.valid(o) then return o end
        return ue.find_object(path)
    end
    return ue.loaded_asset(path, "vehicles")
end

function buy.uid(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end

-- The money stacks of a Jig component, walked as CheckIfHasEnoughMoney /
-- TakeMoney do: { { g = guid, n = count } }, total.
function buy.stacks(jig, da)
    if not (ue.valid(jig) and da) then return nil, nil end
    local da_a = addr(da)
    local list, total = {}, 0
    local ok = pcall(function()
        jig.MainJigContainers:ForEach(function(_, c)
            c:get()[buy.F_ITEMS]:ForEach(function(_, it)
                local item = it:get()
                local info = item[buy.F_INFO]
                local id = info[buy.F_ITEMID]
                if ue.valid(id) and addr(id) == da_a then
                    local g = item[buy.F_USID]
                    local n = math.floor(tonumber(info[buy.F_COUNT]) or 0)
                    list[#list + 1] = { g = { A = g.A, B = g.B, C = g.C, D = g.D }, n = n }
                    total = total + n
                end
            end)
        end)
    end)
    if not ok then return nil, nil end
    return list, total
end

-- S_UpdateCount entries: the stacks of `before` whose count changed (all of
-- them when `after` is nil: the host's numbers as they are).
function buy.counts(before, after)
    local now = nil
    if after then
        now = {}
        for _, s in ipairs(after) do now[buy.uid(s.g)] = s.n end
    end
    local out = {}
    for _, s in ipairs(before or {}) do
        local n = s.n
        if now then n = now[buy.uid(s.g)] or 0 end
        if not now or n ~= s.n then out[#out + 1] = { [buy.F_UC_UID] = s.g, [buy.F_UC_NEW] = n } end
    end
    return out
end

-- The game's CLIENT_UpdateCounts on the player's component (host -> its client).
function buy.send_counts(jig, list)
    if #list == 0 then return "nothing changed" end
    local ok, err = pcall(function() jig:CLIENT_UpdateCounts(list, { A = 0, B = 0, C = 0, D = 0 }) end)
    return ok and string.format("CLIENT_UpdateCounts sent (%d stack(s))", #list) or ("CLIENT_UpdateCounts FAILED: " .. tostring(err))
end

-- The price of a vehicle class in DT_VehicleInfo row "Trader" (what the
-- trader window shows), or nil.
function buy.price_of(path)
    local dt = buy.asset(buy.DT)
    if not dt then return nil end
    local price = nil
    pcall(function()
        local row = dt:FindRow("Trader")
        row[buy.F_ROWS]:ForEach(function(_, el)
            local e = el:get()
            local c = e[buy.F_CLASS]
            if price == nil and ue.valid(c) and ue.path(c) == path then price = math.floor(tonumber(e[buy.F_PRICE]) or 0) end
        end)
    end)
    if price and price > 0 then return price end
    return nil
end

-- VBUY|class path|spawner x|y|z|price there|serial: a client bought a vehicle
-- on its machine (money taken and car spawned there only).
local function on_vbuy(f, pc)
    local key = sender(pc)
    if not key then return end
    local path, x, y, z = f[1], tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    local cprice = tonumber(f[5])
    local tok, serial = tostring(f[6] or ""):match("^(%w+)%.(%d+)$")
    serial = tonumber(serial)
    if not (path and path:find("^/Game/") and x and y and z) then return end
    local who = name_of(key)
    local pawn = ue.pawn_of(pc)
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    local da = buy.asset(buy.MONEY)
    -- refused: the client's game took the money from its own view already;
    -- its stacks get the host's numbers again (CLIENT_UpdateCounts)
    local function no(reason, have, price, detail)
        local back = "no inventory here"
        if ue.valid(jig) and da then
            local now, total = buy.stacks(jig, da)
            back = buy.send_counts(jig, buy.counts(now, nil))
            have = have or total
        end
        net.send_to(pc, "VBUYR", tostring(serial or 0), "no", reason, tostring(have or -1), tostring(price or -1))
        log.warn("vehicles: buy: %s's purchase of %s (#%s) refused on the host: %s; its money from the host again: %s",
            who, path, tostring(serial), detail, back)
    end
    -- one purchase, one charge, one car (a message seen again does nothing;
    -- the token changes when the client's game restarts)
    if serial then
        local seen = buy.seen[key]
        if seen and seen.tok == tok and serial <= seen.n then
            return log.warn("vehicles: buy: %s's purchase #%d of %s came again: ignored (no second charge, no second vehicle)", who, serial, path)
        end
        buy.seen[key] = { tok = tok, n = serial }
    end
    local cls = ue.find_object(path)
    if not cls then return no("class", nil, cprice, "the vehicle class is not loaded here") end
    -- the client's GetActorOfClass found a spawner at x,y,z: the same level actor here
    local best, bestd, first = nil, (NEAR_M * 2) ^ 2, nil
    for _, sp in ipairs(ue.find_all(TRADER_CLASS)) do
        if ue.valid(sp) and not ue.short(sp):find("^Default__") then
            first = first or sp
            local l = ue.location(sp)
            local d = l and d2(l, { X = x, Y = y, Z = z })
            if d and d <= bestd then best, bestd = sp, d end
        end
    end
    local where = "the spawner the client used"
    if not best and first then best, where = first, "GetActorOfClass's spawner (none at the client's)" end
    if not best then return no("spawner", nil, cprice, string.format("no vehicle trader spawner here (client's at %.0f,%.0f,%.0f)", x, y, z)) end
    local price, src = buy.price_of(path), "DT_VehicleInfo"
    if not price then price, src = cprice, "the client's trader window" end
    if not price or price <= 0 then return no("price", nil, cprice, "no price (DT_VehicleInfo not readable, none from the client)") end
    if cprice and cprice ~= price then
        log.warn("vehicles: buy: %s's window said %d for %s, DT_VehicleInfo says %d: the table's price is charged", who, cprice, path, price)
    end
    if not (ue.valid(jig) and da) then return no("inventory", nil, price, "no inventory component / DA_Money here") end
    local before, have = buy.stacks(jig, da)
    if ue.try(function() return jig:CheckIfHasEnoughMoney(price, da) end) ~= true then
        return no("money", have, price, string.format("%s money in its inventory here, price %d (%s)", tostring(have), price, src))
    end
    local took = ue.try(function() return jig:TakeMoney(price, da, {}) end)
    if took ~= true then
        return no("take", have, price, string.format("TakeMoney(%d) failed (%s money here)", price, tostring(have)))
    end
    local after, left = buy.stacks(jig, da)
    local upd = buy.send_counts(jig, buy.counts(before, after))
    -- the car: the game's own SpawnVehicle at that spawner, a replicated host actor
    discover(true)
    local had = {}
    for a in pairs(cur.by) do had[a] = true end
    local ok, err = apply(function() best:SpawnVehicle(cls) end)
    discover(true)
    local nv = nil
    for _, v in ipairs(cur.list) do
        local a = addr(v)
        if a and not had[a] and ue.valid(v) then nv = v break end
    end
    if nv then state_for(addr(nv), nv).dirty = true end
    M.stats.buys = M.stats.buys + 1
    net.send_to(pc, "VBUYR", tostring(serial or 0), "ok", nv and ue.short(nv) or "?", tostring(price), tostring(left or -1))
    local log_fn = (ok and nv) and log.info or log.warn
    log_fn("vehicles: buy: %s bought %s for %d (%s): its money on the host %s -> %s (%s); spawned at %s: %s (ok=%s%s)",
        who, path, price, src, tostring(have), tostring(left), upd, where, nv and ue.short(nv) or "NO NEW VEHICLE FOUND",
        tostring(ok), ok and "" or (" " .. tostring(err)))
end

-- VHORN: client -> host (the driver honked) and host -> client (play it).
-- Only the driver's (a passenger's horn is muted on its own machine and not sent: SEATK.pass_block, hush_snd).
local horn_client   -- forward: client handler
local function on_vhorn(f, pc)
    if S and S.role == "client" then return horn_client(f) end
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v or SEATK.not_driver("VHORN", key, v) then return end
    apply(function() v:Horn() end)
    host_horn_broadcast(v, pc)
    M.stats.relays = M.stats.relays + 1
end

-- ---------------------------------------------------------------------------
-- Host: hooks for the host's own actions
-- ---------------------------------------------------------------------------

-- No free seat for the host (a client drives, another one sits next to it):
-- the game's get-in seated the host anyway (one seat, no check). It is undone
-- the way the game's own exit does it, as for a client the host refuses
-- (local_force_exit): Event_ExitVehicle on player 0 = the host (host_till),
-- the ExitVehicle tail with the car still occupied (no handbrake, the fuel
-- keeps running), the character's own exit path, the camera back; the sit
-- pose ends on every machine. Event_ExitVehicle also stopped the driver's
-- engine sound and timers: back on, as after the host's own exit as a
-- passenger. The get-in's VehicleInteraction(true) 0.1 s later still
-- reaches the host: on_vi_post undoes it (SEATK.refused names it there).
-- Up to 0.7.3 the host sat down in the passenger's seat (two in one seat).
function SEATK.host_out(v, st, a)
    local hp = ue.local_pawn()
    -- the game's function only while player 0 is surely the host (a nil
    -- answer would let sdc_ctx pick the car's owner: the driver)
    local p0_host = not ctx.active or (ctx.scope_resolver == my_resolver and my_resolver(v, a) == false)
    local how = "not run"
    local side, side_why = SEATK.exit_side(v, hp)
    ue.set_prop(v, "GetOutPasseenger", side == "p")
    if p0_host then
        apply(function() v:Event_ExitVehicle() end)
        how = "the game's Event_ExitVehicle"
    end
    if hp and parent_vehicle(hp) == a then
        -- still attached: the same steps without the game's function
        pcall(function() hp:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
        local loc = socket_loc(v, side == "p" and "PassengerSide" or "DriverSide")
        if loc then pcall(function() hp:K2_SetActorLocationAndRotation(loc, ue.rotation(hp), false, {}, false) end) end
        how = how .. "; detached here"
    end
    -- (the game's Event_ExitVehicle resets it too, @23482)
    ue.set_prop(v, "GetOutPasseenger", false)
    drop_new_ui(v, nil)
    if hp then
        stop_sit(hp)
        exit_tail(v, hp, true)
        apply(function() hp:ResetVehicleCameraArmLength() end)
        char_out(hp)
        forget_att(hp)
        stop_sit_everywhere(hp)
        local hca = addr(hp)
        local hr = hca and seated[hca]
        if hr and hr.vaddr == a then seat_clear(hca, hr, hp, "host") end
    end
    set_collision(v, true)
    host_services(v)
    if st.host_seat ~= nil then st.host_seat, st.dirty = nil, true end
    st.host_idx, st.host_geo = nil, nil
    st.host_at = nil
    SEATK.refused = { va = a, till = os.clock() + SCOPE_S }
    M.stats.rejected = M.stats.rejected + 1
    -- "No free seat (M seats)" where a car has more than 2 (else as before)
    local n = M.vseats.layout(st.cls, { host = true }).count
    if n > 2 then log.say("veh_full_n", "warn", 5, n) else log.say("veh_full", "warn", 5) end
    seat_log("host", st.name, "refused", string.format("full (%d seats): %s drives, passengers %s; the host's get-in undone (%s), out at %s",
        n, name_of(st.driver_key), SEATK.seats_text(st), how,
        hp and parent_vehicle(hp) == nil and ((side == "p" and "the passenger door (" or "the driver door (") .. side_why .. ")") or "?"))
    recount_watch()
end

local function host_entered(v)
    local a = addr(v)
    local st = state_for(a, v)
    local hp0 = ue.local_pawn()
    if not (hp0 and parent_vehicle(hp0) == a) then
        -- the game's get-in did not seat the host (player 0 was someone
        -- else): no seat, and the VehicleUI it made on this screen goes
        log.warn("vehicles: seat: the host's get-in on %s did not seat the host (player 0 was another player); not seated, its VehicleUI removed",
            st.name)
        drop_new_ui(v, nil)
        return
    end
    local again = st.host_seat ~= nil
    -- the host's entry is the latest: its delayed VehicleInteraction (0.1 s)
    -- is the host's, not a client's whose entry came earlier
    st.scope_key, st.scope_till = nil, nil
    st.host_till = os.clock() + SCOPE_S
    -- (clear_area_flags: the client standing at the fuel / repair box would
    -- stop the game's VehicleInteraction(true) for the host 0.1 s from now -
    -- host stuck in the seat: no driving, no exit)
    local flags = nil
    if again then
        -- The game's get-in ran again while the host sits here (its
        -- VehicleInteraction stopped half-way, so the key offered "get in"
        -- again): the seat stays, no new seat is asked for (with the seat
        -- table a full car would refuse the host that sits in it, a free one
        -- would move it). The get-in put the host at the wheel and welded
        -- it: back in its own seat, unwelded again.
        st.host_at = os.clock()
        flags = clear_area_flags(v, true)
        local hp = ue.local_pawn()
        if hp and st.host_seat == "passenger" then
            local hidx = M.vseats.host_idx(st)
            local loc, rot = M.vseats.xf_geo(v, st.host_geo or M.vseats.geo(st.cls, hidx))
            if not loc then loc, rot = seat_transform(v, true) end
            if loc then pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
        end
        local r = seated[addr(hp) or -1]
        if r then r.unwelded = nil end
        if hp and parent_vehicle(hp) == a then seat_mark(hp, v, a, "host", true, st.host_geo and st.host_geo.pose) end
        log.info("vehicles: seat: the host's get-in on %s ran again while it sat there as %s%s (the game's VehicleUI made twice: the extra one goes; flags cleared: %s): the seat stays",
            st.name, tostring(st.host_seat), st.host_seat == "passenger" and (" in seat " .. tostring(M.vseats.host_idx(st))) or "",
            #flags > 0 and table.concat(flags, ",") or "none")
        st.dirty = true
        recount_watch()
        return
    end
    local free, idx = SEATK.free_seat(a, st, true)
    if not free then return SEATK.host_out(v, st, a) end
    st.host_at = os.clock()
    flags = clear_area_flags(v, true)
    if #flags > 0 then
        log.info("vehicles: %s had %s set (another player at the car); cleared for the host's entry", st.name, table.concat(flags, ","))
    end
    local lay = M.vseats.layout(st.cls, { host = true })
    if free == "passenger" then
        -- a client drives: the host sits in the first free seat
        local hp = ue.local_pawn()
        local geo = M.vseats.geo(st.cls, idx) or M.vseats.geo(st.cls, 2)
        local loc, rot = M.vseats.xf_geo(v, geo)
        if not loc then loc, rot = seat_transform(v, true) end
        if hp and loc then pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
        st.host_seat, st.host_idx, st.host_geo = "passenger", idx, geo
        -- "Seat N of M" where a car has more than 2 (else as before)
        if lay.count > 2 then
            log.say("veh_seat", "info", 5, lay.rank[idx] or idx, lay.count, name_of(st.driver_key))
        else
            log.say("veh_passenger", "info", 5, name_of(st.driver_key))
        end
        seat_log("host", st.name, "passenger seat " .. tostring(idx), name_of(st.driver_key) .. " drives")
    else
        st.host_seat, st.host_idx, st.host_geo = "driver", nil, nil
        SEATK.took(st, cfg.player_name())
        -- a driver is told "Seat 1 of M" only with somebody else in a car of more than 2
        if lay.count > 2 and M.vseats.any(st) then log.say("veh_seat_driver", "info", 5, lay.count) end
        seat_log("host", st.name, "driver", M.vseats.any(st) and ("passengers " .. SEATK.seats_text(st) .. "; driver seat free")
            or "driver seat free")
    end
    -- the game welded the host into the car: unweld now, so the seat
    -- replicates (the clients saw the host under the car)
    local hp = ue.local_pawn()
    if hp and parent_vehicle(hp) == a then seat_mark(hp, v, a, "host", true, st.host_geo and st.host_geo.pose) end
    st.dirty = true
    recount_watch()
end

-- `can`: ExitVehicle's CanExit? output as the hook read it (nil: not read).
local function host_exited(v, can)
    local a = addr(v)
    local st = vs[a]
    if not st then return end
    if host_attached(a) then
        -- The key ran the game's exit and the host still sits: the game said
        -- no (CanExit? false: 10 MPH or more, or both door sockets blocked,
        -- @163 / @482..519, its "Cannot exit vehicle" note) or its
        -- Event_ExitVehicle detached another player 0. One line per press,
        -- so a press that "did nothing" shows in the log.
        local m = mcomp(v)
        local mph = m and num(ue.try(function() return m:GetForwardSpeedMPH() end))
        log.info("vehicles: seat: the host's interact key ran the game's exit on %s but the host still sits there (CanExit=%s, speed %s MPH, seat %s)",
            st.name, can == nil and "?" or tostring(can), mph and string.format("%.1f", mph) or "?", tostring(st.host_seat))
        return
    end
    local was, was_idx, was_geo = st.host_seat, M.vseats.host_idx(st), st.host_geo
    st.host_seat, st.host_idx, st.host_geo = nil, nil, nil
    st.dirty = true
    local hp = ue.local_pawn()
    forget_att(hp)
    -- the exit stopped the sit montage only here: stop it on the clients too
    stop_sit_everywhere(hp)
    local hca = hp and addr(hp)
    local hr = hca and seated[hca]
    local was_seated = hr ~= nil and hr.vaddr == a
    if was_seated then seat_clear(hca, hr, hp, "host") end
    -- a seat 3+: the game put the host at a front door; its own (rear) door
    -- when that is free
    if hp and was == "passenger" and was_idx and was_idx >= 3 then
        local _, sw, loc, free = SEATK.exit_side(v, hp, was_idx, was_geo or M.vseats.geo(st.cls, was_idx))
        if loc and free == true then
            pcall(function() hp:K2_SetActorLocationAndRotation(loc, ue.rotation(hp), false, {}, false) end)
        end
        log.info("vehicles: seat: the host out of seat %d of %s: %s", was_idx, st.name,
            (loc and free == true) and ("at " .. sw) or ("left at the game's door (" .. tostring(sw) .. ")"))
    end
    -- ExitVehicle has one caller: the interact key (BP_PlayerCharacter
    -- @108596, IA_Interact "Started", once per press)
    local how = st.host_at and string.format("interact key, %.1f s after its get-in", os.clock() - st.host_at) or "interact key"
    st.host_at = nil
    if was == nil and not was_seated then
        -- The host sat in no seat here, yet its key ran the game's exit: its
        -- character had the game's driving state for this car without sitting
        -- in it (InVehicle? / Vehicle, movement off: a delayed get-in step
        -- that reached the host). Up to 0.7.0 the host stood beside the car
        -- without control until this second press (0.7.0 16:33: "host -> out,
        -- was passenger" 1.7 s after its real exit). Nothing to hand over.
        M.stats.stray_exits = M.stats.stray_exits + 1
        if st.driver_key then
            set_collision(v, true)
            host_services(v)
        end
        log.warn("vehicles: seat: the host's interact key ran the game's exit on %s although the host sat in no seat there (%s; %s): its character had the game's driving state for this car without a seat - a second press was needed to move again",
            st.name, st.driver_key and (name_of(st.driver_key) .. " drives") or "no driver", how)
        return
    end
    if st.driver_key then
        -- the host was a passenger: its Event_ExitVehicle + tail stopped the
        -- driver's services; the client still drives
        set_collision(v, true)
        host_services(v)
        seat_log("host", st.name, "out", "was " .. tostring(was or "passenger") .. "; " .. name_of(st.driver_key) .. " still drives; " .. how)
    else
        -- (a nil seat: the host got in before anyone joined, as the driver)
        -- (a passenger out of a car nobody drives: the last one out parks it)
        seat_log("host", st.name, "out", "was " .. tostring(was or "driver")
            .. (was ~= "passenger" and M.vseats.any(st) and ("; passengers " .. SEATK.seats_text(st) .. " stay in their seats") or "") .. "; " .. how)
        if was ~= "passenger" then
            SEATK.wheel_free(v, st, "the host got out")
        elseif M.vseats.any(st) then
            -- out of a parked car the others still sit in (the game's exit
            -- tail gave the collision back)
            set_collision(v, true)
        else
            SEATK.park_empty(v, st, a)
        end
    end
end

-- The host's seat ended without its exit key (host_exited): the host died in
-- it - the game's death in a vehicle (@13822 -> VehicleDrivingComponent.Death)
-- stops the car but leaves the body attached, and AfterDeath's UnPossess
-- (@1387) leaves the host without a character, so the host holds no seat any
-- more - or its character left the car some other way. As after its exit:
-- the seat is free; if the host drove, its passengers stay in their seats in
-- the parked car and are told the wheel is free (SEATK.wheel_free). Host
-- tick, once the get-in's window (host_till) is over.
function SEATK.host_gone(v, st)
    local was = st.host_seat
    st.host_seat, st.host_idx, st.host_geo, st.dirty = nil, nil, nil, true
    st.host_at = nil
    local why = ue.local_pawn() == nil and "the host has no character (died)" or "the host is not in it any more"
    local left = was ~= "passenger" and not st.driver_key and M.vseats.any(st)
    seat_log("host", st.name, "out", "was " .. tostring(was) .. "; " .. why .. ", without its exit"
        .. (left and ("; passengers " .. SEATK.seats_text(st) .. " stay in their seats") or ""))
    if left then
        SEATK.wheel_free(v, st, why)
    elseif was == "passenger" then
        SEATK.park_empty(v, st, addr(v))
    end
end

-- sdc_down: a client went down in its seat: out at once (the knockdown waits
-- for it to stand outside). Returns what was done.
function M.unseat_client(key, why)
    if not S or S.role ~= "host" then return "not the host" end
    if not seats[key] then return "no seat" end
    host_unseat(key, why or "downed", { tell = true, reason = why or "downed" })
    return "unseated"
end

-- sdc_down: the host went down in a vehicle: out the way its own exit goes
-- (the game's Event_ExitVehicle while player 0 is surely the host, else
-- detached at the door), then its exit's bookkeeping (host_exited): the
-- seat free, its passengers stay in their seats, a car nobody drives is
-- parked (engine, fuel and noise off, handbrake on), a client driver keeps
-- its car running. Not SEATK.host_out: that one is for a get-in refused
-- while a client drives (the car stays "occupied" and running).
function M.force_out_host(why)
    if not S or S.role ~= "host" then return "not the host" end
    local hp = ue.local_pawn()
    if not hp then return "no character" end
    local a = parent_vehicle(hp)
    local v = a and cur.by[a]
    if not (v and ue.valid(v)) then
        if ue.prop(hp, "InVehicle?") == true then
            char_out(hp)
            return "the game's driving state cleared (attached to no vehicle)"
        end
        return "not in a vehicle"
    end
    local st = state_for(a, v)
    local others = st.driver_key ~= nil or M.vseats.any(st)
    local p0_host = not ctx.active or (ctx.scope_resolver == my_resolver and my_resolver(v, a) == false)
    local side = SEATK.exit_side(v, hp)
    local how = "not run"
    ue.set_prop(v, "GetOutPasseenger", side == "p")
    if p0_host then
        apply(function() v:Event_ExitVehicle() end)
        how = "the game's Event_ExitVehicle"
    end
    if parent_vehicle(hp) == a then
        pcall(function() hp:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
        local loc = socket_loc(v, side == "p" and "PassengerSide" or "DriverSide")
        if loc then pcall(function() hp:K2_SetActorLocationAndRotation(loc, ue.rotation(hp), false, {}, false) end) end
        how = how .. "; detached here"
        if not p0_host and not st.driver_key then stop_services(v, others) end
    end
    ue.set_prop(v, "GetOutPasseenger", false)
    stop_sit(hp)
    exit_tail(v, hp, others)
    apply(function() hp:ResetVehicleCameraArmLength() end)
    char_out(hp)
    log.info("vehicles: seat: the host out of %s (%s): %s", st.name, tostring(why), how)
    host_exited(v, nil)
    pcall(hud.check, "the host got out (" .. tostring(why) .. ")")
    return how
end

-- ---------------------------------------------------------------------------
-- Client state
-- ---------------------------------------------------------------------------

local host_cap = false
local local_seat = nil      -- { vaddr, vname, seat = pending|driver|passenger|local, since }
local applied = {}          -- [vehicle address] = { name, fuel, health, color, drv, eng, at, lights_local }
local obs = {}              -- [vehicle address] = { engine = bool }
-- placed[character address] = { va, vname, name, at }: seated here from VSTATE;
-- missing[character address] = first time a VSTATE seat had no attachment here;
-- gone[ghost vehicle name] = when this client destroyed it (client_ghosts);
-- rescan_at: the last list rescan a packed VSTATE asked for (cpl.on_state)
local cpl = { placed = {}, missing = {}, gone = {}, rescan_at = -100, RESCAN_S = 5 }
local spawners_done = {}
local last_spawner_scan = -100
local ghost_logged = {}

local function local_pos(v)
    local l = ue.location(v)
    if not l then return nil end
    return f0(l.X), f0(l.Y), f0(l.Z), ue.class_name(v)
end

local function to_host(kind, v, ...)
    local x, y, z, cls = local_pos(v)
    if not x then return false end
    return net.send_to_host(kind, x, y, z, cls, ...)
end

local function in_local_seat(v, kinds)
    if not local_seat or addr(v) ~= local_seat.vaddr then return false end
    if not kinds then return true end
    return kinds[local_seat.seat] == true
end
local DRIVING = { driver = true, ["local"] = true }

local function client_ready()
    return S and S.role == "client" and S.client and S.client.acked == true
end

-- The host did not seat us: leave the way ExitVehicle would, without its
-- checks (Event_ExitVehicle + tail + the character's own exit path). Our own
-- get-in started the sit montage on every machine (Svr_Montage ->
-- MC_Montage) and the host never seated us, so nothing there stops it: the
-- game's replicated stop goes after it on this character's channel (up to
-- 0.7.3 the others saw a refused player sitting in the air beside the car).
-- The door: the one the game's own exit would pick (SEATK.exit_side).
local function local_force_exit(v, why, count)
    local ch = ue.local_pawn()
    local side, side_why = SEATK.exit_side(v, ch)
    ue.set_prop(v, "GetOutPasseenger", side == "p")
    apply(function() v:Event_ExitVehicle() end)
    ue.set_prop(v, "GetOutPasseenger", false)
    if side == "p" then log.info("vehicles: seat: refused: out at the passenger door of %s (%s)", ue.short(v), side_why) end
    if ch then
        stop_sit_everywhere(ch)
        exit_tail(v, ch, false)
        apply(function() ch:ResetVehicleCameraArmLength() end)
        char_out(ch)
        forget_att(ch)
    end
    set_requires(v, true)
    seat_log("this player", local_seat and local_seat.vname or ue.short(v), "out", "the host refused: " .. tostring(why)
        .. (count and (" (" .. count .. " seats)") or ""))
    local_seat = nil
    hud.check("the host refused the seat")
    if why == "full" then
        -- "No free seat (M seats)" where a car has more than 2 (else as before)
        if count and count > 2 then log.say("veh_full_n", "warn", 5, count) else log.say("veh_full", "warn", 5) end
    else
        -- (down: sdc_down's own notice says so)
        if why ~= "downed" then log.say("veh_rejected", "warn", 5, tostring(why)) end
    end
end

-- This machine's player in its seat on this machine's copy: a passenger at
-- the host's numbers for its seat (local_seat.geo; none: the mirror, seat
-- 2), the driver at the wheel.
function SEATK.place_local(v, lp)
    if not (local_seat and lp) then return end
    local loc, rot
    if local_seat.seat == "passenger" then
        if local_seat.geo then loc, rot = M.vseats.xf_geo(v, local_seat.geo) end
        if not loc then loc, rot = seat_transform(v, true) end
    else
        loc, rot = seat_transform(v, false)
    end
    if loc then pcall(function() lp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
end

local function client_entered(v)
    if not client_ready() then return end
    local a = addr(v)
    local lp = ue.local_pawn()
    if local_seat and local_seat.vaddr == a and (local_seat.seat == "driver" or local_seat.seat == "passenger") then
        -- The game's get-in ran again while this player sits here (a second
        -- press with its in-vehicle flag unset): the seat stays (its number
        -- and the host's numbers for it); the get-in put this player at the
        -- wheel and welded it: back in its seat, unwelded again. The host
        -- answers with the same seat (no notice).
        local r = seated[addr(lp) or -1]
        if r then r.unwelded = nil end
        local flags = clear_area_flags(v, true)
        if lp and parent_vehicle(lp) == a then
            seat_mark(lp, v, a, "this player", true, local_seat.geo and local_seat.geo.pose)
            if local_seat.seat == "passenger" then SEATK.place_local(v, lp) end
        end
        to_host("VENTER", v, "s2", "sw")
        seat_log("this player", local_seat.vname, local_seat.seat, string.format(
            "the game's get-in ran again while sitting here in seat %s: the seat stays, asked the host again%s",
            tostring(local_seat.idx or "?"), #flags > 0 and ("; cleared " .. table.concat(flags, ",")) or ""))
        return
    end
    local_seat = { vaddr = a, vname = ue.short(v), seat = host_cap and "pending" or "local", since = os.clock() }
    if host_cap then set_requires(v, true) end
    -- the host's character at the fuel / repair box of our copy would stop
    -- our own VehicleInteraction(true) 0.1 s from now
    local flags = clear_area_flags(v, true)
    -- the game welded us into our copy: unweld, so our moves keep reaching
    -- the host (its copy of us animates from them)
    if lp and parent_vehicle(lp) == a then seat_mark(lp, v, a, "this player", true) end
    -- "s2": this client knows seats 3+ (sdc_vehseats); "sw": it has the seat key
    to_host("VENTER", v, "s2", "sw")
    seat_log("this player", local_seat.vname, local_seat.seat,
        "entered here, asked the host" .. (#flags > 0 and ("; cleared " .. table.concat(flags, ",")) or ""))
end

local function client_exited(v)
    if not local_seat or addr(v) ~= local_seat.vaddr then return end
    local ch = ue.local_pawn()
    if ch and parent_vehicle(ch) == local_seat.vaddr then return end
    local side = "d"
    local cl = ch and ue.location(ch)
    local ds, ps = socket_loc(v, "DriverSide"), socket_loc(v, "PassengerSide")
    if cl and ds and ps and d2(cl, ps) < d2(cl, ds) then side = "p" end
    -- a seat 3+: the game put this player at a front door; its own (rear)
    -- door when that is free (its moves take it there on the host too)
    local idx = local_seat.idx
    local door = ""
    if ch and local_seat.seat == "passenger" and idx and idx >= 3 and local_seat.geo then
        local s2, sw, loc, free = SEATK.exit_side(v, ch, idx, local_seat.geo)
        if loc and free == true then
            pcall(function() ch:K2_SetActorLocationAndRotation(loc, ue.rotation(ch), false, {}, false) end)
            side = s2
            door = "; out of seat " .. idx .. " at " .. sw
        else
            door = "; out of seat " .. idx .. ", left at the game's door (" .. tostring(sw) .. ")"
        end
    end
    -- only the interact key calls ExitVehicle (BP_PlayerCharacter @108596,
    -- IA_Interact "Started": once per press); the age tells a quick second
    -- press from a stuck seat in the logs
    local age = os.clock() - (local_seat.seat_at or local_seat.since or os.clock())
    to_host("VEXIT", v, side, string.format("%.1f", age), tostring(local_seat.seat), tostring(idx or ""))
    set_requires(v, true)
    forget_att(ch)
    seat_log("this player", local_seat.vname, "out", string.format("exit here with the interact key after %.1f s; was %s, %s side%s",
        age, tostring(local_seat.seat), side, door))
    local_seat = nil
end

local function on_vcap()
    if not host_cap then log.info("vehicles: the host runs the vehicle sync") end
    host_cap = true
end

-- VSEAT|kind|name[|idx|N|M|side|x|y|z|yaw|pose|exit|tell|sw] (sdc_vehseats;
-- an older host sends kind and name only: seat 1 or 2; without "sw" it has
-- no seat key).
local function on_vseat(f)
    if not client_ready() then return end
    host_cap = true
    local kind = f[1]
    if not local_seat then
        log.info("vehicles: host seat answer '%s' but this player is not in a vehicle", tostring(kind))
        return
    end
    local v = vehicle_by(local_seat.vaddr, local_seat.vname)
    if kind == "none" then
        if v then local_force_exit(v, f[2] ~= "" and f[2] or "?", tonumber(f[3])) else local_seat = nil end
        return
    end
    local p = M.vseats.parse_vseat(f)
    local was, was_idx = local_seat.seat, local_seat.idx
    local_seat.seat = kind == "driver" and "driver" or "passenger"
    local_seat.idx = (p and p.idx) or (local_seat.seat == "driver" and 1 or 2)
    local_seat.geo = (local_seat.seat == "passenger" and p and p.geo) or nil
    local_seat.sw = p ~= nil and p.sw == true
    local same = was == local_seat.seat and was_idx == local_seat.idx
    if was ~= local_seat.seat then local_seat.seat_at = os.clock() end
    if v then
        set_requires(v, local_seat.seat ~= "driver")
        -- this machine's own entry put us at the wheel; sit where the host
        -- seated us (the attachment the host replicates says the same; a
        -- seat tuned live on the host comes again with its new numbers)
        local lp = ue.local_pawn()
        if lp and parent_vehicle(lp) == local_seat.vaddr and (local_seat.seat == "passenger" or was == "passenger") then
            SEATK.place_local(v, lp)
        end
    end
    -- the game's notice; none for the same seat again ("Seat N of M" where
    -- the car has more than 2, else as before; no name: nobody drives)
    local name = f[2] or "?"
    if local_seat.seat == "passenger" then
        if not same and (not p or p.tell) then
            if p and name == "" then
                log.say("veh_seat_free", "info", 5, p.n, p.m)
            elseif p and p.m and p.m > 2 then
                log.say("veh_seat", "info", 5, p.n, p.m, name)
            else
                log.say("veh_passenger", "info", 5, name)
            end
        end
    elseif was == "passenger" then
        -- (its seat key took it to the wheel: "Seat 1 of M" where the car
        -- has more than 2, as every move)
        if p and p.m and p.m > 2 then log.say("veh_seat_driver", "info", 5, p.m) else log.say("veh_driver_now", "info", 4) end
    elseif p and p.tell and p.m and p.m > 2 and not same then
        log.say("veh_seat_driver", "info", 5, p.m)
    end
    seat_log("this player", local_seat.vname, local_seat.seat .. (local_seat.seat == "passenger" and (" seat " .. local_seat.idx) or ""),
        "the host's answer" .. ((f[2] and f[2] ~= "") and ("; " .. f[2] .. " drives") or "") .. "; was " .. tostring(was)
        .. (p and string.format(" (seat %d of %s)", p.n, tostring(p.m)) or " (an older host: seats 1-2)"))
end

-- VSWR|kind[|M or name]: the host on this player's seat key (sdc_vehseats
-- header): "wheel" = the driver left, the wheel is free (once); "full" = no
-- free seat; "taken" = somebody took the free wheel just before (it stays);
-- "no" = it could not move this player.
function SEATK.on_vswr(f)
    if not client_ready() then return end
    local kind = f[1]
    local pass = local_seat ~= nil and local_seat.seat == "passenger"
    if kind == "wheel" then
        if pass then SEATK.say_wheel_free() end
    elseif kind == "taken" then
        if pass then log.say("veh_wheel_taken", "info", 4, (f[2] and f[2] ~= "") and f[2] or "?") end
    elseif kind == "full" then
        log.say("veh_switch_none", "info", 4)
    else
        log.say("veh_switch_failed", "warn", 4)
    end
    log.info("vehicles: seat key: the host's answer '%s%s' (this player: %s)", tostring(kind), f[2] and ("|" .. tostring(f[2])) or "",
        local_seat and (tostring(local_seat.seat) .. (local_seat.idx and (" seat " .. local_seat.idx) or "")) or "not seated")
end

-- This machine's player is a client and pressed its seat key (game thread,
-- SEATK.on_key): a passenger asks the host (VSWITCH; the host moves it and
-- answers VSEAT, or VSWR); with an older host (no "sw" in its VSEAT) the key
-- does nothing there: a notice. Returns the log text.
function SEATK.client_key()
    if not client_ready() then return "not connected" end
    local ls = local_seat
    if not ls or ls.seat ~= "passenger" then return "not a passenger (" .. tostring(ls and ls.seat) .. ")" end
    local v = vehicle_by(ls.vaddr, ls.vname)
    if not v then return "its vehicle is gone" end
    if not ls.sw then
        log.say("veh_switch_old_host", "warn", 5)
        return "the host has no seat key (an older version of the mod)"
    end
    to_host("VSWITCH", v)
    return string.format("seat %s of %s: asked the host (VSWITCH)", tostring(ls.idx or 2), ls.vname)
end

local function apply_color(v, idx)
    local colors = ue.prop(v, "Colors")
    local n = colors and ue.try(function() return colors:GetArrayNum() end)
    if type(n) ~= "number" or idx < 0 or idx >= n then return false end
    local mat = ue.try(function() return colors[idx + 1] end)   -- index checked: a read past the end grows a TArray
    local mesh = ue.prop(v, "Mesh")
    if not ue.valid(mat) or not ue.valid(mesh) then return false end
    ue.set_prop(v, "VehicleColor", idx)
    ue.set_prop(v, "RandomColorSelected?", true)
    return (pcall(function() mesh:SetMaterial(0, mat) end))
end

local function band(h)
    if not h then return 0 end
    if h <= 10 then return 2 end
    if h <= 30 then return 1 end
    return 0
end

-- One VSTATE record (x|y|z|class|colour|fuel|health|lights|engine|driver|
-- driver id|passenger id) on this machine's copy v.
function cpl.apply(v, f)
    local a = addr(v)
    local ap = applied[a]
    if not ap or ap.name ~= ue.short(v) then
        ap = { name = ue.short(v) }
        applied[a] = ap
    end
    local color, fuel, health = tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
    local lights, engine, drv = f[8] == "1", f[9] == "1", f[10] == "1"
    ap.drv, ap.eng, ap.at = drv, engine, os.clock()
    ap.occ_d, ap.occ_p = f[11], f[12]
    local t = os.clock()
    if color and color >= 0 and (ap.color ~= color or num(ue.prop(v, "VehicleColor")) ~= color) then
        if apply_color(v, color) then ap.color = color end
    end
    -- a refuel / repair done here that the tick has not reported yet would
    -- be overwritten right now: report it first
    fx.report(v, ap, "found before a vehicle state from the host")
    local keep = ap.raised_at ~= nil and t - ap.raised_at < fx.keep_s
    local cur_f, maxf, fc = fuel_of(v)
    local shown = false
    if fc and fuel then
        if keep and cur_f and fuel < cur_f - 1 then
            -- older than our report: the host's next state carries ours
            log.debug("vehicles: refuel: %s: the host's %.0f predates our refuel (%.0f here); kept", ue.short(v), fuel, cur_f)
        else
            shown = cur_f == nil or math.abs(cur_f - fuel) > 0.5
            ap.fuel = fuel
            ue.set_prop(fc, "CurrentFuel", fuel)
            ue.set_prop(fc, "Empty", fuel <= 0)
            if in_local_seat(v) and maxf then pcall(function() fc:UpdateUIFuel(fuel, maxf) end) end
        end
    end
    local old_h, maxh, hc = health_of(v)
    if hc and health then
        if keep and old_h and health < old_h - 0.5 then
            log.debug("vehicles: repair: %s: the host's %.0f predates our repair (%.0f here); kept", ue.short(v), health, old_h)
        else
            shown = shown or old_h == nil or math.abs(old_h - health) > 0.5
            ap.health = health
            ue.set_prop(hc, "CurrentHealth", health)
            if in_local_seat(v) and maxh then pcall(function() hc:UpdateUIHealth(health, maxh) end) end
            if band(old_h) ~= band(health) then apply(function() v:VehicleEngineFX(true) end) end
        end
    end
    if shown then fx.widgets(v) end
    ue.set_prop(v, "EngineOn?", engine)
    if (ue.prop(v, "LightsOn?") == true) ~= lights and t - (ap.lights_local or -100) > 2 then
        apply(function() v:TurnOnOffLights() end)
        -- (the host's wreck with its lights on: the game's function does not switch them on at 0 here)
        if lights and ue.prop(v, "LightsOn?") ~= true then
            log.info("vehicles: state: %s: the host's lights are on: %s", ue.short(v), SEATK.lights_back(v))
        end
    end
    M.stats.states_applied = M.stats.states_applied + 1
end

-- VSTATE|*|<record>|<record>|... (the host's vehicles near this player, one
-- message a tick), or VSTATE|<record> (one vehicle, as before 0.7.3). A
-- packed message is matched against one vehicle list (refreshed every 2 s);
-- a record whose vehicle is not in it (just bought, or out of this machine's
-- network range) rescans it at most every RESCAN_S.
local function on_vstate(f)
    if not client_ready() or not on("vehicle_state") then return end
    if f[1] ~= "*" then
        local v = vehicle_at(tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), f[4], MATCH_M)
        if v then cpl.apply(v, f) end
        return
    end
    discover_slow()
    local miss = nil
    for i = 2, #f - 11, 12 do
        local r = table.move(f, i, i + 11, 1, {})
        local v = vehicle_at(tonumber(r[1]), tonumber(r[2]), tonumber(r[3]), r[4], MATCH_M, true)
        if v then
            cpl.apply(v, r)
        else
            miss = miss or {}
            miss[#miss + 1] = r
        end
    end
    local t = os.clock()
    if not miss or t - cpl.rescan_at < cpl.RESCAN_S then return end
    cpl.rescan_at = t
    discover(true)
    for _, r in ipairs(miss) do
        local v = vehicle_at(tonumber(r[1]), tonumber(r[2]), tonumber(r[3]), r[4], MATCH_M, true)
        if v then cpl.apply(v, r) end
    end
end

-- A vehicle's VOCC list counts while it came with the latest VSTATE of that
-- vehicle (the host sends it next to each VSTATE record of a car with a
-- seat 3+ taken): an older one (a VSTATE came without it) is stale - field 12
-- of VSTATE says who sits then.
function cpl.occ_fresh(ap, t)
    return ap.occ_x ~= nil and (ap.occ_at or -100) >= (ap.at or -100) - 0.25 and t - (ap.at or -100) < 3 * STATE_EVERY_S
end

-- VOCC|*|x|y|z|class|occ|...: the seats 2+ of the host's vehicles near this
-- player that have someone in a seat 3+ (sdc_vehseats.parse_occ; a bad
-- entry is skipped). client_place sits a seated player there when the
-- engine's attachment did not arrive.
function cpl.on_occ(f)
    if not client_ready() or not on("vehicle_state") or f[1] ~= "*" then return end
    discover_slow()
    local t = os.clock()
    for i = 2, #f - 4, 5 do
        local x, y, z, cls = tonumber(f[i]), tonumber(f[i + 1]), tonumber(f[i + 2]), f[i + 3]
        local v = vehicle_at(x, y, z, cls, MATCH_M, true) or vehicle_at(x, y, z, cls, MATCH_M)
        if v then
            local a = addr(v)
            local ap = applied[a]
            if not ap or ap.name ~= ue.short(v) then
                ap = { name = ue.short(v) }
                applied[a] = ap
            end
            ap.occ_x, ap.occ_at = M.vseats.parse_occ(f[i + 4]), t
        end
    end
end

-- The vehicles with a seat 3+ taken (seat_tick: SEATK.cam): on the host
-- from its records, on a client from its own seat and the fresh VOCC lists
-- (an older host sends none: two seats, nothing behind).
function SEATK.rear_set()
    local out = {}
    if S and S.role == "host" then
        for a, st in pairs(vs) do
            if M.vseats.rear_taken(st) then out[a] = true end
        end
        return out
    end
    if local_seat and (local_seat.idx or 0) >= 3 then out[local_seat.vaddr] = true end
    local t = os.clock()
    for a, ap in pairs(applied) do
        if cpl.occ_fresh(ap, t) and M.vseats.rear_listed(ap.occ_x) then out[a] = true end
    end
    return out
end

-- The characters whose seat has the floor pose (seat_tick): on the host
-- from its records (each passenger's seat geometry), on a client from its
-- own seat and VOCC. Empty almost always (floor seats are stage 2).
function SEATK.floor_set(list)
    local out = {}
    if S and S.role == "host" then
        for _, st in pairs(vs) do
            for _, key in pairs(st.pax or {}) do
                local seat = seats[key]
                if seat and seat.geo and seat.geo.pose == "floor" then
                    local pc = remote_pc_of(key)
                    local ch = pc and ue.pawn_of(pc)
                    local ca = ch and addr(ch)
                    if ca then out[ca] = true end
                end
            end
            if st.host_seat == "passenger" and st.host_geo and st.host_geo.pose == "floor" then
                local ca = addr(ue.local_pawn())
                if ca then out[ca] = true end
            end
        end
        return out
    end
    if local_seat and local_seat.geo and local_seat.geo.pose == "floor" then
        local ca = addr(ue.local_pawn())
        if ca then out[ca] = true end
    end
    local t, ids = os.clock(), nil
    for _, ap in pairs(applied) do
        if cpl.occ_fresh(ap, t) then
            for _, o in ipairs(ap.occ_x) do
                if o.geo.pose == "floor" then
                    if not ids then
                        ids = {}
                        for _, ch in ipairs(list) do
                            local id = pawn_id(ch)
                            if id then ids[tostring(id)] = ch end
                        end
                    end
                    local ca = addr(ids[o.id])
                    if ca then out[ca] = true end
                end
            end
        end
    end
    return out
end

horn_client = function(f)
    if not client_ready() then return end
    local v = vehicle_at(tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), f[4], MATCH_M)
    if v then apply(function() v:Horn() end) end
end

-- Client: a refuel / repair done on this machine's copy since the host's last
-- state (ap.fuel / ap.health). Called by the UseGasCan hook, the tick and a
-- VSTATE about to overwrite it; each amount goes to the host once.
function fx.report(v, ap, why)
    if not (ap and host_cap and S and S.role == "client") then return false end
    local sent = false
    local t = os.clock()
    local fuel, maxf = fuel_of(v)
    if fuel and ap.fuel and fuel > ap.fuel + 1 then
        local add = fuel - ap.fuel
        local ok = to_host("VFUEL", v, string.format("%.1f", fuel), string.format("%.1f", add))
        log.info("vehicles: refuel: this player refuelled %s here: %.0f -> %.0f of %.0f (+%.0f; %s), %s",
            ue.short(v), ap.fuel, fuel, maxf or -1, add, why, ok and "sent to the host" or "NOT sent (no connection)")
        ap.fuel, ap.raised_at, sent = fuel, t, true
        -- (this player's running refuel hold: its end asks nothing more)
        local h = fx.holds[addr(v)]
        if h and h.kind == "refuel" then h.sent = true end
    end
    local hp, maxh = health_of(v)
    if hp and ap.health and hp > ap.health + 0.5 then
        local add = hp - ap.health
        local ok = to_host("VREPAIR", v, string.format("%.1f", hp), string.format("%.1f", add))
        log.info("vehicles: repair: this player repaired %s here: %.0f -> %.0f of %.0f (+%.0f; %s), %s",
            ue.short(v), ap.health, hp, maxh or -1, add, why, ok and "sent to the host" or "NOT sent (no connection)")
        ap.health, ap.raised_at, sent = hp, t, true
        local h = fx.holds[addr(v)]
        if h and h.kind == "repair" then h.sent = true end
    end
    return sent
end

-- Is this machine's player inside the vehicle's fuel / repair box?
function fx.inside(v, ch, kind)
    local box = ue.prop(v, kind == "refuel" and "FuelBoxCollision" or "RepairBoxCollision")
    if not ue.valid(box) then return nil end
    return ue.try(function() return box:IsOverlappingActor(ch) end) == true
end

-- The game's timer bar again (HUD_Game.InteractTimerUI + MaxTime, @18844 /
-- @18984); the game's 0.01 s loop (@20627) moves it while IsHeld is set.
function fx.timer_ui(v, kind)
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    if not ue.valid(hud) then return false end
    local ok = pcall(function()
        hud:InteractTimerUI(true, FText(kind == "refuel" and "Refilling Vehicle" or "Repairing Vehicle"))
    end)
    local w = ue.prop(hud, "InteractTimerWidget")
    local dur = num(ue.prop(v, "Duration"))
    if ue.valid(w) and dur then ue.set_prop(w, "MaxTime", dur) end
    return ok
end

-- This machine's player still marked "in a vehicle" (InVehicle?) while it
-- sits in none: the fuel / repair boxes skip it (@15482 / @16731) and the
-- interact key takes the exit branch. After a while, the character's own
-- exit path (VehicleInteraction(false), as the game's exit tail).
function fx.unstick()
    local lp = ue.local_pawn()
    if not lp or ue.prop(lp, "InVehicle?") ~= true or ue.prop(lp, "PlayerDead?") == true
        or ue.valid(ue.try(function() return lp:GetAttachParentActor() end)) then
        fx.stuck_since = nil
        return
    end
    local t = os.clock()
    fx.stuck_since = fx.stuck_since or t
    if t - fx.stuck_since < fx.stuck_s then return end
    fx.stuck_since = nil
    char_out(lp)
    pcall(function() lp:ResetVehicleCameraArmLength() end)
    -- a full VehicleInteraction(true) also turned the movement off (@62995,
    -- MOVE_None); only the game's ExitVehicle tail (@242) walks again
    local cmc = ue.prop(lp, "CharacterMovement")
    local walk = ue.valid(cmc) and num(ue.prop(cmc, "MovementMode")) == 0
    if walk then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
    hud.check("was still marked in a vehicle")
    log.warn("vehicles: this player was still marked in a vehicle (InVehicle?) while in none: the game's exit path run here (the fuel / repair options and the interact key need it); now InVehicle?=%s%s",
        tostring(ue.prop(lp, "InVehicle?")), walk and ", walking again (its movement was off)" or "")
end

-- ---------------------------------------------------------------------------
-- Hooks (Blueprint functions: one callback, after the body, on the machine
-- that ran it)
-- ---------------------------------------------------------------------------

local function hook_self(p)
    local v = get(p)
    if ue.valid(v) then return v end
    return nil
end

local function host_live()
    return S and S.role == "host" and #(S.remote_pcs or {}) > 0
end

local function on_enter_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if not v then return end
    if S and S.role == "client" then
        client_entered(v)
        hud.check("this player's get-in: an earlier panel was still on screen")
    elseif host_live() then
        host_entered(v)
        hud.check("this player's get-in: an earlier panel was still on screen")
    end
end

local function on_exit_post(self_p, can_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if not v then return end
    if S and S.role == "client" then
        client_exited(v)
        hud.check("exit")
    elseif host_live() then
        local can = get(can_p)
        if type(can) ~= "boolean" then can = nil end
        host_exited(v, can)
        hud.check("exit")
    end
end

-- BP_PlayerCharacter.VehicleInteraction(Enter?, VehicleRef), post, host.
-- Every get-in ends 0.1 s later with VehicleInteraction(true) on whoever
-- player 0 is then (@1706..1818); the get-in itself attached that character
-- (@11180). A character that is not attached to that vehicle got a get-in
-- step meant for someone else (a client who left within that 0.1 s - the
-- released window names the host - or any other misrouted call): it now has
-- InVehicle?, the car as its Vehicle and no movement (@62995) while standing
-- beside it, and only its interact key (the game's exit) gave it back.
-- Undone at once: the character's own exit steps (@107999, @88168..88225)
-- and walking again (the ExitVehicle tail, @242). Our own calls (apply) and
-- Enter? = false are left alone.
local function on_vi_post(self_p, enter_p, vref_p)
    if applying > 0 or not enabled() or not S or S.role ~= "host" then return end
    if get(enter_p) ~= true then return end
    local ch = hook_self(self_p)
    local v = get(vref_p)
    if not (ch and ue.valid(v)) then return end
    local va = addr(v)
    local pa = ue.try(function() return ch:GetAttachParentActor() end)
    if ue.valid(pa) and addr(pa) == va then
        -- The get-in's delayed step reached the client it was for: that
        -- client's player-0 window on this vehicle (scope_key, SCOPE_S) is
        -- done - its last call of the get-in. Kept open, it took the host's
        -- own player-0 calls on this car in the rest of that second (the
        -- prompt when the host looks at it). (With the host in the car the
        -- window closed at the get-in already: SEATK.early_step.)
        local st = vs[va]
        local mine = locally_controlled(ch)
        if st and st.scope_key and not mine then
            local pc = remote_pc_of(st.scope_key)
            local sc = pc and ue.pawn_of(pc)
            if sc and addr(sc) == addr(ch) and os.clock() < (st.scope_till or 0) then st.scope_till = os.clock() end
        end
        -- the step of a get-in that SEATK.early_step ran already, to the host in its seat
        if st and mine and os.clock() < (st.step_till or 0) then SEATK.step_seen(ch, st, true) end
        return
    end
    local is_local = locally_controlled(ch)
    if is_local then apply(function() ch:ResetVehicleCameraArmLength() end) end
    char_out(ch)
    local cmc = ue.prop(ch, "CharacterMovement")
    if ue.valid(cmc) then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
    forget_att(ch)
    -- the host's own get-in step after SEATK.host_out (no free seat): expected
    local rf = SEATK.refused
    if is_local and rf and rf.va == va and os.clock() < rf.till then
        SEATK.refused = nil
        log.info("vehicles: seat: the get-in step of the host's refused entry into %s undone (no driving state, walking, camera back)",
            ue.short(v))
        return
    end
    -- the step of a get-in that SEATK.early_step ran already, to the host who got out in between
    local sst = vs[va]
    if is_local and sst and os.clock() < (sst.step_till or 0) then return SEATK.step_seen(ch, sst, false) end
    M.stats.stray_vi = M.stats.stray_vi + 1
    log.warn("vehicles: seat: the game's get-in step VehicleInteraction(true) for %s reached %s, who does not sit in it (attached to %s) -> undone: no driving state, walking again (else it stood beside the car without control until a second press)",
        ue.short(v), is_local and "the host" or char_label(ch), ue.valid(pa) and ue.short(pa) or "nothing")
end

-- Driver-only controls. In the game the one in a vehicle is its driver: the
-- lights key (IA_Flashlight, VehicleDrivingComponent @1642..2229), the radial
-- menu's light (BP_PlayerCharacter RadialMenuSelection @609..688), the horn
-- (@8397..8816) and the flip key (@1166..1585) ask only InVehicle? and the
-- driving component's Vehicle - and a passenger the mod seats has both, on
-- its own machine. (Its throttle / brake / steering / handbrake reach
-- nothing: its copy takes the replicated inputs, set_requires - the host
-- passenger of a car nobody drives is held parked, SEATK.hold_frame; the
-- radio window stays every seated player's, sdc_vehradio.) This machine's player
-- is a passenger of v: a client by the host's answer (local_seat), the host
-- by its seat record (sdc_vehseats host_idx) while attached there.
function SEATK.pass_here(v)
    if not (S and v) then return false end
    local a = addr(v)
    if S.role == "client" then
        return local_seat ~= nil and local_seat.vaddr == a and local_seat.seat == "passenger"
    end
    local st = S.role == "host" and vs[a] or nil
    return st ~= nil and M.vseats.host_idx(st) ~= nil and host_attached(a)
end

-- A passenger's own lights / horn on this machine (`undo`: the lights,
-- switched back at once - the same frame, nothing shows or goes out, a
-- wreck's too: SEATK.lights_back; the horn was muted while it played,
-- SEATK.hush_snd / hush_ai, and is not passed on). The notice at most every
-- 5 s. True: it was a passenger's.
function SEATK.pass_block(v, undo)
    if not SEATK.pass_here(v) then return false end
    local how
    if undo then
        -- (the lights before this press: a Blueprint hook sees only the after;
        -- asked only of a wreck - above 0 health the game's switch is its own undo)
        local was_on = SEATK.flip_va == addr(v) and SEATK.lights_was == true
        apply(function() v:TurnOnOffLights() end)
        how = "switched back"
        if was_on and ue.prop(v, "LightsOn?") ~= true and (health_of(v) or 1) <= 0 then how = SEATK.lights_back(v) end
    else
        local h = SEATK.hush_now or {}
        SEATK.hush_now = nil
        how = string.format("not passed on; muted here: sound %s, AI noise %s", h.snd and "yes" or "NO", h.ai and "yes" or "NO")
    end
    local t = os.clock()
    if t - (SEATK.pass_note_at or -100) > 5 then
        SEATK.pass_note_at = t
        log.say("veh_driver_only", "info", 4)
    end
    log.info("vehicles: driver only: this player (a passenger) %s in %s: %s", undo and "switched the lights" or "honked",
        ue.short(v), how)
    return true
end

-- The game's TurnOnOffLights switches off always but on only while the
-- vehicle's CurrentHealth > 0 (BP_VehicleMaster TurnOnOffLights @344..418),
-- and a wreck keeps its lights (at 0 only the engine stops, @27198): a
-- passenger's radial-menu light (no engine check, BP_PlayerCharacter
-- RadialMenuSelection @609..688; the lights key needs the engine) switched
-- a wreck's lights off for good, on the host's copy for everyone. Back on
-- with the game's own function, the health above 0 for that one call and
-- put back right after. Also for the host's lights in a VSTATE (cpl.apply).
-- Returns the log text.
function SEATK.lights_back(v)
    local h, _, hc = health_of(v)
    if not (h and hc) then return "NOT switched back (a wreck: no health to read)" end
    ue.set_prop(hc, "CurrentHealth", 1)
    apply(function() v:TurnOnOffLights() end)
    ue.set_prop(hc, "CurrentHealth", h)
    return string.format("switched back (a wreck, health %.0f: on again through the game's function, its health above 0 for that call)%s",
        h, ue.prop(v, "LightsOn?") == true and "" or " - STILL OFF")
end

-- The lights of the vehicle this machine's player sits in as a passenger
-- (flip_va), as last seen: flip_hold each tick, and every TurnOnOffLights
-- this module runs on it (on_lights_post, applying) - so a passenger's press
-- finds the state before it (SEATK.pass_block).
function SEATK.lights_seen(p)
    local v = hook_self(p)
    if v and addr(v) == SEATK.flip_va then SEATK.lights_was = ue.prop(v, "LightsOn?") == true end
end

-- A passenger's horn makes no sound and calls no zombie (in single player
-- only the driver has one). The game's Horn plays Cue_Horn
-- (GameplayStatics.PlaySoundAtLocation, WorldContext = the vehicle, @90)
-- and reports an AI noise (AISense_Hearing.ReportNoiseEvent, Instigator =
-- the vehicle, MaxRange 8500 = 85 m, @191; the vehicle's driving noise has
-- the driver as Instigator, 3500, @23260). The Blueprint hook (on_horn_post)
-- runs after the function, so these two natives are caught before
-- (sdc_ue.hook_native, pre) while this machine's player sits in that
-- vehicle as a passenger (flip_va) and it is not the driver's horn this
-- module plays (apply): VolumeMultiplier 0; Loudness 0 and MaxRange 1 cm
-- (0 would mean "no limit"). On the host this is the noise the zombies hear.
-- Subscribed the first time this machine's player sits as a passenger
-- (flip_hold); with nobody seated so, both return at once.
SEATK.HUSH = { snd = "/Script/Engine.GameplayStatics:PlaySoundAtLocation",
               ai = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent" }
function SEATK.hush_hooks()
    if SEATK.hush_on or not ue.hook_native then return end
    SEATK.hush_on = true
    for _, kind in ipairs({ "snd", "ai" }) do
        local ok, err = ue.hook_native(SEATK.HUSH[kind], "vehicles.hush", SEATK["hush_" .. kind])
        log.info("vehicles: driver only: %s hook (a passenger's horn muted) %s%s", SEATK.HUSH[kind]:match(":([%w_]+)$"),
            ok and "ok" or "FAILED ", ok and "" or tostring(err))
    end
end

function SEATK.hush_set(p, x, kind)
    local ok = pcall(function() p:set(x) end)
    local back = ok and get(p) or nil
    if type(back) == "number" and math.abs(back - x) < 0.001 then
        SEATK.hush_now = SEATK.hush_now or {}
        SEATK.hush_now[kind] = true
    else
        log.err_throttled("veh.hush." .. kind, "vehicles: driver only: could not mute a passenger's horn (%s: set ok=%s, reads %s)",
            kind, tostring(ok), tostring(back))
    end
end

-- PlaySoundAtLocation(WorldContext, Sound, Location, Rotation, VolumeMultiplier, ...)
function SEATK.hush_snd(_, wco_p, sound_p, _, _, vol_p)
    local va = SEATK.flip_va
    if va == nil or applying > 0 or addr(get(wco_p)) ~= va then return end
    if not ue.short(get(sound_p)):find("Horn", 1, true) then return end
    SEATK.hush_set(vol_p, 0, "snd")
end

-- ReportNoiseEvent(WorldContext, NoiseLocation, Loudness, Instigator, MaxRange, Tag)
function SEATK.hush_ai(_, _, _, loud_p, inst_p, range_p)
    local va = SEATK.flip_va
    if va == nil or applying > 0 or addr(get(inst_p)) ~= va then return end
    SEATK.hush_set(loud_p, 0, "ai")
    SEATK.hush_set(range_p, 1, "ai")
end

-- The flip key of a passenger here: the vehicle's Flipped (the game's 1 s
-- guard after a flip, @25339 / @2968; not saved, not replicated) is held on
-- this machine's copy while this player sits in it as a passenger, so the
-- game answers with its own "Cannot flip vehicle" (@25405 -> @24871) and
-- moves nothing. Let go (false) when the seat ends or becomes the driver's,
-- for a VFLIP of the driver (on_vflip), and on a reset (`free`).
function SEATK.flip_hold(free)
    local a = nil
    if not free and S and enabled() then
        if S.role == "client" then
            if local_seat and local_seat.seat == "passenger" then a = local_seat.vaddr end
        elseif S.role == "host" then
            local hp = ue.local_pawn()
            local pa = hp and parent_vehicle(hp)
            local st = pa and vs[pa]
            if st and M.vseats.host_idx(st) then a = pa end
        end
    end
    local held = SEATK.flip_va
    if held and held ~= a then
        local v = cur.by[held]
        if v and ue.valid(v) then ue.set_prop(v, "Flipped", false) end
        SEATK.flip_va, SEATK.lights_was = nil, nil
        log.info("vehicles: driver only: flip key of %s free again", v and ue.short(v) or "a vehicle")
    end
    local v = a and cur.by[a]
    if v and ue.valid(v) then
        if ue.prop(v, "Flipped") ~= true then ue.set_prop(v, "Flipped", true) end
        if held ~= a then log.info("vehicles: driver only: this player sits in %s as a passenger: its flip key held", ue.short(v)) end
        SEATK.flip_va = a
        -- (also the passenger's lights as they are now, and its horn muted: SEATK.lights_seen / hush_hooks)
        SEATK.lights_was = ue.prop(v, "LightsOn?") == true
        SEATK.hush_hooks()
    end
end

local function on_lights_post(self_p)
    if applying > 0 then
        if SEATK.flip_va ~= nil then SEATK.lights_seen(self_p) end
        return
    end
    if not enabled() then return end
    local v = hook_self(self_p)
    if not v then return end
    if SEATK.pass_block(v, true) then return end
    if S and S.role == "client" then
        if host_cap and in_local_seat(v, DRIVING) then
            local a = addr(v)
            local ap = applied[a] or { name = ue.short(v) }
            applied[a] = ap
            ap.lights_local = os.clock()
            to_host("VLIGHT", v, ue.prop(v, "LightsOn?") == true and "1" or "0")
        end
    elseif host_live() then
        local st = state_for(addr(v), v)
        st.dirty = true
    end
end

local function on_horn_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if not v then return end
    if SEATK.pass_block(v, false) then return end
    if S and S.role == "client" then
        if host_cap and in_local_seat(v, DRIVING) then to_host("VHORN", v) end
    elseif host_live() then
        host_horn_broadcast(v, nil)
    end
end

local function on_flip_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if v and SEATK.flip_va ~= nil and SEATK.flip_va == addr(v) then
        log.info("vehicles: driver only: this player (a passenger) pressed the flip key in %s: the game's \"Cannot flip vehicle\" (flip_hold)",
            ue.short(v))
    end
    if v and S and S.role == "client" and host_cap and in_local_seat(v, DRIVING) then to_host("VFLIP", v) end
end

-- AddTowingComp / RemoveTowingComp (post), client: this player's own "Tow
-- Vehicle" / "Detach Vehicle" (the game offers it only to a player on foot at
-- the tow box, so no seat is asked for; the player stands at that vehicle).
-- A detach runs both functions (AddTowingComp -> RemoveTowingComp): the same
-- state of the same vehicle within half a second goes once.
local function on_tow_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if not (v and S and S.role == "client" and host_cap) then return end
    local lp = ue.local_pawn()
    local pl, vl = lp and ue.location(lp), ue.location(v)
    if not (pl and vl) or d2(pl, vl) > NEAR_M * NEAR_M then return end
    local want = ue.prop(v, "TowingVehicle?") == true and "1" or "0"
    local a, t = addr(v), os.clock()
    local last = fx.tow_sent
    if last and last.a == a and last.want == want and t - last.t < 0.5 then return end
    fx.tow_sent = { a = a, want = want, t = t }
    local ok = to_host("VTOW", v, want)
    log.info("vehicles: tow: this player %s %s here: %s", want == "1" and "hitched a vehicle to" or "detached the towed vehicle of",
        ue.short(v), ok and "sent to the host" or "NOT sent (no connection)")
end

local function on_push_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if not (v and S and S.role == "client" and host_cap) then return end
    local pc = ue.local_pc()
    local cam = pc and ue.prop(pc, "PlayerCameraManager")
    local fwd = ue.valid(cam) and vec(ue.try(function() return cam:GetActorForwardVector() end))
    if fwd then to_host("VPUSH", v, string.format("%.3f", fwd.X), string.format("%.3f", fwd.Y), string.format("%.3f", fwd.Z)) end
end

-- The price the clicked VehicleVendorButton charged here (its Price text, read
-- by the click's Text to Int), or nil.
function buy.button_price(cls)
    local ca = addr(cls)
    for _, b in ipairs(ue.find_all("VehicleVendorButton_C")) do
        if ue.valid(b) and not ue.short(b):find("^Default__") then
            local bc = ue.prop(b, "Vehicle")
            if ue.valid(bc) and addr(bc) == ca then
                local s = ue.str(ue.prop(b, "Price"))
                return tonumber((s:gsub("[^%d]", ""))), s
            end
        end
    end
    return nil, nil
end

function buy.money_here()
    local lp = ue.local_pawn()
    local _, total = buy.stacks(lp and ue.prop(lp, "BP_JigMultiplayer"), buy.asset(buy.MONEY))
    return total
end

-- GameplayStatics.BeginDeferredActorSpawnFromClass, pre (the shared engine
-- hook): a client's vehicle trader spawner about to spawn the car only this
-- machine would have. A non-actor class makes the spawn return None and
-- FinishSpawningActor(None) do nothing (as sdc_dialogue does for trader
-- spawners); the host's car comes replicated. (Not blocked: the ghost pass
-- removes it.)
function buy.on_spawn(_, wco_p, class_p)
    if not (S and S.role == "client" and host_cap) or not wco_p or not class_p or not enabled() then return end
    local wco = get(wco_p)
    if not ue.valid(wco) or ue.class_name(wco) ~= TRADER_CLASS then return end
    local ksl = ue.ksl()
    local ok, server = pcall(function() return ksl:IsServer(wco) end)
    if not ok or server ~= false then return end
    local cls = get(class_p)
    local na = ue.find_object(buy.NOT_ACTOR)
    if na and pcall(function() class_p:set(na) end) then
        buy.blocked = os.clock()
        log.info("vehicles: buy: this client's own spawn of %s at %s blocked (the host spawns the car)", ue.short(cls), ue.short(wco))
    else
        log.warn("vehicles: buy: cannot block this client's own spawn of %s; the car only here is removed after it appears", ue.short(cls))
    end
end

-- The shared engine hook; a failed registration is tried again on the next
-- ticks, up to `max_tries` (install_hooks).
function buy.hook_spawn(max_tries)
    if buy.spawn_hooked or buy.spawn_tries >= max_tries then return end
    buy.spawn_tries = buy.spawn_tries + 1
    local ok, err = ue.hook_native(buy.SPAWN_FN, "vehicles.buy", safe("buy-spawn", buy.on_spawn))
    buy.spawn_hooked = ok == true
    if ok then
        log.info("vehicles: trader spawn hook ok%s", buy.spawn_tries > 1 and string.format(" (try %d)", buy.spawn_tries) or "")
    elseif buy.spawn_tries == 1 then
        log.warn("vehicles: trader spawn hook FAILED %s; tried again each tick (up to %d tries)", tostring(err), max_tries)
    elseif buy.spawn_tries >= max_tries then
        log.err("vehicles: trader spawn hook FAILED %d times (%s): a client's own trader car is not blocked", max_tries, tostring(err))
    end
end

-- BP_VehicleTraderSpawner.SpawnVehicle(Class), post. Host: its own purchase
-- (the game did all of it there). Client: the game has taken the money from
-- this machine's view of the inventory; the host repeats the purchase.
local function on_buy_post(self_p, class_p)
    if applying > 0 or not enabled() or not S then return end
    local sp = hook_self(self_p)
    local cls = get(class_p)
    if not sp or not ue.valid(cls) then return end
    local path = ue.path(cls)
    if S.role == "host" then
        log.info("vehicles: buy: the host bought %s at the trader (the game's own purchase there)", path)
        return
    end
    if S.role ~= "client" or not host_cap then return end
    local l = ue.location(sp)
    if not l or not path:find("^/Game/") then return end
    local price, shown = buy.button_price(cls)
    buy.token = buy.token or string.format("%x%04x", os.time() % 0xFFFFFF, math.random(0, 0xFFFF))
    buy.serial = buy.serial + 1
    local blocked = buy.blocked ~= nil and os.clock() - buy.blocked < 2
    buy.blocked = nil
    net.send_to_host("VBUY", path, f0(l.X), f0(l.Y), f0(l.Z), tostring(price or ""), buy.token .. "." .. buy.serial)
    log.info("vehicles: buy: this player bought %s for %s at the trader here (#%d): the game took it from this machine's view (%s money left here); own spawn %s; asked the host",
        path, price and tostring(price) or ("? (" .. tostring(shown) .. ")"), buy.serial, tostring(buy.money_here()),
        blocked and "blocked" or "not blocked (the ghost pass removes it)")
end

-- VBUYR|serial|ok|vehicle|price|money left on the host
-- VBUYR|serial|no|reason|money on the host|price
local function on_vbuyr(f)
    if not (S and S.role == "client") then return end
    local here = buy.money_here()
    if f[2] == "ok" then
        local hl = tonumber(f[5])
        local same = here == nil or hl == nil or hl < 0 or here == hl
        local fn = same and log.info or log.warn
        fn("vehicles: buy: the host charged %s and spawned %s (#%s); money here %s, on the host %s%s", tostring(f[4]),
            tostring(f[3]), tostring(f[1]), tostring(here), tostring(f[5]), same and "" or " - DIFFERENT")
        return
    end
    local reason = tostring(f[3])
    if reason == "money" then
        log.say("veh_buy_money", "warn", 6, tonumber(f[4]) or 0, tonumber(f[5]) or 0)
    else
        log.say("veh_buy_failed", "warn", 6, buy.WHY[reason] or reason)
    end
    log.warn("vehicles: buy: the host refused purchase #%s: %s (money on the host %s, price %s; here now %s)",
        tostring(f[1]), reason, tostring(f[4]), tostring(f[5]), tostring(here))
end

-- The host's key press is over (its BP_JigHelperComp.TryInteract returned).
-- The game keeps InteractExecutedActor (@1363) until the inventory closes,
-- not until the key is released (see host_interacting): a vehicle the host
-- got into stayed "pressed" for minutes, and the resolver gave the host the
-- player-0 calls meant for a client on that vehicle. Up to 0.7.0: the host
-- got out with a passenger in the car -> the passenger took the wheel through
-- the game's get-in -> its VehicleInteraction(true) 0.1 s later (@1706..1818,
-- player 0 = whoever the resolver names THEN) went to the host: InVehicle?,
-- its Vehicle, movement off (@62995) beside the car, until a second press of
-- the key ran the game's exit again. For a vehicle both of the game's readers
-- are empty (OnStopExecuteInteract @3484 on release, OnExecuteInteractEnded
-- @3487 when the inventory closes), so it is cleared here: the next
-- TryInteract sets it again while that press runs. (A trader / NPC stays:
-- the dialogue's trade event reads it later, Quest_Event_OnInteractNPC.)
local function host_press_done(hc, ie)
    local a = ue.valid(ie) and addr(ie)
    if not a then return end
    if not cur.by[a] then discover(true) end   -- (a key press: rare)
    if not cur.by[a] then return end
    if ue.set_prop(hc, "InteractExecutedActor", nil) then
        info_once("pressdone", "vehicles: interact: the host's press on %s is over: its interact target cleared (the game keeps it until the inventory closes; the vehicle resolver reads it as \"pressing now\")",
            ue.short(ie))
    end
end

-- This machine's player pressed the interact key (BP_JigHelperComp.TryInteract,
-- post) next to a car someone sits in: one line with what the press hit and
-- what came of it (the host could not get into a car the client drove).

local function on_try_interact_post(self_p)
    if applying > 0 or not enabled() or not S or (S.role ~= "host" and S.role ~= "client") then return end
    local hc = hook_self(self_p)
    if not hc then return end
    local owner = ue.try(function() return hc:GetOwner() end)
    if not ue.valid(owner) or not locally_controlled(owner) then return end
    -- (read before the host's press is closed: the log line below names it)
    local ie = ue.prop(hc, "InteractExecutedActor")
    if S.role == "host" then host_press_done(hc, ie) end
    local n_by = {}
    for _, r in pairs(seated) do n_by[r.vaddr] = (n_by[r.vaddr] or 0) + 1 end
    if next(n_by) == nil then return end
    local ol = ue.location(owner)
    if not ol then return end
    local best, bd = nil, SEATK.near * SEATK.near
    for _, v in ipairs(cur.list) do
        local a = ue.valid(v) and addr(v)
        local l = a and n_by[a] and ue.location(v)
        if l then
            local d = d2(l, ol)
            if d <= bd then best, bd = v, d end
        end
    end
    if not best then return end
    local a = addr(best)
    local mine = n_by[a]
    local ta = ue.prop(hc, "CurrentTracActor")
    local outcome
    if parent_vehicle(owner) == a then
        outcome = S.role == "host" and ("seated here as " .. tostring((vs[a] or {}).host_seat or "?"))
            or ("in the car here, asked the host (" .. tostring(local_seat and local_seat.seat or "?") .. ")")
    elseif ue.valid(ie) then
        outcome = "the key went to " .. ue.short(ie)
    else
        outcome = "nothing interactable hit (no entry)"
    end
    log.info("vehicles: interact: %s pressed interact at %s (%d seated there): interact target=%s, looked-at=%s -> %s",
        char_label(owner), ue.short(best), mine, ue.valid(ie) and ue.short(ie) or "none",
        ue.valid(ta) and ue.short(ta) or "none", outcome)
end

-- BP_VehicleMaster.OnExecuteInteract(InteractingActor, Option), post, on the
-- machine whose player pressed the key: "Refuel Vehicle" / "Repair Vehicle".
function fx.on_interact(self_p, actor_p, opt_p)
    if applying > 0 or not enabled() or not S or (S.role ~= "host" and S.role ~= "client") then return end
    local v = hook_self(self_p)
    if not v then return end
    local a = addr(v)
    -- (this car's hold only: the game's IsHeld and delay are per vehicle, a
    -- hold on another car runs on)
    local h = fx.holds[a]
    local kind = fx.kind_of(ue.try(function() return ue.str(opt_p:get().TagName) end))
    -- (another option: only while this player's hold on this car waits)
    if not kind and not h then return end
    local lp = ue.local_pawn()
    local who = get(actor_p)
    if not (lp and ue.valid(who)) or addr(who) ~= addr(lp) then return end
    if not kind then
        local t = os.clock()
        if h.dur and t >= h.t0 + h.dur then
            -- the hold's time was up: its last step ran before this press
            -- (getting in right after the bar filled), no tick saw it yet
            fx.hold_end(t, a)
        elseif ue.prop(v, "IsHeld") ~= true then
            -- any other option on this car during the hold (the game's
            -- @17947: IsHeld set -> only cleared, nothing else): the game's
            -- last step will find the flag down and do nothing - so
            -- fx.hold_end must not take the flag down for that step
            fx.holds[a] = nil
            log.info("vehicles: %s: this player's hold on %s here ended by another option (the game's press only cleared its flag; its last step does nothing)",
                h.kind, h.vname)
        end
        return
    end
    local cur, max
    if kind == "refuel" then cur, max = fuel_of(v) else cur, max = health_of(v) end
    local outcome
    if ue.prop(v, "IsHeld") ~= true then
        -- @17947: IsHeld was already set, so this press only cleared it
        if h then
            outcome = "stopped its running hold (the game's second press)"
        else
            outcome = "the game's hold flag was set: this press only cleared it"
        end
        fx.holds[a] = nil
    else
        -- an earlier hold on this car whose time is up and whose end no tick
        -- has seen yet: its last step ran (the flag was down for this press)
        -- - its ask first
        if h and h.dur and os.clock() >= h.t0 + h.dur then fx.hold_end(os.clock(), a) end
        local full
        if kind == "refuel" then full = cur ~= nil and max ~= nil and cur >= max
        else full = cur ~= nil and max ~= nil and cur > max - 1 end
        local has = nil
        if not full then has = fx.has_item(lp, kind) end
        if full then
            outcome = kind == "refuel" and "the game says the tank is full" or "the game says it needs no repair"
        elseif has == false then
            outcome = "no " .. fx.item_name(kind) .. " in this player's inventory here (the game does nothing)"
        else
            local dur = num(ue.prop(v, "Duration")) or 10
            local t = os.clock()
            -- v0: the value at the press (fx.hold_end's line; `sent`: fx.report
            -- sent an add the game made here during this hold)
            fx.holds[a] = { va = a, vname = ue.short(v), kind = kind, t0 = t, till = t + dur + 1, dur = dur, v0 = cur, has = has }
            -- (has nil: the item asset is not in memory here - not looked for)
            outcome = string.format("hold started (%.0f s, %s %s)", dur, fx.item_name(kind),
                has == true and "found here" or "not checked here")
            -- (a hold on another car runs on beside it, the game's own on each)
            local other = {}
            for oa, oh in pairs(fx.holds) do
                if oa ~= a and oh.dur and t < oh.t0 + oh.dur then other[#other + 1] = oh.kind .. " on " .. oh.vname end
            end
            if #other > 0 then outcome = outcome .. "; this player's hold still running beside it: " .. table.concat(other, ", ") end
        end
        if full or has == false then
            -- the game leaves IsHeld set (@18506, then returns): the next press
            -- of any option on this car, getting in too, would only clear it
            ue.set_prop(v, "IsHeld", false)
            outcome = outcome .. "; the game's hold flag cleared"
        end
    end
    log.info("vehicles: %s: %s chose %s at %s here: %s %.0f of %.0f, in the %s box=%s, in a vehicle=%s -> %s",
        kind, char_label(lp), kind == "refuel" and "Refuel Vehicle" or "Repair Vehicle", ue.short(v),
        kind == "refuel" and "fuel" or "health", cur or -1, max or -1, kind == "refuel" and "fuel" or "repair",
        tostring(fx.inside(v, lp, kind)), tostring(ue.prop(lp, "InVehicle?") == true), outcome)
end

-- BP_VehicleMaster.UseGasCan, post: the hold ran out with IsHeld still set
-- and the game used a gas can here (or found none: "No gas found" - always
-- on a client, whose take reads the host's data: fx.ask, from that note).
function fx.on_gascan(self_p)
    if applying > 0 or not enabled() or not S or (S.role ~= "host" and S.role ~= "client") then return end
    local v = hook_self(self_p)
    if not v then return end
    local a = addr(v)
    local fuel, maxf = fuel_of(v)
    if S.role == "client" then
        local ap = applied[a]
        if not host_cap then
            fx.holds[a] = nil
            log.warn("vehicles: refuel: the game's UseGasCan ran on %s here (fuel %.0f of %.0f), but the host runs no vehicle sync: not sent",
                ue.short(v), fuel or -1, maxf or -1)
        elseif ap and fx.report(v, ap, "the game's UseGasCan") then
            fx.holds[a] = nil
        else
            -- (its note normally asked already; one ask per hold either way)
            fx.ask(v, "refuel", "the game's UseGasCan added nothing here")
        end
    else
        fx.holds[a] = nil
        local st = vs[a]
        if st then st.dirty = true end
        fx.widgets(v)
        log.info("vehicles: refuel: the host used a gas can on %s: fuel now %.0f of %.0f (the game's own UseGasCan; sent to the clients)",
            ue.short(v), fuel or -1, maxf or -1)
    end
end

-- BP_VehicleMaster.OnBegin/EndFuelInteract, OnBegin/EndRepairInteract
-- (Actor), post. The game keeps one flag, one option and one IsHeld per
-- vehicle for all players: another player's character leaving a box here
-- takes the option, and the running hold, from this machine's player too
-- (@14726 / @14038). Give them back: the game's own OnBegin...Interact for
-- this player while it stands in the box; IsHeld and the timer bar for its
-- hold.
function fx.box(kind, ended)
    return function(self_p, actor_p)
        if applying > 0 or not enabled() or not S or (S.role ~= "host" and S.role ~= "client") then return end
        local v = hook_self(self_p)
        local who = get(actor_p)
        local lp = ue.local_pawn()
        if not (v and lp and ue.valid(who)) then return end
        if ue.try(function() return who:ActorHasTag(FName("Player")) end) ~= true then return end
        local a = addr(v)
        local box = kind == "refuel" and "fuel" or "repair"
        if addr(who) == addr(lp) then
            local h = fx.holds[a]
            local note = ""
            local t = os.clock()
            if ended and h and S.role == "client" and h.dur and t >= h.t0 + h.dur and not h.out then
                -- the hold's time is up: the game's last step has run (a client's
                -- tick asks the host for it a moment later, fx.hold_end); a player
                -- walking off as the bar fills keeps its refuel / repair
                h.out = t
                note = string.format("; its %s hold's time was up %.1f s before: the tick looks at its end", h.kind, t - h.t0 - h.dur)
            elseif ended and h and not h.out then
                fx.holds[a] = nil
                note = string.format("; its %s hold stopped (the game: leaving a box)", h.kind)
            end
            local k = tostring(a) .. box .. tostring(ended)
            if note ~= "" or t - (fx.box_log[k] or -100) > 10 then
                fx.box_log[k] = t
                -- entered with the flag set: the game offers the option (in a
                -- vehicle: it skips this player, @15482 / @16731)
                log.info("vehicles: %s: this player %s the %s box of %s here (box flag=%s, in a vehicle=%s)%s",
                    kind, ended and "left" or "entered", box, ue.short(v),
                    tostring(ue.prop(v, kind == "refuel" and "InRefuellingArea?" or "InRepairingArea?")),
                    tostring(ue.prop(lp, "InVehicle?") == true), note)
            end
            return
        end
        if not ended then return end
        local back = {}
        if ue.prop(lp, "InVehicle?") ~= true and fx.inside(v, lp, kind) then
            apply(function()
                if kind == "refuel" then v:OnBeginFuelInteract(lp) else v:OnBeginRepairInteract(lp) end
            end)
            back[#back + 1] = kind == "refuel" and "Refuel Vehicle" or "Repair Vehicle"
        end
        local h = fx.holds[a]
        -- (only while the hold's time runs: after it the game's last step has
        -- cleared the flag itself, and a flag set again would never come down)
        if h and not h.out and os.clock() < (h.dur and h.t0 + h.dur or h.till)
            and ue.prop(v, "IsHeld") ~= true then
            ue.set_prop(v, "IsHeld", true)
            fx.timer_ui(v, h.kind)
            back[#back + 1] = "its " .. h.kind .. " hold"
        end
        if #back > 0 then
            log.info("vehicles: %s: %s left the %s box of %s here (the game clears it for every player); given back to this player: %s",
                kind, char_label(who), box, ue.short(v), table.concat(back, ", "))
        else
            log.debug("vehicles: %s: %s left the %s box of %s here; this player was not at it", kind, char_label(who), box, ue.short(v))
        end
    end
end

-- A note on this screen (HUD NotificationUI) taken off again: the client's
-- own false "No gas found" / "No repair kits found" (as sdc_world's
-- generator gas can).
function fx.unnote(text)
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    local vb = ue.prop(ue.prop(hud, "NotificationUI"), "VerticalBox_31")
    if not ue.valid(vb) then return false end
    local n = tonumber(ue.try(function() return vb:GetChildrenCount() end)) or 0
    for i = n - 1, math.max(0, n - 6), -1 do
        local w = ue.try(function() return vb:GetChildAt(i) end)
        local det = ue.prop(w, "NotificationDetailsStruct")
        local msg = det and ue.try(function() return ue.str(det[fx.NOTE_MSG]) end)
        if msg == text then return (pcall(function() w:RemoveFromParent() end)) end
    end
    return false
end

-- The game's own note, with the vehicle as context (as its own step).
function fx.note(text, v)
    local gfl = ue.find_object(fx.GFL)
    if not gfl then return false end
    return (apply(function()
        gfl:CreateNotificationUI(FText(text), nil, { R = 1, G = 1, B = 1, A = 1 }, 2.0, false, v)
    end))
end

function fx.timer_off()
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    if ue.valid(hud) then pcall(function() hud:InteractTimerUI(false, FText("")) end) end
end

-- Client: the game's last refuel / repair step ran on this copy and could not
-- take the item (a client's ServerFindThenConsumeByItemID reads the host's
-- data, see "Refuel / repair"): the host does that step - one ask per hold.
function fx.ask(v, kind, why)
    if not (S and S.role == "client") then return false end
    local a = addr(v)
    local k = tostring(a) .. kind
    local t = os.clock()
    if t - (fx.asked[k] or -100) < fx.ask_gap_s then return false end
    fx.asked[k] = t
    fx.holds[a] = nil
    local note = kind == "refuel" and fx.NO_GAS or fx.NO_KIT
    local off = fx.unnote(note)
    if not off then ue.delay("veh-unnote", 100, function() fx.unnote(note) end) end
    local cur, max
    if kind == "refuel" then cur, max = fuel_of(v) else cur, max = health_of(v) end
    if not host_cap then
        log.warn("vehicles: %s: the game's %s step on %s here took no %s (%s), and the host runs no vehicle sync: nothing done",
            kind, kind, ue.short(v), fx.item_name(kind), tostring(why))
        return false
    end
    -- the game's step adds half the maximum (UseGasCan @234, the kit branch @2185)
    local add = (max or 0) / 2
    local there = math.min(max or 0, (cur or 0) + add)
    local ok = to_host(kind == "refuel" and "VFUEL" or "VREPAIR", v, string.format("%.1f", there), string.format("%.1f", add))
    log.info("vehicles: %s: the game's %s step on %s here could not take the %s (%s; a client's ServerFindThenConsumeByItemID reads MainJigContainers, which only the host fills): %s - the host takes it from this player's inventory and adds +%.0f (%s %.0f of %.0f here; its false note %s)",
        kind, kind, ue.short(v), fx.item_name(kind), tostring(why), ok and "asked the host" or "NOT sent (no connection)",
        add, kind == "refuel" and "fuel" or "health", cur or -1, max or -1, off and "taken off" or "taken off shortly")
    return ok
end

-- GameFunctionLibrary.CreateNotificationUI (post), every machine: on a
-- client, its copy of a vehicle saying "No gas found" (UseGasCan @585) / "No
-- repair kits found" (the kit branch @2805) is the moment its own take failed.
function fx.on_note(_, msg_p, _, _, _, _, wco_p)
    if applying > 0 or not S or S.role ~= "client" or not enabled() then return end
    local text = ue.fstring(msg_p)
    local kind = (text == fx.NO_GAS and "refuel") or (text == fx.NO_KIT and "repair") or nil
    if not kind then return end
    local v = get(wco_p)
    local a = ue.valid(v) and addr(v)
    if a and not cur.by[a] then discover(true) end
    -- (13.11: in the game this hook never saw these notes; this line says
    -- whether it does now, and with which context)
    log.info("vehicles: %s: the game's note '%s' seen here (context %s%s)", kind, text,
        ue.valid(v) and ue.short(v) or "none", (a and cur.by[a]) and "" or ": no vehicle of this list")
    if not (a and cur.by[a]) then return end
    fx.ask(v, kind, "its note '" .. text .. "'")
end

-- Client, every tick: the end of this player's hold. The game's last step
-- (UseGasCan @1887 / the kit branch @1902, both clear IsHeld first) cannot
-- take the item here; its note was to ask the host (fx.on_note), but in the
-- game no such note ever reached that hook (13.11, 0.11.0: two repair holds
-- ran out with nothing sent; the one refuel ask came from UseGasCan's own
-- hook), and the kit branch has no function to hook. So: the hold's time is
-- up, the game's flag is down, nothing was added here and this player is not
-- outside the box (or it walked off after the hold's time, h.out) -> the
-- same ask (fx.ask, one per hold). The flag still up `late_s` after `till`:
-- the game never ran its delay (its own item check failed, or the hold was
-- set again) - the flag goes, nothing asked. Host: the game's own step takes
-- the item there; a hold record is only let go.
-- Every car's hold on its own (fx.holds: the game's IsHeld and delay are per
-- vehicle). `ran_va`: only that car's hold, whose last step is known to have
-- run (a new press on that car before the tick saw the old hold's end: its
-- flag was down).
function fx.hold_end(t, ran_va)
    if not S then return end
    if ran_va then
        local h = fx.holds[ran_va]
        if h then fx.hold_end_of(h, t, true) end
        return
    end
    local list = {}
    for _, h in pairs(fx.holds) do list[#list + 1] = h end
    if #list == 0 then return end
    table.sort(list, function(x, y) return x.t0 < y.t0 end)
    for _, h in ipairs(list) do
        if fx.holds[h.va] == h then fx.hold_end_of(h, t, false) end
    end
end

function fx.hold_end_of(h, t, ran)
    if not ran and t < h.t0 + (h.dur or 10) + fx.end_s then return end
    if S.role ~= "client" or not h.dur then
        if ran or t >= h.till + fx.late_s then fx.holds[h.va] = nil end
        return
    end
    local v = vehicle_by(h.va, h.vname)
    if not v then
        fx.holds[h.va] = nil
        log.warn("vehicles: %s: the game's hold on %s here ended; the vehicle is gone here: nothing asked", h.kind, h.vname)
        return
    end
    local what = h.kind == "refuel" and "fuel" or "health"
    local now, max
    if h.kind == "refuel" then now, max = fuel_of(v) else now, max = health_of(v) end
    if not ran and ue.prop(v, "IsHeld") == true then
        if t < h.till + fx.late_s then return end
        fx.holds[h.va] = nil
        ue.set_prop(v, "IsHeld", false)
        log.warn("vehicles: %s: the game's hold on %s here still up %.1f s after its time (%s %.0f of %.0f, %s %s): its last step never ran; flag cleared, nothing asked",
            h.kind, h.vname, t - h.t0 - h.dur, what, now or -1, max or -1, fx.item_name(h.kind),
            h.has == true and "found here at the press" or "not checked here at the press")
        return
    end
    fx.holds[h.va] = nil
    if h.sent then
        -- the game's own add here, already sent to the host (fx.report)
        log.info("vehicles: %s: the game's hold on %s here ended with %s %.0f -> %.0f added here and sent: nothing asked",
            h.kind, h.vname, what, h.v0 or -1, now or -1)
        return
    end
    -- (a value raised only by the host - its own refuel / repair meanwhile,
    -- or its answer to an earlier hold: this hold still asks; the host
    -- answers "full" when nothing is left)
    local lp = ue.local_pawn()
    if not h.out and lp and fx.inside(v, lp, h.kind) == false then
        log.info("vehicles: %s: the game's hold on %s here ended with this player outside the %s box: nothing asked",
            h.kind, h.vname, what == "fuel" and "fuel" or "repair")
        return
    end
    fx.ask(v, h.kind, string.format("seen in the tick: the game's hold ended %.1f s ago, its flag down, %s %.0f -> %.0f here%s",
        t - h.t0 - h.dur, what, h.v0 or -1, now or -1, h.out and ", this player walked off after its time" or ""))
end

-- The game's success step of a refuel / repair on this copy (UseGasCan
-- @447..990: fuel, Empty, the fuel widget, the timer bar; the kit branch
-- @2073..2706: engine FX off, engine on, health, the repair widget).
function fx.done_here(v, kind, value)
    local a = addr(v)
    local ap = applied[a]
    if not ap or ap.name ~= ue.short(v) then
        ap = { name = ue.short(v) }
        applied[a] = ap
    end
    if kind == "refuel" then
        local _, _, fc = fuel_of(v)
        if ue.valid(fc) then
            ue.set_prop(fc, "CurrentFuel", value)
            ue.set_prop(fc, "Empty", value <= 0)
        end
        ap.fuel = value
    else
        local _, _, hc = health_of(v)
        apply(function() v:VehicleEngineFX(false) end)
        ue.set_prop(v, "EngineOn?", true)
        if ue.valid(hc) then ue.set_prop(hc, "CurrentHealth", value) end
        ap.health = value
    end
    ap.raised_at = os.clock()
    fx.widgets(v)
end

-- VBOXR|kind|result|x|y|z|class|value|max (host -> this client, fx.reply)
function fx.on_boxr(f)
    if not client_ready() then return end
    local kind, res = f[1], f[2]
    if kind ~= "refuel" and kind ~= "repair" then return end
    local v = vehicle_at(tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), f[6], MATCH_M)
    local value, max = tonumber(f[7]), tonumber(f[8])
    -- (the HUD's one timer bar: kept while a hold of this player still runs,
    -- on this car - pressed again - or on another)
    local running = false
    local t = os.clock()
    for _, h in pairs(fx.holds) do
        if t < h.t0 + (h.dur or 10) then running = true end
    end
    if not running then fx.timer_off() end
    local what = kind == "refuel" and "fuel" or "health"
    if res == "ok" then
        if v and value then fx.done_here(v, kind, value) end
        log.info("vehicles: %s: the host did this player's %s of %s: %s %.0f of %.0f (its %s taken from this player's inventory there)%s",
            kind, kind, v and ue.short(v) or "?", what, value or -1, max or -1, fx.item_name(kind),
            v and "" or "; no such vehicle here")
        return
    end
    local text = (res == "full" and fx.FULL[kind]) or (res == "none" and (kind == "refuel" and fx.NO_GAS or fx.NO_KIT)) or nil
    if text and v then fx.note(text, v) end
    local say = res == "full" and log.info or log.warn
    say("vehicles: %s: the host did not do this player's %s of %s: %s (%s %.0f of %.0f there)%s",
        kind, kind, v and ue.short(v) or "?",
        res == "full" and "nothing to do" or res == "none" and ("no " .. fx.item_name(kind) .. " in this player's inventory there")
            or "no such vehicle next to this player's character there",
        what, value or -1, max or -1, text and ("; the game's note '" .. text .. "'") or "")
end

-- ---------------------------------------------------------------------------
-- The inventory key in a seat (0.7.0: "the passenger cannot open the
-- inventory, the driver can"; the host sat next to a client who drove).
-- ---------------------------------------------------------------------------
-- The game (BP_PlayerCharacter): the key (IMC_General: Tab -> IA_Inventory)
-- runs InpActEvt_IA_Inventory_..._63 -> @136591 -> @108034: ToggleInventory
-- (@107882) unless IsAiming?() (IsADS? and not InMeleeStance?) or
-- UsingBinoculars? or JournalOpen? or BuildingComponent.BuildModeOn? or
-- InMeleeStance?; then the press does nothing and leaves no trace. Neither
-- that branch nor ToggleInventory looks at the vehicle. But in a vehicle an
-- aim can neither start nor end: Event_AimFirearm / Event_StopAimFirearm
-- (@115650 / @115473) and Event_MeleeAim / Event_StopMeleeAim (@133972 /
-- @133744) return while InVehicle?, and the entry's VehicleInteraction(true)
-- ends only a firearm aim (@62942 -> @3769; in melee stance IsAiming? is
-- false, @62980): an aim flag the character has in the seat stays until the
-- exit and eats every press, while the interact key (the exit, @108405 ->
-- @108525) still works.
-- The 0.7.0 logs cannot tell what met the host's presses (nothing logs the
-- host's own inventory; sdc_uiinput is client only; sdc_ctx never redirected
-- a BP_JigComponent_C call). So, for this machine's player in a seat:
--   * IA_Inventory (post): one line per press - did the game's branch run
--     ToggleInventory, the window, its five conditions, InVehicle?, Vehicle,
--     the seat, the montage. A press eaten only by an aim flag: the flag goes
--     (IsADS? through the game's own Svr_SetADS, @115946 -> @10217) and the
--     window toggles the game's way (ToggleInventory, as @107882).
--   * ToggleInventory (post) and the game's callers that close the window
--     (the key again, IA_Interact @108341, OnInteractActorOverDistance from a
--     CheckDistanceFromActor timer, AddJigWidgetToContent): a window that
--     closes within QUICK_CLOSE_S of opening in a seat gets a line naming
--     what closed it (0.7.0 client as a passenger: open 0.44 s / 0.31 s at
--     16:33:10 / 16:37:00; as the driver 34 s / 10 s at 16:52). The three
--     callers' hooks only name the cause in that line: registered with
--     config debug only.
--   * Tab itself (read on the game thread each frame while seated): a press
--     after which the IA_Inventory event never ran (the key did not reach
--     the character) gets a line; in the passenger seat, with Tab mapped to
--     IA_Inventory, no modifier, no window / menu / console / cursor up and
--     nothing the game would refuse, the window opens the game's way
--     (ToggleInventory).
local ik = {
    IA = CHAR_PATH .. ":InpActEvt_IA_Inventory_K2Node_EnhancedInputActionEvent_63",
    INTERACT = CHAR_PATH .. ":InpActEvt_IA_Interact_K2Node_EnhancedInputActionEvent_61",
    DISTANCE = CHAR_PATH .. ":OnInteractActorOverDistance",
    LOOT = CHAR_PATH .. ":AddJigWidgetToContent",
    TOGGLE = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:ToggleInventory",
    IA_ASSET = "/Game/Input/InventoryPlayerActions/IA_Inventory.IA_Inventory",
    MODS = { "LeftAlt", "RightAlt", "LeftShift", "RightShift", "LeftControl", "RightControl" },
    SAME_CALL_S = 0.05,     -- a caller's post-hook follows ToggleInventory's within one call
    QUICK_CLOSE_S = 1.5,
    CHECK_S = 0.4,          -- Tab: the IA_Inventory event must have run by then
    CONFIRM_S = 0.1,        -- ... and still not one tick later (a hitch: same frame)
    MAP_EVERY_S = 10,
    key_at = nil,           -- last IA_Inventory event of this machine's player
    seen = false,           -- the IA_Inventory hook ran at least once (it works)
    toggle_at = nil, opened_at = nil,
    close = nil,            -- a quick close waiting for its caller's post-hook
    tab = nil,              -- { at, yes }: Tab is mapped to IA_Inventory here
    poll = false,           -- the frame's Tab read is on (ik.maybe_seated, set by the 0.5 s tick)
}

function ik.live()
    return enabled() and S ~= nil and (S.role == "host" or S.role == "client")
end

-- This machine's player's vehicle, the vehicle and the seat name, or nil.
function ik.seat_of(ch)
    local va = ch and parent_vehicle(ch)
    local v = va and cur.by[va]
    if not (v and ue.valid(v)) then return nil, nil, nil end
    local seat
    if S and S.role == "host" then
        seat = vs[va] and vs[va].host_seat or "?"
    else
        seat = (local_seat and local_seat.vaddr == va) and local_seat.seat or "?"
    end
    return va, v, seat
end

function ik.flags(ch)
    local bc = ue.prop(ch, "BuildingComponent")
    local f = {
        ads = ue.prop(ch, "IsADS?") == true,
        melee = ue.prop(ch, "InMeleeStance?") == true,
        binos = ue.prop(ch, "UsingBinoculars?") == true,
        journal = ue.prop(ch, "JournalOpen?") == true,
        build = ue.valid(bc) and ue.prop(bc, "BuildModeOn?") == true,
    }
    f.aiming = f.ads and not f.melee
    return f
end

-- The conditions of @108034 that are set, in the game's order.
function ik.blockers(f)
    local b = {}
    if f.aiming then b[#b + 1] = "IsAiming?()" end
    if f.binos then b[#b + 1] = "UsingBinoculars?" end
    if f.journal then b[#b + 1] = "JournalOpen?" end
    if f.build then b[#b + 1] = "BuildModeOn?" end
    if f.melee then b[#b + 1] = "InMeleeStance?" end
    return b
end

-- Only an aim (which the game cannot end in a vehicle) stops the key.
function ik.aim_only(f)
    return (f.aiming or f.melee) and not (f.binos or f.journal or f.build)
end

function ik.state(ch, f)
    local dc = ue.prop(ch, "VehicleDrivingComponent")
    local hv = ue.valid(dc) and ue.prop(dc, "Vehicle") or nil
    local m = ue.try(function() return ch:GetCurrentMontage() end)
    return string.format("IsADS?=%s InMeleeStance?=%s UsingBinoculars?=%s JournalOpen?=%s BuildModeOn?=%s InVehicle?=%s Vehicle=%s montage=%s",
        tostring(f.ads), tostring(f.melee), tostring(f.binos), tostring(f.journal), tostring(f.build),
        tostring(ue.prop(ch, "InVehicle?") == true), ue.valid(hv) and ue.short(hv) or "None",
        ue.valid(m) and ue.short(m) or "none")
end

-- The character's Jig component and whether its inventory window is open.
function ik.window(ch)
    local comp = ue.prop(ch, "BP_JigMultiplayer")
    if not ue.valid(comp) then return nil, false end
    local w = ue.prop(comp, "InventoryWidgetRef")
    return comp, ue.valid(w) and ue.try(function() return w:IsInViewport() end) == true
end

-- The aim flags off. IsADS? through the game's own server setter (@115946 ->
-- @10217: the flag and its replication; on a client the RPC reaches the
-- host). InMeleeStance? has none (the owner sets it, @1424 / @1700): set here,
-- and on the host marked for replication as the game's server does
-- (sdc_pawnstate does the same for a client's copy).
function ik.clear_aim(ch, f)
    local done = {}
    pcall(function() ch:FlushNetDormancy() end)
    if f.melee and ue.set_prop(ch, "InMeleeStance?", false) then
        done[#done + 1] = "InMeleeStance?"
        if S and S.role == "host" then
            local push = ue.find_object("/Script/Engine.Default__NetPushModelHelpers")
            if push then pcall(function() push:MarkPropertyDirtyFromRepIndex(ch, 27, FName("InMeleeStance?")) end) end
        end
    end
    if f.ads then
        ue.set_prop(ch, "IsADS?", false)
        pcall(function() ch:Svr_SetADS(false) end)
        done[#done + 1] = "IsADS?"
    end
    return #done > 0 and table.concat(done, " and ") or "nothing"
end

-- BP_JigComponent.ToggleInventory (post), this machine's player only.
function ik.on_toggle(comp_p)
    if not ik.live() then return end
    local comp = get(comp_p)
    if not ue.valid(comp) then return end
    local owner = ue.try(function() return comp:GetOwner() end)
    if not (ue.valid(owner) and locally_controlled(owner)) then return end
    local t = os.clock()
    ik.toggle_at = t
    local _, open = ik.window(owner)
    if open then
        ik.opened_at, ik.close = t, nil
        return
    end
    local since = ik.opened_at
    ik.opened_at = nil
    if not since or t - since > ik.QUICK_CLOSE_S then return end
    local va, v, seat = ik.seat_of(owner)
    if not va then return end
    ik.close = { at = t, open_for = t - since, who = char_label(owner), seat = seat, vname = ue.short(v),
                 cause = applying > 0 and "this module" or nil }
    ue.delay("veh-invclose", 100, ik.report_close)
end

function ik.report_close()
    local c = ik.close
    ik.close = nil
    if not c then return end
    local fn = c.key and log.info or log.warn
    fn("vehicles: inventory: the window of %s (%s seat of %s) closed %.2f s after it opened, by %s",
        c.who, tostring(c.seat), c.vname, c.open_for,
        c.cause or (ik.callers_on and "no caller seen (not the inventory or interact key, no distance check, no loot / trade window)"
            or "a caller not watched (not the inventory key; the interact key / distance check / loot window hooks are on with config debug only)"))
end

-- Post-hooks of the game's functions that call ToggleInventory: the caller of
-- a quick close (its post-hook runs right after ToggleInventory's).
function ik.caller(what)
    return function(self_p, a1)
        local c = ik.close
        if not c or c.cause or os.clock() - c.at > ik.SAME_CALL_S then return end
        local ch = hook_self(self_p)
        if not (ch and locally_controlled(ch)) then return end
        if what == "distance" then
            local by = get(a1)
            c.cause = string.format("the 3 m distance check of %s (CheckDistanceFromActor -> OnInteractActorOverDistance: the window of a container / body / vehicle storage closes once its player is 3 m from where it opened it - in a moving car at once)",
                ue.valid(by) and ue.short(by) or "?")
        elseif what == "interact" then
            c.cause = "the interact key (IA_Interact @108341: the game closes an open inventory first)"
        else
            c.cause = "a loot / trade window (AddJigWidgetToContent toggles the inventory first)"
        end
    end
end

-- InpActEvt_IA_Inventory_K2Node_EnhancedInputActionEvent_63 (post): the
-- game's branch has run (ToggleInventory inside it, or nothing).
function ik.on_key(self_p)
    if applying > 0 or not ik.live() then return end
    local ch = hook_self(self_p)
    if not (ch and locally_controlled(ch)) then return end
    local t = os.clock()
    ik.key_at, ik.seen = t, true
    local toggled = ik.toggle_at ~= nil and t - ik.toggle_at <= ik.SAME_CALL_S
    local c = ik.close
    if toggled and c and not c.cause and t - c.at <= ik.SAME_CALL_S then
        c.cause, c.key = "the inventory key again", true
    end
    local va, v, seat = ik.seat_of(ch)
    if not va and ue.prop(ch, "InVehicle?") ~= true then return end
    M.stats.inv_keys = M.stats.inv_keys + 1
    local who = char_label(ch)
    local where = va and string.format("the %s seat of %s", tostring(seat), ue.short(v)) or "no seat (InVehicle? set)"
    local f = ik.flags(ch)
    local comp, open = ik.window(ch)
    if toggled then
        log.info("vehicles: inventory key: %s in %s: the game's branch ran ToggleInventory -> window %s (%s)",
            who, where, open and "open" or "closed", ik.state(ch, f))
        return
    end
    local b = ik.blockers(f)
    if #b == 0 then
        log.warn("vehicles: inventory key: %s in %s: the game's branch (@108034) ran no ToggleInventory although none of its conditions is set (window %s, Jig component %s; %s)",
            who, where, open and "open" or "closed", comp and "ok" or "MISSING", ik.state(ch, f))
        return
    end
    if not (va and comp and ik.aim_only(f)) then
        log.warn("vehicles: inventory key: %s in %s: the game ate the key (@108034: %s) - left as the game has it (%s)",
            who, where, table.concat(b, ", "), ik.state(ch, f))
        return
    end
    local cleared = ik.clear_aim(ch, f)
    apply(function() comp:ToggleInventory() end)
    local _, now_open = ik.window(ch)
    M.stats.inv_fixed = M.stats.inv_fixed + 1
    log.warn("vehicles: inventory key: %s in %s: the game ate the key (@108034: %s), an aim it cannot end in a vehicle (its stop steps return while InVehicle?, @115473 / @133744): %s cleared, the window toggled the game's way (ToggleInventory, as @107882) -> window %s (%s)",
        who, where, table.concat(b, ", "), cleared, now_open and "open" or "closed", ik.state(ch, ik.flags(ch)))
end

-- Tab mapped to IA_Inventory for this player (the settings can remap keys):
-- true / false / nil (cannot tell).
function ik.tab_mapped()
    local t = os.clock()
    if ik.tab and t - ik.tab.at < ik.MAP_EVERY_S then return ik.tab.yes end
    local yes = nil
    local ia = ue.find_object(ik.IA_ASSET)
    if ia then
        for _, ss in ipairs(ue.find_all("EnhancedInputLocalPlayerSubsystem")) do
            local keys = ue.valid(ss) and ue.try(function() return ss:QueryKeysMappedToAction(ia) end) or nil
            if keys then
                local found = false
                local ok = pcall(function()
                    keys:ForEach(function(_, e)
                        local k = e:get()
                        if ue.str(k and k.KeyName) == "Tab" then found = true end
                    end)
                end)
                if ok then yes = found end
                break
            end
        end
    end
    ik.tab = { at = t, yes = yes }
    return yes
end

function ik.modifier(pc)
    for _, k in ipairs(ik.MODS) do
        if ue.try(function() return pc:IsInputKeyDown({ KeyName = FName(k) }) end) == true then return k end
    end
    return nil
end

function ik.console_open()
    for _, c in ipairs(ue.find_all("Console")) do
        local s = ue.str(ue.prop(c, "ConsoleState"))
        if s ~= "" and s ~= "None" then return true end
    end
    return false
end

-- What else holds the screen: a game window (sdc_uiinput's list, the
-- inventory included), the co-op panel, the console.
function ik.screen_busy()
    local ui = package.loaded["sdc_uiinput"]
    local open = type(ui) == "table" and type(ui.game_ui_open) == "function" and ue.try(ui.game_ui_open) or nil
    if open then return open end
    local panel = package.loaded["sdc_ui"]
    if type(panel) == "table" and panel.open == true then return "the co-op panel" end
    if ik.console_open() then return "the console" end
    return nil
end

-- Tab pressed while this machine's player sits (ik.poll_tab, game thread).
function ik.on_tab()
    if not ik.live() then return end
    local lp = ue.local_pawn()
    local va = lp and ik.seat_of(lp)
    if not va then return end
    local t = os.clock()
    -- the game may have run the event before this callback: it counts too
    if ik.key_at and t - ik.key_at <= ik.CHECK_S then return end
    local pc = ue.local_pc()
    local press = { at = t, va = va, mod = pc and ik.modifier(pc) or nil }
    ue.delay("veh-invtab", math.floor(ik.CHECK_S * 1000), function() ik.check_tab(press, false) end)
end

function ik.check_tab(press, confirm)
    if ik.key_at and ik.key_at >= press.at - ik.CHECK_S then return end
    local lp = ue.local_pawn()
    local va, v, seat = ik.seat_of(lp)
    if not va or va ~= press.va then return end
    if not confirm then
        ue.delay("veh-invtab2", math.floor(ik.CONFIRM_S * 1000), function() ik.check_tab(press, true) end)
        return
    end
    M.stats.inv_lost = M.stats.inv_lost + 1
    local pc = ue.local_pc()
    local comp, open = ik.window(lp)
    local f = ik.flags(lp)
    local b = ik.blockers(f)
    local busy = ik.screen_busy()
    local cursor = pc ~= nil and ue.prop(pc, "bShowMouseCursor") == true
    local mapped = ik.tab_mapped()
    local why
    if seat ~= "passenger" then why = "not the passenger seat"
    elseif not ik.seen then why = "the IA_Inventory hook has not run once yet"
    elseif mapped ~= true then why = mapped == false and "Tab is not the inventory key here" or "the inventory key mapping is unknown"
    elseif press.mod then why = press.mod .. " was held"
    elseif open or busy then why = (busy or "the inventory window") .. " is open"
    elseif cursor then why = "the mouse cursor is on (some UI holds the input)"
    elseif #b > 0 and not ik.aim_only(f) then why = "the game would refuse it (" .. table.concat(b, ", ") .. ")"
    elseif not comp then why = "no Jig component"
    end
    local did = "left as it is (" .. tostring(why) .. ")"
    if not why then
        local cleared = (#b > 0) and ik.clear_aim(lp, f) or nil
        apply(function() comp:ToggleInventory() end)
        local _, now_open = ik.window(lp)
        M.stats.inv_fixed = M.stats.inv_fixed + 1
        did = string.format("%sthe window opened the game's way (ToggleInventory, as @107882) -> window %s",
            cleared and (cleared .. " cleared, ") or "", now_open and "open" or "closed")
    end
    log.warn("vehicles: inventory key: Tab pressed while %s sits in the %s seat of %s, but the game's IA_Inventory event did not run within %.1f s (the key never reached the character's input; Tab mapped to the inventory=%s, cursor=%s, screen=%s, %s): %s",
        char_label(lp), tostring(seat), ue.short(v), ik.CHECK_S + ik.CONFIRM_S, tostring(mapped), tostring(cursor),
        busy or "free", ik.state(lp, f), did)
end

-- Tab is read on the game thread, every frame while this machine's player may
-- sit. No UE4SS key bind: UE4SS runs those on its own thread, while the game
-- thread runs native hooks that take no lock. Lua on both threads at once
-- broke the shared Lua registry. That was the 0.7.1 host crashes (lua_rawgeti /
-- luaH_getint while wrapping a hook param); they began with this Tab bind.
-- Gate from Lua state only (no engine call), read by the 0.5 s tick into
-- ik.poll (a seat taken shows within 0.5 s); a stale seat only costs one key
-- read a frame: on_tab checks the real seat.
function ik.maybe_seated()
    if not ik.live() then return false end
    if S.role == "host" then
        for _, st in pairs(vs) do
            if st.host_seat then return true end
        end
        return false
    end
    return local_seat ~= nil
end

-- The 0.5 s tick: the frame's Tab read on or off.
function ik.set_poll(on)
    if ik.poll and not on then ik.tab_down = false end
    ik.poll = on == true
end

function ik.poll_tab()
    local pc = ue.local_pc()
    if not pc then return end
    if not ik.TAB_KEY then ik.TAB_KEY = { KeyName = FName("Tab") } end
    local down = ue.try(function() return pc:IsInputKeyDown(ik.TAB_KEY) end) == true
    if down and not ik.tab_down then ik.on_tab() end
    ik.tab_down = down
    -- the seat key and a parked car's hold (below)
    SEATK.frame(pc)
end

-- ---------------------------------------------------------------------------
-- The seat key (config vehicle_seat_key): read on the game thread
-- ---------------------------------------------------------------------------
-- As Tab above: no UE4SS key bind (its thread), the key's down state read in
-- main.lua's frame loop - only while this machine's player sits as a
-- passenger (ik.seat_poll, set by the 0.5 s tick: one key read a frame), a
-- press = its down edge. G by default: no action of the game's IMC_General
-- (one context on foot and in a vehicle; F interact / exit, WASD, Space,
-- Shift, Tab, H horn, K flip, R radio, L, J, M, Y, digits are the game's;
-- Enter the chat, F7 / F8 the mod's). A press while something holds the
-- input (the chat line, a game window, the co-op panel, the console, the
-- mouse cursor) does nothing.
SEATK.GAME_KEYS = " # A B Backslash C D Down E Eight Equals Escape F F5 Five Four H Hyphen J K L Left LeftAlt LeftControl"
    .. " LeftMouseButton LeftShift M MiddleMouseButton N Nine O One Q R Right RightMouseButton S Semicolon Seven"
    .. " Six SpaceBar T Tab Three Two Up V W X Y Z "

-- The mod's own keys (their defaults as their modules read them): a seat
-- key on one of them is off - one press would do both (the frame reads the
-- seat key before the chat's, so with chat_key = G a passenger's G moved it
-- and opened the chat). The setting it clashes with, or nil.
SEATK.MOD_KEYS = { { "chat_key", "Enter" }, { "menu_key", "F7" }, { "players_hud_key", "F8" } }
function SEATK.clash(name)
    for _, k in ipairs(SEATK.MOD_KEYS) do
        local other = (tostring(cfg.get(k[1]) or ""):gsub("%s+", ""))
        if other == "" then other = k[2] end
        if other:lower() == name:lower() then return k[1] end
    end
    return nil
end

-- The seat key: its FKey and name, or nil (config empty / "None": no key;
-- one of the mod's own keys: off, a warning in the log).
function SEATK.key()
    local name = (tostring(cfg.get("vehicle_seat_key") or ""):gsub("%s+", ""))
    local clash = name ~= "" and SEATK.clash(name)
    if clash and SEATK.clash_seen ~= name .. "|" .. clash then
        SEATK.clash_seen = name .. "|" .. clash
        log.warn("vehicles: seat key: vehicle_seat_key = %s is also %s (the mod's own key): the seat key is off - set another one (G, U, P, I...)",
            name, clash)
    end
    if name == "" or name:lower() == "none" or clash then
        SEATK.key_fk, SEATK.key_name = nil, nil
        return nil, nil
    end
    if name ~= SEATK.key_name then
        -- (a key already down is no press)
        SEATK.key_name, SEATK.key_fk, SEATK.key_was = name, { KeyName = FName(name) }, true
        log.info("vehicles: seat key: %s%s", name, SEATK.GAME_KEYS:find(" " .. name .. " ", 1, true)
            and " - also a key of the game (IMC_General): its action runs too" or "")
    end
    return SEATK.key_fk, name
end

-- The 0.5 s tick: read the seat key each frame (this machine's player is a
-- passenger) and hold a parked car (the host sits in it as a passenger and
-- nobody drives: SEATK.hold_frame).
function SEATK.poll_flags()
    local pass, hold = false, nil
    if ik.live() then
        if S.role == "host" then
            local hp = ue.local_pawn()
            local ha = hp and parent_vehicle(hp)
            local st = ha and vs[ha]
            if st and st.host_seat == "passenger" then
                pass = true
                if not st.driver_key then hold = ha end
            end
        else
            pass = local_seat ~= nil and local_seat.seat == "passenger"
        end
    end
    local want = pass and SEATK.key() ~= nil
    if want and not ik.seat_poll then SEATK.key_was = true end
    ik.seat_poll = want
    -- (a car somebody tows: not held, SEATK.tower_of)
    local towed = hold
    local tower = hold and SEATK.tower_of(hold)
    if tower then
        if SEATK.tow_seen ~= towed then
            log.info("vehicles: seat: %s, where the host sits as a passenger, is towed by %s: not held parked while it is",
                vs[towed] and vs[towed].name or "?", ue.short(tower))
        end
        hold = nil
    end
    SEATK.tow_seen = tower and towed or nil
    SEATK.hold_va = hold
end

-- The frame (ik.poll_tab, game thread): the seat key's press, the hold.
function SEATK.frame(pc)
    if ik.seat_poll and SEATK.key_fk then
        local down = ue.try(function() return pc:IsInputKeyDown(SEATK.key_fk) end) == true
        local was = SEATK.key_was
        SEATK.key_was = down
        if down and not was then SEATK.on_key() end
    end
    if SEATK.hold_va then SEATK.hold_frame() end
end

-- A press of the seat key (game thread).
function SEATK.on_key()
    if not ik.live() then return end
    local who = S.role == "host" and "the host" or "this player"
    local chat = package.loaded["sdc_chat"]
    local busy = type(chat) == "table" and type(chat.is_open) == "function" and chat.is_open() == true and "the chat line" or nil
    local pc = ue.local_pc()
    busy = busy or ik.screen_busy() or (pc and ue.prop(pc, "bShowMouseCursor") == true and "the mouse cursor (a window holds the input)")
    if busy then
        log.info("vehicles: seat key: %s pressed it while %s is open: nothing done", who, tostring(busy))
        return
    end
    local res = S.role == "host" and SEATK.host_key() or SEATK.client_key()
    log.info("vehicles: seat key: %s: %s", who, tostring(res))
end

-- The host sits as a passenger in a car nobody drives (SEATK.hold_va: set
-- by SEATK.wheel_free and the tick): its own driving keys still reach its
-- copy - its driving component points at the car, and no replicated inputs
-- are used once the driver left (set_requires false: the handbrake must
-- hold). Every frame: the handbrake on (the game's throttle step then gives
-- 0 itself, VehicleDrivingComponent @53..302), throttle and brake (its
-- reverse) 0. Off once somebody drives, the host moves to the wheel or
-- gets out, and while another vehicle tows it (SEATK.tower_of).
function SEATK.hold_frame()
    local a = SEATK.hold_va
    local st = vs[a]
    local v = cur.by[a]
    if not (st and st.host_seat == "passenger" and not st.driver_key and v and ue.valid(v)) then
        SEATK.hold_va = nil
        return
    end
    local m = mcomp(v)
    if not m then return end
    if ue.try(function() return m:GetHandbrakeInput() end) ~= true then pcall(function() m:SetHandbrakeInput(true) end) end
    pcall(function() m:SetThrottleInput(0) end)
    pcall(function() m:SetBrakeInput(0) end)
end

-- The car vehicle t tows (its address), or nil. The game's hitch
-- (AddTowingComp, BP_VehicleMaster @197..538) sets t's TowingVehicle? and
-- adds the PhysicsConstraintComp to the towed car (its owner), then, a tick
-- later, releases that car's handbrake and gives it throttle 0.01
-- (@1168 / @1252); the detach (@28529..28916) puts them back.
function SEATK.towed_by(t)
    if not (t and ue.valid(t)) or ue.prop(t, "TowingVehicle?") ~= true then return nil end
    local pcc = ue.prop(t, "PhysicsConstraintComp")
    local o = ue.valid(pcc) and ue.try(function() return pcc:GetOwner() end) or nil
    return o and ue.valid(o) and addr(o) or nil
end

-- The vehicle towing car a, or nil (the 0.5 s tick, only for a car the host
-- sits in as a passenger with nobody at the wheel: SEATK.poll_flags). Held
-- parked there, the hitched car was dragged with its handbrake on.
function SEATK.tower_of(a)
    for _, t in ipairs(cur.list) do
        if SEATK.towed_by(t) == a then return t end
    end
    return nil
end


-- main.lua's frame loop (game thread). Nobody of this machine seated (the
-- 0.5 s tick's flag): back at once, no pcall, no engine call (0.7.3 [PERF]
-- f:vehicles 0.6-1.7 ms/s with nobody in a vehicle).
function M.frame_tick()
    if not ik.poll then return end
    local ok, err = pcall(ik.poll_tab)
    if not ok then log.err_throttled("veh.tab", "vehicles: Tab poll: %s", tostring(err)) end
end

-- For main.lua's frame loop: frame_tick has work this frame (a plain field
-- read; the caller may skip its timing wrapper when false).
function M.frame_wanted() return ik.poll == true end

-- debug = true: the hook only writes log lines (the box entry of this
-- player, the cause of a quick inventory close): registered with config
-- debug only (each Blueprint hook costs on every call of its function).
local HOOKS = {
    { path = SEATK.helper .. ":TryInteract", cb = on_try_interact_post },
    { path = VEH_PATH .. ":OnExecuteInteract", cb = fx.on_interact },
    { path = VEH_PATH .. ":UseGasCan", cb = fx.on_gascan },
    { path = fx.GFL_NOTE, cb = fx.on_note },
    { path = VEH_PATH .. ":OnBeginFuelInteract", cb = fx.box("refuel", false), debug = true },
    { path = VEH_PATH .. ":OnEndFuelInteract", cb = fx.box("refuel", true) },
    { path = VEH_PATH .. ":OnBeginRepairInteract", cb = fx.box("repair", false), debug = true },
    { path = VEH_PATH .. ":OnEndRepairInteract", cb = fx.box("repair", true) },
    { path = VEH_PATH .. ":Interact_GetInVehicle", cb = on_enter_post },
    { path = VEH_PATH .. ":ExitVehicle", cb = on_exit_post },
    { path = CHAR_PATH .. ":VehicleInteraction", cb = on_vi_post },
    { path = VEH_PATH .. ":TurnOnOffLights", cb = on_lights_post },
    { path = VEH_PATH .. ":Horn", cb = on_horn_post },
    { path = VEH_PATH .. ":Event_FlipVehicle", cb = on_flip_post },
    { path = VEH_PATH .. ":Interact_PushVehicle", cb = on_push_post },
    { path = VEH_PATH .. ":AddTowingComp", cb = on_tow_post },
    { path = VEH_PATH .. ":RemoveTowingComp", cb = on_tow_post },
    { path = TRADER_PATH .. ":SpawnVehicle", cb = on_buy_post },
    { path = ik.TOGGLE, cb = ik.on_toggle },
    { path = ik.IA, cb = ik.on_key },
    { path = ik.INTERACT, cb = ik.caller("interact"), debug = true, caller = true },
    { path = ik.DISTANCE, cb = ik.caller("distance"), debug = true, caller = true },
    { path = ik.LOOT, cb = ik.caller("loot"), debug = true, caller = true },
}
-- (fields, not locals: this chunk is at Lua's 200-locals limit)
HOOKS.hooked = {}    -- [path] = true once registered
HOOKS.tries = {}     -- [path] = registrations tried
-- A registration can fail while the class loads (UFunction::Func 0x0); it is
-- tried again each tick (0.5 s) up to MAX_TRIES. Up to 0.7.3 a failed one
-- counted as hooked and was never tried again: logs had "hook SpawnVehicle
-- (post) FAILED" and nothing later - a client paid for a car and got none.
HOOKS.MAX_TRIES = 120

local function install_hooks()
    buy.hook_spawn(HOOKS.MAX_TRIES)
    for _, h in ipairs(HOOKS) do
        local n = HOOKS.tries[h.path] or 0
        if not HOOKS.hooked[h.path] and n < HOOKS.MAX_TRIES and (log.debug_enabled or not h.debug)
            and ue.find_object(h.path) then
            local name = h.path:match(":([%w_]+)$")
            local ok, err = pcall(RegisterHook, h.path, safe(name, h.cb))
            n = n + 1
            HOOKS.tries[h.path] = n
            if ok then
                HOOKS.hooked[h.path] = true
                if h.caller then ik.callers_on = true end
                log.info("vehicles: hook %s (post) ok%s%s", name, h.debug and " (debug)" or "",
                    n > 1 and string.format(" (try %d)", n) or "")
            elseif n == 1 then
                log.warn("vehicles: hook %s (post) FAILED %s; tried again each tick (up to %d tries)", name, tostring(err),
                    HOOKS.MAX_TRIES)
            elseif n >= HOOKS.MAX_TRIES then
                log.err("vehicles: hook %s (post) FAILED %d times, given up: %s", name, n, tostring(err))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host tick
-- ---------------------------------------------------------------------------

local function occupancy(list)
    local occ = {}
    for _, ch in ipairs(list) do
        local a = parent_vehicle(ch)
        if a then
            occ[a] = occ[a] or {}
            table.insert(occ[a], ch)
        end
    end
    return occ
end

-- VSTATE, per client: only the vehicles within RANGE of its character, all
-- of them in one message a tick (VSTATE|*|<N fields>|<N fields>|..., up to
-- PER_MSG records). Up to 0.7.3 every vehicle went to every client in a
-- message of its own; one the client did not have (out of its network range)
-- made it rescan its vehicle list each time (1.6/s).
-- Sends that are not a change (the 10 s refresh, a vehicle's first state)
-- are spread over the 0.5 s ticks: all vehicles at once held the host for
-- 10-20 ms every 10 s (130 ms on the first pass after a join). A change
-- (colour, fuel, health, lights, engine, driver) still goes out at once to
-- the clients in range. st.got[client] = the state that client has: one
-- that comes into range gets the latest at the vehicle's next read (active:
-- every tick; idle: its turn, ~every 3 s).
local vsync = {
    REFRESH = 3, FIRST = 8, IDLE = 4,   -- per tick: refreshes, first states, idle vehicles read
    refresh_left = 0, first_left = 0, idle_turn = 0,
    RANGE = 20000,                      -- cm (~200 m)
    N = 12,                             -- fields per record
    PER_MSG = 16,                       -- records per message
    rcpt = {},                          -- this tick's clients: { pc, k, loc (nil: unknown -> every vehicle) }
    out = {},                           -- [client key] = { pc =, fields... } this tick
    rkey = "",                          -- the clients of the last tick (st.got is cleared when they change)
    -- VOCC (sdc_vehseats): a vehicle's seats 2+ while a seat 3+ is taken,
    -- next to each of its VSTATE records (and once empty after, per client:
    -- st.occ_got[client] = the list that client has)
    NO = 5,                             -- fields per VOCC record (x, y, z, class, list)
    occ_out = {},                       -- [client key] = { pc =, fields... } this tick
}

-- Start of a host tick: the clients and where their characters are.
function vsync.begin()
    local list, keys = {}, {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        local k = addr(pc)
        if k then
            local p = ue.pawn_of(pc)
            list[#list + 1] = { pc = pc, k = k, loc = p and ue.location(p) or nil }
            keys[#keys + 1] = tostring(k)
        end
    end
    vsync.rcpt, vsync.out, vsync.occ_out = list, {}, {}
    local rk = table.concat(keys, ",")
    if rk ~= vsync.rkey then
        vsync.rkey = rk
        for _, st in pairs(vs) do st.got, st.occ_got = nil, nil end
    end
    vsync.refresh_left, vsync.first_left = vsync.REFRESH, vsync.FIRST
end

-- End of a host tick: each client's records, packed.
function vsync.flush()
    local per = vsync.N * vsync.PER_MSG
    for _, o in pairs(vsync.out) do
        local n = #o
        for i = 1, n, per do
            net.send_to(o.pc, "VSTATE", "*", table.unpack(o, i, math.min(n, i + per - 1)))
        end
    end
    -- after the VSTATE records (the client takes a VOCC list as fresh only
    -- when it follows that vehicle's latest VSTATE)
    per = vsync.NO * vsync.PER_MSG
    for _, o in pairs(vsync.occ_out) do
        local n = #o
        for i = 1, n, per do
            net.send_to(o.pc, "VOCC", "*", table.unpack(o, i, math.min(n, i + per - 1)))
        end
    end
    vsync.out, vsync.occ_out = {}, {}
end

-- VOCC's list for a vehicle: its seats 2+ ("idx:id:side:x:y:z:yaw:pose;..."),
-- only while somebody sits in a seat 3+ ("" otherwise: VSTATE's field 12
-- says it all, as before). Each seat's own geometry (a copy taken when the
-- player sat down: a row changed or removed later does not break it).
function SEATK.occ_text(a, st)
    local occ = M.vseats.occupants(st)
    if #occ == 0 or occ[#occ].idx < 3 then return "" end
    local parts = {}
    for _, o in ipairs(occ) do
        local id, geo
        if o.who == "host" then
            id = host_seated(a) and pawn_id(ue.local_pawn()) or nil
            geo = st.host_geo or M.vseats.geo(st.cls, o.idx)
        else
            local pc = remote_pc_of(o.who)
            id = pawn_id(pc and ue.pawn_of(pc))
            local seat = seats[o.who]
            geo = (seat and seat.geo) or M.vseats.geo(st.cls, o.idx)
        end
        if id and geo then parts[#parts + 1] = M.vseats.occ_entry(o.idx, id, geo) end
    end
    return table.concat(parts, ";")
end

-- PlayerIds of the driver and the passenger in seat 2 ("" = free) for
-- VSTATE (seats 3+: VOCC).
local function seat_ids(a, st)
    local did, pid = "", ""
    local hp = ue.local_pawn()
    local host_here = hp ~= nil and host_seated(a)
    if st.driver_key then
        local pc = remote_pc_of(st.driver_key)
        did = tostring(pawn_id(pc and ue.pawn_of(pc)) or "")
    elseif host_here and st.host_seat ~= "passenger" then
        did = tostring(pawn_id(hp) or "")
    end
    local p2 = st.pax and st.pax[2]
    if p2 then
        local pc = remote_pc_of(p2)
        pid = tostring(pawn_id(pc and ue.pawn_of(pc)) or "")
    elseif host_here and M.vseats.host_idx(st) == 2 then
        pid = tostring(pawn_id(hp) or "")
    end
    return did, pid
end

local function broadcast_state(v, a, st, t)
    local fuel, maxf = fuel_of(v)
    local hp = health_of(v)
    local color = num(ue.prop(v, "VehicleColor")) or -1
    local lights = ue.prop(v, "LightsOn?") == true
    local eng = ue.prop(v, "EngineOn?") ~= false
    local drv = has_driver(a, st)
    local did, pid = seat_ids(a, st)
    local occ = SEATK.occ_text(a, st)
    local pct = (fuel and maxf and maxf > 0) and math.floor(fuel / maxf * 100) or -1
    local sig = string.format("%d|%d|%d|%s|%s|%s|%s|%s|%s", color, pct, math.floor(hp or -1), tostring(lights), tostring(eng),
        tostring(drv), did, pid, occ)
    local due = st.dirty == true   -- (a change the hooks reported goes now)
    if not due then
        if st.sig == nil then
            if vsync.first_left > 0 then
                vsync.first_left = vsync.first_left - 1
                due = true
            end
        elseif sig ~= st.sig then
            due = true
        elseif t - (st.sent_at or -100) >= STATE_EVERY_S and vsync.refresh_left > 0 then
            vsync.refresh_left = vsync.refresh_left - 1
            due = true
        end
    end
    local l = ue.location(v)
    if not l then return end
    if due then st.sig, st.sent_at, st.dirty = sig, t, false end
    if st.sig == nil then return end   -- (its first state waits for the budget)
    st.got = st.got or {}
    st.occ_got = st.occ_got or {}
    local rec = nil
    for _, r in ipairs(vsync.rcpt) do
        if (due or st.got[r.k] ~= st.sig) and (not r.loc or d2(r.loc, l) <= vsync.RANGE * vsync.RANGE) then
            rec = rec or { f0(l.X), f0(l.Y), f0(l.Z), st.cls or ue.class_name(v), tostring(color),
                string.format("%.1f", fuel or 0), string.format("%.1f", hp or 0), lights and "1" or "0", eng and "1" or "0",
                drv and "1" or "0", did, pid }
            st.got[r.k] = st.sig
            local o = vsync.out[r.k]
            if not o then
                o = { pc = r.pc }
                vsync.out[r.k] = o
            end
            table.move(rec, 1, vsync.N, #o + 1, o)
            M.stats.states_sent = M.stats.states_sent + 1
            -- the seats 3+ with it; an emptied list once to whoever had one
            -- (also a client that was out of range when the seats emptied)
            if occ ~= "" or (st.occ_got[r.k] or "") ~= "" then
                local oo = vsync.occ_out[r.k]
                if not oo then
                    oo = { pc = r.pc }
                    vsync.occ_out[r.k] = oo
                end
                table.move({ rec[1], rec[2], rec[3], rec[4], occ }, 1, vsync.NO, #oo + 1, oo)
                st.occ_got[r.k] = occ
            end
        end
    end
end

local function host_tick()
    if #(S.remote_pcs or {}) == 0 then
        if next(seats) then
            local keys = {}
            for k in pairs(seats) do keys[#keys + 1] = k end
            for _, k in ipairs(keys) do host_unseat(k, "player gone") end
        end
        return
    end
    discover_slow()
    outer_cache = {}
    ensure_resolver()
    fx.unstick()
    local t = os.clock()
    if t - last_cap >= CAP_EVERY_S then
        last_cap = t
        net.broadcast(S.remote_pcs, "VCAP", "1")
    end
    -- remote seats still valid?
    local keys = {}
    for k in pairs(seats) do keys[#keys + 1] = k end
    for _, key in ipairs(keys) do
        local seat = seats[key]
        local pc = remote_pc_of(key)
        local ch = pc and ue.pawn_of(pc)
        local v = vehicle_by(seat.vaddr, seat.vname)
        if not pc then
            host_unseat(key, "player left")
        elseif not v then
            host_unseat(key, "vehicle gone", { tell = true, reason = "vehicle gone" })
        elseif not ch or ue.prop(ch, "PlayerDead?") == true then
            host_unseat(key, "no living character")
        elseif SEATK.out_cold(ch) then
            -- down (sdc_down): it gets out itself on VSEAT none
            host_unseat(key, "downed", { tell = true, reason = "downed" })
        elseif parent_vehicle(ch) ~= seat.vaddr and t - (seat.at or t) > 2 then
            host_unseat(key, "not attached any more", { tell = true, reason = "detached" })
        else
            heal_seated(ch, v, name_of(key), false)
        end
    end
    -- the host's own seat: the game's driving state, and no client driving
    -- the car the host sits in at the wheel
    do
        local hp = ue.local_pawn()
        local ha = hp and parent_vehicle(hp)
        local hv = ha and cur.by[ha]
        if hv and ue.valid(hv) then
            local st = state_for(ha, hv)
            if st.driver_key and st.host_seat ~= "passenger" and t > (st.host_till or 0) then
                log.warn("vehicles: seat: conflict in %s: the host sits at the wheel and %s is its driver", st.name, name_of(st.driver_key))
                demote_remote_driver(hv, st, "the host sits at the wheel")
            end
            if not st.host_seat and not st.driver_key then st.host_seat = "driver" end
            heal_seated(hp, hv, "host", true)
        end
    end
    local list = chars()
    local occ = occupancy(list)
    -- everyone attached to a vehicle: unwelded, sit pose, trace, pose tick
    seat_tick(list)
    vsync.begin()
    -- an idle vehicle (nobody in or at it, nothing reported) has its state
    -- read in turns, vsync.IDLE a tick (~every 3 s with 25 vehicles); the
    -- others every tick. Reading all of them every 0.5 s was most of the
    -- vehicles task.
    local idle_left = vsync.IDLE
    local n = #cur.list
    vsync.idle_turn = (n > 0) and (vsync.idle_turn % n) or 0
    for i, v in ipairs(cur.list) do
        if ue.valid(v) then
            local a = addr(v)
            local st = state_for(a, v)
            if st.host_seat and not host_attached(a) and t > (st.host_till or 0) then
                SEATK.host_gone(v, st)
            end
            if occ[a] then set_collision(v, true) end
            if st.driver_key then
                local pc = remote_pc_of(st.driver_key)
                local o = ue.try(function() return v:GetOwner() end)
                if pc and (not ue.valid(o) or addr(o) ~= addr(pc)) then pcall(function() v:SetOwner(pc) end) end
                set_requires(v, true)
                keep_awake(v, st)
                host_services(v)
            end
            if on("vehicle_state") then
                local active = st.dirty or st.sig == nil or st.driver_key or M.vseats.any(st) or st.host_seat or occ[a]
                -- idle: its turn (a window of vsync.IDLE positions that moves on every tick)
                local turn = ((i - 1 - vsync.idle_turn) % math.max(1, n)) < vsync.IDLE
                if active or (turn and idle_left > 0) then
                    if not active then idle_left = idle_left - 1 end
                    broadcast_state(v, a, st, t)
                end
            end
        end
    end
    vsync.flush()
    vsync.idle_turn = vsync.idle_turn + vsync.IDLE
    -- forget vehicles that are gone
    for a, st in pairs(vs) do
        if not cur.by[a] and not st.driver_key and not M.vseats.any(st) then vs[a] = nil end
    end
    recount_watch()
end

-- ---------------------------------------------------------------------------
-- Client tick
-- ---------------------------------------------------------------------------

local function client_ghosts(occ, t)
    if not on("vehicle_ghosts") then return end
    if t - last_spawner_scan >= 2 then
        last_spawner_scan = t
        for _, cls in ipairs(SPAWNER_CLASSES) do
            for _, sp in ipairs(ue.find_all(cls)) do
                if ue.valid(sp) and not ue.short(sp):find("^Default__") and ue.role(sp) == ue.ROLE_AUTHORITY then
                    local k = ue.name(sp)
                    if not spawners_done[k] and ue.prop(sp, "SpawnerUsed?") ~= true then
                        spawners_done[k] = true
                        ue.set_prop(sp, "SpawnerUsed?", true)
                        M.stats.spawners = M.stats.spawners + 1
                        if M.stats.spawners <= 5 then
                            log.info("vehicles: local vehicle spawner %s switched off (the host spawns vehicles)", ue.short(sp))
                        end
                    end
                end
            end
        end
    end
    -- (a destroyed ghost stays valid, and in the list, until the garbage
    -- collector: cpl.gone keeps it from being destroyed and counted again;
    -- runtime names are not reused)
    for _, v in ipairs(cur.list) do
        local name = ue.valid(v) and ue.short(v)
        if name and not cpl.gone[name] and ue.role(v) == ue.ROLE_AUTHORITY then
            local a = addr(v)
            if not occ[a] and ue.is_runtime_spawned(v) then
                if pcall(function() v:K2_DestroyActor() end) then
                    cpl.gone[name] = t
                    M.stats.ghosts = M.stats.ghosts + 1
                    log.info("vehicles: removed local ghost vehicle %s (spawned on this client only)", name)
                end
            elseif not ghost_logged[name] then
                ghost_logged[name] = true
                log.info("vehicles: client-owned vehicle %s kept (%s)", name, occ[a] and "occupied" or "placed in the level")
            end
        end
    end
    for name, at in pairs(cpl.gone) do
        if t - at > 300 then cpl.gone[name] = nil end
    end
end

-- Client: the host says who sits where (VSTATE fields 11 / 12, PlayerIds;
-- the seats 2+ of a car with a seat 3+ taken: VOCC, with each seat's
-- numbers). A seat the engine did not attach here within SEATK.place_after
-- (an old weld on the host, relevancy) is attached here at the same seat;
-- one the host says is free is let go again. The engine's attachment wins
-- when it comes.

local function client_place(list, t)
    local placed, missing = cpl.placed, cpl.missing
    local by_id = {}
    for _, ch in ipairs(list) do
        if not locally_controlled(ch) then
            local id = pawn_id(ch)
            if id then by_id[tostring(id)] = ch end
        end
    end
    local want = {}
    for _, v in ipairs(cur.list) do
        local a = ue.valid(v) and addr(v)
        local ap = a and applied[a]
        if ap and ap.occ_d ~= nil and t - (ap.at or -100) < 3 * STATE_EVERY_S then
            local list2 = { { "driver", ap.occ_d } }
            if cpl.occ_fresh(ap, t) and #ap.occ_x > 0 then
                for _, o in ipairs(ap.occ_x) do list2[#list2 + 1] = { "passenger", o.id, o.geo, o.idx } end
            else
                list2[2] = { "passenger", ap.occ_p }
            end
            for _, sd in ipairs(list2) do
                local ch = sd[2] and sd[2] ~= "" and by_id[sd[2]]
                local ca = ch and addr(ch)
                if ca then want[ca] = { ch = ch, v = v, va = a, seat = sd[1], geo = sd[3], idx = sd[4] } end
            end
        end
    end
    for ca, w in pairs(want) do
        if parent_vehicle(w.ch) == w.va then
            missing[ca] = nil
        else
            missing[ca] = missing[ca] or t
            local p = placed[ca]
            if t - missing[ca] >= SEATK.place_after and (not p or t - p.at >= SEATK.place_every) then
                local loc, rot = nil, nil
                if w.geo then loc, rot = M.vseats.xf_geo(w.v, w.geo) end
                if not loc then loc, rot = seat_transform(w.v, w.seat == "passenger") end
                pcall(function() w.ch:K2_AttachToActor(w.v, FName("None"), KEEP_WORLD, KEEP_WORLD, KEEP_WORLD, false) end)
                if loc then pcall(function() w.ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
                placed[ca] = { va = w.va, vname = ue.short(w.v), name = ue.short(w.ch), at = t }
                log.info("vehicles: pose: %s placed in the %s seat%s of %s here (the host says so; no attachment arrived for %.1f s)",
                    char_label(w.ch), w.seat, w.idx and (" " .. w.idx) or "", ue.short(w.v), t - missing[ca])
            end
        end
    end
    for ca in pairs(missing) do
        if not want[ca] then missing[ca] = nil end
    end
    for ca, p in pairs(placed) do
        if not want[ca] then
            placed[ca] = nil
            for _, ch in ipairs(list) do
                if addr(ch) == ca and ue.short(ch) == p.name then
                    if parent_vehicle(ch) == p.va then
                        pcall(function() ch:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
                        log.info("vehicles: pose: %s taken out of %s here (the host says the seat is free)", char_label(ch), p.vname)
                    end
                    break
                end
            end
        end
    end
end

local function client_tick()
    if not client_ready() then return end
    local t = os.clock()
    discover_slow()
    local list = chars()
    local occ = occupancy(list)
    local lp = ue.local_pawn()
    -- once per world, 12 s after this player's character exists: the sit
    -- montage (sit_montage takes it only from memory on a client, so a
    -- client that never sat in a car would show teammates seated without
    -- the pose). One small asset, off the message path.
    if lp and not sit.tried then
        sit.pawn_at = sit.pawn_at or t
        if t - sit.pawn_at >= 12 then
            sit.tried = true
            ue.load_asset(SIT_MONTAGE, "vehicles preload")
        end
    end
    local la = lp and parent_vehicle(lp)
    if local_seat then
        if la ~= local_seat.vaddr and t - local_seat.since > 2 then
            -- out without the exit hook (death, the host detached us)
            local v = vehicle_by(local_seat.vaddr, local_seat.vname)
            if v then
                to_host("VEXIT", v, "d")
                set_requires(v, true)
            end
            -- the game's driving state goes with it (InVehicle? left set would
            -- hide the fuel / repair options and turn the key into "exit")
            if lp and not la and ue.prop(lp, "InVehicle?") == true and ue.prop(lp, "PlayerDead?") ~= true then
                char_out(lp)
                pcall(function() lp:ResetVehicleCameraArmLength() end)
            end
            seat_log("this player", local_seat.vname, "out", "not attached any more (no exit call seen); InVehicle?=" ..
                tostring(lp and ue.prop(lp, "InVehicle?")))
            local_seat = nil
            hud.check("seat ended without the game's exit")
        elseif local_seat.seat == "pending" and t - local_seat.since > PENDING_S then
            local_seat.seat = "local"
            seat_log("this player", local_seat.vname, "local", "the host did not answer; driving this copy")
        end
    else
        fx.unstick()
    end
    -- our own seat: the game's driving state (exit key, driving input)
    if la then
        local lv = cur.by[la]
        if lv and ue.valid(lv) then heal_seated(lp, lv, "this player", true) end
    end
    client_ghosts(occ, t)
    for _, v in ipairs(cur.list) do
        if ue.valid(v) and ue.role(v) ~= ue.ROLE_AUTHORITY then
            local a = addr(v)
            local mine = local_seat and local_seat.vaddr == a
            set_requires(v, not (mine and DRIVING[local_seat.seat]))
            if on("vehicle_state") then
                set_collision(v, occ[a] ~= nil)
                local ap = applied[a]
                if ap and ap.name ~= ue.short(v) then ap = nil; applied[a] = nil end
                local ob = obs[a] or {}
                obs[a] = ob
                local want = ap ~= nil and ap.drv and ap.eng and (ap.fuel or 0) > 0 and t - (ap.at or -100) < 3 * STATE_EVERY_S
                    and la ~= a
                if want then
                    engine_sound(v, true)
                    ob.engine = true
                elseif ob.engine then
                    if la ~= a then engine_sound(v, false) end
                    ob.engine = false
                end
                -- a repair / refuel done here (the game's kit branch has no
                -- function to hook; UseGasCan reports at once)
                if ap then fx.report(v, ap, "seen in the tick") end
            end
        end
    end
    -- the end of this player's refuel / repair hold (after fx.report: an add
    -- the game made here is sent as such)
    fx.hold_end(t)
    if on("vehicle_state") then
        client_place(list, t)
        seat_tick(list)
    else
        seat_tick(list)
    end
end

-- ---------------------------------------------------------------------------
-- Tick, reset, install
-- ---------------------------------------------------------------------------

local last_role = nil

function M.reset(why)
    pcall(SEATK.flip_hold, true)   -- (before the vehicle list goes)
    sit.obj, sit.tried, sit.pawn_at = nil, false, nil
    sit.floor, sit.floor_tried = nil, false
    vs, seats, watch_n, outer_cache = {}, {}, 0, {}
    cur = { list = {}, by = {}, at = -100 }
    local_seat, host_cap = nil, false
    applied, obs, att, seated = {}, {}, {}, {}
    cpl.placed, cpl.missing, cpl.gone, cpl.rescan_at = {}, {}, {}, -100
    spawners_done, ghost_logged = {}, {}
    last_spawner_scan, last_cap = -100, -100
    sit.obj = nil
    buy.seen, buy.blocked = {}, nil
    fx.holds, fx.stuck_since, fx.asked, fx.box_log, fx.tow_sent = {}, nil, {}, {}, nil
    SEATK.refused = nil
    hud.logged, hud.until_at = {}, -100
    vsync.out, vsync.rkey, vsync.idle_turn, vsync.occ_out = {}, "", 0, {}
    for k in pairs(logged) do logged[k] = nil end
    ik.key_at, ik.toggle_at, ik.opened_at, ik.close, ik.tab = nil, nil, nil, nil, nil
    ik.set_poll(false)
    ik.seat_poll, SEATK.hold_va, SEATK.key_was, SEATK.tow_seen = false, nil, true, nil
    M.radio.reset(why)
    -- (the seat table's live edits stay: they are not per world)
    M.vseats.reset(why)
    log.info("vehicles: reset (%s)", tostring(why))
end

local function tick()
    if not S then return end
    local role = S.role
    if role ~= last_role then
        if last_role ~= nil then M.reset("role " .. tostring(last_role) .. " -> " .. tostring(role)) end
        last_role = role
    end
    SEATK.flip_hold()   -- (also off / single player: let go)
    if not enabled() or (role ~= "host" and role ~= "client") then
        ik.set_poll(false)
        ik.seat_poll, SEATK.hold_va = false, nil
        return
    end
    install_hooks()
    hud.tick()
    if role == "host" then
        host_tick()
        fx.hold_end(os.clock())   -- (here: only lets an old hold record go)
    else
        client_tick()
    end
    SEATK.poll_flags()
    ik.set_poll(ik.maybe_seated())
    M.radio.tick(role)
end

function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("veh.tick", "vehicles: tick: %s", tostring(err)) end
end

function M.register_handlers()
    net.on("VENTER", on_venter)
    net.on("VEXIT", on_vexit)
    net.on("VLIGHT", on_vlight)
    net.on("VHORN", on_vhorn)
    net.on("VFLIP", on_vflip)
    net.on("VTOW", on_vtow)
    net.on("VFUEL", on_vfuel)
    net.on("VREPAIR", on_vrepair)
    net.on("VBOXR", fx.on_boxr)
    net.on("VPUSH", on_vpush)
    net.on("VBUY", on_vbuy)
    net.on("VBUYR", on_vbuyr)
    net.on("VCAP", on_vcap)
    net.on("VSEAT", on_vseat)
    -- the seat key: a client's press (host), the host's answer (client)
    net.on("VSWITCH", function(f, pc) SEATK.on_vswitch(f, pc) end)
    net.on("VSWR", function(f) SEATK.on_vswr(f) end)
    net.on("VSTATE", on_vstate)
    net.on("VOCC", cpl.on_occ)
    net.on("VRADIO", function(f, pc) if enabled() then M.radio.on_msg(f, pc) end end)
    net.on("VRADIOQ", function(f, pc) if enabled() then M.radio.on_query(f, pc) end end)
end

-- main.lua, after sdc_respawn.install (the vehicle scope chains to its resolver).
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    -- what the radio needs of the vehicle sync
    M.radio.attach({
        S = function() return S end,
        MATCH_M = MATCH_M,
        vehicle_at = vehicle_at,
        vehicle_by = vehicle_by,
        list = function() return cur.list end,
        addr = addr,
        local_pos = local_pos,
        -- the vehicle this machine's player sits in (attached), or nil
        local_vehicle = function()
            local lp = ue.local_pawn()
            local a = lp and parent_vehicle(lp)
            local v = a and cur.by[a]
            if v and ue.valid(v) then return v end
            return nil
        end,
        sender = sender,
        msg_vehicle = msg_vehicle,
        seat_in = seat_in,
        seats = function() return seats end,
        remote_pc_of = remote_pc_of,
        name_of = name_of,
        client_ready = client_ready,
        host_cap = function() return host_cap end,
    })
    M.register_handlers()
    if session and session.world_reset_hooks then
        session.world_reset_hooks.vehicles = function(why) M.reset("world:" .. tostring(why)) end
    end
    log.info("vehicles: installed (vehicle_sync=%s passengers=%s seats=%s untuned seats=%s state=%s ghosts=%s radio=%s)",
        tostring(enabled()), tostring(on("vehicle_passengers")), tostring(M.vseats.on()), tostring(M.vseats.untuned()),
        tostring(on("vehicle_state")), tostring(on("vehicle_ghosts")), tostring(on("vehicle_radio")))
end

-- main.lua: the console commands (sdcoop_seat, sdc_vehseats).
function M.register_commands(add)
    M.vseats.register_commands(add)
end

-- Host: the seat ("driver" | "passenger") the host gave remote player `key`
-- (session key), or nil (sdc_players: no pull of a seated player).
function M.seat_of(key)
    local seat = key and seats[key]
    return seat and seat.seat or nil
end

-- Host: the seat number (1 = driver, 2.. passengers) of remote player `key`, or nil.
function M.seat_idx(key)
    local seat = key and seats[key]
    if not seat then return nil end
    return seat.idx or (seat.seat == "driver" and 1 or 2)
end

function M.status_line()
    local nseats = 0
    for _ in pairs(seats) do nseats = nseats + 1 end
    local s = M.stats
    return string.format("vehicles: %s known=%d seats=%d watched=%d local=%s host_cap=%s | enters=%d passengers=%d exits=%d to the wheel=%d seat moves=%d rejected=%d relays=%d | state sent=%d applied=%d | ghosts=%d spawners=%d buys=%d | stray get-in steps undone=%d stray exits=%d | inventory key in a seat=%d fixed=%d lost=%d | %s",
        tostring(S and S.role), #cur.list, nseats, watch_n,
        local_seat and (local_seat.vname .. ":" .. local_seat.seat .. (local_seat.idx and (":" .. local_seat.idx) or "")) or "-",
        tostring(host_cap),
        s.enters, s.passengers, s.exits, s.promoted, s.switches, s.rejected, s.relays, s.states_sent, s.states_applied,
        s.ghosts, s.spawners, s.buys, s.stray_vi, s.stray_exits, s.inv_keys, s.inv_fixed, s.inv_lost,
        M.radio.status() .. " | " .. M.vseats.status())
end

-- Test access (mock harness).
M._t = {
    resolve = function(w) return my_resolver(w) end,
    seats = function() return seats end,
    vs = function() return vs end,
    local_seat = function() return local_seat end,
    applying = function() return applying end,
    ik = ik,
    att = function() return att end,
    cpl = cpl,
    vseats = M.vseats,
    seatk = SEATK,
    vsync = vsync,
    applied = function() return applied end,
    seated = function() return seated end,
    fx = fx,
}

-- ---------------------------------------------------------------------------
-- sdcoop_seat (sdc_vehseats.command): the vehicle-side pieces. Host or
-- single player. Who sits in a seat is told by the live attachment (and,
-- for a client, the host's record): in single player no records are kept.
-- ---------------------------------------------------------------------------

-- The vehicle the host sits in, else the nearest within 8 m: v, its
-- address, its class, its record (host only; nil in single player).
function SEATK.cmd_vehicle()
    discover(true)
    local hp = ue.local_pawn()
    if not hp then return nil end
    local a = parent_vehicle(hp)
    local v = a and cur.by[a]
    if not v then
        local l = ue.location(hp)
        v = l and vehicle_at(l.X, l.Y, l.Z, nil, 800)
        a = v and addr(v)
    end
    if not (v and a) then return nil end
    local st = (S and S.role == "host") and state_for(a, v) or nil
    return v, a, ue.class_name(v), st
end

-- Who sits in seat idx (geometry geo): its label and id (a client key or
-- "host"), or nil.
function SEATK.cmd_who(v, a, st, idx, geo)
    if st and S and S.role == "host" then
        for key, seat in pairs(seats) do
            if seat.vaddr == a and (seat.idx or (seat.seat == "driver" and 1 or 2)) == idx then
                local pc = remote_pc_of(key)
                local ch = pc and ue.pawn_of(pc)
                if ch and parent_vehicle(ch) == a then return name_of(key), key end
            end
        end
    end
    local hp = ue.local_pawn()
    if hp and geo and parent_vehicle(hp) == a then
        local loc = idx == 1 and seat_transform(v, false) or M.vseats.xf_geo(v, geo)
        local hl = ue.location(hp)
        if loc and hl and d2(loc, hl) <= M.vseats.NEAR * M.vseats.NEAR then return "host", "host" end
    end
    return nil, nil
end

-- The one in seat idx (wid) to the seat's new geometry at once: the host
-- moved here (its record's geometry too), a client moved here and told its
-- seat again (VSEAT with the new numbers, no notice; it moves itself); the
-- others see it through the attachment, VOCC follows (st.dirty).
function SEATK.cmd_place(v, a, st, idx, geo, wid)
    if not (wid and geo) then return "nobody to move" end
    local loc, rot = M.vseats.xf_geo(v, geo)
    if not loc then return "no world position for seat " .. idx end
    if wid == "host" then
        local hp = ue.local_pawn()
        if not (hp and parent_vehicle(hp) == a) then return "the host does not sit in it" end
        unweld(hp, v)
        pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
        if st and st.host_seat == "passenger" and M.vseats.host_idx(st) == idx then
            st.host_geo = geo
            st.dirty = true
        end
        return "the host moved there"
    end
    local seat = seats[wid]
    local pc = remote_pc_of(wid)
    local ch = pc and ue.pawn_of(pc)
    if not (st and seat and ch and parent_vehicle(ch) == a) then return "that player does not sit in it" end
    seat.geo = geo
    pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    SEATK.tell_pass(pc, st, wid, idx, geo, false)
    st.dirty = true
    return name_of(wid) .. " moved there (its seat sent again)"
end

-- The host to seat idx to look at it, alone in the vehicle: a real seat
-- change on the host (records, VOCC); in single player only the move.
function SEATK.cmd_try(v, a, st, idx, geo)
    local hp = ue.local_pawn()
    if not (hp and parent_vehicle(hp) == a) then return false, "sit in this vehicle first" end
    if st then
        for key, seat in pairs(seats) do
            if seat.vaddr == a then return false, "only alone in the vehicle (" .. name_of(key) .. " sits in it)" end
        end
    end
    local loc, rot
    if idx == 1 then loc, rot = seat_transform(v, false) else loc, rot = M.vseats.xf_geo(v, geo) end
    if not loc then return false, "no world position for seat " .. idx end
    unweld(hp, v)
    pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    if st then
        if idx == 1 then
            st.host_seat, st.host_idx, st.host_geo = "driver", nil, nil
        else
            st.host_seat, st.host_idx, st.host_geo = "passenger", idx, geo
        end
        st.dirty = true
    end
    return true, "the host sits in seat " .. idx .. " now" .. (st and "" or " (single player: moved only)")
end

-- The seat module's view of this one (xf: seat_transform; the command).
M.vseats.attach({
    seat_transform = seat_transform,
    role = function() return S and S.role end,
    cmd_vehicle = SEATK.cmd_vehicle,
    who_at = SEATK.cmd_who,
    place = SEATK.cmd_place,
    try = SEATK.cmd_try,
})

return M
