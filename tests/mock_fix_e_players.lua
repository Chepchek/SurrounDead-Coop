-- Mock harness for the 2026-11-13 critic fixes of group E (players):
--   A1 sdc_sync's AI ghost cleanup tells destroyed ghosts apart with
--      sdc_sweepguard.live (KismetSystemLibrary.IsValid through its UFunction)
--   A2 sdc_localinit: "Quit to main menu" works with unload_menu_level = false
--      (menu_level_tick never called); the LoadStreamLevel hook is retried
--   A3 sdc_ctx: a carried-over body is dropped when its address is reused
--   A4 per-character / per-player tables are pruned (sync, appearance,
--      pawnstate, playermarks)
--   B1/B2 no sound subscriber and no per-shot lines just because debug is on
--   B3 a host nobody is connected to skips pawnstate / playermarks work
--   B5 sdc_players does not re-register BP_PlayerMarker_C markers
-- Real modules with stubbed engine access (sdc_ue / sdc_log / sdc_config /
-- sdc_net and the modules each one requires).
-- usage: lua mock_fix_e_players.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, passed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what) end
end

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

-- ------------------------------------------------------------ fake objects
local next_addr = 0x1000
local Obj = {}
Obj.__index = function(t, k)
    local m = rawget(Obj, k)
    if m ~= nil then return m end
    local mm = rawget(t, "_m")
    if mm and mm[k] ~= nil then return mm[k] end
    return nil
end
local classes = {}
local function class_of(cls)
    local c = classes[cls]
    if not c then
        next_addr = next_addr + 16
        c = setmetatable({ _cls = "Class", _name = cls, _addr = next_addr, _valid = true, _p = {}, _m = {} }, Obj)
        classes[cls] = c
    end
    return c
end
local function new(cls, name, props, methods)
    next_addr = next_addr + 16
    return setmetatable({ _cls = cls, _name = name, _addr = next_addr, _valid = true, _p = props or {}, _m = methods or {} }, Obj)
end
function Obj:GetAddress() return self._addr end
function Obj:GetClass() return class_of(self._cls) end
function Obj:IsValid() return self._valid end
function Obj:GetOuter() return nil end
function Obj:GetOwner() return self._p.__owner end
function Obj:IsLocallyControlled() return self._p.__local == true end
function Obj:K2_DestroyActor() self._destroyed = (self._destroyed or 0) + 1 end
function Obj:GetPlayerId() return self._p.PlayerId end
local function param(v, counter)
    return { get = function() if counter then counter.n = counter.n + 1 end return v end, set = function(_, x) v = x end,
             val = function() return v end }
end

function FName(s) return { _fname = s } end
function FText(s) return { _text = s } end
function NotifyOnNewObject() end
local bp_hooks = {}   -- RegisterHook (Blueprint hooks): [path] = callback
function RegisterHook(path, cb) bp_hooks[path] = cb; return 1, 2 end

-- ------------------------------------------------------------ stub modules
local lines = {}
local function count_lines(pat)
    local n = 0
    for _, l in ipairs(lines) do if l:find(pat) then n = n + 1 end end
    return n
end
local W = {}   -- the world of the current section

local function fresh(cfgv)
    for k in pairs(package.loaded) do
        if type(k) == "string" and k:find("^sdc_") then package.loaded[k] = nil end
    end
    lines = {}
    bp_hooks = {}
    W = { objs = {}, paths = {}, natives = {}, native_fail = {}, delayed = {}, sent = {}, handlers = {},
          calls = setmetatable({}, { __index = function() return 0 end }) }
    local log = setmetatable({ debug_enabled = false, probes_enabled = false, TEXT = {} }, { __index = function(_, k)
        return function(a, ...)
            local fmt, args = a, { ... }
            if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
            local ok, s = pcall(string.format, fmt, table.unpack(args))
            lines[#lines + 1] = k .. ": " .. tostring(ok and s or fmt)
        end
    end })
    package.loaded["sdc_log"] = log
    local ue = { ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }
    function ue.try(f, ...) local ok, v = pcall(f, ...) if ok then return v end end
    function ue.valid(o) return type(o) == "table" and o._valid == true end
    function ue.name(o) return ue.valid(o) and o._name or "<none>" end
    ue.short = ue.name
    function ue.class_name(o) return ue.valid(o) and o._cls or "" end
    function ue.prop(o, k) if not ue.valid(o) then return nil end return o._p[k] end
    function ue.set_prop(o, k, v) if not ue.valid(o) then return false end o._p[k] = v return true end
    function ue.str(v)
        if type(v) == "table" then return v._fname or v._text or "" end
        if v == nil then return "" end
        return tostring(v)
    end
    function ue.path(o) return ue.valid(o) and (o._path or "") or "" end
    function ue.find_all(cls)
        W.calls["find_all:" .. cls] = W.calls["find_all:" .. cls] + 1
        local out = {}
        for _, o in ipairs(W.objs) do if o._cls == cls then out[#out + 1] = o end end
        return out
    end
    function ue.player_chars()
        W.calls.player_chars = W.calls.player_chars + 1
        local out = {}
        for _, o in ipairs(W.objs) do if o._cls == "BP_PlayerCharacter_C" and o._valid then out[#out + 1] = o end end
        return out
    end
    function ue.find_first(cls) return ue.find_all(cls)[1] end
    function ue.find_object(path) return W.paths[path] end
    function ue.role(a) return ue.valid(a) and a._p.Role or -1 end
    function ue.is_runtime_spawned() return true end
    function ue.ksl() return W.ksl end
    function ue.local_pc() return W.pc end
    function ue.local_pawn() W.calls.local_pawn = W.calls.local_pawn + 1; return W.me end
    function ue.pawn_of(pc) return ue.valid(pc) and pc._p.Pawn or nil end
    function ue.location(a) return ue.valid(a) and a._p.__loc or nil end
    function ue.rotation(a) return nil end
    function ue.teleport(a, l) a._p.__loc = l return true end
    function ue.gameplay_statics() return W.gps end
    function ue.game_instance() return nil end
    function ue.world_context() return W.pc end
    function ue.world_path() return W.world_path or "/Game/Levels/L.L" end
    function ue.delay(label, ms, fn) W.delayed[#W.delayed + 1] = { label = label, ms = ms, fn = fn } end
    function ue.every() end
    function ue.call(o, f, ...) return pcall(o[f], o, ...) end
    function ue.loaded_asset(p) return W.paths[p] end
    function ue.load_asset(p) return W.paths[p] ~= nil, W.paths[p] end
    function ue.net_role() return W.role or "host" end
    function ue.in_main_menu() return false end
    function ue.hook_native(path, key, fn)
        W.calls["hook_native:" .. path] = W.calls["hook_native:" .. path] + 1
        if (W.native_fail[path] or 0) > 0 then
            W.native_fail[path] = W.native_fail[path] - 1
            return false, "no such function"
        end
        W.natives[path] = W.natives[path] or {}
        W.natives[path][#W.natives[path] + 1] = { key = key, fn = fn }
        return true
    end
    package.loaded["sdc_ue"] = ue
    W.cfg = cfgv or {}
    package.loaded["sdc_config"] = { get = function(k) return W.cfg[k] end, player_name = function() return "Host" end }
    package.loaded["sdc_net"] = {
        on = function(kind, fn) W.handlers[kind] = fn end,
        send_to = function(pc, kind, ...) W.sent[#W.sent + 1] = { to = pc, kind = kind, f = { ... } }; return true end,
        broadcast = function(pcs, kind, ...) for _, pc in ipairs(pcs) do W.sent[#W.sent + 1] = { to = pc, kind = kind, f = { ... } } end end,
        send_to_host = function(kind, ...) W.sent[#W.sent + 1] = { to = "host", kind = kind, f = { ... } }; return true end,
    }
    package.loaded["sdc_ctx"] = { addr = function(o) return o and o._addr end }
    return log, ue
end

local function add(o) W.objs[#W.objs + 1] = o; return o end
local function sent_of(kind)
    local out = {}
    for _, m in ipairs(W.sent) do if m.kind == kind then out[#out + 1] = m end end
    return out
end

-- =================================================================== sync
print("== A1: AI ghosts destroyed already are skipped (sdc_sweepguard.live)")
local log = fresh({ ai_fix = true, shot_sounds = true })
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"
W.ksl = new("KismetSystemLibrary", "Default__KismetSystemLibrary")
local isvalid_calls = 0
W.paths[KSL_ISVALID] = setmetatable({}, { __call = function(_, ctx, o)
    isvalid_calls = isvalid_calls + 1
    assert(ctx == W.ksl, "IsValid UFunction called with the library as context")
    return o._live ~= false
end })
package.loaded["sdc_players"] = { helpers = {} }
local guard = require("sdc_sweepguard")
check(type(guard.live) == "function", "sdc_sweepguard exports live")
package.loaded["sdc_appearance"] = { player_id = function(p) return p._p.__id end }
package.loaded["sdc_ownsounds"] = { range_of = function() return 5000, "ATT" end, audible_here = function() return true, 0 end }
local sync = require("sdc_sync")
local dead = add(new("BP_MasterAICharacter_C", "Zombie_dead", { Role = 3, ["IsDead?"] = true }))
dead._live = false
local ghost = add(new("BP_MasterAICharacter_C", "Zombie_ghost", { Role = 3, ["IsDead?"] = false }))
check(guard.live(dead) == false and guard.live(ghost) == true, "live: KismetSystemLibrary.IsValid through its UFunction")
for _ = 1, 3 do sync.client_ai_tick() end
check(dead._destroyed == nil, "a ghost destroyed already is not destroyed again")
check(ghost._destroyed == 2, "a live ghost: two removal attempts")
check(count_lines("survives removal") == 1 and count_lines("Zombie_dead") == 0,
    "only the live ghost is reported as surviving (no false warning for the destroyed one)")

print("== A4: per-character tables of sdc_sync are pruned / cleared")
local stale = add(new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Role = 3 }))
sync.client_hide_stale_pawns()
check(count_lines("hid stale local copy BP_PlayerCharacter_C_7") == 1, "stale copy hidden and logged")
sync.client_hide_stale_pawns()
check(count_lines("hid stale local copy BP_PlayerCharacter_C_7") == 1, "logged once while it stays")
stale._valid = false
sync.client_hide_stale_pawns()
local stale2 = add(new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_7", { Role = 3 }))
sync.client_hide_stale_pawns()
check(count_lines("hid stale local copy BP_PlayerCharacter_C_7") == 2, "gone and back (same name): its entry was dropped")
stale2._valid = false
local cmc = new("CharacterMovementComponent", "CMC", { MovementMode = 0 },
    { SetMovementMode = function(self, m) self._p.MovementMode = m end })
local mover = add(new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_8", { Role = 2, CharacterMovement = cmc }))
sync.unstick(mover, os.time(), "client")
cmc._p.MovementMode = 0
sync.unstick(mover, os.time(), "client")
check(count_lines("BP_PlayerCharacter_C_8 spawned with movement disabled") == 1, "unstick logged once per character")
sync.forget_world()
cmc._p.MovementMode = 0
sync.unstick(mover, os.time(), "client")
check(count_lines("BP_PlayerCharacter_C_8 spawned with movement disabled") == 2, "forget_world empties the tables")
mover._valid = false

print("== B1: the sound subscriber needs mirror_sounds (or debug_probes), not debug")
log.debug_enabled = true
local PLAY = "/Script/Engine.GameplayStatics:PlaySoundAtLocation"
local SPAWN = "/Script/Engine.GameplayStatics:SpawnSoundAtLocation"
local rpc = new("BP_PlayerController_C", "PC_client", { NetConnection = new("NetConnection", "Conn") })
local cpawn = add(new("BP_PlayerCharacter_C", "ClientChar", { Role = 3, PlayerState = new("PlayerState", "PS2", { PlayerId = 2 }), Controller = rpc, __id = 2 }))
rpc._p.Pawn = cpawn
sync.host_sound_tick({ rpc })
check(W.natives[PLAY] == nil and W.natives[SPAWN] == nil, "debug on, mirror off: no PlaySoundAtLocation subscriber")
W.cfg.mirror_sounds = true
sync.host_sound_tick({ rpc })
check(W.natives[PLAY] ~= nil and W.natives[SPAWN] ~= nil, "mirror_sounds on: subscribers installed")
W.cfg.mirror_sounds = false
local gets = { n = 0 }
W.natives[PLAY][1].fn(nil, param(cpawn, gets), param(new("SoundCue", "S"), gets), param({ X = 0, Y = 0, Z = 0 }), nil, param(1), param(1))
check(gets.n == 0, "mirror switched off again: a world sound is not even looked at")

print("== B2: no line per shot with debug on, one summary")
sync.forget_world()
W.me = add(new("BP_PlayerCharacter_C", "Me", { Role = 2, __local = true }))
local shooter = add(new("BP_PlayerCharacter_C", "Shooter", { Role = 1 }))
local snd = new("SoundCue", "Gunshot_M4")
local wcomp = new("BP_WeaponsPickupComponent_C", "WComp", { FirearmSound = snd, ["SuppressorAttached?"] = false })
local weapon = add(new("BP_FirearmPickup_C", "BP_M4Pickup_C_1", { BP_WeaponsPickupComponent = wcomp, __owner = shooter, __loc = { X = 1, Y = 2, Z = 3 } }))
local played = 0
W.gps = new("GameplayStatics", "Default__GameplayStatics", {}, { PlaySoundAtLocation = function() played = played + 1 end })
sync.ensure_shot_sounds()
local FX = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:MC_WeaponEffects"
check(bp_hooks[FX] ~= nil, "MC_WeaponEffects hook registered")
for _ = 1, 25 do advance(0.1); bp_hooks[FX](param(weapon)) end
check(played == 25, "every shot played (" .. played .. ")")
check(count_lines("shot: played") == 0 and count_lines("fx: MC_WeaponEffects") == 0, "no line per shot")
advance(31)
bp_hooks[FX](param(weapon))
check(count_lines("shot: 26 MC_WeaponEffects, 26 shot sounds played in the last") == 1, "one summary line after 30 s")
bp_hooks[FX](param(weapon))
check(count_lines("MC_WeaponEffects, %d+ shot sounds") == 1, "not repeated right away")
check(sync.fx_listeners == nil and sync.log_mesh_states == nil and sync.sky_probe == nil, "dead sync exports gone")
check(sync.experiment_tick == nil and sync.movement_monitor_frame == nil and sync.install_motion_probes == nil
    and sync.probe_watch == nil and sync.probe_report == nil and sync.send_shot_map == nil,
    "the debug-only probes and their stubs are gone (callers removed at integration)")

-- =================================================================== localinit
print("== A2: 'Quit to main menu' with unload_menu_level = false")
fresh({ unload_menu_level = false, block_menu_level = true })
local LOAD = "/Script/Engine.GameplayStatics:LoadStreamLevel"
W.native_fail[LOAD] = 1
local localinit = require("sdc_localinit")
check(localinit.reset == nil and localinit.reset_menu_level == nil, "unused resets removed")
check(localinit.install_hooks() == false and count_lines("LoadStreamLevel hook FAILED") == 1, "first registration fails")
W.pc = new("BP_PlayerController_C", "PC_me")
W.ksl = new("KismetSystemLibrary", "KSL", {}, { IsStandalone = function() return false end, IsServer = function() return false end })
local me = new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_me")
localinit.tick(nil, 1)
check(W.natives[LOAD] ~= nil and #W.natives[LOAD] == 1 and count_lines("LoadStreamLevel hook ok") == 1,
    "retried from the tick: shared pre-only hook (sdc_ue.hook_native)")
local quits = 0
localinit.on_client_quit_to_menu = function() quits = quits + 1 end
local pre = W.natives[LOAD][1].fn
local gi = new("SD_GameInstance_C", "GI")
local lp = param(FName("MainMenu"))
pre(nil, param(gi), lp)
check(lp.val()._fname == "None" and #W.delayed == 0, "arrival: the level script's own load is blocked, not a quit")
localinit.tick(me, 5)   -- the own character is there; menu_level_tick is never called
lp = param(FName("MainMenu"))
pre(nil, param(gi), lp)
check(lp.val()._fname == "None" and #W.delayed == 1 and W.delayed[1].label == "quit-to-menu", "after playing: the quit is seen")
W.delayed[1].fn()
check(quits == 1, "the client leaves the server")
-- menu_level_tick is safe to call every tick with unload_menu_level = false
local ls_calls = 0
local ls = new("LevelStreaming", "MainMenu", {}, { IsLevelLoaded = function() return true end, ShouldBeLoaded = function() return true end,
    SetShouldBeVisible = function() error("must not unload") end, SetShouldBeLoaded = function() error("must not unload") end })
W.gps = new("GameplayStatics", "GPS", {}, { GetStreamingLevel = function() ls_calls = ls_calls + 1; return ls end })
for i = 1, 4 do localinit.menu_level_tick(me, 10 + i * 4, false) end
check(ls_calls == 1 and count_lines("unload_menu_level = false, left as is") == 1, "unload off: one look per world, nothing unloaded")

print("== C4: LoadStreamLevel registration gives up after 5 tries")
fresh({})
W.native_fail[LOAD] = 99
localinit = require("sdc_localinit")
for i = 1, 8 do localinit.tick(nil, i) end
check(W.calls["hook_native:" .. LOAD] == 5 and count_lines("not tried again") == 1, "5 tries, then quiet")

-- =================================================================== ctx
print("== A3: the player-0 map drops a body whose address was reused")
fresh({ redirect_player0 = true })
local hostpc = new("BP_PlayerController_C", "PC_host")
local cpc = new("BP_PlayerController_C", "PC_client", { NetConnection = new("NetConnection", "C") })
W.pc = hostpc
W.gps = new("GameplayStatics", "GPS", {}, {
    GetNumPlayerControllers = function() return 2 end,
    GetPlayerController = function(_, _, i) if i == 0 then return hostpc elseif i == 1 then return cpc end end,
})
package.loaded["sdc_ctx"] = nil   -- the real one here
local ctx = require("sdc_ctx")
local P1 =new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_1", { Controller = cpc })
cpc._p.Pawn = P1
ctx.tick({ cpc })
check(ctx.active and ctx.player_for(P1) and ctx.player_for(P1).pc == cpc, "the client's character is its player's")
local P2 = new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_2", { Controller = cpc })
cpc._p.Pawn, P1._p.Controller = P2, nil
ctx.tick({ cpc })
check(ctx.player_for(P1) and ctx.player_for(P1).pc == cpc, "respawned: the old body (nobody's) is still that player's")
P1._name, P1._cls = "BP_Zombie_C_44", "BP_Zombie_C"   -- freed, its address taken by a new object
ctx.tick({ cpc })
check(ctx.player_for(P1) == nil, "address reused by another object: not mapped any more")
local P3 = new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_3", {})
ctx.bind(P3, cpc)
ctx.tick({ cpc })
check(ctx.player_for(P3) and ctx.player_for(P3).pc == cpc, "bound before Possess: kept")
P3._p.Controller = hostpc
ctx.tick({ cpc })
check(ctx.player_for(P3) == nil, "now another player's: dropped")
local P4 = new("BP_PlayerCharacter_C", "BP_PlayerCharacter_C_4", {})
ctx.bind(P4, cpc)
ctx.tick({ cpc })
P4._name = "BP_PlayerCharacter_C_5"   -- a new character at the same address, nobody's yet
ctx.tick({ cpc })
check(ctx.player_for(P4) == nil, "same class, other name: dropped")
W.cfg.redirect_player0 = false
ctx.tick({ cpc })
check(ctx.active == false, "redirect_player0 off: nothing carried over, redirection off")

-- =================================================================== appearance / pawnstate
print("== A4 / B3: looks and states of players who left; a host alone")
fresh({ weapon_pose_fix = false })
local S = { role = "host", remote_pcs = {} }
local function mkpc(name, id, net_conn)
    local pc = new("BP_PlayerController_C", name, { PlayerState = new("PlayerState", "PS_" .. name, { PlayerId = id }) })
    if net_conn then pc._p.NetConnection = new("NetConnection", "NC_" .. name) end
    local p = add(new("BP_PlayerCharacter_C", "Char_" .. name, { Role = 3, PlayerState = pc._p.PlayerState, Controller = pc }))
    pc._p.Pawn = p
    return pc, p
end
local hpc, hpawn = mkpc("host", 1, false)
hpawn._p.__local = true
W.pc, W.me = hpc, hpawn
local apc = mkpc("A", 2, true)
local bpc = mkpc("B", 3, true)
package.loaded["sdc_items"] = { equipped_of = function() return {} end }
local appearance = require("sdc_appearance")
local pawnstate = require("sdc_pawnstate")
check(appearance.dress_own == nil and pawnstate.aim_of == nil, "unused exports gone (dress_own, aim_of)")
appearance.init(S); pawnstate.init(S)
appearance.register_handlers(); pawnstate.register_handlers()
-- host alone: the own state is not even read
for _ = 1, 10 do pawnstate.fast_tick() end
check(W.calls.local_pawn == 0 and #sent_of("PSTATE") == 0, "host alone: fast_tick reads nothing, sends nothing")
S.remote_pcs = { apc, bpc }
pawnstate.fast_tick()
check(#sent_of("PSTATE") == 2, "a client connected: the own state goes out")
W.handlers.MYLOOK({ "m=1" }, apc)
W.handlers.MYLOOK({ "m=0" }, bpc)
W.handlers.MYSTATE({ "hf=1" }, apc)
W.handlers.MYSTATE({ "hf=0" }, bpc)
S.remote_pcs = { apc }   -- B left
local npc = mkpc("N", 4, true)
W.sent = {}
appearance.send_all(npc)
pawnstate.send_all(npc)
local look_ids, state_ids = {}, {}
for _, m in ipairs(sent_of("LOOK")) do look_ids[#look_ids + 1] = tostring(m.f[1]) end
for _, m in ipairs(sent_of("PSTATE")) do state_ids[#state_ids + 1] = tostring(m.f[1]) end
table.sort(look_ids); table.sort(state_ids)
check(table.concat(look_ids, ",") == "2", "looks to a new joiner: not of the player who left (" .. table.concat(look_ids, ",") .. ")")
check(table.concat(state_ids, ",") == "1,2", "states to a new joiner: own + present (" .. table.concat(state_ids, ",") .. ")")

-- =================================================================== playermarks
print("== B3 / A4 / C8: playermarks on a host nobody is connected to")
fresh({ player_names = true, player_names_range = 40, player_names_near = 4, gps_markers = true, gps_compass = true,
        map_markers_shared = true })
local pm = require("sdc_playermarks")
local S2 = { role = "host", remote = {}, remote_pcs = {} }
local hpc2, me2 = mkpc("host2", 1, false)
me2._p.__local = true
local gps_reads = 0
me2._m["IsGPSEquipped?"] = function(_, out) gps_reads = gps_reads + 1; out["GPS?"] = false end
W.pc, W.me = hpc2, me2
pm.init(S2)
for _ = 1, 10 do pm.tick(); pm.fast_tick(); advance(1) end
check(W.calls.player_chars == 0 and W.calls["find_all:BP_PlayerCharacter_C"] == 0, "no character scans while alone")
check(gps_reads == 0, "no GPS reads while alone")
local mk_scans = W.calls["find_all:BP_PlayerMarker_C"]
check(mk_scans >= 1 and mk_scans <= 3, "map marker pass every 5 s, not every second (" .. mk_scans .. " in 10 s)")
check(count_lines("^err") == 0, "no errors")
-- two clients; B's character has a HUD on the host (warned once per character)
local apc2, apawn2 = mkpc("A2", 2, true)
local bpc2, bpawn2 = mkpc("B2", 3, true)
bpawn2._p.InGameUI = new("BP_Ingame_C", "HUD_B", {}, { IsInViewport = function() return false end })
S2.remote = { A = { key = "A", pc = apc2, name = "A", hello = true }, B = { key = "B", pc = bpc2, name = "B", hello = true } }
S2.remote_pcs = { apc2, bpc2 }
pm.tick(); advance(1)
check(W.calls.player_chars >= 1, "with players: characters listed (sdc_ue.player_chars)")
pm.tick(); advance(1)
check(count_lines("remote character Char_B2 has a HUD on the host") == 1, "HUD warning once")
S2.remote.B, S2.remote_pcs = nil, { apc2 }
pm.tick(); advance(1)
S2.remote.B, S2.remote_pcs = { key = "B", pc = bpc2, name = "B", hello = true }, { apc2, bpc2 }
pm.tick(); advance(1)
check(count_lines("remote character Char_B2 has a HUD on the host") == 2, "left and came back: its warning record was dropped")
check(count_lines("^err") == 0, "no errors")

-- =================================================================== players
print("== B5: the client's minimap does not re-register player-placed markers")
fresh({})
package.loaded["sdc_widgets"] = setmetatable({}, { __index = function() return function() return nil end end })
local players = require("sdc_players")
players.init({ role = "client", remote = {} }, {})
local respawned = { POI = 0, PM = 0 }
add(new("BP_POIManager_C", "POI", {}, { RespawnMarker = function() respawned.POI = respawned.POI + 1 end }))
add(new("BP_PlayerMarker_C", "PM", {}, { RespawnMarker = function() respawned.PM = respawned.PM + 1 end }))
local mm = new("BPC_MinimapSystem_C", "MM", {}, { Event_ConstructMap = function() end })
W.pc = new("BP_PlayerController_C", "PC_c")
W.me = add(new("BP_PlayerCharacter_C", "Me_c", { MinimapSystemComponent = mm, InGameUI = new("BP_Ingame_C", "HUD") }))
players.reinit()
for _, d in ipairs(W.delayed) do if d.label == "markers" then d.fn() end end
check(respawned.POI == 1 and respawned.PM == 0, "POI markers re-registered, BP_PlayerMarker_C left to sdc_playermarks")

print(string.format("fix_e players: %d passed, %d failed", passed, fails))
print(fails == 0 and string.format("%d checks, ALL OK", passed) or string.format("%d checks, %d FAILED", passed + fails, fails))
os.exit(fails == 0 and 0 or 1)
