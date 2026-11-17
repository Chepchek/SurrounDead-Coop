-- Mock test: the in-game self test (sdc_selftest) with both sides in one
-- process: a host and a client, each with its own copy of the module, a fake
-- engine (pawns, controller, containers, station, replication of the client's
-- pawn to the host's copy) and a fake sdc_net (latency, a throttled bulk queue,
-- a fast lane and snapshot coalescing that work only through the module's own
-- registration in net.FAST / net.SNAPSHOT).
--   1. off by default: nothing installed, the command is refused
--   2. the happy path: every step, both blocks, DONE counts, line format
--   3. echo series maths (p50 / p95 / max, losses, order)
--   4. a silent host: A.hello FAILs at its timeout, the rest SKIP, no hang
--   5. a host that answers FAIL (no MYSTATE): that step FAILs, the run goes on
--   6. losses on the channel: A.rtt FAILs, the run goes on and ends
--   7. sdc_net behaviour: no fast lane -> B.burst FAIL, no coalescing -> B.snapshot
--      FAIL, no SNAPSHOT table -> SKIP
--   8. nothing near -> SKIP; a pawn that cannot move -> SKIP
--   9. the client leaves the world / is stopped: abort, one DONE
--  10. the host's block: the client goes quiet -> the host prints its block alone
-- usage: lua mock_selftest.lua <scripts dir>
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

local CLK = 1000.0
os.clock = function() return CLK end

local LOADED_KEYS = { "sdc_log", "sdc_ue", "sdc_config", "sdc_net", "sdc_session", "sdc_chat", "sdc_pawnstate",
                      "sdc_containers", "sdc_bdoors", "sdc_perf", "sdc_players", "sdc_items", "sdc_consume", "sdc_quests", "sdc_events",
                      "sdc_markerdata", "sdc_selftest" }

-- ------------------------------------------------------------------ fake net
local function clean(v)
    local s = tostring(v == nil and "" or v)
    return (s:gsub("[|\r\n]", " "))
end
local function encode(kind, ...)
    local parts = { "SDC1", clean(kind) }
    for i = 1, select("#", ...) do parts[#parts + 1] = clean((select(i, ...))) end
    return table.concat(parts, "|")
end
local function decode(s)
    local fields = {}
    for part in (s .. "|"):gmatch("(.-)%|") do fields[#fields + 1] = part end
    table.remove(fields, 1)
    local kind = table.remove(fields, 1)
    return kind, fields
end

-- ------------------------------------------------------------------ a world with two sides
local function new_world(opts)
    opts = opts or {}
    local W = { q = {}, bulk_free = 0, lat = opts.lat or 0.02, delivered = {}, sides = {}, nseq = 0 }

    local function side(name)
        local s = { name = name, lines = {}, frame_cbs = {}, every = {}, actors = {}, objects = {} }
        W.sides[name] = s
        s.log = {
            info = function(f, ...) s.lines[#s.lines + 1] = string.format(f, ...) end,
            warn = function(f, ...) s.lines[#s.lines + 1] = "[WARN] " .. string.format(f, ...) end,
            err = function(f, ...) s.lines[#s.lines + 1] = "[ERR] " .. string.format(f, ...) end,
            err_throttled = function(_, f, ...) s.lines[#s.lines + 1] = "[ERR] " .. string.format(f, ...) end,
            debug = function() end, flush = function() end, ascii = function(x) return tostring(x) end,
        }
        s.cfg = { values = { selftest = opts.cfg_off ~= true and true or false, chat = true },
                  get = function(k) return s.cfg.values[k] end }
        -- fake sdc_net
        local net = { handlers = {}, encode = encode, decode = decode }
        if opts.no_fast ~= true then net.FAST = {} end
        if opts.no_snapshot ~= true then net.SNAPSHOT = {} end
        function net.on(kind, fn) net.handlers[kind] = fn end
        function net.queued_count() return 0 end
        s.net = net
        -- fake sdc_ue
        local ue = { task_stats = { demo = { wmax = 6.5 } } }
        function ue.valid(o) return type(o) == "table" and not o.dead end
        function ue.try(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end
        function ue.class_name(o) return ue.valid(o) and o.class or "" end
        function ue.short(o) return ue.valid(o) and o.name or "<none>" end
        function ue.path(o) return o.path end
        function ue.local_pc() return s.pc end
        function ue.local_pawn() return s.pawn end
        function ue.pawn_of(pc) return pc and pc.pawn or nil end
        function ue.location(o) if not o then return nil end if o.locf then return o.locf() end return o.loc end
        function ue.rotation(o) return { Pitch = 0, Yaw = o.yawf and o.yawf() or o.yaw or 0, Roll = 0 } end
        function ue.prop(o, k)
            if not o or not o.props then return nil end
            local v = o.props[k]
            if type(v) == "function" then return v() end
            return v
        end
        function ue.set_prop(o, k, v) if not ue.valid(o) or not o.props then return false end o.props[k] = v return true end
        function ue.call(o, name, ...)
            local f = o and o.methods and o.methods[name]
            if not f then return false, "no method " .. name end
            return pcall(f, o, ...)
        end
        function ue.find_all(cls) return s.actors[cls] or {} end
        function ue.find_object(path) return s.objects[path] end
        function ue.in_main_menu() return false end
        function ue.every_frame(_, fn) s.frame_cbs[#s.frame_cbs + 1] = fn end
        function ue.every(label, _, fn) s.every[label] = fn end
        function ue.delay(_, _, fn) fn() end
        s.ue = ue
        s.session = { VERSION = "0.0-test", world_reset_hooks = {} }
        s.state = { role = name, client = name == "client" and { acked = true } or nil }
        s.runtime = {}   -- modules the self test finds in package.loaded at run time
        return s
    end
    local H, C = side("host"), side("client")
    W.host, W.client = H, C

    -- ---- the game objects
    local cpawn = { class = "BP_PlayerCharacter_C", name = "Pawn_C", loc = { X = 0, Y = 0, Z = 0 }, yaw = 0,
                    props = { ["Sprinting?"] = false, ["HoldingFirearm?"] = false, bIsCrouched = false }, methods = {} }
    local cpc = { class = "PC_C", name = "PC_C", yaw = 0, methods = {}, pawn = cpawn }
    function cpc.GetControlRotation(self) return { Pitch = 0, Yaw = self.yaw, Roll = 0 } end
    function cpc.methods.SetControlRotation(self, rot) self.yaw = rot.Yaw; cpawn.yaw = rot.Yaw end
    if opts.cannot_move ~= true then
        function cpawn.methods.AddMovementInput(self, dir)
            if opts.blocked_forward and dir.X > 0.5 then return end   -- an obstacle ahead
            if opts.blocked_right and dir.Y > 0.5 then return end
            self.last_move = CLK
            self.last_dir = dir
            self.loc = { X = self.loc.X + dir.X * 8, Y = self.loc.Y + dir.Y * 8, Z = self.loc.Z }
        end
    else
        function cpawn.methods.AddMovementInput() end
    end
    function cpawn.methods.Crouch(self) if opts.cannot_crouch ~= true then self.props.bIsCrouched = true end end
    function cpawn.methods.UnCrouch(self) self.props.bIsCrouched = false end
    C.pc, C.pawn = cpc, cpawn

    cpawn.props["PlayerDead?"] = opts.start_dead == true
    W.respawns = 0
    C.runtime.sdc_players = { request_respawn = function(mode)
        W.respawns = W.respawns + 1
        if opts.respawn_works ~= false and cpawn.props["PlayerDead?"] then cpawn.props["PlayerDead?"] = false; C.pawn = cpawn end
    end }
    if opts.no_players_mod then C.runtime.sdc_players = nil end
    -- the host's own pawn and the client's copy: what god mode must reach
    local function mk_god(name)
        return { class = "BP_PlayerCharacter_C", name = name, props = { bCanBeDamaged = true, ["PlayerDead?"] = false,
                 MedicalComponent = { class = "MedicalComponent_C", name = "Med", props = { ["CanTakeDamage?"] = true } } } }
    end
    W.god_own, W.god_remote = mk_god("Pawn_Host"), mk_god("Pawn_HR")
    H.actors["BP_PlayerCharacter_C"] = { W.god_own, W.god_remote }
    local hviewers = {}
    local hostcomp_box = { class = "BP_JigComponent_C", name = "BoxComp_H" }
    local clientcomp_box = { class = "BP_JigComponent_C", name = "BoxComp_C" }
    function cpawn.methods.RequestServerData(self, comp)
        if opts.no_viewer ~= true then hviewers[hostcomp_box] = true end
    end

    -- host's replicated copy of the client's pawn / controller
    local hpawn = { class = "BP_PlayerCharacter_C", name = "Pawn_H",
        locf = function() return { X = cpawn.loc.X + (opts.pos_offset or 0), Y = cpawn.loc.Y, Z = cpawn.loc.Z } end,
        yawf = function() return cpawn.yaw end,
        props = { bIsCrouched = function() return cpawn.props.bIsCrouched end } }
    local hpc = { class = "PC_H", name = "PC_Remote", pawn = hpawn }
    function hpc.GetControlRotation() return { Pitch = 0, Yaw = cpc.yaw, Roll = 0 } end
    W.hpc = hpc
    H.pc = { class = "PC_H0", name = "PC_Host" }

    if opts.no_box ~= true then
        C.actors["BP_LootContainer_C"] = { { class = "BP_LootContainer_C", name = "Box1", path = "/Game/Box1.Box1",
            loc = { X = 500, Y = 0, Z = 0 }, props = { BP_JigMultiplayer = clientcomp_box } } }
        H.objects["/Game/Box1.Box1"] = { class = "BP_LootContainer_C", name = "Box1_H", path = "/Game/Box1.Box1",
            props = { BP_JigMultiplayer = hostcomp_box } }
    end
    local hcomp_st = { class = "BP_JigComponent_C", name = "StComp_H", ItemsToCraft = { n = 0 } }
    function hcomp_st.ItemsToCraft.GetArrayNum(self) return self.n end
    if opts.no_station ~= true then
        C.actors["BP_CraftingStation_C"] = { { class = "BP_CraftingStation_C", name = "Bench", path = "/Game/Bench.Bench",
            loc = { X = -300, Y = 200, Z = 0 }, props = { BP_JigMultiplayer = { class = "BP_JigComponent_C", name = "StComp_C" } } } }
        H.objects["/Game/Bench.Bench"] = { class = "BP_CraftingStation_C", name = "Bench_H", path = "/Game/Bench.Bench",
            props = { BP_JigMultiplayer = hcomp_st } }
    end

    -- ---- runtime modules (host side checks)
    H.runtime.sdc_chat = { stats = { relayed = 0, dropped = 0, shown = 0 } }
    C.runtime.sdc_chat = { stats = { relayed = 0, dropped = 0, shown = 0 } }
    H.runtime.sdc_pawnstate = { state_of = function(p)
        if opts.no_mystate then return nil end
        local sprint = cpawn.props["Sprinting?"] and (not opts.sprint_needs_motion or CLK - (cpawn.last_move or -9) < 0.1)
        if sprint and opts.sprint_forward_only then   -- only along the control rotation
            local d, y = cpawn.last_dir or { X = 0, Y = 0 }, math.rad(cpc.yaw)
            sprint = d.X * math.cos(y) + d.Y * math.sin(y) > 0.7
        end
        return { sp = sprint and "1" or "0", hf = cpawn.props["HoldingFirearm?"] and "1" or "0",
                 cs = "0", bs = "0" }
    end }
    H.runtime.sdc_containers = { has_viewers = function(comp) return hviewers[comp] == true end }
    H.runtime.sdc_bdoors = { stats = { snaps = 0 } }
    H.runtime.sdc_perf = { hooks = { x = { name = "Foo:Bar", wmax = 3.5 } } }
    C.runtime.sdc_perf = { hooks = {} }
    -- ---- C.markers: the markers the client's own mod places (sdc_quests.selftest_marker, sdc_events.place_marker);
    -- opts.markers = { quest = false (no marker placed), quest_widget = false (its map widget is not built), event_widget = false,
    -- quest_title = "..." (what the actor holds) }
    do
        local mo = opts.markers or {}
        local function marker_actor(cls, title, radius, widget)
            return { class = cls, name = cls .. "_1", props = { Marker = widget and { class = "W_Marker_C", name = "W" } or nil },
                     md = { title = title, radius = radius }, K2_DestroyActor = function(self) self.dead = true end }
        end
        local placed, ev_st = {}, { markers = {} }
        C.runtime.sdc_markerdata = { read = function(a) return a and a.md or nil end }
        C.runtime.sdc_quests = {
            selftest_marker = function(tag, rec)
                if mo.quest == false then return nil end
                placed[tag] = marker_actor("BP_QuestMarker_C", mo.quest_title or rec.text, rec.radius, mo.quest_widget ~= false)
                return placed[tag]
            end,
            selftest_marker_drop = function(tag) placed[tag] = nil; W.markers_dropped = (W.markers_dropped or 0) + 1 end,
        }
        C.runtime.sdc_events = {
            _st = ev_st,
            place_marker = function(key, _, mk)
                local a = marker_actor("BP_Marker_C", mk.title, nil, mo.event_widget ~= false)
                a.path = "/Game/Map.Map:PersistentLevel.BP_Marker_C_1"
                C.objects[a.path] = a
                ev_st.markers[key] = a.path
                return "map marker placed"
            end,
        }
    end
    -- ---- the own equipment for C.durability: opts.dur = { game (the durability the game answers), actor, screen, struct,
    -- host (the durability of the same item on the host; nil = the host lists no item),
    -- no_call = true (DurabilityCheck missing), no_actor = true (nothing equipped) }
    if opts.dur then
        local d = opts.dur
        local DUR_INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
        local DUR_USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
        local DUR_FIELD = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
        local actor = { class = "BP_MeleePickup_C", name = "Knife_C", props = {} }
        actor.props.BP_JigMultiplayer = { class = "BP_JigMultiplayer_C", name = "KnifeJig",
            PickupInfo = { [DUR_INFO] = { [DUR_FIELD] = { X = d.actor, Y = 100 } }, [DUR_USID] = { A = 1, B = 2, C = 3, D = 4 } } }
        local helper = { class = "BP_JigHelperComp_C", name = "Helper", props = {}, methods = {}, ServerEquippedItems = {} }
        if d.struct ~= nil then
            helper.ServerEquippedItems["EquippedMelee_48_0C451F654720DD3648581EA9DB6E85D0"] = { [DUR_FIELD] = { X = d.struct, Y = 100 } }
        end
        local jig = { class = "BP_JigMultiplayer_C", name = "OwnJig", props = {}, methods = {} }
        local dstats = { uid_filled = 2, dur_from_slot = 1, dur_from_ui = 3, dur_restored = 0, dur_no_data = 0, dur_calls = 0, equid_calls = 0 }
        -- BP_MeleePickup.DurabilityCheck(Dmg, out NewDmg): Dmg * (durability / 100) ^ 0.225; the mod's GetDurability
        -- hook runs inside it (counted) unless d.hook_runs == false (UE4SS: no hooks inside a call made from Lua)
        actor.methods = {}
        if d.no_call ~= true then
            function actor.methods.DurabilityCheck(self, dmg, out)
                out.NewDmg = dmg * (d.game / 100) ^ 0.225
                if d.hook_runs ~= false then dstats.dur_calls = dstats.dur_calls + 1 end
            end
        end
        cpawn.props.BP_JigHelperComp, cpawn.props.BP_JigMultiplayer = helper, jig
        C.runtime.sdc_items = {
            stats = dstats,
            equipped_of = function()
                if d.no_actor == true then return {} end
                return { a1 = { actor = actor, slot = "Jig.PlayerSlot.MeleeWeapon" } }
            end }
        H.runtime.sdc_items = { equipped_of = function()
            if d.host == nil then return {} end
            local hactor = { class = "BP_MeleePickup_C", name = "Knife_H", props = {} }
            hactor.props.BP_JigMultiplayer = { class = "BP_JigMultiplayer_C", name = "KnifeJig_H",
                PickupInfo = { [DUR_INFO] = { [DUR_FIELD] = { X = d.host, Y = 100 } } } }
            return { h1 = { actor = hactor, slot = "Jig.PlayerSlot.MeleeWeapon" } }
        end }
        C.runtime.sdc_consume = { client_view = function()
            if d.screen == nil then return {} end
            return { ["1:2:3:4"] = { slot = { Dur = d.screen } } }
        end }
    end
    -- the game side of the mod's own messages
    H.net.on("CHAT", function(f, pc)
        local chat = H.runtime.sdc_chat
        if opts.chat_dropped then chat.stats.dropped = chat.stats.dropped + 1 return end
        chat.stats.relayed = chat.stats.relayed + 1
        H.net.send_to(pc, "CHATM", "1", "Bob", f[1])
    end)
    C.net.on("CHATM", function() C.runtime.sdc_chat.stats.shown = C.runtime.sdc_chat.stats.shown + 1 end)
    H.net.on("STABLE", function() hcomp_st.ItemsToCraft.n = opts.recipes or 14 end)
    H.net.on("WBDOORQ", function(_, pc)
        if opts.no_door_answer then return end
        H.runtime.sdc_bdoors.stats.snaps = H.runtime.sdc_bdoors.stats.snaps + 1
        H.net.send_to(pc, "WBDOOR", "s", "d1")
    end)
    W.door_prev_calls = 0
    C.net.on("WBDOOR", function() W.door_prev_calls = W.door_prev_calls + 1 end)
    C.runtime.sdc_bdoors = nil

    -- ---- transmission
    local function transmit(from, to, kind, raw)
        if opts.drop and opts.drop(kind, raw, from) then return true end
        local fields_kind, fields = decode(raw)
        W.nseq = W.nseq + 1
        local nseq = W.nseq
        local due = CLK + W.lat
        local net_from = from.net
        local fast = net_from.FAST and net_from.FAST[kind] and opts.fast_lane ~= false
        -- host -> client bulk kinds of the burst are serialized (a throttled queue)
        if from == H and (kind == "STESTB" or kind == "STESTS" or (kind == "STESTF" and not fast)) then
            W.bulk_free = math.max(W.bulk_free, CLK) + 0.09
            due = W.bulk_free + W.lat
            local reg = net_from.SNAPSHOT and net_from.SNAPSHOT[kind]
            if reg and opts.coalesce ~= false then
                local key = reg(fields)
                if opts.keep_old then
                    for _, m in ipairs(W.q) do if m.kind == kind and m.key == key and m.due > CLK and m.to == to then return true end end
                end
                for i = #W.q, 1, -1 do
                    local m = W.q[i]
                    if m.kind == kind and m.key == key and m.due > CLK and m.to == to then table.remove(W.q, i) end
                end
                W.q[#W.q + 1] = { due = due, to = to, raw = raw, kind = kind, key = key, from = from, n = nseq }
                return true
            end
        end
        W.q[#W.q + 1] = { due = due, to = to, raw = raw, kind = kind, from = from, n = nseq }
        return true
    end
    function H.net.send_to(pc, kind, ...) return transmit(H, C, kind, encode(kind, ...)) end
    function C.net.send_to_host(kind, ...) return transmit(C, H, kind, encode(kind, ...)) end

    -- ---- the module, one copy per side
    local function enter(s)
        package.loaded.sdc_log, package.loaded.sdc_ue, package.loaded.sdc_config = s.log, s.ue, s.cfg
        package.loaded.sdc_net, package.loaded.sdc_session = s.net, s.session
        for _, k in ipairs({ "sdc_chat", "sdc_pawnstate", "sdc_containers", "sdc_bdoors", "sdc_perf", "sdc_players", "sdc_items", "sdc_consume", "sdc_quests", "sdc_events", "sdc_markerdata" }) do
            package.loaded[k] = s.runtime[k]
        end
        package.loaded.sdc_selftest = nil
    end
    W.enter = enter
    for _, s in ipairs({ H, C }) do
        enter(s)
        local f = assert(loadfile(dir .. "/sdc_selftest.lua"))
        s.mod = f()
        s.mod.install(s.state)
    end
    for _, k in ipairs(LOADED_KEYS) do package.loaded[k] = nil end

    local function deliver_due()
        table.sort(W.q, function(a, b) if a.due ~= b.due then return a.due < b.due end return a.n < b.n end)
        local n = 0
        while W.q[1] and W.q[1].due <= CLK do
            local m = table.remove(W.q, 1)
            local to = m.to
            local kind, fields = decode(m.raw)
            local h = to.net.handlers[kind]
            if h then
                enter(to)
                local pc = to == H and hpc or C.pc
                local ok, err = pcall(h, fields, pc)
                if not ok then to.lines[#to.lines + 1] = "[ERR] handler " .. tostring(kind) .. ": " .. tostring(err) end
            end
            n = n + 1
        end
        return n
    end

    local tick_n = 0
    function W.step()
        CLK = CLK + 0.02
        for _, s in ipairs({ H, C }) do
            enter(s)
            for _, cb in ipairs(s.frame_cbs) do cb() end
        end
        deliver_due()
        tick_n = tick_n + 1
        if tick_n % 5 == 0 then
            for _, s in ipairs({ H, C }) do
                enter(s)
                if s.every.selftest then s.every.selftest() end
            end
        end
    end
    function W.run_until(cond, max_s)
        local t0 = CLK
        while not cond() and CLK - t0 < max_s do W.step() end
        return cond()
    end
    function W.cmd(v) enter(C); return C.mod.command(v) end
    return W
end

local function lines_of(s, pat)
    local out = {}
    for _, l in ipairs(s.lines) do if l:find(pat) then out[#out + 1] = l end end
    return out
end
local function done_of(s)
    local out = lines_of(s, "^%[SELFTEST%] DONE ")
    return out
end
local function counts(l)
    if not l then return nil end
    local p, f, k = l:match("DONE pass=(%d+) fail=(%d+) skip=(%d+)")
    return tonumber(p), tonumber(f), tonumber(k)
end
local function status_of(s, step)
    for _, l in ipairs(s.lines) do
        local st = l:match("^%[SELFTEST%] " .. step:gsub("%.", "%%.") .. " (%u+) ")
        if st then return st, l end
    end
end
local function finish(W, max_s)
    return W.run_until(function() return #done_of(W.client) >= 1 and #done_of(W.host) >= 1 end, max_s or 600)
end

-- ------------------------------------------------------------------ 1. off by default
do
    say("1. off by default")
    local W = new_world({ cfg_off = true })
    check(W.client.net.handlers.STEST == nil and W.host.net.handlers.STEST == nil, "config off: no STEST handler installed")
    check(W.client.net.FAST == nil or W.client.net.FAST.STESTF == nil, "config off: nothing registered in sdc_net")
    check(W.cmd("1") == false, "config off: the command is refused")
    for _ = 1, 400 do W.step() end
    check(#lines_of(W.client, "starts on the client") == 0, "config off: no run")
    check(#lines_of(W.client, "ignored: config selftest is off") == 1, "config off: one clear log line")
    check(W.client.every.selftest == nil, "config off: no tick registered")
end

-- ------------------------------------------------------------------ 2. happy path
do
    say("2. the happy path")
    local W = new_world()
    check(W.cmd("1") == true, "command accepted on the client")
    check(W.host.net.handlers.STEST ~= nil and W.host.net.FAST.STESTF == true and type(W.host.net.SNAPSHOT.STESTS) == "function",
        "module registers its fast and snapshot kinds in sdc_net")
    check(W.host.net.SNAPSHOT.STESTS({ "k1", "7" }) == "k1", "snapshot key is the first field")
    local t0 = CLK
    local ended = finish(W)
    check(ended, "both sides print DONE (" .. string.format("%.0f", CLK - t0) .. " s of game time)")
    local cp, cf, ck = counts(done_of(W.client)[1])
    local hp, hf, hk = counts(done_of(W.host)[1])
    check(#done_of(W.client) == 1 and #done_of(W.host) == 1, "exactly one DONE per side")
    check(cp == 20 and cf == 0 and ck == 3, string.format("client DONE pass=%s fail=%s skip=%s (20 steps pass, 3 skip: C.durability skips, the mock pawn has no BP_JigHelperComp)", tostring(cp), tostring(cf), tostring(ck)))
    check(hf == 0 and (hp or 0) >= 19, string.format("host DONE pass=%s fail=%s skip=%s", tostring(hp), tostring(hf), tostring(hk)))
    local want = { "A.hello", "A.rtt.50", "A.rtt.1k", "A.rtt.3k", "A.host.50", "A.host.1k", "A.host.3k", "B.burst",
                   "B.snapshot", "C.chat", "C.sprint", "C.weapon", "C.crouch", "C.container", "C.workbench", "C.door",
                   "C.turn", "C.walk", "D.frame" }
    local bad = {}
    for _, name in ipairs(want) do
        local st = status_of(W.client, name)
        if st ~= "PASS" then bad[#bad + 1] = name .. "=" .. tostring(st) end
    end
    check(#bad == 0, "every client step PASS " .. table.concat(bad, ","))
    local fmt_bad = 0
    for _, l in ipairs(W.client.lines) do
        if l:find("^%[SELFTEST%]") and not (l:find("^%[SELFTEST%] %S+ %u%u%u%u? ") or l:find("^%[SELFTEST%] DONE ")
            or l:find("^%[SELFTEST%] | ") or l:find("^%[SELFTEST%] =====") or l:find("^%[SELFTEST%] run ")
            or l:find("^%[SELFTEST%] start requested") or l:find("^%[SELFTEST%] on:")) then
            fmt_bad = fmt_bad + 1
            say("    odd line: " .. l)
        end
    end
    check(fmt_bad == 0, "every client [SELFTEST] line has the agreed shape")
    local ascii_bad = 0
    for _, s in ipairs({ W.client, W.host }) do
        for _, l in ipairs(s.lines) do if l:find("[\128-\255]") then ascii_bad = ascii_bad + 1 end end
    end
    check(ascii_bad == 0, "logs are ASCII")
    local _, l1 = status_of(W.client, "A.rtt.3k")
    check(l1 and l1:find("p50=") and l1:find("p95=") and l1:find("max=") and l1:find("lost=0") and l1:find("ooo=0"),
        "A.rtt line has p50 / p95 / max / losses / order")
    local _, lb = status_of(W.client, "B.burst")
    check(lb and lb:find("overtook"), "B.burst: the fast answer overtook the queue")
    local _, ls = status_of(W.client, "B.snapshot")
    check(ls and ls:find("last=20") and not ls:find("k1: 20 of"), "B.snapshot: last version held, fewer than 20 delivered: " .. tostring(ls))
    check(W.client.net.handlers.WBDOOR ~= nil and W.door_prev_calls >= 1, "C.door: the real WBDOOR handler is untouched and gets the answer")
    check(W.client.pawn.props["Sprinting?"] == false and W.client.pawn.props["HoldingFirearm?"] == false
        and W.client.pawn.props.bIsCrouched == false, "the pawn's flags are put back")
    check(math.abs(W.client.pc.yaw) < 1e-6, "the control rotation is put back")
    check(W.client.pawn.loc.X > 100, "C.walk: the pawn really moved")
    local _, lw = status_of(W.client, "D.frame")
    check(lw and lw:find("frames=") and lw:find("p99=") and lw:find("worst hook"), "D.frame: frame times of both sides and the mod's worst call")
    check(#lines_of(W.host, "^%[SELFTEST%] | ") >= 20 and #lines_of(W.host, "host summary") == 1, "host prints its own block")
    check(#lines_of(W.client, "client summary") == 1, "client prints one block")
    check(#lines_of(W.client, "%[ERR%]") == 0 and #lines_of(W.host, "%[ERR%]") == 0, "no errors logged")
    check(W.client.every.selftest ~= nil, "tick registered only because the config is on")
    check(W.god_own.props.bCanBeDamaged == false and W.god_own.props.MedicalComponent.props["CanTakeDamage?"] == false
        and W.god_remote.props.bCanBeDamaged == false and W.god_remote.props.MedicalComponent.props["CanTakeDamage?"] == false,
        "host: every player character made invulnerable (bCanBeDamaged and CanTakeDamage?)")
    check(#lines_of(W.host, "made invulnerable") == 1, "host: the mechanism is logged once")
    -- a second command after the run starts a new one
    check(W.cmd("1") == true, "a new run can be started afterwards")
end

-- ------------------------------------------------------------------ 3. echo series maths
do
    say("3. echo series")
    local W = new_world()
    W.enter(W.client)
    local sent = {}
    local p = W.client.mod._t.new_pinger({ dir = "c", tag = "t", size = 100, count = 10, window = 3,
        send = function(op, dir, tag, seq) sent[#sent + 1] = seq return true end })
    p:fill(0)
    check(#sent == 3 and p.nin == 3, "window of 3 in flight")
    p:on_echo(1, 0.010); p:on_echo(2, 0.020); p:on_echo(3, 0.030)
    check(#sent == 6, "each echo sends the next")
    p:on_echo(5, 0.040); p:on_echo(4, 0.050)   -- 4 came after 5
    check(p.ooo == 1, "an echo that comes after a later one counts as out of order")
    for s = 6, 10 do p:on_echo(s, 0.1 + s * 0.01) end
    check(p.done and p.got == 10 and p.lost == 0, "all echoed: done, nothing lost")
    local r = p:result()
    check(r.max > 0 and r.p50 <= r.p95 and r.p95 <= r.max, "p50 <= p95 <= max")
    local lost = W.client.mod._t.new_pinger({ dir = "c", tag = "t", size = 100, count = 4, window = 4, msg_timeout = 5,
        send = function() return true end })
    lost:fill(0)
    lost:on_echo(1, 0.01)
    lost:tick(2); check(not lost.done, "not lost before the per-message timeout")
    lost:tick(6)
    check(lost.done and lost.lost == 3 and lost.got == 1, "unanswered messages are lost after the timeout, the series ends")
    local nosend = W.client.mod._t.new_pinger({ dir = "c", tag = "t", size = 100, count = 3, window = 3, send = function() return false end })
    nosend:fill(0)
    check(nosend.done and nosend.lost == 3, "messages that cannot be sent are lost at once")
    local pct = W.client.mod._t.new_pinger({ dir = "c", tag = "t", size = 100, count = 100, window = 100, send = function() return true end })
    pct:fill(0)
    for s = 1, 100 do pct:on_echo(s, s / 1000) end
    local rr = pct:result()
    check(math.abs(rr.p50 - 50) < 1.01 and math.abs(rr.p95 - 95) < 1.01 and math.abs(rr.max - 100) < 1.01, "percentiles of 1..100 ms")
end

-- ------------------------------------------------------------------ 4. a silent host
do
    say("4. a silent host")
    local W = new_world({ drop = function(kind, raw, from) return from.name == "host" end })
    W.cmd("1")
    local t0 = CLK
    local ok = W.run_until(function() return #done_of(W.client) >= 1 end, 120)
    check(ok, "the run ends (no hang): " .. string.format("%.0f", CLK - t0) .. " s")
    check(CLK - t0 < 40, "within the hello timeout, not the whole script")
    local st, l = status_of(W.client, "A.hello")
    check(st == "FAIL" and l:find("timeout"), "A.hello FAIL with a timeout text: " .. tostring(l))
    local p, f, k = counts(done_of(W.client)[1])
    check(p == 0 and f == 1 and k == 22, string.format("DONE pass=0 fail=1 skip=22 (got %s/%s/%s)", tostring(p), tostring(f), tostring(k)))
    check(status_of(W.client, "C.walk") == "SKIP", "the rest is SKIPped")
end

-- ------------------------------------------------------------------ 5. host says FAIL
do
    say("5. a host verdict of FAIL")
    local W = new_world({ no_mystate = true, chat_dropped = true, pos_offset = 400, no_viewer = true, no_door_answer = true, recipes = 0 })
    W.cmd("1")
    check(finish(W), "the run ends")
    local p, f, k = counts(done_of(W.client)[1])
    check(status_of(W.client, "C.sprint") == "FAIL" and status_of(W.client, "C.weapon") == "FAIL", "no MYSTATE on the host: sprint / weapon FAIL")
    check(status_of(W.client, "C.chat") == "FAIL", "chat dropped by the host: FAIL")
    check(status_of(W.client, "C.walk") == "FAIL", "host position 4 m away: C.walk FAIL")
    check(status_of(W.client, "C.container") == "FAIL", "no viewer on the host: C.container FAIL")
    check(status_of(W.client, "C.door") == "FAIL", "no door answer: C.door FAIL")
    check(status_of(W.client, "C.workbench") == "FAIL", "0 recipes: C.workbench FAIL")
    check(status_of(W.client, "A.rtt.50") == "PASS" and status_of(W.client, "D.frame") == "PASS", "the run went on past the failures")
    check(f == 7 and p + f + k == 23, string.format("DONE fail=7 and the total is 23 (got %s/%s/%s)", tostring(p), tostring(f), tostring(k)))
    local hp, hf = counts(done_of(W.host)[1])
    check((hf or 0) >= 7, "the host's own DONE counts the failures too (" .. tostring(hf) .. ")")
end

-- ------------------------------------------------------------------ 6. losses on the channel
do
    say("6. losses")
    local lost_n = 0
    local W = new_world({ drop = function(kind, raw, from)
        if kind == "STEST" and raw:find("^SDC1|STEST|ECHO|c|50|3|") then lost_n = lost_n + 1 return true end
    end })
    W.cmd("1")
    check(finish(W), "the run ends")
    local st, l = status_of(W.client, "A.rtt.50")
    check(st == "FAIL" and l:find("lost=1"), "A.rtt.50 FAIL with lost=1: " .. tostring(l))
    check(status_of(W.client, "A.rtt.1k") == "PASS", "the next series is fine")
    local p, f, k = counts(done_of(W.client)[1])
    check(f == 1 and p == 19, string.format("DONE pass=19 fail=1 (got %s/%s/%s)", tostring(p), tostring(f), tostring(k)))
    -- a slow channel: p95 over the limit
    local W2 = new_world({ lat = 0.7 })
    W2.cmd("1")
    check(finish(W2, 2000), "a slow channel: the run still ends")
    local st2 = status_of(W2.client, "A.rtt.50")
    check(st2 == "FAIL", "p95 of 1.4 s round trips fails A.rtt")
end

-- ------------------------------------------------------------------ 7. sdc_net behaviour
do
    say("7. sdc_net behaviour")
    local W = new_world({ fast_lane = false })
    W.cmd("1")
    check(finish(W), "the run ends")
    local st, l = status_of(W.client, "B.burst")
    check(st == "FAIL" and l:find("waited behind"), "no fast lane: B.burst FAIL: " .. tostring(l))
    check(status_of(W.client, "B.snapshot") == "PASS", "snapshot still PASS")
    local W2 = new_world({ coalesce = false })
    W2.cmd("1")
    check(finish(W2), "the run ends (no coalescing)")
    local st2, l2 = status_of(W2.client, "B.snapshot")
    check(st2 == "FAIL" and l2:find("nothing was coalesced"), "no coalescing: B.snapshot FAIL: " .. tostring(l2))
    local W5 = new_world({ keep_old = true })
    W5.cmd("1")
    check(finish(W5), "the run ends (a queue that keeps the OLD version)")
    local st5, l5 = status_of(W5.client, "B.snapshot")
    check(st5 == "FAIL" and l5:find("LAST"), "old version kept: B.snapshot FAIL: " .. tostring(l5))
    local W3 = new_world({ no_snapshot = true })
    W3.cmd("1")
    check(finish(W3), "the run ends (no SNAPSHOT table)")
    local st3, l3 = status_of(W3.client, "B.snapshot")
    check(st3 == "SKIP" and l3:find("no SNAPSHOT"), "no registration table: B.snapshot SKIP with the reason: " .. tostring(l3))
    local p3, f3, k3 = counts(done_of(W3.client)[1])
    check(k3 == 4 and f3 == 0, "DONE skip=4 fail=0")
    local W4 = new_world({ no_fast = true, no_snapshot = true })
    W4.cmd("1")
    check(finish(W4), "the run ends (an sdc_net with neither table)")
    check(status_of(W4.client, "B.burst") == "PASS" and status_of(W4.client, "B.snapshot") == "SKIP", "old sdc_net: burst only measured, snapshot SKIP")
end

-- ------------------------------------------------------------------ 8. nothing near
do
    say("8. nothing near / cannot move")
    local W = new_world({ no_box = true, no_station = true, cannot_crouch = true, cannot_move = true })
    W.cmd("1")
    check(finish(W), "the run ends")
    local st, l = status_of(W.client, "C.container")
    check(st == "SKIP" and l:find("no loot container within 10 m"), "no container: SKIP with the reason")
    check(status_of(W.client, "C.workbench") == "SKIP", "no station: SKIP")
    check(status_of(W.client, "C.crouch") == "SKIP", "pawn does not crouch locally: SKIP")
    local st2, l2 = status_of(W.client, "C.walk")
    check(st2 == "SKIP" and l2:find("did not move"), "pawn did not move: SKIP: " .. tostring(l2))
    local p, f, k = counts(done_of(W.client)[1])
    check(status_of(W.client, "C.sprint") == "SKIP", "pawn cannot walk: C.sprint SKIP, not FAIL")
    check(f == 0 and k == 8, string.format("DONE fail=0 skip=8 (got %s/%s/%s)", tostring(p), tostring(f), tostring(k)))
end

-- ------------------------------------------------------------------ 9. leaving / stopping
do
    say("9. abort")
    local W = new_world()
    W.cmd("1")
    W.run_until(function() return status_of(W.client, "A.rtt.1k") ~= nil end, 100)
    W.client.state.role = "standalone"
    W.client.pawn = nil
    local ok = W.run_until(function() return #done_of(W.client) >= 1 end, 60)
    check(ok, "left the world: the run ends within 60 s")
    local p, f, k = counts(done_of(W.client)[1])
    check(f >= 1 and (k or 0) > 0 and p + f + k == 23, string.format("the unfinished steps are FAIL / SKIP, total 23 (got %s/%s/%s)", tostring(p), tostring(f), tostring(k)))
    check(#done_of(W.client) == 1, "one DONE")
    local W2 = new_world()
    W2.cmd("1")
    W2.run_until(function() return status_of(W2.client, "A.rtt.50") ~= nil end, 100)
    W2.cmd("0")
    check(#done_of(W2.client) == 1, "selftest=0 stops the run with a DONE")
    local p2, f2, k2 = counts(done_of(W2.client)[1])
    check(p2 + f2 + k2 == 23, "all 23 steps accounted for after the stop")
    check(W2.client.pawn.props["Sprinting?"] == false, "game state restored after the stop")
    -- a host copy: the command only answers
    local W3 = new_world()
    W3.enter(W3.host)
    check(W3.host.mod.command("1") == false, "the command on the host starts nothing")
    local W4 = new_world()
    W4.client.pawn = nil
    W4.cmd("1")
    for _ = 1, 6200 do W4.step() end   -- 124 s without a pawn
    check(#lines_of(W4.client, "not started") == 1 and #done_of(W4.client) == 0, "a client that never gets into the world: 'not started' after 120 s, no run")
end

-- ------------------------------------------------------------------ 10. the host's block alone
do
    say("10. the client goes quiet")
    local cut = { on = false }
    local W = new_world({ drop = function(kind, raw, from) return from.name == "client" and cut.on end })
    W.cmd("1")
    W.run_until(function() return status_of(W.host, "A.check.50") ~= nil end, 100)
    cut.on = true
    local ok = W.run_until(function() return #done_of(W.host) >= 1 end, 120)
    check(ok, "a host whose client went quiet prints its block and DONE by itself")
    check(#lines_of(W.host, "went quiet") == 1, "the block says why")
end

do
    say("11. dead client / respawn / god mode")
    local W = new_world({ start_dead = true })
    W.cmd("1")
    check(W.run_until(function() return #lines_of(W.client, "respawn asked") >= 1 end, 40), "a dead client asks for a respawn")
    check(finish(W), "the run goes on after the respawn and ends")
    local p, f, k = counts(done_of(W.client)[1])
    check(p == 20 and f == 0, string.format("all steps pass after the respawn (got %s/%s/%s)", tostring(p), tostring(f), tostring(k)))
    check(#lines_of(W.client, "the client is dead: respawn asked") >= 1, "the log says what happened")
    -- no respawn path: waits, then gives up after 120 s
    local W2 = new_world({ start_dead = true, no_players_mod = true })
    W2.cmd("1")
    for _ = 1, 6200 do W2.step() end
    check(#lines_of(W2.client, "not started") == 1 and #lines_of(W2.client, "no respawn path") >= 1, "no respawn path: said so, not started after 120 s")
    -- respawn that never works: respawn retried every 20 s
    local W3 = new_world({ start_dead = true, respawn_works = false })
    W3.cmd("1")
    for _ = 1, 6200 do W3.step() end
    check(W3.respawns >= 5 and W3.respawns <= 7, "a respawn that does not work is retried every 20 s (" .. W3.respawns .. " tries)")
    -- dies in the middle of the run: respawn, the run still ends
    local W4 = new_world()
    W4.cmd("1")
    W4.run_until(function() return status_of(W4.client, "B.burst") ~= nil end, 200)
    W4.client.pawn.props["PlayerDead?"] = true
    check(finish(W4), "a client that dies mid-run: the run still ends")
    check(W4.respawns >= 1, "it asked for a respawn mid-run")
    local W6 = new_world({ respawn_works = false })
    W6.cmd("1")
    W6.run_until(function() return status_of(W6.client, "B.burst") ~= nil end, 200)
    W6.client.pawn.props["PlayerDead?"] = true
    check(W6.run_until(function() return #done_of(W6.client) >= 1 end, 300), "dead for good: the run still ends (steps fail / skip, no hang)")
    check(W6.respawns >= 1, "and the respawn was asked for")
    -- god mode is off with the config off
    local W5 = new_world({ cfg_off = true })
    for _ = 1, 400 do W5.step() end
    check(W5.god_own.props.bCanBeDamaged == true, "config off: nobody is made invulnerable")
end

do
    say("12. walk in another direction, sprint while walking")
    local W = new_world({ blocked_forward = true, sprint_needs_motion = true })
    W.cmd("1")
    check(finish(W), "the run ends")
    local st, l = status_of(W.client, "C.walk")
    check(st == "PASS" and l:find("walked right %(90 deg%)") and l:find("cm"), "forward blocked: the walk finds 'right' and says so: " .. tostring(l))
    local st2, l2 = status_of(W.client, "C.sprint")
    check(st2 == "PASS" and l2:find("while walking"), "Sprinting? holds only while moving: C.sprint PASS: " .. tostring(l2))
    local W3 = new_world({ blocked_forward = true, blocked_right = true, sprint_needs_motion = true, sprint_forward_only = true })
    W3.cmd("1")
    check(finish(W3), "the run ends (only left works, sprint only forward)")
    local st4, l4 = status_of(W3.client, "C.walk")
    check(st4 == "PASS" and l4:find("walked left %(270 deg%)"), "forward and right blocked: walked left: " .. tostring(l4))
    check(status_of(W3.client, "C.sprint") == "PASS", "the control rotation is turned to the walked direction: sprint is forward movement")
    check(math.abs(W3.client.pc.yaw) < 1e-6, "the control rotation is put back after the sprint")
    local W2 = new_world({ sprint_needs_motion = true })
    W2.cmd("1")
    check(finish(W2), "the run ends (forward free)")
    local _, l3 = status_of(W2.client, "C.walk")
    check(l3 and l3:find("walked forward"), "forward free: 'forward' is reported")
    local p, f = counts(done_of(W2.client)[1])
    check(p == 20 and f == 0, "all 20 pass")
    check(W2.client.pawn.props["Sprinting?"] == false, "Sprinting? put back")
end

do
    say("13. C.durability: the game's own answer next to the item actor, the equipped struct and the screen")
    local function dur_world(d)
        local W = new_world({ dur = d })
        W.cmd("1")
        check(finish(W), "the run ends")
        return status_of(W.client, "C.durability")
    end
    -- a whole item answered with its number: PASS, every source on the line
    local st, l = dur_world({ game = 95, actor = 95, screen = 95, struct = 95, host = 95 })
    check(st == "PASS" and l:find("game 95.0 (NewDmg 98.9 of 100)", 1, true) and l:find("screen 95.0", 1, true)
        and l:find("actor 95.0/100", 1, true) and l:find("struct 95.0", 1, true), "healthy: PASS with game / screen / actor / struct: " .. tostring(l))
    check(l:find("uid_filled=2 from_slot=1 from_screen=3", 1, true) ~= nil, "the mod's own counters are on the line: " .. tostring(l))
    check(l:find("host 95.0", 1, true) and l:find("host: MeleeWeapon 95.0/100", 1, true), "the host's number is on the line: " .. tostring(l))
    -- the bug of the 17.11 review: the game reads 0 for a whole item
    local st2, l2 = dur_world({ game = 0, actor = 95, screen = 95, struct = 0 })
    check(st2 == "FAIL" and l2:find("game 0.0 (NewDmg 0.0 of 100)", 1, true) and l2:find("struct 0.0", 1, true),
        "a whole item read as 0: FAIL, and an unfilled struct shows as 0.0 next to the screen: " .. tostring(l2))
    -- the struct could not be read at all: it shows as '-', the verdict does not depend on it
    local st3, l3 = dur_world({ game = 95, actor = 95, screen = 95 })
    check(st3 == "PASS" and l3:find("struct -", 1, true), "struct unreadable: '-': " .. tostring(l3))
    -- the screen is the reference when it is there; without it the actor is
    local st4, l4 = dur_world({ game = 95, actor = 95 })
    check(st4 == "PASS" and l4:find("screen -", 1, true), "no screen number: the actor is the reference: " .. tostring(l4))
    local st5 = dur_world({ game = 0, actor = 0, screen = 0 })
    check(st5 == "PASS", "a really broken item stays broken: PASS")
    -- the actor says 95, the screen says 0 (it is the reference): a game answer of 95 is not 'broken' but nothing is claimed
    local st6, l6 = dur_world({ game = 95, actor = 95, screen = 0 })
    check(st6 == "SKIP", "screen 0 / answer 95: cannot tell, SKIP (not a FAIL): " .. tostring(st6))
    -- what 17.11 showed in the game: every number on the client reads 0.0 (the actor, the struct, the game's answer), the
    -- screen has no row; only the host knows the item is whole - the host's number is the reference
    local stz, lz = dur_world({ game = 0, actor = 0, struct = 0, host = 100 })
    check(stz == "FAIL" and lz:find("host 100.0", 1, true) and lz:find("screen -", 1, true),
        "all client numbers 0, the host says 100: FAIL (without the host the zeros would pass as 'broken'): " .. tostring(lz))
    local stq = dur_world({ game = 0, actor = 0, struct = 0 })
    check(stq == "PASS", "the same zeros with the host listing nothing: the client's own zeros stand (PASS, 'broken')")
    local sth, lh = dur_world({ game = 0, actor = 0, struct = 0, host = 0 })
    check(sth == "PASS" and lh:find("host 0.0", 1, true), "the host says 0 too: a really broken item, PASS: " .. tostring(lh))
    -- what 17.11 showed in the game: DurabilityCheck made from Lua does not run the mod's hook (GetDurability x0), so
    -- the number is the game's raw answer: SKIP, never a FAIL (the fix has not been looked at)
    local stn, ln = dur_world({ game = 0, actor = 0, struct = 0, host = 100, hook_runs = false })
    check(stn == "SKIP" and ln:find("raw: the mod's hook did not run in a call from Lua", 1, true) and ln:find("swing the knife", 1, true),
        "the hook did not run: SKIP with the reason and what to do: " .. tostring(ln))
    -- no way to ask the game
    local st7, l7 = dur_world({ game = 95, actor = 95, screen = 95, no_call = true })
    check(st7 == "SKIP" and l7:find("DurabilityCheck", 1, true), "DurabilityCheck missing: SKIP with the reason: " .. tostring(l7))
    -- nothing equipped
    local st8, l8 = dur_world({ game = 95, actor = 95, screen = 95, no_actor = true })
    check(st8 == "SKIP" and l8:find("no equipped item actor", 1, true), "nothing equipped: SKIP: " .. tostring(l8))
    -- the whole run: the 19 steps of before plus this one pass
    local W9 = new_world({ dur = { game = 95, actor = 95, screen = 95 } })
    W9.cmd("1")
    check(finish(W9), "the run ends (equipment present)")
    local p9, f9, k9 = counts(done_of(W9.client)[1])
    check(p9 == 21 and f9 == 0 and k9 == 2, string.format("21 pass, 2 skip with the equipment (got %s/%s/%s)", tostring(p9), tostring(f9), tostring(k9)))
    check(W9.client.pawn.props.BP_JigHelperComp.props.x == nil, "nothing was written to the helper component")
    check(W9.client.pawn.props.BP_JigHelperComp.methods.GetEquipmentUID == nil
        and W9.client.pawn.props.BP_JigMultiplayer.methods.GetDurability == nil,
        "the fake game has no GetEquipmentUID / GetDurability for Lua to call: the step does not need them")
end

do
    say("14. C.markers: the client's own BP_QuestMarker / BP_Marker, placed the way the mod places a host's (MarkerData)")
    local function marker_world(o)
        local W = new_world({ markers = o })
        W.cmd("1")
        check(finish(W), "the run ends")
        return W, status_of(W.client, "C.markers")
    end
    local W1, st1, l1 = nil, nil, nil
    W1 = new_world({})
    W1.cmd("1"); check(finish(W1), "the run ends")
    st1, l1 = status_of(W1.client, "C.markers")
    check(st1 == "PASS" and l1:find("BP_QuestMarker: title 'SDC selftest', radius 1234, map widget built", 1, true)
        and l1:find("BP_Marker: title 'SDC selftest event', map widget built", 1, true), "both markers hold their data and built their widget: PASS: " .. tostring(l1))
    check(W1.markers_dropped == 1, "the quest marker is taken away again")
    check(W1.client.objects["/Game/Map.Map:PersistentLevel.BP_Marker_C_1"].dead == true, "the event marker is destroyed again")
    local _, st2, l2 = marker_world({ quest_widget = false })
    check(st2 == "FAIL" and l2:find("map widget NOT built", 1, true), "the quest marker's widget is not built: FAIL: " .. tostring(l2))
    local _, st3, l3 = marker_world({ event_widget = false })
    check(st3 == "FAIL" and l3:find("BP_Marker: title 'SDC selftest event', map widget NOT built", 1, true), "the event marker's widget is not built: FAIL")
    local _, st4, l4 = marker_world({ quest_title = "wrong" })
    check(st4 == "FAIL" and l4:find("title 'wrong'", 1, true), "the data did not stick (old layout: the title is not the one set): FAIL: " .. tostring(l4))
    local _, st5, l5 = marker_world({ quest = false })
    check(st5 == "FAIL" and l5:find("gone", 1, true), "no quest marker placed: FAIL: " .. tostring(l5))
end

print = real_print
io.write(string.format("mock_selftest: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
