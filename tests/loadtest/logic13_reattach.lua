-- sdc_items (client): worn items put back where the host has them only when the
-- game's own replicated state says they are worn there; back-off and a limit for
-- put-backs that do not hold; one log line per item and cause
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
local function count_log(pat, kind)
  local n = 0
  for _, l in ipairs(logs) do if l:find(pat, 1, true) and (not kind or l:sub(1, #kind) == kind) then n = n + 1 end end
  return n
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
local world = { BP_PlayerCharacter_C = {}, BP_StaticMeshPickup_C = {}, BP_SkeletalMeshPickup_C = {} }
function ue.find_all(cls) return world[cls] or {} end
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
function ue.delay() end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned(o) return o.__runtime == true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
function ue.hook_native() return true end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end, send_to_host = function() end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
RegisterHook = function() return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end,
  GetArrayNum = function() return #t end } end
local F_SLOT = "Slot_4_8843E80049E14A7C56C7E89EF659AAEC"
local F_ACTOR = "Actor_5_6FDDEF454801C671BE34D7B2377175C5"

local function character(name, role, loc, opts)
  opts = opts or {}
  local equip = {}
  local p = { __name = name, __cls = "BP_PlayerCharacter_C", Role = role, __loc = loc, ["PlayerDead?"] = opts.dead == true,
    IsLocallyControlled = function() return opts.own == true end,
    K2_GetRootComponent = function() return nil end }
  p.BP_JigHelperComp = { RepActorsData = { ForEach = function(_, f)
    for i, e in ipairs(equip) do f(i, { get = function() return { [F_SLOT] = { TagName = e.slot }, [F_ACTOR] = e.actor } end }) end
  end } }
  p.wear = function(a, slot) equip[#equip + 1] = { actor = a, slot = slot } end
  world.BP_PlayerCharacter_C[#world.BP_PlayerCharacter_C + 1] = p
  return p
end

-- an item the host attached to `parent`/`socket`; `holds`: whether a put-back stays
local onrep = {}
local function item(name, parent, socket, opts)
  opts = opts or {}
  local a = { __name = name, __cls = "BP_" .. name .. "Pickup_C", Role = 1, bHidden = false,
    AttachmentReplication = { AttachParent = parent, AttachSocket = socket },
    RootComponent = { IsSimulatingPhysics = function() return opts.physics == true end, RelativeScale3D = { X = 1, Y = 1, Z = 1 } },
    K2_GetComponentsByClass = function() return {} end, cur = nil, cur_socket = "None" }
  a.GetAttachParentActor = function(self) return self.cur end
  a.GetAttachParentSocketName = function(self) return self.cur_socket end
  a.OnRep_AttachmentReplication = function(self)
    onrep[name] = (onrep[name] or 0) + 1
    if opts.holds ~= false then self.cur = parent; self.cur_socket = socket end
  end
  world.BP_StaticMeshPickup_C[#world.BP_StaticMeshPickup_C + 1] = a
  return a
end

local items = require("sdc_items")
local S = { role = "client", remote_pcs = {} }
items.init(S)
items.register_handlers()

local me = character("Me", 2, { X = 0, Y = 0, Z = 0 }, { own = true })
ue.__me = me
local mate = character("Mate", 1, { X = 500, Y = 0, Z = 0 })
local corpse = character("Corpse", 1, { X = 0, Y = 0, Z = 44000 }, { dead = true })
local far = character("FarAway", 1, { X = 56000, Y = 0, Z = 0 })

-- 1. a gap: worn by Mate, detached here, the put-back holds
local helmet = item("Helmet", mate, "Headwear")
mate.wear(helmet, "Jig.PlayerSlot.Headwear")
-- 2. the respirator taken off: the client's copy still names Me, but Me does not wear it
local old_mask = item("HazmatRespirator", me, "Mask")
local new_mask = item("HazmatRespirator2", me, "Mask")
me.wear(new_mask, "Jig.PlayerSlot.Facewear")
new_mask.cur, new_mask.cur_socket = me, "Mask"
-- 3. a dead character's gear
local machete = item("Machete", corpse, "Machete")
corpse.wear(machete, "Jig.PlayerSlot.MeleeWeapon")
-- 4. a player far away
local ar45 = item("AR45", far, "Rifle_Hand")
far.wear(ar45, "Jig.PlayerSlot.PrimaryWeapon")
-- 5. dropped: simulating physics
local backpack = item("Backpack", mate, "backpack", { physics = true })
mate.wear(backpack, "Jig.PlayerSlot.Backpack")
-- 6. worn and alive, but the put-back never holds
local shotgun = item("SawnOffShotgun", mate, "Rifle_Hand", { holds = false })
mate.wear(shotgun, "Jig.PlayerSlot.PrimaryWeapon")

for _ = 1, 60 do
  items.client_tick()
  offset = offset + 1
end

-- 1
assert(onrep.Helmet == 1 and helmet.cur == mate, "gap not closed once")
assert(count_log("Helmet put back on Mate/Headwear (was <none>/None, try 1)", "info") == 1, "put-back log")
-- 2
assert(not onrep.HazmatRespirator and not onrep.HazmatRespirator2, "unworn respirator put back")
assert(count_log("HazmatRespirator not put back on Me/Mask (now <none>/None): not in the equipment of Me (unequipped / dropped on the host)", "info") == 1, "unworn log once")
-- 3
assert(not onrep.Machete and count_log("Machete not put back on Corpse/Machete", "info") == 1 and count_log("Corpse is dead") == 1, "dead wearer")
-- 4
assert(not onrep.AR45 and count_log("FarAway is out of range") == 1, "far wearer")
-- 5
assert(not onrep.Backpack and count_log("dropped (simulating physics)") == 1, "dropped item")
-- 6: tries at 0, 1, 3, 7, 15 s, then given up for good
assert(onrep.SawnOffShotgun == 5, "put-backs that do not hold: " .. tostring(onrep.SawnOffShotgun))
assert(count_log("SawnOffShotgun put back on Mate/Rifle_Hand (was <none>/None, try 1)", "info") == 1, "first try at info")
assert(count_log("SawnOffShotgun does not stay on Mate/Rifle_Hand (5 put-backs, now <none>/None) - left as the game has it", "info") == 1, "give-up once")
-- no line per second: in 60 ticks, a handful of info lines about attachments
local lines = 0
for _, l in ipairs(logs) do if l:find("put back", 1, true) or l:find("does not stay", 1, true) then lines = lines + 1 end end
assert(lines <= 12, "too many lines: " .. lines)
print("client: gap closed once; unequipped / dead / far / dropped left alone; 5 tries then given up; " .. lines .. " lines in 60 s")

-- the mate equips the shotgun again (a new attach target): tried again
shotgun.AttachmentReplication = { AttachParent = mate, AttachSocket = "PrimaryWeaponBackpack" }
items.client_tick()
assert(onrep.SawnOffShotgun == 6, "a new target is not tried")
-- a reset (new session) forgets everything
items.reset()
for _, l in ipairs(logs) do if l:find("^err") then error("error logged: " .. l) end end
print("ALL OK")
