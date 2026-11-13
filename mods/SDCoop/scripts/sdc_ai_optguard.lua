-- SDCoop AI feature ai_client_optimizer_guard (client; off by default: it
-- needs an in-game test): this client's own AI optimizer leaves the host's
-- AI copies alone while this client's character is dead.
--
-- Every machine runs the AI Optimization plugin on what it has: on a client
-- the host's zombies / animals are its subjects. When the client's character
-- dies (the server runs AfterDeath, @1280-1310: its invoker off, the
-- controller unpossesses) every subject here ends up "beyond the last layer"
-- and BP_MasterZombie's handler calls K2_DespawnSubject (@15045, no
-- authority check) on the host's copies: client_3p 2026-11-12 18:53:01
-- death, 18:53:06 38 copies despawned by this client's optimizer.
-- Variant: the subject component's own switch, only on this client and only
-- while its character is dead. The tick sees its living character die (the
-- body dead, nothing else possessed), then every host copy of
-- BP_MainEnemy_C / BP_Animal_C / BP_MasterAICharacter_C / BP_MainFriendly_C
-- here gets AIOSubject.SetCanBeUpdatedBySubsystem
-- (false) (the bCanBeUpdatedBySubsystem property if the call fails), again
-- every second for copies that came in. A zombie, boss or Smart AI human copy
-- that comes into net range while this player is dead (the chasers walking
-- up to the body arrive as new copies) gets it at once, in a post-hook on its
-- master class's ReceiveBeginPlay (BP_MasterZombie, BP_ZombieBoss,
-- BP_MasterAICharacter: every child calls it or has none of its own): its
-- AIOSubject registered in that BeginPlay, the optimizer has not updated it
-- yet. Once a living character is this client's pawn again, the same copies
-- get true back; so they do when the feature is turned off while this
-- player is dead (M.off: sdc_ai on its on -> off, or this module's loop).
-- The tick: sdc_session's client ticks - and sdc_ai's with them - stop while
-- this client's character is dead (the death screen counts as
-- ue.in_main_menu(): no character on the PersistentLevel map; client_3p
-- 2026-11-12: "state: main menu" 18:53:02 at the death, "state: in game"
-- 18:53:47 at the respawn, no c:ai part in between). So this module also
-- runs its own 1 s game-thread loop (ue.every): it does nothing unless the
-- feature is on and this machine is a client.
-- A pre-hook on K2_DespawnSubject only logs each host copy this client's
-- optimizer still despawns (and whether it was frozen).
-- Not covered (logged only): despawns in normal play (animals with short
-- layers, fast vehicles). The copies 122-150 m away whose movement this
-- client's optimizer switches off (layer 3): sdc_ai_farmove. Rejected: Subject = nil in K2_DespawnSubject (how
-- the plugin takes a null subject is unknown); re-registering the dead
-- body's invoker (UnregisterInvoker runs on the server, not here).
-- Kept: names (strings) and clocks.

local log = require("sdc_log")
local ue = require("sdc_ue")
local ctx = require("sdc_ctx")
local cfg = require("sdc_config")

local M = { stats = { deaths = 0, frozen = 0, born = 0, back = 0, failed = 0, despawns = 0, despawns_frozen = 0 } }
local core

local KEY = "ai_client_optimizer_guard"
local DESPAWN_FN = "/Script/AIOptimizer.AIOptimizerSubsystem:K2_DespawnSubject"
local ENEMY_CLASS = "/Game/AI/Other/BP_MainEnemy.BP_MainEnemy_C"
-- Smart AI humans (bandits, traders, Coyote soldiers, scavengers) and
-- civilians (BP_RandomCivilian): the same OnOptimizationUpdate ->
-- K2_DespawnSubject handler (BP_MasterBandit:218, BP_MasterTrader:207,
-- BP_MasterScavenger:195, BP_RandomCivilian:38)
local HUMAN_CLASS = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C"
local FRIENDLY_CLASS = "/Game/AI/Other/BP_MainFriendly.BP_MainFriendly_C"
local PASS_S = 0.5               -- while dead: a pass on every tick (1 s apart)
local LOOP_MS = 1000             -- this module's own loop (see the header)

local clock = os.clock
local own = { name = nil, alive = false }   -- this client's living character (full name)
local frozen = {}                           -- [host copy full name] = true, false: no switch (not retried)
local frozen_n = 0
local dead_since = nil
local pass_at = -1000

local function m_owner(o) return o:GetOwner() end

-- AIOSubject.SetCanBeUpdatedBySubsystem(on), else the property itself.
local function set_updates(a, on)
    local comp = ue.prop(a, "AIOSubject")
    if not ue.valid(comp) then return false end
    if ue.call(comp, "SetCanBeUpdatedBySubsystem", on) then return true end
    return ue.set_prop(comp, "bCanBeUpdatedBySubsystem", on)
end

-- fn(actor, key) for every host copy (not this machine's own actor) of the AI classes.
local function each_copy(fn)
    for _, path in ipairs({ ENEMY_CLASS, core.ANIMAL_CLASS, HUMAN_CLASS, FRIENDLY_CLASS }) do
        local out = ue.actors_of(path)
        if type(out) == "table" then
            for i = 1, #out do
                local a = ue.elem(out[i])
                if ue.valid(a) and ue.role(a) ~= ue.ROLE_AUTHORITY then fn(a, ue.name(a)) end
            end
        end
    end
end

-- One host copy kept from the optimizer: true; false when it has no switch
-- (recorded only when `record_fail`: not retried).
local function freeze_one(a, key, record_fail)
    if set_updates(a, false) then
        frozen[key] = true
        frozen_n = frozen_n + 1
        M.stats.frozen = M.stats.frozen + 1
        return true
    end
    if record_fail then
        frozen[key] = false
        M.stats.failed = M.stats.failed + 1
    end
    return false
end

local function freeze_pass(now)
    pass_at = now
    local n, failed = 0, 0
    each_copy(function(a, key)
        if frozen[key] ~= nil then return end
        if freeze_one(a, key, true) then n = n + 1 else failed = failed + 1 end
    end)
    if n > 0 or failed > 0 then
        log.info("ai: optimizer guard: %d host AI cop%s here no longer updated by this client's AI optimizer while"
            .. " this player is dead (%d in all%s)", n, n == 1 and "y" or "ies", frozen_n,
            failed > 0 and string.format(", %d without an AIOSubject switch", failed) or "")
    end
end

-- Every frozen host copy still here is updated by the optimizer again; the
-- dead state ends. Returns how many got it back and how many were frozen.
local function restore()
    local had, n = frozen_n, 0
    if had > 0 then
        each_copy(function(a, key)
            if frozen[key] and set_updates(a, true) then n = n + 1 end
        end)
    end
    M.stats.back = M.stats.back + n
    frozen, frozen_n, dead_since = {}, 0, nil
    return n, had
end

local function hand_back(now, who)
    local since = now - dead_since
    local n, had = restore()
    log.info("ai: optimizer guard: new character %s after %.0f s dead: %d of %d frozen host AI copies updated by this"
        .. " client's AI optimizer again (the others are gone)", ue.short(who), since, n, had)
end

-- This client's living character as its pawn, or nil.
local function live_own()
    local p = ue.local_pawn()
    if p and ue.class_name(p) == ue.PLAYER_CHAR and not ctx.is_dead_player(p) then return p end
    return nil
end

local function find_char(name)
    for _, o in ipairs(ue.player_chars(true)) do
        if ue.valid(o) and ue.name(o) == name then return o end
    end
    return nil
end

-- AIOptimizerSubsystem.K2_DespawnSubject(..., Subject, ...), pre (client):
-- evidence only (the subject found by value).
local function on_despawn(_, ...)
    for i = 1, select("#", ...) do
        local o = ue.param((select(i, ...)))
        if ue.valid(o) and ue.class_name(o):find("AIOSubjectComponent", 1, true) then
            local owner = ue.try(m_owner, o)
            if ue.valid(owner) and ue.role(owner) ~= ue.ROLE_AUTHORITY then
                local was = frozen[ue.name(owner)] == true
                M.stats.despawns = M.stats.despawns + 1
                if was then M.stats.despawns_frozen = M.stats.despawns_frozen + 1 end
                local say = core.line("optguard.despawn", 10)
                if say then
                    say("ai: optimizer guard: this client's AI optimizer despawns the host's %s (beyond its last"
                        .. " layer)%s", ue.short(owner), was and " although frozen" or "")
                end
            end
            return
        end
    end
end

-- <BP_MasterZombie | BP_ZombieBoss | BP_MasterAICharacter>.ReceiveBeginPlay,
-- post (client): a host copy that came in while this player is dead is kept
-- from the optimizer at once. A copy without a switch yet is left to the
-- next pass.
local function on_born(c)
    if not dead_since then return end
    local a = ue.param(c)
    if not ue.valid(a) or ue.role(a) == ue.ROLE_AUTHORITY then return end
    local key = ue.name(a)
    if frozen[key] ~= nil or not freeze_one(a, key, false) then return end
    M.stats.born = M.stats.born + 1
    local say = core.line("optguard.born", 5)
    if say then
        say("ai: optimizer guard: %s came into range while this player is dead: kept from this client's AI optimizer"
            .. " from its BeginPlay on (%d in all)", ue.short(a), frozen_n)
    end
end

-- The feature turned off (sdc_ai on its on -> off; this module's loop when
-- the key goes off while this player is dead, before sdc_ai ticks again):
-- every frozen copy still here is the optimizer's again. On again while still
-- dead: its first tick sees the death again.
function M.off()
    if not dead_since and frozen_n == 0 then return end
    local n, had = restore()
    if own.name then own.alive = true end
    log.info("ai: optimizer guard turned off while this player is dead: %d of %d frozen host AI copies updated by"
        .. " this client's AI optimizer again", n, had)
end

function M.client_tick(now)
    local p = live_own()
    if p then
        if dead_since then hand_back(now, p) end
        own.name, own.alive = ue.name(p), true
        return
    end
    if not own.alive then
        if dead_since and now - pass_at >= PASS_S then freeze_pass(now) end
        return
    end
    -- the living character is not the pawn any more: dead, or seated elsewhere
    local body = own.name and find_char(own.name)
    if body and not ctx.is_dead_player(body) then return end
    if not body and ue.local_pawn() then return end
    own.alive = false
    dead_since = now
    M.stats.deaths = M.stats.deaths + 1
    log.info("ai: optimizer guard: this player's character %s died: the host's AI copies here are kept from this"
        .. " client's AI optimizer until the new character is in", body and ue.short(body) or tostring(own.name))
    freeze_pass(now)
end

-- This module's own loop (1 s): the tick while sdc_ai's does not come.
local function loop()
    if not core or core.S.role ~= "client" or not core.on("optguard") then return end
    if cfg.get(KEY) ~= true then
        M.off()
        return
    end
    M.client_tick(clock())
end

function M.init(c)
    core = c
    core.hook({ path = DESPAWN_FN, kind = "pre", role = "client", feature = "optguard",
                name = "optguard.despawn", fn = on_despawn })
    for _, cls in ipairs({ core.ZM, core.BOSS, HUMAN_CLASS .. ":" }) do
        core.hook({ path = cls .. "ReceiveBeginPlay", kind = "bp", role = "client", feature = "optguard",
                    name = "optguard.born", fn = on_born })
    end
    local ok, err = pcall(ue.every, "ai-optguard", LOOP_MS, loop)
    if not ok then log.warn("ai: optimizer guard: no loop of its own (%s): it acts only while sdc_ai ticks", tostring(err)) end
end

-- World / role change: the copies of the old world go with it (nothing is
-- touched here: sdc_ai's reset drops tables only).
function M.reset()
    own = { name = nil, alive = false }
    frozen, frozen_n, dead_since, pass_at = {}, 0, nil, -1000
end

function M.status_line()
    local s = M.stats
    return string.format("ai: optimizer guard deaths=%d copies frozen=%d (at arrival %d) handed back=%d no switch=%d"
        .. " | host copies despawned here=%d (frozen ones %d)%s", s.deaths, s.frozen, s.born, s.back, s.failed,
        s.despawns, s.despawns_frozen, dead_since and string.format(" | dead now, %d frozen", frozen_n) or "")
end

M._t = { on_despawn = on_despawn, on_born = on_born, loop = loop, frozen = function() return frozen end,
         own = function() return own end }

return M
