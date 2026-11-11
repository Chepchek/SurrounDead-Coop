-- Mock harness: turrets in co-op (sdc_turrets).
-- Host: Multicast Muzzle Effect post-hook -> TURFIRE batched every 0.25 s,
-- only to clients within the fire sound's range; a turret near a remote
-- player that the host's optimizer switched off is woken (layer 0 handler);
-- TUROFF runs the bandit turret's own disable step (@31) on the host and the
-- state goes to the near clients (TURSTATE); TURHIT runs Server Turret Damaged.
-- Client: TURFIRE shown on the copy (aim, idle stop, its own Multicast Muzzle
-- Effect) unless the engine's multicast came; no copy -> the sound at the
-- place; a copy disabled here -> TUROFF + own pickup removed; TURSTATE ->
-- head removed / buildable health; own firearm hits -> TURHIT, melee not.
-- usage: lua mock_turrets.lua <scripts dir>
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
RegisterHook = function(path, fn) hooks[path] = fn; return 1, 2 end
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

-- ===================================================================== host
print("host")
local S = { role = "host", remote_pcs = {} }
turrets.install(S)
check(handlers.TURFIRE and handlers.TURSTATE and handlers.TUROFF and handlers.TURHIT, "four message handlers")
local near_pc = { __name = "NearPC" }
near_pc.Pawn = character("Near", 1000, 0, 0, false)
local far_pc = { __name = "FarPC" }
far_pc.Pawn = character("Far", 60000, 0, 0, false)
S.remote_pcs = { near_pc, far_pc }
me_pawn = character("Host", -20000, 0, 0, true)
me_pc = { __name = "HostPC", Pawn = me_pawn }
local bt, bt_comp, bt_mesh = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147475806", "BP_BanditTurret_AI_C", P_MASTER,
  0, 0, 100, 3, "camp")
local pt_, pt_comp = turret("Buildable_Turret_C_2147470001", "Buildable_Turret_C", P_BUILD, 3000, 0, 0, 3, "build")
turrets.tick()
check(hooks[P_COMP .. ":Multicast Muzzle Effect"] and hooks[P_BCOMP .. ":Multicast Muzzle Effect"]
  and hooks[P_MASTER .. ":Damage_Object"], "the three Blueprint hooks are registered once the classes exist")

print("host: shots are batched per client in range")
bt_comp.active, bt_comp.tick = false, false   -- the host's optimizer switched it off
for _ = 1, 3 do bt_comp["Multicast Muzzle Effect"](bt_comp, {}) end
check(#of_kind(sent, "TURFIRE") == 0, "nothing sent inside the shots")
T = T + 0.3
turrets.tick()
local tf = of_kind(sent, "TURFIRE")
check(#tf == 1 and tf[1].pc == "NearPC", "one TURFIRE, only to the client within the sound's range")
check(tf[1] and tf[1].args[1] == SOUND_PATH, "the fire sound path in the header: " .. tostring(tf[1] and tf[1].args[1]))
check(tf[1] and tf[1].args[2] == "BT,0,0,100,3,-5.0,120.0,1", "entry: code, place, 3 shots, head aim, sound#: " .. tostring(tf[1] and tf[1].args[2]))
check(count_log("fires on the host") == 1, "first shot of the turret logged once")
T = T + 0.8
turrets.tick()
check(count_calls("aio " .. bt.__name .. " false 0 true") == 1, "switched-off turret near a remote player woken with the optimizer's layer 0")
check(count_log("was switched off by the host's AI optimizer") == 1, "the wake is logged")
T = T + 0.3
turrets.tick()
check(#of_kind(sent, "TURFIRE") == 1, "no shot, no message")

print("host: a client's disable")
handlers.TUROFF({ "BT", "0", "0", "100" }, far_pc)
check(count_calls("ubergraph " .. bt.__name .. " 31") == 0, "refused: the sender is 600 m from it")
check(count_log("too far, not applied") == 1, "the refusal is logged")
near_pc.Pawn.__loc = { X = 200, Y = 0, Z = 0 }
handlers.TUROFF({ "BT", "0", "0", "100" }, near_pc)
check(count_calls("ubergraph " .. bt.__name .. " 31") >= 1, "the bandit turret's own disable step @31 ran on the host")
check(bt_comp.Dead == true and bt_comp["Can Attack"] == false and bt_mesh.__valid == false, "dead, cannot attack, head destroyed")
check(count_calls("pickup-spawned " .. bt.__name) == 1, "the game's TurretGun pickup spawned (once)")
check(count_log("the game's disable step @31 ran on the host") >= 1, "the disable is logged")
T = T + 0.3
turrets.tick()
local ts = of_kind(sent, "TURSTATE")
local got_dead = false
for _, m in ipairs(ts) do for _, a in ipairs(m.args) do if a == "BT,0,0,100,1,-1" and m.pc == "NearPC" then got_dead = true end end end
check(got_dead, "the near client gets TURSTATE 'disabled' on the next tick")
local hp_sent = false
for _, m in ipairs(ts) do for _, a in ipairs(m.args) do if a == "PT,3000,0,0,0,100" then hp_sent = true end end end
check(hp_sent, "and the buildable's health")
for _, m in ipairs(ts) do check(m.pc ~= "FarPC", "nothing to the far client") end
local n_ts = #ts
T = T + 1.1
turrets.tick()
check(#of_kind(sent, "TURSTATE") == n_ts, "unchanged state is not sent again")
pt_comp["Current Health"] = 60
T = T + 1.1
turrets.tick()
local hp2 = false
for _, m in ipairs(of_kind(sent, "TURSTATE")) do for _, a in ipairs(m.args) do if a == "PT,3000,0,0,0,60" then hp2 = true end end end
check(hp2, "a buildable's new health goes out")

print("host: a client's hits")
local st2, st2_comp = turret("ChildActor2_GEN_VARIABLE_BP_SurvivorTurret_AI_C_CAT_2147475800", "BP_SurvivorTurret_AI_C", P_MASTER,
  5000, 0, 0, 3, "camp")
T = T + 1.1
turrets.tick()
handlers.TURHIT({ "ST,5000,0,0,45.5" }, near_pc)
check(count_calls("damaged " .. st2.__name .. " 45.5") == 1, "Server Turret Damaged ran on the host's turret with the damage")
check(st2_comp["Current Health"] == 55, "health 100 -> 55")
handlers.TURHIT({ "ST,5000,0,0,99999" }, near_pc)
check(st2_comp.Dead == true, "damage clamped, still kills it")
handlers.TURHIT({ "ST,5000,0,0,10" }, near_pc)
check(count_calls("damaged " .. st2.__name .. " 10.0") == 0 and count_calls("damaged " .. st2.__name .. " 10") == 0, "a dead turret takes no more")
handlers.TURHIT({ "garbage" }, near_pc)
handlers.TURHIT({}, near_pc)
handlers.TUROFF({}, near_pc)
handlers.TUROFF({ "XX", "1", "2", "3" }, near_pc)
check(errors() == 0, "bad input: no errors")

-- ==================================================================== client
print("client")
turrets.reset("test")
actors = {}
calls, sent, to_host, played = {}, {}, {}, {}
for k, v in pairs(objects) do if rawget(v, "__runtime") then objects[k] = nil end end
S.role = "client"
S.remote_pcs = {}
me_pawn = character("Me", 0, 500, 100, true)
me_pc = { __name = "MyPC", Pawn = me_pawn }
local c1, c1_comp, c1_mesh = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460001", "BP_BanditTurret_AI_C", P_MASTER,
  0.4, -0.3, 100.2, 1, "camp")
local c2, c2_comp = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460002", "BP_BanditTurret_AI_C", P_MASTER,
  8000, 0, 100, 1, "camp")
local cb, cb_comp = turret("Buildable_Turret_C_2147460003", "Buildable_Turret_C", P_BUILD, 3000, 0, 0, 1, "build")
c1_comp.tick = false       -- the replicated deactivation
T = T + 1.1
turrets.tick()
local function count_both(a, b)
  local n = 0
  for _, l in ipairs(logs) do if l:find(a, 1, true) and l:find(b, 1, true) then n = n + 1 end end
  return n
end
check(count_both("copy " .. c1.__name .. " (BT at", "role=1 (the host's, replicated)") == 1
  and count_log("role=1 (the host's, replicated)") == 3,
  "first sight of each copy logged once with its role / component state")
check(count_both("copy " .. c1.__name, "did not tick here") == 1, "the wake of a copy is logged")
check(count_calls("aio " .. c1.__name .. " false 0 true") == 1, "a copy within 100 m that does not tick is woken")
check(count_calls("aio " .. c2.__name .. " false 0 true") == 0, "a ticking copy is left alone")

print("client: a relayed shot without the engine multicast")
handlers.TURFIRE({ SOUND_PATH, "BT,0,0,100,2,-10.0,45.0,1" })
check(count_calls("muzzle " .. c1.__name) == 1, "the copy's own Multicast Muzzle Effect ran")
check(count_calls("idle-stop " .. c1.__name) == 1, "its idle sweep stopped")
check(c1_mesh.rot.Yaw == 45 and c1_mesh.rot.Pitch == -10, "head set to the host's aim (no target here)")
T = T + 0.15
run_delays()
check(count_calls("muzzle " .. c1.__name) == 2, "the second shot of the batch a moment later")
check(count_log("the host's fire multicast reached this client") == 0, "the module's own calls are not taken for the engine's")
check(count_log("no engine multicast here: shown by") == 1, "the relayed shot is logged once")

print("client: the engine's multicast arrives")
c2_comp["Multicast Muzzle Effect"](c2_comp, {})   -- as the engine runs it on the copy
check(count_log("the host's fire multicast reached this client for " .. c2.__name) == 1, "engine arrival logged")
local m2 = count_calls("muzzle " .. c2.__name)
handlers.TURFIRE({ SOUND_PATH, "BT,8000,0,100,1,0.0,10.0,1" })
check(count_calls("muzzle " .. c2.__name) == m2, "a turret the engine already shows is not shown twice")

print("client: a turret with no copy here")
handlers.TURFIRE({ SOUND_PATH, "BT,0,9000,100,1,0.0,10.0,1" })
check(#played == 1 and played[1].s == sound, "its fire sound at its place")
handlers.TURFIRE({ SOUND_PATH, "BT,0,90000,100,1,0.0,10.0,1" })
check(#played == 1, "not when it does not carry this far")

print("client: idle sweep again after the last relayed shot")
T = T + 3.5
turrets.tick()
check(count_calls("idle-start " .. c1.__name) == 1, "Multicast Turret Idle Start after 3 s without shots")

print("client: disabled on this machine")
local own = pickup("BP_TurretGunPickup_C_2147460100", 0, 0, 150, 3)
local hosts = pickup("BP_TurretGunPickup_C_2147460101", 0, 0, 150, 1)
c1["ExecuteUbergraph_BP_BanditTurret_AI"](c1, 31)   -- IsHeld false: nothing
c1.IsHeld = true
c1["ExecuteUbergraph_BP_BanditTurret_AI"](c1, 31)
T = T + 1.1
turrets.tick()
local off = of_kind(to_host, "TUROFF")
check(#off == 1 and off[1].args[1] == "BT" and off[1].args[2] == "0" and off[1].args[4] == "100", "TUROFF with the copy's class and place")
check(own.__valid == false and hosts.__valid ~= false, "only this client's own pickup removed, the host's stays")
T = T + 1.1
turrets.tick()
check(#of_kind(to_host, "TUROFF") == 1, "sent once")

print("client: the host says a turret is disabled")
handlers.TURSTATE({ "BT,8000,0,100,1,-1", "PT,3000,0,0,0,60" })
check(c2_comp.Dead == true and c2_comp["Can Attack"] == false and count_calls("head-destroyed " .. c2.__name) == 1,
  "copy off: dead, cannot attack, head destroyed")
check(count_calls("hp " .. cb.__name .. " 60") == 1 and cb_comp["Current Health"] == 60, "buildable health into its bar")
T = T + 1.1
turrets.tick()
check(#of_kind(to_host, "TUROFF") == 1, "a turret the host disabled is not reported back")
local c2m = count_calls("muzzle " .. c2.__name)
T = T + 4
handlers.TURFIRE({ SOUND_PATH, "BT,8000,0,100,1,0.0,10.0,1" })
check(count_calls("muzzle " .. c2.__name) == c2m, "a disabled copy shows no shots")

print("client: state for a copy that is not here yet")
handlers.TURSTATE({ "BT,-7000,0,100,1,-1" })
local c3, c3_comp = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460004", "BP_BanditTurret_AI_C", P_MASTER,
  -7000, 0, 100, 1, "camp")
T = T + 1.1
turrets.tick()
check(c3_comp.Dead == true and count_calls("head-destroyed " .. c3.__name) == 1, "applied when the copy appears")
check(#of_kind(to_host, "TUROFF") == 1, "and not reported back")

print("client: own hits")
local c4, c4_comp = turret("ChildActor1_GEN_VARIABLE_BP_BanditTurret_AI_C_CAT_2147460005", "BP_BanditTurret_AI_C", P_MASTER,
  2000, 2000, 100, 1, "camp")
local DO = P_MASTER .. ":Damage_Object"
fire_hook(DO, c4, 41.0, me_pawn, nil)
fire_hook(DO, c4, 41.0, me_pawn, nil)
local other = character("Other", 0, 0, 0, false)
fire_hook(DO, c4, 50.0, other, nil)
check(#of_kind(to_host, "TURHIT") == 0, "nothing inside the shots")
T = T + 0.3
turrets.tick()
local th = of_kind(to_host, "TURHIT")
check(#th == 1 and th[1].args[1] == "BT,2000,2000,100,82.0", "one TURHIT with the sum of the own hits: " .. tostring(th[1] and th[1].args[1]))
me_pawn.BP_JigHelperComp.ActiveWeapon.TagName = "Jig.PlayerSlot.MeleeWeapon"
fire_hook(DO, c4, 30.0, me_pawn, nil)
T = T + 0.3
turrets.tick()
check(#of_kind(to_host, "TURHIT") == 1, "a melee hit is left to the host's copy of the swing")
fire_hook(DO, nil, nil, nil)
fire_hook(DO, c4, "x", me_pawn)
fire_hook(P_COMP .. ":Multicast Muzzle Effect", nil)
handlers.TURFIRE({})
handlers.TURFIRE({ "", "garbage", ",,,," })
handlers.TURSTATE({ "garbage" })
check(errors() == 0, "bad input: no errors")
check(turrets.status_line():find("[client]", 1, true) ~= nil, "status line")

print(string.format("%d checks, %d failed", checks, fails))
if fails == 0 then print("ALL OK") end
