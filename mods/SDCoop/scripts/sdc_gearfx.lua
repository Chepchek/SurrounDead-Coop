-- SDCoop: lights and lasers of OTHER players' gear.
--
-- Weapon modules (BP_*LocalAttachment) are local actors on every machine. Their
-- state (Jig.AttachmentActivate.State1 off / State2 light on / StateADS laser
-- on / StateStopADS) reaches clients through the weapon's RepAttachments.
--   * Lights (weapon modules and the handheld flashlight) are switched by the
--     game's own code on every machine (replicated module state ->
--     ProcessAttachments -> Event_Battery; MC_Flashlight -> FlashlightToggle).
--     They only failed at the battery check, which looks in the OWNER's
--     inventory (host only); sdc_items answers that check with "yes" for
--     another player's item on a client. The PSTATE `fl` backstop for the
--     unreliable MC_Flashlight is in sdc_pawnstate.
--   * The host's copies of a client's modules never received the client's
--     switches: SERVER_UpdateAttachmentState only stores the state in
--     RepAttachments, and OnRep_RepAttachments skips ProcessAttachments on the
--     authority. The host runs the component's own ProcessAttachments after it,
--     as the game itself does after OnAttachmentInstalled / UpdateAttachments.
--
-- Laser beam (game: LaserEndPoint of both laser modules, called by Event_Laser,
-- a 0.01 s looping timer while the module is in StateADS). The beam starts at
-- the module's NS_LaserSight component; its end is traced from
-- GetPlayerCameraManager(0): camera location along the camera's forward
-- vector, 5000 units, ignoring the weapon and the character, then a second
-- trace from the beam start to that hit. So the dot sits where the owner's
-- crosshair points; the weapon's own axis is never used. StateADS is set by
-- ToggleTacticalAttachment on aiming (ADS) and on every hip-fire shot
-- (BP_PlayerCharacter@80192); StateStopADS when aiming stops (@116038) and 3 s
-- after the last hip-fire shot (@5229) - always on the weapon in hand.
-- On another machine "player 0" is the wrong player: on a client sdc_ctx makes
-- it nobody (no camera: the end came out at the world origin), on the host it
-- is the owner's controller, whose camera there is only what ServerUpdateCamera
-- delivers. Every machine therefore re-traces the end after Event_Laser, the
-- game's way, from the owner's aim:
--   host:   the owner's camera as the server has it, when it agrees with the
--           controller's control rotation (ServerMove), else that control
--           rotation from the character's eyes
--   client: GetBaseAimRotation (replicated RemoteViewPitch + actor yaw, which
--           follows the aim while aiming / hip firing) from the eyes
--
-- Holstered weapons. The game never touches a module when its weapon goes to
-- the back or hip (EquipActorToSocket only re-attaches the weapon); a module
-- keeps its state. A swap within the 3 s after a hip-fire shot leaves the old
-- weapon in StateADS (the delayed StopADS goes to the NEW weapon in hand), so
-- its laser kept shining from the back / hip, aimed at "player 0"'s camera
-- point. Other players' light / laser parts are shown here only for the weapon
-- in their hands (replicated BP_JigHelperComp.ActiveWeapon): a holstered
-- weapon's parts are hidden (SetVisibility), drawn again they are shown as
-- they were - the module's state, timers and battery stay the game's.
-- Such a module's 0.01 s Event_Laser timer keeps running for as long as the
-- weapon stays away (0.8.1 host: a friend's rifle on the back, 100 calls a
-- second for 26 minutes, 12-20 ms/s - the owner lookup, slot check and
-- visibility check on every call). The laser hook remembers the module's
-- address once it found the weapon not in hand (gate.away) and returns at
-- once, like for this player's own lasers, while the gate's last poll still
-- has another slot in that player's hands, at most AWAY_S. The draw ends it
-- at the gate's next poll (the gate shows the parts and drops the record),
-- the beam is aimed again from the next Event_Laser.
--
-- Weapons that reach a client already fitted (client): what a sight,
-- suppressor or muzzle brake DOES is not replicated. BP_FirearmPickup binds
-- its OnAttachmentsUpdated handler (-> CheckAttachments: SetCurrentSight /
-- SetCurrentSuppressor / SetCurrentMuzzleBrake on BP_WeaponsPickupComponent,
-- the 'Ironsights' bone hidden) in its BeginPlay (@6383 -> 4526), and only
-- ProcessAttachments' broadcast at its end calls it. The host spawns an
-- equipped weapon and fits it in the same frame (BP_JigHelperComp.OnMainAdded:
-- SpawnActor, then UpdateAttachmentFromMP -> OnAttachmentInstalled), so its
-- first bunch to a client already carries RepAttachments; the engine runs
-- OnRep_RepAttachments -> ProcessAttachments (module actors spawned and
-- attached, the broadcast) BEFORE that new actor's BeginPlay (PostNetInit)
-- - nobody listens yet. The client's weapon then has its modules on it but
-- no sight (no scope zoom, iron sights in the way), no suppressor, no muzzle
-- brake, until a module is taken off and put on again (the next
-- RepAttachments change). That hit every fitted weapon of a client restored
-- by sdc_persist on a re-join, and any fitted weapon equipped from a
-- container or coming into view. After such a weapon's BeginPlay the
-- component's own ProcessAttachments runs once more - what OnRep_RepAttachments
-- runs on every change: modules found again by UID (none spawned twice), then
-- the broadcast that now reaches CheckAttachments (refit below).

local log = require("sdc_log")
local ue = require("sdc_ue")
local pawnstate = require("sdc_pawnstate")
local items = require("sdc_items")

local M = {}
local S
function M.init(state) S = state end

-- A host nobody is connected to: no other player's gear to fix.
local function host_alone()
    return S.role == "host" and #(S.remote_pcs or {}) == 0
end

local LASERS = {
    "/Game/Inventory/Items/LocalAttachments/Tactical/BP_SmallTacticalLaserSightLocalAttachment.BP_SmallTacticalLaserSightLocalAttachment_C:Event_Laser",
    "/Game/Inventory/Items/LocalAttachments/Tactical/BP_TacticalLaserLightComboLocalAttachment.BP_TacticalLaserLightComboLocalAttachment_C:Event_Laser",
}
-- trace channel the game's own LaserEndPoint uses (it hits characters too)
local LASER_CHANNEL = {
    BP_SmallTacticalLaserSightLocalAttachment_C = 6,
    BP_TacticalLaserLightComboLocalAttachment_C = 5,
}
-- light / laser parts of each module class (decompiled component variables)
local FX_PARTS = {
    BP_SmallTacticalLaserSightLocalAttachment_C = { "NS_LaserSight", "PointLight" },
    BP_TacticalLaserLightComboLocalAttachment_C = { "NS_LaserSight", "PointLight", "SpotLight" },
    BP_SmallTacticalLightLocalAttachment_C = { "SpotLight" },
    BP_TacticalLightLocalAttachment_C = { "SpotLight" },
}
M.FX_PARTS = FX_PARTS
local HOST_STATE_RPC = "/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C:SERVER_UpdateAttachmentState"
local LASER_RANGE = 5000      -- LaserEndPoint: forward vector * 5000
local CAM_NEAR = 1500         -- host: the owner's camera counts when this close to its eyes ...
local CAM_AGREE = 5           -- ... and within this many degrees of its control rotation
local GATE_MS = 100           -- holster gate: active slot poll
local GATE_SWEEP = 1.0        -- s between full passes (modules re-created / re-lit by the game)
local GATE_LOG_INFO = 200     -- holster / draw lines at info level, then debug

local function m_addr(o) return o:GetAddress() end
local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(m_addr, o)
    if ok and type(a) == "number" and a ~= 0 then return a end
    return nil
end

local function is_player(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

local function is_local(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

-- module -> weapon -> character
local function owner_pawn(att)
    local w = ue.try(function() return att:GetOwner() end)
    local p = w and ue.try(function() return w:GetOwner() end)
    return p, w
end

local ksl_obj
local function ksl()
    if not ue.valid(ksl_obj) then ksl_obj = ue.find_object("/Script/Engine.Default__KismetSystemLibrary") end
    return ksl_obj
end

local function vec_of(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

local function rot_of(r)
    if r == nil then return nil end
    local ok, p, y = pcall(function() return r.Pitch, r.Yaw end)
    if ok and type(p) == "number" and type(y) == "number" then return { Pitch = p, Yaw = y, Roll = 0 } end
    return nil
end

local function norm180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- FRotator::Vector (KismetMathLibrary.GetForwardVector)
local function forward(r)
    local p, y = math.rad(r.Pitch), math.rad(r.Yaw)
    return { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
end
M.forward = forward

local function dist2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- ---------------------------------------------------------------------------
-- Holster gate: light / laser parts only for the weapon in hand
-- ---------------------------------------------------------------------------

local gate = {
    tags = {},     -- [pawn address] = active slot seen at the last poll
    slots = {},    -- [weapon address] = { slot =, pawn = pawn address }
    hidden = {},   -- [module address] = { names = { [part] = true }, pawn = pawn address }
    miss = {},     -- [weapon address] = os.clock() of a slot lookup that did not find it
    -- [module address] = { t = os.clock(), pk = pawn address, slot = its weapon's
    -- slot, n = Event_Laser calls skipped }: a laser found on a weapon not in hand
    away = {},
    swept = -1e9,  -- os.clock() of the last full pass
    loop = false,  -- the gate loop was registered
    logged = 0,
}
M.gate = gate

-- The replicated slot in hand ("Jig.PlayerSlot.PrimaryWeapon", "None"), or nil.
local function active_slot(pawn)
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return nil end
    local tag = ue.str(ue.try(function() return helper.ActiveWeapon.TagName end))
    if tag == "" then return nil end
    return tag
end

local function weapons_of(pawn, pk)
    local out = {}
    for _, it in pairs(items.equipped_of(pawn)) do
        if type(it.slot) == "string" and it.slot:find("Weapon", 1, true) and ue.valid(it.actor) then
            out[#out + 1] = it
            local wk = addr(it.actor)
            if wk then gate.slots[wk] = { slot = it.slot, pawn = pk } end
        end
    end
    return out
end

-- Modules with light / laser parts installed on a weapon (this machine's actors).
local function fx_modules(weapon)
    local out = {}
    local comp = ue.prop(weapon, "BP_JigPickupComponent")
    if not ue.valid(comp) then return out end
    local arr = ue.prop(comp, "InstalledAttachments")
    if not arr then return out end
    pcall(function()
        arr:ForEach(function(_, e)
            local m = e:get()
            if ue.valid(m) and FX_PARTS[ue.class_name(m)] then out[#out + 1] = m end
        end)
    end)
    return out
end

local function state_tag(m)
    local s = ue.str(ue.try(function() return m.ActivateState.TagName end))
    return (s:gsub("^Jig%.AttachmentActivate%.", ""))
end

-- "laser on, light off" for the log
local function lit_text(m)
    local parts = {}
    local ns = ue.prop(m, "NS_LaserSight")
    if ue.valid(ns) then
        parts[#parts + 1] = "laser " .. (ue.try(function() return ns:IsActive() end) == true and "on" or "off")
    end
    local sl = ue.prop(m, "SpotLight")
    if ue.valid(sl) then
        local i = ue.prop(sl, "Intensity")
        parts[#parts + 1] = "light " .. ((type(i) == "number" and i > 0) and "on" or "off")
    end
    return table.concat(parts, ", ")
end

local function gate_log(fmt, ...)
    gate.logged = gate.logged + 1
    if gate.logged <= GATE_LOG_INFO then log.info(fmt, ...) else log.debug(fmt, ...) end
end

-- Hides (show = false) or restores the module's light / laser parts. Only the
-- parts this gate hid are made visible again. Returns true when it changed.
local function set_shown(pawn, weapon, m, show, why)
    local mk = addr(m)
    if not mk then return false end
    local rec = gate.hidden[mk]
    if show then
        -- in hand: the laser hook aims its beam again from the next call
        local off = gate.away[mk]
        gate.away[mk] = nil
        if not rec then return false end
        gate.hidden[mk] = nil
        for name in pairs(rec.names) do
            local c = ue.prop(m, name)
            if ue.valid(c) then pcall(function() c:SetVisibility(true, false) end) end
        end
        gate_log("gearfx: holster: %s drew %s: %s light/laser shown again (module state %s, %s; %s%s)",
            ue.short(pawn), ue.class_name(weapon), ue.class_name(m), state_tag(m), lit_text(m), why,
            (off and off.n > 0) and string.format("; %d laser call(s) skipped while away", off.n) or "")
        return true
    end
    local names = rec and rec.names or {}
    local changed = false
    for _, name in ipairs(FX_PARTS[ue.class_name(m)] or {}) do
        local c = ue.prop(m, name)
        if ue.valid(c) and ue.try(function() return c:IsVisible() end) == true then
            if pcall(function() c:SetVisibility(false, false) end) then
                names[name] = true
                changed = true
            end
        end
    end
    if next(names) == nil then return false end
    gate.hidden[mk] = { names = names, pawn = addr(pawn) }
    if changed and not rec then
        gate_log("gearfx: holster: %s put %s away: %s light/laser hidden here (module state %s, %s; %s)",
            ue.short(pawn), ue.class_name(weapon), ue.class_name(m), state_tag(m), lit_text(m), why)
    end
    return changed
end
M.set_shown = set_shown

-- One character: every light / laser module shown for the weapon in hand only.
local function pass_pawn(p, pk, active, why)
    local mods = {}
    for _, it in ipairs(weapons_of(p, pk)) do
        local in_hand = it.slot == active
        for _, m in ipairs(fx_modules(it.actor)) do
            local mk = addr(m)
            if mk then mods[mk] = true end
            set_shown(p, it.actor, m, in_hand, why)
        end
    end
    -- modules the game destroyed (re-created, removed with the weapon)
    for k, r in pairs(gate.hidden) do
        if r.pawn == pk and not mods[k] then gate.hidden[k] = nil end
    end
    for k, r in pairs(gate.away) do
        if r.pk == pk and not mods[k] then gate.away[k] = nil end
    end
end

-- Records of characters (and their weapons / modules) not seen any more.
local function prune(seen)
    for k in pairs(gate.tags) do if not seen[k] then gate.tags[k] = nil end end
    for k, r in pairs(gate.slots) do if not seen[r.pawn] then gate.slots[k] = nil end end
    for k, r in pairs(gate.hidden) do if not seen[r.pawn] then gate.hidden[k] = nil end end
    for k, r in pairs(gate.away) do if not seen[r.pk] then gate.away[k] = nil end end
    gate.miss = {}
end

-- Every GATE_MS: an active slot that changed gets a pass at once, every
-- character a full pass each GATE_SWEEP s (the game re-creates modules in
-- ProcessAttachments; a re-lit module of a holstered weapon is hidden again).
local function gate_body()
    if not S or (S.role ~= "host" and S.role ~= "client") then return end
    if host_alone() then
        -- the last player left: their records go
        if next(gate.tags) or next(gate.slots) or next(gate.hidden) or next(gate.away) then prune({}) end
        return
    end
    local now = os.clock()
    local sweep = now - gate.swept >= GATE_SWEEP or now < gate.swept
    if sweep then gate.swept = now end
    local seen = {}
    -- other players' characters here (the host: every remote character; a
    -- client: replicated ones, not a stale local copy)
    for _, p in ipairs(pawnstate.others()) do
        local pk = addr(p)
        local active = pk and active_slot(p)
        if pk then seen[pk] = true end
        if active then
            local before = gate.tags[pk]
            gate.tags[pk] = active
            if before ~= active or sweep then
                local why = before == nil and "first look"
                    or (before ~= active and ("slot " .. before .. " -> " .. active) or "sweep")
                local ok, err = pcall(pass_pawn, p, pk, active, why)
                if not ok then log.err_throttled("gearfx-gate-pawn", "gearfx: holster gate: %s", tostring(err)) end
            end
        end
    end
    if sweep then prune(seen) end
end

function M.gate_tick()
    local ok, err = pcall(gate_body)
    if not ok then log.err_throttled("gearfx-gate", "gearfx: holster gate: %s", tostring(err)) end
end

local function ensure_gate_loop()
    if gate.loop then return end
    gate.loop = true
    local ok, err = pcall(ue.every, "gearfx-holster", GATE_MS, M.gate_tick)
    gate.loop_ok = ok
    log.info("gearfx: holster gate: other players' lights / lasers only for the weapon in hand (every %d ms%s)",
        GATE_MS, ok and "" or (", loop FAILED: " .. tostring(err) .. "; once a second instead"))
end

-- Laser hook: the weapon is not in hand (true), in hand (false), unknown (nil);
-- known: its gate.slots record second.
local function holstered_now(pawn, weapon)
    local wk = addr(weapon)
    if not wk then return nil end
    local rec = gate.slots[wk]
    if not rec then
        -- not among the character's equipped actors (yet): look again later
        local now = os.clock()
        local t = gate.miss[wk]
        if t and now - t < 0.5 and now >= t then return nil end
        weapons_of(pawn, addr(pawn))
        rec = gate.slots[wk]
        if not rec then
            gate.miss[wk] = now
            return nil
        end
        gate.miss[wk] = nil
    end
    local active = active_slot(pawn)
    if not active then return nil end
    return rec.slot ~= active, rec
end

-- ---------------------------------------------------------------------------
-- Laser beams of other players
-- ---------------------------------------------------------------------------

-- Hit point of one trace on the game's laser channel, or nil.
local function trace(att, weapon, pawn, from, to)
    local hit = {}
    local channel = LASER_CHANNEL[ue.class_name(att)] or 0
    local ok, got = pcall(function()
        return ksl():LineTraceSingle(att, from, to, channel, false, { att, weapon, pawn }, 0, hit, true,
            { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
    end)
    if ok and got == true then
        return vec_of(hit.ImpactPoint) or vec_of(hit.Location)
    end
    return nil
end

-- The character's eyes (GetPawnViewLocation: actor + BaseEyeHeight).
local function eyes(pawn)
    local v = vec_of(ue.try(function() return pawn:GetPawnViewLocation() end))
    if v then return v end
    local loc = ue.location(pawn)
    if not loc then return nil end
    local eh = ue.prop(pawn, "BaseEyeHeight")
    return { X = loc.X, Y = loc.Y, Z = loc.Z + (type(eh) == "number" and eh or 0) }
end

-- Where the owner looks from and along: origin, rotation, source name.
local function aim_ray(pawn, start)
    local eye = eyes(pawn) or start
    if S.role == "host" then
        local pc = ue.prop(pawn, "Controller")
        if ue.valid(pc) then
            local cr = rot_of(ue.try(function() return pc:GetControlRotation() end))
            local cam = cr and ue.prop(pc, "PlayerCameraManager")
            if ue.valid(cam) then
                local cl = vec_of(ue.try(function() return cam:GetCameraLocation() end))
                local rot = rot_of(ue.try(function() return cam:GetCameraRotation() end))
                if cl and rot and dist2(cl, eye) <= CAM_NEAR * CAM_NEAR
                    and math.abs(norm180(rot.Pitch - cr.Pitch)) <= CAM_AGREE
                    and math.abs(norm180(rot.Yaw - cr.Yaw)) <= CAM_AGREE then
                    return cl, rot, "owner camera (server copy)"
                end
            end
            if cr then return eye, cr, "control rotation (server copy)" end
        end
    end
    local br = rot_of(ue.try(function() return pawn:GetBaseAimRotation() end))
    if br then return eye, br, "base aim (RemoteViewPitch + actor yaw)" end
    return nil
end
M.aim_ray = aim_ray

-- LaserEndPoint with the owner's aim: trace along the aim, then from the beam
-- start to that point (the first thing in between wins).
local function beam_end(att, weapon, pawn, start, origin, rot)
    local d = forward(rot)
    local far = { X = origin.X + d.X * LASER_RANGE, Y = origin.Y + d.Y * LASER_RANGE, Z = origin.Z + d.Z * LASER_RANGE }
    local p = trace(att, weapon, pawn, origin, far)
    if not p then return far end
    return trace(att, weapon, pawn, start, p) or p
end

local aim_logged = {}   -- [weapon class .. "|" .. source] = true
-- The 0.01 s timer runs Event_Laser several times in one frame (once per
-- 0.01 s elapsed): within REUSE_S the last end is written again, not traced.
local REUSE_S = 0.004
local last_end = {}     -- [module address] = { t = os.clock(), p = end point }
local last_end_n = 0
-- This player's own laser modules (~100 Event_Laser a second): skipped by
-- address for MINE_S without the owner lookup (~6 engine calls); then
-- looked up again (an address can be reused by another module).
local MINE_S = 1.0
local mine = {}         -- [module address] = os.clock() it was found to be this player's
local mine_n = 0
-- Another player's laser on a weapon not in hand (gate.away, see the header):
-- skipped by address while the gate has not seen that slot drawn, at most
-- AWAY_S; then looked up again (the gate loop may be down, an address can be
-- reused).
local AWAY_S = 0.5
M.AWAY_S = AWAY_S
local function note_away(ak, srec, now)
    local off = gate.away[ak]
    if off then
        off.t, off.pk, off.slot = now, srec.pawn, srec.slot
    else
        gate.away[ak] = { t = now, pk = srec.pawn, slot = srec.slot, n = 0 }
    end
end
local beam_param = nil
local function laser_fix(c)
    if not S or (S.role ~= "client" and S.role ~= "host") or host_alone() then return end
    local att = c and c:get()
    if not ue.valid(att) then return end
    local ak = addr(att)
    local now = os.clock()
    local own_at = ak and mine[ak]
    if own_at and now - own_at < MINE_S and now >= own_at then return end
    local off = ak and gate.away[ak]
    if off and now - off.t < AWAY_S and now >= off.t and gate.tags[off.pk] ~= off.slot then
        off.n = off.n + 1
        return
    end
    local prev = ak and last_end[ak]
    if prev and now - prev.t < REUSE_S and now >= prev.t then
        local ns0 = ue.prop(att, "NS_LaserSight")
        if ue.valid(ns0) then pcall(function() ns0:SetVectorParameter(beam_param, prev.p) end) end
        return
    end
    local pawn, weapon = owner_pawn(att)
    if not is_player(pawn) then return end
    if is_local(pawn) then
        if ak then
            if not own_at then
                mine_n = mine_n + 1
                -- modules come and go with weapons: start over now and then
                if mine_n > 64 then mine, mine_n = {}, 1 end
            end
            mine[ak] = now
        end
        return
    end
    if ak and own_at then
        mine[ak] = nil
        mine_n = mine_n - 1
    end
    -- a holstered weapon's beam stays hidden; drawn again it is shown
    local away, srec = holstered_now(pawn, weapon)
    if away then
        set_shown(pawn, weapon, att, false, "laser of a weapon not in hand")
        if ak then note_away(ak, srec, now) end
        return
    end
    if away == false and gate.hidden[ak or -1] then set_shown(pawn, weapon, att, true, "laser") end
    local ns = ue.prop(att, "NS_LaserSight")
    if not ue.valid(ns) then return end
    local start = vec_of(ue.try(function() return ns:K2_GetComponentLocation() end))
    if not start then return end
    local origin, rot, source = aim_ray(pawn, start)
    if not origin then return end
    local p = beam_end(att, weapon, pawn, start, origin, rot)
    if not beam_param then beam_param = FName("User.Beam End") end
    if pcall(function() ns:SetVectorParameter(beam_param, p) end) then
        if ak then
            if not last_end[ak] then
                last_end_n = last_end_n + 1
                -- modules come and go with weapons: start over now and then
                if last_end_n > 64 then last_end, last_end_n = {}, 1 end
            end
            last_end[ak] = { t = now, p = p }
        end
        local key = ue.class_name(weapon) .. "|" .. source
        if not aim_logged[key] then
            aim_logged[key] = true
            log.info("gearfx: laser of %s on %s (%s): aim from %s, beam from the module to the aim point (%s)",
                ue.short(pawn), ue.class_name(weapon), ue.class_name(att), source, S.role)
        end
    end
end

local laser_hooked = {}
local function try_hook_lasers()
    for _, path in ipairs(LASERS) do
        if not laser_hooked[path] then
            local ok = pcall(RegisterHook, path, function(c)
                local okc, err = pcall(laser_fix, c)
                if not okc then log.err_throttled("gearfx-laser", "gearfx: laser: %s", tostring(err)) end
            end)
            if ok then
                laser_hooked[path] = true
                log.info("gearfx: laser hook ok (%s)", path:match("%.([%w_]+):"))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host: apply a client's module switches to the host's copies
-- ---------------------------------------------------------------------------

-- SERVER_UpdateAttachmentState(UID, NewState), post: RepAttachments now holds
-- the new state; ProcessAttachments applies it to the local module actors
-- (Jig_SetAttachmentActiveState) and reconciles them, exactly what clients
-- run from OnRep_RepAttachments.
local host_states = 0   -- client switches applied on the host (the first are logged)
local function on_host_state(c, uid_p, state_p)
    if S.role ~= "host" then return end
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    local weapon = ue.try(function() return comp:GetOwner() end)
    local pawn = weapon and ue.try(function() return weapon:GetOwner() end)
    -- the host's own switches: the game pre-executes them locally
    if not is_player(pawn) or is_local(pawn) then return end
    local ok, err = pcall(function() comp:ProcessAttachments() end)
    host_states = host_states + 1
    if host_states <= 3 or not ok then
        local tag = ue.try(function() return ue.str(state_p:get().TagName) end)
        log.info("gearfx: %s of %s -> %s on the host (ProcessAttachments ok=%s%s)", ue.class_name(weapon),
            ue.short(pawn), tostring(tag), tostring(ok), ok and "" or (" " .. tostring(err)))
    end
end

local host_hooked = false
local function try_hook_host()
    if host_hooked then return end
    local ok = pcall(RegisterHook, HOST_STATE_RPC, function(c, uid_p, state_p)
        local okc, err = pcall(on_host_state, c, uid_p, state_p)
        if not okc then log.err_throttled("gearfx-host", "gearfx: host state: %s", tostring(err)) end
    end)
    if ok then
        host_hooked = true
        log.info("gearfx: module state hook ok")
    end
end

-- ---------------------------------------------------------------------------
-- Client: a weapon that arrives already fitted (see the header)
-- ---------------------------------------------------------------------------

local FIREARM_BEGIN = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:ReceiveBeginPlay"
local F_REP_ATTS = "Attachments_6_38F2C7B64C1B85D80C3C35A8B1026969"   -- S_RepWeaponAttachment.Attachments
local REFIT_LOG_INFO = 30     -- refit lines at info level, then debug
local REFIT_SEEN_MAX = 256    -- remembered weapons (by address + full name; no wrappers kept)

local refit = { seen = {}, n = 0, hooked = false, logged = 0 }
M.refit = refit

-- Modules in the weapon's replicated RepAttachments.
local function rep_modules(comp)
    local rep = ue.prop(comp, "RepAttachments")
    local list = rep ~= nil and ue.try(function() return rep[F_REP_ATTS] end) or nil
    if list == nil then return 0 end
    local ok, n = pcall(function() return list:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    return 0
end

-- What CheckAttachments left on BP_WeaponsPickupComponent, for the log.
local function fit_text(weapon)
    local wc = ue.prop(weapon, "BP_WeaponsPickupComponent")
    if not ue.valid(wc) then return "no BP_WeaponsPickupComponent" end
    local sight = ue.prop(wc, "CurrentSight")
    return string.format("sight %s, suppressor %s, muzzle brake %s", ue.valid(sight) and ue.short(sight) or "none",
        ue.prop(wc, "SuppressorAttached?") == true and "yes" or "no",
        ue.prop(wc, "MuzzleBrakeAttached?") == true and "yes" or "no")
end

-- A replicated copy (this machine did not spawn it).
local function replicated_copy(a)
    local r = ue.role(a)
    return r == ue.ROLE_SIMULATED or r == ue.ROLE_AUTONOMOUS
end

local function remember(wk, name)
    if refit.seen[wk] == nil then
        refit.n = refit.n + 1
        if refit.n > REFIT_SEEN_MAX then refit.seen, refit.n = {}, 1 end
    end
    refit.seen[wk] = name
end

-- The weapon's own ProcessAttachments once more, now that its handler is
-- bound. Weapons without modules are left alone. Returns true when it ran.
local function refit_weapon(weapon, why)
    local comp = ue.prop(weapon, "BP_JigPickupComponent")
    if not ue.valid(comp) then return false end
    local n = rep_modules(comp)
    if n == 0 then return false end
    local before = fit_text(weapon)
    local ok, err = pcall(function() comp:ProcessAttachments() end)
    refit.logged = refit.logged + 1
    local owner = ue.try(function() return weapon:GetOwner() end)
    local fmt = "gearfx: %s of %s %s with %d module(s): ProcessAttachments run again (ok=%s%s): was %s -> now %s"
    local args = { ue.short(weapon), ue.short(owner), why, n, tostring(ok), ok and "" or (" " .. tostring(err)),
        before, fit_text(weapon) }
    if refit.logged <= REFIT_LOG_INFO or not ok then log.info(fmt, table.unpack(args)) else log.debug(fmt, table.unpack(args)) end
    return ok
end

-- BP_FirearmPickup.ReceiveBeginPlay, post (client): the handler is bound now.
local function on_firearm_begin(c)
    if not S or S.role ~= "client" then return end
    local w = c and c:get()
    if not ue.valid(w) or not replicated_copy(w) then return end
    local wk = addr(w)
    if wk then remember(wk, ue.name(w)) end
    refit_weapon(w, "arrived fitted")
end

local function try_hook_refit()
    if refit.hooked then return end
    local ok = pcall(RegisterHook, FIREARM_BEGIN, function(c)
        local okc, err = pcall(on_firearm_begin, c)
        if not okc then log.err_throttled("gearfx-refit", "gearfx: refit: %s", tostring(err)) end
    end)
    if ok then
        refit.hooked = true
        log.info("gearfx: refit hook ok (a weapon that arrives fitted gets its sight / suppressor / muzzle brake here)")
    end
end

-- The own character's weapons the BeginPlay hook never saw (they came before
-- it was in): refitted now. sdc_persist runs it after the host's restore.
function M.refit_own(why)
    if not S or S.role ~= "client" then return 0 end
    local pawn = ue.local_pawn()
    if not ue.valid(pawn) then return 0 end
    local looked, done = 0, 0
    for _, it in pairs(items.equipped_of(pawn)) do
        local w = it.actor
        if type(it.slot) == "string" and it.slot:find("Weapon", 1, true) and ue.valid(w) and replicated_copy(w)
            and type(ue.prop(w, "FireReady")) == "boolean" then   -- a BP_FirearmPickup (CheckAttachments)
            looked = looked + 1
            local wk, name = addr(w), ue.name(w)
            if wk and refit.seen[wk] ~= name then
                remember(wk, name)
                if refit_weapon(w, why) then done = done + 1 end
            end
        end
    end
    log.info("gearfx: %s: %d own firearm(s), %d refitted now (the others were refitted on arrival or have no modules; hook %s)",
        why, looked, done, refit.hooked and "in" or "NOT in")
    return done
end

-- 1 s ticks (sdc_session phase B). The host's hooks and gate loop wait for
-- a remote player.
local function common_tick()
    try_hook_lasers()
    ensure_gate_loop()
    if not gate.loop_ok then M.gate_tick() end
end
function M.host_tick()
    if host_alone() then return end
    try_hook_host()
    common_tick()
end
function M.client_tick() try_hook_refit(); common_tick() end

return M
