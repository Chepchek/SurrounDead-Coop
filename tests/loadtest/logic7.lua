-- sdc_tools: binoculars slot + night vision battery for clients
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
local cleared = {}
function ue.ksl() return { K2_ClearTimer = function(_, o, n) cleared[#cleared + 1] = n end } end
function ue.local_pawn() return ue.__me end
function ue.delay() end
function ue.pawn_of(pc) return pc.__pawn end
function ue.is_runtime_spawned() return true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and a.__loc end
local sent_host, sent_client, handlers = {}, {}, {}
package.loaded["sdc_log"] = log
ue.load_asset = ue.load_asset or function(p) return pcall(LoadAsset, p) end
-- (0.7.3: a client takes the binoculars item only from memory)
ue.loaded_asset = ue.loaded_asset or function(p) return ue.find_object(p) end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
package.loaded["sdc_net"] = { send_to = function(pc, kind, ...) sent_client[#sent_client + 1] = { pc, kind, ... } end,
  broadcast = function() end, send_to_host = function(kind, ...) sent_host[#sent_host + 1] = { kind, ... } end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (o.__name or tostring(o)) end }
local hooks = {}
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
NotifyOnNewObject = function() end
FName = function(s) return s end
LoadAsset = function() end
local function arr(t) return { ForEach = function(_, f) for i, e in ipairs(t) do f(i, { get = function() return e end }) end end } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local BINO = "EquippedBinoculars_57_FA37337F42E4A60116D21485F6D57AB7"
local IID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local function item(uid, idx, sub, dur)
  return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = G(uid), InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE = idx,
    SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE = arr(sub and { { UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7 = G(sub) } } or {}),
    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Durability_22_A3557C454274D193D47AB9B71FB0C0CA = { X = dur } } }
end
local function cont(uid, items) return { ReplicationUID_23_EB27D09649B6E02591DCA98708B06332 = G(uid), ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = arr(items) } end

local items = require("sdc_items")
local S = { role = "host", remote_pcs = {} }
items.init(S)
items.register_handlers()
assert(handlers.PTOOLS and handlers.MYNVG, "handlers missing")

-- ---------------------------------------------------------------- host
local bino = { __name = "DA_Binoculars", __path = "/Game/I/DA_Binoculars.DA_Binoculars" }
local pc = { __name = "PC_dag", NetConnection = { __name = "conn" } }
local guest = { __name = "guest", __cls = "BP_PlayerCharacter_C", Controller = pc }
pc.__pawn = guest
guest.BP_JigHelperComp = { __name = "H", ServerEquippedItems = { [BINO] = { [IID] = bino } },
  EquipmentUIDs = { ForEach = function(_, f) f({ get = function() return { TagName = "Jig.PlayerSlot.Headwear" } end },
    { get = function() return G(100) end }) end } }
local battery = 40
local drains = {}
guest.BP_JigMultiplayer = setmetatable({ __name = "GuestJig",
  ServerFuncUpdateDurabilityByUID = function(_, g, minus, destroy, out)
    drains[#drains + 1] = { a = g.A, minus = minus }; battery = math.max(0, battery - minus); out.NewDur = battery
  end }, { __index = function(_, k)
    if k == "MainJigContainers" then
      return arr({ cont(1, { item(100, 0, 200, 90) }),            -- helmet in the head slot container
                   cont(200, { item(300, 0, 400, 80) }),          -- helmet sub-container: the NVG at index 0
                   cont(400, { item(500, 0, nil, battery) }) })   -- NVG sub-container: the battery
    end end })
items.host_tick({ pc })
local last
for _, m in ipairs(sent_client) do if m[2] == "PTOOLS" then last = m end end
assert(last and last[2] == "PTOOLS" and last[3] == bino.__path and last[4] == "40.00", "PTOOLS wrong: " .. tostring(last and last[4]))
handlers.MYNVG({ "1" }, pc)
local real_clock = os.clock
local offset = 0
os.clock = function() return real_clock() + offset end
offset = 1
items.host_tick({ pc })
assert(#drains == 1 and drains[1].a == 500 and drains[1].minus > 0.1 and drains[1].minus < 0.2, "battery not drained")
handlers.MYNVG({ "0" }, pc)
offset = 2
items.host_tick({ pc })
assert(#drains == 1, "drained while off")
print("host: binoculars slot + NVG charge sent, battery drained while on")

-- ---------------------------------------------------------------- client
S.role = "client"
logs = {}
items.reset()
assets[bino.__path] = bino
local me = { __name = "Me", __cls = "BP_PlayerCharacter_C", IsLocallyControlled = function() return true end,
  BP_JigHelperComp = { __name = "MyH", ServerEquippedItems = { [BINO] = { [IID] = nil } } } }
local hud_dur
me.InGameUI = { __name = "HUD", GetNightVisionDurability = function(_, d) hud_dur = d end }
local offs = 0
me.NightVisionOn = function(_, on) if not on then offs = offs + 1; me["PlayerUsingNightVision?"] = false end end
me.BP_JigMultiplayer = { __name = "MyJig", LocalJSIContainers = arr({}) }
ue.__me = me
items.client_tick()
handlers.PTOOLS({ bino.__path, "40.00" })
items.client_tick()
assert(me.BP_JigHelperComp.ServerEquippedItems[BINO][IID] == bino, "binoculars slot not written")
assert(has_log("own binoculars slot set from the host: empty -> DA_Binoculars"), "slot log")
-- the game's battery check answers no here; the host has 40 -> yes
local PFN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local okp = P(false)
hooks[PFN .. "NightVisionBatteryCheck"](C(me), okp)
assert(okp.v == true, "NVG check not answered yes")
me["PlayerUsingNightVision?"] = true
hooks[PFN .. "NightVisionOn"](C(me), P(true))
assert(sent_host[#sent_host][1] == "MYNVG" and sent_host[#sent_host][2] == "1", "MYNVG not sent")
items.client_tick()
assert(hud_dur == 40, "HUD charge not set")
-- the host's battery runs out: off
handlers.PTOOLS({ bino.__path, "0.00" })
items.client_tick()
assert(offs == 1 and cleared[1] == "NightVisionCheck", "NVG not switched off")
-- no battery at all: the check stays no
local okp2 = P(false)
handlers.PTOOLS({ "", "-1" })
hooks[PFN .. "NightVisionBatteryCheck"](C(me), okp2)
assert(okp2.v == false, "NVG check said yes without a battery")
items.client_tick()
assert(me.BP_JigHelperComp.ServerEquippedItems[BINO][IID] == nil, "binoculars slot not cleared")
print("client: binoculars slot written and cleared, NVG check / HUD / off follow the host")
for _, l in ipairs(logs) do if l:find("^err") and l:find("tools:", 1, true) then error("error logged: " .. l) end end
print("ALL OK")
