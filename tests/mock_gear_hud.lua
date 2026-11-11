-- Mock harness: sdc_hudmods (driven by sdc_geiger) - the HUD's equipment
-- status icons (respirator filter / flashlight battery / NVG, an icon with a
-- percent above the hunger / thirst / radiation circles) on a client's screen.
-- usage: lua mock_gear_hud.lua <scripts dir>
--
-- The HUD (BP_Ingame_C) is simulated after work\re\pseudo\BP_Ingame.txt:
-- three Borders (RespiratorDur / FlashlightDur / NightVisionDur) start at
-- RenderOpacity 0; Show<X>Durability(true / false) fades them to 1 / 0 (here
-- at once: the fade's end state); Get<X>Durability(Dur) sets the text
-- "{A}%". The host side: RadiationComponent.SetFilterUI / UseFilter run on
-- the host for a client's character (its RadiationTimer), post-hooks only.
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

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end
local RAD_FN = "/Game/Blueprints/Components/RadiationComponent.RadiationComponent_C:"
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    if WORLD.no_rad_class and path:find(RAD_FN, 1, true) then error("function not found: " .. path) end
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

-- a Blueprint function's post-hooks (UE4SS 3.0.1: after the body, no ReturnValue)
local function bp_post(w, path, ctx, ...)
    local prev = WORLD
    WORLD = w
    local args = { param(ctx) }
    for _, v in ipairs({ ... }) do args[#args + 1] = param(v) end
    for _, h in ipairs(w.hooks[path] or {}) do
        assert(h.a(table.unpack(args)) == nil, "hook returned a value: " .. path)
    end
    WORLD = prev
end

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

-- the HUD: BP_Ingame_C with its three status Borders; every call is recorded
-- with who made it ("game" = the game's own Blueprint path, else the mod)
local KIND = { "Respirator", "Flashlight", "NightVision" }
local function make_hud(w, name)
    local borders, m = {}, {}
    local hud
    for _, kd in ipairs(KIND) do
        borders[kd] = new(w, { "Border", "Widget" }, kd .. "Dur_" .. name, { RenderOpacity = 0.0 })
        m["Show" .. kd .. "Durability"] = function(self, show)
            self._calls[#self._calls + 1] = { fn = "Show" .. kd, v = show, by = self._by or "mod" }
            borders[kd]._p.RenderOpacity = show and 1.0 or 0.0
        end
        m["Get" .. kd .. "Durability"] = function(self, v)
            self._calls[#self._calls + 1] = { fn = "Get" .. kd, v = v, by = self._by or "mod" }
            self._text[kd] = string.format("%d%%", math.floor(v + 0.5))
        end
    end
    hud = new(w, { "BP_Ingame_C", "UserWidget" }, name,
        { RespiratorDur = borders.Respirator, FlashlightDur = borders.Flashlight, NightVisionDur = borders.NightVision }, m)
    hud._calls, hud._text, hud._b = {}, {}, borders
    return hud
end
local function game_call(hud, fn, v)   -- the game's own Blueprint calling the HUD
    hud._by = "game"
    hud[fn](hud, v)
    hud._by = nil
end
local function mod_calls(hud, fn, v)
    local n = 0
    for _, c in ipairs(hud._calls) do
        if c.by == "mod" and (fn == nil or c.fn == fn) and (v == nil or c.v == v) then n = n + 1 end
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
local function shown(hud, kd) return hud._b[kd]._p.RenderOpacity >= 0.5 end

-- a player character: RadiationComponent, the own spot light "Flashlight",
-- and (on its own machine) its HUD
local function character(w, name, is_local, with_hud)
    local pawn
    local comp = new(w, { "RadiationComponent_C" }, "RadiationComponent_" .. name,
        { InRadArea = false, CurrentRadiation = 100.0, MaxRadiation = 100.0 }, {
            StopGeiger = function() end, StopRadiation = function() end,
        })
    local light = new(w, { "SpotLightComponent" }, "Flashlight_" .. name, { Intensity = 0.0 })
    pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, name, {
        RadiationComponent = comp, Flashlight = light, ["PlayerDead?"] = false, ["FlashlightOn?"] = false,
        ["PlayerUsingNightVision?"] = false, _local = is_local,
        InGameUI = with_hud and make_hud(w, "BP_Ingame_C_" .. name) or nil,
    })
    comp._p._owner = pawn
    return pawn, comp, light
end

-- ---------------------------------------------------------------- load modules per world
local CFGO = {}
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if CFGO[k] ~= nil then return CFGO[k] end
        return get0(k, ...)
    end
    m.items = require("sdc_items")
    m.geiger = require("sdc_geiger")
    m.hud = require("sdc_hudmods")
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

-- =================================================================== host
say("== H0. host: hooks")
local HW = world("host")
engine(HW)
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { Player = conn, NetConnection = conn }, {
        ClientMessage = function(_, msg) HW.to_client[#HW.to_client + 1] = msg end,
    })
local R, compR = character(HW, "BP_PlayerCharacter_C_R", false, false)
R._p.Controller = rpc
rpc._p.Pawn = R
local Hh, compHh = character(HW, "BP_PlayerCharacter_C_0", true, true)   -- the host's own (with its HUD)
HW.pc._p.Pawn = Hh
HW.no_rad_class = true
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc._full] = { name = "Friend" } } }
H.geiger.install(HS)
tick(HW, H)
check(HW.hooks[RAD_FN .. "SetFilterUI"] == nil, "RadiationComponent_C not loaded yet: no SetFilterUI hook")
HW.no_rad_class = false
tick(HW, H, 2.5)
check(HW.hooks[RAD_FN .. "SetFilterUI"] ~= nil and #HW.hooks[RAD_FN .. "SetFilterUI"] == 1, "SetFilterUI hook registered once")
check(HW.hooks[RAD_FN .. "UseFilter"] ~= nil and #HW.hooks[RAD_FN .. "UseFilter"] == 1, "UseFilter: sdc_geiger's one hook (not a second one)")
check(logged("hudmods: SetFilterUI hook ok") ~= nil, "logged: SetFilterUI hook ok")
check(logged("client_gear_hud=true") ~= nil, "logged: client_gear_hud in the install line")

say("== H1. the client's RadiationTimer on the host: SetFilterUI(true) + UseFilter -> RESPUI")
local h1 = #LOG + 1
bp_post(HW, RAD_FN .. "SetFilterUI", compR, false)   -- a zone exit without the icon ever on (no mask)
check(#HW.to_client == 0 and logged("hudmods: respirator icon", h1) == nil, "exit with the icon never on: nothing sent, no line")
bp_post(HW, RAD_FN .. "SetFilterUI", compR, true)
local on1 = sent_kinds(HW.to_client, "RESPUI")
check(#on1 == 1 and on1[1] == "SDC1|RESPUI|1|", "SetFilterUI(true) -> RESPUI|1| (filter not known yet)")
check(logged("hudmods: respirator icon of BP_PlayerCharacter_C_R %(Friend%) turned on by the host's copy %(RadiationComponent%.SetFilterUI true%) %-> RESPUI to its screen", h1) ~= nil,
    "logged: respirator icon on for the client")
bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 87.5, true)
local p1 = sent_kinds(HW.to_client, "RESPUI")
check(#p1 == 2 and p1[2] == "SDC1|RESPUI|1|87.50", "UseFilter (sdc_geiger's hook) -> RESPUI|1|87.50")
check(logged("respirator filter used on the host", h1) ~= nil, "sdc_geiger's own UseFilter log line still there")
for _ = 1, 20 do advance(0.1); bp_post(HW, RAD_FN .. "SetFilterUI", compR, true) end
check(#sent_kinds(HW.to_client, "RESPUI") == 2, "SetFilterUI(true) every RadiationTimer tick: no more messages")
advance(0.1); bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 87.6, true)
check(#sent_kinds(HW.to_client, "RESPUI") == 2, "87.5 -> 87.6 (same whole percent, < 5 s): nothing sent")
advance(0.1); bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 87.4, true)
check(#sent_kinds(HW.to_client, "RESPUI") == 3, "87.6 -> 87.4 (88% -> 87%): sent at once")
advance(5); bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 87.3, true)
check(#sent_kinds(HW.to_client, "RESPUI") == 4, "a small change after 5 s: sent")
advance(10); bp_post(HW, RAD_FN .. "SetFilterUI", compR, true)
local k1 = sent_kinds(HW.to_client, "RESPUI")
check(#k1 == 5 and k1[5] == "SDC1|RESPUI|1|87.30", "10 s while on: 'on' again (keep-alive) with the filter")

say("== H2. the host's own respirator: nothing sent, its HUD untouched by the mod")
local own0 = #HW.to_client
bp_post(HW, RAD_FN .. "SetFilterUI", compHh, true)
bp_post(HW, RAD_FN .. "UseFilter", compHh, 0.1, 50, true)
ticks(HW, H, 8)
check(#HW.to_client == own0, "no RESPUI for the host's own character")
check(mod_calls(Hh._p.InGameUI) == 0, "the host's own HUD: no call from the mod")

-- =================================================================== client
say("== C0. client: own character, HUD, host data (UIDS / ITEMS)")
local CW = world("client")
engine(CW)
local A, compA, lightA = character(CW, "BP_PlayerCharacter_C_A", true, true)
CW.pc._p.Pawn = A
local HUD = A._p.InGameUI
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {} }
C.items.init(CS)
C.items.register_handlers()
C.geiger.install(CS)
tick(CW, C)
check(CW.hooks[RAD_FN .. "SetFilterUI"] ~= nil, "client: SetFilterUI hook (own zone exits)")
-- the host's UIDS / ITEMS: flashlight with a battery at 64.2, the mask with a filter at 70.0
WORLD = CW
C.net.handlers.UIDS({ "Jig.PlayerSlot.Facewear=5:6:7:8@0.00;Jig.PlayerSlot.Flashlight=-1234567:2345678:3456789:4567890@0.00;None=0:0:0:0" }, CW.pc)
C.net.handlers.ITEMS({ "-1234567:2345678:3456789:4567890=0.0/64.2;5:6:7:8=100.0/70.0;9:9:9:9=55.0" }, CW.pc)
check(C.items.own_slot_uid("Jig.PlayerSlot.Flashlight") == "-1234567:2345678:3456789:4567890",
    "sdc_items.own_slot_uid: the flashlight's UID from UIDS")
check(C.items.own_slot_uid("None") == nil and C.items.own_slot_uid("Jig.PlayerSlot.Eyewear") == nil,
    "own_slot_uid: an all-zero UID / a slot not in UIDS -> nil")
local _, batF = C.items.reported(C.items.own_slot_uid("Jig.PlayerSlot.Flashlight"))
check(batF == 64.2, "sdc_items.reported: the flashlight's battery 64.2 from ITEMS")
ticks(CW, C, 8)
check(mod_calls(HUD) == 0, "nothing in use: the mod calls nothing on the HUD")

say("== C1. respirator: the host's RESPUI shows the icon with the game's own HUD calls")
local c1 = #LOG + 1
local n, list = deliver(HW, CW, C)
check(n == 5, "5 RESPUI delivered to the client")
check(logged("hudmods: host: its radiation timer uses the own respirator %-> respirator icon on", c1) ~= nil,
    "logged: host says respirator icon on")
tick(CW, C)    -- the miss starts
tick(CW, C)    -- 0.25 s later: fixed
check(mod_calls(HUD, "ShowRespirator", true) == 1 and shown(HUD, "Respirator"), "ShowRespiratorDurability(true) once -> icon shown")
check(last_mod_value(HUD, "GetRespirator") == 87.3 and HUD._text.Respirator == "87%",
    "GetRespiratorDurability(87.3) -> '87%' (the host's filter)")
check(logged("hudmods: own respirator icon on %-> ShowRespiratorDurability%(true%) on the own HUD %(ok=true%), percent 87%.30; it follows the host's radiation timer", c1) ~= nil,
    "logged: respirator icon fixed with its percent")
ticks(CW, C, 12)
check(mod_calls(HUD, "ShowRespirator") == 1, "no repeated Show calls (the fade would restart)")
local pushes = mod_calls(HUD, "GetRespirator")
check(pushes >= 1 and pushes <= 2, "the same percent is not pushed every tick (" .. pushes .. " in 3 s)")
-- the host: filter down to 80.9
advance(1); WORLD = HW; bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 80.9, true)
deliver(HW, CW, C)
tick(CW, C)
check(last_mod_value(HUD, "GetRespirator") == 80.9 and HUD._text.Respirator == "81%", "new filter percent pushed: 81%")

say("== C2. own zone exit: the game hides the icon here; a late host 'on' does not bring it back")
local c2 = #LOG + 1
game_call(HUD, "ShowRespiratorDurability", false)   -- StopRadiation -> SetFilterUI(false) -> the HUD
HUD._b.Respirator._p.RenderOpacity = 0.8            -- its reverse fade still running
bp_post(CW, RAD_FN .. "SetFilterUI", compA, false)
check(logged("hudmods: own respirator icon hidden by the game here", c2) ~= nil, "logged: own zone exit seen")
ticks(CW, C, 2)
check(mod_calls(HUD, "ShowRespirator", false) == 0, "the game's reverse fade running: no Show(false) from the mod")
HUD._b.Respirator._p.RenderOpacity = 0.0            -- fade done
advance(0.5); WORLD = HW; bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 79.0, true)   -- the host's timer before RADZ
deliver(HW, CW, C)
ticks(CW, C, 4)
check(not shown(HUD, "Respirator") and mod_calls(HUD, "ShowRespirator", true) == 1, "the icon stays hidden (host 'on' within 3 s ignored)")
-- RADZ reaches the host: StopRadiation there -> SetFilterUI(false)
WORLD = HW; bp_post(HW, RAD_FN .. "SetFilterUI", compR, false)
local _, offl = deliver(HW, CW, C)
check(#sent_kinds(offl, "RESPUI") == 1 and offl[1]:find("SDC1|RESPUI|0|", 1, true) == 1, "host: SetFilterUI(false) -> RESPUI|0|...")
check(logged("respirator icon of BP_PlayerCharacter_C_R %(Friend%) turned off by the host's copy") ~= nil, "logged on the host: icon off")
ticks(CW, C, 8)
check(not shown(HUD, "Respirator") and mod_calls(HUD, "ShowRespirator", false) == 0, "hidden, the mod did not call Show(false) (the game did)")

say("== C3. back into the zone: on again after the guard")
advance(3)
WORLD = HW; bp_post(HW, RAD_FN .. "SetFilterUI", compR, true)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(shown(HUD, "Respirator") and mod_calls(HUD, "ShowRespirator", true) == 2, "re-entered: icon shown again")
-- the host's pills: SetFilterUI(false) there (no local call here) -> the mod hides it
WORLD = HW; bp_post(HW, RAD_FN .. "SetFilterUI", compR, false)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(shown(HUD, "Respirator") and mod_calls(HUD, "ShowRespirator", false) == 0, "host 'off': the game's own fade gets 1 s first")
ticks(CW, C, 4)
check(not shown(HUD, "Respirator") and mod_calls(HUD, "ShowRespirator", false) == 1, "host 'off' (pills) -> ShowRespiratorDurability(false) here")

say("== C4. flashlight: the game's own path shows the icon -> the mod only adds the host's battery")
local c4 = #LOG + 1
A._p["FlashlightOn?"] = true
lightA._p.Intensity = 6000.0
game_call(HUD, "ShowFlashlightDurability", true)   -- FlashlightToggle(true)
ticks(CW, C, 6)
check(mod_calls(HUD, "ShowFlashlight") == 0, "no Show call by the mod")
check(last_mod_value(HUD, "GetFlashlight") == 64.2 and HUD._text.Flashlight == "64%", "GetFlashlightDurability(64.2): the host's battery")
check(logged("hudmods: own flashlight in use: the game's own HUD call did it %(icon shown%), percent 64%.20", c4) ~= nil,
    "logged: the game's own call did it")
-- battery drained on the host -> ITEMS
WORLD = CW
C.net.handlers.ITEMS({ "-1234567:2345678:3456789:4567890=0.0/63.0;5:6:7:8=100.0/70.0" }, CW.pc)
tick(CW, C)
check(last_mod_value(HUD, "GetFlashlightDurability") == nil and last_mod_value(HUD, "GetFlashlight") == 63.0, "battery 63.0 pushed")
-- off by the game
A._p["FlashlightOn?"] = false
lightA._p.Intensity = 0.0
game_call(HUD, "ShowFlashlightDurability", false)
ticks(CW, C, 6)
check(mod_calls(HUD, "ShowFlashlight") == 0 and not shown(HUD, "Flashlight"), "off by the game: nothing from the mod")

say("== C5. flashlight: the game's HUD call was missed (no HUD at the switch, lost toggle) -> fixed")
local c5 = #LOG + 1
A._p["FlashlightOn?"] = true
lightA._p.Intensity = 6000.0
ticks(CW, C, 3)
check(mod_calls(HUD, "ShowFlashlight") == 0, "within the grace time: the game's call may still come")
ticks(CW, C, 3)
check(mod_calls(HUD, "ShowFlashlight", true) == 1 and shown(HUD, "Flashlight"), "after 1 s: ShowFlashlightDurability(true) by the mod")
check(HUD._text.Flashlight == "63%", "with the host's battery 63%")
check(logged("hudmods: own flashlight icon on %-> ShowFlashlightDurability%(true%) on the own HUD %(ok=true%), percent 63%.00; it follows the own light %(the game's own call did not come%), the HUD differed for 1%.00 s", c5) ~= nil,
    "logged: flashlight icon fixed")
-- light goes off but the game's Show(false) is lost -> the mod hides it
A._p["FlashlightOn?"] = false
lightA._p.Intensity = 0.0
ticks(CW, C, 6)
check(mod_calls(HUD, "ShowFlashlight", false) == 1 and not shown(HUD, "Flashlight"), "light off, icon left on -> hidden by the mod")
-- flashlight lit but no battery known from the host: icon yes, no percent from the mod
WORLD = CW
C.net.handlers.ITEMS({ "5:6:7:8=100.0/70.0" }, CW.pc)
local pushed0 = mod_calls(HUD, "GetFlashlight")
A._p["FlashlightOn?"] = true
lightA._p.Intensity = 6000.0
game_call(HUD, "ShowFlashlightDurability", true)
ticks(CW, C, 6)
check(mod_calls(HUD, "GetFlashlight") == pushed0, "no battery charge from the host: no percent pushed")
check(logged("hudmods: own flashlight lit but the host reported no battery charge") ~= nil, "logged: no battery charge (once)")
A._p["FlashlightOn?"] = false
lightA._p.Intensity = 0.0
game_call(HUD, "ShowFlashlightDurability", false)
ticks(CW, C, 4)

say("== C6. night vision: icon state only (the percent is sdc_tools')")
A._p["PlayerUsingNightVision?"] = true
ticks(CW, C, 6)
check(mod_calls(HUD, "ShowNightVision", true) == 1 and shown(HUD, "NightVision"), "NVG on without the game's icon -> shown by the mod")
check(mod_calls(HUD, "GetNightVision") == 0, "no NVG percent from this module")
A._p["PlayerUsingNightVision?"] = false
game_call(HUD, "ShowNightVisionDurability", false)
ticks(CW, C, 6)
check(mod_calls(HUD, "ShowNightVision", false) == 0, "NVG off by the game: nothing from the mod")

say("== C7. respawn: a new character / HUD forgets the old respirator state")
WORLD = HW; advance(4); bp_post(HW, RAD_FN .. "SetFilterUI", compR, true)
deliver(HW, CW, C)
ticks(CW, C, 2)
check(shown(HUD, "Respirator"), "respirator icon on (in a zone)")
local c7 = #LOG + 1
A._p["PlayerDead?"] = true
ticks(CW, C, 2)
local B = character(CW, "BP_PlayerCharacter_C_B", true, true)
CW.pc._p.Pawn = B
local HUD2 = B._p.InGameUI
ticks(CW, C, 8)
check(mod_calls(HUD2) == 0 and not shown(HUD2, "Respirator"), "new character's HUD: no respirator icon from the old state")
check(logged("hudmods: own character replaced: respirator icon state of the old one dropped", c7) ~= nil, "logged: old state dropped")

say("== C8. config off: the client does nothing, the host sends nothing")
CFGO.client_gear_hud = false
B._p["FlashlightOn?"] = true
B._p.Flashlight._p.Intensity = 6000.0
ticks(CW, C, 8)
check(mod_calls(HUD2) == 0, "client: no HUD call with client_gear_hud = false")
local before = #HW.to_client
WORLD = HW; advance(20); bp_post(HW, RAD_FN .. "SetFilterUI", compR, false); bp_post(HW, RAD_FN .. "UseFilter", compR, 0.1, 10, true)
check(#HW.to_client == before, "host: no RESPUI with client_gear_hud = false")
CFGO.client_gear_hud = nil

say("== S. status line")
WORLD = CW
local sl = C.geiger.status_line()
say("  " .. sl)
check(sl:find("filter uses=", 1, true) ~= nil and sl:find("|| hudmods: hook=true", 1, true) ~= nil, "geiger status line carries hudmods'")
WORLD = HW
local hl = H.hud.status_line()
say("  " .. hl)
check(hl:find("respirator on=", 1, true) ~= nil, "host counters in the status line")

say(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
