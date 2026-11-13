-- SDCoop: knockdown on every machine (sdc_down's views): the pose, the
-- action flags, the frozen movement, the keys, the bars and the notices.
--
-- Pose: the game's own "sitting on the floor" (Chr_SittingFloor_Montage,
-- BP_PlayerCharacter @3514-3518), played here on every downed character
-- this machine knows (PlayAnimMontage: local, as the vehicles' seat pose)
-- and started again when another montage took it (own character: 10 times
-- a second; copies: every 250 ms). The host's copy of a client gets
-- bOnlyAllowAutonomousTickPose off while downed (else the host sees a frozen
-- pose). The capsule is left as it is unless `sdcoop_down capsule use on`.
-- Own downed character, every frame:
--   * flags IsPlayerRolling? / CurrentlyChangingWeapon? (no shot, aim,
--     swing, jump, roll, the game's interact) and, once the weapon is put
--     away (ServerFuncChangeActiveSlot None, once), Attacking? (no weapon
--     keys); off once at the end;
--   * movement: one decision a frame "frozen = down OR reviving somebody":
--     SetIgnoreMoveInput(true) only while IsMoveInputIgnored() is false (the
--     engine counts these), DisableMovement only on the ground and while the
--     mode is not None (both checked 20 times a second once frozen); undone
--     once (ResetIgnoreMoveInput, walking) when both reasons are gone;
--   * an open inventory is closed (ToggleInventory, the game's own way);
--   * the spot from DOWN: more than 1 m away (horizontally, not falling) ->
--     moved back (a client moves its own character);
--   * give up: the interact key held GIVEUP_S, counted only from a press
--     after going down (a key held from before - a rescuer knocked down
--     while holding F - must be let go first) and not in the first second;
--   * the game's timer bar (HUD_Game.InteractTimerUI + its widget's
--     CurrentTime / MaxTime, as the vehicles' refuel bar; the time written
--     20 times a second, MaxTime once per bar): "Bleeding out"
--     (the time left), "You're being revived" (the progress), "Giving up";
--     the game's notices: on going down, at 30 and 10 s left, at the end.
-- Rescuer (this machine's player stands, not in a vehicle, a downed player
-- within NEAR_CM): looking at it (the camera ray within a few degrees of
-- its body, 40 cm below the capsule's centre, and AController.LineOfSightTo;
-- checked 10 times a second, the key every frame)
-- within REVIVE_START_CM (keeps it within REVIVE_KEEP_CM) and holding the
-- interact key: sdc_down.hold(id, true) once (a client: REVIVE|id|1), the
-- bar "Reviving <name>", its own movement frozen, the game's looting
-- montage through BPI_Player.PlayMontage (every machine sees it, older
-- versions too) about once a second; let go: hold(id, false), the montage
-- stopped. Looking at a downed player without the key: one notice "Hold
-- [F] to get <name> up" (at most every 15 s each).
-- Keys: read on the game thread only (PlayerController.IsInputKeyDown), the
-- interact key as the player mapped it (IA_Interact: QueryKeysMappedToAction,
-- its array result a plain Lua table; else F). Never with the chat line open
-- or the mouse cursor shown.

local log = require("sdc_log")
local ue = require("sdc_ue")
local ctx = require("sdc_ctx")

local P = { want_frame = false, frozen = false }
local S, D = nil, nil
local addr = ctx.addr
local clock = os.clock

local FLOOR = "/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage"
local LOOT = "/Game/Character/Anims/Interaction/Chr_Interact_Looting_Montage.Chr_Interact_Looting_Montage"
local IA_INTERACT = "/Game/Input/InventoryPlayerActions/IA_Interact.IA_Interact"
local MOVE_NONE, MOVE_WALKING = 0, 1
local SPOT_CM, SPOT_EVERY_S = 100, 0.5
local HINT_EVERY_S = 15
local ANIM_EVERY_S = 1.0
local LOOK_DEG = 8
-- what does not need every frame (the frame loop's cost while somebody is
-- down): the bar 20 times a second, the pose and the movement check 10 / 20
-- times, the rescuer's aim (camera, distance, line of sight) 10 times
local BAR_EVERY_S, POSE_EVERY_S, FREEZE_EVERY_S, AIM_EVERY_S = 0.05, 0.1, 0.05, 0.1
P.FLOOR, P.LOOT, P.IA_INTERACT = FLOOR, LOOT, IA_INTERACT

local O = { on = false }      -- this machine's own downed player
local R = nil                 -- reviving { id, since, anim_at, name }
local A = { at = -100, id = nil }   -- the rescuer's aim (AIM_EVERY_S): the downed player looked at
local B = { kind = nil }      -- the game's timer bar while ours
local K = { at = -100 }       -- the interact key
local T = { freeze = false, pose = {}, capsule_use = false }   -- sdcoop_down test switches
local copies = {}             -- [character address] = { id, name, tickpose, cap }
local near = {}               -- downed ids within NEAR_CM
local hint_at = {}
local montages = { tried = {} }
P._O, P._T = function() return O end, T

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function dead(p) return ue.prop(p, "PlayerDead?") == true end

-- A caption in the player's language (sdc_i18n STR down_bar_*).
local FALLBACK = { down_bar_bleed = "Bleeding out", down_bar_reviving = "Reviving %s", down_bar_being = "You're being revived",
                   down_bar_giveup = "Giving up", down_mate = "a teammate" }
local function tr(key, ...)
    local i18n = package.loaded["sdc_i18n"]
    if type(i18n) == "table" and type(i18n.T) == "function" then
        local ok, s = pcall(i18n.T, key, ...)
        if ok and type(s) == "string" and s ~= key then return s end
    end
    local ok, s = pcall(string.format, FALLBACK[key] or key, ...)
    return ok and s or key
end

local function montage(path)
    local m = montages[path]
    if m and ue.valid(m) then return m end
    if S and S.role == "host" and not montages.tried[path] then
        montages.tried[path] = true
        ue.load_asset(path, "down")
    end
    m = ue.loaded_asset(path, "down")
    montages[path] = m
    return m
end
P.montage = montage

local function playing(p, m)
    local cur = ue.try(function() return p:GetCurrentMontage() end)
    return ue.valid(cur) and ue.valid(m) and ue.short(cur) == ue.short(m)
end

local function hold_pose(p)
    local m = montage(FLOOR)
    if not m then return false end
    if playing(p, m) then return true end
    return (pcall(function() p:PlayAnimMontage(m, 1.0, FName("None")) end))
end
P.hold_pose = hold_pose

-- The pose off here; `everywhere`: the game's replicated stop too.
local function stop_pose(p, everywhere)
    local m = montages[FLOOR]
    if not (m and ue.valid(m)) then return end
    if playing(p, m) then pcall(function() p:StopAnimMontage(m) end) end
    if everywhere then pcall(function() p:StopMontage(m, false) end) end
end
P.stop_pose = stop_pose

local function all_chars()
    local out = {}
    for _, p in ipairs(ue.player_chars() or {}) do
        if ue.valid(p) and not dead(p) then out[#out + 1] = p end
    end
    return out
end

local function char_by_id(id)
    if id == nil then return nil end
    for _, p in ipairs(all_chars()) do
        if D.player_id(p) == id then return p end
    end
    return nil
end
P.char_by_id = char_by_id

local function remote_controlled(p)
    local pc = ue.prop(p, "Controller")
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

-- The first key name in QueryKeysMappedToAction's result. UE4SS returns an
-- array return value as a plain Lua table of element params
-- (LuaUObject.cpp push_arrayproperty, GetNonTrivialLocal): ipairs + get();
-- a TArray object (another UE4SS build) through its ForEach.
local function first_key_name(keys)
    local name = nil
    local function one(e)
        if name then return end
        local k = ue.elem(e)
        local s = ue.str(ue.try(function() return k.KeyName end))
        if s ~= "" and s ~= "None" then name = s end
    end
    if type(keys) == "table" then
        for _, e in ipairs(keys) do
            one(e)
            if name then break end
        end
    else
        pcall(function() keys:ForEach(function(_, e) one(e) end) end)
    end
    return name
end
P.first_key_name = first_key_name

-- The interact key's FKey and name (as the player mapped IA_Interact), F
-- when that cannot be read. Looked up again every 10 s.
local function interact_key()
    local t = clock()
    if K.fk and t - K.at < 10 then return K.fk, K.name end
    local name = nil
    local ia = ue.find_object(IA_INTERACT)
    if ia then
        for _, ss in ipairs(ue.find_all("EnhancedInputLocalPlayerSubsystem")) do
            local keys = ue.valid(ss) and ue.try(function() return ss:QueryKeysMappedToAction(ia) end) or nil
            if keys then
                name = first_key_name(keys)
                break
            end
        end
    end
    name = name or "F"
    if name ~= K.name then log.info("[DOWN] the interact key here: %s", name) end
    K.fk, K.name, K.at = { KeyName = FName(name) }, name, t
    return K.fk, name
end
P.interact_key = interact_key

local function key_down(pc)
    local fk = interact_key()
    return ue.try(function() return pc:IsInputKeyDown(fk) end) == true
end

-- Something else has the keys: the chat line, a window (the mouse cursor).
local function busy(pc)
    local chat = package.loaded["sdc_chat"]
    if type(chat) == "table" and type(chat.is_open) == "function" then
        local ok, open = pcall(chat.is_open)
        if ok and open == true then return true end
    end
    return ue.prop(pc, "bShowMouseCursor") == true
end

local function camera_view(pc)
    local cam = ue.prop(pc, "PlayerCameraManager")
    if not ue.valid(cam) then return nil end
    local ok, l, pitch, yaw = pcall(function()
        local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
        return { X = loc.X, Y = loc.Y, Z = loc.Z }, rot.Pitch, rot.Yaw
    end)
    if not ok or type(l) ~= "table" or type(l.X) ~= "number" or type(pitch) ~= "number" or type(yaw) ~= "number" then
        return nil
    end
    local pr, yr = math.rad(pitch), math.rad(yaw)
    return l, { X = math.cos(pr) * math.cos(yr), Y = math.cos(pr) * math.sin(yr), Z = math.sin(pr) }
end

-- The camera looks at the sitting body (40 cm below the capsule's centre)
-- and nothing blocks the view.
local function looks_at(pc, p, pl, cl, fwd)
    local dx, dy, dz = pl.X - cl.X, pl.Y - cl.Y, pl.Z - 40 - cl.Z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < 1 then return true end
    local cosang = (dx * fwd.X + dy * fwd.Y + dz * fwd.Z) / d
    local tol = math.max(math.rad(LOOK_DEG), math.atan(70 / d))
    if cosang < math.cos(tol) then return false end
    local ok, v = pcall(function() return pc:LineOfSightTo(p, { X = 0, Y = 0, Z = 0 }, false) end)
    return not ok or v == true
end
P.looks_at = looks_at

-- ---------------------------------------------------------------------------
-- The game's timer bar
-- ---------------------------------------------------------------------------

local function game_hud()
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    if ue.valid(hud) then return hud end
    return nil
end

-- The bar: shown / changed at once; its time written at most BAR_EVERY_S,
-- MaxTime only when the widget or the maximum is new.
local function bar(kind, text, cur, max)
    local now = clock()
    if B.kind == kind and B.text == text and now - (B.at or -100) < BAR_EVERY_S then return true end
    local hud = game_hud()
    if not hud then return false end
    local w = ue.prop(hud, "InteractTimerWidget")
    if B.kind ~= kind or B.text ~= text or not ue.valid(w) then
        -- InteractTimerUI(true) makes a new widget every call: the old one off first
        if ue.valid(w) then pcall(function() hud:InteractTimerUI(false, FText("")) end) end
        if not pcall(function() hud:InteractTimerUI(true, FText(text)) end) then return false end
        B.kind, B.text, B.max = kind, text, nil
        w = ue.prop(hud, "InteractTimerWidget")
    end
    B.at = now
    if ue.valid(w) then
        if B.max ~= max then
            ue.set_prop(w, "MaxTime", max)
            B.max = max
        end
        ue.set_prop(w, "CurrentTime", math.max(0, math.min(max, cur)))
    end
    return true
end
P.bar = bar

local function bar_off()
    if not B.kind then return end
    B.kind, B.text, B.max, B.at = nil, nil, nil, nil
    local hud = game_hud()
    if hud then pcall(function() hud:InteractTimerUI(false, FText("")) end) end
end
P.bar_off = bar_off

-- ---------------------------------------------------------------------------
-- Movement and flags
-- ---------------------------------------------------------------------------

local function flags(p, on)
    for _, f in ipairs(D.FLAGS) do
        if f ~= "Attacking?" or not on or O.holstered then ue.set_prop(p, f, on) end
    end
end

local function freeze(pc, p, now)
    now = now or clock()
    if P.frozen and now - (P.freeze_at or -100) < FREEZE_EVERY_S then return end
    P.freeze_at = now
    if ue.try(function() return pc:IsMoveInputIgnored() end) ~= true then
        pcall(function() pc:SetIgnoreMoveInput(true) end)
    end
    local cmc = ue.prop(p, "CharacterMovement")
    if ue.valid(cmc) then
        local falling = ue.try(function() return cmc:IsFalling() end) == true
        if not falling and ue.prop(cmc, "MovementMode") ~= MOVE_NONE then pcall(function() cmc:DisableMovement() end) end
    end
    P.frozen = true
end

local function unfreeze(pc, p)
    P.frozen = false
    if pc then pcall(function() pc:ResetIgnoreMoveInput() end) end
    local cmc = p and ue.prop(p, "CharacterMovement")
    if ue.valid(cmc) then pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end) end
end

local function holstered(p)
    local helper = ue.prop(p, "BP_JigHelperComp")
    local active = ue.str(ue.try(function() return helper.ActiveWeapon.TagName end))
    return active == "" or active == "None"
end

local function close_inventory(p)
    local comp = ue.prop(p, "BP_JigMultiplayer")
    local w = ue.valid(comp) and ue.prop(comp, "InventoryWidgetRef") or nil
    if ue.valid(w) and ue.try(function() return w:IsInViewport() end) == true then
        pcall(function() comp:ToggleInventory() end)
        log.info("[DOWN] the inventory closed (this player is down)")
    end
end

-- ---------------------------------------------------------------------------
-- This machine's own downed player
-- ---------------------------------------------------------------------------

local function left_of(v, now) return math.max(0, (v.left or 0) - (now - (v.at or now))) end
local function prog_of(v, now)
    local p = v.prog or 0
    if next(v.resc or {}) then p = p + (now - (v.at or now)) end
    return math.max(0, math.min(D.C.REVIVE_S, p))
end

local function own_start(me, v, now)
    O = { on = true, id = v.id, paddr = addr(me), since = now, told = {}, gu_released = false, gu_t = nil,
          holstered = false, spot_at = -100 }
    if not holstered(me) then
        pcall(function() me:ServerFuncChangeActiveSlot({ TagName = FName("None") }) end)
    else
        O.holstered = true
    end
    close_inventory(me)
    local _, kname = interact_key()
    log.say("down_you", "warn", 8, math.floor(left_of(v, now)), kname)
    log.info("[DOWN] this player is down (%d s left)", math.floor(left_of(v, now)))
end

local function own_end(why, by)
    local me = ue.local_pawn()
    if me and addr(me) == O.paddr then
        flags(me, false)
        ue.set_prop(me, "Attacking?", false)
        stop_pose(me, true)
    end
    bar_off()
    local id = O.id
    O = { on = false }
    if why == "up" then
        local name = by and D.name_of_id(by) or nil
        if name then log.say("down_up_by", "ok", 6, name) else log.say("down_up", "ok", 5) end
    elseif why == "off" then
        log.say("down_up_off", "info", 6)
    end
    log.info("[DOWN] this player's knockdown ended here (%s; player %s)", tostring(why), tostring(id))
end

local function own_frame(pc, me, v, now)
    if not O.holstered and holstered(me) then O.holstered = true end
    flags(me, true)
    if now - (O.pose_at or -100) >= POSE_EVERY_S then
        O.pose_at = now
        hold_pose(me)
    end
    if now - (O.inv_at or -100) > 0.5 then
        O.inv_at = now
        close_inventory(me)
    end
    -- back to the spot (horizontally; not while falling)
    local sp = v.spot
    if sp and now - O.spot_at >= SPOT_EVERY_S then
        local l = ue.location(me)
        local cmc = ue.prop(me, "CharacterMovement")
        local falling = ue.valid(cmc) and ue.try(function() return cmc:IsFalling() end) == true
        if l and not falling and D.hdist(l, sp) > SPOT_CM then
            O.spot_at = now
            ue.teleport(me, { X = sp.X, Y = sp.Y, Z = sp.Z })
            log.info("[DOWN] this player was %.0f cm from its spot: moved back", D.hdist(l, sp))
        end
    end
    -- give up: a press after going down, held GIVEUP_S
    local down = key_down(pc)
    if not down then
        O.gu_released, O.gu_t = true, nil
    elseif O.gu_released and now - O.since >= 1 and not busy(pc) then
        O.gu_t = O.gu_t or now
        if now - O.gu_t >= D.C.GIVEUP_S and not O.gu_sent then
            O.gu_sent = true
            D.give_up()
        end
    else
        O.gu_t = nil
    end
    -- the bar
    local left = left_of(v, now)
    if O.gu_t then
        bar("giveup", tr("down_bar_giveup"), now - O.gu_t, D.C.GIVEUP_S)
    elseif next(v.resc or {}) or (v.prog or 0) > 0 then
        bar("being", tr("down_bar_being"), prog_of(v, now), D.C.REVIVE_S)
    else
        bar("bleed", tr("down_bar_bleed"), left, v.bleed_s or D.C.BLEED_S)
    end
    for _, at in ipairs(D.C.NOTICE_AT) do
        if left <= at and left > at - 5 and not O.told[at] and now - O.since > 2 then
            O.told[at] = true
            log.say("down_left", "warn", 5, at)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Rescuer
-- ---------------------------------------------------------------------------

local function stop_rescue(me)
    if not R then return end
    D.hold(R.id, false)
    local m = montages[LOOT]
    if me and m and ue.valid(m) then
        if playing(me, m) then pcall(function() me:StopAnimMontage(m) end) end
        pcall(function() me:StopMontage(m, false) end)
    end
    if B.kind == "reviving" then bar_off() end
    log.info("[DOWN] this player stopped reviving player %s (%.1f s)", tostring(R.id), clock() - R.since)
    R = nil
end

-- The downed player this machine's player looks at from close enough, or nil
-- (camera, distance, line of sight: AIM_EVERY_S, not every frame).
local function aim(pc, me, views)
    if dead(me) or D.in_vehicle(me) or busy(pc) then return nil end
    local cl, fwd = camera_view(pc)
    local ml = ue.location(me)
    if not (cl and ml) then return nil end
    for _, id in ipairs(near) do
        local p = views[id] and char_by_id(id)
        local pl = p and ue.location(p)
        local lim = (R and R.id == id) and D.C.REVIVE_KEEP_CM or D.C.REVIVE_START_CM
        if pl and D.dist(ml, pl) <= lim and looks_at(pc, p, pl, cl, fwd) then return id end
    end
    return nil
end

local function rescue_frame(pc, me, views, now)
    local target = nil
    if not O.on and #near > 0 then
        if now - A.at >= AIM_EVERY_S then
            A.at, A.id = now, aim(pc, me, views)
        end
        -- the one looked at got up / died since: at once
        if A.id ~= nil and views[A.id] == nil then A.id = nil end
        target = A.id
    else
        A.id = nil
    end
    local held = target ~= nil and key_down(pc)
    if target and held then
        if R and R.id ~= target then stop_rescue(me) end
        if not R then
            R = { id = target, since = now, anim_at = -100, name = D.name_of_id(target) or tr("down_mate") }
            D.hold(target, true)
            log.info("[DOWN] this player revives player %s", tostring(target))
        end
        if now - R.anim_at >= ANIM_EVERY_S then
            R.anim_at = now
            local m = montage(LOOT)
            if m and not playing(me, m) then pcall(function() me:PlayMontage(m, 1.0) end) end
        end
        local v = views[target]
        bar("reviving", tr("down_bar_reviving", R.name), v and prog_of(v, now) or 0, D.C.REVIVE_S)
    else
        if R then stop_rescue(me) end
        if target and not held and now - (hint_at[target] or -100) >= HINT_EVERY_S then
            hint_at[target] = now
            local _, kname = interact_key()
            log.say("down_hint", "info", 4, kname, D.name_of_id(target) or tr("down_mate"))
        end
    end
    return target
end

-- ---------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------

local function release_copy(p, c)
    stop_pose(p, false)
    local mesh = ue.prop(p, "Mesh")
    if c.tickpose ~= nil and ue.valid(mesh) and remote_controlled(p) then
        ue.set_prop(mesh, "bOnlyAllowAutonomousTickPose", c.tickpose)
    end
    if c.cap ~= nil then
        local cap = ue.prop(p, "CapsuleComponent")
        if ue.valid(cap) then pcall(function() cap:SetCollisionResponseToChannel(2, c.cap) end) end
    end
end

-- Every 250 ms (sdc_down.tick): the pose on the downed copies here, who is
-- near, whether the frame has work.
function P.tick(now)
    now = now or clock()
    local role = S and S.role
    if role ~= "host" and role ~= "client" then
        P.want_frame = O.on or T.freeze or P.frozen or B.kind ~= nil
        return
    end
    local views = D.views()
    local my = D.my_id()
    P.my = my                 -- the frame's copy (PlayerId does not change in a world)
    local me = ue.local_pawn()
    local ml = me and ue.location(me)
    local seen = {}
    local nb = {}
    for id, v in pairs(views) do
        if id ~= my then
            local p = char_by_id(id)
            local a = p and addr(p)
            if a then
                seen[a] = true
                local c = copies[a]
                if not c then
                    c = { id = id, name = ue.short(p) }
                    copies[a] = c
                    log.info("[DOWN] player %s's character shown down here", tostring(id))
                end
                hold_pose(p)
                local mesh = ue.prop(p, "Mesh")
                if role == "host" and remote_controlled(p) and ue.valid(mesh)
                    and ue.prop(mesh, "bOnlyAllowAutonomousTickPose") == true then
                    if c.tickpose == nil then c.tickpose = true end
                    ue.set_prop(mesh, "bOnlyAllowAutonomousTickPose", false)
                end
                if T.capsule_use and c.cap == nil then
                    local cap = ue.prop(p, "CapsuleComponent")
                    local was = ue.valid(cap) and ue.try(function() return cap:GetCollisionResponseToChannel(2) end)
                    if type(was) == "number" then
                        c.cap = was
                        pcall(function() cap:SetCollisionResponseToChannel(2, 0) end)
                    end
                end
                local pl = ue.location(p)
                if ml and pl and D.dist(ml, pl) <= D.C.NEAR_CM then nb[#nb + 1] = id end
            end
        end
    end
    for a, c in pairs(copies) do
        if not seen[a] then
            copies[a] = nil
            for _, p in ipairs(ue.player_chars() or {}) do
                if ue.valid(p) and addr(p) == a and ue.short(p) == c.name then release_copy(p, c) end
            end
            log.info("[DOWN] player %s's character no longer shown down here", tostring(c.id))
        end
    end
    -- sdcoop_down pose: the pose on a character here (test)
    for a in pairs(T.pose) do
        for _, p in ipairs(ue.player_chars() or {}) do
            if ue.valid(p) and addr(p) == a then hold_pose(p) end
        end
    end
    near = nb
    P.want_frame = (my ~= nil and views[my] ~= nil) or O.on or #near > 0 or R ~= nil or B.kind ~= nil or T.freeze
        or P.frozen
end

-- Every frame while want_frame (main.lua via sdc_down.frame_tick).
function P.frame_tick()
    local now = clock()
    local pc = ue.local_pc()
    local me = pc and ue.pawn_of(pc) or nil
    if not pc or not me then
        if O.on then own_end("gone") end
        if R then R = nil end
        A.id = nil
        bar_off()
        P.frozen = false
        return
    end
    local views = D.views()
    local my = P.my or D.my_id()
    local v = my and views[my] or nil
    -- the own character died or is another one: freed here at once (the
    -- host's record closes by its own binding check)
    if v and (dead(me) or (v.paddr ~= nil and v.paddr ~= addr(me))) then v = nil end
    if O.on and (O.paddr ~= addr(me) or dead(me)) then own_end("dead") end
    if v then
        if not O.on then own_start(me, v, now) end
        own_frame(pc, me, v, now)
    elseif O.on then
        local e = D.last_end[O.id] or {}
        own_end(e.why or "up", e.by)
    end
    rescue_frame(pc, me, views, now)
    if not O.on and not R and B.kind then bar_off() end
    if O.on or R or T.freeze then
        freeze(pc, me, now)
    elseif P.frozen then
        unfreeze(pc, me)
    end
    if T.freeze then flags(me, true) end
end

-- A role change in the same world (sdc_down.tick): this machine's own
-- player and the copies here freed with the live objects, before P.reset.
function P.release(why)
    local pc, me = ue.local_pc(), ue.local_pawn()
    if O.on then own_end(why or "off") end
    if R then stop_rescue(me) end
    bar_off()
    if P.frozen then unfreeze(pc, me) end
    for a, c in pairs(copies) do
        for _, p in ipairs(ue.player_chars() or {}) do
            if ue.valid(p) and addr(p) == a and ue.short(p) == c.name then release_copy(p, c) end
        end
    end
    copies = {}
end

-- World / role change: the controller and its characters go with the old
-- world (nothing touched).
function P.reset(why)
    O, R, B, A = { on = false }, nil, { kind = nil }, { at = -100, id = nil }
    copies, near, hint_at = {}, {}, {}
    montages = { tried = {} }
    T.freeze, T.pose = false, {}
    P.frozen, P.want_frame, P.my, P.freeze_at = false, false, nil, nil
end

-- sdcoop_down freeze on / off (this machine's own player, test).
function P.test_freeze(on)
    T.freeze = on == true
    if not on then
        local me = ue.local_pawn()
        if me and not O.on then flags(me, false) end
    end
    P.want_frame = true
end
-- sdcoop_down pose <who> on / off (test).
function P.test_pose(p, on)
    local a = addr(p)
    if not a then return false end
    if on then T.pose[a] = true else
        T.pose[a] = nil
        stop_pose(p, false)
    end
    return true
end
function P.capsule_use(on) T.capsule_use = on == true end

function P.install(state, down)
    S, D = state, down
end

function P.status()
    local n = 0
    for _ in pairs(copies) do n = n + 1 end
    return string.format("own=%s rescuing=%s bar=%s copies=%d near=%d frozen=%s key=%s", tostring(O.on),
        tostring(R and R.id), tostring(B.kind), n, #near, tostring(P.frozen), tostring(K.name))
end

-- tests
P._t = { own_start = own_start, own_end = own_end, rescue_frame = rescue_frame, near = function() return near end,
         R = function() return R end, B = function() return B end, copies = function() return copies end,
         K = function() return K end }

return P
