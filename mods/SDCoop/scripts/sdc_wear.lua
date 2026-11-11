-- SDCoop: a client's firearm and muzzle attachment wear.
-- Driven by sdc_items (init / client_tick / reset / register_handlers); its
-- fix_durability (the client's GetDurability) subtracts own_minus().
--
-- Every shot runs on the shooter's machine only (input -> Local_StartShooting
-- -> FireBullet, then the "FireBullet" timer for automatic fire;
-- work\re\pseudo\BP_FirearmPickup.txt):
--   FireBullet @5 DurabilityCheck: GetDurability(EquipmentUID of the active
--     slot); 0 jams every pull ("Weapon jammed"), <= 85 may jam with
--     Difficulty.FirearmMalfunction;
--   FireBullet @164 ReduceDurability (Difficulty.WeaponDurability): the
--     owner's BP_JigComponent.ServerFuncUpdateDurabilityByUID(EquipmentUID,
--     ItemDataAsset.ReduceDurabilityAmount * WeaponDurabilityMultiplier,
--     false) @430;
--   FireBullet @197 MuzzleEffects -> with a suppressor (or a muzzle brake)
--     MuzzleDurability (Difficulty.MuzzleAttachmentDurability): when
--     GetDurability(AttachmentUID) != 0, ServerFuncUpdateDurabilityByUID(
--     AttachmentUID, AttachmentID.ReduceDurabilityAmount *
--     MuzzleAttachmentDurabilityMultiplier * MuzzleDurabilityMultiplier,
--     false) @614; a muzzle at 0 counts as absent (the loud shot).
-- ServerFuncUpdateDurabilityByUID (BP_JigComponent @0-1565) is a plain
-- function, not an RPC: it walks MainJigContainers, lowers the item's
-- Durability.X (FMax 0) and tells the owner (CLIENT_UpdateDurability). On a
-- client MainJigContainers is empty (the inventory is the host's): the call
-- finds nothing and nothing reaches the host. The host never runs FireBullet
-- for a client's gun (only Svr_WeaponShot / Svr_WeaponEffects /
-- SERVER_DamageEvent / SERVER_RequestConsumeItem come over), so a client's
-- guns and suppressors never wore. 0.7.0 / 0.7.1 logs: the client's 308 and
-- 12 gauge rounds were consumed on the host while every UIDS kept its guns at
-- @100.00 all session; the suppressor (MakeshiftMuffler2) read 100.0 on the
-- client right after the rifle in the same shot (its MuzzleDurability ran);
-- the knife, worn by the host's replay of the swing (sdc_combat MHIT), 99.54.
-- Fix:
--   client: the game's own call is taken as it is. The post-hook of
--     ServerFuncUpdateDurabilityByUID on the own component remembers (UID,
--     MinusDur); the post-hook of BP_FirearmPickup.ReduceDurability /
--     MuzzleDurability that follows it (the same call) claims it as a shot's
--     wear. Other callers (melee: the host already wears it; tools: sdc_world;
--     the respirator) are never claimed. The wear is summed per item and sent
--     at most every FLUSH_S (GWEAR). Until the host's value comes back, the
--     own GetDurability reads the host's value minus that wear (own_minus), so
--     a gun jams and a worn-out suppressor stops suppressing on the shot it
--     would in single player.
--   host: the same ServerFuncUpdateDurabilityByUID(UID, sum, false) on its
--     copy of that player's inventory (the sender's BP_JigMultiplayer). The
--     function looks at no "player 0" (sdc_ctx not needed); its
--     CLIENT_UpdateDurability updates the client's inventory slot, and
--     ITEMS / UIDS (sdc_items) carry the value.
--   client: ClientFunc_UpdateDurability (the CLIENT_UpdateDurability body) on
--     the own component: GetDurability reads that value at once
--     (sdc_items.set_reported), and the oldest wear sent for the item is in it.
-- The host's own shots stay with the game (every client hook checks the
-- role and the own character). Config client_durability_from_host.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local consume = require("sdc_consume")   -- the host's inventory walk (item names, a missing item)

local M = {
    stats = { weapon = 0, muzzle = 0, unclaimed = 0, sent_msgs = 0, confirmed = 0, expired = 0,
              host_msgs = 0, host_applied = 0, host_missing = 0, host_refused = 0, host_shots = 0 },
}
local S
function M.init(state) S = state end

local JIG_FN = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
local FIREARM_FN = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:"
local MSG = "GWEAR"

local SAME_CALL = 0.1    -- s: the wear call and the firearm function it ran in
local FLUSH_S = 0.5      -- s: a client's wear goes to the host at most this often
local CONFIRM_S = 4      -- s: sent wear the host has not confirmed stops counting here
local MAX_MINUS = 100    -- durability per item and message (a durability is 0..100)
local MAX_ITEMS = 16     -- items per message
local INFO_LINES = 20    -- sends / applications / confirmations at info, then debug
local SUMMARY_S = 60     -- s between summary lines while wear goes on

local function on()
    return cfg.get("client_durability_from_host") ~= false
end

local function say(n, fmt, ...)
    if n <= INFO_LINES then log.info(fmt, ...) else log.debug(fmt, ...) end
end

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function guid_str(g)
    if g == nil then return nil end
    local ok, s = pcall(function() return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end)
    if ok then return s end
    return nil
end

local function parse_guid(s)
    local a, b, c, d = tostring(s or ""):match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not a then return nil end
    return { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) }
end

local function is_player_character(a)
    return ue.valid(a) and ue.class_name(a):find("PlayerCharacter", 1, true) ~= nil
end

local function is_locally_controlled(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

-- The own character (or controller), when `a` (a Jig component, a gun)
-- belongs to it: its owner chain, as the game's GetOwner() finds the
-- component the gun's wear call goes to.
local function own_owner(a)
    if not ue.valid(a) then return nil end
    local o = a
    for _ = 1, 3 do
        local cur = o
        o = ue.try(function() return cur:GetOwner() end)
        if not ue.valid(o) then return nil end
        if is_player_character(o) then
            if is_locally_controlled(o) then return o end
            return nil
        end
        if ue.class_name(o):find("PlayerController", 1, true) then
            local ok, v = pcall(function() return o:IsLocalController() end)
            if ok and v == true then return o end
            return nil
        end
    end
    return nil
end

local function kind_text(kind)
    return kind == "muzzle" and "muzzle attachment" or "weapon"
end

-- One RegisterHook per BP function (post: after the body ran here).
local hooked = {}
local function try_hook(path, tag, fn)
    if hooked[path] then return end
    local ok = pcall(RegisterHook, path, function(c, ...)
        local okc, err = pcall(fn, c, ...)
        if not okc then log.err_throttled("wear." .. tag, "wear: %s hook: %s", tag, tostring(err)) end
    end)
    if ok then
        hooked[path] = true
        log.info("wear: %s hook ok (%s)", tag, path:match(":([^:]+)$") or path)
    end
end

-- ===========================================================================
-- Client
-- ===========================================================================

local function new_client()
    return {
        last = nil,       -- { u, m, destroy, t }: the own component's last wear call
        pend = {},        -- [uid] = { m = wear, n = shots, kind, cls }: not sent yet
        flight = {},      -- [uid] = { { m, at }, ... } sent, not confirmed by the host (oldest first)
        flush_at = -100,  -- os.clock() of the last send
        sched_at = nil,   -- os.clock() a delayed send was asked for
        told = {}, told_n = 0,   -- [uid .. kind]: the per-shot line logged
        hook_at = -100,
        sum_at = nil, sum_said = nil,
    }
end
local cl = new_client()
local gen = 0   -- a reset makes the delayed send of the old session do nothing

-- Sends the summed wear (GWEAR|<uid>=<wear>/<shots>;...); kept when there is
-- no connection yet.
local function flush()
    local list = {}
    for u in pairs(cl.pend) do list[#list + 1] = u end
    if #list == 0 then return end
    table.sort(list)
    local parts = {}
    for _, u in ipairs(list) do
        local e = cl.pend[u]
        parts[#parts + 1] = string.format("%s=%.4f/%d", u, e.m, e.n)
    end
    if not net.send_to_host(MSG, table.concat(parts, ";")) then return end
    local now = os.clock()
    cl.flush_at = now
    M.stats.sent_msgs = M.stats.sent_msgs + 1
    local text = {}
    for _, u in ipairs(list) do
        local e = cl.pend[u]
        cl.pend[u] = nil
        local q = cl.flight[u]
        if not q then
            q = {}
            cl.flight[u] = q
        end
        q[#q + 1] = { m = e.m, at = now }
        text[#text + 1] = string.format("%s %s %s -%.3f (%d shot(s))", e.cls, kind_text(e.kind), u, e.m, e.n)
    end
    say(M.stats.sent_msgs, "wear: own wear sent to the host: %s", table.concat(text, "; "))
end

-- One delayed send per FLUSH_S while shots come (the client tick sends what
-- a lost timer left).
local function schedule()
    if cl.sched_at then return end
    local now = os.clock()
    local wait = math.max(0.05, FLUSH_S - (now - cl.flush_at))
    cl.sched_at = now
    local my_gen = gen
    local ok = pcall(ue.delay, "wear-flush", math.floor(wait * 1000), function()
        if my_gen ~= gen then return end
        cl.sched_at = nil
        flush()
    end)
    if not ok then cl.sched_at = nil end
end

-- BP_JigComponent.ServerFuncUpdateDurabilityByUID(UID, MinusDur,
-- DestroyItemIfZeroDur?, out NewDur), post (client): a wear call of the own
-- component, claimed by the gun function it ran in (below) or never.
local function on_dur(c, uid_p, minus_p, destroy_p)
    if not S or S.role ~= "client" or not on() then return end
    if cl.last then M.stats.unclaimed = M.stats.unclaimed + 1 end
    cl.last = nil
    local comp = c and c:get()
    if not own_owner(comp) then return end
    local u = guid_str(get(uid_p))
    local m = tonumber(get(minus_p))
    if not u or u == "0:0:0:0" or not m or m ~= m or m <= 0 then return end
    cl.last = { u = u, m = m, destroy = get(destroy_p) == true, t = os.clock() }
end

-- BP_FirearmPickup.ReduceDurability(out Reduced?) / MuzzleDurability(out
-- AttachmentFound?), post (client): the wear call just before, made inside
-- this function of the own gun, is a shot's wear.
local function claim(kind, c)
    local d = cl.last
    cl.last = nil
    if not d or not S or S.role ~= "client" or not on() then return end
    if d.destroy or os.clock() - d.t > SAME_CALL then
        M.stats.unclaimed = M.stats.unclaimed + 1
        return
    end
    local gun = c and c:get()
    if not own_owner(gun) then return end
    local e = cl.pend[d.u]
    if not e then
        e = { m = 0, n = 0, kind = kind, cls = ue.class_name(gun) }
        cl.pend[d.u] = e
    end
    e.m = e.m + d.m
    e.n = e.n + 1
    M.stats[kind] = M.stats[kind] + 1
    local key = d.u .. kind
    if not cl.told[key] and cl.told_n < 64 then
        cl.told[key] = true
        cl.told_n = cl.told_n + 1
        log.info("wear: own %s %s %s wears %.4f a shot (the game's ServerFuncUpdateDurabilityByUID finds no item"
            .. " on a client); the host applies it", e.cls, kind_text(kind), d.u, d.m)
    end
    schedule()
end

local function on_reduce(c) claim("weapon", c) end
local function on_muzzle(c) claim("muzzle", c) end

-- BP_JigComponent.ClientFunc_UpdateDurability(ItemUID, NewDurab), post
-- (client; the body of CLIENT_UpdateDurability): the host changed the
-- durability of an own item.
local function on_host_value(c, uid_p, dur_p)
    if not S or S.role ~= "client" then return end
    local comp = c and c:get()
    if not own_owner(comp) then return end
    local u = guid_str(get(uid_p))
    local d = get(dur_p)
    local x = d ~= nil and tonumber(ue.try(function() return d.X end)) or nil
    if not u or not x then return end
    local items = package.loaded["sdc_items"]
    if type(items) == "table" and type(items.set_reported) == "function" then items.set_reported(u, x) end
    local q = cl.flight[u]
    if not q then return end
    local f = table.remove(q, 1)
    if #q == 0 then cl.flight[u] = nil end
    if not f then return end
    M.stats.confirmed = M.stats.confirmed + 1
    say(M.stats.confirmed, "wear: the host applied own wear %.3f of %s: now %.2f (CLIENT_UpdateDurability %.0f ms after the send)",
        f.m, u, x, (os.clock() - f.at) * 1000)
end

-- Client: own wear of this item not in the host's value yet (not sent, or
-- sent and not confirmed): the own GetDurability subtracts it.
function M.own_minus(u)
    local m = 0
    local e = cl.pend[u]
    if e then m = e.m end
    local q = cl.flight[u]
    if q then
        local now = os.clock()
        for _, f in ipairs(q) do
            if now - f.at <= CONFIRM_S then m = m + f.m end
        end
    end
    return m
end

local function client_summary(now)
    local s = M.stats
    local said = string.format("%d/%d/%d/%d/%d", s.weapon, s.muzzle, s.sent_msgs, s.confirmed, s.expired)
    if cl.sum_said == said then return end
    if cl.sum_at and now - cl.sum_at < SUMMARY_S then return end
    if cl.sum_at == nil and s.sent_msgs == 0 then return end
    cl.sum_at, cl.sum_said = now, said
    log.info("wear: own shots so far: %d gun wear(s), %d muzzle attachment wear(s); %d message(s) to the host,"
        .. " %d confirmed, %d unconfirmed", s.weapon, s.muzzle, s.sent_msgs, s.confirmed, s.expired)
end

-- Client tick (1 s): hooks, a send a lost timer left, unconfirmed wear.
function M.client_tick()
    if not S or S.role ~= "client" then return end
    local now = os.clock()
    if now - cl.hook_at >= 5 then
        cl.hook_at = now
        try_hook(JIG_FN .. "ServerFuncUpdateDurabilityByUID", "wear-call", on_dur)
        try_hook(JIG_FN .. "ClientFunc_UpdateDurability", "host-value", on_host_value)
        try_hook(FIREARM_FN .. "ReduceDurability", "gun-wear", on_reduce)
        try_hook(FIREARM_FN .. "MuzzleDurability", "muzzle-wear", on_muzzle)
    end
    if cl.sched_at and now - cl.sched_at > FLUSH_S + 2 then cl.sched_at = nil end
    if not cl.sched_at then flush() end
    for u, q in pairs(cl.flight) do
        local keep = {}
        for _, f in ipairs(q) do
            if now - f.at <= CONFIRM_S then
                keep[#keep + 1] = f
            else
                M.stats.expired = M.stats.expired + 1
                if M.stats.expired <= 5 then
                    log.warn("wear: the host did not confirm own wear %.3f of %s within %d s (a host without this fix?)",
                        f.m, u, CONFIRM_S)
                end
            end
        end
        cl.flight[u] = (#keep > 0) and keep or nil
    end
    client_summary(now)
end

-- ===========================================================================
-- Host
-- ===========================================================================

local function new_host()
    return { missing = {}, broken = {}, names = {}, names_n = 0, sum_at = nil, sum_said = nil }
end
local host = new_host()

local function is_remote_character(p)
    if not is_player_character(p) then return false end
    return ue.valid(ue.prop(ue.prop(p, "Controller"), "NetConnection"))
end

-- The item in the host's copy of a player's inventory (a walk: info lines and
-- a 0 result only), or nil.
local function host_item(jig, u)
    local inv = consume.inventory(jig, true)
    local e = inv and inv.by_uid and inv.by_uid[u]
    if e and not host.names[u] and host.names_n < 256 then
        host.names[u] = e.id
        host.names_n = host.names_n + 1
    end
    return e
end

local function host_summary(now)
    local s = M.stats
    local said = string.format("%d/%d/%d", s.host_msgs, s.host_applied, s.host_missing)
    if host.sum_said == said or (host.sum_at and now - host.sum_at < SUMMARY_S) then return end
    if host.sum_at == nil then
        host.sum_at, host.sum_said = now, said   -- (the first applications have their own lines)
        return
    end
    host.sum_at, host.sum_said = now, said
    log.info("wear: clients' gun / muzzle wear so far: %d message(s), %d item wear(s) applied (%d shot(s)), %d not found,"
        .. " %d refused", s.host_msgs, s.host_applied, s.host_shots, s.host_missing, s.host_refused)
end

-- net GWEAR|<uid>=<wear>/<shots>;...   (client -> host): wear of that
-- player's guns / muzzle attachments, applied on the host's copy of their
-- inventory with the game's own function.
local function on_wear_msg(f, pc)
    if not S or S.role ~= "host" or not on() then return end
    local pawn = ue.pawn_of(pc)
    if not is_remote_character(pawn) then return end
    local jig = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(jig) then return end
    M.stats.host_msgs = M.stats.host_msgs + 1
    local n = 0
    for entry in tostring(f[1] or ""):gmatch("[^;]+") do
        n = n + 1
        if n > MAX_ITEMS then break end
        local us, ms, ns = entry:match("^([%-%d:]+)=([%d%.]+)/(%d+)$")
        local g, m, shots = parse_guid(us), tonumber(ms), math.max(1, math.floor(tonumber(ns) or 1))
        if not g or not m or m ~= m or m <= 0 then
            M.stats.host_refused = M.stats.host_refused + 1
            if M.stats.host_refused <= 5 then log.warn("wear: bad entry '%s' from %s, ignored", entry, ue.short(pc)) end
        else
            m = math.min(m, MAX_MINUS)
            local e = (M.stats.host_applied < INFO_LINES) and host_item(jig, us) or nil
            local x0 = e and tonumber(e.dur) or nil
            local out = {}
            local ok, err = pcall(function() jig:ServerFuncUpdateDurabilityByUID(g, m, false, out) end)
            local x1 = tonumber(out.NewDur)
            local missing = false
            if ok and (x1 == nil or x1 <= 0) then
                -- 0: worn out, or no such item (the function's answer for both)
                if e == nil then e = host_item(jig, us) end
                missing = e == nil
            end
            if not ok then
                log.err_throttled("wear.apply", "wear: %s's wear of %s FAILED on the host: %s", ue.short(pawn), us, tostring(err))
            elseif missing then
                M.stats.host_missing = M.stats.host_missing + 1
                if not host.missing[us] then
                    host.missing[us] = true
                    log.warn("wear: %s's item %s is not in their inventory here: wear %.3f of %d shot(s) not applied",
                        ue.short(pawn), us, m, shots)
                end
            else
                M.stats.host_applied = M.stats.host_applied + 1
                M.stats.host_shots = M.stats.host_shots + shots
                say(M.stats.host_applied, "wear: %s's %s worn by %.3f for %d shot(s) on the host: %s -> %.2f"
                    .. " (CLIENT_UpdateDurability tells them)", ue.short(pawn), host.names[us] or us, m, shots,
                    x0 and string.format("%.2f", x0) or "?", x1 or 0)
                if (x1 or 0) <= 0 and not host.broken[us] then
                    host.broken[us] = true
                    log.info("wear: %s's %s is worn out (durability 0), as their own game will see it", ue.short(pawn),
                        host.names[us] or us)
                end
            end
        end
    end
    host_summary(os.clock())
end

-- ===========================================================================

function M.reset()
    gen = gen + 1
    cl = new_client()
    host = new_host()
end

function M.register_handlers()
    -- client -> host: GWEAR|<uid>=<wear>/<shots>;...   (a client's gun / muzzle attachment wear)
    net.on(MSG, on_wear_msg)
end

return M
