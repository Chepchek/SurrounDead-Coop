-- pawnstate flashlight backstop + appearance dress, with fake objects
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
local all = {}
function ue.find_all() return all end
function ue.player_chars() return all end
function ue.find_object(p) return nil end
function ue.role(a) return a and a.Role or -1 end
function ue.local_pawn() return ue.__me end
function ue.local_pc() return ue.__pc end
function ue.rotation(a) return a and a.__rot end
function ue.location(a) return a and a.__loc end
function ue.pawn_of(pc) return pc.__pawn end
package.loaded["sdc_log"] = log
ue.load_asset = ue.load_asset or function(p) return pcall(LoadAsset, p) end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
local sent = {}
package.loaded["sdc_net"] = { send_to = function() end, broadcast = function(_, kind, id, s) sent[#sent + 1] = kind .. " " .. tostring(s) end,
    send_to_host = function(kind, s) sent[#sent + 1] = kind .. " " .. tostring(s) end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, pre) hooks[path] = pre; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() return nil end

local appearance = require("sdc_appearance")
local pawnstate = require("sdc_pawnstate")
local S = { role = "client", remote_pcs = {} }
appearance.init(S); pawnstate.init(S)

-- a proxy with a torso item and an unlit flashlight
local DA = { __name = "DA_Shirt", ClothingSettings = {
    MaleMesh_55_C39419A54F846168C8ACC7B8047249B8 = { __name = "SK_Shirt_M", __path = "/Game/M" },
    FemaleMesh_56_759E5B484609B6B259ECB5ACB9BFA58A = { __name = "SK_Shirt_F", __path = "/Game/F" },
    BodyPartSettings_60_19AFB636484813B2DE1483A03355E921 = {} } }
local entries = { { Slot_4_8843E80049E14A7C56C7E89EF659AAEC = { TagName = "Jig.PlayerSlot.Torso" },
                    DA_7_6FDDEF454801C671BE34D7B2377175C5 = DA } }
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end } end
local attached
local torso = { __name = "Clothing_Torso" }
local light = { __name = "Flashlight", Intensity = 0 }
local toggled
local proxy = { __name = "Proxy", __cls = "BP_PlayerCharacter_C", Role = 1,
    IsLocallyControlled = function() return false end,
    PlayerState = { GetPlayerId = function() return 7 end },
    BP_JigHelperComp = { RepPrimitiveActorsData = arr(entries) },
    Clothing_Torso = torso, ["ClothingTorsoEquipped?"] = true, ["IsPlayerMale?"] = false,
    ["ClothingLegsEquipped?"] = false,
    MC_AttachClothing = function(_, comp, mesh) attached = mesh.__name; comp.SkeletalMeshAsset = mesh end,
    Flashlight = light,
    FlashlightToggle = function(_, on) toggled = on; light.Intensity = on and 5000 or 0 end }
all = { proxy }

-- clothing OnRep event: dress with the female mesh
appearance.tick()
local onrep = hooks["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:OnRep_ClothingTorsoEquipped?"]
assert(onrep, "clothing hook missing")
torso.SkeletalMeshAsset = nil       -- the game's OnRep undressed it
onrep({ get = function() return proxy end })
assert(attached == "SK_Shirt_F", "not dressed on event: " .. tostring(attached))
print("dress: ok")

-- flashlight backstop: PSTATE says lit, the copy is dark -> FlashlightToggle(true)
local handlers = {}
package.loaded["sdc_net"].on = function(k, f) handlers[k] = f end
pawnstate.register_handlers()
handlers.PSTATE({ "7", "fl=1;hf=0;hm=0;sp=0;cs=0;hip=0;ln=0.00;bs=0;hy=0" })
assert(toggled == true and proxy["FlashlightOn?"] == true, "backstop did not toggle")
toggled = nil
pawnstate.tick()
assert(toggled == nil, "toggled again although lit")
print("flashlight: ok")

-- own state string: no cp/cy, fl from the light
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", Role = 2, IsLocallyControlled = function() return true end,
    PlayerState = { GetPlayerId = function() return 1 end }, Flashlight = { Intensity = 3 }, Lean = 0,
    __rot = { Yaw = 10 } }
ue.__me = me
ue.__pc = { GetControlRotation = function() return { Pitch = 5, Yaw = 30 } end }
pawnstate.fast_tick()
print("published:", sent[#sent])
assert(sent[#sent]:find("fl=1") and not sent[#sent]:find("cp=") and sent[#sent]:find("hy="), "own state wrong")
for _, l in ipairs(logs) do print("LOG", l) end
print("ALL OK")
