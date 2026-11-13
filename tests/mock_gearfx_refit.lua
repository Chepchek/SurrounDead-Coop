-- Mock harness for the weapon refit (sdc_gearfx) and its persist trigger
-- (sdc_persist PSDONE): a fitted weapon that reaches a client gets its sight /
-- suppressor / muzzle brake once it has begun play there.
-- Engine order mocked: the first bunch runs OnRep_RepAttachments ->
-- ProcessAttachments (modules spawned, OnAttachmentsUpdated broadcast) BEFORE
-- BeginPlay, where BP_FirearmPickup binds CheckAttachments.
-- Real sdc_gearfx / sdc_persist / sdc_ue / sdc_log / sdc_net / sdc_config;
-- sdc_items and sdc_pawnstate are stubs.
-- usage: lua mock_gearfx_refit.lua <scripts dir>
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
local function last_line(pat)
    for i = #lines, 1, -1 do if lines[i]:find(pat) then return lines[i] end end
    return nil
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local next_addr = 4096
local registry, by_path = {}, {}
local function name_obj(s) return { ToString = function() return s end } end
local function new_obj(cls, short, props, methods)
    next_addr = next_addr + 16
    local o = setmetatable({ _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr,
        _valid = true }, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return rawget(t, "_p")[k]
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/L.L:PersistentLevel." .. self._short end
function Obj:GetFName() return name_obj(self._short) end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return name_obj(c) end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOwner() return self._p.__owner end

local Arr = {}
Arr.__index = Arr
local function arr(list) return setmetatable({ _i = list }, Arr) end
function Arr:GetArrayNum() return #self._i end
function Arr:ForEach(fn) for i, v in ipairs(self._i) do fn(i, { get = function() return v end }) end end

local function param(v) return { get = function() return v end, set = function(_, x) v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local hooks = {}
function RegisterHook(path, cb)
    if path:find("BP_FirearmPickup_C:ReceiveBeginPlay", 1, true) and not _G.FIREARM_LOADED then
        error("function not found: " .. path)
    end
    hooks[path] = hooks[path] or {}
    table.insert(hooks[path], cb)
    return 1, 2
end
function FindAllOf(cls) return registry[cls] or {} end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path) return by_path[path] end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
local delayed = {}
function ExecuteInGameThreadWithDelay(ms, f) delayed[#delayed + 1] = { ms = ms, f = f }; return #delayed end
function ExecuteWithDelay(ms, f) delayed[#delayed + 1] = { ms = ms, f = f } end
local loops = {}
function LoopInGameThreadWithDelay(ms, f) loops[#loops + 1] = { ms = ms, f = f }; return #loops end
function LoopAsync() end
function FName(s) return name_obj(s) end
local function run_delayed()
    local d = delayed
    delayed = {}
    for _, e in ipairs(d) do e.f() end
    return #d
end

local function fire(path, ...)
    local n = 0
    for _, cb in ipairs(hooks[path] or {}) do
        local r = cb(...)
        assert(r == nil, "hook returned a value: " .. path)
        n = n + 1
    end
    return n
end

-- ------------------------------------------------------------ stubs
local equipped = {}   -- [pawn] = { { actor =, slot = } }
package.loaded["sdc_items"] = { equipped_of = function(p) return equipped[p] or {} end }
package.loaded["sdc_pawnstate"] = { others = function() return {} end }

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local gearfx = require("sdc_gearfx")
local persist = require("sdc_persist")

local own_pawn = nil
ue.local_pawn = function() return own_pawn end

-- ------------------------------------------------------------ the game, mocked
local F_ATTS = "Attachments_6_38F2C7B64C1B85D80C3C35A8B1026969"
local DA = {
    reddot = new_obj("JigsawItem_DataAsset_C", "DA_RedDotSight", {}),
    acog = new_obj("JigsawItem_DataAsset_C", "DA_Acog4x32Scope", {}),
    supp = new_obj("JigsawItem_DataAsset_C", "DA_RifleSuppressor", {}),
    laser = new_obj("JigsawItem_DataAsset_C", "DA_SmallTacticalLaser", {}),
}
local spawned = 0
-- A firearm as the game builds it. rep = { { uid =, kind = "Sight"|"Muzzle"|"Tactical", da = } }
local function make_firearm(cls, short, pawn, role, rep)
    local wc = new_obj("BP_WeaponsPickupComponent_C", short .. "_wc", { ["SuppressorAttached?"] = false,
        ["MuzzleBrakeAttached?"] = false, ["SightAttached?"] = false })
    local installed = {}
    local pc = new_obj("BP_JigPickupComponent_C", short .. "_pc", { InstalledAttachments = arr(installed),
        RepAttachments = { [F_ATTS] = arr(rep) } })
    local w = new_obj(cls, short, { __owner = pawn, BP_JigPickupComponent = pc, BP_WeaponsPickupComponent = wc,
        Role = role, FireReady = false })
    pc._p.__owner = w
    local handlers = {}
    pc._pa = 0
    -- BP_JigPickupComponent.ProcessAttachments: modules found again by UID
    -- (else spawned), then broadcast OnAttachmentsUpdated
    pc._m.ProcessAttachments = function(self)
        self._pa = self._pa + 1
        if self._throw then error("ProcessAttachments failed") end
        for _, e in ipairs(rep) do
            local found = nil
            for _, m in ipairs(installed) do if m._uid == e.uid then found = m end end
            if not found then
                spawned = spawned + 1
                found = new_obj("BP_LocalAttachment_C", "Att_" .. spawned, { __owner = w })
                found._uid = e.uid
                installed[#installed + 1] = found
            end
        end
        for _, h in ipairs(handlers) do h() end
    end
    -- BP_FirearmPickup.ReceiveBeginPlay binds OnAttachmentsUpdated -> CheckAttachments
    w._begin = function()
        handlers[#handlers + 1] = function()
            wc._p.CurrentSight, wc._p["SightAttached?"] = nil, false
            wc._p["SuppressorAttached?"], wc._p.CurrentSuppressor = false, nil
            for _, e in ipairs(rep) do
                if e.kind == "Sight" then wc._p.CurrentSight, wc._p["SightAttached?"] = e.da, true end
                if e.kind == "Muzzle" then wc._p.CurrentSuppressor, wc._p["SuppressorAttached?"] = e.da, true end
            end
        end
    end
    return { w = w, pc = pc, wc = wc, installed = installed }
end

local BEGIN = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:ReceiveBeginPlay"
-- a weapon replicated to this machine: first bunch (OnRep -> ProcessAttachments), then BeginPlay (+ hooks)
local function arrive(f, opts)
    opts = opts or {}
    if #f.pc.RepAttachments[F_ATTS]._i > 0 and not opts.no_onrep then f.pc:ProcessAttachments() end
    f.w._begin()
    if not opts.no_hook then fire(BEGIN, param(f.w)) end
end
-- the game's own re-install: the next RepAttachments change after BeginPlay
local function reinstall(f) f.pc:ProcessAttachments() end

local function sight_of(f) local s = f.wc._p.CurrentSight; return s and s._short or "none" end

-- ============================================================ the bug, as the game has it
out("== the game alone: a fitted weapon arrives at a client")
local S = { role = "client", client = {} }
gearfx.init(S)
local P = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2147466856", { Role = 2 })
local raw = make_firearm("BP_BlackOpsMP5Pickup_C", "BP_BlackOpsMP5Pickup_C_1", P, 1,
    { { uid = "a1", kind = "Sight", da = DA.reddot }, { uid = "a2", kind = "Muzzle", da = DA.supp } })
arrive(raw)   -- no hook registered yet: the plain game
check(#raw.installed == 2, "modules are on the weapon (spawned by the OnRep before BeginPlay)")
check(sight_of(raw) == "none" and raw.wc._p["SuppressorAttached?"] == false,
    "but no sight and no suppressor: the broadcast came before CheckAttachments was bound")
reinstall(raw)
check(sight_of(raw) == "DA_RedDotSight" and raw.wc._p["SuppressorAttached?"] == true,
    "re-installing a module (the next RepAttachments change) fixes it - the user's workaround")

-- ============================================================ hook registration
out("== hook registration")
gearfx.host_tick()
check(hooks[BEGIN] == nil, "the host does not hook BeginPlay (its weapons are fitted after their BeginPlay)")
_G.FIREARM_LOADED = false
gearfx.client_tick()
check(hooks[BEGIN] == nil and count_lines("refit hook ok") == 0, "class not loaded yet: no hook, no line")
_G.FIREARM_LOADED = true
gearfx.client_tick()
check(hooks[BEGIN] and #hooks[BEGIN] == 1, "client: BeginPlay hook registered once the class exists")
check(count_lines("gearfx: refit hook ok") == 1, "hook line logged")
gearfx.client_tick()
check(#hooks[BEGIN] == 1, "registered only once")

-- ============================================================ the fix
out("== client: a fitted weapon arrives (persist restore / equip)")
local mp5 = make_firearm("BP_BlackOpsMP5Pickup_C", "BP_BlackOpsMP5Pickup_C_2", P, 1,
    { { uid = "b1", kind = "Sight", da = DA.acog }, { uid = "b2", kind = "Muzzle", da = DA.supp },
      { uid = "b3", kind = "Tactical", da = DA.laser } })
local spawned0 = spawned
arrive(mp5)
check(mp5.pc._pa == 2, "ProcessAttachments ran again after BeginPlay (OnRep + refit)")
check(sight_of(mp5) == "DA_Acog4x32Scope" and mp5.wc._p["SuppressorAttached?"] == true,
    "sight and suppressor set on the client")
check(#mp5.installed == 3 and spawned - spawned0 == 3, "no module spawned twice (found again by UID)")
local l = last_line("BP_BlackOpsMP5Pickup_C_2 of BP_PlayerCharacter_C_2147466856 arrived fitted with 3 module")
check(l ~= nil, "refit line names the weapon, its owner and the module count")
check(l and l:find("ok=true", 1, true) and l:find("was sight none, suppressor no, muzzle brake no -> now sight DA_Acog4x32Scope, suppressor yes, muzzle brake no", 1, true),
    "refit line shows the state before and after")
check(count_lines("arrived fitted with %d module%(s%): ProcessAttachments run again %(ok=true") == 1, "one refit")

out("== not refitted")
local bare = make_firearm("BP_AR15Pickup_C", "BP_AR15Pickup_C_3", P, 1, {})
arrive(bare)
check(bare.pc._pa == 0, "weapon without modules: left alone")
local own_copy = make_firearm("BP_AR15Pickup_C", "BP_AR15Pickup_C_4", nil, 3, { { uid = "c1", kind = "Sight", da = DA.reddot } })
own_copy.pc:ProcessAttachments()   -- the authority path: BeginPlay ... later UpdateAttachments
own_copy.pc._pa = 0
own_copy.w._begin()
fire(BEGIN, param(own_copy.w))
check(own_copy.pc._pa == 0, "this machine's own actor (authority): the game fits it after BeginPlay itself")
S.role = "host"
local hostw = make_firearm("BP_AR15Pickup_C", "BP_AR15Pickup_C_5", P, 1, { { uid = "d1", kind = "Sight", da = DA.reddot } })
arrive(hostw)
check(hostw.pc._pa == 1, "role host: hook does nothing")
S.role = "client"
local dead = make_firearm("BP_AR15Pickup_C", "BP_AR15Pickup_C_6", P, 1, {})
dead.w._valid = false
check(pcall(fire, BEGIN, param(dead.w)), "invalid weapon: nothing, no throw")
local bad = make_firearm("BP_M4Pickup_C", "BP_M4Pickup_C_7", P, 1, { { uid = "e1", kind = "Sight", da = DA.reddot } })
bad.pc._throw = true
local okb = pcall(arrive, bad, { no_onrep = true })
check(okb, "ProcessAttachments throwing: the hook swallows it")
check(count_lines("ProcessAttachments run again %(ok=false ") == 1 and last_line("BP_M4Pickup_C_7 .*%(ok=false ") ~= nil, "failure logged")
bad.pc._throw = nil

-- ============================================================ persist: PSDONE passes
out("== persist: the host's restore finished (PSDONE) -> two passes over the own weapons")
own_pawn = P
persist.install(S)
-- weapons of the restore: one refitted on arrival, one that came before the hook was in
local early = make_firearm("BP_MarksmansLegacyPickup_C", "BP_MarksmansLegacyPickup_C_8", P, 1,
    { { uid = "f1", kind = "Sight", da = DA.acog }, { uid = "f2", kind = "Muzzle", da = DA.supp } })
arrive(early, { no_hook = true })
check(sight_of(early) == "none", "a weapon that came before the hook: still without its sight")
local melee = new_obj("BP_MachetePickup_C", "BP_MachetePickup_C_9", { __owner = P, Role = 1 })
local helmet = new_obj("BP_HelmetPickup_C", "BP_HelmetPickup_C_10", { __owner = P, Role = 1 })
equipped[P] = {
    { actor = mp5.w, slot = "Jig.PlayerSlot.PrimaryWeapon" },
    { actor = early.w, slot = "Jig.PlayerSlot.SecondaryWeapon" },
    { actor = bare.w, slot = "Jig.PlayerSlot.SidearmWeapon" },
    { actor = melee, slot = "Jig.PlayerSlot.MeleeWeapon" },
    { actor = helmet, slot = "Jig.PlayerSlot.Headwear" },
}
delayed = {}
net.handlers.PSSET({ "g1", "", "-", "0", "inv" })
net.handlers.PSDONE({ "g1", "14", "201" })
check(#delayed == 2 and delayed[1].ms == 3000 and delayed[2].ms == 10000, "two passes scheduled (3 s, 10 s)")
local mp5_pa = mp5.pc._pa
run_delayed()
check(early.pc._pa == 2 and sight_of(early) == "DA_Acog4x32Scope" and early.wc._p["SuppressorAttached?"] == true,
    "the early weapon refitted once by the passes")
check(mp5.pc._pa == mp5_pa, "the weapon refitted on arrival is not touched again")
check(bare.pc._pa == 0, "weapon without modules untouched")
check(count_lines("3 s after the host's restore: 3 own firearm%(s%), 1 refitted now") == 1, "first pass line")
check(count_lines("10 s after the host's restore: 3 own firearm%(s%), 0 refitted now") == 1, "second pass: nothing left")
check(last_line("BP_MarksmansLegacyPickup_C_8 of .* 3 s after the host's restore with 2 module") ~= nil, "refit line of the pass")

out("== persist: repeats and stale passes")
delayed = {}
net.handlers.PSDONE({ "g1", "-", "-" })
check(#delayed == 0, "PSDONE again (answer to a later PSRDY): nothing scheduled")
S.client = {}
net.handlers.PSSET({ "g2", "", "-", "0", "inv" })
net.handlers.PSDONE({ "g2", "14", "0" })
check(#delayed == 0, "restore with no items: nothing scheduled")
persist.reset("test")   -- a new connection (client_tick does this when S.client changes)
net.handlers.PSSET({ "g3", "", "-", "0", "inv" })
net.handlers.PSDONE({ "g3", "14", "5" })
check(#delayed == 2, "a new restore schedules again")
S.client = {}   -- left and joined again before the pass
local sweeps = count_lines("own firearm%(s%), %d+ refitted now")
run_delayed()
check(count_lines("own firearm%(s%), %d+ refitted now") == sweeps, "pass of an old connection does nothing")
S.role = "host"
check(gearfx.refit_own("test") == 0, "refit_own on the host: nothing")
S.role = "client"
own_pawn = nil
check(gearfx.refit_own("test") == 0, "no own character: nothing")

real_print(string.format("gearfx refit: %d passed, %d failed", passed, fails))
real_print(fails == 0 and string.format("%d checks, ALL OK", passed) or string.format("%d checks, %d FAILED", passed + fails, fails))
os.exit(fails == 0 and 0 or 1)
