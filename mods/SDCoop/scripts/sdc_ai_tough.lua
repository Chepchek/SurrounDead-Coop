-- SDCoop AI feature ai_toughness (host; off by default - a gameplay change
-- the host chooses): zombies are tougher where several players fight them.
--
-- Until now only the size of a spawner's group followed the number of
-- players (ai_player_scaling); a zombie's health and hits did not. Every hit
-- on a zombie and every zombie hit on a player ends in the host's
-- GameplayStatics.ApplyDamage (a client's shot: BP_FirearmPickup.
-- SERVER_DamageEvent -> ApplyDamage, sdc_damage; melee HitBody / HitHead; a
-- zombie's attack trace BP_MasterZombie @19328 ApplyDamage(HitActor, dmg,
-- its controller, self)). A pre-hook there (sdc_ai's shared engine hook, with
-- sdc_ffire and sdc_ai_kills), while a client is connected:
--   victim a zombie (BP_MasterZombie and children)  BaseDamage / f(health)
--   victim a player, causer a zombie                BaseDamage x f(damage)
-- f = min(cap, 1 + pct x (n - 1)), n = living players within RADIUS_CM of
-- the zombie (140 m, the spawners' trigger radius; one player: f = 1, as
-- before). Dividing the damage a zombie takes is the same as more health,
-- without touching its health values: the archetype roll, the blood moon
-- (Event_HealthMultiplier) and the health bar (CurrentHealth / StandardHealth)
-- stay the game's. Not changed: other damage paths of zombies (the
-- grenadier's blast, radiation), bosses, animals, people.
-- Kept: the players' positions (numbers) for PLAYERS_S.

local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = { stats = { hits_taken = 0, hits_dealt = 0, failed = 0 } }
local core

local APPLY_DAMAGE = "/Script/Engine.GameplayStatics:ApplyDamage"
local RADIUS_CM = 14000
local PLAYERS_S = 0.5
local DEFAULTS = { ai_toughness_health_pct = 25, ai_toughness_damage_pct = 15, ai_toughness_cap_pct = 200 }

local clock = os.clock
local players = { t = -1e9, list = {} }   -- living players' positions, PLAYERS_S old at most

local function pct(key, lo)
    local v = tonumber(cfg.get(key))
    if v == nil then v = DEFAULTS[key] end
    return math.max(lo, v) / 100
end

-- The factor for `n` players: min(cap, 1 + pct x (n - 1)).
function M.factor(n, key)
    if n < 2 then return 1 end
    return math.min(pct("ai_toughness_cap_pct", 100), 1 + pct(key, 0) * (n - 1))
end

local function players_near(loc)
    if not loc then return 0 end
    local now = clock()
    if now - players.t >= PLAYERS_S then
        local list = {}
        for _, e in ipairs(ctx.live_players()) do list[#list + 1] = { X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z } end
        players.t, players.list = now, list
    end
    local n, r2 = 0, RADIUS_CM * RADIUS_CM
    for _, p in ipairs(players.list) do
        local dx, dy, dz = p.X - loc.X, p.Y - loc.Y, p.Z - loc.Z
        if dx * dx + dy * dy + dz * dz <= r2 then n = n + 1 end
    end
    return n
end

local function set(dmg_p, v)
    if pcall(function() dmg_p:set(v) end) then return true end
    M.stats.failed = M.stats.failed + 1
    return false
end

-- GameplayStatics.ApplyDamage(DamagedActor, BaseDamage, EventInstigator, DamageCauser, DamageTypeClass), pre (host)
local function on_damage(_, victim_p, dmg_p, _, causer_p)
    if not core.host.active then return end
    local dmg = tonumber(ue.param(dmg_p))
    if not dmg or dmg <= 0 then return end
    local v = ue.param(victim_p)
    if not ue.valid(v) then return end
    if core.is_zombie(v) then
        local n = players_near(ue.location(v))
        local f = M.factor(n, "ai_toughness_health_pct")
        if f <= 1 or not set(dmg_p, dmg / f) then return end
        M.stats.hits_taken = M.stats.hits_taken + 1
        local say = core.line("tough.taken", 3)
        if say then
            say("ai: toughness: %s takes %.1f instead of %.1f damage: %d living players within %.0f m (x%.2f health)",
                ue.short(v), dmg / f, dmg, n, RADIUS_CM / 100, f)
        end
        return
    end
    if ue.class_name(v) ~= ue.PLAYER_CHAR then return end
    local z = ue.param(causer_p)
    if not ue.valid(z) or not core.is_zombie(z) then return end
    local n = players_near(ue.location(z))
    local f = M.factor(n, "ai_toughness_damage_pct")
    if f <= 1 or not set(dmg_p, dmg * f) then return end
    M.stats.hits_dealt = M.stats.hits_dealt + 1
    local say = core.line("tough.dealt", 3)
    if say then
        say("ai: toughness: %s hits %s for %.1f instead of %.1f: %d living players within %.0f m (x%.2f damage)",
            ue.short(z), ue.short(v), dmg * f, dmg, n, RADIUS_CM / 100, f)
    end
end

function M.init(c)
    core = c
    core.hook({ path = APPLY_DAMAGE, kind = "pre", role = "host", feature = "tough", name = "tough.damage",
                fn = on_damage })
end

function M.reset()
    players.t, players.list = -1e9, {}
end

function M.status_line()
    local s = M.stats
    return string.format("ai: toughness hits on zombies weakened=%d zombie hits on players strengthened=%d failed=%d",
        s.hits_taken, s.hits_dealt, s.failed)
end

M._t = { on_damage = on_damage, players_near = players_near }

return M
