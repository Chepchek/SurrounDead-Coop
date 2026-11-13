-- world containers: the plugin's unreliable multicasts sent reliably (JMC), refused
-- moves answered (CLIENT_MoveToIndexFailed), missing adds asked for (JADD), the
-- client applying them with the game's own handlers, stuck pending slots
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path
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
local real_clock = os.clock
local offset = 0
os.clock = function() return real_clock() + offset end
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return o.__path end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all() return {} end
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
local delayed = {}
function ue.delay(_, _, fn) delayed[#delayed + 1] = fn end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned(o) return o.__runtime == true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
function ue.hook_native() return true end
local to_host, to_client, handlers = {}, {}, {}
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local cfgv = {}
package.loaded["sdc_config"] = { get = function(k) if cfgv[k] ~= nil then return cfgv[k] end return true end }
-- (0.7.3: JMC|*|<key>|<op,args>|...: one entry per op, as the single form JMC|<op>|<key>|<args> was;
-- whole numbers as numbers, as the host passed them before)
local function jmc_ops(pc, f)
  if f[1] ~= "*" then to_client[#to_client + 1] = { pc = pc, kind = "JMC", f = f }; return end
  for i = 3, #f do
    local one = {}
    for part in (f[i] .. ","):gmatch("([^,]*),") do one[#one + 1] = part:match("^%-?%d+$") and tonumber(part) or part end
    table.insert(one, 2, f[2])
    to_client[#to_client + 1] = { pc = pc, kind = "JMC", f = one }
  end
end
package.loaded["sdc_net"] = { broadcast = function() end,
  send_to = function(pc, kind, ...) if kind == "JMC" then jmc_ops(pc, { ... }) end end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind, ... } end, on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn)
  assert(not hooks[path], "second RegisterHook on " .. path)
  hooks[path] = fn; return 1, 2
end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end,
  GetArrayNum = function() return #t end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"

local items = require("sdc_items")
local S = { role = "host", remote_pcs = {} }
items.init(S)
items.register_handlers()
assert(handlers.JMC and handlers.JADD, "handlers missing")

-- ---------------------------------------------------------------- host
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc, __loc = { X = 0, Y = 0, Z = 0 } }
pc.__pawn = guest
local failed, readded = {}, {}
local djig = { __name = "GuestJig", GetOwner = function() return guest end, MainJigContainers = arr({}),
  IsVendor = function() return false end,
  CLIENT_MoveToIndexFailed = function(_, uids, target) failed[#failed + 1] = { a = uids[1].A, target = target } end,
  CLIENT_AddNewItem = function(_, info, content, comp, pend) readded[#readded + 1] = { info = info, content = content, comp = comp, pend = pend } end }
guest.BP_JigMultiplayer = djig
local crate = { __name = "Container_MedicalLoot_MedicalCrate2_C_33", __cls = "Container_MedicalLoot_MedicalCrate2_C",
  __loc = { X = 200, Y = 0, Z = 0 }, JigCanInteract = function(_, out) out.Result = true end }
-- the chest's server data: rags (7) at slot 4, a bag (8) at slot 0 with a bandage (9) inside
local function item(uid, da, n, mother, slot, subs)
  local s = {}
  for _, x in ipairs(subs or {}) do s[#s + 1] = { [F_SUB_ID] = G(x) } end
  return { [F_USID] = G(uid), [F_MOTHER] = G(mother), [F_SLOT] = slot, [F_SUBS] = arr(s),
           [F_INFO] = { [F_COUNT] = n, [F_ITEMID] = { __name = da } } }
end
local rags = item(7, "DA_Rags", 3, 500, 4)
local bag = item(8, "DA_MedBag", 1, 500, 0, { 600 })
local bandage = item(9, "DA_Bandages", 2, 600, 0)
local chest_items, bag_items = { rags, bag }, { bandage }
local chest = { __name = "ChestJig", GetOwner = function() return crate end, MainContainersIDs = arr({ G(500) }),
  IsVendor = function() return false end,
  MainJigContainers = { ForEach = function(_, f)
    f(1, { get = function() return { [F_CONT_UID] = G(500), [F_ITEMS] = arr(chest_items) } end })
    f(2, { get = function() return { [F_CONT_UID] = G(600), [F_ITEMS] = arr(bag_items) } end })
  end } }
items.host_tick({ pc })
-- (0.7.3: the JMC ops of a tick go together a moment later; here right after each call)
local containers = require("sdc_containers")
for p, fn in pairs(hooks) do hooks[p] = function(...) fn(...); containers.flush_viewers() end end
for _, f in ipairs({ "MC_MoveItemToIndex", "MC_ItemRemoved", "MC_AddNewItem", "MC_UpdateStack", "MC_UpdateCount",
    "MC_UpdateCounts", "MC_SameCompUpdateSplitRequest", "MC_NewItemAdded", "MC_UpdateDurability", "MC_OnPendingDone",
    "SERVER_RequestSplitItem",
    "SERVER_SameContainer_MoveToIndex", "SERVER_RequestMoveItemToAnotherComp", "SERVER_RequestData" }) do
  assert(hooks[JIG .. f], "hook missing: " .. f)
end
-- a multicast before anyone opened the chest: nothing sent
hooks[JIG .. "MC_ItemRemoved"](C(chest), P(G(7)))
assert(#to_client == 0, "sent to nobody's open chest")
-- guest opens it
hooks[JIG .. "SERVER_RequestData"](C(djig), P(chest))
assert(has_log("guest opened Container_MedicalLoot_MedicalCrate2_C_33"), "open log")
-- the plugin's multicasts on it -> reliable copies to guest
hooks[JIG .. "MC_MoveItemToIndex"](C(chest), P(chest), P(G(7)), P(G(500)), P(4), P(false))
local m = to_client[#to_client]
assert(m and m.pc == pc and m.kind == "JMC" and m.f[1] == "mv" and m.f[2] == "500:0:0:0" and m.f[3] == "7:0:0:0"
  and m.f[4] == "500:0:0:0" and m.f[5] == 4 and m.f[6] == 0, "mv not forwarded")
hooks[JIG .. "MC_ItemRemoved"](C(chest), P(G(7)))
assert(to_client[#to_client].f[1] == "rm" and to_client[#to_client].f[3] == "7:0:0:0", "rm not forwarded")
hooks[JIG .. "MC_AddNewItem"](C(chest), P(rags), P(arr({})))
assert(to_client[#to_client].f[1] == "add" and to_client[#to_client].f[3] == "7:0:0:0", "add not forwarded")
hooks[JIG .. "MC_UpdateStack"](C(chest), P(G(7)), P(0), P(G(8)), P(5))
assert(to_client[#to_client].f[1] == "stk" and to_client[#to_client].f[4] == 0 and to_client[#to_client].f[6] == 5, "stk not forwarded")
hooks[JIG .. "MC_UpdateCount"](C(chest), P(G(7)), P(2), P(G(0)))
assert(to_client[#to_client].f[1] == "cnt" and to_client[#to_client].f[4] == 2, "cnt not forwarded")
assert(has_log("mv 7:0:0:0 500:0:0:0 4 0 in Container_MedicalLoot_MedicalCrate2_C_33 -> guest"), "forward log")
-- a player's own inventory multicast? (not a world container): nothing
local n0 = #to_client
hooks[JIG .. "MC_ItemRemoved"](C(djig), P(G(7)))
assert(#to_client == n0, "player inventory forwarded")
-- guest walked away (40 m): nothing more
guest.__loc = { X = 4000, Y = 0, Z = 0 }
hooks[JIG .. "MC_ItemRemoved"](C(chest), P(G(7)))
assert(#to_client == n0, "sent to a player far away")
guest.__loc = { X = 0, Y = 0, Z = 0 }
print("host: world container multicasts sent reliably to the player who has it open")

-- moves inside the chest: done / refused (no answer from the game) -> the failure answer
hooks[JIG .. "SERVER_SameContainer_MoveToIndex"](C(djig), P(chest), P(G(7)), P(G(500)), P(4), P(false), P(2))
assert(#failed == 0 and has_log("guest moved Rags (uid 7:0:0:0) inside Container_MedicalLoot_MedicalCrate2_C_33 to slot 4: done"), "done move")
hooks[JIG .. "SERVER_SameContainer_MoveToIndex"](C(djig), P(chest), P(G(7)), P(G(500)), P(9), P(false), P(4))
assert(#failed == 1 and failed[1].a == 7 and failed[1].target == chest, "refused move not answered")
-- (0.9.x: the log names the count and what the target slot holds on the host)
assert(has_log("to slot 9: NOT moved (still at slot 4, x3; slot 9 there holds nothing) - the client was told (CLIENT_MoveToIndexFailed)", "warn"), "refused log")
-- chest -> inventory: still in the chest = refused; the pending slot is in the receiving component
hooks[JIG .. "SERVER_RequestMoveItemToAnotherComp"](C(djig), P(chest), P(djig), P(G(8)), P(false), P(3), P(G(1)), P(0), P(G(0)), P(0))
assert(#failed == 2 and failed[2].a == 8 and failed[2].target == djig, "refused comp move not answered")
-- moved: in the inventory now
local inv_items = { item(8, "DA_MedBag", 1, 1, 3) }
table.remove(chest_items, 2)
djig.MainJigContainers = arr({ { [F_CONT_UID] = G(1), [F_ITEMS] = arr(inv_items) } })
hooks[JIG .. "SERVER_RequestMoveItemToAnotherComp"](C(djig), P(chest), P(djig), P(G(8)), P(false), P(3), P(G(1)), P(0), P(G(0)), P(0))
assert(#failed == 2 and has_log("guest moved MedBag x1 (uid 8:0:0:0) from Container_MedicalLoot_MedicalCrate2_C_33 to inventory of guest slot 3: done"), "comp move done")
table.insert(chest_items, bag)
-- the client still misses the bag: sent again, with what is inside it
handlers.JADD({ "500:0:0:0", "8:0:0:0" }, pc)
assert(#readded == 1 and readded[1].info == bag and readded[1].comp == chest and #readded[1].content == 1
  and readded[1].content[1] == bandage and readded[1].pend.A == 0, "item not sent again")
handlers.JADD({ "500:0:0:0", "8:0:0:0" }, pc)
assert(#readded == 1, "asked twice at once")
handlers.JADD({ "999:0:0:0", "8:0:0:0" }, pc)
assert(#readded == 1, "unknown container answered")
print("host: refused moves answered, a missing add sent again with its content")

-- the other multicasts: counts, a split in the chest, an item made into it, durability, crafts done
local U_UID, U_COUNT = "UID_2_DC6DBB72457305316FAC19A4399A1CB5", "NewCount_5_31E28E124BF695AFBB001A87164F9121"
local function last_ops(n)
  local out = {}
  for i = #to_client - n + 1, #to_client do out[#out + 1] = table.concat(to_client[i].f, "|") end
  return table.concat(out, " ; ")
end
local n1 = #to_client
hooks[JIG .. "MC_UpdateCounts"](C(chest), P(arr({ { [U_UID] = G(7), [U_COUNT] = 2 }, { [U_UID] = G(9), [U_COUNT] = 1 } })))
assert(#to_client == n1 + 2 and last_ops(2) == "cnt|500:0:0:0|7:0:0:0|2 ; cnt|500:0:0:0|9:0:0:0|1", "counts: " .. last_ops(2))
hooks[JIG .. "MC_SameCompUpdateSplitRequest"](C(chest), P(G(7)), P(1), P({}), P(G(12)), P(G(500)), P(6), P(false))
assert(last_ops(2) == "cnt|500:0:0:0|7:0:0:0|1 ; add|500:0:0:0|12:0:0:0", "split: " .. last_ops(2))
hooks[JIG .. "MC_NewItemAdded"](C(chest), P({}), P(G(13)), P(G(500)), P(7), P(false), P({ [U_UID] = G(7), [U_COUNT] = 1 }), P(arr({})))
assert(last_ops(2) == "add|500:0:0:0|13:0:0:0 ; cnt|500:0:0:0|7:0:0:0|1", "new item: " .. last_ops(2))
hooks[JIG .. "MC_NewItemAdded"](C(chest), P({}), P(G(14)), P(G(500)), P(8), P(false), P({ [U_UID] = G(0), [U_COUNT] = 1 }), P(arr({})))
assert(last_ops(1) == "add|500:0:0:0|14:0:0:0", "new item without count: " .. last_ops(1))
hooks[JIG .. "MC_UpdateDurability"](C(chest), P(G(8)), P({ X = 42.5, Y = 100 }))
assert(last_ops(1) == "dur|500:0:0:0|8:0:0:0|42.500|100.000", "dur: " .. last_ops(1))
hooks[JIG .. "MC_OnPendingDone"](C(chest), P(arr({ rags })))
assert(last_ops(1) == "done|500:0:0:0|7:0:0:0", "done: " .. last_ops(1))
-- a split in the chest: done (a new stack at the slot) / refused (nothing there) -> the failure answer
table.insert(chest_items, item(12, "DA_Rags", 1, 500, 6))
local nf = #failed
hooks[JIG .. "SERVER_RequestSplitItem"](C(djig), P(chest), P(chest), P(G(7)), P(G(500)), P(6), P(1), P(false))
assert(#failed == nf and has_log("guest split 1 off Rags (uid 7:0:0:0) to Container_MedicalLoot_MedicalCrate2_C_33 slot 6: done (new stack 12:0:0:0 x1)"), "split done")
hooks[JIG .. "SERVER_RequestSplitItem"](C(djig), P(chest), P(chest), P(G(7)), P(G(500)), P(11), P(1), P(false))
assert(#failed == nf + 1 and failed[#failed].a == 7 and failed[#failed].target == chest, "refused split not answered")
assert(has_log("to Container_MedicalLoot_MedicalCrate2_C_33 slot 11: NOT split - the client was told (CLIENT_MoveToIndexFailed)", "warn"), "refused split log")
print("host: counts, splits, new items, durability and done crafts sent reliably; a refused split answered")

-- ---------------------------------------------------------------- client
S.role = "client"
items.reset()
logs = {}
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local mycomp = { __name = "MyJig", GetOwner = function() return me end, LocalJSIContainers = arr({}), PendingRequests = arr({}) }
me.BP_JigMultiplayer = mycomp
-- (0.7.3: the Jig_UnhandledEvent hook, which only logs this player's move requests, is on with config debug)
log.debug_enabled = true
items.client_tick()
assert(hooks[JIG .. "Jig_UnhandledEvent"] and hooks[JIG .. "CLIENT_ContainerDataResponse"], "client hooks missing")
local ccrate = { __name = "Container_MedicalLoot_MedicalCrate2_C_33", __cls = "Container_MedicalLoot_MedicalCrate2_C" }
local jsi = { __name = "Crate_W", ContainerName = "CRATE", ContainerID = G(500) }
local shown, cpending, moved, stacks, counts, unpended = {}, {}, {}, {}, {}, {}
local function slot(uid, da, idx, pend)
  local s = { __name = "slot" .. uid, ItemUniqueID = G(uid), JigDataAsset = { __name = da }, SlotIndex = idx,
    IsPending = pend, ContainerMother = jsi, ItemCount = 1 }
  s.RemoveFromJSIParent = function(self) self.__valid = false; for i, x in ipairs(shown) do if x == self then table.remove(shown, i) end end end
  shown[#shown + 1] = s
  return s
end
local cchest = { __name = "CChestJig", __cls = "BP_JigComponent_C", GetOwner = function() return ccrate end,
  LocalJSIContainers = arr({ jsi }),
  DeepSearchForItem = function(_, g, out) for _, s in ipairs(shown) do if s.ItemUniqueID.A == g.A then out.ItemFound = s end end end,
  HandleClientMoveItemToIndex = function(_, g, to, idx, rot) moved[#moved + 1] = { a = g.A, to = to.A, idx = idx, rot = rot }
    for _, s in ipairs(shown) do if s.ItemUniqueID.A == g.A then s.SlotIndex = idx; s.IsPending = false end end end,
  FuncHandleStackResponse = function(_, d, dn, r, rn) stacks[#stacks + 1] = { d.A, dn, r.A, rn } end,
  ClientUpdateCount = function(_, g, n, rm) counts[#counts + 1] = { g.A, n, rm } end,
  RemoveRequestByUID = function(_, g, clear, out)
    for i, s in ipairs(cpending) do if s.ItemUniqueID.A == g.A then table.remove(cpending, i); s.IsPending = false
      unpended[#unpended + 1] = { g.A, clear }; out.Removed = true; return end end
    out.Removed = false end }
setmetatable(cchest, { __index = function(_, k) if k == "PendingRequests" then return arr(cpending) end end })
-- the chest is opened: the host's contents arrive
hooks[JIG .. "CLIENT_ContainerDataResponse"](C(mycomp), P(arr({ G(500) })), P(arr({ 1, 2 })), P(cchest), P(arr({})))
assert(has_log("contents of Container_MedicalLoot_MedicalCrate2_C_33"), "answer log")
-- the player drags the rags inside the chest: the move is logged
local r = slot(7, "DA_Rags", 2, true)
cpending[#cpending + 1] = r
hooks[JIG .. "Jig_UnhandledEvent"](C(cchest), P(jsi), P(jsi), P(4), P(r), P(false), P(1))
assert(has_log("move of Rags x1 (uid 7:0:0:0) asked: CRATE -> CRATE slot 4 (pending)"), "move asked log")
-- the plugin's multicast was lost; the reliable copy moves it with the game's handler
handlers.JMC({ "mv", "500:0:0:0", "7:0:0:0", "500:0:0:0", "4", "0" })
assert(#moved == 1 and moved[1].a == 7 and moved[1].to == 500 and moved[1].idx == 4 and moved[1].rot == false, "move not applied")
assert(r.SlotIndex == 4 and r.IsPending == false, "still pending")
-- the same answer again (the multicast after all): already shown, not applied twice
handlers.JMC({ "mv", "500:0:0:0", "7:0:0:0", "500:0:0:0", "4", "0" })
assert(#moved == 1, "applied twice")
-- taken by the host / moved out: the copy shown here goes
handlers.JMC({ "rm", "500:0:0:0", "7:0:0:0" })
assert(r.__valid == false and #shown == 0 and has_log("7:0:0:0 is no longer in Container_MedicalLoot_MedicalCrate2_C_33 on the host"), "stale copy not removed")
handlers.JMC({ "rm", "500:0:0:0", "7:0:0:0" })
-- an add the multicast did not bring: asked for after a moment; one that arrived: not
handlers.JMC({ "add", "500:0:0:0", "8:0:0:0" })
slot(9, "DA_Bandages", 1, false)
handlers.JMC({ "add", "500:0:0:0", "9:0:0:0" })
for _, f in ipairs(delayed) do f() end
delayed = {}
assert(#to_host == 1 and to_host[1][1] == "JADD" and to_host[1][2] == "500:0:0:0" and to_host[1][3] == "8:0:0:0", "missing add not asked for")
-- stack / count with the game's handlers
handlers.JMC({ "stk", "500:0:0:0", "7:0:0:0", "0", "9:0:0:0", "5" })
handlers.JMC({ "cnt", "500:0:0:0", "9:0:0:0", "3" })
assert(#stacks == 1 and stacks[1][1] == 7 and stacks[1][2] == 0 and stacks[1][3] == 9 and stacks[1][4] == 5, "stack not applied")
assert(#counts == 1 and counts[1][1] == 9 and counts[1][2] == 3 and counts[1][3] == true, "count not applied")
-- durability and a timed craft done, with the game's own handlers
local durs = {}
cchest.ClientFunc_UpdateDurability = function(_, g, d) durs[#durs + 1] = { g.A, d.X, d.Y } end
handlers.JMC({ "dur", "500:0:0:0", "9:0:0:0", "42.500", "100.000" })
assert(#durs == 1 and durs[1][1] == 9 and durs[1][2] == 42.5 and durs[1][3] == 100, "durability not applied")
local crafted = slot(15, "DA_Bandages", 7, true)
crafted.SetPending = function(self, v) self.IsPending = v end
handlers.JMC({ "done", "500:0:0:0", "15:0:0:0" })
assert(crafted.IsPending == false and has_log("15:0:0:0 in Container_MedicalLoot_MedicalCrate2_C_33 is done on the host: it stops blinking"), "done not applied")
handlers.JMC({ "done", "500:0:0:0", "15:0:0:0" })
assert(crafted.IsPending == false, "done twice")
crafted:RemoveFromJSIParent()
-- another container (not open here): ignored
handlers.JMC({ "rm", "777:0:0:0", "9:0:0:0" })
assert(#shown == 1, "other container touched")
print("client: reliable copies applied with the game's handlers, once")

-- a pending slot of the open chest that nobody answers: stops blinking after a while
local stuck = slot(11, "DA_Rags", 6, true)
cpending[#cpending + 1] = stuck
items.client_tick()
offset = offset + 9
items.client_tick()
assert(#unpended >= 1 and unpended[#unpended][1] == 11 and unpended[#unpended][2] == false and stuck.IsPending == false
  and stuck.__valid ~= false, "stuck slot not un-pended")
assert(has_log("Rags (uid 11:0:0:0) in Container_MedicalLoot_MedicalCrate2_C_33 waited", "warn"), "stuck log")
-- switched off: nothing applied
cfgv.container_moves_reliable = false
handlers.JMC({ "cnt", "500:0:0:0", "9:0:0:0", "1" })
assert(#counts == 1, "option ignored")
cfgv.container_moves_reliable = nil
print("client: a stuck pending slot stops blinking where it is")
for _, l in ipairs(logs) do if l:find("^err") then error("error logged: " .. l) end end
print("ALL OK")
