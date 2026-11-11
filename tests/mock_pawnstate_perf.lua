-- Mock harness for sdc_pawnstate's per-frame work after the 0.7.0 perf pass:
-- left hand IK (Lua InverseTransformLocation, written only when it moved,
-- every frame only on screen), head turn (nothing written while straight),
-- held weapon cached (RepActorsData walked only on a change), the shared
-- character list (no FindAllOf per refresh, a new character listed at once),
-- nothing at all on a host nobody is connected to, never a destroyed object
-- touched, the host's weapon pose check. Real sdc_pawnstate + sdc_ue + sdc_log;
-- sdc_net / sdc_ctx / sdc_config / sdc_appearance / sdc_items are stubs.
-- usage: lua mock_pawnstate_perf.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end

local fails, passed = 0, 0
local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = tostring(s) end
local function out(s) real_print(s) end
local function check(cond, what)
    if cond then passed = passed + 1; out("  ok   " .. what) else fails = fails + 1; out("  FAIL " .. what) end
end
local function count_lines(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat) then n = n + 1 end end
    return n
end
local function near(a, b, eps) return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6) end

-- ------------------------------------------------------------ fake UE4SS objects
-- Every member access of a live object counts as engine work (E.index /
-- E.newindex); IsValid / GetAddress do not. Any access to a destroyed object
-- other than IsValid / GetAddress is recorded (in the game: a crash).
local E = { index = 0, newindex = 0 }
local touched_dead = {}
local Obj = {}
local next_addr = 4096
local function mk(cls, short, props, methods)
    next_addr = next_addr + 16
    return setmetatable({ _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr,
        _valid = true, _writes = {} }, Obj)
end
local FREE = { IsValid = true, GetAddress = true }
Obj.__index = function(t, k)
    if not rawget(t, "_valid") and not FREE[k] then
        touched_dead[#touched_dead + 1] = rawget(t, "_short") .. "." .. tostring(k)
        error("touched a destroyed object: " .. rawget(t, "_short") .. "." .. tostring(k))
    end
    local base = rawget(Obj, k)
    if base ~= nil then
        if not FREE[k] then E.index = E.index + 1 end
        return base
    end
    E.index = E.index + 1
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return rawget(t, "_p")[k]
end
local function copy(v)
    if type(v) ~= "table" or getmetatable(v) == Obj then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end
local function store(t, k, v)
    if not rawget(t, "_valid") then
        touched_dead[#touched_dead + 1] = rawget(t, "_short") .. "." .. tostring(k) .. "="
        error("wrote to a destroyed object")
    end
    E.newindex = E.newindex + 1
    rawget(t, "_p")[k] = copy(v)   -- UE4SS copies a table into the struct
    local w = rawget(t, "_writes")
    w[k] = (w[k] or 0) + 1
end
Obj.__newindex = store
function Obj:IsValid() return rawget(self, "_valid") end
function Obj:GetAddress() return rawget(self, "_addr") end
function Obj:GetPropertyValue(n) return rawget(self, "_p")[n] end
function Obj:SetPropertyValue(n, v) store(self, n, v) end
function Obj:GetFName() local s = rawget(self, "_short"); return { ToString = function() return s end } end
function Obj:GetFullName() return rawget(self, "_cls") .. " /Game/L.L:PersistentLevel." .. rawget(self, "_short") end
function Obj:GetClass() local c = rawget(self, "_cls"); return { GetFName = function() return { ToString = function() return c end } end } end
local function writes(o, k) return rawget(o, "_writes")[k] or 0 end
local function P(o) return rawget(o, "_p") end

-- ------------------------------------------------------------ transforms
local function quat(ax, ay, az, ang)
    local n = math.sqrt(ax * ax + ay * ay + az * az)
    local s = math.sin(ang / 2) / n
    return { X = ax * s, Y = ay * s, Z = az * s, W = math.cos(ang / 2) }
end
local function rotmat(q)
    local x, y, z, w = q.X, q.Y, q.Z, q.W
    return {
        { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
        { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
        { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) },
    }
end
-- reference: R^T (v - t) * safe 1/s (matrix form, independent of the module's quaternion form)
local function ref_inv(t, v)
    local R = rotmat(t.Rotation)
    local d = { v.X - t.Translation.X, v.Y - t.Translation.Y, v.Z - t.Translation.Z }
    local function sr(s) if math.abs(s) <= 1e-8 then return 0 end return 1 / s end
    local x = R[1][1] * d[1] + R[2][1] * d[2] + R[3][1] * d[3]
    local y = R[1][2] * d[1] + R[2][2] * d[2] + R[3][2] * d[3]
    local z = R[1][3] * d[1] + R[2][3] * d[2] + R[3][3] * d[3]
    return x * sr(t.Scale3D.X), y * sr(t.Scale3D.Y), z * sr(t.Scale3D.Z)
end
local function xf(q, tx, ty, tz, s)
    return { Rotation = q, Translation = { X = tx, Y = ty, Z = tz }, Scale3D = s or { X = 1, Y = 1, Z = 1 } }
end

-- ------------------------------------------------------------ UE4SS globals
local world = {}          -- class -> list FindAllOf returns
local scans = {}
function FindAllOf(cls)
    scans[cls] = (scans[cls] or 0) + 1
    local l = world[cls]
    if not l or #l == 0 then return nil end
    local c = {}
    for i, o in ipairs(l) do c[i] = o end
    return c
end
local notify = {}
NotifyOnNewObject = function(path, fn) notify[path] = fn end
local by_path = {}
function StaticFindObject(path) return by_path[path] end
function FindFirstOf() return nil end
function ExecuteInGameThread(f) f() end
function LoopAsync() end
function RegisterHook() return 1, 2 end
function FName(s) return { ToString = function() return s end, _s = s } end
local function fname_is(n, s) return type(n) == "table" and n._s == s end

local kml_calls = 0
local kml = mk("KismetMathLibrary", "Default__KismetMathLibrary", {}, {
    InverseTransformLocation = function(_, t, v)
        kml_calls = kml_calls + 1
        local x, y, z = ref_inv(t, v)
        return { X = x, Y = y, Z = z }
    end })
by_path["/Script/Engine.Default__KismetMathLibrary"] = kml

-- ------------------------------------------------------------ stubs
local walks = 0
local equip = {}          -- [pawn] = { { actor =, slot = } }
package.loaded["sdc_items"] = { equipped_of = function(p)
    walks = walks + 1
    local o = {}
    for _, it in ipairs(equip[p] or {}) do
        if it.actor:IsValid() then o[it.actor:GetAddress()] = { actor = it.actor, slot = it.slot } end
    end
    return o
end }
local ue = require("sdc_ue")
package.loaded["sdc_appearance"] = { player_id = function(p)
    local ps = ue.prop(p, "PlayerState")
    if not ue.valid(ps) then return nil end
    return ps:GetPlayerId()
end }
package.loaded["sdc_ctx"] = { addr = function(o)
    if o == nil then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and a then return a end
    return nil
end }
package.loaded["sdc_config"] = { get = function() return nil end }
local handlers, sent = {}, {}
package.loaded["sdc_net"] = {
    on = function(k, f) handlers[k] = f end,
    broadcast = function(pcs, kind, id, s) sent[#sent + 1] = { kind = kind, id = id, s = s, n = #pcs } end,
    send_to = function() end, send_to_host = function() end,
}
local pawnstate = require("sdc_pawnstate")
local S = { role = "client", remote_pcs = {} }
pawnstate.init(S)
pawnstate.register_handlers()
local PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
check(notify[PATH] ~= nil, "register_handlers installs the character watch")

-- ------------------------------------------------------------ actors
local SOCK = xf(quat(0, 0, 1, 0.3), 30, 5, 140)          -- weapon LeftHand socket, world
local HAND = xf(quat(1, 2, 0.5, 1.1), 20, -4, 135)       -- Hand_R bone, world
local function make_weapon(short, sock, mesh)
    local root
    root = mk("StaticMeshComponent", short .. "_root", { AttachParent = mesh }, {
        DoesSocketExist = function(_, n) return fname_is(n, "LeftHand") end,
        GetSocketTransform = function(self, n, space)
            assert(fname_is(n, "LeftHand") and space == 0, "weapon socket")
            rawset(self, "_gst", (rawget(self, "_gst") or 0) + 1)
            return copy(rawget(self, "_sock"))
        end })
    rawset(root, "_sock", sock)
    local comp = mk("BP_EquipmentPickupComponent_C", short .. "_eq", { AnimBlendspace = 1 })
    local w = mk("BP_Rifle_C", short, { RootComponent = root, BP_EquipmentPickupComponent = comp })
    return w, root
end
local function make_pawn(short, opts)
    local anim = mk("AnimBP_PlayerCharacter_C", short .. "_anim", { BlendSpaceInt = opts.bs or 1, HeadRotation = { Pitch = 0, Yaw = 0, Roll = 0 } })
    local mesh
    mesh = mk("SkeletalMeshComponent", short .. "_mesh", {}, {
        GetSocketTransform = function(self, n, space)
            assert(fname_is(n, "Hand_R") and space == 0, "hand bone")
            rawset(self, "_gst", (rawget(self, "_gst") or 0) + 1)
            return copy(rawget(self, "_hand"))
        end,
        GetAnimInstance = function() return anim end,
        WasRecentlyRendered = function(self, tol)
            rawset(self, "_wrr", (rawget(self, "_wrr") or 0) + 1)
            return rawget(self, "_shown") ~= false
        end })
    rawset(mesh, "_hand", HAND)
    local helper = mk("BP_JigHelperComp_C", short .. "_helper", { ActiveWeapon = { TagName = opts.tag or "None" } })
    local ps = mk("PlayerState", short .. "_ps", {}, { GetPlayerId = function() return opts.id end })
    local p = mk("BP_PlayerCharacter_C", short, { Role = opts.role, BP_JigHelperComp = helper, Mesh = mesh,
        PlayerState = ps, ["HoldingFirearm?"] = opts.hf == true, ["IsADS?"] = false, ["PlayerDead?"] = false,
        LeftHandLoc = { X = -32.5, Y = -10, Z = 0 } }, {
        IsLocallyControlled = function() return opts.is_local == true end,
        UpdateCombatState = function(self, v) rawset(self, "_ucs", v); P(anim).BlendSpaceInt = v end,
        MC_UpdateCombatState = function(self, v) rawset(self, "_mc", v); P(anim).BlendSpaceInt = v end,
        FlashlightToggle = function() end,
    })
    world.BP_PlayerCharacter_C = world.BP_PlayerCharacter_C or {}
    table.insert(world.BP_PlayerCharacter_C, p)
    return { p = p, mesh = mesh, anim = anim, helper = helper }
end
local function spawn(short, opts)
    local c = make_pawn(short, opts)
    assert(notify[PATH](c.p) == nil, "new-object callback returned a value")
    return c
end
local function frames(n, fps)
    for _ = 1, n do
        T = T + 1 / (fps or 60)
        pawnstate.frame_tick()
    end
end
local function lhl(p) return P(p).LeftHandLoc end
local function lh_is(p, sock, hand)
    local x, y, z = ref_inv(hand, sock.Translation)
    local v = lhl(p)
    return near(v.X, x, 1e-6) and near(v.Y, y, 1e-6) and near(v.Z, z, 1e-6)
end

-- ------------------------------------------------------------ math
out("== InverseTransformLocation in Lua")
local inv = pawnstate.inv_transform
local okm = true
for i, q in ipairs({ quat(0, 0, 1, 0), quat(0, 0, 1, 1.7), quat(1, -2, 3, 2.9), quat(-0.3, 0.8, 0.1, -1.2) }) do
    for _, s in ipairs({ { X = 1, Y = 1, Z = 1 }, { X = 2, Y = 0.5, Z = -1.5 }, { X = 0, Y = 1, Z = 1e-9 } }) do
        local t = xf(q, 10 * i, -3, 7, s)
        local v = { X = 3, Y = 40, Z = -12 }
        local a, b, c = inv(t, v)
        local x, y, z = ref_inv(t, v)
        if not (near(a, x, 1e-9) and near(b, y, 1e-9) and near(c, z, 1e-9)) then okm = false end
    end
end
check(okm, "quaternion form = matrix reference (rotations, non-uniform / zero scale)")
check(inv({ Rotation = { X = 0, Y = 0, Z = 0 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } },
    { X = 1, Y = 2, Z = 3 }) == nil, "missing W: nil (engine function used)")

-- ------------------------------------------------------------ client
out("== client: the host's copy holding a rifle")
local ME = make_pawn("Me", { role = 2, is_local = true, id = 2 })
local H = make_pawn("HostChar", { role = 1, id = 1, tag = "Jig.PlayerSlot.PrimaryWeapon", hf = true })
local W1, R1 = make_weapon("Rifle1", SOCK, H.mesh)
equip[H.p] = { { actor = W1, slot = "Jig.PlayerSlot.PrimaryWeapon" } }
handlers.PSTATE({ "1", "hf=1;hm=0;sp=0;cs=0;hip=0;ln=0.00;bs=1;fl=0;hy=20" })
local scans0, walks0 = scans.BP_PlayerCharacter_C or 0, walks
frames(60)
check(lh_is(H.p, SOCK, HAND), "LeftHandLoc = the game's math (socket in Hand_R space)")
check(kml_calls == 0, "no KismetMathLibrary call (Lua math)")
local sc = (scans.BP_PlayerCharacter_C or 0) - scans0
check(sc <= 2, "1 s at 60 fps: FindAllOf BP_PlayerCharacter_C " .. sc .. " time(s) (was ~4)")
check(walks - walks0 == 1, "RepActorsData walked once in 1 s (was 4 + 0)")
check(writes(H.p, "LeftHandLoc") <= 5, "unchanged IK target: written " .. writes(H.p, "LeftHandLoc") .. " times (once per refresh), not 60")
check(rawget(R1, "_gst") >= 60 and rawget(H.mesh, "_gst") >= 60, "on screen: computed every frame")
local yaw = P(H.anim).HeadRotation.Yaw
check(yaw > 0.95 * 20 / 0.9 and yaw <= 20 / 0.9 + 1e-9, string.format("head turned (%.2f -> %.2f)", yaw, 20 / 0.9))

out("== client: moving hand")
local w0 = writes(H.p, "LeftHandLoc")
for i = 1, 30 do
    rawset(H.mesh, "_hand", xf(quat(1, 2, 0.5, 1.1 + i * 0.01), 20 + i * 0.1, -4, 135))
    frames(1)
end
check(writes(H.p, "LeftHandLoc") - w0 == 30, "moving hand: written every frame")
check(lh_is(H.p, SOCK, rawget(H.mesh, "_hand")), "and right")

out("== client: straight head")
handlers.PSTATE({ "1", "hf=1;hm=0;sp=0;cs=0;hip=0;ln=0.00;bs=1;fl=0;hy=0" })
frames(60)
check(P(H.anim).HeadRotation.Yaw == 0, "head back to 0")
local hw, idx0 = writes(H.anim, "HeadRotation"), E.index
frames(60)
check(writes(H.anim, "HeadRotation") == hw, "straight head: nothing written")
handlers.PSTATE({ "1", "hf=1;hm=0;sp=0;cs=0;hip=0;ln=0.00;bs=1;fl=0;hy=30" })
P(H.p)["IsADS?"] = true
frames(30)
check(near(P(H.anim).HeadRotation.Yaw, 0, 1e-9), "aiming: head kept straight")
P(H.p)["IsADS?"] = false
frames(60)
check(P(H.anim).HeadRotation.Yaw > 0.95 * 30 / 0.9, "not aiming: head turned again")

out("== client: off screen")
rawset(H.mesh, "_shown", false)
frames(16)   -- the next refresh sees it
local g0 = rawget(R1, "_gst")
local moved = xf(quat(0, 1, 0, 0.4), 22, -3, 130)
rawset(H.mesh, "_hand", moved)
frames(60)
local per = rawget(R1, "_gst") - g0
check(per >= 3 and per <= 6, "off screen: IK once per refresh (" .. per .. " in 1 s, not 60)")
check(lh_is(H.p, SOCK, moved), "still right (refresh rate)")
rawset(H.mesh, "_shown", true)
frames(16)
g0 = rawget(R1, "_gst")
frames(30)
check(rawget(R1, "_gst") - g0 == 30, "back on screen: every frame")

out("== client: weapon changes")
local SOCK2 = xf(quat(0, 0, 1, -0.2), 25, 8, 141)
local W2, R2 = make_weapon("Pistol", SOCK2, H.mesh)
table.insert(equip[H.p], { actor = W2, slot = "Jig.PlayerSlot.SecondaryWeapon" })
P(H.helper).ActiveWeapon = { TagName = "Jig.PlayerSlot.SecondaryWeapon" }
local wk = walks
frames(16)
check(lh_is(H.p, SOCK2, rawget(H.mesh, "_hand")), "slot changed: IK on the new weapon within a refresh")
check(walks - wk == 1, "one walk for the change")
-- the same slot gets a new actor; the old one is destroyed (and detached)
local SOCK3 = xf(quat(0, 0, 1, 0.1), 27, 9, 139)
local W3, R3 = make_weapon("Pistol2", SOCK3, H.mesh)
equip[H.p] = { { actor = W1, slot = "Jig.PlayerSlot.PrimaryWeapon" }, { actor = W3, slot = "Jig.PlayerSlot.SecondaryWeapon" } }
P(R2).AttachParent = nil
rawset(W2, "_valid", false)
rawset(R2, "_valid", false)
wk = walks
frames(16)
check(lh_is(H.p, SOCK3, rawget(H.mesh, "_hand")), "same slot, new actor: IK follows it")
check(walks - wk == 1, "found by one walk")
-- a new actor while the old one stays valid but detached
local SOCK4 = xf(quat(0, 0, 1, 0.5), 28, 10, 138)
local W4, R4 = make_weapon("Pistol3", SOCK4, H.mesh)
equip[H.p] = { { actor = W1, slot = "Jig.PlayerSlot.PrimaryWeapon" }, { actor = W4, slot = "Jig.PlayerSlot.SecondaryWeapon" } }
P(R3).AttachParent = nil
frames(16)
check(lh_is(H.p, SOCK4, rawget(H.mesh, "_hand")), "old actor detached: walked again, IK on the new one")
wk = walks
frames(60 * 5)
check(walks == wk, "5 s with nothing changed: no walk")
frames(60 * 6)
check(walks - wk == 1, "backstop: one walk after 10 s")
P(H.p)["HoldingFirearm?"] = false
frames(16)
local g4 = rawget(R4, "_gst") or 0
frames(60)
check((rawget(R4, "_gst") or 0) == g4, "holstered: no IK work")
P(H.p)["HoldingFirearm?"] = true

out("== client: 1 s tick still re-applies the state")
P(H.p)["Sprinting?"] = true
handlers.PSTATE({ "1", "hf=1;hm=0;sp=0;cs=0;hip=0;ln=0.25;bs=1;fl=0;hy=0" })
check(P(H.p)["Sprinting?"] == false and near(P(H.p).Lean, 0.25), "PSTATE applied to the copy")
P(H.p)["Sprinting?"] = true
pawnstate.tick()
check(P(H.p)["Sprinting?"] == false, "tick re-applied it")

out("== client: the host's copy destroyed (left the network range)")
rawset(H.p, "_valid", false)
rawset(H.mesh, "_valid", false)
rawset(H.anim, "_valid", false)
-- still returned by a scan here (worst case): the validated list drops it
frames(60)
check(#touched_dead == 0, "no destroyed object touched" .. (touched_dead[1] and (": " .. touched_dead[1]) or ""))
for i = #world.BP_PlayerCharacter_C, 1, -1 do
    if world.BP_PlayerCharacter_C[i] == H.p then table.remove(world.BP_PlayerCharacter_C, i) end
end
out("== client: the host's character comes back into range")
local scb = scans.BP_PlayerCharacter_C or 0
T = T + 0.5
local H2 = spawn("HostChar2", { role = 1, id = 1, tag = "Jig.PlayerSlot.PrimaryWeapon", hf = true })
local W5, R5 = make_weapon("Rifle5", SOCK, H2.mesh)
equip[H2.p] = { { actor = W5, slot = "Jig.PlayerSlot.PrimaryWeapon" } }
frames(16)   -- one refresh period, well under the list's 1 s
check(scans.BP_PlayerCharacter_C - scb >= 1, "rescanned because of the notification")
check(lh_is(H2.p, SOCK, HAND), "new character's IK within a refresh")
check(#touched_dead == 0, "still nothing destroyed touched")

-- ------------------------------------------------------------ host
out("== host, nobody connected")
for i = #world.BP_PlayerCharacter_C, 1, -1 do world.BP_PlayerCharacter_C[i] = nil end
pawnstate.reset()
S.role = "host"
S.remote_pcs = {}
local HP = make_pawn("HostOwn", { role = 3, is_local = true, id = 1 })
frames(2)
local e0, s0 = E.index + E.newindex, scans.BP_PlayerCharacter_C
frames(120)
check(E.index + E.newindex == e0, "2 s of frames: no engine access")
check(scans.BP_PlayerCharacter_C == s0, "and no FindAllOf")

out("== host, a client connected")
local CL = make_pawn("ClientChar", { role = 3, id = 2, tag = "Jig.PlayerSlot.PrimaryWeapon", hf = true, bs = 0 })
local WC, RC = make_weapon("RifleC", SOCK, CL.mesh)
equip[CL.p] = { { actor = WC, slot = "Jig.PlayerSlot.PrimaryWeapon" } }
local pc = mk("BP_PlayerController_C", "PC_Client", { Pawn = CL.p })
S.remote_pcs = { pc }
-- the new client character was spawned by the host (notification)
assert(notify[PATH](CL.p) == nil)
local hs, hw0 = scans.BP_PlayerCharacter_C, walks
frames(60)
check(lh_is(CL.p, SOCK, HAND), "client's IK on the host")
check(rawget(CL.p, "_mc") == 1, "weapon pose sweep: MC_UpdateCombatState(1) for the rifle (anim had 0)")
check(walks - hw0 == 1, "one walk shared by IK and the pose sweep")
check(scans.BP_PlayerCharacter_C - hs <= 2, "FindAllOf " .. (scans.BP_PlayerCharacter_C - hs) .. " in 1 s")
check(writes(HP.p, "LeftHandLoc") == 0 and writes(HP.anim, "HeadRotation") == 0, "own character untouched")
sent = {}
local wm = walks
handlers.MYSTATE({ "fl=0;hf=1;hm=0;sp=0;cs=0;hip=0;ads=0;ms=0;ln=0.00;bs=0;hy=0" }, pc)
check(pawnstate.state_of(CL.p) and pawnstate.state_of(CL.p).bs == "1", "MYSTATE: bs from the host's active slot")
check(walks == wm, "MYSTATE: held weapon from the cache")
wm = walks
local sh = scans.BP_PlayerCharacter_C
frames(60 * 3)
check(walks == wm and scans.BP_PlayerCharacter_C - sh <= 4, "3 s: no walk, FindAllOf " .. (scans.BP_PlayerCharacter_C - sh))
-- a pose the hook missed: the anim BP reset on this machine only
P(CL.anim).BlendSpaceInt = 0
frames(40)
check(P(CL.anim).BlendSpaceInt == 1, "pose sweep still fixes a reset anim BP")
P(CL.helper).ActiveWeapon = { TagName = "None" }
P(CL.p)["HoldingFirearm?"] = false
local want = pawnstate.expected_bs(CL.p)
check(want == 0, "holstered: expected pose 0")

out("== cached function handles failing")
P(CL.helper).ActiveWeapon = { TagName = "Jig.PlayerSlot.PrimaryWeapon" }
P(CL.p)["HoldingFirearm?"] = true
-- the first lookup (the handle) gives something that throws, plain calls work
local real_gst = rawget(RC, "_m").GetSocketTransform
local served = 0
rawget(RC, "_m").GetSocketTransform = nil
rawset(RC, "_p", setmetatable(rawget(RC, "_p"), { __index = function(_, k)
    if k ~= "GetSocketTransform" then return nil end
    served = served + 1
    if served == 1 then return function() error("stale handle") end end
    return real_gst
end }))
rawset(CL.mesh, "_hand", xf(quat(0, 0, 1, 0.9), 21, -2, 133))
pawnstate.reset()
frames(30)
check(lh_is(CL.p, SOCK, rawget(CL.mesh, "_hand")), "plain call used, IK right")
-- cached handles are off since the 0.7.1 crashes: plain calls from the start, nothing to fall back from
check(count_lines("cached GetSocketTransform handles failed") == 0, "no cached handles (plain calls only)")

check(#touched_dead == 0, "no destroyed object touched in the whole run")
real_print(string.format("pawnstate perf: %d passed, %d failed", passed, fails))
real_print(fails == 0 and string.format("%d checks, ALL OK", passed) or string.format("%d checks, %d FAILED", passed + fails, fails))
os.exit(fails == 0 and 0 or 1)
