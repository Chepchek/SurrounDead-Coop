-- Mock harness for sdc_ue's shared player-character list (find_all_recent of
-- a watched class, player_chars, watch_new): FindAllOf scans only when a new
-- character was constructed (NotifyOnNewObject) or after the long TTL, a
-- destroyed character never comes out, the watch falls back to the short TTL
-- when a character appears without a notification. Real sdc_ue + sdc_log.
-- usage: lua mock_ue_playerlist.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, passed = 0, 0
local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = tostring(s) end
local function out(s) real_print(s) end
local function check(cond, what)
    if cond then passed = passed + 1; out("  ok   " .. what) else fails = fails + 1; out("  FAIL " .. what) end
end
local function count_lines(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat) then n = n + 1 end end
    return n
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
Obj.__index = Obj
local next_addr = 8192
local world = {}          -- class -> list (what FindAllOf sees)
local function new_char(short)
    next_addr = next_addr + 16
    local o = setmetatable({ _short = short, _addr = next_addr, _valid = true }, Obj)
    world.BP_PlayerCharacter_C = world.BP_PlayerCharacter_C or {}
    table.insert(world.BP_PlayerCharacter_C, o)
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetAddress() return self._addr end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
-- destroyed: gone from FindAllOf, the wrapper reports invalid
local function destroy(o)
    o._valid = false
    local l = world.BP_PlayerCharacter_C
    for i = #l, 1, -1 do if l[i] == o then table.remove(l, i) end end
end

-- ------------------------------------------------------------ UE4SS globals
local scans = {}
function FindAllOf(cls)
    scans[cls] = (scans[cls] or 0) + 1
    local l = world[cls]
    if not l or #l == 0 then return nil end   -- UE4SS returns nil for none
    local copy = {}
    for i, o in ipairs(l) do copy[i] = o end
    return copy
end
local notify = {}        -- path -> callback
local notify_regs = 0
NotifyOnNewObject = function(path, fn)
    notify_regs = notify_regs + 1
    notify[path] = fn
end
function FindFirstOf() return nil end
function StaticFindObject() return nil end
function ExecuteInGameThread(f) f() end
function LoopAsync() end
function FName(s) return { ToString = function() return s end } end

local log = require("sdc_log")
local ue = require("sdc_ue")
local CLS = "BP_PlayerCharacter_C"
local PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"

local function names(list)
    local t = {}
    for _, o in ipairs(list) do t[#t + 1] = o._short end
    table.sort(t)
    return table.concat(t, ",")
end
-- UE4SS constructs a new character: the notification fires inside the construction
local function spawn(short)
    local o = new_char(short)
    local cb = notify[PATH]
    if cb then
        local r = cb(o)
        assert(r == nil, "new-object callback returned a value (UE4SS would unregister it)")
    end
    return o
end

-- ------------------------------------------------------------ before the watch
out("== unwatched class: unchanged behaviour")
local H = new_char("Host")
local C = new_char("Client")
local l1 = ue.find_all_recent(CLS)
check(#l1 == 2 and scans[CLS] == 1, "first read scans")
advance(0.1)
ue.find_all_recent(CLS)
check(scans[CLS] == 1, "within 0.25 s: shared")
advance(0.2)
ue.find_all_recent(CLS)
check(scans[CLS] == 2, "after 0.25 s: scanned again")
check(ue.player_chars and #ue.player_chars() == 2, "player_chars without the watch: the 0.25 s list")
local s0 = scans[CLS]
ue.player_chars(true)
check(scans[CLS] == s0 + 1, "player_chars(fresh) without the watch: a new scan")

-- ------------------------------------------------------------ the watch
out("== watch")
local okw = ue.watch_player_chars()
check(okw == true and notify[PATH] ~= nil, "watch registered on " .. PATH)
check(ue.watch_player_chars() == true and notify_regs == 1, "second call: no second registration")
check(count_lines("shared BP_PlayerCharacter_C list rescanned on a new one") == 1, "watch logged")
local s1 = scans[CLS]
local l2 = ue.find_all_recent(CLS)
check(scans[CLS] == s1 + 1 and #l2 == 2, "first read after the watch: one scan (dirty)")
for _ = 1, 9 do advance(0.1); ue.find_all_recent(CLS) end
check(scans[CLS] == s1 + 1, "0.9 s of reads: no new scan")
advance(0.15)
ue.find_all_recent(CLS)
check(scans[CLS] == s1 + 2, "after 1 s: scanned again")

out("== destroyed character never comes out")
destroy(C)
local l3 = ue.find_all_recent(CLS)
check(#l3 == 1 and l3[1] == H, "destroyed client character left out at once (no scan)")
check(scans[CLS] == s1 + 2, "...without a new scan")
local l3b = ue.player_chars()
check(#l3b == 1 and names(l3b) == "Host", "player_chars too")
local touched = false
for _, o in ipairs(ue.player_chars(true)) do if o == C then touched = true end end
check(not touched, "player_chars(fresh) with a trusted watch: no destroyed one")

out("== new character listed without waiting for the TTL")
advance(0.1)
local s2 = scans[CLS]
local C2 = spawn("Client2")
local l4 = ue.find_all_recent(CLS)
check(scans[CLS] == s2 + 1 and names(l4) == "Client2,Host", "new character: rescanned on the next read")
check(count_lines("new%-object notification for BP_PlayerCharacter_C works") == 1, "watch confirmed in the log")
advance(0.1)
ue.find_all_recent(CLS)
check(scans[CLS] == s2 + 1, "then shared again")
local ps = ue.player_chars(true)
check(scans[CLS] == s2 + 1 and #ps == 2, "player_chars(fresh) with a trusted watch: no scan")

out("== copies")
local l5 = ue.find_all_recent(CLS)
l5[1] = nil; l5[2] = "junk"; l5[3] = "junk"
local l6 = ue.find_all_recent(CLS)
check(#l6 == 2 and type(l6[1]) == "table" and type(l6[2]) == "table", "caller changing its copy does not change the list")

out("== a fresh find_all feeds the shared list")
advance(0.95)   -- the shared list is 1.05 s old now
local s3 = scans[CLS]
ue.find_all(CLS)
ue.find_all_recent(CLS)
check(scans[CLS] == s3 + 1, "find_all + read: one scan")
advance(0.5)
ue.find_all_recent(CLS)
check(scans[CLS] == s3 + 1, "the find_all result is the shared list")

out("== an explicit ttl longer than the watch TTL is kept")
advance(1.0)   -- the list is 1.5 s old now
local s4 = scans[CLS]
ue.find_all_recent(CLS, 2.0)
check(scans[CLS] == s4, "ttl 2 s: 1.5 s old list shared")
ue.find_all_recent(CLS)
check(scans[CLS] == s4 + 1, "default ttl: the same list is too old (1 s)")

out("== forget_world")
ue.forget_world()
local s5 = scans[CLS]
ue.find_all_recent(CLS)
check(scans[CLS] == s5 + 1, "after forget_world: scanned")

out("== a character the notification missed")
advance(1.1)
local s6 = scans[CLS]
local miss = new_char("Sneaky")          -- constructed without a notification
local l7 = ue.find_all_recent(CLS)
check(scans[CLS] == s6 + 1 and names(l7) == "Client2,Host,Sneaky", "found by the 1 s scan")
check(count_lines("without a new%-object notification") == 1, "watch distrust logged")
advance(0.3)
ue.find_all_recent(CLS)
check(scans[CLS] == s6 + 2, "back to 0.25 s")
local s7 = scans[CLS]
ue.player_chars(true)
check(scans[CLS] == s7 + 1, "player_chars(fresh) scans again")
destroy(miss)
check(names(ue.find_all_recent(CLS)) == "Client2,Host", "destroyed still left out")
advance(0.3)
spawn("Late")
ue.find_all_recent(CLS)
check(count_lines("without a new%-object notification") == 1, "logged once only")

out("== no NotifyOnNewObject")
-- a class that is not watched keeps the plain 0.25 s list (a watched one: 1 s)
-- (2026-11-13: ue.watch_state, unused by the mod, is gone; read the behaviour)
local function not_watched(cls)
    ue.find_all_recent(cls)
    local n0 = scans[cls] or 0
    advance(0.3)
    ue.find_all_recent(cls)
    return (scans[cls] or 0) == n0 + 1
end
local saved = NotifyOnNewObject
NotifyOnNewObject = nil
local okn = ue.watch_new("BP_Other_C", "/Game/X.BP_Other_C")
check(okn == false and not_watched("BP_Other_C"), "unavailable: not watched")
NotifyOnNewObject = function() error("boom") end
local okf = ue.watch_new("BP_Other_C", "/Game/X.BP_Other_C")
check(okf == false and not_watched("BP_Other_C") and count_lines("FAILED") >= 1, "registration error: not watched, logged")
NotifyOnNewObject = saved

out("== empty world")
world.BP_PlayerCharacter_C = {}
advance(2)
local le = ue.find_all_recent(CLS)
check(type(le) == "table" and #le == 0, "no character: empty list")

real_print(string.format("ue playerlist: %d passed, %d failed", passed, fails))
real_print(fails == 0 and string.format("%d checks, ALL OK", passed) or string.format("%d checks, %d FAILED", passed + fails, fails))
os.exit(fails == 0 and 0 or 1)
