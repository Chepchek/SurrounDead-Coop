-- SDCoop: damage of remote players' weapons, computed on the host.
--
-- A client's firearm hit reaches the host as BP_FirearmPickup.SERVER_DamageEvent
-- (ubergraph 3691 headshot / 4610 body): DamageMultiplier -> EffectiveDamage ->
-- CriticalHit -> ApplyDamage -> Client_HitUI. A client's knife swing runs on
-- the host too (the attack montage is multicast; AnimNotify_MeleeHitDetect
-- starts BP_MeleePickup.MeleeTrace there; HitBody/HitHead -> ApplyDamage).
-- Every one of those asks FindStat for the weapon's numbers, and FindStat
-- reads the INVENTORY WIDGET of GetPlayerCharacter(0):
--   BP_FirearmPickup.FindStat@0..397 / BP_MeleePickup.FindStat@0..415
--     -> BP_JigComponent.JigComp_GetInventoryWidgetRef (= InventoryWidgetRef)
--     -> BP_MainJigInventory.GetJSIContainerByPlayerSlots (the first container
--        whose ContainerTag == slot; its ArrayOfItems[0] if it is EquipTo)
--     -> JSI_Slot_C.GetStatByName: first entry of JSI_Slot_C.ItemStats with
--        that STAT_NAME (S_ItemStat {STAT_NAME, Prefix, MinValue, MaxValue, Txt})
-- The host has no inventory widget for a client's character, so all stats
-- came back unset and a client's hit did ~0-1 damage.
--
-- What the widget holds, in order of preference here:
--   1. the host's copy of the item record (the server's authoritative data:
--      stat edits go through BP_JigComponent.BulkUpdateStats / UpdateStatByUID
--      on these records and reach the client UI by CLIENT_OnStatsUpdated):
--      JSI_Slot_C.SetDynamicInfo@395
--      sets the data asset's ItemStats, then BP_JigComponent calls
--      UpdateStats(ItemInfo.Stats) UNCONDITIONALLY (2398/6536/7324/7372/12444)
--      with the record the server keeps in the owner's
--      BP_JigMultiplayer.MainJigContainers[].ContainerItems[].ItemInfo.Stats.
--      So an item whose record has an empty Stats array has no stats at all:
--      every FindStat answers not found (false, 1, 1), like single player.
--        weapon actor -> its slot (owner's BP_JigHelperComp.RepActorsData)
--        -> item UID (BP_JigHelperComp.EquipmentUIDs[slot])
--        -> item record in MainJigContainers -> stats
--      Fallbacks: BP_JigHelperComp.ServerEquippedItems.<slot> (set with the
--      UID by SetEquippedInfoBySlot), then the weapon's own
--      BP_JigMultiplayer.PickupInfo.ItemInfo (BP_JigHelperComp.OnMainAdded@2363).
--      The host's copy is re-read every REFRESH_S (records can change in place).
--   2. the client's own numbers (WSTAT): the client reads its widget, i.e.
--      exactly what single player would use. Used when the host cannot read
--      the record, or always with config client_weapon_stats = true (the
--      pre-0.6.3 order). A difference to the host's record is logged once per
--      item and report; in 0.6.2 tests the two always matched.
-- Min/max as the game returns them: the firearm swaps them
-- (MinValue = Stat.MaxValue, FindStat@485/550), the knife does not (@503/568).
--
-- Also for remote players' weapons on the host:
--   * Range fall-off: EffectiveDamage divides self.ShotDistance, which only
--     FireTrace on the shooter's machine sets (FireTrace@2232). The host's
--     copy kept 0, so clients had no fall-off. It is set from the hit in
--     AISense_Damage.ReportDamageEvent, which the game calls between the
--     first EffectiveDamage (AI report) and the one ApplyDamage uses. Not for
--     projectile weapons (crossbow bolts): they never run FireTrace, their
--     ShotDistance stays 0 in single player as well.
--   * Skill XP the game grants only on the server (see XP_FUNCS): it lands on
--     the host's copy of the client's PassiveSkillsComponent (no replicated
--     variables, no RPCs), never on the client. The host adds it up per player
--     and skill and sends it as DXP; the client calls its own AddXP_<skill>.
--     Likewise the death reset (BP_PlayerCharacter.AfterDeath@579
--     ResetPassiveSkills, gated by Difficulty.ResetPassiveSkills) -> SKRESET.
--     Config relay_skill_xp.
--   * weapon.PassiveSkillsComponent (BeginPlay@6313 via player 0) is pointed
--     at the owner's controller even when the player-0 redirection missed it
--     (otherwise the host got the client's XP), and that component's
--     StrengthMultiplier (knife damage, BP_MeleePickup.DamageCalc@670) is set
--     to the client's own value (SKL).
-- Not fixed: CriticalHit asks GetSkillTreeManager (player 0 -> the host's copy
-- of the client's controller) whether Skill_CriticalHitter is unlocked.
--
-- No UObject is kept in a table: entries hold addresses and names only, and
-- every object is looked up again (and checked with ue.valid) when used.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local items = require("sdc_items")
local consume = require("sdc_consume")

local M = { stats = {} }
for _, k in ipairs({ "fixed", "replaced", "absent", "missing", "distance", "differ",
                     "xp_sent", "xp_added", "reports", "skills_set", "comps_fixed",
                     "resets_sent", "resets_done" }) do
    M.stats[k] = 0
end

local S
function M.init(state) S = state end

local addr = ctx.addr

local FIREARM_FINDSTAT = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:FindStat"
local MELEE_FINDSTAT = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C:FindStat"
local SKILLS_FN = "/Game/Blueprints/Components/PassiveSkillsComponent.PassiveSkillsComponent_C:"
local REPORT_DAMAGE = "/Script/AIModule.AISense_Damage:ReportDamageEvent"

-- BP struct members (GUID-suffixed)
local F_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"   -- S_ReplicatedContainerInfo
local F_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"    -- ContainerPickupsInfo
local F_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"          -- ContainerPickupsInfo -> RepItemInfo
local F_STATS = "Stats_26_C770972746930CB80CC49AB7A6D19359"            -- RepItemInfo -> array of S_ItemStat
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"          -- RepItemInfo -> JigsawItem_DataAsset_C
local F_STAT_NAME = "STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10"    -- S_ItemStat
local F_MIN = "MinValue_6_4B4822A7420F784740B6A58155973EE6"
local F_MAX = "MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"

-- weapon slot -> its RepItemInfo in S_ServerEquippedItems
local WEAPON_SLOTS = {
    ["Jig.PlayerSlot.PrimaryWeapon"] = "EquippedPrimary_43_71FDAE8F453FE0DADB6317949C57DDCF",
    ["Jig.PlayerSlot.SecondaryWeapon"] = "EquippedSecondary_44_06F9E8664A16E6584B9772A436A872B0",
    ["Jig.PlayerSlot.SidearmWeapon"] = "EquippedSidearm_45_DBAF50604B799AD8D36966B58FC8D116",
    ["Jig.PlayerSlot.MeleeWeapon"] = "EquippedMelee_48_0C451F654720DD3648581EA9DB6E85D0",
}
local MELEE_SLOT = "Jig.PlayerSlot.MeleeWeapon"
local EQUIP_TO = "Jig.ContainerType.EquipTo"   -- JSIContainer.IsEquipTo?@0
-- Skill -> PassiveSkillsComponent function, for the skills whose XP the game
-- grants ONLY on the server, so the client never gets it by itself:
--   Marksmanship  BP_FirearmPickup.SERVER_DamageEvent@3816/4735
--   Toughness     BP_PlayerCharacter ReceiveAnyDamage@137383 (damage events run
--                 on the authority only); RadiationComponent.RadiationTimer@671
--                 (timer set by the UpdateRadiation server RPC)
--   FirstAid      MedicalComponent.IncreaseHealth@1412/2193 <- ConsumeItem <-
--                 JigMP_OnItemConsumed (server consume RPCs only)
--   Fitness       StaminaComponent.ReduceStaminaDuringSprinting@988; its timer
--                 is set only in SetSprintState's IsServer branch (@76-700)
-- NOT relayed, the owning client already gets them itself: Strength
-- (BP_MeleePickup.Client_StrengthXP RPC), Sneaking (Footstep Sound anim notify
-- on every machine), Reloading (Jig_StartReloading -> LocalStartReload on the
-- owner), Scavenging (hold-to-interact on the interacting machine).
local XP_FUNCS = {
    Marksmanship = "AddXP_Marksmanship",
    Toughness = "AddXP_Toughness",
    FirstAid = "AddXP_FirstAid",
    Fitness = "AddXP_Fitness",
}
local RESET_CVAR = "Difficulty.ResetPassiveSkills"   -- PassiveSkillsComponent.ResetPassiveSkills@5-38
local NO_ITEM = "-"       -- WSTAT text: the slot's container holds no item
local ZERO_GUID = "0:0:0:0"

local LOCAL_TTL = 2       -- s: cache of "not a remote player's weapon"
local REMOTE_TTL = 15     -- s: remote weapons, kept alive by the host tick
local REFRESH_S = 5       -- s: re-read of the host's copy of a remote weapon's item
local RESEND_S = 120      -- s: client re-sends unchanged reports (the verify; a change goes at once)
local MAX_XP_MSG = 10000  -- sanity cap of one DXP message (one tick of hits)
local XP_MIN_SEND = 0.5   -- smaller amounts (sprint Fitness: ~0.3/s) wait ...
local XP_MAX_WAIT = 10    -- s: ... at most this long

local function enabled()
    return cfg.get("fix_client_damage") ~= false
end

local function xp_enabled()
    return cfg.get("relay_skill_xp") ~= false
end

-- Hooks act only on a host with remote players connected.
local function host_active()
    return S ~= nil and S.role == "host" and #(S.remote_pcs or {}) > 0 and enabled()
end

local function xp_active()
    return S ~= nil and S.role == "host" and #(S.remote_pcs or {}) > 0 and xp_enabled()
end

local guid_str = consume.guid_str

-- nil for an unknown / empty UID
local function known_uid(u)
    if u == nil or u == "" or u == ZERO_GUID then return nil end
    return u
end

local function approx(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then return false end
    return math.abs(a - b) <= 1e-3 * math.max(1, math.abs(b))
end

-- One-time log notes: notes[kind][group][sub]. Table lookups only, so the
-- hot hooks build no strings for notes that were already written.
local notes = {}
local function first(kind, group, sub)
    if sub == nil then sub = "" end
    local k = notes[kind]
    if not k then k = {}; notes[kind] = k end
    local g = k[group]
    if not g then g = {}; k[group] = g end
    if g[sub] then return false end
    g[sub] = true
    return true
end

local function slot_short(slot)
    return (tostring(slot or "?"):gsub("^Jig%.PlayerSlot%.", ""))
end


-- ---------------------------------------------------------------------------
-- Item stats as the host has them
-- ---------------------------------------------------------------------------

-- Array of S_ItemStat -> { [tag] = { min =, max = } }, count, complete. The
-- first entry of a tag wins, like JSI_Slot_C.GetStatByName. Every row is
-- read: GenerateRandomStats@0-2492 appends the rolled rows AND all of the
-- data asset's rows (guns usually end up with one row more than MaxStats,
-- DamageFallOff), and the widget gets that whole array. complete = false when
-- the array or any row could not be read: the caller must then treat the
-- stats as unknown, never as "item lacks this stat" (a missing DamageFallOff
-- answers 1 m effective range: about -7 damage per metre, EffectiveDamage@1200-1573).
local function read_stat_array(arr)
    local out, n = {}, 0
    if arr == nil then return out, 0, false end
    local bad = false
    local ok = pcall(function()
        arr:ForEach(function(_, e)
            local okr = pcall(function()
                local s = e:get()
                local tag = ue.str(s[F_STAT_NAME].TagName)
                if tag ~= "" and tag ~= "None" and out[tag] == nil then
                    local lo, hi = s[F_MIN], s[F_MAX]
                    if type(lo) ~= "number" or type(hi) ~= "number" then error("stat value not a number") end
                    out[tag] = { min = lo, max = hi }
                    n = n + 1
                end
            end)
            if not okr then bad = true end
        end)
    end)
    return out, n, ok and not bad
end

-- RepItemInfo -> stats (possibly empty), count; nil when the record holds no
-- item or could not be read completely. An item with an empty Stats array has
-- no stats (see the header).
local function read_item_info(info)
    if info == nil then return nil, 0 end
    local arr = ue.try(function() return info[F_STATS] end)
    if arr == nil then return nil, 0 end
    local stats, n, complete = read_stat_array(arr)
    if not complete then return nil, 0 end
    if n > 0 then return stats, n end
    local da = ue.try(function() return info[F_ITEMID] end)
    if ue.valid(da) then return stats, 0 end
    return nil, 0
end

-- slot tag -> item UID string, from the owner's HelperComp (host only).
local function equipment_uids(pawn)
    local out = {}
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return out end
    pcall(function()
        helper.EquipmentUIDs:ForEach(function(k, v)
            local u = known_uid(guid_str(v:get()))
            if u then out[ue.str(k:get().TagName)] = u end
        end)
    end)
    return out
end

-- The item record with this UID in the owner's inventory: stats, n, found.
local function inventory_stats(pawn, uid)
    local jig = ue.prop(pawn, "BP_JigMultiplayer")
    if not uid or not ue.valid(jig) then return nil, 0, false end
    local stats, n, found = nil, 0, false
    pcall(function()
        jig.MainJigContainers:ForEach(function(_, c)
            if found then return true end
            c:get()[F_ITEMS]:ForEach(function(_, it)
                if found then return true end
                local item = it:get()
                if guid_str(item[F_USID]) == uid then
                    found = true
                    stats, n = read_item_info(item[F_INFO])
                    return true
                end
            end)
        end)
    end)
    return stats, n, found
end

local function equipped_info_stats(pawn, slot)
    local field = slot and WEAPON_SLOTS[slot]
    if not field then return nil, 0 end
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return nil, 0 end
    return read_item_info(ue.try(function() return helper.ServerEquippedItems[field] end))
end

local function pickup_stats(w)
    local comp = ue.prop(w, "BP_JigMultiplayer")
    if not ue.valid(comp) then return nil, 0 end
    return read_item_info(ue.try(function() return comp.PickupInfo[F_INFO] end))
end

-- stats (possibly empty) or nil, count, source label
local function collect(pawn, w, slot, uid)
    local stats, n, found
    if uid then
        stats, n, found = inventory_stats(pawn, uid)
        if stats then return stats, n, n > 0 and "inventory" or "inventory (item has no stats)" end
    end
    stats, n = equipped_info_stats(pawn, slot)
    if stats then return stats, n, n > 0 and "equipped info" or "equipped info (item has no stats)" end
    stats, n = pickup_stats(w)
    if stats then return stats, n, n > 0 and "pickup info" or "pickup info (item has no stats)" end
    return nil, 0, found and "inventory (unreadable record)" or "none"
end

-- ---------------------------------------------------------------------------
-- Client reports
-- ---------------------------------------------------------------------------

local reported = {}    -- [pc address] = { [slot] = { uid =, stats =, n =, text = } }
local strength = {}    -- [pc address] = StrengthMultiplier reported by that client
local xp_pending = {}  -- [pc address] = { [skill] = { amount =, since = } } not sent yet

-- The client's report for this entry's slot; nil when there is none or it is
-- about another item than the one the host has in that slot.
local function report_for(e)
    local per = e.slot and reported[e.pc_a]
    local r = per and per[e.slot]
    if not r then return nil end
    if e.uid and r.uid ~= "" and r.uid ~= e.uid then
        if first("uid", e.group, r.uid) then
            log.info("damage: %s of %s: the client reports item %s, the host has %s; report not used",
                slot_short(e.slot), e.pawn_name, r.uid, tostring(e.uid))
        end
        return nil
    end
    return r
end

local function stat_diffs(host, client)
    local diffs = {}
    for tag, s in pairs(client) do
        local h = host[tag]
        if not h then
            diffs[#diffs + 1] = tag .. " only on the client"
        elseif not approx(h.min, s.min) or not approx(h.max, s.max) then
            diffs[#diffs + 1] = string.format("%s host %.3f/%.3f client %.3f/%.3f", tag, h.min, h.max, s.min, s.max)
        end
    end
    for tag in pairs(host) do
        if not client[tag] then diffs[#diffs + 1] = tag .. " only on the host" end
    end
    table.sort(diffs)
    return diffs
end

-- What FindStat answers for this weapon (e.use): the host's copy of the item
-- record; the client's own numbers when the host has none, or always with
-- client_weapon_stats = true.
local function choose(e)
    local r = report_for(e)
    if r and (not e.host or cfg.get("client_weapon_stats") == true) then
        e.use, e.use_n, e.use_src = r.stats, r.n, "client report"
    else
        e.use, e.use_n, e.use_src = e.host, e.host_n, e.host_src
    end
    if not r then return end
    if not first("cmp", e.group, tostring(e.host_src) .. "|" .. r.text) then return end
    if not e.host then
        log.info("damage: %s of %s: no stats on the host (%s), using the client's (%d stats)",
            slot_short(e.slot), e.pawn_name, tostring(e.host_src), r.n)
        return
    end
    local diffs = stat_diffs(e.host, r.stats)
    if #diffs == 0 then
        log.info("damage: %s of %s: host stats (%s) match the client's (%d stats)",
            slot_short(e.slot), e.pawn_name, e.host_src, r.n)
    else
        M.stats.differ = M.stats.differ + 1
        log.info("damage: %s of %s: host stats (%s) differ from the client's, using the %s: %s",
            slot_short(e.slot), e.pawn_name, e.host_src,
            e.use_src == "client report" and "client's" or "host's", table.concat(diffs, "; "))
    end
end

-- ---------------------------------------------------------------------------
-- Remote weapons on the host
-- ---------------------------------------------------------------------------

-- [weapon address] = entry. Entries hold no UObjects: addresses, names, slot,
-- UID and stat tables only.
local entries = {}

local function remote_owner(w)
    if not ue.valid(w) then return nil end
    local pawn = ue.try(function() return w:GetOwner() end)
    if not ue.valid(pawn) or not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return nil end
    local pc = ue.prop(pawn, "Controller")
    if not ue.valid(pc) or not ue.valid(ue.prop(pc, "NetConnection")) then return nil end
    return pawn, pc
end

local function slot_of(pawn, w)
    if not ue.valid(w) then return nil end
    local a = addr(w)
    local it = a and items.equipped_of(pawn)[a]
    if it and it.slot ~= "" then return it.slot end
    return nil
end

-- weapon.PassiveSkillsComponent was taken at BeginPlay through player 0;
-- point it at the owner's controller (XP and StrengthMultiplier come from it).
local function fix_weapon_skills(w, pc)
    if not ue.valid(w) or not ue.valid(pc) then return end
    local cur = ue.prop(w, "PassiveSkillsComponent")
    if ue.missing(cur) then return end                 -- no such property
    local want = ue.prop(pc, "PassiveSkillsComponent")
    if not ue.valid(want) then return end
    if ue.valid(cur) and addr(cur) == addr(want) then return end
    local was = "no"
    if ue.valid(cur) then was = ue.short(ue.try(function() return cur:GetOwner() end)) end
    if ue.set_prop(w, "PassiveSkillsComponent", want) then
        M.stats.comps_fixed = M.stats.comps_fixed + 1
        local wname = ue.short(w)
        if first("comp", wname) then
            log.info("damage: %s used %s's skills component, now its owner's (%s)", wname, was, ue.short(pc))
        end
    end
end

-- The client's StrengthMultiplier on the host's copy of its skills component.
local function apply_skills(pc)
    if not ue.valid(pc) then return end
    local k = addr(pc)
    local want = k and strength[k]
    if not want then return end
    local comp = ue.prop(pc, "PassiveSkillsComponent")
    if not ue.valid(comp) then return end
    local cur = ue.prop(comp, "StrengthMultiplier")
    if type(cur) ~= "number" or approx(cur, want) then return end
    if ue.set_prop(comp, "StrengthMultiplier", want) then
        M.stats.skills_set = M.stats.skills_set + 1
        if M.stats.skills_set <= 5 then
            log.info("damage: StrengthMultiplier of %s on the host %.3f -> %.3f (client's)", ue.short(pc), cur, want)
        end
    end
end

-- A fresh entry for a remote player's weapon; nil if an object is gone.
-- prev: the entry this one replaces (same weapon address), or nil.
local function build(w, pawn, pc, slot, uids, kind, now, prev)
    if not ue.valid(w) or not ue.valid(pawn) or not ue.valid(pc) then return nil end
    local e = { t = now, built = now, remote = true, pawn_a = addr(pawn), pc_a = addr(pc) }
    e.weapon_name, e.pawn_name = ue.short(w), ue.short(pawn)
    e.slot = slot or slot_of(pawn, w) or (kind == "melee" and MELEE_SLOT or nil)
    uids = uids or equipment_uids(pawn)
    e.uid = e.slot and uids[e.slot] or nil
    e.group = table.concat({ e.pawn_name, tostring(e.slot), tostring(e.uid) }, "|")
    e.firearm = type(ue.prop(w, "ShotDistance")) == "number"
    -- a projectile weapon (crossbow) never runs FireTrace: its ShotDistance
    -- stays 0 in single player too (no fall-off), so it is left alone
    e.projectile = ue.prop(ue.prop(w, "BP_WeaponsPickupComponent"), "DoesWeaponUseAProjectile?") == true
    e.host, e.host_n, e.host_src = collect(pawn, w, e.slot, e.uid)
    if not e.host and prev and prev.remote and prev.host and prev.pawn_a == e.pawn_a and prev.slot == e.slot
        and prev.uid == e.uid then
        -- a refresh that could not read the item keeps the last good read
        e.host, e.host_n, e.host_src = prev.host, prev.host_n, prev.host_src
    end
    fix_weapon_skills(w, pc)
    choose(e)
    if first("entry", e.group, e.host_src) then
        if e.host then
            local dmg = e.host["Jig.Stat.FirearmDamage"] or e.host["Jig.Stat.MeleeDamage"]
            log.info("damage: %s %s of %s: %d stats from %s (uid %s, damage %s)", slot_short(e.slot),
                e.weapon_name, e.pawn_name, e.host_n, e.host_src, tostring(e.uid),
                dmg and string.format("%.2f/%.2f", dmg.min, dmg.max) or "-")
        else
            log.info("damage: %s %s of %s: no stats on the host (%s, uid %s)", slot_short(e.slot),
                e.weapon_name, e.pawn_name, e.host_src, tostring(e.uid))
        end
    end
    return e
end

-- Entry of any weapon a hook sees: { remote = false } or a remote player's.
local function entry_for(w, kind)
    if not ue.valid(w) then return nil end
    local a = addr(w)
    if not a then return nil end
    local now = os.clock()
    local e = entries[a]
    if e then
        if not e.remote then
            if now - e.t < LOCAL_TTL then return e end
        elseif now - e.t < REMOTE_TTL then
            local o = ue.try(function() return w:GetOwner() end)
            if ue.valid(o) and addr(o) == e.pawn_a then return e end
        end
    end
    local pawn, pc = remote_owner(w)
    e = pawn and build(w, pawn, pc, nil, nil, kind, now, e) or { t = now, remote = false }
    entries[a] = e
    return e
end

-- Host tick: (re)build the entries of every remote player's equipped weapons
-- so the hooks only look them up; drop entries of weapons no longer equipped.
local function refresh_remote(remote_pcs, now)
    local seen = {}
    for _, pc in ipairs(remote_pcs) do
        if ue.valid(pc) then
            apply_skills(pc)
            local pawn = ue.pawn_of(pc)
            if pawn then
                local pa = addr(pawn)
                local uids = nil
                for a, it in pairs(items.equipped_of(pawn)) do
                    if WEAPON_SLOTS[it.slot] and ue.valid(it.actor) then
                        uids = uids or equipment_uids(pawn)
                        local e = entries[a]
                        if e and e.remote and e.pawn_a == pa and e.slot == it.slot and e.uid == uids[it.slot]
                            and now - e.built < REFRESH_S then
                            e.t = now
                            fix_weapon_skills(it.actor, pc)
                        else
                            e = build(it.actor, pawn, pc, it.slot, uids, nil, now, e)
                            entries[a] = e
                        end
                        if e then seen[a] = true end
                    end
                end
            end
        end
    end
    for a, e in pairs(entries) do
        if (e.remote and not seen[a]) or now - e.t > LOCAL_TTL * 5 then entries[a] = nil end
    end
end

-- Forget what departed players reported (their controller's address may be
-- reused by the next one).
local function prune_players(remote_pcs)
    local live = {}
    for _, pc in ipairs(remote_pcs) do
        if ue.valid(pc) then
            local k = addr(pc)
            if k then live[k] = true end
        end
    end
    for _, t in ipairs({ reported, strength, xp_pending }) do
        for k in pairs(t) do
            if not live[k] then t[k] = nil end
        end
    end
end

-- [PassiveSkillsComponent address] = its controller's address, for remote
-- players' controllers on the host. Rebuilt by the host tick, read by the
-- XP hooks (AddXP_Fitness fires about 100 times a second while someone
-- sprints, so the hook does one table lookup for everybody else).
local remote_comps = {}

local function build_remote_comps(remote_pcs)
    local m = {}
    for _, pc in ipairs(remote_pcs) do
        if ue.valid(pc) then
            local comp = ue.prop(pc, "PassiveSkillsComponent")
            local ca, pa = ue.valid(comp) and addr(comp), addr(pc)
            if ca and pa then m[ca] = pa end
        end
    end
    remote_comps = m
end

-- Skill XP of a remote player gathered on the host, one DXP message per
-- player and skill. Small amounts wait (up to XP_MAX_WAIT) to batch.
local xp_logged = {}
local function flush_xp(remote_pcs)
    if next(xp_pending) == nil then return end
    local now = os.clock()
    for _, pc in ipairs(remote_pcs) do
        local k = ue.valid(pc) and addr(pc)
        local per = k and xp_pending[k]
        if per then
            for skill, p in pairs(per) do
                if p.amount >= XP_MIN_SEND or now - p.since >= XP_MAX_WAIT then
                    per[skill] = nil
                    local amount = math.min(p.amount, MAX_XP_MSG)
                    if amount > 0 and net.send_to(pc, "DXP", skill, string.format("%.3f", amount)) then
                        M.stats.xp_sent = M.stats.xp_sent + 1
                        local n = xp_logged[skill] or 0
                        if n < 3 then
                            xp_logged[skill] = n + 1
                            log.info("damage: %.2f %s XP sent to %s", amount, skill, ue.short(pc))
                        end
                    end
                end
            end
            if next(per) == nil then xp_pending[k] = nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Hooks (host)
-- ---------------------------------------------------------------------------

local function set_out(found_p, min_p, max_p, found, lo, hi)
    pcall(function() found_p:set(found) end)
    pcall(function() min_p:set(lo) end)
    pcall(function() max_p:set(hi) end)
end

-- FindStat(StatTag, out Found, out Min, out Max) of a firearm / knife.
local function on_find_stat(kind, c, tag_p, found_p, min_p, max_p)
    if not host_active() then return end
    if not c or not tag_p or not found_p or not min_p or not max_p then return end
    local w = c:get()
    local e = entry_for(w, kind)
    if not e or not e.remote then return end
    -- A weapon whose BeginPlay found no skills component (player 0 answered
    -- "no player", see sdc_ctx): the knife's DamageCalc@670 reads
    -- StrengthMultiplier from it right after this FindStat (from None: 0, i.e.
    -- no damage), and XP goes to it. Point it at the owner's now.
    if not ue.valid(ue.prop(w, "PassiveSkillsComponent")) then
        local _, pc = remote_owner(w)
        if pc then fix_weapon_skills(w, pc) end
    end
    local stats = e.use
    if not stats then
        M.stats.missing = M.stats.missing + 1
        if first("missing", e.group) then
            log.info("damage: no stats for %s of %s (slot %s): its hits keep the game's result",
                e.weapon_name, e.pawn_name, slot_short(e.slot))
        end
        return
    end
    local okt, tag = pcall(function() return ue.str(tag_p:get().TagName) end)
    if not okt or tag == "" then return end
    local s = stats[tag]
    if not s then
        -- the item has no such stat: what the game answers with a widget
        -- (FindStat@887..921: Found = false, 1, 1)
        set_out(found_p, min_p, max_p, false, 1, 1)
        M.stats.absent = M.stats.absent + 1
        if first("absent", e.group, tag) then
            log.info("damage: %s of %s has no %s (%s): not found, 1/1 like single player",
                e.weapon_name, e.pawn_name, tag, e.use_src)
        end
        return
    end
    local lo, hi
    if kind == "firearm" then lo, hi = s.max, s.min else lo, hi = s.min, s.max end
    local okf, was = pcall(function() return found_p:get() end)
    if okf and was == true then
        local cur_lo = ue.try(function() return min_p:get() end)
        local cur_hi = ue.try(function() return max_p:get() end)
        if approx(cur_lo, lo) and approx(cur_hi, hi) then return end
        -- found in some other inventory widget (the host's own)
        M.stats.replaced = M.stats.replaced + 1
        if first("replaced", e.group, tag) then
            log.info("damage: %s %s of %s: game found %s/%s (not this item), using %.2f/%.2f", kind, tag,
                e.pawn_name, tostring(cur_lo), tostring(cur_hi), lo, hi)
        end
    end
    set_out(found_p, min_p, max_p, true, lo, hi)
    M.stats.fixed = M.stats.fixed + 1
    if M.stats.fixed <= 5 then
        log.info("damage: %s %s of %s (%s) -> %.2f/%.2f from %s", kind, tag, e.weapon_name, e.pawn_name, lo, hi,
            e.use_src)
    end
end

-- AISense_Damage.ReportDamageEvent(WorldContext = weapon, DamagedActor, ...):
-- give the host's copy of a client's firearm the shot distance before the
-- EffectiveDamage that feeds ApplyDamage.
local function on_report_damage(_, wco_p, damaged_p)
    if not host_active() or not wco_p or not damaged_p then return end
    local w = wco_p:get()
    local e = entry_for(w, "firearm")
    if not e or not e.remote or not e.firearm or e.projectile then return end
    local target = damaged_p:get()
    if not ue.valid(w) or not ue.valid(target) then return end
    local a, b = ue.location(w), ue.location(target)
    if not a or not b then return end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if ue.set_prop(w, "ShotDistance", d) then
        M.stats.distance = M.stats.distance + 1
        if M.stats.distance <= 3 then
            log.info("damage: shot distance of %s (%s) set to %.0f cm", e.weapon_name, e.pawn_name, d)
        end
    end
end

-- PassiveSkillsComponent.AddXP_<skill> (see XP_FUNCS) on the host's copy of a
-- client's controller: the client never runs that code. Added up per player
-- and skill, sent by host_tick. (BP hook: runs after the function, the
-- parameter still holds the amount.)
local function on_add_xp(skill, c, amount_p)
    if not xp_active() or not c or not amount_p then return end
    local ca = addr(c:get())
    local pa = ca and remote_comps[ca]
    if not pa then return end
    local amount = ue.try(function() return amount_p:get() end)
    if type(amount) ~= "number" or amount <= 0 or amount ~= amount then return end
    local per = xp_pending[pa]
    if not per then per = {}; xp_pending[pa] = per end
    local p = per[skill]
    if not p then p = { amount = 0, since = os.clock() }; per[skill] = p end
    p.amount = p.amount + amount
end

-- PassiveSkillsComponent.ResetPassiveSkills on the host's copy of a client's
-- controller (BP_PlayerCharacter.AfterDeath@579, the server's death path).
-- The function resets only with Difficulty.ResetPassiveSkills on; the host's
-- setting decides, as for the host's own death. The client resets its own
-- component (SKRESET); XP gathered before the death is dropped like the
-- host's copy of it.
local function on_reset_skills(c)
    if not xp_active() or not c then return end
    local ca = addr(c:get())
    local pa = ca and remote_comps[ca]
    if not pa then return end
    local ksl = ue.ksl()
    local on = ksl and ue.try(function() return ksl:GetConsoleVariableBoolValue(RESET_CVAR) end)
    local pc = nil
    for _, p in ipairs(S.remote_pcs or {}) do
        if ue.valid(p) and addr(p) == pa then pc = p; break end
    end
    if on ~= true then
        if first("reset-off", "all") then
            log.info("damage: %s died; %s is %s on the host, skills kept", ue.short(pc), RESET_CVAR, tostring(on))
        end
        return
    end
    xp_pending[pa] = nil
    if pc and net.send_to(pc, "SKRESET") then
        M.stats.resets_sent = M.stats.resets_sent + 1
        log.info("damage: %s died with %s on: passive skills reset, SKRESET sent", ue.short(pc), RESET_CVAR)
    end
end

-- Hook callbacks: errors are logged, nothing is ever returned.
local function guarded(label, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("damage." .. label, "damage: %s hook: %s", label, tostring(err)) end
    end
end

local hooked = {}   -- [key] = true once registered

local function try_hook(key, path, pre)
    if hooked[key] then return end
    local ok, err = pcall(RegisterHook, path, pre)
    if ok then
        hooked[key] = true
        log.info("damage: %s hook ok", key)
    else
        log.debug("damage: %s hook not ready (%s)", key, tostring(err))
    end
end

local function try_hooks()
    try_hook("firearm", FIREARM_FINDSTAT, guarded("firearm", function(c, t, f, lo, hi)
        on_find_stat("firearm", c, t, f, lo, hi)
    end))
    try_hook("melee", MELEE_FINDSTAT, guarded("melee", function(c, t, f, lo, hi)
        on_find_stat("melee", c, t, f, lo, hi)
    end))
    -- a native: one shared pre-only engine hook (sdc_ue.hook_native, each
    -- subscriber in its own pcall), no post callback
    if not hooked.report then
        local ok, err = ue.hook_native(REPORT_DAMAGE, "damage.report", on_report_damage)
        if ok then
            hooked.report = true
            log.info("damage: report hook ok")
        else
            log.debug("damage: report hook not ready (%s)", tostring(err))
        end
    end
end

-- The skills component class is loaded once a controller exists; retried
-- every host tick until in.
local function try_xp_hooks()
    for skill, fn in pairs(XP_FUNCS) do
        local key = "xp " .. skill
        try_hook(key, SKILLS_FN .. fn, guarded(key, function(c, amount_p) on_add_xp(skill, c, amount_p) end))
    end
    try_hook("skill reset", SKILLS_FN .. "ResetPassiveSkills", guarded("skill reset", on_reset_skills))
end

-- ---------------------------------------------------------------------------
-- Client: report the own weapons' stats and StrengthMultiplier
-- ---------------------------------------------------------------------------

-- [slot] = { uid =, text = "tag=min,max;..." | "" (no stats) | NO_ITEM },
-- read from the own inventory widget the way FindStat does: the first
-- container with the slot's tag decides, and only an EquipTo container's
-- first item counts (GetJSIContainerByPlayerSlots@276-291,
-- JSIContainer.GetEquippedItemRef@0-155).
local function own_weapon_stats()
    local me = ue.local_pawn()
    local jig = me and ue.prop(me, "BP_JigMultiplayer")
    if not ue.valid(jig) then return nil end
    local inv = ue.prop(jig, "InventoryWidgetRef")
    if not ue.valid(inv) then return nil end
    local out, decided = {}, {}
    pcall(function()
        inv.Priv_Containers:ForEach(function(_, ce)
            local c = ce:get()
            if not ue.valid(c) then return end
            local slot = ue.str(ue.try(function() return c.ContainerTag.TagName end))
            if not WEAPON_SLOTS[slot] or decided[slot] then return end
            decided[slot] = true
            out[slot] = { uid = "", text = NO_ITEM }
            local ctype = ue.str(ue.try(function() return c.ContainerType.TagName end))
            if ctype ~= EQUIP_TO then return end
            local item, taken = nil, false
            pcall(function()
                c.ArrayOfItems:ForEach(function(_, ie)
                    if taken then return true end
                    taken = true
                    item = ie:get()
                    return true
                end)
            end)
            if not ue.valid(item) then return end
            local stats, _, complete = read_stat_array(ue.prop(item, "ItemStats"))
            if not complete then
                -- unreadable this tick: report nothing rather than "no stats"
                out[slot] = nil
                return
            end
            local parts = {}
            for tag, s in pairs(stats) do
                parts[#parts + 1] = string.format("%s=%.6g,%.6g", tag, s.min, s.max)
            end
            table.sort(parts)
            local uid = ""
            if ue.valid(item) then uid = ue.try(function() return guid_str(item.ItemUniqueID) end) or "" end
            out[slot] = { uid = known_uid(uid) or "", text = table.concat(parts, ";") }
        end)
    end)
    return out
end

local client = { sent = {}, sent_t = {}, skl = nil, skl_t = 0 }

function M.client_tick()
    if not S or S.role ~= "client" then return end
    local now = os.clock()
    for slot, r in pairs(own_weapon_stats() or {}) do
        local key = r.uid .. "|" .. r.text
        if client.sent[slot] ~= key or now - (client.sent_t[slot] or 0) >= RESEND_S then
            if net.send_to_host("WSTAT", slot, r.uid, r.text) then
                client.sent[slot], client.sent_t[slot] = key, now
                log.debug("damage: reported %s stats (%s)", slot_short(slot), r.text)
            end
        end
    end
    local pc = ue.local_pc()
    local comp = ue.prop(pc, "PassiveSkillsComponent")
    local sm = ue.valid(comp) and ue.prop(comp, "StrengthMultiplier") or nil
    if type(sm) == "number" then
        local s = string.format("%.4f", sm)
        if s ~= client.skl or now - client.skl_t >= RESEND_S then
            if net.send_to_host("SKL", s) then client.skl, client.skl_t = s, now end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Host tick, messages, status
-- ---------------------------------------------------------------------------

function M.host_tick(remote_pcs)
    if not S or S.role ~= "host" then return end
    remote_pcs = remote_pcs or S.remote_pcs or {}
    prune_players(remote_pcs)
    if #remote_pcs == 0 then
        entries, remote_comps = {}, {}
        return
    end
    if xp_enabled() then
        try_xp_hooks()
        build_remote_comps(remote_pcs)
        flush_xp(remote_pcs)
    else
        remote_comps, xp_pending = {}, {}
    end
    if not enabled() then return end
    try_hooks()
    refresh_remote(remote_pcs, os.clock())
end

function M.register_handlers()
    -- client -> host: WSTAT|<slot tag>|<item uid>|<stat tag>=<MinValue>,<MaxValue>;...
    -- (empty text: the item has no stats; "-": the slot holds no item)
    net.on("WSTAT", function(f, pc)
        if not S or S.role ~= "host" then return end
        local slot, uid, text = f[1] or "", known_uid(f[2]) or "", f[3] or ""
        if not WEAPON_SLOTS[slot] or not ue.valid(pc) then return end
        local k = addr(pc)
        if not k then return end
        reported[k] = reported[k] or {}
        if text == NO_ITEM then
            reported[k][slot] = nil
        else
            -- every row must parse: a dropped row would turn into "not found"
            -- (DamageFallOff: -7 damage per metre), so a bad report is not used
            local stats, n, bad = {}, 0, nil
            for row in text:gmatch("[^;]+") do
                local tag, lo, hi = row:match("^([^=]+)=([^,]+),(.+)$")
                local a = tag and tonumber(lo)
                local b = tag and tonumber(hi)
                if not a or not b or a ~= a or b ~= b then
                    bad = row
                elseif stats[tag] == nil then
                    stats[tag] = { min = a, max = b }
                    n = n + 1
                end
            end
            if bad then
                reported[k][slot] = nil
                if first("badreport", tostring(k), slot) then
                    log.info("damage: %s's %s report not used, unreadable row '%s'", ue.short(pc), slot_short(slot), bad)
                end
            else
                reported[k][slot] = { uid = uid, stats = stats, n = n, text = text }
            end
        end
        M.stats.reports = M.stats.reports + 1
        for _, e in pairs(entries) do
            if e.remote and e.pc_a == k and e.slot == slot then choose(e) end
        end
    end)

    -- client -> host: SKL|<StrengthMultiplier>
    net.on("SKL", function(f, pc)
        if not S or S.role ~= "host" or not ue.valid(pc) then return end
        local v = tonumber(f[1])
        local k = addr(pc)
        if k and v and v > 0 and v < 100 then strength[k] = v end
    end)

    -- host -> client: SKRESET (the host's copy of this player's skills was
    -- reset on death; ResetPassiveSkills_NewSave resets the same fields
    -- without asking the client's own Difficulty.ResetPassiveSkills again)
    net.on("SKRESET", function()
        if not S or S.role ~= "client" then return end
        local comp = ue.prop(ue.local_pc(), "PassiveSkillsComponent")
        if not ue.valid(comp) then return end
        local ok, err = pcall(function() comp:ResetPassiveSkills_NewSave() end)
        if ok then
            M.stats.resets_done = M.stats.resets_done + 1
            client.skl = nil   -- report the reset StrengthMultiplier right away
            log.info("damage: passive skills reset on death (host setting %s)", RESET_CVAR)
        else
            log.err_throttled("damage.skreset", "damage: ResetPassiveSkills_NewSave failed: %s", tostring(err))
        end
    end)

    -- host -> client: DXP|<skill>|<amount> (XP of that skill gathered on the host)
    net.on("DXP", function(f)
        if not S or S.role ~= "client" then return end
        local fn, amount = XP_FUNCS[f[1] or ""], tonumber(f[2])
        if not fn or not amount or amount <= 0 or amount > MAX_XP_MSG then return end
        local comp = ue.prop(ue.local_pc(), "PassiveSkillsComponent")
        if not ue.valid(comp) then return end
        local ok, err = pcall(function() comp[fn](comp, amount) end)
        if ok then
            M.stats.xp_added = M.stats.xp_added + 1
            local n = xp_logged[f[1]] or 0
            if n < 3 then
                xp_logged[f[1]] = n + 1
                log.info("damage: %.2f %s XP from the host", amount, f[1])
            end
        else
            log.err_throttled("damage.dxp", "damage: %s(%.2f) failed: %s", fn, amount, tostring(err))
        end
    end)
end

function M.reset()
    entries, reported, strength, xp_pending, notes, remote_comps = {}, {}, {}, {}, {}, {}
    client = { sent = {}, sent_t = {}, skl = nil, skl_t = 0 }
end

return M
