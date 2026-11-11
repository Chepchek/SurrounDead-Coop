-- sdc_consume: client craft gate + queue, host craft report, host medical cure, desync detector
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
local ue = {}
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all() return {} end
local dirty = {}
local push = { __name = "push", MarkPropertyDirtyFromRepIndex = function(_, comp, idx, name) dirty[#dirty + 1] = idx .. name end }
function ue.find_object() return push end
local timers = {}
local ksl = { __name = "ksl",
  K2_IsTimerActive = function(_, o, n) return timers[n] ~= nil end,
  K2_SetTimer = function(_, o, n, t) timers[n] = t end,
  K2_ClearTimer = function(_, o, n) timers[n] = nil end }
function ue.ksl() return ksl end
function ue.local_pawn() return ue.__me end
local delayed = {}
function ue.delay(label, ms, fn) delayed[#delayed + 1] = fn end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
local cfgv = {}
package.loaded["sdc_log"] = log
ue.load_asset = ue.load_asset or function(p) return pcall(LoadAsset, p) end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function(k) if cfgv[k] ~= nil then return cfgv[k] end return true end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end, send_to_host = function() end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() return nil end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end

local items = require("sdc_items")
local consume = items.consume
local S = { role = "client", remote_pcs = {} }
items.init(S)

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local UI = "/Game/Inventory/Widgets/Crafting/W_PlayerCraftingUI.W_PlayerCraftingUI_C:"
local CLICK = "BndEvt__Button_81_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"

-- ---------------------------------------------------------------- client
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local slot1 = { __name = "slot1", ItemUniqueID = G(1), ItemCount = 4, JigDataAsset = { __name = "DA_Rag" } }
local mycomp = { __name = "MyJig", GetOwner = function() return me end,
  LocalJSIContainers = arr({ { __name = "cont", ArrayOfItems = arr({ slot1 }) } }) }
me.BP_JigMultiplayer = mycomp
local calls = {}
local enabled = true
local w = { __name = "craftui", __cls = "W_PlayerCraftingUI_C", CountIndex = 3, CraftIndex = 7,
  CurrentFaded = { __name = "faded" }, MPComponent = mycomp,
  JSIContainer_1 = { ClearContainer = function() calls[#calls + 1] = "clear" end },
  Button_81 = { GetIsEnabled = function() return enabled end },
  AddRequiredItems = function() calls[#calls + 1] = "required" end,
  ["Set Craftable Items"] = function() calls[#calls + 1] = "list" end }
w[CLICK] = function() calls[#calls + 1] = "click" end

items.client_tick()
assert(hooks[UI .. "CheckIngredientsAvailability"], "check hook missing")
assert(hooks[JIG .. "JigTryAddGetPendingRef"] and hooks[JIG .. "CLIENT_ItemCraftedResponse"], "client hooks missing")
local check, pend, answer = hooks[UI .. "CheckIngredientsAvailability"], hooks[JIG .. "JigTryAddGetPendingRef"],
  hooks[JIG .. "CLIENT_ItemCraftedResponse"]

-- a use that gives an item back (HotBarConsume -> JigTryAddItemSomewhere): not a craft
pend(C(mycomp))
answer(C(mycomp), P(G(9)), P({}), P(true), P(arr({})), P(arr({})))
assert(not has_log("craft answer"), "local add taken as a craft answer")

-- "craft 3": check passes, request, iteration 2 check, after-loop check
local p1 = P(true); check(C(w), p1); assert(p1.v == true)
pend(C(mycomp))
local p2 = P(true); check(C(w), p2); assert(p2.v == false, "second craft of the click not held back")
assert(w.CountIndex == 1, "CountIndex not set to the one sent")
local p3 = P(true); check(C(w), p3); assert(p3.v == false, "after-loop check not held back")
assert(has_log("2 more crafted one by one"), "queue not logged")

-- host answer: component consumed (count 0, gone in the view)
slot1.ItemUniqueID = G(2)
answer(C(mycomp), P(G(5)), P({ ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = { __name = "DA_Bandage" },
  Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 1 } }), P(true), P(arr({ G(1) })), P(arr({ 0 })))
assert(has_log("craft answer: success=true, Bandage x1"), "answer not logged")
assert(table.concat(calls, ",") == "clear,required,list", "refresh order: " .. table.concat(calls, ","))
assert(#delayed == 1, "next craft not scheduled")
delayed[1](); assert(calls[#calls] == "click", "queued click not run")
-- the queued click: one more request
local p4 = P(true); check(C(w), p4); assert(p4.v == true); pend(C(mycomp))
local p5 = P(true); check(C(w), p5); assert(p5.v == false)
answer(C(mycomp), P(G(5)), P({}), P(true), P(arr({ G(1) })), P(arr({ 0 })))
assert(#delayed == 2, "third craft not scheduled")
-- components ran out before the third: button disabled after refresh -> no more
enabled = false
delayed[2]()
local p6 = P(true); check(C(w), p6); pend(C(mycomp))
answer(C(mycomp), P(G(5)), P({}), P(true), P(arr({ G(1) })), P(arr({ 0 })))
assert(#delayed == 2, "crafted past the queue")

-- shown count differs from the host's -> warn
local p7 = P(true); check(C(w), p7); pend(C(mycomp))
slot1.ItemUniqueID = G(1)
answer(C(mycomp), P(G(5)), P({}), P(true), P(arr({ G(1) })), P(arr({ 2 })))
assert(has_log("not shown as the host has them", "warn"), "count mismatch not warned")
print("client: gate, queue and answer reports ok")

-- desync detector: an item only here, twice in a row
local itemsmod = package.loaded["sdc_items"]
itemsmod.host_item_uids = function() return { ["3:0:0:0"] = 1 }, 1, 0 end
consume.reset()
local t0 = os.clock()
consume.client_tick(); while os.clock() - t0 < 5.05 do end; consume.client_tick()
assert(has_log("not in the host's copy", "warn"), "desync not reported")
print("client: desync reported")

-- ---------------------------------------------------------------- host
S.role = "host"
logs = {}
consume.reset()
local med = { __name = "Med", ["Bleed?"] = true, ["HeavyBleed?"] = false, ["BrokenBone?"] = false, ["Infection?"] = false,
  Health = 40, MaxHealth = 100 }
local onrep_called = 0
med["OnRep_Bleed?"] = function() onrep_called = onrep_called + 1 end
local pc = { __name = "PC_bla", NetConnection = { __name = "conn" }, PassiveSkillsComponent = { __name = "sk", FirstAidMultiplier = 1 } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc, MedicalComponent = med }
med.GetOwner = function() return guest end
pc.__pawn = guest
local inv = { { n = 1, uid = 11, id = "DA_Rag" } }
local function mjc()
  local list = {}
  for _, e in ipairs(inv) do
    list[#list + 1] = { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = G(e.uid),
      ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = e.n,
        ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = { __name = e.id } } }
  end
  return arr({ { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = arr(list) } })
end
local taken = {}
local bjig = setmetatable({ __name = "BlaJig", GetOwner = function() return guest end,
  SERVER_RequestRemoveItem = function(_, target, g, n, cb)
    taken[#taken + 1] = { a = g.A, n = n, cb = cb }
    for i, e in ipairs(inv) do if e.uid == g.A then e.n = e.n - n; if e.n <= 0 then table.remove(inv, i) end break end end
  end }, { __index = function(_, k)
  if k == "MainJigContainers" then return mjc() end end })
guest.BP_JigMultiplayer = bjig
items.host_tick({ pc })
local PFN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local MFN = "/Game/Blueprints/Components/MedicalComponent.MedicalComponent_C:"
assert(hooks[JIG .. "SERVER_RequestCraftItem"] and hooks[PFN .. "ConsumeItem"] and hooks[MFN .. "OnRep_Bleed?"], "host hooks missing")
-- craft 1: rag consumed, bandage made
inv = { { n = 1, uid = 12, id = "DA_Bandage" } }
hooks[JIG .. "SERVER_RequestCraftItem"](C(bjig), P(bjig), P(3), P(arr({ G(11) })))
assert(has_log("Rag 1->gone") and has_log("new: Bandage x1"), "craft report wrong")
-- craft 2 with the same rag: free -> the new bandage is taken back
inv = { { n = 1, uid = 12, id = "DA_Bandage" }, { n = 1, uid = 13, id = "DA_Bandage" } }
hooks[JIG .. "SERVER_RequestCraftItem"](C(bjig), P(bjig), P(3), P(arr({ G(11) })))
assert(has_log("none of them was here: taken back [Bandage x1]", "warn"), "free craft not taken back")
assert(#taken == 1 and taken[1].a == 13 and taken[1].n == 1 and taken[1].cb == false and #inv == 1, "wrong item taken back")
-- free craft that stacked onto an existing stack: only the increase goes
inv = { { n = 1, uid = 12, id = "DA_Bandage" } }
items.host_tick({ pc })
inv = { { n = 3, uid = 12, id = "DA_Bandage" } }
hooks[JIG .. "SERVER_RequestCraftItem"](C(bjig), P(bjig), P(3), P(arr({ G(99) })))
assert(#taken == 2 and taken[2].a == 12 and taken[2].n == 2 and inv[1].n == 1, "stacked output not taken back")
-- a pickup right before a craft: the snapshot is renewed by the request, the craft is paid
inv = { { n = 1, uid = 12, id = "DA_Bandage" }, { n = 2, uid = 20, id = "DA_Rag" } }
hooks[JIG .. "SERVER_RequestAddActorToContainer"](C(bjig), P({}), P(G(0)), P(G(0)), P(0), P(false), P(false))
inv = { { n = 1, uid = 12, id = "DA_Bandage" }, { n = 1, uid = 20, id = "DA_Rag" }, { n = 1, uid = 21, id = "DA_Bandage" } }
hooks[JIG .. "SERVER_RequestCraftItem"](C(bjig), P(bjig), P(3), P(arr({ G(20) })))
assert(#taken == 2 and has_log("Rag 2->1"), "paid craft after a pickup taken back")
print("host: craft reports ok, free crafts taken back")

-- bandage used: ConsumeItem inside SERVER_RequestConsumeItem
local da = { __name = "DA_Bandage", ["CanBeConsumed?"] = true, RemoveMedicalEffects = arr({ "Bleed" }) }
local info = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = da,
  Stats_26_C770972746930CB80CC49AB7A6D19359 = arr({ { STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10 = { TagName = "Jig.ConsumableStat.Health" },
    MaxValue_8_04A5809A498E900862BCCA9A6E412BD7 = 25 } }) }
med.Health = 65
hooks[PFN .. "ConsumeItem"](C(guest), P(info))
assert(med["Bleed?"] == false and onrep_called == 1 and dirty[1] == "2Bleed?", "bleed not cured on the host")
assert(has_log("Health +25") and has_log("health 40->65/100") and has_log("cured on the host [Bleed]"), "cure log wrong")
inv = { { n = 1, uid = 13, id = "DA_Bandage" } }
hooks[JIG .. "SERVER_RequestConsumeItem"](C(bjig), P(bjig), P(G(12)), P(1), P(""))
assert(has_log("ConsumeItem ran on their character"), "use report wrong: " .. tostring(has_log("used Bandage x1")))
print("host: bleeding cured")

-- bleeding starts: stop timer on the host
med["Bleed?"] = true
hooks[MFN .. "OnRep_Bleed?"](C(med))
assert(timers.Time_Bleed and timers.Time_Bleed >= 10 and timers.Time_Bleed <= 12, "stop timer not set")
med["Bleed?"] = false
hooks[MFN .. "OnRep_Bleed?"](C(med))
assert(timers.Time_Bleed == nil, "stop timer not cleared")
-- the host's own character: untouched
local hostpawn = { __name = "Host", __cls = "BP_PlayerCharacter_C", Controller = { __name = "HPC" } }
local hmed = { __name = "HMed", ["Bleed?"] = true, GetOwner = function() return hostpawn end }
hooks[MFN .. "OnRep_Bleed?"](C(hmed))
assert(timers.Time_Bleed == nil, "host's own bleed got a timer")
print("host: stop timers ok")
for _, l in ipairs(logs) do if l:find("^err") and l:find("consume:", 1, true) then error("error logged: " .. l) end end
print("ALL OK")
