-- Mock harness (critic fix 2026-11-13, group B, A4 / A5): join answers as
-- lists instead of one message per object.
--   sdc_rename: the RNAMEQ answer is RNAME|class!x,y,z!uid!name;... in
--     messages of at most 1500 characters (names with ';', '|', '%', '!'
--     survive); the old one-container RNAME is still taken.
--   sdc_events: a joiner gets the markers of earlier events as one
--     WEVT|o|class>x,y,z>marker;... message; the old one-event form is still
--     taken.
-- usage: lua mock_fix_b_lists.lua <scripts dir>
-- (harness core copied from mock_rename.lua)
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, nchecks = 0, 0
local real_print = print
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then real_print("  ok   " .. what) else real_print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local machine = "host"
local worlds = { host = {}, client = {} }
local Obj = {}
local next_addr = 4096
local function new_obj(cls, short, props, methods, bases, where)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true,
                _bases = bases or {} }
    o._bases[cls] = true
    setmetatable(o, Obj)
    local w = worlds[where or machine]
    w[#w + 1] = o
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    local p = rawget(t, "_p")[k]
    if p ~= nil then return p end
    return nil
end
Obj.__newindex = function(t, k, v) rawget(t, "_p")[k] = v end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:IsA(c) return c ~= nil and self._bases[c._short] == true end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end

-- ------------------------------------------------------------ UE4SS globals
local CONT = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local class_obj = new_obj("BlueprintGeneratedClass", "BuildableMaster_Container_C", {}, {}, nil, "host")
table.remove(worlds.host)
function RegisterHook() return 1, 2 end
function FindAllOf(cls)
    local out = {}
    for _, o in ipairs(worlds[machine]) do if o._valid and o._bases[cls] then out[#out + 1] = o end end
    return #out > 0 and out or nil
end
function FindFirstOf(cls) local l = FindAllOf(cls); return l and l[1] or nil end
function StaticFindObject(path)
    if path == CONT then return class_obj end
    return nil
end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay() return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end

print = function() end   -- the modules' log lines
local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
ue.every = function() end
local net = require("sdc_net")
local function on(m) machine = m; ue.forget_world() end

-- ------------------------------------------------------------ machines
local function box_methods()
    return { OverrideBuildName = function(self, name) self._p.ContainerName = name end }
end
local BASES = function() return { BuildableMaster_Container_C = true, Actor = true } end
local function guids(list)
    return { ForEach = function(_, fn) for i, g in ipairs(list) do fn(i, { get = function() return g end }) end end }
end
local function new_box(where, short, loc, uid, name, da)
    local comp = new_obj("BP_JigComponent_C", short .. ".Jig", { MainContainersIDs = guids({ uid }) }, {}, nil, where)
    return new_obj("Buildable_StorageCrate_C", short, { __loc = loc, ContainerName = name, BP_JigMultiplayer = comp,
        PickupDataAsset = da }, box_methods(), BASES(), where)
end

machine = "host"
local da_h = new_obj("JigsawItem_DataAsset_C", "DA_StorageCrate", { name = "Storage Crate" })
local host_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local host_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_0", { Player = host_lp }, {
    IsLocalController = function() return true end }, { PlayerController = true })
local conn = new_obj("IpConnection", "IpConnection_1", {})
local rpawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { __loc = { X = 0, Y = 0, Z = 0 } })
local rpc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_7", { Player = conn, NetConnection = conn, Pawn = rpawn }, {
    IsLocalController = function() return false end }, { PlayerController = true })
rpawn._p.Controller = rpc
machine = "client"
local da_c = new_obj("JigsawItem_DataAsset_C", "DA_StorageCrate", { name = "Storage Crate" })
local client_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local client_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_1", { Player = client_lp }, {
    IsLocalController = function() return true end }, { PlayerController = true })

local SPECIAL = { "Ammo; 9mm", "A|B", "Wow!", "100% food", "Шкаф;1", "x!y;z|w%25" }
local N = 40
local hboxes, cboxes, want = {}, {}, {}
for i = 1, N do
    local name = SPECIAL[i] or string.format("Long storage crate name number %02d with a few more words", i)
    local loc = { X = 1000 * i, Y = 0, Z = 0 }
    local uid = { A = i, B = i, C = i, D = i }
    hboxes[i] = new_box("host", "Buildable_StorageCrate_C_21474" .. (10000 + i), loc, uid, name, da_h)
    cboxes[i] = new_box("client", "Buildable_StorageCrate_C_21473" .. (10000 + i), loc, uid, "Storage Crate", da_c)
    want[i] = name
end
-- one never renamed: not sent
new_box("host", "Buildable_StorageCrate_C_2147499999", { X = -500, Y = 0, Z = 0 }, { A = 99, B = 99, C = 99, D = 99 }, "Storage Crate", da_h)

-- the wire
local wire = {}
net.send_to = function(pc, kind, ...) wire[#wire + 1] = { to = pc, msg = net.encode(kind, ...) }; return true end
net.send_to_host = function(kind, ...) wire[#wire + 1] = { to = "host", msg = net.encode(kind, ...) }; return true end
local function take(kind)
    local out, keep = {}, {}
    for _, m in ipairs(wire) do
        local k = net.decode(m.msg)
        if kind == nil or k == kind then out[#out + 1] = m else keep[#keep + 1] = m end
    end
    wire = keep
    return out
end

-- ===========================================================================
real_print("== A4. sdc_rename: the names of renamed containers as RNAME lists")
on("host")
local host_rn = require("sdc_rename")
host_rn.install({ role = "host", remote_pcs = { rpc }, map = "LongdownValley" })
local host_q = net.handlers.RNAMEQ
package.loaded["sdc_rename"] = nil
on("client")
local client_rn = require("sdc_rename")
client_rn.install({ role = "client", remote_pcs = {}, map = "LongdownValley", client = { acked = true, pc_key = "pc1" } })
local client_name = net.handlers.RNAME

on("host"); host_q({}, rpc)
local snap = take("RNAME")
local longest, entries = 0, 0
for _, m in ipairs(snap) do
    longest = math.max(longest, #m.msg)
    local _, f = net.decode(m.msg)
    check(f[2] == nil, "a list message (one field): " .. m.msg:sub(1, 60))
    for _ in tostring(f[1]):gmatch("[^;]+") do entries = entries + 1 end
end
check(#snap >= 2 and #snap <= 5, string.format("%d renamed containers in %d message(s), not %d", N, #snap, N))
check(entries == N, "every renamed container listed once, the default-named one not: " .. entries)
check(longest <= 1500 + 40, "each message within the 1500-character list size: " .. longest)
check(host_rn.stats.names_sent == N, "host stat: names sent")
on("client")
for _, m in ipairs(snap) do client_name(select(2, net.decode(m.msg)), client_pc) end
local same = 0
for i = 1, N do if cboxes[i]._p.ContainerName == want[i] then same = same + 1 end end
check(same == N, "every name applied on the client, ';' '|' '%' '!' included: " .. same .. "/" .. N)
check(cboxes[1]._p.ContainerName == "Ammo; 9mm" and cboxes[6]._p.ContainerName == "x!y;z|w%25",
    "special names exact: '" .. tostring(cboxes[1]._p.ContainerName) .. "', '" .. tostring(cboxes[6]._p.ContainerName) .. "'")
-- the old one-container form
on("client"); client_name({ "Buildable_StorageCrate_C", "2000,0,0", "2:2:2:2", "Old%3Bform" }, client_pc)
check(cboxes[2]._p.ContainerName == "Old;form", "RNAME|class|x,y,z|uid|name (one container) still applied")
-- escaping round trip with ';'
check(host_rn.unesc(host_rn.esc("a;b|c%d!e")) == "a;b|c%d!e" and not host_rn.esc("a;b"):find(";", 1, true), "';' escaped on the wire")

-- ===========================================================================
real_print("== A5. sdc_events: a joiner's markers of earlier events in one WEVT o list")
for k in pairs(package.loaded) do if k == "sdc_events" then package.loaded[k] = nil end end
on("host")
local host_ev = require("sdc_events")
local HS = { role = "host", remote_pcs = { rpc }, remote = {} }
host_ev.install(HS)
host_ev._t.set_state(HS)
local mk = "UI/Textures/Heli.Heli>Crashed; Military>A crash|site>3.500,3.500>0.5052,0.1697,0.0342,1.0000>0"
for i = 1, 5 do
    local key = string.format("%d,%d,100", 10000 * i, -5000 * i)
    -- (the spec as marker_spec writes it: texts escaped; event 3 has no marker)
    local spec = nil
    if i ~= 3 then
        spec = mk:gsub("Crashed; Military", "Crashed%%3B Military%%3B " .. i):gsub("A crash|site", "A crash%%7Csite")
    end
    table.insert(host_ev._st.events, { key = key, cls = "Prefab_CrashedApache01_C", loc = { X = 10000 * i, Y = -5000 * i, Z = 100 },
        snd = "", mk = spec, title = "Crashed", t = T, notes = {}, to = {} })
end
take()
host_ev.tick()          -- its character is there: the wait starts
T = T + 6
host_ev.tick()          -- the markers go
local j = take("WEVT")
check(#j == 1, "one WEVT message for the joiner: " .. #j)
local _, jf = net.decode(j[1] and j[1].msg or "")
check(jf and jf[1] == "o" and jf[3] == nil, "WEVT|o|<list>")
local n_e = 0
for _ in tostring(jf and jf[2] or ""):gmatch("[^;]+") do n_e = n_e + 1 end
check(n_e == 4, "4 events with a marker in the list (the one without a marker left out): " .. n_e)
T = T + 6
host_ev.tick()
check(#take("WEVT") == 0, "sent once")

package.loaded["sdc_events"] = nil
on("client")
local client_ev = require("sdc_events")
client_ev.install({ role = "client", remote_pcs = {}, remote = {} })
client_ev._t.set_state({ role = "client", remote_pcs = {}, remote = {} })
local placed = {}
client_ev.place_marker = function(key, loc, m) placed[#placed + 1] = { key = key, title = m.title, desc = m.desc }; return "placed" end
client_ev.play_sound = function() return "no sound" end
client_ev._t.on_wevt(jf, client_pc)
check(#placed == 4 and placed[1].key == "10000,-5000,100" and placed[4].key == "50000,-25000,100",
    "the client places every marker at its place: " .. #placed)
check(placed[1].title == "Crashed; Military; 1" and placed[1].desc == "A crash|site",
    "marker texts with ';' and '|' intact: '" .. tostring(placed[1] and placed[1].title) .. "' / '" .. tostring(placed[1] and placed[1].desc) .. "'")
-- the old one-event form
placed = {}
client_ev._t.on_wevt({ "o", "Prefab_CrashedApache01_C", "1,2,3", "", ">Old>d>3.500,3.500>0.5,0.1,0.0,1.0>0" }, client_pc)
check(#placed == 1 and placed[1].key == "1,2,3" and placed[1].title == "Old", "WEVT|o|class|x,y,z||marker (one event) still taken")
placed = {}
client_ev._t.on_wevt({ "o", "garbage;Prefab_X_C>4,5,6>>Two>d>3.5,3.5>1,1,1,1>0" }, client_pc)
check(#placed == 1 and placed[1].key == "4,5,6", "a broken list entry skipped, the others placed")

print = real_print
print(string.format("%d checks, %s", nchecks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
