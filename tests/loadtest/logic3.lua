-- flashlight item relevancy (host), worn hidden item on the client, backstop timing
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
local world = {}
function ue.find_all(cls) return world[cls] or {} end
function ue.find_object(p) return { __name = p, __cls = "Class", FlashlightIntensity = 5000 } end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.ksl() return nil end
function ue.local_pawn() return ue.__me end
function ue.location(a) return a and a.__loc end
function ue.delay() end
function ue.pawn_of(pc) return pc.__pawn end
package.loaded["sdc_log"] = log
ue.load_asset = ue.load_asset or function(p) return pcall(LoadAsset, p) end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function() end, send_to_host = function() end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
RegisterHook = function() return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() return nil end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end } end

local items = require("sdc_items")
local pawnstate = require("sdc_pawnstate")
local S = { role = "host", remote_pcs = {} }
items.init(S); pawnstate.init(S)

local host = { __name = "HostChar", __cls = "BP_PlayerCharacter_C", Role = 3 }
local fl = { __name = "BP_FlashlightPickup_C_1", __cls = "BP_FlashlightPickup_C", bReplicates = true, NetUpdateFrequency = 30,
    bHidden = true, Role = 3, GetOwner = function() return host end, ForceNetUpdate = function() end,
    GetAttachParentActor = function() return nil end }
host.BP_JigHelperComp = { RepActorsData = arr({ { Slot_4_8843E80049E14A7C56C7E89EF659AAEC = { TagName = "Jig.PlayerSlot.Flashlight" },
    Actor_5_6FDDEF454801C671BE34D7B2377175C5 = fl } }) }
world.BP_PlayerCharacter_C = { host }
items.host_tick({ { __pawn = { __name = "ClientChar" } } })
assert(fl.bNetUseOwnerRelevancy == true, "owner relevancy not set")
assert(fl.bHidden == true, "flashlight unhidden on host")
print("host: flashlight relevant with owner")

-- client: the host's flashlight arrived (simulated, hidden, unattached)
S.role = "client"
host.Role = 1
host.IsLocallyControlled = function() return false end
fl.Role = 1
local physics, coll = true, 1
fl.K2_GetComponentsByClass = function() return { { __name = "Mesh", GetCollisionEnabled = function() return coll end,
    IsSimulatingPhysics = function() return physics end, SetSimulatePhysics = function(_, v) physics = v end,
    SetCollisionEnabled = function(_, v) coll = v end } } end
fl.SetActorHiddenInGame = function(_, v) fl.bHidden = v end
world.BP_StaticMeshPickup_C = { fl }
items.client_tick()
items.client_tick()
assert(fl.bHidden == true, "flashlight unhidden on client")
assert(physics == false and coll == 0, "flashlight not inert on client")
print("client: flashlight hidden and inert")
for _, l in ipairs(logs) do assert(not l:find("OnRep_Flashlight"), "flashlight OnRep re-run") end

-- backstop: item missing -> no direct light before 10 s
local light = { Intensity = 0, SetIntensity = function(self, v) self.Intensity = v end,
    SetAttenuationRadius = function() end, SetLightFunctionMaterial = function() end }
local proxy = { __name = "Proxy", __cls = "BP_PlayerCharacter_C", Role = 1, IsLocallyControlled = function() return false end,
    PlayerState = { GetPlayerId = function() return 9 end }, Flashlight = light,
    FlashlightToggle = function() end, BP_JigHelperComp = { RepActorsData = arr({}) } }
world.BP_PlayerCharacter_C = { proxy }
local handlers = {}
package.loaded["sdc_net"].on = function(k, f) handlers[k] = f end
pawnstate.register_handlers()
handlers.PSTATE({ "9", "fl=1" })
assert(light.Intensity == 0, "direct light before the game's grace time")
print("backstop: waits for the game's path")
for _, l in ipairs(logs) do print("LOG", l) end
print("ALL OK")
