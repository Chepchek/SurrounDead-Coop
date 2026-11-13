-- Mock test (critic fixes 2026-11-13, group A1): sdc_persist (host).
--   A6: a moment without a character while alive keeps the written inventory
--       (a save / periodic pass / leave then no longer drops it);
--   B1: no BP_PlayerController.SaveGameToSlot hook: EMS's AsyncSaveActors
--       (every save of the game runs it) gives one write per save;
--   B5: the native pre-only hooks (AsyncSaveActors, AsyncLoadActors, slot
--       delete) go through sdc_ue.hook_native.
-- usage: lua mock_fix_a1_persist.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end

local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_persist = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
local HOOKS, NATIVE = {}, {}
RegisterHook = function(path, pre, post) HOOKS[path] = { pre = pre, post = post }; return 1, 2 end
-- no LOCALAPPDATA: the records stay in memory, nothing is written on this PC
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end

local NOW = 200000
os.time = function() return NOW end
local delayed = {}
local function run_delayed()
    local list = delayed
    delayed = {}
    for _, f in ipairs(list) do f() end
end

local to_client, handlers = {}, {}
local net = stub()
net.on = function(kind, fn) handlers[kind] = fn end
net.send_to = function(pc, kind, ...) to_client[#to_client + 1] = { to = pc.key, kind = kind, f = { ... } } return true end
net.send_to_host = function() return true end
net.broadcast = function() end
package.loaded["sdc_net"] = net

local ue = stub()
ue.ROLE_AUTONOMOUS, ue.ROLE_AUTHORITY = 2, 3
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.local_pc = function() return { key = "HostPC" } end
ue.pawn_of = function(pc) return type(pc) == "table" and rawget(pc, "Pawn") or nil end
ue.in_main_menu = function() return false end
ue.ems_current_slot = function() return "CoopSlot" end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.find_all = function() return {} end
ue.find_object = function() return { key = "fn" } end
ue.delay = function(_, _, fn) delayed[#delayed + 1] = fn end
ue.hook_native = function(path, key, fn) NATIVE[path] = { key = key, fn = fn }; return true end
local KEEP = false   -- the game's Difficulty.KeepInventory
ue.ksl = function() return { GetConsoleVariableBoolValue = function() return KEEP end } end
package.loaded["sdc_ue"] = ue

package.loaded["sdc_progress"] = {
    decode_values = function() return {} end, encode_values = function() return "" end, major_key = function() return "" end,
}
local S = { role = "host", remote = {}, remote_pcs = {}, in_menu = false, menu_since = 0 }
package.loaded["sdc_players"] = { PERSIST_HOOKS = true, record_for = function(pc) return S.remote[pc.key] end }

local log = require("sdc_log")
log.info = function() end
local cfg = require("sdc_config")
local persist = require("sdc_persist")
persist.install(S)
local function tick(n)
    for _ = 1, n or 1 do NOW = NOW + 1; persist.tick() end
end

print("B1 / B5: the game hooks")
tick(1)
check(HOOKS["/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot"] == nil, "no SaveGameToSlot hook")
local ems = NATIVE["/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"]
check(ems and ems.key == "persist" and HOOKS["/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"] == nil,
    "AsyncSaveActors: sdc_ue.hook_native, pre only")
check(NATIVE["/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors"] and NATIVE["/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot"],
    "AsyncLoadActors and DeleteAllSaveDataForSlot: sdc_ue.hook_native")
local saves0 = persist.stats.host_saves
ems.fn(nil, { get = function() return nil end }, { get = function() return 3 end })
ems.fn(nil, { get = function() return nil end }, { get = function() return 3 end })
run_delayed()
check(persist.stats.host_saves == saves0 + 1, "two calls within one save: one write")

print("A6: alive, no character for a moment: the written inventory stays")
local bob = { key = "BobPC", pc = { key = "BobPC" }, name = "Bob", index = 1, joined_at = NOW, pawnless_since = NOW,
              spawned_once = true, dead = false }
S.remote[bob.key] = bob
handlers.PSID({ "76561190000000042", "00112233445566778899aabb", "Bob" }, bob.pc)
local p = persist._P()[bob.key]
check(p and p.gen, "Bob has a verdict")
p.restored = true
p.snap = { alive = true, at = NOW }
local inv = { file = "CoopSlot_SDCoop_s76561190000000042", slot = "CoopSlot", source = "character", containers = 2, items = 5 }
p.inv, p.inv_sig = inv, "sig"
persist.save_now()
check(p.inv == inv and p.snap.alive == true, "a save without the character: the inventory is kept")
KEEP = true
persist.save_now()
check(p.inv == inv, "also with Difficulty.KeepInventory on (no KeepInventory read for a living player)")
KEEP = false
print("A6: dead: the inventory is in the loot box")
bob.dead = true
persist.save_now()
check(p.inv == nil and p.snap.alive == false, "dead: the saved inventory is dropped as before")

print = real_print
print(string.format("fix_a1_persist: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
