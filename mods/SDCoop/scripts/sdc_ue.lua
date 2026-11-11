-- SDCoop: safe wrappers around the UE4SS object API.
--
-- Rules every caller relies on:
--   * Engine objects are touched ONLY on the game thread. Use M.delay /
--     M.every / M.game_thread instead of ExecuteWithDelay / LoopAsync, which
--     run on a worker thread (that is what crashed v0.1-v0.2 with
--     "Pure virtual function being called" and <unnameable> objects).
--   * A null object property comes back as an *invalid* UObject, not nil, so
--     always test with M.valid(), never with `if obj then`.

local log = require("sdc_log")

local M = {}

-- ---------------------------------------------------------------------------
-- Basic helpers
-- ---------------------------------------------------------------------------
-- The engine calls below are wrapped as pcall(f, args) with module-level
-- functions, not pcall(function() ... end): a closure (plus an upvalue per
-- captured local) per call was 80-390 bytes of Lua garbage for every
-- valid / prop / name / location - thousands of calls a second, the mod's
-- largest steady garbage source after UE4SS's own hook parameters.
local function m_is_valid(o) return o:IsValid() end
local function m_to_string(v) return v:ToString() end
local function m_full_name(o) return o:GetFullName() end
local function m_short(o) return o:GetFName():ToString() end
local function m_class_name(o) return o:GetClass():GetFName():ToString() end
local function m_get_prop(o, name) return o:GetPropertyValue(name) end
local function m_set_prop(o, name, value) o:SetPropertyValue(name, value) end
local function m_call(o, fname, ...)
    local fn = o[fname]
    return fn(o, ...)
end
local function m_field(t, k) return t[k] end
local function m_get(v) return v:get() end
local function m_is_local(pc) return pc:IsLocalController() end
local function m_is_standalone(ksl, ctx) return ksl:IsStandalone(ctx) end
local function m_is_server(ksl, ctx) return ksl:IsServer(ctx) end
local function m_level_name(gps, ctx) return gps:GetCurrentLevelName(ctx, true) end
local function m_get_world(ctx) return ctx:GetWorld() end
local function m_is_paused(gps, ctx) return gps:IsGamePaused(ctx) end
local function m_set_paused(gps, ctx, paused) gps:SetGamePaused(ctx, paused) end
local function m_ping(ps) return ps:GetPingInMilliseconds() end
local function m_get_loc(actor) return actor:K2_GetActorLocation() end
local function m_get_rot(actor) return actor:K2_GetActorRotation() end
local function m_set_loc(actor, loc) actor:K2_SetActorLocation(loc, false, {}, true) end

function M.try(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

function M.valid(o)
    if o == nil then return false end
    local t = type(o)
    if t ~= "userdata" and t ~= "table" then return false end
    local ok, v = pcall(m_is_valid, o)
    return ok and v == true
end

-- Converts FString / FText / FName / numbers to a Lua string.
function M.str(v)
    if v == nil then return "" end
    local t = type(v)
    if t == "string" then return v end
    if t == "number" or t == "boolean" then return tostring(v) end
    local ok, s = pcall(m_to_string, v)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(tostring, v)
    if ok and type(s) == "string" then return s end
    return ""
end

function M.name(o)
    if not M.valid(o) then return "<none>" end
    local ok, s = pcall(m_full_name, o)
    if ok and type(s) == "string" then return s end
    return "<?>"
end

-- Object name without class and outer path ("BP_Zombie_C_2147470001").
function M.short(o)
    if not M.valid(o) then return "<none>" end
    local ok, s = pcall(m_short, o)
    if ok and type(s) == "string" then return s end
    return (M.name(o):match("([^%.:%s]+)$")) or "<?>"
end

-- Asset path of an object ("/Game/Foo/Bar.Bar"), without the class prefix.
function M.path(o)
    local full = M.name(o)
    return full:match("^%S+%s+(.+)$") or full
end

function M.class_name(o)
    if not M.valid(o) then return "" end
    local ok, s = pcall(m_class_name, o)
    if ok and type(s) == "string" then return s end
    return ""
end

function M.prop(o, name)
    if not M.valid(o) then return nil end
    local ok, v = pcall(m_get_prop, o, name)
    if ok then return v end
    return nil
end

-- A property of an object known to be alive (a hook's own context object
-- while its function runs: a non-zero address): no validity check first.
-- Same result as M.prop for such an object; nil when the read fails.
function M.prop_live(o, name)
    if o == nil then return nil end
    local ok, v = pcall(m_get_prop, o, name)
    if ok then return v end
    return nil
end

function M.set_prop(o, name, value)
    if not M.valid(o) then return false end
    local ok = pcall(m_set_prop, o, name, value)
    return ok
end

-- Calls a reflected function, returning ok, result.
function M.call(o, fname, ...)
    if not M.valid(o) then return false, "invalid object" end
    return pcall(m_call, o, fname, ...)
end

-- Shared FindAllOf results (find_all_recent) and watched classes (below).
local recent = {}   -- [class] = { t = os.clock(), list = {...}[, addrs =, notes =] }
local watched = {}  -- [class] = watch state (M.watch_new)
local WATCH_TTL = 1.0
local function m_addr(o) return o:GetAddress() end

-- A FindAllOf result of a watched class becomes its shared list. Health
-- check of the watch: an object the previous scan did not list, with no
-- new-object notification since that scan, means UE4SS did not report it;
-- the class then goes back to the plain ttl (logged once). The first object
-- that did come with a notification is logged once too (the watch works).
local function store_watched(class_name, w, list, now)
    local addrs, copy = {}, {}
    for i = 1, #list do
        local o = list[i]
        copy[i] = o
        local ok, a = pcall(m_addr, o)
        if ok and a then addrs[a] = true end
    end
    local prev = recent[class_name]
    if prev and prev.addrs then
        for a in pairs(addrs) do
            if not prev.addrs[a] then
                if w.notes == prev.notes then
                    w.missed = w.missed + 1
                    if w.ok then
                        w.ok = false
                        log.warn("ue: a new %s was listed without a new-object notification; its shared list is"
                            .. " rescanned every 0.25 s again", class_name)
                    end
                elseif not w.confirmed then
                    w.confirmed = true
                    log.info("ue: new-object notification for %s works (a new one was listed at once)", class_name)
                end
                break
            end
        end
    end
    w.dirty = false
    recent[class_name] = { t = now, list = copy, addrs = addrs, notes = w.notes }
end

-- [PERF]: what FindAllOf costs, per class (calls, ms, objects returned).
M.find_stats = {}
function M.find_all(class_name)
    local t0 = os.clock()
    local ok, t = pcall(FindAllOf, class_name)
    if not (ok and type(t) == "table") then t = {} end
    local t1 = os.clock()
    local s = M.find_stats[class_name]
    if not s then s = { calls = 0, ms = 0, n = 0 }; M.find_stats[class_name] = s end
    s.calls, s.ms, s.n = s.calls + 1, s.ms + (t1 - t0) * 1000, s.n + #t
    -- a fresh scan of a watched class also refreshes its shared list
    local w = watched[class_name]
    if w then store_watched(class_name, w, t, t1) end
    return t
end

-- The same search shared by periodic ticks within `ttl` seconds (default
-- 0.25): several modules list BP_PlayerCharacter_C every second, some in the
-- same frame. Only for ticks that tolerate a list up to `ttl` old (callers
-- check every object with valid() anyway); never right after a spawn.
-- Returns a copy the caller may change.
-- A watched class (watch_new) is kept longer, WATCH_TTL, since a new object
-- of it marks the list dirty (rescanned on the next read); every read of it
-- leaves out (and forgets) entries that are no longer valid.
function M.find_all_recent(class_name, ttl)
    local now = os.clock()
    local r = recent[class_name]
    local w = watched[class_name]
    if w then
        local max_age = ttl or 0.25
        if w.ok and max_age < WATCH_TTL then max_age = WATCH_TTL end
        if not r or w.dirty or now - r.t >= max_age or now < r.t then
            M.find_all(class_name)   -- stores the new list (store_watched)
            r = recent[class_name]
        end
        local list, out, n = r.list, {}, 0
        local total = #list
        for i = 1, total do
            local o = list[i]
            if M.valid(o) then
                n = n + 1
                out[n] = o
                list[n] = o
            end
        end
        for i = n + 1, total do list[i] = nil end
        return out
    end
    if not r or now - r.t >= (ttl or 0.25) or now < r.t then
        r = { t = now, list = M.find_all(class_name) }
        recent[class_name] = r
    end
    local out = {}
    for i = 1, #r.list do out[i] = r.list[i] end
    return out
end

-- Keep the shared list of `class_name` (short class name) for longer:
-- NotifyOnNewObject(path) marks it dirty whenever an object of the class is
-- constructed (in this UE4SS build it fires for spawned actors - the mod's
-- pickup / loot container / camp watches -, and once for the class default
-- object, which FindAllOf leaves out). The callback only sets two fields: it
-- returns nothing (true would unregister it) and cannot throw. Register once,
-- at load (not from inside another new-object callback). Returns ok, err.
function M.watch_new(class_name, path)
    if watched[class_name] then return true end
    if type(NotifyOnNewObject) ~= "function" then return false, "NotifyOnNewObject unavailable" end
    local w = { path = path, dirty = true, ok = true, notes = 0, missed = 0, confirmed = false }
    local ok, err = pcall(NotifyOnNewObject, path, function()
        w.dirty = true
        w.notes = w.notes + 1
    end)
    if not ok then
        log.warn("ue: new-object watch for %s FAILED (%s); its shared list stays at 0.25 s", class_name, tostring(err))
        return false, err
    end
    watched[class_name] = w
    log.info("ue: shared %s list rescanned on a new one (NotifyOnNewObject), else after %.1f s; entries checked on every read",
        class_name, WATCH_TTL)
    return true
end

-- Watch state of a class, or nil: { ok, notes, missed, confirmed, dirty }.
function M.watch_state(class_name) return watched[class_name] end

-- Every BP_PlayerCharacter_C (players, remote copies, dead / unpossessed
-- bodies): the shared list (copy, only valid objects). `fresh` = a message
-- handler that must not miss a character spawned a moment ago: a new scan
-- unless the new-object watch is in and trusted (then the list is fresh for
-- new characters anyway).
M.PLAYER_CHAR = "BP_PlayerCharacter_C"
M.PLAYER_CHAR_PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
function M.player_chars(fresh)
    local w = watched[M.PLAYER_CHAR]
    if fresh and not (w and w.ok) then
        local out = {}
        for _, o in ipairs(M.find_all(M.PLAYER_CHAR)) do
            if M.valid(o) then out[#out + 1] = o end
        end
        return out
    end
    return M.find_all_recent(M.PLAYER_CHAR)
end

function M.watch_player_chars()
    return M.watch_new(M.PLAYER_CHAR, M.PLAYER_CHAR_PATH)
end

-- What the mod is doing right now ([SLOWLOG], [HITCH]): the scheduled task
-- (guarded) and its part (sub_time); a hook is sdc_perf.current.
M.running = nil
M.part = nil
-- the longest task / part since sdc_diag last took them (take_worst)
local worst_task = { ms = 0 }
local worst_part = { ms = 0 }

local function perf_mod()
    local p = package.loaded["sdc_perf"]
    if type(p) == "table" then return p end
    return nil
end

-- ms spent writing UE4SS.log since start (sdc_log)
local function log_ms()
    local w = log.writes
    return type(w) == "table" and tonumber(w.ms) or 0
end

-- "task 'session-client-b', part c:headdbg" / "hook X" / both when a hook
-- runs inside a task.
function M.activity()
    local s
    if M.running then
        s = "task '" .. tostring(M.running) .. "'" .. (M.part and (", part " .. tostring(M.part)) or "")
    end
    local p = perf_mod()
    local h = p and p.current
    if h then s = (s and (s .. ", ") or "") .. "hook " .. tostring(h.name) end
    return s or "no mod task or hook"
end
log.activity = M.activity

-- The longest task and part since the last call, then resets them:
-- { ms, label }, { ms, label, task }.
function M.take_worst()
    local t, p = worst_task, worst_part
    worst_task, worst_part = { ms = 0 }, { ms = 0 }
    return t, p
end

-- [PERF]: parts of a scheduled task (label -> { calls, ms }); sub_time runs
-- fn(...) and adds its time under `label`. Not added to the task totals.
M.sub_stats = {}
function M.sub_time(label, fn, ...)
    local prev = M.part
    M.part = label
    local t0 = os.clock()
    local ok, err = pcall(fn, ...)
    local ms = (os.clock() - t0) * 1000
    M.part = prev
    local s = M.sub_stats[label]
    if not s then s = { calls = 0, ms = 0, wmax = 0 }; M.sub_stats[label] = s end
    s.calls, s.ms = s.calls + 1, s.ms + ms
    if ms > (s.wmax or 0) then s.wmax = ms end
    if ms > worst_part.ms then worst_part.ms, worst_part.label, worst_part.task = ms, label, M.running end
    if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
    return ok
end

function M.find_first(class_name)
    local ok, o = pcall(FindFirstOf, class_name)
    if ok and M.valid(o) then return o end
    return nil
end

function M.find_object(path)
    local ok, o = pcall(StaticFindObject, path)
    if ok and M.valid(o) then return o end
    return nil
end

-- Runtime-spawned actors get a name suffix counted down from INT_MAX
-- (UE fast-path unique names); actors placed in the level have small numbers.
function M.is_runtime_spawned(o)
    local n = tonumber(M.short(o):match("_(%d+)$"))
    return n ~= nil and n > 2000000000
end

function M.role(actor)
    local r = M.prop(actor, "Role")
    if type(r) == "number" then return r end
    return -1
end

M.ROLE_SIMULATED = 1
M.ROLE_AUTONOMOUS = 2
M.ROLE_AUTHORITY = 3

-- ---------------------------------------------------------------------------
-- Engine singletons
-- ---------------------------------------------------------------------------

local cache = {}
local function cached(key, finder)
    local o = cache[key]
    if M.valid(o) then return o end
    o = finder()
    if M.valid(o) then cache[key] = o; return o end
    return nil
end

function M.ksl()
    return cached("ksl", function() return M.find_object("/Script/Engine.Default__KismetSystemLibrary") end)
end

function M.gameplay_statics()
    return cached("gps", function() return M.find_object("/Script/Engine.Default__GameplayStatics") end)
end

function M.widget_lib()
    return cached("wbl", function() return M.find_object("/Script/UMG.Default__WidgetBlueprintLibrary") end)
end

function M.game_instance()
    return cached("gi", function()
        return M.find_first("SD_GameInstance_C") or M.find_first("GameInstance")
    end)
end

-- The PlayerController owned by this machine's LocalPlayer. The game also
-- creates helper controllers (item inspector) without a Player; those are
-- skipped, and on a listen server remote controllers have a NetConnection
-- in their Player slot instead of a LocalPlayer.
function M.local_pc()
    local cached_pc = cache.local_pc
    if M.valid(cached_pc) and M.valid(M.prop(cached_pc, "Player")) then
        return cached_pc
    end
    cache.local_pc = nil
    local fallback = nil
    for _, pc in ipairs(M.find_all("PlayerController")) do
        if M.valid(pc) then
            local player = M.prop(pc, "Player")
            if M.valid(player) and M.class_name(player):find("LocalPlayer", 1, true) then
                cache.local_pc = pc
                return pc
            end
            if not fallback then
                local ok, isl = pcall(m_is_local, pc)
                if ok and isl and M.valid(player) then fallback = pc end
            end
        end
    end
    cache.local_pc = fallback
    return fallback
end

-- Level change: the controller of the old world is freed by the load's
-- garbage collection, so its wrapper is dropped without touching it. The
-- other cached objects (class default objects, the GameInstance) outlive
-- every world.
function M.forget_world()
    cache.local_pc = nil
    recent = {}
end

function M.pawn_of(pc)
    local p = M.prop(pc, "Pawn")
    if M.valid(p) then return p end
    return nil
end

function M.local_pawn()
    local pc = M.local_pc()
    if not pc then return nil end
    return M.pawn_of(pc)
end

function M.world_context()
    return M.local_pc() or M.game_instance()
end

-- "standalone" | "host" | "client" | "unknown"
function M.net_role()
    local ctx = M.world_context()
    local ksl = M.ksl()
    if not ctx or not ksl then return "unknown" end
    local ok1, standalone = pcall(m_is_standalone, ksl, ctx)
    if ok1 and standalone == true then return "standalone" end
    local ok2, server = pcall(m_is_server, ksl, ctx)
    if ok2 and server == true then return "host" end
    if ok2 and server == false then return "client" end
    return "unknown"
end

-- Current level name without the "UEDPIE"/streaming prefix, or nil.
function M.map_name()
    local ctx = M.world_context()
    local gps = M.gameplay_statics()
    if not ctx or not gps then return nil end
    local ok, r = pcall(m_level_name, gps, ctx)
    if ok then
        local s = M.str(r)
        if s ~= "" then return s end
    end
    return nil
end

-- SurrounDead boots into /Game/Levels/PersistentLevel. The main menu is an
-- overlay on that same world, and "Continue"/"Load" restore the save INTO it
-- without opening another level. So "main menu" = menu map AND the local
-- player has no character yet.
function M.is_menu_map(name)
    if not name or name == "" then return false end
    local n = name:lower():match("([%w_]+)$") or name:lower()
    return n == "persistentlevel" or n:find("mainmenu", 1, true) ~= nil
end

function M.has_player_character()
    local pawn = M.local_pawn()
    return pawn ~= nil and M.class_name(pawn) == "BP_PlayerCharacter_C"
end

function M.in_main_menu()
    if not M.is_menu_map(M.map_name()) then return false end
    return not M.has_player_character()
end

-- "/Game/Levels/PersistentLevel" for the loaded world, or nil.
function M.world_path()
    local ctx = M.world_context()
    local w = ctx and M.try(m_get_world, ctx)
    if not M.valid(w) then return nil end
    local p = M.path(w)                       -- /Game/Levels/X.X
    return p:match("^(/[^%.]+)") or nil
end

function M.is_paused()
    local ctx, gps = M.world_context(), M.gameplay_statics()
    if not ctx or not gps then return false end
    local ok, r = pcall(m_is_paused, gps, ctx)
    return ok and r == true
end

function M.set_paused(paused)
    local ctx, gps = M.world_context(), M.gameplay_statics()
    if not ctx or not gps then return false end
    return (pcall(m_set_paused, gps, ctx, paused))
end

function M.count(class_name)
    return #M.find_all(class_name)
end

function M.has_pending_connection()
    return M.count("PendingNetGame") > 0
end

-- Executes a console command the same way the game does (through
-- KismetSystemLibrary with the game instance as world context).
-- `M.exec_in_progress` lets our own ExecuteConsoleCommand hook skip it.
M.exec_in_progress = false
function M.exec(cmd)
    local ksl, gi = M.ksl(), M.game_instance()
    if not ksl or not gi then return false, "KismetSystemLibrary/GameInstance not found" end
    M.exec_in_progress = true
    local ok, err = pcall(function() ksl:ExecuteConsoleCommand(gi, cmd, nil) end)
    M.exec_in_progress = false
    log.info("exec '%s' ok=%s%s", cmd, tostring(ok), ok and "" or (" err=" .. tostring(err)))
    return ok, err
end

function M.ping_ms(pc)
    local ps = M.prop(pc, "PlayerState")
    if not M.valid(ps) then return nil end
    local ok, v = pcall(m_ping, ps)
    if ok and type(v) == "number" then return v end
    ok, v = pcall(m_field, ps, "Ping")
    if ok and type(v) == "number" then return v * 4 end -- compressed ping
    return nil
end

function M.location(actor)
    local ok, loc = pcall(m_get_loc, actor)
    if ok and loc then
        local x, y, z = M.try(m_field, loc, "X"), M.try(m_field, loc, "Y"), M.try(m_field, loc, "Z")
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return { X = x, Y = y, Z = z }
        end
    end
    return nil
end

function M.rotation(actor)
    local ok, rot = pcall(m_get_rot, actor)
    if ok and rot then
        local yaw = M.try(m_field, rot, "Yaw")
        if type(yaw) == "number" then return { Pitch = 0, Yaw = yaw, Roll = 0 } end
    end
    return { Pitch = 0, Yaw = 0, Roll = 0 }
end

function M.teleport(actor, loc)
    return (pcall(m_set_loc, actor, loc))
end

-- ---------------------------------------------------------------------------
-- Game-thread scheduling
-- ---------------------------------------------------------------------------

-- Debug: loops switched off by label (experiment.txt "loop <label> off").
M.disabled_loops = {}
function M.loop_on(label) return not M.disabled_loops[label] end

-- [SLOW]: a scheduled task of the mod that held the game thread for longer
-- than SLOW_MS (a freeze or a stutter shows up with the task's name); the
-- worst one of each label is logged again when it gets worse, and every one
-- of a second or more. The line says how much of it was writing UE4SS.log
-- (sdc_log) and whether the Lua collector finished a cycle in it.
local SLOW_MS = 100
M.slow = {}   -- label -> worst ms logged
M.last_task = { label = nil, at = 0 }
-- the last task that finished (label, os.clock() at its end, its ms): what
-- sdc_diag's [HITCH] names (last_task is the one running now - diag itself)
M.last_done = { label = nil, at = 0, ms = 0 }
M.task_stats = {}   -- label -> { calls, ms } (sdc_perf)
local function guarded(label, fn)
    return function(...)
        if M.disabled_loops[label] then return end
        local t0 = os.clock()
        M.last_task.label, M.last_task.at = label, t0
        -- tasks run from the engine's timers, never inside a hook: a hook
        -- marker left by a hook that threw is cleared here
        local prev_task, prev_part = M.running, M.part
        M.running, M.part = label, nil
        local perf = perf_mod()
        local prev_hook = perf and perf.current
        if perf then perf.current = nil end
        local w0 = log_ms()
        local gc0 = tonumber(perf and perf.gc_cycles) or 0
        local ok, err = pcall(fn, ...)
        if perf then perf.current = prev_hook end
        M.running, M.part = prev_task, prev_part
        if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
        local t1 = os.clock()
        local ms = (t1 - t0) * 1000
        local ld = M.last_done
        ld.label, ld.at, ld.ms = label, t1, ms
        local ts = M.task_stats[label]
        if not ts then ts = { calls = 0, ms = 0 }; M.task_stats[label] = ts end
        ts.calls, ts.ms = ts.calls + 1, ts.ms + ms
        if ms > worst_task.ms then worst_task.ms, worst_task.label = ms, label end
        if ms >= SLOW_MS and (ms > (M.slow[label] or 0) * 1.5 or ms >= 1000) then
            M.slow[label] = math.max(ms, M.slow[label] or 0)
            log.warn("[SLOW] mod task '%s' held the game for %.0f ms (writing UE4SS.log in it: %.0f ms; lua heap %.1f MB,"
                .. " collector cycles finished in it: %d)", label, ms, log_ms() - w0,
                collectgarbage("count") / 1024, (tonumber(perf and perf.gc_cycles) or 0) - gc0)
        end
    end
end
M.guarded = guarded

function M.game_thread(label, fn)
    local g = guarded(label, fn)
    if ExecuteInGameThread then
        ExecuteInGameThread(g)
    else
        g()
    end
end

-- The *InGameThread* timer API is preferred; older UE4SS builds (or a failed
-- EngineTick/ProcessEvent AOB scan) fall back to a worker-thread timer that
-- only hops onto the game thread to run the callback.
function M.delay(label, ms, fn)
    local g = guarded(label, fn)
    if ExecuteInGameThreadWithDelay then
        local ok, h = pcall(ExecuteInGameThreadWithDelay, ms, g)
        if ok then return h end
        log.warn("ExecuteInGameThreadWithDelay unavailable (%s), using fallback", tostring(h))
    end
    ExecuteWithDelay(ms, function() ExecuteInGameThread(g) end)
    return nil
end

function M.every(label, ms, fn)
    local g = guarded(label, fn)
    if LoopInGameThreadWithDelay then
        local ok, h = pcall(LoopInGameThreadWithDelay, ms, g)
        if ok then return h end
        log.warn("LoopInGameThreadWithDelay unavailable (%s), using fallback", tostring(h))
    end
    LoopAsync(ms, function()
        ExecuteInGameThread(g)
        return false
    end)
    return nil
end

-- Every rendered frame when the EngineTick hook is available.
function M.every_frame(label, fn)
    local g = guarded(label, fn)
    if EngineTickAvailable and LoopInGameThreadAfterFrames then
        local ok, h = pcall(LoopInGameThreadAfterFrames, 1, g)
        if ok then return h end
    end
    return M.every(label, 16, fn)
end


-- ---------------------------------------------------------------------------
-- Easy Multi Save, called the way the game's own blueprints call it
-- ---------------------------------------------------------------------------
local EMS_LIB_PATH = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"

-- SaveMenu @48: DeleteAllSaveDataForSlot(self, SaveName, 0). Returns ok, error.
function M.ems_delete_slot(slot)
    local lib, wc = M.find_object(EMS_LIB_PATH), M.world_context()
    if not lib or not wc then return false, "no EMS library / world" end
    local ok, err = pcall(function() lib:DeleteAllSaveDataForSlot(wc, slot, 0) end)
    if ok then return true end
    if pcall(function() lib:DeleteAllSaveDataForSlot(wc, slot, false) end) then return true end
    return false, tostring(err)
end

-- The text of an FString that may come wrapped (out parameters, TArray
-- elements: RemoteUnrealParam -> FString). Never the wrapper's own
-- tostring ("RemoteUnrealParam: 0000..."): that once became the name of the
-- host's current save slot (0.6.46). "" when no text is found.
function M.fstring(v)
    for _ = 1, 4 do
        local t = type(v)
        if v == nil then return "" end
        if t == "string" then return v end
        if t == "number" or t == "boolean" then return tostring(v) end
        local ok, s = pcall(m_to_string, v)
        if ok and type(s) == "string" then return s end
        local okg, inner = pcall(m_get, v)
        if not okg or inner == nil or rawequal(inner, v) then return "" end
        v = inner
    end
    return ""
end

-- A string that is a Lua wrapper's tostring, not a game value.
function M.is_wrapper_text(s)
    return type(s) == "string" and (s:find("^RemoteUnrealParam") ~= nil or s:find("^LocalUnrealParam") ~= nil
        or s:find("^UObject: ") ~= nil or s:find("^UScriptStruct") ~= nil)
end

-- SaveGameSlot @236: GetSlotInfoSaveGame(self, out SaveGameName) gives the
-- current slot name. Returns the name or nil, error.
function M.ems_current_slot()
    local lib, wc = M.find_object(EMS_LIB_PATH), M.world_context()
    if not lib or not wc then return nil, "no EMS library / world" end
    local out = {}
    local ok, err = pcall(function() lib:GetSlotInfoSaveGame(wc, out) end)
    if not ok then return nil, tostring(err) end
    local v = out.SaveGameName
    if v == nil then
        for _, x in pairs(out) do v = x break end
    end
    if v == nil then return nil, "no out value" end
    return M.fstring(v)
end


-- Synchronous asset load with a timer: UE4SS LoadAsset blocks the game thread
-- (and can wait on the game's own streaming). Returns ok, object like
-- pcall(LoadAsset, path); a load taking >= 50 ms is logged as [SLOW].
function M.load_asset(path, who)
    local found = M.find_object(path)
    if found then return true, found end
    local t0 = os.clock()
    local ok, loaded = pcall(LoadAsset, path)
    local ms = (os.clock() - t0) * 1000
    if ms >= 50 then
        log.warn("[SLOW] %s loaded %s synchronously in %.0f ms", tostring(who or "?"), tostring(path), ms)
    end
    return ok, loaded
end

-- An asset that is already in memory, or nil: never loads. For message-driven
-- paths on a client (a forwarded sound, the host's weather preset), where a
-- synchronous LoadAsset can wait for the world's streaming and freeze the
-- game. The first miss of each path is logged.
local mem_miss = {}
function M.loaded_asset(path, who)
    if type(path) ~= "string" or path == "" then return nil end
    local o = M.find_object(path)
    if o then return o end
    if not mem_miss[path] then
        mem_miss[path] = true
        log.info("asset: %s is not in memory here; skipped by %s (no synchronous load on this path)",
            path, tostring(who or "?"))
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Shared native-function hooks
-- ---------------------------------------------------------------------------
-- UE4SS wraps every parameter of a hooked native function in a new Lua
-- object for EVERY registered callback on EVERY call, and again for a post
-- callback (even an empty `function() end`). Several modules hooking the same
-- native (PlaySoundAtLocation: 4-5) paid that per module. hook_native keeps
-- ONE pre-only engine hook per function and calls each subscriber with the
-- same arguments (Context, params...), in subscription order, each in its own
-- pcall (a failing subscriber never stops the others or the game call).
-- Subscribers return nothing (a returned value would replace the function's
-- result). The cost of each subscriber shows in [PERF] as
-- "Class:Function#key". Returns ok, err like pcall(RegisterHook, ...).
-- Use it only for /Script/ native functions; Blueprint functions keep their
-- own RegisterHook (one callback, after the function).
local natives = {}   -- [path] = { subs = { { key =, fn =, rec = } } }
M.natives = natives

local function perf_record(path, key)
    local perf = package.loaded["sdc_perf"]
    if type(perf) == "table" and type(perf.record) == "function" then
        local ok, r = pcall(perf.record, path .. "#" .. key)
        if ok and type(r) == "table" then return r end
    end
    return { calls = 0, ms = 0 }
end

function M.hook_native(path, key, fn)
    key = tostring(key or "?")
    if type(fn) ~= "function" then return false, "no callback" end
    local h = natives[path]
    if h then
        for _, s in ipairs(h.subs) do
            if s.key == key then s.fn = fn; return true end
        end
        h.subs[#h.subs + 1] = { key = key, fn = fn, rec = perf_record(path, key) }
        log.info("hook: %s + %s (%d subscribers on one engine hook)", path:match("([%w_]+:[%w_]+)$") or path, key, #h.subs)
        return true
    end
    local subs = { { key = key, fn = fn, rec = perf_record(path, key) } }
    local clock = os.clock
    local pm = perf_mod()   -- "what is running" marker and slow-call notes (sdc_perf)
    local function dispatch(...)
        local prev = pm and pm.current
        for i = 1, #subs do
            local s = subs[i]
            local r = s.rec
            if pm then pm.current = r end
            local w0 = log_ms()
            local t0 = clock()
            local ok, err = pcall(s.fn, ...)
            local ms = (clock() - t0) * 1000
            r.calls = r.calls + 1
            r.ms = r.ms + ms
            if not ok then log.err_throttled("hook." .. s.key, "hook %s on %s: %s", s.key, path, tostring(err)) end
            if ms >= 50 and pm and pm.note_hook then pcall(pm.note_hook, r, ms, log_ms() - w0) end
        end
        if pm then pm.current = prev end
    end
    local perf = package.loaded["sdc_perf"]
    -- debug switch perf_bench_no_bp_hooks (sdc_perf): a Blueprint function is
    -- not hooked at all (only natives belong here; checked anyway)
    if type(perf) == "table" and type(perf.bench_skip) == "function" and perf.bench_skip(path) then
        natives[path] = { subs = subs, skipped = true }
        return true
    end
    local reg = (type(perf) == "table" and perf.raw_register_hook) or RegisterHook
    local ok, err = pcall(reg, path, dispatch)
    if not ok then return false, err end
    natives[path] = { subs = subs }
    if type(perf) == "table" and type(perf.note_hook_registered) == "function" then
        pcall(perf.note_hook_registered, path)
    end
    log.info("hook: %s (shared engine hook, pre only) for %s", path:match("([%w_]+:[%w_]+)$") or path, key)
    return true
end

return M
