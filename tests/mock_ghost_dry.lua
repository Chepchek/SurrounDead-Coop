-- Mock harness: ghost items on a client's screen (sdc_consume, GHOSTQ).
-- P0-2 (v0.13): nothing is removed unless the host really does not have the
-- item, and the sweep can be run in a dry mode (config ghost_cleanup = false)
-- that only says in the log what it would end. The items whose answer from the
-- host may still be on its way (placeholders / a resend asked for) are not
-- ghosts at all.
-- usage: lua mock_ghost_dry.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local T = 500
os.clock = function() return T end
local function tick(d) T = T + d end

-- ------------------------------------------------------------ log capture
local logs = {}
package.loaded["sdc_log"] = setmetatable({ debug_enabled = true, TEXT = {} }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = tostring(k) .. ": " .. tostring(ok and s or fmt)
  end
end })
local function has_log(pat, level)
  for _, l in ipairs(logs) do
    if (level == nil or l:sub(1, #level + 2) == level .. ": ") and l:find(pat, 1, true) then return l end
  end
  return nil
end

-- ------------------------------------------------------------ fakes
FName = function(s) return { _s = s } end
local hooks = {}
function RegisterHook(path, fn) hooks[path] = fn; return 1, 2 end
function NotifyOnNewObject() end

local next_addr = 1000
local function obj(cls, name, t)
  t = t or {}
  next_addr = next_addr + 8
  t.__cls, t.__name, t.__addr = cls, name, next_addr
  return t
end

local function arr(list)
  return {
    items = list,
    ForEach = function(self, fn) for i, v in ipairs(self.items) do fn(i, { get = function() return v end }) end end,
    GetArrayNum = function(self) return #self.items end,
  }
end

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.name(o) return ue.valid(o) and (o.__name or "obj") or "" end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return ue.valid(o) and (o.__path or ("/Game/" .. ue.name(o))) or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if ue.valid(o) then o[n] = v end end
function ue.location(a) return a and a.__loc end
function ue.role(o) return ue.valid(o) and (o.__role or 1) or 0 end
function ue.find_all(cls)
  local out = {}
  if ue.__world then
    for _, o in ipairs(ue.__world) do
      if o.__cls == cls and rawget(o, "__valid") ~= false then out[#out + 1] = o end
    end
  end
  return out
end
function ue.find_object(p) return nil end
function ue.load_asset() return true end
function ue.pawn_of(pc) return pc and pc.Pawn end
function ue.local_pawn() return ue.__local_pawn end
function ue.local_pc() return ue.__local_pc end
function ue.is_runtime_spawned() return false end
local delayed = {}
function ue.delay(label, ms, fn) delayed[label] = fn; return true end
function ue.run_delayed(label) local f = delayed[label]; if f then delayed[label] = nil; f() end end
function ue.sub_time() return 0 end
function ue.hook_native() return true end
function ue.every_frame() return true end
ue.gameplay_statics = function() return nil end
ue.str = function(v) return v == nil and "" or tostring(v) end
ue.ksl = function() return nil end
ue.load_asset = function() return true end
package.loaded["sdc_ue"] = ue

-- config: every key true unless the test says otherwise
local CFG = {}
package.loaded["sdc_config"] = { get = function(k)
  local v = CFG[k]
  if v == nil then return true end
  return v
end }

package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__addr or nil end }
package.loaded["sdc_wire"] = { uid_enc = function(u) return tostring(u) end, uid_dec = function(c) return tostring(c) end }

local handlers, sent = {}, {}
package.loaded["sdc_net"] = {
  NOW = {},
  PAIRED = {}, FAST = {}, BUDGET = {}, SNAPSHOT = {}, MERGE = {},
  on = function(kind, fn) handlers[kind] = fn end,
  send_to = function(pc, kind, ...) sent[#sent + 1] = { to = "pc", kind = kind, ... }; return true end,
  send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, ... }; return true end,
  broadcast = function() return 0 end,
  congested = function() return false end,
}

-- sdc_place: only init() is called at load; everything else stays a no-op
package.loaded["sdc_place"] = setmetatable({ init = function() end }, { __index = function() return function() end end })
package.loaded["sdc_deathbox"] = { init = function() end, host_tick = function() end, client_tick = function() end,
                                   register_handlers = function() end, reset = function() end }

local consume = require("sdc_consume")

-- ------------------------------------------------------------ a remote player's inventory copy on the host
local by_uid = {}          -- the host's inventory of that player, as M.inventory reports it
local bad_read = nil
consume.inventory = function()
  local copy = {}
  for k, v in pairs(by_uid) do copy[k] = v end
  return { by_uid = copy, bad = bad_read }
end

local S = { role = "host", remote_pcs = {} }
consume.init(S)
consume.register_handlers()
check(handlers.GHOSTQ ~= nil, "GHOSTQ handler registered")

local function player(name)
  local net = obj("NetConnection", "NetConnection_" .. name)
  local pc = obj("BP_PlayerController_C", "BP_PlayerController_C_" .. name, {
    NetConnection = net,
    Controller = { NetConnection = net },
  })
  local pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_" .. name, { Controller = { NetConnection = net } })
  local comp = obj("BP_JigComponent_C", "BP_JigMultiplayer_" .. name, { __calls = {} })
  comp.CLIENT_UpdateCount = function(self, holder, g, n, zero)
    self.__calls[#self.__calls + 1] = { holder = holder, g = g, n = n, zero = zero }
  end
  pawn.BP_JigMultiplayer = comp
  pc.Pawn = pawn
  return { pc = pc, pawn = pawn, comp = comp }
end

local function ghostq(p, uids)
  handlers.GHOSTQ({ table.concat(uids, ";") }, p.pc)
end

local function reset_stats()
  consume.stats.ghosts_ended, consume.stats.ghosts_dry = 0, 0
  consume.stats.ghosts_waiting, consume.stats.ghost_stale_skips = 0, 0
  logs = {}
end

-- ------------------------------------------------------------ A. dry run
print("A. ghost_cleanup = false: only the log")
local p = player("a")
CFG.ghost_cleanup = false
by_uid, bad_read = { ["99:0:0:0"] = { n = 1 } }, nil
reset_stats()
ghostq(p, { "11:0:0:0", "12:0:0:0" })
check(#p.comp.__calls == 0, "nothing removed on the client")
check(consume.stats.ghosts_dry == 2, "two items counted as would-be removals")
check(consume.stats.ghosts_ended == 0, "nothing counted as ended")
check(has_log("nothing removed", "warn") ~= nil, "the log says nothing was removed")
check(has_log("11:0:0:0", "warn") ~= nil and has_log("12:0:0:0", "warn") ~= nil, "both uids named in the log")

-- ------------------------------------------------------------ B. cleanup on
print("B. ghost_cleanup = true: the client is told they are gone")
CFG.ghost_cleanup = true
reset_stats()
tick(10)                    -- past HOST_EVERY
ghostq(p, { "11:0:0:0", "12:0:0:0" })
check(#p.comp.__calls == 2, "CLIENT_UpdateCount once per item")
check(p.comp.__calls[1].n == 0, "count 0 (the slot goes)")
check(p.comp.__calls[1].zero and p.comp.__calls[1].zero.A == 0
      and p.comp.__calls[1].zero.B == 0 and p.comp.__calls[1].zero.C == 0 and p.comp.__calls[1].zero.D == 0,
      "a zero FGuid, as the game's ClientUpdateCount takes")
check(p.comp.__calls[1].g and p.comp.__calls[1].g.A == 11, "the item's own uid is passed")
check(consume.stats.ghosts_ended == 2, "two counted as ended")
check(has_log("the client was told they are gone", "warn") ~= nil, "logged as ended")

-- ------------------------------------------------------------ C. held: the host has it
print("C. an item the host's copy has: resend, no removal")
reset_stats()
tick(10)
by_uid = { ["11:0:0:0"] = { n = 1 } }
local resends = 0
package.loaded["sdc_items"] = { resend_items = function() resends = resends + 1 end }
local before = #p.comp.__calls
ghostq(p, { "11:0:0:0", "13:0:0:0" })
check(#p.comp.__calls == before + 1, "only the item the host does not have is ended")
check(consume.stats.ghosts_ended == 1 and consume.stats.ghosts_dry == 0, "one ended, none dry")
check(resends == 1, "the item list goes to the client again")
check(has_log("their inventory here has", "info") ~= nil, "logged as held")

-- ------------------------------------------------------------ D. unreadable inventory
print("D. the host's read was incomplete: nothing")
reset_stats()
tick(10)
bad_read = "the walk hit a removed grid"
local n0 = #p.comp.__calls
ghostq(p, { "14:0:0:0" })
check(#p.comp.__calls == n0, "nothing removed")
check(has_log("could not be read in full", "warn") ~= nil, "logged as unreadable")
bad_read = nil

-- ------------------------------------------------------------ E. throttles and caps
print("E. throttles, malformed input, the cap")
reset_stats()
tick(10)
by_uid = { ["99:0:0:0"] = { n = 1 } }
ghostq(p, { "15:0:0:0" })
local after_first = #p.comp.__calls
tick(1)                     -- inside HOST_EVERY
ghostq(p, { "16:0:0:0" })
check(#p.comp.__calls == after_first, "a second ask inside HOST_EVERY is ignored")
tick(5)
ghostq(p, { "not a uid", "17:0:0:0" })
check(#p.comp.__calls == after_first + 1, "a malformed code is skipped, the good one goes")
tick(5)
local many = {}
for i = 1, 30 do many[i] = string.format("%d:0:0:0", 100 + i) end
reset_stats()
local n1 = #p.comp.__calls
ghostq(p, many)
check(#p.comp.__calls - n1 == 16, "at most GHOST.MAX (16) items in one answer")
check(consume.stats.ghosts_ended == 16, "the cap is the one counted")

-- ------------------------------------------------------------ F. who is not a remote player
print("F. not a remote player / not a host")
reset_stats()
local lone = player("b")
lone.pawn.Controller = nil          -- no connection: not a remote character
ghostq(lone, { "18:0:0:0" })
check(#lone.comp.__calls == 0, "a pawn without a connection is left alone")
check(#p.comp.__calls == n1 + 16, "and nothing else was touched")

S.role = "client"
reset_stats()
local n2 = #p.comp.__calls
ghostq(p, { "19:0:0:0" })
check(#p.comp.__calls == n2, "a client does not answer GHOSTQ")
S.role = "host"

-- ------------------------------------------------------------ G. no copy on the host
print("G. the host's copy is empty: nothing ended (a replaced save)")
reset_stats()
tick(10)
by_uid = {}
local g = player("c")
ghostq(g, { "21:0:0:0", "22:0:0:0" })
check(#g.comp.__calls == 0, "nothing removed from the player's screen")
check(consume.stats.ghosts_ended == 0, "none counted as ended")
check(has_log("inventory is empty while their screen shows items", "warn") ~= nil, "logged as a replaced save")

print()
print(checks .. " checks, " .. fails .. " failed")
os.exit(fails == 0 and 0 or 1)
