-- Mock harness: co-op sleep (sdc_respawn section 2b, config coop_sleep_all)
-- and the game clock log (sdc_sync.time_tick: hour lines, time jumps).
-- usage: lua mock_coopsleep.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails = 0
local function check(cond, what)
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
local registry = {}
local by_path = {}

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
    return nil
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:GetOwner() return self._p.__owner end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = { pre = pre, post = post }; return 1, 2 end
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

setmetatable(by_path, { __index = function(_, k)
    if k:find(":") then return new_obj("Function", k) end
    return nil
end })

local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {})
local net_mode = "listen"
ksl._m.IsStandalone = function() return net_mode == "standalone" end
ksl._m.IsServer = function() return net_mode ~= "client" end
ksl._m.K2_IsTimerActive = function() return true end
ksl._m.GetCommandLine = function() return "" end
rawset(by_path, "/Script/Engine.Default__KismetSystemLibrary", ksl)
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {})
rawset(by_path, "/Script/Engine.Default__GameplayStatics", gps)

-- ------------------------------------------------------------ modules
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text) toasts[#toasts + 1] = text end
local lines = {}
log.info = function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    lines[#lines + 1] = ok and s or tostring(fmt)
end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat) then return l end end
    return nil
end
local function toasted(text)
    for _, t in ipairs(toasts) do if t == text then return true end end
    return false
end
local ctx = require("sdc_ctx")
ctx.SCOPE_API = 1
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... } }; return true end
net.broadcast = function(list, kind, ...)
    for _, pc in ipairs(list or {}) do sent[#sent + 1] = { to = pc, kind = kind, args = { ... } } end
end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
local function sent_kind(kind, a1)
    for _, m in ipairs(sent) do
        if m.kind == kind and (a1 == nil or m.args[1] == a1) then return m end
    end
    return nil
end
local players = require("sdc_players")
local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end
local respawn = require("sdc_respawn")
local sync = require("sdc_sync")

local S = { role = "host", remote = {}, remote_pcs = {}, spawned = {}, in_menu = false, menu_since = 0 }
package.loaded["sdc_session"] = { state = S }
players.init(S, { remote_record = function(pc) return S.remote[pc:GetFullName()] end })
cfg.values.player_name = "Host"

-- ------------------------------------------------------------ the world
local SLEEP_FN = "/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C:"
    .. "BndEvt__Button_60_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local EXIT_FN = "/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C:Exit"

local sky = new_obj("Ultra_Dynamic_Sky_C", "Ultra_Dynamic_Sky_0", { ["Time of Day"] = 2105, ["Transitioning Time"] = false,
    ["Animate Time of Day"] = true, Month = 7, Day = 15, Year = 2027, ["Day Length"] = 30, ["Night Length"] = 15 }, {})
local transitions = {}
sky._m["Transition Time of Day"] = function(self, to, dur, ease, exp, back)
    transitions[#transitions + 1] = { to = to, dur = dur, back = back }
    self._p["Transition Time A"] = self._p["Time of Day"]
    self._p["Transition Time B"] = to
    self._p["Transitioning Time"] = true
end
local gws = new_obj("UDW_State", "GWS", { Snow = 3.0, ["Material Snow Coverage"] = 0.94, Rain = 0, Dust = 0 }, {})
local snowtype = new_obj("UDS_Weather_Settings_C", "Snow", {}, {})
local mgr = new_obj("Random_Weather_Variation_C", "Random Weather Manager", { ["Target Random Weather Type"] = snowtype }, {})
new_obj("Ultra_Dynamic_Weather_C", "Ultra_Dynamic_Weather_1", { Season = 1.02, ["Global Weather State"] = gws,
    ["Random Weather Manager"] = mgr }, {})

local widgets = {}
local function new_sleep_ui()
    local label = new_obj("TextBlock", "SleepingText", {}, {})
    label._m.SetText = function(self, t) self._p.__text = t end
    label._m.SetVisibility = function(self, v) self._p.__vis = v end
    local choices = new_obj("VerticalBox", "Choices", {}, {})
    choices._m.SetVisibility = function(self, v) self._p.__vis = v end
    local w = new_obj("SleepingUI_C", "SleepingUI_C_" .. (#widgets + 1), { Choices = choices, SleepingText = label,
        BlurAnim = new_obj("WidgetAnimation", "BlurAnim", {}, {}), __inview = true }, {})
    w._m.IsInViewport = function(self) return self._p.__inview end
    w._m.PlayAnimationForward = function() end
    -- the Blueprint's Exit, then the mod's post hook
    w._m.Exit = function(self)
        self._p.__inview = false
        local h = hooks[EXIT_FN]
        if h then h.pre(param(self)) end
    end
    widgets[#widgets + 1] = w
    return w
end
local hud = new_obj("HUD_Game_C", "HUD", {}, {})
hud._m.ShowSleepWidget = function(self, show) if show then self._p.SleepUI = new_sleep_ui() end end

local med = new_obj("MedicalComponent_C", "Med", { Health = 100, MaxHealth = 100 }, {})
local host_pawn = new_obj("BP_PlayerCharacter_C", "Host", { MedicalComponent = med, ["PlayerDead?"] = false }, {})
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_pawn, DaysSurvived = 7,
    Player = new_obj("LocalPlayer", "LP", {}, {}) }, {})
host_pc._m.IsLocalController = function() return true end
host_pc._m.GetHUD = function() return hud end
host_pawn._p.Controller = host_pc
registry["PlayerController"] = { host_pc }
local conn = new_obj("IpConnection", "Conn", {}, {})
local rpawn = new_obj("BP_PlayerCharacter_C", "Friend", { ["PlayerDead?"] = false }, {})
local rpc = new_obj("BP_PlayerController_C", "RemotePC", { NetConnection = conn, Pawn = rpawn }, {})
local rkey = rpc:GetFullName()
S.remote[rkey] = { key = rkey, pc = rpc, index = 1, name = "Friend", hello = true, pawn = rpawn }
S.remote_pcs = { rpc }

respawn.install(S)
run_delayed()
check(loops.respawn ~= nil, "respawn tick scheduled")
loops.respawn()
local sleeph, exith = hooks[SLEEP_FN], hooks[EXIT_FN]
check(sleeph ~= nil and exith ~= nil, "host: Sleep button and Exit hooks registered")
local handlers = net.handlers

-- what the game's Sleep button does on the pressing machine, then the mod's post hook
local function press_sleep()
    local w = hud._p.SleepUI or new_sleep_ui()
    hud._p.SleepUI = w
    sky["Transition Time of Day"](sky, 650, 2, 7, 2, false)
    sleeph.pre(param(w))
    return w
end
local function reset_round(tod)
    sent, toasts, transitions = {}, {}, {}
    sky._p["Time of Day"] = tod
    sky._p["Transitioning Time"] = false
    hud._p.SleepUI = nil
end
local function args_of(m) return m and table.concat(m.args, "|") or "-" end

-- ------------------------------------------------------------ A. host alone in bed: waits
print("A. host sleeps, client awake")
reset_round(2105)
local w1 = press_sleep()
check(#transitions == 2 and transitions[2].to == 2105 and transitions[2].back == true and transitions[2].dur < 1,
    "the game's skip held: Transition Time of Day(press time, 0.1 s, backwards)")
local st = sent_kind("BED", "sleepst")
check(st and st.to == rpc and args_of(st) == "sleepst|wait|1|2|Host|in", "client told: wait 1/2, Host in (" .. args_of(st) .. ")")
check(toasted("Ждём, пока уснут все игроки (1/2)."), "host: the game's notification 'waiting 1/2'")
check(logged("asleep 1/2, awake: Friend") ~= nil, "host log: asleep 1/2, awake Friend")
T = T + 2.5
w1:Exit()    -- the game's own end of the sleep animation
run_delayed()
local w2 = hud._p.SleepUI
check(w2 ~= w1 and w2 and w2._p.__inview, "the game's sleep window opened again")
check(w2 and w2._p.SleepingText._p.__text == "Ждём, пока уснут все игроки (1/2)\nEsc — встать", "waiting text in the sleep window")
check(w2 and w2._p.Choices._p.__vis == 2, "choices hidden (sleeping state)")
loops.respawn()
check(#transitions == 2, "tick: no skip while the client is awake")

-- ------------------------------------------------------------ B. the client sleeps too: skip
print("B. client sleeps: everyone asleep")
sent = {}
handlers.SLEEP({ "2" }, rpc)
check(#transitions == 3 and transitions[3].to == 650 and transitions[3].dur == 2 and transitions[3].back == false,
    "host ran the game's Transition Time of Day(650, 2 s)")
st = sent_kind("BED", "sleepst")
check(st and args_of(st) == "sleepst|skip|2|2|Friend|in", "client told: skip (" .. args_of(st) .. ")")
check(toasted("Все уснули — ночь проходит."), "host: 'everyone asleep' notification")
check(w2._p.SleepingText._p.__text == "Все уснули — ночь проходит.", "host's sleep window says the night passes")
check(w2._p.__inview, "host's window still open during the transition")
run_delayed()
check(not w2._p.__inview, "host's window closed after the transition")
check(respawn.stats.sleeps == 1, "sleeps counted")
check(not sent_kind("BED", "sleepst") or sent_kind("BED", "sleepst").args[2] == "skip", "no 'got up' after our own close")

-- ------------------------------------------------------------ C. Esc in the waiting window
print("C. host gets up (Esc)")
reset_round(2200)
local w3 = press_sleep()
T = T + 2.6
w3:Exit()
run_delayed()
local w4 = hud._p.SleepUI
check(w4 ~= w3 and w4._p.__inview, "waiting window open")
sent = {}
w4:Exit()   -- Esc: SleepingUI's Tick calls Exit
st = sent_kind("BED", "sleepst")
check(st and args_of(st) == "sleepst|wait|0|2|Host|out", "client told: Host got up (" .. args_of(st) .. ")")
check(respawn.status_line():find("asleep=0 waiting_here=false", 1, true) ~= nil, "nobody asleep")
run_delayed()
check(hud._p.SleepUI == w4, "no window reopened after getting up")

-- ------------------------------------------------------------ D. Esc during the animation
print("D. Esc during the sleep animation")
reset_round(2210)
local w5 = press_sleep()
T = T + 1
w5:Exit()
run_delayed()
check(hud._p.SleepUI == w5, "got up during the animation: no waiting window")
check(logged("Esc during the sleep animation") ~= nil, "logged")

-- ------------------------------------------------------------ E. client first, host last
print("E. client sleeps first, the host last")
reset_round(2230)
T = T + 10
handlers.SLEEP({ "2" }, rpc)
st = sent_kind("BED", "sleepst")
check(st and args_of(st) == "sleepst|wait|1|2|Friend|in", "client: wait 1/2 (" .. args_of(st) .. ")")
check(toasted("Friend спит (1/2): ночь пройдёт, когда уснут все."), "awake host told who sleeps")
sent = {}
press_sleep()
check(#transitions == 1 and transitions[1].to == 650, "host last: only the game's own transition, not held")
st = sent_kind("BED", "sleepst")
check(st and args_of(st) == "sleepst|skip|2|2|Host|in", "client told: skip (" .. args_of(st) .. ")")
T = T + 3
loops.respawn()
check(respawn.status_line():find("asleep=0", 1, true) ~= nil, "after the skip nobody is asleep")

-- ------------------------------------------------------------ F. the client gets up
print("F. client gets up")
reset_round(2300)
T = T + 30
handlers.SLEEP({ "2" }, rpc)
sent = {}
handlers.SLEEP({ "x" }, rpc)
st = sent_kind("BED", "sleepst")
check(st and args_of(st) == "sleepst|wait|0|2|Friend|out", "got up: wait 0/2 (" .. args_of(st) .. ")")

-- ------------------------------------------------------------ G. not night
print("G. Sleep at noon (outside 19:30-06:30)")
reset_round(1210)
T = T + 30
press_sleep()
check(#transitions == 2 and transitions[2].to == 1210, "noon: the game's skip held")
st = sent_kind("BED", "sleepst")
check(st and st.args[2] == "early", "early sent (" .. args_of(st) .. ")")
check(toasted("Ещё рано спать, подождите до 19:30."), "noon: the game's 'too early' words")
T = T + 3
local before = #widgets
hud._p.SleepUI:Exit()
run_delayed()
check(#widgets == before, "no waiting window at noon")
-- waiting until the morning
reset_round(600)
T = T + 30
local wm = press_sleep()
T = T + 2.6
wm:Exit()
run_delayed()
local wm2 = hud._p.SleepUI
sky._p["Time of Day"] = 640
sent = {}
loops.respawn()
st = sent_kind("BED", "sleepst")
check(st and st.args[2] == "late", "morning while waiting: late sent (" .. args_of(st) .. ")")
check(toasted("Наступило утро — вы встаёте."), "morning: notification")
check(not wm2._p.__inview, "morning: the sleep window closed")

-- ------------------------------------------------------------ H. the older rule
print("H. coop_sleep_all off")
reset_round(2100)
T = T + 30
cfg.values.coop_sleep_all = false
handlers.SLEEP({ "2" }, rpc)
st = sent_kind("BED", "sleepst")
check(st and st.args[2] == "off", "client told: off")
check(#transitions == 1 and transitions[1].to == 650, "older rule: the client's sleep skips the night")
sent = {}
press_sleep()
check(#transitions == 2, "older rule: the host's own sleep not held")
check(sent_kind("MSG", "bed_slept") ~= nil, "client told the host sleeps")
cfg.values.coop_sleep_all = nil

-- ------------------------------------------------------------ I. an older client
print("I. older client (SLEEP without a version)")
reset_round(2100)
T = T + 30
handlers.SLEEP({}, rpc)
check(#transitions == 0, "an older client alone: no skip")
check(logged("an older mod") ~= nil, "logged as an older mod")
T = T + 21
loops.respawn()
check(logged("no longer counts as asleep") ~= nil, "its sleep ends after 20 s")

-- ------------------------------------------------------------ J. hurt while waiting
print("J. hurt in bed")
reset_round(2100)
T = T + 30
local w6 = press_sleep()
T = T + 2.6
w6:Exit()
run_delayed()
local w7 = hud._p.SleepUI
loops.respawn()
med._p.Health = 80
sent = {}
loops.respawn()
check(not w7._p.__inview, "hurt: the sleep window closed")
st = sent_kind("BED", "sleepst")
check(st and args_of(st) == "sleepst|wait|0|2|Host|out", "hurt: got up (" .. args_of(st) .. ")")
med._p.Health = 100

-- ------------------------------------------------------------ K. the client's side
print("K. client side")
S.role = "client"
S.client = {}
net_mode = "client"
loops.respawn()
reset_round(2100)
T = T + 30
local cw = press_sleep()
check(#transitions == 2 and transitions[2].to == 2100 and transitions[2].back == true, "client: own copy's skip held")
local m = sent_kind("SLEEP")
check(m and m.to == "host" and m.args[1] == "2", "client: SLEEP 2 sent")
handlers.BED({ "sleepst", "wait", "1", "2", "Friend", "in" })
check(toasted("Ждём, пока уснут все игроки (1/2)."), "client: waiting notification")
T = T + 2.5
cw:Exit()
run_delayed()
local cw2 = hud._p.SleepUI
check(cw2 ~= cw and cw2._p.__inview and cw2._p.SleepingText._p.__text:find("(1/2)", 1, true), "client: waiting window")
sent = {}
handlers.BED({ "sleepst", "skip", "2", "2", "Host", "in" })
run_delayed()
check(not cw2._p.__inview, "client: window closed after the skip")
check(sent_kind("SLEEP") == nil, "client: no 'got up' after the skip")
-- again, then Esc
reset_round(2200)
T = T + 30
local cw3 = press_sleep()
handlers.BED({ "sleepst", "wait", "1", "2", "Friend", "in" })
T = T + 2.5
cw3:Exit()
run_delayed()
sent = {}
hud._p.SleepUI:Exit()
m = sent_kind("SLEEP")
check(m and m.args[1] == "x", "client: Esc sends SLEEP x")
-- an older host never answers
reset_round(2200)
T = T + 30
press_sleep()
T = T + 7
loops.respawn()
check(logged("no answer from the host") ~= nil, "client: an older host's silence ends the waiting")

-- ------------------------------------------------------------ L. the game clock log
print("L. clock log")
lines = {}
S.role = "host"
net_mode = "listen"
S.in_menu = false
sky._p["Animate Time of Day"] = false
sky._p["Time of Day"] = 960
sync.time_tick()
check(logged("time: host sky Ultra_Dynamic_Sky_0 at 09:36") ~= nil, "new sky logged")
T = T + 1
sky._p["Animate Time of Day"] = true
sky._p["Time of Day"] = 1739.6
sync.time_tick()
check(logged("sky started at 17:23 %(it showed 09:36 while the world loaded%): the save's time, not a time skip") ~= nil,
    "load: the save's time, not a skip (UDS 1739.6 = 17:23)")
T = T + 1
sky._p["Time of Day"] = 1740.3
sync.time_tick()
check(logged("time: 17:00 day 7, date 2027%-07%-15, season summer %(1.02%)") ~= nil, "first hour line (start)")
check(logged("weather Snow: snow 3.0, snow cover 0.94") ~= nil, "hour line: weather and snow")
T = T + 40
sky._p["Time of Day"] = 1770
sync.time_tick()
T = T + 42
sky._p["Time of Day"] = 1801
sync.time_tick()
check(logged("time: 18:00 day 7") ~= nil, "hour line at 18:00")
check(logged("night length 15 min") ~= nil, "day / night length in the hour line")
lines = {}
sync.note_time_cause("sleep: test cause")
T = T + 1
sky._p["Time of Day"] = 2350
sync.time_tick()
T = T + 1
sky._p["Time of Day"] = 300
sync.time_tick()
T = T + 1
sky._p["Time of Day"] = 650
sync.time_tick()
T = T + 1
sky._p["Time of Day"] = 651
sync.time_tick()
check(logged("time: jump 18:00 %-> 06:30 %(%+12.49 game h in 3.0 s%): sleep: test cause") ~= nil,
    "jump with its cause (" .. tostring(lines[1]) .. ")")
check(logged("after the jump") ~= nil, "hour line after the jump")
lines = {}
T = T + 1
sky._p["Time of Day"] = 600
sync.time_tick()
T = T + 1
sky._p["Time of Day"] = 601
sync.time_tick()
check(logged("time: jump 06:30 %-> 06:00 %(%-0.51 game h") ~= nil and logged("no sleep, load or join seen") ~= nil,
    "backwards jump without a known cause")
-- a client logs jumps, no hour lines
lines = {}
S.role = "client"
T = T + 60
sky._p["Time of Day"] = 700
sync.time_tick()
T = T + 60
sky._p["Time of Day"] = 760
sync.time_tick()
check(logged("time: 07:00") == nil, "client: no hour lines")
S.in_menu = true
sync.time_tick()

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
