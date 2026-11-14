-- SDCoop: "send on change, verify rarely" for the mod channel (sdc_net).
--
-- The other side already knows what it was told. A sender that keeps a
-- per-peer record of the last thing it sent under a key (a hash / the
-- payload text itself) sends again only
--   * when the thing changed (at once), or
--   * every verify_s seconds (a rare full resend: a message the budget
--     queue dropped, a record the other side lost, a world reset there heals
--     itself), or
--   * when the peer is new (a joiner / a reconnect has no record: the first
--     check sends the full state).
-- No network, no engine calls: sdc_net's send queue, NOW classes and budget
-- are untouched; the callers send with sdc_net as before.
--
--   local due = sync.due(peer, key, state, verify_s)   -- true: send now
--   if due and net.send_to(pc, ...) then sync.mark(peer, key, state) end
--   sync.due_mark(peer, key, state, verify_s)          -- both in one (optimistic)
--   sync.mark(peer, key, state)   a message that carried `state` went out by another way
--   sync.drop(peer)               the peer left / said HI again: it knows nothing
--   sync.prune(live)              live = { [peer] = true }: forgets the other peers
-- `peer`: names one machine as this machine sees it: the remote controller's
-- name (ue.name(pc)) on the host, "host" on a client. `key`: what is sent
-- ("ROSTER", "LOOK:12"...), one record per peer and key, shared by all modules.
-- `state`: a string (the payload, or a hash of it); compared with ==.

local M = { stats = { sent = 0, skipped = 0, verified = 0, changed = 0, fresh = 0 } }

local peers = {}   -- [peer] = { [key] = { s = state, t = clock of the last send } }

local function clock() return os.clock() end

function M.due(peer, key, state, verify_s)
    local p = peers[peer]
    local e = p and p[key]
    if not e then return true end
    if e.s ~= state then return true end
    if verify_s and clock() - e.t >= verify_s then return true end
    return false
end

-- has this peer been told anything under `key`?
function M.known(peer, key)
    local p = peers[peer]
    return p ~= nil and p[key] ~= nil
end

function M.mark(peer, key, state)
    local p = peers[peer]
    if not p then p = {}; peers[peer] = p end
    local e = p[key]
    if not e then p[key] = { s = state, t = clock() } else e.s, e.t = state, clock() end
end

-- due + mark, counting what happened (the caller sends when it returns true)
function M.due_mark(peer, key, state, verify_s)
    local p = peers[peer]
    local e = p and p[key]
    local why
    if not e then why = "fresh"
    elseif e.s ~= state then why = "changed"
    elseif verify_s and clock() - e.t >= verify_s then why = "verified" end
    if not why then
        M.stats.skipped = M.stats.skipped + 1
        return false
    end
    M.stats[why] = M.stats[why] + 1
    M.stats.sent = M.stats.sent + 1
    M.mark(peer, key, state)
    return true
end

function M.forget(peer, key)
    local p = peers[peer]
    if p then p[key] = nil end
end

function M.drop(peer) peers[peer] = nil end

-- Forgets every peer that is not in `live` (sdc_session calls it each second
-- with the controllers the host is connected to).
function M.prune(live)
    for peer in pairs(peers) do
        if not live[peer] then peers[peer] = nil end
    end
end

function M.reset() peers = {} end

return M
