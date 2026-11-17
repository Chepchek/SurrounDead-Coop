-- SDCoop: a per-session dictionary for the long strings of the mod channel
-- (asset paths, part names, material paths).
--
-- A look message used to carry the same 1-2.5 KB of mesh / material paths every
-- time (NPCSET 600 times for 5 distinct looks, LOOK / MYLOOK 2.3 KB, AIAPP
-- 250-400 B per zombie). Now a string goes over the wire as a short token
-- "~<id>" and its definition travels once per peer, INSIDE the first message
-- that uses it (so the order is the channel's own order: reliable, in sequence).
--
-- Sender (one id space per machine, ids are never reused within a session):
--   local e = dict.encoder(peer, chan)   -- peer: as sdc_netsync (remote controller's name on the
--                                        -- host, "host" on a client); chan: "n" for the NOW kinds
--                                        -- (sdc_net.NOW: sent at once), "q" for queueable kinds
--   local t    = e:ref("Characters/Meshes/SK_Man.SK_Man")  -- "~a" (or the text itself when short / unsafe)
--   local defs = e:defs()                -- "a=Characters/...;b=..." for what the peer does not know yet
--   ... net.send_to(pc, kind, defs, ..., t ...)   -- then, when it was accepted:
--   e:commit()                           -- the peer now knows those ids
--   "Known by a peer" lives in sdc_netsync (keys "dict:..."): a joiner's HI (netsync.drop),
--   a world reset (netsync.reset) and a leaving peer (netsync.prune) clear it, so the
--   definitions go again. A queueable message (chan "q") may wait in sdc_net's queue
--   while a NOW message (chan "n") passes it, so what a "q" message defined counts as
--   known for "q" only; what an "n" message defined counts for both.
-- Receiver:
--   local d = dict.decoder(peer, pc)     -- peer: who sent it; pc: its controller (host side)
--   d:receive(defs)                      -- keeps the definitions of the message
--   local s = d:get("~a")                -- the string; nil (and d.missing) when the id is unknown
--   if d:incomplete() then d:ask(); d:retry(function() ... end) end
--     ask: DICTQ|ids to the sender; it answers DICT|definitions (queueable) and tells the
--     modules that registered with dict.on_heal(fn(peer)) so they can send again what
--     the receiver could not read (the NOW messages paired with an object reference cannot
--     be replayed on the receiver's side); retry: fn runs when the definitions came
--     (at most RETRY_N waiting, RETRY_TTL seconds).
-- Messages: DICTQ|id|id... (receiver -> sender), DICT|defs (sender -> receiver).

local netsync = require("sdc_netsync")

local M = {
    stats = { defined = 0, refs = 0, asked = 0, answered = 0, healed = 0, retried = 0, missing = 0 },
}

local RETRY_N, RETRY_TTL = 64, 30
local ASK_GAP_S = 3
local ASK_MAX = 40            -- ids in one DICTQ
local OUT_MAX = 6000          -- distinct strings known at once; over it the id tables start again (ids stay monotonic)
local IN_MAX = 8000           -- strings kept for all senders; over it the table is emptied (DICTQ heals)
local MIN_LEN = 6             -- shorter strings go as they are

local clock = os.clock

local S = nil                 -- sdc_session.state (role)
local out_ids, out_str, out_n, next_id, epoch = {}, {}, 0, 0, 1
local in_tab, in_n = {}, 0    -- [peer] = { [token id] = string }
local waiting = {}            -- [peer] = { { ids = {id...}, fn, t } }
local asked = {}              -- [peer .. id] = clock of the last DICTQ
local heal_fns = {}

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local r = n % 36
        s = B36:sub(r + 1, r + 1) .. s
        n = n // 36
    end
    return s
end

local function known_key(chan, id) return "dict:" .. epoch .. chan .. id end

local function is_known(peer, chan, id)
    return netsync.known(peer, known_key(chan, id))
end

-- ---------------------------------------------------------------------------
-- Sender
-- ---------------------------------------------------------------------------

local Enc = {}
Enc.__index = Enc

function M.encoder(peer, chan)
    return setmetatable({ peer = peer, chan = chan == "n" and "n" or "q", new = {}, order = {}, strs = {} }, Enc)
end

local function id_of(s)
    local id = out_ids[s]
    if id then return id end
    if out_n >= OUT_MAX then
        -- a new epoch: no peer knows any id of the old one (their known-keys carry the epoch).
        -- The counter keeps counting: an id is never given to two strings in one session, so an
        -- old message still on its way cannot resolve to a new string.
        out_ids, out_str, out_n, epoch = {}, {}, 0, epoch + 1
    end
    out_n = out_n + 1
    next_id = next_id + 1
    id = b36(next_id)
    out_ids[s], out_str[id] = id, s
    return id
end

function Enc:ref(s)
    if type(s) ~= "string" or #s < MIN_LEN or s:find("[|;\r\n]") then return s == nil and "" or s end
    local id = id_of(s)
    M.stats.refs = M.stats.refs + 1
    if not self.new[id] and not is_known(self.peer, self.chan, id) then
        self.new[id] = true
        self.strs[id] = s   -- (the tables of ids may start again before defs() is called)
        self.order[#self.order + 1] = id
    end
    return "~" .. id
end

-- "id=string;id=string" of the strings this message uses and the peer lacks
function Enc:defs()
    if #self.order == 0 then return "" end
    local parts = {}
    for i, id in ipairs(self.order) do parts[i] = id .. "=" .. self.strs[id] end
    return table.concat(parts, ";")
end

-- the message went out (was accepted by sdc_net): the peer will know them
function Enc:commit()
    for _, id in ipairs(self.order) do
        netsync.mark(self.peer, known_key("q", id), "1")
        if self.chan == "n" then netsync.mark(self.peer, known_key("n", id), "1") end
        M.stats.defined = M.stats.defined + 1
    end
    self.order, self.new = {}, {}
end

-- ---------------------------------------------------------------------------
-- Receiver
-- ---------------------------------------------------------------------------

local function store(peer, id, s)
    local t = in_tab[peer]
    if not t then t = {}; in_tab[peer] = t end
    if t[id] == nil then
        if in_n >= IN_MAX then in_tab, in_n = {}, 0; t = {}; in_tab[peer] = t end
        in_n = in_n + 1
    end
    t[id] = s
end

local function receive(peer, defs)
    if type(defs) ~= "string" or defs == "" then return 0 end
    local n = 0
    for entry in (defs .. ";"):gmatch("([^;]*);") do
        local id, s = entry:match("^(%w+)=(.+)$")
        if id then store(peer, id, s); n = n + 1 end
    end
    return n
end

local Dec = {}
Dec.__index = Dec

-- chan: the kind of message being read, "n" (NOW: NPCSET / AIAPP) or "q" (queueable: LOOK)
function M.decoder(peer, pc, chan)
    return setmetatable({ peer = peer, pc = pc, chan = chan == "n" and "n" or "q", missing = {} }, Dec)
end

function Dec:receive(defs) return receive(self.peer, defs) end

-- the string of a token; plain text (not "~<id>") is its own value
function Dec:get(tok)
    if type(tok) ~= "string" then return "" end
    local id = tok:match("^~(%w+)$")
    if not id then return tok end
    local t = in_tab[self.peer]
    local s = t and t[id]
    if s == nil then
        self.missing[#self.missing + 1] = id
        return nil
    end
    return s
end

function Dec:incomplete() return #self.missing > 0 end

-- DICTQ to the sender (once per id every ASK_GAP_S)
function Dec:ask()
    local net = package.loaded["sdc_net"] or require("sdc_net")
    local ids, now = {}, clock()
    for _, id in ipairs(self.missing) do
        local k = self.peer .. "\0" .. id
        if not asked[k] or now - asked[k] >= ASK_GAP_S then
            asked[k] = now
            ids[#ids + 1] = id
            if #ids >= ASK_MAX then break end
        end
    end
    M.stats.missing = M.stats.missing + #self.missing
    if #ids == 0 then return false end
    M.stats.asked = M.stats.asked + 1
    if S and S.role == "client" then return net.send_to_host("DICTQ", self.chan, table.unpack(ids)) end
    if self.pc then return net.send_to(self.pc, "DICTQ", self.chan, table.unpack(ids)) end
    return false
end

-- run fn when every missing id has come
function Dec:retry(fn)
    local list = waiting[self.peer]
    if not list then list = {}; waiting[self.peer] = list end
    local now = clock()
    for i = #list, 1, -1 do
        if now - list[i].t > RETRY_TTL then table.remove(list, i) end
    end
    if #list >= RETRY_N then table.remove(list, 1) end
    local ids = {}
    for i, id in ipairs(self.missing) do ids[i] = id end
    list[#list + 1] = { ids = ids, fn = fn, t = now }
end

local function run_waiting(peer)
    local list = waiting[peer]
    if not list then return end
    local t = in_tab[peer] or {}
    local now = clock()
    local keep, run = {}, {}
    for _, w in ipairs(list) do
        if now - w.t <= RETRY_TTL then
            local done = true
            for _, id in ipairs(w.ids) do if t[id] == nil then done = false; break end end
            if done then run[#run + 1] = w else keep[#keep + 1] = w end
        end
    end
    waiting[peer] = keep
    for _, w in ipairs(run) do
        M.stats.retried = M.stats.retried + 1
        pcall(w.fn)
    end
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

function M.on_heal(fn) heal_fns[#heal_fns + 1] = fn end

local function peer_of(pc)
    if S and S.role == "client" then return "host" end
    local ue = package.loaded["sdc_ue"] or require("sdc_ue")
    return ue.name(pc)
end

-- DICTQ|n or q|id|id...: the definitions again, to the asker. "n": the asker could not read an NPCSET /
-- AIAPP (a NOW message): the NOW-known marks of those ids go, so the modules' resend (on_heal) carries
-- its own definitions; "q" (a LOOK): only the DICT answer, no module resends anything.
local function on_dictq(f, pc)
    local net = package.loaded["sdc_net"] or require("sdc_net")
    local peer = peer_of(pc)
    local chan = f[1] == "n" and "n" or "q"
    local parts, ids = {}, {}
    for i = 2, math.min(#f, ASK_MAX + 1) do
        local s = out_str[f[i]]
        if s then
            parts[#parts + 1] = f[i] .. "=" .. s
            ids[#ids + 1] = f[i]
        end
    end
    if #parts == 0 then return end
    local ok
    if S and S.role == "client" then ok = net.send_to_host("DICT", table.concat(parts, ";"))
    else ok = net.send_to(pc, "DICT", table.concat(parts, ";")) end
    if ok then
        for _, id in ipairs(ids) do netsync.mark(peer, known_key("q", id), "1") end
        M.stats.answered = M.stats.answered + 1
    end
    if chan == "n" then
        for _, id in ipairs(ids) do netsync.forget(peer, known_key("n", id)) end
        -- a NOW message that could not be read there is sent again by its module
        M.stats.healed = M.stats.healed + 1
        for _, fn in ipairs(heal_fns) do pcall(fn, peer) end
    end
end

-- DICT|definitions
local function on_dict(f, pc)
    local peer = peer_of(pc)
    if receive(peer, f[1]) > 0 then run_waiting(peer) end
end

-- Idempotent: every module that uses the dictionary calls it from its install.
function M.install(state)
    if state then S = state end
    local net = package.loaded["sdc_net"] or require("sdc_net")
    net.on("DICTQ", on_dictq)
    net.on("DICT", on_dict)
end

-- Everything received from `peer` goes (it said HI / HELLO again: a new session of it, whose ids
-- mean other strings; or it left).
function M.reset_peer(peer)
    local t = in_tab[peer]
    if t then
        for _ in pairs(t) do in_n = in_n - 1 end
        in_tab[peer] = nil
    end
    waiting[peer] = nil
    local prefix = peer .. "\0"
    for k in pairs(asked) do
        if k:sub(1, #prefix) == prefix then asked[k] = nil end
    end
end

-- live = { [peer] = true } (as sdc_netsync.prune): forgets what the other peers sent
function M.prune(live)
    local gone = {}
    for peer in pairs(in_tab) do if not live[peer] then gone[#gone + 1] = peer end end
    for peer in pairs(waiting) do if not live[peer] then gone[#gone + 1] = peer end end
    for _, peer in ipairs(gone) do M.reset_peer(peer) end
end

function M.reset()
    in_tab, in_n, waiting, asked = {}, 0, {}, {}
end

return M
