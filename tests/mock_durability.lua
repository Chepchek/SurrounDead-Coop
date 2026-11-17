-- Mock harness: sdc_items' answer to the client's GetDurability (fix_durability) - which source it trusts.
-- 17.11, in the game (self test C.durability): for a WHOLE knife the host says 100, while on the client the game
-- answers 0 and the two sources added on 17.11 read 0.0 too - the item actor's PickupInfo and the struct
-- HelperComp.ServerEquippedItems (no REPL flag in the dump: they are not filled on a client). A 0 from them
-- must be "unknown", never an answer: it used to be a number, 0 is true in Lua, so it closed the way to the
-- host's number and the screen. And the host's number comes first (it is the one the host drains).
-- usage: lua mock_durability.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path
local wire = require("sdc_wire")

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
end

local T = 1000
os.clock = function() return T end

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
function ue.ksl() return nil end
local ME = nil
function ue.local_pawn() return ME end
function ue.delay() return 1 end
function ue.is_runtime_spawned() return false end
function ue.role() return -1 end
function ue.location() return nil end
function ue.hook_native() return true end
function ue.sub_time(_, fn, ...) pcall(fn, ...) return true end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
local handlers = {}
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end, send_to_host = function() end,
  on = function(k, h) handlers[k] = h end, NOW = {} }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (rawget(o, "__name") or tostring(o)) end }
RegisterHook = function() return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end

local F_SLOT = "Slot_4_8843E80049E14A7C56C7E89EF659AAEC"
local F_ACTOR = "Actor_5_6FDDEF454801C671BE34D7B2377175C5"
local F_UP_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_UP_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_UP_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local STRUCT_MELEE = "EquippedMelee_48_0C451F654720DD3648581EA9DB6E85D0"
local TAG = "Jig.PlayerSlot.MeleeWeapon"
local UID = "7:8:9:10"           -- the knife's UID as the game's lookups know it
local function guid() return { A = 7, B = 8, C = 9, D = 10 } end

local items = require("sdc_items")
local consume = package.loaded["sdc_consume"]
items.init({ role = "client", remote_pcs = {} })
items.register_handlers()

-- the client's own character: its helper component and the world's view of its equipped item actor
local view = {}                  -- what the screen shows: [uid] = { slot = { Dur = n } }
consume.client_view = function() return view end
local function new_me(o)
  local helper = { __name = "Helper", ServerEquippedItems = {}, EquipmentUIDs = { Empty = function() end, Add = function() end } }
  if o.struct ~= nil then
    helper.ServerEquippedItems[STRUCT_MELEE] = { [F_UP_DUR] = { X = o.struct, Y = 100 } }
  end
  local actor = { __name = "Knife", BP_JigMultiplayer = { PickupInfo = {
    [F_UP_INFO] = { [F_UP_DUR] = { X = o.actor or 0, Y = 100 } }, [F_UP_USID] = guid() } } }
  helper.RepActorsData = { ForEach = function(_, f)
    local e = { [F_ACTOR] = actor, [F_SLOT] = { TagName = TAG } }
    f(1, { get = function() return e end })
  end }
  return { __name = "Pawn", BP_JigHelperComp = helper, BP_JigMultiplayer = { __name = "Jig" } }
end

-- the game's calls: GetEquipmentUID(slot, out Value) fills the UID, GetDurability(UID, out NewDur) answers
local function equip_uid_call()
  local value = guid()
  items._t.fix_equipment_uid(nil, { get = function() return { TagName = TAG } end },
    { get = function() return value end, set = function(_, v) value = v end })
end
local function get_durability(answer)
  local out = answer or 0
  local p = { get = function() return out end, set = function(_, v) out = v end }
  items._t.fix_durability(nil, { get = function() return guid() end }, p)
  return out
end
local function host_says(n)       -- ITEMS|<uid>=<durability>
  handlers.ITEMS({ wire.uid_enc(UID) .. "=" .. tostring(n) })
end
local function reset_world()
  items.reset()
  items.init({ role = "client", remote_pcs = {} })
  view = {}
  consume.client_view = function() return view end
  logs = {}
  T = T + 100                    -- (past the caches of the screen / actor reads)
end

-- ============================================================ A. the 17.11 game state
print("A. whole knife: the host says 100, the actor and the struct read 0.0 on the client:")
reset_world()
ME = new_me({ struct = 0, actor = 0 })
equip_uid_call()
host_says(100)
check(get_durability(0) == 100, "A1: the host's 100 is the answer (the zeros do not close the way to it)")
check(has_log("fixed to 100.0 from the host") ~= nil, "A1: logged as coming from the host")
check(items.stats.dur_from_slot == 0, "A1: the slot source was not used")
check(items.stats.dur_calls == 1 and items.stats.dur_last == string.format("uid %s: 100 from the host", UID),
  "A1: the diagnostics say what the hook saw: " .. tostring(items.stats.dur_last))
check(has_log("GetDurability call 1 on this client: uid " .. UID .. ": 100 from the host") ~= nil,
  "A1: the first calls are in the log (a real session's log answers whether the hook runs for the game's own swing)")

print("B. the host knows nothing of the item: the screen, then a filled source:")
reset_world()
ME = new_me({ struct = 0, actor = 0 })
equip_uid_call()
view[UID] = { slot = { Dur = 88 } }
check(get_durability(0) == 88, "B1: the struct reads 0.0 (unknown): the screen's 88 is the answer")
check(items.stats.dur_from_ui == 1 and items.stats.dur_from_slot == 0, "B1: counted as the screen's")
reset_world()
ME = new_me({ struct = 61, actor = 0 })
equip_uid_call()
check(get_durability(0) == 61, "B2: a struct that IS filled (above 0) answers when the host and the screen have nothing")
check(items.stats.dur_from_slot == 1, "B2: counted as the slot's")
reset_world()
ME = new_me({ struct = 0, actor = 47 })
equip_uid_call()
check(get_durability(0) == 47, "B3: the item actor's number above 0 answers as the last source")
check(items.stats.dur_restored == 1, "B3: counted as the actor's")

print("C. nothing known anywhere: no answer is made up:")
reset_world()
ME = new_me({ struct = 0, actor = 0 })
equip_uid_call()
check(get_durability(0) == 0, "C1: all zeros and nothing else: the game's own 0 stays")
check(items.stats.dur_no_data == 1, "C1: counted as 'no data'")
check(items.stats.dur_last == string.format("uid %s: nil from the item actor", UID), "C1: the diagnostics: " .. tostring(items.stats.dur_last))

print("D. what the host says is the truth, also a 0:")
reset_world()
ME = new_me({ struct = 80, actor = 80 })
equip_uid_call()
host_says(0)
check(get_durability(0) == 0, "D1: the host says 0 (broken): the filled struct's 80 does not override it")
host_says(40)
check(get_durability(0) == 40, "D2: the host says 40: the struct's 80 does not override it")

print("E. what the game answers itself stays:")
reset_world()
ME = new_me({ struct = 0, actor = 0 })
equip_uid_call()
host_says(100)
local calls0 = items.stats.dur_calls
check(get_durability(55) == 55, "E1: a non-zero answer is not touched")
check(items.stats.dur_calls == calls0 + 1 and items.stats.dur_last:find("is 55", 1, true) ~= nil,
  "E1: the diagnostics: " .. tostring(items.stats.dur_last))
local out0 = 0
items._t.fix_durability(nil, { get = function() return { A = 0, B = 0, C = 0, D = 0 } end },
  { get = function() return out0 end, set = function(_, v) out0 = v end })
check(out0 == 0 and items.stats.dur_last:find("the uid is 0:0:0:0", 1, true) ~= nil, "E2: an empty UID (no item) is left alone")

print("F. the equipment UID hook counts its calls:")
reset_world()
ME = new_me({ struct = 0, actor = 0 })
local n0 = items.stats.equid_calls
equip_uid_call()
check(items.stats.equid_calls == n0 + 1 and items.stats.equid_last == "MeleeWeapon -> " .. UID,
  "F1: the call and the slot / UID are noted: " .. tostring(items.stats.equid_last))

print("")
print(checks .. " checks, " .. fails .. " failed")
os.exit(fails == 0 and 0 or 1)
