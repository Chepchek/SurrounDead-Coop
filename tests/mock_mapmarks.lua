-- Mock harness for sdc_playermarks.lua: map markers players place
-- (BP_PlayerMarker_C) - owner on the host, sharing, removal, local copies on
-- a client (fake engine; logic only). The fake game follows
-- work\re\pseudo: Svr_SpawnPlayerMarker spawns the marker and runs
-- Event_AddMarker for GetPlayerCharacter(0) = this machine's own character;
-- "Remove Player Marker" = Marker.RemoveFromParent + K2_DestroyActor (a
-- replicated copy on a client cannot be destroyed); RespawnMarker = "Add
-- Saved Player Marker" with the actor's Marker Data.
-- usage: lua mock_mapmarks.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, checks = 0, 0
local function check(c, what)
    checks = checks + 1
    print((c and "  ok   " or "  FAIL ") .. what)
    if not c then fails = fails + 1 end
end

-- ------------------------------------------------------------- globals
FText = function(s) return { _text = s } end
FName = function(s) return { _fname = s } end
LoadAsset = function() end
local HOOKS = {}
RegisterHook = function(path, fn) HOOKS[path] = fn; return 1, 2 end

-- ------------------------------------------------------------- fake objects
local nobj = 0
local function obj(class, t)
    nobj = nobj + 1
    t = t or {}
    t._class, t._valid, t._addr = class, true, 0x10000 + nobj * 16
    t._name = t._name or (class .. "_" .. nobj)
    t.GetAddress = function(self) return self._addr end
    return t
end
local function param(v) return { get = function() return v end } end

local MDN = {
    title = "MarkerTitle_47_5E7A698C4B5AC497BBB438A55515B853",
    texture = "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD",
    tex_size = "TextureSize_30_0FC614D34939DCCA4077899925344EDF",
    text_size = "TextSize_33_ADA10B73491C7DD1835FD69801CC42F1",
    color = "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872",
    compass = "CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4",
}
local XTEX = obj("Texture2D", { _name = "XTexture" })
local function default_data()
    return { [MDN.title] = FText(""), [MDN.texture] = XTEX, [MDN.tex_size] = { X = 1, Y = 1 },
             [MDN.text_size] = { X = 0, Y = 0 }, [MDN.color] = { R = 1, G = 1, B = 1, A = 1 }, [MDN.compass] = false }
end
local function copy_data(d)
    local c = {}
    for k, v in pairs(d) do
        if type(v) == "table" and v._class == nil and v._text == nil then
            local t = {}
            for kk, vv in pairs(v) do t[kk] = vv end
            c[k] = t
        else
            c[k] = v
        end
    end
    return c
end

local W = {}     -- the current machine
local sent = {}

local P_MM = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:"
local HOOK_PATH = {
    create = P_MM .. "CreatePlayerMarker",
    svr = P_MM .. "Svr_SpawnPlayerMarker",
    dbl = "/Game/Blueprints/MinimapSystem/Blueprints/Widget/Markers/W_PlayerMarker.W_PlayerMarker_C:OnMouseButtonDoubleClick",
}
local function fire(name, ctx, ...)
    local fn = HOOKS[HOOK_PATH[name]]
    assert(fn, "hook " .. name .. " not registered")
    local args = { param(ctx) }
    for i = 1, select("#", ...) do args[#args + 1] = param((select(i, ...))) end
    fn(table.unpack(args))
end

local function new_map()
    local overlay = obj("Overlay")
    local refs = { list = {} }
    refs.ForEach = function(self, fn) for i, w in ipairs(self.list) do fn(i, param(w)) end end
    local mw = obj("MapWidget_C", { StandardMarkerOverlay = overlay, ["Player Marker References"] = refs,
        InnerCanvas = obj("CanvasPanel", { RenderTransform = { Scale = { X = 1, Y = 1 } } }) })
    mw.add = function(self, data, target)
        local c = data[MDN.color] or { R = 0, G = 0, B = 0 }
        local icon = obj("Image", { ColorAndOpacity = { R = c.R, G = c.G, B = c.B, A = 1 } })
        icon.SetColorAndOpacity = function(s, col) s.ColorAndOpacity = col end
        local w = obj("W_PlayerMarker_C", { ["Target Actor"] = target, ["Marker Data"] = copy_data(data), Icon = icon, parent = overlay })
        w.GetParent = function(s) return s.parent end
        w.RemoveFromParent = function(s) s.parent = nil end
        w.SetToolTipText = function(s, t) s.tip = t._text end
        refs.list[#refs.list + 1] = w
        return w
    end
    return mw
end

-- live widgets of a map (for one target actor, or all)
local function live_on(mw, a)
    local n, last = 0, nil
    for _, w in ipairs(mw["Player Marker References"].list) do
        if w.parent and (a == nil or w["Target Actor"] == a) then n, last = n + 1, w end
    end
    return n, last
end

local function spawn_marker(loc, role)
    local a = obj("BP_PlayerMarker_C", { loc = { X = loc.X, Y = loc.Y, Z = loc.Z }, Role = role or 3,
        -- class defaults: no texture, no title
        ["Marker Data"] = { [MDN.title] = FText(""), [MDN.color] = { R = 0, G = 0, B = 0, A = 0 }, [MDN.tex_size] = { X = 1, Y = 1 } } })
    a.Event_AddMarker = function(self)
        local mm0 = W.me and W.me.MinimapSystemComponent
        if not mm0 then return end   -- Accessed None
        self["Marker Data"] = copy_data(mm0.DefaultPlayerMarkerData)
        if mm0.MapWidget and mm0.MapWidget._valid then self.Marker = mm0.MapWidget:add(self["Marker Data"], self) end
        W.add_calls = (W.add_calls or 0) + 1
    end
    a.RespawnMarker = function(self)
        local mm0 = W.me and W.me.MinimapSystemComponent
        if mm0 and mm0.MapWidget and mm0.MapWidget._valid then self.Marker = mm0.MapWidget:add(self["Marker Data"], self) end
        W.respawn_calls = (W.respawn_calls or 0) + 1
    end
    a.K2_DestroyActor = function(self)
        if self.Role ~= 3 then return false end   -- a client cannot destroy a replicated actor
        self._valid = false
        return true
    end
    W.actors[#W.actors + 1] = a
    return a
end

-- the game's Svr_SpawnPlayerMarker body (ubergraph @393) where it runs
local function svr_body(mm, loc)
    local a = spawn_marker(loc, 3)
    a:Event_AddMarker()
    return a
end

local function new_mm(owner, with_map)
    local mm = obj("BPC_MinimapSystem_C", { DefaultPlayerMarkerData = default_data(), MapToggled = false })
    if with_map then mm.MapWidget = new_map() end
    mm.GetOwner = function() return owner end
    mm["Remove Player Marker"] = function(self, a)
        if a.Marker then a.Marker:RemoveFromParent() end
        if a._valid then a:K2_DestroyActor() end
        W.remove_calls = (W.remove_calls or 0) + 1
    end
    mm["Marker Location"] = function(self, ml, o1, o2)
        o1.ImpactPoint = { X = ml.X, Y = ml.Y, Z = W.ground or 50 }
        o2.Success = W.trace_ok ~= false
    end
    -- called from Lua on the host (authority: runs locally); UE4SS's script
    -- hook fires for it unless W.no_lua_hook
    mm.Svr_SpawnPlayerMarker = function(self, loc, ok)
        svr_body(self, loc)
        if not W.no_lua_hook then fire("svr", self, loc, ok) end
    end
    return mm
end

-- the game's RPC from the network: the body, then the Blueprint hook
local function game_rpc(mm, loc)
    local a = svr_body(mm, loc)
    fire("svr", mm, loc, true)
    return a
end

-- W_PlayerMarker.OnMouseButtonDoubleClick: Get Minimap Component(self) (=
-- player 0's) -> Remove Player Marker(Target Actor); then the hook
local function dblclick(w)
    local t = w["Target Actor"]
    if t and t._valid then
        local mm0 = W.me.MinimapSystemComponent
        mm0["Remove Player Marker"](mm0, t)
    end
    fire("dbl", w)
end

local function new_ps(id) local ps = obj("PlayerState"); ps.GetPlayerId = function() return id end; return ps end

local SLOT_G = "EquippedGPS_58_A18BCF9B44989D75939B038888DBFC9C"
local SLOT_C = "EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB"
local function new_pawn(id, opts)
    opts = opts or {}
    local p = obj("BP_PlayerCharacter_C", { PlayerState = new_ps(id), ["PlayerDead?"] = false, bHidden = false,
        Role = opts.role or 3, loc = opts.loc or { X = 0, Y = 0, Z = 100 }, Mesh = obj("SkeletalMeshComponent"), comps = {} })
    p.IsLocallyControlled = function() return opts.is_local == true end
    p["IsGPSEquipped?"] = function(self, out) out["GPS?"] = true end
    p.BP_JigHelperComp = obj("BP_JigHelperComp_C", { ServerEquippedItems = { [SLOT_G] = {}, [SLOT_C] = {} } })
    p.ShowCompassWidget = function() end
    p.GetComponentByClass = function(self) return self.comps[1] end
    p.MinimapSystemComponent = new_mm(p, opts.map ~= false)
    p.Controller = opts.pc
    return p
end

local function new_pc(id) return obj("PlayerController", { PlayerState = new_ps(id) }) end

local MARKER_PATH = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_PlayerMarker.BP_PlayerMarker_C"
local MARKER_CLS = obj("BlueprintGeneratedClass", { _path = MARKER_PATH })
local GS = obj("GameplayStatics")
GS.BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf, coll, owner, scale)
    assert(coll == 1 and scale == 0 and owner == nil, "the game's spawn parameters")
    if cls == MARKER_CLS then
        W.deferred = (W.deferred or 0) + 1
        return spawn_marker(tf.Translation, 3)
    end
    local a = obj("BP_CompassMarker_C", { loc = tf.Translation })
    a.K2_DestroyActor = function(self) self._valid = false end
    W.actors[#W.actors + 1] = a
    return a
end
GS.FinishSpawningActor = function(_, a) return a end

-- ------------------------------------------------------------- module mocks
package.preload["sdc_log"] = function()
    local L = { debug_enabled = false }
    local function out(lvl) return function(fmt, ...) print("    [" .. lvl .. "] " .. string.format(fmt, ...)) end end
    L.info, L.warn, L.err, L.debug = out("I"), out("W"), out("E"), function() end
    L.err_throttled = function(k, fmt, ...) print("    [E!] " .. string.format(fmt, ...)); fails = fails + 1 end
    return L
end
package.preload["sdc_config"] = function()
    local C = { v = { gps_markers = false, gps_compass = false, player_names = false } }
    C.get = function(k) return C.v[k] end
    C.player_name = function() return W.my_name end
    return C
end
package.preload["sdc_net"] = function()
    local N = { handlers = {} }
    N.on = function(k, h) N.handlers[k] = h end
    local function strs(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
        return t
    end
    N.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, f = strs(...) }; return true end
    N.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, f = strs(...) }; return true end
    return N
end
package.preload["sdc_ue"] = function()
    local U = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
    U.valid = function(o) return type(o) == "table" and o._valid == true end
    U.prop = function(o, k) if not U.valid(o) then return nil end return o[k] end
    U.set_prop = function(o, k, v) if not U.valid(o) then return false end o[k] = v; return true end
    U.name = function(o) return U.valid(o) and o._name or "<none>" end
    U.short = U.name
    U.class_name = function(o) return U.valid(o) and o._class or "" end
    U.str = function(v) if type(v) == "table" then return v._text or "" end return tostring(v or "") end
    U.try = function(f, ...) local ok, v = pcall(f, ...) if ok then return v end end
    U.find_all = function(c)
        local out = {}
        for _, a in ipairs(W.actors) do if a._class == c then out[#out + 1] = a end end
        for _, p in ipairs(W.pawns) do if p._class == c then out[#out + 1] = p end end
        return out
    end
    -- sdc_ue.player_chars: the shared list of valid player characters
    U.player_chars = function()
        local out = {}
        for _, p in ipairs(U.find_all("BP_PlayerCharacter_C")) do if U.valid(p) then out[#out + 1] = p end end
        return out
    end
    U.find_object = function(path)
        if path == MARKER_PATH then return MARKER_CLS end
        if path:find("WidgetComponent") then return obj("Class") end
        return obj("Asset")
    end
    U.load_asset = function() end
    U.gameplay_statics = function() return GS end
    U.widget_lib = function() return nil end
    U.local_pc = function() return W.pc end
    U.local_pawn = function() return W.me end
    U.pawn_of = function(pc) return pc and pc.pawn end
    U.location = function(a) if not U.valid(a) then return nil end return a.loc end
    U.teleport = function(a, l) a.loc = l; return true end
    U.role = function(p) return p.Role end
    U.path = function(o) return U.valid(o) and o._path or "" end
    U.ksl = function() return nil end
    U.exec = function() return false end
    return U
end

local pm = require("sdc_playermarks")
local net = require("sdc_net")
local cfg = require("sdc_config")

local function msgs(kind, to)
    local out = {}
    for _, m in ipairs(sent) do
        if m.kind == kind and (to == nil or m.to == to) then out[#out + 1] = m end
    end
    return out
end
-- the last complete MKSYNC list sent to `to`: { [key] = { id, name, ... } }, number of messages
local function last_list(to)
    local list, n, seq = nil, 0, nil
    for _, m in ipairs(sent) do
        if m.kind == "MKSYNC" and m.to == to then
            if m.f[1] ~= seq then seq, list, n = m.f[1], {}, 0 end
            n = n + 1
            for item in (m.f[4] or ""):gmatch("[^;]+") do
                local k, id, x, y, z, r, g, b, name = item:match("^(%-?%d+),(%-?%d+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),(.*)$")
                list[tonumber(k)] = { id = tonumber(id), X = tonumber(x), Y = tonumber(y), Z = tonumber(z),
                                      R = tonumber(r), G = tonumber(g), B = tonumber(b), name = name }
            end
        end
    end
    return list, n
end
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
-- marker actors this machine owns (a replicated copy on a client is not counted)
local function alive()
    local n = 0
    for _, a in ipairs(W.actors) do if a._class == "BP_PlayerMarker_C" and a._valid and a.Role == 3 then n = n + 1 end end
    return n
end
local function tick(dt) T = T + (dt or 1); pm.tick() end

local VIOLET = { R = 0.60, G = 0.45, B = 1.00 }   -- color_of(257)
local YELLOW = { R = 1.00, G = 0.90, B = 0.10 }   -- color_of(256)
local function same_col(c, want) return c and math.abs(c.R - want.R) < 0.01 and math.abs(c.G - want.G) < 0.01 and math.abs(c.B - want.B) < 0.01 end

-- ===================================================================== HOST
print("HOST")
local S = { role = "host", remote = {}, remote_pcs = {} }
local hpc = new_pc(256)
local cpc = new_pc(257)
cpc._name = "PC_client"
local host_me = new_pawn(256, { is_local = true, pc = hpc })
local cpawn = new_pawn(257, { pc = cpc, loc = { X = 5000, Y = 0, Z = 100 } })   -- its server-side map (hidden): not the host's
cpc.pawn, hpc.pawn = cpawn, host_me
W = { actors = {}, pawns = { host_me, cpawn }, me = host_me, pc = hpc, my_name = "Host" }
local hmm, hmw = host_me.MinimapSystemComponent, host_me.MinimapSystemComponent.MapWidget
local cmm = cpawn.MinimapSystemComponent
S.remote["PC_client"] = { key = "PC_client", pc = cpc, name = "Вася", hello = true }
S.remote_pcs = { cpc }
pm.init(S)
local MK = pm.MK

tick()
check(HOOKS[HOOK_PATH.create] and HOOKS[HOOK_PATH.svr] and HOOKS[HOOK_PATH.dbl], "the three Blueprint hooks registered")
local l0 = last_list(cpc)
check(l0 and count(l0) == 0, "an empty list goes to the client after its HI")

-- H1: the host's own marker
print("-- host places a marker")
sent = {}
local ha = game_rpc(hmm, { X = 100, Y = 200, Z = 10 })
local n, hw = live_on(hmw, ha)
check(n == 1 and same_col(hw.Icon.ColorAndOpacity, { R = 1, G = 1, B = 1 }) and hw.tip == nil, "host's marker on the host's map, game look (white, no tooltip)")
local l1 = last_list(cpc)
local hkey = nil
for k, e in pairs(l1 or {}) do if e.id == 256 then hkey = k end end
check(hkey and l1[hkey].name == "Host" and same_col(l1[hkey], YELLOW), "list to the client right away: the host's marker, host colour and name")

-- traffic with nothing changing, 6 minutes: NETQ line for the net-quiet report
do
    sent = {}
    for _ = 1, 360 do tick(1) end
    local ninfo = 0
    for _, m in ipairs(sent) do if m.kind == "PINFO" then ninfo = ninfo + 1 end end
    check(ninfo >= 8 and ninfo <= 16, "PINFO: the table again as the verify every 60 s, not every 10 s (" .. ninfo .. " in 6 minutes)")
    local n, bytes = 0, 0
    for _, m in ipairs(sent) do
        if m.kind == "MKSYNC" then n = n + 1; for _, v in ipairs(m.f) do bytes = bytes + #tostring(v) + 1 end end
    end
    check(n >= 1, "MKSYNC: an unchanged list is told again only as the verify (at least once in 6 minutes: " .. n .. ")")
    check(n <= 4, "MKSYNC: ... and not every 30 s any more")
    io.write(string.format("NETQ MKSYNC idle msgs/min=%.1f bytes/min=%.0f", n / 6, bytes / 6), string.char(10))
end

-- a client that leaves: its records are dropped; back again it gets the list at once
do
    check(MK.sent_sig["PC_client"] ~= nil and MK.sent_t["PC_client"] ~= nil, "MKSYNC: the host keeps what it told the client")
    local keep_remote, keep_pcs = S.remote["PC_client"], S.remote_pcs
    S.remote["PC_client"], S.remote_pcs = nil, {}
    tick()
    check(MK.sent_sig["PC_client"] == nil and MK.sent_t["PC_client"] == nil and MK.synced["PC_client"] == nil,
        "MKSYNC: a client that left: its records are forgotten")
    S.remote["PC_client"], S.remote_pcs = keep_remote, keep_pcs
    sent = {}
    tick()
    check(#msgs("MKSYNC", cpc) >= 1, "MKSYNC: back again: the list goes at once")
end

-- H2: a client's marker through the game's RPC (lands on the host's map in the game)
print("-- client marker via the game's RPC")
sent = {}
local ca = game_rpc(cmm, { X = 3000, Y = 4000, Z = 20 })
n, hw = live_on(hmw, ca)
check(n == 1 and same_col(hw.Icon.ColorAndOpacity, VIOLET) and hw.tip == "Вася", "shared: client's marker on the host's map in its colour, name as tooltip")
check(ca["Marker Data"][MDN.title]._text == "Вася" and same_col(ca["Marker Data"][MDN.color], VIOLET), "owner saved in the marker's Marker Data (title, colour)")
check(live_on(cmm.MapWidget) == 0, "nothing on the client's server-side map")
local l2 = last_list(cpc)
local ckey = nil
for k, e in pairs(l2 or {}) do if e.id == 257 then ckey = k end end
check(count(l2) == 2 and ckey and l2[ckey].name == "Вася", "client gets both markers (its own + the host's)")

-- H3: the client's MKREQ for the same click comes second
print("-- MKREQ after the RPC")
local before = alive()
net.handlers.MKREQ({ "3000.0", "4000.0", "20.0" }, cpc)
check(alive() == before and MK.stats.req_dup == 1, "MKREQ for the same spot: recognised, no second marker")

-- H4: sharing off
print("-- sharing off")
cfg.v.map_markers_shared = false
sent = {}
tick()
check(live_on(hmw, ca) == 0 and live_on(hmw, ha) == 1, "client's marker off the host's map, host's stays")
local l3 = last_list(cpc)
check(count(l3) == 1 and l3[ckey] and l3[ckey].id == 257, "client's list: only its own marker")

-- H5: MKREQ alone (no RPC came), the hook sees the Lua call
print("-- MKREQ only")
sent = {}
net.handlers.MKREQ({ "6000.0", "100.0", "30.0" }, cpc)
local ra = nil
for _, a in ipairs(W.actors) do if a._class == "BP_PlayerMarker_C" and a._valid and a.loc.X == 6000 then ra = a end end
check(ra ~= nil and ra["Marker Data"][MDN.title]._text == "Вася", "host ran the game's Svr_SpawnPlayerMarker for the client (owner written)")
check(ra and live_on(hmw, ra) == 0, "sharing off: kept off the host's map in the same call")
local l4 = last_list(cpc)
check(count(l4) == 2, "client's list now has 2 own markers")
local rkey = MK.by_addr[ra._addr]

-- H6: MKREQ first, then the game's RPC: the second is removed (Lua-call hook not seen)
print("-- MKREQ first, RPC second")
W.no_lua_hook = true
net.handlers.MKREQ({ "7000.0", "100.0", "30.0" }, cpc)
W.no_lua_hook = nil
local cnt = alive()
local dupa = game_rpc(cmm, { X = 7000, Y = 100, Z = 30 })
check(dupa._valid == false and alive() == cnt and MK.stats.dups == 1, "the RPC's duplicate destroyed")
check(MK.stats.via_req == 2, "both MKREQ placements counted")

-- H7: MKREQ without z (the client could not trace): the host traces
W.ground = 77
net.handlers.MKREQ({ "8000.0", "100.0", "" }, cpc)
local za = nil
for _, a in ipairs(W.actors) do if a._class == "BP_PlayerMarker_C" and a._valid and a.loc.X == 8000 then za = a end end
check(za and za.loc.Z == 77, "MKREQ without z: the game's Marker Location on the host")

-- H8: MKDEL of an own marker; MKDEL of the host's while sharing is off
print("-- MKDEL")
sent = {}
net.handlers.MKDEL({ tostring(rkey) }, cpc)
check(ra._valid == false and MK.recs[rkey] == nil, "MKDEL: the game's removal on the host")
local l5 = last_list(cpc)
check(l5 and l5[rkey] == nil, "the next list drops it")
net.handlers.MKDEL({ tostring(hkey) }, cpc)
check(ha._valid == true, "MKDEL of the host's marker while sharing is off: refused")

-- H9: sharing on again: the client's markers come back on the host's map
print("-- sharing on again")
cfg.v.map_markers_shared = true
tick()
tick()
n, hw = live_on(hmw, ca)
check(n == 1 and hw.tip == "Вася" and same_col(hw.Icon.ColorAndOpacity, VIOLET), "client's marker back on the host's map (RespawnMarker), styled")

-- H10: the host removes the client's marker on its map
print("-- host double-click")
sent = {}
n, hw = live_on(hmw, ca)
dblclick(hw)
check(ca._valid == false and MK.recs[ckey] == nil, "host's double-click removes the client's marker")
local l6 = last_list(cpc)
check(l6 and l6[ckey] == nil, "the list to the client drops it")

-- H11: the actor's Marker names another map's widget (a client's respawn
-- scope): the clicked widget still leaves the host's map
local sa = game_rpc(hmm, { X = 900, Y = 900, Z = 0 })
local _, sw = live_on(hmw, sa)
sa.Marker = cmm.MapWidget:add(sa["Marker Data"], sa)
dblclick(sw)
check(sa._valid == false and live_on(hmw, sa) == 0, "clicked widget off the host's map although Marker named another map's")

-- H12: duplicate and orphan widgets on the host's map
local da = game_rpc(hmm, { X = 1500, Y = 0, Z = 0 })
da:RespawnMarker()
check(live_on(hmw, da) == 2, "(setup) two widgets for one marker")
local oa = game_rpc(hmm, { X = 1600, Y = 0, Z = 0 })
oa._valid = false   -- DestroyAllActors: no hook
tick()
check(live_on(hmw, da) == 1, "duplicate widget taken off")
check(live_on(hmw, oa) == 0, "widget of a destroyed marker taken off")

-- H13: a loaded world: markers from the save, owner by the saved title
print("-- load")
pm.forget_world("load")
W.actors = {}
hmm.MapWidget = new_map()
hmw = hmm.MapWidget
local la = spawn_marker({ X = 10, Y = 10, Z = 0 }, 3)
la["Marker Data"] = copy_data(default_data())
la:RespawnMarker()   -- ActorLoaded
local lb = spawn_marker({ X = 20, Y = 20, Z = 0 }, 3)
lb["Marker Data"] = copy_data(default_data())
lb["Marker Data"][MDN.title] = FText("Вася")
lb["Marker Data"][MDN.color] = { R = 0.3, G = 1, B = 0.2, A = 1 }   -- colour of an older session
lb:RespawnMarker()
sent = {}
S.remote["PC_client"].hello = true
tick()
tick()
local l7 = last_list(cpc)
local own7, host7 = 0, 0
for _, e in pairs(l7 or {}) do
    if e.id == 257 and e.name == "Вася" then own7 = own7 + 1 end
    if e.id == 256 then host7 = host7 + 1 end
end
check(own7 == 1 and host7 == 1, "saved markers: the titled one is the client's again, the untitled one the host's")
n, hw = live_on(hmw, lb)
check(n == 1 and hw.tip == "Вася" and same_col(hw.Icon.ColorAndOpacity, VIOLET) and same_col(lb["Marker Data"][MDN.color], VIOLET),
    "its colour follows the player's current colour")

-- H14: many markers at once: one list in a few messages
print("-- burst")
for i = 1, 45 do
    local a = spawn_marker({ X = 100000 + i * 1000, Y = 0, Z = 0 }, 3)
    a["Marker Data"] = copy_data(default_data())
end
sent = {}
tick()
local l8, nmsg = last_list(cpc)
check(count(l8) == 47 and nmsg == 3 and #msgs("MKSYNC", cpc) == 3, "47 markers -> 3 MKSYNC messages (" .. tostring(nmsg) .. ")")

-- H15: no session, sharing off: the client's saved markers stay off the map
print("-- no session")
cfg.v.map_markers_shared = false
S.role = "standalone"
tick()
check(live_on(hmw, lb) == 0 and live_on(hmw, la) == 1, "single player with sharing off: clients' markers off, own stays")
cfg.v.map_markers_shared = nil
pm.report(function(s) print("    " .. s) end)

-- =================================================================== CLIENT
print("CLIENT")
pm.forget_world("join")
local S2 = { role = "client" }
local mypc = new_pc(257)
local me2 = new_pawn(257, { is_local = true, pc = mypc, role = 2 })
mypc.pawn = me2
W = { actors = {}, pawns = { me2 }, me = me2, pc = mypc, my_name = "Вася" }
local mm2, mw2 = me2.MinimapSystemComponent, me2.MinimapSystemComponent.MapWidget
pm.init(S2)
S.role = "standalone"   -- (the host's table above is not used any more)
tick()
tick()

-- the client's own GPS state: told on a change and as the verify every 60 s
do
    sent = {}
    for _ = 1, 360 do tick(1) end
    local n = 0
    for _, m in ipairs(sent) do if m.kind == "MYGPS" then n = n + 1 end end
    check(n >= 5 and n <= 8, "MYGPS: the verify every 60 s, not every 10 s (" .. n .. " in 6 minutes)")
end
-- C1: the host's list in two parts, second part first
print("-- list")
sent = {}
local own_e = "1,257,1000,2000,50,0.600,0.450,1.000,Вася"
local host_e = "2,256,3000,4000,60,1.000,0.900,0.100,Host"
net.handlers.MKSYNC({ "7", "2", "2", host_e })
check(alive() == 0, "nothing before the list is complete")
net.handlers.MKSYNC({ "7", "1", "2", own_e })
check(alive() == 2 and W.deferred == 2 and W.add_calls == 2, "two local copies, spawned the game's way + Event_AddMarker")
local own_a, host_a = nil, nil
for _, a in ipairs(W.actors) do
    if a._class == "BP_PlayerMarker_C" and a.loc.X == 1000 then own_a = a end
    if a._class == "BP_PlayerMarker_C" and a.loc.X == 3000 then host_a = a end
end
local n1, w1 = live_on(mw2, own_a)
local n2, w2 = live_on(mw2, host_a)
check(n1 == 1 and same_col(w1.Icon.ColorAndOpacity, { R = 1, G = 1, B = 1 }) and w1.tip == nil, "own marker on the own map, game look")
check(n2 == 1 and same_col(w2.Icon.ColorAndOpacity, YELLOW) and w2.tip == "Host", "host's marker in the host's colour, name as tooltip")
check(host_a["Marker Data"][MDN.title]._text == "Host" and same_col(host_a["Marker Data"][MDN.color], YELLOW), "its Marker Data keeps colour and name (RespawnMarker)")

-- C2: own double-click on the map -> MKREQ with the game's trace
print("-- placing")
sent = {}
W.ground = 42
fire("create", mm2, { X = 1234, Y = 5678 })
local rq = msgs("MKREQ", "host")
check(#rq == 1 and rq[1].f[1] == "1234.0" and rq[1].f[2] == "5678.0" and rq[1].f[3] == "42.0", "MKREQ with the game's Marker Location result")
W.trace_ok = false
fire("create", mm2, { X = 1, Y = 1 })
check(#msgs("MKREQ", "host") == 1, "no ground: no request (as in single player)")
W.trace_ok = nil

-- C3: own removal on the map
print("-- removal")
sent = {}
dblclick(w1)
local dl = msgs("MKDEL", "host")
check(own_a._valid == false and #dl == 1 and dl[1].f[1] == "1", "own double-click: the game removes it, MKDEL to the host")
tick()
check(alive() == 1, "not made again while the host's list still has it")
net.handlers.MKSYNC({ "8", "1", "1", host_e })
check(count(MK.removed) == 0, "the host's next list drops it")

-- C4: the game destroys a local copy (not the player): made again
print("-- destroyed by the game")
host_a._valid = false
tick()
local again = nil
for _, a in ipairs(W.actors) do if a._class == "BP_PlayerMarker_C" and a._valid and a.loc.X == 3000 then again = a end end
check(again ~= nil and live_on(mw2, again) == 1, "made again and on the map")
host_a = again

-- C5: a new map (respawn): own copies back through RespawnMarker
print("-- new map")
mm2.MapWidget = new_map()
mw2 = mm2.MapWidget
local rc = W.respawn_calls or 0
tick()
n2, w2 = live_on(mw2, host_a)
check(n2 == 1 and (W.respawn_calls or 0) == rc + 1 and w2.tip == "Host", "on the new map once, styled")

-- C6: a replicated copy registered on the map (sdc_players' RespawnMarker loop) and a duplicate
local copy = spawn_marker({ X = 3000, Y = 4000, Z = 60 }, 1)
copy:RespawnMarker()
host_a:RespawnMarker()
check(live_on(mw2, copy) == 1 and live_on(mw2, host_a) == 2, "(setup) copy widget + duplicate")
tick()
check(live_on(mw2, copy) == 0 and copy._valid == true, "replicated copy's widget taken off, the copy untouched")
check(live_on(mw2, host_a) == 1, "duplicate taken off")

-- C7: double-click on a copy's widget (before the sweep): the own copy at that spot is removed
copy:RespawnMarker()
local _, cw = live_on(mw2, copy)
sent = {}
dblclick(cw)
check(#msgs("MKDEL", "host") == 1 and msgs("MKDEL", "host")[1].f[1] == "2" and host_a._valid == false, "click on a copy's widget removes the own copy at its spot")
net.handlers.MKSYNC({ "9", "1", "1", host_e .. ";" .. "3,256,9000,9000,0,1.000,0.900,0.100,Host" })

-- C8: own setting off: others' markers hidden on this map
print("-- own sharing off")
net.handlers.MKSYNC({ "10", "1", "1", own_e .. ";" .. "3,256,9000,9000,0,1.000,0.900,0.100,Host" })
check(alive() == 2, "(setup) own + host's")
cfg.v.map_markers_shared = false
tick()
check(alive() == 1, "others' copies removed, own stays")
cfg.v.map_markers_shared = nil
tick()
check(alive() == 2, "shown again when switched back")

-- C9: list while dead: copies come with the character
print("-- no character")
local saved_me = W.me
W.me = nil
net.handlers.MKSYNC({ "11", "1", "1", own_e .. ";" .. "3,256,9000,9000,0,1.000,0.900,0.100,Host;4,256,9500,9500,0,1.000,0.900,0.100,Host" })
check(alive() == 2, "no character: nothing spawned yet")
W.me = saved_me
tick()
check(alive() == 3, "spawned once the own character is there")

-- C10: Svr_SpawnPlayerMarker running on this client (not expected): replaced by the host's
local stray = svr_body(mm2, { X = 50, Y = 50, Z = 0 })
fire("svr", mm2, { X = 50, Y = 50, Z = 0 }, true)
check(stray._valid == false, "a marker the client's own Svr_SpawnPlayerMarker made is removed")

-- C11: leaving: own copies go
print("-- leaving")
S2.role = "standalone"
tick()
check(alive() == 0, "own copies removed on leaving")
pm.report(function(s) print("    " .. s) end)

print(string.format("%d checks, %s", checks, fails == 0 and "ALL OK" or (fails .. " FAILURES")))
