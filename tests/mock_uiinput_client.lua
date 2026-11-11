-- Mock harness for sdc_uiinput (a client's game windows keep the game's UI
-- input), sdc_widgets.game_input (never forced over an open game window) and
-- sdc_players.close_menu_widgets (stray main-menu widgets only).
-- usage: lua mock_uiinput_client.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
local registry = {}          -- class -> list
local by_path = {}           -- path -> object

local function new_obj(cls, short, props, methods)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }
    setmetatable(o, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    local p = rawget(t, "_p")[k]
    if p ~= nil then return p end
    return nil
end
-- `pc.bShowMouseCursor = x` from Lua writes the property
Obj.__newindex = function(t, k, v) rawget(t, "_p")[k] = v end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:GetOwner() return self._p.__owner end
function Obj:IsInViewport() return self._p.__inv == true end
function Obj:RemoveFromParent() self._p.__inv = false; self._p.__parent = nil end
function Obj:GetParent() return self._p.__parent end
function Obj:IsVisible() return self._p.__vis ~= false end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
local registered = {}
function RegisterHook(path, pre, post) hooks[path] = { pre = pre, post = post }; registered[#registered + 1] = path; return 1, 2 end
function FindAllOf(cls) return registry[cls] or {} end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path) return by_path[path] end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(ms, f) delayed[#delayed + 1] = f; return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay(ms, f) delayed[#delayed + 1] = f end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end
local function run_delayed() local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end

-- every Blueprint function path "exists" once asked for (classes loaded)
local bp_loaded = true
setmetatable(by_path, { __index = function(_, k)
    if bp_loaded and k:find(":") then return new_obj("Function", k) end
    return nil
end })

local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function logged(pat, from)
    for i = from or 1, #lines do if lines[i]:find(pat) then return lines[i] end end
    return nil
end
local function mark() return #lines + 1 end

local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end

-- ------------------------------------------------------------ the world
local GAMEONLY = "/Script/UMG.WidgetBlueprintLibrary:SetInputMode_GameOnly"
local DLG_EXIT = "/Script/Narrative.NarrativeComponent:ClientExitDialogue"
local TOGGLE = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:ToggleInventory"
local DBLCLICK = "/Game/JigSInventory/Jigsaw/Widgets/JSI_Slot.JSI_Slot_C:On_MouseDoubleClick"
local LOOTBOX = "/Game/JigSInventory/Jigsaw/Widgets/JContextMenu/JigContextMenuComp.JigContextMenuComp_C:ContextOpenLootBox"

local lp = new_obj("LocalPlayer", "LocalPlayer_0", {}, {})
local pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_1", { Player = lp, bShowMouseCursor = false }, {})
pc._m.IsLocalController = function() return true end
registry["PlayerController"] = { pc }
lp._p.PlayerController = pc
local other_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_9", {}, {})
registry["BP_PlayerController_C"] = nil
local gi = new_obj("SD_GameInstance_C", "SD_GameInstance_C_0", {
    LocalPlayers = { ForEach = function(_, fn) fn(1, param(lp)) end },
}, {})

local pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_1", { Controller = pc }, {})
pc._p.Pawn = pawn
local comp = new_obj("BP_JigComponent_C", "BP_JigMultiplayer", { __owner = pawn }, {})
local window = new_obj("W_Inventory_C", "W_Inventory_C_1", {}, {})
comp._p.InventoryWidgetRef = window
pawn._p.BP_JigMultiplayer = comp
local mm = new_obj("BPC_MinimapSystem_C", "MinimapSystemComponent", { MapToggled = false }, {})
pawn._p.MinimapSystemComponent = mm

-- the other player's copy on this machine
local other = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2", {}, {})
local other_comp = new_obj("BP_JigComponent_C", "BP_JigMultiplayer", { __owner = other }, {})
local other_window = new_obj("W_Inventory_C", "W_Inventory_C_2", {}, {})
other_comp._p.InventoryWidgetRef = other_window

-- engine libraries
local misroute = false
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {})
gps._m.GetPlayerController = function(_, wc, i) return misroute and other_pc or pc end
rawset(by_path, "/Script/Engine.Default__GameplayStatics", gps)
local wbl = new_obj("WidgetBlueprintLibrary", "Default__WidgetBlueprintLibrary", {}, {})
local calls = { gameui = 0, gameonly = 0 }
wbl._m.SetInputMode_GameAndUIEx = function(_, p, w, lock, hide, flush)
    calls.gameui = calls.gameui + 1
    p._p.__mode, p._p.__focus, p._p.__lock = "gameui", w, lock
end
wbl._m.SetInputMode_GameOnly = function(self, p, flush)
    local h = hooks[GAMEONLY]   -- the engine runs the native pre-hook first
    if h and h.pre then h.pre(param(self), param(p), param(flush)) end
    calls.gameonly = calls.gameonly + 1
    p._p.__mode, p._p.__focus = "game", nil
end
rawset(by_path, "/Script/UMG.Default__WidgetBlueprintLibrary", wbl)

-- What BP_JigComponent.ToggleInventory does (@99-262 / @737-913) on this
-- machine. reach = its GetPlayerController(self, 0) is this player's.
local function game_toggle(c, reach)
    local w = c._p.InventoryWidgetRef
    local target = reach and pc or other_pc
    if w._p.__inv then
        w:RemoveFromParent()
        wbl:SetInputMode_GameOnly(target, false)
        target._p.bShowMouseCursor = false
    else
        w._p.__inv = true
        wbl:SetInputMode_GameAndUIEx(target, w, 2, false, false)
        target._p.bShowMouseCursor = true
    end
    local h = hooks[TOGGLE]
    if h and h.pre then h.pre(param(c)) end   -- UE4SS: after the function
end

-- BP_CustomNarrativeDefaultUI.On Dialogue Finished (@185-275), reached through
-- the host's ClientExitDialogue
local function dialogue_end()
    local h = hooks[DLG_EXIT]
    if h and h.pre then h.pre(param(new_obj("NarrativeComponent", "NC", {}, {})), param(0)) end
    wbl:SetInputMode_GameOnly(pc, false)
    pc._p.bShowMouseCursor = false
end

-- ------------------------------------------------------------ install
local uiinput = require("sdc_uiinput")
local W = require("sdc_widgets")
local players = require("sdc_players")
local S = { role = "client", remote = {}, remote_pcs = {} }
players.init(S, { remote_record = function() return {} end })
uiinput.install(S)
check(loops.uiinput ~= nil, "1 s tick scheduled")
loops.uiinput()
check(hooks[GAMEONLY] ~= nil and hooks[DLG_EXIT] ~= nil, "native hooks (SetInputMode_GameOnly, ClientExitDialogue)")
check(hooks[TOGGLE] ~= nil and hooks[DBLCLICK] ~= nil and hooks[LOOTBOX] ~= nil, "Blueprint hooks (ToggleInventory, On_MouseDoubleClick, ContextOpenLootBox)")
local nreg = #registered
loops.uiinput()
check(#registered == nreg, "hooks registered once")

-- 1. the game's switch reaches this player's controller: nothing to do
local m = mark()
game_toggle(comp, true)
check(pc._p.__mode == "gameui" and pc._p.bShowMouseCursor == true and calls.gameui == 1, "open: the game's own UI input")
check(logged("uiinput: inventory window opened by the game; its switch to UI input reached", m) ~= nil, "open: info line once")
game_toggle(comp, true)
check(pc._p.__mode == "game" and pc._p.bShowMouseCursor == false and uiinput.stats.fixed_close == 0, "close: the game's own game input")

-- 2. the game's switch goes to another controller: the game's step here
misroute = true
m = mark()
game_toggle(comp, false)
check(pc._p.__mode == "gameui" and pc._p.__focus == window and pc._p.__lock == 2 and pc._p.bShowMouseCursor == true,
    "open (switch lost): game+UI on the window, LockAlways, cursor on")
check(logged("did not reach it; applied the game's own open step here", m) ~= nil, "open (switch lost): log line")
check(logged("GetPlayerController%(0%) from the component = BP_PlayerController_C_9 %(NOT this player's%)", m) ~= nil
    and logged("1 local player%(s%), the first one's controller BP_PlayerController_C_1", m) ~= nil, "open (switch lost): controller diagnostics")
m = mark()
game_toggle(comp, false)
check(pc._p.__mode == "game" and pc._p.bShowMouseCursor == false, "close (switch lost): game input, cursor off")
check(logged("applied the game's own close step here", m) ~= nil, "close (switch lost): log line")
misroute = false

-- 3. close with the cursor still on while the co-op panel is open: left as is
game_toggle(comp, true)
package.loaded["sdc_ui"] = { open = true }
pc._p.bShowMouseCursor = true
misroute = true
m = mark()
game_toggle(comp, false)
check(pc._p.bShowMouseCursor == true and logged("the cursor stays because the co%-op panel is open", m) ~= nil, "close: panel keeps the cursor")
package.loaded["sdc_ui"] = nil
misroute = false
pc._p.bShowMouseCursor = false
pc._p.__mode = "game"

-- 4. the dialogue's end lands on the open trade window: its input comes back
game_toggle(comp, true)
local gu = calls.gameui
m = mark()
T = T + 0.25
dialogue_end()
check(pc._p.__mode == "game" and pc._p.bShowMouseCursor == false, "dialogue end: the game's switch happened")
check(logged("a switch to game control came while the inventory window is open %(the NPC dialogue's end", m) ~= nil
    and logged("250 ms after it opened", m) ~= nil, "dialogue end: source and time in the log")
run_delayed()
check(pc._p.__mode == "gameui" and pc._p.__focus == window and pc._p.bShowMouseCursor == true and calls.gameui == gu + 1,
    "next frame: the window's own input again")
check(logged("uiinput: inventory window input restored on BP_PlayerController_C_1", m) ~= nil, "restore line")

-- 5. at most KEEP_MAX restores per opened window
T = T + 5
for _ = 1, 3 do wbl:SetInputMode_GameOnly(pc, false); pc._p.bShowMouseCursor = false; run_delayed() end
check(pc._p.__mode == "gameui" and uiinput.stats.kept == 4, "restored 4 times")
m = mark()
wbl:SetInputMode_GameOnly(pc, false); pc._p.bShowMouseCursor = false; run_delayed()
check(pc._p.__mode == "game" and logged("lost its input 4 times since it opened", m) ~= nil, "5th: gave up with a warning")
m = mark()
wbl:SetInputMode_GameOnly(pc, false); run_delayed()
check(logged("lost its input", m) == nil, "gave-up warning only once")
-- reopening starts over
game_toggle(comp, true)      -- closes (window was open)
game_toggle(comp, true)      -- opens
wbl:SetInputMode_GameOnly(pc, false); pc._p.bShowMouseCursor = false; run_delayed()
check(pc._p.__mode == "gameui" and uiinput.stats.kept == 5, "reopened window: restored again")

-- 6. closed window / another controller: the hook does nothing
game_toggle(comp, true)      -- close
local k = uiinput.stats.kept
wbl:SetInputMode_GameOnly(pc, false); run_delayed()
check(uiinput.stats.kept == k and #delayed == 0, "no window: nothing scheduled")
game_toggle(comp, true)      -- open
wbl:SetInputMode_GameOnly(other_pc, false); run_delayed()
check(uiinput.stats.kept == k and pc._p.__mode == "gameui", "another controller's switch: ignored")

-- 7. sdc_widgets.game_input: never over an open window
m = mark()
local switched = W.game_input(pc, "own character setup check")
check(switched == false and pc._p.__mode == "gameui" and pc._p.bShowMouseCursor == true, "game_input skipped while the window is open")
check(logged("ui: game controls NOT forced %(own character setup check%): the inventory window", m) ~= nil, "skip line")
game_toggle(comp, true)      -- close
pc._p.bShowMouseCursor = true
m = mark()
switched = W.game_input(pc, "death screen closed: respawn asked")
check(switched == true and pc._p.__mode == "game" and pc._p.bShowMouseCursor == false, "game_input applied with no window")
check(logged("ui: game controls forced on BP_PlayerController_C_1 %(death screen closed: respawn asked%)", m) ~= nil, "forced line")
pawn._p["JournalOpen?"] = true
check(W.game_input(pc, "x") == false, "journal open: skipped")
pawn._p["JournalOpen?"] = nil
mm._p.MapToggled = true
check(W.game_input(pc, "x") == false, "map open: skipped")
mm._p.MapToggled = false

-- 8. sdc_players: stray menu widgets only
local pause = new_obj("PauseScreen_C", "PauseScreen_C_1", { __inv = true }, {})
local save_menu = new_obj("SaveMenu_C", "SaveMenu_C_1", { __inv = true }, {})
pc._p.__mode = "gameui"
m = mark()
players.close_menu_widgets(pc)
check(save_menu._p.__inv == true and pc._p.__mode == "gameui", "pause menu's own SaveMenu left alone")
check(logged("client: menu widget%(s%) SaveMenu_C on screen while PauseScreen_C is open: theirs, left alone", m) ~= nil, "left-alone line")
pause:RemoveFromParent()
m = mark()
players.close_menu_widgets(pc)
check(save_menu._p.__inv == false and pc._p.__mode == "game", "stray SaveMenu closed, game controls")
check(logged("stray main%-menu widgets closed: SaveMenu_C", m) ~= nil, "closed + forced lines")

-- 9. another player's component / a host: ignored
local f0 = uiinput.stats.fixed_open
misroute = true
game_toggle(other_comp, false)
check(uiinput.stats.fixed_open == f0 and pc._p.__mode == "game", "other player's ToggleInventory ignored")
S.role = "host"
game_toggle(comp, false)
check(uiinput.stats.fixed_open == f0 and pc._p.__mode == "game", "host: ToggleInventory hook does nothing")
game_toggle(comp, false)     -- close again
S.role = "client"
misroute = false

-- 10. config off: as before
cfg.values.game_ui_input = false
game_toggle(comp, true)      -- open
m = mark()
check(W.game_input(pc, "off") == true and pc._p.__mode == "game", "off: game_input not gated")
run_delayed()
check(pc._p.__mode == "game" and logged("uiinput:", m) == nil, "off: no restore, no uiinput lines")
cfg.values.game_ui_input = nil
game_toggle(comp, true)      -- close

-- 11. container items in the inventory
local function slot(da_props, props)
    local da = new_obj("JigsawItem_DataAsset_C", da_props.__name or "DA_Box", da_props, {})
    props.JigDataAsset = da
    return new_obj("JSI_Slot_C", "JSI_Slot_C_" .. tostring(next_addr), props, {})
end
local mother = new_obj("JSIContainer_C", "JSIContainer_C_1", { AllowOpeningContainers = true }, {})
local canvas = new_obj("BP_InspectorCanvas_C", "BP_InspectorCanvas_C_1", { __inv = true }, {})
local win2 = new_obj("ContainerWindowWidget_C", "ContainerWindowWidget_C_1", { __parent = canvas }, {})
local s1 = slot({ __name = "DA_AmmoCase", ["IsContainer?"] = true, ["OpenContainerOnDoubleClick?"] = true },
    { ContainerMother = mother, SlotContainer = new_obj("JSIContainer_C", "Sub_1", {}, {}), WindowContainer = win2 })
m = mark()
hooks[DBLCLICK].pre(param(s1), param({}), param({}), param({}))
check(logged("uiinput: open request for DA_AmmoCase in JSIContainer_C_1 %(double click / context menu Open%): container=true", m) ~= nil
    and logged("allowed%-here=true", m) ~= nil and logged("%-> container window shown", m) ~= nil, "container opened: info line")
local s2 = slot({ __name = "DA_Toolbox", ["IsContainer?"] = true, ["OpenContainerOnDoubleClick?"] = true },
    { ContainerMother = mother })
m = mark()
hooks[DBLCLICK].pre(param(s2), param({}), param({}), param({}))
check(logged("%[WARN%] uiinput: open request for DA_Toolbox", m) ~= nil and logged("contents%-widget=MISSING", m) ~= nil
    and logged("no contents widget for this item on this machine", m) ~= nil, "container not opened: warning with the reason")
local s4 = slot({ __name = "DA_Crate", ["IsContainer?"] = true, ["OpenContainerOnDoubleClick?"] = true },
    { ContainerMother = mother, SlotContainer = new_obj("JSIContainer_C", "Sub_4", {}, {}), IsPending = true })
m = mark()
hooks[DBLCLICK].pre(param(s4), param({}), param({}), param({}))
check(logged("pending=true", m) ~= nil and logged("the item is still pending: waiting for the host", m) ~= nil,
    "pending container item: warning names it")
local s3 = slot({ __name = "DA_Bandage" }, { ContainerMother = mother })
m = mark()
hooks[DBLCLICK].pre(param(s3), param({}), param({}), param({}))
check(logged("open request", m) == nil, "not a container: no line")
local menu = new_obj("JigContextMenuComp_C", "JigContextMenuComp", { CurrentItemRef = s1 }, {})
m = mark()
hooks[LOOTBOX].pre(param(menu))
check(logged("uiinput: loot box DA_AmmoCase opened from the context menu here", m) ~= nil, "loot box line")

-- 12. a callback that throws never reaches the game
local bad = setmetatable({}, { __index = function() error("boom") end })
local ok = pcall(hooks[TOGGLE].pre, param(bad))
check(ok, "a broken argument is caught inside the hook")

print = real_print
for _, l in ipairs(lines) do if l:find("uiinput:") or l:find("ui: game") or l:find("menu widget") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
