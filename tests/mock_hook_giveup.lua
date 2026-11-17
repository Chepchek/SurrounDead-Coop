-- Mock harness: sdc_world's hook give-up (try_hooks: HOOKS.tries / HOOKS.dead).
-- A hook that will not register costs ~22 ms inside UE4SS on every try. After HOOK_TRIES (8) tries
-- made with the hook's class itself in memory it is left alone until the next world. The tries of
-- the main menu (every class unloaded) must NOT count: 17.11 review - the counter went up on every
-- failure, so the first failure after a class loaded ended the hook for the whole world.
-- usage: lua mock_hook_giveup.lua <scripts dir>
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
local reg = {}          -- [path] = how many times RegisterHook was asked for it
function RegisterHook(path)
  reg[path] = (reg[path] or 0) + 1
  error("no UFunction with the specified name was found")
end
function NotifyOnNewObject() end

local LOADED = {}       -- [class path] = object: what ue.find_object can see
local probed = {}
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.name(o) return ue.valid(o) and (o.__name or "obj") or "" end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return ue.valid(o) and (o.__path or "") or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if ue.valid(o) then o[n] = v end end
function ue.location() return nil end
function ue.role() return 2 end
function ue.is_runtime_spawned() return true end
function ue.find_all() return {} end
function ue.find_all_recent() return {} end
function ue.watch_new() return true end
function ue.find_object(path) return LOADED[path] end
function ue.load_asset() return nil end
function ue.pawn_of(pc) return pc and pc.Pawn end
function ue.role_of() return 1 end
function ue.delay(_, _, fn) return true end
function ue.sub_time() return true end
function ue.hook_native() return true end
function ue.every_frame() return true end
function ue.in_main_menu() return false end
function ue.local_pawn() return nil end
function ue.local_pc() return nil end
function ue.probe_hook(path, tag) probed[#probed + 1] = path end
package.loaded["sdc_ue"] = ue

package.loaded["sdc_config"] = { get = function(k) return true end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and (o.__addr or o.__name) or nil end }
package.loaded["sdc_wire"] = { uid_enc = tostring, uid_dec = tostring }
package.loaded["sdc_net"] = {
  NOW = {}, on = function() end, send_to = function() end, send_to_host = function() return true end,
  broadcast = function() return true end, congested = function() return false end,
}

local world_mod = require("sdc_world")
local HOOKS = world_mod._t.hooks
local try_hooks = world_mod._t.try_hooks

local CLASS = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryCircuitBox.BP_LaboratoryCircuitBox_C"
local PATH = CLASS .. ":Damage_Object"
local OTHER = "/Game/Blueprints/Other/Objects/BP_Siren.BP_Siren_C:ActivateSiren"

local listed = 0
for _, h in ipairs(HOOKS) do if h[1] == PATH or h[1] == OTHER then listed = listed + 1 end end
check(listed == 2, "the two hooks under test are in the hook list")
world_mod.install({ role = "host", remote_pcs = {} })

-- ============================================================ A. classes unloaded (the main menu)
print("A. 12 failed passes with the class not loaded:")
for _ = 1, 12 do T = T + 1; try_hooks(true) end
check(reg[PATH] == 12, "A: tried on every pass (" .. tostring(reg[PATH]) .. " times)")
check(not HOOKS.dead[PATH], "A: the hook is not given up")
check(has_log("gives up after") == nil, "A: no give-up line")

-- ============================================================ B. the class loads, the hook still fails
print("B. the class is in memory now:")
LOADED[CLASS] = { __name = "BP_LaboratoryCircuitBox_C" }
for _ = 1, 7 do T = T + 1; try_hooks(true) end
check(not HOOKS.dead[PATH], "B: 7 tries with the class loaded: still tried (8 are needed)")
check(has_log("gives up after") == nil, "B: nothing logged yet")
T = T + 1; try_hooks(true)
check(HOOKS.dead[PATH] == true, "B: the 8th try with the class loaded ends the hook")
check(has_log("gives up after 8 tries", "info") ~= nil, "B: the give-up line counts the 8 loaded tries")
-- (two hooks of that class are in the list - Damage_Object and OnExecuteInteract - both fail alike)
local probed_for_path = 0
for _, p in ipairs(probed) do if p == PATH then probed_for_path = probed_for_path + 1 end end
check(probed_for_path == 1, "B: the hook probe ran once for that path (" .. #probed .. " probe(s) in all)")
check(not HOOKS.dead[OTHER], "B: a hook of a class that is still unloaded is not given up")

local before = reg[PATH]
for _ = 1, 3 do T = T + 1; try_hooks(true) end
check(reg[PATH] == before, "B: a given-up hook is not registered again")
check(reg[OTHER] == 12 + 7 + 1 + 3, "B: the other hook is still tried on every pass (" .. tostring(reg[OTHER]) .. ")")

-- ============================================================ C. a new world
print("C. a new world gives the tries back:")
world_mod.reset("test")
T = T + 1; try_hooks(true)
check(reg[PATH] == before + 1, "C: tried again in the new world")
check(not HOOKS.dead[PATH] and (HOOKS.tries[PATH] or 0) == 1, "C: the counters start over (1 try)")

print("")
print(checks .. " checks, " .. fails .. " failed")
os.exit(fails == 0 and 0 or 1)
