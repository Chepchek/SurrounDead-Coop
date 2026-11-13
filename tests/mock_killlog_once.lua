-- Log review 0.8.1 (2026-11-13), finding 13: sdc_ai_killlog on the host logs
-- and sends AIKL once per zombie death. The game's DamageTaken broadcasts
-- Death on every hit that leaves the health below 0, so a sawn-off's pellets
-- called Death 4-6 times for one zombie in one frame: four "ai: kill [host]"
-- lines and four AIKL (each with its ClientRepObjRef) to the client.
--   1. a pellet burst (DamageTaken + Death x4): one line, one AIKL, one count
--   2. another zombie still logs; a shot corpse later does not
--   3. the key is name AND address (a level actor streamed back in under the
--      same name, a new actor on a freed address: both new deaths)
--   4. the boss (DeathEvent) the same way
--   5. host_tick forgets a death after DEAD_TTL (1260 s); reset() forgets all
--   6. status line counts the repeats
-- usage: lua mock_killlog_once.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- the module reads os.clock once at require time
local T = 1000.0
os.clock = function() return T end

local logs = {}
local log = setmetatable({}, { __index = function(_, k)
    return function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
    end
end })

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.name(o) return ue.valid(o) and (o.__full or ("Obj /Game/L.L:PersistentLevel." .. o.__name)) or "<none>" end
function ue.short(o) return ue.valid(o) and o.__name or "<none>" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.role(o) return o and o.Role or -1 end
function ue.str(s) return s and tostring(s) or "" end
function ue.local_pc() return nil end
function ue.pawn_of() return nil end
function ue.delay() end

package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end, player_name = function() return "Host" end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and o.__addr end }
package.loaded["sdc_ai_zombie"] = {
    CRAWLER_HH = 60,
    capsule_hh = function() return 88 end,
    describe = function(z)
        return { obj = z.__name, type = z.__type or "Zombie_Roamer", name = "Undead Shambler", arch = "-",
                 crawler = false, hh = 88, mesh = "SK_A", mat = "M_A", loc = { X = 100, Y = 0, Z = 0 } }
    end,
}

local ZM = "/Game/Blueprints/Characters/Zombies/BP_MasterZombie.BP_MasterZombie_C:"
local BOSS = "/Game/Blueprints/Characters/Zombies/BP_ZombieBoss.BP_ZombieBoss_C:"
local hooks = {}
local sent = {}
local viewer_pc = { __name = "PC_client", __addr = 9001 }
local shooter = { __name = "BP_PlayerCharacter_C_2", __addr = 9002, __cls = "BP_PlayerCharacter_C" }
local core = {
    ZM = ZM, BOSS = BOSS,
    S = { role = "host", remote = { [ue.name(viewer_pc)] = { name = "guest" } } },
    host = { active = true, viewers = { { pc = viewer_pc } } },
    hook = function(spec) hooks[spec.name .. "|" .. spec.path] = spec.fn end,
    on_obj = function() end, expect_obj = function() end, forget_gone = function() end,
    viewers_near = function() return { { pc = viewer_pc } } end,
    send_with_obj = function(pc, z, kind, ...) sent[#sent + 1] = { pc = pc, z = z, kind = kind, f = { ... } }; return true end,
    remote_pc_of = function(_, causer) if causer == shooter then return viewer_pc end end,
    has_tag = function() return false end,
    is_zombie = function(o) return o and o.__zombie == true end,
    is_boss = function(o) return o and o.__boss == true end,
    is_bandit = function() return false end, is_animal = function() return false end,
}

local kl = require("sdc_ai_killlog")
kl.init(core)

local function P(v) return { get = function() return v end } end
local DEATH = hooks["killlog.death|" .. ZM .. "Death"]
local DMG = hooks["killlog.damage|/Game/Blueprints/Components/DamageComponent.DamageComponent_C:DamageTaken"]
local BOSSD = hooks["killlog.boss|" .. BOSS .. "DeathEvent"]
check(DEATH ~= nil and DMG ~= nil and BOSSD ~= nil, "host hooks registered (Death, DamageTaken, boss DeathEvent)")
DEATH = DEATH or function() end
DMG = DMG or function() end
BOSSD = BOSSD or function() end

local nextaddr = 5000
local function zombie(name, at, extra)
    nextaddr = nextaddr + 16
    local z = { __name = name, __addr = at or nextaddr, __cls = "BP_Zombie_Roamer_C", __zombie = true, Role = 3 }
    z.DamageComponent = { __name = "DamageComponent", __addr = (at or nextaddr) + 1, GetOwner = function() return z end }
    for k, v in pairs(extra or {}) do z[k] = v end
    return z
end

local function kill_lines(from)
    local n = 0
    for i = from or 1, #logs do if logs[i]:find("ai: kill [host]:", 1, true) then n = n + 1 end end
    return n
end
local function aikl(from)
    local n = 0
    for i = from or 1, #sent do if sent[i].kind == "AIKL" then n = n + 1 end end
    return n
end

local DT = {}
print("== 1. a pellet burst: Death x4 in one frame")
local z1 = zombie("BP_Zombie_Roamer_C_2147466298")
for _ = 1, 4 do
    DMG(P(z1.DamageComponent), P(30), P(DT), P(shooter), P(false))
    DEATH(P(z1), P(shooter), P(false))
end
check(kill_lines() == 1, "one 'ai: kill [host]' line for one zombie (was four): " .. kill_lines())
check(aikl() == 1, "one AIKL to the client (was four): " .. aikl())
check(kl.stats.host == 1 and kl.stats.sent == 1, "host count 1, notes sent 1: host=" .. kl.stats.host .. " sent=" .. kl.stats.sent)
check(kl.stats.repeats == 3, "the other three Death calls counted as repeats: " .. kl.stats.repeats)
local line = ""
for _, l in ipairs(logs) do if l:find("ai: kill [host]:", 1, true) then line = l end end
check(line:find("by guest", 1, true) ~= nil, "the one line still names the killer: " .. line)
check(sent[1] and sent[1].f[1] == "guest" and sent[1].z == z1, "the AIKL carries the killer and the zombie")

print("== 2. another zombie; a shot corpse")
local mark, smark = #logs + 1, #sent + 1
local z2 = zombie("BP_Zombie_Roamer_C_2147466400")
DEATH(P(z2), P(shooter), P(true))
check(kill_lines(mark) == 1 and aikl(smark) == 1, "another zombie: its own line and AIKL")
T = T + 300
mark, smark = #logs + 1, #sent + 1
kl.host_tick(T)
DEATH(P(z1), P(shooter), P(false))
check(kill_lines(mark) == 0 and aikl(smark) == 0, "the first corpse shot 300 s later: no new kill")

print("== 3. name and address")
mark, smark = #logs + 1, #sent + 1
local z3 = zombie("BP_Zombie_Roamer_C_5")                  -- placed in a level
DEATH(P(z3), P(shooter), P(false))
local z3b = zombie("BP_Zombie_Roamer_C_5")                 -- streamed back in: same name, new address
DEATH(P(z3b), P(shooter), P(false))
check(kill_lines(mark) == 2 and aikl(smark) == 2, "same name, another address: a new death (" .. kill_lines(mark) .. ")")
mark, smark = #logs + 1, #sent + 1
local z4 = zombie("BP_Zombie_Roamer_C_2147466500", z2.__addr)  -- a new actor on z2's freed address
DEATH(P(z4), P(shooter), P(false))
check(kill_lines(mark) == 1 and aikl(smark) == 1, "another name on a freed address: a new death")

print("== 4. the boss")
mark, smark = #logs + 1, #sent + 1
local boss = zombie("BP_ZombieBoss_C_2147466600", nil, { __cls = "BP_ZombieBoss_C", __zombie = false, __boss = true, __type = "Boss" })
BOSSD(P(boss), P(shooter))
BOSSD(P(boss), P(shooter))
check(kill_lines(mark) == 1 and aikl(smark) == 1, "boss DeathEvent twice: one line, one AIKL")

print("== 5. forgetting")
T = T + 1000                                               -- z1 died 1300 s ago, z2 1300, z3/z4 1000
kl.host_tick(T)
mark = #logs + 1
DEATH(P(z1), P(shooter), P(false))
check(kill_lines(mark) == 1, "after DEAD_TTL (1260 s) the entry is gone (the corpse is long destroyed in the game)")
mark = #logs + 1
DEATH(P(z4), P(shooter), P(false))
check(kill_lines(mark) == 0, "a death 1000 s ago is still remembered")
kl.reset("world")
mark = #logs + 1
DEATH(P(z4), P(shooter), P(false))
check(kill_lines(mark) == 1, "reset() (world change) forgets every death")

print("== 6. status")
local s = kl.status_line()
check(s:find("repeated Death calls=", 1, true) ~= nil, "status line shows the repeats: " .. s)
check(s:find("host=" .. kl.stats.host, 1, true) ~= nil, "status line host count")

print("== 7. not the host's zombie / host inactive")
mark = #logs + 1
local cz = zombie("BP_Zombie_Roamer_C_2147466700", nil, { Role = 1 })
DEATH(P(cz), P(shooter), P(false))
check(kill_lines(mark) == 0, "a copy (not authority): nothing")
core.host.active = false
DEATH(P(zombie("BP_Zombie_Roamer_C_2147466800")), P(shooter), P(false))
check(kill_lines(mark) == 0, "host not active: nothing")

local bad = 0
for _, l in ipairs(logs) do if l:find("^err") then print("    " .. l); bad = bad + 1 end end
check(bad == 0, "no errors logged")

if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
