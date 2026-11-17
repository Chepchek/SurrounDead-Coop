-- sdc_markerdata: the game's map markers keep their look in ONE struct, S_MarkerData, in the property
-- "MarkerData" of the marker actor.
--
-- Game update of 17.11.2026 (Steam build 26730515): BP_Marker_C and BP_QuestMarker_C lost the separate
-- properties the mod used to read and set (MarkerTexture / MarkerTitle / Texture Size / Color /
-- AddMarkerToCompass? on BP_Marker; Marker Texture / Text / Color / Underground? on BP_QuestMarker) and
-- got "MarkerData" instead. BP_Marker keeps MarkerDescription; the struct gained DiscoverableRadius (the
-- quest marker's search circle). The members of a user defined struct carry their GUIDs in the name
-- (the same names sdc_playermarks uses for the map's DefaultPlayerMarkerData).
--
-- read(actor)  -> { title, tex, size, text_size, color, compass, ug, radius } of what the actor holds
--                 (a missing member is nil / false), or nil when the actor has no MarkerData.
-- write(actor, spec) sets the members present in spec (title string, tex object, size {X,Y}, text_size,
--                 color {R,G,B,A}, compass bool, ug bool, radius number) on a marker that is not
--                 finished spawning yet (its BeginPlay builds the map marker from MarkerData).
--                 Returns ok, how: "members" (set through the live struct), "struct" (the whole
--                 struct assigned from a table; the first way did not stick) or the reason.
local ue = require("sdc_ue")

local M = {}

M.PROP = "MarkerData"
M.F = {
    title     = "MarkerTitle_47_5E7A698C4B5AC497BBB438A55515B853",
    texture   = "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD",
    tex_size  = "TextureSize_30_0FC614D34939DCCA4077899925344EDF",
    text_size = "TextSize_33_ADA10B73491C7DD1835FD69801CC42F1",
    color     = "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872",
    tip_color = "TooltipBorderColor_55_45E57FFE40453BB296F6D7A44B06A8D2",
    compass   = "CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4",
    ug        = "Underground?_57_38CF16D4418981C9C884F689373DF3A8",
    radius    = "DiscoverableRadius_60_C185CCC34DB7347746D2C281FBDCA1F1",
}

local function num(v) return type(v) == "number" and v or nil end

local function member(d, key)
    return ue.try(function() return d[M.F[key]] end)
end

local function vec2(v)
    if v == nil then return nil end
    local x, y = num(ue.try(function() return v.X end)), num(ue.try(function() return v.Y end))
    if x and y then return { X = x, Y = y } end
    return nil
end

local function rgba(v)
    if v == nil then return nil end
    local r, g, b, a = num(ue.try(function() return v.R end)), num(ue.try(function() return v.G end)),
        num(ue.try(function() return v.B end)), num(ue.try(function() return v.A end))
    if r and g and b and a then return { R = r, G = g, B = b, A = a } end
    return nil
end

function M.read(actor)
    if not ue.valid(actor) or not ue.has_prop(actor, M.PROP) then return nil end
    local d = ue.prop(actor, M.PROP)
    if d == nil then return nil end
    local tex = member(d, "texture")
    local title = ue.fstring(member(d, "title"))
    if ue.is_wrapper_text(title) then title = "" end
    return {
        title = title,
        tex = ue.valid(tex) and tex or nil,
        size = vec2(member(d, "tex_size")),
        text_size = vec2(member(d, "text_size")),
        color = rgba(member(d, "color")),
        compass = member(d, "compass") == true,
        ug = member(d, "ug") == true,
        radius = num(member(d, "radius")),
    }
end

-- The members a spec asks for, as {F-name = value}. FText: the engine's text type (a Lua string does
-- not go into a TextProperty from a table).
local function member_values(spec)
    local t = {}
    if spec.tex ~= nil then t[M.F.texture] = spec.tex end
    if spec.title ~= nil then t[M.F.title] = FText(spec.title) end
    if spec.size then t[M.F.tex_size] = { X = spec.size.X, Y = spec.size.Y } end
    if spec.text_size then t[M.F.text_size] = { X = spec.text_size.X, Y = spec.text_size.Y } end
    if spec.color then t[M.F.color] = { R = spec.color.R, G = spec.color.G, B = spec.color.B, A = spec.color.A } end
    if spec.compass ~= nil then t[M.F.compass] = spec.compass == true end
    if spec.ug ~= nil then t[M.F.ug] = spec.ug == true end
    if spec.radius then t[M.F.radius] = spec.radius end
    return t
end

-- What was asked reads back from the actor.
local function stuck(actor, spec)
    local got = M.read(actor)
    if not got then return false end
    if spec.title ~= nil and got.title ~= spec.title then return false end
    if spec.tex ~= nil and not (got.tex and ue.path(got.tex) == ue.path(spec.tex)) then return false end
    if spec.ug ~= nil and got.ug ~= (spec.ug == true) then return false end
    if spec.compass ~= nil and got.compass ~= (spec.compass == true) then return false end
    if spec.radius and got.radius ~= spec.radius then return false end
    if spec.color and not (got.color and math.abs(got.color.R - spec.color.R) < 1e-3
        and math.abs(got.color.G - spec.color.G) < 1e-3 and math.abs(got.color.B - spec.color.B) < 1e-3) then
        return false
    end
    return true
end

function M.write(actor, spec)
    if not ue.valid(actor) then return false, "no actor" end
    if not ue.has_prop(actor, M.PROP) then return false, "the actor has no " .. M.PROP end
    spec = spec or {}
    local values = member_values(spec)
    local d = ue.prop(actor, M.PROP)
    local bad = {}
    for name, v in pairs(values) do
        local ok = pcall(function() d[name] = v end)
        if not ok then bad[#bad + 1] = name end
    end
    if #bad == 0 and stuck(actor, spec) then return true, "members" end
    -- the live struct did not take it: assign the whole struct from a table
    if ue.set_prop(actor, M.PROP, values) and stuck(actor, spec) then return true, "struct" end
    return false, "MarkerData did not take the values (" .. (#bad > 0 and ("members refused: " .. #bad) or "read back differs") .. ")"
end

return M
