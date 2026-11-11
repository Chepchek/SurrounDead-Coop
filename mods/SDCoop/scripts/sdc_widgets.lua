-- SDCoop: UI built out of the game's own widgets.
--
-- The co-op UI lives inside the game's screens (main menu, pause menu, death
-- screen). New buttons are made to look exactly like the game's: a fresh
-- UButton gets the original's style, colours and slot layout, and a fresh
-- TextBlock the original's font. Nothing is created from a template object,
-- because a template copy would also copy the original's OnClicked binding.
-- Clicks are detected by polling IsPressed/IsHovered every frame.

local log = require("sdc_log")
local ue = require("sdc_ue")

local W = {
    buttons = {},
    VISIBLE = 0, COLLAPSED = 1, HIDDEN = 2, HIT_TEST_INVISIBLE = 3, SELF_HIT_TEST_INVISIBLE = 4,
}

local class_cache = {}
function W.umg(short)
    local c = class_cache[short]
    if ue.valid(c) then return c end
    c = ue.find_object("/Script/UMG." .. short)
    if not c then error("UMG class not found: " .. short) end
    class_cache[short] = c
    return c
end

function W.new(short, outer)
    local o = StaticConstructObject(W.umg(short), outer)
    if not ue.valid(o) then error("cannot construct UMG." .. short) end
    return o
end

-- Depth-first search of a widget tree by widget name (panels, and content
-- widgets such as Border / SizeBox / ScaleBox / Button, which are panels too).
local function find_in_tree(widget, name, depth)
    if depth > 16 or not ue.valid(widget) then return nil end
    if ue.short(widget) == name then return widget end
    local n = ue.try(function() return widget:GetChildrenCount() end)
    if type(n) ~= "number" then return nil end
    for i = 0, n - 1 do
        local c = ue.try(function() return widget:GetChildAt(i) end)
        local found = find_in_tree(c, name, depth + 1)
        if found then return found end
    end
    return nil
end

-- Named child of a user widget: its variable, else GetWidgetFromName, else a
-- walk of its tree (designer widgets that are not variables: in game 0.8
-- GetWidgetFromName did not find MenuWidget's "MenuOverlay").
function W.child(user_widget, name)
    local w = ue.prop(user_widget, name)
    if ue.valid(w) then return w end
    w = ue.try(function() return user_widget:GetWidgetFromName(FName(name)) end)
    if ue.valid(w) then return w end
    local root = ue.try(function() return user_widget.WidgetTree.RootWidget end)
    return find_in_tree(root, name, 0)
end

function W.visible(w)
    if not ue.valid(w) then return false end
    local ok, v = pcall(function() return w:GetVisibility() end)
    return ok and v ~= W.COLLAPSED and v ~= W.HIDDEN
end

function W.hide(w)
    if ue.valid(w) then pcall(function() w:SetVisibility(W.COLLAPSED) end) end
end

-- First TextBlock inside a widget (button content, a box around a text...).
function W.first_text(w, depth)
    if not ue.valid(w) then return nil end
    if ue.class_name(w) == "TextBlock" then return w end
    depth = depth or 0
    if depth > 4 then return nil end
    local n = ue.try(function() return w:GetChildrenCount() end) or 0
    for i = 0, n - 1 do
        local t = W.first_text(ue.try(function() return w:GetChildAt(i) end), depth + 1)
        if t then return t end
    end
    return nil
end

-- Copies layout from one panel slot to another of the same kind.
local function copy_slot(src, dst)
    if not ue.valid(src) or not ue.valid(dst) then return end
    pcall(function() dst:SetPadding(src.Padding) end)
    pcall(function() dst:SetHorizontalAlignment(src.HorizontalAlignment) end)
    pcall(function() dst:SetVerticalAlignment(src.VerticalAlignment) end)
    pcall(function() dst:SetSize(src.Size) end)
    -- canvas slots
    pcall(function() dst:SetLayout(src.LayoutData) end)
    pcall(function() dst:SetZOrder(src.ZOrder) end)
    pcall(function() dst:SetAutoSize(src.bAutoSize) end)
end
W.copy_slot = copy_slot

function W.clone_text(src, label, outer)
    local t = W.new("TextBlock", outer)
    pcall(function() t:SetFont(src.Font) end)
    pcall(function() t:SetColorAndOpacity(src.ColorAndOpacity) end)
    pcall(function() t:SetShadowOffset(src.ShadowOffset) end)
    pcall(function() t:SetShadowColorAndOpacity(src.ShadowColorAndOpacity) end)
    pcall(function() t:SetJustification(src.Justification) end)
    pcall(function() t:SetRenderTransform(src.RenderTransform) end)
    pcall(function() t:SetVisibility(W.SELF_HIT_TEST_INVISIBLE) end)
    t:SetText(FText(label or ""))
    return t
end

-- Adds `w` to `parent` right after `after` (or at the end), copying the slot
-- layout of `layout_from`.
function W.insert_after(parent, w, after, layout_from)
    local slot = parent:AddChild(w)
    copy_slot(ue.prop(layout_from, "Slot"), slot)
    if ue.valid(after) then
        local idx = ue.try(function() return parent:GetChildIndex(after) end)
        if idx and idx >= 0 then pcall(function() parent:ShiftChild(idx + 1, w) end) end
    end
    return slot
end

-- Object identity without touching the object (UE4SS returns the pointer it
-- stores in the wrapper).
local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

-- The user widget a widget belongs to (the outer of its WidgetTree).
local function owner_of(w)
    if not ue.valid(w) then return nil end
    local tree = ue.try(function() return w:GetOuter() end)
    if not ue.valid(tree) then return nil end
    local o = ue.try(function() return tree:GetOuter() end)
    if ue.valid(o) then return o end
    return nil
end

-- A button that looks like `orig` (a UButton with a TextBlock, possibly inside
-- a box), placed after `after` (default: right after `orig`) in orig's panel.
-- `owner` (optional) is the screen the button lives on: its clicks are polled
-- only while that screen is on screen (see W.frame_tick / W.forget).
function W.clone_button(orig, label, handler, after, owner)
    local outer = ue.try(function() return orig:GetOuter() end)
    local b = W.new("Button", outer)
    pcall(function() b:SetStyle(orig.WidgetStyle) end)
    pcall(function() b:SetColorAndOpacity(orig.ColorAndOpacity) end)
    pcall(function() b:SetBackgroundColor(orig.BackgroundColor) end)

    local content = ue.try(function() return orig:GetChildAt(0) end)
    local src_text = W.first_text(content)
    if src_text then
        local t = W.clone_text(src_text, label, outer)
        local inner = t
        if ue.valid(content) and ue.class_name(content) ~= "TextBlock" then
            -- e.g. the pause menu wraps its texts in a HorizontalBox
            local box = W.new(ue.class_name(content), outer)
            copy_slot(ue.prop(src_text, "Slot"), box:AddChild(t))
            inner = box
        end
        copy_slot(ue.prop(content, "Slot"), b:AddChild(inner))
    end

    local parent = ue.try(function() return orig:GetParent() end)
    if ue.valid(parent) then W.insert_after(parent, b, after or orig, orig) end
    W.on_click(b, label, handler, owner)
    return b
end

-- Polls `button` for clicks. `owner` (optional): the screen it belongs to.
-- With an owner the entry is dropped as soon as that screen has been on
-- screen and is not any more, while it is still alive: a removed screen is
-- freed by the next garbage collection, and its buttons must not be polled
-- after that. Without an owner the button's own screen is still recorded, so
-- W.forget(screen) finds it.
function W.on_click(button, label, fn, owner)
    local explicit = ue.valid(owner) and owner or nil
    local o = explicit or owner_of(button)
    W.buttons[#W.buttons + 1] = {
        w = button, fn = fn, label = label or "?", was = false,
        owner = explicit, since = os.clock(),
        owner_key = ue.valid(o) and ue.name(o) or nil,
        owner_addr = addr(o),
    }
end

-- Are buttons of `owner` being polled?
function W.has(owner)
    local key = ue.valid(owner) and ue.name(owner) or nil
    if not key then return false end
    for _, b in ipairs(W.buttons) do
        if not b.dead and b.owner_key == key then return true end
    end
    return false
end

-- Stops polling every button of `owner` (a screen that is being closed or
-- removed). The entries themselves are not touched.
function W.forget(owner)
    local key = ue.valid(owner) and ue.name(owner) or nil
    local a = addr(owner)
    if not key and not a then return 0 end
    local keep, n = {}, 0
    for _, b in ipairs(W.buttons) do
        local match
        if key then match = b.owner_key == key else match = b.owner_addr ~= nil and b.owner_addr == a end
        if match then
            b.dead = true
            n = n + 1
        else
            keep[#keep + 1] = b
        end
    end
    W.buttons = keep
    return n
end

-- Level change: every polled button belongs to the old world.
function W.forget_all()
    for _, b in ipairs(W.buttons) do b.dead = true end
    W.buttons = {}
end

-- A screen registered with buttons but never shown for this long is dropped.
local OWNER_GRACE_S = 30

local function owner_on_screen(o)
    if not ue.valid(o) then return false end
    local okv, inv = pcall(function() return o:IsInViewport() end)
    if okv and inv == true then return true end
    local okp, parent = pcall(function() return o:GetParent() end)
    return (okp and ue.valid(parent)) or false
end

-- Every frame: a click = press released while the cursor is still over it.
function W.frame_tick()
    if #W.buttons == 0 then return end
    local on_screen = {}   -- [owner key] = this frame's answer
    -- a click handler may call W.forget: entries it drops are marked dead
    for _, b in ipairs(W.buttons) do
        if not b.dead and b.owner then
            local k = b.owner_key or tostring(b.owner_addr)
            local on = on_screen[k]
            if on == nil then
                on = owner_on_screen(b.owner)
                on_screen[k] = on
            end
            if on then
                b.shown = true
            elseif b.shown or not ue.valid(b.owner) or os.clock() - (b.since or 0) > OWNER_GRACE_S then
                -- left the screen (still alive now), gone, or never shown
                b.dead = true
            end
        end
        if not b.dead and not ue.valid(b.w) then b.dead = true end
        if not b.dead then
            local ok, pressed = pcall(function() return b.w:IsPressed() end)
            pressed = ok and pressed == true
            if b.was and not pressed then
                local okh, hovered = pcall(function() return b.w:IsHovered() end)
                if okh and hovered then
                    log.info("ui: '%s' clicked", log.ascii(b.label))
                    local okc, err = pcall(b.fn, b.w)
                    if not okc then log.err("ui: button '%s': %s", log.ascii(b.label), tostring(err)) end
                end
            end
            b.was = pressed
        end
    end
    local keep = {}
    for _, b in ipairs(W.buttons) do
        if not b.dead then keep[#keep + 1] = b end
    end
    W.buttons = keep
end

-- The game window that is open (inventory / trade / loot window, journal,
-- map, pause menu...) when sdc_uiinput is loaded and on (config
-- game_ui_input), else nil.
function W.game_window_open()
    local ui = package.loaded["sdc_uiinput"]
    if type(ui) ~= "table" or type(ui.game_ui_open) ~= "function" then return nil end
    if type(ui.enabled) == "function" and not ui.enabled() then return nil end
    local ok, what = pcall(ui.game_ui_open)
    if ok and what then return what end
    return nil
end

-- Back to game controls after a menu / death screen. `why` names the reason
-- for the log. Never over an open game window: the window keeps the UI
-- input the game gave it (the mouse would turn the camera and the cursor
-- would vanish over it). Returns true when the input was switched.
function W.game_input(pc, why)
    pc = pc or ue.local_pc()
    if not pc then return false end
    local open = W.game_window_open()
    if open then
        log.info("ui: game controls NOT forced (%s): %s is open and keeps its UI input", why or "?", open)
        return false
    end
    local wbl = ue.widget_lib()
    if wbl then pcall(function() wbl:SetInputMode_GameOnly(pc, false) end) end
    pcall(function() pc.bShowMouseCursor = false end)
    log.info("ui: game controls forced on %s (%s): game input, cursor off", ue.short(pc), why or "?")
    return true
end

return W
