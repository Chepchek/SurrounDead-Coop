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
--           tabs:   Steam / По IP / Персонаж / Мир / Настройки (amber bar = active)
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
-- inside open sections, and not collapsed (show(w, false) on the button or
-- on a row it is gated by), are polled.

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
    -- widgets collapsed by show(w, false) (weak keys: the wrappers this
    -- module holds); a button gated by one of them is not polled
    off = setmetatable({}, { __mode = "k" }),
}

local VIS_VISIBLE, VIS_COLLAPSED, VIS_HIDDEN, VIS_HIT_TEST_INVISIBLE, VIS_SELF_HIT_TEST_INVISIBLE = 0, 1, 2, 3, 4
local HALIGN_FILL = 0
local VALIGN_FILL, VALIGN_TOP, VALIGN_CENTER = 0, 1, 2
local SIZE_FILL = 1
local JUSTIFY_CENTER = 1

local PANEL_W = 480        -- Slate units (DPI-scaled like the game's own UI): five tabs fit
local PAD = 18             -- panel side padding
local TABS = { "steam", "ip", "char", "world", "settings" }
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
    cover       = srgb("0A0F11"),         -- the join cover (opaque: nothing of the world shows through)
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

-- Remembers that `w` is collapsed (off = true) or shown: the buttons it
-- gates leave / join the polled list.
local function mark_off(w, off)
    if w == nil then return end
    off = off and true or nil
    if UI.off[w] ~= off then
        UI.off[w] = off
        UI.active_dirty = true
    end
end

local function show(w, on, vis)
    if ue.valid(w) then
        pcall(function() w:SetVisibility(on and (vis or VIS_SELF_HIT_TEST_INVISIBLE) or VIS_COLLAPSED) end)
    end
    mark_off(w, not on)
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
                  hovered = false, tab = CTX.tab, sec = CTX.sec, gates = { bg } }
    UI.buttons[#UI.buttons + 1] = rec
    UI.active_dirty = true
    return bg, rec
end

-- More widgets whose collapse hides button record `rec` (a row it is in).
local function gate(rec, ...)
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if w ~= nil then rec.gates[#rec.gates + 1] = w end
    end
    UI.active_dirty = true
end

-- A full-width button with a label that wraps instead of overflowing.
-- kind: "primary" (amber) | nil (secondary). Returns the border, the polled
-- record and the label.
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
    return bg, rec, t
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
    return clickable(sb, COL.secondary, handler, type(key) == "string" and key or "button")
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
    local bad = {}
    for key, e in pairs(UI.inputs) do
        if ue.valid(e) then
            local ok, v = pcall(function() return e:GetText() end)
            if ok then
                local s = ue.str(v)
                if cfg.set(key, s) == false then bad[#bad + 1] = i18n.label(key) end
                -- a number box shows the number kept ("30 %" -> 30; no number in it: the value it had)
                local now = tostring(cfg.get(key))
                if cfg.kind and cfg.kind(key) == "int" and s ~= now then pcall(function() e:SetText(FText(now)) end) end
            end
        end
    end
    if #bad > 0 then
        table.sort(bad)
        log.say("settings_num_bad", "warn", 8, table.concat(bad, ", "))
    end
    for key, list in pairs(UI.checks) do
        local v = check_value(list)
        if v ~= nil then cfg.set(key, v) end
    end
end

-- The IP tab's password field: the password kept for the address in the
-- settings (sdc_admin.saved_pw). Not in UI.inputs: its own rules (keep_ip_pw
-- on every save of the settings, JC.enter), so a field left as shown is
-- never kept for another address.
local function fill_ip_pw()
    local a = package.loaded["sdc_admin"]
    if not ue.valid(UI.ip_pw) or type(a) ~= "table" or type(a.saved_pw) ~= "function" then return end
    local ok, v = pcall(function() return a.saved_pw(a.pw_target(cfg.get("host_ip"), cfg.get("port"))) end)
    v = ok and type(v) == "string" and v or ""
    UI.ip_pw_shown = v
    pcall(function() UI.ip_pw:SetText(FText(v)) end)
end
UI.fill_ip_pw = fill_ip_pw

-- Every save of the settings (the footer's Save, Join, Host; after
-- read_widgets: the address is the one typed now): an edit of the IP tab's
-- password field is kept for that address; one left as shown is not (it was
-- shown for the address before), the password kept for this address shows.
local function keep_ip_pw()
    local a = package.loaded["sdc_admin"]
    if not ue.valid(UI.ip_pw) or type(a) ~= "table" or type(a.save_pw) ~= "function" then return end
    local ok, typed = pcall(function() return a.norm_pw(ue.str(UI.ip_pw:GetText())) end)
    if ok and typed ~= (UI.ip_pw_shown or "") then
        local oks, err = pcall(a.save_pw, a.pw_target(cfg.get("host_ip"), cfg.get("port")), typed)
        if not oks then log.err("ui: the IP tab's password not kept: %s", tostring(err)) end
    end
    fill_ip_pw()
end

-- The World tab's join password field (the host): the saved one.
local function fill_world_pw()
    if not ue.valid(UI.world_pw) then return end
    local a = package.loaded["sdc_admin"]
    local v = type(a) == "table" and type(a.join_password) == "function" and a.join_password()
        or tostring(cfg.get("join_password") or "")
    pcall(function() UI.world_pw:SetText(FText(v)) end)
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
    pcall(fill_ip_pw)
    pcall(fill_world_pw)
end

-- A setting shown more than once («Основное», its group, the World tab): a
-- click on one copy sets the others (4 Hz, settings and World tabs, and
-- before a save). The World tab's copy (UI.world_checks) applies at once, as
-- the rest of that tab (UI.on_world_check), also when it is the setting's
-- only copy (its «Все функции» group is built when opened).
local function sync_checks()
    local world = UI.world_checks or {}
    for key, list in pairs(UI.checks) do
        local wcb = world[key]
        if #list > 1 or wcb ~= nil then
            local last = UI.check_state[key]
            local new_v, from = nil, nil
            for _, cb in ipairs(list) do
                if ue.valid(cb) then
                    local ok, v = pcall(function() return cb:IsChecked() end)
                    if ok and (v == true) ~= last then new_v, from = v == true, cb break end
                end
            end
            if new_v ~= nil then
                UI.check_state[key] = new_v
                for _, cb in ipairs(list) do
                    if ue.valid(cb) then pcall(function() cb:SetIsChecked(new_v) end) end
                end
                if from ~= nil and from == wcb then UI.on_world_check(key, new_v) end
            end
        end
    end
end

local function save_settings(quiet, no_reopen)
    local was_open = cfg.get("listen_on_load") == true
    pcall(sync_checks)   -- a copy clicked within the last 250 ms
    read_widgets()
    pcall(keep_ip_pw)    -- not in UI.inputs: the IP tab's password, its own rules
    local ok = cfg.save()
    if not quiet then log.say(ok and "settings_saved" or "settings_failed", ok and "ok" or "err") end
    -- "open my worlds to friends" switched on while playing a single-player
    -- world: open this one now (save, reload it open - sdc_session)
    if not no_reopen and not was_open and cfg.get("listen_on_load") == true and cfg.get("auto_join") ~= true
        and (session.state or {}).role == "standalone" and not ue.in_main_menu()
        and type(session.open_world_now) == "function" then
        if session.open_world_now() then UI.set_open(false) end
    end
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

local function gated_off(b)
    for _, w in ipairs(b.gates or {}) do
        if UI.off[w] then return true end
    end
    return false
end

local function refresh_active()
    local list = {}
    for _, b in ipairs(UI.buttons) do
        if (b.tab == nil or b.tab == UI.tab) and sec_open(b.sec) and not gated_off(b) then
            list[#list + 1] = b
        else
            -- a press that began before it was hidden is not a click later
            b.was = false
        end
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
    -- a box clicked within the last 250 ms (the 4 Hz sync runs only on these
    -- two tabs): a World-tab click is applied before its tab goes
    if (UI.tab == "settings" or UI.tab == "world") and id ~= UI.tab then pcall(sync_checks) end
    UI.tab = id
    for tid, page in pairs(UI.pages) do show(page, tid == id) end
    for tid, tu in pairs(UI.tab_ui or {}) do
        set_color(tu.text, tid == id and C.bone or C.dim)
        pcall(function() tu.bar:SetBrushColor(tid == id and C.amber or C.clear) end)
    end
    if ue.valid(UI.scroll) then pcall(function() UI.scroll:ScrollToStart() end) end
    UI.active_dirty = true
    if id == "char" then pcall(UI.refresh_char) end
    if id == "world" then
        UI.world_sig = nil
        pcall(UI.refresh_world)
    end
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
    UI.hud_sig = nil
    UI.status_shown = nil
    UI.char_sig = nil
    pcall(UI.refresh_char)
    UI.world_sig = nil
    pcall(UI.refresh_world)
    if UI.open then UI.refresh_status() end
    log.info("ui: language %s: %d texts relabelled", UI.lang_built, n)
end

local function set_language(v)
    i18n.set(v)                 -- listeners relabel the panel
    update_lang_buttons()
    -- the co-op buttons in the game's menus too (their language can change
    -- when the panel's does not: "auto" follows the game's language there)
    local lb = package.loaded["sdc_lobby"]
    if type(lb) == "table" and type(lb.relabel) == "function" then pcall(lb.relabel) end
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

-- A number setting (i18n.NUMS_OF, under its switch): its label and a box
-- bound to the key (UI.inputs: filled on opening, kept with the footer's Save).
local function num_row(key)
    local hb = new("HorizontalBox")
    local lf = function() return i18n.label(key) end
    local df = function() return i18n.desc(key) end
    local t = text(lf(), 13, C.dim)
    bind(t, lf)
    local e = input(key)
    for _, w in ipairs({ t, e }) do
        pcall(function() w:SetToolTipText(FText(df())) end)
        bind(w, df, "tip")
    end
    hadd(hb, t, true)
    hadd(hb, sized(e, 96), false, 8, VALIGN_FILL)
    return hb
end

local function on_join()
    -- the password field too (keep_ip_pw): an edit is kept for the address
    -- joined now; one left as shown is not, the one kept for it goes instead
    save_settings(true)
    session.join(cfg.get("host_ip"), cfg.get("port"), false)
end

-- The real main menu on screen. ue.in_main_menu() means "the menu map and
-- no own character", which is also true while the player is dead in a
-- world; the live MenuWidget (sdc_lobby.live_main_menu, loaded by main.lua)
-- tells them apart. Cached for 0.25 s. Without sdc_lobby (tests):
-- ue.in_main_menu() alone.
function UI.real_menu()
    if not ue.in_main_menu() then return false end
    local lobby = package.loaded["sdc_lobby"]
    if type(lobby) ~= "table" or type(lobby.live_main_menu) ~= "function" then return true end
    local now = os.clock()
    if UI.menu_at and now >= UI.menu_at and now - UI.menu_at < 0.25 then return UI.menu_v end
    local ok, w = pcall(lobby.live_main_menu)
    UI.menu_at, UI.menu_v = now, ok and w ~= nil
    return UI.menu_v
end

local function on_host()
    save_settings(true, true)
    local in_world = not UI.real_menu()
    session.host_on_next_load()
    fill_widgets()
    -- a single-player world reloads open: let the player see it
    if in_world and type(session.reopen_state) == "function" and session.reopen_state() then UI.set_open(false) end
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
-- The dot (the panel's list and the players table): green = playing,
-- yellow = not playing for now (joining, loading, its pause menu open),
-- orange = nothing heard from it for seconds, red = dead.
local STATE_COLOR = { host = C.ok, game = C.ok, loading = C.warn, connecting = C.warn, menu = C.warn,
                      lag = C.amber, dead = C.err }
-- A name in the panel's list: its line holds only the dot, the state and
-- the ping (the host's Kick / Ban / «Ещё» are on a line of their own), so a
-- name is cut ("…", its tooltip says it whole) only past this many
-- characters; the own row: this many + " (вы)". A shorter name of wide
-- letters (W, M, Ш, capitals) next to a long state ("подключается", "not
-- responding") can still be wider than its room: the engine ends it with
-- "…" then (build_players), and a name from NAME_TIP_FROM characters on has
-- the tooltip too, cut or not.
local NAME_MAX, NAME_MAX_YOU = 24, 22
local NAME_TIP_FROM = 17
local BAN_CONFIRM_S = 5
-- A press this soon after the row under it moved or got another entry is no
-- click: it was aimed at what was there before (a double-click, a quick
-- second click). The player list and the World tab's lists.
local ROW_SETTLE_S = 0.6

-- Did something change at `at` (os.clock) since just before button `rec`
-- was pressed? Then the click was meant for what was there before.
local function moved_since(at, rec)
    return at ~= nil and at > ((rec and rec.pressed_at) or os.clock()) - ROW_SETTLE_S
end

-- The same for `t` (a row, a list): its changed_at.
local function moved_under(t, rec)
    return moved_since(t and t.changed_at, rec)
end

local function admin()
    local a = package.loaded["sdc_admin"]
    return type(a) == "table" and a or nil
end

-- A small row button whose label can change (Ban -> Sure?).
local function row_button(key, tip_key, handler, label)
    local t = ltext(key, 12, C.bone, { bold = true, justify = JUSTIFY_CENTER })
    local sb = new("SizeBox")
    pcall(function() sb:SetMinDesiredHeight(22) end)
    pcall(function() sb:SetMinDesiredWidth(52) end)
    local ss = sb:SetContent(t)
    pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() ss:SetPadding(margin(6, 0, 6, 0)) end)
    local bg, rec = clickable(sb, COL.secondary, handler, label)
    local tip = lfn(tip_key)
    pcall(function() rec.w:SetToolTipText(FText(tip())) end)
    bind(rec.w, tip, "tip")
    return bg, t, rec
end

-- The «Ещё ›» button at the end of a player's row (host): it opens a strip
-- under the row with the rarer actions, so they never sit next to Kick /
-- Ban. The arrow is the sections' chevron (the engine font has no ▾),
-- turned down while the strip is open. Returns the border, the polled
-- record and the arrow.
local COL_OPEN = { base = C.btn_hover, hover = C.btn_hover }
local function more_button(handler)
    local hb = new("HorizontalBox")
    hadd(hb, ltext("btn_more", 12, C.bone, { bold = true }), false)
    local arrow = text(CHEVRON, 14, C.dim, { bold = true, justify = JUSTIFY_CENTER })
    pcall(function() arrow:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    hadd(hb, sized(arrow, 10, nil), false, 3)
    local sb = new("SizeBox")
    pcall(function() sb:SetMinDesiredHeight(22) end)
    pcall(function() sb:SetMinDesiredWidth(52) end)
    local ss = sb:SetContent(hb)
    pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
    pcall(function() ss:SetHorizontalAlignment(2) end)   -- HAlign_Center
    pcall(function() ss:SetPadding(margin(6, 0, 4, 0)) end)
    local bg, rec = clickable(sb, COL.secondary, handler, "more")
    local tip = lfn("more_tip")
    pcall(function() rec.w:SetToolTipText(FText(tip())) end)
    bind(rec.w, tip, "tip")
    return bg, rec, arrow
end

-- Host: «Притянуть к себе» (sdc_players.pull_to_host; it tells the host
-- the result or why not). A second click on the same player within
-- PULL_REPEAT_S of a pull really sent does nothing (the answer takes a few
-- seconds); after a refusal (it said why) the host may try again at once.
-- `name`: the row's name (said if the player has left meanwhile).
local PULL_REPEAT_S = 3
local function pull_player(key, name)
    local now = os.clock()
    local last = UI.pull_last
    if last and last.key == key and now - last.at < PULL_REPEAT_S then
        log.info("ui: players: pull %s again within %d s: ignored", tostring(key), PULL_REPEAT_S)
        return
    end
    local pl = package.loaded["sdc_players"]
    if type(pl) ~= "table" or type(pl.pull_to_host) ~= "function" then
        log.warn("ui: players: no sdc_players.pull_to_host")
        return
    end
    local ok, sent = pcall(pl.pull_to_host, key, name)
    if not ok then
        log.err("ui: players: pull: %s", tostring(sent))
    elseif sent == true then
        UI.pull_last = { key = key, at = now }
    end
end

-- The strip's actions, in order: id, label / tooltip keys, avail(roster
-- entry) = shown in that player's strip, run(session key, the row's full
-- name). Another action
-- (e.g. add to / remove from the allowed list) is one more entry here: each
-- row's strip gets a button for it, and the row's «Ещё» shows while any of
-- them is available.
local EXTRA_ACTIONS = {
    { id = "pull", key = "btn_pull", tip = "pull_tip",
      -- in the world with a character (not connecting, loading, dead, not
      -- responding); "menu" = its pause menu is open, the character is there
      avail = function(e) local s = e.state or "game"; return s == "game" or s == "menu" end,
      run = pull_player },
}
UI.EXTRA_ACTIONS = EXTRA_ACTIONS

-- A player the host has kicked already (in the roster until the connection
-- closes): sdc_admin.is_kicked when it has one, else the session record's
-- `kicked` stamp that sdc_admin.kick sets.
local function kicked(key)
    local a = admin()
    if a and type(a.is_kicked) == "function" then
        local ok, v = pcall(a.is_kicked, key)
        if ok then return v ~= nil and v ~= false end
    end
    local r = ((session.state or {}).remote or {})[key]
    return type(r) == "table" and r.kicked ~= nil
end

-- Was row `i` where it is now, with the same player, when button `rec` was
-- pressed? A strip opening / closing above it moves the row, a player
-- leaving puts the next one in it, its Kick / Ban appear (refresh_players
-- stamps changed_at): a press right after that was aimed at what was there
-- before (after «Притянуть к себе» the strip closes and the next row's Kick /
-- Ban move up under the cursor; the only client's hello puts his line of
-- buttons where the tabs were). With `strip`: also not right after this row's own
-- strip opened / closed (its buttons appeared under the cursor; a
-- double-click on «Ещё»).
local function row_settled(i, rec, what, strip)
    local row = UI.player_rows and UI.player_rows[i]
    if row and (moved_since(row.changed_at, rec) or (strip and moved_since(row.strip_at, rec))) then
        log.info("ui: players: '%s' on row %d not done: the row moved or changed right before the click", tostring(what), i)
        return false
    end
    return true
end

local function build_players()
    local vb = new("VerticalBox")
    UI.players_title = text(T("pl_title_none"), 14, C.bone, { bold = true })
    vadd(vb, UI.players_title, 0, 4)
    UI.player_rows = {}
    for i = 1, PLAYER_ROWS do
        -- A row (a VerticalBox): line 1 = the dot, the name, the state (dim),
        -- the ping (right-aligned); the name has the Fill slot: all the room
        -- the state and the ping leave (Auto slots get their whole width
        -- first, a Fill slot what is left). Line 2, the host's view: Kick /
        -- Ban / «Ещё ›» right-aligned under the ping; then the «Ещё» strip.
        local rb = new("VerticalBox")
        local hb = new("HorizontalBox")
        local d, ds = dot(C.dim, 8)
        hadd(hb, ds, false, 2, VALIGN_CENTER)
        local name = text("", 14, C.bone)
        pcall(function() name.Clipping = 1 end)    -- EWidgetClipping::ClipToBounds
        -- wider than its room after all (wide letters, a long state): "…" at
        -- its end, not a letter cut in half (UTextBlock.TextOverflowPolicy,
        -- UE 5.1+, in the game's mappings; ETextOverflowPolicy::Ellipsis)
        pcall(function() name.TextOverflowPolicy = 1 end)
        -- hit-testable: its tooltip (the whole name when it is long) shows
        pcall(function() name:SetVisibility(VIS_VISIBLE) end)
        hadd(hb, name, true, 10)
        local state = text("", 12, C.dim)
        hadd(hb, state, false, 8)
        local ping = text("", 12, C.dim, { justify = 2 })
        hadd(hb, sized(ping, 58), false, 6)
        vadd(rb, hb, 0, 0)
        -- host: Kick / Ban for this player, then «Ещё ›» (a wider gap); a
        -- press the row moved under is no click (row_settled)
        local acts = new("HorizontalBox")
        local recs = {}
        local kick, _, kick_rec = row_button("btn_kick", "kick_tip", function()
            if row_settled(i, recs.kick, "kick") then UI.on_kick(i) end
        end, "kick")
        hadd(acts, kick, false)
        local ban, ban_text, ban_rec = row_button("btn_ban", "ban_tip", function()
            if row_settled(i, recs.ban, "ban") then UI.on_ban(i) end
        end, "ban")
        hadd(acts, ban, false, 4)
        local more, more_rec, more_arrow = more_button(function()
            if row_settled(i, recs.more, "more", true) then UI.on_extra(i) end
        end)
        hadd(acts, more, false, 10)
        recs.kick, recs.ban, recs.more = kick_rec, ban_rec, more_rec
        gate(kick_rec, acts, rb, vb)
        gate(ban_rec, acts, rb, vb)
        gate(more_rec, acts, rb, vb)
        local aslot = vadd(rb, acts, 3, 0)
        pcall(function() aslot:SetHorizontalAlignment(3) end)   -- HAlign_Right
        show(acts, false)
        -- the row's bottom gap: 1 under one line, 6 under two (refresh_players)
        local rslot = vadd(vb, rb, 0, 1)
        show(rb, false)
        -- the strip under the row's buttons (right-aligned, under «Ещё»): one
        -- button per EXTRA_ACTIONS entry, shown while that action is available
        local strip_hb = new("HorizontalBox")
        local strip = box(strip_hb, C.surface, 4, 3, 4, 3)
        local extra_btns = {}
        for j, a in ipairs(EXTRA_ACTIONS) do
            local rk = "x_" .. a.id
            local bg, _, rec = row_button(a.key, a.tip, function()
                if row_settled(i, recs[rk], a.id, true) then UI.on_extra_action(i, a.id) end
            end, a.id)
            recs[rk] = rec
            hadd(strip_hb, bg, false, j > 1 and 4 or nil)
            gate(rec, strip, rb, vb)
            extra_btns[a.id] = bg
        end
        local sslot = vadd(rb, strip, 3, 0)
        pcall(function() sslot:SetHorizontalAlignment(3) end)   -- HAlign_Right
        show(strip, false)
        UI.player_rows[i] = { row = rb, line1 = hb, slot = rslot, gap = 1, dot = d, name = name, state = state, ping = ping,
                              acts = acts, ban_text = ban_text, more = more, more_rec = more_rec, more_arrow = more_arrow,
                              strip = strip, extra_btns = extra_btns, extra = {} }
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
        -- Kick / Ban: not for a player still connecting (no hello yet: no
        -- SteamID, a placeholder name - a ban would be useless) or already kicked
        local acts = role == "host" and not e.host and e.key ~= nil and admin() ~= nil
            and state ~= "connecting" and not kicked(e.key)
        -- the «Ещё» strip's actions available for this player (ids)
        local extra = {}
        if acts then
            for _, a in ipairs(EXTRA_ACTIONS) do
                local okv, v = pcall(a.avail, e)
                if okv and v then extra[#extra + 1] = a.id end
            end
        end
        local full = e.name ~= nil and tostring(e.name) or nil   -- uncut, for the strip's actions
        local shown = cut(full, e.me and NAME_MAX_YOU or NAME_MAX)
        -- whole on hovering it: a cut name, and a long one the engine may end
        -- with "…" (too wide for its room)
        local long = full ~= nil and (shown ~= full or (utf8.len(full) or #full) >= NAME_TIP_FROM)
        out.rows[#out.rows + 1] = {
            name = e.me and T("pl_you", shown) or shown,
            tip = long and full or "",
            state = T("pl_state_" .. state),
            ping = (e.ping and not e.host) and T("pl_ping", math.floor(e.ping)) or "",
            color = STATE_COLOR[state] or C.dim,
            key = e.key, acts = acts, me = e.me == true,
            full = full,
            ban_sure = acts and UI.ban_confirm ~= nil and UI.ban_confirm.key == e.key
                and os.clock() - UI.ban_confirm.at <= BAN_CONFIRM_S or false,
            extra = extra,
            extra_open = #extra > 0 and UI.extra_open ~= nil and UI.extra_open == e.key,
        }
    end
    -- The host's view: a player's Kick / Ban / «Ещё» on a line under its
    -- name. A row without them (connecting, kicked) keeps that line's place
    -- while another row has them, so the rows under it do not move when its
    -- buttons come or go; the own row (never any buttons) and a client's
    -- whole list: one line.
    local any_acts = false
    for _, r in ipairs(out.rows) do if r.acts then any_acts = true end end
    for _, r in ipairs(out.rows) do r.two_lines = r.acts == true or (any_acts and not r.me) end
    return out
end

local function refresh_players(m)
    if not UI.player_rows then return end
    local pm = UI.players_model(m)
    local sig = { tostring(pm.visible), pm.title, pm.empty or "", pm.more or "" }
    local open_seen = false
    for _, r in ipairs(pm.rows) do
        sig[#sig + 1] = r.name .. "|" .. r.state .. "|" .. r.ping .. "|" .. tostring(r.key) .. tostring(r.acts) .. tostring(r.ban_sure)
            .. "|" .. table.concat(r.extra or {}, ",") .. tostring(r.extra_open) .. "|" .. tostring(r.full)
            .. "|" .. tostring(r.two_lines)
        if r.extra_open then open_seen = true end
    end
    -- the strip's player is gone, or has nothing in it any more: closed
    if UI.extra_open ~= nil and not open_seen then UI.extra_open = nil end
    sig = table.concat(sig, "\1")
    if sig == UI.players_sig then return end
    UI.players_sig = sig
    pcall(function() UI.players_title:SetText(FText(pm.title)) end)
    -- the row whose strip is open: the rows after it sit lower by its height
    -- (one line of buttons in every strip)
    local now, open_row, lines_above = os.clock(), nil, 0
    for i, r in ipairs(pm.rows) do if r.extra_open then open_row = i end end
    for i, row in ipairs(UI.player_rows) do
        local r = pm.rows[i]
        -- for row_settled: the row moved (a strip above it opened / closed, a
        -- row above got or lost its line of buttons) or holds another player
        -- now; its own Kick / Ban appeared (its player's hello came, a new
        -- row with them): where they are, nothing was a moment ago - under
        -- the list's last row the tabs, which move down; its own strip
        -- opened / closed
        local pos = lines_above .. ((open_row ~= nil and open_row < i) and "+strip" or "")
        if r then lines_above = lines_above + (r.two_lines and 2 or 1) end
        local strip_open = r ~= nil and r.extra_open == true
        if r and r.key ~= nil and row.key ~= nil and (r.key ~= row.key or pos ~= row.pos) then
            row.changed_at = now
        end
        if r and r.acts == true and not row.can_act then row.changed_at = now end
        if strip_open ~= (row.strip_open == true) then row.strip_at = now end
        row.pos, row.strip_open = pos, strip_open
        row.extra = {}
        if r then
            pcall(function() row.name:SetText(FText(r.name)) end)
            pcall(function() row.name:SetToolTipText(FText(r.tip or "")) end)
            pcall(function() row.state:SetText(FText(r.state)) end)
            pcall(function() row.ping:SetText(FText(r.ping)) end)
            pcall(function() row.dot:SetBrushColor(r.color) end)
            row.key, row.can_act, row.full = r.key, r.acts == true, r.full
            if r.acts or not r.two_lines then
                -- line 2: the buttons, or nothing (one line)
                show(row.acts, r.acts == true)
            else
                -- line 2 hidden but keeping its place (the rows under it stay put)
                pcall(function() row.acts:SetVisibility(VIS_HIDDEN) end)
                mark_off(row.acts, true)
            end
            local gap = r.two_lines and 6 or 1
            if row.gap ~= gap and row.slot then
                row.gap = gap
                pcall(function() row.slot:SetPadding(margin(0, 0, 0, gap)) end)
            end
            pcall(function() row.ban_text:SetText(FText(T(r.ban_sure and "btn_ban_sure" or "btn_ban"))) end)
            if r.acts then
                for _, id in ipairs(r.extra or {}) do row.extra[id] = true end
            end
        else
            row.key, row.can_act, row.full = nil, false, nil
        end
        -- «Ещё»: only with something in its strip; else hidden, keeping its space
        if row.more then
            if next(row.extra) then
                show(row.more, true)
            else
                pcall(function() row.more:SetVisibility(VIS_HIDDEN) end)
                mark_off(row.more, true)
            end
            local open = r ~= nil and r.extra_open == true
            set_chevron(row.more_arrow, open)
            local rec = row.more_rec
            local colors = open and COL_OPEN or COL.secondary
            if rec and rec.colors ~= colors then
                rec.colors, rec.hovered = colors, false
                if ue.valid(rec.bg) then pcall(function() rec.bg:SetBrushColor(colors.base) end) end
            end
            for id, bg in pairs(row.extra_btns or {}) do show(bg, row.extra[id] == true) end
            show(row.strip, open)
        end
        show(row.row, r ~= nil)
    end
    if pm.more then pcall(function() UI.players_more:SetText(FText(pm.more)) end) end
    show(UI.players_more, pm.more ~= nil, VIS_HIT_TEST_INVISIBLE)
    if pm.empty then pcall(function() UI.players_empty:SetText(FText(pm.empty)) end) end
    show(UI.players_empty, pm.visible and pm.empty ~= nil, VIS_HIT_TEST_INVISIBLE)
    show(UI.players_box, pm.visible == true)
end

-- Host: Kick / Ban on a player's row (the row's session key at click time).
-- The rows are drawn again at once: the Ban button says "Sure?" (or the
-- kicked player's buttons go) before a second click can come.
function UI.on_kick(i)
    local row = UI.player_rows and UI.player_rows[i]
    local a = admin()
    if not row or not row.key or not row.can_act or not a then return end
    a.kick(row.key, false)
    UI.players_sig = nil
    refresh_players()
end

function UI.on_ban(i)
    local row = UI.player_rows and UI.player_rows[i]
    local a = admin()
    if not row or not row.key or not row.can_act or not a then return end
    local now = os.clock()
    if UI.ban_confirm and UI.ban_confirm.key == row.key and now - UI.ban_confirm.at <= BAN_CONFIRM_S then
        UI.ban_confirm = nil
        a.kick(row.key, true)
    else
        UI.ban_confirm = { key = row.key, at = now }
        log.info("ui: ban %s? (a second click within %d s confirms)", tostring(row.key), BAN_CONFIRM_S)
    end
    UI.players_sig = nil
    refresh_players()
end

-- Host: «Ещё ›» on a player's row opens its strip (one strip at a time: it
-- closes on a second click, another row's «Ещё», an action in it, and when
-- the panel closes). The strip belongs to the player (session key), not to
-- the row number: the rows can move under it.
function UI.on_extra(i)
    local row = UI.player_rows and UI.player_rows[i]
    if not row or not row.key or not row.can_act or not next(row.extra or {}) then return end
    UI.extra_open = UI.extra_open ~= row.key and row.key or nil
    UI.players_sig = nil
    refresh_players()
end

local function run_extra(row, id)
    if not row or not row.key or not row.can_act or not (row.extra or {})[id] then
        log.info("ui: players: '%s' not available for that row (any more)", tostring(id))
        return
    end
    for _, a in ipairs(EXTRA_ACTIONS) do
        if a.id == id then
            local ok, err = pcall(a.run, row.key, row.full)
            if not ok then log.err("ui: players: '%s': %s", id, tostring(err)) end
            return
        end
    end
end

-- A button in the strip of row `i`: only for the player the strip was
-- opened for; the strip closes.
function UI.on_extra_action(i, id)
    local row = UI.player_rows and UI.player_rows[i]
    if not row or not row.key or row.key ~= UI.extra_open then
        log.info("ui: players: '%s' on row %s not done: its strip is not open for that player any more", tostring(id), tostring(i))
        return
    end
    UI.extra_open = nil
    run_extra(row, id)
    UI.players_sig = nil
    refresh_players()
end

-- «Притянуть к себе» for row `i` (also the ui_test hook pull=<row>).
function UI.on_pull(i)
    local row = UI.player_rows and UI.player_rows[i]
    if not row then return end
    if row.key ~= nil and UI.extra_open == row.key then UI.extra_open = nil end
    run_extra(row, "pull")
    UI.players_sig = nil
    refresh_players()
end

-- ---------------------------------------------------------------------------
-- Steam (sdc_steamlink: a helper that carries the game's UDP over Steam P2P)
-- ---------------------------------------------------------------------------
-- Used only through pcall(require, "sdc_steamlink") and its interface:
--   status() -> { state = off|no_steam|starting|ready|hosting|joining|connected|error,
--                 detail = the module's own sentence, friends_only = bool }
--   friends() -> { { id, name, joinable, status }, ... }
--   join(id) -> ok, why          invite() -> ok, why
-- main.lua always loads it; a broken module shows as a Steam link error.

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

-- Host: Invite on a friend's row - a Steam invite to that friend, who goes
-- on the allowed list (join_access "invite only" lets them in).
local function on_steam_invite_friend(i)
    local f = UI.steam_friends and UI.steam_friends[i]
    local sl = steamlink()
    if not f or not sl or type(sl.invite_friend) ~= "function" then return end
    log.info("ui: steam: invite %s", log.ascii(tostring(f.name)))
    local ok, done, why, why_key = pcall(sl.invite_friend, f.id)
    if not ok or done == false then
        log.toast(ok and tostring(why or T("steam_error_plain")) or T("steam_invite_failed", tostring(done)), "warn", 8,
            "steam link invite of a friend: " .. tostring(ok and why_key or done), "steam_invite")
        return
    end
    local a = admin()
    if a and type(a.invited) == "function" then
        local oka, err = pcall(a.invited, f.name, f.id)
        if not oka then log.err("ui: steam: invited: %s", tostring(err)) end
    end
    UI.world_sig = nil
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
        local jb, jrec = small_button("btn_steam_join", function() on_steam_join(i) end, 28)
        gate(jrec, row)
        hadd(row, jb, false, 8, VALIGN_CENTER)
        -- the host: invite this friend (and put them on the allowed list)
        local ib, irec = small_button("btn_steam_invite_one", function() on_steam_invite_friend(i) end, 28)
        gate(irec, row)
        hadd(row, ib, false, 8, VALIGN_CENTER)
        show(ib, false)
        vadd(vb, row, 1, 2)
        show(row, false)
        UI.friend_rows[i] = { row = row, name = name, status = status, join = jb, invite = ib }
    end
    UI.steam_more = text("", 12, C.dim)
    vadd(vb, UI.steam_more, 0, 2)
    UI.steam_none = ltext("steam_no_friends", 13, C.dim, { wrap = true })
    vadd(vb, UI.steam_none, 0, 0)
    UI.steam_sig = nil
    for _, w in ipairs({ UI.steam_detail, UI.steam_note, UI.steam_invite, UI.steam_friends_title,
                         UI.steam_more, UI.steam_none }) do show(w, false) end
    return vb
end

-- What the Steam block shows now.
function UI.steam_model()
    local sl = steamlink()
    if not sl or type(sl.status) ~= "function" then
        -- no usable module (a broken install): an error line and the way to the IP tab
        return { available = false, state = "error", text = T("steam_error_plain"), color = C.err, friends = {} }
    end
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
    else
        -- every state comes with the module's own sentence
        m.text = detail or ""
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
    -- hosting through Steam: Invite on each friend's row (Join is no use then)
    local inviting = m.state == "hosting"
    local sig = { tostring(m.available), tostring(m.state), m.text or "", m.detail or "", tostring(m.friends_only),
                  UI.lang_built or "" }
    for _, f in ipairs(m.friends or {}) do
        sig[#sig + 1] = tostring(f.id) .. "|" .. tostring(f.name) .. "|" .. tostring(f.joinable) .. "|" .. tostring(f.status)
    end
    sig = table.concat(sig, "\1")
    if sig == UI.steam_sig then return end
    UI.steam_sig = sig
    pcall(function() UI.steam_status:SetText(FText(m.text or "")) end)
    pcall(function() UI.steam_dot:SetBrushColor(m.color or C.dim) end)
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
            local can_join = not inviting and UI.can_join_friend(f)
            -- a row with a button has less room (the Russian labels are long)
            local btn = can_join or inviting
            local room = btn and (i18n.language() == "ru" and 12 or 20) or 20
            pcall(function() row.name:SetText(FText(cut(f.name, room))) end)
            local st = f.status ~= nil and tostring(f.status) or ""   -- the module's own words
            pcall(function() row.status:SetText(FText(cut(st, btn and 16 or 26))) end)
            set_color(row.status, (f.joinable and not can_join and not inviting) and C.warn or C.dim)
            show(row.join, can_join)
            show(row.invite, inviting)
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
-- Steam when the Steam link is usable, else IP. A host with players waiting
-- for its answer: the World tab (its notice says so).
UI.user_tab = nil
function UI.pick_tab(id)
    UI.user_tab = id
    UI.select_tab(id)
end

function UI.default_tab()
    if UI.pages.world and (session.state or {}).role == "host" then
        local a = admin()
        local okw, list = pcall(function() return a and type(a.waiting) == "function" and a.waiting() or {} end)
        if okw and type(list) == "table" and #list > 0 then return "world" end
    end
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

-- IP tab: the address and the host's password (kept per address), the
-- how-to (Radmin VPN / ZeroTier / port forwarding) and a quick connection
-- test on a fresh map.
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
    vadd(vb, addr, 0, 6)
    vadd(vb, ltext("f_host_pw", 12, C.dim), 0, 3)
    UI.ip_pw = input_box("", lfn("f_host_pw_hint"))
    pcall(function() UI.ip_pw:SetIsPassword(true) end)
    vadd(vb, UI.ip_pw, 0, 8)
    fill_ip_pw()
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

-- The co-op character for the «Персонаж» tab (no widgets: tests read it):
-- { known, made, text, button }. sdc_charcreate (loaded by main.lua) keeps
-- it in its public field `stored` (Mods/SDCoop/character.txt: sex, first /
-- forename, last / surname, ...); only that field is read.
function UI.char_model()
    local cc = package.loaded["sdc_charcreate"]
    if type(cc) ~= "table" then return { known = false, button = "btn_looks" } end
    if cfg.get("char_create") == false then return { known = true, made = false, text = T("char_off"), button = "btn_looks" } end
    local sel = rawget(cc, "stored")
    if type(sel) ~= "table" then
        return { known = true, made = false, text = T("char_none"), button = "btn_looks_new" }
    end
    local sex = T(sel.sex == "Female" and "char_sex_female" or "char_sex_male")
    local first = tostring(sel.first or sel.forename or "")
    local last = tostring(sel.last or sel.surname or "")
    local name = (first .. " " .. last):gsub("^%s+", ""):gsub("%s+$", "")
    local text = name ~= "" and T("char_made_named", sex, cut(name, 40)) or T("char_made", sex)
    return { known = true, made = true, text = text, button = "btn_looks" }
end

-- The line under «Внешность» and its button's label (the panel opens, the
-- tab is shown, the 1 s refresh while open; only when they change).
function UI.refresh_char()
    if not ue.valid(UI.char_info) then return end
    local m = UI.char_model()
    local sig = tostring(m.text) .. "\1" .. m.button
    if sig == UI.char_sig then return end
    UI.char_sig = sig
    UI.char_button_key = m.button
    if m.text then pcall(function() UI.char_info:SetText(FText(m.text)) end) end
    show(UI.char_info, m.text ~= nil, VIS_HIT_TEST_INVISIBLE)
    if ue.valid(UI.looks_text) then pcall(function() UI.looks_text:SetText(FText(T(m.button))) end) end
end

local function build_char()
    local vb = new("VerticalBox")
    vadd(vb, heading("sec_name"), 0, 8)
    vadd(vb, input("player_name", "f_name_hint"), 0, 14)

    vadd(vb, heading("sec_looks"), 0, 6)
    -- whether a co-op character exists (sdc_charcreate.stored)
    UI.char_info = text("", 13, C.bone, { wrap = true })
    vadd(vb, UI.char_info, 0, 8)
    show(UI.char_info, false)
    UI.char_sig = nil
    -- the co-op character in the game's own creator (main menu, sdc_charcreate)
    UI.char_row = new("VerticalBox")
    local lb, lrec, lt = button(function() return T(UI.char_button_key or "btn_looks") end, nil, function()
        UI.set_open(false)
        local cc = package.loaded["sdc_charcreate"]
        if type(cc) == "table" and type(cc.open_from_menu) == "function" then cc.open_from_menu("panel") end
    end)
    lrec.label = "looks"
    UI.looks_text = lt
    gate(lrec, UI.char_row)
    vadd(UI.char_row, lb, 0, 4)
    vadd(UI.char_row, caption("looks_caption"), 0, 0)
    vadd(vb, UI.char_row, 0, 14)
    UI.looks_off = ltext("looks_menu_only", 13, C.dim, { wrap = true })
    vadd(vb, UI.looks_off, 0, 14)
    show(UI.looks_off, false)

    UI.rescue_title = heading("sec_rescue")
    vadd(vb, UI.rescue_title, 0, 8)
    -- Client with a character: stuck in a wall, fell through the world, can't
    -- move -> the host puts the character next to itself or on a game start
    -- point (sdc_players.request_unstuck; alive, not in a vehicle, cooldown).
    UI.unstuck_row = new("VerticalBox")
    vadd(UI.unstuck_row, ltext("unstuck_caption", 13, C.dim, { wrap = true }), 0, 6)
    local hb, hrec = button("btn_unstuck_host", nil, function()
        UI.set_open(false)
        require("sdc_players").request_unstuck("host")
    end)
    gate(hrec, UI.unstuck_row)
    vadd(UI.unstuck_row, hb, 0, 6)
    local sb, srec = button("btn_unstuck_start", nil, function()
        UI.set_open(false)
        require("sdc_players").request_unstuck("start")
    end)
    gate(srec, UI.unstuck_row)
    vadd(UI.unstuck_row, sb, 0, 0)
    vadd(vb, UI.unstuck_row, 0, 10)
    UI.char_offline = ltext("char_ingame_only", 13, C.dim, { wrap = true })
    vadd(vb, UI.char_offline, 0, 0)
    show(UI.unstuck_row, false)
    show(UI.rescue_title, false)
    show(UI.char_offline, true)
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
            for _, key in ipairs(keys) do
                vadd(gb, check_row(key, CHECK_WRAP.group), 2, 2)
                for _, nk in ipairs((i18n.NUMS_OF or {})[key] or {}) do
                    if i18n.schema_row(nk) then vadd(gb, num_row(nk), 1, 1, 28) end
                end
            end
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

-- ---------------------------------------------------------------------------
-- World tab (host; sdc_admin): who can join (join_access, saved at once;
-- with «По паролю» the join password and its own Save) and
-- the client_cheats checkbox, the players waiting for the host's answer,
-- the players turned away lately, the allowed list, the bans, and the
-- game's own save of this world. A client or a single player: one line.
-- ---------------------------------------------------------------------------

local WORLD_ROWS = { wait = 4, recent = 4, allowed = 6, bans = 6 }   -- built at first; more when needed
local WORLD_ROWS_MAX = 40   -- a list builds at most this many rows ("…and N more" past it)
-- one choice, two buttons a row: Все / По паролю, По одобрению / Только приглашённые
local ACCESS_MODES = { "open", "password", "approve", "list" }
local IS_MODE = { open = true, password = true, approve = true, list = true }

local function update_mode_buttons(mode)
    for v, rec in pairs(UI.mode_buttons or {}) do
        local colors = v == mode and COL.primary or COL.secondary
        if rec.colors ~= colors then
            rec.colors, rec.hovered = colors, false
            if ue.valid(rec.bg) then pcall(function() rec.bg:SetBrushColor(colors.base) end) end
        end
    end
end

-- Row `i` of a World tab list (into L.box, after the rows built so far).
local function world_row(L, i)
    local hb = new("HorizontalBox")
    local name = text("", 14, C.bone)
    pcall(function() name.Clipping = 1 end)    -- EWidgetClipping::ClipToBounds
    hadd(hb, name, true, 2)
    local info = text("", 12, C.dim)
    hadd(hb, info, false, 8)
    local acts = new("HorizontalBox")
    for j, b in ipairs(L.btns) do
        local rec
        local bg, _, brec = row_button(b[1], b[2], function()
            if moved_under(L.rows[i], rec) then
                log.info("ui: world: '%s' on row %d not done: the row got another entry right before the click", b[4], i)
                return
            end
            b[3](i)
        end, b[4])
        rec = brec
        gate(rec, acts, hb, L.vb, L.outer)
        hadd(acts, bg, false, j > 1 and 4 or nil)
    end
    hadd(hb, acts, false, 8)
    show(acts, false)
    vadd(L.box, hb, 0, 1)
    show(hb, false)
    L.rows[i] = { row = hb, name = name, info = info, acts = acts }
end

-- More rows for a list that outgrew them (at most WORLD_ROWS_MAX), in the
-- tab / section the list was built in.
local function grow_rows(L, n)
    n = math.min(n, WORLD_ROWS_MAX)
    if #L.rows >= n then return end
    local saved_tab, saved_sec = CTX.tab, CTX.sec
    CTX.tab, CTX.sec = L.tab, L.sec
    local from = #L.rows + 1
    local ok, err = pcall(function() for i = from, n do world_row(L, i) end end)
    CTX.tab, CTX.sec = saved_tab, saved_sec
    if not ok then log.err("ui: world: more rows: %s", tostring(err)) end
end

-- A list of the World tab: `n` rows at first (name | dim info | row
-- buttons, each { key, tip key, fn(i), label }; more are built when
-- needed), the "…and N more" line, and the line shown when it is empty
-- (empty_key; none = no line). `outer`: the box whose collapse also hides
-- its buttons.
local function world_list(vb, n, btns, empty_key, outer)
    local L = { rows = {}, btns = btns, vb = vb, outer = outer, tab = CTX.tab, sec = CTX.sec }
    L.box = new("VerticalBox")
    vadd(vb, L.box, 0, 0)
    for i = 1, n do world_row(L, i) end
    L.more = text("", 12, C.dim)
    vadd(vb, L.more, 0, 2)
    show(L.more, false)
    if empty_key then
        L.empty = ltext(empty_key, 13, C.dim, { wrap = true })
        vadd(vb, L.empty, 0, 0)
        show(L.empty, false)
    end
    return L
end

-- What a model row stands for (its key / entry id / name + SteamID).
local function item_id(it)
    if not it then return nil end
    return tostring(it.key or it.id or (tostring(it.raw or it.name) .. "|" .. tostring(it.sid)))
end

-- Puts model rows ({ name, info, act }) into a list; rows without buttons
-- keep their place when others have them (the columns line up). A row that
-- gets another entry is stamped (changed_at: a press right after it is no
-- click), so is the list when any row does.
local function fill_rows(L, items)
    if #items > #L.rows then grow_rows(L, #items) end
    local any = false
    for i = 1, math.min(#items, #L.rows) do
        if items[i].act then any = true end
    end
    local now = os.clock()
    for i, row in ipairs(L.rows) do
        local it = items[i]
        row.item = it
        local id = item_id(it)
        if id ~= row.item_id then
            row.item_id, row.changed_at, L.changed_at = id, now, now
        end
        -- a hidden row keeps no text (a language change would leave it stale)
        pcall(function() row.name:SetText(FText(it and it.name or "")) end)
        pcall(function() row.info:SetText(FText(it and it.info or "")) end)
        if it then
            if it.act or not any then
                show(row.acts, it.act == true)
            else
                pcall(function() row.acts:SetVisibility(VIS_HIDDEN) end)
                mark_off(row.acts, true)
            end
        end
        show(row.row, it ~= nil)
    end
    local more = #items - #L.rows
    pcall(function() L.more:SetText(FText(more > 0 and T("pl_more", more) or "")) end)
    show(L.more, more > 0, VIS_HIT_TEST_INVISIBLE)
    if L.empty then show(L.empty, #items == 0, VIS_HIT_TEST_INVISIBLE) end
end

local function build_world()
    local vb = new("VerticalBox")
    UI.world_guest = ltext("wa_guest", 13, C.dim, { wrap = true })
    vadd(vb, UI.world_guest, 0, 0)
    local host = new("VerticalBox")
    UI.world_host = host
    UI.world_rows = {}
    -- who can join: four exclusive options, two a row (saved at once), the
    -- mode's caption
    vadd(host, heading("wa_sec_access"), 0, 8)
    UI.mode_buttons = {}
    local tip = lfn("wa_mode_tip")
    local row
    for i, v in ipairs(ACCESS_MODES) do
        if i % 2 == 1 then
            row = new("HorizontalBox")
            vadd(host, row, i > 1 and 6 or 0, i + 1 >= #ACCESS_MODES and 4 or 0)
        end
        local bg, rec = button("wa_mode_" .. v, nil, function() UI.on_world_mode(v) end, 34)
        pcall(function() rec.w:SetToolTipText(FText(tip())) end)
        bind(rec.w, tip, "tip")
        gate(rec, host)
        hadd(row, bg, true, i % 2 == 0 and 6 or nil, VALIGN_FILL)
        UI.mode_buttons[v] = rec
    end
    UI.world_caption = text("", 12, C.dim, { wrap = true })
    vadd(host, UI.world_caption, 0, 2)
    UI.world_limit = text("", 12, C.dim, { wrap = true })
    vadd(host, UI.world_limit, 0, 2)
    show(UI.world_limit, false)
    -- the join password (only with «По паролю»): its own Save (the panel's
    -- footer saves the settings tab, and opening the panel refills fields)
    UI.world_pw_box = new("VerticalBox")
    vadd(UI.world_pw_box, ltext("wa_pw_title", 12, C.dim), 0, 3)
    local prow = new("HorizontalBox")
    UI.world_pw = input_box("", lfn("wa_pw_hint"))
    hadd(prow, UI.world_pw, true, nil, VALIGN_FILL)
    local pb, prec = button("wa_pw_save", "primary", function() UI.on_world_pw_save() end, 34)
    gate(prec, host, UI.world_pw_box)
    hadd(prow, sized(pb, 130), false, 8, VALIGN_FILL)
    vadd(UI.world_pw_box, prow, 0, 4)
    UI.world_pw_state = text("", 12, C.dim, { wrap = true })
    vadd(UI.world_pw_box, UI.world_pw_state, 0, 2)
    vadd(UI.world_pw_box, caption("wa_pw_cap"), 0, 0)
    vadd(host, UI.world_pw_box, 8, 2)
    show(UI.world_pw_box, false)
    fill_world_pw()
    -- the world's rules for the players (saved at once): the game's cheats,
    -- friendly fire (sdc_ffire) with what "off" means
    vadd(host, heading("wa_sec_rules"), 12, 6)
    UI.world_cheats = check_row("client_cheats", CHECK_WRAP.main)
    vadd(host, UI.world_cheats, 0, 4)
    UI.world_ff = check_row("friendly_fire", CHECK_WRAP.main)
    vadd(host, UI.world_ff, 0, 2)
    vadd(host, caption("wa_ff_cap"), 0, 14)
    -- knockdown and revive by a teammate (sdc_down)
    UI.world_down = check_row("down_enabled", CHECK_WRAP.main)
    vadd(host, UI.world_down, 0, 2)
    vadd(host, caption("wa_down_cap"), 0, 14)
    UI.world_checks = { client_cheats = UI.world_cheats, friendly_fire = UI.world_ff, down_enabled = UI.world_down }
    -- waiting for the host's answer
    UI.world_wait_box = new("VerticalBox")
    vadd(UI.world_wait_box, heading("wa_sec_waiting"), 0, 6)
    UI.world_rows.wait = world_list(UI.world_wait_box, WORLD_ROWS.wait, {
        { "wa_btn_allow", "wa_allow_tip", function(i) UI.on_world_allow(i) end, "allow" },
        { "wa_btn_deny", "wa_deny_tip", function(i) UI.on_world_deny(i) end, "deny" },
    }, "wa_waiting_none", host)
    vadd(host, UI.world_wait_box, 0, 14)
    show(UI.world_wait_box, false)
    -- turned away lately
    UI.world_recent_box = new("VerticalBox")
    vadd(UI.world_recent_box, heading("wa_sec_recent"), 0, 6)
    UI.world_rows.recent = world_list(UI.world_recent_box, WORLD_ROWS.recent, {
        { "wa_btn_add", "wa_add_tip", function(i) UI.on_world_add(i) end, "add to list" },
    }, nil, host)
    vadd(host, UI.world_recent_box, 0, 14)
    show(UI.world_recent_box, false)
    -- the allowed list
    local ab = new("VerticalBox")
    vadd(ab, heading("wa_sec_allowed"), 0, 6)
    UI.world_rows.allowed = world_list(ab, WORLD_ROWS.allowed, {
        { "wa_btn_remove", "wa_remove_tip", function(i) UI.on_world_remove(i) end, "remove from list" },
    }, "wa_allowed_none", host)
    vadd(host, ab, 0, 14)
    -- bans (moved here from the settings)
    local bb = new("VerticalBox")
    vadd(bb, heading("sec_bans"), 0, 6)
    UI.world_rows.bans = world_list(bb, WORLD_ROWS.bans, {
        { "wa_btn_unban", "wa_unban_tip", function(i) UI.on_world_unban(i) end, "unban" },
    }, "bans_none", host)
    -- Clear all: a second click confirms; not a press right after a row
    -- went (it slides up under the cursor)
    local urec
    local ub, brec, utext = button("btn_unban", nil, function()
        if moved_under(UI.world_rows.bans, urec) then
            log.info("ui: world: 'clear all bans' not done: the ban list changed right before the click")
            return
        end
        UI.on_world_unban_all()
    end, 32)
    urec = brec
    gate(urec, host)
    UI.world_unban_all, UI.world_unban_all_text = ub, utext
    vadd(bb, ub, 4, 0)
    show(ub, false)
    vadd(host, bb, 0, 14)
    -- the game's own save of this world
    UI.world_save_row = new("VerticalBox")
    local sb, srec = button("wa_btn_save", nil, function() UI.on_world_save() end)
    gate(srec, host, UI.world_save_row)
    vadd(UI.world_save_row, sb, 0, 4)
    vadd(UI.world_save_row, caption("wa_save_cap"), 0, 0)
    vadd(host, UI.world_save_row, 0, 0)
    show(UI.world_save_row, false)
    vadd(vb, host, 0, 0)
    show(host, false)
    UI.world_sig = nil
    return vb
end

local PAGES = { steam = build_steam_page, ip = build_ip_page, char = build_char, world = build_world,
                settings = build_settings }

-- What the World tab shows (no widgets; tests read it):
--   { host, guest (not the host: one line), mode, caption, limit,
--     show_pw (the password field: mode "password"), pw_set, pw_state,
--     waiting, recent, allowed, bans (rows: { name, info, act } and the
--     row's key / raw name + sid / entry id), show_waiting, show_recent,
--     can_save, saving }.
function UI.world_model()
    local st = session.state or {}
    local role = UI.test_role or st.role
    local a = admin()
    local m = { host = role == "host" and a ~= nil, waiting = {}, recent = {}, allowed = {}, bans = {} }
    if not m.host then
        m.guest = T("wa_guest")
        return m
    end
    local function call(fn, ...)
        if type(a[fn]) ~= "function" then return nil end
        local ok, v = pcall(a[fn], ...)
        if ok then return v end
        return nil
    end
    local mode = call("access_mode")
    m.mode = IS_MODE[mode] and mode or "open"
    m.caption = T("wa_cap_" .. m.mode)
    local max = tonumber(call("max_players")) or 0
    if max > 0 then m.limit = T("wa_limit", max) end
    m.show_pw = m.mode == "password"
    if m.show_pw then
        m.pw_set = (call("join_password") or "") ~= ""
        m.pw_state = T(m.pw_set and "wa_pw_set" or "wa_pw_unset")
    end
    for _, w in ipairs(call("waiting") or {}) do
        m.waiting[#m.waiting + 1] = { key = w.key, name = cut(w.name, 18), act = true,
                                      info = T("wa_secs", math.floor(tonumber(w.secs) or 0)) }
    end
    m.show_waiting = m.mode == "approve" or #m.waiting > 0
    for _, e in ipairs(call("recent") or {}) do
        -- guess: refused before it said who it is (a placeholder name): not for the list
        m.recent[#m.recent + 1] = { raw = e.name, sid = e.sid, name = cut(e.name, 16),
                                    info = T("wa_why_" .. tostring(e.reason or "denied")),
                                    act = not e.guess and call("is_allowed", e.name, e.sid) ~= true }
    end
    m.show_recent = #m.recent > 0
    local id_of = type(a.entry_id) == "function" and a.entry_id or function(e) return tostring(e.sid or e.name) end
    -- the list and the bans: the newest (the end of the config value) first
    local allowed, bans = call("allowed") or {}, call("bans") or {}
    for n = #allowed, 1, -1 do
        local e = allowed[n]
        m.allowed[#m.allowed + 1] = { id = id_of(e), name = cut(e.name or e.sid, 26), info = "", act = true }
    end
    for n = #bans, 1, -1 do
        local e = bans[n]
        m.bans[#m.bans + 1] = { id = id_of(e), name = cut(e.name or e.sid, 26), info = "", act = true }
    end
    m.unban_sure = #m.bans > 0 and UI.unban_all_at ~= nil and os.clock() - UI.unban_all_at <= BAN_CONFIRM_S
    m.saving = call("saving") == true
    m.can_save = type(a.save_world) == "function" and not UI.real_menu()
    return m
end

-- The World tab from its model: only when something changed (it is on
-- screen: the 4 Hz tick, the tab shown, a click, a language change).
function UI.refresh_world()
    if not UI.world_rows or not ue.valid(UI.world_host) then return end
    local m = UI.world_model()
    local parts = { tostring(m.host), m.guest or "", m.mode or "", m.caption or "", m.limit or "",
                    tostring(m.show_waiting), tostring(m.show_recent), tostring(m.can_save), tostring(m.saving),
                    tostring(m.unban_sure), tostring(m.show_pw), m.pw_state or "" }
    for _, list in ipairs({ m.waiting, m.recent, m.allowed, m.bans }) do
        parts[#parts + 1] = "#" .. #list
        for _, r in ipairs(list) do
            parts[#parts + 1] = r.name .. "|" .. r.info .. "|" .. tostring(r.act) .. "|" .. tostring(r.key or r.id or r.sid)
        end
    end
    local sig = table.concat(parts, "\1")
    if sig == UI.world_sig then return end
    UI.world_sig = sig
    show(UI.world_guest, not m.host, VIS_HIT_TEST_INVISIBLE)
    show(UI.world_host, m.host)
    if not m.host then return end
    update_mode_buttons(m.mode)
    pcall(function() UI.world_caption:SetText(FText(m.caption)) end)
    pcall(function() UI.world_limit:SetText(FText(m.limit or "")) end)
    show(UI.world_limit, m.limit ~= nil, VIS_HIT_TEST_INVISIBLE)
    show(UI.world_pw_box, m.show_pw == true)
    if m.show_pw then
        pcall(function() UI.world_pw_state:SetText(FText(m.pw_state or "")) end)
        set_color(UI.world_pw_state, m.pw_set and C.ok or C.warn)
    end
    show(UI.world_wait_box, m.show_waiting)
    fill_rows(UI.world_rows.wait, m.waiting)
    show(UI.world_recent_box, m.show_recent)
    fill_rows(UI.world_rows.recent, m.recent)
    fill_rows(UI.world_rows.allowed, m.allowed)
    fill_rows(UI.world_rows.bans, m.bans)
    show(UI.world_unban_all, #m.bans > 0)
    pcall(function() UI.world_unban_all_text:SetText(FText(T(m.unban_sure and "btn_ban_sure" or "btn_unban"))) end)
    show(UI.world_save_row, m.can_save)
end

-- The World tab's buttons: the row's item at click time; drawn again at once.
local function world_item(list, i)
    local L = UI.world_rows and UI.world_rows[list]
    local row = L and L.rows[i]
    return row and row.item or nil
end

local function world_act(fn, ...)
    local a = admin()
    if not a or type(a[fn]) ~= "function" then return end
    local ok, err = pcall(a[fn], ...)
    if not ok then log.err("ui: world: %s: %s", fn, tostring(err)) end
    UI.world_sig, UI.players_sig = nil, nil
    pcall(UI.refresh_world)
end

function UI.on_world_mode(v) world_act("set_access_mode", v) end

-- The join password's Save: as typed (trimmed), saved at once; the field
-- shows what was saved.
function UI.on_world_pw_save()
    if not ue.valid(UI.world_pw) then return end
    local ok, v = pcall(function() return ue.str(UI.world_pw:GetText()) end)
    if not ok then return end
    world_act("set_join_password", v)
    fill_world_pw()
end

function UI.on_world_allow(i)
    local it = world_item("wait", i)
    if it then world_act("allow", it.key) end
end

function UI.on_world_deny(i)
    local it = world_item("wait", i)
    if it then world_act("deny", it.key) end
end

function UI.on_world_add(i)
    local it = world_item("recent", i)
    if it and it.act then world_act("list_add", it.raw, it.sid) end
end

function UI.on_world_remove(i)
    local it = world_item("allowed", i)
    if it then world_act("list_remove", it.id) end
end

function UI.on_world_unban(i)
    local it = world_item("bans", i)
    if it then world_act("unban", it.id) end
end

-- Clear all bans: the first click asks (the button says "Sure?"), a second
-- one within BAN_CONFIRM_S clears them (as Ban on a player's row).
function UI.on_world_unban_all()
    local now = os.clock()
    if UI.unban_all_at and now - UI.unban_all_at <= BAN_CONFIRM_S then
        UI.unban_all_at = nil
        world_act("unban_all")
        return
    end
    UI.unban_all_at = now
    log.info("ui: world: clear all bans? (a second click within %d s confirms)", BAN_CONFIRM_S)
    UI.world_sig = nil
    pcall(UI.refresh_world)
end

function UI.on_world_save() world_act("save_world") end

-- The World tab's copy of a setting (client_cheats, friendly_fire) was
-- clicked: applied and saved at once (the players hear of a friendly fire
-- switch from sdc_admin's RULES|ff within a second; the host gets a notice).
function UI.on_world_check(key, v)
    cfg.set(key, v)
    local ok = cfg.save()
    log.info("ui: world: %s = %s (saved: %s)", key, tostring(v), tostring(ok))
    if key == "friendly_fire" then log.say(v and "ff_on_host" or "ff_off_host", "info", 6) end
    if key == "down_enabled" then log.say(v and "down_on_host" or "down_off_host", "info", 6) end
end

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
    local hb, hrec = button("btn_host", "primary", on_host)
    gate(hrec, UI.host_row)
    vadd(UI.host_row, hb, 0, 3)
    UI.host_caption_menu = caption("host_caption")
    vadd(UI.host_row, UI.host_caption_menu, 0, 0)
    UI.host_caption_world = caption("host_caption_world")
    vadd(UI.host_row, UI.host_caption_world, 0, 0)
    show(UI.host_caption_world, false)
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
        -- 14, not 15: five Russian (and English) labels overflowed the 480 panel
        local t = ltext("tab_" .. id, 14, C.dim, { bold = true, justify = JUSTIFY_CENTER })
        game_font(t, 14)
        local sb = new("SizeBox")
        pcall(function() sb:SetMinDesiredHeight(36) end)
        local ss = sb:SetContent(t)
        pcall(function() ss:SetVerticalAlignment(VALIGN_CENTER) end)
        pcall(function() ss:SetPadding(margin(2, 0, 2, 0)) end)
        local tb, trec = clickable(sb, COL.ghost, function() UI.pick_tab(id) end, "tab " .. id)
        -- the button's own side padding (12) is what made four tabs too wide
        pcall(function()
            local style = trec.w.WidgetStyle
            style.NormalPadding.Left, style.NormalPadding.Right = 4, 4
            style.PressedPadding.Left, style.PressedPadding.Right = 4, 4
        end)
        vadd(col, tb, 0, 0)
        local bar = box(nil, C.clear)
        vadd(col, sized(bar, nil, 3), 0, 0)
        -- left-aligned, as wide as their labels (+ the button padding): the
        -- game font is wider than the engine font, equal thirds crowded them
        hadd(row, col, false, i > 1 and 3 or nil, VALIGN_FILL)
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

-- ---------------------------------------------------------------------------
-- Player table, top right, in game: who is in this world, nick and ping (the
-- dot's colour: in game / loading / dead), the host first. A row's ping is
-- the delay between this machine and that player: the host sees every
-- client's ping, a client sees its own ping to the host on the host's row
-- (clients are not connected to each other). Host: its own list; client:
-- the host's ROSTER. Shown while
-- someone besides this player is there and the panel is closed; config
-- players_hud, the players_hud_key key (F8) shows / hides it (main.lua sets
-- KEYS.players, the frame loop calls UI.on_players_key).
-- ---------------------------------------------------------------------------

local HUD_ROWS = 8
local HUD_COLS = { "name", "ping" }
-- Slate units; measured in game at 1280x720 ("112 мс" fits in 62)
local HUD_W = { name = 150, ping = 62 }

local function hud_key()
    local k = tostring(cfg.get("players_hud_key") or ""):upper()
    return k ~= "" and k or "F8"
end
UI.hud_key = hud_key

-- One cell: a clipped text in a fixed-width box (the columns line up).
local function hud_cell(width, size, color, bold, justify)
    local t = text("", size, color, { bold = bold, justify = justify })
    pcall(function() t.Clipping = 1 end)    -- EWidgetClipping::ClipToBounds
    return t, sized(t, width, nil)
end

local function build_players_hud()
    local hb = new("HorizontalBox")
    local bar = hb:AddChildToHorizontalBox(sized(box(nil, C.amber), 3, nil))
    pcall(function() bar:SetVerticalAlignment(VALIGN_FILL) end)
    local vb = new("VerticalBox")
    -- title + key hint
    local top = new("HorizontalBox")
    UI.hud_title = text("", 13, C.bone, { bold = true })
    hadd(top, UI.hud_title, true)
    UI.hud_hint = text("", 11, C.dim)
    hadd(top, UI.hud_hint, false, 16)
    vadd(vb, top, 0, 5)
    vadd(vb, line(), 0, 4)
    -- column heads
    local head = new("HorizontalBox")
    hadd(head, sized(nil, 8, 8), false)
    UI.hud_heads = {}
    for _, col in ipairs(HUD_COLS) do
        local t, s = hud_cell(HUD_W[col], 11, C.dim, false, col == "ping" and 2 or nil)
        hadd(head, s, false, 8)
        UI.hud_heads[col] = t
    end
    vadd(vb, head, 0, 3)
    -- rows
    UI.hud_rows = {}
    for i = 1, HUD_ROWS do
        local row = new("HorizontalBox")
        local d, ds = dot(C.dim, 8)
        hadd(row, ds, false)
        local r = { row = row, dot = d }
        for _, col in ipairs(HUD_COLS) do
            local t, s = hud_cell(HUD_W[col], 12, col == "name" and C.bone or C.dim, col == "name",
                col == "ping" and 2 or nil)
            hadd(row, s, false, 8)
            r[col] = t
        end
        vadd(vb, row, 1, 1)
        show(row, false)
        UI.hud_rows[i] = r
    end
    UI.hud_more = text("", 11, C.dim)
    vadd(vb, UI.hud_more, 3, 0)
    show(UI.hud_more, false)
    local slot = hb:AddChildToHorizontalBox(box(vb, C.night, 10, 6, 12, 7))
    pcall(function() slot:SetVerticalAlignment(VALIGN_FILL) end)
    UI.hud_sig = nil
    return hb
end

-- What the table shows (no widgets; tests read it):
--   { visible, why, title, hint, heads = { name, ping },
--     rows = { { name, ping, color } }, more }
-- why: the reason it is hidden ("off" | "menu" | "panel" | "alone").
function UI.players_hud_model()
    local st = session.state or {}
    local role = UI.test_role or st.role
    local out = { visible = false, rows = {} }
    if cfg.get("players_hud") == false then out.why = "off" return out end
    if UI.open then out.why = "panel" return out end   -- the panel lists the players itself
    if role ~= "host" and role ~= "client" then out.why = "alone" return out end
    if role == "host" and not UI.test_roster and #(st.remote_pcs or {}) == 0 then out.why = "alone" return out end
    -- the real main menu (sdc_lobby.live_main_menu): not while dead in a world
    if not UI.test_role and UI.real_menu() then out.why = "menu" return out end
    local ok, list = pcall(function()
        if UI.test_roster then return UI.test_roster end
        return type(session.roster) == "function" and session.roster() or {}
    end)
    if not ok or type(list) ~= "table" or #list == 0 then out.why = "alone" return out end
    out.visible = true
    out.title = T("hud_title", #list)
    out.hint = T("hud_hint", hud_key())
    out.heads = { name = T("hud_col_name"), ping = T("hud_col_ping") }
    -- a client: its own ping to the host (its own measure, else the host's)
    local my_ping = role == "client" and st.client and st.client.ping or nil
    if role == "client" and not my_ping then
        for _, e in ipairs(list) do
            if e.me then my_ping = e.ping end
        end
    end
    for i, e in ipairs(list) do
        if i > HUD_ROWS then
            out.more = T("hud_more", #list - HUD_ROWS)
            break
        end
        local state = e.state or "game"
        local ping = nil
        if role == "host" then
            if not e.host then ping = e.ping end
        elseif e.host then
            ping = my_ping
        end
        out.rows[#out.rows + 1] = {
            name = e.me and T("pl_you", cut(e.name, 16)) or cut(e.name, 21),
            ping = ping and T("pl_ping", math.floor(ping)) or "",
            color = STATE_COLOR[state] or C.dim,
        }
    end
    return out
end

-- 1 s (and right after the key): the table follows the session.
function UI.update_players_hud()
    if not ue.valid(UI.players_hud) or not UI.hud_rows then return end
    local m = UI.players_hud_model()
    local sig = { tostring(m.visible) }
    if m.visible then
        sig[#sig + 1] = m.title .. "|" .. m.hint .. "|" .. (m.more or "") .. "|" .. m.heads.name .. m.heads.ping
        for _, r in ipairs(m.rows) do
            sig[#sig + 1] = r.name .. "|" .. r.ping .. "|" .. string.format("%.3f", r.color.R + r.color.G * 2)
        end
    end
    sig = table.concat(sig, "\1")
    if sig == UI.hud_sig then return end
    UI.hud_sig = sig
    if m.visible then
        pcall(function() UI.hud_title:SetText(FText(m.title)) end)
        pcall(function() UI.hud_hint:SetText(FText(m.hint)) end)
        for _, col in ipairs(HUD_COLS) do
            local h = UI.hud_heads[col]
            pcall(function() h:SetText(FText(m.heads[col])) end)
        end
        for i, row in ipairs(UI.hud_rows) do
            local r = m.rows[i]
            if r then
                for _, col in ipairs(HUD_COLS) do
                    local t = row[col]
                    pcall(function() t:SetText(FText(r[col])) end)
                end
                pcall(function() row.dot:SetBrushColor(r.color) end)
            end
            show(row.row, r ~= nil)
        end
        if m.more then pcall(function() UI.hud_more:SetText(FText(m.more)) end) end
        show(UI.hud_more, m.more ~= nil)
    end
    pcall(function() UI.players_hud:SetVisibility(m.visible and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) end)
end

-- The players table key: show / hide it and keep that in config.ini.
function UI.on_players_key()
    local on = cfg.get("players_hud") == false
    cfg.set("players_hud", on)
    UI.check_state.players_hud = on
    for _, cb in ipairs(UI.checks.players_hud or {}) do
        if ue.valid(cb) then pcall(function() cb:SetIsChecked(on) end) end
    end
    local saved = cfg.save()
    UI.hud_sig = nil
    pcall(UI.update_players_hud)
    local m = UI.players_hud_model()
    local key = on and ((m.visible or m.why == "panel") and "hud_shown" or "hud_shown_later") or "hud_hidden"
    log.toast(T(key, hud_key()), "info", 5,
        string.format("ui: players table %s by key %s (saved: %s)", on and "shown" or "hidden", hud_key(), tostring(saved)),
        "players_hud")
end

-- ---------------------------------------------------------------------------
-- Join cover (client; config join_cover). From the moment this game starts
-- joining a friend (sdc_session.join / join_tunnel stamp join.started_at,
-- or the role turns "client") until its own character stands where the host
-- put it, a dark full-screen cover with one status line and four steps
-- hides the screen. What it hides (client logs): ~20 s in the host's world
-- with no character of its own (the camera stays at the bare controller,
-- under the landscape) while the host's sdc_persist waits for this player's
-- id; then, for a returning player, the character first stands next to the
-- host and is moved to its saved spot ~8 s later (UNSTUCKTO "saved", right
-- before PSDONE).
-- Stages: arming (a join was asked; nothing running yet: not shown) ->
-- connect (PendingNetGame / the Steam tunnel) -> load (role "client", the
-- controller is still the menu world's) -> pawn (the host's world, no own
-- character; "wait" while the host has to let this player in: ACCESS|wait,
-- sdc_admin) -> verdict / restore / fresh (own character;
-- sdc_persist.client_join_state) -> "Ready", then a fade. Never traps the
-- player: 60 s in the host's world (then a dim note over the game; the wait
-- for the host's answer does not count, up to WAIT_MAX_S), the menu
-- key or Esc. A host or single player never arms it (no join, never
-- "client"); a respawn later in the same connection does not either.
-- A failed join, or a connection that ended against the player's will (a
-- kick, the host gone), shows on the same cover: what went wrong, what to
-- do, "Try again" / "Close" (JC.FAIL; the session's message comes here
-- through sdc_log.join_sink instead of a toast), until Esc, the menu key,
-- a button or the next attempt. The join's own progress messages are not
-- toasted while the cover shows that progress (JC.QUIET).
-- UI.join_cover_tick (4 Hz) runs the logic, UI.join_cover_model builds what
-- is shown (no widgets: tests read it), JC.render only shows the model. The
-- cover is the canvas's first child: the toast, the panel and the players
-- table draw above it. It takes clicks while up (the game's hidden menu
-- buttons under it get none), not while it fades; collapsed when off.
-- ---------------------------------------------------------------------------

local JC = {
    TIMEOUT_S = 60,       -- in the host's world: the game is shown after this long anyway
    LOAD_MAX_S = 120,     -- from the join's start to the host's world
    GRACE_S = 3,          -- a join just asked: its connection attempt shows up within this
    FRESH_MAX_S = 10,     -- a new character: set up here (sdc_progress, 6 s after it came) or this long
    RESTORE_MAX_S = 30,   -- a saved character: the host's PSDONE or this long after it came
    VERDICT_MAX_S = 15,   -- no answer from the host's sdc_persist (an older mod): this long after it came
    SETTLE_S = 1.0,       -- done: "Ready" this long (a move to the saved spot settles) ...
    FADE_S = 0.6,         -- ... then a fade
    NOTE_S = 30,          -- after a timeout: the dim note over the game at most this long
    FAIL_GRACE_S = 3,     -- a failure said this soon after the cover went ("left" / "cancel") still shows on it
    WAIT_HINT_S = 5,      -- connect: no answer from the host this long -> the hint says so
    WAIT_MAX_S = 150,     -- the host's yes awaited at most this long (it refuses after 120 s)
    STEP = { connect = 1, load = 2, pawn = 3, wait = 3, verdict = 4, restore = 4, fresh = 4, done = 5 },
    STEPS = { "jc_step_connect", "jc_step_world", "jc_step_char", "jc_step_items" },
    TEXT = { connect = "pl_connecting", load = "jc_load", pawn = "jc_pawn", wait = "jc_access_wait",
             verdict = "jc_verdict", restore = "jc_restore", fresh = "jc_fresh", done = "jc_done" },
    HINT = { load = "jc_hint_load", pawn = "jc_hint_pawn", wait = "jc_hint_access_wait", verdict = "jc_hint_verdict",
             restore = "jc_hint_restore", fresh = "jc_hint_fresh" },
    s = nil,              -- the current join (nil: none yet)
    join_seen = nil,      -- session.state.join.started_at already acted on
    conn_seen = nil,      -- session.state.client already acted on
    esc_key = nil, esc_was = false, frame_build_at = 0,
}
UI._jc = JC   -- tests

-- Why a join failed: the message key -> the cover's texts (no text: the
-- message itself). A later message replaces the shown one only when its prio
-- is higher (a kick comes first, then its "connection lost"). `step`: the
-- step it failed at whatever the cover saw (no answer = the connection);
-- `left`: it ended a connection (the title says so).
JC.FAIL = {
    admin_banned_you     = { prio = 9, text = "jc_err_banned", hint = "jc_err_banned_hint", no_retry = true, nosteps = true },
    admin_kicked_you     = { prio = 8, text = "jc_err_kicked", hint = "jc_err_kicked_hint", nosteps = true },
    -- not let in (sdc_admin: KICK|2..5); door: no "disconnected" title
    -- unless a character had come
    access_list_you      = { prio = 9, text = "jc_err_list", hint = "jc_err_list_hint", no_retry = true, nosteps = true,
                             door = true },
    access_denied_you    = { prio = 8, text = "jc_err_denied", hint = "jc_err_denied_hint", nosteps = true, door = true },
    access_timeout_you   = { prio = 8, text = "jc_err_no_reply", hint = "jc_err_no_reply_hint", nosteps = true, door = true },
    access_full_you      = { prio = 8, text = "jc_err_full", hint = "jc_err_full_hint", nosteps = true, door = true },
    -- the join password (KICK|6): a field and Join in place of Try again
    -- (shown with join_cover off too: the password has to be typed somewhere)
    access_pw_need_you   = { prio = 8, text = "jc_err_pw_need", hint = "jc_err_pw_hint", nosteps = true, door = true,
                             password = true },
    access_pw_wrong_you  = { prio = 8, text = "jc_err_pw_wrong", hint = "jc_err_pw_hint", nosteps = true, door = true,
                             password = true },
    access_pw_locked_you = { prio = 9, hint = "jc_err_pw_locked_hint", no_retry = true, nosteps = true, door = true },
    -- KICK|6|3: «По паролю» but no password saved by the host: nothing to
    -- type (any password is refused the same way), no retry
    access_pw_unset_you  = { prio = 9, text = "jc_err_pw_unset", hint = "jc_err_pw_unset_hint", no_retry = true,
                             nosteps = true, door = true },
    sl_rejected          = { prio = 7, hint = "jc_err_rejected_hint", step = 1 },
    sl_join_failed       = { prio = 6, hint = "jc_err_steam_hint", step = 1 },
    sl_no_helper         = { prio = 6, no_retry = true, step = 1 },
    sl_st_off            = { prio = 6, no_retry = true, step = 1 },
    host_no_answer       = { prio = 5, text = "jc_err_no_answer", hint = "jc_err_no_answer_hint", step = 1 },
    host_no_answer_steam = { prio = 5, text = "jc_err_no_answer_steam", hint = "jc_err_no_answer_steam_hint", step = 1 },
    sl_tunnel_lost       = { prio = 4, text = "jc_err_lost", hint = "jc_err_lost_hint", left = true },
    connection_lost      = { prio = 4, text = "jc_err_lost", hint = "jc_err_lost_hint", left = true },
    -- the host went to its main menu (sdc_session HOSTMENU): above the
    -- "connection lost" / "tunnel lost" its leaving brings
    host_menu_you        = { prio = 6, text = "jc_err_host_menu", hint = "jc_err_host_menu_hint", left = true },
}
-- Its texts (here with the entry; sdc_i18n's own, if it ever has them, win)
-- and its class (the mod's: a connection's end).
for lang, t in pairs({
    ru = { jc_err_host_menu = "Хост вышел в главное меню",
           jc_err_host_menu_hint = "Мир хоста закрыт. Подключитесь снова, когда хост загрузит сохранение." },
    en = { jc_err_host_menu = "The host went to the main menu",
           jc_err_host_menu_hint = "The host's world is closed. Join again once the host has loaded a save." },
}) do
    local into = type(i18n.STR) == "table" and i18n.STR[lang] or nil
    if type(into) == "table" then
        for k, v in pairs(t) do if into[k] == nil then into[k] = v end end
    end
end
if type(i18n.SAY_CLASS) == "table" and i18n.SAY_CLASS.host_menu_you == nil then i18n.SAY_CLASS.host_menu_you = "mod" end
-- What the cover's own steps already say: not toasted while it is up.
JC.QUIET = { connecting = true, sl_joining = true, connected = true, connected_to = true, sl_wait_host = true,
             persist_fresh_client = true, persist_restored_client = true, access_ok_you = true,
             -- the cover's line says it (sdc_steamlink.status: sl_st_silent / sl_st_silent_left)
             sl_host_silent = true, sl_host_silent_left = true }
-- Said on the cover only while it shows (or is about to show) the wait for the
-- host's answer: before this player's character exists.
JC.BEFORE_CHAR = { connect = true, load = true, pawn = true, wait = true }

function JC.on() return cfg.get("join_cover") ~= false end

-- What the stages are made of (engine reads in one place).
function JC.inputs()
    local st = session.state or {}
    local i = { role = st.role, client = st.client, join = st.join or {}, ps = {} }
    -- the host's access answer for this connection (sdc_admin's ACCESS: "wait" | "ok")
    i.access = type(st.client) == "table" and st.client.access or nil
    local pc = ue.local_pc()
    if pc then
        i.pc_name = ue.name(pc)
        i.pc_role = ue.role and ue.try(ue.role, pc) or nil
        local pawn = ue.pawn_of(pc)
        if pawn and ue.class_name(pawn) == "BP_PlayerCharacter_C" then
            i.pawn = true
            i.dead = ue.prop(pawn, "PlayerDead?") == true
        end
    end
    local persist = package.loaded["sdc_persist"]
    if type(persist) == "table" and type(persist.client_join_state) == "function" then
        local ok, v = pcall(persist.client_join_state)
        if ok and type(v) == "table" then i.ps = v end
    end
    return i
end

-- Before the role is "client": is a connection attempt running? (the Steam
-- tunnel being built: its own status line becomes the hint)
function JC.connecting(s)
    local joining = false
    local sl = package.loaded["sdc_steamlink"]
    if type(sl) == "table" and type(sl.status) == "function" then
        local ok, v = pcall(sl.status)
        joining = ok and type(v) == "table" and v.state == "joining"
        s.detail = joining and type(v.detail) == "string" and v.detail ~= "" and v.detail or nil
    end
    return joining or ue.has_pending_connection()
end

function JC.start(now, why, i)
    -- first: the join as asked (a Steam code stays one after the tunnel is up)
    JC.s = { at = now, seen_at = now, why = why, pc0 = i.pc_name, target = i.join.target, via = i.join.via,
             first = i.join.code or i.join.target }
    JC.esc_was = false
    log.info("ui: join cover: armed (%s; target %s)", why, tostring(i.join.target))
end

-- how: done | timeout | key | cancel | left | dead | off
function JC.finish(now, how, why)
    local s = JC.s
    if not s or s.finished then return end
    s.finished, s.done_at = how, now
    local stage, took = tostring(s.stage or "-"), now - s.at
    if how == "done" then
        log.info("ui: join cover: done at stage %s after %.1f s (%s): Ready, fading out", stage, took, why)
    elseif how == "timeout" then
        s.note_until = now + JC.NOTE_S
        log.warn("ui: join cover: timeout at stage %s (%s; %.0f s since the join started): the game is shown, with a note",
            stage, why, took)
    elseif how == "key" then
        log.info("ui: join cover: hidden by %s at stage %s after %.1f s", why, stage, took)
        -- hidden while the host's answer is awaited: the usual notice says
        -- it now (the cover is gone), a dim note until the answer comes
        if s.stage == "wait" then
            s.wait_note = true
            log.say("access_wait_you", "info", 12)
        end
    else
        log.info("ui: join cover: %s at stage %s after %.1f s (%s)", how, stage, took, why)
    end
end

-- A join failed (see JC.FAIL). With no cover up (a kick or the host gone
-- while playing) a new one comes up, showing only the error.
function JC.fail(now, key, text)
    local s = JC.s
    -- the host did answer (its world was loading): the connection broke, it
    -- is not "no answer"
    if s and s.answered and (key == "host_no_answer" or key == "host_no_answer_steam") then key = "connection_lost" end
    local e = JC.FAIL[key]
    if s and s.finished == "failed" and s.err then
        local cur = JC.FAIL[s.err.key]
        if cur and cur.prio >= e.prio then return end
    end
    local live = s and (not s.finished or s.finished == "failed"
        or ((s.finished == "left" or s.finished == "cancel") and now - (s.done_at or now) <= JC.FAIL_GRACE_S))
    if not live then
        local st = session.state or {}
        local j, old = st.join or {}, s
        -- first: the join as asked (a Steam code, not the tunnel's loopback address)
        s = { at = now, seen_at = now, late = true, target = j.target, via = j.via, first = j.code or j.target }
        if old and old.conn ~= nil and old.conn == st.client then
            -- this connection's cover, hidden by a key: what it knew
            s.conn, s.first, s.via, s.pawn_at = old.conn, old.first or s.first, old.via or s.via, old.pawn_at
        end
        if not s.pawn_at then
            local oki, i = pcall(JC.inputs)
            if oki and i.pawn then s.pawn_at = now end
        end
        JC.s = s
    end
    s.finished, s.done_at = "failed", now
    s.err = { key = key, text = text }
    -- the connection it failed on (nil: none yet): a later one takes it down (JC.update)
    s.err_conn = (session.state or {}).client
    JC.esc_was = true   -- an Esc already held does not close it at once
    log.info("ui: join cover: failed at stage %s after %.1f s (%s): shown with what to do", tostring(s.stage or "-"),
        now - s.at, key)
end

-- Error shown -> gone (Esc, the menu key, Close, Try again).
function JC.dismiss(why)
    local s = JC.s
    if not s or s.finished ~= "failed" then return end
    s.finished, s.closed_by = "closed", why
    log.info("ui: join cover: error closed (%s)", tostring(why))
end

-- "Try again": the same join as the failed one (a Steam code or ip:port).
function JC.retry()
    local s = JC.s
    if not s or s.finished ~= "failed" then return end
    local t = tostring(s.first or s.target or "")
    JC.dismiss("Try again")
    local sid = t:match("^steam:(%d+)$")
    local ip, port = t:match("^(.+):(%d+)$")
    if sid then
        session.join(sid, cfg.get("port"), false)
    elseif ip and s.via ~= "steam" then
        session.join(ip, tonumber(port), false)
    else
        session.join(cfg.get("host_ip"), cfg.get("port"), false)
    end
end

-- "Join" (a password refusal): the typed password is kept for the failed
-- join's target (sdc_admin.save_pw: an IP or a Steam friend), then the same
-- join again; its mod answers the host with it.
function JC.enter()
    local s = JC.s
    if not s or s.finished ~= "failed" then return end
    local target = tostring(s.first or s.target or "")
    if target == "" then
        -- no join recorded (a console "open"): never kept for a guessed
        -- host, nor joined (the IP tab's host may be another one; JC.error_model
        -- shows no Join then)
        log.info("ui: join cover: Join: the failed join recorded no target, the password is not kept, no join")
        return
    end
    local okt, typed = pcall(function() return ue.str(UI.jc_pw:GetText()) end)
    local a = package.loaded["sdc_admin"]
    if type(a) == "table" and type(a.save_pw) == "function" then
        local ok, err = pcall(a.save_pw, target, okt and typed or "")
        if not ok then log.err("ui: join cover: the password not kept: %s", tostring(err)) end
    end
    -- the IP tab's field shows what is kept now (a Join there does not undo it)
    pcall(fill_ip_pw)
    log.info("ui: join cover: Join with the typed password (%s)", target)
    JC.retry()
end

-- sdc_log.join_sink: true = shown on the cover (no toast).
function JC.on_say(key, text)
    if type(key) ~= "string" then return false end
    -- the error on the cover says why: not "you left" as well
    if key == "disconnected" then return JC.s ~= nil and JC.s.finished == "failed" end
    local e = JC.FAIL[key]
    -- join_cover off: only a password refusal comes up (its field is the one
    -- place to type the password for a Steam join)
    if not JC.on() and not (e and e.password) then return false end
    if e then
        if (session.state or {}).role == "host" then return false end
        local now = os.clock()
        JC.fail(now, key, text)
        pcall(JC.render, now)
        return true
    end
    -- the host has to let this player in: the cover's wait stage says it
    if key == "access_wait_you" then
        local s = JC.s
        return s ~= nil and not s.finished and JC.BEFORE_CHAR[s.stage] == true
    end
    if JC.QUIET[key] then
        -- "connecting" comes right before the cover arms: it shows the address
        if key == "connecting" or key == "sl_joining" then return true end
        local s = JC.s
        return s ~= nil and not s.finished and s.stage ~= nil and s.stage ~= "arming"
    end
    return false
end
log.join_sink = function(key, text) return JC.on_say(key, text) end

-- sdc_session's world reset on LoadMap (UI.forget_world): a level load
-- while the connection attempt still runs is the host's world loading, so
-- the host answered (a failed attempt is cancelled before the menu loads).
function JC.on_load_map()
    local s = JC.s
    if s and not s.finished and not s.answered and ue.pending_connection_live() then
        s.answered = os.clock()
        log.info("ui: join cover: the host answered (its world is loading) %.1f s after the join started", s.answered - s.at)
    end
end

function JC.update(now)
    local i = JC.inputs()
    -- a join asked here (sdc_session.join; join_tunnel stamps it again when
    -- the Steam tunnel is up: the same join, its next step)
    local started = i.join.started_at or 0
    if JC.join_seen == nil then JC.join_seen = started end
    if started ~= JC.join_seen then
        JC.join_seen = started
        local s = JC.s
        if i.role ~= "client" and started ~= 0 then
            if s and not s.finished and not s.conn then
                s.seen_at, s.target, s.via = now, i.join.target, i.join.via
            else
                -- a new join (the IP / Steam tab, sdcoop_join, a Steam
                -- invite): an earlier join's error goes, with join_cover off
                -- too (its password prompt shows then as well)
                if s and s.finished == "failed" then JC.dismiss("a new join") end
                if JC.on() then JC.start(now, "join asked", i) end
            end
        end
    end
    -- a new connection (sdc_session.on_role_change makes a new client state)
    if i.role == "client" and i.client ~= nil and i.client ~= JC.conn_seen then
        JC.conn_seen = i.client
        local s = JC.s
        -- an error of an earlier connection or join still shown (a console
        -- "open" stamps no join): it goes, with join_cover off too
        if s and s.finished == "failed" and s.err_conn ~= i.client then
            JC.dismiss("a new connection")
            s = nil
        end
        -- (not when sdc_session's bind_join forgot the join's address at
        -- this connection's start: then it is not that join's)
        if s and not s.conn and s.finished ~= "cancel" and now - s.at < JC.LOAD_MAX_S
            and (i.join.code or i.join.target) ~= nil then
            s.conn = i.client   -- the join asked here became this connection
        else
            -- joined some other way (console "open"): a connection that just
            -- began and no character yet (not a mod reload in the middle of a game)
            local t0 = type(i.client) == "table" and tonumber(i.client.connected_at) or nil
            if t0 and os.time() - t0 <= 120 and not i.pawn and JC.on() then
                JC.start(now, "connected", i)
                JC.s.conn = i.client
            end
        end
    end
    local s = JC.s
    if not s then return end
    if s.finished then
        -- hidden while waiting for the host: the note goes with the wait
        if s.wait_note and not (i.role == "client" and i.access == "wait") then
            s.wait_note = nil
            log.info("ui: join cover: the wait note taken off (%s)", i.access == "ok" and "let in" or "no longer waiting")
        end
        -- after a timeout: the note goes once the character is ready
        if s.finished == "timeout" and s.note_until and now < s.note_until then
            local ready = i.pawn and (i.ps.done or (i.ps.verdict == "fresh" and i.ps.applied))
            if i.role ~= "client" or ready then
                s.note_until = now
                log.info("ui: join cover: note taken off (%s)", ready and "the character is ready" or "no longer a client")
            end
        end
        return
    end
    if not JC.on() then return JC.finish(now, "off", "join_cover turned off") end
    if type(i.client) == "table" and i.client.host_name then s.host = i.client.host_name end
    local stage
    if i.role ~= "client" then
        if s.conn then return JC.finish(now, "left", "no longer a client") end
        if JC.connecting(s) then
            s.seen_at, s.live = now, true
        elseif now - s.seen_at > JC.GRACE_S then
            return JC.finish(now, "cancel", "no connection attempt running")
        end
        stage = s.live and "connect" or "arming"
    else
        s.conn = s.conn or i.client
        -- the host's world: this game's controller came from the host (a
        -- client's own one), or at least is not the menu world's any more
        -- (not a new controller of the menu world: a failed connection loads
        -- the menu again, its controller is this game's own, Authority)
        local loaded = i.pc_name ~= nil and (i.pc_role == (ue.ROLE_AUTONOMOUS or 2)
            or (s.pc0 ~= nil and i.pc_name ~= s.pc0 and i.pc_role ~= (ue.ROLE_AUTHORITY or 3)))
        if not loaded then
            -- the role is "client" from the first packet sent: until the
            -- host answers (its world starts loading) this is still the connection
            if not s.answered and ue.has_pending_connection() then
                stage = "connect"
            else
                stage = "load"
                s.answered = s.answered or now
            end
            if now - s.at >= JC.LOAD_MAX_S then
                return JC.finish(now, "timeout", string.format("the host's world not loaded in %d s", JC.LOAD_MAX_S))
            end
        else
            s.loaded_at = s.loaded_at or now
            if i.pawn and i.dead then return JC.finish(now, "dead", "own character is dead") end
            if not i.pawn then
                stage = "pawn"
                -- the host has to let this player in (join_access approve):
                -- no timeout while it waits, the minute starts after it
                if i.access == "wait" then
                    s.wait_at = s.wait_at or now
                    if now - s.wait_at < JC.WAIT_MAX_S then
                        stage = "wait"
                        s.loaded_at = now
                    end
                end
            else
                s.pawn_at = s.pawn_at or now
                local ps, since = i.ps, now - s.pawn_at
                if ps.verdict == "restore" then
                    stage = "restore"
                    if ps.done then return JC.finish(now, "done", "the host restored the saved character") end
                    if since >= JC.RESTORE_MAX_S then
                        return JC.finish(now, "done", string.format("no PSDONE from the host in %d s", JC.RESTORE_MAX_S))
                    end
                elseif ps.verdict == "fresh" then
                    stage = "fresh"
                    if ps.applied then return JC.finish(now, "done", "a new character, set up here") end
                    if since >= JC.FRESH_MAX_S then
                        return JC.finish(now, "done", string.format("a new character, not set up here in %d s", JC.FRESH_MAX_S))
                    end
                else
                    stage = "verdict"
                    if since >= JC.VERDICT_MAX_S then
                        return JC.finish(now, "done", string.format("no answer from the host's save module in %d s",
                            JC.VERDICT_MAX_S))
                    end
                end
            end
            if now - s.loaded_at >= JC.TIMEOUT_S then
                return JC.finish(now, "timeout", string.format("%d s in the host's world", JC.TIMEOUT_S))
            end
        end
    end
    if stage ~= s.stage then
        log.info("ui: join cover: stage %s -> %s (%.1f s since the join started)", tostring(s.stage or "-"), stage, now - s.at)
        s.stage = stage
    end
end

-- What the cover shows (no widgets):
--   { visible, stage, title, text, hint, key, steps = { { text, state } },
--     alpha (the fade), note (after a timeout, or hidden while the host's
--     answer is awaited: a dim line over the game) }
-- step state: "done" | "now" | "todo".
function UI.join_cover_model(now)
    now = now or os.clock()
    local s = JC.s
    local m = { visible = false, stage = s and (s.finished or s.stage) or "off", title = "", text = "", hint = "",
                key = "", steps = {}, alpha = 1 }
    if not s then return m end
    local key = tostring(cfg.get("menu_key") or "F7")
    if s.finished == "done" then
        local t = now - s.done_at
        if t >= JC.SETTLE_S + JC.FADE_S then return m end
        m.visible, m.stage = true, "done"
        m.alpha = t <= JC.SETTLE_S and 1 or math.max(0, 1 - (t - JC.SETTLE_S) / JC.FADE_S)
    elseif s.finished == "failed" then
        return JC.error_model(m, s, now, key)
    elseif s.finished then
        if s.finished == "timeout" and s.note_until and now < s.note_until then m.note = T("jc_note", key) end
        if s.finished == "key" and s.wait_note then m.note = log.tr("access_wait_you") end
        return m
    elseif not s.stage or s.stage == "arming" then
        return m
    else
        m.visible = true
    end
    local stage = m.stage
    m.title = s.host and T("jc_title_host", s.host) or T("jc_title")
    m.text = T(JC.TEXT[stage] or "jc_load")
    if stage == "connect" then
        local steam = s.via == "steam" or tostring(s.target or ""):find("^steam") ~= nil
        m.hint = s.detail or (steam and T("jc_hint_steam") or T("jc_hint_ip", tostring(s.target or "?")))
        if not s.detail and not steam and now - s.at >= JC.WAIT_HINT_S then
            m.hint = T("jc_hint_wait", tostring(s.target or "?"))
        end
    elseif JC.HINT[stage] then
        m.hint = T(JC.HINT[stage])
    end
    if stage ~= "done" then m.key = T("jc_key", math.max(0, math.floor(now - s.at)), key) end
    local cur = JC.STEP[stage] or 1
    for n, k in ipairs(JC.STEPS) do
        m.steps[n] = { text = T(k), state = n < cur and "done" or (n == cur and "now" or "todo") }
    end
    return m
end

-- A failed join: what went wrong (title, the reason, what to do), the step
-- it stopped at, the automatic join's next try or how to close it.
function JC.error_model(m, s, now, key)
    local e = JC.FAIL[s.err.key] or {}
    m.visible, m.stage, m.error = true, "failed", true
    local left = s.pawn_at ~= nil or (not e.door and (s.late or e.left))
    m.title = T(left and "jc_err_title_left" or "jc_err_title")
    m.text = e.text and T(e.text) or tostring(s.err.text or "")
    m.hint = e.hint and T(e.hint, tostring(s.target or s.first or "?")) or ""
    if not s.late and not e.nosteps then
        local cur = e.step or JC.STEP[s.stage] or 1
        for n, k in ipairs(JC.STEPS) do
            m.steps[n] = { text = T(k), state = n < cur and "done" or (n == cur and "fail" or "todo") }
        end
    end
    local nxt = type(session.auto_join_next) == "function" and session.auto_join_next() or nil
    m.key = nxt and T("jc_err_retry_in", math.floor(nxt)) or T("jc_err_close", key)
    local target = s.first or s.target or cfg.get("host_ip")
    m.retry = not e.no_retry and type(target) == "string" and target ~= ""
    -- a password refusal of a connection no join here led to (a console
    -- "open"): a typed password could be kept for no address and no join
    -- reaches that host (the IP tab's may be another one): no field, no
    -- Join, the hint says where to join it from
    if e.password and tostring(s.first or s.target or "") == "" then
        m.hint, m.retry = T("jc_err_pw_hint_where"), false
    end
    -- a password refusal: the field and Join (the same join with it)
    m.password = e.password == true and m.retry
    m.close = true
    return m
end

-- The cover's widgets: an opaque full-screen Border, a centred column (amber
-- bar, title, status line, four steps, hint, the error's buttons, elapsed
-- time + key).
function JC.build()
    local root = box(nil, C.cover)
    pcall(function() root:SetHorizontalAlignment(2) end)   -- HAlign_Center
    pcall(function() root:SetVerticalAlignment(VALIGN_CENTER) end)
    local col = new("VerticalBox")
    local function centre(slot) pcall(function() slot:SetHorizontalAlignment(2) end) end
    UI.jc_bar = box(nil, C.amber)
    centre(vadd(col, sized(UI.jc_bar, 56, 3), 0, 16))
    UI.jc_title = text("", 14, C.dim, { bold = true, justify = JUSTIFY_CENTER })
    centre(vadd(col, UI.jc_title, 0, 6))
    UI.jc_text = text("", 26, C.bone, { bold = true, justify = JUSTIFY_CENTER })
    pcall(function() UI.jc_text.WrapTextAt = 640 end)   -- engine font: it has "…" and Cyrillic
    centre(vadd(col, UI.jc_text, 0, 18))
    local steps = new("HorizontalBox")
    UI.jc_steps = {}
    for n = 1, #JC.STEPS do
        local d, ds = dot(C.line, 9)
        hadd(steps, ds, false, n > 1 and 22 or nil)
        local t = text("", 13, C.dim, { bold = true })
        hadd(steps, t, false, 7)
        UI.jc_steps[n] = { dot = d, text = t }
    end
    centre(vadd(col, steps, 0, 18))
    UI.jc_hint = text("", 14, C.dim, { justify = JUSTIFY_CENTER })
    pcall(function() UI.jc_hint.WrapTextAt = 560 end)
    centre(vadd(col, UI.jc_hint, 0, 10))
    -- a password refusal: the host's password (masked), as wide as the buttons
    UI.jc_pw = input_box("", lfn("f_host_pw_hint"))
    pcall(function() UI.jc_pw:SetIsPassword(true) end)
    UI.jc_pw_row = sized(UI.jc_pw, 352, nil)
    centre(vadd(col, UI.jc_pw_row, 2, 6))
    show(UI.jc_pw_row, false)
    -- a failed join: Try again (or Join, with the password) / Close. Polled
    -- by JC.frame (the panel's own button loop runs only while the panel is
    -- open), so not in UI.buttons.
    local function own_button(key, kind, fn)
        local bg, rec = button(key, kind, fn, 36)
        for n = #UI.buttons, 1, -1 do
            if UI.buttons[n] == rec then table.remove(UI.buttons, n) break end
        end
        return sized(bg, 170, nil), rec
    end
    local btns = new("HorizontalBox")
    local retry_rec, close_rec, enter_rec
    UI.jc_enter, enter_rec = own_button("jc_btn_enter", "primary", function() JC.enter() end)
    UI.jc_retry, retry_rec = own_button("jc_btn_retry", "primary", function() JC.retry() end)
    UI.jc_close, close_rec = own_button("jc_btn_close", nil, function() JC.dismiss("Close") end)
    UI.jc_recs = { enter = enter_rec, retry = retry_rec, close = close_rec }
    hadd(btns, UI.jc_enter, false)
    show(UI.jc_enter, false)
    hadd(btns, UI.jc_retry, false)
    hadd(btns, UI.jc_close, false, 12)
    UI.jc_btns = btns
    centre(vadd(col, btns, 6, 14))
    show(btns, false)
    UI.jc_key = text("", 12, C.dim, { justify = JUSTIFY_CENTER })
    centre(vadd(col, UI.jc_key, 0, 0))
    root:SetContent(col)
    return root
end

-- After a timeout: one dim line over the game, bottom centre.
function JC.build_note()
    UI.jc_note_text = text("", 13, C.dim, { justify = JUSTIFY_CENTER })
    pcall(function() UI.jc_note_text.WrapTextAt = 640 end)
    return box(UI.jc_note_text, C.night, 14, 8, 14, 9)
end

-- Shows the model: texts only when they change, the opacity on every call
-- while it fades.
function JC.render(now)
    if not ue.valid(UI.jc_root) then return end
    local m = UI.join_cover_model(now)
    -- while up it takes the clicks (none reach the game's hidden menu
    -- buttons under it; the panel above it still gets them); not while it
    -- fades; collapsed when off
    local vis = not m.visible and VIS_COLLAPSED or (m.stage == "done" and VIS_HIT_TEST_INVISIBLE or VIS_VISIBLE)
    local parts = { tostring(vis), m.title, m.text, m.hint, m.key, tostring(m.note), tostring(m.error),
                    tostring(m.retry), tostring(m.close), tostring(m.password) }
    for _, st in ipairs(m.steps) do parts[#parts + 1] = st.text .. st.state end
    local sig = table.concat(parts, "\1")
    if sig ~= UI.jc_sig then
        UI.jc_sig = sig
        if m.visible then
            pcall(function() UI.jc_title:SetText(FText(m.title)) end)
            pcall(function() UI.jc_text:SetText(FText(m.text)) end)
            pcall(function() UI.jc_hint:SetText(FText(m.hint)) end)
            pcall(function() UI.jc_key:SetText(FText(m.key)) end)
            show(UI.jc_hint, m.hint ~= "", VIS_HIT_TEST_INVISIBLE)
            show(UI.jc_key, m.key ~= "", VIS_HIT_TEST_INVISIBLE)
            show(UI.jc_btns, m.close == true, VIS_SELF_HIT_TEST_INVISIBLE)
            -- a password refusal: the field and Join in place of Try again
            local pw = m.password == true
            show(UI.jc_pw_row, pw)
            show(UI.jc_enter, pw, VIS_VISIBLE)
            JC.enter_shown = pw
            show(UI.jc_retry, m.retry == true and not pw, VIS_VISIBLE)
            JC.retry_shown = m.retry == true and not pw
            show(UI.jc_close, m.close == true, VIS_VISIBLE)
            pcall(function() UI.jc_bar:SetBrushColor(m.error and C.err or C.amber) end)
            for n, row in ipairs(UI.jc_steps or {}) do
                local st = m.steps[n]
                show(row.text, st ~= nil, VIS_HIT_TEST_INVISIBLE)
                show(row.dot, st ~= nil, VIS_HIT_TEST_INVISIBLE)
                if st then
                    pcall(function() row.text:SetText(FText(st.text)) end)
                    set_color(row.text, st.state == "todo" and C.dim or C.bone)
                    local c = st.state == "done" and C.ok or (st.state == "now" and C.amber
                        or (st.state == "fail" and C.err or C.line))
                    pcall(function() row.dot:SetBrushColor(c) end)
                end
            end
        end
        pcall(function() UI.jc_root:SetVisibility(vis) end)
        if ue.valid(UI.jc_note) then
            if m.note then pcall(function() UI.jc_note_text:SetText(FText(m.note)) end) end
            pcall(function() UI.jc_note:SetVisibility(m.note and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED) end)
        end
    end
    -- each new password refusal: an empty field (not the password just refused)
    local err = m.password and JC.s and JC.s.err or nil
    if err and err ~= UI.jc_pw_err then
        UI.jc_pw_err = err
        pcall(function() UI.jc_pw:SetText(FText("")) end)
    end
    local a = m.visible and m.alpha or 1
    if a ~= UI.jc_alpha then
        UI.jc_alpha = a
        pcall(function() UI.jc_root:SetRenderOpacity(a) end)
    end
end

-- 4 Hz (UI.slow_tick); tests pass `now` (os.clock seconds).
function UI.join_cover_tick(now)
    now = now or os.clock()
    JC.update(now)
    JC.render(now)
end

-- Every frame while a cover is up: the fade, Esc, and a widget the level
-- change took is built again at once (the 4 Hz tick may come 250 ms after
-- the host's world is first drawn).
function JC.frame()
    local s = JC.s
    if not s then return end
    local now = os.clock()
    local failed = s.finished == "failed"
    if not s.finished or failed then
        if not failed and (not s.stage or s.stage == "arming") then return end
        if not ue.valid(UI.widget) and now - JC.frame_build_at >= 0.05 then
            JC.frame_build_at = now
            UI.ensure()
            JC.render(now)
        end
        -- Esc: read on the game thread (as the vehicles' Tab), no key bind
        local pc = ue.local_pc()
        if pc then
            JC.esc_key = JC.esc_key or { KeyName = FName("Escape") }
            local down = ue.try(function() return pc:IsInputKeyDown(JC.esc_key) end) == true
            if down and not JC.esc_was then
                if failed then JC.dismiss("Esc") else JC.finish(now, "key", "Esc") end
                JC.render(now)
            end
            JC.esc_was = down
        end
        if failed and JC.s == s and s.finished == "failed" and JC.poll_buttons then
            JC.poll_buttons()
            if s.finished ~= "failed" then JC.render(os.clock()) end
        end
    elseif s.finished == "done" and now - s.done_at <= JC.SETTLE_S + JC.FADE_S + 0.25 then
        JC.render(now)
    end
end

local function drop_refs()
    UI.widget, UI.tree, UI.canvas, UI.panel = nil, nil, nil, nil
    UI.players_hud, UI.hud_title, UI.hud_hint, UI.hud_heads, UI.hud_rows, UI.hud_more, UI.hud_sig =
        nil, nil, nil, nil, nil, nil, nil
    UI.toast_box, UI.toast_text, UI.status_title, UI.status_body, UI.status_dot = nil, nil, nil, nil, nil
    UI.toast_dot, UI.toast_hint, UI.bug_section, UI.bug_path_box, UI.dot_color = nil, nil, nil, nil, nil
    UI.unstuck_row, UI.char_row, UI.looks_off, UI.rescue_title, UI.char_offline = nil, nil, nil, nil, nil
    UI.char_info, UI.looks_text, UI.char_sig = nil, nil, nil
    UI.players_title, UI.player_rows, UI.players_more, UI.players_empty, UI.players_sig = nil, nil, nil, nil, nil
    UI.extra_open = nil
    UI.steam_dot, UI.steam_status, UI.steam_status_row, UI.steam_note = nil, nil, nil, nil
    UI.steam_invite, UI.steam_friends_title, UI.friend_rows, UI.steam_more, UI.steam_none = nil, nil, nil, nil, nil
    UI.steam_sig, UI.steam_friends, UI.steam_ready, UI.steam_detail = nil, nil, nil, nil
    UI.disconnect_row, UI.disconnect_shown, UI.char_state = nil, nil, nil
    UI.host_row, UI.host_shown, UI.players_box, UI.steam_to_ip, UI.steam_help = nil, nil, nil, nil, nil
    UI.host_caption_menu, UI.host_caption_world = nil, nil
    UI.world_guest, UI.world_host, UI.world_rows, UI.world_sig, UI.mode_buttons = nil, nil, nil, nil, nil
    UI.world_caption, UI.world_limit, UI.world_cheats, UI.world_wait_box, UI.world_recent_box = nil, nil, nil, nil, nil
    UI.world_unban_all, UI.world_unban_all_text, UI.world_save_row = nil, nil, nil
    UI.world_ff, UI.world_checks, UI.world_down = nil, nil, nil
    -- the join cover's widgets (its state, JC.s, outlives them)
    UI.jc_root, UI.jc_title, UI.jc_text, UI.jc_steps, UI.jc_hint, UI.jc_key = nil, nil, nil, nil, nil, nil
    UI.jc_note, UI.jc_note_text, UI.jc_sig, UI.jc_alpha = nil, nil, nil, nil
    UI.jc_bar, UI.jc_btns, UI.jc_retry, UI.jc_close, UI.jc_recs = nil, nil, nil, nil, nil
    UI.jc_pw, UI.jc_pw_row, UI.jc_enter, UI.jc_pw_err = nil, nil, nil, nil
    UI.ip_pw, UI.ip_pw_shown, UI.world_pw, UI.world_pw_box, UI.world_pw_state = nil, nil, nil, nil, nil
    UI.scroll, UI.tab_ui, UI.lang_buttons = nil, nil, nil
    UI.buttons, UI.active, UI.active_dirty = {}, {}, true
    UI.off = setmetatable({}, { __mode = "k" })
    UI.menu_at, UI.menu_v = nil, nil
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

    -- first: everything after it draws above it (toast, panel, players table)
    step("join cover")
    local okj, errj = pcall(function()
        local root = JC.build()
        local js = canvas:AddChildToCanvas(root)
        pcall(function()
            js:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            js:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        end)
        pcall(function() root:SetVisibility(VIS_COLLAPSED) end)
        local note = JC.build_note()
        local ns = canvas:AddChildToCanvas(note)
        pcall(function()
            ns:SetAnchors({ Minimum = { X = 0.5, Y = 1.0 }, Maximum = { X = 0.5, Y = 1.0 } })
            ns:SetAlignment({ X = 0.5, Y = 1.0 })
            ns:SetPosition({ X = 0, Y = -90 })
            ns:SetAutoSize(true)
        end)
        pcall(function() note:SetVisibility(VIS_COLLAPSED) end)
        UI.jc_root, UI.jc_note = root, note
    end)
    if not okj then
        UI.jc_root, UI.jc_note = nil, nil
        log.err("ui: join cover not built: %s", tostring(errj))
    end

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

    step("players table")
    -- player table, top right (in game, while someone else is there)
    UI.players_hud = build_players_hud()
    local cs = canvas:AddChildToCanvas(UI.players_hud)
    pcall(function()
        cs:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
        cs:SetAlignment({ X = 1.0, Y = 0.0 })
        cs:SetPosition({ X = -16, Y = 12 })
        cs:SetAutoSize(true)
    end)
    pcall(function() UI.players_hud:SetVisibility(VIS_COLLAPSED) end)

    step("viewport")
    w:AddToViewport(900)
    UI.widget, UI.canvas = w, canvas
    UI.widget_live = true
    UI.built_epoch = UI.world_epoch
    UI.built_pc = ue.name(ue.local_pc())
    UI.shown = nil
    UI.toasts_dirty = true
    UI.lang_built = i18n.language()
    log.info("ui: menu built (%d buttons, %d texts, language %s)", #UI.buttons, #UI.ltexts, UI.lang_built)
    -- a join in progress: the new widget shows the cover in its first frame
    local okr, errr = pcall(JC.render, os.clock())
    if not okr then log.err_throttled("ui-cover", "ui: join cover: %s", tostring(errr)) end
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
    if why == "loadmap" then
        UI.world_epoch = UI.world_epoch + 1
        pcall(JC.on_load_map)
    end
    drop_refs()
    UI.built_pc = nil
    UI.shown = nil
    UI.toasts_dirty = true
    UI.last_map = nil
end
session.world_reset_hooks.ui = function(why, pc_key) UI.forget_world(why, pc_key) end

-- Crash guard: a marker file exists while the widget is being built (and
-- 6 s after, while Slate paints it). It holds the number of earlier starts
-- in a row that ended inside a build. The menu is kept off only when two
-- starts in a row did (as sdc_lobby): one crash - also during a rebuild
-- after a world load - only warns. A build that did not crash ends the
-- chain. Console commands work either way.
UI.marker_path = nil
UI.marker_hits = 0
UI.mod_dir = nil
UI.disabled = false

function UI.check_crash_marker(dir)
    UI.mod_dir = dir
    UI.marker_path = dir .. "/ui_build.marker"
    local f = io.open(UI.marker_path, "r")
    if not f then return end
    local line = f:read("*l")
    f:close()
    os.remove(UI.marker_path)
    local hits = (tonumber(line or "") or 0) + 1
    if hits >= 2 then
        UI.disabled = true
        UI.marker_hits = 0
        log.err("ui: %d starts in a row crashed while building the menu; menu disabled for this session. "
            .. "Console still works: sdcoop_help", hits)
    else
        UI.marker_hits = hits
        log.warn("ui: the previous start crashed while building the menu (%d/2); the menu stays on", hits)
    end
end

local function marker(on)
    if not UI.marker_path then return end
    if on then
        local f = io.open(UI.marker_path, "w")
        if f then f:write(tostring(UI.marker_hits), "\n"); f:close() end
    else
        UI.marker_hits = 0
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
    -- the chat's input line (sdc_chat) gives the keyboard to the panel at once
    if open then
        local chat = package.loaded["sdc_chat"]
        if type(chat) == "table" and type(chat.close) == "function" then pcall(chat.close, "panel") end
    end
    -- closing: a box clicked within the last 250 ms is synced first (a
    -- World-tab click applied and saved; the next open refills from cfg)
    if not open then pcall(sync_checks) end
    UI.open = open
    log.info("ui: menu %s", open and "opened" or "closed")
    -- a player's «Ещё» strip does not outlive the panel
    if not open and UI.extra_open ~= nil then
        UI.extra_open, UI.players_sig = nil, nil
        pcall(refresh_players)
    end
    if open then
        pcall(i18n.detect)
        if ue.valid(UI.widget) and UI.lang_built ~= i18n.language() then UI.relabel() end
        fill_widgets()
        if UI.pages.steam then
            local okt, tab = pcall(UI.default_tab)
            if okt and tab and tab ~= UI.tab then UI.select_tab(tab) end
        end
    end
    for _, b in ipairs(UI.buttons) do b.was = false end
    UI.apply_visibility()
    pcall(UI.update_players_hud)   -- the open panel lists the players: no table beside it
    set_game_input(open)
    if open then
        UI.refresh_status()
        pcall(UI.apply_game_font)
    end
end

function UI.toggle()
    UI.set_open(not UI.open)
end

-- Menu hotkey. Note: UE4SS treats every "UnrealWindow" as focused, so with
-- two copies of the game on one PC the key toggles the menu in both. That is
-- harmless (the menu only shows/hides); every action needs a mouse click
-- inside the specific window.
function UI.on_menu_key()
    -- the join cover goes first (never traps the player), then the panel as always
    local s = JC.s
    if s and not s.finished and s.stage and s.stage ~= "arming" then
        local now = os.clock()
        JC.finish(now, "key", tostring(cfg.get("menu_key") or "F7"))
        pcall(JC.render, now)
    elseif s and s.finished == "failed" then
        JC.dismiss(tostring(cfg.get("menu_key") or "F7"))
        pcall(JC.render, os.clock())
    end
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
    -- the real main menu, not "no own character" (dead in a world: opening
    -- the menu as a server there would drop the unsaved world)
    local in_menu = UI.real_menu()
    local okp, errp = pcall(refresh_players, m)
    if not okp then log.err_throttled("ui-players", "ui: players: %s", tostring(errp)) end
    local oks, errs = pcall(refresh_steam)
    if not oks then log.err_throttled("ui-steam", "ui: steam: %s", tostring(errs)) end
    local disc = role == "client" or m.pending == true
    if disc ~= UI.disconnect_shown then
        UI.disconnect_shown = disc
        show(UI.disconnect_row, disc)
    end
    -- in the menu (it reopens as a server) or in a single-player world (saved
    -- and loaded again open, sdc_session.open_world_now)
    local reopening = type(session.reopen_state) == "function" and session.reopen_state() ~= nil
    local can_host = role == "standalone" and not m.pending and m.color ~= C.warn and not reopening
        and (in_menu or ue.local_pawn() ~= nil)
    local host_key = can_host and (in_menu and "menu" or "world") or "none"
    if host_key ~= UI.host_shown then
        UI.host_shown = host_key
        show(UI.host_row, can_host)
        show(UI.host_caption_menu, host_key == "menu")
        show(UI.host_caption_world, host_key == "world")
    end
    local looks = in_menu and role ~= "client"
    local pawn = role == "client" and ue.local_pawn() or nil
    local unstuck = pawn ~= nil and ue.prop(pawn, "PlayerDead?") ~= true
    local key = tostring(looks) .. tostring(unstuck)
    if key ~= UI.char_state then
        UI.char_state = key
        show(UI.char_row, looks)
        show(UI.looks_off, not looks)
        show(UI.unstuck_row, unstuck)
        show(UI.rescue_title, unstuck)
        show(UI.char_offline, not unstuck)
    end
    UI.refresh_char()
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
-- drives it for screenshots: tab=steam|ip|char|world|settings, lang=auto|ru|en,
-- expand=<section>[,<section>...] / collapse=... (main, all, help, groups,
-- group <id>), scroll=start|end|<px>, open=1|0,
-- steammock=<steamlink state>|none, roster=host|client|off, hud=key (the
-- players table key), anykey=1 (past PRESS ANY KEY: MainMenu_C.Event_KeyDown),
-- continue=1 (the menu's Continue), host=1 (the panel's Open my world),
-- bug=open|form|logs[-dry], say=<catalog key>,<kind>, toast=<text>,
-- kick / ban / more / pull=<players row> (more: its «Ещё» strip).
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
                { id = "2", name = "Борис", joinable = false, status = "в игре" },
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
                { name = "Борис", state = "game", ping = 48, me = false, key = "test_boris" },
                { name = v == "client" and cfg.player_name() or "Vasya", state = v == "client" and "game" or "loading",
                  ping = 112, me = v == "client", key = "test_vasya" },
                { name = "Gleb", state = "connecting", me = false, key = "test_gleb" },
            }
        else
            UI.test_role, UI.test_roster = nil, nil
        end
        UI.refresh_status()
        UI.hud_sig = nil
        pcall(UI.update_players_hud)
    elseif k == "hud" then
        UI.on_players_key()
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
    elseif k == "anykey" then
        local mm = nil
        for _, o in ipairs(ue.find_all("MainMenu_C")) do
            if ue.valid(o) and not ue.short(o):find("^Default__") then mm = o end
        end
        local ok, err = pcall(function() mm:Event_KeyDown() end)
        log.info("ui: test: MainMenu_C.Event_KeyDown %s%s", ok and "ok" or "FAILED", ok and "" or (": " .. tostring(err)))
    elseif k == "continue" then
        local lobby = package.loaded["sdc_lobby"]
        local menu = lobby and lobby.live_main_menu and lobby.live_main_menu() or nil
        local ok, err = pcall(function()
            menu:BndEvt__MenuWidget_ContinueGame_K2Node_ComponentBoundEvent_25_OnButtonClickedEvent__DelegateSignature()
        end)
        log.info("ui: test: the menu's Continue %s%s", ok and "ok" or "FAILED", ok and "" or (": " .. tostring(err)))
    elseif k == "host" then
        on_host()
    elseif k == "kick" then
        UI.on_kick(tonumber(v))
    elseif k == "ban" then
        -- the second click inside the confirmation window bans
        UI.on_ban(tonumber(v))
        UI.on_ban(tonumber(v))
    elseif k == "more" then
        UI.on_extra(tonumber(v))
    elseif k == "pull" then
        UI.on_pull(tonumber(v))
    elseif k == "toast" then
        log.toast(v, "info", 12, "ui test toast")
    elseif k == "tod" then
        -- screenshots: the time of day on this machine's sky (the host's
        -- reaches the clients through ENV)
        local sky = ue.find_first("Ultra_Dynamic_Sky_C")
        local t = tonumber(v)
        local ok = sky and t and (ue.call(sky, "Transition Time of Day", t, 0.5, 0, 2, false)
            or ue.set_prop(sky, "Time of Day", t))
        log.info("ui: test: time of day -> %s (ok=%s)", tostring(t), tostring(ok))
    elseif k == "journal" then
        -- screenshots: press a tab of the game's open journal (J)
        local fns = {
            quests = "BndEvt__JournalUI_Test_QuestsButton_K2Node_ComponentBoundEvent_6_OnButtonClickedEvent__DelegateSignature",
            skills = "BndEvt__JournalUI_Test_SkillsButton_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature",
            info = "BndEvt__InfoSkillQuestUI_Button_56_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature",
        }
        local cls = ue.find_object("/Game/UI/Widgets/Journal/JournalUI.JournalUI_C")
        local wbl, wc = ue.widget_lib(), ue.local_pc()
        local arr, okj = {}, false
        if cls and wbl and wc and fns[v] then
            pcall(function() wbl:GetAllWidgetsOfClass(wc, arr, cls, false) end)
            for _, w in ipairs(arr) do
                local j = ue.valid(w) and w or ue.try(function() return w:get() end)
                if ue.valid(j) then okj = ue.call(j, fns[v]) or okj end
            end
        end
        log.info("ui: test: journal tab %s (%d journal widget(s), ok=%s)", tostring(v), #arr, tostring(okj))
    elseif k == "weather" then
        local okw = require("sdc_sync").test_weather(v)
        log.info("ui: test: weather channels %s (ok=%s)", log.ascii(v), tostring(okw))
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
    local okc, errc = pcall(UI.join_cover_tick)
    if not okc then log.err_throttled("ui-cover", "ui: join cover: %s", tostring(errc)) end
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
        if UI.tab == "settings" or UI.tab == "world" then pcall(sync_checks) end
        if UI.tab == "world" then pcall(UI.refresh_world) end
        if not UI.gfont_done and (UI.gfont_tries or 0) < 12 then pcall(UI.apply_game_font) end
    end
    if UI.status_ticks % 4 == 0 then
        pcall(UI.update_players_hud)
        local ok, err = pcall(test_tick)
        if not ok then log.err_throttled("ui-test", "ui: test tick: %s", tostring(err)) end
    end
end

local function m_hovered(w) return w:IsHovered() end
local function m_pressed(w) return w:IsPressed() end

-- The join cover's error buttons (JC.frame, every frame while it shows one).
function JC.poll_buttons()
    local recs = UI.jc_recs
    if not recs then return end
    for _, name in ipairs({ "enter", "retry", "close" }) do
        local b = recs[name]
        if b and ue.valid(b.w) and (name ~= "retry" or JC.retry_shown) and (name ~= "enter" or JC.enter_shown) then
            local okh, hov = pcall(m_hovered, b.w)
            hov = okh and hov == true
            if hov ~= b.hovered then
                b.hovered = hov
                pcall(function() b.bg:SetBrushColor(hov and b.colors.hover or b.colors.base) end)
            end
            local ok, pressed = pcall(m_pressed, b.w)
            pressed = ok and pressed == true
            if b.was and not pressed and hov then
                b.was = false
                log.debug("ui: click '%s' (join cover)", b.label)
                local okc, err = pcall(b.fn)
                if not okc then log.err("ui: join cover button '%s': %s", b.label, tostring(err)) end
                return
            end
            b.was = pressed
        end
    end
end

-- Every frame while open: hover colours and clicks of the shown buttons.
function UI.frame_tick()
    if JC.s then
        local okc, errc = pcall(JC.frame)
        if not okc then log.err_throttled("ui-cover-frame", "ui: join cover (frame): %s", tostring(errc)) end
    end
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
            -- when the press began (the player list's and the World tab's
            -- rows: a row that moved or changed right before it was not what
            -- the player aimed at)
            if pressed and not b.was then b.pressed_at = os.clock() end
            b.was = pressed
        end
    end
end

return UI
