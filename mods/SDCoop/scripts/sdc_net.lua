-- SDCoop: message channel between the host's mod and the clients' mods.
--
-- Rides on two stock engine RPCs, so it needs no sockets and no Blueprint
-- changes:
--   host -> client : APlayerController::ClientMessage (reliable client RPC;
--                    the client only prints it to the drop-down console)
--   client -> host : APlayerController::ServerExecRPC (reliable server RPC;
--                    its body is compiled out of shipping builds, so the host
--                    just receives the string)
-- Both are hooked on the receiving side. Messages look like
--   SDC1|<kind>|<field>|<field>...

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = {
    PREFIX = "SDC1",
    handlers = {},
    hooked = false,
    stats = { sent = 0, received = 0 },
}

local SEP = "|"

local function clean(v)
    local s = tostring(v == nil and "" or v)
    s = s:gsub("[|\r\n]", " ")
    return s
end

function M.encode(kind, ...)
    local parts = { M.PREFIX, clean(kind) }
    for i = 1, select("#", ...) do parts[#parts + 1] = clean((select(i, ...))) end
    return table.concat(parts, SEP)
end

function M.decode(s)
    if type(s) ~= "string" or s:sub(1, #M.PREFIX + 1) ~= M.PREFIX .. SEP then return nil end
    local fields = {}
    for part in (s .. SEP):gmatch("(.-)" .. "%" .. SEP) do fields[#fields + 1] = part end
    table.remove(fields, 1) -- prefix
    local kind = table.remove(fields, 1)
    return kind, fields
end

-- handler(fields, sender_pc) ; sender_pc is the remote controller on the host
-- and the local controller on a client.
function M.on(kind, handler)
    M.handlers[kind] = handler
end

-- Frequent message kinds are logged only with debug_net (they were dozens of
-- log lines a second: disk writes on both machines).
local FREQUENT = {
    MYSTATE = true, PSTATE = true, PPOS = true, MYGPS = true, STEALTH = true, ENV = true,
    PCVAR = true, PINFO = true, PEQUIP = true, VSTATE = true, VCAP = true, AIHP = true,
    VOCC = true,   -- sdc_vehicles: the seats 3+ of a car (next to its VSTATE records)
    AIHPQ = true, AIM = true, DXP = true, SKL = true, WSTAT = true, ITEMS = true, UIDS = true,
    PTOOLS = true, QS = true, QH = true, SKTREE = true, AIAPP = true, SND = true, MHIT = true,
    GWEAR = true,   -- sdc_wear: a client's gun / muzzle wear, ~2/s while firing
    TURFIRE = true, TURHIT = true,   -- sdc_turrets: turret shots / a client's hits, up to 4/s while firing
    VRADIO = true,   -- sdc_vehradio: a slider drag 2/s, each playing radio again every 10 s (it logs its own changes)
    RESPUI = true,   -- sdc_hudmods: a client's respirator filter percent, ~every 2-5 s in a radiation zone (it logs its own changes)
    DOWN = true,     -- sdc_down: a downed player's state, again every 10 s (it logs its own changes)
}
local function net_log(kind)
    return log.debug_enabled and (log.net_enabled or not FREQUENT[kind])
end

-- Kinds whose fields never go to the log (sdc_admin's JPW: a join password;
-- sdc_chat's CHAT / CHATM: what players write and their names).
M.SECRET = { JPW = true, CHAT = true, CHATM = true }
local function shown(kind, msg)
    if M.SECRET[kind] then return M.PREFIX .. SEP .. kind .. SEP .. "<hidden>" end
    return msg
end

-- [PERF] "msgs in": time spent in each kind's handler (sdc_perf).
M.handler_stats = {}   -- [kind] = { calls, ms, wmax }

local function dispatch(direction, pc, raw)
    local kind, fields = M.decode(raw)
    if not kind then return end
    M.stats.received = M.stats.received + 1
    if net_log(kind) then log.debug("net <- %s %s", direction, shown(kind, raw)) end
    local h = M.handlers[kind]
    if not h then
        log.debug("net: no handler for %s", kind)
        return
    end
    local t0 = os.clock()
    local ok, err = pcall(h, fields, pc)
    local ms = (os.clock() - t0) * 1000
    local s = M.handler_stats[kind]
    if not s then s = { calls = 0, ms = 0, wmax = 0 }; M.handler_stats[kind] = s end
    s.calls, s.ms = s.calls + 1, s.ms + ms
    if ms > s.wmax then s.wmax = ms end
    if not ok then log.err_throttled("net." .. kind, "net handler %s: %s", kind, tostring(err)) end
end

-- A message as its sender logs it: a long one is cut (the receiver logs it
-- whole; 1-2.5 KB looks / progress lines written by both machines were ~18%
-- of a client's UE4SS.log, and every UE4SS.log write can hold a slow
-- machine's game - sdc_log).
local SENT_LOG_MAX = 300
local function sent_text(msg)
    if #msg <= SENT_LOG_MAX then return msg end
    return string.format("%s... (%d bytes, logged whole by the receiver)", msg:sub(1, SENT_LOG_MAX), #msg)
end

local function client_message(pc, msg) pc:ClientMessage(msg, FName("SDCoop"), 0.0) end
local function server_exec(pc, msg) pc:ServerExecRPC(msg) end

-- The RPC itself. `waited` = seconds the message spent in the send queue.
local function raw_send(pc, to_host, kind, msg, waited)
    local ok, err = pcall(to_host and server_exec or client_message, pc, msg)
    if ok then
        M.stats.sent = M.stats.sent + 1
        if net_log(kind) then
            log.debug("net -> %s %s%s", to_host and "host" or "client", sent_text(shown(kind, msg)),
                waited and string.format(" (queued %.1f s)", waited) or "")
        end
    elseif to_host then
        log.err_throttled("net.send_to_host", "ServerExecRPC failed: %s", tostring(err))
    else
        log.err_throttled("net.send_to", "ClientMessage failed: %s", tostring(err))
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Send budget: a safety net for every module, per connection
-- ---------------------------------------------------------------------------
-- Every mod message is a reliable RPC on the receiving player's controller
-- channel. UE closes a connection when more than 256 reliable bunches of a
-- channel wait for their ack (RELIABLE_BUFFER): 2569 loot messages in 4 s
-- did that to a client in 0.6.46. A game that stands still (a client froze
-- for 2-9 s writing its UE4SS.log) acks nothing meanwhile, so a sender must
-- not keep pouring messages into it.
-- Measured normal traffic (2026-11-10 logs, one client): host -> client 4-6
-- msgs/s, at most 22 msgs / 5 KB (a join's world snapshot) or 14 msgs (in
-- play) in 250 ms, 49 msgs in 2 s; client -> host 2-3 msgs/s, at most 8 msgs /
-- 2.7 KB in 250 ms. The loot refill: 300 msgs / 20 KB in 250 ms (900/s).
-- Budget per connection: a token bucket of BUDGET.burst_msgs messages and
-- BUDGET.burst_bytes bytes (2x the normal 250 ms peaks), refilled at
-- rate_msgs / rate_bytes a second (several times the normal rate; a 9 s
-- freeze of the other game at that rate still stays far below 256). Within
-- it a message goes out at once, as before. Over it, it waits in a FIFO queue
-- per connection, drained by a game-thread loop every tick_ms.
-- NOW kinds never wait: movement, combat, vehicles / seats, session control,
-- and the payloads paired with a ClientRepObjRef RPC (sdc_ai, sdc_npc: the
-- object must follow its payload directly). They use the budget too, so
-- queued messages wait behind them, never the other way round. Messages of
-- one protocol that depend on their order must be in the same class.
-- A connection that sent us nothing for stall_s (NetConnection.
-- LastReceiveTime unchanged: the other game is frozen, or the link) gets no
-- queueable message until it is heard again.
-- Config net_send_budget = false: every message at once (as before 0.6.58).
M.BUDGET = { burst_msgs = 48, burst_bytes = 32768, rate_msgs = 24, rate_bytes = 24576,
             tick_ms = 50, sample_s = 0.1, stall_s = 0.5 }
local NOW = {}
for _, k in ipairs({
    -- movement / player state
    "MYSTATE", "PSTATE", "PPOS", "MYGPS", "PINFO", "PCVAR", "PEQUIP", "MYNVG", "SETMOVE", "STEALTH",
    -- combat, AI, sounds, throws (AIM AIHP AIKL AIAPP AIDEAD NPC*: paired with ClientRepObjRef)
    "AIM", "AIHP", "AIKL", "AIKILL", "AIDEAD", "AIAPP", "AIFX", "AIDAY", "NPCSET", "NPCFIRE", "NPCBLOOD",
    "NPCROCK", "MHIT", "MONT", "EXPL", "WMINE", "DMGNUM", "THROW", "THROWN", "THRFX", "THRACK", "OSND", "SND",
    "WHISTLE", "RLSTOP", "RADZ", "TURFIRE", "TURHIT",
    -- vehicles and seats
    "VENTER", "VEXIT", "VSEAT", "VSTATE", "VOCC", "VCAP", "VHORN", "VLIGHT", "VFLIP", "VPUSH", "VTOW", "VFUEL",
    "VREPAIR", "VBOXR", "VBUY", "VBUYR", "VRADIO", "VRADIOQ", "VSWITCH", "VSWR",
    -- session, respawn, character
    "HI", "HELLO", "RESPAWN", "RSPCAP", "UNSTUCK", "UNSTUCKOK", "UNSTUCKTO", "PULLACK", "SPAWNED", "SPAWNPT", "BED",
    "SLEEP", "CHAR", "CHARACK", "CHARNONE", "MSG",
    "CHATON", "CHAT", "CHATM",   -- sdc_chat: rare and small, never behind a world snapshot
    "DOWN", "DOWNCAP", "REVIVE", "GIVEUP", "DOWNQ",   -- sdc_down: knockdown state, revive key, give up
    -- world: rare replies to a player's own action, sent past sdc_world's own
    -- queue (its queued kinds - WLOOT WLOOTR WLOOTS WINF WRINF WBMOON, snapshots
    -- - stay in this queue class: their order among themselves is kept)
    "WBUILT", "WMOVE", "WFOL", "WHHIT", "WDMG",
    "SHWR", "SHWRQ", "SHWRR", "SHWRV",   -- sdc_shower: a start's water, the cooldown a press needs, small and rare
}) do NOW[k] = true end
M.NOW = NOW

-- totals since start ([PERF]: sdc_perf)
M.budget_stats = { episodes = 0, queued = 0, sent_late = 0, dropped = 0, max_wait = 0 }
local lanes = {}           -- [key] = lane (host: controller address, client: "host")
local loop = { started = false, hooked_reset = false }

local function budget_on()
    local cfg = package.loaded["sdc_config"]
    if type(cfg) == "table" and type(cfg.get) == "function" then
        local ok, v = pcall(cfg.get, "net_send_budget")
        if ok and v == false then return false end
    end
    return true
end

local function m_addr(o) return o:GetAddress() end
local function addr_of(o)
    local ok, a = pcall(m_addr, o)
    if ok and a then return a end
    return ue.name(o)
end

local function kinds_text(kinds)
    local list = {}
    for k, n in pairs(kinds) do list[#list + 1] = { k = k, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, math.min(5, #list) do out[i] = list[i].k .. " " .. list[i].n end
    return #out > 0 and table.concat(out, ", ") or "-"
end

local function refill(lane, now)
    local B = M.BUDGET
    local dt = now - lane.at
    lane.at = now
    if dt <= 0 then return end
    lane.tm = math.min(B.burst_msgs, lane.tm + dt * B.rate_msgs)
    lane.tb = math.min(B.burst_bytes, lane.tb + dt * B.rate_bytes)
end

-- room for one message of `size` bytes (a bigger one than the whole byte
-- budget goes when the bucket is full)
local function fits(lane, size)
    local B = M.BUDGET
    return lane.tm >= 1 and (lane.tb >= size or lane.tb >= B.burst_bytes)
end

local function spend(lane, size)
    local B = M.BUDGET
    lane.tm = math.max(-B.burst_msgs, lane.tm - 1)
    lane.tb = math.max(-B.burst_bytes, lane.tb - size)
end

local function queued(lane) return lane.qt - lane.qh + 1 end

-- Throws away what waits for this connection (it left, world change).
local function drop(lane, why)
    local n = queued(lane)
    if n > 0 then
        M.budget_stats.dropped = M.budget_stats.dropped + n
        log.info("[NET] send budget: %d queued message(s) to %s dropped (%s; %s)", n, lane.name, why,
            kinds_text(lane.ep and lane.ep.kinds or {}))
    end
    lane.q, lane.qh, lane.qt, lane.qbytes, lane.ep = {}, 1, 0, 0, nil
end

-- Is the other game still talking to us? NetConnection.LastReceiveTime is
-- the engine's time of the last packet from it; unchanged for stall_s by our
-- clock = nothing came (sampled every sample_s from the loop).
local function sample(lane, pc, now)
    lane.sampled = now
    local conn = ue.prop(pc, "NetConnection")
    local rt = ue.valid(conn) and ue.prop(conn, "LastReceiveTime") or nil
    if type(rt) ~= "number" then
        if not loop.rt_logged then
            loop.rt_logged = true
            log.info("[NET] send budget: no NetConnection.LastReceiveTime for %s (%s); the budget works without"
                .. " the stall check", lane.name, ue.valid(conn) and type(rt) or "no connection")
        end
        lane.rt_ok, lane.stalled = false, false
        return
    end
    lane.rt_ok = true
    if rt ~= lane.rt then lane.rt, lane.rt_at = rt, now end
    lane.stalled = now - lane.rt_at > M.BUDGET.stall_s
end

local function drain(lane, pc, now)
    local ep = lane.ep
    while lane.qh <= lane.qt and not lane.stalled do
        local e = lane.q[lane.qh]
        local size = #e.msg
        if not fits(lane, size) then break end
        lane.q[lane.qh] = nil
        lane.qh = lane.qh + 1
        lane.qbytes = lane.qbytes - size
        spend(lane, size)
        local waited = now - e.t
        if ep and waited > ep.max_wait then ep.max_wait = waited end
        if waited > M.budget_stats.max_wait then M.budget_stats.max_wait = waited end
        M.budget_stats.sent_late = M.budget_stats.sent_late + 1
        raw_send(pc, lane.to_host, e.kind, e.msg, waited)
    end
    if lane.qh > lane.qt then
        if ep then
            log.info("[NET] send budget: queue to %s drained: %d message(s), %.1f KB, waited up to %.1f s, longest"
                .. " queue %d (%s)", lane.name, ep.n, ep.bytes / 1024, ep.max_wait, ep.peak, kinds_text(ep.kinds))
        end
        lane.q, lane.qh, lane.qt, lane.qbytes, lane.ep = {}, 1, 0, 0, nil
    end
end

local function enqueue(lane, kind, msg, now)
    local B = M.BUDGET
    if queued(lane) == 0 then
        M.budget_stats.episodes = M.budget_stats.episodes + 1
        lane.ep = { n = 0, bytes = 0, max_wait = 0, peak = 0, kinds = {}, next_note = 500 }
        log.info("[NET] send budget: messages to %s wait in a queue from now (%s; first %s, %d B; budget %d msgs /"
            .. " %d KB at once, then %d msgs / %d KB a second; %s never wait)", lane.name,
            lane.stalled and string.format("nothing received from it for %.1f s", now - (lane.rt_at or now))
                or "over the budget", kind, #msg, B.burst_msgs, B.burst_bytes // 1024, B.rate_msgs,
            B.rate_bytes // 1024, "movement, combat, vehicles, session")
    end
    lane.qt = lane.qt + 1
    lane.q[lane.qt] = { kind = kind, msg = msg, t = now }
    lane.qbytes = lane.qbytes + #msg
    local ep = lane.ep
    ep.n, ep.bytes = ep.n + 1, ep.bytes + #msg
    ep.kinds[kind] = (ep.kinds[kind] or 0) + 1
    local n = queued(lane)
    if n > ep.peak then ep.peak = n end
    if n >= ep.next_note then
        ep.next_note = ep.next_note * 2
        log.info("[NET] send budget: %d message(s) (%.0f KB) wait for %s, the oldest %.1f s (%s)", n,
            lane.qbytes / 1024, lane.name, now - lane.q[lane.qh].t, kinds_text(ep.kinds))
    end
    M.budget_stats.queued = M.budget_stats.queued + 1
end

-- The controller a lane sends through right now (nil = gone): the client's
-- own one (same address as when the lane began), or on the host the remote
-- controller of the lane's last send (validity-checked, like the session's
-- records of remote players).
local function lane_pc(lane)
    if lane.to_host then
        local pc = ue.local_pc()
        if pc and addr_of(pc) == lane.pc_addr then return pc end
        return nil
    end
    if ue.valid(lane.pc) then return lane.pc end
    return nil
end

-- Every tick_ms on the game thread: stall samples (while the lane is in use:
-- a queue, or a send in the last IDLE_S), then what the budget lets through;
-- a lane whose controller is gone is dropped with its queue. An idle lane
-- touches no controller.
local IDLE_S = 10
function M.budget_tick()
    local now = os.clock()
    for key, lane in pairs(lanes) do
        local busy = lane.qt >= lane.qh
        if busy or now - lane.last_submit <= IDLE_S then
            local pc = lane_pc(lane)
            if not pc then
                drop(lane, lane.to_host and "the connection to the host changed" or "the player left")
                lanes[key] = nil
            else
                if now - (lane.sampled or -1e9) >= M.BUDGET.sample_s then sample(lane, pc, now) end
                refill(lane, now)
                if busy then drain(lane, pc, now) end
            end
        end
    end
end

local function start_loop()
    if not loop.started then
        loop.started = true
        local ok, err = pcall(ue.every, "net-send", M.BUDGET.tick_ms, M.budget_tick)
        if not ok then log.warn("[NET] send budget: no game-thread loop (%s); queues drain on the next send", tostring(err)) end
    end
    if not loop.hooked_reset then
        local session = package.loaded["sdc_session"]
        if type(session) == "table" and type(session.world_reset_hooks) == "table" then
            loop.hooked_reset = true
            session.world_reset_hooks.net_budget = function(why)
                for key, lane in pairs(lanes) do
                    drop(lane, "world reset: " .. tostring(why))
                    lanes[key] = nil
                end
            end
        end
    end
end

local function lane_for(pc, to_host)
    local a = addr_of(pc)
    local key = to_host and "host" or a
    local lane = lanes[key]
    if lane and to_host and lane.pc_addr ~= a then
        drop(lane, "the connection to the host changed")
        lane = nil
    end
    if not lane then
        local B = M.BUDGET
        lane = { key = key, to_host = to_host, pc_addr = a, name = to_host and "the host" or ue.short(pc),
                 q = {}, qh = 1, qt = 0, qbytes = 0, tm = B.burst_msgs, tb = B.burst_bytes, at = os.clock(),
                 stalled = false }
        lanes[key] = lane
        start_loop()
    end
    if not to_host then lane.pc = pc end   -- the caller's controller: the freshest one
    lane.last_submit = os.clock()
    return lane
end

local function submit(pc, to_host, kind, msg)
    if not budget_on() then return raw_send(pc, to_host, kind, msg, nil) end
    local lane = lane_for(pc, to_host)
    local now = os.clock()
    refill(lane, now)
    if lane.qt >= lane.qh then drain(lane, pc, now) end   -- older messages first
    if NOW[kind] then
        spend(lane, #msg)
        return raw_send(pc, to_host, kind, msg, nil)
    end
    if lane.qt < lane.qh and not lane.stalled and fits(lane, #msg) then
        spend(lane, #msg)
        return raw_send(pc, to_host, kind, msg, nil)
    end
    enqueue(lane, kind, msg, now)
    return true   -- accepted: it goes out in order
end

-- Messages waiting in the send queues (all connections).
function M.queued_count()
    local n = 0
    for _, lane in pairs(lanes) do n = n + queued(lane) end
    return n
end

-- Host -> one client.
function M.send_to(pc, kind, ...)
    if not ue.valid(pc) then return false end
    return submit(pc, false, kind, M.encode(kind, ...))
end

-- Host -> every connected client.
function M.broadcast(remote_pcs, kind, ...)
    for _, pc in ipairs(remote_pcs) do M.send_to(pc, kind, ...) end
end

-- Client -> host.
function M.send_to_host(kind, ...)
    local pc = ue.local_pc()
    if not pc then return false end
    return submit(pc, true, kind, M.encode(kind, ...))
end

-- ---------------------------------------------------------------------------
-- Connection bandwidth (host)
-- ---------------------------------------------------------------------------
-- The engine sends a connection at most CurrentNetSpeed bytes a second
-- (UNetConnection::Tick budgets its QueuedBits with it; a saturated
-- connection is skipped by ServerReplicateActors until the budget refills, so
-- actors further down the priority list - zombies, items, other players - get
-- their updates late: rubber-banding and "teleporting" zombies on the
-- client). The value is the client's [/Script/Engine.Player]
-- ConfiguredInternetSpeed / ConfiguredLanSpeed, sent once at login and
-- clamped to the net driver's MaxClientRate. UE5 ships 100000 (100 KB/s);
-- the game raised MaxClientRate / MaxInternetClientRate to 1e9 but not the
-- speed itself, so every client gets 100 KB/s - a few dozen zombies moving
-- near it use that up. CurrentNetSpeed is a UPROPERTY of UPlayer, the base of
-- UNetConnection: the host sets it on each remote connection (net_speed;
-- 0 = the engine's value). Checked every second (one property read per
-- client); a change is logged with the value before.
M.DEFAULT_NET_SPEED = 500000   -- bytes/s (4 Mbit/s): a cap, not a target
local rates = { conns = {}, driver_logged = false, changes = 0 }

local function log_driver(conn)
    if rates.driver_logged then return end
    local drv = ue.prop(conn, "Driver")
    if not ue.valid(drv) then return end
    rates.driver_logged = true
    log.info("[NET] net driver %s: MaxClientRate=%s MaxInternetClientRate=%s NetServerMaxTickRate=%s MaxNetTickRate=%s "
        .. "ClampListenServerTickRate=%s RelevantTimeout=%s",
        ue.class_name(drv), tostring(ue.prop(drv, "MaxClientRate")), tostring(ue.prop(drv, "MaxInternetClientRate")),
        tostring(ue.prop(drv, "NetServerMaxTickRate")), tostring(ue.prop(drv, "MaxNetTickRate")),
        tostring(ue.prop(drv, "bClampListenServerTickRate")), tostring(ue.prop(drv, "RelevantTimeout")))
end

function M.tune_rates(remote_pcs, want)
    want = tonumber(want)
    if want == nil then want = M.DEFAULT_NET_SPEED end
    want = math.floor(want)
    local seen = {}
    for _, pc in ipairs(remote_pcs or {}) do
        local conn = ue.prop(pc, "NetConnection")
        if ue.valid(conn) then
            log_driver(conn)
            local key = ue.name(conn)
            seen[key] = true
            local cur = ue.prop(conn, "CurrentNetSpeed")
            local r = rates.conns[key]
            if not r then
                r = { first = cur, set = nil }
                rates.conns[key] = r
                log.info("[NET] %s: connection speed %s B/s (the client's ConfiguredInternetSpeed, capped by MaxClientRate)",
                    ue.short(pc), tostring(cur))
            end
            if want >= 2000 and type(cur) == "number" and cur ~= want then
                local ok = ue.set_prop(conn, "CurrentNetSpeed", want)
                local now = ue.prop(conn, "CurrentNetSpeed")
                rates.changes = rates.changes + 1
                if rates.changes <= 20 then
                    log.info("[NET] %s: connection speed %s -> %s B/s (net_speed=%d, ok=%s)%s", ue.short(pc),
                        tostring(cur), tostring(now), want, tostring(ok),
                        r.set and " - something changed it back" or "")
                end
                r.set = now
            end
        end
    end
    for key in pairs(rates.conns) do
        if not seen[key] then rates.conns[key] = nil end
    end
end

-- Client: its own connection to the host, once per connection (diagnostics).
function M.log_client_rate(pc)
    local conn = ue.prop(pc, "NetConnection")
    if not ue.valid(conn) then return end
    local key = ue.name(conn)
    if rates.client_key == key then return end
    rates.client_key = key
    log.info("[NET] client: connection to the host %s, speed %s B/s, driver %s", ue.short(conn),
        tostring(ue.prop(conn, "CurrentNetSpeed")), ue.class_name(ue.prop(conn, "Driver")))
end

function M.install_hooks()
    if M.hooked then return end
    M.hooked = true

    local ok1, e1 = pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, S)
            local raw = ue.str(S and S:get())
            if raw:sub(1, #M.PREFIX) ~= M.PREFIX then return end
            if ue.net_role() ~= "client" then return end
            dispatch("from-host", ctx:get(), raw)
        end)
    end)
    log.info("net: ClientMessage hook %s%s", ok1 and "ok" or "FAILED", ok1 and "" or (" " .. tostring(e1)))

    local ok2, e2 = pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ServerExecRPC", function(ctx, Msg)
            local raw = ue.str(Msg and Msg:get())
            if raw:sub(1, #M.PREFIX) ~= M.PREFIX then return end
            if ue.net_role() ~= "host" then return end
            local pc = ctx:get()
            if not ue.valid(ue.prop(pc, "NetConnection")) then return end
            dispatch("from-client", pc, raw)
        end)
    end)
    log.info("net: ServerExecRPC hook %s%s", ok2 and "ok" or "FAILED", ok2 and "" or (" " .. tostring(e2)))
end

return M
