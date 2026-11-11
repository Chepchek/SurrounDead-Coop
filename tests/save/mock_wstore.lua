-- Mock: the WSTORE part of the patched sdc_world (storage-container mark).
-- usage: lua mock_wstore.lua <patched dir> <scripts dir>
package.path = arg[1] .. "/?.lua;" .. arg[2] .. "/?.lua;" .. package.path
local fails = 0
local function check(c, what) if c then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end end

local sent = {}
package.preload["sdc_net"] = function()
    return {
        on = function() end,
        send_to_host = function(kind, ...) sent[#sent + 1] = { "host", kind, ... }; return true end,
        broadcast = function(_, kind, ...) sent[#sent + 1] = { "all", kind, ... } end,
        send_to = function(pc, kind, ...) sent[#sent + 1] = { pc._name, kind, ... } end,
    }
end
package.preload["sdc_ctx"] = function()
    return { addr = function(o) return o and o._name end, SCOPE_API = 1 }
end
StaticFindObject = function() return nil end
FindAllOf = function() return nil end
RegisterHook = function() return 1, 2 end

local Obj = {}
Obj.__index = function(t, k) return rawget(Obj, k) or rawget(t, "_p")[k] end
local function new(name, props)
    return setmetatable({ _name = name, _p = props or {} }, Obj)
end
function Obj:IsValid() return true end
function Obj:GetFullName() return "BP_LootContainer_C /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._name end
function Obj:GetFName() return { ToString = function() return self._name end } end
function Obj:GetClass() return { GetFName = function() return { ToString = function() return "BP_LootContainer_C" end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end

local ue = require("sdc_ue")
local cvar = true
ue.ksl = function() return { GetConsoleVariableBoolValue = function() return cvar end } end
local log = require("sdc_log")
log.info = function(m, ...) print("    log: " .. string.format(m, ...)) end
local world = require("sdc_world")
local t = world._t

local comp = new("jig", { ["DoesContainerRefillLoot?"] = true })
local box = new("Container_Cupboard_C_7", { ContainerLooted = true, MarkedAsStorageContainer = false, BP_JigMultiplayer = comp })
local paths = { ["/Game/Levels/LongdownValley.LongdownValley:PersistentLevel.Container_Cupboard_C_7"] = box }
StaticFindObject = function(p) return paths[p] end
local function prm(v) return { get = function() return v end } end
local opt2 = prm({ TagName = { ToString = function() return "Jig.InteractOptions.Option2" end } })
local opt1 = prm({ TagName = { ToString = function() return "Jig.InteractOptions.Option1" end } })

print("client marks a container as storage")
local client_pc = new("PC_client")
local S = { role = "client", client = { acked = true }, remote_pcs = {} }
t.set_state(S)
box._p.MarkedAsStorageContainer = true   -- the option ran here (toggle) before the post-hook
t.on_interact_container(prm(box), prm(nil), opt2)
check(#sent == 1 and sent[1][1] == "host" and sent[1][2] == "WSTORE" and sent[1][4] == "1", "client -> host WSTORE ...|1")
check(sent[1][3] == "~LongdownValley~Container_Cupboard_C_7", "packed path")
t.on_interact_container(prm(box), prm(nil), opt1)
check(#sent == 1, "Option1 (search) sends nothing")

print("host applies it")
S.role = "host"; S.remote_pcs = { client_pc, new("PC_other") }
box._p.MarkedAsStorageContainer = false
sent = {}
t.store_msg({ "~LongdownValley~Container_Cupboard_C_7", "1" }, client_pc)
check(box._p.MarkedAsStorageContainer == true, "host copy marked")
check(comp._p["DoesContainerRefillLoot?"] == false, "host copy stops refilling")
check(#sent == 1 and sent[1][1] == "PC_other", "relayed to the other client only")

print("unmark with Difficulty.Refill on")
t.store_msg({ "~LongdownValley~Container_Cupboard_C_7", "0" }, client_pc)
check(box._p.MarkedAsStorageContainer == false and comp._p["DoesContainerRefillLoot?"] == true, "unmarked, refill back on")
cvar = false
comp._p["DoesContainerRefillLoot?"] = false
t.store_msg({ "~LongdownValley~Container_Cupboard_C_7", "1" }, client_pc)
t.store_msg({ "~LongdownValley~Container_Cupboard_C_7", "0" }, client_pc)
check(comp._p["DoesContainerRefillLoot?"] == false, "Refill off: refill stays off")

print("join snapshot carries the mark")
box._p.MarkedAsStorageContainer = true
local items = {}
local orig_send = t.send_list
local _ = orig_send
FindAllOf = function(cls) if cls == "BP_LootContainer_C" then return { box } end return nil end
sent = {}
t.snapshot(client_pc)
-- 0.6.49: snapshots go through the per-client queue, sent from the next tick
if t.queue and t.queue.host_pump then t.queue.host_pump() end
for _, m in ipairs(sent) do if m[2] == "WLOOTS" then items[#items + 1] = m[3] end end
check(items[1] and items[1]:find("!s", 1, true) ~= nil, "WLOOTS item has !s: " .. tostring(items[1]))
S.role = "client"
box._p.MarkedAsStorageContainer = false
t.loots_msg({ items[1] })
check(box._p.MarkedAsStorageContainer == true, "client applies the storage mark from the snapshot")

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
