-- Mock harness: the host pulls a player to itself (sdc_players), and the
-- shared host move behind it, the client's own unstuck and sdc_persist's fall
-- check (real sdc_players / sdc_ue / sdc_net / sdc_log / sdc_config /
-- sdc_i18n; stub engine objects, sdc_persist, sdc_vehicles).
--   1. the spot: a capsule sweep from the host per direction, ground under
--      it (spot = ground + 100, facing the host); blocked / no ground: next
--      direction; none or no trace library: near_host_spot
--   2. the pull: UNSTUCKTO|..|pull|id, the host's copy stopped, sdc_persist
--      told, «Переношу…»; the client's PULLACK ok / failed / dead / a stale id
--   3. the landing guard: the fall speed zeroed while beyond -600 for up to
--      4 s; ends once landed near the spot, at the time, or when gone
--   4. no answer in 5 s: the host's own 3D check (moved / not / gone)
--   5. refusals: gone (the record gone: the name the caller showed, else a
--      text without one - never the controller's name), waiting, dead,
--      joining, no character, restoring,
--      seated (sdc_vehicles' seat, InVehicle?, attached), ladder, sitting,
--      the host dead / without a character / seated / in the air, the
--      cooldown (shared with the client's own unstuck)
--   6. client_movement_authority off: the host's teleport, UNSTUCKOK|ok|pull
--   7. the client's own unstuck and sdc_persist's host_move: the same guard
--   8. the client: stop before / after the teleport, PULLACK, its notices;
--      a dead / seated client answers without moving; an older "host" move
--   9. sdcoop_pull (names with spaces, row numbers, a row whose player has
--      gone: the roster's name); English texts
-- usage: lua mock_pull.lua <scripts dir>
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
-- os.time follows os.clock; SKIP moves it on alone (a cooldown passing)
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
function RegisterHook() return 1, 2 end
function FName(s) return { ToString = function() return s end, _fname = s } end
function FText(s) return s end

-- a character: movement component with a velocity, falling / swimming flags
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

-- the trace library: per direction (call order) blocked or not; ground Z
local ksl = new_obj("KismetSystemLibrary", "Default__KismetSystemLibrary", {}, {})
by_path["/Script/Engine.Default__KismetSystemLibrary"] = ksl
local TR = { blocked = {}, ground = {}, sweeps = {}, downs = {}, fail = false }
ksl._m.CapsuleTraceSingleByProfile = function(_, wc, from, to, radius, half, profile, complex, ignore, dbg, hit)
    if TR.fail then error("no such function") end
    TR.sweeps[#TR.sweeps + 1] = { from = from, to = to, r = radius, half = half, profile = profile._fname, ignore = ignore }
    return TR.blocked[#TR.sweeps] == true
end
ksl._m.LineTraceSingle = function(_, wc, from, to, channel, complex, ignore, dbg, hit)
    TR.downs[#TR.downs + 1] = { from = from, to = to, channel = channel }
    local g = TR.ground[#TR.sweeps]
    if g == false then return false end
    hit.ImpactPoint = { X = from.X, Y = from.Y, Z = g or 95 }
    return true
end
local function traces_reset(blocked, ground)
    TR.blocked, TR.ground, TR.sweeps, TR.downs, TR.fail = blocked or {}, ground or {}, {}, {}, false
end

-- ------------------------------------------------------------ modules
package.loaded["sdc_ctx"] = { bind = function() end }
package.loaded["sdc_widgets"] = { game_window_open = function() return false end }
local RESTORING, noted = false, {}
package.loaded["sdc_persist"] = {
    restoring = function() return RESTORING end,
    note_moved = function(k) noted[#noted + 1] = k end,
}
local SEATS = {}
package.loaded["sdc_vehicles"] = { seat_of = function(k) return SEATS[k] end }
local cfg = require("sdc_config")
local log = require("sdc_log")
local toasts = {}
log.toast_sink = function(text, kind) toasts[#toasts + 1] = { text = text, kind = kind } end
local i18n = require("sdc_i18n")
cfg.set("language", "ru")
local net = require("sdc_net")
local sent = {}
net.send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc, kind = kind, args = { ... }, n = select("#", ...) }; return true end
net.send_to_host = function(kind, ...) sent[#sent + 1] = { to = "host", kind = kind, args = { ... }, n = select("#", ...) }; return true end
local function last_sent(kind)
    for i = #sent, 1, -1 do if sent[i].kind == kind then return sent[i] end end
    return nil
end
local function last_toast() return toasts[#toasts] or { text = "", kind = "" } end
local players = require("sdc_players")

-- world: the host (centre 1000,0,182: feet at 100) and Vasya under the map
local host_pawn, host_cmc = character("Host", { X = 1000, Y = 0, Z = 182 })
local host_pc = new_obj("BP_PlayerController_C", "HostPC", { Pawn = host_pawn, Player = new_obj("LocalPlayer", "LP", {}, {}) }, {})
host_pc._m.IsLocalController = function() return true end
registry["PlayerController"] = { host_pc }
local vpawn, vcmc = character("Vasya", { X = 50000, Y = 20000, Z = -3000 })
local rpc = new_obj("BP_PlayerController_C", "RemotePC", { Pawn = vpawn, NetConnection = new_obj("IpConnection", "C", {}, {}) }, {})
local key = rpc:GetFullName()
local S = { role = "host", remote = {}, remote_pcs = { rpc }, in_menu = false, menu_since = 0 }
local r = { key = key, pc = rpc, index = 1, name = "Вася Пупкин", hello = true, spawned_once = true, dead = false }
S.remote[key] = r
players.init(S, { remote_record = function(pc) return S.remote[pc:GetFullName()] end })
players.register_handlers()
local H = net.handlers
cfg.set("client_movement_authority", true)

local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

-- ------------------------------------------------------------ 1 + 2. spot, pull
print("pull")
traces_reset({ true }, {})     -- direction 1 blocked, 2 clear
vcmc._p.Velocity = { X = 0, Y = 0, Z = -2500 }
sent, toasts, noted = {}, {}, {}
local mark = #LOGS
local ok, code = players.pull_to_host(key)
check(ok == true and code == nil, "pull_to_host: ok")
local un = last_sent("UNSTUCKTO")
check(un and un.to == rpc and un.args[5] == "pull" and un.args[6] == "1" and un.n == 6, "UNSTUCKTO|x|y|z|yaw|pull|1 to the player")
check(#TR.sweeps == 2 and TR.sweeps[1].r == 30 and TR.sweeps[1].half == 82 and TR.sweeps[1].profile == "Pawn"
    and TR.sweeps[1].ignore[1] == host_pawn and TR.sweeps[1].ignore[2] == vpawn, "capsule sweeps (30 / 82, 'Pawn', both pawns ignored)")
check(TR.sweeps[1].from.Z == 222 and math.abs(d3(TR.sweeps[1].to, { X = 1000, Y = 0, Z = 222 }) - 160) < 0.01,
    "from the host's capsule (+40) to 160 cm away")
local ang2 = math.rad(72 + 45)
check(math.abs(tonumber(un.args[1]) - (1000 + math.cos(ang2) * 160)) < 1 and math.abs(tonumber(un.args[2]) - math.sin(ang2) * 160) < 1,
    "direction 1 blocked: the spot is direction 2 (index*72 + 45 degrees)")
check(tonumber(un.args[3]) == 195 and #TR.downs == 1 and TR.downs[1].to.Z == 100 - 150 and TR.downs[1].channel == 0,
    "ground 150 cm under the host's feet at most (Visibility); spot = ground + 100")
local yaw = math.rad(tonumber(un.args[4]))
local sx, sy = tonumber(un.args[1]), tonumber(un.args[2])
check((1000 - sx) * math.cos(yaw) + (0 - sy) * math.sin(yaw) > 150, "the spot faces the host")
check(vcmc.stops == 1 and vcmc._p.Velocity.Z == 0, "the host's copy: fall speed zeroed at once")
check(noted[1] == key, "sdc_persist told (note_moved)")
check(r.unstuck_at == os.time() and r.pull and r.pull.id == "1", "cooldown stamp, the pull waits for its answer")
check(last_toast().text == "Переношу игрока Вася Пупкин к вам…" and last_toast().kind == "info", "the host: «Переношу игрока … к вам…»")
check(logged("host: pull #1 of Vasya Pupkin from 530 m away", mark) ~= nil and logged("clear spot, direction 2", mark) ~= nil,
    "one log line: who, distance, spot, how")

-- 3. the landing guard
print("landing guard")
vcmc._p.Velocity = { X = 0, Y = 0, Z = -1800 }   -- the host's copy re-simulates the client's fall
advance(0.1)
check(vcmc.stops == 2 and vcmc._p.Velocity.Z == 0, "guard: zeroed again (beyond -600)")
vcmc._p.Velocity = { X = 0, Y = 0, Z = -500 }
advance(0.1)
check(vcmc.stops == 2, "guard: a slow fall is left alone")
-- the client's move arrives: the copy at the spot, landed
vpawn._p.__loc = { X = sx, Y = sy, Z = 185 }
advance(0.3)
check(logged("landing guard (pull) for Vasya Pupkin ended", mark) == nil, "guard: not ended right on arrival (0.5 s calm)")
advance(0.4)
check(logged("landing guard (pull) for Vasya Pupkin ended: landed; fall speed zeroed 1 time(s) (fastest -1800 cm/s)", mark) ~= nil,
    "guard ends once landed near the spot")
local nq = #queue
advance(1)
check(#queue <= nq, "no guard steps left running")

-- the client's answer
print("answer")
toasts = {}
H.PULLACK({ "ok", "pull", "99" }, rpc)
check(#toasts == 0 and r.pull ~= nil, "a stale id: ignored")
H.PULLACK({ "ok", "pull", "1" }, rpc)
check(last_toast().text == "Вася Пупкин перенесён к вам." and last_toast().kind == "ok" and r.pull == nil, "«… перенесён к вам.»")
advance(5)
check(#toasts == 1, "answered: the 5 s check stays silent")

-- the cooldown: shared with the client's own unstuck
print("refusals")
local function refused(c, text, ...)
    toasts = {}
    local okk, got = players.pull_to_host(...)
    local t = last_toast()
    check(okk == false and got == c and t.text == text and t.kind == "warn", "refused " .. c .. ": " .. t.text)
end
-- the clock as if 3 s had passed since the pull (the waits above took longer)
SKIP = SKIP + (3 - (os.time() - r.unstuck_at))
local n_sent = #sent
refused("wait", "Игрока Вася Пупкин можно будет перенести снова через 7 с.", key)
check(#sent == n_sent, "a refusal sends nothing to the player")
SKIP = SKIP + 20
r.dead = true
refused("dead", "Игрок Вася Пупкин погиб — пусть возродится кнопкой «Возрождение — рядом с хостом».", key)
r.dead = false
vpawn._p["PlayerDead?"] = true
refused("dead", "Игрок Вася Пупкин погиб — пусть возродится кнопкой «Возрождение — рядом с хостом».", key)
vpawn._p["PlayerDead?"] = false
r.access = "wait"
refused("waiting", "Игрок Вася Пупкин ещё ждёт вашего разрешения войти (вкладка «Мир»).", key)
r.access = nil
r.kicked = os.time()
refused("gone", "Игрок Вася Пупкин уже вышел из мира.", key)
r.kicked = nil
-- the record gone: never the session key (a controller's name) in the text
local GONE_KEY = "BP_PlayerController_C_2147481234"
refused("gone", "Этот игрок уже вышел из мира.", GONE_KEY)
check(not last_toast().text:find("PlayerController", 1, true), "  no controller name on screen")
refused("gone", "Игрок Bob уже вышел из мира.", GONE_KEY, "Bob")
refused("gone", "Этот игрок уже вышел из мира.", GONE_KEY, "")
r.kicked = os.time()
refused("gone", "Игрок Вася Пупкин уже вышел из мира.", key, "Bob")
r.kicked = nil
rpc._p.Pawn = nil
r.spawned_once = false
refused("joining", "Игрок Вася Пупкин ещё входит в мир — подождите несколько секунд.", key)
r.spawned_once = true
refused("no_char", "У игрока Вася Пупкин ещё нет персонажа в мире.", key)
rpc._p.Pawn = vpawn
RESTORING = true
refused("joining", "Игрок Вася Пупкин ещё входит в мир — подождите несколько секунд.", key)
RESTORING = false
SEATS[key] = "passenger"
refused("vehicle", "Игрок Вася Пупкин в транспорте — пусть сначала выйдет.", key)
SEATS[key] = nil
vpawn._p["InVehicle?"] = true
refused("vehicle", "Игрок Вася Пупкин в транспорте — пусть сначала выйдет.", key)
vpawn._p["InVehicle?"] = nil
vpawn._p.__parent = new_obj("BP_Car_C", "Car", {}, {})
refused("vehicle", "Игрок Вася Пупкин в транспорте — пусть сначала выйдет.", key)
vpawn._p.__parent = nil
vpawn._p["ClimbingLadder?"] = true
refused("ladder", "Игрок Вася Пупкин на лестнице — пусть слезет.", key)
vpawn._p["ClimbingLadder?"] = nil
vpawn._p["Sitting?"] = true
refused("sitting", "Игрок Вася Пупкин сидит — пусть встанет.", key)
vpawn._p["Sitting?"] = nil
host_pawn._p["PlayerDead?"] = true
refused("host_dead", "Вы мертвы — сначала возродитесь.", key)
host_pawn._p["PlayerDead?"] = false
host_pc._p.Pawn = nil
refused("host_nochar", "У вас нет персонажа в мире.", key)
host_pc._p.Pawn = host_pawn
host_pawn._p["InVehicle?"] = true
refused("host_vehicle", "Сначала выйдите из транспорта.", key)
host_pawn._p["InVehicle?"] = nil
host_cmc.falling = true
refused("host_air", "Встаньте на землю: вы в воздухе, в воде или на лестнице.", key)
host_cmc.falling, host_cmc.swimming = false, true
refused("host_air", "Встаньте на землю: вы в воздухе, в воде или на лестнице.", key)
host_cmc.swimming = false
host_pawn._p["ClimbingLadder?"] = true
refused("host_air", "Встаньте на землю: вы в воздухе, в воде или на лестнице.", key)
host_pawn._p["ClimbingLadder?"] = nil
check(r.pull == nil and #noted == 1, "no refusal moved anything")
S.role = "client"
check(players.pull_to_host(key) == false, "not the host: nothing")
S.role = "host"

-- 4. no answer: the host's own check
print("no answer")
vpawn._p.__loc = { X = 50000, Y = 20000, Z = -3000 }
traces_reset({}, {})
toasts = {}
check(players.pull_to_host(key) == true, "second pull")
local id2 = last_sent("UNSTUCKTO").args[6]
check(id2 == "2", "a new id")
local spot2 = { X = tonumber(last_sent("UNSTUCKTO").args[1]), Y = tonumber(last_sent("UNSTUCKTO").args[2]),
                Z = tonumber(last_sent("UNSTUCKTO").args[3]) }
vpawn._p.__loc = { X = spot2.X + 50, Y = spot2.Y, Z = spot2.Z - 10 }
advance(4.9)
check(last_toast().kind == "info", "nothing before 5 s")
advance(0.2)
check(last_toast().text == "Вася Пупкин перенесён к вам." and r.pull == nil, "an older client: moved (3D near the spot, far from the start)")
SKIP = SKIP + 11
vpawn._p.__loc = { X = 50000, Y = 20000, Z = -3000 }
check(players.pull_to_host(key) == true, "third pull")
advance(5.1)
check(last_toast().text == "Не удалось подтвердить перенос игрока Вася Пупкин." and last_toast().kind == "warn",
    "not moved: «Не удалось подтвердить…»")
SKIP = SKIP + 11
check(players.pull_to_host(key) == true, "fourth pull")
local n_t = #toasts
S.remote[key] = nil
advance(5.1)
check(#toasts == n_t and logged("landing guard (pull) for Vasya Pupkin ended: the character is gone") ~= nil,
    "the player left: no notice, the guard ends")
S.remote[key] = r
r.pull = nil
-- the client's other answers
SKIP = SKIP + 11
check(players.pull_to_host(key) == true, "fifth pull")
H.PULLACK({ "failed", "pull", last_sent("UNSTUCKTO").args[6] }, rpc)
check(last_toast().text == "Не удалось перенести игрока Вася Пупкин: рядом с вами нет свободного места. Отойдите от стен и попробуйте ещё раз.",
    "the client could not move: no free spot")
SKIP = SKIP + 11
check(players.pull_to_host(key) == true, "sixth pull")
H.PULLACK({ "vehicle", "pull", last_sent("UNSTUCKTO").args[6] }, rpc)
check(last_toast().text == "Игрок Вася Пупкин в транспорте — пусть сначала выйдет.", "the client's own reason (a race)")
advance(5)

-- the guard runs out of time when the copy never arrives
SKIP = SKIP + 11
local m2 = #LOGS
check(players.pull_to_host(key) == true, "seventh pull")
advance(3.9)
check(logged("ended", m2) == nil, "guard still on at 3.9 s")
advance(0.3)
check(logged("landing guard (pull) for Vasya Pupkin ended: time up", m2) ~= nil, "guard: 4 s at most")
advance(1)

-- the spot: none clear -> near_host_spot; no ground -> next direction; no trace function
print("spot fallbacks")
SKIP = SKIP + 11
traces_reset({ true, true, true, true, true, true, true, true }, {})
local m3 = #LOGS
check(players.pull_to_host(key) == true, "all directions blocked: still pulled")
un = last_sent("UNSTUCKTO")
local a1 = math.rad(72)
check(math.abs(tonumber(un.args[1]) - (1000 + math.cos(a1) * 160)) < 1 and tonumber(un.args[3]) == 262,
    "near_host_spot (host + 80) as before")
check(logged("near_host_spot (no clear direction)", m3) ~= nil, "logged why")
advance(5)
SKIP = SKIP + 11
traces_reset({}, { false })
check(players.pull_to_host(key) == true, "pull")
un = last_sent("UNSTUCKTO")
check(math.abs(tonumber(un.args[1]) - (1000 + math.cos(ang2) * 160)) < 1, "no ground in direction 1 (a cliff): direction 2")
advance(5)
SKIP = SKIP + 11
traces_reset({}, {})
TR.fail = true
local m4 = #LOGS
check(players.pull_to_host(key) == true and logged("near_host_spot (capsule trace:", m4) ~= nil, "no trace function: near_host_spot")
advance(5)
TR.fail = false

-- 6. client_movement_authority off
print("server teleport")
cfg.set("client_movement_authority", false)
SKIP = SKIP + 11
traces_reset({}, {})
vpawn._p.__loc = { X = 50000, Y = 20000, Z = -3000 }
vcmc._p.Velocity = { X = 0, Y = 0, Z = -2000 }
vcmc._p.MovementMode = 0
local st0 = vcmc.stops
sent, toasts = {}, {}
check(players.pull_to_host(key) == true, "pull (server)")
local ok_msg = last_sent("UNSTUCKOK")
check(#vpawn.teleports >= 1 and d3(vpawn._p.__loc, { X = 1000, Y = 0, Z = 182 }) < 200, "the host teleported its copy")
check(ok_msg and ok_msg.args[1] == "ok" and ok_msg.args[2] == "pull" and last_sent("UNSTUCKTO") == nil, "UNSTUCKOK|ok|pull, no UNSTUCKTO")
check(vcmc.stops == st0 + 2 and vcmc._p.MovementMode == 3, "stopped before and after the teleport, movement freed")
check(#toasts == 1 and toasts[1].text == "Вася Пупкин перенесён к вам." and r.pull == nil, "the host's notice at once (no «Переношу…»)")
advance(5)
SKIP = SKIP + 11
vpawn.teleport_ok = false
check(players.pull_to_host(key) == true and last_sent("UNSTUCKOK").args[1] == "failed", "teleport failed: UNSTUCKOK|failed|pull")
check(last_toast().text:find("нет свободного места", 1, true) ~= nil, "the host: no free spot")
vpawn.teleport_ok = true
advance(5)
cfg.set("client_movement_authority", true)

-- 7. the client's own unstuck and sdc_persist's host_move: the same guard
print("unstuck and host_move")
SKIP = SKIP + 11
r.unstuck_at = nil
vpawn._p.__loc = { X = 50000, Y = 20000, Z = -3000 }
vcmc._p.Velocity = { X = 0, Y = 0, Z = -2400 }
sent, noted = {}, {}
st0 = vcmc.stops
local m5 = #LOGS
H.UNSTUCK({ "host" }, rpc)
un = last_sent("UNSTUCKTO")
check(un and un.args[5] == "host" and un.n == 5, "UNSTUCK: UNSTUCKTO|..|host (no id: an older client reads it as before)")
check(vcmc.stops == st0 + 1 and noted[1] == key, "the copy stopped, sdc_persist told")
vcmc._p.Velocity = { X = 0, Y = 0, Z = -1500 }
advance(0.1)
check(vcmc.stops == st0 + 2, "the guard protects the client's own unstuck too")
H.UNSTUCK({ "host" }, rpc)
check(last_sent("UNSTUCKOK").args[1] == "refused" and last_sent("UNSTUCKOK").args[2] == "soon", "unstuck rate limit unchanged")
toasts = {}
refused("wait", "Игрока Вася Пупкин можно будет перенести снова через 10 с.", key)
advance(5)
check(logged("landing guard (host) for Vasya Pupkin ended", m5) ~= nil, "unstuck guard ended")
local moved, spot = players.host_move(r, "host")
un = last_sent("UNSTUCKTO")
check(moved == true and spot and un.args[5] == "host" and tonumber(un.args[3]) == spot.Z, "host_move (sdc_persist's fall check)")
check(logged("moved next to the host (client): spot", m5) ~= nil, "host_move logged")
advance(5)
S.role = "client"
check(players.host_move(r, "host") == false, "host_move: host only")
S.role = "host"

-- 8. the client
print("client")
S.role = "client"
S.client = {}
local cpawn, ccmc = character("Me", { X = 0, Y = 0, Z = -5000 })
host_pc._p.Pawn = cpawn
ccmc._p.Velocity = { X = 0, Y = 0, Z = -2600 }
sent, toasts = {}, {}
H.UNSTUCKTO({ "1000", "200", "195", "-90", "pull", "7" })
local ack = last_sent("PULLACK")
check(#cpawn.teleports == 1 and cpawn._p.__loc.X == 1000 and ccmc.stops == 2, "teleported; stopped before and after")
check(ack and ack.to == "host" and ack.args[1] == "ok" and ack.args[2] == "pull" and ack.args[3] == "7", "PULLACK|ok|pull|7")
check(last_toast().text == "Хост перенёс вас к себе." and last_toast().kind == "ok", "«Хост перенёс вас к себе.»")
cpawn.teleport_ok = false
H.UNSTUCKTO({ "1000", "200", "195", "-90", "pull", "8" })
check(last_sent("PULLACK").args[1] == "failed" and last_sent("PULLACK").args[3] == "8", "PULLACK|failed")
check(last_toast().text == "Хост пытался перенести вас к себе, но рядом с ним не нашлось места." and last_toast().kind == "warn",
    "the player: no free spot next to the host")
cpawn.teleport_ok = true
local nt = #cpawn.teleports
cpawn._p["PlayerDead?"] = true
H.UNSTUCKTO({ "1000", "200", "195", "-90", "pull", "9" })
check(last_sent("PULLACK").args[1] == "dead" and #cpawn.teleports == nt, "dead: PULLACK|dead, not moved")
cpawn._p["PlayerDead?"] = false
cpawn._p["InVehicle?"] = true
H.UNSTUCKTO({ "1000", "200", "195", "-90", "pull", "10" })
check(last_sent("PULLACK").args[1] == "vehicle" and #cpawn.teleports == nt, "in a vehicle: PULLACK|vehicle, not moved")
cpawn._p["InVehicle?"] = nil
host_pc._p.Pawn = nil
H.UNSTUCKTO({ "1000", "200", "195", "-90", "pull", "11" })
check(last_sent("PULLACK").args[1] == "nopawn", "no character: PULLACK|nopawn")
host_pc._p.Pawn = cpawn
sent = {}
local st1 = ccmc.stops
H.UNSTUCKTO({ "1000", "200", "195", "0", "host" })
check(last_sent("PULLACK") == nil and last_toast().text == "Персонаж перенесён к хосту." and ccmc.stops == st1 + 2,
    "the own unstuck: as before, plus the stops")
H.UNSTUCKTO({ "1000", "200", "195", "0", "saved" })
check(last_toast().text == "Персонаж перенесён к хосту.", "saved: nothing to announce")
H.UNSTUCKOK({ "ok", "pull" })
check(last_toast().text == "Хост перенёс вас к себе.", "UNSTUCKOK|ok|pull (server mode)")
H.UNSTUCKOK({ "failed", "pull" })
check(last_toast().text == "Хост пытался перенести вас к себе, но рядом с ним не нашлось места.", "UNSTUCKOK|failed|pull")
H.UNSTUCKOK({ "ok", "host" })
check(last_toast().text == "Персонаж перенесён к хосту.", "UNSTUCKOK|ok|host unchanged")
host_pc._p.Pawn = host_pawn
S.role, S.client = "host", nil

-- 9. console, English, catalog
print("console and texts")
SKIP = SKIP + 11
local roster = { { name = "Host", state = "host", host = true }, { name = r.name, key = key, state = "game" } }
check(players.pull_console("Вася Пупкин", roster):find("moving", 1, true) ~= nil, "sdcoop_pull <name with a space>")
advance(5)
SKIP = SKIP + 11
check(players.pull_console("2", roster):find("moving", 1, true) ~= nil, "sdcoop_pull <row number> (host = 1)")
advance(5)
check(players.pull_console("1", roster):find("no player", 1, true) ~= nil, "row 1 is the host itself")
check(players.pull_console("Nobody", roster):find("no player Nobody", 1, true) ~= nil, "unknown name")
check(players.pull_console("", roster):find("usage", 1, true) ~= nil, "usage")
check(players.pull_console("Вася Пупкин", roster):find("not moved: wait", 1, true) ~= nil, "refusal shown in the console")
-- a row whose player has gone since the roster was read: the roster's name
local stale = { roster[1], { name = "Bob", key = GONE_KEY, state = "game" } }
toasts = {}
local reply = players.pull_console("2", stale)
check(reply == "sdcoop_pull: Bob not moved: gone" and last_toast().text == "Игрок Bob уже вышел из мира.",
    "sdcoop_pull <row> of a player gone: «Игрок Bob уже вышел из мира.», the reply names Bob: " .. reply)
check(not reply:find("PlayerController", 1, true) and not last_toast().text:find("PlayerController", 1, true),
    "  no controller name in the reply or on screen")
SKIP = SKIP + 11
cfg.set("language", "en")
i18n.notify()
toasts = {}
check(players.pull_to_host(key) == true and last_toast().text == "Moving Вася Пупкин to you...", "English: Moving … to you...")
H.PULLACK({ "ok", "pull", last_sent("UNSTUCKTO").args[6] }, rpc)
check(last_toast().text == "Вася Пупкин was moved to you.", "English: … was moved to you.")
refused("wait", "Вася Пупкин can be moved again in 10 s.", key)
cfg.set("language", "ru")
i18n.notify()
advance(5)
local bad = {}
for k, t in pairs(log.TEXT) do
    if k:find("^pull_") then
        if not (t[1] and t[2] and not t[1]:find("[\208\209]") and t[2]:find("[\208\209]") and i18n.SAY_CLASS[k] == "game") then
            bad[#bad + 1] = k
        end
    end
end
local n_pull = 0
for k in pairs(log.TEXT) do if k:find("^pull_") then n_pull = n_pull + 1 end end
check(#bad == 0 and n_pull >= 19, "pull_* notices: English log, Russian screen, class game (" .. n_pull .. "): " .. table.concat(bad, ","))
check(net.NOW.PULLACK == true and net.NOW.UNSTUCKTO == true, "PULLACK is sent at once (sdc_net NOW)")
local vf = io.open(SCRIPTS .. "/sdc_vehicles.lua", "r")
local vsrc = vf and vf:read("a") or ""
if vf then vf:close() end
check(vsrc:find("function M.seat_of(key)", 1, true) ~= nil, "sdc_vehicles exports seat_of")

io.write(string.format("pull: %d checks, %d failed\n", nchecks, fails))
io.write(fails == 0 and "ALL OK\n" or (fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
