-- Group C critic fixes (2026-11-13) in sdc_containers / sdc_stations / sdc_deathbox / sdc_tools:
--   B6  a world container's JMC ops go per (viewer, container) in one message a tick, in order;
--       the client applies the packed form and still the single one;
--   A7  a container's viewers that left are dropped by the host tick (not only by a forward);
--   B2  log-only hooks (Jig_UnhandledEvent, RequestServerData) with config debug only;
--   A4  a client's death box entries keep names / paths, no engine objects; a new box at a
--       reused address does not take the old box's marker; only a BP_Marker_C is destroyed;
--   C1  sdc_tools.host_tick (never called) gone; C3 the client's binoculars item only from memory.
-- usage: lua mock_fix_c_items.lua <scripts dir>
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
local function has_log(pat)
  for _, l in ipairs(logs) do if l:find(pat, 1, true) then return l end end
  return nil
end

local T = 1000
os.clock = function() return T end

local objects = {}   -- [path] = object (StaticFindObject)
local world = {}     -- [class] = list (FindAllOf)
local loads = 0
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return ue.valid(o) and (o.__path or "") or "<none>" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all(cls)
  local out = {}
  for _, o in ipairs(world[cls] or {}) do if ue.valid(o) then out[#out + 1] = o end end
  return out
end
function ue.find_all_recent(cls) return ue.find_all(cls) end
function ue.find_object(p) local o = objects[p]; if ue.valid(o) then return o end return nil end
function ue.loaded_asset(p) return ue.find_object(p) end
function ue.load_asset(p) loads = loads + 1; return true, ue.find_object(p) end
function ue.watch_new() return true end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
local delayed = {}
function ue.delay(_, ms, fn) delayed[#delayed + 1] = { due = T + ms / 1000, fn = fn } end
local function run_delayed()
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do if d.due <= T + 1e-9 then d.fn() else delayed[#delayed + 1] = d end end
end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned(o) return o.__runtime == true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) local l = ue.valid(a) and a.__loc; if l then return { X = l.X, Y = l.Y, Z = l.Z } end end
function ue.hook_native() return true end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local cfgv = {}
package.loaded["sdc_config"] = { get = function(k) if cfgv[k] ~= nil then return cfgv[k] end return true end }
local sent, to_host, handlers = {}, {}, {}
package.loaded["sdc_net"] = { broadcast = function() end,
  send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc, kind = kind, f = { ... } }; return true end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind, ... }; return true end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__addr or o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
FText = function(s) return s end
LoadAsset = function() loads = loads + 1 end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end,
  GetArrayNum = function() return #t end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local PFN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local BINO = "EquippedBinoculars_57_FA37337F42E4A60116D21485F6D57AB7"
local IID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"

local items = require("sdc_items")
local containers = require("sdc_containers")
local deathbox = require("sdc_deathbox")
local tools = require("sdc_tools")
local S = { role = "host", remote_pcs = {} }
items.init(S)
items.register_handlers()

-- ===================================================================== host: JMC
local function player(name, a, x)
  local pc = { __name = "PC_" .. name, __addr = a, NetConnection = { __name = "conn_" .. name } }
  local p = { __name = name, __addr = a + 1, __cls = "BP_PlayerCharacter_C", Controller = pc, __loc = { X = x, Y = 0, Z = 0 } }
  pc.__pawn = p
  p.BP_JigMultiplayer = { __name = name .. "Jig", __addr = a + 2, GetOwner = function() return p end,
    MainJigContainers = arr({}), IsVendor = function() return false end }
  return pc, p
end
local function chest(name, a, key, x)
  local crate = { __name = name, __addr = a, __cls = "Container_MedicalLoot_C", __loc = { X = x, Y = 0, Z = 0 },
    JigCanInteract = function(_, out) out.Result = true end }
  return { __name = name .. "Jig", __addr = a + 1, GetOwner = function() return crate end, MainContainersIDs = arr({ G(key) }),
    IsVendor = function() return false end, MainJigContainers = arr({ { [F_CONT_UID] = G(key), [F_ITEMS] = arr({}) } }) }
end
local pc1, guest = player("guest", 100, 0)
local pc2, bob = player("bob", 200, 100)
local ch1 = chest("Crate_1", 300, 500, 200)
local ch2 = chest("Crate_2", 400, 700, 300)
items.host_tick({ pc1, pc2 })
check(hooks[JIG .. "MC_ItemRemoved"] and hooks[JIG .. "SERVER_RequestData"], "host hooks registered")
hooks[JIG .. "SERVER_RequestData"](C(guest.BP_JigMultiplayer), P(ch1))
hooks[JIG .. "SERVER_RequestData"](C(guest.BP_JigMultiplayer), P(ch2))
hooks[JIG .. "SERVER_RequestData"](C(bob.BP_JigMultiplayer), P(ch1))
local function jmc() local out = {}; for _, m in ipairs(sent) do if m.kind == "JMC" then out[#out + 1] = m end end; return out end

print("B6. the JMC ops of one game tick: one message per viewer and container, in order")
sent = {}
hooks[JIG .. "MC_ItemRemoved"](C(ch1), P(G(7)))
hooks[JIG .. "MC_AddNewItem"](C(ch1), P({ [F_USID] = G(8) }), P(arr({})))
hooks[JIG .. "MC_UpdateCount"](C(ch1), P(G(9)), P(4), P(false))
hooks[JIG .. "MC_ItemRemoved"](C(ch2), P(G(5)))
check(#jmc() == 0, "B6: nothing sent inside the game's call (queued)")
T = T + 0.05
run_delayed()
local m = jmc()
local to1, to2 = {}, {}
for _, x in ipairs(m) do if x.pc == pc1 then to1[#to1 + 1] = x elseif x.pc == pc2 then to2[#to2 + 1] = x end end
check(#m == 3 and #to1 == 2 and #to2 == 1, "B6: 3 messages for 4 ops x viewers (0.7.3: 5)")
local a = to1[1] and to1[1].f or {}
check(a[1] == "*" and a[2] == "500:0:0:0" and a[3] == "rm,7:0:0:0" and a[4] == "add,8:0:0:0" and a[5] == "cnt,9:0:0:0,4"
  and #a == 5, "B6: guest's message for crate 1: its three ops in their order")
local b = to1[2] and to1[2].f or {}
check(b[1] == "*" and b[2] == "700:0:0:0" and b[3] == "rm,5:0:0:0", "B6: guest's message for crate 2")
check(to2[1] and to2[1].f[2] == "500:0:0:0" and #to2[1].f == 5, "B6: bob's message for crate 1 (he has only that one open)")
sent = {}
hooks[JIG .. "MC_ItemRemoved"](C(ch1), P(G(10)))
delayed = {}   -- the delayed send never runs
T = T + 1
items.host_tick({ pc1, pc2 })
check(#jmc() == 2, "B6: a delayed send that never ran: the host tick sends it")
sent = {}
for i = 1, 30 do hooks[JIG .. "MC_ItemRemoved"](C(ch2), P(G(1000 + i))) end
containers.flush_viewers()
m = jmc()
check(#m == 2 and #m[1].f == 2 + 24 and #m[2].f == 2 + 6, "B6: 30 ops: 24 to a message, the rest in the next")

print("A7. viewers that left are dropped by the host tick")
check(containers.has_viewers(ch1) and containers.has_viewers(ch2), "A7: both crates open")
pc1.NetConnection, pc2.NetConnection = nil, nil      -- both left
T = T + 1
items.host_tick({})
check(not containers.has_viewers(ch1) and not containers.has_viewers(ch2),
  "A7: the views go with no forward at all (0.7.3: only a forward dropped them)")
pc1.NetConnection = { __name = "conn_dag2" }
hooks[JIG .. "SERVER_RequestData"](C(guest.BP_JigMultiplayer), P(ch1))
check(containers.has_viewers(ch1), "A7: open again")
T = T + 1801
items.host_tick({ pc1 })
check(not containers.has_viewers(ch1), "A7: a view older than VIEW_KEEP goes too")

-- ===================================================================== client
S.role = "client"
items.reset()
logs = {}
local me = { __name = "Me", __addr = 900, __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end,
  BP_JigHelperComp = { __name = "MyH", ServerEquippedItems = { [BINO] = { [IID] = nil } } } }
local mycomp = { __name = "MyJig", GetOwner = function() return me end, LocalJSIContainers = arr({}), PendingRequests = arr({}) }
me.BP_JigMultiplayer = mycomp
ue.__me = me

print("B2. log-only client hooks: with config debug only")
items.client_tick()
check(hooks[JIG .. "Jig_UnhandledEvent"] == nil and hooks[PFN .. "RequestServerData"] == nil,
  "B2: Jig_UnhandledEvent / RequestServerData not hooked without debug")
check(hooks[JIG .. "CLIENT_ContainerDataResponse"] ~= nil, "B2: the contents answer (it notes the open container) is hooked")
log.debug_enabled = true
T = T + 5.1
items.client_tick()
check(hooks[JIG .. "Jig_UnhandledEvent"] ~= nil and hooks[PFN .. "RequestServerData"] ~= nil, "B2: hooked once debug is on")
log.debug_enabled = false

print("B6c. the client applies a packed JMC in order; the single form still")
local jsi = { __name = "Crate_W", ContainerID = G(500) }
local ops = {}
local cchest = { __name = "CChestJig", __cls = "BP_JigComponent_C",
  GetOwner = function() return { __name = "Crate_1c", __cls = "Container_MedicalLoot_C" } end,
  LocalJSIContainers = arr({ jsi }),
  DeepSearchForItem = function() end,
  HandleClientMoveItemToIndex = function(_, g, to, idx, rot) ops[#ops + 1] = string.format("mv %d %d %d %s", g.A, to.A, idx, tostring(rot)) end,
  ClientUpdateCount = function(_, g, n) ops[#ops + 1] = string.format("cnt %d %d", g.A, n) end }
hooks[JIG .. "CLIENT_ContainerDataResponse"](C(mycomp), P(arr({ G(500) })), P(arr({})), P(cchest), P(arr({})))
handlers.JMC({ "*", "500:0:0:0", "mv,7:0:0:0,500:0:0:0,4,0", "cnt,9:0:0:0,3", "mv,8:0:0:0,500:0:0:0,2,1" })
check(table.concat(ops, "; ") == "mv 7 500 4 false; cnt 9 3; mv 8 500 2 true", "B6c: three ops applied in order: " .. table.concat(ops, "; "))
handlers.JMC({ "cnt", "500:0:0:0", "9:0:0:0", "2" })
check(ops[4] == "cnt 9 2", "B6c: the single form (older host) applied")

print("A4. death boxes on a client: names and paths, no engine objects kept")
world.Container_DeadPlayerLoot_C = {}
local function marker(name)
  local mk = { __name = name, __cls = "BP_Marker_C", __path = "/Game/Maps/W.W:PersistentLevel." .. name,
    Marker = { RemoveFromParent = function() end } }
  mk.K2_DestroyActor = function(self) self.__valid = false end
  objects[mk.__path] = mk
  return mk
end
local function box(name, a, x, mk)
  local bx = { __name = name, __addr = a, __cls = "Container_DeadPlayerLoot_C", __path = "/Game/Maps/W.W:PersistentLevel." .. name,
    __loc = { X = x, Y = 0, Z = 0 }, DeathMarker = mk }
  objects[bx.__path] = bx
  table.insert(world.Container_DeadPlayerLoot_C, bx)
  return bx
end
local ma = marker("BP_Marker_C_1")
local ba = box("Container_DeadPlayerLoot_C_1", 5000, 5000, ma)
T = T + 3
items.client_tick()
local e = deathbox._track()[5000]
local objs = 0
for k, v in pairs(e or {}) do if type(v) == "table" and k ~= "loc" then objs = objs + 1 end end
check(e and e.name == ba.__name and e.path == ba.__path and e.mpath == ma.__path and objs == 0,
  "A4: tracked by name / path (0.7.3: the box and marker wrappers, for good)")
-- box A is gone (collected); a new box B gets its address, at the same place, its marker not there yet
ba.__valid = false
local bb = box("Container_DeadPlayerLoot_C_2", 5000, 5000, nil)
T = T + 3
items.client_tick()
e = deathbox._track()[5000]
check(e and e.name == bb.__name and e.mpath == nil, "A4: a new box at a reused address: a new entry, not the old marker")
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_2h", "5000", "0", "0" })
check(ma.__valid ~= false, "A4: DBOXGONE for the new box leaves the old box's marker (0.7.3: destroyed it)")
-- only a BP_Marker_C is destroyed: the marker's path now names something else
local mc = marker("BP_Marker_C_3")
local bc = box("Container_DeadPlayerLoot_C_3", 5100, 9000, mc)
T = T + 3
items.client_tick()
mc.__valid = false
local other = { __name = "BP_Marker_C_3", __cls = "BP_Zombie_C", __path = mc.__path }
other.K2_DestroyActor = function(self) self.__killed = true end
objects[mc.__path] = other
bc.__valid = false
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_3h", "9000", "0", "0" })
check(not other.__killed, "A4: an object of another class at the marker's path is not destroyed")
local md = marker("BP_Marker_C_4")
box("Container_DeadPlayerLoot_C_4", 5200, 20000, md)
T = T + 3
items.client_tick()
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_4h", "20000", "0", "0" })
check(md.__valid == false, "A4: the box's own marker is found by its path and removed")

print("C1 / C3. sdc_tools")
check(tools.host_tick == nil, "C1: host_tick (never called) is gone")
local BPATH = "/Game/I/DA_Binoculars.DA_Binoculars"
handlers.PTOOLS({ BPATH, "-1" })
loads = 0
items.client_tick()
check(loads == 0 and has_log("tools: item " .. BPATH .. " not found on this machine") ~= nil,
  "C3: the host's binoculars item not in memory here: no synchronous load on the client tick (0.7.3: every tick)")
local bino = { __name = "DA_Binoculars", __path = BPATH }
objects[BPATH] = bino
items.client_tick()
check(me.BP_JigHelperComp.ServerEquippedItems[BINO][IID] == bino and loads == 0, "C3: in memory: the slot written, nothing loaded")

for _, l in ipairs(logs) do if l:find("^err:") then print("  (error logged) " .. l) end end
print(string.format("items fixes: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
