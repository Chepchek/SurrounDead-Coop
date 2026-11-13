-- Mock harness: bunker / laboratory doors for a client (sdc_world PW +
-- sdc_puzzlelist). 2026-11-13: a client used a bunker scanner with its
-- keycard; the host's scanner unlocked and the host's door opened, the
-- client's copy of the door stayed shut and the client bumped into it. The
-- host had listed the puzzle objects in the main menu (0 of them, the map
-- streams in at Continue / Load without a new map) and never again: nothing
-- was ever sent, joiners got nothing, every save wrote an empty list.
-- usage: lua mock_bunker_doors.lua <scripts dir>
-- (harness core copied from mock_world_power.lua)
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
local function rec(name)
    return function(self, ...) self._calls[#self._calls + 1] = { name, ... } end
end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(self, nv) v = nv end } end
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
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {}, tls = {}, sounds = {} }
end
local HW, CW = world("host"), world("client")

local function engine(w, is_server)
    WORLD = w
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return is_server end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    new(w, { "GameplayStatics" }, "GPS", {}, {
        GetPlayerController = function(_, wc, i) return w.pcs[i + 1] end,
        GetNumPlayerControllers = function() return #w.pcs end,
        PlaySoundAtLocation = function(_, wco, snd) w.sounds[#w.sounds + 1] = snd end,
        GetCurrentLevelName = function() return "LongdownValley" end,
    }, "/Script/Engine.Default__GameplayStatics")
    new(w, { "Object" }, "Object", {}, {}, "/Script/CoreUObject.Object")
end
engine(HW, true)
engine(CW, false)

local function players(w)
    WORLD = w
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local jig = new(w, { "BP_JigComponent_C" }, "BP_JigMultiplayer_0", {}, {})
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
        ServerExecRPC = function(self, msg) w.outbox[#w.outbox + 1] = msg end,
        IsLocalController = function() return true end,
    })
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, _loc = { X = 0, Y = 0, Z = 0 }, _local = true, BP_JigMultiplayer = jig })
    pc._p.Pawn = pawn
    w.pcs = { pc }
    w.pc, w.pawn, w.jig = pc, pawn, jig
end
players(HW)
players(CW)

-- the remote player's controller and character on the host
WORLD = HW
local conn = new(HW, { "IpConnection" }, "IpConnection_0")
local rjig = new(HW, { "BP_JigComponent_C" }, "BP_JigMultiplayer_1", {}, {})
local rpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_1",
    { _loc = { X = 300, Y = 0, Z = 0 }, BP_JigMultiplayer = rjig })
local rpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_1",
    { NetConnection = conn, Player = conn, Pawn = rpawn }, {
        ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = msg end,
        IsLocalController = function() return false end,
    })
rpawn._p.Controller = rpc
HW.pcs[2] = rpc

-- ---------------------------------------------------------------- the game's pieces
local P = {
    scan = "/Game/Blueprints/Bunker/BP_BunkerScanner.BP_BunkerScanner_C",
    sdoor = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySlidingDoor.BP_LaboratorySlidingDoor_C",
    save = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot",
    load = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors",
}
local DA = {
    AllAccess = "/Game/Inventory/Items/DataAssets/Keycards/DA_AllAccessKeycard.DA_AllAccessKeycard",
    Level1Keycard = "/Game/Inventory/Items/DataAssets/Keycards/DA_Level1Keycard.DA_Level1Keycard",
    RedKeycard = "/Game/Inventory/Items/DataAssets/Keycards/DA_RedKeycard.DA_RedKeycard",
}
local GREEN = "/Game/Meshes/Materials/M_EmissiveColour_Green.M_EmissiveColour_Green"
-- each player's inventory: the owner's widgets show it, the host's containers hold it
local INV = { host = {}, client = {} }
local function inv_has(who, da) return da and (INV[who][da._name] or 0) > 0 end
local function inv_take(who, da)
    if not inv_has(who, da) then return false end
    INV[who][da._name] = INV[who][da._name] - 1
    return true
end
local function jig_methods(jig, find_who, take_who)
    jig._m.FindJigItemByDA = function(self, da, tags, a, b, n, out) out.Result = find_who ~= nil and inv_has(find_who, da) end
    jig._m.ServerFindThenConsumeByItemID = function(self, da, n, out) out.Result = take_who ~= nil and inv_take(take_who, da) end
end
jig_methods(HW.jig, "host", "host")      -- the host's own: widgets and containers
jig_methods(rjig, nil, "client")         -- the client's on the host: containers only
jig_methods(CW.jig, "client", nil)       -- the client's own: widgets only

local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local function setup(w)
    WORLD = w
    w.slot = "Slot1"
    local vb = new(w, { "VerticalBox" }, "VerticalBox_31_" .. w.id, {}, {})
    vb._children = {}
    vb._m.GetChildrenCount = function(self) return #self._children end
    vb._m.GetChildAt = function(self, i) return self._children[i + 1] end
    local parent = new(w, { "NotificationParentWidget_C" }, "Notifications_" .. w.id, { VerticalBox_31 = vb })
    local hud = new(w, { "HUD_Game_C" }, "HUD_Game_" .. w.id, { NotificationUI = parent })
    w.pc._m.GetHUD = function() return hud end
    new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(self, text)
            local s = type(text) == "string" and text or text:ToString()
            local note
            note = new(w, { "NotficationUI_C" }, "Note_" .. (#vb._children + 1), { NotificationDetailsStruct = { [MSG] = FText(s) } }, {
                RemoveFromParent = function()
                    for i, c in ipairs(vb._children) do if c == note then table.remove(vb._children, i) return end end
                end,
            })
            vb._children[#vb._children + 1] = note
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    w.note = function(s) w.paths["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"]:CreateNotificationUI(FText(s)) end
    new(w, { "EMSFunctionLibrary" }, "Default__EMSFunctionLibrary", {}, {
        GetSlotInfoSaveGame = function(self, wc, out) out.SaveGameName = w.slot end,
    }, "/Script/EasyMultiSave.Default__EMSFunctionLibrary")
    for k, p in pairs(DA) do new(w, { "JigsawItem_DataAsset_C" }, "DA_" .. k, {}, {}, p) end
    new(w, { "Material" }, "M_EmissiveColour_Green", {}, {}, GREEN)
    new(w, { "Material" }, "M_EmissiveColour_Red", {}, {}, "/Game/Meshes/Materials/M_EmissiveColour_Red.M_EmissiveColour_Red")
    w.pc._p.LevellingComponent = new(w, { "LevellingComponent_C" }, "LevellingComponent_" .. w.id, { CurrentLevel = 3 }, {
        AddXP = function(self, xp, up, out) out.XPOutput = xp end,
    })
end
setup(HW)
setup(CW)

local function post(w, path, self, ...)
    local args = { param(self) }
    for _, a in ipairs({ ... }) do args[#args + 1] = param(a) end
    fire(w, path, table.unpack(args))
end

-- A timeline: Play / Reverse run one update at once (the doors set Open? in
-- each update from the timeline's direction); finish() runs them to the end.
local function timeline(w, name, on_update, on_finish)
    local t = new(w, { "TimelineComponent" }, name, {}, {})
    t._pos, t._playing, t._rev, t._fin = 0, false, false, on_finish
    t._m.IsPlaying = function(self) return self._playing end
    t._m.IsReversing = function(self) return self._rev end
    t._m.GetPlaybackPosition = function(self) return self._pos end
    t._m.Play = function(self) self._playing, self._rev = true, false; if on_update then on_update(self) end end
    t._m.PlayFromStart = function(self) self._pos = 0; self:Play() end
    t._m.Reverse = function(self) self._playing, self._rev = true, true; if on_update then on_update(self) end end
    t._m.Stop = function(self) self._playing = false end
    t._m.GetTimelineLength = function() return 1 end
    t._m.SetNewTime = function(self, v) self._pos = v; if on_update then on_update(self) end end
    w.tls[#w.tls + 1] = t
    return t
end
local function finish(w)
    for _, t in ipairs(w.tls) do
        if t._playing and t._valid then
            t._playing = false
            t._pos = t._rev and 0 or 1
            if t._fin then t._fin(t._rev) end   -- its finished event
        end
    end
end

-- The level's actors of one machine (work\re\pseudo): a new copy each time
-- the level streams in (the old ones are gone).
local function level(w)
    WORLD = w
    for _, o in ipairs(w.level or {}) do o._valid = false end
    local made = {}
    local function bp(chain, name, props, methods)
        local o = new(w, chain, name, props, methods)
        made[#made + 1] = o
        return o
    end
    -- BP_DoubleBunkerDoor / BP_LargeBunkerEntrance(_Small): CallInteractOnObject
    -- (@642-656): Open? -> Reverse, else Play; each update (@439-488)
    -- Open? = the timeline goes forward. The meshes (and their collision) turn
    -- with it: a player passes an open door only.
    local function door(chain, name)
        local d
        local t = timeline(w, "DoorTimeline_" .. name, function(tl) d._p["Open?"] = not tl._rev end)
        made[#made + 1] = t
        d = bp(chain, name, { ["Open?"] = false, DoorTimeline = t }, {
            CallInteractOnObject = function(self)
                self._calls[#self._calls + 1] = { "CallInteractOnObject" }
                w.sounds[#w.sounds + 1] = "door"
                if self._p["Open?"] then t:Reverse() else t:Play() end
            end,
        })
        return d
    end
    -- BP_BunkerScanner: a press goes the server path; MC_CallInteract (a
    -- multicast of an actor that does not replicate: the host's copy only)
    -- -> FindKeycard (@0: no card needed -> found; else the interacting
    -- actor's all-access card, else its keycard consumed, else the note) ->
    -- Unlocked?, its light, every ListeningActor's CallInteractOnObject.
    local function scanner(name, card, doors)
        local mesh = new(w, { "StaticMeshComponent" }, "Scanner_" .. name, {}, { SetMaterial = rec("SetMaterial") })
        made[#made + 1] = mesh
        return bp({ "BP_BunkerScanner_C", "BP_MasterObject_C" }, name, {
            ["Unlocked?"] = false, ["KeycardRequired?"] = true, Keycard = w.paths[card], Scanner = mesh,
            ListeningActor = doors }, {
            FindKeycard = function(self, actor)
                if not self._p["KeycardRequired?"] then return true end
                local jig = actor and actor._p.BP_JigMultiplayer
                if not jig then return false end
                local out = {}
                jig:FindJigItemByDA(w.paths[DA.AllAccess], {}, true, false, 1, out)
                if out.Result then return true end
                out = {}
                jig:ServerFindThenConsumeByItemID(self._p.Keycard, 1, out)
                if out.Result then return true end
                w.note("No Keycard Available")
                return false
            end,
            MC_CallInteract = function(self, actor)
                if #self._p.ListeningActor > 0 and self:FindKeycard(actor) then
                    self._p["Unlocked?"], self._p["KeycardRequired?"] = true, false
                    mesh:SetMaterial(1, w.paths[GREEN])
                    for _, a in ipairs(self._p.ListeningActor) do a:CallInteractOnObject() end
                end
                post(w, P.scan .. ":MC_CallInteract", self, actor)
            end,
            OnExecuteInteract = function(self, actor, opt) post(w, P.scan .. ":OnExecuteInteract", self, actor, opt) end,
        })
    end
    local o = {}
    o.door7 = door({ "BP_DoubleBunkerDoor_C", "BP_MasterObject_C" }, "BP_DoubleBunkerDoor_C_7")
    o.door3 = door({ "BP_LargeBunkerEntrance_Small_C", "BP_LargeBunkerEntrance_C", "BP_MasterObject_C" },
        "BP_LargeBunkerEntrance_Small_C_3")
    o.scan7 = scanner("BP_BunkerScanner_C_7", DA.Level1Keycard, { o.door7 })
    o.scan12 = scanner("BP_BunkerScanner_C_12", DA.Level1Keycard, { o.door3 })
    -- a locked laboratory sliding door (Event_Door: keycard of player 0, TL_DoorsKeycard)
    local tk = timeline(w, "TL_DoorsKeycard_" .. w.id)
    made[#made + 1] = tk
    o.sdoor = bp({ "BP_LaboratorySlidingDoor_C", "BP_LaboratoryMaster_C" }, "BP_LaboratorySlidingDoor_C_1", {
        Unlocked = false, Locked = true, Warning = false, ["XPGiven?"] = false, Keycard = w.paths[DA.RedKeycard],
        TL_DoorsKeycard = tk }, {
        OnRep_Unlocked = function(self) if self._p.Unlocked then self._p.Locked, self._p.Warning = false, false end end,
        OnRep_Locked = function(self) if self._p.Locked then self._p.Unlocked, self._p.Warning = false, false end end,
        OnRep_Warning = function(self) if self._p.Warning then self._p.Unlocked, self._p.Locked = false, false end end,
        Event_Door = function(self)
            if self._p.Locked then
                local out = {}
                w.jig:ServerFindThenConsumeByItemID(self._p.Keycard, 1, out)
                if not out.Result then w.note("No Keycard Available") return end
                self._p["XPGiven?"] = true
                self._p.Unlocked = true; self:OnRep_Unlocked()
                tk:Play()
            elseif not self._p.Warning then
                if tk._playing and not tk._rev or (not tk._playing and tk._pos > 0) then tk:Reverse() else tk:Play() end
            end
        end,
        OnExecuteInteract = function(self, actor, opt)
            self:Event_Door()
            post(w, P.sdoor .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    -- a laboratory light switch: Event_LightSwitch toggles (@3192), On? / Off? + their OnRep
    o.sw = bp({ "BP_LaboratoryLightSwitch_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryLightSwitch_C_4",
        { ["On?"] = false, ["Off?"] = false, ["Warning?"] = false }, {
        ["OnRep_On?"] = function(self) if self._p["On?"] then self._p["Off?"], self._p["Warning?"] = false, false end end,
        ["OnRep_Off?"] = function(self) if self._p["Off?"] then self._p["On?"], self._p["Warning?"] = false, false end end,
        ["OnRep_Warning?"] = function(self) if self._p["Warning?"] then self._p["On?"], self._p["Off?"] = false, false end end,
        Event_LightSwitch = function(self)
            if self._p["On?"] then self._p["Off?"] = true; self["OnRep_Off?"](self)
            else self._p["On?"] = true; self["OnRep_On?"](self) end
        end,
    })
    -- the circuit box (BP_LaboratoryCircuitBox): Event_Door opens its door
    -- (@3982), then plays TL_Levers (@3028); the levers' end
    -- (TL_Levers__FinishedFunc -> @3918) toggles its switches and ends it
    -- (its panel: `Timeline` opens it, @381; TL_DoorReverse closes it, @3944)
    local cbox
    local tl = timeline(w, "TL_Levers_" .. w.id, nil, function(rev) if not rev then cbox:TL_Levers__FinishedFunc() end end)
    local panel = timeline(w, "Timeline_" .. w.id)
    local closing = timeline(w, "TL_DoorReverse_" .. w.id)
    made[#made + 1] = tl; made[#made + 1] = panel; made[#made + 1] = closing
    cbox = bp({ "BP_LaboratoryCircuitBox_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryCircuitBox_C_2", {
        ["DoorClosed?"] = true, ["CanInteract?"] = true, ["DamageToActivate?"] = false, TL_Levers = tl,
        Timeline = panel, TL_DoorReverse = closing, LightSwitches = { o.sw } }, {
        Event_Door = function(self)
            if self._p["DoorClosed?"] then self._p["DoorClosed?"] = false; panel:Play() else tl:Play() end
        end,
        TL_Levers__FinishedFunc = function(self)
            self._calls[#self._calls + 1] = { "TL_Levers__FinishedFunc" }
            for _, s in ipairs(self._p.LightSwitches) do s:Event_LightSwitch() end
            self._p["CanInteract?"] = false
            closing:Play()
        end,
    })
    o.cbox = cbox
    -- a siren: plays by itself (its random timer) or by a press
    o.siren = bp({ "BP_Siren_C", "BP_MasterObject_C" }, "BP_Siren_C_3", { Playing = false }, {
        ActivateSiren = function(self) self._p.Playing = true end,
        DeactivateSiren = function(self) self._p.Playing = false end,
    })
    -- a laboratory cable: a laboratory actor that is not tracked
    bp({ "BP_LaboratoryCable_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryCable_C_1", {})
    w.level = made
    return o
end

-- a player gets through a door when it stands open (its timeline at the end, forward)
local function passable(d)
    local t = d._p.DoorTimeline
    return d._valid and d._p["Open?"] == true and not t._playing and t._pos >= 1
end

-- ---------------------------------------------------------------- load modules per world
local function load_mods(w)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    local get0 = m.cfg.get
    m.cfg.get = function(k, ...) if k == "net_send_budget" then return false end return get0(k, ...) end
    m.net.install_hooks()
    m.world = require("sdc_world")
    m.list = require("sdc_puzzlelist")
    return m
end
local H = load_mods(HW)
H.ctx.scope_resolver = function() return nil end
-- the host opened its world to friends: the main menu of the listening world
-- (no character of its own yet), the client already connected
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "PersistentLevel", in_menu = true }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "PersistentLevel", in_menu = false,
             client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
-- sdc_notes as far as sdc_world uses it here: quietly(why, fn, ...) runs fn
-- with the game's notes it raises kept off the screen (labels noted)
local QUIET = {}
package.loaded["sdc_notes"] = { quietly = function(why, fn, ...) QUIET[#QUIET + 1] = tostring(why); return pcall(fn, ...) end }
local function quiet_restores()
    local k = 0
    for _, w in ipairs(QUIET) do if w:find("^restoring") then k = k + 1 end end
    return k
end
local HPW = H.world._t.power
local TMPDIR = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
local FILE_PREFIX = TMPDIR .. "/sdc_bunkertest_" .. tostring(os.time()) .. "_"
HPW.dir = FILE_PREFIX
local SAVE1 = FILE_PREFIX .. "Slot1_SDCoop_World.txt"

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
local function ticks(n, dt)
    for _ = 1, n do
        advance(dt or 0.25)
        WORLD = HW; H.world.tick(); deliver()
        WORLD = CW; C.world.tick(); deliver()
        settle()
    end
end
local function st(w, o)
    WORLD = w
    local PWm = w == HW and HPW or C.world._t.power
    return PWm.K[PWm.kind_of(o)].state(o)
end
local function file_text(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("a")
    h:close()
    return s
end
local function write_file(path, s)
    local h = assert(io.open(path, "wb"))
    h:write(s)
    h:close()
end

print("== B0. hooks")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
check(HW.hooks[P.load] ~= nil, "the game's load (EMS AsyncLoadActors) is hooked")

-- the slot's file from an earlier session: the second bunker opened
-- (and the laboratory's circuit box done, its light switch on; a siren that
-- was playing by itself at that save - a file of 0.11.0 saved sirens)
write_file(SAVE1, "# SDCoop test\n~LongdownValley~BP_BunkerScanner_C_12=10\n~LongdownValley~BP_LargeBunkerEntrance_Small_C_3=o\n"
    .. "~LongdownValley~BP_LaboratoryCircuitBox_C_2=2\n~LongdownValley~BP_LaboratoryLightSwitch_C_4=1\n~LongdownValley~BP_Siren_C_3=1\n")

print("== B1. the main menu of the listening world: nothing is listed there")
ticks(40, 0.25)
check(HPW.objs == nil, "no puzzle / power list while the host is in the main menu (the map is not streamed in)")
check(file_text(SAVE1):find("Small_C_3=o", 1, true) ~= nil, "the slot's file untouched")

print("== B2. Continue: the map streams in, the game loads the save; the list is made in the world")
local HO = level(HW)
local CO = level(CW)
HS.in_menu = false
local snd0 = #HW.sounds
fire(HW, P.load, param(nil), param(HW.pc))
ticks(40, 0.25)
local n = HPW.objs and #HPW.objs or 0
check(n == 8, "2 scanners, 2 bunker doors, a laboratory door, a circuit box, a switch, a siren listed (" .. n .. "), not the cable")
check(HO.scan12._p["Unlocked?"] == true and HO.door3._p["Open?"] == true, "the save's bunker open again on the host")
local door_snd = 0
for i = snd0 + 1, #HW.sounds do if HW.sounds[i] == "door" then door_snd = door_snd + 1 end end
check(door_snd == 0, "restored without the door's sound on the host (" .. door_snd .. ")")
check(quiet_restores() >= 2, "restored quietly: the game's notes of it stay off the screen (" .. quiet_restores() .. ")")
check(st(HW, HO.cbox) == "2" and st(HW, HO.sw) == "1", "the circuit box done, its switch on (as saved)")
local panel, closing = HO.cbox._p.Timeline, HO.cbox._p.TL_DoorReverse
check(not panel._playing and panel._pos == 1 and closing._playing,
    "its panel: the opening at its end, only the closing plays (not two timelines on one door)")
check(HO.siren._p.Playing == false, "the old file's playing siren left alone: silent")
finish(HW); finish(CW); ticks(4, 0.25)
check(st(CW, CO.scan12) == "10" and passable(CO.door3), "and on the client (BP_LargeBunkerEntrance_Small: a child class)")
ticks(20, 0.25); finish(HW)
check(st(HW, HO.sw) == "1" and #HO.cbox._calls == 1, "the box's levers chain ran once, inside the restore: the switch stays on")

print("== B3. the client uses scanner _7 with its keycard: its door opens on the client too")
INV.client.DA_Level1Keycard = 1
WORLD = CW; CO.scan7:OnExecuteInteract(CW.pawn, { TagName = FName("Jig.InteractOptions.Option1") })
check(CO.scan7._p["Unlocked?"] == false, "(the client's own copy does nothing: the press goes the server path)")
-- the server path on the host: OnServerExecuteInteract -> MC_CallInteract(the client's character)
WORLD = HW; HO.scan7:MC_CallInteract(rpawn)
check(INV.client.DA_Level1Keycard == 0 and HO.scan7._p["Unlocked?"] == true, "the host took the client's keycard, unlocked")
check(HO.door7._p["Open?"] == true, "the host's door opens")
ticks(4, 0.25)
finish(HW); finish(CW)
check(passable(HO.door7), "the host walks through")
check(st(CW, CO.scan7) == "10", "the client's scanner unlocked")
check(passable(CO.door7), "the client's copy of the door is open: the client walks through")
ticks(70, 0.25)   -- the client's looks at 3, 8, 15 s, the host's idle passes
check(passable(CO.door7) and #CO.door7._calls == 1, "it stays open, toggled once")

print("== B4. the unlocked scanner used again closes the doors (the game's toggle): closed on both, then open again")
WORLD = HW; HO.scan7:MC_CallInteract(rpawn)   -- the client's next press, on the host
ticks(4, 0.25)
finish(HW); finish(CW)
check(HO.door7._p["Open?"] == false and CO.door7._p["Open?"] == false and not passable(CO.door7), "closed on both")
WORLD = HW; HO.scan7:MC_CallInteract(HW.pawn)   -- the host's own press
ticks(4, 0.25)
finish(HW); finish(CW)
check(passable(HO.door7) and passable(CO.door7), "open on both again")

print("== B5. a laboratory door the host opens with its keycard opens for the client")
INV.host.DA_RedKeycard = 1
WORLD = HW; HO.sdoor:OnExecuteInteract(HW.pawn, { TagName = FName("Jig.InteractOptions.Option1") })
ticks(4, 0.25)
check(st(HW, HO.sdoor) == "uo1" and st(CW, CO.sdoor) == "uo1", "unlocked and open on both")

print("== B6. a player who joins later gets the open bunkers")
CO = level(CW)   -- the joiner's fresh copies: everything closed
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 30 do WORLD = HW; H.world.tick(); deliver() end
ticks(4, 0.25)
finish(CW)
check(st(CW, CO.scan7) == "10" and passable(CO.door7) and passable(CO.door3) and st(CW, CO.sdoor) == "uo1",
    "both scanners unlocked, both bunker doors and the laboratory door open")

print("== B7. the host's save keeps them (not a siren playing by itself)")
WORLD = HW; HO.siren:ActivateSiren()   -- its own random timer, 138 s
ticks(24, 0.25)   -- (no hook in this fake: the idle pass finds it)
check(st(CW, CO.siren) == "1", "(the host's siren plays on the client too: the live sync)")
os.remove(SAVE1)
WORLD = HW; fire(HW, P.save, param(HW.pc))
run_timers(HW)
local txt = file_text(SAVE1) or ""
check(txt:find("~LongdownValley~BP_BunkerScanner_C_7=10", 1, true) ~= nil
    and txt:find("~LongdownValley~BP_DoubleBunkerDoor_C_7=o", 1, true) ~= nil
    and txt:find("~LongdownValley~BP_LargeBunkerEntrance_Small_C_3=o", 1, true) ~= nil, "scanners and bunker doors saved")
check(txt:find("~LongdownValley~BP_LaboratorySlidingDoor_C_1=uo1", 1, true) ~= nil, "the laboratory door saved")
check(txt:find("BP_LaboratoryLightSwitch_C_4=1", 1, true) ~= nil and txt:find("BP_LaboratoryCircuitBox_C_2=2", 1, true) ~= nil,
    "the circuit box and its switch on saved")
check(txt:find("BP_Siren_C_3", 1, true) == nil, "the playing siren not saved")

print("== B8. the host loads that save during the session: the map streams in again, the doors open again")
HS.in_menu = true      -- the save menu removed the characters
ticks(4, 0.25)
HO = level(HW)          -- a fresh copy of the map: everything at the level's start
HS.in_menu = false
fire(HW, P.load, param(nil), param(HW.pc))
ticks(40, 0.25)
finish(HW)
check(HO.scan7._p["Unlocked?"] == true and passable(HO.door7) and passable(HO.door3) and st(HW, HO.sdoor) == "uo1",
    "the host's new copies as saved")
ticks(4, 0.25)
finish(CW)
check(passable(CO.door7) and passable(CO.door3), "the client's doors open")

print("== B9. the host loads another save (nothing opened there): a connected client's copies follow")
HW.slot = "Slot2"
HS.in_menu = true
ticks(4, 0.25)
HO = level(HW)
HS.in_menu = false
fire(HW, P.load, param(nil), param(HW.pc))
ticks(40, 0.25)
finish(HW); finish(CW)
check(not passable(HO.door7) and HO.scan7._p["Unlocked?"] == false, "the host's bunker closed (Slot2)")
check(not passable(CO.door7) and not passable(CO.door3) and st(CW, CO.scan7) == "01" and st(CW, CO.sdoor):sub(1, 2) == "lc",
    "the client's copies (still the old world's) closed and locked as on the host")

local SAVE2 = FILE_PREFIX .. "Slot2_SDCoop_World.txt"
local function save_now(path)
    os.remove(path)
    WORLD = HW; fire(HW, P.save, param(HW.pc))
    run_timers(HW)
    return file_text(path) or ""
end

print("== B9b. Slot1 again, then Slot2 into the same level (the engine did not load it anew)")
HW.slot = "Slot1"
HS.in_menu = true; ticks(4, 0.25)
HO = level(HW)
HS.in_menu = false
fire(HW, P.load, param(nil), param(HW.pc))
ticks(40, 0.25); finish(HW); finish(CW)
check(passable(HO.door7) and passable(HO.door3) and passable(CO.door7), "(Slot1: open on both)")
HW.slot = "Slot2"
HS.in_menu = true; ticks(4, 0.25)
HS.in_menu = false   -- the same actors, still open
fire(HW, P.load, param(nil), param(HW.pc))
ticks(40, 0.25); finish(HW); finish(CW)
check(not passable(HO.door7) and not passable(HO.door3) and HO.scan7._p["Unlocked?"] == false
    and st(HW, HO.sdoor):sub(1, 2) == "lc", "the host's objects not in Slot2's file back to the level's start")
check(not passable(CO.door7) and not passable(CO.door3) and st(CW, CO.scan7) == "01", "and the client's")
txt = save_now(SAVE2)
check(txt:find("BunkerDoor_C_7=", 1, true) == nil and txt:find("Small_C_3=", 1, true) == nil
    and txt:find("BunkerScanner_C_7=", 1, true) == nil, "Slot2's save has no open bunker")

print("== N1. the host quits to its main menu: the list goes; a New Game (no load call) lists its own new level")
HS.in_menu, HS.real_menu_at = true, T   -- the menu's MenuWidget on screen (sdc_session.host_menu_tick)
ticks(8, 0.25)
check(HPW.objs == nil, "the list dropped in the host's main menu")
local OLD = HO
HW.slot = "Slot3"
HO = level(HW)   -- New Game: a fresh copy of the map (the old one is gone)
CO = level(CW)   -- (the client joins it again)
HS.real_menu_at, HS.in_menu = nil, false
ticks(40, 0.25)
local D7 = LVL .. "BP_DoubleBunkerDoor_C_7"
check(HPW.objs ~= nil and #HPW.objs == 8 and HPW.idx[D7] and HPW.idx[D7].o == HO.door7, "the new level listed")
-- the old door _7's memory now holds another live object (the new door _3)
local ghost = OLD.door7
ghost._valid, ghost._p, ghost._full = true, HO.door3._p, HO.door3._full
HPW.idx[D7].o = ghost
WORLD = HW; HO.door3:CallInteractOnObject()   -- door _3 only (no press hook: the idle pass finds it)
ticks(40, 0.25); finish(HW); finish(CW)
check(passable(HO.door3) and not passable(HO.door7), "(host: door _3 open, door _7 closed)")
check(passable(CO.door3) and not passable(CO.door7), "the client: door _3 open, door _7 closed as on the host")
txt = save_now(FILE_PREFIX .. "Slot3_SDCoop_World.txt")
check(txt:find("Small_C_3=o", 1, true) ~= nil and txt:find("BunkerDoor_C_7=", 1, true) == nil,
    "the save: door _3 open, nothing about door _7")
ghost._valid = false   -- (the stand-in for that memory goes with this level)

print("== D1. the host dies (the death screen, the same world): the list stays; a player joining then gets the doors")
HS.in_menu = true   -- no character of its own; not the main menu (real_menu_at stays nil)
ticks(40, 0.25)
check(HPW.objs ~= nil and #HPW.objs == 8, "the list kept while the host is dead")
CO = level(CW)
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 30 do WORLD = HW; H.world.tick(); deliver() end
ticks(4, 0.25); finish(CW)
check(passable(CO.door3) and not passable(CO.door7), "the joiner gets door _3 open while the host is dead")
HS.in_menu = false   -- respawned
ticks(4, 0.25)

print("== L1. Continue of Slot1, the game's load call after the 5 s list and its restore")
HS.in_menu, HS.real_menu_at = true, T
ticks(8, 0.25)
HW.slot = "Slot1"
HO = level(HW)
-- (this box's levers refuse SetNewTime here: an engine error must not skip their Stop and chain)
HO.cbox._p.TL_Levers._m.SetNewTime = function() error("SetNewTime failed") end
HS.real_menu_at, HS.in_menu = nil, false
ticks(40, 0.25); finish(HW)
check(passable(HO.door3) and passable(HO.door7) and HO.scan7._p["Unlocked?"] == true, "(restored before the load call)")
check(st(HW, HO.sw) == "1" and #HO.cbox._calls == 1, "a failing SetNewTime: the levers' chain still ran once in the restore, the switch stays on")
fire(HW, P.load, param(nil), param(HW.pc))   -- the load call, late
ticks(40, 0.25); finish(HW)
txt = save_now(SAVE1)
check(txt:find("Small_C_3=o", 1, true) ~= nil and txt:find("BunkerDoor_C_7=o", 1, true) ~= nil
    and txt:find("BunkerScanner_C_7=10", 1, true) ~= nil, "the next save still has the open bunkers")
CO = level(CW)
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 30 do WORLD = HW; H.world.tick(); deliver() end
ticks(4, 0.25); finish(CW)
check(passable(CO.door3) and passable(CO.door7), "a joiner gets them open")

print("== B10. a save while nothing is listed or the level is gone keeps the slot's file")
HW.slot = "Slot1"
local before = file_text(SAVE1)
for _, o in ipairs(HW.level) do o._valid = false end   -- the map streamed out (quit to the menu)
WORLD = HW; fire(HW, P.save, param(HW.pc))
run_timers(HW)
check(file_text(SAVE1) == before, "the level streamed out: the file keeps its states")
-- a world whose list came out empty (the map was not there yet)
WORLD = HW; H.world.reset("world:loadmap")
ticks(40, 0.25)
check(HPW.objs ~= nil and #HPW.objs == 0, "(listed with nothing in the world)")
WORLD = HW; fire(HW, P.save, param(HW.pc))
run_timers(HW)
check(file_text(SAVE1) == before, "an empty list: the file keeps its states")

print("== B11. the map comes in after an empty list: listed again (the same world: the sirens' press notes stay)")
HPW.flip["probe-test"] = { a = 1, v = true }
HO = level(HW)
ticks(100, 1.0)
n = HPW.objs and #HPW.objs or 0
check(n == 8, "listed again once its objects are in the world (" .. n .. ")")
check(HO.scan7._p["Unlocked?"] == true and HO.door7._p["Open?"] == true, "and the slot's states applied")
check(HPW.flip["probe-test"] ~= nil, "a siren's press note kept")

print("== B12. status")
WORLD = HW
local line = H.world.status_line()
print(H.list.status_line())
check(line:find("puzzlelist: game loads=", 1, true) ~= nil, "the world's status line has the list's part")
local s = H.list.stats
check(s.loads == 6 and s.menus == 2 and s.full_sends >= 1 and s.saves_kept == 2 and s.probes == 1,
    "6 loads, 2 main menus, all states after a load with a player connected, 2 saves kept, 1 list made again")

os.remove(SAVE1)
os.remove(SAVE2)
os.remove(FILE_PREFIX .. "Slot3_SDCoop_World.txt")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
