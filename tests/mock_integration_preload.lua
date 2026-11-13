-- Mock test (integration 2026-11-13): a client preloads the throwable
-- classes once per world, 10 s after its character exists, one a second,
-- off the message path (load_class takes only classes already in memory on
-- a client).
-- usage: lua mock_integration_preload.lua <scripts dir>
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
local REAL = { sdc_throw = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end

local loads, inmem = {}, {}
local PAWN = nil
local ue = stub()
ue.local_pawn = function() return PAWN end
ue.find_object = function(path) return inmem[path] end
ue.load_asset = function(path) loads[#loads + 1] = path; inmem[path] = { path = path }; return true, inmem[path] end
ue.loaded_asset = function(path) return inmem[path] end
package.loaded["sdc_ue"] = ue
package.loaded["sdc_ctx"] = setmetatable({ addr = function() return nil end }, { __index = function() return function() end end })

local throw = require("sdc_throw")
check(type(throw._client_preload) == "function", "preload exists")
local p = throw._client_preload
p(0)
check(#loads == 0, "no character: nothing loaded")
PAWN = { key = "me" }
p(1); p(5); p(10.5)
check(#loads == 0, "character for less than 10 s: nothing yet")
p(11.1)
check(#loads == 1 and loads[1]:find("BP_Throwable_Frag", 1, true) ~= nil, "10 s later: the first class (frag)")
p(11.5)
check(#loads == 1, "one a second")
for s = 12.2, 20, 1 do p(s) end
check(#loads == 5, "all five classes, once each (" .. #loads .. ")")
for s = 21, 30, 1 do p(s) end
check(#loads == 5, "done: nothing more this world")
throw.reset("world")
loads = {}
p(100); p(111)
check(#loads == 0, "a new world: classes already in memory are not loaded again")

print = real_print
print(string.format("preload: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
