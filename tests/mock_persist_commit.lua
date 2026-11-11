-- Mock harness: the clients' records follow the host's saves
-- (sdc_persist, persist_follow_host_save).
--   live records during a session, commit at the game's save (only once the
--   game reports it done; nothing on a failed save), a load puts the save's
--   records back (position, inventory, level, quests), a re-join without a
--   reload keeps the live record, a crash before a save, a player who came
--   after the save, save to another slot, migration of an old slot, a crash
--   in the middle of a commit, damaged commit document, old generations
--   deleted, a PSID during the load job, slot delete, setting off = the old
--   behaviour, a lost committed inventory file, a load DURING the session
--   (death -> main menu -> Load: same level; a player still connected gets
--   the save's state again).
-- usage: lua mock_persist_commit.lua <scripts dir> [temp dir]
-- Player names / ids here are neutral (no Steam ids: the guid keys).
local SCRIPTS = arg[1]
local HERE = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local TMP = arg[2] or (HERE .. "/_tmp/persist_commit")
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- log lines (sdc_log prints each one)
local LOGS = {}
local real_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOGS[#LOGS + 1] = table.concat(parts, "\t")
    real_print(...)
end
local function log_mark() return #LOGS end
local function logged(pat, from)
    for i = (from or 0) + 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return LOGS[i] end end
    return nil
end

-- ------------------------------------------------------------ time, env, files
local NOW = 2000000
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return NOW end
local CLK = 100.0
os.clock = function() return CLK end
local function advance(s) NOW = NOW + s; CLK = CLK + s end
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return TMP end return real_getenv(k) end
local SAVEDIR = TMP .. "/SurrounDead/Saved/SaveGames/"
os.execute('rmdir /S /Q "' .. TMP:gsub("/", "\\") .. '" >nul 2>&1')
os.execute('mkdir "' .. (TMP .. "/SurrounDead/Saved/SaveGames"):gsub("/", "\\") .. '" >nul 2>&1')
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local d = f:read("a"); f:close(); return d end
local function spit(p, d) local f = assert(io.open(p, "wb")); f:write(d); f:close() end
spit(SAVEDIR .. "probe.txt", "x")
assert(exists(SAVEDIR .. "probe.txt"), "temp folder not writable: " .. SAVEDIR)
os.remove(SAVEDIR .. "probe.txt")

-- ------------------------------------------------------------ fake arrays / objects (as tests/persist/mock_persist.lua)
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
    return v
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
local function run_delayed(rounds)
    for _ = 1, rounds or 8 do
        local d = delayed
        delayed = {}
        for _, f in ipairs(d) do f() end
    end
end
local function run_one_delayed()   -- exactly one round
    local d = delayed
    delayed = {}
    for _, f in ipairs(d) do f() end
end

setmetatable(by_path, { __index = function(t, k)
    if type(k) == "string" and k:find(":") and not k:find("^/Script/EasyMultiSave%.Default") then
        local f = new_obj("Function", k)
        rawset(t, k, f)
        return f
    end
    return nil
end })

-- engine singletons
local current_slot = "CoopA"
local cvars = { ["Difficulty.KeepInventory"] = false }
new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return false end,
    IsServer = function() return true end,
    GetConsoleVariableBoolValue = function(_, n) return cvars[n] == true end,
}, "/Script/Engine.Default__KismetSystemLibrary")
local ems = new_obj("EMSFunctionLibrary", "Default__EMSFunctionLibrary", {}, {
    GetSlotInfoSaveGame = function(_, wc, out) out.SaveGameName = current_slot end,
    DeleteAllSaveDataForSlot = function() end,
}, "/Script/EasyMultiSave.Default__EMSFunctionLibrary")
new_obj("NetPushModelHelpers", "Default__NetPushModelHelpers", {}, {
    MarkPropertyDirtyFromRepIndex = function() end }, "/Script/Engine.Default__NetPushModelHelpers")
local jig_cls = new_obj("BlueprintGeneratedClass", "BP_JigMPComponentSave_C", {}, {},
    "/Game/JigSInventory/Jigsaw/Components/Save/BP_JigMPComponentSave.BP_JigMPComponentSave_C")
new_obj("BlueprintGeneratedClass", "BP_PlayerCharacter_C", {}, {}, "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C")

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"

local DA = {}
for _, n in ipairs({ "DA_Knife", "DA_Bandage", "DA_Rifle", "DA_Ammo", "DA_Water" }) do
    DA[n] = new_obj("JigsawItem_DataAsset_C", n, {}, {}, "/Game/Inventory/Data/" .. n .. "." .. n)
end
local uidn = 100
local function guid() uidn = uidn + 1; return { A = uidn, B = 2, C = 3, D = 4 } end
local function item(da, n, slot)
    return { [F_USID] = guid(), [F_INFO] = { [F_COUNT] = n, [F_ITEMID] = DA[da], [F_DUR] = { X = 80, Y = 100 } },
             [F_SLOT] = slot or 0 }
end
local function container(items) return { [F_CONT_UID] = guid(), [F_ITEMS] = arr(items or {}) } end

local json_enc, json_dec
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
local gps = new_obj("GameplayStatics", "Default__GameplayStatics", {}, {
    CreateSaveGameObject = function(_, cls) return cls == jig_cls and new_save_obj() or nil end,
    SaveGameToSlot = function(_, obj, name)
        local t = {}
        for _, k in ipairs({ "JigContainers", "MainUIDs", "Weights", "ActionbarUIDs", "PlayerLocation", "MapName" }) do
            t[k] = ser(obj._p[k])
        end
        spit(SAVEDIR .. name .. ".sav", "FAKESAVE" .. json_enc(t))
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
local function new_jig(conts)
    local jig = new_obj("BP_JigComponent_C", "BP_JigMultiplayer", {
        MainJigContainers = arr(conts or {}), MainContainersIDs = arr({ guid(), guid() }), InventoryWeight = arr({ {}, {} }) }, {})
    jig._m.SERVER_LoadSaveDataFromClientSide = function(self, c, u, w, hot)
        self._p.MainJigContainers, self._p.MainContainersIDs, self._p.InventoryWeight = deep(c), deep(u), deep(w)
    end
    jig._m.AddNewItemSomewhere = function(self, da, n, _, _, _, _, added)
        table.insert(self._p.MainJigContainers._i[1][F_ITEMS]._i, item(da._short, n))
        added.Added = true
    end
    return jig
end
local function new_pawn(name, loc)
    local med = new_obj("MedicalComponent_C", "Med", { Health = 100, MaxHealth = 100, ["Bleed?"] = false,
        ["HeavyBleed?"] = false, ["BrokenBone?"] = false, ["Infection?"] = false, InfectionTimeLeft = 0 },
        { ComponentLoaded = function() end })
    local p = new_obj("BP_PlayerCharacter_C", name, {
        __loc = loc, ["PlayerDead?"] = false, MedicalComponent = med,
        ["Hunger&ThirstComponent"] = new_obj("HungerThirstComponent_C", "HT", { CurrentHunger = 100, CurrentThirst = 100 }, {}),
        StaminaComponent = new_obj("StaminaComponent_C", "Stam", { CurrentStamina = 100 }, {}),
        RadiationComponent = new_obj("RadiationComponent_C", "Rad", { CurrentRadiation = 0 }, {}),
        BP_JigMultiplayer = new_jig({ container({}), container({}) }),
        ["DeathbringerSkillUsed?"] = false, ["InVehicle?"] = false,
    }, {})
    for _, f in ipairs({ "Client_UpdateHealthUI", "Client_UpdateHungerUI", "Client_UpdateThirstUI",
        "Client_UpdateStaminaUI", "Client_UpdateRadiationUI" }) do p._m[f] = function() end end
    return p
end
local function comp(cls, props, extra)
    local m = setmetatable(extra or {}, { __index = function() return function() end end })
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
    pc._m.GetControlRotation = function() return { Yaw = 10 } end
    pc._m.BindPlayerRespawn = function() end
    pc._m.Possess = function(self, pawn) self._p.Pawn = pawn; pawn._p.Controller = self end
    pc._m.IsLocalController = function() return not remote end
    if remote then pc._p.NetConnection = new_obj("IpConnection", "Conn_" .. name, {}, {}) else
        pc._p.Player = new_obj("LocalPlayer", "LP_" .. name, {}, {}) end
    return pc
end
for _, n in ipairs({ "Skill_Parkour", "Skill_HealthRegen" }) do
    new_obj("BP_SkillTreeAsset_C", n, {}, {}, "/Game/Blueprints/SkillTree/Skills/" .. n .. "." .. n)
end
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
package.preload["sdc_steam"] = function() return { own_id = function() return nil end } end
require("sdc_steam")

-- sdc_quests' save of a client's own quests: a file per player and slot
-- (<slot>_SDQuests_<key>.sav), the "component" = QUEST[pc short name]
local QUEST, QBOUND = {}, {}
package.loaded["sdc_quests"] = {
    persist_bind = function(pc, slot, key, load)
        local name = tostring(slot) .. "_SDQuests_" .. tostring(key)
        QBOUND[pc._short] = name
        if load then QUEST[pc._short] = slurp(SAVEDIR .. name .. ".sav") or "(no save)" end
        return true
    end,
    persist_save = function(pc)
        local name = QBOUND[pc._short]
        if not name or not QUEST[pc._short] then return false end
        spit(SAVEDIR .. name .. ".sav", QUEST[pc._short])
        return true
    end,
    persist_delete = function(slot, key)
        os.remove(SAVEDIR .. tostring(slot) .. "_SDQuests_" .. tostring(key) .. ".sav")
        return true
    end,
}
local quests = package.loaded["sdc_quests"]

local cfg = require("sdc_config")
cfg.load(TMP .. "/config.ini")
check(cfg.get("persist_follow_host_save") == true, "persist_follow_host_save defaults to on")
local log = require("sdc_log")
log.toast_sink = function() end
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... } }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... } }; return true end
local function last(kind, to)
    for i = #sent, 1, -1 do if sent[i].kind == kind and (to == nil or sent[i].to == to) then return sent[i] end end
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
check(loops.persist ~= nil and persist._CM ~= nil, "persist installed, commit machinery present")

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
-- a player joins: the verdict, the character, the restore; returns r, "restore" | "fresh", message
local function join(name, gid)
    local r = connect(name)
    sent = {}
    deliver("PSID", { "-", gid, name }, r.pc)
    local set, fr = last("PSSET", r.pc), last("PSFRESH", r.pc)
    advance(3); host_tick()
    if set then
        deliver("PSRDY", { set.args[1] }, r.pc)
        advance(1); host_tick()
        return r, "restore", set
    end
    return r, "fresh", fr
end

local function inv_count(pawn)
    local n = 0
    for _, c in ipairs(pawn._p.BP_JigMultiplayer._p.MainJigContainers._i) do n = n + #c[F_ITEMS]._i end
    return n
end
local function add_item(pawn, da, n)
    table.insert(pawn._p.BP_JigMultiplayer._p.MainJigContainers._i[2][F_ITEMS]._i, item(da, n or 1, 3))
end
local function blob_items(name)
    local d = slurp(SAVEDIR .. name .. ".sav")
    if not d or d:sub(1, 8) ~= "FAKESAVE" then return nil end
    local t = json_dec(d:sub(9))
    local n = 0
    for _, c in ipairs(t.JigContainers.__arr) do n = n + #c[F_ITEMS].__arr end
    return n
end
local function doc(name)
    local d = slurp(SAVEDIR .. name)
    return d and json_dec(d) or nil
end

local SAVE_FN = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot"
local EMS_SAVE = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
local SAVED = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:OnCompleted_9CDBA9034C950D925C1539BE037C23EF"
local FAILED = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:OnFailed_9CDBA9034C950D925C1539BE037C23EF"
local DELETE = "/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot"
local function hook(path) local h = hooks[path]; return h and h[#h] end
-- the game saves into `slot`: both save hooks, then (end = true / false /
-- nil) the game's "actors saved" / "failed" / nothing yet
local function game_save(slot, done)
    current_slot = slot
    hook(SAVE_FN).pre(param(host_pc))
    hook(EMS_SAVE).post(param(nil), param(nil), param(host_pc), param(3))
    run_delayed()
    if done ~= nil then
        hook(done and SAVED or FAILED).pre(param(host_pc))
        run_delayed()
    end
end
-- the host opens a world from `slot` (level change: the old world closes first)
local function load_world(slot)
    persist.reset("loadmap")
    if session.world_reset_hooks.progress then session.world_reset_hooks.progress("loadmap") end
    for k, r in pairs(S.remote) do leave(r) end
    S.remote = {}
    current_slot = slot
    host_tick()
end
-- the game process ends without a world change (crash / killed): nothing is
-- flushed; then it starts again and opens the world from `slot`
local function crash_and_load(slot)
    for k, r in pairs(S.remote) do leave(r) end
    S.remote = {}
    package.loaded["sdc_persist"] = nil
    persist = require("sdc_persist")
    persist.install(S)
    if session.world_reset_hooks.progress then session.world_reset_hooks.progress("restart") end
    current_slot = slot
    host_tick()
end

local GA = "a1a1a1a1a1a1a1a1a1a1"   -- player "Alpha" (guid key gA)
local GB = "b2b2b2b2b2b2b2b2b2b2"   -- player "Bravo"
local GC = "c3c3c3c3c3c3c3c3c3c3"   -- player "Charlie"
local KA, KB, KC = "g" .. GA, "g" .. GB, "g" .. GC
local function pa() for _, q in pairs(persist._P()) do if q.key == KA then return q end end end

-- ======================================================================
print("1. a session: Alpha plays, the live record follows; nothing committed before a save")
host_tick()
check(persist._hs.world_slot == "CoopA", "world slot CoopA")
local alpha, how = join("Alpha", GA)
check(how == "fresh", "Alpha: a new character")
local ap = alpha.pc._p.Pawn
check(ap ~= nil and inv_count(ap) == 1, "Alpha spawned with the starting kit")
deliver("PSPROG", { pa().gen, "L.CurrentLevel=2;L.CurrentXP=10", "-", "?" }, alpha.pc)
add_item(ap, "DA_Bandage", 2)
ap._p.__loc = { X = 1000, Y = 2000, Z = 300 }
QUEST[alpha.pc._short] = "quests@save1"
quests.persist_save(alpha.pc)
advance(16); host_tick()
local live = doc("CoopA_SDCoop.json")
check(live and live.players[KA] and live.players[KA].inv.items == 2, "live record written during play (2 items)")
check(not exists(SAVEDIR .. "CoopA_SDCoop_commit.json"), "no commit before the game saves")

print("2. the game saves: committed only once the game reports the save done")
local m0 = log_mark()
game_save("CoopA", nil)
check(not exists(SAVEDIR .. "CoopA_SDCoop_commit.json"), "save started, not finished: nothing committed yet")
check(persist._hs.commit_wait and persist._hs.commit_wait.slot == "CoopA", "commit waits for the game's save end")
hook(SAVED).pre(param(host_pc))
run_delayed()
local c1 = doc("CoopA_SDCoop_commit.json")
check(c1 and c1.gen == 1 and c1.players[KA], "commit document written (generation 1)")
local ca = c1 and c1.players[KA]
check(ca and ca.inv.items == 2 and ca.inv.cfile == "CoopA_SDCoop_" .. KA .. "_c1", "committed record names its inventory copy")
check(blob_items("CoopA_SDCoop_" .. KA .. "_c1") == 2, "committed inventory file holds the 2 items")
check(ca and ca.cq == "CoopA_SDCoop_" .. KA .. "_q1" and slurp(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_q1.sav") == "quests@save1",
    "committed quest save")
check(ca and ca.pos and ca.pos.x == 1000 and ca.prog.L.CurrentLevel == 2, "committed position and level")
check(logged("persist: committed 1 client record(s) to slot CoopA (game save", m0) ~= nil, "log: committed 1 client record(s) to slot CoopA (...)")

print("3. after the save: Alpha goes on (live changes), Bravo comes for the first time")
add_item(ap, "DA_Rifle", 1)
ap._p.__loc = { X = 9000, Y = 9000, Z = 500 }
deliver("PSPROG", { pa().gen, "L.CurrentLevel=5;L.CurrentXP=10", "-", "?" }, alpha.pc)
QUEST[alpha.pc._short] = "quests@later"
quests.persist_save(alpha.pc)
advance(16); host_tick()
local bravo = join("Bravo", GB)
add_item(bravo.pc._p.Pawn, "DA_Water", 1)
QUEST[bravo.pc._short] = "bravo quests"
quests.persist_save(bravo.pc)
advance(11); host_tick()
live = doc("CoopA_SDCoop.json")
check(live.players[KA].inv.items == 3 and live.players[KA].prog.L.CurrentLevel == 5, "live record: 3 items, level 5")
check(live.players[KB] ~= nil, "Bravo has a live record")
check(doc("CoopA_SDCoop_commit.json").players[KA].inv.items == 2 and doc("CoopA_SDCoop_commit.json").players[KB] == nil,
    "the commit is untouched by live writes")

print("4. re-join without a reload: the live record (no rollback)")
leave(alpha)
advance(1); host_tick()
local alpha2, how2, set2 = join("Alpha", GA)
check(how2 == "restore" and set2.args[2]:find("L.CurrentLevel=5", 1, true), "same running world: level 5 (live)")
local ap2 = alpha2.pc._p.Pawn
check(ap2 and inv_count(ap2) == 3, "same running world: 3 items (live)")
check(ap2 and ap2._p.__loc.X == 9000, "same running world: where Alpha left")
check(logged("record from this session (this session's live record", m0) ~= nil, "log: this session's live record used")

print("5. crash before the next save: the world loads from CoopA's save, so do the players")
local m1 = log_mark()
crash_and_load("CoopA")
check(logged("persist: slot CoopA loaded: 1 client record(s) back to the save (live ones from", m1) ~= nil,
    "log: slot CoopA loaded: 1 client record(s) back to the save (live ones from ... dropped)")
check(logged("1 player(s) who came after that save start as new characters: Bravo", m1) ~= nil, "log names the player who came after the save")
live = doc("CoopA_SDCoop.json")
check(live.players[KA].inv.items == 2 and live.players[KA].prog.L.CurrentLevel == 2, "live record = the save's (2 items, level 2)")
check(live.players[KB] == nil, "Bravo (not in the save) dropped from the live records")
check(blob_items("CoopA_SDCoop_" .. KA) == 2, "live inventory file = the save's")
check(blob_items("CoopA_SDCoop_" .. KA .. "_bak") == 3, "the dropped live inventory kept as _bak")
check(doc("CoopA_SDCoop.json.bak").players[KB] ~= nil, "the dropped live document kept as .json.bak")
check(slurp(SAVEDIR .. "CoopA_SDQuests_" .. KA .. ".sav") == "quests@save1", "live quest save = the save's")
local alpha3, how3, set3 = join("Alpha", GA)
check(how3 == "restore" and set3.args[2]:find("L.CurrentLevel=2", 1, true), "Alpha rejoins at the save's level 2")
local ap3 = alpha3.pc._p.Pawn
check(ap3 and ap3._p.__loc.X == 1000 and math.abs(ap3._p.__loc.Z - 330) < 1, "Alpha spawns at the save's position")
check(ap3 and inv_count(ap3) == 2, "Alpha has the save's 2 items (no rifle taken after the save)")
check(QUEST[alpha3.pc._short] == "quests@save1", "Alpha's quests are the save's")
check(logged("(the save's record, committed", m1) ~= nil, "log on join: the save's record was used")
local bravo2, howb = join("Bravo", GB)
check(howb == "fresh", "Bravo (came after the save): a new character")
check(logged("a live record from after the save was dropped", m1) ~= nil, "log on join: Bravo's live record was dropped")

print("6. save to another slot (save as), then load each slot")
add_item(ap3, "DA_Ammo", 30)
add_item(ap3, "DA_Ammo", 30)
advance(11); host_tick()
check(inv_count(ap3) == 4, "Alpha has 4 items now")
QUEST[alpha3.pc._short] = "quests@saveB"
quests.persist_save(alpha3.pc)   -- (CoopA's file; the save binds and saves CoopB's)
QUEST[bravo2.pc._short] = nil
local m2 = log_mark()
game_save("CoopB", true)
check(persist._hs.world_slot == "CoopB", "the world is CoopB's now")
local cb = doc("CoopB_SDCoop_commit.json")
check(cb and cb.players[KA] and cb.players[KA].inv.items == 4, "CoopB committed with 4 items")
check(cb and cb.players[KB] ~= nil and cb.players[KB].cq == false, "Bravo committed to CoopB (no quest save then: marked)")
check(slurp(SAVEDIR .. cb.players[KA].cq .. ".sav") == "quests@saveB", "CoopB's committed quests")
check(doc("CoopA_SDCoop_commit.json").gen == 1 and doc("CoopA_SDCoop_commit.json").players[KA].inv.items == 2,
    "CoopA's commit unchanged by the save to CoopB")
check(logged("persist: committed 2 client record(s) to slot CoopB", m2) ~= nil, "log: committed 2 to CoopB")
-- Bravo gets quests after the CoopB save: not that save's
QUEST[bravo2.pc._short] = "bravo after B"
quests.persist_save(bravo2.pc)
check(exists(SAVEDIR .. "CoopB_SDQuests_" .. KB .. ".sav"), "Bravo's later quest save exists")
load_world("CoopA")
local alpha4, _, set4 = join("Alpha", GA)
check(set4 and set4.args[2]:find("L.CurrentLevel=2", 1, true) and inv_count(alpha4.pc._p.Pawn) == 2, "load CoopA: CoopA's save (2 items)")
local b3, howb3 = join("Bravo", GB)
check(howb3 == "fresh", "load CoopA: Bravo was not in CoopA's save")
leave(alpha4); leave(b3)
load_world("CoopB")
local alpha5, _, set5 = join("Alpha", GA)
check(set5 and inv_count(alpha5.pc._p.Pawn) == 4, "load CoopB: CoopB's save (4 items)")
check(QUEST[alpha5.pc._short] == "quests@saveB", "load CoopB: CoopB's quests")
check(not exists(SAVEDIR .. "CoopB_SDQuests_" .. KB .. ".sav") and slurp(SAVEDIR .. "CoopB_SDQuests_" .. KB .. "_bak.sav") == "bravo after B",
    "Bravo's quest save from after the save set aside (_bak)")
local b4, howb4 = join("Bravo", GB)
check(howb4 == "restore", "load CoopB: Bravo restored (he was in CoopB's save)")
check(QUEST[b4.pc._short] == "(no save)", "Bravo: no quests (none at that save)")
leave(alpha5); leave(b4)

print("7. a failed save commits nothing; old generations are deleted")
load_world("CoopA")
local alpha6 = join("Alpha", GA)
add_item(alpha6.pc._p.Pawn, "DA_Rifle", 1)
advance(11); host_tick()
local m3 = log_mark()
game_save("CoopA", false)
check(doc("CoopA_SDCoop_commit.json").gen == 1, "failed save: the commit stays generation 1")
check(logged("FAILED: the clients' records are NOT committed", m3) ~= nil or logged("save of slot CoopA FAILED", m3) ~= nil,
    "log: failed save not committed")
game_save("CoopA", true)
check(doc("CoopA_SDCoop_commit.json").gen == 2 and doc("CoopA_SDCoop_commit.json.bak").gen == 1, "generation 2, 1 kept as .bak")
game_save("CoopA", true)
check(doc("CoopA_SDCoop_commit.json").gen == 3 and doc("CoopA_SDCoop_commit.json.bak").gen == 2, "generation 3, 2 kept as .bak")
check(not exists(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_c1.sav") and not exists(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_q1.sav"),
    "generation 1 files deleted")
check(exists(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_c2.sav") and exists(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_c3.sav"),
    "generations 2 and 3 files kept")
-- the save's end before the records (order of the hooks): still committed
current_slot = "CoopA"
hook(SAVED).pre(param(host_pc))
run_delayed()
hook(SAVE_FN).pre(param(host_pc))
run_delayed()
check(doc("CoopA_SDCoop_commit.json").gen == 4, "the game's save end seen first: committed with the records")
-- a save the game never reports done: dropped after the wait
game_save("CoopA", nil)
advance(61); host_tick()
check(doc("CoopA_SDCoop_commit.json").gen == 4 and persist._hs.commit_wait == nil, "no save end within 60 s: not committed")

print("8. a crash in the middle of a commit: the previous commit stays whole")
local bravo7 = join("Bravo", GB)
advance(11); host_tick()
persist._CM.STEP_BYTES = 1       -- one player per step
game_save("CoopA", nil)
hook(SAVED).pre(param(host_pc))
run_one_delayed()                 -- the save end -> the commit starts: first player only
check(persist._hs.job and persist._hs.job.kind == "commit" and persist._hs.job.i == 1, "commit job half done")
check(exists(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_c5.sav"), "first player's generation 5 file written")
check(doc("CoopA_SDCoop_commit.json").gen == 4, "commit document still generation 4")
local before = doc("CoopA_SDCoop_commit.json")
delayed = {}                      -- the process dies here
crash_and_load("CoopA")
check(logged("back to the save", #LOGS - 12) ~= nil and doc("CoopA_SDCoop.json").players[KB] == nil,
    "after the crash: back to generation 4 (Bravo was not in it)")
check(blob_items("CoopA_SDCoop_" .. KA) == before.players[KA].inv.items, "inventory = generation 4's")
game_save("CoopA", true)
check(doc("CoopA_SDCoop_commit.json").gen == 5, "the next commit is generation 5 again (old leftovers overwritten)")
persist._CM.STEP_BYTES = 256 * 1024

print("9. a damaged commit document: the previous copy; a crash between the two renames")
spit(SAVEDIR .. "CoopA_SDCoop_commit.json", "{ broken")
local m4 = log_mark()
load_world("CoopA")
check(logged("taken from the previous copy (.bak)", m4) ~= nil, "damaged commit: the .bak (generation 4) is used")
check(persist._hs.loaded and persist._hs.loaded.mode == "save", "records back to that save")
game_save("CoopA", true)
local c6 = doc("CoopA_SDCoop_commit.json")
check(c6 and c6.gen == 5 and doc("CoopA_SDCoop_commit.json.bak").gen == 4, "next commit: the damaged one is not kept over the good .bak")
check(exists(SAVEDIR .. "CoopA_SDCoop_" .. KA .. "_c4.sav"), "generation 4 files kept (they are the .bak's)")
-- main renamed to .bak, the new one never renamed in (crash inside rotate)
os.remove(SAVEDIR .. "CoopA_SDCoop_commit.json.bak")
os.rename(SAVEDIR .. "CoopA_SDCoop_commit.json", SAVEDIR .. "CoopA_SDCoop_commit.json.bak")
crash_and_load("CoopA")
check(persist._hs.loaded and persist._hs.loaded.mode == "save" and persist._hs.loaded.at == c6.committed_at,
    "crash inside the rename: the .bak (the last commit) is used")

print("10. a PSID while the save's records are still being copied back: finished at once")
local alpha10 = join("Alpha", GA)
local bravo10 = join("Bravo", GB)
add_item(alpha10.pc._p.Pawn, "DA_Water", 1)
advance(11); host_tick()
game_save("CoopA", true)
local committed_items = doc("CoopA_SDCoop_commit.json").players[KB].inv.items
add_item(bravo10.pc._p.Pawn, "DA_Rifle", 1)
add_item(bravo10.pc._p.Pawn, "DA_Rifle", 1)
advance(11); host_tick()
check(blob_items("CoopA_SDCoop_" .. KB) == committed_items + 2, "Bravo's live inventory moved on")
persist._CM.STEP_BYTES = 1
for k, r in pairs(S.remote) do leave(r) end
S.remote = {}
persist.reset("loadmap")
current_slot = "CoopA"
loops.persist()                   -- the world is seen: the load job's first step only
check(persist._hs.job and persist._hs.job.kind == "reset", "load job running")
local bravo11 = connect("Bravo")
sent = {}
deliver("PSID", { "-", GB, "Bravo" }, bravo11.pc)
check(persist._hs.job == nil, "the PSID finished the load job")
check(blob_items("CoopA_SDCoop_" .. KB) == committed_items, "Bravo's inventory file is the save's before his verdict")
check(last("PSSET", bravo11.pc) ~= nil, "Bravo restored")
persist._CM.STEP_BYTES = 256 * 1024
delayed = {}
leave(bravo11)

print("11. migration: a slot from before this setting (live records only)")
-- an old slot: CoopA's live files under another name, no commit
local la = doc("CoopA_SDCoop.json")
la.slot = "OldSlot"
for k, r in pairs(la.players) do
    if r.inv then
        spit(SAVEDIR .. "OldSlot_SDCoop_" .. k .. ".sav", slurp(SAVEDIR .. "CoopA_SDCoop_" .. k .. ".sav"))
        r.inv.slot, r.inv.file = "OldSlot", "OldSlot_SDCoop_" .. k
    end
end
spit(SAVEDIR .. "OldSlot_SDCoop.json", json_enc(la))
local old_items = la.players[KA].inv.items
local m5 = log_mark()
load_world("OldSlot")
check(logged("persist: slot OldSlot has no committed client records yet", m5) ~= nil, "log: migration of OldSlot")
local cm = doc("OldSlot_SDCoop_commit.json")
check(cm and cm.players[KA] and cm.players[KA].inv.items == old_items and cm.why:find("^migration"), "the live records became the commit")
local alpha11, howm = join("Alpha", GA)
check(howm == "restore" and inv_count(alpha11.pc._p.Pawn) == old_items, "Alpha keeps the current character (nothing lost)")
check(logged("live record: no committed records yet", m5) ~= nil, "log on join: live record (migration)")
add_item(alpha11.pc._p.Pawn, "DA_Knife", 1)
advance(11); host_tick()
crash_and_load("OldSlot")
local alpha12 = join("Alpha", GA)
check(inv_count(alpha12.pc._p.Pawn) == old_items, "a crash before any save: back to the migrated records")
leave(alpha12)

print("12. the game deletes a slot: committed files go too")
check(exists(SAVEDIR .. "CoopB_SDCoop_commit.json") and exists(SAVEDIR .. "CoopB_SDCoop_" .. KA .. "_c1.sav"), "CoopB has a commit")
hook(DELETE).pre(param(ems), param(host_pc), param("CoopB"), param(0))
check(not exists(SAVEDIR .. "CoopB_SDCoop_commit.json") and not exists(SAVEDIR .. "CoopB_SDCoop_" .. KA .. "_c1.sav")
    and not exists(SAVEDIR .. "CoopB_SDCoop_" .. KA .. "_q1.sav") and not exists(SAVEDIR .. "CoopB_SDCoop.json"),
    "CoopB's records, commit and files deleted")
check(exists(SAVEDIR .. "CoopA_SDCoop_commit.json"), "other slots untouched")

print("13. setting off: the old behaviour (live records survive a load); commits are still written")
cfg.set("persist_follow_host_save", false)
load_world("CoopA")
local alpha13 = join("Alpha", GA)
local committed_a = doc("CoopA_SDCoop_commit.json").players[KA].inv.items
add_item(alpha13.pc._p.Pawn, "DA_Bandage", 1)
add_item(alpha13.pc._p.Pawn, "DA_Bandage", 1)
advance(11); host_tick()
local live_a = inv_count(alpha13.pc._p.Pawn)
local m6 = log_mark()
load_world("CoopA")
check(logged("persist_follow_host_save is off: the 1 live client record(s)", m6) ~= nil or
    logged("persist_follow_host_save is off: the 2 live client record(s)", m6) ~= nil, "log: off, live records used")
local alpha14 = join("Alpha", GA)
check(inv_count(alpha14.pc._p.Pawn) == live_a and live_a == committed_a + 2, "off: the live inventory, not the save's")
check(logged("(live record: persist_follow_host_save is off)", m6) ~= nil, "log on join: live record (off)")
local g0 = doc("CoopA_SDCoop_commit.json").gen
game_save("CoopA", true)
check(doc("CoopA_SDCoop_commit.json").gen == g0 + 1, "off: the save still commits (turning it on later starts from the save)")
check(persist.status_line():find("commit: follow=false", 1, true) ~= nil, "status line shows the commit state")
cfg.set("persist_follow_host_save", true)
leave(alpha14)

print("14. a committed inventory file lost: the save's item list is used, never the live file")
local c14 = doc("CoopA_SDCoop_commit.json")
local want = c14.players[KA].inv.items
os.remove(SAVEDIR .. c14.players[KA].inv.cfile .. ".sav")
local m7 = log_mark()
local fb = persist.stats.inv_fallback
load_world("CoopA")
check(logged("the record's item list is used", m7) ~= nil, "log: committed inventory file missing")
local alpha15 = join("Alpha", GA)
check(persist.stats.inv_fallback == fb + 1, "the live inventory file was not used (item-list restore)")
check(inv_count(alpha15.pc._p.Pawn) == want, "Alpha gets the save's " .. want .. " item(s) back from the record's list ("
    .. inv_count(alpha15.pc._p.Pawn) .. ")")

print("15. a load DURING the session (the host died -> main menu -> Load: the same level, no world change)")
local LOAD = persist._CM.LOAD_FN
check(hook(LOAD) ~= nil and hook(LOAD).pre ~= nil, "the game's load hook (EMS AsyncLoadActors, pre) registered")
alpha15.pc._p.Pawn._p.__loc = { X = 4000, Y = 4000, Z = 100 }
advance(6); host_tick()
game_save("CoopA", true)
local c15 = doc("CoopA_SDCoop_commit.json")
local items15, gen15 = c15.players[KA].inv.items, c15.gen
-- after the save: Alpha goes on far away, Bravo comes and goes
add_item(alpha15.pc._p.Pawn, "DA_Rifle", 1)
add_item(alpha15.pc._p.Pawn, "DA_Rifle", 1)
alpha15.pc._p.Pawn._p.__loc = { X = 60000, Y = 60000, Z = 100 }
deliver("PSPROG", { pa().gen, "L.CurrentLevel=9;L.CurrentXP=1", "-", "?" }, alpha15.pc)
local charlie15 = join("Charlie", GC)
advance(16); host_tick()
leave(charlie15)
advance(1); host_tick()
check(doc("CoopA_SDCoop.json").players[KC] ~= nil and persist._live()[KC] ~= nil, "before the load: Charlie's live record")
local old_gen = pa().gen
local r0, m8 = persist.stats.resets, log_mark()
-- the game's load of the slot: no persist.reset, no world change; Alpha stays connected
current_slot = "CoopA"
sent = {}
hook(LOAD).pre(param(nil), param(host_pc))
check(persist._hs.load_wait ~= nil, "PSIDs wait while the load starts")
run_delayed()
check(logged("the game loaded slot CoopA during the session", m8) ~= nil, "log: the game loaded slot CoopA during the session")
check(persist.stats.resets == r0 + 1 and logged("back to the save (live ones from", m8) ~= nil, "records back to the save")
check(persist._live()[KC] == nil and doc("CoopA_SDCoop.json").players[KC] == nil, "Charlie's live record (after the save) dropped")
host_tick()
local set15 = last("PSSET", alpha15.pc)
check(set15 ~= nil and set15.args[1] ~= old_gen, "Alpha (still connected) gets a new verdict")
check(set15 and set15.args[2]:find("L.CurrentLevel=" .. tostring(c15.players[KA].prog.L.CurrentLevel), 1, true),
    "with the save's level (not 9)")
check(logged("stayed connected through the load", m8) ~= nil, "log: stayed connected through the load")
deliver("PSRDY", { set15.args[1] }, alpha15.pc)
advance(1); host_tick()
check(inv_count(alpha15.pc._p.Pawn) == items15, "Alpha's inventory back to the save's " .. items15 .. " item(s) ("
    .. inv_count(alpha15.pc._p.Pawn) .. ")")
local un = last("UNSTUCKTO", alpha15.pc)
check(un and tonumber(un.args[1]) == c15.players[KA].pos.x, "Alpha moved back to the save's position")
local charlie16, howc16 = join("Charlie", GC)
check(howc16 == "fresh" and logged("a live record from after the save was dropped", m8) ~= nil, "Charlie rejoins: a new character")
-- a load right after a world change: done once (world_seen), the game's load event adds nothing
leave(alpha15); leave(charlie16)
load_world("CoopA")
local r1, m9 = persist.stats.resets, log_mark()
hook(LOAD).pre(param(nil), param(host_pc))
run_delayed()
check(persist.stats.resets == r1 and logged("already as at its save", m9) ~= nil, "first load of a world: not reset twice")
check(doc("CoopA_SDCoop_commit.json").gen == gen15, "loads never commit")

print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
