-- SDCoop debug: sync gap tracer.
--
-- Counts, on host and client alike, what the game does for whom:
--   * every "player 0" call (GetPlayerController / Character / CameraManager
--     ... with index 0) seen by sdc_ctx, by function and calling class;
--   * calls of client-visible "sinks" (widgets, 2D sounds, camera shakes,
--     notifications, HUD access, damage numbers, dialogue, time dilation),
--     by sink, calling class and a detail (widget class, sound, text).
-- Each call is attributed with sdc_ctx.classify:
--   host:   remote (a remote player's object) / local (the host player's) / world
--   client: own / other / world
-- Rows "clock" (sdc_speed, one count per measured second): game_speed by
-- band (x1.00 = normal; a time dilation or hitches make it lower), paused,
-- dilation when not 1, hitches (seconds that lost >= 0.05 s of world time to
-- frames over 0.4 s, by how much), timer_period (how far apart the 1 s
-- timer ran). tools/gapdiff.py shows them in its CLOCK section.
-- Host and client side by side show a world that runs slower on one of them.
-- Rows go to Mods/SDCoop/gaptrace_<role>.csv every WRITE_S seconds.
-- tools/gapdiff.py joins the host's and the client's file:
--   host "remote" rows with no client "own" row = logic that runs only on the
--   host for a client's action: what that client never sees.
--
-- Off unless config gap_trace = true: main.lua loads this module and starts
-- its 1 s tick only then (at start, or when sdcoop_set turns the key on); the
-- tick stops counting when the key goes off again. Read-only: hooks return
-- nothing and never throw. A second RegisterHook on a function the mod hooks
-- elsewhere adds one more callback (UE4SS keeps both).

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")

local M = { enabled = false }

local WRITE_S = 20
local CACHE_S = 10
local MAX_ROWS = 4000

-- kind "native": pre-hook, args after the context; "bp": post-hook.
-- ctx: index of the world-context argument (1-based after the hook's own
-- context), 0 = the hook's context object itself, "last" = last argument.
-- detail: index of an argument describing the call (class / sound / text).
local SINKS = {
    { "native", "/Script/UMG.WidgetBlueprintLibrary:Create", ctx = 1, detail = 2 },
    { "native", "/Script/Engine.GameplayStatics:PlaySound2D", ctx = 1, detail = 2 },
    { "native", "/Script/Engine.GameplayStatics:SpawnSound2D", ctx = 1, detail = 2 },
    { "native", "/Script/Engine.GameplayStatics:SetGlobalTimeDilation", ctx = 1, detail = 2 },
    { "native", "/Script/Engine.PlayerCameraManager:StartCameraShake", ctx = 0, detail = 1 },
    { "native", "/Script/Narrative.NarrativeFunctionLibrary:GetNarrativeComponent", ctx = 1 },
    { "native", "/Script/Narrative.NarrativeComponent:BeginDialogue", ctx = 0, detail = 1 },
    { "native", "/Script/Narrative.NarrativeComponent:BeginQuest", ctx = 0, detail = 1 },
    { "bp", "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI", ctx = "last", detail = 1 },
    { "bp", "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:SpawnDamageNumbers", ctx = "last" },
    { "bp", "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:GetHUD", ctx = 1 },
    -- effects in the world: what stays on one machine (owner-only sounds,
    -- montages, movement modes) shows up as "own" on a client with no
    -- "remote" counterpart on the host, and the other way round
    { "native", "/Script/Engine.GameplayStatics:PlaySoundAtLocation", ctx = 1, detail = 2 },
    { "native", "/Script/Engine.GameplayStatics:SpawnSoundAtLocation", ctx = 1, detail = 2 },
    { "native", "/Script/Engine.GameplayStatics:SpawnSoundAttached", ctx = 2, detail = 1 },
    { "native", "/Script/Engine.Character:PlayAnimMontage", ctx = 0, detail = 1 },
    { "native", "/Script/Engine.CharacterMovementComponent:SetMovementMode", ctx = 0, detail = 1 },
    { "native", "/Script/Engine.CharacterMovementComponent:DisableMovement", ctx = 0 },
}

local S
local rows = {}          -- key -> { role, who, sink, class, detail, n }
local nrows = 0
local cls_cache, who_cache, cache_at = {}, {}, 0
local hooked = {}
local mod_dir
local write_at = 0
local dropped = 0

local function role() return S and S.role or "standalone" end

local function addr(o)
    return ue.try(function() return o:GetAddress() end)
end

local function cls(o)
    local a = addr(o)
    if not a then return "?" end
    local c = cls_cache[a]
    if not c then
        c = ue.class_name(o)
        cls_cache[a] = c
    end
    return c
end

local function who(o)
    local a = addr(o)
    if not a then return "none" end
    local w = who_cache[a]
    if not w then
        w = ctx.classify(o, role())
        who_cache[a] = w
    end
    return w
end

local function clean(s)
    -- numbers inside texts vary per call (damage, XP): one row per kind of
    -- message; a bare number (movement mode) stays
    s = tostring(s or ""):gsub("[\r\n,;]", " ")
    if not s:match("^[%d%.%-]+$") then s = s:gsub("%d+", "#") end
    if #s > 60 then s = s:sub(1, 60) end
    return s
end

local function count(w, sink, class, detail)
    local key = w .. "|" .. sink .. "|" .. class .. "|" .. detail
    local r = rows[key]
    if r then r.n = r.n + 1 return end
    if nrows >= MAX_ROWS then dropped = dropped + 1 return end
    rows[key] = { who = w, sink = sink, class = class, detail = detail, n = 1 }
    nrows = nrows + 1
end

-- describe an argument value: object class / name, text, number
local function describe(v)
    if v == nil then return "" end
    local t = type(v)
    if t == "number" then return string.format("%.3g", v) end
    if t == "boolean" or t == "string" then return tostring(v) end
    if ue.valid(v) then
        local n = ue.try(function() return v:GetFName():ToString() end)
        local c = ue.class_name(v)
        if c == "Class" or c == "BlueprintGeneratedClass" or c == "WidgetBlueprintGeneratedClass" then return n or c end
        return n or c
    end
    local s = ue.try(function() return v:ToString() end)
    return s and tostring(s) or ""
end

local function on_sink(spec, sink, context, ...)
    if not M.enabled then return end
    local n = select("#", ...)
    local cobj
    if spec.ctx == 0 then
        cobj = ue.param(context)
    elseif spec.ctx == "last" then
        cobj = ue.param((select(n, ...)))
    else
        cobj = ue.param((select(spec.ctx, ...)))
    end
    local detail = ""
    if spec.detail and spec.detail <= n then detail = clean(describe(ue.param((select(spec.detail, ...))))) end
    if not ue.valid(cobj) then
        count("none", sink, "-", detail)
        return
    end
    count(who(cobj), sink, cls(cobj), detail)
end

local function on_player0(fname, wco, tag)
    if not M.enabled or not ue.valid(wco) then return end
    local w = tag or who(wco)
    count(w, "p0:" .. fname, cls(wco), "")
end

-- sdc_speed's per-second records not counted yet: rows "clock".
M.clock_seen = 0
local function period_band(dt)
    local ms = dt * 1000
    if ms < 1020 then return "<1.02s" elseif ms < 1050 then return "1.02-1.05s"
    elseif ms < 1100 then return "1.05-1.10s" elseif ms < 1250 then return "1.10-1.25s" end
    return ">=1.25s"
end
local function lost_band(s)
    if s < 0.5 then return "0.05-0.5s" elseif s < 2 then return "0.5-2s" end
    return ">=2s"
end
local function count_clock()
    local sp = package.loaded["sdc_speed"]
    if type(sp) ~= "table" or type(sp.recent) ~= "table" then return end
    for _, r in ipairs(sp.recent) do
        if r.seq > M.clock_seen then
            M.clock_seen = r.seq
            if r.paused then
                count("clock", "paused", "-", "")
            else
                -- 0.05 bands: x1.00 normal, x0.50 half speed
                count("clock", "game_speed", string.format("x%.2f", math.floor(r.speed * 20 + 0.5) / 20), "")
                if (r.lost or 0) >= 0.05 then count("clock", "hitches", lost_band(r.lost), "") end
            end
            if r.dil and math.abs(r.dil - 1) > 0.001 then count("clock", "dilation", string.format("%.2f", r.dil), "") end
            count("clock", "timer_period", period_band(r.dt), "")
        end
    end
end
M._count_clock = count_clock   -- tests
M._rows = function() return rows end

local function install()
    for _, spec in ipairs(SINKS) do
        local path = spec[2]
        if not hooked[path] then
            local sink = path:match(":([%w_]+)$")
            local cb = function(context, ...)
                local ok, err = pcall(on_sink, spec, sink, context, ...)
                if not ok then log.err_throttled("gaptrace." .. sink, "gaptrace: %s: %s", sink, tostring(err)) end
            end
            local ok
            if spec[1] == "native" then
                ok = pcall(RegisterHook, path, cb, function() end)
            else
                ok = pcall(RegisterHook, path, cb)
            end
            if ok then
                hooked[path] = true
                log.info("gaptrace: hooked %s", sink)
            end
        end
    end
end

local function write()
    if not mod_dir then return end
    local path = string.format("%s/gaptrace_%s.csv", mod_dir, role())
    local f = io.open(path, "w")
    if not f then return end
    f:write("role,who,sink,class,detail,count\n")
    local list = {}
    for _, r in pairs(rows) do list[#list + 1] = r end
    table.sort(list, function(a, b) return a.n > b.n end)
    for _, r in ipairs(list) do
        f:write(string.format("%s,%s,%s,%s,%s,%d\n", role(), r.who, r.sink, r.class, r.detail, r.n))
    end
    f:close()
end

function M.init(state, dir)
    S, mod_dir = state, dir
end

-- Every second from main.lua while started (any role).
function M.tick(now)
    local on = cfg.get("gap_trace") == true
    if on ~= M.enabled then
        M.enabled = on
        ctx.observer = on and on_player0 or nil
        -- clock rows from the seconds after the switch only
        local sp = package.loaded["sdc_speed"]
        if on and type(sp) == "table" then M.clock_seen = tonumber(sp.seq) or 0 end
        log.info("gaptrace: %s", on and "on (writes gaptrace_<role>.csv)" or "off")
    end
    if not on then return end
    if role() ~= M.last_role then
        M.last_role = role()
        M.reset()
    end
    install()
    local okc, errc = pcall(count_clock)
    if not okc then log.err_throttled("gaptrace.clock", "gaptrace: clock rows: %s", tostring(errc)) end
    if now - cache_at >= CACHE_S then
        cache_at = now
        cls_cache, who_cache = {}, {}
    end
    if now - write_at >= WRITE_S then
        write_at = now
        local ok, err = pcall(write)
        if not ok then log.err_throttled("gaptrace.write", "gaptrace: write: %s", tostring(err)) end
        if dropped > 0 then log.warn("gaptrace: %d calls not counted (row limit %d)", dropped, MAX_ROWS) end
    end
end

-- Role / level change: start a new count (the old one stays in the file
-- until the next write).
function M.reset()
    rows, nrows, dropped = {}, 0, 0
    cls_cache, who_cache = {}, {}
end

return M
