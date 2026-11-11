-- Tests for sdc_ai core's sweep of gone AI copies (real sdc_ai, fake feature
-- modules and world). usage: lua test_aisweep.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    if c then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local T = 1000.0
os.clock = function() return T end
local logs = {}
print = function(s) logs[#logs + 1] = s end
local function log_has(p) for _, l in ipairs(logs) do if l:find(p) then return true end end return false end
FName = function(s) return s end
RegisterHook = function() return 1, 2 end

package.loaded["sdc_config"] = { get = function() return nil end }
package.loaded["sdc_ctx"] = setmetatable({}, { __index = function() return function() end end })
local ue = require("sdc_ue")

-- the world
local function actor(name)
    local a = { alive = true, name = name }
    function a:IsValid() return self.alive end
    function a:GetFullName() return "BP_Zombie_Roamer_C /Game/Maps/PersistentLevel.PersistentLevel:PersistentLevel." .. self.name end
    function a:GetFName() return { ToString = function() return name end } end
    return a
end
local world = {}
local own = actor("BP_PlayerCharacter_C_2147478132")
own.GetFullName = function() return "BP_PlayerCharacter_C /Game/Maps/PersistentLevel.PersistentLevel:PersistentLevel.BP_PlayerCharacter_C_2147478132" end
local CHAR = { IsValid = function() return true end }
local listed = 0
local gps = { IsValid = function() return true end }
function gps:GetAllActorsOfClass(wc, cls, out)
    listed = listed + 1
    if cls ~= CHAR then return end
    out[#out + 1] = { get = function() return own end }
    for _, a in ipairs(world) do if a.alive then out[#out + 1] = { get = function() return a end } end end
end
local real_find = ue.find_object
ue.find_object = function(p) if p == "/Script/Engine.Character" then return CHAR end return nil end
ue.gameplay_statics = function() return gps end
local pc = { IsValid = function() return true end }
ue.local_pc = function() return pc end
ue.local_pawn = function() return own end

-- fake feature modules: one keeps tables keyed by copy full name
local tabs = { applied = {}, born = {} }
local core
local function fake(id, register)
    package.loaded["sdc_ai_" .. id] = {
        init = function(c)
            core = c
            if register then
                c.forget_gone(id, function() return { applied = tabs.applied, born = tabs.born } end)
            end
        end,
        client_tick = function() end,
    }
end
for _, id in ipairs({ "kills", "attacks", "corpses", "hud", "offscreen", "killlog", "ghosts", "fx" }) do fake(id, false) end
fake("looks", true)

local ai = require("sdc_ai")
local S = { role = "client", remote_pcs = {} }
ai.init(S)

-- copies: runtime-spawned (unique) and one level-placed name
local z1, z2, z3 = actor("BP_Zombie_Roamer_C_2147320909"), actor("BP_Zombie_Roamer_C_2147320885"), actor("BP_Zombie_Roamer_C_2147320800")
local placed = actor("BP_ZombieBoss_Military_C_7")
world = { z1, z2, z3, placed }
for _, a in ipairs(world) do
    tabs.applied[ue.name(a)] = { mesh = "x" }
    tabs.born[ue.name(a)] = T
end
ai.client_tick()
check(core ~= nil and type(core.forget_gone) == "function", "core.forget_gone exists")
check(listed == 1, "the world is listed once")
local n = 0 for _ in pairs(tabs.applied) do n = n + 1 end
check(n == 4, "nothing dropped while every copy exists")

-- z2 and the placed boss go away
z2.alive = false
placed.alive = false
T = T + 30
ai.client_tick()
check(listed == 1, "not listed again within a minute")
T = T + 31
ai.client_tick()
check(listed == 2, "listed again after a minute")
check(tabs.applied[ue.name(z1)] and tabs.applied[ue.name(z3)], "existing copies keep their entries")
check(tabs.applied["BP_Zombie_Roamer_C /Game/Maps/PersistentLevel.PersistentLevel:PersistentLevel.BP_Zombie_Roamer_C_2147320885"] == nil
    and tabs.born["BP_Zombie_Roamer_C /Game/Maps/PersistentLevel.PersistentLevel:PersistentLevel.BP_Zombie_Roamer_C_2147320885"] == nil,
    "a gone runtime-spawned copy loses its entries in every registered table")
check(tabs.applied["BP_Zombie_Roamer_C /Game/Maps/PersistentLevel.PersistentLevel:PersistentLevel.BP_ZombieBoss_Military_C_7"] ~= nil,
    "a level-placed name is never dropped (it can stream back)")
check(log_has("ai: forgot 2 entries of AI copies no longer in this world %(looks.applied 1, looks.born 1%)")
    or log_has("ai: forgot 2 entries of AI copies no longer in this world %(looks.born 1, looks.applied 1%)"), "one summary line")
check(ai.sweep_stats.dropped == 2, "counted")

-- a list without this player's own character is not trusted
local k3 = ue.name(z3)
z3.alive = false
local real_pawn = ue.local_pawn
ue.local_pawn = function() return actor("BP_PlayerCharacter_C_2147400000") end
T = T + 61
ai.client_tick()
check(tabs.applied[k3] ~= nil, "nothing dropped when the own character is missing from the list")
ue.local_pawn = real_pawn

-- no world list (no controller): nothing dropped
ue.local_pc = function() return nil end
T = T + 61
ai.client_tick()
check(tabs.applied[k3] ~= nil, "nothing dropped without a world context")
ue.local_pc = function() return pc end
T = T + 61
ai.client_tick()
check(tabs.applied[k3] == nil, "dropped once the list is trusted again")

-- a world reset replaces the tables: the sweep reads the current ones
tabs.applied, tabs.born = {}, {}
local z4 = actor("BP_Zombie_Roamer_C_2147300000")
tabs.applied[ue.name(z4)] = {}
T = T + 61
ai.client_tick()
check(next(tabs.applied) == nil, "a new table (after a reset) is swept too")

-- host role: no sweep
S.role = "host"
local l0 = listed
T = T + 61
ai.client_tick()
check(listed == l0, "host: the client sweep does not run")
ue.find_object = real_find

io.stderr:write(string.format("%d checks, %d failed\n", checks, fails))
os.exit(fails == 0 and 0 or 1)
