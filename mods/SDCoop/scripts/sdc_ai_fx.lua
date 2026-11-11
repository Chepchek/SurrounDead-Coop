-- SDCoop zombie feature ai_zombie_fx: the archetypes' one-shot effects reach
-- the clients — the grenadier's beep and explosion, the acidic zombie's death
-- burst. (Their lasting effects, the acid spit at the mouth and the radiation
-- mist, are part of the look: sdc_ai_looks.)
--
-- On the host only (BP_MasterZombie ubergraph, no authority check, but the
-- copies never run these paths):
--   Grenadier: Event_Grenadier timer -> a player within 6.75 m in sight (@9590)
--     -> once (@8689): Zombie_Agonizing_Montage (proxy: sdc_ai_attacks relays
--     it), PlaySoundAtLocation(ZombieAttack_Cue), PlaySoundAtLocation(S_Beep_Cue)
--     (@9462), Delay 2.7 -> @2678 SpawnEmitterAtLocation(FX_Explosion_Grenadier,
--     random yaw, random scale 1..1.25), PlaySoundAtLocation(explosion_large_06_Cue),
--     SpawnDecalAtLocation(M_Burn, (400,800,800), pitch -90, 30 s), damage.
--     GrenadierDeath (bound to DeathEvent) runs the same from @8689.
--     No projectile: the grenadier blows itself up (nothing for sdc_throw).
--   Acidic: Event_SpecialDeath (not a headshot) -> Delay 1.3..1.6 -> @1888
--     SpawnEmitterAtLocation(FX_Explosion_RadiatedZombie),
--     PlaySoundAtLocation(Infected_SpecialCue), damage.
-- Host: pre-hooks on GameplayStatics PlaySoundAtLocation / SpawnEmitterAtLocation
--   / SpawnDecalAtLocation: when the world context is a zombie and the asset is
--   one of these, AIFX|kind|asset|x|y|z|pitch|yaw|roll|a|b|c|d goes to every
--   client within reach: a sound as far as it carries (its attenuation + 5 m:
--   S_Beep_Cue 126 m, Infected_SpecialCue 210 m, explosion_large_06_Cue 325 m),
--   an emitter or decal within 160 m (kind s: a,b = volume, pitch; e: a,b,c =
--   scale; d: a,b,c = size, d = life). Not relayed: ZombieAttack_Cue (also the attack
--   sound sdc_ai_attacks plays with each attack montage), the camera shake
--   (the game shakes only player 0).
-- Client: the same GameplayStatics call at that place, with an asset already in
--   memory (they are hard references of BP_MasterZombie); never a load — a
--   missing one is skipped and logged once.

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = { stats = { sent = 0, played = 0, missing = 0 } }
local core

local clock = os.clock
local addr = ctx.addr

local GS = "/Script/Engine.GameplayStatics:"
-- asset short name -> kind (s sound, e emitter, d decal)
local WANTED = {
    S_Beep_Cue = "s", explosion_large_06_Cue = "s", Infected_SpecialCue = "s",
    FX_Explosion_Grenadier = "e", FX_Explosion_RadiatedZombie = "e",
    M_Burn = "d",
}
local CLASS_PART = { s = "Sound", e = "ParticleSystem", d = "Material" }
local SEND_CM = 16000
local PER_CLIENT_S = 20        -- relayed effects per client and second

local wanted_by_addr = {}      -- host: [asset address] = kind | false
local per_client = {}          -- host: [pc full name] = { t, n }
local missing = {}             -- client: [asset path] = true (logged once)

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function num(v, d)
    if type(v) == "number" then return v end
    return d
end

local function vec(v)
    if v == nil then return nil end
    local x = ue.try(function() return v.X end)
    local y = ue.try(function() return v.Y end)
    local z = ue.try(function() return v.Z end)
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

local function rot(v)
    if v == nil then return { Pitch = 0, Yaw = 0, Roll = 0 } end
    return { Pitch = num(ue.try(function() return v.Pitch end), 0), Yaw = num(ue.try(function() return v.Yaw end), 0),
             Roll = num(ue.try(function() return v.Roll end), 0) }
end

local function f2(v) return string.format("%.2f", v) end
local function f0(v) return string.format("%.0f", v) end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

-- The kind of an asset this module relays, or nil (cached by address: assets live long).
local function wanted(a)
    local k = addr(a)
    if not k then return nil end
    local w = wanted_by_addr[k]
    if w == nil then
        w = WANTED[ue.short(a)] or false
        wanted_by_addr[k] = w
    end
    return w or nil
end

local function budget_ok(pc_key, now)
    local b = per_client[pc_key]
    if not b or now - b.t >= 1 then
        b = { t = now, n = 0 }
        per_client[pc_key] = b
    end
    if b.n >= PER_CLIENT_S then return false end
    b.n = b.n + 1
    return true
end

-- How far a relayed sound goes: the cue's own range (its attenuation, read
-- from the asset; these are the values in its data) + a margin. Emitters and
-- decals keep SEND_CM: past the 150 m net range a client has no copy of the
-- zombie, and the flash is lost in the distance.
local SOUND_CM = { S_Beep_Cue = 12600, Infected_SpecialCue = 21000, explosion_large_06_Cue = 32500 }
local MARGIN_CM = 500
local skipped_n = 0
local function send_range(kind, asset)
    if kind ~= "s" then return SEND_CM end
    local snd = package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
    local r = snd.range_of(asset)
    return (r or SOUND_CM[ue.short(asset)] or SEND_CM) + MARGIN_CM
end

local function relay(kind, asset, loc, r, a, b, c, d, z)
    if not loc then return end
    local path = ue.path(asset)
    if path:sub(1, 6) ~= "/Game/" then return end
    local now = clock()
    local n = 0
    local range = send_range(kind, asset)
    local near = core.viewers_near(loc, range)
    local far = #core.host.viewers - #near
    if far > 0 then
        skipped_n = skipped_n + 1
        if skipped_n <= 20 then
            log.debug("ai: fx: %s of %s not sent to %d client(s) beyond %.0f m", ue.short(asset), ue.short(z), far, range / 100)
        end
    end
    for _, v in ipairs(near) do
        if budget_ok(v.key, now) then
            if net.send_to(v.pc, "AIFX", kind, path, f0(loc.X), f0(loc.Y), f0(loc.Z), f2(r.Pitch), f2(r.Yaw), f2(r.Roll),
                f2(a), f2(b), f2(c), f2(d)) then
                n = n + 1
            end
        end
    end
    M.stats.sent = M.stats.sent + n
    if n > 0 and core.first("fx.sent." .. ue.short(asset), 2) then
        log.info("ai: fx: %s of %s -> %d client(s)", ue.short(asset), ue.short(z), n)
    end
end

-- the zombie whose Blueprint made this call, or nil
local function zombie_of(wco_p)
    local w = get(wco_p)
    if ue.valid(w) and core.is_zombie(w) and ue.role(w) == ue.ROLE_AUTHORITY then return w end
    return nil
end

-- PlaySoundAtLocation(WorldContextObject, Sound, Location, Rotation, VolumeMultiplier, PitchMultiplier, ...), pre (host)
local function on_sound(_, wco_p, sound_p, loc_p, rot_p, vol_p, pitch_p)
    if not core.host.active or #core.host.viewers == 0 then return end
    local s = get(sound_p)
    if not ue.valid(s) or wanted(s) ~= "s" then return end
    local z = zombie_of(wco_p)
    if not z then return end
    relay("s", s, vec(get(loc_p)), rot(get(rot_p)), num(get(vol_p), 1), num(get(pitch_p), 1), 0, 0, z)
end

-- SpawnEmitterAtLocation(WorldContextObject, EmitterTemplate, Location, Rotation, Scale, ...), pre (host)
local function on_emitter(_, wco_p, tpl_p, loc_p, rot_p, scale_p)
    if not core.host.active or #core.host.viewers == 0 then return end
    local t = get(tpl_p)
    if not ue.valid(t) or wanted(t) ~= "e" then return end
    local z = zombie_of(wco_p)
    if not z then return end
    local sc = vec(get(scale_p)) or { X = 1, Y = 1, Z = 1 }
    relay("e", t, vec(get(loc_p)), rot(get(rot_p)), sc.X, sc.Y, sc.Z, 0, z)
end

-- SpawnDecalAtLocation(WorldContextObject, DecalMaterial, DecalSize, Location, Rotation, LifeSpan), pre (host)
local function on_decal(_, wco_p, mat_p, size_p, loc_p, rot_p, life_p)
    if not core.host.active or #core.host.viewers == 0 then return end
    local m = get(mat_p)
    if not ue.valid(m) or wanted(m) ~= "d" then return end
    local z = zombie_of(wco_p)
    if not z then return end
    local sz = vec(get(size_p)) or { X = 400, Y = 800, Z = 800 }
    relay("d", m, vec(get(loc_p)), rot(get(rot_p)), sz.X, sz.Y, sz.Z, num(get(life_p), 30), z)
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- AIFX|kind|asset|x|y|z|pitch|yaw|roll|a|b|c|d
local function on_fx(f)
    if core.S.role ~= "client" then return end
    local kind, path = f[1], f[2] or ""
    local part = CLASS_PART[kind or ""]
    if not part or path:sub(1, 6) ~= "/Game/" then return end
    local a = ue.find_object(path)
    if not a or not ue.class_name(a):find(part, 1, true) then
        M.stats.missing = M.stats.missing + 1
        if not missing[path] then
            missing[path] = true
            log.info("ai: fx: %s not in memory here; skipped (never loaded on a client)", path:match("([^%.]+)$") or path)
        end
        return
    end
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then return end
    local loc = { X = tonumber(f[3]) or 0, Y = tonumber(f[4]) or 0, Z = tonumber(f[5]) or 0 }
    local r = { Pitch = tonumber(f[6]) or 0, Yaw = tonumber(f[7]) or 0, Roll = tonumber(f[8]) or 0 }
    local p1, p2, p3, p4 = tonumber(f[9]) or 1, tonumber(f[10]) or 1, tonumber(f[11]) or 1, tonumber(f[12]) or 0
    local ok, err
    if kind == "s" then
        ok, err = pcall(function() gps:PlaySoundAtLocation(wc, a, loc, r, p1, p2, 0.0, nil, nil, nil, nil) end)
    elseif kind == "e" then
        ok, err = pcall(function() gps:SpawnEmitterAtLocation(wc, a, loc, r, { X = p1, Y = p2, Z = p3 }, true, 0, true) end)
    else
        ok, err = pcall(function() gps:SpawnDecalAtLocation(wc, a, { X = p1, Y = p2, Z = p3 }, loc, r, p4) end)
    end
    if not ok then
        log.err_throttled("ai.fx.play", "ai: fx: %s: %s", ue.short(a), tostring(err))
        return
    end
    M.stats.played = M.stats.played + 1
    if core.first("fx.played." .. ue.short(a), 2) then
        log.info("ai: fx: %s at %.0f %.0f %.0f (from the host)", ue.short(a), loc.X, loc.Y, loc.Z)
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function M.init(c)
    core = c
    core.hook({ path = GS .. "PlaySoundAtLocation", kind = "pre", role = "host", feature = "fx", name = "fx.sound",
                fn = on_sound })
    core.hook({ path = GS .. "SpawnEmitterAtLocation", kind = "pre", role = "host", feature = "fx", name = "fx.emitter",
                fn = on_emitter })
    core.hook({ path = GS .. "SpawnDecalAtLocation", kind = "pre", role = "host", feature = "fx", name = "fx.decal",
                fn = on_decal })
    log.info("sound relay AIFX (host): a zombie's sound to the clients within its own range + %.0f m (S_Beep_Cue %.0f m, Infected_SpecialCue %.0f m, explosion_large_06_Cue %.0f m; before: 160 m for all), played there with its attenuation; emitters and decals within %.0f m",
        MARGIN_CM / 100, SOUND_CM.S_Beep_Cue / 100, SOUND_CM.Infected_SpecialCue / 100, SOUND_CM.explosion_large_06_Cue / 100,
        SEND_CM / 100)
end

function M.host_tick(now)
    for k, b in pairs(per_client) do
        if now - b.t > 60 then per_client[k] = nil end
    end
end

function M.on_message(kind, f)
    if kind == "AIFX" then on_fx(f) end
end

function M.reset()
    per_client, missing = {}, {}
end

function M.status_line()
    local s = M.stats
    return string.format("ai: fx relayed=%d | client played=%d not in memory=%d", s.sent, s.played, s.missing)
end

return M
