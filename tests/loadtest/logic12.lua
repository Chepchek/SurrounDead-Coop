-- sdc_dialogue (trader flow) against stub modules: every engine answer is nil.
-- Install / ticks / handlers / every hook callback with nil parameters must
-- not throw, return nothing, and register each Blueprint function once.
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path
local logs = {}
local log = setmetatable({ debug_enabled = false }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    if k == "toast" then fmt = args[3] or a; args = {} end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local ue = setmetatable({ ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }, { __index = function(_, k)
  return function() return nil end
end })
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return false end
function ue.find_all() return {} end
function ue.find_object(p) return { path = p } end      -- every function "exists"
function ue.short() return "<none>" end
function ue.name() return "<none>" end
function ue.class_name() return "" end
function ue.role() return -1 end
function ue.in_main_menu() return false end
function ue.game_thread(_, fn) fn() end
local delayed = {}
function ue.delay(_, _, fn) delayed[#delayed + 1] = fn end
local hooks = {}
function ue.hook_native(path, key, fn) hooks[path .. "#" .. key] = fn; return true end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return nil end }
local handlers = {}
package.loaded["sdc_net"] = { send_to = function() return true end, send_to_host = function() return true end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { player_for = function() return nil end, classify = function() return "?" end }
RegisterHook = function(path, pre, post)
  assert(not hooks[path], "second RegisterHook on " .. path)
  hooks[path] = { pre = pre, post = post }
  return 1, 2
end
FName = function(s) return s end
LoadAsset = function() end

local dlg = require("sdc_dialogue")
local S = { role = "client", remote_pcs = {} }
dlg.init(S)
dlg.install()
dlg.install()
dlg.register_handlers()
dlg.client_tick(1000, nil, nil)
dlg.client_tick(1020, nil, nil)
local nil_param = { get = function() return nil end, set = function() end }
local function call_all()
  for path, h in pairs(hooks) do
    local fn = type(h) == "function" and h or h.pre
    for _, f in ipairs({ fn, type(h) == "table" and h.post or nil }) do
      if f then
        local r = f(nil_param, nil_param, nil_param, nil_param, nil_param, nil_param, nil_param, nil_param, nil_param)
        assert(r == nil, "hook returned a value: " .. path)
        r = f(nil, nil, nil)
        assert(r == nil, "hook returned a value (nil args): " .. path)
      end
    end
  end
  for k, h in pairs(handlers) do
    h({}, nil)
    h({ "x", "1", "2", "3", "4" }, nil)
  end
  for _, fn in ipairs(delayed) do fn() end
  delayed = {}
end
call_all()
S.role = "host"
dlg.host_tick(2000)
dlg.host_tick(2020)
call_all()
dlg.reset("test")
local lines = {}
dlg.status_lines(lines)
assert(#lines == 2, "status lines")
local n = 0
for path in pairs(hooks) do if not path:find("#", 1, true) then n = n + 1 end end
assert(n == 9, "9 engine hooks (4 native + 5 Blueprint: the quest giver since 0.6.62), got " .. n)
assert(hooks["/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass#dlg.trader-spawn"], "spawn subscriber")
local bad = 0
for _, l in ipairs(logs) do if l:find("^err") then print(l); bad = bad + 1 end end
if bad > 0 then error("a hook threw") end
print("client/host: every hook and handler with nil parameters ran clean, " .. n .. " hooks, each once")
print("ALL OK")
