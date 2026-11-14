-- sdc_consume: the host's walks of remote players' inventories only after a
-- change signal + a 10 s fingerprint check (0.13.0), not every second.
--   * the SAME scripted session (looting, a use, a craft, a grant, equip, a
--     shot's wear, a repair, the night vision drain, a ghost check, a death
--     and respawn) is run twice - the old continuous walk (walking.events =
--     false) and the event-driven one - and what every consumer got is
--     compared in every step: UIDS / ITEMS / PTOOLS of the tick's readers, the
--     use / craft ledger, the ghost check's answers, the log's warnings;
--   * a change no signal reaches (the verify's job), a durability written
--     into the snapshot in place, the ghost check's own fresh read;
--   * the cost: engine accesses per second of a 2-player host (a client with
--     80 containers / 230+ items, one small), idle and busy looting, before
--     and after (a simulated 3 us per access: one walk of the big
--     inventory is then ~12 ms, the 2026-11-13 log's average per second).
-- usage: lua mock_consume_walk_events.lua <scripts dir>
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

local COST = 0.000003    -- a simulated engine access: 3 us
local T = 1000
local TICK = 1.37          -- seconds between two host ticks (not a whole number: no timer sits on the edge of a tick)
local base = 1000        -- the clock at the start of the current tick (the walks' own cost does not move the next tick)
local ops = 0            -- engine accesses (member reads, get(), ForEach, GetArrayNum)
os.clock = function() return T end
local function tick_cost() ops = ops + 1; T = T + COST end

local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
local proxies = {}   -- [userdata] = the component table it stands for
function ue.valid(o)
  if type(o) == "userdata" then return proxies[o] ~= nil end
  return type(o) == "table" and rawget(o, "__valid") ~= false
end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o)
  if type(o) == "userdata" then return proxies[o] and "BP_JigComponent_C" or "" end
  return ue.valid(o) and (rawget(o, "__cls") or "") or ""
end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
local world = { BP_PlayerCharacter_C = {}, BP_StaticMeshPickup_C = {}, BP_SkeletalMeshPickup_C = {} }
function ue.find_all(cls) return world[cls] or {} end
function ue.find_object() return nil end
function ue.ksl() return nil end
function ue.local_pawn() return nil end
function ue.is_runtime_spawned() return false end
function ue.role(a) return a and a.Role or -1 end
function ue.location(a) return a and rawget(a, "__loc") end
function ue.hook_native() return true end
local delayed = {}
function ue.delay(label, ms, fn) delayed[#delayed + 1] = { label = label, ms = ms, fn = fn }; return #delayed end
local function run_all_delayed()
  for _ = 1, 400 do
    local list = delayed
    delayed = {}
    if #list == 0 then return end
    for _, d in ipairs(list) do d.fn() end
  end
end
function ue.pawn_of(pc) local p = pc.Pawn; if ue.valid(p) then return p end end
function ue.sub_time(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
  return ok
end
local cfgv = { replicate_items = true, client_tools = true }
local mocks = {
  sdc_log = log, sdc_ue = ue,
  sdc_config = { get = function(k) local v = cfgv[k]; if v == nil then return true end return v end },
  sdc_ctx = { addr = function(o)
    if type(o) == "userdata" then o = proxies[o] end
    return o and (rawget(o, "__name") or tostring(o))
  end },
}
local sent, handlers = {}, {}
local cuc = {}   -- CLIENT_UpdateCount calls of the host (the ghost check's answers)
mocks.sdc_net = { send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc.__name, kind = kind, args = { ... } } end,
  broadcast = function() end, send_to_host = function() end, on = function(k, h) handlers[k] = h end }
local hooks = {}
-- (every module's callback of a path runs, as in UE4SS)
local hook_fail = {}   -- [path] = true: this game build has no such function
RegisterHook = function(path, fn)
  if hook_fail[path] then error("UFunction not found: " .. path) end
  hooks[path] = hooks[path] or {}; table.insert(hooks[path], fn); return 1, 2
end
local function call_hooks(path, ...)
  local list = hooks[path]
  if not list then return false end
  for _, fn in ipairs(list) do fn(...) end
  return true
end
NotifyOnNewObject = function() end
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
local JIG_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"

local function S(fields) return setmetatable({}, { __index = function(_, k) tick_cost(); return fields[k] end }) end
local function P(e) return { get = function() tick_cost(); return e end } end
local function A(list)
  return {
    ForEach = function(_, f) tick_cost(); for i, e in ipairs(list) do if f(i, P(e)) == true then break end end end,
    GetArrayNum = function() tick_cost(); return #list end,
  }
end
local function G(a) return S({ A = a, B = 0, C = 0, D = 0 }) end
local DA = { __name = "DA_Bandage" }

-- the item with this uid: item, container, container index, item index
local function find_item(conts, uid)
  for ci, c in ipairs(conts) do
    for ii, it in ipairs(c.items) do if it.uid == uid then return it, c, ci, ii end end
  end
end
local function remove_item(conts, uid)
  local it, c, _, ii = find_item(conts, uid)
  if it then table.remove(c.items, ii) end
  return it
end

local function make_jig(name, conts)
  local jig = { __name = name, conts = conts }
  setmetatable(jig, { __index = function(_, k)
    if k ~= "MainJigContainers" then return nil end
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
  -- the plugin's wear call; the game's own hook of it fires after the body
  rawset(jig, "ServerFuncUpdateDurabilityByUID", function(self, g, minus, _, out)
    local it = find_item(conts, g.A)
    if it then it.dur = math.max(0, it.dur - minus); out.NewDur = it.dur end
    call_hooks(JIG_FN .. "ServerFuncUpdateDurabilityByUID", P(self), P(g), P(minus), P(false), P(out))
  end)
  rawset(jig, "SERVER_RequestRemoveItem", function(_, _, g, n)
    local it, c, _, ii = find_item(conts, g.A)
    if it then it.n = it.n - n; if it.n <= 0 then table.remove(c.items, ii) end end
  end)
  rawset(jig, "CLIENT_UpdateCount", function(_, _, g, n) cuc[#cuc + 1] = string.format("%s:%s", tostring(g.A), tostring(n)) end)
  return jig
end

local function std_inventory(n_conts)
  local conts = {
    { uid = 1, items = { { uid = 10, n = 1, dur = 90, idx = 0, sub = 2 }, { uid = 20, n = 1, dur = 55.5, idx = 1 },
                         { uid = 30, n = 4, dur = 100, idx = 2 } } },
    { uid = 2, items = { { uid = 11, n = 1, dur = 80, idx = 0, sub = 3 } } },
    { uid = 3, items = { { uid = 12, n = 1, dur = 40, idx = 0 } } },
  }
  local u = 1000
  for ci = 4, n_conts do
    local items = {}
    for ii = 0, 2 do
      u = u + 1
      items[#items + 1] = { uid = u, n = 1 + (u % 7), dur = 100 - (u % 13), idx = ii }
    end
    conts[#conts + 1] = { uid = ci, items = items }
  end
  return conts
end

local function player(i, conts, loc, tag)
  tag = tag or ""
  local pc = { __name = "PC" .. i, NetConnection = { __name = "Conn" .. i } }
  local pawn = { __name = "Char" .. i .. tag, __cls = "BP_PlayerCharacter_C", Controller = pc, Role = 3, __loc = loc,
    MedicalComponent = { __name = "Med" .. i, Health = 40 + i } }
  pc.Pawn = pawn
  local jig = make_jig("Jig" .. i .. tag, conts)
  rawset(jig, "GetOwner", function() return pawn end)
  pawn.BP_JigMultiplayer = jig
  local equip = { { "Jig.PlayerSlot.Headwear", 10 }, { "Jig.PlayerSlot.PrimaryWeapon", 20 } }
  pawn.BP_JigHelperComp = { __name = "Helper" .. i .. tag, RepActorsData = A({}), ServerEquippedItems = {},
    EquipmentUIDs = { ForEach = function(_, f)
      for _, e in ipairs(equip) do if f(P(S({ TagName = e[1] })), P(G(e[2]))) == true then break end end
    end } }
  world.BP_PlayerCharacter_C[#world.BP_PlayerCharacter_C + 1] = pawn
  return { pc = pc, pawn = pawn, jig = jig, conts = conts }
end

-- a game hook fires on the host: fire("SERVER_RequestConsumeItem", jig, args...)
local function fire(name, jig, ...)
  local ps = {}
  for i = 1, select("#", ...) do ps[i] = P((select(i, ...))) end
  return call_hooks(JIG_FN .. name, P(jig), table.unpack(ps, 1, select("#", ...)))
end

-- ------------------------------------------------------------ one session
local function fresh_modules()
  for name in pairs(package.loaded) do
    if name:match("^sdc_") then package.loaded[name] = nil end
  end
  for k, v in pairs(mocks) do package.loaded[k] = v end
end

local function norm(list)
  local out = {}
  for _, m in ipairs(list) do out[#out + 1] = m.pc .. "|" .. m.kind .. "|" .. table.concat(m.args, ",") end
  return out
end

-- the last full walk the tick's readers share: items, counts, durabilities, slots
local function snap_text(CM, jig)
  local e = CM._t.walking.by[jig.__name]
  local fp = e and e.inv and e.inv.fp
  if not fp then return "none" end
  return string.format("%d/%d/%d/%d/%d/%d:%d", fp.nc, fp.ni, fp.uid, fp.cnt, fp.pos, fp.dur, #e.inv.list)
end

local function ledger_text(CM, jig)
  local l = CM._t.ledger()[jig.__name]
  if not l then return "none" end
  local t = {}
  for u, e in pairs(l) do t[#t + 1] = string.format("%s=%s", u, tostring(e.n)) end
  table.sort(t)
  return #t .. ":" .. table.concat(t, ";")
end

-- Builds the world, runs steps_fn(W); W.tick(label, seconds) is the host's 1 s
-- tick (with its delayed slices) and records what every consumer got.
local function session(events, steps_fn)
  fresh_modules()
  logs, sent, cuc, hooks, handlers, delayed = {}, {}, {}, {}, {}, {}
  world.BP_PlayerCharacter_C = {}
  local items = require("sdc_items")
  local CM = require("sdc_consume")
  CM._t.walking.events = events
  items.init({ role = "host", remote_pcs = {} })
  items.register_handlers()
  items.install()
  local big = player(1, std_inventory(80), { X = 0, Y = 0, Z = 0 })
  local small = player(2, std_inventory(4), { X = 100000, Y = 0, Z = 0 })
  local W = { items = items, CM = CM, big = big, small = small, pcs = { big.pc, small.pc }, record = {}, cost = {} }
  function W.tick(label, secs)
    for _ = 1, secs or 1 do
      local o0 = ops
      base = base + TICK
      T = base
      items.host_tick(W.pcs)
      run_all_delayed()
      W.last_cost = ops - o0
    end
    local rec = { label = label, msgs = norm(sent), cuc = table.concat(cuc, ","),
      l1 = ledger_text(CM, W.big.jig), l2 = ledger_text(CM, W.small.jig),
      s1 = snap_text(CM, W.big.jig), s2 = snap_text(CM, W.small.jig) }
    sent, cuc = {}, {}
    W.record[#W.record + 1] = rec
    return rec
  end
  steps_fn(W)
  return W
end

local function warnings()
  local out = {}
  for _, l in ipairs(logs) do if l:find("^warn") or l:find("^err") then out[#out + 1] = l end end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------ the script
-- Every change is followed by what the game does: the request's hook and the
-- plugin's answers (the signals the walks wait for).
local function script(W)
  local big, small, CM = W.big, W.small, W.CM
  W.tick("start")
  W.tick("idle", 14)
  -- looting: items moved, picked up, stacked
  for round = 1, 4 do
    local it = remove_item(big.conts, 1000 + round)
    it.idx = 5; it.dur = it.dur - 1
    table.insert(big.conts[40 + round].items, it)
    fire("SERVER_RequestMoveItemToAnotherComp", big.jig)
    fire("MC_MoveItemToIndex", big.jig)
    table.insert(big.conts[10].items, { uid = 5000 + round, n = 3, dur = 100, idx = 3 + round })
    fire("SERVER_RequestAddActorToContainer", big.jig)
    fire("TryAddNewItem", big.jig)
    find_item(big.conts, 1100 + round).n = 9
    fire("SERVER_RequestStackItem", big.jig)
    W.tick("loot" .. round)
  end
  -- the small player loots too; the big one is idle: only the small one is walked
  table.insert(small.conts[3].items, { uid = 7001, n = 2, dur = 50, idx = 1 })
  fire("SERVER_RequestAddActorToContainer", small.jig)
  W.tick("small adds")
  -- a use (a bandage x4 -> x3)
  find_item(big.conts, 30).n = 3
  fire("SERVER_RequestConsumeItem", big.jig, big.jig, { A = 30, B = 0, C = 0, D = 0 }, 1, "")
  W.tick("use")
  -- a craft (components 1105 and 1106 gone, the output 7100 comes)
  remove_item(big.conts, 1105)
  remove_item(big.conts, 1106)
  table.insert(big.conts[2].items, { uid = 7100, n = 1, dur = 100, idx = 1 })
  fire("SERVER_RequestCraftItem", big.jig, nil, 0, A({ G(1105), G(1106) }))
  W.tick("craft")
  -- the host's own grant (sdc_place / sdc_world)
  table.insert(big.conts[20].items, { uid = 7200, n = 5, dur = 100, idx = 3 })
  CM.renew_ledger(big.jig)
  W.tick("grant")
  -- the game's own add (a fish, a well's water): JigTryAddItemSomewhere on that player's component
  table.insert(big.conts[21].items, { uid = 7300, n = 2, dur = 100, idx = 3 })
  fire("JigTryAddItemSomewhere", big.jig, big.jig, DA, 2, true)
  W.tick("game add")
  -- equip: the helmet goes to another container
  local h = remove_item(big.conts, 10)
  h.idx = 0
  table.insert(big.conts[30].items, h)
  fire("SERVER_RequestEquipActorToContainer", big.jig)
  W.tick("equip")
  -- a shot's wear of the weapon, a repair of it
  big.jig:ServerFuncUpdateDurabilityByUID({ A = 20, B = 0, C = 0, D = 0 }, 0.5, false, {})
  W.tick("shot")
  find_item(big.conts, 20).dur = 99
  fire("ServerFunc_UpdateDurabilityByUID", big.jig)
  W.tick("repair")
  -- the night vision on: the host drains the battery each tick
  handlers.MYNVG({ "1" }, big.pc)
  W.tick("nvg on", 4)
  handlers.MYNVG({ "0" }, big.pc)
  W.tick("nvg off", 2)
  -- a ghost check: the client shows 999 (not here) and 1107 (here)
  base = base + 5
  handlers.GHOSTQ({ "999:0:0:0;1107:0:0:0" }, big.pc)
  W.tick("ghost")
  -- the player's own game loads its inventory again
  fire("SERVER_RequestDataFromSave", big.jig)
  W.tick("data request")
  -- death and respawn of the small player: another character, another inventory
  world.BP_PlayerCharacter_C = { big.pawn }
  local fresh = player(2, std_inventory(4), { X = 5, Y = 0, Z = 0 }, "b")
  fresh.conts[1].items[1].dur = 60
  small.pc.Pawn = fresh.pawn
  W.small = fresh
  W.tick("respawn")
  W.tick("idle 3", 12)
end

print("the same session, old continuous walk and new event-driven walk:")
local old = session(false, script)
local old_warn = warnings()
local new = session(true, script)
local new_warn = warnings()

local same_all, n_diff = true, 0
for i, a in ipairs(old.record) do
  local b = new.record[i]
  local ok = b and a.label == b.label and table.concat(a.msgs, "\n") == table.concat(b.msgs, "\n") and a.cuc == b.cuc
    and a.l1 == b.l1 and a.l2 == b.l2 and a.s1 == b.s1 and a.s2 == b.s2
  if not ok then
    same_all, n_diff = false, n_diff + 1
    print("  step " .. a.label .. " differs:")
    local inb, ina = {}, {}
    for _, m in ipairs(b and b.msgs or {}) do inb[m] = true end
    for _, m in ipairs(a.msgs) do ina[m] = true end
    for _, m in ipairs(a.msgs) do if not inb[m] then print("    only old: " .. m:sub(1, 160) .. " ... " .. m:sub(-90)) end end
    for _, m in ipairs(b and b.msgs or {}) do if not ina[m] then print("    only new: " .. m:sub(1, 160) .. " ... " .. m:sub(-90)) end end
    print("    old snapshot: " .. a.s1 .. " | " .. a.s2 .. "   new: " .. (b and (b.s1 .. " | " .. b.s2) or "-"))
    print("    old ledger: " .. a.l1:sub(1, 60) .. " | " .. a.l2:sub(1, 40) .. " | cuc " .. a.cuc)
    print("    new ledger: " .. (b and (b.l1:sub(1, 60) .. " | " .. b.l2:sub(1, 40) .. " | cuc " .. b.cuc) or "-"))
  end
end
check(#old.record == #new.record and #old.record > 15, "both runs recorded the same steps: " .. #old.record)
check(same_all, "every consumer's result is identical in every step (UIDS / ITEMS / PTOOLS, ledger, ghost answers): " .. n_diff .. " steps differ")
check(old_warn == new_warn, "the same warnings and errors in the log")
do
  -- the placement rescue's scan looks at the (unchanged) snapshot every tick, as it did
  local R = new.CM.stats and require("sdc_place")._t.R
  check(R.seen_at["Jig1"] ~= nil and base - R.seen_at["Jig1"] < 1, "sdc_place's scan still runs every tick on the snapshot (its retry cadence)")
end
local any_uids, any_items, any_ptools, any_ghost = false, false, false, false
for _, r in ipairs(new.record) do
  for _, m in ipairs(r.msgs) do
    if m:find("|UIDS|", 1, true) then any_uids = true end
    if m:find("|ITEMS|", 1, true) then any_items = true end
    if m:find("|PTOOLS|", 1, true) then any_ptools = true end
  end
  if r.cuc ~= "" then any_ghost = true end
end
check(any_uids and any_items and any_ptools and any_ghost, "the session sent UIDS, ITEMS and PTOOLS and answered a ghost check (the comparison is not empty)")
local nerr = 0
for _, l in ipairs(logs) do if l:find("^err") then nerr = nerr + 1; print("    " .. l) end end
check(nerr == 0, "no error logged in the new run")
check(new.CM.stats.signals > 20 and new.CM.stats.walks_full < old.CM.stats.walks_full / 2,
  string.format("far fewer full walks: %d (continuous: %d), signals seen: %d", new.CM.stats.walks_full, old.CM.stats.walks_full, new.CM.stats.signals))
check(new.CM.stats.verify_diffs == 0, "the 10 s check found nothing the signals had missed in the session: " .. new.CM.stats.verify_diffs)

-- ------------------------------------------------------------ the ghost check reads fresh
print("the ghost check reads the inventory itself:")
do
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
  remove_item(W.big.conts, 1001)   -- (no signal: the snapshot still has it)
  base = base + 5
  handlers.GHOSTQ({ "1001:0:0:0;999:0:0:0" }, W.big.pc)
  check(#cuc == 2, "both unknown items ended (1001 was removed here; an old snapshot would have said 'held'): " .. table.concat(cuc, ","))
end

-- ------------------------------------------------------------ a change no signal reaches
print("a change with no signal:")
do
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
  local walks0 = W.CM.stats.walks_full
  find_item(W.big.conts, 1050).n = 77   -- (no hook fires)
  local function ledger_n() return W.CM._t.ledger()["Jig1"]["1050:0:0:0"].n end
  local before = ledger_n()
  W.tick("silent 1", 3)
  check(W.CM.stats.walks_full == walks0 and ledger_n() == before, "not walked within the verify time (the snapshot is old: the declared trade-off)")
  W.tick("silent 2", 8)
  check(W.CM.stats.verify_diffs == 1 and ledger_n() == 77, "the 10 s check found it and walked again: ledger x" .. tostring(ledger_n()))
  local found = false
  for _, l in ipairs(logs) do if l:find("with no change signal", 1, true) then found = true end end
  check(found, "and said so in the log")
  local w1 = W.CM.stats.walks_full
  W.tick("quiet", 25)
  check(W.CM.stats.walks_full == w1, "then nothing is walked again")
  local W2 = session(false, function(W) W.tick("start"); W.tick("idle", 2) end)
  find_item(W2.big.conts, 1050).n = 77
  W2.tick("silent")
  check(W2.CM._t.ledger()["Jig1"]["1050:0:0:0"].n == 77, "(the continuous walk saw it at the next tick)")
  -- a count that stays the same but the item moved elsewhere: the check sees slots too
  local W3 = session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
  local it = remove_item(W3.big.conts, 1060)
  table.insert(W3.big.conts[70].items, it)
  it.idx = 9
  W3.tick("moved silently", 11)
  check(W3.CM.stats.verify_diffs == 1, "a silent move between containers is found too")
  -- a durability only
  local W4 = session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
  find_item(W4.big.conts, 1070).dur = 12.34
  W4.tick("silent dur", 11)
  check(W4.CM.stats.verify_diffs == 1, "a silent durability change is found too")
end

-- ------------------------------------------------------------ a signal under a walk in slices
print("a change signal while a walk is going on in slices:")
do
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 2) end)
  -- a first move starts a walk in slices (the big inventory is over SYNC_MS) ...
  local it = remove_item(W.big.conts, 1002)
  table.insert(W.big.conts[60].items, it)
  fire("MC_MoveItemToIndex", W.big.jig)
  base = base + TICK
  T = base
  W.items.host_tick(W.pcs)
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do d.fn() end   -- (one frame: the first slice)
  check(#delayed > 0 and W.CM._t.walking.by["Jig1"].job ~= nil, "the walk of the big inventory is under way (in slices)")
  -- ... and a new item arrives in a container the walk has already read
  table.insert(W.big.conts[2].items, { uid = 5100, n = 1, dur = 100, idx = 5 })
  fire("TryAddNewItem", W.big.jig)
  run_all_delayed()
  W.tick("after")
  local seen = false
  for _, m in ipairs(W.record[#W.record].msgs) do if m:find("5100:0:0:0=100.0", 1, true) then seen = true end end
  check(seen, "the walk started over: the next ITEMS has the new item, not an old walk's")
  check(W.CM.stats.walk_restarts >= 1, "(restarts: " .. W.CM.stats.walk_restarts .. ")")
end

-- ------------------------------------------------------------ durability in place
print("durability in place:")
do
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 2) end)
  local walks0 = W.CM.stats.walks_full
  for i = 1, 20 do
    W.big.jig:ServerFuncUpdateDurabilityByUID({ A = 20, B = 0, C = 0, D = 0 }, 0.25, false, {})
    W.tick("shot " .. i)
  end
  check(W.CM.stats.walks_full == walks0 and W.CM.stats.dur_patched == 20,
    "20 shots in 20 s: no walk, each written into the snapshot (" .. W.CM.stats.dur_patched .. ")")
  check(W.CM.stats.verify_diffs == 0, "and the 10 s check agrees with the patched snapshot")
  local u = nil
  for _, r in ipairs(W.record) do for _, m in ipairs(r.msgs) do if m:find("PrimaryWeapon=20:0:0:0@", 1, true) then u = m end end end
  check(u ~= nil and u:find("@50.50", 1, true) ~= nil, "UIDS carries the worn weapon's new durability: " .. tostring(u))
  -- the hook cannot read the new value: a change signal, the walk follows
  local w1 = W.CM.stats.walks_full
  call_hooks(JIG_FN .. "ServerFuncUpdateDurabilityByUID", P(W.big.jig), P({ A = 20, B = 0, C = 0, D = 0 }), P(1), P(false), P(nil))
  W.tick("unreadable")
  check(W.CM.stats.walks_full == w1 + 1, "an unreadable value is a change signal (a walk)")
end

-- ------------------------------------------------------------ every signal, for the right player only
print("every change signal marks the right player's inventory:")
-- (the functions that run on the host: the plugin's multicasts, its server-side add / remove / pay / write
-- functions and the SERVER_* requests; the CLIENT_* RPCs never fire there and are not in the list)
local SELF_SIGNALS = {
  "MC_AddNewItem", "MC_ItemRemoved", "MC_MoveItemToIndex", "MC_UpdateStack", "MC_UpdateCount", "MC_UpdateCounts",
  "MC_NewItemAdded", "MC_SameCompUpdateSplitRequest", "TryAddNewItem", "RemoveGetInfo", "AddNewItemToSlot",
  "FireArmChamberWeapon", "HandleTwoContainerSwap", "TakeMoney", "UpdateStatByUID", "ServerFunc_UpdateCustomDataByUID",
  "ServerFunc_UpdateDurabilityByUID", "ServerUpdateCountByUID", "ServerFindThenConsumeByItemID",
  "ServerFunc_HandleMoveToCapacityContainer", "ServerHandleSplitRequest", "ServerFunc_RequestStackItem",
  "HandleServerDropRequest", "HandleLocalRequestConsumeItem", "ServerFuncHandleEquipActor", "HandleMainPlayerRequestedData",
  -- the requests the handlers of this module see (ledger list, use, craft, remove, load)
  "SERVER_RequestAddActorToContainer", "SERVER_RequestActorAddStackItem", "SERVER_RequestEquipActorToContainer",
  "SERVER_RequestMoveItemToAnotherComp", "SERVER_RequestSplitItem", "SERVER_RequestStackItem", "SERVER_RequestReload",
  "SERVER_RequestReloadInternal", "SERVER_SameContainer_MoveToIndex", "SERVER_RequestRemoveItem",
  "SERVER_RequestConsumeItem", "SERVER_RequestCraftItem", "SERVER_RequestDataFromSave", "JigTryAddItemSomewhere",
}
local PARAM_SIGNALS = { "SERVER_RequestDropItem", "SERVER_RequestData", "SERVER_LoadSaveDataFromClientSide",
  "SERVER_RequestLoadReplaceOneContainerByIndex", "SERVER_RequestSwapContainers", "SERVER_UpdateStatByUID" }
do
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 2) end)
  local by = W.CM._t.walking.by
  local function sigs() return by["Jig1"].sig, by["Jig2"].sig end
  local function expect(name, fn)
    local a1, a2 = sigs()
    local ok, err = pcall(fn)
    local b1, b2 = sigs()
    check(ok and b1 > a1 and b2 == a2, name .. ": the right player's inventory marked, the other not" .. (ok and "" or (" (" .. tostring(err) .. ")")))
  end
  for _, name in ipairs(SELF_SIGNALS) do
    expect(name, function()
      -- (a request on a component whose target is itself: ids as the game passes them)
      assert(fire(name, W.big.jig, W.big.jig, { A = 1000, B = 0, C = 0, D = 0 }, 1, ""), "no hook registered")
    end)
  end
  for _, name in ipairs(PARAM_SIGNALS) do
    expect(name, function() assert(fire(name, W.big.jig), "no hook registered") end)
    -- a component named in a parameter (a move / drop into another component) is marked too
    local ud = io.tmpfile()
    proxies[ud] = W.small.jig
    local a1, a2 = sigs()
    fire(name, W.big.jig, ud)
    local b1, b2 = sigs()
    check(b1 > a1 and b2 > a2, name .. ": the component in its parameters is marked too")
    proxies[ud] = nil
    ud:close()
  end
  -- the durability call: a value that is read goes in place, a destroy or an unreadable one is a signal
  local function dur(destroy, value)
    local out = { NewDur = value }
    return call_hooks(JIG_FN .. "ServerFuncUpdateDurabilityByUID", P(W.big.jig), P({ A = 20, B = 0, C = 0, D = 0 }), P(1), P(destroy), P(value and out or nil))
  end
  local a1 = sigs()
  local p0 = W.CM.stats.dur_patched
  dur(false, 44)
  check(W.CM.stats.dur_patched == p0 + 1 and (sigs()) == a1, "a readable durability is written in place (no signal)")
  dur(true, 44)
  check((sigs()) == a1 + 1 and W.CM.stats.dur_patched == p0 + 1, "an item destroyed at 0 durability is a signal")
  local u0 = W.CM.stats.dur_unread
  dur(false, nil)
  check((sigs()) == a1 + 2 and W.CM.stats.dur_unread == u0 + 1, "an unreadable value is a signal and is counted (dur_unread)")
  -- the hooks of the host's own character / world containers touch nothing
  local before1, before2 = sigs()
  fire("TryAddNewItem", { __name = "WorldChest" })
  check(select(1, sigs()) == before1 and select(2, sigs()) == before2, "a call on a component that is no remote player's changes nothing")
  -- the module's own handlers
  local d1 = sigs()
  W.CM.host_drop_report(P(W.big.jig), P({ A = 1001, B = 0, C = 0, D = 0 }), P(1), P(W.big.jig))
  check((sigs()) > d1, "the drop report marks the inventory")
end

-- ------------------------------------------------------------ what the log says about the hooks
print("the hook lines:")
do
  local function count(pat) local n = 0; for _, l in ipairs(logs) do if l:find(pat, 1, true) then n = n + 1 end end; return n end
  session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
  local ok_lines = 0
  for _, l in ipairs(logs) do if l:find("^info: consume: %d+ change%-signal hooks ok") then ok_lines = ok_lines + 1 end end
  check(ok_lines == 1 and count("could not be installed") == 0, "all installed: one INFO line 'change-signal hooks ok', no warning")
  hook_fail[JIG_FN .. "TakeMoney"], hook_fail[JIG_FN .. "FireArmChamberWeapon"] = true, true
  session(true, function(W) W.tick("start"); W.tick("idle", 40) end)
  local warn
  for _, l in ipairs(logs) do if l:find("change-signal hook(s) could not be installed", 1, true) then warn = l end end
  check(warn ~= nil and warn:find("TakeMoney", 1, true) and warn:find("FireArmChamberWeapon", 1, true) and warn:find("^warn") ~= nil
    and count("could not be installed") == 1 and count("change-signal hooks ok") == 0,
    "some missing: one WARN naming them, no 'hooks ok': " .. tostring(warn and warn:sub(1, 120)))
  hook_fail = {}
end

-- ------------------------------------------------------------ the CLIENT_* RPCs are not relied on
print("no hook on the Client RPCs, none before a remote player is here:")
do
  local W = session(true, function(W) W.tick("start") end)
  for _, name in ipairs({ "CLIENT_AddNewItem", "CLIENT_ItemRemoved", "CLIENT_UpdateStack", "CLIENT_UpdateCount", "CLIENT_UpdateCounts",
                          "CLIENT_MoveItemToIndex", "CLIENT_NewItemAdded", "Client_SameCompUpdateSplitRequest" }) do
    check(hooks[JIG_FN .. name] == nil, name .. " is not hooked on the host (its body never runs there)")
  end
  -- no remote player: no signal hooks (each BP call walks the hook list)
  fresh_modules()
  hooks, handlers, delayed = {}, {}, {}
  local items = require("sdc_items")
  items.init({ role = "host", remote_pcs = {} })
  items.register_handlers()
  items.install()
  base = base + TICK; T = base
  items.host_tick({})
  check(hooks[JIG_FN .. "TryAddNewItem"] == nil and hooks[JIG_FN .. "RemoveGetInfo"] == nil, "no remote player: the change-signal hooks are not registered")
  local p = player(1, std_inventory(4), { X = 0, Y = 0, Z = 0 }, "x")
  base = base + TICK; T = base
  items.host_tick({ p.pc })
  check(hooks[JIG_FN .. "TryAddNewItem"] ~= nil, "the first remote player: they are registered at once")
end

-- ------------------------------------------------------------ the paths the review found
print("changes that used to go unseen for 10 s:")
do
  -- (2a) a new stack that only Generate_AddNewItemToContainer made: TryAddNewItem runs, the next ITEMS has it
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
  table.insert(W.big.conts[12].items, { uid = 8001, n = 5, dur = 100, idx = 9 })
  fire("TryAddNewItem", W.big.jig)
  W.tick("new stack")   -- (a big inventory is walked in slices after this tick: its ITEMS goes with the next one, as ever)
  local rec = W.tick("new stack 2")
  local seen = false
  for _, m in ipairs(rec.msgs) do if m:find("8001:0:0:0=100.0", 1, true) then seen = true end end
  check(seen, "a new stack (a harvest's wood / rock): in ITEMS a tick later, not 10 s, so the client's craft is not held back")
  -- (2b) the chamber after a reload / shot
  find_item(W.big.conts, 1010).n = 1
  fire("FireArmChamberWeapon", W.big.jig)
  W.tick("chamber")
  check(W.CM._t.walking.by["Jig1"].inv.by_uid["1010:0:0:0"].n == 1, "a round moved to the chamber: in the snapshot at the next tick")
  -- (2c) payment
  find_item(W.big.conts, 1011).n = 2
  fire("TakeMoney", W.big.jig)
  W.tick("money")
  check(W.CM._t.walking.by["Jig1"].inv.by_uid["1011:0:0:0"].n == 2, "a payment (TakeMoney): in the snapshot at the next tick")
  -- (2d) swap of two containers
  local it = remove_item(W.big.conts, 1012)
  table.insert(W.big.conts[13].items, it)
  it.idx = 8
  fire("HandleTwoContainerSwap", W.big.jig)
  W.tick("swap")
  check(W.CM._t.walking.by["Jig1"].inv.fp.pos ~= nil and W.CM.stats.verify_diffs == 0, "a container swap: seen at the next tick, the 10 s check agrees")
  -- the ghost check: items the client lists that the snapshot lacked (no signal): the snapshot is renewed
  table.insert(W.big.conts[14].items, { uid = 8002, n = 1, dur = 100, idx = 9 })
  base = base + 5
  handlers.GHOSTQ({ "8002:0:0:0" }, W.big.pc)
  W.tick("ghost held")
  local rec2 = W.tick("ghost held 2")
  local seen2 = false
  for _, m in ipairs(rec2.msgs) do if m:find("8002:0:0:0=100.0", 1, true) then seen2 = true end end
  check(seen2 and #cuc == 0, "the ghost check found it here: the snapshot is walked again (ITEMS has it), nothing ended")
end

-- ------------------------------------------------------------ the fingerprint sees these
print("the fingerprint:")
do
  local function silent(change, what)
    local W = session(true, function(W) W.tick("start"); W.tick("idle", 3) end)
    change(W)
    W.tick("silent", 8)
    check(W.CM.stats.verify_diffs == 1, what)
  end
  silent(function(W) find_item(W.big.conts, 1030).uid = 9030 end, "an item with another UID, the same everything else")
  silent(function(W) table.insert(W.big.conts, { uid = 99, items = {} }) end, "a new empty container")
  silent(function(W)
    local a, b = find_item(W.big.conts, 1040), find_item(W.big.conts, 1041)
    a.n, b.n = b.n + 1, a.n - 1   -- (the same total, counts moved between two stacks)
    if a.n == b.n then a.n = a.n + 1; b.n = b.n - 1 end
  end, "a count moved between two stacks with the same total")
  silent(function(W) find_item(W.big.conts, 1042).dur = find_item(W.big.conts, 1042).dur - 0.4 end, "a durability only")
end

-- ------------------------------------------------------------ the old switch
print("inventory_walk_events = false:")
do
  cfgv.inventory_walk_events = false
  local W = session(true, function(W) W.tick("start"); W.tick("warm", 2) end)   -- (events on in the code, off in the config)
  local w0 = W.CM.stats.walks_full
  W.tick("idle", 6)
  check(W.CM.stats.walks_full - w0 >= 12, "every tick walks every inventory again (" .. (W.CM.stats.walks_full - w0) .. " walks in 6 ticks, 2 players)")
  find_item(W.big.conts, 1050).n = 77   -- (no signal)
  W.tick("silent")
  check(W.CM._t.ledger()["Jig1"]["1050:0:0:0"].n == 77, "a change with no signal is seen at the next tick")
  cfgv.inventory_walk_events = nil
  local W2 = session(true, function(W) W.tick("start"); W.tick("warm", 2) end)
  local w1 = W2.CM.stats.walks_full
  W2.tick("idle", 6)
  check(W2.CM.stats.walks_full == w1, "with the config on again: no walk when nothing changed")
end

-- ------------------------------------------------------------ a verify in slices
print("a verify in slices:")
do
  local function setup()
    local W = session(true, function(W) W.tick("start"); W.tick("idle", 2) end)
    W.CM._t.walking.by["Jig1"].vms = 20   -- (the last check took long: the next one goes in slices)
    return W
  end
  local function start_verify(W)
    base = base + 9 * TICK   -- (over VERIFY_S)
    T = base
    W.items.host_tick(W.pcs)
  end
  -- nothing changed: slices, then nothing
  local W = setup()
  local full0, ver0 = W.CM.stats.walks_full, W.CM.stats.verifies
  start_verify(W)
  local j = W.CM._t.walking.by["Jig1"].job
  check(j ~= nil and j.kind == "verify", "the check of the big inventory goes in slices (a job of kind verify)")
  local n = 0
  while delayed[1] and n < 50 do local l = delayed; delayed = {}; for _, d in ipairs(l) do d.fn() end; n = n + 1 end
  check(n >= 2 and W.CM._t.walking.by["Jig1"].job == nil, "it needed several frames (" .. n .. ") and ended")
  check(W.CM.stats.verifies > ver0 and W.CM.stats.walks_full == full0 and W.CM.stats.verify_diffs == 0, "the same fingerprint: nothing more done")
  -- a silent change: found by the sliced check, a full walk follows
  W = setup()
  find_item(W.big.conts, 1050).n = 55
  start_verify(W)
  run_all_delayed()
  check(W.CM.stats.verify_diffs == 1, "a silent change is found by the sliced check")
  W.tick("next")
  check(W.CM._t.ledger()["Jig1"]["1050:0:0:0"].n == 55, "and the full walk of the next tick has it")
  -- a signal under the sliced check: no false 'no change signal'
  W = setup()
  start_verify(W)
  local l = delayed; delayed = {}; for _, d in ipairs(l) do d.fn() end   -- (the first slice)
  table.insert(W.big.conts[2].items, { uid = 8100, n = 1, dur = 100, idx = 4 })
  fire("TryAddNewItem", W.big.jig)
  run_all_delayed()
  check(W.CM.stats.verify_diffs == 0, "a signal that came under the check explains the difference: not counted as a missed one")
  W.tick("next")
  check(W.CM._t.walking.by["Jig1"].inv.by_uid["8100:0:0:0"] ~= nil, "and its walk follows")
end

-- ------------------------------------------------------------ a walk with a read error
print("a read error:")
do
  local W = session(true, function(W) W.tick("start"); W.tick("idle", 2) end)
  local e = W.CM._t.walking.by["Jig2"]
  e.inv.bad = "boom"
  local w0 = W.CM.stats.walks_full
  W.tick("retry")
  check(W.CM.stats.walks_full > w0 and not W.CM._t.walking.by["Jig2"].inv.bad, "a walk that could not read everything is tried again at the next tick")
  -- a persistent one: walked every tick, said once
  local function say_count() local n = 0; for _, l in ipairs(logs) do if l:find("cannot be read in full", 1, true) then n = n + 1 end end; return n end
  for _ = 1, 3 do W.CM._t.walking.by["Jig2"].inv.bad = "boom"; W.tick("bad") end
  check(say_count() == 1, "an inventory that never reads cleanly is said once (an INFO line), not every tick: " .. say_count())
end

-- ------------------------------------------------------------ the cost
print("the cost (engine accesses per second, a simulated 3 us each):")
local function measure(events, busy)
  local keep_tick = TICK
  TICK = 1   -- (the game's tick: once a second)
  local W = session(events, function(W) W.tick("start"); W.tick("warm", 12) end)
  local secs = busy and 20 or 60
  local total, peak = 0, 0
  for s = 1, secs do
    if busy then
      -- looting: three things move in the big inventory each second
      for r = 1, 3 do
        local it, c, _, ii = find_item(W.big.conts, 1000 + ((s * 3 + r) % 200) + 1)
        if it and #c.items > 1 then
          table.remove(c.items, ii)
          it.idx = 7
          table.insert(W.big.conts[2 + (s + r) % 78].items, it)
          fire("SERVER_RequestMoveItemToAnotherComp", W.big.jig)
          fire("MC_MoveItemToIndex", W.big.jig)
        end
      end
    end
    W.tick("s" .. s)
    total = total + W.last_cost
    if W.last_cost > peak then peak = W.last_cost end
  end
  TICK = keep_tick
  return total / secs, peak   -- (per second of game time)
end
do
  local W = session(true, function(W) W.tick("start") end)
  local n = 0
  for _, c in ipairs(W.big.conts) do n = n + #c.items end
  print(string.format("  the big inventory: %d containers, %d items", #W.big.conts, n))
  check(#W.big.conts == 80 and n >= 200, "80 containers / 200+ items")
end
local idle_old, idle_old_peak = measure(false, false)
local idle_new, idle_new_peak = measure(true, false)
local busy_old, busy_old_peak = measure(false, true)
local busy_new, busy_new_peak = measure(true, true)
local function ms(x) return x * COST * 1000 end
print(string.format("  idle:  before %7.0f accesses/s = %5.2f ms/s (worst second %5.1f ms) | after %6.0f = %5.2f ms/s (worst second %5.1f ms) = %.1f%%",
  idle_old, ms(idle_old), ms(idle_old_peak), idle_new, ms(idle_new), ms(idle_new_peak), 100 * idle_new / idle_old))
print(string.format("  busy:  before %7.0f accesses/s = %5.2f ms/s (worst second %5.1f ms) | after %6.0f = %5.2f ms/s (worst second %5.1f ms) = %.1f%%",
  busy_old, ms(busy_old), ms(busy_old_peak), busy_new, ms(busy_new), ms(busy_new_peak), 100 * busy_new / busy_old))
check(idle_new < 0.1 * idle_old, string.format("idle: under a tenth of the continuous cost (%.1f%%)", 100 * idle_new / idle_old))
check(busy_new <= busy_old * 1.02, string.format("busy looting: never more than the continuous walk (%.1f%%)", 100 * busy_new / busy_old))

print(string.format("mock_consume_walk_events: %d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
