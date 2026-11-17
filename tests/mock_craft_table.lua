-- Mock harness: the recipe table a client's crafting window names (sdc_stations, STABLE).
-- Bug (user, host): "I open the workbench, and to craft a cartridge it shows the bandage recipe
-- (rag + antiseptic)". The weapons workbench (Buildable_WeaponsEquipmentWorkbench) opens the SAME
-- window class as the crafting workbench (W_CraftingWorkbenchUI) but its code calls
-- SetItemsToCraft(3, ...) (24 recipes: cartridges...), the crafting workbench SetItemsToCraft(1, ...)
-- (15 recipes: bandage...). The client named the table by window class -> 1, and the host ran
-- SetItemsToCraft(1) on the weapons workbench's component ("were 24" -> "15 recipes" in the logs),
-- so the host's own window read CraftIndex -> the crafting workbench's list.
-- usage: lua mock_craft_table.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local T = 500
os.clock = function() return T end

package.loaded["sdc_log"] = setmetatable({ debug_enabled = true, TEXT = {} }, { __index = function() return function() end end })
FName = function(s) return { _s = s } end
function RegisterHook() return 1, 2 end
function NotifyOnNewObject() end

local next_addr = 1000
local function obj(cls, name, t)
  t = t or {}
  next_addr = next_addr + 8
  t.__cls, t.__name, t.__addr = cls, name, next_addr
  return t
end

-- the game's recipe tables: 1 = crafting workbench (15), 3 = weapons workbench (24)
local COUNT_OF = { [1] = 15, [3] = 24 }
local function arr(n) return { GetArrayNum = function() return n end } end
local gfl = obj("GameFunctionLibrary_C", "Default__GameFunctionLibrary_C")
gfl.SetItemsToCraft = function(_, t, comp, _) comp.table = t; comp.ItemsToCraft = arr(COUNT_OF[t] or 0) end

local function new_station(cls, name, at)
  local comp = obj("BP_JigComponent_C", "BP_JigMultiplayer")
  local st = obj(cls, name, { BP_JigMultiplayer = comp, __loc = at })
  comp.__owner = st
  comp.GetOwner = function(self) return self.__owner end
  return st, comp
end

local world, by_path = {}, {}
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return "/Game/" .. ue.short(o) end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.location(a) return a and a.__loc end
function ue.find_all(cls)
  local out = {}
  for _, o in ipairs(world) do if o.__cls == cls then out[#out + 1] = o end end
  return out
end
ue.find_all_recent = ue.find_all
function ue.watch_new() return true end
function ue.find_object(p)
  if p == "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C" then return gfl end
  return by_path[p]
end
function ue.pawn_of(p) return p and p.Pawn end
function ue.role() return 2 end
function ue.is_runtime_spawned() return false end
function ue.delay() return true end
package.loaded["sdc_ue"] = ue

package.loaded["sdc_config"] = { get = function() return nil end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__addr or nil end }
local handlers, to_host = {}, {}
package.loaded["sdc_net"] = {
  on = function(kind, fn) handlers[kind] = fn end,
  send_to = function() return true end,
  broadcast = function() end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, args = { ... } }; return true end,
}
package.loaded["sdc_notes"] = { show_to = function() end }

local S = { role = "client", remote_pcs = {} }
local containers = require("sdc_containers")
local stations = require("sdc_stations")
containers.init(S)
stations.init(S)
stations.register_handlers()

local function window(cls, st)
  local _, comp = st, st.BP_JigMultiplayer
  return obj(cls, cls .. "_1", { MPComponent = comp })
end

-- ============================================================ 1. the client names the table
print("-- 1: the table a client's window names")
local weapons, wcomp = new_station("Buildable_WeaponsEquipmentWorkbench_C", "Buildable_WeaponsEquipmentWorkbench_C_5", { X = 0, Y = 0, Z = 0 })
local crafting = new_station("Buildable_CraftingWorkbench_C", "Buildable_CraftingWorkbench_C_6", { X = 5000, Y = 0, Z = 0 })
local cooking = new_station("Buildable_Campfire_C", "Buildable_Campfire_C_7", { X = 9000, Y = 0, Z = 0 })
local function sent_table(w)
  T = T + 10
  to_host = {}
  stations.client_craft_check(w)
  local m = to_host[1]
  return m and m.kind == "STABLE" and m.args[1] or nil
end
check(sent_table(window("W_CraftingWorkbenchUI_C", weapons)) == 3, "weapons workbench window -> table 3 (cartridges)")
check(sent_table(window("W_CraftingWorkbenchUI_C", crafting)) == 1, "crafting workbench window -> table 1")
check(sent_table(window("W_CookingUI_C", cooking)) == 2, "campfire window -> table 2")

-- ============================================================ 2. the host runs it
print("-- 2: the host sets the table on the weapons workbench")
S.role = "host"
local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_7", { NetConnection = obj("NetConnection", "IpConnection_1") })
local pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Controller = pc, __loc = { X = 100, Y = 0, Z = 0 } })
pc.Pawn = pawn
by_path[ue.path(weapons)] = weapons
world[#world + 1] = weapons
gfl.SetItemsToCraft(gfl, 3, wcomp, weapons)   -- the host's own open: the weapons list
check(wcomp.ItemsToCraft:GetArrayNum() == 24, "the host's copy holds the weapons list (24 recipes)")
-- an old-style message (what the buggy client sent): table 1 for the weapons workbench
handlers.STABLE({ "1", ue.path(weapons), "Buildable_WeaponsEquipmentWorkbench_C", "0", "0", "0" }, pc)
check(wcomp.table == 3 and wcomp.ItemsToCraft:GetArrayNum() == 24, "host: the weapons workbench keeps table 3 whatever the message says")
handlers.STABLE({ "3", ue.path(weapons), "Buildable_WeaponsEquipmentWorkbench_C", "0", "0", "0" }, pc)
check(wcomp.table == 3, "host: table 3 from the message is set")

print(string.format("%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
