-- SDCoop AI feature ai_keep_chase (host): a zombie that loses sight of one
-- player keeps chasing another target it still sees.
--
-- BP_ZombieAIController.PerceptionUpdate(Actor, Stimulus): a sight stimulus
-- no longer sensed for an actor tagged ZombieCanAttack (@541-984) clears
-- CanSeePlayer?, AttackTarget and Combat and sets IsAlert? and
-- LastHeardLocation (go and look where that actor vanished), whoever else
-- the zombie still sees. The perception system does not report a player who
-- stays in view again, so in co-op the zombie walked past the player in front
-- of it to the spot where the other one left its sight.
-- Fix (post-hook, host, while a client is connected): after that branch ran
-- (Combat and CanSeePlayer? false), if the controller's AIPerception still
-- perceives by sight a living actor tagged ZombieCanAttack (living as the
-- game's "AI Is Dead?" reads it: a corpse stays in sight), CanSeePlayer? and
-- Combat are set back (what the sight-gained branch sets, @1778-1882) and
-- IsAlert? is cleared; BTTask_FindAttackTargetLocation then picks the nearest
-- seen target itself. A zombie that sees nobody else, hearing, damage and
-- gained stimuli, and single player are left as they are.
-- Nothing is kept: the controller and the actors come from the hook.

local ue = require("sdc_ue")
local ctx = require("sdc_ctx")

local M = { stats = { lost = 0, kept = 0, alone = 0 } }
local core

local CTRL = "/Game/AI/Zombies/BP_ZombieAIController.BP_ZombieAIController_C"
local SIGHT = "/Script/AIModule.AISense_Sight"
local BB_LIB = "/Script/AIModule.Default__AIBlueprintHelperLibrary"
local TARGET_TAG = "ZombieCanAttack"
local HEARING = { Noise = true, LoudNoise = true }   -- the game's noise tags

local function m_perceived(perc, sense, out) perc:GetCurrentlyPerceivedActors(sense, out) end
local function m_get_bool(bb, key) return bb:GetValueAsBool(key) end
local function m_set_bool(bb, key, v) bb:SetValueAsBool(key, v) end
local function m_blackboard(lib, ctrl) return lib:GetBlackboard(ctrl) end
local function m_perception(ctrl) return ctrl:GetAIPerceptionComponent() end
local function f_sensed(st) return st.bSuccessfullySensed end
local function f_tag(st) return st.Tag end
local function f_strength(st) return st.Strength end

local function blackboard(ctrl)
    local lib = ue.find_object(BB_LIB)
    local bb = lib and ue.try(m_blackboard, lib, ctrl)
    if ue.valid(bb) then return bb end
    bb = ue.prop(ctrl, "Blackboard")
    if ue.valid(bb) then return bb end
    return nil
end

-- Dead the way the game's own BP_AIInterface "AI Is Dead?" reads it (the
-- sight-gained branch @397-536, BTTask_FindAttackTargetLocation): players
-- PlayerDead?, bosses IsDead?, animals / zombies Dead, Smart AI humans
-- BP_AIComponent.Dead (BP_MasterAICharacter:91; a scavenger's Death keeps
-- ZombieCanAttack and adds no 'Dead' tag), and the 'Dead' tag (bandits, traders).
local function is_dead(a)
    if core.has_tag(a, "Dead") then return true end
    if ue.prop(a, "PlayerDead?") == true or ue.prop(a, "IsDead?") == true or ue.prop(a, "Dead") == true then
        return true
    end
    return ue.prop(ue.prop(a, "BP_AIComponent"), "Dead") == true
end

-- A living actor tagged ZombieCanAttack the controller sees right now (the
-- lost one is not among them any more; skipped anyway), or nil.
local function seen_target(ctrl, lost_a)
    local perc = ue.prop(ctrl, "AIPerception")
    if not ue.valid(perc) then perc = ue.try(m_perception, ctrl) end
    local sense = ue.find_object(SIGHT)
    if not ue.valid(perc) or not sense then return nil end
    local out = {}
    if not pcall(m_perceived, perc, sense, out) then return nil end
    for _, e in ipairs(out) do
        local a = ue.elem(e)
        if ue.valid(a) and ctx.addr(a) ~= lost_a and core.has_tag(a, TARGET_TAG) and not is_dead(a) then
            return a
        end
    end
    return nil
end

-- BP_ZombieAIController.PerceptionUpdate(Actor, Stimulus), post (host).
local function on_perception(c, actor_p, stim_p)
    if not core.host.active then return end
    local st = ue.param(stim_p)
    if st == nil or ue.try(f_sensed, st) == true then return end
    if HEARING[ue.str(ue.try(f_tag, st))] then return end
    -- sight only (the game's branch runs for AISense_Sight, @180-248): a lost
    -- sight stimulus keeps its strength 1, an expired damage one the damage
    -- (as sdc_stealth tells them apart; an unreadable strength counts as sight)
    local strength = ue.try(f_strength, st)
    if type(strength) == "number" and math.abs(strength - 1) > 1e-3 then return end
    local actor = ue.param(actor_p)
    if not ue.valid(actor) or not core.has_tag(actor, TARGET_TAG) then return end
    local ctrl = ue.param(c)
    if not ue.valid(ctrl) or ue.prop(ctrl, "Combat") == true then return end
    local z = ue.prop(ctrl, "Pawn")
    if not ue.valid(z) or ue.prop(z, "IsDead?") == true then return end
    local bb = blackboard(ctrl)
    if not bb then return end
    local can_see = FName("CanSeePlayer?")
    local ok, v = pcall(m_get_bool, bb, can_see)
    if not ok or v == true then return end
    -- the sight-lost branch ran for `actor`
    M.stats.lost = M.stats.lost + 1
    local t = seen_target(ctrl, ctx.addr(actor))
    if not t then
        M.stats.alone = M.stats.alone + 1
        return
    end
    if not pcall(m_set_bool, bb, can_see, true) then return end
    pcall(m_set_bool, bb, FName("IsAlert?"), false)
    ue.set_prop(ctrl, "Combat", true)
    M.stats.kept = M.stats.kept + 1
    local say = core.line("chase.kept", 5)
    if say then
        say("ai: chase: %s lost sight of %s but still sees %s: keeps chasing (CanSeePlayer? and Combat back,"
            .. " IsAlert? off)", ue.short(z), ue.short(actor), ue.short(t))
    end
end

function M.init(c)
    core = c
    core.hook({ path = CTRL .. ":PerceptionUpdate", kind = "bp", role = "host", feature = "chase",
                name = "chase.perception", fn = on_perception })
end

function M.status_line()
    local s = M.stats
    return string.format("ai: chase sight lost=%d kept chasing another target=%d nobody else seen=%d",
        s.lost, s.kept, s.alone)
end

M._t = { on_perception = on_perception, seen_target = seen_target }

return M
