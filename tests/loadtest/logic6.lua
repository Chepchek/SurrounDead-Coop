-- sdc_stations (disassembly on the host) + loot-box default attachments + station placeholders
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
function ue.path(o) return o.__path end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
local world = {}
function ue.find_all(cls) return world[cls] or {} end
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
LoadAsset = function() end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"

local items = require("sdc_items")
local S = { role = "client", remote_pcs = {} }
items.init(S)
items.register_handlers()
assert(handlers.DISASM and handlers.IGAIN, "handlers missing")

local DIS_UI = "/Game/Inventory/Widgets/Crafting/W_DisassemblyWorkbenchUI.W_DisassemblyWorkbenchUI_C:"
  .. "BndEvt__W_DisassemblyWorkbenchUI_Button_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"

-- ---------------------------------------------------------------- client
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
me.BP_JigMultiplayer = { __name = "MyJig", GetOwner = function() return me end, LocalJSIContainers = arr({}) }
local station_c = { __name = "Buildable_DisassemblyWorkbench_C_9", __cls = "Buildable_DisassemblyWorkbench_C",
  __loc = { X = 1000, Y = 2000, Z = 50 } }
local removed = {}
local scomp_c = { __name = "StationJig_c", GetOwner = function() return station_c end,
  RemoveRequestByUID = function(_, uid, clear, out) removed[#removed + 1] = uid.A; out.Removed = true end }
items.client_tick()
assert(hooks[DIS_UI], "disassemble hook missing")
hooks[DIS_UI](C({ __name = "W_Dis", JSIContainer_1 = { JigMultiplayerComp = scomp_c } }))
assert(sent[1] and sent[1][1] == "DISASM" and sent[1][2] == "Buildable_DisassemblyWorkbench_C" and sent[1][3] == "1000",
  "DISASM not sent")
-- the station's own single-player add on this machine: its placeholder goes, no IGAIN
local slot = { __name = "pslot", ItemUniqueID = G(42), ContainerMother = { __name = "Disassembled_W" }, SlotIndex = 0 }
hooks[JIG .. "JigTryAddGetPendingRef"](C(scomp_c), P({}), P(true), P(slot), P(false))
hooks[JIG .. "JigTryAddItemSomewhere"](C(scomp_c), P(scomp_c), P({ __name = "DA_Scrap" }), P(2), P(false), P(G(0)))
assert(removed[1] == 42 and #sent == 1, "station placeholder not removed or IGAIN sent")
assert(has_log("to Buildable_DisassemblyWorkbench_C's inventory (placeholder pending request dropped)"), "station add log")
print("client: DISASM sent, station placeholder removed")

-- ---------------------------------------------------------------- host
S.role = "host"
logs = {}
items.reset()
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc, __loc = { X = 1100, Y = 2000, Z = 50 } }
pc.__pawn = guest
local scrap = { __name = "DA_Scrap" }
local pistol = { __name = "DA_Pistol", ["CanBeDisassembled?"] = true, DisassemblyItems = arr({
  { ItemID_41_8C5E69274AB445604263E4A2B3091BAD = scrap, SpawnChance_9_0A1811814580181DD09AE78500C25A28 = 100,
    RandomCountMin_17_2CF035DB43DEE23801AD29A29560BDA9 = 2, RandomCountMax_18_C37B88104F52B02AA216B5912518580D = 2 } }) }
local can = { __name = "DA_Can", ["CanBeDisassembled?"] = false }
local function item(uid, da, n) return { [F_USID] = G(uid), [F_INFO] = { [F_ITEMID] = da, [F_COUNT] = n } } end
local adds, consumed, full = {}, {}, false
local station = { __name = "Buildable_DisassemblyWorkbench_C_3", __cls = "Buildable_DisassemblyWorkbench_C",
  __loc = { X = 1010, Y = 2000, Z = 50 }, CurrentActor = guest }
local scomp = { __name = "StationJig", MainJigContainers = arr({ { [F_ITEMS] = arr({ item(1, pistol, 1), item(2, can, 1) }) } }) }
scomp.AddNewItemSomewhere = function(_, da, n, inside, inside_n, drop_ok, spec, a, d)
  adds[#adds + 1] = { da = da, n = n }
  a.Added = not full; d["Dropped?"] = false
end
scomp.SERVER_RequestConsumeItem = function(_, target, uid, n, cd) consumed[#consumed + 1] = { t = target, a = uid.A, n = n } end
station.BP_JigMultiplayer = scomp
local other = { __name = "Buildable_DisassemblyWorkbench_C_4", __cls = "Buildable_DisassemblyWorkbench_C",
  __loc = { X = 1000, Y = 2000, Z = 50 } }
world.Buildable_DisassemblyWorkbench_C = { other, station }
items.host_tick({ pc })
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "1000", "2000", "50" }, pc)
assert(#adds == 1 and adds[1].da == scrap and adds[1].n == 2, "output not added")
assert(#consumed == 1 and consumed[1].t == scomp and consumed[1].a == 1 and consumed[1].n == 1, "input not consumed")
assert(has_log("guest disassembled at Buildable_DisassemblyWorkbench_C_3: Pistol x1 -> Scrap x2; skipped Can (cannot be disassembled)"),
  "disassembly log: " .. tostring(logs[#logs]))
-- full station: the output drops at the player
full = true
local dropped
guest.JigMP_OnRequestDropItem = function(_, info, name, out)
  dropped = info; out.ActorRef = { __name = "Pickup", SetPickupCount = function(_, n) dropped.count = n end }
end
local t0 = os.clock(); while os.clock() - t0 < 0.55 do end
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "1000", "2000", "50" }, pc)
assert(dropped and dropped[F_ITEMID] == scrap and dropped.count == 2, "full station: not dropped at the player")
assert(has_log("Scrap x2 dropped at the player"), "drop log")
-- refused: too soon, wrong class, out of reach
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "1000", "2000", "50" }, pc)
assert(has_log("refused (too soon)", "warn"), "rate limit")
t0 = os.clock(); while os.clock() - t0 < 0.55 do end
handlers.DISASM({ "BP_Something_C", "0", "0", "0" }, pc)
assert(has_log("refused (not a station)", "warn"), "class check")
t0 = os.clock(); while os.clock() - t0 < 0.55 do end
guest.__loc = { X = 9000, Y = 9000, Z = 0 }
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "1000", "2000", "50" }, pc)
assert(has_log("no such station in reach", "warn"), "reach check")
guest.__loc = { X = 1100, Y = 2000, Z = 50 }
print("host: disassembly runs on the station, drops when full, refuses bad requests")

-- loot-box weapon: added where the client's screen put it (grid 5), default
-- attachments into its sub-containers, the client told once with its contents
-- (2026-11-13: CLIENT_AddNewItem with the content; see mock_consume_lootbox)
local rifle = { __name = "DA_Rifle", __cls = "JigsawItem_DataAsset_C", __path = "/Game/I/DA_Rifle.DA_Rifle",
  DefaultAttachments = arr({ { ID_21_A45B60654D588805C5D52BA4BC5CD4FD = { __name = "DA_Mag" },
    MinCount_31_E62F0FA548FC7DB0BDB860B4C0D695B6 = 1, AddToContainerIndex_11_3CB23949434BAB8C7EEBE09362324A4C = 1 } }) }
assets[rifle.__path] = rifle
local gens, told = {}, {}
local djig = { __name = "GuestJig", GetOwner = function() return guest end }
djig.AddNewItemSomewhere = function() error("the any-grid add is not used for gains") end
local REP = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local conts = { { [REP] = G(5), _t = {} } }
conts[1][F_ITEMS] = arr(conts[1]._t)
djig.MainJigContainers = arr(conts)
djig.Generate_AddNewItemToContainer = function(_, g, id, n, info, added)
  gens[#gens + 1] = { grid = g.A, id = id, n = n }
  local c
  for _, x in ipairs(conts) do if x[REP].A == g.A then c = x end end
  if not c then added["Added?"] = false return end
  local it = { [F_USID] = G(700 + #gens), [F_INFO] = { [F_ITEMID] = id, [F_COUNT] = n }, [MOTHER] = g, [SUBS] = arr({}) }
  if id == rifle then
    it[SUBS] = arr({ { UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7 = G(70) }, { UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7 = G(71) } })
    for _, s in ipairs({ 70, 71 }) do
      local t = {}
      conts[#conts + 1] = { [REP] = G(s), [F_ITEMS] = arr(t), _t = t }
    end
  end
  table.insert(c._t, it)
  added["Added?"] = true
end
djig.CLIENT_AddNewItem = function(_, it, content, comp, pend)
  told[#told + 1] = { uid = it[F_USID].A, n = #content, inner = content[1] and content[1][F_USID].A, comp = comp, pend = pend.A }
end
djig.CLIENT_NewItemAdded = function() error("not used any more") end
guest.BP_JigMultiplayer = djig
hooks[JIG .. "SERVER_RequestConsumeItem"](C(djig), P(djig), P(G(9)), P(1), P(""))
handlers.IGAIN({ rifle.__path, "1", "c", "5:0:0:0", "2" }, pc)
assert(#gens == 2 and gens[1].grid == 5 and gens[1].id == rifle, "rifle not added to the client's grid")
assert(gens[2].grid == 71 and gens[2].id.__name == "DA_Mag" and gens[2].n == 1, "attachment not added to sub-container 1")
assert(#told == 1 and told[1].uid == 701 and told[1].n == 1 and told[1].inner == 702 and told[1].comp == djig and told[1].pend == 0,
  "client not told (once, with the magazine inside)")
assert(has_log("attachments: Mag x1") and has_log("the client was told (CLIENT_AddNewItem, 1 inside)"), "attachment log")
print("host: loot-box weapon gets its default attachments")
for _, l in ipairs(logs) do if l:find("^err") and (l:find("consume:", 1, true) or l:find("stations:", 1, true)) then error("error logged: " .. l) end end
print("ALL OK")
