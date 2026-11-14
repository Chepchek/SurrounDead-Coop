-- SDCoop: the infection bar (the HUD's InfectionBorder) on a client's screen,
-- as the host has it on its own.
--
-- The game (work\re\pseudo; json\BP_Ingame.json):
--   * BP_Ingame (the HUD): InfectionBorder, a dark plate at the left middle of
--     the screen holding InfectionStat (an Overlay: the olive virus icon and
--     InfectionBar, a ProgressBarLinear). The Border is not a widget variable
--     (InfectionStat is: its parent); it starts Hidden at RenderOpacity 0 and
--     only the widget animation InfectionAnim shows it (Visibility ->
--     SelfHitTestInvisible at frame 0, RenderOpacity 0 -> 1 in 0.5 s).
--     UpdateInfection(Infection) -> InfectionBar.PB_SetPercent(Infection / 100).
--   * A bite (BP_MasterZombie BiteTrace -> GameFunctionLibrary.
--     ApplyBiteInfection) or a hit (ApplyMedicalEffect) runs on the host (the
--     zombie AI): MedicalComponent.Infection? = true, then OnRep_Infection?()
--     there. OnRep_Infection? (MedicalComponent.txt:497-531) is the only
--     caller of InfectionAnim: Player.GetInGameUI().PlayAnimationForward /
--     Reverse(InfectionAnim); then the 1 s timer Infection (InfectionAmount
--     0 -> 100 from InfectionTimeLeft) -> Player.SendInfectionToClient ->
--     Client_UpdateInfectionUI [NetClient] -> InGameUI.UpdateInfection. At
--     100 the timer switches to InfectionDamage and the value stops coming.
-- For a client's character:
--   * on the host the OnRep runs, but the host's copy has no HUD (InGameUI is
--     made only for a locally controlled character): the animation went
--     nowhere;
--   * on the client it never runs: MedicalComponent does not replicate
--     (Infection? stays false there, BaseComponent.Player is None).
--   So the client's bar may fill (Client_UpdateInfectionUI), but its plate is
--   never shown.
-- Here:
--   host:   every POLL_S, for each remote player's character, its
--           MedicalComponent.Infection? / InfectionAmount ->
--           INFUI|1|<percent> when it turns on (again FIRST_KEEP_S later: the
--           amount of the timer's first tick; then every KEEP_S while on: a
--           late HUD, a client that dropped its state, the 100 % stage where
--           the game sends nothing), INFUI|0| when it turns off (a cure; the
--           new character after a respawn; the switch turned off here).
--   client: INFUI -> the wanted state. Every tick the own HUD's plate is
--           compared with it; a difference that lasts GRACE_S is fixed with
--           the game's own animation (PlayAnimationForward / Reverse of
--           InfectionAnim; at most MAX_TRIES times per state and HUD). Only a
--           plate shown by this module is hidden by it. The host's percent
--           goes in with UpdateInfection when the bar (InfectionBar.
--           CurrentPercent, see bar_value) is BAR_DIFF or more away from it:
--           the game's own Client_UpdateInfectionUI keeps it current every
--           second otherwise.
--   The host's own HUD is never touched. Nothing of the HUD is cached between
--   ticks (addresses only): each tick reads it again from the own character.
-- Old builds: an old client has no INFUI handler (the message is dropped);
-- with an old host the client simply gets no INFUI (as before).
-- Config: client_infection_hud (each machine its own). Switched off on a
-- client: INFUI is still recorded (no HUD work for it); a plate this module
-- showed is hidden, nothing else is touched; switched on again, the plate
-- follows the host's latest state (a cure that came meanwhile included).
-- Driven by sdc_geiger (install / tick / reset / status line), next to
-- sdc_hudmods.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = {
    stats = {
        -- host: INFUI sent
        sent_on = 0, sent_off = 0, sent_keep = 0,
        -- client
        got = 0, shown = 0, hidden = 0, pushed = 0, bar_ok = 0, failed = 0, gave_up = 0,
    },
}

local MSG = "INFUI"
local POLL_S = 1.0          -- s: host: remote players' infection read this often
local FIRST_KEEP_S = 2      -- s: host: "on" once more this soon after it turned on
local KEEP_S = 30           -- s: host: "on" again this often while on (the verify; the game's own bar update keeps the percent current)
local OFF_KEEP_S = 120      -- s: host: "off" again this often to a client that was ever told "on" (a lost "off" must not leave the bar on)
local GRACE_S = 1.0         -- s: client: a wrong plate state must last this long before it is fixed
local MAX_TRIES = 3         -- client: animation calls per wanted state and HUD before giving up
local SHOWN_AT = 0.5        -- RenderOpacity from which the plate counts as shown
local BAR_DIFF = 1.0        -- percent points: the bar this far from the host's percent gets it
local EDGE_LINES = 10       -- info lines for plate switches (then debug)
local VIS_COLLAPSED, VIS_HIDDEN = 1, 2   -- ESlateVisibility

local S
local function new_client() return { want = false, pct = nil, pct_new = false } end
local function new_hud_state() return { want = false, miss = nil, tries = 0, ours = false, gave_up = false, pushes = 0, bar_logged = false } end
local st = {
    -- host: [controller address] = { sent = true / false / nil, next_at }
    recs = {}, poll_at = -100,
    -- client
    pawn = nil, hud = nil,      -- addresses of the own character / its HUD
    c = new_client(),           -- the host's infection state of the own character
    h = new_hud_state(),        -- the plate on the current HUD
    lines = 0,
    logged = {},
}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local clock = os.clock
local function m_addr(o) return o:GetAddress() end
local function m_local(p) return p:IsLocallyControlled() end
local function m_parent(w) return w:GetParent() end
local function m_play(hud, fn, anim) hud[fn](hud, anim, 1.0, false) end
local function m_update(hud, v) hud:UpdateInfection(v) end

local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(m_addr, o)
    if ok and a ~= nil and a ~= 0 then return a end
    return nil
end

local function locally_controlled(p)
    local ok, v = pcall(m_local, p)
    return ok and v == true
end

local function is_player(o)
    return ue.valid(o) and ue.class_name(o):find("PlayerCharacter", 1, true) ~= nil
end

local function enabled() return cfg.get("client_infection_hud") ~= false end

local function once(key, fmt, ...)
    if st.logged[key] then return end
    st.logged[key] = true
    log.info(fmt, ...)
end

local function pct(v)
    if type(v) == "number" then return string.format("%.2f%%", v) end
    return "unknown"
end

local function yes_no(o) return ue.valid(o) and "set" or "none" end

local function secs(v)
    v = tonumber(v)
    if v then return string.format("%.0f", v) end
    return "?"
end

-- ===========================================================================
-- Host
-- ===========================================================================

-- "BP_PlayerCharacter_C_123 (Name)"
local function who(pawn, pc)
    local r = S and S.remote and S.remote[ue.name(pc)] or nil
    return string.format("%s (%s)", ue.short(pawn), r and tostring(r.name) or "?")
end

-- A character's infection on the host: true / false and its
-- MedicalComponent, or nil when it cannot be read.
local function infection_of(pawn)
    local med = ue.prop(pawn, "MedicalComponent")
    if not ue.valid(med) then return nil end
    local f = ue.prop(med, "Infection?")
    if type(f) ~= "boolean" then
        once("host-noflag", "infui: %s has no readable Infection? (%s): no infection bar is sent for it", ue.short(med), tostring(f))
        return nil
    end
    return f, med
end

-- INFUI|<1 / 0>|<percent / "">
local function send(pc, r, on, amount, now, why)
    local v = (on and type(amount) == "number") and string.format("%.2f", amount) or ""
    if not net.send_to(pc, MSG, on and "1" or "0", v) then return false end
    r.sent = on
    if on then r.ever = true else r.off_at = now + OFF_KEEP_S end
    r.next_at = now + (why == "on" and FIRST_KEEP_S or KEEP_S)
    local s = M.stats
    if why == "on" then
        s.sent_on = s.sent_on + 1
    elseif why == "off" then
        s.sent_off = s.sent_off + 1
    else
        s.sent_keep = s.sent_keep + 1
        log.debug("infui: infection bar of %s kept on its screen: %s", ue.short(ue.pawn_of(pc)), pct(amount))
    end
    return true
end

local function host_tick(now)
    if now - st.poll_at < POLL_S then return end
    st.poll_at = now
    local en = enabled()
    local seen = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        local a = ue.valid(pc) and addr(pc) or nil
        if a then
            seen[a] = true
            local r = st.recs[a]
            if not r then
                r = { sent = nil, next_at = 0 }
                st.recs[a] = r
            end
            local pawn = ue.pawn_of(pc)
            -- another character: its client knows nothing of it - "on" goes now, not at the next verify
            local pa = pawn and addr(pawn) or nil
            if pa ~= r.pawn_a then
                r.pawn_a = pa
                if r.sent == true then r.next_at = 0 end
            end
            local on, med = nil, nil
            if pawn then on, med = infection_of(pawn) end
            if on == true and not en then on = false end   -- switched off here: a plate told "on" goes away
            if on == true then
                local amount = tonumber(ue.prop(med, "InfectionAmount"))
                if r.sent ~= true then
                    if send(pc, r, true, amount, now, "on") then
                        log.info("infui: %s infected on the host (MedicalComponent.Infection? true, InfectionAmount %s, InfectionTimeLeft %s s; this copy: Player %s, InGameUI %s - the game's own InfectionAnim had no HUD to play on) -> INFUI on to its screen",
                            who(pawn, pc), pct(amount), secs(ue.prop(med, "InfectionTimeLeft")),
                            yes_no(ue.prop(med, "Player")), yes_no(ue.prop(pawn, "InGameUI")))
                    end
                elseif now >= r.next_at then
                    send(pc, r, true, amount, now, "keep")
                end
            elseif on == false and r.sent == true then
                if send(pc, r, false, nil, now, "off") then
                    log.info("infui: %s no longer infected on the host (%s) -> INFUI off to its screen", who(pawn, pc),
                        en and "Infection? false: cured, or a new character" or "client_infection_hud off here")
                end
            elseif on == false and r.ever and now >= (r.off_at or 0) then
                send(pc, r, false, nil, now, "off_keep")
            end
        end
    end
    for a in pairs(st.recs) do
        if not seen[a] then st.recs[a] = nil end
    end
end

-- ===========================================================================
-- Client
-- ===========================================================================

local function own_pawn()
    local p = ue.local_pawn()
    if is_player(p) and locally_controlled(p) then return p end
    return nil
end

-- net INFUI (host -> client): the host's infection state of the own character.
-- Recorded with the switch off too (the host sends a change only once): on
-- again, the plate follows the latest state.
local function on_msg(f)
    if not S or S.role ~= "client" then return end
    M.stats.got = M.stats.got + 1
    local c = st.c
    local v = tonumber(f[2])
    local off_here = not enabled() and " (client_infection_hud off here: recorded only)" or ""
    if f[1] == "1" then
        if v then c.pct, c.pct_new = v, true end
        if not c.want then
            local me = own_pawn()
            local med = me and ue.prop(me, "MedicalComponent") or nil
            log.info("infui: host: own character infected (%s) -> infection bar wanted on (the game shows it only from OnRep_Infection? on the host's copy, which has no HUD; this copy: Infection? %s, Player %s)%s",
                pct(v), tostring(ue.prop(med, "Infection?")), yes_no(ue.prop(med, "Player")), off_here)
        end
        c.want = true
    elseif f[1] == "0" then
        if c.want then log.info("infui: host: own character no longer infected -> infection bar wanted off%s", off_here) end
        c.want, c.pct, c.pct_new = false, nil, false
    end
end

-- The plate: InfectionStat's parent (InfectionBorder is not a widget variable).
local function find_plate(hud)
    local stat = ue.prop(hud, "InfectionStat")
    if not ue.valid(stat) then return nil, "no InfectionStat" end
    local b = ue.prop(ue.prop(stat, "Slot"), "Parent")
    if not ue.valid(b) then
        local ok, p = pcall(m_parent, stat)
        b = ok and p or nil
    end
    if not ue.valid(b) then return nil, "InfectionStat has no parent" end
    return b
end

-- true / false, or nil when it cannot be read
local function plate_shown(b)
    local op = tonumber(ue.prop(b, "RenderOpacity"))
    if op == nil then return nil end
    local vis = tonumber(ue.prop(b, "Visibility"))
    if vis == VIS_COLLAPSED or vis == VIS_HIDDEN then return false end
    return op >= SHOWN_AT
end

-- What the bar shows, 0..100, or nil. ProgressBarLinear (work\re: the
-- HQUI_ProgressBars widget, extracted 2026-11-13): PB_SetPercent(v) with
-- InfectionBar's ProgressMethod 0 (static; BP_Ingame.json) runs
-- UpdatePercent: CurrentPercent = FClamp(v, 0, 1) (@8540-8595, @14175-14230);
-- method 1 sets CurrentPercent when its queued entry runs (@25804).
-- TargetPercent is the bar's second "target" fill (PB_SetTargetPercent), never
-- touched by PB_SetPercent: it stays at the 1.0 BP_Ingame gives InfectionBar.
-- 0.8.1 read TargetPercent, saw 100 % every time and pushed the percent again
-- every 10 s (13.11 client log: 210 pushes, not one "already at").
local function bar_value(hud)
    local t = tonumber(ue.prop(ue.prop(hud, "InfectionBar"), "CurrentPercent"))
    return t and t * 100 or nil
end

-- The host's percent into the bar, unless the bar already shows it (the
-- game's own Client_UpdateInfectionUI every second).
local function push(hud)
    local c, h = st.c, st.h
    c.pct_new = false
    local v = c.pct
    local bar = bar_value(hud)
    if bar and math.abs(bar - v) < BAR_DIFF then
        M.stats.bar_ok = M.stats.bar_ok + 1
        if not h.bar_logged then
            h.bar_logged = true
            log.info("infui: own infection bar already at %s (host: %s): the game's own Client_UpdateInfectionUI keeps it", pct(bar), pct(v))
        end
        return
    end
    local ok, err = pcall(m_update, hud, v)
    if not ok then
        M.stats.failed = M.stats.failed + 1
        log.err_throttled("infui.update", "infui: UpdateInfection(%s) on the own HUD failed: %s", pct(v), tostring(err))
        return
    end
    M.stats.pushed = M.stats.pushed + 1
    h.pushes = h.pushes + 1
    local fn = h.pushes == 1 and log.info or log.debug
    fn("infui: own infection bar %s -> %s (UpdateInfection with the host's percent: the bar did not show it)", pct(bar), pct(v))
end

local function edge_line(fmt, ...)
    st.lines = st.lines + 1
    if st.lines <= EDGE_LINES then log.info(fmt, ...) else log.debug(fmt, ...) end
end

local function reconcile(hud, now)
    local c, h = st.c, st.h
    local en = enabled()
    local want = c.want and en      -- switched off here: only a plate shown by this module is hidden
    if want ~= h.want then h.want, h.miss, h.tries, h.gave_up = want, nil, 0, false end
    if not want and not h.ours then h.miss = nil; return end   -- nothing shown by this module
    if want and c.pct_new and type(c.pct) == "number" then push(hud) end
    local plate, why = find_plate(hud)
    if not plate then
        once("noplate", "infui: own HUD %s: infection plate not found (%s): the infection bar is not shown", ue.short(hud), tostring(why))
        return
    end
    local shown = plate_shown(plate)
    if shown == nil then
        once("noopacity", "infui: cannot read the infection plate's RenderOpacity on the own HUD %s: not checked", ue.short(hud))
        return
    end
    if shown == want then
        h.miss, h.tries, h.gave_up = nil, 0, false
        return
    end
    if h.tries >= MAX_TRIES then
        if not h.gave_up then
            h.gave_up = true
            M.stats.gave_up = M.stats.gave_up + 1
            log.warn("infui: own infection plate still %s after %d InfectionAnim call(s) on the HUD %s: left alone until the state or the HUD changes",
                shown and "shown" or "hidden", h.tries, ue.short(hud))
        end
        return
    end
    h.miss = h.miss or now
    local waited = now - h.miss
    if waited < GRACE_S then return end
    local anim = ue.prop(hud, "InfectionAnim")
    if not ue.valid(anim) then
        once("noanim", "infui: own HUD %s has no InfectionAnim: the infection bar is not shown", ue.short(hud))
        return
    end
    local fn = want and "PlayAnimationForward" or "PlayAnimationReverse"
    local ok, err = pcall(m_play, hud, fn, anim)
    h.miss, h.tries = nil, h.tries + 1
    if ok then
        if want then M.stats.shown = M.stats.shown + 1 else M.stats.hidden = M.stats.hidden + 1 end
        h.ours = want
    else
        M.stats.failed = M.stats.failed + 1
    end
    local line = en and edge_line or log.info   -- a switch turned off: a user's action, always logged
    line("infui: own infection bar %s -> %s(InfectionAnim) on the own HUD (ok=%s%s)%s; %s, the HUD differed for %.2f s",
        want and "shown" or "hidden", fn, tostring(ok), ok and "" or (" " .. tostring(err)),
        (want and type(c.pct) == "number") and (", percent " .. pct(c.pct)) or "",
        en and "it follows the host's MedicalComponent (INFUI)" or "client_infection_hud off here (the plate this module showed)", waited)
end

local function client_tick(now)
    local me = own_pawn()
    local pa = me and addr(me) or nil
    if pa ~= nil and pa ~= st.pawn then
        -- (pa == nil: the character is only missing for a moment, e.g. at death: nothing is forgotten)
        -- the own character went away (death, respawn): its infection with
        -- it. (No reset when the new one appears: an INFUI for it may already
        -- be here.) The plate state stays with its HUD.
        if st.pawn then
            if st.c.want then log.info("infui: own character replaced: the old one's infection state dropped") end
            st.c = new_client()
        end
        st.pawn = pa
    end
    if not enabled() and not st.h.ours then return end   -- switched off here: nothing of this module to hide
    if not me or ue.prop(me, "PlayerDead?") == true then return end
    local hud = ue.prop(me, "InGameUI")
    local ha = addr(hud)
    if not ha then return end
    if ha ~= st.hud then
        if st.hud and st.c.want then log.info("infui: own HUD replaced (%s): infection bar shown again", ue.short(hud)) end
        st.hud, st.h = ha, new_hud_state()
        st.c.pct_new = st.c.pct ~= nil   -- the new bar gets the percent again
    end
    reconcile(hud, now)
end

-- ===========================================================================
-- Driver (sdc_geiger)
-- ===========================================================================

-- Every 250 ms from sdc_geiger.tick while co-op is on (host with remote
-- players, or a client).
function M.tick(now)
    if not S then return end
    now = now or clock()
    if S.role == "host" then
        host_tick(now)
    elseif S.role == "client" then
        client_tick(now)    -- with the switch off too: the own character is followed, a plate shown here hidden
    end
end

function M.install(state)
    S = state
    -- host -> client: INFUI|<1/0>|<percent or "">
    net.on(MSG, function(f)
        local ok, err = pcall(on_msg, f)
        if not ok then log.err_throttled("infui.msg", "infui: INFUI: %s", tostring(err)) end
    end)
    log.info("infui: installed (client_infection_hud=%s): host: remote players' infection -> their screens; client: the own infection bar",
        tostring(enabled()))
end

-- World change: every cached address belongs to the old world.
function M.reset(why)
    st.recs, st.poll_at = {}, -100
    st.pawn, st.hud, st.c, st.h = nil, nil, new_client(), new_hud_state()
    log.debug("infui: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    local infected = 0
    for _, r in pairs(st.recs) do if r.sent == true then infected = infected + 1 end end
    return string.format("infui: enabled=%s | host: infection on=%d off=%d kept=%d infected now=%d | client: msgs=%d infection=%s bar shown=%d hidden=%d percent pushes=%d bar already right=%d gave up=%d failed=%d",
        tostring(enabled()), s.sent_on, s.sent_off, s.sent_keep, infected,
        s.got, st.c.want and ("on " .. pct(st.c.pct)) or "off", s.shown, s.hidden, s.pushed, s.bar_ok, s.gave_up, s.failed)
end

return M
