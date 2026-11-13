-- Mock harness for sdc_shower (decontamination shower: one host cooldown per
-- shower that a client's copy shows and keeps, water / lights / power for
-- every player, decontamination once for everyone inside). Two module
-- instances, one per machine, each with its own world and its own player 0;
-- the shower's Blueprint logic is simulated (pseudo_shower); messages go
-- through sdc_net's real encode / decode. The client's screen is an sdc_notes
-- stand-in with the game's rule: a text already on screen is not added again
-- (then the call added nothing: not "fresh"). The host's relay of the game's
-- notes (sdc_notes) is tested with the real modules in mock_shower_relay.
-- usage: lua mock_shower.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ------------------------------------------------------------ fake objects
local machine = "host"
local worlds = { host = {}, client = {} }
local Obj = {}
local next_addr = 4096
local function new_obj(cls, short, props, methods, where)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true }
    setmetatable(o, Obj)
    if where ~= false then
        local w = worlds[where or machine]
        w[#w + 1] = o
    end
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    local p = rawget(t, "_p")[k]
    if p ~= nil then return p end
    return nil
end
Obj.__newindex = function(t, k, v) rawget(t, "_p")[k] = v end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetAddress() return self._addr end
function Obj:GetOuter() return nil end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local PATH = "/Game/Blueprints/BuildingSystem/Actors/Other/Buildable_DecontaminationShower.Buildable_DecontaminationShower_C"
local BASE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local CLS = "Buildable_DecontaminationShower_C"
local F = {
    decon = PATH .. ":DecontaminatePlayer", press = PATH .. ":OnInteractBuildable", cooldown = PATH .. ":Event_Cooldown",
    on = PATH .. ":On", off = PATH .. ":Off", exec = BASE .. ":OnExecuteInteract",
}
local TEXT_COOL = "Decontamination shower cooldown in effect..."
local TEXT_NOPOWER = "No power"
local timers = {}   -- [object] = { [name] = clock when it fires }
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {
    K2_GetTimerRemainingTime = function(_, o, n)
        local t = timers[o] and timers[o][n]
        if t then return t - T end
        return -1
    end,
    K2_ClearTimer = function(_, o, n) if timers[o] then timers[o][n] = nil end end,
}, false)
local MATS = {}
for _, c in ipairs({ "Green", "Orange", "Red" }) do
    MATS[c] = new_obj("MaterialInstanceConstant", "M_EmissiveColour_" .. c, {}, {}, false)
end
function StaticFindObject(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return ksl end
    local mc = path:match("^/Game/Meshes/Materials/M_EmissiveColour_(%a+)%.")
    if mc then return MATS[mc] end
    if path:find("/Game/", 1, true) then return new_obj("Object", path, {}, {}, false) end
    return nil
end
local hooks = { host = {}, client = {} }
local hook_machine = "host"
function RegisterHook(path, fn) hooks[hook_machine][path] = fn; return 1, 2 end
function FindAllOf(cls)
    local out = {}
    for _, o in ipairs(worlds[machine]) do
        if o._valid and o._cls == cls then out[#out + 1] = o end
    end
    return #out > 0 and out or nil
end
function FindFirstOf(cls) local l = FindAllOf(cls); return l and l[1] or nil end
function NotifyOnNewObject() end
function ExecuteInGameThread(f) f() end
function ExecuteInGameThreadWithDelay() return 1 end
function LoopInGameThreadWithDelay() return 1 end
function ExecuteWithDelay() end
function LoopAsync() end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
function LoadAsset() return nil end

local lines = {}
local real_print = print
print = function(s) lines[#lines + 1] = s end
local function logged(pat, from)
    for i = from or 1, #lines do if lines[i]:find(pat, 1, true) then return lines[i] end end
    return nil
end

local cfg = require("sdc_config")
cfg.load(os.tmpname())
cfg.set("debug", true)
local log = require("sdc_log")
log.debug_enabled = true
local ue = require("sdc_ue")
ue.every = function() end
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local function on(m) machine = m; ue.forget_world() end
local function fire(m, path, ...)
    local cb = hooks[m][path]
    if cb then return cb(...) end
end

-- ------------------------------------------------------------ the client's screen (sdc_notes stand-in)
local screen = {}   -- notification widgets { text, t, by }; gone after 3 s
local recent = {}   -- [text] = { t, fresh }
local quiet = false -- sdc_ctx's client mode keeps the copy's notes off this screen (another player's copy)
local function on_screen(text)
    local n = 0
    for _, s in ipairs(screen) do if s.text == text and T - s.t < 3 then n = n + 1 end end
    return n
end
local function raise(text, by)
    local fresh = on_screen(text) == 0
    if fresh then screen[#screen + 1] = { text = text, t = T, by = by } end
    recent[text] = { t = T, fresh = fresh }
    return fresh
end
local fake_notes = {
    OWN_CLASSES = {},
    covered = function(text, s) local r = recent[text]; return r ~= nil and T - r.t <= (s or 5) end,
    shown_fresh = function(text, s) local r = recent[text]; return r ~= nil and r.fresh and T - r.t <= (s or 0.25) end,
    take_off = function(text)
        for i = #screen, 1, -1 do
            if screen[i].text == text then table.remove(screen, i); return true end
        end
        return false
    end,
    show_here = function(text) raise(text, "mod"); return true end,
}
local function clear_screen() screen, recent = {}, {} end
local host_notes = 0   -- notes the host's copies raised (relayed to the scope player by sdc_notes)

-- ------------------------------------------------------------ players
local function rad_comp(cur)
    return new_obj("RadiationComponent_C", "RadiationComponent", { CurrentRadiation = cur or 40, MaxRadiation = 100, __calls = 0 }, {
        IncreaseRadiation = function(self, amount)
            self._p.__calls = self._p.__calls + 1
            self._p.CurrentRadiation = math.min(self._p.MaxRadiation, self._p.CurrentRadiation + amount)
        end,
    }, false)
end
local function capsule() return new_obj("CapsuleComponent", "CollisionCylinder", {}, {
    GetScaledCapsuleRadius = function() return 34 end, GetScaledCapsuleHalfHeight = function() return 88 end }, false)
end
local function medical(sick)
    return new_obj("MedicalComponent_C", "MedicalComponent", { ["RadiationSickness?"] = sick, __onrep = 0 }, {
        ["OnRep_RadiationSickness?"] = function(self) self._p.__onrep = self._p.__onrep + 1 end,
    }, false)
end
local function char(where, short, pc, loc)
    return new_obj("BP_PlayerCharacter_C", short, { Controller = pc, __loc = loc, RadiationComponent = rad_comp(),
        CapsuleComponent = capsule(), MedicalComponent = medical(false),
        InGameUI = new_obj("BP_Ingame_C", "InGameUI", { __rad = nil }, {
            UpdateRadiation = function(self, v) self._p.__rad = v end }, false) }, {}, where)
end
local function players(where, local_short, loc)
    local lp = new_obj("LocalPlayer", "LocalPlayer_0", {}, {}, where)
    local pc = new_obj("PlayerController", local_short .. "_PC", { Player = lp }, {}, where)
    local pawn = char(where, local_short, pc, loc)
    pc._p.Pawn = pawn
    return pc, pawn
end
local SA, SB, SC = { X = 0, Y = 0, Z = 0 }, { X = 5000, Y = 0, Z = 0 }, { X = 9000, Y = 0, Z = 0 }
local IN_A = { X = 10, Y = -20, Z = 90 }        -- a capsule centre inside shower A's box
local OUT_A = { X = 300, Y = 0, Z = 90 }        -- next to it, outside

local host_pc, host_pawn = players("host", "BP_PlayerCharacter_C_0", { X = 300, Y = 0, Z = 90 })
local conn = new_obj("IpConnection", "IpConnection_1", {}, {}, "host")
local rpc_h = new_obj("BP_PlayerController_C", "BP_PlayerController_C_7", { Player = conn, NetConnection = conn }, {}, false)
local client_on_host = char("host", "BP_PlayerCharacter_C_5", rpc_h, { X = 10, Y = -20, Z = 90 })
rpc_h._p.Pawn = client_on_host
-- a dead player's body on the host (its controller still there)
local dead_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_8", { Player = conn, NetConnection = conn }, {}, false)
local dead_body = char("host", "BP_PlayerCharacter_C_6", dead_pc, { X = 3000, Y = 3000, Z = 90 })
dead_body._p["PlayerDead?"] = true
local client_pc, client_pawn = players("client", "BP_PlayerCharacter_C_1", { X = 10, Y = -20, Z = 90 })
local host_copy = char("client", "BP_PlayerCharacter_C_9", nil, { X = 300, Y = 0, Z = 90 })

-- ------------------------------------------------------------ the shower Blueprint (pseudo_shower)
local function comp(cls, short, props, methods) return new_obj(cls, short, props or {}, methods or {}, false) end
local function fx() return comp("ParticleSystemComponent", "FX", { __on = false }, {
    IsActive = function(s) return s._p.__on end,
    Activate = function(s) s._p.__on = true end,
    Deactivate = function(s) s._p.__on = false end,
}) end
local function light(mat) return comp("StaticMeshComponent", "Light", { __mat = mat }, {
    GetMaterial = function(s) return s._p.__mat end,
    SetMaterial = function(s, _, m) s._p.__mat = m end,
}) end

-- who GetPlayerCharacter(self, 0) gives inside the shower's DecontaminatePlayer
local function player0(where, s)
    if where == "host" then
        local cur = s._p.CurrentActor
        if cur and cur._p.Controller == rpc_h then return cur end   -- sdc_ctx: the build scope (CurrentActor)
        return host_pawn
    end
    if quiet then return nil end                                     -- client mode: another player's copy
    return client_pawn
end

local function shower(where, short, loc, powered, bound)
    local s
    s = new_obj(CLS, short, {
        __loc = loc, ["PoweredOn?"] = powered, ["CooldownRunning?"] = false, ["RequiresPower?"] = true, Cooldown = 300,
        Light = light(MATS.Red), Light2 = light(MATS.Red), FX_Water = fx(), FX_Water2 = fx(),
        Trace = comp("SceneComponent", "Trace", {}, { K2_GetComponentLocation = function()
            return { X = s._p.__loc.X, Y = s._p.__loc.Y, Z = s._p.__loc.Z + 120 } end }),
        __bound = bound,
    }, {
        OnInteractBuildable = function(self, actor)
            if not self._p["PoweredOn?"] then
                if where == "host" then host_notes = host_notes + 1 elseif not quiet then raise(TEXT_NOPOWER, "copy") end
            elseif self._p["CooldownRunning?"] then
                if where == "host" then host_notes = host_notes + 1 elseif not quiet then raise(TEXT_COOL, "copy") end
            else
                self._p["CooldownRunning?"] = true
                self["OnRep_CooldownRunning?"](self)
                self:DecontaminatePlayer()
                self._p.FX_Water:Activate(false); self._p.FX_Water2:Activate(false)
                timers[self] = timers[self] or {}
                timers[self].Event_Cooldown = T + self._p.Cooldown
            end
            fire(where, F.press, param(self), param(actor))
        end,
        DecontaminatePlayer = function(self)
            local p0 = player0(where, self)
            local c = self._p.Trace:K2_GetComponentLocation()
            if p0 then
                local l = p0._p.__loc
                if math.abs(l.X - c.X) <= 84 and math.abs(l.Y - c.Y) <= 119 and math.abs(l.Z - c.Z) <= 188 then
                    p0._p.RadiationComponent:IncreaseRadiation(100)
                    p0._p.MedicalComponent._p["RadiationSickness?"] = false
                end
            end
            fire(where, F.decon, param(self))
        end,
        Event_Cooldown = function(self)
            if timers[self] then timers[self].Event_Cooldown = nil end
            self._p["CooldownRunning?"] = false
            self["OnRep_CooldownRunning?"](self)
            fire(where, F.cooldown, param(self))
        end,
        ["OnRep_CooldownRunning?"] = function(self)
            local m = self._p["CooldownRunning?"] and MATS.Orange or MATS.Green
            self._p.Light._p.__mat, self._p.Light2._p.__mat = m, m
        end,
        On = function(self)
            if not self._p["CooldownRunning?"] then self._p.Light._p.__mat, self._p.Light2._p.__mat = MATS.Green, MATS.Green end
            fire(where, F.on, param(self))
        end,
        Off = function(self)
            self._p.Light._p.__mat, self._p.Light2._p.__mat = MATS.Red, MATS.Red
            fire(where, F.off, param(self))
        end,
        ["OnRep_PoweredOn?"] = function(self)
            if not self._p.__bound then return end   -- On / Off bound 1 s after BeginPlay
            if self._p["PoweredOn?"] then self:On() else self:Off() end
        end,
        ["Power On"] = function(self)
            if not self._p["PoweredOn?"] then self._p["PoweredOn?"] = true; self["OnRep_PoweredOn?"](self) end
        end,
        ["Power Off"] = function(self)
            if self._p["PoweredOn?"] then self._p["PoweredOn?"] = false; self["OnRep_PoweredOn?"](self) end
        end,
    }, where)
    return s
end
local function mat_of(s) return s._p.Light._p.__mat._short:match("_(%a+)$") end
local function water_of(s) return s._p.FX_Water._p.__on and s._p.FX_Water2._p.__on end
local function rad(p) return p._p.RadiationComponent._p.__calls end

-- the host's showers: A ready and powered, B powered and cooling 200 s more
on("host")
local hA = shower("host", "Buildable_DecontaminationShower_C_2147000001", SA, true, true)
hA["OnRep_CooldownRunning?"](hA)
local hB = shower("host", "Buildable_DecontaminationShower_C_2147000002", SB, true, true)
hB._p["CooldownRunning?"] = true; hB["OnRep_CooldownRunning?"](hB)
timers[hB] = { Event_Cooldown = T + 200 }
-- the client's copies (joined): A got PoweredOn? before its BeginPlay -> lights still red; B cooling (orange)
local cA = shower("client", "Buildable_DecontaminationShower_C_2146000001", { X = 0.4, Y = 0.3, Z = 0 }, true, true)
local cB = shower("client", "Buildable_DecontaminationShower_C_2146000002", SB, true, true)
cB._p["CooldownRunning?"] = true; cB["OnRep_CooldownRunning?"](cB)

-- ------------------------------------------------------------ module instances
local Sh = { role = "host", remote_pcs = { rpc_h }, map = "LongdownValley" }
local Sc = { role = "client", map = "LongdownValley", remote_pcs = {}, client = { acked = false, pc_key = "k" } }
package.loaded["sdc_notes"] = fake_notes
on("host")
local host_mod = require("sdc_shower")
host_mod.install(Sh)
local hh = { SHWR = net.handlers.SHWR, SHWRQ = net.handlers.SHWRQ, SHWRR = net.handlers.SHWRR, SHWRV = net.handlers.SHWRV }
package.loaded["sdc_shower"] = nil
on("client")
local client_mod = require("sdc_shower")
client_mod.install(Sc)
local ch = { SHWR = net.handlers.SHWR, SHWRQ = net.handlers.SHWRQ, SHWRR = net.handlers.SHWRR, SHWRV = net.handlers.SHWRV }
check(host_mod ~= client_mod and hh.SHWR and ch.SHWR and hh.SHWRQ and hh.SHWRR and ch.SHWRV, "two instances, handlers on both")

local wire = {}
net.send_to = function(pc, kind, ...) wire[#wire + 1] = { from = machine, to = pc, msg = net.encode(kind, ...) }; return true end
net.send_to_host = function(kind, ...) wire[#wire + 1] = { from = machine, to = "host", msg = net.encode(kind, ...) }; return true end
local function take(kind)
    local out, keep = {}, {}
    for _, m in ipairs(wire) do
        local k = net.decode(m.msg)
        if kind == nil or k == kind then out[#out + 1] = m else keep[#keep + 1] = m end
    end
    wire = keep
    return out
end
local function deliver(list)
    for _, m in ipairs(list) do
        local kind, fields = net.decode(m.msg)
        if m.to == "host" then on("host"); hh[kind](fields, rpc_h) else on("client"); ch[kind](fields, client_pc) end
    end
end
local function tick(m, mod) on(m); hook_machine = m; ctx.active = m == "host"; mod.tick() end
local function ticks(n, step)
    for _ = 1, n do T = T + (step or 0.25); tick("host", host_mod); tick("client", client_mod) end
end
local function force_pass() client_mod._t.st.pass_at = -100; tick("client", client_mod) end
local function rec_at(loc)
    for _, r in ipairs(client_mod._t.st.known) do
        if math.abs(r.loc.X - loc.X) < 1 and math.abs(r.loc.Y - loc.Y) < 1 then return r end
    end
    return nil
end
local USE = { TagName = FName("Jig.InteractOptions.Option1") }
local MOVE = { TagName = FName("Jig.InteractOptions.Option2") }

-- A press. The presser's own machine runs OnExecuteInteract (client: the
-- module's hook); the server's OnServerExecuteInteract (CurrentActor, the
-- multicast's local run). On the client the shower's bunch: its properties
-- first, then (copy_runs) the multicast, then the OnReps; `go_first`: the
-- mod's SHWR comes before the bunch.
local function press(hs, cs, presser_host, presser_client, opts)
    opts = opts or {}
    if presser_client == client_pawn then
        on("client"); fire("client", F.exec, param(cs), param(client_pawn), param(opts.option or USE))
    end
    on("host"); ctx.active = true
    hs._p.CurrentActor = presser_host
    hs:OnInteractBuildable(presser_host)
    local msgs = take("SHWR")
    if opts.go_first then deliver(msgs) end
    on("client")
    local cool0, pw0 = cs._p["CooldownRunning?"], cs._p["PoweredOn?"]
    if not opts.keep_state then
        cs._p["CooldownRunning?"], cs._p["PoweredOn?"] = hs._p["CooldownRunning?"], hs._p["PoweredOn?"]
    end
    if opts.copy_runs ~= false then cs:OnInteractBuildable(presser_client) end
    if cs._p["CooldownRunning?"] ~= cool0 then cs["OnRep_CooldownRunning?"](cs) end
    if cs._p["PoweredOn?"] ~= pw0 then cs["OnRep_PoweredOn?"](cs) end
    if not opts.go_first then deliver(msgs) end
    return msgs
end

-- ------------------------------------------------------------ 1. hooks, join snapshot, lights and remaining time
tick("host", host_mod)
tick("client", client_mod)
check(hooks.host[F.decon] and hooks.host[F.cooldown] and hooks.host[F.on] and hooks.host[F.off] and not hooks.host[F.press]
    and not hooks.host[F.exec], "host: DecontaminatePlayer / Event_Cooldown / On / Off hooked")
check(hooks.client[F.decon] and hooks.client[F.press] and hooks.client[F.exec] and not hooks.client[F.on],
    "client: DecontaminatePlayer / OnInteractBuildable / OnExecuteInteract hooked")
check(#fake_notes.OWN_CLASSES == 0, "host: the game's notes of the shower stay relayed (no sdc_notes OWN_CLASSES entry)")
Sc.client.acked = true
ticks(2, 0.5)
ticks(8, 0.5)
local q = take("SHWRQ")
check(#q == 1, "client: asks for the showers after joining (SHWRQ)")
deliver(q)
local snap = take("SHWR")
check(#snap >= 1 and snap[#snap].msg:find("|1|0,0,0 1 0 0.0 g;5000,0,0 1 1 " .. string.format("%.1f", timers[hB].Event_Cooldown - T)
    .. " o", 1, true) ~= nil and snap[#snap].msg:find("SDC1|SHWR|s|", 1, true) == 1,
    "host: stamped snapshot with power, cooldown, remaining and lights: " .. tostring(snap[#snap] and snap[#snap].msg))
deliver(snap)
local known = client_mod._t.st.known
check(#known == 2, "client: two showers known")
local recB = rec_at(SB)
check(recB and math.abs((recB.cool_until - T) - (timers[hB].Event_Cooldown - T)) < 0.2,
    "client: the joiner gets B's remaining cooldown (" .. string.format("%.1f", recB and recB.cool_until - T or -1) .. " s)")
check(mat_of(cA) == "Red", "client: A's copy still red (PoweredOn? came before its BeginPlay binding)")
ticks(9)
check(mat_of(cA) == "Green" and mat_of(cB) == "Orange", "client: lights as on the host (A green, B orange)")
check(logged("lights Green here, as on the host") ~= nil, "client logs the light fix")
-- a copy whose own cooldown flag is off while the host's shower cools (re-created, a local write)
cB._p["CooldownRunning?"] = false; cB["OnRep_CooldownRunning?"](cB)
force_pass()
check(cB._p["CooldownRunning?"] == true and mat_of(cB) == "Orange", "client: B's flag and lights back to the host's cooldown")

-- ------------------------------------------------------------ 2. the client starts A (its copy runs: property before multicast)
host_pawn._p.__loc = { X = -30, Y = 40, Z = 95 }    -- the host stands in A too
client_on_host._p.__loc = IN_A
local rc0, rh0 = rad(client_on_host), rad(host_pawn)
T = T + 5
local msgs = press(hA, cA, client_on_host, client_pawn)
check(hA._p["CooldownRunning?"] and water_of(hA), "host: A started (cooldown, water)")
check(rad(client_on_host) == rc0 + 1, "host: the presser (client) decontaminated once (the game's own call)")
check(rad(host_pawn) == rh0 + 1, "host: the host standing in A decontaminated too, once")
check(rad(dead_body) == 0, "host: no dead player decontaminated")
check(rad(client_pawn) == 0, "client: no local radiation write (its copy took the cooldown branch)")
check(#msgs == 1 and msgs[1].msg:find("SDC1|SHWR|go|0,0,0 1 1 300.0 o|1", 1, true) == 1, "host: SHWR go to the presser with you=1")
check(on_screen(TEXT_COOL) == 0, "client: the copy's wrong cooldown note for its own start is off the screen")
check(water_of(cA) and cA._p["CooldownRunning?"] and mat_of(cA) == "Orange", "client: water on, cooldown, orange lights here")
check(logged("copy Buildable_DecontaminationShower_C_2146000001 ran OnInteractBuildable here for this player's press: cool") ~= nil,
    "client: debug line names the copy's branch and whose press")
ticks(10)   -- 2.5 s
check(water_of(cA), "client: water still runs within 3 s")
ticks(4)
check(not water_of(cA), "client: water off after the host's 3 s")
check(on_screen(TEXT_COOL) == 0, "client: no cooldown note came back")

-- ------------------------------------------------------------ 3. presses during the cooldown: the note at once, from the host's word
local hn0 = host_notes
local starts0 = host_mod.stats.starts
T = T + 3
clear_screen()
-- the copy runs nothing here (as in the 2026-11-13 client log): the note comes with the press itself
on("client"); fire("client", F.exec, param(cA), param(client_pawn), param(USE))
check(on_screen(TEXT_COOL) == 1 and screen[1].by == "mod", "client: the game's cooldown note at once on its own press (no copy run)")
press(hA, cA, client_on_host, client_pawn, { copy_runs = false })
check(host_notes == hn0 + 1 and host_mod.stats.starts == starts0, "host: refused (cooldown), no start")
check(#take("SHWR") == 0, "host: no SHWR for a refused press")
check(on_screen(TEXT_COOL) == 1, "client: still one note")
ticks(12)
clear_screen()
-- the copy does run, but belonged to another player here (sdc_ctx client mode): the module's note at the press
quiet = true
press(hA, cA, client_on_host, client_pawn)
quiet = false
check(on_screen(TEXT_COOL) == 1 and screen[1].by == "mod", "client: quieted copy -> the game's cooldown note shown at the press")
ticks(12)
clear_screen()
-- "Move" is not a use: nothing shown
on("client"); fire("client", F.exec, param(cA), param(client_pawn), param(MOVE))
check(#screen == 0, "client: Move / Pickup show no shower note")
-- the copy thinks it has no power (stale), the host's word: powered and cooling -> the host's answer instead
cA._p["PoweredOn?"] = false
press(hA, cA, client_on_host, client_pawn, { keep_state = true })
check(on_screen(TEXT_NOPOWER) == 0 and on_screen(TEXT_COOL) == 1, "client: the copy's wrong 'No power' replaced by the host's answer")
cA._p["PoweredOn?"] = true
ticks(12)
-- a note the player already had stays: another player's press raises the same text (not added again)
clear_screen()
on("client"); fire("client", F.exec, param(cA), param(client_pawn), param(USE))
T = T + 1
on("host"); hA._p.CurrentActor = host_pawn; hA:OnInteractBuildable(host_pawn)
on("client"); cA:OnInteractBuildable(host_copy)
check(on_screen(TEXT_COOL) == 1, "client: its own earlier note stays (the copy added none for the other's press)")
ticks(12)

-- ------------------------------------------------------------ 4. B's cooldown end, then the host presses B with the client in it
T = T + 200
on("host"); hB:Event_Cooldown()
local cmsg = take("SHWR")
check(#cmsg >= 1 and cmsg[#cmsg].msg:find("SDC1|SHWR|c|5000,0,0 1 0 0.0 g", 1, true) == 1, "host: cooldown over -> SHWR c")
deliver(take("SHWR")); deliver(cmsg)
on("client"); cB._p["CooldownRunning?"] = false; cB["OnRep_CooldownRunning?"](cB)
ticks(8)
deliver(take("SHWR"))   -- the periodic snapshot of these 200 s
client_on_host._p.__loc = { X = 5010, Y = 10, Z = 90 }
host_pawn._p.__loc = { X = 4990, Y = -5, Z = 95 }
dead_body._p.__loc = { X = 5000, Y = 0, Z = 90 }   -- a dead player lies in it
rc0, rh0 = rad(client_on_host), rad(host_pawn)
clear_screen()
msgs = press(hB, cB, host_pawn, host_copy)
check(rad(host_pawn) == rh0 + 1, "host: its own press decontaminates the host once (unchanged)")
check(rad(client_on_host) == rc0 + 1, "host: the client standing in the host's shower decontaminated too, once")
check(rad(dead_body) == 0, "host: the dead player in it gets nothing")
check(#msgs == 1 and msgs[1].msg:sub(-2) == "|0", "host: SHWR go with you=0")
check(water_of(cB) and mat_of(cB) == "Orange", "client: the host's start shows water and orange lights here")
check(#screen == 0, "client: the copy's note for another player's press is off this screen")
check(logged("another player's press") ~= nil, "client logs the bystander take-off")
ticks(14)
check(not water_of(cB), "client: the host's water stops here after 3 s")

-- ------------------------------------------------------------ 5. SHWR go before the bunch; the flag set by go itself
on("host"); hA:Event_Cooldown()
deliver(take("SHWR"))
on("client"); cA._p["CooldownRunning?"] = false; cA["OnRep_CooldownRunning?"](cA)
ticks(8)
client_on_host._p.__loc = OUT_A
host_pawn._p.__loc = { X = 200, Y = 0, Z = 90 }   -- the host next to A, outside the booth
rc0, rh0 = rad(client_on_host), rad(host_pawn)
on("host"); hA._p.CurrentActor = client_on_host; hA:OnInteractBuildable(client_on_host)
deliver(take("SHWR"))
check(cA._p["CooldownRunning?"] == true and mat_of(cA) == "Orange" and water_of(cA),
    "client: the go alone (no replication yet) sets the copy's cooldown flag, orange lights and water")
check(rad(client_on_host) == rc0, "host: a presser outside the box gets nothing (as in the game)")
check(rad(host_pawn) == rh0, "host: a player next to the booth, outside it, gets nothing")
ticks(14)
on("host"); hA:Event_Cooldown()
deliver(take("SHWR"))
on("client"); cA._p["CooldownRunning?"] = false; cA["OnRep_CooldownRunning?"](cA)
ticks(8)
clear_screen()
press(hA, cA, client_on_host, client_pawn, { go_first = true })
check(on_screen(TEXT_COOL) == 0 and water_of(cA), "client: go first, then the bunch: note off, water on")
ticks(14)

-- ------------------------------------------------------------ 6. the host's word "ready" was wrong: the held note shown after all
-- (the client missed A's start: its word still says ready)
on("host"); hA._p.CurrentActor = client_on_host
local ra = rec_at(SA)
ra.cool_until, ra.changed = 0, T - 10
clear_screen()
press(hA, cA, client_on_host, client_pawn, { keep_state = true })
check(on_screen(TEXT_COOL) == 0, "client: the copy's refusal held back (the host's word: ready)")
check(#take("SHWR") == 0, "host: refused, no go")
ticks(11)
check(on_screen(TEXT_COOL) == 1, "client: no start came within 2.5 s -> the held cooldown note shown after all")
ticks(4)

-- ------------------------------------------------------------ 6b. no word from the host yet: the race note stays until its go
clear_screen()
take()
local SD = { X = 12000, Y = 0, Z = 0 }
on("host")
local hD = shower("host", "Buildable_DecontaminationShower_C_2147000004", SD, true, true)
local cD = shower("client", "Buildable_DecontaminationShower_C_2146000004", SD, true, true)
check(rec_at(SD) == nil, "client: nothing known about the new shower")
on("client"); fire("client", F.exec, param(cD), param(client_pawn), param(USE))
check(#screen == 0, "client: unknown shower - nothing shown at the press")
on("host"); hD._p.CurrentActor = client_on_host; hD:OnInteractBuildable(client_on_host)
local dmsg = take("SHWR")
on("client")
cD._p["CooldownRunning?"] = true
cD:OnInteractBuildable(client_pawn)
cD["OnRep_CooldownRunning?"](cD)
check(on_screen(TEXT_COOL) == 1, "client: the copy's race note stays for now")
deliver(dmsg)
check(on_screen(TEXT_COOL) == 0 and water_of(cD), "client: the host's go for this press takes it off, water on")
ticks(14)
hD._valid = false

-- ------------------------------------------------------------ 7. power off on the host; GRACE; a copy that missed it
on("host"); hB["Power Off"](hB)
local pmsg = take("SHWR")
check(#pmsg == 1 and pmsg[1].msg:find(" 0 1 ", 1, true) ~= nil and pmsg[1].msg:sub(-2) == " r",
    "host: power off -> SHWR c (no power, red)")
deliver(pmsg)
force_pass()
check(cB._p["PoweredOn?"] == true, "client: within GRACE after the change the copy is left to the replication")
ticks(16)   -- GRACE 1.5 s + a pass every 2 s
check(cB._p["PoweredOn?"] == false and mat_of(cB) == "Red", "client: copy powered off (the game's Power Off), red as on the host")
check(logged("has no power here, as on the host") ~= nil, "client logs the power fix")
clear_screen()
on("client"); fire("client", F.exec, param(cB), param(client_pawn), param(USE))
check(on_screen(TEXT_NOPOWER) == 1, "client: 'No power' at once on its own press")
press(hB, cB, client_on_host, client_pawn, { copy_runs = false })
ticks(12)

-- ------------------------------------------------------------ 8. a copy that started itself here (wrong state), the host refused
clear_screen()
local cC = shower("client", "Buildable_DecontaminationShower_C_2146000003", SC, true, true)
on("host")
local hC = shower("host", "Buildable_DecontaminationShower_C_2147000003", SC, false, true)
deliver({ { to = "client", msg = net.encode("SHWR", "c", "9000,0,0 0 0 0 r") } })
on("client")
local u0 = client_mod.stats.undone
client_pawn._p.__loc = { X = 9000, Y = 10, Z = 90 }
local crad = client_pawn._p.RadiationComponent
crad._p.CurrentRadiation = 35
client_pawn._p.MedicalComponent._p["RadiationSickness?"] = true
client_on_host._p.RadiationComponent._p.CurrentRadiation = 35
on("host"); client_on_host._p.MedicalComponent._p["RadiationSickness?"] = true
take()
hC._p.CurrentActor = client_on_host; hC:OnInteractBuildable(client_on_host)
check(#take("SHWR") == 0, "host: no power, no start")
on("client"); cC:OnInteractBuildable(client_pawn)
check(water_of(cC) and crad._p.CurrentRadiation == 100, "client: the copy started itself here (its state was wrong), wrote the radiation")
local rr = take("SHWRR")
check(#rr == 1, "client: asks the host for its radiation values (SHWRR)")
deliver(rr)
local rv = take("SHWRV")
check(#rv == 1 and rv[1].msg == "SDC1|SHWRV|35.000|1", "host: its values of that player (SHWRV): " .. tostring(rv[1] and rv[1].msg))
deliver(rv)
check(crad._p.CurrentRadiation == 35 and client_pawn._p.MedicalComponent._p["RadiationSickness?"] == true
    and client_pawn._p.MedicalComponent._p.__onrep == 1 and client_pawn._p.InGameUI._p.__rad == 35,
    "client: radiation, sickness (OnRep) and the HUD as on the host again")
ticks(11)
check(not water_of(cC) and cC._p["CooldownRunning?"] == false and client_mod.stats.undone == u0 + 1,
    "client: no start from the host within 2.5 s -> water off, no cooldown")
check(timers[cC] == nil or timers[cC].Event_Cooldown == nil, "client: the copy's own cooldown timer cleared")
ticks(4)
check(cC._p["PoweredOn?"] == false, "client: the pass took its power off too")
-- the same for another player's press (an observer's copy)
cC._p["PoweredOn?"] = true
on("client"); cC:OnInteractBuildable(host_copy)
check(water_of(cC), "client: the observer's copy started itself for the host's press")
ticks(11)
check(not water_of(cC) and cC._p["CooldownRunning?"] == false and client_mod.stats.undone == u0 + 2,
    "client: an observer's unconfirmed start undone too")
ticks(4)

-- ------------------------------------------------------------ 9. snapshots: stamps, chunks, gone showers
take()
on("host")
local many = {}
for i = 1, 60 do many[i] = shower("host", "Buildable_DecontaminationShower_C_21470001" .. string.format("%02d", i),
    { X = 20000 + i * 1000, Y = 0, Z = 0 }, true, true) end
deliver({ { to = "client", msg = net.encode("SHWR", "c", "77000,5000,0 1 1 120.0 o") } })   -- a shower the host no longer has
check(rec_at({ X = 77000, Y = 5000 }) ~= nil, "client: a shower known from a change message")
T = T + 31
tick("host", host_mod)
local chunks = take("SHWR")
check(#chunks >= 2, "host: a big snapshot goes in chunks (" .. #chunks .. ")")
deliver({ chunks[1] })
check(rec_at({ X = 77000, Y = 5000 }) ~= nil, "client: kept while the snapshot is incomplete")
deliver({ table.unpack(chunks, 2) })
check(rec_at({ X = 77000, Y = 5000 }) == nil, "client: a shower the whole snapshot left out is dropped")
check(#client_mod._t.st.known == 63, "client: every shower of every chunk kept (" .. #client_mod._t.st.known .. ")")
for _, s in ipairs(many) do s._valid = false end
hC._valid = false
T = T + 31
tick("host", host_mod)
deliver(take("SHWR"))
check(#client_mod._t.st.known == 2, "client: picked-up showers gone with the next snapshot")
-- an empty world: one empty chunk drops everything
hA._valid, hB._valid = false, false
T = T + 31
tick("host", host_mod)
local empty = take("SHWR")
check(#empty == 1 and empty[1].msg:find("|1|$") ~= nil, "host: an empty snapshot is still sent")
deliver(empty)
check(#client_mod._t.st.known == 0, "client: nothing kept after an empty snapshot")
hA._valid, hB._valid = true, true

-- ------------------------------------------------------------ 10. expiry, off, malformed
deliver({ { to = "client", msg = net.encode("SHWR", "c", "0,0,0 1 0 0.0 g") } })
T = T + 80
tick("client", client_mod)
force_pass()
check(client_mod.status_line():find("known=0", 1, true) ~= nil, "client: states no message refreshed for 75 s are forgotten")
cfg.set("world_build_shower", false)
on("host"); hA._p["CooldownRunning?"] = false
hA._p.CurrentActor = host_pawn; hA:OnInteractBuildable(host_pawn)
check(#take() == 0, "off: the host sends nothing on a start")
cfg.set("world_build_shower", true)
on("client")
ch.SHWR({ "c", "bad;1,2,3 1 1 x q" }, client_pc)
ch.SHWR({ "go", "" }, client_pc)
ch.SHWR({ "s", "x", "1", "" }, client_pc)
ch.SHWR({}, client_pc)
ch.SHWRV({ "abc" }, client_pc)
check(#client_mod._t.st.known == 0, "malformed entries ignored")
local bad = setmetatable({}, { __index = function() error("boom") end })
check(pcall(hooks.host[F.decon], bad) and pcall(hooks.client[F.press], bad, bad) and pcall(hooks.client[F.exec], bad, bad, bad),
    "broken hook arguments are caught")
check(host_mod.status_line():find("shower: on=true", 1, true) ~= nil, "status line")

-- ------------------------------------------------------------ 11. sdc_net: the shower's messages never wait
check(net.NOW.SHWR and net.NOW.SHWRQ and net.NOW.SHWRR and net.NOW.SHWRV, "sdc_net: SHWR / SHWRQ / SHWRR / SHWRV in the NOW class")

-- ------------------------------------------------------------ 12. a copy's own start the host confirmed stays; radiation asked once per RAD_GAP
take(); clear_screen()
local SE, SH = { X = 15000, Y = 0, Z = 0 }, { X = 17000, Y = 0, Z = 0 }
on("host")
local hE = shower("host", "Buildable_DecontaminationShower_C_2147000005", SE, true, true)
local cE = shower("client", "Buildable_DecontaminationShower_C_2146000005", SE, true, true)
local cH = shower("client", "Buildable_DecontaminationShower_C_2146000006", SH, true, true)
deliver({ { to = "client", msg = net.encode("SHWR", "c", "15000,0,0 1 0 0.0 g") } })
ticks(8)
take("SHWRR")
local u1 = client_mod.stats.undone
local l1 = #lines
-- the multicast here before the cooldown flag: the copy starts itself, the host confirms (go)
press(hE, cE, client_on_host, client_pawn, { keep_state = true })
check(water_of(cE) and cE._p["CooldownRunning?"] == true, "client: the copy started itself, the host's go confirmed it")
-- another copy starts itself a moment later (an observer's): no second radiation request so soon
on("client"); cH:OnInteractBuildable(host_copy)
check(#take("SHWRR") == 1, "client: one radiation request for two local starts within 2 s (RAD_GAP)")
ticks(11)   -- 2.75 s
check(client_mod.stats.undone == u1 + 1 and water_of(cE) and cE._p["CooldownRunning?"] == true,
    "client: the confirmed start is not rolled back after 2.5 s (only the unconfirmed one: " ..
    (client_mod.stats.undone - u1) .. ")")
local rolled = false
for i = l1, #lines do if lines[i]:find("started here but not on the host", 1, true) and lines[i]:find("15000", 1, true) then rolled = true end end
check(not rolled, "client: no roll-back line for the confirmed shower")
cH._p["CooldownRunning?"] = false
on("client"); cH:OnInteractBuildable(host_copy)
check(#take("SHWRR") == 1, "client: after RAD_GAP the next local start asks again")
ticks(14)

-- ------------------------------------------------------------ 13. F on something else / by someone else: no shower note
clear_screen()
local door = new_obj("Buildable_WoodenDoor_C", "Buildable_WoodenDoor_C_2146000099", { __loc = { X = 15080, Y = 0, Z = 0 } }, {}, "client")
on("client"); fire("client", F.exec, param(door), param(client_pawn), param(USE))
check(#screen == 0, "client: F on a door 80 cm from a cooling shower shows no shower note")
fire("client", F.exec, param(cE), param(host_copy), param(USE))
check(#screen == 0, "client: another player's press on this machine shows no note here")
fire("client", F.exec, param(cE), param(client_pawn), param(USE))
check(on_screen(TEXT_COOL) == 1, "client: its own F on that shower does (the host's word: cooling)")
ticks(12)

-- ------------------------------------------------------------ 14. a new own press after the host's go: its refusal is not the race
clear_screen(); take()
local SG = { X = 19000, Y = 0, Z = 0 }
on("host")
local hG = shower("host", "Buildable_DecontaminationShower_C_2147000007", SG, true, true)
local cG = shower("client", "Buildable_DecontaminationShower_C_2146000007", SG, true, true)
deliver({ { to = "client", msg = net.encode("SHWR", "c", "19000,0,0 1 0 0.0 g") } })
ticks(8)
press(hG, cG, client_on_host, client_pawn, { copy_runs = false })   -- started; its multicast never comes here
check(water_of(cG), "client: started by the host's go")
T = T + 0.5
clear_screen()
press(hG, cG, client_on_host, client_pawn)                         -- pressed again: the host refuses (cooldown)
check(on_screen(TEXT_COOL) == 1, "client: the copy's cooldown note for the new press stays (not taken for the start's)")
ticks(14)

-- ------------------------------------------------------------ 15. a snapshot keeps a shower whose water runs here (to stop it)
take()
local SF = { X = 21000, Y = 0, Z = 0 }
on("host")
local hF = shower("host", "Buildable_DecontaminationShower_C_2147000008", SF, true, true)
local cF = shower("client", "Buildable_DecontaminationShower_C_2146000008", SF, true, true)
on("host"); hF._p.CurrentActor = host_pawn; hF:OnInteractBuildable(host_pawn)
deliver(take("SHWR"))
check(water_of(cF), "client: the host's water runs on F here")
T = T + 0.5
deliver({ { to = "client", msg = net.encode("SHWR", "s", 999, 1, "") } })   -- F picked up on the host meanwhile
check(rec_at(SF) ~= nil and rec_at(SE) == nil, "client: the snapshot dropped the others but kept F while its water runs")
ticks(14)
check(not water_of(cF), "client: F's water still stops after 3 s")

print = real_print
for _, l in ipairs(lines) do if l:find("shower:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
