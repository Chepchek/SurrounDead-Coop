-- purify (remove = use for IGAIN), repairs (SETDUR), loot container diagnostics
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
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local PFN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"

local items = require("sdc_items")
local S = { role = "client", remote_pcs = {} }
items.init(S)
items.register_handlers()
assert(handlers.SETDUR, "SETDUR handler missing")

-- ---------------------------------------------------------------- client
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local mycomp = { __name = "MyJig", GetOwner = function() return me end, LocalJSIContainers = arr({}) }
me.BP_JigMultiplayer = mycomp
-- (0.7.3: the RequestServerData hook, which only feeds the "no contents" warning, is on with config debug)
log.debug_enabled = true
items.client_tick()
-- a repair sets a durability in the empty data here: sent, and Updated answered
local up = P(false)
hooks[JIG .. "ServerFunc_UpdateDurabilityByUID"](C(mycomp), P(G(7)), P({ X = 80, Y = 100 }), up)
assert(to_host[#to_host][1] == "SETDUR" and to_host[#to_host][2] == "7:0:0:0" and to_host[#to_host][3] == "80.000", "SETDUR not sent")
assert(up.v == true, "Updated not answered")
-- loot: a request without an answer is reported; one with an answer is logged
local crate = { __name = "Container_HighTierMilitaryLoot_Crates_C_5", __cls = "Container_HighTierMilitaryLoot_Crates_C", Role = 1 }
local ccomp = { __name = "CrateJig", GetOwner = function() return crate end }
hooks[PFN .. "RequestServerData"](C(me), P(ccomp), P(false))
hooks[JIG .. "CLIENT_ContainerDataResponse"](C(mycomp), P(arr({})), P(arr({ 1, 2, 3 })), P(ccomp), P(arr({})))
assert(has_log("contents of Container_HighTierMilitaryLoot_Crates_C_5 (Container_HighTierMilitaryLoot_Crates_C) from the host: 3 item(s)"), "answer log")
local inf = { __name = "BP_Infestation_C_2", __cls = "BP_Infestation_C", Role = 3 }
hooks[PFN .. "RequestServerData"](C(me), P({ __name = "InfJig", GetOwner = function() return inf end }), P(false))
offset = offset + 5
items.client_tick()
assert(has_log("no contents from the host for BP_Infestation_C_2 (BP_Infestation_C; this copy: local authority, placed in the level / replicated)", "warn"), "missing answer not reported")
print("client: SETDUR sent, loot requests logged")

-- ---------------------------------------------------------------- host
S.role = "host"
logs = {}
items.reset()
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc }
pc.__pawn = guest
local inv = {
  { uid = 1, n = 1, id = "DA_DirtyWaterBottle", x = 100, y = 100 },
  { uid = 2, n = 3, id = "DA_WaterPurificationTablets", x = 100, y = 100 },
  { uid = 7, n = 1, id = "DA_Pistol", x = 40, y = 100 },
  { uid = 8, n = 1, id = "DA_WeaponCleaningKit", x = 50, y = 50 } }
local granted, setdur = {}, {}
-- (2026-11-13: a gain goes where the client's screen put it - grid 1 here -
-- with the plugin's add into that grid, not AddNewItemSomewhere)
local djig = setmetatable({ __name = "GuestJig", GetOwner = function() return guest end,
  AddNewItemSomewhere = function() error("the any-grid add is not used for gains") end,
  Generate_AddNewItemToContainer = function(_, g, da, n, info, res)
    granted[#granted + 1] = da
    inv[#inv + 1] = { uid = 300 + #granted, n = n, id = da.__name, x = 100, y = 100 }
    res["Added?"] = true
  end,
  CLIENT_AddNewItem = function() end,
  ServerFunc_UpdateDurabilityByUID = function(_, g, nd, out) setdur[#setdur + 1] = { a = g.A, x = nd.X, y = nd.Y }
    for _, e in ipairs(inv) do if e.uid == g.A then e.x = nd.X end end; out.Updated = true end },
  { __index = function(_, k)
    if k == "MainJigContainers" then
      local list = {}
      for _, e in ipairs(inv) do list[#list + 1] = { [F_USID] = G(e.uid),
        [F_INFO] = { [F_COUNT] = e.n, [F_ITEMID] = { __name = e.id }, [F_DUR] = { X = e.x, Y = e.y } } } end
      return arr({ { ["ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"] = G(1), [F_ITEMS] = arr(list) } })
    end end })
guest.BP_JigMultiplayer = djig
local clean = { __name = "DA_WaterBottle", __cls = "JigsawItem_DataAsset_C", __path = "/Game/I/DA_WaterBottle.DA_WaterBottle" }
assets[clean.__path] = clean
items.host_tick({ pc })
assert(hooks[JIG .. "SERVER_RequestRemoveItem"], "remove hook missing")
-- purify: the client's IGAIN for the clean bottle, then the two removes
handlers.IGAIN({ clean.__path, "1", "c", "1:0:0:0", "3" }, pc)
assert(#granted == 0, "granted before the use")
table.remove(inv, 1)
hooks[JIG .. "SERVER_RequestRemoveItem"](C(djig), P(djig), P(G(1)), P(1), P(false))
assert(#granted == 1 and granted[1] == clean, "clean water not given after the remove")
assert(has_log("guest used up DirtyWaterBottle x1"), "remove log")
print("host: purify gives the clean bottle")

-- repair: raise first (waits), then the kit wears (applied, raise flushed)
offset = offset + 10
handlers.SETDUR({ "7:0:0:0", "90" }, pc)
assert(#setdur == 0, "raise applied without a kit")
handlers.SETDUR({ "8:0:0:0", "30" }, pc)
assert(#setdur == 2 and setdur[1].a == 8 and setdur[1].x == 30 and setdur[2].a == 7 and setdur[2].x == 90, "repair not applied")
-- a raise with nothing around: refused after the window
offset = offset + 10
handlers.SETDUR({ "7:0:0:0", "100" }, pc)
offset = offset + 3
items.host_tick({ pc })
assert(#setdur == 2 and has_log("raised the durability of 7:0:0:0 with no repair kit used around it; not applied", "warn"), "unpaid raise not refused")
-- unknown item
handlers.SETDUR({ "99:0:0:0", "10" }, pc)
assert(has_log("set the durability of item 99:0:0:0, which is not in their inventory here", "warn"), "unknown item")
-- loot request diagnostics on the host
local crate = { __name = "Crate_5", __cls = "Container_HighTierMilitaryLoot_Crates_C",
  JigCanInteract = function(_, out) out.Result = true end }
local ccomp = { __name = "CrateJig", GetOwner = function() return crate end,
  MainJigContainers = arr({ { [F_ITEMS] = arr({ 1, 2 }) } }) }
hooks[JIG .. "SERVER_RequestData"](C(djig), P(ccomp))
assert(has_log("guest opened Crate_5 (Container_HighTierMilitaryLoot_Crates_C): 2 item(s) here, can interact=true"), "host loot log")
hooks[JIG .. "SERVER_RequestData"](C(djig), P(nil))
assert(has_log("opened a container the host does not have", "warn"), "unresolved container")
print("host: repairs applied with their kit, loot requests logged")
for _, l in ipairs(logs) do if l:find("^err") and (l:find("consume:", 1, true) or l:find("stations:", 1, true)) then error("error logged: " .. l) end end
print("ALL OK")
