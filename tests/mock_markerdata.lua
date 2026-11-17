-- Mock harness: sdc_markerdata - reading and writing the S_MarkerData struct of BP_Marker / BP_QuestMarker
-- (the game's 17.11.2026 layout: the look of a map marker is ONE struct property, MarkerData).
-- usage: lua mock_markerdata.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local ue = {}
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and rawget(o, "__valid") ~= false end
function ue.has_prop(o, n) return ue.valid(o) and o[n] ~= nil end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.set_prop(o, n, v) if not ue.valid(o) then return false end o[n] = v return true end
function ue.fstring(v)
  if v == nil then return "" end
  if type(v) == "table" and v.ToString then return v:ToString() end
  return tostring(v)
end
function ue.is_wrapper_text(s) return type(s) == "string" and s:find("^RemoteUnrealParam") ~= nil end
function ue.path(o) return ue.valid(o) and (rawget(o, "__path") or "") or "" end
package.loaded["sdc_ue"] = ue
FText = function(s) return { ToString = function() return s end, _s = s } end

local MD = require("sdc_markerdata")
local F = MD.F
local TEX = { __path = "/Game/UI/T_Camp.T_Camp" }
local TEX2 = { __path = "/Game/UI/T_Other.T_Other" }

-- A struct the way UE4SS hands it out: a live reference, member writes go through.
local function live_struct() return {} end
-- A struct that is a COPY: writes to the member go nowhere (the whole-struct assignment is the way).
local function copy_struct_actor()
  local store = {}
  local actor = {}
  return setmetatable(actor, {
    __index = function(_, k)
      if k ~= "MarkerData" then return nil end
      return setmetatable({}, { __index = function(_, m) return store[m] end, __newindex = function() end })
    end,
    __newindex = function(_, k, v)
      if k == "MarkerData" then for m, val in pairs(v) do store[m] = val end end
    end,
  })
end

print("A. read of the host's marker:")
local host = { MarkerData = {
  [F.title] = FText("Crashed Helicopter"), [F.texture] = TEX, [F.tex_size] = { X = 3.5, Y = 3.5 },
  [F.text_size] = { X = 1, Y = 1 }, [F.color] = { R = 0.5, G = 0.25, B = 0.125, A = 1 },
  [F.compass] = false, [F.ug] = true, [F.radius] = 3000 } }
local r = MD.read(host)
check(r and r.title == "Crashed Helicopter" and r.tex == TEX and r.ug == true and r.compass == false and r.radius == 3000,
  "A1: title (FText -> string), texture, underground, compass, radius")
check(r.size.X == 3.5 and r.text_size.Y == 1 and r.color.G == 0.25, "A2: sizes and colour")
check(MD.read({}) == nil, "A3: an actor without MarkerData (the old layout): nil")
check(MD.read(nil) == nil, "A4: no actor: nil")
local bare = MD.read({ MarkerData = {} })
check(bare and bare.title == "" and bare.tex == nil and bare.ug == false and bare.radius == nil and bare.size == nil,
  "A5: an empty struct reads as empty (no invented numbers)")
local wrapped = MD.read({ MarkerData = { [F.title] = "RemoteUnrealParam: 0000001" } })
check(wrapped.title == "", "A6: a wrapper's own text is never a title")

print("B. write through the live struct:")
local a = { MarkerData = live_struct() }
local ok, how = MD.write(a, { tex = TEX, title = "Camp", size = { X = 4, Y = 4 }, color = { R = 1, G = 0.5, B = 0, A = 1 },
  compass = true, ug = true, radius = 2500, text_size = { X = 1, Y = 1 } })
check(ok == true and how == "members", "B1: members set, how = members")
local b = MD.read(a)
check(b.title == "Camp" and b.tex == TEX and b.compass == true and b.ug == true and b.radius == 2500 and b.size.X == 4
  and b.color.G == 0.5 and b.text_size.X == 1, "B2: everything reads back")
local a2 = { MarkerData = live_struct() }
MD.write(a2, { title = "Only title" })
local b2 = MD.read(a2)
check(b2.title == "Only title" and b2.tex == nil and b2.radius == nil, "B3: a spec without the other members leaves them alone")

print("C. the live struct is a copy: the whole struct goes in from a table:")
local c = copy_struct_actor()
local okc, howc = MD.write(c, { tex = TEX2, title = "Copy path", ug = true, radius = 1000, color = { R = 0.1, G = 0.2, B = 0.3, A = 1 } })
check(okc == true and howc == "struct", "C1: falls back to the struct assignment: " .. tostring(howc))
local rc = MD.read(c)
check(rc.title == "Copy path" and rc.tex == TEX2 and rc.ug == true and rc.radius == 1000, "C2: and it reads back")

print("D. failures are reported, never thrown:")
local okd, whyd = MD.write({}, { title = "x" })
check(okd == false and whyd:find("no MarkerData", 1, true) ~= nil, "D1: no MarkerData: false + reason: " .. tostring(whyd))
local okn, whyn = MD.write(nil, { title = "x" })
check(okn == false and whyn == "no actor", "D2: no actor: false")
local dead = { MarkerData = live_struct(), __valid = false }
check(MD.write(dead, { title = "x" }) == false, "D3: a destroyed actor: false")
-- an actor whose struct nothing can change (member writes and the whole-struct assignment are dropped)
local fstore = {}
local frozen = setmetatable({}, { __index = function(_, k) if k == "MarkerData" then return setmetatable({}, { __index = function() return nil end, __newindex = function() end }) end end,
  __newindex = function() end })
local okf, whyf = MD.write(frozen, { title = "stuck", ug = true })
check(okf == false and whyf:find("did not take", 1, true) ~= nil, "D4: nothing sticks anywhere: false + reason: " .. tostring(whyf))
-- a member write that raises: no error escapes; the whole-struct assignment still gets it in
local errw = { MarkerData = setmetatable({}, { __newindex = function() error("write refused") end }) }
local oke, howe = MD.write(errw, { title = "x" })
check(oke == true and howe == "struct", "D5: a member write that raises: no error escapes, the struct assignment takes over (" .. tostring(howe) .. ")")

print("")
print(checks .. " checks, " .. fails .. " failed")
os.exit(fails == 0 and 0 or 1)
