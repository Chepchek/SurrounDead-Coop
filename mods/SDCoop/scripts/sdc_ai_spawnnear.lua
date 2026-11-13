-- SDCoop AI feature ai_spawn_check_all (host): the spawners' "don't spawn
-- within 25 m of the player" counts every player, not only the host.
--
-- Each check runs a sphere query at the spawn point and compares every actor
-- it found with GetPlayerCharacter(self, 0), one call per actor:
--   BP_AISpawner_Master.TraceForPlayer (882-898): SphereOverlapActors(self,
--     Loc, DontSpawnCloseToPlayerRange = 25 m, Pawn, Character) - zombies,
--     hounds, bosses, animals, survivors (its data-only children);
--   BP_AISpawningVolume_Prefab.TraceForPlayer (477-492):
--     SphereTraceMultiForObjects(self, Loc, Loc, 2500, Pawn + PhysicsBody) - camp AI;
--   BP_PrefabSpawner.CheckSurroundingArea (40-43): SphereTraceMultiForObjects(
--     self, its location, 2500, Pawn) - camps, trucks, random events.
-- Player 0 is the host there, so a spawn point next to a client passed.
-- Fix: native pre-hooks on those two queries note where a spawner looks
-- (its address, the point, a clock). The player-0 calls that follow in the
-- same frame (sdc_ctx -> sdc_world's "spawn" scope kind -> ctx.spawn_scope)
-- get the living player nearest to that point: a client's controller, or
-- false (the host). A player within 25 m of the point is the nearest one, so
-- the game's own comparison now finds any player. Other player-0 calls of
-- these objects (BP_PrefabSpawner.DistanceToPrefab: discovery XP and the
-- minimap) come without a fresh query and stay the host's.
-- Kept: per spawner address one point and a clock (numbers), a few seconds.

local ue = require("sdc_ue")
local ctx = require("sdc_ctx")

local M = { stats = { queries = 0, host = 0, client = 0 } }
local core

local clock = os.clock
local KSL = "/Script/Engine.KismetSystemLibrary"
local FRESH_S = 0.25          -- the player-0 calls follow their query in the same frame
local KEEP_S = 5
local PREFIXES = { "BP_AISpawner_", "BP_AISpawningVolume_", "BP_PrefabSpawner" }

local at = {}            -- [spawner address] = { X, Y, Z, t, told }
local spawner_cls = {}   -- [class name] = bool

local function is_spawner(cls)
    local v = spawner_cls[cls]
    if v == nil then
        v = false
        for _, p in ipairs(PREFIXES) do
            if cls:sub(1, #p) == p then v = true break end
        end
        spawner_cls[cls] = v
    end
    return v
end

-- KismetSystemLibrary.SphereOverlapActors / SphereTraceMultiForObjects, pre
-- (host): (context, WorldContextObject, SpherePos | Start, ...).
local function on_query(_, wco_p, pos_p)
    if not core.host.active then return end
    local w = ue.param(wco_p)
    if w == nil then return end
    -- a null WorldContextObject (not nil): ctx.class_name checks its address
    -- before GetClass (which would crash the game on it) and gives ""
    local cls = ctx.class_name(w)
    if cls == "" or not is_spawner(cls) then return end
    local a = ctx.addr(w)
    local l = ue.vec(ue.param(pos_p))
    if not a or not l then return end
    at[a] = { X = l.X, Y = l.Y, Z = l.Z, t = clock() }
    M.stats.queries = M.stats.queries + 1
end

-- ctx.spawn_scope: player 0 of a spawner's GetPlayerCharacter right after
-- its query -> the living player nearest to the queried point (remote
-- controller | false for the host); nil when there was no query just now.
local function answer(wco, a)
    if not core.on("spawnnear") or core.S.role ~= "host" or not core.host.active then return nil end
    if ctx.call_fn ~= "GetPlayerCharacter" then return nil end
    local r = a and at[a]
    if not r or clock() - r.t > FRESH_S then return nil end
    local e, d = ctx.nearest_live_player(r)
    if not e then return nil end
    if not e.remote then
        if not r.told then
            r.told = true
            M.stats.host = M.stats.host + 1
        end
        return false
    end
    if not r.told then
        r.told = true
        M.stats.client = M.stats.client + 1
        local say = core.line("spawnnear.client", 8)
        if say then
            say("ai: spawn check: %s checks its spawn point %.0f,%.0f,%.0f against %s (%s, %.0f m away), the living"
                .. " player nearest to it, not the host", ue.short(wco), r.X, r.Y, r.Z, ue.short(e.pawn),
                ue.short(e.pc), d / 100)
        end
    end
    return e.pc
end

function M.init(c)
    core = c
    for _, fn in ipairs({ "SphereOverlapActors", "SphereTraceMultiForObjects" }) do
        core.hook({ path = KSL .. ":" .. fn, kind = "pre", role = "host", feature = "spawnnear",
                    name = "spawnnear." .. fn, fn = on_query })
    end
    ctx.spawn_scope = answer
end

function M.host_tick(now)
    for a, r in pairs(at) do
        if now - r.t > KEEP_S then at[a] = nil end
    end
end

function M.reset()
    at = {}
end

function M.status_line()
    local s = M.stats
    return string.format("ai: spawn check spawner queries=%d checked against the host=%d against a client=%d",
        s.queries, s.host, s.client)
end

M._t = { answer = answer, on_query = on_query, at = function() return at end, is_spawner = is_spawner }

return M
