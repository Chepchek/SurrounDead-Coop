-- Mock harness: sdc_notes - every game notification on the screen of the
-- player it is for (host relay NOTE, host take-off, client dedup / quiet).
-- usage: lua mock_notes_route.lua <scripts dir>
-- (harness core copied from mock_world.lua; the game's CreateNotificationUI
-- is simulated: sdc_ctx's real GetPlayerController pre-hook picks the
-- controller, its HUD (none for a remote controller on the host) adds the
-- widget unless the same text is on screen and it is not forced, then the
-- Blueprint post-hooks run)
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD
local fails = 0
local function check(cond, what)
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
                             _valid = true, _calls = {} }, Obj)
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
local function param(v) return { get = function() return v end, set = function(self, nv) v = nv end, _v = function() return v end } end
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
ExecuteInGameThreadWithDelay = function(ms, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
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
local NEST_FN = "/Game/Infestation/BP_Infestation.BP_Infestation_C:Damage_Object"
local GPC_FN = "/Script/Engine.GameplayStatics:GetPlayerController"
local GASMASK = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/A_Scavengers_Prey/T_GasMask_256x256.T_GasMask_256x256"
local JUG = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/Hunting_For_Food/T_WaterJug_256x256.T_WaterJug_256x256"

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
end
local HW, CW = world("host"), world("client")

-- the HUD's notification list (NotificationParentWidget.Notification @0-791)
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
            NotificationDetailsStruct = { [MSG] = FText(text), Icon = icon, Col = col, Delay = delay },
        }, {
            RemoveFromParent = function()
                for i, k in ipairs(box._kids) do if k == wd then table.remove(box._kids, i) break end end
                wd._removed = true
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
local function icon_on_screen(w, text)
    for _, k in ipairs(w.hud._box._kids) do
        if k._p.NotificationDetailsStruct[MSG]:ToString() == text then return k._p.NotificationDetailsStruct.Icon end
    end
    return nil
end

-- the game's CreateNotificationUI: player 0 by sdc_ctx's real pre-hook,
-- that controller's HUD, then the Blueprint post-hooks
local function game_note(w, text, icon, col, delay, force, wco)
    local prev = WORLD
    WORLD = w
    local idx = param(0)
    for _, h in ipairs(w.hooks[GPC_FN] or {}) do if h.pre then h.pre(param(w.gps), param(wco), idx) end end
    local pc = w.pcs[idx._v() + 1]
    local hud = pc and pc._p._hud
    if hud then hud:add(text, icon, col, delay, force) end
    for _, h in ipairs(w.hooks[GFL_FN] or {}) do
        local r = h.pre(param(w.gfl), param(FText(text)), param(icon), param(col), param(delay), param(force), param(wco))
        assert(r == nil, "hook returned a value")
    end
    WORLD = prev
end
local function fire(w, path, ...)
    local prev = WORLD
    WORLD = w
    for _, h in ipairs(w.hooks[path] or {}) do assert(h.pre(...) == nil, "hook returned a value: " .. path) end
    WORLD = prev
end

local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local function engine(w)
    WORLD = w
    w.gps = new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return w.id == "host" end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    w.gfl = new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(_, text, icon, col, delay, force, wco)
            game_note(w, type(text) == "table" and text:ToString() or text, icon, col, delay, force, wco)
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    for _, p in ipairs({ GFL_FN, CHAR_FN, FWD_FN, NEST_FN }) do new(w, { "Function" }, p:match(":(.+)$"), {}, {}, p) end
    new(w, { "Texture2D" }, "T_GasMask_256x256", {}, {}, GASMASK)
    new(w, { "Texture2D" }, "T_WaterJug_256x256", {}, {}, JUG)
    -- the local player
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    w.hud = make_hud(w)
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
        { Player = lp, _local = true, _hud = w.hud }, {
            ServerExecRPC = function(_, msg) w.outbox[#w.outbox + 1] = msg end,
            GetHUD = function(self) return self._p._hud end,
        })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0", { Controller = pc, _local = true })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn = pc, pawn
end
engine(HW)
engine(CW)

-- the client's controller and character on the host (no HUD there)
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1", {})
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end,
        GetHUD = function() return nil end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc
-- on the client: the host's character (another player's)
WORLD = CW
local hpawn_c = new(CW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_9", { _local = false })

-- ---------------------------------------------------------------- load modules per world
local CFGO = {}
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...)
        if k == "net_send_budget" then return false end
        if CFGO[k] ~= nil then return CFGO[k] end
        return get0(k, ...)
    end
    m.notes = require("sdc_notes")
    return m
end
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc._full] = { name = "Friend" } } }
local H = load_mods(HW)
H.notes.install(HS)
WORLD = HW; H.ctx.tick({ rpc })          -- player-0 redirection on (registers its pre-hooks)
WORLD = HW; H.notes.tick()
local CS = { role = "client", remote_pcs = {}, remote = {} }
local C = load_mods(CW)
C.notes.install(CS)
WORLD = CW; C.ctx.tick_client(true)       -- client mode: other players' objects ask for no player
WORLD = CW; C.notes.tick()

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

print("== N0. hooks")
check(H.ctx.active == true, "host: sdc_ctx redirection on (a client is connected)")
for _, p in ipairs({ GFL_FN, CHAR_FN, FWD_FN, NEST_FN }) do
    check(HW.hooks[p] and #HW.hooks[p] == 1, "host hooked " .. p:match("([%w_]+:[%w_]+)$"))
end
check(CW.hooks[GFL_FN] and #CW.hooks[GFL_FN] == 1, "client hooked CreateNotificationUI")

print("== N1. a server-only notice for the client (radiation filter timer): nobody saw it -> that client")
WORLD = HW
local rrad = new(HW, { "RadiationComponent_C" }, "RadiationComponent_1", { _owner = rpawn })
local gm = HW.paths[GASMASK]
game_note(HW, "No Filter", gm, WHITE, 4, false, rrad)
check(on_screen(HW, "No Filter") == 0, "not on the host's screen (the client's controller has no HUD there)")
check(sent("NOTE") == 1, "NOTE sent to the client")
settle()
check(on_screen(CW, "No Filter") == 1, "the game's notice on the client's screen")
check(icon_on_screen(CW, "No Filter") == CW.paths[GASMASK], "with the game's icon (in memory there)")

print("== N2. the timer raises it again and again: one message per delay")
HW.outbox = {}
for _ = 1, 10 do advance(0.1); game_note(HW, "No Filter", gm, WHITE, 4, false, rrad) end
check(sent("NOTE") == 0, "10 more within a second: none sent")
advance(4)
game_note(HW, "No Filter", gm, WHITE, 4, false, rrad)
check(sent("NOTE") == 1, "after its delay: sent again")
HW.outbox = {}

print("== N3. the host's own notice stays the host's")
local hrad = new(HW, { "RadiationComponent_C" }, "RadiationComponent_0", { _owner = HW.pawn })
game_note(HW, "Filter No Longer Working\r\nFind Another...", gm, WHITE, 8, false, hrad)
check(on_screen(HW, "Filter No Longer Working\r\nFind Another...") == 1, "on the host's screen")
check(sent("NOTE") == 0, "nothing sent")

print("== N4. what the client's machine raises itself / progression / kill popups: not sent")
local rmed = new(HW, { "MedicalComponent_C" }, "MedicalComponent_1", { _owner = rpawn })
game_note(HW, "Suffering from 'Bleeding'", nil, WHITE, 4, false, rmed)
local rlev = new(HW, { "LevellingComponent_C" }, "LevellingComponent_1", { _owner = rpc })
game_note(HW, "Level up! You're now level 7!", nil, WHITE, 2, false, rlev)
local zombie = new(HW, { "BP_Zombie_Roamer_C" }, "BP_Zombie_Roamer_C_5", {})
H.ctx.stand_in = function(o) return o == zombie and rpc or nil end
game_note(HW, "Zombie Killed, XP Given: 6", nil, WHITE, 2, false, zombie)
H.ctx.stand_in = nil
check(sent("NOTE") == 0, "MedicalComponent (OnRep), LevellingComponent (host copy), kill popup: none sent")
check(on_screen(HW, "Zombie Killed, XP Given: 6") == 0 and on_screen(HW, "Suffering from 'Bleeding'") == 0,
    "and none on the host's screen")
local weapon = new(HW, { "BP_M4Pickup_C" }, "BP_M4Pickup_C_1", { _owner = rpawn,
    BP_WeaponsPickupComponent = new(HW, { "BP_WeaponsPickupComponent_C" }, "WPC_1") })
game_note(HW, "Weapon jammed", nil, WHITE, 2, false, weapon)
check(sent("NOTE") == 0 and on_screen(HW, "Weapon jammed") == 0, "a client's weapon: no player on the host, nothing sent (its owner shows it)")

print("== N5. a client's use of a water well (SERVER_ForwardInteract): off the host's screen, to the client")
local well = new(HW, { "BP_WaterWell_C" }, "BP_WaterWell_2", {})
local rjig = new(HW, { "BP_JigComponent_C" }, "BP_JigMultiplayer_1", { _owner = rpawn })
local jug = HW.paths[JUG]
game_note(HW, "'Water Bottle' filled", jug, WHITE, 2, false, well)   -- inside OnServerExecuteInteract
check(on_screen(HW, "'Water Bottle' filled") == 1, "(the game put it on the host's screen)")
fire(HW, FWD_FN, param(rjig), param(well), param(FName("Jig.InteractOptions.Option1")), param({}))
check(on_screen(HW, "'Water Bottle' filled") == 0, "taken off the host's screen")
check(sent("NOTE") == 1, "sent to the client")
settle()
check(on_screen(CW, "'Water Bottle' filled") == 1, "on the client's screen")

print("== N6. the host's own use of the well stays the host's")
local hjig = new(HW, { "BP_JigComponent_C" }, "BP_JigMultiplayer_0", { _owner = HW.pawn })
advance(3)
game_note(HW, "Not enough water in well", jug, WHITE, 3, false, well)
fire(HW, FWD_FN, param(hjig), param(well), param(FName("Jig.InteractOptions.Option1")), param({}))
check(on_screen(HW, "Not enough water in well") == 1 and sent("NOTE") == 0, "on the host's screen, nothing sent")

print("== N7. a client's melee on a locked primary nest: the host's copy refuses it -> off the host's screen; the client shows its own once")
local nest = new(HW, { "BP_PrimaryInfestation_C", "BP_Infestation_C" }, "BP_PrimaryInfestation_C_3", {})
local cnest = new(CW, { "BP_PrimaryInfestation_C", "BP_Infestation_C" }, "BP_PrimaryInfestation_C_3", {})
local NN = "Secondary Infestations Not Destroyed In Surrounding Area."
local RED = { R = 0.46875, G = 0, B = 0, A = 1 }
game_note(CW, NN, nil, RED, 2, true, cnest)                 -- the client's own copy (its hit, local)
game_note(HW, NN, nil, RED, 2, true, nest)                  -- the host's copy of the same hit
fire(HW, NEST_FN, param(nest), param(20), param(rpawn), param(rpc))
check(on_screen(HW, NN) == 0, "taken off the host's screen")
settle()
check(on_screen(CW, NN) == 1, "the client: its own notice, not a second one from the host")
advance(3)
game_note(HW, NN, nil, RED, 2, true, nest)                  -- the host's own hit
fire(HW, NEST_FN, param(nest), param(20), param(HW.pawn), param(HW.pc))
check(on_screen(HW, NN) == 1, "the host's own hit: stays on the host's screen")
HW.outbox = {}

print("== N8. BPI_Player notice on the client's character (hangar door keycard, server path)")
fire(HW, CHAR_FN, param(rpawn), param(FText("No Keycard Available")), param(nil), param(WHITE), param(2))
check(sent("NOTE") == 1, "sent to that client")
settle()
check(on_screen(CW, "No Keycard Available") == 1, "on the client's screen")

print("== N9. for_player: a module runs the game's function for the client on the host")
local gen = new(HW, { "BP_PowerGenerator_C" }, "BP_PowerGenerator_4", {})
advance(3)
local ok, _, n = H.notes.for_player(rpc, function() game_note(HW, "Generator powered on...", nil, WHITE, 2, false, gen) end)
check(ok and n == 1, "fn ran, 1 notice raised")
check(on_screen(HW, "Generator powered on...") == 0, "off the host's screen")
check(sent("NOTE") == 1, "sent to the client")
settle()
check(on_screen(CW, "Generator powered on...") == 1, "on the client's screen")
local ok2, _, n2 = H.notes.for_player(HW.pc, function() game_note(HW, "Generator powered off...", nil, WHITE, 2, false, gen) end)
check(ok2 and n2 == 0 and on_screen(HW, "Generator powered off...") == 1, "for the host's own controller: just runs, stays here")
HW.outbox = {}

print("== N10. client: quietly (the host's state applied here)")
advance(3)
local cgen = new(CW, { "BP_PowerGenerator_C" }, "BP_PowerGenerator_4", {})
local _, _, qn = C.notes.quietly("applying the host's generator", function()
    game_note(CW, "Generator powered off...", nil, WHITE, 2, false, cgen)
end)
check(qn == 1 and on_screen(CW, "Generator powered off...") == 0, "the notice is taken off the client's screen")
game_note(CW, "Spawn Point Set", nil, WHITE, 2, false, cgen)   -- the client's own, still on screen
C.notes.quietly("applying", function() game_note(CW, "Spawn Point Set", nil, WHITE, 2, false, cgen) end)
check(on_screen(CW, "Spawn Point Set") == 1, "an identical notice already on screen (not added again) is not taken off")

print("== N11. client dedup: its own copy first / the host's first")
advance(5)
game_note(CW, "Gas full", nil, WHITE, 2, false, cgen)          -- the client's own
WORLD = HW; H.notes.show_to(rpc, "Gas full", "", WHITE, 2, "test")
settle()
check(on_screen(CW, "Gas full") == 1, "own first: the host's one is not shown again")
advance(5)
WORLD = HW; H.notes.show_to(rpc, "Vehicle hitched", "", WHITE, 2, "test")
deliver()
check(C.notes.covered("Vehicle hitched", 5) == true, "covered() while it waits")
game_note(CW, "Vehicle hitched", nil, WHITE, 2, false, cgen)   -- the own copy within the hold
advance(0.4); run_timers(CW)
check(on_screen(CW, "Vehicle hitched") == 1, "own within the hold: one on screen")
advance(5)
WORLD = HW; H.notes.show_to(rpc, "No gas can", "", WHITE, 2, "test")
settle()
check(on_screen(CW, "No gas can") == 1, "only the host's: shown")

print("== N12. another player's object on the client is not counted as shown")
advance(5)
game_note(CW, "Battery run out", nil, WHITE, 2, false, hpawn_c)   -- the host's character: sdc_ctx gives no player
check(on_screen(CW, "Battery run out") == 0, "nothing on the client's screen (sdc_ctx client mode)")
WORLD = HW; H.notes.show_to(rpc, "Battery run out", "", WHITE, 2, "test")
settle()
check(on_screen(CW, "Battery run out") == 1, "the client's own one from the host is still shown")

print("== N13. text escapes; sent_to; settings off")
local tx = "Removing will resort in generator losing all gas.\r\nPress again to remove. | 100%"
WORLD = HW; H.notes.show_to(rpc, tx, "", WHITE, 2, "test")
check(H.notes.sent_to(rpc, tx, 3) == true, "sent_to() true right after")
settle()
check(on_screen(CW, tx) == 1, "\\r\\n, | and % survive the message")
CFGO.notes_relay = false
advance(5)
game_note(HW, "No Filter", gm, WHITE, 4, false, rrad)
check(sent("NOTE") == 0, "notes_relay = false: nothing sent")
CFGO.notes_relay = nil
CFGO.notes_owner_only = false
advance(5)
game_note(HW, "'Water Jug' filled", jug, WHITE, 2, false, well)
fire(HW, FWD_FN, param(rjig), param(well), param(FName("x")), param({}))
check(on_screen(HW, "'Water Jug' filled") == 1 and sent("NOTE") == 0, "notes_owner_only = false: stays on the host's screen")
CFGO.notes_owner_only = nil
HW.outbox = {}

print("== N14. an XP note the host's screen showed for a client's action stays (the XP went to the host)")
advance(5)
local door = new(HW, { "BP_HangarDoor_C" }, "BP_HangarDoor_1", {})
game_note(HW, "Door Unlocked, XP Given: 800", nil, WHITE, 2, false, door)
fire(HW, FWD_FN, param(rjig), param(door), param(FName("x")), param({}))
check(on_screen(HW, "Door Unlocked, XP Given: 800") == 1 and sent("NOTE") == 0, "kept on the host's screen, not sent")

print("== N16. a buildable the scope names the client for (CurrentActor): near -> sent; far (left over) -> not")
HW.outbox = {}
advance(5)
local genm = new(HW, { "Buildable_GeneratorMaster_C" }, "Buildable_GeneratorMaster_2", { _loc = { X = 0, Y = 0, Z = 0 } })
rpawn._p._loc = { X = 500, Y = 0, Z = 0 }
H.ctx.scope_resolver = function(o) if o == genm then return rpc end return nil end
game_note(HW, "No gas can", nil, WHITE, 2, false, genm)
check(on_screen(HW, "No gas can") == 0 and sent("NOTE") == 1, "5 m away: not on the host's screen, sent to the client")
HW.outbox = {}
advance(5)
rpawn._p._loc = { X = 9000, Y = 0, Z = 0 }
game_note(HW, "Gas full", nil, WHITE, 2, false, genm)
check(sent("NOTE") == 0, "90 m away (a left-over CurrentActor): not sent")
H.ctx.scope_resolver = nil
rpawn._p._loc = nil

print("== N15. status")
WORLD = HW
local sl = H.notes.status_line()
print("  " .. sl)
check(sl:find("relayed=", 1, true) ~= nil and sl:find("notes+", 1, true) ~= nil, "status line with the hooks")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
