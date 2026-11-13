-- Loop reload capacity (2026-11-13, user report: a client's sawn-off loaded
-- 42 shells; capacity 6 per DA_SawnOffShotgunLoader). sdc_reloadcap.
--   The game: the OWNER's machine decides each round (Cap == Max: full;
--   Max - Cap == 1: the last one) on its own widget count; the host's
--   HandleLocalInternalReload adds +1 to the loader's stack with no capacity
--   check and answers with absolute counts (CLIENT_UpdateCounts, or
--   CLIENT_NewItemAdded for a first stack; nothing when it finds no stack).
--   Client fix: each own request is counted on the own widgets at once
--   (ClientUpdateCount), reconciled with the host's absolute answers.
--   Host rule: the loader never keeps more than its capacity; the extra goes
--   back onto ammo stacks (else at the feet); RLNOTE tells the player.
-- The game is simulated: the client's loop on its widgets, the host's insert,
-- both reliable channels with their delays, frame hitches.
-- usage: lua mock_reloadcap.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------------------
-- mocks
-- ---------------------------------------------------------------------------
local T = 0
local real_clock = os.clock
os.clock = function() return T end

local logs, toasts = {}, {}
local log = setmetatable({ debug_enabled = false }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
log.toast = function(text, kind, seconds, log_text) toasts[#toasts + 1] = { text = text, kind = kind, log = log_text } end
local function logged(pat, plain)
  for _, l in ipairs(logs) do if l:find(pat, 1, plain) then return true end end
  return false
end

local ue = setmetatable({ ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }, { __index = function()
  return function() return nil end
end })
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return o.__path or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.str(v) if type(v) == "string" then return v end return "" end
local local_pawn = nil
function ue.local_pawn() return local_pawn end
local delays, everys = {}, {}
function ue.delay(label, ms, fn) delays[#delays + 1] = { label = label, fn = fn } end
function ue.every(label, ms, fn) everys[label] = fn end
function ue.hook_native() return true end
function ue.find_all() return {} end

local hooks = {}
RegisterHook = function(path, post) hooks[path] = post; return 1, 2 end
FName = function(s) return s end

local sent = {}
local up_sent = {}   -- client -> host messages
local handlers = {}
local cfgv = { reload_cap_fix = true }
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function(k) if cfgv[k] ~= nil then return cfgv[k] end return true end }
package.loaded["sdc_net"] = {
  send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc, kind = kind, f = { ... } } end,
  send_to_host = function(kind, ...) up_sent[#up_sent + 1] = { kind = kind, f = { ... } } end, broadcast = function() end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__name or nil end }
package.loaded["sdc_appearance"] = { player_id = function(p) return p and p.__id end }
package.loaded["sdc_items"] = { equipped_of = function() return {} end }
package.loaded["sdc_i18n"] = { T = function(key, ...)
  local parts = { key }
  for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
  return table.concat(parts, " ")
end }

local combat = require("sdc_combat")
local rc = combat.reloadcap
check(type(rc) == "table" and rc == package.loaded["sdc_reloadcap"], "sdc_combat drives sdc_reloadcap")
-- (without the module: a stand-in, so every check below reports instead of crashing)
rc = rc or { stats = { over = 0, ended = 0 }, reset = function() end, status_line = function() return "" end }
local S = { role = "host", remote_pcs = {} }
combat.init(S)
combat.register_handlers()
combat.install()
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local RPC, REQ = JIG .. "SERVER_RequestReloadInternal", JIG .. "JigComp_CallRequestReloadInternal"
local H_COUNTS, H_NEW, H_COUNT = JIG .. "CLIENT_UpdateCounts", JIG .. "CLIENT_NewItemAdded", JIG .. "CLIENT_UpdateCount"
local H_CHAMBER = JIG .. "JigComp_CallServerChamberWeapon"
local START = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Jig_StartReloading"
check(hooks[RPC] and hooks[REQ] and hooks[H_COUNTS] and hooks[H_NEW] and hooks[H_COUNT] and hooks[START] and hooks[H_CHAMBER],
  "hooks: SERVER_RequestReloadInternal (host), JigComp_CallRequestReloadInternal + CLIENT_UpdateCounts / NewItemAdded / UpdateCount / CallServerChamberWeapon + BP_FirearmPickup.Jig_StartReloading (client)")
check(handlers.RLNOTE ~= nil and handlers.RLFULL == nil, "RLNOTE handler (the player's note); no RLFULL / montage stop any more")
check(rc._t ~= nil and everys["reloadcap-expire"] ~= nil, "client expiry tick")
local function nohook() end
local function hk(p) return hooks[p] or nohook end
local function expire_tick() if rc._t then rc._t.expire_tick() end end
local EXPIRE_S = rc._t and rc._t.PRED_EXPIRE_S or 5

-- ---------------------------------------------------------------------------
-- the host's data (MainJigContainers) and the game's own functions
-- ---------------------------------------------------------------------------
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_HOLDER = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF"
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_UC_UID = "UID_2_DC6DBB72457305316FAC19A4399A1CB5"
local F_UC_COUNT = "NewCount_5_31E28E124BF695AFBB001A87164F9121"
local ZERO = { A = 0, B = 0, C = 0, D = 0 }

local function arr(list)
  return { list = list, ForEach = function(self, cb)
    for i, e in ipairs(self.list) do
      if cb(i, { get = function() return e end }) == true then break end
    end
  end }
end
local function guid(n) return { A = n, B = -7, C = 0, D = n * 3 } end
local function gs(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end

local DA_AMMO = { __name = "DA_12GaugeAmmo", MaxStack = 1000 }
local DA_SLUG = { __name = "DA_12GaugeSlug", MaxStack = 1000 }
local DA_LOADER = { __name = "DA_SawnOffShotgunLoader", ContainerCapacity = 6 }
local DA_GUN = { __name = "DA_SawnOffShotgun", ContainerCapacity = 0, ItemType = { TagName = "Jig.ItemType.Sidearm" } }
local DA_PANTS = { __name = "DA_Pants", ContainerCapacity = 0 }
local DA_MAG = { __name = "DA_SpareLoader", ContainerCapacity = 8 }

local G_LOADER_GRID, G_POCKET, G_GUN_SLOTS, G_CHAMBER = guid(900), guid(901), guid(902), guid(903)
local U_LOADER, U_GUN, U_PANTS = guid(10), guid(11), guid(12)
local U_LOADED, U_RESERVE = guid(20), guid(21)

local function item(g, da, n) return { [F_USID] = g, [F_INFO] = { [F_COUNT] = n, [F_ITEMID] = da } } end
local function cont(g, holder, items) return { [F_CONT_UID] = g, [F_HOLDER] = holder, [F_ITEMS] = arr(items) } end

local walks = 0
local function make_jig(owner, loaded, reserve)
  local conts = {
    cont(guid(800), guid(0), { item(U_PANTS, DA_PANTS, 1), item(U_GUN, DA_GUN, 1) }),
    cont(G_GUN_SLOTS, U_GUN, { item(U_LOADER, DA_LOADER, 1) }),
    cont(G_LOADER_GRID, U_LOADER, loaded > 0 and { item(U_LOADED, DA_AMMO, loaded) } or {}),
    cont(G_POCKET, U_PANTS, reserve > 0 and { item(U_RESERVE, DA_AMMO, reserve) } or {}),
  }
  local jig = { __name = "BP_JigMultiplayer_host_" .. owner.__name, client_rpcs = {}, refuse = {}, conts = conts,
                fail_reads = 0 }
  jig.MainJigContainers = { list = conts, ForEach = function(self, cb)
    walks = walks + 1
    if jig.fail_reads > 0 then jig.fail_reads = jig.fail_reads - 1; error("read failed") end
    for i, e in ipairs(self.list) do
      if cb(i, { get = function() return e end }) == true then break end
    end
  end }
  function jig.GetOwner() return owner end
  function jig.find(uid)
    for _, c in ipairs(conts) do
      for i, it in ipairs(c[F_ITEMS].list) do
        if gs(it[F_USID]) == uid then return it, c, i end
      end
    end
  end
  function jig.grid(g)
    for _, c in ipairs(conts) do if gs(c[F_CONT_UID]) == gs(g) then return c end end
  end
  function jig.count(g) local it = jig.find(gs(g)); return it and it[F_INFO][F_COUNT] or 0 end
  function jig.total(g)
    local n = 0
    for _, it in ipairs(jig.grid(g)[F_ITEMS].list) do n = n + it[F_INFO][F_COUNT] end
    return n
  end
  function jig.add(g, holder, items) conts[#conts + 1] = cont(g, holder, items) end
  -- BP_JigComponent.ServerUpdateCountByUID(ItemUID, NewCount): the count, no message
  function jig.ServerUpdateCountByUID(self, g, n)
    if self.refuse[gs(g)] then return end
    local it = jig.find(gs(g))
    if it then it[F_INFO][F_COUNT] = n end
    if self.after_set then self.after_set(g) end
  end
  -- CLIENT_UpdateCount(TargetComp, ItemUID, NewCount, RemovedPending): to the owner
  function jig.CLIENT_UpdateCount(self, target, g, n, pending)
    self.client_rpcs[#self.client_rpcs + 1] = { fn = "CLIENT_UpdateCount", g = { A = g.A, B = g.B, C = g.C, D = g.D }, n = n }
  end
  return jig
end
local function rounds(jig)
  local n = 0
  for _, c in ipairs(jig.conts) do
    for _, it in ipairs(c[F_ITEMS].list) do
      local da = it[F_INFO][F_ITEMID]
      if da == DA_AMMO or da == DA_SLUG then n = n + it[F_INFO][F_COUNT] end
    end
  end
  return n
end

-- BP_JigComponent.HandleLocalInternalReload (host): same-type stack +1 with
-- no capacity check; else a first stack (CurrentCap < MaxCap); ammo -1
-- (removed at 0); absolute answers. An ammo stack or grid it does not find:
-- nothing, no answer.
local new_n = 0
local function game_insert(jig, mag_g, ammo_g, maxcap)
  local bullet, bc, bi = jig.find(gs(ammo_g))
  local grid = jig.grid(mag_g)
  if not bullet or not grid then return end
  local da = bullet[F_INFO][F_ITEMID]
  local stack = nil
  for _, it in ipairs(grid[F_ITEMS].list) do if it[F_INFO][F_ITEMID] == da then stack = it break end end
  local cur = 0
  for _, it in ipairs(grid[F_ITEMS].list) do cur = cur + it[F_INFO][F_COUNT] end
  local new = false
  if stack then
    stack[F_INFO][F_COUNT] = stack[F_INFO][F_COUNT] + 1
  elseif cur < maxcap then
    new_n = new_n + 1
    stack = item(guid(5000 + new_n), da, 1)
    table.insert(grid[F_ITEMS].list, stack)
    new = true
  else
    return
  end
  bullet[F_INFO][F_COUNT] = bullet[F_INFO][F_COUNT] - 1
  local bn = bullet[F_INFO][F_COUNT]
  if bn == 0 then table.remove(bc[F_ITEMS].list, bi) end
  if new then
    jig.client_rpcs[#jig.client_rpcs + 1] = { fn = "CLIENT_NewItemAdded", g = stack[F_USID], to = mag_g, n = 1, da = da,
                                             upd = { g = ammo_g, n = bn } }
  else
    jig.client_rpcs[#jig.client_rpcs + 1] = { fn = "CLIENT_UpdateCounts",
      counts = { { g = stack[F_USID], n = stack[F_INFO][F_COUNT] }, { g = ammo_g, n = bn } } }
  end
end

local function P(v) return { get = function() return v end } end
local function as(role, fn, ...)
  local old = S.role
  S.role = role
  fn(...)
  S.role = old
end
-- the request on the host: the game's body, then the post-hooks
local function host_request(jig, mag_g, ammo_g, maxcap)
  game_insert(jig, mag_g, ammo_g, maxcap)
  as("host", hk(RPC), P(jig), P(mag_g), P(ammo_g), P(maxcap))
end

local ground = {}
local function make_pawn(name, remote)
  local pc = { __name = "PC_" .. name, NetConnection = remote and { __name = "Conn_" .. name } or nil }
  local pawn = { __name = "BP_PlayerCharacter_C_" .. name, __cls = "BP_PlayerCharacter_C", Controller = pc }
  function pawn.JigMP_OnRequestDropItem(self, info, cname, out)
    local a = { __name = "Pickup_" .. #ground, n = info[F_COUNT], da = info[F_ITEMID] }
    function a.SetPickupCount(s, n) s.n = n end
    ground[#ground + 1] = a
    out.ActorRef = a
  end
  return pawn, pc
end
local function ground_n()
  local n = 0
  for _, a in ipairs(ground) do n = n + a.n end
  return n
end

-- ---------------------------------------------------------------------------
-- the client's widgets (LocalJSIContainers: JSIContainer widgets with JSI_Slot)
-- ---------------------------------------------------------------------------
local own_calls = 0
local function make_cjig(owner, hjig)
  local cj = { __name = "BP_JigMultiplayer_" .. owner.__name, conts = {} }
  local function slot(g, n, da) return { __name = "Slot_" .. gs(g), ItemUniqueID = g, ItemCount = n, JigDataAsset = da } end
  for _, c in ipairs(hjig.conts) do
    local slots = {}
    for _, it in ipairs(c[F_ITEMS].list) do slots[#slots + 1] = slot(it[F_USID], it[F_INFO][F_COUNT], it[F_INFO][F_ITEMID]) end
    cj.conts[#cj.conts + 1] = { __name = "JSI_" .. gs(c[F_CONT_UID]), ContainerID = c[F_CONT_UID], ArrayOfItems = arr(slots) }
  end
  cj.LocalJSIContainers = arr(cj.conts)
  function cj.GetOwner() return owner end
  function cj.widget(g) for _, c in ipairs(cj.conts) do if gs(c.ContainerID) == gs(g) then return c end end end
  function cj.slot(g)
    for _, c in ipairs(cj.conts) do
      for i, s in ipairs(c.ArrayOfItems.list) do if gs(s.ItemUniqueID) == gs(g) then return s, c, i end end
    end
  end
  function cj.count(g) local s = cj.slot(g); return s and s.ItemCount or 0 end
  function cj.cap() local n = 0; for _, s in ipairs(cj.widget(G_LOADER_GRID).ArrayOfItems.list) do n = n + s.ItemCount end; return n end
  function cj.add_slot(to, g, n, da) table.insert(cj.widget(to).ArrayOfItems.list, slot(g, n, da)) end
  function cj.FindItemInContainer(self, c, g, out)
    for _, s in ipairs(c.ArrayOfItems.list) do if gs(s.ItemUniqueID) == gs(g) then out.Found = s end end
  end
  function cj.FindJSIContainer(self, g, ref, fnd)
    local w = cj.widget(g)
    if w then ref.JSIRef = w; fnd.Found = true end
  end
  -- BP_JigComponent.ClientUpdateCount(ItemUID, NewCount, RemoveIf0): the widget's count, 0 removes it
  function cj.game_update(self, g, n, remove0)
    local s, c, i = cj.slot(g)
    if not s then return end
    if n == 0 and remove0 then table.remove(c.ArrayOfItems.list, i) else s.ItemCount = n end
  end
  -- the same function when the mod calls it (prediction): counted
  function cj.ClientUpdateCount(self, g, n, remove0)
    own_calls = own_calls + 1
    return cj.game_update(self, g, n, remove0)
  end
  return cj
end

-- an answer executed on the client: the RPC body, then the post-hooks
local function client_exec(cj, r, hooks_on)
  if r.fn == "CLIENT_UpdateCounts" then
    local list = {}
    for _, e in ipairs(r.counts) do
      cj.game_update(cj, e.g, e.n, true)
      list[#list + 1] = { [F_UC_UID] = e.g, [F_UC_COUNT] = e.n }
    end
    if hooks_on then as("client", hk(H_COUNTS), P(cj), P(arr(list)), P(ZERO)) end
  elseif r.fn == "CLIENT_NewItemAdded" then
    cj.add_slot(r.to, r.g, r.n, r.da)
    cj.game_update(cj, r.upd.g, r.upd.n, true)
    if hooks_on then
      as("client", hk(H_NEW), P(cj), P({ [F_COUNT] = r.n, [F_ITEMID] = r.da }), P(r.g), P(r.to), P(0), P(false),
        P({ [F_UC_UID] = r.upd.g, [F_UC_COUNT] = r.upd.n }), P(ZERO), P({}), P(false))
    end
  elseif r.fn == "CLIENT_UpdateCount" then
    cj.game_update(cj, r.g, r.n, true)
    if hooks_on then as("client", hk(H_COUNT), P(cj), P(cj), P(r.g), P(r.n), P(ZERO)) end
  end
end

-- One reload of the client on its widgets (BP_PlayerCharacter @90435 ->
-- LocalStartReloadInternal), the host behind two reliable channels.
--   o.l1 / o.l2: client->host / host->client delay (s, or a function);
--   o.period: s between Round_In; o.burst: Round_In in the first frame
--   (a hitch: the montage catches up; they all fire, and a "stop" among
--   them ends the loop after that frame - the game's Delay 0.25 then
--   StopAnimMontage); o.refuse[k]: the host finds no stack for request k;
--   o.client_hooks / o.host_hooks / o.start_hook (default on); o.shot_at:
--   a shot's CLIENT_UpdateCount for the loader stack at that time;
--   o.stale: the loader widget the game reads keeps the count it had when
--   the reload started (it does not follow the host's answers);
--   o.max_rounds: Round_In before the sim gives up ("loops").
local function sim(o)
  local q, seq = {}, 0
  local function at(t, f) seq = seq + 1; q[#q + 1] = { t = t, s = seq, f = f } end
  local up_last, down_last = 0, 0
  local function lat(v) if type(v) == "function" then return v() end return v end
  local function send_up(t, f) local d = math.max(up_last, t + lat(o.l1)); up_last = d; at(d, f) end
  local function send_down(t, f) local d = math.max(down_last, t + lat(o.l2)); down_last = d; at(d, f) end
  local res = { reads = {}, asked = 0, why = nil, maxhost = 0 }
  local stopped, nreq, any_stop, nround = false, 0, false, 0
  local frozen = o.stale and o.cj.cap() or nil
  local burst_left = (o.burst or 1) - 1
  local chooks, hhooks = o.client_hooks ~= false, o.host_hooks ~= false
  local round_in
  local function next_round(t, go_on)
    if not go_on then any_stop = true end
    if burst_left > 0 then
      burst_left = burst_left - 1
      at(t, round_in)
    elseif any_stop then
      stopped = true
      if chooks and o.loop_end ~= false and rc.loop_ended then rc.loop_ended() end   -- the own loop montage ends (sdc_combat)
    elseif nround >= (o.max_rounds or 60) then
      stopped = true
      res.why = "loops"
      if chooks and o.loop_end ~= false and rc.loop_ended then rc.loop_ended() end
    else
      at(t + o.period, round_in)
    end
  end
  round_in = function(t)
    if stopped then return end
    nround = nround + 1
    local cap = frozen or o.cj.cap()
    res.reads[#res.reads + 1] = cap
    if cap == 6 then res.why = "FULL!"; return next_round(t, false) end
    local go_on = not (6 - cap == 1)
    local ammo = nil
    for _, s in ipairs(o.cj.widget(G_POCKET).ArrayOfItems.list) do
      if s.ItemCount > 0 then ammo = s.ItemUniqueID break end
    end
    if not ammo then res.why = "no ammo"; return next_round(t, false) end
    nreq = nreq + 1
    res.asked = res.asked + 1
    local k = nreq
    send_up(t, function(t2)
      if o.refuse and o.refuse[k] then return end
      local n0 = #o.hj.client_rpcs
      game_insert(o.hj, G_LOADER_GRID, ammo, 6)
      if hhooks then as("host", hk(RPC), P(o.hj), P(G_LOADER_GRID), P(ammo), P(6)) end
      res.maxhost = math.max(res.maxhost, o.hj.total(G_LOADER_GRID))
      for i = n0 + 1, #o.hj.client_rpcs do
        local r = o.hj.client_rpcs[i]
        send_down(t2, function() client_exec(o.cj, r, chooks) end)
      end
    end)
    if chooks then
      as("client", hk(REQ), P(o.cj), P(G_LOADER_GRID), P(ammo), P(6), P(false))
      -- Jig_StartReloading returns: its Result is what the Round_In decides on
      local result = { v = go_on }
      function result.get(r) return r.v end
      function result.set(r, v) r.v = v end
      if o.start_hook ~= false then
        local game_read = frozen or o.cj.cap()
        local loader_slot = { __name = "LoaderSlot" }
        function loader_slot.GetContainerCapacity(_, c1, c2) c1.Cap = game_read; c2.MaxCapacity = 6 end
        local mag_slot = { __name = "MagSlot" }
        function mag_slot.GetEquippedItemRef(_, f, r, p) f.Found = true; r.ItemRef = loader_slot; p.IsPending = false end
        as("client", hk(START), P({ __name = "Weapon" }), P(o.cj), P(mag_slot), P(nil), result)
      end
      go_on = result.v
    end
    if not go_on then res.why = "last round" end
    next_round(t, go_on)
  end
  at(0, round_in)
  if o.shot_at then
    at(o.shot_at, function(t)
      -- a shot (the host's consume; the game's absolute CLIENT_UpdateCount)
      local it = o.hj.find(gs(U_LOADED))
      it[F_INFO][F_COUNT] = it[F_INFO][F_COUNT] - 1
      local r = { fn = "CLIENT_UpdateCount", g = U_LOADED, n = it[F_INFO][F_COUNT] }
      send_down(t, function() client_exec(o.cj, r, chooks) end)
    end)
  end
  for t = 0.5, (o.until_t or 12), 0.5 do
    at(t, function() if chooks then as("client", expire_tick) end end)
  end
  while #q > 0 do
    table.sort(q, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.s < b.s end)
    local e = table.remove(q, 1)
    T = e.t
    e.f(e.t)
  end
  return res
end

local client_pawn, client_pc = make_pawn("client", true)
local host_pawn = make_pawn("host", false)
local_pawn = client_pawn

local function world(loaded, reserve)
  local hj = make_jig(client_pawn, loaded, reserve)
  local cj = make_cjig(client_pawn, hj)
  client_pawn.BP_JigMultiplayer = cj
  return hj, cj
end
local function same_counts(hj, cj, what)
  local ok = true
  for _, c in ipairs(hj.conts) do
    for _, it in ipairs(c[F_ITEMS].list) do
      if cj.count(it[F_USID]) ~= it[F_INFO][F_COUNT] then ok = false end
    end
  end
  for _, c in ipairs(cj.conts) do
    for _, s in ipairs(c.ArrayOfItems.list) do
      if not hj.find(gs(s.ItemUniqueID)) then ok = false end
    end
  end
  check(ok, what .. ": the client's widgets show exactly the host's counts")
end
local function seq_str(t) local p = {} for _, v in ipairs(t) do p[#p + 1] = tostring(v) end return table.concat(p, ",") end

-- ---------------------------------------------------------------------------
print("== the bug: reload_cap_fix off, answers 2 loops late")
cfgv.reload_cap_fix = false
do
  T = 0
  local hj, cj = world(3, 40)
  local r = sim({ hj = hj, cj = cj, l1 = 0.45, l2 = 0.45, period = 0.45 })
  check(hj.total(G_LOADER_GRID) > 6, "one reload goes past the capacity (" .. hj.total(G_LOADER_GRID) .. " of 6), reads " .. seq_str(r.reads))
  T = 0
  sim({ hj = hj, cj = cj, l1 = 0.45, l2 = 0.45, period = 0.45 })
  check(hj.total(G_LOADER_GRID) == 43 and hj.count(U_RESERVE) == 0,
    "the next reload takes the whole reserve (" .. hj.total(G_LOADER_GRID) .. " loaded)")
end
cfgv.reload_cap_fix = true

-- ---------------------------------------------------------------------------
print("== prediction: high ping (answers after several inserts)")
for _, l in ipairs({ 0.05, 0.6, 1.5, 3.0 }) do
  T = 0
  sent, ground = {}, {}
  local over0, ended0 = rc.stats.over, rc.stats.ended or 0
  local hj, cj = world(3, 40)
  local r = sim({ hj = hj, cj = cj, l1 = l, l2 = l, period = 0.45 })
  check((rc.stats.ended or 0) == ended0, "RTT " .. 2 * l .. " s: the game's own checks ended it (the host-count end not needed)")
  check((rc.stats.mismatch or 0) == 0, "RTT " .. 2 * l .. " s: the widget the game reads shows the counted value (no mismatch logged)")
  check(r.asked == 3 and hj.total(G_LOADER_GRID) == 6 and r.maxhost == 6,
    string.format("RTT %.1f s: 3 requests, the host never above 6 (reads %s, %s)", 2 * l, seq_str(r.reads), tostring(r.why)))
  check(seq_str(r.reads) == "3,4,5", "RTT " .. 2 * l .. " s: the game read 3, 4, 5 - its own last-round check stopped it")
  check(rc.stats.over == over0, "RTT " .. 2 * l .. " s: the host never had to take a round out")
  same_counts(hj, cj, "RTT " .. 2 * l .. " s")
  check(hj.count(U_RESERVE) == 37 and rounds(hj) == 43, "rounds kept (loaded 6 + reserve 37)")
end

-- ---------------------------------------------------------------------------
print("== prediction alone (the host's rule not running): nothing past 6, nothing out of step")
do
  T = 0
  local hj, cj = world(1, 20)
  local r = sim({ hj = hj, cj = cj, l1 = 1.0, l2 = 1.0, period = 0.4, host_hooks = false })
  check(hj.total(G_LOADER_GRID) == 6 and r.asked == 5, "1 -> 6 with 5 requests at 2 s RTT (" .. r.asked .. ")")
  same_counts(hj, cj, "prediction alone")
end

-- ---------------------------------------------------------------------------
print("== a frame hitch: several Round_In in one frame")
do
  T = 0
  local hj, cj = world(3, 20)
  local r = sim({ hj = hj, cj = cj, l1 = 0.3, l2 = 0.3, period = 0.45, burst = 4 })
  check(r.asked == 3 and hj.total(G_LOADER_GRID) == 6 and seq_str(r.reads) == "3,4,5,6",
    "four Round_In in one frame at 3: each read the count the one before it counted, the fourth FULL! (" .. seq_str(r.reads) .. ")")
  same_counts(hj, cj, "hitch")
  T = 0
  hj, cj = world(5, 20)
  r = sim({ hj = hj, cj = cj, l1 = 0.3, l2 = 0.3, period = 0.45, burst = 3 })
  check(r.asked == 1 and hj.total(G_LOADER_GRID) == 6 and seq_str(r.reads) == "5,6,6",
    "three Round_In in one frame at 5: one request, then FULL! (" .. seq_str(r.reads) .. ")")
  T = 0
  cfgv.reload_cap_fix = false
  hj, cj = world(5, 20)
  r = sim({ hj = hj, cj = cj, l1 = 0.3, l2 = 0.3, period = 0.45, burst = 3 })
  check(hj.total(G_LOADER_GRID) == 8, "(fix off: the same frame reads 5 three times and loads 8: " .. hj.total(G_LOADER_GRID) .. ")")
  cfgv.reload_cap_fix = true
end

-- ---------------------------------------------------------------------------
print("== late answers in bursts, and a shot's absolute count in between")
do
  T = 0
  local slow = 0
  local function bursty() slow = slow + 1; return (slow % 3 == 0) and 0.1 or 1.4 end
  local hj, cj = world(1, 30)
  local r = sim({ hj = hj, cj = cj, l1 = 0.2, l2 = bursty, period = 0.35 })
  check(hj.total(G_LOADER_GRID) == 6 and seq_str(r.reads) == "1,2,3,4,5", "bursty answers: reads 1..5, loaded 6 (" .. seq_str(r.reads) .. ")")
  same_counts(hj, cj, "bursty answers")
  T = 0
  hj, cj = world(2, 30)
  local over0 = rc.stats.over
  r = sim({ hj = hj, cj = cj, l1 = 0.5, l2 = 0.5, period = 0.45, shot_at = 0.6 })
  check(hj.total(G_LOADER_GRID) == 6 and r.maxhost <= 6 and rc.stats.over == over0,
    "a shot's absolute count while requests are on their way: shown from it + the unanswered ones; 6, no correction (reads " .. seq_str(r.reads) .. ")")
  same_counts(hj, cj, "shot in between")
end

-- ---------------------------------------------------------------------------
print("== the host refuses a request mid-loop (no answer)")
do
  T = 0
  logs = {}
  local hj, cj = world(2, 30)
  sim({ hj = hj, cj = cj, l1 = 0.5, l2 = 0.5, period = 0.45, refuse = { [2] = true }, until_t = 15 })
  check(hj.total(G_LOADER_GRID) == 5, "the refused round is not in the gun on the host (5)")
  check(cj.cap() == 5 and cj.count(U_RESERVE) == hj.count(U_RESERVE),
    "after " .. EXPIRE_S .. " s the client shows the host's counts again (5, reserve " .. cj.count(U_RESERVE) .. ")")
  check(logged("got no answer from the host", true), "logged")
  same_counts(hj, cj, "refusal")
  T = 0
  local r = sim({ hj = hj, cj = cj, l1 = 0.5, l2 = 0.5, period = 0.45 })
  check(hj.total(G_LOADER_GRID) == 6 and r.asked == 1, "the next R loads the last one")
end

-- ---------------------------------------------------------------------------
print("== the loader grid's widget not found on this screen: counted from the first answer on")
do
  T = 0
  logs = {}
  local hj, cj = world(2, 30)
  cj.FindJSIContainer = function() end
  local over0 = rc.stats.over
  local r = sim({ hj = hj, cj = cj, l1 = 0.6, l2 = 0.6, period = 0.45 })
  check(hj.total(G_LOADER_GRID) == 6 and r.maxhost == 6, "2 -> 6 at RTT 1.2 s, the host never above 6 (reads " .. seq_str(r.reads) .. ")")
  check(r.asked == 4 and seq_str(r.reads) == "2,2,2,5" and rc.stats.over == over0,
    "the first answer names the loader stack: then 5 is read and the reload ends at 6 by itself, no correction")
  check(logged("no widget of loader grid", true), "logged")
  same_counts(hj, cj, "no grid widget")
end

-- ---------------------------------------------------------------------------
print("== the loader widget the game reads does not follow the host (tonight: 50 ms ping, no hitch, 16 rounds)")
do
  T = 0
  logs = {}
  local hj, cj = world(3, 40)
  local ended0 = rc.stats.ended or 0
  local r = sim({ hj = hj, cj = cj, l1 = 0.025, l2 = 0.025, period = 0.45, stale = true })
  check(r.asked == 3 and hj.total(G_LOADER_GRID) == 6 and r.why == "last round",
    "the game reads 3 every time, but the reload ends after 3 rounds by the host's counts (" .. seq_str(r.reads) .. ")")
  check(rc.stats.ended == ended0 + 1 and logged("own reload ended after this round: the host's count", true),
    "ended with Jig_StartReloading's Result (the game's own end of the loop), logged")
  check(hj.count(U_RESERVE) == 37 and rounds(hj) == 43, "rounds kept")
  -- without that end the game would go on: each round refused by the host's rule, the loop never ends
  T = 0
  hj, cj = world(3, 40)
  r = sim({ hj = hj, cj = cj, l1 = 0.025, l2 = 0.025, period = 0.45, stale = true, start_hook = false, max_rounds = 30 })
  check(r.why == "loops" and hj.total(G_LOADER_GRID) == 6 and rounds(hj) + ground_n() == 43,
    "(without it: the host keeps 6 and gives every round back, but the loop runs on - " .. r.asked .. " requests)")
end


-- ---------------------------------------------------------------------------
print("== a reload after leaving a vehicle (as tonight): the game reads a loader widget the answers do not reach")
do
  -- (a) the screen has two widgets of the loader grid: the game reads the
  -- old one (frozen), FindJSIContainer and the answers reach the other one
  T = 0
  logs = {}
  local hj, cj = world(3, 40)
  local mm0 = rc.stats.mismatch or 0
  local r = sim({ hj = hj, cj = cj, l1 = 0.025, l2 = 0.025, period = 0.45, stale = true })
  check(r.asked == 3 and hj.total(G_LOADER_GRID) == 6 and r.why == "last round",
    "(a) a second widget: the reload ends after 3 rounds by the host's counts (" .. seq_str(r.reads) .. ")")
  check((rc.stats.mismatch or 0) > mm0 and logged("^warn: reloadcap: the loader count this reload reads is 3, .*does not follow the host's answers"),
    "(a) the next log says it: the loader count the game reads vs the one shown from the host's")
  -- (b) FindJSIContainer returns the same frozen widget the game reads; the
  -- answers reach another one (50 ms ping: each Round_In after its answer)
  T = 0
  logs = {}
  hj, cj = world(3, 40)
  local frozen = { __name = "JSI_frozen", ContainerID = G_LOADER_GRID,
    ArrayOfItems = arr({ { __name = "SlotF", ItemUniqueID = U_LOADED, ItemCount = 3, JigDataAsset = DA_AMMO } }) }
  cj.FindJSIContainer = function(self, g, ref, fnd)
    if gs(g) == gs(G_LOADER_GRID) then ref.JSIRef = frozen; fnd.Found = true end
  end
  local over0 = rc.stats.over
  r = sim({ hj = hj, cj = cj, l1 = 0.025, l2 = 0.025, period = 0.45, stale = true, max_rounds = 30 })
  check(r.asked == 3 and hj.total(G_LOADER_GRID) == 6 and r.why == "last round" and rc.stats.over == over0,
    "(b) the frozen widget is read only at the first round; then the host's own answers count: 3 rounds, 6, no correction (" .. r.asked .. ")")
  check(logged("^warn: reloadcap: the loader count this reload reads is 3, .*does not follow the host's answers"), "(b) logged as a warning")
end

-- ---------------------------------------------------------------------------
print("== the host's count is not carried to the next reload (a chamber step changes it silently)")
do
  T = 0
  local hj, cj = world(3, 20)
  sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45 })
  check(hj.total(G_LOADER_GRID) == 6, "(reload 1: 6)")
  -- the chamber takes a round on both machines, no count message
  hj.find(gs(U_LOADED))[F_INFO][F_COUNT] = 5
  cj.slot(U_LOADED).ItemCount = 5
  T = T + 1   -- the next R within the 2 s window of a reload
  as("client", hk(REQ), P(cj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  local G = rc._t and rc._t.pred.grids[gs(G_LOADER_GRID)]
  check(G and G.auth == 5, "the next reload counts from the widget (5), not the last reload's host count (6): " .. tostring(G and G.auth))
  rc.reset()
  -- the end of a reload comes from sdc_combat's own loop watch
  S.role = "client"
  local LOOP = { __name = "Chr_AN_Shotgun_ReloadB_Anim_Montage", __cls = "AnimMontage", __path = "/Game/L.L" }
  local weapon = { __name = "BP_SawnOffShotgunPickup_C_1", BP_WeaponsPickupComponent = { __name = "WPC", LoopReloadMontage = LOOP } }
  local playing = true
  local anim = { __name = "Anim", Montage_IsPlaying = function(_, m) return playing and m == LOOP end }
  local saved = { client_pawn.Mesh, client_pawn.Children, client_pawn.GetCurrentMontage, client_pawn.IsLocallyControlled,
                  client_pawn.Svr_StopMontage }
  client_pawn.Mesh = { __name = "Mesh", GetAnimInstance = function() return anim end }
  client_pawn.Children = { ForEach = function(_, f) f(1, P(weapon)) end }
  client_pawn.GetCurrentMontage = function() return playing and LOOP or nil end
  client_pawn.IsLocallyControlled = function() return true end
  client_pawn.Svr_StopMontage = function() end
  local tick = everys["combat-reload"] or function() end
  T = T + 5
  as("client", hk(REQ), P(cj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  tick()
  local G2 = rc._t and rc._t.pred.grids[gs(G_LOADER_GRID)]
  check(G2 and G2.open == true, "(a reload going: its count is kept)")
  playing = false
  tick()
  check(G2 and G2.open == false, "the own loop montage ended (sdc_combat's watch): the reload's count is closed")
  client_pawn.Mesh, client_pawn.Children, client_pawn.GetCurrentMontage, client_pawn.IsLocallyControlled,
    client_pawn.Svr_StopMontage = table.unpack(saved, 1, 5)
  S.role = "host"
  rc.reset()
end

-- ---------------------------------------------------------------------------
print("== an unanswered request took the last round of a reserve stack (its widget went)")
do
  T = 0
  logs, up_sent, ground = {}, {}, {}
  local hj, cj = world(3, 1)
  sim({ hj = hj, cj = cj, l1 = 0.3, l2 = 0.3, period = 0.45, refuse = { [1] = true }, until_t = 15 })
  local asked = nil
  for _, m in ipairs(up_sent) do if m.kind == "RESEND" and m.f[1] == gs(U_RESERVE) then asked = m end end
  check(hj.count(U_RESERVE) == 1 and asked ~= nil, "the host still has it: RESEND|its uid to the host after the expiry")
  -- the host's answer to RESEND (sdc_consume: CLIENT_AddNewItem) puts it back
  if asked then cj.add_slot(G_POCKET, U_RESERVE, 1, DA_AMMO) end
  same_counts(hj, cj, "after RESEND")
  up_sent = {}
  T = 0
  hj, cj = world(3, 10)
  sim({ hj = hj, cj = cj, l1 = 0.3, l2 = 0.3, period = 0.45, refuse = { [3] = true }, until_t = 15 })
  local any = false
  for _, m in ipairs(up_sent) do if m.kind == "RESEND" then any = true end end
  check(not any, "a stack still on the screen: nothing asked again")
end

-- ---------------------------------------------------------------------------
print("== an ammo stack's absolute count from another answer while rounds are on their way")
do
  T = 0
  local hj, cj = world(2, 10)
  as("client", hk(REQ), P(cj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  check(cj.count(U_RESERVE) == 9, "(predicted: reserve 9)")
  -- the player picks up 40 shells that stack onto the reserve on the host: 10 -> 50
  client_exec(cj, { fn = "CLIENT_UpdateCounts", counts = { { g = U_RESERVE, n = 50 }, { g = guid(66), n = 3 } } }, true)
  check(cj.count(U_RESERVE) == 49, "shown 50 - the 1 on its way = 49 (" .. cj.count(U_RESERVE) .. ")")
  rc.reset()
end

-- ---------------------------------------------------------------------------
print("== two stacks of one kind in the loader: the round goes to the first, as the host's insert does")
do
  T = 0
  local hj, cj = world(2, 10)
  local U_SECOND = guid(23)
  table.insert(hj.grid(G_LOADER_GRID)[F_ITEMS].list, item(U_SECOND, DA_AMMO, 2))
  cj = make_cjig(client_pawn, hj)
  client_pawn.BP_JigMultiplayer = cj
  as("client", hk(REQ), P(cj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  check(cj.count(U_LOADED) == 3 and cj.count(U_SECOND) == 2, "predicted onto the first stack (3), the second untouched (2)")
  rc.reset()
  -- this screen lists them the other way round: the first answer names the stack the host loaded
  T = 0
  hj, cj = world(2, 10)
  table.insert(hj.grid(G_LOADER_GRID)[F_ITEMS].list, item(U_SECOND, DA_AMMO, 2))
  cj = make_cjig(client_pawn, hj)
  local w = cj.widget(G_LOADER_GRID).ArrayOfItems.list
  w[1], w[2] = w[2], w[1]
  client_pawn.BP_JigMultiplayer = cj
  local rs0 = rc.stats.restacked or 0
  local r = sim({ hj = hj, cj = cj, l1 = 0.6, l2 = 0.6, period = 0.4 })
  check(hj.total(G_LOADER_GRID) == 6 and r.maxhost == 6 and (rc.stats.restacked or 0) > rs0,
    "the answer moved the counting to the stack the host loaded; 6, never above (reads " .. seq_str(r.reads) .. ")")
  same_counts(hj, cj, "two stacks of one kind")
end


-- ---------------------------------------------------------------------------
print("== when a reload's host count is closed (the sdc_combat loop watch not running)")
do
  local function chamber(cj, n_left, hj)
    -- a round into the chamber: the loader loses one on both machines, no count message
    hj.find(gs(U_LOADED))[F_INFO][F_COUNT] = n_left
    cj.slot(U_LOADED).ItemCount = n_left
    as("client", hk(H_CHAMBER), P(cj), P(G_CHAMBER), P(G_LOADER_GRID), P(U_LOADED), P(0), P(true), P(false))
  end
  local function grid() return rc._t and rc._t.pred.grids[gs(G_LOADER_GRID)] end
  -- the probe: a reload to 6, the chamber step and a shot's re-chamber (4 left), R 1.2 s later
  T = 0
  local hj, cj = world(3, 20)
  sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false, until_t = 1.5 })
  check(grid() == nil or grid().open == false, "the reload's last round (Result false) closed it")
  chamber(cj, 5, hj); chamber(cj, 4, hj)
  T = 0
  local r = sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false })
  check(hj.total(G_LOADER_GRID) == 6 and r.asked == 2, "R after the chamber steps: 4 -> 6 (" .. r.asked .. " rounds)")
  rc.reset()
  -- the game would go on (its widget does not follow), our Result false ended it: closed too
  T = 0
  hj, cj = world(3, 20)
  sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, stale = true, loop_end = false, until_t = 1.5 })
  check(hj.total(G_LOADER_GRID) == 6 and (grid() == nil or grid().open == false),
    "the round our Result false ended (the game's own was true) closed it")
  rc.reset()
  -- a reload cut short (no last round), then a shot re-chambers: the chamber step closes it
  T = 0
  hj, cj = world(2, 20)
  sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false, max_rounds = 2, until_t = 1.5 })
  check(hj.total(G_LOADER_GRID) == 4 and grid() and grid().open == true, "(cut short at 4: still open)")
  chamber(cj, 3, hj)
  check(grid() and grid().open == false, "the chamber step from its loader closed it")
  T = 0
  r = sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false })
  check(hj.total(G_LOADER_GRID) == 6 and r.asked == 3, "R after it: 3 -> 6 (" .. r.asked .. " rounds, not stopped early)")
  rc.reset()
  -- cut short, then two shots that take from the loader with a count message (no chamber): kept current
  T = 0
  hj, cj = world(2, 20)
  sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false, max_rounds = 2, until_t = 1.5 })
  for _, n in ipairs({ 3, 2 }) do
    hj.find(gs(U_LOADED))[F_INFO][F_COUNT] = n
    client_exec(cj, { fn = "CLIENT_UpdateCount", g = U_LOADED, n = n }, true)
  end
  check(grid() and grid().auth == 2, "the shots' counts kept the open reload's count current (2)")
  T = 0
  r = sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false })
  check(hj.total(G_LOADER_GRID) == 6 and r.asked == 4, "R within 2 s: 2 -> 6 (" .. r.asked .. " rounds)")
  rc.reset()
  -- nothing closed it (no last round, no chamber step, no loop watch): 2 s later the widget is read again
  T = 0
  hj, cj = world(2, 20)
  sim({ hj = hj, cj = cj, l1 = 0.05, l2 = 0.05, period = 0.45, loop_end = false, max_rounds = 2, until_t = 1.5 })
  hj.find(gs(U_LOADED))[F_INFO][F_COUNT] = 3
  cj.slot(U_LOADED).ItemCount = 3
  T = T + 3
  as("client", hk(REQ), P(cj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  check(grid() and grid().auth == 3, "after 2 s the next reload reads the widget (3), not the old count (4): " .. tostring(grid() and grid().auth))
  rc.reset()
end

-- ---------------------------------------------------------------------------
print("== the widget-mismatch line: at most 10 a session")
do
  local before = rc.stats.mismatch_lines or 0
  logs = {}
  for _ = 1, 12 do
    T = 0
    local hj, cj = world(3, 40)
    sim({ hj = hj, cj = cj, l1 = 0.025, l2 = 0.025, period = 0.45, stale = true })
  end
  local n = 0
  for _, l in ipairs(logs) do if l:find("^warn: reloadcap: the loader count this reload reads") then n = n + 1 end end
  check(n == 10 - before and rc.stats.mismatch_lines == 10, "12 more reloads with it: " .. n .. " more line(s), 10 in all")
end

-- ---------------------------------------------------------------------------
print("== the reserve runs out mid-reload at high ping")
do
  T = 0
  local hj, cj = world(1, 2)
  local r = sim({ hj = hj, cj = cj, l1 = 1.0, l2 = 1.0, period = 0.4 })
  check(r.asked == 2 and r.why == "no ammo" and hj.total(G_LOADER_GRID) == 3 and not hj.find(gs(U_RESERVE)),
    "2 requests, then no ammo on the client's screen at once (" .. tostring(r.why) .. ")")
  same_counts(hj, cj, "reserve ran out")
end

-- ---------------------------------------------------------------------------
print("== an empty loader (the first stack comes with CLIENT_NewItemAdded)")
do
  T = 0
  local hj, cj = world(0, 30)
  local r = sim({ hj = hj, cj = cj, l1 = 0.3, l2 = 0.3, period = 0.45 })
  check(hj.total(G_LOADER_GRID) == 6 and r.maxhost == 6, "0 -> 6, RTT 0.6 s")
  same_counts(hj, cj, "empty loader")
  T = 0
  sent, ground = {}, {}
  hj, cj = world(0, 30)
  r = sim({ hj = hj, cj = cj, l1 = 1.5, l2 = 1.5, period = 0.4 })
  check(hj.total(G_LOADER_GRID) == 6 and rounds(hj) + ground_n() == 30,
    "0 -> 6 at RTT 3 s: the first stack cannot be counted before it exists; the host's rule takes the extra out (asked " .. r.asked .. ")")
  same_counts(hj, cj, "empty loader, RTT 3 s")
end

-- ---------------------------------------------------------------------------
print("== a gun loaded past its capacity before (42 of 6, 6 in reserve)")
do
  T = 0
  sent, toasts, ground = {}, {}, {}
  local hj, cj = world(42, 6)
  local r = sim({ hj = hj, cj = cj, l1 = 0.5, l2 = 0.5, period = 0.45 })
  check(r.asked == 1 and seq_str(r.reads) == "42" and cj.cap() == 6,
    "one request, and the reload ends with it (the host's count 42 + 1 >= 6); the widget shows 6 (" .. seq_str(r.reads) .. ")")
  check(hj.total(G_LOADER_GRID) == 6 and hj.count(U_RESERVE) == 42, "host: 6 loaded, 37 back -> reserve 42")
  same_counts(hj, cj, "42 of 6")
  local m = sent[1]
  check(m and m.kind == "RLNOTE" and m.pc == client_pc and m.f[1] == "6" and m.f[2] == "43" and m.f[3] == "37" and m.f[4] == "0",
    "RLNOTE|6|43|37|0 to that player")
  check(logged("held 43 round(s), capacity 6 (data)", true) and logged("37 back onto", true), "host log")
  as("client", handlers.RLNOTE or nohook, m and m.f or {})
  check(#toasts == 1 and toasts[1].text == "rlcap_back 43 6 37", "client: the note (" .. tostring(toasts[1] and toasts[1].text) .. ")")
  -- the widget alone (no Result end): it never shows more than the capacity, so the next Round_In reads 6
  T = 0
  sent, ground = {}, {}
  hj, cj = world(42, 6)
  r = sim({ hj = hj, cj = cj, l1 = 0.5, l2 = 0.5, period = 0.45, start_hook = false })
  check(r.asked == 1 and seq_str(r.reads) == "42,6", "without the Result end: shown 6 at once, the next Round_In reads FULL! (" .. seq_str(r.reads) .. ")")
end

-- ---------------------------------------------------------------------------
print("== host rule: where the extra rounds go")
do
  -- the request took the last shell of its stack; another stack of that ammo has room
  sent, ground = {}, {}
  local hj = make_jig(client_pawn, 6, 1)
  table.insert(hj.grid(G_POCKET)[F_ITEMS].list, item(guid(22), DA_AMMO, 30))
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 6 and hj.count(guid(22)) == 31 and ground_n() == 0,
    "its stack is gone: the round goes onto the other 12ga stack (30 -> 31), not to the ground")
  check(#sent == 0, "one round: no note")
  -- the only other stack of that ammo holds 1 round (a pocket): it takes it
  sent, ground = {}, {}
  hj = make_jig(client_pawn, 6, 1)
  table.insert(hj.grid(G_POCKET)[F_ITEMS].list, item(guid(24), DA_AMMO, 1))
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.count(guid(24)) == 2 and ground_n() == 0, "a pocket stack of 1: the round goes onto it (1 -> 2), not to the ground")
  -- no stack anywhere: the ground
  ground = {}
  hj = make_jig(client_pawn, 6, 1)
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 6 and #ground == 1 and ground[1].n == 1 and ground[1].da == DA_AMMO,
    "no other stack: 1 shell at the player's feet")
  check(sent[1] and sent[1].kind == "RLNOTE" and sent[1].f[4] == "1", "rounds dropped: RLNOTE says 1 dropped")
  -- never into a magazine or a chamber
  sent, ground = {}, {}
  hj = make_jig(client_pawn, 6, 1)
  local U_SPARE = guid(40)
  table.insert(hj.grid(G_POCKET)[F_ITEMS].list, item(U_SPARE, DA_MAG, 1))
  hj.add(guid(904), U_SPARE, { item(guid(41), DA_AMMO, 3) })        -- rounds in another loader
  hj.add(G_CHAMBER, U_GUN, { item(guid(42), DA_AMMO, 1) })          -- a chamber's round
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.count(guid(41)) == 3 and hj.count(guid(42)) == 1 and ground_n() == 1,
    "not into another loader's rounds nor a chamber's single round: to the ground")
  -- an old overfill with two kinds: slugs back onto the slug stack, buckshot onto buckshot
  sent, ground = {}, {}
  hj = make_jig(client_pawn, 1, 10)
  table.insert(hj.grid(G_LOADER_GRID)[F_ITEMS].list, item(guid(31), DA_SLUG, 42))
  table.insert(hj.grid(G_POCKET)[F_ITEMS].list, item(guid(32), DA_SLUG, 5))
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)   -- buckshot 1 -> 2, 44 in all
  check(hj.count(U_LOADED) == 1 and hj.count(guid(31)) == 5 and hj.total(G_LOADER_GRID) == 6,
    "loader: buckshot 1 (the kind just loaded first), slugs 5")
  check(hj.count(U_RESERVE) == 10 and hj.count(guid(32)) == 42 and ground_n() == 0,
    "buckshot back onto buckshot (10), 37 slugs onto the slug stack (42), nothing on the ground")
  -- the kind just loaded is cut first even when its stack is the smaller one
  sent, ground = {}, {}
  hj = make_jig(client_pawn, 2, 10)
  table.insert(hj.grid(G_LOADER_GRID)[F_ITEMS].list, 1, item(guid(33), DA_SLUG, 5))
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)   -- buckshot 3 + slugs 5 = 8
  check(hj.count(guid(33)) == 5 and hj.count(U_LOADED) == 1 and hj.count(U_RESERVE) == 11,
    "slugs 5 kept, buckshot 3 -> 1, the 2 back onto its reserve (9 -> 11)")
  -- a stack is never emptied (a 0-count item would stay in the data)
  sent, ground = {}, {}
  hj = make_jig(client_pawn, 1, 10)
  table.insert(hj.grid(G_LOADER_GRID)[F_ITEMS].list, item(guid(34), DA_SLUG, 7))
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)   -- buckshot 2 + slugs 7 = 9
  check(hj.count(U_LOADED) == 1 and hj.count(guid(34)) == 5 and hj.find(gs(U_LOADED)) ~= nil,
    "buckshot 2 -> 1 (not 0), slugs 7 -> 5")
  -- MaxStack: the rest to the ground
  sent, ground = {}, {}
  hj = make_jig(client_pawn, 9, 998)
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)   -- 10 loaded, reserve 997
  check(hj.total(G_LOADER_GRID) == 6 and hj.count(U_RESERVE) == 1000 and ground_n() == 1, "4 extra: 3 fill the stack to 1000, 1 at the feet")
end

-- ---------------------------------------------------------------------------
print("== host rule: refused or unread writes never double a round")
do
  sent, ground = {}, {}
  local hj = make_jig(client_pawn, 6, 10)
  hj.refuse[gs(U_LOADED)] = true
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 7 and hj.count(U_RESERVE) == 9 and ground_n() == 0 and rounds(hj) == 16,
    "the loader's count did not change: nothing given back (16 rounds, not 17)")
  check(#sent == 0, "nothing taken out: no note")
  hj = make_jig(client_pawn, 42, 10)
  hj.refuse[gs(U_LOADED)] = true
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(#sent == 0 and rounds(hj) == 52, "43 in the gun but the write refused: nothing taken, no note claiming otherwise")
  check(logged("^warn: reloadcap: .*taking 1 out FAILED"), "logged as a warning")
  -- the write went through, its read-back failed once: read again, the round counted once
  sent, ground, logs = {}, {}, {}
  hj = make_jig(client_pawn, 6, 10)
  hj.after_set = function(g) if gs(g) == gs(U_RESERVE) then hj.fail_reads = 1 end end
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 6 and hj.count(U_RESERVE) == 10 and ground_n() == 0 and rounds(hj) == 16,
    "one failed read-back: read again from the whole inventory, 16 rounds")
  check(not logged("not read back", true), "read again successfully: no 'not read back' warning")
  -- no read-back at all: taken as done, nothing dropped, a warning
  sent, ground, logs = {}, {}, {}
  hj = make_jig(client_pawn, 6, 10)
  hj.after_set = function(g) if gs(g) == gs(U_RESERVE) then hj.fail_reads = 2 end end
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(rounds(hj) + ground_n() == 16 and ground_n() == 0, "unreadable data after the write: no second give-back (16 rounds)")
  check(logged("^warn: reloadcap: .*not read back"), "logged as a warning")
  sent, ground, logs = {}, {}, {}
  hj = make_jig(client_pawn, 6, 10)
  hj.after_set = function(g) if gs(g) == gs(U_LOADED) then hj.fail_reads = 2 end end
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(rounds(hj) + ground_n() == 16 and hj.total(G_LOADER_GRID) == 6 and hj.count(U_RESERVE) == 10,
    "the loader's read-back failed: taken as done, the round back on its stack (no round lost)")
end

-- ---------------------------------------------------------------------------
print("== host rule: cost and the capacity it trusts")
do
  rc.reset()
  sent, ground = {}, {}
  local hj = make_jig(client_pawn, 3, 10)
  local w0 = walks
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(walks - w0 == 1 and hj.total(G_LOADER_GRID) == 4, "within the Max the request carries: one short walk, no inventory walk")
  -- the loader item's data asset wins over a request that says otherwise
  rc.reset()
  logs = {}
  hj = make_jig(client_pawn, 6, 10)
  host_request(hj, G_LOADER_GRID, U_RESERVE, 5)
  check(hj.total(G_LOADER_GRID) == 6, "over the request's 5: the loader's own capacity 6 is looked up and kept")
  check(logged("says capacity 5, the loader SawnOffShotgunLoader holds 6", true), "the mismatch is logged")
  host_request(hj, G_LOADER_GRID, U_RESERVE, 99)
  check(hj.total(G_LOADER_GRID) == 6, "known capacity: a request saying 99 is not believed")
  -- a grid whose owner item is not found: the request's Max, looked up again only after 30 s
  rc.reset()
  hj = make_jig(client_pawn, 6, 10)
  hj.grid(G_LOADER_GRID)[F_HOLDER] = guid(777)
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 6, "no owner item: the request's Max 6")
  hj.find(gs(U_LOADED))[F_INFO][F_COUNT] = 3
  w0 = walks
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(walks - w0 == 1, "the next request within it does not look for the owner again (" .. walks - w0 .. " walk)")
end

-- ---------------------------------------------------------------------------
print("== the host's own gun and role checks")
do
  sent, toasts, ground, own_calls = {}, {}, {}, 0
  local hj = make_jig(host_pawn, 3, 10)
  local cj = make_cjig(host_pawn, hj)
  local_pawn = host_pawn
  as("host", hk(REQ), P(cj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(own_calls == 0 and hj.total(G_LOADER_GRID) == 4 and #sent == 0 and #toasts == 0,
    "host's own reload within capacity: no prediction, nothing changed")
  hj = make_jig(host_pawn, 20, 10)
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 6 and hj.count(U_RESERVE) == 24 and #sent == 0 and #toasts == 1
    and toasts[1].text == "rlcap_back 21 6 15", "a gun loaded past it before: set right, the host's own note")
  local_pawn = client_pawn
  -- the host rule only on the host; prediction only for the own component
  sent = {}
  hj = make_jig(client_pawn, 6, 10)
  game_insert(hj, G_LOADER_GRID, U_RESERVE, 6)
  as("client", hk(RPC), P(hj), P(G_LOADER_GRID), P(U_RESERVE), P(6))
  check(hj.total(G_LOADER_GRID) == 7, "client role: the host rule does nothing")
  local other = make_pawn("other", true)
  local _, ocj = world(3, 10)
  ocj.GetOwner = function() return other end
  own_calls = 0
  as("client", hk(REQ), P(ocj), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  check(own_calls == 0, "another component than the own: not predicted")
  -- a Jig_StartReloading with no round asked for in it (a box magazine): untouched
  local result = { v = true }
  function result.get(r) return r.v end
  function result.set(r, v) r.v = v end
  T = T + 1
  as("client", hk(START), P({ __name = "Weapon" }), P(ocj), P({ __name = "MagSlot" }), P({ __name = "Mag" }), result)
  check(result.v == true, "Jig_StartReloading without a round request in that call (a magazine): Result untouched")
  -- the request marker belongs to the one call it was made in
  T = T + 10
  local _, cj5 = world(5, 10)
  client_pawn.BP_JigMultiplayer = cj5
  as("client", hk(REQ), P(cj5), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  local r1 = { v = true }; r1.get = result.get; r1.set = result.set
  as("client", hk(START), P({ __name = "Weapon" }), P(cj5), P({ __name = "MagSlot" }), P(nil), r1)
  check(r1.v == false, "(the call that asked for the 6th round: Result false)")
  local r2 = { v = true }; r2.get = result.get; r2.set = result.set
  as("client", hk(START), P({ __name = "Weapon" }), P(cj5), P({ __name = "MagSlot" }), P(nil), r2)
  check(r2.v == true, "a later Jig_StartReloading without its own request: untouched")
  as("client", hk(REQ), P(cj5), P(G_LOADER_GRID), P(U_RESERVE), P(6), P(false))
  T = T + 1
  local r3 = { v = true }; r3.get = result.get; r3.set = result.set
  as("client", hk(START), P({ __name = "Weapon" }), P(cj5), P({ __name = "MagSlot" }), P(nil), r3)
  check(r3.v == true, "a request marker from an earlier frame: not used")
  rc.reset()
  -- two kinds in the loader: the other kind counts toward the capacity
  T = T + 10
  local hj2 = make_jig(client_pawn, 1, 20)
  table.insert(hj2.grid(G_LOADER_GRID)[F_ITEMS].list, 1, item(guid(35), DA_SLUG, 2))
  local cj2 = make_cjig(client_pawn, hj2)
  client_pawn.BP_JigMultiplayer = cj2
  local over0 = rc.stats.over
  local r2 = sim({ hj = hj2, cj = cj2, l1 = 0.025, l2 = 0.025, period = 0.45, stale = true })
  check(r2.asked == 3 and hj2.total(G_LOADER_GRID) == 6 and rc.stats.over == over0,
    "slugs 2 + buckshot 1, the game's widget not following: 3 rounds, then the end - the slugs count too (" .. r2.asked .. ")")
  cfgv.reload_cap_fix = false
  hj = make_jig(client_pawn, 6, 10)
  host_request(hj, G_LOADER_GRID, U_RESERVE, 6)
  check(hj.total(G_LOADER_GRID) == 7, "reload_cap_fix = false: the host keeps what the game did")
  cfgv.reload_cap_fix = true
  local box = { __name = "Container_1", __cls = "Container_RandomLoot_C" }
  local bj = make_jig(box, 6, 10)
  host_request(bj, G_LOADER_GRID, U_RESERVE, 6)
  check(bj.total(G_LOADER_GRID) == 7, "not a player's inventory: ignored")
end

-- ---------------------------------------------------------------------------
print("== texts and setting")
do
  local function read(p) local f = assert(io.open(dir .. "/" .. p, "r")); local s = f:read("a"); f:close(); return s end
  local i18n = read("sdc_i18n.lua")
  for _, k in ipairs({ "rlcap_back", "rlcap_drop", "rlcap_floor" }) do
    local ru = i18n:match("M%.STR%.ru%." .. k .. " = \"([^\"]+)\"")
    local en = i18n:match("M%.STR%.en%." .. k .. " = \"([^\"]+)\"")
    check(ru and en and ru:find("[\208\209]") ~= nil and not en:find("[\208\209]"), k .. ": Russian and English")
    local n_ru = select(2, (ru or ""):gsub("%%d", "")); local n_en = select(2, (en or ""):gsub("%%d", ""))
    check(n_ru == n_en and n_ru >= 3, k .. ": same %d count (" .. n_ru .. "/" .. n_en .. ")")
  end
  check(i18n:find("M.DESC_EN.reload_cap_fix", 1, true) and i18n:find("M.LABEL.reload_cap_fix", 1, true)
    and i18n:find("M.GROUP_OF.reload_cap_fix = \"combat\"", 1, true), "reload_cap_fix: English text, label, group")
  check(read("sdc_config.lua"):find("{ \"reload_cap_fix\",   \"bool\",   true,", 1, true) ~= nil, "config key reload_cap_fix, default on")
  check(combat.status_line():find("reloadcap: host checks=", 1, true) ~= nil, "status line")
end

local bad = 0
for _, l in ipairs(logs) do if l:find("^err") then print("    " .. l); bad = bad + 1 end end
check(bad == 0, "no errors logged")

os.clock = real_clock
if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
