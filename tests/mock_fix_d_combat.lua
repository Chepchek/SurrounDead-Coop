-- Critic fix D / A5, A6, B2, C7 (2026-11-13): sdc_combat.
--   B2: the chamber-montage watch on PlayMontageCallbackProxy.
--       CreateProxyObjectForPlayMontage is one sdc_ue.hook_native subscriber
--       (pre, pcall'd), no own RegisterHook with an empty pre and a post.
--   A5: the forwarded rate is the PlayRate after the montage (the weapon's
--       ChamberBaseSpeed), not always 1.0.
--   A6: MONT on a client plays only a montage already in memory (no
--       synchronous LoadAsset on a message path).
--   C7: the melee hook retry stops once both hooks are in.
-- Log review 0.8.1, finding 3 (2026-11-13): MONT for the shooting client's
--   own character. The game plays the chamber montage only on the host
--   (Svr_WeaponShot is a server RPC), so MONT keeps going to the shooter too
--   (the host broadcasts to every remote player) and the client plays it on
--   its own character; it only never restarts an own chamber montage that
--   is already playing and that MONT did not start (within OWN_MONT_S, 5 s).
--   Its first three own plays are logged even after others' shots (skeptic).
-- usage: lua mock_fix_d_combat.lua <scripts dir>
local dir = arg[1]
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if cond then print("  ok   " .. what) else print("  FAIL " .. what); fails = fails + 1 end
end

local logs = {}
local log = setmetatable({ debug_enabled = false }, { __index = function(_, k)
  return function(a, ...)
    local fmt, args = a, { ... }
    if k == "err_throttled" then fmt = args[1]; table.remove(args, 1) end
    local ok, s = pcall(string.format, fmt, table.unpack(args))
    logs[#logs + 1] = k .. ": " .. tostring(ok and s or fmt)
  end
end })

local PROXY_FN = "/Script/AnimGraphRuntime.PlayMontageCallbackProxy:CreateProxyObjectForPlayMontage"
local MONTAGE = "/Game/Weapons/Anims/AN_BoltAction_Rerack_Anim_Montage.AN_BoltAction_Rerack_Anim_Montage"

local paths = {}
local ue = setmetatable({ ROLE_SIMULATED = 1, ROLE_AUTONOMOUS = 2, ROLE_AUTHORITY = 3 }, { __index = function()
  return function() return nil end
end })
function ue.try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end end
function ue.valid(o) return type(o) == "table" and o.__valid ~= false end
function ue.short(o) return ue.valid(o) and (o.__name or "obj") or "<none>" end
function ue.path(o) return o.__path or "" end
function ue.class_name(o) return ue.valid(o) and (o.__cls or "") or "" end
function ue.prop(o, n) if not ue.valid(o) then return nil end return o[n] end
function ue.find_object(p) return paths[p] end
local sync_loads = {}
function ue.load_asset(p) sync_loads[#sync_loads + 1] = p; return true, paths["later:" .. p] end
function ue.loaded_asset(p) return paths[p] end
function ue.role(a) return a and a.Role or -1 end
local players = {}
function ue.find_all() return players end
ue.find_all_recent = ue.find_all
local delays = {}
function ue.delay(label, ms, fn) delays[#delays + 1] = { label = label, fn = fn }; return #delays end
function ue.every(label, ms, fn) delays[#delays + 1] = { label = label, fn = fn, every = true }; return #delays end
local natives, raw_hooks = {}, {}
function ue.hook_native(path, key, fn)
  natives[path] = natives[path] or {}
  natives[path][key] = fn
  return true
end
local refuse = {}
RegisterHook = function(path, pre, post)
  if refuse[path] then error("no such function " .. path) end
  raw_hooks[#raw_hooks + 1] = { path = path, pre = pre, post = post }
  return 1, 2
end
FName = function(s) return s end

local bcast = {}
package.loaded["sdc_log"] = log
package.loaded["sdc_ue"] = ue
package.loaded["sdc_config"] = { get = function() return true end }
package.loaded["sdc_net"] = { broadcast = function(pcs, kind, ...) bcast[#bcast + 1] = { kind = kind, f = { ... }, pcs = pcs } end,
  send_to = function() end, send_to_host = function() end, on = function() end }
package.loaded["sdc_ctx"] = { addr = function(o) return o and o.__name end }
package.loaded["sdc_appearance"] = { player_id = function(p) return p and p.__id end }
package.loaded["sdc_items"] = { equipped_of = function() return {} end }

local combat = require("sdc_combat")
local S = { role = "host", remote_pcs = { { __name = "PC_1" } } }
combat.init(S)

local function P(v) return { get = function() return v end } end
local montage = { __name = "AN_BoltAction_Rerack_Anim_Montage", __cls = "AnimMontage", __path = MONTAGE }
local comp = { __name = "BP_WeaponsPickupComponent", ChamberFirearmMontage = montage }
local rifle = { __name = "BP_HuntingRiflePickup_C_1", BP_WeaponsPickupComponent = comp }
local pawn = { __name = "BP_PlayerCharacter_C_1", __cls = "BP_PlayerCharacter_C", __id = 257,
  Children = { ForEach = function(_, f) f(1, P(rifle)) end } }
local mesh = { __name = "CharacterMesh0", __cls = "SkeletalMeshComponent", GetOwner = function() return pawn end }

print("== host: chamber montage watch")
combat.host_tick()
local sub = natives[PROXY_FN] and natives[PROXY_FN]["combat.chamber"]
check(sub ~= nil, "subscribed through sdc_ue.hook_native (key combat.chamber)")
local own = 0
for _, h in ipairs(raw_hooks) do if h.path == PROXY_FN then own = own + 1 end end
check(own == 0, "no own RegisterHook on CreateProxyObjectForPlayMontage")
combat.host_tick()
check(natives[PROXY_FN] and natives[PROXY_FN]["combat.chamber"] == sub, "subscribed once")
sub = sub or function() end
-- pre: (Context, InSkeletalMeshComponent, MontageToPlay, PlayRate, StartingPosition, StartingSection, bShouldStopAllMontages)
local r = sub({ __name = "Default__PlayMontageCallbackProxy" }, P(mesh), P(montage), P(0.8), P(0.0), P("None"), P(true))
check(r == nil, "the subscriber returns nothing")
check(#bcast == 1 and bcast[1].kind == "MONT" and bcast[1].f[1] == 257 and bcast[1].f[2] == MONTAGE,
  "MONT broadcast with the player id and the montage path")
check(bcast[1] and bcast[1].f[3] == "0.80", "MONT carries the PlayRate after the montage (0.80), not 1.0: " .. tostring(bcast[1] and bcast[1].f[3]))
sub(nil, P(mesh), P(montage), P(0), P(0.25), P("None"), P(true))
check(#bcast == 2 and bcast[2].f[3] == "1.00", "a zero rate is sent as 1.00 (StartingPosition 0.25 not taken for it)")
local other = { __name = "Other_Montage", __cls = "AnimMontage", __path = "/Game/Other.Other" }
sub(nil, P(mesh), P(other), P(1.5), P(0), P("None"), P(true))
check(#bcast == 2, "another montage (not the weapon's chamber montage): not forwarded")
S.remote_pcs = {}
sub(nil, P(mesh), P(montage), P(0.8), P(0), P("None"), P(true))
check(#bcast == 2, "no remote players: nothing sent")

print("== client: MONT")
local handlers = {}
package.loaded["sdc_net"].on = function(k, h) handlers[k] = h end
combat.register_handlers()
S.role = "client"
local played = {}
local anim = { __name = "Anim", Montage_Play = function(_, m, rate) played[#played + 1] = { m = m, rate = rate } end }
local cmesh = { __name = "Mesh", GetAnimInstance = function() return anim end }
players = { { __name = "BP_PlayerCharacter_C_2", __id = 257, Role = 1, Mesh = cmesh } }
paths["later:" .. MONTAGE] = montage
handlers.MONT({ "257", MONTAGE, "0.80" })
check(#played == 0 and #sync_loads == 0, "montage not in memory: nothing played, no synchronous load")
paths[MONTAGE] = montage
handlers.MONT({ "257", MONTAGE, "0.80" })
check(#played == 1 and played[1].m == montage and played[1].rate == 0.8, "montage in memory: played at the host's rate")
paths["/Game/Snd.Snd"] = { __name = "Snd", __cls = "SoundWave" }
handlers.MONT({ "257", "/Game/Snd.Snd", "1" })
check(#played == 1, "a path of another class: ignored")

print("== finding 3: MONT for the shooter's own character")
-- host: a client's shot -> the host's copy of that client plays the chamber
-- montage -> MONT to every remote player, the shooter's own controller too
S.role = "host"
local owner_pc, other_pc = { __name = "PC_owner" }, { __name = "PC_other" }
S.remote_pcs = { owner_pc, other_pc }
local cpawn = { __name = "BP_PlayerCharacter_C_9", __cls = "BP_PlayerCharacter_C", __id = 258, Controller = owner_pc,
  Children = pawn.Children }
local cpmesh = { __name = "CharacterMesh0", __cls = "SkeletalMeshComponent", GetOwner = function() return cpawn end }
local nb = #bcast
sub(nil, P(cpmesh), P(montage), P(0.75), P(0), P("None"), P(true))
local last = bcast[#bcast]
check(#bcast == nb + 1 and last.f[1] == 258 and last.pcs == S.remote_pcs,
  "MONT of a client's character goes to every remote player, its owner included (the only chamber anim it gets)")

S.role = "client"
local T = 100.0
local real_clock = os.clock
os.clock = function() return T end
local own_playing, other_playing = false, false
local own_anim = { __name = "OwnAnim",
  Montage_Play = function(_, m, rate) played[#played + 1] = { m = m, rate = rate, own = true } end,
  Montage_IsPlaying = function() return own_playing end }
local other_anim = { __name = "OtherAnim",
  Montage_Play = function(_, m, rate) played[#played + 1] = { m = m, rate = rate, own = false } end,
  Montage_IsPlaying = function() return other_playing end }
local own = { __name = "BP_PlayerCharacter_C_own", __id = 258, Role = 2,
  Mesh = { __name = "OwnMesh", GetAnimInstance = function() return own_anim end },
  IsLocallyControlled = function() return true end }
local other2 = { __name = "BP_PlayerCharacter_C_oth", __id = 257, Role = 1,
  Mesh = { __name = "OthMesh", GetAnimInstance = function() return other_anim end },
  IsLocallyControlled = function() return false end }
players = { own, other2 }
local n0 = #played
local logs0 = #logs
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 1 and played[#played].own and played[#played].rate == 0.75,
  "client: own character, montage not playing: MONT plays it (the game never plays it on a client)")
check(combat.stats.montages_own == 1 and combat.stats.montages_own_busy == 0, "counted as an own chamber montage")
local said = false
for i = logs0, #logs do if logs[i]:find("own character: the game plays it only on the host", 1, true) then said = true end end
check(said, "log says it is the own character")

-- a pump MONT while the previous MONT's montage still plays: restarted, as
-- the host's copy restarts it
T = T + 1.2
own_playing = true
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 2, "own, still playing from MONT 1.2 s ago: restarted like on the host")

-- playing, but not started by MONT (no own MONT for 5 s): not restarted
T = T + 6
logs0 = #logs
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 2, "own, already playing and not started by MONT: not restarted")
check(combat.stats.montages_own_busy == 1, "counted as 'own already playing'")
said = false
for i = logs0, #logs do if logs[i]:find("^warn: combat: own .- already playing here") then said = true end end
check(said, "warned once in the log")
check(combat.status_line():find("own=2, own already playing=1", 1, true) ~= nil,
  "status line: " .. combat.status_line():sub(1, 80))

-- another player's character: unchanged (always played, even when playing)
other_playing = true
handlers.MONT({ "257", MONTAGE, "1.00" })
check(#played == n0 + 3 and not played[#played].own, "another player's character: played as before")
check(combat.stats.montages_own_busy == 1, "another player's character is never 'own'")

-- own, montage not playing any more: played again
own_playing = false
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 4 and played[#played].own, "own, not playing: played")

-- IsLocallyControlled not answering: treated as before (played)
own.IsLocallyControlled = function() error("gone") end
own_playing = true
T = T + 10
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 5, "IsLocallyControlled fails: played as before the fix")
own.IsLocallyControlled = function() return true end

-- world change: the own MONT times are forgotten
T = T + 0.5
handlers.MONT({ "258", MONTAGE, "0.75" })   -- own, playing, not from MONT within 5 s: kept
check(#played == n0 + 5, "own, playing, last own MONT 10.5 s ago: kept")
own_playing = false
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 6, "(own MONT played)")
combat.reset("world")
own_playing = true
T = T + 1
handlers.MONT({ "258", MONTAGE, "0.75" })
check(#played == n0 + 6, "after reset() a MONT 1 s ago no longer counts as MONT's own")

-- the in-game check reads the log: the "own character" line must appear
-- even when another player shot first (0.8.1 skeptic: only the first three
-- plays of anyone were logged, so three of the host's shots hid it)
print("== finding 3: the own character's plays are logged even after others' shots")
package.loaded["sdc_combat"] = nil
local c2 = require("sdc_combat")
package.loaded["sdc_combat"] = combat
local S2 = { role = "client", remote_pcs = {} }
c2.init(S2)
c2.register_handlers()   -- handlers.MONT is c2's from here on
own_playing, other_playing = false, false
players = { own, other2 }
local function lines_since(i0, pat)
  local n = 0
  for i = i0 + 1, #logs do if logs[i]:find(pat, 1, true) then n = n + 1 end end
  return n
end
local l0 = #logs
for _ = 1, 4 do T = T + 2; handlers.MONT({ "257", MONTAGE, "1.00" }) end
check(lines_since(l0, "combat: played AN_BoltAction_Rerack_Anim_Montage on BP_PlayerCharacter_C_oth") == 3,
  "another player's shots: the first three plays logged, the fourth not")
check(lines_since(l0, "own character") == 0, "(no own play yet)")
l0 = #logs
for _ = 1, 4 do T = T + 2; handlers.MONT({ "258", MONTAGE, "0.75" }) end
check(c2.stats.montages_played == 8 and c2.stats.montages_own == 4, "(4 foreign + 4 own plays counted)")
check(lines_since(l0, "on BP_PlayerCharacter_C_own (own character: the game plays it only on the host)") == 3,
  "own character after 4 foreign plays: its first three plays still logged, the fourth not")
check(lines_since(l0, "on BP_PlayerCharacter_C_oth") == 0, "no foreign line among them")
os.clock = real_clock
players = {}

print("== melee hook retry")
local melee_delays = 0
for _, d in ipairs(delays) do if d.label == "combat-melee-hooks" then melee_delays = melee_delays + 1 end end
check(melee_delays == 0, "(install not run yet)")
local MELEE = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C:"
refuse[MELEE .. "HitBody"], refuse[MELEE .. "HitHead"] = true, true
delays = {}
combat.install()
local function run_melee()
  local list = delays
  delays = {}
  local n = 0
  for _, d in ipairs(list) do
    if d.label == "combat-melee-hooks" then d.fn(); n = n + 1 else delays[#delays + 1] = d end
  end
  return n
end
local every = 0
for _, d in ipairs(delays) do if d.label == "combat-melee-hooks" and d.every then every = every + 1 end end
check(every == 0, "the melee retry is not an endless loop (ue.every)")
check(run_melee() == 1, "first try after 2 s")
check(run_melee() == 1, "class not loaded: tried again")
refuse[MELEE .. "HitBody"], refuse[MELEE .. "HitHead"] = nil, nil
check(run_melee() == 1, "class loaded: hooked")
check(run_melee() == 0, "both hooks in: the retry chain ended")

local bad = 0
for _, l in ipairs(logs) do
  if l:find("^err") and not l:find("is a SoundWave, not an AnimMontage", 1, true) then print("    " .. l); bad = bad + 1 end
end
check(bad == 0, "no errors logged (but the expected wrong-class line)")

if fails == 0 then print(checks .. " checks, ALL OK") else print(checks .. " checks, " .. fails .. " FAILED") end
os.exit(fails == 0 and 0 or 1)
