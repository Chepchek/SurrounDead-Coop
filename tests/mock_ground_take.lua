-- Mock harness: P0-5 (ground_take, on by default).
-- A client builds from a pickup lying on the ground: the build stands on the
-- host, but the host still has the pickup (one material, two walls). With
-- ground_take on, the client asks the host to take its copy; the host finds a
-- pickup of the same item near the spot and destroys it (or lowers its count).
-- The host must never touch a pickup of another item, a far one, or one that
-- is not in the pickup class whitelist.
-- usage: lua mock_ground_take.lua <scripts dir>
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
local function has_log(pat, level)
  for _, l in ipairs(logs) do
    if (level == nil or l:sub(1, #level + 2) == level .. ": ") and l:find(pat, 1, true) then return l end
  end
  return nil
end

-- ------------------------------------------------------------ fakes
FName = function(s) return s end
local hooks = {}
function RegisterHook(path, fn) hooks[path] = fn; return 1, 2 end
function NotifyOnNewObject() end

local next_addr = 1000
local function obj(cls, name, t)
  t = t or {}
  next_addr = next_addr + 8
  t.__cls, t.__name, t.__addr = cls, name, next_addr
  return t
end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local function P(v)
  local p = { v = v }
  function p.get() return p.v end
  function p.set(_, x) p.v = x end
  return p
end
local function C(o) return { get = function() return o end } end

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.name(o) return ue.valid(o) and (o.__name or "obj") or "" end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return ue.valid(o) and (o.__path or ("/Game/" .. (o.__name or "obj"))) or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if ue.valid(o) then o[n] = v end end
function ue.location(a) return ue.valid(a) and a.__loc or nil end
function ue.role() return 2 end
function ue.is_runtime_spawned() return true end
local world = {}
function ue.find_all(cls)
  local out = {}
  for _, o in ipairs(world) do if o.__cls == cls and rawget(o, "__valid") ~= false then out[#out + 1] = o end end
  return out
end
function ue.find_all_recent(cls) return ue.find_all(cls) end
function ue.watch_new() return true end
function ue.find_object() return nil end
function ue.load_asset() return nil end
function ue.pawn_of(pc) return pc and pc.Pawn end
function ue.role_of() return 1 end
local delayed = {}
function ue.delay(label, ms, fn) delayed[#delayed + 1] = { label = label, ms = ms, fn = fn }; return true end
function ue.run_delayed(label)
  for i = #delayed, 1, -1 do
    if delayed[i].label == label then local d = table.remove(delayed, i); if d.fn then d.fn() end end
  end
end
function ue.sub_time() return true end
function ue.hook_native(path, fn) hooks[path] = fn; return true end
function ue.every_frame() return true end
local LP, LPC = nil, nil
function ue.local_pawn() return LP end
function ue.local_pc() return LPC end
package.loaded["sdc_ue"] = ue

local CFG = { world_build = true, ground_take = true }
package.loaded["sdc_config"] = { get = function(k) local v = CFG[k]; if v == nil then return true end; return v end }

package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and (o.__addr or o.__name) or nil end }
package.loaded["sdc_wire"] = { uid_enc = tostring, uid_dec = tostring }

local handlers, to_host, to_client = {}, {}, {}
package.loaded["sdc_net"] = {
  NOW = {},
  on = function(kind, fn) handlers[kind] = fn end,
  send_to = function(pc, kind, ...) to_client[#to_client + 1] = { pc = pc, kind = kind, ... } end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, ... }; return true end,
  broadcast = function() return true end,
  congested = function() return false end,
}

local world_mod = require("sdc_world")

-- ------------------------------------------------------------ world objects
local DA_WOOD = obj("JigsawItem_DataAsset_C", "DA_WoodWallHalf2")
DA_WOOD.__path = "/Game/Items/DA_WoodWallHalf2.DA_WoodWallHalf2"
local DA_METAL = obj("JigsawItem_DataAsset_C", "DA_MetalSheet")
DA_METAL.__path = "/Game/Items/DA_MetalSheet.DA_MetalSheet"

local function pickup(cls, da, x, y, z, count)
  local p = obj(cls, cls .. "_" .. tostring(next_addr), {
    BP_JigPickupComponent = { ItemDataAsset = da },
    PickupCount = count or 1,
  })
  p.__loc = { X = x, Y = y, Z = z }
  p.K2_DestroyActor = function(self) self.__valid = false; self.__destroyed = true end
  p.SetPickupCount = function(self, n) self.__count_set = n; self.PickupCount = n end
  return p
end

local function new_pc(addr)
  local net = obj("NetConnection", "NetConnection_" .. tostring(addr))
  local ctrl = obj("BP_PlayerController_C", "BP_PlayerController_C_" .. tostring(addr), { NetConnection = net })
  local pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_" .. tostring(addr), { Controller = ctrl })
  local pc = { __addr = addr, Pawn = pawn }
  return pc, pawn
end

local function reset_logs() logs, to_host, to_client = {}, {}, {} end

local function host_state()
  return { role = "host", remote_pcs = {} }
end
local function client_state()
  return { role = "client", remote_pcs = {} }
end

-- ============================================================ A. the key is off
print("A. ground_take off: the host leaves the pickup alone:")
CFG.ground_take = false
reset_logs()
local pc, pawn = new_pc(7001)
local p_wood = pickup("BP_StaticMeshPickup_C", DA_WOOD, 100, 200, 50, 1)
world[#world + 1] = p_wood
world_mod.install(host_state())
world_mod.register_handlers()
check(handlers.GTAKE ~= nil, "GTAKE handler registered")
handlers.GTAKE({ "BP_StaticMeshPickup_C", "100,200,50", DA_WOOD.__path }, pc)
check(p_wood.__destroyed == nil and p_wood.PickupCount == 1, "off: nothing removed")
check(world_mod.stats.ground_taken == 0, "off: ground_taken stays 0")

-- ============================================================ B. the key is on
print("B. ground_take on: the host's pickup goes:")
CFG.ground_take = true
reset_logs()
T = 500
handlers.GTAKE({ "BP_StaticMeshPickup_C", "100,200,50", DA_WOOD.__path }, pc)
check(p_wood.__destroyed == true, "the pickup with that item is destroyed")
check(world_mod.stats.ground_taken == 1, "ground_taken counted")
check(has_log("the host's pickup", "info") ~= nil, "logged as taken")

print("B2. the same request within 0.5 s: throttled")
reset_logs()
local p_wood2 = pickup("BP_StaticMeshPickup_C", DA_WOOD, 100, 200, 50, 1)
world[#world + 1] = p_wood2
T = 500.2
handlers.GTAKE({ "BP_StaticMeshPickup_C", "100,200,50", DA_WOOD.__path }, pc)
check(p_wood2.__destroyed == nil, "second request ignored (throttle)")
T = 501.5
handlers.GTAKE({ "BP_StaticMeshPickup_C", "100,200,50", DA_WOOD.__path }, pc)
check(p_wood2.__destroyed == true, "after the throttle window the request goes through")

print("B3. a stack of 3: one is taken, two stay")
reset_logs()
local p_stack = pickup("BP_StaticMeshPickup_C", DA_WOOD, 120, 200, 50, 3)
world[#world + 1] = p_stack
T = 505
handlers.GTAKE({ "BP_StaticMeshPickup_C", "120,200,50", DA_WOOD.__path }, pc)
check(p_stack.__destroyed == nil and p_stack.__count_set == 2, "count lowered, actor kept")

-- ============================================================ C. no match
print("C. no match: nothing is touched:")
reset_logs()
local p_other = pickup("BP_StaticMeshPickup_C", DA_METAL, 5000, 5000, 50, 1)
local p_far = pickup("BP_StaticMeshPickup_C", DA_WOOD, 6000, 5000, 50, 1)
world[#world + 1] = p_other
world[#world + 1] = p_far
local pc2 = new_pc(7002)
T = 510
handlers.GTAKE({ "BP_StaticMeshPickup_C", "5000,5000,50", DA_WOOD.__path }, pc2)
check(p_other.__destroyed == nil and p_far.__destroyed == nil, "another item / too far: both stay")
check(world_mod.stats.ground_take_miss >= 1, "miss counted")
check(has_log("none with that item near", "debug") ~= nil, "logged as a miss")

print("C2. a non-pickup class / broken coordinates:")
T = 515
local before = world_mod.stats.ground_take_miss
handlers.GTAKE({ "BP_WoodenCrate_C", "100,200,50", DA_WOOD.__path }, pc2)
handlers.GTAKE({ "BP_StaticMeshPickup_C", "abc", DA_WOOD.__path }, pc2)
handlers.GTAKE({ "BP_StaticMeshPickup_C", "100,200,50", "" }, pc2)
check(world_mod.stats.ground_take_miss == before, "ignored before any lookup")

print("C3. a pickup subclass (BP_KnifePickup_C) is taken:")
T = 520
local p_knife = pickup("BP_KnifePickup_C", DA_WOOD, 7000, 7000, 50, 1)
world[#world + 1] = p_knife
local pc3 = new_pc(7003)
local taken0 = world_mod.stats.ground_taken
handlers.GTAKE({ "BP_KnifePickup_C", "7000,7000,50", DA_WOOD.__path }, pc3)
check(p_knife.__destroyed == true and world_mod.stats.ground_taken == taken0 + 1,
  "a subclass name is accepted (the item asset and the spot decide)")

-- ============================================================ D. the client asks
print("D. the client asks after building from a ground pickup:")
CFG.ground_take = true
reset_logs()
local p_ask = pickup("BP_StaticMeshPickup_C", DA_WOOD, 300, 400, 60, 1)
local bc = { PickupRef = p_ask, DARef = DA_WOOD }
local lpawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_own", { BuildingComponent = bc })
LP, LPC = lpawn, { __addr = 7100 }
world_mod.install(client_state())
world_mod.register_handlers()
T = 600
handlers.WBUILT({ "0" })
check(#to_host == 1 and to_host[1].kind == "GTAKE", "GTAKE sent to the host")
check(to_host[1][1] == "BP_StaticMeshPickup_C" and to_host[1][2] == "300,400,60"
  and to_host[1][3] == DA_WOOD.__path, "class, spot and item in the message")
check(world_mod.stats.ground_take_sent == 1, "asked once")
check(has_log("the host's pickup stays", "warn") ~= nil, "the old warning is still there")

print("D2. a second build within 1 s: not asked again")
T = 600.3
handlers.WBUILT({ "0" })
check(world_mod.stats.ground_take_sent == 1, "client throttle holds")

print("D3. moving a building (no pickup) and the key off: no GTAKE")
T = 605
handlers.WBUILT({ "1" })
check(world_mod.stats.ground_take_sent == 1, "no ask without a pickup")
bc.PickupRef = p_ask
CFG.ground_take = false
T = 607
handlers.WBUILT({ "0" })
check(world_mod.stats.ground_take_sent == 1, "no ask with the key off")

-- ============================================================ E. the spot has to be near the sender
-- (the spot in a GTAKE comes from the client: 17.11 review - it was trusted, so a client could name a
-- pickup of that item anywhere; and the 350 cm reach around the spot was never tested)
print("E. the named spot must be near the sender's own character, and the pickup near the spot:")
CFG.ground_take = true
world_mod.install(host_state())        -- (section D left the module in the client role)
world_mod.register_handlers()
reset_logs()
local pcE, pawnE = new_pc(7200)
pawnE.__loc = { X = 10000, Y = 10000, Z = 50 }
local p_near = pickup("BP_StaticMeshPickup_C", DA_WOOD, 10300, 10000, 50, 1)   -- 300 cm from the spot
world[#world + 1] = p_near
T = 700
handlers.GTAKE({ "BP_StaticMeshPickup_C", "10000,10000,50", DA_WOOD.__path }, pcE)
check(p_near.__destroyed == true, "E1: a pickup 300 cm from the named spot is taken (reach 350)")

local p_edge = pickup("BP_StaticMeshPickup_C", DA_WOOD, 10400, 10000, 50, 1)   -- 400 cm: beyond the reach
world[#world + 1] = p_edge
T = 701
handlers.GTAKE({ "BP_StaticMeshPickup_C", "10000,10000,50", DA_WOOD.__path }, pcE)
check(p_edge.__destroyed == nil, "E2: a pickup 400 cm from the named spot stays (reach 350)")

print("E3. a spot far from the sender's character is refused:")
local pcF, pawnF = new_pc(7201)
pawnF.__loc = { X = 20000, Y = 10000, Z = 50 }                                 -- 100 m from the spot it names
local p_named = pickup("BP_StaticMeshPickup_C", DA_WOOD, 10000, 10100, 50, 1)
world[#world + 1] = p_named
reset_logs()
T = 710
local far0, miss0 = world_mod.stats.ground_take_far, world_mod.stats.ground_take_miss
handlers.GTAKE({ "BP_StaticMeshPickup_C", "10000,10100,50", DA_WOOD.__path }, pcF)
check(p_named.__destroyed == nil, "E3: the pickup stays")
check(world_mod.stats.ground_take_far == far0 + 1, "E3: counted as a far ask")
check(world_mod.stats.ground_take_miss == miss0, "E3: refused before any lookup (not a miss)")
check(has_log("from its own character: refused", "warn") ~= nil, "E3: logged as refused")

print("E4. a spot 900 cm from the character (reach 1000) is taken:")
local pcG, pawnG = new_pc(7202)
pawnG.__loc = { X = 10900, Y = 20000, Z = 50 }
local p_g = pickup("BP_StaticMeshPickup_C", DA_WOOD, 10000, 20000, 50, 1)
world[#world + 1] = p_g
T = 720
handlers.GTAKE({ "BP_StaticMeshPickup_C", "10000,20000,50", DA_WOOD.__path }, pcG)
check(p_g.__destroyed == true, "E4: taken")

print("E5. a character whose position cannot be read: the spot stands:")
local pcH = new_pc(7203)                 -- its pawn has no readable location (nothing to compare with)
local p_h = pickup("BP_StaticMeshPickup_C", DA_WOOD, 10000, 30000, 50, 1)
world[#world + 1] = p_h
T = 730
handlers.GTAKE({ "BP_StaticMeshPickup_C", "10000,30000,50", DA_WOOD.__path }, pcH)
check(p_h.__destroyed == true, "E5: taken - the distance check leaves itself out")

print("")
print(checks .. " checks, " .. fails .. " failed")
os.exit(fails == 0 and 0 or 1)
