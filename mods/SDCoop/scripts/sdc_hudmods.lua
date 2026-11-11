-- SDCoop: the HUD's equipment status icons (an icon with a percent above the
-- hunger / thirst / radiation circles) on a client's screen, as the host has
-- them on its own.
--
-- The game (work\re\pseudo\BP_Ingame.txt, the HUD widget; json\BP_Ingame.json
-- for the animations): three Borders, each an icon + a text -
-- RespiratorDur / RespiratorText (gas mask filter), FlashlightDur /
-- FlashlightText (handheld flashlight battery), NightVisionDur /
-- NightVisionText (NVG battery). All start at RenderOpacity 0. The HUD
-- implements BPI_UI:
--   Show<X>Durability(Show?) -> PlayAnimationForward / Reverse(Show<X>Dur),
--                               a short RenderOpacity 0 -> 1 fade;
--   Get<X>Durability(Dur)    -> <X>Text = Format("{A}%", Dur as an integer).
-- Callers - the only ones (a name-map search of every asset under
-- Blueprints, Inventory/Items/LocalAttachments, Inventory/Items/Pickups/
-- Equipment, JigSInventory and UI/Widgets):
--   * respirator: RadiationComponent.RadiationTimer, set by the zone's
--     UpdateRadiation (a Server RPC: it runs on the HOST) -> GetRespirator
--     (any item in the Facewear slot) -> SetFilterUI(true) (a DoOnce @558)
--     -> GetPlayerCharacter(self, 0).GetInGameUI().ShowRespiratorDurability
--     (true); UseFilter -> ServerFuncUpdateDurabilityByUID ->
--     GetRespiratorDurability(NewDur). Off: SetFilterUI(false) from
--     StopRadiation (the zone's exit, on the player's own machine) and
--     IncreaseRadiation at the maximum (pills).
--   * handheld flashlight: BP_PlayerCharacter.FlashlightToggle(true) (from
--     MC_Flashlight) -> BatteryComponent.CheckBatteryLevel -> light +
--     self.InGameUI.ShowFlashlightDurability(true); the 0.1 s timer
--     Battery_Flashlight -> UseBattery -> GetFlashlightDurability(NewDur);
--     off (key, battery empty -> MC_Flashlight(false)) -> Show(false).
--     Icon on <=> the own light lit.
--   * night vision (the NVG module on the headwear): NightVisionOn(true) ->
--     NightVisionBatteryCheck -> ShowNightVisionDurability(true) +
--     PlayerUsingNightVision?; NightVisionCheck -> GetNightVisionDurability.
--   * weapon modules (BP_TacticalLight / SmallTacticalLight /
--     TacticalLaserLightCombo / SmallTacticalLaserSight LocalAttachment):
--     their BatteryComponent drains, but they call no HUD function: there is
--     no icon for them in single player either, nothing to mirror.
-- On a client:
--   * respirator: never. The timer runs on the host; there player 0 is the
--     client's character (sdc_ctx), which has no HUD on the host: the call
--     went nowhere, and nothing ever reached the client's own HUD.
--   * flashlight / NVG: the game's own path runs on the client's machine
--     (its battery checks answered from the host's data: sdc_items,
--     sdc_tools). A call it missed (the HUD not there yet - Client_AddUI
--     comes late, sdc_players.ensure_hud -, a check that failed once, a lost
--     unreliable MC_Flashlight) left the icon off for good.
-- Here:
--   host:   RadiationComponent.SetFilterUI(Show?) (post) of another player's
--           character -> RESPUI|<1/0>|<filter> to that player when it changes
--           (and every KEEP_S while on); UseFilter's NewDur (sdc_geiger's
--           UseFilter hook calls M.host_filter_used) -> RESPUI|1|<filter>
--           when the shown percent changes (at most every PCT_EVERY_S for a
--           smaller change).
--   client: RESPUI -> the respirator state; every tick the own HUD is
--           compared with what single player shows: respirator = the host's
--           state, flashlight = the own light lit (FlashlightOn? and its
--           Intensity > 0), NVG = PlayerUsingNightVision?. A difference that
--           lasts GRACE_S (the game's own call and its fade come first) is
--           fixed with the game's own Show<X>Durability on the own HUD; the
--           percent (respirator: the host's filter; flashlight: the host's
--           battery charge from ITEMS, sdc_items) goes in with
--           Get<X>Durability when it changes (the NVG percent: sdc_tools).
--           The own SetFilterUI(false) (zone exit here) hid the icon itself:
--           a host "on" within LOCAL_OFF_GUARD_S after it is ignored.
--   The host's own HUD is never touched.
-- Config: client_gear_hud. Driven by sdc_geiger (install / tick / reset /
-- status line; the UseFilter hook is sdc_geiger's).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = {
    stats = {
        -- host: RESPUI sent
        sent_on = 0, sent_off = 0, sent_pct = 0, sent_keep = 0,
        -- client
        got = 0, shown = 0, hidden = 0, pushed = 0, local_off = 0, ignored_on = 0, failed = 0,
    },
}

local RAD_FN = "/Game/Blueprints/Components/RadiationComponent.RadiationComponent_C:"
local MSG = "RESPUI"
local FLASHLIGHT_SLOT = "Jig.PlayerSlot.Flashlight"
local FACEWEAR_SLOT = "Jig.PlayerSlot.Facewear"

local HOOK_RETRY_S = 2       -- s: the hook waits for RadiationComponent_C
local OWNER_TTL = 2          -- s: host: "whose component" is read again after this
local KEEP_S = 10            -- s: host: "on" again this often while on
local PCT_EVERY_S = 5        -- s: host: a change within the same whole percent at most this often
local GRACE_S = 1.0          -- s: a wrong icon state must last this long before it is fixed
local LOCAL_OFF_GUARD_S = 3  -- s: client: a host "on" this soon after the own zone exit is ignored
local PUSH_EVERY_S = 5       -- s: client: the percent again this often while shown
local SUMMARY_S = 60         -- s: host: percent updates summed up per player
local SHOWN_AT = 0.5         -- RenderOpacity from which an icon counts as shown
local EDGE_LINES = 10        -- info lines per kind for switch reports (then debug)

-- The HUD's icons (BP_Ingame widgets / BPI_UI events). `grace`: how long a
-- wrong icon state lasts before it is fixed - the flashlight / NVG icon is
-- the game's own call on this machine (and its fade); the respirator's "on"
-- never comes here (`grace_on`: the next tick), its "off" does (the zone's
-- exit here: the reverse fade first). `src`: whose state the icon follows
-- (log lines).
local KINDS = {
    { key = "respirator", border = "RespiratorDur", show = "ShowRespiratorDurability", set = "GetRespiratorDurability",
      grace = GRACE_S, grace_on = 0.25, src = "the host's radiation timer (the game calls it only there)" },
    { key = "flashlight", border = "FlashlightDur", show = "ShowFlashlightDurability", set = "GetFlashlightDurability",
      grace = GRACE_S, src = "the own light (the game's own call did not come)" },
    -- the percent: sdc_tools (the host's NVG battery, every second while on)
    { key = "nightvision", border = "NightVisionDur", show = "ShowNightVisionDurability",
      grace = GRACE_S, src = "PlayerUsingNightVision? (the game's own call did not come)" },
}

local S
local function new_resp() return { show = false, dur = nil, at = nil, off_at = nil } end
local st = {
    hooked = false, hook_at = -100,
    -- host: [component address] = { pc, who, checked, show, dur, sent_show, sent_dur, sent_at, pct_at, n, t0 }
    comps = {}, prune_at = 0,
    -- client
    pawn = nil, hud = nil,     -- addresses of the own character / its HUD
    resp = new_resp(),         -- the host's respirator icon state for the own character
    k = {},                    -- [kind key] = per-icon state on the current HUD
    items = nil,               -- sdc_items (required on first use)
    logged = {},
}

-- ---------------------------------------------------------------------------
-- helpers (the host's SetFilterUI hook runs with every RadiationTimer tick:
-- no closure per call)
-- ---------------------------------------------------------------------------
local clock = os.clock
local function m_addr(o) return o:GetAddress() end
local function m_owner(o) return o:GetOwner() end
local function m_get(p) return p:get() end
local function m_local(p) return p:IsLocallyControlled() end
local function call_hud(hud, fn, v) hud[fn](hud, v) end

local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(m_addr, o)
    if ok and a ~= nil and a ~= 0 then return a end
    return nil
end

local function param(p)
    if p == nil then return nil end
    local ok, v = pcall(m_get, p)
    if ok then return v end
    return nil
end

local function owner_of(comp)
    local ok, o = pcall(m_owner, comp)
    if ok then return o end
    return nil
end

local function locally_controlled(p)
    local ok, v = pcall(m_local, p)
    return ok and v == true
end

local function is_player(o)
    return ue.valid(o) and ue.class_name(o):find("PlayerCharacter", 1, true) ~= nil
end

local function enabled() return cfg.get("client_gear_hud") ~= false end

local function once(key, fmt, ...)
    if st.logged[key] then return end
    st.logged[key] = true
    log.info(fmt, ...)
end

local function pct(v)
    if type(v) == "number" then return string.format("%.2f", v) end
    return "not known yet"
end

-- ===========================================================================
-- Host
-- ===========================================================================

-- The remote controller whose character this is (nil: the host's own, a
-- body nobody controls, not a player's).
local function pc_of(pawn)
    local pa = addr(pawn)
    if not pa or not S then return nil end
    for _, pc in ipairs(S.remote_pcs or {}) do
        if addr(ue.pawn_of(pc)) == pa then return pc end
    end
    return nil
end

-- "BP_PlayerCharacter_C_123 (Name)"
local function who(pawn, pc)
    local r = pc and S and S.remote and S.remote[ue.name(pc)] or nil
    return string.format("%s (%s)", ue.short(pawn), r and tostring(r.name) or "?")
end

-- The record of a RadiationComponent: its player's controller in .pc (nil =
-- not another player's: nothing to send).
local function host_rec(comp, a, now)
    local r = st.comps[a]
    if r and now - r.checked < OWNER_TTL then return r end
    if not r then
        r = { n = 0, t0 = now, sent_at = -100, pct_at = -100 }
        st.comps[a] = r
    end
    local owner = owner_of(comp)
    local pc = nil
    if is_player(owner) and not locally_controlled(owner) then pc = pc_of(owner) end
    r.checked, r.pc = now, pc
    if pc and not r.who then r.who = who(owner, pc) end
    return r
end

local function whole(v) return math.floor(v + 0.5) end

-- RESPUI|<show: 1 / 0 / "" unknown>|<filter: number / "" unknown>
local function send(r, now, why)
    local show_s = r.show == nil and "" or (r.show and "1" or "0")
    local dur_s = type(r.dur) == "number" and string.format("%.2f", r.dur) or ""
    if not net.send_to(r.pc, MSG, show_s, dur_s) then return end
    local s = M.stats
    if why == "on" or why == "off" then
        if why == "on" then s.sent_on = s.sent_on + 1 else s.sent_off = s.sent_off + 1 end
        log.info("hudmods: respirator icon of %s turned %s by the host's copy (RadiationComponent.SetFilterUI %s) -> RESPUI to its screen, filter %s",
            tostring(r.who), why, why == "on" and "true" or "false", pct(r.dur))
    elseif why == "keep" then
        s.sent_keep = s.sent_keep + 1
    else
        s.sent_pct = s.sent_pct + 1
        r.n = r.n + 1
        if r.n == 1 then
            log.info("hudmods: respirator filter of %s -> its screen: %s (RadiationTimer -> UseFilter on the host)", tostring(r.who), pct(r.dur))
        elseif now - r.t0 >= SUMMARY_S then
            log.info("hudmods: respirator filter of %s -> its screen: %d update(s) in %.0f s, now %s",
                tostring(r.who), r.n - 1, now - r.t0, pct(r.dur))
            r.n, r.t0 = 1, now
        end
    end
    if r.show ~= nil then r.sent_show = r.show end
    if type(r.dur) == "number" then r.sent_dur = r.dur end
    r.sent_at = now
    if why ~= "keep" then r.pct_at = now end
end

-- Host: RadiationComponent.SetFilterUI(Show?) ran for another player's
-- character (its RadiationTimer here; StopRadiation / pills: off).
local function host_filter_ui(comp, a, show, now)
    local r = host_rec(comp, a, now)
    if not r.pc then return end
    r.show = show
    if show and r.sent_show ~= true then
        send(r, now, "on")
    elseif not show and r.sent_show == true then
        -- (an exit without the icon ever on - no mask - sends nothing)
        send(r, now, "off")
    elseif show and now - r.sent_at >= KEEP_S then
        send(r, now, "keep")
    end
end

-- Host, from sdc_geiger's UseFilter post-hook (another player's character,
-- the filter's durability after the use): the percent its HUD would show.
function M.host_filter_used(comp, a, dur)
    if not S or S.role ~= "host" or type(dur) ~= "number" or not enabled() then return end
    a = a or addr(comp)
    if not a then return end
    local now = clock()
    local r = host_rec(comp, a, now)
    if not r.pc then return end
    r.dur = dur
    if r.show == nil then r.show = true end   -- RadiationTimer: SetFilterUI(true) came first (hook missing?)
    local last = r.sent_dur
    if last == nil or whole(dur) ~= whole(last) or (dur ~= last and now - r.pct_at >= PCT_EVERY_S)
        or (dur <= 0 and last > 0) then
        send(r, now, "pct")
    end
end

local function host_prune(now)
    if now - st.prune_at < 10 then return end
    st.prune_at = now
    for a, r in pairs(st.comps) do
        if now - math.max(r.sent_at, r.checked) > 60 then st.comps[a] = nil end
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

-- Client: the own component's SetFilterUI(false) ran here (StopRadiation at
-- the zone's exit, pills): the game hid the icon itself.
local function client_filter_ui(comp, show, now)
    if show then return end
    local me = own_pawn()
    if not me or addr(owner_of(comp)) ~= addr(me) then return end
    M.stats.local_off = M.stats.local_off + 1
    local was = st.resp.show
    st.resp.show, st.resp.off_at = false, now
    if was or M.stats.local_off <= 3 then
        log.info("hudmods: own respirator icon hidden by the game here (SetFilterUI false: zone exit / pills); a host 'on' within %d s is ignored",
            LOCAL_OFF_GUARD_S)
    end
end

-- RadiationComponent.SetFilterUI(Show?) post-hook, both roles.
local function on_set_filter_ui(c, show_p)
    if not S or not enabled() then return end
    local comp = c and param(c)
    local a = addr(comp)
    if not a then return end
    local show = param(show_p) == true
    local now = clock()
    if S.role == "host" then
        host_filter_ui(comp, a, show, now)
    elseif S.role == "client" then
        client_filter_ui(comp, show, now)
    end
end

-- net RESPUI (host -> client): the host's respirator icon for the own character.
local function on_msg(f)
    if not S or S.role ~= "client" or not enabled() then return end
    M.stats.got = M.stats.got + 1
    local now = clock()
    local show, dur = f[1], tonumber(f[2])
    if dur then st.resp.dur = dur end
    st.resp.at = now
    if show == "1" then
        local off = st.resp.off_at
        if off and now - off < LOCAL_OFF_GUARD_S then
            M.stats.ignored_on = M.stats.ignored_on + 1
            log.debug("hudmods: host's respirator 'on' ignored: the own zone exit was %.1f s ago", now - off)
            return
        end
        if not st.resp.show then
            log.info("hudmods: host: its radiation timer uses the own respirator -> respirator icon on (filter %s)", pct(st.resp.dur))
        end
        st.resp.show = true
    elseif show == "0" then
        if st.resp.show then log.info("hudmods: host: its radiation timer stopped using the own respirator -> respirator icon off") end
        st.resp.show = false
    end
end

local function items_mod()
    if st.items == nil then
        local ok, m = pcall(require, "sdc_items")
        st.items = ok and type(m) == "table" and m or false
        if not st.items then log.warn("hudmods: sdc_items not available (%s): no battery / filter percent from ITEMS", tostring(m)) end
    end
    return st.items or nil
end

-- The host's battery / filter charge of the item in an own equipment slot
-- (sdc_items: UIDS + ITEMS), or nil.
local function slot_charge(tag)
    local items = items_mod()
    if not items or not items.own_slot_uid or not items.reported then return nil, nil end
    local okU, uid = pcall(items.own_slot_uid, tag)
    if not okU or not uid then return nil, nil end
    local okR, _, bat = pcall(items.reported, uid)
    if okR and type(bat) == "number" then return bat, uid end
    return nil, uid
end

local function light_lit(me)
    local i = tonumber(ue.prop(ue.prop(me, "Flashlight"), "Intensity"))
    return i ~= nil and i > 0
end

-- What single player would show for this icon now, and its percent.
local function wanted(kind, me)
    if kind.key == "respirator" then
        if not st.resp.show then return false, nil end
        local v = st.resp.dur
        if v == nil then v = slot_charge(FACEWEAR_SLOT) end   -- ITEMS: the filter in the mask
        return true, v
    elseif kind.key == "flashlight" then
        if ue.prop(me, "FlashlightOn?") ~= true or not light_lit(me) then return false, nil end
        local v, uid = slot_charge(FLASHLIGHT_SLOT)
        if v == nil then
            once("fl-nocharge-" .. tostring(uid), "hudmods: own flashlight lit but the host reported no battery charge for it (slot uid %s): the icon keeps the game's percent",
                tostring(uid))
        end
        return true, v
    end
    return ue.prop(me, "PlayerUsingNightVision?") == true, nil
end

local function edge_line(k, fmt, ...)
    k.lines = (k.lines or 0) + 1
    if k.lines <= EDGE_LINES then log.info(fmt, ...) else log.debug(fmt, ...) end
end

local function reconcile(kind, me, hud, now)
    local k = st.k[kind.key]
    if not k then
        k = { want = false, miss = nil, report_at = nil, pushed = nil, pushed_at = -100, lines = 0 }
        st.k[kind.key] = k
    end
    local want, value = wanted(kind, me)
    local op = tonumber(ue.prop(ue.prop(hud, kind.border), "RenderOpacity"))
    if op == nil then
        once("noop-" .. kind.key, "hudmods: cannot read %s.RenderOpacity on the own HUD %s: %s icon not checked",
            kind.border, ue.short(hud), kind.key)
        return
    end
    local shown = op >= SHOWN_AT
    local grace = want and kind.grace_on or kind.grace
    if want ~= k.want then
        k.want, k.report_at = want, now + grace
        if not want then k.pushed = nil end
    end
    if want ~= shown then
        k.miss = k.miss or now
        if now - k.miss >= grace then
            local ok, err = pcall(call_hud, hud, kind.show, want)
            k.miss, k.report_at = nil, nil
            if ok then
                if want then M.stats.shown = M.stats.shown + 1 else M.stats.hidden = M.stats.hidden + 1 end
                k.pushed = nil   -- the percent goes in right after
            else
                M.stats.failed = M.stats.failed + 1
            end
            edge_line(k, "hudmods: own %s icon %s -> %s(%s) on the own HUD (ok=%s%s)%s; it follows %s, the HUD differed for %.2f s",
                kind.key, want and "on" or "off", kind.show, tostring(want), tostring(ok), ok and "" or (" " .. tostring(err)),
                (want and type(value) == "number") and (", percent " .. pct(value)) or "", kind.src, grace)
        end
    else
        k.miss = nil
        if k.report_at and now >= k.report_at then
            k.report_at = nil
            edge_line(k, "hudmods: own %s %s: the game's own HUD call did it (icon %s)%s", kind.key,
                want and "in use" or "no longer in use", want and "shown" or "hidden",
                (want and type(value) == "number") and (", percent " .. pct(value)) or "")
        end
    end
    if want and kind.set and type(value) == "number" then
        if k.pushed == nil or math.abs(value - k.pushed) >= 0.05 or now - k.pushed_at >= PUSH_EVERY_S then
            local ok, err = pcall(call_hud, hud, kind.set, value)
            if ok then
                local first = k.pushed == nil
                k.pushed, k.pushed_at = value, now
                M.stats.pushed = M.stats.pushed + 1
                if first then log.debug("hudmods: own %s percent on the HUD: %s (%s)", kind.key, pct(value), kind.set) end
            else
                M.stats.failed = M.stats.failed + 1
                log.err_throttled("hudmods.set-" .. kind.key, "hudmods: %s(%s) on the own HUD failed: %s", kind.set, pct(value), tostring(err))
            end
        end
    end
end

local function client_tick(now)
    local me = own_pawn()
    local pa = me and addr(me) or nil
    if pa ~= st.pawn then
        -- the own character went away (death, respawn): the host's timer of
        -- it is gone; a new HUD starts with every icon hidden. (No reset when
        -- the new one appears: a RESPUI for it may already be here.)
        if st.pawn then
            if st.resp.show then
                log.info("hudmods: own character replaced: respirator icon state of the old one dropped")
            end
            st.resp = new_resp()
        end
        st.pawn, st.hud, st.k = pa, nil, {}
    end
    if not me or ue.prop(me, "PlayerDead?") == true then return end
    local hud = ue.prop(me, "InGameUI")
    local ha = addr(hud)
    if not ha then return end
    if ha ~= st.hud then
        if st.hud then log.info("hudmods: own HUD replaced (%s): icons checked again", ue.short(hud)) end
        st.hud, st.k = ha, {}
    end
    for _, kind in ipairs(KINDS) do reconcile(kind, me, hud, now) end
end

-- ===========================================================================
-- Driver (sdc_geiger)
-- ===========================================================================

local function try_hook(now)
    if st.hooked or now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    -- the Blueprint hook fails quietly until RadiationComponent_C is loaded
    local ok = pcall(RegisterHook, RAD_FN .. "SetFilterUI", function(c, show_p)
        local okc, e = pcall(on_set_filter_ui, c, show_p)
        if not okc then log.err_throttled("hudmods.filterui", "hudmods: SetFilterUI hook: %s", tostring(e)) end
    end)
    if ok then
        st.hooked = true
        log.info("hudmods: SetFilterUI hook ok (host: other players' respirator icon goes to their screens; client: own zone exits) - client_gear_hud=%s",
            tostring(enabled()))
    end
end

-- Every 250 ms from sdc_geiger.tick while co-op is on (host with remote
-- players, or a client).
function M.tick(now)
    if not S then return end
    now = now or clock()
    try_hook(now)
    if S.role == "host" then
        host_prune(now)
    elseif S.role == "client" and enabled() then
        client_tick(now)
    end
end

function M.install(state)
    S = state
    -- host -> client: RESPUI|<1/0/"">|<filter durability or "">
    net.on(MSG, function(f)
        local ok, err = pcall(on_msg, f)
        if not ok then log.err_throttled("hudmods.msg", "hudmods: RESPUI: %s", tostring(err)) end
    end)
end

-- World change: every cached address belongs to the old world.
function M.reset(why)
    st.comps = {}
    st.pawn, st.hud, st.k, st.resp = nil, nil, {}, new_resp()
    log.debug("hudmods: reset (%s)", tostring(why))
end

function M.status_line()
    local s = M.stats
    return string.format("hudmods: hook=%s enabled=%s | host: respirator on=%d off=%d percent=%d kept=%d | client: msgs=%d respirator=%s icons shown=%d hidden=%d percent pushes=%d own zone exits=%d ons ignored=%d failed=%d",
        tostring(st.hooked), tostring(enabled()), s.sent_on, s.sent_off, s.sent_pct, s.sent_keep,
        s.got, st.resp.show and ("on " .. pct(st.resp.dur)) or "off", s.shown, s.hidden, s.pushed,
        s.local_off, s.ignored_on, s.failed)
end

return M
