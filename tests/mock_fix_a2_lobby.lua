-- Mock test (critic fixes 2026-11-13, group A2): sdc_lobby after the page
-- mode was removed (simple mode only).
--   A1  once the main menu has its button, the 1 s main-menu scan and the
--       "main menu not patched yet" diagnosis stop while that menu is up;
--       they start again when it leaves the screen
--   A8  lobby_build.marker covers only the FIRST button of a kind per
--       session (written once, kept for its paint frames), not every pause
--   A10 the names of patched menus are dropped on a level change (not on a
--       new controller in the same world)
--   B4  the pause clone is appended: no ShiftChild on the game's list
--   C1  no page-mode API left (status_line, TEXT)
-- The harness (fake UMG, the game's menus) is mock_lobby_coop_top.lua's.
-- usage: lua mock_fix_a2_lobby.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local TMP = HERE .. "/_tmp/fix_a2_lobby"
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
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
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
-- the game's WidgetBlueprintLibrary (see mock_lobby_coop_top.lua): the pause
-- screen is found with GetAllWidgetsOfClass, not as the HUD's PauseMenu
local LIVE = {}   -- [class short name] = { widget, ... }
local WBL = obj("WidgetBlueprintLibrary", "Default__WidgetBlueprintLibrary")
WBL._m.GetAllWidgetsOfClass = function(_, _, arr, cls, top)
    for _, w in ipairs(LIVE[cls._short] or {}) do
        if w._valid and (not top or w._in_viewport) then arr[#arr + 1] = w end
    end
end
local BP_CLASSES = { ["/Game/UI/Menus/PauseScreen/PauseScreen.PauseScreen_C"] = obj("Class", "PauseScreen_C") }
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
local FINDS = {}
function FindAllOf(cls) FINDS[cls] = (FINDS[cls] or 0) + 1; return FIND[cls] or {} end
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


local function count_log(s)
    local n = 0
    for _, l in ipairs(LOG) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end

-- ================================================================ C1
print("C1: only the simple mode is left")
do
    fresh(dir_for("c1"))
    check(lobby.status_line == nil and lobby.TEXT == nil, "no page-mode API (status_line, TEXT)")
    check(type(lobby.live_main_menu) == "function" and type(lobby.pause_menu_shown) == "function"
        and type(lobby.toast_sink) == "function" and type(lobby.notify) == "function", "the simple mode's API is there")
    check(W.insert_after == nil and type(W.append) == "function", "sdc_widgets: W.append, no W.insert_after (ShiftChild)")
end

-- ================================================================ A1
print("A1: no main-menu scan / diagnosis while the patched menu is up")
do
    local d = dir_for("a1")
    fresh(d)
    local m, g = main_menu()
    FIND.MenuWidget_C = { m }
    FINDS = {}
    patch_now()
    check(log_has("lobby: coop button placed at the top (") ~= nil, "the main menu got its button")
    local scans = FINDS.MenuWidget_C or 0
    check(scans >= 1, "it was found by the scan (" .. scans .. ")")
    LOG = {}
    for _ = 1, 80 do lobby.slow_tick() end
    check((FINDS.MenuWidget_C or 0) == scans, "80 more ticks (20 s): no FindAllOf(MenuWidget_C) (" .. tostring(FINDS.MenuWidget_C) .. ")")
    check(count_log("main menu not patched yet") == 0 and count_log("GetAllWidgetsOfClass") == 0, "no diagnosis lines")
    check(#ours(g.main._children) == 1, "still one button")
    -- the menu leaves the screen (still in the menu map, no character): the scan comes back
    m._in_viewport = false
    for _ = 1, 8 do lobby.slow_tick() end
    check((FINDS.MenuWidget_C or 0) > scans, "menu gone from the screen: the scan runs again")
    -- it comes back (the same widget): no second button
    m._in_viewport = true
    T = T + 2
    for _ = 1, 8 do lobby.slow_tick() end
    check(#ours(g.main._children) == 1, "the same menu again: no second button")
    local s2 = FINDS.MenuWidget_C
    for _ = 1, 20 do lobby.slow_tick() end
    check(FINDS.MenuWidget_C == s2, "and the scan stops again")
    FIND.MenuWidget_C = nil
end

-- ================================================================ A8 / A10 / B4
print("A8/A10/B4: pause menus")
do
    local d = dir_for("a8")
    fresh(d)
    IN_MENU = false
    local player = obj("LocalPlayer", "LocalPlayer_0")
    local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_0")
    local hud = obj("HUD_Game_C", "HUD_Game_C_0")
    pc._p.Player = player
    pc._m.GetHUD = function() return hud end
    FIND.PlayerController = { pc }

    -- the first pause of the session: the marker covers its paint frames
    local p1, g1 = pause_screen()
    LIVE.PauseScreen_C = { p1 }
    lobby.slow_tick()
    check(#ours(g1.list._slate) == 1, "first pause: one co-op button")
    check(C.game_shift == 0, "B4: no ShiftChild on the game's list")
    check(exists(d .. "/lobby_build.marker"), "A8: first pause: lobby_build.marker while it is painted")
    frames(44)
    check(exists(d .. "/lobby_build.marker"), "still there after 44 frames")
    frames(1)
    check(not exists(d .. "/lobby_build.marker"), "gone after 45 frames")

    -- the next pause (a new PauseScreen): no marker file at all
    local p2, g2 = pause_screen()
    p2._short = "PauseScreen_C_2147481001"
    LIVE.PauseScreen_C = { p2 }
    lobby.slow_tick()
    check(#ours(g2.list._slate) == 1, "second pause: its own co-op button")
    check(not exists(d .. "/lobby_build.marker"), "A8: second pause: no marker written")
    for _ = 1, 8 do lobby.slow_tick() end
    check(#ours(g2.list._slate) == 1, "later ticks: no second button in the same pause menu")

    -- A10: a new controller in the same world keeps the names (its menu is still up)
    package.loaded["sdc_session"].world_reset_hooks.lobby("new controller")
    lobby.slow_tick()
    check(#ours(g2.list._slate) == 1, "A10: new controller: the pause menu keeps its one button")
    -- a level change drops them: a menu with that name would be a new one
    package.loaded["sdc_session"].world_reset_hooks.lobby("loadmap")
    lobby.slow_tick()
    check(#ours(g2.list._slate) == 2, "A10: level change: the names are dropped (a same-named menu is patched again)")
    FIND.PlayerController = nil
    IN_MENU = true
end

-- ================================================================ A8: crash markers at the next start
print("A8: a start that ended during the first placement")
do
    local d = dir_for("a8b")
    local f = io.open(d .. "/lobby_build.marker", "w"); f:write("0\n"); f:close()
    fresh(d)
    check(log_has("[WARN] lobby: the previous start ended while a co-op button was being placed (1/2)") ~= nil,
        "one earlier crash: a warning, the lobby stays on")
    local m = main_menu()
    FIND.MenuWidget_C = { m }
    patch_now()
    check(exists(d .. "/lobby_build.marker"), "the marker of this start holds the earlier hit")
    local fh = io.open(d .. "/lobby_build.marker", "r"); local line = fh and fh:read("*l"); if fh then fh:close() end
    check(line == "1", "marker content: 1 earlier hit (" .. tostring(line) .. ")")
    frames(130)
    check(not exists(d .. "/lobby_build.marker"), "painted fine: the chain ends")
    FIND.MenuWidget_C = nil
    -- two in a row: off
    f = io.open(d .. "/lobby_build.marker", "w"); f:write("1\n"); f:close()
    fresh(d)
    check(lobby.disabled == true and log_has("[ERROR] lobby: 2 starts in a row ended") ~= nil, "two in a row: the lobby is off")
end

print(string.format("fix a2 lobby: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
