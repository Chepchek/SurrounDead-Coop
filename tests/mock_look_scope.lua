-- Mock harness for sdc_appearance.look_string: the own look is published as
-- in third person. Report: a client looking through a scope vanished on the
-- host (only its attached gear stayed). The game's SetEnableScope hides the
-- owner's whole body for its own camera (Mesh:SetVisibility(false, true) ->
-- bVisible false on every body / clothing component) and turns the
-- first-person camera on without PlayerInFirstPerson? (head hidden); the
-- look carried those flags ("v", "hv") and the host applied them. The same
-- for binoculars (head only). Real sdc_appearance; sdc_ue / sdc_log /
-- sdc_net / sdc_ctx are stubs. The end: a second copy of the module as the
-- host (MYLOOK applied to its copy of the client and relayed to a third
-- player; the host's own scope: hidden only for its own camera). A look from
-- an older SDCoop (raw "v" / head "h" of its own scope or binoculars; a
-- version mismatch only warns) does not hide the body or head either.
-- usage: lua mock_look_scope.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what) end
end

package.loaded["sdc_log"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["sdc_net"] = { on = function() end, broadcast = function() end, send_to = function() end,
                              send_to_host = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o end }
package.loaded["sdc_ue"] = {
    valid = function(o) return type(o) == "table" end,
    prop = function(o, n) if type(o) ~= "table" then return nil end return o[n] end,
    short = function(o) return type(o) == "table" and o.__name or "<none>" end,
    path = function(o) return type(o) == "table" and (o.__path or "") or "" end,
    class_name = function(o) return type(o) == "table" and (o.__cls or "") or "" end,
    find_object = function() return { __name = "MeshComponent" } end,
    try = function(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end return nil end,
}
local appearance = require("sdc_appearance")
appearance.init({ role = "client" })

local BODY = { "Arms", "Biceps", "Clothing_Armor", "Clothing_Torso", "Clothing_Legs", "Feet", "Hands", "Legs", "Torso" }
local HEAD = { "Head", "Mouth", "EyebrowsMesh", "Accessory1", "HairMesh", "BeardMesh" }

local comps, by = {}, {}
local function new_comp(name)   -- with the setters apply_look calls (a look applied by mistake shows up)
    local c = { __name = name, __cls = "SkeletalMeshComponent", bVisible = true, bHiddenInGame = false }
    function c:SetVisibility(on) self.bVisible = on end
    function c:SetHiddenInGame(h) self.bHiddenInGame = h end
    return c
end
local function comp(name)
    local c = new_comp(name)
    comps[#comps + 1] = c
    by[name] = c
end
for _, n in ipairs(BODY) do comp(n) end
for _, n in ipairs(HEAD) do comp(n) end
local mesh = { __name = "CharacterMesh0", bVisible = true, bHiddenInGame = false }
local cam = { __name = "FirstPersonCamera", on = false }
function cam:IsActive() return self.on end
local pawn = { __name = "BP_PlayerCharacter_C_1", ["IsPlayerMale?"] = true, ["PlayerInFirstPerson?"] = false,
               Mesh = mesh, FirstPersonCamera = cam }
function pawn:K2_GetComponentsByClass() return comps end
comps[#comps + 1] = mesh   -- CharacterMesh0 is a mesh component too (never published)
for n, c in pairs(by) do pawn[n] = c end   -- component properties, as apply_look finds them

-- the game's own calls, as in BP_PlayerCharacter
local function set_visibility(root, on)                 -- Mesh:SetVisibility(on, true)
    root.bVisible = on
    for _, c in ipairs(comps) do c.bVisible = on end    -- every body part is attached under Mesh
end
local function fp_meshes(on)                            -- SetFPMeshesVisibility(on) @49 / @114-366
    for _, n in ipairs(HEAD) do
        if n ~= "HairMesh" or on then by[n].bHiddenInGame = on end
    end
end
local function perspective(fp, override)                -- ChangePlayerPerspective(fp, override)
    if override then pawn["PlayerInFirstPerson?"] = fp end
    cam.on = fp
    fp_meshes(fp)
end
local function scope(on)                                -- SetEnableScope(on) from third person
    if on then set_visibility(mesh, false); perspective(true, false)
    else set_visibility(mesh, true); if not pawn["PlayerInFirstPerson?"] then perspective(false, false) end end
end
local function binoculars(on)                           -- BinocularsVisibility(on)
    if on then perspective(true, false) elseif not pawn["PlayerInFirstPerson?"] then perspective(false, false) end
end

local function flags_in(s, name)
    return s:match("[;]" .. name .. "=[^,]*,[^,]*,([^;]*)")
end

print("== third person: the look as it is")
by.HairMesh.bHiddenInGame = true   -- hair under a helmet (third person)
local tp = appearance.look_string(pawn)
check(flags_in(tp, "Torso") == "" and flags_in(tp, "Head") == "", "body and head visible")
check(flags_in(tp, "HairMesh") == "h", "hair under the helmet: hidden (h)")
check(not tp:find("CharacterMesh0", 1, true), "CharacterMesh0 never published")

print("== scope (SetEnableScope(true) from third person)")
scope(true)
check(by.Torso.bVisible == false and by.Head.bHiddenInGame == true and cam.on, "setup: body bVisible off, head hidden, FP camera on")
local sc = appearance.look_string(pawn)
for _, n in ipairs(BODY) do check(flags_in(sc, n) == "", n .. ": no 'v' published while scoped") end
for _, n in ipairs(HEAD) do
    check(flags_in(sc, n) == flags_in(tp, n), n .. ": third-person flags (" .. tostring(flags_in(sc, n)) .. ")")
end
check(sc == tp, "scoped look == third-person look (nothing new to send)")
scope(false)
check(appearance.look_string(pawn) == tp, "scope off: same look")

print("== binoculars (first-person camera without PlayerInFirstPerson?)")
binoculars(true)
check(by.Head.bHiddenInGame == true and pawn["PlayerInFirstPerson?"] == false, "setup: head hidden, not 'in first person'")
local bn = appearance.look_string(pawn)
check(flags_in(bn, "Head") == "" and flags_in(bn, "Accessory1") == "" and flags_in(bn, "HairMesh") == "h",
    "head published as in third person")
binoculars(false)
check(appearance.look_string(pawn) == tp, "binoculars off: same look")

print("== first person (PlayerInFirstPerson?) and a scope in it")
perspective(true, true)
check(appearance.look_string(pawn) == tp, "first person: head as in third person (unchanged behaviour)")
scope(true)
check(appearance.look_string(pawn) == tp, "scope in first person: same look")
scope(false)
check(by.Torso.bVisible == true, "scope off in first person: body visible again")
perspective(false, true)

print("== third-person changes still go out")
by.HairMesh.bHiddenInGame = false   -- helmet taken off
local nohelmet = appearance.look_string(pawn)
check(flags_in(nohelmet, "HairMesh") == "", "hair shown again: published")
perspective(true, true)
check(flags_in(appearance.look_string(pawn), "HairMesh") == "", "first person: hair from the last third-person state (shown)")
perspective(false, true)
by.HairMesh.bHiddenInGame = true    -- helmet back on
appearance.look_string(pawn)
perspective(true, true)
check(flags_in(appearance.look_string(pawn), "HairMesh") == "h", "first person: hair from the last third-person state (hidden)")
perspective(false, true)
by.Torso.bVisible = false           -- a component hidden by something else, body Mesh visible
check(flags_in(appearance.look_string(pawn), "Torso") == "v", "'v' without the scope: published as before")
by.Torso.bVisible = true

print("== first-person camera read from bIsActive when IsActive() cannot be called")
local is_active = cam.IsActive
cam.IsActive = nil
cam.bIsActive = true
fp_meshes(true)                     -- binoculars, the camera flag only
check(flags_in(appearance.look_string(pawn), "Head") == "", "head published as in third person")
cam.bIsActive = nil
fp_meshes(false)
check(appearance.look_string(pawn) == tp, "camera off: same look")
cam.IsActive = is_active

-- ---------------------------------------------------------------------------
-- The whole way: client A scopes -> MYLOOK -> the host applies it to its copy
-- of A and relays it to client B; the host scopes -> its LOOK to the clients.
-- A second, independent copy of the module plays the host.
-- ---------------------------------------------------------------------------
print("== host: copy of a scoping client stays visible, relay to the third player clean")
local ue = package.loaded["sdc_ue"]
local net = package.loaded["sdc_net"]
local handlers, sent = {}, {}
net.on = function(kind, fn) handlers[kind] = fn end
net.broadcast = function(pcs, kind, id, s) sent[#sent + 1] = { to = pcs, kind = kind, id = id, s = s } end
ue.pawn_of = function(pc) return pc.pawn end
ue.set_prop = function(o, n, v) o[n] = v; return true end
ue.local_pc = function() return nil end

local function remote_copy(name, id)   -- the host's copy of a client's character
    local cs, b = {}, {}
    for _, list in ipairs({ BODY, HEAD }) do
        for _, n in ipairs(list) do b[n] = new_comp(n); cs[#cs + 1] = b[n] end
    end
    local p = { __name = name, __cls = "BP_PlayerCharacter_C", Mesh = new_comp("CharacterMesh0"),
                PlayerState = { GetPlayerId = function() return id end } }
    for n, c in pairs(b) do p[n] = c end
    function p:K2_GetComponentsByClass() return cs end
    function p:IsLocallyControlled() return false end
    return p, b
end
local function all_shown(b, except)
    for n, c in pairs(b) do
        if n ~= except and (c.bVisible ~= true or c.bHiddenInGame ~= false) then return false, n end
    end
    return true
end

local host = assert(loadfile(SCRIPTS .. "/sdc_appearance.lua"))()
local pcA, pcB = { name = "pcA" }, { name = "pcB" }
local copyA, byA = remote_copy("BP_PlayerCharacter_C_A", 7)
pcA.pawn = copyA
host.init({ role = "host", remote_pcs = { pcA, pcB } })
host.register_handlers()
check(handlers.MYLOOK ~= nil, "setup: MYLOOK handler registered")

handlers.MYLOOK({ tp }, pcA)
check(byA.HairMesh.bHiddenInGame == true and all_shown(byA, "HairMesh"), "client A third person: copy shown, hair under the helmet hidden")
handlers.MYLOOK({ sc }, pcA)                     -- what A sends while scoped
local ok_sc, bad_sc = all_shown(byA, "HairMesh")
check(ok_sc, "client A scoped: the host still shows A's body and head" .. (bad_sc and (" (hidden: " .. bad_sc .. ")") or ""))
local relay = sent[#sent]
check(relay and relay.kind == "LOOK" and relay.id == 7 and #relay.to == 1 and relay.to[1] == pcB,
    "MYLOOK relayed to client B only")
local function any_v(s)                          -- a component published as invisible
    for entry in s:gmatch("[^;]+") do
        local f = entry:match("^[^=]+=[^,]*,[^,]*,(.*)$")
        if f and f:find("v", 1, true) then return true end
    end
    return false
end
check(relay and not any_v(relay.s), "relayed look carries no 'v' (B shows A's body too)")
handlers.MYLOOK({ bn }, pcA)                     -- what A sends with binoculars
check(all_shown(byA, "HairMesh"), "client A with binoculars: the host still shows A's head")

-- a part of the copy hidden by something else comes back with the next look
byA.Torso.bVisible, byA.Arms.bVisible = false, false
handlers.MYLOOK({ sc }, pcA)
check(all_shown(byA, "HairMesh"), "a hidden part of the copy is shown again by the next look")

print("== looks from an older SDCoop (raw own-camera flags): the host keeps the body")
-- what the old look_string sent outside PlayerInFirstPerson?: the flags as they were
local function raw_look()
    local parts = { "m=1" }
    for _, c in ipairs(comps) do
        if c ~= mesh then
            parts[#parts + 1] = string.format("%s=,,%s", c.__name,
                (c.bHiddenInGame and "h" or "") .. (c.bVisible == false and "v" or ""))
        end
    end
    table.sort(parts, function(a, b)
        if a:sub(1, 2) == "m=" then return b:sub(1, 2) ~= "m=" end
        if b:sub(1, 2) == "m=" then return false end
        return a < b
    end)
    return table.concat(parts, ";")
end
check(raw_look() == tp, "setup: in third person the old format gives the same look")
scope(true)
local old_sc = raw_look()
scope(false)
binoculars(true)
local old_bn = raw_look()
binoculars(false)
check(any_v(old_sc) and flags_in(old_sc, "Torso") == "v" and flags_in(old_sc, "Head") == "hv",
    "setup: the old scope look: 'v' on the body, 'hv' on the head")
check(not any_v(old_bn) and flags_in(old_bn, "Head") == "h", "setup: the old binoculars look: 'h' on the head")
handlers.MYLOOK({ old_sc }, pcA)
local ok_o, bad_o = all_shown(byA, "HairMesh")
check(ok_o, "old client A scoped: the host still shows A's body and head" .. (bad_o and (" (hidden: " .. bad_o .. ")") or ""))
check(byA.HairMesh.bHiddenInGame == true, "old client A scoped: hair under the helmet stays hidden")
check(sent[#sent].s == old_sc and sent[#sent].to[1] == pcB, "relayed as it came (client B applies it the same way)")
byA.Torso.bVisible = false                       -- a part hidden by something else meanwhile
handlers.MYLOOK({ old_sc }, pcA)                 -- the same look again (every 2 s)
check(all_shown(byA, "HairMesh") and byA.HairMesh.bHiddenInGame == true,
    "old client A scoped, applied again: still shown (a hidden body part shown again)")
handlers.MYLOOK({ old_bn }, pcA)
check(all_shown(byA, "HairMesh") and byA.HairMesh.bHiddenInGame == true,
    "old client A with binoculars: the host still shows A's head, hair under the helmet hidden")
handlers.MYLOOK({ tp }, pcA)
check(all_shown(byA, "HairMesh") and byA.HairMesh.bHiddenInGame == true, "old client A back in third person: unchanged")
local nohelm = tp:gsub("(;HairMesh=[^,]*,[^,]*,)h", "%1")
handlers.MYLOOK({ nohelm }, pcA)
check(byA.HairMesh.bHiddenInGame == false, "a normal look still changes the head flags (helmet off: hair shown)")
local vpath = tp:gsub(";Torso=,,", ";Torso=Characters/Vest_v,M_vv,")
check(vpath ~= tp, "setup: a look with 'v' in an asset path")
handlers.MYLOOK({ vpath }, pcA)
check(byA.HairMesh.bHiddenInGame == true and all_shown(byA, "HairMesh"),
    "a 'v' in an asset path is not a flag (helmet on: hair hidden again)")

print("== host scopes: its own camera still hides the body, the clients keep seeing it")
ue.local_pawn = function() return pawn end
ue.player_chars = function() return { pawn, copyA } end
pawn.PlayerState = { GetPlayerId = function() return 1 end }
function pawn:IsLocallyControlled() return true end
sent = {}
host.tick({ pcA, pcB })
local first = sent[1]
check(first and first.kind == "LOOK" and first.id == 1 and first.s == tp, "host third person: its look broadcast")
scope(true)
host.tick({ pcA, pcB })
check(#sent == 1, "host scoped: nothing new broadcast (the clients keep the third-person look)")
check(by.Torso.bVisible == false and by.Clothing_Torso.bVisible == false and by.Head.bHiddenInGame == true,
    "host's own character: body and head stay hidden for its own scope camera")
check(all_shown(byA, "HairMesh"), "host's copy of client A untouched by the host's scope")
scope(false)
host.tick({ pcA, pcB })
check(#sent == 1 and by.Torso.bVisible == true, "host scope off: body back, still nothing new to send")

print(fails == 0 and ("ALL OK (" .. passed .. " checks)") or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
