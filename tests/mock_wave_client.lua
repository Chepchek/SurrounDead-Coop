-- Mock test (0.7.3 wave, group "session"): client pieces.
-- sdc_sync's weather on a client:
--   4. sync_weather_overrides on (default): the host's weather state goes into
--      the UDW channels and their "Manual Override" switches (as before);
--      off: the overrides this machine has on go off again (OnRep), nothing is
--      written into the channels, a "native weather check" line every 60 s
--      compares the host's state with this machine's and its random weather
--      manager, and once - the manager not started while the world is in
--      random weather mode - UDW's own Initialize Random Weather Variation;
--      back on: the overrides again; a new connection checks afresh
-- sdc_ai_kills (2, the host's difficulty): a client's kill XP uses the
--      Difficulty.XPMultiplier CVar (the host's for the session): when the
--      own LevellingComponent's Difficulty_MultiplierValue differs, the
--      game's own Event_Multiplier gets the CVar's value before AddXP
-- Every other module is an automatic stub; sdc_log / sdc_config are real.
-- usage: lua mock_wave_client.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local LOGS = {}
local real_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOGS[#LOGS + 1] = table.concat(parts, "\t")
end
local function count(pat, from)
    local n = 0
    for i = (from or 0) + 1, #LOGS do if LOGS[i]:find(pat, 1, true) then n = n + 1 end end
    return n
end

local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_sync = true, sdc_log = true, sdc_config = true, sdc_ai_kills = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end

local T = 100.0
os.clock = function() return T end

-- the weather actor
local CH = { "Cloud Coverage", "Rain", "Snow", "Thunder/Lightning", "Wind Intensity", "Fog", "Dust", "Material Wetness",
             "Material Snow Coverage", "Material Dust Coverage" }
local mgr = { _valid = true, _name = "Random_Weather_Variation", Started = false }
local W = { _valid = true, _name = "Ultra_Dynamic_Weather_0", calls = {}, ["Random Weather Manager"] = mgr,
            ["Random Weather Variation State"] = 1 }
for _, c in ipairs(CH) do W[c] = 0; W[c .. " - Manual Override"] = false end
local function calls(fn, from) local n = 0 for i = (from or 0) + 1, #W.calls do if W.calls[i] == fn then n = n + 1 end end return n end

local ue = stub()
ue.valid = function(o) return type(o) == "table" and o._valid == true end
ue.prop = function(o, k) if not ue.valid(o) then return nil end return rawget(o, k) end
ue.set_prop = function(o, k, v) if not ue.valid(o) then return false end rawset(o, k, v) return true end
ue.call = function(o, fn) if not ue.valid(o) then return false end o.calls[#o.calls + 1] = fn return true end
ue.short = function(o) return ue.valid(o) and o._name or "<none>" end
ue.name = ue.short
ue.find_first = function(cls) if cls == "Ultra_Dynamic_Weather_C" then return W end return nil end
ue.role = function() return 3 end
ue.path = function() return "" end
ue.ROLE_SIMULATED = 1
package.loaded["sdc_ue"] = ue

local cfg = require("sdc_config")
local sync = require("sdc_sync")
cfg.set("sync_env", true)
local HOST = "cc=0.800;r=0.500;s=0.000;t=0.000;w=0.300;f=1.000;d=0.000;mw=0.200;ms=0.000;md=0.000"

print("weather")
check(cfg.get("sync_weather_overrides") == true, "sync_weather_overrides defaults to on")
sync.apply_env(nil, "", HOST)
check(W["Cloud Coverage"] == 0.8 and W["Rain"] == 0.5 and W["Cloud Coverage - Manual Override"] == true
    and W["Rain - Manual Override"] == true, "on: the host's state in the channels, overrides on (as before)")
-- off: the game's own random weather
cfg.set("sync_weather_overrides", false)
local mark = #LOGS
local n_rep = #W.calls
sync.apply_env(nil, "", "cc=0.100;r=0.900")
local all_off = true
for _, c in ipairs(CH) do if W[c .. " - Manual Override"] ~= false then all_off = false end end
check(all_off, "off: every manual override released")
check(calls("OnRep_Cloud Coverage - Manual Override", n_rep) == 1 and calls("OnRep_Rain - Manual Override", n_rep) == 1,
    "  with the game's own OnRep")
check(W["Cloud Coverage"] == 0.8 and W["Rain"] == 0.5, "off: nothing written into the channels")
check(count("manual override(s) released", mark) == 1, "  logged once")
check(count("native weather check: host cc=0.100;r=0.900 | here cc=0.800;r=0.500", mark) == 1
    and count("started=false", mark) == 1, "the check line: the host's and this machine's state, the manager")
check(calls("Initialize Random Weather Variation") == 1, "the manager not started in random weather mode: UDW's own init once")
T = T + 30
sync.apply_env(nil, "", "cc=0.100;r=0.900")
check(count("native weather check", mark) == 1, "30 s later: no new line")
T = T + 31
sync.apply_env(nil, "", "cc=0.100;r=0.900")
check(count("native weather check", mark) == 2 and calls("Initialize Random Weather Variation") == 1,
    "61 s: a new line, no second init")
check(count("manual override(s) released", mark) == 1, "the overrides released only once")
-- a manager that started: never nudged
-- back on
cfg.set("sync_weather_overrides", true)
mark = #LOGS
sync.apply_env(nil, "", HOST)
check(W["Cloud Coverage - Manual Override"] == true and W["Cloud Coverage"] == 0.8, "on again: overrides and channels again")
check(count("sync_weather_overrides on again", mark) == 1, "  logged")
-- a new connection: the check starts afresh; a started manager is left alone
cfg.set("sync_weather_overrides", false)
sync.reset_client_state()
mgr.Started = true
mark = #LOGS
sync.apply_env(nil, "", HOST)
check(count("manual override(s) released", mark) == 1 and count("native weather check", mark) == 1,
    "a new connection: released and checked again")
check(calls("Initialize Random Weather Variation") == 1, "a started manager: no init")
cfg.set("sync_env", false)
local before = #W.calls
sync.apply_env(nil, "", HOST)
check(#W.calls == before, "sync_env off: nothing at all")

-- ===================================================================== kill XP
print("kill XP multiplier")
local CU = { _valid = true, _name = "Default__ConsoleUtils", calls = {}, xp = 2.5 }
CU.GetFloatCVar = function(self, n) if n == "Difficulty.XPMultiplier" then return self.xp end end
local order = {}
local comp = { _valid = true, _name = "LevellingComponent", calls = {}, Difficulty_MultiplierValue = 1.0, CurrentLevel = 1,
               MultiplyValue = 1 }
comp.Event_Multiplier = function(self, v) order[#order + 1] = "mult"; self.Difficulty_MultiplierValue = v end
comp.AddXP = function(self, xp) order[#order + 1] = "addxp" end
local pc = { _valid = true, _name = "PC", calls = {}, ZombieKills = 0, LevellingComponent = comp }
ue.local_pc = function() return pc end
ue.find_object = function(path) if path:find("ConsoleUtils", 1, true) then return CU end return nil end
local kills = require("sdc_ai_kills")
local firsts = {}
kills.init({ S = { role = "client" }, ZM = "/Game/Z.Z_C:", hook = function() end,
             first = function(k, n) firsts[k] = (firsts[k] or 0) + 1; return firsts[k] <= (n or 1) end,
             cvar_bool = function() return false end })
local mark2 = #LOGS
kills.on_message("AIKILL", { "z", "", "0" })
check(pc.ZombieKills == 1 and table.concat(order, ",") == "mult,addxp" and comp.Difficulty_MultiplierValue == 2.5,
    "a kill: Event_Multiplier(2.5) before AddXP: " .. table.concat(order, ","))
check(count("XP multiplier of the own controller 1.0, Difficulty.XPMultiplier is 2.5", mark2) == 1, "  logged")
order = {}
kills.on_message("AIKILL", { "z", "", "0" })
check(table.concat(order, ",") == "addxp", "the same value already: only AddXP")
CU.xp = nil
comp.Difficulty_MultiplierValue = 1.0
order = {}
kills.on_message("AIKILL", { "z", "", "0" })
check(table.concat(order, ",") == "addxp", "the CVar unreadable: left as it is")

print = real_print
print(string.format("wave client: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
