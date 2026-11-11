-- Mock harness for sdc_persist (+ sdc_progress / sdc_skilltree / patched sdc_players).
-- usage: lua mock_persist.lua <scripts dir> <patched dir> <temp dir>
local SCRIPTS, PATCHED, TMP = arg[1], arg[2], arg[3]
package.path = PATCHED .. "/?.lua;" .. SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ time, env
local NOW = 1000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end
local CLK = 100.0
os.clock = function() return CLK end
local function advance(s) NOW = NOW + s; CLK = CLK + s end
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return TMP end return real_getenv(k) end
local SAVEDIR = TMP .. "/SurrounDead/Saved/SaveGames/"
os.execute('mkdir "' .. (TMP .. "/SurrounDead/Saved/SaveGames"):gsub("/", "\\") .. '" >nul 2>&1')
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local d = f:read("a"); f:close(); return d end
local function spit(p, d) local f = assert(io.open(p, "wb")); f:write(d); f:close() end

-- ------------------------------------------------------------ fake arrays / objects
local FArr = {}
FArr.__index = FArr
local function arr(items) return setmetatable({ _i = items or {} }, FArr) end
function FArr:ForEach(fn)
    for i, v in ipairs(self._i) do
        local cell = { get = function() return self._i[i] end }
        fn(i, cell)
    end
end
function FArr:GetArrayNum() return #self._i end
local function is_arr(v) return getmetatable(v) == FArr end

local function deep(v)
    if is_arr(v) then
        local out = {}
        for i, x in ipairs(v._i) do out[i] = deep(x) end
        return arr(out)
    end
    if type(v) == "table" and getmetatable(v) == nil then
        local out = {}
        for k, x in pairs(v) do out[k] = deep(x) end
        return out
    end
    return v   -- objects (data assets, actors) by reference
end

local Obj = {}
local next_addr = 4096
local registry, by_path = {}, {}
local function new_obj(cls, short, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr,
        _valid = true, _path = path }, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    if path then by_path[path] = o end
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return rawget(t, "_p")[k]
end
Obj.__newindex = function(t, k, v) rawget(t, "_p")[k] = v end
function Obj:IsValid() return self._valid end
function Obj:GetFullName()
    if self._path then return self._cls .. " " .. self._path end
    return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short
end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
local ARRAY_PROPS = { JigContainers = true, MainUIDs = true, Weights = true, ActionbarUIDs = true,
    MainJigContainers = true, MainContainersIDs = true, InventoryWeight = true }
function Obj:SetPropertyValue(n, v)
    if ARRAY_PROPS[n] then
        if is_arr(v) then v = deep(v)
        elseif type(v) == "table" then local items = {}; for i, x in ipairs(v) do items[i] = deep(x) end; v = arr(items) end
    elseif type(v) == "table" and getmetatable(v) == nil then
        v = deep(v)
    end
    self._p[n] = v
end
function Obj:GetAddress() return self._addr end
function Obj:K2_DestroyActor() self._valid = false end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = self._p.__yaw or 0, Roll = 0 } end
function Obj:K2_SetActorLocation(loc) self._p.__loc = { X = loc.X, Y = loc.Y, Z = loc.Z }; return true end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, pre, post)
    hooks[path] = hooks[path] or {}
    table.insert(hooks[path], { pre = pre, post = post })
    return 1, 2
end
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
function LoadAsset(p) return by_path[p] end
local function run_delayed() for _ = 1, 5 do local d = delayed; delayed = {}; for _, f in ipairs(d) do f() end end end

setmetatable(by_path, { __index = function(t, k)
    if type(k) == "string" and k:find(":") and not k:find("^/Script/EasyMultiSave%.Default") then
        local f = new_obj("Function", k)
        rawset(t, k, f)
        return f
    end
    return nil
end })

-- engine singletons
local current_slot = "SlotA"
local cvars = { ["Difficulty.KeepInventory"] = false }
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return false end,
    IsServer = function() return true end,
    GetConsoleVariableBoolValue = function(_, n) return cvars[n] == true end,
}, "/Script/Engine.Default__KismetSystemLibrary")
local ems = new_obj("EMSFunctionLibrary", "Default__EMSFunctionLibrary", {}, {
    GetSlotInfoSaveGame = function(_, wc, out) out.SaveGameName = current_slot end,
    DeleteAllSaveDataForSlot = function() end,
}, "/Script/EasyMultiSave.Default__EMSFunctionLibrary")
local push = new_obj("NetPushModelHelpers", "Default__NetPushModelHelpers", {}, {
    MarkPropertyDirtyFromRepIndex = function() end }, "/Script/Engine.Default__NetPushModelHelpers")
local jig_cls = new_obj("BlueprintGeneratedClass", "BP_JigMPComponentSave_C", {}, {},
    "/Game/JigSInventory/Jigsaw/Components/Save/BP_JigMPComponentSave.BP_JigMPComponentSave_C")
local player_cls = new_obj("BlueprintGeneratedClass", "BP_PlayerCharacter_C", {}, {},
    "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C")

-- Jig struct members
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_PICKUP = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657"

local DA = {}
for _, n in ipairs({ "DA_Knife", "DA_Bandage", "DA_Rifle", "DA_Backpack", "DA_Ammo" }) do
    DA[n] = new_obj("JigsawItem_DataAsset_C", n, {}, {}, "/Game/Inventory/Data/" .. n .. "." .. n)
end
local uidn = 100
local function guid() uidn = uidn + 1; return { A = uidn, B = 2, C = 3, D = 4 } end
local function item(da, n, slot, pickup)
    return { [F_USID] = guid(), [F_INFO] = { [F_COUNT] = n, [F_ITEMID] = DA[da], [F_DUR] = { X = 90.5, Y = 100 } },
             [F_SLOT] = slot or 0, [F_PICKUP] = pickup }
end
local function container(items) return { [F_CONT_UID] = guid(), [F_ITEMS] = arr(items or {}) } end

-- save files: our own text format for the fake engine save system
local json_enc, json_dec   -- set once sdc_persist is loaded
local function ser(v)
    if is_arr(v) then local out = { __arr = {} }; for i, x in ipairs(v._i) do out.__arr[i] = ser(x) end; return out end
    if type(v) == "table" and getmetatable(v) == Obj then return { __obj = v._path or v._short } end
    if type(v) == "table" then local out = {}; for k, x in pairs(v) do out[k] = ser(x) end; return out end
    return v
end
local function unser(v)
    if type(v) == "table" and v.__arr then local items = {}; for i, x in ipairs(v.__arr) do items[i] = unser(x) end; return arr(items) end
    if type(v) == "table" and v.__obj then return by_path[v.__obj] end
    if type(v) == "table" then local out = {}; for k, x in pairs(v) do out[k] = unser(x) end; return out end
    return v
end
local function new_save_obj()
    return new_obj("BP_JigMPComponentSave_C", "SaveObj", { JigContainers = arr(), MainUIDs = arr(), Weights = arr(),
        ActionbarUIDs = arr() }, {})
end
local saves_written = 0
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {
    CreateSaveGameObject = function(_, cls) return cls == jig_cls and new_save_obj() or nil end,
    SaveGameToSlot = function(_, obj, name)
        local t = {}
        for _, k in ipairs({ "JigContainers", "MainUIDs", "Weights", "ActionbarUIDs", "PlayerLocation", "MapName" }) do
            t[k] = ser(obj._p[k])
        end
        spit(SAVEDIR .. name .. ".sav", "FAKESAVE" .. json_enc(t))
        saves_written = saves_written + 1
        return true
    end,
    DoesSaveGameExist = function(_, name) return exists(SAVEDIR .. name .. ".sav") end,
    LoadGameFromSlot = function(_, name)
        local d = slurp(SAVEDIR .. name .. ".sav")
        if not d or d:sub(1, 8) ~= "FAKESAVE" then return nil end
        local t = json_dec(d:sub(9))
        if type(t) ~= "table" then return nil end
        local o = new_save_obj()
        for k, v in pairs(t) do o._p[k] = unser(v) end
        return o
    end,
}, "/Script/Engine.Default__GameplayStatics")

-- ------------------------------------------------------------ characters
local calls = {}
local function call_rec(name) return function(...) calls[#calls + 1] = name end end
local function new_jig(conts)
    local jig = new_obj("BP_JigComponent_C", "BP_JigMultiplayer", {
        MainJigContainers = arr(conts or {}), MainContainersIDs = arr({ guid(), guid() }), InventoryWeight = arr({ {}, {} }) }, {})
    jig._m.SERVER_LoadSaveDataFromClientSide = function(self, c, u, w, hot)
        calls[#calls + 1] = "SERVER_LoadSaveDataFromClientSide"
        self._p.MainJigContainers, self._p.MainContainersIDs, self._p.InventoryWeight = deep(c), deep(u), deep(w)
        self._p.__last_hot = deep(hot)
    end
    jig._m.AddNewItemSomewhere = function(self, da, n, _, _, _, _, added)
        calls[#calls + 1] = "AddNewItemSomewhere " .. da._short .. " x" .. n
        local c = self._p.MainJigContainers._i[1]
        table.insert(c[F_ITEMS]._i, item(da._short, n))
        added.Added = true
    end
    return jig
end
local function new_pawn(name, loc, kit)
    local conts = { container(kit and { item("DA_Knife", 1, 0) } or {}), container({}) }
    local med = new_obj("MedicalComponent_C", "Med", { Health = 100, MaxHealth = 100, ["Bleed?"] = false,
        ["HeavyBleed?"] = false, ["BrokenBone?"] = false, ["Infection?"] = false, InfectionTimeLeft = 0 },
        { ComponentLoaded = call_rec("Medical.ComponentLoaded") })
    local ht = new_obj("HungerThirstComponent_C", "HT", { CurrentHunger = 100, CurrentThirst = 100 }, {})
    local stam = new_obj("StaminaComponent_C", "Stam", { CurrentStamina = 100 }, {})
    local rad = new_obj("RadiationComponent_C", "Rad", { CurrentRadiation = 0 }, {})
    local p = new_obj("BP_PlayerCharacter_C", name, {
        __loc = loc, ["PlayerDead?"] = false, MedicalComponent = med, ["Hunger&ThirstComponent"] = ht,
        StaminaComponent = stam, RadiationComponent = rad, BP_JigMultiplayer = new_jig(conts),
        ["DeathbringerSkillUsed?"] = false, ["InVehicle?"] = false,
    }, {})
    for _, f in ipairs({ "Client_UpdateHealthUI", "Client_UpdateHungerUI", "Client_UpdateThirstUI",
        "Client_UpdateStaminaUI", "Client_UpdateRadiationUI" }) do p._m[f] = call_rec(f) end
    return p
end
local function comp(cls, props, extra)
    local m = setmetatable(extra or {}, { __index = function(_, k) return function() calls[#calls + 1] = cls .. "." .. k end end })
    return new_obj(cls, cls, props, m)
end
local function new_pc(name, remote)
    local lev = comp("LevellingComponent_C", { CurrentLevel = 1, CurrentXP = 0, CurrentMaxXP = 500, CurrentPercentage = 0,
        BufferXP = 0, RemainingXP = 0 })
    lev._m.Reset = function(self) self._p.CurrentLevel = 1; self._p.CurrentXP = 0; self._p.CurrentMaxXP = 500 end
    local ps = comp("PassiveSkillsComponent_C", { CurrentFitnessXP = 0, CurrentFitnessLevel = 1, StrengthMultiplier = 1,
        ["FitnessMultiplierUsed?"] = false })
    local unlocked = {}
    local tech = comp("TechTreeComponent_C", { SkillPoints = 0, CurrentPoints = 0 }, {
        IsTechnologyUnlocked = function(_, o) return unlocked[o._short] == true end,
        UnlockTechnology = function(_, o) unlocked[o._short] = true end,
        LockTechnology = function(_, o) unlocked[o._short] = nil end,
    })
    local pc = new_obj("BP_PlayerController_C", name, {
        LevellingComponent = lev, PassiveSkillsComponent = ps, TechTreeComponent = tech, ZombieKills = 0, DaysSurvived = 1,
        RespawnPointEnabled = false, RespawnLoc = { Translation = { X = 0, Y = 0, Z = 0 }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 } },
        KeepInventory = {},
    }, {})
    pc._m.GetControlRotation = function() return { Yaw = 33 } end
    pc._m.BindPlayerRespawn = call_rec("BindPlayerRespawn")
    pc._m.Possess = function(self, pawn) self._p.Pawn = pawn; pawn._p.Controller = self end
    pc._m.IsLocalController = function() return not remote end
    pc._unlocked = unlocked
    if remote then pc._p.NetConnection = new_obj("IpConnection", "Conn_" .. name, {}, {}) else
        pc._p.Player = new_obj("LocalPlayer", "LP_" .. name, {}, {}) end
    return pc
end
for _, n in ipairs({ "Skill_Parkour", "Skill_HealthRegen" }) do
    new_obj("BP_SkillTreeAsset_C", n, {}, {}, "/Game/Blueprints/SkillTree/Skills/" .. n .. "." .. n)
end

-- spawning (BeginDeferred / Finish)
gps._m.BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf)
    local t = tf.Translation
    local p = new_pawn("Spawned" .. next_addr, { X = t.X, Y = t.Y, Z = t.Z })
    p._p["SpawnStartingItems?"] = nil
    return p
end
gps._m.FinishSpawningActor = function(_, actor)
    if actor._p["SpawnStartingItems?"] == true then
        table.insert(actor._p.BP_JigMultiplayer._p.MainJigContainers._i[1][F_ITEMS]._i, item("DA_Knife", 1, 0))
    end
    return actor
end

-- ------------------------------------------------------------ module stubs
package.preload["sdc_ctx"] = function()
    return { addr = function(o) return o and o._addr end, bind = function() end, SCOPE_API = 1, scope_resolver = nil,
             reset = function() end }
end
package.preload["sdc_widgets"] = function() return {} end
local steam_id = nil
package.preload["sdc_steam"] = function() return { own_id = function() return steam_id end } end
require("sdc_steam")   -- sdc_session loads it in the mod

local cfg = require("sdc_config")
cfg.load(TMP .. "/config.ini")
-- this harness checks the live records across reloads (the behaviour with
-- persist_follow_host_save off); tests/mock_persist_commit.lua checks it on
cfg.set("persist_follow_host_save", false)
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text) toasts[#toasts + 1] = text end
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... } }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
local function last(kind)
    for i = #sent, 1, -1 do if sent[i].kind == kind then return sent[i] end end
    return nil
end
local function deliver(kind, fields, pc) net.handlers[kind](fields, pc) end

local ue = require("sdc_ue")
local loops = {}
ue.every = function(label, ms, fn) loops[label] = fn end

local session = { state = nil, world_reset_hooks = {}, VERSION = "test" }
package.loaded["sdc_session"] = session
local S = { role = "host", remote = {}, remote_pcs = {}, spawned = {}, in_menu = false, menu_since = 0 }
session.state = S
local players = require("sdc_players")
players.init(S, { remote_record = function(pc) return S.remote[pc:GetFullName()] end })
local progress = require("sdc_progress")
progress.install(S)
run_delayed()
local persist = require("sdc_persist")
json_enc, json_dec = persist.json_encode, persist.json_decode
check(loops.persist ~= nil and loops.progress ~= nil, "persist and progress ticks scheduled")
check(net.handlers.PSID and net.handlers.PSSET and net.handlers.PSPROG, "handlers registered")

-- host world
local host_pc = new_pc("HostPC", false)
local host_pawn = new_pawn("HostChar", { X = 5000, Y = 5000, Z = 200 })
host_pc._p.Pawn = host_pawn
registry["PlayerController"] = { host_pc }
ue.forget_world()

local function host_tick()
    for _, r in pairs(S.remote) do players.host_player_tick(r, NOW) end
    loops.persist()
    loops.progress()
    run_delayed()
end

local function connect(name)
    local pc = new_pc(name, true)
    table.insert(registry["PlayerController"], pc)
    local r = { key = pc:GetFullName(), pc = pc, index = 1, name = name, joined_at = NOW, pawnless_since = NOW,
                spawned_once = false, spawn_pending = false, dead = false }
    S.remote[r.key] = r
    return r
end
local function leave(r)
    S.remote[r.key] = nil
    local p = r.pc._p.Pawn
    if p then p._valid = false end
    r.pc._valid = false
end

-- ======================================================================
print("1. a new player: fresh character, recorded while playing")
host_tick()
check(persist._hs.world_slot == "SlotA", "world slot read from EMS: " .. tostring(persist._hs.world_slot))
local bob = connect("Bob")
host_tick()
check(bob.pc._p.Pawn == nil, "first character waits for the id (gate)")
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob.pc)
local fr = last("PSFRESH")
check(fr and fr.to == bob.pc, "PSFRESH sent (no record)")
local gen = fr.args[1]
advance(3)
host_tick()
local bpawn = bob.pc._p.Pawn
check(bpawn ~= nil, "character spawned after the id")
check(#bpawn._p.BP_JigMultiplayer._p.MainJigContainers._i[1][F_ITEMS]._i == 1, "fresh character has the starting kit")
-- client reports progression
local vals = "L.CurrentLevel=4;L.CurrentXP=321.5;L.CurrentMaxXP=900;P.CurrentFitnessLevel=3;P.StrengthMultiplier=1.25;P.FitnessMultiplierUsed?=1;T.SkillPoints=2;T.CurrentPoints=5;J.ZombieKills=17;J.DaysSurvived=3"
deliver("PSPROG", { gen, vals, "Skill_Parkour", "101:2:3:4,0:0:0:0,0:0:0:0" }, bob.pc)
deliver("PSPROG", { "wronggen", "L.CurrentLevel=1", "-", "?" }, bob.pc)
advance(16)   -- a level / skill change is written within PROG_WRITE_S
host_tick()
local files = persist.savegames_dir()
check(exists(SAVEDIR .. "SlotA_SDCoop.json"), "SlotA_SDCoop.json written")
check(exists(SAVEDIR .. "SlotA_SDCoop_s76561190000000001.sav"), "inventory file written")
local doc = json_dec(slurp(SAVEDIR .. "SlotA_SDCoop.json"))
local rec = doc and doc.players and doc.players.s76561190000000001
check(rec ~= nil, "record of Bob in the slot file")
check(rec and rec.prog and rec.prog.L.CurrentLevel == 4 and rec.prog.P["FitnessMultiplierUsed?"] == true, "progression from the client's report (gen-checked)")
check(rec and rec.inv and rec.inv.items == 1 and rec.inv.containers == 2, "inventory summary 2 containers / 1 item")
check(rec and rec.tree and rec.tree[1] == "Skill_Parkour", "skill list saved")

print("2. inventory change, PickupRef cleared in the file, durability kept")
local pick = new_obj("BP_FirearmPickup_C", "Rifle_1", {}, {})
table.insert(bpawn._p.BP_JigMultiplayer._p.MainJigContainers._i[2][F_ITEMS]._i, item("DA_Rifle", 1, 3, pick))
table.insert(bpawn._p.BP_JigMultiplayer._p.MainJigContainers._i[2][F_ITEMS]._i, item("DA_Ammo", 30, 4))
bpawn._p.__loc = { X = 12345, Y = -6789, Z = 456 }
bpawn._p.MedicalComponent._p.Health = 55
bpawn._p.MedicalComponent._p["Bleed?"] = true
bpawn._p["Hunger&ThirstComponent"]._p.CurrentHunger = 40
advance(11)
host_tick()
doc = json_dec(slurp(SAVEDIR .. "SlotA_SDCoop.json"))
rec = doc.players.s76561190000000001
check(rec.inv.items == 3, "inventory change written (3 items)")
local blob = json_dec(slurp(SAVEDIR .. "SlotA_SDCoop_s76561190000000001.sav"):sub(9))
local saved_pick, saved_dur = "missing", nil
for _, c in ipairs(blob.JigContainers.__arr) do
    for _, it in ipairs(c[F_ITEMS].__arr) do
        if it[F_INFO][F_ITEMID].__obj:find("DA_Rifle") then saved_pick = it[F_PICKUP]; saved_dur = it[F_INFO][F_DUR].X end
    end
end
check(saved_pick == nil, "PickupRef cleared in the saved copy")
check(saved_dur == 90.5, "durability in the saved copy")
check(bpawn._p.BP_JigMultiplayer._p.MainJigContainers._i[2][F_ITEMS]._i[1][F_PICKUP] == pick, "live item keeps its PickupRef")
check(exists(SAVEDIR .. "SlotA_SDCoop_s76561190000000001_bak.sav"), "previous inventory kept as _bak")
check(exists(SAVEDIR .. "SlotA_SDCoop.json.bak"), "previous record file kept as .bak")
check(rec.pos and rec.pos.x == 12345 and rec.pos.yaw == 33, "position + control yaw")
check(rec.vitals and rec.vitals.Health == 55 and rec.vitals["Bleed?"] == true and rec.vitals.CurrentHunger == 40, "health, bleeding, hunger")

print("3. the game saves to a new slot: records go along")
current_slot = "QuickSave1"
local saveh = hooks["/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot"]
check(saveh and #saveh == 1, "SaveGameToSlot hook registered")
saveh[1].pre(param(host_pc))
run_delayed()
check(persist._hs.world_slot == "QuickSave1", "world slot follows the save")
check(exists(SAVEDIR .. "QuickSave1_SDCoop.json") and exists(SAVEDIR .. "QuickSave1_SDCoop_s76561190000000001.sav"), "records + inventory in the new slot")
check(persist.stats.host_saves == 1, "host save counted")
-- the same save seen by EMS's AsyncSaveActors too: still one write
local emsh = hooks["/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"]
check(emsh and emsh[1] and emsh[1].post, "AsyncSaveActors hook registered")
saveh[1].pre(param(host_pc)); emsh[1].post(param(nil), param(nil), param(host_pc), param(3))
run_delayed()
check(persist.stats.host_saves == 2, "both hooks of one save: one write")
-- a save that EMS reports into the throwaway slot keeps the world's slot
current_slot = "SDCoop_ClientTemp"
emsh[1].post(param(nil), param(nil), param(host_pc), param(3))
run_delayed()
check(persist._hs.world_slot == "QuickSave1" and not exists(SAVEDIR .. "SDCoop_ClientTemp_SDCoop.json"), "throwaway slot never gets records")
current_slot = "QuickSave1"

print("4. periodic write")
local before = persist.stats.periodic
advance(125)
host_tick()
check(persist.stats.periodic == before + 1, "periodic flush")

print("5. Bob leaves: the record is final, the character is not touched")
bpawn._p.MedicalComponent._p.Health = 1   -- changes after the last gathering are not seen
leave(bob)
advance(1)
host_tick()
doc = json_dec(slurp(SAVEDIR .. "QuickSave1_SDCoop.json"))
rec = doc.players.s76561190000000001
check(rec.why == "left" and rec.alive == true, "record written on leaving")
check(rec.vitals.Health == 55, "last gathered health (5 s granularity)")
check(rec.inv.items == 3 and rec.inv.slot == "QuickSave1", "inventory reference in the new slot")

print("6. the host loads QuickSave1 again; Bob comes back: everything is restored")
persist.reset("loadmap")
progress_state_reset = session.world_reset_hooks.progress
if progress_state_reset then progress_state_reset("loadmap") end
S.remote = {}
host_tick()
check(persist._hs.world_slot == "QuickSave1", "world slot of the loaded world")
local bob2 = connect("Bob2")
sent = {}
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob2.pc)
local set = last("PSSET")
check(set ~= nil and set.to == bob2.pc, "PSSET sent")
check(set and set.args[2]:find("L.CurrentLevel=4", 1, true) and set.args[3] == "Skill_Parkour", "PSSET carries level and skills")
check(set and set.args[5]:find("inv", 1, true) and not set.args[5]:find("clear", 1, true), "inventory flag, no UI clear (hooks in)")
local gen2 = set.args[1]
advance(3)
host_tick()
local b2pawn = bob2.pc._p.Pawn
check(b2pawn ~= nil, "character spawned")
local l = b2pawn._p.__loc
check(l and l.X == 12345 and l.Y == -6789 and math.abs(l.Z - 486) < 1, "spawned at the saved spot")
check(#b2pawn._p.BP_JigMultiplayer._p.MainJigContainers._i[1][F_ITEMS]._i == 0, "no starting kit")
check(bob2.pc._p.LevellingComponent._p.CurrentLevel == 4 and bob2.pc._p.ZombieKills == 17, "host copy of the controller restored")
check(calls[#calls] ~= "SERVER_LoadSaveDataFromClientSide", "inventory waits for the client")
deliver("PSRDY", { gen2 }, bob2.pc)
advance(1)
host_tick()
local inv = b2pawn._p.BP_JigMultiplayer._p.MainJigContainers
local n = 0
for _, c in ipairs(inv._i) do n = n + #c[F_ITEMS]._i end
check(n == 3, "inventory restored through SERVER_LoadSaveDataFromClientSide (3 items)")
check(b2pawn._p.BP_JigMultiplayer._p.__last_hot and #b2pawn._p.BP_JigMultiplayer._p.__last_hot._i == 3, "action bar UIDs passed")
check(b2pawn._p.MedicalComponent._p.Health == 55 and b2pawn._p.MedicalComponent._p["Bleed?"] == true, "health and bleeding restored")
check(b2pawn._p["Hunger&ThirstComponent"]._p.CurrentHunger == 40, "hunger restored")
local cl = table.concat(calls, ",")
check(cl:find("Medical.ComponentLoaded", 1, true) and cl:find("Client_UpdateHealthUI", 1, true), "game's load events / UI RPCs called")
check(last("PSDONE") ~= nil, "PSDONE sent")
check(persist.stats.inv_restored == 1, "inventory restore counted")

print("7. client side: the record is applied by the client")
-- a separate client machine view
S.role = "client"; S.client = {}
local cpc = new_pc("ClientPC", false)
registry["PlayerController"] = { cpc }
ue.forget_world()
local hud = new_obj("BP_Ingame_C", "HUD", {}, {})
local cpawn = new_pawn("ClientChar", { X = 0, Y = 0, Z = 0 })
cpawn._p.InGameUI = hud
cpc._p.Pawn = cpawn
steam_id = "76561190000000001"
sent = {}
loops.persist(); loops.progress()
local pid = last("PSID")
check(pid and pid.args[1] == "76561190000000001" and pid.args[2]:match("^%x+$"), "client sends its SteamID and own id")
deliver("PSSET", set.args)
advance(7)
loops.progress(); loops.persist(); run_delayed()
check(cpc._p.LevellingComponent._p.CurrentLevel == 4 and cpc._p.LevellingComponent._p.CurrentXP == 321.5, "client copy: level / XP")
check(cpc._p.PassiveSkillsComponent._p.StrengthMultiplier == 1.25 and cpc._p.PassiveSkillsComponent._p["FitnessMultiplierUsed?"] == true, "client copy: passive skills")
check(cpc._p.TechTreeComponent._p.SkillPoints == 2 and cpc._unlocked.Skill_Parkour == true, "client copy: points and unlocked skill")
check(cpc._p.ZombieKills == 17 and cpc._p.DaysSurvived == 3, "client copy: journal")
check(last("PSRDY") ~= nil, "client asks the host for the inventory (PSRDY)")
advance(4)
loops.persist()
local prog = last("PSPROG")
check(prog and prog.args[1] == set.args[1] and prog.args[2]:find("L.CurrentLevel=4", 1, true), "client reports progression with the record's gen")
check(prog and prog.args[3] == "Skill_Parkour", "client reports its skills")
S.role = "host"; S.client = nil
registry["PlayerController"] = { host_pc, bob2.pc }
ue.forget_world()

print("8. another player without a record: fresh")
local eve = connect("Eve")
sent = {}
deliver("PSID", { "-", "aabbccddeeff00112233", "Eve" }, eve.pc)
check(last("PSFRESH") ~= nil, "PSFRESH for Eve (guid key)")
advance(3)
host_tick()
check(eve.pc._p.Pawn and #eve.pc._p.Pawn._p.BP_JigMultiplayer._p.MainJigContainers._i[1][F_ITEMS]._i == 1, "Eve gets the starting kit")

print("9. damaged files: previous copies are used")
-- leave both, then break the newest files
leave(bob2); leave(eve)
advance(1)
host_tick()
local good_json = slurp(SAVEDIR .. "QuickSave1_SDCoop.json")
-- 9a: the record file is damaged -> .bak
spit(SAVEDIR .. "QuickSave1_SDCoop.json", "{ this is not json")
local fb0 = persist.stats.load_fallbacks
persist.reset("test")
host_tick()
local bob3 = connect("Bob3")
sent = {}
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob3.pc)
check(last("PSSET") ~= nil and persist.stats.load_fallbacks > fb0, "damaged record file: the .bak copy was read")
leave(bob3)
advance(1); host_tick()
-- 9b: inventory file newer than the record (crash between them) -> _bak inventory matches the record
spit(SAVEDIR .. "QuickSave1_SDCoop.json", good_json)
persist.reset("test2")
host_tick()
local recnow = json_dec(good_json).players.s76561190000000001
local mainblob = SAVEDIR .. "QuickSave1_SDCoop_s76561190000000001.sav"
local bakblob = SAVEDIR .. "QuickSave1_SDCoop_s76561190000000001_bak.sav"
spit(bakblob, slurp(mainblob))
-- the main inventory file now holds one more item than the record says
local t = json_dec(slurp(mainblob):sub(9))
table.insert(t.JigContainers.__arr[1][F_ITEMS].__arr, ser(item("DA_Bandage", 2, 5)))
spit(mainblob, "FAKESAVE" .. json_enc(t))
local bob4 = connect("Bob4")
sent = {}
fb0 = persist.stats.load_fallbacks
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob4.pc)
local set4 = last("PSSET")
check(set4 and set4.args[5]:find("inv", 1, true) and persist.stats.load_fallbacks > fb0, "inventory with the record's counts taken from _bak")
advance(3); host_tick()
deliver("PSRDY", { set4.args[1] }, bob4.pc)
advance(1); host_tick()
n = 0
for _, c in ipairs(bob4.pc._p.Pawn._p.BP_JigMultiplayer._p.MainJigContainers._i) do n = n + #c[F_ITEMS]._i end
check(n == recnow.inv.items, "restored from the previous inventory file (" .. n .. " items)")
leave(bob4)
advance(1); host_tick()
-- 9c: both inventory files unusable -> the record's item list
spit(mainblob, "garbage")
spit(bakblob, "garbage")
persist.reset("test3")
host_tick()
local bob5 = connect("Bob5")
sent = {}
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob5.pc)
local set5 = last("PSSET")
advance(3); host_tick()
check(#bob5.pc._p.Pawn._p.BP_JigMultiplayer._p.MainJigContainers._i[1][F_ITEMS]._i == 0, "item-list restore: no starting kit either")
deliver("PSRDY", { set5.args[1] }, bob5.pc)
advance(1); host_tick()
local adds = 0
for _, c in ipairs(calls) do if c:find("^AddNewItemSomewhere") then adds = adds + 1 end end
check(adds >= 3 and persist.stats.inv_fallback >= 1, "items given back one by one from the record's list (" .. adds .. ")")
leave(bob5)
advance(1); host_tick()

print("10. death: the record keeps no inventory (it is in the loot box)")
local bob6 = connect("Bob6")
sent = {}
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob6.pc)
local set6 = last("PSSET")
advance(3); host_tick()
deliver("PSRDY", { set6.args[1] }, bob6.pc)
advance(1); host_tick()
bob6.pc._p.Pawn._p["PlayerDead?"] = true
bob6.dead = true
advance(6); host_tick()
doc = json_dec(slurp(SAVEDIR .. "QuickSave1_SDCoop.json"))
rec = doc.players.s76561190000000001
check(rec.alive == false and rec.inv == nil and rec.why == "death", "dead record without inventory")
leave(bob6)
advance(1); host_tick()
local bob7 = connect("Bob7")
sent = {}
deliver("PSID", { "76561190000000001", "00112233445566778899", "Bob" }, bob7.pc)
local set7 = last("PSSET")
check(set7 and set7.args[5]:find("dead", 1, true) and not set7.args[5]:find("inv", 1, true), "dead record: progression only")
advance(3); host_tick()
check(#bob7.pc._p.Pawn._p.BP_JigMultiplayer._p.MainJigContainers._i[1][F_ITEMS]._i == 1, "respawned with the starting kit")
leave(bob7)
advance(1); host_tick()

print("11. the game deletes the slot: the player files go too")
local delh = hooks["/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot"]
check(delh and delh[1] and delh[1].pre, "delete hook registered")
delh[1].pre(param(ems), param(host_pc), param("SlotA"), param(0))
check(not exists(SAVEDIR .. "SlotA_SDCoop.json") and not exists(SAVEDIR .. "SlotA_SDCoop_s76561190000000001.sav"), "SlotA records and inventory deleted")
check(exists(SAVEDIR .. "QuickSave1_SDCoop.json"), "other slots untouched")

print("12. client without an answer from the host (older host): new character after the wait")
S.role = "client"; S.client = { id = 2 }
local cpc2 = new_pc("ClientPC2", false)
registry["PlayerController"] = { cpc2 }
ue.forget_world()
local cpawn2 = new_pawn("ClientChar2", { X = 0, Y = 0, Z = 0 })
cpawn2._p.InGameUI = hud
cpc2._p.Pawn = cpawn2
cpc2._p.LevellingComponent._p.CurrentLevel = 9
persist.reset("client")
loops.persist(); loops.progress()
advance(8)
loops.persist(); loops.progress()
check(cpc2._p.LevellingComponent._p.CurrentLevel == 9, "waits for the host's answer")
advance(16)
loops.persist(); loops.progress()
check(cpc2._p.LevellingComponent._p.CurrentLevel == 1, "no answer: a new character, as before")

-- ======================================================================
print("13. map discoveries (BP_POIManager): recorded, saved, restored on rejoin; old records load")
local POI_NAME = "Name_2_5D639B8747C652C2C1E4E2A0F1D71410"
local pois = {}
for i, nm in ipairs({ "Pinewood", "Gas Station", "Old Church", "Radio Tower" }) do
    local a = new_obj("BP_POIManager_C", "BP_POIManager_C_" .. i, { ["Explored?"] = false, POI = { [POI_NAME] = nm } }, {})
    a._m.ActorLoaded = function(self) calls[#calls + 1] = "ActorLoaded " .. self._short end
    pois[i] = a
end
new_obj("BP_POIManager_C", "Default__BP_POIManager_C", { ["Explored?"] = false }, {})   -- the CDO is never a place
ksl._m.K2_ClearTimer = function(_, o, fn) calls[#calls + 1] = "K2_ClearTimer " .. o._short .. " " .. tostring(fn) end
local function count_calls(prefix)
    local k = 0
    for _, c in ipairs(calls) do if c:sub(1, #prefix) == prefix then k = k + 1 end end
    return k
end
local function host_view()
    S.role = "host"; S.client = nil; S.remote = {}
    registry["PlayerController"] = { host_pc }
    ue.forget_world()
end
local function all_sent(kind)
    local out = {}
    for _, m in ipairs(sent) do if m.kind == kind then out[#out + 1] = m end end
    return out
end

print("13a. a record written before map discoveries were kept (no `map` field) still loads")
host_view()
current_slot = "MapSlot"
spit(SAVEDIR .. "MapSlot_SDCoop.json", json_enc({ format = 1, slot = "MapSlot", players = {
    s76561190000000088 = { key = "s76561190000000088", steam = "76561190000000088", name = "Old", alive = true,
        why = "left", updated_at = "2026-11-09 12:00:00", prog = { L = { CurrentLevel = 3 } }, tree = {} } } }))
persist.reset("map test")
host_tick()
check(persist._hs.world_slot == "MapSlot", "world slot MapSlot")
local old = connect("Old")
sent = {}
deliver("PSID", { "76561190000000088", "-", "Old" }, old.pc)
local oset = last("PSSET")
check(oset ~= nil and oset.args[2]:find("L.CurrentLevel=3", 1, true), "old record (no map): PSSET with its level")
check(last("PSMAPSET") == nil, "old record (no map): no PSMAPSET")
advance(3); host_tick()
check(old.pc._p.Pawn ~= nil and old.pc._p.LevellingComponent._p.CurrentLevel == 3, "old record restored on the host's copy")
leave(old)
advance(1); host_tick()
doc = json_dec(slurp(SAVEDIR .. "MapSlot_SDCoop.json"))
rec = doc.players.s76561190000000088
check(rec and rec.why == "left" and rec.prog.L.CurrentLevel == 3 and rec.map == nil, "old record written back unchanged, still without map")

print("13b. a new player discovers places: recorded, in the game's save and on leaving")
local mia = connect("Mia")
sent = {}
deliver("PSID", { "76561190000000077", "-", "Mia" }, mia.pc)
local mfr = last("PSFRESH")
check(mfr ~= nil, "Mia: fresh character")
local mgen = mfr.args[1]
advance(3); host_tick()
check(mia.pc._p.Pawn ~= nil, "Mia spawned")
deliver("PSMAP", { "wronggen", "BP_POIManager_C_3=Old Church" }, mia.pc)
deliver("PSMAP", { mgen, "BP_POIManager_C_1=Pinewood;BP_POIManager_C_2=Gas Station;BP_POIManager_C_44=Radio Tower;BP_POIManager_C_98=Nowhere;Default__BP_POIManager_C=x;bad id=y" }, mia.pc)
local mp = nil
for _, q in pairs(persist._P()) do if q.key == "s76561190000000077" then mp = q end end
check(mp and mp.map and mp.map.BP_POIManager_C_1 == "Pinewood" and mp.map.BP_POIManager_C_44 == "Radio Tower", "host keeps the reported places")
check(mp and mp.map.BP_POIManager_C_3 == nil, "a report with another gen is ignored")
check(mp and mp.map.Default__BP_POIManager_C == nil and mp.map["bad id"] == nil, "class default / bad names are not places")
check(persist.stats.map_new == 4, "4 new places counted: " .. persist.stats.map_new)
deliver("PSMAP", { mgen, "BP_POIManager_C_1=Pinewood" }, mia.pc)
check(persist.stats.map_new == 4, "the same place again: nothing new")
-- the game saves right away: the places are in the slot file at once
saveh[1].pre(param(host_pc))
run_delayed()
doc = json_dec(slurp(SAVEDIR .. "MapSlot_SDCoop.json"))
rec = doc.players.s76561190000000077
check(rec and rec.map and rec.map.BP_POIManager_C_2 == "Gas Station" and rec.map.BP_POIManager_C_98 == "Nowhere", "game save: the record has the places")
check(doc.players.s76561190000000088 and doc.players.s76561190000000088.map == nil, "the other (old) record is untouched")
-- one more discovery, then Mia leaves before any other write
deliver("PSMAP", { mgen, "BP_POIManager_C_3=Old Church" }, mia.pc)
leave(mia)
advance(1); host_tick()
doc = json_dec(slurp(SAVEDIR .. "MapSlot_SDCoop.json"))
rec = doc.players.s76561190000000077
local nm = 0
for _ in pairs(rec.map or {}) do nm = nm + 1 end
check(rec.why == "left" and nm == 5 and rec.map.BP_POIManager_C_3 == "Old Church", "on leaving: all 5 places in the record")

print("13c. Mia rejoins: the host sends the places right behind the record")
-- the client's last discovery (Old Church) is not in the record the client gets back below:
-- drop it so the client test can discover it again
persist.reset("map test 2")
doc.players.s76561190000000077.map.BP_POIManager_C_3 = nil
spit(SAVEDIR .. "MapSlot_SDCoop.json", json_enc(doc))
host_tick()
local mia2 = connect("Mia2")
sent = {}
deliver("PSID", { "76561190000000077", "-", "Mia" }, mia2.pc)
local mset = last("PSSET")
local msets = all_sent("PSMAPSET")
check(mset ~= nil and #msets == 1, "PSSET + one PSMAPSET")
check(msets[1] and msets[1].args[1] == mset.args[1] and msets[1].args[2] == "1" and msets[1].args[3] == "1", "PSMAPSET: same gen, part 1/1")
check(msets[1] and msets[1].args[4]:find("BP_POIManager_C_1=Pinewood", 1, true)
    and msets[1].args[4]:find("BP_POIManager_C_44=Radio Tower", 1, true), "PSMAPSET carries the places")
check(persist.stats.map_sent == 4, "4 places sent")
-- the client asks again (PSID crossed the answer): the same answer, places again
deliver("PSID", { "76561190000000077", "-", "Mia" }, mia2.pc)
check(#all_sent("PSMAPSET") == 2 and last("PSMAPSET").args[1] == mset.args[1], "a repeated answer repeats the places (same gen)")

print("13d. client: the places are set once the record is applied, the game's way")
S.role = "client"; S.client = { id = 3 }
local cpc3 = new_pc("ClientPC3", false)
registry["PlayerController"] = { cpc3 }
ue.forget_world()
local cpawn3 = new_pawn("ClientChar3", { X = 0, Y = 0, Z = 0 })
cpawn3._p.InGameUI = hud
cpc3._p.Pawn = cpawn3
steam_id = "76561190000000077"
pois[2]._p["Explored?"] = true   -- rediscovered (spawned next to it) before the record came: already known
sent = {}
loops.persist(); loops.progress()
deliver("PSSET", mset.args)
deliver("PSMAPSET", msets[1].args)
deliver("PSMAPSET", { "othergen", "1", "1", "BP_POIManager_C_3=Old Church" })
check(pois[1]._p["Explored?"] == false, "nothing is set before the record is applied")
local al0, ct0 = count_calls("ActorLoaded"), count_calls("K2_ClearTimer")
advance(7)
loops.progress(); loops.persist(); run_delayed()
check(persist._C().applied == mset.args[1], "record applied on the client")
check(pois[1]._p["Explored?"] == true and pois[4]._p["Explored?"] == true, "Pinewood set; Radio Tower found by its name (actor renamed)")
check(pois[3]._p["Explored?"] == false, "Old Church (other gen / not saved) untouched")
check(count_calls("ActorLoaded") - al0 == 2, "the load event ran on the 2 places set now")
local cleared = 0
for _, c in ipairs(calls) do if c == "K2_ClearTimer BP_POIManager_C_1 DistanceCheck" or c == "K2_ClearTimer BP_POIManager_C_4 DistanceCheck" then cleared = cleared + 1 end end
check(count_calls("K2_ClearTimer") - ct0 == 2 and cleared == 2, "the distance checks of those places stopped")
check(persist.stats.map_restored == 2, "2 places set now (1 was already known)")
local mtoast = false
for _, tx in ipairs(toasts) do if tx:find("Открытые места на карте восстановлены: 3", 1, true) then mtoast = true end end
check(mtoast, "Russian toast with 3 restored places")
local rp = last("PSMAP")
check(rp and rp.args[1] == mset.args[1] and rp.args[2] == "BP_POIManager_C_4=Radio Tower",
    "restored places are not reported back; the one found by its name is, under its current actor name")
-- the not-found saved place is given up after a few passes, without errors
advance(5); loops.persist()
advance(5); loops.persist()
check(next(persist._C().map_want or {}) == nil, "a saved place that is not in this world is given up")
-- a new discovery on this client (the game's DistanceCheck set Explored?)
pois[3]._p["Explored?"] = true
advance(5); loops.persist()
local pm = last("PSMAP")
check(pm and pm.args[1] == mset.args[1] and pm.args[2] == "BP_POIManager_C_3=Old Church", "new place reported with the record's gen")
sent = {}
advance(5); loops.persist()
check(last("PSMAP") == nil, "reported once")

print("13e. host side of that report, and many places in several messages")
host_view()
S.remote[mia2.key] = mia2
mia2.pc._valid = true
registry["PlayerController"] = { host_pc, mia2.pc }
ue.forget_world()
deliver("PSRDY", { mset.args[1] }, mia2.pc)
deliver("PSMAP", pm.args, mia2.pc)
local mp2 = nil
for _, q in pairs(persist._P()) do if q.key == "s76561190000000077" then mp2 = q end end
check(mp2 and mp2.map.BP_POIManager_C_3 == "Old Church" and mp2.map_dirty == true, "host: the new place is recorded, a write is due")
advance(16); host_tick()
doc = json_dec(slurp(SAVEDIR .. "MapSlot_SDCoop.json"))
check(doc.players.s76561190000000077.map.BP_POIManager_C_3 == "Old Church", "written within 15 s")
leave(mia2)
advance(1); host_tick()
local zed = connect("Zed")
sent = {}
deliver("PSID", { "76561190000000099", "-", "Zed" }, zed.pc)
local zgen = last("PSFRESH").args[1]
advance(3); host_tick()
local many = {}
for i = 1, 45 do many[#many + 1] = string.format("BP_POIManager_C_%d=Place %d", 100 + i, i) end
deliver("PSMAP", { zgen, table.concat(many, ";") }, zed.pc)
leave(zed)
advance(1); host_tick()
persist.reset("map test 3")
host_tick()
local zed2 = connect("Zed2")
sent = {}
deliver("PSID", { "76561190000000099", "-", "Zed" }, zed2.pc)
local zs = all_sent("PSMAPSET")
local zn = 0
for _, m in ipairs(zs) do for _ in m.args[4]:gmatch("[^;]+") do zn = zn + 1 end end
check(#zs == 2 and zs[1].args[3] == "2" and zs[2].args[2] == "2" and zn == 45, "45 places in 2 messages (" .. #zs .. ", " .. zn .. ")")
check(persist.status_line():find("map: recorded=", 1, true) ~= nil, "status line has the map counters")
leave(zed2)
advance(1); host_tick()

print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
