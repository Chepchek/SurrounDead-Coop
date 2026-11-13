-- SDCoop: other players' events as the game's own notifications:
-- "<name> died" and "<name> respawned", on every screen but that player's
-- own. No cause of death: the hook it needed (BP_PlayerCharacter.
-- ReceiveAnyDamage) was registered during both 0.7.1 host crashes of
-- 2026-11-11 and has been removed.
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
-- Joined / left / connection lost: sdc_session already says so (log.say
--   player_joined / player_left on the host and MSG to the other clients,
--   connection_lost on the client that lost the host): not repeated here.
-- Rate: one "died" per player per GAP_S and BURST in total (refilled one per
--   REFILL_S); "respawned" only to the screens told about that death.
-- Config player_event_notes: off on the host = nothing sent or shown there;
--   off on a client = not shown on that client.
--
-- Message (host -> client): PEV|died|name   PEV|back|name
--   (fields after the name, sent by older builds, are ignored)
-- No hooks; no engine object is kept between calls (names and strings only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
-- optional (pure modules; a failure leaves the mod's toast and English text)
local function opt(name)
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then return m end
    return nil
end
local notes = opt("sdc_notes")
local i18n = opt("sdc_i18n")

local M = { stats = { died = 0, back = 0, sent = 0, shown = 0, got = 0, limited = 0 } }

local S = nil   -- sdc_session.state

-- the game's notices of the same kind: the human skull of the kill popups
-- (BP_Human Death), the sleeping bag of the beds; the game's red for bad news
M.LOOK = {
    died = { icon = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/Hunting_For_Food/T_HumanSkull_256x256.T_HumanSkull_256x256",
             col = { R = 1, G = 0, B = 0, A = 1 }, delay = 5 },
    back = { icon = "/Game/UI/Textures/over_250_survival_flat_icons/sleeping_bag.sleeping_bag",
             col = { R = 1, G = 1, B = 1, A = 1 }, delay = 4 },
}
-- English without sdc_i18n (tests, a broken catalog)
local FALLBACK = { pe_died = "%s died.", pe_back = "%s respawned." }

local GAP_S = 30            -- one "died" per player this often
local BURST, REFILL_S = 4, 15
local SHOW_DELAY_MS = 150   -- out of the net hook before building a widget
local NAME_MAX = 40
local HOST = "host"         -- subject key of the host's own player (record keys are full names)

local st = {
    seen = {},      -- host: [subject key] = { dead, announced, died_at, told = { [receiver key] = true } }
    bucket = { n = BURST, t = nil },
    role = nil,
}
M._st = st

local clock = os.clock
local function enabled() return cfg.get("player_event_notes") ~= false end
local function role() return S and S.role or nil end

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

-- kind "died" | "back".
function M.text(kind, name)
    if kind == "back" then return T("pe_back", name) end
    return T("pe_died", name)
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

local function on_died(key, name)
    local now = clock()
    local s = subject(key)
    s.dead, s.announced, s.told = true, false, {}
    M.stats.died = M.stats.died + 1
    if not enabled() then
        log.debug("playernotes: %s died; not announced (player_event_notes off)", log.ascii(name))
        return
    end
    local list = receivers(key)
    local host_screen = key ~= HOST
    if #list == 0 and not host_screen then return end
    if (s.died_at and now - s.died_at < GAP_S) or not take_token(now) then
        M.stats.limited = M.stats.limited + 1
        log.info("playernotes: %s died again; not announced: rate limit", log.ascii(name))
        return
    end
    s.died_at, s.announced = now, true
    for _, rcv in ipairs(list) do
        if net.send_to(rcv.pc, "PEV", "died", name) then
            s.told[rcv.key] = true
            M.stats.sent = M.stats.sent + 1
        end
    end
    if host_screen then
        s.told[HOST] = true
        show("died", M.text("died", name), "a player died")
    end
    log.info("playernotes: %s died: told %s%d client(s)", log.ascii(name), host_screen and "the host's screen + " or "", #list)
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
-- died ("died") / lives again after that ("back"). The second argument
-- (the body's address, from sdc_respawn) is not needed any more.
function M.own_event(kind)
    if role() ~= "host" then return end
    if kind == "died" then
        on_died(HOST, clean_name(cfg.player_name()))
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
    st.seen = {}
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
    local remote = S.remote or {}
    for key, r in pairs(remote) do
        local s = st.seen[key]
        local dead = r.dead == true
        if not s then
            s = subject(key)
            s.dead = dead             -- first sight: no event
        elseif dead and not s.dead then
            on_died(key, clean_name(r.name))
        elseif not dead and s.dead then
            if living_pawn(r.pc) then on_back(key, clean_name(r.name)) end
        end
    end
    for key in pairs(st.seen) do
        if key ~= HOST and not remote[key] then st.seen[key] = nil end
    end
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
    local text = M.text(kind, clean_name(name))
    ue.delay("playernotes", SHOW_DELAY_MS, function()
        if role() ~= "client" then return end
        -- (sdc_notes logs the shown text itself)
        if show(kind, text, "the host's player event") then
            log.debug("playernotes: the host's '%s %s' shown here", log.ascii(name), kind)
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
    return string.format("playernotes: died=%d back=%d sent=%d shown=%d got=%d limited=%d",
        s.died, s.back, s.sent, s.shown, s.got, s.limited)
end

-- tests
M._t = { on_pev = on_pev, set_state = function(s) S = s end, GAP_S = GAP_S, BURST = BURST, REFILL_S = REFILL_S }

return M
