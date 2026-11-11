local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path
local calls = {}
local function stubmod(name)
  return setmetatable({}, { __index = function(t, k)
    if k == "ROLE_SIMULATED" then return 1 elseif k == "ROLE_AUTONOMOUS" then return 2 elseif k == "ROLE_AUTHORITY" then return 3 end
    if k == "addr" then return function(o) return tostring(o) end end
    if k == "debug_enabled" then return false end
    if k == "find_all" then return function() return {} end end
    if k == "class_name" or k == "str" or k == "short" or k == "name" then return function() return "" end end
    return function(...) calls[#calls+1] = name .. "." .. k; return nil end
  end })
end
package.loaded["sdc_log"] = stubmod("log")
package.loaded["sdc_ue"] = stubmod("ue")
-- sdc_ue.hook_native (0.6.39): one shared engine hook; here a plain RegisterHook
rawset(package.loaded["sdc_ue"], "hook_native", function(path, _, fn) return pcall(RegisterHook, path, fn) end)
package.loaded["sdc_config"] = stubmod("cfg")
package.loaded["sdc_net"] = stubmod("net")
package.loaded["sdc_ctx"] = stubmod("ctx")
RegisterHook = function(path, ...) calls[#calls+1] = "RegisterHook " .. path; return 1, 2 end
NotifyOnNewObject = function(path, fn) calls[#calls+1] = "Notify " .. path end
FName = function(s) return s end
LoadAsset = function() return nil end
local items = require("sdc_items")
local appearance = require("sdc_appearance")
local pawnstate = require("sdc_pawnstate")
local gearfx = require("sdc_gearfx")
local S = { role = "client", remote_pcs = {} }
items.init(S); appearance.init(S); pawnstate.init(S); gearfx.init(S)
items.install()
items.client_tick(); gearfx.client_tick(); gearfx.tick(); appearance.tick(); pawnstate.tick(); pawnstate.fast_tick(); pawnstate.frame_tick()
items.hotbar_tick()
S.role = "host"
items.host_tick({}); gearfx.host_tick(); appearance.tick({}); pawnstate.tick({})
items.reset(); appearance.reset(); pawnstate.reset()
local n = 0
for _, c in ipairs(calls) do if c:find("^RegisterHook") or c:find("^Notify") then print(c) end end
print("OK", #calls)
