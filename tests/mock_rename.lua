-- Mock harness for sdc_rename (a client renames a placed storage container;
-- every machine shows the host's name). Two instances of the module run side
-- by side, one per machine, each with its own world of objects; messages go
-- through sdc_net's real encode / decode.
-- usage: lua mock_rename.lua <scripts dir>
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
local machine = "host"        -- whose world the engine calls see
local worlds = { host = {}, client = {} }
local Obj = {}
local next_addr = 4096

local function new_obj(cls, short, props, methods, bases, where)
    next_addr = next_addr + 16
    local o = { _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _addr = next_addr, _valid = true,
                _bases = bases or {} }
    o._bases[cls] = true
    setmetatable(o, Obj)
    local w = worlds[where or machine]
    w[#w + 1] = o
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
function Obj:GetOwner() return self._p.__owner end
function Obj:IsA(c) return c ~= nil and self._bases[c._short] == true end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:IsInViewport() return self._p.__inv == true end

local function param(v) return { _v = v, get = function(s) return s._v end, set = function(s, x) s._v = x end } end

-- ------------------------------------------------------------ UE4SS globals
local CONT = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local F_OVERRIDE = CONT .. ":OverrideBuildName"
local F_SERVER = CONT .. ":OnServerExecuteInteract"
local class_loaded = false
local class_obj = new_obj("BlueprintGeneratedClass", "BuildableMaster_Container_C", {}, {}, nil, "host")
table.remove(worlds.host)   -- the class object is not an instance in any world

local hooks = { host = {}, client = {} }   -- [machine][path] = callback
local hook_machine = "host"
local registered = {}
function RegisterHook(path, fn) hooks[hook_machine][path] = fn; registered[#registered + 1] = hook_machine .. " " .. path; return 1, 2 end
function FindAllOf(cls)
    local out = {}
    for _, o in ipairs(worlds[machine]) do if o._valid and o._bases[cls] then out[#out + 1] = o end end
    return #out > 0 and out or nil
end
function FindFirstOf(cls) local l = FindAllOf(cls); return l and l[1] or nil end
function StaticFindObject(path)
    if path == CONT then return class_loaded and class_obj or nil end
    return nil
end
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
local function mark() return #lines + 1 end
local function logged(pat, from)
    for i = from or 1, #lines do if lines[i]:find(pat, 1, true) then return lines[i] end end
    return nil
end

local cfg = require("sdc_config")
cfg.load(os.tmpname())
local ue = require("sdc_ue")
ue.every = function() end
local net = require("sdc_net")

-- ------------------------------------------------------------ the two machines
local hooked_calls = { host = 0, client = 0 }
local function fire(path, ...)
    local cb = hooks[machine][path]
    if not cb then return nil end
    hooked_calls[machine] = hooked_calls[machine] + 1
    return cb(...)
end

local override_calls = { host = 0, client = 0 }
local function box_methods()
    return {
        -- the game's OverrideBuildName (ContainerName = Name); the post-hook fires inside, as in UE4SS
        OverrideBuildName = function(self, name)
            override_calls[machine] = override_calls[machine] + 1
            self._p.ContainerName = name
            fire(F_OVERRIDE, param(self), param(name))
        end,
    }
end
local BOX_BASES = function() return { BuildableMaster_Container_C = true, Buildable_MASTER_C = true, Actor = true } end
local function guids(list)
    return { ForEach = function(_, fn) for i, g in ipairs(list) do fn(i, param(g)) end end }
end
local function new_box(where, cls, short, loc, uid, name, da)
    local comp = new_obj("BP_JigComponent_C", short .. ".BP_JigMultiplayer", {
        MainContainersIDs = guids(uid and { uid } or {}),
    }, {}, nil, where)
    return new_obj(cls, short, { __loc = loc, ContainerName = name, BP_JigMultiplayer = comp, PickupDataAsset = da },
        box_methods(), BOX_BASES(), where)
end

local function hud_methods(calls)
    return {
        ShowChangeObjectNameWidget = function(self, show, ref)
            calls[#calls + 1] = { show = show, ref = ref }
            if show then
                self._p.ChangeNameWidget = new_obj("BuildableRenameObject_C", "BuildableRenameObject_C_" .. #calls,
                    { __inv = true, ActorRef = ref })
            else
                local w = self._p.ChangeNameWidget
                if w then w._p.__inv = false end
            end
        end,
    }
end

-- host's world
machine = "host"
local da_crate = new_obj("JigsawItem_DataAsset_C", "DA_StorageCrate", { name = "Storage Crate" })
local da_cupboard = new_obj("JigsawItem_DataAsset_C", "DA_ClothingCupboard", { name = "Clothing Cupboard" })
local host_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local host_hud_calls = {}
local host_hud = new_obj("HUD_Game_C", "HUD_Game_C_0", {}, hud_methods(host_hud_calls))
local host_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_0", { Player = host_lp }, {
    GetHUD = function() return host_hud end, IsLocalController = function() return true end,
}, { PlayerController = true })
local host_pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_0", { Controller = host_pc, __loc = { X = 0, Y = 0, Z = 0 } })
host_pc._p.Pawn = host_pawn
local conn = new_obj("IpConnection", "IpConnection_1", {})
local rpc_h = new_obj("BP_PlayerController_C", "BP_PlayerController_C_7", { Player = conn, NetConnection = conn }, {
    IsLocalController = function() return false end,
}, { PlayerController = true })
local rpawn_h = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Controller = rpc_h, __loc = { X = 150, Y = 200, Z = 300 } })
rpc_h._p.Pawn = rpawn_h
local U1 = { A = 11, B = 22, C = -33, D = 44 }
local hbox1 = new_box("host", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147400001",
    { X = 100, Y = 200, Z = 300 }, U1, "Storage Crate", da_crate)
local hbox2 = new_box("host", "Buildable_ClothingCupboard_C", "Buildable_ClothingCupboard_C_2147400002",
    { X = 500, Y = 0, Z = 0 }, { A = 2, B = 2, C = 2, D = 2 }, "Guns", da_cupboard)   -- loaded from the save
local hbox3 = new_box("host", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147400003",
    { X = 1000, Y = 0, Z = 0 }, { A = 3, B = 3, C = 3, D = 3 }, "Storage Crate", da_crate)
local hbox4 = new_box("host", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147400004",
    { X = 3000, Y = 0, Z = 0 }, { A = 4, B = 4, C = 4, D = 4 }, "Storage Crate", da_crate)   -- never renamed
local hbox5 = new_box("host", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147400005",
    { X = 2600, Y = 0, Z = 0 }, { A = 5, B = 5, C = 5, D = 5 }, "Storage Crate", da_crate)

-- client's world: the same containers, other object names and addresses
machine = "client"
local cda_crate = new_obj("JigsawItem_DataAsset_C", "DA_StorageCrate", { name = "Ящик" })
local cda_cupboard = new_obj("JigsawItem_DataAsset_C", "DA_ClothingCupboard", { name = "Шкаф" })
local client_lp = new_obj("LocalPlayer", "LocalPlayer_0", {})
local client_hud_calls = {}
local client_hud = new_obj("HUD_Game_C", "HUD_Game_C_1", {}, hud_methods(client_hud_calls))
local client_pc = new_obj("BP_PlayerController_C", "BP_PlayerController_C_1", { Player = client_lp }, {
    GetHUD = function() return client_hud end, IsLocalController = function() return true end,
}, { PlayerController = true })
local client_pawn = new_obj("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_1", { Controller = client_pc })
client_pc._p.Pawn = client_pawn
local cbox1 = new_box("client", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147300011",
    { X = 100.4, Y = 199.6, Z = 300 }, U1, "Ящик", cda_crate)
local cbox2 = new_box("client", "Buildable_ClothingCupboard_C", "Buildable_ClothingCupboard_C_2147300012",
    { X = 500, Y = 0, Z = 0 }, nil, "Шкаф", cda_cupboard)   -- its UIDs did not replicate yet
-- moved on the host (same UID, another place here)
local cbox5 = new_box("client", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147300015",
    { X = 2000, Y = 0, Z = 0 }, { A = 5, B = 5, C = 5, D = 5 }, "Ящик", cda_crate)
-- a crate picked up and placed again where hbox4 stood: another UID
local cbox4 = new_box("client", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147300014",
    { X = 3000, Y = 0, Z = 0 }, { A = 9, B = 9, C = 9, D = 9 }, "Ящик", cda_crate)

-- ------------------------------------------------------------ two module instances
local function on(m) machine = m; ue.forget_world() end

local Sh = { role = "host", remote_pcs = { rpc_h }, map = "LongdownValley" }
-- (the client's join handshake completes in section 7)
local Sc = { role = "client", map = "LongdownValley", remote_pcs = {}, client = { acked = false, pc_key = "BP_PlayerController_C_1" } }
local KINDS = { "RNOPEN", "RNREQ", "RNAME", "RNAMEQ" }

on("host")
local host_mod = require("sdc_rename")
host_mod.install(Sh)
local host_handlers = {}
for _, k in ipairs(KINDS) do host_handlers[k] = net.handlers[k] end
package.loaded["sdc_rename"] = nil
on("client")
local client_mod = require("sdc_rename")
client_mod.install(Sc)
local client_handlers = {}
for _, k in ipairs(KINDS) do client_handlers[k] = net.handlers[k] end
check(host_mod ~= client_mod, "two independent module instances")
for _, k in ipairs(KINDS) do check(host_handlers[k] ~= nil and client_handlers[k] ~= nil, "handler for " .. k) end

-- the wire: real encode / decode, delivered by hand
local wire = {}   -- { from =, to =, msg = }
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
        if m.to == "host" then
            on("host"); host_handlers[kind](fields, rpc_h)
        else
            on("client"); client_handlers[kind](fields, client_pc)
        end
    end
end
local function tick(m, mod) on(m); hook_machine = m; mod.tick() end

-- ------------------------------------------------------------ 1. hooks
tick("host", host_mod)
check(next(hooks.host) == nil, "no hook while the container class is not loaded")
class_loaded = true
T = T + 3
tick("host", host_mod)
check(hooks.host[F_OVERRIDE] ~= nil and hooks.host[F_SERVER] ~= nil, "host: OverrideBuildName + OnServerExecuteInteract hooked")
tick("client", client_mod)
check(hooks.client[F_OVERRIDE] ~= nil, "client: OverrideBuildName hooked")
check(hooks.client[F_SERVER] == nil, "client: no OnServerExecuteInteract hook (it never runs there)")
local nreg = #registered
T = T + 3
tick("host", host_mod); tick("client", client_mod)
check(#registered == nreg, "each hook registered once")

-- ------------------------------------------------------------ 2. Rename chosen by the client (host side)
local OPT2 = { TagName = FName("Jig.InteractOptions.Option2") }
local OPT1 = { TagName = FName("Jig.InteractOptions.Option1") }
on("host")
local r = fire(F_SERVER, param(hbox1), param(OPT1), param(rpawn_h), param({}))
check(r == nil and #take("RNOPEN") == 0, "Option1 (move): no rename window sent")
fire(F_SERVER, param(hbox1), param(OPT2), param(host_pawn), param({}))
check(#take("RNOPEN") == 0, "the host's own Rename: nothing sent (the game's window on its screen)")
fire(F_SERVER, param(hbox1), param(OPT2), param(rpawn_h), param({}))
local opens = take("RNOPEN")
check(#opens == 1 and opens[1].to == rpc_h, "client's Rename: RNOPEN to that client")
check(opens[1].msg == "SDC1|RNOPEN|Buildable_StorageCrate_C|100,200,300|11:22:-33:44", "RNOPEN names class, place, UID: " .. opens[1].msg)
check(#host_hud_calls == 0, "host HUD untouched (the scope sent the game's window nowhere)")

-- a window the host's HUD opened for that request (no scope) is closed
host_hud:ShowChangeObjectNameWidget(true, hbox1)
fire(F_SERVER, param(hbox1), param(OPT2), param(rpawn_h), param({}))
check(#host_hud_calls == 2 and host_hud_calls[2].show == false and host_hud_calls[2].ref == nil,
    "the host's stray rename window for the client's request is closed")
check(logged("closed here") ~= nil, "host logs the closed window")
-- a host window for another container stays
host_hud:ShowChangeObjectNameWidget(true, hbox3)
local nh = #host_hud_calls
fire(F_SERVER, param(hbox1), param(OPT2), param(rpawn_h), param({}))
check(#host_hud_calls == nh, "the host's own window for another container stays open")
host_hud:ShowChangeObjectNameWidget(false, nil)

-- ------------------------------------------------------------ 3. the window on the client
deliver(opens)
check(#client_hud_calls == 1 and client_hud_calls[1].show == true and client_hud_calls[1].ref == cbox1,
    "client: the game's ShowChangeObjectNameWidget(true, its own copy)")
check(logged("rename window for Buildable_StorageCrate_C_2147300011") ~= nil, "client logs the opened window")
deliver(take("RNOPEN"))   -- (the two repeats above)
check(#client_hud_calls == 1, "a second RNOPEN while the window is open: not opened again")
client_hud:ShowChangeObjectNameWidget(false, nil)
local m0 = mark()
on("client"); client_handlers.RNOPEN({ "Buildable_StorageCrate_C", "9000,9000,0", "" }, client_pc)
check(#client_hud_calls == 2 and logged("no such container", m0) ~= nil, "unknown container: no window, a warning")

-- ------------------------------------------------------------ 4. the client confirms a name
on("client")
m0 = mark()
cbox1:OverrideBuildName("My|Box 100%")   -- the window's Confirm
local reqs = take("RNREQ")
check(#reqs == 1 and reqs[1].to == "host", "client: its rename goes to the host (RNREQ)")
check(reqs[1].msg == "SDC1|RNREQ|Buildable_StorageCrate_C|100,200,300|11:22:-33:44|My%7CBox 100%25",
    "name escaped on the wire: " .. tostring(reqs[1] and reqs[1].msg))
check(logged("renamed here to 'My|Box 100%'", m0) ~= nil, "client logs its rename")
local ho = override_calls.host
deliver(reqs)
check(hbox1.ContainerName == "My|Box 100%", "host: its copy renamed (OverrideBuildName): " .. tostring(hbox1.ContainerName))
check(override_calls.host == ho + 1, "host: the game's OverrideBuildName ran once")
check(logged("renamed by BP_PlayerCharacter_C_7", m0) ~= nil, "host logs whose rename it applied")
local names = take("RNAME")
check(#names == 1 and names[1].to == rpc_h, "host: RNAME to every client, once (its own call does not echo)")
local co = override_calls.client
deliver(names)
check(override_calls.client == co, "client: already called that: not renamed again")
check(#take("RNREQ") == 0, "client: nothing echoed back")

-- control characters are not kept; the client's copy gets the same text as the host's
T = T + 1
on("client")
cbox1:OverrideBuildName("Tab\tName\n")
deliver(take("RNREQ"))
check(hbox1.ContainerName == "TabName", "host: control characters removed: " .. tostring(hbox1.ContainerName))
co = override_calls.client
deliver(take("RNAME"))
check(cbox1.ContainerName == "TabName" and override_calls.client == co + 1, "client: its copy shows the host's text")
check(#take("RNREQ") == 0, "client: applying the host's name sends nothing")

-- a long name is cut on a character boundary, and the client's copy gets the cut one back
local long = string.rep("Ящик", 30)   -- 120 characters
on("client")
cbox1:OverrideBuildName(long)
T = T + 1
deliver(take("RNREQ"))
local cut = string.rep("Ящик", 25)    -- 100 characters
check(hbox1.ContainerName == cut, "host: name cut to 100 characters")
deliver(take("RNAME"))
check(cbox1.ContainerName == cut, "client: its copy gets the host's (cut) name")
check(#take("RNREQ") == 0, "client: applying the host's name sends nothing")

-- ------------------------------------------------------------ 5. refused / unknown requests
T = T + 1
rpawn_h._p.__loc = { X = 90000, Y = 0, Z = 0 }   -- far away, and the window grant was used
on("client")
cbox1:OverrideBuildName("Far")
deliver(take("RNREQ"))
check(hbox1.ContainerName == cut, "host: a rename from far away without a window is refused")
local back = take("RNAME")
check(#back == 1 and back[1].to == rpc_h, "refused: the host's name goes back to that client only")
deliver(back)
check(cbox1.ContainerName == cut, "client: its copy shows the host's name again")
rpawn_h._p.__loc = { X = 150, Y = 200, Z = 300 }
T = T + 1
m0 = mark()
on("host"); host_handlers.RNREQ({ "Buildable_StorageCrate_C", "7000,0,0", "", "X" }, rpc_h)
check(logged("has no such container", m0) ~= nil and #take() == 0, "host: a container it does not have: nothing renamed")
T = T + 0.1
on("host"); host_handlers.RNREQ({ "Buildable_StorageCrate_C", "100,200,300", "11:22:-33:44", "Spam" }, rpc_h)
check(hbox1.ContainerName == cut, "host: a second request within 0.5 s is ignored")
-- a grant (window opened for it) is enough from farther than REACH
T = T + 1
rpawn_h._p.__loc = { X = 9000, Y = 0, Z = 0 }
on("host"); fire(F_SERVER, param(hbox1), param(OPT2), param(rpawn_h), param({}))
take("RNOPEN")
on("host"); host_handlers.RNREQ({ "Buildable_StorageCrate_C", "100,200,300", "11:22:-33:44", "Granted" }, rpc_h)
check(hbox1.ContainerName == "Granted", "host: the player it opened the window for may rename")
deliver(take("RNAME"))
check(cbox1.ContainerName == "Granted", "client: copy follows")
rpawn_h._p.__loc = { X = 150, Y = 200, Z = 300 }

-- ------------------------------------------------------------ 6. the host's own rename reaches the clients
on("host")
hbox3:OverrideBuildName("Ammo")   -- the host's window Confirm
local hn = take("RNAME")
check(#hn == 1 and hn[1].msg == "SDC1|RNAME|Buildable_StorageCrate_C|1000,0,0|3:3:3:3|Ammo", "host's rename: RNAME " .. tostring(hn[1] and hn[1].msg))
deliver(hn)
check(#take() == 0, "client: not here yet: kept, nothing sent")
-- its copy replicates in later
on("client")
local cbox3 = new_box("client", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147300013",
    { X = 1000, Y = 0, Z = 0 }, { A = 3, B = 3, C = 3, D = 3 }, "Ящик", cda_crate)
T = T + 3.5
tick("client", client_mod)
check(cbox3.ContainerName == "Ammo", "client: a copy that appears later gets the host's name")
check(#take("RNREQ") == 0, "client: that sends nothing")
-- relevance lost and back: a fresh copy with the default name gets it again
cbox3._valid = false
local cbox3b = new_box("client", "Buildable_StorageCrate_C", "Buildable_StorageCrate_C_2147300023",
    { X = 1000, Y = 0, Z = 0 }, { A = 3, B = 3, C = 3, D = 3 }, "Ящик", cda_crate)
T = T + 3.5
tick("client", client_mod)
check(cbox3b.ContainerName == "Ammo", "client: a new copy at that place gets the name again")
-- no clients: the host's rename sends nothing
Sh.remote_pcs = {}
on("host"); hbox3:OverrideBuildName("Ammo 2")
check(#take() == 0, "host alone: nothing sent")
Sh.remote_pcs = { rpc_h }
on("host"); hbox3:OverrideBuildName("Ammo")
take()

-- ------------------------------------------------------------ 7. join snapshot
package.loaded["sdc_rename"] = nil
on("client")
local fresh = require("sdc_rename")   -- the client of a new session (nothing known)
fresh.install(Sc)
for _, k in ipairs(KINDS) do client_handlers[k] = net.handlers[k] end
hooks.client = {}
Sc.client.acked = true
cbox2.ContainerName = "Шкаф"
tick("client", fresh)
check(hooks.client[F_OVERRIDE] ~= nil, "new session: hook in")
check(#take("RNAMEQ") == 0, "client: does not ask at once")
T = T + 3.5
tick("client", fresh)
local q = take("RNAMEQ")
check(#q == 1, "client: asks the host for the names after a few seconds (RNAMEQ)")
T = T + 3.5
tick("client", fresh)
check(#take("RNAMEQ") == 0, "client: asks once per world")
deliver(q)
local snap = take("RNAME")
local sent = {}
for _, m in ipairs(snap) do sent[#sent + 1] = m.msg end
local all = table.concat(sent, " ; ")
check(#snap == 3, "host: 3 renamed containers sent: " .. all)
check(all:find("|Guns", 1, true) ~= nil, "the name loaded from the save is sent")
check(all:find("3000,0,0", 1, true) == nil and all:find("2600,0,0", 1, true) == nil, "default-named containers are not sent")
deliver(snap)
check(cbox2.ContainerName == "Guns", "client: copy without UID found by class and place")
check(cbox1.ContainerName == "Granted" and cbox3b.ContainerName == "Ammo", "client: copies already named stay")
-- a crate picked up and placed again at a named place (another UID) keeps its own name
on("client"); client_handlers.RNAME({ "Buildable_StorageCrate_C", "3000,0,0", "4:4:4:4", "Old" }, client_pc)
check(cbox4.ContainerName == "Ящик", "client: another crate (other UID) at a named place keeps its name")
T = T + 3.5
tick("client", fresh)
check(cbox4.ContainerName == "Ящик", "client: ... also in the later pass")

-- moved container: matched by its UID
on("host"); hbox5:OverrideBuildName("Moved")
local mv = take("RNAME")
on("client"); deliver(mv)
check(cbox5.ContainerName == "Moved", "client: a container standing elsewhere here is found by its UID")

-- ------------------------------------------------------------ 8. config off
cfg.set("world_rename", false)
on("host"); fire(F_SERVER, param(hbox1), param(OPT2), param(rpawn_h), param({}))
check(#take() == 0, "off: no rename window sent")
T = T + 1
m0 = mark()
on("host"); host_handlers.RNREQ({ "Buildable_StorageCrate_C", "100,200,300", "11:22:-33:44", "Off" }, rpc_h)
check(hbox1.ContainerName == "Granted" and logged("world_rename or world_sync off", m0) ~= nil, "off: the host ignores a rename")
on("client"); cbox1:OverrideBuildName("Local")
check(#take() == 0, "off: the client sends nothing")
cfg.set("world_rename", true)
cfg.set("world_sync", false)
on("host"); fire(F_SERVER, param(hbox1), param(OPT2), param(rpawn_h), param({}))
check(#take() == 0, "world_sync off: no rename window sent")
cfg.set("world_sync", true)

-- ------------------------------------------------------------ 9. robustness
on("host")
local okb = pcall(hooks.host[F_SERVER], param(nil), nil, nil)
check(okb, "a broken hook argument is caught")
local bad = setmetatable({}, { __index = function() error("boom") end })
check(pcall(hooks.host[F_OVERRIDE], bad) and hooks.host[F_OVERRIDE](param(hbox4)) == nil, "hook callbacks never throw and return nothing")
take()
on("client"); client_handlers.RNAME({ "Buildable_StorageCrate_C", "bad", "", "x" }, client_pc)
client_handlers.RNAME({}, client_pc)
client_handlers.RNOPEN({}, client_pc)
on("host"); host_handlers.RNREQ({}, rpc_h)
check(#take() == 0, "malformed messages are ignored")
check(host_mod.unesc(host_mod.esc("a|b%c%7C")) == "a|b%c%7C", "escape round trip")
check(host_mod.clean("x\r\ny\t") == "xy", "control characters removed")

-- reset (world change) forgets the names
check(fresh.status_line():find("known=0", 1, true) == nil, "status line: " .. fresh.status_line())
fresh.reset("test")
check(fresh.status_line():find("known=0", 1, true) ~= nil, "reset forgets the kept names")
check(host_mod.status_line():find("rename: on=true", 1, true) ~= nil, "host status line")

print = real_print
for _, l in ipairs(lines) do if l:find("rename:") or l:find("FAIL") then io.write(l, string.char(10)) end end
print(nchecks .. " checks, " .. (fails == 0 and "ALL OK" or (fails .. " FAILED")))
