-- SDCoop: player state the game keeps on one machine only.
--
-- Some state of a character lives only on its owner's machine (local Blueprint
-- variables) or is sent once by a multicast that late joiners never get. The
-- owner publishes it (client -> host: MYSTATE, host -> everyone: PSTATE) and
-- every other machine applies it to its copy.
--
-- Why it matters:
--   * speed: MC_UpdateWeaponSpeed runs on every machine and picks MaxWalkSpeed
--     from HoldingFirearm? / IsADS? / Sprinting? (250 / 650 / 350), then
--     multicasts it through Svr_UpdateSpeed -> MC_UpdateSpeed to everyone,
--     the owner included. The host's copy had stale flags, so host and owner
--     kept overwriting each other's speed (jitter, slow run on the host).
--   * animation: HoldingFirearm?, HipFire?, Lean and the anim instance's
--     BlendSpaceInt (set by MC_UpdateCombatState) drive the weapon pose.
--   * the left hand IK target (LeftHandLoc) is computed only for the own
--     character; other characters get it computed here every frame.
--
--   * head turn: the anim BP turns the head by (actor yaw - control yaw); a
--     client's copy of the host has no controller, so the host's head never
--     turned there. The owner sends that difference, clients write the anim
--     instance's HeadRotation every frame.
--   * flashlight: the game switches it with MC_Flashlight -> FlashlightToggle
--     on every machine, but that multicast is UNRELIABLE and late joiners
--     never get it. `fl` is whether the owner's light is really on; another
--     machine whose copy disagrees runs the game's own FlashlightToggle.
--   * aim for other players' lasers: not sent. sdc_gearfx uses
--     GetBaseAimRotation (replicated RemoteViewPitch + actor yaw; the
--     character turns with the aim while aiming).
--
--   * weapon pose (work/audit/weapon_pose.md). The anim BP picks the pose by
--     BlendSpaceInt (0 nothing in hand, 1 rifle, 2 sidearm, 3 one-handed
--     melee, 4 two-handed melee, 5 fishing rod); the aiming poses hang under
--     the same index, so with 0 a weapon is held like nothing and aiming
--     raises nothing. The owner's equip / holster notify calls
--     SERVER_ChangeActiveSlot and right away reads the active slot to choose
--     Svr_UpdateCombatState(AnimBlendspace or 0) (BP_PlayerCharacter@75642,
--     @125573, @132221, @145436). On the host the server RPC has already run;
--     on a client it has not, so a client sends 0 when it draws a weapon (and
--     the weapon's pose when it puts it away), and the host multicasts that
--     to everyone, the client itself included. The host re-derives the value
--     from its own (authoritative) active slot - what single player computes
--     - and corrects it with the game's reliable MC_UpdateCombatState.
--     `bs` from a client is therefore not applied on the host; the host
--     forwards its own value to the other clients (late-join snapshot).
--   * melee aim: InMeleeStance? (replicated, skip owner) is set only on the
--     owner (BP_PlayerCharacter@1424 / @1700); no RPC takes it to the server,
--     so nobody else ever saw a client's melee aim stance. IsADS? has
--     Svr_SetADS, but that one is unreliable. The owner sends both (ads, ms);
--     the host sets them on its copy the way the game does on the server
--     (FlushNetDormancy, flag, MarkPropertyDirtyFromRepIndex 26 / 27) and
--     replication takes them to the other players. Clients do not apply them.
--
-- Fields: fl flashlight lit, hf HoldingFirearm?, hm HoldingMelee?, sp Sprinting?,
--         cs CrouchSprinting?, hip HipFire?, ln Lean, bs BlendSpaceInt,
--         hy head yaw (degrees, 4-degree steps), ads IsADS? / ms InMeleeStance? (host only)
--
-- Wire format (traffic, 0.12.2): the flags are ONE bitmask number, the rest
-- short numbers; an empty field = "not sent, keep what you have":
--     MYSTATE|mask|bs|ln|hy            client -> host
--     PSTATE|player id|mask|bs|ln|hy   host -> client
--   mask bits: fl 1, hf 2, hm 4, sp 8, cs 16, hip 32, ads 64, ms 128,
--   hc 256 (PSTATE only: this is the host's own character); ln = Lean
--   (the game sets 45 / -65 / 0 on the Q / E input, so a whole number) and
--   hy = head yaw in steps of 4 degrees (-15..15), both as small signed integers.
-- Who needs what:
--   * CORE (mask, bs, ln): the host's own logic needs the flags (speed from
--     HoldingFirearm? / IsADS? / Sprinting?, the replicated ads / ms, the pose
--     check) and other machines' copies need them too (speed, flashlight
--     backstop, late-joiner pose): always sent, on change only. Lean (ln) is core:
--     it is a plain local variable the owner sets on its input, nothing
--     replicates it, and the host's copy of the client needs it for the anim BP
--     (it changes only on a key press: rare and tiny).
--   * VISUAL (hy): head turn is animation only. The host does
--     not use it (its anim BP turns the heads by itself), so it matters only
--     to other CLIENTS that can see the character: a client sends it only
--     while another client's character is within VIS_CM of it (the host does
--     not count as a viewer), and the host relays / sends them only to the
--     clients within VIS_CM of the character. A client that comes into range
--     gets the full current state at once. A message to somebody in range
--     always carries every field (a queue that keeps only the newest message
--     per peer, sdc_net, must not lose a head angle); only messages to peers
--     out of range leave hy empty.
--   * at most 4 visual updates a second (HY_MIN_INTERVAL), head in 4-degree
--     steps; the receiving side eases the head towards the value.

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local cfg = require("sdc_config")
local appearance = require("sdc_appearance")
local items = require("sdc_items")

local M = {}
local S
function M.init(state) S = state end

local addr = ctx.addr

local BOOLS = {
    { "hf", "HoldingFirearm?" }, { "hm", "HoldingMelee?" },
    { "sp", "Sprinting?" }, { "cs", "CrouchSprinting?" }, { "hip", "HipFire?" },
}
-- Replicated (skip owner) flags the owner sets only on its own machine: the
-- host writes them on its copy, replication does the rest. [3] = the rep
-- index the game passes to MarkPropertyDirtyFromRepIndex.
local HOST_BOOLS = {
    { "ads", "IsADS?", 26 }, { "ms", "InMeleeStance?", 27 },
}

-- Config weapon_pose_fix (default on, also when the key is unknown).
local function pose_fix_on() return cfg.get("weapon_pose_fix") ~= false end

-- The character's own spot light ("Flashlight" component) is lit.
local function light_on(pawn)
    local i = ue.prop(ue.prop(pawn, "Flashlight"), "Intensity")
    return type(i) == "number" and i > 0
end

local function anim_of(pawn)
    local mesh = ue.prop(pawn, "Mesh")
    if not ue.valid(mesh) then return nil end
    return ue.try(function() return mesh:GetAnimInstance() end)
end

local function norm180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- head yaw in steps of HY_STEP degrees, lean in whole numbers: small moves do not resend
local HY_STEP = 4
local function step_hy(v) return math.floor(v / HY_STEP + 0.5) * HY_STEP end
local function step_ln(v) return math.floor(v + 0.5) end

-- Relevance (see the header). Hysteresis: in at VIS_CM, out at VIS_STAY_CM.
local VIS_CM = 6000            -- 60 m: head detail
local VIS_STAY_CM = 7000
local VIS_CHECK = 0.5          -- s between range checks
local HY_MIN_INTERVAL = 0.25   -- s between visual updates (4 / s)
M.VIS_CM, M.HY_MIN_INTERVAL = VIS_CM, HY_MIN_INTERVAL

-- Own state as decoded strings (the same shape as states[id]).
local function own_state(pawn)
    local t = { fl = light_on(pawn) and "1" or "0" }
    for _, b in ipairs(BOOLS) do
        t[b[1]] = ue.prop(pawn, b[2]) == true and "1" or "0"
    end
    for _, b in ipairs(HOST_BOOLS) do
        t[b[1]] = ue.prop(pawn, b[2]) == true and "1" or "0"
    end
    local lean = ue.prop(pawn, "Lean")
    t.ln = string.format("%.2f", step_ln(type(lean) == "number" and lean or 0) + 0)
    local bs = ue.prop(anim_of(pawn), "BlendSpaceInt")
    t.bs = tostring(type(bs) == "number" and math.floor(bs) or 0)
    local pc = ue.local_pc()
    local cr = pc and ue.try(function() return pc:GetControlRotation() end)
    local ar = ue.rotation(pawn)
    if cr and ar then
        local cy = ue.try(function() return cr.Yaw end)
        if type(cy) == "number" then
            local hy = math.max(-60, math.min(60, norm180(ar.Yaw - cy)))
            t.hy = string.format("%d", step_hy(hy))
        end
    end
    return t
end

-- Flag bits of the wire mask.
local BITS = {
    { "fl", 1 }, { "hf", 2 }, { "hm", 4 }, { "sp", 8 }, { "cs", 16 },
    { "hip", 32 }, { "ads", 64 }, { "ms", 128 }, { "hc", 256 },
}
local function mask_of(t)
    local m = 0
    for _, b in ipairs(BITS) do
        if t[b[1]] == "1" then m = m + b[2] end
    end
    return m
end

-- { mask, bs, ln, hy } as strings; hy "" without `vis` (or unknown).
local function wire_of(t, vis)
    local ln = tonumber(t.ln)
    local hy = vis and tonumber(t.hy)
    return {
        tostring(mask_of(t)), tostring(math.floor(tonumber(t.bs) or 0)),
        ln and tostring(math.floor(ln + 0.5)) or "",
        hy and tostring(math.floor(hy / HY_STEP + 0.5)) or "",
    }
end

-- Merge the wire fields f[i .. i+3] into the decoded state t (an empty field
-- keeps what t has). false = not a state.
local function merge_wire(t, f, i)
    local mask = tonumber(f[i])
    if not mask then return false end
    mask = math.floor(mask)
    for _, b in ipairs(BITS) do
        t[b[1]] = (mask % (b[2] * 2) >= b[2]) and "1" or "0"
    end
    local bs = tonumber(f[i + 1])
    if bs then t.bs = tostring(math.floor(bs)) end
    local ln = tonumber(f[i + 2])
    if ln then t.ln = string.format("%.2f", ln) end
    local hy = tonumber(f[i + 3])
    if hy then t.hy = tostring(math.floor(hy) * HY_STEP) end
    return true
end

local function copy_state(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function dist2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local states = {}    -- [player id] = decoded state
local published = nil    -- own state as last published (decoded)
local pub_vis_at = 0      -- when its visual part last went out
local pub_vis_sent = false  -- client: the last message carried the visual part
local near_on, near_at = false, -1e9      -- client: a client that can see us is near
local host_cid = nil      -- client: player id of the host's character (not a viewer)
-- host: who is in whose visual range, and what each client was last sent
local inr = {}            -- [viewer pc address][subject player id] = true / false
local ranges_at = -1e9
local sent_core, sent_full = {}, {}   -- [pc address][player id] = key

local function m_is_local(p) return p:IsLocallyControlled() end
local function is_local(p)
    local ok, v = pcall(m_is_local, p)
    return ok and v == true
end

-- Characters of other players on this machine (not the hidden stale local copy
-- a client may have from its own save), from the character list shared with
-- the other modules (sdc_ue.player_chars: rescanned when a new character
-- appears, else at most every second, destroyed ones left out). `fresh` = a
-- message handler: a new scan unless that list is known to be fresh.
-- Shared: sdc_gearfx (other players' lights / lasers).
local function others(fresh)
    local out = {}
    local host = S.role == "host"
    for _, p in ipairs(ue.player_chars(fresh) or {}) do
        -- find_all can return a character that is already being destroyed
        -- (e.g. the host's copy leaving a client's network range)
        if ue.valid(p) then
            if host then
                if not is_local(p) then out[#out + 1] = p end
            elseif ue.role(p) == ue.ROLE_SIMULATED then
                -- a simulated proxy is never locally controlled (no controller here)
                out[#out + 1] = p
            end
        end
    end
    return out
end
M.others = others

-- ---------------------------------------------------------------------------
-- Other players' characters: what is looked up once, not every frame
-- ---------------------------------------------------------------------------
-- [pawn address] = { p = pawn, k = address, w = held weapon (held_weapon),
-- mesh, anim, id, IK fields (frame section) }. Refreshed every REFRESH s by the
-- frame tick; a character no longer listed loses its record.
local recs = {}
local FN_LEFT, FN_HAND = nil, nil
local function fnames()
    if not FN_LEFT then FN_LEFT, FN_HAND = FName("LeftHand"), FName("Hand_R") end
end

local function rec_of(p, k)
    k = k or addr(p)
    if not k then return nil end
    local r = recs[k]
    if not r then
        r = { k = k }
        recs[k] = r
    end
    r.p = p
    return r
end

-- Held weapon: the RepActorsData walk (sdc_items.equipped_of, ~60 engine
-- calls, the biggest part of the old 0.25 s refresh and 0.5 s pose sweep)
-- only when the active slot changed, the cached actor is gone or its root is
-- no longer attached where it was (a destroyed actor is detached), or after
-- WEAPON_RECHECK s; otherwise ~6 reads.
local WEAPON_RECHECK = 10        -- s
local WEAPON_RECHECK_BLIND = 1   -- s: when the root's attachment cannot be read
local function m_active_tag(helper) return helper.ActiveWeapon.TagName end
local function m_has_socket(root, name) return root:DoesSocketExist(name) end

-- Address of the component a weapon's root is attached to, false = none / unreadable.
local function attach_key(root)
    local parent = ue.prop(root, "AttachParent")
    if not ue.valid(parent) then return false end
    return addr(parent) or false
end

-- The weapon in the character's active slot: w = { tag, actor, ak (its
-- address), root, parent (attach_key at lookup), left (root has a LeftHand
-- socket, nil = not asked yet) } or nil, and the active slot tag ("" = cannot
-- tell, "None" = nothing in hand). `fresh` forces the walk.
local function held_weapon(p, r, now, fresh)
    local helper = ue.prop(p, "BP_JigHelperComp")
    if not ue.valid(helper) then return nil, "" end
    local tag = ue.str(ue.try(m_active_tag, helper))
    if tag == "" then return nil, tag end
    if tag == "None" then
        r.w = nil
        return nil, tag
    end
    local w = r.w
    if w and not fresh and w.tag == tag and now >= w.at
        and now - w.at < (w.parent == false and WEAPON_RECHECK_BLIND or WEAPON_RECHECK)
        and ue.valid(w.actor)
        and (w.root == nil or (ue.valid(w.root) and attach_key(w.root) == w.parent)) then
        return w, tag
    end
    local actor = nil
    for _, it in pairs(items.equipped_of(p)) do
        if it.slot == tag then actor = it.actor break end
    end
    if not ue.valid(actor) then
        r.w = nil
        return nil, tag
    end
    local ak = addr(actor)
    if not (w and w.tag == tag and w.ak == ak) then
        local root = ue.prop(actor, "RootComponent")
        w = { tag = tag, ak = ak, root = ue.valid(root) and root or nil }
    end
    w.actor, w.at = actor, now
    w.parent = w.root and attach_key(w.root) or false
    r.w = w
    return w, tag
end

-- Flashlight backstop: at most one game toggle per character every FL_RETRY s
-- (a toggle that cannot succeed here - item actor not arrived yet, no battery
-- on the host - is not repeated every second).
local FL_RETRY = 3
local FL_DIRECT_AFTER = 10   -- s of the game's toggle failing before the direct light
local fl_tried = {}     -- [pawn address] = os.clock() of the last backstop toggle
local fl_failing = {}   -- [pawn address] = os.clock() since the game's toggle keeps failing
local fl_logged = 0

-- Direct light: last-resort safety net, when the game's FlashlightToggle
-- could not light another player's copy here. FlashlightToggle starts with
-- GetEquippedActorBySlot(Flashlight) (BP_PlayerCharacter.FlashlightToggle@14)
-- and returns when that copy has no flashlight item actor on this machine.
-- The item is hidden and unattached by the game, so it used to reach only its
-- owner (hidden actors are not net-relevant to others); sdc_items now makes
-- worn items relevant with their owner, so this should not trigger once the
-- item has arrived. Same values the game sets (@601-756): the item's
-- FlashlightIntensity / FlashlightMaterial, attenuation 16384.
local FL_SLOT = "Jig.PlayerSlot.Flashlight"
local FL_DA = {
    BP_FlashlightPickup_C = "/Game/Inventory/Items/DataAssets/Equipment/Flashlight/DA_Flashlight.DA_Flashlight",
    BP_HighPoweredFlashlightPickup_C = "/Game/Inventory/Items/DataAssets/Equipment/Flashlight/DA_HighPoweredFlashlight.DA_HighPoweredFlashlight",
}
local fl_da_cache = {}
local function load_fl_da(path)
    local da = fl_da_cache[path]
    if ue.valid(da) then return da end
    da = ue.find_object(path)
    if not ue.valid(da) then
        local ok, loaded = ue.load_asset(path, "pawnstate")
        da = ok and ue.valid(loaded) and loaded or nil
    end
    fl_da_cache[path] = da
    return da
end

-- The flashlight item actor of a character on this machine (the replicated
-- RepActorsData entry the game's GetEquippedActorBySlot reads), or nil.
local function flashlight_item(pawn)
    for _, it in pairs(items.equipped_of(pawn)) do
        if it.slot == FL_SLOT then return it.actor end
    end
    return nil
end

local function flashlight_data(pawn)
    local a = flashlight_item(pawn)
    if a then
        local da = ue.prop(a, "ItemDataAsset")
        if not ue.valid(da) then da = ue.try(function() return a.BP_JigPickupComponent.ItemDataAsset end) end
        if ue.valid(da) then return da end
        local path = FL_DA[ue.class_name(a)]
        if path then return load_fl_da(path) end
    end
    return load_fl_da(FL_DA.BP_FlashlightPickup_C)
end

local function light_directly(pawn, want)
    local light = ue.prop(pawn, "Flashlight")
    if not ue.valid(light) then return false end
    if not want then
        pcall(function() light:SetIntensity(0) end)
        pcall(function() light:SetAttenuationRadius(0) end)
        return true
    end
    local da = flashlight_data(pawn)
    local intensity = da and tonumber(ue.prop(da, "FlashlightIntensity")) or nil
    if not intensity or intensity <= 0 then return false end
    local mat = da and ue.prop(da, "FlashlightMaterial")
    if ue.valid(mat) then pcall(function() light:SetLightFunctionMaterial(mat) end) end
    pcall(function() light:SetIntensity(intensity) end)
    pcall(function() light:SetAttenuationRadius(16384) end)
    return true
end

local function apply_flashlight(pawn, want)
    local k = addr(pawn)
    if light_on(pawn) == want then
        if k then fl_failing[k] = nil end
        return
    end
    local now = os.clock()
    if k and fl_tried[k] and now - fl_tried[k] < FL_RETRY then return end
    if k then fl_tried[k] = now end
    -- as MC_Flashlight does: the flag, then the game's own switch
    ue.set_prop(pawn, "FlashlightOn?", want)
    local ok, err = pcall(function() pawn:FlashlightToggle(want) end)
    local direct = nil
    if light_on(pawn) ~= want then
        -- the game's path gets FL_DIRECT_AFTER s (the item actor can arrive a
        -- moment after the character) before the safety net takes over
        local since = k and fl_failing[k] or now
        if k then fl_failing[k] = since end
        if now - since >= FL_DIRECT_AFTER then direct = light_directly(pawn, want) end
    elseif k then
        fl_failing[k] = nil
    end
    fl_logged = fl_logged + 1
    local item = flashlight_item(pawn)
    local line = string.format("state: flashlight of %s %s by the backstop (item %s, FlashlightToggle ok=%s%s%s, lit now %s)",
        ue.short(pawn), want and "on" or "off", item and ue.short(item) or "not here", tostring(ok),
        ok and "" or (" " .. tostring(err)), direct == nil and "" or (", direct light " .. tostring(direct)),
        tostring(light_on(pawn)))
    -- the safety net doing the game's job is always worth a line
    if fl_logged <= 5 or direct then log.info("%s", line) else log.debug("%s", line) end
end

-- ---------------------------------------------------------------------------
-- Weapon pose of other players' characters (host): the combat state
-- ---------------------------------------------------------------------------
-- See the header. The host knows the truth (the server has run
-- SERVER_ChangeActiveSlot) and fixes what a client's racy read multicast.
local COMBAT_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:UpdateCombatState"
local COMBAT_MAX_PER_S = 6  -- corrections per character and second (each weapon
                            -- swap needs one, an equip montage takes ~0.5 s;
                            -- a runaway loop is capped)
local COMBAT_SWEEP = 0.5    -- s between checks of every remote character (backstop)
local combat_hook = { done = false, next_try = 0, fails = 0 }
local combat_last = {}      -- [pawn address] = value the game last applied here (hook)
local combat_dirty = {}     -- [pawn address] = true: UpdateCombatState ran, check next frame
local combat_sent = {}      -- [pawn address] = { at = window start, n = corrections in it }
local combat_sweep_at = 0
local remote_list = {}      -- host: other players' characters, refreshed with ik_list
M.combat_stats = { fixed_all = 0, fixed_here = 0, hook_calls = 0 }

-- The blend space single player picks for this character's active slot: the
-- equipped actor's BP_EquipmentPickupComponent.AnimBlendspace, 0 with nothing
-- in hand (BP_PlayerCharacter@145254-145436, read after the slot changed).
-- Returns value, slot tag; value nil = cannot tell (leave it alone).
-- The held weapon comes from the per-character cache (held_weapon).
local function expected_bs(pawn)
    local r = rec_of(pawn)
    if not r then return nil, nil end
    local w, tag = held_weapon(pawn, r, os.clock())
    if tag == "" then return nil, nil end
    if tag == "None" then return 0, tag end
    -- active slot without its item actor (yet): unknown
    if not w then return nil, tag end
    local comp = ue.prop(w.actor, "BP_EquipmentPickupComponent")
    local v = ue.valid(comp) and ue.prop(comp, "AnimBlendspace") or nil
    if type(v) == "number" then return math.floor(v), tag end
    return nil, tag
end
M.expected_bs = expected_bs

-- Post-hook of BP_PlayerCharacter.UpdateCombatState on the host (it runs in
-- every MC_UpdateCombatState and sets the anim BP's BlendSpaceInt): remember
-- the value and check the character next frame. Nothing is called from here.
local function on_combat_state(c, bs_param)
    if S.role ~= "host" then return end
    local p = c and c:get()
    if not ue.valid(p) or is_local(p) then return end
    local k = addr(p)
    if not k then return end
    M.combat_stats.hook_calls = M.combat_stats.hook_calls + 1
    local v = bs_param and bs_param:get()
    if type(v) == "number" then combat_last[k] = math.floor(v) end
    combat_dirty[k] = true
end

local function ensure_combat_hook(now)
    if combat_hook.done or now < combat_hook.next_try then return end
    combat_hook.next_try = now + 10
    -- the function exists once the character class is loaded
    if not ue.find_object(COMBAT_FN) then return end
    local ok, err = pcall(RegisterHook, COMBAT_FN, function(c, bs_param)
        local okc, e = pcall(on_combat_state, c, bs_param)
        if not okc then log.err_throttled("state-combat-hook", "state: combat state hook: %s", tostring(e)) end
    end)
    combat_hook.done = ok
    if ok or combat_hook.fails < 3 then
        log.info("state: combat state hook (UpdateCombatState) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    if not ok then combat_hook.fails = combat_hook.fails + 1 end
end

local function combat_log(line)
    local n = M.combat_stats.fixed_all + M.combat_stats.fixed_here
    if n <= 20 or n % 50 == 0 then log.info("%s", line) else log.debug("%s", line) end
end

-- One remote character: correct its combat state when it is not what its
-- active slot says.
--   the game's last value is wrong -> the wrong value went to every machine:
--       the game's own reliable MC_UpdateCombatState(right value)
--   only this machine's anim BP differs (anim instance re-created) ->
--       UpdateCombatState(right value) here only
local function check_combat(p, now)
    if ue.prop(p, "PlayerDead?") == true then return end
    local want, slot = expected_bs(p)
    if want == nil then return end
    local k = addr(p)
    if not k then return end
    local last = combat_last[k]
    local cur = ue.prop(anim_of(p), "BlendSpaceInt")
    cur = type(cur) == "number" and math.floor(cur) or nil
    local everyone
    if last ~= nil then
        if last ~= want then everyone = true
        elseif cur ~= nil and cur ~= want then everyone = false
        else return end
    else
        -- no hook data (hook not in yet): judge by the anim BP
        if cur == nil or cur == want then return end
        everyone = true
    end
    local s = combat_sent[k]
    if not s or now - s.at >= 1.0 then
        s = { at = now, n = 0 }
        combat_sent[k] = s
    end
    if s.n >= COMBAT_MAX_PER_S then return end
    s.n = s.n + 1
    local ok, err
    if everyone then
        ok, err = pcall(function() p:MC_UpdateCombatState(want) end)
        M.combat_stats.fixed_all = M.combat_stats.fixed_all + 1
    else
        ok, err = pcall(function() p:UpdateCombatState(want) end)
        M.combat_stats.fixed_here = M.combat_stats.fixed_here + 1
    end
    combat_log(string.format("state: combat state of %s %s -> %d (active slot %s) %s, ok=%s%s",
        ue.short(p), tostring(everyone and last or cur), want, tostring(slot),
        everyone and "multicast (MC_UpdateCombatState): the owner read its slot before the server changed it"
            or "here only (anim BP was reset)",
        tostring(ok), ok and "" or (" " .. tostring(err))))
end

-- Every frame on the host: characters the hook flagged, and every
-- COMBAT_SWEEP s all of them (a correction the hook missed, a reliable slot
-- change processed after the combat state RPC).
local function combat_frame(now)
    if not pose_fix_on() then
        combat_dirty = {}
        return
    end
    local sweep = now - combat_sweep_at >= COMBAT_SWEEP
    if not sweep and next(combat_dirty) == nil then return end
    if sweep then combat_sweep_at = now end
    local dirty = combat_dirty
    combat_dirty = {}
    for _, p in ipairs(remote_list) do
        -- cached for a fraction of a second: re-check before touching it
        if ue.valid(p) and (sweep or dirty[addr(p)]) then
            local ok, err = pcall(check_combat, p, now)
            if not ok then log.err_throttled("state-combat", "state: combat state check: %s", tostring(err)) end
        end
    end
end

-- Host: IsADS? / InMeleeStance? of a client's character from its owner, set
-- the way the game sets them on the server (@10217-10246, @1700-1721).
local push_obj = nil
local function mark_dirty(pawn, rep, name)
    if not ue.valid(push_obj) then push_obj = ue.find_object("/Script/Engine.Default__NetPushModelHelpers") end
    if push_obj then pcall(function() push_obj:MarkPropertyDirtyFromRepIndex(pawn, rep, FName(name)) end) end
end

local flags_logged = 0
local function apply_host_flags(pawn, t)
    for _, b in ipairs(HOST_BOOLS) do
        local v = t[b[1]]
        if v ~= nil then
            local want = v == "1"
            if (ue.prop(pawn, b[2]) == true) ~= want then
                pcall(function() pawn:FlushNetDormancy() end)
                local ok = ue.set_prop(pawn, b[2], want)
                mark_dirty(pawn, b[3], b[2])
                flags_logged = flags_logged + 1
                local line = string.format("state: %s of %s -> %s from its owner (ok=%s)", b[2], ue.short(pawn),
                    tostring(want), tostring(ok))
                if flags_logged <= 10 then log.info("%s", line) else log.debug("%s", line) end
            end
        end
    end
end

local function apply(pawn, t)
    for _, b in ipairs(BOOLS) do
        local v = t[b[1]]
        if v ~= nil then
            local want = v == "1"
            if (ue.prop(pawn, b[2]) == true) ~= want then ue.set_prop(pawn, b[2], want) end
        end
    end
    local ln = tonumber(t.ln)
    if ln then
        local cur = ue.prop(pawn, "Lean")
        if type(cur) ~= "number" or math.abs(cur - ln) > 0.01 then ue.set_prop(pawn, "Lean", ln) end
    end
    local host_decides = S.role == "host" and pose_fix_on()
    if host_decides then
        apply_host_flags(pawn, t)
    else
        -- clients: the combat state of characters whose multicast they missed
        -- (joined later, out of range at the time)
        local bs = tonumber(t.bs)
        if bs then
            local cur = ue.prop(anim_of(pawn), "BlendSpaceInt")
            if cur ~= bs then
                local ok = pcall(function() pawn:UpdateCombatState(bs) end)
                log.debug("state: combat state of %s -> %d (ok=%s)", ue.short(pawn), bs, tostring(ok))
            end
        end
    end
    if t.fl then apply_flashlight(pawn, t.fl == "1") end
end

-- Published state of another player's character (nil if none yet).
function M.state_of(pawn)
    local id = appearance.player_id(pawn)
    return id and states[id] or nil
end

local function apply_id(id)
    local t = states[id]
    if not t then return end
    for _, p in ipairs(others(true)) do
        if appearance.player_id(p) == id then apply(p, t) end
    end
end

-- ---------------------------------------------------------------------------
-- Who can see whom (visual range)
-- ---------------------------------------------------------------------------
-- Client: is a client's character (not the host's) within range of the own
-- character? Those are the only machines that can use our head / lean. The
-- characters come from the engine's own replication (net relevancy 150 m >
-- VIS_CM). Checked every VIS_CHECK s, with hysteresis.
local function viewers_near(now, me)
    if now - near_at < VIS_CHECK then return near_on end
    near_at = now
    local ml = ue.location(me)
    if not ml then
        near_on = true
        return true
    end
    local lim = near_on and VIS_STAY_CM or VIS_CM
    lim = lim * lim
    local on = false
    for _, p in ipairs(others()) do
        local id = appearance.player_id(p)
        if not (host_cid and id == host_cid) then
            local l = ue.location(p)
            if not l or dist2(ml, l) <= lim then
                on = true
                break
            end
        end
    end
    near_on = on
    return on
end

-- Host: does client `pc` see the character `id`? (unknown = yes)
local function in_range(pc, id)
    local row = inr[addr(pc)]
    local v = row and row[id]
    return v ~= false
end

-- Host: recompute who is within VIS_CM of whom (every VIS_CHECK s). Returns
-- the list of { pc, id } that came into range: they get the full state now.
local function update_ranges(now, me, my_id)
    if now - ranges_at < VIS_CHECK then return nil end
    ranges_at = now
    local subj = {}
    local ml = me and ue.location(me)
    if my_id then subj[#subj + 1] = { id = my_id, loc = ml } end
    local views = {}
    for _, pc in ipairs(S.remote_pcs or {}) do
        if ue.valid(pc) then
            local pawn = ue.pawn_of(pc)
            local id = pawn and appearance.player_id(pawn)
            local v = { pc = pc, id = id, loc = pawn and ue.location(pawn) or nil }
            views[#views + 1] = v
            if id then subj[#subj + 1] = v end
        end
    end
    local flips = {}
    for _, v in ipairs(views) do
        local k = addr(v.pc)
        if k then
            local row = inr[k]
            if not row then
                row = {}
                inr[k] = row
            end
            for _, sj in ipairs(subj) do
                if sj.id ~= v.id then
                    local prev = row[sj.id]
                    local lim = prev and VIS_STAY_CM or VIS_CM
                    local now_in = true
                    if v.loc and sj.loc then now_in = dist2(v.loc, sj.loc) <= lim * lim end
                    if now_in and not prev then flips[#flips + 1] = { pc = v.pc, id = sj.id } end
                    row[sj.id] = now_in
                end
            end
        end
    end
    return flips
end

-- Host: send the state of character `id` to client `pc`: everything when it
-- is within range, else only the core (mask, bs) and only when that changed.
local function push(pc, id, t, vis)
    local k = addr(pc)
    if not k then return end
    local f = wire_of(t, vis)
    local core = f[1] .. "|" .. f[2] .. "|" .. f[3]
    local sc = sent_core[k]
    if not sc then
        sc = {}
        sent_core[k] = sc
        sent_full[k] = {}
    end
    if vis then
        local key = core .. "|" .. f[4]
        if sent_full[k][id] == key then return end
        sent_full[k][id] = key
    else
        if sc[id] == core then return end
        sent_full[k][id] = nil
    end
    sc[id] = core
    net.send_to(pc, "PSTATE", id, f[1], f[2], f[3], f[4])
end

local function push_flips(flips)
    for _, fl in ipairs(flips or {}) do
        local t = states[fl.id]
        if t then push(fl.pc, fl.id, t, true) end
    end
end

-- Every 100 ms: publish the own state when it changed. A host nobody is
-- connected to has nobody to tell: nothing is read, and the state goes out
-- again when somebody is there.
function M.fast_tick()
    if S.role ~= "host" and S.role ~= "client" then return end
    local host = S.role == "host"
    if host then
        if pose_fix_on() then ensure_combat_hook(os.clock()) end
        if #(S.remote_pcs or {}) == 0 then
            published = nil
            return
        end
    end
    local me = ue.local_pawn()
    if not me then return end
    local id = appearance.player_id(me)
    if not id then return end
    local now = os.clock()
    local flips = host and update_ranges(now, me, id) or nil
    local new = own_state(me)
    if host then new.hc = "1" end
    local vis = host or viewers_near(now, me)
    local pub = published
    local core_changed = not pub or mask_of(new) ~= mask_of(pub) or new.bs ~= pub.bs or new.ln ~= pub.ln
    local vis_changed = not pub or new.hy ~= pub.hy
    -- a client that was not sending the visual part sends it when somebody
    -- comes near (its first visual update is not held back)
    local fresh_vis = not host and vis and not pub_vis_sent
    -- (a client with nobody near publishes nothing for a visual change)
    local due = (host or vis) and (vis_changed or fresh_vis) and (fresh_vis or now - pub_vis_at >= HY_MIN_INTERVAL)
    if host then
        if core_changed or due then
            published = new
            pub_vis_at = vis_changed and now or pub_vis_at
            states[id] = copy_state(new)
            for _, pc in ipairs(S.remote_pcs) do push(pc, id, states[id], in_range(pc, id)) end
        end
        push_flips(flips)
        return
    end
    if core_changed or due then
        published = new
        states[id] = copy_state(new)
        local f = wire_of(new, vis)
        if vis then
            pub_vis_at = now
        end
        pub_vis_sent = vis
        net.send_to_host("MYSTATE", f[1], f[2], f[3], f[4])
    elseif not vis then
        pub_vis_sent = false
    end
end

-- Every second: re-apply (the game's own code may have reset a copy). The
-- host forgets the states of players who left (send_all).
function M.tick(remote_pcs)
    if S.role == "host" and remote_pcs then
        appearance.drop_left(states, remote_pcs)
        local live = {}
        for _, pc in ipairs(remote_pcs) do live[addr(pc) or 0] = true end
        for k in pairs(sent_core) do
            if not live[k] then sent_core[k], sent_full[k] = nil, nil end
        end
        for k in pairs(inr) do
            if not live[k] then inr[k] = nil end
        end
        -- a player id that is gone (respawn under a new id): forget its rows
        for _, tbl in ipairs({ inr, sent_core, sent_full }) do
            for _, row in pairs(tbl) do
                for id in pairs(row) do
                    if states[id] == nil then row[id] = nil end
                end
            end
        end
    end
    for _, p in ipairs(others()) do
        local id = appearance.player_id(p)
        local t = id and states[id]
        if t then apply(p, t) end
    end
end

-- Every frame: left hand IK target of other players' characters, the way the
-- game computes it for its own character (weapon socket 'LeftHand' in the
-- space of the bone 'Hand_R').
local kml_obj = nil
local function kml()
    if not ue.valid(kml_obj) then kml_obj = ue.find_object("/Script/Engine.Default__KismetMathLibrary") end
    return kml_obj
end

-- Every REFRESH s the frame tick looks up who is there and what they hold
-- (cheap now: the shared character list, the cached held weapon); every
-- frame it only does the IK of characters holding a firearm and the head turn.
local REFRESH = 0.25
-- IK every frame only while the character's mesh is on screen (rendered in the
-- last RENDER_TOL s, asked once per refresh); off screen once per refresh, so
-- LeftHandLoc - in the hand's own space - is never older than REFRESH s when
-- it comes into view.
local RENDER_TOL = 0.5
local LH_EPS = 0.01      -- cm: a LeftHandLoc this close to the last one written is not written again
local HEAD_EASE = 9       -- 1/s: the head eases towards the (4-degree, 4 / s) target values
local HEAD_EPS = 0.01    -- degrees: a head turn this small is 0 (the anim BP's own target here)
local ik_list, ik_list_at = {}, 0   -- recs of characters with a firearm and a LeftHand socket
local head_list = {}    -- recs (clients)
local head_now = {}     -- [pawn address] = smoothed head yaw
local last_frame = os.clock()
-- scratch values: UE4SS copies a table into the engine struct at once
local LH = { X = 0, Y = 0, Z = 0 }
local HEAD = { Pitch = 0, Yaw = 0, Roll = 0 }
-- GetSocketTransform: a plain obj:GetSocketTransform() every time. A cached
-- UFunction handle (removed after the 0.7.1 crashes of 2026-11-11) kept
-- calling the old class's function at an address that another object could
-- take; a plain call resolves on the object's real class and fails cleanly.

local function m_anim(mesh) return mesh:GetAnimInstance() end
local function m_shown(mesh) return mesh:WasRecentlyRendered(RENDER_TOL) end
local function m_set_head(anim, v) anim.HeadRotation = v end

-- FTransform.InverseTransformPosition (KismetMathLibrary.InverseTransformLocation):
-- Rotation.UnrotateVector(v - Translation) * GetSafeScaleReciprocal(Scale3D).
-- nil when the transform is not the plain numbers expected (then the engine
-- function is used).
local function safe_recip(s)
    if math.abs(s) <= 1e-8 then return 0 end
    return 1 / s
end
local function inv_transform(t, v)
    local r, tr, s = t.Rotation, t.Translation, t.Scale3D
    if r == nil or tr == nil or s == nil or v == nil then return nil end
    local qx, qy, qz, qw = r.X, r.Y, r.Z, r.W
    local tx, ty, tz = tr.X, tr.Y, tr.Z
    local sx, sy, sz = s.X, s.Y, s.Z
    local vx, vy, vz = v.X, v.Y, v.Z
    if type(qx) ~= "number" or type(qy) ~= "number" or type(qz) ~= "number" or type(qw) ~= "number"
        or type(tx) ~= "number" or type(ty) ~= "number" or type(tz) ~= "number"
        or type(sx) ~= "number" or type(sy) ~= "number" or type(sz) ~= "number"
        or type(vx) ~= "number" or type(vy) ~= "number" or type(vz) ~= "number" then
        return nil
    end
    local px, py, pz = vx - tx, vy - ty, vz - tz
    -- UnrotateVector: rotate by the conjugate (-x, -y, -z, w)
    local ax, ay, az = -qx, -qy, -qz
    local cx = 2 * (ay * pz - az * py)
    local cy = 2 * (az * px - ax * pz)
    local cz = 2 * (ax * py - ay * px)
    local rx = px + qw * cx + (ay * cz - az * cy)
    local ry = py + qw * cy + (az * cx - ax * cz)
    local rz = pz + qw * cz + (ax * cy - ay * cx)
    return rx * safe_recip(sx), ry * safe_recip(sy), rz * safe_recip(sz)
end
M.inv_transform = inv_transform   -- tests

-- One character's LeftHandLoc (through pcall); written only when it moved.
local function ik_apply(r)
    local target = r.root:GetSocketTransform(FN_LEFT, 0)
    local hand = r.mesh:GetSocketTransform(FN_HAND, 0)
    local tl = target.Translation
    local x, y, z = inv_transform(hand, tl)
    if x == nil then
        local m = kml()
        if not m then return end
        local loc = m:InverseTransformLocation(hand, tl)
        x, y, z = loc.X, loc.Y, loc.Z
    end
    if r.lx and math.abs(x - r.lx) < LH_EPS and math.abs(y - r.ly) < LH_EPS and math.abs(z - r.lz) < LH_EPS then
        return
    end
    LH.X, LH.Y, LH.Z = x, y, z
    r.p.LeftHandLoc = LH
    r.lx, r.ly, r.lz = x, y, z
end

-- Refresh: a firearm in hand -> the weapon's root (with a LeftHand socket),
-- the mesh, on screen or not.
local function ik_setup(r, now)
    r.ik = false
    if not r.mesh then return end
    local w = held_weapon(r.p, r, now)
    if not w or not w.root then return end
    if w.left == nil then w.left = ue.try(m_has_socket, w.root, FN_LEFT) == true end
    if not w.left then return end
    r.ik, r.root = true, w.root
    local ok, shown = pcall(m_shown, r.mesh)
    r.every = not ok or shown ~= false
    r.once = true      -- at least once per refresh, written even if unchanged
    r.lx = nil
end

local function refresh(now)
    fnames()
    local client, host = S.role == "client", S.role == "host"
    local ik, hl, rl, seen = {}, {}, {}, {}
    for _, p in ipairs(others()) do
        local k = addr(p)
        local r = k and rec_of(p, k)
        if r then
            seen[k] = true
            local mesh = ue.prop(p, "Mesh")
            r.mesh = ue.valid(mesh) and mesh or nil
            r.ik = false
            if ue.prop(p, "HoldingFirearm?") == true then
                local ok, err = pcall(ik_setup, r, now)
                if not ok then
                    r.ik = false
                    log.err_throttled("state-ik", "state: left hand IK lookup: %s", tostring(err))
                end
                if r.ik then ik[#ik + 1] = r end
            end
            if client then
                r.id = appearance.player_id(p)
                r.anim = r.mesh and ue.try(m_anim, r.mesh) or nil
                hl[#hl + 1] = r
            end
            if host then rl[#rl + 1] = p end
        end
    end
    for k in pairs(recs) do
        if not seen[k] then recs[k] = nil end
    end
    ik_list, head_list, remote_list = ik, hl, rl
end

-- Clients: head turn of other players (the host has their controllers, its
-- anim BP turns their heads by itself). The anim update moves HeadRotation
-- 10% towards its own target (0 here) per update, hence the / 0.9. Nothing
-- to write while the head is straight (the anim BP keeps it at 0 itself).
local function heads(dt)
    for i = 1, #head_list do
        local r = head_list[i]
        local p = r.p
        local t = r.id and states[r.id]
        local hy = t and tonumber(t.hy)
        -- cached for a fraction of a second: re-check every frame, a destroyed
        -- character's memory must never be touched (that crashed the client)
        if hy and ue.valid(p) then
            local k = r.k
            local cur = head_now[k] or 0
            if hy ~= 0 or cur ~= 0 then
                if ue.prop(p, "IsADS?") == true then hy = 0 end
                cur = cur + (hy - cur) * math.min(1, dt * HEAD_EASE)
                if hy == 0 and math.abs(cur) < HEAD_EPS then cur = 0 end
                head_now[k] = cur
                local anim = r.anim
                -- a character without an animated mesh (far / not rendered) has none:
                -- writing to it makes UE4SS log an error every frame
                if ue.valid(anim) then
                    HEAD.Yaw = cur / 0.9
                    pcall(m_set_head, anim, HEAD)
                end
            end
        end
    end
end

function M.frame_tick()
    if S.role ~= "host" and S.role ~= "client" then return end
    local now = os.clock()
    local dt = math.max(0.001, math.min(0.1, now - last_frame))
    last_frame = now
    -- a host nobody is connected to has no other player's character to animate
    if S.role == "host" and #(S.remote_pcs or {}) == 0 then
        if ik_list_at ~= 0 then
            ik_list, head_list, remote_list, recs = {}, {}, {}, {}
            ik_list_at = 0
        end
        if next(combat_dirty) ~= nil then combat_dirty = {} end
        return
    end
    if now - ik_list_at > REFRESH or now < ik_list_at then
        ik_list_at = now
        refresh(now)
    end
    if #head_list > 0 then heads(dt) end
    if S.role == "host" then combat_frame(now) end
    for i = 1, #ik_list do
        local r = ik_list[i]
        -- cached for a quarter second: re-check before touching them
        if (r.every or r.once) and ue.valid(r.p) and ue.valid(r.root) and ue.valid(r.mesh) then
            r.once = false
            pcall(ik_apply, r)
        end
    end
end

-- Host: every state known here to a client that said HI (players who left
-- are dropped first).
function M.send_all(pc)
    if S and S.role == "host" then appearance.drop_left(states, S.remote_pcs) end
    -- the joiner gets everything once (it is at the spawn, near the others
    -- at least as often as not); the range checks trim it afterwards
    -- a repeated HI (the client repeats it until acknowledged) or a client that
    -- reuses an address must get everything again: forget what was sent
    local k = addr(pc)
    if k then sent_core[k], sent_full[k], inr[k] = nil, nil, nil end
    for id, t in pairs(states) do push(pc, id, t, true) end
end

-- Role change and level change (sdc_session.reset_world): the cached
-- character lists are dropped without touching them. The UpdateCombatState
-- hook stays registered (its callback checks the role).
function M.reset()
    states, published, ik_list, head_list, head_now = {}, nil, {}, {}, {}
    pub_vis_at, pub_vis_sent, near_on, near_at, host_cid = 0, false, false, -1e9, nil
    inr, ranges_at, sent_core, sent_full = {}, -1e9, {}, {}
    recs = {}
    ik_list_at = 0
    fl_tried, fl_failing = {}, {}
    remote_list, combat_last, combat_dirty, combat_sent = {}, {}, {}, {}
    combat_sweep_at = 0
end

function M.register_handlers()
    -- The shared character list (sdc_ue.player_chars) learns of new characters
    -- from UE4SS's new-object notification; registered once, at load (this
    -- runs from sdc_session.register_handlers in main.lua's main chunk).
    if ue.watch_player_chars then pcall(ue.watch_player_chars) end
    -- host -> clients: PSTATE|player id|mask|bs|ln|hy
    net.on("PSTATE", function(f)
        local id = tonumber(f[1])
        if not id then return end
        id = math.floor(id)
        local t = states[id] or {}
        if not merge_wire(t, f, 2) then return end
        states[id] = t
        if t.hc == "1" then host_cid = id end
        apply_id(id)
    end)
    -- client -> host: MYSTATE|mask|bs|ln|hy   (its own character)
    net.on("MYSTATE", function(f, pc)
        local pawn = ue.pawn_of(pc)
        local id = pawn and appearance.player_id(pawn)
        if not id then return end
        local t = states[id] or {}
        if not merge_wire(t, f, 1) then return end
        t.hc = "0"
        -- the combat state is the host's call (check_combat): the other
        -- clients get the value of the active slot, not the owner's echo of
        -- a multicast the host may be correcting right now
        if pose_fix_on() then
            local want = expected_bs(pawn)
            if want ~= nil then t.bs = tostring(want) end
        end
        states[id] = t
        apply_id(id)
        local me = ue.local_pawn()
        local flips = update_ranges(os.clock(), me, me and appearance.player_id(me))
        for _, other in ipairs(S.remote_pcs or {}) do
            if addr(other) ~= addr(pc) then push(other, id, t, in_range(other, id)) end
        end
        push_flips(flips)
    end)
end

return M
