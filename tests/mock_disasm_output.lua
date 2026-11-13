-- Mock harness: where a client's disassembly puts its results (sdc_stations,
-- with sdc_containers forwarding them to the client's open window).
-- 0.7.1: the host ran the client's disassembly with AddNewItemSomewhere, which
-- stacks onto that item in any grid and puts a new stack in the first grid
-- with room: the station's input grid "Container" (the window's top grid);
-- the client's window shows the host's data, so the results were in the top
-- grid. Single player (W_DisassemblyWorkbenchUI: NonAdd = the input grid,
-- JigTryAddItemSomewhere) puts them into "Disassembled" (the bottom grid), or
-- drops them at the player's feet when it is full.
-- usage: lua mock_disasm_output.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local T = 500
os.clock = function() return T end

-- ------------------------------------------------------------ log capture
local logs = {}
package.loaded["sdc_log"] = setmetatable({ debug_enabled = true, TEXT = {} }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local function has_log(level, pat)
  for _, l in ipairs(logs) do
    if (level == nil or l:sub(1, #level + 2) == level .. ": ") and l:find(pat, 1, true) then return l end
  end
  return nil
end

-- ------------------------------------------------------------ fakes
local G = {}
FName = function(s) return { _s = s } end
local hooks = {}
function RegisterHook(path, fn) hooks[path] = fn; return 1, 2 end
function NotifyOnNewObject() end

local function arr(list)
  return {
    items = list,
    ForEach = function(self, fn)
      for i, v in ipairs(self.items) do fn(i, { get = function() return v end }) end
    end,
    GetArrayNum = function(self) return #self.items end,
  }
end
local function guid(a) return { A = a, B = 0, C = 0, D = 0 } end
local function gs(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_SLOTS = "ContainerSlots_13_97B5C4324E23EC5C1D899EA59CCDD3AC"
local F_HOSTING = "HostingUID_12_7B8F2C70428BC8D03C43329582545C16"
local CS_NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982"
local R_ID = "ItemID_41_8C5E69274AB445604263E4A2B3091BAD"
local R_CHANCE = "SpawnChance_9_0A1811814580181DD09AE78500C25A28"
local R_MIN = "RandomCountMin_17_2CF035DB43DEE23801AD29A29560BDA9"
local R_MAX = "RandomCountMax_18_C37B88104F52B02AA216B5912518580D"

local next_addr = 1000
local function obj(cls, name, t)
  t = t or {}
  next_addr = next_addr + 8
  t.__cls, t.__name, t.__addr = cls, name, next_addr
  return t
end

-- data assets
local function da(name, parts, can, max)
  local d = obj("JigsawItem_DataAsset_C", "DA_" .. name, { name = name, MaxStack = max or 50, ["CanStack?"] = (max or 50) > 1 })
  d["CanBeDisassembled?"] = can
  local list = {}
  for _, p in ipairs(parts or {}) do
    list[#list + 1] = { [R_ID] = p[1], [R_CHANCE] = 100, [R_MIN] = p[2], [R_MAX] = p[2] }
  end
  d.DisassemblyItems = arr(list)
  return d
end
local SCRAP = da("ScrapMetal", nil, false, 50)
local CLOTH = da("Cloth", nil, false, 50)
local KNIFE = da("Knife", { { SCRAP, 1 } }, true, 1)
local JEANS = da("BlackHeavyJeans", { { CLOTH, 1 } }, true, 1)
local SHIRT = da("GreenShirt", { { CLOTH, 1 } }, true, 1)
local BOOTS = da("Boots2", nil, false, 1)

local uid_n = 100
local function item(d, n, cont, slot)
  uid_n = uid_n + 1
  return { [F_USID] = guid(uid_n), [F_MOTHER] = cont[F_CONT_UID], [F_SLOT] = slot or 0,
           [F_INFO] = { [F_ITEMID] = d, [F_COUNT] = n } }
end
local function grid(uid, cols, rows)
  local slots = {}
  for i = 1, cols * rows do slots[i] = { [F_HOSTING] = guid(0) } end
  return { [F_CONT_UID] = guid(uid), [F_ITEMS] = arr({}), [F_SLOTS] = arr(slots), cols = cols, rows = rows }
end
local function take_slot(rc, u)
  for _, s in ipairs(rc[F_SLOTS].items) do
    if gs(s[F_HOSTING]) == "0:0:0:0" then s[F_HOSTING] = u; return true end
  end
  return false
end
local function put(rc, it)
  rc[F_ITEMS].items[#rc[F_ITEMS].items + 1] = it
  take_slot(rc, it[F_USID])
  return it
end

-- the station's component: the game's AddItemToContainerByName (stack only in
-- that grid when the count fits, else a new stack there; nothing when full),
-- AddNewItemSomewhere (stack anywhere, new stack in the first grid with room)
local calls = {}
local function new_station(at)
  local IN, OUT = grid(11, 12, 8), grid(12, 12, 6)
  local comp = obj("BP_JigComponent_C", "BP_JigMultiplayer")
  local st = obj("Buildable_DisassemblyWorkbench_C", "Buildable_DisassemblyWorkbench_C_1",
    { BP_JigMultiplayer = comp, __loc = at })
  comp.__owner = st
  comp.MainContainersIDs = arr({ IN[F_CONT_UID], OUT[F_CONT_UID] })
  comp.ContainersSettings = arr({ { [CS_NAME] = FName("Container") }, { [CS_NAME] = FName("Disassembled") } })
  comp.MainJigContainers = arr({ IN, OUT })
  comp.GetOwner = function(self) return self.__owner end
  comp.AddItemToContainerByName = function(self, name, d, n)
    calls[#calls + 1] = { "AddItemToContainerByName", name._s, d.name, n }
    if self.broken_by_name then error("no such function") end
    for i, s in ipairs(self.ContainersSettings.items) do
      if s[CS_NAME]._s == name._s then
        local rc = self.MainJigContainers.items[i]
        for _, it in ipairs(rc[F_ITEMS].items) do
          if it[F_INFO][F_ITEMID] == d and it[F_INFO][F_COUNT] + n <= d.MaxStack then
            it[F_INFO][F_COUNT] = it[F_INFO][F_COUNT] + n
            return
          end
        end
        uid_n = uid_n + 1
        local it = { [F_USID] = guid(uid_n), [F_MOTHER] = rc[F_CONT_UID], [F_SLOT] = 0,
                     [F_INFO] = { [F_ITEMID] = d, [F_COUNT] = n } }
        if take_slot(rc, it[F_USID]) then rc[F_ITEMS].items[#rc[F_ITEMS].items + 1] = it end
        return
      end
    end
  end
  comp.AddNewItemSomewhere = function(self, d, n, _, _, _, _, added)
    calls[#calls + 1] = { "AddNewItemSomewhere", d.name, n }
    for _, rc in ipairs(self.MainJigContainers.items) do
      for _, it in ipairs(rc[F_ITEMS].items) do
        if it[F_INFO][F_ITEMID] == d and it[F_INFO][F_COUNT] + n <= d.MaxStack then
          it[F_INFO][F_COUNT] = it[F_INFO][F_COUNT] + n
          added.Added = true
          return
        end
      end
    end
    for _, rc in ipairs(self.MainJigContainers.items) do
      uid_n = uid_n + 1
      local it = { [F_USID] = guid(uid_n), [F_MOTHER] = rc[F_CONT_UID], [F_SLOT] = 0,
                   [F_INFO] = { [F_ITEMID] = d, [F_COUNT] = n } }
      if take_slot(rc, it[F_USID]) then
        rc[F_ITEMS].items[#rc[F_ITEMS].items + 1] = it
        added.Added = true
        return
      end
    end
  end
  comp.SERVER_RequestConsumeItem = function(self, _, g, n)
    calls[#calls + 1] = { "consume", gs(g), n }
    for _, rc in ipairs(self.MainJigContainers.items) do
      for i, it in ipairs(rc[F_ITEMS].items) do
        if gs(it[F_USID]) == gs(g) then table.remove(rc[F_ITEMS].items, i); return end
      end
    end
  end
  return st, comp, IN, OUT
end

-- the remote player
local conn = obj("NetConnection", "IpConnection_1")
local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_7", { NetConnection = conn })
local pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Controller = pc, __loc = { X = 100, Y = 0, Z = 0 } })
pc.Pawn = pawn
local dropped = {}
pawn.JigMP_OnRequestDropItem = function(_, info, _, out)
  dropped[#dropped + 1] = { info[F_ITEMID].name, info[F_COUNT] }
  out.ActorRef = obj("BP_StaticMeshPickup_C", "Pickup", { SetPickupCount = function() end })
end

-- ------------------------------------------------------------ module stubs
local world = {}
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v)
  if type(v) == "table" and v._s then return v._s end
  if v == nil then return "" end
  return tostring(v)
end
function ue.fstring(v) return ue.str(v) end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return "/Game/" .. ue.short(o) end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.location(a) return a and a.__loc end
function ue.find_all(cls)
  local out = {}
  for _, o in ipairs(world) do if o.__cls == cls then out[#out + 1] = o end end
  return out
end
function ue.find_all_recent(cls) return ue.find_all(cls) end
function ue.watch_new() return true end
function ue.find_object() return nil end
function ue.pawn_of(p) return p and p.Pawn end
function ue.role() return 3 end
function ue.is_runtime_spawned() return false end
local delayed = {}
function ue.delay(label, ms, fn) delayed[#delayed + 1] = { due = T + ms / 1000, fn = fn, label = label }; return true end
local function run_delays()
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do
    if d.due <= T + 1e-9 then d.fn() else delayed[#delayed + 1] = d end
  end
end
package.loaded["sdc_ue"] = ue

local CFG = {}
package.loaded["sdc_config"] = { get = function(k) return CFG[k] end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__addr or nil end }
local handlers, sent, to_host = {}, {}, {}
package.loaded["sdc_net"] = {
  on = function(kind, fn) handlers[kind] = fn end,
  send_to = function(p, kind, ...) sent[#sent + 1] = { pc = p, kind = kind, args = { ... } }; return true end,
  broadcast = function(list, kind, ...) for _, p in ipairs(list) do sent[#sent + 1] = { pc = p, kind = kind, args = { ... } } end end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, args = { ... } }; return true end,
}
local notes_shown = {}
package.loaded["sdc_notes"] = { show_to = function(_, text) notes_shown[#notes_shown + 1] = text end }

math.random = function(a, b)
  if a == nil then return 0 end
  return a
end

local S = { role = "host", remote_pcs = { pc } }
local containers = require("sdc_containers")
local stations = require("sdc_stations")
containers.init(S)
stations.init(S)
containers.register_handlers()
stations.register_handlers()
check(handlers.DISASM ~= nil and handlers.DISASMR ~= nil and handlers.JMC ~= nil and handlers.DBOXGONE ~= nil,
  "handlers DISASM, DISASMR, JMC, DBOXGONE registered")

local function items_of(rc)
  local out = {}
  for _, it in ipairs(rc[F_ITEMS].items) do out[#out + 1] = it[F_INFO][F_ITEMID].name .. "x" .. it[F_INFO][F_COUNT] end
  table.sort(out)
  return table.concat(out, ",")
end
-- (0.7.3: JMC|*|<key>|<op,args>|...: one entry per op, as the single form JMC|<op>|<key>|<args> was;
-- number-like args as numbers, as the host passed them before)
local function sends(kind, op)
  local out = {}
  for _, s in ipairs(sent) do
    if s.kind == "JMC" and s.args[1] == "*" then
      for i = 3, #s.args do
        local one = {}
        for part in (s.args[i] .. ","):gmatch("([^,]*),") do one[#one + 1] = tonumber(part) or part end
        table.insert(one, 2, s.args[2])
        if kind == "JMC" and (op == nil or one[1] == op) then out[#out + 1] = { pc = s.pc, kind = "JMC", args = one } end
      end
    elseif s.kind == kind and (op == nil or s.args[1] == op) then out[#out + 1] = s end
  end
  return out
end

-- ============================================================ 1. the client's disassembly
print("-- 1: a client disassembles (host's work for them)")
local st, comp, IN, OUT = new_station({ X = 0, Y = 0, Z = 0 })
st.CurrentActor = pawn
world[#world + 1] = st
put(IN, item(KNIFE, 1, IN, 50))
put(IN, item(JEANS, 1, IN, 43))
put(IN, item(SHIRT, 1, IN, 51))
put(IN, item(BOOTS, 1, IN, 27))
-- the client has the station open (SERVER_RequestData noted by sdc_stations)
containers.note_view(pawn, comp)
check(containers.has_viewers(comp), "the client's open window is noted (has_viewers)")
local g = stations.output_grid(comp)
check(g and g.idx == 2 and g.n == 2 and g.name == "Disassembled" and g.uid == gs(OUT[F_CONT_UID]),
  "output grid = the 2nd main container 'Disassembled'")

handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
check(items_of(OUT) == "Clothx2,ScrapMetalx1", "results in the output grid: ScrapMetal x1, Cloth stacked x2 (" .. items_of(OUT) .. ")")
check(items_of(IN) == "Boots2x1", "input grid: only the item that cannot be disassembled is left (" .. items_of(IN) .. ")")
local any_somewhere = false
for _, c in ipairs(calls) do if c[1] == "AddNewItemSomewhere" then any_somewhere = true end end
check(not any_somewhere, "AddNewItemSomewhere (any grid) not used")
local adds, cnts = sends("JMC", "add"), sends("JMC", "cnt")
check(#adds == 2, "the client's window gets 2 'add' (ScrapMetal, the first Cloth): " .. #adds)
local cloth_cnt = false
for _, s in ipairs(cnts) do if s.args[4] == 2 then cloth_cnt = true end end
check(cloth_cnt, "and the stacked Cloth as 'cnt ... 2'")
check(adds[1] and adds[1].args[2] == gs(IN[F_CONT_UID]), "JMC carries the station's key (its first main container)")
local r = sends("DISASMR")[1]
check(r and r.pc == pc and r.args[1] == 2 and r.args[2] == 2 and r.args[3] == "Disassembled" and r.args[4] == 3
  and r.args[5] == 0 and r.args[6] == 0, "DISASMR to that player: grid 2 of 2 'Disassembled', 3 there, 0 dropped, 0 elsewhere")
check(has_log("info", "disassembly results -> output grid 2 of 2 'Disassembled' (3 there, 0 dropped at the player, 0 elsewhere)") ~= nil,
  "host log: disassembly results -> output grid 2")
check(#notes_shown == 1 and notes_shown[1]:find("Boots2", 1, true), "the game's 'cannot be disassembled' notice for Boots2")
local consumed = 0
for _, c in ipairs(calls) do if c[1] == "consume" then consumed = consumed + 1 end end
check(consumed == 3, "three inputs consumed through the station's SERVER_RequestConsumeItem")

-- ============================================================ 2. output grid full
print("-- 2: the output grid is full")
T = T + 5
calls, sent, dropped = {}, {}, {}
for i = 1, #OUT[F_SLOTS].items do OUT[F_SLOTS].items[i][F_HOSTING] = guid(9000 + i) end
OUT[F_ITEMS].items = {}
put(IN, item(KNIFE, 1, IN, 10))
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
check(#dropped == 1 and dropped[1][1] == "ScrapMetal", "ScrapMetal dropped at the player's feet (single player's no-room branch)")
check(not items_of(IN):find("ScrapMetal", 1, true), "nothing went into the input grid (" .. items_of(IN) .. ")")
r = sends("DISASMR")[1]
check(r and r.args[4] == 0 and r.args[5] == 1, "DISASMR: 0 there, 1 dropped")

-- ============================================================ 3. the named add failing with room left
print("-- 3: AddItemToContainerByName fails with room left: the old add, logged")
T = T + 5
calls, sent, dropped = {}, {}, {}
for i = 1, #OUT[F_SLOTS].items do OUT[F_SLOTS].items[i][F_HOSTING] = guid(0) end
comp.broken_by_name = true
IN[F_ITEMS].items = {}
for i = 1, #IN[F_SLOTS].items do IN[F_SLOTS].items[i][F_HOSTING] = guid(0) end
put(IN, item(KNIFE, 1, IN, 10))
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
check(has_log("warn", "did not go into grid 2 'Disassembled'") ~= nil, "warning logged")
check(items_of(IN) == "ScrapMetalx1", "the result is kept (old add: first grid with room)")
r = sends("DISASMR")[1]
check(r and r.args[6] == 1, "DISASMR: 1 elsewhere")
comp.broken_by_name = nil

-- ============================================================ 4. the host's own disassembly is not touched
print("-- 4: the host's own click is the game's code")
T = T + 5
calls, sent = {}, {}
S.role = "host"
-- the window's button hook (registered by the client tick) does nothing on the host
local w = obj("W_DisassemblyWorkbenchUI_C", "W", { JSIContainer_1 = { JigMultiplayerComp = comp } })
stations.client_tick()
local UI_FN = "/Game/Inventory/Widgets/Crafting/W_DisassemblyWorkbenchUI.W_DisassemblyWorkbenchUI_C:"
  .. "BndEvt__W_DisassemblyWorkbenchUI_Button_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"
check(hooks[UI_FN] ~= nil, "the button hook is registered")
hooks[UI_FN]({ get = function() return w end })
check(#to_host == 0 and #calls == 0 and #sent == 0, "host's own click: no request, no add, no message from the mod")
S.role = "client"
hooks[UI_FN]({ get = function() return w end })
check(#to_host == 1 and to_host[1].kind == "DISASM", "a client's click still asks the host (DISASM)")
to_host = {}
S.role = "host"

-- ============================================================ 5. client: logs where the results are shown
print("-- 5: client side")
S.role = "client"
logs = {}
handlers.DISASMR({ "2", "2", "Disassembled", "3", "0", "0" })
check(has_log("info", "disassembly results -> output grid 2 of 2 'Disassembled' (the window's bottom grid) (3 there") ~= nil,
  "client log: results -> output grid 2 of 2 (bottom)")
-- the client's copy of the station: its window's two grids
local G1, G2 = guid(11), guid(12)
local cslot = { ContainerMother = { ContainerID = G2 }, SlotIndex = 3, IsPending = false }
local ccomp = obj("BP_JigComponent_C", "BP_JigMultiplayer_c")
ccomp.__owner = obj("Buildable_DisassemblyWorkbench_C", "Buildable_DisassemblyWorkbench_C_c")
ccomp.GetOwner = function(self) return self.__owner end
ccomp.LocalJSIContainers = arr({ { ContainerID = G1 }, { ContainerID = G2 } })
ccomp.DeepSearchForItem = function(_, gg, out) if gs(gg) == "555:0:0:0" then out.ItemFound = cslot end end
containers.note_open(ccomp, { G1, G2 })
handlers.JMC({ "add", gs(G1), "555:0:0:0" })
T = T + 1
run_delays()
check(has_log("info", "555:0:0:0 added on the host is shown here in grid 2 of 2") ~= nil,
  "client log: the added result is shown in grid 2 of 2")
handlers.JMC({ "add", gs(G1), "556:0:0:0" })
T = T + 1
run_delays()
check(#to_host == 1 and to_host[1].kind == "JADD", "a result not shown here is asked for (JADD)")
ccomp.DeepSearchForItem = function(_, gg, out) if gs(gg) == "556:0:0:0" then out.ItemFound = cslot end end
T = T + 2
run_delays()
check(has_log("info", "556:0:0:0 added on the host is shown here in grid 2 of 2 of Buildable_DisassemblyWorkbench_C_c (after asking)") ~= nil,
  "client log after the host's CLIENT_AddNewItem: grid 2 of 2")

print(string.format("disassembly output: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
