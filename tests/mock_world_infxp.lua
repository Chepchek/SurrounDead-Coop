-- Mock harness: infestation XP shared in co-op (sdc_world IX): every player near a
-- destroyed nest gets the game's payment once (XP, InfestationsDestroyed, the note).
-- usage: lua mock_world_infxp.lua <scripts dir>
-- (harness core copied from mock_world.lua)
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
local function class_obj(chain, i)
    i = i or 1
    if not chain[i] then return nil end
    return {
        IsValid = function() return true end,
        GetFName = function() return name_obj(chain[i]) end,
    }
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
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:IsLocallyControlled() return self._p._local == true end
function Obj:K2_DestroyActor() self._valid = false end
local function rec(name)
    return function(self, ...) self._calls[#self._calls + 1] = { name, ... } end
end
local function called(o, name)
    for _, c in ipairs(o._calls) do if c[1] == name then return c end end
    return nil
end

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
NotifyOnNewObject = function(path, fn) WORLD.watch = WORLD.watch or {}; table.insert(WORLD.watch, { path = path, fn = fn }) end
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

local function fire(w, path, ...)
    WORLD = w
    local hs = w.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local r = h.pre(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
    return true
end

-- ---------------------------------------------------------------- worlds
local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
end
local HW, CW = world("host"), world("client")

HARV_METHODS = {
    SetMaxHits = function(self) self._calls[#self._calls + 1] = { "SetMaxHits" }; self._p.MaxHits = 7 end,
    HitHarvestableObject = function(self, at, hits)
        self._calls[#self._calls + 1] = { "HitHarvestableObject", at, hits }
        if not self._init then self._init = true; self._p.MaxHits = 7 end   -- DoOnce Svr_SetMaxHits
        self._p.MaxHits = self._p.MaxHits - hits
        if self._p.MaxHits <= 0 then self._fell = (self._fell or 0) + 1 end
    end,
}
local function engine(w, is_server)
    WORLD = w
    w.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    w.sounds, w.spawned = {}, {}
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        PlaySoundAtLocation = function(_, wco, snd) w.sounds[#w.sounds + 1] = snd end,
        GetCurrentLevelName = function() return "LongdownValley" end,
        BeginDeferredActorSpawnFromClass = function(_, wco, cls, tf)
            local a = new(w, { cls._name, "Actor" }, "Spawned_" .. (#w.spawned + 1), { _tf = tf })
            w.spawned[#w.spawned + 1] = a
            if cls._name:find("^BP_HarvestableObject") then
                a._p._loc = tf.Translation
                a._p.Role = 3
                a._p.MaxHits = 1
                for k, fn in pairs(HARV_METHODS) do a._m[k] = fn end
                for _, x in ipairs(w.watch or {}) do
                    if x.path:find(cls._name:gsub("_C$", ""), 1, true) then assert(x.fn(a) == nil) end
                end
            end
            return a
        end,
        FinishSpawningActor = function(_, a) a._finished = true; return a end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
    new(w, { "AISense_Hearing" }, "Hearing", {}, { ReportNoiseEvent = rec("ReportNoiseEvent") }, "/Script/AIModule.Default__AISense_Hearing")
    new(w, { "SoundCue" }, "BreakOpen_Cue", {}, {}, "/Game/Audio/BreakOpen_Cue.BreakOpen_Cue")
    new(w, { "JigsawItem_DataAsset_C" }, "DA_ScrapMetal", {}, {}, "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal")
    new(w, { "JigsawItem_DataAsset_C" }, "DA_WoodenWall", {}, {}, "/Game/Inventory/Items/DataAssets/Buildable/DA_WoodenWall.DA_WoodenWall")
    new(w, { "BlueprintGeneratedClass" }, "BP_HarvestableObject_Tree_C", {}, {},
        "/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Tree.BP_HarvestableObject_Tree_C")
end
engine(HW, true)
engine(CW, false)

local function players(w, locals)
    WORLD = w
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local bc = new(w, { "BuildingComponent_C" }, "BuildingComponent_0", { ["BuildModeOn?"] = false },
        { Event_StopBuildMode = rec("Event_StopBuildMode") })
    local jig = new(w, { "BP_JigComponent_C" }, "BP_JigMultiplayer_0", {}, {
        AddNewItemSomewhere = function(self, da, n, a, b, dropifail, sc, added) self._calls[#self._calls + 1] = { "Add", da, n }; added.Added = true end,
        FindJigItemByDA = function(self, da, tags, a, b, n, out) out.Result = false end,
        SERVER_RequestConsumeItem = rec("SERVER_RequestConsumeItem"),
    })
    local root = new(w, { "JSIContainer_C" }, "Root_0", { JigMultiplayerComp = jig })
    local menu = new(w, { "JigContextMenuComp_C" }, "JigContextMenuComp_0", { LocalComp = jig, RootContainer = root })
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true, BuildingComponent = bc, BP_JigMultiplayer = jig,
          JigContextMenuComp = menu })
    bc._p._owner = pawn
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn, w.bc, w.jig = pc, pawn, bc, jig
end
players(HW)
players(CW)

-- the remote player's controller and character on the host
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rjig = new(HW, { "BP_JigComponent_C" }, "BP_JigMultiplayer_1", {}, {
    AddNewItemSomewhere = function(self, da, n, a, b, dropifail, sc, added) self._calls[#self._calls + 1] = { "Add", da, n }; added.Added = true end,
})
local rbc = new(HW, { "BuildingComponent_C" }, "BuildingComponent_1", {})
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1",
    { _loc = { X = 5000, Y = 0, Z = 0 }, BP_JigMultiplayer = rjig, BuildingComponent = rbc })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
    })
rpawn._p.Controller = rpc
rbc._p._owner = rpawn
HW.pcs[2] = rpc

-- ===========================================================================
-- Infestation XP shared in co-op (sdc_world IX, 0.6.72)
-- ===========================================================================
local INF = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
local SKULL = "/Game/UI/Textures/Survival-UI-Bundle/Rhombus_Solid/512x512/Skul.Skul"
local CV = { ["Game.XpPopUp"] = true }
local CFGO = {}   -- config overrides of this test

for _, w in ipairs({ HW, CW }) do
    WORLD = w
    w.notes = {}
    new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(self, text, icon, col)
            w.notes[#w.notes + 1] = { text = type(text) == "string" and text or text:ToString(), icon = icon, col = col }
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    new(w, { "ConsoleUtils" }, "Default__ConsoleUtils", {}, {
        GetBoolCVar = function(self, n) return CV[n:ToString()] end,
    }, "/Script/AutoSettings.Default__ConsoleUtils")
    new(w, { "Texture2D" }, "Skul", {}, {}, SKULL)
    w.lc = new(w, { "LevellingComponent_C" }, "LC_" .. w.id, { CurrentLevel = 5, MultiplyValue = 1.2 }, {
        AddXP = function(self, xp, up, out) self._calls[#self._calls + 1] = { "AddXP", xp }; out.XPOutput = xp end,
    })
    w.pc._p.LevellingComponent = w.lc
    w.pc._p.InfestationsDestroyed = 3
    w.pawn._p._loc = { X = 0, Y = 0, Z = 0 }
end
rpawn._p._loc = { X = 5000, Y = 0, Z = 0 }

-- a nest on both machines: Event_OnDestroyed runs the game's payment there (@9868) when not from a load
local function nest(w, name, primary, at)
    WORLD = w
    local n
    local dc = new(w, { "DamageComponent_C" }, name .. "_DC", {}, {
        DamageTaken = function(self, dmg, typ, causer) n:Event_OnDestroyed(causer, false) end,
    })
    n = new(w, primary and { "BP_PrimaryInfestation_C", "BP_Infestation_C" } or { "BP_Infestation_C" }, name,
        { ["IsDestroyed?"] = false, ["PrimaryInfestation?"] = primary, DamageComponent = dc, _loc = at }, {
        Event_OnDestroyed = function(self, causer, load)
            if self._p["IsDestroyed?"] then return end
            self._p["IsDestroyed?"] = true
            self._calls[#self._calls + 1] = { "Event_OnDestroyed", causer, load }
            if not load then w.game_paid = (w.game_paid or 0) + 1 end
            fire(w, INF .. ":Event_OnDestroyed", param(self), param(causer), param(load))
        end,
        Damage_Object = function(self) end,
    })
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
        if CFGO[k] ~= nil then return CFGO[k] end
        return get0(k, ...)
    end
    m.net.install_hooks()
    m.world = require("sdc_world")
    return m
end
local H = load_mods(HW)
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
local function deliver()
    for _ = 1, 6 do
        local out = HW.outbox
        HW.outbox = {}
        WORLD = CW
        for _, msg in ipairs(out) do
            local kind, f = C.net.decode(msg)
            local h = C.net.handlers[kind]
            if h then h(f, CW.pc) end
        end
        out = CW.outbox
        CW.outbox = {}
        WORLD = HW
        for _, msg in ipairs(out) do
            local kind, f = H.net.decode(msg)
            local h = H.net.handlers[kind]
            if h then h(f, rpc) end
        end
    end
end
local function settle() for _ = 1, 3 do run_timers(HW); deliver(); run_timers(CW); deliver() end end
local function pump() for _ = 1, 10 do advance(0.25); WORLD = HW; H.world.tick(); deliver() end; settle() end
local function xps(w) local o = {} for _, c in ipairs(w.lc._calls) do if c[1] == "AddXP" then o[#o + 1] = c[2] end end return o end
local function sent(w, kind) local n = 0 for _, m in ipairs(w.outbox) do if m:find("|" .. kind .. "|", 1, true) then n = n + 1 end end return n end
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
pump()

print("== X1. the host destroys a secondary nest: the client 40 m away gets the same, the game's way")
local h1 = nest(HW, "BP_Infestation_C_11", false, { X = 1000, Y = 0, Z = 0 })
local c1 = nest(CW, "BP_Infestation_C_11", false, { X = 1000, Y = 0, Z = 0 })
WORLD = HW; h1:Event_OnDestroyed(nil, false)   -- the host's kill: the game paid the host
pump()
check(c1._calls[1] and c1._calls[1][3] == true, "the client's copy: the load path (no payment of its own)")
local cx = xps(CW)
check(#cx == 1 and cx[1] >= 5 * 100 * 1.2 and cx[1] <= 5 * 200 * 1.2, "client XP = its level 5 x 100..200 x its multiplier 1.2 (" .. tostring(cx[1]) .. ")")
check(CW.pc._p.InfestationsDestroyed == 4, "its journal: InfestationsDestroyed + 1")
local cn = CW.notes[#CW.notes]
check(cn and cn.text == string.format("Infestation Destroyed, XP Given: %d", math.floor(cx[1])) and cn.icon == CW.paths[SKULL]
    and cn.col.R == 1 and cn.col.G == 0, "the game's note on the client's screen (skull, red)")
check(#xps(HW) == 0, "the host is not paid a second time")

print("== X2. a client far away gets nothing; the setting off: nobody")
rpawn._p._loc = { X = 30000, Y = 0, Z = 0 }   -- 290 m
local h2 = nest(HW, "BP_Infestation_C_12", false, { X = 1000, Y = 0, Z = 0 })
nest(CW, "BP_Infestation_C_12", false, { X = 1000, Y = 0, Z = 0 })
WORLD = HW; h2:Event_OnDestroyed(nil, false)
pump()
check(#xps(CW) == 1, "290 m away: no share")
rpawn._p._loc = { X = 5000, Y = 0, Z = 0 }
CFGO.infestation_xp_shared = false
local h3 = nest(HW, "BP_Infestation_C_13", false, { X = 1000, Y = 0, Z = 0 })
nest(CW, "BP_Infestation_C_13", false, { X = 1000, Y = 0, Z = 0 })
WORLD = HW; h3:Event_OnDestroyed(nil, false)
pump()
check(#xps(CW) == 1, "infestation_xp_shared = false: only the finisher")
CFGO.infestation_xp_shared = nil
CFGO.infestation_xp_radius_m = 20
local h4 = nest(HW, "BP_Infestation_C_14", false, { X = 1000, Y = 0, Z = 0 })
nest(CW, "BP_Infestation_C_14", false, { X = 1000, Y = 0, Z = 0 })
WORLD = HW; h4:Event_OnDestroyed(nil, false)
pump()
check(#xps(CW) == 1, "radius 20 m: the client 40 m away gets nothing")
CFGO.infestation_xp_radius_m = nil

print("== X3. the client destroys a primary nest: its own copy paid it; the host 10 m away gets the same")
local h5 = nest(HW, "BP_PrimaryInfestation_C_2", true, { X = 1000, Y = 0, Z = 0 })
local c5 = nest(CW, "BP_PrimaryInfestation_C_2", true, { X = 1000, Y = 0, Z = 0 })
local client_paid = CW.game_paid or 0
WORLD = CW; c5:Event_OnDestroyed(CW.pawn, false)   -- its own kill: the game paid the client there
check(sent(CW, "WINFD") == 1, "WINFD to the host")
pump()
check(h5._p["IsDestroyed?"] == true, "the host's nest died the game's way for that player")
local hx = xps(HW)
check(#hx == 1 and hx[1] >= 5 * 400 * 1.2 and hx[1] <= 5 * 500 * 1.2, "the host: XP 5 x 400..500 x 1.2 of a primary nest (" .. tostring(hx[1]) .. ")")
check(HW.pc._p.InfestationsDestroyed == 4 and HW.notes[#HW.notes].text:find("^Infestation Destroyed, XP Given: ") ~= nil, "the host's stat and note")
check(#xps(CW) == 1 and (CW.game_paid or 0) == client_paid + 1, "the client: only its own game's payment (no share on top)")

print("== X4. the host's run named the client (its last hit), the client's copy did not die: the client gets it even from far")
rpawn._p._loc = { X = 30000, Y = 0, Z = 0 }
local h6 = nest(HW, "BP_Infestation_C_15", false, { X = 1000, Y = 0, Z = 0 })
nest(CW, "BP_Infestation_C_15", false, { X = 1000, Y = 0, Z = 0 })
WORLD = HW; H.net.handlers.WDMG({ "~LongdownValley~BP_Infestation_C_15", "25" }, rpc)   -- the client's shot: its hit, remembered
WORLD = HW; h6:Event_OnDestroyed(nil, false)   -- dies on the host; the scope paid the host's copy of the client
pump()
check(#xps(CW) == 2, "the finisher (the client, 290 m) got it")
check(#xps(HW) == 2, "and the host, 10 m away (not paid by the game this time)")
rpawn._p._loc = { X = 5000, Y = 0, Z = 0 }

print("== X5. once only: a second share for the same nest; a client whose copy died before the share")
local n_before = #xps(CW)
WORLD = CW; C.net.handlers.WINFXP({ "~LongdownValley~BP_Infestation_C_11", "0" }, CW.pc)
check(#xps(CW) == n_before, "the same nest again: nothing")
local c7 = nest(CW, "BP_Infestation_C_16", false, { X = 1000, Y = 0, Z = 0 })
nest(HW, "BP_Infestation_C_16", false, { X = 1000, Y = 0, Z = 0 })
WORLD = CW; c7:Event_OnDestroyed(CW.pawn, false)   -- its own copy died (paid here)
CW.outbox = {}                                       -- (its WINFD is still on the way)
C.net.handlers.WINFXP({ "~LongdownValley~BP_Infestation_C_16", "0" }, CW.pc)
check(#xps(CW) == n_before, "its own copy died here first: the share is not added")

print("== X6. a load (CalledFromGameLoad?) pays nobody; no pop-up with Game.XpPopUp off")
local h8 = nest(HW, "BP_Infestation_C_17", false, { X = 1000, Y = 0, Z = 0 })
nest(CW, "BP_Infestation_C_17", false, { X = 1000, Y = 0, Z = 0 })
local nh = #xps(HW)
WORLD = HW; h8:Event_OnDestroyed(nil, true)
pump()
check(#xps(CW) == n_before and #xps(HW) == nh, "destroyed by a load: no share")
CV["Game.XpPopUp"] = false
local notes0 = #CW.notes
local h9 = nest(HW, "BP_Infestation_C_18", false, { X = 1000, Y = 0, Z = 0 })
nest(CW, "BP_Infestation_C_18", false, { X = 1000, Y = 0, Z = 0 })
WORLD = HW; h9:Event_OnDestroyed(nil, false)
pump()
check(#xps(CW) == n_before + 1 and #CW.notes == notes0, "Game.XpPopUp off: the XP, no note")
CV["Game.XpPopUp"] = true

print("== X7. status")
WORLD = HW; local sl = H.world.status_line(); print(sl)
check(sl:find("xp shared=", 1, true) ~= nil, "status: xp shared=N")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
