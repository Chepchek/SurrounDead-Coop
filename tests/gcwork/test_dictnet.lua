-- sdc_dict / NPCHP on the REAL sdc_net (netsim: fake controllers and clock).
-- usage: lua test_dictnet.lua <scripts dir>
local dir = arg[1]
local sim_mod = dofile(arg[0]:gsub("test_dictnet%.lua$", "netsim.lua"))
local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local sim = sim_mod.new(dir .. "/sdc_net.lua", dir)
local pc = sim.pc("BP_PlayerController_C_1", 1001)
sim.tick(40, 0.05)
local net = sim.net
package.loaded["sdc_net"] = net
check(net.PAIRED and net.PAIRED.NPCHP == true, "NPCHP is a PAIRED kind (its ClientRepObjRef follows it directly)")
check(net.NOW.NPCHP == true, "NPCHP is a NOW kind")
check(net.FAST and net.FAST.DICT == true and net.FAST.DICTQ == true, "DICT / DICTQ travel in the FAST lane (a look waiting for a definition)")
-- a connection that stopped answering: the paired kinds still leave at once, in order
net.send_to(pc, "PSTATE", 99, "keep")
pc.frozen = true
sim.tick(15, 0.05)
local before = #pc.got
net.send_to(pc, "NPCHP", "55")
check(#pc.got - before == 1, "NPCHP leaves at once even when the lane is stalled")
-- the real dictionary over the real sdc_net: a definition inside the message, ids after it
local dict = require("sdc_dict")
local e = dict.encoder("peer1", "n")
local t = e:ref("AI/Humans/Meshes/SK_Bandit_Test_Mesh.SK_Bandit_Test_Mesh")
local n0 = #pc.got
check(net.send_to(pc, "NPCSET", e:defs(), t) == true, "NPCSET with its definition accepted by the real queue")
e:commit()
check(#pc.got - n0 == 1 and pc.got[#pc.got]:find("=AI/Humans/Meshes/SK_Bandit_Test_Mesh", 1, true) ~= nil, "... and went out with the definition inside")
local e2 = dict.encoder("peer1", "n")
e2:ref("AI/Humans/Meshes/SK_Bandit_Test_Mesh.SK_Bandit_Test_Mesh")
check(e2:defs() == "", "the next one needs none")
-- a LOOK superseded in the queue never left: its on_out does not run; the newer one defines its own strings
do
    local sim2 = sim_mod.new(dir .. "/sdc_net.lua", dir)
    local pc2 = sim2.pc("BP_PlayerController_C_2", 2002)
    sim2.tick(40, 0.05)
    local n2 = sim2.net
    package.loaded["sdc_net"] = n2
    check(n2.congested(pc2) == false, "a healthy peer is not congested")
    n2.send_to(pc2, "PSTATE", 99, "keep")
    pc2.frozen = true
    sim2.tick(15, 0.05)
    check(n2.congested(pc2) == true, "a frozen peer is congested (the health waits)")
    local PATH = "PlayerModel/Torso/Meshes/Chr_Torso_Test_Mesh.Chr_Torso_Test_Mesh"
    local sent_ok = {}
    local function send_look(s)
        local e = dict.encoder("viewer", "q")
        local tok = e:ref(PATH)
        local msg_defs = e:defs()
        n2.send_to_cb(pc2, function() e:commit(); sent_ok[#sent_ok + 1] = s end, "LOOK", 7, msg_defs, tok .. "," .. s)
        return msg_defs
    end
    local d1 = send_look("h")
    local d2 = send_look("v")      -- supersedes the first one in the queue
    check(d1 ~= "" and d2 ~= "", "both defined the string: the first was not committed while it waited")
    pc2.frozen = false
    sim2.tick(80, 0.05)
    check(#sent_ok == 1 and sent_ok[1] == "v", "only the newer LOOK left the queue (its on_out ran once, the superseded one's did not)")
    local rcv = dict.decoder("rcv-viewer")
    local last = pc2.got[#pc2.got]
    local _, f = n2.decode(last)
    rcv:receive(f[2])
    check(f[1] == "7" and rcv:get(f[3]:match("^(~%w+),")) == PATH, "the receiver decodes the newer LOOK without a DICTQ")
    check(send_look("hv") == "", "after it really left, the next one needs no definition")
end
io.write(string.format("test_dictnet: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
