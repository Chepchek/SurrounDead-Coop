-- SDCoop: in-game self test (config selftest, off by default).
--
-- Two game copies on one PC (host + client joined to 127.0.0.1). The CLIENT
-- plays a scripted scenario that imitates a player through the real game and
-- the real mod code paths; the HOST checks what arrived and answers with its
-- verdict. Both write [SELFTEST] lines to UE4SS.log:
--     [SELFTEST] <step> PASS|FAIL|SKIP <details>
--     [SELFTEST] DONE pass=N fail=M skip=K        (once per side, at the end)
-- tools/ingame_selftest.sh starts both games, starts the run and collects the
-- logs. By hand: config selftest = true on BOTH copies (a restart: nothing is
-- installed while it is off), then on the client a line "selftest=1" in
-- Mods/SDCoop/ui_test.txt (sdc_ui test commands; they need ui_open_at_menu).
--
-- Steps (client driven; every step has a timeout and a host answer):
--   A.hello         handshake: the host has the module and the config on
--   A.rtt.50/1k/3k  30 echoes each, client -> host -> client (4 in flight):
--                   p50 / p95 / max ms, losses, order; the host counts too
--   A.host.50/1k/3k the same started by the host (host -> client -> host)
--   B.burst         the host sends 60 x ~1.2 KB events and right after them one
--                   small answer of a FAST kind: it must not wait behind the
--                   burst (sdc_net FAST); latency and burst time are logged
--   B.snapshot      20 rapid versions of one snapshot key behind a queue: the
--                   client must hold the LAST one and get fewer than 20
--                   (sdc_net SNAPSHOT); SKIP without those registration tables
--   C.chat          a chat line (CHAT of sdc_chat): the host relays it
--   C.weapon        the own pawn's HoldingFirearm? as sdc_pawnstate publishes it
--                   (MYSTATE): the host's copy of the flag
--   C.sprint        after C.walk: Sprinting? held while the pawn walks (the game
--                   clears it standing); SKIP when the pawn could not walk
--   C.crouch        ACharacter::Crouch on the own pawn: the host's copy crouches
--   C.container     the nearest loot container within 10 m: the data request a
--                   player's open sends (RequestServerData): the host has a
--                   viewer for it (sdc_containers)
--   C.markers       local: a BP_QuestMarker and a BP_Marker placed the way the mod places a host's
--                   markers on a client (their MarkerData set before they finish spawning): the
--                   data reads back and their map widgets are built (game layout of 17.11.2026)
--   C.durability    the own equipped items: what the game answers when it runs its
--                   own DurabilityCheck of the melee weapon (GetEquipmentUID ->
--                   GetDurability inside the game) next to the item actor, the
--                   equipped struct and the screen (read only; a whole item must not
--                   read 0; the game's functions are never called with a struct
--                   built here: that crashed UE4SS 4.0.0)
--   C.workbench     a crafting station within 10 m: STABLE (sdc_stations): the
--                   host's recipe count for it
--   C.door          WBDOORQ (the doors' snapshot request of sdc_bdoors): the
--                   host answers; no door is toggled (a door press is the
--                   game's own interaction, the mod has no function for it)
--   C.turn          the control rotation in steps: the host's controller / pawn
--   C.walk          AddMovementInput, forward / right / back / left for 2 s each
--                   until the pawn moved 2 m: the client's position against the
--                   host's copy of the pawn
--   D.frame         worst frame and p99 on each side, the mod's worst call
-- Never touched: inventory contents, saves, the items of a container.
-- Messages (kinds start with STEST; FAST / SNAPSHOT registered in sdc_net's
-- tables where they exist):
--   STEST|REQ|<step>|<handler>|args...                 client -> host
--   STEST|ANS|<step>|PASS/FAIL/SKIP/INFO|text|k=v...   host -> client
--   STEST|PING|<dir>|<tag>|<seq>|<pad>  either way; STEST|ECHO|... comes back
--   STEST|END|pass|fail|skip            client -> host: print the host block
--   STESTB event burst, STESTS snapshot (key = first field), STESTF fast answer.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")

local M = { stats = { runs = 0 } }
local S

local K, KB, KS, KF = "STEST", "STESTB", "STESTS", "STESTF"

local function now() return os.clock() end
local function enabled() return cfg.get("selftest") == true end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function say(step, status, detail)
    log.info("[SELFTEST] %s %s %s", step, status, detail or "")
end

local function pct(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    return sorted[math.max(1, math.min(n, math.ceil(p / 100 * n)))]
end

local function sorted_copy(t)
    local s = {}
    for i = 1, #t do s[i] = t[i] end
    table.sort(s)
    return s
end

local function kv_of(f, from)
    local kv = {}
    for i = from, #f do
        local k, v = tostring(f[i]):match("^([%w_]+)=(.*)$")
        if k then kv[k] = v end
    end
    return kv
end

local function dist3(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function angle_diff(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return math.abs(d)
end

local function norm180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

local function pad(n) return string.rep("x", math.max(0, n)) end

-- ---------------------------------------------------------------------------
-- Frame time and the mod's own worst call (both sides, while a run is on)
-- ---------------------------------------------------------------------------

local FR = { on = false, ds = {}, max = 0, last = nil, registered = false, fn = nil }
local PM = { hook_ms = 0, hook_name = "-", task_ms = 0, task_name = "-" }
local FRAME_FAIL_MS = 250

local function frame()
    if not FR.on then return end
    local t = now()
    if FR.last then
        local d = (t - FR.last) * 1000
        if #FR.ds < 120000 then FR.ds[#FR.ds + 1] = d end
        if d > FR.max then FR.max = d end
    end
    FR.last = t
    local fn = FR.fn
    if fn then
        local ok, err = pcall(fn, t)
        if not ok then
            FR.fn = nil
            log.err_throttled("selftest.frame", "selftest: frame step: %s", tostring(err))
        end
    end
end

local function frames_start()
    FR.on, FR.ds, FR.max, FR.last = true, {}, 0, nil
    PM = { hook_ms = 0, hook_name = "-", task_ms = 0, task_name = "-" }
    if not FR.registered then
        FR.registered = true
        local ok, err = pcall(ue.every_frame, "selftest-frame", frame)
        if not ok then
            FR.registered = false
            log.warn("selftest: no frame loop (%s): frame times are not measured", tostring(err))
        end
    end
end

local function frames_stop()
    FR.on, FR.fn = false, nil
end

local function frame_summary()
    local s = sorted_copy(FR.ds)
    local n, sum = #s, 0
    for i = 1, n do sum = sum + s[i] end
    return { n = n, max = FR.max, p99 = pct(s, 99), avg = n > 0 and sum / n or 0 }
end

-- The mod's own worst single call: sdc_perf's per-window maxima of hooks and
-- sdc_ue's of tasks, sampled (they restart with each [PERF] window; this keeps
-- the largest value seen during the run).
local function perf_sample()
    local perf = package.loaded["sdc_perf"]
    if type(perf) == "table" and type(perf.hooks) == "table" then
        for _, r in pairs(perf.hooks) do
            local w = type(r) == "table" and r.wmax
            if type(w) == "number" and w > PM.hook_ms then PM.hook_ms, PM.hook_name = w, tostring(r.name) end
        end
    end
    if type(ue.task_stats) == "table" then
        for label, r in pairs(ue.task_stats) do
            local w = type(r) == "table" and r.wmax
            if type(w) == "number" and w > PM.task_ms then PM.task_ms, PM.task_name = w, tostring(label) end
        end
    end
end

local function perf_text()
    perf_sample()
    return string.format("mod worst hook %.1f ms (%s), worst task %.1f ms (%s)", PM.hook_ms, PM.hook_name,
        PM.task_ms, PM.task_name)
end

local function frame_text(fs)
    return string.format("frames=%d max=%.1f ms p99=%.1f ms avg=%.1f ms", fs.n, fs.max, fs.p99, fs.avg)
end

-- ---------------------------------------------------------------------------
-- Echo series (either side starts one)
-- ---------------------------------------------------------------------------
-- o = { dir = "c" | "h", tag, size, count, window, msg_timeout, send = fn(op, ...) }

local function new_pinger(o)
    local p = {
        dir = o.dir, tag = o.tag, size = o.size, count = o.count or 30, window = o.window or 4,
        msg_to = o.msg_timeout or 5, send = o.send,
        nxt = 1, sent_at = {}, inflight = {}, nin = 0, rtts = {}, got = 0, lost = 0, ooo = 0, last = 0, done = false,
    }
    p.pad = pad(p.size - 32)
    function p:fill(t)
        while self.nin < self.window and self.nxt <= self.count do
            local seq = self.nxt
            self.nxt = seq + 1
            self.sent_at[seq] = t
            self.inflight[seq] = true
            self.nin = self.nin + 1
            if self.send("PING", self.dir, self.tag, seq, self.pad) == false then
                self.inflight[seq] = nil   -- not sent at all: lost at once
                self.nin = self.nin - 1
                self.lost = self.lost + 1
            end
        end
        if self.nxt > self.count and self.nin == 0 then self.done = true end
    end
    function p:on_echo(seq, t)
        seq = tonumber(seq)
        if not seq or not self.inflight[seq] then return end
        self.inflight[seq] = nil
        self.nin = self.nin - 1
        self.rtts[#self.rtts + 1] = (t - self.sent_at[seq]) * 1000
        self.got = self.got + 1
        if seq < self.last then self.ooo = self.ooo + 1 else self.last = seq end
        self:fill(t)
    end
    function p:tick(t)
        if self.done then return end
        for seq in pairs(self.inflight) do
            if t - self.sent_at[seq] > self.msg_to then
                self.inflight[seq] = nil
                self.nin = self.nin - 1
                self.lost = self.lost + 1
            end
        end
        self:fill(t)
    end
    function p:result()
        local s = sorted_copy(self.rtts)
        return { got = self.got, lost = self.lost, ooo = self.ooo, p50 = pct(s, 50), p95 = pct(s, 95),
                 max = s[#s] or 0 }
    end
    return p
end

local function rtt_text(r)
    return string.format("n=%d lost=%d ooo=%d p50=%.1f p95=%.1f max=%.1f ms", r.got, r.lost, r.ooo, r.p50, r.p95, r.max)
end

local P95_LIMIT_MS = 1000
local BURST_N, BURST_PAD, SNAP_N, SNAP_FILL = 60, 1180, 20, 40

-- a loot container / station of this class near the pawn: the nearest, cm
local function nearest(classes, max_cm, pawn)
    local from = ue.location(pawn)
    local best, bd = nil, nil
    if not from then return nil end
    for _, cls in ipairs(classes) do
        for _, a in ipairs(ue.find_all(cls)) do
            if ue.valid(a) then
                local d = dist3(ue.location(a), from)
                if d and d <= max_cm and (not bd or d < bd) then best, bd = a, d end
            end
        end
    end
    return best, bd
end

local function comp_of(actor) return ue.prop(actor, "BP_JigMultiplayer") end

-- ---------------------------------------------------------------------------
-- Host side
-- ---------------------------------------------------------------------------

local H = { run = nil, tasks = {}, pingers = {}, ping_rcv = {} }
local HOST = {}   -- request handlers: fn(f, pc, reply, step)

local function host_record(step, status, detail)
    local r = H.run
    if r then
        r.results[#r.results + 1] = { step = step, status = status, detail = detail }
        r.count[status] = (r.count[status] or 0) + 1
    end
    say(step, status, "host: " .. tostring(detail))
end

local function host_print_block(why, client_counts)
    local r = H.run
    if not r then return end
    local c = r.count
    log.info("[SELFTEST] ===== host summary (%s) =====", why)
    for _, x in ipairs(r.results) do
        log.info("[SELFTEST] | %-14s | %-4s | %s", x.step, x.status, tostring(x.detail))
    end
    log.info("[SELFTEST] | %-14s | INFO | host %s; %s", "D.frame", frame_text(frame_summary()), perf_text())
    if client_counts then log.info("[SELFTEST] client reports: %s", client_counts) end
    log.info("[SELFTEST] DONE pass=%d fail=%d skip=%d", c.PASS or 0, c.FAIL or 0, c.SKIP or 0)
    pcall(log.flush)
    frames_stop()
    H.run, H.pingers, H.ping_rcv = nil, {}, {}
end

local function reply_of(step, pc)
    local replied = false
    return function(status, text, ...)
        if replied then return end
        replied = true
        if status ~= "INFO" then host_record(step, status, text) end
        net.send_to(pc, K, "ANS", step, status, text or "", ...)
    end
end

local function host_pawn(pc) return ue.valid(pc) and ue.pawn_of(pc) or nil end

HOST.hello = function(f, pc, reply)
    if H.run then host_print_block("a new run started") end
    H.run = { id = f[4] or "?", pc = pc, t0 = now(), last_rx = now(), results = {}, count = {} }
    H.pingers, H.ping_rcv = {}, {}
    frames_start()
    reply("PASS", "selftest on; client run " .. tostring(f[4] or "?") .. ", mod " .. tostring(f[5] or "?"))
end

-- the client's echo series arrived complete and in order?
HOST.check = function(f, pc, reply)
    local tag = f[4] or "?"
    local r = H.ping_rcv[tag] or { n = 0, ooo = 0 }
    if r.n == 30 and r.ooo == 0 then
        reply("PASS", string.format("echoed %d/30 in order (%s)", r.n, tag))
    else
        reply("FAIL", string.format("echoed %d/30, out of order %d (%s)", r.n, r.ooo, tag))
    end
end

-- the host starts an echo series towards the client
HOST.hostping = function(f, pc, reply, step)
    local tag = f[4] or "50"
    local size = ({ ["50"] = 50, ["1k"] = 1024, ["3k"] = 3072 })[tag] or 50
    local p = new_pinger({ dir = "h", tag = tag, size = size,
        send = function(op, ...) return net.send_to(pc, K, op, ...) end })
    H.pingers[#H.pingers + 1] = { p = p, step = step, reply = reply, t0 = now(), tag = tag }
    p:fill(now())
end

local function host_pingers_tick(t)
    for i = #H.pingers, 1, -1 do
        local e = H.pingers[i]
        e.p:tick(t)
        if e.p.done or t - e.t0 > 45 then
            table.remove(H.pingers, i)
            local r = e.p:result()
            local lost = e.p.count - r.got
            local ok = lost == 0 and r.ooo == 0 and r.p95 <= P95_LIMIT_MS
            e.reply(ok and "PASS" or "FAIL", rtt_text(r), "got=" .. r.got, "ooo=" .. r.ooo)
        end
    end
end

local function queued_now() return type(net.queued_count) == "function" and net.queued_count() or -1 end

HOST.burst = function(f, pc, reply)
    local id = f[4] or "?"
    local padding = pad(BURST_PAD)
    local t0 = now()
    for i = 1, BURST_N do net.send_to(pc, KB, id, i, padding) end
    net.send_to(pc, KF, id, "answer")
    reply("PASS", string.format("sent %d x ~%d B + 1 fast answer in %.1f ms; %d queued after", BURST_N, BURST_PAD + 20,
        (now() - t0) * 1000, queued_now()))
end

HOST.snap = function(f, pc, reply)
    local id = f[4] or "?"
    local padding = pad(BURST_PAD)
    for i = 1, SNAP_FILL do net.send_to(pc, KB, id .. "f", i, padding) end
    local sp = pad(600)
    for v = 1, SNAP_N do
        net.send_to(pc, KS, "k1", v, sp)
        if v == SNAP_N // 2 then net.send_to(pc, KS, "k2", 1, sp) end
    end
    net.send_to(pc, KB, id .. "e", 0, "END")   -- bulk, behind the snapshots: the end mark
    reply("PASS", string.format("sent %d fillers, %d versions of k1, 1 of k2, end mark; %d queued after", SNAP_FILL,
        SNAP_N, queued_now()))
end

HOST.chatbase = function(f, pc, reply)
    local chat = package.loaded["sdc_chat"]
    local st = type(chat) == "table" and chat.stats or {}
    reply("INFO", "chat counters", "relayed=" .. tostring(st.relayed or 0), "dropped=" .. tostring(st.dropped or 0))
end

HOST.chat = function(f, pc, reply)
    local chat = package.loaded["sdc_chat"]
    if type(chat) ~= "table" or type(chat.stats) ~= "table" then reply("SKIP", "the host has no sdc_chat") return end
    local r0, d0 = tonumber(f[4]) or 0, tonumber(f[5]) or 0
    local dr, dd = (chat.stats.relayed or 0) - r0, (chat.stats.dropped or 0) - d0
    if dr >= 1 and dd == 0 then
        reply("PASS", string.format("chat line relayed to %d player(s), dropped %d", dr, dd))
    else
        reply("FAIL", string.format("chat line not relayed: relayed +%d, dropped +%d (client not admitted / no CHATON / rate?)", dr, dd))
    end
end

HOST.flags = function(f, pc, reply)
    local key, want = f[4] or "?", f[5] or "?"
    local pawn = host_pawn(pc)
    if not pawn then reply("FAIL", "the host has no pawn for the client") return end
    local ps = package.loaded["sdc_pawnstate"]
    local t = type(ps) == "table" and ps.state_of and ps.state_of(pawn) or nil
    if not t then reply("FAIL", "no published state for the client's pawn (MYSTATE never arrived)") return end
    local got = t[key]
    if got == want then
        reply("PASS", string.format("host holds %s=%s (sp=%s hf=%s cs=%s bs=%s)", key, tostring(got),
            tostring(t.sp), tostring(t.hf), tostring(t.cs), tostring(t.bs)))
    else
        reply("FAIL", string.format("host holds %s=%s, expected %s", key, tostring(got), want))
    end
end

HOST.crouch = function(f, pc, reply)
    local want = f[4] == "1"
    local pawn = host_pawn(pc)
    if not pawn then reply("FAIL", "the host has no pawn for the client") return end
    local got = ue.prop(pawn, "bIsCrouched") == true
    if got == want then
        reply("PASS", "host's copy bIsCrouched=" .. tostring(got))
    else
        reply("FAIL", string.format("host's copy bIsCrouched=%s, expected %s", tostring(got), tostring(want)))
    end
end

HOST.container = function(f, pc, reply)
    local path = f[4] or ""
    local box = ue.find_object(path)
    if not box or not ue.valid(box) then reply("FAIL", "the host has no container at " .. path) return end
    local comp = comp_of(box)
    if not ue.valid(comp) then reply("SKIP", "the host's container has no BP_JigMultiplayer") return end
    local cont = package.loaded["sdc_containers"]
    if type(cont) ~= "table" or type(cont.has_viewers) ~= "function" then
        reply("SKIP", "sdc_containers.has_viewers is missing")
        return
    end
    if cont.has_viewers(comp) == true then
        reply("PASS", "host registered the client as a viewer of " .. ue.short(box))
    else
        reply("FAIL", "host saw no open of " .. ue.short(box) .. " (SERVER_RequestData hook / viewer missing)")
    end
end

-- The container's item list: the same fields the mod reads (sdc_containers).
-- They are declared here, above every user, so they are upvalues, not globals.
local F_ITEMS_SF = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local F_USID_SF = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local F_SLOT_SF = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local F_CONT_SF = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"

local function sf_guid(g)
    -- an FGuid comes as userdata (A-D are read through __index), a string is
    -- taken as it is: a `type(g) ~= "table"` check turned every guid into "",
    -- so the step could never name a grid or an item
    if type(g) == "string" then return g end
    local ok, s = pcall(function() return string.format("%d:%d:%d:%d", g.A or 0, g.B or 0, g.C or 0, g.D or 0) end)
    if ok and s then return s end
    return ""
end

-- Where the host's copy of the item sits now (slot) or nil.
local function sf_item_slot(comp, uid)
    local slot = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if slot then return end
            local x = c:get()
            pcall(function()
                x[F_ITEMS_SF]:ForEach(function(_, iv)
                    local it = iv:get()
                    if sf_guid(it[F_USID_SF]) == uid then slot = tonumber(it[F_SLOT_SF]) or -1 end
                end)
            end)
        end)
    end)
    return slot
end

-- A grid of that inventory with at least two items: the first item is moved
-- onto the slot the second one holds (the game refuses the slot, the mod
-- relocates). Returns { uid, mother, from, to } or nil.
local function sf_find_pair(comp)
    local pair = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if pair then return end
            local x = c:get()
            local list = {}
            pcall(function()
                x[F_ITEMS_SF]:ForEach(function(_, iv)
                    local it = iv:get()
                    list[#list + 1] = { uid_g = it[F_USID_SF], uid = sf_guid(it[F_USID_SF]),
                        slot = tonumber(it[F_SLOT_SF]) or 0 }
                end)
            end)
            if #list >= 2 then
                pair = { uid = list[1].uid, uid_g = list[1].uid_g, mother = x[F_CONT_SF],
                         from = list[1].slot, to = list[2].slot }
            end
        end)
    end)
    return pair
end

-- A fresh character usually holds one item per grid, so there is nothing to
-- move onto an occupied slot. The host then gives the client one more item of
-- a kind it already has, into the same grid: an asset that client shows, and
-- the free slot is picked from the grid's own slot list first, so the grid's
-- capacity is never passed (sdc_consume.place -> GAIN.into_grid refuses a full
-- grid anyway). The item stays in the inventory: the self test run restores
-- the saves afterwards.
local F_INFO_SF = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local F_ITEMID_SF = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_SLOTS_SF = "ContainerSlots_13_97B5C4324E23EC5C1D899EA59CCDD3AC"

local function sf_make_pair(pawn, comp)
    local cs = package.loaded["sdc_consume"]
    if type(cs) ~= "table" or type(cs.place) ~= "function" then
        return nil, "the host has no sdc_consume.place"
    end
    local pick = nil
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            if pick then return end
            local x = c:get()
            local slots, used, first = 0, {}, nil
            pcall(function() x[F_SLOTS_SF]:ForEach(function() slots = slots + 1 end) end)
            pcall(function()
                x[F_ITEMS_SF]:ForEach(function(_, iv)
                    local it = iv:get()
                    local slot = tonumber(it[F_SLOT_SF]) or 0
                    used[slot] = true
                    local info = it[F_INFO_SF]
                    if not first and info then
                        first = { uid = sf_guid(it[F_USID_SF]), slot = slot, da = info[F_ITEMID_SF] }
                    end
                end)
            end)
            if slots > 0 and first then
                local free = nil
                for i = 0, slots - 1 do
                    if not used[i] then free = i break end
                end
                if free then pick = { mother = x[F_CONT_SF], free = free, da = first.da } end
            end
        end)
    end)
    if not pick then return nil, "no grid with a free slot in the client's inventory" end
    if not ue.valid(pick.da) then return nil, "the item in that grid has no data asset on the host" end
    local done, what = nil, nil
    pcall(function()
        done, what = cs.place(pawn, pick.da, 1, { kind = "c", uid = sf_guid(pick.mother), slot = pick.free }, false)
    end)
    if not done then return nil, "the host could not add an item there: " .. tostring(what) end
    local list = {}
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local x = c:get()
            if sf_guid(x[F_CONT_SF]) ~= sf_guid(pick.mother) then return end
            pcall(function()
                x[F_ITEMS_SF]:ForEach(function(_, iv)
                    local it = iv:get()
                    list[#list + 1] = { uid_g = it[F_USID_SF], uid = sf_guid(it[F_USID_SF]),
                        slot = tonumber(it[F_SLOT_SF]) or 0 }
                end)
            end)
        end)
    end)
    if #list < 2 then
        return nil, string.format("an item was added, but that grid still shows %d item(s)", #list)
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    return { uid = list[1].uid, uid_g = list[1].uid_g, mother = pick.mother,
             from = list[1].slot, to = list[2].slot,
             made = true, added_slot = pick.free, what = tostring(what) }
end

-- The host runs the move itself on the client's copy: the same 6 arguments the
-- client's click sends, and the same handler answers it (a move of the host's
-- own character is not a remote one, so that path would be rejected before the
-- handler). With a grid that holds one item the host adds a second one first
-- (see sf_make_pair); otherwise the items only change slots.
HOST.relocate = function(f, pc, reply)
    local cont = package.loaded["sdc_containers"]
    if type(cont) ~= "table" or type(cont.stats) ~= "table" then reply("SKIP", "the host has no sdc_containers") return end
    if cfg.get("container_relocate") ~= true then reply("SKIP", "container_relocate is off on the host") return end
    local pawn = host_pawn(pc)
    local comp = pawn and comp_of(pawn)
    if not ue.valid(comp) then reply("FAIL", "the client has no character on the host") return end
    local pair = sf_find_pair(comp)
    local made = nil
    if not pair then
        pair, made = sf_make_pair(pawn, comp)
        if not pair then
            reply("SKIP", "no grid to test the move on: " .. tostring(made))
            return
        end
    end
    local st = cont.stats
    local r0, f0 = st.relocated or 0, st.failed_sent or 0
    local ok, err = pcall(function()
        comp:SERVER_SameContainer_MoveToIndex(comp, pair.uid_g, pair.mother, pair.to, false, pair.from)
    end)
    if not ok then reply("FAIL", "the game's move call failed: " .. tostring(err)) return end
    local slot, now_relocated = sf_item_slot(comp, pair.uid), (st.relocated or 0) - r0
    local prep = pair.made and string.format(" (a second item was added to that grid, slot %s: %s)", tostring(pair.added_slot),
        tostring(pair.what)) or ""
    if now_relocated > 0 and slot and slot ~= pair.to and slot ~= pair.from then
        reply("PASS", string.format("item %s went from slot %d to the free slot %d instead of %d (relocated %d)%s",
            pair.uid, pair.from, slot, pair.to, st.relocated, prep))
    elseif (st.failed_sent or 0) > f0 then
        reply("FAIL", "the host refused the move instead of relocating it (the relocate branch was not reached)" .. prep)
    elseif slot == pair.from or slot == nil then
        reply("FAIL", string.format("the item did not move (slot %s, relocated %d, failed_sent %d)%s", tostring(slot),
            st.relocated or 0, st.failed_sent or 0, prep))
    else
        reply("FAIL", string.format("the item went to slot %d, which is neither free nor the refused one%s", slot, prep))
    end
end

HOST.ground_take = function(f, pc, reply)
    local w = package.loaded["sdc_world"]
    if type(w) ~= "table" or type(w.stats) ~= "table" then reply("SKIP", "the host has no sdc_world") return end
    if cfg.get("ground_take") ~= true then reply("SKIP", "ground_take is off on the host") return end
    local want = tostring(f[4] or "")
    local x, y, z = tostring(f[5] or ""):match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not x or want == "" then reply("FAIL", "bad request (item or location)") return end
    local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
    local left = 0
    for _, cls in ipairs({ "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }) do
        for _, a in ipairs(ue.find_all(cls) or {}) do
            local da = ue.prop(ue.prop(a, "BP_JigPickupComponent"), "ItemDataAsset")
            if ue.valid(da) and ue.path(da) == want then
                local l = ue.location(a)
                if l then
                    local dx, dy, dz = l.X - px, l.Y - py, l.Z - pz
                    if dx * dx + dy * dy + dz * dz <= 350 * 350 then left = left + 1 end
                end
            end
        end
    end
    local taken = w.stats.ground_taken or 0
    if taken > 0 and left == 0 then
        reply("PASS", string.format("host took the ground pickup %s (ground_taken=%d, nothing of it left there)", want, taken))
    elseif left > 0 then
        reply("FAIL", string.format("the host still has %d pickup(s) %s there (ground_taken=%d)", left, want, taken))
    else
        reply("SKIP", "no ask reached the host (ground_take off, or no such pickup here)")
    end
end

HOST.workbench = function(f, pc, reply)
    local path, want_t = f[4] or "", tonumber(f[5]) or 0
    local st = ue.find_object(path)
    if not st or not ue.valid(st) then reply("FAIL", "the host has no station at " .. path) return end
    local comp = comp_of(st)
    if not ue.valid(comp) then reply("FAIL", "the host's station has no BP_JigMultiplayer") return end
    local n = ue.try(function() return comp.ItemsToCraft:GetArrayNum() end)
    if type(n) == "number" and n > 0 then
        reply("PASS", string.format("host's %s has %d recipe(s) after STABLE %d", ue.short(st), n, want_t))
    else
        reply("FAIL", string.format("host's %s has %s recipes after STABLE %d (stations_on_host off?)", ue.short(st),
            tostring(n), want_t))
    end
end

HOST.doorbase = function(f, pc, reply)
    local bd = package.loaded["sdc_bdoors"]
    local st = type(bd) == "table" and bd.stats or {}
    reply("INFO", "door counters", "snaps=" .. tostring(st.snaps or 0))
end

HOST.door = function(f, pc, reply)
    local bd = package.loaded["sdc_bdoors"]
    if type(bd) ~= "table" or type(bd.stats) ~= "table" then reply("SKIP", "the host has no sdc_bdoors") return end
    local s0, s1 = tonumber(f[4]) or 0, bd.stats.snaps or 0
    if s1 > s0 then
        reply("PASS", string.format("host answered WBDOORQ (snapshots %d -> %d)", s0, s1))
    else
        reply("FAIL", string.format("host did not answer WBDOORQ (snapshots %d -> %d; world_build_doors off?)", s0, s1))
    end
end

HOST.turn = function(f, pc, reply)
    local yaw0, want = tonumber(f[4]), tonumber(f[5])
    if not yaw0 or not want then reply("FAIL", "bad turn request") return end
    local cr = ue.valid(pc) and ue.try(function() return pc:GetControlRotation() end)
    local cy = cr and ue.try(function() return cr.Yaw end)
    local pawn = host_pawn(pc)
    local py = pawn and ue.rotation(pawn).Yaw or nil
    local cd = type(cy) == "number" and angle_diff(cy, want) or nil
    local pd = type(py) == "number" and angle_diff(py, want) or nil
    local text = string.format("start yaw %.0f, wanted %.0f; host controller yaw %s (off %s), pawn yaw %s (off %s)", yaw0, want,
        type(cy) == "number" and string.format("%.0f", cy) or "?", cd and string.format("%.0f", cd) or "?",
        type(py) == "number" and string.format("%.0f", py) or "?", pd and string.format("%.0f", pd) or "?")
    if (cd and cd <= 10) or (pd and pd <= 15) then reply("PASS", text) else reply("FAIL", text) end
end

HOST.pos = function(f, pc, reply)
    local cx, cy, cz, moved = tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7]) or 0
    local pawn = host_pawn(pc)
    local loc = pawn and ue.location(pawn)
    if not loc then reply("FAIL", "the host has no pawn / position for the client") return end
    local d = dist3(loc, { X = cx or 0, Y = cy or 0, Z = cz or 0 })
    local text = string.format("client at %.0f,%.0f,%.0f; host copy at %.0f,%.0f,%.0f; off by %.0f cm; client moved %.0f cm",
        cx or 0, cy or 0, cz or 0, loc.X, loc.Y, loc.Z, d or -1, moved)
    if moved < 30 then
        reply("SKIP", "the client's pawn did not move (input blocked?): " .. text)
    elseif d and d <= 150 then
        reply("PASS", text)
    else
        reply("FAIL", text)
    end
end

HOST.frame = function(f, pc, reply)
    local fs = frame_summary()
    reply(fs.max > FRAME_FAIL_MS and "FAIL" or "PASS", frame_text(fs) .. "; " .. perf_text(),
        string.format("max=%.1f", fs.max), string.format("p99=%.1f", fs.p99))
end

local function on_req(f, pc)
    local step, kind = f[2] or "?", f[3] or "?"
    local reply = reply_of(step, pc)
    if H.run then H.run.last_rx = now() end
    local fn = HOST[kind]
    if not fn then reply("FAIL", "unknown request " .. kind) return end
    local ok, err = pcall(fn, f, pc, reply, step)
    if not ok then reply("FAIL", "host error: " .. tostring(err)) end
end

-- Selftest mode only, host: every player character cannot be hurt, so the
-- run does not depend on what stands near the saved position. The game's
-- damage event (BP_PlayerCharacter, pseudo @137699) returns at once when
-- MedicalComponent.CanTakeDamage? is false (or the Debug.Invincibility cvar,
-- which sdc_admin guards); bCanBeDamaged = false (AActor) stops the engine's
-- damage as well. Nothing is saved; both are runtime values only.
local GOD_EVERY_S = 1
local god_logged = false
local function god_tick(t)
    if t - (H.god_at or -1e9) < GOD_EVERY_S then return end
    H.god_at = t
    local n = 0
    for _, p in ipairs(ue.find_all("BP_PlayerCharacter_C")) do
        if ue.valid(p) and ue.prop(p, "PlayerDead?") ~= true then
            ue.set_prop(p, "bCanBeDamaged", false)
            local med = ue.prop(p, "MedicalComponent")
            if ue.valid(med) then ue.set_prop(med, "CanTakeDamage?", false) end
            n = n + 1
        end
    end
    if not god_logged and n > 0 then
        god_logged = true
        log.info("[SELFTEST] host: %d player character(s) made invulnerable (bCanBeDamaged=false + MedicalComponent.CanTakeDamage?=false, every %d s while selftest is on)", n, GOD_EVERY_S)
    end
end

local function host_tick(t)
    god_tick(t)
    if H.run then
        host_pingers_tick(t)
        if t - H.run.last_rx > 90 then host_print_block("the client went quiet for 90 s") end
    end
end

-- ---------------------------------------------------------------------------
-- Client side: the steps
-- ---------------------------------------------------------------------------

local C = { run = nil, want_start = nil, hping = {}, pingers = {} }
local VERSION_TEXT = "?"

local function ask(st, step, kind, ...)
    return net.send_to_host(K, "REQ", step, kind, ...)
end

local function ans(step) return C.run and C.run.ans[step] end

local function local_pawn() return ue.local_pawn() end

local function rtt_step(tag, size)
    local name = "A.rtt." .. tag
    return {
        name = name, timeout = 45,
        start = function(st)
            st.waiting = "echoes from the host"
            st.p = new_pinger({ dir = "c", tag = tag, size = size,
                send = function(op, ...) return net.send_to_host(K, op, ...) end })
            C.pingers[tag] = st.p
            st.p:fill(now())
        end,
        poll = function(st, t)
            st.p:tick(t)
            if st.p.done and not st.checked then
                st.checked = true
                st.waiting = "the host's count of the echoes"
                ask(st, "A.check." .. tag, "check", tag)
            end
            local a = ans("A.check." .. tag)
            if a then
                local r = st.p:result()
                local ok = r.lost == 0 and r.ooo == 0 and r.p95 <= P95_LIMIT_MS and a.status == "PASS"
                return ok and "PASS" or "FAIL", rtt_text(r) .. "; host: " .. tostring(a.text)
            end
        end,
        cleanup = function() C.pingers[tag] = nil end,
    }
end

local function hostping_step(tag)
    local name = "A.host." .. tag
    return {
        name = name, timeout = 60,
        start = function(st)
            st.waiting = "the host's echo series"
            C.hping[tag] = { n = 0, ooo = 0, last = 0 }
            ask(st, name, "hostping", tag)
        end,
        poll = function(st)
            local a = ans(name)
            if not a then return end
            local h = C.hping[tag]
            local ok = a.status == "PASS" and h.n == 30 and h.ooo == 0
            return ok and "PASS" or "FAIL", string.format("host: %s; client saw %d/30 pings, out of order %d",
                tostring(a.text), h.n, h.ooo)
        end,
    }
end

local function burst_step()
    return {
        name = "B.burst", timeout = 40,
        start = function(st)
            st.waiting = "the burst and the fast answer"
            local id = C.run.id .. "b"
            C.b = { id = id, t0 = now(), n = 0, total = 0, ooo = 0, seq = 0 }
            ask(st, "B.burst", "burst", id)
        end,
        poll = function(st, t)
            local b = C.b
            local a = ans("B.burst")
            local complete = b.ans_t and b.n >= BURST_N and a
            local stale = b.ans_t and a and t - math.max(b.last_t or 0, b.ans_t) > 6
            if not complete and not stale then return end
            local lost = BURST_N - b.n
            local burst_ms = b.last_t and (b.last_t - b.t0) * 1000 or -1
            local ans_ms = (b.ans_t - b.t0) * 1000
            local text = string.format("burst %d/%d lost=%d ooo=%d first=%.0f ms last=%.0f ms; answer at %.0f ms, arrival #%s of %d",
                b.n, BURST_N, lost, b.ooo, b.first_t and (b.first_t - b.t0) * 1000 or -1, burst_ms, ans_ms,
                tostring(b.ans_pos), b.total)
            if a.status ~= "PASS" then return "FAIL", text .. "; host: " .. tostring(a.text) end
            if lost > 0 then return "FAIL", text .. " - burst messages lost" end
            if b.ooo > 0 then return "FAIL", text .. " - burst out of order" end
            if type(net.FAST) ~= "table" then return "PASS", text .. " (sdc_net has no FAST table: lane not checked)" end
            if burst_ms < 300 then return "PASS", text .. " (the burst was not queued: lane not exercised)" end
            if b.ans_pos < b.total then return "PASS", text .. " (the fast answer overtook the queue)" end
            return "FAIL", text .. " - the fast answer waited behind the whole burst"
        end,
    }
end

local function snapshot_step()
    return {
        name = "B.snapshot", timeout = 50,
        start = function(st)
            if type(net.SNAPSHOT) ~= "table" or type(net.FAST) ~= "table" then
                return "SKIP", "sdc_net has no SNAPSHOT / FAST registration table yet"
            end
            st.waiting = "the snapshot versions and the end mark"
            local id = C.run.id .. "s"
            C.s = { id = id, k1 = { n = 0, last = 0 }, k2 = { n = 0, last = 0 }, ooo = 0 }
            ask(st, "B.snapshot", "snap", id)
        end,
        poll = function(st, t)
            local s, a = C.s, ans("B.snapshot")
            if not s.endt or t - s.endt < 0.7 or not a then return end   -- a moment for stragglers
            local text = string.format("k1: %d of %d versions delivered, last=%d; k2: %d delivered; %d fillers ahead",
                s.k1.n, SNAP_N, s.k1.last, s.k2.n, SNAP_FILL)
            if a.status ~= "PASS" then return "FAIL", text .. "; host: " .. tostring(a.text) end
            if s.k1.last ~= SNAP_N then return "FAIL", text .. " - the client does not hold the LAST version" end
            if s.k1.n >= SNAP_N then return "FAIL", text .. " - nothing was coalesced" end
            if s.k2.n < 1 then return "FAIL", text .. " - the other key was swallowed" end
            return "PASS", text
        end,
    }
end

local function chat_step()
    return {
        name = "C.chat", timeout = 20,
        start = function(st)
            local chat = package.loaded["sdc_chat"]
            if type(chat) ~= "table" or type(chat.stats) ~= "table" then return "SKIP", "sdc_chat is not loaded" end
            if cfg.get("chat") == false then return "SKIP", "config chat is off" end
            st.shown0 = chat.stats.shown or 0
            st.waiting = "the host's chat counters"
            ask(st, "C.chat.base", "chatbase")
        end,
        poll = function(st, t)
            local chat = package.loaded["sdc_chat"]
            local base = ans("C.chat.base")
            if base and not st.sent_chat then
                st.sent_chat = t
                st.r0, st.d0 = base.kv.relayed or "0", base.kv.dropped or "0"
                net.send_to_host("CHAT", "selftest" .. tostring(C.run.id))
                st.waiting = "the chat line to reach the host"
            end
            if st.sent_chat and not st.asked_end and t - st.sent_chat > 1.5 then
                st.asked_end = true
                ask(st, "C.chat", "chat", st.r0, st.d0)
            end
            local a = ans("C.chat")
            if a then
                local back = (chat.stats.shown or 0) > st.shown0
                return a.status, string.format("host: %s; copy back in the client's feed: %s", tostring(a.text), back and "yes" or "no")
            end
        end,
    }
end

-- a flag of the own pawn that sdc_pawnstate publishes (Sprinting?, HoldingFirearm?)
local function flag_step(name, prop, key)
    return {
        name = name, timeout = 20,
        start = function(st)
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            local orig = ue.prop(pawn, prop)
            if type(orig) ~= "boolean" then return "SKIP", "the pawn has no boolean " .. prop end
            st.pawn, st.orig = pawn, orig
            ue.set_prop(pawn, prop, not orig)
            st.t_set, st.ph = now(), 1
            st.waiting = "MYSTATE to reach the host"
        end,
        poll = function(st, t)
            if st.ph == 1 and t - st.t_set > 1.4 then
                st.ph = 2
                ask(st, name, "flags", key, st.orig and "0" or "1")
            elseif st.ph == 2 then
                local a = ans(name)
                if a then
                    st.first = a
                    if a.status ~= "PASS" then return "FAIL", "set: " .. tostring(a.text) end
                    if ue.valid(st.pawn) then ue.set_prop(st.pawn, prop, st.orig) end
                    st.ph, st.t_set = 3, t
                    st.waiting = "the flag to go back on the host"
                end
            elseif st.ph == 3 and t - st.t_set > 1.4 then
                st.ph = 4
                ask(st, name .. ".off", "flags", key, st.orig and "1" or "0")
            elseif st.ph == 4 then
                local a = ans(name .. ".off")
                if a then
                    if a.status == "PASS" then return "PASS", "set: " .. tostring(st.first.text) .. "; restored: " .. tostring(a.text) end
                    return "FAIL", "restore: " .. tostring(a.text)
                end
            end
        end,
        cleanup = function(st)
            if st.pawn and st.orig ~= nil and ue.valid(st.pawn) then ue.set_prop(st.pawn, prop, st.orig) end
        end,
    }
end

local function crouch_step()
    return {
        name = "C.crouch", timeout = 20,
        start = function(st)
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            st.pawn = pawn
            local ok, err = ue.call(pawn, "Crouch", false)
            if not ok then return "SKIP", "Crouch failed: " .. tostring(err) end
            st.t_set, st.ph = now(), 1
            st.waiting = "the pawn to crouch"
        end,
        poll = function(st, t)
            if st.ph == 1 and t - st.t_set > 1.2 then
                if ue.prop(st.pawn, "bIsCrouched") ~= true then return "SKIP", "the pawn did not crouch locally (Crouch is not the game's path?)" end
                st.ph = 2
                ask(st, "C.crouch", "crouch", "1")
            elseif st.ph == 2 then
                local a = ans("C.crouch")
                if a then
                    st.first = a
                    ue.call(st.pawn, "UnCrouch", false)
                    if a.status ~= "PASS" then return "FAIL", "crouched: " .. tostring(a.text) end
                    st.ph, st.t_set = 3, t
                    st.waiting = "the pawn to stand up"
                end
            elseif st.ph == 3 and t - st.t_set > 1.2 then
                st.ph = 4
                ask(st, "C.crouch.off", "crouch", "0")
            elseif st.ph == 4 then
                local a = ans("C.crouch.off")
                if a then
                    if a.status == "PASS" then return "PASS", "crouched: " .. tostring(st.first.text) .. "; stood up: " .. tostring(a.text) end
                    return "FAIL", "stand up: " .. tostring(a.text)
                end
            end
        end,
        cleanup = function(st)
            if st.pawn and ue.valid(st.pawn) then ue.call(st.pawn, "UnCrouch", false) end
        end,
    }
end

local function container_step()
    return {
        name = "C.container", timeout = 15,
        start = function(st)
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            local box, d = nearest({ "BP_LootContainer_C" }, 1000, pawn)
            if not box then return "SKIP", "no loot container within 10 m of the client" end
            local comp = comp_of(box)
            if not ue.valid(comp) then return "SKIP", ue.short(box) .. " has no BP_JigMultiplayer" end
            local ok, err = ue.call(pawn, "RequestServerData", comp, {})
            if not ok then return "SKIP", "RequestServerData failed: " .. tostring(err) end
            st.box, st.d, st.t_set = box, d, now()
            st.waiting = "the host to see the open"
        end,
        poll = function(st, t)
            if not st.asked and t - st.t_set > 1.5 then
                st.asked = true
                ask(st, "C.container", "container", ue.path(st.box))
            end
            local a = ans("C.container")
            if a then
                return a.status, string.format("%s at %.1f m, data request sent (the container's items are not touched; no window"
                    .. " is opened, so nothing to close); host: %s", ue.short(st.box), (st.d or 0) / 100, tostring(a.text))
            end
        end,
    }
end

-- A real move onto a slot another item holds: the client asks the host, the host
-- runs the move itself (the same 6 arguments a client's click sends) and the
-- mod's handler has to put the item into a free slot instead of refusing it.
local function relocate_step()
    return {
        name = "C.relocate", timeout = 25,
        start = function(st)
            if cfg.get("container_relocate") ~= true then return "SKIP", "container_relocate is off" end
            st.t_set, st.waiting = now(), "the host to move an item onto an occupied slot"
            ask(st, "C.relocate", "relocate")
        end,
        poll = function(st, t)
            local a = ans("C.relocate")
            if a then
                return a.status, "host: " .. tostring(a.text)
            end
            if t - st.t_set > 20 then return "FAIL", "no answer from the host in 20 s" end
        end,
    }
end

-- A real ground pickup: the client sends the ask the build does (GTAKE), the host takes it.
local function ground_take_step()
    return {
        name = "C.ground_take", timeout = 20,
        start = function(st)
            if cfg.get("ground_take") ~= true then return "SKIP", "ground_take is off" end
            local w = package.loaded["sdc_world"]
            if type(w) ~= "table" or type(w.ask_ground_take) ~= "function" then
                return "SKIP", "sdc_world.ask_ground_take is missing"
            end
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            local pr, d = nearest({ "BP_StaticMeshPickup_C", "BP_SkeletalMeshPickup_C" }, 1000, pawn)
            if not pr then return "SKIP", "no pickup on the ground within 10 m" end
            local da = ue.prop(ue.prop(pr, "BP_JigPickupComponent"), "ItemDataAsset")
            if not ue.valid(da) then return "SKIP", "the pickup has no ItemDataAsset" end
            local loc = ue.location(pr)
            if not loc then return "SKIP", "the pickup has no location" end
            st.da = ue.path(da)
            st.loc = string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z)
            st.d = d
            w.ask_ground_take(pr)
            st.t_set, st.waiting = now(), "the host to take the pickup"
        end,
        poll = function(st, t)
            if not st.asked and t - st.t_set > 1.2 then
                st.asked = true
                ask(st, "C.ground_take", "ground_take", st.da, st.loc)
            end
            local a = ans("C.ground_take")
            if a then
                return a.status, string.format("%s at %.1f m, the client sent the ask; host: %s", st.da,
                    (st.d or 0) / 100, tostring(a.text))
            end
        end,
    }
end

local STATION_TABLE = { BP_CraftingStation_C = 1, Buildable_CraftingWorkbench_C = 1, BP_CookingStation_C = 2 }

-- C.durability (read only): the sources of the own equipment's durability, side by side.
-- The game asks BP_JigHelperComp.GetEquipmentUID(slot) for a UID and BP_JigMultiplayer.GetDurability(UID)
-- for the number (a melee swing, a gun, the fishing rod) and shows "Item durability too low" on a 0. On a
-- client that 0 came with a WHOLE item (the screen showed 95 %). sdc_items answers it with a number from
-- the item actor, the equipped struct or the screen. This step lets the game ask by itself
-- (BP_MeleePickup.DurabilityCheck) and puts every source next to its answer. Verdict: the answer must not
-- be 0 while the item is whole. Which source is right on a real client (is ServerEquippedItems filled
-- there at all? 17.11 review: the dump gives it no REPL flag) is what the other numbers are for.
-- Nothing is written.
local DUR_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local DUR_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local DUR_FIELD = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local DUR_STRUCT = {   -- BP_JigHelperComp.ServerEquippedItems fields of the weapon slots (as sdc_items reads them)
    ["Jig.PlayerSlot.MeleeWeapon"] = "EquippedMelee_48_0C451F654720DD3648581EA9DB6E85D0",
    ["Jig.PlayerSlot.PrimaryWeapon"] = "EquippedPrimary_43_71FDAE8F453FE0DADB6317949C57DDCF",
    ["Jig.PlayerSlot.SecondaryWeapon"] = "EquippedSecondary_44_06F9E8664A16E6584B9772A436A872B0",
    ["Jig.PlayerSlot.SidearmWeapon"] = "EquippedSidearm_45_DBAF50604B799AD8D36966B58FC8D116",
}
local DUR_ROWS_MAX = 8

-- A line on disk before every read / call that goes into the game's structs: a UE4SS access violation
-- kills the process and the batched log with it (17.11: the first run of this step crashed the client).
local function dur_trace(what)
    log.info("[SELFTEST] C.durability trace: %s", what)
    pcall(log.flush)
end

local function dur_num(f)
    local n = ue.try(f)
    if type(n) == "number" then return n end
    return nil
end

local function dur_guid(g)
    if g == nil then return nil end
    return ue.try(function() return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end)
end

local function dur_row(helper, jig, view, tag, actor)
    local r = { tag = tag, name = tag:match("([%w_]+)$") or tag }
    dur_trace(r.name .. ": PickupInfo of the item actor")
    local pu = ue.prop(actor, "BP_JigMultiplayer")
    local pi = ue.valid(pu) and ue.try(function() return pu.PickupInfo end) or nil
    local info = pi and ue.try(function() return pi[DUR_INFO] end) or nil
    local d = info and ue.try(function() return info[DUR_FIELD] end) or nil
    r.actor_uid = pi and dur_guid(ue.try(function() return pi[DUR_USID] end)) or nil
    r.actor = d and dur_num(function() return tonumber(d.X) end) or nil
    r.actor_max = d and dur_num(function() return tonumber(d.Y) end) or nil
    dur_trace(r.name .. ": the equipped struct (ServerEquippedItems)")
    local field = DUR_STRUCT[tag]
    local si = field and ue.try(function() return helper.ServerEquippedItems[field] end) or nil
    local sd = si and ue.try(function() return si[DUR_FIELD] end) or nil
    r.struct = sd and dur_num(function() return tonumber(sd.X) end) or nil
    local e = view and r.actor_uid and view[r.actor_uid] or nil
    r.screen = e and e.slot and dur_num(function() return tonumber(e.slot.Dur) end) or nil
    -- The game's own path, run by the game: BP_MeleePickup.DurabilityCheck(Dmg) asks GetEquipmentUID(melee slot) and
    -- GetDurability(that UID) by itself and gives back Dmg * (durability / 100) ^ 0.225 (the difficulty's
    -- MeleeDmgDegradation on; off: Dmg back), so its number is the game's answer with our hooks in it and no
    -- struct is built here. A Lua call of GetEquipmentUID itself (a GameplayTag table in, an FGuid table out)
    -- crashed the client in UE4SS 4.0.0 on 17.11 (access violation, nothing after it): never again.
    if tag == "Jig.PlayerSlot.MeleeWeapon" then
        local o = {}
        local items = package.loaded["sdc_items"]
        local calls0 = type(items) == "table" and type(items.stats) == "table" and items.stats.dur_calls or 0
        dur_trace(r.name .. ": call DurabilityCheck(100) on the item actor")
        local okc, errc = ue.call(actor, "DurabilityCheck", 100.0, o)
        -- UE4SS does not run a hook inside a call that Lua made (a hook that calls its own function would never end):
        -- then the number is the game's RAW answer, without sdc_items' correction, and says nothing about the fix.
        r.hook_ran = type(items) == "table" and type(items.stats) == "table" and (items.stats.dur_calls or 0) > calls0
        if okc then
            local nd = dur_num(function() return tonumber(o.NewDmg) end)
            if nd ~= nil then
                r.newdmg = nd
                r.game = nd <= 0.0001 and 0 or 100 * (nd / 100) ^ (1 / 0.225)
            end
        else
            r.err = "DurabilityCheck: " .. tostring(errc)
        end
    end
    return r
end

-- The verdict of one row: "FAIL" (a whole item read as broken), "PASS", or nil (cannot tell).
local function dur_row_verdict(r)
    local ref = r.host or r.screen or r.actor or r.struct   -- the host's own number first, then what the player sees
    if type(r.game) ~= "number" or type(ref) ~= "number" then return nil end
    if not r.hook_ran then return nil end   -- the raw answer of the game: not a verdict on sdc_items
    if ref > 0 and r.game < 0.5 then return "FAIL" end
    if ref > 0 and r.game >= 0.5 then return "PASS" end
    if ref <= 0 and r.game < 0.5 then return "PASS" end   -- a really broken item stays broken
    return nil
end

local function dur_fmt(v, max)
    if type(v) ~= "number" then return "-" end
    if type(max) == "number" and max > 0 then return string.format("%.1f/%.0f", v, max) end
    return string.format("%.1f", v)
end

-- Rows for the equipped item actors of the own pawn, or nil, why.
local function dur_rows()
    local me = local_pawn()
    if not me then return nil, "no own pawn" end
    local helper, jig = ue.prop(me, "BP_JigHelperComp"), comp_of(me)
    if not ue.valid(helper) or not ue.valid(jig) then return nil, "the pawn has no BP_JigHelperComp / BP_JigMultiplayer" end
    local items = package.loaded["sdc_items"]
    if type(items) ~= "table" or type(items.equipped_of) ~= "function" then return nil, "sdc_items.equipped_of is missing" end
    local consume = package.loaded["sdc_consume"]
    local view = nil
    if type(consume) == "table" and type(consume.client_view) == "function" then
        dur_trace("the screen (sdc_consume.client_view)")
        local ok, v = pcall(consume.client_view, jig)
        if ok and type(v) == "table" then view = v end
    end
    local list = {}
    for _, e in pairs(items.equipped_of(me)) do
        if e.slot and e.slot ~= "" and ue.valid(e.actor) then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    local rows = {}
    for i = 1, math.min(#list, DUR_ROWS_MAX) do rows[i] = dur_row(helper, jig, view, list[i].slot, list[i].actor) end
    return rows, nil, view ~= nil
end

-- The verdict and the line of the step, once the client's own numbers (and the host's, when it answered) are in.
local function dur_result(rows, have_view, a)
    local fails, passes, parts = 0, 0, {}
    for _, r in ipairs(rows) do
        r.host = a and a.kv and tonumber(a.kv[r.name:lower()]) or nil
        local v = dur_row_verdict(r)
        if v == "FAIL" then fails = fails + 1 elseif v == "PASS" then passes = passes + 1 end
        parts[#parts + 1] = string.format("%s: game %s%s | host %s | screen %s | actor %s | struct %s%s%s", r.name,
            dur_fmt(r.game), (r.newdmg and string.format(" (NewDmg %.1f of 100%s)", r.newdmg, r.hook_ran and "" or ", raw: the mod's hook did not run in a call from Lua") or ""),
            dur_fmt(r.host), dur_fmt(r.screen), dur_fmt(r.actor, r.actor_max), dur_fmt(r.struct),
            v and (" -> " .. v) or "", r.err and (" [" .. r.err .. "]") or "")
    end
    local items = package.loaded["sdc_items"]
    local s = type(items) == "table" and type(items.stats) == "table" and items.stats or {}
    local counters = string.format(" || mod: uid_filled=%s from_slot=%s from_screen=%s from_actor=%s no_data=%s; screen read: %s; host: %s"
        .. "; hooks: GetDurability x%s (last: %s), GetEquipmentUID x%s (last: %s)",
        tostring(s.uid_filled), tostring(s.dur_from_slot), tostring(s.dur_from_ui), tostring(s.dur_restored),
        tostring(s.dur_no_data), have_view and "yes" or "no", a and (a.text ~= "" and a.text or "no items") or "no answer",
        tostring(s.dur_calls), tostring(s.dur_last), tostring(s.equid_calls), tostring(s.equid_last))
    local text = table.concat(parts, " || ") .. counters
    if fails > 0 then return "FAIL", text end
    if passes > 0 then return "PASS", text end
    return "SKIP", "no verdict (no reference number, or the answer is the game's raw one - the mod's hook does not run inside a call "
        .. "made from Lua; swing the knife / shoot as a client and read the 'GetDurability call' lines of the log): " .. text
end

local function durability_step()
    return {
        name = "C.durability", timeout = 12,
        start = function(st)
            local rows, why, have_view = dur_rows()
            if not rows then return "SKIP", why end
            if #rows == 0 then return "SKIP", "no equipped item actor (RepActorsData lists no slot)" end
            st.rows, st.have_view, st.t_set = rows, have_view, now()
            st.waiting = "the host's own durability of the client's equipped items"
            ask(st, "C.durability", "durability")
        end,
        poll = function(st, t)
            local a = ans("C.durability")
            if not a and t - st.t_set < 6 then return end
            return dur_result(st.rows, st.have_view, a)   -- (no answer in 6 s: the client's numbers alone)
        end,
    }
end

-- Host: the durability of every equipped item actor of the client's character on the HOST (the server's actors
-- carry the number the game really drains). Informational: the client sets the verdict.
HOST.durability = function(f, pc, reply)
    local pawn = host_pawn(pc)
    if not pawn then reply("FAIL", "the client has no character on the host") return end
    local items = package.loaded["sdc_items"]
    if type(items) ~= "table" or type(items.equipped_of) ~= "function" then reply("SKIP", "the host has no sdc_items.equipped_of") return end
    local list, kv = {}, {}
    for _, e in pairs(items.equipped_of(pawn)) do
        if e.slot and e.slot ~= "" and ue.valid(e.actor) then
            local pu = ue.prop(e.actor, "BP_JigMultiplayer")
            local pi = ue.valid(pu) and ue.try(function() return pu.PickupInfo end) or nil
            local info = pi and ue.try(function() return pi[DUR_INFO] end) or nil
            local d = info and ue.try(function() return info[DUR_FIELD] end) or nil
            local x = d and dur_num(function() return tonumber(d.X) end) or nil
            local y = d and dur_num(function() return tonumber(d.Y) end) or nil
            local name = e.slot:match("([%w_]+)$") or e.slot
            list[#list + 1] = string.format("%s %s", name, dur_fmt(x, y))
            if x then kv[#kv + 1] = string.format("%s=%.1f", name:lower(), x) end
        end
    end
    table.sort(list)
    reply("INFO", table.concat(list, ", "), table.unpack(kv))
end

-- C.markers (local, on the client only): the game's 17.11.2026 layout keeps a map marker's look in its
-- MarkerData struct. A BP_QuestMarker is placed the way a QM from the host places it (sdc_quests) and a
-- BP_Marker the way the host's random event marker is (sdc_events); both must read their data back and
-- build their map marker (the widget in their `Marker` property) from it.
local MK_TEX = "/Game/Blueprints/MinimapSystem/Texture/T_Point.T_Point"
local MK_QTAG = "SDCSelftestQuestMarker"
local MK_EKEY = "selftest-event-marker"

local function marker_probe_state(a, want_title, want_radius)
    local MD = require("sdc_markerdata")
    if not ue.valid(a) then return false, "gone" end
    local d = MD.read(a)
    if not d then return false, "no MarkerData" end
    local wid = ue.prop(a, "Marker")
    local ok_data = d.title == want_title and (want_radius == nil or d.radius == want_radius)
    return ok_data and ue.valid(wid), string.format("title '%s'%s, map widget %s", tostring(d.title),
        want_radius and (", radius " .. tostring(d.radius)) or "", ue.valid(wid) and "built" or "NOT built")
end

local function markers_step()
    return {
        name = "C.markers", timeout = 25,
        start = function(st)
            local pawn = local_pawn()
            local loc = pawn and ue.location(pawn)
            if not loc then return "SKIP", "no own pawn" end
            local quests, events = require("sdc_quests"), require("sdc_events")
            st.qa = quests.selftest_marker(MK_QTAG, { loc = { X = loc.X, Y = loc.Y, Z = loc.Z }, tex = MK_TEX, text = "SDC selftest",
                color = { R = 1, G = 0.2, B = 0.1, A = 1 }, ug = false, radius = 1234, size = { X = 4, Y = 4 }, text_size = { X = 1, Y = 1 } })
            local placed = events.place_marker(MK_EKEY, { X = loc.X, Y = loc.Y, Z = loc.Z },
                { tex = "", title = "SDC selftest event", desc = "d", size = { X = 3.5, Y = 3.5 },
                  col = { R = 0.5, G = 0.17, B = 0.03, A = 1 }, compass = false })
            local path = events._st and events._st.markers and events._st.markers[MK_EKEY]
            st.ea = path and ue.find_object(path) or nil
            st.mk_note, st.t_set, st.waiting = placed, now(), "the markers' BeginPlay (their map widgets)"
            if not ue.valid(st.qa) and not ue.valid(st.ea) then return "FAIL", "neither marker was placed: " .. tostring(placed) end
        end,
        poll = function(st, t)
            if t - st.t_set < 3 then return end
            local qok, qtext = marker_probe_state(st.qa, "SDC selftest", 1234)
            local eok, etext = marker_probe_state(st.ea, "SDC selftest event", nil)
            if not (qok and eok) and t - st.t_set < 12 then return end
            local function clean_up()
                pcall(function() require("sdc_quests").selftest_marker_drop(MK_QTAG) end)
                if ue.valid(st.ea) then pcall(function() st.ea:K2_DestroyActor() end) end
                local ev = require("sdc_events")
                if ev._st and ev._st.markers then ev._st.markers[MK_EKEY] = nil end
            end
            clean_up()
            return (qok and eok) and "PASS" or "FAIL", string.format("BP_QuestMarker: %s | BP_Marker: %s", qtext, etext)
        end,
    }
end

local function workbench_step()
    return {
        name = "C.workbench", timeout = 15,
        start = function(st)
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            local classes = {}
            for cls in pairs(STATION_TABLE) do classes[#classes + 1] = cls end
            table.sort(classes)
            local station, d = nearest(classes, 1000, pawn)
            if not station then return "SKIP", "no crafting / cooking station within 10 m of the client" end
            local t = STATION_TABLE[ue.class_name(station)] or 1
            local loc = ue.location(station)
            if not loc then return "SKIP", "no station position" end
            net.send_to_host("STABLE", t, ue.path(station), ue.class_name(station), string.format("%.0f", loc.X),
                string.format("%.0f", loc.Y), string.format("%.0f", loc.Z))
            st.station, st.table, st.d, st.t_set = station, t, d, now()
            st.waiting = "the host's recipe table"
        end,
        poll = function(st, t)
            if not st.asked and t - st.t_set > 1.5 then
                st.asked = true
                ask(st, "C.workbench", "workbench", ue.path(st.station), st.table)
            end
            local a = ans("C.workbench")
            if a then
                return a.status, string.format("%s at %.1f m, STABLE %d sent; host: %s", ue.short(st.station),
                    (st.d or 0) / 100, st.table, tostring(a.text))
            end
        end,
    }
end

local function door_step()
    return {
        name = "C.door", timeout = 15,
        start = function(st)
            if not net.handlers.WBDOOR then return "SKIP", "sdc_bdoors is not installed here" end
            st.waiting = "the host's door counters"
            ask(st, "C.door.base", "doorbase")
        end,
        poll = function(st, t)
            local base = ans("C.door.base")
            if base and not st.sent then
                st.sent, st.s0 = t, base.kv.snaps or "0"
                net.send_to_host("WBDOORQ")
                st.waiting = "the host to answer WBDOORQ"
            end
            if st.sent and not st.asked and t - st.sent > 2 then
                st.asked = true
                ask(st, "C.door", "door", st.s0)
            end
            local a = ans("C.door")
            if a then
                return a.status, string.format("WBDOORQ sent; host: %s; no door toggled", tostring(a.text))
            end
        end,
    }
end

local function turn_step()
    return {
        name = "C.turn", timeout = 20,
        start = function(st)
            local pc = ue.local_pc()
            if not pc then return "SKIP", "no own controller" end
            local cr = ue.try(function() return pc:GetControlRotation() end)
            local yaw = cr and ue.try(function() return cr.Yaw end)
            if type(yaw) ~= "number" then return "SKIP", "cannot read the control rotation" end
            st.pc, st.yaw0 = pc, yaw
            st.pitch = ue.try(function() return cr.Pitch end)
            if type(st.pitch) ~= "number" then st.pitch = 0 end
            st.n, st.t_step = 0, now() - 1
            st.waiting = "the rotation steps"
        end,
        poll = function(st, t)
            if st.n < 4 then
                if t - st.t_step >= 0.4 then
                    st.n = st.n + 1
                    st.t_step = t
                    st.final = norm180(st.yaw0 + 30 * st.n)
                    ue.call(st.pc, "SetControlRotation", { Pitch = st.pitch, Yaw = st.final, Roll = 0 })
                end
                return
            end
            if not st.asked and t - st.t_step > 1.2 then
                st.asked = true
                ask(st, "C.turn", "turn", string.format("%.1f", st.yaw0), string.format("%.1f", st.final))
            end
            local a = ans("C.turn")
            if a then return a.status, "host: " .. tostring(a.text) end
        end,
        cleanup = function(st)
            if st.pc and st.yaw0 and ue.valid(st.pc) then
                ue.call(st.pc, "SetControlRotation", { Pitch = st.pitch or 0, Yaw = st.yaw0, Roll = 0 })
            end
        end,
    }
end

-- Directions tried by the walk (degrees from the pawn's facing): a pawn that
-- stands against an obstacle moves in another one.
local WALK_DIRS = { { 0, "forward" }, { 90, "right" }, { 270, "left" }, { 180, "back" } }
local WALK_LEG_S, WALK_OK_CM = 2, 200

local function dir_vec(yaw_deg, off)
    local a = math.rad(yaw_deg + off)
    return { X = math.cos(a), Y = math.sin(a), Z = 0 }
end

local function walk_step()
    return {
        name = "C.walk", timeout = 45,
        start = function(st)
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            local p0 = ue.location(pawn)
            if not p0 then return "SKIP", "no own position" end
            st.pawn, st.origin, st.yaw0 = pawn, p0, ue.rotation(pawn).Yaw
            st.i, st.ph, st.leg0, st.leg_t = 1, 1, p0, now()
            st.tried = {}
            C.walk_off = nil
            st.waiting = "the pawn to walk"
            FR.fn = function()
                if st.ph == 1 and ue.valid(st.pawn) then
                    ue.call(st.pawn, "AddMovementInput", dir_vec(st.yaw0, WALK_DIRS[st.i][1]), 1.0, false)
                end
            end
        end,
        poll = function(st, t)
            if st.ph == 1 and t - st.leg_t >= WALK_LEG_S then
                local here = ue.location(st.pawn) or st.leg0
                local d = dist3(here, st.leg0) or 0
                st.tried[#st.tried + 1] = string.format("%s %.0f cm", WALK_DIRS[st.i][2], d)
                if d > WALK_OK_CM then
                    st.ok_dir, st.ok_cm = WALK_DIRS[st.i], d
                    C.walk_off = WALK_DIRS[st.i][1]
                    st.ph, st.t_stop = 2, t
                    FR.fn = nil
                    st.waiting = "the pawn to settle"
                elseif st.i >= #WALK_DIRS then
                    st.ph, st.t_stop = 2, t
                    FR.fn = nil
                    st.waiting = "the pawn to settle"
                else
                    st.i = st.i + 1
                    st.leg0, st.leg_t = ue.location(st.pawn) or st.leg0, t
                end
            elseif st.ph == 2 and t - st.t_stop >= 1 then
                st.ph = 3
                local p1 = ue.location(st.pawn) or st.origin
                st.moved = dist3(p1, st.origin) or 0
                ask(st, "C.walk", "pos", string.format("%.1f", p1.X), string.format("%.1f", p1.Y),
                    string.format("%.1f", p1.Z), string.format("%.0f", st.moved))
                st.waiting = "the host's position of the pawn"
            elseif st.ph == 3 then
                local a = ans("C.walk")
                if a then
                    local how = st.ok_dir and string.format("walked %s (%d deg), %.0f cm in %d s", st.ok_dir[2], st.ok_dir[1],
                        st.ok_cm, WALK_LEG_S) or ("no direction worked: " .. table.concat(st.tried, ", "))
                    return a.status, how .. "; host: " .. tostring(a.text)
                end
            end
        end,
        cleanup = function() FR.fn = nil end,
    }
end

-- Sprinting? is cleared by the game while the pawn stands still, so the flag is
-- held while the pawn walks in the direction the walk step found.
local function sprint_step()
    return {
        name = "C.sprint", timeout = 25,
        start = function(st)
            if C.walk_off == nil then return "SKIP", "the pawn could not walk (see C.walk): Sprinting? cannot be tested standing" end
            local pawn = local_pawn()
            if not pawn then return "SKIP", "no own pawn" end
            local orig = ue.prop(pawn, "Sprinting?")
            if type(orig) ~= "boolean" then return "SKIP", "the pawn has no boolean Sprinting?" end
            st.pawn, st.orig = pawn, orig
            -- the game does not sprint backwards / sideways: turn the control rotation
            -- to the direction that walked, so the sprint is FORWARD movement
            local yaw = norm180(ue.rotation(pawn).Yaw + C.walk_off)
            local pc = ue.local_pc()
            local cr = pc and ue.try(function() return pc:GetControlRotation() end)
            local cyaw = cr and ue.try(function() return cr.Yaw end)
            if pc and type(cyaw) == "number" then
                st.pc, st.cyaw = pc, cyaw
                st.cpitch = ue.try(function() return cr.Pitch end)
                if type(st.cpitch) ~= "number" then st.cpitch = 0 end
                ue.call(pc, "SetControlRotation", { Pitch = st.cpitch, Yaw = yaw, Roll = 0 })
            end
            st.dir = dir_vec(yaw, 0)
            st.moving, st.ph, st.t_set = true, 1, now()
            FR.fn = function()
                if st.moving and ue.valid(st.pawn) then
                    ue.call(st.pawn, "AddMovementInput", st.dir, 1.0, false)
                    ue.set_prop(st.pawn, "Sprinting?", not orig)
                end
            end
            st.waiting = "1.5 s of sprinting"
        end,
        poll = function(st, t)
            if st.ph == 1 and t - st.t_set > 1.5 then
                st.ph = 2
                ask(st, "C.sprint", "flags", "sp", st.orig and "0" or "1")
                st.waiting = "the host's flags"
            elseif st.ph == 2 then
                local a = ans("C.sprint")
                if a then
                    st.first, st.moving = a, false
                    FR.fn = nil
                    if ue.valid(st.pawn) then ue.set_prop(st.pawn, "Sprinting?", st.orig) end
                    if a.status ~= "PASS" then return "FAIL", "while walking: " .. tostring(a.text) end
                    st.ph, st.t_set = 3, t
                    st.waiting = "the flag to go back on the host"
                end
            elseif st.ph == 3 and t - st.t_set > 1.4 then
                st.ph = 4
                ask(st, "C.sprint.off", "flags", "sp", st.orig and "1" or "0")
            elseif st.ph == 4 then
                local a = ans("C.sprint.off")
                if a then
                    if a.status == "PASS" then return "PASS", "while walking: " .. tostring(st.first.text) .. "; restored: " .. tostring(a.text) end
                    return "FAIL", "restore: " .. tostring(a.text)
                end
            end
        end,
        cleanup = function(st)
            FR.fn = nil
            if st.pawn and st.orig ~= nil and ue.valid(st.pawn) then ue.set_prop(st.pawn, "Sprinting?", st.orig) end
            if st.pc and st.cyaw and ue.valid(st.pc) then
                ue.call(st.pc, "SetControlRotation", { Pitch = st.cpitch or 0, Yaw = st.cyaw, Roll = 0 })
            end
        end,
    }
end

local function frame_step()
    return {
        name = "D.frame", timeout = 10,
        start = function(st)
            st.waiting = "the host's frame times"
            ask(st, "D.frame", "frame")
        end,
        poll = function(st)
            local a = ans("D.frame")
            if not a then return end
            local fs = frame_summary()
            local ok = a.status == "PASS" and fs.max <= FRAME_FAIL_MS
            return ok and "PASS" or "FAIL", string.format("client %s; %s | host: %s", frame_text(fs), perf_text(), tostring(a.text))
        end,
    }
end

local function build_steps()
    local steps = {
        { name = "A.hello", timeout = 10, fatal = true,
          start = function(st)
              st.waiting = "the host's answer (no sdc_selftest / config selftest off on the host?)"
              ask(st, "A.hello", "hello", C.run.id, VERSION_TEXT)
          end,
          poll = function()
              local a = ans("A.hello")
              if a then return a.status, "host: " .. tostring(a.text) end
          end },
    }
    for _, t in ipairs({ { "50", 50 }, { "1k", 1024 }, { "3k", 3072 } }) do steps[#steps + 1] = rtt_step(t[1], t[2]) end
    for _, t in ipairs({ "50", "1k", "3k" }) do steps[#steps + 1] = hostping_step(t) end
    steps[#steps + 1] = burst_step()
    steps[#steps + 1] = snapshot_step()
    steps[#steps + 1] = chat_step()
    steps[#steps + 1] = flag_step("C.weapon", "HoldingFirearm?", "hf")
    steps[#steps + 1] = crouch_step()
    steps[#steps + 1] = container_step()
    steps[#steps + 1] = relocate_step()
    steps[#steps + 1] = ground_take_step()
    steps[#steps + 1] = durability_step()
    steps[#steps + 1] = markers_step()
    steps[#steps + 1] = workbench_step()
    steps[#steps + 1] = door_step()
    steps[#steps + 1] = turn_step()
    steps[#steps + 1] = walk_step()
    steps[#steps + 1] = sprint_step()
    steps[#steps + 1] = frame_step()
    return steps
end

-- ---------------------------------------------------------------------------
-- Client side: the runner
-- ---------------------------------------------------------------------------

local function client_block(why)
    local r = C.run
    log.info("[SELFTEST] ===== client summary (%s) =====", why)
    for _, x in ipairs(r.results) do
        log.info("[SELFTEST] | %-14s | %-4s | %s", x.step, x.status, tostring(x.detail))
    end
    log.info("[SELFTEST] DONE pass=%d fail=%d skip=%d", r.count.PASS or 0, r.count.FAIL or 0, r.count.SKIP or 0)
    pcall(log.flush)
end

local function run_end(why)
    local r = C.run
    if not r or r.done then return end
    r.done = true
    net.send_to_host(K, "END", r.count.PASS or 0, r.count.FAIL or 0, r.count.SKIP or 0)
    client_block(why)
    frames_stop()
    C.run = nil
end

local function record(r, step, status, detail)
    r.results[#r.results + 1] = { step = step, status = status, detail = detail }
    r.count[status] = (r.count[status] or 0) + 1
    say(step, status, detail)
end

-- Remaining steps are skipped (the run cannot go on).
local function skip_rest(r, why)
    for i = r.idx + 1, #r.steps do record(r, r.steps[i].name, "SKIP", why) end
    r.idx = #r.steps
end

local function finish_step(st, status, detail)
    local r = C.run
    local def = st.def
    if def.cleanup then
        local ok, err = pcall(def.cleanup, st)
        if not ok then log.err_throttled("selftest.cleanup", "selftest: cleanup %s: %s", def.name, tostring(err)) end
    end
    FR.fn = nil
    r.cur = nil
    if status ~= "PASS" and status ~= "FAIL" and status ~= "SKIP" then status = "FAIL" end
    record(r, def.name, status, detail)
    if def.fatal and status ~= "PASS" then skip_rest(r, "no working host answer (" .. def.name .. ")") end
end

local function next_step(t)
    local r = C.run
    r.idx = r.idx + 1
    local def = r.steps[r.idx]
    if not def then return end
    local st = { def = def, t0 = t }
    r.cur = st
    local ok, status, detail = pcall(def.start, st)
    if not ok then
        finish_step(st, "FAIL", "error: " .. tostring(status))
    elseif status then
        finish_step(st, status, detail)
    end
end

local function pawn_dead(p) return ue.valid(p) and ue.prop(p, "PlayerDead?") == true end

local function client_ready()
    local cs = S and S.client
    return S and S.role == "client" and cs and cs.acked == true and ue.valid(ue.local_pc()) and local_pawn() ~= nil
        and not pawn_dead(local_pawn()) and not ue.in_main_menu()
end

-- The client is dead or has no character: press the mod's own respawn (the
-- death screen's "respawn at the host", sdc_players.request_respawn), at most
-- every 20 s.
local RESPAWN_EVERY_S = 20
local function try_respawn(t, why)
    local cs = S and S.client
    if not (S and S.role == "client" and cs and cs.acked == true) or ue.in_main_menu() then return end
    if C.resp_at and t - C.resp_at < RESPAWN_EVERY_S then return end
    C.resp_at = t
    local pl = package.loaded["sdc_players"]
    if type(pl) ~= "table" or type(pl.request_respawn) ~= "function" then
        log.info("[SELFTEST] %s: no respawn path (sdc_players.request_respawn) - waiting", why)
        return
    end
    local ok, err = pcall(pl.request_respawn, "host", nil)
    log.info("[SELFTEST] %s: respawn asked through sdc_players.request_respawn (ok=%s%s)", why, tostring(ok),
        ok and "" or (" " .. tostring(err)))
end

local function begin_run()
    M.stats.runs = M.stats.runs + 1
    local id = string.format("%d%03d", os.time() % 100000, math.random(100, 999))
    C.run = { id = id, steps = build_steps(), idx = 0, ans = {}, results = {}, count = {}, t0 = now(), last_ok = now() }
    C.hping, C.b, C.s = {}, nil, nil
    frames_start()
    log.info("[SELFTEST] run %s starts on the client (mod %s)", id, VERSION_TEXT)
end

local function client_tick(t)
    local r = C.run
    if not r then
        if C.want_start then
            if client_ready() then
                C.ready_since = C.ready_since or t
                if t - C.ready_since >= 3 then
                    C.want_start, C.ready_since = nil, nil
                    begin_run()
                end
            else
                C.ready_since = nil
                if not local_pawn() or pawn_dead(local_pawn()) then
                    try_respawn(t, local_pawn() and "the client is dead" or "the client has no character")
                end
                if t - C.want_start > 120 then
                    C.want_start = nil
                    log.warn("[SELFTEST] not started: the client did not get into the host's world in 120 s")
                end
            end
        end
        return
    end
    -- left the world / lost the pawn: nothing more can be tested
    local gone = S.role ~= "client" or not local_pawn() or pawn_dead(local_pawn())
    if gone and S.role == "client" then
        try_respawn(t, local_pawn() and "the client died during the run" or "the client lost its character")
    end
    if gone then
        -- a client that only died gets 120 s to come back; one that left the world 15 s
        if t - r.last_ok > (S.role == "client" and 120 or 15) then
            if r.cur then finish_step(r.cur, "FAIL", "the client left the host's world or lost its pawn") end
            skip_rest(r, "the client left the host's world")
            run_end("aborted")
            return
        end
    else
        r.last_ok = t
    end
    local st = r.cur
    if not st then
        next_step(t)
        st = r.cur
        if not st and r.idx >= #r.steps then run_end("finished") end
        return
    end
    local ok, status, detail = pcall(st.def.poll, st, t)
    if not ok then
        finish_step(st, "FAIL", "error: " .. tostring(status))
    elseif status then
        finish_step(st, status, detail)
    elseif t - st.t0 > st.def.timeout then
        finish_step(st, "FAIL", string.format("timeout after %d s waiting for %s", st.def.timeout, tostring(st.waiting or "an answer")))
    end
    if r.idx >= #r.steps and not r.cur then run_end("finished") end
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

local function on_stest(f, pc)
    if not enabled() then return end
    local op = f[1]
    local role = S and S.role
    if role == "host" then
        if op == "REQ" then
            on_req(f, pc)
        elseif op == "PING" then
            local tag, seq = f[3] or "?", tonumber(f[4]) or 0
            local r = H.ping_rcv[tag]
            if not r then r = { n = 0, ooo = 0, last = 0 }; H.ping_rcv[tag] = r end
            r.n = r.n + 1
            if seq < r.last then r.ooo = r.ooo + 1 else r.last = seq end
            if H.run then H.run.last_rx = now() end
            net.send_to(pc, K, "ECHO", f[2], f[3], f[4], f[5])
        elseif op == "ECHO" then
            for _, e in ipairs(H.pingers) do
                if e.tag == f[3] then e.p:on_echo(f[4], now()) end
            end
            if H.run then H.run.last_rx = now() end
        elseif op == "END" then
            host_print_block("client finished",
                string.format("pass=%s fail=%s skip=%s", tostring(f[2]), tostring(f[3]), tostring(f[4])))
        end
    elseif role == "client" then
        if op == "ANS" then
            if C.run then C.run.ans[f[2] or "?"] = { status = f[3], text = f[4] or "", kv = kv_of(f, 5) } end
        elseif op == "PING" then
            local tag, seq = f[3] or "?", tonumber(f[4]) or 0
            local h = C.hping[tag]
            if h then
                h.n = h.n + 1
                if seq < h.last then h.ooo = h.ooo + 1 else h.last = seq end
            end
            net.send_to_host(K, "ECHO", f[2], f[3], f[4], f[5])
        elseif op == "ECHO" then
            local p = C.pingers[f[3]]
            if p then p:on_echo(f[4], now()) end
        end
    end
end

-- client: the burst, the fast answer, the snapshot versions
local function on_burst(f)
    if not enabled() then return end
    local t = now()
    local b, s = C.b, C.s
    local id, seq = f[1], tonumber(f[2]) or 0
    if b and id == b.id then
        b.n, b.total = b.n + 1, b.total + 1
        b.first_t = b.first_t or t
        b.last_t = t
        if seq < b.seq then b.ooo = b.ooo + 1 else b.seq = seq end
    elseif s and id == s.id .. "e" then
        s.endt = t
    end
end

local function on_fast(f)
    if not enabled() then return end
    local b = C.b
    if b and f[1] == b.id then
        b.ans_t = now()
        b.total = b.total + 1
        b.ans_pos = b.total
    end
end

local function on_snap(f)
    if not enabled() then return end
    local s = C.s
    local k = s and s[f[1] or ""]
    if type(k) ~= "table" then return end
    local v = tonumber(f[2]) or 0
    k.n = k.n + 1
    if v < k.last then s.ooo = s.ooo + 1 else k.last = v end
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

-- Every 100 ms (started from install, 5 s after the mod).
function M.tick()
    if not enabled() or not S then return end
    local t = now()
    local ok, err = pcall(function()
        if S.role == "host" then host_tick(t) end
        -- (a run that outlives the client role still has to end)
        if S.role == "client" or C.run or C.want_start then client_tick(t) end
        if FR.on and t - (FR.sample_at or 0) >= 1 then
            FR.sample_at = t
            perf_sample()
        end
    end)
    if not ok then log.err_throttled("selftest.tick", "selftest: tick: %s", tostring(err)) end
end

-- ui_test.txt "selftest=1" (sdc_ui): start the run on this client; "0" stops it.
function M.command(v)
    if not enabled() then
        log.warn("[SELFTEST] selftest=%s ignored: config selftest is off (set it on both copies and restart)", tostring(v))
        return false
    end
    if tostring(v) == "0" then
        M.abort("stopped by command")
        return true
    end
    local role = S and S.role
    if role ~= "client" then
        log.info("[SELFTEST] a run is started on the client; this machine is %s (it only answers)", tostring(role))
        return false
    end
    if C.run or C.want_start then
        log.info("[SELFTEST] a run is already going")
        return false
    end
    C.want_start = now()
    log.info("[SELFTEST] start requested; waiting for the client to stand in the host's world")
    return true
end

function M.abort(why)
    local r = C.run
    C.want_start = nil
    if r then
        if r.cur then finish_step(r.cur, "FAIL", tostring(why)) end
        skip_rest(r, tostring(why))
        run_end("aborted: " .. tostring(why))
    end
end

-- World change / role change: a client's run ends; the host's block goes out.
function M.reset(why)
    if C.run then M.abort("world reset: " .. tostring(why)) end
    if H.run then host_print_block("world reset: " .. tostring(why)) end
end

function M.install(state)
    S = state
    if not enabled() then return end
    net.on(K, on_stest)
    net.on(KB, on_burst)
    net.on(KS, on_snap)
    net.on(KF, on_fast)
    -- sdc_net's type tables (0.12.2): the fast answer in the fast lane, the
    -- snapshot keyed by its first field; absent tables = the steps that need
    -- them say so
    if type(net.FAST) == "table" then net.FAST[KF] = true end
    if type(net.SNAPSHOT) == "table" then net.SNAPSHOT[KS] = function(f) return f[1] or "" end end
    local session = package.loaded["sdc_session"]
    if type(session) == "table" then
        VERSION_TEXT = tostring(session.VERSION or "?")
        if type(session.world_reset_hooks) == "table" then
            session.world_reset_hooks.selftest = function(why) M.reset(why) end
        end
    end
    ue.delay("selftest-boot", 5000, function() ue.every("selftest", 100, M.tick) end)
    log.info("[SELFTEST] on: this copy answers the self test (the client starts it with ui_test.txt selftest=1)")
end

-- tests
M._t = { C = C, H = H, FR = FR, HOST = HOST, new_pinger = new_pinger, on_stest = on_stest, client_tick = client_tick,
         host_tick = host_tick, build_steps = build_steps }

return M
