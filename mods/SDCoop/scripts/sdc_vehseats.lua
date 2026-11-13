-- SDCoop: seats in a vehicle (config vehicle_seats), for sdc_vehicles.
--
-- The game has one seat per vehicle: PlayerLocation, the driver's
-- (BP_VehicleMaster @11537; the same in all 19 vehicle classes). The mod adds
-- the others. Seat numbers:
--   1   the driver's seat (the game's PlayerLocation), every vehicle;
--   2   its mirror across the vehicle's centre line (the front passenger),
--       every vehicle;
--   3+  the rows of M.TABLE[class], in order. A row keeps its number when it
--       is off: sdcoop_seat names a seat by it.
-- A row: side "L" (measured from seat 1) | "R" (from seat 2); x, y, z: cm
--   along the vehicle's axes (x forward, y right, z up) from that seat; yaw:
--   degrees added to the driver seat's yaw (0 = facing forward; benches +90 /
--   -90); pose "car" (Chr_SitInCar) | "floor" (Chr_SittingFloor); exit
--   "d" | "p": the door socket (DriverSide / PassengerSide), moved back by x
--   when x < 0 (a rear seat gets out at the rear door); ready: true = tuned in
--   the game; false = a first guess, used only with vehicle_seats_untuned
--   (to tune it with sdcoop_seat).
-- The seats that count for a player (layout): seat 1 always; seat 2 for the
--   host and, with vehicle_passengers, for a client; seats 3+ only with
--   vehicle_seats on, a ready row (or vehicle_seats_untuned) and, for a
--   client, one that said it knows them (VENTER "s2": an older client gets
--   seats 1-2). "Seat N of M": M = the seats that count for that player, N =
--   its seat's place among them. A newcomer takes the first free one.
-- The seat key (config vehicle_seat_key, G; the user, 13.11: a player stays
--   where it sat and moves only by a key): a passenger's press takes it to
--   the wheel when nobody drives, else to the next free seat after its own
--   in its layout's order, round (M.next_idx); none free: a notice. When the
--   driver gets out nobody is moved.
-- Network (fields built and read here, sent by sdc_vehicles):
--   VSEAT|kind|name|idx|N|M|side|x|y|z|yaw|pose|exit|tell|sw: the host's
--     answer (an older client reads kind / name only; an older host sends
--     kind / name: seat 2, the mirror). tell "0": the same seat again, no
--     notice. sw "sw": the host takes the seat key (VSWITCH); an older host
--     sends no field 14, so the client knows its key does nothing there.
--   VSWITCH|x|y|z|class (client -> host): its seat key (an older host has no
--     handler: ignored). VSWR|kind[|M] (host -> a client that sent "sw" in
--     its VENTER): "wheel" = the driver left, the wheel is free (one notice);
--     "full" = no free seat for its key (M seats); "taken|name" = name took
--     the free wheel just before its press (it stays); "no" = could not
--     move it. A VSEAT passenger with no name: nobody drives.
--   VOCC|*|x|y|z|class|occ ...: the seats 2+ of a vehicle that has someone
--     in a seat 3+, occ = "idx:id:side:x:y:z:yaw:pose;..." (id = PlayerId),
--     next to each VSTATE record of it; an older client has no handler for
--     it (sdc_net skips it). VSTATE itself is unchanged (field 12 = seat 2).
--   The geometry travels with the messages: a client places a seat from the
--   host's numbers (no table needed there; a live tuning reaches everyone).
-- sdcoop_seat (host, or single player): lists the seats of the vehicle the
--   host sits in (or stands at), tunes a row live (until the game quits; a
--   world change keeps it) and prints the rows to paste into M.TABLE
--   ([SEATS] lines in UE4SS.log).

local log = require("sdc_log")
local cfg = require("sdc_config")

local M = {
    MAX = 8,          -- seats per vehicle at most
    LIMIT = 1500,     -- cm: an offset beyond this is a typo (refused / not read)
    NEAR = 40,        -- cm: "sits in that seat" (the command, the check after a move to the wheel)
    edits = {},       -- [class] = rows changed with sdcoop_seat (until the game quits)
    api = nil,        -- sdc_vehicles' pieces (M.attach)
}

-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------

local function row(side, x, y, z, yaw, pose, exit, ready)
    return { side = side, x = x, y = y, z = z, yaw = yaw, pose = pose, exit = exit, ready = ready }
end

-- A rear row: two seats `back` cm behind the front ones, the driver's pose.
local function rear(back, ready)
    return { row("L", back, 0, 0, 0, "car", "d", ready), row("R", back, 0, 0, 0, "car", "p", ready) }
end

-- Floor seats (pickup bed, flatbed, the frame behind a cab): pairs at each x.
local function floor(...)
    local t = {}
    for _, x in ipairs({ ... }) do
        t[#t + 1] = row("L", x, 0, 0, 0, "floor", "d", false)
        t[#t + 1] = row("R", x, 0, 0, 0, "floor", "p", false)
    end
    return t
end

-- Benches along the walls, facing the middle: pairs at each x.
local function benches(...)
    local t = {}
    for _, x in ipairs({ ... }) do
        t[#t + 1] = row("L", x, 0, 0, 90, "car", "d", false)
        t[#t + 1] = row("R", x, 0, 0, -90, "car", "p", false)
    end
    return t
end

-- Stage 1 (ready): the rear row of the six cars, 90 cm behind the front
-- seats (the 4x4's model has a rear seat bone; the others are a guess -
-- tuned in the game with sdcoop_seat). Stage 2 (ready = false: first
-- guesses, only with vehicle_seats_untuned until tuned): pickup beds,
-- flatbed, the BigRig frame (floor pose), benches in vans, ambulance, RV,
-- SWAT van, APC, military truck. No rows (2 seats): Buggy, GolfCart.
M.TABLE = {
    Vehicle_4x4Jeep_C = rear(-90, true),
    Vehicle_DamagedSedan_C = rear(-90, true),
    Vehicle_Charger_C = rear(-90, true),
    Vehicle_Sheriff_C = rear(-90, true),
    Vehicle_SUV_C = rear(-90, true),
    Vehicle_Humvee_C = rear(-90, true),
    Vehicle_PickupTruck_C = floor(-200),
    Vehicle_PickupUtilityTruck_C = floor(-200),
    Vehicle_ModifiedPickupUtilityTruck_C = floor(-200),
    Vehicle_FlatbedTruck_C = floor(-180, -280),
    Vehicle_BigRig_C = floor(-260),
    Vehicle_Van_C = benches(-150, -230),
    Vehicle_Ambulance_C = benches(-150, -230),
    Vehicle_RV_C = benches(-150, -230),
    Vehicle_SwatVan_C = benches(-150, -230),
    Vehicle_APC_C = benches(-250, -330),
    Vehicle_Truck_C = benches(-250, -330),
}

M.SEAT1 = row("L", 0, 0, 0, 0, "car", "d", true)
M.SEAT2 = row("R", 0, 0, 0, 0, "car", "p", true)
local EMPTY = {}

M.TEXT = {
    veh_seat        = { "Seat %d of %d: %s drives.", "Место %d из %d: машину ведёт %s." },
    veh_seat_driver = { "Seat 1 of %d: you drive.", "Место 1 из %d: вы за рулём." },
    veh_full_n      = { "No free seat in this vehicle (%d seats).", "В машине нет свободного места (всего мест: %d)." },
    -- the seat key (sdc_vehicles SEATK.on_key / switch)
    veh_wheel_free  = { "The wheel is free: press %s to move there.", "Руль свободен: нажмите %s, чтобы пересесть." },
    veh_wheel_free_nokey = { "The wheel is free: get out and in again to drive.", "Руль свободен: чтобы вести, выйдите и сядьте снова." },
    veh_switch_none = { "No free seat to move to.", "Пересесть некуда: все места заняты." },
    veh_wheel_taken = { "%s already took the wheel.", "Руль уже занял %s." },
    veh_seat_free   = { "Seat %d of %d: nobody drives.", "Место %d из %d: руль свободен." },
    veh_switch_failed = { "Could not change seats.", "Не получилось пересесть." },
    veh_switch_old_host = { "Seats cannot be changed: the host has an older version of the mod.",
                            "Пересесть нельзя: у хоста старая версия мода." },
}
for k, v in pairs(M.TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end

function M.on() return cfg.get("vehicle_seats") ~= false end
-- (cfg.get gives nil for a key the config file does not have: off)
function M.untuned() return cfg.get("vehicle_seats_untuned") == true end

-- The rows (seats 3+) of a class: the live edits, else the table.
function M.rows(cls)
    return M.edits[cls] or M.TABLE[cls] or EMPTY
end

function M.row(cls, idx)
    if idx == 1 then return M.SEAT1 end
    if idx == 2 then return M.SEAT2 end
    if type(idx) ~= "number" then return nil end
    return M.rows(cls)[idx - 2]
end

local function copy(r)
    if not r then return nil end
    return { side = r.side, x = r.x, y = r.y, z = r.z, yaw = r.yaw, pose = r.pose, exit = r.exit, ready = r.ready }
end

-- A copy of seat idx's geometry (a seated player keeps its own copy: a row
-- changed or switched off later does not move it), or nil.
function M.geo(cls, idx)
    return copy(M.row(cls, idx))
end

local function finite(n, lim) return type(n) == "number" and n == n and math.abs(n) <= lim end

function M.valid_row(r)
    return type(r) == "table" and (r.side == "L" or r.side == "R") and finite(r.x, M.LIMIT) and finite(r.y, M.LIMIT)
        and finite(r.z, M.LIMIT) and finite(r.yaw, 360) and (r.pose == "car" or r.pose == "floor")
        and (r.exit == "d" or r.exit == "p") and type(r.ready) == "boolean"
end

-- The seats that count for one player in a vehicle of class cls.
-- opts: host (the host itself), cap (a client that knows seats 3+),
-- passengers (vehicle_passengers on). Returns { list, count, rank[idx] }.
function M.layout(cls, opts)
    opts = opts or {}
    local list = { 1 }
    if opts.host or opts.passengers then list[2] = 2 end
    if #list == 2 and M.on() and (opts.host or opts.cap) then
        local untuned = M.untuned()
        for i, r in ipairs(M.rows(cls)) do
            if i + 2 > M.MAX then break end
            if r.ready or untuned then list[#list + 1] = i + 2 end
        end
    end
    local rank = {}
    for i, idx in ipairs(list) do rank[idx] = i end
    return { list = list, count = #list, rank = rank }
end

-- ---------------------------------------------------------------------------
-- Who sits where (the host's vehicle record st: st.pax[idx] = client key,
-- st.host_seat = "driver" | "passenger", st.host_idx = the host's seat)
-- ---------------------------------------------------------------------------

function M.host_idx(st)
    if st.host_seat ~= "passenger" then return nil end
    return st.host_idx or 2
end

-- Seat idx has someone (`for_host`: the host's own seat does not count: its
-- get-in asks for a seat).
function M.taken(st, idx, for_host)
    if st.pax and st.pax[idx] ~= nil then return true end
    return not for_host and M.host_idx(st) == idx
end

-- The first free passenger seat (2..) that counts for this player, or nil.
function M.free_idx(st, cls, opts)
    local lay = M.layout(cls, opts)
    for _, idx in ipairs(lay.list) do
        if idx >= 2 and not M.taken(st, idx, opts and opts.host) then return idx, lay end
    end
    return nil, lay
end

-- Where a passenger's seat key takes it (cur: its seat now): the wheel (1)
-- when `wheel` (nobody drives and it may take it), else the next free seat
-- after cur in the order of its layout, round (a seat not in the layout:
-- from the start); nil = none free. Also the layout.
function M.next_idx(st, cls, opts, cur, wheel)
    local lay = M.layout(cls, opts)
    if wheel then return 1, lay end
    local list, n = lay.list, #lay.list
    local p0 = lay.rank[cur] or 0
    for i = 1, n do
        local idx = list[(p0 - 1 + i) % n + 1]
        if idx >= 2 and idx ~= cur and not M.taken(st, idx, opts and opts.host) then return idx, lay end
    end
    return nil, lay
end

function M.any(st)
    return st.pax ~= nil and next(st.pax) ~= nil
end

-- The passengers by seat: { { idx, who = client key | "host" }, ... }.
function M.occupants(st)
    local out = {}
    for idx, key in pairs(st.pax or EMPTY) do out[#out + 1] = { idx = idx, who = key } end
    local h = M.host_idx(st)
    if h and not (st.pax and st.pax[h]) then out[#out + 1] = { idx = h, who = "host" } end
    table.sort(out, function(a, b) return a.idx < b.idx end)
    return out
end

-- Somebody sits in a seat 3+ (behind the front row): in the host's record
-- st, or in a client's VOCC list (parse_occ). The camera boom of a front
-- seat passes through the players there (sdc_vehicles SEATK.cam).
function M.rear_taken(st)
    for idx in pairs(st.pax or EMPTY) do
        if idx >= 3 then return true end
    end
    local h = M.host_idx(st)
    return h ~= nil and h >= 3
end

function M.rear_listed(occ)
    for _, o in ipairs(occ or EMPTY) do
        if (tonumber(o.idx) or 0) >= 3 then return true end
    end
    return false
end

-- The client in the lowest passenger seat: idx, key.
function M.first(st)
    local bi, bk = nil, nil
    for idx, key in pairs(st.pax or EMPTY) do
        if not bi or idx < bi then bi, bk = idx, key end
    end
    return bi, bk
end

function M.idx_of(st, key)
    for idx, k in pairs(st.pax or EMPTY) do
        if k == key then return idx end
    end
    return nil
end

-- Client `key` out of its passenger seat: the seat number, or nil.
function M.drop(st, key)
    local idx = M.idx_of(st, key)
    if idx then st.pax[idx] = nil end
    return idx
end

function M.set(st, idx, key)
    st.pax = st.pax or {}
    M.drop(st, key)
    st.pax[idx] = key
end

-- ---------------------------------------------------------------------------
-- Where a seat is in the world
-- ---------------------------------------------------------------------------

local function axis(v, fn)
    local ok, r = pcall(function() return v[fn](v) end)
    if not ok or r == nil then return nil end
    local ok2, x, y, z = pcall(function() return r.X, r.Y, r.Z end)
    if ok2 and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end
M.axis = axis

local function norm_yaw(y)
    y = y % 360
    if y > 180 then y = y - 360 end
    return y
end

-- The world location / rotation of a seat with this geometry on vehicle v:
-- seats 1 / 2 exactly as sdc_vehicles' seat_transform (PlayerLocation / its
-- mirror), the others from there along the vehicle's own axes.
function M.xf_geo(v, geo)
    local base = M.api and M.api.seat_transform
    if not (base and geo) then return nil, nil end
    local loc, rot = base(v, geo.side == "R")
    if not loc then return nil, nil end
    local x, y, z = tonumber(geo.x) or 0, tonumber(geo.y) or 0, tonumber(geo.z) or 0
    if x ~= 0 or y ~= 0 or z ~= 0 then
        local f = x ~= 0 and axis(v, "GetActorForwardVector") or nil
        local r = y ~= 0 and axis(v, "GetActorRightVector") or nil
        local u = z ~= 0 and axis(v, "GetActorUpVector") or nil
        if (x ~= 0 and not f) or (y ~= 0 and not r) or (z ~= 0 and not u) then return nil, nil end
        local o = { X = 0, Y = 0, Z = 0 }
        for _, p in ipairs({ { f, x }, { r, y }, { u, z } }) do
            if p[1] then
                o.X, o.Y, o.Z = o.X + p[1].X * p[2], o.Y + p[1].Y * p[2], o.Z + p[1].Z * p[2]
            end
        end
        loc = { X = loc.X + o.X, Y = loc.Y + o.Y, Z = loc.Z + o.Z }
    end
    rot = { Pitch = rot.Pitch or 0, Yaw = norm_yaw((rot.Yaw or 0) + (tonumber(geo.yaw) or 0)), Roll = 0 }
    return loc, rot
end

function M.xf(v, cls, idx)
    return M.xf_geo(v, M.geo(cls, idx))
end

-- ---------------------------------------------------------------------------
-- Network fields
-- ---------------------------------------------------------------------------

-- A number as text: whole cm when whole, one decimal otherwise.
local function ns(n)
    local s = string.format("%.1f", tonumber(n) or 0):gsub("%.0$", "")
    if s == "-0" then s = "0" end
    return s
end
M.ns = ns

local function int_in(s, lo, hi)
    local n = tonumber(s)
    if not n or n ~= math.floor(n) or n < lo or n > hi then return nil end
    return math.floor(n)
end

-- geometry from text fields (side, x, y, z, yaw, pose[, exit]) or nil
local function geo_of(side, x, y, z, yaw, pose, exit)
    local g = { side = side, x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw), pose = pose,
                exit = exit, ready = true }
    if g.exit ~= "d" and g.exit ~= "p" then g.exit = (side == "R") and "p" or "d" end
    if not M.valid_row(g) then return nil end
    return g
end

-- VSEAT fields 3.. (after kind and name): idx, N, M, the seat's geometry,
-- tell ("0": the same seat again, no notice), "sw" (this host takes the
-- seat key).
function M.vseat_fields(idx, n, m, geo, tell)
    geo = geo or M.SEAT1
    return { tostring(idx), tostring(n or idx), tostring(m or ""), geo.side, ns(geo.x), ns(geo.y), ns(geo.z),
             ns(geo.yaw), geo.pose, geo.exit or ((geo.side == "R") and "p" or "d"), tell == false and "0" or "1", "sw" }
end

-- A VSEAT from the host: { idx, n, m, geo, tell, sw }, or nil (an older
-- host: kind and name only). sw: the host takes the seat key.
function M.parse_vseat(f)
    local idx = int_in(f[3], 1, M.MAX)
    if not idx then return nil end
    local p = { idx = idx, n = int_in(f[4], 1, M.MAX) or idx, m = int_in(f[5], 1, M.MAX), tell = f[13] ~= "0",
                sw = f[14] == "sw" }
    p.geo = geo_of(f[6], f[7], f[8], f[9], f[10], f[11], f[12])
    return p
end

-- One VOCC seat: "idx:id:side:x:y:z:yaw:pose".
function M.occ_entry(idx, id, geo)
    return table.concat({ tostring(idx), tostring(id), geo.side, ns(geo.x), ns(geo.y), ns(geo.z), ns(geo.yaw), geo.pose }, ":")
end

-- VOCC's list: { { idx, id, geo }, ... } (bad entries skipped).
function M.parse_occ(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for e in s:gmatch("[^;]+") do
        local p = {}
        for part in (e .. ":"):gmatch("(.-):") do p[#p + 1] = part end
        local idx = int_in(p[1], 2, M.MAX)
        local id = p[2]
        local g = #p == 8 and geo_of(p[3], p[4], p[5], p[6], p[7], p[8]) or nil
        if idx and type(id) == "string" and id:match("^%d+$") and g then
            out[#out + 1] = { idx = idx, id = id, geo = g }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- sdcoop_seat: tune the seats live
-- ---------------------------------------------------------------------------

local function row_text(r)
    return string.format('{ side = "%s", x = %s, y = %s, z = %s, yaw = %s, pose = "%s", exit = "%s", ready = %s }',
        r.side, ns(r.x), ns(r.y), ns(r.z), ns(r.yaw), r.pose, r.exit, tostring(r.ready == true))
end
M.row_text = row_text

-- The line of M.TABLE for a class, ready to paste.
function M.table_line(cls)
    local parts = {}
    for _, r in ipairs(M.rows(cls)) do parts[#parts + 1] = row_text(r) end
    return string.format("    %s = { %s },", cls, table.concat(parts, ", "))
end

-- The rows of a class, editable (a copy of the table's on the first change).
local function edit_rows(cls)
    local e = M.edits[cls]
    if not e then
        e = {}
        for i, r in ipairs(M.TABLE[cls] or EMPTY) do e[i] = copy(r) end
        M.edits[cls] = e
    end
    return e
end
M.edit_rows = edit_rows

-- Every change is written to UE4SS.log at once ([SEATS]): a tuning the
-- player forgot to print is still there.
local function log_line(cls, what)
    log.info("[SEATS] %s: %s", cls, what)
    log.info("[SEATS] %s", M.table_line(cls))
end

local function str(p)
    if type(p) == "string" then return p end
    local ok, s = pcall(function() return require("sdc_ue").str(p) end)
    if ok and type(s) == "string" then return s end
    return tostring(p)
end

local USAGE = "sdcoop_seat [print | reset | add [n] | del | <n> <x> <y> <z> | <n> move <dx> <dy> <dz> | <n> side L|R"
    .. " | <n> yaw <deg> | <n> pose car|floor | <n> exit d|p | <n> on|off | <n> try]"

-- The vehicle's seats as text, one line each, and the counts.
function M.list(a, v, va, cls, st, reply)
    reply(string.format("%s: seats 1 (driver) and 2 (front passenger) always; rows 3+ below (vehicle_seats=%s, untuned=%s%s)",
        cls, tostring(M.on()), tostring(M.untuned()), M.edits[cls] and ", live edits" or ""))
    for idx = 1, 2 + #M.rows(cls) do
        local r = M.row(cls, idx)
        local who = a.who_at(v, va, st, idx, M.geo(cls, idx))
        reply(string.format("  %d: %s%s", idx, idx <= 2 and (idx == 1 and "driver (the game's seat)" or "mirror of 1")
            or row_text(r), who and ("  <- " .. who) or ""))
    end
    reply(string.format("  seats now: host %d, a new client %d, an older client %d",
        M.layout(cls, { host = true }).count, M.layout(cls, { cap = true, passengers = cfg.get("vehicle_passengers") ~= false }).count,
        M.layout(cls, { passengers = cfg.get("vehicle_passengers") ~= false }).count))
end

function M.command(params, reply)
    local a = M.api
    if not a then return reply("vehicles not installed") end
    local role = a.role()
    if role ~= "host" and role ~= "standalone" then return reply("sdcoop_seat: host only (or single player)") end
    local v, va, cls, st = a.cmd_vehicle()
    if not v then return reply("sdcoop_seat: no vehicle (sit in one, or stand within 8 m of one)") end
    local args = {}
    for i = 1, #(params or EMPTY) do args[#args + 1] = str(params[i]) end
    local w1 = args[1] and args[1]:lower() or nil
    if not w1 then return M.list(a, v, va, cls, st, reply) end
    if w1 == "print" then
        reply("[SEATS] rows to paste into sdc_vehseats.lua M.TABLE:")
        reply("[SEATS] " .. M.table_line(cls))
        return
    end
    if w1 == "help" then return reply(USAGE) end
    if w1 == "reset" then
        local had = M.edits[cls] ~= nil
        local sit = {}
        for idx = 3, 2 + #M.rows(cls) do
            local _, wid = a.who_at(v, va, st, idx, M.geo(cls, idx))
            sit[idx] = wid
        end
        M.edits[cls] = nil
        for idx, wid in pairs(sit) do
            local g = M.geo(cls, idx)
            if g then a.place(v, va, st, idx, g, wid) end
        end
        log_line(cls, "live edits dropped")
        return reply(had and ("live edits of " .. cls .. " dropped") or ("no live edits of " .. cls))
    end
    if w1 == "add" then
        local rows = edit_rows(cls)
        if #rows + 2 >= M.MAX then return reply("sdcoop_seat: at most " .. M.MAX .. " seats") end
        local n = int_in(args[2], 3, 2 + #rows)
        local r = n and copy(rows[n - 2]) or row("L", -90, 0, 0, 0, "car", "d", true)
        r.ready = true
        rows[#rows + 1] = r
        log_line(cls, "row " .. (#rows + 2) .. " added")
        return reply(string.format("seat %d added: %s", #rows + 2, row_text(r)))
    end
    if w1 == "del" then
        local rows = M.rows(cls)
        if #rows == 0 then return reply("sdcoop_seat: no rows to remove") end
        local idx = #rows + 2
        local who = a.who_at(v, va, st, idx, M.geo(cls, idx))
        if who then return reply(string.format("sdcoop_seat: seat %d is taken (%s): not removed", idx, who)) end
        rows = edit_rows(cls)
        rows[#rows] = nil
        log_line(cls, "row " .. idx .. " removed")
        return reply("seat " .. idx .. " removed")
    end
    local n = int_in(args[1], 1, M.MAX)
    if not n then return reply(USAGE) end
    local w2 = args[2] and args[2]:lower() or nil
    if w2 == "try" then
        if not M.row(cls, n) then return reply("sdcoop_seat: no seat " .. n) end
        local ok, text = a.try(v, va, st, n, M.geo(cls, n))
        return reply((ok and "" or "sdcoop_seat: ") .. tostring(text))
    end
    if n < 3 or not M.row(cls, n) then
        return reply(string.format("sdcoop_seat: seat %d cannot be changed (1 and 2 come from the game's seat; rows: 3..%d)",
            n, 2 + #M.rows(cls)))
    end
    local old = M.geo(cls, n)
    local who, wid = a.who_at(v, va, st, n, old)
    local r = edit_rows(cls)[n - 2]
    local nums = { tonumber(args[2]), tonumber(args[3]), tonumber(args[4]) }
    local what
    if nums[1] and nums[2] and nums[3] then
        r.x, r.y, r.z = nums[1], nums[2], nums[3]
        what = "set"
    elseif w2 == "move" and tonumber(args[3]) and tonumber(args[4]) and tonumber(args[5]) then
        r.x, r.y, r.z = r.x + tonumber(args[3]), r.y + tonumber(args[4]), r.z + tonumber(args[5])
        what = "moved"
    elseif w2 == "side" and args[3] and (args[3]:upper() == "L" or args[3]:upper() == "R") then
        r.side = args[3]:upper()
        what = "side"
    elseif w2 == "yaw" and tonumber(args[3]) then
        r.yaw = norm_yaw(tonumber(args[3]))
        what = "yaw"
    elseif w2 == "pose" and (args[3] == "car" or args[3] == "floor") then
        r.pose = args[3]
        what = "pose"
    elseif w2 == "exit" and (args[3] == "d" or args[3] == "p") then
        r.exit = args[3]
        what = "exit"
    elseif w2 == "on" or w2 == "off" then
        r.ready = w2 == "on"
        what = w2
    else
        return reply(USAGE)
    end
    if not M.valid_row(r) then
        -- out of bounds: back as it was
        local e = edit_rows(cls)
        e[n - 2] = old
        return reply(string.format("sdcoop_seat: refused (offsets up to %d cm, yaw up to 360): %s", M.LIMIT, row_text(old)))
    end
    local moved = ""
    if who and what ~= "on" and what ~= "off" then moved = "; " .. tostring(a.place(v, va, st, n, M.geo(cls, n), wid)) end
    log_line(cls, string.format("seat %d %s", n, what))
    reply(string.format("seat %d: %s%s", n, row_text(r), moved))
end

function M.register_commands(add)
    add("sdcoop_seat", "host / single player: vehicle seats - list, tune live, print the table rows ("
        .. USAGE .. ")", function(params, reply) M.command(params, reply) end)
end

-- ---------------------------------------------------------------------------
-- Life cycle
-- ---------------------------------------------------------------------------

-- sdc_vehicles' pieces: seat_transform, role, cmd_vehicle, who_at, place, try.
function M.attach(api)
    M.api = api
end

-- A world change / role change: nothing here is per world. The live edits
-- stay until the game quits (a host tuning alone keeps them when it opens
-- the world to friends).
function M.reset(why)
end

function M.status()
    local n = 0
    for _ in pairs(M.edits) do n = n + 1 end
    return string.format("seats=%s untuned=%s edited classes=%d", tostring(M.on()), tostring(M.untuned()), n)
end

return M
