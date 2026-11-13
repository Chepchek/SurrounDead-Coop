-- Mock test (0.7.3): zombie names in each machine's own language.
-- sdc_ai_zombie builds a name from the class's default Name (its CDO) and
-- the Archetype_* format texts looked up by key in the game's localization
-- table (KismetTextLibrary.FindTextInLocalizationTable); the host sends the
-- name's form, a client builds that form in its own language.
-- usage: lua mock_zombie_names.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end

-- this machine's translation (key -> text); nil: no entry (the English source)
local LOC = {}
local LOOKUP_BROKEN = false
local lookups = 0
local lib = {
    FindTextInLocalizationTable = function(_, ns, key, out, src)
        lookups = lookups + 1
        if LOOKUP_BROKEN then error("no such function") end
        assert(ns == "", "namespace")
        local t = LOC[key]
        if t then out.OutText = { text = t } return true end
        return false
    end,
}
local CDO = {
    BP_Zombie_Roamer_C = { Name = { text = "Undead" } },
    BP_Zombie_Dog_C = { Name = { text = "Undead Feral Hound" } },
}
local function zombie(cls)
    return { _class = cls, GetClass = function() return { GetCDO = function() return CDO[cls] end } end }
end
FName = function(s) return s end
FText = function(s) return { text = s } end
local ue = setmetatable({
    valid = function(o) return type(o) == "table" end,
    try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end,
    str = function(v) if type(v) == "table" then return v.text or "" end return v and tostring(v) or "" end,
    prop = function(o, k) return type(o) == "table" and o[k] or nil end,
    class_name = function(o) return o and o._class or "" end,
    path = function() return "" end,
    find_object = function(p) if p == "/Script/Engine.Default__KismetTextLibrary" then return lib end end,
}, { __index = function() return function() return nil end end })
package.loaded["sdc_ue"] = ue

local zi = require("sdc_ai_zombie")
local K = {}
for letter, e in pairs(zi.NAME_TEXTS) do K[letter] = e[1] end
local function reset()
    for _, c in pairs(zi._name_cache) do for k in pairs(c) do c[k] = nil end end
end

-- 1. an English game (no entries in the live table): the English sources
local roamer, dog = zombie("BP_Zombie_Roamer_C"), zombie("BP_Zombie_Dog_C")
check(zi.build_name(roamer, "") == "Undead", "base: the class default")
check(zi.build_name(roamer, "s") == "Undead Sprinter", "sprinter: " .. tostring(zi.build_name(roamer, "s")))
check(zi.build_name(roamer, "h") == "Undead Shambler", "shambler")
check(zi.build_name(roamer, "ct") == "Toughened Undead Crawler", "toughened crawler: Crawler then Toughened")
check(zi.build_name(roamer, "u") == "Ultra-Radiated Undead", "ultra-radiated: a whole name")
check(zi.build_name(dog, "A") == "Armored Undead Feral Hound", "armoured hound: a whole name")
for _, f in ipairs(zi.NAME_FORMS) do
    local n = zi.build_name(roamer, f)
    check(n and zi.name_form(roamer, n) == f, "form '" .. f .. "' round trip: " .. tostring(n))
end
check(zi.arch_of(roamer, "Undead Sprinter") == "s" and zi.arch_of(roamer, "Toughened Undead Crawler") == "ct",
    "arch from the form")
check(zi.rolled(roamer, "Undead Shambler") and not zi.rolled(roamer, "Undead"), "rolled: shambler yes, base no")
check(zi.is_armored(dog, "Armored Undead Feral Hound") and not zi.is_armored(dog, "Undead Feral Hound"), "armoured by form")
local n0 = lookups
zi.name_form(roamer, "Undead Sprinter")
zi.build_name(roamer, "s")
check(lookups == n0, "texts and forms are cached (no lookup again)")

-- 2. a Russian translation here (a translation mod: its own table entries)
reset()
LOC = {
    [K.h] = "{A}-шатун", [K.c] = "{A}-ползун", [K.t] = "Закалённый {A}", [K.s] = "{A}-бегун",
    [K.a] = "Кислотный {A}", [K.g] = "{A}-гренадёр", [K.r] = "{A}-крикун",
    [K.u] = "Сверхрадиоактивная нежить", [K.A] = "Бронированная гончая-нежить",
}
CDO.BP_Zombie_Roamer_C.Name.text = "Нежить"
check(zi.build_name(roamer, "s") == "Нежить-бегун", "Russian: sprinter " .. tostring(zi.build_name(roamer, "s")))
check(zi.build_name(roamer, "ct") == "Закалённый Нежить-ползун", "Russian: toughened crawler")
check(zi.build_name(roamer, "u") == "Сверхрадиоактивная нежить", "Russian: whole name")
check(zi.name_form(roamer, "Нежить-бегун") == "s" and zi.arch_of(roamer, "Нежить-бегун") == "s",
    "a Russian host: its own name's form and arch")
check(zi.rolled(roamer, "Нежить-шатун") and not zi.rolled(roamer, "Нежить"), "a Russian host: rolled by form")
check(zi.name_form(roamer, "Undead Sprinter") == nil and zi.arch_of(roamer, "Undead Sprinter") == "s",
    "a name not of this game: no form, the English parse as before")
check(zi.name_form(roamer, "Something else") == nil and zi.arch_of(roamer, "Something else") == "-", "an unknown name")
-- a % in a text does not break the substitution
LOC[K.s] = "{A} 100%"
reset()
check(zi.build_name(roamer, "s") == "Нежить 100%", "a % in the text")

-- 3. the lookup itself fails: nothing is built (the host's text is used)
reset()
LOOKUP_BROKEN = true
check(zi.build_name(roamer, "s") == nil and zi.build_name(roamer, "") == "Нежить", "lookup broken: no format, base still")
check(zi.name_form(roamer, "Нежить-бегун") == nil and zi.arch_of(roamer, "Нежить-бегун") == "-",
    "lookup broken: no form; the English parse finds nothing in a Russian name")
LOOKUP_BROKEN = false

-- 4. a class without a default Name
reset()
local odd = zombie("BP_Zombie_Unknown_C")
check(zi.build_name(odd, "s") == nil and zi.name_form(odd, "x") == nil, "no default Name: nothing built")

print = real_print
print(string.format("zombie names: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
