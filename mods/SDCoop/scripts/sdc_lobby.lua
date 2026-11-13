-- SDCoop: the "Кооператив" button in the game's own menus.
--
-- The game's menus get one button that opens the co-op panel (sdc_ui). An
-- earlier in-menu page mode (co-op pages built into the game's widget trees
-- from copies of its widgets) crashed the game - copying slot layouts
-- between canvas slots hung, then EXCEPTION_ACCESS_VIOLATION; removing and
-- re-adding the game's own buttons on a fresh pause screen crashed on Esc -
-- and was removed.
--   Pause menu: a clone of "Settings" (made the way the death-screen
--     buttons are, which works), appended to the game's list. It opens the
--     panel; in a running single-player world the panel's «Открыть мир для
--     друзей» saves the world and loads it again, open for friends
--     (sdc_session.host_on_next_load -> open_world_now).
--   Main menu: the button stands apart, ABOVE the game's button column and
--     in the co-op panel's amber (coop_button_on_top). It cannot go to the
--     top of the column itself: a child added to a live box is appended to
--     its Slate box, and ShiftChild / InsertChildAt only reorder the UMG slot
--     array (Slate is not rebuilt), so it becomes a child of the column's
--     parent canvas instead. Fallback (no canvas there, a layout that cannot
--     be read or set, or lobby_top.marker from a start that crashed there):
--     the plain clone at the bottom of the column, behind a spacer of ours.
--
-- Widget lifetime:
--   * The HUD creates a NEW PauseScreen_C on every pause (HUD_Game 340-420)
--     and the main menu is recreated on every level open. A menu that has
--     its button is remembered by its widget name (simple_patched, dropped
--     on every level change). The main menu's wrapper (patched_menu) is
--     re-checked by name and "on screen" on every tick and dropped on every
--     level change.
--   * Every widget this module names is SDC_Coop<Part>_<n>, n unique for the
--     process.
--   * New menus: NotifyOnNewObject queues them and the frame tick adds the
--     button once their tree is up. The real main menu (NotifyOnNewObject
--     reported only its CDO in this UE4SS build) is also looked for once a
--     second (WidgetBlueprintLibrary.GetAllWidgetsOfClass), only while the
--     main menu is up and has no button yet.
--
-- Crash guards: lobby_build.marker while the first button of a kind (main
-- menu / pause menu) is placed in this session and painted (two starts in a
-- row ending there turn the lobby off); lobby_top.marker for the main menu's
-- top placement (it stays: the top is off until the file is deleted).
--
-- Notifications: M.notify / M.toast_sink route the mod's toasts to the
-- game's notification widget (GameFunctionLibrary_C.CreateNotificationUI),
-- falling back to the overlay toasts when there is no game HUD or a level
-- change is coming (the overlay survives it, the game's HUD does not).
--
-- Wiring (main.lua): lobby.install(MOD_DIR); slow_tick every 250 ms;
-- frame_tick every frame BEFORE widgets.frame_tick;
-- log.toast_sink = lobby.toast_sink(ui.toast).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local session = require("sdc_session")
local W = require("sdc_widgets")

local M = {
    disabled = false,
    use_game_notifications = true,
}

local MENU_CLASS = "/Game/UI/Menus/Menu/MenuWidget.MenuWidget_C"
local PAUSE_CLASS = "/Game/UI/Menus/PauseScreen/PauseScreen.PauseScreen_C"
-- HUD_Game_C's notification box (its NotificationUI, added to the viewport)
local NOTIFY_CLASS = "/Game/UI/Widgets/Notification/NotificationParentWidget.NotificationParentWidget_C"
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"

local WATCH_FRAMES = 240      -- frames a new menu widget is watched until its tree is up
local MARKER_FRAMES = 45      -- frames the crash marker outlives a placement
local MARKER_MAX_MS = 10000   -- ... or this long when the frame tick does not run
-- The real MenuWidget_C only exists after the PRESS ANY KEY screen, which can
-- take any time: scan once a second while the main menu is up without its
-- button (main menu only).
local SCAN_BUDGET = 100000    -- fallback scans for the main menu per world
local SCAN_EVERY = 4          -- slow ticks between those scans (1 s)
local SETTLE_S = 1.5          -- a new menu stays untouched this long after it is on screen
-- Main menu "Кооператив" button (see coop_button_on_top)
local TOP_GAP = 20            -- px between it and the top of the game's button column
local BOTTOM_GAP = 12         -- px spacer above it when it stays at the bottom of the column
local ROW_MIN, ROW_MAX = 28, 64   -- its height: one row of the game's column, within these
local TOP_MARKER_FRAMES = 120 -- frames the top-placement marker outlives the placement

local COOP_RU = "Кооператив"  -- the label when sdc_i18n has none
-- the co-op panel's amber (sdc_ui "amber" #DB751A, linear): the main menu's
-- "Кооператив" label, so it reads as the mod's, not the game's
local ACCENT = { R = 0.708, G = 0.178, B = 0.010, A = 1.0 }

-- State for the current world only (see the header).
local seq = 0                    -- n of the names SDC_Coop<Part>_<n>
local watch_queue = {}           -- new menu widgets waiting for their tree (this world only)
local diag_left = 6              -- "main menu not patched yet" lines
local late = {}                  -- watched widgets of this world not on screen within WATCH_FRAMES
local world_gen = 0
local tick_n = 0
local scans_left = SCAN_BUDGET
local pending_conn = false       -- cached ue.has_pending_connection() (an object scan)
local loadmap_hooked = false
local simple_patched = {}        -- [menu widget name] = true: it has its co-op button
local menu_seen_at = {}          -- [menu widget name] = os.clock() when first seen on screen
local last_scan_sig = nil
local patched_menu = nil         -- { w, key }: the main menu with its button (this world)

-- forward declaration
local drain_notifications

-- ===========================================================================
-- Small helpers
-- ===========================================================================

local function wname(part, n)
    return string.format("SDC_Coop%s_%d", part, n)
end

local function addr(o)
    if not ue.valid(o) then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

local function need(o, what)
    if not ue.valid(o) then error("missing widget " .. what, 0) end
    return o
end

local function set_color(t, c)
    if ue.valid(t) then pcall(function() t:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end) end
end

local function shown(w)
    if not ue.valid(w) then return false end
    local ok, inv = pcall(function() return w:IsInViewport() end)
    if ok and inv then return true end
    return ue.valid(ue.try(function() return w:GetParent() end))
end

-- A UMG widget in `outer` (the menu's WidgetTree), named when `name` is
-- given. Names are unique for the process, so StaticConstructObject never
-- replaces an existing object.
local function new_widget(short, outer, name)
    if not ue.valid(outer) then error("no outer for UMG." .. short, 0) end
    local o
    if name then
        o = StaticConstructObject(W.umg(short), outer, FName(name))
    else
        o = StaticConstructObject(W.umg(short), outer)
    end
    if not ue.valid(o) then error("cannot construct UMG." .. short .. " " .. tostring(name), 0) end
    return o
end

local function children(panel)
    local list = {}
    if not ue.valid(panel) then return list end
    local count = ue.try(function() return panel:GetChildrenCount() end) or 0
    for i = 0, count - 1 do
        if not ue.valid(panel) then break end
        local c = ue.try(function() return panel:GetChildAt(i) end)
        if ue.valid(c) then list[#list + 1] = c end
    end
    return list
end

-- The co-op buttons' labels made so far (main menu, pause menu): a language
-- change in the panel relabels them (M.relabel); gone ones are dropped.
local coop_texts = {}
local function keep_label(t)
    if not ue.valid(t) then return end
    for i = #coop_texts, 1, -1 do
        if not ue.valid(coop_texts[i]) then table.remove(coop_texts, i) end
    end
    coop_texts[#coop_texts + 1] = t
end

local function clone_text(src, label, outer, name)
    need(src, "text style")
    local t = new_widget("TextBlock", outer, name)
    pcall(function() t:SetFont(src.Font) end)
    pcall(function() t:SetColorAndOpacity(src.ColorAndOpacity) end)
    pcall(function() t:SetShadowOffset(src.ShadowOffset) end)
    pcall(function() t:SetShadowColorAndOpacity(src.ShadowColorAndOpacity) end)
    pcall(function() t:SetJustification(src.Justification) end)
    pcall(function() t:SetRenderTransform(src.RenderTransform) end)
    pcall(function() t:SetVisibility(W.SELF_HIT_TEST_INVISIBLE) end)
    pcall(function() t:SetText(FText(label or "")) end)
    return t
end

-- A UButton that looks like `orig` (style, focusability, text font, box
-- around the text), not inserted anywhere. Returns button, TextBlock.
-- IsFocusable must be set before the Slate widget exists: the game's menu
-- buttons are not focusable, so clicking them never takes keyboard focus
-- away from the menu (which would break its Esc handling).
local function make_button(orig, label, outer, name, text_name)
    need(orig, "button style")
    local b = new_widget("Button", outer, name)
    pcall(function() b:SetStyle(orig.WidgetStyle) end)
    pcall(function() b:SetColorAndOpacity(orig.ColorAndOpacity) end)
    pcall(function() b:SetBackgroundColor(orig.BackgroundColor) end)
    ue.set_prop(b, "IsFocusable", ue.prop(orig, "IsFocusable") == true)
    local content = ue.try(function() return orig:GetChildAt(0) end)
    local src_text = W.first_text(content)
    local t = nil
    if src_text then
        t = clone_text(src_text, label, outer, text_name)
        keep_label(t)
        local inner = t
        if ue.valid(content) and ue.class_name(content) ~= "TextBlock" then
            local box = new_widget(ue.class_name(content), outer)
            W.copy_slot(ue.prop(src_text, "Slot"), box:AddChild(t))
            inner = box
        end
        W.copy_slot(ue.prop(content, "Slot"), b:AddChild(inner))
    end
    return b, t
end

-- Live user widgets of a Blueprint class in this world that are in the
-- viewport, through the game's own WidgetBlueprintLibrary.GetAllWidgetsOfClass
-- (FindAllOf does not see them in this UE4SS build, and NotifyOnNewObject
-- only reported the CDO). Also the way to the HUD's own widgets: HUD_Game_C's
-- Blueprint variables (PauseMenu, NotificationUI) are not read by name, since
-- UE4SS 3.0.1 can hand out a freed property for a Blueprint class reloaded at
-- its old address after a level change (see W.child in sdc_widgets).
local live_classes = {}   -- [path] = the class object (checked by name on reuse)
local function live_widgets(path)
    local out = {}
    local wbl, wc = ue.widget_lib(), ue.local_pc() or ue.game_instance()
    local cls = live_classes[path]
    -- a class unloaded with its level: its address may hold another object now
    if not ue.valid(cls) or ue.short(cls) ~= path:match("%.([^%.]+)$") then
        cls = ue.find_object(path)
        live_classes[path] = cls
    end
    if not wbl or not wc or not ue.valid(cls) then return out end
    local arr = {}
    local ok = pcall(function() wbl:GetAllWidgetsOfClass(wc, arr, cls, true) end)
    if not ok then return out end
    for _, v in ipairs(arr) do
        local w = v
        if type(v) == "userdata" and not ue.valid(v) then w = ue.try(function() return v:get() end) end
        if ue.valid(w) and not ue.short(w):find("^Default__") then out[#out + 1] = w end
    end
    return out
end

-- The game's pause menu (PauseScreen_C, HUD_Game_C's PauseMenu) on screen.
local function hud_pause_menu()
    if not ue.local_pc() then return nil end
    for _, w in ipairs(live_widgets(PAUSE_CLASS)) do
        if shown(w) then return w end
    end
    return nil
end

-- ===========================================================================
-- Crash guard: lobby_build.marker exists while the first co-op button of a
-- kind (main menu / pause menu) is placed in this session, and for
-- MARKER_FRAMES frames after (Slate builds and paints it then). The lobby is
-- turned off only when two starts in a row ended there; the file holds the
-- number of earlier such starts. Later buttons of the same kind (a new
-- PauseScreen on every pause) are made the same way and skip the marker: no
-- file write and delete per pause.
-- ===========================================================================

local marker_path = nil
local marker_hits = 0      -- consecutive earlier starts that ended inside a placement
local marker_frames = 0
local marker_id = 0
local marker_done = {}     -- [kind] = true: a button of this kind was placed in this session

-- A placement that did not crash breaks the chain of hits.
local function marker_off()
    marker_frames = 0
    marker_hits = 0
    if marker_path then os.remove(marker_path) end
end

local function marker_on()
    if not marker_path then return end
    marker_id = marker_id + 1
    local f = io.open(marker_path, "w")
    if f then
        f:write(tostring(marker_hits), "\n")
        f:close()
    end
    marker_frames = MARKER_FRAMES
    local id = marker_id
    -- in case the frame tick is not running
    ue.delay("lobby-marker", MARKER_MAX_MS, function()
        if marker_id == id and marker_frames > 0 then marker_off() end
    end)
end

-- Every frame: the marker is kept for MARKER_FRAMES frames after a placement.
local function marker_frame()
    if marker_frames <= 0 then return end
    marker_frames = marker_frames - 1
    if marker_frames == 0 then marker_off() end
end

-- The main menu's co-op button above the game's buttons (coop_button_on_top)
-- has a marker of its own: a start that ended while the button was being
-- placed there, or in the TOP_MARKER_FRAMES frames after (Slate builds and
-- paints it then), leaves lobby_top.marker behind. While that file exists
-- the button stays at the bottom of the game's column (the plain clone that
-- is known to work); deleting the file lets the next start try the top again.
local top_marker_path = nil
local top_marker_frames = 0
local top_marker_id = 0
local top_off = nil   -- why the top placement is off for this session (nil: allowed)

local function top_marker(on)
    if not top_marker_path then return end
    if not on then
        top_marker_frames = 0
        os.remove(top_marker_path)
        return
    end
    local f = io.open(top_marker_path, "w")
    if f then
        f:write("SDCoop: the game ended while the co-op button was being placed at the top of the main menu.\n",
            "Delete this file to let the mod try that again.\n")
        f:close()
    end
    top_marker_frames = TOP_MARKER_FRAMES
    top_marker_id = top_marker_id + 1
    local id = top_marker_id
    -- in case the frame tick is not running
    ue.delay("lobby-top-marker", MARKER_MAX_MS, function()
        if top_marker_id == id and top_marker_frames > 0 then top_marker(false) end
    end)
end

local function top_marker_frame()
    if top_marker_frames <= 0 then return end
    top_marker_frames = top_marker_frames - 1
    if top_marker_frames == 0 then top_marker(false) end
end

-- ===========================================================================
-- Level changes
-- ===========================================================================

-- Level change (sdc_session.world_reset_hooks, our own LoadMap pre-hook or
-- the per-frame world check): the old world's widgets are destroyed right
-- after this, or already are, so nothing is touched here. The names of the
-- old world's menus never come back; a new controller in the SAME world
-- (no level change) keeps them, since its menus may still be up.
local function on_load_map(why)
    world_gen = world_gen + 1
    late = {}
    diag_left = 6
    watch_queue = {}
    drain_notifications()
    pending_conn = false
    scans_left = SCAN_BUDGET
    patched_menu = nil
    last_scan_sig = nil
    if why ~= "new controller" then simple_patched, menu_seen_at = {}, {} end
end

-- Without the LoadMap hook: a new world shows up as another UWorld object or
-- as its real time starting over. The GameViewportClient lives as long as
-- the engine, so it is the one object kept across levels.
local viewport_client = nil
local last_world, last_rt = nil, nil

local function find_viewport_client()
    if ue.valid(viewport_client) then return end
    viewport_client = nil
    for _, v in ipairs(ue.find_all("GameViewportClient")) do
        if ue.valid(v) and not ue.short(v):find("^Default__") then
            viewport_client = v
            return
        end
    end
end

local function world_changed()
    if not ue.valid(viewport_client) then return false end
    local world = ue.prop(viewport_client, "World")
    if not ue.valid(world) then return false end
    local a = addr(world)
    local rt = nil
    local gps = ue.gameplay_statics()
    if ue.valid(gps) and ue.valid(world) then
        local ok, v = pcall(function() return gps:GetRealTimeSeconds(world) end)
        if ok and type(v) == "number" then rt = v end
    end
    local changed = (last_world ~= nil and a ~= last_world)
        or (last_rt ~= nil and rt ~= nil and rt + 0.5 < last_rt)
    last_world = a
    if rt then last_rt = rt end
    return changed
end

local function queue_watch(kind, w)
    if M.disabled or #watch_queue >= 16 then return end
    -- the class default object is reported too; it is never on screen
    if ue.short(w):find("^Default__") then return end
    watch_queue[#watch_queue + 1] = { kind = kind, w = w, gen = world_gen, frames = 0 }
end

-- ===========================================================================
-- The co-op button
-- ===========================================================================

-- The label in the player's language (sdc_i18n), else the Russian one.
local function coop_label()
    local label = COOP_RU
    local oki, i18n = pcall(require, "sdc_i18n")
    if oki and type(i18n) == "table" and type(i18n.coop_label) == "function" then
        local okl, s = pcall(i18n.coop_label)
        if okl and type(s) == "string" and s ~= "" then label = s end
    end
    return label
end

function M.relabel()
    local label, n = coop_label(), 0
    for i = #coop_texts, 1, -1 do
        local t = coop_texts[i]
        if ue.valid(t) then
            if pcall(function() t:SetText(FText(label)) end) then n = n + 1 end
        else
            table.remove(coop_texts, i)
        end
    end
    if n > 0 then log.info("lobby: %d co-op button label(s) now '%s'", n, log.ascii(label)) end
    return n
end

local function open_coop_panel()
    local okp, e = pcall(function() require("sdc_ui").set_open(true) end)
    if not okp then log.err("lobby: co-op panel: %s", tostring(e)) end
end

local LAYOUT_KEYS = { "amin_x", "amin_y", "amax_x", "amax_y", "x", "y", "w", "h", "ax", "ay" }

-- Where the game's button column is, from its canvas slot. Only read:
-- nothing of the game's slot is written or copied anywhere.
-- Returns { anchors, position, size, alignment, z } or nil, why.
local function column_layout(column)
    local cs = ue.prop(column, "Slot")
    local cls = ue.class_name(cs)
    if cls ~= "CanvasPanelSlot" then
        return nil, "the button column's slot is " .. (cls ~= "" and cls or "missing") .. ", not a CanvasPanelSlot"
    end
    local ok, g = pcall(function()
        local a, p, s, al = cs:GetAnchors(), cs:GetPosition(), cs:GetSize(), cs:GetAlignment()
        return {
            amin_x = a.Minimum.X, amin_y = a.Minimum.Y, amax_x = a.Maximum.X, amax_y = a.Maximum.Y,
            x = p.X, y = p.Y, w = s.X, h = s.Y, ax = al.X, ay = al.Y,
        }
    end)
    if not ok or type(g) ~= "table" then
        return nil, "the button column's canvas slot could not be read: " .. tostring(g)
    end
    for _, key in ipairs(LAYOUT_KEYS) do
        local v = g[key]
        if type(v) ~= "number" or v ~= v or math.abs(v) > 100000 then
            return nil, "the button column's canvas slot has no usable " .. key
        end
    end
    if math.abs(g.amin_x - g.amax_x) > 0.001 or math.abs(g.amin_y - g.amax_y) > 0.001 then
        return nil, string.format("the button column is stretched (anchors %.2f,%.2f - %.2f,%.2f)",
            g.amin_x, g.amin_y, g.amax_x, g.amax_y)
    end
    if g.w < 100 or g.h < 60 then
        return nil, string.format("the button column is only %.0fx%.0f px", g.w, g.h)
    end
    local z = ue.try(function() return cs:GetZOrder() end)
    g.z = type(z) == "number" and z or 0
    return g
end

-- One row of the column: its Fill buttons share what its spacers leave.
local function column_row(column, h)
    local n, spacers = 0, 0
    for _, c in ipairs(children(column)) do
        if W.visible(c) then
            local cls = ue.class_name(c)
            if cls == "Button" then
                n = n + 1
            elseif cls == "Spacer" then
                local y = ue.try(function() return c.Size.Y end)
                spacers = spacers + ((type(y) == "number" and y >= 0 and y < 200) and y or 5)
            end
        end
    end
    local row = n > 0 and (h - spacers) / n or 40
    return math.max(ROW_MIN, math.min(ROW_MAX, row))
end

-- Main menu: "Кооператив" as a new child of the canvas that holds the
-- game's button column (MainMenu > Buttons), TOP_GAP px above that column,
-- as wide as it and one of its rows high. Only our own button is created,
-- added, laid out (plain setters with fresh numbers, nothing copied from
-- another slot) and, if it does not take its layout, removed again. The
-- game's widgets and slots are only read: nothing of theirs is moved,
-- removed, re-added or re-laid out. Returns true, how | false, why.
local function coop_button_on_top(w, orig, column, label)
    if top_off then return false, top_off end
    if ue.class_name(column) ~= "VerticalBox" then
        return false, "the game's buttons are not in a VerticalBox (" .. ue.class_name(column) .. ")"
    end
    local canvas = ue.try(function() return column:GetParent() end)
    if ue.class_name(canvas) ~= "CanvasPanel" then
        return false, "the button column's parent is not a CanvasPanel (" .. ue.class_name(canvas) .. ")"
    end
    local g, why = column_layout(column)
    if not g then return false, why end
    local outer = ue.try(function() return orig:GetOuter() end)
    if not ue.valid(outer) then return false, "no WidgetTree for a new button" end
    local row = column_row(column, g.h)
    -- the column's top edge is at anchor + y - ay * h; ours (alignment Y = 1:
    -- the position is our bottom edge) TOP_GAP above it, same left edge
    local x, y = g.x, g.y - g.ay * g.h - TOP_GAP
    seq = seq + 1
    local n = seq
    local b = nil
    top_marker(true)
    local ok, err = pcall(function()
        local t
        b, t = make_button(orig, label, outer, wname("TopButton", n), wname("TopText", n))
        need(t, "button text")
        set_color(t, ACCENT)
        -- hidden until it has its place (a new canvas child starts at the top-left corner)
        b:SetVisibility(W.COLLAPSED)
        need(canvas, "canvas")
        local s = canvas:AddChildToCanvas(b)
        need(s, "canvas slot")
        s:SetAnchors({ Minimum = { X = g.amin_x, Y = g.amin_y }, Maximum = { X = g.amax_x, Y = g.amax_y } })
        s:SetAlignment({ X = g.ax, Y = 1 })
        s:SetPosition({ X = x, Y = y })
        s:SetSize({ X = g.w, Y = row })
        pcall(function() s:SetAutoSize(false) end)
        pcall(function() s:SetZOrder(g.z) end)
        local p, z = s:GetPosition(), s:GetSize()
        if math.abs(p.X - x) > 1 or math.abs(p.Y - y) > 1 or math.abs(z.X - g.w) > 1 or math.abs(z.Y - row) > 1 then
            error(string.format("its canvas slot did not take the layout (at %.0f,%.0f, %.0fx%.0f px)",
                p.X, p.Y, z.X, z.Y), 0)
        end
        b:SetVisibility(W.VISIBLE)
        W.on_click(b, label, open_coop_panel, w)
    end)
    if not ok then
        -- our own button only is taken out again
        if ue.valid(b) then pcall(function() b:RemoveFromParent() end) end
        top_marker(false)
        return false, "placing it at the top failed: " .. tostring(err)
    end
    return true, string.format("%s in %s, %d px above %s, %.0fx%.0f px", ue.short(b), ue.short(canvas),
        TOP_GAP, ue.short(column), g.w, row)
end

-- Main menu fallback: a spacer of ours at the end of the game's column, so
-- the clone appended after it stands apart from the game's last button.
local function bottom_gap(column, orig)
    if not ue.valid(column) then return end
    local outer = ue.try(function() return orig:GetOuter() end)
    if not ue.valid(outer) then return end
    seq = seq + 1
    local n = seq
    local ok, err = pcall(function()
        local sp = new_widget("Spacer", outer, wname("Gap", n))
        pcall(function() sp:SetSize({ X = 1, Y = BOTTOM_GAP }) end)
        column:AddChild(sp)
    end)
    if not ok then log.warn("lobby: no gap above the co-op button: %s", tostring(err)) end
end

-- The co-op button in menu widget `w` (kind "menu" | "pause"), next to the
-- game's button `anchor_name`. apart (main menu): above the game's buttons
-- (coop_button_on_top), else at the bottom behind a gap; in the accent
-- colour either way. Returns "wait" (its tree is not up yet) | "done".
local function simple_coop_button(w, kind, anchor_name, what, apart)
    local k = ue.name(w)
    if simple_patched[k] then return "done" end
    local orig = W.child(w, anchor_name)
    if not ue.valid(orig) or not ue.valid(ue.prop(orig, "Slot")) then return "wait" end
    simple_patched[k] = true
    local column = ue.try(function() return orig:GetParent() end)
    local label = coop_label()
    local guard = not marker_done[kind]
    if guard then marker_on() end
    if apart then
        local okt, placed, how = pcall(coop_button_on_top, w, orig, column, label)
        if okt and placed == true then
            marker_done[kind] = true
            log.info("lobby: coop button placed at the top (%s)", tostring(how))
            return "done"
        end
        if not okt then
            top_marker(false)
            how = "error: " .. tostring(placed)
        end
        log.info("lobby: coop button kept at the bottom: %s", tostring(how))
    end
    local ok, err = pcall(function()
        if apart then bottom_gap(column, orig) end
        local b = W.clone_button(orig, label, open_coop_panel, nil, w)
        if apart then set_color(W.first_text(b), ACCENT) end
        keep_label(W.first_text(b))
    end)
    if ok then
        marker_done[kind] = true
        log.info("lobby: %s: co-op button added after %s (opens the co-op panel)", what, anchor_name)
    else
        if guard then marker_off() end
        log.err("lobby: %s: co-op button failed: %s", what, tostring(err))
    end
    return "done"
end

local function patch_menu(w)
    if M.disabled then return "skip" end
    if not shown(w) then return "wait" end
    -- a menu that is still starting up must not be touched (another co-op
    -- mod for this game crashed it that way): give it SETTLE_S on screen
    local mk = ue.name(w)
    if not menu_seen_at[mk] then
        menu_seen_at[mk] = os.clock()
        log.info("lobby: main menu on screen: %s", ue.short(w))
    end
    if os.clock() - menu_seen_at[mk] < SETTLE_S then return "wait" end
    local status = simple_coop_button(w, "menu", "Load", "main menu", true)
    if status == "done" then patched_menu = { w = w, key = mk } end
    return status
end

local function patch_pause(w)
    if M.disabled then return "skip" end
    if not shown(w) then return "wait" end
    return simple_coop_button(w, "pause", "Settings", "pause menu", false)
end

-- The main menu that got its button in this world, if it is still that
-- widget (same name) and on screen.
local function menu_done()
    local p = patched_menu
    if not p then return false end
    if ue.valid(p.w) and ue.name(p.w) == p.key and shown(p.w) then return true end
    patched_menu = nil
    return false
end

-- New menu widgets: patched on the first frame their tree is up (the pause
-- menu is created and added to the viewport in the same frame).
local function process_watch_queue()
    if #watch_queue == 0 then return end
    local q = watch_queue
    watch_queue = {}
    local keep = {}
    for _, e in ipairs(q) do
        e.frames = e.frames + 1
        local status = "skip"
        if e.gen == world_gen and e.frames > WATCH_FRAMES and ue.valid(e.w) then
            -- not on screen yet (loading): the 4 Hz tick keeps trying, since
            -- FindAllOf does not see these widgets in this UE4SS build
            late[#late + 1] = e
        end
        if e.gen == world_gen and e.frames <= WATCH_FRAMES and ue.valid(e.w) then
            if e.kind == "menu" then status = patch_menu(e.w) else status = patch_pause(e.w) end
        end
        if status == "wait" and e.gen == world_gen then keep[#keep + 1] = e end
    end
    -- entries queued while patching (same frame) are kept too
    for _, e in ipairs(watch_queue) do keep[#keep + 1] = e end
    watch_queue = keep
end

-- ===========================================================================
-- Game notifications
-- ===========================================================================

local notify_queue = {}
local notify_failures = 0
local gfl = nil

local function game_notification(text, seconds)
    if not M.use_game_notifications then return false end
    local pc = ue.local_pc()
    if not ue.valid(pc) then return false end
    local hud = ue.try(function() return pc:GetHUD() end)
    if ue.class_name(hud) ~= "HUD_Game_C" then return false end
    -- its notification box on screen (live_widgets: not read from the HUD by name)
    local parent = live_widgets(NOTIFY_CLASS)[1]
    if not shown(parent) then return false end
    if not ue.valid(gfl) then gfl = ue.find_object(GFL_CDO) end
    if not ue.valid(gfl) or not ue.valid(pc) then return false end
    -- (Message, Icon, Icon Colour, Delay, Force Notification?, WorldContext):
    -- not forced, so the game drops a copy of a message still on screen
    local ok, err = pcall(function()
        gfl:CreateNotificationUI(FText(text), nil, { R = 1, G = 1, B = 1, A = 1 }, seconds, false, pc)
    end)
    if not ok then
        notify_failures = notify_failures + 1
        log.warn("lobby: game notification failed (%d/3): %s", notify_failures, tostring(err))
        if notify_failures >= 3 then
            M.use_game_notifications = false
            log.warn("lobby: game notifications off, using the overlay toasts")
        end
    end
    return ok
end

local function to_fallback(n)
    if not M.fallback_sink then return end
    local ok, err = pcall(M.fallback_sink, n.text, n.kind, n.seconds)
    if not ok then log.err("lobby: fallback toast: %s", tostring(err)) end
end

-- A level change is coming: queued toasts go to the overlay (it survives the
-- change); the game's HUD would take them down with the old world.
drain_notifications = function()
    if #notify_queue == 0 then return end
    local q = notify_queue
    notify_queue = {}
    for _, n in ipairs(q) do to_fallback(n) end
end

local function flush_notifications()
    if #notify_queue == 0 then return end
    local q = notify_queue
    notify_queue = {}
    -- while a connection is pending the current world (and its HUD) is
    -- about to go away
    for _, n in ipairs(q) do
        if pending_conn or not game_notification(n.text, n.seconds) then to_fallback(n) end
    end
end

-- Shows `text` with the game's notification widget (next frame, game
-- thread); falls back to M.fallback_sink when there is no game HUD.
function M.notify(text, kind, seconds)
    if type(text) ~= "string" or text == "" then return end
    if kind == "err" or kind == "warn" then seconds = math.max(seconds or 6, 6) end
    notify_queue[#notify_queue + 1] = { text = text, kind = kind or "info", seconds = seconds or 5 }
    while #notify_queue > 8 do table.remove(notify_queue, 1) end
end

-- log.toast_sink = lobby.toast_sink(ui.toast)
function M.toast_sink(fallback)
    M.fallback_sink = fallback
    return function(text, kind, seconds)
        -- the game's notifications appear on the right, under the co-op
        -- panel: while it is open the mod's own toast (top centre) is used
        local okp, ui = pcall(require, "sdc_ui")
        if okp and type(ui) == "table" and ui.open and fallback then
            fallback(text, kind, seconds)
            return
        end
        M.notify(text, kind, seconds)
    end
end

-- ===========================================================================
-- Install / ticks
-- ===========================================================================

local installed = false

function M.install(mod_dir)
    if installed then return end
    installed = true
    if cfg.get("lobby") == false then
        M.disabled = true
        log.info("lobby: off (config lobby = false)")
        return
    end
    marker_path = (mod_dir or "ue4ss/Mods/SDCoop") .. "/lobby_build.marker"
    local f = io.open(marker_path, "r")
    if f then
        local line = f:read("*l")
        f:close()
        os.remove(marker_path)
        local hits = (tonumber(line or "") or 0) + 1
        if hits >= 2 then
            M.disabled = true
            marker_hits = 0
            log.err("lobby: %d starts in a row ended while a co-op button was being placed; the lobby is off "
                .. "for this session (F7 menu and console commands still work)", hits)
        else
            marker_hits = hits
            log.warn("lobby: the previous start ended while a co-op button was being placed (%d/2); "
                .. "the lobby stays on", hits)
        end
    end
    -- the main menu's co-op button stays at the bottom while this file exists
    top_marker_path = (mod_dir or "ue4ss/Mods/SDCoop") .. "/lobby_top.marker"
    local tf = io.open(top_marker_path, "r")
    if tf then
        tf:close()
        top_off = "a start ended while it was being placed at the top "
            .. "(delete lobby_top.marker in the mod folder to try the top again)"
        log.warn("lobby: the main menu's co-op button stays at the bottom: %s", top_off)
    end

    -- NotifyOnNewObject fires inside the construction: only queue the widget
    -- (the callback returns nothing; true would unregister it)
    local function watch(kind, path)
        local ok, err = pcall(NotifyOnNewObject, path, function(w)
            queue_watch(kind, w)
        end)
        log.info("lobby: watch %s %s%s", path:match("[^%.]+$"), ok and "ok" or "unavailable (polling)",
            ok and "" or (" " .. tostring(err)))
    end
    watch("menu", MENU_CLASS)
    watch("pause", PAUSE_CLASS)

    -- Level changes: sdc_session's world reset (main.lua's LoadMap pre-hook,
    -- with a 1 s tick fallback) when it has one, else our own LoadMap
    -- pre-hook. Without any LoadMap hook the frame tick also compares worlds.
    local reg = rawget(_G, "RegisterLoadMapPreHook")
    local hooks = rawget(session, "world_reset_hooks")
    if type(hooks) == "table" then
        hooks.lobby = function(why) on_load_map(why) end
        loadmap_hooked = type(reg) == "function"
        log.info("lobby: level changes via sdc_session world reset (LoadMap hook %s)",
            loadmap_hooked and "available" or "unavailable, per-frame world check on")
    elseif type(reg) == "function" then
        local ok, err = pcall(reg, function()
            local okc, errc = pcall(on_load_map, "level change")
            if not okc then log.err("lobby: load map: %s", tostring(errc)) end
        end)
        loadmap_hooked = ok
        log.info("lobby: load map hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    else
        log.warn("lobby: RegisterLoadMapPreHook unavailable, using the per-frame world check")
    end
end

-- Live main menu widgets of this world (live_widgets).
local function live_menus()
    return live_widgets(MENU_CLASS)
end

-- The main menu widget on screen, or nil (sdc_session: the menu's Continue
-- after reopening a single-player world for friends; sdc_ui: the real main
-- menu, since ue.in_main_menu() is also true while the player is dead).
function M.live_main_menu()
    for _, w in ipairs(live_menus()) do
        if shown(w) then return w end
    end
    return nil
end

-- 4 Hz: polling fallbacks for menus without their button.
function M.slow_tick()
    if M.disabled then return end
    tick_n = tick_n + 1
    if not loadmap_hooked and tick_n % 8 == 1 then find_viewport_client() end

    local in_menu = ue.in_main_menu()
    -- the main menu has its button: nothing to look for while it is up
    local menu_ok = in_menu and menu_done()
    -- diagnosis while the main menu stays unpatched (a few lines per world)
    if in_menu and not menu_ok and tick_n % 20 == 0 and diag_left > 0 then
        diag_left = diag_left - 1
        local list, info = ue.find_all("MenuWidget_C"), {}
        for _, e in ipairs(late) do
            if e.kind == "menu" and e.gen == world_gen and ue.valid(e.w) then list[#list + 1] = e.w end
        end
        for _, w in ipairs(list) do
            if ue.valid(w) and not ue.short(w):find("^Default__") then
                local load = W.child(w, "Load")
                info[#info + 1] = string.format("%s shown=%s load=%s slot=%s", ue.short(w), tostring(shown(w)),
                    tostring(ue.valid(load)), tostring(ue.valid(load) and ue.valid(ue.prop(load, "Slot"))))
            end
        end
        log.info("lobby: main menu not patched yet: %d MenuWidget_C [%s] scans_left=%d queue=%d gen=%d",
            #list, table.concat(info, "; "), scans_left, #watch_queue, world_gen)
        -- the game's own enumeration of live widgets of this world
        local found = live_menus()
        local parts = {}
        for _, w in ipairs(found) do parts[#parts + 1] = ue.short(w) .. " shown=" .. tostring(shown(w)) end
        log.info("lobby: GetAllWidgetsOfClass(MenuWidget_C): %d [%s]", #found, table.concat(parts, "; "))
    end
    -- one object scan per second, and only where a connection can be pending
    if tick_n % 4 == 0 then pending_conn = in_menu and ue.has_pending_connection() or false end

    -- watched menus that were not on screen in time (no object scan needed)
    if in_menu and not menu_ok and #late > 0 then
        local keep = {}
        for _, e in ipairs(late) do
            if e.gen == world_gen and ue.valid(e.w) then
                local status = "wait"
                if not patched_menu and shown(e.w) then
                    if e.kind == "menu" then status = patch_menu(e.w) else status = patch_pause(e.w) end
                end
                if status == "wait" then keep[#keep + 1] = e end
            end
        end
        late = keep
    end

    if in_menu and not menu_ok and not patched_menu and tick_n % SCAN_EVERY == 0 and scans_left > 0 then
        scans_left = scans_left - 1
        local cands = live_menus()
        for _, w in ipairs(ue.find_all("MenuWidget_C")) do cands[#cands + 1] = w end
        local n_all, n_shown = 0, 0
        for _, w in ipairs(cands) do
            if ue.valid(w) and not ue.short(w):find("^Default__") then
                n_all = n_all + 1
                if shown(w) then
                    n_shown = n_shown + 1
                    if patch_menu(w) == "done" then break end
                end
            end
        end
        local sig = n_all .. "/" .. n_shown
        if sig ~= last_scan_sig then
            last_scan_sig = sig
            log.info("lobby: scan: %d main menu widget(s), %d on screen", n_all, n_shown)
        end
    end

    if not in_menu then
        local pm = hud_pause_menu()
        if pm and shown(pm) then patch_pause(pm) end
    end
end

-- Every frame (wire it BEFORE widgets.frame_tick): notifications, crash
-- markers, new menus.
function M.frame_tick()
    marker_frame()
    top_marker_frame()
    -- without a LoadMap hook: notice a new world before anything is touched
    if not M.disabled and not loadmap_hooked and world_changed() then on_load_map("world changed") end
    flush_notifications()
    if M.disabled then return end
    process_watch_queue()
end

-- For sdc_ui: true while the game's pause menu is on screen (fresh lookup,
-- nothing cached).
function M.pause_menu_shown()
    local pm = hud_pause_menu()
    return pm ~= nil and shown(pm)
end

return M
