-- Mock harness: the puzzle / power shared state of sdc_world (world_doors):
-- generators, levers, circuit boxes, switches, lights, laboratory and bunker
-- doors, scanners, sirens, radios, the keycard door's card, the nuke, the save;
-- and the host's airdrop / jet logs and the sdcoop_events / sdcoop_airdrop commands.
-- usage: lua mock_world_power.lua <scripts dir>
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
-- Power / laboratory / bunker puzzle, sirens, radios, keycard doors, the nuke
-- (sdc_world PW section, 0.6.62). Fake Blueprints below behave like the
-- decompiled ones (work\re\pseudo) on each machine: nothing replicates,
-- FindJigItemByDA sees the owner's widgets only, ServerFindThenConsumeByItemID
-- the host's containers only.
-- ===========================================================================
local MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"
local P = {
    pgen = "/Game/Blueprints/Other/Power/BP_PowerGenerator.BP_PowerGenerator_C",
    lgen = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryGenerator.BP_LaboratoryGenerator_C",
    lever = "/Game/Blueprints/Other/Power/BP_Lever.BP_Lever_C",
    cbox = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryCircuitBox.BP_LaboratoryCircuitBox_C",
    sw = "/Game/Blueprints/Laboratory/Blueprints/Lights/BP_LaboratoryLightSwitch.BP_LaboratoryLightSwitch_C",
    sdoor = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySlidingDoor.BP_LaboratorySlidingDoor_C",
    secure = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySecureDoors.BP_LaboratorySecureDoors_C",
    scan = "/Game/Blueprints/Bunker/BP_BunkerScanner.BP_BunkerScanner_C",
    siren = "/Game/Blueprints/Other/Objects/BP_Siren.BP_Siren_C",
    radio = "/Game/Blueprints/Other/Radio/BP_Radio.BP_Radio_C",
    kdoor = "/Game/Blueprints/Other/Doors/BP_KeycardDoor.BP_KeycardDoor_C",
    nuke = "/Game/Blueprints/Other/EasterEggs/BP_EasterEgg_Nuke.BP_EasterEgg_Nuke_C",
    save = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot",
    delete = "/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot",
    firearm = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C",
}
local DA = {
    AllAccess = "/Game/Inventory/Items/DataAssets/Keycards/DA_AllAccessKeycard.DA_AllAccessKeycard",
    GasCan = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan",
    Fuse = "/Game/Inventory/Items/DataAssets/Misc/DA_Fuse.DA_Fuse",
    RedKeycard = "/Game/Inventory/Items/DataAssets/Keycards/DA_RedKeycard.DA_RedKeycard",
    BlueKeycard = "/Game/Inventory/Items/DataAssets/Keycards/DA_BlueKeycard.DA_BlueKeycard",
}
-- what each player carries: the owner's widgets show it (FindJigItemByDA on
-- the owner's machine), the host's containers hold it (consume on the host)
local INV = { host = {}, client = {} }
local consumed = {}   -- { { who, item } }
local function inv_has(who, da) return da and (INV[who][da._name] or 0) > 0 end
local function inv_take(who, da)
    if not inv_has(who, da) then return false end
    INV[who][da._name] = INV[who][da._name] - 1
    consumed[#consumed + 1] = { who, da._name }
    return true
end

local OPT1 = { TagName = FName("Jig.InteractOptions.Option1") }
local OPT2 = { TagName = FName("Jig.InteractOptions.Option2") }

local function tl_fwd(t) if t._playing then return not t._rev end return t._pos > 0.001 end
local function timeline(w, name, on_finish)
    local t = new(w, { "TimelineComponent" }, name, {}, {})
    t._pos, t._playing, t._rev, t._on = 0, false, false, on_finish
    t._m.IsPlaying = function(self) return self._playing end
    t._m.IsReversing = function(self) return self._rev end
    t._m.GetPlaybackPosition = function(self) return self._pos end
    t._m.Play = function(self) self._playing, self._rev = true, false; self._calls[#self._calls + 1] = { "Play" } end
    t._m.PlayFromStart = function(self) self._pos, self._playing, self._rev = 0, true, false; self._calls[#self._calls + 1] = { "PlayFromStart" } end
    t._m.Reverse = function(self) self._playing, self._rev = true, true; self._calls[#self._calls + 1] = { "Reverse" } end
    w.tls[#w.tls + 1] = t
    return t
end
-- every timeline that plays reaches its end (and its finished event runs)
local function finish(w)
    WORLD = w
    for _ = 1, 6 do
        local any = false
        for _, t in ipairs(w.tls) do
            if t._playing then
                any = true
                t._playing = false
                t._pos = t._rev and 0 or 1
                if t._on then t._on(t._rev) end
            end
        end
        if not any then return end
    end
end

-- the game's notes (GameFunctionLibrary.CreateNotificationUI -> the HUD's VerticalBox_31)
local function notes_of(w)
    local out = {}
    for _, c in ipairs(w.vb._children) do out[#out + 1] = c._p.NotificationDetailsStruct[MSG]:ToString() end
    return out
end
local function has_note(w, text)
    for _, s in ipairs(notes_of(w)) do if s == text then return true end end
    return false
end

local function setup_ui(w)
    WORLD = w
    w.tls = {}
    w.slot = "Slot1"
    local vb = new(w, { "VerticalBox" }, "VerticalBox_31_" .. w.id, {}, {})
    vb._children = {}
    vb._m.GetChildrenCount = function(self) return #self._children end
    vb._m.GetChildAt = function(self, i) return self._children[i + 1] end
    local parent = new(w, { "NotificationParentWidget_C" }, "Notifications_" .. w.id, { VerticalBox_31 = vb })
    local hud = new(w, { "HUD_Game_C" }, "HUD_Game_" .. w.id, { NotificationUI = parent })
    w.pc._m.GetHUD = function() return hud end
    w.vb = vb
    local n = 0
    new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(self, text, icon, col, delay, force, wco)
            local s = type(text) == "string" and text or text:ToString()
            for _, c in ipairs(vb._children) do
                if not force and c._p.NotificationDetailsStruct[MSG]:ToString() == s then return end   -- @480
            end
            n = n + 1
            local note
            note = new(w, { "NotficationUI_C" }, "Note_" .. n, { NotificationDetailsStruct = { [MSG] = FText(s) } }, {
                RemoveFromParent = function()
                    for i, c in ipairs(vb._children) do if c == note then table.remove(vb._children, i) return end end
                end,
            })
            vb._children[#vb._children + 1] = note
        end,
    }, "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
    w.note = function(s) w.paths["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"]:CreateNotificationUI(FText(s), nil, {}, 2, false, w.pc) end
    new(w, { "EMSFunctionLibrary" }, "Default__EMSFunctionLibrary", {}, {
        GetSlotInfoSaveGame = function(self, wc, out) out.SaveGameName = w.slot end,
    }, "/Script/EasyMultiSave.Default__EMSFunctionLibrary")
    for k, p in pairs(DA) do w.paths[p] = new(w, { "JigsawItem_DataAsset_C" }, "DA_" .. k, {}, {}, p) end
    for _, m in ipairs({ "Green", "Red" }) do
        local p = "/Game/Meshes/Materials/M_EmissiveColour_" .. m .. ".M_EmissiveColour_" .. m
        new(w, { "Material" }, "M_EmissiveColour_" .. m, {}, {}, p)
    end
    -- XP
    local lc = new(w, { "LevellingComponent_C" }, "LevellingComponent_" .. w.id, { CurrentLevel = 3 }, {
        AddXP = function(self, xp, up, out) self._calls[#self._calls + 1] = { "AddXP", xp }; out.XPOutput = xp end,
    })
    w.pc._p.LevellingComponent = lc
    w.lc = lc
end
setup_ui(HW)
setup_ui(CW)

-- inventories: the owner's view (widgets) and the host's containers
local function jig_methods(jig, find_who, take_who)
    jig._m.FindJigItemByDA = function(self, da, tags, a, b, n, out) out.Result = find_who ~= nil and inv_has(find_who, da) end
    jig._m.ServerFindThenConsumeByItemID = function(self, da, n, out) out.Result = take_who ~= nil and inv_take(take_who, da) end
end
jig_methods(HW.jig, "host", "host")      -- the host's own: widgets and containers
jig_methods(rjig, nil, "client")         -- the client's on the host: containers only
jig_methods(CW.jig, "client", nil)       -- the client's own: widgets only

-- ---------------------------------------------------------------- the fake Blueprints, one copy per machine
local function bp(w, chain, name, props, methods) WORLD = w; return new(w, chain, name, props, methods) end
local function post(w, path, self, ...)
    local args = { param(self) }
    for _, a in ipairs({ ... }) do args[#args + 1] = param(a) end
    fire(w, path, table.unpack(args))
end
local function p0jig(w) return w.jig end   -- GetPlayerCharacter(self, 0).BP_JigComponent

local function objects(w)
    local o = {}
    -- lights and switches
    local function light(name)
        return bp(w, { "BP_LaboratoryLight2_C", "BP_LaboratoryLight_C", "BP_LaboratoryMaster_C" }, name, { ["LightOn?"] = false },
            { ["OnRep_LightOn?"] = rec("OnRep_LightOn?") })
    end
    local function switch(name, lights)
        local s
        s = bp(w, { "BP_LaboratoryLightSwitch_C", "BP_LaboratoryMaster_C" }, name,
            { ["On?"] = false, ["Off?"] = false, ["Warning?"] = false, Lights = lights }, {
            ["OnRep_On?"] = function(self)
                if not self._p["On?"] then return end
                self._p["Off?"], self._p["Warning?"] = false, false
                for _, l in ipairs(lights) do l._p["LightOn?"] = true; l:OnRep_LightOn() end
            end,
            ["OnRep_Off?"] = function(self)
                if not self._p["Off?"] then return end
                self._p["On?"], self._p["Warning?"] = false, false
                for _, l in ipairs(lights) do l._p["LightOn?"] = false; l:OnRep_LightOn() end
            end,
            ["OnRep_Warning?"] = function(self)
                if not self._p["Warning?"] then return end
                self._p["On?"], self._p["Off?"] = false, false
                for _, l in ipairs(lights) do l._p["LightOn?"] = false; l:OnRep_LightOn() end
            end,
            SetPower_TurnedOn = function(self, b) self._p["On?"] = b; self["OnRep_On?"](self) end,
            SetPower_Warning = function(self, b) self._p["Warning?"] = b; self["OnRep_Warning?"](self) end,
            Event_LightSwitch = function(self)
                self._calls[#self._calls + 1] = { "Event_LightSwitch" }
                if self._p["On?"] then self._p["Off?"] = true; self["OnRep_Off?"](self)
                else self._p["On?"] = true; self["OnRep_On?"](self) end
            end,
            OnExecuteInteract = function(self, actor, opt)
                if not self._p["Warning?"] then self:Event_LightSwitch() end
                post(w, P.sw .. ":OnExecuteInteract", self, actor, opt)
            end,
        })
        return s
    end
    for _, l in ipairs({ "BP_LaboratoryLight2_C_1", "BP_LaboratoryLight2_C_2", "BP_LaboratoryLight2_C_3" }) do o[l] = light(l) end
    -- (OnRep_LightOn? called as l:OnRep_LightOn() above: a plain alias)
    for _, l in ipairs({ "BP_LaboratoryLight2_C_1", "BP_LaboratoryLight2_C_2", "BP_LaboratoryLight2_C_3" }) do
        o[l]._m.OnRep_LightOn = o[l]._m["OnRep_LightOn?"]
    end
    o.sw1 = switch("BP_LaboratoryLightSwitch_C_1", { o.BP_LaboratoryLight2_C_1, o.BP_LaboratoryLight2_C_2 })
    o.sw2 = switch("BP_LaboratoryLightSwitch_C_2", { o.BP_LaboratoryLight2_C_3 })
    -- sliding doors
    local function sdoor(name, props)
        local d
        local t = timeline(w, "TL_DoorsKeycard_" .. name)
        props.TL_DoorsKeycard = t
        d = bp(w, { "BP_LaboratorySlidingDoor_C", "BP_LaboratoryMaster_C" }, name, props, {
            OnRep_Unlocked = function(self) if self._p.Unlocked then self._p.Locked, self._p.Warning = false, false end end,
            OnRep_Locked = function(self) if self._p.Locked then self._p.Unlocked, self._p.Warning = false, false end end,
            OnRep_Warning = function(self) if self._p.Warning then self._p.Unlocked, self._p.Locked = false, false end end,
            SetPower_TurnedOn = function(self, b) self._p.Unlocked = b; self:OnRep_Unlocked() end,
            SetPower_Warning = function(self, b) self._p.Warning = b; self:OnRep_Warning() end,
            Event_Door = function(self, who)
                if self._p.Locked then
                    local out = {}
                    p0jig(w):FindJigItemByDA(w.paths[DA.AllAccess], {}, true, false, 1, out)
                    if not out.Result then
                        out = {}
                        p0jig(w):ServerFindThenConsumeByItemID(self._p.Keycard, 1, out)
                    end
                    if not out.Result then w.note("No Keycard Available") return end
                    if not self._p["XPGiven?"] then
                        local xo = {}
                        w.lc:AddXP(w.lc._p.CurrentLevel * 400, false, xo)
                        w.note("Door Unlocked, XP Given: " .. math.floor(xo.XPOutput))
                        self._p["XPGiven?"] = true
                    end
                    self._p.Unlocked = true; self:OnRep_Unlocked()
                    t:Play()
                elseif not self._p.Warning then
                    if tl_fwd(t) then t:Reverse() else t:Play() end
                end
            end,
            OnExecuteInteract = function(self, actor, opt)
                self:Event_Door(actor)
                post(w, P.sdoor .. ":OnExecuteInteract", self, actor, opt)
            end,
        })
        return d
    end
    o.sdoor1 = sdoor("BP_LaboratorySlidingDoor_C_1", { Unlocked = false, Locked = false, Warning = false, ["XPGiven?"] = false })
    o.sdoor2 = sdoor("BP_LaboratorySlidingDoor_C_2", { Unlocked = false, Locked = true, Warning = false, ["XPGiven?"] = false,
        Keycard = w.paths[DA.RedKeycard] })
    o.sdoor3 = sdoor("BP_LaboratorySlidingDoor_C_3", { Unlocked = false, Locked = true, Warning = false, ["XPGiven?"] = false,
        Keycard = w.paths[DA.RedKeycard] })
    -- laboratory generator: its switch and its door
    o.lgen = bp(w, { "BP_LaboratoryGenerator_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryGenerator_C_1",
        { ["TurnedOn?"] = false, Actors = { o.sw1, o.sdoor1 } }, {
        Event_TurnOn = function(self, who)
            self._calls[#self._calls + 1] = { "Event_TurnOn", who }
            if self._p["TurnedOn?"] then
                self._p["TurnedOn?"] = false
                for _, a in ipairs(self._p.Actors) do a:SetPower_Warning(true) end
                w.note("Laboratory generator powered off")
            else
                self._p["TurnedOn?"] = true
                for _, a in ipairs(self._p.Actors) do a:SetPower_TurnedOn(true) end
                w.note("Laboratory generator powered on")
            end
        end,
        OnExecuteInteract = function(self, actor, opt)
            self:Event_TurnOn(actor)
            post(w, P.lgen .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    -- circuit box: its door, its levers -> sdoor2 unlocked, sw2 switched
    local levers
    o.cbox = bp(w, { "BP_LaboratoryCircuitBox_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryCircuitBox_C_1",
        { ["DoorClosed?"] = true, ["CanInteract?"] = true, ["DamageToActivate?"] = false, Doors = { o.sdoor2 }, LightSwitches = { o.sw2 } }, {
        Event_Door = function(self)
            self._calls[#self._calls + 1] = { "Event_Door" }
            if self._p["DoorClosed?"] then self._p["DoorClosed?"] = false else levers:Play() end
        end,
        OnExecuteInteract = function(self, actor, opt)
            if not self._p["DamageToActivate?"] and self._p["CanInteract?"] then self:Event_Door() end
            post(w, P.cbox .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    levers = timeline(w, "TL_Levers_" .. w.id, function(rev)
        if rev then return end
        for _, d in ipairs(o.cbox._p.Doors) do d._p.Unlocked = true; d:OnRep_Unlocked() end
        for _, s in ipairs(o.cbox._p.LightSwitches) do s:Event_LightSwitch() end
        o.cbox._p["CanInteract?"] = false
    end)
    o.cbox._p.TL_Levers = levers
    -- bunker doors, the lever, the generator, the scanner
    local function bunker(name)
        local d
        local t = timeline(w, "DoorTimeline_" .. name, function(rev) d._p["Open?"] = not rev end)
        d = bp(w, { "BP_DoubleBunkerDoor_C", "BP_MasterObject_C" }, name, { ["Open?"] = false, DoorTimeline = t }, {
            CallInteractOnObject = function(self)
                self._calls[#self._calls + 1] = { "CallInteractOnObject" }
                if tl_fwd(t) then t:Reverse() else t:Play() end
            end,
        })
        return d
    end
    o.bunker1 = bunker("BP_DoubleBunkerDoor_C_1")
    o.bunker2 = bunker("BP_DoubleBunkerDoor_C_2")
    local lt = timeline(w, "LeverMovement_" .. w.id)
    o.lever = bp(w, { "BP_Lever_C", "BP_MasterObject_C" }, "BP_Lever_C_1", { PoweredOn = false, LeverMovement = lt, Actors = { o.bunker1 } }, {
        SetPower_TurnedOn = function(self, b) self._p.PoweredOn = b end,
        OnExecuteInteract = function(self, actor, opt)
            self._calls[#self._calls + 1] = { "OnExecuteInteract", actor }
            if self._p.PoweredOn then
                for _, a in ipairs(self._p.Actors) do a:CallInteractOnObject() end
                if tl_fwd(lt) then lt:Reverse() else lt:PlayFromStart() end
            else
                w.note("No Power To Lever")
            end
            post(w, P.lever .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    o.pgen = bp(w, { "BP_PowerGenerator_C", "BP_MasterObject_C" }, "BP_PowerGenerator_C_1", {
        ["TurnedOn?"] = false, ["GasAdded?"] = false, ["ItemUsed?"] = false, ["RequiredItemToPowerOn?"] = true,
        ["ConsumeItemOnUse?"] = true, RequiredItem = w.paths[DA.Fuse], DisplayItemName = FText("Fuse"), Actors = { o.lever } }, {
        Event_TurnOn = function(self, who)
            self._calls[#self._calls + 1] = { "Event_TurnOn", who }
            if not self._p["GasAdded?"] then w.note("No Gas In Generator") return end
            if self._p["TurnedOn?"] then
                self._p["TurnedOn?"] = false
                for _, a in ipairs(self._p.Actors) do a:SetPower_TurnedOn(false) end
                w.note("Generator powered off...")
                return
            end
            if not self._p["ItemUsed?"] and self._p["RequiredItemToPowerOn?"] then
                local out = {}
                p0jig(w):FindJigItemByDA(self._p.RequiredItem, {}, true, false, 1, out)
                if out.Result and self._p["ConsumeItemOnUse?"] then
                    out = {}
                    p0jig(w):ServerFindThenConsumeByItemID(self._p.RequiredItem, 1, out)
                end
                if not out.Result then w.note(self._p.DisplayItemName:ToString() .. " Not Found") return end
            end
            self._p["ItemUsed?"], self._p["TurnedOn?"] = true, true
            w.note("Generator powered on...")
            for _, a in ipairs(self._p.Actors) do a:SetPower_TurnedOn(true) end
        end,
        Event_AddGas = function(self, who)
            if self._p["GasAdded?"] then w.note("Gas Already Added") return end
            local out = {}
            p0jig(w):ServerFindThenConsumeByItemID(w.paths[DA.GasCan], 1, out)
            if out.Result then self._p["GasAdded?"] = true; w.note("Generator Refueled")
            else w.note("No Gas Can In Inventory") end
        end,
        OnExecuteInteract = function(self, actor, opt)
            if opt.TagName:ToString():find("Option2") then self:Event_AddGas(actor) else self:Event_TurnOn(actor) end
            post(w, P.pgen .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    local scanmesh = new(w, { "StaticMeshComponent" }, "Scanner_" .. w.id, {}, { SetMaterial = rec("SetMaterial") })
    o.scan = bp(w, { "BP_BunkerScanner_C", "BP_MasterObject_C" }, "BP_BunkerScanner_C_1", {
        ["Unlocked?"] = false, ["KeycardRequired?"] = true, Keycard = w.paths[DA.BlueKeycard], Scanner = scanmesh,
        ListeningActor = { o.bunker2 } }, {
        -- FindKeycard with the interacting actor's inventory, then the doors
        MC_CallInteract = function(self, actor)
            local ok = not self._p["KeycardRequired?"]
            local jig = actor and actor._p.BP_JigMultiplayer
            if not ok and jig then
                local out = {}
                jig:FindJigItemByDA(w.paths[DA.AllAccess], {}, true, false, 1, out)
                if not out.Result then out = {}; jig:ServerFindThenConsumeByItemID(self._p.Keycard, 1, out) end
                ok = out.Result
            end
            if ok and not self._p["Unlocked?"] then
                self._p["Unlocked?"], self._p["KeycardRequired?"] = true, false
                scanmesh:SetMaterial(1, w.paths["/Game/Meshes/Materials/M_EmissiveColour_Green.M_EmissiveColour_Green"])
                for _, a in ipairs(self._p.ListeningActor) do a:CallInteractOnObject() end
            elseif not ok then
                w.note("No Keycard Available")
            end
            post(w, P.scan .. ":MC_CallInteract", self, actor)
        end,
        OnExecuteInteract = function(self, actor, opt) post(w, P.scan .. ":OnExecuteInteract", self, actor, opt) end,
    })
    -- secure doors: card, mechanism, doors
    local sd
    local tdoors = timeline(w, "TL_Doors_" .. w.id, function(rev) if rev then sd._p.IsClosed = true end end)
    local tmech = timeline(w, "TL_Mechanism_" .. w.id, function(rev) if not rev then tdoors:Play() end end)
    local tmrev
    tmrev = timeline(w, "TL_MechanismReverse_" .. w.id, function(rev) if not rev then tmrev._pos = 0; tdoors:Reverse() end end)
    sd = bp(w, { "BP_LaboratorySecureDoors_C", "BP_LaboratoryMaster_C" }, "BP_LaboratorySecureDoors_C_1", {
        IsClosed = true, Unlocked = false, ["XPGiven?"] = false, Keycard = w.paths[DA.BlueKeycard],
        TL_Doors = tdoors, TL_Mechanism = tmech, TL_MechanismReverse = tmrev }, {
        Event_Door = function(self, who)
            if self._p.IsClosed then
                local out = {}
                p0jig(w):FindJigItemByDA(w.paths[DA.AllAccess], {}, true, false, 1, out)
                if not out.Result then out = {}; p0jig(w):ServerFindThenConsumeByItemID(self._p.Keycard, 1, out) end
                if not out.Result then w.note("No Keycard Available") return end
                if not self._p["XPGiven?"] then
                    local xo = {}
                    w.lc:AddXP(w.lc._p.CurrentLevel * 400, false, xo)
                    w.note("Door Unlocked, XP Given: " .. math.floor(xo.XPOutput))
                    self._p["XPGiven?"] = true
                end
                self._p.Unlocked, self._p.IsClosed = true, false
                tmech:Play()
            else
                tmrev:Play()
            end
        end,
        OnExecuteInteract = function(self, actor, opt)
            self:Event_Door(actor)
            post(w, P.secure .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    o.secure = sd
    -- siren: a flip-flop press, a random timer per machine
    local flip = false
    o.siren = bp(w, { "BP_Siren_C", "BP_MasterObject_C" }, "BP_Siren_C_1", { Playing = false }, {
        ActivateSiren = function(self)
            if not self._p.Playing then self._p.Playing = true end
            post(w, P.siren .. ":ActivateSiren", self)
        end,
        DeactivateSiren = function(self)
            if self._p.Playing then self._p.Playing = false end
            post(w, P.siren .. ":DeactivateSiren", self)
        end,
        OnExecuteInteract = function(self, actor, opt)
            flip = not flip
            if flip then self:ActivateSiren() else self:DeactivateSiren() end
            post(w, P.siren .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    local audio = new(w, { "AudioComponent" }, "RadioAudio_" .. w.id, { VolumeMultiplier = 0 }, {
        SetVolumeMultiplier = function(self, v) self._p.VolumeMultiplier = v end,
    })
    o.radio = bp(w, { "BP_Radio_C", "BP_MasterObject_C" }, "BP_Radio_C_1", { Audio = audio }, {
        OnExecuteInteract = function(self, actor, opt)
            audio:SetVolumeMultiplier(audio._p.VolumeMultiplier == 0 and 0.5 or 0)
            post(w, P.radio .. ":OnExecuteInteract", self, actor, opt)
        end,
    })
    -- the replicated keycard door (RDOOR "Open?")
    local kt
    o.kdoor = bp(w, { "BP_KeycardDoor_C", "BP_MasterDoor_C" }, "BP_KeycardDoor_C_1", { ["Open?"] = false }, {
        MC_OpenDoor = function(self, actor)
            self._calls[#self._calls + 1] = { "MC_OpenDoor", actor }
            if self._p["Open?"] then self._p["Open?"] = false return end
            -- Event_OpenDoor: the card of that Actor (none: nothing)
            if not actor then return end
        end,
        OnExecuteInteract = function(self, actor, opt) post(w, P.kdoor .. ":OnExecuteInteract", self, actor, opt) end,
    })
    kt = timeline(w, "Timeline_OpenDoor_" .. w.id, function(rev) if not rev then o.kdoor._p["Open?"] = true end end)
    o.kdoor._p.Timeline_OpenDoor = kt
    -- the nuke: Damage_Object -> Svr_Explode -> MC_Explode (all local), DoOnce
    local function nuke(name)
        local n
        n = bp(w, { "BP_EasterEgg_Nuke_C", "BP_MasterObject_C" }, name, {}, {
            Damage_Object = function(self, dmg, causer, inst)
                self._calls[#self._calls + 1] = { "Damage_Object", dmg, causer }
                fire(w, P.nuke .. ":Damage_Object", param(self), param(dmg), param(causer), param(inst))
                self:MC_Explode(inst)
            end,
            MC_Explode = function(self, inst)
                if self._boom then return end
                self._boom = true
                self._calls[#self._calls + 1] = { "MC_Explode", inst }
                self._valid = false   -- K2_DestroyActor
                fire(w, P.nuke .. ":MC_Explode", param(self), param(inst))
            end,
            K2_DestroyActor = function(self) self._calls[#self._calls + 1] = { "K2_DestroyActor" }; self._valid = false end,
        })
        return n
    end
    o.nuke = nuke("BP_EasterEgg_Nuke_C_1")
    o.mknuke = nuke
    o.reset = function()
        -- the level's start state (a new copy of the world)
        for _, l in ipairs({ "BP_LaboratoryLight2_C_1", "BP_LaboratoryLight2_C_2", "BP_LaboratoryLight2_C_3" }) do o[l]._p["LightOn?"] = false end
        for _, s in ipairs({ o.sw1, o.sw2 }) do s._p["On?"], s._p["Off?"], s._p["Warning?"] = false, false, false end
        o.sdoor1._p.Unlocked, o.sdoor1._p.Locked = false, false
        for _, d in ipairs({ o.sdoor2, o.sdoor3 }) do d._p.Unlocked, d._p.Locked, d._p["XPGiven?"] = false, true, false end
        for _, d in ipairs({ o.sdoor1, o.sdoor2, o.sdoor3 }) do d._p["XPGiven?"] = false end
        o.lgen._p["TurnedOn?"] = false
        o.cbox._p["DoorClosed?"], o.cbox._p["CanInteract?"] = true, true
        o.bunker1._p["Open?"], o.bunker2._p["Open?"] = false, false
        o.lever._p.PoweredOn = false
        o.pgen._p["TurnedOn?"], o.pgen._p["GasAdded?"], o.pgen._p["ItemUsed?"] = false, false, false
        o.scan._p["Unlocked?"], o.scan._p["KeycardRequired?"] = false, true
        o.secure._p.IsClosed, o.secure._p.Unlocked, o.secure._p["XPGiven?"] = true, false, false
        o.siren._p.Playing = false
        o.radio._p.Audio._p.VolumeMultiplier = 0
        o.kdoor._p["Open?"] = false
        for _, t in ipairs(w.tls) do t._pos, t._playing, t._rev = 0, false, false end
    end
    return o
end
local HO = objects(HW)
local CO = objects(CW)
-- a non-puzzle laboratory actor (cables, stairwell lights): not tracked
bp(HW, { "BP_LaboratoryCable_C", "BP_LaboratoryMaster_C" }, "BP_LaboratoryCable_C_1", {})
-- the client's gun (its shots end in Trace_Impact)
local cgun = new(CW, { "BP_M4Pickup_C", "BP_FirearmPickup_C" }, "BP_M4Pickup_C_78", { _owner = CW.pawn })

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
    return m
end
local H = load_mods(HW)
H.ctx.scope_resolver = function() return nil end
local HS = { role = "host", remote_pcs = { rpc }, remote = {}, map = "LongdownValley" }
H.world.install(HS)
local C = load_mods(CW)
local CS = { role = "client", remote_pcs = {}, remote = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc0" } }
C.world.install(CS)
local HPW, CPW = H.world._t.power, C.world._t.power
-- the state files go to the temp folder
local TMPDIR = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
local FILE_PREFIX = TMPDIR .. "/sdc_pwtest_" .. tostring(os.time()) .. "_"
HPW.dir = FILE_PREFIX

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
-- host ticks (each drains its queue a little), client ticks, messages delivered
local function ticks(n, dt)
    for _ = 1, n do
        advance(dt or 0.25)
        WORLD = HW; H.world.tick(); deliver()
        WORLD = CW; C.world.tick(); deliver()
        settle()
    end
end
local function outbox_has(w, kind)
    for _, m in ipairs(w.outbox) do if m:find("|" .. kind .. "|", 1, true) or m:find("|" .. kind .. "$") then return true end end
    return false
end
local function st(PWm, w, o)
    WORLD = w
    local k = PWm.kind_of(o)
    return PWm.K[k].state(o)
end

print("== P0. hooks")
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
check(HW.hooks[P.pgen .. ":OnExecuteInteract"] ~= nil and HW.hooks[P.siren .. ":ActivateSiren"] ~= nil
    and HW.hooks[P.save] ~= nil and HW.hooks[P.delete] ~= nil and HW.hooks[P.nuke .. ":MC_Explode"] ~= nil,
    "press, siren, save, slot delete and nuke hooks registered")

print("== P1. the host lists the objects 5 s after the world starts; nothing to send yet")
ticks(4, 0.25)
check(HPW.objs == nil, "not listed in the first seconds")
ticks(30, 0.25)
local n_objs = HPW.objs and #HPW.objs or 0
-- 3 lights, 2 switches, 3 sliding doors, lab generator, circuit box, 2 bunker
-- doors, lever, generator, scanner, secure doors, siren, radio = 18 (not the cable)
check(n_objs == 18, "18 puzzle / power objects tracked (" .. n_objs .. ")")
check(HPW.objs and HPW.objs[1].k == "pgen" and HPW.objs[#HPW.objs].k == "radio", "listed in the chain's order")
check(H.world.stats.pw_sent == 0, "nothing sent while nothing changed")

print("== P2. the client turns the laboratory generator on: the host runs Event_TurnOn, both show it")
local applied0 = C.world.stats.pw_applied
WORLD = CW; CO.lgen:OnExecuteInteract(CW.pawn, OPT1)
check(CO.lgen._p["TurnedOn?"] == true and CO.sw1._p["On?"] == true, "the client's own press ran there")
check(outbox_has(CW, "WPSTEP"), "the press went to the host (WPSTEP)")
deliver()
check(HO.lgen._p["TurnedOn?"] == true, "the host's generator is on")
check(called(HO.lgen, "Event_TurnOn") ~= nil and called(HO.lgen, "Event_TurnOn")[2] == rpawn, "by the game's Event_TurnOn, for that player")
check(HO.sw1._p["On?"] == true and HO.BP_LaboratoryLight2_C_1._p["LightOn?"] == true and HO.sdoor1._p.Unlocked == true,
    "its chain on the host: switch on, lights on, door unlocked")
ticks(2, 0.25)
check(H.world.stats.pw_sent >= 5, "the host sent the changed states (" .. H.world.stats.pw_sent .. ")")
check(C.world.stats.pw_applied == applied0, "the client already matched: nothing applied")

print("== P3. the host switches the light off: the client's switch and lights follow")
WORLD = HW; HO.sw1:OnExecuteInteract(HW.pawn, OPT1)
check(HO.sw1._p["Off?"] == true and HO.BP_LaboratoryLight2_C_1._p["LightOn?"] == false, "off on the host")
ticks(2, 0.25)
check(CO.sw1._p["Off?"] == true and CO.sw1._p["On?"] == false, "the client's switch is off (REPL variable + OnRep)")
check(CO.BP_LaboratoryLight2_C_1._p["LightOn?"] == false and CO.BP_LaboratoryLight2_C_2._p["LightOn?"] == false,
    "the client's lights are off")
check(st(CPW, CW, CO.sw1) == "0", "client switch state 0")

print("== P4. gas can and fuse: what the client's machine cannot consume, the host does from that player's inventory")
INV.client.DA_GasCan = 1
INV.client.DA_Fuse = 1
WORLD = CW; CO.pgen:OnExecuteInteract(CW.pawn, OPT2)
check(not has_note(CW, "No Gas Can In Inventory"), "the client's false 'No Gas Can In Inventory' is gone")
check(outbox_has(CW, "WPTRY"), "asked the host (WPTRY gas)")
deliver()
check(HO.pgen._p["GasAdded?"] == true and INV.client.DA_GasCan == 0, "the host consumed the player's gas can and refueled")
check(has_note(CW, "Generator Refueled"), "the client sees the game's 'Generator Refueled'")
ticks(2, 0.25)
check(CO.pgen._p["GasAdded?"] == true, "the client's generator has gas too")
WORLD = CW; CO.pgen:OnExecuteInteract(CW.pawn, OPT1)
check(not has_note(CW, "Fuse Not Found"), "the client's false 'Fuse Not Found' is gone")
deliver()
check(HO.pgen._p["TurnedOn?"] == true and HO.pgen._p["ItemUsed?"] == true and INV.client.DA_Fuse == 0,
    "the host consumed the fuse and started the generator")
check(HO.lever._p.PoweredOn == true, "its lever has power on the host")
ticks(2, 0.25)
check(CO.pgen._p["TurnedOn?"] == true and CO.lever._p.PoweredOn == true, "the client's generator runs, its lever has power")
check(#consumed == 2, "two items consumed in all (" .. #consumed .. ")")

print("== P5. the client pulls the lever: the host pulls it the game's way, the bunker door opens on both")
WORLD = CW; CO.lever:OnExecuteInteract(CW.pawn, OPT1)
check(tl_fwd(CO.bunker1._p.DoorTimeline), "the client's door opens (its own press)")
deliver()
check(called(HO.lever, "OnExecuteInteract") ~= nil and tl_fwd(HO.lever._p.LeverMovement), "the host's lever pulled by OnExecuteInteract")
check(tl_fwd(HO.bunker1._p.DoorTimeline), "the host's bunker door opens")
finish(HW); finish(CW)
check(HO.bunker1._p["Open?"] == true and CO.bunker1._p["Open?"] == true, "open on both")
local cc = #CO.bunker1._calls
ticks(14, 0.25)
check(#CO.bunker1._calls == cc, "no second toggle on the client")

print("== P6. the host opens the circuit box: its levers unlock a door and switch a light on the client too")
WORLD = HW; HO.cbox:OnExecuteInteract(HW.pawn, OPT1); HO.cbox:OnExecuteInteract(HW.pawn, OPT1)
finish(HW)
check(HO.sdoor2._p.Unlocked == true and HO.sw2._p["On?"] == true and HO.cbox._p["CanInteract?"] == false, "the host's chain ran")
ticks(2, 0.25)
check(st(CPW, CW, CO.cbox) == "2", "the client's box runs its levers")
check(CO.sdoor2._p.Unlocked == true and CO.sw2._p["On?"] == true, "door and switch as on the host")
finish(CW)   -- the client's levers end: its own chain switches sw2 again
check(CO.sw2._p["On?"] == false, "(the client's own chain toggled the switch back)")
ticks(14, 0.25)
check(CO.sw2._p["On?"] == true and CO.BP_LaboratoryLight2_C_3._p["LightOn?"] == true, "the client's look 3 s later set it as on the host")

print("== P7. a locked sliding door and the client's keycard: the host consumes it, the XP is the client's, once")
INV.client.DA_RedKeycard = 1
WORLD = CW; CO.sdoor3:OnExecuteInteract(CW.pawn, OPT1)
check(not has_note(CW, "No Keycard Available"), "the client's false 'No Keycard Available' is gone")
deliver()
check(INV.client.DA_RedKeycard == 0 and HO.sdoor3._p.Unlocked == true and tl_fwd(HO.sdoor3._p.TL_DoorsKeycard),
    "the host consumed the card, unlocked and opened the door")
check(called(HW.lc, "AddXP") == nil, "the host got no XP")
local xp = called(CW.lc, "AddXP")
check(xp ~= nil and xp[2] == 1200, "the client got the door's XP (CurrentLevel 3 x 400)")
check(has_note(CW, "Door Unlocked, XP Given: 1200"), "with the game's note")
ticks(2, 0.25)
check(st(CPW, CW, CO.sdoor3) == "uo1", "the client's door: unlocked, open, XP given")
WORLD = CW; CO.sdoor3:OnExecuteInteract(CW.pawn, OPT1)   -- close it again
deliver()
check(not tl_fwd(HO.sdoor3._p.TL_DoorsKeycard), "closing it closes the host's door")
local nxp = 0
for _, c in ipairs(CW.lc._calls) do if c[1] == "AddXP" then nxp = nxp + 1 end end
check(nxp == 1, "XP once")

print("== P8. secure doors with no card on the client: the host's card check, both open, then both close")
INV.client.DA_BlueKeycard = 1
WORLD = CW; CO.secure:OnExecuteInteract(CW.pawn, OPT1)
deliver()
check(HO.secure._p.IsClosed == false and tl_fwd(HO.secure._p.TL_Mechanism), "the host's secure doors open")
ticks(2, 0.25)
check(st(CPW, CW, CO.secure) == "111", "the client's too")
finish(HW); finish(CW)
WORLD = HW; HO.secure:OnExecuteInteract(HW.pawn, OPT1)   -- the host closes them
ticks(2, 0.25)
check(CO.secure._p.TL_MechanismReverse._playing, "the client's close as the host's (TL_MechanismReverse)")
finish(HW); finish(CW)
check(HO.secure._p.IsClosed == true and CO.secure._p.IsClosed == true, "closed on both")

print("== P9. all-access keycard in the client's widgets: scanner and keycard door open on the host")
INV.client.DA_AllAccess = 1
WORLD = CW; CO.scan:OnExecuteInteract(CW.pawn, OPT1)
check(outbox_has(CW, "WPTRY"), "the client asked the host (allaccess)")
-- (the game's own server path reached the host too: its check cannot see the card)
WORLD = HW; HO.scan:MC_CallInteract(rpawn)
check(HO.scan._p["Unlocked?"] == false, "(the host's own check failed)")
deliver()
check(HO.scan._p["Unlocked?"] == true and tl_fwd(HO.bunker2._p.DoorTimeline), "the host's scanner unlocked, its door opens")
ticks(2, 0.25)
check(st(CPW, CW, CO.scan) == "10" and tl_fwd(CO.bunker2._p.DoorTimeline), "the client's scanner and door as on the host")
check(called(CO.scan._p.Scanner, "SetMaterial") ~= nil, "its light green on the client")
WORLD = CW; CO.kdoor:OnExecuteInteract(CW.pawn, OPT1)
deliver()
check(HO.kdoor._p.Timeline_OpenDoor._playing, "the host's keycard door opens (Timeline_OpenDoor)")
finish(HW)
-- the client's own multicast run failed: its door is still shut; the host's state comes
run_timers(HW); deliver(); run_timers(CW); run_timers(CW)
local ck = CO.kdoor._p.Timeline_OpenDoor
check(called(ck, "PlayFromStart") ~= nil and called(CO.kdoor, "MC_OpenDoor") == nil,
    "the client's copy opened by its timeline, not by MC_OpenDoor(None)")

print("== P10. sirens: the host's random one reaches the client, the client's own random one stops")
WORLD = CW; CO.siren:ActivateSiren()   -- the client's own random timer
run_timers(CW)
check(CO.siren._p.Playing == false, "the client's own random siren stopped")
WORLD = HW; HO.siren:ActivateSiren()   -- the host's random timer
ticks(2, 0.25)
check(CO.siren._p.Playing == true, "the host's siren plays on the client")
WORLD = CW; CO.siren:OnExecuteInteract(CW.pawn, OPT1)   -- flip-flop: on here (no change)
WORLD = CW; CO.siren:OnExecuteInteract(CW.pawn, OPT1)   -- off
run_timers(CW); deliver()
check(HO.siren._p.Playing == false, "the client's press stops the host's siren (its AI noise)")
ticks(2, 0.25)
check(CO.siren._p.Playing == false, "off on the client")

print("== P11. radio")
WORLD = CW; CO.radio:OnExecuteInteract(CW.pawn, OPT1)
deliver()
check(HO.radio._p.Audio._p.VolumeMultiplier == 0.5, "the client's radio plays on the host")

print("== P11b. more of a chain ran on the client than on the host: all states again after its step")
WORLD = CW; CO.sw2:Event_LightSwitch()   -- e.g. its circuit box shot a second time
check(CO.sw2._p["On?"] == false and HO.sw2._p["On?"] == true, "(the client's switch differs, nothing tells the host)")
WORLD = CW; CO.radio:OnExecuteInteract(CW.pawn, OPT1)   -- a step: radio off
deliver()
check(HO.radio._p.Audio._p.VolumeMultiplier == 0, "the step reached the host")
ticks(10, 0.25)
check(CO.sw2._p["On?"] == true and CO.BP_LaboratoryLight2_C_3._p["LightOn?"] == true, "4 s after its step the client got every state again")
check(CO.radio._p.Audio._p.VolumeMultiplier == 0, "and kept its own step")

print("== P12. a joining client gets the host's states (snapshot)")
CO.reset()
local before_apply = C.world.stats.pw_applied
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 30 do WORLD = HW; H.world.tick(); deliver() end
check(C.world.stats.pw_applied > before_apply, "states applied (" .. (C.world.stats.pw_applied - before_apply) .. ")")
check(CO.lgen._p["TurnedOn?"] == true and CO.pgen._p["TurnedOn?"] == true and CO.lever._p.PoweredOn == true,
    "generators on, lever powered")
check(st(CPW, CW, CO.sdoor3) == st(HPW, HW, HO.sdoor3) and st(CPW, CW, CO.scan) == "10", "doors and scanner as on the host")
finish(CW)
ticks(40, 0.25)
local same, diff = 0, {}
for _, e in ipairs(HPW.objs) do
    local ho = HPW.obj(e)
    local co = CW.paths[e.p]
    local a, b = st(HPW, HW, ho), st(CPW, CW, co)
    if a == b then same = same + 1 else diff[#diff + 1] = e.p:match("([^%.]+)$") .. " " .. a .. "/" .. b end
end
check(#diff == 0, "every object as on the host after the looks (" .. same .. " same" .. (#diff > 0 and (", differ: " .. table.concat(diff, ", ")) or "") .. ")")

print("== P13. the host's save keeps them; the next load of the world restores them; a deleted slot loses them")
local function file_text(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("a")
    h:close()
    return s
end
local SAVE_FILE = FILE_PREFIX .. "Slot1_SDCoop_World.txt"
os.remove(SAVE_FILE)
WORLD = HW; fire(HW, P.save, param(HW.pc))
run_timers(HW)
local txt = file_text(SAVE_FILE)
check(txt ~= nil, "written next to the slot: " .. SAVE_FILE)
check(txt and txt:find("~LongdownValley~BP_LaboratoryGenerator_C_1=1", 1, true) ~= nil
    and txt:find("~LongdownValley~BP_PowerGenerator_C_1=111", 1, true) ~= nil, "with the generators")
check(txt and not txt:find("BP_LaboratoryCable", 1, true), "only tracked objects")
-- the world is loaded again: the level's own start states, then the file
HO.reset()
WORLD = HW; H.world.reset("mock: world loaded")
ticks(30, 0.25)
check(H.world.stats.pw_restored > 0, "states restored (" .. H.world.stats.pw_restored .. ")")
check(HO.lgen._p["TurnedOn?"] == true and HO.pgen._p["TurnedOn?"] == true and HO.lever._p.PoweredOn == true,
    "generators and lever as saved")
check(HO.sdoor3._p.Unlocked == true and HO.sdoor3._p["XPGiven?"] == true and HO.scan._p["Unlocked?"] == true,
    "doors and scanner as saved")
local saved_cbox = txt and txt:match("BP_LaboratoryCircuitBox_C_1=(%d)")
check(saved_cbox == "2" and st(HPW, HW, HO.cbox) == "2", "the circuit box done")
WORLD = HW; fire(HW, P.delete, param(nil), param(HW.pc), param("Slot1"), param(0))
check(file_text(SAVE_FILE) == nil, "the deleted slot's file is gone")

print("== P14. the nuke: the client's shot blows up the host's (its damage is the host's); a joiner's copy just goes")
WORLD = CW
fire(CW, P.nuke .. ":Damage_Object", param(CO.nuke), param(40), param(CW.pawn), param(nil))
fire(CW, P.firearm .. ":Trace_Impact", param(cgun))
check(outbox_has(CW, "WDMG"), "the shot went to the host")
deliver()
check(called(HO.nuke, "Damage_Object") ~= nil and called(HO.nuke, "MC_Explode") ~= nil and not HO.nuke._valid,
    "the host's nuke exploded")
for _ = 1, 20 do WORLD = HW; H.world.tick(); deliver() end
check(called(CO.nuke, "MC_Explode") ~= nil and not CO.nuke._valid, "and the client's")
WORLD = CW
local cnuke2 = CO.mknuke("BP_EasterEgg_Nuke_C_1")   -- a joiner's fresh copy
WORLD = HW; H.world._t.snapshot(rpc)
for _ = 1, 30 do WORLD = HW; H.world.tick(); deliver() end
check(not cnuke2._valid and called(cnuke2, "MC_Explode") == nil, "the joiner's copy removed without a blast")

print("== P15. an object not loaded on the client yet gets its state when it appears")
WORLD = HW
local hlate = bp(HW, { "BP_Siren_C", "BP_MasterObject_C" }, "BP_Siren_C_9", { Playing = true }, {})
HPW.objs[#HPW.objs + 1] = { p = LVL .. "BP_Siren_C_9", k = "siren", o = hlate }
HPW.sent[LVL .. "BP_Siren_C_9"] = "0"
HPW.mark_dirty()
ticks(2, 0.25)
local pend = C.world._t.pending()
local has_pw = false
for _, e in ipairs(pend) do if e.kind == "pw" then has_pw = true end end
check(has_pw, "kept for later on the client")
WORLD = CW
local clate = bp(CW, { "BP_Siren_C", "BP_MasterObject_C" }, "BP_Siren_C_9", { Playing = false }, {
    ActivateSiren = function(self) self._p.Playing = true end,
    DeactivateSiren = function(self) self._p.Playing = false end,
})
ticks(10, 0.25)
check(clate._p.Playing == true, "applied when it appeared")

print("== E1. airdrops and jets: the host's timers are logged")
local SPAWN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local MGR = "/Game/Blueprints/Events/BP_EventManager.BP_EventManager_C"
local CRATE_P = "/Game/Inventory/Containers/Containers/Airdrop/Master_AirdropContainer.Master_AirdropContainer_C"
local logged = { host = {}, client = {} }
local function catch(m, who)
    local info0 = m.log.info
    m.log.info = function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        logged[who][#logged[who] + 1] = ok and s or fmt
        return info0(fmt, ...)
    end
end
catch(H, "host"); catch(C, "client")
local function said(who, pat)
    for _, s in ipairs(logged[who]) do if s:find(pat) then return s end end
    return nil
end
local function forget() logged.host, logged.client = {}, {} end
local CV = { ["Difficulty.Airdrop"] = true, ["Difficulty.ChanceOfAirdrop"] = 0.6,
    ["Difficulty.MinimumTimeAirdrop"] = 5, ["Difficulty.MaximumTimeAirdrop"] = 60 }
local TIMERS = { SpawnAirdrop = 1200, SpawnJet = 600, SpawnExplosion = -1, SpawnRandomEvent = 300 }
local ROLL = 0.9
local plane_n, crate_n = 0, 0
for _, w in ipairs({ HW, CW }) do
    WORLD = w
    new(w, { "ConsoleUtils" }, "Default__ConsoleUtils", {}, {
        GetBoolCVar = function(self, n) return CV[n:ToString()] == true end,
        GetFloatCVar = function(self, n) return CV[n:ToString()] end,
        SetBoolCVar = function(self, n, v) CV[n:ToString()] = v end,
        SetFloatCVar = function(self, n, v) CV[n:ToString()] = v end,
    }, "/Script/AutoSettings.Default__ConsoleUtils")
    w.paths["/Script/Engine.Default__KismetSystemLibrary"]._m.K2_GetTimerRemainingTime = function(self, o, fname) return TIMERS[fname] or -1 end
    w.pc._p.DaysSurvived = 6
end
local plane_cls = new(HW, { "BlueprintGeneratedClass" }, "AirdropAircraft_C", {}, {}, "/Game/Blueprints/Events/Airdrop/AirdropAircraft.AirdropAircraft_C")
local crate_cls = new(HW, { "BlueprintGeneratedClass" }, "AirdropContainer_Supplies_C", {}, {},
    "/Game/Inventory/Containers/Containers/Airdrop/AirdropContainer_Supplies.AirdropContainer_Supplies_C")
WORLD = HW
local mgr
mgr = new(HW, { "BP_EventManager_C" }, "BP_EventManager_C_1", { AirdropTimeToSpawn = 1200.0, JetTimeToSpawn = 600.0,
    MaxNumberOfJetsToSpawn = 2, BloodMoonChance = 5.0 }, {
    GetDaysSurvived = function(self, out) out.DaysSurvived = HW.pc._p.DaysSurvived end,
    AirdropSpawn = function(self) fire(HW, MGR .. ":AirdropSpawn", param(self)) end,
    Jet_Spawn = function(self) fire(HW, MGR .. ":Jet_Spawn", param(self)) end,
    -- @3162-5253: Difficulty.Airdrop, the weighted roll, the days, the plane, the next timer
    SpawnAirdrop = function(self)
        WORLD = HW
        if CV["Difficulty.Airdrop"] and ROLL < CV["Difficulty.ChanceOfAirdrop"] then
            if HW.pc._p.DaysSurvived > 5 then
                fire(HW, SPAWN, param(nil), param(self), param(plane_cls), param({}))
                plane_n = plane_n + 1
                local plane = new(HW, { "AirdropAircraft_C", "BP_MasterObject_C" }, "AirdropAircraft_C_" .. (2147300000 + plane_n),
                    { bReplicates = true, bAlwaysRelevant = true, _loc = { X = 1000, Y = 2000, Z = 50000 } })
                -- its crate (@450) and the crate's landing
                fire(HW, SPAWN, param(nil), param(plane), param(crate_cls), param({}))
                crate_n = crate_n + 1
                HW.last_crate = new(HW, { "AirdropContainer_Supplies_C", "Master_AirdropContainer_C" },
                    "AirdropContainer_Supplies_C_" .. (2147310000 + crate_n), { bReplicates = true, _loc = { X = 1000, Y = 2000, Z = 120 } })
            end
            self:AirdropSpawn()
        end
        fire(HW, MGR .. ":SpawnAirdrop", param(self))
    end,
})
WORLD = HW; H.world._t.try_hooks(true)
WORLD = CW; C.world._t.try_hooks(true)
forget()
WORLD = HW; mgr:AirdropSpawn(); run_timers(HW)
check(said("host", "^airdrop: next roll in 20%.0 min %(Difficulty%.Airdrop=true, chance 60%%, 5%-60 min") ~= nil,
    "timer logged: " .. tostring(said("host", "^airdrop: next roll")))
WORLD = HW; mgr:Jet_Spawn()
check(said("host", "^jets: next fly%-by in 10%.0 min") ~= nil, "jet timer logged")

print("== E2. the rolls: failed (no new timer), too early, success with plane and crate")
advance(2); forget(); ROLL = 0.9
WORLD = HW; mgr:SpawnAirdrop()
check(said("host", "^airdrop: roll FAILED %(chance 60%%%), days survived 6: no plane, and the game sets no new timer") ~= nil,
    "failed roll: " .. tostring(said("host", "^airdrop: roll")))
forget(); ROLL = 0.1; HW.pc._p.DaysSurvived = 4
WORLD = HW; mgr:SpawnAirdrop()
check(said("host", "but days survived 4 <= 5: no plane; next timer set") ~= nil, "days <= 5: " .. tostring(said("host", "^airdrop: roll")))
forget(); HW.pc._p.DaysSurvived = 7
WORLD = HW; mgr:SpawnAirdrop(); run_timers(HW)
check(said("host", "^airdrop: roll ok %(chance 60%%%), days survived 7: plane spawned, next timer set") ~= nil,
    "success: " .. tostring(said("host", "^airdrop: roll")))
check(said("host", "^airdrop: plane spawned AirdropAircraft_C_2147300001 at 1000,2000,50000: replicates to 1 client%(s%) %(bReplicates=true, always relevant=true%)") ~= nil,
    "plane logged: " .. tostring(said("host", "^airdrop: plane")))
check(said("host", "^airdrop: crate dropped AirdropContainer_Supplies_C_2147310001") ~= nil, "crate drop logged")
WORLD = HW; fire(HW, CRATE_P .. ":ReceiveHit", param(HW.last_crate)); fire(HW, CRATE_P .. ":ReceiveHit", param(HW.last_crate))
local nland = 0
for _, s in ipairs(logged.host) do if s:find("^airdrop: crate .* landed") then nland = nland + 1 end end
check(nland == 1, "the landing logged once (" .. nland .. ")")
check(H.world.stats.ad_rolls == 3 and H.world.stats.ad_planes == 1 and H.world.stats.ad_crates == 1, "counted: 3 rolls, 1 plane, 1 crate")

print("== E3. the client sees the host's plane and crate arrive")
WORLD = CW
new(CW, { "AirdropAircraft_C", "BP_MasterObject_C" }, "AirdropAircraft_C_2147300001", { Role = 1, _loc = { X = 1000, Y = 2000, Z = 50000 } })
new(CW, { "AirdropContainer_Supplies_C", "Master_AirdropContainer_C" }, "AirdropContainer_Supplies_C_2147310001", { Role = 1, _loc = { X = 1000, Y = 2000, Z = 120 } })
for _ = 1, 12 do advance(1); WORLD = CW; C.world.tick() end
check(said("client", "^airdrop: the host's plane AirdropAircraft_C_2147300001 is here") ~= nil
    and said("client", "^airdrop: the host's crate AirdropContainer_Supplies_C_2147310001 is here") ~= nil, "client logs both (replicated)")

print("== E4. sdcoop_events and sdcoop_airdrop")
local cmds = {}
local function add(name, help, fn) cmds[name] = fn end
H.world.register_commands(add)
check(cmds.sdcoop_events ~= nil and cmds.sdcoop_airdrop ~= nil, "both commands registered through add()")
local out = {}
local function reply(s) out[#out + 1] = s end
WORLD = HW; cmds.sdcoop_events({}, reply)
local all = table.concat(out, "\n")
check(all:find("airdrop: next roll in 20.0 min", 1, true) ~= nil and all:find("jets: next fly-by in 10.0 min", 1, true) ~= nil
    and all:find("explosion sounds: no timer", 1, true) ~= nil, "timers printed")
TIMERS.SpawnAirdrop = -1
out = {}
WORLD = HW; cmds.sdcoop_events({}, reply)
check(table.concat(out, "\n"):find("no timer (the cycle has stopped", 1, true) ~= nil, "a stopped airdrop cycle is said")
-- force: a roll that would fail, too few days: the plane comes; the settings come back
forget(); ROLL = 0.9; HW.pc._p.DaysSurvived = 3; out = {}
WORLD = HW; cmds.sdcoop_airdrop({ "force" }, reply)
check(plane_n == 2 and said("host", "^airdrop: roll ok") ~= nil, "sdcoop_airdrop force: the game's roll spawned a plane")
check(CV["Difficulty.ChanceOfAirdrop"] == 0.6 and HW.pc._p.DaysSurvived == 3, "chance and days survived put back")
check(out[1] and out[1]:find("SpawnAirdrop ran: roll ok", 1, true) ~= nil, "reply: " .. tostring(out[1]))
out = {}
WORLD = HW; cmds.sdcoop_airdrop({}, reply)
check(plane_n == 2 and out[1]:find("roll FAILED", 1, true) ~= nil, "without force: the game's own roll (failed here)")
local ccmds = {}
C.world.register_commands(function(name, help, fn) ccmds[name] = fn end)
out = {}
WORLD = CW; ccmds.sdcoop_airdrop({}, reply)
check(out[1]:find("host only", 1, true) ~= nil, "client: host only")

print("== P16. status")
WORLD = HW; print(H.world.status_line())
WORLD = CW; print(C.world.status_line())
check(H.world.status_line():find("puzzle objs=", 1, true) ~= nil, "status line has the puzzle part")

os.remove(SAVE_FILE)
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
