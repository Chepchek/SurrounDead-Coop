-- SDCoop: other players' names and GPS markers, shown with the game's own UI.
--
-- NAMES. SurrounDead shows a civilian's name with a screen-space
-- WidgetComponent ("NameWidget" of BP_RandomCivilian: widget class
-- BP_InteractWidgetCivilian, attached to the capsule at (5, 0, 105), hidden,
-- no collision, drawn at desired size). The player's interaction trace
-- (BP_JigHelperComp.TraceToWorld, every 0.4 s) calls OnBeginInteract on the
-- civilian, which makes that component visible; OnEndInteract hides it again.
-- A player character answers JigCanInteract = false and its interaction
-- events are empty, so the trace never reaches another player. Making
-- JigCanInteract true for players is not safe: BP_JigComponent asks the same
-- function before moving items between containers, and TryInteract would
-- send OnExecuteInteract to the other player's character. So the same
-- component with the same widget is added here to other players' characters
-- and shown the same way, driven by a look-at check of our own (camera ray,
-- distance, AController.LineOfSightTo) instead of the interaction trace.
--
-- COMPASS / GPS MARKERS. Every other player gets a local BP_CompassMarker_C
-- (gps_compass): the game's Compass widget collects every such actor by
-- itself and is visible only while the viewer wears a compass. Players WITH a
-- GPS are also put on the big map (gps_markers): BPC_MinimapSystem."Add
-- Standard Marker" puts a W_StandardMarker into MapWidget.StandardMarkerOverlay;
-- the map's Tick moves every marker to its "Target Actor" (that compass
-- marker actor) each frame, and ToggleMap shows the overlay only while the
-- VIEWER has a GPS, as for the game's own markers. The actor is attached to
-- the player's mesh while that character exists on this machine; characters
-- replicate only within 150 m, so for players farther away a client moves it
-- to positions the host relays.
--
-- OWN COMPASS / GPS ON A CLIENT. Equipping runs only in the Jig server RPCs
-- (SERVER_RequestMoveItemToAnotherComp / SERVER_SameContainer_MoveToIndex ->
-- JigMP_OnMainContainerItemAdded / Removed -> BP_JigHelperComp.OnMainAdded),
-- i.e. on the host, against a remote character that has no InGameUI there:
-- the game's ShowCompassWidget(true / false) never reaches the client's HUD,
-- and BP_JigHelperComp.ServerEquippedItems (read by IsGPSEquipped?: map,
-- marker overlay) is not replicated. The host reads the client's compass /
-- GPS slot from its copy (ServerEquippedItems.EquippedX.ItemID, exactly what
-- GetEquippedInfoBySlot tests) and sends it; the client writes the same item
-- into its own ServerEquippedItems and runs the game's ShowCompassWidget on
-- its own character.
--
-- MAP MARKERS PLAYERS PLACE (BP_PlayerMarker_C). The game's flow
-- (work\re\pseudo: MapWidget, BPC_MinimapSystem, BP_PlayerMarker,
-- W_PlayerMarker, BFL_MinimapSystem):
--   * double-click on the big map (MapWidget.OnMouseButtonDoubleClick ->
--     AddPlayerMarker @3732, only with IsGPSEquipped? of player 0) ->
--     "Get Minimap Component" (= GetPlayerCharacter(0)'s BPC_MinimapSystem)
--     .CreatePlayerMarker(map XY) -> "Marker Location" (a vertical line
--     trace, on the clicking machine) -> Svr_SpawnPlayerMarker(hit, ok): a
--     NetServer RPC on a component that is NOT replicated (no bReplicates in
--     its class or in BP_PlayerCharacter's template);
--   * on the server: deferred spawn of BP_PlayerMarker_C (bReplicates; Owner
--     None) -> Event_AddMarker: Marker Data = "Get Minimap Component".
--     DefaultPlayerMarkerData (white X, CompassMarker? false: player markers
--     never go on the compass), "Add Player Marker" -> MapWidget.
--     AddPlayerCreatedMarker (a W_PlayerMarker in StandardMarkerOverlay,
--     "Player Marker References"). GetPlayerCharacter(marker, 0): the marker
--     has no owner, so on the host it is ALWAYS the host - a client's marker
--     landed on the host's map, and the replicated copy on the client is
--     never registered (nothing calls Event_AddMarker there);
--   * removal: double-click on the W_PlayerMarker -> "Remove Player Marker"
--     (Marker.RemoveFromParent, K2_DestroyActor) on the clicking machine (a
--     client cannot destroy a replicated actor);
--   * saving: the actor is in the world's EMS save (Marker Data and Index are
--     SaveGame); ActorLoaded / RespawnMarker (SD_GameInstance's respawn loop,
--     sdc_players' client map build) put it on player 0's map again with the
--     saved Marker Data ("Add Saved Player Marker", retried every 2 s while
--     there is no map widget).
-- In co-op: the host's BP_PlayerMarker_C actors are the markers (saved with
-- the host's world). A client's own placement reaches the host through the
-- game's RPC and / or the mod's MKREQ (the client's own "Marker Location"
-- result; whichever comes second is recognised as the same click); the host
-- runs the game's own Svr_SpawnPlayerMarker for that player. Its owner goes
-- into the game's saved data: Marker Data title = the player's name, colour =
-- the player's colour (empty title = the host's, as in single player). The
-- host keeps a client's marker off its own map (the widget Event_AddMarker
-- put there leaves in the same frame) unless map_markers_shared is on; then
-- it shows in that player's colour with the name as tooltip. Every client
-- gets the list it may see (MKSYNC: its own, plus everybody's when shared)
-- and runs the game's own spawn + Event_AddMarker on a LOCAL copy per entry,
-- so its own map has them the single-player way (removal, RespawnMarker on a
-- new map). Removing one on a client (the game's double-click) sends MKDEL:
-- the host runs the game's Remove Player Marker, the next list removes it
-- everywhere. Each map is checked every second: one widget per marker,
-- widgets of removed markers and of other machines' replicated copies off.
-- Nothing is per-player outside the world save: no sdc_persist record.
--
-- Messages (sdc_net):
--   client -> host : MKREQ|<x>|<y>|<z>               own double-click on the map
--                                                    (z empty: the host traces)
--   client -> host : MKDEL|<key>                     a marker removed on the client's map
--   host -> client : MKSYNC|<seq>|<part>|<parts>|<key,id,x,y,z,r,g,b,name;...>
--                                                    the markers that client sees
--                                                    (20 per message; on change, after
--                                                    its HI, every 30 s)
--   client -> host : MYGPS|<0|1>                     own GPS state (on change, every 10 s)
--   host -> clients: PINFO|<player id>|<0|1>|<name>  name + GPS of every player
--                                                    (on change, to a client after its HI,
--                                                    to everybody every 10 s)
--   host -> client : PPOS|<player id>|<x>|<y>|<z>    any player more than 100 m away
--                                                    from that client (1 Hz)
--   host -> client : PEQUIP|<GPS item>|<compass item> the client's own GPS / compass slot
--                                                    (data asset paths, "" = empty;
--                                                    on change and every 10 s)
-- Player id = APlayerState.PlayerId (the same on every machine).
--
-- Every engine object is looked up again (or re-validated) right before use;
-- wrappers kept between ticks (our own proxy actors, our marker widgets while
-- their map widget is unchanged, other players' characters for <= 1 s) are
-- checked with IsValid + class name first and dropped untouched on a level
-- change (forget_world).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = {
    stats = { tags = 0, markers = 0, proxies = 0, relayed = 0 },
}

local S   -- sdc_session.state

-- ---------------------------------------------------------------------------
-- Settings (defaults apply until the keys are added to sdc_config's SCHEMA)
-- ---------------------------------------------------------------------------

local DEFAULTS = {
    player_names = true,
    player_names_range = 40,
    player_names_near = 4,
    gps_markers = true,
    gps_compass = true,
    map_markers_shared = true,
}

local function opt(key)
    local v = cfg.get(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

-- ---------------------------------------------------------------------------
-- Game assets
-- ---------------------------------------------------------------------------

local PAWN_CLASS = "BP_PlayerCharacter_C"
local WIDGET_COMPONENT = "/Script/UMG.WidgetComponent"
local NAME_WIDGET = "/Game/JigSInventory/Jigsaw/Widgets/BP_InteractWidgetCivilian.BP_InteractWidgetCivilian_C"
local NAME_WIDGET_CLASS = "BP_InteractWidgetCivilian_C"
local NAME_OFFSET = { X = 5, Y = 0, Z = 105 }   -- the civilians' NameWidget, relative to the capsule
local COMPASS_MARKER = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_CompassMarker.BP_CompassMarker_C"
local COMPASS_MARKER_CLASS = "BP_CompassMarker_C"
local DOT_TEXTURE = "/Game/Blueprints/MinimapSystem/Texture/T_Point.T_Point"   -- white ring dot
local MARKER_CLASS = "W_StandardMarker_C"

-- S_MarkerData is a user defined struct: member names carry their GUIDs.
local MD = {
    title       = "MarkerTitle_47_5E7A698C4B5AC497BBB438A55515B853",
    texture     = "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD",
    tex_size    = "TextureSize_30_0FC614D34939DCCA4077899925344EDF",
    text_size   = "TextSize_33_ADA10B73491C7DD1835FD69801CC42F1",
    color       = "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872",
    tip_color   = "TooltipBorderColor_55_45E57FFE40453BB296F6D7A44B06A8D2",
    compass     = "CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4",
    underground = "Underground?_57_38CF16D4418981C9C884F689373DF3A8",
}

-- BP_JigHelperComp.ServerEquippedItems (S_ServerEquippedItems) members and
-- the RepItemInfo member GetEquippedInfoBySlot tests (Equipped = IsValid(ItemID)).
local SLOT = {
    gps     = "EquippedGPS_58_A18BCF9B44989D75939B038888DBFC9C",
    compass = "EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB",
}
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"

-- ESlateVisibility
local VIS_COLLAPSED, VIS_HIDDEN, VIS_HIT_TEST_INVISIBLE, VIS_SELF_HIT_TEST_INVISIBLE = 1, 2, 3, 4

-- Player colours (linear), by player id.
local PALETTE = {
    { R = 0.10, G = 0.75, B = 1.00 },   -- cyan
    { R = 1.00, G = 0.50, B = 0.05 },   -- orange
    { R = 0.30, G = 1.00, B = 0.20 },   -- green
    { R = 1.00, G = 0.25, B = 0.85 },   -- magenta
    { R = 1.00, G = 0.90, B = 0.10 },   -- yellow
    { R = 0.60, G = 0.45, B = 1.00 },   -- violet
}

local GPS_RESEND_S = 10
local INFO_RESYNC_S = 10
local RELAY_FAR_CM = 10000      -- relay positions to clients farther than 100 m
local RELAY_MAX_AGE_S = 4.0
local NAME_LINGER_S = 0.75
local MAP_MARKER_SCALE = 1.0    -- on-screen size of a map marker (its design size = 1)
local DEFAULT_NAME = "Игрок"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local info = {}          -- [player id] = { name = string, gps = bool }
local my = { gps = nil, sent = nil, sent_at = -1000 }
local host = nil         -- host-side bookkeeping (new_host_state)
local relay = {}         -- client: [player id] = { X, Y, Z, t }
local others = {}        -- [player id] = character of another player on this machine (<= 1 s old)
local proxies = {}       -- [player id] = { a = BP_CompassMarker_C, mode = "attached"|"pawn"|"relay", attached = pawn name, compass = bool, cur = {X,Y,Z} }
local markers = {}       -- [player id] = { w = W_StandardMarker_C, map = map widget name, shown = bool, name = string, scale = number }
local map_key = nil      -- full name of the map widget `markers` belong to
local tags = {}          -- [character full name] = { p = character, shown, name, until_t, fail_until }
local last_role = nil
local struct_ok = nil    -- S_MarkerData member names verified
local los_broken = false
-- client: own GPS / compass slot as the host has it (PEQUIP)
local own_equip = { got = false, gps = "", compass = "", logged = nil }
local warned = {}

local function new_host_state()
    return { client_gps = {}, synced = {}, sig = {}, equip_sent = {}, equip_at = {}, hud_warned = {}, cvars = {},
             last_resync = -1000 }
end
host = new_host_state()

local function warn_once(key, msg, ...)
    if warned[key] then return end
    warned[key] = true
    log.warn(msg, ...)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function load_obj(path)
    local o = ue.find_object(path)
    if o then return o end
    ue.load_asset(path, "playermarks")
    return ue.find_object(path)
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function transform(loc)
    return {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
end

local function color_of(id)
    local c = PALETTE[(math.floor(id) % #PALETTE) + 1]
    return { R = c.R, G = c.G, B = c.B }
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function ps_id(ps)
    if not ue.valid(ps) then return nil end
    local ok, id = pcall(function() return ps:GetPlayerId() end)
    if ok and type(id) == "number" then return math.floor(id) end
    local v = ue.prop(ps, "PlayerId")
    if type(v) == "number" then return math.floor(v) end
    return nil
end

local function pawn_id(p) return ps_id(ue.prop(p, "PlayerState")) end
local function pc_id(pc) return ps_id(ue.prop(pc, "PlayerState")) end

local function local_id()
    local pc = ue.local_pc()
    if not pc then return nil end
    return pc_id(pc)
end

local function is_local(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

local function is_character(p)
    return ue.valid(p) and ue.class_name(p) == PAWN_CLASS
end

local function alive_character(p)
    return is_character(p) and ue.prop(p, "PlayerDead?") ~= true
end

local function own_character()
    local p = ue.local_pawn()
    if alive_character(p) then return p end
    return nil
end

local function display_name(id)
    local i = info[id]
    if not i then return nil end
    local n = trim(i.name)
    if n == "" then n = DEFAULT_NAME end
    return n
end

-- Characters of other (living, possessed) players on this machine, by
-- player id. A dead body is unpossessed and has no PlayerState; a client's
-- stale local copy is not a simulated proxy and is hidden.
local function refresh_others()
    local out = {}
    for _, p in ipairs(ue.find_all(PAWN_CLASS)) do
        if ue.valid(p) and not is_local(p) and ue.prop(p, "bHidden") ~= true then
            local replicated = S.role == "host" or ue.role(p) == ue.ROLE_SIMULATED
            if replicated and ue.prop(p, "PlayerDead?") ~= true then
                local id = pawn_id(p)
                if id then out[id] = p end
            end
        end
    end
    others = out
end

-- BPI_Player."IsGPSEquipped?" = BP_JigHelperComp.GetEquippedInfoBySlot(Jig.PlayerSlot.GPS).
-- nil when the call failed.
local function gps_of(p)
    if not alive_character(p) then return false end
    local out = {}
    local ok, err = pcall(function() p["IsGPSEquipped?"](p, out) end)
    if not ok then
        log.err_throttled("pm.gps", "playermarks: IsGPSEquipped? failed on %s: %s", ue.short(p), tostring(err))
        return nil
    end
    return out["GPS?"] == true
end

-- Item (data asset) in a ServerEquippedItems slot of a character, or nil.
local function slot_item(p, slot)
    local helper = ue.prop(p, "BP_JigHelperComp")
    if not ue.valid(helper) then return nil end
    local ok, v = pcall(function() return helper.ServerEquippedItems[SLOT[slot]][ITEM_ID] end)
    if ok and ue.valid(v) then return v end
    return nil
end

-- Writes the item (or nil) into the own character's slot; true when it holds.
local function set_slot_item(p, slot, item)
    local helper = ue.prop(p, "BP_JigHelperComp")
    if not ue.valid(helper) then return false end
    local ok, err = pcall(function() helper.ServerEquippedItems[SLOT[slot]][ITEM_ID] = item end)
    if not ok then
        log.err_throttled("pm.slot", "playermarks: writing the %s slot failed: %s", slot, tostring(err))
        return false
    end
    return (slot_item(p, slot) ~= nil) == (item ~= nil)
end

-- ---------------------------------------------------------------------------
-- Client: own compass / GPS slot from the host (PEQUIP)
-- ---------------------------------------------------------------------------

local function widget_shown(w)
    local okv, vis = pcall(function() return w:GetVisibility() end)
    if not okv or type(vis) ~= "number" then return nil, vis end
    return vis ~= VIS_HIDDEN and vis ~= VIS_COLLAPSED, vis
end

-- Every 5 s: any other game HUD (BP_Ingame_C) on this screen, e.g. one left
-- from an earlier character, must not show a compass either. A narrow
-- Blueprint class (one or two instances), each re-validated before use.
local hud_sweep_at = -1000
local function sweep_other_huds(own_hud, now)
    if now - hud_sweep_at < 5 then return end
    if not ue.valid(own_hud) then return end   -- only stray HUDs next to a known own one
    hud_sweep_at = now
    local own_key = ue.name(own_hud)
    for _, h in ipairs(ue.find_all("BP_Ingame_C")) do
        if ue.valid(h) and ue.name(h) ~= own_key then
            local okv, inv = pcall(function() return h:IsInViewport() end)
            local c = ue.prop(h, "Compass")
            if okv and inv == true and ue.valid(c) and widget_shown(c) == true then
                pcall(function() c:SetVisibility(VIS_HIDDEN) end)
                log.warn("playermarks: another HUD %s (not the own character's %s) showed a compass; hidden",
                    ue.short(h), tostring(own_key))
            end
        end
    end
end

-- Every second: the slots of the own character follow the host's copy, and
-- the HUD compass follows the compass slot (the game's ShowCompassWidget,
-- what JigMP_OnMainContainerItemAdded / Removed run on equip / unequip).
-- Until the host has said otherwise the compass is hidden, as in single
-- player before anything is equipped.
local function client_equip_tick(now)
    local me = own_character()
    if not me then return end
    if own_equip.got then
        for _, slot in ipairs({ "gps", "compass" }) do
            local path = own_equip[slot]
            local want = path ~= "" and load_obj(path) or nil
            if path ~= "" and not want then
                warn_once("pm.asset." .. path, "playermarks: item %s not found on this machine", path)
            end
            local have = slot_item(me, slot)
            if (have ~= nil) ~= (want ~= nil) or (have and want and ue.name(have) ~= ue.name(want)) then
                local ok = set_slot_item(me, slot, want)
                log.info("playermarks: own %s slot set from the host: %s -> %s (ok=%s)", slot,
                    have and ue.short(have) or "empty", want and ue.short(want) or "empty", tostring(ok))
            end
        end
    end
    local show = own_equip.got and own_equip.compass ~= ""
    local hud = ue.prop(me, "InGameUI")
    sweep_other_huds(hud, now)
    local compass = ue.valid(hud) and ue.prop(hud, "Compass") or nil
    if not ue.valid(compass) then return end
    local key = ue.name(hud) .. "|" .. tostring(show)
    local shown, vis = widget_shown(compass)
    -- on a change (or a new HUD), and again whenever something else flipped it
    if own_equip.hud_key ~= key or (shown ~= nil and shown ~= show) then
        if own_equip.hud_key == key then
            log.err_throttled("pm.hudflip", "playermarks: the HUD compass was %s by something else (visibility %s); %s again",
                shown and "shown" or "hidden", tostring(vis), show and "shown" or "hidden")
        end
        local ok, err = pcall(function() me:ShowCompassWidget(show) end)
        if own_equip.hud_key ~= key then
            log.info("playermarks: own compass %s on the HUD %s (was visibility %s, slot from host: %s, ShowCompassWidget ok=%s%s)",
                show and "shown" or "hidden", ue.short(hud), tostring(vis),
                own_equip.got and ("'" .. own_equip.compass .. "'") or "not received yet",
                tostring(ok), ok and "" or (" " .. tostring(err)))
        end
        own_equip.hud_key = key
    end
end

-- ---------------------------------------------------------------------------
-- Difficulty CVars the map / GPS rules depend on: the host's value applies
-- ---------------------------------------------------------------------------
-- BP_PlayerCharacter @150872-150995 opens the big map when IsGPSEquipped? OR
-- NOT Difficulty.MapVisibility. The Difficulty.* CVars are AutoSettings
-- settings of each machine (SD_GameInstance registers them, default false =
-- map without a GPS), so a client used its own value instead of the host's
-- world setting. The client takes the host's value through the game's CVar
-- helper (AutoSettings ConsoleUtils, as sdc_sync does for Game.SlowTime) and
-- gets its own value back when it leaves.
local SYNCED_CVARS = { "Difficulty.MapVisibility" }
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"
local cvars = { want = {}, saved = {} }   -- client: host's values, own values before the session

local function get_bool_cvar(name)
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu then
        local ok, v = pcall(function() return cu:GetBoolCVar(FName(name)) end)
        if ok and type(v) == "boolean" then return v end
    end
    local ksl = ue.ksl()
    if ksl then
        local ok, v = pcall(function() return ksl:GetConsoleVariableBoolValue(name) end)
        if ok and type(v) == "boolean" then return v end
    end
    return nil
end

local function set_bool_cvar(name, on)
    local cu = ue.find_object(CONSOLE_UTILS)
    if cu and pcall(function() cu:SetBoolCVar(FName(name), on) end) and get_bool_cvar(name) == on then
        return true, "ConsoleUtils"
    end
    ue.exec(name .. " " .. (on and "1" or "0"))
    return get_bool_cvar(name) == on, "console"
end

local function client_cvar_tick()
    for name, want in pairs(cvars.want) do
        local cur = get_bool_cvar(name)
        if cur == nil then
            warn_once("pm.cvar." .. name, "playermarks: %s unreadable on this machine", name)
        elseif cur ~= want then
            if cvars.saved[name] == nil then cvars.saved[name] = cur end
            local ok, how = set_bool_cvar(name, want)
            log.info("playermarks: %s %s -> %s from the host (%s, ok=%s; own value %s comes back on leaving)",
                name, cur and "1" or "0", want and "1" or "0", how, tostring(ok), cvars.saved[name] and "1" or "0")
        end
    end
end

local function restore_cvars(why)
    for name, orig in pairs(cvars.saved) do
        local ok, how = set_bool_cvar(name, orig)
        log.info("playermarks: %s back to own value %s (%s; %s, ok=%s)", name, orig and "1" or "0", why, how, tostring(ok))
    end
    cvars = { want = {}, saved = {} }
end

-- ---------------------------------------------------------------------------
-- Own GPS (every machine)
-- ---------------------------------------------------------------------------

local function own_tick(now)
    local me = own_character()
    local g = (me and gps_of(me)) or false
    if g ~= my.gps then
        log.info("playermarks: own GPS %s", g and "equipped" or "not equipped")
        my.gps = g
    end
    if S.role == "client" and (my.sent ~= g or now - my.sent_at >= GPS_RESEND_S) then
        if net.send_to_host("MYGPS", g and "1" or "0") then my.sent, my.sent_at = g, now end
    end
end

-- ---------------------------------------------------------------------------
-- Host: names / GPS of everybody, position relay
-- ---------------------------------------------------------------------------

local function send_info(pc, id, i)
    net.send_to(pc, "PINFO", id, i.gps and "1" or "0", i.name)
end

local function host_tick(now)
    local want = {}
    local me = local_id()
    if me then want[me] = { name = cfg.player_name(), gps = my.gps == true } end
    for key, r in pairs(S.remote or {}) do
        if r.hello and ue.valid(r.pc) then
            local id = pc_id(r.pc)
            if id then
                -- the client's own report, or the host's copy of its character
                -- (whichever machine keeps the equipment; logged on change)
                local said = host.client_gps[key]
                local copy = nil
                local p = ue.pawn_of(r.pc)
                if alive_character(p) then
                    local g, c = slot_item(p, "gps"), slot_item(p, "compass")
                    copy = g ~= nil
                    -- the client's own GPS / compass slot (PEQUIP)
                    local s = (g and ue.path(g) or "") .. "|" .. (c and ue.path(c) or "")
                    local skey = ue.name(p) .. "|" .. s
                    if host.equip_sent[key] ~= skey or now - (host.equip_at[key] or -1000) >= INFO_RESYNC_S then
                        if host.equip_sent[key] ~= skey then
                            log.info("playermarks: player %d (%s) slots: GPS %s, compass %s", id, tostring(r.name),
                                g and ue.short(g) or "empty", c and ue.short(c) or "empty")
                        end
                        host.equip_sent[key], host.equip_at[key] = skey, now
                        net.send_to(r.pc, "PEQUIP", g and ue.path(g) or "", c and ue.path(c) or "")
                    end
                    -- the game's equip code runs ShowCompassWidget on this
                    -- character here; it must have no HUD on the host
                    local hud = ue.prop(p, "InGameUI")
                    if ue.valid(hud) and not host.hud_warned[ue.name(p)] then
                        host.hud_warned[ue.name(p)] = true
                        local okv, inv = pcall(function() return hud:IsInViewport() end)
                        log.warn("playermarks: remote character %s has a HUD on the host (in viewport=%s)",
                            ue.short(p), tostring(okv and inv))
                    end
                end
                local sig = tostring(said) .. "/" .. tostring(copy)
                if host.sig[key] ~= sig then
                    host.sig[key] = sig
                    log.info("playermarks: player %d (%s) GPS: client says %s, host copy says %s",
                        id, tostring(r.name), tostring(said), tostring(copy))
                end
                want[id] = { name = tostring(r.name or ""), gps = said == true or copy == true }
            end
        end
    end

    local pcs = S.remote_pcs or {}
    for id, w in pairs(want) do
        local cur = info[id]
        if not cur or cur.name ~= w.name or cur.gps ~= w.gps then
            log.info("playermarks: player %d '%s' GPS %s", id, w.name, w.gps and "on" or "off")
            for _, pc in ipairs(pcs) do send_info(pc, id, w) end
        end
    end
    for id, cur in pairs(info) do
        if not want[id] then
            for _, pc in ipairs(pcs) do send_info(pc, id, { name = cur.name, gps = false }) end
        end
    end
    info = want

    -- the host's difficulty CVars the map rules depend on (PCVAR)
    local cv = {}
    for _, name in ipairs(SYNCED_CVARS) do
        local v = get_bool_cvar(name)
        if v ~= nil then
            cv[name] = v
            if host.cvars[name] ~= v then
                log.info("playermarks: host %s = %s", name, v and "1" or "0")
                for _, pc in ipairs(pcs) do net.send_to(pc, "PCVAR", name, v and "1" or "0") end
            end
        end
    end
    host.cvars = cv

    -- the whole table to a client that just said HI, and to everybody every 10 s
    local resync = now - host.last_resync >= INFO_RESYNC_S
    if resync then host.last_resync = now end
    for key, r in pairs(S.remote or {}) do
        if r.hello and ue.valid(r.pc) and (resync or not host.synced[key]) then
            host.synced[key] = true
            for id, i in pairs(info) do send_info(r.pc, id, i) end
            for name, v in pairs(host.cvars) do net.send_to(r.pc, "PCVAR", name, v and "1" or "0") end
        end
    end
    for key in pairs(host.synced) do
        if not (S.remote or {})[key] then
            host.synced[key], host.client_gps[key], host.sig[key] = nil, nil, nil
            host.equip_sent[key], host.equip_at[key] = nil, nil
        end
    end

    -- positions of every player (compass for all, map for GPS players) for
    -- clients that are too far to have the character
    for id in pairs(info) do
        local p = (id == me) and own_character() or others[id]
        local loc = alive_character(p) and ue.location(p) or nil
        if loc then
            for _, pc in ipairs(pcs) do
                if ue.valid(pc) and pc_id(pc) ~= id then
                    local cp = ue.pawn_of(pc)
                    local cl = cp and ue.location(cp)
                    if not cl or dist(cl, loc) > RELAY_FAR_CM then
                        net.send_to(pc, "PPOS", id, string.format("%.0f", loc.X),
                            string.format("%.0f", loc.Y), string.format("%.0f", loc.Z))
                        M.stats.relayed = M.stats.relayed + 1
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Map / compass markers (every machine, for the other players)
-- ---------------------------------------------------------------------------

local function proxy_ok(a)
    return ue.valid(a) and ue.class_name(a) == COMPASS_MARKER_CLASS
end

local function destroy_proxy(id, why)
    local rec = proxies[id]
    proxies[id] = nil
    if rec and proxy_ok(rec.a) then
        pcall(function() rec.a:K2_DestroyActor() end)
        log.info("playermarks: marker of player %d removed (%s)", id, why)
    end
end

-- The game's own way (BP_PlayerMarker / BP_QuestMarker): deferred spawn of
-- BP_CompassMarker_C, Icon / IconColor, finish. Alpha 0 keeps it off the
-- compass when gps_compass is off (then it only carries a map marker).
local function spawn_proxy(id, loc, compass)
    local cls = load_obj(COMPASS_MARKER)
    local gsl, wc = ue.gameplay_statics(), ue.local_pc()
    if not (cls and gsl and wc) then
        warn_once("pm.proxycls", "playermarks: BP_CompassMarker_C / GameplayStatics / controller missing, no player markers")
        return nil
    end
    local tex = load_obj(DOT_TEXTURE)
    local tf = transform(loc)
    local ok, a = pcall(function() return gsl:BeginDeferredActorSpawnFromClass(wc, cls, tf, 1, nil, 0) end)
    if not ok or not ue.valid(a) then
        log.err_throttled("pm.spawn", "playermarks: compass marker spawn failed: %s", tostring(a))
        return nil
    end
    local c = color_of(id)
    if tex then ue.set_prop(a, "Icon", tex) end
    ue.set_prop(a, "IconColor", { R = c.R, G = c.G, B = c.B, A = (compass and tex) and 1 or 0 })
    local okf, done = pcall(function() return gsl:FinishSpawningActor(a, tf, 0) end)
    local actor = (okf and proxy_ok(done)) and done or a
    if not proxy_ok(actor) then return nil end
    M.stats.proxies = M.stats.proxies + 1
    log.info("playermarks: marker actor for player %d spawned (compass %s, finish ok=%s)",
        id, compass and "on" or "off", tostring(okf))
    return actor
end

local function detach(rec)
    if rec.mode == "attached" and proxy_ok(rec.a) then
        pcall(function() rec.a:K2_DetachFromActor(1, 1, 1) end)   -- KeepWorld
        rec.cur = ue.location(rec.a) or rec.cur
    end
    rec.attached = nil
end

-- w = { pawn = character or nil, pos = relayed position or nil }
local function ensure_proxy(id, w)
    local compass = opt("gps_compass") == true
    local rec = proxies[id]
    if rec and not proxy_ok(rec.a) then
        proxies[id], rec = nil, nil       -- gone with its world / destroyed elsewhere: not touched
    elseif rec and rec.compass ~= compass then
        destroy_proxy(id, "compass setting changed")
        rec = nil
    end
    local loc = (w.pawn and ue.location(w.pawn)) or (w.pos and { X = w.pos.X, Y = w.pos.Y, Z = w.pos.Z })
    if not rec then
        if not loc then return nil end
        local a = spawn_proxy(id, loc, compass)
        if not a then return nil end
        rec = { a = a, compass = compass, mode = "relay", cur = loc }
        proxies[id] = rec
    end
    if w.pawn then
        local pk = ue.name(w.pawn)
        if rec.mode ~= "attached" or rec.attached ~= pk then
            local mesh = ue.prop(w.pawn, "Mesh")
            local ok, res = false, nil
            if ue.valid(mesh) then
                -- SnapToTarget location, KeepWorld rotation / scale
                ok, res = pcall(function() return rec.a:K2_AttachToComponent(mesh, FName("None"), 2, 1, 1, false) end)
            end
            if ok and res ~= false then
                rec.mode, rec.attached = "attached", pk
            else
                log.err_throttled("pm.attach", "playermarks: attaching the marker of player %d failed (%s), moving it instead",
                    id, tostring(res))
                rec.mode, rec.attached = "pawn", nil
            end
        end
    else
        if rec.mode == "attached" then detach(rec) end
        rec.mode = "relay"
    end
    return rec.a
end

local function map_widget()
    local me = ue.local_pawn()
    if not is_character(me) then return nil, nil end
    local mm = ue.prop(me, "MinimapSystemComponent")
    if not ue.valid(mm) then return nil, nil end
    local mw = ue.prop(mm, "MapWidget")
    if not ue.valid(mw) then return mm, nil end
    return mm, mw
end

-- Reading the minimap's DefaultPlayerMarkerData with the member names proves
-- that the names are right before a table is written into the struct (a
-- member left zero would leave an empty FText the marker would draw).
local function check_struct(mm)
    if struct_ok ~= nil then return struct_ok end
    local ok, res = pcall(function()
        local d = mm.DefaultPlayerMarkerData
        local sx = d[MD.tex_size].X
        local tx = d[MD.text_size].X
        local r = d[MD.color].R
        local title = ue.str(d[MD.title])
        local c = d[MD.compass]
        return type(sx) == "number" and type(tx) == "number" and type(r) == "number"
            and type(title) == "string" and type(c) == "boolean"
    end)
    struct_ok = ok and res == true
    log.info("playermarks: S_MarkerData member names %s%s", struct_ok and "verified" or "NOT verified, map markers off",
        ok and "" or (" (" .. tostring(res) .. ")"))
    return struct_ok
end

local function create_marker(mm, id, target, name)
    if not check_struct(mm) then return nil end
    local tex = load_obj(DOT_TEXTURE)
    if not tex then warn_once("pm.tex", "playermarks: %s not found, map markers show the name only", DOT_TEXTURE) end
    local c = color_of(id)
    local data = {
        [MD.title] = FText(name),
        [MD.tex_size] = { X = 1, Y = 1 },
        [MD.text_size] = { X = 1, Y = 1 },
        [MD.color] = { R = c.R, G = c.G, B = c.B, A = 1 },
        [MD.tip_color] = { R = 0.0025, G = 0.0025, B = 0.0025, A = 0.75 },
        [MD.compass] = false,
        [MD.underground] = false,
    }
    if tex then data[MD.texture] = tex end
    local out = {}
    local ok, err = pcall(function() mm["Add Standard Marker"](mm, data, target, out) end)
    local w = out.Markers
    if not ok or not ue.valid(w) or ue.class_name(w) ~= MARKER_CLASS then
        log.err_throttled("pm.marker", "playermarks: Add Standard Marker failed: %s", ok and "no marker returned" or tostring(err))
        return nil
    end
    -- the icon variant shows the dot only; its own (collapsed) Text row gets the name
    if tex then
        local t = ue.prop(w, "Text")
        if ue.valid(t) then
            pcall(function() t:SetText(FText(name)) end)
            pcall(function() t:SetVisibility(VIS_SELF_HIT_TEST_INVISIBLE) end)
        end
    end
    pcall(function() w:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)   -- never eats map clicks
    M.stats.markers = M.stats.markers + 1
    log.info("playermarks: map marker for player %d '%s' created (%s)", id, name, tex and "dot + name" or "name")
    return w
end

local function hide_marker(m)
    if m.shown and ue.valid(m.w) then pcall(function() m.w:SetVisibility(VIS_COLLAPSED) end) end
    m.shown = false
end

local function ensure_marker(mm, id, target, name)
    local m = markers[id]
    if m and not ue.valid(m.w) then markers[id], m = nil, nil end
    if not m then
        local w = create_marker(mm, id, target, name)
        if not w then return end
        markers[id] = { w = w, map = map_key, shown = true, name = name }
        return
    end
    local cur = ue.prop(m.w, "Target Actor")
    if not ue.valid(cur) or ue.name(cur) ~= ue.name(target) then ue.set_prop(m.w, "Target Actor", target) end
    if m.name ~= name then
        local t = ue.prop(m.w, "Text")
        if ue.valid(t) then pcall(function() t:SetText(FText(name)) end) end
        m.name = name
    end
    if not m.shown then
        pcall(function() m.w:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
        m.shown, m.scale = true, nil
    end
end

-- Compass marker (the actor) for every other player while gps_compass is on;
-- big-map marker only for players with a GPS while gps_markers is on (the
-- actor is then needed as its target even with the compass off).
local function view_tick()
    local me = local_id()
    local compass_on = opt("gps_compass") == true
    local map_on = opt("gps_markers") == true
    local wanted = {}
    for id, i in pairs(info) do
        local on_map = map_on and i.gps
        if id ~= me and (compass_on or on_map) then
            local p = others[id]
            if p and not alive_character(p) then p = nil end
            local pos = nil
            if not p then
                local r = relay[id]
                if r and os.clock() - r.t <= RELAY_MAX_AGE_S then pos = r end
            end
            if p or pos then wanted[id] = { pawn = p, pos = pos, map = on_map } end
        end
    end

    for id in pairs(proxies) do
        if not wanted[id] then destroy_proxy(id, "left / dead / out of reach / markers off") end
    end

    -- markers belong to one map widget; a new character builds a new one
    local mm, mw = map_widget()
    local key = mw and ue.name(mw) or nil
    if key ~= map_key then
        markers, map_key = {}, key       -- the old map's widgets are not touched
    end
    for id, m in pairs(markers) do
        if not (wanted[id] and wanted[id].map) then hide_marker(m) end
    end

    for id, w in pairs(wanted) do
        local target = ensure_proxy(id, w)
        if target and w.map and mm and mw then ensure_marker(mm, id, target, display_name(id) or DEFAULT_NAME) end
    end
end

-- 10 Hz: proxies that are not attached; marker size while the map is open.
local function proxies_fast()
    for id, rec in pairs(proxies) do
        if rec.mode ~= "attached" and proxy_ok(rec.a) then
            local goal = nil
            if rec.mode == "pawn" then
                local p = others[id]
                if alive_character(p) then goal = ue.location(p) end
            else
                local r = relay[id]
                if r then goal = { X = r.X, Y = r.Y, Z = r.Z } end
            end
            if goal then
                local cur = rec.cur or goal
                if rec.mode == "relay" and dist(cur, goal) < 5000 then
                    cur = { X = cur.X + (goal.X - cur.X) * 0.35, Y = cur.Y + (goal.Y - cur.Y) * 0.35, Z = cur.Z + (goal.Z - cur.Z) * 0.35 }
                else
                    cur = goal
                end
                rec.cur = cur
                ue.teleport(rec.a, cur)
            end
        end
    end
end

-- The markers sit inside the map's zoomed canvas: counter its scale so that
-- dot and name keep their size at every zoom step.
local function markers_fast()
    if not next(markers) then return end
    local mm, mw = map_widget()
    if not mw or ue.prop(mm, "MapToggled") ~= true or ue.name(mw) ~= map_key then return end
    local ic = ue.prop(mw, "InnerCanvas")
    if not ue.valid(ic) then return end
    local ok, s = pcall(function() return ic.RenderTransform.Scale.X end)
    if not ok or type(s) ~= "number" or s < 0.01 then return end
    local want = MAP_MARKER_SCALE / s
    for _, m in pairs(markers) do
        if m.shown and ue.valid(m.w) and (not m.scale or math.abs(m.scale - want) > want * 0.02) then
            if pcall(function() m.w:SetRenderScale({ X = want, Y = want }) end) then m.scale = want end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Name tags (every machine, for the other players)
-- ---------------------------------------------------------------------------

-- The civilians' NameWidget, added to the character once:
-- deferred AddComponentByClass -> screen space, desired size, no collision,
-- hidden, widget class -> FinishAddComponent (BeginPlay creates the widget).
local function tag_component(p, create)
    local cls = ue.find_object(WIDGET_COMPONENT)
    if not cls then return nil, "WidgetComponent class not found" end
    local ok, c = pcall(function() return p:GetComponentByClass(cls) end)
    if ok and ue.valid(c) then return c end
    if not create then return nil end
    local wcls = load_obj(NAME_WIDGET)
    if not wcls then return nil, "BP_InteractWidgetCivilian not found" end
    local tf = transform(NAME_OFFSET)
    local oka, comp = pcall(function() return p:AddComponentByClass(cls, false, tf, true) end)
    if not oka or not ue.valid(comp) then return nil, "AddComponentByClass: " .. tostring(comp) end
    pcall(function() comp:SetWidgetSpace(1) end)              -- EWidgetSpace::Screen
    pcall(function() comp:SetDrawAtDesiredSize(true) end)
    pcall(function() comp:SetCollisionEnabled(0) end)         -- ECollisionEnabled::NoCollision
    pcall(function() comp:SetVisibility(false, false) end)
    -- SetWidgetClass is not reflected in this build; the property is (the
    -- civilians' template sets it the same way), BeginPlay creates the widget
    local okc = ue.set_prop(comp, "WidgetClass", wcls)
    local okf, errf = pcall(function() p:FinishAddComponent(comp, false, tf) end)
    M.stats.tags = M.stats.tags + 1
    if not okf then
        log.err("playermarks: name tag for %s: FinishAddComponent failed: %s", ue.short(p), tostring(errf))
        return nil, "FinishAddComponent: " .. tostring(errf)
    end
    local okw, w = pcall(function() return comp:GetUserWidgetObject() end)
    local how = "WidgetClass"
    if not (okw and ue.valid(w)) then
        -- fallback: create the widget and hand it over (UWidgetComponent.SetWidget)
        local wbl, pc = ue.widget_lib(), ue.local_pc()
        local okn, nw = false, nil
        if wbl and pc then okn, nw = pcall(function() return wbl:Create(pc, wcls, pc) end) end
        if okn and ue.valid(nw) and pcall(function() comp:SetWidget(nw) end) then
            how = "SetWidget"
        else
            how = "no widget"
        end
    end
    log.info("playermarks: name tag added to %s (class property set=%s, widget via %s)", ue.short(p), tostring(okc), how)
    return comp
end

-- true when done
local function set_tag(p, show, name)
    local comp, why = tag_component(p, show)
    if not comp then
        if show then log.err_throttled("pm.tag", "playermarks: name tag for %s: %s", ue.short(p), tostring(why)) end
        return not show
    end
    if show then
        local okw, w = pcall(function() return comp:GetUserWidgetObject() end)
        if not okw or not ue.valid(w) or ue.class_name(w) ~= NAME_WIDGET_CLASS then
            log.err_throttled("pm.tagw", "playermarks: name tag of %s has no %s widget", ue.short(p), NAME_WIDGET_CLASS)
            return false
        end
        local txt = ue.prop(w, "Txt")
        local cur = ue.valid(txt) and trim(ue.str(ue.try(function() return txt:GetText() end))) or ""
        if cur ~= name then
            -- "{ActionName} {Name}" as for civilians (first name, surname)
            local ok, err = pcall(function() w:SetName(FText(name), FText("")) end)
            if not ok then
                log.err_throttled("pm.setname", "playermarks: SetName failed: %s", tostring(err))
                return false
            end
        end
        pcall(function() comp:SetVisibility(true, false) end)
    else
        pcall(function() comp:SetVisibility(false, false) end)
    end
    return true
end

local function camera_view(pc)
    local cam = ue.prop(pc, "PlayerCameraManager")
    if not ue.valid(cam) then return nil end
    local ok, l, pitch, yaw = pcall(function()
        local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
        return { X = loc.X, Y = loc.Y, Z = loc.Z }, rot.Pitch, rot.Yaw
    end)
    if not ok or type(l) ~= "table" or type(l.X) ~= "number" or type(pitch) ~= "number" or type(yaw) ~= "number" then
        return nil
    end
    local pr, yr = math.rad(pitch), math.rad(yaw)
    return l, { X = math.cos(pr) * math.cos(yr), Y = math.cos(pr) * math.sin(yr), Z = math.sin(pr) }
end

local function line_of_sight(pc, p)
    if los_broken then return true end
    local ok, v = pcall(function() return pc:LineOfSightTo(p, { X = 0, Y = 0, Z = 0 }, false) end)
    if not ok then
        los_broken = true
        log.warn("playermarks: LineOfSightTo unavailable (%s); names are shown through walls", tostring(v))
        return true
    end
    return v == true
end

-- Close by: while in front of the camera. Farther: the camera ray passes
-- within ~0.8 m of the chest and nothing blocks the view.
local function looks_at(pc, p, cl, fwd, ml, range, near)
    local pl = ue.location(p)
    if not pl then return false end
    local dx, dy, dz = pl.X - cl.X, pl.Y - cl.Y, pl.Z + 40 - cl.Z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < 1 then return true end
    local cosang = (dx * fwd.X + dy * fwd.Y + dz * fwd.Z) / d
    local dn = ml and dist(ml, pl) or d
    if dn <= near then return cosang > 0.2 end
    if d > range then return false end
    local tol = math.max(math.rad(2.5), math.atan(80 / d))
    if cosang < math.cos(tol) then return false end
    return line_of_sight(pc, p)
end

local function hide_tag(st)
    if st.shown and is_character(st.p) then set_tag(st.p, false) end
    st.shown = false
end

local function names_fast(now)
    local enabled = opt("player_names") == true
    local pc = ue.local_pc()
    local cl, fwd = nil, nil
    if enabled and pc then cl, fwd = camera_view(pc) end
    local me = ue.local_pawn()
    local ml = is_character(me) and ue.location(me) or nil
    local range = (tonumber(opt("player_names_range")) or DEFAULTS.player_names_range) * 100
    local near = (tonumber(opt("player_names_near")) or DEFAULTS.player_names_near) * 100
    local seen = {}
    for id, p in pairs(others) do
        if alive_character(p) then
            local key = ue.name(p)
            seen[key] = true
            local st = tags[key]
            if not st then
                st = { shown = false }
                tags[key] = st
            end
            st.p = p
            local name = display_name(id)
            local want = enabled and name ~= nil and cl ~= nil and looks_at(pc, p, cl, fwd, ml, range, near)
            if want then st.until_t = now + NAME_LINGER_S end
            local show = enabled and name ~= nil and (want or (st.until_t ~= nil and now < st.until_t))
            if show and (not st.shown or st.name ~= name) then
                if not (st.fail_until and now < st.fail_until) then
                    if set_tag(p, true, name) then
                        st.shown, st.name, st.fail_until = true, name, nil
                    else
                        st.fail_until = now + 10
                    end
                end
            elseif not show and st.shown then
                hide_tag(st)
            end
        end
    end
    -- characters that died, left or went out of range: hide before forgetting
    for key, st in pairs(tags) do
        if not seen[key] then
            hide_tag(st)
            tags[key] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Map markers players place (BP_PlayerMarker_C): owner and sharing
-- ---------------------------------------------------------------------------
-- See "MAP MARKERS" in the header. Everything lives in one table (the
-- chunk's 200-locals limit). No engine wrapper is kept between calls: the
-- host's records and a client's local copies keep the actor's address, and
-- every pass looks the actors up again (MK.scan, a narrow Blueprint class).

local MK = {
    CLASS = "BP_PlayerMarker_C",
    PATH = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_PlayerMarker.BP_PlayerMarker_C",
    MM_FN = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:",
    DBL_FN = "/Game/Blueprints/MinimapSystem/Blueprints/Widget/Markers/W_PlayerMarker.W_PlayerMarker_C:OnMouseButtonDoubleClick",
    NEAR_CM = 150,         -- one spot (the game spawns exactly at the trace point)
    DUP_S = 10,            -- the game's RPC and MKREQ of one double-click
    CHUNK = 20,            -- list entries per MKSYNC message
    RESYNC_S = 30,
    REREG_S = 5,
    REREG_MAX = 3,         -- RespawnMarker calls per marker and map widget
    HOOK_RETRY_S = 5,
    HOOK_WARN_S = 120,
    SPAWN_MAX = 25,        -- local copies spawned per pass
    REMOVED_KEEP_S = 30,
    SOLO_S = 5,
    hooks = {}, hook_at = -1000, hook_first = nil, hook_warned = false,
    next_key = 1, seq = 0, title_checked = false,
    rt_cache = {},         -- [name] = the name after an FText round trip
    stats = { placed = 0, via_rpc = 0, via_req = 0, req_dup = 0, dups = 0, removed = 0, lists = 0,
              requests = 0, spawned = 0, unparented = 0, rereg = 0, client_removed = 0, remade = 0 },
}

function MK.reset()
    -- host
    MK.recs, MK.by_addr, MK.dirty, MK.synced, MK.sent_at, MK.sent_sig = {}, {}, false, {}, -1000, {}
    MK.placing, MK.last_shared, MK.solo_at = nil, nil, -1000
    -- client
    MK.locals, MK.want, MK.parts, MK.removed, MK.need_apply, MK.want_sig, MK.hide_others = {}, nil, nil, {}, false, nil, nil
    -- the own map widget
    MK.map_addr, MK.styled, MK.reg_tries, MK.copies_logged = nil, {}, {}, false
end
MK.reset()

function MK.get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

function MK.addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and type(a) == "number" and a ~= 0 then return a end
    return nil
end

function MK.vec(v)
    if v == nil then return nil end
    local x = ue.try(function() return v.X end)
    local y = ue.try(function() return v.Y end)
    local z = ue.try(function() return v.Z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end

function MK.fmt(v) return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) end

-- A name as a list field and a saved owner: no separators, trimmed.
function MK.clean(s) return trim((tostring(s or ""):gsub("[;,|\r\n]", " "))) end

function MK.name_for(id, raw)
    local n = MK.clean(raw)
    if n == "" then n = "Player " .. tostring(id or "?") end
    return n
end

-- Every player marker actor on this machine: [address] = actor.
function MK.scan()
    local out = {}
    for _, a in ipairs(ue.find_all(MK.CLASS)) do
        if ue.valid(a) and ue.class_name(a) == MK.CLASS and not ue.short(a):find("^Default__") then
            local ad = MK.addr(a)
            if ad then out[ad] = a end
        end
    end
    return out
end

-- The nearest marker actor at `loc` that is not in `known` ([address] = x).
function MK.find_new(loc, known)
    local best, bd = nil, MK.NEAR_CM
    for ad, a in pairs(MK.scan()) do
        if not known[ad] then
            local l = ue.location(a)
            local d = l and dist(l, loc)
            if d and d <= bd then best, bd = a, d end
        end
    end
    return best
end

-- Marker Data (S_MarkerData, SaveGame) of an actor.
function MK.title_of(a)
    local ok, t = pcall(function() return a["Marker Data"][MD.title] end)
    if not ok then return nil end
    return MK.clean(ue.str(t))
end

function MK.saved_col(a)
    local ok, c = pcall(function()
        local v = a["Marker Data"][MD.color]
        return { R = v.R, G = v.G, B = v.B }
    end)
    if ok and type(c) == "table" and type(c.R) == "number" then return c end
    return nil
end

function MK.write_data(a, title, col)
    return pcall(function()
        local d = a["Marker Data"]
        if title ~= nil then d[MD.title] = FText(title) end
        if col then d[MD.color] = { R = col.R, G = col.G, B = col.B, A = 1 } end
    end)
end

-- A marker whose Event_AddMarker found no own character (Get Minimap
-- Component = None) keeps the class defaults: no texture, an invisible icon
-- after every later RespawnMarker. The minimap's default look goes in, as
-- Event_AddMarker would have done.
function MK.fix_data(a, mm)
    if not ue.valid(mm) then return false end
    local ok, res = pcall(function()
        local d = a["Marker Data"]
        if ue.valid(d[MD.texture]) then return false end
        local def = mm.DefaultPlayerMarkerData
        d[MD.texture] = def[MD.texture]
        d[MD.tex_size] = { X = def[MD.tex_size].X, Y = def[MD.tex_size].Y }
        local c = def[MD.color]
        d[MD.color] = { R = c.R, G = c.G, B = c.B, A = c.A }
        return true
    end)
    if ok and res == true then log.info("playermarks: map marker had no look (no own character when it was made): the minimap's default put in") end
    return ok and res == true
end

-- ---- the own map widget --------------------------------------------------

function MK.live(w)
    local ok, p = pcall(function() return w:GetParent() end)
    return ok and ue.valid(p)
end

function MK.unparent(w)
    local ok = pcall(function() w:RemoveFromParent() end)
    if ok then MK.stats.unparented = MK.stats.unparented + 1 end
    return ok
end

-- Live (parented) W_PlayerMarker widgets of a map: { { w =, t =, ta = } }
-- (t / ta nil: its marker actor is gone); nil when the list is unreadable.
function MK.map_list(mw)
    local arr = ue.prop(mw, "Player Marker References")
    if arr == nil then return nil end
    local out = {}
    local ok = pcall(function()
        arr:ForEach(function(_, e)
            local w = e:get()
            if ue.valid(w) and MK.live(w) then
                local t = ue.prop(w, "Target Actor")
                if ue.valid(t) then
                    out[#out + 1] = { w = w, t = t, ta = MK.addr(t) }
                else
                    out[#out + 1] = { w = w }
                end
            end
        end)
    end)
    if not ok then return nil end
    return out
end

-- Another player's marker: the player's colour on the icon (and in the
-- widget's Marker Data, which its Construct Marker reads) and the name as
-- the widget's tooltip.
function MK.style(w, col, label)
    local wa = MK.addr(w)
    local sig = string.format("%.2f,%.2f,%.2f|%s", col and col.R or -1, col and col.G or -1, col and col.B or -1, label or "")
    if wa and MK.styled[wa] == sig then return end
    if col then
        local c = { R = col.R, G = col.G, B = col.B, A = 1 }
        local icon = ue.prop(w, "Icon")
        if ue.valid(icon) then pcall(function() icon:SetColorAndOpacity(c) end) end
        pcall(function() w["Marker Data"][MD.color] = c end)
    end
    if label and label ~= "" then pcall(function() w:SetToolTipText(FText(label)) end) end
    if wa then MK.styled[wa] = sig end
end

-- The own map: one widget per marker, others' markers styled; widgets of
-- removed markers and of markers that do not belong here leave the map (the
-- first step of the game's Remove Player Marker, RemoveFromParent).
-- decide(target address, target) -> nil (not ours: untouched), false (off)
-- or { show = bool, col =, label = }. Returns the set of shown target
-- addresses, or nil (no map / list unreadable: nothing changed).
function MK.enforce(decide, keep_orphans)
    local _, mw = map_widget()
    if not mw then return nil end
    local ma = MK.addr(mw)
    if ma ~= MK.map_addr then
        MK.map_addr, MK.styled, MK.reg_tries = ma, {}, {}
    end
    local list = MK.map_list(mw)
    if not list then
        warn_once("pm.mk.list", "playermarks: the map's Player Marker References cannot be read: map markers are not checked")
        return nil
    end
    local seen, gone, off, dup = {}, 0, 0, 0
    for _, e in ipairs(list) do
        if not e.ta then
            if not keep_orphans and MK.unparent(e.w) then gone = gone + 1 end
        else
            local d = decide(e.ta, e.t)
            if d == false or (d and not d.show) then
                if MK.unparent(e.w) then off = off + 1 end
            elseif d then
                if seen[e.ta] then
                    if MK.unparent(e.w) then dup = dup + 1 end
                else
                    seen[e.ta] = true
                    if d.col or d.label then MK.style(e.w, d.col, d.label) end
                end
            end
        end
    end
    if gone + off + dup > 0 then
        log.info("playermarks: own map: marker widgets taken off: %d of removed markers, %d not for this player, %d duplicate(s)",
            gone, off, dup)
    end
    return seen
end

-- A marker that should be on the own map and is not (a new map after a
-- respawn, a marker shown again): the game's own BP_PlayerMarker.RespawnMarker
-- ("Add Saved Player Marker" with the actor's Marker Data; it retries every
-- 2 s while there is no map). A compass marker the data asks for is made
-- again by that call, so the old one goes first.
-- true when RespawnMarker was called.
function MK.rereg(rec, a, now)
    if not a then return false end
    local n = MK.reg_tries[rec.addr] or 0
    if n >= MK.REREG_MAX then
        if n == MK.REREG_MAX then
            MK.reg_tries[rec.addr] = n + 1
            log.warn("playermarks: map marker #%s is still not on the own map after %d RespawnMarker calls", tostring(rec.key), n)
        end
        return false
    end
    if now - (rec.rereg_at or -1000) < MK.REREG_S then return false end
    rec.rereg_at = now
    MK.reg_tries[rec.addr] = n + 1
    local cm = ue.prop(a, "CompassMarker")
    if ue.valid(cm) then pcall(function() cm:K2_DestroyActor() end) end
    local ok, err = pcall(function() a:RespawnMarker() end)
    MK.stats.rereg = MK.stats.rereg + 1
    if not ok then
        log.err_throttled("pm.mk.rereg", "playermarks: RespawnMarker of map marker #%s failed: %s", tostring(rec.key), tostring(err))
    end
    return true
end

-- After enforce: markers missing from the own map go back on it, and the
-- map is checked again so they get their look in the same pass.
function MK.rereg_missing(seen, list, found, now, decide)
    if not seen then return end
    local n = 0
    for _, rec in ipairs(list) do
        if not seen[rec.addr] and MK.rereg(rec, found[rec.addr], now) then n = n + 1 end
    end
    if n > 0 then
        log.info("playermarks: %d map marker(s) put on the own map (the game's RespawnMarker)", n)
        MK.enforce(decide)
    end
end

-- The game's own removal: BPC_MinimapSystem."Remove Player Marker" (the
-- actor's Marker widget off the map, K2_DestroyActor; its ReceiveDestroyed
-- destroys its compass marker). Own-map widgets that still point at it go
-- too (its Marker may name another map's widget).
function MK.game_remove(a, mm)
    local ta = MK.addr(a)
    local own_mm, mw = map_widget()
    for _, e in ipairs((mw and MK.map_list(mw)) or {}) do
        if e.ta and e.ta == ta then MK.unparent(e.w) end
    end
    mm = mm or own_mm
    local ok, err = false, "no minimap"
    if ue.valid(mm) then ok, err = pcall(function() mm["Remove Player Marker"](mm, a) end) end
    if ue.valid(a) then pcall(function() a:K2_DestroyActor() end) end
    return ok, err
end

-- ---- host ------------------------------------------------------------------

function MK.remote_of(pc)
    local pa = MK.addr(pc)
    if not pa then return nil end
    for _, r in pairs(S.remote or {}) do
        if ue.valid(r.pc) and MK.addr(r.pc) == pa then return r end
    end
    return nil
end

function MK.host_name()
    local n = MK.clean(cfg.player_name())
    return n ~= "" and n or DEFAULT_NAME
end

-- [owner] = current player id: "" = the host (its markers carry no owner,
-- as in single player); a client by the name it joined with, also in the
-- form the name takes after an FText round trip (UE4SS string conversion).
function MK.host_names()
    local t = {}
    local me = local_id()
    if me then t[""] = me end
    for id, i in pairs(info) do
        if id ~= me then
            local n = MK.name_for(id, i.name)
            t[n] = id
            local rt = MK.rt_cache[n]
            if rt == nil then
                local ok, v = pcall(function() return MK.clean(ue.str(FText(n))) end)
                rt = (ok and v) or ""
                MK.rt_cache[n] = rt
            end
            if rt ~= "" and t[rt] == nil then t[rt] = id end
        end
    end
    return t
end

function MK.rec_col(rec)
    if rec.id then return color_of(rec.id) end
    return rec.saved_col or { R = 1, G = 1, B = 1 }
end

function MK.who(rec)
    return rec.owner == "" and "the host's" or string.format("player %s's", tostring(rec.id or "offline"))
end

-- A client's marker carries its owner in the game's own saved data (title =
-- the player's name, colour = the player's colour): the host's save keeps it.
function MK.host_tag(a, rec)
    local okst = struct_ok
    if okst == nil then
        local mm = map_widget()
        okst = (mm and check_struct(mm)) or nil
    end
    if not okst then
        rec.tag_pending = okst == nil
        return
    end
    local ok, err = MK.write_data(a, rec.owner, MK.rec_col(rec))
    rec.tag_pending = not ok
    if not ok then
        log.err_throttled("pm.mk.tag", "playermarks: writing the owner of map marker #%d failed: %s", rec.key, tostring(err))
        return
    end
    if not MK.title_checked then
        MK.title_checked = true
        local back = MK.title_of(a) or ""
        log.info("playermarks: map marker owner written into its Marker Data title (read back: %s)",
            back == rec.owner and "same" or string.format("DIFFERENT, %d vs %d bytes", #back, #rec.owner))
    end
end

function MK.adopt(a, owner, id, via, now)
    local ad = MK.addr(a)
    if not ad then return nil end
    local have = MK.by_addr[ad]
    if have then return MK.recs[have] end
    local loc = ue.location(a) or { X = 0, Y = 0, Z = 0 }
    local key = MK.next_key
    MK.next_key = key + 1
    local rec = { key = key, addr = ad, owner = owner or "", id = id, X = loc.X, Y = loc.Y, Z = loc.Z, t = now, via = via }
    MK.recs[key], MK.by_addr[ad] = rec, key
    if rec.owner ~= "" then
        if via == "world" then
            rec.saved_col = MK.saved_col(a)   -- saved before: the owner is already in the data
        else
            MK.host_tag(a, rec)
        end
    end
    MK.dirty = true
    return rec
end

-- Records follow the world's actors: new ones (a load, anything the hooks
-- missed) with the owner saved in their title, gone ones dropped.
function MK.host_scan(now)
    local found = MK.scan()
    local gone, new, theirs = 0, 0, 0
    for key, rec in pairs(MK.recs) do
        if not found[rec.addr] then
            MK.recs[key], MK.by_addr[rec.addr] = nil, nil
            gone = gone + 1
            MK.dirty = true
        end
    end
    for ad, a in pairs(found) do
        if not MK.by_addr[ad] then
            local rec = MK.adopt(a, MK.title_of(a) or "", nil, "world", now)
            if rec then
                new = new + 1
                if rec.owner ~= "" then theirs = theirs + 1 end
            end
        end
    end
    if gone > 0 or new > 0 then
        log.info("playermarks: map markers in the world: %d new (%d placed by other players, owner from the saved title), %d gone",
            new, theirs, gone)
    end
    return found
end

function MK.recent_near(loc, now, owner)
    for _, rec in pairs(MK.recs) do
        if (owner == nil or rec.owner == owner) and now - rec.t <= MK.DUP_S and dist(rec, loc) <= MK.NEAR_CM then
            return rec
        end
    end
    return nil
end

-- The host's own map: its own markers, and other players' only when shared.
function MK.host_view(now, found, shared)
    local function decide(ta)
        local key = MK.by_addr[ta]
        local rec = key and MK.recs[key]
        if not rec then return nil end
        if rec.owner == "" then return { show = true } end
        return { show = shared, col = MK.rec_col(rec), label = rec.owner }
    end
    local seen = MK.enforce(decide)
    local missing = {}
    for _, rec in pairs(MK.recs) do
        local a = found[rec.addr]
        if a then
            if rec.owner == "" or shared then
                missing[#missing + 1] = rec
            else
                local cm = ue.prop(a, "CompassMarker")
                if ue.valid(cm) then pcall(function() cm:K2_DestroyActor() end) end
            end
        end
    end
    MK.rereg_missing(seen, missing, found, now, decide)
end

function MK.send_list(rkey, r, shared)
    local cid = pc_id(r.pc)
    local host_name = MK.host_name()
    local entries, own = {}, 0
    for key, rec in pairs(MK.recs) do
        local mine = cid ~= nil and rec.id == cid
        if shared or mine then
            if mine then own = own + 1 end
            local col = MK.rec_col(rec)
            entries[#entries + 1] = string.format("%d,%d,%.0f,%.0f,%.0f,%.3f,%.3f,%.3f,%s", key, rec.id or -1,
                rec.X, rec.Y, rec.Z, col.R, col.G, col.B, MK.clean(rec.owner == "" and host_name or rec.owner))
        end
    end
    table.sort(entries)
    MK.seq = MK.seq + 1
    local parts = math.max(1, math.ceil(#entries / MK.CHUNK))
    for p = 1, parts do
        local chunk = {}
        for i = (p - 1) * MK.CHUNK + 1, math.min(#entries, p * MK.CHUNK) do chunk[#chunk + 1] = entries[i] end
        net.send_to(r.pc, "MKSYNC", MK.seq, p, parts, table.concat(chunk, ";"))
    end
    MK.stats.lists = MK.stats.lists + 1
    local sig = table.concat(entries, ";")
    if MK.sent_sig[rkey] ~= sig then
        MK.sent_sig[rkey] = sig
        log.info("playermarks: map markers for player %s: %d (%d own; sharing %s) in %d message(s)",
            tostring(cid), #entries, own, shared and "on" or "off", parts)
    end
end

-- The whole list (it is small) to every client when something changed, to
-- a client after its HI, and to everybody every RESYNC_S.
function MK.host_send(now, shared)
    local due = MK.dirty or now - MK.sent_at >= MK.RESYNC_S
    local remote = S.remote or {}
    for rkey, r in pairs(remote) do
        if r.hello and ue.valid(r.pc) and (due or not MK.synced[rkey]) then
            MK.send_list(rkey, r, shared)
            MK.synced[rkey] = true
        end
    end
    if due then MK.sent_at, MK.dirty = now, false end
    for rkey in pairs(MK.synced) do
        if not remote[rkey] then MK.synced[rkey], MK.sent_sig[rkey] = nil, nil end
    end
end

function MK.after_change(now)
    local shared = opt("map_markers_shared") ~= false
    MK.host_view(now, MK.scan(), shared)
    MK.host_send(now, shared)
end

function MK.host_tick(now)
    local found = MK.host_scan(now)
    local names = MK.host_names()
    local shared = opt("map_markers_shared") ~= false
    if shared ~= MK.last_shared then
        if MK.last_shared ~= nil then log.info("playermarks: map_markers_shared %s", shared and "on" or "off") end
        MK.last_shared, MK.dirty = shared, true
    end
    for _, rec in pairs(MK.recs) do
        local id = names[rec.owner]
        if id == nil and rec.owner == "" then id = rec.id end   -- own id unreadable for a moment
        if id ~= rec.id then
            if rec.owner ~= "" then
                log.info("playermarks: map marker #%d: its owner is %s", rec.key, id and ("player " .. id) or "not here")
                rec.tag_pending = true
            end
            rec.id, MK.dirty = id, true
        end
        if rec.tag_pending and found[rec.addr] then MK.host_tag(found[rec.addr], rec) end
    end
    MK.host_view(now, found, shared)
    MK.host_send(now, shared)
end

-- Who placed a marker: the character owning the BPC_MinimapSystem the RPC
-- ran on (or the player MKREQ named).
function MK.placer_of(comp)
    if MK.placing then return MK.placing.name, MK.placing.id end
    local ch = ue.try(function() return comp:GetOwner() end)
    if not is_character(ch) then return nil end
    if is_local(ch) then return "", local_id() end
    local id = pawn_id(ch)
    local r = MK.remote_of(ue.prop(ch, "Controller"))
    if r then return MK.name_for(id, r.name), id end
    if id and info[id] then return MK.name_for(id, info[id].name), id end
    return nil
end

-- Post-hook of BPC_MinimapSystem.Svr_SpawnPlayerMarker(Hit Location, Success):
-- the game has spawned the marker and run Event_AddMarker (host's map).
function MK.on_svr_spawn(ctx_p, hit_p, ok_p)
    if not S then return end
    local comp = MK.get(ctx_p)
    local hit = MK.vec(MK.get(hit_p))
    if MK.get(ok_p) == false or not hit then return end
    if S.role == "client" then
        -- not expected (a NetServer RPC): the host's list brings the marker
        local known = {}
        for _, rec in pairs(MK.locals) do known[rec.addr] = true end
        local a = MK.find_new(hit, known)
        if a then MK.game_remove(a) end
        warn_once("pm.mk.localrpc", "playermarks: Svr_SpawnPlayerMarker ran on this client: its marker is replaced by the host's")
        return
    end
    if S.role ~= "host" then return end
    local now = os.clock()
    local owner, id = MK.placer_of(comp)
    local placing = MK.placing
    local a = MK.find_new(hit, MK.by_addr)
    if not a then
        log.warn("playermarks: Svr_SpawnPlayerMarker at %s left no new marker actor", MK.fmt(hit))
        return
    end
    if owner == nil then
        owner = ""
        log.warn("playermarks: map marker at %s: placer unknown (%s), kept as the host's", MK.fmt(hit), ue.short(comp))
    end
    if owner ~= "" and not placing then
        local dup = MK.recent_near(hit, now, owner)
        if dup then
            MK.game_remove(a)
            MK.stats.dups = MK.stats.dups + 1
            log.info("playermarks: map marker of player %s at %s came twice (MKREQ first, then the game's RPC): the second one removed, #%d stays",
                tostring(id), MK.fmt(hit), dup.key)
            return
        end
    end
    MK.fix_data(a, comp)
    local rec = MK.adopt(a, owner, id, placing and "request" or "rpc", now)
    if not rec then return end
    if placing then placing.rec = rec; return end   -- MK.on_req goes on
    MK.stats.placed, MK.stats.via_rpc = MK.stats.placed + 1, MK.stats.via_rpc + 1
    local shared = opt("map_markers_shared") ~= false
    log.info("playermarks: %s (id %s) placed map marker #%d at %s (the game's Svr_SpawnPlayerMarker)%s",
        owner == "" and "the host" or "a client", tostring(id), rec.key, MK.fmt(hit),
        owner == "" and "" or (shared and "; on the host's map in that player's colour" or "; kept off the host's map"))
    MK.after_change(now)
end

-- client -> host: MKREQ|x|y|z - a client's double-click on its map. The
-- game's own RPC usually came first (then this is the same marker); if not,
-- the host runs the game's Svr_SpawnPlayerMarker for that player.
function MK.on_req(f, pc)
    local now = os.clock()
    local x, y, z = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
    if not (x and y) then return end
    local id = pc_id(pc)
    local r = MK.remote_of(pc)
    local name = MK.name_for(id, r and r.name)
    local p = ue.pawn_of(pc)
    local comp = is_character(p) and ue.prop(p, "MinimapSystemComponent") or nil
    if not ue.valid(comp) then comp = map_widget() end   -- any BPC_MinimapSystem runs the same spawn
    if not ue.valid(comp) then
        log.warn("playermarks: map marker request of player %s: no minimap component on the host", tostring(id))
        return
    end
    if not z then
        -- the client could not trace: the game's own trace here
        local o1, o2 = {}, {}
        local ok = pcall(function() comp["Marker Location"](comp, { X = x, Y = y }, o1, o2) end)
        local hit = ok and MK.vec(o1.ImpactPoint or o2.ImpactPoint) or nil
        local success = o2.Success
        if success == nil then success = o1.Success end
        if not hit or success == false then
            log.warn("playermarks: map marker request of player %s at (%.0f, %.0f): no ground there on the host", tostring(id), x, y)
            return
        end
        x, y, z = hit.X, hit.Y, hit.Z
    end
    local loc = { X = x, Y = y, Z = z }
    MK.host_scan(now)
    local near = MK.recent_near(loc, now, nil)
    if near and near.owner == name then
        MK.stats.req_dup = MK.stats.req_dup + 1
        log.info("playermarks: map marker request of player %s at %s: #%d is already there (the game's own Svr_SpawnPlayerMarker reached the host)",
            tostring(id), MK.fmt(loc), near.key)
        return
    end
    if near and near.owner == "" and near.via == "world" then
        -- appeared without a known placer this very second: that player's
        near.owner, near.id, near.via = name, id, "rpc"
        local a = MK.scan()[near.addr]
        if a then MK.host_tag(a, near) end
        MK.dirty = true
        log.info("playermarks: map marker #%d at %s (found without its placer) is player %s's", near.key, MK.fmt(loc), tostring(id))
        MK.after_change(now)
        return
    end
    local placing = { name = name, id = id }
    MK.placing = placing
    local ok, err = pcall(function() comp:Svr_SpawnPlayerMarker(loc, true) end)
    MK.placing = nil
    local rec = placing.rec
    if not rec then
        -- the Blueprint hook did not see a call made from Lua
        local a = MK.find_new(loc, MK.by_addr)
        if a then
            MK.fix_data(a, comp)
            rec = MK.adopt(a, name, id, "request", now)
        end
    end
    if not rec then
        log.warn("playermarks: map marker request of player %s at %s placed nothing (Svr_SpawnPlayerMarker ok=%s%s)",
            tostring(id), MK.fmt(loc), tostring(ok), ok and "" or (" " .. tostring(err)))
        return
    end
    MK.stats.placed, MK.stats.via_req = MK.stats.placed + 1, MK.stats.via_req + 1
    local shared = opt("map_markers_shared") ~= false
    log.info("playermarks: a client (id %s) placed map marker #%d at %s (the mod's MKREQ: the game's RPC did not come first; Svr_SpawnPlayerMarker run on the host)%s",
        tostring(id), rec.key, MK.fmt(loc), shared and "; on the host's map in that player's colour" or "; kept off the host's map")
    MK.after_change(now)
end

-- client -> host: MKDEL|key,key - markers a client removed on its map: the
-- game's own removal here, the next list removes them everywhere.
function MK.on_del(f, pc)
    local now = os.clock()
    local id = pc_id(pc)
    local shared = opt("map_markers_shared") ~= false
    local found = MK.scan()
    local n = 0
    for k in tostring(f[1] or ""):gmatch("%d+") do
        local rec = MK.recs[tonumber(k)]
        if rec and not shared and rec.id ~= id then
            log.warn("playermarks: player %s asked to remove map marker #%d (%s), not its own while sharing is off: kept", tostring(id), rec.key, MK.who(rec))
        elseif rec then
            local a = found[rec.addr]
            local ok = a and MK.game_remove(a)
            MK.recs[rec.key], MK.by_addr[rec.addr] = nil, nil
            MK.dirty, n = true, n + 1
            MK.stats.removed = MK.stats.removed + 1
            log.info("playermarks: player %s removed map marker #%d (%s) on its map: removed from the world (Remove Player Marker ok=%s)",
                tostring(id), rec.key, MK.who(rec), tostring(ok))
        end
    end
    if n > 0 then MK.after_change(now) end
end

-- ---- client ----------------------------------------------------------------

-- "key,id,x,y,z,r,g,b,name" (the name is the rest: it has no ';' or ',').
function MK.parse_entry(s)
    local t, rest = {}, s
    for i = 1, 8 do
        local a = rest:find(",", 1, true)
        if not a then return nil end
        t[i], rest = rest:sub(1, a - 1), rest:sub(a + 1)
    end
    local v = {}
    for i = 1, 8 do
        v[i] = tonumber(t[i])
        if not v[i] then return nil end
    end
    return { key = math.floor(v[1]), id = v[2] >= 0 and math.floor(v[2]) or nil, X = v[3], Y = v[4], Z = v[5],
             col = { R = v[6], G = v[7], B = v[8] }, name = rest }
end

-- A local copy of a host marker, made the way the game's
-- Svr_SpawnPlayerMarker makes one (deferred spawn, FinishSpawningActor,
-- Event_AddMarker on this machine's player 0 = this player's map). Another
-- player's keeps that player's colour and name in its Marker Data, so the
-- game's RespawnMarker brings it back the same on a new map.
function MK.spawn_local(e, mm, own)
    local cls = load_obj(MK.PATH)
    local gsl, wc = ue.gameplay_statics(), ue.local_pc()
    if not (cls and gsl and wc) then
        warn_once("pm.mk.cls", "playermarks: BP_PlayerMarker_C / GameplayStatics / controller missing: map markers from the host are not shown")
        return nil
    end
    local tf = transform(e)
    local ok, a = pcall(function() return gsl:BeginDeferredActorSpawnFromClass(wc, cls, tf, 1, nil, 0) end)
    if not ok or not ue.valid(a) then
        log.err_throttled("pm.mk.spawn", "playermarks: map marker spawn failed: %s", tostring(a))
        return nil
    end
    local okf, done = pcall(function() return gsl:FinishSpawningActor(a, tf, 0) end)
    local actor = (okf and ue.valid(done) and ue.class_name(done) == MK.CLASS) and done or a
    if not (ue.valid(actor) and ue.class_name(actor) == MK.CLASS) then return nil end
    local oka, erra = pcall(function() actor:Event_AddMarker() end)
    if not oka then log.err_throttled("pm.mk.add", "playermarks: Event_AddMarker failed: %s", tostring(erra)) end
    MK.fix_data(actor, mm)
    if not own and check_struct(mm) then MK.write_data(actor, e.name, e.col) end
    MK.stats.spawned = MK.stats.spawned + 1
    return actor
end

-- The host's list -> local copies (only with an own living character: the
-- game's Event_AddMarker reads its minimap).
function MK.client_apply(now)
    local want = MK.want
    if not want then return end
    local me = own_character()
    local mm = me and ue.prop(me, "MinimapSystemComponent") or nil
    local myid = local_id()
    if not ue.valid(mm) or myid == nil then
        MK.need_apply = true
        return
    end
    local hide = opt("map_markers_shared") == false
    MK.hide_others = hide
    local function shown(e) return not hide or (e.id ~= nil and e.id == myid) end
    local found = MK.scan()
    for key, t in pairs(MK.removed) do
        if not want[key] or now - t > MK.REMOVED_KEEP_S then MK.removed[key] = nil end
    end
    local added, removed, pending = 0, 0, false
    for key, rec in pairs(MK.locals) do
        local e = want[key]
        local a = found[rec.addr]
        if not (e and a and shown(e) and dist(rec, e) <= MK.NEAR_CM) or MK.removed[key] then
            if a then
                MK.game_remove(a, mm)
                removed = removed + 1
            end
            MK.locals[key] = nil
        else
            rec.id, rec.name, rec.col, rec.own = e.id, e.name, e.col, e.id ~= nil and e.id == myid
        end
    end
    for key, e in pairs(want) do
        if not MK.locals[key] and not MK.removed[key] and shown(e) then
            if added >= MK.SPAWN_MAX then
                pending = true
            else
                local own = e.id ~= nil and e.id == myid
                local ad = MK.addr(MK.spawn_local(e, mm, own))
                if ad then
                    MK.locals[key] = { key = key, addr = ad, id = e.id, name = e.name, col = e.col, own = own,
                                       X = e.X, Y = e.Y, Z = e.Z }
                    added = added + 1
                else
                    pending = true
                end
            end
        end
    end
    MK.need_apply = pending
    if added > 0 or removed > 0 then
        local n = 0
        for _ in pairs(MK.locals) do n = n + 1 end
        log.info("playermarks: own map markers from the host: +%d -%d, %d now%s%s", added, removed, n,
            hide and " (others' markers hidden: own map_markers_shared off)" or "", pending and "; more next second" or "")
        MK.client_view(now, MK.scan())
    end
end

-- The own map: own copies once (others' in their colour with the name);
-- replicated copies of the host's actors registered by the game / sdc_players
-- on a new map carry no data (no icon) and leave it; a copy not on the map
-- goes back through the game's RespawnMarker.
function MK.client_view(now, found)
    local by = {}
    for _, rec in pairs(MK.locals) do by[rec.addr] = rec end
    local copies = 0
    local auth = ue.ROLE_AUTHORITY or 3
    local function decide(ta, t)
        local rec = by[ta]
        if rec then
            if rec.own then return { show = true } end
            return { show = true, col = rec.col, label = rec.name }
        end
        if ue.class_name(t) == MK.CLASS and ue.role(t) ~= auth then
            copies = copies + 1
            return false
        end
        return nil
    end
    local seen = MK.enforce(decide)
    if copies > 0 and not MK.copies_logged then
        MK.copies_logged = true
        log.info("playermarks: %d replicated copy(ies) of the host's map markers were on the own map (no icon): taken off, the own copies stand for them", copies)
    end
    local list = {}
    for _, rec in pairs(MK.locals) do list[#list + 1] = rec end
    MK.rereg_missing(seen, list, found, now, decide)
end

function MK.client_tick(now)
    local found = MK.scan()
    local remade = 0
    for key, rec in pairs(MK.locals) do
        if not found[rec.addr] then
            MK.locals[key] = nil
            MK.need_apply, remade = true, remade + 1
        end
    end
    if remade > 0 then
        MK.stats.remade = MK.stats.remade + remade
        log.info("playermarks: %d own copy(ies) of map markers were removed by the game here (not by the player): made again", remade)
    end
    local hide = opt("map_markers_shared") == false
    if MK.hide_others ~= nil and hide ~= MK.hide_others then MK.need_apply = true end
    if MK.need_apply then
        MK.client_apply(now)
        found = MK.scan()
    end
    MK.client_view(now, found)
end

-- host -> client: MKSYNC|seq|part|parts|entries
function MK.on_sync(f)
    if not S or S.role ~= "client" then return end
    local seq, part, parts = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
    if not (seq and part and parts) or parts < 1 then return end
    local P = MK.parts
    if not P or P.seq ~= seq then
        P = { seq = seq, parts = parts, got = {}, n = 0, entries = {} }
        MK.parts = P
    end
    if not P.got[part] then
        P.got[part], P.n = true, P.n + 1
        for item in tostring(f[4] or ""):gmatch("[^;]+") do
            local e = MK.parse_entry(item)
            if e then P.entries[e.key] = e end
        end
    end
    if P.n < P.parts then return end
    MK.parts, MK.want = nil, P.entries
    local n, own, myid = 0, 0, local_id()
    for _, e in pairs(P.entries) do
        n = n + 1
        if e.id ~= nil and e.id == myid then own = own + 1 end
    end
    local sig = n .. "/" .. own
    if sig ~= MK.want_sig then
        MK.want_sig = sig
        log.info("playermarks: host's map markers for this player: %d (%d own)", n, own)
    end
    MK.need_apply = true
    MK.client_apply(os.clock())
end

-- Post-hook of BPC_MinimapSystem.CreatePlayerMarker(Map Location) on a
-- client: its Svr_SpawnPlayerMarker RPC went to the host (if the engine sends
-- it for a component that does not replicate); MKREQ asks for the same
-- marker with the game's own trace result.
function MK.on_create(ctx_p, ml_p)
    if not S or S.role ~= "client" then return end
    local comp = MK.get(ctx_p)
    if not ue.valid(comp) then return end
    local ch = ue.try(function() return comp:GetOwner() end)
    if not (is_character(ch) and is_local(ch)) then return end
    local ml = MK.get(ml_p)
    local x = ue.try(function() return ml.X end)
    local y = ue.try(function() return ml.Y end)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    local o1, o2 = {}, {}
    local ok, err = pcall(function() comp["Marker Location"](comp, { X = x, Y = y }, o1, o2) end)
    local hit = ok and MK.vec(o1.ImpactPoint or o2.ImpactPoint) or nil
    local success = o2.Success
    if success == nil then success = o1.Success end
    if ok and success == false then
        log.info("playermarks: own map double-click at (%.0f, %.0f): no ground there, no marker (as in single player)", x, y)
        return
    end
    if hit then
        net.send_to_host("MKREQ", string.format("%.1f", hit.X), string.format("%.1f", hit.Y), string.format("%.1f", hit.Z))
    else
        net.send_to_host("MKREQ", string.format("%.1f", x), string.format("%.1f", y), "")
    end
    MK.stats.requests = MK.stats.requests + 1
    log.info("playermarks: own map double-click -> map marker at %s asked from the host (the game's RPC + MKREQ)%s",
        hit and MK.fmt(hit) or string.format("(%.0f, %.0f, ?)", x, y), ok and "" or (" (Marker Location: " .. tostring(err) .. ")"))
end

-- Post-hook of W_PlayerMarker.OnMouseButtonDoubleClick: the game has run
-- "Remove Player Marker" on the clicked marker on this machine.
function MK.on_dblclick(ctx_p)
    if not S or (S.role ~= "host" and S.role ~= "client") then return end
    local w = MK.get(ctx_p)
    if not ue.valid(w) then return end
    local t = nil
    pcall(function() t = w["Target Actor"] end)   -- pending kill by now: its address only
    local ta = MK.addr(t)
    -- the clicked widget leaves the map, whichever widget the actor's Marker named
    if MK.live(w) then MK.unparent(w) end
    local now = os.clock()
    if S.role == "host" then
        local key = ta and MK.by_addr[ta]
        local rec = key and MK.recs[key]
        if not rec then return end
        local a = MK.scan()[rec.addr]
        if a then MK.game_remove(a) end
        MK.recs[key], MK.by_addr[rec.addr] = nil, nil
        MK.dirty = true
        MK.stats.removed = MK.stats.removed + 1
        log.info("playermarks: the host removed map marker #%d (%s) on its map", key, MK.who(rec))
        MK.after_change(now)
        return
    end
    local found = MK.scan()
    local key = nil
    for k, rec in pairs(MK.locals) do
        if ta and rec.addr == ta then key = k end
    end
    if not key and ue.valid(t) then
        -- a replicated copy's widget: the own copy at its spot
        local l = ue.location(t)
        if l then
            for k, rec in pairs(MK.locals) do
                if dist(rec, l) <= MK.NEAR_CM then key = k end
            end
        end
    end
    if not key then
        -- the actor is gone already: the one own copy that just vanished
        local gone = {}
        for k, rec in pairs(MK.locals) do
            if not found[rec.addr] then gone[#gone + 1] = k end
        end
        if #gone == 1 then key = gone[1] end
    end
    if not key then return end
    local rec = MK.locals[key]
    MK.locals[key] = nil
    MK.removed[key] = now
    local a = found[rec.addr]
    if a then MK.game_remove(a) end
    net.send_to_host("MKDEL", tostring(key))
    MK.stats.client_removed = MK.stats.client_removed + 1
    log.info("playermarks: map marker #%d (%s) removed on the own map -> MKDEL to the host", key,
        rec.own and "own" or ("player " .. tostring(rec.id) .. "'s"))
end

-- ---- both ------------------------------------------------------------------

-- Blueprint hooks (one callback, after the function), registered once their
-- classes are loaded (with the player character / its map).
function MK.try_hooks(now)
    if MK.hooks.create and MK.hooks.svr and MK.hooks.dbl then return end
    if now - MK.hook_at < MK.HOOK_RETRY_S then return end
    MK.hook_at = now
    MK.hook_first = MK.hook_first or now
    local function reg(name, path, fn)
        if MK.hooks[name] then return end
        local ok = pcall(RegisterHook, path, function(...)
            local okc, err = pcall(fn, ...)
            if not okc then log.err_throttled("pm.mk." .. name, "playermarks: %s hook: %s", name, tostring(err)) end
        end)
        if ok then
            MK.hooks[name] = true
            log.info("playermarks: map marker hook %s ok", path:match("[%w_]+:[%w_]+$") or path)
        end
    end
    reg("create", MK.MM_FN .. "CreatePlayerMarker", MK.on_create)
    reg("svr", MK.MM_FN .. "Svr_SpawnPlayerMarker", MK.on_svr_spawn)
    reg("dbl", MK.DBL_FN, MK.on_dblclick)
    if not MK.hook_warned and now - MK.hook_first >= MK.HOOK_WARN_S
        and not (MK.hooks.create and MK.hooks.svr and MK.hooks.dbl) then
        MK.hook_warned = true
        log.warn("playermarks: map marker hooks still missing after %d s (create=%s svr=%s dbl=%s)", MK.HOOK_WARN_S,
            tostring(MK.hooks.create == true), tostring(MK.hooks.svr == true), tostring(MK.hooks.dbl == true))
    end
end

function MK.tick(role, now)
    MK.try_hooks(now)
    if role == "host" then MK.host_tick(now) else MK.client_tick(now) end
end

-- No session, sharing off: markers clients placed in this world (saved
-- owner in the title) stay off this player's map in single player too.
function MK.solo_tick(now)
    if opt("map_markers_shared") ~= false or now - MK.solo_at < MK.SOLO_S then return end
    MK.solo_at = now
    local titled = {}
    for ad, a in pairs(MK.scan()) do
        if (MK.title_of(a) or "") ~= "" then titled[ad] = true end
    end
    if not next(titled) then return end
    MK.enforce(function(ta) if titled[ta] then return { show = false } end return nil end, true)
end

-- Leaving a session in the same world: a client's local copies go (the
-- game's removal); the host's world actors stay.
function MK.cleanup(last)
    if last == "client" then
        local found = MK.scan()
        for _, rec in pairs(MK.locals) do
            local a = found[rec.addr]
            if a then MK.game_remove(a) end
        end
    end
    MK.reset()
end

function MK.report(out)
    local nr, theirs, nl = 0, 0, 0
    for _, rec in pairs(MK.recs) do
        nr = nr + 1
        if rec.owner ~= "" then theirs = theirs + 1 end
    end
    for _ in pairs(MK.locals) do nl = nl + 1 end
    local s = MK.stats
    out(string.format("  map markers: shared=%s | host records=%d (%d of other players) | own copies=%d | hooks create=%s svr=%s dbl=%s",
        tostring(opt("map_markers_shared")), nr, theirs, nl, tostring(MK.hooks.create == true), tostring(MK.hooks.svr == true),
        tostring(MK.hooks.dbl == true)))
    out(string.format("  map markers: placed=%d (rpc=%d mkreq=%d) req_dup=%d dups=%d removed=%d lists=%d | client: requests=%d spawned=%d removed=%d remade=%d | widgets off=%d rereg=%d",
        s.placed, s.via_rpc, s.via_req, s.req_dup, s.dups, s.removed, s.lists, s.requests, s.spawned, s.client_removed,
        s.remade, s.unparented, s.rereg))
end

-- ---------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------

-- Role change in the same world (server closed, left): our own actors and
-- widgets are still alive and are removed.
local function cleanup(why)
    for id in pairs(proxies) do destroy_proxy(id, why) end
    local _, mw = map_widget()
    if mw and ue.name(mw) == map_key then
        for _, m in pairs(markers) do hide_marker(m) end
    end
    for _, st in pairs(tags) do hide_tag(st) end
    proxies, markers, tags, others, map_key = {}, {}, {}, {}, nil
end

-- Every second (main.lua).
function M.tick()
    if not S then return end
    local role = S.role
    if role ~= last_role then
        if last_role == "host" or last_role == "client" then
            local ok, err = pcall(cleanup, "role " .. tostring(last_role) .. " -> " .. tostring(role))
            if not ok then log.err("playermarks: cleanup failed: %s", tostring(err)) end
        end
        if last_role == "client" or next(cvars.saved) then
            local ok, err = pcall(restore_cvars, "left the session")
            if not ok then log.err("playermarks: restoring CVars failed: %s", tostring(err)) end
        end
        local okm, errm = pcall(MK.cleanup, last_role)
        if not okm then
            log.err("playermarks: map marker cleanup failed: %s", tostring(errm))
            MK.reset()
        end
        last_role = role
        info, relay, host = {}, {}, new_host_state()
        my.sent, my.sent_at = nil, -1000
        own_equip = { got = false, gps = "", compass = "" }
    end
    if role ~= "host" and role ~= "client" then
        local oks, errs = pcall(MK.solo_tick, os.clock())
        if not oks then log.err_throttled("pm.mk.solo", "playermarks: map markers (no session): %s", tostring(errs)) end
        return
    end
    -- (no main-menu check: ue.in_main_menu() is also true while the local
    -- player is dead, and the host must keep relaying then)
    local now = os.clock()
    refresh_others()
    if role == "client" then
        local ok, err = pcall(client_equip_tick, now)
        if not ok then log.err_throttled("pm.equip", "playermarks: own compass / GPS slot: %s", tostring(err)) end
        ok, err = pcall(client_cvar_tick)
        if not ok then log.err_throttled("pm.cvar", "playermarks: host CVars: %s", tostring(err)) end
    end
    own_tick(now)
    if role == "host" then host_tick(now) end
    view_tick()
    local okm, errm = pcall(MK.tick, role, now)
    if not okm then log.err_throttled("pm.mk", "playermarks: map markers: %s", tostring(errm)) end
end

-- Every 100 ms (main.lua).
function M.fast_tick()
    if not S or (S.role ~= "host" and S.role ~= "client") then return end
    local now = os.clock()
    names_fast(now)
    proxies_fast()
    markers_fast()
end

-- Level change (sdc_session.world_reset_hooks): everything cached belongs to
-- the old world and is dropped without touching it.
function M.forget_world(why)
    proxies, markers, tags, others, map_key = {}, {}, {}, {}, nil
    relay = {}
    if S and S.role == "client" then info = {} end
    MK.reset()
    host = new_host_state()
    my.sent, my.sent_at = nil, -1000
    own_equip = { got = false, gps = "", compass = "" }
    log.debug("playermarks: world reset (%s)", tostring(why))
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

function M.register_handlers()
    -- client -> host: MYGPS|<0|1>
    net.on("MYGPS", function(f, pc)
        if not S or S.role ~= "host" then return end
        host.client_gps[ue.name(pc)] = f[1] == "1"
    end)
    -- host -> clients: PINFO|<player id>|<0|1>|<name>
    net.on("PINFO", function(f)
        local id = tonumber(f[1])
        if not id then return end
        info[math.floor(id)] = { gps = f[2] == "1", name = f[3] or "" }
    end)
    -- host -> client: PPOS|<player id>|<x>|<y>|<z>
    net.on("PPOS", function(f)
        local id, x, y, z = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
        if not (id and x and y and z) then return end
        relay[math.floor(id)] = { X = x, Y = y, Z = z, t = os.clock() }
    end)
    -- host -> clients: PCVAR|<name>|<0|1>   (only the CVars in SYNCED_CVARS)
    net.on("PCVAR", function(f)
        local name = f[1] or ""
        for _, n in ipairs(SYNCED_CVARS) do
            if n == name then
                local v = f[2] == "1"
                if cvars.want[name] ~= v then log.info("playermarks: host says %s = %s", name, v and "1" or "0") end
                cvars.want[name] = v
            end
        end
    end)
    -- host -> client: PEQUIP|<GPS item path>|<compass item path>   (own slots; "" = empty)
    net.on("PEQUIP", function(f)
        local g, c = f[1] or "", f[2] or ""
        if not own_equip.got or own_equip.gps ~= g or own_equip.compass ~= c then
            log.info("playermarks: host says own GPS slot '%s', compass slot '%s'", g, c)
        end
        own_equip.got, own_equip.gps, own_equip.compass = true, g, c
    end)
    -- client -> host: MKREQ|x|y|z   (own double-click on the map; z empty = trace here)
    net.on("MKREQ", function(f, pc)
        if not S or S.role ~= "host" then return end
        MK.on_req(f, pc)
    end)
    -- client -> host: MKDEL|key,key   (markers removed on the client's map)
    net.on("MKDEL", function(f, pc)
        if not S or S.role ~= "host" then return end
        MK.on_del(f, pc)
    end)
    -- host -> client: MKSYNC|seq|part|parts|key,id,x,y,z,r,g,b,name;...
    net.on("MKSYNC", function(f) MK.on_sync(f) end)
end

M.MK = MK   -- tests / console

function M.init(state)
    S = state
    M.register_handlers()
end

-- Console report (sdcoop_marks).
function M.report(out)
    out(string.format("playermarks: role=%s my id=%s own GPS=%s | names=%s gps markers=%s compass=%s",
        tostring(S and S.role), tostring(local_id()), tostring(my.gps), tostring(opt("player_names")),
        tostring(opt("gps_markers")), tostring(opt("gps_compass"))))
    if S and S.role == "client" then
        out(string.format("  own slots from host: got=%s GPS='%s' compass='%s'", tostring(own_equip.got),
            own_equip.gps, own_equip.compass))
        for _, name in ipairs(SYNCED_CVARS) do
            out(string.format("  %s: host %s, here %s, own value before %s", name, tostring(cvars.want[name]),
                tostring(get_bool_cvar(name)), tostring(cvars.saved[name])))
        end
    end
    for id, i in pairs(info) do
        local r = relay[id]
        out(string.format("  player %d '%s' gps=%s here=%s relay=%s", id, i.name, tostring(i.gps),
            tostring(others[id] ~= nil), r and string.format("%.0f,%.0f (%.1f s old)", r.X, r.Y, os.clock() - r.t) or "-"))
    end
    for id, rec in pairs(proxies) do
        out(string.format("  marker actor %d: %s mode=%s compass=%s", id, ue.short(rec.a), tostring(rec.mode), tostring(rec.compass)))
    end
    for id, m in pairs(markers) do
        out(string.format("  map marker %d: shown=%s scale=%s", id, tostring(m.shown), tostring(m.scale)))
    end
    local n = 0
    for _, st in pairs(tags) do if st.shown then n = n + 1 end end
    out(string.format("  name tags shown=%d | made: tags=%d markers=%d actors=%d relayed=%d | struct=%s",
        n, M.stats.tags, M.stats.markers, M.stats.proxies, M.stats.relayed, tostring(struct_ok)))
    MK.report(out)
end

return M
