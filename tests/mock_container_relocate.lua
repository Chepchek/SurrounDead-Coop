-- Mock harness: sdc_containers' relocate (config container_relocate, on by default).
-- A client drops an item into a slot the host's container already holds something
-- in. Off: the client is told "not moved" (CLIENT_MoveToIndexFailed). On: the host
-- moves the item into the first free slot of the same container itself, through the
-- game's own server function, and answers nothing (the plugin's move is the answer).
-- Covers: the key off/on, a free slot, slots unreadable, a full container, the
-- recursion guard (the host's own move runs the same handler) and the guard clearing.
-- usage: lua mock_container_relocate.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local T = 500
os.clock = function() return T end

-- ---------------------------------------------------------------- log capture
local logs = {}
package.loaded["sdc_log"] = setmetatable({ debug_enabled = true, TEXT = {}, probes_enabled = false }, {
    __index = function(_, k)
        return function(a, ...)
            local fmt, args = a, { ... }
            if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
            local ok, s = pcall(string.format, fmt, table.unpack(args))
            logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
        end
    end,
})
local function has_log(pat, level)
    for _, l in ipairs(logs) do
        if (level == nil or l:sub(1, #level + 2) == level .. ": ") and l:find(pat, 1, true) then return l end
    end
    return nil
end

-- ---------------------------------------------------------------- fakes
local CFG = {}
package.loaded["sdc_config"] = { get = function(k) local v = CFG[k]; if v == nil then return true end return v end }

local function arr(list)
    return {
        items = list,
        ForEach = function(self, fn)
            for i, v in ipairs(self.items) do
                local stop = fn(i, { get = function() return v end })
                if stop == true then return end
            end
        end,
        GetArrayNum = function(self) return #self.items end,
    }
end

local next_addr = 1000
local function obj(cls, name, t)
    t = t or {}
    next_addr = next_addr + 8
    t.__cls, t.__name, t.__addr = cls, name, next_addr
    return t
end

local function G(a) return { A = a, B = 0, C = 0, D = 0 } end
local function P(v) local p = { v = v }; function p.get() return p.v end; function p.set(_, x) p.v = x end; return p end
local function C(o) return { get = function() return o end } end

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.name(o) return ue.valid(o) and o.__name or "" end
function ue.short(o) return ue.valid(o) and o.__name or "<none>" end
function ue.path(o) return ue.valid(o) and ("/Game/" .. tostring(o.__name)) or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if ue.valid(o) then o[n] = v end end
function ue.location(a) return a and a.__loc end
function ue.role(o) return ue.valid(o) and (o.Role or 3) or 0 end
function ue.find_all() return {} end
function ue.find_object() return nil end
function ue.pawn_of() return nil end
function ue.local_pawn() return nil end
function ue.is_runtime_spawned() return false end
local delayed = {}
function ue.delay(label, ms, fn) delayed[#delayed + 1] = { label = label, fn = fn }; return true end
function ue.run_delayed(label)
    for i = #delayed, 1, -1 do
        if delayed[i].label == label then local f = table.remove(delayed, i).fn; f(); return true end
    end
    return false
end
function ue.sub_time() return true end
package.loaded["sdc_ue"] = ue

package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and (o.__addr or o.__name) or nil end }
package.loaded["sdc_wire"] = {
    uid_enc = function(u) return tostring(u) end,
    uid_dec = function(s) return tostring(s) end,
}
local net_sends = {}
package.loaded["sdc_net"] = {
    NOW = {},
    on = function() end,
    send_to = function(_, kind, ...) net_sends[#net_sends + 1] = { kind = kind, ... }; return true end,
    send_to_host = function(kind, ...) net_sends[#net_sends + 1] = { kind = kind, ... }; return true end,
    broadcast = function() return true end,
    congested = function() return false end,
}
package.loaded["sdc_deathbox"] = {
    init = function() end, host_tick = function() end, client_tick = function() end,
    register_handlers = function() end, reset = function() end,
}

-- ---------------------------------------------------------------- container model
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_SLOTS = "ContainerSlots_13_97B5C4324E23EC5C1D899EA59CCDD3AC"
local F_HOSTING = "HostingUID_12_7B8F2C70428BC8D03C43329582545C16"

local DA = obj("JigsawItem_DataAsset_C", "DA_WoodenWallHalf2", {})

local function grid(uid, n)
    local slots = {}
    for i = 1, (n or 4) do slots[i] = { [F_HOSTING] = G(0) } end
    return { [F_CONT_UID] = G(uid), [F_ITEMS] = arr({}), [F_SLOTS] = arr(slots) }
end

local function item(uid, mother, slot, n)
    return { [F_USID] = G(uid), [F_MOTHER] = G(mother), [F_SLOT] = slot,
             [F_INFO] = { [F_ITEMID] = DA, [F_COUNT] = n or 1 } }
end

local calls = {}      -- every SERVER_SameContainer_MoveToIndex the fake component got
local function new_comp(g, moved)
    local comp = obj("BP_JigComponent_C", "BP_JigMultiplayer", moved or {})
    comp.__grids = g
    setmetatable(comp, { __index = function(_, k)
        if k == "MainJigContainers" then return arr(g) end
        return nil
    end })
    function comp:GetOwner() return self.__owner end
    function comp.IsVendor() return false end
    function comp:SERVER_SameContainer_MoveToIndex(ref, uid, to, slot, rotated, in_idx)
        local gs = type(ref) == "table" and ref.__grids or nil
        calls[#calls + 1] = { args = { ref, uid, to, slot, rotated, in_idx }, n = select("#", ref, uid, to, slot, rotated, in_idx) }
        if not gs then return end
        local u = tostring(uid.A)
        for _, gr in ipairs(gs) do
            for i, it in ipairs(gr[F_ITEMS].items) do
                if tostring(it[F_USID].A) == u then
                    it[F_MOTHER] = to
                    it[F_SLOT] = slot
                    return
                end
            end
        end
    end
    return comp
end

-- a remote player's pawn: the class check and the Controller.NetConnection check
local function player(name, comp)
    local net = obj("NetConnection", "NetConnection_1", {})
    local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_1", {})
    local pawn = obj("BP_PlayerCharacter_C", name, { Controller = { NetConnection = net }, BP_JigMultiplayer = comp })
    pc.Pawn = pawn
    return pawn, pc
end

local containers = require("sdc_containers")
local S = { role = "host", remote_pcs = {} }
containers.init(S)

-- one 4-slot container: uid 10 at slot 0, uid 11 at slot 1
local function setup(slots)
    local g = { grid(10, slots) }
    g[1][F_ITEMS].items = { item(10, 10, 0, 1) }
    g[1][F_ITEMS].items[2] = item(11, 10, 1, 5)
    local comp = new_comp(g)
    local pawn, pc = player("Me", comp)
    comp.__owner = pawn
    S.remote_pcs = { pc }
    return comp, pawn, pc, g
end

local function move(comp, uid, to_uid, idx, from_slot)
    containers.host_rpc("SERVER_SameContainer_MoveToIndex", C(comp), nil,
        P(comp), P(G(uid)), P(G(to_uid)), P(idx), P(false), P(from_slot))
end

-- ---------------------------------------------------------------- A. off
print("A. container_relocate off:")
CFG.container_relocate = false
local comp, pawn = setup(4)
logs, calls = {}, {}
move(comp, 10, 10, 1, 0)
check(#calls == 0, "off: the host does not move the item itself")
check((comp.__failed or 0) == 0, "off: nothing recorded on the component")
check(containers.stats.failed_sent >= 1, "off: the client is told MoveToIndexFailed")
check(has_log("NOT moved", "warn") ~= nil, "off: logged as NOT moved")

-- ---------------------------------------------------------------- B. on, free slot
print("B. container_relocate on, a free slot:")
CFG.container_relocate = true
comp, pawn = setup(4)
logs, calls = {}, {}
local failed0 = containers.stats.failed_sent
move(comp, 10, 10, 1, 0)
check(#calls == 1, "on: the game's own move is called once")
check(calls[1] and calls[1].n == 6, "on: six arguments (component, item uid, container uid, slot, rotated, in-container index)")
check(calls[1] and calls[1].args[4] == 2, "on: the first free slot is 2 (slot 1 holds an item)")
check(containers.stats.relocated == 1, "on: counted as relocated")
check(containers.stats.failed_sent == failed0, "on: the client gets no failure")
check(has_log("put in free slot 2 instead") ~= nil, "on: logged where the item went")
check(not has_log("NOT moved", "warn"), "on: no NOT moved")

-- ---------------------------------------------------------------- C. slots unreadable
print("C. the container does not show its slots:")
comp, pawn = setup(4)
comp.__grids[1][F_SLOTS] = nil
logs, calls = {}, {}
local failed1 = containers.stats.failed_sent
move(comp, 10, 10, 1, 0)
check(#calls == 0, "unreadable slots: no move")
check(containers.stats.failed_sent == failed1 + 1, "unreadable slots: the old failure goes out")
check(has_log("no free slot", "debug") ~= nil, "unreadable slots: said in the debug log")

-- ---------------------------------------------------------------- D. full container
print("D. the container is full:")
comp, pawn = setup(2)      -- 2 slots, both taken
logs, calls = {}, {}
local failed2 = containers.stats.failed_sent
move(comp, 10, 10, 1, 0)
check(#calls == 0, "full: no move")
check(containers.stats.failed_sent == failed2 + 1, "full: the old failure goes out")

-- ---------------------------------------------------------------- E. recursion
print("E. the host's own move comes back through the handler:")
comp, pawn = setup(4)
logs, calls = {}, {}
local host_moves0 = containers.stats.host_moves
local real_move = comp.SERVER_SameContainer_MoveToIndex
function comp:SERVER_SameContainer_MoveToIndex(ref, uid, to, slot, rotated, in_idx)
    real_move(self, ref, uid, to, slot, rotated, in_idx)
    -- the game's call runs the plugin's multicast handler on the host too
    containers.host_rpc("SERVER_SameContainer_MoveToIndex", C(self), nil,
        P(self), P(uid), P(to), P(slot), P(rotated), P(in_idx))
end
move(comp, 10, 10, 1, 0)
check(containers.stats.relocated == 2, "recursion: the outer call relocated once")
check(containers.stats.host_moves == host_moves0 + 1, "recursion: the handler ran once, not twice")
check(#calls == 1, "recursion: one game call only")

-- ---------------------------------------------------------------- F. guard clears
print("F. the guard is cleared after the delay:")
check(ue.run_delayed("containers.relocate") == true, "the guard clear was scheduled")
logs, calls = {}, {}
move(comp, 10, 10, 1, 0)
check(#calls == 1, "after the clear a new move goes through again")

print(string.format("%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)