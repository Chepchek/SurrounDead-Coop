-- Group F fixes (critic 2026-11-13, AI core), against the real sdc_npc / sdc_ai /
-- sdc_ai_* / sdc_ue / sdc_net / sdc_config / sdc_log / sdc_ctx on fake UE objects:
--   A1  a client applies an NPC look from assets in memory only (no LoadAsset in
--       the ClientRepObjRef hook); a missing one waits for the next NPCSET
--   A2  the host gives human NPCs their own pose ticking back when the last
--       client leaves
--   B1  sdc_ai_attacks' CreateProxyObjectForPlayMontage hook is a pre-only
--       sdc_ue.hook_native subscriber (no post callback)
--   B2  sdc_npc's hooks on functions sdc_ai hooks too (boss MeleeAttack /
--       DeathEvent, the humans' StopBurning) are ONE engine hook, installed by
--       sdc_ai also while every AI feature is off
--   B5  ai_kill_log's host hooks are not installed while nobody is connected
-- usage: lua mock_fix_f_npc.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   " .. what .. "\n") else io.write("  FAIL " .. what .. "\n"); fails = fails + 1 end
end
local LOG = {}
print = function(s) LOG[#LOG + 1] = tostring(s); if os.getenv("MOCK_VERBOSE") then io.write(tostring(s)) end end
local function say(s) io.write(s .. "\n") end

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
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:GetOwner() return self._p._owner end
function Obj:IsA(cls)
    for _, c in ipairs(self._chain) do if c == cls._isa then return true end end
    return false
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
local ZOMBIE = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local HUMAN = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C"
local BANDIT = "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C"
local DMG = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C"
local PROXY = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"
local MONTAGE = "/Game/Animations/Zombie/ZombieBoss/Anim_Zombie_attack1_Montage.Anim_Zombie_attack1_Montage"

local function new_world(is_server)
    W = { objects = {}, paths = {}, hooks = {}, out = {}, loads = 0, lazy = {} }
    W.paths["/Script/Engine.Default__KismetSystemLibrary"] = new({ "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end, IsServer = function() return is_server end })
    W.paths["/Script/Engine.Default__GameplayStatics"] = new({ "GameplayStatics" }, "GPS", {}, {})
    class_asset(BOSS, "BP_ZombieBoss_C")
    class_asset(ZOMBIE, "BP_MasterZombie_C")
    class_asset(HUMAN, "BP_MasterAICharacter_C")
    class_asset(BANDIT, "BP_MasterBandit_C")
    asset("AnimMontage", MONTAGE)
    asset("SkeletalMesh", "/Game/AI/Humans/Meshes/SK_Bandit_A.SK_Bandit_A")
    asset("SkeletalMesh", "/Game/AI/Humans/Meshes/SK_Bandit_B.SK_Bandit_B")
    asset("StaticMesh", "/Game/AI/Humans/Meshes/SM_Hair_1.SM_Hair_1")
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

local function comp(chain, name, props)
    return new(chain, name, props, {
        GetMaterial = function(self) return self._p._mat end,
        SetMaterial = function(self, _, m) self._p._mat = m; record("SetMaterial")(self, m) end,
        SetStaticMesh = function(self, m) self._p.StaticMesh = m; record("SetStaticMesh")(self, m) end,
        SetSkinnedAssetAndUpdate = function(self, a) self._p.SkeletalMeshAsset = a; record("SetSkinnedAssetAndUpdate")(self, a) end,
        K2_SetRelativeLocationAndRotation = function(self, l, r) self._p.RelativeLocation, self._p.RelativeRotation = l, r end,
        SetRelativeScale3D = function(self, s) self._p.RelativeScale3D = s end,
    })
end

local function make_bandit(loc, role, body)
    local mesh = comp({ "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr,
        { VisibilityBasedAnimTickOption = 3, SkeletalMeshAsset = W.paths[body or "/Game/AI/Humans/Meshes/SK_Bandit_A.SK_Bandit_A"] })
    local hair = comp({ "StaticMeshComponent" }, "HairMesh_" .. next_addr, {
        StaticMesh = W.paths["/Game/AI/Humans/Meshes/SM_Hair_1.SM_Hair_1"],
        RelativeLocation = { X = 0, Y = 0, Z = 0 }, RelativeRotation = { Pitch = 0, Yaw = 0, Roll = 0 },
        RelativeScale3D = { X = 1, Y = 1, Z = 1 } })
    local ai = new({ "BP_SmartAIComponent_C" }, "BP_AIComponent_" .. next_addr, { MaxHealth = 150, Health = 150, Dead = false })
    return new({ "BP_Bandit_Ranged_Boss_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C" },
        "BP_Bandit_Ranged_Boss_C_" .. (2147480000 + next_addr), { _loc = loc, Mesh = mesh, HairMesh = hair,
        BP_AIComponent = ai, Role = role, ["Is Burning?"] = false }, {
            SetBurning = record("SetBurning"), StopBurning = record("StopBurning") })
end

local function make_boss(loc, role)
    local anim = new({ "AnimBP_ZombieBoss_C" }, "AnimBP_" .. next_addr, {}, {
        Montage_GetPosition = function() return 0.0 end })
    local mesh = new({ "SkeletalMeshComponent" }, "CharacterMesh0_" .. next_addr, { VisibilityBasedAnimTickOption = 3 },
        { GetAnimInstance = function() return anim end })
    local boss = new({ "BP_ZombieBoss_Survivor_Small_C", "BP_ZombieBoss_C" }, "BP_ZombieBoss_Survivor_Small_C_" .. next_addr,
        { _loc = loc, Mesh = mesh, ["IsDead?"] = false, Role = role },
        { GetCurrentMontage = function() return W.paths[MONTAGE] end })
    mesh._p._owner = boss
    return boss
end

local function msgs(kind)
    local out = {}
    for i, e in ipairs(W.out) do
        if e.msg and e.msg:find("^SDC1|" .. kind .. "|") then out[#out + 1] = { msg = e.msg, pc = e.pc, obj = W.out[i + 1] and W.out[i + 1].obj } end
    end
    return out
end

local function fresh_modules(values)
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local cfg = require("sdc_config")
    cfg.values = values or {}
    return require("sdc_npc"), require("sdc_ai"), require("sdc_net"), require("sdc_ue")
end

local AI_OFF = { ai_kill_credit = false, ai_attack_montages = false, ai_corpses = false, ai_healthbar = false,
                 ai_zombie_looks = false, ai_offscreen_combat = false, ai_kill_log = false, ai_client_ghosts = false,
                 ai_zombie_fx = false }

-- ============================================================== host: B1, B2, B5, A2
say("== host: attacks + kill log on, the rest of sdc_ai off")
new_world(true)
local v = {}
for k, x in pairs(AI_OFF) do v[k] = x end
v.ai_attack_montages, v.ai_kill_log = true, true
local npc, ai, _, ue = fresh_modules(v)
local host_pc = make_pc(true, { X = 0, Y = 0, Z = 0 })
local rpc = make_pc(false, { X = 100000, Y = 0, Z = 0 })
local S = { role = "host", remote_pcs = {} }
ai.init(S)
npc.install(S)
npc.tick(); ai.host_tick({})
advance(1); npc.tick(); ai.host_tick({})
check(W.hooks[BOSS .. ":MeleeAttack"] == nil and W.hooks[BOSS .. ":DeathEvent"] == nil,
    "nobody connected: no boss hook (sdc_npc's needs a client, sdc_ai_killlog's no longer installs alone)")
check(W.hooks[DMG .. ":DamageTaken"] == nil and W.hooks[ZOMBIE .. ":Death"] == nil,
    "B5: nobody connected: no kill-log DamageTaken / Death hook")

S.remote_pcs = { rpc }
advance(1); npc.tick()
check(W.hooks[BOSS .. ":MeleeAttack"] ~= nil and #W.hooks[BOSS .. ":MeleeAttack"] == 1, "B2: a client: boss MeleeAttack hooked once (by sdc_ai, for sdc_npc)")
advance(1); ai.host_tick({ rpc }); npc.tick()
check(#W.hooks[BOSS .. ":MeleeAttack"] == 1, "B2: sdc_ai_attacks on the same function: still one RegisterHook")
check(W.hooks[BOSS .. ":DeathEvent"] ~= nil and #W.hooks[BOSS .. ":DeathEvent"] == 1, "B2: boss DeathEvent: one RegisterHook (sdc_npc + kill log)")
check(W.hooks[BANDIT .. ":StopBurning"] ~= nil and #W.hooks[BANDIT .. ":StopBurning"] == 1, "B2: bandit StopBurning: one RegisterHook")
check(W.hooks[DMG .. ":DamageTaken"] ~= nil, "B5: a client connected: the kill log's DamageTaken hook is in")
check(npc.status_line():find("+6 shared with sdc_ai", 1, true) ~= nil, "status: 6 hooks shared with sdc_ai")

-- B1: the proxy factory: one pre-only engine hook (sdc_ue.hook_native), no post callback
local ph = W.hooks[PROXY]
check(ph ~= nil and #ph == 1 and ph[1].post == nil, "B1: CreateProxyObjectForPlayMontage: one engine hook, no post callback")
check(ue.natives[PROXY] ~= nil and ue.natives[PROXY].subs[1].key:find("^ai%.") ~= nil, "B1: sdc_ai_attacks is a subscriber of sdc_ue.hook_native")

-- both callbacks of the shared MeleeAttack hook run
local boss = make_boss({ X = 100300, Y = 0, Z = 0 }, 3)
W.out = {}
fire(BOSS .. ":MeleeAttack", param(boss))
check(boss._p.Mesh._p.VisibilityBasedAnimTickOption == 0, "B2: sdc_npc's MeleeAttack callback ran (boss ticks unseen)")
check(#msgs("AIM") == 1 and msgs("AIM")[1].obj == boss, "B2: sdc_ai_attacks' MeleeAttack callback ran (AIM + objref)")
check(#msgs("SND") == 1, "B2: sdc_npc's growl sent")

-- B1 in the pre-hook: params without the return value
W.out = {}
advance(1)
fire(PROXY, param(nil), param(boss._p.Mesh), param(W.paths[MONTAGE]), param(1.0))
check(#msgs("AIM") == 1 and msgs("AIM")[1].msg:find("|o|", 1, true) ~= nil, "B1: a proxy montage of the boss forwarded from the pre-hook")

-- A2: a bandit near the client ticks unseen; the client leaves -> its own value back at once
local bandit = make_bandit({ X = 101000, Y = 0, Z = 0 }, 3)
advance(1.1); npc.tick()
check(bandit._p.Mesh._p.VisibilityBasedAnimTickOption == 0, "A2: a bandit near the client ticks unseen on the host")
S.remote_pcs = {}
advance(0.3); npc.tick()
check(bandit._p.Mesh._p.VisibilityBasedAnimTickOption == 3, "A2: the last client left: the bandit's own tick option is back")
local back_line = false
for _, l in ipairs(LOG) do if l:find("back to their own pose ticking (no client connected)", 1, true) then back_line = true end end
check(back_line, "A2: logged")

-- B5: hooks in, the client gone: the kill log stays quiet
local n_kill = 0
for _, l in ipairs(LOG) do if l:find("ai: kill [host]", 1, true) then n_kill = n_kill + 1 end end
ai.host_tick({})
fire(BOSS .. ":DeathEvent", param(make_boss({ X = 0, Y = 0, Z = 0 }, 3)), param(nil))
local n_kill2 = 0
for _, l in ipairs(LOG) do if l:find("ai: kill [host]", 1, true) then n_kill2 = n_kill2 + 1 end end
check(n_kill2 == n_kill, "B5: nobody connected any more: no kill line")

say("== host: every AI feature off")
new_world(true)
npc, ai, _, ue = fresh_modules(AI_OFF)
host_pc = make_pc(true, { X = 0, Y = 0, Z = 0 })
rpc = make_pc(false, { X = 100000, Y = 0, Z = 0 })
S = { role = "host", remote_pcs = { rpc } }
npc.install(S)            -- sdc_ai is never initialised nor ticked (sdc_session: no AI feature on)
npc.tick()
check(W.hooks[BOSS .. ":MeleeAttack"] ~= nil and #W.hooks[BOSS .. ":MeleeAttack"] == 1, "B2: sdc_npc's shared hooks installed without the AI ticks")
local boss2 = make_boss({ X = 100300, Y = 0, Z = 0 }, 3)
W.out = {}
fire(BOSS .. ":MeleeAttack", param(boss2))
check(boss2._p.Mesh._p.VisibilityBasedAnimTickOption == 0 and #msgs("SND") == 1, "B2: sdc_npc's callback runs (AI features off)")
check(#msgs("AIM") == 0, "AI attacks off: no AIM")
S.role = "client"
advance(1)
fire(BOSS .. ":MeleeAttack", param(make_boss({ X = 100300, Y = 0, Z = 0 }, 1)))
check(#msgs("SND") == 1, "the gate: not on a client")

-- ============================================================== client: A1
say("== client: NPC looks from memory only")
new_world(false)
npc = fresh_modules({})
local net = require("sdc_net")
local cpc = make_pc(true, { X = 100000, Y = 0, Z = 0 })
S = { role = "client", remote_pcs = {} }
npc.install(S)
npc.tick()
local copy = make_bandit({ X = 101000, Y = 0, Z = 0 }, 1, "/Game/AI/Humans/Meshes/SK_Bandit_B.SK_Bandit_B")
local OBJREF = "/Script/Engine.PlayerController:ClientRepObjRef"
local function deliver(msg, obj)
    local kind, fields = net.decode(msg)
    net.handlers[kind](fields, cpc)
    fire(OBJREF, param(cpc), param(obj))
end
-- the host's look: a body mesh this client has not loaded (LoadAsset would find it)
local NEW_BODY = "/Game/AI/Humans/Meshes/SK_Bandit_C.SK_Bandit_C"
W.lazy[NEW_BODY] = "SkeletalMesh"
local look = "Mesh=AI/Humans/Meshes/SK_Bandit_C.SK_Bandit_C,"
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|237|200|" .. look, copy)
check(W.loads == 0, "A1: no LoadAsset in the ClientRepObjRef hook")
check(copy._p.BP_AIComponent._p.MaxHealth == 237, "A1: health applied anyway")
check(copy._p.Mesh._p.SkeletalMeshAsset == W.paths["/Game/AI/Humans/Meshes/SK_Bandit_B.SK_Bandit_B"], "A1: body kept until its asset is in memory")
check(npc.stats.look_later == 1 and npc.stats.look_failed == 0, "A1: counted as waiting, not as failed")
-- the asset comes into memory (another NPC, the game's streaming): the host's next NPCSET applies it
asset("SkeletalMesh", NEW_BODY)
advance(30)
deliver("SDC1|NPCSET|BP_Bandit_Ranged_Boss_C|237|190|" .. look, copy)
check(copy._p.Mesh._p.SkeletalMeshAsset == W.paths[NEW_BODY], "A1: the next NPCSET applies the body (not marked bad)")
check(W.loads == 0 and npc.stats.looks == 1, "A1: look complete, still no load")
check(npc.status_line():find("not in memory=1", 1, true) ~= nil, "A1: status line counts it")

io.write(string.format("mock_fix_f_npc: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
