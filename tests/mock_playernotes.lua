-- Mock harness: sdc_playernotes - "<player> died / respawned" as the game's
-- own notification on every screen but that player's (host decides, PEV to
-- the clients, text in the RECEIVING player's language), cause of death from
-- the killing blow (BP_PlayerCharacter.ReceiveAnyDamage post), rate limit,
-- setting player_event_notes.
-- usage: lua mock_playernotes.lua <scripts dir>
-- Three machines in one Lua state (modules loaded once per machine, as
-- mock_notes_route does): the host and clients A ("Alice", Russian) and B
-- ("Bob", English). The game's CreateNotificationUI records what each screen
-- shows; host -> client messages go through the real encode / decode.
local SCRIPTS = arg[1]
package.path = SCRIPTS .. "/?.lua;" .. package.path

local T = 100.0
os.clock = function() return T end
local function advance(s) T = T + s end

local WORLD
local fails, total = 0, 0
local function check(cond, what)
    total = total + 1
    if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

-- ---------------------------------------------------------------- fake objects
local Obj = {}
Obj.__index = function(t, k)
    local v = rawget(Obj, k)
    if v ~= nil then return v end
    local m = rawget(t, "_m")[k]
    if m ~= nil then return m end
    return nil
end
local next_addr = 8192
local LVL = "/Game/Levels/LongdownValley.LongdownValley:PersistentLevel."
local function name_obj(s) return { ToString = function() return s end, _s = s } end
local function class_obj(chain)
    return { IsValid = function() return true end, GetFName = function() return name_obj(chain[1]) end }
end
local function new(w, chain, name, props, methods, path)
    next_addr = next_addr + 16
    local o = setmetatable({ _chain = chain, _name = name, _p = props or {}, _m = methods or {}, _addr = next_addr,
                             _valid = true }, Obj)
    o._full = chain[1] .. " " .. (path or (LVL .. name))
    w.objects[#w.objects + 1] = o
    w.paths[path or (LVL .. name)] = o
    return o
end
local function derives(o, cls)
    for _, c in ipairs(o._chain) do if c == cls then return true end end
    return false
end
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:GetFName() return name_obj(self._name) end
function Obj:GetClass() return class_obj(self._chain) end
function Obj:GetAddress() return self._addr end
function Obj:GetPropertyValue(n) return self._p[n] end
function Obj:SetPropertyValue(n, v) self._p[n] = v end
function Obj:GetOwner() return self._p._owner end
function Obj:GetOuter() return self._p._outer end
function Obj:IsLocalController() return self._p._local == true end
function Obj:IsA(cls) return cls ~= nil and cls._is ~= nil and derives(self, cls._is) end

-- ---------------------------------------------------------------- UE4SS globals
local function param(v) return { get = function() return v end, set = function() end } end
FName = function(s) return name_obj(s) end
FText = function(s) return name_obj(s) end
RegisterHook = function(path, a, b)
    WORLD.hooks[path] = WORLD.hooks[path] or {}
    table.insert(WORLD.hooks[path], { pre = a, post = b })
    return 1, 2
end
NotifyOnNewObject = function() end
StaticFindObject = function(path)
    local o = WORLD.paths[path]
    if o and o._valid then return o end
    return nil
end
FindAllOf = function(cls)
    local out = {}
    for _, o in ipairs(WORLD.objects) do if o._valid and derives(o, cls) then out[#out + 1] = o end end
    return out
end
FindFirstOf = function(cls) return FindAllOf(cls)[1] end
LoadAsset = function(path) return StaticFindObject(path) end
ExecuteInGameThreadWithDelay = function(_, fn) WORLD.timers[#WORLD.timers + 1] = fn; return #WORLD.timers end
ExecuteInGameThread = function(fn) fn() end
LoopInGameThreadWithDelay = function() return 1 end

local function run_timers(w)
    local prev = WORLD
    WORLD = w
    for _ = 1, 3 do
        local t = w.timers
        w.timers = {}
        for _, fn in ipairs(t) do fn() end
    end
    WORLD = prev
end

-- ---------------------------------------------------------------- worlds
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local SKULL = "/Game/UI/Textures/Survivors_Icon_Pack/256x256/Hunting_For_Food/T_HumanSkull_256x256.T_HumanSkull_256x256"
local BAG = "/Game/UI/Textures/over_250_survival_flat_icons/sleeping_bag.sleeping_bag"
local DMG_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:ReceiveAnyDamage"

local function world(id)
    return { id = id, objects = {}, paths = {}, hooks = {}, timers = {}, screen = {} }
end
local HW, AW, BW = world("host"), world("alice"), world("bob")

local function engine(w)
    WORLD = w
    new(w, { "GameplayStatics" }, "GPS", {}, {}, "/Script/Engine.Default__GameplayStatics")
    new(w, { "KismetSystemLibrary" }, "KSL", {}, {
        IsStandalone = function() return false end,
        IsServer = function() return w.id == "host" end,
    }, "/Script/Engine.Default__KismetSystemLibrary")
    new(w, { "GameFunctionLibrary_C" }, "Default__GameFunctionLibrary_C", {}, {
        CreateNotificationUI = function(_, text, icon, col, delay, force, wco)
            w.screen[#w.screen + 1] = { text = type(text) == "table" and text:ToString() or text, icon = icon,
                                        col = col, delay = delay, force = force, wco = wco }
        end,
    }, GFL_CDO)
    new(w, { "Texture2D" }, "T_HumanSkull_256x256", {}, {}, SKULL)
    new(w, { "Texture2D" }, "sleeping_bag", {}, {}, BAG)
    local lp = new(w, { "LocalPlayer" }, "LocalPlayer_0")
    local pc = new(w, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_0",
        { Player = lp, _local = true }, {})
    local pawn = new(w, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_0",
        { Controller = pc, ["PlayerDead?"] = false })
    pc._p.Pawn = pawn
    w.pc, w.pawn = pc, pawn
end
engine(HW); engine(AW); engine(BW)

-- the host's world: both clients' controllers and characters, AI classes, the damage event
WORLD = HW
new(HW, { "Function" }, "ReceiveAnyDamage", {}, {}, DMG_FN)
local CLASSES = {
    { "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C", "BP_MasterZombie_C" },
    { "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C", "BP_ZombieBoss_C" },
    { "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C", "BP_AnimalWolf_C" },
    { "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C", "BP_AnimalBear_C" },
    { "/Game/AI/Animals/BP_Animal.BP_Animal_C", "BP_Animal_C" },
    { "/Game/SmartAI/Blueprints/AI/AICharacters/BP_MasterAICharacter.BP_MasterAICharacter_C", "BP_MasterAICharacter_C" },
}
for _, c in ipairs(CLASSES) do
    local o = new(HW, { "BlueprintGeneratedClass" }, c[2], {}, {}, c[1])
    o._is = c[2]
end
local function remote(name, n)
    local conn = new(HW, { "IpConnection" }, "IpConnection_" .. n)
    local pc = new(HW, { "BP_PlayerController_C", "PlayerController" }, "BP_PlayerController_C_" .. n,
        { NetConnection = conn, Player = conn })
    local pawn = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_" .. n,
        { Controller = pc, ["PlayerDead?"] = false })
    pc._p.Pawn = pawn
    return pc, pawn
end
local apc, apawn = remote("Alice", 1)
local bpc, bpawn = remote("Bob", 2)
local AKEY, BKEY = apc:GetFullName(), bpc:GetFullName()
local zombie = new(HW, { "BP_Zombie_Roamer_C", "BP_MasterZombie_C", "Character" }, "BP_Zombie_Roamer_C_7", {})
local zctrl = new(HW, { "BP_ZombieAIController_C", "AIController" }, "BP_ZombieAIController_C_7", {})
local wolf = new(HW, { "BP_AnimalWolf_C", "BP_Animal_C", "Character" }, "BP_AnimalWolf_C_1", {})
local bear = new(HW, { "BP_AnimalBear_C", "BP_Animal_C", "Character" }, "BP_AnimalBear_C_1", {})
local bandit = new(HW, { "BP_Bandit_Rifle_C", "BP_MasterBandit_C", "BP_MasterAICharacter_C", "Character" }, "BP_Bandit_3", {})
local barrel = new(HW, { "BP_ExplosiveBarrel_C", "Actor" }, "BP_ExplosiveBarrel_2", {})
local bob_gun = new(HW, { "BP_M4Pickup_C", "Actor" }, "BP_M4Pickup_C_5", { _owner = bpawn })

-- ---------------------------------------------------------------- modules per machine
local function load_mods(w, lang, name)
    WORLD = w
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local m = { log = require("sdc_log"), ue = require("sdc_ue"), net = require("sdc_net"), cfg = require("sdc_config"),
                ctx = require("sdc_ctx") }
    m.cfg.set("language", lang)
    m.cfg.set("player_name", name)
    m.i18n = require("sdc_i18n")
    m.notes = require("sdc_notes")
    m.pn = require("sdc_playernotes")
    return m
end

local outbox = {}   -- host -> client: { to = pc, raw = encoded }
local HS = {
    role = "host",
    remote = {
        [AKEY] = { key = AKEY, pc = apc, name = "Alice", hello = true, dead = false, pawn = apawn },
        [BKEY] = { key = BKEY, pc = bpc, name = "Bob", hello = true, dead = false, pawn = bpawn },
    },
    remote_pcs = { apc, bpc },
}
local H = load_mods(HW, "ru", "Hosty")
H.net.send_to = function(pc, kind, ...)
    outbox[#outbox + 1] = { to = pc, kind = kind, raw = H.net.encode(kind, ...) }
    return true
end
H.notes.install(HS)
H.pn.install(HS)
local AS = { role = "client", remote = {}, remote_pcs = {} }
local A = load_mods(AW, "ru", "Alice")
A.notes.install(AS); A.pn.install(AS)
local BS = { role = "client", remote = {}, remote_pcs = {} }
local B = load_mods(BW, "en", "Bob")
B.notes.install(BS); B.pn.install(BS)

local CLIENT = { [apc] = { w = AW, m = A }, [bpc] = { w = BW, m = B } }
local function deliver()
    local out = outbox
    outbox = {}
    for _, e in ipairs(out) do
        local c = CLIENT[e.to]
        WORLD = c.w
        local kind, f = c.m.net.decode(e.raw)
        local h = c.m.net.handlers[kind]
        if h then h(f, c.w.pc) end
    end
    advance(0.2)
    run_timers(AW); run_timers(BW); run_timers(HW)
end
local function sent_to(pc, kind)
    local n = 0
    for _, e in ipairs(outbox) do if e.to == pc and (not kind or e.kind == kind) then n = n + 1 end end
    return n
end
local function shown(w, text)
    for _, s in ipairs(w.screen) do if s.text == text then return s end end
    return nil
end
local function count(w) return #w.screen end
local function tick() WORLD = HW; H.pn.tick() end
local function fire_damage(victim, dmg, inst, causer)
    WORLD = HW
    for _, h in ipairs(HW.hooks[DMG_FN] or {}) do
        local r = h.pre(param(victim), param(dmg), param(nil), param(inst), param(causer))
        assert(r == nil, "the damage hook returned a value")
    end
end
-- the killing blow as the game runs it: PlayerDead? set inside the damage call
local function kill(victim, dmg, inst, causer)
    victim._p["PlayerDead?"] = true
    fire_damage(victim, dmg, inst, causer)
end
local function respawn(rec, pc, pawn_name)
    WORLD = HW
    local p = new(HW, { "BP_PlayerCharacter_C", "Character" }, pawn_name, { Controller = pc, ["PlayerDead?"] = false })
    pc._p.Pawn = p
    rec.pawn, rec.dead = p, false
    return p
end
local rA, rB = HS.remote[AKEY], HS.remote[BKEY]

-- ---------------------------------------------------------------- scenarios
print("== P0. install, first sight")
check(A.net.handlers.PEV ~= nil and B.net.handlers.PEV ~= nil, "clients handle PEV")
-- the cause-of-death hook is off by default since the 0.7.1 crashes
tick()
check(not HW.hooks[DMG_FN], "by default the host does NOT hook BP_PlayerCharacter ReceiveAnyDamage (cause off)")
H.pn.CAUSE_HOOK = true   -- the rest covers the cause logic, still there behind the switch
tick()
check(HW.hooks[DMG_FN] and #HW.hooks[DMG_FN] == 1, "player_event_cause on: host hooked BP_PlayerCharacter ReceiveAnyDamage (clients connected)")
check(#outbox == 0 and count(HW) == 0, "first sight of the players: no event")
advance(1); tick()
check(#outbox == 0, "nothing while everyone lives")

print("== P1. Alice killed by a zombie: the host and Bob are told, Alice is not")
advance(0.6)
fire_damage(apawn, 20, zctrl, zombie)          -- an ordinary hit first
advance(0.2)
kill(apawn, 35, zctrl, zombie)
rA.dead = true                                  -- sdc_players.host_player_tick
advance(0.5); tick()
check(sent_to(bpc, "PEV") == 1, "PEV sent to Bob")
check(sent_to(apc) == 0, "nothing sent to Alice (her own death)")
local hs = shown(HW, "Alice погиб — убит зомби.")
check(hs ~= nil, "host's screen (Russian): " .. tostring(HW.screen[#HW.screen] and HW.screen[#HW.screen].text))
check(hs and hs.icon == HW.paths[SKULL], "with the game's skull icon")
check(hs and hs.col.R == 1 and hs.col.G == 0 and hs.col.B == 0, "in the game's red")
deliver()
check(shown(BW, "Alice was killed by a zombie.") ~= nil, "Bob's screen in English: " .. tostring(BW.screen[1] and BW.screen[1].text))
check(count(AW) == 0, "nothing on Alice's screen")

print("== P2. a hit on the body changes nothing; Alice respawns")
local before = count(HW)
fire_damage(apawn, 50, nil, bob_gun)
advance(2); tick()
check(count(HW) == before and #outbox == 0, "no second death notice")
respawn(rA, apc, "BP_PlayerCharacter_C_11")
advance(1); tick()
check(shown(HW, "Alice возродился.") ~= nil, "host's screen: respawned")
check(sent_to(bpc, "PEV") == 1 and sent_to(apc) == 0, "Bob told, Alice not")
deliver()
check(shown(BW, "Alice respawned.") ~= nil, "Bob's screen: respawned")
check(count(AW) == 0, "still nothing on Alice's screen")
local back_icon = shown(HW, "Alice возродился.")
check(back_icon and back_icon.icon == HW.paths[BAG], "respawn with the sleeping-bag icon")

print("== P3. rate limit: Alice dies again within 30 s")
local hn, bn = count(HW), count(BW)
advance(5); tick()
local apawn2 = HS.remote[AKEY].pawn
kill(apawn2, 99, zctrl, zombie)
rA.dead = true
advance(0.5); tick()
check(#outbox == 0 and count(HW) == hn, "second death within 30 s: not announced")
respawn(rA, apc, "BP_PlayerCharacter_C_12")
advance(1); tick()
check(#outbox == 0 and count(HW) == hn, "and no respawn notice for an unannounced death")
deliver()
check(count(BW) == bn, "Bob's screen unchanged")
check(H.pn.stats.limited >= 1, "counted as rate limited")

print("== P4. after 30 s: Bob kills Alice (his gun): Bob sees 'You killed', the host the killer's name")
advance(31); tick()
local apawn3 = rA.pawn
advance(0.4)
kill(apawn3, 60, bpc, bob_gun)
rA.dead = true
advance(0.5); tick()
check(shown(HW, "Alice погиб — его убил Bob.") ~= nil, "host's screen names the killer")
check(sent_to(bpc, "PEV") == 1 and sent_to(apc) == 0, "Bob told, Alice not")
deliver()
check(shown(BW, "You killed Alice.") ~= nil, "Bob's screen: You killed Alice.")
respawn(rA, apc, "BP_PlayerCharacter_C_13")
advance(1); tick(); deliver()

print("== P5. the host falls to death (own_watch): both clients told in their language, not the host's screen")
advance(1); tick()                               -- the tick sees the host alive
local hn5 = count(HW)
advance(0.3)
kill(HW.pawn, 999, nil, nil)                     -- OnLanded: ApplyDamage(self, 999, None, None)
WORLD = HW; H.pn.own_event("died", HW.pawn:GetAddress())
check(sent_to(apc, "PEV") == 1 and sent_to(bpc, "PEV") == 1, "PEV to Alice and Bob")
check(count(HW) == hn5, "nothing on the host's own screen")
deliver()
check(shown(AW, "Hosty погиб — разбился при падении.") ~= nil, "Alice (Russian): " .. tostring(AW.screen[#AW.screen] and AW.screen[#AW.screen].text))
check(shown(BW, "Hosty died from a fall.") ~= nil, "Bob (English): fall")
HW.pawn._p["PlayerDead?"] = false
WORLD = HW; H.pn.own_event("back", HW.pawn:GetAddress())
deliver()
check(shown(AW, "Hosty возродился.") ~= nil and shown(BW, "Hosty respawned.") ~= nil, "host respawned: both told")

print("== P6. Bob bleeds out (no causer, random damage): no cause in the text")
advance(1); tick()
advance(0.3)
kill(bpawn, 2.7, nil, nil)
rB.dead = true
advance(0.5); tick()
check(shown(HW, "Bob погиб.") ~= nil, "host: 'Bob погиб.' without a cause")
check(sent_to(apc, "PEV") == 1 and sent_to(bpc) == 0, "Alice told, Bob not")
deliver()
check(shown(AW, "Bob погиб.") ~= nil, "Alice: 'Bob погиб.'")
respawn(rB, bpc, "BP_PlayerCharacter_C_21")
advance(1); tick(); deliver()

print("== P7. a dead hit without a fresh 'alive' (no tick for 31 s): no cause")
advance(31)
local bp2 = rB.pawn
kill(bp2, 40, zctrl, zombie)
rB.dead = true
tick()
check(sent_to(apc, "PEV") == 1, "death still announced")
deliver()
check(shown(AW, "Bob погиб.") ~= nil and not shown(AW, "Bob погиб — убит зомби."), "but without a guessed cause")
respawn(rB, bpc, "BP_PlayerCharacter_C_22")
advance(1); tick(); deliver()

print("== P8. causes: wolf, bear, humans, barrel, own grenade, inexact fall damage")
local cl = H.pn._t.classify
WORLD = HW
check(cl(apawn3, 1, AKEY, 30, nil, wolf).kind == "wolf", "wolf")
check(cl(apawn3, 1, AKEY, 30, nil, bear).kind == "bear", "bear")
check(cl(apawn3, 1, AKEY, 30, nil, bandit).kind == "human", "bandit -> humans")
check(cl(apawn3, 1, AKEY, 30, nil, barrel).kind == nil, "an exploding barrel: no cause")
local a_nade = new(HW, { "BP_FragGrenade_C", "Actor" }, "BP_FragGrenade_1", { _owner = rA.pawn })
check(cl(rA.pawn, 1, AKEY, 80, nil, a_nade).kind == nil, "own grenade: no cause (self)")
check(cl(apawn3, 1, AKEY, 80, nil, apawn3).kind == nil, "hunger / radiation (causer = the victim): no cause")
check(cl(apawn3, 1, AKEY, 30, nil, nil).kind == "fall", "landing damage 30: fall")
check(cl(apawn3, 1, AKEY, 30.4, nil, nil).kind == nil, "30.4 without a causer: no cause")
local h = cl(apawn3, 1, AKEY, 50, HW.pc, nil)
check(h.kind == "player" and h.kkey == "host" and h.killer == "Hosty", "the host's own shot: player Hosty")

print("== P9. setting off on the host: nothing sent or shown")
advance(40); tick()
H.cfg.set("player_event_notes", false)
local hn9, an9 = count(HW), count(AW)
advance(0.4)
kill(rB.pawn, 40, zctrl, zombie)
rB.dead = true
advance(0.5); tick()
check(#outbox == 0 and count(HW) == hn9, "host off: no PEV, nothing on the host's screen")
respawn(rB, bpc, "BP_PlayerCharacter_C_23")
advance(1); tick()
check(#outbox == 0, "and no respawn notice")
H.cfg.set("player_event_notes", true)

print("== P10. setting off on a client: only that screen stays quiet")
advance(40); tick()
B.cfg.set("player_event_notes", false)
local bn10 = count(BW)
advance(0.4)
kill(rA.pawn, 40, zctrl, zombie)
rA.dead = true
advance(0.5); tick()
check(sent_to(bpc, "PEV") == 1, "the host still sends it")
deliver()
check(count(BW) == bn10, "Bob (off) shows nothing")
check(shown(HW, "Alice погиб — убит зомби.") ~= nil, "the host still shows it")
B.cfg.set("player_event_notes", true)
respawn(rA, apc, "BP_PlayerCharacter_C_14")
advance(1); tick(); deliver()

print("== P11. a player who leaves while dead, world reset")
advance(40); tick()
kill(rB.pawn, 40, zctrl, zombie)
rB.dead = true
HS.remote[BKEY] = nil
HS.remote_pcs = { apc }
advance(0.5); tick()
check(#outbox == 0, "gone before the tick: no notice")
check(H.pn._st.seen[BKEY] == nil, "its record dropped")
WORLD = HW; H.pn.reset("test world")
rA.dead = true
tick()
check(#outbox == 0, "after a reset: first sight again, no event")

print("== P12. language switch on a client follows its own panel language")
B.cfg.set("language", "ru")
WORLD = BW
check(B.pn.text("died", "Alice", "bear") == "Alice погиб — его задрал медведь.", "Bob in Russian now")
B.cfg.set("language", "en")
check(B.pn.text("died", "Alice", "player", "Hosty", false) == "Alice was killed by Hosty.", "player killer (en)")
check(B.pn.text("died", "Alice", "unknown-cause") == "Alice died.", "an unknown cause word: plain text")

print("== P13. wiring: sdc_respawn installs the module, its tick feeds own_watch's death / respawn")
do
    WORLD = HW
    for k in pairs(package.loaded) do if k:match("^sdc_") then package.loaded[k] = nil end end
    local loops = {}
    LoopInGameThreadWithDelay = function(_, fn) loops[#loops + 1] = fn; return #loops end
    local cfg2 = require("sdc_config")
    cfg2.set("player_name", "Hosty")
    cfg2.set("language", "en")
    local net2 = require("sdc_net")
    local out2 = {}
    net2.send_to = function(pc, kind, ...) out2[#out2 + 1] = { to = pc, kind = kind, args = { ... } }; return true end
    local respawn = require("sdc_respawn")
    local HS2 = { role = "host", in_menu = false, menu_since = 0, spawned = {},
                  remote = { [AKEY] = { key = AKEY, pc = apc, name = "Alice", hello = true, dead = false, pawn = rA.pawn } },
                  remote_pcs = { apc } }
    apc._p.Pawn = rA.pawn
    require("sdc_players").init(HS2, { remote_record = function() return nil end })
    respawn.install(HS2)
    local pn2 = package.loaded["sdc_playernotes"]
    check(type(pn2) == "table" and pn2 ~= H.pn, "sdc_respawn.install loaded sdc_playernotes")
    run_timers(HW)                                   -- the 5 s boot delay -> ue.every("respawn")
    local rtick = loops[#loops]
    check(type(rtick) == "function", "respawn tick captured")
    HW.pawn._p["PlayerDead?"] = false
    advance(1); WORLD = HW; rtick()                  -- own_watch: alive
    advance(1); WORLD = HW; rtick()
    check(#out2 == 0, "alive: nothing")
    HW.pawn._p["PlayerDead?"] = true
    advance(1); WORLD = HW; rtick()                  -- own_watch: died
    local n = 0
    for _, e in ipairs(out2) do if e.kind == "PEV" and e.to == apc and e.args[1] == "died" and e.args[2] == "Hosty" then n = n + 1 end end
    check(n == 1, "the host's own death -> PEV died to Alice")
    out2 = {}
    advance(1); WORLD = HW; rtick()
    check(#out2 == 0, "still dead: nothing more")
    local p2 = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_HOST2", { Controller = HW.pc, ["PlayerDead?"] = false })
    HW.pc._p.Pawn = p2
    advance(1); WORLD = HW; rtick()                  -- own_watch: a living character again
    n = 0
    for _, e in ipairs(out2) do if e.kind == "PEV" and e.to == apc and e.args[1] == "back" then n = n + 1 end end
    check(n == 1, "respawned -> PEV back to Alice")
    -- the pause menu's suicide: dead body and new character within the same second
    advance(31); WORLD = HW; rtick()
    out2 = {}
    p2._p["PlayerDead?"] = true
    local p3 = new(HW, { "BP_PlayerCharacter_C", "Character" }, "BP_PlayerCharacter_C_HOST3", { Controller = HW.pc, ["PlayerDead?"] = false })
    HW.pc._p.Pawn = p3
    advance(1); WORLD = HW; rtick()
    local kinds = {}
    for _, e in ipairs(out2) do if e.kind == "PEV" then kinds[#kinds + 1] = e.args[1] end end
    check(table.concat(kinds, ",") == "died,back", "suicide respawn in one second: died then back (" .. table.concat(kinds, ",") .. ")")
    out2 = {}
    advance(1); WORLD = HW; rtick()
    check(#out2 == 0, "nothing more after that")
    check(respawn.status_line():find("playernotes:", 1, true) ~= nil, "status line includes playernotes")
end

print(string.format("mock_playernotes: %d checks, %d failed", total, fails))
if fails == 0 then print("ALL OK") else print("FAILED") end
