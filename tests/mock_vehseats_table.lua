-- Pure checks of sdc_vehseats: the seat table per vehicle class, which seats
-- count for whom, the free seat, the seat key's next seat, the world position of a seat, the VSEAT /
-- VOCC fields, and the console command sdcoop_seat (tuning, print).
-- usage: lua mock_vehseats_table.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, passes = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end
local function vnear(a, b, eps)
    return a and b and near(a.X, b.X, eps) and near(a.Y, b.Y, eps) and near(a.Z, b.Z, eps)
end

local cfg = require("sdc_config")
cfg.load(os.tmpname())
local log = require("sdc_log")
local lines = {}
local info0 = log.info
log.info = function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    lines[#lines + 1] = ok and s or fmt
end
local VS = require("sdc_vehseats")

local ALL = { "Vehicle_4x4Jeep_C", "Vehicle_APC_C", "Vehicle_Ambulance_C", "Vehicle_BigRig_C", "Vehicle_Buggy_C",
    "Vehicle_Charger_C", "Vehicle_DamagedSedan_C", "Vehicle_FlatbedTruck_C", "Vehicle_GolfCart_C", "Vehicle_Humvee_C",
    "Vehicle_ModifiedPickupUtilityTruck_C", "Vehicle_PickupTruck_C", "Vehicle_PickupUtilityTruck_C", "Vehicle_RV_C",
    "Vehicle_SUV_C", "Vehicle_Sheriff_C", "Vehicle_SwatVan_C", "Vehicle_Truck_C", "Vehicle_Van_C" }
local FOUR = { Vehicle_4x4Jeep_C = true, Vehicle_DamagedSedan_C = true, Vehicle_Charger_C = true,
    Vehicle_Sheriff_C = true, Vehicle_SUV_C = true, Vehicle_Humvee_C = true }
-- with vehicle_seats_untuned (stage 2 first guesses)
local UNTUNED = { Vehicle_PickupTruck_C = 4, Vehicle_PickupUtilityTruck_C = 4, Vehicle_ModifiedPickupUtilityTruck_C = 4,
    Vehicle_FlatbedTruck_C = 6, Vehicle_BigRig_C = 4, Vehicle_Van_C = 6, Vehicle_Ambulance_C = 6, Vehicle_RV_C = 6,
    Vehicle_SwatVan_C = 6, Vehicle_APC_C = 6, Vehicle_Truck_C = 6, Vehicle_Buggy_C = 2, Vehicle_GolfCart_C = 2 }
local function count(cls, opts) return VS.layout(cls, opts).count end
local HOST, NEW, OLD, NOPASS = { host = true }, { cap = true, passengers = true }, { passengers = true }, { cap = true }

-- ------------------------------------------------------------ 1. capacity
print("1. capacity of the 19 classes")
check(#ALL == 19, "1: 19 classes")
do
    local ok_def, ok_old, ok_nopass, ok_max = true, true, true, true
    for _, cls in ipairs(ALL) do
        local want = FOUR[cls] and 4 or 2
        if count(cls, HOST) ~= want or count(cls, NEW) ~= want then ok_def = false; print("    " .. cls) end
        if count(cls, OLD) ~= 2 then ok_old = false end
        if count(cls, NOPASS) ~= 1 then ok_nopass = false end
    end
    check(ok_def, "1: defaults: the six cars 4 seats (host and a new client), the other 13 classes 2")
    check(ok_old, "1: a client without s2 (older mod): 2 seats everywhere")
    check(ok_nopass, "1: vehicle_passengers off: a client gets the wheel only")
    cfg.set("vehicle_seats_untuned", true)
    local ok_unt = true
    for _, cls in ipairs(ALL) do
        local want = FOUR[cls] and 4 or UNTUNED[cls]
        if count(cls, HOST) ~= want or count(cls, NEW) ~= want then ok_unt = false; print("    " .. cls .. " " .. count(cls, HOST)) end
        if count(cls, HOST) > VS.MAX then ok_max = false end
    end
    check(ok_unt, "1: untuned on: pickups 4, flatbed 6, BigRig 4, vans / ambulance / RV / SWAT / APC / truck 6, Buggy and golf cart 2")
    check(ok_max, "1: never more than " .. VS.MAX .. " seats")
    cfg.set("vehicle_seats", false)
    local ok_off = true
    for _, cls in ipairs(ALL) do
        if count(cls, HOST) ~= 2 or count(cls, NEW) ~= 2 then ok_off = false end
    end
    check(ok_off, "1: vehicle_seats off: 2 everywhere (untuned too)")
    cfg.set("vehicle_seats", true)
    cfg.set("vehicle_seats_untuned", false)
    check(count("Vehicle_Unknown_C", HOST) == 2 and count("", NEW) == 2, "1: an unknown class: 2 seats")
    check(count("Vehicle_Buggy_C", HOST) == 2 and #VS.rows("Vehicle_Buggy_C") == 0 and #VS.rows("Vehicle_GolfCart_C") == 0,
        "1: Buggy / golf cart: no rows")
end

-- ------------------------------------------------------------ 2. rows
print("2. every row of the table")
do
    local ok, ok_ready, ok_pose, ok_exit = true, true, true, true
    for cls, rows in pairs(VS.TABLE) do
        for i, r in ipairs(rows) do
            if not VS.valid_row(r) then ok = false; print("    bad " .. cls .. " " .. i) end
            if (r.ready == true) ~= (FOUR[cls] == true) then ok_ready = false end
            local floorcls = cls:find("Pickup") or cls:find("Flatbed") or cls:find("BigRig")
            if (r.pose == "floor") ~= (floorcls ~= nil) then ok_pose = false end
            if (r.side == "L" and r.exit ~= "d") or (r.side == "R" and r.exit ~= "p") then ok_exit = false end
        end
    end
    check(ok, "2: every row valid (side L/R, numbers in bounds, pose car/floor, exit d/p, ready boolean)")
    check(ok_ready, "2: ready exactly in the six cars (stage 1); the rest first guesses (stage 2)")
    check(ok_pose, "2: floor pose in pickup beds, flatbed and BigRig; car pose elsewhere")
    check(ok_exit, "2: left rows exit at the driver door, right rows at the passenger door")
    local r3 = VS.row("Vehicle_SUV_C", 3)
    check(r3 and r3.x == -90 and r3.side == "L" and VS.row("Vehicle_SUV_C", 4).side == "R", "2: SUV rear row 90 cm back, L then R")
    local b = VS.TABLE.Vehicle_Van_C
    check(b[1].yaw == 90 and b[2].yaw == -90, "2: van benches face the middle (+90 / -90)")
    check(not VS.valid_row({ side = "L", x = 0 / 0, y = 0, z = 0, yaw = 0, pose = "car", exit = "d", ready = true })
        and not VS.valid_row({ side = "Q", x = 0, y = 0, z = 0, yaw = 0, pose = "car", exit = "d", ready = true })
        and not VS.valid_row({ side = "L", x = 5000, y = 0, z = 0, yaw = 0, pose = "car", exit = "d", ready = true }),
        "2: NaN, a bad side, an offset beyond the limit: not valid")
    local g = VS.geo("Vehicle_SUV_C", 3)
    g.x = 123
    check(VS.row("Vehicle_SUV_C", 3).x == -90, "2: geo() is a copy (a seated player's copy never changes the table)")
end

-- ------------------------------------------------------------ 3. position of a seat
print("3. seat positions on a turned and tilted vehicle")
do
    local yaw, pitch = math.rad(30), math.rad(5)
    local cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    local F = { X = cp * cy, Y = cp * sy, Z = sp }
    local R = { X = -sy, Y = cy, Z = 0 }
    local U = { X = -sp * cy, Y = -sp * sy, Z = cp }
    local PL = { X = 1000, Y = 2000, Z = 300 }
    local PL2 = { X = 1000 + 90 * R.X, Y = 2000 + 90 * R.Y, Z = 300 }
    local v = {
        GetActorForwardVector = function() return F end,
        GetActorRightVector = function() return R end,
        GetActorUpVector = function() return U end,
    }
    local base_calls = {}
    VS.attach({ seat_transform = function(_, passenger)
        base_calls[#base_calls + 1] = passenger
        return passenger and PL2 or PL, { Pitch = 5, Yaw = 30, Roll = 0 }
    end })
    local function add(a, d, k) return { X = a.X + d.X * k, Y = a.Y + d.Y * k, Z = a.Z + d.Z * k } end
    local l1, r1 = VS.xf(v, "Vehicle_SUV_C", 1)
    local l2 = VS.xf(v, "Vehicle_SUV_C", 2)
    local l3, r3 = VS.xf(v, "Vehicle_SUV_C", 3)
    local l4 = VS.xf(v, "Vehicle_SUV_C", 4)
    check(vnear(l1, PL) and r1.Yaw == 30 and r1.Pitch == 5, "3: seat 1 = the driver seat (PlayerLocation), its rotation")
    check(vnear(l2, PL2), "3: seat 2 = its mirror")
    check(vnear(l3, add(PL, F, -90)), "3: seat 3 = seat 1 - 90 along the vehicle's forward (yaw 30, pitch 5)")
    check(vnear(l4, add(PL2, F, -90)), "3: seat 4 = seat 2 - 90 along the vehicle's forward")
    check(r3.Yaw == 30, "3: a rear seat faces forward")
    local lz = VS.xf_geo(v, { side = "L", x = -90, y = 10, z = 20, yaw = 90, pose = "car" })
    check(vnear(lz, add(add(add(PL, F, -90), R, 10), U, 20)), "3: y along the right vector, z along the vehicle's up")
    local _, rb = VS.xf_geo(v, { side = "R", x = -150, y = 0, z = 0, yaw = -90, pose = "car" })
    local _, rb2 = VS.xf_geo(v, { side = "L", x = -150, y = 0, z = 0, yaw = 170, pose = "car" })
    check(rb.Yaw == -60 and rb2.Yaw == -160, "3: bench yaw added to the seat's, kept in -180..180")
    local nov = { GetActorRightVector = function() return R end }
    check(VS.xf_geo(nov, VS.geo("Vehicle_SUV_C", 3)) == nil and vnear(VS.xf_geo(nov, VS.geo("Vehicle_SUV_C", 2)), PL2),
        "3: no forward vector: no position for a rear seat (none made up); seats 1-2 need none")
    check(VS.xf(v, "Vehicle_SUV_C", 9) == nil, "3: a seat the class does not have: nil")
end

-- ------------------------------------------------------------ 4. the free seat
print("4. the first free seat")
do
    local SUV = "Vehicle_SUV_C"
    local st = { pax = {} }
    check(VS.free_idx(st, SUV, NEW) == 2, "4: empty car: seat 2 first")
    st.pax[2] = "B"
    check(VS.free_idx(st, SUV, NEW) == 3 and VS.free_idx(st, SUV, OLD) == nil, "4: seat 2 taken: a new client 3, an older one none")
    st.pax[3] = "C"
    check(VS.free_idx(st, SUV, NEW) == 4, "4: then 4")
    st.host_seat, st.host_idx = "passenger", 4
    check(VS.free_idx(st, SUV, NEW) == nil, "4: host in 4: full for a client")
    check(VS.free_idx(st, SUV, HOST) == 4, "4: the host's own seat does not count as taken for the host's get-in")
    st.pax[3] = nil
    st.host_idx = 3
    check(VS.free_idx(st, SUV, NEW) == 4 and VS.taken(st, 3) and not VS.taken(st, 3, true), "4: host in 3: the next client gets 4")
    st.host_idx = nil
    check(VS.host_idx(st) == 2 and VS.taken(st, 2), "4: a host passenger without a seat number is in seat 2 (older records)")
    -- a row switched off in the middle
    local e = VS.edit_rows(SUV)
    e[1].ready = false
    local lay = VS.layout(SUV, NEW)
    check(lay.count == 3 and lay.rank[4] == 3 and lay.rank[3] == nil, "4: row 3 off: 3 seats, seat 4 is 'seat 3 of 3'")
    local st2 = { pax = { [2] = "B" } }
    check(VS.free_idx(st2, SUV, NEW) == 4, "4: the switched-off seat is passed over")
    VS.edits[SUV] = nil
    -- occupants / first / drop / set
    local st3 = { pax = { [4] = "D", [2] = "B" }, host_seat = "passenger", host_idx = 3 }
    local o = VS.occupants(st3)
    check(#o == 3 and o[1].idx == 2 and o[1].who == "B" and o[2].who == "host" and o[3].idx == 4, "4: occupants by seat: 2 B, 3 host, 4 D")
    local fi, fk = VS.first(st3)
    check(fi == 2 and fk == "B", "4: the lowest client seat")
    check(VS.drop(st3, "B") == 2 and st3.pax[2] == nil and VS.drop(st3, "nobody") == nil, "4: drop frees the seat")
    VS.set(st3, 2, "D")
    check(st3.pax[2] == "D" and st3.pax[4] == nil and VS.idx_of(st3, "D") == 2, "4: set moves a player (one seat each)")
    check(VS.any(st3) and not VS.any({ pax = {} }) and not VS.any({}), "4: any")
    -- a seat 3+ taken (the camera rule): clients, the host, VOCC lists
    check(not VS.rear_taken({}) and not VS.rear_taken({ pax = { [2] = "B" } })
        and not VS.rear_taken({ pax = { [2] = "B" }, host_seat = "passenger", host_idx = 2 })
        and not VS.rear_taken({ pax = { [2] = "B" }, host_seat = "driver", host_idx = 4 }), "4: rear_taken: none with seats 1-2 only")
    check(VS.rear_taken({ pax = { [3] = "C" } }) and VS.rear_taken({ pax = {}, host_seat = "passenger", host_idx = 4 })
        and not VS.rear_taken({ pax = {}, host_seat = "passenger" }), "4: rear_taken: a client in 3, the host in 4 (the host's seat 2 by default)")
    check(VS.rear_listed({ { idx = 3 } }) and VS.rear_listed({ { idx = 2 }, { idx = 4 } }) and not VS.rear_listed({ { idx = 2 } })
        and not VS.rear_listed({}) and not VS.rear_listed(nil), "4: rear_listed: a VOCC list with a seat 3+")
end

-- ------------------------------------------------------------ 4b. the seat key's next seat
print("4b. the seat key: the wheel when free, else the next free seat after its own, round")
do
    local SUV = "Vehicle_SUV_C"
    local st = { pax = { [2] = "B" } }
    check(VS.next_idx(st, SUV, NEW, 2, true) == 1, "4b: the wheel free: the wheel")
    check(VS.next_idx(st, SUV, NEW, 2, false) == 3, "4b: the wheel taken, seat 2: seat 3")
    st.pax[3] = "C"
    check(VS.next_idx(st, SUV, NEW, 2, false) == 4, "4b: 3 taken: seat 4")
    st.pax[2], st.pax[4] = nil, "B"
    check(VS.next_idx(st, SUV, NEW, 4, false) == 2, "4b: from seat 4: round to seat 2")
    st.pax[2] = "D"
    local idx, lay = VS.next_idx(st, SUV, NEW, 4, false)
    check(idx == nil and lay.count == 4, "4b: all taken: none (4 seats)")
    st = { pax = { [2] = "B" }, host_seat = "passenger", host_idx = 3 }
    check(VS.next_idx(st, SUV, NEW, 2, false) == 4, "4b: the host in seat 3 counts as taken for a client")
    check(VS.next_idx(st, SUV, HOST, 3, false) == 4, "4b: the host itself from seat 3: seat 4")
    st.pax[4] = "D"
    check(VS.next_idx(st, SUV, HOST, 3, false) == nil, "4b: the host: 2 and 4 taken: none")
    -- 2-seat classes, an older client, untuned / switched-off rows
    check(VS.next_idx({ pax = { [2] = "B" } }, "Vehicle_Buggy_C", NEW, 2, false) == nil
        and VS.next_idx({ pax = { [2] = "B" } }, "Vehicle_Buggy_C", NEW, 2, true) == 1, "4b: a buggy: none, or the wheel")
    check(VS.next_idx({ pax = { [2] = "B" } }, SUV, OLD, 2, false) == nil, "4b: a client without s2: seats 1-2 only")
    check(VS.next_idx({ pax = { [2] = "B" } }, "Vehicle_PickupTruck_C", NEW, 2, false) == nil, "4b: untuned bed rows skipped")
    cfg.set("vehicle_seats_untuned", true)
    check(VS.next_idx({ pax = { [2] = "B" } }, "Vehicle_PickupTruck_C", NEW, 2, false) == 3, "4b: untuned on: the bed")
    cfg.set("vehicle_seats_untuned", false)
    local e = VS.edit_rows(SUV)
    e[1].ready = false
    check(VS.next_idx({ pax = { [2] = "B" } }, SUV, NEW, 2, false) == 4, "4b: row 3 off: passed over")
    check(VS.next_idx({ pax = { [3] = "B" } }, SUV, NEW, 3, false) == 2, "4b: sitting in a switched-off seat: from the start of the list")
    VS.edits[SUV] = nil
end

-- ------------------------------------------------------------ 5. VSEAT / VOCC fields
print("5. message fields both ways, garbage skipped")
do
    local g = VS.geo("Vehicle_SUV_C", 4)
    g.z = 4.5
    local f = VS.vseat_fields(4, 4, 4, g, true)
    check(#f == 12 and f[12] == "sw", "5: VSEAT carries 12 fields after kind and name (the last: this host takes the seat key)")
    local msg = { "passenger", "Nick" }
    for _, x in ipairs(f) do msg[#msg + 1] = x end
    local p = VS.parse_vseat(msg)
    check(p and p.idx == 4 and p.n == 4 and p.m == 4 and p.tell == true and p.geo.side == "R" and p.geo.x == -90
        and p.geo.z == 4.5 and p.geo.pose == "car" and p.geo.exit == "p" and p.sw == true, "5: VSEAT passenger round trip (seat 4 of 4, its numbers, the seat key)")
    msg[14] = nil
    check(VS.parse_vseat(msg).sw == false and VS.parse_vseat(msg).idx == 4, "5: a host before the seat key (no field 14): sw false, the seat read as before")
    local fq = VS.vseat_fields(4, 4, 4, g, false)
    local mq = { "passenger", "Nick" }
    for _, x in ipairs(fq) do mq[#mq + 1] = x end
    check(VS.parse_vseat(mq).tell == false, "5: tell 0 (the same seat again)")
    local fd = VS.vseat_fields(1, 1, 4, VS.SEAT1, true)
    local pd = VS.parse_vseat({ "driver", "", table.unpack(fd) })
    check(pd and pd.idx == 1 and pd.m == 4, "5: VSEAT driver: seat 1 of 4")
    check(VS.parse_vseat({ "passenger", "Nick" }) == nil and VS.parse_vseat({ "driver", "" }) == nil,
        "5: an older host's VSEAT (kind, name): no seat fields")
    check(VS.parse_vseat({ "passenger", "x", "99" }) == nil and VS.parse_vseat({ "passenger", "x", "2.5" }) == nil
        and VS.parse_vseat({ "passenger", "x", "abc" }) == nil, "5: a seat number out of range / not whole / not a number: none")
    local pg = VS.parse_vseat({ "passenger", "x", "3", "a", "", "Q", "x", "", "", "", "sofa" })
    check(pg and pg.idx == 3 and pg.n == 3 and pg.m == nil and pg.geo == nil, "5: bad numbers: the seat number kept, no geometry")
    local e = VS.occ_entry(3, 105, VS.geo("Vehicle_SUV_C", 3))
    check(e == "3:105:L:-90:0:0:0:car", "5: VOCC entry text")
    local l = VS.parse_occ(e .. ";" .. VS.occ_entry(2, 104, VS.SEAT2))
    check(#l == 2 and l[1].idx == 3 and l[1].id == "105" and l[1].geo.x == -90 and l[2].idx == 2 and l[2].geo.side == "R",
        "5: VOCC list both ways")
    local bad = VS.parse_occ("3:x:L;99:1:Q:0:0:0:0:car;;:::;3:105:L:-90:0:0:0:sofa;4:106:R:-90:0:0:0:car;1:107:L:0:0:0:0:car;5:1e9:L:0:0:0:0:car")
    check(#bad == 1 and bad[1].idx == 4 and bad[1].id == "106", "5: garbage entries skipped, the good one kept (seat 1 / bad pose / bad id out)")
    check(#VS.parse_occ("") == 0 and #VS.parse_occ(nil) == 0 and #VS.parse_occ(5) == 0, "5: empty / missing list")
    check(VS.ns(4.0) == "4" and VS.ns(-0.04) == "0" and VS.ns(2.25) == "2.2" or VS.ns(2.25) == "2.3", "5: numbers as text")
end

-- ------------------------------------------------------------ 6. sdcoop_seat
print("6. sdcoop_seat: tuning live, print, refusals")
do
    local out = {}
    local function reply(s) out[#out + 1] = s end
    local function last() return out[#out] or "" end
    local function has(pat) for _, s in ipairs(out) do if s:find(pat, 1, true) then return true end end return false end
    local role, who = "host", {}
    local placed, tried = {}, {}
    VS.attach({
        seat_transform = function() return { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 } end,
        role = function() return role end,
        cmd_vehicle = function() return "v", 77, "Vehicle_SUV_C", { pax = {} } end,
        who_at = function(_, _, _, idx) if who[idx] then return who[idx], who[idx] end return nil, nil end,
        place = function(_, _, _, idx, geo, wid) placed[#placed + 1] = { idx = idx, geo = geo, wid = wid }; return "moved" end,
        try = function(_, _, _, idx) tried[#tried + 1] = idx; return true, "the host sits in seat " .. idx end,
    })
    local function cmd(...) out = {}; VS.command({ ... }, reply) end
    cmd()
    check(has("Vehicle_SUV_C") and has("3: { side = \"L\"") and has("seats now: host 4, a new client 4, an older client 2"),
        "6: list: class, rows, the counts")
    who[3] = "Friend2"
    lines = {}
    cmd("3", "-80", "5", "4")
    local r = VS.row("Vehicle_SUV_C", 3)
    check(r.x == -80 and r.y == 5 and r.z == 4, "6: set x y z")
    check(#placed == 1 and placed[1].idx == 3 and placed[1].wid == "Friend2" and placed[1].geo.x == -80,
        "6: the one in that seat moved at once with the new numbers")
    local logged = false
    for _, s in ipairs(lines) do if s:find("[SEATS]", 1, true) and s:find("x = -80", 1, true) then logged = true end end
    check(logged, "6: every change written to UE4SS.log at once ([SEATS] line)")
    check(VS.row("Vehicle_4x4Jeep_C", 3).x == -90 and VS.TABLE.Vehicle_SUV_C[1].x == -90, "6: only this class changes; the table itself is untouched")
    who[3] = nil
    cmd("3", "move", "0", "0", "5")
    check(VS.row("Vehicle_SUV_C", 3).z == 9 and #placed == 1, "6: move adds; nobody there: nobody moved")
    cmd("3", "side", "r")
    cmd("3", "yaw", "45")
    cmd("3", "pose", "floor")
    cmd("3", "exit", "p")
    r = VS.row("Vehicle_SUV_C", 3)
    check(r.side == "R" and r.yaw == 45 and r.pose == "floor" and r.exit == "p", "6: side / yaw / pose / exit")
    cmd("3", "off")
    check(VS.row("Vehicle_SUV_C", 3).ready == false and VS.layout("Vehicle_SUV_C", HOST).count == 3, "6: off: the seat no longer counts")
    cmd("3", "on")
    check(VS.row("Vehicle_SUV_C", 3).ready == true, "6: on")
    cmd("3", "9999", "0", "0")
    check(VS.row("Vehicle_SUV_C", 3).x == -80 and last():find("refused", 1, true), "6: an offset beyond the limit refused, the row unchanged")
    cmd("1", "0", "0", "10")
    check(last():find("cannot be changed", 1, true) ~= nil, "6: seats 1 / 2 cannot be changed")
    cmd("7", "0", "0", "10")
    check(last():find("cannot be changed", 1, true) ~= nil, "6: a seat the class does not have")
    cmd("3", "dance")
    check(last():find("sdcoop_seat [", 1, true) ~= nil, "6: an unknown word: the usage")
    cmd("add")
    check(#VS.rows("Vehicle_SUV_C") == 3 and VS.row("Vehicle_SUV_C", 5).x == -90 and VS.row("Vehicle_SUV_C", 5).ready == true,
        "6: add: a new seat 5 (L, 90 cm back)")
    cmd("add", "3")
    check(#VS.rows("Vehicle_SUV_C") == 4 and VS.row("Vehicle_SUV_C", 6).x == -80 and VS.row("Vehicle_SUV_C", 6).side == "R",
        "6: add 3: a copy of seat 3")
    who[6] = "Friend3"
    cmd("del")
    check(#VS.rows("Vehicle_SUV_C") == 4 and last():find("taken", 1, true) ~= nil, "6: del refused while somebody sits in the last seat")
    who[6] = nil
    cmd("del")
    check(#VS.rows("Vehicle_SUV_C") == 3, "6: del removes the last seat")
    cmd("3", "try")
    check(tried[1] == 3 and last():find("seat 3", 1, true) ~= nil, "6: try asks the vehicle side")
    -- print, and the printed line loads back into the same rows
    cmd("print")
    local line = out[#out]:gsub("^%[SEATS%]%s*", "")
    local fn = load("return { " .. line .. " }")
    local t = fn and fn()
    local same = t and t.Vehicle_SUV_C and #t.Vehicle_SUV_C == 3
    if same then
        for i, rr in ipairs(t.Vehicle_SUV_C) do
            local o = VS.rows("Vehicle_SUV_C")[i]
            for _, k in ipairs({ "side", "x", "y", "z", "yaw", "pose", "exit", "ready" }) do
                if rr[k] ~= o[k] then same = false end
            end
        end
    end
    check(same, "6: print: a line that loads back into the same rows (to paste into M.TABLE)")
    local fn2 = load("return { " .. VS.table_line("Vehicle_Buggy_C") .. " }")
    check(fn2 and #fn2().Vehicle_Buggy_C == 0, "6: a class without rows prints an empty list")
    -- reset puts the one sitting there back with the table's numbers
    who[3] = "host"
    placed = {}
    cmd("reset")
    check(VS.edits.Vehicle_SUV_C == nil and VS.row("Vehicle_SUV_C", 3).x == -90, "6: reset: the table's rows again")
    check(#placed == 1 and placed[1].idx == 3 and placed[1].wid == "host" and placed[1].geo.x == -90, "6: reset: the seated one moved back")
    who[3] = nil
    VS.reset("world")
    cmd("3", "0", "0", "1")
    VS.reset("role host -> standalone")
    check(VS.edits.Vehicle_SUV_C ~= nil and VS.row("Vehicle_SUV_C", 3).z == 1, "6: a world / role change keeps the live edits (until the game quits)")
    VS.edits.Vehicle_SUV_C = nil
    role = "client"
    cmd()
    check(last():find("host only", 1, true) ~= nil, "6: a client is refused")
    role = "standalone"
    cmd()
    check(has("Vehicle_SUV_C"), "6: single player may tune")
    check(VS.status():find("seats=true", 1, true) ~= nil, "6: status line")
end

log.info = info0
print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
