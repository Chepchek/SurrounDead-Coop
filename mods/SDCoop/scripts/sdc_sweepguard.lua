-- SDCoop: the game's "remove every player character" sweeps (host).
--
-- SurrounDead is single-player at heart. Before its own respawn, suicide,
-- save load or quit, three screens clear the world of player characters:
--   RespawnScreen  @26 respawn at the spawn point, @2636 random respawn,
--                  @2091 quit to the menu
--   PauseScreen    @2564 suicide ("stuck"), @118 quit to the menu
--   SaveMenu       @78 load a save
-- each GetAllActorsOfClass(self, BP_PlayerCharacter_C) and, for every one,
-- ClearUI() + K2_DestroyActor() (SaveMenu: DestroyActors(), which is
-- K2_DestroyActor). Then Svr_RequestRespawn_* / Event_LoadLevel.
-- On a listen server the host has authority over every character, so the
-- HOST's own respawn destroyed the clients' characters as well (runs at 13:23
-- and 13:30: the client's PC pawn=<none>, its character ctrl=<none> at
-- 0,0,0, exactly like the host's old body). On a client the same loop is
-- harmless: a client cannot destroy replicated actors.
--
-- Fix, on the host while remote players are connected: a native pre-hook on
-- GameplayStatics:GetAllActorsOfClass. When one of those screens asks for
-- BP_PlayerCharacter_C, the hook does the screen's per-character step
-- (ClearUI + K2_DestroyActor) itself for the host's own characters only (the
-- host's body, living or dead, and bodies nobody else owns), then passes a
-- None world context on to the engine, which returns an empty list for it
-- (GetWorldFromContextObject LogAndReturnNull: one LogScript warning). The
-- screen's loop then has nothing to do and the rest of its flow
-- (Svr_RequestRespawn_*, loading the menu) runs unchanged. Remote players'
-- characters, alive or dead, are never touched.
--   * not the class argument: UE4SS ignores nil for a class parameter
--     (push_classproperty) and any other class could have instances;
--   * not filtering the out array in a post-hook: out parameters of native
--     hooks are not reliable in this UE4SS build.
--
-- Diagnostics: every BP_PlayerCharacter sweep while remote players are
-- connected is logged with its caller (a caller that is not guarded is a
-- warning), and a remote player whose living character disappears or gets
-- unpossessed is logged within a second ("guard: ... lost their living
-- character").

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local players = require("sdc_players")

local M = {
    stats = { sweeps = 0, guarded = 0, kept = 0, removed = 0, unguarded = 0, lost = 0 },
}

local SWEEP_FN = "/Script/Engine.GameplayStatics:GetAllActorsOfClass"
local CHAR_PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local CHAR_CLASS = "BP_PlayerCharacter_C"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"
-- callers whose loop is "for each: ClearUI(); K2_DestroyActor()"
local GUARDED = { RespawnScreen_C = true, PauseScreen_C = true, SaveMenu_C = true }
local UNGUARDED_REPEAT_S = 60

local S
local hooked = false
local active = false
local busy = false
local char_addr = nil
local remote_bodies = {}   -- [address] = { obj =, name = }: characters a remote player had (alive or dead)
local watch = {}           -- [record key] = { pawn =, addr =, short =, alive = }
local last_sweep = nil     -- { at = os.clock(), caller =, kept = n }
local warned = {}          -- [caller] = os.clock() of the last "not guarded" warning

local function enabled()
    return cfg.get("guard_player_sweeps") ~= false
end

-- Not destroyed. UE4SS's own IsValid stays true for a destroyed actor until
-- the garbage collector runs (and ksl:IsValid(o) would call that same Lua
-- method), so the engine's KismetSystemLibrary.IsValid is called through its
-- UFunction object: fn(context, object).
local isvalid_fn, isvalid_broken = nil, false
local function live(o)
    if not ue.valid(o) then return false end
    if isvalid_broken then return true end
    local k = ue.ksl()
    isvalid_fn = isvalid_fn or ue.find_object(KSL_ISVALID)
    if not k or not isvalid_fn then return true end
    local ok, v = pcall(isvalid_fn, k, o)
    if not ok or type(v) ~= "boolean" then
        isvalid_broken = true
        log.warn("guard: KismetSystemLibrary.IsValid from Lua failed (%s); destroyed characters are not told apart from live ones", tostring(v))
        return true
    end
    return v
end

local function is_dead(p)
    local f = players.helpers and players.helpers.is_dead
    if f then return f(p) end
    return ue.prop(p, "PlayerDead?") == true
end

local function world_addr(o)
    local ok, w = pcall(function() return o:GetWorld() end)
    if ok and ue.valid(w) then return ctx.addr(w) end
    return nil
end

local function remote_pcs()
    local m = {}
    for _, r in pairs(S and S.remote or {}) do
        local a = ue.valid(r.pc) and ctx.addr(r.pc)
        if a then m[a] = r end
    end
    return m
end

-- "remote", name | "host" | "other", controller class
local function owner_of(ch, rpcs, lpa)
    local a = ctx.addr(ch)
    local c = ue.prop(ch, "Controller")
    if ue.valid(c) then
        local ca = ctx.addr(c)
        local r = ca and rpcs[ca]
        if r then return "remote", r.name end
        if ca and ca == lpa then return "host" end
        if ue.valid(ue.prop(c, "NetConnection")) then return "remote", ue.short(c) end
        return "other", ue.class_name(c)
    end
    local rb = a and remote_bodies[a]
    if rb then return "remote", rb.name end
    for _, r in pairs(S.remote or {}) do
        if ue.valid(r.pawn) and ctx.addr(r.pawn) == a then return "remote", r.name end
    end
    -- nobody's: the host's own (dead) body, which the game removes anyway
    return "host"
end

-- The player characters the screen would get: live ones of the host's world
-- (a widget has no GetWorld in UE4SS; the host's controller is in the same
-- world). Default objects and other worlds' leftovers are skipped.
local function characters(lpc)
    local wa = lpc and world_addr(lpc)
    local list = {}
    for _, ch in ipairs(ue.find_all(CHAR_CLASS)) do
        if live(ch) and not ue.short(ch):find("^Default__") then
            local ca = world_addr(ch)
            if (wa and ca == wa) or (not wa and ca) then list[#list + 1] = ch end
        end
    end
    return list
end

local function sweep(wco_p, caller)
    M.stats.sweeps = M.stats.sweeps + 1
    local lpc = ue.local_pc()
    local lpa = lpc and ctx.addr(lpc)
    local rpcs = remote_pcs()
    local keep, mine, other = {}, {}, {}
    local listed = {}
    for _, ch in ipairs(characters(lpc)) do
        local who, name = owner_of(ch, rpcs, lpa)
        local a = ctx.addr(ch)
        if a then listed[a] = true end
        if who == "remote" then
            keep[#keep + 1] = string.format("%s of %s", ue.short(ch), tostring(name))
        elseif who == "host" then
            mine[#mine + 1] = ch
        else
            other[#other + 1] = string.format("%s (controller %s)", ue.short(ch), tostring(name))
        end
    end
    -- whatever the object list missed: remote players' characters straight
    -- from their records, the host's own from its controller
    for _, r in pairs(S.remote or {}) do
        local cur = ue.valid(r.pc) and ue.pawn_of(r.pc) or false
        for _, p in ipairs({ cur, r.pawn or false }) do
            local a = p and live(p) and ctx.addr(p)
            if a and not listed[a] then
                listed[a] = true
                keep[#keep + 1] = string.format("%s of %s", ue.short(p), tostring(r.name))
            end
        end
    end
    local me = lpc and ue.pawn_of(lpc)
    local ma = live(me) and ctx.addr(me)
    if ma and not listed[ma] then mine[#mine + 1] = me end
    last_sweep = { at = os.clock(), caller = caller, kept = #keep }
    if not GUARDED[caller] then
        if #keep > 0 then
            M.stats.unguarded = M.stats.unguarded + 1
            local now = os.clock()
            if not warned[caller] or now - warned[caller] >= UNGUARDED_REPEAT_S then
                warned[caller] = now
                log.warn("guard: %s asks for every player character while remote players' ones exist (%s); not one of the guarded screens, left as is",
                    caller, table.concat(keep, ", "))
            end
        end
        return
    end
    if #keep == 0 and #other == 0 then
        log.info("guard: %s removes the player characters: only the host's (%d), nothing to keep", caller, #mine)
        return
    end
    -- the screen's own step, for the host's characters only
    local removed = {}
    for _, ch in ipairs(mine) do
        local n = ue.short(ch)
        local okc = pcall(function() ch:ClearUI() end)
        local okd = pcall(function() ch:K2_DestroyActor() end)
        removed[#removed + 1] = n .. ((okc and okd) and "" or string.format(" (ClearUI ok=%s, destroy ok=%s)", tostring(okc), tostring(okd)))
    end
    -- and the screen's own loop gets an empty list
    local okn, err = pcall(function() wco_p:set(nil) end)
    M.stats.guarded = M.stats.guarded + 1
    M.stats.kept = M.stats.kept + #keep + #other
    M.stats.removed = M.stats.removed + #removed
    if okn then
        log.info("guard: %s was about to remove every player character: kept %d of remote players [%s]%s, removed the host's own %d [%s] itself; the screen's loop got an empty list",
            caller, #keep, table.concat(keep, ", "),
            #other > 0 and (", kept " .. #other .. " with another controller [" .. table.concat(other, ", ") .. "]") or "",
            #removed, table.concat(removed, ", "))
    else
        log.err("guard: %s: could not empty its list (%s); the game removes remote players' characters now [%s]",
            caller, tostring(err), table.concat(keep, ", "))
    end
end

local function on_sweep(wco_p, cls_p)
    if not active or busy then return end
    local cls = cls_p:get()
    if cls == nil then return end
    local ca = ctx.addr(cls)
    if not ca then return end
    if not char_addr then
        local c = ue.find_object(CHAR_PATH)
        char_addr = c and ctx.addr(c)
        if not char_addr then return end
    end
    if ca ~= char_addr then return end
    local wco = wco_p:get()
    local caller = ue.class_name(wco)
    if caller == "" then caller = "<no context>" end
    busy = true
    local ok, err = pcall(sweep, wco_p, caller)
    busy = false
    if not ok then log.err_throttled("guard-sweep", "guard: %s sweep: %s", caller, tostring(err)) end
end

local function install_hook()
    if hooked then return end
    if not ue.find_object(SWEEP_FN) then return end
    hooked = true
    -- shared pre-only engine hook (sdc_ue.hook_native): the game calls
    -- GetAllActorsOfClass ~100 times a second; no empty post callback
    local ok, err = ue.hook_native(SWEEP_FN, "sweepguard", function(_, wco_p, cls_p)
        if not active or busy then return end
        local okc, e = pcall(on_sweep, wco_p, cls_p)
        if not okc then
            busy = false
            log.err_throttled("guard-hook", "guard: GetAllActorsOfClass hook: %s", tostring(e))
        end
    end)
    log.info("guard: GetAllActorsOfClass pre-hook %s%s (the game's player-character sweeps keep remote players' characters)",
        ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- A remote player's living character must not disappear or lose its
-- controller without the player dying; say so when it does.
local function watch_tick()
    local seen = {}
    for key, r in pairs(S.remote or {}) do
        seen[key] = true
        local w = watch[key]
        if not w then w = {}; watch[key] = w end
        local cur = ue.valid(r.pc) and ue.pawn_of(r.pc) or nil
        local ca = cur and ctx.addr(cur)
        if w.addr and w.alive and ca ~= w.addr then
            local old_live = live(w.pawn)
            local died = old_live and is_dead(w.pawn)
            if not died then
                local ctrl = old_live and ue.prop(w.pawn, "Controller") or nil
                local state = not old_live and "destroyed"
                    or (ue.valid(ctrl) and ("now controlled by " .. ue.short(ctrl)) or "unpossessed")
                local recent = ""
                if last_sweep and os.clock() - last_sweep.at <= 5 then
                    recent = string.format("; %s swept the player characters %.1f s before (kept %d)",
                        last_sweep.caller, os.clock() - last_sweep.at, last_sweep.kept)
                end
                M.stats.lost = M.stats.lost + 1
                local line = string.format("guard: %s lost their living character %s (%s); their controller has %s%s",
                    tostring(r.name), tostring(w.short), state, cur and ue.short(cur) or "no pawn", recent)
                if cur then log.info("%s", line) else log.warn("%s", line) end
            end
        end
        if cur then
            w.pawn, w.addr, w.short, w.alive = cur, ca, ue.short(cur), not is_dead(cur)
            if ca then remote_bodies[ca] = { obj = cur, name = r.name } end
        else
            w.pawn, w.addr, w.alive = nil, nil, false
        end
        if ue.valid(r.pawn) then
            local ra = ctx.addr(r.pawn)
            if ra and not remote_bodies[ra] then remote_bodies[ra] = { obj = r.pawn, name = r.name } end
        end
    end
    for key in pairs(watch) do
        if not seen[key] then watch[key] = nil end
    end
    for a, b in pairs(remote_bodies) do
        if not ue.valid(b.obj) then remote_bodies[a] = nil end
    end
end

-- Host tick (1 s).
function M.tick()
    if not S then return end
    local want = S.role == "host" and next(S.remote or {}) ~= nil and enabled()
    if want then install_hook() end
    active = want and hooked
    if S.role == "host" then
        local ok, err = pcall(watch_tick)
        if not ok then log.err_throttled("guard-watch", "guard: watch: %s", tostring(err)) end
    else
        watch, remote_bodies = {}, {}
    end
end

function M.reset_world()
    active = false
    char_addr = nil
    watch, remote_bodies, warned = {}, {}, {}
    last_sweep = nil
end

function M.status_line()
    local s = M.stats
    return string.format("guard: hook=%s active=%s sweeps=%d guarded=%d kept=%d removed=%d unguarded=%d lost=%d",
        tostring(hooked), tostring(active), s.sweeps, s.guarded, s.kept, s.removed, s.unguarded, s.lost)
end

-- Called by sdc_respawn.install (main.lua needs no change).
local installed = false
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    if session and session.world_reset_hooks then session.world_reset_hooks.sweepguard = M.reset_world end
    if installed then return end
    installed = true
    ue.every("sweepguard", 1000, function() M.tick() end)
    log.info("guard: installed (guard_player_sweeps=%s)", tostring(enabled()))
end

return M
