-- Mock harness for sdc_dict (the per-session dictionary of the mod channel) and its
-- use in sdc_appearance (LOOK / MYLOOK). The real sdc_dict, sdc_netsync and
-- sdc_appearance; sdc_net / sdc_ue / sdc_log / sdc_ctx are stubs (the real
-- sdc_net.encode / decode are used to count bytes). NPCSET / NPCHP / AIAPP are
-- tested in mock_npc / mock_npc_wave / mock_fix_f_npc / mock_ai2 /
-- mock_zombie_sync (their wire form and what it decodes to).
-- usage: lua mock_dict.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what) end
end

local T = 1000
os.clock = function() return T end

package.loaded["sdc_log"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["sdc_ue"] = {
    valid = function(o) return type(o) == "table" end,
    name = function(o) return o.name end,
    prop = function(o, n) if type(o) ~= "table" then return nil end return o[n] end,
    short = function(o) return type(o) == "table" and (o.__name or o.name) or "<none>" end,
    path = function(o) return type(o) == "table" and (o.__path or "") or "" end,
    class_name = function(o) return type(o) == "table" and (o.__cls or "") or "" end,
    find_object = function() return { __name = "MeshComponent" } end,
    try = function(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end return nil end,
    pawn_of = function() return nil end,
    set_prop = function() return true end,
    local_pawn = function() return nil end,
    local_pc = function() return nil end,
    player_chars = function() return {} end,
}
-- the real encode / decode, a stub transport
local real_net = dofile(SCRIPTS .. "/sdc_net.lua")
local handlers, sent = {}, {}
local net = {
    encode = real_net.encode, decode = real_net.decode,
    on = function(kind, fn) handlers[kind] = fn end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, f = { ... }, msg = real_net.encode(kind, ...) }; return true end,
    send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, f = { ... }, msg = real_net.encode(kind, ...) }; return true end,
}
package.loaded["sdc_net"] = net
net.send_to_cb = function(pc, cb, kind, ...) local r = net.send_to(pc, kind, ...); if r and cb then cb() end return r end
net.send_to_host_cb = function(cb, kind, ...) local r = net.send_to_host(kind, ...); if r and cb then cb() end return r end
package.loaded["sdc_ctx"] = { addr = function(o) return o end }

local dict = require("sdc_dict")
local netsync = require("sdc_netsync")
local appearance = require("sdc_appearance")
local ST = { role = "host", remote_pcs = {} }
appearance.init(ST)
appearance.register_handlers()   -- also installs the dictionary's DICT / DICTQ handlers
check(handlers.DICTQ ~= nil and handlers.DICT ~= nil and handlers.LOOK ~= nil and handlers.MYLOOK ~= nil,
    "setup: DICTQ / DICT / LOOK / MYLOOK handlers registered")

local LONG1 = "AI/Humans/Meshes/Variants/SK_Human_Male_Casual_Infected_01.SK_Human_Male_Casual_Infected_01"
local LONG2 = "AI/Humans/Materials/Instances/MI_Human_Skin_Dirty_Variation_02.MI_Human_Skin_Dirty_Variation_02"

-- ---------------------------------------------------------------------------
print("== 1. the sender: a definition once per peer, then only ids")
do
    local e = dict.encoder("peerA", "q")
    local t1, t2, tshort = e:ref(LONG1), e:ref(LONG2), e:ref("Head")
    check(t1:match("^~%w+$") and t2:match("^~%w+$") and t1 ~= t2, "a long string becomes a token " .. t1 .. " / " .. t2)
    check(tshort == "Head" and e:ref("") == "" and e:ref(nil) == "", "a short string / nil stays as it is")
    check(e:ref("has;semicolon in a long string") == "has;semicolon in a long string" and e:ref("a|b long string") == "a|b long string",
        "a string with ; or | (cannot be a definition) stays as it is")
    check(e:ref(LONG1) == t1, "the same string, the same token in one session")
    local defs = e:defs()
    check(defs == t1:sub(2) .. "=" .. LONG1 .. ";" .. t2:sub(2) .. "=" .. LONG2, "the first message carries both definitions once: " .. defs)
    -- without a commit (the send failed) the next message defines them again
    local e2 = dict.encoder("peerA", "q")
    e2:ref(LONG1)
    check(e2:defs() ~= "", "not committed (the send failed): defined again")
    e:commit()
    local e3 = dict.encoder("peerA", "q")
    check(e3:ref(LONG1) == t1 and e3:ref(LONG2) == t2 and e3:defs() == "", "committed: the peer knows them, only tokens go")
    local e4 = dict.encoder("peerB", "q")
    e4:ref(LONG1)
    check(e4:defs() ~= "", "another peer (a joiner) gets the definitions too")
    netsync.drop("peerA")
    local e5 = dict.encoder("peerA", "q")
    e5:ref(LONG1)
    check(e5:defs() ~= "", "the peer said HI again (netsync.drop): the definitions go again")
    e5:commit()
    netsync.reset()
    local e6 = dict.encoder("peerA", "q")
    e6:ref(LONG2)
    check(e6:defs() ~= "", "a world reset (netsync.reset): the definitions go again")
end

print("== 2. queueable and NOW messages: what a queued message defines does not count for a NOW one")
do
    local q = dict.encoder("peerC", "q")
    q:ref(LONG1)
    q:commit()
    local n = dict.encoder("peerC", "n")
    n:ref(LONG1)
    check(n:defs() ~= "", "defined by a queueable message: a NOW message (could pass it in the queue) defines it again")
    n:commit()
    local q2 = dict.encoder("peerC", "q")
    q2:ref(LONG1)
    check(q2:defs() == "", "defined by a NOW message: known for the queueable ones too")
end

print("== 3. the receiver, an unknown id: DICTQ, DICT, the message heals")
do
    ST.role = "host"                                   -- the machine that sends the look
    local snd = dict.encoder("peerD", "q")
    local tok = snd:ref(LONG1)
    local lost_defs = snd:defs()                        -- the message that carried it is lost
    snd:commit()
    ST.role = "client"                                 -- the receiving machine
    local d = dict.decoder("host", nil, "n")
    check(d:get(tok) == nil and d:incomplete(), "an id nobody defined here: unknown (missing)")
    sent = {}
    local healed_call = false
    local ran = false
    check(d:ask() == true and #sent == 1 and sent[1].kind == "DICTQ" and sent[1].to == "host" and sent[1].f[1] == "n" and sent[1].f[2] == tok:sub(2),
        "DICTQ goes to the host with the id")
    d:retry(function() ran = true end)
    check(d:ask() == false, "the same id is not asked again within 3 s")
    -- the sender answers
    ST.role = "host"
    dict.on_heal(function(peer) healed_call = peer end)
    local pcD = { name = "peerD" }
    sent = {}
    handlers.DICTQ(sent[1] and sent[1].f or { "n", tok:sub(2) }, pcD)
    check(#sent == 1 and sent[1].kind == "DICT" and sent[1].to == pcD and sent[1].f[1] == tok:sub(2) .. "=" .. LONG1,
        "the sender answers DICT with the definition")
    check(healed_call == "peerD", "the modules that registered with on_heal hear which peer could not read (NPCSET / AIAPP resend)")
    -- the receiver gets it
    ST.role = "client"
    check(not ran, "(not yet retried)")
    handlers.DICT(sent[1].f, "hostpc")
    check(ran, "the DICT arrives: the held message is handled again")
    local d2 = dict.decoder("host")
    check(d2:get(tok) == LONG1 and not d2:incomplete(), "the id now decodes to the original string")
    -- an id nobody has
    ST.role = "host"
    sent = {}
    handlers.DICTQ({ "q", "zzzz" }, pcD)
    check(#sent == 0, "a DICTQ for an id the sender never made: no answer")
    -- expiry
    ST.role = "client"
    local d3 = dict.decoder("host")
    d3:get("~nope1")
    local ran3 = false
    d3:retry(function() ran3 = true end)
    T = T + 100
    handlers.DICT({ "nope1=" .. LONG2 }, "hostpc")
    check(not ran3, "a message waiting for its definitions longer than 30 s is dropped, not run late")
end

-- ---------------------------------------------------------------------------
print("== 3b. channels of a DICTQ, forgetting, reset_peer, prune")
do
    ST.role = "host"
    local healed = {}
    dict.on_heal(function(peer) healed[#healed + 1] = peer end)
    local pcG = { name = "peerG" }
    local e = dict.encoder("peerG", "n")
    local tok = e:ref(LONG1)
    e:commit()
    local id = tok:sub(2)
    check(dict.encoder("peerG", "n"):ref(LONG1) == tok, "(the id is known to peerG on both channels now)")
    local n0 = #healed
    handlers.DICTQ({ "q", id }, pcG)
    check(#healed == n0, "a DICTQ from a LOOK (q) runs no heal callback: no NPC / zombie look is sent again")
    local en = dict.encoder("peerG", "n"); en:ref(LONG1)
    check(en:defs() == "", "... and the NOW-known mark stays")
    handlers.DICTQ({ "n", id }, pcG)
    check(#healed == n0 + 1 and healed[#healed] == "peerG", "a DICTQ from a NOW message (n) runs the heal callbacks for that peer only")
    local en2 = dict.encoder("peerG", "n"); en2:ref(LONG1)
    check(en2:defs() == id .. "=" .. LONG1, "... and forgets what it thought known: the resent message carries its own definition")
    local eq = dict.encoder("peerG", "q"); eq:ref(LONG1)
    check(eq:defs() == "", "(the queueable channel got the DICT answer: still known)")

    -- reset_peer: a new session of the sender: its old ids are gone
    ST.role = "client"
    local d = dict.decoder("host")
    d:receive("old1=" .. LONG1)
    check(dict.decoder("host"):get("~old1") == LONG1, "a definition received from the host")
    dict.reset_peer("host")
    local d2 = dict.decoder("host")
    check(d2:get("~old1") == nil and d2:incomplete(), "reset_peer: after the host's new session an old id no longer resolves to its old string")
    local d3 = dict.decoder("hostX")
    d3:receive("a1=" .. LONG1)
    d3:get("~zz"); d3:retry(function() end)
    local d5 = dict.decoder("host"); d5:get("~w1")
    local ran5 = false
    d5:retry(function() ran5 = true end)
    dict.reset_peer("host")
    ST.role = "client"
    handlers.DICT({ "w1=" .. LONG2 }, "hostpc")   -- the definition arrives after the new session began
    check(not ran5, "reset_peer: a message of the old session still waiting is dropped, not replayed")
    dict.prune({ hostY = true })
    check(dict.decoder("hostX"):get("~a1") == nil, "prune: what a peer that left had sent is forgotten")
    local d4 = dict.decoder("hostY"); d4:receive("a1=" .. LONG1)
    dict.prune({ hostY = true })
    check(dict.decoder("hostY"):get("~a1") == LONG1, "prune: a live peer keeps its table")
end

print("== 3c. ids stay monotonic when the id tables start again (6000 strings)")
do
    local e = dict.encoder("peerH", "q")
    local seen, dup = {}, false
    for i = 1, 6100 do
        local t = e:ref("string number " .. i .. " for the id test")
        if seen[t] then dup = true end
        seen[t] = true
    end
    check(not dup, "6100 strings, no id used twice (also across the restart of the tables)")
    -- a restart between ref and defs() must not break the message
    local e2 = dict.encoder("peerI", "q")
    for i = 1, 30 do e2:ref("message string " .. i .. " of the restart test") end
    local fill = dict.encoder("peerJ", "q")
    for i = 1, 6001 do fill:ref("filler string " .. i .. " of the restart test") end   -- the tables start again here
    local ok, defs = pcall(function() return e2:defs() end)
    check(ok and select(2, defs:gsub(";", ";")) == 29, "a restart of the tables between ref() and defs(): all 30 definitions still there")
end

-- a look as long as the game's (22 components, ~2.3 KB like the logged ones): `who` picks the
-- character (colours differ a little), `alt` swaps the clothes / hair (two components)
local function make_look(who, alt)
    local parts = { "m=1" }
    local comps = { "Arms", "Biceps", "Clothing_Armor", "Clothing_Feet", "Clothing_Gloves", "Clothing_Legs", "Clothing_Torso",
        "Feet", "Hands", "Legs", "Torso", "Head", "Mouth", "EyebrowsMesh", "HairMesh", "BeardMesh", "Accessory1", "Accessory2",
        "Accessory3", "Ears", "Neck", "Eyes" }
    for i, c in ipairs(comps) do
        local v = (c == "Clothing_Torso" or c == "HairMesh") and (alt or 0) or 0
        local mesh = string.format("PlayerModel/%s/Chr_%s_%02d.Chr_%s_%02d", c, c, (i + v) % 7, c, (i + v) % 7)
        local mat = string.format("PlayerModel/%s/MI_%s_%02d.MI_%s_%02d", c, c, (i * 3 + who) % 5, c, (i * 3 + who) % 5)
        parts[#parts + 1] = c .. "=" .. mesh .. "," .. mat .. "," .. ((i % 5 == 0) and "h" or "")
    end
    return table.concat(parts, ";")
end

print("== 4. a look on the wire decodes to exactly the old string")
do
    local looks = { make_look(0), make_look(3, 2), "m=0", "m=1;Head=,,;Torso=a/b.c,d/e.f,hv", "",
        "Clothing_Torso=PlayerModel/Clothing_Torso/Meshes/Chr_X.Chr_X,PlayerModel/Clothing_Torso/Materials/MI_X.MI_X,;;m=1" }
    for i, s in ipairs(looks) do
        local e = dict.encoder("peerE" .. i, "q")
        local packed = appearance.pack_look(e, s)
        local d = dict.decoder("rcv-" .. i)
        d:receive(e:defs())
        local back = appearance.unpack_look(d, packed)
        check(back == s, string.format("look %d (%d chars -> %d on the wire, %d with the definitions) decodes to the same string",
            i, #s, #packed, #packed + #e:defs()))
    end
    -- an unknown token: nil, not a half look
    local e = dict.encoder("peerF", "q")
    local packed = appearance.pack_look(e, make_look(0))
    local d = dict.decoder("rcv-none")
    check(appearance.unpack_look(d, packed) == nil and d:incomplete(), "a look with unknown tokens does not decode (nil)")
end

print("== 5. LOOK / MYLOOK handlers: tokens, definitions, self-heal")
do
    ST.role = "client"
    local s1 = make_look(1)
    -- host side encoder, the way sdc_appearance's send_look builds it
    local e = dict.encoder("viewerX", "q")
    local packed = appearance.pack_look(e, s1)
    handlers.LOOK({ "7", "", packed }, nil)
    check(appearance.known_look(7) == nil, "LOOK with ids this client has no definition for: not taken")
    check(#sent > 0 and sent[#sent].kind == "DICTQ" and sent[#sent].to == "host", "... DICTQ asked the host")
    -- the definitions arrive (as the DICT reply)
    local defs = e:defs()
    handlers.DICT({ defs }, "hostpc")
    check(appearance.known_look(7) == s1, "after the DICT the same LOOK is handled: the look is exactly the old string")
    -- a LOOK with the definitions inline
    local e3 = dict.encoder("viewerZ", "q")
    local s3 = make_look(4)
    local p3 = appearance.pack_look(e3, s3)
    handlers.LOOK({ "9", e3:defs(), p3 }, nil)
    check(appearance.known_look(9) == s3, "LOOK with the definitions inline: decoded at once")
end

print("== 5b. an old LOOK waiting for its definitions never replaces a newer one")
do
    ST.role = "client"
    local sOld, sNew = make_look(5), make_look(5, 3)
    local eOld = dict.encoder("viewerOld", "q")
    local pOld = appearance.pack_look(eOld, sOld)
    local eNew = dict.encoder("viewerNew", "q")
    local pNew = appearance.pack_look(eNew, sNew)
    -- the old one's definitions are missing; the new one arrives complete; then the old definitions come
    handlers.LOOK({ "21", "", pOld }, nil)
    check(appearance.known_look(21) == nil, "(the old look waits for its definitions)")
    handlers.LOOK({ "21", eNew:defs(), pNew }, nil)
    check(appearance.known_look(21) == sNew, "the newer look is taken")
    handlers.DICT({ eOld:defs() }, "hostpc")
    check(appearance.known_look(21) == sNew, "the old look's definitions arrive: the old look is NOT replayed over the newer one")
    -- the same through MYLOOK on the host
    ST.role = "host"
    local pcM = { name = "pcM", pawn = { PlayerState = { GetPlayerId = function() return 31 end } } }
    package.loaded["sdc_ue"].pawn_of = function(pc) return pc.pawn end
    local cOld = dict.encoder("pcM-c", "q")
    local qOld = appearance.pack_look(cOld, sOld)
    local cNew = dict.encoder("pcM-c2", "q")
    local qNew = appearance.pack_look(cNew, sNew)
    handlers.MYLOOK({ "", qOld }, pcM)
    handlers.MYLOOK({ cNew:defs(), qNew }, pcM)
    check(appearance.known_look(31) == sNew, "MYLOOK: the newer look is taken")
    handlers.DICT({ cOld:defs() }, pcM)
    check(appearance.known_look(31) == sNew, "MYLOOK: the old look is not replayed over the newer one")
    package.loaded["sdc_ue"].pawn_of = function() return nil end
    ST.role = "client"
end

-- ---------------------------------------------------------------------------
print("== 5c. definitions count as known only when the message really left the queue (on_out)")
do
    ST.role = "host"
    package.loaded["sdc_ue"].pawn_of = function(pc) return pc.pawn end
    local pcM = { name = "pcM2", pawn = { PlayerState = { GetPlayerId = function() return 41 end } } }
    local pcO = { name = "pcO2" }
    ST.remote_pcs = { pcM, pcO }
    local out, cbs = {}, {}
    local real_cb = net.send_to_cb
    net.send_to_cb = function(pc, cb, kind, ...) out[#out + 1] = { pc = pc, f = { ... } }; cbs[#cbs + 1] = cb; return true end
    local c = dict.encoder("pcM2-c", "q")
    local look1, look2 = make_look(7), make_look(7, 2)
    handlers.MYLOOK({ "", appearance.pack_look(c, look1) }, pcM)   -- (inline defs missing here: the host just relays what it can decode)
    local c2 = dict.encoder("pcM2-d", "q")
    local p1 = appearance.pack_look(c2, look1)
    handlers.MYLOOK({ c2:defs(), p1 }, pcM)
    check(#out >= 1 and out[#out].f[2] ~= "", "the relayed LOOK carries definitions")
    local first = #out
    -- the first LOOK never left the queue (superseded): the next relayed one (same strings, other
    -- flags: a scope) carries the definitions itself
    local before = #out
    local c4 = dict.encoder("pcM2-f", "q")
    local look1b = look1:gsub(",h", ",v")
    local p2 = appearance.pack_look(c4, look1b)
    handlers.MYLOOK({ c4:defs(), p2 }, pcM)
    check(#out == before + 1 and out[#out].f[2] ~= "", "nothing left the queue yet: the next LOOK defines its strings again")
    for _, cb in ipairs(cbs) do cb() end   -- now they all went out
    local before2 = #out
    local c5 = dict.encoder("pcM2-g", "q")
    handlers.MYLOOK({ c5:defs(), appearance.pack_look(c5, look1) }, pcM)   -- back to look 1: strings all known now
    check(#out > before2 and out[#out].f[2] == "", "after on_out the peer is known to have them: only tokens go")
    net.send_to_cb = real_cb
    package.loaded["sdc_ue"].pawn_of = function() return nil end
    ST.role = "client"
end

print("== 6. bytes (the real encoder / decoder; model of the sending rules)")
local function bytes(kind, ...) return #real_net.encode(kind, ...) end
do
    -- 2 players (host + 1 client), 10 minutes: the join (HI -> every look to the client, MYLOOK of the
    -- client), each look told again as the verify after 300 s, one change of clothes each at minute 7
    local host_look, cl_look = make_look(0), make_look(2)
    local host_look2, cl_look2 = make_look(0, 1), make_look(2, 3)
    -- before: every message the whole string
    local old = bytes("LOOK", 1, host_look) + bytes("MYLOOK", cl_look)                       -- join
    old = old + bytes("LOOK", 1, host_look) + bytes("MYLOOK", cl_look)                       -- verify, 300 s
    old = old + bytes("LOOK", 1, host_look2) + bytes("MYLOOK", cl_look2)                     -- clothes
    -- after: the real encoder, one table of known ids per peer
    netsync.reset()
    local new = 0
    local function host_to_client(s)
        local e = dict.encoder("client1", "q")
        local p = appearance.pack_look(e, s)
        new = new + bytes("LOOK", 1, e:defs(), p)
        e:commit()
    end
    local function client_to_host(s)
        local e = dict.encoder("host", "q")
        local p = appearance.pack_look(e, s)
        new = new + bytes("MYLOOK", e:defs(), p)
        e:commit()
    end
    host_to_client(host_look); client_to_host(cl_look)
    local join_new = new
    host_to_client(host_look); client_to_host(cl_look)
    local verify_new = new - join_new
    host_to_client(host_look2); client_to_host(cl_look2)
    local change_new = new - join_new - verify_new
    check(new < old, "2 players: looks in 10 minutes: " .. new .. " bytes (before " .. old .. ")")
    io.write(string.format("NETQ LOOK 2 players, 10 min: before %d bytes (%.0f/min), after %d bytes (%.0f/min); join %d, a verify %d, a change of clothes %d\n",
        old, old / 10, new, new / 10, join_new, verify_new, change_new))
    check(verify_new < 400, "a verify of two unchanged looks: " .. verify_new .. " bytes")
end
do
    -- an NPC under fire for one minute (its health changes every second while it is hit): the host's rules
    -- before: the whole NPCSET (health in it) every RESEND_S = 30 s while it differs; after: the look once, NPCHP per second
    local look = {}
    for i, p in ipairs({ "Mesh", "HairMesh", "BeardMesh", "BackpackMesh", "BodyArmorMesh", "HelmetMesh" }) do
        look[#look + 1] = string.format("%s=AI/Humans/Meshes/Variants/%s_Bandit_Variant_%02d.%s_Bandit_Variant_%02d,AI/Humans/Materials/Instances/MI_Bandit_%s_%02d.MI_Bandit_%s_%02d,1.0,-12.5,30.0,0.0,90.0,0.0,1.000,1.000,1.000",
            p, p, i, p, i, p, i, p, i)
    end
    look = table.concat(look, ";")
    local cls = "BP_Bandit_Ranged_Boss_C"
    local old = 2 * bytes("NPCSET", cls, "237", "150", look)
    netsync.reset()
    local e = dict.encoder("viewer", "n")
    local entries = {}
    for entry in (look .. ";"):gmatch("(.-);") do entries[#entries + 1] = e:ref(entry) end
    local first = bytes("NPCSET", e:defs(), e:ref(cls), "237", table.concat(entries, ";"))
    e:commit()
    local hp = 0
    for s = 1, 60 do hp = hp + bytes("NPCHP", tostring(237 - s * 3)) end
    local steady = first + hp
    io.write(string.format("NETQ NPC under fire (1 NPC, 1 client, 60 s, hit every second): before %d bytes (2 x NPCSET), after %d bytes (first NPCSET %d, %d NPCHP; later minutes %d)\n",
        old, steady, first, 60, hp))
    -- the same NPC standing still for a minute
    local e2 = dict.encoder("viewer", "n")
    for entry in (look .. ";"):gmatch("(.-);") do e2:ref(entry) end
    check(e2:defs() == "", "an NPC already told to that viewer: its look costs no definitions")
    check(hp < old, "NPC under fire: the health bytes per minute (" .. hp .. ") are below one minute of the old full NPCSETs (" .. old .. ")")
end

print(fails == 0 and ("ALL OK (" .. passed .. " checks)") or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
