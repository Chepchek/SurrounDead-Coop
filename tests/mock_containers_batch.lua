-- Mock harness: a client disassembles a stack of 1000 (host work in batches).
-- Before: one add per unit and output (~3500 adds, each with two grid walks and
-- a slot walk, a reliable JMC op + a log line per change, 1.3 KB messages, a
-- host freeze of seconds). Now: the hits of one output item are added together
-- (stacks of MaxStack), the count changes of one item in a batch are merged
-- into the last one, the viewers are worked out once per batch, one log line
-- per container and batch. The client's end state must be the same.
-- (scaffolding from mock_disasm_output.lua)
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

local reads = 0
local function arr(list)
  return {
    items = list,
    ForEach = function(self, fn)
      reads = reads + 1
      for i, v in ipairs(self.items) do reads = reads + 1; fn(i, { get = function() return v end }) end
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
local raw = {}          -- every change the old code would have sent, in order: { op, args... }
local named_fail = {}   -- [da] = true: AddItemToContainerByName adds nothing for it (the field log)
local JIGFN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local function P(v) return { get = function() return v end } end
local function fire(comp, name, ...)
  local h = hooks[JIGFN .. name]
  if h then h(P(comp), ...) end
end
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
    if named_fail[d] then return end
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
          raw[#raw + 1] = { "cnt", gs(it[F_USID]), it[F_INFO][F_COUNT] }
          fire(self, "MC_UpdateCount", P(it[F_USID]), P(it[F_INFO][F_COUNT]), P(false))
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
        raw[#raw + 1] = { "add", gs(it[F_USID]) }
        fire(self, "MC_AddNewItem", P(it))
        return
      end
    end
  end
  comp.SERVER_RequestConsumeItem = function(self, _, g, n)
    calls[#calls + 1] = { "consume", gs(g), n }
    for _, rc in ipairs(self.MainJigContainers.items) do
      for i, it in ipairs(rc[F_ITEMS].items) do
        if gs(it[F_USID]) == gs(g) then
          table.remove(rc[F_ITEMS].items, i)
          raw[#raw + 1] = { "rm", gs(g) }
          fire(self, "MC_ItemRemoved", P(g))
          return
        end
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

-- ------------------------------------------------------------ measuring
local ue_calls = 0
for k, f in pairs(ue) do
  if type(f) == "function" then ue[k] = function(...) ue_calls = ue_calls + 1; return f(...) end end
end
local orig_notify = containers.notify_viewers
containers.notify_viewers = function(c, op, ...)
  raw[#raw + 1] = { op, ... }
  return orig_notify(c, op, ...)
end
containers.host_tick()   -- registers the plugin's multicast hooks
check(hooks[JIGFN .. "MC_UpdateCount"] ~= nil and hooks[JIGFN .. "MC_AddNewItem"] ~= nil, "multicast hooks registered")

local function jmc_msgs()
  local out = {}
  for _, s in ipairs(sent) do if s.kind == "JMC" then out[#out + 1] = s end end
  return out
end
local function jmc_ops(pcx)
  local ops = {}
  for _, s in ipairs(sent) do
    if s.kind == "JMC" and (pcx == nil or s.pc == pcx) then
      for i = 3, #s.args do ops[#ops + 1] = s.args[i] end
    end
  end
  return ops
end
local function bytes_of(msgs)
  local n = 0
  for _, s in ipairs(msgs) do for _, a in ipairs(s.args) do n = n + #tostring(a) + 1 end; n = n + 8 end
  return n
end
local function split(s) local t = {}; for p in (s .. ","):gmatch("([^,]*),") do t[#t + 1] = p end; return t end
-- the client's view built from a stream of ops: [uid] = count (-1: shown, count not sent)
local function apply(stream)
  local m = {}
  for _, o in ipairs(stream) do
    local op = o[1]
    if op == "add" then if m[o[2]] == nil then m[o[2]] = -1 end
    elseif op == "cnt" then if tonumber(o[3]) == 0 then m[o[2]] = nil else m[o[2]] = tonumber(o[3]) end
    elseif op == "rm" then m[o[2]] = nil
    elseif op == "stk" then m[o[2]] = tonumber(o[3]); m[o[4]] = tonumber(o[5]) end
  end
  return m
end
local function from_msgs(ops)
  local st = {}
  for _, o in ipairs(ops) do st[#st + 1] = split(o) end
  return st
end
local function dump(m)
  local ks = {}
  for k in pairs(m) do ks[#ks + 1] = k end
  table.sort(ks)
  local out = {}
  for _, k in ipairs(ks) do out[#out + 1] = k .. "=" .. m[k] end
  return table.concat(out, ";")
end
local function count_logs(pat)
  local n = 0
  for _, l in ipairs(logs) do if l:find(pat, 1, true) then n = n + 1 end end
  return n
end

-- ============================================================ 1. a stack of 1000
print("-- 1: a client disassembles 1000 rounds in one go")
local PLASTIC = da("Plastic", nil, false, 50)
local CASING = da("BulletCasing", nil, false, 50)
local POWDER = da("Gunpowder", nil, false, 100)
local LEAD = da("Lead", nil, false, 50)
local AMMO = da("308Ammo", { { PLASTIC, 1 }, { CASING, 1 }, { POWDER, 2 }, { LEAD, 1 } }, true, 1000)
named_fail[PLASTIC] = true   -- the field log: these never went into the named grid, only the old add took them
named_fail[POWDER] = true
local st, comp, IN, OUT = new_station({ X = 0, Y = 0, Z = 0 })
st.CurrentActor = pawn
world[#world + 1] = st
put(IN, item(AMMO, 1000, IN, 5))
containers.note_view(pawn, comp)
sent, logs, calls, raw = {}, {}, {}, {}
reads, ue_calls = 0, 0
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
T = T + 1
run_delays()
local adds_calls, consumes = 0, 0
for _, c in ipairs(calls) do
  if c[1] == "consume" then consumes = consumes + 1 else adds_calls = adds_calls + 1 end
end
local msgs = jmc_msgs()
local ops = jmc_ops()
local nlogs = count_logs("containers:") + count_logs("stations:")
print(string.format("  METRIC game add calls=%d consume=%d  container reads=%d  ue calls=%d  multicast changes (old code's ops)=%d",
  adds_calls, consumes, reads, ue_calls, #raw))
print(string.format("  METRIC JMC messages=%d ops=%d bytes=%d  log lines=%d (of them warn=%d)", #msgs, #ops, bytes_of(msgs), nlogs,
  count_logs("warn: stations:")))

local tot = {}
for _, rc in ipairs({ IN, OUT }) do
  for _, it in ipairs(rc[F_ITEMS].items) do
    local nm = it[F_INFO][F_ITEMID].name
    tot[nm] = (tot[nm] or 0) + it[F_INFO][F_COUNT]
  end
end
check(tot.Plastic == 1000 and tot.BulletCasing == 1000 and tot.Gunpowder == 2000 and tot.Lead == 1000,
  string.format("every hit is in the station: Plastic %s, Casing %s, Gunpowder %s, Lead %s", tostring(tot.Plastic),
    tostring(tot.BulletCasing), tostring(tot.Gunpowder), tostring(tot.Lead)))
check(tot["308Ammo"] == nil, "the 1000 rounds were consumed")
local maxstack_ok = true
for _, rc in ipairs({ IN, OUT }) do
  for _, it in ipairs(rc[F_ITEMS].items) do
    if it[F_INFO][F_COUNT] > it[F_INFO][F_ITEMID].MaxStack then maxstack_ok = false end
  end
end
check(maxstack_ok, "no stack above its MaxStack")
local ref, got = apply(raw), apply(from_msgs(ops))
check(dump(ref) == dump(got), "the client's end state equals the one of the unmerged stream (" .. #raw .. " ops -> " .. #ops .. ")")
local host_ok, nhost = true, 0
for _, rc in ipairs({ IN, OUT }) do
  for _, it in ipairs(rc[F_ITEMS].items) do
    nhost = nhost + 1
    local v = got[gs(it[F_USID])]
    if v == nil then host_ok = false; print("    ghost-less miss: " .. gs(it[F_USID])) end
    if v ~= nil and v >= 0 and v ~= it[F_INFO][F_COUNT] then host_ok = false; print("    wrong count " .. gs(it[F_USID])) end
  end
end
check(host_ok, "every item of the host's data is shown with its count (" .. nhost .. " stacks), no lost change")
local ghost = false
for u, v in pairs(got) do
  local found = false
  for _, rc in ipairs({ IN, OUT }) do
    for _, it in ipairs(rc[F_ITEMS].items) do if gs(it[F_USID]) == u then found = true end end
  end
  if not found then ghost = true end
end
check(not ghost, "no ghost: nothing shown that the host does not have (the consumed stack included)")
check(adds_calls <= 150, "game add calls batched (<= 150, was ~3500): " .. adds_calls)
check(consumes == 1, "one consume for the stack")
check(#msgs <= 8, "JMC messages for the viewer (<= 8): " .. #msgs)
check(bytes_of(msgs) <= 12000, "JMC bytes (<= 12000): " .. bytes_of(msgs))
check(nlogs <= 6, "log lines containers+stations (<= 6): " .. nlogs)
check(count_logs("warn: stations:") <= 1, "one warning for the old-way adds, not one per output")
check(ue_calls <= 1000, "engine helper calls (<= 1000, was ~156000): " .. ue_calls)
check(reads <= 12000, "container reads (<= 12000): " .. reads)
local rr
for _, s in ipairs(sent) do if s.kind == "DISASMR" then rr = s end end
check(rr and rr.args[4] + rr.args[6] >= 4, "DISASMR still sent after the JMC ops")

-- ============================================================ 2. order and merging
print("-- 2: merging keeps the order where it matters")
T = T + 5
run_delays()
sent, logs, raw = {}, {}, {}
local function fire_all(list)
  for _, e in ipairs(list) do
    local n = e[1]
    if n == "cnt" then fire(comp, "MC_UpdateCount", P(guid(e[2])), P(e[3]), P(false))
    elseif n == "stk" then fire(comp, "MC_UpdateStack", P(guid(e[2])), P(e[3]), P(guid(e[4])), P(e[5]))
    elseif n == "rm" then fire(comp, "MC_ItemRemoved", P(guid(e[2])))
    elseif n == "add" then fire(comp, "MC_AddNewItem", P({ [F_USID] = guid(e[2]) }))
    end
    if n == "cnt" then raw[#raw + 1] = { "cnt", gs(guid(e[2])), e[3] }
    elseif n == "stk" then raw[#raw + 1] = { "stk", gs(guid(e[2])), e[3], gs(guid(e[4])), e[5] }
    else raw[#raw + 1] = { n, gs(guid(e[2])) } end
  end
end
fire_all({
  { "add", 7001 },
  { "cnt", 7001, 2 }, { "cnt", 7001, 3 }, { "cnt", 7001, 4 },   -- merged into the last (cnt 4)
  { "cnt", 7002, 5 },
  { "stk", 7002, 3, 7003, 7 },                                  -- names 7002: the next cnt 7002 is a new op
  { "cnt", 7002, 9 },
  { "cnt", 7003, 8 }, { "cnt", 7003, 9 },
  { "rm", 7003 },
  { "cnt", 7004, 1 }, { "cnt", 7004, 2 },
})
T = T + 1
run_delays()
local o2 = jmc_ops(pc)
check(dump(apply(raw)) == dump(apply(from_msgs(o2))), "end state of the merged stream = the unmerged one (" .. #raw .. " -> " .. #o2 .. " ops)")
check(#o2 == 8, "8 ops left of 12 (add, cnt 4, cnt 5, stk, cnt 9, cnt 9 of 7003, rm, cnt 2): " .. #o2 .. " [" .. table.concat(o2, " | ") .. "]")
local pos = {}
for i, o in ipairs(o2) do pos[o] = i end
local i_stk, i_c2 = nil, nil
for i, o in ipairs(o2) do
  if o:sub(1, 3) == "stk" then i_stk = i end
  if o == "cnt,7002:0:0:0,9" then i_c2 = i end
end
check(i_stk and i_c2 and i_c2 > i_stk, "cnt after stk stays after it (not merged across)")
check(pos["rm,7003:0:0:0"] and pos["cnt,7003:0:0:0,9"] and pos["rm,7003:0:0:0"] > pos["cnt,7003:0:0:0,9"], "rm after the last cnt of the item")
check(pos["cnt,7001:0:0:0,4"] and pos["cnt,7004:0:0:0,2"] and not pos["cnt,7001:0:0:0,2"], "the earlier counts of one item are gone")

-- ============================================================ 3. one change stays fast
print("-- 3: one move, as responsive as before")
T = T + 5
run_delays()
sent, logs = {}, {}
fire(comp, "MC_MoveItemToIndex", P(comp), P(guid(7100)), P(guid(11)), P(3), P(false))
T = T + 0.029
run_delays()
check(#jmc_msgs() == 0, "nothing sent before the 30 ms window ends")
T = T + 0.002
run_delays()
local m3 = jmc_msgs()
check(#m3 == 1 and #jmc_ops() == 1 and jmc_ops()[1] == "mv,7100:0:0:0,11:0:0:0,3,0", "one message, one op, in the same window as before: " .. tostring(jmc_ops()[1]))
check(count_logs("containers: 1 op(s)") == 1, "one log line")

-- ============================================================ 4. a viewer who opens in the middle of a window
print("-- 4: a viewer who opens during a batch window")
T = T + 5
run_delays()
sent, logs = {}, {}
local conn2 = obj("NetConnection", "IpConnection_2")
local pc2 = obj("BP_PlayerController_C", "BP_PlayerController_C_8", { NetConnection = conn2 })
local pawn2 = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_8", { Controller = pc2, __loc = { X = 50, Y = 0, Z = 0 } })
pc2.Pawn = pawn2
fire(comp, "MC_UpdateCount", P(guid(7200)), P(1), P(false))
containers.note_view(pawn2, comp)
fire(comp, "MC_UpdateCount", P(guid(7200)), P(2), P(false))
T = T + 1
run_delays()
local a1, a2 = jmc_ops(pc), jmc_ops(pc2)
check(#a1 == 1 and a1[1] == "cnt,7200:0:0:0,2", "the first viewer: one merged cnt")
check(#a2 == 1 and a2[1] == "cnt,7200:0:0:0,2", "the one who opened in the window gets the change after that: " .. tostring(a2[1]))

-- ============================================================ 5. a big batch splits into messages
print("-- 5: many different items: messages of at most PER_MSG ops, none lost")
T = T + 5
run_delays()
sent, raw = {}, {}
local list = {}
for i = 1, 100 do list[#list + 1] = { "cnt", 8000 + i, i } end
fire_all(list)
T = T + 1
run_delays()
local o5 = jmc_ops(pc)
check(#o5 == 100, "100 items, 100 ops: " .. #o5)
check(#jmc_msgs() == 10, "10 messages for two viewers (5 each of 24): " .. #jmc_msgs())

-- ============================================================ 6. dur merges like cnt, with the same barrier
print("-- 6: dur merge and its barrier")
T = T + 5
run_delays()
sent = {}
local function durp(x, y) return P({ X = x, Y = y }) end
fire(comp, "MC_UpdateDurability", P(guid(7300)), durp(1, 1))
fire(comp, "MC_UpdateDurability", P(guid(7300)), durp(2, 2))
fire(comp, "MC_UpdateStack", P(guid(7300)), P(1), P(guid(7301)), P(1))   -- names 7300: the next dur is a new op
fire(comp, "MC_UpdateDurability", P(guid(7300)), durp(3, 3))
fire(comp, "MC_UpdateDurability", P(guid(7300)), durp(4, 4))
fire(comp, "MC_UpdateDurability", P(guid(7302)), durp(5, 5))
T = T + 1
run_delays()
local o6 = jmc_ops(pc)
check(#o6 == 4 and o6[1] == "dur,7300:0:0:0,2.000,2.000" and o6[2]:sub(1, 3) == "stk" and o6[3] == "dur,7300:0:0:0,4.000,4.000"
  and o6[4] == "dur,7302:0:0:0,5.000,5.000", "dur: merged before and after the stk, not across it: " .. table.concat(o6, " | "))
-- cnt and dur of one item do not swallow each other
sent = {}
fire(comp, "MC_UpdateCount", P(guid(7310)), P(1), P(false))
fire(comp, "MC_UpdateDurability", P(guid(7310)), durp(1, 1))
fire(comp, "MC_UpdateCount", P(guid(7310)), P(2), P(false))
T = T + 1
run_delays()
check(#jmc_ops(pc) == 2, "cnt and dur of one item stay two ops: " .. table.concat(jmc_ops(pc), " | "))

-- ============================================================ 7. the viewers of a window do not outlive it
print("-- 7: a player who left the zone gets no ops after the window")
T = T + 5
run_delays()
sent = {}
fire(comp, "MC_UpdateCount", P(guid(7400)), P(1), P(false))
T = T + 1
run_delays()
check(#jmc_ops(pc) == 1 and #jmc_ops(pc2) == 1, "both viewers get an op in the zone")
sent = {}
pawn2.__loc = { X = 90000, Y = 0, Z = 0 }
fire(comp, "MC_UpdateCount", P(guid(7401)), P(1), P(false))   -- (inside the old window: the viewers as they were)
T = T + 0.06
run_delays()
fire(comp, "MC_UpdateCount", P(guid(7402)), P(1), P(false))   -- (a new window: the walk happens again)
T = T + 1
run_delays()
local gone2 = jmc_ops(pc2)
check(#jmc_ops(pc) == 2 and #gone2 <= 1 and not table.concat(gone2, "|"):find("7402", 1, true),
  "the player who left gets nothing after the window (" .. #gone2 .. " op(s))")
pawn2.__loc = { X = 50, Y = 0, Z = 0 }

-- ============================================================ 8. reset() drops the queue and the batch's summary
print("-- 8: reset")
T = T + 5
run_delays()
sent, logs = {}, {}
fire(comp, "MC_UpdateCount", P(guid(7500)), P(1), P(false))
containers.reset()
containers.note_view(pawn, comp)
T = T + 1
run_delays()
check(#jmc_msgs() == 0, "nothing queued before the reset is sent after it")
fire(comp, "MC_UpdateCount", P(guid(7501)), P(1), P(false))
T = T + 1
run_delays()
check(#jmc_ops(pc) == 1 and count_logs("containers: 1 op(s)") == 1 and count_logs("containers: 2 op(s)") == 0,
  "one op, one summary line: the old batch's summary is gone")

-- ============================================================ 9. the dice are the game's (37 % and 80 %, seeded)
print("-- 9: a seeded differential run: the same sums as one roll per unit")
local seed
local function lcg() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
math.random = function(a, b)
  if a == nil then return lcg() end
  return a + math.floor(lcg() * (b - a + 1))
end
local DICE_A = da("DiceA", nil, false, 50)
local DICE_B = da("DiceB", nil, false, 50)
local DICE = obj("JigsawItem_DataAsset_C", "DA_Dice", { name = "Dice", MaxStack = 1000, ["CanStack?"] = true, ["CanBeDisassembled?"] = true })
DICE.DisassemblyItems = arr({
  { [R_ID] = DICE_A, [R_CHANCE] = 37, [R_MIN] = 1, [R_MAX] = 3 },
  { [R_ID] = DICE_B, [R_CHANCE] = 80, [R_MIN] = 2, [R_MAX] = 2 },
})
seed = 4242
local want_a, want_b = 0, 0
for _ = 1, 400 do if lcg() * 100 <= 37 then want_a = want_a + 1 + math.floor(lcg() * 3) end end
for _ = 1, 400 do if lcg() * 100 <= 80 then want_b = want_b + 2 + math.floor(lcg() * 1) end end
-- (a hit of DiceB draws math.random(2, 2): one more draw, as the game's code does)
seed = 4242
local st9, comp9, IN9, OUT9 = new_station({ X = 0, Y = 0, Z = 0 })
for i = #world, 1, -1 do world[i].CurrentActor = nil; world[i] = nil end
st9.CurrentActor = pawn
world[#world + 1] = st9
put(IN9, item(DICE, 400, IN9, 5))
T = T + 5
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
local tot9 = {}
for _, rc in ipairs({ IN9, OUT9 }) do
  for _, it in ipairs(rc[F_ITEMS].items) do
    local nm = it[F_INFO][F_ITEMID].name
    tot9[nm] = (tot9[nm] or 0) + it[F_INFO][F_COUNT]
  end
end
check(want_a > 100 and want_a < 500 and want_b > 500, "the reference sums are sane: " .. want_a .. " / " .. want_b)
check(tot9.DiceA == want_a and tot9.DiceB == want_b,
  string.format("sums = one roll per unit: DiceA %s (want %d), DiceB %s (want %d)", tostring(tot9.DiceA), want_a, tostring(tot9.DiceB), want_b))

-- ============================================================ 10. a full grid with a partial stack
print("-- 10: the output grid full except a partial stack: it is topped up, the rest dropped")
local SCR = da("ScrapMetal2", nil, false, 50)
local KNIFE2 = da("Knife2", { { SCR, 40 } }, true, 1)
math.random = function(a) if a == nil then return 0 end return a end
local st10, comp10, IN10, OUT10 = new_station({ X = 0, Y = 0, Z = 0 })
for i = #world, 1, -1 do world[i].CurrentActor = nil; world[i] = nil end
st10.CurrentActor = pawn
world[#world + 1] = st10
containers.note_view(pawn, comp10)
for i = 1, #OUT10[F_SLOTS].items do OUT10[F_SLOTS].items[i][F_HOSTING] = guid(9000 + i) end
local part = item(SCR, 30, OUT10, 0)
OUT10[F_ITEMS].items[1] = part
put(IN10, item(KNIFE2, 1, IN10, 3))
dropped = {}
sent = {}
T = T + 5
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
check(part[F_INFO][F_COUNT] == 50, "the partial stack is topped up to MaxStack: " .. part[F_INFO][F_COUNT])
check(#dropped == 1 and dropped[1][1] == "ScrapMetal2" and dropped[1][2] == 20, "only the rest (20) is dropped at the feet: " ..
  (dropped[1] and (dropped[1][1] .. " " .. dropped[1][2]) or "nothing"))
local c10 = false
for _, o in ipairs(jmc_ops(pc)) do if o == "cnt," .. gs(part[F_USID]) .. ",50" then c10 = true end end
check(c10, "the viewer is told the new count")

-- ============================================================ 11. MaxStack unreadable: one unit per add, as before
print("-- 11: MaxStack unreadable")
local SCR3 = da("ScrapMetal3", nil, false, 50)
SCR3.MaxStack = nil
local KNIFE3 = da("Knife3", { { SCR3, 3 } }, true, 1)
local st11, comp11, IN11 = new_station({ X = 0, Y = 0, Z = 0 })
for i = #world, 1, -1 do world[i].CurrentActor = nil; world[i] = nil end
st11.CurrentActor = pawn
world[#world + 1] = st11
put(IN11, item(KNIFE3, 2, IN11, 3))
calls = {}
T = T + 5
handlers.DISASM({ "Buildable_DisassemblyWorkbench_C", "0", "0", "0" }, pc)
local ones, adds11 = true, 0
for _, c in ipairs(calls) do
  if c[1] == "AddItemToContainerByName" then adds11 = adds11 + 1; if c[4] ~= 3 then ones = false end end
end
check(adds11 == 2 and ones, "every hit its own add (2 of 3), not one stack of the whole sum (6): " .. adds11)

print(string.format("containers batch: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
