-- Mock harness: sdc_shower with the REAL sdc_notes on both machines, for the
-- case the 2026-11-13 client log showed: the client's copy of the shower runs
-- nothing (no OnInteractBuildable there, no note of its own). The client must
-- still get the game's "No power" / "...cooldown in effect..." through the
-- host's relay (NOTE), the water of a start through SHWR go, the note of its
-- own press at once from the host's word, and no note twice.
-- usage: lua mock_shower_relay.lua <scripts dir>
-- (harness core: mock_notes_route.lua - two worlds, each with its own module
-- instances; the game's CreateNotificationUI with sdc_ctx's real pre-hook)
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD
local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
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
function Obj:GetOuter() return self._p._outer end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:IsLocalController() return self._p._local == true end
function Obj:K2_GetActorLocation() return self._p._loc end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
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
ExecuteInGameThreadWithDelay = function(_, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local function run_timers(w)
    WORLD = w
    for _ = 1, 3 do
        local t = w.timers
        w.timers = {}
        for _, fn in ipairs(t) do fn() end
    end
end

-- ---------------------------------------------------------------- worlds
local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local GFL_FN = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"
local CHAR_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:CreateNotificationUI"
local FWD_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_ForwardInteract"
local GPC_FN = "/Script/Engine.GameplayStatics:GetPlayerController"
local PATH = "/Game/Blueprints/BuildingSystem/Actors/Other/Buildable_DecontaminationShower.Buildable_DecontaminationShower_C"
local BASE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local CLS = "Buildable_DecontaminationShower_C"
local TEXT_COOL = "Decontamination shower cooldown in effect..."
local TEXT_NOPOWER = "No power"
local SH_FNS = { "DecontaminatePlayer", "OnInteractBuildable", "Event_Cooldown", "On", "Off" }

local function world(id) return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} } end
local HW, CW = world("host"), world("client")

local function make_hud(w)
    local box
    box = new(w, { "VerticalBox" }, "VerticalBox_31", {}, {
        GetChildrenCount = function() return #box._kids end,
        GetChildAt = function(_, i) return box._kids[i + 1] end,
    })
    box._kids = {}
    local parent = new(w, { "NotificationParentWidget_C" }, "NotificationUI", { VerticalBox_31 = box })
    local hud = new(w, { "HUD_Game_C", "HUD" }, "HUD_Game_C_0", { NotificationUI = parent })
    function hud.add(_, text, icon, col, delay, force)
        if not force then
            for _, k in ipairs(box._kids) do
                if k._p.NotificationDetailsStruct[MSG]:ToString() == text then return false end
            end
        end
        local wd
        wd = new(w, { "NotficationUI_C" }, "NotficationUI_C_" .. (#box._kids + 1), {
            NotificationDetailsStruct = { [MSG] = FText(text) },
        }, {
            RemoveFromParent = function()
                for i, k in ipairs(box._kids) do if k == wd then table.remove(box._kids, i) break end end
            end,
        })
        box._kids[#box._kids + 1] = wd
        return true
    end
    hud._box = box
    return hud
end
local function on_screen(w, text)
    local n = 0
    for _, k in ipairs(w.hud._box._kids) do
        if k._p.NotificationDetailsStruct[MSG]:ToString() == text then n = n + 1 end
    end
    return n
end
local function clear(w) w.hud._box._kids = {} end

-- the game's CreateNotificationUI: player 0 by sdc_ctx's real pre-hook,
-- that controller's HUD, then the Blueprint post-hooks
local function game_note(w, text, wco)
    local prev = WORLD
    WORLD = w
    local idx = param(0)
    for _, h in ipairs(w.hooks[GPC_FN] or {}) do if h.pre then h.pre(param(w.gps), param(wco), idx) end end
    local pc = w.pcs[idx:get() + 1]
    local hud = pc and pc._p._hud
    if hud then hud:add(text, nil, nil, 2, false) end
    for _, h in ipairs(w.hooks[GFL_FN] or {}) do
        h.pre(param(w.gfl), param(FText(text)), param(nil), param({ R = 1, G = 1, B = 1, A = 1 }), param(2), param(false),
            param(wco))
    end
    WORLD = prev
end
local function fire(w, path, ...)
    local prev = WORLD
    WORLD = w
    for _, h in ipairs(w.hooks[path] or {}) do assert(h.pre(...) == nil, "hook returned a value: " .. path) end
    WORLD = prev
end

local function fx(w) return new(w, { "ParticleSystemComponent" }, "FX", { _on = false }, {
    IsActive = function(s) return s._p._on end,
    Activate = function(s) s._p._on = true end,
    Deactivate = function(s) s._p._on = false end,
}) end

local function engine(w)
    WORLD = w
    w.gps = new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, _, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return w.id == "host" end,
        K2_GetTimerRemainingTime = function() return 300 end,
        K2_ClearTimer = function() end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    w.gfl = new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(_, text, _, _, _, _, wco)
            game_note(w, type(text) == "table" and text:ToString() or text, wco)
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    for _, p in ipairs({ GFL_FN, CHAR_FN, FWD_FN }) do new(w, { "Function" }, p:match(":(.+)$"), {}, {}, p) end
    new(w, { "Class" }, CLS, {}, {}, PATH)
    for _, f in ipairs(SH_FNS) do new(w, { "Function" }, f, {}, {}, PATH .. ":" .. f) end
    new(w, { "Function" }, "OnExecuteInteract", {}, {}, BASE .. ":OnExecuteInteract")
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    w.hud = make_hud(w)
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
        { Player = lp, _local = true, _hud = w.hud }, {
            ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
            GetHUD = function(self) return self._p._hud end,
        })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _local = true, _loc = { X = 300, Y = 0, Z = 90 } })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
    -- the shower here
    w.shower = new(w, { CLS, "Buildable_MASTER_C" }, CLS .. "_" .. w.id, {
        _loc = { X = 0, Y = 0, Z = 0 }, ["PoweredOn?"] = false, ["CooldownRunning?"] = false, Cooldown = 300,
        FX_Water = fx(w), FX_Water2 = fx(w),
    }, { ["OnRep_CooldownRunning?"] = function() end })
end
engine(HW)
engine(CW)

-- the client's controller and character on the host (no HUD there)
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1", { _loc = { X = 20, Y = 0, Z = 90 } })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end,
        GetHUD = function() return nil end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        return get0(k, ...)
    end
    m.ue.every = function() end
    m.notes = require("sdc_notes")
    m.shower = require("sdc_shower")
    return m
end
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc._full] = { name = "Friend" } } }
local H = load_mods(HW)
H.notes.install(HS)
H.shower.install(HS)
WORLD = HW; H.ctx.tick({ rpc })
WORLD = HW; H.notes.tick()
WORLD = HW; H.shower.tick()
-- sdc_world's build scope: the shower's player 0 is its CurrentActor's player
H.ctx.scope_resolver = function(wco)
    if wco == HW.shower then
        local cur = HW.shower._p.CurrentActor
        if cur == rpawn then return rpc end
        if cur == HW.pawn then return false end
    end
    return nil
end
local CS = { role = "client", remote_pcs = {}, remote = {}, client = { acked = false } }
local C = load_mods(CW)
C.notes.install(CS)
C.shower.install(CS)
WORLD = CW; C.ctx.tick_client(true)
WORLD = CW; C.notes.tick()
WORLD = CW; C.shower.tick()
check(H.shower ~= C.shower and H.notes ~= C.notes, "two machines, own module instances")
check(CW.hooks[BASE .. ":OnExecuteInteract"] and CW.hooks[PATH .. ":OnInteractBuildable"], "client: shower hooks in")

local function deliver()
    local out = HW.outbox
    HW.outbox = {}
    WORLD = CW
    for _, msg in ipairs(out) do
        local kind, f = C.net.decode(msg)
        local h = C.net.handlers[kind]
        if h then h(f, CW.pc) end
    end
end
local function sent(kind)
    local n = 0
    for _, m in ipairs(HW.outbox) do if m:find("|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end
local function settle() deliver(); advance(0.4); run_timers(CW); run_timers(HW) end
local USE = { TagName = FName("Jig.InteractOptions.Option1") }
-- a client press: its own OnExecuteInteract (the copy runs NOTHING else here),
-- then the host's run with CurrentActor = the client's character
local function client_press(host_run)
    fire(CW, BASE .. ":OnExecuteInteract", param(CW.shower), param(CW.pawn), param(USE))
    WORLD = HW
    HW.shower._p.CurrentActor = rpawn
    host_run()
end

print("== R1. no power: the host's note reaches the client (its copy raised nothing)")
client_press(function() game_note(HW, TEXT_NOPOWER, HW.shower) end)
check(on_screen(HW, TEXT_NOPOWER) == 0, "not on the host's screen")
check(sent("NOTE") == 1, "the host relays it (NOTE)")
settle()
check(on_screen(CW, TEXT_NOPOWER) == 1, "the client sees 'No power'")

print("== R2. cooldown: the same")
advance(4)
client_press(function() game_note(HW, TEXT_COOL, HW.shower) end)
check(sent("NOTE") == 1, "the host relays the cooldown note")
settle()
check(on_screen(CW, TEXT_COOL) == 1, "the client sees '...cooldown in effect...'")
clear(CW)

print("== R3. a start: water on the client through SHWR go, no note")
advance(4)
HW.shower._p["PoweredOn?"], HW.shower._p["CooldownRunning?"] = true, true
client_press(function() fire(HW, PATH .. ":DecontaminatePlayer", param(HW.shower)) end)
check(sent("NOTE") == 0 and sent("SHWR") == 1, "host: SHWR go, no note")
settle()
check(CW.shower._p.FX_Water._p._on and CW.shower._p.FX_Water2._p._on, "client: water on its copy")
check(CW.shower._p["CooldownRunning?"] == true, "client: its copy's cooldown flag on")
check(#CW.hud._box._kids == 0, "client: no note for its own start")

print("== R4. pressed again during the cooldown: the note at once from the host's word, the relay not twice")
advance(2)
WORLD = CW; C.shower.tick()
fire(CW, BASE .. ":OnExecuteInteract", param(CW.shower), param(CW.pawn), param(USE))
check(on_screen(CW, TEXT_COOL) == 1, "client: the cooldown note at the press, before the host answered")
WORLD = HW; HW.shower._p.CurrentActor = rpawn
game_note(HW, TEXT_COOL, HW.shower)
check(sent("NOTE") == 1, "the host still relays it")
settle()
check(on_screen(CW, TEXT_COOL) == 1, "client: still one note (the relay was a duplicate)")

print("== R5. the host's own refusal stays on the host")
clear(HW)
advance(4)
WORLD = HW; HW.shower._p.CurrentActor = HW.pawn
game_note(HW, TEXT_COOL, HW.shower)
check(on_screen(HW, TEXT_COOL) == 1 and sent("NOTE") == 0, "host: its own note on its screen, nothing sent")

print("== R6. sdc_notes freshness: a note already on screen is not the copy's")
clear(CW)
advance(4)
WORLD = CW
local hpawn_c = new(CW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_9", { _local = false })
CW.shower._p["PoweredOn?"], CW.shower._p["CooldownRunning?"] = true, true
game_note(CW, TEXT_COOL, CW.pc)          -- this player's own note (its press a second ago)
advance(1)
game_note(CW, TEXT_COOL, CW.shower)      -- the copy raises the same text for another player's press: not added
check(on_screen(CW, TEXT_COOL) == 1 and C.notes.shown_fresh(TEXT_COOL, 0.25) == false,
    "sdc_notes: the same text still on screen -> not fresh")
fire(CW, PATH .. ":OnInteractBuildable", param(CW.shower), param(hpawn_c))
check(on_screen(CW, TEXT_COOL) == 1, "client: the player's own note is not taken off for another player's press")
clear(CW)
advance(4)
game_note(CW, TEXT_COOL, CW.shower)      -- added this time
check(C.notes.shown_fresh(TEXT_COOL, 0.25) == true, "sdc_notes: a note the game added now is fresh")
fire(CW, PATH .. ":OnInteractBuildable", param(CW.shower), param(hpawn_c))
check(on_screen(CW, TEXT_COOL) == 0, "client: the copy's note for another player's press is taken off")

print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
