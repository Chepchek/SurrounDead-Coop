-- Tests for sdc_perf's Lua-registry count and out-parameter probe in [MEM]
-- (UE4SS takes a luaL_ref to every out-parameter table; the shipped build
-- releases it after the call). usage: lua test_outrefs.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local out = {}
print = function(s) out[#out + 1] = s end
FName = function(s) return s end

local log = require("sdc_log")
local perf = require("sdc_perf")
local ue = require("sdc_ue")

local reg = debug.getregistry()
local FREE = 3
-- luaL_ref / luaL_unref as lauxlib does them (Lua 5.4.3+): free list at slot 3
local function ref(v)
    if reg[FREE] == nil then reg[FREE] = 0 end
    local r = reg[FREE]
    if r ~= 0 then
        reg[FREE] = reg[r]
    else
        r = #reg + 1
    end
    reg[r] = v
    return r
end
local function unref(r)
    reg[r] = reg[FREE]
    reg[FREE] = r
end

-- 1. counting: references held = slots - free list
unref(ref(true))   -- UE4SS has made references long before the mod runs: free list set up
local n0, f0, u0 = perf.registry_refs()
check(type(n0) == "number" and type(u0) == "number", "registry readable")
local r = {}
for i = 1, 5 do r[i] = ref({ i }) end
unref(r[2]); unref(r[4])
local n1, f1, u1 = perf.registry_refs()
check(u1 - u0 == 3, "5 refs taken, 2 released: +3 held (" .. tostring(u1 - u0) .. ")")
-- the set-up slot was reused by the first ref; the free list now holds the 2 released ones
check(f0 == 1 and f1 == 2, "the released slots are counted as free (" .. tostring(f0) .. " -> " .. tostring(f1) .. ")")
check(n1 >= n0, "slots never shrink")
for _, i in ipairs({ 1, 3, 5 }) do unref(r[i]) end

-- 2. a UE4SS that releases out-parameter references (the shipped 4fb9b61)
local kml = { IsValid = function() return true end }
function kml:BreakVector(v, a, b, c)
    -- UE4SS: luaL_ref per out table, the call, then luaL_unref + write-back
    local ra, rb, rc = ref(a), ref(b), ref(c)
    unref(ra); unref(rb); unref(rc)
    a.X, b.Y, c.Z = v.X, v.Y, v.Z
end
ue.find_object = function(p) if p == "/Script/Engine.Default__KismetMathLibrary" then return kml end end
local kept, x = perf.outparam_probe()
check(kept == 0 and x == 1, "probe: released, the out value came back (" .. tostring(kept) .. ", " .. tostring(x) .. ")")
perf.mem_census()
check(out[#out]:find("%[MEM%] lua heap") and out[#out]:find("lua registry %d+ slots, %d+ free, %d+ references held; out%-param references released"),
    "[MEM] line: registry and 'released'")

-- 3. a UE4SS that keeps them (older 3.0.1 builds)
function kml:BreakVector(v, a, b, c)
    ref(a); ref(b); ref(c)
    a.X, b.Y, c.Z = v.X, v.Y, v.Z
end
kept = perf.outparam_probe()
check(kept == 3, "probe: a keeping build shows +3 (" .. tostring(kept) .. ")")
perf.mem_census()
check(out[#out]:find("out%-param references KEPT %(%+3 from one call"), "[MEM] line says KEPT")
check(out[#out]:find("since the last %[MEM%]"), "[MEM] line shows the change since the last one")

-- 4. a failing probe call is reported n/a, not as a leak
function kml:BreakVector() error("Tried calling UFunction without a registered handler") end
local k4, why = perf.outparam_probe()
check(k4 == nil and tostring(why):find("registered handler"), "failing probe: n/a with the reason")
perf.mem_census()
check(out[#out]:find("out%-param probe n/a"), "[MEM] line says n/a")

-- 5. no KismetMathLibrary (not loaded / tests): n/a
ue.find_object = function() return nil end
check(perf.outparam_probe() == nil, "no library: n/a")

io.stderr:write(string.format("%d checks, %d failed\n", checks, fails))
os.exit(fails == 0 and 0 or 1)
