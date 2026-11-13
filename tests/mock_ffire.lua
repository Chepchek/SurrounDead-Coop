-- Mock test: friendly fire on / off (sdc_ffire 0.7.3, host setting
-- friendly_fire, default off) with the real sdc_admin / sdc_config /
-- sdc_i18n / sdc_log and stub engine, sdc_ai, sdc_throw.
--   1. the setting and the texts (RU / EN, group combat, notices "game")
--   2. the hook entries on sdc_ai's shared hooks (ApplyDamage pre + an
--      always-off post, SetBurning bp), gates, installed from the tick
--   3. ApplyDamage pre, host: each causer kind - other players' bullets /
--      blows / stomps dropped, own grenade, zombies, falls, barrels and
--      turrets untouched; a client's blast named as the host's by the
--      player-0 fallback (sdc_throw.blast_now)
--   4. SetBurning post, host: tracked fires (host's, clients'), own fire
--      wins, untracked Molotov actors, barrels untouched; switched off while
--      players burn: where they stand (4b), by whose fire set them burning
--      after they ran out of it (4c)
--   5. SetBurning post, client copies (own throw, the thrower's PlayerId);
--      switched off: where they stand, by the record after running out
--   6. RULES|ff: the host sends it to players it let in (not to a waiting
--      one), again after a switch and a hello; the client's notices (on
--      join only when on, after the character and the join cover; every
--      switch later), a world reset
-- usage: lua mock_ffire.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end
local function say(s) io.write(s, "\n") end

FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
RegisterConsoleCommandHandler = function() end

local CLK = 100.0
os.clock = function() return CLK end
local function advance(s) CLK = CLK + s end

-- ------------------------------------------------------------ fake objects
local next_addr = 1000
local function obj(class, name, props)
    next_addr = next_addr + 16
    local o = props or {}
    o._class, o._name, o._addr = class, name, next_addr
    return o
end
local function player(name, x, y, pid)
    local pc = obj("BP_PlayerController_C", name .. "_PC")
    local ps = obj("PlayerState", name .. "_PS", { _pid = pid })
    local p = obj("BP_PlayerCharacter_C", name, { Controller = pc, PlayerState = ps, _loc = { X = x, Y = y, Z = 100 } })
    p.stopped = 0
    p.StopBurning = function(self) self.stopped = self.stopped + 1 end
    pc.key = name .. "_PC"
    return p, pc
end
local host_pawn, host_pc = player("Host", 0, 0, 256)
local a_pawn, a_pc = player("Ann", 300, 0, 257)
local b_pawn, b_pc = player("Bob", 0, 300, 258)
local zombie = obj("BP_Zombie_Walker_C", "Zombie_1", { _loc = { X = 100, Y = 100, Z = 100 } })
local barrel = obj("BP_ExplosiveBarrel_C", "Barrel_1", { _loc = { X = 50, Y = 50, Z = 100 } })
local turret = obj("BP_BuildableTurret_C", "Turret_1", { _loc = { X = 80, Y = 0, Z = 100 } })
local NONE = obj("", "None", { _invalid = true })
-- ApplyDamage's DamageTypeClass (work\re\pseudo): explosives and firearm / melee
-- body hits Damage_Body_C, headshots Damage_Headshot_C; hunger, thirst,
-- radiation, drowning DamageType; infection (MedicalComponent) None
local BODY = obj("BlueprintGeneratedClass", "Damage_Body_C")
local HEAD = obj("BlueprintGeneratedClass", "Damage_Headshot_C")
local DTYPE = obj("Class", "DamageType")

local W = { me = host_pawn, molotovs = {}, players = {} }
local function valid(o) return type(o) == "table" and not o._invalid end
package.loaded["sdc_ue"] = {
    valid = valid,
    try = function(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end,
    prop = function(o, k) return valid(o) and rawget(o, k) or nil end,
    location = function(o) return valid(o) and o._loc or nil end,
    local_pawn = function() return W.me end,
    short = function(o) return valid(o) and o._name or "<none>" end,
    name = function(o) return valid(o) and o._name or "<none>" end,
    class_name = function(o) return valid(o) and o._class or "" end,
    find_all = function(cls)
        if cls == "BP_Throwable_Molotov_C" then return W.molotovs end
        if cls == "BP_PlayerCharacter_C" then return W.players end
        return {}
    end,
    delay = function() end, exec = function() end, ksl = function() return nil end, find_object = function() return nil end,
    pawn_of = function(pc) return pc and pc.pawn end,
}
package.loaded["sdc_ctx"] = {
    addr = function(o) return valid(o) and o._addr or nil end,
    class_name = function(o) return valid(o) and o._class or "" end,
}
-- sdc_ai: the shared hooks (entries kept, installed by install_now)
local entries, installs = {}, 0
local handles = {}
package.loaded["sdc_ai"] = {
    hook_external = function(spec)
        entries[#entries + 1] = spec
        local h = handles[spec.path]
        if not h then h = { installed = false }; handles[spec.path] = h end
        return h
    end,
    install_now = function() installs = installs + 1 end,
}
-- sdc_throw's records
local T = { boom = nil, fires = {} }
package.loaded["sdc_throw"] = {
    blast_now = function(max_s)
        local b = T.boom
        if not b or CLK - b.t > (max_s or 0.25) then return nil end
        return b
    end,
    fires_near = function(loc, r)
        local out = {}
        for _, f in ipairs(T.fires) do
            local dx, dy = f.loc.X - loc.X, f.loc.Y - loc.Y
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= r then out[#out + 1] = { pc = f.pc, own = f.own, who = f.who, d = d } end
        end
        return out
    end,
}
package.loaded["sdc_appearance"] = { player_id = function(p) return p.PlayerState and p.PlayerState._pid or nil end }
local COVER = { visible = false }
package.loaded["sdc_ui"] = { join_cover_model = function() return { visible = COVER.visible } end }
local sent, handlers = {}, {}
package.loaded["sdc_net"] = {
    on = function(kind, fn) handlers[kind] = fn end,
    send_to = function(pc, kind, ...) sent[#sent + 1] = { to = pc.key, kind = kind, f = { ... } } return true end,
    broadcast = function() end,
}
local function sent_of(kind, to, f1)
    local out = {}
    for _, m in ipairs(sent) do
        if m.kind == kind and (to == nil or m.to == to) and (f1 == nil or m.f[1] == f1) then out[#out + 1] = m end
    end
    return out
end
package.loaded["sdc_players"] = {}
package.loaded["sdc_persist"] = { steam_of = function() return nil end }

local log = require("sdc_log")
local said = {}
local real_say = log.say
log.say = function(key, kind, secs, ...)
    said[#said + 1] = { key = key, kind = kind }
    return real_say(key, kind, secs, ...)
end
local function said_n(key)
    local n = 0
    for _, s in ipairs(said) do if s.key == key then n = n + 1 end end
    return n
end
local lines = {}
log.info = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
local function logged(pat)
    for _, l in ipairs(lines) do if l:find(pat, 1, true) then return l end end
    return nil
end
local cfg = require("sdc_config")
cfg.save = function() return true end
local i18n = require("sdc_i18n")

-- ---------------------------------------------------------------- 1. setting and texts
say("== 1. the setting and the texts")
local row = i18n.schema_row("friendly_fire")
check(row and row[2] == "bool" and row[3] == false and cfg.get("friendly_fire") == false,
    "friendly_fire: bool, default off (players cannot hurt each other)")
check(row and row[4]:find("Хост: огонь по своим", 1, true) ~= nil and type(i18n.DESC_EN.friendly_fire) == "string"
    and i18n.DESC_EN.friendly_fire:find("Host: friendly fire", 1, true) ~= nil, "Russian description + DESC_EN")
check(i18n.LABEL.friendly_fire and i18n.LABEL.friendly_fire[1] == "Огонь по своим"
    and i18n.LABEL.friendly_fire[2] == "Friendly fire", "label «Огонь по своим» / Friendly fire")
check(i18n.group_of("friendly_fire") == "combat", "Settings -> all features: group combat")
local in_group = false
for _, g in ipairs(i18n.groups()) do
    if g.id == "combat" then for _, k in ipairs(g.keys) do if k == "friendly_fire" then in_group = true end end end
end
check(in_group, "listed in the combat group")
local bad = {}
for _, k in ipairs({ "ff_on_host", "ff_off_host", "ff_join_on", "ff_turned_on", "ff_turned_off" }) do
    local t = log.TEXT[k]
    if not (t and t[1] and t[2] and not t[1]:find("[\208\209]") and t[2]:find("[\208\209]")
        and i18n.SAY_CLASS[k] == "game") then bad[#bad + 1] = k end
end
check(#bad == 0, "notices: English log, Russian screen, class game " .. table.concat(bad, ","))
check(i18n.STR.ru.wa_sec_rules and i18n.STR.en.wa_sec_rules and i18n.STR.ru.wa_ff_cap and i18n.STR.en.wa_ff_cap,
    "World tab: the rules heading and the caption in RU / EN")

-- ---------------------------------------------------------------- 2. hooks
say("== 2. hook entries")
local S = { role = "host", remote = {}, remote_pcs = {} }
local admin = require("sdc_admin")
admin.install(S)
local ff = require("sdc_ffire")
ff.install(S)
local by = {}
for _, e in ipairs(entries) do by[e.path .. "|" .. e.kind] = e end
local DMG = by["/Script/Engine.GameplayStatics:ApplyDamage|pre"]
local POST = by["/Script/Engine.GameplayStatics:ApplyDamage|post"]
local BURN = by["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetBurning|bp"]
check(DMG and type(DMG.fn) == "function" and type(DMG.gate) == "function", "ApplyDamage: a pre subscriber through sdc_ai.hook_external")
check(POST and POST.gate() == false, "ApplyDamage: an always-off post entry (sdc_ai keeps the engine hook pre + post)")
check(BURN and type(BURN.fn) == "function", "SetBurning: a Blueprint (post) subscriber")
check(DMG.gate() == false and BURN.gate() == false, "host alone: no gate open")
S.remote_pcs = { a_pc, b_pc }
check(DMG.gate() == true and BURN.gate() == true, "host with clients, friendly fire off: gates open")
installs = 0
ff.tick()
check(installs == 1, "the tick installs the hooks itself (sdc_ai's tick may not run)")
handles["/Script/Engine.GameplayStatics:ApplyDamage"].installed = true
handles["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetBurning"].installed = true
ff.tick()
check(installs == 1, "installed: not asked again")
-- friendly fire on from the start: the burn hook is still installed (it
-- remembers whose fire set a player burning, for switching off)
handles["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetBurning"].installed = false
cfg.set("friendly_fire", true)
ff.tick()
check(installs == 2, "friendly fire on, players here: the tick installs the burn hook too")
handles["/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetBurning"].installed = true
cfg.set("friendly_fire", false)
ff.tick()
cfg.set("friendly_fire", true)
check(DMG.gate() == false and BURN.gate() == true,
    "friendly fire on: the damage gate closed; the burn hook stays (it only remembers whose fire set a player burning)")
cfg.set("friendly_fire", false)

-- ---------------------------------------------------------------- 3. ApplyDamage
say("== 3. ApplyDamage (host, friendly fire off)")
local function param(v) return { get = function() return v end, set = function(_, nv) v = nv end, v = function() return v end } end
-- dtype: the DamageTypeClass (default Damage_Body_C; false: the param reads nil)
local function hit(victim, causer, dmg, dtype)
    if dtype == nil then dtype = BODY elseif dtype == false then dtype = nil end
    local d = param(dmg or 30)
    DMG.fn(param(nil), param(victim), d, param(nil), param(causer), param(dtype))
    return d.v()
end
check(hit(zombie, a_pawn) == 30, "a client's bullet in a zombie: untouched")
check(hit(zombie, host_pawn) == 30, "the host's knife in a zombie: untouched")
check(hit(a_pawn, zombie) == 30, "a zombie bites a client: untouched")
check(hit(host_pawn, NONE) == 30, "a fall / a burn's tick (no causer): untouched")
check(hit(a_pawn, barrel) == 30 and hit(a_pawn, turret) == 30, "a barrel / a turret: untouched")
check(hit(host_pawn, a_pawn) == 0, "a client shoots the host: dropped")
check(logged("ffire: 30.0 damage to host from Ann dropped (friendly fire off)") ~= nil, "log line")
check(hit(a_pawn, host_pawn, 55) == 0, "the host shoots / stabs a client: dropped")
check(hit(b_pawn, a_pawn, 40) == 0, "a client stomps another client: dropped")
check(hit(host_pawn, host_pawn, 80) == 80, "the host's own frag at its feet: hurts")
check(hit(a_pawn, a_pawn, 80) == 80, "a client's own grenade (its character as the causer): hurts")
-- a client's frag with the player-0 fallback: the game names the host
-- (the frag's damage loop: Damage_Body_C)
T.boom = { pc = a_pc._addr, who = "Ann", short = "BP_Throwable_Frag_C", loc = { X = 100, Y = 0, Z = 100 }, t = CLK }
check(hit(host_pawn, host_pawn, 90, BODY) == 0, "Ann's frag (named as the host's) on the host: dropped")
check(logged("Ann's BP_Throwable_Frag_C (its thrower; the game named the host)") ~= nil, "log says whose it was")
check(hit(a_pawn, host_pawn, 90, BODY) == 90, "... on Ann herself: her own blast hurts")
check(hit(b_pawn, host_pawn, 90, BODY) == 0, "... on Bob: dropped")
-- the host's own ticks in the same moment also name its character as the
-- causer (victim == causer), with another damage class: its own damage
check(hit(host_pawn, host_pawn, 4, NONE) == 4 and hit(host_pawn, host_pawn, 4, false) == 4,
    "Ann's blast 1 m away: the host's infection tick (no damage class) still hurts the host")
check(hit(host_pawn, host_pawn, 15, DTYPE) == 15,
    "... the host's hunger / thirst / radiation / drowning tick (DamageType) still hurts the host")
-- bleeding names no causer (MedicalComponent Bleed -> Svr_Damage:
-- ApplyDamage(self, d, None, None, DamageType)): never touched, before the
-- damage class check too
check(hit(host_pawn, NONE, 3, DTYPE) == 3, "... the host's bleeding tick (no causer) still hurts the host")
check(hit(a_pawn, host_pawn, 50, HEAD) == 0, "... the host's headshot on Ann (Damage_Headshot_C): not her blast, dropped")
T.boom.loc = { X = 9000, Y = 0, Z = 100 }
check(hit(host_pawn, host_pawn, 90) == 90, "a client's blast far away: the host's own damage")
T.boom.loc = { X = 100, Y = 0, Z = 100 }
advance(0.5)
check(hit(host_pawn, host_pawn, 90) == 90, "half a second later: the host's own damage again")
T.boom = { pc = nil, who = "host", short = "BP_Throwable_Frag_C", loc = { X = 0, Y = 0, Z = 100 }, t = CLK }
check(hit(host_pawn, host_pawn, 90) == 90 and hit(a_pawn, host_pawn, 90) == 0,
    "the host's own frag: hurts the host, not a client")
T.boom = nil
local st0 = ff.stats.blocked
check(st0 >= 6 and ff.stats.own >= 4 and ff.stats.blast_fix == 2, "counters: blocked / own / client blasts")

-- ---------------------------------------------------------------- 4. burns, host
say("== 4. Molotov burns (host)")
-- through the gate, as sdc_ai's dispatcher runs it
local function burn(p, on)
    if BURN.gate() ~= true then return end
    BURN.fn(param(p), param(on ~= false), param(10))
end
local function fresh() host_pawn.stopped, a_pawn.stopped, b_pawn.stopped = 0, 0, 0 end
T.fires = { { pc = nil, who = "host", loc = { X = 300, Y = 50, Z = 0 } } }   -- the host's fire next to Ann
fresh()
burn(a_pawn)
check(a_pawn.stopped == 1, "Ann in the host's Molotov fire: put out")
check(logged("ffire: Ann set on fire by host's Molotov: put out") ~= nil, "log line")
burn(a_pawn, false)
check(a_pawn.stopped == 1, "SetBurning(false): nothing")
T.fires = { { pc = nil, who = "host", loc = { X = 0, Y = 50, Z = 0 } } }
burn(host_pawn)
check(host_pawn.stopped == 0, "the host in its own fire: burns")
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 150, Y = 150, Z = 0 } } }   -- Ann's fire between everyone
fresh()
burn(a_pawn); burn(b_pawn); burn(host_pawn)
check(a_pawn.stopped == 0 and b_pawn.stopped == 1 and host_pawn.stopped == 1,
    "Ann's fire: Ann burns, Bob and the host are put out")
fresh()
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 300, Y = 0, Z = 0 } },
            { pc = b_pc._addr, who = "Bob", loc = { X = 350, Y = 0, Z = 0 } } }
burn(a_pawn)
check(a_pawn.stopped == 0 and ff.stats.burns_kept >= 1, "Ann in her own and Bob's fire: she walked into her own, burns")
-- untracked (throw_sync off): the Molotov actor, its Owner
T.fires = {}
fresh()
local mol = obj("BP_Throwable_Molotov_C", "Molotov_9", { _loc = { X = 320, Y = 0, Z = 0 } })
mol.GetOwner = function() return nil end
W.molotovs = { mol }
burn(a_pawn); burn(host_pawn)
check(a_pawn.stopped == 1 and host_pawn.stopped == 0 and ff.stats.untracked == 1,
    "an untracked Molotov (no Owner = the host's): Ann put out, the host burns")
mol.GetOwner = function() return b_pawn end
fresh()
burn(a_pawn)
check(a_pawn.stopped == 1, "an untracked Molotov owned by Bob's character: Ann put out")
W.molotovs = {}
fresh()
burn(a_pawn)
check(a_pawn.stopped == 0, "no Molotov near (a barrel's fire): burns")
cfg.set("friendly_fire", true)
T.fires = { { pc = nil, who = "host", loc = { X = 300, Y = 50, Z = 0 } } }
fresh()
burn(a_pawn)
check(a_pawn.stopped == 0, "friendly fire on: Ann in the host's fire burns (the hook only remembers whose fire)")
T.fires = {}
cfg.set("friendly_fire", false)

-- ---------------------------------------------------------------- 4b. switched off while players burn
say("== 4b. friendly fire switched off while players burn (host, no SetBurning record)")
-- while it was on, Ann's Molotov set everyone near it on fire; the burn goes
-- on by itself (Event_Fire, causer None) and her fire skips burning players.
-- Here no SetBurning record stands for these burns (the records of section 4
-- are older than a burn lasts): each is judged where it stands
advance(13)
local function burning(h, a, b) host_pawn["Burning?"], a_pawn["Burning?"], b_pawn["Burning?"] = h, a, b end
a_pc.pawn, b_pc.pawn = a_pawn, b_pawn
cfg.set("friendly_fire", true)
ff.tick()
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 150, Y = 150, Z = 0 } } }   -- Ann's fire between everyone
burning(true, true, true)
fresh()
local swept0, out0 = ff.stats.swept, ff.stats.burns_out
cfg.set("friendly_fire", false)
ff.tick()
check(b_pawn.stopped == 1 and host_pawn.stopped == 1,
    "switched off: Bob's and the host's burns from Ann's Molotov put out at the next tick")
check(a_pawn.stopped == 0, "Ann in her own fire: keeps burning")
check(ff.stats.swept == swept0 + 2 and ff.stats.burns_out == out0 + 2, "counters: put out on switching off")
check(logged("ffire: Bob was burning from Ann's Molotov when friendly fire was switched off: put out") ~= nil, "log line")
fresh()
ff.tick()
check(b_pawn.stopped == 0 and host_pawn.stopped == 0, "the next tick: not again (only on the switch)")
-- a burn with no other player's fire near (a barrel), players not burning
cfg.set("friendly_fire", true)
ff.tick()
T.fires = { { pc = b_pc._addr, who = "Bob", loc = { X = 850, Y = 0, Z = 0 } } }   -- Bob's fire 5.5 m from Ann
burning(true, false, false)
fresh()
cfg.set("friendly_fire", false)
ff.tick()
check(host_pawn.stopped == 0 and a_pawn.stopped == 0 and b_pawn.stopped == 0,
    "the host burning far from any player's fire, Ann next to Bob's fire but not burning: untouched")
-- nobody else in the world: nothing to judge (and nothing blocked)
cfg.set("friendly_fire", true)
ff.tick()
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 150, Y = 150, Z = 0 } } }
burning(true, false, false)
S.remote_pcs = {}
fresh()
cfg.set("friendly_fire", false)
ff.tick()
check(host_pawn.stopped == 0, "switched off with no players connected: not touched")
S.remote_pcs = { a_pc, b_pc }
burning(nil, nil, nil)
T.fires = {}
fresh()

-- ---------------------------------------------------------------- 4c. ran out of the fire
say("== 4c. switched off after the burning players ran out of the fire (host)")
-- while it is on, the SetBurning hook only remembers whose fire set a player
-- burning (it stands in that fire then); a burning player runs out of it
local function at(p, x, y) p._loc = { X = x, Y = y, Z = 100 } end
cfg.set("friendly_fire", true)
ff.tick()
check(BURN.gate() == true and DMG.gate() == false, "friendly fire on, players here: the burn hook remembers, damage passes")
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 0, Y = 400, Z = 0 } } }   -- Ann's fire at Bob's feet
fresh()
burn(b_pawn)
check(b_pawn.stopped == 0, "friendly fire on: Bob set burning by Ann's fire burns")
T.fires = { { pc = nil, who = "host", loc = { X = 0, Y = -100, Z = 0 } } }       -- the host in its own fire
burn(host_pawn)
T.fires = {}                                                                       -- Ann at a burning barrel
burn(a_pawn)
check(host_pawn.stopped == 0 and a_pawn.stopped == 0, "the host in its own fire, Ann at a barrel: burn")
-- 3 s later: Bob 9 m from Ann's fire, the host inside Ann's fire (it skips
-- a burning player), Ann next to Bob's fire
advance(3)
at(b_pawn, 0, 1300); at(host_pawn, 0, 700); at(a_pawn, 2000, 0)
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 0, Y = 400, Z = 0 } },
            { pc = nil, who = "host", loc = { X = 0, Y = -100, Z = 0 } },
            { pc = b_pc._addr, who = "Bob", loc = { X = 2100, Y = 0, Z = 0 } } }
burning(true, true, true)
fresh()
local lit0 = ff.stats.swept_lit
cfg.set("friendly_fire", false)
ff.tick()
check(b_pawn.stopped == 1, "switched off: Bob's burn from Ann's fire put out, though he ran 9 m out of it")
check(ff.stats.swept_lit == lit0 + 1
    and logged("ffire: Bob was burning from Ann's Molotov when friendly fire was switched off: put out (it caught fire there 3.0 s ago)") ~= nil,
    "counter and log line: where he caught fire")
check(host_pawn.stopped == 0, "the host set burning by its own fire, now inside Ann's: keeps burning")
check(a_pawn.stopped == 0, "Ann set burning by a barrel, now next to Bob's fire: keeps burning")
-- a record older than a burn lasts stands for nothing: judged where it is
cfg.set("friendly_fire", true)
ff.tick()
at(b_pawn, 0, 300)
T.fires = { { pc = a_pc._addr, who = "Ann", loc = { X = 0, Y = 400, Z = 0 } } }
burn(b_pawn)
advance(13)
at(b_pawn, 0, 1300)
burning(nil, nil, true)
fresh()
cfg.set("friendly_fire", false)
ff.tick()
check(b_pawn.stopped == 0, "Bob's record 13 s old (a burn lasts 10-12 s), no fire near him now: not touched")
at(b_pawn, 0, 300); at(host_pawn, 0, 0); at(a_pawn, 300, 0)
burning(nil, nil, nil)
T.fires = {}
fresh()

-- ---------------------------------------------------------------- 5. burns, client copies
say("== 5. Molotov copies on a client")
S.role = "client"
S.client = { access = "ok" }
S.remote_pcs = {}
ff.tick()   -- the role changed: the rule is the next host's
check(BURN.gate() == false and DMG.gate() == false, "a client before the host's rule: nothing (an older host)")
handlers.RULES({ "ff", "0" })
check(ff._client().ff == false and BURN.gate() == true and DMG.gate() == false, "RULES|ff|0: the client puts out copies' burns")
W.me = a_pawn   -- this machine is Ann's
fresh()
T.fires = { { own = false, who = "256", loc = { X = 300, Y = 0, Z = 0 } } }
burn(a_pawn)
check(a_pawn.stopped == 1, "Ann's own character in the host's copy fire: put out here")
T.fires = { { own = true, loc = { X = 300, Y = 0, Z = 0 } } }
burn(a_pawn)
check(a_pawn.stopped == 1, "in her own copy: burns")
burn(b_pawn)
check(b_pawn.stopped == 1, "Bob in Ann's copy fire (her throw): put out on her screen")
fresh()
T.fires = { { own = false, who = "258", loc = { X = 0, Y = 300, Z = 0 } } }
burn(b_pawn)
check(b_pawn.stopped == 0, "Bob in his own copy fire (his PlayerId): burns")
T.fires = { { own = false, who = "256", loc = { X = 0, Y = 300, Z = 0 } } }
burn(b_pawn)
check(b_pawn.stopped == 1, "Bob in the host's copy fire: put out")
fresh()
T.fires = { { own = false, who = nil, loc = { X = 0, Y = 300, Z = 0 } } }
burn(b_pawn)
check(b_pawn.stopped == 0, "Bob in a copy fire of an unknown thrower: left as it is")
check(ff.stats.copies_out >= 3, "counter: copies put out")
-- the host switches friendly fire off while copies burn here (while it was
-- on, the copies' fire set them burning and the hook let them be); no
-- SetBurning record stands for these burns (older than a burn lasts)
advance(13)
handlers.RULES({ "ff", "1" })
ff.tick()
T.fires = { { own = false, who = "256", loc = { X = 300, Y = 0, Z = 0 } },    -- the host's copy fire at Ann
            { own = false, who = "258", loc = { X = 0, Y = 300, Z = 0 } } }   -- Bob's own copy fire
W.players = { a_pawn, b_pawn, host_pawn }
burning(nil, true, true)
fresh()
local sw0 = ff.stats.swept
handlers.RULES({ "ff", "0" })
check(a_pawn.stopped == 0, "RULES|ff|0: nothing until the tick")
ff.tick()
check(a_pawn.stopped == 1 and ff.stats.swept == sw0 + 1, "then Ann's burn from the host's copy fire is put out here")
check(b_pawn.stopped == 0, "Bob standing in his own copy fire too: left burning")
check(host_pawn.stopped == 0, "the host's character not burning: untouched")
fresh()
ff.tick()
handlers.RULES({ "ff", "0" })
ff.tick()
check(a_pawn.stopped == 0, "the same rule again: not again")
-- while it is on, the host's copy fire sets Bob burning here; he runs 9 m
-- out of it before the host switches it off
handlers.RULES({ "ff", "1" })
ff.tick()
check(BURN.gate() == true, "RULES|ff|1: the burn hook only remembers whose copy fire")
T.fires = { { own = false, who = "256", loc = { X = 0, Y = 400, Z = 0 } } }   -- the host's copy fire at Bob's feet
burning(nil, nil, nil)
fresh()
burn(b_pawn)
check(b_pawn.stopped == 0, "friendly fire on: Bob set burning by the host's copy fire burns here")
advance(2)
b_pawn._loc = { X = 0, Y = 1300, Z = 100 }
burning(nil, nil, true)
handlers.RULES({ "ff", "0" })
ff.tick()
check(b_pawn.stopped == 1, "RULES|ff|0: Bob's burn put out here, though he ran 9 m out of that copy fire")
b_pawn._loc = { X = 0, Y = 300, Z = 100 }
burning(nil, nil, nil)
W.players = {}
T.fires = {}

-- ---------------------------------------------------------------- 6. RULES|ff and the notices
say("== 6. the rule and the notices")
-- host side
S.role = "host"
W.me = host_pawn
ff.tick()
local function remote(key, pc, access)
    local r = { key = key, pc = pc, name = key, hello = true, access = access, index = 1 }
    S.remote[key] = r
    return r
end
cfg.set("join_access", "approve")   -- Bob waits for the host's answer
local ra = remote("Ann_PC", a_pc, "ok")
local rb = remote("Bob_PC", b_pc, "wait")
S.remote_pcs = { a_pc, b_pc }
sent = {}
admin.tick()
check(#sent_of("RULES", "Ann_PC", "ff") == 1 and sent_of("RULES", "Ann_PC", "ff")[1].f[2] == "0", "RULES|ff|0 to Ann (let in)")
check(#sent_of("RULES", "Bob_PC", "ff") == 0, "nothing to Bob while he waits for the host's answer")
check(#sent_of("RULES", "Bob_PC", "cheats") == 1, "(the cheats rule goes as before)")
admin.tick()
check(#sent_of("RULES", nil, "ff") == 1, "sent once")
rb.access = "ok"
admin.tick()
check(#sent_of("RULES", "Bob_PC", "ff") == 1, "Bob let in: RULES|ff|0 to him")
cfg.set("friendly_fire", true)
admin.tick()
local ffa = sent_of("RULES", "Ann_PC", "ff")
check(#ffa == 2 and ffa[2].f[2] == "1" and #sent_of("RULES", "Bob_PC", "ff") == 2, "the switch: RULES|ff|1 to both")
check(logged("admin: rules to Ann_PC: friendly fire ON") ~= nil, "log line")
admin.on_hello(ra)
admin.tick()
check(#sent_of("RULES", "Ann_PC", "ff") == 3, "a hello: sent again")
cfg.set("friendly_fire", false)
admin.reset("test")
S.remote = {}
-- client side
S.role = "client"
W.me = nil
ff.tick()
ff.reset("world:loadmap")
said = {}
handlers.RULES({ "ff", "1" })
check(ff._client().ff == true and BURN.gate() == true, "RULES|ff|1: friendly fire on, burns only remembered")
ff.tick()
check(said_n("ff_join_on") == 0, "no character yet: no notice")
W.me = a_pawn
S.client.access = "wait"
ff.tick()
check(said_n("ff_join_on") == 0, "waiting for the host's answer: no notice")
S.client.access = "ok"
COVER.visible = true
ff.tick()
check(said_n("ff_join_on") == 0, "the join cover still up: no notice")
COVER.visible = false
ff.tick()
check(said_n("ff_join_on") == 1 and said[#said].kind == "info", "then: «В этом мире включён огонь по своим» (game notice)")
ff.tick()
check(said_n("ff_join_on") == 1, "once")
handlers.RULES({ "ff", "1" })
ff.tick()
check(#said == 1, "the same rule again (a hello): nothing")
handlers.RULES({ "ff", "0" })
ff.tick()
check(said_n("ff_turned_off") == 1, "the host switched it off: «Хост выключил огонь по своим»")
handlers.RULES({ "ff", "1" })
ff.tick()
check(said_n("ff_turned_on") == 1, "and on again: «Хост включил огонь по своим»")
-- a world where it is off: nothing on joining
ff.reset("world:loadmap")
said = {}
handlers.RULES({ "ff", "0" })
ff.tick()
check(#said == 0 and ff._client().told == false, "joining a world with friendly fire off: no notice")
handlers.RULES({ "ff", "1" })
ff.tick()
check(said_n("ff_turned_on") == 1, "switched on later: the notice")
-- an off-then-on before the character came: the join notice once
ff.reset("world:loadmap")
said = {}
W.me = nil
handlers.RULES({ "ff", "1" }); handlers.RULES({ "ff", "0" }); handlers.RULES({ "ff", "1" })
W.me = a_pawn
ff.tick()
check(#said == 1 and said_n("ff_join_on") == 1, "switched while joining: one join notice")
-- the old cheats rule still works beside it
handlers.RULES({ "cheats", "0" })
check(admin._rules().cheats == false, "RULES|cheats still handled")
check(ff.status_line():find("ffire: friendly_fire=false", 1, true) ~= nil, "status line: " .. ff.status_line())

-- ---------------------------------------------------------------- 7. the real sdc_ai
say("== 7. the real sdc_ai: one engine hook, pre + post")
local regs, natives = {}, {}
RegisterHook = function(path, pre, post) regs[path] = { pre = pre, post = post } return 1, 2 end
local U = package.loaded["sdc_ue"]
U.hook_native = function(path, key, fn) natives[path] = { key = key, fn = fn } return true end
U.backoff = function() end
local X = package.loaded["sdc_ctx"]
X.set_idle_check = function() end
X.player_for = function() return nil end
package.loaded["sdc_ai"], package.loaded["sdc_ffire"] = nil, nil
local ai2 = require("sdc_ai")
local ff2 = require("sdc_ffire")
local S2 = { role = "host", remote = {}, remote_pcs = { a_pc } }
ff2.install(S2)
W.me = host_pawn
advance(5)
ff2.tick()
local APPLY = "/Script/Engine.GameplayStatics:ApplyDamage"
local SETB = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:SetBurning"
check(regs[APPLY] and type(regs[APPLY].pre) == "function" and type(regs[APPLY].post) == "function" and natives[APPLY] == nil,
    "ApplyDamage: RegisterHook with pre and post (kill credit can join later), not a pre-only native hook")
check(regs[SETB] and type(regs[SETB].pre) == "function", "SetBurning: hooked")
check(ff2.status_line():find("hooks damage=true burn=true", 1, true) ~= nil, "both installed")
local d = param(45)
regs[APPLY].pre(param({}), param(a_pawn), d, param(nil), param(host_pawn), param(nil))
check(d.v() == 0, "through the dispatcher: the host's hit on a client dropped")
d = param(45)
regs[APPLY].pre(param({}), param(zombie), d, param(nil), param(host_pawn), param(nil))
regs[APPLY].post(param({}), param(zombie), d, param(nil), param(host_pawn), param(nil))
check(d.v() == 45, "a zombie hit untouched; the post runs nothing")
cfg.set("friendly_fire", true)
d = param(45)
regs[APPLY].pre(param({}), param(a_pawn), d, param(nil), param(host_pawn), param(nil))
check(d.v() == 45, "friendly fire on: the same hit hurts")
cfg.set("friendly_fire", false)
T.fires = { { pc = nil, who = "host", loc = { X = 300, Y = 0, Z = 0 } } }
a_pawn.stopped = 0
regs[SETB].pre(param(a_pawn), param(true), param(9))
check(a_pawn.stopped == 1, "through the dispatcher: Ann's burn from the host's Molotov put out")
T.fires = {}
check(#ai2.status_lines() >= 1, "sdc_ai status still fine")

print = real_print
io.write(string.format("mock_ffire: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
