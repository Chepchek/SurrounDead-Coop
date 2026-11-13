-- SDCoop: a zone's "Now Entering <name>" banner and its warning on the
-- screen of every player who walks in (the Aurora observatory's "WARNING:
-- Mines in the area"), each on its own machine, once per visit.
--
-- The game (BP_EnterArea, /Game/Blueprints/Zones; work\re\pseudo_zones,
-- the level's instance read from extract_level\Levels\LongdownValley):
--   * a Sphere; BeginOverlap @2892 with any BP_PlayerCharacter ->
--     Event_EnteredArea(char) @3298; EndOverlap @3095 -> Event_ExitedArea
--     @3354; a 0.2 s poll @291-1143, armed 5 s after BeginPlay and again on
--     GameInstance.PlayerRespawned, runs the entry for every player character
--     inside and stops @650 only when it found one: the first visit after a
--     load gets a second entry call 0-0.2 s later (BeginOverlap does not stop
--     the poll).
--   * entry: a DoOnce @1148 - ONE gate for the whole zone, reopened only by
--     the exit's DoOnce @2148 - then char.GetController() ->
--     Cast<BP_MasterPlayerController> -> GetHUD -> Cast<HUD_Game> (a failed
--     cast ends the flow, the gate stays closed) -> HUD.ZoneAreaUI(true,
--     Name, None, white) @1734 ("Now Entering <Name>") -> with
--     AdditionalNotification?: GetGameHUD(self).Notification({Message, Icon,
--     Icon Colour, Delay 5, not forced}) @1815-2027 (straight to the HUD,
--     not through CreateNotificationUI: sdc_notes never sees it).
--   * exit: a DoOnce @2174, the same casts, ZoneAreaUI(false, Name) @2760
--     ("Now Leaving"), entry gate reopened - for whichever character left.
--     ("Now Entering" / "Now Leaving": ZoneAreaWidget @108 / @178.)
--   * LongdownValley has one: BP_EnterArea_C_1 (224086,26442,6744, radius
--     80 m): Name "The Observatory", "WARNING: Mines in the area", no icon,
--     red, 5 s. Its level data sets nothing of Actor's but the root and its
--     components (bNetLoadOnClient stays true): every client has its copy.
-- Single player: one character, the gate means "once per visit". Co-op:
-- every machine has every player's character and the first one in closes the
-- gate. Another player's character has no HUD on this machine (a client's
-- controller has none on the host; on a client another player's controller
-- does not exist), so nothing is shown and the gate stays closed until some
-- character leaves: the second player gets neither banner nor warning.
-- 2026-11-14: host and client walked into the observatory together, the
-- host's character first - only the host saw the mines warning.
-- The game can also show its banner a second time in one visit: another
-- character's exit reopens the entry gate, and the poll after a respawn runs
-- the entry again. "Once per visit" below is about the mod's own shows only.
-- The other zones are not affected: BP_EnterSafeZone (traders, safe zones)
-- checks the HUD before its gate; BP_RadiationArea_Sphere (the same banner
-- and notice code: "Increased Radiation [Level 1]" ...), BP_EnterSkyModifer
-- and BP_EnterTeleporterAreaTutorial react only to GetPlayerCharacter(0),
-- this machine's own player.
--
-- Here (host and client, each for its own character only, in co-op):
--   Event_EnteredArea (post) for this machine's own character, its first
--   since it went in -> unless the game showed it in this very call (the
--   HUD_Game.ZoneAreaUI(true, this zone's Name) post-hook ran inside it: the
--   record is dropped after every entry / exit call and every tick, never
--   judged by time) the mod does what the zone does: ZoneAreaUI(true, Name,
--   None, white) on this HUD and, with AdditionalNotification?, the zone's
--   own notification (text, icon, colour, 5 s, not forced) through the
--   game's CreateNotificationUI (sdc_notes.show_here). No game HUD yet: the
--   visit is not counted (the zone's next entry call tries again).
--   Event_ExitedArea (post) for the own character after an entry -> "Now
--   Leaving" the same way when the game did not show it (another character's
--   exit used the exit's gate).
--   Another player's character: nothing (its own machine shows that player).
-- A visit is the zone's address with the own character's address and name
-- (a new character, even at a freed one's address, is a new visit). The own
-- character's visits are tracked in single player too (no screen change
-- there), so a late co-op start does not repeat a visit.
-- Hooks that come in late (the first world of a game session: HUD_Game and
-- BP_EnterArea load with it), or a world reset that came after the new world
-- (sdc_session's "new controller" fallback): the zones the own character
-- stands in then count as visited, shown by the game (otherwise the zone's
-- poll would make the mod repeat the banner). Known limit: if the game had
-- skipped that visit (another character in first, no HUD yet), it stays
-- without the banner until the player leaves and comes back.
-- Hooks: post only, wrapped in pcall, return nothing; no engine object is
-- kept between calls (addresses and texts only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local notes = require("sdc_notes")

local M = {
    stats = { game = 0, shown = 0, left = 0, others = 0, again = 0, failed = 0, no_hud = 0, found = 0 },
}

local ZONE_CLASS = "BP_EnterArea_C"
local ZONE = "/Game/Blueprints/Zones/BP_EnterArea." .. ZONE_CLASS
local P = {
    enter = ZONE .. ":Event_EnteredArea",
    exit = ZONE .. ":Event_ExitedArea",
    ui = "/Game/Blueprints/HUD_Game.HUD_Game_C:ZoneAreaUI",
}
M.PATHS = P
local NOTE_DELAY = 5        -- BP_EnterArea @1971
local HOOK_RETRY_S = 2
local RESCAN_TRIES = 5      -- ticks a pending "where is the own character" pass waits for one
local WHITE = { R = 1, G = 1, B = 1, A = 1 }   -- BP_EnterArea @1734 / @2760

local S = nil
local st = {
    hooks = {}, hook_at = -100, hook_logged = {},
    inside = {},    -- [zone address] = own character's key (address|name): went in, no exit since
    ui = nil,       -- the game's ZoneAreaUI inside the entry / exit call being run: { entering, name }
    rescan = 0,     -- ticks left to mark the zones the own character stands in (late hooks / late world reset)
}
M._st = st

local clock = os.clock
local function coop()
    local r = S and S.role or nil
    return r == "host" or r == "client"
end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function addr(o)
    if not ue.valid(o) then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and type(a) == "number" and a ~= 0 then return a end
    return nil
end

-- "address|name" when the character is this machine's own player's (the
-- controller's pawn; while that is a vehicle, the locally controlled one)
local function own(ch)
    local a = addr(ch)
    if not a then return nil end
    local mine = ue.local_pawn()
    local is = mine ~= nil and addr(mine) == a
    if not is then
        local ok, loc = pcall(function() return ch:IsLocallyControlled() end)
        is = ok and loc == true
    end
    if not is then return nil end
    return tostring(a) .. "|" .. ue.short(ch)
end

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

-- The zone's texts as this machine's game has them (its language).
local function zone_info(z)
    local i = { label = ue.short(z), name = ue.fstring(ue.prop(z, "Name")), extra = false, msg = "", icon = "",
                col = WHITE }
    if ue.prop(z, "AdditionalNotification?") == true then
        i.msg = ue.fstring(ue.prop(z, "Notification Details Message"))
        i.extra = i.msg ~= "" and not ue.is_wrapper_text(i.msg)
        local icon = ue.prop(z, "Notification Details Icon")
        if ue.valid(icon) then
            local p = ue.path(icon)
            if p:sub(1, 1) == "/" then i.icon = p end
        end
        i.col = colour_of(ue.prop(z, "Notification Details Icon Colour"))
    end
    return i
end

-- did the game itself call ZoneAreaUI(entering, name) on this HUD inside the
-- entry / exit call being run?
local function game_showed(entering, name)
    local u = st.ui
    return u ~= nil and u.entering == entering and u.name == name
end

-- this screen's HUD_Game, or nil
local function game_hud()
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    if ue.valid(hud) and ue.class_name(hud):find("HUD_Game", 1, true) then return hud end
    return nil
end

-- HUD_Game.ZoneAreaUI(Entering?, Area Name, Texture, Color), as the zone calls it
local function banner(hud, entering, name)
    local ok, err = pcall(function() hud:ZoneAreaUI(entering, FText(name), nil, WHITE) end)
    if not ok then log.err_throttled("zones.banner", "zones: ZoneAreaUI failed: %s", tostring(err)) end
    return ok
end

-- Late hooks / late world reset: the zones the own character stands in now
-- count as visited (the game ran their entry before the mod could see it).
-- false while there is no own character yet.
local function mark_where_standing()
    local pawn = ue.local_pawn()
    local key = pawn and own(pawn)
    if not key or not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return false end
    for _, z in ipairs(ue.find_all(ZONE_CLASS)) do
        local za = addr(z)
        local sphere = za and ue.prop(z, "Sphere")
        if za and st.inside[za] ~= key and ue.valid(sphere) then
            local ok, isin = pcall(function() return sphere:IsOverlappingActor(pawn) end)
            if ok and isin == true then
                st.inside[za] = key
                M.stats.found = M.stats.found + 1
                log.info("zones: own character already inside %s '%s' when the mod started watching it: that visit "
                    .. "counts as shown by the game", ue.short(z), ue.fstring(ue.prop(z, "Name")))
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- HUD_Game_C.ZoneAreaUI (post): what this screen's game showed.
local function on_zone_ui(_, entering_p, name_p)
    st.ui = { entering = pget(entering_p) == true, name = ue.fstring(name_p) }
end

-- BP_EnterArea_C.Event_EnteredArea(Actor) (post)
local function on_enter(c, actor_p)
    local zone = pget(c)
    local za = addr(zone)
    if not za then return end
    local ch = pget(actor_p)
    local key = own(ch)
    if not key then
        if ue.valid(ch) and coop() then
            M.stats.others = M.stats.others + 1
            log.debug("zones: %s: another player's character %s went in here (that player's own machine shows it the zone)",
                ue.short(zone), ue.short(ch))
        end
        return
    end
    if st.inside[za] == key then
        M.stats.again = M.stats.again + 1   -- the zone's poll / a second overlap: once per visit
        return
    end
    local z = zone_info(zone)
    if game_showed(true, z.name) then
        st.inside[za] = key
        M.stats.game = M.stats.game + 1
        log.debug("zones: own character went into %s '%s': the game showed it", z.label, z.name)
        return
    end
    if not coop() then
        st.inside[za] = key
        return
    end
    -- the zone's once-per-visit gate was closed by another player's character
    local hud = game_hud()
    if not hud then
        M.stats.no_hud = M.stats.no_hud + 1
        log.debug("zones: own character went into %s '%s', the zone showed nothing and there is no game HUD here yet: "
            .. "not counted (its next entry call tries again)", z.label, z.name)
        return
    end
    st.inside[za] = key
    local okb = banner(hud, true, z.name)
    local okn = z.extra and notes.show_here(z.msg, z.icon, z.col, NOTE_DELAY, "zone " .. z.label) or false
    if okb or okn then M.stats.shown = M.stats.shown + 1 else M.stats.failed = M.stats.failed + 1 end
    log.info("zones: own character went into %s '%s' but the zone showed nothing here (another player's character "
        .. "went in first and closed its once-per-visit gate): banner %s, notice %s", z.label, z.name,
        okb and "shown" or "FAILED",
        z.extra and string.format("'%s' %s", z.msg, okn and "shown" or "FAILED") or "none (the zone has none)")
end

-- BP_EnterArea_C.Event_ExitedArea(Actor) (post)
local function on_exit(c, actor_p)
    local zone = pget(c)
    local za = addr(zone)
    if not za then return end
    local key = own(pget(actor_p))
    if not key or st.inside[za] ~= key then return end
    st.inside[za] = nil
    local name = ue.fstring(ue.prop(zone, "Name"))
    if game_showed(false, name) or not coop() then return end
    local hud = game_hud()
    local ok = hud ~= nil and banner(hud, false, name)
    if ok then M.stats.left = M.stats.left + 1 end
    log.info("zones: own character left %s '%s' but the zone showed nothing here (another character's exit closed its "
        .. "exit gate): 'Now Leaving' %s", ue.short(zone), name, ok and "shown" or "NOT shown (no game HUD)")
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("zones." .. name, "zones: %s hook: %s", name, tostring(err)) end
    end
end

-- an entry / exit call: the game's ZoneAreaUI inside it (if any) belonged to
-- this call only
local function zone_event(name, fn)
    local f = safe(name, fn)
    return function(...)
        f(...)
        st.ui = nil
    end
end

local HOOKS = {
    { P.ui, safe("ui", on_zone_ui), "ui" },
    { P.enter, zone_event("enter", on_enter), "enter" },
    { P.exit, zone_event("exit", on_exit), "exit" },
}

-- Blueprint functions exist once their class is loaded (HUD_Game with the
-- HUD, BP_EnterArea with the map): tried again every HOOK_RETRY_S. The zone
-- hooks go in only after the HUD's: an entry is never judged without it.
function M.try_hooks(force)
    local now = clock()
    if not force and now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    for _, h in ipairs(HOOKS) do
        if not st.hooks[h[3]] and (h[3] == "ui" or st.hooks.ui) and ue.find_object(h[1]) then
            local ok, err = pcall(RegisterHook, h[1], h[2])
            st.hooks[h[3]] = ok
            if ok then
                log.info("zones: hook %s ok", h[1]:match("([%w_]+:[%w_]+)$") or h[1])
                if h[3] == "enter" then st.rescan = RESCAN_TRIES end
            elseif not st.hook_logged[h[3]] then
                st.hook_logged[h[3]] = true
                log.warn("zones: cannot hook %s: %s", h[1], tostring(err))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Install / tick / reset
-- ---------------------------------------------------------------------------

-- A world reset: before the new world (LoadMap) every visit there is seen;
-- after it (the "new controller" fallback) the own character may be in a
-- zone already.
function M.reset(why)
    st.inside, st.ui = {}, nil
    st.rescan = tostring(why or ""):find("loadmap", 1, true) and 0 or RESCAN_TRIES
    log.debug("zones: state dropped (%s)", tostring(why or "?"))
end

-- 1 s tick (main.lua): hooks, a pending look at where the own character
-- stands. (UE4SS runs it from its EngineTick pre-hook, UE4SS-settings
-- DefaultExecuteInGameThreadMethod = EngineTick: never inside a zone's call.)
function M.tick()
    st.ui = nil   -- a ZoneAreaUI outside any entry / exit call: nothing to judge by it
    M.try_hooks(false)
    if st.rescan > 0 and st.hooks.enter then
        st.rescan = mark_where_standing() and 0 or st.rescan - 1
    end
end

function M.status_line()
    local s = M.stats
    return string.format("zones game=%d shown=%d left=%d failed=%d no_hud=%d found=%d others=%d again=%d hooks=%s%s%s",
        s.game, s.shown, s.left, s.failed, s.no_hud, s.found, s.others, s.again,
        st.hooks.ui and "ui+" or "ui-", st.hooks.enter and ",enter+" or ",enter-", st.hooks.exit and ",exit+" or ",exit-")
end

local installed = false
function M.install(state)
    S = state or S
    if installed then return end
    installed = true
    local session = package.loaded["sdc_session"]
    if session and session.world_reset_hooks then
        session.world_reset_hooks.zones = function(why) M.reset("world:" .. tostring(why)) end
    end
    M.try_hooks(true)
    log.info("zones: installed (zone entry banner and warning for every player who enters, on its own screen)")
end

-- tests
M._t = { on_enter = on_enter, on_exit = on_exit, on_zone_ui = on_zone_ui, set_state = function(s) S = s end }

return M
