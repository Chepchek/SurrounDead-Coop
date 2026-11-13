-- Mock test for sdc_stealth.lua: fake sdc_* modules and UE objects.
-- usage: lua mock_stealth.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails = 0
local function check(cond, what)
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
Obj.__index = Obj
local next_addr = 1000
local function new(name, props)
    next_addr = next_addr + 8
    return setmetatable({ _name = name, _p = props or {}, _addr = next_addr, _valid = true }, Obj)
end
function Obj:IsValid() return self._valid end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetFName() local s = self._name; return { ToString = function() return s end } end

local function fname(s) return { ToString = function() return s end, _s = s } end
local function param(v)
    local box = { v = v }
    return { get = function() return box.v end, set = function(_, nv) box.v = nv end, box = box }
end

-- ------------------------------------------------------------ fake modules
local LOG = {}
package.preload["sdc_log"] = function()
    local M = { debug_enabled = true }
    local function emit(lvl, msg, ...)
        local s = select("#", ...) > 0 and string.format(msg, ...) or msg
        LOG[#LOG + 1] = lvl .. " " .. s
        print("    log " .. lvl .. " " .. s)
    end
    function M.info(m, ...) emit("I", m, ...) end
    function M.warn(m, ...) emit("W", m, ...) end
    function M.err(m, ...) emit("E", m, ...) end
    function M.debug(m, ...) emit("D", m, ...) end
    function M.err_throttled(_, m, ...) emit("E", m, ...) end
    return M
end

local WORLD = { local_pc = nil }
package.preload["sdc_ue"] = function()
    local M = {}
    function M.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end return nil end
    function M.valid(o) return type(o) == "table" and o.IsValid ~= nil and o:IsValid() == true end
    function M.str(v)
        if v == nil then return "" end
        if type(v) == "string" then return v end
        if type(v) == "table" and v.ToString then return v.ToString() end
        return tostring(v)
    end
    function M.short(o) if M.valid(o) then return o._name end return "<none>" end
    function M.prop(o, n) if not M.valid(o) then return nil end return o._p[n] end
    function M.local_pc() return WORLD.local_pc end
    function M.pawn_of(pc) local p = M.prop(pc, "Pawn"); if M.valid(p) then return p end return nil end
    function M.local_pawn() return WORLD.local_pc and M.pawn_of(WORLD.local_pc) or nil end
    function M.location(a) local l = a._p._loc; if l then return { X = l.X, Y = l.Y, Z = l.Z } end return nil end
    -- sdc_ue.hook_native (0.6.39): one shared engine hook; here a plain RegisterHook
    function M.hook_native(path, _, fn) return pcall(RegisterHook, path, fn) end
    -- sdc_ue.param / backoff (2026-11-13: shared helpers, as in sdc_ue)
    function M.param(p)
        if p == nil then return nil end
        local ok, v = pcall(function() return p:get() end)
        if ok then return v end
        return nil
    end
    function M.backoff(rec, now, base, cap)
        local w = rec.wait and math.min(cap, rec.wait * 2) or base
        rec.wait, rec.next_try = w, now + w
        return w
    end
    return M
end

local CFG = { stealth_sync = nil, stealth_trace = nil }
package.preload["sdc_config"] = function()
    return { get = function(k) return CFG[k] end }
end

local SENT, HANDLERS = {}, {}
package.preload["sdc_net"] = function()
    local M = {}
    function M.on(kind, h) HANDLERS[kind] = h end
    function M.send_to_host(kind, ...) SENT[#SENT + 1] = { kind, ... }; return true end
    return M
end

package.preload["sdc_ctx"] = function()
    return { addr = function(o)
        if o == nil then return nil end
        local ok, a = pcall(function() return o:GetAddress() end)
        if ok and a then return a end
        return "<none>"
    end }
end

local HOOKS = {}
function RegisterHook(path, pre, post)
    if path:find("BP_ZombieAIController", 1, true) and not WORLD.zombie_class_loaded then
        error("no such function")
    end
    HOOKS[path] = { pre = pre, post = post }
    return 1, 2
end

local stealth = require("sdc_stealth")
local NOISE = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent"
local PERC = "/Game/AI/Zombies/BP_ZombieAIController.BP_ZombieAIController_C:PerceptionUpdate"

local function noise(wco, loc, loud, inst, range, tag)
    local r = param(range)
    HOOKS[NOISE].pre(param(nil), param(wco), param(loc), param(loud), param(inst), r, param(fname(tag)))
    return r.box.v
end

local function skills(m) return new("PassiveSkillsComponent_C", { SneakingMultiplier = m }) end

-- ================================================================== client
print("client")
local S = { role = "client", remote_pcs = {} }
stealth.install(S)
check(HANDLERS.STEALTH ~= nil, "STEALTH handler registered")
local own_m = 1.035 ^ 4
local me = new("BP_PlayerCharacter_C_me", { _loc = { X = 10, Y = 20, Z = 90 } })
local mypc = new("BP_PlayerController_C_me", { Pawn = me, PassiveSkillsComponent = skills(own_m) })
WORLD.local_pc = mypc
stealth.tick()
check(HOOKS[NOISE] ~= nil, "ReportNoiseEvent hook registered on the client")
check(HOOKS[PERC] == nil, "no PerceptionUpdate hook on a client")
local at_me = { X = 10, Y = 20, Z = 90 }
noise(me, at_me, 1, me, 1 / own_m, "Noise")              -- crouched step
advance(0.1); stealth.tick()
check(#SENT == 1 and SENT[1][1] == "STEALTH" and SENT[1][3] == "c", "crouched step sent as kind c")
check(math.abs(tonumber(SENT[1][2]) - 1 / own_m) < 0.001, "range sent is the own game's 1/mult")
noise(me, at_me, 1, me, 1 / own_m, "Noise")
advance(0.1); stealth.tick()
check(#SENT == 1, "same value not re-sent")
noise(me, at_me, 1, me, 850 / own_m, "Noise")            -- walking
advance(0.1); stealth.tick()
check(#SENT == 2 and SENT[2][3] == "w", "walk step sent as kind w")
local other = new("BP_PlayerCharacter_C_other", { _loc = { X = 0, Y = 0, Z = 0 } })
noise(other, { X = 0, Y = 0, Z = 0 }, 1, other, 0, "Noise")   -- another player's copy (multiplier 0 -> 0)
noise(me, at_me, 1, me, 1500, "Noise")                   -- own whistle
noise(me, { X = 10, Y = 20, Z = 0 }, 1, me, 150, "Noise") -- landed, at the floor
noise(me, at_me, 1, me, 500, "Noise")                    -- stomp
noise(mypc, at_me, 1, me, 2000 / own_m, "Noise")         -- other context (a weapon would be)
noise(me, at_me, 1, me, 2000 / own_m, "LoudNoise")       -- other tag
advance(0.1); stealth.tick()
check(#SENT == 2, "other noises (other player, whistle, landed, stomp, weapon ctx, tag) ignored")
noise(me, { X = 400, Y = 20, Z = 90 }, 1, me, 2000 / own_m, "Noise")  -- far from the actor
advance(0.1); stealth.tick()
check(#SENT == 2, "noise away from the character ignored")
noise(me, at_me, 1, me, 850 / own_m, "Noise")
advance(5); stealth.tick()
check(#SENT == 2, "unchanged value within 20 s not re-sent")
advance(16); stealth.tick()
check(#SENT == 3 and SENT[3][3] == "w", "unchanged value re-sent after 20 s of stepping")
advance(25); stealth.tick()
check(#SENT == 3, "no re-send without new steps")
-- respawn: new own pawn -> next step is sent even if equal
local me2 = new("BP_PlayerCharacter_C_me2", { _loc = at_me })
mypc._p.Pawn = me2
advance(1); stealth.tick()
noise(me, at_me, 1, me, 850 / own_m, "Noise")            -- old pawn: ignored
noise(me2, at_me, 1, me2, 850 / own_m, "Noise")
advance(0.1); stealth.tick()
check(#SENT == 4 and SENT[4][3] == "w", "new own character re-sends its value")
CFG.stealth_sync = false
advance(1); stealth.tick()
noise(me2, at_me, 1, me2, 1 / own_m, "Noise")
advance(0.1); stealth.tick()
check(#SENT == 4, "stealth_sync=false: client sends nothing")
CFG.stealth_sync = nil

-- ================================================================== host
print("host")
S.role = "host"
local hostpawn = new("BP_PlayerCharacter_C_host", { _loc = { X = 0, Y = 0, Z = 90 } })
local hostpc = new("BP_PlayerController_C_host", { Pawn = hostpawn, PassiveSkillsComponent = skills(1.5) })
local cl = new("BP_PlayerCharacter_C_client", { _loc = { X = 500, Y = 0, Z = 90 }, bIsCrouched = true,
    ["Sprinting?"] = false, ["CrouchSprinting?"] = true })
local ps = new("PlayerState", {})
ps.GetPlayerName = function() return "Friend" end
local clpc = new("BP_PlayerController_C_client", { Pawn = cl, PassiveSkillsComponent = skills(1.0), PlayerState = ps })
WORLD.local_pc = hostpc
S.remote_pcs = { clpc }
advance(1); stealth.tick()
check(LOG[#LOG - 0] ~= nil, "host tick ran")
check(HOOKS[PERC] == nil, "PerceptionUpdate hook waits for the zombie class")
WORLD.zombie_class_loaded = true
advance(1); stealth.tick()
check(HOOKS[PERC] ~= nil, "PerceptionUpdate hook registered once the class is loaded")
local at_cl = { X = 500, Y = 0, Z = 90 }
local r = noise(cl, at_cl, 1, cl, 250, "Noise")
check(r == 250 and stealth.stats.no_info == 1, "no owner report yet: game value kept")
HANDLERS.STEALTH({ "1.000", "c", "1.0000" }, clpc)
r = noise(cl, at_cl, 1, cl, 250, "Noise")
check(r == 1.0 and stealth.stats.capped == 1, "stale crouch-sprint step (250) lowered to owner's crouch (1)")
r = noise(cl, at_cl, 1, cl, 1.0, "Noise")
check(r == 1.0 and stealth.stats.capped == 1, "equal value untouched")
r = noise(cl, at_cl, 1, cl, 0, "Noise")
check(r == 1.0 and stealth.stats.capped == 2, "unlimited (0) footstep lowered to owner's value")
HANDLERS.STEALTH({ "850.000", "w", "1.0000" }, clpc)
r = noise(cl, at_cl, 1, cl, 1.0, "Noise")
check(r == 1.0 and stealth.stats.host_quieter == 1, "copy quieter than owner: never raised")
r = noise(cl, at_cl, 1, cl, 2000, "Noise")
check(r == 850 and stealth.stats.capped == 3, "stale sprint (2000) lowered to owner's walk (850)")
r = noise(cl, at_cl, 1, cl, 1500, "Noise")
check(r == 1500, "whistle noise of the client untouched")
r = noise(hostpawn, { X = 0, Y = 0, Z = 90 }, 1, hostpawn, 2000 / 1.5, "Noise")
check(r == 2000 / 1.5, "host's own footstep untouched")
r = noise(cl, { X = 500, Y = 0, Z = 0 }, 1, cl, 150, "Noise")
check(r == 150, "client's landing noise untouched")
CFG.stealth_sync = false
advance(1); stealth.tick()
local s_before = stealth.stats.host.s
r = noise(cl, at_cl, 1, cl, 2000, "Noise")
check(r == 2000, "stealth_sync=false: host keeps the game's value")
-- 2026-11-13 (critic B6): the host's noise hook serves only the cap; with
-- stealth_sync off it does not even look at the step (the trace has its own hook)
check(stealth.stats.host.s == s_before, "stealth_sync=false: the host's noise hook is passive (trace on)")
CFG.stealth_sync = nil
advance(1); stealth.tick()
check(stealth.stats.host.s >= 1 and stealth.stats.host.r >= 1 and stealth.stats.host.c >= 2, "host copy steps classified by kind")
check(stealth.stats.cap_pairs["r>c"] == 1 and stealth.stats.cap_pairs["s>w"] == 1 and stealth.stats.cap_pairs["0>c"] == 1, "cap pairs counted")
HANDLERS.STEALTH({ "0.871", "c", "1.1480" }, clpc)
local capped0 = stealth.stats.capped
r = noise(cl, at_cl, 1, cl, 1.0, "Noise")
check(r == 1.0 and stealth.stats.capped == capped0, "both inaudible: crouched copy step left alone")

-- trace
local zpawn = new("BP_Zombie_Roamer_C_1", {})
local zctrl = new("BP_ZombieRoamer_AIController_C_1", { Pawn = zpawn })
local function perceive(actor, tag, sensed, from, strength)
    local st = { Tag = fname(tag), bSuccessfullySensed = sensed, StimulusLocation = from or at_cl,
                 ReceiverLocation = { X = 500, Y = 240, Z = 90 }, Strength = strength or 1 }
    HOOKS[PERC].pre(param(zctrl), param(actor), param(st))
end
local n0 = #LOG
perceive(cl, "None", true)
check(#LOG == n0 + 1 and LOG[#LOG]:find("noticed client Friend by sight at 2.4 m", 1, true) ~= nil, "trace: sight line with distance")
perceive(cl, "None", true)
check(#LOG == n0 + 1, "trace: repeat within 10 s throttled")
perceive(cl, "Noise", true)
check(LOG[#LOG]:find("by hearing 'Noise'", 1, true) ~= nil, "trace: hearing line")
perceive(hostpawn, "None", true)
check(LOG[#LOG]:find("noticed host by sight", 1, true) ~= nil, "trace: host perception logged")
local other_z = new("BP_Zombie_Roamer_C_2", {})
local n1 = #LOG
perceive(other_z, "None", true)
check(#LOG == n1, "trace: perceptions of non-players ignored")
advance(11)
perceive(cl, "None", true)
check(LOG[#LOG]:find("noticed client Friend by sight", 1, true) ~= nil, "trace: logged again after 10 s")
check(stealth.stats.seen == 4 and stealth.stats.heard == 1, "trace counters")
perceive(cl, "None", true, nil, 18.5)
check(LOG[#LOG]:find("by damage? (strength 18.5)", 1, true) ~= nil and stealth.stats.seen == 4, "trace: damage stimulus not counted as sight")

-- respawn on the host: owner value dropped
local cl2 = new("BP_PlayerCharacter_C_client2", { _loc = at_cl })
clpc._p.Pawn = cl2
advance(1); stealth.tick()
r = noise(cl2, at_cl, 1, cl2, 2000, "Noise")
check(r == 2000, "new client character: old owner value not applied")
HANDLERS.STEALTH({ "1.000", "c", "1.0000" }, clpc)
r = noise(cl2, at_cl, 1, cl2, 850, "Noise")
check(r == 1.0, "new report applies to the new character")
-- old character's address no longer mapped
r = noise(cl, at_cl, 1, cl, 2000, "Noise")
check(r == 2000, "old character no longer capped")

-- client left
S.remote_pcs = {}
advance(1); stealth.tick()
r = noise(cl2, at_cl, 1, cl2, 2000, "Noise")
check(r == 2000, "no remote players: hook passive")

-- bad messages
S.remote_pcs = { clpc }
advance(1); stealth.tick()
local before = stealth.stats.received
HANDLERS.STEALTH({ "nan", "c" }, clpc)
HANDLERS.STEALTH({ "-1", "c" }, clpc)
HANDLERS.STEALTH({ "1e9", "c" }, clpc)
check(stealth.stats.received == before, "invalid ranges rejected")
HANDLERS.STEALTH({ "1.000", "c", "1.0000" }, clpc)
r = noise(cl2, at_cl, 1, cl2, 850, "Noise")
check(r == 1.0, "cap active again")
HANDLERS.STEALTH({ "0.000", "0", "0.0000" }, clpc)
r = noise(cl2, at_cl, 1, cl2, 850, "Noise")
check(r == 850, "owner report 0 (no limit in its game) clears the cap")

-- role change resets
S.role = "client"
advance(1); stealth.tick()
check(LOG[#LOG - 1]:find("stealth: reset (role)", 1, true) ~= nil or LOG[#LOG]:find("stealth: reset (role)", 1, true) ~= nil
    or (function() for i = #LOG, math.max(1, #LOG - 5), -1 do if LOG[i]:find("reset (role)", 1, true) then return true end end return false end)(),
    "role change resets")
print(stealth.status_line())

-- hook never throws on garbage
local ok = pcall(function() HOOKS[NOISE].pre(nil, nil, nil, nil, nil, nil, nil) end)
check(ok, "noise hook survives nil params")
ok = pcall(function() HOOKS[PERC].pre(nil, nil, nil) end)
check(ok, "perception hook survives nil params")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
