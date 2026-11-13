-- Group C critic fixes (2026-11-13) in sdc_turrets: a hook whose registration failed is tried
-- again (A2: up to 0.7.3 "failed" counted as done), and the client's per-copy tables (first
-- seen, woken, disable sent / told) lose the copies that are gone (A7: a camp turret streams in
-- under a new path each time). The harness is mock_turrets.lua's.
-- usage: lua mock_fix_c_turrets.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local logs = {}
local log = setmetatable({ debug_enabled = true }, { __index = function(_, k)
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
local function errors()
  local n = 0
  for _, l in ipairs(logs) do if l:sub(1, 4) == "err:" or l:sub(1, 14) == "err_throttled:" then n = n + 1 end end
  return n
end

local T = 1000
os.clock = function() return T end

-- ------------------------------------------------------------ world objects
local P_MASTER = "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterTurret.BP_MasterTurret_C"
local P_BUILD = "/Game/Blueprints/BuildingSystem/Actors/Turret/Buildable_TurretMASTER.Buildable_TurretMASTER_C"
local P_COMP = "/Game/SmartAI/Blueprints/AI/Components/BP_TurretAIComponent.BP_TurretAIComponent_C"
local P_BCOMP = "/Game/SmartAI/Blueprints/AI/Components/BP_BuildableTurretAIComponent.BP_BuildableTurretAIComponent_C"
local P_PICKUP = "/Game/Inventory/Items/Pickups/Other/BP_TurretGunPickup.BP_TurretGunPickup_C"
local AIO = "BndEvt__BP_CookingStation_AIOSubject_K2Node_ComponentBoundEvent_0_OnOptimizationUpdate__DelegateSignature"
local SOUND_PATH = "/Game/Audio/Weapons/M16_Single_Shot_2_Cue.M16_Single_Shot_2_Cue"

local hooks = {}
local fail_left, attempts = {}, {}   -- [path] = registrations that still fail / were tried
RegisterHook = function(path, fn)
  attempts[path] = (attempts[path] or 0) + 1
  if (fail_left[path] or 0) > 0 then fail_left[path] = fail_left[path] - 1; error("UFunction::Func 0x0") end
  hooks[path] = fn; return 1, 2
end
local function fire_hook(path, ctx_obj, ...)
  local fn = hooks[path]
  if not fn then return false end
  local args = { ... }
  local wrapped = {}
  for i = 1, select("#", ...) do local v = args[i]; wrapped[i] = { get = function() return v end } end
  fn({ get = function() return ctx_obj end }, table.unpack(wrapped, 1, select("#", ...)))
  return true
end

local objects = {}      -- [path] = object (find_object)
local actors = {}       -- list of world actors (GetAllActorsOfClass)
local classes = {}
for _, p in ipairs({ P_MASTER, P_BUILD, P_PICKUP }) do classes[p] = { __cls = "UClass", __path = p }; objects[p] = classes[p] end
for _, p in ipairs({ P_COMP .. ":Multicast Muzzle Effect", P_BCOMP .. ":Multicast Muzzle Effect", P_MASTER .. ":Damage_Object" }) do
  objects[p] = { __cls = "Function", __path = p }
end
local sound = { __cls = "SoundCue", __path = SOUND_PATH, __name = "M16_Single_Shot_2_Cue" }
objects[SOUND_PATH] = sound

local calls = {}        -- recorded game calls
local function rec(what) calls[#calls + 1] = what end
local function count_calls(what) local n = 0 for _, c in ipairs(calls) do if c == what then n = n + 1 end end return n end

local function turret(name, cls, base, x, y, z, role, kind)
  local a = { __name = name, __cls = cls, __base = base, __path = "/Game/Maps/L.L:PersistentLevel." .. name,
              __loc = { X = x, Y = y, Z = z }, Role = role, __runtime = true, IsHeld = false }
  local mesh = { __name = name .. ".Turret", rot = { Pitch = -5, Yaw = 120, Roll = 0 } }
  function mesh:K2_GetComponentRotation() return self.rot end
  function mesh:K2_SetWorldRotation(r) self.rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0 }; rec("aim " .. name) end
  function mesh:K2_DestroyComponent(owner) self.__valid = false; rec("head-destroyed " .. name) end
  a.Turret = mesh
  local comp = { __name = name .. ".AI", Dead = false, ["Can Attack"] = true, ["Current Health"] = 100,
                 active = true, tick = true, FireSound = sound }
  function comp:GetOwner() return a end
  function comp:IsActive() return self.active end
  function comp:IsComponentTickEnabled() return self.tick end
  function comp:Activate() self.active = true; self.tick = true end
  function comp:SetComponentTickEnabled(v) self.tick = v end
  comp["Multicast Muzzle Effect"] = function(self, hit)
    rec("muzzle " .. name)
    -- UE4SS: the post-hook runs after the function, wherever it ran
    fire_hook((kind == "build" and P_BCOMP or P_COMP) .. ":Multicast Muzzle Effect", self, hit)
  end
  comp["Server Turret Damaged"] = function(self, dmg)
    rec("damaged " .. name .. " " .. tostring(dmg))
    self["Current Health"] = self["Current Health"] - math.floor(dmg)
    if self["Current Health"] <= 0 then self["Current Health"] = 0; self.Dead = true end
  end
  if kind == "build" then a.BP_BuildableTurretAIComponent = comp else a.BP_TurretAIComponent = comp end
  a[AIO] = function(self, beyond, layer, seen)
    rec(string.format("aio %s %s %d %s", name, tostring(beyond), layer, tostring(seen)))
    if layer == 0 then comp.active = true; comp.tick = true end
  end
  a["Multicast Turret Idle Stop"] = function() rec("idle-stop " .. name) end
  a["Multicast Turret Idle Start"] = function() rec("idle-start " .. name) end
  a.UpdateHealth = function(self, hp) rec("hp " .. name .. " " .. tostring(hp)) end
  a.ExecuteUbergraph_BP_BanditTurret_AI = function(self, entry)
    rec("ubergraph " .. name .. " " .. tostring(entry))
    if entry == 31 and self.IsHeld then
      self.IsHeld = false
      comp.Dead = true
      comp["Can Attack"] = false
      rec("pickup-spawned " .. name)
      mesh:K2_DestroyComponent(self)
    end
  end
  function a:K2_DestroyActor() self.__valid = false; rec("destroyed " .. name) end
  objects[a.__path] = a
  actors[#actors + 1] = a
  return a, comp, mesh
end

local function pickup(name, x, y, z, role)
  local p = { __name = name, __cls = "BP_TurretGunPickup_C", __base = P_PICKUP, __path = "/Game/Maps/L.L:PersistentLevel." .. name,
              __loc = { X = x, Y = y, Z = z }, Role = role, __runtime = true }
  function p:K2_DestroyActor() self.__valid = false; rec("pickup-removed " .. name) end
  actors[#actors + 1] = p
  return p
end

local played = {}
local gps = {}
function gps:GetAllActorsOfClass(_, cls, out)
  for _, a in ipairs(actors) do
    if a.__valid ~= false and a.__base == cls.__path then out[#out + 1] = a end
  end
end
function gps:PlaySoundAtLocation(_, s, loc) played[#played + 1] = { s = s, x = loc.X, y = loc.Y } end

-- ------------------------------------------------------------ module mocks
local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.str(v) if v == nil then return "" end return tostring(v) end
function ue.short(o) return ue.valid(o) and (rawget(o, "__name") or "obj") or "<none>" end
function ue.name(o) return ue.short(o) end
function ue.path(o) return rawget(o, "__path") or "" end
function ue.class_name(o) return ue.valid(o) and (rawget(o, "__cls") or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.call(o, f, ...) if not ue.valid(o) then return false end local args = { ... } return pcall(function() return o[f](o, table.unpack(args)) end) end
function ue.find_object(p) local o = objects[p]; if ue.valid(o) then return o end return nil end
function ue.location(a) local l = ue.valid(a) and a.__loc; if l then return { X = l.X, Y = l.Y, Z = l.Z } end end
function ue.role(a) return a and a.Role or -1 end
function ue.is_runtime_spawned(a) return a and a.__runtime == true end
local me_pawn, me_pc = nil, nil
function ue.local_pawn() return me_pawn end
function ue.local_pc() return me_pc end
function ue.pawn_of(pc) local p = pc and pc.Pawn; if ue.valid(p) then return p end end
function ue.gameplay_statics() return gps end
function ue.world_context() return me_pc end
local delayed = {}
function ue.delay(label, ms, fn) delayed[#delayed + 1] = { due = T + ms / 1000, fn = fn } end
local function run_delays()
  local list = delayed
  delayed = {}
  for _, d in ipairs(list) do if d.due <= T + 1e-9 then d.fn() else delayed[#delayed + 1] = d end end
end
setmetatable(ue, { __index = function(_, k) return function() return nil end end })
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return nil end }
local sent, to_host, handlers = {}, {}, {}
package.loaded["sdc_net"] = {
  send_to = function(pc, kind, ...) sent[#sent + 1] = { pc = pc.__name, kind = kind, args = { ... } } return true end,
  broadcast = function() end,
  send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, args = { ... } } return true end,
  on = function(k, h) handlers[k] = h end }
package.loaded["sdc_ownsounds"] = {
  range_of = function(s) return 30000, nil end,
  audible_here = function(at, range)
    local l = me_pawn and me_pawn.__loc
    if not l then return false end
    local d = math.sqrt((l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2)
    return d <= range + 500, d
  end }

local function character(name, x, y, z, local_ctl, slot)
  local p = { __name = name, __cls = "BP_PlayerCharacter_C", __loc = { X = x, Y = y, Z = z } }
  function p:IsLocallyControlled() return local_ctl end
  p.BP_JigHelperComp = { __name = name .. ".Helper", ActiveWeapon = { TagName = slot or "Jig.PlayerSlot.PrimaryWeapon" } }
  return p
end
local function of_kind(list, kind)
  local out = {}
  for _, m in ipairs(list) do if m.kind == kind then out[#out + 1] = m end end
  return out
end

local turrets = require("sdc_turrets")
local MUZZLE = P_COMP .. ":Multicast Muzzle Effect"

-- ===================================================================== A2
print("A2. a hook whose registration fails is tried again")
local S = { role = "host", remote_pcs = {} }
turrets.install(S)
me_pawn = character("Host", 0, 0, 0, true)
me_pc = { __name = "HostPC", Pawn = me_pawn }
fail_left[MUZZLE] = 2
fail_left[P_MASTER .. ":Damage_Object"] = 1000
turrets.tick()
check(hooks[MUZZLE] == nil and count_log("hook BP_TurretAIComponent Multicast Muzzle Effect FAILED") == 1
  and count_log("tried again every 5 s (up to 24 tries)") >= 1, "A2: the first try failed: one line, tried again")
check(hooks[P_BCOMP .. ":Multicast Muzzle Effect"] ~= nil, "A2: the others registered")
T = T + 5.1
turrets.tick()
check(hooks[MUZZLE] == nil and attempts[MUZZLE] == 2
  and count_log("hook BP_TurretAIComponent Multicast Muzzle Effect FAILED") == 1, "A2: the second try failed, no second line")
T = T + 5.1
turrets.tick()
check(hooks[MUZZLE] ~= nil and count_log("hook BP_TurretAIComponent Multicast Muzzle Effect ok (try 3)") == 1,
  "A2: registered on the third try (0.7.3: \"failed\" was truthy, never again)")
for _ = 1, 30 do T = T + 5.1; turrets.tick() end
check(attempts[P_MASTER .. ":Damage_Object"] == 24 and count_log("hook BP_MasterTurret Damage_Object FAILED 24 times, given up") == 1,
  "A2: one that never registers: given up after 24 tries")

-- ===================================================================== A7
print("A7. the client's per-copy tables lose the copies that are gone")
turrets.reset("test")
S.role = "client"
me_pawn = character("Me", 0, 500, 100, true)
me_pc = { __name = "MyPC", Pawn = me_pawn }
local c1, c1_comp = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460001", "BP_BanditTurret_AI_C", P_MASTER,
  0, 0, 100, 1, "camp")
local c2, c2_comp = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460002", "BP_BanditTurret_AI_C", P_MASTER,
  2000, 0, 100, 1, "camp")
c1_comp.Dead = true          -- disabled on this machine: TUROFF, off_sent
c2_comp.tick = false         -- switched off by the host's optimizer: woken here, cwoken
T = T + 1.1
turrets.tick()
local st = turrets._t.st()
check(st.seen[c1.__path] and st.seen[c2.__path] and st.off_sent[c1.__path] and st.cwoken[c2.__path],
  "A7: both copies recorded (first seen, disable sent, woken)")
handlers.TURSTATE({ "BT,0,0,100,1,-1" })
check(st.off_host[c1.__path] == true, "A7: the host's 'disabled' recorded")
-- both stream out; they come back under new paths (camp prefabs)
c1.__valid, c2.__valid = false, false
local c3 = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460077", "BP_BanditTurret_AI_C", P_MASTER,
  0, 0, 100, 1, "camp")
T = T + 1.1
turrets.tick()
local function n(t) local k = 0; for _ in pairs(t) do k = k + 1 end; return k end
check(st.seen[c1.__path] == nil and st.seen[c2.__path] == nil and st.off_sent[c1.__path] == nil
  and st.off_host[c1.__path] == nil and st.cwoken[c2.__path] == nil, "A7: the gone copies' entries dropped (0.7.3: kept for good)")
check(st.seen[c3.__path] == true and n(st.seen) == 1, "A7: the copy that is here stays")
-- a scan that could not list a class keeps everything (an incomplete list)
gps.GetAllActorsOfClass = function() error("no world") end
T = T + 1.1
turrets.tick()
check(st.seen[c3.__path] == true, "A7: nothing dropped on a failed scan")

print(string.format("turrets fixes: %d passed, %d failed", checks - fails, fails))
print(fails == 0 and "ALL OK" or "FAILED")
