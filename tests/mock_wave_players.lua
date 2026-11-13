-- Mock harness (0.7.3 wave, group "session"): sdc_players.
--   3. the game's HUDs on screen (screen_huds): WidgetBlueprintLibrary.
--      GetAllWidgetsOfClass (FindAllOf does not see UMG widgets) plus
--      FindAllOf, each once, never the class default; an old HUD in the
--      viewport is taken off, the own one stays
--   8. "go to a player" (sdcoop_goto): the host setting teleport_to_players,
--      to the host at once, to another client only after it agrees (yes /
--      no / no answer in 30 s), the asker's and the target's checks, the
--      cooldown, the client's own move and its GOTOACK, the target told; the
--      host's own move to a client; the client's console and answers; the
--      one moved not taken off a ladder or out of a seat; every check again
--      at the answer; no word at all from the host (an older host's mod)
--      said after GT.WAIT_S
--   9. the server's ClientRestart on this client: noted, the own setup runs
--      250 ms later without the 1 s wait; the mod's own ClientRestart call
--      and other machines' / roles' calls are not taken for it
-- Real sdc_players / sdc_ue / sdc_net / sdc_log / sdc_config / sdc_i18n;
-- stub engine objects (the harness of mock_pull.lua).
-- usage: lua mock_wave_players.lua <scripts dir>
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local LOGS = {}
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    LOGS[#LOGS + 1] = table.concat(parts, "\t")
end
local function logged(pat, from)
    for i = (from or 0) + 1, #LOGS do if LOGS[i]:find(pat, 1, true) then return LOGS[i] end end
    return nil
end

-- ------------------------------------------------------------ time
local T, SKIP = 100.0, 0
os.clock = function() return T end
local real_time = os.time
os.time = function(t) if t then return real_time(t) end return 1000000 + math.floor(T) + SKIP end
local queue = {}
function ExecuteInGameThreadWithDelay(ms, f) queue[#queue + 1] = { at = T + ms / 1000, f = f }; return #queue end
function ExecuteWithDelay(ms, f) queue[#queue + 1] = { at = T + ms / 1000, f = f } end
function ExecuteInGameThread(f) f() end
function LoopInGameThreadWithDelay() return 1 end
function LoopAsync() end
local function advance(s)
    local stop = T + s
    while true do
        local best = nil
        for i, q in ipairs(queue) do
            if q.at <= stop + 1e-9 and (not best or q.at < queue[best].at) then best = i end
        end
        if not best then break end
        local q = table.remove(queue, best)
        if q.at > T then T = q.at end
        q.f()
    end
    if stop > T then T = stop end
end

-- ------------------------------------------------------------ fake objects
local Obj = {}
local registry, by_path = {}, {}
local function new_obj(cls, short, props, methods)
    local o = setmetatable({ _cls = cls, _short = short, _p = props or {}, _m = methods or {}, _valid = true }, Obj)
    registry[cls] = registry[cls] or {}
    table.insert(registry[cls], o)
    return o
end
Obj.__index = function(t, k)
    local base = rawget(Obj, k)
    if base ~= nil then return base end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._cls .. " /Game/Levels/LongdownValley.LongdownValley:PersistentLevel." .. self._short end
function Obj:GetFName() local s = self._short; return { ToString = function() return s end } end
function Obj:GetClass() local c = self._cls; return { GetFName = function() return { ToString = function() return c end } end } end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:K2_GetActorLocation() return self._p.__loc or { X = 0, Y = 0, Z = 0 } end
function Obj:K2_GetActorRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end
function Obj:GetAttachParentActor() return self._p.__parent end
function Obj:K2_DestroyActor() self._valid = false end

function FindAllOf(cls) return registry[cls] or {} end
function FindFirstOf(cls) local l = registry[cls]; return l and l[1] or nil end
function StaticFindObject(path) return by_path[path] end
function NotifyOnNewObject() end
local HOOKS = {}
function RegisterHook(path, cb) HOOKS[path] = cb; return 1, 2 end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end
local function param(v) return { get = function() return v end } end

local function character(short, loc)
    local cmc = new_obj("CharacterMovementComponent", short .. "_CMC",
        { Velocity = { X = 0, Y = 0, Z = 0 }, MovementMode = 1 }, {})
    cmc.stops, cmc.falling, cmc.swimming = 0, false, false
    cmc._m.StopMovementImmediately = function(self) self.stops = self.stops + 1; self._p.Velocity = { X = 0, Y = 0, Z = 0 } end
    cmc._m.IsFalling = function(self) return self.falling end
    cmc._m.IsSwimming = function(self) return self.swimming end
    cmc._m.SetMovementMode = function(self, m) self._p.MovementMode = m end
    local p = new_obj("BP_PlayerCharacter_C", short, { __loc = loc, CharacterMovement = cmc, ["PlayerDead?"] = false }, {})
    p.teleports = {}
    p.teleport_ok = true
    p._m.K2_TeleportTo = function(self, dest)
        self.teleports[#self.teleports + 1] = dest
        if self.teleport_ok then self._p.__loc = { X = dest.X, Y = dest.Y, Z = dest.Z } end
        return self.teleport_ok
    end
    return p, cmc
end

-- the trace library: every direction clear, ground at 95
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {})
by_path["/Script/Engine.Default__KismetSystemLibrary"] = ksl
local TR = { sweeps = {} }
ksl._m.CapsuleTraceSingleByProfile = function(_, wc, from, to)
    TR.sweeps[#TR.sweeps + 1] = { from = from, to = to }
    return false
end
ksl._m.LineTraceSingle = function(_, wc, from, to, channel, complex, ignore, dbg, hit)
    hit.ImpactPoint = { X = from.X, Y = from.Y, Z = to.Z + 100 }
    return true
end

-- WidgetBlueprintLibrary: the HUDs in the viewport (UMG; FindAllOf misses them)
local WBL_HUDS = {}
local wbl = new_obj("WidgetBlueprintLibrary", "Default__WidgetBlueprintLibrary", {}, {})
wbl._m.GetAllWidgetsOfClass = function(_, wc, arr, cls, top)
    if not (cls and cls._short == "BP_Ingame_C" and top == true) then return end
    for _, w in ipairs(WBL_HUDS) do arr[#arr + 1] = w end
end
by_path["/Script/UMG.Default__WidgetBlueprintLibrary"] = wbl
by_path["/Game/Inventory/BP_Ingame.BP_Ingame_C"] = new_obj("WidgetBlueprintGeneratedClass", "BP_Ingame_C", {}, {})

-- ------------------------------------------------------------ modules
package.loaded["sdc_ctx"] = { bind = function() end }
package.loaded["sdc_widgets"] = { game_window_open = function() return false end, game_input = function() end,
                                  child = function() return nil end, forget = function() end }
local RESTORING = false
package.loaded["sdc_persist"] = { restoring = function() return RESTORING end, note_moved = function() end }
local SEATS = {}
package.loaded["sdc_vehicles"] = { seat_of = function(k) return SEATS[k] end }
local cfg = require("sdc_config")
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text, kind) toasts[#toasts + 1] = { text = text, kind = kind } end
local i18n = require("sdc_i18n")
cfg.set("language", "ru")
cfg.set("player_name", "Хост")
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... }, n = select("#", ...) }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... }, n = select("#", ...) }; return true end
local function last_sent(kind, to)
    for i = #sent, 1, -1 do if sent[i].kind == kind and (to == nil or sent[i].to == to) then return sent[i] end end
    return nil
end
local function last_toast() return toasts[#toasts] or { text = "", kind = "" } end
local ue = require("sdc_ue")
local players = require("sdc_players")

-- world: the host, Vasya (asks) and Petya (asked)
local host_pawn = character("Host", { X = 1000, Y = 0, Z = 182 })
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_pawn, Player = new_obj("LocalPlayer", "LP", {}, {}) }, {})
host_pc._m.IsLocalController = function() return true end
registry["PlayerController"] = { host_pc }
local vpawn = character("Vasya", { X = 9000, Y = 0, Z = 182 })
local ppawn = character("Petya", { X = 20000, Y = 0, Z = 182 })
local vpc = new_obj("BP_PlayerController_C", "VasyaPC", { Pawn = vpawn, NetConnection = new_obj("IpConnection", "C1", {}, {}) }, {})
local ppc = new_obj("BP_PlayerController_C", "PetyaPC", { Pawn = ppawn, NetConnection = new_obj("IpConnection", "C2", {}, {}) }, {})
local vkey, pkey = vpc:GetFullName(), ppc:GetFullName()
local S = { role = "host", remote = {}, remote_pcs = { vpc, ppc }, in_menu = false, menu_since = 0 }
local rv = { key = vkey, pc = vpc, index = 1, name = "Вася", hello = true, spawned_once = true, dead = false }
local rp = { key = pkey, pc = ppc, index = 2, name = "Петя", hello = true, spawned_once = true, dead = false }
S.remote[vkey], S.remote[pkey] = rv, rp
players.init(S, { remote_record = function(pc) return S.remote[pc:GetFullName()] end })
players.register_handlers()
local H = net.handlers
cfg.set("client_movement_authority", true)
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

-- ===================================================================== 8 host
print("go to a player: host")
sent, toasts = {}, {}
H.GOTO({ "Петя" }, vpc)
check(last_sent("GOTOST", vpc) and last_sent("GOTOST", vpc).args[1] == "off" and last_sent("GOTOASK") == nil,
    "setting off (default): GOTOST|off, nobody asked")
check(cfg.get("teleport_to_players") == false, "teleport_to_players defaults to off")
cfg.set("teleport_to_players", true)
sent = {}
H.GOTO({ "Никто" }, vpc)
check(last_sent("GOTOST", vpc).args[1] == "gone", "an unknown name: gone")
H.GOTO({ "вася" }, vpc)
check(last_sent("GOTOST", vpc).args[1] == "self", "the asker itself (any case): self")
-- to the host: no question
sent = {}
H.GOTO({ "хост" }, vpc)
local un = last_sent("UNSTUCKTO", vpc)
check(un and un.args[5] == "goto" and un.args[6] == "g1" and un.args[7] == "Хост" and un.n == 7,
    "to the host: UNSTUCKTO|x|y|z|yaw|goto|g1|Хост at once")
check(un and d2({ X = tonumber(un.args[1]), Y = tonumber(un.args[2]) }, host_pawn._p.__loc) < 200, "a spot next to the host")
check(last_sent("GOTOASK") == nil, "nobody asked for the host")
toasts = {}
H.GOTOACK({ "ok", "g9" }, vpc)
check(#toasts == 0, "GOTOACK with another id: nothing")
H.GOTOACK({ "ok", "g1" }, vpc)
check(last_toast().text == "Вася переместился к вам." and last_toast().kind == "ok", "the host is told once Vasya moved")
-- the cooldown (shared with unstuck / pull)
sent = {}
H.GOTO({ "Петя" }, vpc)
local st_ = last_sent("GOTOST", vpc)
check(st_ and st_.args[1] == "soon" and tonumber(st_.args[3]) == 10 and last_sent("GOTOASK") == nil, "cooldown: GOTOST|soon|..|10")
SKIP = SKIP + 11
-- to another client: it is asked
sent = {}
H.GOTO({ "Петя" }, vpc)
local ask = last_sent("GOTOASK", ppc)
check(ask and ask.args[2] == "Вася", "Petya asked: GOTOASK|id|Вася")
check(last_sent("GOTOST", vpc).args[1] == "asked" and last_sent("GOTOST", vpc).args[2] == "Петя", "Vasya: asked")
check(last_sent("UNSTUCKTO") == nil, "nothing moved before the answer")
H.GOTO({ "Петя" }, vpc)
check(last_sent("GOTOST", vpc).args[1] == "pending", "asking again: pending")
-- an answer from somebody else: ignored
H.GOTOANS({ ask.args[1], "1" }, vpc)
check(last_sent("UNSTUCKTO") == nil, "an answer from another player: ignored")
-- yes
H.GOTOANS({ ask.args[1], "1" }, ppc)
un = last_sent("UNSTUCKTO", vpc)
check(un and un.args[5] == "goto" and un.args[7] == "Петя", "yes: Vasya moved (UNSTUCKTO .. goto .. Петя)")
check(un and d2({ X = tonumber(un.args[1]), Y = tonumber(un.args[2]) }, ppawn._p.__loc) < 200, "a spot next to Petya")
check(not last_sent("MSG", ppc), "Petya not told before Vasya's answer")
H.GOTOACK({ "ok", un.args[6] }, vpc)
local m = last_sent("MSG", ppc)
check(m and m.args[1] == "goto_arrived" and m.args[2] == "Вася", "Petya told: MSG|goto_arrived|Вася")
H.GOTOANS({ ask.args[1], "1" }, ppc)
check(last_sent("UNSTUCKTO", vpc) == un, "the same answer again: nothing")
-- no
SKIP = SKIP + 11
sent = {}
H.GOTO({ "Петя" }, vpc)
ask = last_sent("GOTOASK", ppc)
H.GOTOANS({ ask.args[1], "0" }, ppc)
check(last_sent("GOTOST", vpc).args[1] == "denied" and last_sent("UNSTUCKTO") == nil, "no: denied, nothing moved")
-- no answer in 30 s
SKIP = SKIP + 11
sent = {}
H.GOTO({ "Петя" }, vpc)
ask = last_sent("GOTOASK", ppc)
advance(29)
check(last_sent("GOTOST", vpc).args[1] == "asked", "29 s: still waiting")
advance(1.5)
check(last_sent("GOTOST", vpc).args[1] == "noanswer", "30 s: noanswer")
H.GOTOANS({ ask.args[1], "1" }, ppc)
check(last_sent("UNSTUCKTO") == nil, "a late yes: nothing")
-- refusals
local function refused(code, what)
    local s = last_sent("GOTOST", vpc)
    check(s and s.args[1] == code, what .. ": " .. tostring(s and s.args[1]))
end
SKIP = SKIP + 11
sent = {}
ppawn._p["PlayerDead?"] = true
H.GOTO({ "Петя" }, vpc); refused("target_dead", "the target dead")
ppawn._p["PlayerDead?"] = false
SEATS[pkey] = "driver"
H.GOTO({ "Петя" }, vpc); refused("target_vehicle", "the target in a vehicle")
SEATS[pkey] = nil
ppawn._p["ClimbingLadder?"] = true
H.GOTO({ "Петя" }, vpc); refused("target_air", "the target on a ladder")
ppawn._p["ClimbingLadder?"] = nil
RESTORING = true
H.GOTO({ "Петя" }, vpc); refused("target_nochar", "the target still being put back")
RESTORING = false
vpawn._p["PlayerDead?"] = true
H.GOTO({ "Петя" }, vpc); refused("dead", "the asker dead")
vpawn._p["PlayerDead?"] = false
vpawn._p["InVehicle?"] = true
H.GOTO({ "Петя" }, vpc); refused("vehicle", "the asker in a vehicle")
vpawn._p["InVehicle?"] = nil
-- the one moved: not off a ladder, not out of a seat (as the pull)
vpawn._p["ClimbingLadder?"] = true
H.GOTO({ "Петя" }, vpc); refused("ladder", "the asker on a ladder")
H.GOTO({ "Хост" }, vpc); refused("ladder", "the asker on a ladder, to the host as well")
vpawn._p["ClimbingLadder?"] = nil
vpawn._p["Sitting?"] = true
H.GOTO({ "Петя" }, vpc); refused("sitting", "the asker sitting")
vpawn._p["Sitting?"] = nil
host_pawn._p["PlayerDead?"] = true
H.GOTO({ "Хост" }, vpc); refused("target_dead", "to a dead host")
host_pawn._p["PlayerDead?"] = false
check(last_sent("GOTOASK") == nil and last_sent("UNSTUCKTO") == nil, "no refusal asked or moved anybody")
-- both checked again at the answer
sent = {}
H.GOTO({ "Петя" }, vpc)
ask = last_sent("GOTOASK", ppc)
ppawn._p["PlayerDead?"] = true
H.GOTOANS({ ask.args[1], "1" }, ppc)
refused("target_dead", "yes, but the target died meanwhile")
ppawn._p["PlayerDead?"] = false
check(last_sent("UNSTUCKTO") == nil, "  nothing moved")
-- each of the other checks again at the answer (the state changed after the ask)
local function changed_meanwhile(set, unset, code, what)
    sent = {}
    H.GOTO({ "Петя" }, vpc)
    local a = last_sent("GOTOASK", ppc)
    set()
    if a then H.GOTOANS({ a.args[1], "1" }, ppc) end
    unset()
    refused(code, what)
    check(a ~= nil and last_sent("UNSTUCKTO") == nil, "  nothing moved")
end
changed_meanwhile(function() SEATS[pkey] = "driver" end, function() SEATS[pkey] = nil end,
    "target_vehicle", "yes, but the target got into a vehicle meanwhile")
changed_meanwhile(function() ppawn._p.CharacterMovement.falling = true end,
    function() ppawn._p.CharacterMovement.falling = false end, "target_air", "yes, but the target is in the air now")
changed_meanwhile(function() vpc._p.Pawn = nil end, function() vpc._p.Pawn = vpawn end,
    "nopawn", "yes, but the asker has no character now")
changed_meanwhile(function() vpawn._p["InVehicle?"] = true end, function() vpawn._p["InVehicle?"] = nil end,
    "vehicle", "yes, but the asker got into a vehicle meanwhile")
changed_meanwhile(function() vpawn._p["ClimbingLadder?"] = true end, function() vpawn._p["ClimbingLadder?"] = nil end,
    "ladder", "yes, but the asker is on a ladder now")
changed_meanwhile(function() vpawn._p["Sitting?"] = true end, function() vpawn._p["Sitting?"] = nil end,
    "sitting", "yes, but the asker sat down meanwhile")
-- the host's own teleport (client_movement_authority off)
SKIP = SKIP + 11
cfg.set("client_movement_authority", false)
sent = {}
H.GOTO({ "Петя" }, vpc)
ask = last_sent("GOTOASK", ppc)
H.GOTOANS({ ask.args[1], "1" }, ppc)
check(last_sent("GOTOST", vpc).args[1] == "done" and d2(vpawn._p.__loc, ppawn._p.__loc) < 200,
    "server mode: the host teleports its copy, GOTOST|done")
check(last_sent("MSG", ppc) and last_sent("MSG", ppc).args[1] == "goto_arrived", "  Petya told")
cfg.set("client_movement_authority", true)

-- the host goes to a client (no setting needed)
print("the host goes to a player")
cfg.set("teleport_to_players", false)
sent, toasts = {}, {}
local ok_h = players.host_goto(pkey)
check(ok_h == true and d2(host_pawn._p.__loc, ppawn._p.__loc) < 200, "host_goto: the host's character next to Petya")
check(last_toast().text == "Вы перенесены к игроку Петя." and last_toast().kind == "ok", "«Вы перенесены к игроку Петя.»")
check(last_sent("MSG", ppc) and last_sent("MSG", ppc).args[2] == "Хост", "Petya told: MSG|goto_arrived|Хост")
ppawn._p["PlayerDead?"] = true
local okd, why = players.host_goto(pkey)
check(okd == false and why == "target_dead" and last_toast().text == "Игрок Петя мёртв.", "a dead player: refused")
ppawn._p["PlayerDead?"] = false
host_pawn._p["PlayerDead?"] = true
okd, why = players.host_goto(pkey)
check(okd == false and why == "pull_host_dead" and last_toast().text == "Вы мертвы — сначала возродитесь.", "the host dead: refused")
host_pawn._p["PlayerDead?"] = false
-- the player gone to: not in a vehicle, on a ladder, in the air; the host
-- itself (the one moved): not off a ladder or out of a seat
local nt_h = #host_pawn.teleports
ppawn._p["ClimbingLadder?"] = true
okd, why = players.host_goto(pkey)
check(okd == false and why == "target_air"
    and last_toast().text == "Игрок Петя сейчас в воздухе, в воде или на лестнице — попробуйте чуть позже.", "the player on a ladder: refused")
ppawn._p["ClimbingLadder?"] = nil
SEATS[pkey] = "passenger"
okd, why = players.host_goto(pkey)
check(okd == false and why == "target_vehicle" and last_toast().text == "Игрок Петя в транспорте.", "the player in a vehicle: refused")
SEATS[pkey] = nil
host_pawn._p["ClimbingLadder?"] = true
okd, why = players.host_goto(pkey)
check(okd == false and why == "ladder" and last_toast().text == "Сначала слезьте с лестницы.", "the host on a ladder: refused")
host_pawn._p["ClimbingLadder?"] = nil
host_pawn._p["Sitting?"] = true
okd, why = players.host_goto(pkey)
check(okd == false and why == "sitting" and last_toast().text == "Сначала встаньте.", "the host sitting: refused")
host_pawn._p["Sitting?"] = nil
check(#host_pawn.teleports == nt_h, "  no refusal moved the host")
okd, why = players.host_goto("nobody", "Гость")
check(okd == false and why == "gone" and last_toast().text == "Игрока Гость нет в мире.", "gone: the shown name")
-- the console on the host
local roster = { { name = "Хост", host = true, me = true }, { name = "Вася", key = vkey }, { name = "Петя", key = pkey } }
host_pawn._p.__loc = { X = 1000, Y = 0, Z = 182 }
check(players.goto_console("3", roster) == "sdcoop_goto: moved" and d2(host_pawn._p.__loc, ppawn._p.__loc) < 200,
    "sdcoop_goto 3: by the row number")
check(players.goto_console("вася", roster) == "sdcoop_goto: moved" and d2(host_pawn._p.__loc, vpawn._p.__loc) < 200,
    "sdcoop_goto вася: by the name")
check(players.goto_console("1", roster):find("no other player", 1, true) ~= nil, "the host's own row: no")
check(players.goto_console("", roster):find("usage", 1, true) ~= nil, "no name: usage")

-- ===================================================================== 8 client
print("go to a player: client")
S.role = "client"
S.client = { setup_stage = 0, pawn_seen_at = 0 }
host_pc._p.Pawn = vpawn          -- this machine is Vasya now
ue.forget_world()
local croster = { { name = "Хост", host = true }, { name = "Вася", me = true }, { name = "Петя" } }
sent, toasts = {}, {}
local rep = players.goto_console("3", croster)
check(last_sent("GOTO") and last_sent("GOTO").args[1] == "Петя" and rep:find("Петя", 1, true) ~= nil, "row 3: GOTO|Петя to the host")
sent = {}
players.goto_console("2", croster)
check(last_sent("GOTO") == nil and last_toast().text == "Это вы.", "the own row: «Это вы.», nothing sent")
vpawn._p["PlayerDead?"] = true
players.goto_console("Петя", croster)
check(last_sent("GOTO") == nil and last_toast().text == "Персонаж мёртв — сначала возродитесь.", "dead: refused here")
vpawn._p["PlayerDead?"] = false
-- the host's answers
H.GOTOST({ "asked", "Петя" })
check(last_toast().text == "Спрашиваю игрока Петя, можно ли к нему…" and last_toast().kind == "info", "asked: info")
H.GOTOST({ "soon", "Петя", "7" })
check(last_toast().text == "Перенос снова будет доступен через 7 с.", "soon: the seconds")
H.GOTOST({ "denied", "Петя" })
check(last_toast().text == "Игрок Петя не разрешил перенос." and last_toast().kind == "warn", "denied: warn")
H.GOTOST({ "off", "Петя" })
check(last_toast().text == "Перенос к другим игрокам выключен у хоста.", "off")
H.GOTOST({ "brandnew", "Петя" })
check(last_toast().text == "Не удалось перенести вас к игроку Петя: нет свободного места.", "an unknown newer code: a generic text")
H.GOTOST({ "ladder", "Петя" })
check(last_toast().text == "Сначала слезьте с лестницы." and last_toast().kind == "warn", "ladder: «Сначала слезьте с лестницы.»")
H.GOTOST({ "sitting", "Петя" })
check(last_toast().text == "Сначала встаньте.", "sitting: «Сначала встаньте.»")
-- the host's move
sent = {}
H.UNSTUCKTO({ "20100", "0", "200", "0", "goto", "a7", "Петя" })
check(vpawn._p.__loc.X == 20100 and last_sent("GOTOACK") and last_sent("GOTOACK").args[1] == "ok"
    and last_sent("GOTOACK").args[2] == "a7", "UNSTUCKTO goto: moved, GOTOACK|ok|a7")
check(last_toast().text == "Вы перенесены к игроку Петя." and last_toast().kind == "ok", "«Вы перенесены к игроку Петя.»")
vpawn._p["PlayerDead?"] = true
local nt = #vpawn.teleports
H.UNSTUCKTO({ "1", "2", "3", "0", "goto", "a8", "Петя" })
check(#vpawn.teleports == nt and last_sent("GOTOACK").args[1] == "dead", "dead meanwhile: not moved, GOTOACK|dead")
vpawn._p["PlayerDead?"] = false
-- being asked
toasts, sent = {}, {}
H.GOTOASK({ "a9", "Петя" })
check(last_toast().text == "Петя хочет переместиться к вам. Разрешить: консоль (~) → sdcoop_goto_yes, отказать: sdcoop_goto_no.",
    "asked: the notice says how to answer")
check(players.goto_answer(true) == "sdcoop_goto: Петя may come" and last_sent("GOTOANS").args[1] == "a9"
    and last_sent("GOTOANS").args[2] == "1", "sdcoop_goto_yes: GOTOANS|a9|1")
check(last_toast().text == "Вы разрешили игроку Петя переместиться к вам.", "  «Вы разрешили…»")
check(players.goto_answer(true):find("nobody", 1, true) ~= nil, "answered already: nobody asks")
H.GOTOASK({ "a10", "Петя" })
check(players.goto_answer(false) == "sdcoop_goto: Петя may not come" and last_sent("GOTOANS").args[2] == "0", "sdcoop_goto_no")
H.GOTOASK({ "a11", "Петя" })
SKIP = SKIP + 31
check(players.goto_answer(true):find("nobody", 1, true) ~= nil, "after 30 s: too late")
-- English
cfg.set("language", "en")
H.GOTOST({ "denied", "Petya" })
check(last_toast().text == "Petya did not let you come.", "English: " .. last_toast().text)
H.GOTOST({ "ladder", "Petya" })
check(last_toast().text == "Get off the ladder first.", "English: " .. last_toast().text)
cfg.set("language", "ru")

-- no word at all from the host on the own GOTO (an older host's mod has no
-- GOTO: «no handler for GOTO» there): said after GT.WAIT_S
print("go to a player: no word from the host")
local NOREPLY = "Хост не ответил на запрос переноса — возможно, у него старая версия мода без этой функции."
local function noreplies()
    local n = 0
    for _, t in ipairs(toasts) do if t.text == NOREPLY then n = n + 1 end end
    return n
end
advance(10)   -- the earlier asks' waits (answered) run out first
sent, toasts = {}, {}
local mark8 = #LOGS
players.goto_console("Петя", croster)
advance(7.5)
check(noreplies() == 0, "7.5 s: nothing said yet")
advance(1)
check(noreplies() == 1 and last_toast().kind == "warn", "8 s without a word: «" .. NOREPLY .. "»")
local l8 = logged("client: no word from the host on going to ", mark8)
check(l8 ~= nil and l8:find(" in 8 s (the host's mod version ", 1, true) ~= nil, "  logged: " .. tostring(l8))
advance(10)
check(noreplies() == 1, "  once")
toasts = {}
players.goto_console("Петя", croster)
H.GOTOST({ "asked", "Петя" })
advance(9)
check(noreplies() == 0 and #toasts == 1, "the host's GOTOST in time: no such notice")
toasts = {}
players.goto_console("Хост", croster)
H.UNSTUCKTO({ "1500", "0", "200", "0", "goto", "g77", "Хост" })
advance(9)
check(noreplies() == 0, "the host's move in time: no such notice")
toasts = {}
players.goto_console("Петя", croster)
advance(4)
players.goto_console("Петя", croster)
advance(6)
check(noreplies() == 0, "asked again: the first wait does not count")
advance(3)
check(noreplies() == 1, "  the second one does")
toasts = {}
players.goto_console("Петя", croster)
S.role = "standalone"
advance(9)
S.role = "client"
check(noreplies() == 0, "left the session meanwhile: nothing said")
toasts = {}
local cs_was = S.client
players.goto_console("Петя", croster)
S.client = { setup_stage = 0, pawn_seen_at = 0 }
advance(9)
S.client = cs_was
check(noreplies() == 0, "another connection meanwhile: nothing said")

-- ===================================================================== 3
print("HUDs on screen")
local function hud(short, inv)
    local h = new_obj("BP_Ingame_C", short, {}, {})
    h.removed = 0
    h._m.IsInViewport = function(self) return self.inv end
    h._m.RemoveFromParent = function(self) self.removed = self.removed + 1; self.inv = false end
    h.inv = inv
    return h
end
registry["BP_Ingame_C"] = {}
local own = hud("BP_Ingame_C_1", true)
local old_umg = hud("BP_Ingame_C_0", true)          -- seen only by GetAllWidgetsOfClass
registry["BP_Ingame_C"] = { own }                   -- FindAllOf sees only the own one
local cdo = hud("Default__BP_Ingame_C", true)
registry["BP_Ingame_C"] = { own, cdo }
WBL_HUDS = { own, old_umg }
local list = players.screen_huds()
local names = {}
for _, w in ipairs(list) do names[#names + 1] = w._short end
check(#list == 2 and names[1] == "BP_Ingame_C_1" and names[2] == "BP_Ingame_C_0",
    "GetAllWidgetsOfClass + FindAllOf, each once, no class default: " .. table.concat(names, ","))
vpawn._p.InGameUI = own
vpawn._p.MinimapSystemComponent = nil
players.reinit()
check(old_umg.removed == 1 and own.removed == 0, "the old HUD only GetAllWidgetsOfClass sees is taken off; the own stays")
check(logged("client: removed an old HUD BP_Ingame_C_0") ~= nil, "  logged")
by_path["/Game/Inventory/BP_Ingame.BP_Ingame_C"] = nil
local old2 = hud("BP_Ingame_C_5", true)
registry["BP_Ingame_C"] = { own, old2 }
list = players.screen_huds()
check(#list == 2, "the class not loaded: FindAllOf alone")

-- ===================================================================== 9
print("ClientRestart")
players.install_watches()
local hook = HOOKS["/Script/Engine.PlayerController:ClientRestart"]
check(type(hook) == "function", "ClientRestart hooked (shared native hook)")
check(logged("watch ClientRestart ok") ~= nil, "  logged")
local newpawn = character("Vasya2", { X = 0, Y = 0, Z = 182 })
host_pc._p.Pawn = newpawn
host_pc._p.AcknowledgedPawn = nil
local own_calls = 0
host_pc._m.ClientRestart = function(self, p)
    own_calls = own_calls + 1
    hook(param(self), param(p))      -- the mod's own call goes through the hook as well
end
host_pc._m.ResetIgnoreInputFlags = function() end
host_pc._m.GetViewTarget = function() return newpawn end
local cs = { setup_stage = 0, pawn_seen_at = 0, had_pawn = true, pawn_key = ue.name(vpawn) }
S.client = cs
-- the session's 1 s tick first sees the new character: stage 0 waits a second
players.client_tick(cs, host_pc, newpawn, os.time())
check(cs.setup_stage == 0 and cs.pawn_key == ue.name(newpawn), "without the server's ClientRestart: the setup waits 1 s")
-- the server's ClientRestart comes
local mark = #LOGS
local n0 = players.restart.n
hook(param(host_pc), param(newpawn))
check(players.restart.n == n0 + 1 and players.restart.pawn == ue.name(newpawn), "noted (n, pawn)")
check(logged("the server's ClientRestart(Vasya2)", mark) ~= nil, "  logged")
advance(0.2)
check(cs.setup_stage == 0, "200 ms: not yet")
advance(0.1)
check(cs.setup_stage == 1 and logged("client: input Vasya2 (first)", mark) ~= nil, "250 ms later: the own setup ran (stage 1)")
check(own_calls == 1 and players.restart.n == n0 + 1, "the mod's own ClientRestart call is not taken for the server's")
-- a new character (respawn): the line has the delay
local p3 = character("Vasya3", { X = 0, Y = 0, Z = 182 })
host_pc._p.Pawn = p3
hook(param(host_pc), param(p3))
advance(0.5)
check(logged("possessing Vasya3 (respawn) (the server's ClientRestart", mark) ~= nil and cs.setup_stage == 1,
    "a respawn: possessing .. (the server's ClientRestart 0.2 s ago), set up at once")
-- not for this machine / not a client
local n1 = players.restart.n
hook(param(vpc), param(p3))
check(players.restart.n == n1, "another controller: ignored")
S.role = "host"
hook(param(host_pc), param(p3))
check(players.restart.n == n1, "the host: ignored")
S.role = "client"
-- the character gone before the delay: nothing
local p4 = character("Vasya4", { X = 0, Y = 0, Z = 182 })
hook(param(host_pc), param(p4))
host_pc._p.Pawn = p3
local st0 = cs.pawn_key
advance(0.5)
check(cs.pawn_key == st0, "the possessed character changed meanwhile: no setup for the other one")

io.write(string.format("wave players: %d checks, %s", nchecks, fails == 0 and "ALL OK" or (fails .. " FAILED")), "\n")
os.exit(fails == 0 and 0 or 1)
