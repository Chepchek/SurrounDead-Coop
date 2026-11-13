-- host-side JigTryAddItemSomewhere for a remote player (water well / fishing):
-- the drop waits at the player's feet while that client's screen is asked
-- where it goes (sdc_place WHERE; never the plugin's any-grid add); the world
-- module's own drops are left alone; the client's IGAIN path (drinking)
-- unchanged
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
function ue.hook_native() return true end
local to_host, handlers = {}, {}
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local cfgv = {}
package.loaded["sdc_config"] = { get = function(k) if cfgv[k] ~= nil then return cfgv[k] end return true end }
local sent = {}
package.loaded["sdc_net"] = { send_to = function(pc, kind, ...) sent[#sent + 1] = { pc, kind, ... }; return true end, broadcast = function() end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind, ... } end, on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local world = { stats = { grants = 0, grant_drops = 0 } }
package.loaded["sdc_world"] = world
local hooks, notify = {}, {}
RegisterHook = function(path, fn)
  assert(not hooks[path], "second RegisterHook on " .. path)
  hooks[path] = fn; return 1, 2
end
NotifyOnNewObject = function(cls, fn) notify[#notify + 1] = fn end
FName = function(s) return s end
LoadAsset = function() end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end,
  GetArrayNum = function() return #t end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local ADD = JIG .. "JigTryAddItemSomewhere"

local items = require("sdc_items")
local function items_place() return package.loaded["sdc_place"] end
local S = { role = "host", remote_pcs = {} }
items.init(S)
items.register_handlers()
items.install()
assert(#notify > 0, "no pickup watch")
local function spawn(obj) for _, f in ipairs(notify) do f(obj) end end

-- ---------------------------------------------------------------- host
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc, __path = "/L.L:PersistentLevel.guest" }
assets[guest.__path] = guest
pc.__pawn = guest
local granted = {}
local djig = { __name = "GuestJig", GetOwner = function() return guest end, MainJigContainers = arr({}),
  AddNewItemSomewhere = function(_, da, n) granted[#granted + 1] = { da = da, n = n }; error("the any-grid add is not used") end }
guest.BP_JigMultiplayer = djig
items.host_tick({ pc })
assert(hooks[ADD], "add hook missing on the host")

local function da(name)
  local d = { __name = name, __cls = "JigsawItem_DataAsset_C", __path = "/Game/I/" .. name .. "." .. name }
  assets[d.__path] = d
  return d
end
local jugD = da("DA_DirtyWaterJug")
local botD = da("DA_DirtyWaterBottle")
local n_pick = 0
local function pickup(name, d, n)
  n_pick = n_pick + 1
  local p = { __name = name, __cls = name:gsub("_%d+$", ""), BP_JigPickupComponent = { ItemDataAsset = d, OverrideCount = n },
              __path = "/L.L:PersistentLevel." .. name }
  p.K2_DestroyActor = function(self) self.__valid = false end
  assets[p.__path] = p
  return p
end
local function asks()
  local out = {}
  for _, m in ipairs(sent) do if m[2] == "WHERE" then out[#out + 1] = m end end
  return out
end
-- the well: jug, then bottle, in one call; each add drops its pickup first
local p1 = pickup("BP_DirtyWaterJugPickup_C_1", jugD, 1)
spawn(p1)
hooks[ADD](C(djig), P(djig), P(jugD), P(1), P(false), P({}))
local p2 = pickup("BP_DirtyWaterBottlePickup_C_2", botD, 1)
spawn(p2)
hooks[ADD](C(djig), P(djig), P(botD), P(1), P(false), P({}))
local a = asks()
assert(#a == 2 and a[1][1] == pc and a[1][4] == jugD.__path and a[1][5] == 1 and a[2][4] == botD.__path,
  "the well's fills: that client's screen asked where each goes (WHERE)")
assert(#granted == 0, "not the plugin's any-grid add")
assert(p1.__valid ~= false and p2.__valid ~= false, "the drops wait at its feet for the answers")
assert(has_log("DirtyWaterJug x1 for guest lies at its feet (the host's code dropped it at the player): asked its screen", "info"),
  "ask log")
-- its screen has no room for the jug: the jug stays at its feet
handlers.WHEREIS({ a[1][3], "n", "", "" }, pc)
assert(p1.__valid ~= false and has_log("DirtyWaterJug x1 for guest stays at its feet: its screen has no room for it"), "no room")
-- an answer from another player for the bottle is not taken
handlers.WHEREIS({ a[2][3], "n", "", "" }, { __name = "PC_other", NetConnection = {} })
assert(#items_place()._t.Q.pend == 1, "another player's answer ignored")
print("host: well fills asked for, the drops wait; no room keeps the drop; another player's answer ignored")

-- the world module took this drop itself (its counter moved inside the call)
offset = offset + 1
items.host_tick({ pc })
local p3 = pickup("BP_WoodenLogPickup_C_3", da("DA_WoodenLog"), 2)
spawn(p3)
world.stats.grants = world.stats.grants + 1
local na = #asks()
hooks[ADD](C(djig), P(djig), P(p3.BP_JigPickupComponent.ItemDataAsset), P(2), P(false), P({}))
assert(#asks() == na and p3.__valid ~= false, "world drop handled twice")
-- the next add (a fish) is handled again
local fishD = da("DA_RawPike")
local p4 = pickup("BP_RawPikePickup_C_4", fishD, 2)
spawn(p4)
hooks[ADD](C(djig), P(djig), P(fishD), P(2), P(false), P({}))
a = asks()
assert(#a == na + 1 and a[#a][4] == fishD.__path and a[#a][5] == 2 and p4.__valid ~= false, "fish not asked for")
print("host: world drops left to the world module, a fish asked for")

-- no answer in time: the bottle and the fish stay at its feet
offset = offset + 6
items.host_tick({ pc })
assert(#items_place()._t.Q.pend == 0 and p2.__valid ~= false and p4.__valid ~= false
  and has_log("RawPike x2 for guest stays at its feet: no answer from its screen", "warn"), "no answer")
-- drop not found: nothing asked
local n_before = #asks()
hooks[ADD](C(djig), P(djig), P(jugD), P(1), P(false), P({}))
assert(#asks() == n_before and has_log("its drop was not found", "warn"), "missing drop")
-- an old pickup of the same item is not taken
local p6 = pickup("BP_DirtyWaterJugPickup_C_6", jugD, 1)
spawn(p6)
offset = offset + 1
hooks[ADD](C(djig), P(djig), P(jugD), P(1), P(false), P({}))
assert(#asks() == n_before and p6.__valid ~= false, "old pickup taken")
-- the host's own add / a successful add: nothing
local me = { __name = "host", __cls = "BP_PlayerCharacter_C", Controller = { __name = "HPC" } }
local hjig = { __name = "HostJig", GetOwner = function() return me end }
hooks[ADD](C(hjig), P(hjig), P(jugD), P(1), P(false), P({}))
hooks[ADD](C(djig), P(djig), P(jugD), P(1), P(true), P({}))
assert(#asks() == n_before, "own / successful add touched")
-- switched off
cfgv.host_adds_to_inventory = false
local p7 = pickup("BP_DirtyWaterJugPickup_C_7", jugD, 1)
spawn(p7)
hooks[ADD](C(djig), P(djig), P(jugD), P(1), P(false), P({}))
assert(#asks() == n_before and p7.__valid ~= false, "option ignored")
cfgv.host_adds_to_inventory = nil
assert(#granted == 0, "the plugin's any-grid add never used")
print("host: no answer / missing drop / old pickup / own add / option off handled")

-- ---------------------------------------------------------------- client (drinking: IGAIN as before)
S.role = "client"
items.reset()
local cme = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = cme
local mycomp = { __name = "MyJig", GetOwner = function() return cme end, LocalJSIContainers = arr({}), PendingRequests = arr({}) }
cme.BP_JigMultiplayer = mycomp
items.client_tick()
local empty = { __name = "DA_EmptyWaterCanteen", __path = "/Game/I/DA_EmptyWaterCanteen.DA_EmptyWaterCanteen" }
hooks[ADD](C(mycomp), P(mycomp), P(empty), P(1), P(false), P({}))
assert(to_host[#to_host] and to_host[#to_host][1] == "IGAIN" and to_host[#to_host][2] == empty.__path, "IGAIN not sent")
print("client: drinking still asks the host for the empty container")
for _, l in ipairs(logs) do if l:find("^err") then error("error logged: " .. l) end end
print("ALL OK")
