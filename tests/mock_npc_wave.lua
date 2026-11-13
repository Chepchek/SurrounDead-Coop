-- Mock harness, wave "ai" 2026-11-13: sdc_npc
--   npc_marker   a client's enemy marker goes 60 s after the last sight (its copy has no AI controller)
--   npc_looks    civilians (look + name plate) and the pet dog look as on the host
--   [SLOW] line for a slow ClientRepObjRef apply
-- The real sdc_npc / sdc_ue / sdc_net / sdc_config / sdc_log against fake UE objects.
-- usage: lua mock_npc_wave.lua <scripts dir>
-- (harness core from mock_npc.lua)
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails = 0
local function check(cond, what)
    if cond then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local quiet_print = print
print = function(s) if os.getenv("MOCK_VERBOSE") then io.write(s) end end

-- ---------------------------------------------------------------- fake objects
local W
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    return rawget(t, "_m")[k]
end
local next_addr = 4096
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function new(chain, name, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true, _calls = {} }, Obj)
    W.objects[#W.objects + 1] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass()
    local chain = self._chain
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n)
    if n == "__missing" then error("no such property") end
    return self._p[n]
end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:IsA(cls)
    for _, c in ipairs(self._chain) do if c == cls._isa then return true end end
    return false
end
local function called(o, fn)
    for _, c in ipairs(o._calls) do if c[1] == fn then return c end end
    return nil
end
local function record(fn) return function(self, ...) self._calls[#self._calls + 1] = { fn, ... }; return true end end

local function asset(cls, path)
    local o = new({ cls }, path:match("([^%.]+)$"))
    o._full = cls .. " " .. path
    W.paths[path] = o
    return o
end
local function class_asset(path, isa_name)
    local o = new({ "BlueprintGeneratedClass" }, path:match("([^%.]+)$"))
    o._full = "BlueprintGeneratedClass " .. path
    o._isa = isa_name
    W.paths[path] = o
    return o
end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end } end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    W.hooks[path] = W.hooks[path] or {}
    table.insert(W.hooks[path], { pre = a, post = b })
    return 1, 2
end
StaticFindObject = function(path)
    local o = W.paths[path]
    if o and o._valid then return o end
    return nil
end
local function derives(o, cls) for _, c in ipairs(o._chain) do if c == cls then return true end end return false end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(W.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) W.loads = W.loads + 1; return W.lazy[path] and asset(W.lazy[path], path) or nil end
ExecuteInGameThread = function(fn) fn() end
ExecuteInGameThreadWithDelay = function() return 1 end
LoopInGameThreadWithDelay = function() return 1 end

local function fire(path, ...)
    local hs = W.hooks[path]
    if not hs then return false end
    for _, h in ipairs(hs) do
        local r = h.pre(...)
        assert(r == nil, "hook returned a value: " .. path)
    end
    return true
end

local BOSS = "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C"
local ROCK = "/Game/AI/Zombies/Boss/BP_ZombieBossRock.BP_ZombieBossRock_C"
local HUMAN = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C"
local BANDIT = "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C"
local DMG = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C"
local OBJREF = "/Script/Engine.PlayerController:ClientRepObjRef"
local BOSS_HIT = "BndEvt__DamageTester_DamageComponent_K2Node_ComponentBoundEvent_0_StandardDamage__DelegateSignature"

local function make_pc(local_player, loc)
    local pawn = new({ "BP_PlayerCharacter_C" }, "BP_PlayerCharacter_C_" .. next_addr, { _loc = loc })
    local player = new({ local_player and "LocalPlayer" or "NetConnection" }, "Player_" .. next_addr)
    local pc = new({ "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. next_addr,
        { Pawn = pawn, Player = player, NetConnection = (not local_player) and player or nil }, {
            ClientMessage = function(self, msg) W.out[#W.out + 1] = { pc = self, msg = msg } end,
            ClientRepObjRef = function(self, o) W.out[#W.out + 1] = { pc = self, obj = o } end,
        })
    return pc, pawn
end

local function comp(chain, name, props, methods)
    methods = methods or {}
    methods.GetMaterial = methods.GetMaterial or function(self) return self._p._mat end
    methods.SetMaterial = methods.SetMaterial or function(self, _, m) self._p._mat = m; record("SetMaterial")(self, m) end
    methods.SetStaticMesh = methods.SetStaticMesh or function(self, m) self._p.StaticMesh = m; record("SetStaticMesh")(self, m) end
    methods.SetSkinnedAssetAndUpdate = methods.SetSkinnedAssetAndUpdate or function(self, a, r)
        self._p.SkeletalMeshAsset = a; record("SetSkinnedAssetAndUpdate")(self, a, r) end
    methods.K2_SetRelativeLocationAndRotation = function(self, l, r)
        self._p.RelativeLocation, self._p.RelativeRotation = l, r; record("SetRelLocRot")(self, l, r) end
    methods.SetRelativeScale3D = function(self, s) self._p.RelativeScale3D = s; record("SetRelScale")(self, s) end
    return new(chain, name, props, methods)
end

local function make_bandit(loc, role, look)
    look = look or {}
    local mesh = comp({ "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr,
        { VisibilityBasedAnimTickOption = 3, SkeletalMeshAsset = W.paths[look.body or "/Game/AI/Humans/Meshes/SK_Bandit_A.SK_Bandit_A"] })
    local hair = comp({ "StaticMeshComponent" }, "HairMesh_" .. next_addr, {
        StaticMesh = W.paths["/Game/AI/Humans/Meshes/SM_Hair_1.SM_Hair_1"], _mat = W.paths[look.hairmat or ""],
        RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
        RelativeScale3D = { X = 1, Y = 1, Z = 1 } })
    local pack = comp({ "StaticMeshComponent" }, "BackpackMesh_" .. next_addr, {
        StaticMesh = W.paths[look.pack or ""], RelativeLocation = look.packloc or { X = 0, Y = 0, Z = 0 },
        RelativeRotation = { Pitch = 0, Yaw = look.packyaw or 0, Roll = 0 }, RelativeScale3D = { X = 1, Y = 1, Z = 1 } })
    local ai = new({ "BP_SmartAIComponent_C" }, "BP_AIComponent_" .. next_addr, { MaxHealth = look.max or 150,
        Health = look.hp or 150, Dead = false })
    local b = new({ "BP_Bandit_Ranged_Boss_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" },
        "BP_Bandit_Ranged_Boss_C_" .. (2147480000 + next_addr), { _loc = loc, Mesh = mesh, HairMesh = hair,
        BackpackMesh = pack, BP_AIComponent = ai, Role = role, ["Is Burning?"] = false }, {
            SetBurning = function(self, on, dmg, actor) self._p["Is Burning?"] = on; record("SetBurning")(self, on, dmg, actor) end,
            StopBurning = function(self) self._p["Is Burning?"] = false; record("StopBurning")(self) end,
            Event_BloodSplatter = record("Event_BloodSplatter"),
        })
    return b
end

local function make_boss(loc, role)
    local montage = asset("AnimMontage", "/Game/Animations/Zombie/ZombieBoss/Anim_Zombie_attack1_Montage.Anim_Zombie_attack1_Montage")
    local pos = { v = 0.0 }
    local anim = new({ "AnimBP_ZombieBoss_C" }, "AnimBP_" .. next_addr, {}, {
        Montage_GetPosition = function() return pos.v end })
    local mesh = new({ "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr, { VisibilityBasedAnimTickOption = 3 },
        { GetAnimInstance = function() return anim end })
    local dc = new({ "DamageComponent_C" }, "DamageComponent_" .. next_addr, {}, {
        Event_BloodSplatterFX = record("Event_BloodSplatterFX") })
    local boss = new({ "BP_ZombieBoss_Survivor_Small_C", "BP_ZombieBoss_C" }, "BP_ZombieBoss_Survivor_Small_C_" .. next_addr,
        { _loc = loc, Mesh = mesh, DamageComponent = dc, ["IsDead?"] = false, Role = role, ["Is Burning?"] = false }, {
            GetCurrentMontage = function() return montage end,
            SetBurning = function(self, on) self._p["Is Burning?"] = on; record("SetBurning")(self, on) end,
            StopBurning = function(self) self._p["Is Burning?"] = false; record("StopBurning")(self) end,
        })
    dc._p._owner = boss
    return boss, pos
end

local function msgs(kind)
    local out = {}
    for i, e in ipairs(W.out) do
        if e.msg and e.msg:find("^SDC1|" .. kind .. "|") then
            out[#out + 1] = { i = i, msg = e.msg, pc = e.pc, obj = W.out[i + 1] and W.out[i + 1].obj }
        end
    end
    return out
end

local function fresh_modules()
    for _, m in ipairs({ "sdc_npc", "sdc_net", "sdc_ue", "sdc_config", "sdc_log" }) do package.loaded[m] = nil end
    local cfg = require("sdc_config")
    cfg.values = {}
    return require("sdc_npc"), require("sdc_net")
end


local CIVILIAN = "/Game/AI/SafeZoneAndCivilians/RandomCivilian/BP_RandomCivilian.BP_RandomCivilian_C"
local DOG = "/Game/AI/Animals/Dog/BP_AnimalDog.BP_AnimalDog_C"
local ZOMBIE = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local WOLF = "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C"

local function new_world(is_server)
    W = { objects = {}, paths = {}, hooks = {}, out = {}, loads = 0, lazy = {}, timers_cleared = {} }
    W.paths["/Script/Engine.Default__KismetSystemLibrary"] = new({ "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end, IsServer = function() return is_server end,
        K2_ClearTimer = function(_, o, fn) W.timers_cleared[#W.timers_cleared + 1] = { o = o, fn = fn } end,
    })
    W.paths["/Script/Engine.Default__GameplayStatics"] = new({ "GameplayStatics" }, "GPS", {}, {
        GetAllActorsOfClass = function(_, wc, cls, out)
            for _, o in ipairs(W.objects) do
                if o._valid and derives(o, cls._isa) then out[#out + 1] = param(o) end
            end
        end,
    })
    class_asset(BOSS, "BP_ZombieBoss_C")
    class_asset(HUMAN, "BP_MasterAICharacter_C")
    class_asset(CIVILIAN, "BP_RandomCivilian_C")
    class_asset(DOG, "BP_AnimalDog_C")
    asset("SkeletalMesh", "/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_A.SK_Civ_A")
    asset("SkeletalMesh", "/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_B.SK_Civ_B")
    asset("StaticMesh", "/Game/AI/Humans/Meshes/SM_Hair_1.SM_Hair_1")
    asset("StaticMesh", "/Game/AI/Humans/Meshes/SM_Beard_2.SM_Beard_2")
    asset("StaticMesh", "/Game/AI/Humans/Meshes/SM_Pack_1.SM_Pack_1")
    asset("MaterialInstanceConstant", "/Game/Polygon/Mat_04_C_Inst.Mat_04_C_Inst")
    asset("SkeletalMesh", "/Game/AI/Animals/Dog/SK_Dog_Husky.SK_Dog_Husky")
    asset("MaterialInstanceConstant", "/Game/AI/Animals/Dog/MI_Dog_Black.MI_Dog_Black")
    asset("MaterialInstanceConstant", "/Game/AI/Animals/Dog/MI_Dog_White.MI_Dog_White")
end

-- a civilian: body, hair, beard, backpack, a name plate (NameWidget -> BP_InteractWidgetCivilian.Txt)
local function make_civilian(loc, role, body, name)
    local mesh = comp({ "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr,
        { SkeletalMeshAsset = W.paths[body] })
    local hair = comp({ "StaticMeshComponent" }, "HairMesh_" .. next_addr, {
        StaticMesh = W.paths["/Game/AI/Humans/Meshes/SM_Hair_1.SM_Hair_1"], _mat = W.paths["/Game/Polygon/Mat_04_C_Inst.Mat_04_C_Inst"],
        RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
        RelativeScale3D = { X = 1, Y = 1, Z = 1 } })
    local beard = comp({ "StaticMeshComponent" }, "BeardMesh_" .. next_addr, {
        StaticMesh = role == 3 and W.paths["/Game/AI/Humans/Meshes/SM_Beard_2.SM_Beard_2"] or nil,
        RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
        RelativeScale3D = { X = 1, Y = 1, Z = 1 } })
    local text = { v = name }
    local txt = new({ "TextBlock" }, "Txt_" .. next_addr, {}, {
        GetText = function() return name_obj(text.v) end,
        SetText = function(self, t) text.v = t._s; record("SetText")(self, t._s) end,
    })
    local widget = new({ "BP_InteractWidgetCivilian_C" }, "BP_InteractWidgetCivilian_C_" .. next_addr, { Txt = txt })
    local nw = new({ "WidgetComponent" }, "NameWidget_" .. next_addr, {}, { GetUserWidgetObject = function() return widget end })
    local c = new({ "BP_RandomCivilian_Male_C", "BP_RandomCivilian_C", "BP_MainFriendly_C" },
        "BP_RandomCivilian_Male_C_" .. (2147470000 + next_addr), { _loc = loc, Mesh = mesh, HairMesh = hair,
        BeardMesh = beard, NameWidget = nw, Role = role })
    return c, text, txt
end

local function make_dog(loc, role, model, mat)
    local mesh = comp({ "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr,
        { SkeletalMeshAsset = W.paths[model], _mat = W.paths[mat] })
    return new({ "BP_AnimalDog_C", "BP_Animal_C" }, "BP_AnimalDog_C_" .. (2147460000 + next_addr),
        { _loc = loc, Mesh = mesh, Role = role })
end

-- ============================================================== host
io.write("== host: civilians and the dog\n")
new_world(true)
local npc, net = fresh_modules()
local host_pc = make_pc(true, { X = 0, Y = 0, Z = 0 })
local rpc, rpawn = make_pc(false, { X = 100000, Y = 0, Z = 0 })
local S = { role = "host", remote_pcs = { rpc } }
npc.install(S)
npc.tick()
local civ = make_civilian({ X = 101000, Y = 0, Z = 0 }, 3, "/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_A.SK_Civ_A", "John Smith")
local dog = make_dog({ X = 100500, Y = 0, Z = 0 }, 3, "/Game/AI/Animals/Dog/SK_Dog_Husky.SK_Dog_Husky",
    "/Game/AI/Animals/Dog/MI_Dog_Black.MI_Dog_Black")
local far = make_civilian({ X = 300000, Y = 0, Z = 0 }, 3, "/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_A.SK_Civ_A", "Far Away")
advance(3.1); npc.tick()     -- the friendly pass meets them
check(#msgs("NPCSET") == 0, "host: nothing before they were near for 1.5 s")
advance(1.1); npc.tick()
check(#msgs("NPCSET") == 0, "host: the friendly pass runs every 3 s")
advance(2.0); npc.tick()
local sets = msgs("NPCSET")
check(#sets == 2, "host: 3 s later: NPCSET for the civilian and the dog (" .. #sets .. ")")
local by_obj = {}
for _, s in ipairs(sets) do by_obj[s.obj] = s end
local cs = by_obj[civ]
local f = {}
for part in ((cs and cs.msg or "") .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
check(cs ~= nil and f[3] == "BP_RandomCivilian_Male_C" and f[4] == "" and f[5] == "", "host: civilian NPCSET: class, no health")
check(f[6] and f[6]:find("Mesh=AI/SafeZoneAndCivilians/Meshes/SK_Civ_A.SK_Civ_A,", 1, true) == 1
    and f[6]:find("BeardMesh=AI/Humans/Meshes/SM_Beard_2.SM_Beard_2,", 1, true) ~= nil, "host: its look (body, beard)")
check(f[7] == "John Smith", "host: its name plate's text: " .. tostring(f[7]))
local civ_look = f[6]
local ds = by_obj[dog]
local g = {}
for part in ((ds and ds.msg or "") .. "|"):gmatch("([^|]*)|") do g[#g + 1] = part end
check(ds ~= nil and g[6] == "Mesh=AI/Animals/Dog/SK_Dog_Husky.SK_Dog_Husky,AI/Animals/Dog/MI_Dog_Black.MI_Dog_Black"
    and g[7] == nil, "host: the dog's model and material, no name: " .. tostring(g[6]))
local dog_look = g[6]
check(by_obj[far] == nil, "host: a civilian 2 km from the client: nothing")
advance(3.1); npc.tick()
check(#msgs("NPCSET") == 2, "host: not again within 30 s")
civ._valid = false
advance(3.1); npc.tick()
civ._valid = true
advance(3.1); npc.tick()
check(#msgs("NPCSET") == 2, "host: a civilian gone and back: counted from the start again (waits 1.5 s)")
advance(3.1); npc.tick()
check(#msgs("NPCSET") == 3, "host: ... then sent again")
-- npc_looks off: no friendly pass
require("sdc_config").values.npc_looks = false
for _ = 1, 12 do advance(3.1); npc.tick() end
check(#msgs("NPCSET") == 3, "host: npc_looks off: civilians and dogs not sent")
require("sdc_config").values.npc_looks = nil

-- ============================================================== client
io.write("== client: civilians, dog, markers, slow apply\n")
new_world(false)
npc, net = fresh_modules()
local cpc, cpawn = make_pc(true, { X = 100000, Y = 0, Z = 0 })
local los = { [true] = true }
local sight = true
cpc._m.LineOfSightTo = function(_, a) return sight end
S = { role = "client", remote_pcs = {} }
npc.install(S)
npc.tick()
local function deliver(msg, obj)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, cpc)
    if obj ~= false then fire(OBJREF, param(cpc), param(obj)) end
end
local ccopy, ctext, ctxt = make_civilian({ X = 101000, Y = 0, Z = 0 }, 1, "/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_B.SK_Civ_B", "Bob Brown")
deliver("SDC1|NPCSET|BP_RandomCivilian_Male_C|||" .. civ_look .. "|John Smith", ccopy)
check(ccopy._p.Mesh._p.SkeletalMeshAsset == W.paths["/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_A.SK_Civ_A"], "client: civilian body as on the host")
check(ccopy._p.BeardMesh._p.StaticMesh == W.paths["/Game/AI/Humans/Meshes/SM_Beard_2.SM_Beard_2"], "client: civilian beard as on the host")
check(ctext.v == "John Smith", "client: name plate 'John Smith' (its own roll was 'Bob Brown')")
local n_set = 0
for _, c in ipairs(ctxt._calls) do if c[1] == "SetText" then n_set = n_set + 1 end end
deliver("SDC1|NPCSET|BP_RandomCivilian_Male_C|||" .. civ_look .. "|John Smith", ccopy)
local n_set2 = 0
for _, c in ipairs(ctxt._calls) do if c[1] == "SetText" then n_set2 = n_set2 + 1 end end
check(n_set == 1 and n_set2 == 1, "client: the same name not set again")
local dcopy = make_dog({ X = 100500, Y = 0, Z = 0 }, 1, "/Game/AI/Animals/Dog/SK_Dog_Husky.SK_Dog_Husky",
    "/Game/AI/Animals/Dog/MI_Dog_White.MI_Dog_White")
deliver("SDC1|NPCSET|BP_AnimalDog_C|||" .. dog_look, dcopy)
check(dcopy._p.Mesh._p._mat == W.paths["/Game/AI/Animals/Dog/MI_Dog_Black.MI_Dog_Black"], "client: the dog's material as on the host")

-- a slow apply is named in the log
local slow = make_civilian({ X = 101000, Y = 0, Z = 0 }, 1, "/Game/AI/SafeZoneAndCivilians/Meshes/SK_Civ_B.SK_Civ_B", "Slow One")
slow._p.Mesh._m.SetSkinnedAssetAndUpdate = function(self, a) advance(0.04); self._p.SkeletalMeshAsset = a end
local LOGS = {}
print = function(s) LOGS[#LOGS + 1] = tostring(s) end
deliver("SDC1|NPCSET|BP_RandomCivilian_Male_C|||" .. civ_look .. "|John Smith", slow)
local slow_line
for _, l in ipairs(LOGS) do if l:find("[SLOW] set on", 1, true) then slow_line = l end end
check(slow_line ~= nil and slow_line:find("took 40 ms", 1, true) ~= nil, "client: a 40 ms apply: [SLOW] line: " .. tostring(slow_line))
LOGS = {}
deliver("SDC1|NPCSET|BP_RandomCivilian_Male_C|||" .. civ_look .. "|John Smith", ccopy)
slow_line = nil
for _, l in ipairs(LOGS) do if l:find("[SLOW]", 1, true) then slow_line = l end end
check(slow_line == nil, "client: a fast apply: no [SLOW] line")

-- the enemy marker
local BANDIT_M = BANDIT .. ":Event_Marker"
check(W.hooks[BANDIT_M] ~= nil and W.hooks[ZOMBIE .. ":Event_Marker"] ~= nil and W.hooks[WOLF .. ":Event_Marker"] ~= nil
    and W.hooks[BOSS .. ":Event_Marker"] ~= nil, "client: Event_Marker hooked on zombies, bosses, people, animals")
local function marked(chain, name, role, can_add)
    local m = new({ "WidgetComponent" }, "NODE_AddWidgetComponent-0_" .. next_addr, {}, {
        K2_DestroyComponent = function(self, owner) self._destroyed_by = owner; self._valid = false end })
    local props = { Role = role, Marker = m, MarkerTimer = { Handle = 7 }, _loc = { X = 101000, Y = 0, Z = 0 } }
    if can_add ~= nil then props["CanAddMarker?"] = can_add end
    return new(chain, name, props), m
end
local b, bm = marked({ "BP_Bandit_Melee_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" }, "BP_Bandit_Melee_C_2147480001", 1, false)
local function timer(path, a) fire(path, param(a)) end
sight = true
timer(BANDIT_M, b)
advance(30); sight = false
timer(BANDIT_M, b)
check(bm._valid, "client: out of sight for 30 s: the marker stays")
advance(29)
timer(BANDIT_M, b)
check(bm._valid, "client: 59 s: stays")
advance(2)
timer(BANDIT_M, b)
check(not bm._valid and bm._destroyed_by == b, "client: 61 s after the last sight: the marker component destroyed (owner passed)")
check(b._p["CanAddMarker?"] == true, "client: CanAddMarker? true again")
local cl = W.timers_cleared[#W.timers_cleared]
check(cl and cl.o == b and cl.fn == "Event_Marker", "client: the Event_Marker timer cleared")
check(b._p.MarkerTimer and b._p.MarkerTimer.Handle == 0, "client: the timer handle invalidated (a zombie's CanAddMarkerToAI?)")
-- seen again within the 60 s: the clock restarts
local b2, bm2 = marked({ "BP_Bandit_Melee_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" }, "BP_Bandit_Melee_C_2147480002", 1, false)
sight = true; timer(BANDIT_M, b2)
advance(50); sight = false; timer(BANDIT_M, b2)
advance(5); sight = true; timer(BANDIT_M, b2)
advance(50); sight = false; timer(BANDIT_M, b2)
check(bm2._valid, "client: seen again at 55 s: 50 s later it still stays")
advance(11); timer(BANDIT_M, b2)
check(not bm2._valid, "client: 61 s after that last sight: removed")
-- a zombie (no CanAddMarker? property): removed, no flag written
local z, zm = marked({ "BP_Zombie_Roamer_C", "BP_MasterZombie_C" }, "BP_Zombie_Roamer_C_2147480003", 1, nil)
sight = true; timer(ZOMBIE .. ":Event_Marker", z)
advance(61); sight = false; timer(ZOMBIE .. ":Event_Marker", z)
check(not zm._valid and z._p["CanAddMarker?"] == nil and z._p.MarkerTimer.Handle == 0, "client: zombie: removed, handle invalidated, no flag written")
-- never seen (as the host: the delay never starts): stays
local n, nm = marked({ "BP_AnimalWolf_C", "BP_Animal_C" }, "BP_AnimalWolf_C_2147480004", 1, false)
sight = false
for _ = 1, 5 do timer(WOLF .. ":Event_Marker", n); advance(30) end
check(nm._valid, "client: never in sight since marked: stays (the game's rule)")
-- this machine's own AI: not touched
local own, om = marked({ "BP_Bandit_Melee_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" }, "BP_Bandit_Melee_C_2147480005", 3, false)
sight = true; timer(BANDIT_M, own); advance(61); sight = false; timer(BANDIT_M, own)
check(om._valid, "client: an authority actor: not touched")
-- off
require("sdc_config").values.npc_marker = false
local o2, om2 = marked({ "BP_Bandit_Melee_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" }, "BP_Bandit_Melee_C_2147480006", 1, false)
sight = true; timer(BANDIT_M, o2); advance(61); sight = false; timer(BANDIT_M, o2)
check(om2._valid, "client: npc_marker off: not touched")
require("sdc_config").values.npc_marker = nil
check(npc.status_line():find("markers seen=", 1, true) ~= nil, "status line")
io.write("  " .. npc.status_line() .. "\n")

io.write(fails == 0 and "ALL OK\n" or (fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
