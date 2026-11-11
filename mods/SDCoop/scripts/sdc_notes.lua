-- SDCoop: every game notification on the screen of the player it is for.
--
-- How the game shows one (decompiled, work\re\pseudo):
--   * GameFunctionLibrary_C.CreateNotificationUI(Message, Icon, Icon Colour,
--     Delay, Force Notification?, __WorldContext) [static] @0-319:
--     GetPlayerController(__WorldContext, 0) -> GetHUD -> Cast<HUD_Game_C> ->
--     HUD_Game.Notification -> NotificationParentWidget.Notification: unless
--     forced, a message already on screen is not added again (@5-568), else a
--     NotficationUI_C is appended to VerticalBox_31 (@573-791). 173 call
--     sites in 66 Blueprints, each passing its own `self` as the context.
--   * BP_PlayerCharacter.CreateNotificationUI (BPI_Player) @141107: only if
--     IsLocallyControlled, GetGameHUD(self).Notification(...). The keycard
--     checks of BP_HangarDoor @3409 / BP_KeycardDoor @3077 call it on the
--     interacting character (server path).
--   * Direct HUD.Notification through GetHUD(self): crowbar (BP_LockedDoor
--     FindCrowbar), tool containers, radiation zones (a player-0 overlap
--     check first): all on the interacting machine - nothing to do here.
-- Co-op, host: sdc_ctx turns GetPlayerController(context, 0) for a client's
-- object (its character, components, controller, owned actors, world
-- objects a scope resolver names, an AI it is killing) into that client's
-- controller. A remote controller has no HUD on the server (ClientSetHUD
-- runs on the owning client): the cast fails and NOBODY sees the notice.
-- Right for what the client's own machine raises too (input, multicasts,
-- OnReps, client RPCs, its own timers); wrong for what runs only on the
-- server for that client: the radiation filter (RadiationComponent.
-- RadiationTimer, a server timer: "No Filter", "Filter No Longer Working",
-- "Unusable Filter"), the trader's money ("Handle Comp to Comp Move" ->
-- CheckVendorAmountOfMoney @1059 "Trader does not have enough money"), beds
-- (sdc_respawn's scope: "It's too early to sleep yet...", "Spawn Point
-- Set"), buildables used through OnServerExecuteInteract (generator "Gas
-- full" / "No gas can" / "Removing will ...", the battery charger), the
-- hangar door's keycard (BPI_Player path) and any other server-side path.
-- A world object nothing resolves asks for the HOST instead: a client's use
-- of a water well (BP_WaterWell.OnServerExecuteInteract @5016 -> "'Water
-- Bottle' filled", "Not enough water in well", "No water to drink from") or
-- its melee on a locked primary nest (BP_Infestation.Damage_Object @7946
-- "Secondary Infestations Not Destroyed In Surrounding Area.") showed on the
-- host's screen, not the client's.
--
-- Here (config notes_relay, notes_owner_only):
--   host   CreateNotificationUI (post): the same question sdc_ctx's pre-hook
--          asked (scope resolvers, the remote player's own objects, the dying
--          AI's killer; a remote player's weapon = nobody). A remote player's
--          notice goes to that client (NOTE) unless its own machine raises it
--          (its character and the components listed in OWN_CLASSES), it is
--          progression of the host's copy of its controller (level, passive
--          skills, skill tree: the client's own copy shows them when the XP
--          reaches it), or an "XP Given" note (the XP reaches the client
--          through the module that relays it: kills, doors, nests, cooking).
--          Throttled per player and text (the radiation timer raises "No
--          Filter" up to 25 times a second).
--          A notice the host's screen showed for a client's action is taken
--          off it and sent to that client: raised inside that client's
--          BP_JigComponent.SERVER_ForwardInteract on the object it used, inside
--          BP_Infestation.Damage_Object with that client as the causer, or
--          inside M.for_player(pc, fn) (a module running the game's function
--          for that player).
--          BP_PlayerCharacter.CreateNotificationUI (post) of a client's
--          character: sent to that client.
--   client NOTE: the game's own CreateNotificationUI on the own controller
--          (text, icon if it is in memory - never loaded -, colour, delay),
--          HOLD_S later and only if this screen did not show the same text
--          within DEDUP_S (its own copy raised it too). Inside M.quietly(fn)
--          (another player's state applied here) the notices the game raises
--          are taken off this screen. A notice the host's random-event wreck
--          raises when it reaches this client long after the event (join,
--          relevance again) is taken off too (sdc_events.stale_note).
-- Taking a notice off: the newest NotficationUI_C child of VerticalBox_31
-- with that text, only when the game really added one (forced, or not on
-- this screen within its delay; NotificationParentWidget @5-568).
--
-- Other modules: M.show_to(pc, ...) (host: that player's screen), M.show_here
-- (this screen, any role), M.for_player / M.quietly (scopes), M.covered,
-- M.shown_since (host: what this screen showed lately, by context class).
-- Message (host -> client): NOTE|text|icon path|r,g,b,a|delay   (text with
-- %25 / %7C / %0D / %0A escapes)
-- Hooks: post only, wrapped in pcall, return nothing; no engine object is
-- kept between calls (addresses and names only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = { relayed = 0, got = 0, shown = 0, deduped = 0, throttled = 0, skipped = 0, taken_off = 0,
              kept = 0, quieted = 0 },
}

local P = {
    gfl = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI",
    char = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:CreateNotificationUI",
    forward = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_ForwardInteract",
    infest = "/Game/Infestation/BP_Infestation.BP_Infestation_C:Damage_Object",
    gfl_cdo = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
}
M.PATHS = P
local MSG_FIELD = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"   -- S_NotificationDetails.Message
local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local HOLD_S = 0.35          -- client: a relayed notice waits this long for the own copy's
local DEDUP_S = 3.0          -- client: the same text shown here this recently -> not again
local PENDING_S = 0.1        -- host: a notice shown here may still be claimed this long
local GAP_MIN_S = 1.5        -- host: one relay per player and text at most this often ...
local BURST = 6              -- ... and at most this many per player ...
local REFILL = 3             -- ... refilled this many per second
local INFO_EVERY_S = 60      -- a relay / take-off is logged at info once per text and player in this time
local HOOK_RETRY_S = 2
local SCOPE_NEAR_CM = 3000   -- host: a scope-named player farther from the object: not its notice

-- Contexts whose notices the owning client's machine raises itself (input,
-- multicast, OnRep, client RPC, its own timers), or that are progression of
-- the host's copy of a client's controller (class name substrings).
local OWN_CLASSES = {
    { "PlayerCharacter", "its own machine raises it (input, multicast, timers)" },
    { "MedicalComponent", "its own machine raises it (OnRep, client RPC)" },
    { "BatteryComponent", "its own machine raises it (battery timers)" },
    { "FishingComponent", "its own machine raises it (multicast)" },
    { "BuildingComponent", "its own machine raises it (build mode)" },
    { "LevellingComponent", "progression lives on the client (its own level-up)" },
    { "PassiveSkillsComponent", "progression lives on the client (its own skill level-up)" },
    { "TechTreeComponent", "progression lives on the client (its own skill tree)" },
    { "BP_PlayerController", "saves and progression are the client's own" },
}
M.OWN_CLASSES = OWN_CLASSES
-- the infestation's lock note (BP_Infestation @7946, forced)
local NEST_NOTE = "Secondary Infestations Not Destroyed In Surrounding Area."

local S = nil
local st = {
    hooks = {}, hook_at = -100, hook_logged = {},
    recent = {},     -- [text] = { t = clock, till = clock }: shown on this screen
    pending = {},    -- host: notices shown here this instant, claimable: { text, wa, t, fresh, note }
    sent = {},       -- host: [pc address .. "|" .. text] = clock of the last relay
    tokens = {},     -- host: [pc address] = { n, t }
    info_at = {},    -- [key] = clock of the last info line
    memo = nil,      -- host: { wa, text, t, pc_addr, how } the last decision (radiation spam)
    queued = {},     -- client: [text] = clock until which a relayed one waits here
    scopes = {},     -- stack: { kind = "for" | "quiet", pc_addr, label, n }
    shown_log = {},  -- host: the last notices this screen showed: { t, cls, text, icon, col, delay }
    role = nil,
}
M._st = st

local clock = os.clock
local function on(key) return cfg.get(key) ~= false end
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

local function remote_pc(pc)
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

-- the info line once per key and INFO_EVERY_S, debug otherwise
local function say(key, fmt, ...)
    local now = clock()
    local t = st.info_at[key]
    if not t or now - t >= INFO_EVERY_S then
        st.info_at[key] = now
        log.info(fmt, ...)
    else
        log.debug(fmt, ...)
    end
end

-- ---------------------------------------------------------------------------
-- Text, icon, colour
-- ---------------------------------------------------------------------------

local function esc(s)
    return (tostring(s or ""):gsub("[%%|\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unesc(s)
    return (tostring(s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
M.esc, M.unesc = esc, unesc

-- one line for the log (the game's texts have \r\n)
local function line(text) return (tostring(text or ""):gsub("[\r\n]+", " / ")) end

local function colour_of(c)
    if c == nil then return WHITE end
    local function f(k)
        local ok, v = pcall(function() return c[k] end)
        return ok and tonumber(v) or nil
    end
    local r, g, b, a = f("R"), f("G"), f("B"), f("A")
    if not (r and g and b) then return WHITE end
    return { R = r, G = g, B = b, A = a or 1 }
end

local function colour_str(c)
    return string.format("%.3f,%.3f,%.3f,%.3f", c.R, c.G, c.B, c.A or 1)
end

local function parse_colour(s)
    local r, g, b, a = tostring(s or ""):match("^([%d%.%-]+),([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)$")
    if not r then return WHITE end
    return { R = tonumber(r) or 1, G = tonumber(g) or 1, B = tonumber(b) or 1, A = tonumber(a) or 1 }
end

local function icon_path(icon)
    if not ue.valid(icon) then return "" end
    local p = ue.path(icon)
    if p == "" or p:sub(1, 1) ~= "/" then return "" end
    return p
end

-- A notice as the hooks read it: { text, icon, col, delay, force, cls }.
local function note_of(msg_p, icon_p, col_p, delay_p, force_p)
    local text = ue.fstring(msg_p)
    if text == "" or ue.is_wrapper_text(text) then return nil end
    return {
        text = text,
        icon = icon_path(pget(icon_p)),
        col = colour_of(pget(col_p)),
        delay = tonumber(pget(delay_p)) or 2,
        force = pget(force_p) == true,
    }
end

-- ---------------------------------------------------------------------------
-- This screen's notices
-- ---------------------------------------------------------------------------

-- Remembers a notice this screen showed; true when the game really added a
-- widget for it (forced, or the same text was not on screen any more).
local function shown_here(text, delay, force)
    local now = clock()
    local r = st.recent[text]
    local fresh = force or not r or now >= r.till
    st.recent[text] = { t = now, till = now + (tonumber(delay) or 2) + 1 }
    return fresh
end

local function seen_within(text, s)
    local r = st.recent[text]
    return r ~= nil and clock() - r.t <= s
end

-- Host: a notice the host's own screen showed (nobody else's), for modules
-- that relay a world event's own notice to the clients (sdc_events: the
-- crashed helicopter's "A helicopter has crashed in The Valley...").
local function remember_shown(n)
    local l = st.shown_log
    l[#l + 1] = { t = clock(), cls = n.cls, text = n.text, icon = n.icon, col = n.col, delay = n.delay }
    if #l > 16 then table.remove(l, 1) end
end

-- Host: the notices this screen showed since `t0` whose context was of class
-- `cls` (oldest first): { text, icon (path or ""), col, delay }.
function M.shown_since(t0, cls)
    local out = {}
    for _, e in ipairs(st.shown_log) do
        if e.t >= t0 and (cls == nil or e.cls == cls) then
            out[#out + 1] = { text = e.text, icon = e.icon, col = e.col, delay = e.delay }
        end
    end
    return out
end

-- The newest notification widget with this text leaves this screen.
local function take_off(text)
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    local vb = ue.prop(ue.prop(hud, "NotificationUI"), "VerticalBox_31")
    if not ue.valid(vb) then return false end
    local n = tonumber(ue.try(function() return vb:GetChildrenCount() end)) or 0
    for i = n - 1, math.max(0, n - 8), -1 do
        local w = ue.try(function() return vb:GetChildAt(i) end)
        local det = ue.prop(w, "NotificationDetailsStruct")
        local msg = det and ue.fstring(ue.try(function() return det[MSG_FIELD] end)) or ""
        if msg == text then
            local ok = pcall(function() w:RemoveFromParent() end)
            if ok then M.stats.taken_off = M.stats.taken_off + 1 end
            return ok
        end
    end
    return false
end
M.take_off = take_off

-- ---------------------------------------------------------------------------
-- Host: whose notice is it
-- ---------------------------------------------------------------------------

local function is_weapon(o)
    return ue.valid(ue.prop(o, "BP_WeaponsPickupComponent"))
end

-- What sdc_ctx's player-0 pre-hook answered for this context (read again
-- after the call, same call stack): the remote controller and how, or nil.
-- "weapon": a remote player's weapon asks for no player (its owner runs its
-- own effects).
local function asked_for(wco)
    local a = addr_of(wco)
    if not a then return nil, nil end
    local pc, how = nil, nil
    local rs = ctx.scope_resolver
    if rs then
        local ok, spc = pcall(rs, wco, a)
        if ok and spc == false then return nil, "host" end
        if ok and spc ~= nil and remote_pc(spc) then pc, how = spc, "scope" end
    end
    if not pc then
        local e = ctx.player_for(wco, a)
        if e and remote_pc(e.pc) then pc, how = e.pc, "own" end
    end
    if not pc and ctx.stand_in then
        local ok, spc = pcall(ctx.stand_in, wco)
        if ok and remote_pc(spc) then pc, how = spc, "kill" end
    end
    if pc and cfg.get("host_weapon_fx_quiet") ~= false and cfg.get("fix_client_damage") ~= false
        and is_weapon(wco) then
        return nil, "weapon"
    end
    -- a world object a scope named a player for (a container / buildable's
    -- CurrentActor can be left over from that player's last use): only while
    -- that player is near it
    if pc and how == "scope" then
        local ol, pl = ue.location(wco), ue.location(ue.pawn_of(pc))
        if ol and pl then
            local dx, dy, dz = ol.X - pl.X, ol.Y - pl.Y, ol.Z - pl.Z
            if dx * dx + dy * dy + dz * dz > SCOPE_NEAR_CM * SCOPE_NEAR_CM then return nil, "far" end
        end
    end
    return pc, how
end
M.asked_for = asked_for

-- Why a remote player's notice is not sent, or nil.
local function skip_reason(cls, text, how)
    if how == "kill" then return "a kill popup: sdc_ai_kills credits the killer on its own machine" end
    if text:find("XP Given", 1, true) or text:find("XP given", 1, true) then
        return "an XP note: the XP itself reaches that player through its own module"
    end
    for _, o in ipairs(OWN_CLASSES) do
        if cls:find(o[1], 1, true) then return o[2] end
    end
    return nil
end
M.skip_reason = skip_reason

local function pc_name(pc)
    local r = S and S.remote and S.remote[ue.name(pc)]
    if type(r) == "table" and type(r.name) == "string" and r.name ~= "" then return r.name end
    return ue.short(pc)
end

-- A connected player's controller by its address (looked up, never kept).
local function pc_by_addr(pa)
    if not pa then return nil end
    for _, pc in ipairs((S and S.remote_pcs) or {}) do
        if ue.valid(pc) and addr_of(pc) == pa then return pc end
    end
    return nil
end

-- Rate: one per player and text per max(delay, GAP_MIN_S), BURST per player.
local function allowed(pa, text, delay)
    local now = clock()
    local k = tostring(pa) .. "|" .. text
    local last = st.sent[k]
    if last and now - last < math.max(tonumber(delay) or 2, GAP_MIN_S) then return false end
    local b = st.tokens[pa]
    if not b then b = { n = BURST, t = now }; st.tokens[pa] = b end
    b.n = math.min(BURST, b.n + (now - b.t) * REFILL)
    b.t = now
    if b.n < 1 then return false end
    b.n = b.n - 1
    st.sent[k] = now
    return true
end

-- NOTE to that client. `why` for the log. Returns true when sent, or when
-- the same text went to that player moments ago (throttled).
local function relay(pc, n, why)
    if not on("notes_relay") or not remote_pc(pc) then return false end
    local pa = addr_of(pc)
    if not allowed(pa, n.text, n.delay) then
        M.stats.throttled = M.stats.throttled + 1
        log.debug("notes: '%s' for %s not sent again so soon (throttled)", line(n.text), ue.short(pc))
        return st.sent[tostring(pa) .. "|" .. n.text] ~= nil
    end
    local ok = net.send_to(pc, "NOTE", esc(n.text), n.icon or "", colour_str(n.col or WHITE),
        string.format("%.1f", tonumber(n.delay) or 2))
    if ok then
        M.stats.relayed = M.stats.relayed + 1
        say("relay|" .. tostring(pa) .. "|" .. n.text, "notes: '%s' (%s) is %s's: sent to that player (%s)",
            line(n.text), n.cls or "?", pc_name(pc), why)
    end
    return ok
end

-- A notice the host's screen showed belongs to `pc`: off this screen, to
-- that player (an XP note stays: the XP went to the host as well).
local function claim(n, pc, why)
    if not remote_pc(pc) or not on("notes_owner_only") then return false end
    if n.text:find("XP Given", 1, true) or n.text:find("XP given", 1, true) then
        M.stats.kept = M.stats.kept + 1
        log.info("notes: '%s' (%s) came from %s's action but stays on the host's screen: the XP went to the host's "
            .. "player (world-scope gap)", line(n.text), n.cls or "?", pc_name(pc))
        return false
    end
    local off = n.fresh and take_off(n.text) or false
    say("claim|" .. n.text, "notes: '%s' (%s) was %s's (%s): %s, sent to that player", line(n.text), n.cls or "?",
        pc_name(pc), why, off and "taken off the host's screen" or "not on the host's screen")
    relay(pc, n, why)
    return true
end

local function prune_pending(now)
    if #st.pending == 0 then return end
    local keep = {}
    for _, p in ipairs(st.pending) do
        if now - p.t <= PENDING_S then keep[#keep + 1] = p end
    end
    st.pending = keep
end

-- ---------------------------------------------------------------------------
-- Scopes (other modules)
-- ---------------------------------------------------------------------------

local function top_scope() return st.scopes[#st.scopes] end

local function run_scope(sc, fn, ...)
    st.scopes[#st.scopes + 1] = sc
    local ok, err = pcall(fn, ...)
    for i = #st.scopes, 1, -1 do
        if st.scopes[i] == sc then table.remove(st.scopes, i) break end
    end
    return ok, err, sc.n
end

-- Host: run fn(...) as `pc`'s action: the game's notices it raises are that
-- player's (off the host's screen, sent to that player). Returns ok, err, n
-- (notices it raised). Without a remote pc, fn just runs.
function M.for_player(pc, fn, ...)
    if role() ~= "host" or not remote_pc(pc) then
        local ok, err = pcall(fn, ...)
        return ok, err, 0
    end
    return run_scope({ kind = "for", pc_addr = addr_of(pc), label = ue.short(pc), n = 0 }, fn, ...)
end

-- Any machine: run fn(...) while applying another player's state here: the
-- game's notices it raises are not this player's (off this screen). Returns
-- ok, err, n.
function M.quietly(why, fn, ...)
    return run_scope({ kind = "quiet", label = tostring(why or "?"), n = 0 }, fn, ...)
end

local function scope_pc(sc)
    return sc and pc_by_addr(sc.pc_addr) or nil
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- GameFunctionLibrary_C.CreateNotificationUI (post), every machine.
local function on_note(_, msg_p, icon_p, col_p, delay_p, force_p, wco_p)
    local r = role()
    if r ~= "host" and r ~= "client" then return end
    local n = note_of(msg_p, icon_p, col_p, delay_p, force_p)
    if not n then return end
    local wco = pget(wco_p)
    n.cls = ue.class_name(wco)
    local sc = top_scope()
    if r == "client" then
        -- another player's object: sdc_ctx's client mode gave it no player,
        -- nothing was shown
        if ctx.client_mode and ctx.classify(wco, "client") == "other" then return end
        local fresh = shown_here(n.text, n.delay, n.force)
        if sc and sc.kind == "quiet" and on("notes_owner_only") then
            sc.n = sc.n + 1
            local off = fresh and take_off(n.text)
            M.stats.quieted = M.stats.quieted + 1
            say("quiet|" .. n.text, "notes: '%s' (%s) raised here while %s (another player's state): %s",
                line(n.text), n.cls, sc.label, off and "taken off this screen" or "not on this screen")
            return
        end
        -- the host's wreck of a random event reaching this client long after
        -- the event (sdc_events): its BeginPlay notice is no event here
        local evm = package.loaded["sdc_events"]
        if fresh and evm and evm.stale_note then
            local oks, stale, why = pcall(evm.stale_note, wco, n.text)
            if oks and stale then
                local off = take_off(n.text)
                st.recent[n.text] = nil   -- (a relayed copy later is not a duplicate of it)
                M.stats.quieted = M.stats.quieted + 1
                say("stale|" .. n.text, "notes: '%s' (%s) raised here by %s: %s", line(n.text), n.cls, tostring(why),
                    off and "taken off this screen" or "not on this screen")
            end
        end
        return
    end
    -- host
    if not ctx.active then
        shown_here(n.text, n.delay, n.force)
        remember_shown(n)
        return
    end
    local now = clock()
    local wa = addr_of(wco)
    local pc, how
    local m = st.memo
    if m and m.wa == wa and m.text == n.text and now - m.t < 0.25 then
        -- the same context and text again this instant (the radiation timer)
        pc, how = pc_by_addr(m.pa), m.how
    else
        pc, how = asked_for(wco)
        st.memo = { wa = wa, text = n.text, t = now, pa = pc and addr_of(pc) or nil, how = how }
    end
    if sc then sc.n = sc.n + 1 end
    if pc then
        -- the cast failed on the host: nobody saw it
        if sc and sc.kind == "quiet" then return end
        local reason = skip_reason(n.cls, n.text, how)
        if reason then
            M.stats.skipped = M.stats.skipped + 1
            log.debug("notes: '%s' (%s) for %s not sent: %s", line(n.text), n.cls, ue.short(pc), reason)
            return
        end
        relay(pc, n, how == "scope" and "a scope named that player" or "that player's own object")
        return
    end
    if how == "weapon" then return end   -- nobody: the weapon's owner shows it
    if how == "far" then                 -- redirected, but that player is far from the object
        log.debug("notes: '%s' (%s): the scope named a player far from it; not sent", line(n.text), n.cls)
        return
    end
    -- shown on the host's screen
    n.fresh = shown_here(n.text, n.delay, n.force)
    if sc and sc.kind == "for" then
        local spc = scope_pc(sc)
        if spc then claim(n, spc, "run for that player by the mod") end
        return
    end
    if sc and sc.kind == "quiet" and on("notes_owner_only") then
        local off = n.fresh and take_off(n.text)
        M.stats.quieted = M.stats.quieted + 1
        say("quiet|" .. n.text, "notes: '%s' (%s) raised on the host while %s: %s", line(n.text), n.cls, sc.label,
            off and "taken off the host's screen" or "not on the host's screen")
        return
    end
    remember_shown(n)
    -- a world object's notice: a client's interaction / hit may claim it
    -- (SERVER_ForwardInteract / Damage_Object post, same call stack)
    if wa then
        prune_pending(now)
        n.wa, n.t = wa, now
        st.pending[#st.pending + 1] = n
    end
end

-- BP_PlayerCharacter.CreateNotificationUI(Text, Image, Color, UI Delay)
-- (post, host): shown only where that character is locally controlled.
local function on_char_note(c, text_p, image_p, col_p, delay_p)
    if role() ~= "host" or not ctx.active then return end
    local ch = pget(c)
    if not ue.valid(ch) then return end
    local e = ctx.player_for(ch)
    if not e or not remote_pc(e.pc) then return end
    local n = note_of(text_p, image_p, col_p, delay_p, nil)
    if not n then return end
    n.cls = "BPI_Player of " .. ue.class_name(ch)
    if skip_reason("", n.text, nil) then
        M.stats.skipped = M.stats.skipped + 1
        log.debug("notes: '%s' (%s) for %s not sent: an XP note", line(n.text), n.cls, ue.short(e.pc))
        return
    end
    relay(e.pc, n, "the game showed it on that player's character only where it is controlled")
end

-- Claims the pending notices of object `oa` for `pc`.
local function claim_pending(oa, pc, why, only_text)
    if #st.pending == 0 or not oa then return 0 end
    local now = clock()
    local keep, n = {}, 0
    for _, p in ipairs(st.pending) do
        if p.wa == oa and now - p.t <= PENDING_S and (not only_text or p.text == only_text) then
            if claim(p, pc, why) then n = n + 1 end
        elseif now - p.t <= PENDING_S then
            keep[#keep + 1] = p
        end
    end
    st.pending = keep
    return n
end

-- BP_JigComponent.SERVER_ForwardInteract(Actor, Option, Payload) (post,
-- host): the player's request reached Actor.OnServerExecuteInteract(Option,
-- that player's pawn) (@16818-16913) in this very call.
local function on_forward(c, actor_p)
    if role() ~= "host" or #st.pending == 0 then return end
    local comp = pget(c)
    local e = ue.valid(comp) and ctx.player_for(comp) or nil
    if not e or not remote_pc(e.pc) then return end
    claim_pending(addr_of(pget(actor_p)), e.pc, "its interaction, run on the host")
end

-- BP_Infestation.Damage_Object(Damage, Damage Causer, Event Instigator)
-- (post, host): a locked primary nest refused this hit with the note @7946.
local function on_nest_hit(c, _, causer_p, inst_p)
    if role() ~= "host" or #st.pending == 0 then return end
    local nest = pget(c)
    local causer = pget(causer_p)
    local e = ue.valid(causer) and ctx.player_for(causer) or nil
    local pc = e and e.pc or nil
    if not remote_pc(pc) then
        local inst = pget(inst_p)
        if remote_pc(inst) then pc = inst end
    end
    if not remote_pc(pc) then return end
    claim_pending(addr_of(nest), pc, "its hit on the nest", NEST_NOTE)
end

local HOOKS = {
    { P.gfl, on_note, "notes" },
    { P.char, on_char_note, "char" },
    { P.forward, on_forward, "forward" },
    { P.infest, on_nest_hit, "nest" },
}

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("notes." .. name, "notes: %s hook: %s", name, tostring(err)) end
    end
end

-- Blueprint functions exist once their class is loaded: tried again every
-- HOOK_RETRY_S until each is in (one callback each, after the call).
function M.try_hooks(force)
    local now = clock()
    if not force and now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    for _, h in ipairs(HOOKS) do
        if not st.hooks[h[3]] and ue.find_object(h[1]) then
            local ok, err = pcall(RegisterHook, h[1], safe(h[3], h[2]))
            st.hooks[h[3]] = ok
            if ok then
                log.info("notes: hook %s ok", h[1]:match("([%w_]+:[%w_]+)$") or h[1])
            elseif not st.hook_logged[h[3]] then
                st.hook_logged[h[3]] = true
                log.warn("notes: cannot hook %s: %s", h[1], tostring(err))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Client: a notice from the host
-- ---------------------------------------------------------------------------

local function show(n)
    local gfl = ue.find_object(P.gfl_cdo)
    local pc = ue.local_pc()
    if not gfl or not pc then
        log.debug("notes: the host's note '%s' not shown: no game HUD here yet", line(n.text))
        return false
    end
    local icon = n.icon ~= "" and ue.loaded_asset(n.icon, "notes") or nil
    local ok, err = pcall(function()
        gfl:CreateNotificationUI(FText(n.text), icon, n.col, n.delay, false, pc)
    end)
    if not ok then
        log.err_throttled("notes.show", "notes: showing the host's note failed: %s", tostring(err))
    end
    return ok
end

-- NOTE|text|icon|r,g,b,a|delay   (host -> client)
local function on_note_msg(f)
    if role() ~= "client" then return end
    local n = { text = unesc(f[1]), icon = tostring(f[2] or ""), col = parse_colour(f[3]),
                delay = tonumber(f[4]) or 2 }
    if n.text == "" then return end
    M.stats.got = M.stats.got + 1
    if not on("notes_relay") then
        log.debug("notes: the host's note '%s' not shown (notes_relay off here)", line(n.text))
        return
    end
    if seen_within(n.text, DEDUP_S) then
        M.stats.deduped = M.stats.deduped + 1
        log.debug("notes: the host's note '%s': this screen showed it already", line(n.text))
        return
    end
    st.queued[n.text] = clock() + HOLD_S + DEDUP_S
    ue.delay("notes-show", math.floor(HOLD_S * 1000), function()
        if seen_within(n.text, DEDUP_S) then
            M.stats.deduped = M.stats.deduped + 1
            log.debug("notes: the host's note '%s': this machine raised it itself meanwhile", line(n.text))
            return
        end
        if show(n) then
            M.stats.shown = M.stats.shown + 1
            say("shown|" .. n.text, "notes: the host's note '%s' shown here", line(n.text))
        end
    end)
end

-- True when this screen shows `text` or will show it from the host (within
-- `s` seconds): for modules whose own toast would repeat the game's notice.
function M.covered(text, s)
    s = tonumber(s) or 5
    if seen_within(text, s) then return true end
    local q = st.queued[text]
    return q ~= nil and clock() <= q
end

-- Host: true when `text` went to `pc` as the game's notice within `s` s.
function M.sent_to(pc, text, s)
    local pa = addr_of(pc)
    local t = pa and st.sent[tostring(pa) .. "|" .. tostring(text)]
    return t ~= nil and clock() - t <= (tonumber(s) or 5)
end

-- Host: the game's notice `text` (icon path or "", colour, delay) on that
-- player's screen, the game's way: here for the host's own player, NOTE for
-- a client. For modules that run a game flow in Lua (it raises no notice).
function M.show_to(pc, text, icon, colour, delay, why)
    local n = { text = tostring(text or ""), icon = icon or "", col = colour or WHITE, delay = tonumber(delay) or 2,
                cls = why or "mod" }
    if n.text == "" then return false end
    if remote_pc(pc) then return relay(pc, n, why or "the mod's run of the game's flow") end
    local ok = show(n)
    if ok then log.info("notes: '%s' shown on the host's screen (%s)", line(n.text), why or "mod") end
    return ok
end

-- Any machine: a notice of the mod's own (text already in this player's
-- language, icon path or "", colour, delay) on THIS screen, the game's way
-- (sdc_playernotes: another player died / respawned). The game's hook then
-- counts it as shown here (dedup with the relayed ones).
function M.show_here(text, icon, colour, delay, why)
    local n = { text = tostring(text or ""), icon = icon or "", col = colour or WHITE, delay = tonumber(delay) or 2 }
    if n.text == "" then return false end
    local ok = show(n)
    if ok then say("here|" .. n.text, "notes: '%s' shown here (%s)", line(n.text), why or "mod") end
    return ok
end

-- ---------------------------------------------------------------------------
-- Install / tick / reset
-- ---------------------------------------------------------------------------

function M.reset(why)
    st.recent, st.pending, st.sent, st.tokens, st.queued = {}, {}, {}, {}, {}
    st.memo = nil
    st.scopes = {}
    st.shown_log = {}
    log.debug("notes: state dropped (%s)", tostring(why or "?"))
end

-- 1 s tick (main.lua): hooks, role change, table pruning.
function M.tick()
    local r = role()
    if r ~= st.role then
        if st.role ~= nil then M.reset("role " .. tostring(st.role) .. " -> " .. tostring(r)) end
        st.role = r
    end
    if r ~= "host" and r ~= "client" then return end
    M.try_hooks(false)
    local now = clock()
    for k, v in pairs(st.recent) do if now - v.t > 30 then st.recent[k] = nil end end
    for k, t in pairs(st.sent) do if now - t > 60 then st.sent[k] = nil end end
    for k, t in pairs(st.queued) do if now > t then st.queued[k] = nil end end
    for k, t in pairs(st.info_at) do if now - t > INFO_EVERY_S * 2 then st.info_at[k] = nil end end
    if #st.scopes > 0 then
        log.warn("notes: %d scope(s) left open; dropped", #st.scopes)
        st.scopes = {}
    end
    prune_pending(now)
end

function M.status_line()
    local s = M.stats
    return string.format("notes relayed=%d skipped=%d throttled=%d taken_off=%d kept=%d quieted=%d got=%d shown=%d deduped=%d hooks=%s",
        s.relayed, s.skipped, s.throttled, s.taken_off, s.kept, s.quieted, s.got, s.shown, s.deduped,
        (function()
            local t = {}
            for _, h in ipairs(HOOKS) do t[#t + 1] = h[3] .. (st.hooks[h[3]] and "+" or "-") end
            return table.concat(t, ",")
        end)())
end

local installed = false
function M.install(state)
    S = state or S
    if installed then return end
    installed = true
    net.on("NOTE", on_note_msg)
    local session = package.loaded["sdc_session"]
    if session and session.world_reset_hooks then
        session.world_reset_hooks.notes = function(why) M.reset("world:" .. tostring(why)) end
    end
    M.try_hooks(true)
    log.info("notes: installed (relay %s, owner only %s)", on("notes_relay") and "on" or "off",
        on("notes_owner_only") and "on" or "off")
end

-- tests
M._t = { on_note = on_note, on_char_note = on_char_note, on_forward = on_forward, on_nest_hit = on_nest_hit,
         on_note_msg = on_note_msg, set_state = function(s) S = s end, HOLD_S = HOLD_S, DEDUP_S = DEDUP_S }

return M
