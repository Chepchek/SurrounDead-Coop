-- SDCoop: combat details of other players' weapons.
--
-- * Bolt / pump cycling: after a shot the host plays the weapon's
--   ChamberFirearmMontage on the shooter's mesh (Svr_WeaponShot, host only),
--   so nobody else saw it. The host forwards it (MONT) and the others play it.
--   (The game's own MC_Montage multicast is no substitute: a server executes
--   a multicast too, which would restart the montage on the host and
--   interrupt the weapon's montage proxy with its Chamber notify / sound.)
--   MONT goes to the shooting client too, on purpose: Svr_WeaponShot is a
--   server RPC (a client's call runs only on the host), and its
--   @3222 -> Delay 0.5 -> @274-481 is the one place in the game that plays
--   the chamber montage, so without MONT a client never sees its own bolt /
--   pump cycle (work/audit/combat.md J). The 0.8.1 log review took MONT on
--   the own character for a restart of a montage already playing there; in
--   case some path ever does play it there, a client does not restart an
--   own chamber montage that MONT did not start itself (counted and logged,
--   "own ... already playing"). The first three plays on the own character
--   are logged ("own character") even when other players shot first.
--
-- * Melee hits of a remote player's NORMAL swing: the client detects them and
--   the host applies them with the game's own HitBody / HitHead (MHIT), see
--   the melee section.
--
-- * Loop reloads (rounds one at a time): the end of the owner's loop montage
--   and its after-reload chamber montage reach the other machines (RLSTOP),
--   see the loop reload section. Such a reload stops at the gun's capacity
--   (sdc_reloadcap, driven from here).
--
-- Camera shake of other players' shots is not handled here any more:
-- MC_WeaponEffects@2450 asks GetPlayerController(self, 0) for the camera and
-- sdc_ctx's client mode (client_quiet_others) answers "no player" for another
-- player's weapon, so the shake never starts. The old
-- StopAllInstancesOfCameraShake(class) after every foreign shot was redundant
-- and also stopped this player's own shake of the same class.

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local appearance = require("sdc_appearance")
local items = require("sdc_items")
local cfg = require("sdc_config")
local reloadcap = require("sdc_reloadcap")

local M = { stats = { montages_sent = 0, montages_played = 0, montages_own = 0, montages_own_busy = 0 },
            reloadcap = reloadcap }
local S
function M.init(state)
    S = state
    reloadcap.init(state)
end

local addr = ctx.addr

-- ---------------------------------------------------------------------------
-- Chamber montage (host -> everyone)
-- ---------------------------------------------------------------------------

local PROXY_FN = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"

local function is_player(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

local function locally_controlled(pawn)
    local ok, v = pcall(function() return pawn:IsLocallyControlled() end)
    return ok and v == true
end

-- true / false / nil (could not ask)
local function montage_playing(anim, montage)
    local ok, v = pcall(function() return anim:Montage_IsPlaying(montage) end)
    if not ok or type(v) ~= "boolean" then return nil end
    return v
end

-- client: [montage address] = os.clock() of the last MONT played on the own
-- character (a pump MONT can come while the previous one still plays: that
-- one is MONT's own and is restarted, as the host's copy restarts it)
local OWN_MONT_S = 5
local own_mont = {}

-- true when `montage` is the montage `prop` (ChamberFirearmMontage,
-- LoopReloadMontage...) of the BP_WeaponsPickupComponent of one of the
-- pawn's weapons
local function weapon_montage(pawn, montage, prop)
    local owned = ue.try(function() return pawn.Children end)
    local found = false
    pcall(function()
        owned:ForEach(function(_, e)
            local a = e:get()
            local comp = ue.prop(a, "BP_WeaponsPickupComponent")
            local cm = ue.prop(comp, prop)
            if ue.valid(cm) and addr(cm) == addr(montage) then found = true end
        end)
    end)
    return found
end

local function chamber_of(pawn, montage)
    -- the montage must be the chamber montage of one of the pawn's weapons
    return weapon_montage(pawn, montage, "ChamberFirearmMontage")
end

-- CreateProxyObjectForPlayMontage(InSkeletalMeshComponent, MontageToPlay,
-- PlayRate, StartingPosition, StartingSection, bShouldStopAllMontages), pre:
-- the rate is the first number after the montage (the weapon's
-- ChamberBaseSpeed); StartingPosition comes after it.
local function on_play_montage(...)
    if not S or S.role ~= "host" or #(S.remote_pcs or {}) == 0 then return end
    local mesh, montage, rate = nil, nil, nil
    for _, p in ipairs({ ... }) do
        local ok, v = pcall(function() return p:get() end)
        if ok and v ~= nil then
            if type(v) == "number" then
                if montage and rate == nil then rate = v end
            elseif ue.valid(v) then
                local cls = ue.class_name(v)
                if cls:find("SkeletalMeshComponent", 1, true) then mesh = v
                elseif cls == "AnimMontage" then montage = v end
            end
        end
    end
    if not mesh or not montage then return end
    local pawn = ue.try(function() return mesh:GetOwner() end)
    if not is_player(pawn) or not chamber_of(pawn, montage) then return end
    local id = appearance.player_id(pawn)
    if not id then return end
    if type(rate) ~= "number" or rate <= 0 then rate = 1.0 end
    net.broadcast(S.remote_pcs, "MONT", id, ue.path(montage), string.format("%.2f", rate))
    M.stats.montages_sent = M.stats.montages_sent + 1
    if M.stats.montages_sent <= 3 then
        log.info("combat: forwarding %s of %s (x%.2f)", ue.short(montage), ue.short(pawn), rate)
    end
end

-- One shared pre-only engine hook (sdc_ue.hook_native, each subscriber in its
-- own pcall); sdc_throw and sdc_ai_attacks watch the same native.
local montage_hooked = false
local function try_hook_montage()
    if montage_hooked then return end
    montage_hooked = true
    local ok, err = ue.hook_native(PROXY_FN, "combat.chamber", function(_, ...) on_play_montage(...) end)
    log.info("combat: montage hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- MONT|player id|montage path|rate (host -> clients). A message path: the
-- montage must already be in memory here (no synchronous load on a client).
local function play_forwarded(f)
    local id = tonumber(f[1])
    if not id or not f[2] then return end
    local montage = ue.loaded_asset(f[2], "combat MONT")
    if not montage then return end
    -- the path came over the network: Montage_Play does not check the type
    if ue.class_name(montage) ~= "AnimMontage" then
        log.err_throttled("mont-class", "combat: %s is a %s, not an AnimMontage; ignored", f[2], ue.class_name(montage))
        return
    end
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if appearance.player_id(p) == math.floor(id) and (S.role ~= "client" or ue.role(p) ~= ue.ROLE_AUTHORITY) then
            local mesh = ue.prop(p, "Mesh")
            local anim = ue.valid(mesh) and ue.try(function() return mesh:GetAnimInstance() end) or nil
            local own = S.role == "client" and locally_controlled(p)
            local ma = own and addr(montage)
            if own and ma and ue.valid(anim) and montage_playing(anim, montage) == true
                and os.clock() - (own_mont[ma] or -1e9) > OWN_MONT_S then
                -- see the header: not restarted
                M.stats.montages_own_busy = M.stats.montages_own_busy + 1
                if M.stats.montages_own_busy <= 3 then
                    log.warn("combat: own %s already playing here when the host's MONT came (not started by MONT); not restarted",
                        ue.short(montage))
                end
            elseif ue.valid(anim) and ue.valid(montage) then
                pcall(function() anim:Montage_Play(montage, tonumber(f[3]) or 1.0, 0, 0.0, true) end)
                M.stats.montages_played = M.stats.montages_played + 1
                if ma then
                    own_mont[ma] = os.clock()
                    M.stats.montages_own = M.stats.montages_own + 1
                end
                -- the first 3 plays, and the first 3 on the own character
                -- whoever shot first (the log alone shows that MONT reaches
                -- the shooter; the counts are in sdcoop_status only)
                if M.stats.montages_played <= 3 or (ma and M.stats.montages_own <= 3) then
                    log.info("combat: played %s on %s%s", ue.short(montage), ue.short(p),
                        ma and " (own character: the game plays it only on the host)" or "")
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Melee hits of remote players (client detects, host applies)
-- ---------------------------------------------------------------------------
-- A swing is traced on every machine that plays its montage:
-- Svr_Montage(montage, rate, IncludeLocal=true) -> MC_Montage -> the montage's
-- AnimNotify_MeleeHitDetect.Received_NotifyBegin starts a timer on the melee
-- weapon: MeleeTrace (normal) or MeleeTracePower (PowerAttack? on the notify)
-- -> SphereTraceMulti between the weapon's Start/End sockets ->
-- Event_OnHitNormal / Event_OnHitPower -> (surface) HitBody / HitHead ->
-- ApplyDamage. Only the host's ApplyDamage counts (pawns refuse damage on a
-- client: the client's own trace yields the "0" damage number).
-- On the host, the replay of a CLIENT's normal swing practically never hits
-- (0.6.12 session, gaptrace: 123 swing sounds of the client's knife on the
-- host, 9 flesh hits, all power-sized; the host's own knife: 41 of 42). The
-- replay runs a client-latency-old swing against the host's current zombie,
-- and the normal swing is the tight one: knife windows 0.30 s
-- (Chr_AN_ShortBlade_NormalAttack01-03, UpperBody slot), a 32 cm sphere, only
-- the first blocking hit counted, at most MaxMeleeHits (1) actor per swing.
-- Power swings (0.39-0.56 s, 36 cm, full-body lunge) and hits on standing
-- zombies still land. The client's own trace does hit.
-- So, as the game does for guns (the shooter traces, SERVER_DamageEvent
-- applies on the server): the client reports each hit of its own NORMAL swing
-- (MHIT), and the host runs the game's own HitBody / HitHead with it on its
-- copy of the weapon (stats, crit, strength, ApplyDamage, Client_HitUI,
-- Client_StrengthXP, Damage_Shoved, durability). The host's own trace keeps
-- running (trees, rocks, objects and standing targets still work through
-- it); a hit counts once: a relayed hit on a target the host's trace hit with
-- that weapon less than DUP_S ago is dropped, and a relayed hit that comes
-- first puts the target into HitActors, which keeps the host's trace off it
-- for the rest of that swing. Power swings stay with the host's trace.
-- Config melee_client_hits.

local MELEE = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C:"
local MELEE_SLOT = "Jig.PlayerSlot.MeleeWeapon"
local MATCH_R = 300      -- cm: reported target position -> host's actor of that class
local REACH = 450        -- cm: host's copy of the attacker -> target
local MAX_PER_S = 6      -- relayed hits per player and second
local DUP_S = 0.6        -- s: host trace hit -> same target's relayed hit is a duplicate

M.stats.melee_sent, M.stats.melee_applied, M.stats.melee_missed, M.stats.melee_dup = 0, 0, 0, 0

-- host_hits[weapon address][target address] = os.clock() of the host trace's hit
local melee = { hooked = {}, rate = {}, logged = {}, looping = false, host_hits = {}, applying = false }

local function melee_on()
    return cfg.get("melee_client_hits") ~= false
end

local function once(key, fmt, ...)
    if melee.logged[key] then return end
    melee.logged[key] = true
    log.info(fmt, ...)
end

local function fmt_vec(v)
    return string.format("%.0f,%.0f,%.0f", v.X, v.Y, v.Z)
end

local function parse_vec(s)
    local x, y, z = tostring(s or ""):match("^(%-?[%d.]+),(%-?[%d.]+),(%-?[%d.]+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z then return nil end
    return { X = x, Y = y, Z = z }
end

local function dist(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

local function remote_pc_of(pawn)
    local pc = ue.prop(pawn, "Controller")
    if ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) then return pc end
    return nil
end

local function melee_weapon_of(pawn)
    for _, it in pairs(items.equipped_of(pawn)) do
        if it.slot == MELEE_SLOT and ue.valid(it.actor) then return it.actor end
    end
    return nil
end

-- Hook arguments by kind (the BP hook gets the parameters in order; read by
-- value so a different parameter layout cannot shift them).
local function hit_args(...)
    local actor, loc, power = nil, nil, nil
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        local ok, v = pcall(function() return p:get() end)
        if ok then
            if type(v) == "boolean" then
                if power == nil then power = v end
            elseif ue.valid(v) then
                if not actor then actor = v end
            elseif v ~= nil and not loc then
                local x = ue.try(function() return v.X end)
                if type(x) == "number" then loc = { X = x, Y = v.Y, Z = v.Z } end
            end
        end
    end
    return actor, loc, power
end

-- Client: BP_MeleePickup.HitBody / HitHead ran for the own weapon (after the
-- function). Normal swings only; the host traces power swings itself.
local function on_own_hit(kind, c, ...)
    if not S or S.role ~= "client" or not melee_on() then return end
    local w = c and c:get()
    if not ue.valid(w) then return end
    local me = ue.local_pawn()
    local owner = ue.try(function() return w:GetOwner() end)
    if not me or not ue.valid(owner) or addr(owner) ~= addr(me) then return end
    local target, hit_loc, power = hit_args(...)
    if power == true or not ue.valid(target) or ue.class_name(target):find("PlayerCharacter", 1, true) then return end
    -- a corpse (zombie / boss IsDead?, Smart AI BP_AIComponent.Dead): the host has no
    -- live target there (the client's ragdoll may also have slid away from it)
    if ue.prop(target, "IsDead?") == true or ue.prop(ue.prop(target, "BP_AIComponent"), "Dead") == true then return end
    local tloc = ue.location(target)
    if not tloc then return end
    hit_loc = hit_loc or tloc
    if net.send_to_host("MHIT", kind, ue.class_name(target), fmt_vec(tloc), fmt_vec(hit_loc), ue.class_name(w)) then
        M.stats.melee_sent = M.stats.melee_sent + 1
        if M.stats.melee_sent <= 5 then
            log.info("melee: own %s hit on %s reported to the host", kind, ue.short(target))
        end
    end
end

-- Host: a HitBody / HitHead of a remote player's weapon that the host's own
-- trace produced (not one of ours): remembered for the duplicate check.
local function on_host_trace_hit(c, ...)
    if melee.applying then return end
    local w = c and c:get()
    if not ue.valid(w) then return end
    local owner = ue.try(function() return w:GetOwner() end)
    if not ue.valid(owner) or not remote_pc_of(owner) then return end
    local target = hit_args(...)
    local wa, ta = addr(w), addr(target)
    if not wa or not ta then return end
    local per = melee.host_hits[wa]
    if not per then per = {}; melee.host_hits[wa] = per end
    per[ta] = os.clock()
end

local function on_hit_fn(kind, c, ...)
    if not S then return end
    if S.role == "client" then return on_own_hit(kind, c, ...) end
    if S.role == "host" then return on_host_trace_hit(c, ...) end
end

-- Host: the nearest live actor of that class around the reported position.
local function find_target(cls, at)
    local best, best_d = nil, MATCH_R
    for _, a in ipairs(ue.find_all(cls)) do
        if ue.valid(a) and ue.prop(a, "IsDead?") ~= true then
            local l = ue.location(a)
            local d = l and dist(l, at)
            if d and d < best_d then best, best_d = a, d end
        end
    end
    return best, best_d
end

-- Host: MHIT|body/head|target class|target x,y,z|hit x,y,z|weapon class
local function on_mhit(f, pc)
    if not S or S.role ~= "host" or not melee_on() or not ue.valid(pc) then return end
    local kind, cls, at, hit = f[1], f[2] or "", parse_vec(f[3]), parse_vec(f[4])
    if (kind ~= "body" and kind ~= "head") or cls == "" or not at or not hit then return end
    if cls:find("PlayerCharacter", 1, true) then return end
    local k = addr(pc)
    local now = os.clock()
    local r = melee.rate[k]
    if not r or now - r.t >= 1 then r = { t = now, n = 0 }; melee.rate[k] = r end
    r.n = r.n + 1
    if r.n > MAX_PER_S then return end
    local pawn = ue.pawn_of(pc)
    local w = pawn and melee_weapon_of(pawn)
    if not w then return end
    if f[5] and f[5] ~= "" and ue.class_name(w) ~= f[5] then
        once("wclass|" .. f[5], "melee: %s reports a hit with %s, the host has %s in the melee slot; ignored",
            ue.short(pc), f[5], ue.class_name(w))
        return
    end
    local target, d = find_target(cls, at)
    local ploc = ue.location(pawn)
    local tloc = target and ue.location(target)
    if not target or not ploc or not tloc or dist(ploc, tloc) > REACH then
        M.stats.melee_missed = M.stats.melee_missed + 1
        log.err_throttled("melee-miss", "melee: %s's hit on %s not applied: no live one within %d cm of %s (or out of reach)",
            ue.short(pc), cls, MATCH_R, f[3])
        return
    end
    local per = melee.host_hits[addr(w)]
    local th = per and per[addr(target)]
    if th and os.clock() - th < DUP_S then
        M.stats.melee_dup = M.stats.melee_dup + 1
        once("dup|" .. tostring(k), "melee: %s's hit on %s already landed through the host's own trace; not applied twice",
            ue.short(pc), ue.short(target))
        return
    end
    -- the hit point moves with the host's copy of the target
    local hl = { X = hit.X + tloc.X - at.X, Y = hit.Y + tloc.Y - at.Y, Z = hit.Z + tloc.Z - at.Z }
    local fn = kind == "head" and "HitHead" or "HitBody"
    melee.applying = true
    local ok, err = pcall(function() w[fn](w, target, hl, false) end)
    melee.applying = false
    if ok then
        M.stats.melee_applied = M.stats.melee_applied + 1
        if M.stats.melee_applied <= 5 then
            log.info("melee: %s's %s hit on %s applied with the game's %s (matched %.0f cm)", ue.short(pc), kind,
                ue.short(target), fn, d)
        end
    else
        log.err_throttled("melee-apply", "melee: %s(%s) failed: %s", fn, ue.short(target), tostring(err))
    end
end

local function try_melee_hooks()
    local function hook(key, path, cb)
        if melee.hooked[key] then return end
        local ok = pcall(RegisterHook, path, function(c, ...)
            local okc, err = pcall(cb, c, ...)
            if not okc then log.err_throttled("melee." .. key, "melee: %s hook: %s", key, tostring(err)) end
        end)
        if ok then
            melee.hooked[key] = true
            log.info("melee: %s hook ok", key)
        end
    end
    hook("HitBody", MELEE .. "HitBody", function(c, ...) on_hit_fn("body", c, ...) end)
    hook("HitHead", MELEE .. "HitHead", function(c, ...) on_hit_fn("head", c, ...) end)
end

-- The weapon class loads with the first melee weapon: retried every
-- 2 s on both roles until in (independent of the session ticks); the retry
-- chain ends once both hooks are in.
local function start_melee()
    if melee.looping then return end
    melee.looping = true
    local function retry()
        try_melee_hooks()
        if melee.hooked.HitBody and melee.hooked.HitHead then return end
        ue.delay("combat-melee-hooks", 2000, retry)
    end
    ue.delay("combat-melee-hooks", 2000, retry)
end

-- ---------------------------------------------------------------------------
-- Loop reloads (rounds one at a time)
-- ---------------------------------------------------------------------------
-- Weapons with a LoopReloadMontage: hunting rifle, Mosin, Marksman's Legacy
-- (AN_BoltAction_TopReloadA/B/C), pump / sawn-off / Benelli / Exterminator
-- shotguns (Chr_AN_Shotgun_ReloadA/B), Winchester, Deadeye
-- (AN_Handgun_Revolver_ReloadA/B/C), grenade launcher.
-- BP_PlayerCharacter, on the owner's machine only (reload input):
--   ReloadMontage A, then Svr_Montage(LoopReloadMontage B, 1, IncludeLocal=
--   false) @69431 and the local proxy @69852. B has one section "Default"
--   whose next section is itself: it loops until somebody stops it. Each
--   loop's Round_In / Shell_In notify loads one round
--   (OnNotifyBegin_8ACC... @90435 -> Jig_StartReloading); when the magazine
--   is full: Delay 0.25 -> StopAnimMontage(None) @5053 ->
--   ChamberAfterReloadWeapon -> PlayChamberAfterReloadMontage(C) @105267
--   (closing the bolt / pump), local only as well.
-- Every other machine got B through MC_Montage (@139929: the host's copy of
-- a client and the clients' copies of the host) and nothing ever stopped it
-- there: the other player's character went on reloading for good, with an
-- insert sound on every loop (Jig_OnMontageNotify Round_In; 0.8.0 host
-- gaptrace: 50 Winchester inserts of a client).
-- Here, on the owner's machine (host or client) while others are connected:
--   * the own loop montage stops -> the game's own Svr_StopMontage(B,
--     IncludeLocal=false) -> MC_StopMontage -> StopAnimMontage(B) on every
--     other machine (@139731); RLSTOP (mod channel, reliable) backs up the
--     unreliable game RPCs;
--   * PlayChamberAfterReloadMontage(C, speed) -> Svr_Montage(C, speed, false),
--     sent as the game sends A and B.
-- The owner's own loop needs nothing: should its StopAnimMontage(None) hit
-- another montage, the next Round_In finds the magazine full and stops again
-- (@90647 -> 5053). Only logged: a loop still playing 2 s after the game's
-- reload ended (Reloading? false) or for 20 s.
-- Config reload_loop_fix.
-- Capacity (sdc_reloadcap): the owner's machine decides each round with
-- exact checks on its own copy of the count (Cap == Max: full; Max - Cap ==
-- 1: the last one) and the host adds what it is asked for. A client whose
-- count came back late (lag, or several Round_In in one frame after a
-- hitch) loaded past the capacity, and from then on every reload of that
-- gun took the whole reserve (2026-11-13: a sawn-off with 42 of 6). Now the
-- client counts its own requests at once and the game's checks stop at the
-- capacity by themselves; the host never keeps more than the capacity.

local PLAYER_BP = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local RL_POLL_MS = 100     -- ms: own loop montage check
local RL_HOOK_S = 2        -- s: retry of the PlayChamberAfterReloadMontage hook
local RL_ORPHAN_S = 2      -- s: an own loop montage outliving the game's Reloading? is logged
local RL_LONG_S = 20       -- s: an own loop montage playing this long is logged
local RL_NO_TTL = 10       -- s: "not a loop montage" cache

M.stats.rl_started, M.stats.rl_ended, M.stats.rl_orphans, M.stats.rl_chamber = 0, 0, 0, 0
M.stats.rl_stopped, M.stats.rl_idle = 0, 0

-- montage: the own loop montage being watched (an asset); pawn: address of
-- the own character it plays on
local rl = { montage = nil, pawn = nil, since = 0, unreloaded = nil, long_logged = false,
             known = {}, hooked = false, hook_at = -100, looping = false }

local function reload_on()
    return cfg.get("reload_loop_fix") ~= false
end

local function coop_active()
    if not S then return false end
    if S.role == "host" then return #(S.remote_pcs or {}) > 0 end
    return S.role == "client"
end

local function anim_of(pawn)
    local mesh = ue.prop(pawn, "Mesh")
    if not ue.valid(mesh) then return nil end
    local anim = ue.try(function() return mesh:GetAnimInstance() end)
    if ue.valid(anim) then return anim end
    return nil
end

local function is_loop_montage(pawn, montage)
    local a = addr(montage)
    if not a then return false end
    local k = rl.known[a]
    local now = os.clock()
    if k == true then return true end
    if k and now - k < RL_NO_TTL then return false end
    local yes = weapon_montage(pawn, montage, "LoopReloadMontage")
    rl.known[a] = yes or now
    return yes
end

-- Owner: the own loop montage `montage` stopped here; stop it on the others.
local function send_loop_end(pawn, montage, why)
    local ok, err = pcall(function() pawn:Svr_StopMontage(montage, false) end)
    if not ok then
        log.err_throttled("rl-svrstop", "combat: Svr_StopMontage(%s): %s", ue.short(montage), tostring(err))
    end
    local id = appearance.player_id(pawn)
    if id then
        local path = ue.path(montage)
        if S.role == "client" then
            net.send_to_host("RLSTOP", id, path)
        else
            net.broadcast(S.remote_pcs, "RLSTOP", id, path)
        end
    end
    M.stats.rl_ended = M.stats.rl_ended + 1
    pcall(reloadcap.loop_ended)   -- the reload is over: its next one starts from the widget again
    if M.stats.rl_ended <= 5 or why ~= "finished" then
        log.info("combat: own loop reload %s ended here (%s, %.1f s) -> stopped on the other machines (Svr_StopMontage %s, RLSTOP %s)",
            ue.short(montage), why, os.clock() - rl.since, ok and "sent" or "FAILED", id and "sent" or "no player id")
    end
end

-- Owner: PlayChamberAfterReloadMontage(C, speed) ran here (BP hook, after
-- the function). Sent to the others the way the game sends A and B, one
-- frame later (not from inside the game's call).
local function on_chamber_after_reload(c, m_p, s_p)
    if not reload_on() or not coop_active() then return end
    local pawn = c and c:get()
    if not is_player(pawn) or not locally_controlled(pawn) then return end
    local m = m_p and m_p:get()
    if not ue.valid(m) or ue.class_name(m) ~= "AnimMontage" then return end
    local speed = tonumber(s_p and s_p:get()) or 1.0
    if speed <= 0 then speed = 1.0 end
    local pa = addr(pawn)
    ue.delay("combat-reload-chamber", 1, function()
        local me = ue.local_pawn()
        if not me or addr(me) ~= pa or not ue.valid(m) then return end
        local ok, err = pcall(function() me:Svr_Montage(m, speed, false) end)
        if not ok then
            log.err_throttled("rl-svrmont", "combat: Svr_Montage(%s): %s", ue.short(m), tostring(err))
            return
        end
        M.stats.rl_chamber = M.stats.rl_chamber + 1
        if M.stats.rl_chamber <= 3 then
            log.info("combat: own after-reload chamber %s (x%.2f) sent to the other machines", ue.short(m), speed)
        end
    end)
end

local function try_reload_hooks(now)
    if rl.hooked or now - rl.hook_at < RL_HOOK_S then return end
    rl.hook_at = now
    -- fails quietly until BP_PlayerCharacter is loaded
    local ok = pcall(RegisterHook, PLAYER_BP .. "PlayChamberAfterReloadMontage", function(c, m_p, s_p)
        local okc, err = pcall(on_chamber_after_reload, c, m_p, s_p)
        if not okc then log.err_throttled("rl-chamber", "combat: PlayChamberAfterReloadMontage hook: %s", tostring(err)) end
    end)
    if ok then
        rl.hooked = true
        log.info("combat: PlayChamberAfterReloadMontage hook ok")
    end
end

-- Owner, every RL_POLL_MS: watch the own loop montage.
local function reload_tick()
    if not reload_on() or not coop_active() then
        rl.montage = nil
        return
    end
    local now = os.clock()
    try_reload_hooks(now)
    local pawn = ue.local_pawn()
    if not pawn or not is_player(pawn) then
        rl.montage = nil
        return
    end
    local pa = addr(pawn)
    if rl.montage then
        -- a new own character (respawn): the old one's montage is gone with it
        if rl.pawn ~= pa then
            rl.montage = nil
            return
        end
        local anim = anim_of(pawn)
        local playing = anim and montage_playing(anim, rl.montage)
        if playing == nil then return end
        if not playing then
            local m = rl.montage
            rl.montage = nil
            send_loop_end(pawn, m, "finished")
            return
        end
        -- diagnosis only: the game's reload is over, the loop still plays here
        if ue.prop(pawn, "Reloading?") == false then
            rl.unreloaded = rl.unreloaded or now
            if rl.unreloaded ~= true and now - rl.unreloaded >= RL_ORPHAN_S then
                M.stats.rl_orphans = M.stats.rl_orphans + 1
                log.warn("combat: own loop reload %s still plays %.1f s after the game's reload ended (Reloading? false)",
                    ue.short(rl.montage), now - rl.unreloaded)
                rl.unreloaded = true   -- once per loop
            end
        elseif rl.unreloaded ~= true then
            rl.unreloaded = nil
        end
        if not rl.long_logged and now - rl.since >= RL_LONG_S then
            rl.long_logged = true
            log.warn("combat: own loop reload %s has been playing for %.0f s (Reloading?=%s)",
                ue.short(rl.montage), now - rl.since, tostring(ue.prop(pawn, "Reloading?")))
        end
        return
    end
    local cur = ue.try(function() return pawn:GetCurrentMontage() end)
    if not ue.valid(cur) or not is_loop_montage(pawn, cur) then return end
    rl.montage, rl.pawn, rl.since, rl.unreloaded, rl.long_logged = cur, pa, now, nil, false
    M.stats.rl_started = M.stats.rl_started + 1
    if M.stats.rl_started <= 3 then log.info("combat: own loop reload %s started", ue.short(cur)) end
end

-- Another player's character on this machine: stop its loop montage.
local function stop_copy(pawn, montage)
    if not is_player(pawn) or locally_controlled(pawn) then return "own" end
    local anim = anim_of(pawn)
    if not anim then return "noanim" end
    if montage_playing(anim, montage) ~= true then return "idle" end
    if pcall(function() pawn:StopAnimMontage(montage) end) then return "stopped" end
    return "failed"
end

local function count_stop(res, pawn, montage, via)
    if res == "stopped" then
        M.stats.rl_stopped = M.stats.rl_stopped + 1
        if M.stats.rl_stopped <= 5 then
            log.info("combat: %s's loop reload %s stopped here by %s (the game's MC_StopMontage had not stopped it)",
                ue.short(pawn), ue.short(montage), via)
        end
    elseif res == "idle" then
        M.stats.rl_idle = M.stats.rl_idle + 1
    elseif res == "failed" then
        log.err_throttled("rl-stop", "combat: StopAnimMontage(%s) on %s failed", ue.short(montage), ue.short(pawn))
    end
end

-- RLSTOP|player id|montage path
--   client -> host: the sender's own loop reload ended (host: its copy, then
--   the other clients); host -> client: that player's one ended.
local function on_rlstop(f, pc)
    if not S or not reload_on() then return end
    local id = tonumber(f[1])
    local path = f[2]
    if not id or not path or path == "" then return end
    id = math.floor(id)
    -- not loaded here = not playing here; the path came over the network
    local montage = ue.find_object(path)
    if not montage or ue.class_name(montage) ~= "AnimMontage" then return end
    if S.role == "host" then
        local pawn = ue.valid(pc) and ue.pawn_of(pc) or nil
        if not pawn or appearance.player_id(pawn) ~= id then return end
        count_stop(stop_copy(pawn, montage), pawn, montage, "RLSTOP")
        local from = addr(pc)
        for _, other in ipairs(S.remote_pcs or {}) do
            if addr(other) ~= from then net.send_to(other, "RLSTOP", id, path) end
        end
    elseif S.role == "client" then
        for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
            if appearance.player_id(p) == id then count_stop(stop_copy(p, montage), p, montage, "RLSTOP") end
        end
    end
end

local function start_reload_watch()
    if rl.looping then return end
    rl.looping = true
    ue.every("combat-reload", RL_POLL_MS, reload_tick)
end

-- ---------------------------------------------------------------------------

-- Called once at startup (sdc_session.install_item_watch).
function M.install()
    start_melee()
    start_reload_watch()
    reloadcap.install()
    -- AN_BoltAction_Rerack_Anim_Montage / Chr_AN_Shotgun_Pump_Montage hold only
    -- AnimNotify_PlayMontageNotify (named notifies), no sound notify
    log.info("sound relay MONT / RLSTOP: no sound (the chamber montages have no sound notifies; RLSTOP ends other players' loop reloads, whose insert sounds sdc_ownsounds' guard keeps at 15.5 m)")
end

-- World change: the watched montage belonged to the old character.
function M.reset(why)
    rl.montage, rl.pawn, rl.unreloaded = nil, nil, nil
    own_mont = {}
    reloadcap.reset()
    log.debug("combat: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    return string.format("combat: chamber sent=%d played=%d (own=%d, own already playing=%d) | loop reloads own=%d ended=%d outlived-reload=%d after-reload chamber=%d | others stopped by RLSTOP=%d already stopped=%d | hook=%s | melee sent=%d applied=%d missed=%d dup=%d | %s",
        s.montages_sent, s.montages_played, s.montages_own, s.montages_own_busy, s.rl_started, s.rl_ended, s.rl_orphans, s.rl_chamber,
        s.rl_stopped, s.rl_idle, tostring(rl.hooked), s.melee_sent, s.melee_applied, s.melee_missed,
        s.melee_dup, reloadcap.status_line())
end

function M.host_tick()
    try_hook_montage()
    local now = os.clock()
    for wa, per in pairs(melee.host_hits) do
        for ta, t in pairs(per) do
            if now - t > 5 then per[ta] = nil end
        end
        if next(per) == nil then melee.host_hits[wa] = nil end
    end
end

function M.register_handlers()
    -- host -> clients: MONT|player id|montage path|rate
    net.on("MONT", play_forwarded)
    -- client -> host: MHIT|body/head|target class|target x,y,z|hit x,y,z|weapon class
    net.on("MHIT", function(f, pc)
        local ok, err = pcall(on_mhit, f, pc)
        if not ok then log.err_throttled("melee-mhit", "melee: MHIT: %s", tostring(err)) end
    end)
    -- RLSTOP|player id|montage path (both directions): a loop reload ended
    net.on("RLSTOP", on_rlstop)
    -- sdc_reloadcap: RLNOTE (host -> the player whose gun was set right)
    reloadcap.register_handlers()
end

return M
