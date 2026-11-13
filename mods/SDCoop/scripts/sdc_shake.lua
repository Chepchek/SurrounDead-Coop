-- SDCoop: explosion camera shake for every player inside the explosion's zone.
--
-- The game shakes "player 0" once for every player its explosion overlaps:
--   BP_MasterZombie special death @714-1128: SphereOverlapActors(r = 500)
--     around the zombie, then for each 'Player'-tagged actor
--     GetPlayerController(self, 0).CameraShake(CameraShake_Explosion);
--   BP_ExplosiveBarrelMaster @1144-1923: the same with r = ExplosionSphere.
-- In single player that is right. In co-op the machine running that code
-- shakes its own player whenever ANY player is near (the host shook while
-- far away when the client stood next to an explosion), and the other player
-- next to it gets nothing from it.
--
-- Here, on every machine:
--   * explosions are recorded where their sound plays (PlaySoundAtLocation /
--     SpawnSoundAtLocation of a sound named *explosion*), with the zone of
--     their source (barrel: its ExplosionSphere; otherwise 500 cm); the host
--     also sends each one to the clients (EXPL|x|y|z|r);
--   * PlayerController:ClientStartCameraShake (pre): an explosion shake of
--     this machine's own controller waits a moment (its sound may come after
--     it) and then plays only if this player's character is inside the zone
--     of a recent explosion; no known explosion -> it plays as the game asked;
--   * a player inside the zone whose own game started no shake gets one: the
--     game's CameraShake_Explosion at the game's CameraShakeIntensity.
-- One shake per explosion and player. Config: explosion_shake_zone (off: no
-- hook is subscribed).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = { stats = { seen = 0, played = 0, muted = 0, given = 0, sources = 0, from_host = 0, failed = 0 } }

local SHAKE_PATH = "/Game/FX/CameraShake/CameraShake_Explosion.CameraShake_Explosion_C"
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"
local SHAKE_FN = "/Script/Engine.PlayerController:ClientStartCameraShake"
local SOUND_FNS = { "/Script/Engine.GameplayStatics:PlaySoundAtLocation",
                    "/Script/Engine.GameplayStatics:SpawnSoundAtLocation" }
local DEFAULT_RADIUS = 500   -- the zombie's SphereOverlapActors radius
local MARGIN = 100           -- the overlap counts the player's capsule, not its centre
local WINDOW = 2.0           -- s an explosion stays "the one" for a shake
local DECIDE_AFTER = 0.25    -- s a shake waits for its explosion's sound
local ONE_SHAKE = 0.8        -- s: one shake per explosion and player

local S
local st = {
    hooks = false, sources = {}, pending = nil, replaying = false,
    last_shake = -100, give_at = nil,
}

local function clock() return os.clock() end

local function enabled() return cfg.get("explosion_shake_zone") ~= false end

local function coop() return S ~= nil and (S.role == "host" or S.role == "client") end

local function is_explosion_shake(cls)
    if not ue.valid(cls) then return false end
    return (ue.name(cls) or ""):find("Explosion", 1, true) ~= nil
end

local function radius_of(src)
    if ue.valid(src) and (ue.class_name(src) or ""):find("Barrel", 1, true) then
        local r = tonumber(ue.prop(ue.prop(src, "ExplosionSphere"), "SphereRadius"))
        if r and r > 0 then return r end
    end
    return DEFAULT_RADIUS
end

-- The recent explosion whose zone holds the own character, and whether any
-- explosion is known at all.
local function own_zone()
    local t = clock()
    for i = #st.sources, 1, -1 do
        if t - st.sources[i].t > WINDOW then table.remove(st.sources, i) end
    end
    local any = #st.sources > 0
    local pawn = ue.local_pawn()
    local p = ue.valid(pawn) and ue.location(pawn) or nil
    if not p then return nil, any end
    for i = #st.sources, 1, -1 do
        local s = st.sources[i]
        local dx, dy, dz = p.X - s.x, p.Y - s.y, p.Z - s.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d <= s.r + MARGIN then return s, any, d end
    end
    return nil, any
end

local function add_source(x, y, z, r, what)
    st.sources[#st.sources + 1] = { x = x, y = y, z = z, r = r, t = clock(), what = what }
    if #st.sources > 16 then table.remove(st.sources, 1) end
    M.stats.sources = M.stats.sources + 1
end

local function intensity()
    local cu = ue.find_object(CONSOLE_UTILS)
    if not cu then return 1 end
    local ok, v = pcall(function() return cu:GetFloatCVar(FName("Character.CameraShakeIntensity")) end)
    if ok and type(v) == "number" then return v end
    return 1
end

local function shake_class()
    local c = ue.find_object(SHAKE_PATH)
    if c then return c end
    local ok, loaded = ue.load_asset(SHAKE_PATH, "shake")
    if ok and ue.valid(loaded) then return loaded end
    return nil
end

-- Starts the shake on the own controller (the call the game's own
-- CameraShakeClient makes), past our pre-hook.
local function play(cls, scale, why)
    if clock() - st.last_shake < ONE_SHAKE then return false end
    local pc = ue.local_pc()
    if not pc or not ue.valid(cls) then return false end
    st.replaying = true
    local ok, err = pcall(function()
        pc:ClientStartCameraShake(cls, scale, 0, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    st.replaying = false
    st.last_shake = clock()
    if ok then
        log.info("shake: explosion shake played here (%s, scale %.2f)", why, scale)
    else
        M.stats.failed = M.stats.failed + 1
        log.warn("shake: could not start the explosion shake (%s): %s", why, tostring(err))
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- [sound asset address] = its full name when it is an explosion, false when
-- not: the full name (a long string) is built once per sound asset, not on
-- every PlaySoundAtLocation. Dropped with the world (shake.reset).
local explosive = {}

-- PlaySoundAtLocation / SpawnSoundAtLocation(WorldContextObject, Sound,
-- Location, ...), pre (subscribers of sdc_ue.hook_native: each runs in its
-- own pcall there)
local function on_sound(_, wco, sound, loc)
    if not enabled() or not coop() then return end
    local s = sound and sound:get()
    if not ue.valid(s) then return end
    local sa = ue.try(function() return s:GetAddress() end)
    local name = sa and explosive[sa]
    if name == nil then
        name = ue.name(s) or ""
        if not name:lower():find("explosion", 1, true) then name = false end
        if sa then explosive[sa] = name end
    end
    if not name then return end
    local w = wco and wco:get()
    local l = loc and loc:get()
    local x, y, z = ue.try(function() return l.X end), ue.try(function() return l.Y end), ue.try(function() return l.Z end)
    if type(x) ~= "number" then
        local wl = ue.valid(w) and ue.location(w) or nil
        if not wl then return end
        x, y, z = wl.X, wl.Y, wl.Z
    end
    local r = radius_of(w)
    local src = ue.valid(w) and ue.class_name(w) or "?"
    add_source(x, y, z, r, src)
    log.info("shake: explosion %s from %s at %.0f,%.0f,%.0f, zone %.0f cm", name, src, x, y, z, r)
    if S.role == "host" and #(S.remote_pcs or {}) > 0 then
        net.broadcast(S.remote_pcs, "EXPL", string.format("%.0f", x), string.format("%.0f", y),
            string.format("%.0f", z), string.format("%.0f", r))
    end
end

-- ClientStartCameraShake(Shake, Scale, PlaySpace, UserPlaySpaceRot), pre
local function on_shake(ctx, shake, scale)
    if st.replaying or not enabled() or not coop() then return end
    local pc = ctx and ctx:get()
    local lpc = ue.local_pc()
    if not ue.valid(pc) or not lpc or ue.name(pc) ~= ue.name(lpc) then return end
    local cls = shake and shake:get()
    if not is_explosion_shake(cls) then return end
    M.stats.seen = M.stats.seen + 1
    local sc = tonumber(scale and scale:get()) or 1
    -- the game asks once per player in the zone: one decision for all of them
    if not st.pending then st.pending = { cls = cls, scale = sc, t = clock(), n = 0 } end
    st.pending.n = st.pending.n + 1
    if scale then pcall(function() scale:set(0.0) end) end
end

-- Only with explosion_shake_zone on (subscribed when it is on in co-op;
-- sdc_ue.hook_native keeps a subscriber, so turned off later they return at once).
local function install_hooks()
    st.hooks = true
    local ok, err = ue.hook_native(SHAKE_FN, "shake", on_shake)
    log.info("shake: ClientStartCameraShake hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    for _, path in ipairs(SOUND_FNS) do
        local fn = path:match(":([%w_]+)$")
        local oks, errs = ue.hook_native(path, "shake", on_sound)
        log.info("shake: %s hook %s%s", fn, oks and "ok" or "FAILED", oks and "" or (" " .. tostring(errs)))
    end
end

-- ---------------------------------------------------------------------------
-- Tick (50 ms)
-- ---------------------------------------------------------------------------

function M.tick()
    if not coop() then
        st.pending, st.give_at = nil, nil
        return
    end
    if not st.hooks and enabled() then install_hooks() end
    local t = clock()
    local p = st.pending
    if p and t - p.t >= DECIDE_AFTER then
        st.pending = nil
        local src, any, d = own_zone()
        if src then
            if play(p.cls, p.scale, string.format("own character %.0f cm from the %s explosion", d or -1, src.what)) then
                M.stats.played = M.stats.played + 1
            end
        elseif not any then
            -- no explosion known here: as the game asked
            if play(p.cls, p.scale, "no explosion position known, as the game asked") then
                M.stats.played = M.stats.played + 1
            end
        else
            M.stats.muted = M.stats.muted + 1
            log.info("shake: explosion shake for another player's zone not played here (own character outside every zone; asked %dx)", p.n)
        end
    end
    -- an explosion the host reported: a player in its zone whose own game
    -- shook nothing gets the game's shake
    if st.give_at and t >= st.give_at and not st.pending then
        st.give_at = nil
        if t - st.last_shake >= ONE_SHAKE then
            local src, _, d = own_zone()
            if src and play(shake_class(), intensity(), string.format("in the zone of an explosion from %s, %.0f cm", src.what, d or -1)) then
                M.stats.given = M.stats.given + 1
            end
        end
    end
end

function M.install(state)
    S = state
    -- host -> client: EXPL|x|y|z|zone radius
    net.on("EXPL", function(f)
        if not enabled() then return end
        local x, y, z, r = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
        if not (x and y and z) then return end
        add_source(x, y, z, r or DEFAULT_RADIUS, "host")
        M.stats.from_host = M.stats.from_host + 1
        st.give_at = clock() + DECIDE_AFTER + 0.1
    end)
    log.info("shake: installed (explosion_shake_zone=%s)", tostring(enabled()))
    log.info("sound relay EXPL: carries no sound (the explosion's position and zone for the camera shake only; the sound is the game's, with its attenuation)")
end

function M.reset(why)
    st.sources, st.pending, st.give_at = {}, nil, nil
    explosive = {}
    log.debug("shake: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    return string.format("shake: hooks=%s explosions=%d (from host %d) shakes asked=%d played=%d muted=%d given=%d failed=%d",
        tostring(st.hooks), s.sources, s.from_host, s.seen, s.played, s.muted, s.given, s.failed)
end

return M
