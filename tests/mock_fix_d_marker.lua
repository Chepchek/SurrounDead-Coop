-- Critic fix D / A4 + A6 (2026-11-13): quest markers (sdc_quests).
-- An actor destroyed with K2_DestroyActor stays valid for ~30 s (until GC)
-- and reads 0,0,0. The client's destroy_marker + spawn_marker (a respawn, a
-- repeated QM) found its own just-destroyed marker as "placed by this
-- player's own quest already" and placed nothing. The host sent a destroyed
-- marker at 0,0,0 to a joiner. The marker class / texture of a QM come from a
-- message: a client takes them only from memory (no synchronous load) and
-- tries a missing class again later.
-- usage: lua mock_fix_d_marker.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local logs = {}
local log = setmetatable({ debug_enabled = false, probes_enabled = false }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })
local function has_log(pat)
  for _, l in ipairs(logs) do if l:find(pat, 1, true) then return l end end
  return nil
end

-- ---------------------------------------------------------------- fake world
local MARKER = "/Game/Quests/Blueprints/Objects/BP_QuestMarker.BP_QuestMarker_C"
local TEX = "/Game/UI/Icons/T_Camp.T_Camp"
local objects, paths = {}, {}
local next_n = 2147400000
local function tarray(list)
  return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end }
end
local function marker(tag, loc, runtime)
  next_n = next_n - 1
  local m = { __name = "BP_QuestMarker_C_" .. next_n, __cls = "BP_QuestMarker_C", __runtime = runtime ~= false,
              __loc = loc, Tags = tarray({ tag }) }
  -- as in the engine: still valid after K2_DestroyActor, at 0,0,0
  m.K2_DestroyActor = function(self) self.__destroyed = true; self.__loc = { X = 0, Y = 0, Z = 0 } end
  objects[#objects + 1] = m
  return m
end
local spawned = {}
local gs = {
  BeginDeferredActorSpawnFromClass = function(_, _, cls, tf)
    assert(cls == paths[MARKER], "spawned with the marker class")
    local m = marker("?", { X = tf.Translation.X, Y = tf.Translation.Y, Z = tf.Translation.Z })
    m.Tags = nil
    spawned[#spawned + 1] = m
    return m
  end,
  FinishSpawningActor = function(_, a) return a end,
}

local ue = setmetatable({ ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }, { __index = function()
  return function() return nil end
end })
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.missing(v) return v == nil end
function ue.has_prop(o, n) return type(o) == "table" and o[n] ~= nil end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.name(o) return ue.valid(o) and ((o.__cls or "Object") .. " /Game/Map.Map:PersistentLevel." .. (o.__name or "obj")) or "<none>" end
function ue.path(o) return ue.valid(o) and (o.__path or "") or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.location(a) return ue.valid(a) and a.__loc or nil end
function ue.is_runtime_spawned(a) return a.__runtime == true end
function ue.find_all(cls)
  local out = {}
  for _, o in ipairs(objects) do if o.__cls == cls and ue.valid(o) then out[#out + 1] = o end end
  return out
end
function ue.find_object(p) return paths[p] end
local sync_loads = {}
function ue.load_asset(p) sync_loads[#sync_loads + 1] = p; return false, nil end
local mem_logged = {}
function ue.loaded_asset(p, who)
  local o = paths[p]
  if not o and not mem_logged[p] then mem_logged[p] = true; log.info("asset: %s not in memory (%s)", p, tostring(who)) end
  return o
end
function ue.gameplay_statics() return gs end
local my_pc = { __name = "PC_0", __cls = "BP_PlayerController_C" }
function ue.local_pc() return my_pc end
function ue.local_pawn() return nil end
function ue.pawn_of(pc) return pc.__pawn end
function ue.in_main_menu() return false end
function ue.game_thread(_, fn) fn() end
function ue.delay(_, _, fn) end
function ue.call() return false end

local sent, handlers = {}, {}
local cfgv = {}
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function(k)
  local v = cfgv[k]
  if v ~= nil then return v end
  if k:match("^quest_") or k:match("^trade_") then return true end
  return nil
end }
package.loaded["sdc_net"] = {
  send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc, kind = kind, f = { ... } }; return true end,
  send_to_host = function(kind, ...) sent[#sent + 1] = { kind = kind, f = { ... } }; return true end,
  broadcast = function() end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ctx"] = { player_for = function() return nil end, classify = function() return "?" end,
  addr = function(o) return o and o.__name end }
RegisterHook = function() error("no such function") end
NotifyOnNewObject = function() end
FName = function(s) return s end
FText = function(s) return s end
LoadAsset = function() error("synchronous LoadAsset") end

local quests = require("sdc_quests")
local S = { role = "client", remote_pcs = {} }
quests.init(S)
quests.register_handlers()
local function qm(...) handlers.QM({ ... }, nil) end
local function placed(tag)
  local n = 0
  for _, m in ipairs(spawned) do if not m.__destroyed and m.__loc and m.__loc.X ~= 0 then n = n + 1 end end
  return n
end

paths[MARKER] = { __name = "BP_QuestMarker_C", __cls = "BlueprintGeneratedClass" }
paths[TEX] = { __name = "T_Camp", __cls = "Texture2D" }

print("== client: markers")
quests.client_tick(100, my_pc, { __name = "Pawn_1" })
qm("a", "T1", "100", "200", "300", TEX, "Camp", "1", "0", "0", "1", "0")
check(#spawned == 1 and spawned[1].__loc.X == 100, "QM: marker placed at the host's point")
check(spawned[1]["Marker Texture"] == paths[TEX], "QM: texture in memory set")
local first = spawned[1]

-- respawn: the old marker goes (still valid until GC), a new one is placed
-- (regression guard: our own spawned markers carry no tag)
quests.client_tick(101, my_pc, { __name = "Pawn_2" })
check(first.__destroyed == true, "new character: the old marker destroyed")
check(#spawned == 2 and not spawned[2].__destroyed and spawned[2].__loc.X == 100,
  "new character: the marker placed again (the destroyed one, still valid, is not 'placed by the own quest')")
check(has_log("1 quest marker(s) placed again") ~= nil, "new character: logged")

-- the same QM again (the host resends it): replaced, not lost
qm("a", "T1", "150", "200", "300", TEX, "Camp", "1", "0", "0", "1", "0")
check(spawned[2].__destroyed == true and #spawned == 3 and spawned[3].__loc.X == 150 and not spawned[3].__destroyed,
  "repeated QM: the old marker replaced by the new one")
check(placed() == 1, "one live marker for T1")

-- this player's own quest placed T2 here: not placed twice
marker("T2", { X = 5, Y = 5, Z = 5 }, true)
local n0 = #spawned
qm("a", "T2", "5", "5", "5", "", "Own", "1", "1", "1", "1", "0")
check(#spawned == n0 and has_log("quest marker 'T2' is placed here by this player's own quest already") ~= nil,
  "own quest's live marker: no second one")

-- the critic's case: this player's own quest placed T3, the game's
-- RemoveMarker destroyed it (still valid until GC, at 0,0,0), the quest's
-- next marker with the same tag comes from the host: it must be placed
local dead = marker("T3", { X = 3, Y = 3, Z = 3 }, true)
qm("a", "T3", "3", "3", "3", "", "Stage 1", "1", "1", "1", "1", "0")
check(#spawned == n0, "own quest's T3: not placed twice")
dead:K2_DestroyActor()
dead.__destroyed = nil
qm("a", "T3", "7", "8", "9", "", "Gone", "1", "1", "1", "1", "0")
check(#spawned == n0 + 1 and spawned[#spawned].__loc.X == 7 and dead.__destroyed == nil,
  "own quest's T3 destroyed by the game (valid, 0,0,0): the next QM for T3 is placed")

-- a texture path that is not a texture: ignored
paths["/Game/Not/A.Tex"] = { __name = "A", __cls = "SoundWave" }
qm("a", "T5", "1", "1", "1", "/Game/Not/A.Tex", "x", "1", "1", "1", "1", "0")
check(spawned[#spawned]["Marker Texture"] == nil, "a QM texture path of another class is not set")

-- the marker class not in memory: nothing loaded synchronously, tried again
local cls = paths[MARKER]
paths[MARKER] = nil
local n1 = #spawned
qm("a", "T4", "11", "12", "13", TEX, "Later", "1", "1", "1", "1", "0")
check(#spawned == n1, "class not in memory: no marker yet")
local loaded_marker = false
for _, p in ipairs(sync_loads) do if p == MARKER or p == TEX then loaded_marker = true end end
check(not loaded_marker, "class not in memory: no synchronous load of the QM's class / texture on the client")
quests.client_tick(102, my_pc, { __name = "Pawn_2" })
check(#spawned == n1, "retry: still not in memory, nothing")
paths[MARKER] = cls
quests.client_tick(103, my_pc, { __name = "Pawn_2" })
check(#spawned == n1, "retry waits 5 s")
quests.client_tick(108, my_pc, { __name = "Pawn_2" })
check(#spawned == n1 + 1 and spawned[#spawned].__loc.X == 11, "retry: placed once the class is in memory")
quests.client_tick(114, my_pc, { __name = "Pawn_2" })
check(#spawned == n1 + 1, "retry: not placed twice")

print("== host (group design): a joiner's markers")
quests.reset("test")
objects, spawned = {}, {}
cfgv.quest_own = false
S.role = "host"
local live = marker("Camp1", { X = 10, Y = 20, Z = 30 }, true)
live.Text = "Camp"
local gone = marker("Camp2", { X = 40, Y = 50, Z = 60 }, true)
gone:K2_DestroyActor()   -- removed by the game: valid, 0,0,0
local rpc = { __name = "PC_1", __cls = "BP_PlayerController_C", __pawn = { __name = "Pawn_R" } }
S.remote_pcs = { rpc }
sent = {}
quests.host_tick(200)
local tags = {}
for _, m in ipairs(sent) do if m.kind == "QM" then tags[#tags + 1] = m.f[2] end end
check(#tags == 1 and tags[1] == "Camp1", "joiner: the live marker sent, the destroyed one (0,0,0) not: " .. table.concat(tags, ","))

local bad = 0
for _, l in ipairs(logs) do
  if l:find("^err") and not l:find("BP_QuestMarker (in memory: false)", 1, true) then print("    " .. l); bad = bad + 1 end
end
check(bad == 0, "no errors logged (but the expected missing-class line)")

if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
