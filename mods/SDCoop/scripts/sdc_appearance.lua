-- SDCoop: player appearance — the OWNER is the source.
--
-- The game builds a character's look from the local save of the machine it
-- runs on (sex, skin, hair, beard: meshes + material assets in SetSexMesh)
-- and its clothes from ServerEquippedItems, which exists only on the host.
-- So every machine showed every character with ITS OWN save's body, and
-- clients even undressed their own character (OnRep_Clothing* runs there
-- with an empty item and clears the mesh).
--
-- 1. A client dresses every replicated character (its own and the others)
--    itself, from the replicated Jig data (RepPrimitiveActorsData: the
--    entry's DA, or the replicated BP_CustomPrimitiveComp's DA ->
--    ClothingSettings), through the game's own MC_AttachClothing (run
--    locally). It does so right after the game's own OnRep_Clothing* /
--    OnRep_BodyArmorEquipped? (post-hooks: same frame, so the OnRep's
--    undressing never shows) and every 2 s as a safety net. The heavy-armour
--    sprint limit, which OnRep_BodyArmorEquipped? also decides from the
--    server-only data, is set on the own character the same way.
-- 2. Every machine publishes the look of ITS OWN character ("Comp=mesh,material,flags;...";
--    never '|', that is the message separator): mesh + material
--    of every body / hair / clothing component and their visibility, as it
--    would look in third person, plus the sex. Client -> host (MYLOOK), host
--    -> everyone (LOOK). Each machine applies the looks of the others; on a
--    client the clothing components dressed from replicated data in (1) are
--    left out (a LOOK can be a few seconds old after a change of clothes).

local log = require("sdc_log")
local ue = require("sdc_ue")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local netsync = require("sdc_netsync")

local M = {}
local S
function M.init(state) S = state end

-- hidden by the game's first-person view: not published from that state
local FP_COMPS = { Head = true, Mouth = true, EyebrowsMesh = true, HairMesh = true, BeardMesh = true,
                   Accessory1 = true, Accessory2 = true, Accessory3 = true }
local SKIP_COMPS = { CharacterMesh0 = true }
-- Components the game adds for a moment (a held item's mesh while it is used:
-- "NODE_AddStaticMeshComponent-2", "StaticMeshComponent_2147463626"): they are
-- not part of the look, no other machine has one of that name, and every one
-- changed the look string twice (13.11: 70 of 73 MYLOOK of a session).
local function transient_comp(name)
    return name:find("^NODE_") ~= nil or name:find("^StaticMeshComponent_%d+$") ~= nil
end

-- S_RepNonActorData / clothing settings members (BP structs)
local F_SLOT = "Slot_4_8843E80049E14A7C56C7E89EF659AAEC"
local F_DA = "DA_7_6FDDEF454801C671BE34D7B2377175C5"
local F_PRIM = "Primitive_10_73CBE8904497C494E7AB7D8EEE5E5411"
local F_MALE = "MaleMesh_55_C39419A54F846168C8ACC7B8047249B8"
local F_FEMALE = "FemaleMesh_56_759E5B484609B6B259ECB5ACB9BFA58A"
local F_PARTS = "BodyPartSettings_60_19AFB636484813B2DE1483A03355E921"
local F_ALL = "UpdateAllBodyParts?_62_67FB43564F6CE0C89955899C911D08E8"

-- as in OnRep_Clothing*/OnRep_BodyArmorEquipped? of BP_PlayerCharacter
local CLOTHING = {
    { tag = "Jig.PlayerSlot.Torso",     comp = "Clothing_Torso",  flag = "ClothingTorsoEquipped?",  part = "Torso",  gendered = true },
    { tag = "Jig.PlayerSlot.Legs",      comp = "Clothing_Legs",   flag = "ClothingLegsEquipped?",   part = "Legs",   gendered = true },
    { tag = "Jig.PlayerSlot.Feet",      comp = "Clothing_Feet",   flag = "ClothingFeetEquipped?",   part = "Feet",   gendered = true },
    { tag = "Jig.PlayerSlot.Gloves",    comp = "Clothing_Gloves", flag = "ClothingGlovesEquipped?", part = "Gloves", gendered = false, all = false },
    { tag = "Jig.PlayerSlot.BodyArmor", comp = "Clothing_Armor",  flag = "BodyArmorEquipped?",      part = "None",   gendered = false },
}
local ARMOR_TAG = "Jig.PlayerSlot.BodyArmor"
-- OnRep_BodyArmorEquipped? @95-293: these armours forbid sprinting
local HEAVY_ARMOR = { MilitaryHeavyArmor = true, MilitaryHeavyArmor2 = true }

local PLAYER_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local CLOTHING_ONREPS = { "OnRep_ClothingTorsoEquipped?", "OnRep_ClothingLegsEquipped?", "OnRep_ClothingFeetEquipped?",
                          "OnRep_ClothingGlovesEquipped?", "OnRep_BodyArmorEquipped?" }

local addr = ctx.addr

local function player_id(pawn)
    local ps = ue.prop(pawn, "PlayerState")
    if not ue.valid(ps) then return nil end
    local ok, id = pcall(function() return ps:GetPlayerId() end)
    if ok and type(id) == "number" then return math.floor(id) end
    local v = ue.prop(ps, "PlayerId")
    if type(v) == "number" then return math.floor(v) end
    return nil
end
M.player_id = player_id

-- Host: the player ids of everybody in the session now (its own and every
-- remote controller's PlayerState, which outlives the characters), or nil
-- when its own id cannot be read (nothing is dropped then).
function M.present_ids(remote_pcs)
    local ids = {}
    local own = ue.local_pc()
    local mine = own and player_id(own)
    if not mine then return nil end
    ids[mine] = true
    for _, pc in ipairs(remote_pcs or {}) do
        local id = ue.valid(pc) and player_id(pc)
        if not id then return nil end
        ids[id] = true
    end
    return ids
end

-- Host: entries of `t` ([player id] = ...) of players who left.
function M.drop_left(t, remote_pcs)
    local ids = M.present_ids(remote_pcs)
    if not ids then return end
    for id in pairs(t) do
        if not ids[id] then t[id] = nil end
    end
end

local function short_path(p) return (p:gsub("^/Game/", "")) end
local function full_path(p)
    if p == "" or p:sub(1, 1) == "/" then return p end
    return "/Game/" .. p
end

local function load_asset(path)
    if path == "" then return nil end
    local a = ue.find_object(path)
    if a then return a end
    local ok, loaded = ue.load_asset(path, "appearance")
    if ok and ue.valid(loaded) then return loaded end
    return nil
end

local function mesh_comps(actor)
    local out = {}
    local cls = ue.find_object("/Script/Engine.MeshComponent")
    local ok, arr = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
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

local function asset_path(comp)
    for _, pname in ipairs({ "SkeletalMeshAsset", "SkeletalMesh", "StaticMesh" }) do
        local a = ue.prop(comp, pname)
        if ue.valid(a) then return ue.path(a) end
    end
    return ""
end

local function material_path(comp)
    local m = ue.try(function() return comp:GetMaterial(0) end)
    if not ue.valid(m) then return "" end
    if ue.class_name(m):find("Dynamic", 1, true) then
        local parent = ue.prop(m, "Parent")
        if ue.valid(parent) then return ue.path(parent) end
    end
    return ue.path(m)
end

local function flags_of(comp)
    return (ue.prop(comp, "bHiddenInGame") == true and "h" or "") .. (ue.prop(comp, "bVisible") == false and "v" or "")
end

local function is_local(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

-- A replicated character on a client (not the hidden stale local copy).
local function is_replicated(p)
    if not ue.valid(p) or not ue.class_name(p):find("PlayerCharacter", 1, true) then return false end
    local r = ue.role(p)
    return r == ue.ROLE_SIMULATED or r == ue.ROLE_AUTONOMOUS
end

-- ===========================================================================
-- 1. Clothes from the replicated Jig data (clients)
-- ===========================================================================

-- [slot tag] = data asset of the clothing item in that slot: the replicated
-- array entry's DA, else the DA of its replicated primitive actor.
local function clothing_das(pawn)
    local out = {}
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return out end
    pcall(function()
        helper.RepPrimitiveActorsData:ForEach(function(_, e)
            local entry = e:get()
            local tag = ue.str(ue.try(function() return entry[F_SLOT].TagName end))
            if tag ~= "" then
                local da = ue.try(function() return entry[F_DA] end)
                if not ue.valid(da) then
                    local prim = ue.try(function() return entry[F_PRIM] end)
                    da = ue.valid(prim) and ue.prop(prim, "DA") or nil
                end
                if ue.valid(da) then out[tag] = da end
            end
        end)
    end)
    return out
end

-- Own character: OnRep_BodyArmorEquipped? sets SprintingRestricted? from the
-- item in the server-only ServerEquippedItems, i.e. never on a client. With
-- the armour unequipped the game's own value (false) is right.
local function armor_sprint(pawn, das)
    if ue.prop(pawn, "BodyArmorEquipped?") ~= true then return end
    local da = das[ARMOR_TAG]
    if not ue.valid(da) then return end
    local id = ue.str(ue.prop(da, "ItemID"))
    local want = HEAVY_ARMOR[id] == true
    if (ue.prop(pawn, "SprintingRestricted?") == true) ~= want then
        local ok = ue.set_prop(pawn, "SprintingRestricted?", want)
        log.info("look: sprinting %s by the body armour %s (ok=%s)", want and "restricted" or "allowed", id, tostring(ok))
    end
end

-- Dresses `pawn` (client). Returns the set of clothing component names whose
-- look now comes from replicated data: slot flag false (the game's own OnRep
-- cleared the mesh) or flag true with the item's data asset known.
function M.dress(pawn, why)
    local handled = {}
    if not ue.valid(pawn) then return handled end
    local das = clothing_das(pawn)
    local male = ue.prop(pawn, "IsPlayerMale?") == true
    for _, c in ipairs(CLOTHING) do
        local flag = ue.prop(pawn, c.flag)
        local comp = ue.prop(pawn, c.comp)
        local da = das[c.tag]
        if flag == false then
            handled[c.comp] = true
        elseif flag == true and ue.valid(comp) and ue.valid(da) then
            local cs = ue.prop(da, "ClothingSettings")
            local mesh = cs and ue.try(function() return (c.gendered and not male) and cs[F_FEMALE] or cs[F_MALE] end)
            if ue.valid(mesh) then
                handled[c.comp] = true
                if asset_path(comp) ~= ue.path(mesh) then
                    local parts = ue.try(function() return cs[F_PARTS] end)
                    local all = c.all
                    if all == nil then all = ue.try(function() return cs[F_ALL] end) == true end
                    -- gloves / armour always pass "male" (one mesh for both)
                    local male_arg = true
                    if c.gendered then male_arg = male end
                    local ok, err = pcall(function()
                        pawn:MC_AttachClothing(comp, mesh, parts, male_arg, FName(c.part), all)
                    end)
                    log.info("look: dressed %s %s with %s (%s, ok=%s%s)", ue.short(pawn), c.comp, ue.short(mesh),
                        why or "tick", tostring(ok), ok and "" or (" " .. tostring(err)))
                end
            end
        end
    end
    if is_local(pawn) then armor_sprint(pawn, das) end
    return handled
end

-- BP_PlayerCharacter.OnRep_Clothing*Equipped? / OnRep_BodyArmorEquipped?, post
-- (client): the game has just dressed the character from empty data.
local function on_clothing_rep(c)
    if S.role ~= "client" then return end
    local p = c and c:get()
    if not is_replicated(p) then return end
    M.dress(p, "event")
end

local onrep_hooked = {}   -- [path] = true
local function try_hook_onreps()
    for _, fn in ipairs(CLOTHING_ONREPS) do
        local path = PLAYER_FN .. fn
        if not onrep_hooked[path] then
            local ok = pcall(RegisterHook, path, function(c)
                local okc, err = pcall(on_clothing_rep, c)
                if not okc then log.err_throttled("look-onrep", "look: clothing OnRep hook: %s", tostring(err)) end
            end)
            if ok then
                onrep_hooked[path] = true
                log.info("look: clothing event hook ok (%s)", fn)
            end
        end
    end
end

-- ===========================================================================
-- 2. Publishing / applying looks
-- ===========================================================================

local tp_flags = {}   -- [component name] = flags last seen in third person (own character)

-- The game hides parts of the OWNER's body for its own camera only
-- (component visibility is not replicated; nobody else is meant to see it):
--   * first-person camera on (ChangePlayerPerspective(true, ..) @141,
--     SetFPMeshesVisibility(true) @49: Head & co hidden). The scope
--     (SetEnableScope @110) and binoculars (BinocularsVisibility @878) turn
--     it on WITHOUT PlayerInFirstPerson?, so that flag alone missed them;
--   * the scope: SetEnableScope @76 Mesh:SetVisibility(false, true) clears
--     bVisible of every body and clothing component ("v"), @954 sets it back.
-- Published as they were, those flags hid a scoping player's whole body (and
-- a binocular user's head) on the host and, relayed, on every other client.
local function fp_camera_on(pawn)
    local cam = ue.prop(pawn, "FirstPersonCamera")
    if not ue.valid(cam) then return false end
    local ok, on = pcall(function() return cam:IsActive() end)
    if ok and type(on) == "boolean" then return on end
    return ue.prop(cam, "bIsActive") == true   -- the flag behind IsActive()
end

local own_view = ""   -- "scope" / "fp" / "" of the last look_string, for the log

function M.look_string(pawn)
    local fp = ue.prop(pawn, "PlayerInFirstPerson?") == true or fp_camera_on(pawn)
    local mesh = ue.prop(pawn, "Mesh")
    local scoped = ue.valid(mesh) and ue.prop(mesh, "bVisible") == false
    local view = scoped and "scope" or (fp and "fp" or "")
    if view ~= own_view then
        own_view = view
        log.debug("look: own view now %s%s", view == "" and "third person" or view,
            view == "" and "" or " (hidden only for the own camera; others get the third-person flags)")
    end
    local parts = { "m=" .. ((ue.prop(pawn, "IsPlayerMale?") == true) and "1" or "0") }
    for _, comp in ipairs(mesh_comps(pawn)) do
        local name = ue.short(comp)
        if not SKIP_COMPS[name] and not transient_comp(name) and ue.prop(comp, "bOnlyOwnerSee") ~= true then
            local flags = flags_of(comp)
            if scoped then flags = (flags:gsub("v", "")) end
            if FP_COMPS[name] then
                if fp then flags = tp_flags[name] or "" else tp_flags[name] = flags end
            end
            parts[#parts + 1] = string.format("%s=%s,%s,%s", name, short_path(asset_path(comp)),
                short_path(material_path(comp)), flags)
        end
    end
    table.sort(parts, function(a, b)
        if a:sub(1, 2) == "m=" then return true end
        if b:sub(1, 2) == "m=" then return false end
        return a < b
    end)
    return table.concat(parts, ";")
end

-- The asset comes from a path sent over the network: native setters do not
-- check the type of what they get, so only a mesh of the matching kind is
-- passed (nil clears the mesh).
local function set_mesh(comp, asset)
    local acls = nil
    if asset ~= nil then
        if not ue.valid(asset) then return false end
        acls = ue.class_name(asset)
        if acls ~= "SkeletalMesh" and acls ~= "StaticMesh" then return false end
    end
    for _, fname in ipairs({ "SetSkinnedAssetAndUpdate", "SetSkeletalMeshAsset", "SetSkeletalMesh", "SetStaticMesh" }) do
        if acls == nil or (fname == "SetStaticMesh") == (acls == "StaticMesh") then
            local ok
            if fname == "SetSkinnedAssetAndUpdate" or fname == "SetSkeletalMesh" then
                ok = ue.call(comp, fname, asset, true)
            else
                ok = ue.call(comp, fname, asset)
            end
            if ok then return true end
        end
    end
    return false
end

local function is_material(o)
    if not ue.valid(o) then return false end
    local cls = ue.class_name(o)
    return cls == "Material" or cls:find("MaterialInstance", 1, true) ~= nil
end

-- "<component>|<path>" that could not be loaded or applied on this machine
-- (missing asset, other game / mod version): not loaded again every 2 s.
local bad_paths = {}

local function mark_bad(kind, key, pawn)
    if bad_paths[key] then return end
    bad_paths[key] = true
    log.warn("look: %s %s cannot be applied on %s here; not retried", kind, key, ue.short(pawn))
end

-- The sex part of a look (the clothes dressed from replicated data pick the
-- male / female mesh from it).
local function apply_sex(pawn, s)
    local m = s:match("^m=(%d)")
    if m then
        local want = m == "1"
        if (ue.prop(pawn, "IsPlayerMale?") == true) ~= want then ue.set_prop(pawn, "IsPlayerMale?", want) end
    end
end

-- A look from an older SDCoop (before look_string published the third-person
-- flags) still carries what the sender's own scope / binoculars camera hides:
-- "v" on every body and clothing part (SetEnableScope @76) and "h" on Head &
-- co (SetFPMeshesVisibility @49). Neither is ever part of the third-person
-- look (nothing else in the game clears bVisible of a player's part or hides
-- Head; HairMesh / BeardMesh "h" alone is the helmet / no beard), and a
-- version mismatch only warns, so such a look drops its "v" and leaves the
-- head flags as the last third-person look set them.
local function own_view_leaked(s)
    for entry in s:gmatch("[^;]+") do
        local name, flags = entry:match("^([^=]+)=[^,]*,[^,]*,(.*)$")
        if flags and (flags:find("v", 1, true) or (name == "Head" and flags:find("h", 1, true))) then
            return true
        end
    end
    return false
end
local leak_noted = {}   -- [pawn address] = true: logged once

-- skip: component names not to touch (dressed from replicated data).
local function apply_look(pawn, s, skip)
    local leader = ue.prop(pawn, "Mesh")
    local changed, failed = 0, 0
    local what = {}   -- "<component>:mesh|mat|flags old->new", for the log
    local leaked = own_view_leaked(s)
    if leaked then
        local key = addr(pawn) or ue.short(pawn)
        if not leak_noted[key] then
            leak_noted[key] = true
            log.info("look: %s sends the flags of its own scope / first-person camera (older SDCoop there?): "
                .. "kept visible, head as in its last third-person look", ue.short(pawn))
        end
    end
    for entry in s:gmatch("[^;]+") do
        local m = entry:match("^m=(%d)$")
        if m then
            ue.set_prop(pawn, "IsPlayerMale?", m == "1")
        else
            local name, mesh, mat, flags = entry:match("^([^=]+)=([^,]*),([^,]*),(.*)$")
            local comp = name and not (skip and skip[name]) and ue.prop(pawn, name)
            if ue.valid(comp) then
                local want = full_path(mesh)
                local mesh_key = name .. "|" .. want
                if asset_path(comp) ~= want and not bad_paths[mesh_key] then
                    local asset = load_asset(want)
                    local had = asset_path(comp)
                    if (want == "" or asset) and set_mesh(comp, asset) then
                        changed = changed + 1
                        what[#what + 1] = string.format("%s:mesh %s->%s", name, had:match("[^/.]+$") or had,
                            want:match("[^/.]+$") or want)
                        if asset and ue.valid(leader) and ue.valid(comp) and ue.class_name(comp):find("Skeletal", 1, true) then
                            pcall(function() comp:SetLeaderPoseComponent(leader, true, false) end)
                        end
                    else
                        failed = failed + 1
                        mark_bad("mesh", mesh_key, pawn)
                    end
                end
                local want_mat = full_path(mat)
                local mat_key = name .. "|" .. want_mat
                if want_mat ~= "" and material_path(comp) ~= want_mat and not bad_paths[mat_key] then
                    local m2 = load_asset(want_mat)
                    local had = material_path(comp) or ""
                    if is_material(m2) and ue.valid(comp) and pcall(function() comp:SetMaterial(0, m2) end) then
                        changed = changed + 1
                        what[#what + 1] = string.format("%s:mat %s->%s", name, had:match("[^/.]+$") or had,
                            want_mat:match("[^/.]+$") or want_mat)
                    else
                        failed = failed + 1
                        mark_bad("material", mat_key, pawn)
                    end
                end
                if leaked then flags = (flags:gsub("v", "")) end
                local had_flags = flags_of(comp)
                if not (leaked and FP_COMPS[name]) and had_flags ~= flags then
                    what[#what + 1] = string.format("%s:flags %s->%s", name, tostring(had_flags), tostring(flags))
                    pcall(function() comp:SetHiddenInGame(flags:find("h", 1, true) ~= nil, false) end)
                    pcall(function() comp:SetVisibility(flags:find("v", 1, true) == nil, false) end)
                    changed = changed + 1
                end
            end
        end
    end
    if changed > 0 or failed > 0 then
        local list = {}
        for i = 1, math.min(#what, 8) do list[i] = what[i] end
        log.info("look: %s updated (%d changes, %d failed): %s%s", ue.short(pawn), changed, failed,
            table.concat(list, ", "), #what > 8 and (" +" .. (#what - 8)) or "")
    end
end

local looks = {}        -- [player id] = look string (known on this machine)
local published = nil   -- own look last sent
local published_at = -1000
local LOOK_VERIFY_S = 300   -- a look is told again this often when it did not change (a lost message heals)

-- Host: a look to one client when that client has not got this text yet (a
-- changed look, a new client) or as the verify (sdc_netsync).
local function send_look(pc, id, s, forced)
    local peer, key = ue.name(pc), "LOOK:" .. id
    if not forced and not netsync.due(peer, key, s, LOOK_VERIFY_S) then return end
    if net.send_to(pc, "LOOK", id, s) then netsync.mark(peer, key, s) end   -- only a sent look counts as told
end

-- A client's own character whose co-op look (sdc_charcreate) is not on it
-- yet: its look is not published now - the host would put that default look
-- back on the character it has just given the right one (13.11: MYLOOK at
-- 17:00:03.7 with the old beard / brows / hair colour, the look itself put on
-- at 17:00:04.4, right on the host only at 17:00:05.8).
local function own_look_pending(me)
    if S.role ~= "client" then return false end
    local cc = package.loaded["sdc_charcreate"]
    if type(cc) ~= "table" or type(cc.own_look_pending) ~= "function" then return false end
    local ok, pending = pcall(cc.own_look_pending, me)
    return ok and pending == true
end

-- Every machine, every 2 s.
function M.tick(remote_pcs)
    if S.role == "host" then M.drop_left(looks, remote_pcs) end
    local me = ue.local_pawn()
    if S.role == "client" then try_hook_onreps() end
    if me then
        if S.role == "client" then M.dress(me, "tick") end
        local s = M.look_string(me)
        local id = player_id(me)
        if id and s ~= published and own_look_pending(me) then
            log.debug("look: own look not published yet (the co-op character's look is not on it yet)")
        elseif id and (s ~= published or os.clock() - published_at >= LOOK_VERIFY_S) then
            local changed = s ~= published
            published, published_at = s, os.clock()
            looks[id] = s
            if S.role == "client" then
                net.send_to_host("MYLOOK", s)
            end
            if changed then log.debug("look: own look published (%d bytes)", #s) end
        end
    end
    if S.role == "host" then
        -- every client has every look known here; only a changed one (or the
        -- verify) goes out
        for _, pc in ipairs(remote_pcs or {}) do
            if ue.valid(pc) then
                -- (a client's own look is not sent back to it)
                local pawn = ue.pawn_of(pc)
                local own = pawn and player_id(pawn) or nil
                for id, s in pairs(looks) do
                    if id ~= own then send_look(pc, id, s) end
                end
            end
        end
    end
    for _, p in ipairs(ue.player_chars() or {}) do
        if ue.valid(p) and not is_local(p) then
            local id = player_id(p)
            local s = id and looks[id]
            if S.role == "client" then
                if is_replicated(p) then
                    if s then apply_sex(p, s) end
                    local handled = M.dress(p, "tick")
                    if s then apply_look(p, s, handled) end
                end
            elseif s then
                apply_look(p, s)
            end
        end
    end
end

-- Host: every look known here to a client that said HI (players who left
-- are dropped first).
function M.send_all(pc)
    if S and S.role == "host" then M.drop_left(looks, S.remote_pcs) end
    for id, s in pairs(looks) do send_look(pc, id, s, true) end
end

function M.reset()
    looks, published, tp_flags, bad_paths, own_view, leak_noted = {}, nil, {}, {}, "", {}
end

function M.register_handlers()
    -- host -> clients: LOOK|player id|look
    net.on("LOOK", function(f)
        local id = tonumber(f[1])
        if id and f[2] then looks[math.floor(id)] = f[2] end
    end)
    -- client -> host: MYLOOK|look   (its own character)
    net.on("MYLOOK", function(f, pc)
        local pawn = ue.pawn_of(pc)
        local id = pawn and player_id(pawn)
        if not id or not f[1] then return end
        looks[id] = f[1]
        local others = {}
        for _, other in ipairs(S.remote_pcs or {}) do
            if addr(other) ~= addr(pc) then others[#others + 1] = other end
        end
        for _, other in ipairs(others) do send_look(other, id, f[1]) end
        apply_look(pawn, f[1])
    end)
end

return M
