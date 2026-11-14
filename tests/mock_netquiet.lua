-- sdc_netsync: "send on change, verify rarely" (the net-quiet pass of 2026-11-14).
-- Unit checks of the per-peer last-sent record: a new peer gets everything, the
-- same state is not sent again, a change goes at once, the verify resends after
-- verify_s, a peer that said HI again / left knows nothing. The senders'
-- own idle traffic is measured in their mocks (NETQ lines: mock_bdoors,
-- mock_infection_hud, mock_knockdown, mock_mapmarks, mock_throw, mock_npc,
-- mock_look_scope, persist/mock_persist, loadtest/logic_roster).
-- usage: lua mock_netquiet.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local T = 100.0
os.clock = function() return T end
local sync = require("sdc_netsync")

check(sync.due("bob", "ROSTER", "a", 30) == true, "a new peer: due (the full state at once)")
check(sync.due("bob", "ROSTER", "a", 30) == true and sync.due("zed", "ROSTER", "a", 30) == true, "due() does not record: still due")
check(sync.known("bob", "ROSTER") == false, "due() records nothing")
check(sync.due_mark("bob", "ROSTER", "a", 30) == true, "due_mark: the first send")
check(sync.known("bob", "ROSTER") == true, "... now known")
check(sync.due_mark("bob", "ROSTER", "a", 30) == false, "the same state a moment later: not sent")
T = T + 29
check(sync.due_mark("bob", "ROSTER", "a", 30) == false, "29 s: still not sent")
T = T + 2
check(sync.due_mark("bob", "ROSTER", "a", 30) == true, "31 s: the verify sends the same state again")
check(sync.due_mark("bob", "ROSTER", "a", 30) == false, "and the verify clock starts over")
check(sync.due_mark("bob", "ROSTER", "b", 30) == true, "a change goes at once")
check(sync.due("bob", "ROSTER", "b", 30) == false and sync.due("bob", "ROSTER", "c", 30) == true, "due(): the same state not, a changed one yes")
check(sync.due_mark("bob", "ROSTER", "b", nil) == false, "no verify given: only changes")
T = T + 100000
check(sync.due_mark("bob", "ROSTER", "b", nil) == false, "... however long it takes")

check(sync.due_mark("gleb", "ROSTER", "b", 30) == true, "another peer has its own record")
check(sync.due_mark("bob", "LOOK:7", "x", 60) == true and sync.due_mark("bob", "LOOK:7", "x", 60) == false,
    "another key of the same peer has its own record")

sync.drop("bob")
check(sync.due("bob", "ROSTER", "b", 30) == true and sync.due("bob", "LOOK:7", "x", 60) == true,
    "a peer that said HI again (drop): everything due again")
check(sync.due("gleb", "ROSTER", "b", 30) == false, "... the others untouched")

sync.mark("gleb", "WBDOOR", "doors")
check(sync.due("gleb", "WBDOOR", "doors", 180) == false, "mark(): told by another way (a change message): not due")
sync.forget("gleb", "WBDOOR")
check(sync.due("gleb", "WBDOOR", "doors", 180) == true, "forget(): a failed send is retried")

sync.due_mark("ann", "ROSTER", "z", 30)
sync.prune({ gleb = true })
check(sync.known("gleb", "ROSTER") and not sync.known("ann", "ROSTER"), "prune(): a peer that is gone is forgotten")
sync.reset()
check(not sync.known("gleb", "ROSTER"), "reset(): everybody knows nothing")

local st = sync.stats
check(st.sent > 0 and st.skipped > 0 and st.verified >= 1 and st.changed >= 1 and st.fresh >= 1, "stats count what happened")


-- sdc_damage: a client's SKL (the strength multiplier) goes on a change and as the verify every 120 s
do
    local function auto() return setmetatable({}, { __index = function(t, k) local f = function() return nil end; rawset(t, k, f); return f end }) end
    local sent_skl = 0
    local comp = { StrengthMultiplier = 1.25 }
    local pc = { PassiveSkillsComponent = comp }
    local ue = auto()
    ue.valid = function(o) return type(o) == "table" end
    ue.prop = function(o, k) return type(o) == "table" and o[k] or nil end
    ue.local_pc = function() return pc end
    ue.local_pawn = function() return nil end
    ue.str = function(v) return tostring(v or "") end
    local net = auto()
    net.send_to_host = function(kind) if kind == "SKL" then sent_skl = sent_skl + 1 end return true end
    package.loaded["sdc_ue"], package.loaded["sdc_net"] = ue, net
    package.loaded["sdc_log"] = auto()
    package.loaded["sdc_config"] = auto()
    package.loaded["sdc_ctx"], package.loaded["sdc_items"], package.loaded["sdc_consume"] = auto(), auto(), auto()
    package.loaded["sdc_damage"] = nil
    local dmg = require("sdc_damage")
    dmg.init({ role = "client" })
    dmg.client_tick()
    check(sent_skl == 1, "damage: SKL told once")
    T = T + 60
    dmg.client_tick()
    check(sent_skl == 1, "damage: unchanged after 60 s: not again")
    T = T + 70
    dmg.client_tick()
    check(sent_skl == 2, "damage: the verify after 120 s")
    comp.StrengthMultiplier = 1.5
    dmg.client_tick()
    check(sent_skl == 3, "damage: a change at once")
    package.loaded["sdc_damage"] = nil
end

io.write(string.format("netquiet: %d checks, %d failed%s\n", checks, fails, fails == 0 and ", ALL OK" or ""))
os.exit(fails == 0 and 0 or 1)
