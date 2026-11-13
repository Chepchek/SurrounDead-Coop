-- Mock harness for sdc_npc: the real sdc_npc / sdc_ue / sdc_net / sdc_config /
-- sdc_log against fake UE objects. Phase 1 = host, phase 2 = client (fresh
-- module loads). usage: lua mock_npc.lua <scripts dir>
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

local function new_world(is_server)
    W = { objects = {}, paths = {}, hooks = {}, out = {}, loads = 0, lazy = {} }
    W.paths["/Script/Engine.Default__KismetSystemLibrary"] = new({ "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end, IsServer = function() return is_server end })
    W.spawned = {}
    W.paths["/Script/Engine.Default__GameplayStatics"] = new({ "GameplayStatics" }, "GPS", {}, {
        BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf)
            local r = new({ "BP_ZombieBossRock_C" }, "BP_ZombieBossRock_C_" .. next_addr, { _loc = tf.Translation },
                { SetLifeSpan = record("SetLifeSpan"), Launch = record("Launch"), K2_DestroyActor = record("Destroy") })
            W.spawned[#W.spawned + 1] = r
            return r
        end,
        FinishSpawningActor = function(_, a) return a end,
    })
    class_asset(BOSS, "BP_ZombieBoss_C")
    class_asset(HUMAN, "BP_MasterAICharacter_C")
    class_asset(ROCK, "BP_ZombieBossRock_C")
    asset("SkeletalMesh", "/Game/AI/Humans/Meshes/SK_Bandit_A.SK_Bandit_A")
    asset("SkeletalMesh", "/Game/AI/Humans/Meshes/SK_Bandit_B.SK_Bandit_B")
    asset("StaticMesh", "/Game/AI/Humans/Meshes/SM_Hair_1.SM_Hair_1")
    asset("StaticMesh", "/Game/AI/Humans/Meshes/SM_Pack_1.SM_Pack_1")
    asset("MaterialInstanceConstant", "/Game/Polygon/Mat_04_C_Inst.Mat_04_C_Inst")
end

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

-- ============================================================== host
quiet_print("== host")
new_world(true)
local npc, net = fresh_modules()
local host_pc = make_pc(true, { X = 0, Y = 0, Z = 0 })
local rpc, rpawn = make_pc(false, { X = 100000, Y = 0, Z = 0 })   -- the client, 1 km from the host
local S = { role = "host", remote_pcs = { rpc } }
npc.install(S)
npc.tick()
check(W.hooks[BOSS .. ":MeleeAttack"] ~= nil, "host: boss MeleeAttack hook installed")
check(W.hooks[ROCK .. ":Launch"] ~= nil, "host: rock Launch hook installed")
check(W.hooks[BANDIT .. ":SetBurning"] ~= nil, "host: bandit SetBurning hook installed")
check(W.hooks[OBJREF] == nil, "host: no ClientRepObjRef hook on the host")

local boss, bpos = make_boss({ X = 100300, Y = 0, Z = 0 }, 3)
local bandit = make_bandit({ X = 101000, Y = 0, Z = 0 }, 3, { hairmat = "/Game/Polygon/Mat_04_C_Inst.Mat_04_C_Inst",
    pack = "/Game/AI/Humans/Meshes/SM_Pack_1.SM_Pack_1", packloc = { X = 1, Y = -12.5, Z = 30 }, packyaw = 90, max = 237, hp = 200 })
advance(1.1); npc.tick()   -- first pass: viewers, bandit seen near the client

-- boss attacks, host far away
fire(BOSS .. ":MeleeAttack", param(boss))
check(boss._p.Mesh._p.VisibilityBasedAnimTickOption == 0, "host: attacking boss now ticks unseen (AlwaysTickPoseAndRefreshBones)")
local snd = msgs("SND")
check(#snd == 1 and snd[1].msg:find("ZombieGrowlShort", 1, true) ~= nil and snd[1].pc == rpc, "host: attack growl sent as SND")
fire(BOSS .. ":MeleeAttack", param(boss))
check(#msgs("SND") == 1, "host: no second growl within 1.2 s")
advance(1.3); bpos.v = 0.9
fire(BOSS .. ":MeleeAttack", param(boss))
check(#msgs("SND") == 1, "host: no growl for a running attack (montage at 0.9 s)")

-- rock
fire(ROCK .. ":Launch", param(new({ "BP_ZombieBossRock_C" }, "rock")), param({ X = 100300, Y = 0, Z = 100 }),
    param({ X = 100000, Y = 0, Z = 0 }))
local rocks = msgs("NPCROCK")
check(#rocks == 1 and rocks[1].msg == "SDC1|NPCROCK|100300|0|100|100000|0|0", "host: NPCROCK with origin and target")
check(#msgs("SND") == 2, "host: throw growl sent")

-- burning
fire(BANDIT .. ":SetBurning", param(bandit), param(true), param(12.0), param(nil))
local fires = msgs("NPCFIRE")
check(#fires == 1 and fires[1].msg == "SDC1|NPCFIRE|BP_Bandit_Ranged_Boss_C|1" and fires[1].obj == bandit, "host: NPCFIRE 1 + objref")
fire(BANDIT .. ":StopBurning", param(bandit))
fires = msgs("NPCFIRE")
check(#fires == 2 and fires[2].msg:find("|0$") ~= nil, "host: NPCFIRE 0 on StopBurning")
fire(BANDIT .. ":StopBurning", param(bandit))
check(#msgs("NPCFIRE") == 2, "host: StopBurning of a fire never sent (Death's call) sends nothing")

-- blood
fire(HUMAN .. ":Event_BloodSplatter", param(bandit))
fire(HUMAN .. ":Event_BloodSplatter", param(bandit))
check(#msgs("NPCBLOOD") == 1, "host: NPCBLOOD for a hit bandit, rate-limited")
-- the boss's own StandardDamage bound event (0.7.3; before: DamageComponent.Event_BloodSplatterFX,
-- which runs on every hit of every zombie too)
fire(BOSS .. ":" .. BOSS_HIT, param(boss), param(25.0), param(rpawn))
check(#msgs("NPCBLOOD") == 2 and msgs("NPCBLOOD")[2].obj == boss, "host: NPCBLOOD for a hit boss (its own hit event)")
check(W.hooks[DMG .. ":Event_BloodSplatterFX"] == nil, "host: DamageComponent.Event_BloodSplatterFX (every zombie hit) not hooked")

-- the human pass: tick + NPCSET
check(bandit._p.Mesh._p.VisibilityBasedAnimTickOption == 0, "host: bandit 10 m from the client ticks unseen")
check(#msgs("NPCSET") == 0, "host: no NPCSET before the NPC was near for 1.5 s")
advance(1.6); npc.tick()
local sets = msgs("NPCSET")
check(#sets == 1 and sets[1].obj == bandit, "host: NPCSET + objref after 1.5 s")
local f = {}
for part in (sets[1].msg .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
check(f[3] == "BP_Bandit_Ranged_Boss_C" and f[4] == "237" and f[5] == "200", "host: NPCSET class / max / health")
check(f[6]:find("Mesh=AI/Humans/Meshes/SK_Bandit_A.SK_Bandit_A,", 1, true) == 1, "host: look starts with the body mesh")
check(f[6]:find("HairMesh=AI/Humans/Meshes/SM_Hair_1.SM_Hair_1,Polygon/Mat_04_C_Inst.Mat_04_C_Inst,", 1, true) ~= nil, "host: look has hair + material")
check(f[6]:find("BackpackMesh=AI/Humans/Meshes/SM_Pack_1.SM_Pack_1,,1.0,-12.5,30.0,0.0,90.0,0.0,1.000,1.000,1.000", 1, true) ~= nil,
    "host: look has the backpack transform")
local look = f[6]
advance(1.0); npc.tick()
check(#msgs("NPCSET") == 1, "host: not re-sent within 30 s")
advance(30.0); npc.tick()
check(#msgs("NPCSET") == 2, "host: re-sent after 30 s")
-- client goes away -> restored; comes back -> sent again after 1.5 s
rpawn._p._loc = { X = 300000, Y = 0, Z = 0 }
advance(1.0); npc.tick()
check(bandit._p.Mesh._p.VisibilityBasedAnimTickOption == 3, "host: bandit far from every client gets its own tick option back")
rpawn._p._loc = { X = 100000, Y = 0, Z = 0 }
advance(1.0); npc.tick()
check(#msgs("NPCSET") == 2, "host: back in range: waits 1.5 s")
advance(1.6); npc.tick()
check(#msgs("NPCSET") == 3, "host: back in range: sent again")

-- death roar once
fire(BOSS .. ":DeathEvent", param(boss), param(nil))
fire(BOSS .. ":DeathEvent", param(boss), param(nil))
local roars = 0
for _, m in ipairs(msgs("SND")) do if m.msg:find("ZombieDeathShort", 1, true) then roars = roars + 1 end end
check(roars == 1, "host: death roar once")
-- no client: hooks inert
S.remote_pcs = {}
npc.tick()
local n_before = #W.out
fire(BOSS .. ":DeathEvent", param(make_boss({ X = 0, Y = 0, Z = 0 }, 3)), param(nil))
check(#W.out == n_before, "host alone: nothing sent")
check(npc.status_line():find("^npc: hooks=") ~= nil, "status line")
quiet_print("  " .. npc.status_line())

-- ============================================================== client
quiet_print("== client")
new_world(false)
npc, net = fresh_modules()
local cpc = make_pc(true, { X = 100000, Y = 0, Z = 0 })
S = { role = "client", remote_pcs = {} }
npc.install(S)
npc.tick()
check(W.hooks[OBJREF] ~= nil, "client: ClientRepObjRef hook installed")
check(W.hooks[BOSS .. ":MeleeAttack"] == nil, "client: no host hooks")
local copy = make_bandit({ X = 101000, Y = 0, Z = 0 }, 1, { body = "/Game/AI/Humans/Meshes/SK_Bandit_B.SK_Bandit_B", max = 120, hp = 120 })
W.lazy["/Game/AI/Humans/Meshes/SM_Pack_1.SM_Pack_1"] = nil   -- already loaded above
local function deliver(msg, obj)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, cpc)
    if obj ~= false then fire(OBJREF, param(cpc), param(obj)) end
end
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|237|200|" .. look, copy)
local ai = copy._p.BP_AIComponent
check(ai._p.MaxHealth == 237 and ai._p.Health == 200, "client: MaxHealth / Health of the host")
check(called(copy._p.Mesh, "SetSkinnedAssetAndUpdate") ~= nil and copy._p.Mesh._p.SkeletalMeshAsset == W.paths["/Game/AI/Humans/Meshes/SK_Bandit_A.SK_Bandit_A"],
    "client: body mesh of the host")
check(copy._p.HairMesh._p._mat == W.paths["/Game/Polygon/Mat_04_C_Inst.Mat_04_C_Inst"], "client: hair material of the host")
check(copy._p.BackpackMesh._p.StaticMesh == W.paths["/Game/AI/Humans/Meshes/SM_Pack_1.SM_Pack_1"], "client: backpack mesh of the host")
local rel = copy._p.BackpackMesh._p.RelativeLocation
check(rel.Y == -12.5 and copy._p.BackpackMesh._p.RelativeRotation.Yaw == 90, "client: backpack transform of the host")
local n_calls = #copy._p.Mesh._calls
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|237|180|" .. look, copy)
check(#copy._p.Mesh._calls == n_calls and ai._p.Health == 180, "client: same look not applied twice; health updated")
-- wrong class / stale / nil
local other = make_bandit({ X = 0, Y = 0, Z = 0 }, 1)
other._chain = { "BP_Bandit_Melee_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" }
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|999|999|", other)
check(other._p.BP_AIComponent._p.MaxHealth ~= 999, "client: object of another class ignored")
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|999|999|", false)
advance(3.0)
fire(OBJREF, param(cpc), param(copy))
check(ai._p.MaxHealth == 237, "client: stale payload ignored")
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|999|999|", nil)
check(ai._p.MaxHealth == 237, "client: no copy here: nothing")
-- fire
deliver("SDC1|NPCFIRE|BP_Bandit_Ranged_Boss_C|1", copy)
local sb = called(copy, "SetBurning")
check(sb and sb[2] == true and sb[3] == 0 and sb[4] == nil, "client: SetBurning(true, 0, None) on the copy")
deliver("SDC1|NPCFIRE|BP_Bandit_Ranged_Boss_C|1", copy)
local n_sb = 0
for _, c in ipairs(copy._calls) do if c[1] == "SetBurning" then n_sb = n_sb + 1 end end
check(n_sb == 1, "client: already burning: not lit twice")
deliver("SDC1|NPCFIRE|BP_Bandit_Ranged_Boss_C|0", copy)
check(called(copy, "StopBurning") ~= nil, "client: StopBurning on the copy")
-- blood
deliver("SDC1|NPCBLOOD|BP_Bandit_Ranged_Boss_C", copy)
check(called(copy, "Event_BloodSplatter") ~= nil, "client: bandit blood splatter")
local cboss = make_boss({ X = 100300, Y = 0, Z = 0 }, 1)
deliver("SDC1|NPCBLOOD|BP_ZombieBoss_Survivor_Small_C", cboss)
check(called(cboss._p.DamageComponent, "Event_BloodSplatterFX") ~= nil, "client: boss blood splatter")
local auth = make_bandit({ X = 0, Y = 0, Z = 0 }, 3)
deliver("SDC1|NPCBLOOD|BP_Bandit_Ranged_Boss_C", auth)
check(called(auth, "Event_BloodSplatter") == nil, "client: a local-authority actor is not touched")
-- rock
deliver("SDC1|NPCROCK|100300|0|100|100000|0|0", false)
local rock = W.spawned[1]
local la = rock and called(rock, "Launch")
check(la and la[2].X == 100300 and la[3].X == 100000, "client: rock spawned and launched (origin, target)")
check(rock and called(rock, "SetLifeSpan") ~= nil, "client: rock has a life span")
deliver("SDC1|NPCROCK|nan|0|0|0|0|0", false)
check(#W.spawned == 1, "client: bad numbers ignored")
-- role change resets
S.role = "host"; npc.tick(); S.role = "client"; npc.tick()
check(npc.status_line():find("client: rocks=1", 1, true) ~= nil, "status after reset")
quiet_print("  " .. npc.status_line())

quiet_print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
