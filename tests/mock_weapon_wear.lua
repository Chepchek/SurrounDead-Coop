-- Mock harness: a client's gun and muzzle attachment wear (sdc_wear, driven by
-- sdc_items). Client: the game's own ServerFuncUpdateDurabilityByUID call is
-- claimed only inside BP_FirearmPickup.ReduceDurability / MuzzleDurability of
-- the own gun, summed and sent at most every 0.5 s (GWEAR); GetDurability
-- reads the host's value minus wear on its way; CLIENT_UpdateDurability
-- confirms. Host: the same function on its copy of that player's inventory;
-- ITEMS / UIDS carry the value. No wear for the host's own shots, other
-- players' guns, melee or stale calls.
-- usage: lua mock_weapon_wear.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

local logs = {}
local log = setmetatable({ debug_enabled = true }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local function count_log(level, pat)
  local n = 0
  for _, l in ipairs(logs) do
    if l:sub(1, #level + 2) == level .. ": " and l:find(pat, 1, true) then n = n + 1 end
  end
  return n
end

local T = 1000
os.clock = function() return T end

-- ------------------------------------------------------------ engine mocks
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o) return ue.valid(o) and (rawget(o, "__cls") or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all() return {} end
function ue.find_object() return nil end
local me_pawn = nil
function ue.local_pawn() return me_pawn end
function ue.local_pc() return me_pawn and me_pawn.Controller end
function ue.pawn_of(pc) local p = pc and pc.Pawn; if ue.valid(p) then return p end end
function ue.role(a) return a and a.Role or -1 end
function ue.is_runtime_spawned() return false end
function ue.hook_native() return true end
local delayed = {}
function ue.delay(label, ms, fn)
  delayed[#delayed + 1] = { label = label, due = T + ms / 1000, fn = fn }
  return #delayed
end
local function run_due(label)
  local n, keep = 0, {}
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do
    if d.label == label and d.due <= T + 1e-9 then d.fn(); n = n + 1 else keep[#keep + 1] = d end
  end
  for _, d in ipairs(delayed) do keep[#keep + 1] = d end
  delayed = keep
  return n
end
local function pending_delays(label)
  local n = 0
  for _, d in ipairs(delayed) do if d.label == label then n = n + 1 end end
  return n
end
function ue.sub_time(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
  return ok
end
setmetatable(ue, { __index = function() return function() return nil end end })
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local cfgv = { replicate_items = true, client_tools = true }
package.loaded["sdc_config"] = { get = function(k) local v = cfgv[k]; if v == nil then return true end return v end }
local sent, to_host, handlers = {}, {}, {}
local host_link = true
package.loaded["sdc_net"] = {
  send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc.__name, kind = kind, args = { ... } } return true end,
  broadcast = function() end,
  send_to_host = function(kind, ...)
    if not host_link then return false end
    to_host[#to_host + 1] = { kind = kind, args = { ... } }
    return true
  end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (rawget(o, "__name") or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = hooks[path] or {}; table.insert(hooks[path], fn); return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end

local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local GUN = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:"
local DUR, CFUNC, GETDUR = JIG .. "ServerFuncUpdateDurabilityByUID", JIG .. "ClientFunc_UpdateDurability", JIG .. "GetDurability"
local REDUCE, MUZZLE = GUN .. "ReduceDurability", GUN .. "MuzzleDurability"

local function P(v)
  local p = { v = v }
  function p:get() return self.v end
  function p:set(x) self.v = x end
  return p
end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local function fire(path, obj, ...)
  for _, fn in ipairs(hooks[path] or {}) do fn(P(obj), ...) end
end
local function gwear(from)
  local out = {}
  for i = (from or 1), #to_host do if to_host[i].kind == "GWEAR" then out[#out + 1] = to_host[i].args[1] end end
  return out
end

-- ------------------------------------------------------------ client objects
local function character(name, local_ctl, pc)
  local p = { __name = name, __cls = "BP_PlayerCharacter_C", Controller = pc }
  function p:IsLocallyControlled() return local_ctl end
  if pc then pc.Pawn = p end
  return p
end
local function owned(name, cls, owner)
  local o = { __name = name, __cls = cls }
  function o:GetOwner() return owner end
  return o
end
local my_pc = { __name = "MyPC", __cls = "BP_PlayerController_C" }
local me = character("Me", true, my_pc)
me_pawn = me
local eq_writes = 0
me.BP_JigHelperComp = { __name = "MyHelper", RepActorsData = { ForEach = function() end },
  EquipmentUIDs = { Empty = function() end, Add = function() eq_writes = eq_writes + 1 end } }
local my_jig = owned("MyJig", "BP_JigComponent_C", me)
local rifle = owned("Rifle", "BP_MarksmansLegacyPickup_C", me)
local other = character("Other", false, nil)
local other_jig = owned("OtherJig", "BP_JigComponent_C", other)
local other_gun = owned("OtherGun", "BP_BlackOpsMP5Pickup_C", other)

local function shot(jig, gun, gun_uid, gun_minus, muz_uid, muz_minus)
  fire(DUR, jig, P(G(gun_uid)), P(gun_minus), P(false), P(0))
  fire(REDUCE, gun, P(true))
  if muz_uid then
    fire(DUR, jig, P(G(muz_uid)), P(muz_minus), P(false), P(0))
    fire(MUZZLE, gun, P(true))
  end
end
local function read_dur(uid)
  local out = P(0)
  fire(GETDUR, my_jig, P(G(uid)), out)
  return out.v
end

local items = require("sdc_items")
local wear = require("sdc_wear")
local S = { role = "client", remote_pcs = {} }
items.init(S)
items.register_handlers()
items.client_tick()

-- ------------------------------------------------------------ client
print("client: hooks")
check(hooks[DUR] and hooks[CFUNC] and hooks[REDUCE] and hooks[MUZZLE], "the four wear hooks are registered")
check(hooks[GETDUR] ~= nil, "the GetDurability fix is registered")
check(handlers.GWEAR ~= nil, "GWEAR handler registered")

print("client: a shot of the own suppressed rifle")
handlers.ITEMS({ "1:0:0:0=50.0;2:0:0:0=30.0;9:0:0:0=80.0" }, my_pc)
check(read_dur(1) == 50, "the host's value before any shot")
shot(my_jig, rifle, 1, 0.25, 2, 0.1)
check(#gwear() == 0, "nothing sent inside the shot")
check(pending_delays("wear-flush") == 1, "one delayed send")
check(near(read_dur(1), 49.75), "the gun reads the host's value minus its own wear: " .. tostring(read_dur(1)))
check(near(read_dur(2), 29.9), "the suppressor too: " .. tostring(read_dur(2)))
check(count_log("info", "wears 0.2500 a shot") == 1 and count_log("info", "wears 0.1000 a shot") == 1,
  "one line per item with the game's per-shot wear")
for _ = 1, 3 do T = T + 0.1; shot(my_jig, rifle, 1, 0.25, 2, 0.1) end
check(pending_delays("wear-flush") == 1, "still one delayed send for four shots")
T = T + 0.5
run_due("wear-flush")
local g = gwear()
check(#g == 1 and g[1] == "1:0:0:0=1.0000/4;2:0:0:0=0.4000/4", "one message with the sums: " .. tostring(g[1]))
check(near(read_dur(1), 49.0), "sent, not confirmed: still subtracted: " .. tostring(read_dur(1)))
check(count_log("info", "own wear sent to the host") == 1, "the send is logged")

print("client: what is not a shot of the own gun")
local before = #to_host
local st = wear.stats.weapon
fire(DUR, my_jig, P(G(9)), P(0.5), P(false), P(0))       -- melee: no firearm function around it
T = T + 0.3
fire(REDUCE, rifle, P(true))                             -- stale record
fire(MUZZLE, rifle, P(true))                             -- nothing recorded
check(wear.stats.weapon == st and wear.stats.muzzle == 4, "a melee / stale call is not claimed")
check(read_dur(9) == 80, "the knife reads the host's value (the host's swing replay wears it)")
fire(DUR, other_jig, P(G(1)), P(0.25), P(false), P(0)); fire(REDUCE, other_gun, P(true))
fire(DUR, my_jig, P(G(1)), P(0.25), P(false), P(0)); fire(REDUCE, other_gun, P(true))
check(wear.stats.weapon == st, "another player's component / gun is not claimed")
fire(DUR, my_jig, P(G(1)), P(0.25), P(true), P(0)); fire(REDUCE, rifle, P(true))
check(wear.stats.weapon == st, "a destroying call is not claimed")
fire(DUR, my_jig, P(G(0)), P(0.25), P(false), P(0)); fire(REDUCE, rifle, P(true))
check(wear.stats.weapon == st, "an empty UID is not claimed")
T = T + 1
run_due("wear-flush")
items.client_tick()
check(#to_host == before, "nothing sent for them")

print("client: the host's value comes back")
fire(CFUNC, my_jig, P(G(1)), P({ X = 49.0, Y = 100 }))
fire(CFUNC, my_jig, P(G(2)), P({ X = 29.6, Y = 100 }))
check(near(wear.own_minus("1:0:0:0"), 0) and near(wear.own_minus("2:0:0:0"), 0), "the sent wear is confirmed")
check(near(items.reported("1:0:0:0"), 49.0) and near(read_dur(1), 49.0), "the gun reads the host's new value at once")
check(near(read_dur(2), 29.6), "the suppressor too")
fire(CFUNC, other_jig, P(G(9)), P({ X = 1, Y = 100 }))
check(read_dur(9) == 80, "another player's CLIENT_UpdateDurability is not taken")
check(wear.stats.confirmed == 2, "two confirmations")

print("client: automatic fire, 10 shots a second for 3 s")
local from = #to_host + 1
for _ = 1, 30 do
  T = T + 0.1
  shot(my_jig, rifle, 1, 0.25, 2, 0.1)
  run_due("wear-flush")
end
T = T + 0.5
run_due("wear-flush")
g = gwear(from)
local sum1, n1, sum2 = 0, 0, 0
for _, s in ipairs(g) do
  for u, m, n in s:gmatch("([%-%d:]+)=([%d%.]+)/(%d+)") do
    if u == "1:0:0:0" then sum1 = sum1 + tonumber(m); n1 = n1 + tonumber(n) end
    if u == "2:0:0:0" then sum2 = sum2 + tonumber(m) end
  end
end
check(#g >= 5 and #g <= 8, "batched: " .. #g .. " message(s) for 30 shots")
check(math.abs(sum1 - 7.5) < 1e-3 and n1 == 30 and math.abs(sum2 - 3.0) < 1e-3, "every shot's wear sent once: "
  .. sum1 .. " / " .. n1 .. " shots, " .. sum2)
check(near(read_dur(1), 49.0 - sum1), "nothing confirmed yet: the gun reads 41.5: " .. tostring(read_dur(1)))

print("client: unconfirmed wear (a host without the fix) stops counting")
T = T + 5
items.client_tick()
check(wear.stats.expired >= 5 and count_log("warn", "did not confirm") >= 1, "expired and warned")
check(near(wear.own_minus("1:0:0:0"), 0) and near(read_dur(1), 49.0), "the host's value again")

print("client: a lost timer, no connection")
delayed = {}
from = #to_host + 1
shot(my_jig, rifle, 1, 0.25)
delayed = {}                      -- the timer never runs
T = T + 3
items.client_tick()
g = gwear(from)
check(#g == 1 and g[1] == "1:0:0:0=0.2500/1", "the client tick sends what a lost timer left: " .. tostring(g[1]))
host_link = false
from = #to_host + 1
T = T + 1
shot(my_jig, rifle, 1, 0.25)
T = T + 1
run_due("wear-flush")
items.client_tick()
check(#gwear(from) == 0 and near(wear.own_minus("1:0:0:0"), 0.25 + 0.25), "kept while there is no connection")
host_link = true
T = T + 1
items.client_tick()
check(#gwear(from) == 1, "sent once the connection is there")

print("client: switched off / host role")
cfgv.client_durability_from_host = false
from = #to_host + 1
st = wear.stats.weapon
T = T + 2
shot(my_jig, rifle, 1, 0.25)
T = T + 1
run_due("wear-flush")
items.client_tick()
check(wear.stats.weapon == st and #gwear(from) == 0, "config client_durability_from_host = false: nothing")
cfgv.client_durability_from_host = nil
S.role = "host"
delayed = {}
shot(my_jig, rifle, 1, 0.25, 2, 0.1)
check(wear.stats.weapon == st and pending_delays("wear-flush") == 0, "the host's own shots: nothing (the game wears them)")

print("client: equipment UIDs whose durabilities change")
S.role = "client"
local info0 = count_log("info", "equipment UIDs from the host written")
handlers.UIDS({ "Jig.PlayerSlot.Headwear=5:0:0:0@90.00;Jig.PlayerSlot.PrimaryWeapon=1:0:0:0@50.00" })
check(count_log("info", "equipment UIDs from the host written") == info0 + 1 and eq_writes == 2, "a new map: info line, written")
handlers.UIDS({ "Jig.PlayerSlot.Headwear=5:0:0:0@90.00;Jig.PlayerSlot.PrimaryWeapon=1:0:0:0@49.75" })
check(count_log("info", "equipment UIDs from the host written") == info0 + 1 and eq_writes == 4
  and count_log("debug", "(durabilities only)") == 1, "durabilities only: written again, a debug line")
handlers.UIDS({ "Jig.PlayerSlot.Headwear=5:0:0:0@90.00;Jig.PlayerSlot.PrimaryWeapon=3:0:0:0@100.00" })
check(count_log("info", "equipment UIDs from the host written") == info0 + 2, "another gun: info line")

-- ------------------------------------------------------------ host
print("host: a client's GWEAR on the host's copy of their inventory")
items.reset()
S.role = "host"
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local function PV(e) return { get = function() return e end } end
local function A(list) return { ForEach = function(_, f) for i, e in ipairs(list) do if f(i, PV(e)) == true then break end end end } end
local calls = {}
local function make_jig(name, conts)
  local jig = { __name = name }
  setmetatable(jig, { __index = function(_, k)
    if k ~= "MainJigContainers" then return nil end
    local cl = {}
    for _, c in ipairs(conts) do
      local il = {}
      for _, it in ipairs(c.items) do
        il[#il + 1] = { [F_USID] = G(it.uid), [F_INDEX] = it.idx, [F_SUBS] = A({}),
          [F_INFO] = { [F_COUNT] = 1, [F_ITEMID] = { __name = "DA_" .. it.name }, [F_DUR] = { X = it.dur, Y = 100 } } }
      end
      cl[#cl + 1] = { [F_CONT_UID] = G(c.uid), [F_ITEMS] = A(il) }
    end
    return A(cl)
  end })
  -- BP_JigComponent.ServerFuncUpdateDurabilityByUID @0-1565 (FMax 0; NewDur 0 when not found)
  rawset(jig, "ServerFuncUpdateDurabilityByUID", function(self, gg, minus, destroy, out)
    calls[#calls + 1] = { jig = self.__name, uid = gg.A, minus = minus, destroy = destroy }
    out.NewDur = 0
    for _, c in ipairs(conts) do
      for _, it in ipairs(c.items) do
        if it.uid == gg.A then it.dur = math.max(0, it.dur - minus); out.NewDur = it.dur end
      end
    end
  end)
  return jig
end
local inv = {
  { uid = 1, items = { { uid = 20, name = "MarksmansLegacy", dur = 55.5, idx = 0 }, { uid = 30, name = "Bandage", dur = 100, idx = 1 } } },
  { uid = 2, items = { { uid = 21, name = "MakeshiftMuffler2", dur = 30, idx = 0 } } },
}
local pc = { __name = "PC1", NetConnection = { __name = "Conn1" } }
local pawn = character("Char1", false, pc)
pawn.BP_JigMultiplayer = make_jig("Jig1", inv)
pawn.MedicalComponent = { __name = "Med1", Health = 50 }
local equip = { { "Jig.PlayerSlot.SecondaryWeapon", 20 } }
pawn.BP_JigHelperComp = { __name = "Helper1", RepActorsData = A({}), ServerEquippedItems = {},
  EquipmentUIDs = { ForEach = function(_, f)
    for _, e in ipairs(equip) do if f(PV({ TagName = e[1] }), PV(G(e[2]))) == true then break end end
  end } }
handlers.GWEAR({ "20:0:0:0=1.3000/5;21:0:0:0=0.5000/5" }, pc)
check(#calls == 2 and calls[1].uid == 20 and near(calls[1].minus, 1.3) and calls[1].destroy == false
  and calls[2].uid == 21 and near(calls[2].minus, 0.5), "the game's function per item, summed wear, no destroy")
check(near(inv[1].items[1].dur, 54.2) and near(inv[2].items[1].dur, 29.5), "the host's copy wore")
check(count_log("info", "Char1's MarksmansLegacy worn by 1.300 for 5 shot(s) on the host: 55.50 -> 54.20") == 1,
  "info line with the item and both values")
sent = {}
items.host_tick({ pc })
local it_msg, uid_msg
for _, m in ipairs(sent) do
  if m.kind == "ITEMS" then it_msg = m.args[1] end
  if m.kind == "UIDS" then uid_msg = m.args[1] end
end
check(it_msg and it_msg:find("20:0:0:0=54.2", 1, true) and it_msg:find("21:0:0:0=29.5", 1, true),
  "ITEMS carries the worn values: " .. tostring(it_msg))
check(uid_msg and uid_msg:find("SecondaryWeapon=20:0:0:0@54.20", 1, true), "UIDS too: " .. tostring(uid_msg))

print("host: what is refused")
calls = {}
handlers.GWEAR({ "77:0:0:0=0.2000/1" }, pc)
check(#calls == 1 and count_log("warn", "item 77:0:0:0 is not in their inventory here") == 1, "an unknown item: warned")
handlers.GWEAR({ "77:0:0:0=0.2000/1" }, pc)
check(count_log("warn", "item 77:0:0:0 is not in their inventory here") == 1, "warned once")
calls = {}
handlers.GWEAR({ "20:0:0:0=500.0000/1;x=1/1;21:0:0:0=-1/1" }, pc)
check(#calls == 1 and calls[1].minus == 100, "wear clamped to 100, bad entries refused")
check(wear.stats.host_refused == 2, "two refused")
check(count_log("info", "Char1's MarksmansLegacy is worn out (durability 0)") == 1, "a worn-out gun is logged")
local own_pc = { __name = "HostPC" }
local host_char = character("HostChar", true, own_pc)
host_char.BP_JigMultiplayer = make_jig("HostJig", inv)
calls = {}
handlers.GWEAR({ "21:0:0:0=1.0000/1" }, own_pc)
check(#calls == 0, "not from a remote player: ignored")
cfgv.client_durability_from_host = false
handlers.GWEAR({ "21:0:0:0=1.0000/1" }, pc)
check(#calls == 0, "switched off: ignored")
cfgv.client_durability_from_host = nil
S.role = "client"
handlers.GWEAR({ "21:0:0:0=1.0000/1" }, pc)
check(#calls == 0, "a client ignores GWEAR")
S.role = "host"
for i = 1, 30 do handlers.GWEAR({ "21:0:0:0=0.1000/1" }, pc) end
check(#calls == 30, "every message applied")
check(count_log("debug", "Char1's MakeshiftMuffler2 worn by") + count_log("debug", "Char1's 21:0:0:0 worn by") >= 1,
  "after the first applications the lines go to debug")

for _, l in ipairs(logs) do
  if l:find("^err") then print("  error logged: " .. l); fails = fails + 1 end
end
print(string.format("mock_weapon_wear: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
