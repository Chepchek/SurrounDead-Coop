-- sdc_consume: items a use gives (client placeholder removal + IGAIN, host: where the client's screen put it),
-- local drop removal, stale pending slots, desync line with slots
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
local assets = {}
function ue.find_object(p) return assets[p] end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
function ue.delay() end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
local sent, handlers = {}, {}
package.loaded["sdc_log"] = log
ue.load_asset = ue.load_asset or function(p) return pcall(LoadAsset, p) end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end,
  send_to_host = function(kind, ...) sent[#sent + 1] = { kind, ... } end, on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function(p) assets[p] = assets["later:" .. p] end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end

local items = require("sdc_items")
local consume = items.consume
local S = { role = "client", remote_pcs = {} }
items.init(S)
items.register_handlers()
assert(handlers.IGAIN, "IGAIN handler not registered")

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local PFN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"

-- ---------------------------------------------------------------- client
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local cont = { __name = "Backpack_W", ContainerName = "BACKPACK" }
local pending = {}
local removed_uids = {}
local unpended_uids = {}
local mycomp = { __name = "MyJig", GetOwner = function() return me end }
mycomp.RemoveRequestByUID = function(_, uid, clear, out)
  for i, s in ipairs(pending) do
    if s.ItemUniqueID.A == uid.A then
      table.remove(pending, i); s.IsPending = false
      if clear == true then s.ContainerMother = nil; removed_uids[#removed_uids + 1] = uid.A
      else unpended_uids[#unpended_uids + 1] = uid.A end
      out.Removed = true; return
    end
  end
  out.Removed = false
end
local view = {}
mycomp.LocalJSIContainers = arr({ setmetatable({ __name = "Backpack_W", ContainerName = "BACKPACK" },
  { __index = function(_, k) if k == "ArrayOfItems" then return arr(view) end end }) })
setmetatable(mycomp, { __index = function(_, k) if k == "PendingRequests" then return arr(pending) end end })
me.BP_JigMultiplayer = mycomp
items.client_tick()
local pend, add, drop = hooks[JIG .. "JigTryAddGetPendingRef"], hooks[JIG .. "JigTryAddItemSomewhere"], hooks[PFN .. "JigMP_OnRequestDropItem"]
assert(pend and add and drop, "client hooks missing")

-- tearing a shirt: a new pending Cloth slot, then the local add
local cloth = { __name = "DA_Cloth", __cls = "JigsawItem_DataAsset_C", __path = "/Game/Items/DA_Cloth.DA_Cloth" }
local slot = { __name = "slotA", ItemUniqueID = G(77), ContainerMother = cont, SlotIndex = 12, IsPending = true, JigDataAsset = cloth, ItemCount = 2 }
pending[#pending + 1] = slot
pend(C(mycomp), P({}), P(true), P(slot), P(false))
add(C(mycomp), P(mycomp), P(cloth), P(2), P(false), P(G(0)))
assert(removed_uids[1] == 77, "placeholder not removed")
assert(sent[1] and sent[1][1] == "IGAIN" and sent[1][2] == cloth.__path and sent[1][3] == 2, "IGAIN not sent")
assert(has_log("placeholder in BACKPACK slot 12, pending: pending request dropped"), "local add log wrong")
-- stacking: nothing to remove, still asked
pend(C(mycomp), P({}), P(true), P({ __name = "stackslot", ItemUniqueID = G(5) }), P(true))
add(C(mycomp), P(mycomp), P(cloth), P(1), P(false), P(G(0)))
assert(#sent == 2 and has_log("would stack"), "stack case wrong")
-- no room: the game drops a local pickup
local destroyed = false
local pickup = { __name = "BP_StaticMeshPickup_C_1", Role = 3, K2_DestroyActor = function() destroyed = true end }
pend(C(mycomp), P({}), P(true), P(nil), P(false))
drop(C(me), P({}), P("None"), P(pickup))
add(C(mycomp), P(mycomp), P(cloth), P(1), P(false), P(G(0)))
assert(destroyed and has_log("local pickup BP_StaticMeshPickup_C_1 removed"), "local drop not removed")
assert(#sent == 3, "no-room gain not sent")
-- a crafting answer path is untouched: armed calls are crafts, not local adds
print("client: placeholder, stack and drop cases ok")

-- stale pending slot (never answered)
local stale = { __name = "slotB", ItemUniqueID = G(88), ContainerMother = cont, SlotIndex = 3, IsPending = true,
  JigDataAsset = { __name = "DA_Can" } }
pending[#pending + 1] = stale
consume.client_tick()
offset = offset + 25
consume.client_tick()
assert(unpended_uids[#unpended_uids] == 88 and stale.ContainerMother == cont
  and has_log("Can (uid 88:0:0:0, BACKPACK slot 3, pending) waited 25 s for the host; a real item: it stops blinking where it is", "warn"),
  "stale real item not un-pended")
-- a slot reserved here (a local add's placeholder) that the host never filled: removed
local stale2 = { __name = "slotC", ItemUniqueID = G(89), ContainerMother = cont, SlotIndex = 5, IsPending = true,
  JigDataAsset = { __name = "DA_Can" } }
pending[#pending + 1] = stale2
pend(C(mycomp), P({}), P(true), P(stale2), P(false))
consume.client_tick()
offset = offset + 25
consume.client_tick()
assert(removed_uids[#removed_uids] == 89 and stale2.ContainerMother == nil and has_log("(uid 89:0:0:0", "warn"), "stale placeholder not removed")
print("client: stale pending: real item un-pended, placeholder removed")

-- inventory check line names the slot
local itemsmod = package.loaded["sdc_items"]
itemsmod.host_item_uids = function() return { ["1:0:0:0"] = 1 }, 1, 0 end
view[1] = { __name = "slotC", ItemUniqueID = G(66), ContainerMother = cont, SlotIndex = 7, IsPending = false,
  JigDataAsset = { __name = "DA_Cloth" }, ItemCount = 1 }
consume.reset()
consume.client_tick(); offset = offset + 6; consume.client_tick()
assert(has_log("Cloth x1 (uid 66:0:0:0, BACKPACK slot 7)", "warn"), "desync line lacks the slot: " .. tostring(has_log("not in the host")))
print("client: desync line names the slot")

-- items inside a worn backpack are part of the view; a craft paid with one the
-- host does not have is held back, one paid with a host item goes through
local inner = { __name = "BackpackInner_W", ContainerName = "BACKPACK INNER" }
local ghost = { __name = "slotG", ItemUniqueID = G(91), ContainerMother = inner, SlotIndex = 4, IsPending = false,
  JigDataAsset = { __name = "DA_Cloth" }, ItemCount = 1 }
local real = { __name = "slotR", ItemUniqueID = G(1), ContainerMother = inner, SlotIndex = 5, IsPending = false,
  JigDataAsset = { __name = "DA_Rag" }, ItemCount = 2 }
inner.ArrayOfItems = arr({ ghost, real })
view[1] = { __name = "slotBP", ItemUniqueID = G(1), ContainerMother = cont, SlotIndex = 0, IsPending = false,
  JigDataAsset = { __name = "DA_Backpack" }, ItemCount = 1, SpecialContainerRef = { __name = "BP_Special", AllContainers = arr({ inner }) } }
-- (the backpack itself shares uid 1 with nothing else here; use a host map with both 1 and the backpack)
itemsmod.host_item_uids = function() return { ["1:0:0:0"] = 1 }, 1, 0 end
local CHECK = "/Game/Inventory/Widgets/Crafting/W_PlayerCraftingUI.W_PlayerCraftingUI_C:CheckIngredientsAvailability"
assert(hooks[CHECK], "check hook missing")
local wui = { __name = "craftui", __cls = "W_PlayerCraftingUI_C", RequestConsume = arr({ G(91) }) }
local pr = P(true)
hooks[CHECK](C(wui), pr)
assert(pr.v == false and has_log("craft held back - its components are not in the host's copy of this inventory: Cloth x1 (uid 91:0:0:0, BACKPACK INNER slot 4)", "warn"),
  "ghost craft not held back")
wui.RequestConsume = arr({ G(1) })
local pr2 = P(true)
hooks[CHECK](C(wui), pr2)
assert(pr2.v == true, "paid craft held back")
-- a station item (not in this inventory) is not judged
wui.RequestConsume = arr({ G(555) })
local pr3 = P(true)
hooks[CHECK](C(wui), pr3)
assert(pr3.v == true, "station component held back")
print("client: backpack items seen, ghost crafts held back")

-- ---------------------------------------------------------------- host
S.role = "host"
logs = {}
consume.reset()
local calls = {}
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc }
pc.__pawn = guest
-- the shirt the rip uses (in the inventory here before and after: x3 -> x2)
local shirt = { ["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] = G(9),
  ["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"] = { ["Count_8_DD79AF2A46126A338C8DCCB4616D91CD"] = 3,
    ["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] = { __name = "DA_GreenShirt" } } }
-- (the grid the client's screen puts gains in: uid 1; 2026-11-13 the host adds
-- there, not with the plugin's AddNewItemSomewhere - see mock_consume_lootbox)
local inv = { shirt }
local djig = { __name = "GuestJig", GetOwner = function() return guest end,
  MainJigContainers = arr({ { ["ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"] = G(1),
    ["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] = arr(inv) } }) }
djig.AddNewItemSomewhere = function() error("the any-grid add is not used for gains") end
local next_new = 500
djig.Generate_AddNewItemToContainer = function(_, g, da, n, info, res)
  calls[#calls + 1] = { da = da, n = n, grid = g.A }
  next_new = next_new + 1
  inv[#inv + 1] = { ["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] = G(next_new),
    ["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"] = { ["Count_8_DD79AF2A46126A338C8DCCB4616D91CD"] = n,
      ["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] = da }, SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE = arr({}) }
  res["Added?"] = true
end
local adds = {}
djig.CLIENT_AddNewItem = function(_, it, content, comp, pend)
  adds[#adds + 1] = { a = it["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"].A, n = #content, comp = comp, pend = pend.A }
end
guest.BP_JigMultiplayer = djig
assets[cloth.__path] = cloth
items.host_tick({ pc })
assert(hooks[JIG .. "SERVER_RequestConsumeItem"], "use hook missing")
-- IGAIN before its use request: waits, then paid
handlers.IGAIN({ cloth.__path, "2", "c", "1:0:0:0", "4" }, pc)
assert(#calls == 0, "paid without a use request")
hooks[JIG .. "SERVER_RequestConsumeItem"](C(djig), P(djig), P(G(9)), P(1), P(""))
assert(#calls == 1 and calls[1].da == cloth and calls[1].n == 2 and calls[1].grid == 1, "not added after the use")
assert(#adds == 1 and adds[1].a == 501 and adds[1].n == 0 and adds[1].comp == djig and adds[1].pend == 0, "client not told")
assert(has_log("guest gets Cloth x2 from using an item, where its screen put it (its slot 4): new item 501:0:0:0 in grid 1:0:0:0"),
  "grant log wrong")
-- a use of an item the host does not have (a slot left on the client): nothing used, the client told, no gain
local told = {}
djig.CLIENT_UpdateCount = function(_, target, g, n) told[#told + 1] = { target = target, a = g.A, n = n } end
hooks[JIG .. "SERVER_RequestConsumeItem"](C(djig), P(djig), P(G(66)), P(1), P(""))
assert(#told == 1 and told[1].target == djig and told[1].a == 66 and told[1].n == 0, "ghost not removed on the client")
assert(has_log("used uid 66:0:0:0 x1, which is not in their inventory here", "warn"), "ghost use log")
-- IGAIN right after a use request: paid at once
handlers.IGAIN({ cloth.__path, "1", "c", "1:0:0:0", "5" }, pc)
assert(#calls == 2, "not paid right after a use")
-- an asset loaded on demand
local can = { __name = "DA_Can", __cls = "JigsawItem_DataAsset_C" }
assets["later:/Game/Items/DA_Can.DA_Can"] = can
handlers.IGAIN({ "/Game/Items/DA_Can.DA_Can", "1", "c", "1:0:0:0", "6" }, pc)
assert(#calls == 3 and calls[3].da == can, "asset not loaded")
-- no word where the client's screen put it: at its feet (single player's no-room drop)
local drops = {}
guest.JigMP_OnRequestDropItem = function(_, info, cname, out)
  drops[#drops + 1] = { da = info["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"], n = info["Count_8_DD79AF2A46126A338C8DCCB4616D91CD"] }
  out.ActorRef = { __name = "pickup", SetPickupCount = function(self, cnt) self.n = cnt end }
end
handlers.IGAIN({ cloth.__path, "1" }, pc)
assert(#calls == 3 and #drops == 1 and drops[1].da == cloth and drops[1].n == 1, "no word: not dropped at the feet")
-- no use around it: refused after the window
offset = offset + 10
handlers.IGAIN({ cloth.__path, "1", "c", "1:0:0:0", "7" }, pc)
offset = offset + 7
items.host_tick({ pc })
assert(#calls == 3 and #drops == 1 and has_log("with no item use around it; not added", "warn"), "unbacked IGAIN not refused")
print("host: gains added where the client's screen put them, unbacked refused")
for _, l in ipairs(logs) do if l:find("^err") and l:find("consume:", 1, true) then error("error logged: " .. l) end end
print("ALL OK")
