-- SDCoop AI feature ai_player_scaling (host): a zombie spawner's group grows
-- with the living players near it.
--
-- BP_AISpawner_Master: SetSpawnCount (785-816) sets SpawnAmount (random
-- x/1.5..x1.5 times Difficulty.ZombieAmount) once per spawner, from its
-- InitSpawner's DoOnce (@195-221) - at the level's load or when the spawner
-- streams in, before any player is near it - and again only from
-- KillSpawnedActors(true), which no Blueprint of the game calls. A factor
-- applied there would not see the players. The group itself is made when an
-- invoker (a player) comes within the spawner's radius:
-- CheckStartSpawningWithRadius -> @1895 AddGroupToSpawn(SpawnAmount); full
-- respawn groups come the same way (@1366, @5697).
-- Fix (post-hook AddGroupToSpawn(AmountToSpawn), while a client is connected):
-- a spawner of zombies or hounds (SpawnedActorClass BP_Zombie_*, no boss) and
-- a full group (AmountToSpawn = SpawnAmount > 1; a killed zombie's single
-- respawn is a group of 1 and stays 1:1, so nothing compounds): with n
-- living players within the spawner's own SpawnRadius - the radius its
-- CheckStartSpawningWithRadius (@5721 IsAnyInvokerInRadius(SpawnRadius))
-- starts the group at: 140 m by default, level prefabs set their own (75 m
-- in Alternate_ZombiesObservatory); 140 m when it cannot be read -
--   f = min(cap, 1 + pct x (n - 1)),
-- and the spawner gets one more group of round(SpawnAmount x f) - SpawnAmount
-- through its own AddGroupToSpawn: queued after the first one, spawned,
-- counted, respawned and despawned by the spawner like the others.
-- SpawnAmount and the Difficulty.* console variables (saved to the player's
-- settings) are never written.
-- No bigger group while the host's world is full (ai_host_cap, sdc_ai_cap:
-- core.ai_full).
-- Nothing is kept: the spawner comes from the hook.

local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = { stats = { groups = 0, alone = 0, added = 0, zombies = 0, failed = 0, full = 0 } }
local core

local SPAWNER = "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C"
local RADIUS_CM = 14000          -- the spawners' default SpawnRadius (activation)
local adding = false             -- this module's own AddGroupToSpawn call

local function zombie_class(name)
    return name:sub(1, 10) == "BP_Zombie_" and not name:find("Boss", 1, true)
end

-- The spawner's own SpawnRadius (cm), else the default.
local function radius_of(sp)
    local r = tonumber(ue.prop(sp, "SpawnRadius"))
    if r and r > 0 then return r end
    return RADIUS_CM
end

local function pct(key, default, lo)
    local v = tonumber(cfg.get(key))
    if v == nil then v = default end
    return math.max(lo, v) / 100
end

-- The group size for n players: the factor and the extra zombies.
function M.extra_for(base, n)
    if n < 2 then return 1, 0 end
    local f = math.min(pct("ai_player_scaling_cap_pct", 200, 100), 1 + pct("ai_player_scaling_pct", 35, 0) * (n - 1))
    return f, math.max(0, math.floor(base * f + 0.5) - base)
end

-- BP_AISpawner_Master.AddGroupToSpawn(AmountToSpawn), post (host).
local function on_add_group(c, amount_p)
    if adding or not core.host.active then return end
    local sp = ue.param(c)
    if not ue.valid(sp) then return end
    local base = ue.param(amount_p)
    if type(base) ~= "number" or base < 2 or ue.prop(sp, "SpawnAmount") ~= base then return end
    local cls = ue.prop(sp, "SpawnedActorClass")
    if not ue.valid(cls) or not zombie_class(ue.short(cls)) then return end
    local loc = ue.location(sp)
    if not loc then return end
    M.stats.groups = M.stats.groups + 1
    if core.ai_full and core.on("cap") and core.ai_full() then
        M.stats.full = M.stats.full + 1
        return
    end
    local n, r = 0, radius_of(sp)
    for _, e in ipairs(ctx.live_players()) do
        local dx, dy, dz = e.loc.X - loc.X, e.loc.Y - loc.Y, e.loc.Z - loc.Z
        if dx * dx + dy * dy + dz * dz <= r * r then n = n + 1 end
    end
    local f, extra = M.extra_for(base, n)
    if extra < 1 then
        M.stats.alone = M.stats.alone + 1
        return
    end
    adding = true
    local ok = ue.call(sp, "AddGroupToSpawn", extra)
    adding = false
    if not ok then
        M.stats.failed = M.stats.failed + 1
        local say = core.line("scale.failed", 3)
        if say then say("ai: scaling: %s: AddGroupToSpawn(%d) failed", ue.short(sp), extra) end
        return
    end
    M.stats.added = M.stats.added + 1
    M.stats.zombies = M.stats.zombies + extra
    local say = core.line("scale.added", 8)
    if say then
        say("ai: scaling: %s spawns %d %s instead of %d: %d living players within %.0f m (x%.2f)", ue.short(sp),
            base + extra, ue.short(cls), base, n, r / 100, f)
    end
end

function M.init(c)
    core = c
    core.hook({ path = SPAWNER .. ":AddGroupToSpawn", kind = "bp", role = "host", feature = "scale",
                name = "scale.group", fn = on_add_group })
end

function M.status_line()
    local s = M.stats
    return string.format("ai: scaling zombie groups=%d one player=%d bigger=%d (+%d zombies) failed=%d world full=%d",
        s.groups, s.alone, s.added, s.zombies, s.failed, s.full)
end

M._t = { on_add_group = on_add_group, zombie_class = zombie_class, radius_of = radius_of }

return M
