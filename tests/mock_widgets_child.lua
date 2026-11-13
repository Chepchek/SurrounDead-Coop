-- Mock test: sdc_widgets.W.child finds a named child widget of a user widget
-- WITHOUT reading the widget Blueprint's variables by name.
-- Why: UE4SS 3.0.1 (4fb9b615) keeps every by-name property lookup forever,
-- keyed by (class address, name). A level change can unload a widget
-- Blueprint class and load it again at the same address; GetPropertyValue /
-- obj.Name then use the freed property of the old class (client crash
-- 2026-11-13 in UE4SS: MenuWidget_C's "Load" after a few failed joins).
--   A  GetWidgetFromName (a UFunction) answers: its widget, nothing else read
--   B  it answers nothing (an invalid object): the tree walk from
--      WidgetTree.RootWidget (C++ properties) with GetChildrenCount /
--      GetChildAt finds it; logged once per name
--   C  it throws: the same walk
--   D  the name is nowhere: nil, still no by-name read
--   E  bad input (nil / invalid widget / empty name): nil, nothing called
-- The fake user widget's by-name reads (GetPropertyValue, SetPropertyValue,
-- any field other than its methods and WidgetTree) are recorded and throw,
-- as a stale cache entry would read freed memory.
-- usage: lua mock_widgets_child.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

local LOG = {}
local function logline(kind) return function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    LOG[#LOG + 1] = kind .. (ok and s or tostring(fmt))
end end
local nop = function() end
package.loaded["sdc_log"] = setmetatable({
    info = logline(""), warn = logline("[WARN] "), err = logline("[ERROR] "),
    debug = nop, ascii = function(s) return s end,
}, { __index = function() return nop end })
local function log_count(s)
    local n = 0
    for _, l in ipairs(LOG) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end

function FName(s) return { ToString = function() return s end } end

-- ---------------------------------------------------------------- fake widgets
local next_addr = 4096
local function base_methods(short, cls)
    next_addr = next_addr + 16
    local a = next_addr
    return {
        IsValid = function(self) return rawget(self, "_valid") ~= false end,
        GetFName = function() return { ToString = function() return short end } end,
        GetClass = function() return { GetFName = function() return { ToString = function() return cls end } end } end,
        GetFullName = function() return cls .. " /Engine/Transient." .. short end,
        GetAddress = function() return a end,
    }
end

-- a designer widget; panels have children (GetChildrenCount / GetChildAt)
local function widget(cls, short, children)
    local m = base_methods(short, cls)
    if children then
        m.GetChildrenCount = function() return #children end
        m.GetChildAt = function(_, i) return children[i + 1] end
    end
    return setmetatable({ _short = short }, { __index = m })
end

local READS = {}      -- by-name reads on the user widget
local NATIVE = {}     -- C++ property reads on it (WidgetTree)
local GWFN = {}       -- GetWidgetFromName calls
-- mode: "finds" | "invalid" | "throws"
local function user_widget(root, mode, by_name)
    local m = base_methods("MenuWidget_C_2147482001", "MenuWidget_C")
    m.GetPropertyValue = function(_, n)
        READS[#READS + 1] = "GetPropertyValue(" .. tostring(n) .. ")"
        error("stale FProperty for " .. tostring(n))
    end
    m.SetPropertyValue = function(_, n)
        READS[#READS + 1] = "SetPropertyValue(" .. tostring(n) .. ")"
        error("stale FProperty for " .. tostring(n))
    end
    m.GetWidgetFromName = function(_, fname)
        local n = fname:ToString()
        GWFN[#GWFN + 1] = n
        if mode == "throws" then error("GetWidgetFromName failed") end
        if mode == "finds" and by_name[n] then return by_name[n] end
        local inv = widget("Widget", "None")
        rawset(inv, "_valid", false)
        return inv
    end
    local tree = setmetatable({}, { __index = function(_, k)
        if k == "RootWidget" then return root end
        if k == "IsValid" then return function() return true end end
        return nil
    end })
    return setmetatable({}, { __index = function(_, k)
        local f = m[k]
        if f ~= nil then return f end
        if k == "WidgetTree" then NATIVE[#NATIVE + 1] = k; return tree end
        READS[#READS + 1] = "." .. tostring(k)
        error("stale FProperty for " .. tostring(k))
    end })
end

-- MenuWidget_C: CanvasPanel_0 > MenuOverlay > MainMenu > Buttons > Load > LoadText
local function menu_tree()
    local text = widget("TextBlock", "LoadText")
    local load = widget("Button", "Load", { text })
    local quit = widget("Button", "Quit", { widget("TextBlock", "QuitText") })
    local col = widget("VerticalBox", "Buttons", { widget("Spacer", "Spacer_5"), load, quit })
    local main = widget("CanvasPanel", "MainMenu", { col })
    local overlay = widget("Overlay", "MenuOverlay", { main })
    local root = widget("CanvasPanel", "CanvasPanel_0", { overlay })
    return root, { Load = load, Quit = quit, MenuOverlay = overlay, Buttons = col, LoadText = text }
end

local function reset() READS, NATIVE, GWFN = {}, {}, {} end

local W = require("sdc_widgets")
check(type(W.child) == "function", "W.child exists")

print("A: GetWidgetFromName answers")
do
    reset()
    local root, w = menu_tree()
    local uw = user_widget(root, "finds", w)
    local got = W.child(uw, "Load")
    check(rawequal(got, w.Load), "the Load button")
    check(#GWFN == 1 and GWFN[1] == "Load", "asked GetWidgetFromName(\"Load\") once")
    check(#READS == 0, "no by-name read of the Blueprint's variables (" .. table.concat(READS, " ") .. ")")
    check(#NATIVE == 0, "no tree walk needed")
end

print("B: GetWidgetFromName finds nothing -> tree walk")
do
    reset()
    local root, w = menu_tree()
    local uw = user_widget(root, "invalid", w)
    local got = W.child(uw, "Load")
    check(rawequal(got, w.Load), "the Load button, found in the tree")
    check(#GWFN == 1, "GetWidgetFromName asked first")
    check(#READS == 0, "no by-name read of the Blueprint's variables (" .. table.concat(READS, " ") .. ")")
    check(#NATIVE == 1, "the walk starts at the C++ WidgetTree property")
    check(log_count("ui: Load found by a walk of MenuWidget_C's widget tree") == 1, "the walk is logged")
    check(rawequal(W.child(uw, "Load"), w.Load) and log_count("ui: Load found by a walk") == 1, "logged once per name")
    check(rawequal(W.child(uw, "LoadText"), w.LoadText), "a deeper widget (inside the button)")
    check(rawequal(W.child(uw, "MenuOverlay"), w.MenuOverlay), "MenuOverlay (game 0.8: not found by GetWidgetFromName)")
    check(#READS == 0, "still no by-name read")
end

print("C: GetWidgetFromName throws -> tree walk")
do
    reset()
    local root, w = menu_tree()
    local uw = user_widget(root, "throws", w)
    check(rawequal(W.child(uw, "Quit"), w.Quit), "the Quit button, found in the tree")
    check(#READS == 0, "no by-name read (" .. table.concat(READS, " ") .. ")")
end

print("D: a name that is nowhere")
do
    reset()
    local root, w = menu_tree()
    check(W.child(user_widget(root, "finds", w), "Settings") == nil, "nil (GetWidgetFromName route)")
    check(W.child(user_widget(root, "invalid", w), "Settings") == nil, "nil (tree walk)")
    check(#READS == 0, "no by-name read (" .. table.concat(READS, " ") .. ")")
    -- a user widget whose tree has no root yet
    local uw = user_widget(nil, "invalid", w)
    check(W.child(uw, "Load") == nil, "no root widget yet: nil")
end

print("E: bad input")
do
    reset()
    local root, w = menu_tree()
    check(W.child(nil, "Load") == nil, "nil widget: nil")
    local uw = user_widget(root, "finds", w)
    check(W.child(uw, "") == nil and W.child(uw, nil) == nil, "empty / no name: nil")
    local dead = widget("MenuWidget_C", "MenuWidget_C_0")
    rawset(dead, "_valid", false)
    check(W.child(dead, "Load") == nil, "invalid (freed) widget: nil")
    check(#GWFN == 0 and #READS == 0, "nothing asked of them")
end

print(string.format("widgets child: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
