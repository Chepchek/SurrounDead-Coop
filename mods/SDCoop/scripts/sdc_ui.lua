-- SDCoop: the co-op panel and on-screen notifications, built from plain UMG
-- classes at runtime (no Blueprint assets needed).
--
-- Widget tree:
--   UserWidget (outer = GameInstance, survives level changes)
--     CanvasPanel  (self-hit-test-invisible: never blocks the game)
--       Border "toast"  - top centre, notifications
--       Overlay "panel" - right column, 82% of the screen height (anchored
--                         9%..91%, so DPI scaling and resolution never clip
--                         it); the panel inside is as tall as its content and
--                         at most that column:
--         Border (night)
--           header: title (the game's menu font) + version
--           status: coloured dot + one sentence + one dim line
--           tabs:   Играть / Персонаж / Настройки (amber bar = active)
--           ScrollBox: the active tab's page (collapsible sections)
--           footer: Сохранить / Закрыть (always visible)
--
-- Text comes from sdc_i18n (Russian / English); every text is registered with
-- the function that makes it, so a language change relabels the panel in
-- place. Collapsed sections build their body the first time they open.
--
-- UE4SS cannot bind Lua functions to UMG delegates, so button clicks are
-- detected by polling UButton::IsPressed every frame while the panel is open
-- (press -> release over the button = click); only buttons on the shown tab
-- inside open sections are polled.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local session = require("sdc_session")
local i18n = require("sdc_i18n")
local T = i18n.T

local UI = {
    VERSION = "?",
    widget = nil, tree = nil, canvas = nil, panel = nil,
    toast_box = nil, toast_text = nil, status_title = nil, status_body = nil,
    inputs = {}, checks = {}, buttons = {}, active = {}, active_dirty = true,
    ltexts = {}, gtexts = {}, sections = {}, pages = {}, check_state = {},
    tab = nil,
    open = false, shown = nil, input_mode_changed = false,
    toasts = {}, toasts_dirty = false,
    build_failures = 0, builds = 0, last_map = nil,
}

local VIS_VISIBLE, VIS_COLLAPSED, VIS_HIT_TEST_INVISIBLE, VIS_SELF_HIT_TEST_INVISIBLE = 0, 1, 3, 4
local HALIGN_FILL = 0
local VALIGN_FILL, VALIGN_TOP, VALIGN_CENTER = 0, 1, 2
local SIZE_FILL = 1
local JUSTIFY_CENTER = 1

local PANEL_W = 480        -- Slate units (DPI-scaled like the game's own UI): four tabs fit
local PAD = 18             -- panel side padding
local TABS = { "steam", "ip", "char", "settings" }
-- Section chevron: "›" (the engine font has no ▸ / ▾), turned 90° when open.
local CHEVRON = "›"
-- Checkbox labels wrap at a fixed width (Slate units): a CheckBox gives its
-- content its desired width, so wrapping at the arranged width is unstable.
local CHECK_WRAP = { main = 392, group = 370 }

-- Colour tokens (sRGB hex from the spec; Slate colours are linear).
local function srgb(hex, a)
    local function ch(i)
        local c = tonumber(hex:sub(i, i + 1), 16) / 255
        return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    return { R = ch(1), G = ch(3), B = ch(5), A = a or 1 }
end

local C = {
    night       = srgb("0F1517", 0.94),   -- panel background
    surface     = srgb("182022"),         -- inputs
    btn         = srgb("222C2F"),         -- secondary buttons
    btn_hover   = srgb("2E3B3F"),
    ghost_hover = srgb("1C2527"),         -- tabs, section headers
    line        = srgb("263033"),         -- dividers
    bone        = srgb("E4E6E0"),         -- text, titles
    dim         = srgb("8C968F"),         -- captions, help, version
    amber       = srgb("DB751A"),         -- primary buttons, active tab
    amber_hover = srgb("F08C2E"),
    ok          = srgb("7DC46A"),
    warn        = srgb("E5BF57"),
    err         = srgb("DD5E4C"),
    clear       = { R = 0, G = 0, B = 0, A = 0 },
    white       = { R = 1, G = 1, B = 1, A = 1 },
}
local TOAST_COLOR = { info = C.bone, ok = C.ok, warn = C.warn, err = C.err }

local COL = {
    primary   = { base = C.amber, hover = C.amber_hover },
    secondary = { base = C.btn, hover = C.btn_hover },
    ghost     = { base = C.clear, hover = C.ghost_hover },
}

-- Build context: the tab and the collapsible section new buttons belong to
-- (a button is polled only while both are shown).
local CTX = { tab = nil, sec = nil }

-- ---------------------------------------------------------------------------
-- Widget construction helpers
-- ---------------------------------------------------------------------------

local class_cache = {}
local function umg_class(short)
    local c = class_cache[short]
    if ue.valid(c) then return c end
    c = ue.find_object("/Script/UMG." .. short)
    if not c then error("UMG class not found: " .. short) end
    class_cache[short] = c
    return c
end

local function new(short)
    local o = StaticConstructObject(umg_class(short), UI.tree)
    if not ue.valid(o) then error("cannot construct UMG." .. short) end
    return o
end

local function margin(l, t, r, b)
    return { Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 }
end

local function set_color(tb, color)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
end

-- Engine font (typefaces "Regular" / "Bold"; it has Cyrillic).
local function set_font(tb, size, bold)
    pcall(function()
        local f = tb.Font
        f.Size = size
        f.TypefaceFontName = FName(bold and "Bold" or "Regular")
        tb:SetFont(f)
    end)
end

local function show(w, on, vis)
    if ue.valid(w) then
        pcall(function() w:SetVisibility(on and (vis or VIS_SELF_HIT_TEST_INVISIBLE) or VIS_COLLAPSED) end)
    end
end

-- opts: bold, wrap (wrap at the width the layout gives), justify
local function text(s, size, color, opts)
    opts = opts or {}
    local t = new("TextBlock")
    pcall(function() t:SetText(FText(s or "")) end)
    set_font(t, size or 14, opts.bold)
    set_color(t, color or C.bone)
    if opts.wrap then
        pcall(function() t.AutoWrapText = true end)
        pcall(function() t:SetAutoWrapText(true) end)
    end
    if opts.justify then pcall(function() t:SetJustification(opts.justify) end) end
    return t
end

-- A text maker: a catalog key (with arguments) or a function.
local function lfn(key, ...)
    if type(key) == "function" then return key end
    local n, args = select("#", ...), { ... }
    return function() return T(key, table.unpack(args, 1, n)) end
end

-- kind: "text" (SetText) | "tip" (SetToolTipText) | "hint" (SetHintText)
local function bind(w, f, kind)
    UI.ltexts[#UI.ltexts + 1] = { w = w, f = f, kind = kind or "text" }
end

local function ltext(key, size, color, opts)
    local f = lfn(key)
    local t = text(f(), size, color, opts)
    bind(t, f)
    return t
end

-- Texts drawn in the game's own menu font once it is known (apply_game_font).
local function game_font(t, size)
    UI.gtexts[#UI.gtexts + 1] = { w = t, size = size }
end

local function vadd(vb, w, top, bottom, left, right)
    local slot = vb:AddChildToVerticalBox(w)
    pcall(function() slot:SetPadding(margin(left, top, right, bottom)) end)
    return slot
end

local function hadd(hb, w, fill, left, valign)
    local slot = hb:AddChildToHorizontalBox(w)
    pcall(function() slot:SetVerticalAlignment(valign or VALIGN_CENTER) end)
    if fill then pcall(function() slot:SetSize({ Value = 1.0, SizeRule = SIZE_FILL }) end) end
    if left then pcall(function() slot:SetPadding(margin(left, 0, 0, 0)) end) end
    return slot
end

local function sized(w, width, height)
    local sb = new("SizeBox")
    if width then pcall(function() sb:SetWidthOverride(width) end) end
    if height then pcall(function() sb:SetHeightOverride(height) end) end
    if w then sb:SetContent(w) end
    return sb
end

-- A filled box around `content`.
local function box(content, color, l, t, r, b)
    local bd = new("Border")
    pcall(function() bd:SetBrushColor(color) end)
    pcall(function() bd:SetPadding(margin(l, t, r, b)) end)
    if content then bd:SetContent(content) end
    return bd
end

local function line()
    return sized(box(nil, C.line), nil, 1)
end

-- A clickable area: Border (its colour is the look) > Button (invisible,
-- not focusable: a click must not take keyboard focus from the game's menu)
-- > content. Returns the border and the polled record.
local function clickable(content, colors, handler, label)
    local bg = new("Border")
    pcall(function() bg:SetBrushColor(colors.base) end)
    pcall(function() bg:SetPadding(margin()) end)
    local b = new("Button")
    pcall(function() b:SetBackgroundColor(C.clear) end)
    ue.set_prop(b, "IsFocusable", false)
    local s = b:SetContent(content)
    pcall(function() s:SetHorizontalAlignment(HALIGN_FILL) end)
    pcall(function() s:SetVerticalAlignment(VALIGN_FILL) end)
    pcall(function() s:SetPadding(margin()) end)
    bg:SetContent(b)
    local rec = { w = b, bg = bg, was = false, fn = handler, label = label or "?", colors = colors,
                  hovered = false, tab = CTX.tab, sec = CTX.sec }
    UI.buttons[#UI.buttons + 1] = rec
    UI.active_dirty = true
    return bg, rec
end

-- A full-width button with a label that wraps instead of overflowing.
-- kind: "primary" (amber) | nil (secondary)
local function button(key, kind, handler, min_h)
    local t = ltext(key, 15, C.bone, { bold = true, wrap = true, justify = JUSTIFY_CENTER })
    game_font(t, 15)
    local sb = new("SizeBox")
    pcall(function() sb:SetMinDesiredHeight(min_h or 38) end)
    local ss = sb:SetContent(t)
    pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() ss:SetHorizontalAlignment(HALIGN_FILL) end)
    pcall(function() ss:SetPadding(margin(10, 4, 10, 4)) end)
    local bg, rec = clickable(sb, kind == "primary" and COL.primary or COL.secondary, handler,
        type(key) == "string" and key or "button")
    return bg, rec
end

-- A small button for a row of a list: as wide as its label, one line (an
-- auto-sized slot gives a wrapping text an unstable width).
local function small_button(key, handler, min_h)
    local t = ltext(key, 13, C.bone, { bold = true, justify = JUSTIFY_CENTER })
    game_font(t, 13)
    local sb = new("SizeBox")
    pcall(function() sb:SetMinDesiredHeight(min_h or 28) end)
    local ss = sb:SetContent(t)
    pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() ss:SetPadding(margin(2, 1, 2, 1)) end)
    return (clickable(sb, COL.secondary, handler, type(key) == "string" and key or "button"))
end

local function caption(key)
    return ltext(key, 12, C.dim, { wrap = true })
end

local function heading(key)
    return ltext(key, 15, C.bone, { bold = true })
end

local function input_box(value, hint_f)
    local e = new("EditableTextBox")
    pcall(function() e:SetText(FText(value or "")) end)
    if hint_f then
        pcall(function() e:SetHintText(FText(hint_f())) end)
        bind(e, hint_f, "hint")
    end
    pcall(function() e.WidgetStyle.TextStyle.Font.Size = 15 end)
    -- the default style is light text on a light box: make it dark / readable
    pcall(function() e.WidgetStyle.BackgroundColor = { SpecifiedColor = C.surface, ColorUseRule = 0 } end)
    pcall(function() e.WidgetStyle.ForegroundColor = { SpecifiedColor = C.bone, ColorUseRule = 0 } end)
    pcall(function() e.WidgetStyle.FocusedForegroundColor = { SpecifiedColor = C.white, ColorUseRule = 0 } end)
    pcall(function() e.WidgetStyle.Padding = { Left = 10, Top = 7, Right = 10, Bottom = 7 } end)
    pcall(function() e:SetForegroundColor(C.bone) end)
    return e
end

-- An input bound to a config key.
local function input(key, hint_key)
    local e = input_box(tostring(cfg.get(key) or ""), hint_key and lfn(hint_key) or nil)
    UI.inputs[key] = e
    return e
end

-- ---------------------------------------------------------------------------
-- Settings <-> widgets
-- ---------------------------------------------------------------------------

local function check_value(list)
    for _, cb in ipairs(list) do
        if ue.valid(cb) then
            local ok, v = pcall(function() return cb:IsChecked() end)
            if ok then return v == true end
        end
    end
    return nil
end

local function read_widgets()
    for key, e in pairs(UI.inputs) do
        if ue.valid(e) then
            local ok, v = pcall(function() return e:GetText() end)
            if ok then cfg.set(key, ue.str(v)) end
        end
    end
    for key, list in pairs(UI.checks) do
        local v = check_value(list)
        if v ~= nil then cfg.set(key, v) end
    end
end

local function fill_widgets()
    for key, e in pairs(UI.inputs) do
        if ue.valid(e) then pcall(function() e:SetText(FText(tostring(cfg.get(key) or ""))) end) end
    end
    for key, list in pairs(UI.checks) do
        local v = cfg.get(key) == true
        UI.check_state[key] = v
        for _, cb in ipairs(list) do
            if ue.valid(cb) then pcall(function() cb:SetIsChecked(v) end) end
        end
    end
end

-- A setting shown twice («Основное» and its group): a click on one copy
-- sets the other (4 Hz, settings tab only).
local function sync_checks()
    for key, list in pairs(UI.checks) do
        if #list > 1 then
            local last = UI.check_state[key]
            local new_v = nil
            for _, cb in ipairs(list) do
                if ue.valid(cb) then
                    local ok, v = pcall(function() return cb:IsChecked() end)
                    if ok and (v == true) ~= last then new_v = v == true break end
                end
            end
            if new_v ~= nil then
                UI.check_state[key] = new_v
                for _, cb in ipairs(list) do
                    if ue.valid(cb) then pcall(function() cb:SetIsChecked(new_v) end) end
                end
            end
        end
    end
end

local function save_settings(quiet)
    read_widgets()
    local ok = cfg.save()
    if not quiet then log.say(ok and "settings_saved" or "settings_failed", ok and "ok" or "err") end
end

-- ---------------------------------------------------------------------------
-- Game font (title, tabs, button labels)
-- ---------------------------------------------------------------------------

-- Plain values, kept across worlds: the font asset path of the game's menu
-- buttons, its typeface and letter spacing.
local GAME_FONT = { path = nil, typeface = nil, spacing = nil }
UI.game_font_info = GAME_FONT

-- A TextBlock of the game's own menu: the main menu's "Load" button, else
-- the pause screen's "Settings" (both exist only while on screen).
local function game_font_source()
    local W = require("sdc_widgets")
    for _, spec in ipairs({ { "MenuWidget_C", "Load" }, { "PauseScreen_C", "Settings" } }) do
        local w = ue.find_first(spec[1])
        if w then
            local b = W.child(w, spec[2])
            local t = b and W.first_text(b)
            if ue.valid(t) then return t, spec[1] end
        end
    end
    return nil
end

-- Puts the game font on every registered text from index `from` on.
-- Returns the number of texts changed.
local function put_game_font(font_obj, from)
    local n = 0
    for i = from or 1, #UI.gtexts do
        local g = UI.gtexts[i]
        if ue.valid(g.w) then
            local ok = pcall(function()
                local f = g.w.Font
                f.FontObject = font_obj
                if GAME_FONT.typeface and GAME_FONT.typeface ~= "" and GAME_FONT.typeface ~= "None" then
                    f.TypefaceFontName = FName(GAME_FONT.typeface)
                end
                if type(GAME_FONT.spacing) == "number" then f.LetterSpacing = GAME_FONT.spacing end
                f.Size = g.size
                g.w:SetFont(f)
            end)
            if ok then n = n + 1 end
        end
    end
    return n
end

function UI.apply_game_font(force)
    if UI.gfont_done and not force then return end
    local now = os.clock()
    if not force and UI.gfont_next and now < UI.gfont_next then return end
    UI.gfont_next = now + 5
    UI.gfont_tries = (UI.gfont_tries or 0) + 1
    local font_obj, from = nil, nil
    local src, where = game_font_source()
    if src then
        pcall(function()
            local f = src.Font
            font_obj = f.FontObject
            GAME_FONT.typeface = ue.str(f.TypefaceFontName)
            GAME_FONT.spacing = tonumber(f.LetterSpacing)
        end)
        if ue.valid(font_obj) then GAME_FONT.path = ue.path(font_obj) end
        from = where
    end
    if not ue.valid(font_obj) and GAME_FONT.path then
        font_obj = ue.find_object(GAME_FONT.path)
        from = "cached path"
    end
    if not ue.valid(font_obj) then
        if UI.gfont_tries <= 2 then log.info("ui: game menu font not found yet (engine font for now)") end
        return
    end
    local n = put_game_font(font_obj, 1)
    UI.gfont_done = true
    UI.gfont_obj_path = GAME_FONT.path
    log.info("ui: game font %s typeface %s (from %s) on %d texts", log.ascii(tostring(GAME_FONT.path)),
        log.ascii(tostring(GAME_FONT.typeface)), tostring(from), n)
end

-- Texts made after the font was applied (a section opened later).
local function game_font_new(from)
    if not UI.gfont_done or not GAME_FONT.path then return end
    local font_obj = ue.find_object(GAME_FONT.path)
    if ue.valid(font_obj) then put_game_font(font_obj, from) end
end

-- ---------------------------------------------------------------------------
-- Tabs, sections, relabelling
-- ---------------------------------------------------------------------------

local function sec_open(sec)
    while sec do
        if not sec.open then return false end
        sec = sec.parent
    end
    return true
end

local function refresh_active()
    local list = {}
    for _, b in ipairs(UI.buttons) do
        if (b.tab == nil or b.tab == UI.tab) and sec_open(b.sec) then list[#list + 1] = b end
    end
    UI.active = list
    UI.active_dirty = false
end

local function build_section(sec)
    if sec.built then return end
    sec.built = true
    local first_g = #UI.gtexts + 1
    local saved_tab, saved_sec = CTX.tab, CTX.sec
    CTX.tab, CTX.sec = sec.tab, sec
    local ok, body = pcall(sec.build)
    CTX.tab, CTX.sec = saved_tab, saved_sec
    if not ok or not body then
        log.err("ui: section '%s' failed: %s", sec.name, tostring(body))
        return
    end
    sec.body = body
    vadd(sec.holder, body, 2, 6, sec.indent, 0)
    if UI.widget_live then
        log.info("ui: section '%s' built", sec.name)
        game_font_new(first_g)
    end
end

local function set_chevron(arrow, open)
    pcall(function() arrow:SetRenderTransformAngle(open and 90 or 0) end)
end

function UI.toggle_section(sec, open)
    if open == nil then open = not sec.open end
    sec.open = open
    if open then build_section(sec) end
    if sec.body then show(sec.body, open) end
    set_chevron(sec.arrow, open)
    UI.active_dirty = true
end

-- A collapsible section: a header row (arrow + title) that shows / hides
-- its body. The body is built the first time it opens.
local function section(title_f, open, build_body, opts)
    opts = opts or {}
    local holder = new("VerticalBox")
    local row = new("HorizontalBox")
    local size = opts.size or 15
    local arrow = text(CHEVRON, size + 5, C.dim, { bold = true, justify = JUSTIFY_CENTER })
    pcall(function() arrow:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    set_chevron(arrow, open)
    hadd(row, sized(arrow, 14, nil), false, 0)
    local title = text(title_f(), size, C.bone, { bold = opts.bold ~= false })
    bind(title, title_f)
    hadd(row, title, true, 8)
    local sb = new("SizeBox")
    pcall(function() sb:SetMinDesiredHeight(opts.height or 32) end)
    local ss = sb:SetContent(row)
    pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() ss:SetPadding(margin(6, 0, 6, 0)) end)
    local sec = { open = open, arrow = arrow, holder = holder, build = build_body, built = false,
                  tab = CTX.tab, parent = CTX.sec, indent = opts.indent or 16, name = opts.name or "?" }
    local bg = clickable(sb, COL.ghost, function() UI.toggle_section(sec) end, "section " .. sec.name)
    vadd(holder, bg, 0, 0)
    UI.sections[#UI.sections + 1] = sec
    if open then build_section(sec) end
    return holder, sec
end

function UI.select_tab(id)
    if not UI.pages[id] then return end
    UI.tab = id
    for tid, page in pairs(UI.pages) do show(page, tid == id) end
    for tid, tu in pairs(UI.tab_ui or {}) do
        set_color(tu.text, tid == id and C.bone or C.dim)
        pcall(function() tu.bar:SetBrushColor(tid == id and C.amber or C.clear) end)
    end
    if ue.valid(UI.scroll) then pcall(function() UI.scroll:ScrollToStart() end) end
    UI.active_dirty = true
end

local function update_lang_buttons()
    local cur = i18n.setting()
    for v, rec in pairs(UI.lang_buttons or {}) do
        rec.colors = v == cur and COL.primary or COL.secondary
        rec.hovered = false
        if ue.valid(rec.bg) then pcall(function() rec.bg:SetBrushColor(rec.colors.base) end) end
    end
end

-- Every registered text again, in the current language.
function UI.relabel()
    UI.lang_built = i18n.language()
    local n = 0
    for _, e in ipairs(UI.ltexts) do
        if ue.valid(e.w) then
            local ok, s = pcall(e.f)
            if ok and type(s) == "string" then
                if e.kind == "tip" then
                    pcall(function() e.w:SetToolTipText(FText(s)) end)
                elseif e.kind == "hint" then
                    pcall(function() e.w:SetHintText(FText(s)) end)
                else
                    pcall(function() e.w:SetText(FText(s)) end)
                end
                n = n + 1
            end
        end
    end
    update_lang_buttons()
    UI.chip_shown = nil
    UI.status_shown = nil
    if UI.open then UI.refresh_status() end
    log.info("ui: language %s: %d texts relabelled", UI.lang_built, n)
end

local function set_language(v)
    i18n.set(v)                 -- listeners relabel the panel
    update_lang_buttons()
    if cfg.save() then log.info("ui: language setting %s saved", i18n.setting()) end
end

i18n.listeners.ui = function()
    if ue.valid(UI.widget) then UI.relabel() end
end

-- ---------------------------------------------------------------------------
-- Build: pages
-- ---------------------------------------------------------------------------

local function check_row(key, wrap_at)
    -- a second copy of a setting starts as the first one shows it (unsaved)
    if UI.check_state[key] == nil then UI.check_state[key] = cfg.get(key) == true end
    local cb = new("CheckBox")
    local v = UI.check_state[key]
    pcall(function() cb:SetIsChecked(v) end)
    local lf = function() return i18n.label(key) end
    local df = function() return i18n.desc(key) end
    local t = text(lf(), 14, C.bone)
    pcall(function() t.WrapTextAt = wrap_at or CHECK_WRAP.main end)
    pcall(function() t:SetWrapTextAt(wrap_at or CHECK_WRAP.main) end)
    bind(t, lf)
    pcall(function() cb:SetContent(box(t, C.clear, 8, 3, 0, 3)) end)
    pcall(function() cb:SetToolTipText(FText(df())) end)
    bind(cb, df, "tip")
    local list = UI.checks[key]
    if not list then
        list = {}
        UI.checks[key] = list
    end
    list[#list + 1] = cb
    return cb
end

local function on_join()
    save_settings(true)
    session.join(cfg.get("host_ip"), cfg.get("port"), false)
end

local function on_host()
    save_settings(true)
    session.host_on_next_load()
    fill_widgets()
end

-- A small round dot (status, player rows).
local function dot(color, size)
    local d = box(nil, color or C.dim)
    pcall(function()
        local br = d.Background
        br.DrawAs = 4                       -- ESlateBrushDrawType::RoundedBox
        br.OutlineSettings.RoundingType = 1 -- HalfHeightRadius
    end)
    return d, sized(d, size or 8, size or 8)
end

-- A text cut to `n` characters (names in the lists).
local function cut(s, n)
    s = tostring(s or "")
    if (utf8.len(s) or #s) <= n then return s end
    local out, i = {}, 0
    for _, c in utf8.codes(s) do
        i = i + 1
        if i > n - 1 then break end
        out[#out + 1] = utf8.char(c)
    end
    return table.concat(out) .. "…"
end

-- ---------------------------------------------------------------------------
-- Players: who is in this world. In the header under the status line (seen
-- on every tab), while someone besides this player is there; live while the
-- panel is open.
-- ---------------------------------------------------------------------------

local PLAYER_ROWS = 8
local STATE_COLOR = { host = C.ok, game = C.ok, loading = C.warn, connecting = C.warn, dead = C.err }

local function build_players()
    local vb = new("VerticalBox")
    UI.players_title = text(T("pl_title_none"), 14, C.bone, { bold = true })
    vadd(vb, UI.players_title, 0, 4)
    UI.player_rows = {}
    for i = 1, PLAYER_ROWS do
        local hb = new("HorizontalBox")
        local d, ds = dot(C.dim, 8)
        hadd(hb, ds, false, 2, VALIGN_CENTER)
        local name = text("", 14, C.bone)
        pcall(function() name.Clipping = 1 end)    -- EWidgetClipping::ClipToBounds
        hadd(hb, name, true, 10)
        local state = text("", 12, C.dim)
        hadd(hb, state, false, 8)
        local ping = text("", 12, C.dim, { justify = 2 })
        hadd(hb, sized(ping, 58), false, 6)
        vadd(vb, hb, 0, 1)
        show(hb, false)
        UI.player_rows[i] = { row = hb, dot = d, name = name, state = state, ping = ping }
    end
    UI.players_more = text("", 12, C.dim)
    vadd(vb, UI.players_more, 0, 2)
    show(UI.players_more, false)
    UI.players_empty = text("", 13, C.dim, { wrap = true })
    vadd(vb, UI.players_empty, 0, 0)
    show(UI.players_empty, false)
    UI.players_sig = nil
    UI.players_box = vb
    show(vb, false)
    return vb
end

-- The player list: sdc_session.roster() (host: live; client: the host's
-- ROSTER), in the words of the current language.
function UI.players_model(m)
    local st = session.state or {}
    local role = UI.test_role or st.role
    local list = {}
    if role == "host" or role == "client" then
        local ok, r = pcall(function()
            if UI.test_roster then return UI.test_roster end
            return type(session.roster) == "function" and session.roster() or {}
        end)
        if ok and type(r) == "table" then list = r end
    end
    local out = { rows = {}, title = T("pl_title_none"), empty = nil, more = nil }
    -- shown while someone besides this player is there (the status line says the rest)
    out.visible = (role == "host" and #list >= 2) or (role == "client" and #list >= 1)
    if role == "host" or role == "client" then
        if #list > 0 then out.title = T("pl_title", #list) end
        if role == "host" and #list <= 1 then out.empty = T("pl_waiting") end
        if role == "client" and #list == 0 then out.empty = T("pl_connecting") end
    elseif m and m.pending then
        out.empty = T("pl_connecting")
    elseif role == "standalone" then
        out.empty = ue.in_main_menu() and T("pl_closed_menu") or T("pl_single")
    else
        out.empty = T("pl_loading")
    end
    for i, e in ipairs(list) do
        if i > PLAYER_ROWS then
            out.more = T("pl_more", #list - PLAYER_ROWS)
            break
        end
        local state = e.state or "game"
        out.rows[#out.rows + 1] = {
            name = e.me and T("pl_you", cut(e.name, 22)) or cut(e.name, 26),
            state = T("pl_state_" .. state),
            ping = (e.ping and not e.host) and T("pl_ping", math.floor(e.ping)) or "",
            color = STATE_COLOR[state] or C.dim,
        }
    end
    return out
end

local function refresh_players(m)
    if not UI.player_rows then return end
    local pm = UI.players_model(m)
    local sig = { tostring(pm.visible), pm.title, pm.empty or "", pm.more or "" }
    for _, r in ipairs(pm.rows) do sig[#sig + 1] = r.name .. "|" .. r.state .. "|" .. r.ping end
    sig = table.concat(sig, "\1")
    if sig == UI.players_sig then return end
    UI.players_sig = sig
    pcall(function() UI.players_title:SetText(FText(pm.title)) end)
    for i, row in ipairs(UI.player_rows) do
        local r = pm.rows[i]
        if r then
            pcall(function() row.name:SetText(FText(r.name)) end)
            pcall(function() row.state:SetText(FText(r.state)) end)
            pcall(function() row.ping:SetText(FText(r.ping)) end)
            pcall(function() row.dot:SetBrushColor(r.color) end)
        end
        show(row.row, r ~= nil)
    end
    if pm.more then pcall(function() UI.players_more:SetText(FText(pm.more)) end) end
    show(UI.players_more, pm.more ~= nil, VIS_HIT_TEST_INVISIBLE)
    if pm.empty then pcall(function() UI.players_empty:SetText(FText(pm.empty)) end) end
    show(UI.players_empty, pm.visible and pm.empty ~= nil, VIS_HIT_TEST_INVISIBLE)
    show(UI.players_box, pm.visible == true)
end

-- ---------------------------------------------------------------------------
-- Steam (sdc_steamlink: a helper that carries the game's UDP over Steam P2P)
-- ---------------------------------------------------------------------------
-- Used only through pcall(require, "sdc_steamlink") and its interface:
--   status() -> { state = off|no_steam|starting|ready|hosting|joining|connected|error,
--                 detail = string|nil, friends_only = bool }
--   friends() -> { { id, name, joinable, status }, ... }
--   join(id) -> ok, why          invite() -> ok, why
-- Without the module (builds before 0.7.0) the block is one dim line.

local FRIEND_ROWS = 6
local STEAM_DOT = { ready = C.ok, hosting = C.ok, connected = C.ok, starting = C.warn, joining = C.warn,
                    off = C.dim, no_steam = C.warn, error = C.err }

local function steamlink()
    if package.loaded["sdc_steamlink"] == nil then
        local now = os.clock()
        if UI.steam_missing_at and now - UI.steam_missing_at < 30 then return nil end
        local ok, m = pcall(require, "sdc_steamlink")
        if not ok or type(m) ~= "table" then
            if not UI.steam_missing_at then log.info("ui: no Steam link module (sdc_steamlink): %s", tostring(m):sub(1, 120)) end
            UI.steam_missing_at = now
            return nil
        end
        UI.steam_missing_at = nil
        return m
    end
    local m = package.loaded["sdc_steamlink"]
    return type(m) == "table" and m or nil
end

local function on_steam_invite()
    local sl = steamlink()
    if not sl or type(sl.invite) ~= "function" then return end
    local ok, done, why, why_key = pcall(sl.invite)
    if not ok then
        log.toast(T("steam_invite_failed", tostring(done)), "warn", 8, "steam link invite: " .. tostring(done), "steam_invite")
    elseif done == false then
        -- `why` is the module's sentence in the player's language
        log.toast(tostring(why or T("steam_error_plain")), "warn", 8,
            "steam link invite refused: " .. tostring(why_key), "steam_invite")
    end
end

local function on_steam_join(i)
    local f = UI.steam_friends and UI.steam_friends[i]
    local sl = steamlink()
    if not f or not sl or type(sl.join) ~= "function" then return end
    log.info("ui: steam: join %s", log.ascii(tostring(f.name)))
    -- a started join: its progress and failures are the module's own
    -- notifications (sl_*); a refusal (ok = false) is shown here
    local ok, done, why, why_key = pcall(sl.join, f.id)
    if not ok then
        log.toast(T("steam_join_failed", tostring(done)), "err", 8, "steam link join: " .. tostring(done), "steam_join")
    elseif done == false then
        log.toast(tostring(why or T("steam_error_plain")), "warn", 8,
            "steam link join refused: " .. tostring(why_key), "steam_join")
    end
end

local function build_steam()
    local vb = new("VerticalBox")
    local hb = new("HorizontalBox")
    local d, ds = dot(C.dim, 8)
    UI.steam_dot = d
    local dslot = hadd(hb, ds, false, 2, VALIGN_TOP)
    pcall(function() dslot:SetPadding(margin(2, 5, 0, 0)) end)
    UI.steam_status = text("", 14, C.bone, { wrap = true })
    hadd(hb, UI.steam_status, true, 10, VALIGN_TOP)
    UI.steam_status_row = hb
    vadd(vb, hb, 0, 2)
    UI.steam_detail = text("", 12, C.dim, { wrap = true })
    vadd(vb, UI.steam_detail, 0, 4, 20, 0)
    UI.steam_later = ltext("steam_later", 14, C.bone, { wrap = true })
    vadd(vb, UI.steam_later, 0, 0)
    UI.steam_note = caption("steam_friends_only")
    vadd(vb, UI.steam_note, 0, 6)
    UI.steam_invite = button("btn_steam_invite", nil, on_steam_invite)
    vadd(vb, UI.steam_invite, 4, 8)
    UI.steam_friends_title = ltext("steam_friends", 12, C.dim, { bold = true })
    vadd(vb, UI.steam_friends_title, 2, 4)
    UI.friend_rows = {}
    for i = 1, FRIEND_ROWS do
        local row = new("HorizontalBox")
        local name = text("", 14, C.bone)
        pcall(function() name.Clipping = 1 end)
        hadd(row, name, true, 2)
        local status = text("", 12, C.dim)
        hadd(row, status, false, 8)
        local jb = small_button("btn_steam_join", function() on_steam_join(i) end, 28)
        hadd(row, jb, false, 8, VALIGN_CENTER)
        vadd(vb, row, 1, 2)
        show(row, false)
        UI.friend_rows[i] = { row = row, name = name, status = status, join = jb }
    end
    UI.steam_more = text("", 12, C.dim)
    vadd(vb, UI.steam_more, 0, 2)
    UI.steam_none = ltext("steam_no_friends", 13, C.dim, { wrap = true })
    vadd(vb, UI.steam_none, 0, 0)
    UI.steam_sig = nil
    for _, w in ipairs({ UI.steam_status_row, UI.steam_detail, UI.steam_note, UI.steam_invite, UI.steam_friends_title,
                         UI.steam_more, UI.steam_none }) do show(w, false) end
    return vb
end

-- What the Steam block shows now.
function UI.steam_model()
    local sl = steamlink()
    if not sl or type(sl.status) ~= "function" then return { available = false } end
    local ok, s = pcall(sl.status)
    if not ok or type(s) ~= "table" then
        return { available = true, state = "error", text = T("steam_error_plain"), color = C.err, friends = {} }
    end
    local state = tostring(s.state or "off")
    local m = { available = true, state = state, color = STEAM_DOT[state] or C.dim, friends = {} }
    local detail = type(s.detail) == "string" and s.detail ~= "" and s.detail or nil
    if state == "error" then
        -- missing helper, crashed helper, restart needed: the sentence says what to do
        m.text = detail or T("steam_error_plain")
        if s.restart_needed or s.detail_key == "sl_st_restart" then m.color = C.warn end
    elseif detail then
        m.text = detail
    else
        local key = "steam_" .. state
        m.text = i18n.STR.en[key] and T(key) or state
    end
    -- the mod changed Engine.ini at this start: one restart before Steam co-op
    if s.restart_needed and state ~= "error" then
        local okr, line = pcall(function() return sl.tr and sl.tr("sl_st_restart") end)
        m.detail = (okr and type(line) == "string" and line ~= "sl_st_restart") and line or T("steam_restart")
    end
    m.ready = state == "ready" or state == "hosting" or state == "connected"
    m.friends_only = state == "hosting" and s.friends_only == true
    if m.ready and type(sl.friends) == "function" then
        local okf, list = pcall(sl.friends)
        if okf and type(list) == "table" then m.friends = list end
    end
    -- joinable friends first, then by name
    table.sort(m.friends, function(a, b)
        if (a.joinable == true) ~= (b.joinable == true) then return a.joinable == true end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return m
end

-- Join through Steam: a friend hosting a co-op world with this mod version
-- (version unknown = allowed).
function UI.can_join_friend(f)
    if type(f) ~= "table" or f.joinable ~= true then return false end
    local mine = tostring(session.VERSION or UI.VERSION or "")
    return f.version == nil or f.version == "" or mine == "" or mine == "?" or tostring(f.version) == mine
end

local function refresh_steam()
    if not UI.friend_rows then return end
    local m = UI.steam_model()
    UI.steam_ready = m.ready == true
    local sig = { tostring(m.available), tostring(m.state), m.text or "", m.detail or "", tostring(m.friends_only),
                  UI.lang_built or "" }
    for _, f in ipairs(m.friends or {}) do
        sig[#sig + 1] = tostring(f.id) .. "|" .. tostring(f.name) .. "|" .. tostring(f.joinable) .. "|" .. tostring(f.status)
    end
    sig = table.concat(sig, "\1")
    if sig == UI.steam_sig then return end
    UI.steam_sig = sig
    show(UI.steam_later, not m.available, VIS_HIT_TEST_INVISIBLE)
    show(UI.steam_status_row, m.available)
    if m.available then
        pcall(function() UI.steam_status:SetText(FText(m.text or "")) end)
        pcall(function() UI.steam_dot:SetBrushColor(m.color or C.dim) end)
    end
    if m.detail then pcall(function() UI.steam_detail:SetText(FText(m.detail)) end) end
    show(UI.steam_detail, m.detail ~= nil, VIS_HIT_TEST_INVISIBLE)
    show(UI.steam_note, m.friends_only == true, VIS_HIT_TEST_INVISIBLE)
    show(UI.steam_invite, m.ready == true)
    show(UI.steam_friends_title, m.ready == true, VIS_HIT_TEST_INVISIBLE)
    local friends = m.friends or {}
    UI.steam_friends = {}
    for i, row in ipairs(UI.friend_rows) do
        local f = m.ready and friends[i] or nil
        UI.steam_friends[i] = f
        if f then
            local can_join = UI.can_join_friend(f)
            -- a row with «Подключиться» has less room (the Russian label is long)
            local room = can_join and (i18n.language() == "ru" and 12 or 20) or 20
            pcall(function() row.name:SetText(FText(cut(f.name, room))) end)
            local st = f.status and f.status ~= "" and tostring(f.status)
                or T(f.joinable and "steam_friend_hosting" or "steam_friend_playing")
            pcall(function() row.status:SetText(FText(cut(st, can_join and 16 or 26))) end)
            set_color(row.status, (f.joinable and not can_join) and C.warn or C.dim)
            show(row.join, can_join)
        end
        show(row.row, f ~= nil)
    end
    local more = m.ready and #friends > FRIEND_ROWS
    if more then pcall(function() UI.steam_more:SetText(FText(T("steam_more", #friends - FRIEND_ROWS))) end) end
    show(UI.steam_more, more, VIS_HIT_TEST_INVISIBLE)
    show(UI.steam_none, m.ready == true and #friends == 0, VIS_HIT_TEST_INVISIBLE)
    -- no usable Steam link: the way to the IP tab; usable: how Steam joining goes
    local blocked = not m.available or m.state == "off" or m.state == "no_steam" or m.state == "error"
    show(UI.steam_to_ip, blocked)
    show(UI.steam_help, m.ready == true, VIS_HIT_TEST_INVISIBLE)
end

-- The tab the player picked last (kept while the game runs); before that,
-- Steam when the Steam link is usable, else IP.
UI.user_tab = nil
function UI.pick_tab(id)
    UI.user_tab = id
    UI.select_tab(id)
end

function UI.default_tab()
    if UI.user_tab and UI.pages[UI.user_tab] then return UI.user_tab end
    local ok, m = pcall(UI.steam_model)
    return (ok and type(m) == "table" and m.ready) and "steam" or "ip"
end

-- Steam tab: the Steam link (sdc_steamlink); without it, the way to the IP tab.
local function build_steam_page()
    local vb = new("VerticalBox")
    vadd(vb, build_steam(), 0, 6)
    UI.steam_to_ip = button("btn_go_ip", nil, function() UI.pick_tab("ip") end)
    vadd(vb, UI.steam_to_ip, 6, 8)
    UI.steam_help = caption("help_steam")
    vadd(vb, UI.steam_help, 8, 0)
    show(UI.steam_help, false)
    return vb
end

-- IP tab: the address, the how-to (Radmin VPN / ZeroTier / port forwarding)
-- and a quick connection test on a fresh map.
local function build_ip_page()
    local vb = new("VerticalBox")
    vadd(vb, heading("sec_join"), 0, 8)
    local caps = new("HorizontalBox")
    hadd(caps, ltext("f_ip", 12, C.dim), true)
    hadd(caps, sized(ltext("f_port", 12, C.dim), 90), false, 8)
    vadd(vb, caps, 0, 3)
    local addr = new("HorizontalBox")
    hadd(addr, input("host_ip", "f_ip_hint"), true, nil, VALIGN_FILL)
    hadd(addr, sized(input("port"), 90), false, 8, VALIGN_FILL)
    vadd(vb, addr, 0, 8)
    vadd(vb, (button("btn_join", "primary", on_join)), 0, 10)

    local help = section(lfn("sec_help"), true, function()
        local b = new("VerticalBox")
        vadd(b, ltext("help_text", 13, C.dim, { wrap = true }), 0, 0)
        return b
    end, { name = "help", indent = 6 })
    vadd(vb, help, 0, 10)

    vadd(vb, heading("sec_test"), 4, 8)
    vadd(vb, (button("btn_fresh", nil, function() session.start_fresh_server() end)), 0, 4)
    vadd(vb, caption("fresh_caption"), 0, 0)
    return vb
end

local function build_char()
    local vb = new("VerticalBox")
    vadd(vb, heading("sec_name"), 0, 8)
    vadd(vb, input("player_name", "f_name_hint"), 0, 14)

    vadd(vb, heading("sec_looks"), 0, 8)
    -- the co-op character in the game's own creator (main menu, sdc_charcreate)
    UI.char_row = new("VerticalBox")
    vadd(UI.char_row, (button("btn_looks", nil, function()
        UI.set_open(false)
        local okc, cc = pcall(require, "sdc_charcreate")
        if okc then cc.open_from_menu("panel") end
    end)), 0, 4)
    vadd(UI.char_row, caption("looks_caption"), 0, 0)
    vadd(vb, UI.char_row, 0, 14)
    UI.looks_off = ltext("looks_menu_only", 13, C.dim, { wrap = true })
    vadd(vb, UI.looks_off, 0, 14)
    show(UI.looks_off, false)

    UI.rescue_title = heading("sec_rescue")
    vadd(vb, UI.rescue_title, 0, 8)
    -- Shown only while this client's character is dead (replaces the game's
    -- death screen, whose buttons would respawn the host / load a save).
    UI.respawn_row = button("btn_respawn", "primary", function() session.request_respawn() end)
    vadd(vb, UI.respawn_row, 0, 10)
    -- Client with a character: stuck in a wall, fell through the world, can't
    -- move -> the host puts the character next to itself or on a game start
    -- point (sdc_players.request_unstuck; alive, not in a vehicle, cooldown).
    UI.unstuck_row = new("VerticalBox")
    vadd(UI.unstuck_row, ltext("unstuck_caption", 13, C.dim, { wrap = true }), 0, 6)
    vadd(UI.unstuck_row, (button("btn_unstuck_host", nil, function()
        UI.set_open(false)
        require("sdc_players").request_unstuck("host")
    end)), 0, 6)
    vadd(UI.unstuck_row, (button("btn_unstuck_start", nil, function()
        UI.set_open(false)
        require("sdc_players").request_unstuck("start")
    end)), 0, 0)
    vadd(vb, UI.unstuck_row, 0, 10)
    UI.char_offline = ltext("char_ingame_only", 13, C.dim, { wrap = true })
    vadd(vb, UI.char_offline, 0, 0)
    show(UI.respawn_row, UI.dead == true)
    show(UI.unstuck_row, false)
    show(UI.rescue_title, UI.dead == true)
    show(UI.char_offline, UI.dead ~= true)
    UI.char_state = nil
    return vb
end

local function build_main_settings()
    local b = new("VerticalBox")
    for _, key in ipairs(i18n.MAIN) do
        if i18n.schema_row(key) then vadd(b, check_row(key, CHECK_WRAP.main), 2, 2) end
    end
    return b
end

local function build_all_settings()
    local b = new("VerticalBox")
    vadd(b, caption("all_caption"), 2, 6)
    for _, g in ipairs(i18n.groups()) do
        local keys, id = g.keys, g.id
        local h = section(function() return T("group_count", i18n.group_name(id), #keys) end, false, function()
            local gb = new("VerticalBox")
            for _, key in ipairs(keys) do vadd(gb, check_row(key, CHECK_WRAP.group), 2, 2) end
            return gb
        end, { name = "group " .. id, size = 14, height = 30, indent = 22 })
        vadd(b, h, 0, 1)
    end
    return b
end

-- ---------------------------------------------------------------------------
-- Bug reports: the GitHub issue form (prefilled) and the UE4SS.log folder
-- ---------------------------------------------------------------------------

local ISSUE_URL = "https://github.com/Chepchek/SurrounDead-Coop/issues/new?template=bug_report.yml"

local function url_encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
UI.url_encode = url_encode

-- The issue form with the mod version and this machine's role filled in
-- (field ids and role options of .github/ISSUE_TEMPLATE/bug_report.yml).
function UI.issue_url()
    local url = ISSUE_URL .. "&version=" .. url_encode(UI.VERSION or "?")
    local role = (session.state or {}).role
    local r = (role == "host" and "У хоста") or (role == "client" and "У клиента") or nil
    if r then url = url .. "&role=" .. url_encode(r) end
    return url
end

-- Absolute path of the folder with UE4SS.log (<game>\Binaries\Win64\ue4ss).
-- The mod folder is relative to the process directory (Binaries\Win64);
-- KismetSystemLibrary makes it absolute (game thread).
function UI.log_dir()
    if UI.log_dir_cache then return UI.log_dir_cache end
    local rel = (UI.mod_dir or "ue4ss/Mods/SDCoop"):gsub("[/\\]+Mods[/\\]+[^/\\]+[/\\]*$", "")
    local abs = nil
    if not rel:match("^%a:[/\\]") then
        local ksl = ue.ksl()
        if ksl then
            abs = ue.fstring(ue.try(function() return ksl:ConvertToAbsolutePath(rel) end))
            if abs == "" or abs == rel then abs = nil end
            if not abs then
                local proj = ue.fstring(ue.try(function() return ksl:GetProjectDirectory() end))
                if proj:match("^%a:[/\\]") then
                    abs = proj:gsub("[/\\]*$", "/") .. "Binaries/Win64/" .. rel
                end
            end
        end
    end
    local out = (abs or rel):gsub("/", "\\"):gsub("\\+$", "")
    if out:match("^%a:\\") then UI.log_dir_cache = out end
    return out
end

-- The folder as a file:/// URL. KismetSystemLibrary.LaunchURL gives a
-- plain path to the default WEB BROWSER (tested 0.6.68: the folder opened
-- as a page in the browser); a file:// URL goes to the shell's file
-- protocol handler, i.e. Explorer. Spaces / '#' / '%' are escaped; other
-- characters (Cyrillic user names) stay as they are (ShellExecuteW).
function UI.log_dir_url()
    local p = UI.log_dir():gsub("\\", "/"):gsub("%%", "%%25"):gsub(" ", "%%20"):gsub("#", "%%23")
    return "file:///" .. p
end

-- KismetSystemLibrary.LaunchURL: https -> the default browser, file:// ->
-- Explorer. UI.test_dry_run: only logged.
local function launch(target, what)
    if UI.test_dry_run then
        log.info("ui: bug: would open the %s: %s", what, log.ascii(target))
        return true
    end
    local ksl = ue.ksl()
    local ok, err = false, "KismetSystemLibrary not found"
    if ksl then ok, err = pcall(function() ksl:LaunchURL(target) end) end
    log.info("ui: bug: open the %s (%s): %s", what, log.ascii(target), ok and "ok" or tostring(err))
    return ok, err
end

local function on_bug_form()
    local url = UI.issue_url()
    local ok, err = launch(url, "issue form")
    log.toast(ok and T("bug_opening_web") or T("bug_open_failed", url), ok and "info" or "warn", 8,
        "bug report: issue form " .. (ok and "opened" or ("failed: " .. tostring(err))), "bug_open")
end

local function on_bug_logs()
    local dir = UI.log_dir()
    local ok, err = launch(UI.log_dir_url(), "log folder")
    log.toast(ok and T("bug_opening_folder") or T("bug_open_failed", dir), ok and "info" or "warn", 8,
        "bug report: log folder " .. (ok and "opened" or ("failed: " .. tostring(err))), "bug_open")
end
UI.on_bug_form, UI.on_bug_logs = on_bug_form, on_bug_logs

local function build_bug()
    local b = new("VerticalBox")
    vadd(b, ltext(function() return T("bug_text", tostring(UI.VERSION)) end, 13, C.bone, { wrap = true }), 0, 8)
    vadd(b, ltext("bug_template", 12, C.dim, { wrap = true }), 0, 10)
    vadd(b, (button("btn_bug_form", "primary", on_bug_form)), 0, 6)
    vadd(b, (button("btn_bug_logs", nil, on_bug_logs)), 0, 10)
    vadd(b, caption("bug_path"), 0, 3)
    -- the path as selectable text (when Explorer does not open)
    UI.bug_path_box = input_box(UI.log_dir(), nil)
    pcall(function() UI.bug_path_box:SetIsReadOnly(true) end)
    pcall(function() UI.bug_path_box.WidgetStyle.TextStyle.Font.Size = 12 end)
    vadd(b, UI.bug_path_box, 0, 0)
    return b
end

-- Footer link / error toast: the settings tab with this section open.
function UI.open_bug()
    UI.select_tab("settings")
    if UI.bug_section then UI.toggle_section(UI.bug_section, true) end
    if ue.valid(UI.scroll) then pcall(function() UI.scroll:ScrollToEnd() end) end
end

local function build_settings()
    local vb = new("VerticalBox")
    vadd(vb, heading("sec_lang"), 0, 8)
    local row = new("HorizontalBox")
    UI.lang_buttons = {}
    local tip = lfn("lang_tip")
    for i, v in ipairs({ "auto", "ru", "en" }) do
        local bg, rec = button("lang_" .. v, nil, function() set_language(v) end, 34)
        pcall(function() rec.w:SetToolTipText(FText(tip())) end)
        bind(rec.w, tip, "tip")
        hadd(row, bg, true, i > 1 and 6 or nil, VALIGN_FILL)
        UI.lang_buttons[v] = rec
    end
    vadd(vb, row, 0, 4)
    vadd(vb, caption("lang_caption"), 0, 12)
    local main = section(lfn("sec_main"), true, build_main_settings, { name = "main", indent = 6 })
    vadd(vb, main, 0, 4)
    local all = section(lfn("sec_all"), false, build_all_settings, { name = "all", indent = 6 })
    vadd(vb, all, 0, 8)
    vadd(vb, caption("settings_note"), 4, 12)
    local bug, bug_sec = section(lfn("sec_bug"), false, build_bug, { name = "bug", indent = 6 })
    UI.bug_section = bug_sec
    vadd(vb, bug, 0, 0)
    update_lang_buttons()
    return vb
end

local PAGES = { steam = build_steam_page, ip = build_ip_page, char = build_char, settings = build_settings }

-- ---------------------------------------------------------------------------
-- Build: frame
-- ---------------------------------------------------------------------------

local function step(what)
    if UI.builds <= 1 then log.info("ui: build: %s", what) else log.debug("ui: build: %s", what) end
end

local function build_header()
    local hb = new("HorizontalBox")
    local title = ltext("title", 26, C.bone, { bold = true })
    game_font(title, 26)
    hadd(hb, title, true, 0, VALIGN_CENTER)
    hadd(hb, ltext(lfn("version", UI.VERSION), 12, C.dim), false, 10, VALIGN_CENTER)
    return hb
end

local function build_status()
    local hb = new("HorizontalBox")
    UI.status_dot = box(nil, C.dim)
    -- a round dot where the engine allows it (rounded brush), else a square
    pcall(function()
        local br = UI.status_dot.Background
        br.DrawAs = 4                       -- ESlateBrushDrawType::RoundedBox
        br.OutlineSettings.RoundingType = 1 -- HalfHeightRadius
    end)
    local ds = hadd(hb, sized(UI.status_dot, 10, 10), false, nil, VALIGN_TOP)
    pcall(function() ds:SetPadding(margin(0, 5, 0, 0)) end)
    local col = new("VerticalBox")
    UI.status_title = text("", 14, C.bone, { bold = true, wrap = true })
    vadd(col, UI.status_title, 0, 2)
    UI.status_body = text("", 12, C.dim, { wrap = true })
    vadd(col, UI.status_body, 0, 0)
    hadd(hb, col, true, 10, VALIGN_TOP)
    return hb
end

-- Under the status line, on every tab: what this machine can do next (open
-- its world for friends - the host side of both Steam and IP joining - or
-- disconnect), and who is in the world.
local function build_header_extra()
    local vb = new("VerticalBox")
    UI.host_row = new("VerticalBox")
    vadd(UI.host_row, (button("btn_host", "primary", on_host)), 0, 3)
    vadd(UI.host_row, caption("host_caption"), 0, 0)
    vadd(vb, UI.host_row, 10, 0)
    show(UI.host_row, false)
    UI.disconnect_row = button("btn_disconnect", nil, function() session.disconnect() end)
    vadd(vb, UI.disconnect_row, 10, 0)
    show(UI.disconnect_row, false)
    vadd(vb, build_players(), 10, 0)
    return vb
end

local function build_tabs()
    local row = new("HorizontalBox")
    UI.tab_ui = {}
    for i, id in ipairs(TABS) do
        local col = new("VerticalBox")
        local t = ltext("tab_" .. id, 15, C.dim, { bold = true, justify = JUSTIFY_CENTER })
        game_font(t, 15)
        local sb = new("SizeBox")
        pcall(function() sb:SetMinDesiredHeight(36) end)
        local ss = sb:SetContent(t)
        pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
        pcall(function() ss:SetPadding(margin(2, 0, 2, 0)) end)
        local tb, trec = clickable(sb, COL.ghost, function() UI.pick_tab(id) end, "tab " .. id)
        -- the button's own side padding (12) is what made four tabs too wide
        pcall(function()
            local style = trec.w.WidgetStyle
            style.NormalPadding.Left, style.NormalPadding.Right = 5, 5
            style.PressedPadding.Left, style.PressedPadding.Right = 5, 5
        end)
        vadd(col, tb, 0, 0)
        local bar = box(nil, C.clear)
        vadd(col, sized(bar, nil, 3), 0, 0)
        -- left-aligned, as wide as their labels (+ the button padding): the
        -- game font is wider than the engine font, equal thirds crowded them
        hadd(row, col, false, i > 1 and 4 or nil, VALIGN_FILL)
        UI.tab_ui[id] = { text = t, bar = bar }
    end
    return row
end

local function build_footer()
    local vb = new("VerticalBox")
    local row = new("HorizontalBox")
    hadd(row, (button("btn_save", nil, function() save_settings(false) end)), true, nil, VALIGN_FILL)
    hadd(row, (button("btn_close", nil, function() UI.set_open(false) end)), true, 8, VALIGN_FILL)
    vadd(vb, row, 0, 4)
    -- "report a bug" (a link to its section) on the left, the menu key on
    -- the right (it wraps rather than running into the link)
    local hints = new("HorizontalBox")
    local link = ltext("bug_link", 12, C.amber, { bold = true })
    local lb = new("SizeBox")
    pcall(function() lb:SetMinDesiredHeight(24) end)
    local ls = lb:SetContent(link)
    pcall(function() ls:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() ls:SetPadding(margin(0, 0, 0, 0)) end)
    hadd(hints, (clickable(lb, COL.ghost, function() UI.open_bug() end, "bug link")), false, nil)
    local key = tostring(cfg.get("menu_key") or "F7")
    hadd(hints, ltext(lfn("hint_key", key), 11, C.dim, { wrap = true, justify = 2 }), true, 8)
    vadd(vb, hints, 0, 0)
    return vb
end

local function build_panel()
    local root = new("Overlay")
    local panel = box(nil, C.night)
    local os_ = root:AddChildToOverlay(panel)
    pcall(function() os_:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() os_:SetHorizontalAlignment(HALIGN_FILL) end)
    -- the panel itself blocks clicks (no shots into the world through it)
    pcall(function() panel:SetVisibility(VIS_VISIBLE) end)
    local col = new("VerticalBox")
    panel:SetContent(col)

    step("header")
    vadd(col, build_header(), 14, 6, PAD, PAD)
    step("status")
    vadd(col, build_status(), 2, 0, PAD, PAD)
    vadd(col, build_header_extra(), 0, 12, PAD, PAD)
    step("tabs")
    vadd(col, build_tabs(), 0, 0, PAD - 6, PAD)
    vadd(col, line(), 0, 0, 0, 0)

    step("scroll box")
    local scroll = new("ScrollBox")
    UI.scroll = scroll
    pcall(function() scroll:SetVisibility(VIS_VISIBLE) end)
    pcall(function() scroll:SetScrollbarThickness({ X = 6, Y = 6 }) end)
    pcall(function() scroll:SetAlwaysShowScrollbar(false) end)
    local ss = vadd(col, scroll, 0, 0)
    pcall(function() ss:SetSize({ Value = 1.0, SizeRule = SIZE_FILL }) end)
    local pages = new("VerticalBox")
    local ps = scroll:AddChild(pages)
    pcall(function() ps:SetPadding(margin(PAD, 14, PAD, 14)) end)
    for _, id in ipairs(TABS) do
        step("page " .. id)
        CTX.tab, CTX.sec = id, nil
        local ok, page = pcall(PAGES[id])
        CTX.tab, CTX.sec = nil, nil
        if not ok then error("page " .. id .. ": " .. tostring(page)) end
        UI.pages[id] = page
        vadd(pages, page, 0, 0)
    end

    vadd(col, line(), 0, 0, 0, 0)
    step("footer")
    vadd(col, build_footer(), 12, 10, PAD, PAD)
    UI.select_tab(UI.pages[UI.tab or ""] and UI.tab or UI.default_tab())
    return root
end

-- The mod's toast, in the panel's style: an amber line over the night box,
-- a dot in the colour of the kind, bone text, and for a mod error a dim
-- line saying where to report it.
local function build_toast()
    local vb = new("VerticalBox")
    vadd(vb, sized(box(nil, C.amber), nil, 3), 0, 0)
    local hb = new("HorizontalBox")
    UI.toast_dot = box(nil, C.dim)
    pcall(function()
        local br = UI.toast_dot.Background
        br.DrawAs = 4                       -- ESlateBrushDrawType::RoundedBox
        br.OutlineSettings.RoundingType = 1 -- HalfHeightRadius
    end)
    local ds = hadd(hb, sized(UI.toast_dot, 9, 9), false, nil, VALIGN_TOP)
    pcall(function() ds:SetPadding(margin(0, 7, 0, 0)) end)
    local col = new("VerticalBox")
    UI.toast_text = text("", 15, C.bone, { bold = true })
    pcall(function() UI.toast_text.WrapTextAt = 720 end)
    vadd(col, UI.toast_text, 0, 0)
    UI.toast_hint = text("", 12, C.dim)
    pcall(function() UI.toast_hint.WrapTextAt = 720 end)
    vadd(col, UI.toast_hint, 4, 0)
    pcall(function() UI.toast_hint:SetVisibility(VIS_COLLAPSED) end)
    hadd(hb, col, true, 10, VALIGN_TOP)
    vadd(vb, box(hb, C.night, 16, 10, 18, 11), 0, 0)
    pcall(function() vb:SetVisibility(VIS_COLLAPSED) end)
    return vb
end

-- Small connection line in the corner: host name and ping on a client,
-- players on the host.
local function build_chip()
    local hb = new("HorizontalBox")
    local bar = hb:AddChildToHorizontalBox(sized(box(nil, C.amber), 3, nil))
    pcall(function() bar:SetVerticalAlignment(VALIGN_FILL) end)
    UI.chip_text = text("", 12, C.bone, { bold = true })
    local body = box(UI.chip_text, C.night, 10, 4, 10, 4)
    local slot = hb:AddChildToHorizontalBox(body)
    pcall(function() slot:SetVerticalAlignment(VALIGN_FILL) end)
    return hb
end

local function via_label(via)
    return T(via == "steam" and "chip_via_steam" or "chip_via_ip")
end

-- one remote player on the host's chip: "Name (Steam, 35 ms)"
local function chip_entry(e)
    local d = {}
    if e.via then d[#d + 1] = via_label(e.via) end
    if e.ping then d[#d + 1] = T("chip_ms", math.floor(e.ping)) end
    if #d == 0 then return tostring(e.name) end
    return T("chip_player", tostring(e.name), table.concat(d, ", "))
end

-- 1 s: the chip follows the session.
function UI.update_chip()
    if not ue.valid(UI.status_chip) or not ue.valid(UI.chip_text) then return end
    local st = session.state or {}
    local line_ = nil
    if not ue.in_main_menu() then
        if st.role == "client" then
            local cs = st.client or {}
            local name = cs.host_name or "?"
            local via = st.join and st.join.via
            if via then
                line_ = cs.ping and T("chip_client_via", name, via_label(via), math.floor(cs.ping))
                    or T("chip_client_via_noping", name, via_label(via))
            else
                line_ = cs.ping and T("chip_client", name, math.floor(cs.ping)) or T("chip_client_noping", name)
            end
        elseif st.role == "host" and #(st.remote_pcs or {}) > 0 then
            local names = {}
            local okr, list = pcall(session.roster)
            if okr and type(list) == "table" and #list > 1 then
                for _, e in ipairs(list) do
                    if not e.host then names[#names + 1] = chip_entry(e) end
                end
            else
                for _, r in pairs(st.remote or {}) do names[#names + 1] = tostring(r.name) end
                table.sort(names)
            end
            line_ = T("chip_host", table.concat(names, ", "))
        end
    end
    if line_ ~= UI.chip_shown then
        UI.chip_shown = line_
        if line_ then pcall(function() UI.chip_text:SetText(FText(line_)) end) end
        pcall(function() UI.status_chip:SetVisibility(line_ and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) end)
    end
end

local function drop_refs()
    UI.widget, UI.tree, UI.canvas, UI.panel = nil, nil, nil, nil
    UI.status_chip, UI.chip_text = nil, nil
    UI.toast_box, UI.toast_text, UI.status_title, UI.status_body, UI.status_dot = nil, nil, nil, nil, nil
    UI.toast_dot, UI.toast_hint, UI.bug_section, UI.bug_path_box = nil, nil, nil, nil
    UI.respawn_row, UI.unstuck_row, UI.char_row, UI.looks_off, UI.rescue_title, UI.char_offline = nil, nil, nil, nil, nil, nil
    UI.players_title, UI.player_rows, UI.players_more, UI.players_empty, UI.players_sig = nil, nil, nil, nil, nil
    UI.steam_dot, UI.steam_status, UI.steam_status_row, UI.steam_later, UI.steam_note = nil, nil, nil, nil, nil
    UI.steam_invite, UI.steam_friends_title, UI.friend_rows, UI.steam_more, UI.steam_none = nil, nil, nil, nil, nil
    UI.steam_sig, UI.steam_friends, UI.steam_ready, UI.steam_detail = nil, nil, nil, nil
    UI.disconnect_row, UI.disconnect_shown, UI.char_state = nil, nil, nil
    UI.host_row, UI.host_shown, UI.players_box, UI.steam_to_ip, UI.steam_help = nil, nil, nil, nil, nil
    UI.scroll, UI.tab_ui, UI.lang_buttons = nil, nil, nil
    UI.buttons, UI.active, UI.active_dirty = {}, {}, true
    UI.inputs, UI.checks, UI.check_state = {}, {}, {}
    UI.ltexts, UI.gtexts, UI.sections, UI.pages = {}, {}, {}, {}
    UI.gfont_done, UI.gfont_next, UI.gfont_tries = false, nil, 0
    UI.widget_live = false
    UI.status_shown = nil
end

function UI.build()
    local gi = ue.game_instance()
    if not gi then error("GameInstance not found") end
    drop_refs()
    UI.builds = UI.builds + 1
    CTX.tab, CTX.sec = nil, nil

    step("widget")
    local w = StaticConstructObject(umg_class("UserWidget"), gi)
    if not ue.valid(w) then error("cannot construct UMG.UserWidget") end
    local tree = StaticConstructObject(umg_class("WidgetTree"), w)
    if not ue.valid(tree) then error("cannot construct UMG.WidgetTree") end
    w.WidgetTree = tree
    UI.tree = tree
    local canvas = new("CanvasPanel")
    tree.RootWidget = canvas

    step("toast")
    UI.toast_box = build_toast()
    local ts = canvas:AddChildToCanvas(UI.toast_box)
    pcall(function()
        ts:SetAnchors({ Minimum = { X = 0.5, Y = 0.0 }, Maximum = { X = 0.5, Y = 0.0 } })
        ts:SetAlignment({ X = 0.5, Y = 0.0 })
        ts:SetPosition({ X = 0, Y = 70 })
        ts:SetAutoSize(true)
    end)

    UI.panel = build_panel()
    step("panel slot")
    local ps = canvas:AddChildToCanvas(UI.panel)
    -- a right-side column from 9% to 91% of the screen height: the panel
    -- (centred in it) can never be taller than the screen, at any DPI
    pcall(function() ps:SetAnchors({ Minimum = { X = 1.0, Y = 0.09 }, Maximum = { X = 1.0, Y = 0.91 } }) end)
    pcall(function() ps:SetAlignment({ X = 0.0, Y = 0.0 }) end)
    pcall(function() ps:SetOffsets({ Left = -(PANEL_W + 28), Top = 0, Right = PANEL_W, Bottom = 0 }) end)
    pcall(function() ps:SetAutoSize(false) end)

    pcall(function() canvas:SetVisibility(VIS_SELF_HIT_TEST_INVISIBLE) end)
    pcall(function() UI.toast_box:SetVisibility(VIS_COLLAPSED) end)
    pcall(function() UI.panel:SetVisibility(VIS_COLLAPSED) end)

    step("chip")
    -- connection chip, top right (in game, while connected / hosting)
    UI.status_chip = build_chip()
    local cs = canvas:AddChildToCanvas(UI.status_chip)
    pcall(function()
        cs:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
        cs:SetAlignment({ X = 1.0, Y = 0.0 })
        cs:SetPosition({ X = -16, Y = 12 })
        cs:SetAutoSize(true)
    end)
    pcall(function() UI.status_chip:SetVisibility(VIS_COLLAPSED) end)

    step("viewport")
    w:AddToViewport(900)
    UI.widget, UI.canvas = w, canvas
    UI.widget_live = true
    UI.built_epoch = UI.world_epoch
    UI.chip_shown = nil
    UI.built_pc = ue.name(ue.local_pc())
    UI.shown = nil
    UI.toasts_dirty = true
    UI.lang_built = i18n.language()
    log.info("ui: menu built (%d buttons, %d texts, language %s)", #UI.buttons, #UI.ltexts, UI.lang_built)
end

-- Level change (sdc_session.reset_world). The engine takes the widget off
-- screen with the old world, and the load's garbage collection frees the
-- whole tree, so every reference is dropped; UI.ensure builds a new one.
--   why == "loadmap": called before the old world is torn down, everything
--     is still alive, so the widget is taken off screen here (if the load
--     stopped early, an unreachable menu would stay on screen otherwise).
--   otherwise (a new controller seen by the 1 s tick): nothing is touched,
--     and a menu already rebuilt for the new controller is kept.
--   A new controller in the SAME world (no LoadMap since the widget was
--   built: a client getting its replicated controller after the travel)
--   leaves the old widget alive, so it is taken off screen too - otherwise
--   it stayed there orphaned, with its last toast frozen on screen.
UI.world_epoch, UI.built_epoch = 0, nil
function UI.forget_world(why, pc_key)
    if why ~= "loadmap" and UI.built_pc ~= nil and UI.built_pc == pc_key then return end
    local same_world = why ~= "loadmap" and UI.built_epoch == UI.world_epoch
    if (why == "loadmap" or same_world) and ue.valid(UI.widget) then
        pcall(function() UI.widget:RemoveFromParent() end)
    end
    if why == "loadmap" then UI.world_epoch = UI.world_epoch + 1 end
    drop_refs()
    UI.built_pc = nil
    UI.shown = nil
    UI.toasts_dirty = true
    UI.last_map = nil
end
session.world_reset_hooks.ui = function(why, pc_key) UI.forget_world(why, pc_key) end

-- Crash guard: a marker file exists only while the widget is being built.
-- If the game dies inside the build, the next start finds the marker and
-- keeps the menu off instead of crashing again (console commands still work).
UI.marker_path = nil
UI.mod_dir = nil
UI.disabled = false

function UI.check_crash_marker(dir)
    UI.mod_dir = dir
    UI.marker_path = dir .. "/ui_build.marker"
    local f = io.open(UI.marker_path, "r")
    if f then
        f:close()
        os.remove(UI.marker_path)
        UI.disabled = true
        log.err("ui: previous start crashed while building the menu; menu disabled for this session. "
            .. "Console still works: sdcoop_help")
    end
end

local function marker(on)
    if not UI.marker_path then return end
    if on then
        local f = io.open(UI.marker_path, "w")
        if f then f:write("building\n"); f:close() end
    else
        os.remove(UI.marker_path)
    end
end

-- Keeps the widget alive and on screen across level changes.
function UI.ensure()
    if UI.disabled or UI.build_failures >= 3 then return end
    if not ue.local_pc() then return end
    if ue.valid(UI.widget) then
        local ok, inv = pcall(function() return UI.widget:IsInViewport() end)
        if ok and inv then return end
        if pcall(function() UI.widget:AddToViewport(900) end) then
            UI.shown = nil
            UI.toasts_dirty = true
            log.debug("ui: re-added to viewport")
            return
        end
    end
    marker(true)
    local ok, err = pcall(UI.build)
    if ok then
        -- Slate paints the new widget on the next frames; keep the marker a
        -- little longer so a paint-time crash is caught as well.
        ue.delay("ui-marker", 6000, function() marker(false) end)
    else
        marker(false)
    end
    if not ok then
        UI.build_failures = UI.build_failures + 1
        UI.widget = nil
        UI.widget_live = false
        log.err("ui: build failed (%d/3): %s", UI.build_failures, tostring(err))
        if UI.build_failures >= 3 then
            log.err("ui: menu disabled; use console commands sdcoop_join / sdcoop_host / sdcoop_status")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

local function set_game_input(menu_open)
    if ue.in_main_menu() then return end
    -- the pause menu owns input (UI only, focus on it for its Esc handling)
    if UI.pause_menu_shown and UI.pause_menu_shown() then return end
    local pc, wbl = ue.local_pc(), ue.widget_lib()
    if not pc or not wbl then return end
    if menu_open then
        pcall(function() wbl:SetInputMode_GameAndUIEx(pc, nil, 0, false, false) end)
        pcall(function() pc.bShowMouseCursor = true end)
        UI.input_mode_changed = true
    elseif UI.input_mode_changed then
        -- a game window (inventory, trade, container) under the panel keeps its UI input
        local okw, open = pcall(function() return require("sdc_widgets").game_window_open() end)
        if okw and open then
            log.info("ui: menu closed over %s: its UI input stays (game controls not forced)", tostring(open))
        else
            pcall(function() wbl:SetInputMode_GameOnly(pc, false) end)
            pcall(function() pc.bShowMouseCursor = false end)
        end
        UI.input_mode_changed = false
    end
end

function UI.apply_visibility()
    if not ue.valid(UI.panel) then return end
    if UI.shown == UI.open then return end
    UI.shown = UI.open
    -- the column itself is click-through; the panel inside blocks clicks
    pcall(function() UI.panel:SetVisibility(UI.open and VIS_SELF_HIT_TEST_INVISIBLE or VIS_COLLAPSED) end)
end

function UI.set_open(open)
    if open == UI.open then return end
    UI.open = open
    log.info("ui: menu %s", open and "opened" or "closed")
    if open then
        pcall(i18n.detect)
        if ue.valid(UI.widget) and UI.lang_built ~= i18n.language() then UI.relabel() end
        fill_widgets()
        if not UI.dead and UI.pages.steam then
            local okt, tab = pcall(UI.default_tab)
            if okt and tab and tab ~= UI.tab then UI.select_tab(tab) end
        end
    end
    for _, b in ipairs(UI.buttons) do b.was = false end
    UI.apply_visibility()
    set_game_input(open)
    if open then
        UI.refresh_status()
        pcall(UI.apply_game_font)
    end
end

function UI.toggle()
    UI.set_open(not UI.open)
end

-- Client death: show the respawn button and open the menu (with cursor) on
-- the character tab.
function UI.set_dead(dead)
    UI.dead = dead
    UI.char_state = nil
    if dead and UI.pages.char then UI.select_tab("char") end
    UI.set_open(dead)
    UI.refresh_status()
end
session.ui_hooks.dead = function(dead) UI.set_dead(dead) end

-- Menu hotkey. Note: UE4SS treats every "UnrealWindow" as focused, so with
-- two copies of the game on one PC the key toggles the menu in both. That is
-- harmless (the menu only shows/hides); every action needs a mouse click
-- inside the specific window.
function UI.on_menu_key()
    if UI.disabled or not ue.valid(UI.widget) then
        log.warn("ui: menu key pressed but the menu is not available (disabled=%s)", tostring(UI.disabled))
        return
    end
    UI.toggle()
end

-- ---------------------------------------------------------------------------
-- Status, toasts, polling
-- ---------------------------------------------------------------------------

-- { color, title, body } for the status line.
function UI.status_model()
    local st = session.state or {}
    local role = st.role
    local in_menu = ue.in_main_menu()
    local m = { color = C.dim, title = "", body = "" }
    if role == "host" then
        m.color = C.ok
        m.title = T("st_host", #(st.remote_pcs or {}))
        -- who is there: the «Игроки» section; here only what to do next
        if in_menu then
            m.body = T("st_host_menu_hint")
        elseif #(st.remote_pcs or {}) == 0 then
            m.body = T(UI.steam_ready and "st_host_wait_steam" or "st_host_wait")
        end
    elseif role == "client" then
        local cs = st.client or {}
        m.color = C.ok
        m.title = cs.host_name and T("st_client", cs.host_name) or T("st_client_noname")
        local parts = {}
        if cs.ping then parts[#parts + 1] = T("st_ping", math.floor(cs.ping)) end
        if cs.host_version and cs.host_version ~= session.VERSION then
            m.color = C.warn
            parts[#parts + 1] = T("st_version", tostring(cs.host_version), tostring(session.VERSION))
        end
        m.body = table.concat(parts, " ")
    elseif ue.has_pending_connection() then
        m.color = C.warn
        m.pending = true
        m.title = T("st_connecting", tostring((st.join and st.join.target) or cfg.get("host_ip")))
    elseif role == "standalone" then
        if in_menu then
            if cfg.get("auto_join") == true then
                m.color = C.warn
                m.title = T("st_autojoin", tostring(cfg.get("host_ip")), tonumber(cfg.get("port")) or 7777,
                    (st.join and st.join.attempts) or 0)
            elseif cfg.get("listen_on_load") == true and not st.listen_warned then
                m.color = C.warn
                m.title = T("st_opening")
                m.body = T("st_opening_hint")
            else
                m.title = T("st_closed")
                m.body = T("st_closed_hint")
            end
        else
            m.title = T("st_single")
            m.body = T("st_single_hint")
        end
    else
        m.title = T("st_loading")
    end
    return m
end

-- Rows that depend on the session: players, Steam, disconnect, appearance,
-- rescue.
local function refresh_rows(m)
    local st = session.state or {}
    local role = st.role
    local in_menu = ue.in_main_menu()
    local okp, errp = pcall(refresh_players, m)
    if not okp then log.err_throttled("ui-players", "ui: players: %s", tostring(errp)) end
    local oks, errs = pcall(refresh_steam)
    if not oks then log.err_throttled("ui-steam", "ui: steam: %s", tostring(errs)) end
    local disc = role == "client" or m.pending == true
    if disc ~= UI.disconnect_shown then
        UI.disconnect_shown = disc
        show(UI.disconnect_row, disc)
    end
    local can_host = role == "standalone" and in_menu and not m.pending and m.color ~= C.warn
    if can_host ~= UI.host_shown then
        UI.host_shown = can_host
        show(UI.host_row, can_host)
    end
    local looks = in_menu and role ~= "client"
    local pawn = role == "client" and ue.local_pawn() or nil
    local unstuck = pawn ~= nil and ue.prop(pawn, "PlayerDead?") ~= true
    local dead = UI.dead == true
    local key = tostring(looks) .. tostring(unstuck) .. tostring(dead)
    if key ~= UI.char_state then
        UI.char_state = key
        show(UI.char_row, looks)
        show(UI.looks_off, not looks)
        show(UI.respawn_row, dead)
        show(UI.unstuck_row, unstuck)
        show(UI.rescue_title, dead or unstuck)
        show(UI.char_offline, not (dead or unstuck))
    end
end

function UI.refresh_status()
    if not ue.valid(UI.status_title) then return end
    local m = UI.status_model()
    local okr, err = pcall(refresh_rows, m)
    if not okr then log.err_throttled("ui-rows", "ui: rows: %s", tostring(err)) end
    local sig = m.title .. "\1" .. m.body
    if sig ~= UI.status_shown then
        UI.status_shown = sig
        pcall(function() UI.status_title:SetText(FText(m.title)) end)
        pcall(function() UI.status_body:SetText(FText(m.body)) end)
        show(UI.status_body, m.body ~= "", VIS_HIT_TEST_INVISIBLE)
    end
    if m.color ~= UI.dot_color then
        UI.dot_color = m.color
        if ue.valid(UI.status_dot) then pcall(function() UI.status_dot:SetBrushColor(m.color) end) end
    end
end

-- Called from anywhere; rendering happens on the UI tick. `class` "mod":
-- the mod's own message (sdc_log.mod_sink); nil: a gameplay message shown
-- here because the game's HUD is not there (main menu, panel open).
function UI.toast(msg, kind, seconds, class)
    UI.toasts[#UI.toasts + 1] = { text = msg, kind = kind or "info", class = class,
                                  expires = os.time() + (seconds or 6) }
    while #UI.toasts > 4 do table.remove(UI.toasts, 1) end
    UI.toasts_dirty = true
end

-- sdc_log: "mod" notifications (connection, versions, saves, the mod's
-- warnings and errors) come here instead of the game's notification
-- widget. Without a usable menu they go the game's way after all.
log.mod_sink = function(text, kind, seconds)
    if UI.disabled or UI.build_failures >= 3 then
        if log.toast_sink then log.toast_sink(text, kind, seconds) end
        return
    end
    if kind == "err" or kind == "warn" then seconds = math.max(seconds or 6, 8) end
    UI.toast(text, kind, seconds, "mod")
end

local function render_toasts()
    local now = os.time()
    local live = {}
    for _, t in ipairs(UI.toasts) do
        if t.expires > now then live[#live + 1] = t end
    end
    if #live ~= #UI.toasts then UI.toasts, UI.toasts_dirty = live, true end
    if not UI.toasts_dirty or not ue.valid(UI.toast_box) then return end
    UI.toasts_dirty = false
    if #live == 0 then
        pcall(function() UI.toast_box:SetVisibility(VIS_COLLAPSED) end)
        return
    end
    local lines, mod_error = {}, false
    for _, t in ipairs(live) do
        lines[#lines + 1] = t.text
        if t.class == "mod" and t.kind == "err" then mod_error = true end
    end
    if ue.valid(UI.toast_text) then
        pcall(function() UI.toast_text:SetText(FText(table.concat(lines, "\n"))) end)
    end
    if ue.valid(UI.toast_dot) then
        local c = live[#live].kind == "info" and C.bone or TOAST_COLOR[live[#live].kind] or C.bone
        pcall(function() UI.toast_dot:SetBrushColor(c) end)
    end
    if ue.valid(UI.toast_hint) then
        if mod_error then
            local key = tostring(cfg.get("menu_key") or "F7")
            pcall(function() UI.toast_hint:SetText(FText(T("toast_err_hint", key))) end)
        end
        pcall(function() UI.toast_hint:SetVisibility(mod_error and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) end)
    end
    pcall(function() UI.toast_box:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
end

-- ---------------------------------------------------------------------------
-- Test mode (config ui_open_at_menu): the panel opens by itself in the main
-- menu, and Mods/SDCoop/ui_test.txt (key=value lines, re-read when changed)
-- drives it for screenshots: tab=steam|ip|char|settings, lang=auto|ru|en,
-- expand=<section>[,<section>...] / collapse=... (main, all, help, groups,
-- group <id>), scroll=start|end|<px>, open=1|0,
-- steammock=<steamlink state>|none, roster=host|client|off,
-- bug=open|form|logs[-dry], say=<catalog key>,<kind>, toast=<text>.
-- ---------------------------------------------------------------------------

local function sections_named(name)
    local out = {}
    for _, sec in ipairs(UI.sections) do
        if sec.name == name or (name == "groups" and sec.name:find("^group ")) or name == "*" then
            out[#out + 1] = sec
        end
    end
    return out
end

local function apply_test(k, v)
    log.info("ui: test: %s=%s", k, log.ascii(v))
    if k == "open" then
        UI.set_open(v == "1")
    elseif k == "tab" then
        UI.select_tab(v)
    elseif k == "lang" then
        i18n.set(v)
        update_lang_buttons()
    elseif k == "expand" or k == "collapse" then
        for name in v:gmatch("[^,]+") do
            for _, sec in ipairs(sections_named(name)) do UI.toggle_section(sec, k == "expand") end
        end
    elseif k == "scroll" and ue.valid(UI.scroll) then
        if v == "start" then
            pcall(function() UI.scroll:ScrollToStart() end)
        elseif v == "end" then
            pcall(function() UI.scroll:ScrollToEnd() end)
        elseif tonumber(v) then
            pcall(function() UI.scroll:SetScrollOffset(tonumber(v)) end)
        end
    elseif k == "steammock" then
        -- a stand-in sdc_steamlink in a given state (none = no module)
        if v == "none" then
            package.loaded["sdc_steamlink"] = nil
        else
            local friends = {
                { id = "1", name = "Alice", joinable = true, status = "мир открыт, 0.7.0", version = "0.7.0" },
                { id = "3", name = "Very-Long-Steam-Nickname-Of-A-Friend", joinable = true, status = "другая версия" },
                { id = "2", name = "Борис", joinable = false, status = nil },
            }
            package.loaded["sdc_steamlink"] = {
                status = function()
                    local en = i18n.language() == "en"
                    local detail = (en and { error = "The Steam helper is missing (antivirus?)", no_steam = "Steam isn't running.",
                                             hosting = "Connected through Steam: 1", joining = "Waiting for the host to load the world…" }
                                    or { error = "Steam-помощник не найден (антивирус?)", no_steam = "Steam не запущен.",
                                         hosting = "Подключено через Steam: 1", joining = "Жду, пока хост загрузит мир…" })[v]
                    return { state = v, detail = detail, friends_only = true, helper = true, peers = 1 }
                end,
                friends = function() return friends end,
                join = function(id) log.info("ui: test: steam mock join %s", tostring(id)) return true end,
                invite = function() log.info("ui: test: steam mock invite") return true end,
            }
        end
        UI.steam_missing_at = nil
        UI.refresh_status()
    elseif k == "roster" then
        -- a stand-in player list: host | client | off
        if v == "host" or v == "client" then
            UI.test_role = v
            UI.test_roster = {
                { name = v == "host" and cfg.player_name() or "Alice", state = "host", host = true, me = v == "host" },
                { name = "Борис", state = "game", ping = 48, me = false },
                { name = v == "client" and cfg.player_name() or "Vasya", state = v == "client" and "game" or "loading",
                  ping = 112, me = v == "client" },
                { name = "Gleb", state = "connecting", me = false },
            }
        else
            UI.test_role, UI.test_roster = nil, nil
        end
        UI.refresh_status()
    elseif k == "bug" then
        -- open: the section; form / logs: the buttons; "-dry": only logged
        local what, dry = v:match("^(%a+)(%-?%a*)$")
        UI.test_dry_run = dry == "-dry"
        if what == "open" then UI.open_bug()
        elseif what == "form" then UI.on_bug_form()
        elseif what == "logs" then UI.on_bug_logs() end
        UI.test_dry_run = false
    elseif k == "say" then
        -- a catalog notification: say=<key>,<kind>
        local key, kind = v:match("^([%w_]+),?(%a*)$")
        if key then log.say(key, kind ~= "" and kind or "info", 12, "Bob", "0.6.1", "0.6.2") end
    elseif k == "toast" then
        log.toast(v, "info", 12, "ui test toast")
    end
end

local function test_tick()
    if cfg.get("ui_open_at_menu") ~= true or not ue.valid(UI.widget) then return end
    if not UI.test_opened and ue.in_main_menu() then
        UI.test_opened = true
        UI.set_open(true)
        log.info("ui: test: panel opened in the main menu (ui_open_at_menu)")
    end
    local path = UI.mod_dir and (UI.mod_dir .. "/ui_test.txt") or nil
    local f = path and io.open(path, "r") or nil
    if not f then return end
    local s = f:read("a") or ""
    f:close()
    if s == UI.test_seen then return end
    UI.test_seen = s
    for row in s:gmatch("[^\r\n]+") do
        local k, v = row:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then
            local ok, err = pcall(apply_test, k, v)
            if not ok then log.err("ui: test: %s: %s", k, tostring(err)) end
        end
    end
end

-- 4 Hz: keep alive, follow level changes, refresh texts.
function UI.slow_tick()
    pcall(i18n.detect)
    UI.ensure()
    if not ue.valid(UI.widget) then return end
    -- Menu and game share one world here, so follow "main menu vs in game"
    -- (and world reloads), not just the level name.
    local map = ue.map_name()
    if map then
        local in_menu = ue.in_main_menu()
        local state = map .. "|" .. tostring(in_menu) .. "|" .. ue.name(ue.local_pc())
        if state ~= UI.last_map then
            UI.last_map = state
            UI.test_opened = false
            if in_menu then
                UI.input_mode_changed = false
                UI.set_open(cfg.get("menu_in_main_menu") == true and not UI.lobby_active)
            else
                UI.set_open(false)
            end
        end
    end
    UI.apply_visibility()
    render_toasts()
    UI.status_ticks = (UI.status_ticks or 0) + 1
    if UI.open then
        if UI.status_ticks % 4 == 0 then UI.refresh_status() end
        if UI.tab == "settings" then pcall(sync_checks) end
        if not UI.gfont_done and (UI.gfont_tries or 0) < 12 then pcall(UI.apply_game_font) end
    end
    if UI.status_ticks % 4 == 0 then
        pcall(UI.update_chip)
        local ok, err = pcall(test_tick)
        if not ok then log.err_throttled("ui-test", "ui: test tick: %s", tostring(err)) end
    end
end

local function m_hovered(w) return w:IsHovered() end
local function m_pressed(w) return w:IsPressed() end

-- Every frame while open: hover colours and clicks of the shown buttons.
function UI.frame_tick()
    if not UI.open or not ue.valid(UI.panel) then return end
    if UI.active_dirty then refresh_active() end
    local all, list = UI.buttons, UI.active
    for _, b in ipairs(list) do
        if ue.valid(b.w) then
            local okh0, hov = pcall(m_hovered, b.w)
            hov = okh0 and hov == true
            if hov ~= b.hovered then
                b.hovered = hov
                pcall(function() b.bg:SetBrushColor(hov and b.colors.hover or b.colors.base) end)
            end
            local ok, pressed = pcall(m_pressed, b.w)
            pressed = ok and pressed == true
            if b.was and not pressed and hov then
                log.debug("ui: click '%s'", b.label)
                local okc, err = pcall(b.fn)
                if not okc then log.err("ui: button '%s': %s", b.label, tostring(err)) end
                -- the handler rebuilt or dropped the menu: its old buttons are stale
                if UI.buttons ~= all then return end
            end
            b.was = pressed
        end
    end
end

return UI
