-- Mock test (critic fixes 2026-11-13, group A2, B2): sdc_notes registers its
-- host-only hooks (BP_PlayerCharacter.CreateNotificationUI,
-- BP_JigComponent.SERVER_ForwardInteract, BP_Infestation.Damage_Object)
-- only on the host; a client hooks GameFunctionLibrary.CreateNotificationUI
-- alone. A machine that becomes the host gets them on its next tick.
-- usage: lua mock_fix_a2_notes.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local T = 100.0
os.clock = function() return T end

-- quiet stubs for the modules sdc_notes pulls in
local nop = function() end
local LOG = {}
package.loaded["sdc_log"] = setmetatable({
    info = function(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end,
    ascii = function(s) return s end,
}, { __index = function() return nop end })
local CFG = {}
package.loaded["sdc_config"] = { get = function(k) return CFG[k] end, set = nop, save = nop }
package.loaded["sdc_ue"] = setmetatable({
    valid = function(o) return o ~= nil end,
    find_object = function(path) return { path = path } end,   -- every class is loaded
}, { __index = function() return nop end })
package.loaded["sdc_net"] = { on = nop, send_to = function() return true end }
package.loaded["sdc_ctx"] = setmetatable({}, { __index = function() return nop end })
package.loaded["sdc_session"] = { world_reset_hooks = {} }

local HOOKED = {}
function RegisterHook(path) HOOKED[path] = (HOOKED[path] or 0) + 1; return 1, 2 end

local notes = require("sdc_notes")
local P = notes.PATHS
local S = { role = "client", remote = {}, remote_pcs = {} }

print("a client")
notes.install(S)
notes.tick()
T = T + 5
notes.tick()
check(HOOKED[P.gfl] == 1, "GameFunctionLibrary.CreateNotificationUI hooked once")
check(HOOKED[P.char] == nil and HOOKED[P.forward] == nil and HOOKED[P.infest] == nil,
    "no host-only hooks on a client (character notice, forwarded interaction, nest hit)")
check(notes.status_line():find("hooks=notes+,char-,forward-,nest-", 1, true) ~= nil, "status: " .. notes.status_line())

print("the same machine becomes the host")
S.role = "host"
notes.tick()   -- the role change forces a try at once (no HOOK_RETRY_S wait)
check(HOOKED[P.char] == 1 and HOOKED[P.forward] == 1 and HOOKED[P.infest] == 1, "host-only hooks registered on the next tick")
T = T + 5
notes.tick()
check(HOOKED[P.gfl] == 1 and HOOKED[P.char] == 1, "each hook registered once")

print("a host from the start")
for k in pairs(package.loaded) do if k == "sdc_notes" then package.loaded[k] = nil end end
HOOKED = {}
local notes2 = require("sdc_notes")
notes2.install({ role = "host", remote = {}, remote_pcs = {} })
check(HOOKED[P.gfl] == 1 and HOOKED[P.char] == 1 and HOOKED[P.forward] == 1 and HOOKED[P.infest] == 1,
    "install as host: all four hooks")

print(string.format("fix a2 notes: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
