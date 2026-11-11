local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path
local out = {}
print = function(s) out[#out + 1] = s end
FName = function(s) return s end
local log = require("sdc_log")
local perf = require("sdc_perf")
local ue = require("sdc_ue")
local net = require("sdc_net")
for i = 1, 300 do ue.find_stats["Class" .. i] = { calls = 1, ms = 0, n = 0 } end
for i = 1, 120 do net.handlers["K" .. i] = function() end end
perf.mem_census()
io.write(out[#out] or "no line", "\n")
local ok = (out[#out] or ""):find("sdc_ue.find_stats 300") and (out[#out] or ""):find("sdc_net.handlers 1%d%d")
io.write(ok and "census OK\n" or "census FAIL\n")
os.exit(ok and 0 or 1)
