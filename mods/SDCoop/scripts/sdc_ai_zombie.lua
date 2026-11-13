-- SDCoop: read-only helpers that describe a zombie (BP_MasterZombie_C and its
-- children) for the zombie features (sdc_ai_looks, sdc_ai_killlog). No state,
-- nothing kept: every function takes a fresh wrapper and returns strings and
-- numbers.
--
-- What makes zombies look different (BP_MasterZombie, see work\audit\zombie_sync.md):
--   BeginPlay -> Event_SetMeshAndMaterial: random Meshes_Soft / Materials_Soft
--     entry, loaded async (LoadAsset -> OnLoaded_D22F.. sets the mesh,
--     OnLoaded_A775.. slot 0's material); then Delay(1..1.25) -> SelectArchetype:
--     RandomIntegerInRange per *ArchetypeChance -> one Archetype_* event.
--   Archetype_Crawler (@28813 -> @27774): Name "{A} Crawler", blendspace
--     CrawlerAILocomotion, CapsuleHalfHeight 75 -> 40, the capsule (the root)
--     moved 35 cm down, Mesh relative location (0,0,-75) -> (-3,0,-32), one calf
--     and the other foot hidden, then an 8 % roll for ToughenedCrawler (random
--     mesh / material).
--   None of it is replicated (only IsDead? is).

local ue = require("sdc_ue")

local M = {}

-- bones the archetypes hide: crawler legs (@28041..), screamer arms + jaw (@27541..)
M.BONES = { "calf_l", "calf_r", "Foot_L", "Foot_R", "lowerarm_l", "lowerarm_r", "Jaw" }

-- standing capsule half height is 75, a crawler's 40 (Archetype_Crawler @27785)
M.CRAWLER_HH = 60

M.vec = ue.vec

-- Archetype letters from a Name as the Archetype_* events set it:
-- c crawler, t toughened (crawler), s sprinter, u ultra-radiated, a acidic,
-- g grenadier, r screamer; "-" none.
function M.arch_from_name(name)
    local n = name or ""
    local s = ""
    local tough = n:find("^Toughened ") ~= nil
    if tough or n:find(" Crawler$") then s = s .. "c" end
    if tough then s = s .. "t" end
    if n:find(" Sprinter$") then s = s .. "s" end
    if n:find("^Ultra%-Radiated") then s = s .. "u" end
    if n:find("^Acidic ") then s = s .. "a" end
    if n:find(" Grenadier$") then s = s .. "g" end
    if n:find(" Screamer$") then s = s .. "r" end
    if s == "" then return "-" end
    return s
end

-- Has this zombie rolled (SelectArchetype renames it)?
function M.rolled_name(name)
    return (name or ""):find(" Shambler$") ~= nil or M.arch_from_name(name) ~= "-"
end

-- The Feral Hound's armour (BP_Zombie_Dog ubergraph @264) renames it.
function M.armored(n) return (n or ""):find("Armored", 1, true) ~= nil end

-- ---------------------------------------------------------------------------
-- Names in this machine's language
-- ---------------------------------------------------------------------------
-- A zombie's Name is its class's default Name (BP_Zombie_Roamer "Undead",
-- BP_Zombie_Radiated "Radiated Undead", BP_Zombie_Dog "Undead Feral Hound",
-- ...) put through the text its Archetype_* event formats it with
-- (BP_MasterZombie: "{A} Sprinter", "Acidic {A}", ...; Toughened after
-- Crawler), or replaced whole ("Ultra-Radiated Undead", the hound's armour).
-- All are localized texts, so a host with a translation shows them in its
-- language; the host sends which FORM its zombie's name is and each client
-- builds that form from its own game's texts. Forms: "" not rolled, "h"
-- shambler, "c" / "ct" crawler / toughened crawler, "s", "a", "g", "r",
-- "u" (whole), "A" (the armoured hound, whole).
-- The format texts by key in the game's localization table (namespace "",
-- English source; work/re/json/BP_MasterZombie.json, BP_Zombie_Dog.json, 0.8.0).
local NAME_TEXTS = {
    h = { "A350A34C4C78C0E382329DB6B8FB5CF5", "{A} Shambler" },
    c = { "393D6D484BFA1908C89999819243C8F4", "{A} Crawler" },
    t = { "CF15AD12487D4B530D17139E6E5C98F5", "Toughened {A}" },
    s = { "B75C469844FBE9A3913930AF445FFC73", "{A} Sprinter" },
    a = { "BA9E1A864BD9F111621D4BB181A81DDC", "Acidic {A}" },
    g = { "A0F3F08F4B606F17913742B1541DF96F", "{A} Grenadier" },
    r = { "FAAE5E9D4834EA4B05C7C9B33C9AB988", "{A} Screamer" },
    u = { "8532F4A247CFF485D199F9AB452B671F", "Ultra-Radiated Undead" },
    A = { "3A4D1C264174094B82E619911498014D", "Armored Undead Feral Hound" },
}
M.NAME_TEXTS = NAME_TEXTS
M.NAME_FORMS = { "", "h", "c", "ct", "s", "a", "g", "r", "u", "A" }
local WHOLE = { u = true, A = true }
local TEXT_LIB = "/Script/Engine.Default__KismetTextLibrary"
local texts = {}     -- form letter -> this game's text; false: no way to look it up here
local bases = {}     -- class name -> its default Name here ("" unknown)
local forms = {}     -- class name .. "|" .. a name -> its form (false: none)
M._name_cache = { texts = texts, bases = bases, forms = forms }   -- tests

-- This game's text of a format / whole name. Not in the live table (no
-- translation loaded for it here): the English source, which is what this
-- game shows then. nil when the lookup itself fails (then nothing is built).
local function local_text(letter)
    local t = texts[letter]
    if t ~= nil then return t or nil end
    local e = NAME_TEXTS[letter]
    local lib = e and ue.find_object(TEXT_LIB)
    if not lib then texts[letter] = false return nil end
    local out = {}
    local ok, found = pcall(function() return lib:FindTextInLocalizationTable("", e[1], out, e[2]) end)
    if not ok then texts[letter] = false return nil end
    local s = found and ue.str(out.OutText) or ""
    if s == "" then s = e[2] end
    texts[letter] = s
    return s
end

-- The class's default Name here (its CDO, in this game's language).
local function base_name(z)
    local cls = ue.class_name(z)
    if cls == "" then return nil end
    local b = bases[cls]
    if b == nil then
        local cdo = ue.try(function() return z:GetClass():GetCDO() end)
        if not ue.valid(cdo) then
            local p = ue.path(ue.try(function() return z:GetClass() end))
            if p ~= "" then cdo = ue.find_object((p:gsub("%.([^%.:]+)$", ".Default__%1"))) end
        end
        b = ue.valid(cdo) and ue.str(ue.prop(cdo, "Name")) or ""
        bases[cls] = b
    end
    return b ~= "" and b or nil
end

-- The name of zombie `z`'s class in form `form`, in this game's language;
-- nil when it cannot be built here.
function M.build_name(z, form)
    if type(form) ~= "string" then return nil end
    if WHOLE[form] then return local_text(form) end
    local name = base_name(z)
    if not name then return nil end
    for letter in form:gmatch(".") do
        local p = local_text(letter)
        if not p then return nil end
        local a = name
        name = (p:gsub("{A}", function() return a end))
    end
    return name
end

-- Which form `name` is for `z`'s class (the name as this game shows it);
-- nil when none matches (a translation patched into the assets, a name
-- from elsewhere).
function M.name_form(z, name)
    if type(name) ~= "string" or name == "" then return nil end
    local ck = ue.class_name(z) .. "|" .. name
    local f = forms[ck]
    if f == nil then
        f = false
        for _, cand in ipairs(M.NAME_FORMS) do
            if M.build_name(z, cand) == name then f = cand break end
        end
        forms[ck] = f
    end
    return f or nil
end

-- Archetype letters of a form ("-" none).
function M.form_arch(f)
    local s = (f or ""):gsub("[hA]", "")
    return s == "" and "-" or s
end

-- Language-free versions of arch_from_name / rolled_name / armored: by the
-- form of the name when it is one of this game's, else the English parse.
function M.arch_of(z, name)
    local f = M.name_form(z, name)
    if f then return M.form_arch(f) end
    return M.arch_from_name(name)
end

function M.rolled(z, name)
    local f = M.name_form(z, name)
    if f then return f ~= "" and f ~= "A" end
    return M.rolled_name(name)
end

function M.is_armored(z, name)
    local f = M.name_form(z, name)
    if f then return f == "A" end
    return M.armored(name)
end

function M.obj_path(o)
    if not ue.valid(o) then return "" end
    return ue.path(o)
end

-- "/Game/X/SK_Foo.SK_Foo" -> "SK_Foo"
function M.short_asset(path)
    if type(path) ~= "string" or path == "" then return "-" end
    return path:match("%.([^%.:/]+)$") or path:match("([^/]+)$") or path
end

function M.mesh_asset(mesh)
    for _, p in ipairs({ "SkeletalMeshAsset", "SkeletalMesh" }) do
        local a = ue.prop(mesh, p)
        if ue.valid(a) then return a end
    end
    local a = ue.try(function() return mesh:GetSkeletalMeshAsset() end)
    if ue.valid(a) then return a end
    return nil
end

-- slot 0 below the eyes' MaterialInstanceDynamic (EyesColour makes one)
function M.base_material(mesh)
    local m = ue.try(function() return mesh:GetMaterial(0) end)
    for _ = 1, 4 do
        if not ue.valid(m) or ue.class_name(m) ~= "MaterialInstanceDynamic" then break end
        m = ue.prop(m, "Parent")
    end
    if ue.valid(m) then return m end
    return nil
end

-- "calf_l,Foot_R" | "-" (none) | "?" (cannot tell)
function M.hidden_bones(mesh)
    local out = {}
    for _, b in ipairs(M.BONES) do
        local ok, h = pcall(function() return mesh:IsBoneHiddenByName(FName(b)) end)
        if not ok then return "?" end
        if h == true then out[#out + 1] = b end
    end
    if #out == 0 then return "-" end
    return table.concat(out, ",")
end

function M.anim_of(mesh)
    local a = ue.try(function() return mesh:GetAnimInstance() end)
    if ue.valid(a) then return a end
    return nil
end

-- The capsule's half height, or nil (no capsule: a host corpse, BP Death @5).
function M.capsule_hh(z)
    local cap = ue.prop(z, "CapsuleComponent")
    if not ue.valid(cap) then return nil end
    local hh = ue.prop(cap, "CapsuleHalfHeight")
    if type(hh) ~= "number" then hh = ue.try(function() return cap:GetUnscaledCapsuleHalfHeight() end) end
    if type(hh) == "number" then return hh end
    return nil
end

-- The mesh's place under the capsule: { X, Y, Z, Yaw } or nil.
function M.mesh_rel(mesh)
    local l = M.vec(ue.prop(mesh, "RelativeLocation"))
    if not l then return nil end
    local yaw = ue.try(function() return ue.prop(mesh, "RelativeRotation").Yaw end)
    l.Yaw = type(yaw) == "number" and yaw or -90
    return l
end

local function r1(v) return (string.format("%.1f", v):gsub("%.0$", "")) end

-- Live body as sent to clients: "hh,x,y,z,yaw" or "" (dead / unreadable).
function M.body_string(z, mesh)
    if ue.prop(z, "IsDead?") == true then return "" end
    local hh = M.capsule_hh(z)
    local rel = mesh and M.mesh_rel(mesh)
    if not hh or not rel then return "" end
    return table.concat({ r1(hh), r1(rel.X), r1(rel.Y), r1(rel.Z), r1(rel.Yaw) }, ",")
end

function M.parse_body(s)
    if type(s) ~= "string" or s == "" then return nil end
    local a, b, c, d, e = s:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
    local hh, x, y, z, yaw = tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e)
    if not (hh and x and y and z and yaw) or hh < 10 or hh > 200 then return nil end
    return { hh = hh, X = x, Y = y, Z = z, Yaw = yaw }
end

-- "BP_Zombie_Roamer_C" -> "Zombie_Roamer"
function M.type_of(o)
    local cn = ue.class_name(o)
    if cn == "" then return "?" end
    return (cn:gsub("^BP_", ""):gsub("_C$", ""))
end

-- Where the body is (the mesh: a host corpse has no capsule, so no actor location).
function M.where(z)
    local mesh = ue.prop(z, "Mesh")
    local l = ue.valid(mesh) and M.vec(ue.try(function() return mesh:K2_GetComponentLocation() end)) or nil
    if not l then l = ue.location(z) end
    return l
end

-- Everything the kill log / look check needs, as strings and numbers.
function M.describe(z)
    local mesh = ue.prop(z, "Mesh")
    local name = ue.str(ue.prop(z, "Name"))
    local d = {
        obj = ue.short(z), type = M.type_of(z), name = name, arch = M.arch_of(z, name),
        mesh = "-", mat = "-", hh = M.capsule_hh(z), loc = M.where(z),
    }
    if ue.valid(mesh) then
        d.mesh = M.short_asset(M.obj_path(M.mesh_asset(mesh)))
        d.mat = M.short_asset(M.obj_path(M.base_material(mesh)))
    end
    d.crawler = d.arch:find("c", 1, true) ~= nil or (d.hh ~= nil and d.hh < M.CRAWLER_HH)
    return d
end

return M
