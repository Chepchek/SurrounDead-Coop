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
--   Passengers (vehicle_passengers): the game has one seat. A second player
--     gets the mirrored seat next to the driver (attach + SitInCar montage +
--     VehicleInteraction on the host); the host becomes a passenger the same
--     way when it enters a client-driven car. When the driver leaves, a
--     passenger moves to the driver seat.
--   Client: vehicles it does not drive use the replicated inputs (no local
--     handbrake fighting the physics replication, no ServerUpdateState
--     spam); its own driven vehicle predicts locally. Lights / horn / flip /
--     tow / push / refuel / repair / trader purchases done on the client are
--     sent to the host, which runs the game's function on its copy.
--   Refuel / repair (every machine): the game's own flow where the key was
--     pressed (option, timer bar, montage, hold). Its last step cannot take
--     the gas can / repair kit on a client (the host's data): the client's
--     note of that asks the host (VFUEL / VREPAIR), which takes the item from
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
--     health, lights, engine and "has a driver" (VSTATE); clients apply them
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
    stats = { enters = 0, passengers = 0, exits = 0, rejected = 0, promoted = 0, relays = 0,
              states_sent = 0, states_applied = 0, ghosts = 0, spawners = 0, buys = 0,
              stray_vi = 0, stray_exits = 0, inv_keys = 0, inv_fixed = 0, inv_lost = 0 },
}

local S = nil   -- sdc_session.state

-- The vehicle radio (config vehicle_radio): its own module, given this
-- module's pieces in M.install and run from tick / reset / the handlers (a
-- field, not a local: this chunk is at Lua's 200-locals limit).
M.radio = require("sdc_vehradio")

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
-- (VSTATE on a client: ~25 vehicles per message; the location in one call,
-- the class from discover's cache)
local function loc_xyz(v)
    local l = v:K2_GetActorLocation()
    return l.X, l.Y, l.Z
end

local function vehicle_at(x, y, z, cls, maxd)
    if not (x and y and z) then return nil end
    discover(false)
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
    for _, c in ipairs(((ue.find_all_recent or ue.find_all)(CHAR_CLASS) or {})) do
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
        if not active then pcall(function() snd:Activate(true) end) end
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

local sit = { obj = nil, tried = false }
local function sit_montage()
    if sit.obj and ue.valid(sit.obj) then return sit.obj end
    sit.obj = ue.find_object(SIT_MONTAGE)
    if not sit.obj and not sit.tried and LoadAsset then
        -- a machine that never ran an entry (a client watching the host)
        sit.tried = true
        pcall(LoadAsset, SIT_MONTAGE)
        sit.obj = ue.find_object(SIT_MONTAGE)
    end
    return sit.obj
end

local function playing_sit(ch)
    local m = ue.try(function() return ch:GetCurrentMontage() end)
    return ue.valid(m) and ue.short(m):find("SitInCar", 1, true) ~= nil, m
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

-- vs[vehicle address] = { name, cls, driver_key, pass_key, host_seat,
--   scope_key, scope_till, host_till, released_till, watch, dirty, sig,
--   sent_at, upd, push_at }
local vs = {}
-- seats[remote pc key] = { vaddr, vname, seat = "driver" | "passenger", at, accept }
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
        st = { name = name, cls = ue.class_name(v) }
        vs[a] = st
    end
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
}

-- Refuel / repair state of this machine's player (functions further down,
-- "Refuel / repair"). hold: { va, vname, kind, t0, till } while the game's
-- hold (RetriggerableDelay(Duration) -> UseGasCan / the repair kit) runs.
local fx = {
    hold = nil, stuck_since = nil, da = {}, box_log = {},
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
}

-- Vehicle trader purchases (functions in "Vehicle trader"): asset paths and
-- the Blueprint struct field names (S_UpdateCount, the Jig item, the
-- DT_VehicleInfo "Trader" row).
local buy = {
    serial = 0, seen = {}, blocked = nil, spawn_hooked = false,
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
    if ue.prop(ch, "PlayerDead?") == true then return end
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

local function seat_mark(ch, v, va, label, is_local)
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
    local yes, m = playing_sit(ch)
    if not yes then
        local sm = sit_montage()
        if sm and pcall(function() ch:PlayAnimMontage(sm, 1.0, FName("None")) end) then
            r.sit_n = r.sit_n + 1
            if r.sit_n <= 3 or r.sit_n % 20 == 0 then
                log.info("vehicles: pose: %s in %s: sit montage started here (%d; was playing %s)",
                    label, r.vname, r.sit_n, ue.valid(m) and ue.short(m) or "nothing")
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
    for _, ch in ipairs(list) do
        local va = parent_vehicle(ch)
        local v = va and cur.by[va]
        local ca = addr(ch)
        if ca and v and ue.valid(v) then
            seen[ca] = true
            local is_local = locally_controlled(ch)
            local first = not seated[ca] or seated[ca].vaddr ~= va
            seat_mark(ch, v, va, char_label(ch), is_local)
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
end

-- The game's own replicated stop (BPI_Player.StopMontage -> Svr_StopMontage
-- -> MC_StopMontage): the sit montage of a player who got out ends on every
-- other machine too (IncludeLocal false: the exit already stopped it here).
local function stop_sit_everywhere(ch)
    local sm = sit_montage()
    if ch and sm then pcall(function() ch:StopMontage(sm, false) end) end
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
        local o = ue.try(function() return wco:GetOuter() end)
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
        local h = fx.hold
        if h and h.va == a and t < h.till then return false end
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
-- machine's player, only for the vehicle it sits in.
local hud = { next_at = -100, logged = {} }

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
function hud.check(why)
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

-- Safety net, at most once a second.
function hud.tick()
    local t = os.clock()
    if t < hud.next_at then return end
    hud.next_at = t + 1
    hud.check("left on screen: this player sits in no vehicle, or it is another vehicle's panel")
end

local host_seat_driver   -- forward (promotion calls it from host_unseat)

local function send_seat(pc, kind, extra)
    if pc then net.send_to(pc, "VSEAT", kind, extra or "") end
end

host_seat_driver = function(key, pc, ch, v, st, why)
    local a = addr(v)
    st.driver_key = key
    st.scope_key, st.scope_till = key, os.clock() + SCOPE_S
    st.released_till = nil
    recount_watch()
    pcall(function() v:SetOwner(pc) end)
    local seat = seats[key] or {}
    seats[key] = seat
    seat.vaddr, seat.vname, seat.seat, seat.at = a, st.name, "driver", os.clock()
    hold_position(ch, seat)
    local old_ui = ue.prop(v, "VehicleUI")
    if not ue.valid(old_ui) then old_ui = nil end
    local host_was = host_attached(a)
    -- the host standing at the fuel / repair box must not stop the game's
    -- VehicleInteraction(true) for this client (runs 0.1 s after the entry)
    clear_area_flags(v, false)
    local ok, err = apply(function() v:Interact_GetInVehicle() end)
    clear_area_flags(v, false)
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
    -- the game welded the character: unweld now, so its seat replicates
    if parent_vehicle(ch) == a then seat_mark(ch, v, a, name_of(key), false) end
    local req = set_requires(v, true)
    keep_awake(v, st)
    st.dirty = true
    M.stats.enters = M.stats.enters + 1
    send_seat(pc, "driver")
    seat_log(name_of(key), st.name, "driver", why or "driver seat free")
    log.info("vehicles: %s drives %s (game entry ok=%s%s, replicated inputs=%s, owner set)",
        name_of(key), st.name, tostring(ok), ok and "" or (" " .. tostring(err)), tostring(req))
end

local function host_seat_passenger(key, pc, ch, v, st, driver_name, why)
    local a = addr(v)
    local loc, rot = seat_transform(v, true)
    local seat = seats[key] or {}
    seats[key] = seat
    seat.vaddr, seat.vname, seat.seat, seat.at = a, st.name, "passenger", os.clock()
    st.pass_key = key
    hold_position(ch, seat)
    -- the game's driving state first (InVehicle?, its Vehicle): then the
    -- seat's overlap with the fuel / repair box no longer counts this player
    clear_area_flags(v, false)
    apply(function() ch:VehicleInteraction(true, v) end)
    -- not welded: a welded seat would not replicate (see "Seated characters")
    pcall(function() ch:K2_AttachToActor(v, FName("None"), KEEP_WORLD, KEEP_WORLD, KEEP_WORLD, false) end)
    if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
    local m = sit_montage()
    if m then pcall(function() ch:PlayMontage(m, 1.0) end) end
    clear_area_flags(v, false)
    if parent_vehicle(ch) == a then seat_mark(ch, v, a, name_of(key), false) end
    set_collision(v, true)
    st.dirty = true
    M.stats.passengers = M.stats.passengers + 1
    send_seat(pc, "passenger", driver_name)
    seat_log(name_of(key), st.name, "passenger", why or (tostring(driver_name) .. " drives"))
    log.info("vehicles: %s sits as a passenger in %s next to %s (seat %s)", name_of(key), st.name,
        tostring(driver_name), loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "?")
end

-- Driver left: a passenger takes the driver seat.
local function promote(v, st)
    local a = addr(v)
    if host_attached(a) and st.host_seat == "passenger" then
        local hp = ue.local_pawn()
        local loc, rot = seat_transform(v, false)
        if hp and loc then pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
        st.host_seat = "driver"
        -- the client's Event_ExitVehicle stopped what the host's own entry
        -- started; as @7820 the handbrake goes off for the new driver
        local m = mcomp(v)
        if m then
            pcall(function() m:SetHandbrakeInput(false) end)
            pcall(function() m:SetBrakeInput(0) end)
        end
        host_services(v)
        M.stats.promoted = M.stats.promoted + 1
        seat_log("host", st.name, "driver", "the driver left; the passenger takes the wheel")
        return
    end
    local pkey = st.pass_key
    if not pkey then return end
    local pc = remote_pc_of(pkey)
    local ch = pc and ue.pawn_of(pc)
    if not (pc and ch and parent_vehicle(ch) == a and can_redirect(pc)) then
        log.info("vehicles: seat: passenger %s stays a passenger in %s (cannot take the wheel here)", name_of(pkey), st.name)
        return
    end
    st.pass_key = nil
    local seat = seats[pkey]
    if seat then seat.seat = "driver" end
    M.stats.promoted = M.stats.promoted + 1
    host_seat_driver(pkey, pc, ch, v, st, "the driver left; the passenger takes the wheel")
end

-- opts: side ("p" = passenger side), tell (send VSEAT none), reason
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
    if seat.seat == "driver" then
        if v then
            local others = (st and st.pass_key ~= nil) or host_attached(seat.vaddr)
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
        if attached and v then
            pcall(function() ch:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
            local loc = socket_loc(v, "PassengerSide")
            if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, ue.rotation(ch), false, {}, false) end) end
            stop_sit(ch)
            local cmc = ue.prop(ch, "CharacterMovement")
            if ue.valid(cmc) then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
        end
        if st and st.pass_key == key then st.pass_key = nil; st.dirty = true end
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
    if opts.tell then send_seat(pc, "none", opts.reason or why) end
    seat_log(name_of(key), seat.vname, "out", "was " .. tostring(seat.seat) .. "; " .. tostring(why))
    if seat.seat == "driver" and v and st then promote(v, st) end
end

local function host_reject(pc, why)
    M.stats.rejected = M.stats.rejected + 1
    send_seat(pc, "none", why)
    local r = S and S.remote and S.remote[ue.name(pc)]
    seat_log(r and r.name or ue.short(pc), "-", "refused", why)
end

-- Who has the driver seat: a remote driver, or the host sitting in it (not
-- as a passenger). The host's attachment counts at once (the game's entry
-- attaches synchronously; its driving state comes 0.1 s later, or not at all
-- when VehicleInteraction stopped half-way).
local function has_driver(a, st)
    if st.driver_key and remote_pc_of(st.driver_key) then return true end
    return host_seated(a) and st.host_seat ~= "passenger"
end

-- A remote driver while the host sits in the driver seat (up to 0.6.44 the
-- seat test made a client the driver of the host's car): the client goes
-- to the passenger seat, the host keeps the wheel.
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
    if not (seat and ch and parent_vehicle(ch) == a) or st.pass_key then
        if seat then host_unseat(key, why, { tell = true, reason = "full" }) end
        return
    end
    seat.seat = "passenger"
    st.pass_key = key
    local loc, rot = seat_transform(v, true)
    if loc then pcall(function() ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
    st.dirty = true
    recount_watch()
    send_seat(pc, "passenger", cfg.player_name())
    seat_log(name_of(key), st.name, "passenger", why)
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

local function on_venter(f, pc)
    local key = sender(pc)
    if not key then return end
    local ch = ue.pawn_of(pc)
    if not ch or ue.prop(ch, "PlayerDead?") == true then return host_reject(pc, "no character") end
    if not ensure_resolver() then return host_reject(pc, "no scope api") end
    discover(true)
    local v = vehicle_at(tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), f[4], MATCH_M)
    if not v then return host_reject(pc, "vehicle not found") end
    local cl, vl = ue.location(ch), ue.location(v)
    if not (cl and vl) or d2(cl, vl) > NEAR_M * NEAR_M then return host_reject(pc, "too far") end
    local a = addr(v)
    local st = state_for(a, v)
    local had = seats[key]
    if had and had.vaddr == a and parent_vehicle(ch) == a then
        -- its game ran the get-in again while it sits here (a second press
        -- with its in-vehicle flag unset): the seat stays, the answer repeats,
        -- no second get-in here
        local extra = nil
        if had.seat == "passenger" then extra = st.driver_key and name_of(st.driver_key) or cfg.player_name() end
        send_seat(pc, had.seat, extra)
        log.info("vehicles: seat: %s asked again for a seat in %s while sitting there as %s: the seat stays (no second get-in)",
            name_of(key), st.name, tostring(had.seat))
        return
    end
    if had then host_unseat(key, "re-enter") end
    local hs = host_seated(a)
    log.info("vehicles: %s asks for a seat in %s: remote driver=%s, host seated=%s (host seat=%s, driving state=%s), passenger=%s",
        name_of(key), st.name, st.driver_key and name_of(st.driver_key) or "-", tostring(hs), tostring(st.host_seat),
        tostring(host_in(a)), st.pass_key and name_of(st.pass_key) or "-")
    if not has_driver(a, st) then
        if not can_redirect(pc) then return host_reject(pc, "no player index") end
        host_seat_driver(key, pc, ch, v, st, hs and "the host sits as a passenger; driver seat free" or "driver seat free")
    elseif on("vehicle_passengers") and not st.pass_key and st.host_seat ~= "passenger" then
        local dn = st.driver_key and name_of(st.driver_key) or cfg.player_name()
        host_seat_passenger(key, pc, ch, v, st, dn,
            st.driver_key and (dn .. " drives") or "the host drives")
    else
        host_reject(pc, "full")
    end
end

local function on_vexit(f, pc)
    local key = sender(pc)
    if not key or not seats[key] then return end
    -- f[6]: seconds the client sat in that seat, f[7]: its seat there
    -- (both diagnostics; the exit itself is the client's interact key)
    local age = tonumber(f[6])
    host_unseat(key, age and string.format("client exit with the interact key after %.1f s in its %s seat", age, tostring(f[7] or "?"))
        or "client exit", { side = f[5] })
end

-- The sender's seat in the vehicle the message names.
local function seat_in(key, v)
    local seat = seats[key]
    if seat and v and seat.vaddr == addr(v) then return seat.seat end
    return nil
end

local function on_vlight(f, pc)
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v or seat_in(key, v) ~= "driver" then return end
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
    if not v or seat_in(key, v) ~= "driver" then return end
    apply(function() v:Event_FlipVehicle() end)
    M.stats.relays = M.stats.relays + 1
    log.info("vehicles: %s flipped %s", name_of(key), ue.short(v))
end

local function on_vtow(f, pc)
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v or seat_in(key, v) ~= "driver" then return end
    local want = f[5] == "1"
    if (ue.prop(v, "TowingVehicle?") == true) == want then return end
    if want then
        apply(function() v:AddTowingComp(false, true) end)
    else
        apply(function() v:RemoveTowingComp() end)
    end
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
    local path = kind == "refuel" and fx.GASCAN or fx.KIT
    da = ue.find_object(path)
    if not da and LoadAsset then
        pcall(LoadAsset, path)
        da = ue.find_object(path)
    end
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

function buy.asset(path)
    local o = ue.find_object(path)
    if not o and LoadAsset then
        pcall(LoadAsset, path)
        o = ue.find_object(path)
    end
    return o
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
local horn_client   -- forward: client handler
local function on_vhorn(f, pc)
    if S and S.role == "client" then return horn_client(f) end
    local key = sender(pc)
    local v = key and msg_vehicle(f, pc)
    if not v or not seat_in(key, v) then return end
    apply(function() v:Horn() end)
    host_horn_broadcast(v, pc)
    M.stats.relays = M.stats.relays + 1
end

-- ---------------------------------------------------------------------------
-- Host: hooks for the host's own actions
-- ---------------------------------------------------------------------------

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
    st.host_at = os.clock()
    if again then
        log.info("vehicles: seat: the host's get-in on %s ran again while it sat there as %s (the game's VehicleUI made twice: the extra one goes)",
            st.name, tostring(st.host_seat))
    end
    -- the client standing at the fuel / repair box would stop the game's
    -- VehicleInteraction(true) for the host 0.1 s from now (host stuck in
    -- the seat: no driving, no exit)
    local flags = clear_area_flags(v, true)
    if #flags > 0 then
        log.info("vehicles: %s had %s set (another player at the car); cleared for the host's entry", st.name, table.concat(flags, ","))
    end
    if st.driver_key then
        -- a client drives: the host sits next to it
        local hp = ue.local_pawn()
        local loc, rot = seat_transform(v, true)
        if hp and loc then pcall(function() hp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
        st.host_seat = "passenger"
        log.say("veh_passenger", "info", 5, name_of(st.driver_key))
        if st.pass_key then
            log.warn("vehicles: seat: the host shares the passenger seat of %s with %s (one passenger seat)", st.name, name_of(st.pass_key))
        end
        seat_log("host", st.name, "passenger", name_of(st.driver_key) .. " drives")
    else
        st.host_seat = "driver"
        seat_log("host", st.name, "driver", st.pass_key and (name_of(st.pass_key) .. " sits as a passenger; driver seat free") or "driver seat free")
    end
    -- the game welded the host into the car: unweld now, so the seat
    -- replicates (the clients saw the host under the car)
    local hp = ue.local_pawn()
    if hp and parent_vehicle(hp) == a then seat_mark(hp, v, a, "host", true) end
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
    local was = st.host_seat
    st.host_seat = nil
    st.dirty = true
    local hp = ue.local_pawn()
    forget_att(hp)
    -- the exit stopped the sit montage only here: stop it on the clients too
    stop_sit_everywhere(hp)
    local hca = hp and addr(hp)
    local hr = hca and seated[hca]
    local was_seated = hr ~= nil and hr.vaddr == a
    if was_seated then seat_clear(hca, hr, hp, "host") end
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
        -- was passenger" 1.7 s after its real exit). Nothing to promote.
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
        seat_log("host", st.name, "out", "was " .. tostring(was or "driver")
            .. (st.pass_key and ("; passenger " .. name_of(st.pass_key) .. " takes the wheel") or "") .. "; " .. how)
        if was ~= "passenger" then promote(v, st) end
    end
end

-- ---------------------------------------------------------------------------
-- Client state
-- ---------------------------------------------------------------------------

local host_cap = false
local local_seat = nil      -- { vaddr, vname, seat = pending|driver|passenger|local, since }
local applied = {}          -- [vehicle address] = { name, fuel, health, color, drv, eng, at, lights_local }
local obs = {}              -- [vehicle address] = { engine = bool }
-- placed[character address] = { va, vname, name, at }: seated here from VSTATE;
-- missing[character address] = first time a VSTATE seat had no attachment here
local cpl = { placed = {}, missing = {} }
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
-- checks (Event_ExitVehicle + tail + the character's own exit path).
local function local_force_exit(v, why)
    local ch = ue.local_pawn()
    apply(function() v:Event_ExitVehicle() end)
    if ch then
        exit_tail(v, ch, false)
        apply(function() ch:ResetVehicleCameraArmLength() end)
        char_out(ch)
        forget_att(ch)
    end
    set_requires(v, true)
    seat_log("this player", local_seat and local_seat.vname or ue.short(v), "out", "the host refused: " .. tostring(why))
    local_seat = nil
    hud.check("the host refused the seat")
    if why == "full" then
        log.say("veh_full", "warn", 5)
    else
        log.say("veh_rejected", "warn", 5, tostring(why))
    end
end

local function client_entered(v)
    if not client_ready() then return end
    local a = addr(v)
    local_seat = { vaddr = a, vname = ue.short(v), seat = host_cap and "pending" or "local", since = os.clock() }
    if host_cap then set_requires(v, true) end
    -- the host's character at the fuel / repair box of our copy would stop
    -- our own VehicleInteraction(true) 0.1 s from now
    local flags = clear_area_flags(v, true)
    -- the game welded us into our copy: unweld, so our moves keep reaching
    -- the host (its copy of us animates from them)
    local lp = ue.local_pawn()
    if lp and parent_vehicle(lp) == a then seat_mark(lp, v, a, "this player", true) end
    to_host("VENTER", v)
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
    -- only the interact key calls ExitVehicle (BP_PlayerCharacter @108596,
    -- IA_Interact "Started": once per press); the age tells a quick second
    -- press from a stuck seat in the logs
    local age = os.clock() - (local_seat.seat_at or local_seat.since or os.clock())
    to_host("VEXIT", v, side, string.format("%.1f", age), tostring(local_seat.seat))
    set_requires(v, true)
    forget_att(ch)
    seat_log("this player", local_seat.vname, "out", string.format("exit here with the interact key after %.1f s; was %s, %s side",
        age, tostring(local_seat.seat), side))
    local_seat = nil
end

local function on_vcap()
    if not host_cap then log.info("vehicles: the host runs the vehicle sync") end
    host_cap = true
end

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
        if v then local_force_exit(v, f[2] ~= "" and f[2] or "?") else local_seat = nil end
        return
    end
    local was = local_seat.seat
    local_seat.seat = kind == "driver" and "driver" or "passenger"
    if was ~= local_seat.seat then local_seat.seat_at = os.clock() end
    if v then
        set_requires(v, local_seat.seat ~= "driver")
        -- this machine's own entry put us at the wheel; sit where the host
        -- seated us (the attachment the host replicates says the same)
        local lp = ue.local_pawn()
        if lp and parent_vehicle(lp) == local_seat.vaddr and (local_seat.seat == "passenger" or was == "passenger") then
            local loc, rot = seat_transform(v, local_seat.seat == "passenger")
            if loc then pcall(function() lp:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
        end
    end
    if local_seat.seat == "passenger" then
        log.say("veh_passenger", "info", 5, f[2] or "?")
    elseif was == "passenger" then
        log.say("veh_driver_now", "info", 4)
    end
    seat_log("this player", local_seat.vname, local_seat.seat,
        "the host's answer" .. ((f[2] and f[2] ~= "") and ("; " .. f[2] .. " drives") or "") .. "; was " .. tostring(was))
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

-- VSTATE|x|y|z|class|colour|fuel|health|lights|engine|driver
local function on_vstate(f)
    if not client_ready() or not on("vehicle_state") then return end
    local v = vehicle_at(tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), f[4], MATCH_M)
    if not v then return end
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
    end
    M.stats.states_applied = M.stats.states_applied + 1
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
    end
    local hp, maxh = health_of(v)
    if hp and ap.health and hp > ap.health + 0.5 then
        local add = hp - ap.health
        local ok = to_host("VREPAIR", v, string.format("%.1f", hp), string.format("%.1f", add))
        log.info("vehicles: repair: this player repaired %s here: %.0f -> %.0f of %.0f (+%.0f; %s), %s",
            ue.short(v), ap.health, hp, maxh or -1, add, why, ok and "sent to the host" or "NOT sent (no connection)")
        ap.health, ap.raised_at, sent = hp, t, true
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
    if ue.valid(pa) and addr(pa) == va then return end
    local is_local = locally_controlled(ch)
    if is_local then apply(function() ch:ResetVehicleCameraArmLength() end) end
    char_out(ch)
    local cmc = ue.prop(ch, "CharacterMovement")
    if ue.valid(cmc) then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
    forget_att(ch)
    M.stats.stray_vi = M.stats.stray_vi + 1
    log.warn("vehicles: seat: the game's get-in step VehicleInteraction(true) for %s reached %s, who does not sit in it (attached to %s) -> undone: no driving state, walking again (else it stood beside the car without control until a second press)",
        ue.short(v), is_local and "the host" or char_label(ch), ue.valid(pa) and ue.short(pa) or "nothing")
end

local function on_lights_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if not v then return end
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
    if S and S.role == "client" then
        if host_cap and in_local_seat(v) then to_host("VHORN", v) end
    elseif host_live() then
        host_horn_broadcast(v, nil)
    end
end

local function on_flip_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if v and S and S.role == "client" and host_cap and in_local_seat(v, DRIVING) then to_host("VFLIP", v) end
end

local function on_tow_post(self_p)
    if applying > 0 or not enabled() then return end
    local v = hook_self(self_p)
    if v and S and S.role == "client" and host_cap and in_local_seat(v, DRIVING) then
        to_host("VTOW", v, ue.prop(v, "TowingVehicle?") == true and "1" or "0")
    end
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

function buy.hook_spawn()
    if buy.spawn_hooked or not ue.hook_native then return end
    buy.spawn_hooked = true
    local ok, err = ue.hook_native(buy.SPAWN_FN, "vehicles.buy", safe("buy-spawn", buy.on_spawn))
    log.info("vehicles: trader spawn hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
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
    local kind = fx.kind_of(ue.try(function() return ue.str(opt_p:get().TagName) end))
    if not kind then return end
    local lp = ue.local_pawn()
    local who = get(actor_p)
    if not (lp and ue.valid(who)) or addr(who) ~= addr(lp) then return end
    local a = addr(v)
    local cur, max
    if kind == "refuel" then cur, max = fuel_of(v) else cur, max = health_of(v) end
    local outcome
    if ue.prop(v, "IsHeld") ~= true then
        -- @17947: IsHeld was already set, so this press only cleared it
        if fx.hold and fx.hold.va == a then
            outcome = "stopped its running hold (the game's second press)"
        else
            outcome = "the game's hold flag was set: this press only cleared it"
        end
        fx.hold = nil
    else
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
            fx.hold = { va = a, vname = ue.short(v), kind = kind, t0 = t, till = t + dur + 1 }
            outcome = string.format("hold started (%.0f s, %s found)", dur, fx.item_name(kind))
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
            if fx.hold and fx.hold.va == a then fx.hold = nil end
            log.warn("vehicles: refuel: the game's UseGasCan ran on %s here (fuel %.0f of %.0f), but the host runs no vehicle sync: not sent",
                ue.short(v), fuel or -1, maxf or -1)
        elseif ap and fx.report(v, ap, "the game's UseGasCan") then
            if fx.hold and fx.hold.va == a then fx.hold = nil end
        else
            -- (its note normally asked already; one ask per hold either way)
            fx.ask(v, "refuel", "the game's UseGasCan added nothing here")
        end
    else
        if fx.hold and fx.hold.va == a then fx.hold = nil end
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
            local h = fx.hold
            local note = ""
            if ended and h and h.va == a then
                fx.hold = nil
                note = string.format("; its %s hold stopped (the game: leaving a box)", h.kind)
            end
            local t = os.clock()
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
        local h = fx.hold
        if h and h.va == a and os.clock() < h.till and ue.prop(v, "IsHeld") ~= true then
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
    if fx.hold and fx.hold.va == a then fx.hold = nil end
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
    if not a then return end
    if not cur.by[a] then discover(true) end
    if not cur.by[a] then return end
    fx.ask(v, kind, "its note '" .. text .. "'")
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
    if not (fx.hold and fx.hold.kind == kind) then fx.timer_off() end
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
--     16:33:10 / 16:37:00; as the driver 34 s / 10 s at 16:52).
--   * Tab itself (UE4SS key bind, seated only): a press after which the
--     IA_Inventory event never ran (the key did not reach the character)
--     gets a line; in the passenger seat, with Tab mapped to IA_Inventory,
--     no modifier, no window / menu / console / cursor up and nothing the
--     game would refuse, the window opens the game's way (ToggleInventory).
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
    bound = false,
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
        c.cause or "no caller seen (not the inventory or interact key, no distance check, no loot / trade window)")
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
-- Gate from Lua state only (no engine call); a stale seat only costs one key
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

function ik.poll_tab()
    if not ik.maybe_seated() then
        ik.tab_down = false
        return
    end
    local pc = ue.local_pc()
    if not pc then return end
    if not ik.TAB_KEY then ik.TAB_KEY = { KeyName = FName("Tab") } end
    local down = ue.try(function() return pc:IsInputKeyDown(ik.TAB_KEY) end) == true
    if down and not ik.tab_down then ik.on_tab() end
    ik.tab_down = down
end

function ik.bind_tab()
    if ik.bound then return end
    ik.bound = true
    log.info("vehicles: inventory key watch on (Tab read on the game thread each frame while seated, no UE4SS key bind)")
end

-- main.lua's frame loop (game thread)
function M.frame_tick()
    local ok, err = pcall(ik.poll_tab)
    if not ok then log.err_throttled("veh.tab", "vehicles: Tab poll: %s", tostring(err)) end
end

local HOOKS = {
    { path = SEATK.helper .. ":TryInteract", cb = on_try_interact_post },
    { path = VEH_PATH .. ":OnExecuteInteract", cb = fx.on_interact },
    { path = VEH_PATH .. ":UseGasCan", cb = fx.on_gascan },
    { path = fx.GFL_NOTE, cb = fx.on_note },
    { path = VEH_PATH .. ":OnBeginFuelInteract", cb = fx.box("refuel", false) },
    { path = VEH_PATH .. ":OnEndFuelInteract", cb = fx.box("refuel", true) },
    { path = VEH_PATH .. ":OnBeginRepairInteract", cb = fx.box("repair", false) },
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
    { path = ik.INTERACT, cb = ik.caller("interact") },
    { path = ik.DISTANCE, cb = ik.caller("distance") },
    { path = ik.LOOT, cb = ik.caller("loot") },
}
-- (a field, not a local: this chunk is at Lua's 200-locals limit)
HOOKS.hooked = {}

local function install_hooks()
    buy.hook_spawn()
    for _, h in ipairs(HOOKS) do
        if not HOOKS.hooked[h.path] and ue.find_object(h.path) then
            local name = h.path:match(":([%w_]+)$")
            local ok, err = pcall(RegisterHook, h.path, safe(name, h.cb))
            HOOKS.hooked[h.path] = true
            log.info("vehicles: hook %s (post) %s%s", name, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
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

-- VSTATE sends that are not a change (the 10 s refresh, a vehicle's first
-- state) are spread over the 0.5 s ticks: all vehicles at once held the host
-- for 10-20 ms every 10 s (130 ms on the first pass after a join). A change
-- (colour, fuel, health, lights, engine, driver) still goes out at once.
local REFRESH_PER_TICK, FIRST_PER_TICK = 3, 8
local refresh_left, first_left = 0, 0
local IDLE_PER_TICK = 4
local idle_turn = 0

-- PlayerIds of the driver and the passenger ("" = free) for VSTATE.
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
    if st.pass_key then
        local pc = remote_pc_of(st.pass_key)
        pid = tostring(pawn_id(pc and ue.pawn_of(pc)) or "")
    elseif host_here and st.host_seat == "passenger" then
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
    local pct = (fuel and maxf and maxf > 0) and math.floor(fuel / maxf * 100) or -1
    local sig = string.format("%d|%d|%d|%s|%s|%s|%s|%s", color, pct, math.floor(hp or -1), tostring(lights), tostring(eng),
        tostring(drv), did, pid)
    if not st.dirty then   -- (a change the hooks reported goes now)
        if st.sig == nil then
            if first_left <= 0 then return end
            first_left = first_left - 1
        elseif sig == st.sig then
            if t - (st.sent_at or -100) < STATE_EVERY_S or refresh_left <= 0 then return end
            refresh_left = refresh_left - 1
        end
    end
    local l = ue.location(v)
    if not l then return end
    st.sig, st.sent_at, st.dirty = sig, t, false
    net.broadcast(S.remote_pcs, "VSTATE", f0(l.X), f0(l.Y), f0(l.Z), st.cls or ue.class_name(v), tostring(color),
        string.format("%.1f", fuel or 0), string.format("%.1f", hp or 0), lights and "1" or "0", eng and "1" or "0", drv and "1" or "0",
        did, pid)
    M.stats.states_sent = M.stats.states_sent + 1
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
    refresh_left, first_left = REFRESH_PER_TICK, FIRST_PER_TICK
    -- an idle vehicle (nobody in or at it, nothing reported) has its state
    -- read in turns, IDLE_PER_TICK a tick (~every 3 s with 25 vehicles); the
    -- others every tick. Reading all of them every 0.5 s was most of the
    -- vehicles task.
    local idle_left = IDLE_PER_TICK
    local n = #cur.list
    idle_turn = (n > 0) and (idle_turn % n) or 0
    for i, v in ipairs(cur.list) do
        if ue.valid(v) then
            local a = addr(v)
            local st = state_for(a, v)
            if st.host_seat and not host_attached(a) and t > (st.host_till or 0) then
                st.host_seat, st.dirty = nil, true
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
                local active = st.dirty or st.sig == nil or st.driver_key or st.pass_key or st.host_seat or occ[a]
                -- idle: its turn (a window of IDLE_PER_TICK positions that moves on every tick)
                local turn = ((i - 1 - idle_turn) % math.max(1, n)) < IDLE_PER_TICK
                if active or (turn and idle_left > 0) then
                    if not active then idle_left = idle_left - 1 end
                    broadcast_state(v, a, st, t)
                end
            end
        end
    end
    idle_turn = idle_turn + IDLE_PER_TICK
    -- forget vehicles that are gone
    for a, st in pairs(vs) do
        if not cur.by[a] and not st.driver_key and not st.pass_key then vs[a] = nil end
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
    for _, v in ipairs(cur.list) do
        if ue.valid(v) and ue.role(v) == ue.ROLE_AUTHORITY then
            local a = addr(v)
            local name = ue.short(v)
            if not occ[a] and ue.is_runtime_spawned(v) then
                if pcall(function() v:K2_DestroyActor() end) then
                    M.stats.ghosts = M.stats.ghosts + 1
                    log.info("vehicles: removed local ghost vehicle %s (spawned on this client only)", name)
                end
            elseif not ghost_logged[name] then
                ghost_logged[name] = true
                log.info("vehicles: client-owned vehicle %s kept (%s)", name, occ[a] and "occupied" or "placed in the level")
            end
        end
    end
end

-- Client: the host says who sits where (VSTATE fields 11 / 12, PlayerIds).
-- A seat the engine did not attach here within SEATK.place_after (an old weld on
-- the host, relevancy) is attached here at the same seat; one the host says
-- is free is let go again. The engine's attachment wins when it comes.

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
            for _, sd in ipairs({ { "driver", ap.occ_d }, { "passenger", ap.occ_p } }) do
                local ch = sd[2] and sd[2] ~= "" and by_id[sd[2]]
                local ca = ch and addr(ch)
                if ca then want[ca] = { ch = ch, v = v, va = a, seat = sd[1] } end
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
                local loc, rot = seat_transform(w.v, w.seat == "passenger")
                pcall(function() w.ch:K2_AttachToActor(w.v, FName("None"), KEEP_WORLD, KEEP_WORLD, KEEP_WORLD, false) end)
                if loc then pcall(function() w.ch:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end) end
                placed[ca] = { va = w.va, vname = ue.short(w.v), name = ue.short(w.ch), at = t }
                log.info("vehicles: pose: %s placed in the %s seat of %s here (the host says so; no attachment arrived for %.1f s)",
                    char_label(w.ch), w.seat, ue.short(w.v), t - missing[ca])
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
    vs, seats, watch_n, outer_cache = {}, {}, 0, {}
    cur = { list = {}, by = {}, at = -100 }
    local_seat, host_cap = nil, false
    applied, obs, att, seated = {}, {}, {}, {}
    cpl.placed, cpl.missing = {}, {}
    spawners_done, ghost_logged = {}, {}
    last_spawner_scan, last_cap = -100, -100
    sit.obj = nil
    buy.seen, buy.blocked = {}, nil
    fx.hold, fx.stuck_since, fx.asked = nil, nil, {}
    ik.key_at, ik.toggle_at, ik.opened_at, ik.close, ik.tab = nil, nil, nil, nil, nil
    M.radio.reset(why)
    log.info("vehicles: reset (%s)", tostring(why))
end

local function tick()
    if not S then return end
    local role = S.role
    if role ~= last_role then
        if last_role ~= nil then M.reset("role " .. tostring(last_role) .. " -> " .. tostring(role)) end
        last_role = role
    end
    if not enabled() then return end
    if role ~= "host" and role ~= "client" then return end
    install_hooks()
    hud.tick()
    if role == "host" then
        host_tick()
    else
        client_tick()
    end
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
    net.on("VSTATE", on_vstate)
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
    log.info("vehicles: installed (vehicle_sync=%s passengers=%s state=%s ghosts=%s radio=%s)", tostring(enabled()),
        tostring(on("vehicle_passengers")), tostring(on("vehicle_state")), tostring(on("vehicle_ghosts")),
        tostring(on("vehicle_radio")))
    ik.bind_tab()
end

function M.status_line()
    local nseats = 0
    for _ in pairs(seats) do nseats = nseats + 1 end
    local s = M.stats
    return string.format("vehicles: %s known=%d seats=%d watched=%d local=%s host_cap=%s | enters=%d passengers=%d exits=%d promoted=%d rejected=%d relays=%d | state sent=%d applied=%d | ghosts=%d spawners=%d buys=%d | stray get-in steps undone=%d stray exits=%d | inventory key in a seat=%d fixed=%d lost=%d | %s",
        tostring(S and S.role), #cur.list, nseats, watch_n,
        local_seat and (local_seat.vname .. ":" .. local_seat.seat) or "-", tostring(host_cap),
        s.enters, s.passengers, s.exits, s.promoted, s.rejected, s.relays, s.states_sent, s.states_applied,
        s.ghosts, s.spawners, s.buys, s.stray_vi, s.stray_exits, s.inv_keys, s.inv_fixed, s.inv_lost,
        M.radio.status())
end

-- Test access (mock harness).
M._t = {
    resolve = function(w) return my_resolver(w) end,
    seats = function() return seats end,
    vs = function() return vs end,
    local_seat = function() return local_seat end,
    applying = function() return applying end,
    ik = ik,
}

return M
