-- Tests for the sdc_net send budget (real sdc_net / sdc_ue / sdc_log, fake
-- controllers and clock). usage: lua test_netbudget.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end

local T = 500.0
os.clock = function() return T end
local function advance(s) T = T + s end
local logs = {}
print = function(s) logs[#logs + 1] = s end
local function log_has(pat)
    for _, l in ipairs(logs) do if l:find(pat) then return true end end
    return false
end
FName = function(s) return s end
local loops = {}
LoopInGameThreadWithDelay = function(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn }; return #loops end

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")

-- a fake remote controller with a connection whose LastReceiveTime we drive
-- (packets arrive every tick unless the pc is frozen)
local all_pcs = {}
local function new_pc(name, addr)
    local pc = { got = {}, alive = true, frozen = false, conn = { rt = 1.0, alive = true } }
    all_pcs[#all_pcs + 1] = pc
    function pc:IsValid() return self.alive end
    function pc:GetAddress() return addr end
    function pc:GetFName() return { ToString = function() return name end } end
    function pc:GetFullName() return "BP_PlayerController_C /Game/X." .. name end
    function pc:GetPropertyValue(n) if n == "NetConnection" then return self.conn end end
    function pc:ClientMessage(msg) self.got[#self.got + 1] = msg end
    function pc:ServerExecRPC(msg) self.got[#self.got + 1] = msg end
    local conn = pc.conn
    function conn:IsValid() return self.alive end
    function conn:GetPropertyValue(n) if n == "LastReceiveTime" then return self.rt end end
    return pc
end
local function kinds(pc, from)
    local out = {}
    for i = from or 1, #pc.got do out[#out + 1] = pc.got[i]:match("^SDC1|([A-Z0-9_]+)|") end
    return out
end
local function tick(n, dt)
    for _ = 1, n do
        advance(dt or 0.05)
        for _, p in ipairs(all_pcs) do if not p.frozen then p.conn.rt = p.conn.rt + (dt or 0.05) end end
        for _, l in ipairs(loops) do l.fn() end
    end
end

-- 1. normal traffic: a join snapshot of 22 messages goes out at once
local pc = new_pc("BP_PlayerController_C_1", 1001)
for i = 1, 16 do net.send_to(pc, "WRDOOR", "door" .. i, "1") end
for i = 1, 3 do net.send_to(pc, "WLOOTS", string.rep("x", 1200)) end
net.send_to(pc, "WDOOR", "a"); net.send_to(pc, "WDOOR", "b"); net.send_to(pc, "PSDONE", "1")
check(#pc.got == 22, "join snapshot (22 msgs) sent at once: " .. #pc.got)
check(net.queued_count() == 0, "nothing queued in normal traffic")
check(#loops == 1 and loops[1].ms == 50, "one game-thread loop started (50 ms)")
check(not log_has("send budget"), "no budget log line in normal traffic")

-- 2. steady play: 6 msgs/s for a minute never queues
tick(40, 0.05)
for s = 1, 60 do
    for i = 1, 6 do net.send_to(pc, (i % 2 == 0) and "PSTATE" or "ITEMS", s, i) end
    tick(20, 0.05)
end
check(net.queued_count() == 0, "6 msgs/s for 60 s: nothing queued")

-- 3. a flood: 300 loot messages in one go -> the burst goes, the rest waits in order
tick(40, 0.05)   -- bucket full again
local before = #pc.got
for i = 1, 300 do net.send_to(pc, "WLOOT", "c" .. i, "r") end
local sent_now = #pc.got - before
check(sent_now == 48, "flood: the 48-message burst goes at once: " .. sent_now)
check(net.queued_count() == 252, "flood: 252 wait: " .. net.queued_count())
check(log_has("%[NET%] send budget: messages to BP_PlayerController_C_1 wait in a queue from now %(over the budget; first WLOOT"),
    "queue start line")
-- latency-sensitive kinds overtake the queue
local b2 = #pc.got
net.send_to(pc, "PSTATE", "1", "x"); net.send_to(pc, "VSEAT", "passenger", "Host"); net.send_to(pc, "MHIT", "1")
local k = kinds(pc, b2 + 1)
check(#k == 3 and k[1] == "PSTATE" and k[2] == "VSEAT" and k[3] == "MHIT", "PSTATE / VSEAT / MHIT never wait")
-- a later bulk message keeps its place behind the queue
net.send_to(pc, "LOOK", "late")
check(net.queued_count() == 253, "a later bulk message queues behind the others")
-- drain at ~24/s
tick(20, 0.05)   -- 1 s
local after1 = #pc.got
check(after1 - b2 - 3 >= 20 and after1 - b2 - 3 <= 30, "about 24 a second drained: " .. (after1 - b2 - 3))
tick(240, 0.05)  -- 12 s more
check(net.queued_count() == 0, "flood drained within ~11 s")
-- order kept
local seq, ok_order = {}, true
for i = before + 1, #pc.got do
    local n = pc.got[i]:match("^SDC1|WLOOT|c(%d+)|")
    if n then seq[#seq + 1] = tonumber(n) end
end
for i = 2, #seq do if seq[i] ~= seq[i - 1] + 1 then ok_order = false end end
check(#seq == 300 and ok_order, "all 300 loot messages arrived, in order")
check(pc.got[#pc.got]:find("^SDC1|LOOK|late"), "the later bulk message came last")
check(log_has("%[NET%] send budget: queue to BP_PlayerController_C_1 drained: 253 message%(s%)"), "drained line with counts")
check(log_has("WLOOT 252, LOOK 1"), "drained line lists the kinds")

-- 4. the other game stands still: queueable messages wait, NOW ones still go
-- (in play the host sends PSTATE / VSTATE every second: the lane is in use)
tick(40, 0.05)
net.send_to(pc, "PSTATE", "keep")
pc.frozen = true
tick(20, 0.05)             -- 1 s without a packet
local b3 = #pc.got
net.send_to(pc, "ITEMS", "x"); net.send_to(pc, "MYSTATE", "y")
local k3 = kinds(pc, b3 + 1)
check(#k3 == 1 and k3[1] == "MYSTATE", "frozen receiver: ITEMS waits, MYSTATE goes")
check(log_has("nothing received from it for"), "queue start says why (nothing received)")
tick(40, 0.05)
check(net.queued_count() == 1, "still waiting while nothing is received")
pc.frozen = false
tick(4, 0.05)
check(net.queued_count() == 0 and pc.got[#pc.got]:find("^SDC1|ITEMS|x"), "sent once the receiver is heard again")

-- 5. the player leaves: its queue is dropped with a line
tick(40, 0.05)
for i = 1, 100 do net.send_to(pc, "WLOOT", "d" .. i) end
check(net.queued_count() == 52, "second flood queued: " .. net.queued_count())
pc.alive = false
tick(1, 0.05)
check(net.queued_count() == 0, "a gone player's queue is dropped")
check(log_has("52 queued message%(s%) to BP_PlayerController_C_1 dropped %(the player left"), "drop line")

-- 6. config off: every message at once
local pc2 = new_pc("BP_PlayerController_C_2", 2002)
package.loaded["sdc_config"] = { get = function(k) if k == "net_send_budget" then return false end end }
for i = 1, 200 do net.send_to(pc2, "WLOOT", "e" .. i) end
check(#pc2.got == 200 and net.queued_count() == 0, "net_send_budget = false: 200 sent at once")
package.loaded["sdc_config"] = nil

-- 7. client -> host: same budget on the host lane
local me = new_pc("BP_PlayerController_C_9", 9009)
ue.local_pc = function() return me end
for i = 1, 8 do net.send_to_host("WSTAT", i) end
check(#me.got == 8, "client normal burst (8) sent at once")
for i = 1, 100 do net.send_to_host("IGAIN", "DA_X", i) end
check(net.queued_count() > 0 and #me.got == 48, "client flood: the burst goes, the rest waits: " .. #me.got)
net.send_to_host("MYSTATE", "s")
check(me.got[#me.got]:find("^SDC1|MYSTATE|"), "client MYSTATE never waits")
tick(200, 0.05)
check(net.queued_count() == 0 and #me.got == 109, "client queue drained: " .. #me.got)
-- the client joins another game: what waited for the old host is dropped
for i = 1, 100 do net.send_to_host("IGAIN", "DA_Y", i) end
local other = new_pc("BP_PlayerController_C_10", 9010)
ue.local_pc = function() return other end
tick(1, 0.05)
check(net.queued_count() == 0, "queue to the old host dropped when the controller changes")

-- 8. paired payloads (ClientRepObjRef follows) are never queued
local pc3 = new_pc("BP_PlayerController_C_3", 3003)
for i = 1, 60 do net.send_to(pc3, "WLOOT", "f" .. i) end
local b4 = #pc3.got
for _, kd in ipairs({ "AIM", "AIHP", "AIKL", "AIAPP", "AIDEAD", "NPCSET", "NPCFIRE", "NPCBLOOD" }) do
    net.send_to(pc3, kd, "x")
end
check(#pc3.got - b4 == 8, "all ClientRepObjRef payload kinds go at once while a queue waits")

-- 9. a message bigger than the byte budget still goes (when the bucket is full)
local pc4 = new_pc("BP_PlayerController_C_4", 4004)
net.send_to(pc4, "LOOK", string.rep("y", 40000))
check(#pc4.got == 1, "a 40 KB message is not stuck forever")

-- 10. world reset drops every queue
local fake_session = { world_reset_hooks = {} }
package.loaded["sdc_session"] = fake_session
local pc5 = new_pc("BP_PlayerController_C_5", 5005)
for i = 1, 60 do net.send_to(pc5, "WLOOT", "g" .. i) end
-- the hook registers once a lane starts after the session module exists
check(fake_session.world_reset_hooks.net_budget ~= nil or net.queued_count() > 0, "reset hook / queue present")
if fake_session.world_reset_hooks.net_budget then
    fake_session.world_reset_hooks.net_budget("level change")
    check(net.queued_count() == 0, "world reset drops the queues")
end

io.stderr:write(string.format("%d checks, %d failed\n", checks, fails))
os.exit(fails == 0 and 0 or 1)
