-- station recipe tables (STABLE), client-only stations, wrong-recipe crafts, item resend, drop report
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
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return o.__path or ("/Game/L.L:PersistentLevel." .. (o.__name or "?")) end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
local world = {}
function ue.find_all(cls) return world[cls] or {} end
local objects = {}
function ue.find_object(p) return objects[p] end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
function ue.delay() end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned(o) return o.__runtime == true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
local to_host, handlers = {}, {}
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind, ... } end, on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end,
  GetArrayNum = function() return #t end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"

local items = require("sdc_items")
local S = { role = "client", remote_pcs = {} }
items.init(S)
items.register_handlers()
assert(handlers.STABLE and handlers.RESEND, "handlers missing")
local stations = items.stations

-- ---------------------------------------------------------------- client
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local view = {}
local mycomp = { __name = "MyJig", GetOwner = function() return me end,
  LocalJSIContainers = arr({ setmetatable({ __name = "Pockets_W", ContainerName = "POCKETS" },
    { __index = function(_, k) if k == "ArrayOfItems" then return arr(view) end end }) }) }
me.BP_JigMultiplayer = mycomp
items.client_tick()
-- a world cooking station (level-placed: same path on the host)
local stove = { __name = "BP_CookingStation_C_3", __cls = "BP_CookingStation_C", Role = 3, __loc = { X = 100, Y = 0, Z = 0 } }
local scomp = { __name = "StoveJig", GetOwner = function() return stove end }
local cook = { __name = "cookui", __cls = "W_CookingUI_C", MPComponent = scomp }
assert(stations.client_craft_check(cook) == true, "level station refused")
assert(to_host[#to_host][1] == "STABLE" and to_host[#to_host][2] == 2 and to_host[#to_host][4] == "BP_CookingStation_C", "STABLE not sent")
-- the window-opened hook sends it at once
local n0 = #to_host
hooks["/Game/Inventory/Widgets/Crafting/W_CookingUI.W_CookingUI_C:InitializeInventory"](C(cook))
assert(#to_host == n0 + 1 and to_host[#to_host][1] == "STABLE", "window open did not send STABLE")
-- a station spawned only here (prefab camp): refused, nothing sent
local ghost = { __name = "BP_CookingStation_C_2147400000", __cls = "BP_CookingStation_C", Role = 3, __runtime = true,
  __loc = { X = 0, Y = 0, Z = 0 } }
local gcomp = { __name = "GhostJig", GetOwner = function() return ghost end }
local n1 = #to_host
assert(stations.client_craft_check({ __name = "c2", __cls = "W_CookingUI_C", MPComponent = gcomp }) == false, "client-only station allowed")
assert(#to_host == n1 and has_log("exists only on this machine (the host does not have it): crafting there is refused", "warn"), "refusal")
-- the craft check (sdc_consume) holds such a craft back
local CHECK = "/Game/Inventory/Widgets/Crafting/W_CookingUI.W_CookingUI_C:CheckIngredientsAvailability"
local pr = P(true)
hooks[CHECK](C({ __name = "c3", __cls = "W_CookingUI_C", MPComponent = gcomp }), pr)
assert(pr.v == false, "craft at a client-only station not held back")
print("client: recipe table sent, client-only station refused")

-- a craft answer for another item than the slot shows: slot removed, RESEND
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local removed = false
local wrong = { __name = "slotM", ItemUniqueID = G(77), JigDataAsset = { __name = "DA_CookedMeat" }, ItemCount = 1, SlotIndex = 2,
  ContainerMother = { __name = "Pockets_W", ContainerName = "POCKETS" }, RemoveFromJSIParent = function() removed = true end }
view[1] = wrong
-- a request in flight
hooks[CHECK](C(cook), P(true))
hooks[JIG .. "JigTryAddGetPendingRef"](C(mycomp), P({}), P(true), P({ __name = "pend" }), P(false))
hooks[JIG .. "CLIENT_ItemCraftedResponse"](C(mycomp), P(G(5)),
  P({ [F_USID] = G(77), [F_INFO] = { [F_ITEMID] = { __name = "DA_Bandage" }, [F_COUNT] = 1 } }), P(true), P(arr({})), P(arr({})))
assert(removed and to_host[#to_host][1] == "RESEND" and to_host[#to_host][2] == "77:0:0:0", "mismatch not fixed")
assert(has_log("the host made Bandage (uid 77:0:0:0), this inventory showed CookedMeat there", "warn"), "mismatch log")
print("client: a slot showing the wrong item is replaced")

-- ---------------------------------------------------------------- host
S.role = "host"
logs = {}
items.reset()
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc, __loc = { X = 150, Y = 0, Z = 0 } }
pc.__pawn = guest
-- recipe table: SetItemsToCraft on the host's copy of the station
local hstove = { __name = "BP_CookingStation_C_3", __cls = "BP_CookingStation_C", __loc = { X = 100, Y = 0, Z = 0 } }
local recipes = {}
hstove.BP_JigMultiplayer = { __name = "HStoveJig", ItemsToCraft = arr(recipes) }
objects["/Game/L.L:PersistentLevel.BP_CookingStation_C_3"] = hstove
local set_calls = {}
objects["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"] = { __name = "GFL",
  SetItemsToCraft = function(_, t, comp, st) set_calls[#set_calls + 1] = { t = t, comp = comp, st = st }
    for i = 1, 23 do recipes[i] = i end end }
handlers.STABLE({ "2", "/Game/L.L:PersistentLevel.BP_CookingStation_C_3", "BP_CookingStation_C", "100", "0", "0" }, pc)
assert(#set_calls == 1 and set_calls[1].t == 2 and set_calls[1].st == hstove, "SetItemsToCraft not called")
assert(has_log("recipe table 2 of BP_CookingStation_C_3 set on the host for guest: 23 recipes (were 0)"), "table log")
-- a station the host does not have
handlers.STABLE({ "2", "/Game/L.L:PersistentLevel.Nope", "BP_CookingStation_C", "5000", "0", "0" }, pc)
assert(has_log("that is not on the host: its crafts there will fail", "warn"), "missing station not reported")
print("host: recipe table set on the host's station, missing station reported")

-- a craft whose station did not resolve: wrong recipe, nothing consumed -> taken back
local inv = { { uid = 1, n = 2, id = "DA_Meat" } }
local taken = {}
local djig = setmetatable({ __name = "GuestJig", GetOwner = function() return guest end,
  SERVER_RequestRemoveItem = function(_, t, g, n) taken[#taken + 1] = { a = g.A, n = n }
    for i, e in ipairs(inv) do if e.uid == g.A then e.n = e.n - n; if e.n <= 0 then table.remove(inv, i) end break end end end,
  CLIENT_AddNewItem = nil }, { __index = function(_, k)
    if k == "MainJigContainers" then
      local list = {}
      for _, e in ipairs(inv) do list[#list + 1] = { [F_USID] = G(e.uid), [F_INFO] = { [F_COUNT] = e.n, [F_ITEMID] = { __name = e.id } } } end
      return arr({ { [F_ITEMS] = arr(list) } })
    end end })
guest.BP_JigMultiplayer = djig
items.host_tick({ pc })
inv[#inv + 1] = { uid = 9, n = 1, id = "DA_Bandage" }
hooks[JIG .. "SERVER_RequestCraftItem"](C(djig), P(nil), P(4), P(arr({ G(1) })))
assert(#taken == 1 and taken[1].a == 9 and has_log("wrong recipe, nothing consumed: taken back [Bandage x1]", "warn"), "wrong recipe not taken back")
-- RESEND: the host sends the item as it has it
local sent_item
rawset(djig, "CLIENT_AddNewItem", function(_, item, content, comp, pend) sent_item = item end)
handlers.RESEND({ "1:0:0:0" }, pc)
assert(sent_item and sent_item[F_USID].A == 1 and has_log("Meat (uid 1:0:0:0) sent to guest again"), "resend failed")
handlers.RESEND({ "55:0:0:0" }, pc)
assert(has_log("asked for item 55:0:0:0 again, which is not in their inventory here", "warn"), "unknown resend")
-- drop report
local before_n = inv[1].n
inv[1].n = before_n - 1
consume_report = items.consume.host_drop_report
consume_report(C(djig), P(G(1)), P(1), P(djig))
assert(has_log("guest dropped Meat x1 (uid 1:0:0:0: 2 here before, 1 after)"), "drop report: " .. tostring(logs[#logs]))
consume_report(C(djig), P(G(66)), P(1), P(djig))
assert(has_log("asked to drop uid 66:0:0:0 x1, which is not in their inventory here", "warn"), "unknown drop")
print("host: wrong-recipe craft taken back, resend, drop report")
for _, l in ipairs(logs) do if l:find("^err") and (l:find("consume:", 1, true) or l:find("stations:", 1, true)) then error("error logged: " .. l) end end
print("ALL OK")
