-- sdc_wire: the short forms of the mod channel (UIDs, numbers) and sdc_progress'
-- short PSPROG field ids. Checks the round trips bit for bit and measures the
-- message sizes before / after (METRIC lines; "before" = the text the old
-- formats made, rebuilt here from the same values).
-- usage: lua mock_wire.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end

package.loaded["sdc_log"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["sdc_ue"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["sdc_config"] = { get = function() return nil end }

local wire = require("sdc_wire")
local progress = require("sdc_progress")

print("1. UIDs: bit-identical round trip, 22 characters, no separator characters")
local sample = "-399008991:1216681327:-1278485583:-941303400"
local e = wire.uid_enc(sample)
check(#sample == 44 and #e == 22, "44 -> 22 characters: " .. e)
wire.clear_cache()   -- (the machine that decodes has not encoded it)
check(wire.uid_dec(e) == sample, "decodes to the same text")
check(wire.uid_enc("0:0:0:0") == "AAAAAAAAAAAAAAAAAAAAAA" and wire.uid_dec("AAAAAAAAAAAAAAAAAAAAAA") == "0:0:0:0", "the empty UID")
local edge = { "-2147483648:2147483647:-1:0", "2147483647:-2147483648:1:-2", "-1:-1:-1:-1", "0:0:0:1", "1:0:0:0" }
local ok = true
for _, u in ipairs(edge) do
    local w = wire.uid_enc(u)
    wire.clear_cache()
    if wire.uid_dec(w) ~= u then ok = false; print("    " .. u) end
end
check(ok, "the int32 extremes and signs survive")
math.randomseed(7)
local bad, seen = 0, {}
for _ = 1, 20000 do
    local p = {}
    for i = 1, 4 do p[i] = math.random(-2147483648, 2147483647) end
    local u = string.format("%d:%d:%d:%d", p[1], p[2], p[3], p[4])
    local w = wire.uid_enc(u)
    wire.clear_cache()
    if wire.uid_dec(w) ~= u or #w ~= 22 or w:find("[^%w_%-]") then bad = bad + 1 end
    if seen[w] and seen[w] ~= u then bad = bad + 1 end
    seen[w] = u
end
check(bad == 0, "20000 random UIDs: exact, 22 characters of A-Za-z0-9-_ only, no two alike")
check(wire.uid_enc("12:34") == "" and wire.uid_enc("") == "" and wire.uid_enc(nil) == "" and wire.uid_enc("a:b:c:d") == "",
  "a text that is no GUID encodes to nothing")
check(wire.uid_enc("4294967296:0:0:0") == "", "a part beyond int32 is refused")
check(wire.uid_dec(nil) == nil and wire.uid_dec("") == nil and wire.uid_dec("short") == nil
  and wire.uid_dec("AAAAAAAAAAAAAAAAAAAAA!") == nil and wire.uid_dec(sample) == nil, "a bad text decodes to nil")
check(wire.uid_dec("AAAAAAAAAAAAAAAAAAAAAB") == nil, "the 22nd character's spare bits must be zero (only encoder output is read)")

print("2. numbers")
check(wire.num(86, 3) == "86" and wire.num(86.5, 3) == "86.5" and wire.num(0.125, 3) == "0.125" and wire.num(1.0000, 4) == "1",
  "whole numbers without a point, no trailing zeros")
check(wire.num(-0.0001, 2) == "0" and wire.num(-5.25, 2) == "-5.25" and wire.num(100, 0) == "100" and wire.num(20, 0) == "20",
  "no -0; an integer stays itself (the 20 of '120' is not eaten)")
check(tonumber(wire.num(42.5, 3)) == 42.5 and tonumber(wire.num(0.4, 4)) == 0.4, "the value is the same number")

print("3. PSPROG: short field ids, full and changed-only")
-- a character of some play time: every field has a value
local vals = {}
for _, g in ipairs(progress.FIELDS) do
    vals[g[1]] = {}
    for i, name in ipairs(g[3]) do
        local v = (i * 37.123456789) % 997
        if name:sub(-1) == "?" then v = (i % 2) == 0
        elseif name == "CurrentLevel" then v = 20
        elseif name:find("Kills") or name == "DaysSurvived" or name == "InfestationsDestroyed" then v = i * 3
        elseif name == "SkillPoints" or name == "CurrentPoints" then v = 4 end
        vals[g[1]][name] = v
    end
end
local old_text = progress.encode_values(vals)
local flat = progress.flat_of(old_text)
local full = progress.wire_encode(flat)
check(#full < #old_text * 0.55, string.format("the full report is under 55%% of the old text (%d -> %d bytes)", #old_text, #full))
check(progress.flat_text(progress.wire_decode(full)) == progress.flat_text(flat), "full: every field comes back")
local back = progress.decode_values(progress.flat_text(progress.wire_decode(full)))
local same = true
local ref = progress.decode_values(old_text)
for tag, t in pairs(ref) do
    for name, v in pairs(t) do if back[tag] == nil or back[tag][name] ~= v then same = false; print("    differs: " .. tag .. "." .. name) end end
end
check(same, "decoded values equal the old text's decode_values")
check(progress.major_key(progress.flat_text(progress.wire_decode(full))) == progress.major_key(old_text), "the 'at once' fields are found the same")
-- a trickle of XP: one field changes
local flat2 = {}
for k, v in pairs(flat) do flat2[k] = v end
flat2["P.CurrentFitnessXP"] = "12.5"
local delta = progress.wire_encode(flat2, flat)
check(delta ~= "" and not delta:find(";", 1, true) and #delta < 12, "one changed field: just that field (" .. delta .. ")")
check(progress.wire_encode(flat, flat) == "", "nothing changed: nothing")
-- the host's merge
local host = progress.wire_decode(full)
for k, v in pairs(progress.wire_decode(delta)) do host[k] = v end
check(host["P.CurrentFitnessXP"] == "12.5" and host["L.CurrentLevel"] == "20", "the host's copy: the changed field new, the rest kept")
check(progress.wire_decode("zz=1;0=5;junk")["L.CurrentLevel"] == "5" and next(progress.wire_decode("zz=1")) == nil,
  "an unknown id is ignored")
-- ids are unique and short
local ids, nid, longest = {}, 0, 0
for _, g in ipairs(progress.FIELDS) do
    for _, name in ipairs(g[3]) do
        local one = progress.wire_encode({ [g[1] .. "." .. name] = "1" })
        local id = one:match("^(.-)=")
        if ids[id] then check(false, "duplicate id " .. id) end
        ids[id] = true
        nid = nid + 1
        longest = math.max(longest, #id)
    end
end
check(nid > 70 and longest <= 2, "every field has its own id of 1-2 characters (" .. nid .. " fields)")

print("4. METRIC: sizes before / after (real-size UIDs)")
local function uid43(i) return string.format("%d:%d:%d:%d", -399008991 + i, 1216681327 - i, -1278485583, -941303400 + i * 7) end
-- JMC: an ad-hoc batch of 24 ops (counts, moves) for one container
local old_ops, new_ops = {}, {}
for i = 1, 24 do
    if i % 3 == 0 then
        old_ops[#old_ops + 1] = table.concat({ "mv", uid43(i), uid43(100), i, 0 }, ",")
        new_ops[#new_ops + 1] = table.concat({ "mv", wire.uid_enc(uid43(i)), wire.uid_enc(uid43(100)), i, 0 }, ",")
    else
        old_ops[#old_ops + 1] = table.concat({ "cnt", uid43(i), i * 10 }, ",")
        new_ops[#new_ops + 1] = table.concat({ "cnt", wire.uid_enc(uid43(i)), i * 10 }, ",")
    end
end
local jo = #("SDC1|JMC|*|" .. uid43(100) .. "|" .. table.concat(old_ops, "|"))
local jn = #("SDC1|JMC|*|" .. wire.uid_enc(uid43(100)) .. "|" .. table.concat(new_ops, "|"))
print(string.format("  METRIC JMC 24 ops: %d -> %d bytes", jo, jn))
check(jn < jo * 0.6, "JMC about 40% smaller")
-- ITEMS of 25 items, battery on 5 of them
local io_, in_ = {}, {}
for i = 1, 25 do
    local d, b = 100 - i * 2.37, 80 - i * 1.1
    io_[#io_ + 1] = string.format("%s=%.1f%s", uid43(i), d, i % 5 == 0 and string.format("/%.1f", b) or "")
    in_[#in_ + 1] = string.format("%s=%d%s", wire.uid_enc(uid43(i)), math.floor(d + 0.5), i % 5 == 0 and string.format("/%d", math.floor(b + 0.5)) or "")
end
local ito, itn = #table.concat(io_, ";"), #table.concat(in_, ";")
print(string.format("  METRIC ITEMS 25 items: %d -> %d bytes", ito, itn))
check(itn < ito * 0.55, "ITEMS about half")
-- PSPROG
local pro = #("SDC1|PSPROG|g1|" .. old_text .. "|Skill_A,Skill_B,Skill_C|" .. uid43(1) .. "," .. uid43(2) .. "," .. uid43(3))
local prn = #("SDC1|PSPROG|g1|" .. full .. "|Skill_A,Skill_B,Skill_C|" .. wire.uid_enc(uid43(1)) .. "," .. wire.uid_enc(uid43(2)) .. "," .. wire.uid_enc(uid43(3)) .. "|f")
local prd = #("SDC1|PSPROG|g1|" .. delta .. "|||d")
print(string.format("  METRIC PSPROG full: %d -> %d bytes; a trickle report: %d -> %d bytes", pro, prn, pro, prd))
check(prd < pro * 0.05, "a changed-only report is a few dozen bytes")
-- WBDOOR entry
local door_old = "Buildable_WoodenDoor_C 160579,129273,1735 0 0.000 -"
local door_new = "d 160579,129273,1735 0 0 -"
print(string.format("  METRIC WBDOOR entry: %d -> %d bytes", #door_old, #door_new))

print(string.format("wire: %d checks, %d failed", checks, fails))
print(fails == 0 and "ALL OK" or "FAILED")
os.exit(fails == 0 and 0 or 1)
