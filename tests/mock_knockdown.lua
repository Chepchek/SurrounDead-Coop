-- Mock test: knockdown and revive by a teammate (sdc_down + sdc_down_pose,
-- host rule down_enabled) with the real sdc_ffire / sdc_config / sdc_i18n /
-- sdc_log and a stub engine (characters, health, the game's damage path and
-- Deathbringer, zombies, HUD, keys), sdc_ai (its shared hooks run the way
-- its dispatcher runs them), sdc_net, sdc_vehicles, sdc_widgets.
--   1  settings and texts
--   2  hook entries, gates: single player and the rule off stay vanilla
--   3  candidates and rescuers (old clients, the dead, the joining)
--   4  the hit: probe, measure (the post-hook's (Context, ReturnValue,
--      params) order), decision (armour, Deathbringer, own state, own
--      grenade, shotgun, water, nobody to help, nothing taken)
--   5  friendly fire off / on (sdc_ffire first), nobody finishes a downed player
--   6  down: health 1, protection, tag, burn, zombies (50 m, again every
--      second), DOWN only to DOWNCAP
--   7  revive: shared progress, interrupted, distance, health 10..25, bleeding
--   8  ends: bleed-out, give up, nobody left, moved, binding, left, rule off
--   9  the host down: pause buttons (only with the cursor shown, the HUD's
--      PauseMenu, a full search at most once a second), saves, a client revives it
--  10  vehicles: client unseated / host out, 2 s, landing, the floor
--  11  the grenadier (ApplyRadialDamage): sight traced at the blast with the
--      grenadier ignored, the flags back first
--  12  saved / left while down (sdc_persist's restore), F7
--  13  null objects in every hook; the fuse (not for a death of another
--      cause after a measured probe; Deathbringer during the probe kept)
--  14  client: rule notices, DOWNCAP, pose, flags, freeze without stacking,
--      give up (a fresh press), revive keys, own death, timeouts, DOWNQ, the
--      frame's cost (bar / pose / freeze / aim not every frame), a remapped
--      interact key (the plain-table array result)
--  15  the real sdc_players; 15b debug commands' delayed calls (fresh objects)
--  16  sources: the wiring in main / net / admin / ui / players / vehicles /
--      savecheck / persist / session, no RegisterKeyBind
-- usage: lua mock_knockdown.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end
local function say(s) io.write(s, "\n") end

FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
RegisterConsoleCommandHandler = function() end
local keybinds = 0
RegisterKeyBind = function() keybinds = keybinds + 1 end

local CLK = 100.0
os.clock = function() return CLK end
local function advance(s) CLK = CLK + s end

-- ------------------------------------------------------------ fake objects
local CRASHES = 0
-- a null UObject: any method call on it is the 17:36 crash
local NONE = setmetatable({ _invalid = true }, {
    __index = function(_, k)
        if k == "_invalid" then return true end
        CRASHES = CRASHES + 1
        error("CRASH: " .. tostring(k) .. " on a null object")
    end,
})
local next_addr = 1000
local function obj(class, name, props)
    next_addr = next_addr + 16
    local o = props or {}
    o._class, o._name, o._addr = class, name, next_addr
    return o
end
local function valid(o) return type(o) == "table" and rawget(o, "_invalid") == nil and not o._gone end

local W = { chars = {}, zombies = {}, objects = {}, find = {}, trace = { ok = true, hit = false, at = nil } }
local FINDS = {}     -- [class] = FindAllOf calls (ue.find_all)
local DELAYED = {}   -- ue.delay callbacks (run by the test)
W.objects["/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage"] = obj("AnimMontage", "Chr_SittingFloor_Montage")
W.objects["/Game/Character/Anims/Interaction/Chr_Interact_Looting_Montage.Chr_Interact_Looting_Montage"] = obj("AnimMontage", "Chr_Interact_Looting_Montage")
W.objects["/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"] = obj("Class", "BP_MasterZombie_C")
local FLOOR = W.objects["/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage"]
local LOOT = W.objects["/Game/Character/Anims/Interaction/Chr_Interact_Looting_Montage.Chr_Interact_Looting_Montage"]
local BODY = obj("BlueprintGeneratedClass", "Damage_Body_C")
local DTYPE = obj("Class", "DamageType")
local pushes = 0
W.objects["/Script/Engine.Default__NetPushModelHelpers"] = obj("Class", "Push", {
    MarkPropertyDirtyFromRepIndex = function() pushes = pushes + 1 end })
local BBLIB = obj("Class", "BBLib", { GetBlackboard = function(_, ctrl) return ctrl.Blackboard end })
W.objects["/Script/AIModule.Default__AIBlueprintHelperLibrary"] = BBLIB

local function tags(list)
    local t = {}
    for i, n in ipairs(list) do t[i] = n end
    t.ForEach = function(self, fn) for i, n in ipairs(self) do fn(i, { get = function() return n end }) end end
    return t
end
local function has_tag(p, n) for _, x in ipairs(p.Tags) do if x == n then return true end end return false end

local HUD = obj("HUD_Game_C", "HUD", { opened = 0 })
HUD.InteractTimerUI = function(self, open, text)
    if open then
        self.opened = self.opened + 1
        self.InteractTimerWidget = obj("InteractionTimerUI_C", "Timer" .. self.opened, { CurrentTime = 0, MaxTime = 0, text = text })
    else
        self.InteractTimerWidget = nil
    end
end

local function player(name, pid, x, y, remote)
    local ps = obj("PlayerState", name .. "_PS")
    ps.GetPlayerId = function() return pid end
    ps.GetPlayerName = function() return name end
    local med = obj("MedicalComponent", name .. "_Med", { Health = 100, ["CanTakeDamage?"] = true, ["Bleed?"] = false })
    med["OnRep_Bleed?"] = function(self) self.onrep = (self.onrep or 0) + 1 end
    local cmc = obj("CharacterMovementComponent", name .. "_CMC", { MovementMode = 1, falling = false, swimming = false, disabled = 0 })
    cmc.IsFalling = function(self) return self.falling end
    cmc.IsSwimming = function(self) return self.swimming end
    cmc.DisableMovement = function(self) self.MovementMode = 0; self.disabled = self.disabled + 1 end
    cmc.SetMovementMode = function(self, m) self.MovementMode = m end
    local helper = obj("BP_JigHelperComp_C", name .. "_Helper", { ActiveWeapon = { TagName = "Weapon.Knife" } })
    local jig = obj("BP_JigMultiplayer_C", name .. "_Jig", { toggles = 0 })
    jig.ToggleInventory = function(self)
        self.toggles = self.toggles + 1
        if self.InventoryWidgetRef then self.InventoryWidgetRef = nil end
    end
    local pc = obj("BP_PlayerController_C", name .. "_PC", { PlayerState = ps, keys = {}, ignore = 0, sets = 0, resets = 0 })
    if remote then pc.NetConnection = obj("NetConnection", name .. "_Conn") end
    pc.IsInputKeyDown = function(self, fk) return self.keys[fk.KeyName] == true end
    pc.IsMoveInputIgnored = function(self) return self.ignore > 0 end
    pc.SetIgnoreMoveInput = function(self, b) if b then self.ignore = self.ignore + 1; self.sets = self.sets + 1 end end
    pc.ResetIgnoreMoveInput = function(self) self.ignore = 0; self.resets = self.resets + 1 end
    pc.GetHUD = function() return HUD end
    pc.LineOfSightTo = function() return true end
    pc.bShowMouseCursor = false
    local p = obj("BP_PlayerCharacter_C", name, {
        MedicalComponent = med, CharacterMovement = cmc, PlayerState = ps, Controller = pc, BP_JigHelperComp = helper,
        BP_JigMultiplayer = jig, Mesh = obj("Mesh", name .. "_Mesh", { bOnlyAllowAutonomousTickPose = remote and true or false }),
        CapsuleComponent = obj("Capsule", name .. "_Cap"),
        _loc = { X = x, Y = y, Z = 100 }, Tags = tags({ "ZombieCanAttack", "Player" }),
        ["PlayerDead?"] = false, ["InVehicle?"] = false, ["DeathbringerSkillUsed?"] = false, ["Burning?"] = false,
        ["ClimbingLadder?"] = false, sent_hp = {}, stopped_burn = 0, montage_log = {}, stops = {}, db_unlocked = false, div = 1,
    })
    p.SendHealthToClient = function(self, v) self.sent_hp[#self.sent_hp + 1] = v end
    p.StopBurning = function(self) self.stopped_burn = self.stopped_burn + 1; self["Burning?"] = false end
    p.Deathbringer = function(self, out)
        if self["DeathbringerSkillUsed?"] or not self.db_unlocked then out["Used?"] = false return end
        self.MedicalComponent.Health = 25
        self["DeathbringerSkillUsed?"] = true
        out["Used?"] = true
    end
    p.PlayAnimMontage = function(self, m) self._montage = m; self.montage_log[#self.montage_log + 1] = m._name end
    p.GetCurrentMontage = function(self) return self._montage end
    p.StopAnimMontage = function(self, m) if self._montage == m then self._montage = nil end end
    p.StopMontage = function(self, m, inc) self.stops[#self.stops + 1] = m._name end
    p.PlayMontage = function(self, m) self._montage = m; self.played = (self.played or 0) + 1 end
    p.ServerFuncChangeActiveSlot = function(self, t) self.BP_JigHelperComp.ActiveWeapon = { TagName = t.TagName } end
    p.GetAttachParentActor = function(self) return self._parent end
    p.ActorHasTag = function(self, n) return has_tag(self, n) end
    pc.Pawn = p
    W.chars[#W.chars + 1] = p
    return p, pc
end

local host_pawn, host_pc = player("Host", 256, 0, 0, false)
local a_pawn, a_pc = player("Ann", 257, 150, 0, true)
local b_pawn, b_pc = player("Bob", 258, 0, 150, true)
local o_pawn, o_pc = player("Old", 259, 5000, 0, true)   -- an older mod: no DOWNCAP
W.me_pc = host_pc
local CAM = obj("CameraManager", "Cam", { loc = { X = 0, Y = 0, Z = 160 }, pitch = 0, yaw = 0 })
CAM.GetCameraLocation = function(self) return self.loc end
CAM.GetCameraRotation = function(self) return { Pitch = self.pitch, Yaw = self.yaw } end
for _, pc in ipairs({ host_pc, a_pc, b_pc, o_pc }) do pc.PlayerCameraManager = CAM end

-- the game's ApplyDamage (sdc_ai's dispatcher: pre entries, the engine, post entries)
local entries = {}
local handles = {}
local installs = 0
local function run_entries(path, kind, ...)
    for _, e in ipairs(entries) do
        if e.path == path and e.kind == kind then
            local okg, open = pcall(e.gate)
            if okg and open == true then
                local ok, err = pcall(e.fn, ...)
                if not ok then say("  (dispatch error " .. e.name .. ": " .. tostring(err) .. ")") end
            end
        end
    end
end
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end, v = function() return v end } end
local AD = "/Script/Engine.GameplayStatics:ApplyDamage"
local ARD = "/Script/Engine.GameplayStatics:ApplyRadialDamage"
local deaths = {}
local function engine_damage(victim, dmg)
    if not valid(victim) or victim._class ~= "BP_PlayerCharacter_C" then return end
    local m = victim.MedicalComponent
    if m["CanTakeDamage?"] == false or victim["PlayerDead?"] then return end
    m.Health = math.max(0, math.min(100, m.Health - dmg / (victim.div or 1)))
    victim:SendHealthToClient(m.Health)
    if m.Health <= 0 then
        local out = {}
        victim:Deathbringer(out)
        if not out["Used?"] then
            victim["PlayerDead?"] = true
            deaths[#deaths + 1] = victim._name
        end
    end
end
local GPS = obj("GameplayStatics", "GPS")
-- UE4SS: a pre-hook gets (Context, params...); a post-hook of a function with
-- a return value gets (Context, ReturnValue, params...) (LuaMod.cpp)
GPS.ApplyDamage = function(self, victim, dmg, inst, causer, dtype)
    local pv, pd = param(victim), param(dmg)
    run_entries(AD, "pre", self, pv, pd, param(inst), param(causer), param(dtype))
    if pd.v() ~= 0 then engine_damage(victim, pd.v()) end
    run_entries(AD, "post", self, param(pd.v()), pv, pd, param(inst), param(causer), param(dtype))
    return pd.v()
end
local function hit(victim, dmg, causer, dtype)
    return GPS:ApplyDamage(victim, dmg, nil, causer == nil and NONE or causer, dtype == nil and NONE or dtype)
end
local function radial(dmg, o, r, causer)
    local pd = param(dmg)
    run_entries(ARD, "pre", GPS, param(nil), pd, param(o), param(r), param(BODY), param({}), param(causer or NONE), param(NONE), param(true), param(4))
    for _, p in ipairs({ host_pawn, a_pawn, b_pawn }) do
        local l = p._loc
        local dx, dy, dz = l.X - o.X, l.Y - o.Y, l.Z - o.Z
        if math.sqrt(dx * dx + dy * dy + dz * dz) <= r then engine_damage(p, pd.v()) end
    end
end

local KSL = obj("KSL", "KSL")
KSL.SphereOverlapActors = function(_, wc, loc, r, types, cls, ignore, out)
    W.overlap_r = r
    for _, z in ipairs(W.zombies) do
        local l = z._loc
        local d = l and math.sqrt((l.X - loc.X) ^ 2 + (l.Y - loc.Y) ^ 2 + (l.Z - loc.Z) ^ 2) or 0
        if d <= r then out[#out + 1] = z end
    end
    return true
end
KSL.LineTraceSingle = function(_, wc, from, to, ch, complex, ignore, dbg, hit_out, self_ign, c1, c2, t)
    W.trace.calls = (W.trace.calls or 0) + 1
    W.trace.channel = ch
    W.trace.ignore = ignore
    if not W.trace.ok then error("trace broken") end
    -- the grenadier's own body right at the blast's centre: blocks unless ignored
    if W.trace.body then
        local ignored = false
        for _, a in ipairs(ignore or {}) do if a == W.trace.body then ignored = true end end
        if not ignored then
            hit_out.ImpactPoint = { X = from.X, Y = from.Y, Z = from.Z + 20 }
            return true
        end
    end
    if W.trace.hit then
        hit_out.ImpactPoint = W.trace.at or { X = to.X, Y = to.Y, Z = to.Z }
        return true
    end
    return false
end
KSL.GetConsoleVariableBoolValue = function() return false end

local function zombie(target, loc)
    local bb = obj("Blackboard", "BB", { vals = { AttackTarget = target }, bools = {} })
    bb.GetValueAsObject = function(self, k) return self.vals[k] end
    bb.SetValueAsBool = function(self, k, v) self.bools[k] = v end
    bb.ClearValue = function(self, k) self.vals[k] = nil end
    bb.SetValueAsVector = function(self, k, v) self.vals[k] = v end
    local ctrl = obj("BP_ZombieAIController_C", "ZC", { Blackboard = bb, Combat = true })
    return obj("BP_Zombie_C", "Zombie", { Controller = ctrl, _loc = loc or { X = 0, Y = 0, Z = 100 } }), bb, ctrl
end

-- ------------------------------------------------------------ stub modules
local function copyloc(l) return l and { X = l.X, Y = l.Y, Z = l.Z } or nil end
package.loaded["sdc_ue"] = {
    valid = valid,
    try = function(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end,
    prop = function(o, k) if not valid(o) then return nil end return o[k] end,
    set_prop = function(o, k, v) if not valid(o) then return false end o[k] = v return true end,
    location = function(o) return valid(o) and copyloc(o._loc) or nil end,
    rotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
    teleport = function(o, l) if valid(o) then o._loc = copyloc(l); o.teleports = (o.teleports or 0) + 1 return true end end,
    local_pc = function() return W.me_pc end,
    local_pawn = function() return W.me_pc and valid(W.me_pc.Pawn) and W.me_pc.Pawn or nil end,
    pawn_of = function(pc) return valid(pc) and valid(pc.Pawn) and pc.Pawn or nil end,
    short = function(o) return valid(o) and o._name or "<none>" end,
    name = function(o) return valid(o) and o._name or "<none>" end,
    class_name = function(o) return valid(o) and o._class or "" end,
    str = function(v) if v == nil then return "" end return tostring(v) end,
    vec = function(v) if type(v) == "table" and type(v.X) == "number" then return { X = v.X, Y = v.Y, Z = v.Z } end end,
    -- as sdc_ue.elem: an element param's value (get()), else the element itself
    elem = function(e)
        if type(e) == "table" and rawget(e, "_invalid") == nil and type(rawget(e, "get")) == "function" then
            local ok, v = pcall(e.get, e)
            if ok then return v end
        end
        return e
    end,
    player_chars = function() local out = {} for _, p in ipairs(W.chars) do if valid(p) then out[#out + 1] = p end end return out end,
    find_all = function(cls) FINDS[cls] = (FINDS[cls] or 0) + 1 return W.find[cls] or {} end,
    find_object = function(path) return W.objects[path] end,
    loaded_asset = function(path) return W.objects[path] end,
    load_asset = function(path) return W.objects[path] ~= nil, W.objects[path] end,
    ksl = function() return KSL end,
    gameplay_statics = function() return GPS end,
    game_instance = function() return nil end,
    delay = function(_, _, fn) DELAYED[#DELAYED + 1] = fn end, every = function() end, exec = function() end,
    sub_time = function(_, fn, ...) return pcall(fn, ...) end,
}
local ue = package.loaded["sdc_ue"]
package.loaded["sdc_ctx"] = {
    addr = function(o) return valid(o) and o._addr or nil end,
    class_name = function(o) return valid(o) and o._class or "" end,
}
package.loaded["sdc_ai"] = {
    hook_external = function(spec)
        entries[#entries + 1] = spec
        local h = handles[spec.path]
        if not h then h = { installed = false }; handles[spec.path] = h end
        return h
    end,
    install_now = function() installs = installs + 1 end,
}
local sent, to_host, handlers = {}, {}, {}
package.loaded["sdc_net"] = {
    on = function(kind, fn) handlers[kind] = fn end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc._name, kind = kind, f = { ... } } return true end,
    send_to_host = function(kind, ...) to_host[#to_host + 1] = { kind = kind, f = { ... } } return true end,
    broadcast = function() end,
}
local function sent_of(kind, to, f1, f2)
    local out = {}
    for _, m in ipairs(sent) do
        if m.kind == kind and (to == nil or m.to == to) and (f1 == nil or m.f[1] == f1) and (f2 == nil or m.f[2] == f2) then
            out[#out + 1] = m
        end
    end
    return out
end
local function host_got(kind, f1) local n = 0 for _, m in ipairs(to_host) do if m.kind == kind and (f1 == nil or m.f[1] == f1) then n = n + 1 end end return n end
local veh = { calls = {} }
package.loaded["sdc_vehicles"] = {
    force_out_host = function(why) veh.calls[#veh.calls + 1] = "host:" .. why; if veh.host_ok then host_pawn["InVehicle?"], host_pawn._parent = false, nil end return "ok" end,
    unseat_client = function(key, why) veh.calls[#veh.calls + 1] = key .. ":" .. why; if veh.client_ok then local p = key == "Ann_PC" and a_pawn or b_pawn; p["InVehicle?"], p._parent = false, nil end return "unseated" end,
}
package.loaded["sdc_widgets"] = {
    child = function(w, n) return w.kids and w.kids[n] end,
    visible = function(b) return b.vis ~= "hidden" end,
    hide = function(b) b.vis = "hidden" end,
}
local COVER = { visible = false }
package.loaded["sdc_ui"] = { join_cover_model = function() return { visible = COVER.visible } end }
local CHAT = { open = false }
package.loaded["sdc_chat"] = { is_open = function() return CHAT.open end }
package.loaded["sdc_throw"] = { blast_now = function() return nil end, fires_near = function() return {} end }
package.loaded["sdc_appearance"] = { player_id = function(p) return p.PlayerState and p.PlayerState.GetPlayerId() end }
package.loaded["sdc_players"] = {}
package.loaded["sdc_persist"] = { steam_of = function() return nil end }

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, kind, secs, ...)
    said[#said + 1] = { key = key, kind = kind, args = { ... } }
    return real_say(key, kind, secs, ...)
end
local function said_n(key) local n = 0 for _, s in ipairs(said) do if s.key == key then n = n + 1 end end return n end
local function said_last(key) for i = #said, 1, -1 do if said[i].key == key then return said[i] end end end
local lines = {}
local errs = {}
log.info = function(fmt, ...) local ok, s = pcall(string.format, fmt, ...) lines[#lines + 1] = ok and s or fmt end
log.warn = log.info
log.debug = function() end
log.err = function(fmt, ...) local ok, s = pcall(string.format, fmt, ...) errs[#errs + 1] = ok and s or fmt end
log.err_throttled = function(_, fmt, ...) local ok, s = pcall(string.format, fmt, ...) errs[#errs + 1] = ok and s or fmt end
local function logged(pat) for i = #lines, 1, -1 do if lines[i]:find(pat, 1, true) then return lines[i] end end return nil end
local cfg = require("sdc_config")
cfg.save = function() return true end
cfg.player_name = function() return "Host" end
local i18n = require("sdc_i18n")

local S = { role = "host", remote = {}, remote_pcs = {} }
local function rec_of(pc, opts)
    opts = opts or {}
    return { key = pc._name, pc = pc, name = pc._name:gsub("_PC$", ""), hello = true, access = opts.access or "ok",
             spawned_once = opts.spawned ~= false, downcap = opts.downcap ~= false, down_ready = true, dead = false }
end
local function connect(...)
    S.remote, S.remote_pcs = {}, {}
    for _, x in ipairs({ ... }) do
        local r = rec_of(x[1], x[2])
        S.remote[r.key] = r
        S.remote_pcs[#S.remote_pcs + 1] = x[1]
    end
end

local ff = require("sdc_ffire")
ff.install(S)
local D = require("sdc_down")
D.install(S)
local H = D._H
local POSE = package.loaded["sdc_down_pose"]

local function tick(n, dt)
    for _ = 1, (n or 1) do
        advance(dt or 0.25)
        D.tick()
    end
end
local function frame() if D.frame_wanted() then D.frame_tick() end end
local function reset_pawn(p, hp)
    p.MedicalComponent.Health = hp or 100
    p.MedicalComponent["CanTakeDamage?"] = true
    p["PlayerDead?"], p.div, p.db_unlocked, p["DeathbringerSkillUsed?"] = false, 1, false, false
    p.Tags = tags({ "ZombieCanAttack", "Player" })
    p._loc.Z = 100
    p.CharacterMovement.falling, p.CharacterMovement.swimming = false, false
    p["InVehicle?"], p._parent = false, nil
end
local function clear_all()
    D.reset("test")
    sent, to_host = {}, {}
    for _, p in ipairs({ host_pawn, a_pawn, b_pawn, o_pawn }) do reset_pawn(p) end
    host_pawn._loc = { X = 0, Y = 0, Z = 100 }
    a_pawn._loc = { X = 150, Y = 0, Z = 100 }
    b_pawn._loc = { X = 0, Y = 150, Z = 100 }
end

-- ================================================================ 1
say("== 1. settings and texts")
local row = i18n.schema_row("down_enabled")
check(row and row[2] == "bool" and row[3] == false and cfg.get("down_enabled") == false, "down_enabled: bool, default off")
local row2 = i18n.schema_row("down_bleedout_s")
check(row2 and row2[2] == "int" and row2[3] == 60, "down_bleedout_s: int, 60")
check(i18n.LABEL.down_enabled[1] == "Нокдаун и подъём напарником" and i18n.LABEL.down_enabled[2]:find("Knockdown", 1, true) ~= nil,
    "label RU / EN")
check(i18n.group_of("down_enabled") == "combat" and i18n.NUMS_OF.down_enabled[1] == "down_bleedout_s", "group combat, its number row")
check(type(i18n.DESC_EN.down_enabled) == "string" and type(i18n.DESC_EN.down_bleedout_s) == "string", "English descriptions")
local bad = {}
for k, t in pairs(D.TEXT) do
    if not (t[1] and t[2] and not t[1]:find("[\208\209]") and t[2]:find("[\208\209]") and i18n.SAY_CLASS[k]) then bad[#bad + 1] = k end
end
check(#bad == 0, "every notice: English log, Russian screen, a class " .. table.concat(bad, ","))
check(i18n.SAY_CLASS.down_you == "game" and i18n.SAY_CLASS.down_up_by == "game", "notices are the game's (class game)")
check(i18n.STR.ru.wa_down_cap and i18n.STR.en.wa_down_cap and i18n.STR.ru.pl_state_down == "ранен" and i18n.STR.en.pl_state_down == "down",
    "World tab caption, F7 state RU / EN")
check(i18n.STR.ru.down_bar_bleed and i18n.STR.en.down_bar_giveup, "bar captions RU / EN")
cfg.set("down_bleedout_s", 5)
check(D.bleed_s() == 15, "bleed-out clamped to 15..300")
cfg.set("down_bleedout_s", 60)

-- ================================================================ 2
say("== 2. hook entries, gates")
local by = {}
local order = {}
for i, e in ipairs(entries) do by[e.name] = e; order[e.name] = i end
check(by["down.damage"] and by["down.damage"].kind == "pre" and by["down.damage"].path == AD, "ApplyDamage pre entry")
check(order["ffire.damage"] < order["down.damage"], "after sdc_ffire's entry (its zero comes first)")
check(by["down.measure"] and by["down.measure"].kind == "post", "ApplyDamage post entry (the measure)")
check(by["down.radial"] and by["down.radial"].path == ARD, "ApplyRadialDamage pre entry")
check(by["down.pause"] and by["down.pause"].kind == "bp" and by["down.pause"].path:find("RemoveSaveAndSuicideButton", 1, true), "pause menu bp entry")
cfg.set("down_enabled", true)
tick(4)
check(by["down.damage"].gate() == false and by["down.radial"].gate() == false, "single player (rule on, nobody connected): gates closed")
-- single player: a deadly hit kills as usual
hit(host_pawn, 150, NONE, NONE)
check(host_pawn["PlayerDead?"] == true and next(H.downs) == nil, "single player: a deadly hit kills (vanilla)")
clear_all()
cfg.set("down_enabled", false)
connect({ a_pc }, { b_pc })
tick(4)
check(by["down.damage"].gate() == false, "rule off, players here: gate closed")
hit(a_pawn, 150, NONE, NONE)
check(a_pawn["PlayerDead?"] == true and next(H.downs) == nil, "rule off: a deadly hit kills (vanilla)")
clear_all()
cfg.set("down_enabled", true)
connect({ a_pc }, { b_pc })
installs = 0
tick(4)
check(by["down.damage"].gate() == true and installs > 0, "rule on, players here: gate open, the tick installs the hooks")
check(sent_of("RULES", "Ann_PC", "down", "1")[1] ~= nil and sent_of("RULES", "Ann_PC", "down", "1")[1].f[3] == "60",
    "RULES|down|1|60 to a client let in")

-- ================================================================ 3
say("== 3. candidates and rescuers")
local function cand_has(p) return H.cand[p._addr] ~= nil end
check(cand_has(host_pawn) and cand_has(a_pawn) and cand_has(b_pawn), "host + two new clients: all candidates")
check(D.rescuers("host") == 2 and D.rescuers("Ann_PC") == 2, "rescuers besides oneself")
clear_all()
connect({ o_pc, { downcap = false } })
tick(4)
check(not cand_has(host_pawn) and not cand_has(o_pawn), "host + an older client: nobody goes down")
hit(host_pawn, 150, NONE, NONE)
check(host_pawn["PlayerDead?"] == true, "... the host dies as usual")
clear_all()
connect({ a_pc }, { o_pc, { downcap = false } })
check(sent_of("DOWN", "Old_PC")[1] == nil, "an older client gets no DOWN")
a_pawn["PlayerDead?"] = true
S.remote["Ann_PC"].dead = true
tick(4)
check(cand_has(host_pawn), "a new client on its death screen, the host alive: the host can go down")
check(not cand_has(a_pawn), "a dead client is no candidate")
clear_all()
connect({ a_pc })
host_pawn["PlayerDead?"] = true
tick(4)
check(not cand_has(a_pawn), "the host dead: the client cannot go down (nobody to help)")
clear_all()
connect({ a_pc, { spawned = false } })
tick(4)
check(not cand_has(host_pawn), "a client still joining is no rescuer")
clear_all()
connect({ a_pc, { access = "wait" } })
tick(4)
check(not cand_has(host_pawn), "a client waiting for the host's yes is no rescuer")

-- ================================================================ 4
say("== 4. the hit: probe, measure, decision")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
-- armour: divisor 2, not deadly
a_pawn.MedicalComponent.Health, a_pawn.div = 50, 2
local zed = obj("BP_Zombie_C", "Z1")
local got = hit(a_pawn, 80, zed, BODY)
check(got == 25, "deadly-looking hit (80 >= 50): the probe is half its health (25)")
check(H.probe_open and D.frame_wanted(), "a probe waits for the frame")
check(a_pawn.MedicalComponent.Health == 37.5, "the probe took 12.5 (armour divides by 2)")
frame()
check(math.abs(a_pawn.MedicalComponent.Health - 10) < 1e-6 and next(H.downs) == nil, "h0 50, 80 / 2 = 40: stands with 10")
check(a_pawn.sent_hp[#a_pawn.sent_hp] == a_pawn.MedicalComponent.Health, "the health sent to the client")
check(D.stats.post >= 1 and logged("measured=post") ~= nil, "measured in the post hook")
-- the post entry: UE4SS passes (Context, ReturnValue, DamagedActor, BaseDamage, ...)
a_pawn.MedicalComponent.Health, a_pawn.div = 50, 1
by["down.damage"].fn(GPS, param(a_pawn), param(90), param(nil), param(zed), param(BODY))
local pr_m = H.pending[a_pawn._addr]
a_pawn.MedicalComponent.Health = 25
by["down.measure"].fn(GPS, param(a_pawn), param(25))
check(pr_m and pr_m.h1 == nil, "the post entry does not take the return value's slot for the victim")
by["down.measure"].fn(GPS, param(25.0), param(a_pawn), param(25))
check(pr_m and pr_m.h1 == 25, "the post entry reads the victim from the third argument: h1 measured")
frame()
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
-- not deadly at all: untouched
a_pawn.MedicalComponent.Health, a_pawn.div = 80, 1
check(hit(a_pawn, 30, zed, BODY) == 30 and not H.probe_open, "a hit below its health: untouched")
-- own state's damage (hunger: the victim as the causer, DamageType): dies as usual
a_pawn.MedicalComponent.Health = 3
hit(a_pawn, 5, a_pawn, DTYPE)
check(a_pawn["PlayerDead?"] == true and next(H.downs) == nil, "hunger / thirst / radiation / drowning: dies as usual")
reset_pawn(a_pawn)
tick(4)
a_pawn.MedicalComponent.Health = 3
hit(a_pawn, 5, a_pawn, nil)
check(a_pawn["PlayerDead?"] == true, "infection (own causer, no damage class): dies as usual")
reset_pawn(a_pawn)
tick(4)
-- own grenade: down
a_pawn.MedicalComponent.Health = 40
check(hit(a_pawn, 90, a_pawn, BODY) == 20, "own grenade (Damage_Body_C): a probe")
frame()
check(H.downs["Ann_PC"] ~= nil and a_pawn["PlayerDead?"] == false, "own grenade: down, not dead")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
-- shotgun: pellets in one frame add up
a_pawn.MedicalComponent.Health = 60
hit(a_pawn, 70, zed, BODY)
check(hit(a_pawn, 20, zed, BODY) == 0 and hit(a_pawn, 20, zed, BODY) == 0, "pellets after the probe: 0, added to it")
check(H.pending[a_pawn._addr].extra == 40, "... 40 added")
frame()
check(H.downs["Ann_PC"] ~= nil, "110 damage on 60 health: down")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
-- shotgun that armour saves: pellets add up and still stand
a_pawn.MedicalComponent.Health, a_pawn.div = 60, 4
hit(a_pawn, 70, zed, BODY)
hit(a_pawn, 30, zed, BODY)
frame()
check(H.downs["Ann_PC"] == nil and math.abs(a_pawn.MedicalComponent.Health - 35) < 1e-6, "100 / 4 = 25 on 60: stands with 35")
-- Deathbringer
reset_pawn(a_pawn)
a_pawn.MedicalComponent.Health, a_pawn.db_unlocked = 30, true
tick(4)
hit(a_pawn, 90, zed, BODY)
frame()
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 25 and a_pawn["DeathbringerSkillUsed?"] == true,
    "deadly and Deathbringer ready: the game's skill, stands with 25")
check(D.stats.saved >= 1, "counted")
-- in water
reset_pawn(a_pawn)
tick(4)
a_pawn.MedicalComponent.Health = 20
a_pawn.CharacterMovement.swimming = true
hit(a_pawn, 90, zed, BODY)
frame()
check(a_pawn["PlayerDead?"] == true and H.downs["Ann_PC"] == nil, "deadly in water: dies the game's way")
-- the post hook missed: the frame's health
reset_pawn(a_pawn)
tick(4)
a_pawn.MedicalComponent.Health = 40
by["down.damage"].fn(GPS, param(a_pawn), param(90), param(nil), param(zed), param(BODY))
a_pawn.MedicalComponent.Health = 20   -- the probe as the engine applies it, no post call
frame()
check(H.downs["Ann_PC"] ~= nil and D.stats.frame >= 1, "no post measure: measured in the frame, down")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
-- nothing taken: CanTakeDamage? off (debug god mode, another protection)
a_pawn.MedicalComponent.Health = 30
a_pawn.MedicalComponent["CanTakeDamage?"] = false
hit(a_pawn, 90, zed, BODY)
frame()
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 30 and D.stats.nothing >= 1,
    "the game took nothing (CanTakeDamage? off): nothing done, no division by zero")
a_pawn.MedicalComponent["CanTakeDamage?"] = true
-- tiny health: the relative threshold still sees the probe
a_pawn.MedicalComponent.Health = 0.0015
hit(a_pawn, 10, zed, BODY)
frame()
check(H.downs["Ann_PC"] ~= nil, "health 0.0015: the probe still measures, down (no endless invulnerability)")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health, a_pawn.div = 0.0015, 2
hit(a_pawn, 0.0016, zed, BODY)
frame()
check(H.downs["Ann_PC"] == nil and math.abs(a_pawn.MedicalComponent.Health - 0.0007) < 1e-7,
    "tiny health, armour saves it: measured relative to the probe, stands (0.0007)")
a_pawn.div = 1
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
-- nobody can help at the decision (the only other players dropped in the same frame)
connect({ a_pc })
tick(4)
a_pawn.MedicalComponent.Health = 20
hit(a_pawn, 90, zed, BODY)
host_pawn["PlayerDead?"] = true   -- the only rescuer died in the same frame
frame()
check(H.downs["Ann_PC"] == nil and a_pawn["PlayerDead?"] == true, "the only rescuer died before the decision: dies the game's way")
clear_all()
connect({ a_pc })
host_pawn["PlayerDead?"] = true
tick(4)
a_pawn.MedicalComponent.Health = 20
hit(a_pawn, 90, zed, BODY)
check(not H.probe_open, "the host dead: Ann is no candidate (no probe)")
check(a_pawn["PlayerDead?"] == true, "... dies as usual")

-- ================================================================ 5
say("== 5. friendly fire")
clear_all()
connect({ a_pc }, { b_pc })
cfg.set("friendly_fire", false)
ff.tick()
tick(4)
a_pawn.MedicalComponent.Health = 20
check(hit(a_pawn, 90, b_pawn, BODY) == 0 and not H.probe_open, "friendly fire off: Bob's shot dropped by sdc_ffire first (no probe)")
check(a_pawn.MedicalComponent.Health == 20, "... no damage")
cfg.set("friendly_fire", true)
ff.tick()
check(hit(a_pawn, 90, b_pawn, BODY) == 10, "friendly fire on: Bob's deadly shot is a probe")
frame()
check(H.downs["Ann_PC"] ~= nil, "... Ann is down")
tick(1)
check(hit(a_pawn, 500, b_pawn, BODY) == 0 and a_pawn["PlayerDead?"] == false, "a downed player cannot be finished off (BaseDamage 0)")
cfg.set("friendly_fire", false)
ff.tick()

-- ================================================================ 6
say("== 6. down")
clear_all()
connect({ a_pc }, { b_pc }, { o_pc, { downcap = false } })
tick(4)
local z1, bb1, zc1 = zombie(a_pawn)
local z2, bb2 = zombie(b_pawn)
-- one chasing it from 30 m (it sees 25 m, loses sight only at 50 m), one 60 m away
local z3, bb3 = zombie(a_pawn, { X = 3150, Y = 0, Z = 100 })
local z4, bb4 = zombie(a_pawn, { X = 6200, Y = 0, Z = 100 })
W.zombies = { z1, z2, z3, z4 }
a_pawn.MedicalComponent.Health = 40
a_pawn["Burning?"] = true
hit(a_pawn, 90, zed, BODY)
frame()
local rec = H.downs["Ann_PC"]
check(rec and rec.phase == "land", "decision: a record (landing first)")
check(a_pawn.MedicalComponent.Health == 1 and a_pawn.MedicalComponent["CanTakeDamage?"] == false, "health 1, CanTakeDamage? off")
check(not has_tag(a_pawn, "ZombieCanAttack") and has_tag(a_pawn, "SDCDown") and #a_pawn.Tags == 2, "ZombieCanAttack renamed in place")
check(a_pawn.stopped_burn == 1, "a burn put out")
check(D.is_down(a_pawn), "is_down already while landing (vehicles do not seat it again)")
sent = {}
tick(1)
check(rec.phase == "down" and rec.spot and rec.spot.X == 150, "on the ground: down at its spot")
check(bb1.vals.AttackTarget == nil and bb1.bools["IsAlert?"] == true and zc1.Combat == false, "a zombie attacking it drops it")
check(bb2.vals.AttackTarget == b_pawn, "a zombie on somebody else keeps its target")
check(bb3.vals.AttackTarget == nil and W.overlap_r == 5000, "a zombie chasing it from 30 m drops it too (the sphere is the 50 m lose-sight radius)")
check(bb4.vals.AttackTarget == a_pawn, "one 60 m away is not looked at (it lost sight of everybody there anyway)")
-- its attack task writes its old target back (BTTask_FindAttackTargetLocation @743),
-- another one walks into 50 m still after it: dropped again within a second
bb1.vals.AttackTarget, bb1.bools["IsAlert?"] = a_pawn, nil
z4._loc = { X = 4000, Y = 0, Z = 100 }
local zn0 = D.stats.zombies
tick(4)
check(bb1.vals.AttackTarget == nil and bb1.bools["IsAlert?"] == true and bb4.vals.AttackTarget == nil and D.stats.zombies >= zn0 + 2,
    "every second while down: a zombie after it again drops it again")
check(logged("more zombie(s) still after it") ~= nil, "... logged")
check(#sent_of("DOWN", "Bob_PC", "257", "1") == 1 and #sent_of("DOWN", "Old_PC") == 0, "DOWN to DOWNCAP clients only")
local m = sent_of("DOWN", "Bob_PC", "257", "1")[1]
check(m and m.f[3] == "60" and m.f[6] == "150", "DOWN: 60 s left, the spot")
W.zombies = {}
a_pawn.MedicalComponent.Health = 7
tick(4)
check(a_pawn.MedicalComponent.Health == 1, "health held at 1")
check(hit(a_pawn, 30, zed, BODY) == 0, "a zombie hit on it: 0")
sent = {}
tick(40)
check(#sent_of("DOWN", "Bob_PC", "257", "1") >= 1, "DOWN again every 10 s")
-- a client that says DOWNCAP late gets the state at once
S.remote["Old_PC"].downcap = nil
sent = {}
handlers.DOWNCAP({ "1" }, o_pc)
check(#sent_of("DOWN", "Old_PC", "257", "1") == 1 and S.remote["Old_PC"].downcap == true, "a late DOWNCAP: the state at once")
check(D.state_of("Ann_PC") == "down" and D.downcap("Old_PC"), "F7: state down, DOWNCAP known")

-- ================================================================ 7
say("== 7. revive")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 18
a_pawn.MedicalComponent["Bleed?"] = true
hit(a_pawn, 90, zed, BODY)
frame()
tick(1)
check(H.downs["Ann_PC"].phase == "down", "Ann down")
b_pawn._loc = { X = 150, Y = 400, Z = 100 }   -- 4 m away
handlers.REVIVE({ "257", "1" }, b_pc)
tick(4)
check(H.downs["Ann_PC"].prog == 0, "Bob holds the key 4 m away: nothing")
b_pawn._loc = { X = 150, Y = 200, Z = 100 }   -- 2 m
tick(4)
check(H.downs["Ann_PC"].prog > 0.9, "within 2.5 m: progress grows")
local rs = sent_of("DOWN", "Bob_PC", "257", "1")
check(rs[#rs].f[5] == "258", "DOWN names the rescuer")
b_pawn._loc = { X = 150, Y = 280, Z = 100 }   -- 2.8 m: keeps it
tick(2)
check(H.downs["Ann_PC"].prog > 1.4, "moving to 2.8 m: keeps reviving")
-- the host joins, Bob lets go: no reset
H.holding.host = { target = "Ann_PC", t = CLK }
handlers.REVIVE({ "257", "0" }, b_pc)
tick(2)
check(H.downs["Ann_PC"].prog > 1.9, "Bob lets go, the host holds: no reset")
H.holding.host = nil
tick(1)
check(H.downs["Ann_PC"].prog == 0, "nobody holds: back to 0")
handlers.REVIVE({ "257", "1" }, b_pc)
b_pawn._loc = { X = 150, Y = 400, Z = 100 }
tick(2)
check(H.downs["Ann_PC"].prog == 0, "beyond 3 m: out")
b_pawn._loc = { X = 150, Y = 200, Z = 100 }
sent = {}
tick(21)
check(H.downs["Ann_PC"] == nil, "5 s: up")
check(a_pawn.MedicalComponent.Health == 18, "health as before the hit (18)")
check(a_pawn.MedicalComponent["CanTakeDamage?"] == true and has_tag(a_pawn, "ZombieCanAttack"), "protection and tag back")
check(a_pawn.MedicalComponent["Bleed?"] == false and a_pawn.MedicalComponent.onrep == 1 and pushes >= 1, "the bleeding stopped (flag, mark, OnRep)")
check(a_pawn["IsPlayerRolling?"] == false and a_pawn["Attacking?"] == false, "the host's copy flags off")
check(#sent_of("DOWN", "Bob_PC", "257", "0") == 1 and sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "up"
    and sent_of("DOWN", "Bob_PC", "257", "0")[1].f[4] == "258", "DOWN|257|0|up|258")
for _, case in ipairs({ { 3, 10 }, { 50, 25 } }) do
    clear_all()
    connect({ a_pc }, { b_pc })
    tick(4)
    a_pawn.MedicalComponent.Health = case[1]
    hit(a_pawn, 200, zed, BODY)
    frame()
    tick(1)
    handlers.REVIVE({ "257", "1" }, b_pc)
    b_pawn._loc = { X = 150, Y = 100, Z = 100 }
    tick(22)
    check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == case[2],
        string.format("health before %d -> %d after the revive", case[1], case[2]))
end

-- ================================================================ 8
say("== 8. ends")
local function down_ann(hp)
    clear_all()
    connect({ a_pc }, { b_pc })
    tick(4)
    a_pawn.MedicalComponent.Health = hp or 20
    hit(a_pawn, 200, zed, BODY)
    frame()
    tick(1)
    sent = {}
    return H.downs["Ann_PC"]
end
down_ann()
tick(4 * 61)
check(H.downs["Ann_PC"] == nil and a_pawn["PlayerDead?"] == true, "60 s: bleeds out, the game's death")
check(sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "dead", "DOWN|..|0|dead")
check(H.bypass == false, "the bypass is off again")
down_ann()
handlers.GIVEUP({}, a_pc)
check(H.downs["Ann_PC"] == nil and a_pawn["PlayerDead?"] == true and D.stats.gaveup >= 1, "GIVEUP: dies")
down_ann()
handlers.GIVEUP({}, b_pc)
check(H.downs["Ann_PC"] ~= nil, "GIVEUP from someone else: nothing")
-- Deathbringer at the end counts as up
down_ann()
a_pawn.db_unlocked = true
handlers.GIVEUP({}, a_pc)
check(a_pawn["PlayerDead?"] == false and a_pawn.MedicalComponent.Health == 25, "dying with Deathbringer ready: stands")
check(sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "up", "... DOWN|..|0|up")
-- nobody left
down_ann()
S.remote["Bob_PC"] = nil
S.remote_pcs = { a_pc }
host_pawn["PlayerDead?"] = true
tick(1)
check(H.downs["Ann_PC"] == nil and a_pawn["PlayerDead?"] == true, "the last rescuer gone: dies")
-- moved: three times in 10 s
down_ann()
for i = 1, 3 do
    a_pawn._loc = { X = 150 + 400, Y = 0, Z = 100 }
    tick(4)
end
check(H.downs["Ann_PC"] == nil and a_pawn["PlayerDead?"] == true, "its copy away from the spot 3 times in 10 s: dies")
down_ann()
a_pawn._loc = { X = 550, Y = 0, Z = 100 }
tick(4)
check(#sent_of("DOWN", "Ann_PC", "257", "1") >= 1, "away once: DOWN with the spot again (it moves back)")
a_pawn._loc = { X = 150, Y = 0, Z = 100 }
tick(48)
check(H.downs["Ann_PC"] ~= nil, "back: still down")
-- binding: another character
down_ann()
local old = a_pawn
local a2 = player("Ann", 257, 150, 0, true)
a_pc.Pawn = a2
tick(1)
check(H.downs["Ann_PC"] == nil and old["PlayerDead?"] == false and sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "gone",
    "another character: closed without damage (gone)")
a_pc.Pawn = old
a2._gone = true
-- dead some other way (suicide)
down_ann()
a_pawn["PlayerDead?"] = true
tick(1)
check(H.downs["Ann_PC"] == nil and sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "dead", "died some other way: closed (dead)")
-- left
down_ann()
S.remote["Ann_PC"] = nil
S.remote_pcs = { b_pc }
tick(1)
check(H.downs["Ann_PC"] == nil and sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "left", "left: closed (left)")
-- the rule off
down_ann(16)
cfg.set("down_enabled", false)
tick(1)
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 16 and a_pawn.MedicalComponent["CanTakeDamage?"] == true,
    "the rule off: up (health 10..25), unprotected")
check(sent_of("DOWN", "Bob_PC", "257", "0")[1].f[3] == "off", "DOWN|..|0|off")
check(by["down.damage"].gate() == false, "and the hook is quiet again")
cfg.set("down_enabled", true)
-- world change: everything dropped without touching
down_ann()
D.reset("loadmap")
check(next(H.downs) == nil and next(H.cand) == nil, "world change: records dropped")

-- ================================================================ 9
say("== 9. the host down")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
host_pawn.MedicalComponent.Health = 30
hit(host_pawn, 99, zed, BODY)
frame()
tick(1)
check(H.downs.host and H.downs.host.phase == "down", "the host is down")
check(D.any_down() == true, "any_down (saves wait, save now refused)")
local pause = obj("PauseScreen_C", "Pause", { kids = { Save = { vis = "v" }, QuickSave = { vis = "v" }, Suicide = { vis = "v" },
                                                      Resume = { vis = "v" } } })
pause.IsInViewport = function() return true end
pause.RemoveSaveAndSuicideButton = function(self) for _, n in ipairs({ "Save", "QuickSave", "Suicide" }) do self.kids[n].vis = "v" end end
run_entries(by["down.pause"].path, "bp", param(pause))
check(pause.kids.Save.vis == "hidden" and pause.kids.QuickSave.vis == "hidden" and pause.kids.Suicide.vis == "hidden"
    and pause.kids.Resume.vis == "v", "the game's pause menu: Save / QuickSave / Suicide hidden")
pause.kids.Save.vis = "v"
W.find["PauseScreen_C"] = { pause }
HUD.PauseMenu = nil
FINDS["PauseScreen_C"] = 0
host_pc.bShowMouseCursor = false
tick(8)
check(FINDS["PauseScreen_C"] == 0 and pause.kids.Save.vis == "v",
    "the fallback: no mouse cursor (no menu open) - no search over every object at all")
host_pc.bShowMouseCursor = true
tick(1)
check(pause.kids.Save.vis == "hidden", "the 250 ms fallback hides them too (the cursor on, the menu open)")
pause.kids.Save.vis = "v"
FINDS["PauseScreen_C"] = 0
tick(8)
check(FINDS["PauseScreen_C"] >= 1 and FINDS["PauseScreen_C"] <= 2 and pause.kids.Save.vis == "hidden",
    "no HUD PauseMenu: the full search at most once a second (" .. tostring(FINDS["PauseScreen_C"]) .. " in 2 s, not 8)")
W.find["PauseScreen_C"] = nil
HUD.PauseMenu = pause
pause.kids.Save.vis = "v"
FINDS["PauseScreen_C"] = 0
tick(1)
check(FINDS["PauseScreen_C"] == 0 and pause.kids.Save.vis == "hidden", "the HUD's own PauseMenu: found without a search")
-- a client revives the host
handlers.REVIVE({ "256", "1" }, a_pc)
tick(21)
check(H.downs.host == nil and host_pawn.MedicalComponent.Health == 25, "Ann revives the host (health 30 -> 25)")
tick(1)
check(pause.kids.Save.vis == "v", "nobody down: the game shows its buttons again")
HUD.PauseMenu = nil
host_pc.bShowMouseCursor = false
-- the host gives up
clear_all()
connect({ a_pc })
tick(4)
host_pawn.MedicalComponent.Health = 30
hit(host_pawn, 99, zed, BODY)
frame()
tick(1)
D.give_up()
check(H.downs.host == nil and host_pawn["PlayerDead?"] == true, "the host gives up: dies")

-- ================================================================ 10
say("== 10. vehicles, landing")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
veh.calls, veh.client_ok = {}, false
a_pawn["InVehicle?"], a_pawn._parent = true, obj("BP_Car_C", "Car")
a_pawn.MedicalComponent.Health = 20
hit(a_pawn, 90, zed, BODY)
frame()
check(veh.calls[1] == "Ann_PC:downed" and H.downs["Ann_PC"].phase == "exit", "a client down in a car: unseated at once (exit phase)")
check(D.is_down(a_pawn), "is_down in the exit phase (no seat heal)")
tick(9)
check(H.downs["Ann_PC"] == nil and a_pawn["PlayerDead?"] == true, "not out within 2 s: dies")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
veh.calls, veh.client_ok = {}, true
a_pawn["InVehicle?"], a_pawn._parent = true, obj("BP_Car_C", "Car")
a_pawn.MedicalComponent.Health = 20
hit(a_pawn, 90, zed, BODY)
frame()
tick(2)
check(H.downs["Ann_PC"] and H.downs["Ann_PC"].phase == "down", "out of the car: down beside it")
-- the host in a car
clear_all()
connect({ a_pc })
tick(4)
veh.calls, veh.host_ok = {}, true
host_pawn["InVehicle?"], host_pawn._parent = true, obj("BP_Car_C", "Car")
host_pawn.MedicalComponent.Health = 20
hit(host_pawn, 90, zed, BODY)
frame()
check(veh.calls[1] == "host:downed", "the host down in a car: its own exit (force_out_host)")
tick(2)
check(H.downs.host and H.downs.host.phase == "down", "... then down")
-- landing: in the air, then the floor below
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.CharacterMovement.falling = true
a_pawn._loc = { X = 150, Y = 0, Z = 900 }
a_pawn.MedicalComponent.Health = 20
hit(a_pawn, 90, zed, BODY)
frame()
tick(4)
check(H.downs["Ann_PC"].phase == "land", "falling: waits to land (no spot in the air)")
W.trace.hit, W.trace.at = true, { X = 150, Y = 0, Z = 0 }
tick(10)
check(H.downs["Ann_PC"].phase == "down" and H.downs["Ann_PC"].spot.Z == 95, "not on the ground after 3 s: the floor below")
W.trace.hit, W.trace.at = false, nil
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.CharacterMovement.falling = true
a_pawn.MedicalComponent.Health = 20
hit(a_pawn, 90, zed, BODY)
frame()
tick(2)
a_pawn.CharacterMovement.falling = false
tick(1)
check(H.downs["Ann_PC"].phase == "down", "landed: down")

-- ================================================================ 11
say("== 11. the grenadier")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 50
b_pawn.MedicalComponent.Health = 100
W.trace.ok, W.trace.hit = true, false
radial(80, { X = 150, Y = 50, Z = 100 }, 600)
check(a_pawn.MedicalComponent.Health == 50 and b_pawn.MedicalComponent.Health == 20, "the blast: Ann (50 <= 80) protected, Bob (100) hurt as usual")
check(#H.blasts == 1 and D.frame_wanted(), "the blast remembered for the frame")
frame()
check(W.trace.channel == 1, "line of sight on the Camera trace type (TraceTypeQuery2)")
check(a_pawn.MedicalComponent["CanTakeDamage?"] == true or H.downs["Ann_PC"], "the flag back")
frame()
check(H.downs["Ann_PC"] ~= nil, "in sight: the same damage through ApplyDamage, down")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 50
W.trace.hit, W.trace.at = true, { X = 150, Y = 150, Z = 100 }   -- a wall between
radial(80, { X = 150, Y = 200, Z = 100 }, 600)
frame()
frame()
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 50 and a_pawn.MedicalComponent["CanTakeDamage?"] == true,
    "behind cover: no damage, the flag back")
W.trace.ok = false
radial(80, { X = 150, Y = 200, Z = 100 }, 600)
frame()
frame()
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 50, "the trace fails: no damage (not \"everybody hit\")")
W.trace.ok, W.trace.hit, W.trace.at = true, false, nil
-- the grenadier's own body at the blast's centre: the game's check ignores the
-- causer (ComponentIsDamageableFrom), so does ours
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 50
local gren = obj("BP_Zombie_Grenadier_C", "Grenadier")
W.trace.body = gren
W.trace.calls = 0
radial(80, { X = 150, Y = 200, Z = 100 }, 600, gren)
check(W.trace.calls == 1 and W.trace.ignore and W.trace.ignore[1] == gren, "the line of sight traced at the blast (its pre-hook), the grenadier ignored")
frame()
frame()
check(H.downs["Ann_PC"] ~= nil, "the grenadier's body on the line: not \"behind cover\", Ann down")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 50
radial(80, { X = 150, Y = 200, Z = 100 }, 600, NONE)
frame()
frame()
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent["CanTakeDamage?"] == true and CRASHES == 0,
    "(the mock's body blocks when the causer is not passed: a None causer is never put in the list)")
W.trace.body = nil
-- an error in the frame after the blast: nobody keeps CanTakeDamage? off
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health, b_pawn.MedicalComponent.Health = 50, 60
radial(80, { X = 150, Y = 100, Z = 100 }, 600)
check(#H.blasts == 1 and #H.blasts[1].hits == 2 and a_pawn.MedicalComponent["CanTakeDamage?"] == false
    and b_pawn.MedicalComponent["CanTakeDamage?"] == false, "both could die of it: both protected for that call")
local real_info = log.info
log.info = function() error("boom in the frame after the blast") end
local ok_bs = pcall(D._t.blasts_step)
log.info = real_info
check(not ok_bs and a_pawn.MedicalComponent["CanTakeDamage?"] == true and b_pawn.MedicalComponent["CanTakeDamage?"] == true,
    "an error in the frame after the blast: the flags came back first, nobody stays unable to take damage")
H.blasts = {}

-- ================================================================ 12
say("== 12. saved / left while down, F7")
local rec2 = down_ann(14)
advance(10)
local left, h0 = D.down_left(a_pawn)
check(left and left >= 48 and left <= 50 and h0 == 14, "persist: down_left / down_h0 of a downed character")
check(D.down_left(b_pawn) == nil, "nothing for a standing one")
-- back with 30 s left, after its inventory: ready -> down again
clear_all()
connect({ a_pc }, { b_pc })
S.remote["Ann_PC"].down_ready = false
tick(4)
check(D.restore_later("Ann_PC", a_pawn, 5, 14, "Ann"), "restore_later registered")
check(select(1, D.down_left(a_pawn)) == 20, "waiting: its snapshot keeps max(left, 20)")
tick(20)
check(H.downs["Ann_PC"] == nil, "not ready yet: waits")
S.remote["Ann_PC"].down_ready = true
tick(4)
check(H.downs["Ann_PC"] ~= nil and math.floor(D.rec_left(H.downs["Ann_PC"])) >= 18, "ready: down again with at least 20 s")
-- the rule off at its return: stands with 10..25
clear_all()
connect({ a_pc }, { b_pc })
cfg.set("down_enabled", false)
a_pawn.MedicalComponent.Health = 1
D.restore_later("Ann_PC", a_pawn, 40, 3, "Ann")
tick(16)
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 10, "rule off at its return: stands with 10")
cfg.set("down_enabled", true)
-- an older mod at its return
clear_all()
connect({ a_pc, { downcap = false } }, { b_pc })
a_pawn.MedicalComponent.Health = 1
D.restore_later("Ann_PC", a_pawn, 40, 30, "Ann")
tick(4 * 22)
check(H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 25, "an older mod at its return: stands (25)")
-- nobody can help at its return: dies the game's way, after its inventory
clear_all()
connect({ a_pc })
host_pawn["PlayerDead?"] = true
a_pawn.MedicalComponent.Health = 1
local downs0 = D.stats.downs
D.restore_later("Ann_PC", a_pawn, 40, 30, "Ann")
tick(16)
check(a_pawn["PlayerDead?"] == true and D.stats.downs == downs0, "nobody can help at its return: dies at once (not down first)")
-- F7
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
check(D.state_of("Ann_PC") == nil, "F7: standing = no state of ours")

-- ================================================================ 13
say("== 13. null objects, the fuse")
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
local dmg = by["down.damage"]
local errs0 = #errs
CRASHES = 0
dmg.fn(GPS, param(NONE), param(50), param(NONE), param(NONE), param(NONE))
dmg.fn(GPS, param(nil), param(50), param(nil), param(nil), param(nil))
dmg.fn(GPS, nil, nil, nil, nil, nil)
a_pawn.MedicalComponent.Health = 20
dmg.fn(GPS, param(a_pawn), param(90), param(NONE), param(NONE), param(NONE))
check(H.probe_open, "a deadly hit with no causer / damage class (a fall, bleeding): a probe")
by["down.measure"].fn(GPS, param(0.0), param(NONE))
by["down.measure"].fn(GPS, param(0.0), param(nil))
by["down.measure"].fn(GPS, param(nil), param(nil))
by["down.measure"].fn(GPS, nil, nil)
frame()
by["down.radial"].fn(GPS, param(NONE), param(NONE), param(nil), param(NONE))   -- (Origin is a struct: never a null object)
by["down.radial"].fn(GPS, param(nil), param(nil), param(nil), param(nil))
by["down.pause"].fn(param(NONE))
by["down.pause"].fn(nil)
dmg.fn(GPS, param(a_pawn), param(90), param(NONE), param(a_pawn), param(NONE))   -- own, None class
check(CRASHES == 0, "no method call on a null object in any hook")
check(D.stats.hook_errors == 0, "no hook error " .. table.concat(errs, " | ", errs0 + 1))
-- the fuse: a BaseDamage that cannot be written
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 20
local ro = { get = function() return 90 end, set = function() error("read only") end }
dmg.fn(GPS, param(a_pawn), ro, param(nil), param(zed), param(BODY))
check(D.fused() and by["down.damage"].gate() == false, "BaseDamage not writable: the fuse, the hook quiet")
check(said_n("down_fuse") >= 1, "the host gets a notice")
hit(a_pawn, 90, zed, BODY)
check(a_pawn["PlayerDead?"] == true, "fused: a deadly hit kills as usual")
H.fuse.off, H.fuse.why, H.fuse.errs = false, nil, {}
-- the fuse: a write that "works" but never reaches the game (the full hit lands)
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 20
local deaf = { get = function() return 90 end, set = function() end }
run_entries(AD, "pre", GPS, param(a_pawn), deaf, param(nil), param(zed), param(BODY))
engine_damage(a_pawn, 90)
run_entries(AD, "post", GPS, param(90), param(a_pawn), deaf, param(nil), param(zed), param(BODY))
frame()
check(D.fused() and H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 0,
    "the probe was not lessened (the player died of the real hit): the fuse, nothing laid on a dead body")
H.fuse.off, H.fuse.why, H.fuse.errs = false, nil, {}
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health, a_pawn.div = 60, 1
local deaf2 = { get = function() return 70 end, set = function() end }
a_pawn.div = 2
run_entries(AD, "pre", GPS, param(a_pawn), deaf2, param(nil), param(zed), param(BODY))
engine_damage(a_pawn, 70)   -- 35 taken, more than the probe (30)
run_entries(AD, "post", GPS, param(70), param(a_pawn), deaf2, param(nil), param(zed), param(BODY))
frame()
check(D.fused() and math.abs(a_pawn.MedicalComponent.Health - 25) < 1e-6, "took more than the probe: the fuse, the game's own result kept")
H.fuse.off, H.fuse.why, H.fuse.errs = false, nil, {}
a_pawn.div = 1
-- measured lessened right after the probe, then dead by the frame of something
-- else (the host's Suicide, a trap, a blast's edge): no fuse
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 40
hit(a_pawn, 90, zed, BODY)
check(H.pending[a_pawn._addr] and H.pending[a_pawn._addr].h1 == 20, "the probe measured right after it: 40 -> 20")
a_pawn.MedicalComponent.Health, a_pawn["PlayerDead?"] = 0, true
local od0 = D.stats.other_death
frame()
check(not D.fused() and H.downs["Ann_PC"] == nil and D.stats.other_death == od0 + 1,
    "measured lessened, then dead of something else in the same frame: no fuse, nothing laid on the body")
-- no measure right after it and dead by the frame: still the fuse (it cannot be told apart)
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health = 40
by["down.damage"].fn(GPS, param(a_pawn), param(90), param(nil), param(zed), param(BODY))
a_pawn.MedicalComponent.Health, a_pawn["PlayerDead?"] = 0, true
frame()
check(D.fused(), "no post measure and dead by the frame: the fuse (as before)")
H.fuse.off, H.fuse.why, H.fuse.errs = false, nil, {}
-- the write ignored and the game's Deathbringer saved it during the probe hit
-- (h0 50: it took exactly the probe's 25): the game's result kept, no knockdown,
-- no second Deathbringer call
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
a_pawn.MedicalComponent.Health, a_pawn.db_unlocked = 50, true
local db_calls, real_db = 0, a_pawn.Deathbringer
a_pawn.Deathbringer = function(...) db_calls = db_calls + 1 return real_db(...) end
local deaf3 = { get = function() return 90 end, set = function() end }
run_entries(AD, "pre", GPS, param(a_pawn), deaf3, param(nil), param(zed), param(BODY))
engine_damage(a_pawn, 90)
run_entries(AD, "post", GPS, param(90), param(a_pawn), deaf3, param(nil), param(zed), param(BODY))
local dbp0 = D.stats.db_probe
frame()
check(db_calls == 1 and H.downs["Ann_PC"] == nil and a_pawn.MedicalComponent.Health == 25 and a_pawn["PlayerDead?"] == false
    and D.stats.db_probe == dbp0 + 1 and not D.fused(),
    "the game's Deathbringer fired during the probe: its result kept (25), not put down, not called again")
a_pawn.Deathbringer = real_db
a_pawn.db_unlocked = false
-- the fuse: hook errors
clear_all()
connect({ a_pc }, { b_pc })
tick(4)
local bad_pawn = player("Bad", 300, 0, 0, true)
H.watch[bad_pawn._addr] = true
H.cand[bad_pawn._addr] = "Bad_PC"
bad_pawn.MedicalComponent = setmetatable({}, { __index = function() error("boom") end })
D._t.count_error("test", "x")
D._t.count_error("test", "x")
D._t.count_error("test", "x")
D._t.count_error("test", "x")
check(not D.fused(), "4 errors: still on")
D._t.count_error("test", "x")
check(D.fused(), "5 errors within 60 s: the fuse")
H.fuse.off, H.fuse.why, H.fuse.errs = false, nil, {}
bad_pawn._gone = true

-- ================================================================ 14
say("== 14. client")
clear_all()
S.role = "client"
S.remote, S.remote_pcs = {}, {}
W.me_pc = a_pc
S.client = { acked = false }
tick(2)
check(host_got("DOWNCAP") == 0, "no DOWNCAP before the host's hello ack")
S.client.acked = true
COVER.visible = true
tick(1)
check(host_got("DOWNCAP") == 1, "DOWNCAP once after the ack")
tick(8)
check(host_got("DOWNCAP") == 1, "... and not again (cover still up: not ready)")
COVER.visible = false
tick(4)
check(host_got("DOWNCAP") == 2 and to_host[#to_host].f[2] == "ready", "ready once the cover is gone")
-- rule notices
D.on_rule(true, 45)
tick(4)
check(said_n("down_join_on") == 1, "joining a world with knockdown on: one notice")
D.on_rule(false, 45)
tick(4)
check(said_n("down_turned_off") == 1, "the host turns it off: a notice")
D.on_rule(true, 45)
tick(4)
check(said_n("down_turned_on") == 1, "... and on again")
-- another player's copy down here: the pose
handlers.DOWN({ "258", "1", "50", "0", "", "0", "150", "100", "0" })
tick(1)
check(b_pawn._montage == FLOOR, "Bob's copy shows the sitting pose here")
b_pawn._montage = obj("AnimMontage", "Chr_Reload")
tick(1)
check(b_pawn._montage == FLOOR, "another montage took it: the pose again")
tick(4 * 31)
check(D.views()[258] == nil and b_pawn._montage ~= FLOOR, "no DOWN for 30 s: another player's copy freed here")
-- own state
a_pawn.BP_JigHelperComp.ActiveWeapon = { TagName = "Weapon.Rifle" }
a_pawn.BP_JigMultiplayer.InventoryWidgetRef = obj("Inv", "Inv", { IsInViewport = function() return true end })
a_pc.keys.F = true   -- F held from before (it was reviving somebody)
said = {}
handlers.DOWN({ "257", "1", "45", "0", "", "150", "0", "100", "0" })
tick(1)
for _ = 1, 300 do frame() end
check(a_pawn._montage == FLOOR, "own: the pose")
check(a_pawn["IsPlayerRolling?"] == true and a_pawn["CurrentlyChangingWeapon?"] == true, "own: the action flags")
check(a_pawn.BP_JigHelperComp.ActiveWeapon.TagName == "None" and a_pawn["Attacking?"] == true, "own: weapon put away, then Attacking?")
check(a_pawn.BP_JigMultiplayer.toggles == 1, "own: the inventory closed")
check(a_pc.sets == 1 and a_pc.ignore == 1, "own: SetIgnoreMoveInput once in 300 frames (no stacking)")
check(a_pawn.CharacterMovement.MovementMode == 0 and a_pawn.CharacterMovement.disabled == 1, "own: DisableMovement once")
check(said_n("down_you") == 1, "own: one notice on going down")
check(host_got("GIVEUP") == 0, "F held from before the knockdown: no give up")
for _ = 1, 20 do advance(0.25) frame() end
check(host_got("GIVEUP") == 0, "... still held 5 s later: no give up (a fresh press is needed)")
check(HUD.InteractTimerWidget and HUD.InteractTimerWidget.text == i18n.T("down_bar_bleed")
    and HUD.InteractTimerWidget.MaxTime == 45, "own: the bleeding-out bar")
local opened = HUD.opened
for _ = 1, 30 do frame() end
check(HUD.opened == opened, "the bar is not created again every frame")
-- the frame's cost while down: the bar, the pose, the movement check are
-- not every frame (30 frames within 1/60 s each: at most one of each)
do
    local gh, gm, mi = 0, 0, 0
    local real_gh, real_gm, real_mi = a_pc.GetHUD, a_pawn.GetCurrentMontage, a_pc.IsMoveInputIgnored
    a_pc.GetHUD = function(...) gh = gh + 1 return real_gh(...) end
    a_pawn.GetCurrentMontage = function(...) gm = gm + 1 return real_gm(...) end
    a_pc.IsMoveInputIgnored = function(...) mi = mi + 1 return real_mi(...) end
    advance(0.2)
    for _ = 1, 30 do advance(1 / 600) frame() end
    check(gh <= 1 and gm <= 1 and mi <= 1, string.format(
        "own, 30 frames in 0.05 s: GetHUD %d, GetCurrentMontage %d, IsMoveInputIgnored %d (not 30 each)", gh, gm, mi))
    check(a_pawn["IsPlayerRolling?"] == true and a_pc.ignore == 1, "... the action flags still every frame, still frozen once")
    local w = HUD.InteractTimerWidget
    w.MaxTime = 999
    local t0 = w.CurrentTime
    advance(0.5)
    frame()
    check(w.MaxTime == 999 and w.CurrentTime ~= t0, "the bar's time written, MaxTime only when the bar is new")
    w.MaxTime = 45
    a_pc.GetHUD, a_pawn.GetCurrentMontage, a_pc.IsMoveInputIgnored = real_gh, real_gm, real_mi
end
-- someone moves it: back to the spot
a_pawn._loc = { X = 400, Y = 0, Z = 100 }
advance(1)
frame()
check(a_pawn._loc.X == 150, "own: pushed away -> back to the spot")
-- give up: a fresh press, 3 s
a_pc.keys.F = false
frame()
a_pc.keys.F = true
for _ = 1, 10 do advance(0.25) frame() end
check(host_got("GIVEUP") == 0, "2.5 s: not yet")
check(HUD.InteractTimerWidget.text == i18n.T("down_bar_giveup"), "the give-up bar")
for _ = 1, 4 do advance(0.25) frame() end
check(host_got("GIVEUP") == 1, "a fresh press held 3 s: one GIVEUP")
for _ = 1, 20 do advance(0.25) frame() end
check(host_got("GIVEUP") == 1, "only once")
a_pc.keys.F = false
-- revived by Bob
said = {}
handlers.DOWN({ "257", "0", "up", "258" })
frame()
tick(1)
frame()
check(a_pawn["IsPlayerRolling?"] == false and a_pawn["Attacking?"] == false, "up: flags off")
check(a_pc.ignore == 0 and a_pawn.CharacterMovement.MovementMode == 1, "up: movement back")
check(said_last("down_up_by") and said_last("down_up_by").args[1] == "Bob", "«Вас поднял Bob»")
check(HUD.InteractTimerWidget == nil, "the bar closed")
check(a_pawn.stops[#a_pawn.stops] == "Chr_SittingFloor_Montage", "the pose stopped everywhere (the game's StopMontage)")
-- own death while down: freed at once
handlers.DOWN({ "257", "1", "45", "0", "", "150", "0", "100", "0" })
tick(1)
frame()
a_pawn["PlayerDead?"] = true
frame()
tick(1)
check(a_pc.ignore == 0 and D.views()[257] == nil, "own death while down: freed here without the host")
a_pawn["PlayerDead?"] = false
-- own state without DOWN for 30 s: asks (never frees itself)
handlers.DOWN({ "257", "1", "45", "0", "", "150", "0", "100", "0" })
tick(4 * 31)
check(D.views()[257] ~= nil and host_got("DOWNQ", "257") == 1, "own: 30 s without DOWN -> DOWNQ, still down")
handlers.DOWN({ "257", "0", "gone", "" })
frame()
tick(1)
frame()
check(a_pc.ignore == 0, "the host says gone: freed")
-- rescuer: looking at Bob down, holding F
handlers.DOWN({ "258", "1", "40", "0", "", "0", "150", "100", "0" })
a_pawn._loc = { X = 0, Y = 0, Z = 100 }
b_pawn._loc = { X = 0, Y = 150, Z = 100 }
CAM.loc, CAM.yaw, CAM.pitch = { X = 0, Y = 0, Z = 160 }, 90, -30
tick(1)
said = {}
frame()
check(said_n("down_hint") == 1, "looking at him without the key: one hint")
frame()
check(said_n("down_hint") == 1, "... not every frame")
a_pc.keys.F = true
to_host = {}
for _ = 1, 8 do advance(0.25) frame() end
check(host_got("REVIVE", "258") == 1 and to_host[1].f[2] == "1", "holding F on him: REVIVE|258|1 once")
check(a_pawn.played and a_pawn.played >= 1, "the game's looting montage (everyone sees it)")
check(HUD.InteractTimerWidget and HUD.InteractTimerWidget.text:find("Bob", 1, true), "the bar «Поднимаю: Bob»")
check(a_pc.ignore == 1, "the rescuer stands still")
-- the aim (camera, distance, line of sight) 10 times a second, the key every frame
do
    local los, real_los = 0, a_pc.LineOfSightTo
    a_pc.LineOfSightTo = function(...) los = los + 1 return real_los(...) end
    advance(0.2)
    for _ = 1, 30 do advance(1 / 600) frame() end
    check(los <= 1 and host_got("REVIVE", "258") == 1, "rescuer, 30 frames in 0.05 s: LineOfSightTo " .. los .. " (not 30), still reviving")
    a_pc.LineOfSightTo = real_los
end
CAM.yaw = -90
advance(0.1)
frame()
check(host_got("REVIVE", "258") == 2 and to_host[#to_host].f[2] == "0", "looking away: REVIVE|258|0 (within 0.1 s)")
check(a_pc.ignore == 0, "moves again")
a_pc.keys.F = false
CHAT.open = true
CAM.yaw = 90
a_pc.keys.F = true
advance(0.1)
frame()
check(host_got("REVIVE", "258") == 2, "the chat line open: the key does nothing")
-- the one looked at gets up between two aims: dropped at once
CHAT.open = false
advance(0.1)
frame()
check(host_got("REVIVE", "258") == 3 and to_host[#to_host].f[2] == "1", "looking at him again with the key: REVIVE|258|1")
handlers.DOWN({ "258", "0", "up", "257" })
frame()
check(host_got("REVIVE", "258") == 4 and to_host[#to_host].f[2] == "0" and POSE._t.R() == nil,
    "he is up (DOWN|..|0) in the same 0.1 s: let go at once, no stale target")
CHAT.open, a_pc.keys.F = false, false
handlers.DOWN({ "258", "0", "dead", "" })
tick(1)
frame()
-- No DOWNCAP now and then: the host's ROSTER says what it knows of this client
-- (S.client.roster_cap: 0 nothing, 1 DOWNCAP, 2 DOWNCAP + ready)
local caps = host_got("DOWNCAP")
S.client.roster_cap = 2   -- the host's list says it knows everything: an idle client
tick(4 * 300)
io.write(string.format("NETQ DOWNCAP idle msgs/min=%.1f", (host_got("DOWNCAP") - caps) / 5), string.char(10))
caps = host_got("DOWNCAP")
tick(4 * 120)
check(host_got("DOWNCAP") == caps, "no DOWNCAP again while the host's list says it knows everything")
tick(4 * 31)
check(host_got("DOWNCAP") == caps, "the host's list: it knows DOWNCAP + ready: nothing sent")
S.client.roster_cap = 0
tick(4 * 5)
check(host_got("DOWNCAP") == caps + 1, "the host's list: it knows nothing of this client: DOWNCAP|1|ready again")
S.client.roster_cap = 1
tick(4 * 11)
check(host_got("DOWNCAP") == caps + 2, "the host's list: it has DOWNCAP but not ready: sent again")
S.client.roster_cap = 2
-- the interact key remapped (E): UE4SS returns QueryKeysMappedToAction's
-- array as a plain Lua table of element params (no ForEach on it)
do
    local IA = "/Game/Input/InventoryPlayerActions/IA_Interact.IA_Interact"
    W.objects[IA] = obj("InputAction", "IA_Interact")
    local function elem(name) return { get = function() return { KeyName = name } end } end
    local ss = obj("EnhancedInputLocalPlayerSubsystem", "EILPS")
    ss.QueryKeysMappedToAction = function() return { elem("E"), elem("Gamepad_FaceButton_Left") } end
    W.find["EnhancedInputLocalPlayerSubsystem"] = { ss }
    POSE._t.K().at = -100
    local _, kname = POSE.interact_key()
    check(kname == "E", "the interact key remapped to E: read from the plain table (" .. tostring(kname) .. ")")
    check(POSE.first_key_name({}) == nil and POSE.first_key_name({ elem("None"), elem("Q") }) == "Q",
        "an empty mapping: none; None skipped")
    -- a downed Bob, looked at: the hint names E, holding E revives, F does nothing
    handlers.DOWN({ "258", "1", "40", "0", "", "0", "150", "100", "0" })
    a_pawn._loc = { X = 0, Y = 0, Z = 100 }
    b_pawn._loc = { X = 0, Y = 150, Z = 100 }
    CAM.loc, CAM.yaw, CAM.pitch = { X = 0, Y = 0, Z = 160 }, 90, -30
    tick(1)
    said, to_host = {}, {}
    advance(0.2)
    frame()
    local h = said_last("down_hint")
    check(h and h.args[1] == "E", "the hint: «Держите [E], чтобы поднять игрока Bob»")
    a_pc.keys.F = true
    for _ = 1, 4 do advance(0.25) frame() end
    check(host_got("REVIVE", "258") == 0, "F held while the key is E: nothing")
    a_pc.keys.F, a_pc.keys.E = false, true
    for _ = 1, 4 do advance(0.25) frame() end
    check(host_got("REVIVE", "258") == 1, "E held: REVIVE|258|1")
    a_pc.keys.E = false
    handlers.DOWN({ "258", "0", "dead", "" })
    tick(1)
    frame()
    W.find["EnhancedInputLocalPlayerSubsystem"] = nil
    W.objects[IA] = nil
    POSE._t.K().at = -100
    local _, k2 = POSE.interact_key()
    check(k2 == "F", "no mapping readable: F")
end
-- a role change in the same world: own state freed with the live objects
handlers.DOWN({ "257", "1", "45", "0", "", "150", "0", "100", "0" })
tick(1)
frame()
check(a_pc.ignore == 1 and a_pawn["IsPlayerRolling?"] == true, "down again")
S.role = "unknown"
tick(1)
check(a_pc.ignore == 0 and a_pawn["IsPlayerRolling?"] == false and a_pawn.CharacterMovement.MovementMode == 1,
    "role change: frozen movement and flags undone")
S.role = "client"
tick(1)
-- world change on a client: own state gone
handlers.DOWN({ "257", "1", "45", "0", "", "150", "0", "100", "0" })
tick(1)
frame()
D.reset("loadmap")
check(D.views()[257] == nil and not POSE._O().on, "world change: own state dropped")
W.me_pc = host_pc
S.role = "host"

-- ================================================================ 15
say("== 15. moving players (the real sdc_players)")
package.loaded["sdc_players"] = nil
local okp, players = pcall(require, "sdc_players")
check(okp and type(players) == "table", "sdc_players loads " .. (okp and "" or tostring(players)))
if okp then
    players.init(S, { remote_record = function(pc) return S.remote[pc._name] end })
    players.register_handlers()
    clear_all()
    connect({ a_pc }, { b_pc })
    tick(4)
    a_pawn.MedicalComponent.Health = 20
    hit(a_pawn, 90, zed, BODY)
    frame()
    tick(1)
    said = {}
    local okr, code = players.pull_to_host("Ann_PC", "Ann")
    check(okr == false and code == "down" and said_n("pull_down") == 1, "pull a downed player: refused (pull_down)")
    local okg, gcode = players.host_goto("Ann_PC", "Ann")
    check(okg == false and gcode == "target_down" and said_n("goto_target_down") == 1, "the host goes to a downed player: refused")
    sent = {}
    handlers.UNSTUCK({ "host" }, a_pc)
    check(sent_of("UNSTUCKOK", "Ann_PC", "refused", "down")[1] ~= nil, "a downed client's unstuck: refused (down)")
    -- the host down
    clear_all()
    connect({ a_pc }, { b_pc })
    tick(4)
    host_pawn.MedicalComponent.Health = 20
    hit(host_pawn, 90, zed, BODY)
    frame()
    tick(1)
    said = {}
    local okh, hcode = players.pull_to_host("Bob_PC", "Bob")
    check(okh == false and hcode == "host_down" and said_n("pull_host_down") == 1, "the host down: no pull (pull_host_down)")
    local okm, mcode = players.host_goto("Bob_PC", "Bob")
    check(okm == false and mcode == "down" and said_n("goto_down") == 1, "the host down: does not go to a player")
    clear_all()
    connect({ a_pc }, { b_pc })
    tick(4)
    local _, ncode = players.pull_to_host("Ann_PC", "Ann")
    check(ncode ~= "down" and ncode ~= "host_down", "nobody down: no knockdown refusal (" .. tostring(ncode) .. ")")
    -- a client: its own unstuck while down
    S.role = "client"
    S.remote, S.remote_pcs = {}, {}
    W.me_pc = a_pc
    S.client = { acked = true }
    tick(1)
    handlers.DOWN({ "257", "1", "45", "0", "", "150", "0", "100", "0" })
    said = {}
    check(players.request_unstuck("host") == false and said_n("unstuck_down") == 1, "a downed client cannot ask for unstuck")
    handlers.DOWN({ "257", "0", "up", "" })
    tick(1)
    frame()
    D.reset("test")
    W.me_pc = host_pc
    S.role = "host"
end
package.loaded["sdc_players"] = {}

-- ================================================================ 15b
say("== 15b. debug commands: their delayed calls take fresh objects")
do
    package.loaded["sdc_session"] = package.loaded["sdc_session"] or { state = S, roster = function() return {} end }
    local CMDS = {}
    D.register_commands(function(name, _, fn) CMDS[name] = fn end)
    local function run(...) CMDS.sdcoop_down({ ... }, function() end) end
    clear_all()
    connect({ a_pc }, { b_pc })
    tick(1)
    local c0 = CRASHES
    -- pause: the menu of 3 s ago closed and collected, another one open now
    local function menu(name)
        local m = obj("PauseScreen_C", name, { kids = { Save = { vis = "v" }, QuickSave = { vis = "v" }, Suicide = { vis = "v" } } })
        m.IsInViewport = function() return true end
        m.restored = 0
        m.RemoveSaveAndSuicideButton = function(self) self.restored = self.restored + 1 end
        return m
    end
    local old_m, new_m = menu("OldPause"), menu("NewPause")
    W.find["PauseScreen_C"] = { old_m }
    DELAYED = {}
    run("pause")
    check(old_m.kids.Save.vis == "hidden" and #DELAYED == 1, "sdcoop_down pause: hidden now, put back in 3 s")
    old_m._gone = true
    old_m.RemoveSaveAndSuicideButton = function() CRASHES = CRASHES + 1 end
    W.find["PauseScreen_C"] = { old_m, new_m }
    DELAYED[1]()
    check(CRASHES == c0 and new_m.restored == 1, "... 3 s later: the menu open then, never the old object")
    W.find["PauseScreen_C"] = nil
    -- freeze: the controller looked up again after 0.5 s
    local old_pc = W.me_pc
    DELAYED = {}
    run("freeze", "on")
    local _, fresh_pc = player("Fresh", 290, 0, 0, false)
    W.me_pc = fresh_pc
    local old_ign = old_pc.IsMoveInputIgnored
    old_pc.IsMoveInputIgnored = function() CRASHES = CRASHES + 1 return false end
    DELAYED[1]()
    check(CRASHES == c0, "sdcoop_down freeze: 0.5 s later the controller of that moment, not the old one")
    old_pc.IsMoveInputIgnored = old_ign
    W.me_pc = old_pc
    fresh_pc.Pawn._gone = true
    DELAYED = {}
    run("freeze", "off")
    -- prompt game: the HUD looked up again after 3 s
    local shown, real_show = {}, HUD.ShowInteractWidget
    HUD.ShowInteractWidget = function(_, on) shown[#shown + 1] = on end
    DELAYED = {}
    run("prompt", "game")
    check(shown[1] == true and #DELAYED == 1, "sdcoop_down prompt game: shown, closed in 3 s")
    local HUD2 = obj("HUD_Game_C", "HUD2")
    HUD2.ShowInteractWidget = function(_, on) shown[#shown + 1] = "new:" .. tostring(on) end
    local real_gethud = host_pc.GetHUD
    host_pc.GetHUD = function() return HUD2 end
    HUD.ShowInteractWidget = function() CRASHES = CRASHES + 1 end
    DELAYED[1]()
    check(CRASHES == c0 and shown[#shown] == "new:false", "... 3 s later: the HUD of that moment, not the old one")
    host_pc.GetHUD = real_gethud
    HUD.ShowInteractWidget = real_show
    DELAYED = {}
end

-- ================================================================ 16
say("== 16. sources")
local function src(f)
    local h = io.open(dir .. "/" .. f, "r")
    if not h then return "" end
    local s = h:read("a")
    h:close()
    return s
end
local main = src("main.lua")
check(main:find('require("sdc_down")', 1, true) and main:find("down.install(session.state)", 1, true)
    and main:find('ue.every("down", 250, down.tick)', 1, true) and main:find("down.frame_wanted()", 1, true)
    and main:find("down.register_commands(add)", 1, true) and main:find("session.world_reset_hooks.down", 1, true),
    "main.lua: install, tick, frame, commands, world reset")
check(main:find('require("sdc_ffire")', 1, true) < main:find('require("sdc_down")', 1, true), "main.lua: after sdc_ffire")
local net = src("sdc_net.lua")
check(net:find('"DOWN", "DOWNCAP", "REVIVE", "GIVEUP", "DOWNQ"', 1, true) and net:find("DOWN = true", 1, true), "sdc_net: NOW and FREQUENT")
check(src("sdc_admin.lua"):find('f[1] == "down"', 1, true) and src("sdc_admin.lua"):find("down_save_refused", 1, true),
    "sdc_admin: RULES|down routed, save now refused")
check(src("sdc_ui.lua"):find('check_row("down_enabled"', 1, true) and src("sdc_ui.lua"):find("down_on_host", 1, true),
    "sdc_ui: World tab switch and the host's notice")
local pl = src("sdc_players.lua")
check(pl:find('log.say("unstuck_down"', 1, true) and pl:find('refuse("down")', 1, true) and pl:find('refuse("host_down")', 1, true)
    and pl:find('return "target_down"', 1, true) and pl:find('if downed(p) then return "down" end', 1, true), "sdc_players: refusals")
local vh = src("sdc_vehicles.lua")
check(vh:find("function SEATK.out_cold", 1, true) and vh:find("function M.force_out_host", 1, true)
    and vh:find("function M.unseat_client", 1, true) and vh:find('host_unseat(key, "downed"', 1, true)
    and vh:find('if why ~= "downed" then log.say("veh_rejected"', 1, true), "sdc_vehicles: out cold, host out, client out, no odd notice")
check(src("sdc_savecheck.lua"):find("M.someone_down()", 1, true), "sdc_savecheck: saves wait")
local ps = src("sdc_persist.lua")
check(ps:find("v.down_left, v.down_h0", 1, true) and ps:find("dn.restore_later, r.key", 1, true), "sdc_persist: record and restore")
check(src("sdc_session.lua"):find('state = "down"', 1, true) and src("sdc_session.lua"):find("dn.downcap_level(key)", 1, true),
    "sdc_session: F7 down, game for older clients")
check(keybinds == 0 and not src("sdc_down.lua"):find("RegisterKeyBind", 1, true) and not src("sdc_down_pose.lua"):find("RegisterKeyBind", 1, true),
    "no RegisterKeyBind (keys read on the game thread)")
check(CRASHES == 0, "no null-object call anywhere in the run")

print = real_print
say(string.format("knockdown: %d checks, %d failed%s", checks, fails, fails == 0 and ", ALL OK" or ""))
os.exit(fails == 0 and 0 or 1)
