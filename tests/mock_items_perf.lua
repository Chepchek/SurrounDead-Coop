-- sdc_items host tick (h:items) cost: one inventory walk per remote player and
-- second shared by sdc_consume / sdc_tools / sdc_items, further players in
-- frames of their own, the level pickups check remembering what cannot change
-- (sliced passes, reused addresses forgotten, invalid objects skipped).
-- usage: lua mock_items_perf.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local logs = {}
local log = setmetatable({ debug_enabled = false }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local function count_log(pat)
  local n = 0
  for _, l in ipairs(logs) do if l:find(pat, 1, true) then n = n + 1 end end
  return n
end

-- clock: fixed, or moving a little on every read (slices of a pass)
local T, step = 1000, 0
os.clock = function() T = T + step; return T end

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
local pick_reads = {}   -- [pickup name] = engine reads of it
local function is_pick(o) return type(o) == "table" and rawget(o, "__pick") == true end
local function note(o) if is_pick(o) then pick_reads[o.__name] = (pick_reads[o.__name] or 0) + 1 end end
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o) note(o); return ue.valid(o) and (rawget(o, "__cls") or "") or "" end
function ue.prop(o, n) note(o); if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
local world = { BP_PlayerCharacter_C = {}, BP_StaticMeshPickup_C = {}, BP_SkeletalMeshPickup_C = {} }
local finds = {}
function ue.find_all(cls) finds[cls] = (finds[cls] or 0) + 1; return world[cls] or {} end
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return nil end
local delayed, delay_fails = {}, {}
function ue.delay(label, ms, fn)
  if delay_fails[label] then return false end
  delayed[#delayed + 1] = { label = label, ms = ms, fn = fn }
  return #delayed
end
local function run_delayed(only)
  local n, keep = 0, {}
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do
    if not only or d.label == only then d.fn(); n = n + 1 else keep[#keep + 1] = d end
  end
  for _, d in ipairs(delayed) do keep[#keep + 1] = d end
  delayed = keep
  return n
end
local function run_all_delayed()
  local total = 0
  for _ = 1, 200 do
    local n = run_delayed()
    total = total + n
    if n == 0 then break end
  end
  return total
end
function ue.pawn_of(pc) local p = pc.Pawn; if ue.valid(p) then return p end end
function ue.is_runtime_spawned(o) note(o); return rawget(o, "__runtime") == true end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) note(a); return a and rawget(a, "__loc") end
function ue.hook_native() return true end
local parts = {}
function ue.sub_time(label, fn, ...)
  parts[label] = (parts[label] or 0) + 1
  local ok, err = pcall(fn, ...)
  if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
  return ok
end
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
local cfgv = { replicate_items = true, client_tools = true }
package.loaded["sdc_config"] = { get = function(k) local v = cfgv[k]; if v == nil then return true end return v end }
local sent, handlers = {}, {}
package.loaded["sdc_net"] = { send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc.__name, kind = kind, args = { ... } } end,
  broadcast = function() end, send_to_host = function() end, on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and (rawget(o, "__name") or tostring(o)) end }
RegisterHook = function() return 1, 2 end
local notify = {}
NotifyOnNewObject = function(cls, fn) notify[cls] = fn end
FName = function(s) return s end
LoadAsset = function() end

-- ------------------------------------------------------------ inventories
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"

local reads = 0   -- struct member reads (each one is a name lookup in UE4SS)
local function S(fields) return setmetatable({}, { __index = function(_, k) reads = reads + 1; return fields[k] end }) end
local function P(e) return { get = function() return e end } end
local function A(list) return { ForEach = function(_, f) for i, e in ipairs(list) do if f(i, P(e)) == true then break end end end } end
local function G(a) return S({ A = a, B = 0, C = 0, D = 0 }) end
local DA = { __name = "DA_Bandage" }

-- containers: { uid, items = { { uid, n, dur, idx, sub } } }
local function make_jig(name, conts)
  local walks = 0
  local jig = { __name = name }
  setmetatable(jig, { __index = function(_, k)
    if k ~= "MainJigContainers" then return nil end
    walks = walks + 1
    local cl = {}
    for _, c in ipairs(conts) do
      local il = {}
      for _, it in ipairs(c.items) do
        il[#il + 1] = S({ [F_USID] = G(it.uid), [F_INDEX] = it.idx, [F_SUBS] = A(it.sub and { S({ [F_SUB_ID] = G(it.sub) }) } or {}),
          [F_INFO] = S({ [F_COUNT] = it.n, [F_ITEMID] = DA, [F_DUR] = S({ X = it.dur, Y = 100 }) }) })
      end
      cl[#cl + 1] = S({ [F_CONT_UID] = G(c.uid), [F_ITEMS] = A(il) })
    end
    return A(cl)
  end })
  rawset(jig, "ServerFuncUpdateDurabilityByUID", function(_, g, minus, _, out)
    for _, c in ipairs(conts) do
      for _, it in ipairs(c.items) do
        if it.uid == g.A then it.dur = math.max(0, it.dur - minus); out.NewDur = it.dur end
      end
    end
  end)
  return jig, function() return walks end
end

local function player(i, conts, loc)
  local pc = { __name = "PC" .. i, NetConnection = { __name = "Conn" .. i } }
  local pawn = { __name = "Char" .. i, __cls = "BP_PlayerCharacter_C", Controller = pc, Role = 3, __loc = loc,
    MedicalComponent = { __name = "Med" .. i, Health = 40 + i } }
  pc.Pawn = pawn
  local jig, walks = make_jig("Jig" .. i, conts)
  pawn.BP_JigMultiplayer = jig
  -- helmet 10 (head) -> its container 2 holds the NVG (11) at 0 -> its container 3 the battery (12) at 0
  local equip = { { "Jig.PlayerSlot.Headwear", 10 }, { "Jig.PlayerSlot.PrimaryWeapon", 20 } }
  pawn.BP_JigHelperComp = { __name = "Helper" .. i, RepActorsData = A({}), ServerEquippedItems = {},
    EquipmentUIDs = { ForEach = function(_, f)
      for _, e in ipairs(equip) do if f(P(S({ TagName = e[1] })), P(G(e[2]))) == true then break end end
    end } }
  world.BP_PlayerCharacter_C[#world.BP_PlayerCharacter_C + 1] = pawn
  return { pc = pc, pawn = pawn, jig = jig, walks = walks }
end

local function std_inventory()
  return {
    { uid = 1, items = { { uid = 10, n = 1, dur = 90, idx = 0, sub = 2 }, { uid = 20, n = 1, dur = 55.5, idx = 1 },
                         { uid = 30, n = 4, dur = 100, idx = 2 } } },
    { uid = 2, items = { { uid = 11, n = 1, dur = 80, idx = 0, sub = 3 } } },
    { uid = 3, items = { { uid = 12, n = 1, dur = 40, idx = 0 } } },
  }
end

local function msgs(pc, kind)
  local out = {}
  for _, m in ipairs(sent) do if m.pc == pc and m.kind == kind then out[#out + 1] = m end end
  return out
end

local items = require("sdc_items")
local S_ = { role = "host", remote_pcs = {} }
items.init(S_)
items.register_handlers()
items.install()

-- ------------------------------------------------------------ 0 remote players
print("no remote player:")
local p1 = player(1, std_inventory(), { X = 0, Y = 0, Z = 0 })
items.host_tick({})
check(p1.walks() == 0, "no inventory walked")
check(#sent == 0, "nothing sent")
check(not finds.BP_StaticMeshPickup_C and not finds.BP_SkeletalMeshPickup_C, "no pickups listed")
check(#delayed == 0, "nothing scheduled")
check(parts["h:items.consume"] == 1 and not parts["h:items.inv"], "only the global parts ran")

-- ------------------------------------------------------------ 1 remote player
print("one remote player:")
reads = 0
items.host_tick({ p1.pc })
check(p1.walks() == 1, "one walk of the inventory per tick (was 4): " .. p1.walks())
check(reads <= 6 * 15 + 3 * 8 + 3 * 6 + 2 * 6, "struct reads bounded: " .. reads)
local u = msgs("PC1", "UIDS")
check(#u == 1 and u[1].args[1] == "Jig.PlayerSlot.Headwear=10:0:0:0@90.00;Jig.PlayerSlot.PrimaryWeapon=20:0:0:0@55.50",
  "UIDS with durabilities: " .. tostring(u[1] and u[1].args[1]))
local it = msgs("PC1", "ITEMS")
check(#it == 1 and it[1].args[1] == "10:0:0:0=90.0/80.0;11:0:0:0=80.0/40.0;12:0:0:0=40.0;20:0:0:0=55.5;30:0:0:0=100.0",
  "ITEMS with battery charges: " .. tostring(it[1] and it[1].args[1]))
local pt = msgs("PC1", "PTOOLS")
check(#pt == 1 and pt[1].args[2] == "40.00", "PTOOLS with the NVG battery: " .. tostring(pt[1] and pt[1].args[2]))
for _, l in ipairs({ "h:items.consume", "h:items.stations", "h:items.containers", "h:items.inv", "h:items.tools",
                     "h:items.uids", "h:items.worn", "h:items.level" }) do
  check(parts[l] and parts[l] >= 1, "part " .. l .. " timed")
end
-- goggles on: the drain, PTOOLS and ITEMS show the drained charge (the walk is shared)
handlers.MYNVG({ "1" }, p1.pc)
sent = {}
T = T + 1
items.host_tick({ p1.pc })
check(p1.walks() == 2, "still one walk per tick")
pt = msgs("PC1", "PTOOLS")
it = msgs("PC1", "ITEMS")
check(#pt == 1 and pt[1].args[2] == "39.85", "PTOOLS after the drain: " .. tostring(pt[1] and pt[1].args[2]))
check(#it == 1 and it[1].args[1]:find("11:0:0:0=80.0/39.9;12:0:0:0=39.9", 1, true) ~= nil,
  "ITEMS after the drain: " .. tostring(it[1] and it[1].args[1]))
handlers.MYNVG({ "0" }, p1.pc)
-- unchanged: no UIDS / ITEMS again
sent = {}
T = T + 1
items.host_tick({ p1.pc })
check(#msgs("PC1", "UIDS") == 0 and #msgs("PC1", "ITEMS") == 0, "unchanged inventory: no UIDS / ITEMS")

-- ------------------------------------------------------------ 2 remote players
print("two remote players:")
local p2 = player(2, std_inventory(), { X = 100000, Y = 0, Z = 0 })
sent = {}
T = T + 1
local w1, w2 = p1.walks(), p2.walks()
items.host_tick({ p1.pc, p2.pc })
check(p1.walks() == w1 + 1 and p2.walks() == w2, "the first player's walk now, the second's not in this frame")
check(#msgs("PC2", "ITEMS") == 0, "nothing for the second player yet")
local n = run_delayed("items-player")
check(n == 1 and p2.walks() == w2 + 1, "the second player's part in a frame of its own")
check(#msgs("PC2", "ITEMS") == 1 and #msgs("PC2", "UIDS") == 1 and #msgs("PC2", "PTOOLS") == 1, "UIDS / ITEMS / PTOOLS for the second player")
-- a delayed part after a reset, or of a controller gone: nothing
T = T + 1
items.host_tick({ p1.pc, p2.pc })
items.reset()
sent = {}
w2 = p2.walks()
run_delayed("items-player")
check(p2.walks() == w2 and #sent == 0, "a delayed part of a reset session does nothing")
T = T + 1
items.host_tick({ p1.pc, p2.pc })
p2.pc.__valid = false
w2 = p2.walks()
run_delayed("items-player")
check(p2.walks() == w2, "a delayed part of a controller gone does nothing")
p2.pc.__valid = nil
-- delay unavailable: the part runs at once
delay_fails["items-player"] = true
T = T + 1
w2 = p2.walks()
items.host_tick({ p1.pc, p2.pc })
check(p2.walks() == w2 + 1, "without ue.delay the second player's part runs at once")
delay_fails["items-player"] = nil
run_all_delayed()

-- ------------------------------------------------------------ level pickups
print("level pickups:")
items.reset()
for _, w in ipairs({ "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }) do world[w] = {} end
local picks = {}
local repl = {}
local function pickup(name, loc, opts)
  opts = opts or {}
  local a = { __name = name, __pick = true, __cls = opts.cls or "BP_StaticMeshPickup_C", __runtime = opts.runtime == true,
    bReplicates = opts.replicated == true, __loc = loc }
  a.SetReplicates = function(self, v) self.bReplicates = v; repl[self.__name] = (repl[self.__name] or 0) + 1 end
  a.SetReplicateMovement = function() end
  a.ForceNetUpdate = function() end
  a.GetAttachParentActor = function() return nil end
  picks[name] = a
  local l = (#world.BP_StaticMeshPickup_C <= #world.BP_SkeletalMeshPickup_C) and world.BP_StaticMeshPickup_C or world.BP_SkeletalMeshPickup_C
  l[#l + 1] = a
  return a
end
-- player 1 at the origin; 5000 cm reach
for i = 1, 20 do pickup("Far" .. i, { X = 20000 + i * 100, Y = 0, Z = 0 }) end
for i = 1, 4 do pickup("Near" .. i, { X = 1000 * i, Y = 0, Z = 0 }) end
pickup("NearRuntime", { X = 500, Y = 0, Z = 0 }, { runtime = true })
pickup("NearReplicated", { X = 600, Y = 0, Z = 0 }, { replicated = true })
pickup("NearLocal", { X = 700, Y = 0, Z = 0 }, { cls = "BP_Torch_LocalAttachment_C" })
pickup("Doomed", { X = 30000, Y = 0, Z = 0 })
local total = 0
for _ in pairs(picks) do total = total + 1 end

-- a sliced pass: 0.4 ms per clock read, 3 ms per slice
pick_reads, finds = {}, {}
items.stats.level_looks = 0
T = T + 10
step = 0.0004
items.host_tick({ p1.pc })
local first_slices = 0
for _, d in ipairs(delayed) do if d.label == "items-level" then first_slices = first_slices + 1 end end
check(first_slices == 1, "the pass goes on in a later frame")
-- an object of the list destroyed before its slice: skipped
picks.Doomed.__valid = false
local guard = 0
while #delayed > 0 and guard < 100 do run_delayed(); guard = guard + 1 end
step = 0
local slices = parts["h:items.level"] or 0
check(guard >= 2, "the pass took several frames: " .. guard)
local looked_all = true
for name in pairs(picks) do
  if name ~= "Doomed" and not pick_reads[name] then looked_all = false; print("    not looked at: " .. name) end
end
check(looked_all, "every pickup looked at by the sliced pass")
check(items.stats.level_looks == total - 1, "each looked at exactly once: " .. tostring(items.stats.level_looks) .. "/" .. (total - 1))
check(not repl.Doomed and not pick_reads.Doomed, "the object invalid by its slice was not read or replicated")
check(repl.Near1 == 1 and repl.Near2 == 1 and repl.Near3 == 1 and repl.Near4 == 1, "level pickups near the player replicate")
check(not repl.NearRuntime and not repl.NearLocal and not repl.NearReplicated, "runtime / local attachment / replicated ones not")
local far_repl = false
for i = 1, 20 do if repl["Far" .. i] then far_repl = true end end
check(not far_repl, "far ones not")
check(count_log("4 level items near players now replicate") == 1, "one log line for the pass")
check((finds.BP_StaticMeshPickup_C or 0) == 1 and (finds.BP_SkeletalMeshPickup_C or 0) == 1, "one listing per pass")

-- 5 s later, nothing changed: no listing, no engine read of any pickup
pick_reads, finds = {}, {}
T = T + 5.5
items.host_tick({ p1.pc })
local any = 0
for _, n2 in pairs(pick_reads) do any = any + n2 end
check(any == 0 and not finds.BP_StaticMeshPickup_C, "idle check: no listing, no pickup read (" .. any .. ")")
check(#delayed == 0, "idle check: nothing scheduled")

-- the player walks to Far5: the next check lists them, reads only what is near again
rawset(p1.pawn, "__loc", { X = 20500, Y = 0, Z = 0 })
pick_reads, finds = {}, {}
T = T + 5.5
items.host_tick({ p1.pc })
run_all_delayed()
check(repl.Far5 == 1 and repl.Far1 == 1 and repl.Far20 == 1, "remembered pickups near the player now replicate")
check((pick_reads.Near1 or 0) == 0 and (pick_reads.NearRuntime or 0) == 0, "replicated / skipped ones not read again")
check((pick_reads.Far5 or 0) > 0, "the near ones read in full before they replicate")

-- a new level pickup constructed at a remembered address (NotifyOnNewObject):
-- forgotten, the flush marks a level pickup, the next check reads it
rawset(p1.pawn, "__loc", { X = 0, Y = 0, Z = 0 })
local runtime_at = picks.NearRuntime
runtime_at.__runtime = false   -- (the same address, now a level pickup)
notify["/Game/Inventory/Items/BP_StaticMeshPickup.BP_StaticMeshPickup_C"](runtime_at)
run_delayed("items-flush")
pick_reads = {}
T = T + 5.5
items.host_tick({ p1.pc })
run_all_delayed()
check(repl.NearRuntime == 1, "a reused address is read again and its new pickup replicates")

-- the entries are read again after their trust time
pick_reads = {}
T = T + 200
items.host_tick({ p1.pc })
run_all_delayed()
check((pick_reads.Far10 or 0) > 0 and (pick_reads.Near1 or 0) > 0, "every entry read again after its trust time")

-- the check was off (no remote player for a while): all listed again
-- (12 s: before the minute's full listing)
pick_reads, finds = {}, {}
T = T + 6
items.host_tick({})
T = T + 6
items.host_tick({ p1.pc })
run_all_delayed()
check((finds.BP_StaticMeshPickup_C or 0) == 1, "after a pause the pickups are listed again")

-- a slice that never came (ue.delay unavailable): the next tick goes on
delay_fails["items-level"] = true
items.reset()
pick_reads = {}
step = 0.0004
T = T + 10
items.host_tick({ p1.pc })
step = 0
local before_ticks = 0
for name in pairs(picks) do if pick_reads[name] then before_ticks = before_ticks + 1 end end
check(before_ticks < total - 1, "the first slice did not finish the pass (" .. before_ticks .. ")")
for _ = 1, 30 do T = T + 1; step = 0.0004; items.host_tick({ p1.pc }); step = 0 end
delay_fails["items-level"] = nil
local after = 0
for name in pairs(picks) do if pick_reads[name] then after = after + 1 end end
check(after == total - 1, "the pass was finished by the next ticks (" .. after .. "/" .. (total - 1) .. ")")

-- without the new-object watch nothing remembered is trusted (old behaviour)
items.reset()
local fresh = require("sdc_items")   -- (same module: the watch flag is per install)
NotifyOnNewObject = function() error("no watch") end
fresh.install()
pick_reads, finds = {}, {}
T = T + 10
items.host_tick({ p1.pc })
run_all_delayed()
pick_reads, finds = {}, {}
T = T + 5.5
items.host_tick({ p1.pc })
run_all_delayed()
check((finds.BP_StaticMeshPickup_C or 0) == 1 and (pick_reads.Far3 or 0) > 0, "no watch: every check reads all pickups")

for _, l in ipairs(logs) do
  if l:find("^err") then print("  error logged: " .. l); fails = fails + 1 end
end
print(string.format("mock_items_perf: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
