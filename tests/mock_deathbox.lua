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
local function obj(cls, name, t)
  t = t or {}
  next_addr = next_addr + 8
  t.__cls, t.__name, t.__addr = cls, name, next_addr
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

print(string.format("death box: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
