-- SDCoop: the co-op lobby inside the game's own menus (stage 5).
--
-- Nothing here is an overlay: every page is built into the game's widget
-- trees from copies of the game's own widgets (styles, fonts and slot layouts
-- are read from existing widgets at runtime, see work\re\pseudo\*.tree.txt).
--
--   Main menu (MenuWidget_C)
--     Buttons (VerticalBox)  ... Load, [spacer], "Кооператив", Modes ...
--     MenuOverlay
--       SDC_CoopPage_<n> (CanvasPanel, built like GameModeSelectionWidget)
--         BackgroundBlur                     (copy of BackgroundBlur_45)
--         ScaleBox > VerticalBox             (copy of ScaleBox_3 / Buttons_1)
--           title, "Открыть мир для друзей", "Подключиться" + IP:port field,
--           session status
--         ButtonWidget_C "[Esc] Назад"       (like ButtonWidget_BackFromGameModeSelect)
--
--   Pause menu (PauseScreen_C)
--     VerticalBox_59  ... Settings, "Кооператив", ...
--     CanvasPanel_0
--       SDC_CoopPage_<n> (CanvasPanel, built like SuicideWidget)
--         main view: title, status, players, hint, action button
--         confirm view: question + YES/NO ButtonWidget_C (like SuicideWidget)
--         ButtonWidget_C "[Esc] Назад"
--
-- Widget lifetime (the rules this file is written around):
--   * The HUD creates a NEW PauseScreen_C on every pause (HUD_Game 340-420)
--     and the main menu is recreated on every level open, so no wrapper is
--     kept longer than the menu it belongs to is on screen.
--   * Every widget this module adds is named SDC_Coop<Part>_<n>, n unique for
--     the process. "Is this menu patched?" is answered from the live widget
--     tree (find_page), never from a table keyed by addresses. A page that
--     lost its Lua state is re-attached by name (bind_*).
--   * The page state (menu / pause), its click entries and the queue of new
--     menus are dropped: on every level change (sdc_session.world_reset_hooks,
--     called from main.lua's LoadMap pre-hook; own LoadMap hook / per-frame
--     world check without it), before every travel started from a lobby
--     button, and on the first frame the menu is off screen.
--
-- Opening a page hides the game's button panel (MainMenu / PauseWidget), as
-- the game's own sub-pages do. Esc: the game's key handlers close the first
-- *visible* sub-page they know about. While a co-op page is open one of
-- those pages (RoadmapImg / SuicideWidget) is made a "decoy": hit-test
-- invisible with zero opacity. Esc then makes the game hide the decoy and
-- show its button panel again, which the frame tick sees and closes the
-- co-op page. Clicks are polled (sdc_widgets.on_click), there are no
-- delegate bindings.
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
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local CLICK_CUE = "/Game/Audio/SurvivalSoundPack/Cues/UI_click_sound_Cue.UI_click_sound_Cue"
-- The pause menu's own "quit to main menu: YES" handler (closes the server).
local QUIT_YES_EVENT = "BndEvt__PauseScreen_QuitToMainMenuYesButton_K2Node_ComponentBoundEvent_5_ButtonPressed__DelegateSignature"

local HALIGN_FILL, HALIGN_CENTER = 0, 2
local VALIGN_FILL, VALIGN_CENTER = 0, 2
local SIZE_FILL = 1
local JUSTIFY_CENTER = 1

local WATCH_FRAMES = 240      -- frames a new menu widget is watched until its tree is up
local MARKER_FRAMES = 45      -- frames the crash marker outlives a build
local MARKER_MAX_MS = 10000   -- ... or this long when the frame tick does not run
local TRAVEL_HOLD_S = 5       -- seconds a travel started here may take to reach LoadMap
-- The real MenuWidget_C only exists after the PRESS ANY KEY screen, which can
-- take any time: scan once a second for as long as the main menu is up
-- without a patched menu (a single-class FindAllOf, main menu only).
local SCAN_BUDGET = 100000    -- fallback scans for the main menu per world
local SCAN_EVERY = 4          -- slow ticks between those scans (1 s)
local SETTLE_S = 1.5          -- a new menu stays untouched this long after it is on screen
local PAUSE_CELL = 47         -- px per pause button (the game: 395 px for 8 buttons)
local MAX_FAILS = 2           -- consecutive failed builds before a page kind is off

-- On-screen text (Russian). Logs stay English.
local L = {
    coop         = "Кооператив",
    title        = "Кооператив",
    host         = "Открыть мир для друзей",
    host_desc    = "Главное меню перезапустится как сервер (порт 7777, UDP). "
                .. "Затем загрузите сохранение как обычно: Continue или Load.",
    join         = "Подключиться",
    join_cancel  = "Отменить подключение",
    join_desc    = "Адрес хоста в виде IP:порт — внешний IP или адрес из Radmin VPN / ZeroTier.",
    join_hint    = "например 127.0.0.1:7777",
    back         = "[Esc] Назад",
    yes          = "ДА",
    no           = "НЕТ",
    disconnect   = "Отключиться",
    disconnect_q = "Отключиться от сервера?\nВы вернётесь в главное меню.",
    close_world  = "Закрыть мир",
    close_q      = "Закрыть мир и выйти в главное меню?\n"
                .. "Игроки будут отключены, несохранённый прогресс будет потерян.",
    open_world   = "Открыть мир для друзей",
    client_hint  = "Вы играете в мире хоста. Мир сохраняет хост.",
    host_hint    = "Мир открыт для друзей, пока вы в игре. «Закрыть мир» отключит игроков "
                .. "и вернёт вас в главное меню — перед этим сохранитесь.",
    solo_hint    = "Этот мир закрыт для друзей. Нажмите «Открыть мир для друзей», сохранитесь "
                .. "и выйдите в главное меню: меню откроется как сервер, затем загрузите сохранение.",
}
M.TEXT = L

local COLOR = {
    white = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    dim   = { R = 0.80, G = 0.80, B = 0.80, A = 1.0 },
    ok    = { R = 0.45, G = 0.92, B = 0.52, A = 1.0 },
    warn  = { R = 1.0, G = 0.82, B = 0.32, A = 1.0 },
}

-- Live page state, for the current world only (see the header).
local menu = nil
local pause = nil
local seq = 0                    -- page number n of the names SDC_Coop<Part>_<n>
local page_info = {}             -- [n] = { h0 = number }: plain numbers, never wrappers
local fail_streak = { menu = 0, pause = 0 }
local watch_queue = {}           -- new menu widgets waiting for their tree (this world only)
local diag_left = 6              -- "main menu not patched yet" lines
local late = {}                  -- watched widgets of this world not on screen within WATCH_FRAMES
local world_gen = 0
local tick_n = 0
local scans_left = SCAN_BUDGET
local travel_until = 0           -- os.time() until which a travel started here is pending
local pending_conn = false       -- cached ue.has_pending_connection() (an object scan)
local index_logged = {}
local loadmap_hooked = false
local click_cue = nil

-- forward declarations
local close_menu_page, close_pause_page, drain_notifications

-- ===========================================================================
-- Small helpers
-- ===========================================================================

local function noop() end

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

local function set_vis(w, v)
    if ue.valid(w) then pcall(function() w:SetVisibility(v) end) end
end

local function set_text(t, s)
    if ue.valid(t) then pcall(function() t:SetText(FText(s or "")) end) end
end

local function set_color(t, c)
    if ue.valid(t) then pcall(function() t:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end) end
end

-- Only ever used on our own TextBlocks: t.Font is t's own struct.
local function set_font_size(t, size)
    if not ue.valid(t) then return end
    pcall(function()
        local f = t.Font
        f.Size = size
        t:SetFont(f)
    end)
end

local function set_wrap(t, at)
    if ue.valid(t) then pcall(function() t.WrapTextAt = at end) end
end

local function shown(w)
    if not ue.valid(w) then return false end
    local ok, inv = pcall(function() return w:IsInViewport() end)
    if ok and inv then return true end
    return ue.valid(ue.try(function() return w:GetParent() end))
end

local function focus(w)
    if ue.valid(w) then pcall(function() w:SetFocus() end) end
end

-- Widget `name` anywhere in the user widget's tree (runtime-added ones too).
local function find_named(uw, name)
    if not ue.valid(uw) then return nil end
    local o = W.child(uw, name)
    if ue.valid(o) then return o end
    return nil
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

local function children_of_class(panel, class)
    local out = {}
    for _, c in ipairs(children(panel)) do
        if ue.class_name(c) == class then out[#out + 1] = c end
    end
    return out
end

-- Our page among the panel's children: widget, page number.
local function find_page(panel)
    for _, c in ipairs(children(panel)) do
        local n = tonumber(ue.short(c):match("^SDC_CoopPage_(%d+)$"))
        if n then return c, n end
    end
    return nil, nil
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

local function text_like(src, label, outer, size, wrap, name)
    local t = clone_text(src, label, outer, name)
    if size then set_font_size(t, size) end
    pcall(function() t:SetJustification(JUSTIFY_CENTER) end)
    pcall(function() t:SetRenderTranslation({ X = 0, Y = 0 }) end)
    if wrap then set_wrap(t, wrap) end
    return t
end

local function vadd(vb, w, top, bottom, halign)
    need(vb, "box")
    need(w, "box child")
    local s = vb:AddChild(w)
    if ue.valid(s) then
        pcall(function() s:SetPadding({ Left = 0, Top = top or 0, Right = 0, Bottom = bottom or 0 }) end)
        pcall(function() s:SetHorizontalAlignment(halign or HALIGN_CENTER) end)
    end
    return s
end

local function canvas_fill(slot, z)
    if not ue.valid(slot) then return end
    pcall(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } }) end)
    pcall(function() slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
    if z then pcall(function() slot:SetZOrder(z) end) end
end

local function canvas_point(slot, ax, ay, alx, aly, x, y, z)
    if not ue.valid(slot) then return end
    pcall(function() slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } }) end)
    pcall(function() slot:SetAlignment({ X = alx, Y = aly }) end)
    pcall(function() slot:SetPosition({ X = x or 0, Y = y or 0 }) end)
    pcall(function() slot:SetAutoSize(true) end)
    if z then pcall(function() slot:SetZOrder(z) end) end
end

-- Slot layout from the game's widget `src` when it exists, else `fallback`.
local function layout(dst_slot, src, fallback)
    if not ue.valid(dst_slot) then return end
    local s = ue.prop(src, "Slot")
    if ue.valid(s) then
        W.copy_slot(s, dst_slot)
    elseif fallback then
        fallback(dst_slot)
    end
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

-- A ButtonWidget_C (the game's "[Esc] Back" / YES / NO buttons) like `orig`.
-- Text / TextSize are applied by its PreConstruct when it is attached.
-- (WidgetBlueprintLibrary.Create takes no name: these are found by class.)
local function make_game_button(orig, label)
    if not ue.valid(orig) then return nil end
    local pc, wbl = ue.local_pc(), ue.widget_lib()
    if not ue.valid(pc) or not ue.valid(wbl) then return nil end
    local cls = ue.try(function() return orig:GetClass() end)
    if not ue.valid(cls) then return nil end
    local bw = ue.try(function() return wbl:Create(pc, cls, pc) end)
    if not ue.valid(bw) then return nil end
    pcall(function() bw.Text = FText(label) end)
    local size = ue.prop(orig, "TextSize")
    if type(size) == "number" then ue.set_prop(bw, "TextSize", size) end
    return bw
end

-- After attaching: make sure the label is ours even if setting the Text
-- property did not work.
local function fix_game_button(bw, label)
    local t = ue.prop(bw, "ButtonText")
    if ue.valid(t) then pcall(function() t:SetText(FText(label)) end) end
end

-- Text field styled to fit the game: dark translucent box, Montserrat.
local function make_input(font_src, outer, size, hint, name)
    local e = new_widget("EditableTextBox", outer, name)
    pcall(function() e:SetHintText(FText(hint or "")) end)
    local font = ue.prop(font_src, "Font")
    if font then
        pcall(function() e.WidgetStyle.TextStyle.Font.FontObject = font.FontObject end)
        pcall(function() e.WidgetStyle.TextStyle.Font.TypefaceFontName = font.TypefaceFontName end)
    end
    pcall(function() e.WidgetStyle.TextStyle.Font.Size = size end)
    pcall(function() e.WidgetStyle.Padding = { Left = 18, Top = 8, Right = 18, Bottom = 8 } end)
    pcall(function() e.WidgetStyle.BackgroundColor = { SpecifiedColor = { R = 0.0, G = 0.0, B = 0.0, A = 0.6 }, ColorUseRule = 0 } end)
    pcall(function() e.WidgetStyle.ForegroundColor = { SpecifiedColor = COLOR.white, ColorUseRule = 0 } end)
    pcall(function() e.WidgetStyle.FocusedForegroundColor = { SpecifiedColor = COLOR.white, ColorUseRule = 0 } end)
    pcall(function() e:SetForegroundColor(COLOR.white) end)
    pcall(function() e:SetJustification(JUSTIFY_CENTER) end)
    -- Enter must not drop keyboard focus out of the menu (Esc would stop working)
    ue.set_prop(e, "ClearKeyboardFocusOnCommit", false)
    return e
end

local function visible_buttons(panel)
    local n = 0
    for _, c in ipairs(children(panel)) do
        if ue.class_name(c) == "Button" and W.visible(c) then n = n + 1 end
    end
    return n
end

-- Height of a canvas-slotted panel.
local function panel_height(panel)
    local slot = ue.prop(panel, "Slot")
    if not ue.valid(slot) then return nil end
    local ok, y = pcall(function() return slot:GetSize().Y end)
    if ok and type(y) == "number" then return y end
    return nil
end

-- keep_bottom keeps the bottom edge where it was (bottom-aligned panels).
local function set_panel_height(panel, h, keep_bottom)
    local slot = ue.prop(panel, "Slot")
    if not ue.valid(slot) or type(h) ~= "number" then return false end
    local ok, err = pcall(function()
        local size = slot:GetSize()
        local sx, sy = size.X, size.Y
        if math.abs(sy - h) < 0.5 then return end
        if keep_bottom then
            local pos = slot:GetPosition()
            local px, py = pos.X, pos.Y
            local ay = 0.5
            pcall(function() ay = slot:GetAlignment().Y end)
            slot:SetPosition({ X = px, Y = py + (ay - 1) * (h - sy) })
        end
        slot:SetSize({ X = sx, Y = h })
    end)
    if not ok then log.warn("lobby: could not resize %s: %s", ue.short(panel), tostring(err)) end
    return ok
end

local function play_click()
    if not ue.valid(click_cue) then click_cue = ue.find_object(CLICK_CUE) end
    local gs, pc = ue.gameplay_statics(), ue.local_pc()
    if ue.valid(click_cue) and ue.valid(gs) and ue.valid(pc) then
        pcall(function() gs:PlaySound2D(pc, click_cue, 1, 1, 0, nil, nil, true) end)
    end
end

local function status_color(s)
    if s.role == "host" or s.role == "client" then return COLOR.ok end
    if s.title and s.title:find("Подключение", 1, true) then return COLOR.warn end
    return COLOR.white
end

local function safe_status()
    local ok, s = pcall(session.status)
    if ok and type(s) == "table" then return s end
    return { role = "unknown", title = "", lines = {} }
end

-- "ip", "ip:port" -> ip, port|nil
local function parse_address(s)
    s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local host, port = s:match("^(.-):(%d+)$")
    if host and host ~= "" and not host:find(":", 1, true) then return host, tonumber(port) end
    return s, nil
end

local function hud_pause_menu()
    local pc = ue.local_pc()
    if not ue.valid(pc) then return nil end
    local hud = ue.try(function() return pc:GetHUD() end)
    if not ue.valid(hud) then hud = ue.prop(pc, "MyHUD") end
    local pm = ue.prop(hud, "PauseMenu")
    if ue.valid(pm) then return pm end
    return nil
end

-- ===========================================================================
-- Inserting into a box at a position
-- ===========================================================================
-- UPanelWidget::ShiftChild is not a UFUNCTION (editor-only in the engine), so
-- Lua cannot move a child. The siblings that follow the anchor are taken out
-- and added back behind the new widgets, with their slot layout restored.
-- The game's buttons keep their bindings: those live on the UButton.

-- Plain-Lua copy of a box slot's layout (the slot object goes away when its
-- widget is removed from the panel).
local function snapshot_slot(s)
    if not ue.valid(s) then return nil end
    local snap = {}
    pcall(function()
        local p = s.Padding
        local l, t, r, b = p.Left, p.Top, p.Right, p.Bottom
        if type(l) == "number" and type(t) == "number" and type(r) == "number" and type(b) == "number" then
            snap.Padding = { Left = l, Top = t, Right = r, Bottom = b }
        end
    end)
    pcall(function()
        local h = s.HorizontalAlignment
        if type(h) == "number" then snap.HorizontalAlignment = h end
    end)
    pcall(function()
        local v = s.VerticalAlignment
        if type(v) == "number" then snap.VerticalAlignment = v end
    end)
    pcall(function()
        local z = s.Size
        local value, rule = z.Value, z.SizeRule
        if type(value) == "number" and type(rule) == "number" then
            snap.Size = { Value = value, SizeRule = rule }
        end
    end)
    return snap
end

local function apply_slot(s, snap)
    if not snap or not ue.valid(s) then return end
    if snap.Padding then pcall(function() s:SetPadding(snap.Padding) end) end
    if snap.HorizontalAlignment then pcall(function() s:SetHorizontalAlignment(snap.HorizontalAlignment) end) end
    if snap.VerticalAlignment then pcall(function() s:SetVerticalAlignment(snap.VerticalAlignment) end) end
    if snap.Size then pcall(function() s:SetSize(snap.Size) end) end
end

local REORDER_GAME_WIDGETS = false

-- items: { { w = new widget, layout = game widget whose slot layout to copy }, ... }
local function insert_after(parent, after, items, what)
    need(parent, "panel")
    need(after, "anchor widget")
    local idx = ue.try(function() return parent:GetChildIndex(after) end)
    if type(idx) ~= "number" or idx < 0 then error("anchor is not in its panel", 0) end
    local moved = {}
    local count = ue.try(function() return parent:GetChildrenCount() end) or 0
    for i = idx + 1, count - 1 do
        local c = ue.try(function() return parent:GetChildAt(i) end)
        if ue.valid(c) then moved[#moved + 1] = { w = c, slot = snapshot_slot(ue.prop(c, "Slot")) } end
    end
    -- the new widgets first: if one fails, the game's widgets are untouched
    for _, it in ipairs(items) do
        need(it.w, "new widget")
        local s = parent:AddChild(it.w)
        if ue.valid(s) and ue.valid(it.layout) then W.copy_slot(ue.prop(it.layout, "Slot"), s) end
    end
    -- then the game's widgets, in their order, behind them. Off for now:
    -- removing and re-adding the game's own buttons while the pause screen
    -- was coming up (and sdc_players hid some of them) crashed the host
    -- (EXCEPTION_ACCESS_VIOLATION on Esc). The new widgets stay at the end.
    if not REORDER_GAME_WIDGETS then moved = {} end
    local failed = 0
    for _, m in ipairs(moved) do
        local ok = false
        if ue.valid(m.w) and ue.valid(parent) then
            ok = pcall(function()
                parent:RemoveChild(m.w)
                apply_slot(parent:AddChild(m.w), m.slot)
            end)
        end
        if not ok then failed = failed + 1 end
    end
    if failed > 0 then
        log.err("lobby: %s: %d of the game's widgets could not be put back after the insert", what, failed)
    end
    if not index_logged[what] then
        index_logged[what] = true
        local parts = {}
        for _, it in ipairs(items) do
            local i = ue.valid(it.w) and ue.try(function() return parent:GetChildIndex(it.w) end)
            parts[#parts + 1] = string.format("%s@%s", ue.short(it.w), tostring(i))
        end
        local ai = ue.try(function() return parent:GetChildIndex(after) end)
        log.info("lobby: %s: inserted after %s@%s -> %s (%d moved back, %d children)", what, ue.short(after),
            tostring(ai), table.concat(parts, " "), #moved,
            ue.try(function() return parent:GetChildrenCount() end) or -1)
    end
end

-- ===========================================================================
-- Crash guard: a marker file exists while a page is being built and painted.
-- The lobby is turned off only when two starts in a row ended inside a build.
-- The file holds the number of earlier such starts.
-- ===========================================================================

local marker_path = nil
local marker_hits = 0      -- consecutive earlier starts that ended inside a build
local marker_frames = 0
local marker_id = 0

-- A build that did not crash breaks the chain of hits.
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

-- Every frame: Slate builds and paints new widgets on the next frames, so
-- the marker is kept for MARKER_FRAMES frames after a build.
local function marker_frame()
    if marker_frames <= 0 then return end
    marker_frames = marker_frames - 1
    if marker_frames == 0 then marker_off() end
end

-- ===========================================================================
-- Page state lifetime
-- ===========================================================================

-- Polled click on `button`, owned by the page's screen (st.w): sdc_widgets
-- also stops polling it by itself once that screen leaves the viewport.
local function register_click(st, button, label, fn)
    if not ue.valid(button) or not ue.valid(st.w) then return end
    W.on_click(button, label, function(...)
        if not st.dead then fn(...) end
    end, st.w)
    local last = type(W.buttons) == "table" and W.buttons[#W.buttons] or nil
    if type(last) == "table" and rawequal(last.w, button) then
        st.entries[#st.entries + 1] = last
    end
end

-- Retires the page's click entries. Our own entries are marked dead and
-- cleared without touching any UObject (this also works from inside a click
-- being handled); W.forget(screen) is asked as well while the screen is
-- alive. `no_touch`: the world may be gone already, touch nothing.
local function drop_clicks(st, no_touch)
    for _, e in ipairs(st.entries or {}) do
        e.dead, e.w, e.fn, e.owner = true, nil, noop, nil
    end
    st.entries = {}
    if W.forget and not no_touch and ue.valid(st.w) then
        local ok, err = pcall(W.forget, st.w)
        if not ok then log.warn("lobby: W.forget: %s", tostring(err)) end
    end
end

-- Drops every wrapper a page state holds. `tidy` (the menu widget is still
-- alive, only off screen) first gives the game its widgets back.
local function forget(st, why, tidy, no_touch)
    if not st or st.dead then return end
    if tidy and not no_touch and st.open and ue.valid(st.w) then
        if st.kind == "menu" then close_menu_page(st, why) else close_pause_page(st, why, true) end
    end
    st.dead = true
    drop_clicks(st, no_touch)
    local keys = {}
    for k, v in pairs(st) do
        local t = type(v)
        if t == "userdata" or t == "table" then keys[#keys + 1] = k end
    end
    for _, k in ipairs(keys) do st[k] = nil end
    if menu == st then menu = nil end
    if pause == st then pause = nil end
    log.info("lobby: %s page %s released (%s)", tostring(st.kind), tostring(st.n), why)
end

local function forget_all(why, no_touch)
    forget(menu, why, false, no_touch)
    forget(pause, why, false, no_touch)
    menu, pause = nil, nil
    watch_queue = {}
    click_cue = nil
end

-- Before a level change this module starts itself. Nothing is re-attached
-- until LoadMap (which ends the hold) or TRAVEL_HOLD_S seconds.
local function begin_travel(why)
    forget_all(why)
    travel_until = os.time() + TRAVEL_HOLD_S
    drain_notifications()
end

-- Level change (sdc_session.world_reset_hooks, our own LoadMap pre-hook or
-- the per-frame world check): the old world's widgets are destroyed right
-- after this, or already are, so nothing is touched here.
local function on_load_map(why)
    world_gen = world_gen + 1
    late = {}
    diag_left = 6
    forget_all(why or "level change", true)
    drain_notifications()
    travel_until = 0
    pending_conn = false
    scans_left = SCAN_BUDGET
    page_info = {}
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
-- Building a page (with the crash guard) or re-attaching to one
-- ===========================================================================

local function undo_build(st)
    local added = st.added or {}
    for i = #added, 1, -1 do
        local w = added[i]
        if ue.valid(w) then pcall(function() w:RemoveFromParent() end) end
    end
    st.added = {}
    if st.grow_h0 and ue.valid(st.grow_target) then
        set_panel_height(st.grow_target, st.grow_h0, st.grow_keep_bottom)
    end
end

local function guarded_build(what, st, build)
    marker_on()
    local ok, err = pcall(build, st)
    if ok then
        fail_streak[st.kind] = 0
        return true
    end
    pcall(undo_build, st)
    forget(st, "build failed")
    marker_off()
    fail_streak[st.kind] = fail_streak[st.kind] + 1
    log.err("lobby: %s patch failed (%d/%d), the game's menu is left as is: %s",
        what, fail_streak[st.kind], MAX_FAILS, tostring(err))
    if fail_streak[st.kind] >= MAX_FAILS then
        log.err("lobby: the %s page is off for this session", what)
    end
    return false
end

local function adopt(what, st, bind)
    local ok, err = pcall(bind, st)
    if not ok then
        forget(st, "re-attach failed")
        fail_streak[st.kind] = fail_streak[st.kind] + 1
        log.err("lobby: could not re-attach to the %s page %d (%d/%d): %s",
            what, st.n, fail_streak[st.kind], MAX_FAILS, tostring(err))
        return "skip"
    end
    if st.kind == "menu" then menu = st else pause = st end
    log.info("lobby: %s page %d re-attached (%s)", what, st.n, ue.short(st.w))
    return "done"
end

-- ===========================================================================
-- Decoy sub-page for Esc (see the header)
-- ===========================================================================

local function decoy_on(st)
    if not ue.valid(st.decoy) or W.visible(st.decoy) then return end
    st.decoy_opacity = ue.try(function() return st.decoy:GetRenderOpacity() end) or 1
    if ue.valid(st.decoy) then pcall(function() st.decoy:SetRenderOpacity(0) end) end
    set_vis(st.decoy, W.HIT_TEST_INVISIBLE)
    st.decoy_active = true
end

local function decoy_off(st)
    if not st.decoy_active then return end
    st.decoy_active = false
    if not ue.valid(st.decoy) then return end
    set_vis(st.decoy, W.HIDDEN)
    if ue.valid(st.decoy) then pcall(function() st.decoy:SetRenderOpacity(st.decoy_opacity or 1) end) end
end

-- ===========================================================================
-- Main menu page
-- ===========================================================================

local function prefill_address(st)
    local ip = tostring(cfg.get("host_ip") or "")
    local port = cfg.get("port")
    set_text(st.input, ip ~= "" and (port and (ip .. ":" .. tostring(port)) or ip) or "")
end

local function refresh_menu(st)
    if st.dead then return end
    local s = safe_status()
    set_text(st.status_title, s.title or "")
    set_color(st.status_title, status_color(s))
    set_text(st.status_body, table.concat(s.lines or {}, "\n"))
    if pending_conn ~= st.join_pending then
        st.join_pending = pending_conn
        set_text(st.join_text, pending_conn and L.join_cancel or L.join)
    end
end

local function open_menu_page(st)
    if st.dead or st.open or not ue.valid(st.page) then return end
    st.open = true
    prefill_address(st)
    refresh_menu(st)
    set_vis(st.main_panel, W.HIDDEN)
    set_vis(st.page, W.VISIBLE)
    decoy_on(st)
    log.info("lobby: main menu co-op page opened")
end

close_menu_page = function(st, why)
    if not st.open then return end
    st.open = false
    decoy_off(st)
    set_vis(st.page, W.HIDDEN)
    set_vis(st.main_panel, W.VISIBLE)
    focus(st.w)
    log.info("lobby: main menu co-op page closed (%s)", why)
end

local function on_host(st)
    local role = ue.net_role()
    if role ~= "host" and role ~= "client" and ue.in_main_menu() then
        -- host_on_next_load reopens this world as a listen server
        begin_travel("menu reopens as a server")
    end
    session.host_on_next_load()
    refresh_menu(st)
end

local function on_join(st)
    if ue.has_pending_connection() then
        begin_travel("connection cancelled")
        session.disconnect()
        return
    end
    if not ue.valid(st.input) then return end
    local raw = ue.str(ue.try(function() return st.input:GetText() end))
    local host, port = parse_address(raw)
    if host ~= "" then
        cfg.set("host_ip", host)
        if port then cfg.set("port", port) end
        cfg.save()
    end
    -- the connection is async: the LoadMap hook releases this page when it lands
    session.join(host, port or cfg.get("port"), false)
    refresh_menu(st)
end

-- One item in the "game modes" style: SizeBox > VerticalBox > Button(64pt)
-- + description (26pt). Returns the inner VerticalBox.
local function menu_item(st, list, src, height, label, desc, btn_name, text_name)
    local outer = st.outer
    local sb = new_widget("SizeBox", outer)
    pcall(function() sb:SetWidthOverride(ue.prop(src.box, "WidthOverride") or 1000) end)
    pcall(function() sb:SetHeightOverride(height) end)
    local inner = new_widget("VerticalBox", outer)
    layout(sb:AddChild(inner), src.inner, function(s) pcall(function() s:SetVerticalAlignment(VALIGN_CENTER) end) end)
    need(list, "list")
    layout(list:AddChild(sb), src.box, function(s)
        pcall(function() s:SetSize({ Value = 1, SizeRule = SIZE_FILL }) end)
        pcall(function() s:SetHorizontalAlignment(HALIGN_CENTER) end)
        pcall(function() s:SetVerticalAlignment(VALIGN_CENTER) end)
    end)
    if label then
        local b, t = make_button(src.button, label, outer, btn_name, text_name)
        if t then set_font_size(t, 64) end
        layout(inner:AddChild(b), src.button, nil)
    end
    if desc then
        local d = clone_text(src.desc, desc, outer)
        set_wrap(d, ue.prop(src.desc, "WrapTextAt") or 950)
        pcall(function() d:SetJustification(JUSTIFY_CENTER) end)
        layout(inner:AddChild(d), src.desc, function(s)
            pcall(function() s:SetHorizontalAlignment(HALIGN_CENTER) end)
        end)
    end
    return inner
end

-- Fills the state from the live tree (fresh builds and re-attaching alike).
local function bind_menu(st)
    local w, n = st.w, st.n
    need(w, "main menu")
    st.page = need(find_named(w, wname("Page", n)), "page")
    st.button = need(find_named(w, wname("Button", n)), "co-op button")
    st.main_panel = need(W.child(w, "MainMenu"), "MainMenu")
    local q = W.child(w, "QuitToDesktopWidget")
    st.quit_panel = ue.valid(q) and q or nil
    local d = W.child(w, "RoadmapImg")
    st.decoy = ue.valid(d) and d or nil
    st.input = find_named(w, wname("Input", n))
    st.status_title = find_named(w, wname("StatusTitle", n))
    st.status_body = find_named(w, wname("StatusBody", n))
    st.join_text = find_named(w, wname("JoinText", n))
    local back = children_of_class(st.page, "ButtonWidget_C")[1]
    st.open = W.visible(st.page)
    st.decoy_active = st.open and W.visible(st.decoy)
    st.decoy_opacity = 1
    st.join_pending = nil
    st.hovered = false
    register_click(st, st.button, "lobby: co-op", function() open_menu_page(st) end)
    register_click(st, find_named(w, wname("Host", n)), "lobby: host", function() on_host(st) end)
    register_click(st, find_named(w, wname("Join", n)), "lobby: join", function() on_join(st) end)
    if back then
        register_click(st, ue.prop(back, "Button"), "lobby: back", function() close_menu_page(st, "back") end)
    end
end

-- Build progress in the log (flushed line by line): after a crash the last
-- line tells which step of a page build it was.
local function bstep(what, step) log.info("lobby: build %s: %s", what, step) end

local function build_menu(st)
    local w, n = st.w, st.n
    st.added = {}
    need(w, "main menu")
    local load = need(W.child(w, "Load"), "Load")
    local buttons = need(ue.try(function() return load:GetParent() end), "Buttons")
    local overlay = need(W.child(w, "MenuOverlay"), "MenuOverlay")
    need(W.child(w, "MainMenu"), "MainMenu")
    st.outer = need(ue.try(function() return overlay:GetOuter() end), "WidgetTree")
    local outer = st.outer

    local function pick(name, fallback)
        local o = W.child(w, name)
        if ue.valid(o) then return o end
        return fallback
    end
    local load_text = W.first_text(load)
    local src = {
        button = pick("VehicleButton", load),
        title  = pick("VehicleText", load_text),
        desc   = pick("TextBlock_3", load_text),
        box    = pick("SizeBox", nil),
        inner  = pick("VehicleBox", nil),
    }
    need(src.title, "title font")
    need(src.desc, "description font")
    local modes = pick("GameModeSelectionWidget", nil)
    local blur0 = pick("BackgroundBlur_45", nil)
    local scale0 = pick("ScaleBox_3", nil)
    local back0 = pick("ButtonWidget_BackFromGameModeSelect", pick("ButtonWidget_BackFromDesktop", nil))

    -- page --------------------------------------------------------------
    bstep("main menu", "page")
    local page = new_widget("CanvasPanel", outer, wname("Page", n))
    set_vis(page, W.HIDDEN)

    bstep("main menu", "blur")
    local blur = new_widget("BackgroundBlur", outer)
    pcall(function() blur:SetBlurStrength(ue.prop(blur0, "BlurStrength") or 15) end)
    layout(page:AddChild(blur), blur0, function(s) canvas_fill(s, 1) end)

    bstep("main menu", "scale")
    local scale = new_widget("ScaleBox", outer)
    if ue.valid(scale0) then pcall(function() scale:SetStretch(scale0.Stretch) end) end
    local list = new_widget("VerticalBox", outer)
    scale:AddChild(list)
    layout(page:AddChild(scale), scale0, function(s)
        pcall(function() s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 1 } }) end)
        pcall(function() s:SetOffsets({ Left = 0, Top = 0, Right = 500, Bottom = 0 }) end)
        pcall(function() s:SetAlignment({ X = -0.125, Y = 0 }) end)
        pcall(function() s:SetZOrder(2) end)
    end)

    bstep("main menu", "title")
    -- title
    local title_box = menu_item(st, list, src, 240, nil, nil)
    local title = clone_text(src.title, L.title, outer)
    set_font_size(title, 84)
    pcall(function() title:SetJustification(JUSTIFY_CENTER) end)
    vadd(title_box, title, 0, 0, HALIGN_CENTER)

    bstep("main menu", "host item")
    -- host
    menu_item(st, list, src, 380, L.host, L.host_desc, wname("Host", n))

    -- join (+ address field under the description)
    bstep("main menu", "join item")
    local join_box = menu_item(st, list, src, 470, L.join, L.join_desc, wname("Join", n), wname("JoinText", n))
    bstep("main menu", "input")
    local input = make_input(src.desc, outer, 30, L.join_hint, wname("Input", n))
    local isb = new_widget("SizeBox", outer)
    pcall(function() isb:SetWidthOverride(640) end)
    isb:AddChild(input)
    -- the description is drawn 40 px higher than its slot (game layout)
    pcall(function() isb:SetRenderTranslation({ X = 0, Y = -30 }) end)
    vadd(join_box, isb, 0, 0, HALIGN_CENTER)

    bstep("main menu", "status")
    -- status
    local status_box = menu_item(st, list, src, 320, nil, nil)
    local status_title = text_like(src.title, "", outer, 36, 950, wname("StatusTitle", n))
    local status_body = text_like(src.desc, "", outer, 26, 950, wname("StatusBody", n))
    set_color(status_body, COLOR.dim)
    vadd(status_box, status_title, 0, 8, HALIGN_CENTER)
    vadd(status_box, status_body, 0, 0, HALIGN_CENTER)

    bstep("main menu", "back button")
    -- [Esc] Back
    local back = make_game_button(back0, L.back)
    if back then
        layout(page:AddChild(back), back0, function(s) canvas_point(s, 1, 1, 1.1, 1.35, 0, 0, 3) end)
    else
        log.warn("lobby: no ButtonWidget_C for the back button (Esc still closes the page)")
    end

    bstep("main menu", "attach page")
    -- attach the page (builds its Slate widgets) --------------------------
    need(overlay, "MenuOverlay")
    local ps = overlay:AddChild(page)
    st.added[#st.added + 1] = page
    layout(ps, modes, function(s)
        pcall(function() s:SetHorizontalAlignment(HALIGN_FILL) end)
        pcall(function() s:SetVerticalAlignment(VALIGN_FILL) end)
    end)
    if back then fix_game_button(back, L.back) end

    bstep("main menu", "coop button")
    -- "Кооператив" right after "Load", with a spacer like the others -------
    need(buttons, "Buttons")
    local n_before = visible_buttons(buttons)
    local coop, coop_text = make_button(load, L.coop, outer, wname("Button", n))
    need(coop_text, "button text")
    local idx = ue.try(function() return buttons:GetChildIndex(load) end)
    local spacer0 = idx and ue.try(function() return buttons:GetChildAt(idx + 1) end)
    local items, spacer_h = {}, 0
    if ue.class_name(spacer0) == "Spacer" then
        local sp = new_widget("Spacer", outer, wname("Spacer", n))
        pcall(function() sp:SetSize(spacer0.Size) end)
        spacer_h = ue.try(function() return spacer0.Size.Y end) or 5
        items[#items + 1] = { w = sp, layout = spacer0 }
        st.added[#st.added + 1] = sp
    end
    items[#items + 1] = { w = coop, layout = load }
    st.added[#st.added + 1] = coop
    bstep("main menu", "insert")
    insert_after(buttons, load, items, "main menu button")

    bstep("main menu", "resize")
    -- keep the buttons' height: the column is a fixed-size box
    local h = panel_height(buttons)
    if n_before > 0 and h then
        st.grow_target, st.grow_h0, st.grow_keep_bottom = buttons, h, true
        set_panel_height(buttons, h + (h - 25) / n_before + spacer_h, true)
    end

    bind_menu(st)
end

local menu_seen_at = {}   -- [menu widget name] = os.clock() when first seen on screen
local menu_wait_logged = {}
local last_scan_sig = nil
-- Simple mode (default): the game's menus get only a "Кооператив" button, a
-- clone of one of their own buttons (the way the death-screen buttons are
-- made, which works), and it opens the co-op panel (sdc_ui). Building the
-- full in-menu page crashed the game (copying slot layouts between canvas
-- slots hung, then EXCEPTION_ACCESS_VIOLATION), so it stays off until it is
-- rebuilt and tested piece by piece.
local SIMPLE_PAGES = true
local simple_patched = {}   -- [menu widget name] = true

local function simple_coop_button(w, anchor_name, what, grow_column)
    local k = ue.name(w)
    if simple_patched[k] then return "done" end
    local orig = W.child(w, anchor_name)
    if not ue.valid(orig) or not ue.valid(ue.prop(orig, "Slot")) then return "wait" end
    simple_patched[k] = true
    -- the main menu's button column is a fixed-height box held by its bottom
    -- edge: one more row pushed "Continue" out of sight. It grows by a row.
    local column = ue.try(function() return orig:GetParent() end)
    local n_before = ue.valid(column) and visible_buttons(column) or 0
    local h = ue.valid(column) and panel_height(column) or nil
    marker_on()
    local ok, err = pcall(function()
        -- the label in the player's language (sdc_i18n), else the Russian one
        local label = L.coop
        local oki, i18n = pcall(require, "sdc_i18n")
        if oki and type(i18n) == "table" and type(i18n.coop_label) == "function" then
            local okl, s = pcall(i18n.coop_label)
            if okl and type(s) == "string" and s ~= "" then label = s end
        end
        W.clone_button(orig, label, function()
            local okp, e = pcall(function() require("sdc_ui").set_open(true) end)
            if not okp then log.err("lobby: co-op panel: %s", tostring(e)) end
        end, nil, w)
    end)
    if ok and grow_column and n_before > 0 and h then
        local new_h = h + (h - 25) / n_before
        local grown = set_panel_height(column, new_h, true)
        log.info("lobby: %s: button column %.0f -> %.0f px (ok=%s)", what, h, new_h, tostring(grown))
    end
    marker_off()
    if ok then
        log.info("lobby: %s: co-op button added after %s (opens the co-op panel)", what, anchor_name)
    else
        log.err("lobby: %s: co-op button failed: %s", what, tostring(err))
    end
    return "done"
end

local function patch_menu(w)
    if M.disabled or fail_streak.menu >= MAX_FAILS then return "skip" end
    if not shown(w) then return "wait" end
    -- a menu that is still starting up must not be touched (another co-op
    -- mod for this game crashed it that way): give it SETTLE_S on screen
    local mk = ue.name(w)
    if not menu_seen_at[mk] then
        menu_seen_at[mk] = os.clock()
        log.info("lobby: main menu on screen: %s", ue.short(w))
    end
    if os.clock() - menu_seen_at[mk] < SETTLE_S then return "wait" end
    if SIMPLE_PAGES then return simple_coop_button(w, "Load", "main menu", false) end
    local load = W.child(w, "Load")
    local overlay = W.child(w, "MenuOverlay")
    if not ue.valid(load) or not ue.valid(overlay) or not ue.valid(ue.prop(load, "Slot")) then
        if not menu_wait_logged[mk] then
            menu_wait_logged[mk] = true
            log.warn("lobby: main menu %s is on screen but not patchable yet: Load=%s MenuOverlay=%s Load.Slot=%s",
                ue.short(w), tostring(ue.valid(load)), tostring(ue.valid(overlay)),
                tostring(ue.valid(load) and ue.valid(ue.prop(load, "Slot"))))
        end
        return "wait"
    end
    local _, n = find_page(overlay)
    if n and menu and menu.n == n then return "done" end
    if menu then forget(menu, "another main menu", true) end
    local st = { kind = "menu", w = w, open = false, entries = {}, added = {} }
    if n then
        st.n = n
        return adopt("main menu", st, bind_menu)
    end
    seq = seq + 1
    st.n = seq
    if not guarded_build("main menu", st, build_menu) then return "skip" end
    menu = st
    log.info("lobby: main menu patched (%s, page %d)", ue.short(w), st.n)
    return "done"
end

-- ===========================================================================
-- Pause menu page
-- ===========================================================================

local function refresh_pause(st)
    if st.dead then return end
    local s = safe_status()
    set_text(st.status, s.title or "")
    set_color(st.status, status_color(s))
    set_text(st.players, table.concat(s.lines or {}, "\n"))
    local role = s.role
    if role ~= st.shown_role then
        st.shown_role = role
        if role == "client" then
            set_text(st.action_text, L.disconnect)
            set_text(st.hint, L.client_hint)
        elseif role == "host" then
            set_text(st.action_text, L.close_world)
            set_text(st.hint, L.host_hint)
        else
            set_text(st.action_text, L.open_world)
            set_text(st.hint, L.solo_hint)
        end
    end
end

-- The list is a fixed-size box: keep its cells at least PAUSE_CELL high.
-- Re-checked while the page lives, because sdc_players hides buttons on
-- clients after the pause menu appears.
local function fit_pause(st)
    if st.dead then return end
    local info = page_info[st.n]
    if not info or not info.h0 then return end
    local count = visible_buttons(st.list)
    if count == 0 or count == st.fit_count then return end
    st.fit_count = count
    set_panel_height(st.pause_widget, math.max(info.h0, 20 + count * PAUSE_CELL), false)
end

local function show_main_view(st)
    st.confirm_kind = nil
    set_vis(st.confirm, W.HIDDEN)
    set_vis(st.main, W.SELF_HIT_TEST_INVISIBLE)
end

local function open_pause_page(st)
    if st.dead or st.open or not ue.valid(st.page) then return end
    st.open = true
    st.shown_role = nil
    refresh_pause(st)
    show_main_view(st)
    set_vis(st.pause_widget, W.HIDDEN)
    set_vis(st.page, W.VISIBLE)
    decoy_on(st)
    log.info("lobby: pause co-op page opened")
end

-- show_list = false leaves the pause buttons hidden (another game page
-- takes over, e.g. the game's own quit confirmation).
close_pause_page = function(st, why, show_list)
    if not st.open then return end
    st.open = false
    decoy_off(st)
    show_main_view(st)
    set_vis(st.page, W.HIDDEN)
    if show_list ~= false then set_vis(st.pause_widget, W.VISIBLE) end
    focus(st.w)
    log.info("lobby: pause co-op page closed (%s)", why)
end

local function quit_to_menu(st)
    -- the game's own "Quit To Main Menu: YES" (closes the server like in SP):
    -- it removes the pause screen and opens the main menu on the next tick
    local w = st.w
    if not ue.valid(w) then return end
    local ok, err = pcall(function() w[QUIT_YES_EVENT](w) end)
    log.info("lobby: host closes the world via the game's quit flow (ok=%s%s)",
        tostring(ok), ok and "" or (" " .. tostring(err)))
    if ok then
        begin_travel("host closes the world")
    else
        -- fall back to the game's own confirmation page
        set_vis(st.quit_menu, W.VISIBLE)
    end
end

local function disconnect_now(st, why)
    close_pause_page(st, why, true)
    begin_travel(why)
    session.disconnect()
end

local function show_confirm(st, kind)
    if not ue.valid(st.confirm) then
        -- no YES/NO buttons could be built: act like the game's own pages would
        if kind == "disconnect" then
            disconnect_now(st, "disconnect")
        else
            close_pause_page(st, "close world", false)
            set_vis(st.quit_menu, W.VISIBLE)
        end
        return
    end
    st.confirm_kind = kind
    set_text(st.confirm_text, kind == "disconnect" and L.disconnect_q or L.close_q)
    set_vis(st.main, W.HIDDEN)
    set_vis(st.confirm, W.SELF_HIT_TEST_INVISIBLE)
end

local function on_pause_action(st)
    local role = session.state.role
    if role == "client" then
        show_confirm(st, "disconnect")
    elseif role == "host" then
        show_confirm(st, "close")
    else
        -- in a running solo world this only remembers the setting (no travel)
        session.host_on_next_load()
        refresh_pause(st)
    end
end

local function on_confirm_yes(st)
    local kind = st.confirm_kind
    if kind == "disconnect" then
        disconnect_now(st, "disconnect")
    elseif kind == "close" then
        close_pause_page(st, "close world", false)
        quit_to_menu(st)
    else
        show_main_view(st)
    end
end

local function on_pause_back(st)
    if st.confirm_kind then
        show_main_view(st)
    else
        close_pause_page(st, "back", true)
    end
end

local function bind_pause(st)
    local w, n = st.w, st.n
    need(w, "pause menu")
    st.page = need(find_named(w, wname("Page", n)), "page")
    st.button = need(find_named(w, wname("Button", n)), "co-op button")
    st.pause_widget = need(W.child(w, "PauseWidget"), "PauseWidget")
    local resume = need(W.child(w, "Resume"), "Resume")
    st.list = need(ue.try(function() return resume:GetParent() end), "VerticalBox_59")
    st.decoy = need(W.child(w, "SuicideWidget"), "SuicideWidget")
    local q = W.child(w, "QuitToMainMenuWidget")
    st.quit_menu = ue.valid(q) and q or nil
    st.main = need(find_named(w, wname("Main", n)), "main view")
    st.status = find_named(w, wname("Status", n))
    st.players = find_named(w, wname("Players", n))
    st.hint = find_named(w, wname("Hint", n))
    st.action_text = find_named(w, wname("ActionText", n))
    local action = need(find_named(w, wname("Action", n)), "action button")
    st.confirm = find_named(w, wname("Confirm", n))
    st.confirm_text = find_named(w, wname("ConfirmText", n))
    local yes_no = children_of_class(st.confirm, "ButtonWidget_C")
    if #yes_no < 2 then st.confirm = nil end
    local back = children_of_class(st.page, "ButtonWidget_C")[1]
    st.open = W.visible(st.page)
    st.decoy_active = st.open and W.visible(st.decoy)
    st.decoy_opacity = 1
    st.shown_role = nil
    st.fit_count = nil
    st.fit_frames = 90
    if st.open then show_main_view(st) end
    register_click(st, st.button, "lobby: pause co-op", function() open_pause_page(st) end)
    register_click(st, action, "lobby: pause action", function() on_pause_action(st) end)
    if st.confirm then
        register_click(st, ue.prop(yes_no[1], "Button"), "lobby: confirm yes", function() on_confirm_yes(st) end)
        register_click(st, ue.prop(yes_no[2], "Button"), "lobby: confirm no", function() show_main_view(st) end)
    end
    if back then
        register_click(st, ue.prop(back, "Button"), "lobby: pause back", function() on_pause_back(st) end)
    end
end

local function build_pause(st)
    local w, n = st.w, st.n
    st.added = {}
    need(w, "pause menu")
    local resume = need(W.child(w, "Resume"), "Resume")
    local list = need(ue.try(function() return resume:GetParent() end), "VerticalBox_59")
    local pause_widget = need(W.child(w, "PauseWidget"), "PauseWidget")
    local suicide = need(W.child(w, "SuicideWidget"), "SuicideWidget")
    local root = need(ue.try(function() return suicide:GetParent() end), "CanvasPanel_0")
    local outer = need(ue.try(function() return suicide:GetOuter() end), "WidgetTree")
    st.outer = outer
    local after = W.child(w, "Settings")
    if not ue.valid(after) then after = resume end
    local btext0 = need(W.first_text(resume), "pause button text")
    local q0 = W.child(w, "TextBlock_289")
    if not ue.valid(q0) then q0 = btext0 end
    local yes0, no0 = W.child(w, "SuicideYesButton"), W.child(w, "SuicideNoButton")
    local back0 = W.child(w, "ButtonWidget_BackFromSuicide")

    -- page --------------------------------------------------------------
    local page = new_widget("CanvasPanel", outer, wname("Page", n))
    set_vis(page, W.HIDDEN)

    -- main view: title, status, players, hint, action
    local main = new_widget("VerticalBox", outer, wname("Main", n))
    vadd(main, text_like(q0, L.title, outer, 40), 0, 12)
    vadd(main, text_like(q0, "", outer, 22, 900, wname("Status", n)), 0, 14)
    vadd(main, text_like(btext0, "", outer, 18, 900, wname("Players", n)), 0, 16)
    local hint = text_like(q0, "", outer, 16, 760, wname("Hint", n))
    set_color(hint, COLOR.dim)
    vadd(main, hint, 0, 20)
    local action, action_text = make_button(resume, L.disconnect, outer, wname("Action", n), wname("ActionText", n))
    need(action_text, "action text")
    local abox = new_widget("SizeBox", outer)
    pcall(function() abox:SetWidthOverride(500) end)
    pcall(function() abox:SetHeightOverride(46) end)
    abox:AddChild(action)
    vadd(main, abox, 0, 0)
    canvas_point(page:AddChild(main), 0.5, 0.5, 0.5, 0.5, 0, -20, 2)

    -- confirm view, laid out exactly like the game's SuicideWidget
    local yes = make_game_button(yes0, L.yes)
    local no = make_game_button(no0, L.no)
    if yes and no then
        local confirm = new_widget("CanvasPanel", outer, wname("Confirm", n))
        set_vis(confirm, W.HIDDEN)
        local ctext = clone_text(q0, "", outer, wname("ConfirmText", n))
        pcall(function() ctext:SetJustification(JUSTIFY_CENTER) end)
        layout(confirm:AddChild(ctext), q0, function(s) canvas_point(s, 0.5, 0.5, 0.5, 0.5, 0, 0) end)
        layout(confirm:AddChild(yes), yes0, nil)   -- bind_pause finds YES / NO in this order
        layout(confirm:AddChild(no), no0, nil)
        canvas_fill(page:AddChild(confirm), 2)
    end

    local back = make_game_button(back0, L.back)
    if back then
        layout(page:AddChild(back), back0, function(s) canvas_point(s, 1, 1, 1.1, 1.35, 0, 0, 3) end)
    end

    -- attach the page like the game's sub-pages (full screen, ZOrder 2) ----
    need(root, "CanvasPanel_0")
    local ps = root:AddChild(page)
    st.added[#st.added + 1] = page
    layout(ps, suicide, function(s) canvas_fill(s, 2) end)
    if yes then fix_game_button(yes, L.yes) end
    if no then fix_game_button(no, L.no) end
    if back then fix_game_button(back, L.back) end

    -- "Кооператив" in the pause list, after "Settings" ----------------------
    local coop, coop_text = make_button(resume, L.coop, outer, wname("Button", n))
    need(coop_text, "button text")
    st.added[#st.added + 1] = coop
    insert_after(list, after, { { w = coop, layout = resume } }, "pause menu button")

    -- the list height before our button; fit_pause keeps the cells usable
    page_info[n] = { h0 = panel_height(pause_widget) }
    st.grow_target, st.grow_h0, st.grow_keep_bottom = pause_widget, page_info[n].h0, false

    bind_pause(st)
    fit_pause(st)
end

local function patch_pause(w)
    if M.disabled or fail_streak.pause >= MAX_FAILS then return "skip" end
    if not shown(w) then return "wait" end
    if SIMPLE_PAGES then return simple_coop_button(w, "Settings", "pause menu") end
    local resume = W.child(w, "Resume")
    local suicide = W.child(w, "SuicideWidget")
    if not ue.valid(resume) or not ue.valid(suicide) or not ue.valid(ue.prop(resume, "Slot")) then return "wait" end
    local root = ue.try(function() return suicide:GetParent() end)
    if not ue.valid(root) then return "wait" end
    local _, n = find_page(root)
    if n and pause and pause.n == n then return "done" end
    if pause then forget(pause, "another pause menu", true) end
    local st = { kind = "pause", w = w, open = false, entries = {}, added = {} }
    if n then
        st.n = n
        return adopt("pause menu", st, bind_pause)
    end
    seq = seq + 1
    st.n = seq
    if not guarded_build("pause menu", st, build_pause) then return "skip" end
    pause = st
    log.info("lobby: pause menu patched (%s, page %d, role=%s)", ue.short(w), st.n, tostring(session.state.role))
    return "done"
end

-- New menu widgets: patched on the first frame their tree is up (the pause
-- menu is created and added to the viewport in the same frame).
local function process_watch_queue()
    if #watch_queue == 0 then return end
    local q = watch_queue
    watch_queue = {}
    local traveling = os.time() < travel_until
    local keep = {}
    for _, e in ipairs(q) do
        e.frames = e.frames + 1
        local status = "skip"
        if e.gen == world_gen and e.frames > WATCH_FRAMES and ue.valid(e.w) then
            -- not on screen yet (loading): the 4 Hz tick keeps trying, since
            -- FindAllOf does not see these widgets in this UE4SS build
            late[#late + 1] = e
        end
        if e.gen == world_gen and e.frames <= WATCH_FRAMES then
            if traveling then
                status = "wait"
            elseif ue.valid(e.w) then
                if e.kind == "menu" then status = patch_menu(e.w) else status = patch_pause(e.w) end
            end
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
    local parent = ue.prop(hud, "NotificationUI")
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
    -- during a travel started here, or while a connection is pending, the
    -- current world (and its HUD) is about to go away
    local overlay_only = os.time() < travel_until or pending_conn
    for _, n in ipairs(q) do
        if overlay_only or not game_notification(n.text, n.seconds) then to_fallback(n) end
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
            log.err("lobby: %d starts in a row ended while a co-op page was being built; the lobby is off "
                .. "for this session (F7 menu and console commands still work)", hits)
        else
            marker_hits = hits
            log.warn("lobby: the previous start ended while a co-op page was being built (%d/2); "
                .. "the lobby stays on", hits)
        end
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

-- Live main menu widgets of this world, through the game's own
-- WidgetBlueprintLibrary.GetAllWidgetsOfClass (FindAllOf does not see them
-- in this UE4SS build, and NotifyOnNewObject only reported the CDO).
local menu_class_obj = nil
local function live_menus()
    local out = {}
    local wbl, wc = ue.widget_lib(), ue.local_pc() or ue.game_instance()
    if not ue.valid(menu_class_obj) then menu_class_obj = ue.find_object(MENU_CLASS) end
    if not wbl or not wc or not ue.valid(menu_class_obj) then return out end
    local arr = {}
    local ok = pcall(function() wbl:GetAllWidgetsOfClass(wc, arr, menu_class_obj, true) end)
    if not ok then return out end
    for _, v in ipairs(arr) do
        local w = v
        if type(v) == "userdata" and not ue.valid(v) then w = ue.try(function() return v:get() end) end
        if ue.valid(w) and not ue.short(w):find("^Default__") then out[#out + 1] = w end
    end
    return out
end

-- 4 Hz: polling fallbacks, refresh open pages, pause list height.
function M.slow_tick()
    if M.disabled then return end
    tick_n = tick_n + 1
    if not loadmap_hooked and tick_n % 8 == 1 then find_viewport_client() end

    if menu and not shown(menu.w) then forget(menu, "main menu closed", true) end
    if pause and not shown(pause.w) then forget(pause, "pause menu closed", true) end

    if travel_until > 0 then
        if os.time() < travel_until then return end
        -- the travel did not happen: look for the menus again
        travel_until = 0
        scans_left = SCAN_BUDGET
    end

    local in_menu = ue.in_main_menu()
    -- diagnosis while the main menu stays unpatched (a few lines per world)
    if in_menu and not menu and tick_n % 20 == 0 and diag_left > 0 then
        diag_left = diag_left - 1
        local list, info = ue.find_all("MenuWidget_C"), {}
        for _, e in ipairs(late) do
            if e.kind == "menu" and e.gen == world_gen and ue.valid(e.w) then list[#list + 1] = e.w end
        end
        for _, w in ipairs(list) do
            if ue.valid(w) and not ue.short(w):find("^Default__") then
                local load, overlay = W.child(w, "Load"), W.child(w, "MenuOverlay")
                info[#info + 1] = string.format("%s shown=%s load=%s overlay=%s slot=%s", ue.short(w), tostring(shown(w)),
                    tostring(ue.valid(load)), tostring(ue.valid(overlay)), tostring(ue.valid(load) and ue.valid(ue.prop(load, "Slot"))))
            end
        end
        log.info("lobby: main menu not patched yet: %d MenuWidget_C [%s] scans_left=%d queue=%d travel=%d fails=%d gen=%d",
            #list, table.concat(info, "; "), scans_left, #watch_queue, travel_until, fail_streak.menu, world_gen)
        -- the game's own enumeration of live widgets of this world
        local found = live_menus()
        local parts = {}
        for _, w in ipairs(found) do parts[#parts + 1] = ue.short(w) .. " shown=" .. tostring(shown(w)) end
        log.info("lobby: GetAllWidgetsOfClass(MenuWidget_C): %d [%s]", #found, table.concat(parts, "; "))
    end
    -- one object scan per second, and only where a connection can be pending
    if tick_n % 4 == 0 then pending_conn = in_menu and ue.has_pending_connection() or false end

    -- watched menus that were not on screen in time (no object scan needed)
    if not menu and in_menu and #late > 0 and fail_streak.menu < MAX_FAILS then
        local keep = {}
        for _, e in ipairs(late) do
            if e.gen == world_gen and ue.valid(e.w) then
                local status = "wait"
                if not menu and shown(e.w) then
                    if e.kind == "menu" then status = patch_menu(e.w) else status = patch_pause(e.w) end
                end
                if status == "wait" then keep[#keep + 1] = e end
            end
        end
        late = keep
    end

    if menu then
        if menu.open and tick_n % 4 == 0 then refresh_menu(menu) end
    elseif in_menu and tick_n % SCAN_EVERY == 0 and scans_left > 0 and fail_streak.menu < MAX_FAILS then
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

    if pause then
        if pause.open and tick_n % 4 == 0 then refresh_pause(pause) end
        fit_pause(pause)
    elseif not in_menu and fail_streak.pause < MAX_FAILS then
        local pm = hud_pause_menu()
        if pm and shown(pm) then patch_pause(pm) end
    end

    if tick_n % 40 == 0 then
        local count = 0
        for _ in pairs(page_info) do count = count + 1 end
        if count > 32 then
            for k in pairs(page_info) do
                if k < seq - 16 and not (pause and pause.n == k) then page_info[k] = nil end
            end
        end
    end
end

-- Every frame (wire it BEFORE widgets.frame_tick): notifications, crash
-- marker, releasing pages whose menu left the screen, new menus, Esc,
-- hover sound.
function M.frame_tick()
    marker_frame()
    -- without a LoadMap hook: notice a new world before anything is touched
    if not M.disabled and not loadmap_hooked and world_changed() then on_load_map("world changed") end
    flush_notifications()
    if M.disabled then return end

    if menu and not shown(menu.w) then forget(menu, "main menu closed", true) end
    if pause and not shown(pause.w) then forget(pause, "pause menu closed", true) end
    process_watch_queue()

    local m = menu
    if m then
        if m.open then
            if W.visible(m.main_panel) then
                -- Esc (the game hid the decoy and showed its buttons) or any
                -- other game path back to the button list
                close_menu_page(m, "esc")
            elseif not m.decoy_active and W.visible(m.quit_panel) then
                -- Esc without a decoy: the game opened "quit to desktop?"
                set_vis(m.quit_panel, W.HIDDEN)
                close_menu_page(m, "esc")
            end
        elseif ue.valid(m.button) then
            local ok, hovered = pcall(function() return m.button:IsHovered() end)
            hovered = ok and hovered == true
            if hovered and not m.hovered then play_click() end
            m.hovered = hovered
        end
    end

    local p = pause
    if p then
        if p.open and W.visible(p.pause_widget) then close_pause_page(p, "esc", true) end
        if not p.dead and (p.fit_frames or 0) > 0 then
            p.fit_frames = p.fit_frames - 1
            fit_pause(p)
        end
    end
end

-- For sdc_ui: true while the game's pause menu is on screen (fresh lookup,
-- nothing cached).
function M.pause_menu_shown()
    local pm = hud_pause_menu()
    return pm ~= nil and shown(pm)
end

-- For the console / F7 fallback.
function M.status_line()
    return string.format("lobby: disabled=%s loadmap_hook=%s menu=%s(open=%s) pause=%s(open=%s) pages=%d watch=%d",
        tostring(M.disabled), tostring(loadmap_hooked),
        menu and tostring(menu.n) or "-", tostring(menu and menu.open),
        pause and tostring(pause.n) or "-", tostring(pause and pause.open),
        seq, #watch_queue)
end

return M
