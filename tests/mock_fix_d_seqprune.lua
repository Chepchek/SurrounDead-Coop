-- Critic fix D / A3 (2026-11-13): host state keyed by a remote controller's
-- address must go when that player leaves. A client restarted at a reused
-- controller address:
--   1. sdc_throw: numbers its throws from 1 again; the host's st.seqs still
--      held its old numbers and dropped the first throws as repeats (the item
--      already used up on the client);
--   2. sdc_items: got no UIDS / ITEMS (uids_sent / items_sent said "already
--      sent") until its equipment or inventory changed.
-- Part 1 runs the real sdc_throw (+ sdc_ue / sdc_net / sdc_ctx / sdc_config /
-- sdc_log) against fake UE objects (as mock_throw.lua); part 2 sdc_items with
-- stub modules (as mock_items_perf.lua).
-- usage: lua mock_fix_d_seqprune.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ======================================================================
-- Part 1: sdc_throw
-- ======================================================================
local WORLD
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
local next_addr = 4096
local next_num = 2147400000
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, at_addr)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = at_addr or next_addr,
                             _valid = true, _full = nil, _w = w }, Obj)
    w.objects[#w.objects + 1] = o
    w.paths["/Game/Levels/PL.PL:PersistentLevel." .. name] = o
    return o
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full or (self._chain[1] .. " /Game/Levels/PL.PL:PersistentLevel." .. self._name) end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p._loc end
function Obj:K2_GetActorRotation() return self._p._rot or { Pitch = 0, Yaw = 0, Roll = 0 } end
function Obj:K2_SetActorLocation(loc) self._p._loc = { X = loc.X, Y = loc.Y, Z = loc.Z } end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return nil end
function Obj:K2_DestroyActor() self._valid = false end

local function asset(w, cls, path, methods)
    local o = new(w, { cls }, path:match("([^%.:]+)$"), {}, methods)
    o._full = cls .. " " .. path
    w.paths[path] = o
    return o
end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end

FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
UnregisterHook = function() end
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

local HW = { id = "host", objects = {}, paths = {}, hooks = {}, timers = {}, outbox = {} }
WORLD = HW
local FRAG = "BP_Throwable_Frag_C"
local frag_class = asset(HW, "BlueprintGeneratedClass", "/Game/Blueprints/Throwables/BP_Throwable_Frag.BP_Throwable_Frag_C")
frag_class._name = FRAG
HW.paths["/Script/Engine.Default__KismetSystemLibrary"] = new(HW, { "KismetSystemLibrary" }, "Default__KismetSystemLibrary", {}, {
    IsStandalone = function() return false end, IsServer = function() return true end })
HW.spawned = {}
HW.paths["/Script/Engine.Default__GameplayStatics"] = new(HW, { "GameplayStatics" }, "Default__GameplayStatics", {}, {
    GetPlayerController = function(_, wc, i) return HW.pcs[i + 1] end,
    GetNumPlayerControllers = function() return #HW.pcs end,
    GetCurrentLevelName = function() return "LongdownValley" end,
    BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf, coll, owner)
        next_num = next_num + 1
        local a = new(HW, { cls._name, "BP_MasterThrowable_C", "Actor" }, cls._name .. "_" .. next_num,
            { _loc = { X = tf.Translation.X, Y = tf.Translation.Y, Z = tf.Translation.Z }, _owner = owner, ExplosionDelay = 3 },
            { Frag = function(self) self._fuse = true end })
        a._p.Capsule = new(HW, { "CapsuleComponent" }, "Capsule_" .. next_num, { _owner = a }, {
            SetNotifyRigidBodyCollision = function() end, SetSimulatePhysics = function() end,
            SetPhysicsLinearVelocity = function(self, v) self._p._vel = v end,
            SetPhysicsAngularVelocityInDegrees = function() end,
        })
        HW.spawned[#HW.spawned + 1] = a
        return a
    end,
    FinishSpawningActor = function(_, a) return a end,
})

-- the host's own player
local lp = new(HW, { "LocalPlayer" }, "LocalPlayer_0")
local hpc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0", { Player = lp }, {
    IsLocalController = function() return true end })
local hpawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
    { Controller = hpc, _loc = { X = 5000, Y = 0, Z = 100 },
      PlayerState = new(HW, { "PlayerState" }, "PlayerState_0", {}, { GetPlayerId = function() return 256 end }) })
hpc._p.Pawn = hpawn
HW.pcs = { hpc }

-- a remote player (controller at `at`)
local function remote(n, at)
    local conn = new(HW, { "IpConnection" }, "IpConnection_" .. n)
    local ps = new(HW, { "PlayerState" }, "PlayerState_" .. n, {}, { GetPlayerId = function() return 256 + n end })
    local pawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. n,
        { _loc = { X = 0, Y = 0, Z = 100 }, PlayerState = ps })
    local pc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. n,
        { NetConnection = conn, Player = conn, Pawn = pawn }, {
            ClientMessage = function(self, msg) HW.outbox[#HW.outbox + 1] = { to = self, msg = msg } end }, at)
    pawn._p.Controller = pc
    return pc, pawn
end

for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
local H = { net = require("sdc_net"), throw = require("sdc_throw") }
local rpc = remote(1)
local HS = { role = "host", remote_pcs = { rpc }, remote = {} }
H.throw.install(HS)
H.throw.tick()

local function throw_msg(pc, seq)
    WORLD = HW
    H.net.handlers.THROW({ tostring(seq), FRAG, "30.0,0.0,150.0", "0.0,0.0,0.0", "2000.0,0.0,300.0" }, pc)
end
local function acks(pc, ok_flag)
    local n = 0
    for _, m in ipairs(HW.outbox) do
        if m.to == pc and m.msg:find("SDC1|THRACK|", 1, true) and m.msg:find("|" .. ok_flag .. "|", 1, true) then n = n + 1 end
    end
    return n
end

print("== 1. sdc_throw: seqs of a player who left")
throw_msg(rpc, 1)
check(#HW.spawned == 1 and acks(rpc, "1") == 1, "client's throw #1 spawned on the host and acknowledged")
throw_msg(rpc, 1)
check(#HW.spawned == 1, "the same #1 again (still connected): a repeat, ignored")
advance(3)
throw_msg(rpc, 2)
check(#HW.spawned == 2, "throw #2 spawned")

-- the player leaves; a second later the host tick prunes its numbers
HS.remote_pcs = {}
advance(1.1)
H.throw.tick()
-- it restarts and joins again: a new controller at the same address
local addr1 = rpc._addr
rpc._valid = false
local rpc2 = remote(2, addr1)
check(rpc2._addr == addr1, "(the new controller reuses the old address)")
HS.remote_pcs = { rpc2 }
advance(3)
H.throw.tick()
throw_msg(rpc2, 1)
check(#HW.spawned == 3 and acks(rpc2, "1") == 1, "the rejoined player's throw #1 is spawned, not dropped as a repeat")
advance(3)
throw_msg(rpc2, 1)
check(#HW.spawned == 3, "its #1 again: a repeat, ignored")
throw_msg(rpc2, 2)
check(#HW.spawned == 4, "its #2 spawned")

-- a connected player's numbers stay across ticks
advance(1.1)
H.throw.tick()
advance(3)
throw_msg(rpc2, 2)
check(#HW.spawned == 4, "a connected player's numbers are kept by the tick")

-- ======================================================================
-- Part 2: sdc_items UIDS / ITEMS
-- ======================================================================
print("== 2. sdc_items: UIDS / ITEMS after a rejoin at the same address")
for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
local log = setmetatable({ debug_enabled = false }, { __index = function() return function() end end })
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.missing(v) return v == nil end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o) return ue.valid(o) and (rawget(o, "__cls") or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
local world = { BP_PlayerCharacter_C = {}, BP_StaticMeshPickup_C = {}, BP_SkeletalMeshPickup_C = {} }
function ue.find_all(cls) return world[cls] or {} end
ue.find_all_recent = ue.find_all
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return nil end
function ue.delay() return false end
function ue.pawn_of(pc) local p = pc.Pawn; if ue.valid(p) then return p end end
function ue.is_runtime_spawned(o) return rawget(o, "__runtime") == true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and rawget(a, "__loc") end
function ue.hook_native() return true end
function ue.sub_time(label, fn, ...) return pcall(fn, ...) end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
local sent = {}
package.loaded["sdc_net"] = { send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc, kind = kind } end,
  broadcast = function() end, send_to_host = function() end, on = function() end }
-- the controller's address is its "addr" field
package.loaded["sdc_ctx"] = { addr = function(o) return o and (rawget(o, "addr") or rawget(o, "__name")) end }
RegisterHook = function() return 1, 2 end
NotifyOnNewObject = function() end
LoadAsset = function() end

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local function P(e) return { get = function() return e end } end
local function A(list) return { ForEach = function(_, f) for i, e in ipairs(list) do if f(i, P(e)) == true then break end end end } end
local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local DA = { __name = "DA_Bandage" }

-- one player: a knife (uid 20) equipped, a bandage (uid 30)
local function player(n, at)
    local pc = { __name = "PC" .. n, addr = at, NetConnection = { __name = "Conn" .. n } }
    local pawn = { __name = "Char" .. n, __cls = "BP_PlayerCharacter_C", Controller = pc, Role = 3, __loc = { X = 0, Y = 0, Z = 0 },
        MedicalComponent = { __name = "Med" .. n, Health = 50 } }
    pc.Pawn = pawn
    local items_ = {}
    for _, it in ipairs({ { 20, 1, 55.5, 0 }, { 30, 4, 100, 1 } }) do
        items_[#items_ + 1] = { [F_USID] = G(it[1]), [F_INDEX] = it[4], [F_SUBS] = A({}),
            [F_INFO] = { [F_COUNT] = it[2], [F_ITEMID] = DA, [F_DUR] = { X = it[3], Y = 100 } } }
    end
    pawn.BP_JigMultiplayer = { __name = "Jig" .. n, MainJigContainers = A({ { [F_CONT_UID] = G(1), [F_ITEMS] = A(items_) } }) }
    pawn.BP_JigHelperComp = { __name = "Helper" .. n, RepActorsData = A({}), ServerEquippedItems = {},
        EquipmentUIDs = { ForEach = function(_, f) f(P({ TagName = "Jig.PlayerSlot.MeleeWeapon" }), P(G(20))) end } }
    world.BP_PlayerCharacter_C[#world.BP_PlayerCharacter_C + 1] = pawn
    return pc, pawn
end
local function count(pc, kind)
    local n = 0
    for _, m in ipairs(sent) do if m.pc == pc and m.kind == kind then n = n + 1 end end
    return n
end

local items = require("sdc_items")
local IS = { role = "host", remote_pcs = {} }
items.init(IS)
items.register_handlers()
local pc1, pawn1 = player(1, 0x1000)
items.host_tick({ pc1 })
check(count(pc1, "UIDS") == 1 and count(pc1, "ITEMS") == 1, "first tick: UIDS / ITEMS sent")
sent = {}
advance(1)
items.host_tick({ pc1 })
check(count(pc1, "UIDS") == 0 and count(pc1, "ITEMS") == 0, "unchanged: not sent again")
-- the player leaves; the same character object comes back with a new
-- controller at the same address (a reused pawn address too: worst case)
advance(1)
items.host_tick({})
local pc2 = { __name = "PC1b", addr = 0x1000, NetConnection = { __name = "Conn1b" }, Pawn = pawn1 }
pawn1.Controller = pc2
sent = {}
advance(1)
items.host_tick({ pc2 })
check(count(pc2, "UIDS") == 1 and count(pc2, "ITEMS") == 1, "rejoined at the same address: UIDS / ITEMS sent again")

if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
