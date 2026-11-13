-- Mock test (13.11 log review, finding 17): a client's co-op character at the
-- join. In that session the client sent CHAR from the main menu world's
-- controller (lost: it never reaches the host), the host gave up after 8 s
-- while the client was still loading (~15 s), spawned the default character
-- and changed its look when the second CHAR came; then the client's MYLOOK,
-- sent before its own look was on, put the default beard / brows back on the
-- host for ~2 s.
--   C  client (sdc_charcreate): CHAR only from a controller of the host's
--      world (Role AutonomousProxy), again every 4 s until CHARACK, at most 5
--   H  host (join_gate): waits 25 s from the connection, or 8 s after the
--      player's HI; a CHAR before the character exists is acknowledged (got)
--   L  sdc_appearance: MYLOOK not sent while the co-op look is not on the own
--      character yet (at most 10 s), sent right after it is
-- usage: lua mock_sf_misc_charjoin.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path
local HERE = (arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."

local T = 100000
os.time = function() return math.floor(T) end
os.clock = function() return T end
local function advance(s) T = T + s end

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local function say(s) io.write(s, "\n") end

-- every other sdc_ module: an automatic stub (any field is a function returning nil)
local function stub()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return nil end
        rawset(t, k, f)
        return f
    end })
end
local REAL = { sdc_charcreate = true, sdc_appearance = true }
table.insert(package.searchers, 2, function(name)
    if REAL[name] or not name:match("^sdc_") then return nil end
    return function() return stub() end
end)

local LOG = {}
local function logline(kind) return function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    LOG[#LOG + 1] = kind .. (ok and s or tostring(fmt))
end end
local nop = function() end
package.loaded["sdc_log"] = setmetatable({
    info = logline(""), warn = logline("[WARN] "), err = logline("[ERROR] "), debug = logline("[DBG] "),
    err_throttled = function(_, fmt, ...) logline("[ERROR] ")(fmt, ...) end,
    ascii = function(s) return s end, toast = nop,
}, { __index = function() return nop end })
local function logged(pat, from)
    for i = from or 1, #LOG do if LOG[i]:find(pat, 1, true) then return LOG[i] end end
    return nil
end
local CFG = {}
package.loaded["sdc_config"] = { get = function(k) return CFG[k] end, set = nop, save = nop }

-- net: what each side sends
local SENT, HANDLERS = {}, {}
package.loaded["sdc_net"] = {
    send_to_host = function(kind, ...) SENT[#SENT + 1] = { to = "host", kind = kind, f = { ... } }; return true end,
    send_to = function(pc, kind, ...) SENT[#SENT + 1] = { to = pc, kind = kind, f = { ... } }; return true end,
    broadcast = function(_, kind, ...) SENT[#SENT + 1] = { to = "all", kind = kind, f = { ... } } end,
    on = function(kind, fn) HANDLERS[kind] = fn end,
}
local function sent(kind, to)
    local out = {}
    for _, m in ipairs(SENT) do
        if m.kind == kind and (to == nil or m.to == to) then out[#out + 1] = m end
    end
    return out
end
package.loaded["sdc_ctx"] = { addr = function(o) return type(o) == "table" and o.addr or nil end }

FName = function(s) return { ToString = function() return s end } end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end

-- fake objects: o.props = UE properties
local next_addr = 100
local function obj(cls, key, props, methods)
    local o = methods or {}
    next_addr = next_addr + 16
    o.cls, o.key, o.props, o.addr = cls, key, props or {}, next_addr
    return o
end
local LOCAL_PC, LOCAL_PAWN = nil, nil
local ue = stub()
ue.ROLE_SIMULATED, ue.ROLE_AUTONOMOUS, ue.ROLE_AUTHORITY = 1, 2, 3
ue.valid = function(o) return type(o) == "table" and not o.dead end
ue.name = function(o) return type(o) == "table" and (o.key or "obj") or "<none>" end
ue.short = ue.name
ue.class_name = function(o) return type(o) == "table" and (o.cls or "") or "" end
ue.path = function(o) return type(o) == "table" and (o.path or o.key) or "" end
ue.prop = function(o, k) if type(o) == "table" and o.props then return o.props[k] end end
ue.role = function(o) local r = ue.prop(o, "Role"); return type(r) == "number" and r or -1 end
ue.pawn_of = function(pc) local p = ue.prop(pc, "Pawn"); if ue.valid(p) then return p end end
ue.local_pc = function() return LOCAL_PC end
ue.local_pawn = function() return LOCAL_PAWN end
ue.try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
ue.find_all = function() return {} end
ue.player_chars = function() return {} end
ue.str = function(v) return v == nil and "" or tostring(v) end
package.loaded["sdc_ue"] = ue

local cc = require("sdc_charcreate")
local look = require("sdc_appearance")
local S = { role = "client", remote = {}, remote_pcs = {} }
local TMP = HERE .. "/_tmp/sf_misc_charjoin"
os.execute('mkdir "' .. TMP:gsub("/", "\\") .. '" 2>nul')
os.remove(TMP .. "/character.txt")
cc.init({ state = S, world_reset_hooks = {} }, TMP)
cc.register_handlers()
look.init(S)
look.register_handlers()
cc.stored = { sex = "Male", skin = "Materials/1/M_Chr_Texture_1A.M_Chr_Texture_1A",
    hair = "Hair/HairMesh/Chr_FemaleHair7.Chr_FemaleHair7", haircolor = "", brows = "Hair/Eyebrows/Chr_Eyebrows2.Chr_Eyebrows2",
    beard = "Hair/Beard/Chr_Beard4.Chr_Beard4", beardcolor = "", mouth = "", acc1 = "", acc2 = "", acc3 = "",
    first = "A", last = "B", age = "30", occ = "0" }

local function controller(name, role)
    return obj("BP_PlayerController_C", name, { PlayerState = obj("PlayerState", name .. "_PS"), Role = role })
end

-- ==================================================================== client
say("== C1. the main menu world's controller (Authority) is the local one: no CHAR from it")
local menu_pc = controller("BP_PlayerController_C_menu", 3)
LOCAL_PC = menu_pc
cc.tick(); advance(1); cc.tick()
check(#sent("CHAR") == 0, "no CHAR from the menu world's controller (13.11: that one was lost)")
check(logged("is not the host's yet (role 3)") ~= nil, "logged once: not the host's controller yet")

say("== C2. the host's controller (AutonomousProxy), no character yet: CHAR at once, again every 4 s until CHARACK")
local pc = controller("BP_PlayerController_C_2147473600", 2)
LOCAL_PC = pc
advance(1); cc.tick()
check(#sent("CHAR") == 1 and sent("CHAR")[1].f[1] == "1" and sent("CHAR")[1].f[2] == "Male", "CHAR sent from the host's world")
advance(1); cc.tick(); advance(1); cc.tick()
check(#sent("CHAR") == 1, "not again within 4 s")
advance(2); cc.tick()
check(#sent("CHAR") == 2 and logged("character sent again (try 2 of 5)") ~= nil, "no answer for 4 s: sent again (try 2)")
HANDLERS.CHARACK({ "got", "spawn" })
check(logged("the host has the character") ~= nil, "CHARACK got: logged")
for _ = 1, 20 do advance(1); cc.tick() end
check(#sent("CHAR") == 2, "acknowledged: not sent again")

say("== C2b. a controller whose Role cannot be read, with its own player character: in the host's world all the same")
local pcr = controller("BP_PlayerController_C_2147473650", nil)
pcr.props.Pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2147473651", {})
LOCAL_PC = pcr
local nr = #sent("CHAR")
advance(1); cc.tick()
check(#sent("CHAR") == nr + 1, "role unreadable, own character there: CHAR sent")
HANDLERS.CHARACK({ "spawn", "ok" })

say("== C3. no answer at all: 5 CHAR, then it stops")
local pc3 = controller("BP_PlayerController_C_2147473700", 2)
LOCAL_PC = pc3
local n0 = #sent("CHAR")
for _ = 1, 40 do advance(1); cc.tick() end
check(#sent("CHAR") == n0 + 5, "5 tries, no more (" .. (#sent("CHAR") - n0) .. ")")

-- ==================================================================== look
say("== L. MYLOOK only once the co-op look is on the own character")
local pawn = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2147473627", {
    PlayerState = obj("PlayerState", "PS_7", {}, { GetPlayerId = function() return 257 end }) })
pc3.props.Pawn = pawn
LOCAL_PAWN = pawn
local LOOK = "m=1;BeardMesh=,PlayerModel/Hair/Material/Brown/MI_CharacterHair_Brown.MI_CharacterHair_Brown,"
look.look_string = function() return LOOK end
look.dress = function() end
local l0 = #LOG + 1
advance(1); cc.tick()                 -- charcreate: a new character, one tick before its look goes on
look.tick({})
check(#sent("MYLOOK") == 0, "the co-op look not on yet: no MYLOOK (13.11: the default beard / brows went to the host)")
advance(1); cc.tick()                 -- the look put on (try 1; the mock's assets fail, it counts all the same)
check(logged("look applied to own BP_PlayerCharacter_C_2147473627", l0) ~= nil, "(charcreate tried the look)")
LOOK = "m=1;BeardMesh=PlayerModel/Hair/Beard/Chr_Beard4.Chr_Beard4,PlayerModel/Hair/Material/Brown/MI_CharacterHair_Brown.MI_CharacterHair_Brown,"
look.tick({})
local my = sent("MYLOOK")
check(#my == 1 and my[1].f[1] == LOOK, "the look on: MYLOOK sent with it")
-- a character whose look never gets its try: MYLOOK after 10 s at most
local pawn2 = obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2147473999", {
    PlayerState = obj("PlayerState", "PS_8", {}, { GetPlayerId = function() return 258 end }) })
LOCAL_PAWN = pawn2
LOOK = LOOK .. ";x"
look.tick({})
check(#sent("MYLOOK") == 1, "a new own character, no look try yet: held")
advance(9); look.tick({})
check(#sent("MYLOOK") == 1, "still held at 9 s")
advance(2); look.tick({})
check(#sent("MYLOOK") == 2, "10 s: published anyway")
-- no co-op character stored: nothing held
cc.stored = nil
LOOK = LOOK .. ";y"
look.tick({})
check(#sent("MYLOOK") == 3, "no stored character: published at once")

-- ==================================================================== host
say("== H1. host: a joining player's first character waits 25 s from the connection (13.11: 8 s, the client still loading)")
S.role = "host"
cc.tick()
local rpc = obj("BP_PlayerController_C", "BP_PlayerController_C_2147468778", { Pawn = nil })
local r = { key = "BP_PlayerController_C_2147468778", name = "Friend", pc = rpc, hello = false }
S.remote[r.key] = r
local t0 = os.time()
check(cc.join_gate(r, t0) == false, "at the connection: held")
check(cc.join_gate(r, t0 + 8) == false, "8 s: still held (the client is loading the map)")
check(cc.join_gate(r, t0 + 24) == false, "24 s: still held")
check(cc.join_gate(r, t0 + 25) == true and logged("no character message from Friend in 25 s since it connected") ~= nil,
    "25 s: the default character")

say("== H2. HI first, no CHAR: 8 s after the HI")
local r2 = { key = "BP_PlayerController_C_2", name = "Second", pc = obj("BP_PlayerController_C", "BP_PlayerController_C_2"), hello = false }
S.remote[r2.key] = r2
check(cc.join_gate(r2, t0) == false, "connected: held")
r2.hello = true
check(cc.join_gate(r2, t0 + 3) == false, "HI at 3 s: held")
check(cc.join_gate(r2, t0 + 10) == false, "7 s after the HI: held")
check(cc.join_gate(r2, t0 + 11) == true and logged("in 8 s after its HI") ~= nil, "8 s after the HI: the default character")

say("== H3. CHAR before the character exists: the gate opens, CHARACK got")
local r3 = { key = "BP_PlayerController_C_3", name = "Third", pc = obj("BP_PlayerController_C", "BP_PlayerController_C_3"), hello = false }
S.remote[r3.key] = r3
check(cc.join_gate(r3, t0) == false, "connected: held")
local f = sent("CHAR")[1].f
HANDLERS.CHAR(f, r3.pc)
check(cc.join_gate(r3, t0 + 1) == true, "CHAR received: the gate opens at once")
local acks = sent("CHARACK", r3.pc)
check(#acks == 1 and acks[1].f[1] == "got", "CHARACK got sent to that client (it stops sending CHAR)")
HANDLERS.CHAR(f, r3.pc)
check(#sent("CHARACK", r3.pc) == 2, "a CHAR sent again before the character: acknowledged again")

say(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
