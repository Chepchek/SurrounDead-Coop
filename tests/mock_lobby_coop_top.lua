-- Mock test: the main menu's "Кооператив" button above the game's buttons
-- (sdc_lobby simple mode, coop_button_on_top) and its fallbacks.
--   * top: a NEW child of the MainMenu canvas, TOP_GAP px above the Buttons
--     column, as wide as it and one row high, anchored like it; the game's
--     widgets and slots are only read (no write, no remove, no re-add, no
--     slot layout copied); amber label; the click opens the co-op panel;
--     lobby_top.marker exists while it is placed and painted, then is gone
--   * fallback to the old clone at the bottom (behind a spacer of ours, amber)
--     when the column is stretched, its parent is not a canvas, the new slot
--     does not take its layout (our button is taken out again), or a
--     lobby_top.marker was left by an earlier start (kept: sticky)
--   * the pause menu keeps its plain clone at the end of the list
-- usage: lua mock_lobby_coop_top.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/lobby_coop_top"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '" 2>nul')

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local function near(a, b, eps) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 0.01) end
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end

local T = 100.0
os.clock = function() return T end

-- ---------------------------------------------------------------- stubs
local LOG = {}
local function logline(kind) return function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    LOG[#LOG + 1] = kind .. (ok and s or tostring(fmt))
end end
local nop = function() end
package.loaded["sdc_log"] = setmetatable({
    info = logline(""), warn = logline("[WARN] "), err = logline("[ERROR] "),
    err_throttled = function(_, fmt, ...) logline("[ERROR] ")(fmt, ...) end,
    debug = nop, ascii = function(s) return s end,
}, { __index = function() return nop end })
package.loaded["sdc_config"] = { get = function() return nil end, set = nop, save = nop }
package.loaded["sdc_session"] = {
    state = { role = "solo" }, world_reset_hooks = {},
    status = function() return { role = "solo", title = "", lines = {} } end,
    host_on_next_load = nop, join = nop, disconnect = nop,
}
package.loaded["sdc_i18n"] = { coop_label = function() return "Кооператив" end }
local UI_OPEN = {}
package.loaded["sdc_ui"] = { open = false, set_open = function(v) UI_OPEN[#UI_OPEN + 1] = v end }

local function log_has(s)
    for _, l in ipairs(LOG) do if l:find(s, 1, true) then return l end end
    return nil
end

-- ---------------------------------------------------------------- fake UObjects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return rawget(t, "_p")[k]
end
Obj.__tostring = function(t) return "UObject: " .. rawget(t, "_short") end

local next_addr = 4096
local by_class = {}
local function obj(cls, short, outer)
    next_addr = next_addr + 16
    local o = setmetatable({ _cls = cls, _short = short, _p = {}, _m = {}, _addr = next_addr,
        _valid = true, _outer = outer }, Obj)
    by_class[cls] = by_class[cls] or {}
    table.insert(by_class[cls], o)
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Engine/Transient." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
-- _bp_trap (section H): an object of a Blueprint class that a level change can
-- reload; UE4SS 3.0.1 may then read a freed property for any by-name access,
-- so every GetPropertyValue / SetPropertyValue on it is recorded (and gives garbage)
local BP_READS = {}
function Obj:GetPropertyValue(n)
    if self._bp_trap then BP_READS[#BP_READS + 1] = self._cls .. "." .. tostring(n); return { stale = true } end
    return self._p[n]
end
function Obj:SetPropertyValue(n, v)
    if self._bp_trap then BP_READS[#BP_READS + 1] = self._cls .. "." .. tostring(n) .. "="; return end
    self._p[n] = v
end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return self._outer end

local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end

-- counters: what was done to the GAME's widgets and slots
local C = {}
local function reset_counters()
    C.game_writes, C.game_removed, C.layout_copies, C.game_shift, C.game_add = 0, 0, 0, 0, 0
    C.writes = {}
end
reset_counters()
local BROKEN_SETPOS = false

local function setter(field)
    return function(self, v)
        if self._game then
            C.game_writes = C.game_writes + 1
            C.writes[#C.writes + 1] = self._short .. ".Set" .. field
        end
        if field == "Position" and BROKEN_SETPOS and not self._game then return end
        self._p[field] = copy(v)
    end
end

local SLOT_SETTERS = {
    VerticalBoxSlot = { "Padding", "HorizontalAlignment", "VerticalAlignment", "Size" },
    HorizontalBoxSlot = { "Padding", "HorizontalAlignment", "VerticalAlignment", "Size" },
    ButtonSlot = { "Padding", "HorizontalAlignment", "VerticalAlignment" },
    OverlaySlot = { "Padding", "HorizontalAlignment", "VerticalAlignment" },
    SizeBoxSlot = { "Padding", "HorizontalAlignment", "VerticalAlignment" },
    CanvasPanelSlot = { "Anchors", "Alignment", "Position", "Size", "AutoSize", "ZOrder", "Offsets" },
}
local SLOT_OF = {
    CanvasPanel = "CanvasPanelSlot", VerticalBox = "VerticalBoxSlot", HorizontalBox = "HorizontalBoxSlot",
    Overlay = "OverlaySlot", Button = "ButtonSlot", SizeBox = "SizeBoxSlot",
}

local function new_slot(cls, parent, content)
    local s = obj(cls, cls .. "_" .. next_addr, parent)
    for _, f in ipairs(SLOT_SETTERS[cls] or {}) do s._m["Set" .. f] = setter(f) end
    if cls == "CanvasPanelSlot" then
        s._p.Anchors = { Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }
        s._p.Position, s._p.Size, s._p.Alignment = { X = 0, Y = 0 }, { X = 100, Y = 30 }, { X = 0, Y = 0 }
        s._p.ZOrder, s._p.AutoSize = 0, false
        s._m.GetAnchors = function(self) return copy(self._p.Anchors) end
        s._m.GetPosition = function(self) return copy(self._p.Position) end
        s._m.GetSize = function(self) return copy(self._p.Size) end
        s._m.GetAlignment = function(self) return copy(self._p.Alignment) end
        s._m.GetZOrder = function(self) return self._p.ZOrder end
        s._m.SetLayout = function(self, v) C.layout_copies = C.layout_copies + 1; self._p.LayoutData = v end
    else
        s._p.Padding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
        s._p.HorizontalAlignment, s._p.VerticalAlignment = 0, 0
        if cls == "VerticalBoxSlot" or cls == "HorizontalBoxSlot" then s._p.Size = { Value = 1, SizeRule = 0 } end
    end
    s._p.Content = content
    return s
end

-- widgets: _children = the UMG slot array order, _slate = what is on screen
local function widget(cls, short, outer)
    local w = obj(cls, short, outer)
    w._p.Visibility = 0
    if SLOT_OF[cls] then w._children, w._slate = {}, {} end
    return w
end
local function index_of(list, x)
    for i, v in ipairs(list) do if rawequal(v, x) then return i end end
    return nil
end
function Obj:GetParent() return self._parent end
function Obj:GetVisibility() return self._p.Visibility end
function Obj:SetVisibility(v)
    if self._game then C.game_writes = C.game_writes + 1; C.writes[#C.writes + 1] = self._short .. ".SetVisibility" end
    self._p.Visibility = v
end
function Obj:IsInViewport() return self._in_viewport == true end
function Obj:GetChildrenCount() return #self._children end
function Obj:GetChildAt(i) return self._children[i + 1] end
function Obj:GetChildIndex(w) local i = index_of(self._children, w); return i and (i - 1) or -1 end
function Obj:RemoveChild(w)
    local i = index_of(self._children, w)
    if not i then return false end
    if w._game then C.game_removed = C.game_removed + 1 end
    table.remove(self._children, i)
    local j = index_of(self._slate, w)
    if j then table.remove(self._slate, j) end
    w._parent, w._p.Slot = nil, nil
    return true
end
function Obj:RemoveFromParent() if self._parent then self._parent:RemoveChild(self) end end
function Obj:AddChild(w)
    if self._game and not w._game then C.game_add = C.game_add + 1 end
    if w._parent then w._parent:RemoveChild(w) end
    local s = new_slot(SLOT_OF[self._cls], self, w)
    self._children[#self._children + 1] = w
    self._slate[#self._slate + 1] = w      -- a live panel appends to its Slate box
    w._parent, w._p.Slot = self, s
    return s
end
function Obj:AddChildToCanvas(w)
    if self._cls ~= "CanvasPanel" then error("AddChildToCanvas on " .. self._cls) end
    return self:AddChild(w)
end
-- UPanelWidget::ShiftChild: the slot array only, Slate is not rebuilt
function Obj:ShiftChild(i, w)
    if self._game then C.game_shift = C.game_shift + 1 end
    local cur = index_of(self._children, w)
    if not cur then return end
    table.remove(self._children, cur)
    table.insert(self._children, math.max(1, math.min(i + 1, #self._children + 1)), w)
end
local function find_tree(w, name)
    if w._short == name then return w end
    for _, c in ipairs(w._children or {}) do
        local f = find_tree(c, name)
        if f then return f end
    end
    return nil
end
-- widget-only setters (style, text) are plain records
for _, f in ipairs({ "Style", "ColorAndOpacity", "BackgroundColor", "Font", "ShadowOffset",
                     "ShadowColorAndOpacity", "Justification", "RenderTransform", "Text", "Size" }) do
    Obj["Set" .. f] = function(self, v)
        if self._game then C.game_writes = C.game_writes + 1; C.writes[#C.writes + 1] = self._short .. ".Set" .. f end
        self._p[f == "Style" and "WidgetStyle" or f] = copy(v)
    end
end
function Obj:IsPressed() return self._pressed == true end
function Obj:IsHovered() return self._hovered == true end

-- ---------------------------------------------------------------- UE4SS globals
function FName(s) return { _fname = s, ToString = function() return s end } end
function FText(s) return s end
local classes = {}
function StaticFindObject(path)
    local short = path:match("^/Script/UMG%.(%w+)$")
    if short and SLOT_OF[short] ~= nil or short == "TextBlock" or short == "Spacer" or short == "EditableTextBox"
        or short == "BackgroundBlur" or short == "ScaleBox" then
        classes[short] = classes[short] or obj("Class", short)
        classes[short]._umg = short
        return classes[short]
    end
    return nil
end
-- the game's WidgetBlueprintLibrary: GetAllWidgetsOfClass lists the live
-- widgets of a Blueprint class (top level = in the viewport). Only the pause
-- screen's class is loaded here; the main menu tests use FindAllOf, except
-- section I (the menu only through this function, as in the game). The HUD's
-- PauseMenu variable is not set: sdc_lobby must not read it by name.
local LIVE = {}   -- [class short name] = { widget, ... }
local WBL_ASKED = {}   -- the class objects passed in, in order
local WBL = obj("WidgetBlueprintLibrary", "Default__WidgetBlueprintLibrary")
WBL._m.GetAllWidgetsOfClass = function(_, _, arr, cls, top)
    WBL_ASKED[#WBL_ASKED + 1] = cls
    for _, w in ipairs(LIVE[cls._short] or {}) do
        if w._valid and (not top or w._in_viewport) then arr[#arr + 1] = w end
    end
end
local BP_CLASSES = { ["/Game/UI/Menus/PauseScreen/PauseScreen.PauseScreen_C"] = obj("Class", "PauseScreen_C"),
    ["/Game/UI/Widgets/Notification/NotificationParentWidget.NotificationParentWidget_C"] =
        obj("Class", "NotificationParentWidget_C") }
-- the game's notification function (sdc_lobby game_notification)
local NOTES = {}
local GFL = obj("GameFunctionLibrary_C", "Default__GameFunctionLibrary_C")
GFL._m.CreateNotificationUI = function(_, text) NOTES[#NOTES + 1] = text end
BP_CLASSES["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"] = GFL
local find_umg_class = StaticFindObject
function StaticFindObject(path)
    if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return WBL end
    return BP_CLASSES[path] or find_umg_class(path)
end
local constructed = 0
function StaticConstructObject(cls, outer, fname)
    constructed = constructed + 1
    local name = fname and fname:ToString() or (cls._umg .. "_mod" .. constructed)
    return widget(cls._umg, name, outer)
end
local FIND = {}
function FindAllOf(cls) return FIND[cls] or {} end
function FindFirstOf(cls) local l = FIND[cls]; return l and l[1] or nil end
function NotifyOnNewObject() end
function RegisterLoadMapPreHook() end
function RegisterHook() return 1, 2 end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(_, f) delayed[#delayed + 1] = f; return 1 end
function ExecuteWithDelay(_, f) delayed[#delayed + 1] = f end
function LoopInGameThreadWithDelay() return 1 end

-- ---------------------------------------------------------------- the game's menus
local WHITE = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 }
local STYLE = { Normal = { TintColor = { SpecifiedColor = { R = 0, G = 0, B = 0, A = 0.25 } } } }

local function game_button(parent, name, tree, text_in_box)
    local b = widget("Button", name, tree)
    b._p.WidgetStyle, b._p.ColorAndOpacity = copy(STYLE), { R = 1, G = 1, B = 1, A = 1 }
    b._p.BackgroundColor, b._p.IsFocusable = { R = 1, G = 1, B = 1, A = 1 }, false
    local t = widget("TextBlock", name .. "Text", tree)
    t._p.Text, t._p.Font = name, { Size = 18, TypefaceFontName = "Default" }
    t._p.ColorAndOpacity, t._p.ShadowOffset = copy(WHITE), { X = 1, Y = 1 }
    if text_in_box then
        local hb = widget("HorizontalBox", "HorizontalBox_" .. name, tree)
        b:AddChild(hb)
        hb:AddChild(t)
    else
        local s = b:AddChild(t)
        s._p.Padding, s._p.HorizontalAlignment = { Left = 10, Top = 0, Right = 0, Bottom = 0 }, 1
    end
    local s = parent:AddChild(b)
    s._p.Size = { Value = 100, SizeRule = 1 }
    return b
end

local function mark_game(w)
    w._game = true
    if w._p.Slot then w._p.Slot._game = true end
    for _, c in ipairs(w._children or {}) do mark_game(c) end
end

local CW, CH = 1920, 1080
local COLUMN = { Anchors = { Minimum = { X = 0, Y = 1 }, Maximum = { X = 0, Y = 1 } },
                 Position = { X = 0, Y = 0 }, Size = { X = 500, Y = 260 }, Alignment = { X = -0.075, Y = 1.4 }, ZOrder = 3 }

-- MenuWidget_C: CanvasPanel_0 > MenuOverlay > MainMenu (CanvasPanel) > Buttons (VerticalBox)
local function main_menu(opts)
    opts = opts or {}
    local m = widget("MenuWidget_C", "MenuWidget_C_2147482001")
    m._in_viewport = true
    local tree = obj("WidgetTree", "WidgetTree_0", m)
    m._p.WidgetTree = tree
    local root = widget("CanvasPanel", "CanvasPanel_0", tree)
    tree._p.RootWidget = root
    m._m.GetWidgetFromName = function(self, fname) return find_tree(root, fname:ToString()) end
    local overlay = widget("Overlay", "MenuOverlay", tree)
    root:AddChild(overlay)
    local main = widget(opts.parent_class or "CanvasPanel", "MainMenu", tree)
    overlay:AddChild(main)
    local col = widget("VerticalBox", "Buttons", tree)
    local cs = main:AddChild(col)
    if cs._cls == "CanvasPanelSlot" then
        for k, v in pairs(copy(COLUMN)) do cs._p[k] = v end
        if opts.stretched then cs._p.Anchors = { Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } } end
    end
    for _, name in ipairs({ "ContinueGame", "Spacer_4", "NewGame", "Spacer_541", "Load", "Spacer_5", "GameModes",
                            "Spacer_149", "Settings", "Spacer_408", "Quit" }) do
        if name:find("^Spacer") then
            local sp = widget("Spacer", name, tree)
            sp._p.Size = { X = 1, Y = 5 }
            col:AddChild(sp)
        else
            game_button(col, name, tree)
        end
    end
    if opts.no_continue then find_tree(col, "ContinueGame")._p.Visibility = 1 end   -- Collapsed
    for _, icon in ipairs({ "ButtonTrello", "ButtonRoadmap", "ButtonDiscord" }) do
        if main._cls == "CanvasPanel" then main:AddChild(widget("Button", icon, tree)) end
    end
    mark_game(root)
    return m, { root = root, overlay = overlay, main = main, col = col, tree = tree }
end

-- PauseScreen_C: CanvasPanel_0 > PauseWidget (Overlay) > VerticalBox_59
local function pause_screen()
    local p = widget("PauseScreen_C", "PauseScreen_C_2147481000")
    p._in_viewport = true
    local tree = obj("WidgetTree", "WidgetTree_1", p)
    local root = widget("CanvasPanel", "CanvasPanel_0", tree)
    tree._p.RootWidget = root
    p._p.WidgetTree = tree
    p._m.GetWidgetFromName = function(self, fname) return find_tree(root, fname:ToString()) end
    local pw = widget("Overlay", "PauseWidget", tree)
    root:AddChild(pw)
    local list = widget("VerticalBox", "VerticalBox_59", tree)
    pw:AddChild(list)
    for _, name in ipairs({ "Resume", "Settings", "DifficultySettings", "QuickSave", "Save", "Suicide", "MainMenu", "Quit" }) do
        game_button(list, name, tree, true)
    end
    list:AddChild(widget("TextBlock", "TextBlock_146", tree))
    mark_game(root)
    return p, { root = root, list = list }
end

-- ---------------------------------------------------------------- harness
local lobby, ue, W
local IN_MENU = true
local function fresh(dir)
    for _, k in ipairs({ "sdc_lobby", "sdc_widgets", "sdc_ue" }) do package.loaded[k] = nil end
    ue = require("sdc_ue")
    ue.in_main_menu = function() return IN_MENU end
    W = require("sdc_widgets")
    lobby = require("sdc_lobby")
    LOG, UI_OPEN, delayed = {}, {}, {}
    reset_counters()
    lobby.install(dir)
end
-- slow ticks until the menu has been on screen past SETTLE_S and was patched
local function patch_now()
    for _ = 1, 4 do lobby.slow_tick() end
    T = T + 2
    for _ = 1, 4 do lobby.slow_tick() end
end
local function frames(n) for _ = 1, n do lobby.frame_tick(); W.frame_tick() end end

local function rect(slot)
    local a, p, s, al = slot._p.Anchors, slot._p.Position, slot._p.Size, slot._p.Alignment
    return a.Minimum.X * CW + p.X - al.X * s.X, a.Minimum.Y * CH + p.Y - al.Y * s.Y, s.X, s.Y
end
local function ours(list)
    local out = {}
    for _, w in ipairs(list) do if not w._game then out[#out + 1] = w end end
    return out
end
local function names(list)
    local out = {}
    for _, w in ipairs(list) do out[#out + 1] = w._short end
    return table.concat(out, ",")
end
local ACCENT_R = 0.708

local function dir_for(name)
    local d = TMP .. "/" .. name
    os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
    os.remove(d .. "/lobby_top.marker")
    os.remove(d .. "/lobby_build.marker")
    return d
end

-- ================================================================ A: top placement
print("A: above the game's buttons")
do
    local d = dir_for("a")
    fresh(d)
    local m, g = main_menu()
    FIND.MenuWidget_C = { m }
    local col_before, slate_before = names(g.col._children), names(g.col._slate)
    local main_before = #g.main._children
    patch_now()
    local line = log_has("lobby: coop button placed at the top (")
    check(line ~= nil, "log: " .. tostring(line))
    check(log_has("kept at the bottom") == nil, "no 'kept at the bottom' line")
    local added = ours(g.main._children)
    check(#added == 1 and #g.main._children == main_before + 1, "one new child of the MainMenu canvas")
    local b = added[1]
    check(b and b._cls == "Button" and b._short:find("^SDC_CoopTopButton_%d+$") ~= nil, "it is our named Button: " .. tostring(b and b._short))
    check(names(g.col._children) == col_before and names(g.col._slate) == slate_before, "the column is untouched (UMG and Slate order)")
    check(C.game_add == 1 and C.game_shift == 0, "one child added to a game panel (the canvas), nothing shifted")
    check(C.game_writes == 0, "no setter called on any game widget or slot: " .. table.concat(C.writes, " "))
    check(C.game_removed == 0, "no game widget removed")
    check(C.layout_copies == 0, "no canvas layout copied (SetLayout never called)")
    if b then
        local s = b._p.Slot
        check(s._cls == "CanvasPanelSlot", "its slot is a CanvasPanelSlot")
        local cl, ct, cw = rect(g.col._p.Slot)
        local l, t, w, h = rect(s)
        local row = (260 - 25) / 6
        check(near(l, cl) and near(w, cw), string.format("same left edge and width as the column (%.1f %.0f)", l, w))
        check(near(t + h, ct - 20), string.format("bottom edge 20 px above the column's top (%.1f vs %.1f)", t + h, ct))
        check(near(h, row), string.format("one row high (%.2f)", h))
        check(s._p.Anchors.Minimum.Y == 1 and s._p.Anchors.Maximum.X == 0, "anchored like the column (bottom-left)")
        check(s._p.ZOrder == 3 and s._p.AutoSize == false, "ZOrder of the column, no auto size")
        check(b._p.Visibility == 0, "visible after placement")
        check(b._p.IsFocusable == false, "not focusable, like the game's buttons")
        local t1 = W.first_text(b)
        check(t1 and t1._p.Text == "Кооператив", "label from sdc_i18n")
        local i18n_s = package.loaded["sdc_i18n"]
        local old_l = i18n_s.coop_label
        i18n_s.coop_label = function() return "Co-op" end
        lobby.relabel()
        check(t1 and t1._p.Text == "Co-op", "main menu: a language change relabels the top button")
        i18n_s.coop_label = old_l
        lobby.relabel()
        check(t1 and near(t1._p.ColorAndOpacity.SpecifiedColor.R, ACCENT_R), "amber label")
        check(b._p.WidgetStyle and b._p.WidgetStyle.Normal.TintColor.SpecifiedColor.A == 0.25, "the game's button style")
    end
    check(exists(d .. "/lobby_top.marker"), "lobby_top.marker exists right after the placement")
    check(exists(d .. "/lobby_build.marker"), "the build marker covers the first placement's paint frames")
    frames(119)
    check(not exists(d .. "/lobby_build.marker"), "the build marker is gone after its 45 frames")
    check(exists(d .. "/lobby_top.marker"), "marker still there after 119 frames")
    frames(1)
    check(not exists(d .. "/lobby_top.marker"), "marker removed after 120 frames")
    -- click: press, then release while hovered
    if b then
        b._pressed = true; frames(1)
        b._pressed, b._hovered = false, true; frames(1)
        b._hovered = false
    end
    check(#UI_OPEN == 1 and UI_OPEN[1] == true, "click opens the co-op panel")
    for _ = 1, 12 do lobby.slow_tick() end
    check(#ours(g.main._children) == 1 and #ours(g.col._children) == 0, "later ticks add nothing more")
    FIND.MenuWidget_C = nil
end

-- ================================================================ B: Continue hidden
print("B: Continue collapsed (5 buttons)")
do
    fresh(dir_for("b"))
    local m, g = main_menu({ no_continue = true })
    FIND.MenuWidget_C = { m }
    patch_now()
    local b = ours(g.main._children)[1]
    check(b ~= nil and log_has("lobby: coop button placed at the top (") ~= nil, "placed at the top")
    if b then
        local _, _, _, h = rect(b._p.Slot)
        check(near(h, (260 - 25) / 5), string.format("row of the 5 visible buttons (%.1f)", h))
    end
    FIND.MenuWidget_C = nil
end

-- shared checks for the bottom fallback
local function bottom_checks(g, reason)
    local line = log_has("lobby: coop button kept at the bottom: ")
    check(line ~= nil and line:find(reason, 1, true) ~= nil, "log: " .. tostring(line))
    check(log_has("lobby: coop button placed at the top (") == nil, "no 'placed at the top' line")
    check(log_has("lobby: main menu: co-op button added after Load") ~= nil, "the old clone was added")
    if g.main._children then check(#ours(g.main._children) == 0, "nothing of ours left in the column's parent") end
    local slate = g.col._slate
    local n = #slate
    local clone, gap = slate[n], slate[n - 1]
    check(clone and not clone._game and clone._cls == "Button", "on screen: our clone is the last row")
    check(gap and not gap._game and gap._cls == "Spacer" and gap._p.Size.Y == 12, "behind a 12 px spacer of ours")
    check(slate[n - 2] and slate[n - 2]._short == "Quit", "after the game's last button")
    local t = clone and W.first_text(clone)
    check(t and t._p.Text == "Кооператив" and near(t._p.ColorAndOpacity.SpecifiedColor.R, ACCENT_R), "amber label")
    check(C.game_removed == 0 and C.layout_copies == 0, "no game widget removed, no canvas layout copied")
    return clone
end

-- ================================================================ C: stretched column
print("C: the column is stretched -> bottom")
do
    local d = dir_for("c")
    fresh(d)
    local m, g = main_menu({ stretched = true })
    FIND.MenuWidget_C = { m }
    patch_now()
    bottom_checks(g, "the button column is stretched")
    check(not exists(d .. "/lobby_top.marker"), "no top marker written")
    FIND.MenuWidget_C = nil
end

-- ================================================================ D: the slot ignores SetPosition
print("D: the new canvas slot does not take its layout -> taken out, bottom")
do
    local d = dir_for("d")
    fresh(d)
    local m, g = main_menu()
    FIND.MenuWidget_C = { m }
    BROKEN_SETPOS = true
    patch_now()
    BROKEN_SETPOS = false
    bottom_checks(g, "placing it at the top failed: its canvas slot did not take the layout")
    check(not exists(d .. "/lobby_top.marker"), "top marker removed after the failed placement")
    FIND.MenuWidget_C = nil
end

-- ================================================================ E: parent is not a canvas
print("E: the column's parent is an Overlay -> bottom")
do
    fresh(dir_for("e"))
    local m, g = main_menu({ parent_class = "Overlay" })
    FIND.MenuWidget_C = { m }
    patch_now()
    bottom_checks(g, "the button column's parent is not a CanvasPanel (Overlay)")
    FIND.MenuWidget_C = nil
end

-- ================================================================ F: a start crashed while placing at the top
print("F: lobby_top.marker from an earlier start -> bottom, marker kept")
do
    local d = dir_for("f")
    local f = io.open(d .. "/lobby_top.marker", "w"); f:write("x\n"); f:close()
    fresh(d)
    check(log_has("[WARN] lobby: the main menu's co-op button stays at the bottom") ~= nil, "warning at install")
    local m, g = main_menu()
    FIND.MenuWidget_C = { m }
    patch_now()
    bottom_checks(g, "a start ended while it was being placed at the top")
    frames(200)
    check(exists(d .. "/lobby_top.marker"), "the marker stays (the top is off until it is deleted)")
    FIND.MenuWidget_C = nil
    os.remove(d .. "/lobby_top.marker")
end

-- ================================================================ G: pause menu unchanged
print("G: pause menu keeps the plain clone at the end of its list")
do
    fresh(dir_for("g"))
    IN_MENU = false
    local p, g = pause_screen()
    local player = obj("LocalPlayer", "LocalPlayer_0")
    local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_0")
    local hud = obj("HUD_Game_C", "HUD_Game_C_0")
    pc._p.Player = player
    LIVE.PauseScreen_C = { p }   -- found with GetAllWidgetsOfClass, not as the HUD's PauseMenu
    pc._m.GetHUD = function() return hud end
    FIND.PlayerController = { pc }
    lobby.slow_tick()
    local slate = g.list._slate
    local clone = slate[#slate]
    check(clone and not clone._game and clone._cls == "Button", "our clone is the last entry of the list")
    check(#ours(g.list._slate) == 1, "no spacer added to the pause list")
    local t = clone and W.first_text(clone)
    check(t and t._p.Text == "Кооператив" and near(t._p.ColorAndOpacity.SpecifiedColor.R, 1), "label in the game's own colour")
    -- a language change in the panel relabels every co-op button made so far
    local i18n_stub = package.loaded["sdc_i18n"]
    local old_label = i18n_stub.coop_label
    i18n_stub.coop_label = function() return "Co-op" end
    local n = lobby.relabel()
    check(n >= 1 and t._p.Text == "Co-op", "language change: the button says Co-op (" .. tostring(n) .. " relabelled)")
    i18n_stub.coop_label = old_label
    lobby.relabel()
    check(t._p.Text == "Кооператив", "and back")
    check(log_has("lobby: pause menu: co-op button added after Settings") ~= nil, "pause log line")
    check(log_has("kept at the bottom") == nil and log_has("lobby: coop button placed at the top (") == nil, "no top attempt in the pause menu")
    check(#ours(g.root._children) == 0, "nothing added to the pause screen's canvas")
    FIND.PlayerController = nil
    LIVE.PauseScreen_C = nil
    IN_MENU = true
end

-- ================================================================ H: no by-name Blueprint reads
-- UE4SS 3.0.1 keeps by-name property lookups per class address forever; a
-- widget Blueprint reloaded at its old address after a level change gets the
-- freed property (client crash 2026-11-13 reading MenuWidget_C's "Load").
-- The menus, the pause screen and the HUD are trapped: any GetPropertyValue
-- on them is recorded and returns garbage.
print("H: the menus' and the HUD's Blueprint variables are never read by name")
do
    fresh(dir_for("h1"))
    for i = #BP_READS, 1, -1 do BP_READS[i] = nil end
    local m, g = main_menu()
    m._bp_trap = true
    FIND.MenuWidget_C = { m }
    patch_now()
    local b = ours(g.main._children)[1]
    check(b ~= nil and log_has("lobby: coop button placed at the top (") ~= nil,
        "H1: the main menu's Load button is found and the Co-op button is placed")
    check(#BP_READS == 0, "H1: no by-name read of MenuWidget_C's variables (" .. table.concat(BP_READS, " ") .. ")")
    FIND.MenuWidget_C = nil
end
do
    -- GetWidgetFromName finds nothing (game 0.8 did so for MenuOverlay): the tree walk
    fresh(dir_for("h2"))
    for i = #BP_READS, 1, -1 do BP_READS[i] = nil end
    local m, g = main_menu()
    m._bp_trap = true
    local gwfn = 0
    m._m.GetWidgetFromName = function() gwfn = gwfn + 1; return nil end
    FIND.MenuWidget_C = { m }
    patch_now()
    check(#ours(g.main._children) == 1 and log_has("lobby: coop button placed at the top (") ~= nil,
        "H2: no GetWidgetFromName answer: Load found by the tree walk, the Co-op button is placed")
    check(gwfn >= 1, "H2: GetWidgetFromName was asked first (" .. gwfn .. ")")
    check(log_has("ui: Load found by a walk of MenuWidget_C's widget tree") ~= nil, "H2: the walk is logged")
    check(#BP_READS == 0, "H2: no by-name read of MenuWidget_C's variables (" .. table.concat(BP_READS, " ") .. ")")
    FIND.MenuWidget_C = nil
end
do
    fresh(dir_for("h3"))
    for i = #BP_READS, 1, -1 do BP_READS[i] = nil end
    IN_MENU = false
    local p, g = pause_screen()
    p._bp_trap = true
    local player = obj("LocalPlayer", "LocalPlayer_0")
    local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_0")
    local hud = obj("HUD_Game_C", "HUD_Game_C_0")
    hud._p.PauseMenu, hud._bp_trap = p, true
    pc._p.Player = player
    pc._m.GetHUD = function() return hud end
    FIND.PlayerController = { pc }
    LIVE.PauseScreen_C = { p }
    lobby.slow_tick()
    check(#ours(g.list._slate) == 1, "H3: the pause screen (from GetAllWidgetsOfClass) gets its Co-op button")
    check(lobby.pause_menu_shown() == true, "H3: pause_menu_shown while it is on screen")
    p._in_viewport = false
    check(lobby.pause_menu_shown() == false, "H3: not after it left the viewport")
    p._in_viewport = true
    -- notifications: the game's own, while its notification box is on screen
    local fallback = {}
    lobby.toast_sink(function(text) fallback[#fallback + 1] = text end)
    local box = widget("NotificationParentWidget_C", "NotificationParentWidget_C_2147480000")
    box._in_viewport, box._bp_trap = true, true
    LIVE.NotificationParentWidget_C = { box }
    for i = #NOTES, 1, -1 do NOTES[i] = nil end
    lobby.notify("first note", "info", 3)
    lobby.frame_tick()
    check(NOTES[1] == "first note" and #fallback == 0, "H4: notification box on screen: the game's notification")
    box._in_viewport = false
    lobby.notify("second note", "info", 3)
    lobby.frame_tick()
    check(#NOTES == 1 and fallback[1] == "second note", "H4: no notification box: the mod's toast")
    check(#BP_READS == 0, "H3/H4: no by-name read of PauseScreen_C / HUD_Game_C / NotificationParentWidget_C ("
        .. table.concat(BP_READS, " ") .. ")")
    FIND.PlayerController = nil
    LIVE.PauseScreen_C, LIVE.NotificationParentWidget_C = nil, nil
    IN_MENU = true
end

-- ================================================================ I: the game's way to the main menu
-- In the game FindAllOf does not see MenuWidget_C: the menu comes only from
-- WidgetBlueprintLibrary.GetAllWidgetsOfClass. sdc_lobby keeps the class
-- object between calls; after a level change the old class may be unloaded
-- and another object may lie at its address (the stale reference still looks
-- valid). That object must not be handed to the engine as the class again:
-- the class is looked up anew and the new menu still gets its button.
print("I: main menu only from GetAllWidgetsOfClass; its class reloaded after a level change")
do
    local MENU = "/Game/UI/Menus/Menu/MenuWidget.MenuWidget_C"
    fresh(dir_for("i1"))
    for i = #BP_READS, 1, -1 do BP_READS[i] = nil end
    local player = obj("LocalPlayer", "LocalPlayer_0")
    local pc = obj("PlayerController", "PlayerController_0")
    pc._p.Player = player
    FIND.PlayerController = { pc }
    local cls1 = obj("Class", "MenuWidget_C")
    BP_CLASSES[MENU] = cls1
    local m1, g1 = main_menu()
    m1._bp_trap = true
    LIVE.MenuWidget_C = { m1 }   -- FIND.MenuWidget_C stays empty, as in the game
    patch_now()
    check(#ours(g1.main._children) == 1 and log_has("lobby: coop button placed at the top (") ~= nil,
        "I1: the menu from GetAllWidgetsOfClass (FindAllOf sees none) gets the Co-op button")
    check(rawequal(lobby.live_main_menu(), m1), "I1: live_main_menu is that menu")
    check(#BP_READS == 0, "I1: no by-name read of MenuWidget_C's variables (" .. table.concat(BP_READS, " ") .. ")")

    -- level change (back to the menu after a failed join): the menu and its
    -- class are unloaded; a WidgetTree now lies at the old class's address,
    -- and the class is loaded again as a new object
    package.loaded["sdc_session"].world_reset_hooks.lobby("level change")
    m1._valid, m1._in_viewport = false, false
    cls1._short, cls1._cls = "WidgetTree_7", "WidgetTree"
    local cls2 = obj("Class", "MenuWidget_C")
    BP_CLASSES[MENU] = cls2
    local m2, g2 = main_menu()
    m2._bp_trap = true
    LIVE.MenuWidget_C = { m2 }
    for i = #WBL_ASKED, 1, -1 do WBL_ASKED[i] = nil end
    LOG = {}
    patch_now()
    local stale = 0
    for _, c in ipairs(WBL_ASKED) do if rawequal(c, cls1) then stale = stale + 1 end end
    check(#WBL_ASKED > 0 and stale == 0,
        "I2: the old class object is not passed to GetAllWidgetsOfClass again (" .. stale .. " of " .. #WBL_ASKED .. ")")
    check(rawequal(lobby.live_main_menu(), m2), "I2: live_main_menu finds the new menu through the class looked up anew")
    check(#ours(g2.main._children) == 1 and log_has("lobby: coop button placed at the top (") ~= nil,
        "I2: the new menu gets its Co-op button")
    check(#BP_READS == 0, "I2: no by-name read of MenuWidget_C's variables (" .. table.concat(BP_READS, " ") .. ")")
    FIND.PlayerController = nil
    LIVE.MenuWidget_C, BP_CLASSES[MENU] = nil, nil
end

print(string.format("lobby coop top: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
