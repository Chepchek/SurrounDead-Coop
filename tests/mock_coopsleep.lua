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
-- the HUD's health bar (BP_Ingame.HealthBar): CurrentPercent = what the host
-- sent / 100; TargetPercent is never touched by PB_SetPercent (stays 1.0)
local hpbar = new_obj("ProgressBarLinear_C", "HealthBar", { CurrentPercent = 1.0, TargetPercent = 1.0 }, {})
local ingame = new_obj("BP_Ingame_C", "BP_Ingame_C_0", { HealthBar = hpbar }, {})
local host_pawn = new_obj("BP_PlayerCharacter_C", "Host", { MedicalComponent = med, InGameUI = ingame,
    ["PlayerDead?"] = false }, {})
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_pawn, DaysSurvived = 7,
    Player = new_obj("LocalPlayer", "LP", {}, {}) }, {})
host_pc._m.IsLocalController = function() return true end
host_pc._m.GetHUD = function() return hud end
host_pawn._p.Controller = host_pc
registry["PlayerController"] = { host_pc }
local conn = new_obj("IpConnection", "Conn", {}, {})
-- the client's character on the host: its health is the game's own here
local rmed = new_obj("MedicalComponent_C", "FriendMed", { Health = 100, MaxHealth = 100 }, {})
local rpawn = new_obj("BP_PlayerCharacter_C", "Friend", { MedicalComponent = rmed, ["PlayerDead?"] = false }, {})
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
check(toasted("Вы теряете здоровье — вы проснулись."), "host hurt: 'you are losing health: you wake up' on screen")
check(logged("hurt: health 100 %-> 80%)") ~= nil, "host hurt: logged with the game's own health")
med._p.Health = 100

-- ------------------------------------------------------------ J2. a sleeping client hurt (the host's view)
print("J2. the host sees a sleeping client hurt")
reset_round(2100)
T = T + 30
handlers.SLEEP({ "2" }, rpc)
check(respawn.status_line():find("asleep=1", 1, true) ~= nil, "client asleep")
loops.respawn()
rmed._p.Health = 98     -- a small change (not a hit): still asleep
loops.respawn()
check(respawn.status_line():find("asleep=1", 1, true) ~= nil, "a fall of 2: still asleep")
rmed._p.Health = 99     -- regeneration
loops.respawn()
check(respawn.status_line():find("asleep=1", 1, true) ~= nil, "health going up: still asleep")
rmed._p.Health = 70     -- a zombie's hit on the host's copy of the client's character
sent = {}
lines = {}
loops.respawn()
check(respawn.status_line():find("asleep=0", 1, true) ~= nil, "hurt client no longer counts as asleep")
local beds = {}
for _, sm in ipairs(sent) do if sm.kind == "BED" then beds[#beds + 1] = sm end end
local hm = beds[1]
check(hm and hm.to == rpc and args_of(hm) == "sleepst|hurt|0|2|Friend|out",
    "the hurt client is told first: hurt (" .. args_of(hm) .. ")")
-- the mods up to 0.10.0 have no "hurt" (they ignore it): "off" closes their window
local om = beds[2]
check(om and om.to == rpc and args_of(om) == "sleepst|off|0|0|Friend|hurt",
    "then 'off' (event hurt) to the same client, for older mods (" .. args_of(om) .. ")")
local wm3 = beds[3]
check(wm3 and args_of(wm3) == "sleepst|wait|0|2|Friend|out", "then the count: wait 0/2 (" .. args_of(wm3) .. ")")
check(#beds == 3, "nothing else to the clients (" .. #beds .. " BED messages)")
check(logged("Friend was hurt while asleep %(health 99 %-> 70 on the host%)") ~= nil, "host log: who was hurt, health")
-- the client's own SLEEP x afterwards (it saw the hit on its HUD too): nothing more
sent = {}
handlers.SLEEP({ "x" }, rpc)
check(#sent == 0, "the client's own 'got up' after that: no second status")
-- the client's character away (no health readable): it stays asleep, no false wake
handlers.SLEEP({ "2" }, rpc)
rpc._p.Pawn = nil
loops.respawn()
check(respawn.status_line():find("asleep=1", 1, true) ~= nil, "no character on the host: still counted asleep")
rpc._p.Pawn = rpawn
rmed._p.Health = 100
handlers.SLEEP({ "x" }, rpc)
check(respawn.status_line():find("asleep=0", 1, true) ~= nil, "client got up")
-- a hit right after the press, before the host's next tick: the health at the press counts
handlers.SLEEP({ "2" }, rpc)
rmed._p.Health = 60
loops.respawn()
check(respawn.status_line():find("asleep=0", 1, true) ~= nil, "a hit in the first second after Sleep: the client gets up")
rmed._p.Health = 100

-- ------------------------------------------------------------ J3. a sleeping client dies (the host's view)
-- a death is not "hurt": the client gets its death screen, not the "hurt" words
print("J3. a sleeping client dies")
local function client_dies(health, dead_flag, what)
    handlers.SLEEP({ "x" }, rpc)
    rmed._p.Health, rpawn._p["PlayerDead?"] = 100, false
    handlers.SLEEP({ "2" }, rpc)
    loops.respawn()
    check(respawn.status_line():find("asleep=1", 1, true) ~= nil, what .. ": client asleep")
    rmed._p.Health, rpawn._p["PlayerDead?"] = health, dead_flag
    sent, lines = {}, {}
    loops.respawn()
    check(respawn.status_line():find("asleep=0", 1, true) ~= nil, what .. ": no longer counts as asleep")
    local hurt_sent = false
    for _, sm in ipairs(sent) do if sm.kind == "BED" and (sm.args[2] == "hurt" or sm.args[2] == "off") then hurt_sent = true end end
    check(not hurt_sent, what .. ": no 'hurt' / 'off' to the dead client")
    local cm = sent_kind("BED", "sleepst")
    check(cm and args_of(cm) == "sleepst|wait|0|2|Friend|out", what .. ": the count wait 0/2 (" .. args_of(cm) .. ")")
    check(logged("Friend died while asleep") ~= nil and logged("was hurt while asleep") == nil,
        what .. ": host log says died, not hurt")
end
client_dies(0, false, "health 0 before the dead flag")
client_dies(50, true, "the dead flag (health 50)")
rmed._p.Health, rpawn._p["PlayerDead?"] = 100, false
handlers.SLEEP({ "x" }, rpc)

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

-- ------------------------------------------------------------ K2. the client hurt in bed (its HUD)
-- A client's own MedicalComponent does not replicate (13.11: 100/100 on every
-- client line); the host's value reaches it only through its HUD's bar.
print("K2. client hurt in bed: its HUD's health")
local function client_in_bed(tod)
    reset_round(tod)
    T = T + 30
    local w = press_sleep()
    handlers.BED({ "sleepst", "wait", "1", "2", "Friend", "in" })
    T = T + 2.5
    w:Exit()
    run_delayed()
    local w2 = hud._p.SleepUI
    check(w2 ~= w and w2._p.__inview, "client: waiting in bed")
    loops.respawn()
    return w2
end
local kw = client_in_bed(2300)
-- its own (not replicated) MedicalComponent copy changes: not its health
med._p.Health = 40
sent = {}
loops.respawn()
check(kw._p.__inview and sent_kind("SLEEP") == nil, "client: its own MedicalComponent copy is not read")
med._p.Health = 100
loops.respawn()
hpbar._p.CurrentPercent = 0.98     -- a small change: still in bed
loops.respawn()
check(kw._p.__inview, "client: a fall of 2 on the HUD: still in bed")
hpbar._p.CurrentPercent = 0.6      -- the host's Client_UpdateHealthUI(60) after a hit
toasts, sent, lines = {}, {}, {}
loops.respawn()
check(not kw._p.__inview, "client hurt: the sleep window closed")
m = sent_kind("SLEEP")
check(m and m.to == "host" and m.args[1] == "x", "client hurt: SLEEP x sent to the host")
check(toasted("Вы теряете здоровье — вы проснулись."), "client hurt: 'you are losing health: you wake up' on screen")
check(logged("hurt: health 98 %-> 60 %(HUD%)") ~= nil, "client hurt: logged with the HUD's health")
check(respawn.status_line():find("waiting_here=false", 1, true) ~= nil, "client: no longer waiting")
T = T + 5
loops.respawn()
run_delayed()
check(hud._p.SleepUI == kw, "client: no waiting window again after the hit")
hpbar._p.CurrentPercent = 1.0
-- TargetPercent is not the health (always 1.0): a HUD without CurrentPercent
-- gives no health, and nothing wakes the client by mistake
local kw2 = client_in_bed(2310)
hpbar._p.CurrentPercent = nil
hpbar._p.TargetPercent = 0.2
loops.respawn()
check(kw2._p.__inview, "client: no readable HUD health: still in bed")
hpbar._p.CurrentPercent, hpbar._p.TargetPercent = 1.0, 1.0
sent = {}
kw2:Exit()   -- Esc
check(sent_kind("SLEEP") and sent_kind("SLEEP").args[1] == "x", "client: got up with Esc")
-- the host's Client_UpdateHealthUI(0) before PlayerDead? (an unreliable RPC
-- can come first): the client gets up, without the words on its death screen
local kw4 = client_in_bed(2315)
hpbar._p.CurrentPercent = 0
toasts, sent, lines = {}, {}, {}
loops.respawn()
check(not kw4._p.__inview, "client: HUD health 0: the sleep window closed")
check(sent_kind("SLEEP") and sent_kind("SLEEP").args[1] == "x", "client: HUD health 0: SLEEP x to the host")
check(#toasts == 0, "client: HUD health 0 (a death): no 'losing health' words")
check(logged("died: health 100 %-> 0 %(HUD%)") ~= nil, "client: HUD health 0 logged as a death")
hpbar._p.CurrentPercent = 1.0

-- ------------------------------------------------------------ K3. the host says the client was hurt
print("K3. the host's 'hurt'")
local kw3 = client_in_bed(2320)
toasts, sent, lines = {}, {}, {}
handlers.BED({ "sleepst", "hurt", "0", "2", "Friend", "out" })
check(not kw3._p.__inview, "client: the host's 'hurt' closes the sleep window")
check(toasted("Вы теряете здоровье — вы проснулись."), "client: 'you are losing health: you wake up' on screen")
check(respawn.status_line():find("waiting_here=false", 1, true) ~= nil, "client: no longer waiting")
-- what follows it from the host: "off" (event hurt) for older mods, then the count
handlers.BED({ "sleepst", "off", "0", "0", "Friend", "hurt" })
handlers.BED({ "sleepst", "wait", "0", "2", "Friend", "out" })
check(#toasts == 1, "client: 'hurt', 'off', the count: the words once (" .. #toasts .. ")")
check(logged("coop_sleep_all off") == nil, "client: the 'off' after 'hurt' is not taken for the host's rule")
check(sent_kind("SLEEP") == nil, "client: no SLEEP x after the host's 'hurt' (the host already knows)")
T = T + 5
loops.respawn()
run_delayed()
check(hud._p.SleepUI == kw3, "client: no waiting window again after the host's 'hurt'")
-- the same messages as an older mod (up to 0.10.0) takes them: it has no
-- "hurt" state and ignores it; the "off" after it closes its window
local kw5 = client_in_bed(2330)
toasts, sent, lines = {}, {}, {}
handlers.BED({ "sleepst", "off", "0", "0", "Friend", "hurt" })
handlers.BED({ "sleepst", "wait", "0", "2", "Friend", "out" })
check(not kw5._p.__inview, "older mod's view (no 'hurt'): the 'off' closes the sleep window")
check(respawn.status_line():find("waiting_here=false", 1, true) ~= nil, "older mod's view: no longer waiting in bed")
check(logged("no longer waiting in bed: hurt") ~= nil, "the 'off' after a hurt is logged as the hurt")
T = T + 5
loops.respawn()
run_delayed()
check(hud._p.SleepUI == kw5, "older mod's view: no waiting window again")
-- the host's 'hurt' reaching a dead client (its own tick has not seen the death yet)
local kw6 = client_in_bed(2340)
toasts = {}
host_pawn._p["PlayerDead?"] = true
handlers.BED({ "sleepst", "hurt", "0", "2", "Friend", "out" })
check(not kw6._p.__inview, "dead client: the host's 'hurt' closes the window")
check(#toasts == 0, "dead client: no 'losing health' words over the death screen")
host_pawn._p["PlayerDead?"] = false
-- the same with the HUD at 0 (Client_UpdateHealthUI(0) before PlayerDead?)
local kw7 = client_in_bed(2350)
toasts = {}
hpbar._p.CurrentPercent = 0
handlers.BED({ "sleepst", "hurt", "0", "2", "Friend", "out" })
check(not kw7._p.__inview, "HUD health 0: the host's 'hurt' closes the window")
check(#toasts == 0, "HUD health 0: no 'losing health' words")
hpbar._p.CurrentPercent = 1.0
-- 'hurt' while not in bed: nothing
toasts = {}
handlers.BED({ "sleepst", "hurt", "0", "2", "Friend", "out" })
check(#toasts == 0, "client: 'hurt' when not in bed shows nothing")

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
