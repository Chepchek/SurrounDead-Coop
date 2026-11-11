-- SDCoop: other players' events as the game's own notifications:
-- "<name> died" (with its cause when the mod knows it for certain) and
-- "<name> respawned", on every screen but that player's own.
--
-- The host decides and sends; every screen shows the text in its OWN
-- language (sdc_i18n STR pe_*), through the game's notification widget
-- (sdc_notes.show_here -> GameFunctionLibrary_C.CreateNotificationUI, icon
-- if it is in memory; the mod's toast path when that fails).
--
-- Detection (nothing new polls for deaths):
--   * a client's death / respawn: sdc_players.host_player_tick keeps r.dead
--     of each session record (the character's replicated PlayerDead?); M.tick
--     (1 s, from sdc_respawn's tick) compares it with what it saw last. The
--     respawn counts once that player has a living character again.
--   * the host's own death / respawn: sdc_respawn's own_watch (the host's own
--     character, every second) calls M.own_event.
-- Cause of death (host, only what is certain; else no cause in the text):
--   BP_PlayerCharacter.ReceiveAnyDamage (post, host; hooked while a client is
--   connected and the setting is on). The game ignores damage to a dead
--   character (@137859) and sets PlayerDead? inside the killing call (@137645
--   -> @13645), so the hit whose post sees the character dead while the
--   previous hit / the last tick saw it alive is the killing blow. Its causer:
--     zombie or zombie boss (IsA BP_MasterZombie / BP_ZombieBoss), wolf, bear,
--     another animal (BP_Animal), humans (SmartAI BP_MasterAICharacter: bandits,
--     soldiers, scavengers, traders), another player (the causer's / the
--     instigator's player controller: their gun, knife, grenade), a fall
--     (no causer, no instigator, and exactly one of OnLanded's damages 15 /
--     30 / 60 / 80 / 999, BP_PlayerCharacter @123740-124357; bleeding's
--     no-causer damage is a random 2-6, burning has a causer). Hunger,
--     thirst, radiation and drowning name the victim itself as causer: no
--     cause.
-- Joined / left / connection lost: sdc_session already says so (log.say
--   player_joined / player_left on the host and MSG to the other clients,
--   connection_lost on the client that lost the host): not repeated here.
-- Rate: one "died" per player per GAP_S and BURST in total (refilled one per
--   REFILL_S); "respawned" only to the screens told about that death.
-- Config player_event_notes: off on the host = nothing sent or shown there;
--   off on a client = not shown on that client.
--
-- Message (host -> client): PEV|died|name|cause|killer|you   PEV|back|name
--   cause: "" (unknown) | zombie | wolf | bear | animal | human | fall | player;
--   you = 1 on the killer's own screen.
-- Hooks: post only, in pcall, return nothing; no engine object is kept
-- between calls (addresses, names and strings only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
-- optional (pure modules; a failure leaves the mod's toast and English text)
local function opt(name)
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then return m end
    return nil
end
local notes = opt("sdc_notes")
local i18n = opt("sdc_i18n")

local M = { stats = { died = 0, back = 0, sent = 0, shown = 0, got = 0, limited = 0, causes = 0 } }

local S = nil   -- sdc_session.state

local DMG_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:ReceiveAnyDamage"
local CLS = {
    zombie = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C",
    boss = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C",
    wolf = "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
    bear = "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
    animal = "/Game/AI/Animals/BP_Animal.BP_Animal_C",
    human = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C",
}
-- BP_PlayerCharacter OnLanded: ApplyDamage(self, N, None, None, DamageType)
local FALL_DAMAGE = { [15] = true, [30] = true, [60] = true, [80] = true, [999] = true }

-- the game's notices of the same kind: the human skull of the kill popups
-- (BP_Human Death), the sleeping bag of the beds; the game's red for bad news
M.LOOK = {
    died = { icon = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/Hunting_For_Food/T_HumanSkull_256x256.T_HumanSkull_256x256",
             col = { R = 1, G = 0, B = 0, A = 1 }, delay = 5 },
    back = { icon = "/Game/UI/Textures/over_250_survival_flat_icons/sleeping_bag.sleeping_bag",
             col = { R = 1, G = 1, B = 1, A = 1 }, delay = 4 },
}
M.CAUSE_KEY = {
    zombie = "pe_died_zombie", wolf = "pe_died_wolf", bear = "pe_died_bear", animal = "pe_died_animal",
    human = "pe_died_human", fall = "pe_died_fall",
}
-- English without sdc_i18n (tests, a broken catalog)
local FALLBACK = {
    pe_died = "%s died.", pe_died_zombie = "%s was killed by a zombie.", pe_died_wolf = "%s was killed by a wolf.",
    pe_died_bear = "%s was killed by a bear.", pe_died_animal = "%s was killed by an animal.",
    pe_died_human = "%s was killed by humans.", pe_died_fall = "%s died from a fall.",
    pe_died_player = "%s was killed by %s.", pe_died_you = "You killed %s.", pe_back = "%s respawned.",
}

local GAP_S = 30            -- one "died" per player this often
local BURST, REFILL_S = 4, 15
local KILL_WINDOW_S = 5     -- the killing blow is at most this old when the death is seen
local ALIVE_FRESH_S = 2.5   -- a character seen alive this recently by the tick
local HIT_TTL_S = 30
local HOOK_RETRY_S = 2
local SHOW_DELAY_MS = 150   -- out of the net hook before building a widget
local NAME_MAX = 40
local HOST = "host"         -- subject key of the host's own player (record keys are full names)

local st = {
    seen = {},      -- host: [subject key] = { dead, announced, died_at, told = { [receiver key] = true } }
    hits = {},      -- host: [character address] = { t, dead, cause, killer, kkey, cls, subj }
    alive_at = {},  -- host: [character address] = clock when the tick last saw it alive
    host_addr = nil,
    bucket = { n = BURST, t = nil },
    hook = { ok = false, at = -100, warned = false },
    role = nil,
}
M._st = st

local clock = os.clock
local function enabled() return cfg.get("player_event_notes") ~= false end
local function role() return S and S.role or nil end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function addr_of(o)
    if not ue.valid(o) then return nil end
    return ctx.addr(o)
end

local function clean_name(n)
    n = tostring(n or ""):gsub("[|%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- at most NAME_MAX characters, cut on a UTF-8 character boundary
    local okl, len = pcall(utf8.len, n)
    if okl and len and len > NAME_MAX then
        local cut = utf8.offset(n, NAME_MAX + 1)
        if cut then n = n:sub(1, cut - 1) end
    elseif #n > NAME_MAX * 4 then
        n = n:sub(1, NAME_MAX)
    end
    if n == "" then n = "?" end
    return n
end

-- ---------------------------------------------------------------------------
-- Text (the receiving screen's language)
-- ---------------------------------------------------------------------------

local function T(key, ...)
    if i18n and type(i18n.T) == "function" then
        local ok, s = pcall(i18n.T, key, ...)
        if ok and type(s) == "string" and s ~= key then return s end
    end
    local ok, s = pcall(string.format, FALLBACK[key] or "%s", ...)
    return ok and s or tostring(key)
end

-- kind "died" | "back"; cause as in PEV; you = this screen's player killed them.
function M.text(kind, name, cause, killer, you)
    if kind == "back" then return T("pe_back", name) end
    if cause == "player" then
        if you then return T("pe_died_you", name) end
        if killer and killer ~= "" then return T("pe_died_player", name, killer) end
        return T("pe_died", name)
    end
    return T(M.CAUSE_KEY[cause or ""] or "pe_died", name)
end

-- This screen: the game's notification (sdc_notes), else the mod's toast.
local function show(kind, text, why)
    local look = M.LOOK[kind] or M.LOOK.died
    if type(notes) == "table" and type(notes.covered) == "function" and notes.covered(text, 3) then
        log.debug("playernotes: '%s' is on this screen already", text)
        return false
    end
    local ok = false
    if type(notes) == "table" and type(notes.show_here) == "function" then
        local okc, r = pcall(notes.show_here, text, look.icon, look.col, look.delay, why)
        ok = okc and r == true
    end
    if not ok then log.toast(text, "info", look.delay + 2, "player event: " .. tostring(kind)) end
    M.stats.shown = M.stats.shown + 1
    return true
end

-- ---------------------------------------------------------------------------
-- Host: cause of death
-- ---------------------------------------------------------------------------

local isa_cache = {}   -- [class name .. "|" .. path] = bool (strings only)
local function isa(o, path)
    local cn = ue.class_name(o)
    if cn == "" then return false end
    local key = cn .. "|" .. path
    local c = isa_cache[key]
    if c ~= nil then return c end
    local cls = ue.find_object(path)
    if not cls then return false end   -- not loaded: no instance can exist; not cached
    local ok, r = pcall(function() return o:IsA(cls) end)
    if not ok then return false end
    isa_cache[key] = r == true
    return r == true
end

local function is_remote_pc(pc)
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

local function same(a, b)
    local x, y = addr_of(a), addr_of(b)
    return x ~= nil and x == y
end

-- A player controller's subject key and name: "host" / a record key.
local function pc_subject(pc)
    if not ue.valid(pc) then return nil end
    if is_remote_pc(pc) then
        local key = ue.name(pc)
        local r = S and S.remote and S.remote[key]
        return key, r and r.name or nil
    end
    if same(pc, ue.local_pc()) then return HOST, cfg.player_name() end
    return nil
end

-- The player behind a hit (the instigator, or the causer: a character, its
-- weapon, projectile, grenade - owner / instigator chain), or nil.
local function player_behind(inst, causer)
    local k, n = pc_subject(inst)
    if k then return k, n end
    local o = causer
    for _ = 1, 4 do
        if not ue.valid(o) then break end
        k, n = pc_subject(o)
        if k then return k, n end
        local cn = ue.class_name(o)
        if cn:find("PlayerCharacter", 1, true) then
            k, n = pc_subject(ue.prop(o, "Controller"))
            if k then return k, n end
            local e = ctx.player_for(o)
            if e then
                k, n = pc_subject(e.pc)
                if k then return k, n end
            end
            if st.host_addr and addr_of(o) == st.host_addr then return HOST, cfg.player_name() end
        end
        k, n = pc_subject(ue.try(function() return o:GetInstigatorController() end))
        if k then return k, n end
        o = ue.try(function() return o:GetOwner() end)
    end
    return nil
end

-- Whose character `ch` (address a) is: "host" / a record key / nil.
local function subject_of(ch, a)
    if a and a == st.host_addr then return HOST end
    local e = ctx.player_for(ch)
    if e and is_remote_pc(e.pc) then return ue.name(e.pc) end
    local k = pc_subject(ue.prop(ch, "Controller"))
    return k
end

-- { kind = cause or nil, killer, kkey, cls } of the hit that killed `ch`.
local function classify(ch, a, subj, dmg, inst, causer)
    local cn = ue.valid(causer) and ue.class_name(causer) or "none"
    if ue.valid(causer) then
        if same(causer, ch) then return { cls = "the victim itself (" .. cn .. ")" } end
        if isa(causer, CLS.zombie) or isa(causer, CLS.boss) then return { kind = "zombie", cls = cn } end
        if isa(causer, CLS.wolf) then return { kind = "wolf", cls = cn } end
        if isa(causer, CLS.bear) then return { kind = "bear", cls = cn } end
        if isa(causer, CLS.animal) then return { kind = "animal", cls = cn } end
        if isa(causer, CLS.human) then return { kind = "human", cls = cn } end
    end
    local pk, pname = player_behind(inst, causer)
    if pk then
        if pk == subj then return { cls = "own (" .. cn .. ")" } end
        return { kind = "player", killer = clean_name(pname), kkey = pk, cls = cn }
    end
    if not ue.valid(causer) and not ue.valid(inst) and dmg and FALL_DAMAGE[math.floor(dmg + 0.5)]
        and math.abs(dmg - math.floor(dmg + 0.5)) < 0.001 then
        return { kind = "fall", cls = string.format("no causer, damage %g (a landing)", dmg) }
    end
    return { cls = cn }
end

-- BP_PlayerCharacter.ReceiveAnyDamage(Damage, DamageType, InstigatedBy,
-- DamageCauser), post, host.
local function on_damage(c, dmg_p, _, inst_p, causer_p)
    if role() ~= "host" then return end
    local ch = pget(c)
    if not ue.valid(ch) then return end
    local a = addr_of(ch)
    if not a then return end
    local now = clock()
    local dead = ue.prop(ch, "PlayerDead?") == true
    local prev = st.hits[a]
    if not dead then
        st.hits[a] = { t = now, dead = false }
        return
    end
    if prev and prev.dead then return end   -- a hit on the body: the game ignores it
    -- the killing blow only if this character was alive just before it
    local alive_t = (prev and now - prev.t <= ALIVE_FRESH_S and prev.t) or st.alive_at[a]
    if not alive_t or now - alive_t > ALIVE_FRESH_S then
        st.hits[a] = { t = now, dead = true }
        return
    end
    local subj = subject_of(ch, a)
    local r = classify(ch, a, subj, tonumber(pget(dmg_p)), pget(inst_p), pget(causer_p))
    r.t, r.dead, r.subj = now, true, subj
    st.hits[a] = r
    log.debug("playernotes: killing blow on %s: %s (%s)", ue.short(ch), tostring(r.kind or "no cause"), r.cls or "?")
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("playernotes." .. name, "playernotes: %s hook: %s", name, tostring(err)) end
    end
end

local function try_hook()
    if st.hook.ok then return end
    local now = clock()
    if now - st.hook.at < HOOK_RETRY_S then return end
    st.hook.at = now
    if not ue.find_object(DMG_FN) then return end
    local ok, err = pcall(RegisterHook, DMG_FN, safe("damage", on_damage))
    st.hook.ok = ok
    if ok then
        log.info("playernotes: hook BP_PlayerCharacter_C:ReceiveAnyDamage ok (cause of death)")
    elseif not st.hook.warned then
        st.hook.warned = true
        log.warn("playernotes: cannot hook %s: %s (deaths are announced without a cause)", DMG_FN, tostring(err))
    end
end

-- The cause of `subj`'s death (character address a), used once.
local function take_cause(subj, a, now)
    local r = a and st.hits[a]
    if not (r and r.dead and r.cls) then
        r = nil
        for ha, h in pairs(st.hits) do
            if h.dead and h.cls and h.subj == subj and (not r or h.t > r.t) then r, a = h, ha end
        end
    end
    if not r or now - r.t > KILL_WINDOW_S then return nil end
    st.hits[a] = { t = r.t, dead = true }   -- used: the body's later hits stay ignored
    return r
end

-- ---------------------------------------------------------------------------
-- Host: deciding and sending
-- ---------------------------------------------------------------------------

local function subject(key)
    local s = st.seen[key]
    if not s then
        s = { dead = false, announced = false, told = {} }
        st.seen[key] = s
    end
    return s
end

local function take_token(now)
    local b = st.bucket
    if not b.t then b.t = now end
    b.n = math.min(BURST, b.n + (now - b.t) / REFILL_S)
    b.t = now
    if b.n < 1 then return false end
    b.n = b.n - 1
    return true
end

-- Connected players who said hello, except `skip`: { { pc, key } }.
local function receivers(skip)
    local out = {}
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        if ue.valid(pc) then
            local key = ue.name(pc)
            local r = S.remote and S.remote[key]
            if key ~= skip and r and r.hello then out[#out + 1] = { pc = pc, key = key } end
        end
    end
    return out
end

local function cause_log(c)
    if not c then return "cause unknown" end
    if not c.kind then return "cause not certain: " .. tostring(c.cls) end
    if c.kind == "player" then return "killed by player " .. log.ascii(c.killer or "?") end
    return "cause " .. c.kind .. " (" .. tostring(c.cls) .. ")"
end

local function on_died(key, name, a)
    local now = clock()
    local s = subject(key)
    s.dead, s.announced, s.told = true, false, {}
    M.stats.died = M.stats.died + 1
    local c = take_cause(key, a, now)
    if c and c.kind then M.stats.causes = M.stats.causes + 1 end
    if not enabled() then
        log.debug("playernotes: %s died; not announced (player_event_notes off)", log.ascii(name))
        return
    end
    local list = receivers(key)
    local host_screen = key ~= HOST
    if #list == 0 and not host_screen then return end
    if (s.died_at and now - s.died_at < GAP_S) or not take_token(now) then
        M.stats.limited = M.stats.limited + 1
        log.info("playernotes: %s died again (%s); not announced: rate limit", log.ascii(name), cause_log(c))
        return
    end
    s.died_at, s.announced = now, true
    local cause = c and c.kind or ""
    local killer = c and c.killer or ""
    for _, rcv in ipairs(list) do
        local you = (c and c.kkey == rcv.key) and "1" or "0"
        if net.send_to(rcv.pc, "PEV", "died", name, cause, killer, you) then
            s.told[rcv.key] = true
            M.stats.sent = M.stats.sent + 1
        end
    end
    if host_screen then
        s.told[HOST] = true
        show("died", M.text("died", name, cause, killer, c ~= nil and c.kkey == HOST), "a player died")
    end
    log.info("playernotes: %s died (%s): told %s%d client(s)", log.ascii(name), cause_log(c),
        host_screen and "the host's screen + " or "", #list)
end

local function on_back(key, name)
    local s = subject(key)
    s.dead = false
    if not s.announced then return end
    -- (bounded by the announced deaths: one per GAP_S per player)
    s.announced = false
    M.stats.back = M.stats.back + 1
    if not enabled() then s.told = {} return end
    local n = 0
    for _, rcv in ipairs(receivers(key)) do
        if s.told[rcv.key] and net.send_to(rcv.pc, "PEV", "back", name) then
            n = n + 1
            M.stats.sent = M.stats.sent + 1
        end
    end
    local here = key ~= HOST and s.told[HOST] == true
    if here then show("back", M.text("back", name), "a player respawned") end
    s.told = {}
    log.info("playernotes: %s respawned: told %s%d client(s)", log.ascii(name), here and "the host's screen + " or "", n)
end

-- sdc_respawn's own_watch (every machine): this machine's own character
-- died ("died", its address) / lives again after that ("back").
function M.own_event(kind, a)
    if role() ~= "host" then return end
    if kind == "died" then
        on_died(HOST, clean_name(cfg.player_name()), a)
    elseif kind == "back" then
        on_back(HOST, clean_name(cfg.player_name()))
    end
end

local function living_pawn(pc)
    local p = ue.pawn_of(pc)
    if p and ue.prop(p, "PlayerDead?") ~= true then return p end
    return nil
end

local function reset(why)
    st.seen, st.hits, st.alive_at = {}, {}, {}
    st.host_addr = nil
    log.debug("playernotes: state dropped (%s)", tostring(why or "?"))
end
M.reset = reset

-- 1 s (sdc_respawn's tick), every machine.
function M.tick()
    local r0 = role()
    if r0 ~= st.role then
        if st.role ~= nil then reset("role " .. tostring(st.role) .. " -> " .. tostring(r0)) end
        st.role = r0
    end
    if r0 ~= "host" or not S then return end
    local now = clock()
    local remote = S.remote or {}
    local any = next(remote) ~= nil
    -- The cause-of-death hook (BP_PlayerCharacter.ReceiveAnyDamage) is OFF:
    -- both 0.7.1 crashes of 2026-11-11 (19:12, 19:58: UE4SS AV in
    -- AActor/UClass::construct -> lua_rawgeti, a corrupt Lua stack while
    -- wrapping an object) came while it was registered - 19:58 two seconds
    -- after it was - and 19:12's stack matches its first line (c:get() of
    -- the character). Deaths are still announced, without a cause.
    -- M.CAUSE_HOOK = true turns it back on (tests; a debugging session).
    local causes = any and enabled() and M.CAUSE_HOOK == true
    if causes then try_hook() end
    if causes and st.hook.ok then
        -- who is alive now (the killing-blow check of on_damage)
        local hp = living_pawn(ue.local_pc())
        st.host_addr = hp and addr_of(hp) or st.host_addr
        if hp then st.alive_at[st.host_addr] = now end
    end
    for key, r in pairs(remote) do
        local s = st.seen[key]
        local dead = r.dead == true
        if not s then
            s = subject(key)
            s.dead = dead             -- first sight: no event
        elseif dead and not s.dead then
            local body = ue.valid(r.pawn) and r.pawn or ue.pawn_of(r.pc)
            on_died(key, clean_name(r.name), addr_of(body))
        elseif not dead and s.dead then
            if living_pawn(r.pc) then on_back(key, clean_name(r.name)) end
        end
        if causes and st.hook.ok and not dead then
            local p = living_pawn(r.pc)
            local a = p and addr_of(p)
            if a then st.alive_at[a] = now end
        end
    end
    for key in pairs(st.seen) do
        if key ~= HOST and not remote[key] then st.seen[key] = nil end
    end
    for a, h in pairs(st.hits) do if now - h.t > HIT_TTL_S then st.hits[a] = nil end end
    for a, t in pairs(st.alive_at) do if now - t > HIT_TTL_S then st.alive_at[a] = nil end end
end

-- ---------------------------------------------------------------------------
-- Client: PEV from the host
-- ---------------------------------------------------------------------------

local function on_pev(f)
    if role() ~= "client" then return end
    local kind, name = f[1], f[2]
    if (kind ~= "died" and kind ~= "back") or not name or name == "" then return end
    M.stats.got = M.stats.got + 1
    if not enabled() then
        log.debug("playernotes: the host's %s notice for %s not shown (player_event_notes off here)", kind,
            log.ascii(name))
        return
    end
    local text = M.text(kind, clean_name(name), f[3], f[4], f[5] == "1")
    ue.delay("playernotes", SHOW_DELAY_MS, function()
        if role() ~= "client" then return end
        -- (sdc_notes logs the shown text itself)
        if show(kind, text, "the host's player event") then
            log.debug("playernotes: the host's '%s %s' (%s) shown here", log.ascii(name), kind,
                (f[3] ~= nil and f[3] ~= "") and f[3] or "no cause")
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Install / status
-- ---------------------------------------------------------------------------

local installed = false
function M.install(state)
    S = state or S
    if installed then return end
    installed = true
    net.on("PEV", on_pev)
    local session = package.loaded["sdc_session"]
    if type(session) == "table" and type(session.world_reset_hooks) == "table" then
        session.world_reset_hooks.playernotes = function(why) reset("world:" .. tostring(why)) end
    end
    log.info("playernotes: installed (player_event_notes %s)", enabled() and "on" or "off")
end

function M.status_line()
    local s = M.stats
    return string.format("playernotes: died=%d back=%d causes=%d sent=%d shown=%d got=%d limited=%d hook=%s",
        s.died, s.back, s.causes, s.sent, s.shown, s.got, s.limited, tostring(st.hook.ok))
end

-- tests
M._t = { on_damage = on_damage, on_pev = on_pev, classify = classify, set_state = function(s) S = s end,
         GAP_S = GAP_S, BURST = BURST, REFILL_S = REFILL_S, DMG_FN = DMG_FN, CLS = CLS }

return M
