-- SDCoop: friendly fire on / off (0.7.3; host setting friendly_fire,
-- default off: players cannot hurt each other).
--
-- The game has no PvP switch. Every hit on a player ends in the host's
-- GameplayStatics.ApplyDamage (pawns refuse damage without authority), with
-- the attacker as DamageCauser (work\re\pseudo):
--   firearm, crossbow bolt   GetOwner() = the shooter       BP_FirearmPickup @4267 / @5454
--   melee HitBody / HitHead  GetOwner() = the swinger       BP_MeleePickup @665 / @752
--   stomp                    self = the stomping character  BP_PlayerCharacter @1530
--   frag, pipe bomb, launcher grenade / rocket: GetPlayerCharacter(self, 0)
--     (BP_Throwable_Frag @2411, BP_ProjectileGrenade / Rocket): sdc_ctx
--     answers the thrower's character inside a client's throw (the host's
--     copy is owned by it, sdc_throw), the host's for its own.
-- World damage has another causer and passes: falls, bleeding (MedicalComponent
-- Svr_Damage), a burn's tick (None), barrels, landmines, bear traps, turrets,
-- a destroyed car's driver (that object), zombies, people and animals (the
-- AI). Hunger, thirst, radiation, drowning and infection name the victim
-- itself: its own damage.
-- A Molotov passes no causer: its fire calls SetBurning(true) on every
-- player within 500 cm that is not burning (BP_Throwable_Molotov @2157);
-- the burn then hurts every 0.8 s (Event_Fire: ApplyDamage(self, d, None)).
--
-- Host, friendly_fire off (subscribers of sdc_ai's shared engine hooks,
-- sdc_ai.hook_external; installed from this module's tick, since sdc_ai's
-- own tick runs only while one of its features is on):
--   ApplyDamage, pre: a BP_PlayerCharacter_C victim and ANOTHER player's
--     character as the causer -> BaseDamage 0. The engine then skips
--     TakeDamage (`BaseDamage != 0`): no health change, flinch, blood,
--     camera shake or Toughness XP. Your own grenade still hurts you
--     (victim == causer). A causer that is the host's character right after
--     a client's explosive went off near the victim (sdc_throw.blast_now:
--     who threw it) is that client: sdc_ctx's "player 0" fell back to the
--     host (redirect_player0 off, or the thrower's character gone before
--     the fuse ended). So it does not hurt the host, and it hurts its
--     thrower as the thrower's own. Only for an explosive's damage class
--     (Damage_Body_C: frag @2411, pipe bomb @2392, launcher grenade /
--     rocket @1111): the host's own ticks name its character as the causer
--     too - hunger, thirst (HungerThirstComponent), radiation, drowning
--     (SwimmingComponent) with DamageType, infection (MedicalComponent) with
--     None - and stay the host's own in that moment.
--   SetBurning(true), post: a burn from another player's Molotov is put out
--     at once (StopBurning: no particle, no Event_Fire timer; the fire tries
--     again every 0.8 s and is put out again). Whose fire: sdc_throw's
--     tracked fires (fire point, thrower); a Molotov it did not track
--     (throw_sync off: the host's own) by its actor within 700 cm, thrower =
--     its Owner, else the host. A fire of the victim's own wins (it walked
--     into its own fire). Barrels and other burns are not touched.
--   Switched off while players burn: a burn a teammate's Molotov started
--     while it was on goes on by itself (Event_Fire every 0.8 s for 10-12 s;
--     the fire skips a burning player, so SetBurning does not run again),
--     and the burning player usually runs out of the fire. So the SetBurning
--     hook runs while friendly fire is on too (host: players connected;
--     client: the host's rule known) and only remembers whose fire set the
--     character burning, judged where it caught fire. The next tick after
--     the switch puts out every burning player character (Burning?) that
--     another player's fire set burning within BURN_MAX_S, wherever it is
--     now; one with no such record is judged where it stands. Clients do the
--     same with their copies' burns when the host's rule turns off.
-- Clients (RULES|ff from the host's sdc_admin): their copies of a teammate's
-- Molotov fire show a burning character (the copy's burn hurts nobody on a
-- client): put out the same way, by sdc_throw's copies (own throw, or the
-- thrower's PlayerId). A game notice on joining a world with friendly fire
-- on and when the host switches it: once this player has its character and
-- the join cover is gone.
-- Not changed: XP for shooting / hitting a teammate (granted before
-- ApplyDamage), a teammate's grenade still shakes the camera and pushes.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local ai = require("sdc_ai")

local M = {
    stats = { blocked = 0, own = 0, blast_fix = 0, burns_out = 0, burns_kept = 0, untracked = 0, copies_out = 0,
              stop_failed = 0, notices = 0, swept = 0, swept_lit = 0 },
}

local PLAYER_CLASS = "BP_PlayerCharacter_C"
local MOLOTOV_CLASS = "BP_Throwable_Molotov_C"
local APPLY_DAMAGE = "/Script/Engine.GameplayStatics:ApplyDamage"
local SET_BURNING = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetBurning"
local BLAST_S = 0.25         -- s: a blast's damage loop runs right after its sound (one Blueprint call)
local BLAST_CM = 1500        -- the largest blast (rocket 1200 cm) and a margin
-- the explosives' DamageTypeClass (work\re\pseudo: BP_Throwable_Frag @2411,
-- BP_Throwable_PipeBomb @2392, BP_ProjectileGrenade / Rocket @1111)
local BLAST_DAMAGE = { Damage_Body_C = true }
local FIRE_CM = 600          -- the fire burns players within 500 cm of its point, plus the capsule
local UNTRACKED_CM = 700     -- an untracked Molotov's actor (it may roll after its fire started)
local LOG_N = 5              -- the first blocks / put-outs of a kind at info, then debug
local BURN_LOG_S = 10        -- s between log lines of one character's put-out burns
-- s a SetBurning(true) record stands for the burn now: it lasts 10-12 s
-- (Delay RandomFloatInRange(10, 12), BP_PlayerCharacter @45895), plus the tick
local BURN_MAX_S = 12.5

local S = nil
local addr = ctx.addr
local cls_name = ctx.class_name or ue.class_name
local hooks = {}             -- sdc_ai's hook handles: damage, burn (.installed)
local client = { ff = nil, told = nil }   -- client: the host's rule (nil: not said), the last one told the player
local host_ff = nil          -- host: friendly_fire as last seen (logged on a change)
local last_role = nil
local burn_logged = {}       -- [character address] = clock() of its last put-out line
local lit = {}               -- [character address] = verdict of its last SetBurning(true) (+ t = clock())

local function ff_on() return cfg.get("friendly_fire") == true end

local function p_get(p) return p:get() end
local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(p_get, p)
    if ok then return v end
    return nil
end

-- A hook parameter / GetOwner() with no object is a null UObject, not nil:
-- GetClass on it reads address 0x10 and the game dies (pcall cannot catch
-- it). The host crashed so on 2026-11-13 17:36: ApplyDamage of a bleeding
-- tick (MedicalComponent HeavyBleed -> Svr_Damage) passes DamageCauser None;
-- falls and burns do too. ue.valid first, always.
local function is_player(o)
    if o == nil or not ue.valid(o) then return false end
    local ok, n = pcall(cls_name, o)
    return ok and n == PLAYER_CLASS
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function throw_mod()
    local t = package.loaded["sdc_throw"]
    return type(t) == "table" and t or nil
end

local function pc_addr_of(pawn)
    local pc = ue.prop(pawn, "Controller")
    if not ue.valid(pc) then return nil end
    return addr(pc)
end

-- Host's log: a character as its player's name ("host" for its own).
local function label(pawn)
    local me = ue.local_pawn()
    if me ~= nil and addr(me) == addr(pawn) then return "host" end
    local pc = ue.prop(pawn, "Controller")
    local r = ue.valid(pc) and S and S.remote and S.remote[ue.name(pc)] or nil
    if r and r.name then return tostring(r.name) end
    return ue.short(pawn)
end

-- Host's log: the name of the player with this controller address (nil:
-- the host, or not known).
local function pc_name(a)
    if a == nil or not S then return nil end
    for _, r in pairs(S.remote or {}) do
        if ue.valid(r.pc) and addr(r.pc) == a then return r.name and tostring(r.name) or nil end
    end
    return nil
end

-- the first LOG_N of a counter at info, then debug (nil: nothing to format)
local function line(n)
    if n <= LOG_N then return log.info end
    if log.debug_enabled then return log.debug end
    return nil
end

local function remote_present() return S ~= nil and #(S.remote_pcs or {}) > 0 end
local function host_blocks() return S ~= nil and S.role == "host" and not ff_on() and remote_present() end
local function client_blocks() return S ~= nil and S.role == "client" and client.ff == false end
-- the SetBurning hook, on or off (remembers who set whom burning)
local function burn_watch()
    if S == nil then return false end
    if S.role == "host" then return remote_present() end
    return S.role == "client" and client.ff ~= nil
end

-- ---------------------------------------------------------------------------
-- Host: player-on-player damage
-- ---------------------------------------------------------------------------

-- A client's explosive that went off right now near `victim` (sdc_throw's
-- record), or nil.
local function client_blast_at(victim)
    local t = throw_mod()
    local b = t and type(t.blast_now) == "function" and t.blast_now(BLAST_S) or nil
    if not b or not b.pc or not b.loc then return nil end
    local l = ue.location(victim)
    if not l or dist(l, b.loc) > BLAST_CM then return nil end
    return b
end

-- An explosive's damage class (DamageTypeClass param; None or DamageType:
-- the host's own hunger, thirst, radiation, drowning, infection).
local function blast_damage(type_p)
    local c = get(type_p)
    if not ue.valid(c) then return false end
    return BLAST_DAMAGE[ue.short(c)] == true
end

-- GameplayStatics.ApplyDamage(DamagedActor, BaseDamage, EventInstigator,
-- DamageCauser, DamageTypeClass), pre (host, friendly fire off).
local function on_damage(_, victim_p, dmg_p, _, causer_p, type_p)
    local victim = get(victim_p)
    if not is_player(victim) then return end
    local causer = get(causer_p)
    if not is_player(causer) then return end
    local va, ca = addr(victim), addr(causer)
    if va == nil or ca == nil then return end
    local from = nil
    local host = ue.local_pawn()
    if host and ca == addr(host) then
        -- "player 0" of a client's explosive fell back to the host? Only an
        -- explosive's damage: the host's own ticks in that moment are its own
        local b = client_blast_at(victim)
        if b and blast_damage(type_p) then
            if b.pc == pc_addr_of(victim) then
                M.stats.own = M.stats.own + 1
                return   -- the thrower's own blast hurts it
            end
            M.stats.blast_fix = M.stats.blast_fix + 1
            from = string.format("%s's %s (its thrower; the game named the host)", tostring(pc_name(b.pc) or b.who),
                tostring(b.short))
        end
    end
    if not from and va == ca then
        M.stats.own = M.stats.own + 1
        return   -- own damage (a grenade at one's own feet)
    end
    local dmg = tonumber(get(dmg_p)) or 0
    local ok = pcall(function() dmg_p:set(0.0) end)
    M.stats.blocked = M.stats.blocked + 1
    local say = line(M.stats.blocked)
    if say then
        say("ffire: %.1f damage to %s from %s dropped (friendly fire off)%s", dmg, label(victim), from or label(causer),
            ok and "" or " - FAILED: the damage could not be changed")
    end
end

-- ---------------------------------------------------------------------------
-- Molotov burns (host: the real burn; client: its copies' visual one)
-- ---------------------------------------------------------------------------

-- Host: own = a fire near `pawn` is its own, other = one is another
-- player's; by = that player (log); untracked = judged by actors.
local function judge_host(pawn, loc)
    local t = throw_mod()
    local fires = t and type(t.fires_near) == "function" and t.fires_near(loc, FIRE_CM) or {}
    local host = ue.local_pawn()
    local is_host = host ~= nil and addr(host) == addr(pawn)
    local vpc = (not is_host) and pc_addr_of(pawn) or nil
    local own, other, by = false, false, nil
    for _, f in ipairs(fires) do
        local mine
        if f.pc == nil then mine = is_host else mine = vpc ~= nil and f.pc == vpc end
        if mine then own = true else other, by = true, by or pc_name(f.pc) or f.who end
    end
    if #fires > 0 then return own, other, by, false end
    -- not tracked (throw_sync off, or thrown before a client came): the
    -- Molotov actors near it; the thrower is the Owner (a client's throw on
    -- the host), else the host (the game's own throw has none)
    for _, m in ipairs(ue.find_all(MOLOTOV_CLASS)) do
        local l = ue.valid(m) and ue.location(m) or nil
        if l and dist(l, loc) <= UNTRACKED_CM then
            local o = ue.try(function() return m:GetOwner() end)
            local thrower = is_player(o) and o or host
            if thrower ~= nil and addr(thrower) == addr(pawn) then
                own = true
            else
                other, by = true, by or (thrower and label(thrower) or "?")
            end
        end
    end
    return own, other, by, true
end

-- Client: the same by its copies (own = this player's throw, who = the
-- thrower's PlayerId).
local function judge_client(pawn, loc)
    local t = throw_mod()
    local fires = t and type(t.fires_near) == "function" and t.fires_near(loc, FIRE_CM) or {}
    if #fires == 0 then return false, false end
    local me = ue.local_pawn()
    local is_me = me ~= nil and addr(me) == addr(pawn)
    local id = nil
    if not is_me then
        local ap = package.loaded["sdc_appearance"]
        local n = type(ap) == "table" and type(ap.player_id) == "function" and ap.player_id(pawn) or nil
        id = n ~= nil and tostring(n) or nil
    end
    local own, other = false, false
    for _, f in ipairs(fires) do
        if is_me then
            if f.own then own = true else other = true end
        elseif f.own then
            other = true   -- this player's fire on a teammate
        elseif f.who ~= nil and id ~= nil then
            if f.who == id then own = true else other = true end
        end
    end
    return own, other, nil
end

-- The Molotov fires near a player character at loc: { own, other, by,
-- untracked } (judge_host / judge_client).
local function judge(pawn, loc)
    local v = {}
    if S.role == "host" then
        v.own, v.other, v.by, v.untracked = judge_host(pawn, loc)
    else
        v.own, v.other = judge_client(pawn, loc)
    end
    return v
end

-- A burning player character: put out when the verdict v says only another
-- player's Molotov fire set it burning / is near it (true). sweep: friendly
-- fire was just switched off and this burn started while it was on; ago: s
-- since that fire set it burning (v is its SetBurning record), nil: v is
-- where it stands now.
local function judge_burn(pawn, v, sweep, ago)
    local host = S.role == "host"
    local own, other, by, untracked = v.own, v.other, v.by, v.untracked
    if not other then return false end
    if own then
        M.stats.burns_kept = M.stats.burns_kept + 1
        return false   -- it stands in its own fire too
    end
    local ok, err = pcall(function() pawn:StopBurning() end)
    if not ok then
        M.stats.stop_failed = M.stats.stop_failed + 1
        log.err_throttled("ffire.stop", "ffire: StopBurning on %s failed: %s", ue.short(pawn), tostring(err))
        return false
    end
    local n
    if host then
        M.stats.burns_out = M.stats.burns_out + 1
        if untracked then M.stats.untracked = M.stats.untracked + 1 end
        n = M.stats.burns_out
    else
        M.stats.copies_out = M.stats.copies_out + 1
        n = M.stats.copies_out
    end
    if sweep then
        M.stats.swept = M.stats.swept + 1
        if ago then M.stats.swept_lit = M.stats.swept_lit + 1 end
        log.info("ffire: %s was burning from %s when friendly fire was switched off: put out%s", host and label(pawn) or ue.short(pawn),
            host and (tostring(by or "?") .. "'s Molotov") or "a teammate's Molotov (a copy here)",
            ago and string.format(" (it caught fire there %.1f s ago)", ago) or "")
        return true
    end
    local a = addr(pawn) or 0
    local now = os.clock()
    if burn_logged[a] and now - burn_logged[a] < BURN_LOG_S then return true end
    burn_logged[a] = now
    local say = line(n)
    if not say then return true end
    if host then
        say("ffire: %s set on fire by %s's Molotov: put out (friendly fire off%s)", label(pawn), tostring(by or "?"),
            untracked and "; an untracked Molotov, judged by its actor" or "")
    else
        say("ffire: %s burning from a teammate's Molotov here: put out (the host's friendly fire is off; it hurts nobody on a client)",
            ue.short(pawn))
    end
    return true
end

-- BP_PlayerCharacter.SetBurning(Burning, Damage), post (burn_watch): whose
-- fire set it burning is remembered (it stands in that fire now), and with
-- friendly fire off another player's is put out.
local function on_burning(ctx_p, burning_p)
    if get(burning_p) ~= true then return end
    local pawn = get(ctx_p)
    if not is_player(pawn) then return end
    local loc = ue.location(pawn)
    if not loc then return end
    local v = judge(pawn, loc)
    local a = addr(pawn)
    if a ~= nil then
        local now = os.clock()
        for k, r in pairs(lit) do
            if now - r.t > BURN_MAX_S then lit[k] = nil end   -- burnt out (a respawn: a new character)
        end
        v.t = now
        lit[a] = v
    end
    if host_blocks() or client_blocks() then judge_burn(pawn, v, false) end
end

-- The player characters here: the host's own and the remote players'; a
-- client's: every one it has.
local function characters()
    local out, seen = {}, {}
    local function add(p)
        if not ue.valid(p) or not is_player(p) then return end
        local a = addr(p)
        if a ~= nil and not seen[a] then
            seen[a] = true
            out[#out + 1] = p
        end
    end
    add(ue.local_pawn())
    if S.role == "host" then
        for _, pc in ipairs(S.remote_pcs or {}) do add(ue.pawn_of(pc)) end
    else
        for _, p in ipairs(ue.find_all(PLAYER_CLASS)) do add(p) end
    end
    return out
end

-- Friendly fire just switched off: a burn a teammate's Molotov started while
-- it was on keeps hurting by itself (Event_Fire: ApplyDamage(self, d, None)
-- every 0.8 s for 10-12 s; the Molotov's Fire_Damage skips a burning player,
-- so SetBurning does not run again). A burning character is judged by its
-- SetBurning record (where it caught fire: it has usually run out of that
-- fire since), else where it stands, as a new burn would be.
local function sweep_burns(why)
    local burning, out = 0, 0
    local now = os.clock()
    for _, pawn in ipairs(characters()) do
        if ue.prop(pawn, "Burning?") == true then
            burning = burning + 1
            local rec = lit[addr(pawn) or 0]
            local v, ago = nil, nil
            if rec and now - rec.t <= BURN_MAX_S then
                v, ago = rec, now - rec.t
            else
                local loc = ue.location(pawn)
                v = loc and judge(pawn, loc) or nil
            end
            if v and judge_burn(pawn, v, true, ago) then out = out + 1 end
        end
    end
    if burning > 0 then
        log.info("ffire: friendly fire switched off (%s): %d player(s) burning, %d put out (another player's fire)",
            tostring(why), burning, out)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Client: the host's rule and the notices
-- ---------------------------------------------------------------------------

-- sdc_admin's RULES|ff|<0/1> (client).
function M.on_rule(on)
    if not S or S.role ~= "client" then return end
    on = on == true
    if client.ff ~= on then
        log.info("ffire: the host's rule: friendly fire %s%s", on and "ON (players can hurt each other)" or "off",
            client.ff == nil and "" or " (changed)")
    end
    -- turned off: the copies' burns that started while on, from the tick
    if client.ff == true and not on then client.sweep = true end
    client.ff = on
end

-- A notice now: this player has its character, the host let it in, the
-- join cover is gone.
local function ready()
    local pawn = ue.local_pawn()
    if not pawn or not is_player(pawn) then return false end
    local cs = S.client
    if type(cs) == "table" and cs.access == "wait" then return false end
    local ui = package.loaded["sdc_ui"]
    if type(ui) == "table" and type(ui.join_cover_model) == "function" then
        local ok, m = pcall(ui.join_cover_model)
        if ok and type(m) == "table" and m.visible then return false end
    end
    return true
end

-- On joining: only when friendly fire is on; later: every switch.
local function notice_tick()
    if client.ff == nil or client.ff == client.told or not ready() then return end
    local key
    if client.told == nil then
        key = client.ff and "ff_join_on" or nil
    else
        key = client.ff and "ff_turned_on" or "ff_turned_off"
    end
    client.told = client.ff
    if key then
        M.stats.notices = M.stats.notices + 1
        log.say(key, "info", 8)
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- 1 s (main.lua): hooks wanted now, the host's setting, the client's notices.
function M.tick()
    if not S then return end
    if S.role ~= last_role then
        if last_role ~= nil then M.reset("role " .. tostring(S.role)) end
        last_role = S.role
    end
    if S.role == "host" then
        local on = ff_on()
        if on ~= host_ff then
            log.info("ffire: friendly fire %s (host setting friendly_fire)",
                on and "ON: players can hurt each other" or "off: damage between players is dropped")
            local was = host_ff
            host_ff = on
            if was == true and host_blocks() then sweep_burns("host setting") end
        end
        if (host_blocks() and hooks.damage and not hooks.damage.installed)
            or (burn_watch() and hooks.burn and not hooks.burn.installed) then
            ai.install_now()
        end
    elseif S.role == "client" then
        if burn_watch() and hooks.burn and not hooks.burn.installed then ai.install_now() end
        if client.sweep then
            client.sweep = nil
            if client_blocks() then sweep_burns("the host's rule") end
        end
        notice_tick()
    end
end

-- World or role change: the client's rule is the next host's (it sends it
-- after the hello). Hooks stay registered (gated).
function M.reset(why)
    client.ff, client.told, client.sweep = nil, nil, nil
    burn_logged, lit = {}, {}
    log.debug("ffire: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    hooks.damage = ai.hook_external({ path = APPLY_DAMAGE, kind = "pre", name = "ffire.damage", fn = on_damage,
                                      gate = host_blocks })
    -- never runs: keeps sdc_ai's ApplyDamage hook pre + post. Installed with
    -- pre entries only, it would be a pre-only engine hook, and kill
    -- credit's post entries (ai_kill_credit turned on later) would never run.
    ai.hook_external({ path = APPLY_DAMAGE, kind = "post", name = "ffire.keep-post", fn = function() end,
                       gate = function() return false end })
    -- on or off while players are here: who set whom burning (switching off)
    hooks.burn = ai.hook_external({ path = SET_BURNING, kind = "bp", name = "ffire.burn", fn = on_burning,
                                    gate = burn_watch })
    log.info("ffire: installed (friendly_fire=%s: %s)", tostring(ff_on()),
        ff_on() and "players can hurt each other" or "the host drops damage between players")
end

function M.status_line()
    local s = M.stats
    return string.format("ffire: friendly_fire=%s | host: blocked=%d (client blasts=%d) own=%d burns put out=%d (untracked=%d) kept=%d | client: rule=%s told=%s copies put out=%d notices=%d | on switching off put out=%d (ran out of the fire=%d) | stop failed=%d | hooks damage=%s burn=%s",
        tostring(ff_on()), s.blocked, s.blast_fix, s.own, s.burns_out, s.untracked, s.burns_kept, tostring(client.ff),
        tostring(client.told), s.copies_out, s.notices, s.swept, s.swept_lit, s.stop_failed,
        tostring(hooks.damage and hooks.damage.installed), tostring(hooks.burn and hooks.burn.installed))
end

-- tests
M._on_damage = on_damage
M._on_burning = on_burning
M._client = function() return client end

return M
