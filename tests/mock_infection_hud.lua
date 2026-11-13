-- Mock harness: sdc_infui (driven by sdc_geiger) - the infection bar (the
-- HUD's InfectionBorder: a dark plate with a bar and a virus icon at the left
-- middle of the screen) on a client's screen.
-- usage: lua mock_infection_hud.lua <scripts dir>
--
-- The HUD (BP_Ingame_C) is simulated after work\re\pseudo\BP_Ingame.txt and
-- json\BP_Ingame.json: InfectionBorder (not a variable) is the parent of
-- InfectionStat (BorderSlot_0.Parent), starts Visibility Hidden (2) and
-- RenderOpacity 0; InfectionAnim played forward sets Visibility 4 and fades
-- it to 1 (here at once: the fade's end state), reverse fades it to 0;
-- UpdateInfection(v) -> InfectionBar.PB_SetPercent(v / 100): ProgressBarLinear
-- with ProgressMethod 0 -> UpdatePercent: CurrentPercent = FClamp(v / 100, 0, 1)
-- (BP_Ingame gives InfectionBar CurrentPercent 0, TargetPercent 1.0; the
-- second is the bar's "target" fill, which PB_SetPercent never changes:
-- 0.8.1 read it and pushed the percent every 10 s). The host side: MedicalComponent.Infection? / InfectionAmount
-- on the host's copy of a client's character (the game's own timer there).
-- Messages host -> client are carried by ClientMessage, as in the game.
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local LOG = {}
local real_print = print
print = function(s)
    s = tostring(s)
    for line in s:gmatch("[^\n]+") do LOG[#LOG + 1] = line end
end
local function say(s) real_print(s) end
local function logged(pat, from)
    for i = from or 1, #LOG do if LOG[i]:find(pat) then return LOG[i], i end end
    return nil
end
local function count_logged(pat, from)
    local n = 0
    for i = from or 1, #LOG do if LOG[i]:find(pat) then n = n + 1 end end
    return n
end

local WORLD
local fails = 0
local function check(cond, what)
    if cond then say("  ok   " .. what) else say("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- fake objects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
local next_addr = 4096
local LVL = "/Game/Levels/LongdownValley.LongdownValley:PersistentLevel."
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true }, Obj)
    o._full = chain[1] .. " " .. (path or (LVL .. name))
    w.objects[#w.objects + 1] = o
    w.paths[path or (LVL .. name)] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetOwner() return self._p._owner end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:IsLocalController() return self._p._local == true end
function Obj:K2_GetActorLocation() return self._p._loc or { X = 0, Y = 0, Z = 0 } end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end
-- what UE4SS 3.0.1 reads for a property the object does not have
local TRIVIAL = setmetatable({}, { __tostring = function() return "TrivialObject: 000001C2D4E5F600" end })

-- ---------------------------------------------------------------- UE4SS globals
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { a = a, b = b })
    return 1, 2
end
NotifyOnNewObject = function() end
StaticFindObject = function(path)
    local o = WORLD.paths[path]
    if o and o._valid then return o end
    return nil
end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(WORLD.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function() return 1 end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, to_client = {}, outbox = {} }
end

local function engine(w)
    WORLD = w
    new(w, { "GameplayStatics" }, "GPS", {}, { SpawnSound2D = function() return nil end },
        "/Script/Engine.Default__GameplayStatics")
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return w.id == "host" end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    w.pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp, _local = true }, {
        ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
    })
end

-- the HUD: BP_Ingame_C with the infection plate; every call is recorded with
-- who made it ("game" = the game's own Blueprint path, else the mod)
local function make_hud(w, name)
    local plate = new(w, { "Border", "Widget" }, "InfectionBorder_" .. name, { Visibility = 2, RenderOpacity = 0.0 })
    local slot = new(w, { "BorderSlot", "PanelSlot" }, "BorderSlot_0_" .. name, { Parent = plate })
    local stat = new(w, { "Overlay", "Widget" }, "InfectionStat_" .. name, { Slot = slot })
    local bar = new(w, { "ProgressBarLinear_C", "UserWidget" }, "InfectionBar_" .. name, { TargetPercent = 1.0, CurrentPercent = 0.0 })
    local anim = new(w, { "WidgetAnimation" }, "InfectionAnim_" .. name, {})
    local hud
    local function rec(self, fn, v) self._calls[#self._calls + 1] = { fn = fn, v = v, by = self._by or "mod" } end
    local m = {
        PlayAnimationForward = function(self, a, speed, restore)
            rec(self, "Forward", a)
            assert(speed == 1.0 and restore == false, "PlayAnimationForward(anim, 1, false) as the game calls it")
            if a == anim and not self._broken then plate._p.Visibility, plate._p.RenderOpacity = 4, 1.0 end
        end,
        PlayAnimationReverse = function(self, a, speed, restore)
            rec(self, "Reverse", a)
            assert(speed == 1.0 and restore == false, "PlayAnimationReverse(anim, 1, false) as the game calls it")
            if a == anim and not self._broken then plate._p.RenderOpacity = 0.0 end   -- frame 0: Visibility stays 4
        end,
        UpdateInfection = function(self, v)
            rec(self, "Update", v)
            bar._p.CurrentPercent = math.max(0, math.min(1, v / 100))   -- TargetPercent stays 1.0
        end,
    }
    hud = new(w, { "BP_Ingame_C", "UserWidget" }, name, { InfectionStat = stat, InfectionBar = bar, InfectionAnim = anim }, m)
    hud._calls, hud._plate, hud._bar, hud._anim = {}, plate, bar, anim
    return hud
end
local function game_call(hud, fn, ...)   -- the game's own Blueprint calling the HUD
    hud._by = "game"
    hud[fn](hud, ...)
    hud._by = nil
end
local function mod_calls(hud, fn)
    local n = 0
    for _, c in ipairs(hud._calls) do
        if c.by == "mod" and (fn == nil or c.fn == fn) then n = n + 1 end
    end
    return n
end
local function last_mod_value(hud, fn)
    for i = #hud._calls, 1, -1 do
        local c = hud._calls[i]
        if c.by == "mod" and c.fn == fn then return c.v end
    end
    return nil
end
local function shown(hud)
    local p = hud._plate._p
    return p.Visibility ~= 2 and p.Visibility ~= 1 and p.RenderOpacity >= 0.5
end

-- a player character: MedicalComponent (the host's flags), and (on its own
-- machine) its HUD
local function character(w, name, is_local, with_hud)
    local med = new(w, { "MedicalComponent_C", "ActorComponent" }, "MedicalComponent_" .. name,
        { ["Infection?"] = false, InfectionAmount = 0.0, InfectionTimeLeft = 10800.0 })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, name, {
        MedicalComponent = med, ["PlayerDead?"] = false, _local = is_local,
        InGameUI = with_hud and make_hud(w, "BP_Ingame_C_" .. name) or nil,
    })
    med._p._owner = pawn
    if w.id == "host" then med._p.Player = pawn end   -- Svr_Initialise runs only on the server
    return pawn, med
end

-- ---------------------------------------------------------------- load modules per world
local CFGO = {}
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config") }
    m.cfgo = {}   -- this machine's own settings (CFGO: both)
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if m.cfgo[k] ~= nil then return m.cfgo[k] end
        if CFGO[k] ~= nil then return CFGO[k] end
        return get0(k, ...)
    end
    m.geiger = require("sdc_geiger")
    m.inf = require("sdc_infui")
    return m
end
local function tick(w, M, dt)
    advance(dt or 0.25)
    WORLD = w
    M.geiger.tick()
end
local function ticks(w, M, n) for _ = 1, n do tick(w, M) end end

-- host -> client: what the host's ClientMessage carried, into the client's sdc_net handlers
local function deliver(hw, cw, C)
    local list = hw.to_client
    hw.to_client = {}
    local prev = WORLD
    WORLD = cw
    local n = 0
    for _, raw in ipairs(list) do
        local kind, fields = C.net.decode(raw)
        local h = kind and C.net.handlers[kind]
        if h then h(fields, cw.pc); n = n + 1 end
    end
    WORLD = prev
    return n, list
end
local function sent_kinds(list, kind)
    local out = {}
    for _, raw in ipairs(list) do
        if raw:find("SDC1|" .. kind .. "|", 1, true) then out[#out + 1] = raw end
    end
    return out
end
local function infui_msgs(w) return sent_kinds(w.to_client, "INFUI") end

-- =================================================================== host
say("== H0. host: nothing infected -> nothing sent")
local HW = world("host")
engine(HW)
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { Player = conn, NetConnection = conn }, {
        ClientMessage = function(_, msg) HW.to_client[#HW.to_client + 1] = msg end,
    })
local R, medR = character(HW, "BP_PlayerCharacter_C_R", false, false)
R._p.Controller = rpc
rpc._p.Pawn = R
local Hh, medHh = character(HW, "BP_PlayerCharacter_C_0", true, true)   -- the host's own (with its HUD)
HW.pc._p.Pawn = Hh
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc._full] = { name = "Friend" } } }
H.geiger.install(HS)
check(logged("infui: installed %(client_infection_hud=true%)") ~= nil, "logged: installed with the switch")
ticks(HW, H, 12)
check(#infui_msgs(HW) == 0, "no infection: no INFUI")

say("== H1. a zombie bite infects the client's character on the host -> INFUI on, again after 2 s, then every 10 s")
local h1 = #LOG + 1
medR._p["Infection?"] = true          -- ApplyBiteInfection + OnRep_Infection? (no HUD on this copy)
medR._p.InfectionAmount = 0.0
medR._p.InfectionTimeLeft = 10800.0
ticks(HW, H, 4)
local m1 = infui_msgs(HW)
check(#m1 == 1 and m1[1] == "SDC1|INFUI|1|0.00", "INFUI|1|0.00 sent once (" .. tostring(m1[1]) .. ")")
check(logged("infui: BP_PlayerCharacter_C_R %(Friend%) infected on the host %(MedicalComponent%.Infection%? true, InfectionAmount 0%.00%%, InfectionTimeLeft 10800 s; this copy: Player set, InGameUI none", h1) ~= nil,
    "logged on the host: who, amount, time left, Player set / no HUD on this copy")
medR._p.InfectionAmount = 0.01        -- the game's 1 s timer
ticks(HW, H, 4)
check(#infui_msgs(HW) == 1, "1 s after: nothing more yet")
ticks(HW, H, 4)
local m2 = infui_msgs(HW)
check(#m2 == 2 and m2[2] == "SDC1|INFUI|1|0.01", "2 s after: on again with the timer's amount")
ticks(HW, H, 32)                      -- 8 s
check(#infui_msgs(HW) == 2, "no more within 10 s")
medR._p.InfectionAmount = 0.12
ticks(HW, H, 9)
local m3 = infui_msgs(HW)
check(#m3 == 3 and m3[3] == "SDC1|INFUI|1|0.12", "10 s while on: kept with the amount")

say("== H2. the host's own infection: nothing sent, its HUD untouched by the mod")
local own0 = #HW.to_client
medHh._p["Infection?"] = true
game_call(Hh._p.InGameUI, "PlayAnimationForward", Hh._p.InGameUI._anim, 1.0, false)
ticks(HW, H, 8)
check(#HW.to_client == own0, "no INFUI for the host's own character")
check(mod_calls(Hh._p.InGameUI) == 0, "the host's own HUD: no call from the mod")

-- =================================================================== client
say("== C0. client: own character with its HUD, nothing wanted")
local CW = world("client")
engine(CW)
local A, medA = character(CW, "BP_PlayerCharacter_C_A", true, true)
CW.pc._p.Pawn = A
local HUD = A._p.InGameUI
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.geiger.install(CS)
ticks(CW, C, 8)
check(mod_calls(HUD) == 0 and not shown(HUD), "nothing infected: the mod calls nothing on the HUD")

say("== C1. INFUI on -> the plate shown with the game's InfectionAnim after 1 s, the host's percent into the bar")
local c1 = #LOG + 1
local n = deliver(HW, CW, C)
check(n == 3, "3 INFUI delivered (on, 2 s, keep)")
check(logged("infui: host: own character infected %(0%.00%%%) %-> infection bar wanted on", c1) ~= nil, "logged: wanted on (the first message's percent)")
check(logged("this copy: Infection%? false, Player none", c1) ~= nil, "logged: the client's own copy (Infection? false, no Player)")
tick(CW, C)    -- the miss starts; the percent is compared at once
check(mod_calls(HUD, "Forward") == 0, "within the grace time: no animation yet")
-- the bar's own value is CurrentPercent (0 on a new HUD), not TargetPercent
-- (1.0 for good): 0.8.1 saw 100 % here and pushed (13.11 log: 210 pushes)
check(mod_calls(HUD, "Update") == 0 and HUD._bar._p.TargetPercent == 1.0,
    "bar at 0.00 % (CurrentPercent; TargetPercent 1.0 ignored) vs host 0.12: within a point, not pushed")
check(logged("infui: own infection bar already at 0%.00%% %(host: 0%.12%%%): the game's own Client_UpdateInfectionUI keeps it", c1) ~= nil,
    "logged: the bar's own value seen")
ticks(CW, C, 4)
check(mod_calls(HUD, "Forward") == 1 and last_mod_value(HUD, "Forward") == HUD._anim and shown(HUD),
    "PlayAnimationForward(InfectionAnim) once -> plate shown")
check(logged("infui: own infection bar shown %-> PlayAnimationForward%(InfectionAnim%) on the own HUD %(ok=true%), percent 0%.12%%; it follows the host's MedicalComponent %(INFUI%), the HUD differed for 1%.00 s", c1) ~= nil,
    "logged: plate shown with its percent and the grace time")
ticks(CW, C, 20)
check(mod_calls(HUD, "Forward") == 1 and mod_calls(HUD, "Update") == 0, "no repeated animation / percent (the fade would restart)")

say("== C2. the game's own Client_UpdateInfectionUI keeps the bar -> nothing pushed; at 100 % (game silent) -> pushed")
local c2 = #LOG + 1
game_call(HUD, "UpdateInfection", 0.5)          -- the game's 1 s updates on this machine
WORLD = HW
medR._p.InfectionAmount = 0.6
ticks(HW, H, 40)
deliver(HW, CW, C)
local ok2 = C.inf.stats.bar_ok
ticks(CW, C, 2)
check(mod_calls(HUD, "Update") == 0 and C.inf.stats.bar_ok == ok2 + 1, "bar 0.5 vs host 0.6 (< 1 point): not pushed")
check(count_logged("infui: own infection bar already at", c2) == 0, "\"already at\" logged once per HUD (it was in C1)")
WORLD = HW
medR._p.InfectionAmount = 100.0                 -- InfectionDamage stage: the game sends nothing any more
ticks(HW, H, 40)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(mod_calls(HUD, "Update") == 1 and last_mod_value(HUD, "Update") == 100.0 and HUD._bar._p.CurrentPercent == 1.0,
    "host 100 vs bar 0.5 -> UpdateInfection(100): the bar at 100 %")
check(logged("infui: own infection bar 0%.50%% %-> 100%.00%% %(UpdateInfection with the host's percent", c2) ~= nil, "logged: percent pushed")

say("== C2b. the host's percent once in the bar: the next keep messages push nothing (0.8.1: every 10 s)")
local ok2b = C.inf.stats.bar_ok
WORLD = HW
ticks(HW, H, 44)                                -- 11 s: the host's keep, still 100
deliver(HW, CW, C)
ticks(CW, C, 2)
check(mod_calls(HUD, "Update") == 1 and C.inf.stats.bar_ok == ok2b + 1, "keep at 100 vs bar 100: not pushed again")
WORLD = HW
medR._p.InfectionAmount = 37.0                  -- (a value the game would not send here: the bar must follow it)
ticks(HW, H, 44)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(mod_calls(HUD, "Update") == 2 and last_mod_value(HUD, "Update") == 37.0, "host 37 vs bar 100: pushed once")
WORLD = HW
ticks(HW, H, 44)
deliver(HW, CW, C)
ticks(CW, C, 2)
WORLD = HW
ticks(HW, H, 44)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(mod_calls(HUD, "Update") == 2 and C.inf.stats.bar_ok == ok2b + 3, "two more keeps at 37 vs bar 37: nothing pushed")
WORLD = HW
medR._p.InfectionAmount = 100.0
ticks(HW, H, 44)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(mod_calls(HUD, "Update") == 3 and HUD._bar._p.CurrentPercent == 1.0, "(back at 100 for the next steps)")

say("== C3. the plate's fade running: no second animation call")
HUD._plate._p.RenderOpacity = 0.3               -- e.g. still fading in on a slow frame
ticks(CW, C, 3)
check(mod_calls(HUD, "Forward") == 1, "0.75 s below 0.5 opacity: no call yet")
HUD._plate._p.RenderOpacity = 1.0
ticks(CW, C, 8)
check(mod_calls(HUD, "Forward") == 1, "fade done: still one call")
HUD._plate._p.RenderOpacity = 0.3               -- a fade stopped half way (barely visible)
ticks(CW, C, 6)
check(mod_calls(HUD, "Forward") == 2 and shown(HUD), "stuck at 0.3 opacity for 1 s: played again -> shown")
HUD._plate._p.Visibility = 2                    -- set Hidden at full opacity
ticks(CW, C, 6)
check(mod_calls(HUD, "Forward") == 3 and shown(HUD), "Hidden at opacity 1 counts as hidden: played again -> shown")

say("== C4. cured on the host -> INFUI off -> PlayAnimationReverse after 1 s")
local c4 = #LOG + 1
WORLD = HW
medR._p["Infection?"] = false                   -- InfectionState(Cure) on the host
ticks(HW, H, 4)
local _, offl = deliver(HW, CW, C)
local offs = sent_kinds(offl, "INFUI")
check(#offs == 1 and offs[1] == "SDC1|INFUI|0|", "host: INFUI|0| once")
check(logged("infui: BP_PlayerCharacter_C_R %(Friend%) no longer infected on the host %(Infection%? false", c4) ~= nil, "logged on the host: off")
check(logged("infui: host: own character no longer infected %-> infection bar wanted off", c4) ~= nil, "logged on the client: wanted off")
ticks(CW, C, 2)
check(mod_calls(HUD, "Reverse") == 0 and shown(HUD), "within the grace time: still shown")
ticks(CW, C, 4)
check(mod_calls(HUD, "Reverse") == 1 and not shown(HUD), "PlayAnimationReverse(InfectionAnim) once -> hidden")
check(logged("infui: own infection bar hidden %-> PlayAnimationReverse%(InfectionAnim%)", c4) ~= nil, "logged: plate hidden")
WORLD = HW
ticks(HW, H, 60)
check(#infui_msgs(HW) == 0, "host: nothing more while not infected")

say("== C5. a plate the mod did not show is left alone")
game_call(HUD, "PlayAnimationForward", HUD._anim, 1.0, false)
ticks(CW, C, 12)
check(mod_calls(HUD, "Reverse") == 1 and shown(HUD), "not wanted, shown by the game itself: no Reverse from the mod")
game_call(HUD, "PlayAnimationReverse", HUD._anim, 1.0, false)

say("== C6. the animation does nothing -> 3 tries, then left alone (logged once)")
local c6 = #LOG + 1
local fwd6 = mod_calls(HUD, "Forward")
HUD._broken = true
WORLD = HW
medR._p["Infection?"] = true
medR._p.InfectionAmount = 3.0
ticks(HW, H, 4)
deliver(HW, CW, C)
ticks(CW, C, 40)
check(mod_calls(HUD, "Forward") == fwd6 + 3, "3 more PlayAnimationForward calls, no more (" .. (mod_calls(HUD, "Forward") - fwd6) .. ")")
check(count_logged("infui: own infection plate still hidden after 3 InfectionAnim call", c6) == 1, "logged once: gave up")
HUD._broken = false

say("== C7. own HUD replaced while infected -> shown again on the new HUD with the percent")
local c7 = #LOG + 1
local HUD2 = make_hud(CW, "BP_Ingame_C_A2")
A._p.InGameUI = HUD2
ticks(CW, C, 6)
check(mod_calls(HUD2, "Forward") == 1 and shown(HUD2), "new HUD: plate shown")
check(last_mod_value(HUD2, "Update") == 3.0, "new HUD: the host's percent 3.00 pushed")
check(logged("infui: own HUD replaced", c7) ~= nil, "logged: HUD replaced")

say("== C8. respawn: the old character's infection dropped; the host turns it off for the new one")
local c8 = #LOG + 1
A._p["PlayerDead?"] = true
ticks(CW, C, 2)
local B = character(CW, "BP_PlayerCharacter_C_B", true, false)
B._p.InGameUI = HUD2                             -- the same HUD object kept (worst case: the plate must go)
CW.pc._p.Pawn = B
ticks(CW, C, 6)
check(logged("infui: own character replaced: the old one's infection state dropped", c8) ~= nil, "logged: old state dropped")
check(mod_calls(HUD2, "Reverse") == 1 and not shown(HUD2), "same HUD kept: the mod's plate hidden")
WORLD = HW
local R2 = character(HW, "BP_PlayerCharacter_C_R2", false, false)
rpc._p.Pawn = R2                                -- the host's copy of the new character: not infected
ticks(HW, H, 4)
local o2 = infui_msgs(HW)
check(#o2 >= 1 and o2[#o2] == "SDC1|INFUI|0|", "host: INFUI off for the new character")
deliver(HW, CW, C)
ticks(CW, C, 8)
check(mod_calls(HUD2, "Forward") == 1, "client: nothing shown")

say("== C9. a MedicalComponent without Infection? (a game update): nothing sent, no error")
local c9 = #LOG + 1
WORLD = HW
local R3, medR3 = character(HW, "BP_PlayerCharacter_C_R3", false, false)
medR3._p["Infection?"] = TRIVIAL
rpc._p.Pawn = R3
ticks(HW, H, 12)
check(#infui_msgs(HW) == 0, "no INFUI")
check(count_logged("infui: MedicalComponent_BP_PlayerCharacter_C_R3 has no readable Infection%? %(TrivialObject", c9) == 1, "logged once")
check(logged("%[ERROR%]", c9) == nil, "no error line")

say("== C10. config off: the host sends 'off' once to a screen it told 'on', then nothing; the client hides only its own plate")
WORLD = HW
rpc._p.Pawn = R
medR._p["Infection?"] = true
ticks(HW, H, 4)
deliver(HW, CW, C)
ticks(CW, C, 6)
local fwd0 = mod_calls(HUD2, "Forward")
check(fwd0 == 2 and shown(HUD2), "(infected again: shown)")
CFGO.client_infection_hud = false
WORLD = HW
ticks(HW, H, 4)
local d1 = infui_msgs(HW)
check(#d1 == 1 and d1[1] == "SDC1|INFUI|0|", "host switched off: INFUI|0| once")
check(logged("no longer infected on the host %(client_infection_hud off here%)") ~= nil, "logged: off because of the switch")
ticks(HW, H, 60)
check(#infui_msgs(HW) == 1, "then nothing (15 s)")
HW.to_client = {}
WORLD = CW
local c10 = C.inf.stats.got
local c10l = #LOG + 1
local rev10, upd10 = mod_calls(HUD2, "Reverse"), mod_calls(HUD2, "Update")
C.net.handlers.INFUI({ "1", "5.00" }, CW.pc)
ticks(CW, C, 8)
check(C.inf.stats.got == c10 + 1 and mod_calls(HUD2, "Forward") == fwd0 and mod_calls(HUD2, "Update") == upd10,
    "client switched off: the message recorded only (no show, no percent)")
check(mod_calls(HUD2, "Reverse") == rev10 + 1 and not shown(HUD2), "client switched off: the plate the mod showed hidden once")
check(logged("infui: own infection bar hidden %-> PlayAnimationReverse%(InfectionAnim%) on the own HUD %(ok=true%); client_infection_hud off here", c10l) ~= nil,
    "logged: hidden because of the switch")
local n10 = mod_calls(HUD2)
ticks(CW, C, 20)
check(mod_calls(HUD2) == n10, "then no HUD call at all")
CFGO.client_infection_hud = nil

say("== C11. old client (no INFUI handler): the host's message is dropped by sdc_net's receive path, no error")
local c11 = #LOG + 1
WORLD = CW
C.net.install_hooks()
local cm = CW.hooks["/Script/Engine.PlayerController:ClientMessage"]
local function receive(raw)   -- PlayerController.ClientMessage on this client (sdc_net's own hook)
    for _, h in ipairs(cm or {}) do h.a({ get = function() return CW.pc end }, { get = function() return raw end }) end
end
local handler = C.net.handlers.INFUI
C.net.handlers.INFUI = nil
local got0 = C.inf.stats.got
local okr = pcall(receive, "SDC1|INFUI|1|5.00")
check(cm ~= nil and okr and C.inf.stats.got == got0, "no handler: dispatched, nothing ran")
C.net.handlers.INFUI = handler
receive("SDC1|INFUI|0|")
check(C.inf.stats.got == got0 + 1, "this build: the same receive path reaches sdc_infui")
check(logged("%[ERROR%]", c11) == nil, "no error line")

say("== C12. the client's own switch: off hides the mod's plate; what the host sends meanwhile is kept; on again follows it")
local c12 = #LOG + 1
WORLD = HW
medR._p.InfectionAmount = 4.0
ticks(HW, H, 4)
local on12 = infui_msgs(HW)
check(#on12 == 1 and on12[1] == "SDC1|INFUI|1|4.00", "(host on again after its switch: INFUI on)")
deliver(HW, CW, C)
ticks(CW, C, 6)
check(shown(HUD2) and last_mod_value(HUD2, "Update") == 4.0, "(shown with 4.00)")
local f12, r12 = mod_calls(HUD2, "Forward"), mod_calls(HUD2, "Reverse")
C.cfgo.client_infection_hud = false             -- the client's own switch only (the host's stays on)
ticks(CW, C, 6)
check(mod_calls(HUD2, "Reverse") == r12 + 1 and not shown(HUD2), "client off while infected: the mod's plate hidden once")
check(logged("infui: own infection bar hidden %-> PlayAnimationReverse%(InfectionAnim%) on the own HUD %(ok=true%); client_infection_hud off here", c12) ~= nil,
    "logged at info past the plate-switch line limit")
local n12 = mod_calls(HUD2)
local rawB, hud_reads = B._p, 0                 -- count sdc_infui's reads of the own character's InGameUI
B._p = setmetatable({}, { __index = function(_, k)
    if k == "InGameUI" and debug.traceback():find("sdc_infui", 1, true) then hud_reads = hud_reads + 1 end
    return rawB[k]
end, __newindex = rawB })
WORLD = HW
medR._p.InfectionAmount = 7.0
ticks(HW, H, 44)                                -- 11 s: the host's keep
local k12 = infui_msgs(HW)
check(#k12 >= 1 and k12[#k12] == "SDC1|INFUI|1|7.00", "host (on) keeps sending 7.00")
deliver(HW, CW, C)
ticks(CW, C, 12)
check(mod_calls(HUD2) == n12, "client off: the keep recorded, no HUD call")
check(hud_reads == 0, "client off, nothing of its own shown: the HUD not even read (" .. hud_reads .. ")")
B._p = rawB
C.cfgo.client_infection_hud = nil               -- on again, still infected
ticks(CW, C, 6)
check(mod_calls(HUD2, "Forward") == f12 + 1 and shown(HUD2), "client on again while infected: shown again")
check(last_mod_value(HUD2, "Update") == 7.0, "with the percent that came while off (7.00)")
C.cfgo.client_infection_hud = false             -- off again
ticks(CW, C, 6)
check(not shown(HUD2), "(off again: hidden)")
WORLD = HW
medR._p["Infection?"] = false                   -- cured on the host while the client's switch is off
ticks(HW, H, 4)
local o12 = infui_msgs(HW)
check(#o12 == 1 and o12[1] == "SDC1|INFUI|0|", "host: INFUI|0| once")
deliver(HW, CW, C)
check(logged("infui: host: own character no longer infected %-> infection bar wanted off %(client_infection_hud off here: recorded only%)", c12) ~= nil,
    "logged: the cure recorded while switched off")
ticks(CW, C, 8)
C.cfgo.client_infection_hud = nil               -- on again after the cure
local n12b = mod_calls(HUD2)
WORLD = HW
ticks(HW, H, 200)                               -- 50 s: the host sends nothing (not infected)
check(#infui_msgs(HW) == 0, "host: nothing more")
deliver(HW, CW, C)
ticks(CW, C, 200)
check(not shown(HUD2) and mod_calls(HUD2) == n12b, "client on again after a cure that came while off: the plate stays hidden, no HUD call")
check(C.inf.status_line():find("infection=off", 1, true) ~= nil, "client state: off")

say("== S. status line")
WORLD = CW
local sl = C.geiger.status_line()
say("  " .. sl)
check(sl:find("|| infui: enabled=true", 1, true) ~= nil, "geiger status line carries infui's")
check(sl:find("bar shown=", 1, true) ~= nil and sl:find("gave up=1", 1, true) ~= nil, "client counters")
WORLD = HW
local hl = H.inf.status_line()
say("  " .. hl)
check(hl:find("infection on=", 1, true) ~= nil and hl:find("off=", 1, true) ~= nil, "host counters")
check(logged("%[ERROR%]") == nil, "no error line in the whole run")

-- DUMPLOG=1 prints the module's log lines (what the in-game log will show)
for _, l in ipairs(LOG) do if os.getenv("DUMPLOG") and l:find("infui") then real_print("LOG: " .. l) end end
say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
