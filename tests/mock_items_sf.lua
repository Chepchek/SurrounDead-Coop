-- Items (review of the 13.11 logs, SDCoop 0.8.1):
--   A. ammo loaded into a magazine (a stack with fewer rounds, or merged
--      whole) is not a refused move: no CLIENT_MoveToIndexFailed, no WARN; a
--      real refusal still answered, with the count and the target slot;
--   B. an item the host has nowhere (a slot only the client shows, e.g. the
--      Rags a restore had replaced): moving it gets an answer - the client is
--      told it is gone (CLIENT_UpdateCount 0, once per item per 2 s; JMC rm
--      for a world container it was shown in); a merge the game answered and
--      an item still in the player's inventory get none; the repeats of one
--      request within 2 s only in the debug log;
--   C. the client asks the host about items only it shows (GHOSTQ), the host
--      ends those it does not have and sends ITEMS again for the others;
--   D. a big inventory is walked in slices over several frames (no 20-46 ms
--      frame every second), the tick uses the last finished walk; a walk the
--      inventory changed under (an inventory request, a container gone)
--      starts over and, after 3 restarts, is read whole in one frame - no
--      container skipped, the use / craft snapshot from after the request;
--      a reset / a missing ue.delay are handled.
-- (the restore's "clear" flag: tests/persist/mock_persist.lua sections 6, 9c,
-- 9d, 17; tests/mock_pull_persist.lua: a late id without an inventory)
-- usage: lua mock_items_sf.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local logs = {}
local log = setmetatable({ debug_enabled = false }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local function has_log(pat, kind)
  for _, l in ipairs(logs) do if l:find(pat, 1, true) and (not kind or l:sub(1, #kind) == kind) then return l end end
  return nil
end

-- clock: moved by the test, and by struct reads while `cost` is on (engine work)
local T, cost = 1000, 0
os.clock = function() return T end

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o) return ue.valid(o) and (rawget(o, "__cls") or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all() return {} end
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
local delayed, delay_fails = {}, {}
function ue.delay(label, ms, fn)
  if delay_fails[label] then return false end
  delayed[#delayed + 1] = { label = label, ms = ms, fn = fn }
  return #delayed
end
local function run_delayed(only)
  local n, keep = 0, {}
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do
    if not only or d.label == only then d.fn(); n = n + 1 else keep[#keep + 1] = d end
  end
  for _, d in ipairs(delayed) do keep[#keep + 1] = d end
  delayed = keep
  return n
end
local function pending(label)
  local n = 0
  for _, d in ipairs(delayed) do if d.label == label then n = n + 1 end end
  return n
end
function ue.pawn_of(pc) local p = pc and pc.Pawn; if ue.valid(p) then return p end end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and rawget(a, "__loc") end
function ue.hook_native() return true end
local inv_ms = {}   -- engine time of each h:items.inv part (the tick's, the slices')
function ue.sub_time(label, fn, ...)
  local t0 = T
  local ok, err = pcall(fn, ...)
  if label == "h:items.inv" then inv_ms[#inv_ms + 1] = (T - t0) * 1000 end
  if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
  return ok
end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local cfgv = { replicate_items = true, client_tools = false }
package.loaded["sdc_config"] = { get = function(k) local v = cfgv[k]; if v == nil then return true end return v end }
local sent, to_host, handlers = {}, {}, {}
package.loaded["sdc_net"] = {
  send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc, kind = kind, args = { ... } } end,
  broadcast = function() end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, args = { ... } }; return true end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (rawget(o, "__name") or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end

local function msgs(pc, kind)
  local out = {}
  for _, m in ipairs(sent) do if m.pc == pc and m.kind == kind then out[#out + 1] = m end end
  return out
end

-- ------------------------------------------------------------ server data
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"
local READ_MS = 0.02   -- engine time of one struct member read while `cost` is on

-- a struct: every member read costs engine time while `cost` is on
local function St(fields)
  return setmetatable({}, { __index = function(_, k) T = T + cost * READ_MS / 1000; return fields[k] end })
end
-- an array: ForEach stops on true, as UE4SS's does
local function arr(t) return { ForEach = function(_, f)
  for i, e in ipairs(t) do if f(i, { get = function() return e end }) == true then break end end
end, GetArrayNum = function() return #t end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end

-- items: { uid, da, n, slot, dur, subs } in containers { uid, items }; built
-- fresh on every read of MainJigContainers (the data can change between)
local function make_conts(list)
  local cl = {}
  for _, c in ipairs(list) do
    local il = {}
    for _, it in ipairs(c.items) do
      local s = {}
      for _, x in ipairs(it.subs or {}) do s[#s + 1] = St({ [F_SUB_ID] = G(x) }) end
      il[#il + 1] = St({ [F_USID] = G(it.uid), [F_MOTHER] = G(c.uid), [F_SLOT] = it.slot, [F_SUBS] = arr(s),
        [F_INFO] = St({ [F_COUNT] = it.n, [F_ITEMID] = { __name = it.da }, [F_DUR] = St({ X = it.dur or 100, Y = 100 }) }) })
    end
    cl[#cl + 1] = St({ [F_CONT_UID] = G(c.uid), [F_ITEMS] = arr(il) })
  end
  return arr(cl)
end
local function find(list, uid)
  for _, c in ipairs(list) do
    for i, it in ipairs(c.items) do if it.uid == uid then return it, c, i end end
  end
end

-- a remote player: controller, character, its JigComponent over `list`
local function player(name, list, loc)
  local pc = { __name = "PC_" .. name, NetConnection = { __name = "Conn_" .. name } }
  local pawn = { __name = name, __cls = "BP_PlayerCharacter_C", Controller = pc, Role = 3, __loc = loc or { X = 0, Y = 0, Z = 0 },
    MedicalComponent = { __name = "Med_" .. name, Health = 50 } }
  pc.Pawn = pawn
  local walks = 0
  local jig = { __name = "Jig_" .. name, __told = {}, __failed = {} }
  rawset(jig, "GetOwner", function() return pawn end)
  rawset(jig, "IsVendor", function() return false end)
  rawset(jig, "CLIENT_UpdateCount", function(self, target, g, n, pend)
    self.__told[#self.__told + 1] = { target = target, a = g.A, n = n, pend = pend and pend.A } end)
  rawset(jig, "CLIENT_MoveToIndexFailed", function(self, uids, target)
    self.__failed[#self.__failed + 1] = { a = uids[1].A, target = target } end)
  setmetatable(jig, { __index = function(_, k)
    if k == "MainJigContainers" then
      walks = walks + 1
      if jig.__broken then error("read error") end
      return make_conts(list)
    end
  end })
  pawn.BP_JigMultiplayer = jig
  return { pc = pc, pawn = pawn, jig = jig, list = list, walks = function() return walks end }
end

-- a world container (loot bag, zombie): its component over `list`
local function world(name, cls, key, list, loc)
  local actor = { __name = name, __cls = cls, __loc = loc or { X = 100, Y = 0, Z = 0 } }
  local comp = { __name = name .. "_Jig", MainContainersIDs = arr({ G(key) }) }
  rawset(comp, "GetOwner", function() return actor end)
  rawset(comp, "IsVendor", function() return false end)
  setmetatable(comp, { __index = function(_, k) if k == "MainJigContainers" then return make_conts(list) end end })
  return comp
end

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local items = require("sdc_items")
local consume = items.consume
-- (this file tests the slices of a walk: the continuous walk starts one every tick; the
-- event-driven start of walks is mock_consume_walk_events)
consume._t.walking.events = false
local containers = items.containers
local S = { role = "host", remote_pcs = {} }
items.init(S)
items.register_handlers()
items.install()
check(handlers.GHOSTQ ~= nil, "GHOSTQ handler registered")

-- ------------------------------------------------------------ A. magazines
print("A. ammo loaded into a magazine:")
-- pockets (1): 9mm x835 at slot 18, 9mm x20 at slot 19, the MP5 drum (40) with its capacity container 41
local dag_inv = {
  { uid = 1, items = { { uid = 30, da = "DA_9mmAmmo", n = 835, slot = 18 }, { uid = 31, da = "DA_9mmAmmo", n = 20, slot = 19 },
                       { uid = 40, da = "DA_MP5DrumMag", n = 1, slot = 2, subs = { 41 } },
                       { uid = 45, da = "DA_RadiationFilter", n = 1, slot = 4 } } },
  { uid = 41, items = {} },
}
local guest = player("guest", dag_inv)
items.host_tick({ guest.pc })
local same, comp_move = hooks[JIG .. "SERVER_SameContainer_MoveToIndex"], hooks[JIG .. "SERVER_RequestMoveItemToAnotherComp"]
check(same ~= nil and comp_move ~= nil, "move hooks in")
local function move_same(p, uid, to, idx, from_slot)
  same(C(p.jig), P(p.jig), P(G(uid)), P(G(to)), P(idx), P(false), P(from_slot or 0))
end
-- the game loaded 60 rounds into the empty drum: the stack stays with 775, a new stack in the drum
find(dag_inv, 30).n = 775
table.insert(dag_inv[2].items, { uid = 42, da = "DA_9mmAmmo", n = 60, slot = 0 })
logs = {}
move_same(guest, 30, 41, 0, 18)
check(#guest.jig.__failed == 0, "loaded magazine: no CLIENT_MoveToIndexFailed")
check(has_log("moved 9mmAmmo (uid 30:0:0:0) inside inventory of guest to slot 0: done (60 of 835 went in, the rest stays at slot 18)") ~= nil
  and not has_log("NOT moved", "warn"), "loaded magazine: logged as done, no WARN")
check(containers.stats.host_partial == 1, "counted as a partial move")
-- a second drum: 775 -> 715 (the snapshot was renewed after the first request)
find(dag_inv, 30).n = 715
logs = {}
move_same(guest, 30, 41, 0, 18)
check(#guest.jig.__failed == 0 and has_log("done (60 of 775 went in") ~= nil, "second magazine: 60 of 775, no failure")
-- the 20 rounds went whole into the drum's stack: the UID is gone, the plugin answered
local _, c31, i31 = find(dag_inv, 31)
table.remove(c31.items, i31)
find(dag_inv, 42).n = 80
logs = {}
local told0 = #guest.jig.__told
move_same(guest, 31, 41, 0, 19)
check(#guest.jig.__failed == 0 and #guest.jig.__told == told0, "merged whole into the magazine: no failure, nothing sent")
check(has_log("done (merged whole into a stack there: the plugin answered)") ~= nil and not has_log("NOT", "warn"), "merged whole: logged as done")
-- a full magazine (the plugin refused and answered itself): still answered, with the count and the target slot
logs = {}
move_same(guest, 30, 41, 0, 18)
check(#guest.jig.__failed == 1 and guest.jig.__failed[1].a == 30, "nothing loaded: the failure answer as before")
check(has_log("to slot 0: NOT moved (still at slot 18, x715; slot 0 there holds 9mmAmmo x80) - the client was told (CLIENT_MoveToIndexFailed)", "warn") ~= nil,
  "refusal logged with the count and what the target slot holds")
-- a filter onto an empty slot that did not move: a refusal, the slot's content in the log
logs = {}
move_same(guest, 45, 1, 8, 4)
check(#guest.jig.__failed == 2 and has_log("RadiationFilter (uid 45:0:0:0) inside inventory of guest to slot 8: NOT moved (still at slot 4, x1; slot 8 there holds nothing)", "warn") ~= nil,
  "filter refusal: count and target slot logged")

-- ------------------------------------------------------------ B. items the host has nowhere
print("B. moving an item the host has nowhere:")
local bag_inv = { { uid = 700, items = { { uid = 71, da = "DA_Rags", n = 1, slot = 0 } } } }
local bag = world("Container_RandomLoot_TrashBag73_5", "Container_RandomLoot_TrashBag_C", 700, bag_inv)
-- Rags x2 (uid 50): shown in the client's pockets, the host's inventory never had it
logs = {}
T = T + 1
comp_move(C(guest.jig), P(guest.jig), P(bag), P(G(50)), P(false), P(23), P(G(700)), P(0), P(G(0)), P(0))
local t = guest.jig.__told[#guest.jig.__told]
check(#guest.jig.__told == told0 + 1 and t.target == bag and t.a == 50 and t.n == 0 and t.pend == 50,
  "ghost moved to a bag: CLIENT_UpdateCount(bag, uid, 0, uid) - the slot goes, the bag's pending request ends")
check(#guest.jig.__failed == 2, "ghost: no CLIENT_MoveToIndexFailed (the slot would stay)")
check(has_log("gone from both, and not in their inventory before either (shown only on the client) - the client was told it is gone (CLIENT_UpdateCount 0)", "warn") ~= nil,
  "ghost move logged as a WARN with the answer")
-- the same request again at once (a held click): one answer
comp_move(C(guest.jig), P(guest.jig), P(bag), P(G(50)), P(false), P(23), P(G(700)), P(0), P(G(0)), P(0))
check(#guest.jig.__told == told0 + 1 and has_log("the client was told a moment ago") ~= nil, "repeated at once: answered once")
-- (review) a dozen of them: one WARN line, the repeats only in the debug log
for _ = 1, 10 do comp_move(C(guest.jig), P(guest.jig), P(bag), P(G(50)), P(false), P(23), P(G(700)), P(0), P(G(0)), P(0)) end
local function lines_of(pat)
  local by = {}
  for _, l in ipairs(logs) do
    if l:find(pat, 1, true) then local k = l:match("^(%a+):"); by[k] = (by[k] or 0) + 1 end
  end
  return by
end
local l50 = lines_of("(uid 50:0:0:0)")
check(#guest.jig.__told == told0 + 1 and (l50.warn or 0) == 1 and (l50.info or 0) == 0 and (l50.debug or 0) == 11,
  string.format("12 requests in a moment: 1 answer, 1 WARN line, 11 debug lines (%d / %d / %d)", l50.warn or 0, l50.info or 0, l50.debug or 0))
T = T + 3
comp_move(C(guest.jig), P(guest.jig), P(bag), P(G(50)), P(false), P(23), P(G(700)), P(0), P(G(0)), P(0))
check(#guest.jig.__told == told0 + 2 and (lines_of("(uid 50:0:0:0)").warn or 0) == 2, "again after 3 s: answered again, a WARN again")
-- a stack merged into the bag's rags (the host had it before): the game answered, nothing more
table.insert(dag_inv[1].items, { uid = 51, da = "DA_Rags", n = 2, slot = 7 })
T = T + 1
items.host_tick({ guest.pc })
local _, c51, i51 = find(dag_inv, 51)
table.remove(c51.items, i51)
bag_inv[1].items[1].n = 3
logs = {}
local told1 = #guest.jig.__told
comp_move(C(guest.jig), P(guest.jig), P(bag), P(G(51)), P(false), P(0), P(G(700)), P(0), P(G(0)), P(0))
check(#guest.jig.__told == told1 and has_log("gone from both: merged into a stack there (the plugin answered)") ~= nil
  and not has_log("gone from both", "warn"), "merged stack: nothing sent, no WARN")
-- a zombie guest has open shows an item the host no longer has there: JMC rm to guest + the pending request ends
local zinv = { { uid = 800, items = { { uid = 81, da = "DA_Bandage", n = 1, slot = 0 } } } }
local zombie = world("BP_Zombie_Infected_Horde_C_1", "BP_Zombie_Infected_Horde_C", 800, zinv)
containers.note_view(guest.pawn, zombie)
sent = {}
logs = {}
comp_move(C(guest.jig), P(zombie), P(guest.jig), P(G(60)), P(false), P(0), P(G(1)), P(0), P(G(0)), P(0))
run_delayed("containers-jmc")
local rm = false
for _, m in ipairs(msgs(guest.pc, "JMC")) do
  for i = 3, #m.args do if m.args[i] == "rm,60:0:0:0" then rm = true end end
end
t = guest.jig.__told[#guest.jig.__told]
check(rm, "from a zombie guest has open: JMC rm of the item to guest")
check(#guest.jig.__told == told1 + 1 and t.target == guest.jig and t.a == 60 and t.pend == 60, "and CLIENT_UpdateCount(own inventory, uid, 0, uid)")
check(has_log("gone from both (merged, or shown only on the client)") ~= nil and not has_log("gone from both", "warn"),
  "no snapshot of the zombie: not a WARN")
-- an item from a zombie into the bag that is in guest's inventory here: only that view was old - nothing sent
logs = {}
comp_move(C(guest.jig), P(zombie), P(bag), P(G(40)), P(false), P(0), P(G(700)), P(0), P(G(0)), P(0))
check(#guest.jig.__told == told1 + 1 and has_log("it is in their inventory here: nothing sent") ~= nil, "item in the own inventory here: nothing sent")
-- a same-container move of a ghost: told it is gone (was: a failure answer that kept the ghost)
logs = {}
local nf = #guest.jig.__failed
move_same(guest, 55, 1, 3, 0)
t = guest.jig.__told[#guest.jig.__told]
check(#guest.jig.__failed == nf and t.a == 55 and t.target == guest.jig and t.n == 0, "same-container move of a ghost: CLIENT_UpdateCount 0, no failure")
check(has_log("NOT there (not in their inventory before either: shown only on the client) - the client was told it is gone", "warn") ~= nil,
  "same-container ghost logged")
move_same(guest, 55, 1, 3, 0)
check(has_log("(uid 55:0:0:0) inside inventory of guest to slot 3: NOT there (not in their inventory before either: shown only on the client) - the client was told a moment ago", "debug") ~= nil
  and not has_log("(uid 55:0:0:0) inside inventory of guest to slot 3: NOT there (not in their inventory before either: shown only on the client) - the client was told a moment ago", "warn"),
  "same-container repeat at once: a debug line")
-- a normal move between components is unchanged: done, nothing sent
table.insert(dag_inv[1].items, { uid = 72, da = "DA_Bandage", n = 1, slot = 9 })
logs = {}
local told2 = #guest.jig.__told
comp_move(C(guest.jig), P(bag), P(guest.jig), P(G(72)), P(false), P(9), P(G(1)), P(0), P(G(0)), P(0))
check(#guest.jig.__told == told2 and #guest.jig.__failed == nf and has_log("from Container_RandomLoot_TrashBag73_5 to inventory of guest slot 9: done") ~= nil,
  "a normal move: done, nothing sent")

-- ------------------------------------------------------------ C. GHOSTQ
print("C. the client asks about items only it shows:")
-- host side: 66 is not in guest's inventory (ended), 30 is (the client's list was old: ITEMS again)
T = T + 10
items.host_tick({ guest.pc })
local items_before = #msgs(guest.pc, "ITEMS")
T = T + 1
items.host_tick({ guest.pc })
check(#msgs(guest.pc, "ITEMS") == items_before, "unchanged inventory: no ITEMS")
logs = {}
local told3 = #guest.jig.__told
handlers.GHOSTQ({ "66:0:0:0;30:0:0:0" }, guest.pc)
t = guest.jig.__told[#guest.jig.__told]
check(#guest.jig.__told == told3 + 1 and t.a == 66 and t.n == 0 and t.target == guest.jig, "GHOSTQ: the item the host lacks is ended (CLIENT_UpdateCount 0)")
check(has_log("guest's screen showed 1 item(s) their inventory here does not have", "warn") ~= nil, "GHOSTQ: WARN on the host")
check(has_log("guest asked about 1 item(s) that their inventory here has: the item list goes to them again (30:0:0:0)") ~= nil, "GHOSTQ: held item logged")
T = T + 1
items.host_tick({ guest.pc })
check(#msgs(guest.pc, "ITEMS") == items_before + 1, "GHOSTQ: ITEMS sent again although unchanged")
handlers.GHOSTQ({ "67:0:0:0" }, guest.pc)
check(#guest.jig.__told == told3 + 1, "GHOSTQ: one answer per player in 3 s")
-- a read error in the walk: nothing ended (a missing item could be a real one)
T = T + 5
guest.jig.__broken = true
handlers.GHOSTQ({ "68:0:0:0" }, guest.pc)
guest.jig.__broken = nil
check(#guest.jig.__told == told3 + 1 and has_log("could not be read in full", "warn") ~= nil, "GHOSTQ with a read error: nothing ended")
-- garbage: ignored
T = T + 5
handlers.GHOSTQ({ "not-a-uid;;" }, guest.pc)
check(#guest.jig.__told == told3 + 1, "GHOSTQ with no UID: nothing")
-- a non-player sender: ignored
T = T + 5
handlers.GHOSTQ({ "69:0:0:0" }, { __name = "PC_none" })
check(#guest.jig.__told == told3 + 1, "GHOSTQ from no character: nothing")

-- client side
S.role = "client"
items.reset()
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local view = {}
local pockets = setmetatable({ __name = "Pockets_W", ContainerName = "JSIContainer_Pockets" },
  { __index = function(_, k) if k == "ArrayOfItems" then return arr(view) end end })
local function slot(uid, da, n, idx)
  local s = { __name = "slot" .. uid, ItemUniqueID = G(uid), JigDataAsset = { __name = da }, ItemCount = n, SlotIndex = idx,
    IsPending = false, ContainerMother = pockets }
  view[#view + 1] = s
  return s
end
local mycomp = { __name = "MyJig", GetOwner = function() return me end, LocalJSIContainers = arr({ pockets }), PendingRequests = arr({}) }
me.BP_JigMultiplayer = mycomp
slot(10, "DA_Bandage", 1, 1)
slot(66, "DA_Rags", 2, 0)
handlers.ITEMS({ "10:0:0:0=100.0" })   -- the host's list: only the bandage
to_host, logs = {}, {}
T = T + 100
consume.client_tick()
check(#to_host == 0, "first check: not asked yet (an answer may be on its way)")
T = T + 6
consume.client_tick()
local q = to_host[#to_host]
check(q and q.kind == "GHOSTQ" and q.args[1] == "66:0:0:0", "second check, the same item: GHOSTQ with its UID")
check(has_log("not in the host's copy (they cannot be used or moved; the host is asked about them): Rags x2 (uid 66:0:0:0, JSIContainer_Pockets slot 0)", "warn") ~= nil,
  "the WARN names the item and its slot")
check(has_log("asked the host about 1 item(s) shown only in this inventory: 66:0:0:0") ~= nil, "the question logged")
T = T + 6
consume.client_tick()
check(#to_host == 1, "the same item 6 s later: not asked again yet")
T = T + 30
consume.client_tick()
check(#to_host == 2 and to_host[2].args[1] == "66:0:0:0", "asked again after 30 s")
-- the host's answer removed the slot: nothing more
table.remove(view, 2)
T = T + 40
consume.client_tick(); T = T + 6; consume.client_tick()
check(#to_host == 2, "gone from the screen: no question")
-- many: at most 16 per question
for i = 1, 20 do slot(100 + i, "DA_Can", 1, i) end
T = T + 6; consume.client_tick(); T = T + 6; consume.client_tick()
local n_uids = 0
for _ in to_host[#to_host].args[1]:gmatch("[^;]+") do n_uids = n_uids + 1 end
check(#to_host == 3 and n_uids == 16, "at most 16 items per question: " .. n_uids)
for i = #view, 2, -1 do table.remove(view, i) end

-- ------------------------------------------------------------ D. walks in slices
print("D. a big inventory walked in slices:")
S.role = "host"
items.reset()
-- 40 containers of 5 items (a friend's 79 containers / 204 items in 0.8.1)
local big = {}
for c = 1, 40 do
  local its = {}
  for i = 1, 5 do its[#its + 1] = { uid = c * 100 + i, da = "DA_Can", n = 1, slot = i - 1, dur = 100 } end
  big[#big + 1] = { uid = 5000 + c, items = its }
end
local ann = player("ann", big, { X = 9000, Y = 0, Z = 0 })
cost = 1
inv_ms, sent = {}, {}
T = T + 10
items.host_tick({ ann.pc })
check(ann.walks() == 1 and #inv_ms == 1 and inv_ms[1] > 30, string.format("first walk at once (as before): one frame of %.0f ms", inv_ms[1] or -1))
check(#msgs(ann.pc, "ITEMS") == 1, "ITEMS from the first walk")
-- next second: the tick does no walk, the last finished one is used, the walk goes on in slices
inv_ms = {}
T = T + 1
local w0 = ann.walks()
items.host_tick({ ann.pc })
check(ann.walks() == w0 and inv_ms[1] < 1, string.format("next tick: no walk in its frame (%.2f ms)", inv_ms[1] or -1))
check(pending("consume-walk") == 1, "the walk's first slice in a later frame")
-- the inventory changes meanwhile (a can's durability): the finished walk has it
find(big, 2003).dur = 50
local slices = 0
while pending("consume-walk") > 0 and slices < 200 do run_delayed("consume-walk"); slices = slices + 1 end
local worst = 0
for i = 2, #inv_ms do worst = math.max(worst, inv_ms[i]) end
check(slices >= 10 and ann.walks() == w0 + slices, string.format("walked in %d slices (one walk read per slice)", slices))
check(worst <= 3 + 1.5, string.format("no slice over the budget + one container: worst %.2f ms", worst))
check(consume.stats.walks_sliced == 1 and consume.stats.walk_slices == slices, "counted: 1 sliced walk")
local e = consume._t.walking.by["Jig_ann"]
check(e and e.inv and #e.inv.list == 200 and e.inv.by_uid["2003:0:0:0"].dur == 50, "the finished walk has all 200 items, the new durability")
check(consume._t.ledger()["Jig_ann"] == e.inv.by_uid, "the use / craft snapshot is the finished walk")
inv_ms = {}
T = T + 1
items.host_tick({ ann.pc })
local it2 = msgs(ann.pc, "ITEMS")
check(#it2 == 2 and it2[2].args[1]:find("2003:0:0:0=50.0", 1, true) ~= nil, "the next tick sends ITEMS from the finished walk")
-- (skeptic, 0.9.x) the inventory changes between two slices: the walk starts over
local function all_in(inv, list)
  local miss, n = {}, 0
  for _, c in ipairs(list) do
    for _, it in ipairs(c.items) do
      n = n + 1
      if not inv.by_uid[it.uid .. ":0:0:0"] then miss[#miss + 1] = it.uid end
    end
  end
  return #miss == 0 and #inv.list == n, table.concat(miss, ",")
end
-- an inventory request between slices: an item of an unread container (39)
-- moved into a read one (1); the request renews the use / craft snapshot
run_delayed("consume-walk"); run_delayed("consume-walk")
local job = consume._t.walking.by["Jig_ann"].job
check(job and job.done >= 2 and job.done < 39, "two slices read " .. tostring(job and job.done) .. " containers")
local r0 = consume.stats.walk_restarts
local _, c39, i39 = find(big, 3901)
local moved = table.remove(c39.items, i39)
moved.slot = 5
table.insert(big[1].items, moved)
T = T + 0.1
same(C(ann.jig), P(ann.jig), P(G(3901)), P(G(5001)), P(5), P(false), P(0))
local renewed = consume._t.ledger()["Jig_ann"]
while pending("consume-walk") > 0 do run_delayed("consume-walk") end
e = consume._t.walking.by["Jig_ann"]
local okall, miss = all_in(e.inv, big)
check(consume.stats.walk_restarts == r0 + 1, "an inventory request between slices: the walk started over")
check(okall and e.inv.by_uid["3901:0:0:0"] ~= nil, "the finished walk has every item, the moved one too (missing: " .. miss .. ")")
check(consume._t.ledger()["Jig_ann"] == e.inv.by_uid and e.inv.by_uid ~= renewed,
  "the walk (all of it after the request) is the use / craft snapshot")
-- a container gone at a position already read (a backpack put into a chest,
-- a rifle with its magazine dropped), no request seen: the rest would shift
-- by one and a container be skipped
T = T + 1
items.host_tick({ ann.pc })
run_delayed("consume-walk"); run_delayed("consume-walk")
job = consume._t.walking.by["Jig_ann"].job
check(job and job.done >= 3, "two slices read " .. tostring(job and job.done) .. " containers")
r0 = consume.stats.walk_restarts
table.remove(big, 2)
while pending("consume-walk") > 0 do run_delayed("consume-walk") end
e = consume._t.walking.by["Jig_ann"]
okall, miss = all_in(e.inv, big)
check(consume.stats.walk_restarts == r0 + 1, "a container gone between slices: the walk started over")
check(okall and e.inv.by_uid["201:0:0:0"] == nil, "the finished walk has every item, none of the gone container (missing: " .. miss .. ")")
T = T + 1
sent = {}
items.host_tick({ ann.pc })
local it3 = msgs(ann.pc, "ITEMS")[1]
local s3 = it3 and (";" .. it3.args[1]) or ""
local n3 = 0
for _ in s3:gmatch(";%d+:0:0:0=") do n3 = n3 + 1 end
check(n3 == 195 and not s3:find(";201:0:0:0=", 1, true), "ITEMS of the next tick: 195 items, not the gone ones (" .. n3 .. ")")
-- the player keeps changing it (a container more before every slice): after
-- MAX_RESTARTS the walk is read whole in one frame (as before the slices)
while pending("consume-walk") > 0 do run_delayed("consume-walk") end
T = T + 1
items.host_tick({ ann.pc })
r0 = consume.stats.walk_restarts
inv_ms = {}
local passes = 0
while consume._t.walking.by["Jig_ann"].job and passes < 40 do
  run_delayed("consume-walk")
  passes = passes + 1
  if consume._t.walking.by["Jig_ann"].job then
    big[#big + 1] = { uid = 9000 + passes, items = { { uid = 90000 + passes, da = "DA_Can", n = 1, slot = 0 } } }
  end
end
e = consume._t.walking.by["Jig_ann"]
okall, miss = all_in(e.inv, big)
local maxs = 0
for _, x in ipairs(inv_ms) do maxs = math.max(maxs, x) end
check(e.job == nil and passes == 5 and consume.stats.walk_restarts == r0 + 4,
  string.format("ever-changing inventory: finished after %d slices, %d restarts", passes, consume.stats.walk_restarts - r0))
check(okall, "and that walk has every item (missing: " .. miss .. ")")
check(maxs > 20, string.format("its last pass in one frame (%.0f ms)", maxs))
check(has_log("started over 4 time(s)", "debug") ~= nil, "logged (debug)")
-- a reset during a walk: its slices do nothing
T = T + 1
items.host_tick({ ann.pc })
check(pending("consume-walk") == 1, "a new walk started")
items.reset()
local w1 = ann.walks()
run_delayed("consume-walk")
check(ann.walks() == w1 and pending("consume-walk") == 0, "after a reset the old walk's slice does nothing")
-- without ue.delay: the walk goes on one slice per tick
T = T + 1
items.host_tick({ ann.pc })   -- (after the reset: the first walk at once again)
delay_fails["consume-walk"] = true
T = T + 1
w1 = ann.walks()
items.host_tick({ ann.pc })
check(ann.walks() == w1, "no ue.delay: the walk waits for the next tick")
T = T + 1
items.host_tick({ ann.pc })
check(ann.walks() == w1 + 1, "the next tick does one slice")
local ticks = 0
while consume._t.walking.by["Jig_ann"].job and ticks < 100 do T = T + 1; items.host_tick({ ann.pc }); ticks = ticks + 1 end
check(consume._t.walking.by["Jig_ann"].job == nil and ticks > 5, "and the ticks finish it (" .. ticks .. " more)")
delay_fails["consume-walk"] = nil
-- a small inventory: walked at once each tick (as before)
cost = 0
T = T + 1
items.host_tick({ ann.pc })
while pending("consume-walk") > 0 do run_delayed("consume-walk") end
w1 = ann.walks()
T = T + 1
items.host_tick({ ann.pc })
check(ann.walks() == w1 + 1 and pending("consume-walk") == 0, "a cheap walk: at once, in the tick")
-- the player left: its walk goes
T = T + 1
items.host_tick({})
check(consume._t.walking.by["Jig_ann"] == nil, "a player who left: walk forgotten")

for _, l in ipairs(logs) do
  if l:find("^err") then print("  error logged: " .. l); fails = fails + 1 end
end
print(string.format("mock_items_sf: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
