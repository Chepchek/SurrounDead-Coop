-- Critic fix D / A2 (2026-11-13): wood, stone and scrap from world objects.
-- sdc_world has the host grant them to the harvesting player; the client's
-- own single-player add (JigTryAddItemSomewhere) must not also ask for them
-- (IGAIN), or a nearby item use lets the host add them a second time.
-- The exclusion compared ue.name(da) (the FULL name, "JigsawItem_DataAsset_C
-- /Game/...DA_WoodenLog.DA_WoodenLog") with "DA_WoodenLog": it never matched.
-- This stub's ue.name gives the full name, as UE4SS does.
-- usage: lua mock_fix_d_resource.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local logs = {}
local log = setmetatable({ debug_enabled = false, probes_enabled = false }, { __index = function(_, k)
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

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.missing(v) return v == nil end
function ue.str(v) if v == nil then return "" end return tostring(v) end
-- FName (short) vs full name, as UE4SS: GetFName():ToString() / GetFullName()
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o)
  if not ue.valid(o) then return "<none>" end
  return (o.__cls or "Object") .. " " .. (o.__path or ("/Game/X." .. (o.__name or "obj")))
end
function ue.path(o) return o.__path end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.find_all() return {} end
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
function ue.delay() end
function ue.every() end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
local sent = {}
local cfgv = {}
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function(k) local v = cfgv[k]; if v == nil then return true end return v end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end,
  send_to_host = function(kind, ...) sent[#sent + 1] = { kind, ... } end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end

local consume = require("sdc_consume")
local S = { role = "client", remote_pcs = {} }
consume.init(S)
consume.client_tick()
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local add = hooks[JIG .. "JigTryAddItemSomewhere"]
check(add ~= nil, "client: JigTryAddItemSomewhere hooked")
if not add then
  print(checks .. " checks, " .. fails .. " FAILED")
  os.exit(1)
end

local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
ue.__me = me
local mycomp = { __name = "MyJig", GetOwner = function() return me end }
me.BP_JigMultiplayer = mycomp

local DIR = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/"
local function da(short)
  return { __name = short, __cls = "JigsawItem_DataAsset_C", __path = DIR .. short .. "." .. short }
end

-- the game's own add of a harvest on this client: no IGAIN
for _, short in ipairs({ "DA_WoodenLog", "DA_Rock", "DA_ScrapMetal" }) do
  local n0 = #sent
  add(C(mycomp), P(mycomp), P(da(short)), P(3), P(false), P(G(0)))
  check(#sent == n0, "client: " .. short .. " x3 from a world object: no IGAIN (the host grants it)")
end
check(has_log("from a world object: the host grants it") ~= nil, "client: harvest logged as the host's grant")

-- an item a use gave (a torn shirt's cloth): asked for as before
local n1 = #sent
local cloth = da("DA_Cloth")
add(C(mycomp), P(mycomp), P(cloth), P(2), P(false), P(G(0)))
check(#sent == n1 + 1 and sent[#sent][1] == "IGAIN" and sent[#sent][2] == cloth.__path and sent[#sent][3] == 2,
  "client: DA_Cloth x2 from using an item: IGAIN sent")

-- world_harvest off (sdc_world grants nothing): the resource is asked for
cfgv.world_harvest = false
local n2 = #sent
local wood = da("DA_WoodenLog")
add(C(mycomp), P(mycomp), P(wood), P(1), P(false), P(G(0)))
check(#sent == n2 + 1 and sent[#sent][1] == "IGAIN" and sent[#sent][2] == wood.__path,
  "client: world_harvest off: DA_WoodenLog asked for (IGAIN)")
cfgv.world_harvest = nil

local bad = 0
for _, l in ipairs(logs) do if l:find("^err") then print("    " .. l); bad = bad + 1 end end
check(bad == 0, "no hook errors")

if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
