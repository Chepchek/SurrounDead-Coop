-- sdc_dialogue + sdc_quests against stub modules: every engine answer is nil.
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
function ue.valid() return false end
function ue.find_all() return {} end
function ue.find_object(p) return { path = p } end      -- every function "exists"
function ue.short() return "<none>" end
function ue.name() return "<none>" end
function ue.path() return "" end
function ue.str() return "" end
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
  on = function(k, h) assert(not handlers[k], "second handler for " .. k); handlers[k] = h end }
package.loaded["sdc_ctx"] = { player_for = function() return nil end, classify = function() return "?" end }
RegisterHook = function(path, pre, post)
  assert(not hooks[path], "second RegisterHook on " .. path)
  hooks[path] = { pre = pre, post = post }
  return 1, 2
end
FName = function(s) return s end
FText = function(s) return s end
LoadAsset = function() end

local dlg = require("sdc_dialogue")
local quests = require("sdc_quests")
assert(dlg.quest_gnc ~= nil, "sdc_quests hands its GetNarrativeComponent handler to sdc_dialogue")
local S = { role = "client", remote_pcs = {} }
dlg.init(S); quests.init(S)
dlg.install(); dlg.install(); quests.install()
dlg.register_handlers(); quests.register_handlers()
dlg.client_tick(1000, nil, nil); quests.client_tick(1000, nil, nil)
dlg.client_tick(1020, nil, nil); quests.client_tick(1020, nil, nil)
local nil_param = { get = function() return nil end, set = function() end }
local function call_all()
  for path, h in pairs(hooks) do
    local fn = type(h) == "function" and h or h.pre
    for _, f in ipairs({ fn, type(h) == "table" and h.post or nil }) do
      if f then
        assert(f(nil_param, nil_param, nil_param, nil_param, nil_param, nil_param, nil_param, nil_param, nil_param) == nil,
          "hook returned a value: " .. path)
        assert(f(nil, nil, nil) == nil, "hook returned a value (nil args): " .. path)
      end
    end
  end
  for _, h in pairs(handlers) do
    h({}, nil)
    h({ "x", "1", "2", "3", "4" }, nil)
    h({ "forget", "" }, nil)
  end
  for _, kind in ipairs({ "bounty", "area", "generator" }) do
    for _, r in ipairs({ "host", "client" }) do dlg.quest_gnc(r, kind, nil, nil_param) end
  end
  for _, fn in ipairs(delayed) do fn() end
  delayed = {}
end
call_all()
S.role = "host"
S.remote_pcs = { {} }
dlg.host_tick(2000); quests.host_tick(2000)
dlg.host_tick(2020); quests.host_tick(2020)
call_all()
quests.persist_bind(nil, "s", "k", true); quests.persist_save(nil); quests.persist_delete("s", "k")
dlg.reset("role standalone"); quests.reset("test")
local lines = {}
dlg.status_lines(lines); quests.status_lines(lines)
local n = 0
for path in pairs(hooks) do if not path:find("#", 1, true) then n = n + 1 end end
-- sdc_dialogue: 4 native + 5 Blueprint; sdc_quests: 4 native + 6 Blueprint
assert(n == 19, "19 engine hooks, got " .. n)
assert(hooks["/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass#dlg.trader-spawn"], "spawn subscriber")
local bad = 0
for _, l in ipairs(logs) do if l:find("^err") then print(l); bad = bad + 1 end end
if bad > 0 then error("a hook threw") end
print("client/host: every hook, handler and quest handler with nil parameters ran clean, " .. n .. " hooks, each once")
print("ALL OK")
