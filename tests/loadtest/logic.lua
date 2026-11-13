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
local ue = {}
ue.ROLE_SIMULATED, ue.ROLE_AUTONOMOUS, ue.ROLE_AUTHORITY = 1, 2, 3
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.name(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return o.__path or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.call(o, f, ...) return pcall(o[f], o, ...) end
function ue.find_all() return {} end
function ue.find_object(p) return { __name = p, __cls = "Class" } end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.ksl() return { IsStandalone = function() return false end, IsServer = function(_, o) return o.__server == true end } end
function ue.local_pawn() return ue.__me end
function ue.location(a) return a and a.__loc end
function ue.delay(label) logs[#logs + 1] = "delay " .. label end
function ue.pawn_of(pc) return pc.__pawn end
local cfgv = { replicate_items = true, prevent_client_loot = true }
package.loaded["sdc_log"] = log
ue.load_asset = ue.load_asset or function(p) return pcall(LoadAsset, p) end
-- sdc_ue.hook_native (0.6.39): one shared engine hook; here a plain RegisterHook
ue.hook_native = ue.hook_native or function(path, _, fn) return pcall(RegisterHook, path, fn) end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function(k) return cfgv[k] end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end, send_to_host = function() end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, pre) hooks[path] = pre; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
local function P(v) return { get = function() return v end, set = function(_, x) v = x end, val = function() return v end } end

local items = require("sdc_items")
local gearfx = require("sdc_gearfx")
local pawnstate = require("sdc_pawnstate")
local S = { role = "host", remote_pcs = {} }
items.init(S); gearfx.init(S); pawnstate.init(S)
items.install()

-- drop flow (host)
items.host_tick({})
local zpath = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:JigMP_OnRequestDropItem"
assert(hooks[zpath], "zombie hook missing")
local drop = hooks["/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestDropItem"]
assert(drop, "drop hook missing")
local moved_to
local pickup = { __name = "BP_Pickup_1", __cls = "BP_StaticMeshPickup_C", __loc = { X = 0, Y = 0, Z = 0 },
    K2_SetActorLocation = function(_, spot) moved_to = spot end, ForceNetUpdate = function() end }
local zombie = { __name = "Zombie_1", __cls = "BP_MasterZombie_C" }
local pc = { __name = "PC_2", NetConnection = { __name = "conn" } }
local client_char = { __name = "BP_PlayerCharacter_C_2", __cls = "BP_PlayerCharacter_C", Controller = pc,
    __loc = { X = 1000, Y = 0, Z = 100 } }
local client_comp = { __name = "JigComp", GetOwner = function() return client_char end }
local zcomp = { __name = "ZComp", GetOwner = function() return zombie end }
hooks[zpath](P(zombie), P(nil), P("None"), P(pickup))
drop(P(client_comp), P(nil), P(1), P(zcomp))
assert(moved_to and math.abs(moved_to.X - 1000) <= 40, "pickup not moved to the client")
print("drop: moved to", moved_to.X, moved_to.Y, moved_to.Z)
-- host's own drop out of a container: not moved
moved_to = nil
local host_char = { __name = "Host", __cls = "BP_PlayerCharacter_C", Controller = { __name = "HPC" }, __loc = { X = 0, Y = 0, Z = 0 } }
hooks[zpath](P(zombie), P(nil), P("None"), P(pickup))
drop(P({ GetOwner = function() return host_char end }), P(nil), P(1), P(zcomp))
assert(moved_to == nil, "host drop moved")
-- own inventory drop: no fallback
local nlogs = #logs
drop(P(client_comp), P(nil), P(1), P({ GetOwner = function() return client_char end }))
for i = nlogs + 1, #logs do assert(not logs[i]:find("delay"), "fallback for own drop") end
-- unknown container: fallback scheduled
drop(P(client_comp), P(nil), P(1), P({ GetOwner = function() return { __name = "Crate", __cls = "BP_SomeCrate_C" } end }))
local saw = false
for i = nlogs + 1, #logs do if logs[i]:find("delay drop%-move") then saw = true end end
assert(saw, "fallback not scheduled")
print("drop: ok")

-- battery (client)
S.role = "client"
items.client_tick()
local check = hooks["/Game/Blueprints/Components/BatteryComponent.BatteryComponent_C:CheckBatteryLevel"]
local use = hooks["/Game/Blueprints/Components/BatteryComponent.BatteryComponent_C:UseBattery"]
local other = { __name = "BP_PlayerCharacter_C_3", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return false end }
local weapon = { __name = "Gun", __cls = "BP_FirearmPickup_C", GetOwner = function() return other end }
local module = { __name = "Light", __cls = "BP_TacticalLightLocalAttachment_C", GetOwner = function() return weapon end }
local bcomp = { __name = "Battery", GetOwner = function() return module end }
local okp, valp = P(false), P(0)
check(P(bcomp), P(nil), P({ A = 1, B = 2, C = 3, D = 4 }), okp, valp)
assert(okp.val() == true and valp.val() == 100.0, "proxy battery check not answered")
local nd, sp = P(0), P(false)
use(P(bcomp), P(nil), P({ A = 1, B = 2, C = 3, D = 4 }), P(0.01), nd, sp)
assert(sp.val() == true and nd.val() == 100.0, "proxy battery use not answered")
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end }
local mylight = { __name = "MyLight", GetOwner = function() return me end }
local okp2 = P(false)
check(P({ GetOwner = function() return mylight end }), P(nil), P({ A = 1, B = 2, C = 3, D = 4 }), okp2, P(0))
assert(okp2.val() == false, "own battery wrongly answered")
print("battery: ok")

-- loot block (client)
local spawn = hooks["/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"]
local clsp = P({ __name = "BP_Item_C" })
spawn(P({}), P({ __name = "Spawner_1", __cls = "BP_JigRandomSpawner_C", __server = false }), clsp)
assert(clsp.val().__name == "/Script/CoreUObject.Object", "loot class not swapped")
local clsp2 = P({ __name = "BP_Item_C" })
spawn(P({}), P({ __name = "Other", __cls = "BP_Zombie_C" }), clsp2)
assert(clsp2.val().__name == "BP_Item_C", "non-spawner swapped")
local clsp3 = P({ __name = "BP_Item_C" })
spawn(P({}), P({ __name = "Sp", __cls = "BP_JigRandomSpawner_Tutorial_C", __server = true }), clsp3)
assert(clsp3.val().__name == "BP_Item_C", "server spawner swapped")
cfgv.prevent_client_loot = false
local clsp4 = P({ __name = "BP_Item_C" })
spawn(P({}), P({ __name = "Spawner_2", __cls = "BP_JigRandomSpawner_C", __server = false }), clsp4)
assert(clsp4.val().__name == "BP_Item_C", "config off but swapped")
print("loot: ok")

-- events (client): hotbar on own helper
local painted
me.Role = 2
ue.__me = me
me.BP_JigHelperComp = { ActiveWeapon = { TagName = "Jig.PlayerSlot.MeleeWeapon" } }
me.InGameUI = { __name = "HUD" }
me.ActionBarEquipUI = function(_, none, tag) painted = tag.TagName end
local helper = { __name = "Helper", GetOwner = function() return me end }
hooks["/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C:OnRep_ActiveWeapon"](P(helper))
assert(painted == "Jig.PlayerSlot.MeleeWeapon", "hotbar not repainted on event")
print("hotbar: ok")

-- host module state (a client connected: sdc_gearfx waits for one)
S.role = "host"
S.remote_pcs = { { __name = "ClientPC" } }
gearfx.host_tick()
local hs = hooks["/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C:SERVER_UpdateAttachmentState"]
local processed = 0
local wcomp = { __name = "PickupComp", GetOwner = function() return weapon end, ProcessAttachments = function() processed = processed + 1 end }
hs(P(wcomp), P({}), P({ TagName = "Jig.AttachmentActivate.State2" }))
assert(processed == 1, "ProcessAttachments not called")
print("host state: ok")

for _, l in ipairs(logs) do print("LOG", l) end
print("ALL OK")
