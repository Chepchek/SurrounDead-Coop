-- Mock harness for sdc_playermarks.lua (fake engine; logic only).
-- usage: lua mock_marks.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails = 0
local function check(c, what) print((c and "  ok   " or "  FAIL ") .. what); if not c then fails = fails + 1 end end

-- ------------------------------------------------------------- globals
FText = function(s) return { _text = s } end
FName = function(s) return { _fname = s } end
LoadAsset = function() end

-- ------------------------------------------------------------- fake objects
local n = 0
local function obj(class, t)
    n = n + 1
    t = t or {}
    t._class, t._valid = class, true
    t._name = t._name or (class .. "_" .. n)
    return t
end

local W = {}   -- current world
local sent = {}

local function make_struct()
    return {
        ["MarkerTitle_47_5E7A698C4B5AC497BBB438A55515B853"] = { _text = "" },
        ["MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD"] = obj("Texture2D"),
        ["TextureSize_30_0FC614D34939DCCA4077899925344EDF"] = { X = 1, Y = 1 },
        ["TextSize_33_ADA10B73491C7DD1835FD69801CC42F1"] = { X = 1, Y = 1 },
        ["MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872"] = { R = 1, G = 1, B = 1, A = 1 },
        ["CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4"] = false,
    }
end

local function new_marker(data, target)
    local text = obj("TextBlock", { vis = 1 })
    text.SetText = function(self, t) self.text = t._text end
    text.SetVisibility = function(self, v) self.vis = v end
    local m = obj("W_StandardMarker_C", { ["Target Actor"] = target, ["Marker Data"] = data, Text = text, vis = 4 })
    m.SetVisibility = function(self, v) self.vis = v end
    m.SetRenderScale = function(self, s) self.scale = s.X end
    return m
end

local function new_minimap()
    local mw = obj("MapWidget_C", { InnerCanvas = obj("CanvasPanel", { RenderTransform = { Scale = { X = 0.25, Y = 0.25 } } }), made = {} })
    local mm = obj("BPC_MinimapSystem_C", { MapWidget = mw, MapToggled = false, DefaultPlayerMarkerData = make_struct() })
    mm["Add Standard Marker"] = function(self, data, target, out)
        assert(type(data) == "table" and target and type(out) == "table", "bad params")
        local m = new_marker(data, target)
        mw.made[#mw.made + 1] = m
        out.Markers = m
    end
    return mm, mw
end

local function new_ps(id) local ps = obj("PlayerState"); ps.GetPlayerId = function() return id end; return ps end

local function new_pawn(id, loc, opts)
    opts = opts or {}
    local p = obj("BP_PlayerCharacter_C", { PlayerState = new_ps(id), ["PlayerDead?"] = false, bHidden = false,
        Role = opts.role or 3, loc = loc, gps = opts.gps or false, comps = {}, Mesh = obj("SkeletalMeshComponent") })
    p.IsLocallyControlled = function() return opts.is_local == true end
    p.BP_JigHelperComp = obj("BP_JigHelperComp_C", { ServerEquippedItems = {
        ["EquippedGPS_58_A18BCF9B44989D75939B038888DBFC9C"] = {},
        ["EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB"] = {} } })
    if opts.hud then
        local cw = obj("Compass_C", { vis = opts.compass_vis or 2 })
        cw.GetVisibility = function(s) return s.vis end
        cw.SetVisibility = function(s, v) s.vis = v end
        p.InGameUI = obj("BP_Ingame_C", { Compass = cw })
        p.InGameUI.IsInViewport = function() return true end
    end
    p.ShowCompassWidget = function(self, show) if self.InGameUI then self.InGameUI.Compass.vis = show and 4 or 2 end; W.show_calls = (W.show_calls or 0) + 1 end
    p["IsGPSEquipped?"] = function(self, out) out["GPS?"] = self.gps end
    p.GetComponentByClass = function(self) return self.comps[1] end
    p.AddComponentByClass = function(self, cls, manual, tf, deferred)
        assert(deferred == true)
        local c = obj("WidgetComponent", { visible = true })
        c.SetWidgetSpace = function(s, v) s.space = v end
        c.SetDrawAtDesiredSize = function(s, v) s.desired = v end
        c.SetCollisionEnabled = function(s, v) s.coll = v end
        c.SetVisibility = function(s, v) s.visible = v end
        c.GetUserWidgetObject = function(s) return s.widget end
        c.SetWidget = function(s, w) s.widget = w end
        self.comps[1] = c
        return c
    end
    p.FinishAddComponent = function(self, c)
        if c.WidgetClass then
            local w = obj("BP_InteractWidgetCivilian_C")
            w.Txt = obj("TextBlock", { t = "Interact" })
            w.Txt.GetText = function(s) return s.t end
            w.SetName = function(s, a, b) s.Txt.t = a._text .. " " .. b._text end
            c.widget = w
        end
    end
    if opts.minimap then p.MinimapSystemComponent, W.mw = new_minimap() end
    return p
end

local function new_pc(id, opts)
    opts = opts or {}
    local pc = obj("PlayerController", { PlayerState = new_ps(id) })
    pc.LineOfSightTo = function() return true end
    pc.PlayerCameraManager = obj("PlayerCameraManager")
    pc.PlayerCameraManager.GetCameraLocation = function() return W.cam_loc end
    pc.PlayerCameraManager.GetCameraRotation = function() return W.cam_rot end
    return pc
end

local GS = obj("GameplayStatics")
GS.BeginDeferredActorSpawnFromClass = function(_, wc, cls, tf, coll, owner, scale)
    assert(cls and tf.Translation and coll == 1 and scale == 0)
    local a = obj("BP_CompassMarker_C", { loc = tf.Translation })
    a.K2_AttachToComponent = function(self, parent) self.parent = parent; return true end
    a.K2_DetachFromActor = function(self) self.parent = nil end
    a.K2_DestroyActor = function(self) self._valid = false; W.destroyed = (W.destroyed or 0) + 1 end
    W.actors[#W.actors + 1] = a
    return a
end
GS.FinishSpawningActor = function(_, a) return a end

-- ------------------------------------------------------------- module mocks
package.preload["sdc_log"] = function()
    local L = { debug_enabled = false }
    local function out(lvl) return function(fmt, ...) print("    [" .. lvl .. "] " .. string.format(fmt, ...)) end end
    L.info, L.warn, L.err, L.debug = out("I"), out("W"), out("E"), function() end
    L.err_throttled = function(k, fmt, ...) print("    [E!] " .. string.format(fmt, ...)); if k ~= "pm.hudflip" then fails = fails + 1 end end
    return L
end
package.preload["sdc_config"] = function()
    local C = { v = {} }
    C.get = function(k) return C.v[k] end
    C.player_name = function() return W.my_name end
    return C
end
package.preload["sdc_net"] = function()
    local N = { handlers = {} }
    N.on = function(k, h) N.handlers[k] = h end
    N.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, f = { ... } }; return true end
    N.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, f = { ... } }; return true end
    return N
end
package.preload["sdc_ue"] = function()
    local U = { ROLE_SIMULATED = 1 }
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
        for _, p in ipairs(W.pawns) do if p._class == c then out[#out + 1] = p end end
        for _, h in ipairs(W.huds or {}) do if h._class == c then out[#out + 1] = h end end
        return out
    end
    U.find_object = function(path)
        if path:find("WidgetComponent") then return obj("Class") end
        if path:find("ConsoleUtils") then return W.CU end
        if path:find("DA_") then W.assets = W.assets or {}; W.assets[path] = W.assets[path] or obj("JigsawItem_DataAsset", { _path = path, _name = path }); return W.assets[path] end
        return obj("Asset")
    end
    U.gameplay_statics = function() return GS end
    U.widget_lib = function() return nil end
    U.local_pc = function() return W.pc end
    U.local_pawn = function() return W.me end
    U.pawn_of = function(pc) return pc and pc.pawn end
    U.location = function(a) if not U.valid(a) then return nil end if a.parent then return W.loc_of_mesh(a.parent) end return a.loc end
    U.teleport = function(a, l) a.loc = l; return true end
    U.role = function(p) return p.Role end
    U.path = function(o) return U.valid(o) and o._path or "" end
    U.ksl = function() return nil end
    U.exec = function() return false end
    U.find_all_extra = nil
    return U
end

local function new_cu(vals)
    local cu = obj("ConsoleUtils", { vals = vals })
    cu.GetBoolCVar = function(self, n) return self.vals[n._fname] end
    cu.SetBoolCVar = function(self, n, v) self.vals[n._fname] = v end
    return cu
end
local pm = require("sdc_playermarks")
local net = require("sdc_net")

-- ===================================================================== HOST
print("HOST")
local S = { role = "host", remote = {}, remote_pcs = {} }
W = { CU = new_cu({ ["Difficulty.MapVisibility"] = true }), actors = {}, my_name = "Host", cam_loc = { X = 0, Y = 0, Z = 160 }, cam_rot = { Pitch = 0, Yaw = 0 } }
pm.init(S)
local host_me = new_pawn(256, { X = 0, Y = 0, Z = 100 }, { is_local = true, gps = true, minimap = true })
local host_mw = W.mw
local cpc = new_pc(257)
local cpawn = new_pawn(257, { X = 1000, Y = 0, Z = 100 }, { gps = false })
cpc.pawn = cpawn
W.pc, W.me, W.pawns = new_pc(256), host_me, { host_me, cpawn }
W.loc_of_mesh = function(mesh) for _, p in ipairs(W.pawns) do if p.Mesh == mesh then return p.loc end end end
S.remote["PC_client"] = { key = "PC_client", pc = cpc, name = "Вася", hello = true }
S.remote_pcs = { cpc }

pm.tick()
local pinfo = 0
for _, m in ipairs(sent) do if m.kind == "PINFO" then pinfo = pinfo + 1 end end
check(pinfo >= 2, "host sends PINFO for both players (" .. pinfo .. ")")
local pcv = nil
for _, m in ipairs(sent) do if m.kind == "PCVAR" then pcv = m end end
check(pcv and pcv.f[1] == "Difficulty.MapVisibility" and pcv.f[2] == "1", "host sends PCVAR MapVisibility=1")
check(#W.actors == 1 and #host_mw.made == 0, "compass marker actor but no map marker while client has no GPS")
-- client reports GPS
cpc._name = "PC_client"
net.handlers.MYGPS({ "1" }, cpc)
sent = {}
T = T + 1; pm.tick()
check(#W.actors == 1 and W.actors[1].parent == cpawn.Mesh, "client marker actor attached to its mesh")
check(#host_mw.made == 1 and host_mw.made[1]["Target Actor"] == W.actors[1], "map marker targets the marker actor")
check(host_mw.made[1].Text.text == "Вася" and host_mw.made[1].Text.vis == 4, "map marker shows the name")
-- map open: counter scale
W.me.MinimapSystemComponent.MapToggled = true
pm.fast_tick()
check(math.abs((host_mw.made[1].scale or 0) - 4.0) < 1e-6, "marker counter-scaled to 1/0.25")
-- looking at the client: name tag
pm.fast_tick()
check(cpawn.comps[1] and cpawn.comps[1].visible == true and cpawn.comps[1].space == 1, "name tag shown in screen space")
check(cpawn.comps[1].widget.Txt.t == "Вася ", "name tag text set")
-- look away
W.cam_rot = { Pitch = 0, Yaw = 180 }
T = T + 0.2; pm.fast_tick()
check(cpawn.comps[1].visible == true, "name lingers")
T = T + 1; pm.fast_tick()
check(cpawn.comps[1].visible == false, "name hidden after linger")
-- client wears a compass on the host copy -> PEQUIP to that client
local DA_C = obj("JigsawItem_DataAsset", { _path = "/Game/Items/DA_Compass.DA_Compass" })
cpawn.BP_JigHelperComp.ServerEquippedItems["EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] = DA_C
sent = {}
T = T + 1; pm.tick()
local pe = nil
for _, m in ipairs(sent) do if m.kind == "PEQUIP" and m.to == cpc then pe = m end end
check(pe and pe.f[1] == "" and pe.f[2] == "/Game/Items/DA_Compass.DA_Compass", "host sends PEQUIP with the compass")
sent = {}
T = T + 1; pm.tick()
pe = nil
for _, m in ipairs(sent) do if m.kind == "PEQUIP" then pe = m end end
check(pe == nil, "PEQUIP not repeated every second")
-- relay: client is 10 m away -> no PPOS
local pp = 0
for _, m in ipairs(sent) do if m.kind == "PPOS" then pp = pp + 1 end end
check(pp == 0, "no PPOS for a near client")
-- client far away; host has GPS -> PPOS of host to client
cpawn.loc = { X = 50000, Y = 0, Z = 100 }
sent = {}
T = T + 1; pm.tick()
pp = 0
for _, m in ipairs(sent) do if m.kind == "PPOS" and m.f[1] == 256 then pp = pp + 1 end end
check(pp == 1, "PPOS of host sent to far client")
-- client unequips
net.handlers.MYGPS({ "0" }, cpc)
T = T + 1; pm.tick()
check(W.actors[1]._valid == true, "compass marker actor stays on GPS off")
check(host_mw.made[1].vis == 1, "map marker hidden on GPS off")
-- GPS on again -> reuse marker widget
net.handlers.MYGPS({ "1" }, cpc)
T = T + 1; pm.tick()
check(#host_mw.made == 1 and host_mw.made[1].vis == 3 and host_mw.made[1]["Target Actor"] == W.actors[1], "marker widget shown again")
-- client dies
cpawn["PlayerDead?"] = true
T = T + 1; pm.tick()
check(W.actors[1]._valid == false, "marker removed on death")
-- world reset drops everything untouched
pm.forget_world("test")
pm.report(function(s) print("    " .. s) end)

-- ===================================================================== CLIENT
print("CLIENT")
local S2 = { role = "client" }
W = { CU = new_cu({ ["Difficulty.MapVisibility"] = false }), actors = {}, my_name = "Вася", cam_loc = { X = 0, Y = 0, Z = 160 }, cam_rot = { Pitch = 0, Yaw = 0 } }
pm.init(S2)
local me2 = new_pawn(257, { X = 0, Y = 0, Z = 100 }, { is_local = true, gps = true, minimap = true, role = 2, hud = true, compass_vis = 4 })
local stale = new_pawn(999, { X = 0, Y = 0, Z = 0 }, { hud = true, compass_vis = 4 })
local mw2 = W.mw
W.pc, W.me, W.pawns = new_pc(257), me2, { me2 }
W.huds = { stale.InGameUI }
W.loc_of_mesh = function(mesh) for _, p in ipairs(W.pawns) do if p.Mesh == mesh then return p.loc end end end
sent = {}
pm.tick()
local mygps = false
for _, m in ipairs(sent) do if m.kind == "MYGPS" and m.f[1] == "1" then mygps = true end end
check(mygps, "client sends MYGPS 1")
check(me2.InGameUI.Compass.vis == 2, "HUD compass hidden before any PEQUIP (single-player default)")
check(stale.InGameUI.Compass.vis == 2, "another HUD's compass hidden")
net.handlers.PCVAR({ "Difficulty.MapVisibility", "1" })
net.handlers.PCVAR({ "Debug.NoClip", "1" })
T = T + 1; pm.tick()
check(W.CU.vals["Difficulty.MapVisibility"] == true, "client takes the host's MapVisibility")
check(W.CU.vals["Debug.NoClip"] == nil, "unlisted CVar ignored")
-- empty PEQUIP keeps everything empty and hidden
net.handlers.PEQUIP({ "", "" })
T = T + 1; pm.tick()
local sei0 = me2.BP_JigHelperComp.ServerEquippedItems
check(sei0["EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] == nil
    and sei0["EquippedGPS_58_A18BCF9B44989D75939B038888DBFC9C"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] == nil, "empty PEQUIP writes nothing")
check(me2.InGameUI.Compass.vis == 2, "compass stays hidden with an empty slot")
net.handlers.PINFO({ "256", "1", "Host" })
net.handlers.PINFO({ "257", "1", "Вася" })
-- host far away: only relayed position
net.handlers.PPOS({ "256", "40000", "0", "100" })
T = T + 1; pm.tick()
check(#W.actors == 1 and W.actors[1].parent == nil, "relay marker actor for far host")
check(#mw2.made == 1 and mw2.made[1].Text.text == "Host", "client map marker for host")
net.handlers.PPOS({ "256", "41000", "0", "100" })
pm.fast_tick()
check(W.actors[1].loc.X > 40000 and W.actors[1].loc.X < 41000, "relay smoothing moves the actor")
-- host comes into range: attach
local hp = new_pawn(256, { X = 5000, Y = 0, Z = 100 }, { role = 1 })
W.pawns[#W.pawns + 1] = hp
T = T + 1; pm.tick()
check(W.actors[1].parent == hp.Mesh, "attached to host mesh when replicated")
-- host leaves range (destroyed) and relay stale -> removed
hp._valid = false
T = T + 5; pm.tick()
check(W.actors[1]._valid == false, "marker removed when no pawn and no fresh relay")
-- PEQUIP: compass slot -> written + HUD compass shown; GPS slot empty
net.handlers.PEQUIP({ "", "/Game/Items/DA_Compass.DA_Compass" })
T = T + 1; pm.tick()
local sei = me2.BP_JigHelperComp.ServerEquippedItems
check(sei["EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] ~= nil, "client compass slot written")
check(me2.InGameUI.Compass.vis == 4, "client HUD compass shown")
local calls = W.show_calls
T = T + 1; pm.tick()
check(W.show_calls == calls, "ShowCompassWidget not repeated")
me2.InGameUI.Compass.vis = 2   -- something else hid it
T = T + 1; pm.tick()
check(me2.InGameUI.Compass.vis == 4, "HUD compass re-shown after an outside change")
net.handlers.PEQUIP({ "/Game/Items/DA_GPS.DA_GPS", "" })
T = T + 1; pm.tick()
check(sei["EquippedCompass_59_E0A6289D4D59B1D4ABEB43AC8A5527BB"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] == nil, "client compass slot cleared")
check(sei["EquippedGPS_58_A18BCF9B44989D75939B038888DBFC9C"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] ~= nil, "client GPS slot written")
check(me2.InGameUI.Compass.vis == 2, "client HUD compass hidden on unequip")
-- leaving: own MapVisibility comes back
S2.role = "standalone"
T = T + 1; pm.tick()
check(W.CU.vals["Difficulty.MapVisibility"] == false, "own MapVisibility restored on leaving")
-- own entry never shown
check(#mw2.made == 1, "no marker for self")

print(fails == 0 and "ALL OK" or (fails .. " FAILURES"))
