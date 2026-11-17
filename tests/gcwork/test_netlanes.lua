-- sdc_net 0.12.2: latest-wins for snapshot kinds, the fast lane for a player's
-- answers, the budget by size, the reliable-window guard for a stalled client.
-- usage: lua test_netlanes.lua <scripts dir>
local dir = arg[1]
local sim_mod = dofile(arg[0]:gsub("test_netlanes%.lua$", "netsim.lua"))
local NETFILE = dir .. "/sdc_net.lua"

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local function kinds(pc, from)
    local out = {}
    for i = from or 1, #pc.got do out[#out + 1] = sim_mod.kind_of(pc.got[i]) end
    return out
end
local function joined(t) return table.concat(t, ",") end
local function fresh()
    local sim = sim_mod.new(NETFILE, dir)
    local pc = sim.pc("BP_PlayerController_C_1", 1001)
    sim.tick(40, 0.05)
    return sim, sim.net, pc
end
-- a frozen receiver: nothing is received for > stall_s -> the lane is "stalled"
local function freeze(sim, net, pc)
    net.send_to(pc, "PSTATE", 99, "keep")          -- the lane is in use
    pc.frozen = true
    sim.tick(15, 0.05)
end
local function thaw(sim, pc, n) pc.frozen = false; sim.tick(n or 60, 0.05) end

-- 1. the registry: what is a snapshot, what is an event, which lane
do
    local _, net = fresh()
    local snap = { "ROSTER", "ENV", "LOOK", "MYLOOK", "PTOOLS", "ITEMS", "UIDS", "INFUI", "RESPUI", "PRJCAP", "QS", "PEQUIP",
        "PCVAR", "RULES", "SKL", "SKTREE", "WSTAT", "MKSYNC", "PSTATE", "MYSTATE", "PPOS", "PINFO", "MYGPS",
        "STEALTH", "MYNVG" }
    local ok = true
    for _, k in ipairs(snap) do if not net.SNAPSHOT[k] then ok = false; io.write("    not a snapshot: " .. k .. "\n") end end
    check(ok, "the snapshot kinds are registered")
    local ev = { "JMC", "JADD", "TURSTATE", "DXP", "GWEAR", "WLOOT", "WLOOTS", "WLOOTR", "WINF", "WRINF", "WRDOOR", "WDOOR", "NOTE", "RLNOTE",
        "IGAIN", "IGLOST", "IFAIL", "IHID", "VBOXR", "VSTATE", "VOCC", "NPCSET", "AIM", "DOWN", "HORDE", "PEV", "AIHPQ", "SHOTN",
        "ACCESS", "KICK", "PSDONE", "RESEND", "SETDUR", "RNAME", "DBOXGONE", "POIST", "WEVT", "QG" }
    ok = true
    for _, k in ipairs(ev) do if net.SNAPSHOT[k] then ok = false; io.write("    wrongly a snapshot: " .. k .. "\n") end end
    check(ok, "events / deltas / one-shot actions / JMC are NOT coalesced (default: never)")
    local fast = { "JMC", "WBDOOR", "NOTE", "RLNOTE", "IFAIL", "IHID", "DISASMR", "RNOPEN", "GOTOST", "MKSYNC", "ACCESS" }
    ok = true
    for _, k in ipairs(fast) do if not net.FAST[k] then ok = false; io.write("    not fast: " .. k .. "\n") end end
    check(ok, "the answers a player waits for are in the fast lane")
    check(not net.FAST.ROSTER and not net.FAST.WLOOTS and not net.FAST.ITEMS and not net.FAST.LOOK, "snapshots / world bulk are not fast")
    local bad = false
    for k in pairs(net.PAIRED) do if net.SNAPSHOT[k] or not net.NOW[k] then bad = true end end
    check(not bad, "paired payloads (NPCSET, AIM...) are NOW and never merged")
    for k in pairs(net.FAST) do if net.NOW[k] then bad = true end end
    check(not bad, "no kind is both NOW and FAST")
end

-- 2. latest wins, in the queue
do
    local sim, net, pc = fresh()
    freeze(sim, net, pc)
    local b = #pc.got
    for i = 1, 7 do net.send_to(pc, "ROSTER", "r" .. i, "x") end
    for i = 1, 7 do net.send_to(pc, "ENV", i .. ".0", "clear", "") end
    check(net.queued_count() == 2, "ROSTER x7 + ENV x7 while stalled: 2 wait (" .. net.queued_count() .. ")")
    net.send_to(pc, "ROSTER", "A", "x")
    net.send_to(pc, "WLOOT", "w1", "r")
    net.send_to(pc, "ROSTER", "B", "x")
    check(net.queued_count() == 3, "ROSTER A, WLOOT, ROSTER B: A replaced -> 3 wait (" .. net.queued_count() .. ")")
    for i = 1, 3 do net.send_to(pc, "LOOK", 1, "look1_" .. i) end
    for i = 1, 2 do net.send_to(pc, "LOOK", 2, "look2_" .. i) end
    check(net.queued_count() == 5, "LOOK is merged per player id: 2 more wait (" .. net.queued_count() .. ")")
    for i = 1, 4 do net.send_to(pc, "JMC", "*", "box1", "add," .. i) end
    for i = 1, 3 do net.send_to(pc, "DXP", "str", i) end
    check(net.queued_count() == 12, "JMC x4 and DXP x3 are all kept: " .. net.queued_count())
    check(net.budget_stats.replaced >= 17, "stat: replacements counted: " .. net.budget_stats.replaced)
    thaw(sim, pc)
    local got = {}
    for i = b + 1, #pc.got do got[#got + 1] = pc.got[i] end
    local function find(pat) for i, m in ipairs(got) do if m:find(pat) then return i end end end
    local n_roster, n_env = 0, 0
    for _, m in ipairs(got) do
        if m:find("^SDC1|ROSTER|") then n_roster = n_roster + 1 end
        if m:find("^SDC1|ENV|") then n_env = n_env + 1 end
    end
    check(n_roster == 1 and n_env == 1, "the client got ONE ROSTER and ONE ENV (" .. n_roster .. ", " .. n_env .. ")")
    check(find("^SDC1|ROSTER|B|") and find("^SDC1|ENV|7.0|"), "... the newest of each")
    check(find("^SDC1|WLOOT|w1|") < find("^SDC1|ROSTER|B|"), "the newer snapshot took the END position: the event queued before it comes first")
    check(find("^SDC1|LOOK|1|look1_3") and find("^SDC1|LOOK|2|look2_2") and not find("look1_1") and not find("look2_1"), "LOOK: the newest per player")
    local jm = {}
    for _, m in ipairs(got) do local a = m:match("^SDC1|JMC|%*|box1|add,(%d)"); if a then jm[#jm + 1] = a end end
    check(joined(jm) == "1,2,3,4", "JMC ops of one container: all, in order")
    local dx = 0
    for _, m in ipairs(got) do if m:find("^SDC1|DXP|") then dx = dx + 1 end end
    check(dx == 3, "DXP (an event): all 3 delivered")
end

-- 3. per peer: another player's queue is separate
do
    local sim, net, pc = fresh()
    local pc2 = sim.pc("BP_PlayerController_C_2", 2002)
    freeze(sim, net, pc)
    net.send_to(pc2, "ROSTER", "p2", "x")      -- not stalled: goes at once
    net.send_to(pc, "ROSTER", "p1a", "x"); net.send_to(pc, "ROSTER", "p1b", "x")
    check(#pc2.got == 1 and net.queued_count() == 1, "a ROSTER for another player is not merged with this one's")
end

-- 4. several parts of one snapshot: MKSYNC (seq) and WBDOOR "s" (sent in one go)
do
    local sim, net, pc = fresh()
    freeze(sim, net, pc)
    local b = #pc.got
    net.send_to(pc, "MKSYNC", 5, 1, 2, "a"); net.send_to(pc, "MKSYNC", 5, 2, 2, "b")
    check(net.queued_count() == 2, "MKSYNC seq 5: two parts of the same list both wait")
    net.send_to(pc, "MKSYNC", 6, 1, 3, "c"); net.send_to(pc, "MKSYNC", 6, 2, 3, "d"); net.send_to(pc, "MKSYNC", 6, 3, 3, "e")
    check(net.queued_count() == 3, "seq 6 replaces ALL parts of seq 5 (3 wait)")
    net.send_to(pc, "WBDOOR", "s", "door1 1,1,1 1 - -"); net.send_to(pc, "WBDOOR", "c", "door2 2,2,2 0 - -")
    net.send_to(pc, "WBDOOR", "s", "door3 3,3,3 1 - -")
    check(net.queued_count() == 6, "WBDOOR: two parts of one batch + a change: all kept")
    sim.tick(8, 0.05)    -- 0.4 s later: another snapshot
    net.send_to(pc, "WBDOOR", "s", "door1 1,1,1 0 - -")
    net.send_to(pc, "WBDOOR", "c", "door2 2,2,2 1 - -")
    check(net.queued_count() == 8, "WBDOOR (a delta kind): nothing is replaced, all 8 wait (" .. net.queued_count() .. ")")
    thaw(sim, pc)
    local seq = {}
    for i = b + 1, #pc.got do
        local m = pc.got[i]
        if m:find("^SDC1|MKSYNC|") then seq[#seq + 1] = m:match("^SDC1|MKSYNC|(%d+)|") end
        if m:find("^SDC1|WBDOOR|") then seq[#seq + 1] = m:match("^SDC1|WBDOOR|(%a)|") .. m:match("door(%d)") end
    end
    check(joined(seq):find("^6,6,6,") ~= nil, "the client got seq 6 only: " .. joined(seq))
    check(joined(seq) == "6,6,6,s1,c2,s3,s1,c2", "WBDOOR: every message, in the order sent: " .. joined(seq))
end

-- 5. a NOW snapshot (PSTATE) held for a stalled client: only the newest goes, once heard again
do
    local sim, net, pc = fresh()
    freeze(sim, net, pc)
    local b = #pc.got
    for i = 1, 20 do net.send_to(pc, "PSTATE", 1, "s" .. i); net.send_to(pc, "PSTATE", 2, "t" .. i); net.send_to(pc, "PPOS", 1, i, 0, 0) end
    check(#pc.got == b and net.queued_count() == 3, "stalled: PSTATE x2 players + PPOS wait as one record each (" .. net.queued_count() .. ")")
    net.send_to(pc, "VSEAT", "passenger", "Host")
    check(#pc.got == b + 1, "a NOW event (VSEAT) still goes")
    thaw(sim, pc, 4)
    local ps = {}
    for i = b + 1, #pc.got do
        local m = pc.got[i]
        if m:find("^SDC1|PSTATE|") then ps[#ps + 1] = m:match("^SDC1|PSTATE|(%d)|(%w+)") .. "=" .. m:match("|(%w+)$") end
    end
    check(#ps == 2 and net.queued_count() == 0, "recovered: one PSTATE per player")
    -- no stale copy overtakes a newer one sent after the recovery
    pc.frozen = true; sim.tick(15, 0.05)
    net.send_to(pc, "PSTATE", 1, "old")
    pc.frozen = false
    net.send_to(pc, "PSTATE", 1, "new")   -- (still stalled by the lane's own view until the next sample)
    sim.tick(10, 0.05)
    local last
    for i = #pc.got, 1, -1 do if pc.got[i]:find("^SDC1|PSTATE|1|") then last = pc.got[i]; break end end
    check(last and last:find("new$") ~= nil, "the newest PSTATE is the last one the client got")
end

-- 6. the fast lane
do
    local sim, net, pc = fresh()
    local b = #pc.got
    for i = 1, 150 do net.send_to(pc, "WLOOTS", string.rep("w", 1200) .. i) end
    check(net.queued_count() > 100, "a world burst of 150 x 1.2 KB queues (" .. net.queued_count() .. ")")
    local t0 = sim.now()
    net.send_to(pc, "JMC", "*", "box7", "add,1"); net.send_to(pc, "JMC", "*", "box7", "cnt,1")
    net.send_to(pc, "WBDOOR", "c", "door1 1,1,1 1 - -"); net.send_to(pc, "WBDOOR", "s", "door1 1,1,1 1 - -")
    net.send_to(pc, "NOTE", "hi", "", "1,1,1", "2.0"); net.send_to(pc, "RLNOTE", "1", "2", "3", "0")
    local k = kinds(pc, #pc.got - 5)
    check(joined(k):find("JMC,JMC,WBDOOR,WBDOOR,NOTE,RLNOTE$") ~= nil, "answers go at once past the burst, in order: " .. joined(k))
    -- and when the fast budget is used up they wait in the fast queue, still ahead of the bulk
    local g0 = #pc.got
    for i = 1, 60 do net.send_to(pc, "JMC", "*", "box8", "add," .. i, string.rep("p", 1300)) end
    sim.tick(20, 0.05)
    local jm, wl1 = 0, 0
    for i = g0 + 1, #pc.got do
        if pc.got[i]:find("^SDC1|JMC|%*|box8") then jm = jm + 1 elseif pc.got[i]:find("^SDC1|WLOOTS|") then wl1 = wl1 + 1 end
    end
    check(jm > 2 * wl1 and jm >= 20, "a 60-message answer burst goes first, ahead of the bulk (fast " .. jm .. ", bulk " .. wl1 .. " in 1 s)")
    -- order of one container's ops
    sim.tick(600, 0.05)
    local nums, ok = {}, true
    for _, m in ipairs(pc.got) do local n = m:match("^SDC1|JMC|%*|box8|add,(%d+)"); if n then nums[#nums + 1] = tonumber(n) end end
    ok = #nums == 60
    for i = 2, #nums do if nums[i] ~= nums[i - 1] + 1 then ok = false end end
    check(ok, "60 JMC of one container: all arrived, in order")
    local wl = 0
    for _, m in ipairs(pc.got) do if m:find("^SDC1|WLOOTS|") then wl = wl + 1 end end
    check(wl == 150 and net.queued_count() == 0, "the bulk burst still arrives completely (150)")
end

-- 6b. a long fast burst does not starve the bulk queue
do
    local sim, net, pc = fresh()
    for i = 1, 100 do net.send_to(pc, "WLOOTS", "bulk" .. i) end    -- 52 queued
    for i = 1, 200 do net.send_to(pc, "JMC", "*", "boxX", "add," .. i) end
    sim.tick(30, 0.05)   -- 1.5 s
    local bulk, fastn = 0, 0
    for i = 49, #pc.got do
        if pc.got[i]:find("^SDC1|WLOOTS|") then bulk = bulk + 1 elseif pc.got[i]:find("^SDC1|JMC|") then fastn = fastn + 1 end
    end
    check(bulk >= 1 and fastn > bulk, "fast first, but a bulk message goes every fast_run: bulk " .. bulk .. ", fast " .. fastn)
end

-- 7. the budget counts reliable bunches, not messages
do
    local sim, net, pc = fresh()
    local b = #pc.got
    for i = 1, 60 do net.send_to(pc, "WLOOTS", string.rep("z", 1100) .. i) end   -- ~2 bunches each
    local sent = #pc.got - b
    check(sent >= 22 and sent <= 26, "1.1 KB messages cost 2 each: ~24 go at once, not 48 (" .. sent .. ")")
    local sim2, net2, pc2 = fresh()
    local b2 = #pc2.got
    for i = 1, 60 do net2.send_to(pc2, "WRDOOR", "d" .. i, "1") end
    check(#pc2.got - b2 == 48, "small messages: 48 at once as before (" .. (#pc2.got - b2) .. ")")
end

-- 8. a stalled client cannot take the engine's reliable window over 256
do
    local sim, net, pc = fresh()
    freeze(sim, net, pc)
    local b = #pc.got
    local bun = 0
    -- 10 s of everything at once: movement snapshots, events, vehicles, paired NPC payloads
    for s = 1, 10 do
        for q = 1, 4 do
            for id = 1, 3 do net.send_to(pc, "PSTATE", id, "st" .. s .. q); net.send_to(pc, "PPOS", id, s, q, 0) end
            net.send_to(pc, "VSTATE", "*", "v" .. s .. q); net.send_to(pc, "VOCC", "*", "o" .. s .. q)
            for i = 1, 3 do net.send_to(pc, "VENTER", "car" .. i) end
            for i = 1, 2 do net.send_to(pc, "AIM", "n" .. i) end
            sim.tick(5, 0.05)
        end
    end
    for i = b + 1, #pc.got do bun = bun + sim_mod.bunches(pc.got[i]) end
    local paired = 0
    for i = b + 1, #pc.got do if pc.got[i]:find("^SDC1|AIM|") then paired = paired + 1 end end
    check(bun < 230, "10 s into a frozen client: " .. string.format("%.0f", bun) .. " bunches reached the channel (< 256)")
    check(paired == 80, "all 80 paired AIM payloads still went (ClientRepObjRef follows them)")
    local qn = net.queued_count()
    check(qn > 0, "the rest waits (" .. qn .. ")")
    thaw(sim, pc, 200)
    check(net.queued_count() == 0, "everything held is delivered once it is heard again")
    local vs, vo, order_ok, last_vs = {}, {}, true, 0
    for i = b + 1, #pc.got do
        local m = pc.got[i]
        local k = sim_mod.kind_of(m)
        if k == "VSTATE" then last_vs = i end
        if k == "VOCC" and i < last_vs then order_ok = false end
    end
    check(order_ok, "held VSTATE / VOCC events kept their order (a VOCC never before an earlier VSTATE)")
    local n_ps = 0
    for i = b + 1, #pc.got do if pc.got[i]:find("^SDC1|PSTATE|") then n_ps = n_ps + 1 end end
    check(n_ps < 40, "PSTATE: the newest per player, not all 120 (" .. n_ps .. ")")
end

-- 9. measurements (the numbers in the report): 10 s stall, then a burst + an action
do
    local s = sim_mod.stall(NETFILE, dir, 10)
    io.write(string.format("  NETQ stall 10 s: %d msgs = %.0f bunches into the frozen client, queue %d at the end, current after %.2f s, empty after %.2f s, ROSTER copies %d\n",
        s.sent_while_frozen, s.bunches_while_frozen, s.queue_at_end_of_freeze, s.until_current or -1, s.until_empty or -1, s.rosters))
    check(s.bunches_while_frozen < 130, "stall: the window estimate stays far below 256 (" .. string.format("%.0f", s.bunches_while_frozen) .. ")")
    check(s.until_current and s.until_current < 2.5, "stall: the client is current within 2.5 s of recovery")
    check(s.until_empty and s.until_empty < 6, "stall: the queue is empty within 6 s")
    local a = sim_mod.action(NETFILE, dir)
    local worst = 0
    for _, k in ipairs({ "jmc1", "jmc2", "door", "note", "rl" }) do worst = math.max(worst, a.latency[k] or 99) end
    io.write(string.format("  NETQ action answers after a world burst: worst latency %.2f s\n", worst))
    check(worst < 0.2, "action answers are not held up by the burst (worst " .. string.format("%.2f", worst) .. " s)")
    check(joined(a.order) == "jmc1,jmc2", "JMC order kept")
end

-- 10. review fixes
do
    -- WBDOOR "s" is a delta: a queued join list is never replaced by a later delta
    local sim, net, pc = fresh()
    freeze(sim, net, pc)
    local b = #pc.got
    net.send_to(pc, "WBDOOR", "s", "doorA 1,1,1 1 - -;doorB 2,2,2 1 - -")
    sim.tick(10, 0.05)
    net.send_to(pc, "WBDOOR", "s", "doorB 2,2,2 0 - -")
    check(not net.SNAPSHOT.WBDOOR and net.FAST.WBDOOR, "WBDOOR is fast but not a snapshot")
    check(net.queued_count() == 2, "join list A,B + a delta B: both wait")
    thaw(sim, pc)
    local all = table.concat(pc.got, "\n", b + 1)
    check(all:find("doorA", 1, true) and all:find("doorB 2,2,2 0", 1, true), "the client got both: door A is not lost")

    -- NPCHP and every kind sent with an ObjRef is PAIRED (and NOW)
    local _, net2 = fresh()
    local missing = {}
    local seen = 0
    for _, f in ipairs({ "sdc_npc.lua", "sdc_ai.lua", "sdc_ai_attacks.lua", "sdc_ai_corpses.lua", "sdc_ai_hud.lua",
                         "sdc_ai_killlog.lua", "sdc_ai_looks.lua" }) do
        local h = io.open(dir .. "/" .. f, "rb")
        if h then
            local src = h:read("a"); h:close()
            for k in src:gmatch("send_obj%([^\n\"]-\"([A-Z0-9_]+)\"") do seen = seen + 1; if not net2.PAIRED[k] then missing[k] = true end end
            for k in src:gmatch("send_with_obj%([^\n\"]-\"([A-Z0-9_]+)\"") do seen = seen + 1; if not net2.PAIRED[k] then missing[k] = true end end
        end
    end
    local ml = {}
    for k in pairs(missing) do ml[#ml + 1] = k end
    check(seen >= 8 and #ml == 0, "every send_obj / send_with_obj kind is PAIRED (" .. seen .. " sites; missing: " .. joined(ml) .. ")")
    check(net2.PAIRED.NPCHP and net2.NOW.NPCHP and net2.FAST.DICT and net2.FAST.DICTQ, "NPCHP paired + NOW; DICT / DICTQ fast")

    -- MERGE: a partial newer state keeps the older queued one's fields
    local sim3, net3, pc3 = fresh()
    freeze(sim3, net3, pc3)
    local b3 = #pc3.got
    net3.send_to(pc3, "PSTATE", 7, 5, 1, 45, 3)
    net3.send_to(pc3, "PSTATE", 7, 9, 1, "", "")
    net3.send_to(pc3, "MYSTATE", 5, 1, -65, 2)
    net3.send_to(pc3, "MYSTATE", 6, 1, "", "")
    check(net3.queued_count() == 2, "PSTATE / MYSTATE merged to one each")
    thaw(sim3, pc3)
    local got3 = table.concat(pc3.got, "\n", b3 + 1)
    check(got3:find("SDC1|PSTATE|7|9|1|45|3", 1, true) ~= nil, "PSTATE: mask of the newer, ln / hy filled from the older")
    check(got3:find("SDC1|MYSTATE|6|1|-65|2", 1, true) ~= nil, "MYSTATE: the same")
    -- when it goes at once, nothing is changed
    local sim4, net4, pc4 = fresh()
    net4.send_to(pc4, "PSTATE", 7, 9, 1, "", "")
    check(pc4.got[#pc4.got] == "SDC1|PSTATE|7|9|1||", "a message sent at once is untouched")

    -- on_out: after the RPC went out, not for a replaced message
    local sim5, net5, pc5 = fresh()
    local calls = {}
    net5.send_to_cb(pc5, function() calls[#calls + 1] = "direct" end, "ROSTER", "a")
    check(calls[1] == "direct", "on_out: a message that goes at once")
    freeze(sim5, net5, pc5)
    net5.send_to_cb(pc5, function() calls[#calls + 1] = "old" end, "ROSTER", "b")
    net5.send_to_cb(pc5, function() calls[#calls + 1] = "new" end, "ROSTER", "c")
    check(#calls == 1, "on_out: not while it waits")
    thaw(sim5, pc5)
    check(#calls == 2 and calls[2] == "new", "on_out: the replaced one never fires, the newest does when it is sent (" .. joined(calls) .. ")")
    local sim6, net6, pc6 = fresh()
    sim6.ue.local_pc = function() return pc6 end
    local hostc = 0
    net6.send_to_host_cb(function() hostc = hostc + 1 end, "WSTAT", "main", "u", "t")
    check(hostc == 1, "on_out: client -> host")

    -- congested()
    local sim7, net7, pc7 = fresh()
    check(not net7.congested(pc7), "congested: a healthy peer is not")
    freeze(sim7, net7, pc7)
    check(net7.congested(pc7), "congested: a stalled peer is")
    thaw(sim7, pc7)
    check(not net7.congested(pc7), "congested: ... and not again after recovery")

    -- fast_run: the forced bulk turn that does not fit must not block fast
    local sim8, net8, pc8 = fresh()
    for i = 1, 300 do net8.send_to(pc8, "WLOOTS", "w" .. i) end
    for i = 1, 120 do net8.send_to(pc8, "VHORN", "x") end      -- NOW events: the bulk budget is in debt
    for i = 1, 40 do net8.send_to(pc8, "JMC", "*", "box", "add," .. i) end
    local t0, from, jt = sim8.now(), #pc8.got, {}
    for _ = 1, 100 do
        sim8.tick(1, 0.05)
        for i = from + 1, #pc8.got do if sim_mod.kind_of(pc8.got[i]) == "JMC" then jt[#jt + 1] = pc8.at[i] - t0 end end
        from = #pc8.got
    end
    check(#jt == 40 and jt[17] and jt[17] - jt[16] < 0.5, "the 17th JMC does not wait for the bulk budget (" .. #jt .. " in 5 s, 16th/17th " .. string.format("%.2f/%.2f", jt[16] or -1, jt[17] or -1) .. ")")

    -- lanes: an idle lane of a gone player is forgotten
    local sim9, net9, pc9 = fresh()
    net9.send_to(pc9, "ROSTER", "x")
    sim9.tick(240, 0.05)   -- 12 s: the lane is idle
    pc9.alive = false
    sim9.tick(2, 0.05)
    check(net9.lane_count() == 0, "a gone player's idle lane is dropped (" .. net9.lane_count() .. ")")
end

io.stderr:write(string.format("%d checks, %d failed\n", checks, fails))
os.exit(fails == 0 and 0 or 1)
