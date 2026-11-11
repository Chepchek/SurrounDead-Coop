-- SDCoop: items (Jig pickup actors) in co-op.
--
-- JigSInventory is network-ready: each player's HelperComp keeps a replicated
-- list of the equipped item ACTORS (RepActorsData) and every machine finds
-- the weapon / helmet / backpack through it. The pickup actors themselves
-- never replicated (StaticMeshActor / SkeletalMeshActor defaults; only the
-- Jig components do), so on clients that list pointed at nothing: no
-- weapons, the client could not draw its own gun, drops were invisible.
--
-- Host  : every pickup actor spawned at runtime (equipped items, drops, loot
--         of the random spawners) becomes replicated right after it is
--         created; level-placed pickups near players too. Items a client
--         drops out of a WORLD container (zombie, bandit, animal, trader,
--         backpack on the ground, dead player's loot box) land at that
--         client: those containers spawn the drop at GetPlayerCharacter(self,
--         0). Drops from a character's own inventory need no help
--         (HelperComp.GetDropLocation is that character).
-- Client: items worn by players are made inert (no physics / collision) and
--         kept where the host attached them (the client's own OnRep logic
--         re-holsters weapons because it does not know they are in hand),
--         right after the game's own OnReps; items on other players are not
--         hidden by their first-person view; the client's own copy of the
--         level does not spawn loot (its random spawners are authority there:
--         non-replicated level actors), and loot that still appears is removed.
--   * crafting and medical items: sdc_consume; workbenches whose work the
--     host does: sdc_stations; worn tools checked against host data
--     (binoculars, night vision): sdc_tools; a client's gun / muzzle
--     attachment wear (applied on the host): sdc_wear (all driven from here).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local consume = require("sdc_consume")
local stations = require("sdc_stations")
local tools = require("sdc_tools")
local wear = require("sdc_wear")
local containers = require("sdc_containers")

local M = {
    stats = { runtime = 0, level = 0, ghosts_removed = 0, inert = 0, reattached = 0, unhidden = 0, dropped_moved = 0,
              loot_blocked = 0, proxy_battery = 0, owner_relevant = 0 },
    consume = consume,
    stations = stations,
    tools = tools,
    wear = wear,
    containers = containers,
}

local S
function M.init(state)
    S = state
    consume.init(state)
    stations.init(state)
    tools.init(state)
    wear.init(state)
    containers.init(state)
end

-- sdc_consume runs whatever this module's own tick does (its hooks are
-- independent of replicate_items); an error there stays there.
local function consume_tick(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log.err_throttled("consume.tick", "consume: tick: %s", tostring(err)) end
end

-- A timed part of the host tick ([PERF] "parts", sdc_ue.sub_time): pcall'ed,
-- an error logged under its label.
local function sub(label, fn, ...)
    if ue.sub_time then return ue.sub_time(label, fn, ...) end
    local ok, err = pcall(fn, ...)
    if not ok then log.err_throttled(label, "%s: %s", label, tostring(err)) end
    return ok
end

local PICKUP_CLASSES = {
    "/Game/Inventory/Items/BP_StaticMeshPickup.BP_StaticMeshPickup_C",
    "/Game/Inventory/Items/BP_SkeletalMeshPickup.BP_SkeletalMeshPickup_C",
}
local PICKUP_SHORT = { "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }
local DROP_RPC = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestDropItem"
local HELPER_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C:"
local PLAYER_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"

-- S_RepActorData members (BP struct, GUID-suffixed names)
local F_SLOT = "Slot_4_8843E80049E14A7C56C7E89EF659AAEC"
local F_ACTOR = "Actor_5_6FDDEF454801C671BE34D7B2377175C5"
local HEAD_SLOTS = {
    ["Jig.PlayerSlot.Headwear"] = true, ["Jig.PlayerSlot.Eyewear"] = true,
    ["Jig.PlayerSlot.Facewear"] = true, ["Jig.PlayerSlot.Accessory"] = true,
}
-- Worn items the game keeps invisible and unattached: on equip it hides
-- them (and shrinks flashlight / binoculars to scale 0; BP_PlayerCharacter.
-- JigMP_OnPickupEquipped @2705-3078). The handheld flashlight's light is the
-- character's own "Flashlight" spot light; the item actor only has to exist
-- (FlashlightToggle@14 GetEquippedActorBySlot, its BatteryComponent and data
-- asset). The mod never shows these.
local NEVER_SHOWN = {
    ["Jig.PlayerSlot.Flashlight"] = true, ["Jig.PlayerSlot.Binoculars"] = true,
    ["Jig.PlayerSlot.FishingRod"] = true,
}

local NEAR_LEVEL_ITEMS = 5000   -- cm: level pickups this close to a remote player replicate
local COLLISION_NONE = 0

local addr = ctx.addr

local function is_local_attachment(a)
    return ue.class_name(a):find("LocalAttachment", 1, true) ~= nil
end

local function is_player_character(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

local function is_locally_controlled(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

-- A replicated character on a client (not the hidden stale local copy).
local function is_replicated_character(p)
    if not is_player_character(p) then return false end
    local r = ue.role(p)
    return r == ue.ROLE_SIMULATED or r == ue.ROLE_AUTONOMOUS
end

local function attach_parent(a)
    return ue.try(function() return a:GetAttachParentActor() end)
end

local function dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function all_pickups()
    local out = {}
    for _, cls in ipairs(PICKUP_SHORT) do
        for _, a in ipairs(ue.find_all(cls)) do out[#out + 1] = a end
    end
    return out
end

-- Equipped actors of a player: { [address] = slot tag }
local function equipped_of(pawn)
    local out = {}
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return out end
    pcall(function()
        helper.RepActorsData:ForEach(function(_, e)
            local entry = e:get()
            local actor = entry[F_ACTOR]
            if ue.valid(actor) then
                local tag = ue.str(ue.try(function() return entry[F_SLOT].TagName end))
                out[addr(actor)] = { actor = actor, slot = tag }
            end
        end)
    end)
    return out
end
M.equipped_of = equipped_of

-- ===========================================================================
-- Host
-- ===========================================================================

local function replicate(a, on_ground)
    if not ue.valid(a) or is_local_attachment(a) then return false end
    if ue.prop(a, "bReplicates") == true then return false end
    local ok = pcall(function() a:SetReplicates(true) end)
    pcall(function() a:SetReplicateMovement(true) end)
    -- items lying around rarely change; worn ones get a higher rate below
    ue.set_prop(a, "NetUpdateFrequency", on_ground and 2.0 or 30.0)
    pcall(function() a:ForceNetUpdate() end)
    return ok
end

local pending, flush_scheduled = {}, false
local recent = {}   -- runtime pickups of the last second (drop relocation)

-- The level pickups check (host, see "Level-placed pickups" below). No object
-- wrappers are kept beyond one pass: known / cand are keyed by address.
local lvl = {
    known = {},       -- [address] = { skip = true } or { loc = {X,Y,Z} }, til = os.clock() until which it is trusted
    cand = {},        -- [address] = the known entry of a level pickup that does not replicate yet
    dirty = true,     -- a level pickup may have appeared: list them all at the next check
    watch = false,    -- NotifyOnNewObject watches both pickup classes (forgets reused addresses)
    at = 0,           -- os.clock() of the last check (every LEVEL_EVERY s)
    full_at = -100,   -- os.clock() of the last pass over all pickups
    tick_at = -100,   -- os.clock() of the last host tick that ran the check
    pass = nil,       -- the pass in progress: { list, i, n, spots, seen, step_at }
    gen = 0,          -- bumped by reset(): an older pass's slices stop
}

local function flush()
    flush_scheduled = false
    local list = pending
    pending = {}
    if S.role ~= "host" or not cfg.get("replicate_items") then return end
    local n = 0
    for _, e in ipairs(list) do
        local a = e.obj
        if ue.valid(a) then
            if ue.is_runtime_spawned(a) then
                if replicate(a, not ue.valid(attach_parent(a))) then n = n + 1 end
            else
                lvl.dirty = true   -- a level pickup appeared (level streaming): the next check lists them all
            end
        end
    end
    M.stats.runtime = M.stats.runtime + n
    if n > 0 then log.debug("items: %d new items replicate (total %d)", n, M.stats.runtime) end
end

-- ---------------------------------------------------------------------------
-- Drops out of world containers (host)
-- ---------------------------------------------------------------------------
-- SERVER_RequestDropItem runs on the requesting player's own JigComponent and
-- calls CompTarget.HandleServerDropRequest, which asks CompTarget's OWNER to
-- spawn the pickup (JigMP_OnRequestDropItem). A character drops at its own
-- feet, but these world containers spawn it at GetPlayerCharacter(self, 0):
-- the host. Their JigMP_OnRequestDropItem is post-hooked (it returns the new
-- pickup in its out param ActorRef); the SERVER_RequestDropItem post-hook runs
-- right after, in the same call, knows who asked and moves the pickup to that
-- player before it is ever replicated.
local CONTAINER_DROP_CLASSES = {
    "/Game/Inventory/Items/BP_StaticMeshPickup.BP_StaticMeshPickup_C",
    "/Game/Inventory/Items/BP_SkeletalMeshPickup.BP_SkeletalMeshPickup_C",
    "/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C",
    "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C",
    "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C",
    "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C",
    "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C",
    "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C",
    "/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C",
    "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
    "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C",
    "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C",
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
}
local CAUGHT_MAX_AGE = 0.25   -- s: a caught pickup belongs to the request being handled
local caught = {}             -- { { obj =, t =, src = } } pickups a world container just spawned
local container_hooked = {}   -- [path] = true
local container_hook_at = -100

local function on_container_drop(c, _, _, actor_p)
    if S.role ~= "host" or not actor_p then return end
    local ok, a = pcall(function() return actor_p:get() end)
    if not ok or not ue.valid(a) then return end
    if #caught >= 16 then caught = {} end
    caught[#caught + 1] = { obj = a, t = os.clock(), src = ue.class_name(c and c:get()) }
end

local function try_hook_container_drops(now)
    if now - container_hook_at < 10 then return end
    container_hook_at = now
    for _, cls in ipairs(CONTAINER_DROP_CLASSES) do
        local path = cls .. ":JigMP_OnRequestDropItem"
        if not container_hooked[path] then
            local ok = pcall(RegisterHook, path, function(c, info_p, name_p, actor_p)
                local okc, err = pcall(on_container_drop, c, info_p, name_p, actor_p)
                if not okc then log.err_throttled("items.container-drop", "items: container drop hook: %s", tostring(err)) end
            end)
            if ok then
                container_hooked[path] = true
                log.info("items: container drop hook ok (%s)", cls:match("%.([%w_]+)$"))
            end
        end
    end
end

local function drop_spot(ol)
    return { X = ol.X + math.random(-40, 40), Y = ol.Y + math.random(-40, 40), Z = ol.Z + 20 }
end

-- Fallback for a container class not hooked above: the game spawned the
-- pickup at the host (player 0) a moment ago. Runs 30 ms after the request.
local function on_drop_request(comp)
    if S.role ~= "host" then return end
    if not ue.valid(comp) then return end
    local owner = ue.try(function() return comp:GetOwner() end)
    if not is_player_character(owner) then return end
    local pc = ue.prop(owner, "Controller")
    if not ue.valid(ue.prop(pc, "NetConnection")) then return end   -- the host's own drop is fine
    local host_pawn = ue.local_pawn()
    local hl, ol = ue.location(host_pawn), ue.location(owner)
    if not hl or not ol then return end
    local now = os.clock()
    local moved = 0
    for _, e in ipairs(recent) do
        local a = e.obj
        if now - e.t < 1.0 and ue.valid(a) and not ue.valid(attach_parent(a)) then
            local l = ue.location(a)
            if l and dist2(l, hl) < 400 * 400 and dist2(l, ol) > 400 * 400 then
                pcall(function() a:K2_SetActorLocation(drop_spot(ol), false, {}, true) end)
                pcall(function() a:ForceNetUpdate() end)
                moved = moved + 1
            end
        end
    end
    if moved > 0 then
        M.stats.dropped_moved = M.stats.dropped_moved + moved
        log.info("items: %d item(s) dropped by %s moved from the host to them (fallback)", moved, ue.short(owner))
    end
end

-- SERVER_RequestDropItem(ItemUID, Count, CompTarget), post: still inside the
-- RPC, right after the container spawned the pickup.
local function on_drop_rpc(c, _, _, target_p)
    if S.role ~= "host" then return end
    local list = caught
    caught = {}
    local comp = c and c:get()
    if not ue.valid(comp) then return end
    local owner = ue.try(function() return comp:GetOwner() end)
    if not is_player_character(owner) then return end
    local ol = ue.location(owner)
    if not ol then return end
    local now = os.clock()
    local n, moved, src = 0, 0, nil
    for _, e in ipairs(list) do
        if now - e.t <= CAUGHT_MAX_AGE and ue.valid(e.obj) then
            n = n + 1
            src = src or e.src
            local a = e.obj
            -- the host's own drop is already at its feet (player 0), unless
            -- another stand-in of sdc_ctx answered for that container
            if dist2(ue.location(a), ol) > 400 * 400
                and pcall(function() a:K2_SetActorLocation(drop_spot(ol), false, {}, true) end) then
                moved = moved + 1
                pcall(function() a:ForceNetUpdate() end)
            end
        end
    end
    if moved > 0 then
        M.stats.dropped_moved = M.stats.dropped_moved + moved
        log.info("items: %d item(s) that %s dropped out of %s moved to them", moved, ue.short(owner), tostring(src))
    end
    local pc = ue.prop(owner, "Controller")
    if n > 0 or not ue.valid(ue.prop(pc, "NetConnection")) then return end
    -- nothing caught: the own inventory (dropped at the character by the game
    -- itself) or a container class without a hook above
    local target = target_p and ue.try(function() return target_p:get() end)
    local towner = ue.valid(target) and ue.try(function() return target:GetOwner() end) or nil
    if is_player_character(towner) then return end
    log.debug("items: drop out of %s (no container hook), fallback relocation", ue.class_name(towner))
    ue.delay("drop-move", 30, function() on_drop_request(comp) end)
end

local drop_hooked = false
local function try_hook_drop()
    if drop_hooked then return end
    local ok, err = pcall(RegisterHook, DROP_RPC, function(c, uid_p, count_p, target_p)
        local okc, e = pcall(on_drop_rpc, c, uid_p, count_p, target_p)
        if not okc then log.err_throttled("items.drop", "items: drop hook: %s", tostring(e)) end
        -- which item the drop took (sdc_consume's inventory snapshot)
        okc, e = pcall(consume.host_drop_report, c, uid_p, count_p, target_p)
        if not okc then log.err_throttled("items.drop-report", "items: drop report: %s", tostring(e)) end
    end)
    if ok then
        drop_hooked = true
        log.info("items: drop hook ok")
    else
        log.debug("items: drop hook not ready (%s)", tostring(err))
    end
end

-- Equipment UIDs (slot -> item GUID). The client's own game looks up an
-- equipped item's durability / ammo by this UID (e.g. the melee attack:
-- GetEquipmentUID -> GetDurability), but HelperComp.EquipmentUIDs is filled
-- on the host only, so on a client every lookup found 0 ("Item durability too
-- low"). The host sends each client the map of its own character.
--
-- The durability itself is looked up in BP_JigMultiplayer.MainJigContainers,
-- which also exists only on the host (a client keeps its inventory in UI
-- widgets), so the host sends the durability of every equipped item too, and
-- the client's GetDurability is corrected after it ran (see install()).
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_DUR = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"

local function guid_str(g)
    return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D)
end

-- The tick's one walk of the player's inventory (sdc_consume.inventory; in
-- `pass` when sdc_consume.host_player took it this tick), or a walk now.
local function inventory_of(pawn, pass)
    if pass and pass.inv then return pass.inv end
    local jig = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(jig) then return nil end
    local inv = consume.inventory(jig, true)
    if pass then pass.inv = inv end
    return inv
end

local function uid_string(pawn, pass)
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return nil end
    -- durability of each item, from the host's copy of the player's inventory
    local inv = inventory_of(pawn, pass)
    local by_uid = inv and inv.by_uid or {}
    local list, err = consume.equipment_of(pass, helper)
    if err then
        log.err_throttled("uids-read", "items: cannot read EquipmentUIDs: %s", tostring(err))
        return nil
    end
    local parts = {}
    for _, e in ipairs(list) do
        local it = by_uid[e.g]
        local d = it and it.dur
        parts[#parts + 1] = string.format("%s=%s%s", e.tag, e.g, d and string.format("@%.2f", d) or "")
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

-- The whole inventory of a player as the host has it: UID -> durability, and
-- for items with a battery slot (flashlights, weapon lights) the charge of the
-- battery in it. A client's own game checks these (melee durability, battery
-- before switching a light on) in data that exists only on the host. The host
-- stays the authority: it drains batteries / durability, the client only
-- reads the values it is sent.
local function items_string(pawn, pass)
    local jig = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(jig) then return nil end
    local inv = inventory_of(pawn, pass)
    if not inv then return nil end
    if inv.bad then
        log.err_throttled("items-read", "items: cannot read the inventory of %s: %s", ue.short(pawn), tostring(inv.bad))
        return nil
    end
    local at0 = inv.at0   -- [container uid] = the item at index 0 (its durability: the battery's charge)
    local parts = {}
    for _, e in ipairs(inv.list) do
        local s0 = e.sub and at0[e.sub]
        local bat = s0 and s0.dur
        parts[#parts + 1] = string.format("%s=%.1f%s", e.uid, e.dur, bat and string.format("/%.1f", bat) or "")
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local uids_sent = {}   -- [pc address] = pawn address .. uid string
local items_sent = {}  -- [pc address] = pawn address .. items string

-- UIDS / ITEMS of one remote player, when they changed.
local function send_uids(pc, pass)
    local pawn = pass.pawn
    if not pawn then return end
    local s = uid_string(pawn, pass)
    local key = tostring(addr(pawn)) .. "|" .. tostring(s)
    if s and uids_sent[addr(pc)] ~= key then
        uids_sent[addr(pc)] = key
        net.send_to(pc, "UIDS", s)
        log.debug("items: equipment UIDs sent to %s: %s", ue.short(pc), s)
    end
    local t = items_string(pawn, pass)
    local tkey = tostring(addr(pawn)) .. "|" .. tostring(t)
    if t and items_sent[addr(pc)] ~= tkey then
        items_sent[addr(pc)] = tkey
        net.send_to(pc, "ITEMS", t)
    end
end

-- Client: write the host's map into the own HelperComp.
local client_uids = { text = nil, applied = nil, dur = {} }
-- Client: the own inventory's durabilities / battery charges from the host.
local client_items = { dur = {}, bat = {}, n = 0 }

local function apply_items(s)
    local dur, bat, n = {}, {}, 0
    for uid, d, b in (s or ""):gmatch("([%-%d:]+)=([%d%.%-]+)/?([%d%.]*)") do
        dur[uid] = tonumber(d)
        if b ~= "" then bat[uid] = tonumber(b) end
        n = n + 1
    end
    local first = client_items.n == 0
    client_items = { dur = dur, bat = bat, n = n, at = os.clock() }
    if first then log.info("items: inventory values from the host: %d items", n) end
end

local function apply_uids()
    local me = ue.local_pawn()
    local s = client_uids.text
    if not me or not s then return end
    local key = tostring(addr(me)) .. "|" .. s
    if client_uids.applied == key then return end
    local helper = ue.prop(me, "BP_JigHelperComp")
    if not ue.valid(helper) then return end
    client_uids.applied = key
    -- only durabilities changed (a gun, armor wearing): the same map, a debug line
    local map = tostring(addr(me)) .. "|" .. (s:gsub("@[%d%.]*", ""))
    local same_map = client_uids.map == map
    client_uids.map = map
    local n, ok_n, last_err = 0, 0, nil
    pcall(function() helper.EquipmentUIDs:Empty() end)
    client_uids.dur = {}
    -- FGuid A..D are int32 in reflection: negative numbers are normal
    for entry in s:gmatch("[^;]+") do
        local tag, a, b, c, d, dur = entry:match("^([^=]+)=(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)@?([%d%.]*)$")
        if tag then
            n = n + 1
            if dur ~= "" then client_uids.dur[string.format("%s:%s:%s:%s", a, b, c, d)] = tonumber(dur) end
            local ok, err = pcall(function()
                helper.EquipmentUIDs:Add({ TagName = FName(tag) },
                    { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) })
            end)
            if ok then ok_n = ok_n + 1 else last_err = err end
        end
    end
    local nd = 0
    for _ in pairs(client_uids.dur) do nd = nd + 1 end
    local line = string.format("items: %d/%d equipment UIDs from the host written, %d durabilities%s", ok_n, n, nd,
        last_err and (" (error: " .. tostring(last_err) .. ")") or "")
    if same_map and not last_err then log.debug("%s (durabilities only)", line) else log.info("%s", line) end
end

-- Client: BP_JigMultiplayer.GetDurability(UID, out NewDur) searched the empty
-- MainJigContainers and gave 0; give it the host's value instead.
local dur_fixes = 0
local function fix_durability(c, ...)
    if S.role ~= "client" then return end
    local args = { ... }
    local uid_p, out_p = args[1], args[2]
    if not uid_p or not out_p then return end
    local okv, cur = pcall(function() return out_p:get() end)
    if not okv or (type(cur) == "number" and cur ~= 0) then return end
    local oku, u = pcall(function() return guid_str(uid_p:get()) end)
    if not oku then return end
    local want = client_items.dur[u] or client_uids.dur[u]
    if not want then return end
    -- own gun / muzzle wear the host's value does not have yet (sdc_wear)
    local okm, minus = pcall(wear.own_minus, u)
    if okm and type(minus) == "number" and minus > 0 then want = math.max(0, want - minus) end
    local ok, err = pcall(function() out_p:set(want) end)
    dur_fixes = dur_fixes + 1
    if dur_fixes <= 3 then
        local okr, back = pcall(function() return out_p:get() end)
        log.info("items: durability of %s fixed to %.1f (set ok=%s%s, reads %s)", u, want, tostring(ok),
            ok and "" or (" " .. tostring(err)), tostring(okr and back))
    end
end

local dur_hooked = false
local function try_hook_durability()
    if dur_hooked then return end
    local ok, err = pcall(RegisterHook,
        "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:GetDurability", fix_durability)
    if ok then
        dur_hooked = true
        log.info("items: durability hook ok")
    else
        log.debug("items: durability hook not ready (%s)", tostring(err))
    end
end

-- Client: battery checks of flashlights / weapon lights (BatteryComponent)
-- looked the item up in the empty MainJigContainers: no light ever came on.
--   CheckBatteryLevel(JigComp, UID, out Battery?, out Value)
--   UseBattery(JigComp, UID, MinusDur, out NewDur, out Successful?)
-- * Own items: answer with the charge the host reports. Draining is the
--   host's job (its copy of the light runs the same timer on the real
--   inventory).
-- * Another player's item (a light module on their weapon, their handheld
--   flashlight): yes. The game's own switch paths then work as in single
--   player - the replicated module state (RepAttachments -> ProcessAttachments
--   -> Jig_SetAttachmentActiveState -> Event_Battery) and MC_Flashlight ->
--   FlashlightToggle set intensity, light function, radius, sound and timers.
--   The host owns that battery: when it runs out there, the owner switches the
--   light off for everyone through the same replicated paths.
local BATTERY = "/Game/Blueprints/Components/BatteryComponent.BatteryComponent_C:"
local PROXY_CHARGE = 100.0
local battery_fixes = 0

local function battery_of(uid_p)
    local ok, u = pcall(function() return guid_str(uid_p:get()) end)
    if not ok then return nil, nil end
    return client_items.bat[u], u
end

-- The character an item with a BatteryComponent belongs to: the component's
-- owner is the item (flashlight -> character, light module -> weapon -> character).
local function holder_of(comp)
    local o = ue.try(function() return comp:GetOwner() end)
    for _ = 1, 4 do
        if not ue.valid(o) then return nil end
        if is_player_character(o) then return o end
        o = ue.try(function() return o:GetOwner() end)
    end
    return nil
end

-- `c` is the hook context (the BatteryComponent). Returns the holder when it
-- is another player's character on this client.
local function proxy_holder(c)
    local comp = c and c:get()
    if not ue.valid(comp) then return nil end
    local p = holder_of(comp)
    if p and not is_locally_controlled(p) then return p end
    return nil
end

local function fix_check_battery(c, jig, uid_p, ok_p, value_p)
    if S.role ~= "client" or not ok_p then return end
    local okv, cur = pcall(function() return ok_p:get() end)
    if not okv or cur == true then return end
    local holder = proxy_holder(c)
    if holder then
        pcall(function() ok_p:set(true) end)
        if value_p then pcall(function() value_p:set(PROXY_CHARGE) end) end
        M.stats.proxy_battery = M.stats.proxy_battery + 1
        if M.stats.proxy_battery <= 3 then
            local item = ue.try(function() return c:get():GetOwner() end)
            log.info("items: battery of %s on %s (another player) -> yes, the host owns it",
                ue.short(item), ue.short(holder))
        end
        return
    end
    local bat, u = battery_of(uid_p)
    if not bat or bat <= 0 then return end
    pcall(function() ok_p:set(true) end)
    if value_p then pcall(function() value_p:set(bat) end) end
    battery_fixes = battery_fixes + 1
    if battery_fixes <= 3 then log.info("items: battery of %s reported by the host: %.1f", tostring(u), bat) end
end

local function fix_use_battery(c, jig, uid_p, minus_p, newdur_p, ok_p)
    if S.role ~= "client" or not ok_p then return end
    local okv, cur = pcall(function() return ok_p:get() end)
    if not okv or cur == true then return end
    if proxy_holder(c) then
        -- NewDur 0 would show "Battery run out" here and switch the light off
        pcall(function() ok_p:set(true) end)
        if newdur_p then pcall(function() newdur_p:set(PROXY_CHARGE) end) end
        return
    end
    local bat = battery_of(uid_p)
    if not bat or bat <= 0 then return end
    pcall(function() ok_p:set(true) end)
    if newdur_p then pcall(function() newdur_p:set(bat) end) end
end

local battery_hooked = false
local function try_hook_battery()
    if battery_hooked then return end
    local ok1, e1 = pcall(RegisterHook, BATTERY .. "CheckBatteryLevel", function(c, jig, uid_p, ok_p, value_p)
        local ok, err = pcall(fix_check_battery, c, jig, uid_p, ok_p, value_p)
        if not ok then log.err_throttled("items.battery-check", "items: battery check hook: %s", tostring(err)) end
    end)
    if not ok1 then
        log.debug("items: battery hook not ready (%s)", tostring(e1))
        return
    end
    local ok2, e2 = pcall(RegisterHook, BATTERY .. "UseBattery", function(c, jig, uid_p, minus_p, newdur_p, ok_p)
        local ok, err = pcall(fix_use_battery, c, jig, uid_p, minus_p, newdur_p, ok_p)
        if not ok then log.err_throttled("items.battery-use", "items: battery use hook: %s", tostring(err)) end
    end)
    battery_hooked = true
    log.info("items: battery hooks ok (use=%s%s)", tostring(ok2), ok2 and "" or (" " .. tostring(e2)))
end

-- ---------------------------------------------------------------------------
-- Level-placed pickups near remote players (host)
-- ---------------------------------------------------------------------------
-- They replicate once a remote player is within NEAR_LEVEL_ITEMS (so a
-- pickup by anyone removes the item for everyone), checked every 5 s. A map
-- has thousands of them: reading every one's replication flag, name, class
-- and location every 5 s was one 40-70 ms frame. Now what cannot change for
-- a pickup is remembered by its address (lvl above): "skip" (replicated,
-- spawned at run time, a local attachment) or its location (level pickups
-- lie still). An address is forgotten the moment a new pickup is constructed
-- there (the NotifyOnNewObject watch, install()), and every entry is read
-- again after LEVEL_TRUST..+LEVEL_SPREAD s. Every 5 s only the remembered
-- locations are compared with the players' (Lua, no engine call). The pickups
-- are listed (FindAllOf) and looked at only when a remembered one is near a
-- player (it is read again in full before it replicates, as before), a level
-- pickup was created (level streaming, flush()), the watch is missing, or
-- LEVEL_FULL_EVERY s passed. That pass is sliced: LEVEL_STEP_MS of work per
-- frame, the next slice LEVEL_GAP_MS later (a few thousand pickups: well
-- under a second, then the same 5 s rhythm).
local LEVEL_EVERY = 5          -- s between checks (as before)
local LEVEL_FULL_EVERY = 60    -- s: all pickups listed at least this often
local LEVEL_TRUST = 120        -- s (+ up to LEVEL_SPREAD) a remembered entry is used without reading the pickup
local LEVEL_SPREAD = 60
local LEVEL_STEP_MS = 3        -- engine work per frame of a pass
local LEVEL_GAP_MS = 30        -- between two frames of a pass

local function near_spot(l, spots)
    if not l then return false end
    for _, s in ipairs(spots) do
        if dist2(l, s) < NEAR_LEVEL_ITEMS * NEAR_LEVEL_ITEMS then return true end
    end
    return false
end

-- Reads a pickup the way the old pass did and remembers the verdict.
local function level_look(a, k, now)
    if not ue.valid(a) then
        lvl.known[k], lvl.cand[k] = nil, nil
        return nil
    end
    M.stats.level_looks = (M.stats.level_looks or 0) + 1
    local e = { til = now + LEVEL_TRUST + math.random() * LEVEL_SPREAD }
    if ue.prop(a, "bReplicates") == true or ue.is_runtime_spawned(a) or is_local_attachment(a) then
        e.skip = true
        lvl.cand[k] = nil
    else
        e.loc = ue.location(a)
        lvl.cand[k] = e
    end
    lvl.known[k] = e
    return e
end

local level_step   -- (below: a slice schedules the next one)

-- The next slice of pass `p` in a later frame; false when ue.delay failed
-- (the next host tick goes on with it).
local function level_next(p)
    local gen = lvl.gen
    local function go()
        if gen ~= lvl.gen or lvl.pass ~= p then return end
        sub("h:items.level", level_step, p)
    end
    local ok, h = pcall(ue.delay, "items-level", LEVEL_GAP_MS, go)
    if not ok or h == false then
        p.stalled = true
        return false
    end
    return true
end

-- One slice of a pass over the listed pickups (the first one lists them; the
-- list's wrappers are used only after a validity check, within the pass).
level_step = function(p)
    if S.role ~= "host" or not cfg.get("replicate_items") then
        lvl.pass = nil
        return
    end
    local t0 = os.clock()
    p.step_at = t0
    if not p.list then p.list = all_pickups() end
    local list, known, trust = p.list, lvl.known, lvl.watch
    while p.i < #list do
        p.i = p.i + 1
        local a = list[p.i]
        local k = addr(a)
        if k ~= nil and k ~= 0 then
            p.seen[k] = true
            local e = known[k]
            local fresh = false
            if not e or not trust or t0 >= e.til then
                e = level_look(a, k, t0)
                fresh = true
            end
            if e and not e.skip and near_spot(e.loc, p.spots) then
                -- near a player: read in full again before it replicates
                if not fresh then e = level_look(a, k, t0) end
                if e and not e.skip and near_spot(e.loc, p.spots) and replicate(a, not ue.valid(attach_parent(a))) then
                    p.n = p.n + 1
                    e.skip = true
                    lvl.cand[k] = nil
                end
            end
        end
        if (os.clock() - t0) * 1000 >= LEVEL_STEP_MS then break end
    end
    if p.i < #list then
        level_next(p)
        return
    end
    -- the pass is done: what was not listed is gone
    for k in pairs(known) do
        if not p.seen[k] then known[k], lvl.cand[k] = nil, nil end
    end
    lvl.pass = nil
    if p.n > 0 then
        M.stats.level = M.stats.level + p.n
        log.info("items: %d level items near players now replicate (total %d level, %d runtime)", p.n, M.stats.level, M.stats.runtime)
    end
end

local function level_tick(remote_pawns, now)
    -- the check was off (no remote player, setting off): look at all again
    if now - lvl.tick_at > 2 * LEVEL_EVERY + 1 then lvl.dirty = true end
    lvl.tick_at = now
    local p = lvl.pass
    if p then
        -- a pass whose next slice never came (ue.delay failed): on from here
        if p.stalled or now - p.step_at > 1 then
            p.stalled = false
            level_step(p)
        end
        return
    end
    if now - lvl.at < LEVEL_EVERY then return end
    lvl.at = now
    local spots = {}
    for _, pw in pairs(remote_pawns) do spots[#spots + 1] = ue.location(pw) end
    local full = lvl.dirty or not lvl.watch or now - lvl.full_at >= LEVEL_FULL_EVERY
    if not full then
        for _, e in pairs(lvl.cand) do
            if near_spot(e.loc, spots) then
                full = true
                break
            end
        end
    end
    if not full then return end
    lvl.dirty, lvl.full_at = false, now
    -- the listing and the first slice in a frame of their own (not on top of
    -- this tick's inventory walk)
    p = { list = nil, i = 0, n = 0, spots = spots, seen = {}, step_at = now }
    lvl.pass = p
    if not level_next(p) then
        p.stalled = false
        level_step(p)
    end
end

-- ---------------------------------------------------------------------------
-- Host tick (1 s)
-- ---------------------------------------------------------------------------
-- [PERF] "parts": h:items broken down into h:items.consume / .stations /
-- .containers (their ticks), .inv (the one walk of a remote player's
-- inventory + health, sdc_consume.host_player), .tools (binoculars / night
-- vision), .uids (UIDS / ITEMS), .worn (worn items), .level (level pickups).
-- The 2nd and later remote players' .inv / .tools / .uids and the later
-- slices of a .level pass run in frames of their own, outside h:items.
local PLAYER_GAP_MS = 100   -- each further remote player's part this much later (all within 600 ms)
local pass_gen = 0          -- bumped by reset(): delayed parts of an older session do nothing

-- One remote player: inventory and health snapshots (the tick's one walk of
-- that inventory, shared through `pass`), binoculars / night vision, UIDS /
-- ITEMS.
local function player_pass(pc, rep)
    if not ue.valid(pc) then return end
    local pass = { pawn = ue.pawn_of(pc) }
    sub("h:items.inv", consume.host_player, pc, pass)
    sub("h:items.tools", tools.host_player, pc, pass)
    if rep then sub("h:items.uids", send_uids, pc, pass) end
end

-- Worn items: replicate fast, relevant exactly when their character is; a
-- remote player's items must not stay hidden because the host's copy of that
-- player thinks it is in first person.
local function worn_pass(remote_pawns)
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        local is_remote = remote_pawns[addr(p)] ~= nil
        for _, it in pairs(equipped_of(p)) do
            local a = it.actor
            if ue.prop(a, "bReplicates") ~= true then replicate(a, false) end
            local f = ue.prop(a, "NetUpdateFrequency")
            if type(f) == "number" and f < 20 then
                ue.set_prop(a, "NetUpdateFrequency", 30.0)
                pcall(function() a:ForceNetUpdate() end)
            end
            -- AActor::IsNetRelevantFor: a HIDDEN actor without collision is
            -- relevant only to its owner. The handheld flashlight (and the
            -- binoculars) the game hides and leaves unattached, so other
            -- players never received it: the slot in RepActorsData stayed
            -- unresolved there and FlashlightToggle returned at once. With
            -- owner relevancy (checked before the hidden rule) it follows
            -- its character; attached items already did (skeletal parent).
            if ue.prop(a, "bNetUseOwnerRelevancy") ~= true then
                local owner = ue.try(function() return a:GetOwner() end)
                if ue.valid(owner) and addr(owner) == addr(p) and ue.set_prop(a, "bNetUseOwnerRelevancy", true) then
                    pcall(function() a:ForceNetUpdate() end)
                    M.stats.owner_relevant = M.stats.owner_relevant + 1
                    local line = string.format("items: %s (%s) of %s now relevant with its owner (hidden=%s, attached=%s)",
                        ue.short(a), (it.slot:gsub("^Jig%.PlayerSlot%.", "")), ue.short(p),
                        tostring(ue.prop(a, "bHidden")), tostring(ue.valid(attach_parent(a))))
                    if NEVER_SHOWN[it.slot] or M.stats.owner_relevant <= 3 then log.info("%s", line) else log.debug("%s", line) end
                end
            end
            if is_remote and ue.prop(a, "bHidden") == true and M.visible_scale(a) and not NEVER_SHOWN[it.slot]
                and not ue.class_name(a):find("FishingRod", 1, true) then
                pcall(function() a:SetActorHiddenInGame(false) end)
                M.stats.unhidden = M.stats.unhidden + 1
                log.debug("items: %s on %s was hidden on the host, shown", ue.short(a), ue.short(p))
            end
        end
    end
end

function M.host_tick(remote_pcs)
    remote_pcs = remote_pcs or {}
    sub("h:items.consume", consume.host_tick, remote_pcs, true)
    sub("h:items.stations", stations.host_tick)
    consume_tick(tools.host_begin)
    sub("h:items.containers", containers.host_tick)
    local now = os.clock()
    local keep = {}
    for _, e in ipairs(recent) do if now - e.t < 2 then keep[#keep + 1] = e end end
    recent = keep
    local rep = cfg.get("replicate_items")
    if rep then
        try_hook_drop()
        try_hook_container_drops(now)
        -- container drops that were not part of a client's request (a trader's
        -- death drop, the host's own looting): forgotten untouched
        if #caught > 0 and now - caught[#caught].t > 1 then caught = {} end
    end
    -- each remote player's part (consume / tools / UIDS, ITEMS): the first
    -- now, the others in frames of their own (one inventory walk per frame)
    local n = #remote_pcs
    for i, pc in ipairs(remote_pcs) do
        if i == 1 then
            player_pass(pc, rep)
        else
            local gen = pass_gen
            local function later()
                if gen ~= pass_gen or S.role ~= "host" then return end
                player_pass(pc, cfg.get("replicate_items"))
            end
            local ok, h = pcall(ue.delay, "items-player", math.min(PLAYER_GAP_MS, math.floor(600 / (n - 1))) * (i - 1), later)
            if not ok or h == false then later() end
        end
    end
    if not rep or n == 0 then return end
    local remote_pawns = {}
    for _, pc in ipairs(remote_pcs) do
        local p = ue.pawn_of(pc)
        if p then remote_pawns[addr(p)] = p end
    end
    sub("h:items.worn", worn_pass, remote_pawns)
    -- level-placed pickups near remote players (so a pickup by anyone
    -- removes the item for everyone)
    sub("h:items.level", level_tick, remote_pawns, now)
end

function M.visible_scale(a)
    local root = ue.prop(a, "RootComponent")
    local s = ue.prop(root, "RelativeScale3D")
    if not s then return true end
    local ok, m = pcall(function() return math.max(math.abs(s.X), math.abs(s.Y), math.abs(s.Z)) end)
    return not ok or m > 0.01
end

-- ===========================================================================
-- Client
-- ===========================================================================

-- [address] = { name = actor's full name, prims = { [component name] = { coll, phys } } }
-- No object wrappers are kept: an address can belong to another actor by the
-- next tick (the old one destroyed and freed, a new pickup in its memory), so
-- a record is used only when the actor's name still matches, and components
-- are looked up again on the live actor.
local inert = {}

local function prim_comps(a)
    local out = {}
    local cls = ue.find_object("/Script/Engine.PrimitiveComponent")
    local ok, arr = pcall(function() return a:K2_GetComponentsByClass(cls) end)
    if not ok or arr == nil then return out end
    local function add(c)
        if c and not ue.valid(c) then c = ue.try(function() return c:get() end) end
        if ue.valid(c) then out[#out + 1] = c end
    end
    if type(arr) == "table" then
        for _, c in ipairs(arr) do add(c) end
    else
        pcall(function() arr:ForEach(function(_, el) add(el) end) end)
    end
    return out
end

-- `a` is a live actor of this tick.
local function make_inert(a)
    if not ue.valid(a) then return end
    local k = addr(a)
    local name = ue.name(a)
    local old = inert[k]
    if old and old.name == name then return end
    -- a record of another (destroyed) actor at this address is dropped untouched
    local rec = { name = name, prims = {} }
    for _, c in ipairs(prim_comps(a)) do
        if ue.valid(c) then
            local coll = ue.try(function() return c:GetCollisionEnabled() end)
            local phys = ue.try(function() return c:IsSimulatingPhysics() end)
            rec.prims[ue.short(c)] = { coll = coll, phys = phys }
            pcall(function() c:SetSimulatePhysics(false) end)
            pcall(function() c:SetCollisionEnabled(COLLISION_NONE) end)
        end
    end
    inert[k] = rec
    M.stats.inert = M.stats.inert + 1
end

-- `a` is the live actor of this tick, already checked to be the one in `rec`.
local function restore(k, rec, a)
    inert[k] = nil
    if not ue.valid(a) then return end
    for _, c in ipairs(prim_comps(a)) do
        local p = ue.valid(c) and rec.prims[ue.short(c)] or nil
        if p then
            if p.coll ~= nil then pcall(function() c:SetCollisionEnabled(p.coll) end) end
            if p.phys then pcall(function() c:SetSimulatePhysics(true) end) end
        end
    end
end

-- Put a worn item where the host has it (hand / back / head socket).
-- AttachmentReplication is the host's attachment as last replicated. The
-- engine gathers it only while the item is attached (or replicates its
-- movement): when the host DETACHES an item (unequipped, dropped, the wearer
-- died and was moved away) the client's copy keeps naming the old parent,
-- while the game's own code on this machine has already let go of it. Putting
-- it back every second fought the game (2937 lines in one session: a swapped
-- respirator, a dead character's gear for its last 60 s, the gear of a player
-- 500 m away) and never held. It is put back only when the game's own
-- replicated state says the item is worn there: listed in that character's
-- equipment (HelperComp.RepActorsData), the character alive and in range, the
-- item not dropped (simulating physics). A put-back that does not hold is
-- tried again after 1, 2, 4, 8 s, at most REATTACH_MAX times; one log line per
-- item and cause.
local REATTACH_MAX = 5
local REATTACH_RANGE = 15000     -- cm: farther, the item is out of the client's relevance anyway
local reattach = {}              -- [item address] = { name =, key = want parent|socket, tries =, next_at =, done = }
local reattach_said = {}         -- ["item name|cause"] = true

local function reattach_note(a, cause, fmt, ...)
    local k = ue.name(a) .. "|" .. cause
    if reattach_said[k] then return end
    reattach_said[k] = true
    log.info(fmt, ...)
end

-- Why the item must stay where the game has it on this machine, or nil.
local function reattach_block(a, want, wearer)
    if is_player_character(want) then
        if not ue.valid(wearer) or addr(wearer) ~= addr(want) then
            return "not in the equipment of " .. ue.short(want) .. " (unequipped / dropped on the host)"
        end
        if ue.prop(want, "PlayerDead?") == true then return ue.short(want) .. " is dead" end
        local me = ue.local_pawn()
        local lm, lw = me and ue.location(me), ue.location(want)
        if lm and lw and addr(me) ~= addr(want) and dist2(lm, lw) > REATTACH_RANGE * REATTACH_RANGE then
            return ue.short(want) .. " is out of range"
        end
    end
    local root = ue.prop(a, "RootComponent")
    if ue.try(function() return root:IsSimulatingPhysics() end) == true then return "dropped (simulating physics)" end
    return nil
end

local function follow_attachment(a, wearer)
    local rep = ue.prop(a, "AttachmentReplication")
    if not rep then return end
    local want = ue.try(function() return rep.AttachParent end)
    local k = addr(a)
    if not ue.valid(want) or not k then return end
    local cur = attach_parent(a)
    local want_socket = ue.str(ue.try(function() return rep.AttachSocket end))
    local cur_socket = ue.str(ue.try(function() return a:GetAttachParentSocketName() end))
    local name = ue.name(a)
    local st = reattach[k]
    if st and st.name ~= name then st = nil end   -- (another actor at this address)
    if st then st.seen = os.clock() end
    if addr(cur) == addr(want) and want_socket == cur_socket then
        if st and st.tries > 0 then
            log.debug("items: %s stays on %s/%s after %d put-back(s)", ue.short(a), ue.short(want), want_socket, st.tries)
        end
        reattach[k] = nil
        return
    end
    local cause = reattach_block(a, want, wearer)
    if cause then
        M.stats.reattach_skipped = (M.stats.reattach_skipped or 0) + 1
        reattach_note(a, cause, "items: %s not put back on %s/%s (now %s/%s): %s - left as the game has it",
            ue.short(a), ue.short(want), want_socket, ue.short(cur), cur_socket, cause)
        return
    end
    local key = tostring(addr(want)) .. "|" .. want_socket
    if not st or st.key ~= key then
        st = { name = name, key = key, tries = 0, next_at = 0, seen = os.clock() }
        reattach[k] = st
    end
    local now = os.clock()
    if st.done or now < st.next_at then return end
    if st.tries >= REATTACH_MAX then
        st.done = true
        M.stats.reattach_gave_up = (M.stats.reattach_gave_up or 0) + 1
        reattach_note(a, "gave up " .. key, "items: %s does not stay on %s/%s (%d put-backs, now %s/%s) - left as the game has it",
            ue.short(a), ue.short(want), want_socket, st.tries, ue.short(cur), cur_socket)
        return
    end
    if pcall(function() a:OnRep_AttachmentReplication() end) then
        st.tries = st.tries + 1
        st.next_at = now + 2 ^ (st.tries - 1)
        M.stats.reattached = M.stats.reattached + 1
        local line = string.format("items: %s put back on %s/%s (was %s/%s, try %d)", ue.short(a), ue.short(want),
            want_socket, ue.short(cur), cur_socket, st.tries)
        if st.tries == 1 then log.info("%s", line) else log.debug("%s", line) end
    end
end

-- First-person view hides the owner's head items with SetActorHiddenInGame.
-- bHidden is a replicated actor flag, so when the HOST switched view its
-- helmet vanished on every client until the mod showed it again (a visible
-- blink), and the host's copy of a client could hide that client's items for
-- everyone. Before the call runs:
--   * items on someone else's character are never hidden;
--   * the host's own items are hidden per component instead (not replicated).
local function on_set_hidden(c, new_hidden)
    if S.role ~= "host" and S.role ~= "client" then return end
    local a = c and c:get()
    if not ue.valid(a) or not new_hidden then return end
    local cls = ue.class_name(a)
    if not cls:find("Pickup", 1, true) or cls:find("FishingRod", 1, true) then return end
    local parent = attach_parent(a)
    if not is_player_character(parent) or not M.visible_scale(a) then return end
    local ok, want = pcall(function() return new_hidden:get() end)
    if not ok then return end
    want = want == true
    if is_locally_controlled(parent) then
        if S.role == "host" and ue.prop(a, "bReplicates") == true then
            pcall(function() new_hidden:set(false) end)
            local root = ue.prop(a, "RootComponent")
            pcall(function() root:SetHiddenInGame(want, true) end)
        end
    elseif want then
        pcall(function() new_hidden:set(false) end)
    end
end

local hide_hooked = false
local function hook_hidden()
    if hide_hooked then return end
    hide_hooked = true
    local ok, err = ue.hook_native("/Script/Engine.Actor:SetActorHiddenInGame", "items.hidden", on_set_hidden)
    log.info("items: first-person hide hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- The game's per-slot OnRep (BP_PlayerCharacter). On a client they run when
-- the slot flag replicates, which is often before the item actor itself has
-- arrived, so the local part of equipping (hair hidden under a helmet,
-- holstering, first-person hiding...) never happened: the head showed
-- through the helmet until the host re-equipped it. Re-run them once the
-- actors are there: on HelperComp.OnRep_RepActorsData (see the event hooks
-- below), and on the 1 s client tick as a safety net.
-- Not the flashlight: FlashlightEquipped? has no RepNotify and the game never
-- calls OnRep_FlashlightEquipped? (equipping hides the item and leaves it
-- unattached, JigMP_OnPickupEquipped @2705-2848); running it would attach the
-- hidden item to a holster socket on this machine only.
local ONREP = {
    ["Jig.PlayerSlot.PrimaryWeapon"]   = { "PrimaryWeaponEquipped?",   "OnRep_PrimaryWeaponEquipped?",   weapon = true },
    ["Jig.PlayerSlot.SecondaryWeapon"] = { "SecondaryWeaponEquipped?", "OnRep_SecondaryWeaponEquipped?", weapon = true },
    ["Jig.PlayerSlot.SidearmWeapon"]   = { "SidearmWeaponEquipped?",   "OnRep_SidearmWeaponEquipped?",   weapon = true },
    ["Jig.PlayerSlot.MeleeWeapon"]     = { "MeleeWeaponEquipped?",     "OnRep_MeleeWeaponEquipped?",     weapon = true },
    ["Jig.PlayerSlot.Headwear"]        = { "HeadwearEquipped?",        "OnRep_HeadwearEquipped?" },
    ["Jig.PlayerSlot.Eyewear"]         = { "EyewearEquipped?",         "OnRep_EyewearEquipped?" },
    ["Jig.PlayerSlot.Facewear"]        = { "FacewearEquipped?",        "OnRep_FacewearEquipped?" },
    ["Jig.PlayerSlot.Accessory"]       = { "AccessoryEquipped?",       "OnRep_AccessoryEquipped?" },
    ["Jig.PlayerSlot.Backpack"]        = { "BackpackEquipped?",        "OnRep_BackpackEquipped?" },
    ["Jig.PlayerSlot.Container"]       = { "ContainerEquipped?",       "OnRep_ContainerEquipped?" },
    ["Jig.PlayerSlot.Throwable"]       = { "ThrowableEquipped?",       "OnRep_ThrowableEquipped?" },
    ["Jig.PlayerSlot.FishingRod"]      = { "FishingRodEquipped?",      "OnRep_FishingRodEquipped?" },
}

local equip_sig = {}   -- [pawn address] = signature of equipped actors last handled

local function rerun_onreps(pawn, own, why)
    local eq = equipped_of(pawn)
    local parts = {}
    for k, it in pairs(eq) do parts[#parts + 1] = it.slot .. "=" .. tostring(k) end
    table.sort(parts)
    local sig = table.concat(parts, ";")
    local pk = addr(pawn)
    if equip_sig[pk] == sig then return end
    equip_sig[pk] = sig
    local ran = {}
    for _, it in pairs(eq) do
        local o = ONREP[it.slot]
        if o and not (own and o.weapon) and ue.prop(pawn, o[1]) == true then
            if pcall(function() pawn[o[2]](pawn) end) then ran[#ran + 1] = it.slot:gsub("Jig%.PlayerSlot%.", "") end
        end
    end
    if #ran > 0 then
        log.info("items: re-ran equip logic of %s%s for %s (%s)", ue.short(pawn), own and " (own)" or "",
            table.concat(ran, ","), why or "tick")
    end
end

-- Client: the hotbar highlight. On a key press the game sends
-- SERVER_ChangeActiveSlot and right away reads the active slot to colour the
-- hotbar (ActionBarEquipUI). In single player the slot has already changed;
-- on a client the answer is still on its way, so the highlight came out
-- inverted (off while the knife is drawn, on after putting it away). Repaint
-- it with the game's own function whenever the replicated active slot
-- changes: from HelperComp.OnRep_ActiveWeapon (event hook below), and from
-- main.lua's poll as a safety net (it repaints only what the event missed).
local hotbar_last = nil
function M.hotbar_tick(why)
    if S.role ~= "client" then return end
    local me = ue.local_pawn()
    if not me then
        hotbar_last = nil
        return
    end
    local helper = ue.prop(me, "BP_JigHelperComp")
    if not ue.valid(helper) or not ue.valid(ue.prop(me, "InGameUI")) then return end
    local tag = ue.str(ue.try(function() return helper.ActiveWeapon.TagName end))
    if tag == "" then return end
    local key = tostring(addr(me)) .. "|" .. tag
    if key == hotbar_last then return end
    hotbar_last = key
    local none = tag == "None"
    local ok, err = pcall(function() me:ActionBarEquipUI(none, { TagName = FName(tag) }) end)
    log.debug("items: hotbar repainted for active slot %s (%s, ok=%s%s)", tag, why or "poll", tostring(ok),
        ok and "" or (" " .. tostring(err)))
    if not ok then log.err_throttled("hotbar", "items: hotbar repaint failed: %s", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Client: the game's own replication events as triggers
-- ---------------------------------------------------------------------------
-- Instead of the next poll (0.2-1 s of a visible flash or snap):
--   HelperComp.OnRep_ActiveWeapon  -> hotbar repaint
--   HelperComp.OnRep_RepActorsData -> re-run the slot OnReps once the item
--       actors are there (the engine fires it again when late actor
--       references resolve), then put the items where the host has them
--   BP_PlayerCharacter.OnRep_<weapon>Equipped? -> right after the game's own
--       re-holstering (EquipActorToSocket: holster socket, and the backpack
--       variant reads server-only data), back to where the host has the item
-- Post-hooks of BP functions run after the function body, in the same frame.
local EVENT_HOOKS = {
    { HELPER_FN .. "OnRep_ActiveWeapon", "hotbar" },
    { HELPER_FN .. "OnRep_RepActorsData", "actors" },
    { PLAYER_FN .. "OnRep_PrimaryWeaponEquipped?", "weapon" },
    { PLAYER_FN .. "OnRep_SecondaryWeaponEquipped?", "weapon" },
    { PLAYER_FN .. "OnRep_SidearmWeaponEquipped?", "weapon" },
    { PLAYER_FN .. "OnRep_MeleeWeaponEquipped?", "weapon" },
    { PLAYER_FN .. "OnRep_FishingRodEquipped?", "weapon" },
}
local event_hooked = {}   -- [path] = true
M.events = { hotbar = 0, actors = 0, weapon = 0 }

-- Worn items of a replicated character: inert and where the host has them.
local function settle_items(pawn)
    for _, it in pairs(equipped_of(pawn)) do
        local a = it.actor
        if ue.valid(a) and ue.role(a) == ue.ROLE_SIMULATED then
            make_inert(a)
            follow_attachment(a, pawn)
        end
    end
end

local function helper_owner(c)
    local helper = c and c:get()
    if not ue.valid(helper) then return nil end
    local p = ue.try(function() return helper:GetOwner() end)
    if is_replicated_character(p) then return p end
    return nil
end

local EVENT_FN = {
    hotbar = function(c)
        local p = helper_owner(c)
        if not p or not is_locally_controlled(p) then return end
        M.events.hotbar = M.events.hotbar + 1
        M.hotbar_tick("event")
    end,
    actors = function(c)
        local p = helper_owner(c)
        if not p then return end
        M.events.actors = M.events.actors + 1
        rerun_onreps(p, is_locally_controlled(p), "event")
        settle_items(p)
    end,
    weapon = function(c)
        local p = c and c:get()
        if not is_replicated_character(p) then return end
        M.events.weapon = M.events.weapon + 1
        settle_items(p)
    end,
}

local function try_hook_events()
    for _, h in ipairs(EVENT_HOOKS) do
        local path, kind = h[1], h[2]
        if not event_hooked[path] then
            local fn = EVENT_FN[kind]
            local ok = pcall(RegisterHook, path, function(c)
                if S.role ~= "client" then return end
                local okc, err = pcall(fn, c)
                if not okc then log.err_throttled("items.ev." .. kind, "items: %s event hook: %s", kind, tostring(err)) end
            end)
            if ok then
                event_hooked[path] = true
                log.info("items: event hook ok (%s)", path:match(":([%w_%?]+)$") or path)
            end
        end
    end
end

-- Client: nothing attached to the own character may collide. The character's
-- position zig-zagged back a few cm every couple of frames while velocity
-- pointed forward: the capsule being pushed out of something that moves with
-- it. The capsule sweep ignores the character's own components but not
-- separate attached actors (worn items arrive from the host with pickup
-- collision; weapon modules - scopes, mags, lasers - are local actors
-- attached to the weapon). The host has no such problem: its game turns
-- worn items' collision off on the server.
local collision_logged = {}
local COLL_NONE = 0
function M.own_attached_no_collision(pawn)
    local root = ue.try(function() return pawn:K2_GetRootComponent() end)
    if not ue.valid(root) then return end
    local pawn_name = ue.name(pawn)
    local changed = 0
    local function walk(comp, depth)
        if depth > 10 then return end
        local n = ue.try(function() return comp:GetNumChildrenComponents() end)
        if type(n) ~= "number" then return end
        for i = 0, n - 1 do
            local child = ue.try(function() return comp:GetChildComponent(i) end)
            if ue.valid(child) then
                local owner = ue.try(function() return child:GetOwner() end)
                if ue.valid(owner) and ue.name(owner) ~= pawn_name then
                    local coll = ue.try(function() return child:GetCollisionEnabled() end)
                    if type(coll) == "number" and coll ~= COLL_NONE then
                        local resp = ue.try(function() return child:GetCollisionResponseToChannel(2) end)
                        pcall(function() child:SetCollisionEnabled(COLL_NONE) end)
                        changed = changed + 1
                        local key = ue.class_name(owner) .. "." .. ue.short(child)
                        if not collision_logged[key] then
                            collision_logged[key] = true
                            log.info("items: collision off on %s.%s attached to the own character (was %s, pawn response %s)",
                                ue.class_name(owner), ue.short(child), tostring(coll), tostring(resp))
                        end
                    end
                end
                walk(child, depth + 1)
            end
        end
    end
    walk(root, 0)
    return changed
end

-- ---------------------------------------------------------------------------
-- Client: no loot from the client's own copy of the level
-- ---------------------------------------------------------------------------
-- BP_JigRandomSpawner.ReceiveBeginPlay: HasAuthority() -> SpawnItems() ->
-- K2_DestroyActor(). The spawner is a level-placed actor that does not
-- replicate, so on a client it IS the authority of its own copy and spawns
-- its own random loot next to the host's replicated items. A native pre-hook
-- on GameplayStatics.BeginDeferredActorSpawnFromClass swaps the class for
-- UObject when such a spawner asks: TSubclassOf<AActor> / SpawnActor refuse a
-- non-actor class and return None, SpawnItems checks IsValid and skips the
-- item, and the spawner still destroys itself. The net mode is read from the
-- spawner's own world: during a client's map load S.role can still be stale.
-- Config prevent_client_loot (off: only the cleanup in client_tick).
local SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
local NOT_AN_ACTOR = "/Script/CoreUObject.Object"
local loot_block = { cls = nil, pending = 0, at = 0, logged = 0, failed = false }

local function is_loot_spawner(o)
    return ue.class_name(o):find("^BP_JigRandomSpawner") ~= nil
end

local function world_is_client(o)
    local ksl = ue.ksl()
    if not ksl then return false end
    local oks, standalone = pcall(function() return ksl:IsStandalone(o) end)
    if not oks or standalone == true then return false end
    local ok, server = pcall(function() return ksl:IsServer(o) end)
    return ok and server == false
end

local function on_deferred_spawn(_, wco_p, class_p)
    if not wco_p or not class_p or loot_block.failed then return end
    if S.role == "host" then return end
    if not cfg.get("prevent_client_loot") or not cfg.get("replicate_items") then return end
    local okw, wco = pcall(function() return wco_p:get() end)
    if not okw or not ue.valid(wco) or not is_loot_spawner(wco) then return end
    if not world_is_client(wco) then return end
    if not ue.valid(loot_block.cls) then loot_block.cls = ue.find_object(NOT_AN_ACTOR) end
    if not loot_block.cls then return end
    local okc, item = pcall(function() return class_p:get() end)
    local ok, err = pcall(function() class_p:set(loot_block.cls) end)
    if not ok then
        -- never retried: the cleanup in client_tick removes the loot instead
        loot_block.failed = true
        log.warn("items: cannot block client loot spawns (%s); local loot is removed after spawning instead", tostring(err))
        return
    end
    M.stats.loot_blocked = M.stats.loot_blocked + 1
    loot_block.pending = loot_block.pending + 1
    if loot_block.logged < 3 then
        loot_block.logged = loot_block.logged + 1
        log.info("items: client loot spawn blocked (%s from %s)", okc and ue.short(item) or "?", ue.short(wco))
    end
end

local spawn_hooked = false
local function hook_loot_spawns()
    if spawn_hooked then return end
    spawn_hooked = true
    local ok, err = ue.hook_native(SPAWN_FN, "items.loot", function(c, wco_p, class_p)
        local okc, e = pcall(on_deferred_spawn, c, wco_p, class_p)
        if not okc then log.err_throttled("items.loot-block", "items: loot spawn hook: %s", tostring(e)) end
    end)
    log.info("items: client loot spawn hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- Hidden worn items (flashlight...) already reported as arrived, by full name.
local hidden_item_logged = {}

-- What the client removes as "local loot", per class (for the log).
local ghost_classes = {}
local ghost_log = { pending = 0, at = 0 }

-- Pickups that had nothing to do last time (lying in the world: replicated,
-- not worn, not attached; or a local item that stays) are looked at again
-- only after a few seconds: every pickup of the level costs ~8 engine calls,
-- and a client has hundreds to thousands of them. An item a character wears
-- now (its RepActorsData) is always looked at. The table is rebuilt every
-- pass (only items of this pass stay in it).
local quiet = {}            -- [item address] = os.clock() until which it is skipped
local QUIET_MIN_S, QUIET_SPREAD = 2, 4   -- 2..5 s, spread so they do not all come back at once
M.stats.quiet_skipped = 0

-- Client tick (1 s).
function M.client_tick()
    consume_tick(consume.client_tick)
    consume_tick(stations.client_tick)
    consume_tick(tools.client_tick)
    consume_tick(wear.client_tick)
    consume_tick(containers.client_tick)
    try_hook_durability()
    try_hook_battery()
    try_hook_events()
    apply_uids()
    if loot_block.pending > 0 and os.time() - loot_block.at >= 30 then
        log.info("items: %d client loot spawn(s) blocked (total %d)", loot_block.pending, M.stats.loot_blocked)
        loot_block.pending, loot_block.at = 0, os.time()
    end
    local own_head = {}
    local own_fp = false
    local me = ue.local_pawn()
    local my_loc = me and ue.location(me)
    if me then
        own_fp = ue.prop(me, "PlayerInFirstPerson?") == true
        for k, it in pairs(equipped_of(me)) do
            if HEAD_SLOTS[it.slot] then own_head[k] = true end
        end
    end

    local players_now = {}
    local worn = {}   -- [item address] = slot tag, items worn by replicated characters
    local wearer = {} -- [item address] = the character whose equipment lists it
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        local l = ue.location(p)
        if l then players_now[#players_now + 1] = l end
        -- replicated characters only (not the hidden stale local copy)
        if is_replicated_character(p) then
            rerun_onreps(p, is_locally_controlled(p), "tick")
            for k, it in pairs(equipped_of(p)) do
                worn[k] = it.slot
                wearer[k] = p
            end
        end
    end

    local seen, alive = {}, {}
    local ghosts = 0
    local now_c = os.clock()
    local next_quiet, nq = {}, 0
    for _, a in ipairs(all_pickups()) do
        local k = addr(a)
        local q = k and quiet[k]
        if q and now_c < q and not worn[k] and not inert[k] then
            next_quiet[k] = q
            M.stats.quiet_skipped = M.stats.quiet_skipped + 1
            goto next_item
        end
        do
        if ue.valid(a) then alive[k] = a end
        local role = ue.role(a)
        local parent = attach_parent(a)
        local busy = false
        if role == ue.ROLE_SIMULATED then
            -- worn: attached, or (the hidden flashlight / binoculars) only in
            -- the character's RepActorsData; inert like on the host, where
            -- JigSetCanInteract(false, false) switched collision off
            if worn[k] or is_player_character(parent)
                or ue.valid(ue.try(function() return ue.prop(a, "AttachmentReplication").AttachParent end)) then
                busy = true
                seen[k] = true
                if NEVER_SHOWN[worn[k] or ""] and not hidden_item_logged[ue.name(a)] then
                    hidden_item_logged[ue.name(a)] = true
                    log.info("items: %s (%s, kept hidden by the game) has arrived (hidden=%s)", ue.short(a),
                        (worn[k]:gsub("^Jig%.PlayerSlot%.", "")), tostring(ue.prop(a, "bHidden")))
                end
                make_inert(a)
                follow_attachment(a, wearer[k])
                parent = attach_parent(a)
                if is_player_character(parent) then
                    if is_locally_controlled(parent) then
                        if own_fp and own_head[k] and ue.prop(a, "bHidden") ~= true then
                            pcall(function() a:SetActorHiddenInGame(true) end)
                        end
                    -- (scale 0 of the flashlight is not replicated: by slot)
                    elseif ue.prop(a, "bHidden") == true and M.visible_scale(a) and not NEVER_SHOWN[worn[k] or ""]
                        and not ue.class_name(a):find("FishingRod", 1, true) then
                        pcall(function() a:SetActorHiddenInGame(false) end)
                        M.stats.unhidden = M.stats.unhidden + 1
                    end
                end
            end
        elseif role == ue.ROLE_AUTHORITY and cfg.get("replicate_items") and ue.is_runtime_spawned(a)
            and not is_local_attachment(a) and not ue.valid(parent) then
            -- loot spawned by this client's own copy of the level. Kept: the
            -- game's own per-machine helpers (each machine spawns a local
            -- flashlight actor for every character), anything with an owner,
            -- anything close to a player character.
            local cls = ue.class_name(a)
            local d = math.sqrt(dist2(ue.location(a), my_loc))
            local near_player = false
            for _, p in ipairs(players_now) do
                if dist2(ue.location(a), p) < 500 * 500 then near_player = true break end
            end
            local owned = ue.valid(ue.try(function() return a:GetOwner() end))
            local rec = ghost_classes[cls] or { removed = 0, kept = 0 }
            ghost_classes[cls] = rec
            if near_player or owned or cls:find("Flashlight", 1, true) then
                if rec.kept == 0 then
                    log.info("items: kept local %s (%.0f cm from own character, owner=%s)", cls, d, tostring(owned))
                end
                rec.kept = rec.kept + 1
            else
                if rec.removed < 3 then
                    log.info("items: removing local loot %s (%.0f cm away)", cls, d)
                end
                rec.removed = rec.removed + 1
                pcall(function() a:K2_DestroyActor() end)
                ghosts = ghosts + 1
                busy = true
            end
        end
        if k and not busy and not inert[k] then
            nq = nq + 1
            next_quiet[k] = now_c + QUIET_MIN_S + (nq % QUIET_SPREAD)
        end
        end
        ::next_item::
    end
    quiet = next_quiet
    -- put-back records of items no longer looked at (gone, destroyed)
    for rk, st in pairs(reattach) do
        if now_c - (st.seen or 0) > 120 then reattach[rk] = nil end
    end
    -- Items no longer worn: restore those that still exist (dropped). One that
    -- is gone from the live list (picked up / destroyed), or whose address now
    -- belongs to another actor, is forgotten without touching anything.
    for k, rec in pairs(inert) do
        if not seen[k] then
            local a = alive[k]
            if a and ue.valid(a) and ue.name(a) == rec.name then restore(k, rec, a) else inert[k] = nil end
        end
    end
    -- after make_inert has recorded the items' own collision (restored on drop)
    if me then M.own_attached_no_collision(me) end
    if ghosts > 0 then
        M.stats.ghosts_removed = M.stats.ghosts_removed + ghosts
        ghost_log.pending = ghost_log.pending + ghosts
    end
    -- the client's own spawners can keep producing loot: one line per 30 s
    if ghost_log.pending > 0 and os.time() - ghost_log.at >= 30 then
        log.info("items: removed %d local loot item(s) of this client's own level copy (total %d)",
            ghost_log.pending, M.stats.ghosts_removed)
        ghost_log.pending, ghost_log.at = 0, os.time()
    end
end

-- Debug: where the head, the head bone and head items are, relative to each
-- character (compare the same character on host and client).
local function rel(v, base)
    if not v or not base then return "?" end
    local ok, s = pcall(function() return string.format("%.1f,%.1f,%.1f", v.X - base.X, v.Y - base.Y, v.Z - base.Z) end)
    return ok and s or "?"
end

function M.debug_head_report(tag)
    for _, p in ipairs(ue.find_all("BP_PlayerCharacter_C")) do
        local base = ue.location(p)
        local mesh = ue.prop(p, "Mesh")
        local bone = nil
        for _, b in ipairs({ "head", "Head", "neck_01" }) do
            bone = ue.try(function() return mesh:GetSocketLocation(FName(b)) end)
            if bone and (bone.X ~= 0 or bone.Y ~= 0) then break end
        end
        local head = ue.prop(p, "Head")
        local head_loc = ue.try(function() return head:K2_GetComponentLocation() end)
        log.info("headdbg %s %s local=%s fp=%s headbone=%s headmesh=%s hidden=%s leader=%s anim=%s", tag, ue.short(p),
            tostring(is_locally_controlled(p)), tostring(ue.prop(p, "PlayerInFirstPerson?")),
            rel(bone, base), rel(head_loc, base), tostring(ue.prop(head, "bHiddenInGame")),
            ue.short(ue.prop(head, "LeaderPoseComponent")), ue.short(ue.try(function() return mesh:GetAnimInstance() end)))
        for _, it in pairs(equipped_of(p)) do
            if HEAD_SLOTS[it.slot] then
                local a = it.actor
                local root = ue.prop(a, "RootComponent")
                local rl, rr, rs = ue.prop(root, "RelativeLocation"), ue.prop(root, "RelativeRotation"), ue.prop(root, "RelativeScale3D")
                log.info("headdbg %s   %s %s socket=%s world=%s rel=%s rot=%s scale=%s hidden=%s role=%d", tag, it.slot:gsub("Jig.PlayerSlot.", ""),
                    ue.short(a), ue.str(ue.try(function() return a:GetAttachParentSocketName() end)),
                    rel(ue.location(a), base), rel(rl, { X = 0, Y = 0, Z = 0 }),
                    rr and ue.try(function() return string.format("%.1f,%.1f,%.1f", rr.Pitch, rr.Yaw, rr.Roll) end) or "?",
                    rel(rs, { X = 0, Y = 0, Z = 0 }), tostring(ue.prop(a, "bHidden")), ue.role(a))
            end
        end
    end
end

-- Debug (client): the melee durability lookup done by the game itself
-- (GetEquipmentUID -> BP_JigMultiplayer.GetDurability over MainJigContainers).
function M.debug_durability()
    local me = ue.local_pawn()
    if not me then return end
    local helper = ue.prop(me, "BP_JigHelperComp")
    local jig = ue.prop(me, "BP_JigMultiplayer")
    local melee = nil
    local okm, errm = pcall(function()
        helper.EquipmentUIDs:ForEach(function(k, v)
            local key, val = k:get(), v:get()
            if ue.str(key.TagName) == "Jig.PlayerSlot.MeleeWeapon" then
                melee = string.format("%d:%d:%d:%d", val.A, val.B, val.C, val.D)
            end
        end)
    end)
    local nc, ni, found = 0, 0, nil
    local sample = {}
    local ok, err = pcall(function()
        jig.MainJigContainers:ForEach(function(_, c)
            nc = nc + 1
            local cont = c:get()
            cont[F_ITEMS]:ForEach(function(_, it)
                ni = ni + 1
                local item = it:get()
                local u = item[F_USID]
                local us = string.format("%d:%d:%d:%d", u.A, u.B, u.C, u.D)
                local d = item[F_INFO][F_DUR]
                local ds = string.format("%.1f/%.1f", d.X, d.Y)
                if us == melee then found = ds end
                if #sample < 8 then sample[#sample + 1] = us .. "=" .. ds end
            end)
        end)
    end)
    log.info("durdbg melee uid=%s (map ok=%s%s) containers=%d items=%d found=%s (ok=%s%s) sample=[%s]",
        tostring(melee), tostring(okm), okm and "" or (" " .. tostring(errm)), nc, ni, tostring(found),
        tostring(ok), ok and "" or (" " .. tostring(err)), table.concat(sample, " "))
end

function M.reset()
    equip_sig = {}
    reattach, reattach_said = {}, {}
    pending, recent, inert, caught = {}, {}, {}, {}
    hotbar_last = nil
    uids_sent, client_uids = {}, { text = nil, applied = nil, dur = {} }
    items_sent, client_items = {}, { dur = {}, bat = {}, n = 0 }
    -- (delayed player parts and level slices of the old session stop)
    pass_gen = pass_gen + 1
    lvl.known, lvl.cand, lvl.pass, lvl.dirty, lvl.gen = {}, {}, nil, true, lvl.gen + 1
    consume.reset()
    stations.reset()
    tools.reset()
    wear.reset()
    containers.reset()
end

-- Client: durability / battery of an item as the host reports it.
function M.reported(uid)
    return client_items.dur[uid], client_items.bat[uid]
end

-- Client: the UID ("A:B:C:D", as ITEMS / reported use it) of the item in one
-- of the own equipment slots ("Jig.PlayerSlot.Flashlight"), from the host's
-- last UIDS; nil = empty slot or nothing from the host yet (sdc_hudmods: the
-- flashlight's battery / the mask's filter for the HUD). Parsed once per UIDS.
function M.own_slot_uid(tag)
    local s = client_uids.text
    if not s or s == "" then return nil end
    if client_uids.slots_of ~= s then
        local slots = {}
        for entry in s:gmatch("[^;]+") do
            local t, a, b, c, d = entry:match("^([^=]+)=(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)")
            if t and not (a == "0" and b == "0" and c == "0" and d == "0") then
                slots[t] = string.format("%s:%s:%s:%s", a, b, c, d)
            end
        end
        client_uids.slots, client_uids.slots_of = slots, s
    end
    return client_uids.slots[tag]
end

-- Client: the host's new durability of an own item (its CLIENT_UpdateDurability,
-- sdc_wear), read until the next ITEMS brings the same.
function M.set_reported(uid, x)
    if type(x) == "number" and client_items.dur[uid] ~= nil then client_items.dur[uid] = x end
end

-- Client: the UIDs of the own inventory as the host has it ([uid] = durability),
-- how many, and os.clock() of the last ITEMS message (nil before the first).
function M.host_item_uids()
    return client_items.dur, client_items.n, client_items.at
end

-- Host: runtime pickups spawned at or after os.clock() `since`, oldest first
-- (sdc_consume: the drop of a server-side add for a remote player).
function M.recent_pickups(since)
    local out = {}
    for _, e in ipairs(recent) do
        if e.t >= since and ue.valid(e.obj) then out[#out + 1] = e.obj end
    end
    return out
end

function M.register_handlers()
    -- host -> client: UIDS|<slot tag>=A:B:C:D;...   (the client's own equipment)
    net.on("UIDS", function(f)
        client_uids.text = f[1] or ""
        client_uids.applied = nil
        apply_uids()
    end)
    -- host -> client: ITEMS|<uid>=<durability>[/<battery>];...   (the client's own inventory)
    net.on("ITEMS", function(f) apply_items(f[1]) end)
    consume.register_handlers()
    stations.register_handlers()
    tools.register_handlers()
    wear.register_handlers()
    containers.register_handlers()
end

-- ===========================================================================
-- Watches
-- ===========================================================================

function M.install()
    local watched = 0
    for _, cls in ipairs(PICKUP_CLASSES) do
        local ok, err = pcall(NotifyOnNewObject, cls, function(obj)
            -- (any role) a new pickup at an address the level check remembers:
            -- what it knew was about the object that lived there before
            local k = addr(obj)
            if k ~= nil and lvl.known[k] ~= nil then lvl.known[k], lvl.cand[k] = nil, nil end
            if S.role ~= "host" then return end
            local e = { obj = obj, t = os.clock() }
            pending[#pending + 1] = e
            if #recent < 200 then recent[#recent + 1] = e end
            if not flush_scheduled then
                flush_scheduled = true
                ue.delay("items-flush", 30, flush)
            end
        end)
        log.info("items: watching new %s %s%s", cls:match("([%w_]+)$"), ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
        if ok then watched = watched + 1 end
    end
    -- without both watches the level check trusts nothing it remembers
    lvl.watch = watched == #PICKUP_CLASSES
    hook_hidden()
    -- native function: hookable at start, before the client's first map load
    hook_loot_spawns()
end

return M
