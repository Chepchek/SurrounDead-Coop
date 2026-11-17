-- Traffic of the player state sync (sdc_pawnstate, 0.12.2): bitmask + numeric
-- fields, 4 visual updates a second at most, head / lean only to machines that
-- can see the character, full state at once when somebody comes into range.
-- Three machines (host H = id 1, clients A = 2 and B = 3), each with its own
-- copy of sdc_pawnstate and its own view of the world; messages are delivered
-- between them and counted. The OLD behaviour (text "hf=1;..", step 2, send on
-- any change, host relays everything to everybody) is modelled for comparison.
-- usage: lua mock_pawnstate_traffic.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local T = 1000.0
os.clock = function() return T end
local passed, fails = 0, 0
local real_print = print
local function check(c, what)
    if c then passed = passed + 1; real_print("  ok   " .. what) else fails = fails + 1; real_print("  FAIL " .. what) end
end
local out = real_print

local truth = {}      -- [id] = { loc = {X,Y,Z}, ctrl = control yaw (head = -ctrl) , props = {} }
local machines = {}
local stats          -- current scenario counters
local RELEVANCY = 15000
local queue = nil     -- non-nil: sdc_net's stalled queue, latest message per (receiver, kind, sender id) wins

local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local naddr = 1000
local function newaddr() naddr = naddr + 1; return naddr end

local function make_machine(role, myid, pcs_for)
    local m = { role = role, myid = myid, handlers = {}, pawns = {} }
    machines[myid] = m
    for id in pairs(truth) do
        m.pawns[id] = {
            id = id, addr = newaddr(), props = {}, role = (id == myid) and 2 or 1,
            IsLocallyControlled = function() return id == myid end,
        }
    end
    local ue = {}
    setmetatable(ue, { __index = function() return function() end end })
    ue.ROLE_SIMULATED = 1
    function ue.valid(o) return o ~= nil and o.valid ~= false end
    function ue.prop(o, k) if type(o) ~= "table" or not o.props then return nil end return o.props[k] end
    function ue.set_prop(o, k, v) o.props[k] = v; return true end
    function ue.try(f, ...) local ok, v = pcall(f, ...); if ok then return v end return nil end
    function ue.role(p) return p.role end
    function ue.short(p) return "P" .. tostring(p.id) end
    function ue.local_pawn() return m.pawns[myid] end
    function ue.local_pc() return { GetControlRotation = function() return { Yaw = truth[myid].ctrl } end } end
    function ue.pawn_of(pc) return pc.pawn end
    function ue.location(p) return p and p.id and truth[p.id] and { X = truth[p.id].loc.X, Y = truth[p.id].loc.Y, Z = truth[p.id].loc.Z } end
    function ue.rotation(p) return { Pitch = 0, Yaw = 0, Roll = 0 } end
    function ue.player_chars()
        local l = {}
        for id, p in pairs(m.pawns) do
            if role == "host" or id == myid or dist(truth[id].loc, truth[myid].loc) <= RELEVANCY then l[#l + 1] = p end
        end
        return l
    end
    function ue.find_object() return nil end
    function ue.class_name() return "x" end
    local net = { on = function(k, f) m.handlers[k] = f end }
    local function emit(kind, ...)
        local parts = { "SDC1", kind }
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local s = table.concat(parts, "|")
        local f = {}
        for part in (s .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
        table.remove(f, 1); table.remove(f, 1)
        return s, f
    end
    function net.send_to(pc, kind, ...)
        local s, f = emit(kind, ...)
        stats.msgs = stats.msgs + 1; stats.bytes = stats.bytes + #s
        stats.kind[kind] = (stats.kind[kind] or 0) + 1
        stats.log[#stats.log + 1] = { t = T, kind = kind, s = s, to = pc.mach.myid }
        if queue then
            queue[pc.mach.myid .. "|" .. kind .. "|" .. tostring(f[1])] = function() pc.mach.handlers[kind](f) end
            return true
        end
        pc.mach.handlers[kind](f)
        return true
    end
    function net.send_to_host(kind, ...)
        local s, f = emit(kind, ...)
        stats.msgs = stats.msgs + 1; stats.bytes = stats.bytes + #s
        stats.kind[kind] = (stats.kind[kind] or 0) + 1
        stats.log[#stats.log + 1] = { t = T, kind = kind, s = s, to = 1, from = myid }
        if queue then
            queue["1|" .. kind .. "|" .. myid] = function() machines[1].handlers[kind](f, machines[1].pc_of[myid]) end
            return true
        end
        machines[1].handlers[kind](f, machines[1].pc_of[myid])
        return true
    end
    function net.broadcast(pcs, kind, ...) for _, pc in ipairs(pcs) do net.send_to(pc, kind, ...) end end
    package.loaded["sdc_ue"] = ue
    package.loaded["sdc_net"] = net
    package.loaded["sdc_log"] = setmetatable({}, { __index = function() return function() end end })
    package.loaded["sdc_ctx"] = { addr = function(o) return o and o.addr end }
    package.loaded["sdc_config"] = { get = function() return nil end }
    package.loaded["sdc_items"] = { equipped_of = function() return {} end }
    package.loaded["sdc_appearance"] = { player_id = function(p) return p and p.id end, drop_left = function() end }
    package.loaded["sdc_pawnstate"] = nil
    m.ps = require("sdc_pawnstate")
    m.S = { role = role, remote_pcs = {} }
    m.ps.init(m.S)
    m.ps.register_handlers()
    return m
end

-- host's list of client controllers; pc.pawn = the host's copy of that client's pawn
local function setup(positions)
    truth = {}
    machines = {}
    for id, loc in pairs(positions) do truth[id] = { loc = loc, ctrl = 0 } end
    local H = make_machine("host", 1)
    local A = make_machine("client", 2)
    local B = make_machine("client", 3)
    H.pc_of = {}
    for _, id in ipairs({ 2, 3 }) do
        local pc = { addr = newaddr(), mach = machines[id], pawn = H.pawns[id] }
        H.pc_of[id] = pc
        H.S.remote_pcs[#H.S.remote_pcs + 1] = pc
    end
    return H, A, B
end

local function new_stats() stats = { msgs = 0, bytes = 0, kind = {}, log = {} } end

-- Run `secs` seconds in 100 ms ticks; look(id, t) -> head yaw (deg) of player id.
local function run(secs, look, hook)
    local n = math.floor(secs * 10 + 0.5)
    for i = 1, n do
        T = T + 0.1
        local t = i / 10
        for id, tr in pairs(truth) do tr.ctrl = -(look(id, t) or 0) end
        if hook then hook(t) end
        for _, id in ipairs({ 1, 2, 3 }) do machines[id].ps.fast_tick() end
        if i % 10 == 0 then for _, id in ipairs({ 1, 2, 3 }) do machines[id].ps.tick(machines[id].S.remote_pcs) end end
        if queue and i % 10 == 0 then
            local q = queue
            queue = {}
            for _, fn in pairs(q) do fn() end
        end
    end
end

-- A looks around: 1.2 s of turning (~30 deg/s) in every 3 s, otherwise still
local function looker(id, t)
    if id ~= 2 then return 0 end
    local ph = t % 3
    local base = math.floor(t / 3) % 2 == 0 and 0 or 36
    if ph < 1.2 then
        local d = 36 * ph / 1.2
        return (math.floor(t / 3) % 2 == 0) and d or (36 - d)
    end
    return base == 0 and 36 or 0
end

-- ---- the OLD behaviour, for the same head motion of player A -------------
local function old_model(secs, nclients_other)
    local msgs, bytes = 0, 0
    local last
    local function step2(v) return math.floor(v / 2 + 0.5) * 2 end
    local n = math.floor(secs * 10 + 0.5)
    local new_bytes = 0
    for i = 1, n do
        local hy = step2(looker(2, i / 10))
        local s = string.format("fl=0;hf=0;hm=0;sp=0;cs=0;hip=0;ads=0;ms=0;ln=0.00;bs=0;hy=%d", hy)
        if s ~= last then
            last = s
            local c1 = #("SDC1|MYSTATE|" .. s)
            local c2 = #("SDC1|PSTATE|2|" .. s)
            msgs = msgs + 1 + nclients_other
            bytes = bytes + c1 + nclients_other * c2
            -- the same sends with the NEW encoding only (mask|bs|ln|hy, step 2)
            local nw = string.format("0|0|0|%d", hy / 2)
            new_bytes = new_bytes + #("SDC1|MYSTATE|" .. nw) + nclients_other * #("SDC1|PSTATE|2|" .. nw)
        end
    end
    return msgs, bytes, new_bytes
end

local function visual_msgs(kind, from_to)
    local n = 0
    for _, m in ipairs(stats.log) do
        if m.kind == kind then
            local f = {}
            for part in (m.s .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
            local hy = kind == "MYSTATE" and f[6] or f[7]
            if hy and hy ~= "" and (not from_to or m.to == from_to) then n = n + 1 end
        end
    end
    return n
end

local SECS = 60
local function rep(label, secs, ms, bs)
    out(string.format("  %-52s %6.1f msg/s %7.1f B/s  (%.0f B per message)", label, ms / secs, bs / secs, ms > 0 and bs / ms or 0))
end

-- =============================================================== 1. two players close
out("== H, A and B all within 30 m, A looks around, 60 s")
local H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 2000, Y = 0, Z = 0 }, [3] = { X = 3000, Y = 0, Z = 0 } })
new_stats()
run(SECS, looker)
local close_msgs, close_bytes = stats.msgs, stats.bytes
local o_m, o_b, o_nb = old_model(SECS, 1)   -- old: A -> host, host -> B (the far third client got everything too)
rep("OLD (text, step 2, every change, A -> host -> B)", SECS, o_m, o_b)
rep("OLD trigger, NEW encoding only", SECS, o_m, o_nb)
rep("NEW (B sees A: head goes A -> host -> B)", SECS, close_msgs, close_bytes)
check(close_msgs / SECS < 0.5 * o_m / SECS, "close: fewer messages than before")

-- =============================================================== 2. H and A far apart, only 2 players
out("== H and A far apart (200 m), only they are in the game, 60 s")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 20000, Y = 0, Z = 0 }, [3] = { X = 900000, Y = 0, Z = 0 } })
H.S.remote_pcs = { H.S.remote_pcs[1] }   -- B is not in the game
new_stats()
run(SECS, looker)
rep("NEW, far apart", SECS, stats.msgs, stats.bytes)
local o2_m, o2_b = old_model(SECS, 0)
rep("OLD, same game (2 players)", SECS, o2_m, o2_b)
check(stats.msgs <= 5, "far: only the first state goes out (" .. stats.msgs .. " messages in 60 s)")

-- =============================================================== 2b. 2 players close: host does not use hy
out("== H and A close (host is the only other player), A looks around")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 2000, Y = 0, Z = 0 }, [3] = { X = 900000, Y = 0, Z = 0 } })
H.S.remote_pcs = { H.S.remote_pcs[1] }
new_stats()
run(SECS, looker)
rep("NEW, 2 players close (the host needs no head data)", SECS, stats.msgs, stats.bytes)
rep("OLD, same", SECS, o2_m, o2_b)
check(stats.msgs <= 5, "2 players: the host is no viewer, nothing but the core goes out (" .. stats.msgs .. ")")
check(visual_msgs("MYSTATE") == 0, "2 players: no head fields sent to the host")

-- =============================================================== 3. A and B close, H far
out("== A and B close (20 m), host far (300 m), A looks around: host relays A -> B")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 32000, Y = 0, Z = 0 } })
new_stats()
local maxdev, samples = 0, 0
run(SECS, looker, function(t)
    -- B's copy of A's state, compared with A's real (4-degree stepped) head
    local pA = B.pawns[2]
    local st = B.ps.state_of(pA)
    if st and t > 2 and t % 0.5 < 0.05 then
        local dev = math.abs((tonumber(st.hy) or 0) - looker(2, t))
        samples = samples + 1
        if dev > maxdev then maxdev = dev end
    end
end)
local o3_m, o3_b = old_model(SECS, 1)
rep("OLD (A -> host -> B)", SECS, o3_m, o3_b)
rep("NEW (A and B in range)", SECS, stats.msgs, stats.bytes)
local per_s = {}
local worst = 0
for _, m in ipairs(stats.log) do
    if m.kind == "MYSTATE" then
        local sec = math.floor((m.t - 1000) )
        per_s[sec] = (per_s[sec] or 0) + 1
        if per_s[sec] > worst then worst = per_s[sec] end
    end
end
check(worst <= 5, "visual updates: at most 4 (+1 core) per second from A (worst second " .. worst .. ")")
check(maxdev <= 40 and samples > 20, string.format("B follows A's head: sampled %d times, worst gap %.0f deg (A moves 30 deg/s, updates 4/s, 4-deg steps)", samples, maxdev))
-- final settle: A holds still, B must end within 2 deg of A (4-degree step = 2 deg of rounding)
local before = stats.msgs
run(2, function(id) return id == 2 and 36 or 0 end)
local stB = B.ps.state_of(B.pawns[2])
check(stB and math.abs(tonumber(stB.hy) - 36) <= 2, "A holds still: B ends on its head (" .. tostring(stB and stB.hy) .. " vs 36)")
check(stats.msgs - before <= 6, "and a still head costs nothing")

-- =============================================================== 4. core flags always reach everybody
out("== sprint of A reaches the host and far B at once (core flags are never culled)")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 90000, Y = 0, Z = 0 } })
new_stats()
run(2, function() return 0 end)
A.pawns[2].props["Sprinting?"] = true
run(0.3, function() return 0 end)
local hs = H.ps.state_of(H.pawns[2])
local bs_ = B.ps.state_of(B.pawns[2])
check(hs and hs.sp == "1", "host got sp=1")
check(bs_ and bs_.sp == "1", "B (far, 600 m) got sp=1 too")
local n_hy = 0
for _, m in ipairs(stats.log) do if m.kind == "PSTATE" and m.to == 3 then
    local f = {}
    for part in (m.s .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
    if f[7] ~= "" then n_hy = n_hy + 1 end
end end
check(n_hy == 0, "far B: PSTATE without the head field")

-- =============================================================== 5. coming into range
out("== B walks towards A: it gets the current full state at once")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 90000, Y = 0, Z = 0 } })
local still = function(id) return id == 2 and 24 or 0 end
run(3, still)
local before_b = B.ps.state_of(B.pawns[2])
check(before_b == nil or before_b.hy == nil, "far: B has no head data of A yet")
truth[3].loc = { X = 32000, Y = 0, Z = 0 }   -- B arrives 20 m from A
local got_at
for i = 1, 20 do
    run(0.1, still)
    local st = B.ps.state_of(B.pawns[2])
    if st and st.hy == "24" then got_at = i * 0.1 break end
end
check(got_at ~= nil and got_at <= 1.3, "B has A's head (24 deg) " .. tostring(got_at) .. " s after arriving (range check 0.5 s + A's own check)")
-- and the host's own head: B arrives near the host
H.S.remote_pcs = H.S.remote_pcs
local hlook = function(id) return id == 1 and -16 or 0 end
truth[2].loc = { X = 300000, Y = 0, Z = 0 }
truth[3].loc = { X = 90000, Y = 0, Z = 0 }
run(3, hlook)
check((A.ps.state_of(A.pawns[1]) or {}).hy == nil, "far from the host: A has no head data of the host")
truth[2].loc = { X = 2000, Y = 0, Z = 0 }
local gh
for i = 1, 20 do
    run(0.1, hlook)
    local st = A.ps.state_of(A.pawns[1])
    if st and st.hy == "-16" then gh = i * 0.1 break end
end
check(gh ~= nil and gh <= 0.7, "A walks up to the host: has its head at once (" .. tostring(gh) .. " s)")

-- =============================================================== 5b. host only (unit)
out("== host relay on its own: far B costs nothing, B arriving gets the stored state")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 90000, Y = 0, Z = 0 } })
new_stats()
H.ps.fast_tick()   -- first range check
for hy = 1, 10 do
    T = T + 0.3
    H.handlers.MYSTATE({ "0", "0", "0", tostring(hy) }, H.pc_of[2])
    H.ps.fast_tick()
end
local to_b = 0
for _, m in ipairs(stats.log) do if m.kind == "PSTATE" and m.to == 3 and m.s:find("^SDC1|PSTATE|2|") then to_b = to_b + 1 end end
check(to_b <= 1, "10 head changes of A, B far: B got " .. to_b .. " PSTATE of A (unchanged core is not repeated)")
truth[3].loc = { X = 32000, Y = 0, Z = 0 }
for _ = 1, 6 do T = T + 0.1; H.ps.fast_tick() end
check(B.ps.state_of(B.pawns[2]) and B.ps.state_of(B.pawns[2]).hy == "40", "B arrives: the host pushes A's stored head (hy 10 steps = 40 deg) with no help from A")

-- =============================================================== 5c. lean is core
out("== lean (Q / E) of a client reaches the host in a 2-player game, and a far B")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 2000, Y = 0, Z = 0 }, [3] = { X = 900000, Y = 0, Z = 0 } })
H.S.remote_pcs = { H.S.remote_pcs[1] }
new_stats()
run(2, function() return 0 end)
A.pawns[2].props.Lean = 45
run(0.5, function() return 0 end)
check(H.ps.state_of(H.pawns[2]) and tonumber(H.ps.state_of(H.pawns[2]).ln) == 45, "host sees the client's lean 45 (nobody near the client)")
check(visual_msgs("MYSTATE") == 0, "...and still no head field was sent")
A.pawns[2].props.Lean = -65
run(0.5, function() return 0 end)
check(tonumber(H.ps.state_of(H.pawns[2]).ln) == -65, "lean -65 too")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 90000, Y = 0, Z = 0 } })
run(2, function() return 0 end)
A.pawns[2].props.Lean = 45
run(1.5, function() return 0 end)
check(B.ps.state_of(B.pawns[2]) and tonumber(B.ps.state_of(B.pawns[2]).ln) == 45, "far B gets the lean too (core)")

-- =============================================================== 5d. HI repeated
out("== a repeated HI gets the states again")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 2000, Y = 0, Z = 0 }, [3] = { X = 3000, Y = 0, Z = 0 } })
run(2, function() return 0 end)
new_stats()
H.ps.send_all(H.pc_of[3])
local n1 = stats.msgs
H.ps.send_all(H.pc_of[3])
check(n1 >= 2 and stats.msgs == 2 * n1, "send_all twice to the same client: both times everything (" .. n1 .. " + " .. (stats.msgs - n1) .. ")")

-- =============================================================== 5e. queue keeps only the newest message
out("== sdc_net's stalled queue (latest per sender wins): the viewer still ends right")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 2000, Y = 0, Z = 0 }, [3] = { X = 3000, Y = 0, Z = 0 } })
queue = {}
run(2, function() return 0 end)
-- A turns the head and leans; between flushes (1 s) many messages replace each other
local seq = function(id, t) if id ~= 2 then return 0 end return 8 + math.floor(t * 4) % 24 end
run(5, seq)
A.pawns[2].props.Lean = 45
run(3.5, function(id) return id == 2 and 28 or 0 end)
local stq = B.ps.state_of(B.pawns[2])
check(stq and tonumber(stq.hy) == 28 and tonumber(stq.ln) == 45, "B ends on A's head 28 and lean 45 (" .. tostring(stq and stq.hy) .. ", " .. tostring(stq and stq.ln) .. ")")
-- the host's own head to the client in range
run(3, function(id) return id == 1 and -20 or 0 end)
local sth = A.ps.state_of(A.pawns[1])
check(sth and tonumber(sth.hy) == -20, "A ends on the host's head -20 (" .. tostring(sth and sth.hy) .. ")")
queue = nil

-- =============================================================== 5f. dedupe, hysteresis
out("== repeated MYSTATE and the 60 / 70 m border")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 32000, Y = 0, Z = 0 } })
new_stats()
H.ps.fast_tick()
T = T + 0.6; H.ps.fast_tick()
H.handlers.MYSTATE({ "2", "1", "0", "6" }, H.pc_of[2])
local function to_b()
    local n = 0
    for _, m in ipairs(stats.log) do if m.kind == "PSTATE" and m.to == 3 and m.s:find("^SDC1|PSTATE|2|") then n = n + 1 end end
    return n
end
local n0 = to_b()
check(n0 == 1, "first MYSTATE: one PSTATE to B in range")
for _ = 1, 5 do H.handlers.MYSTATE({ "2", "1", "0", "6" }, H.pc_of[2]) end
check(to_b() == n0, "the same MYSTATE five times more: B gets nothing again")
H.handlers.MYSTATE({ "2", "1", "0", "7" }, H.pc_of[2])
check(to_b() == n0 + 1, "a changed head: B gets it")
-- border: B at 62 m (between 60 and 70) after having been in -> stays in
local function with_hy(n) return n end
local function head_to_b(hy)
    local before = #stats.log
    H.handlers.MYSTATE({ "2", "1", "0", tostring(hy) }, H.pc_of[2])
    for i = before + 1, #stats.log do
        local m = stats.log[i]
        if m.kind == "PSTATE" and m.to == 3 and m.s:find("^SDC1|PSTATE|2|") then
            local f = {}
            for part in (m.s .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
            return f[7]
        end
    end
    return nil
end
local flap = 0
for i = 1, 12 do
    truth[3].loc = { X = 30000 + ((i % 2 == 0) and 6200 or 5800), Y = 0, Z = 0 }
    T = T + 0.6; H.ps.fast_tick()
    local hy = head_to_b(8 + i)
    if hy == nil or hy == "" then flap = flap + 1 end
end
check(flap == 0, "B jitters 58 <-> 62 m from A (inside the 70 m stay limit): the head never drops out")
-- far side: starts outside, jitters 62 <-> 71 m: never enters
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 40000, Y = 0, Z = 0 } })
new_stats()
H.ps.fast_tick(); T = T + 0.6; H.ps.fast_tick()
local entered = 0
for i = 1, 12 do
    truth[3].loc = { X = 30000 + ((i % 2 == 0) and 6200 or 7100), Y = 0, Z = 0 }
    T = T + 0.6; H.ps.fast_tick()
    H.handlers.MYSTATE({ "2", "1", "0", tostring(i) }, H.pc_of[2])
end
for _, m in ipairs(stats.log) do
    if m.kind == "PSTATE" and m.to == 3 and m.s:find("^SDC1|PSTATE|2|") then
        local f = {}
        for part in (m.s .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
        if f[7] ~= "" then entered = entered + 1 end
    end
end
check(entered == 0, "B jitters 62 <-> 71 m, never within 60 m: gets no head")

-- client side of the border: B at 58 m, then jittering 65 <-> 69 m: A keeps sending the head
out("== client: viewer jittering between 60 and 70 m keeps the head going")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 30000, Y = 0, Z = 0 }, [3] = { X = 35800, Y = 0, Z = 0 } })
local sweep = function(id, t) if id ~= 2 then return 0 end return (math.floor(t * 4) % 15) * 4 - 28 end
run(3, sweep)
new_stats()
run(8, sweep, function(t)
    truth[3].loc = { X = 30000 + ((math.floor(t * 2) % 2 == 0) and 6500 or 6900), Y = 0, Z = 0 }
end)
local with_hy, without = 0, 0
for _, m in ipairs(stats.log) do
    if m.kind == "MYSTATE" and m.from == 2 then
        local f = {}
        for part in (m.s .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
        if f[6] ~= "" then with_hy = with_hy + 1 else without = without + 1 end
    end
end
check(with_hy >= 20 and without == 0, "A keeps sending the head while B is 65-69 m away (" .. with_hy .. " with, " .. without .. " without)")

-- =============================================================== 6. wire shape
out("== wire shape")
H, A, B = setup({ [1] = { X = 0, Y = 0, Z = 0 }, [2] = { X = 2000, Y = 0, Z = 0 }, [3] = { X = 3000, Y = 0, Z = 0 } })
new_stats()
A.pawns[2].props["HoldingFirearm?"] = true
A.pawns[2].props["Sprinting?"] = true
run(1, function(id) return id == 2 and 20 or 0 end)
local sample
for _, m in ipairs(stats.log) do if m.kind == "MYSTATE" and m.from == 2 then sample = m.s end end
out("  MYSTATE sample: " .. tostring(sample))
check(sample == "SDC1|MYSTATE|10|0|0|5", "mask 2+8, bs 0, lean 0, head 20 deg = 5 steps")
local psample
for _, m in ipairs(stats.log) do if m.kind == "PSTATE" and m.s:find("^SDC1|PSTATE|2|") then psample = m.s end end
check(psample == "SDC1|PSTATE|2|10|0|0|5", "PSTATE relays the same numbers")
check(H.ps.state_of(H.pawns[2]).hf == "1" and H.ps.state_of(H.pawns[2]).sp == "1", "mask decoded into the flags")

real_print(string.format("pawnstate traffic: %d passed, %d failed", passed, fails))
real_print(fails == 0 and string.format("%d checks, ALL OK", passed) or string.format("%d checks, %d FAILED", passed + fails, fails))
os.exit(fails == 0 and 0 or 1)
