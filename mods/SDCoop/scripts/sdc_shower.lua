-- SDCoop: the decontamination shower (Buildable_DecontaminationShower) is the
-- same for every player: one cooldown per shower, the host's, that a client's
-- copy shows (lights, its own flag, the game's notes on a press) and keeps;
-- its power, lights and water seen by everyone; the decontamination for every
-- player standing in it, done once, on the host.
--
-- How the game runs it (work\re\pseudo_shower\Buildable_DecontaminationShower.txt,
-- pseudo\Buildable_MASTER.txt, pseudo\RadiationComponent.txt):
--   * F ("Interact", Option1): OnExecuteInteract on the presser's machine ->
--     its SERVER_ForwardInteract -> on the server OnServerExecuteInteract
--     @2314: CurrentActor = the presser, MC_OnInteractBuildable(CurrentActor) -
--     a NetMulticast, NOT reliable -> OnInteractBuildable @1350 where it
--     arrives: the presser's interact montage; no PoweredOn? -> "No power"
--     (@1679); CooldownRunning? -> "Decontamination shower cooldown in
--     effect..." (@1512); else @680: CooldownRunning? = true (replicated, OnRep:
--     lights orange), DecontaminatePlayer, FX_Water + FX_Water2 on, the
--     Event_Cooldown timer (Cooldown = 300 s, one per shower; Event_Cooldown:
--     CooldownRunning? = false, lights green), Delay 3 s -> water off.
--     Move = ReplacingObject, Pickup = Pickup. No sound of its own (no audio
--     component; the water is the Cascade particle FX_Particle_Water).
--   * DecontaminatePlayer: BoxOverlapActors(Trace = actor + 120 cm up, half
--     size 50 x 85 x 100 cm, world-aligned, Pawn Characters); player 0 of THIS
--     machine inside -> its RadiationComponent.IncreaseRadiation(100): the
--     radiation meter back to its maximum (100), radiation sickness off, the
--     dosimeter stopped. Nobody else; infection is not touched.
--   * Power: RequiresPower? = true; a generator's GetObjects (every 2-4 s)
--     calls Power On / Power Off; PoweredOn? replicates (OnRep -> the
--     PoweredOn / PoweredOff delegates -> the shower's On / Off: lights green
--     or red). The shower binds On / Off only 1 s after its BeginPlay.
-- In co-op (host = listen server), logs of 2026-11-13 (host + client):
--   * Everything ran on the host only. The client's copy raised none of the
--     shower's notes (each note the host relayed was shown on the client after
--     sdc_notes' 0.35 s wait, none was "raised here meanwhile"): its
--     OnInteractBuildable does not run there (the multicast did not arrive, or
--     its notes went nowhere). The client's only answer to a press was the
--     host's NOTE; no water there, ever.
--   * The client's copy knows the cooldown only as far as CooldownRunning?
--     replicates; a copy that (re)appears (join, back within net range) gets
--     PoweredOn? before its BeginPlay: OnRep_PoweredOn? broadcasts before the
--     shower bound On / Off, so its lights stay red although it has power.
--   * The decontamination is the host's: DecontaminatePlayer asks player 0,
--     which sdc_ctx turns into the presser (sdc_world's build scope:
--     CurrentActor). A player standing in the shower while someone else
--     pressed got nothing.
-- Here (config world_build_shower, under world_sync):
--   host   DecontaminatePlayer (post): the shower started (by anyone). Every
--          other living player inside its box (the game's own call did player
--          0 = the presser) gets the same IncreaseRadiation(100) on the host.
--          SHWR|go to every client (with "it was you" for the presser).
--          Event_Cooldown / On / Off (post): SHWR|c. Every SNAP_S and on SHWRQ
--          (a client joined): SHWR|s, every shower with its remaining cooldown
--          (the engine's own timer), stamped (chunks): a client drops what a
--          whole snapshot left out. The game's notes of a client's press keep
--          coming from the host (sdc_notes' relay; a note this screen showed
--          already is not shown twice).
--   client SHWR: keeps the host's word per shower (place, power, cooldown end
--          by its own clock, light colour). go: water on for 3 s on the copy
--          here, CooldownRunning? on.
--          OnExecuteInteract (post, Buildable_MASTER: it runs on the presser's
--          machine) of its own "Interact" on a shower the host's word says is
--          cooling down / unpowered: the game's note at once (the host's relay
--          of it comes as a duplicate). Ready: nothing - the host's go brings
--          the water.
--          OnInteractBuildable (post) of the copy, should it ever run here: a
--          debug line (copy's branch, whose press); another player's press:
--          the note it just added comes off this screen; its own press: a
--          note the copy just added that the host's word contradicts is
--          replaced, a "...cooldown in effect..." for a press the host started
--          (its properties came before the multicast) comes off, held back
--          and shown after all if no start comes within PRESS_WAIT. Only notes
--          the game really added in that call come off (sdc_notes.shown_fresh).
--          A start the copy ran itself and the host did not confirm within
--          PRESS_WAIT is undone (water off, cooldown as on the host); after any
--          start of the copy here this player's radiation values are asked
--          from the host (SHWRR / SHWRV: the local DecontaminatePlayer wrote
--          them, the stopped dosimeter and cleared sickness included).
--          A pass every PASS_S puts the host's power (the game's Power On /
--          Off, with world_build_power), cooldown flag and light colour on
--          copies that differ (GRACE after a change: the replication may still
--          be on its way).
-- Messages:
--   SHWR|go|entry|you      host -> client: a start now (you = 1: that client pressed)
--   SHWR|c|entry           host -> client: one shower changed
--   SHWR|s|id|n|entries    host -> client: all showers (join, every SNAP_S), chunk of n
--   SHWRQ                  client -> host (once in a world)
--   SHWRR / SHWRV|cur|sick client -> host / host -> client: own radiation values
--   entry = "x,y,z power(1/0) cooling(1/0) remaining_s(-1 unknown) light(g/o/r/-)"
-- Hooks: post only, wrapped in pcall, return nothing; parameters are read
-- inside the callback; no engine object is kept between calls (places,
-- addresses and numbers only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local notes = require("sdc_notes")

local M = {
    stats = { starts = 0, sent = 0, snaps = 0, others = 0, received = 0, water = 0, power_fixed = 0,
              cool_fixed = 0, lights_fixed = 0, dropped = 0, notes_off = 0, notes_shown = 0, notes_swapped = 0,
              copy_runs = 0, undone = 0, rad_synced = 0 },
}

local CLS = "Buildable_DecontaminationShower_C"
local PATH = "/Game/Blueprints/BuildingSystem/Actors/Other/Buildable_DecontaminationShower.Buildable_DecontaminationShower_C"
local BASE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local MAT = "/Game/Meshes/Materials/M_EmissiveColour_%s.M_EmissiveColour_%s"
local COLOURS = { g = "Green", o = "Orange", r = "Red" }
-- the game's own notes (English in the game)
local TEXT = { cool = "Decontamination shower cooldown in effect...", nopower = "No power" }
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local NOTE_DELAY = 2
local OPTION_USE = "Jig.InteractOptions.Option1"

-- DecontaminatePlayer: box half size (cm, world axes), Trace height, amount
local BOX = { X = 50, Y = 85, Z = 100 }
local TRACE_UP = 120
local AMOUNT = 100.0
local CAPSULE_R, CAPSULE_HH = 42, 96   -- when a character's capsule cannot be read
local RUN_S = 3              -- the water runs this long (the game's Delay)
local COOLDOWN_DEFAULT = 300

local PLACE_MATCH = 100      -- cm
local GRACE = 1.5            -- s after the host's change before a copy here is corrected
local EDGE = 0.5             -- s: a cooldown ending this close to now is left to the replication
local PASS_S = 2             -- client pass
local SNAP_S = 30            -- host: every shower to every client
local KEEP_S = 75            -- client: a host state no message refreshed this long is forgotten
local SNAP_AFTER_S = 3
local PRESS_WAIT = 2.5       -- client: an own press waits this long for the host's start
local NOTE_NOW = 0.25        -- s: a note shown within this is the one the call just raised
local RAD_GAP = 2            -- client: radiation values asked at most this often
local CHUNK = 900
local HOOK_RETRY_S = 2

local clock = os.clock
local S
local st = {
    role = nil, hooks = {}, hook_logged = {}, hook_at = -100,
    known = {},          -- client: { loc, locs, p, cool_until, l, seen, changed, run_until, water, snap }
    snap = nil,          -- client: { id, got } the snapshot being received
    snap_id = 0,         -- host: the last snapshot's stamp
    pass_at = -100, snap_at = 0, asked = nil, since = nil,
    local_start = nil,   -- client: { a, t }: the copy's own start branch ran here (DecontaminatePlayer)
    press = nil,         -- client: own press { loc, t, shown, shown_fresh, copy, copy_fresh, hold }
    go_mine = nil,       -- client: { loc, t }: the host started this player's press
    runs = {},           -- client: starts of copies here, not confirmed by the host yet { loc, t }
    rad_at = -100,       -- client: radiation values last asked
}

local function on() return cfg.get("world_sync") ~= false and cfg.get("world_build_shower") ~= false end
local function power_on() return on() and cfg.get("world_build_power") ~= false end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end
local function addr(o) return ue.valid(o) and ctx.addr(o) or nil end
local function loc_str(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function parse_loc(s)
    local x, y, z = tostring(s or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end
local function d2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end
local function near(a, b) return d2(a, b) <= PLACE_MATCH * PLACE_MATCH end
local function remote_pc(pc) return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) end
local function remote_pcs() return (S and S.remote_pcs) or {} end

-- ---------------------------------------------------------------------------
-- A shower's state, both machines
-- ---------------------------------------------------------------------------

local function light_of(c)
    local l = ue.prop(c, "Light")
    if not ue.valid(l) then return "-" end
    local m = ue.try(function() return l:GetMaterial(0) end)
    if not ue.valid(m) then return "-" end
    local n = ue.short(m)
    for k, v in pairs(COLOURS) do
        if n:find(v, 1, true) then return k end
    end
    return "-"
end

local function set_light(c, k)
    local name = COLOURS[k]
    local mat = name and ue.find_object(string.format(MAT, name, name))
    if not mat then return false end
    local ok = false
    for _, comp_name in ipairs({ "Light", "Light2" }) do
        local comp = ue.prop(c, comp_name)
        if ue.valid(comp) and pcall(function() comp:SetMaterial(0, mat) end) then ok = true end
    end
    return ok
end

-- FX_Water + FX_Water2 on / off; how many changed
local function water(c, want)
    local n = 0
    for _, name in ipairs({ "FX_Water", "FX_Water2" }) do
        local fx = ue.prop(c, name)
        if ue.valid(fx) then
            local active = ue.try(function() return fx:IsActive() end) == true
            if want and not active then
                if pcall(function() fx:Activate(false) end) then n = n + 1 end
            elseif not want and active then
                if pcall(function() fx:Deactivate() end) then n = n + 1 end
            end
        end
    end
    return n
end

local function water_on(c)
    local fx = ue.prop(c, "FX_Water")
    return ue.valid(fx) and ue.try(function() return fx:IsActive() end) == true
end

local function set_cooling(c, cool)
    ue.set_prop(c, "CooldownRunning?", cool)
    pcall(function() c["OnRep_CooldownRunning?"](c) end)
    if not cool then
        -- the copy's own timer of a start it ran here (it would end its cooldown on its own)
        local ksl = ue.ksl()
        if ksl then pcall(function() ksl:K2_ClearTimer(c, "Event_Cooldown") end) end
    end
end

-- the game's own Power On / Power Off on this machine's copy
local function set_power(c, want)
    local fn = want and "Power On" or "Power Off"
    local ok = pcall(function() c[fn](c, nil) end)
    if not ok or (ue.prop(c, "PoweredOn?") == true) ~= want then
        ue.set_prop(c, "PoweredOn?", want)
        pcall(function() c["OnRep_PoweredOn?"](c) end)
    end
    return (ue.prop(c, "PoweredOn?") == true) == want
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

-- the engine's own cooldown timer: seconds left, 0 = not cooling, -1 = cooling, time unknown
local function remaining(c)
    if ue.prop(c, "CooldownRunning?") ~= true then return 0 end
    local ksl = ue.ksl()
    local r = ksl and ue.try(function() return ksl:K2_GetTimerRemainingTime(c, "Event_Cooldown") end)
    if type(r) == "number" and r > 0 then return r end
    return -1
end

local function entry_of(c, r_now)
    local l = ue.location(c)
    if not l then return nil end
    local cool = ue.prop(c, "CooldownRunning?") == true
    local r = r_now or (cool and remaining(c) or 0)
    return string.format("%s %s %s %s %s", loc_str(l), ue.prop(c, "PoweredOn?") == true and "1" or "0",
        cool and "1" or "0", r < 0 and "-1" or string.format("%.1f", r), light_of(c))
end

local function all_showers()
    if not ue.find_object(PATH) then return {} end
    local out = {}
    for _, c in ipairs(ue.find_all(CLS)) do
        if ue.valid(c) and ue.class_name(c) == CLS then out[#out + 1] = c end
    end
    return out
end

-- Every shower, stamped and in chunks (an empty world: one empty chunk, so
-- a client drops what it still keeps).
local function snapshot(pcs)
    local chunks, buf, len = {}, {}, 0
    for _, c in ipairs(all_showers()) do
        local e = entry_of(c)
        if e then
            if len + #e + 1 > CHUNK and #buf > 0 then chunks[#chunks + 1] = buf; buf, len = {}, 0 end
            buf[#buf + 1] = e
            len = len + #e + 1
        end
    end
    chunks[#chunks + 1] = buf
    st.snap_id = st.snap_id + 1
    local n = 0
    for _, b in ipairs(chunks) do
        net.broadcast(pcs, "SHWR", "s", st.snap_id, #chunks, table.concat(b, ";"))
        n = n + #b
    end
    M.stats.sent = M.stats.sent + #chunks
    M.stats.snaps = M.stats.snaps + 1
    return n
end

local function is_player_char(o)
    return ue.valid(o) and ue.class_name(o):find("PlayerCharacter", 1, true) ~= nil
end

-- The character the game's own DecontaminatePlayer asked for: player 0 of
-- the shower through sdc_ctx - the build scope (CurrentActor) when it names
-- a player, else the shower's own player (owner chain), else the host.
local function game_target(c)
    local host = ue.local_pawn()
    if not ctx.active then return host end
    if cfg.get("world_build") ~= false then
        local cur = ue.prop(c, "CurrentActor")
        if is_player_char(cur) then
            local pc = ue.prop(cur, "Controller")
            if remote_pc(pc) then return cur end
            if ue.valid(pc) then return host end
        end
    end
    local e = ctx.player_for(c)
    if e and remote_pc(e.pc) then return ue.pawn_of(e.pc) end
    return host
end

local function box_center(c)
    local tr = ue.prop(c, "Trace")
    local v = ue.valid(tr) and ue.vec(ue.try(function() return tr:K2_GetComponentLocation() end)) or nil
    if v then return v end
    local l = ue.location(c)
    return l and { X = l.X, Y = l.Y, Z = l.Z + TRACE_UP } or nil
end

local function capsule(p)
    local cap = ue.prop(p, "CapsuleComponent")
    if not ue.valid(cap) then return CAPSULE_R, CAPSULE_HH end
    local r = ue.try(function() return cap:GetScaledCapsuleRadius() end)
    local h = ue.try(function() return cap:GetScaledCapsuleHalfHeight() end)
    return type(r) == "number" and r or CAPSULE_R, type(h) == "number" and h or CAPSULE_HH
end

-- the capsule's box against the shower's box (the game's overlap, world axes)
local function inside(center, loc, pawn)
    local r, hh = capsule(pawn)
    return math.abs(loc.X - center.X) <= BOX.X + r and math.abs(loc.Y - center.Y) <= BOX.Y + r
        and math.abs(loc.Z - center.Z) <= BOX.Z + hh
end

-- Every other living player in the shower: the same IncreaseRadiation(100)
-- the game gave its player 0. Returns the names of those.
local function decontaminate_others(c)
    local center = box_center(c)
    if not center then return {} end
    local target = game_target(c)
    local ta = addr(target)
    local done = {}
    for _, e in ipairs(ctx.live_players()) do
        local a = addr(e.pawn)
        if a and a ~= ta and inside(center, e.loc, e.pawn) then
            local comp = ue.prop(e.pawn, "RadiationComponent")
            if ue.valid(comp) and pcall(function() comp:IncreaseRadiation(AMOUNT) end) then
                done[#done + 1] = e.remote and ue.short(e.pc) or "the host"
                M.stats.others = M.stats.others + 1
            end
        end
    end
    return done
end

-- <shower>.DecontaminatePlayer, post, host: it started now.
local function host_start(c)
    local pcs = remote_pcs()
    if #pcs == 0 then return end
    M.stats.starts = M.stats.starts + 1
    local done = decontaminate_others(c)
    local presser = ue.prop(c, "CurrentActor")
    local ppc = is_player_char(presser) and ue.prop(presser, "Controller") or nil
    local pa = remote_pc(ppc) and addr(ppc) or nil
    -- the Cooldown timer is set right after this call (@504): its full length
    local cd = tonumber(ue.prop(c, "Cooldown")) or COOLDOWN_DEFAULT
    local e = entry_of(c, cd)
    if e then
        for _, pc in ipairs(pcs) do
            net.send_to(pc, "SHWR", "go", e, (pa and addr(pc) == pa) and "1" or "0")
        end
        M.stats.sent = M.stats.sent + 1
    end
    log.info("shower: host: %s started by %s (cooldown %.0f s): water and cooldown to %d client(s)%s",
        ue.short(c), pa and ue.short(ppc) or "the host", cd, #pcs,
        #done > 0 and (", also decontaminated in it: " .. table.concat(done, ", ")) or "")
end

-- Event_Cooldown / On / Off, post, host: its state changed.
local function host_change(c, why)
    local pcs = remote_pcs()
    if #pcs == 0 then return end
    local e = entry_of(c)
    if not e then return end
    net.broadcast(pcs, "SHWR", "c", e)
    M.stats.sent = M.stats.sent + 1
    log.info("shower: host: %s %s: SHWR to %d client(s) (%s)", ue.short(c), why, #pcs, e)
end

-- SHWRQ (client -> host)
local function snap_msg(_, pc)
    if not S or S.role ~= "host" or not on() then return end
    local n = snapshot({ pc })
    log.info("shower: host: a client asked for the showers: %d sent", n)
end

-- SHWRR (client -> host): that player's radiation values, as the host has them
local function rad_msg(_, pc)
    if not S or S.role ~= "host" or not on() then return end
    local pawn = ue.pawn_of(pc)
    local comp = pawn and ue.prop(pawn, "RadiationComponent")
    local cur = ue.valid(comp) and tonumber(ue.prop(comp, "CurrentRadiation")) or nil
    if not cur then return end
    local med = ue.prop(pawn, "MedicalComponent")
    local sick = ue.valid(med) and ue.prop(med, "RadiationSickness?") == true
    net.send_to(pc, "SHWRV", string.format("%.3f", cur), sick and "1" or "0")
    log.debug("shower: host: radiation values of %s sent (%.1f, sickness %s)", ue.short(pc), cur, tostring(sick))
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function find_rec(loc)
    local best, bestd = nil, PLACE_MATCH * PLACE_MATCH
    for _, r in ipairs(st.known) do
        local d = d2(r.loc, loc)
        if d <= bestd then best, bestd = r, d end
    end
    return best
end

local function find_copy(loc, list)
    local best, bestd = nil, PLACE_MATCH * PLACE_MATCH
    for _, c in ipairs(list or ue.find_all_recent(CLS, 0.25)) do
        if ue.valid(c) then
            local dd = d2(ue.location(c), loc)
            if dd <= bestd then best, bestd = c, dd end
        end
    end
    return best
end

local function parse_entry(item)
    local locs, p, cool, r, l = tostring(item or ""):match("^(%S+) ([01]) ([01]) (%S+) ([gor%-])$")
    local loc = locs and parse_loc(locs)
    if not loc then return nil end
    return { loc = loc, locs = locs, p = p == "1", cool = cool == "1", r = tonumber(r) or 0, l = l }
end

local function remember(e, now, why)
    local cool_until = 0
    if e.cool then cool_until = e.r >= 0 and (now + e.r) or math.huge end
    local rec = find_rec(e.loc)
    if not rec then
        rec = { run_until = 0, water = false, changed = why == "s" and -100 or now }
        st.known[#st.known + 1] = rec
    elseif why ~= "s" or rec.p ~= e.p or (rec.cool_until > now) ~= e.cool or rec.l ~= e.l then
        rec.changed = now
    end
    rec.loc, rec.locs, rec.p, rec.cool_until, rec.l, rec.seen = e.loc, e.locs, e.p, cool_until, e.l, now
    return rec
end

-- what the host's word says a press gets now: "nopower" | "cool" | "start" | nil (not sure)
local function host_answer(rec, now)
    if not rec or now - rec.changed < GRACE then return nil end
    if not rec.p then return "nopower" end
    if rec.cool_until > now + EDGE then return "cool" end
    if rec.cool_until < now - EDGE then return "start" end
    return nil
end

local function show(k, why)
    local ok = notes.show_here(TEXT[k], "", WHITE, NOTE_DELAY, why)
    if ok then M.stats.notes_shown = M.stats.notes_shown + 1 end
    return ok
end

-- the game really added this note in the call that just ran (not the same text still on screen)
local function fresh(k) return notes.shown_fresh(TEXT[k], NOTE_NOW) end

local function take_off(k, why)
    if notes.take_off(TEXT[k]) then
        M.stats.notes_off = M.stats.notes_off + 1
        log.info("shower: '%s' taken off this screen (%s)", TEXT[k], why)
        return true
    end
    return false
end

-- this player's radiation values from the host (a local start wrote them here)
local function ask_radiation(now)
    if now - st.rad_at < RAD_GAP then return end
    if net.send_to_host("SHWRR") then st.rad_at = now end
end

-- SHWRV|cur|sick (host -> client)
local function rad_values(f)
    if not S or S.role ~= "client" or not on() then return end
    local cur = tonumber(f[1])
    local pawn = ue.local_pawn()
    if not cur or not pawn then return end
    local comp = ue.prop(pawn, "RadiationComponent")
    if ue.valid(comp) and tonumber(ue.prop(comp, "CurrentRadiation")) ~= cur then
        ue.set_prop(comp, "CurrentRadiation", cur)
    end
    local sick = f[2] == "1"
    local med = ue.prop(pawn, "MedicalComponent")
    if ue.valid(med) and (ue.prop(med, "RadiationSickness?") == true) ~= sick then
        ue.set_prop(med, "RadiationSickness?", sick)
        pcall(function() med["OnRep_RadiationSickness?"](med) end)
    end
    local ui = ue.prop(pawn, "InGameUI")
    if ue.valid(ui) then pcall(function() ui:UpdateRadiation(cur) end) end
    M.stats.rad_synced = M.stats.rad_synced + 1
    log.info("shower: own radiation as on the host again (%.1f, sickness %s)", cur, tostring(sick))
end

-- SHWR|go: the shower started on the host now.
local function on_go(e, you, now)
    local rec = remember(e, now, "go")
    rec.run_until = now + RUN_S
    local keep = {}
    for _, r in ipairs(st.runs) do
        if not near(r.loc, rec.loc) then keep[#keep + 1] = r end   -- a start of the copy here: confirmed
    end
    st.runs = keep
    local c = find_copy(rec.loc)
    if c then
        if ue.prop(c, "CooldownRunning?") ~= true then set_cooling(c, true) end
        if water(c, true) > 0 then
            rec.water = true
            M.stats.water = M.stats.water + 1
        elseif water_on(c) then
            rec.water = true   -- the copy started it itself (its multicast came first)
        end
    end
    log.info("shower: the host's shower at %s started%s: water here %s", rec.locs, you and " by this player's press" or "",
        c and "on" or "(no copy here)")
    if not you then return end
    -- a copy's multicast of this start may still come: its note then is the race
    st.go_mine = { loc = rec.loc, t = now }
    local p = st.press
    if p and now - p.t <= PRESS_WAIT and near(p.loc, rec.loc) then
        st.press = nil
        -- a refusal shown at the press (the host's word was stale) / the copy's
        -- race note: off, if the game really added it then
        if p.shown and p.shown_fresh then take_off(p.shown, "the host started the shower for this press") end
        if p.copy and p.copy ~= "start" and p.copy ~= p.shown and p.copy_fresh and not p.hold then
            take_off(p.copy, "the host started the shower for this press")
        end
    end
end

-- SHWR|s|id|n|entries
local function snapshot_chunk(f, now)
    local id, n = tonumber(f[2]), tonumber(f[3])
    if not id or not n or n < 1 then return end
    if not st.snap or st.snap.id ~= id then st.snap = { id = id, got = 0 } end
    local k = 0
    for item in tostring(f[4] or ""):gmatch("[^;]+") do
        local e = parse_entry(item)
        if e then
            k = k + 1
            remember(e, now, "s").snap = id
        end
    end
    M.stats.received = M.stats.received + k
    st.snap.got = st.snap.got + 1
    if st.snap.got < n then return end
    -- the whole snapshot is here: what it left out is gone on the host
    local keep, dropped = {}, 0
    for _, r in ipairs(st.known) do
        if r.snap == id or r.water then keep[#keep + 1] = r else dropped = dropped + 1 end
    end
    st.known = keep
    st.snap = nil
    M.stats.dropped = M.stats.dropped + dropped
    log.debug("shower: snapshot %d from the host: %d shower(s), %d dropped", id, #keep, dropped)
end

-- SHWR|c|entries, SHWR|go|entry|you, SHWR|s|id|n|entries (host -> client)
local function shower_msg(f)
    if not S or S.role ~= "client" or not on() then return end
    local kind = f[1]
    local now = clock()
    if kind == "go" then
        local e = parse_entry(f[2])
        if e then
            M.stats.received = M.stats.received + 1
            on_go(e, f[3] == "1", now)
        end
        return
    end
    if kind == "s" then return snapshot_chunk(f, now) end
    if kind ~= "c" then return end
    for item in tostring(f[2] or ""):gmatch("[^;]+") do
        local e = parse_entry(item)
        if e then
            M.stats.received = M.stats.received + 1
            local rec = remember(e, now, "c")
            log.debug("shower: the host's shower at %s: power %s, cooling %s, light %s", rec.locs, tostring(rec.p),
                tostring(e.cool), rec.l)
        end
    end
end

local function is_own(actor)
    local me = ue.local_pawn()
    return me ~= nil and ue.valid(actor) and addr(actor) == addr(me)
end

-- Buildable_MASTER.OnExecuteInteract(InteractingActor, Option), post, client:
-- this player pressed a key on a buildable (its server part runs on the host).
local function client_exec(obj, actor, option)
    if ue.class_name(obj) ~= CLS or not is_own(actor) then return end
    local tag = ue.str(ue.try(function() return option.TagName end))
    if tag ~= OPTION_USE then return end
    local loc = ue.location(obj)
    if not loc then return end
    local now = clock()
    local want = host_answer(find_rec(loc), now)
    local p = { loc = loc, t = now }
    st.press = p
    if want == "cool" or want == "nopower" then
        -- the host will refuse it: the game's note here at once (its relay comes as a duplicate)
        if show(want, "this player's press, the host's state") then
            p.shown, p.shown_fresh = want, fresh(want)
        end
    end
    log.debug("shower: own press on %s: the host's word %s", ue.short(obj), tostring(want or "unknown"))
end

-- the branch the copy's own OnInteractBuildable took just now
local function branch_of(c, a, now)
    if ue.prop(c, "PoweredOn?") ~= true then return "nopower" end
    local ls = st.local_start
    if ls and ls.a == a and now - ls.t <= NOTE_NOW then return "start" end
    return "cool"
end

-- <shower>.OnInteractBuildable(Actor), post, client: someone's press reached this copy.
local function client_press(c, actor)
    local now = clock()
    local branch = branch_of(c, addr(c), now)
    st.local_start = nil
    local mine = is_own(actor)
    M.stats.copy_runs = M.stats.copy_runs + 1
    log.debug("shower: copy %s ran OnInteractBuildable here for %s: %s", ue.short(c),
        mine and "this player's press" or "another player's press", branch)
    local loc = ue.location(c)
    if not loc then return end
    if branch == "start" then
        -- the copy started itself: kept if the host's go comes, else undone;
        -- its DecontaminatePlayer may have written this player's radiation
        st.runs[#st.runs + 1] = { loc = loc, t = now }
        ask_radiation(now)
    end
    if not mine then
        -- another player's press: the game's answer is that player's
        if branch ~= "start" and fresh(branch) then take_off(branch, "another player's press") end
        return
    end
    local g, p = st.go_mine, st.press
    if g and now - g.t <= PRESS_WAIT and near(g.loc, loc) and not (p and p.t > g.t and near(p.loc, loc)) then
        -- the host's start of this press came first: the copy's refusal is the race
        st.go_mine = nil
        if branch ~= "start" and fresh(branch) then take_off(branch, "the host started the shower for this press") end
        return
    end
    if not (p and now - p.t <= PRESS_WAIT and near(p.loc, loc)) then
        p = { loc = loc, t = now }
        st.press = p
    end
    p.copy = branch
    if branch == "start" then return end
    p.copy_fresh = fresh(branch)
    local want = host_answer(find_rec(loc), now)
    if want == "start" then
        -- the host's word: ready and powered - this press starts it there, the
        -- copy's refusal is the race. Off the screen now; shown after all if the
        -- host's start does not come (client_tick).
        if p.copy_fresh then take_off(branch, "the host's shower is ready: this press starts it") end
        p.hold = true
        return
    end
    if want and want ~= branch then
        -- the copy's state was not the host's: the host's answer instead
        if p.copy_fresh then take_off(branch, "the host's state says otherwise") end
        if p.shown ~= want and show(want, "the host's shower state") then
            p.shown, p.shown_fresh = want, fresh(want)
            M.stats.notes_swapped = M.stats.notes_swapped + 1
        end
    end
end

-- <shower>.DecontaminatePlayer, post, client: this copy ran the start branch itself.
local function client_local_start(c)
    st.local_start = { a = addr(c), t = clock() }
end

-- a start of the copy here the host did not confirm: undone
local function undo_local_start(r, now)
    local c = find_copy(r.loc)
    if not c then return end
    local rec = find_rec(r.loc)
    water(c, false)
    set_cooling(c, rec ~= nil and rec.cool_until > now)
    M.stats.undone = M.stats.undone + 1
    log.info("shower: the shower at %s started here but not on the host within %.1f s: water off, cooldown as on the host",
        loc_str(r.loc), PRESS_WAIT)
end

-- This machine's copy against the host's word.
local function reconcile(c, rec, now)
    if rec.water and now >= rec.run_until then
        rec.water = false
        water(c, false)
    elseif not rec.water and now < rec.run_until and water(c, true) > 0 then
        rec.water = true   -- the copy appeared while the host's water runs
    end
    if now - rec.changed < GRACE then return end
    if power_on() and (ue.prop(c, "PoweredOn?") == true) ~= rec.p and set_power(c, rec.p) then
        M.stats.power_fixed = M.stats.power_fixed + 1
        log.info("shower: %s has %s here, as on the host", ue.short(c), rec.p and "power" or "no power")
    end
    if math.abs(rec.cool_until - now) > EDGE then
        local cool = rec.cool_until > now
        if (ue.prop(c, "CooldownRunning?") == true) ~= cool then
            set_cooling(c, cool)
            M.stats.cool_fixed = M.stats.cool_fixed + 1
            log.info("shower: %s %s here, as on the host", ue.short(c),
                cool and string.format("cools down (%.0f s left)", rec.cool_until - now) or "is ready")
        end
    end
    if rec.l ~= "-" and light_of(c) ~= rec.l and set_light(c, rec.l) then
        M.stats.lights_fixed = M.stats.lights_fixed + 1
        log.info("shower: %s lights %s here, as on the host", ue.short(c), COLOURS[rec.l])
    end
end

local function client_pass(now)
    local keep, list = {}, nil
    for _, rec in ipairs(st.known) do
        if now - rec.seen <= KEEP_S or rec.water then
            keep[#keep + 1] = rec
            if list == nil then list = ue.find_object(PATH) and ue.find_all_recent(CLS, PASS_S) or {} end
            local c = find_copy(rec.loc, list)
            if c then reconcile(c, rec, now) end
        end
    end
    st.known = keep
end

local function client_ask(now)
    local cs = S.client
    if not (cs and cs.acked == true) or not ue.local_pawn() then return end
    local key = tostring(S.map) .. "|" .. tostring(cs.pc_key)
    if st.asked == key then return end
    if not st.since or st.since.key ~= key then st.since = { key = key, t = now } return end
    if now - st.since.t < SNAP_AFTER_S then return end
    if net.send_to_host("SHWRQ") then
        st.asked = key
        log.info("shower: asked the host for its showers (SHWRQ)")
    end
end

local function client_tick(now)
    local p = st.press
    if p and now - p.t > PRESS_WAIT then
        st.press = nil
        -- held for a start that did not come: the copy's answer after all (the
        -- host's relay of it was a duplicate of the note taken off)
        if p.hold then show(p.copy, "the host did not start it") end
    end
    if st.go_mine and now - st.go_mine.t > PRESS_WAIT then st.go_mine = nil end
    if #st.runs > 0 then
        local keep = {}
        for _, r in ipairs(st.runs) do
            if now - r.t > PRESS_WAIT then undo_local_start(r, now) else keep[#keep + 1] = r end
        end
        st.runs = keep
    end
    -- the water stops on time even between passes
    for _, rec in ipairs(st.known) do
        if rec.water and now >= rec.run_until then
            rec.water = false
            local c = ue.find_object(PATH) and find_copy(rec.loc)
            if c then water(c, false) end
        end
    end
    client_ask(now)
    if #st.known > 0 and now - st.pass_at >= PASS_S then
        st.pass_at = now
        client_pass(now)
    end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

local function on_decon(c)
    if not S or not on() then return end
    local s = pget(c)
    if not ue.valid(s) then return end
    if S.role == "host" then host_start(s) elseif S.role == "client" then client_local_start(s) end
end

local function on_press(c, actor_p)
    if not S or S.role ~= "client" or not on() then return end
    local s = pget(c)
    if not ue.valid(s) then return end
    client_press(s, pget(actor_p))
end

local function on_exec(c, actor_p, option_p)
    if not S or S.role ~= "client" or not on() then return end
    local b = pget(c)
    if not ue.valid(b) then return end
    client_exec(b, pget(actor_p), pget(option_p))
end

local function changed_cb(why)
    return function(c)
        if not S or S.role ~= "host" or not on() then return end
        local s = pget(c)
        if ue.valid(s) then host_change(s, why) end
    end
end

local HOOKS = {
    { key = "decon", fn = "DecontaminatePlayer", cb = on_decon },
    { key = "press", fn = "OnInteractBuildable", cb = on_press, role = "client" },
    { key = "exec", path = BASE .. ":OnExecuteInteract", cb = on_exec, role = "client" },
    { key = "cooldown", fn = "Event_Cooldown", cb = changed_cb("cooldown over"), role = "host" },
    { key = "on", fn = "On", cb = changed_cb("power on"), role = "host" },
    { key = "off", fn = "Off", cb = changed_cb("power off"), role = "host" },
}

local function try_hooks(now, role)
    if now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    for _, h in ipairs(HOOKS) do
        local path = h.path or (PATH .. ":" .. h.fn)
        if not st.hooks[h.key] and (h.role == nil or h.role == role) and ue.find_object(path) then
            local cb = h.cb
            local ok, err = pcall(RegisterHook, path, function(...)
                local okc, e = pcall(cb, ...)
                if not okc then log.err_throttled("shower." .. h.key, "shower: %s hook: %s", h.key, tostring(e)) end
            end)
            local name = path:match("([%w_]+:[%w_?]+)$") or path
            if ok then
                st.hooks[h.key] = true
                log.info("shower: hook %s ok", name)
            elseif not st.hook_logged[h.key] then
                st.hook_logged[h.key] = true
                log.warn("shower: cannot hook %s yet (%s); retried", name, tostring(err))
            end
        end
    end
end

local function tick()
    if not S then return end
    local role = S.role
    if role ~= st.role then
        if st.role ~= nil then M.reset("role " .. tostring(st.role) .. " -> " .. tostring(role)) end
        st.role = role
    end
    if not on() then return end
    local now = clock()
    if role == "host" then
        if #remote_pcs() == 0 then return end
        try_hooks(now, role)
        if now - st.snap_at >= SNAP_S then
            st.snap_at = now
            snapshot(remote_pcs())
        end
    elseif role == "client" then
        try_hooks(now, role)
        client_tick(now)
    end
end

-- main.lua, every 250 ms (any role).
function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("shower.tick", "shower: tick: %s", tostring(err)) end
end

function M.reset(why)
    st.known, st.snap, st.pass_at, st.asked, st.since = {}, nil, -100, nil, nil
    st.local_start, st.press, st.go_mine, st.runs = nil, nil, nil, {}
    st.snap_at = clock()
    log.debug("shower: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    net.on("SHWR", shower_msg)
    net.on("SHWRQ", snap_msg)
    net.on("SHWRR", rad_msg)
    net.on("SHWRV", rad_values)
    log.info("shower: installed (world_build_shower=%s): one host cooldown per decontamination shower, its water and lights for every player, decontamination for everyone inside",
        tostring(on()))
end

function M.status_line()
    local s = M.stats
    local n = 0
    for _ in pairs(st.hooks) do n = n + 1 end
    return string.format("shower: on=%s hooks=%d/%d | host: starts=%d others decontaminated=%d messages=%d snapshots=%d | client: states=%d known=%d dropped=%d, water=%d, power fixed=%d, cooldown fixed=%d, lights fixed=%d, notes off=%d shown=%d swapped=%d, copy runs=%d, local starts undone=%d, radiation synced=%d",
        tostring(on()), n, #HOOKS, s.starts, s.others, s.sent, s.snaps, s.received, #st.known, s.dropped, s.water,
        s.power_fixed, s.cool_fixed, s.lights_fixed, s.notes_off, s.notes_shown, s.notes_swapped, s.copy_runs, s.undone,
        s.rad_synced)
end

-- tests
M._t = { st = st, TEXT = TEXT, inside = inside, game_target = game_target, BOX = BOX }

return M
