-- Mock harness: a dead player's loot box that has been emptied disappears on
-- every machine (sdc_deathbox, driven by sdc_containers).
-- The game never destroys Container_DeadPlayerLoot (its graph destroys only
-- its map marker on open; BP_JigComponent.IsEmpty? has no caller): in 0.7.1 a
-- client took everything out of their box and it stayed, the host still
-- counting one item in it. Host: a box whose items are all taken goes 2 s
-- later (K2_DestroyActor, replicated), its marker with it, the clients are
-- told (DBOXGONE); what is left is logged with container and slot; a
-- leftover in a container nobody can reach does not keep it; a box empty from
-- the start goes once opened; config off keeps it. Client: DBOXGONE removes
-- that box's death marker, not others'.
-- 2026-11-12: a destroyed box stays valid at (0, 0, 0) for a while - the host
-- destroys it once and never sends DBOXGONE at (0, 0, 0); a client keeps the
-- last real place of a box out of range, ignores (0, 0, 0) and removes one
-- marker per message.
-- usage: lua mock_deathbox.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local T = 100
os.clock = function() return T end

local logs = {}
package.loaded["sdc_log"] = setmetatable({ debug_enabled = true, TEXT = {} }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local function has_log(level, pat)
  for _, l in ipairs(logs) do
    if (level == nil or l:sub(1, #level + 2) == level .. ": ") and l:find(pat, 1, true) then return l end
  end
  return nil
end
local function count_log(pat)
  local n = 0
  for _, l in ipairs(logs) do if l:find(pat, 1, true) then n = n + 1 end end
  return n
end

FName = function(s) return { _s = s } end
function RegisterHook() return 1, 2 end
function NotifyOnNewObject() end

local function arr(list)
  return {
    items = list,
    ForEach = function(self, fn)
      for i, v in ipairs(self.items) do fn(i, { get = function() return v end }) end
    end,
    GetArrayNum = function(self) return #self.items end,
  }
end
local function guid(a) return { A = a, B = 1, C = 2, D = 3 } end

local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_CONT_UID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local F_IN_ITEM = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local F_SLOT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE"
local F_SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"
local CS_NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982"

local next_addr = 5000
local by_path = {}   -- (0.7.3: the client finds a box / marker again by its path)
local function obj(cls, name, t)
  t = t or {}
  next_addr = next_addr + 8
  t.__cls, t.__name, t.__addr = cls, name, next_addr
  t.__path = "/Game/Maps/World.World:PersistentLevel." .. name
  by_path[t.__path] = t
  return t
end
local function DA(name) return obj("JigsawItem_DataAsset_C", "DA_" .. name) end

local MAINS = { "FACEWEAR", "HEADWEAR", "TORSO", "LEGS", "BACKPACK", "PRIMARY", "POCKETS" }
local world = {}
local destroyed = {}
local uid_n = 700

-- a death box as SpawnDeadPlayerLoot leaves it: the main containers of the
-- dead character, and the sub-containers of the items in them
local function new_box(name, at)
  local comp = obj("BP_JigComponent_C", "BP_JigMultiplayer")
  local conts, ids, sets = {}, {}, {}
  local by = {}
  for i, n in ipairs(MAINS) do
    local rc = { [F_CONT_UID] = guid(i + #world * 100), [F_IN_ITEM] = guid(0), [F_ITEMS] = arr({}) }
    rc[F_IN_ITEM] = { A = 0, B = 0, C = 0, D = 0 }
    conts[#conts + 1] = rc
    ids[#ids + 1] = rc[F_CONT_UID]
    sets[#sets + 1] = { [CS_NAME] = FName(n) }
    by[n] = rc
  end
  comp.MainContainersIDs = arr(ids)
  comp.ContainersSettings = arr(sets)
  comp.MainJigContainers = arr(conts)
  local marker = obj("BP_Marker_C", "BP_Marker_C_" .. name, { Marker = { RemoveFromParent = function() end } })
  marker.K2_DestroyActor = function(self) self.__valid = false end
  local box = obj("Container_DeadPlayerLoot_C", name, { BP_JigMultiplayer = comp, __loc = at, DeathMarker = marker })
  box.K2_DestroyActor = function(self) self.__valid = false; destroyed[#destroyed + 1] = self.__name end
  comp.__owner = box
  comp.GetOwner = function(self) return self.__owner end
  world[#world + 1] = box
  return box, comp, by, marker
end
local function add(rc, name, n, slot, subs)
  uid_n = uid_n + 1
  local it = { [F_USID] = guid(uid_n), [F_MOTHER] = rc[F_CONT_UID], [F_SLOT] = slot or 0,
               [F_INFO] = { [F_ITEMID] = DA(name), [F_COUNT] = n or 1 }, [F_SUBS] = arr(subs or {}) }
  rc[F_ITEMS].items[#rc[F_ITEMS].items + 1] = it
  return it
end
local function sub_container(comp, host_item, listed)
  uid_n = uid_n + 1
  local rc = { [F_CONT_UID] = guid(uid_n), [F_IN_ITEM] = host_item and host_item[F_USID] or { A = 0, B = 0, C = 0, D = 0 },
               [F_ITEMS] = arr({}) }
  comp.MainJigContainers.items[#comp.MainJigContainers.items + 1] = rc
  if host_item and listed then
    host_item[F_SUBS].items[#host_item[F_SUBS].items + 1] = { [F_SUB_ID] = rc[F_CONT_UID] }
  end
  return rc
end
local function take(rc, it)
  for i, x in ipairs(rc[F_ITEMS].items) do if x == it then table.remove(rc[F_ITEMS].items, i); return end end
end

-- ------------------------------------------------------------ module stubs
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.str(v)
  if type(v) == "table" and v._s then return v._s end
  if v == nil then return "" end
  return tostring(v)
end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.location(a) return ue.valid(a) and a.__loc or nil end
function ue.path(o) return ue.valid(o) and o.__path or "<none>" end
function ue.find_object(p) local o = by_path[p]; if ue.valid(o) then return o end return nil end
local scans = 0
function ue.find_all_recent(cls)
  scans = scans + 1
  local out = {}
  for _, o in ipairs(world) do if o.__cls == cls and ue.valid(o) then out[#out + 1] = o end end
  return out
end
function ue.find_all(cls) return ue.find_all_recent(cls) end
local watched = {}
function ue.watch_new(cls, path) watched[#watched + 1] = { cls, path }; return true end
function ue.delay() return true end
package.loaded["sdc_ue"] = ue

local CFG = {}
package.loaded["sdc_config"] = { get = function(k) return CFG[k] end }
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.__addr or nil end }
local handlers, sent = {}, {}
package.loaded["sdc_net"] = {
  on = function(kind, fn) handlers[kind] = fn end,
  send_to = function(p, kind, ...) sent[#sent + 1] = { pc = p, kind = kind, args = { ... } }; return true end,
  broadcast = function(list, kind, ...) for _, p in ipairs(list) do sent[#sent + 1] = { pc = p, kind = kind, args = { ... } } end end,
  send_to_host = function() return true end,
}

local pc1, pc2 = obj("BP_PlayerController_C", "PC1"), obj("BP_PlayerController_C", "PC2")
local S = { role = "host", remote_pcs = { pc1, pc2 } }
local containers = require("sdc_containers")
local deathbox = require("sdc_deathbox")
containers.init(S)
containers.register_handlers()
check(handlers.DBOXGONE ~= nil, "DBOXGONE handler registered")

local function tick(dt)
  T = T + (dt or 1.1)
  containers.host_tick()
end

-- ============================================================ 1. a client loots their box
print("-- 1: a box looted item by item")
local box, comp, M1, marker = new_box("Container_DeadPlayerLoot_C_1", { X = 1000, Y = 2000, Z = 300 })
local mask = add(M1.FACEWEAR, "HockeyMask")
local jacket = add(M1.TORSO, "BlackMilitaryJacket", 1, 0)
local jpocket = sub_container(comp, jacket, true)
local battery = add(jpocket, "Battery", 20, 1)
local bag = add(M1.BACKPACK, "LargeBlackMilitaryBackpack")
local inbag = sub_container(comp, bag, false)        -- held by InContainerUID only
local bait = add(inbag, "FishingBait", 21, 4)
local rags = add(M1.POCKETS, "Rags", 1, 8)
tick()
check(#watched == 1 and watched[1][1] == "Container_DeadPlayerLoot_C", "new-object watch on the box class")
check(#destroyed == 0, "a full box stays")
check(deathbox._state()[box.__addr].visible == 6 and deathbox._state()[box.__addr].peak == 6,
  "6 visible items (sub-containers by SubContainers and by InContainerUID)")

-- everything but the Rags is taken
take(M1.FACEWEAR, mask)
take(M1.TORSO, jacket); take(jpocket, battery)
take(M1.BACKPACK, bag); take(inbag, bait)
tick()
check(#destroyed == 0, "one item left: the box stays")
local l = has_log("info", "deathbox: Container_DeadPlayerLoot_C_1 on the host: 1 item(s) left: Rags x1")
check(l ~= nil and l:find("in POCKETS slot 8", 1, true) ~= nil, "host log names it: Rags x1 ... in POCKETS slot 8")
tick()
check(count_log("1 item(s) left") == 1, "logged once while it does not change")

-- the last item goes
take(M1.POCKETS, rags)
tick(1.0)
check(#destroyed == 0, "empty: not yet (2 s grace)")
tick(1.1)
check(#destroyed == 0, "empty for 1.1 s: not yet")
tick(1.1)
check(#destroyed == 1 and destroyed[1] == "Container_DeadPlayerLoot_C_1", "empty for 2 s: destroyed on the host")
check(marker.__valid == false, "the host's map marker of it removed")
l = has_log("info", "deathbox: Container_DeadPlayerLoot_C_1 is empty on the host (all 6 item(s) taken) -> destroyed")
check(l ~= nil and l:find("goes on every machine", 1, true) ~= nil, "host log: empty on the host -> destroyed, every machine")
local gone = {}
for _, s in ipairs(sent) do if s.kind == "DBOXGONE" then gone[#gone + 1] = s end end
check(#gone == 2 and gone[1].args[1] == "Container_DeadPlayerLoot_C_1" and gone[1].args[2] == "1000"
  and gone[1].args[3] == "2000", "DBOXGONE with its place to both clients")
tick(); tick()
check(#destroyed == 1, "destroyed once")

-- ============================================================ 2. a leftover nobody can reach
print("-- 2: an item in a container nobody holds does not keep the box")
destroyed, sent = {}, {}
local box2, comp2, M2 = new_box("Container_DeadPlayerLoot_C_2", { X = 5000, Y = 0, Z = 0 })
local gun = add(M2.PRIMARY, "BlackOpsMP5")
local lost = sub_container(comp2, nil, false)       -- e.g. a container left behind by a moved item
add(lost, "Ammo9mm", 1, 0)
tick()
check(#destroyed == 0, "the gun is there: kept")
take(M2.PRIMARY, gun)
tick()
l = has_log("info", "deathbox: Container_DeadPlayerLoot_C_2 on the host: 0 item(s) left; 1 leftover(s) nobody can see or take: Ammo9mm x1")
check(l ~= nil, "the leftover is logged with its container")
tick(); tick()
check(#destroyed == 1 and destroyed[1] == "Container_DeadPlayerLoot_C_2", "only a leftover: destroyed")
check(has_log("info", "Container_DeadPlayerLoot_C_2 is empty on the host (all 1 item(s) taken, 1 leftover(s) nobody can take)") ~= nil,
  "host log says so")
local _ = box2

-- ============================================================ 3. empty from the start
print("-- 3: a box that held nothing")
destroyed = {}
local box3 = new_box("Container_DeadPlayerLoot_C_3", { X = 9000, Y = 0, Z = 0 })
tick(); tick(); tick()
check(#destroyed == 0, "never opened: kept (it is where the player died)")
check(has_log("info", "Container_DeadPlayerLoot_C_3 on the host holds nothing") ~= nil, "logged once")
box3["Looted?"] = true   -- the host opened it (SetInspected)
tick(); tick(); tick()
check(#destroyed == 1 and destroyed[1] == "Container_DeadPlayerLoot_C_3", "opened by the host: destroyed")
check(has_log("info", "Container_DeadPlayerLoot_C_3 is empty on the host (nothing was in it, opened)") ~= nil, "logged")

-- a remote player opened an empty one (sdc_containers' view)
destroyed = {}
local box4, comp4 = new_box("Container_DeadPlayerLoot_C_4", { X = 9500, Y = 0, Z = 0 })
tick(); tick(); tick()
check(#destroyed == 0, "kept before anyone opened it")
local pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_9",
  { Controller = obj("BP_PlayerController_C", "PC9", { NetConnection = obj("NetConnection", "C9") }), __loc = { X = 9500, Y = 0, Z = 0 } })
containers.note_view(pawn, comp4)
tick(); tick(); tick()
check(#destroyed == 1 and destroyed[1] == "Container_DeadPlayerLoot_C_4", "opened by a client: destroyed")
local _b4 = box4

-- ============================================================ 4. config off
print("-- 4: deathbox_remove_empty = false")
destroyed = {}
CFG.deathbox_remove_empty = false
local box5, _, M5 = new_box("Container_DeadPlayerLoot_C_5", { X = 0, Y = 9000, Z = 0 })
local cap = add(M5.HEADWEAR, "Cap")
tick()
take(M5.HEADWEAR, cap)
tick(); tick(); tick()
check(#destroyed == 0 and box5.__valid ~= false, "kept")
check(has_log("info", "Container_DeadPlayerLoot_C_5 is empty on the host; kept (deathbox_remove_empty is off)") ~= nil, "logged")
CFG.deathbox_remove_empty = nil

-- ============================================================ 5. role client: the host's job only
print("-- 5: client")
destroyed, logs = {}, {}
S.role = "client"
local box6, _, M6, marker6 = new_box("Container_DeadPlayerLoot_C_6", { X = 100, Y = 100, Z = 0 })
local box7, _, _, marker7 = new_box("Container_DeadPlayerLoot_C_7", { X = 90000, Y = 0, Z = 0 })
local x = add(M6.FACEWEAR, "Mask")
take(M6.FACEWEAR, x)
tick(); tick(); tick()
check(#destroyed == 0, "a client never destroys a box itself")
T = T + 3
containers.client_tick()
check(deathbox._track()[box6.__addr] ~= nil and deathbox._track()[box7.__addr] ~= nil, "client tracks the boxes and markers")
-- the host destroyed box 6: the replicated copy goes, then DBOXGONE
box6.__valid = false
T = T + 3
containers.client_tick()
check(deathbox._track()[box6.__addr] ~= nil, "its marker is still tracked after the copy went")
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_1", "120", "90", "0" })
check(marker6.__valid == false, "DBOXGONE: that box's death marker removed here")
check(marker7.__valid ~= false, "another box's marker kept")
check(has_log("info", "deathbox: the host removed the emptied death box Container_DeadPlayerLoot_C_1 at (120, 90, 0) (here Container_DeadPlayerLoot_C_6); its death marker here removed") ~= nil,
  "client log")
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_8", "50000", "50000", "0" })
check(has_log("info", "Container_DeadPlayerLoot_C_8 at (50000, 50000, 0) (not near this player)") ~= nil,
  "a box far away: logged, nothing removed")
local _b7 = box7

-- ============================================================ 7. host: a destroyed box stays valid, at (0, 0, 0)
-- 0.7.1, 2026-11-12: K2_DestroyActor leaves the actor valid until the garbage
-- collector (the shared list is kept 30 s) and its place reads (0, 0, 0); the
-- host destroyed it again every 3 s and sent DBOXGONE at (0, 0, 0) each time.
print("-- 7: host: a destroyed box is never checked again")
for _, o in ipairs(world) do o.__valid = false end
world = {}
containers.reset()
S.role = "host"
destroyed, sent, logs = {}, {}, {}
local function gone_msgs()
  local out = {}
  for _, s in ipairs(sent) do if s.kind == "DBOXGONE" then out[#out + 1] = s end end
  return out
end
local box8, _, M8 = new_box("Container_DeadPlayerLoot_C_8", { X = 75112, Y = 63376, Z = 1341 })
box8.K2_DestroyActor = function(self)   -- pending kill: still valid, no place
  self.__loc = { X = 0, Y = 0, Z = 0 }
  destroyed[#destroyed + 1] = self.__name
end
box8["Looted?"] = true                   -- someone opened it (as in the game's case)
local coat = add(M8.TORSO, "Coat")
tick()
take(M8.TORSO, coat)
tick(); tick(); tick()
check(#destroyed == 1 and destroyed[1] == "Container_DeadPlayerLoot_C_8", "empty: destroyed")
local g = gone_msgs()
check(#g == 2 and g[1].args[2] == "75112" and g[1].args[3] == "63376", "DBOXGONE once to each client, at its real place")
for _ = 1, 15 do tick() end
check(#destroyed == 1, "still valid at (0, 0, 0) for 16 s: never destroyed again")
check(#gone_msgs() == 2, "no DBOXGONE at (0, 0, 0)")
check(count_log("Container_DeadPlayerLoot_C_8 is empty on the host") == 1, "host log: destroyed once")
tick(301); tick()
check(#destroyed == 1, "after the destroyed-list entry expires it still is not touched (no place)")
-- a box destroyed by someone else: valid, (0, 0, 0), opened and empty
local box9 = new_box("Container_DeadPlayerLoot_C_9", { X = 0, Y = 0, Z = 0 })
box9["Looted?"] = true
tick(); tick(); tick()
check(#destroyed == 1 and deathbox._state()[box9.__addr] == nil, "a box at (0, 0, 0) is skipped")
check(deathbox._real_loc ~= nil and deathbox._real_loc({ X = 0, Y = 0, Z = 0 }) == nil and deathbox._real_loc({ X = 5, Y = 0, Z = 0 }) ~= nil
  and deathbox._real_loc(nil) == nil, "real_loc: (0, 0, 0) and nil are no place")

-- ============================================================ 8. client: own box out of range
-- 0.7.1, 2026-11-12: the client's copy of its own death box (far away, out of
-- the network range) read (0, 0, 0); the host's DBOXGONE at (0, 0, 0) for
-- another box removed the marker of this one.
print("-- 8: client: a box out of range keeps its place, DBOXGONE at (0, 0, 0) is ignored")
for _, o in ipairs(world) do o.__valid = false end
world = {}
containers.reset()
S.role = "client"
logs = {}
local own, _, _, own_marker = new_box("Container_DeadPlayerLoot_C_10", { X = 126141, Y = 106119, Z = 1300 })
local other, _, _, other_marker = new_box("Container_DeadPlayerLoot_C_11", { X = 75112, Y = 63376, Z = 1341 })
T = T + 3; containers.client_tick()
own.__loc = { X = 0, Y = 0, Z = 0 }       -- the player walked away from it
T = T + 3; containers.client_tick()
local e10 = deathbox._track()[own.__addr]
check(e10 ~= nil and e10.loc.X == 126141, "the last real place of a box out of range is kept")
other.__valid = false                     -- the host destroyed it: the copy goes
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_2147379811", "75112", "63376", "1341" })
check(other_marker.__valid == false, "the removed box's marker removed")
check(own_marker.__valid ~= false, "own box's marker kept")
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_2147379811", "0", "0", "0" })
check(own_marker.__valid ~= false, "DBOXGONE at (0, 0, 0) (from an older host): own marker kept")
check(has_log("info", "sent no place (0, 0, 0): no marker removed here") ~= nil, "client log: ignored")
-- two boxes at one spot: one DBOXGONE removes one marker, the box whose copy went first
local boxA, _, _, markerA = new_box("Container_DeadPlayerLoot_C_12", { X = 5000, Y = 5000, Z = 100 })
local boxB, _, _, markerB = new_box("Container_DeadPlayerLoot_C_13", { X = 5050, Y = 5000, Z = 100 })
T = T + 3; containers.client_tick()
boxB.__valid = false
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_99", "5000", "5000", "100" })
check(markerB.__valid == false and markerA.__valid ~= false,
  "two boxes in reach: only the one whose copy went loses its marker (not the nearer one still standing)")
handlers.DBOXGONE({ "Container_DeadPlayerLoot_C_98", "5000", "5000", "100" })
check(markerA.__valid == false, "the next DBOXGONE there takes the other one")
local _b = boxA

-- ============================================================ 6. reset
containers.reset()
check(next(deathbox._state()) == nil and next(deathbox._track()) == nil, "reset clears the state")

-- ============================================================ 9. boxes saved with the world
-- 2026-11-13 (backlog 9.3): the game saves no Container_DeadPlayerLoot; a
-- restart or a load lost the dead player's things (in co-op a client's
-- record says "dead, the items are in the box"), and a box from after the
-- save could stand through an in-place load of it (items twice). The host's
-- saves now hold the boxes; a load puts back exactly the saved ones.
print("-- 9: death boxes saved with the world (deathbox_persist)")
for _, o in ipairs(world) do o.__valid = false end
world = {}
containers.reset()
S.role, S.in_menu = "host", false
logs, sent, destroyed = {}, {}, {}
local BS = deathbox._store
check(BS ~= nil, "store section present")

-- a fake of sdc_persist.files: blobs and text files in memory
local mem, blobs = {}, {}
local function copy_arr(v)
  if type(v) == "table" and v.ForEach and v.items then
    local out = {}
    for i, x in ipairs(v.items) do out[i] = copy_arr(x) end
    return arr(out)
  end
  if type(v) == "table" and not v.__cls then
    local out = {}
    for k, x in pairs(v) do out[k] = copy_arr(x) end
    return out
  end
  return v
end
local function walk(conts)
  local nc, ni = 0, 0
  conts:ForEach(function(_, c) nc = nc + 1; ni = ni + c:get()[F_ITEMS]:GetArrayNum() end)
  return "sig", nc, ni
end
local jdocs = {}
local F = {
  TAG = "_SDCoop", TEMP_SLOT = "SDCoop_ClientTemp",
  safe_slot = function(s) return s end,
  blob_name = function(slot, key, suffix) return slot .. "_SDCoop_" .. key .. (suffix or "") end,
  blob_write = function(slot, key, src, hot, loc)
    local name = slot .. "_SDCoop_" .. key
    if src.conts == nil or src.uids == nil or src.weights == nil then return nil, "copying the inventory arrays failed" end
    local _, nc, ni = walk(src.conts)
    blobs[name] = { conts = copy_arr(src.conts), uids = copy_arr(src.uids), loc = loc }
    return { file = name, containers = nc, items = ni }
  end,
  blob_load = function(name)
    local b = blobs[name]
    if not b then return nil, "missing" end
    return { JigContainers = copy_arr(b.conts), MainUIDs = copy_arr(b.uids), __cls = "BP_JigMPComponentSave_C" }
  end,
  blob_delete = function(slot, key) blobs[slot .. "_SDCoop_" .. key] = nil end,
  inv_walk = function(conts) return walk(conts) end,
  read = function(p) return mem[p] end,
  write = function(p, d) mem[p] = d; return true end,
  rotate = function(main, bak, tmp) mem[bak] = mem[main]; mem[main] = mem[tmp]; mem[tmp] = nil; return true end,
  exists = function(p) return mem[p] ~= nil end,
  remove = function(p) mem[p] = nil end,
}
package.loaded["sdc_persist"] = {
  files = F,
  savegames_dir = function() return "MEM/" end,
  json_encode = function(t) jdocs[#jdocs + 1] = copy_arr(t); return "JSON#" .. #jdocs end,
  json_decode = function(s) local i = tonumber(tostring(s):match("JSON#(%d+)")); return i and copy_arr(jdocs[i]) or nil end,
}

-- engine pieces for the spawn (SpawnDeadPlayerLoot's way)
local cur_slot = "Slot1"
local timers_cleared, dirty_marks, spawned = {}, {}, {}
function ue.ems_current_slot() return cur_slot end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v; return true end
function ue.world_context() return pc1 end
local ksl = { K2_ClearTimer = function(_, o, fn) timers_cleared[#timers_cleared + 1] = ue.short(o) .. ":" .. tostring(fn) end }
function ue.ksl() return ksl end
local gs = {}
function ue.gameplay_statics() return gs end
local box_cls = obj("BlueprintGeneratedClass", "Container_DeadPlayerLoot_C")
by_path["/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C"] = box_cls
by_path["/Script/Engine.Default__NetPushModelHelpers"] = obj("NetPushModelHelpers", "Default__NetPushModelHelpers", {
  MarkPropertyDirtyFromRepIndex = function(_, o, idx, name) dirty_marks[#dirty_marks + 1] = tostring(idx) .. ":" .. tostring(name._s) end })
local spawn_n = 0
function gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, coll, owner, scale)
  if cls ~= box_cls then return nil end
  spawn_n = spawn_n + 1
  local b, c = new_box("Container_DeadPlayerLoot_C_R" .. spawn_n, { X = tf.Translation.X, Y = tf.Translation.Y, Z = tf.Translation.Z })
  b.__coll = coll
  c.InitializeJigComponent = function(self) self.__init = true end
  c.OnRep_MainContainersIDs = function(self) self.__onrep = true end
  spawned[#spawned + 1] = b
  return b
end
function gs:FinishSpawningActor(a) return a end

local function count_items(b)
  local n = 0
  b.BP_JigMultiplayer.MainJigContainers:ForEach(function(_, c) n = n + c:get()[F_ITEMS]:GetArrayNum() end)
  return n
end
local function standing()
  local out = {}
  for _, o in ipairs(world) do if o.__cls == "Container_DeadPlayerLoot_C" and ue.valid(o) then out[#out + 1] = o end end
  return out
end
local function load_game()
  BS.on_load()
  S.in_menu = true
  T = T + 5
  BS.wait()
  S.in_menu = false
  T = T + 1
  BS.wait()
end

-- 9a. the host saves: a box with items is written, an empty one is not
local boxA, compA, MA = new_box("Container_DeadPlayerLoot_C_A", { X = 1000, Y = 2000, Z = 300 })
add(MA.TORSO, "Coat", 1, 0)
local bpk = add(MA.BACKPACK, "LargeBlackMilitaryBackpack")
local inpk = sub_container(compA, bpk, true)
add(inpk, "Ammo9mm", 30, 2)
local boxE = new_box("Container_DeadPlayerLoot_C_E", { X = 7000, Y = 0, Z = 0 })
BS.save("game save")   -- (no save end hook until 9h: the list is put in place at once)
local idx = package.loaded["sdc_persist"].json_decode(mem["MEM/Slot1_SDCoop_boxes.json"])
check(idx and #idx.boxes == 1 and idx.boxes[1].name == "Container_DeadPlayerLoot_C_A" and idx.boxes[1].items == 3,
  "save: the box with 3 items is in the slot's list, the empty one is not")
check(blobs["Slot1_SDCoop_box1_1"] ~= nil and idx.boxes[1].x == 1000 and idx.boxes[1].file == "Slot1_SDCoop_box1_1"
  and idx.gen == 1 and idx.boxes[1].key == "box1_1",
  "its Jig arrays written as Slot1_SDCoop_box1_1 (list generation 1), its place kept")
check(has_log("info", "deathbox: 1 death box(es) saved with slot Slot1: Container_DeadPlayerLoot_C_A (3 item(s): Coat") ~= nil,
  "host log names the saved box and its items")
local _be = boxE

-- 9b. a restart: no box in the world; the load of Slot1 puts it back
for _, o in ipairs(world) do o.__valid = false end
world = {}
containers.reset()
logs, sent = {}, {}
BS.on_load()
S.in_menu = true
T = T + 5
BS.wait()
check(#spawned == 0, "not while the world is not up (main menu / loading)")
S.in_menu = false
T = T + 1
BS.wait()
check(#spawned == 1 and count_items(spawned[1]) == 3, "the saved box is back with its 3 items")
local R1 = spawned[1]
check(R1.__loc.X == 1000 and R1.__loc.Y == 2000 and R1.__loc.Z == 300 and R1.__coll == 2, "at its saved place, spawned as the game does (collision 2)")
check(R1.BP_JigMultiplayer.__init and R1.BP_JigMultiplayer.__onrep and dirty_marks[#dirty_marks] == "3:MainContainersIDs",
  "InitializeJigComponent, MarkPropertyDirtyFromRepIndex(3) and OnRep_MainContainersIDs, as SpawnDeadPlayerLoot")
check(timers_cleared[#timers_cleared] == "Container_DeadPlayerLoot_C_R1:TraceForFloor",
  "its floor trace is stopped (it stays where it lay; the ground may not be loaded)")
check(has_log("info", "deathbox: slot Slot1 loaded (the game loaded a save): 1 death box(es) of that save put back") ~= nil,
  "host log")
BS.wait()
check(#spawned == 1, "put back once per load")
-- the restored box behaves as any box: it goes when emptied
tick()
check(deathbox._state()[R1.__addr] and deathbox._state()[R1.__addr].peak == 3, "the restored box is checked like any other")

-- 9c. an in-place load (the main menu and the world are one level): a box
-- from after the save is not in it and goes; the saved one comes back as saved
local boxD, _, MD = new_box("Container_DeadPlayerLoot_C_D", { X = 50000, Y = 0, Z = 100 })
add(MD.HEADWEAR, "Cap")
R1.BP_JigMultiplayer.MainJigContainers.items[5][F_ITEMS].items = {}   -- the backpack taken after the save
logs, sent = {}, {}
load_game()
check(boxD.__valid == false and R1.__valid == false, "boxes standing in the world are not in the save: removed")
check(#spawned == 2 and count_items(spawned[2]) == 3, "the saved box comes back as it was saved (3 items)")
local g9 = {}
for _, s in ipairs(sent) do if s.kind == "DBOXGONE" then g9[#g9 + 1] = s.args[1] end end
check(#g9 == 4, "the clients are told of both removed boxes (DBOXGONE x2 clients)")
check(has_log("info", "2 box(es) standing in the world removed (not in that save)") ~= nil, "logged")

-- 9d. persist_follow_host_save off: the clients' records stay live, so do the
-- boxes: nothing removed, nothing put back (2026-11-13 skeptic: a saved box
-- a client looted empty after the save came back full - the client kept the
-- items, its record is not rolled back)
CFG.persist_follow_host_save = false
local boxF, _, MF = new_box("Container_DeadPlayerLoot_C_F", { X = 60000, Y = 0, Z = 100 })
add(MF.HEADWEAR, "Helmet")
logs = {}
load_game()
check(boxF.__valid ~= false and spawned[2].__valid ~= false, "follow off: the standing boxes stay")
check(#spawned == 2, "follow off: no second copy where a box stands already")
spawned[2].__valid = false   -- the client took everything out of the saved box; the empty box went
logs = {}
load_game()
check(#spawned == 2, "follow off: a saved box looted empty after the save is NOT put back (the client kept the items)")
check(has_log("info", "persist_follow_host_save is off - the 1 death box(es) of that save are NOT put back and the 1 standing in the world stay") ~= nil,
  "logged")
CFG.persist_follow_host_save = nil
boxF.__valid = false

-- 9e. the box was emptied and removed: the next save keeps no box; the old
-- box file stays with the previous list (.bak) and goes with the save after
BS.save("game save")
idx = package.loaded["sdc_persist"].json_decode(mem["MEM/Slot1_SDCoop_boxes.json"])
local bak9 = package.loaded["sdc_persist"].json_decode(mem["MEM/Slot1_SDCoop_boxes.json.bak"])
check(idx and #idx.boxes == 0 and idx.gen == 2 and bak9 and bak9.gen == 1 and blobs["Slot1_SDCoop_box1_1"] ~= nil,
  "no box: the list (generation 2) is empty; the previous one is the .bak, its box file kept")
BS.save("game save")
check(blobs["Slot1_SDCoop_box1_1"] == nil, "the next save: the files of the list before the previous one are deleted")

-- 9f. not on a client, not with the setting off, never the throwaway slot
local boxG, _, MG = new_box("Container_DeadPlayerLoot_C_G", { X = 1, Y = 70000, Z = 0 })
add(MG.TORSO, "Vest")
local nb = 0
for _ in pairs(blobs) do nb = nb + 1 end
S.role = "client"
BS.save("x"); BS.on_load()
check(BS.pending == nil and next(blobs) == nil, "client: nothing saved, no restore pending")
S.role = "host"
CFG.deathbox_persist = false
check(mem["MEM/Slot1_SDCoop_boxes.json"] ~= nil, "(Slot1 has a list from the last save)")
BS.save("x")
check(next(blobs) == nil, "deathbox_persist off: nothing saved")
check(mem["MEM/Slot1_SDCoop_boxes.json"] == nil, "a save with it off deletes the slot's older list (it must not come back)")
CFG.deathbox_persist = nil
-- a slot without a list (a save from before this): which boxes it had is unknown - nothing removed or added
local sp0 = #spawned
logs = {}
load_game()
check(boxG.__valid ~= false and #spawned == sp0, "a slot without a list: the standing box stays, nothing spawned")
check(has_log("info", "it has no saved list of death boxes; the 1 standing in the world stay") ~= nil, "logged")
cur_slot = "SDCoop_ClientTemp"
BS.save("x")
check(next(blobs) == nil and mem["MEM/SDCoop_ClientTemp_SDCoop_boxes.json"] == nil, "the throwaway slot never gets boxes")
cur_slot = "Slot2"
BS.save("x")
check(blobs["Slot2_SDCoop_box1_1"] ~= nil and mem["MEM/Slot2_SDCoop_boxes.json"] ~= nil, "a save to another slot: its own list")
local _g = boxG
local _n = nb

-- 9g. the game deletes the slot: its box files go
BS.on_delete({ get = function() return "Slot2" end })
check(blobs["Slot2_SDCoop_box1_1"] == nil and mem["MEM/Slot2_SDCoop_boxes.json"] == nil, "slot deleted: its boxes deleted")
check(deathbox.store_status():find("saved=", 1, true) ~= nil, "status line: " .. deathbox.store_status())

-- 9h. the hooks: EMS's save / load / delete (shared native pre-hooks) and the
-- game's save end (BP_PlayerController OnCompleted / OnFailed); single player too
local subs, bp = {}, {}
function ue.hook_native(path, key, fn) subs[#subs + 1] = { path = path, key = key, fn = fn }; return true end
function RegisterHook(path, fn) bp[path] = fn; return 1, 2 end
for _, p in ipairs({ BS.SAVE_FN, BS.LOAD_FN, BS.DELETE_FN, BS.SAVED_FN, BS.FAILED_FN }) do
  by_path[p] = obj("Function", p:match(":(.+)$"))
end
local delays = {}
function ue.delay(label, ms, fn) delays[#delays + 1] = { label = label, ms = ms, fn = fn }; return true end
-- runs (and drops) the delayed calls with this label, in order
local function run(label)
  local list, n = delays, 0
  delays = {}
  for _, d in ipairs(list) do
    if d.label == label then n = n + 1; d.fn() else delays[#delays + 1] = d end
  end
  return n
end
local function jdoc(slot) return package.loaded["sdc_persist"].json_decode(mem["MEM/" .. slot .. "_SDCoop_boxes.json"]) end
deathbox.register_handlers()
check(#subs == 3 and subs[1].key == "deathbox" and subs[1].path == BS.SAVE_FN and subs[2].path == BS.LOAD_FN,
  "save, load and delete hooks in at install")
check(bp[BS.SAVED_FN] ~= nil and bp[BS.FAILED_FN] ~= nil and BS.hooks.saved_ok == true,
  "the game's save end hooks in (BP_PlayerController OnCompleted / OnFailed)")
local own_pc = obj("BP_PlayerController_C", "PC_own", { IsLocalController = function() return true end })
local far_pc = obj("BP_PlayerController_C", "PC_far", { IsLocalController = function() return false end })
local function save_end(fn_path, pc) bp[fn_path]({ get = function() return pc or own_pc end }) end
S.role = "standalone"
cur_slot = "Solo1"
subs[1].fn(); subs[1].fn()
check(#delays == 1 and delays[1].ms == 50, "one save: one write, 50 ms after the game's call")
run("deathbox-save")
check(BS.pend ~= nil and mem["MEM/Solo1_SDCoop_boxes.json"] == nil and blobs["Solo1_SDCoop_box1_1"] ~= nil,
  "the box file is written; the list waits for the game's save end")
save_end(BS.SAVED_FN, far_pc)
check(run("deathbox-saved") == 0 and BS.pend ~= nil, "a remote player's controller: not this save's end")
save_end(BS.SAVED_FN)
run("deathbox-saved")
check(BS.pend == nil and mem["MEM/Solo1_SDCoop_boxes.json"] ~= nil,
  "single player saves the boxes too: the game reports the save done, the list is in place")
run("deathbox-save-end")
check(BS.pend == nil and jdoc("Solo1").gen == 1, "(its 60 s guard does nothing then)")
subs[2].fn()
check(BS.pending ~= nil and delays[#delays].label == "deathbox-restore", "load hook: a restore is pending")
BS.pending = nil
delays = {}

-- 9i. 2026-11-13 (skeptic): the list was written 50 ms into every save, done
-- or not. After a FAILED save a load gave the last good save's world and
-- records (sdc_persist commits none) AND the box of a death after it: items
-- twice. The list now waits for the game's save end, like the commit.
print("-- 9i: the box list follows the game's save end")
local good = mem["MEM/Solo1_SDCoop_boxes.json"]
local boxH, _, MH = new_box("Container_DeadPlayerLoot_C_H", { X = 2, Y = 80000, Z = 0 })   -- a death after the good save
add(MH.TORSO, "Jacket")
logs = {}
subs[1].fn(); run("deathbox-save")
check(BS.pend and BS.pend.doc.gen == 2 and blobs["Solo1_SDCoop_box2_2"] ~= nil, "(the new list's files are written: generation 2)")
save_end(BS.FAILED_FN)
run("deathbox-saved")
check(BS.pend == nil and mem["MEM/Solo1_SDCoop_boxes.json"] == good and blobs["Solo1_SDCoop_box1_1"] ~= nil
  and blobs["Solo1_SDCoop_box2_1"] == nil and blobs["Solo1_SDCoop_box2_2"] == nil,
  "the game reports the save FAILED: the slot keeps its last list and files, the new files are deleted")
check(has_log("warn", "did not end well (the game reported it FAILED): its list of 2 death box(es) is NOT kept") ~= nil, "logged")
subs[1].fn(); run("deathbox-save")
check(BS.pend ~= nil, "(the next save waits too)")
run("deathbox-save-end")
check(BS.pend == nil and mem["MEM/Solo1_SDCoop_boxes.json"] == good and blobs["Solo1_SDCoop_box2_1"] == nil,
  "no end reported within 60 s: not kept either")
-- the end can come before the write (both 50 ms after the game's call)
subs[1].fn()
save_end(BS.SAVED_FN)
run("deathbox-saved")
run("deathbox-save")
check(BS.pend == nil and jdoc("Solo1").gen == 2 and #jdoc("Solo1").boxes == 2,
  "the save's end before the write ran: the list is put in place right after the write")
-- a newer save before the end replaces the waiting list; the world closes before the end
local d0 = BS.stats.dropped
subs[1].fn(); run("deathbox-save")
subs[1].fn(); run("deathbox-save")
check(BS.pend and BS.pend.doc.gen == 3 and BS.stats.dropped == d0 + 1, "a newer save before the end: it replaces the waiting list")
logs = {}
containers.reset()
check(BS.pend == nil and jdoc("Solo1").gen == 2 and blobs["Solo1_SDCoop_box3_1"] == nil,
  "the world closes before the game reported the save done: not kept (sdc_persist commits nothing then either)")
check(has_log("warn", "the world closed before the game reported it done") ~= nil, "logged")
check(deathbox.store_status():find("not kept=", 1, true) ~= nil, "status line: " .. deathbox.store_status())
-- "open for friends" reopens the world right after its save: the game's
-- "done" came, the world changes within the 50 ms before it is applied
subs[1].fn(); run("deathbox-save")
save_end(BS.SAVED_FN)
containers.reset()
check(BS.pend == nil and jdoc("Solo1").gen == 3, "the save's end came just before the world changed: the list is kept")
subs[1].fn(); run("deathbox-save")   -- the next save in the new world
run("deathbox-saved")
check(BS.pend ~= nil and jdoc("Solo1").gen == 3, "the delayed end, applied already, does not count for the next save")
save_end(BS.FAILED_FN); run("deathbox-saved")
delays = {}

-- 9j. 2026-11-13 (skeptic): every box standing at the restore went, also one
-- from a death in the seconds between the load's start and the restore -
-- with the dead player's freshly loaded things. Only the boxes standing as
-- the load starts are removed.
print("-- 9j: a box from a death after the load started stays")
S.role, S.in_menu = "host", false
for _, o in ipairs(world) do o.__valid = false end
world = {}
cur_slot = "Slot3"
local s3, _, M3 = new_box("Container_DeadPlayerLoot_C_S3", { X = 3000, Y = 3000, Z = 10 })
add(M3.TORSO, "Coat")
subs[1].fn(); run("deathbox-save"); save_end(BS.SAVED_FN); run("deathbox-saved")
check(jdoc("Slot3") and #jdoc("Slot3").boxes == 1, "(Slot3 saved with one box)")
local after, _, MA2 = new_box("Container_DeadPlayerLoot_C_AFTER", { X = 3500, Y = 3000, Z = 10 })   -- a death after the save
add(MA2.HEADWEAR, "Cap")
delays = {}
local sp3 = #spawned
logs = {}
subs[2].fn()   -- the game loads Slot3
local late, _, ML = new_box("Container_DeadPlayerLoot_C_LATE", { X = 3900, Y = 3000, Z = 10 })   -- a death meanwhile
add(ML.TORSO, "Vest")
T = T + 5
run("deathbox-restore")
check(s3.__valid == false and after.__valid == false, "the boxes standing as the load started are removed (not in that save)")
check(late.__valid ~= false and count_items(late) == 1, "a box from a death after the load started stays, with its things")
check(#spawned == sp3 + 1 and count_items(spawned[#spawned]) == 1, "the saved box is put back")
check(has_log("info", "1 box(es) from after the load started stay (a death meanwhile)") ~= nil, "logged")

-- 9k. a box removed at the load stays valid until the garbage collector (its
-- place may still read): the next save does not take it again
s3.__valid, after.__valid = true, true
subs[1].fn(); run("deathbox-save"); save_end(BS.SAVED_FN); run("deathbox-saved")
local names3 = {}
for _, e in ipairs(jdoc("Slot3").boxes) do names3[e.name] = true end
check(not names3["Container_DeadPlayerLoot_C_S3"] and not names3["Container_DeadPlayerLoot_C_AFTER"] and names3["Container_DeadPlayerLoot_C_LATE"]
  and #jdoc("Slot3").boxes == 2, "the next save: the restored and the late box, not the removed ones")
s3.__valid, after.__valid = false, false

-- 9l. a box file that holds other counts than its list says is not put back
local d3 = jdoc("Slot3")
d3.boxes[1].items = 99
mem["MEM/Slot3_SDCoop_boxes.json"] = package.loaded["sdc_persist"].json_encode(d3)
local sp4 = #spawned
logs = {}
subs[2].fn(); T = T + 5; run("deathbox-restore")
check(#spawned == sp4 + 1, "one of the two saved boxes put back; the one whose file does not match its list is not")
check(has_log("info", "| NOT put back: Container_DeadPlayerLoot_C_") ~= nil and has_log("info", "the list says 99") ~= nil, "logged as NOT put back")

-- 9m. a client never removes or puts back a box
S.role = "client"
local sp5 = #spawned
local stand5 = standing()
BS.restore("test", BS.standing_now())
local still = 0
for _, b in ipairs(stand5) do if b.__valid ~= false then still = still + 1 end end
check(#spawned == sp5 and still == #stand5 and #stand5 > 0, "client: BS.restore removes and adds nothing")
S.role = "host"

;(function()   -- (own locals: the main chunk is near Lua's 200-locals limit)
-- 9n. the game deletes a slot whose save still waits for its end: that list
-- goes too and does not come back with the end
cur_slot = "Slot5"
local b5, _, M5 = new_box("Container_DeadPlayerLoot_C_S5", { X = 5000, Y = 5000, Z = 10 })
add(M5.TORSO, "Coat")
delays = {}
subs[1].fn(); run("deathbox-save")
check(BS.pend and BS.pend.slot == "Slot5" and blobs["Slot5_SDCoop_box1_1"] ~= nil, "(Slot5's list waits for the save's end)")
BS.on_delete({ get = function() return "Slot5" end })
save_end(BS.SAVED_FN); run("deathbox-saved")
check(BS.pend == nil and mem["MEM/Slot5_SDCoop_boxes.json"] == nil and blobs["Slot5_SDCoop_box1_1"] == nil,
  "the slot is deleted while its save waits: the waiting list goes, the save's end does not bring it back")
-- an end that came before a write which then wrote nothing (the throwaway
-- slot) is not taken by the next save
cur_slot = "SDCoop_ClientTemp"
subs[1].fn(); save_end(BS.SAVED_FN); run("deathbox-saved"); run("deathbox-save")
cur_slot = "Slot5"
subs[1].fn(); run("deathbox-save")
check(BS.pend ~= nil and mem["MEM/Slot5_SDCoop_boxes.json"] == nil, "an earlier save's end does not put the next save's list in place")
save_end(BS.FAILED_FN); run("deathbox-saved")
b5.__valid = false

-- 9o. a new world between the load's start and the restore: the boxes noted
-- then were the old world's (here the same object stands for a new box that
-- got the same name and address)
cur_slot = "Slot3"
local w6, _, M6 = new_box("Container_DeadPlayerLoot_C_W6", { X = 6000, Y = 6000, Z = 10 })
add(M6.TORSO, "Coat")
delays = {}
subs[2].fn()          -- a load starts: W6 is noted
containers.reset()    -- a new world (sdc_session.reset_world)
T = T + 5; run("deathbox-restore")
check(w6.__valid ~= false, "a new world before the restore: a box under a name / address noted in the old one is not removed")
w6.__valid = false
end)()

;(function()   -- (own locals)
-- ============================================================ 10. a client's copy that comes into range
-- 2026-11-13 (dbox_1113_1901): the host died, a client opened the host's box,
-- drove 190 m away (its copy closed: the engine's 150 m range) and came back:
-- the new copy came in where the host's box lies, its place rounded to
-- 0.1 cm, under the surface by a hair; the box's own TraceForFloor (1 cm down
-- from the mesh every 0.01 s, the box 1 cm lower while it hits nothing) never
-- met the ground and the copy sank for good: the box vanished for the client.
-- Now a copy whose floor trace runs is lifted 5 cm (the game's trace meets the
-- ground from above); one that still falls 3 m below where it came in is put
-- on the ground found below that place, or back where it came in.
print("-- 10: client: a box copy that comes into range lies where the host has it")
for _, o in ipairs(world) do o.__valid = false end
world = {}
containers.reset()
S.role, S.in_menu = "client", false
logs, delays = {}, {}
local FL = deathbox._floor
check(FL ~= nil and FL.LIFT == 5 and FL.DROP_MAX == 300, "floor section present")

-- the engine: Role, moves, timers, the ground (one surface per test, or none)
local ground = 1182.437
local function on_ground(z_from, z_to) return ground ~= nil and z_from >= ground and z_to <= ground end
function ue.role(a) return ue.valid(a) and (a.Role or -1) or -1 end
function ue.teleport(a, l)
  if not ue.valid(a) then return false end
  a.__loc = { X = l.X, Y = l.Y, Z = l.Z }
  return true
end
function ue.vec(v)
  if type(v) ~= "table" or type(v.X) ~= "number" then return nil end
  return { X = v.X, Y = v.Y, Z = v.Z }
end
local me = obj("BP_PlayerCharacter_C", "Me", { __loc = { X = 124249, Y = 280445 + 15000, Z = 1272 } })
function ue.local_pawn() return me end
local traces = {}
ksl.K2_IsTimerActive = function(_, o, fn) return o.__timers ~= nil and o.__timers[fn] == true end
ksl.K2_ClearTimer = function(_, o, fn)
  timers_cleared[#timers_cleared + 1] = ue.short(o) .. ":" .. tostring(fn)
  if o.__timers then o.__timers[fn] = false end
end
ksl.LineTraceSingleForObjects = function(_, ctx, from, to, types, complex, ignore, dbg, hit, ignore_self)
  traces[#traces + 1] = { ctx = ctx, from = from, to = to, types = types, ignore = ignore, self = ignore_self }
  if not on_ground(from.Z, to.Z) then return false end
  hit.ImpactPoint = { X = from.X, Y = from.Y, Z = ground }
  return true
end
-- the box's own TraceForFloor, n runs (Container_DeadPlayerLoot TraceForFloor @0-847)
local function game_floor(b, n)
  for _ = 1, n do
    if not (b.__timers and b.__timers.TraceForFloor) then return end
    local z = b.__loc.Z
    if on_ground(z, z - 1) then
      b.__loc = { X = b.__loc.X, Y = b.__loc.Y, Z = ground }
      b.__timers.TraceForFloor = false
    else
      b.__loc = { X = b.__loc.X, Y = b.__loc.Y, Z = z - 1 }
    end
  end
end
-- a copy of the host's box coming in (its BeginPlay ran: its floor trace runs)
local copy_n = 0
local function copy_at(z, role, timer_on)
  copy_n = copy_n + 1
  local b = new_box("Container_DeadPlayerLoot_C_21474590" .. copy_n, { X = 124249, Y = 280445, Z = z })
  b.Role = role or ue.ROLE_SIMULATED
  b.__timers = { TraceForFloor = timer_on ~= false }
  return b
end
local function came(b) bp[FL.FN]({ get = function() return b end }) end
local function watch_out(b)   -- the game's trace and the watch, 0.5 s a round, until the watch ends
  local rounds = 0
  while #delays > 0 and rounds < 30 do
    game_floor(b, 50)
    run("deathbox-floor")
    rounds = rounds + 1
  end
  return rounds
end

-- 10a. the hook: once the box class is loaded, from the client's tick
T = T + 10; containers.client_tick()
check(bp[FL.FN] == nil and FL.hooked == false, "no hook while the box class is not loaded")
by_path[FL.FN] = obj("Function", "ReceiveBeginPlay")
T = T + 3; deathbox.client_tick()
check(bp[FL.FN] == nil, "the next try waits 5 s")
-- a hook the engine refuses: one warning, no more tries
local reg = RegisterHook
RegisterHook = function() error("no such function") end
T = T + 5; deathbox.client_tick()
local tried = FL.tried_at
T = T + 10; deathbox.client_tick()
check(FL.hooked == false and FL.gave_up == true and FL.tried_at == tried
  and has_log("warn", "deathbox: box copy hook (Container_DeadPlayerLoot ReceiveBeginPlay") ~= nil,
  "a refused hook: logged as a warning once, not tried again")
RegisterHook = reg
FL.gave_up, FL.tried_at = false, -100
T = T + 5; deathbox.client_tick()
check(bp[FL.FN] ~= nil and FL.hooked == true, "hooked: Container_DeadPlayerLoot ReceiveBeginPlay")
check(has_log("info", "deathbox: box copy hook (Container_DeadPlayerLoot ReceiveBeginPlay") ~= nil, "install logged")

-- 10b. the case of the log: the client comes back, the new copy comes in on
-- the ground with its place rounded down (1182.4 under 1182.437)
logs = {}
local c1 = copy_at(1182.4)
came(c1)
check(c1.__loc.Z == 1182.4 + 5, "the copy is lifted 5 cm over the place it came in at")
game_floor(c1, 100)
check(c1.__loc.Z == ground and c1.__timers.TraceForFloor == false,
  "the game's own floor trace meets the ground from above: the copy lies where the host has it")
check(run("deathbox-floor") == 1, "watched")
check(has_log("info", "deathbox: Container_DeadPlayerLoot_C_214745901 came into range here at (124249, 280445, 1182), 150 m from this player (lifted 5 cm for the game's floor trace): set down at z=1182, 0 cm below where it came in") ~= nil,
  "one line: where it came in, how far, set down")
check(#delays == 0, "no more checks once it is set down")
-- the same copy without the lift sinks for good (the bug)
local c0 = copy_at(1182.4)
game_floor(c0, 1000)
check(c0.__loc.Z < 1182.4 - 900, "(without the lift the game's trace never meets the ground: the copy sinks)")
c0.__valid = false

-- 10c. the copy made at the death: comes in at the chest, falls onto the ground
logs = {}
local c2 = copy_at(ground + 120.3)
came(c2)
game_floor(c2, 50)
run("deathbox-floor")
check(#delays == 1 and c2.__timers.TraceForFloor == true, "still falling after 0.5 s: watched on")
game_floor(c2, 100)
run("deathbox-floor")
check(c2.__loc.Z == ground and #delays == 0, "falls onto the ground as the game does")
check(has_log("info", "set down at z=1182, 120 cm below where it came in") ~= nil, "logged with its fall")

-- 10d. no lift (its trace did not run yet when the hook ran) and no ground
-- for the game's trace: 3 m below where it came in it is put on the ground
-- found below that place
logs, traces = {}, {}
local c3 = copy_at(1182.4, nil, false)
came(c3)
check(c3.__loc.Z == 1182.4, "not lifted: its floor trace does not run (yet)")
c3.__timers.TraceForFloor = true
local rounds = watch_out(c3)
check(c3.__loc.Z == ground and c3.__timers.TraceForFloor == false, "put on the ground found below where it came in, its trace stopped")
check(rounds <= 8, "within a few checks (" .. rounds .. ")")
check(#traces == 1 and traces[1].from.Z == 1182.4 + 50 and traces[1].ctx == c3 and traces[1].ignore[1] == c3
  and traces[1].types[1] == 0 and traces[1].types[2] == 1 and traces[1].self == true,
  "the ground is looked for from 50 cm above that place down, WorldStatic / WorldDynamic, the box itself ignored")
check(has_log("info", "still fell (no ground for the game's floor trace under it here): trace stopped, put on the ground found below that place (z=1182)") ~= nil,
  "logged")

-- 10e. no ground there at all: back where it came in
logs = {}
ground = nil
local c4 = copy_at(900)
came(c4)
watch_out(c4)
check(c4.__loc.Z == 900 and c4.__timers.TraceForFloor == false, "no ground found: back where it came in, its trace stopped")
check(has_log("info", "put back where it came in (no ground found below it)") ~= nil, "logged")
ground = 1182.437

-- 10f. a copy that goes out of range again while watched: the watch just ends
logs = {}
local c5 = copy_at(ground + 100)
came(c5)
c5.__valid = false
run("deathbox-floor")
check(#delays == 0 and #logs == 0, "a copy gone meanwhile: nothing more")

-- 10g. not a replicated copy: the host's own box (authority), and the host
logs = {}
local c6 = copy_at(1182.4, ue.ROLE_AUTHORITY)
came(c6)
check(c6.__loc.Z == 1182.4 and #delays == 0, "a box with authority here (single player / the host's) is left to the game")
S.role = "host"
local c7 = copy_at(1182.4)
came(c7)
check(c7.__loc.Z == 1182.4 and #delays == 0, "on the host nothing is done")
S.role = "client"
check(FL.stats.came == 5 and FL.stats.lifted == 4 and FL.stats.set_down == 2 and FL.stats.sank == 2,
  "counts: came / lifted / set down / sank")

-- 10h. the game's timer cannot be read here (K2_IsTimerActive fails or gives
-- no boolean; 2026-11-13 skeptic: a copy taken as set down at once would
-- sink unseen): not lifted; one that still falls is put on the ground 3 m
-- below where it came in, its trace stopped; one that lies still is taken as
-- set down only after the last check
local is_active = ksl.K2_IsTimerActive
for i, bad in ipairs({ function() error("no timer manager") end, function() return nil end, function() return 1 end }) do
  ksl.K2_IsTimerActive = bad
  logs = {}
  local lifted0, sank0, down0 = FL.stats.lifted, FL.stats.sank, FL.stats.set_down
  local c8 = copy_at(1182.4)
  came(c8)
  check(c8.__loc.Z == 1182.4 and FL.stats.lifted == lifted0, "timer unreadable (" .. i .. "): the copy is not lifted")
  watch_out(c8)
  check(c8.__loc.Z == ground and c8.__timers.TraceForFloor == false and FL.stats.sank == sank0 + 1
    and FL.stats.set_down == down0,
    "timer unreadable (" .. i .. "), the copy sinks: put on the ground found below where it came in, its trace stopped")
  check(has_log("info", "still fell (no ground for the game's floor trace under it here): trace stopped, put on the ground found below that place (z=1182)") ~= nil
    and has_log(nil, "set down at") == nil, "logged as fallen, not as set down")
  c8.__valid = false
  logs = {}
  local c9 = copy_at(ground)   -- on the ground: the game's trace meets it at once
  came(c9)
  local r9 = watch_out(c9)
  check(r9 == FL.CHECKS and c9.__loc.Z == ground and FL.stats.set_down == down0 + 1 and FL.stats.sank == sank0 + 1,
    "timer unreadable (" .. i .. "), the copy lies still: set down after the last of the " .. FL.CHECKS .. " checks (" .. r9 .. ")")
  check(has_log("info", "set down at z=1182, 0 cm below where it came in (its floor trace is not readable here)") ~= nil
    and has_log(nil, "still fell") == nil, "logged as set down, the timer noted as unreadable")
  c9.__valid = false
end
ksl.K2_IsTimerActive = is_active
for _, o in ipairs(world) do o.__valid = false end
world = {}
end)()

;(function()   -- (own locals)
-- ============================================================ 11. the client's own box made again: one marker
-- 2026-11-13 (skeptic): the client dies, respawns far away and comes back:
-- the copy of its own box made again (section 10) got its marker and the
-- floating widget removed ("not this player's death": the player is alive
-- by then), while the earlier copy's marker stayed - opening the box no
-- longer cleared it. Now the new copy keeps both as this player's, and the
-- earlier copy's marker goes, its time left carried over; a box opened
-- before (its marker gone) comes again with none, as in single player.
print("-- 11: client: a copy of the own box made again keeps one death marker")
for _, o in ipairs(world) do o.__valid = false end
world = {}
package.loaded["sdc_widgets"] = setmetatable({}, { __index = function() return function() end end })
function ue.name(o) return ue.valid(o) and o.__name or "<none>" end
local watches = {}
local notify = NotifyOnNewObject
NotifyOnNewObject = function(path, fn) watches[path] = fn end
S.role, S.client, S.remote = "client", {}, {}
local players = require("sdc_players")
players.init(S, {})
players.install_watches()
NotifyOnNewObject = notify
local on_box = watches["/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C"]
check(on_box ~= nil, "(sdc_players watches the death boxes)")
local cs = S.client
local pawn
function ue.local_pawn() return pawn end
-- a copy as BeginPlay leaves it: its marker (at the box's place then, 20 min)
-- and the floating widget
local copies = 0
local function copy_of(x, y, z)
  copies = copies + 1
  local b, _, _, m = new_box("Container_DeadPlayerLoot_C_21474300" .. copies, { X = x, Y = y, Z = z })
  m.__loc = { X = x, Y = y, Z = z }
  m.__life = 1200
  m.GetLifeSpan = function(self) return self.__life end
  m.SetLifeSpan = function(self, s) self.__life = s end
  b.DeathWidget = obj("WidgetComponent", "DeathWidget" .. copies)
  b.DeathWidget.K2_DestroyComponent = function(self) self.__valid = false end
  return b, m
end
local function arrives(b)
  logs, delays = {}, {}
  on_box(b)
  return run("death-marker")
end
local P = { X = 50000, Y = 60000, Z = 1000 }

-- 11a. the death: the body lies there, the box comes in at its chest
local body = obj("BP_PlayerCharacter_C", "Body", { __loc = { X = P.X, Y = P.Y, Z = P.Z + 90 }, ["PlayerDead?"] = true })
pawn, cs.last_pawn, cs.last_loc = nil, body, body.__loc
local a1, m1 = copy_of(P.X, P.Y, P.Z + 120.3)
check(arrives(a1) == 3, "(three checks of the new box)")
check(ue.valid(m1) and ue.valid(a1.DeathWidget) and #(cs.own_boxes or {}) == 1 and cs.own_boxes[1].mark == m1.__path,
  "the own box at the death: marker and widget kept, noted as this player's")
a1.__loc = { X = P.X, Y = P.Y, Z = P.Z }   -- it fell onto the ground

-- 11b. respawned 2 km away: the copy goes out of range (a destroyed actor
-- stays valid until the garbage collector, at (0, 0, 0)); a box of someone
-- else, far from the own one, comes in meanwhile
body.__valid = false
pawn = obj("BP_PlayerCharacter_C", "Me2", { __loc = { X = P.X + 200000, Y = P.Y, Z = 900 } })
cs.last_pawn, cs.last_loc = pawn, pawn.__loc
a1.__loc = { X = 0, Y = 0, Z = 0 }
local f1, fm1 = copy_of(P.X + 5000, P.Y, P.Z + 120)
arrives(f1)
check(not ue.valid(fm1) and not ue.valid(f1.DeathWidget) and ue.valid(m1),
  "someone else's box 50 m away: its marker and widget go, the own marker stays")
check(has_log("info", "death marker of " .. f1.__name .. " removed (not this player's death)") ~= nil, "logged")

-- 11c. back at the own box: its copy made again (on the ground) keeps its
-- marker and widget, the earlier copy's marker goes with its time left
m1.__life = 640
local a2, m2 = copy_of(P.X + 0.04, P.Y - 0.03, P.Z)
arrives(a2)
check(ue.valid(m2) and ue.valid(a2.DeathWidget), "the copy made again keeps its marker and floating widget")
check(not ue.valid(m1) and m2.__life == 640, "the earlier copy's marker goes; the new one has its 640 s left (one marker)")
check(#(cs.own_boxes or {}) == 1 and cs.own_boxes[1].box == a2.__path and cs.own_boxes[1].mark == m2.__path,
  "the record follows the new copy")
check(count_log("kept (this player's own box: its copy here came again, the earlier copy " .. a1.__name
  .. " went out of range); the earlier copy's marker removed, this one has its 640 s left") == 1
  and has_log(nil, "removed (") == nil, "logged once over the three checks, nothing removed")

-- 11d. two boxes at one spot: a box of someone else lying 30 cm from the own
-- one while the own copy still stands here is not taken for it
local f2, fm2 = copy_of(P.X + 30, P.Y, P.Z)
arrives(f2)
check(not ue.valid(fm2) and ue.valid(m2), "a box next to the own one that still stands here: not this player's")

-- 11e. the owner opens it (the game removes its marker and widget), goes
-- away and comes back: the copy made again shows none, as in single player
m2.__valid, a2.DeathWidget.__valid = false, false
a2.__loc = { X = 0, Y = 0, Z = 0 }
local a3, m3 = copy_of(P.X, P.Y, P.Z)
arrives(a3)
check(not ue.valid(m3) and not ue.valid(a3.DeathWidget), "opened before: the copy made again has no marker and no widget")
check(has_log("info", "death marker of " .. a3.__name .. " removed (this player's box, its marker gone already: opened, or its time ran out)") ~= nil,
  "logged as this player's box, opened before")

-- 11f. a destroyed marker that still reads valid (0, 0, 0) counts as gone
cs.own_boxes = {}
pawn, cs.last_pawn = nil, obj("BP_PlayerCharacter_C", "Body2", { __loc = { X = P.X, Y = P.Y + 9000, Z = P.Z }, ["PlayerDead?"] = true })
local b1, n1 = copy_of(P.X, P.Y + 9000, P.Z + 120)
arrives(b1)
pawn = obj("BP_PlayerCharacter_C", "Me3", { __loc = { X = P.X + 300000, Y = P.Y, Z = 900 } })
cs.last_pawn, cs.last_loc = pawn, pawn.__loc
b1.__loc, n1.__loc = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }
local b2, n2 = copy_of(P.X, P.Y + 9000, P.Z)
arrives(b2)
check(not ue.valid(n2), "the earlier marker destroyed (valid, at (0, 0, 0)): taken as gone, the new copy gets none")

-- 11g. a new connection starts with no own box (here the earlier marker
-- still stands: in the same connection the copy would be taken as own)
check(#(cs.own_boxes or {}) == 1, "(one record)")
n1.__loc = { X = P.X, Y = P.Y + 9000, Z = P.Z + 120 }
b2.__loc = { X = 0, Y = 0, Z = 0 }
S.client = {}
local b3, n3 = copy_of(P.X, P.Y + 9000, P.Z)
arrives(b3)
check(not ue.valid(n3) and ue.valid(n1), "a new connection: the boxes of the last one are not this player's")
S.client, S.remote = nil, nil
for _, o in ipairs(world) do o.__valid = false end
world = {}
end)()

print(string.format("death box: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
