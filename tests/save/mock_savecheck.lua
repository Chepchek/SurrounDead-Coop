-- Mock harness: runs the real sdc_savecheck (+ sdc_ue / sdc_config / sdc_log)
-- against fake UE objects and a fake %LOCALAPPDATA% folder.
-- usage: lua mock_savecheck.lua <scripts dir> <scratch root>
local SCRIPTS, ROOT = arg[1], arg[2]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 1000.0
os.clock = function() return T end
local function advance(s) T = T + s end

local real_getenv = os.getenv
local LAD = ROOT .. "\\lad"
os.getenv = function(k) if k == "LOCALAPPDATA" then return LAD end return real_getenv(k) end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------------ files
local function sh(cmd) os.execute(cmd .. " >nul 2>&1") end
local SAVES = LAD .. "\\SurrounDead\\Saved\\SaveGames"
local BACK = LAD .. "\\SurrounDead\\Saved\\SDCoop_Backups"
sh('rmdir /S /Q "' .. LAD .. '"')
sh('mkdir "' .. SAVES .. '\\MySlot"')
sh('mkdir "' .. SAVES .. '\\OtherSlot"')
sh('mkdir "' .. BACK .. '"')
local function wfile(path, s) local f = assert(io.open(path, "wb")); f:write(s); f:close() end
local function rfile(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local save_gen = 0
local function ems_write(slot)
    save_gen = save_gen + 1
    local d = SAVES .. "\\" .. slot
    sh('mkdir "' .. d .. '"')
    for _, f in ipairs({ "Slot.sav", "Player.sav", "PlayerInfo.sav", "General.sav", "Difficulties.sav" }) do
        wfile(d .. "\\" .. f, "EMSH" .. f .. " gen " .. save_gen)
    end
    wfile(d .. "\\Level.sav", string.rep("L" .. save_gen, 6000))
    wfile(SAVES .. "\\" .. slot .. "_SkillTree.sav", "tree " .. save_gen)
    wfile(SAVES .. "\\" .. slot .. "_SDQuests.sav", "quests " .. save_gen)
end
ems_write("MySlot")
-- 13 automatic backups + 2 manual ones + a file
for i = 1, 13 do sh(string.format('mkdir "%s\\2026-11-%02d_10-00-00"', BACK, i)) end
sh('mkdir "' .. BACK .. '\\manual_20261110_103313"')
sh('mkdir "' .. BACK .. '\\2026-11-xx_bad"')
local MODDIR = ROOT .. "\\mod"
sh('mkdir "' .. MODDIR .. '"')
os.remove(MODDIR .. "\\savecheck_client_slot.txt")
os.remove(MODDIR .. "\\savecheck_last.txt")

-- ------------------------------------------------------------------ fake objects
local next_addr = 4096
local function fname(s) return { ToString = function() return s end, _s = s } end
local function arr(list)
    return { _l = list, ForEach = function(self, fn)
        for i, v in ipairs(self._l) do fn(i, { get = function() return v end }) end
    end }
end
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    if k == "Tags" then return arr(rawget(t, "_tags")) end
    local p = rawget(t, "_p")[k]
    return p
end
local OBJECTS = {}
local function new(cls, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _cls = cls, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _tags = {} }, Obj)
    OBJECTS[#OBJECTS + 1] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name end
function Obj:GetFName() return fname(self._name) end
function Obj:GetClass() return { GetFName = function() return fname(self._cls) end } end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
local function tagged(o, t) for _, x in ipairs(o._tags) do if x:ToString() == t then return true end end return false end
local function set_tag(o, t, on)
    local keep = {}
    for _, x in ipairs(o._tags) do if x:ToString() ~= t then keep[#keep + 1] = x end end
    if on then keep[#keep + 1] = fname(t) end
    o._tags = keep
end

-- items: { {uid, count}, ... } -> MainJigContainers TArray of structs
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local function inventory(items)
    local list = {}
    for _, it in ipairs(items) do
        list[#list + 1] = { [F_USID] = { A = it[1], B = 2, C = 3, D = 4 }, [F_INFO] = { [F_COUNT] = it[2] } }
    end
    return arr({ { [F_ITEMS] = arr(list) } })
end

-- world
local WORLD = { role = "host", slot = "MySlot", menu = false, cvars = { ["Game.AutoSave"] = true }, timer = false, calls = {} }
local function call(name) WORLD.calls[#WORLD.calls + 1] = name end
local function called(name) for _, c in ipairs(WORLD.calls) do if c == name then return true end end return false end

local function make_pc(name, remote, props)
    props = props or {}
    props.LevellingComponent = new("LevellingComponent_C", name .. "_lev", { CurrentLevel = props.level or 1, CurrentXP = props.xp or 0 })
    props.TechTreeComponent = new("TechTreeComponent_C", name .. "_tech", { SkillPoints = 0, CurrentPoints = 0 })
    props.NetConnection = remote and new("NetConnection", name .. "_conn") or nil
    props.Player = (not remote) and new("LocalPlayer", "LocalPlayer_0") or props.NetConnection
    props.ZombieKills = props.ZombieKills or 0
    return new("BP_PlayerController_C", name, props, {
        IsLocalController = function() return not remote end,
        SaveGameToSlot = function() call("SaveGameToSlot") end,
    })
end
local function make_char(name, pc, items)
    local comp = new("BP_JigComponent_C", name .. "_jig", { MainJigContainers = inventory(items) })
    local ch = new("BP_PlayerCharacter_C", name, { Controller = pc, BP_JigMultiplayer = comp, ["PlayerDead?"] = false })
    comp._m.GetOwner = function() return ch end
    ch._m.K2_GetActorLocation = function() return { X = 1000, Y = 2000, Z = 100 } end
    if pc then pc._p.Pawn = ch end
    return ch, comp
end

local host_pc = make_pc("BP_PlayerController_C_1", false, { level = 7, xp = 120, ZombieKills = 33, Forename = "Host", Surname = "H" })
local host_char, host_comp = make_char("BP_PlayerCharacter_C_1", host_pc, { { 11, 1 }, { 12, 5 } })
local cl_pc = make_pc("BP_PlayerController_C_2", true, { level = 1 })
local cl_char, cl_comp = make_char("BP_PlayerCharacter_C_2", cl_pc, { { 21, 1 }, { 22, 2 }, { 23, 3 } })
local dead_body = make_char("BP_PlayerCharacter_C_3", nil, { { 31, 1 } })
host_pc._p.ZombieKills = 33

local save_player = new("Save_Player_C", "Save_Player_C_0", {
    MainJigContainers = inventory({ { 11, 1 }, { 12, 5 } }), ZombieKills = 33, BossZombieKills = 0, HumanKills = 0,
    AnimalKills = 0, DaysSurvived = 0, InfestationsDestroyed = 0,
    PlayerLocation = { Translation = { X = 1000, Y = 2000, Z = 100 } },
})
local save_general = new("Save_General_C", "Save_General_C_0")
local gm = new("BP_SurroundeadGameMode_C", "GM", { Autosave = true }, {
    EventSave = function(_, v) call("EventSave:" .. tostring(v)); WORLD.timer = true end,
})

local EMS = new("EMSFunctionLibrary", "Default__EMSFunctionLibrary", {}, {
    GetSlotInfoSaveGame = function(_, _, out) out.SaveGameName = WORLD.slot end,
    SetCurrentSaveGameName = function(_, _, name) WORLD.slot = name; call("SetSlot:" .. name) end,
    DoesSaveSlotExist = function(_, _, name) return rfile(SAVES .. "\\" .. name .. "\\Slot.sav") ~= nil end,
    GetSortedSaveSlots = function() return arr({ "SDCoop_ClientTemp", "OtherSlot2", "MySlot" }) end,
    GetCustomSave = function(_, _, cls) if cls._name == "Save_Player_C" then return save_player end return save_general end,
    SetActorSaveProperties = function(_, a, skip, persistent) set_tag(a, "EMS_SkipSave", skip); a._persistent = persistent end,
    DeleteAllSaveDataForSlot = function() end,
})
local KSL = new("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return WORLD.role == "standalone" end,
    IsServer = function() return WORLD.role ~= "client" end,
    GetConsoleVariableBoolValue = function(_, n) return WORLD.cvars[n] == true end,
    K2_IsTimerActive = function() return WORLD.timer end,
    K2_GetTimerRemainingTime = function() return WORLD.timer and 300 or -1 end,
})
local GPS = new("GameplayStatics", "Default__GameplayStatics", {}, {
    GetGameMode = function() return WORLD.role ~= "client" and gm or nil end,
})
local PATHS = {
    ["/Script/EasyMultiSave.Default__EMSFunctionLibrary"] = EMS,
    ["/Script/Engine.Default__KismetSystemLibrary"] = KSL,
    ["/Script/Engine.Default__GameplayStatics"] = GPS,
    ["/Game/Blueprints/Saves/Save_Player.Save_Player_C"] = new("Class", "Save_Player_C"),
}
local function fn_obj(path) return new("Function", path:match("[^:]+$")) end

-- ------------------------------------------------------------------ UE4SS globals
local HOOKS = {}
RegisterHook = function(path, a, b)
    HOOKS[path] = HOOKS[path] or {}
    table.insert(HOOKS[path], { pre = a, post = b })
    return 1, 2
end
StaticFindObject = function(path)
    if PATHS[path] then return PATHS[path] end
    if path:find(":", 1, true) and not path:find("SaveMenu", 1, true) then
        PATHS[path] = fn_obj(path)
        return PATHS[path]
    end
    return nil
end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(OBJECTS) do
        if o._valid and (o._cls == cls or (cls == "PlayerController" and o._cls == "BP_PlayerController_C")) then out[#out + 1] = o end
    end
    if cls == "BP_LootContainer_C" then for i = 1, 5 do out[#out + 1] = new("BP_LootContainer_C", "box" .. i) end end
    if cls == "BP_Infestation_C" then out[#out + 1] = new("BP_Infestation_C", "nest", { ["IsDestroyed?"] = true }) end
    return #out > 0 and out or nil
end
FindFirstOf = function(cls) local l = FindAllOf(cls); return l and l[1] or nil end
local delayed = {}
ExecuteInGameThreadWithDelay = function(ms, fn) delayed[#delayed + 1] = { at = T + ms / 1000, fn = fn } end
LoopInGameThreadWithDelay = function() return 1 end
ExecuteInGameThread = function(fn) fn() end
local function run_delayed()
    local keep = {}
    for _, d in ipairs(delayed) do if d.at <= T then d.fn() else keep[#keep + 1] = d end end
    delayed = keep
end

local log = require("sdc_log")
local LOG = {}
local ALL = {}
local real_info, real_warn, real_err = log.info, log.warn, log.err
log.info = function(msg, ...) local s = string.format(msg, ...); LOG[#LOG + 1] = s; ALL[#ALL + 1] = s; print("    log: " .. s) end
log.warn = function(msg, ...) local s = "[WARN] " .. string.format(msg, ...); LOG[#LOG + 1] = s; print("    log: " .. s) end
log.err = function(msg, ...) local s = "[ERROR] " .. string.format(msg, ...); LOG[#LOG + 1] = s; print("    log: " .. s) end
log.err_throttled = function(_, msg, ...) log.err(msg, ...) end
log.toast = function(text, _, _, lt) LOG[#LOG + 1] = "[TOAST] " .. (lt or text) end
local function logged(pat) for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end return nil end
local function ever(pat) for _, l in ipairs(ALL) do if l:find(pat, 1, true) then return l end end return nil end
local function clear_log() LOG = {} end
local _ = real_info, real_warn, real_err

local cfg = require("sdc_config")
cfg.path = MODDIR .. "\\config.ini"
local ue = require("sdc_ue")
ue.local_pc = function() if WORLD.role == "client" then return WORLD.client_pc end return host_pc end
ue.in_main_menu = function() return WORLD.menu end

local S = { role = "host", remote = { [cl_pc:GetFullName()] = { pc = cl_pc, name = "Friend", pawn = cl_char } }, remote_pcs = { cl_pc } }
package.loaded["sdc_session"] = { state = S, world_reset_hooks = {} }
package.loaded["sdc_players"] = { host_skip_save_tick = function() call("players.skip_tick") end }

local sc = require("sdc_savecheck")

local function p(v) return { get = function() return v end } end
local function fire(path, kind, ...)
    local hs = HOOKS[path]
    assert(hs, "no hook " .. path)
    for _, h in ipairs(hs) do
        local f = kind == "post" and h.post or h.pre
        local r = f(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
end
local PC = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"
local F_SAVE = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
local F_CUSTOM = "/Script/EasyMultiSave.EMSFunctionLibrary:SaveCustom"
local F_LOAD = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestSaveGame"
local GM_AUTO = "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:AutoSaveGame"
local node = new("EMSAsyncSaveGame", "node")

-- one host save through the game's order of calls
local function host_save(opts)
    opts = opts or {}
    fire(F_SAVE, "pre", p(nil), p(host_pc), p(3))
    local ret = node
    if opts.refused then ret = nil end
    fire(F_SAVE, "post", p(nil), p(ret), p(host_pc), p(3))
    if opts.refused then return end
    if opts.trigger then fire(opts.trigger, "post", p(gm)) end
    fire(JIG, "post", p(host_comp), p(host_comp), p(nil))
    if opts.remote_write then
        fire(JIG, "post", p(cl_comp), p(cl_comp), p(nil))
        save_player._p.MainJigContainers = inventory({ { 21, 1 }, { 22, 2 }, { 23, 3 } })
    end
    advance(0.4)
    fire(PC .. ":OnCompleted_9CDBA9034C950D925C1539BE037C23EF", "post", p(host_pc))
    ems_write(WORLD.slot)
    fire(F_CUSTOM, "post", p(nil), p(true), p(host_pc), p(save_general))
    fire(F_CUSTOM, "post", p(nil), p(true), p(host_pc), p(save_player))
    advance(2.1)
    fire(PC .. ":OnCompleted_0E13F8DC4FF1E81D4DC55BB17E7EC154", "post", p(host_pc))
end

-- ================================================================== tests
print("install / hooks")
sc.install(S)
check(HOOKS[F_SAVE] and HOOKS[F_SAVE][1].post ~= nil, "AsyncSaveActors hooked native with a post callback")
check(HOOKS[F_CUSTOM] ~= nil and HOOKS[JIG] ~= nil, "SaveCustom and SERVER_RequestSaveGame hooked")
check(HOOKS["/Game/UI/Menus/SaveGame/SaveMenu.SaveMenu_C:SaveGameToSlot"] == nil, "SaveMenu not hooked while not loaded")
check(package.loaded["sdc_session"].world_reset_hooks.savecheck ~= nil, "world reset hook registered")

print("startup: throwaway slot left by a closed client game")
wfile(MODDIR .. "\\savecheck_client_slot.txt", "MySlot\n")
WORLD.slot = "SDCoop_ClientTemp"
S.role = "standalone"; WORLD.role = "standalone"
sc.tick()
check(WORLD.slot == "MySlot", "current slot back to the remembered MySlot")
check((rfile(MODDIR .. "\\savecheck_client_slot.txt") or "x") == "", "memory cleared")

print("client join helpers")
check(sc.client_slot_before_join("MySlot") == "MySlot", "normal join keeps its own slot")
check((rfile(MODDIR .. "\\savecheck_client_slot.txt") or ""):match("^%s*(.-)%s*$") == "MySlot", "slot remembered on disk")
check(sc.client_slot_before_join("SDCoop_ClientTemp") == "MySlot", "stale throwaway slot -> remembered one")
os.remove(MODDIR .. "\\savecheck_client_slot.txt")
check(sc.client_slot_before_join("SDCoop_ClientTemp") == "MySlot", "nothing remembered -> newest slot on disk (OtherSlot2 not on disk, temp skipped)")
os.remove(MODDIR .. "\\savecheck_client_slot.txt")
-- the list as UE4SS gives it: elements wrapped twice; tostring of a wrapper is not a name
local function wrapped(s)
    return setmetatable({ get = function() return fname(s) end }, { __tostring = function() return "RemoteUnrealParam: 00000222D764E2C8" end })
end
local sorted_real = EMS._m.GetSortedSaveSlots
EMS._m.GetSortedSaveSlots = function() return arr({ wrapped("SDCoop_ClientTemp"), wrapped("MySlot") }) end
check(sc.client_slot_before_join("SDCoop_ClientTemp") == "MySlot", "wrapped list elements read as their text")
os.remove(MODDIR .. "\\savecheck_client_slot.txt")
EMS._m.GetSortedSaveSlots = function() return arr({ setmetatable({}, { __tostring = function() return "RemoteUnrealParam: 1" end }) }) end
check(sc.client_slot_before_join("SDCoop_ClientTemp") == "SDCoop_ClientTemp", "an element with no text is never used as a slot name")
EMS._m.GetSortedSaveSlots = sorted_real
sc.client_slot_restored("MySlot")
check((rfile(MODDIR .. "\\savecheck_client_slot.txt") or "x") == "", "memory cleared after leaving")

print("host save with a client connected")
S.role = "host"; WORLD.role = "host"
set_tag(host_pc, "EMS_SkipSave", true)       -- a bug elsewhere tagged the host's controller
clear_log()
host_save({ trigger = GM_AUTO })
check(tagged(cl_pc, "EMS_SkipSave") and tagged(cl_char, "EMS_SkipSave"), "remote controller + character tagged before EMS started")
check(not tagged(host_char, "EMS_SkipSave"), "host character not tagged")
check(not tagged(host_pc, "EMS_SkipSave") and host_pc._persistent == true, "host controller tag cleared, persistent again")
check(tagged(dead_body, "EMS_SkipSave"), "unpossessed body tagged (the host pawn is known, so it is not the host's)")
check(called("players.skip_tick"), "sdc_players' pass ran first")
local line = logged("[SAVE] save #")
check(line and line:find("OK", 1, true) and line:find("trigger autosave", 1, true), "[SAVE] line: OK, trigger autosave")
check(line and line:find("PlayerInfo.sav = host's own", 1, true), "[SAVE] line: PlayerInfo.sav = host's own")
check(line and line:find("rewritten: Slot", 1, true), "[SAVE] line: files rewritten")
check(line and line:find("2/2 characters", 1, true), "[SAVE] line: 2/2 other characters skip-save (client + body)")
check(sc.last and sc.last.ok, "M.last ok")
for _ = 1, 5 do advance(1); sc.tick() end
check(logged("[SAVE] world in save #"), "world counts line")
check(logged("containers 5") and logged("1 destroyed"), "counts: containers 5, infestation destroyed 1")

print("host save during which a client's inventory save lands")
clear_log()
host_save({ remote_write = true })
check(logged("WHILE the host was saving"), "remote inventory write logged as error")
check(logged("DIFFERS from the host") and logged("Friend's inventory"), "mismatch names the client's inventory")
WORLD.calls = {}
advance(3); run_delayed()
check(called("SaveGameToSlot"), "repair: the game's save ran again")
save_player._p.MainJigContainers = inventory({ { 11, 1 }, { 12, 5 } })

print("host world in the throwaway slot -> new slot")
clear_log()
WORLD.slot = "SDCoop_ClientTemp"
host_save({})
check(WORLD.slot:match("^CoopWorld_%d+_%d+$") ~= nil, "slot switched to " .. tostring(WORLD.slot))
check(logged("[TOAST] [SAVE] host world saved into new slot"), "toast shown")
WORLD.slot = "MySlot"

print("EMS refused")
clear_log()
host_save({ refused = true })
check(logged("not started"), "refused save reported")

print("timeout")
clear_log()
fire(F_SAVE, "pre", p(nil), p(host_pc), p(3))
fire(F_SAVE, "post", p(nil), p(node), p(host_pc), p(3))
advance(61); sc.tick()
check(logged("timeout"), "unfinished save reported after 60 s")

print("load compared with the last save")
clear_log()
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("matches the last save of this slot"), "load: matches")
host_pc._p.LevellingComponent._p.CurrentLevel = 6
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("DIFFERS from the last save") and logged("level 7 -> 6"), "load: level difference reported")
host_pc._p.LevellingComponent._p.CurrentLevel = 7

print("load: XP the game's own quest load gave again (Narrative refires quest events on Load; 13.11: +1200 every load)")
local lev = host_pc._p.LevellingComponent._p
local xp0 = lev.CurrentXP
local quests_was = package.loaded["sdc_quests"]
local REW = {}
package.loaded["sdc_quests"] = { host_rewards_since = function(t)
    local out = {}
    for _, e in ipairs(REW) do if e.at >= t then out[#out + 1] = { amount = e.amount, name = e.name, pawn = e.pawn } end end
    return out
end }
lev.Difficulty_MultiplierValue = 2.0
REW = { { at = T - 2, amount = 300, name = "My New Quest" }, { at = T - 2, amount = 300, name = "My New Quest" } }
lev.CurrentXP = xp0 + 1200
clear_log()
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("matches the last save of this slot") and logged("is the game's own: quest reward(s) given again by its quest load ('My New Quest' 300, 'My New Quest' 300, x2 XP multiplier")
    and not logged("DIFFERS"), "load: +1200 = 2 x 300 x 2.0 refired: explained, not a difference")
-- other XP besides: still a difference, the refired part named
lev.CurrentXP = xp0 + 1500
REW = { { at = T - 2, amount = 300, name = "My New Quest" }, { at = T - 2, amount = 300, name = "My New Quest" } }
clear_log()
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("DIFFERS from the last save") and logged("+1200 XP of quest reward(s) the game gave again while loading"),
    "load: +1500 with 1200 refired: reported, the refired part named")
-- rewards long before this load do not count
lev.CurrentXP = xp0 + 1200
REW = { { at = T - 120, amount = 300, name = "My New Quest" } }
clear_log()
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("DIFFERS from the last save") and not logged("quest reward(s)"), "load: a reward 2 min before the load: not taken for the game's refire")
-- review of fix 16: the host hands in a quest (+500) and loads within 30 s.
-- That real reward ran on the character of the world before the load (gone
-- in the main menu); the refires run on the new one. Only these count.
local cur_pawn = host_char:GetFullName()
local old_pawn = "BP_PlayerCharacter_C /Game/Levels/PL.PL:PersistentLevel.BP_PlayerCharacter_C_0"
lev.CurrentXP = xp0 + 1200
REW = { { at = T - 10, amount = 500, name = "Bunker", pawn = old_pawn },
        { at = T - 2, amount = 300, name = "My New Quest", pawn = cur_pawn },
        { at = T - 2, amount = 300, name = "My New Quest", pawn = cur_pawn } }
clear_log()
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("matches the last save of this slot") and not logged("DIFFERS")
    and logged("is the game's own: quest reward(s) given again by its quest load ('My New Quest' 300, 'My New Quest' 300, x2 XP multiplier")
    and not logged("'Bunker'"),
    "load: a real reward of the character before the load (10 s earlier) is no refire: +1200 explained, no WARN, 'Bunker' not named")
-- only that old character's reward in the window: nothing taken for a refire
lev.CurrentXP = xp0 + 1000
REW = { { at = T - 10, amount = 500, name = "Bunker", pawn = old_pawn } }
clear_log()
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
fire(PC .. ":OnCompleted_F36E30354316ADD99BBAD29E4E315233", "post", p(host_pc))
advance(3.1); run_delayed()
check(logged("DIFFERS from the last save") and not logged("quest reward(s)") and not logged("is the game's own"),
    "load: only the old character's +500 x2 = +1000 in the window: still a difference, not called the game's refire")
lev.CurrentXP, lev.Difficulty_MultiplierValue = xp0, nil
package.loaded["sdc_quests"] = quests_was

print("autosave watchdog")
clear_log()
WORLD.timer = false
for _ = 1, 4 do advance(16); sc.tick() end
check(called("EventSave:true"), "EventSave(true) called when the timer was not running")
check(ever("[SAVE] host world: slot 'MySlot'"), "host world baseline line")
WORLD.calls = {}
advance(16); sc.tick()
check(not called("EventSave:true"), "not called again once the timer runs")

print("co-op autosave with the game's setting off (its default): the mod runs the game's AutoSaveGame")
-- the game's AutoSaveGame: a whole save of the current slot (or nothing, as
-- when it skips itself: paused / permadeath / host dead)
WORLD.autosave_saves = true
gm._m.AutoSaveGame = function()
    call("AutoSaveGame")
    if WORLD.autosave_saves then host_save({ trigger = GM_AUTO }) end
end
clear_log()
WORLD.cvars["Game.AutoSave"] = false
WORLD.timer = false; WORLD.calls = {}
advance(16); sc.tick()
check(not called("EventSave:true"), "co-op world: the game's timer is not started (EventSave(true))")
check(logged("co-op world, the game's autosave setting is off"), "co-op autosave line")
check(logged("[TOAST] [SAVE] co-op autosave every 10 minutes on"), "co-op autosave toast")
check(WORLD.cvars["Game.AutoSave"] == false, "the setting itself unchanged")
host_save()   -- a save by hand: the 10 minutes count from it
clear_log(); WORLD.calls = {}
for _ = 1, 36 do advance(16); sc.tick() end   -- 576 s after it
check(not called("AutoSaveGame"), "nothing before 10 minutes after the last save")
for _ = 1, 3 do advance(16); sc.tick() end
check(called("AutoSaveGame"), "10 minutes after the last save: the game's own AutoSaveGame")
check(logged("trigger autosave"), "[SAVE] line of that save: trigger autosave")
advance(6); run_delayed()
check(logged("co-op autosave: the game's AutoSaveGame saved the world"), "checked: the save really started")
WORLD.calls = {}
for _ = 1, 30 do advance(16); sc.tick() end
check(not called("AutoSaveGame"), "not again within 10 minutes")
-- the game skips its autosave (e.g. paused): said, and tried again a minute later
WORLD.autosave_saves = false
clear_log()
local waited = 0
while not called("AutoSaveGame") and waited < 20 do advance(16); sc.tick(); waited = waited + 1 end
check(called("AutoSaveGame"), "due again after 10 minutes")
advance(6); run_delayed()
local nwarn = 0
for _, l in ipairs(LOG) do if l:find("AutoSaveGame did NOT save", 1, true) then nwarn = nwarn + 1 end end
check(nwarn == 1, "a run without a save is reported (once)")
WORLD.calls = {}
advance(16); sc.tick()
check(not called("AutoSaveGame"), "not at once again")
WORLD.autosave_saves = true
for _ = 1, 4 do advance(16); sc.tick() end
check(called("AutoSaveGame"), "tried again a minute later")
advance(6); run_delayed()
-- a load (also one during the session) restarts the count
WORLD.calls = {}
fire(F_LOAD, "pre", p(nil), p(host_pc), p(3), p(true))
for _ = 1, 30 do advance(16); sc.tick() end
check(not called("AutoSaveGame"), "a load restarts the 10 minutes")
cfg.set("coop_autosave", false)
WORLD.calls = {}
for _ = 1, 20 do advance(16); sc.tick() end
check(not called("AutoSaveGame") and not called("EventSave:true"), "coop_autosave=false: the game's setting decides")
cfg.set("coop_autosave", true)
run_delayed()
WORLD.cvars["Game.AutoSave"] = true
WORLD.timer = true

print("save now (opening a single-player world for friends)")
do
    S.role = "standalone"; WORLD.role = "standalone"
    S.remote, S.remote_pcs = {}, {}
    local real_pawn = ue.local_pawn
    ue.local_pawn = function() return host_char end
    run_delayed()
    -- a save that runs: done after the game's file check, with the slot
    WORLD.calls = {}
    local got = nil
    sc.save_now("test", function(ok, why, slot) got = { ok = ok, why = why, slot = slot } end)
    check(called("SaveGameToSlot"), "save now: the game's SaveGameToSlot (current slot)")
    advance(0.3); run_delayed()
    check(got == nil, "save now: not done before the save starts")
    host_save({})
    advance(0.3); run_delayed()
    check(got and got.ok == true and got.slot == "MySlot", "save now: done after the file check, slot MySlot ("
        .. tostring(got and got.why) .. ")")
    -- no save starts: false after 6 s
    got = nil
    WORLD.calls = {}
    sc.save_now("test", function(ok, why) got = { ok = ok, why = why } end)
    for _ = 1, 30 do advance(0.25); run_delayed() end
    check(got and got.ok == false and tostring(got.why):find("no save started", 1, true),
        "save now: no save started -> false (" .. tostring(got and got.why) .. ")")
    -- a dead character: refused, nothing saved
    got = nil
    WORLD.calls = {}
    host_char._p["PlayerDead?"] = true
    sc.save_now("test", function(ok, why) got = { ok = ok, why = why } end)
    check(got and got.ok == false and not called("SaveGameToSlot"), "save now: dead character -> refused, no save")
    host_char._p["PlayerDead?"] = false
    ue.local_pawn = real_pawn
    S.role = "host"; WORLD.role = "host"
    S.remote, S.remote_pcs = { [cl_pc:GetFullName()] = { pc = cl_pc, name = "Friend", pawn = cl_char } }, { cl_pc }
end

print("client save")
clear_log()
S.role = "client"; WORLD.role = "client"
local own_pc = make_pc("BP_PlayerController_C_9", false, {})
local own_char = make_char("BP_PlayerCharacter_C_9", own_pc, { { 91, 1 } })
WORLD.client_pc = own_pc
WORLD.slot = "QuickSave20261110161000"
sh('mkdir "' .. SAVES .. '\\QuickSave20261110161000"')
wfile(SAVES .. "\\QuickSave20261110161000\\Thumb.sav", "thumb")
fire(F_SAVE, "pre", p(nil), p(own_pc), p(3))
check(WORLD.slot == "SDCoop_ClientTemp", "client save redirected to the throwaway slot")
check(tagged(own_char, "EMS_SkipSave"), "client's own character skip-save on the client")
fire(F_SAVE, "post", p(nil), p(node), p(own_pc), p(3))
fire(PC .. ":OnCompleted_9CDBA9034C950D925C1539BE037C23EF", "post", p(own_pc))
fire(PC .. ":OnCompleted_0E13F8DC4FF1E81D4DC55BB17E7EC154", "post", p(own_pc))
advance(1); run_delayed()
check(logged("[SAVE] client save #"), "client [SAVE] line")
check(rfile(SAVES .. "\\QuickSave20261110161000\\Thumb.sav") == nil, "thumbnail-only junk folder emptied")
local f = io.open(SAVES .. "\\QuickSave20261110161000\\x", "w")
check(f == nil, "junk folder removed")
if f then f:close() end
check(rfile(SAVES .. "\\MySlot\\Slot.sav") ~= nil, "real slot untouched")

print("backups")
S.role = "host"; WORLD.role = "host"
clear_log()
local ok = sc.after_backup(BACK .. "\\2026-11-13_10-00-00", 1)
check(ok == false or ok == true, "after_backup returns")
local p2 = io.popen('dir /B /AD "' .. BACK .. '"')
local names = {}
for l in p2:lines() do names[#names + 1] = l end
p2:close()
table.sort(names)
local auto = 0
for _, n in ipairs(names) do if n:match("^%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d$") then auto = auto + 1 end end
print("    backups left: " .. table.concat(names, ", "))
check(auto == 10, "10 automatic backups kept")
check(names[1] == "2026-11-04_10-00-00", "the oldest three removed")
local has_manual, has_bad = false, false
for _, n in ipairs(names) do if n == "manual_20261110_103313" then has_manual = true end if n == "2026-11-xx_bad" then has_bad = true end end
check(has_manual and has_bad, "manual / non-matching folders untouched")
clear_log()
sc.after_backup(BACK .. "\\none", 9)
check(logged("old backups kept"), "failed backup: nothing pruned")

print("report / commands / reset")
local lines = {}
sc.report(function(s) lines[#lines + 1] = s end)
check(#lines >= 6, "report printed " .. #lines .. " lines")
local reg = {}
sc.register_commands(function(name, _, fn) reg[name] = fn end)
check(reg.sdcoop_savecheck ~= nil, "sdcoop_savecheck registered")
fire(F_SAVE, "pre", p(nil), p(host_pc), p(3))
clear_log()
sc.reset("loadmap")
check(logged("still unfinished at a level change"), "reset drops the unfinished save")
check(sc.status_line():find("savecheck:", 1, true) ~= nil, "status line")

print("startup: the current slot is a wrapper's text, no save on disk")
local function fresh_start(slot)
    package.loaded["sdc_savecheck"] = nil
    local m = require("sdc_savecheck")
    S.role = "standalone"; WORLD.role = "standalone"
    WORLD.slot = slot
    os.remove(MODDIR .. "\\savecheck_client_slot.txt")
    m.install(S)
    clear_log()
    m.tick()
    return m
end
fresh_start("RemoteUnrealParam_00000222D764E2C8")
check(WORLD.slot == "MySlot", "current slot repaired to the newest real save (" .. tostring(WORLD.slot) .. ")")
check(logged("was a script value"), "repair line names the cause")
check(logged("[TOAST] [SAVE] Continue points to MySlot again"), "toast")
print("startup: the wrapper-named slot was saved into (on disk) -> kept")
ems_write("RemoteUnrealParam_00000222D764E2C8")
fresh_start("RemoteUnrealParam_00000222D764E2C8")
check(WORLD.slot == "RemoteUnrealParam_00000222D764E2C8", "a real save under that name stays current")
print("set_slot refuses a wrapper's text")
WORLD.slot = "SDCoop_ClientTemp"
wfile(MODDIR .. "\\savecheck_client_slot.txt", "RemoteUnrealParam: 00000222D764E2C8\n")
package.loaded["sdc_savecheck"] = nil
local m3 = require("sdc_savecheck")
m3.install(S)
clear_log()
m3.tick()
check(WORLD.slot ~= "RemoteUnrealParam: 00000222D764E2C8", "remembered wrapper text not used (" .. tostring(WORLD.slot) .. ")")

print(string.format("%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
