-- Mock harness: sdc_zones - a zone's "Now Entering" banner and its warning
-- (BP_EnterArea: the Aurora observatory's "WARNING: Mines in the area") on
-- the screen of every player who walks in, on its own machine, once.
-- usage: lua mock_zones_entry.lua <scripts dir>
-- The zone is simulated as the game runs it (work\re BP_EnterArea): ONE
-- entry DoOnce per zone and machine, reopened only by the exit's DoOnce;
-- the entering character's controller -> HUD (none for a remote controller
-- on the host, no controller for another player's character on a client:
-- the flow stops, the gate stays closed) -> HUD_Game.ZoneAreaUI(true, Name,
-- None, white) -> GetGameHUD(self).Notification(Message, Icon, Colour, 5,
-- not forced) straight to the HUD; then the event's Blueprint post-hooks.
-- Real modules: sdc_zones, sdc_notes (its show_here goes through the game's
-- CreateNotificationUI with sdc_ctx's real player-0 pre-hook), sdc_ctx.
-- (harness core from mock_notes_route.lua)
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

-- ---------------------------------------------------------------- worlds
local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local GFL_FN = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C:CreateNotificationUI"
local GPC_FN = "/Script/Engine.GameplayStatics:GetPlayerController"
local ZONE_CLS = "/Game/Blueprints/Zones/BP_EnterArea.BP_EnterArea_C"
local ENTER_FN = ZONE_CLS .. ":Event_EnteredArea"
local EXIT_FN = ZONE_CLS .. ":Event_ExitedArea"
local UI_FN = "/Game/Blueprints/HUD_Game.HUD_Game_C:ZoneAreaUI"
local GASMASK = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/A_Scavengers_Prey/T_GasMask_256x256.T_GasMask_256x256"
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local RED = { R = 1, G = 0, B = 0, A = 1 }
local AREA = "The Observatory"
local MINES = "WARNING: Mines in the area"

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
end
local HW, CW = world("host"), world("client")

-- Blueprint post-hooks of `path` (one callback each, after the function)
local function fire(w, path, ...)
    local prev = WORLD
    WORLD = w
    for _, h in ipairs(w.hooks[path] or {}) do assert(h.pre(...) == nil, "hook returned a value: " .. path) end
    WORLD = prev
end

-- HUD_Game: the notification list (NotificationParentWidget.Notification:
-- a text already on screen is not added again unless forced) and the zone
-- banner (ZoneAreaUI, then its post-hooks)
local function make_hud(w)
    local hud
    hud = new(w, { "HUD_Game_C", "HUD" }, "HUD_Game_C_0", {}, {
        ZoneAreaUI = function(self, entering, name, tex, col)
            local nm = type(name) == "table" and name:ToString() or tostring(name)
            self._banners[#self._banners + 1] = { entering = entering, name = nm, tex = tex, col = col }
            fire(w, UI_FN, param(self), param(entering), param(name), param(tex), param(col))
        end,
    })
    hud._banners, hud._notes, hud._kids = {}, {}, {}
    function hud.add(_, text, icon, col, delay, force)
        local live = {}
        for _, k in ipairs(hud._kids) do if T < k.till then live[#live + 1] = k end end   -- gone after its delay
        hud._kids = live
        if not force then
            for _, k in ipairs(hud._kids) do if k.text == text then return false end end
        end
        local n = { text = text, icon = icon, col = col, delay = delay, force = force, till = T + (tonumber(delay) or 2) }
        hud._kids[#hud._kids + 1] = n
        hud._notes[#hud._notes + 1] = n
        return true
    end
    return hud
end

-- the game's CreateNotificationUI: player 0 by sdc_ctx's real pre-hook, that
-- controller's HUD, then the Blueprint post-hooks (sdc_notes)
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
            w.gfl_calls = (w.gfl_calls or 0) + 1
            game_note(w, type(text) == "table" and text:ToString() or text, icon, col, delay, force, wco)
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    for _, p in ipairs({ GFL_FN, ENTER_FN, EXIT_FN, UI_FN }) do new(w, { "Function" }, p:match(":(.+)$"), {}, {}, p) end
    new(w, { "Texture2D" }, "T_GasMask_256x256", {}, {}, GASMASK)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    w.hud = make_hud(w)
    local pc = new(w, { "BP_PlayerController_C", "BP_MasterPlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
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
local rpc = new(HW, { "BP_PlayerController_C", "BP_MasterPlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(_, msg) HW.outbox[#HW.outbox + 1] = msg end,
        GetHUD = function() return nil end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc
-- on the client: the host's character (another player's: no controller here)
WORLD = CW
local hpawn_c = new(CW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_9", { _local = false })

-- the zone, one copy per machine (LongdownValley's BP_EnterArea_C_1)
local function make_zone(w, name, props)
    WORLD = w
    local p = { Name = FText(AREA), ["AdditionalNotification?"] = true,
                ["Notification Details Message"] = FText(MINES), ["Notification Details Icon"] = nil,
                ["Notification Details Icon Colour"] = RED }
    for k, v in pairs(props or {}) do p[k] = v end
    local z = new(w, { "BP_EnterArea_C", "BP_MasterObject_C", "Actor" }, name, p)
    z._closed, z._closed_exit = false, false
    z._in = {}   -- the characters inside the sphere
    z._p.Sphere = new(w, { "SphereComponent" }, name .. ".Sphere", {}, {
        IsOverlappingActor = function(_, a) return z._in[a] == true end,
    })
    return z
end
local HZ = make_zone(HW, "BP_EnterArea_C_1")
local CZ = make_zone(CW, "BP_EnterArea_C_1")

-- Event_EnteredArea(char) as the zone runs it (@3298 -> DoOnce @1148 ...)
local function zone_enter(w, z, ch)
    WORLD = w
    z._in[ch] = true
    if not z._closed then
        z._closed = true
        local pc = ch._p.Controller
        local hud = pc and derives(pc, "BP_MasterPlayerController_C") and pc:GetHUD() or nil
        if hud then
            hud:ZoneAreaUI(true, z._p.Name, nil, WHITE)
            if z._p["AdditionalNotification?"] then
                -- GetGameHUD(self): player 0 here (a zone asks for no other player)
                local hud0 = w.pcs[1]:GetHUD()
                hud0:add(z._p["Notification Details Message"]:ToString(), z._p["Notification Details Icon"],
                    z._p["Notification Details Icon Colour"], 5, false)
            end
        end
        z._closed_exit = false   -- @2073: the exit's DoOnce opens
    end
    fire(w, ENTER_FN, param(z), param(ch))
end
-- Event_ExitedArea(char) (@3354 -> DoOnce @2174 ...)
local function zone_exit(w, z, ch)
    WORLD = w
    z._in[ch] = nil
    if not z._closed_exit then
        z._closed_exit = true
        local pc = ch._p.Controller
        local hud = pc and derives(pc, "BP_MasterPlayerController_C") and pc:GetHUD() or nil
        if hud then hud:ZoneAreaUI(false, z._p.Name, nil, WHITE) end
        z._closed = false        -- @2148: the entry's DoOnce opens again
    end
    fire(w, EXIT_FN, param(z), param(ch))
end

local function banners(w, entering, name)
    local n = 0
    for _, b in ipairs(w.hud._banners) do
        if b.entering == entering and (name == nil or b.name == name) then n = n + 1 end
    end
    return n
end
local function notes_of(w, text)
    local out = {}
    for _, n in ipairs(w.hud._notes) do if n.text == text then out[#out + 1] = n end end
    return out
end
local function clear_screens()
    for _, w in ipairs({ HW, CW }) do
        w.hud._banners, w.hud._notes, w.hud._kids = {}, {}, {}
    end
    advance(10)
end
local function sent(kind)
    local n = 0
    for _, m in ipairs(HW.outbox) do if m:find("|" .. kind .. "|", 1, true) then n = n + 1 end end
    return n
end

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
    m.notes = require("sdc_notes")
    m.zones = require("sdc_zones")
    return m
end
local HS = { role = "host", remote_pcs = { rpc }, remote = { [rpc._full] = { name = "Friend" } } }
local H = load_mods(HW)
H.notes.install(HS)
H.zones.install(HS)
WORLD = HW; H.ctx.tick({ rpc })          -- player-0 redirection on (registers its pre-hooks)
WORLD = HW; H.notes.tick(); H.zones.tick()
local CS = { role = "client", remote_pcs = {}, remote = {} }
local C = load_mods(CW)
C.notes.install(CS)
C.zones.install(CS)
WORLD = CW; C.ctx.tick_client(true)
WORLD = CW; C.notes.tick(); C.zones.tick()

print("== Z0. hooks (both machines)")
for _, w in ipairs({ HW, CW }) do
    for _, p in ipairs({ UI_FN, ENTER_FN, EXIT_FN }) do
        check(w.hooks[p] and #w.hooks[p] == 1, w.id .. " hooked " .. p:match("([%w_]+:[%w_]+)$"))
    end
end

print("== Z1. the report: host and client walk in together, the host's character first on both machines")
zone_enter(HW, HZ, HW.pawn)      -- host machine: the host's own character
zone_enter(HW, HZ, rpawn)        -- host machine: the client's character (no HUD on the host)
zone_enter(CW, CZ, hpawn_c)      -- client machine: the host's character (no controller here): gate closed, nothing
zone_enter(CW, CZ, CW.pawn)      -- client machine: its own character
check(banners(HW, true, AREA) == 1, "host: one 'Now Entering The Observatory' (the game's)")
check(#notes_of(HW, MINES) == 1, "host: one mines warning (the game's)")
check(banners(CW, true, AREA) == 1, "client: 'Now Entering The Observatory' on its own screen")
local cb = CW.hud._banners[1] or {}
check(cb.tex == nil and cb.col and cb.col.R == 1 and cb.col.G == 1 and cb.col.B == 1, "client: banner as the zone calls it (no texture, white)")
local cn = notes_of(CW, MINES)
check(#cn == 1, "client: the mines warning on its own screen, once")
local n1 = cn[1] or {}
check(n1.delay == 5 and n1.force == false, "client: 5 s, not forced (as the zone)")
check(type(n1.col) == "table" and n1.col.R == 1 and n1.col.G == 0 and n1.col.B == 0, "client: the zone's red icon colour")
check(n1.icon == nil, "client: no icon (the zone has none)")
check(CW.gfl_calls == 1, "client: through the game's CreateNotificationUI")
check(sent("NOTE") == 0, "host: nothing relayed (each machine shows its own player)")
check(H.zones.stats.game == 1 and C.zones.stats.shown == 1, "stats: host shown by the game, client by the mod")

print("== Z2. once per visit: the zone's poll / a second overlap")
advance(1)
zone_enter(HW, HZ, HW.pawn); zone_enter(HW, HZ, rpawn)
zone_enter(CW, CZ, hpawn_c); zone_enter(CW, CZ, CW.pawn)
advance(1)
zone_enter(CW, CZ, CW.pawn)
check(banners(HW, true) == 1 and #notes_of(HW, MINES) == 1, "host: still one banner and one warning")
check(banners(CW, true) == 1 and #notes_of(CW, MINES) == 1, "client: still one banner and one warning")

print("== Z3. leaving")
zone_exit(CW, CZ, CW.pawn)       -- the client's exit gate is open (the host's character opened it): the game's 'Now Leaving'
check(banners(CW, false, AREA) == 1, "client: one 'Now Leaving' (the game's, the mod adds none)")
zone_exit(HW, HZ, rpawn)         -- host machine: the client's character takes the exit gate (no HUD: nothing shown)
check(banners(HW, false) == 0, "host: the client's exit shows nothing on the host")
zone_exit(HW, HZ, HW.pawn)       -- exit gate closed: the game shows nothing to the host
check(banners(HW, false, AREA) == 1, "host: 'Now Leaving' anyway (the mod), once")
zone_exit(CW, CZ, hpawn_c)
check(banners(CW, false) == 1, "client: the host's character leaving shows nothing more")

print("== Z4. the other order: the client's character first on both machines")
clear_screens()
zone_enter(HW, HZ, rpawn)        -- host machine: the client's character closes the gate
zone_enter(HW, HZ, HW.pawn)
zone_enter(CW, CZ, CW.pawn)      -- client machine: its own character first: the game shows it
zone_enter(CW, CZ, hpawn_c)
check(banners(HW, true, AREA) == 1 and #notes_of(HW, MINES) == 1, "host: banner and warning once (the mod)")
check(banners(CW, true, AREA) == 1 and #notes_of(CW, MINES) == 1, "client: banner and warning once (the game)")
check(HW.gfl_calls == 1, "host: the warning through the game's CreateNotificationUI")
check(sent("NOTE") == 0, "host: nothing relayed")
zone_exit(HW, HZ, HW.pawn); zone_exit(HW, HZ, rpawn)
zone_exit(CW, CZ, CW.pawn); zone_exit(CW, CZ, hpawn_c)

print("== Z5. a player who did not walk in gets nothing")
clear_screens()
zone_enter(HW, HZ, rpawn)        -- the client alone: on the host
zone_enter(CW, CZ, CW.pawn)      -- and on its own machine
check(banners(HW, true) == 0 and #notes_of(HW, MINES) == 0, "host (outside): no banner, no warning")
check(banners(CW, true) == 1 and #notes_of(CW, MINES) == 1, "client (inside): banner and warning")
zone_exit(HW, HZ, rpawn); zone_exit(CW, CZ, CW.pawn)
clear_screens()
zone_enter(HW, HZ, HW.pawn)      -- the host alone
zone_enter(CW, CZ, hpawn_c)
check(banners(CW, true) == 0 and #notes_of(CW, MINES) == 0, "client (outside): no banner, no warning")
check(banners(HW, true) == 1 and #notes_of(HW, MINES) == 1, "host (inside): banner and warning")
zone_exit(HW, HZ, HW.pawn); zone_exit(CW, CZ, hpawn_c)

print("== Z6. single player (no co-op role): the game alone")
clear_screens()
CS.role = "standalone"
WORLD = CW; C.zones.tick()
zone_enter(CW, CZ, hpawn_c); zone_enter(CW, CZ, CW.pawn)
check(banners(CW, true) == 0 and #notes_of(CW, MINES) == 0, "nothing added by the mod")
zone_exit(CW, CZ, CW.pawn); zone_exit(CW, CZ, hpawn_c)
CS.role = "client"
WORLD = CW; C.zones.tick()

print("== Z7. a new own character (after a respawn) is a new visit")
clear_screens()
zone_enter(CW, CZ, hpawn_c)
zone_enter(CW, CZ, CW.pawn)      -- the old character goes in ...
WORLD = CW
local pawn2 = new(CW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_2", { Controller = CW.pc, _local = true })
CW.pawn._p._local, CW.pawn._p.Controller = false, nil   -- ... and dies there (no exit seen)
CW.pc._p.Pawn = pawn2
advance(10)
zone_enter(CW, CZ, pawn2)
check(banners(CW, true, AREA) == 2 and #notes_of(CW, MINES) == 2, "the new character gets the banner and the warning")
zone_exit(CW, CZ, pawn2); zone_exit(CW, CZ, hpawn_c)

print("== Z8. a zone with an icon: the game's icon and colour")
clear_screens()
WORLD = CW
local GREEN = { R = 0, G = 1, B = 0, A = 1 }
local CZ2 = make_zone(CW, "BP_EnterArea_C_2", { Name = FText("Radio Tower"), ["Notification Details Message"] = FText("Gas leak"),
    ["Notification Details Icon"] = CW.paths[GASMASK], ["Notification Details Icon Colour"] = GREEN })
zone_enter(CW, CZ2, hpawn_c); zone_enter(CW, CZ2, pawn2)
local gn = notes_of(CW, "Gas leak")[1] or {}
check(banners(CW, true, "Radio Tower") == 1, "its own name on the banner")
check(gn.icon == CW.paths[GASMASK], "the zone's icon (in memory here)")
check(type(gn.col) == "table" and gn.col.G == 1 and gn.col.R == 0, "the zone's icon colour")
local CZ3 = make_zone(CW, "BP_EnterArea_C_3", { Name = FText("Quiet Field"), ["AdditionalNotification?"] = false })
zone_enter(CW, CZ3, hpawn_c); zone_enter(CW, CZ3, pawn2)
check(banners(CW, true, "Quiet Field") == 1 and #CW.hud._notes == 1, "a zone without a notification: the banner only")

-- a fresh copy of the observatory zone for each case below (fresh gates)
local zn = 10
local function fresh_zone(props)
    zn = zn + 1
    return make_zone(CW, "BP_EnterArea_C_" .. zn, props)
end

print("== Z10. what the game showed is judged by the call, not by time; other banners do not count")
clear_screens()
local zh = fresh_zone()
WORLD = CW
zh._closed, zh._in[pawn2] = true, true          -- the game's own entry for the own character, as the zone runs it ...
CW.hud:ZoneAreaUI(true, zh._p.Name, nil, WHITE)
CW.hud:add(MINES, nil, RED, 5, false)
advance(0.5)                                     -- ... with a hitch inside the call (a widget's first creation, a load)
fire(CW, ENTER_FN, param(zh), param(pawn2))
check(banners(CW, true, AREA) == 1 and #notes_of(CW, MINES) == 1, "a hitch inside the call: still one banner and one warning")
clear_screens()
local zr = fresh_zone()
zone_enter(CW, zr, hpawn_c)                      -- the host's character closes the gate
WORLD = CW; CW.hud:ZoneAreaUI(true, FText("Contaminated Checkpoint"), nil, WHITE)   -- a radiation zone's banner this frame
zone_enter(CW, zr, pawn2)
check(banners(CW, true, AREA) == 1 and #notes_of(CW, MINES) == 1, "another zone's banner just before: the mod still shows this one")
clear_screens()
local zl = fresh_zone()
zone_enter(CW, zl, hpawn_c)
WORLD = CW; CW.hud:ZoneAreaUI(false, zl._p.Name, nil, WHITE)   -- 'Now Leaving' of the same name just before
zone_enter(CW, zl, pawn2)
check(banners(CW, true, AREA) == 1 and #notes_of(CW, MINES) == 1, "a 'Now Leaving' of that name is not taken for the 'Now Entering'")

print("== Z11. a game banner outside any entry call is forgotten (tick, the next entry call)")
clear_screens()
local zt = fresh_zone()
zone_enter(CW, zt, hpawn_c)
WORLD = CW; CW.hud:ZoneAreaUI(true, zt._p.Name, nil, WHITE)    -- not from this zone's entry
advance(1); WORLD = CW; C.zones.tick()
zone_enter(CW, zt, pawn2)
check(banners(CW, true, AREA) == 2 and #notes_of(CW, MINES) == 1, "after a tick: the own entry gets the mod's banner and warning")
clear_screens()
local zo = fresh_zone()
WORLD = CW; CW.hud:ZoneAreaUI(true, zo._p.Name, nil, WHITE)    -- not from this zone's entry ...
zone_enter(CW, zo, hpawn_c)                                   -- ... then another character's entry call
zone_enter(CW, zo, pawn2)
check(banners(CW, true, AREA) == 2 and #notes_of(CW, MINES) == 1, "after another entry call: the own entry gets the mod's banner and warning")

print("== Z12. no game HUD at the entry: not counted, the zone's next entry call shows it")
clear_screens()
local zu = fresh_zone()
zone_enter(CW, zu, hpawn_c)
local hud_saved = CW.pc._p._hud
CW.pc._p._hud = nil
local s0, nh0, g0 = C.zones.stats.shown, C.zones.stats.no_hud, CW.gfl_calls
zone_enter(CW, zu, pawn2)
check(#hud_saved._notes == 0 and CW.gfl_calls == g0, "no warning sent to a screen that has no game HUD")
check(C.zones.stats.shown == s0 and C.zones.stats.no_hud == nh0 + 1, "not counted as shown")
CW.pc._p._hud = hud_saved
advance(0.2)
zone_enter(CW, zu, pawn2)                       -- the zone's poll
check(banners(CW, true, AREA) == 1 and #notes_of(CW, MINES) == 1 and C.zones.stats.shown == s0 + 1,
    "the next entry call: banner and warning, once")

print("== Z13. a new character at a freed character's address is a new visit")
clear_screens()
local za2 = fresh_zone()
zone_enter(CW, za2, hpawn_c)
zone_enter(CW, za2, pawn2)
WORLD = CW
local pawn3 = new(CW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_3", { Controller = CW.pc, _local = true })
pawn3._addr = pawn2._addr                        -- the old one died there, the new one got its memory
pawn2._p._local, pawn2._p.Controller = false, nil
CW.pc._p.Pawn = pawn3
advance(10)
zone_enter(CW, za2, pawn3)
check(banners(CW, true, AREA) == 2 and #notes_of(CW, MINES) == 2, "the new character gets the banner and the warning")

print("== Z14. a world change")
clear_screens()
local zw = fresh_zone()
zone_enter(CW, zw, hpawn_c); zone_enter(CW, zw, pawn3)
check(banners(CW, true, AREA) == 1, "(the visit before the load: the mod's banner)")
WORLD = CW; C.zones.reset("world:loadmap")      -- sdc_session's world-reset hook, before the new world
zw._closed, zw._closed_exit, zw._in = false, false, {}   -- the new world: freed memory reused at the same addresses
zw._in[pawn3] = true                             -- the own character spawned inside, its entry call still to come
advance(6); WORLD = CW; C.zones.tick()           -- (the loading: the old warning is off the screen)
zone_enter(CW, zw, hpawn_c); zone_enter(CW, zw, pawn3)
check(banners(CW, true, AREA) == 2 and #notes_of(CW, MINES) == 2, "after a LoadMap reset: a new visit, shown again")
clear_screens()
local zv = fresh_zone()
zone_enter(CW, zv, pawn3)                        -- the game shows it ...
WORLD = CW; C.zones.reset("world:new controller")   -- ... and the fallback reset comes after the new world
advance(1); WORLD = CW; C.zones.tick()           -- the mod looks where the own character stands
advance(5)
zone_enter(CW, zv, pawn3)                        -- the zone's poll (gate closed)
check(banners(CW, true, AREA) == 1 and #notes_of(CW, MINES) == 1, "after a late reset: the visit is known, no repeat")

print("== Z15. hooks that come in late (the first world of a game session)")
local LW = world("late")
engine(LW)
local ui_fn = LW.paths[UI_FN]
LW.paths[UI_FN] = nil                            -- HUD_Game not loaded yet; the zone class is
local LZ = make_zone(LW, "BP_EnterArea_C_1")
local LS = { role = "client", remote_pcs = {}, remote = {} }
local L = load_mods(LW)
L.notes.install(LS)
L.zones.install(LS)
WORLD = LW; L.ctx.tick_client(true); L.notes.tick(); L.zones.tick()
check(LW.hooks[ENTER_FN] == nil and LW.hooks[EXIT_FN] == nil, "no zone hook before the HUD's (an entry is never judged without it)")
zone_enter(LW, LZ, LW.pawn)                      -- the game shows it; the mod cannot see it
LW.paths[UI_FN] = ui_fn
advance(2); WORLD = LW; L.zones.tick()
check(LW.hooks[UI_FN] and LW.hooks[ENTER_FN] and LW.hooks[EXIT_FN], "all hooks in")
check(L.zones.stats.found == 1, "the zone the own character stands in counts as visited")
advance(5)
zone_enter(LW, LZ, LW.pawn)                      -- the zone's poll, 5 s after BeginPlay (gate closed)
check(banners(LW, true, AREA) == 1 and #notes_of(LW, MINES) == 1, "the poll after the late hooks: no second banner or warning")
zone_exit(LW, LZ, LW.pawn)
check(banners(LW, false, AREA) == 1, "leaving: one 'Now Leaving' (the game's)")
advance(1)
zone_enter(LW, LZ, LW.pawn)
check(banners(LW, true, AREA) == 2 and L.zones.stats.game == 1, "the next visit is watched as usual (the game's banner)")

print("== Z16. status")
WORLD = CW
local sl = C.zones.status_line()
print("  " .. sl)
check(sl:find("ui+,enter+,exit+", 1, true) ~= nil, "status line with the hooks")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
