-- SDCoop zombie feature ai_kill_log: one log line per zombie death, on the host
-- and on every client that had that zombie in view, plus kills per type.
--
-- Host (also without a client connected):
--   DamageComponent_C.DamageTaken(DmgAmount, DmgType, DmgCauser, IsHeadshot),
--   post: the zombie's last hit (damage type, causer, headshot) and its capsule
--   height while it still has one. BP_MasterZombie.Death(Actor, Headshot),
--   post (Death destroys the capsule at @5, so the body's place is the mesh's):
--     ai: kill [host]: <zombie> <type> "<Name>" arch=<letters> crawler=yes|no
--         (hh=40) mesh=<asset> mat=<asset> | by <killer> (headshot, dmg=<type>,
--         causer=<class>) at X Y Z
--   killer: a remote player's name, "<host name> (host)", "zombie <class>",
--   "AI <class>", "trap <class>", a class, or "none" (the game's own Death
--   calls without a killer: a horde zombie when the player dies). Fire: the
--   DamageComponent's CurrentFireDamageGiver. The boss: BP_ZombieBoss
--   .DeathEvent(Player), post.
--   Clients within 150 m get AIKL|killer|headshot|dmg|causer|arch|mesh|mat|
--   crawler + the zombie (ClientRepObjRef).
-- Client: the copy's OnRep_IsDead? (post; IsDead? is the one replicated zombie
--   variable) logs what this machine shows, with the host's killer and look:
--     ai: kill [client]: <copy> <type> "<Name>" ... | by <killer> (...) at X Y Z
--         | host: arch=.. crawler=.. mesh=.. mat=.. -> same | DIFFERS: mesh crawler
--   A corpse that only comes into view (OnRep before the copy's BeginPlay) is
--   no kill and is not logged.
-- Every 60 s, when the counts changed: ai: kill log: host=N client=N | <type>=n ...

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local zi = require("sdc_ai_zombie")

local M = {
    stats = { host = 0, client = 0, sent = 0, got = 0, corpses_in_view = 0 },
}
local core

local clock = os.clock
local addr = ctx.addr

local DMG = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C:"
local SEND_CM = 15000          -- net range: a copy exists within 150 m
local HIT_TTL = 3.0            -- host: the last hit belongs to the death within this
local INFO_TTL = 10.0          -- client: the host's note waits this long for its OnRep
local LINE_DELAY_MS = 500      -- client: OnRep before the host's note: wait a little
local BORN_MIN_S = 0.5         -- client: OnRep this soon after BeginPlay = a corpse coming into view
local SUMMARY_S = 60

local hits = {}                -- host: [zombie address] = { t, dmg, causer, hs, hh }
local counts = {}              -- [type label] = kills
local born = {}                -- client: [copy full name] = clock (BeginPlay seen)
local notes = {}               -- client: [copy full name] = the host's AIKL
local logged = {}              -- client: [copy full name] = clock
local summary = { at = 0, sig = "0|0" }

-- ---------------------------------------------------------------------------
-- Shared
-- ---------------------------------------------------------------------------

local function yn(b) return b and "yes" or "no" end

local function label(d)
    if d.arch ~= "-" then return d.type .. "/" .. d.arch end
    if d.crawler then return d.type .. "/crawler" end
    return d.type
end

local function count(d)
    local l = label(d)
    counts[l] = (counts[l] or 0) + 1
end

local function look_text(d)
    local hh = d.hh and string.format(" (hh=%.0f)", d.hh) or ""
    return string.format("%s %s \"%s\" arch=%s crawler=%s%s mesh=%s mat=%s", d.obj, d.type, d.name, d.arch,
        yn(d.crawler), hh, d.mesh, d.mat)
end

local function where_text(d)
    local l = d.loc
    if not l then return "?" end
    return string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z)
end

local function by_text(k)
    if not k then return "by ? (no word from the host)" end
    local parts = {}
    if k.hs then parts[#parts + 1] = "headshot" end
    if k.via then parts[#parts + 1] = k.via end
    if k.dmg and k.dmg ~= "" then parts[#parts + 1] = "dmg=" .. k.dmg end
    if k.causer and k.causer ~= "" then parts[#parts + 1] = "causer=" .. k.causer end
    if #parts == 0 then return "by " .. k.killer end
    return string.format("by %s (%s)", k.killer, table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function player_name(pc)
    local r = core.S.remote and core.S.remote[ue.name(pc)]
    if r and r.name then return r.name end
    local ps = ue.prop(pc, "PlayerState")
    local n = ue.valid(ps) and ue.str(ue.try(function() return ps:GetPlayerName() end)) or ""
    if n ~= "" then return n end
    return ue.short(pc)
end

-- Who killed: see the header.
local function killer_of(causer, z)
    local via
    if not ue.valid(causer) then
        local giver = ue.prop(ue.prop(z, "DamageComponent"), "CurrentFireDamageGiver")
        if ue.valid(giver) then causer, via = giver, "fire" end
    end
    if not ue.valid(causer) then return "none", via end
    local pc = core.remote_pc_of(nil, causer)
    if pc then return player_name(pc), via end
    -- the host's own pawn, its weapon, its projectile
    local lpc = ue.local_pc()
    local lpawn = lpc and ue.pawn_of(lpc)
    local lp, la = lpc and addr(lpc), lpawn and addr(lpawn)
    local o = causer
    for _ = 1, 4 do
        if not ue.valid(o) then break end
        local a = addr(o)
        if a and (a == la or a == lp) then return cfg.player_name() .. " (host)", via end
        local c = ue.prop(o, "Controller")
        if lp and ue.valid(c) and addr(c) == lp then return cfg.player_name() .. " (host)", via end
        o = ue.try(function() return o:GetOwner() end)
    end
    local cn = ue.class_name(causer)
    if core.has_tag(causer, "PlayerTrap") then return "trap " .. cn, via end
    if core.is_zombie(causer) or core.is_boss(causer) then return "zombie " .. cn, via end
    if core.is_bandit(causer) or core.is_animal(causer) then return "AI " .. cn, via end
    return cn, via
end

-- DamageComponent_C.DamageTaken(DmgAmount, DmgType, DmgCauser, IsHeadshot), post (host)
local function on_damage_taken(c, _, type_p, causer_p, hs_p)
    local comp = c:get()
    local z = ue.valid(comp) and ue.try(function() return comp:GetOwner() end) or nil
    if not ue.valid(z) or not (core.is_zombie(z) or core.is_boss(z)) then return end
    local a = addr(z)
    if not a then return end
    local dt = type_p and type_p:get()
    local causer = causer_p and causer_p:get()
    local hs = hs_p and hs_p:get()
    hits[a] = { t = clock(), dmg = ue.valid(dt) and ue.class_name(dt) or "",
                causer = ue.valid(causer) and ue.class_name(causer) or "", hs = hs == true, hh = zi.capsule_hh(z) }
end

local function send_note(z, d, k)
    if not core.host.active or #core.host.viewers == 0 then return end
    for _, v in ipairs(core.viewers_near(d.loc, SEND_CM)) do
        if core.send_with_obj(v.pc, z, "AIKL", k.killer, k.hs and "1" or "0", k.dmg or "", k.causer or "",
            d.arch, d.mesh, d.mat, d.crawler and "1" or "0") then
            M.stats.sent = M.stats.sent + 1
        end
    end
end

local function host_death(z, killer_obj, headshot)
    if not ue.valid(z) or ue.role(z) ~= ue.ROLE_AUTHORITY then return end
    local a = addr(z)
    local h = a and hits[a]
    if a then hits[a] = nil end
    if h and clock() - h.t > HIT_TTL then h = nil end
    local d = zi.describe(z)
    if not d.hh and h and h.hh then
        d.hh = h.hh
        d.crawler = d.crawler or h.hh < zi.CRAWLER_HH
    end
    local killer, via = killer_of(killer_obj, z)
    local k = { killer = killer, via = via, hs = headshot == true or (h ~= nil and h.hs), dmg = h and h.dmg or "",
                causer = h and h.causer or (ue.valid(killer_obj) and ue.class_name(killer_obj) or "") }
    count(d)
    M.stats.host = M.stats.host + 1
    log.info("ai: kill [host]: %s | %s at %s", look_text(d), by_text(k), where_text(d))
    send_note(z, d, k)
end

-- BP_MasterZombie.Death(Actor, Headshot), post (host)
local function on_zombie_death(c, actor_p, hs_p)
    host_death(c:get(), actor_p and actor_p:get(), hs_p and hs_p:get())
end

-- BP_ZombieBoss.DeathEvent(Player), post (host)
local function on_boss_death(c, player_p)
    host_death(c:get(), player_p and player_p:get(), false)
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- <Zombie / boss>.ReceiveBeginPlay, post (client)
local function on_begin_play_client(c)
    local z = c:get()
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY then return end
    born[ue.name(z)] = clock()
end

-- AIKL|killer|headshot|dmg|causer|arch|mesh|mat|crawler: waits for its zombie
local function on_note(f)
    if core.S.role ~= "client" then return end
    core.expect_obj("kill", { killer = f[1] ~= "" and f[1] or "?", hs = f[2] == "1", dmg = f[3] or "",
                              causer = f[4] or "", arch = f[5] or "-", mesh = f[6] or "-", mat = f[7] or "-",
                              crawler = f[8] == "1", t = clock() })
end

local function on_note_obj(z, k)
    M.stats.got = M.stats.got + 1
    notes[ue.name(z)] = k
end

local function client_line(key, d)
    local k = notes[key]
    notes[key] = nil
    local host = ""
    if k then
        local diff = {}
        if k.mesh ~= d.mesh then diff[#diff + 1] = "mesh" end
        if k.mat ~= d.mat then diff[#diff + 1] = "mat" end
        if k.arch ~= d.arch then diff[#diff + 1] = "arch" end
        if k.crawler ~= d.crawler then diff[#diff + 1] = "crawler" end
        host = string.format(" | host: arch=%s crawler=%s mesh=%s mat=%s -> %s", k.arch, yn(k.crawler), k.mesh, k.mat,
            #diff == 0 and "same" or ("DIFFERS: " .. table.concat(diff, " ")))
    end
    log.info("ai: kill [client]: %s | %s at %s%s", look_text(d), by_text(k), where_text(d), host)
end

-- <Zombie / boss>.OnRep_IsDead?, post (client)
local function on_rep_dead(c)
    local z = c:get()
    if not ue.valid(z) or ue.role(z) == ue.ROLE_AUTHORITY or ue.prop(z, "IsDead?") ~= true then return end
    local key = ue.name(z)
    if logged[key] then return end
    local now = clock()
    local b = born[key]
    if not b or now - b < BORN_MIN_S then
        -- the initial replication of a corpse: its OnRep runs before BeginPlay
        M.stats.corpses_in_view = M.stats.corpses_in_view + 1
        return
    end
    logged[key] = now
    local d = zi.describe(z)
    count(d)
    M.stats.client = M.stats.client + 1
    if notes[key] then
        client_line(key, d)
    else
        -- the host's note normally comes first; give it a moment (strings only are kept)
        ue.delay("ai-killlog", LINE_DELAY_MS, function() client_line(key, d) end)
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function M.init(c)
    core = c
    -- client tables keyed by copy full name: entries of copies that are gone
    -- are dropped once a minute (sdc_ai core)
    if core.forget_gone then
        core.forget_gone("killlog", function() return { born = born, notes = notes, logged = logged } end)
    end
    core.hook({ path = DMG .. "DamageTaken", kind = "bp", role = "host", feature = "killlog", alone = true,
                name = "killlog.damage", fn = on_damage_taken })
    core.hook({ path = core.ZM .. "Death", kind = "bp", role = "host", feature = "killlog", alone = true,
                name = "killlog.death", fn = on_zombie_death })
    core.hook({ path = core.BOSS .. "DeathEvent", kind = "bp", role = "host", feature = "killlog", alone = true,
                name = "killlog.boss", fn = on_boss_death })
    for _, cls in ipairs({ core.ZM, core.BOSS }) do
        core.hook({ path = cls .. "ReceiveBeginPlay", kind = "bp", role = "client", feature = "killlog",
                    name = "killlog.born", fn = on_begin_play_client })
        core.hook({ path = cls .. "OnRep_IsDead?", kind = "bp", role = "client", feature = "killlog",
                    name = "killlog.dead", fn = on_rep_dead })
    end
    core.on_obj("kill", "killlog", on_note_obj)
end

local function counts_text()
    local list = {}
    for l, n in pairs(counts) do list[#list + 1] = { l, n } end
    table.sort(list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = e[1] .. "=" .. e[2] end
    return #parts > 0 and table.concat(parts, " ") or "none"
end

function M.status_line()
    local s = M.stats
    return string.format("ai: kill log: host=%d client=%d (notes sent=%d got=%d, corpses come into view=%d) | %s",
        s.host, s.client, s.sent, s.got, s.corpses_in_view, counts_text())
end

local function maybe_summary(now)
    if now - summary.at < SUMMARY_S then return end
    summary.at = now
    local sig = M.stats.host .. "|" .. M.stats.client
    if sig == summary.sig then return end
    summary.sig = sig
    log.info("%s", M.status_line())
end

function M.host_tick(now)
    for a, h in pairs(hits) do
        if now - h.t > 30 then hits[a] = nil end
    end
    maybe_summary(now)
end

function M.client_tick(now)
    for k, n in pairs(notes) do
        if now - n.t > INFO_TTL then notes[k] = nil end
    end
    for k, t in pairs(logged) do
        if now - t > 300 then logged[k] = nil end
    end
    for k, t in pairs(born) do
        if now - t > 3600 then born[k] = nil end
    end
    maybe_summary(now)
end

function M.on_message(kind, f)
    if kind == "AIKL" then on_note(f) end
end

-- Role / world change: the counts stay for the whole game session.
function M.reset()
    hits, born, notes, logged = {}, {}, {}, {}
end

return M
