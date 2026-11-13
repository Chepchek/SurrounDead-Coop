-- Mock test: opening a single-player world for friends while playing
-- (sdc_session.open_world_now, 0.7.3). The game's save, the persistent
-- world reopened with "?listen", the menu's own Continue once it listens,
-- the end of the load; failures leave the player a message, never a
-- half-done world.
-- usage: lua mock_reopen_world.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end

-- every other sdc_ module: an automatic stub (any field is a function returning nil)
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_session = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
-- no LOCALAPPDATA: becoming host must not copy the real saves of this PC
-- (sdc_session backup_saves; 0.7.3 test runs left backups in the user's folder)
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end
local real_execute = os.execute
os.execute = function(cmd)
    if tostring(cmd):find("robocopy", 1, true) then error("test tried to run robocopy: " .. tostring(cmd)) end
    return real_execute(cmd)
end

-- clock
local NOW = 5000
os.time = function() return NOW end

-- the world
local W = { role = "standalone", menu = false, pawn = { ["PlayerDead?"] = false }, menu_widget = nil, map = "LongdownValley",
            pc = { key = "pc1" } }
local execs = {}
local net = stub()
net.on = function() end
package.loaded["sdc_net"] = net
local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
-- MenuWidget_C's "SaveMenu" is a designer child: found with sdc_widgets.child
-- (GetWidgetFromName), never read by name as a Blueprint variable (UE4SS
-- 3.0.1 property cache, crash 2026-11-13): such a read is counted and fails
local SAVEMENU_PROP_READS = 0
ue.prop = function(o, k)
    if k == "SaveMenu" then SAVEMENU_PROP_READS = SAVEMENU_PROP_READS + 1; return nil end
    return type(o) == "table" and rawget(o, k) or nil
end
package.loaded["sdc_widgets"] = setmetatable({
    child = function(o, name) return type(o) == "table" and rawget(o, name) or nil end,
}, { __index = function() return function() return nil end end })
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.net_role = function() return W.role end
ue.in_main_menu = function() return W.menu end
ue.local_pawn = function() return W.pawn end
ue.local_pc = function() return W.pc end
ue.map_name = function() return W.map end
ue.world_path = function() return "/Game/Levels/PersistentLevel" end
ue.has_pending_connection = function() return false end
ue.exec = function(cmd) execs[#execs + 1] = cmd end
ue.ems_current_slot = function() return "MySlot" end
ue.find_first = function() return nil end   -- FindAllOf does not see UMG widgets in this UE4SS build
package.loaded["sdc_lobby"] = { live_main_menu = function() return W.menu_widget end }
ue.find_all = function() return {} end
ue.sub_time = function(_, fn, ...) return pcall(fn, ...) end
ue.delay = function() return false end
package.loaded["sdc_ue"] = ue

-- the game's save (sdc_savecheck.save_now): the callback is kept for the test
local SAVE = { calls = 0, done = nil }
package.loaded["sdc_savecheck"] = {
    save_now = function(_, done) SAVE.calls = SAVE.calls + 1; SAVE.done = done end,
}

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, ...) said[#said + 1] = key; return real_say(key, ...) end
local function was_said(key) for _, k in ipairs(said) do if k == key then return true end end return false end

local cfg = require("sdc_config")
cfg.set("listen_on_load", false)
local session = require("sdc_session")
session.register_handlers()
local function tick(n)
    for _ = 1, n or 1 do NOW = NOW + 1; session.tick() end
end
local function menu_widget(no_slot)
    local w = { key = "MenuWidget_C_0", continued = 0,
                SaveMenu = { key = "SaveMenu_C_0", CurrentSelectedSlot = (not no_slot) and { key = "Slot_0", SaveName = "MySlot" } or nil } }
    w.IsInViewport = function() return true end
    w.BndEvt__MenuWidget_ContinueGame_K2Node_ComponentBoundEvent_25_OnButtonClickedEvent__DelegateSignature = function(self)
        self.continued = self.continued + 1
    end
    return w
end

tick(2)   -- in a single-player world

print("happy path: button -> save -> listen -> Continue -> open")
check(type(session.open_world_now) == "function", "open_world_now exists")
session.host_on_next_load()                          -- the panel's button in a single-player world
check(cfg.get("listen_on_load") == true, "the setting is on (later worlds open too)")
check(SAVE.calls == 1 and session.reopen_state() and session.reopen_state().step == "save", "the game's save runs first")
check(was_said("reopen_saving") and not was_said("single_world"), "says it is saving (not the old 'quit to the menu' hint)")
check(#execs == 0, "nothing reopened before the save ended")
check(session.open_world_now() == false and SAVE.calls == 1, "a second press while it runs: no second save")
SAVE.done(true, nil, "MySlot")
check(session.reopen_state().step == "menu", "saved -> reopening")
check(execs[1] == "open /Game/Levels/PersistentLevel?listen", "the persistent world reopens as a listen server: " .. tostring(execs[1]))
check(was_said("reopen_loading") and not was_said("menu_listen"), "says the world loads again (not the menu hint)")
-- the level loads: menu, standalone for a moment, then a listen server
W.menu, W.pawn, W.role = true, nil, "standalone"
tick(2)
check(session.reopen_state().step == "menu", "still waiting while not listening")
W.role = "host"
tick(1)
check(session.reopen_state().step == "menu", "listening, no menu widget yet: waits")
W.menu_widget = menu_widget(true)
tick(5)
check(W.menu_widget.continued == 0, "the menu appeared, its save list has no slot selected yet: waits")
W.menu_widget.SaveMenu.CurrentSelectedSlot = { key = "Slot_0", SaveName = "MySlot" }
tick(1)
check(W.menu_widget.continued == 1 and session.reopen_state().step == "load", "slot selected: the menu's Continue pressed once")
tick(3)
check(W.menu_widget.continued == 1, "Continue not pressed again while loading")
W.menu, W.pawn = false, { ["PlayerDead?"] = false }
tick(1)
check(session.reopen_state() == nil and was_said("reopen_done"), "loaded and open: done, says so")

print("the save fails: nothing reopened")
said, execs = {}, {}
W.role, W.menu, W.menu_widget = "standalone", false, nil
tick(1)
check(session.open_world_now() == true, "started")
SAVE.done(false, "no save started")
check(session.reopen_state() == nil and #execs == 0 and was_said("reopen_save_failed"), "save failed: world stays, says why")

print("the menu never listens: the old way, said")
said, execs = {}, {}
check(session.open_world_now() == true, "started")
SAVE.done(true, nil, "MySlot")
W.menu, W.pawn, W.role = true, nil, "standalone"
tick(80)
check(session.reopen_state() == nil and was_said("reopen_continue_hand"), "no listen in 75 s: 'press Continue' said")

print("Continue fails: said, no loop")
said, execs = {}, {}
W.menu, W.pawn, W.role = false, { ["PlayerDead?"] = false }, "standalone"
tick(1)
session.open_world_now()
SAVE.done(true, nil, "MySlot")
W.menu, W.pawn, W.role = true, nil, "host"
W.menu_widget = { key = "MenuWidget_C_1", SaveMenu = { key = "SM", CurrentSelectedSlot = { key = "S" } } }   -- no Continue function
tick(5)
check(session.reopen_state() == nil and was_said("reopen_continue_hand"), "Continue missing: 'press Continue' said")

print("Continue pressed, nothing loads: the menu comes back")
said, execs = {}, {}
W.menu, W.pawn, W.role, W.menu_widget = false, { ["PlayerDead?"] = false }, "standalone", nil
tick(1)
session.open_world_now()
SAVE.done(true, nil, "MySlot")
W.menu, W.pawn, W.role = true, nil, "host"
W.menu_widget = menu_widget()
tick(4)
check(session.reopen_state() and session.reopen_state().step == "load", "Continue pressed")
W.menu_widget = nil   -- the menu removed itself, no level loads
execs = {}
tick(92)
check(session.reopen_state() == nil and was_said("reopen_continue_hand")
    and execs[#execs] == "open /Game/Levels/PersistentLevel?listen", "no load in 90 s: the menu reopened, 'press Continue' said")

print("refusals")
said = {}
W.menu, W.role, W.menu_widget = false, "standalone", nil
W.pawn = { ["PlayerDead?"] = true }
local calls0 = SAVE.calls
check(session.open_world_now() == false and SAVE.calls == calls0 and was_said("reopen_need_alive"), "dead: respawn first, no save")
W.pawn = { ["PlayerDead?"] = false }
W.role = "host"
check(session.open_world_now() == false and SAVE.calls == calls0, "already hosting: nothing")
W.role, W.menu = "standalone", true
check(session.open_world_now() == false and SAVE.calls == calls0, "main menu: not this path (the menu reopens itself)")
check(SAVEMENU_PROP_READS == 0, "the menu's save list was never read as a Blueprint variable by name ("
    .. SAVEMENU_PROP_READS .. ")")

print = real_print
print(string.format("reopen world: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
