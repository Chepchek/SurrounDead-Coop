-- SDCoop AI feature ai_client_far_movement (client): the host's zombies keep
-- moving smoothly on this client 122-150 m away.
--
-- Every machine runs the AI Optimization plugin on what it has; on a client
-- the host's zombie copies are its subjects too (no authority check). A
-- subject's layer comes from this client's distance to it (zombie layers 50 /
-- 75 / 122.5 / 150 / 225 m), and BP_MasterZombie's OnOptimizationUpdate
-- handler (@16540 -> @16186.. switch) sets its features for that layer:
--   L0 SetCharacterFeatures(self, 95)  everything + shadows
--   L1 31, L2 31 (CharacterMovement / Mesh tick 0.05-0.1 s)
--   L3 29: the movement bit (2) off - @15865
--   L4 28 seen / 8 unseen
-- Feature bits (AIOptimizer, work\re\SurrounDead.usmap): AIBrain 1,
-- Movement 2, Visibility 4, Collision 8, Animations 16, ActorTick 32,
-- Shadows 64. The engine's net range for characters is 150 m, so L3 is the
-- outer ring every copy crosses: there its CharacterMovement - which on a
-- copy moves it smoothly between the host's position updates - is switched
-- off by this client's optimizer, and the zombie jumps from update to update
-- (the "teleporting" far zombies; audit zombie_ai_coop_2026-11-13 A, the
-- cause not proven in game).
-- Fix: a post-hook on that handler (client, host copies only, living
-- zombies): after an L3 update the copy gets SetCharacterFeatures(self, 31),
-- the game's own L2 value (movement on; everything else as at L3; the tick
-- interval L2 set stays). L0-L2 and L4 are left alone; the host's own
-- zombies never pass here (role check). Nothing is kept.
-- Diagnostics: the first copies helped are logged; the status line counts
-- them.

local ue = require("sdc_ue")

local M = { stats = { l3 = 0, kept = 0, failed = 0 } }
local core

local FN = "BndEvt__BP_Zombie_Master_AIOSubject_K2Node_ComponentBoundEvent_2_OnOptimizationUpdate__DelegateSignature"
local L3 = 3
local L2_FEATURES = 31        -- BP_MasterZombie @16446 / @16493
M.L2_FEATURES = L2_FEATURES

local function m_set_features(comp, a, f) comp:SetCharacterFeatures(a, f) end

-- BP_MasterZombie OnOptimizationUpdate(bIsBeyondLastLayer, LayerIndex, bIsSeen), post (client)
local function on_layer(c, beyond_p, layer_p)
    if ue.param(layer_p) ~= L3 or ue.param(beyond_p) == true then return end
    local z = ue.param(c)
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY or ue.prop(z, "IsDead?") == true then return end
    M.stats.l3 = M.stats.l3 + 1
    local comp = ue.prop(z, "AIOSubject")
    if not ue.valid(comp) or not pcall(m_set_features, comp, z, L2_FEATURES) then
        M.stats.failed = M.stats.failed + 1
        local say = core.line("farmove.failed", 3)
        if say then say("ai: far movement: %s: SetCharacterFeatures failed", ue.short(z)) end
        return
    end
    M.stats.kept = M.stats.kept + 1
    local say = core.line("farmove.kept", 5)
    if say then
        say("ai: far movement: the host's %s is 122-150 m from this player: it keeps moving smoothly here (this"
            .. " client's AI optimizer had switched its movement off)", ue.short(z))
    end
end

function M.init(c)
    core = c
    core.hook({ path = core.ZM .. FN, kind = "bp", role = "client", feature = "farmove", name = "farmove.layer",
                fn = on_layer })
end

function M.status_line()
    local s = M.stats
    return string.format("ai: far movement copies at 122-150 m=%d kept moving=%d failed=%d", s.l3, s.kept, s.failed)
end

M._t = { on_layer = on_layer }

return M
