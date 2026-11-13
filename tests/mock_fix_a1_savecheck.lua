-- Mock test (critic fixes 2026-11-13, group A1): sdc_savecheck / sdc_progress.
--   A3: with savecheck = false the record still follows a save to its end:
--       save_now (opening a world for friends) waits for the game's file
--       check instead of finishing 4 s after the start (EMS could still write);
--   B2: the four "trigger" hooks are registered only on the host / in single
--       player and with savecheck on;
--   B5: AsyncLoadActors through sdc_ue.hook_native (pre only);
--   progress A5: DistanceTravelled is not a "major" value (no PSPROG every 3 s).
-- usage: lua mock_fix_a1_savecheck.lua <scripts dir>
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
local REAL = { sdc_savecheck = true, sdc_progress = true, sdc_log = true, sdc_config = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)
FName = function(s) return s end
-- no LOCALAPPDATA: no save folder is read or written
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return "" end return real_getenv(k) end

-- clock (savecheck keeps os.clock) and delayed calls
local T = 1000
os.clock = function() return T end
local delayed = {}
local function advance(s)
    local stop = T + s
    while true do
        local nxt = nil
        for _, d in ipairs(delayed) do if d.at <= stop and (not nxt or d.at < nxt.at) then nxt = d end end
        if not nxt then break end
        for i, d in ipairs(delayed) do if d == nxt then table.remove(delayed, i) break end end
        T = math.max(T, nxt.at)
        nxt.fn()
    end
    T = stop
end

local HOOKS, NATIVE = {}, {}
RegisterHook = function(path, pre, post) HOOKS[path] = { pre = pre, post = post }; return 1, 2 end
local W = { slot = "MySlot" }
local host_pc = { key = "HostPC", IsLocalController = function() return true end }
local pawn = { key = "HostChar", ["PlayerDead?"] = false }
local F_SAVE = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
local F_LOAD = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors"
local PC = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"
local ACTORS_DONE = PC .. ":OnCompleted_9CDBA9034C950D925C1539BE037C23EF"
local CHECK_DONE = PC .. ":OnCompleted_0E13F8DC4FF1E81D4DC55BB17E7EC154"
local GM_AUTO = "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:AutoSaveGame"
local QUICK = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:InpActEvt_IA_QuickSave_K2Node_EnhancedInputActionEvent_2"
local function p(v) return { get = function() return v end } end
-- the game's SaveGameToSlot: EMS starts (the AsyncSaveActors hooks), the rest comes later
local EMS_REFUSES = false
host_pc.SaveGameToSlot = function()
    local h = HOOKS[F_SAVE]
    h.pre(p(nil), p(host_pc), p(3))
    h.post(p(nil), p((not EMS_REFUSES) and { key = "node" } or nil), p(host_pc), p(3))
end

local ue = stub()
ue.valid = function(o) return type(o) == "table" end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.prop = function(o, k) return type(o) == "table" and rawget(o, k) or nil end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.str = function(v) if v == nil then return "" end return tostring(v) end
ue.local_pc = function() return host_pc end
ue.local_pawn = function() return pawn end
ue.in_main_menu = function() return false end
ue.ems_current_slot = function() return W.slot end
ue.find_object = function() return { key = "fn" } end
ue.find_first = function() return nil end
ue.find_all = function() return {} end
ue.delay = function(_, ms, fn) delayed[#delayed + 1] = { at = T + ms / 1000, fn = fn } end
ue.hook_native = function(path, key, fn) NATIVE[path] = { key = key, fn = fn }; return true end
package.loaded["sdc_ue"] = ue

local log = require("sdc_log")
local lines = {}
log.info = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
log.warn = log.info
local function logged(pat) for _, l in ipairs(lines) do if l:find(pat, 1, true) then return l end end return nil end
local cfg = require("sdc_config")

print("B2 / B5: hooks on a client")
local S = { role = "client", remote = {}, remote_pcs = {} }
package.loaded["sdc_session"] = { state = S, world_reset_hooks = {} }
local sc = require("sdc_savecheck")
sc.install(S)
check(HOOKS[F_SAVE] and HOOKS[F_SAVE].pre and HOOKS[F_SAVE].post, "AsyncSaveActors: pre + post")
check(NATIVE[F_LOAD] and NATIVE[F_LOAD].key == "savecheck" and HOOKS[F_LOAD] == nil,
    "AsyncLoadActors through sdc_ue.hook_native (pre only)")
check(HOOKS[GM_AUTO] == nil and HOOKS[QUICK] == nil, "client: no trigger hooks")
check(HOOKS[ACTORS_DONE] and HOOKS[CHECK_DONE], "the save's end hooks are there")
print("B2: savecheck off on the host: still no trigger hooks; on: registered")
S.role = "host"
cfg.values.savecheck = false
advance(4); sc.tick()
check(HOOKS[GM_AUTO] == nil, "savecheck off: no trigger hooks")
cfg.values.savecheck = nil
advance(4); sc.tick()
check(HOOKS[GM_AUTO] ~= nil and HOOKS[QUICK] ~= nil, "host, savecheck on: trigger hooks registered")

print("A3: save_now with savecheck off waits for the save's end")
S.role = "standalone"
cfg.values.savecheck = false
lines = {}
local got = nil
sc.save_now("test", function(ok, why, slot) got = { ok = ok, why = why, slot = slot } end)
advance(5)
check(got == nil, "5 s after the start, actors not written yet: still waiting (savecheck off)")
HOOKS[ACTORS_DONE].pre(p(host_pc))
advance(1)
check(got == nil, "actors written 1 s ago, no file check yet: still waiting")
HOOKS[CHECK_DONE].pre(p(host_pc))
advance(0.5)
check(got and got.ok == true and got.slot == "MySlot", "the game's file check: done (" .. tostring(got and got.why) .. ")")
check(not logged("[SAVE] save #"), "no [SAVE] save line with savecheck off")
check(sc.last and sc.last.ok == true, "status: the last save is known")
print("A3: actors written, the file check never reports: done 4 s after the actors")
got = nil
sc.save_now("test", function(ok, why) got = { ok = ok, why = why } end)
advance(1)
HOOKS[ACTORS_DONE].pre(p(host_pc))
advance(3)
check(got == nil, "3 s after the actors: waiting")
advance(1.5)
check(got and got.ok == true and tostring(got.why):find("file check not reported", 1, true), "4 s after the actors: done ("
    .. tostring(got and got.why) .. ")")
HOOKS[CHECK_DONE].pre(p(host_pc))   -- that save's late file check ends its record
print("A3: EMS refuses the save (another one running)")
got = nil
EMS_REFUSES = true
sc.save_now("test", function(ok, why) got = { ok = ok, why = why } end)
advance(0.5)
check(got and got.ok == false and not tostring(got.why):find("another save", 1, true),
    "EMS did not start it: not ok at once (" .. tostring(got and got.why) .. ")")
EMS_REFUSES = false
cfg.values.savecheck = nil

print("progress A5: DistanceTravelled is not major")
local prog = require("sdc_progress")
local key = prog.major_key("L.CurrentLevel=3;J.DistanceTravelled=12345;J.ZombieKills=7;L.CurrentXP=10")
check(key:find("J.ZombieKills=7", 1, true) and key:find("L.CurrentLevel=3", 1, true), "level / kills are major: " .. key)
check(not key:find("DistanceTravelled", 1, true), "the distance is not")
check(prog.major_key("J.DistanceTravelled=1") == prog.major_key("J.DistanceTravelled=99999"), "walking alone changes nothing major")

print = real_print
print(string.format("fix_a1_savecheck: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
