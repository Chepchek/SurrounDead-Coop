-- SDCoop diagnostics: "[SNAP]" state lines for reading logs after a session.
--
-- While in co-op (host or client), every `diag_snapshots` seconds:
--   [SNAP] head   version, role, map, menu state, connected players, uptime
--   [SNAP] own    own character: alive, health, position, movement mode, held
--                 item, input ignored (move/look), camera view target, HUD on
--                 screen, ping (a client's health: its HUD's, "hp=80(hud)":
--                 the character's own MedicalComponent is not replicated)
--   [SNAP] remote (host) every connected player: their character as above,
--                 distance to the host, ping, waiting respawn
--   [SNAP] other  (client) every other player character here: distance, hidden
--   [SNAP] ai     AI characters: total, dead, local-authority copies, the
--                 classes within 50 m of the own character
-- and right away, checked every second, when the own character, its death
-- state, HUD, input or camera target change ("[SNAP] change ..."), so a lost
-- HUD / control / character shows up with its time.
-- [HITCH] (the 1 s tick came > 3 s late: the game stood still) also names the
-- longest mod work since the previous tick (task + part, or hook call, with
-- how much of it was writing UE4SS.log; on a client the slowest zombie step
-- of sdc_ai's client tick in that task, "AI step c:ai.looks N ms"), the
-- slowest UE4SS.log write (sdc_log)
-- and the Lua heap before / after with the collector cycles in between.
-- Log only; nothing in the game is changed.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")

local M = { stats = { snaps = 0, changes = 0 } }

local st = { version = "?", started = os.time(), last_snap = 0, own_key = nil, last_tick = nil }

local function interval()
    local v = tonumber(cfg.get("diag_snapshots"))
    if v == nil then return 30 end
    return v
end

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function n0(v)
    if type(v) ~= "number" then return "?" end
    return string.format("%.0f", v)
end

local function loc_str(l)
    if not l then return "?" end
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

local function dist(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function ping_of(pc)
    local ps = ue.prop(pc, "PlayerState")
    if not ue.valid(ps) then return nil end
    local v = try(function() return ps:GetPingInMilliseconds() end)
    if type(v) == "number" then return v end
    return tonumber(ue.prop(ps, "ExactPing"))
end

local function is_dead(pawn)
    return ue.valid(pawn) and ue.prop(pawn, "PlayerDead?") == true
end

-- The held slot: the Jig helper's replicated ActiveWeapon slot tag (as
-- sdc_items' hotbar reads it; BP_PlayerCharacter has no ActiveWeapon of its
-- own), "Jig.PlayerSlot." left out; "-" for none.
local function held_slot(pawn)
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    if not ue.valid(helper) then return "-" end
    local tag = ue.str(try(function() return helper.ActiveWeapon.TagName end))
    if tag == "" or tag == "None" then return "-" end
    return (tag:gsub("^Jig%.PlayerSlot%.", ""))
end

-- Health as "hp=..." of a player character. The host's values are the
-- game's own (MedicalComponent.Health / MaxHealth). MedicalComponent does not
-- replicate (sdc_infui): a client's character keeps 100/100 there whatever
-- its health on the host (13.11: every client line said hp=100/100 while the
-- host had that player at 80 / 96). A client's own health is what the host
-- sends to its HUD (Client_UpdateHealthUI -> BP_Ingame.UpdateHealth ->
-- HealthBar.PB_SetPercent(Health / 100); HealthBar's ProgressMethod 0 sets
-- CurrentPercent, clamped 0..1): "hp=80(hud)"; no HUD value: "hp=?(client)".
local function hp_text(pawn, client_own)
    if client_own then
        local bar = ue.prop(ue.prop(pawn, "InGameUI"), "HealthBar")
        local p = tonumber(ue.prop(bar, "CurrentPercent"))
        if p then return "hp=" .. n0(p * 100) .. "(hud)" end
        return "hp=?(client)"
    end
    local med = ue.prop(pawn, "MedicalComponent")
    return string.format("hp=%s/%s", n0(tonumber(ue.prop(med, "Health"))), n0(tonumber(ue.prop(med, "MaxHealth"))))
end
M._hp_text = hp_text   -- tests

-- alive, health, position, movement mode, held item of a player character
-- (`client_own`: this client's own character, health from its HUD)
local function pawn_info(pawn, client_own)
    if not ue.valid(pawn) then return "pawn=none" end
    local cm = ue.prop(pawn, "CharacterMovement")
    return string.format("pawn=%s dead=%s %s loc=%s move=%s held=%s",
        ue.short(pawn), tostring(is_dead(pawn)), hp_text(pawn, client_own),
        loc_str(ue.location(pawn)), tostring(ue.prop(cm, "MovementMode")), held_slot(pawn))
end

-- The own player: character, input, camera, HUD, ping. Returns the line, the
-- change key and the character.
local function own_state(on_client)
    local pc = ue.local_pc()
    local pawn = pc and ue.pawn_of(pc) or nil
    local parts = { pawn_info(pawn, on_client) }
    local mi, li, view, hud = nil, nil, "?", "none"
    if pc then
        mi = try(function() return pc:IsMoveInputIgnored() end)
        li = try(function() return pc:IsLookInputIgnored() end)
        local vt = try(function() return pc:GetViewTarget() end)
        if ue.valid(vt) then
            view = (pawn and ue.name(vt) == ue.name(pawn)) and "own" or ue.short(vt)
        end
        parts[#parts + 1] = string.format("input_ignored=%s/%s view=%s ping=%s",
            tostring(mi), tostring(li), view, n0(ping_of(pc)))
    else
        parts[#parts + 1] = "pc=none"
    end
    if ue.valid(pawn) then
        local ui = ue.prop(pawn, "InGameUI")
        if ue.valid(ui) then hud = tostring(try(function() return ui:IsInViewport() end)) end
    end
    parts[#parts + 1] = "hud=" .. hud
    local key = table.concat({ pawn and ue.name(pawn) or "-", tostring(is_dead(pawn)), hud,
        tostring(mi), tostring(li), view }, "|")
    return table.concat(parts, " "), key, pawn
end

-- Smart AI (bandits, soldiers, traders) and the game's enemies (zombies,
-- hounds, bosses: BP_MainEnemy_C); a name is counted once.
local AI_CLASSES = { "BP_MasterAICharacter_C", "BP_MainEnemy_C" }

-- Cheap on purpose (a pass over every AI with names, flags and locations
-- held a client for ~470 ms): objects are told apart by address, and only
-- the first AI_DETAIL of them get the role / dead / distance reads; the rest
-- are only counted. The line says how many were looked at.
local AI_DETAIL = 48
local function o_addr(o) return o:GetAddress() end

local function ai_line(center, on_client)
    local total, dead, localauth, near, checked = 0, 0, 0, {}, 0
    local seen, list_local = {}, {}
    for _, cls in ipairs(AI_CLASSES) do
        for _, a in ipairs(ue.find_all(cls)) do
            local okk, key = pcall(o_addr, a)
            if not (okk and type(key) == "number" and key ~= 0) then key = ue.valid(a) and ue.name(a) or nil end
            if key and not seen[key] then
                seen[key] = true
                total = total + 1
                if checked < AI_DETAIL and ue.valid(a) then
                    checked = checked + 1
                    if ue.prop(a, "IsDead?") == true or ue.prop(a, "Dead") == true then dead = dead + 1 end
                    -- on a client every AI should be a copy of the host's (role 1)
                    if ue.role(a) == ue.ROLE_AUTHORITY then
                        localauth = localauth + 1
                        if on_client and #list_local < 5 then list_local[#list_local + 1] = ue.short(a) end
                    end
                    local d = dist(center, ue.location(a))
                    if d and d < 5000 then
                        local c = ue.class_name(a) or "?"
                        near[c] = (near[c] or 0) + 1
                    end
                end
            end
        end
    end
    local list = {}
    for c, n in pairs(near) do list[#list + 1] = c .. "=" .. n end
    table.sort(list)
    return string.format("total=%d (looked at %d) dead=%d local_authority=%d%s near50m: %s", total, checked, dead,
        localauth, #list_local > 0 and (" [" .. table.concat(list_local, " ") .. "]") or "",
        #list > 0 and table.concat(list, ", ") or "-")
end

local function snapshot(S, own_line, own_pawn)
    M.stats.snaps = M.stats.snaps + 1
    local nrem = 0
    for _ in pairs(S.remote or {}) do nrem = nrem + 1 end
    log.info("[SNAP] head v=%s role=%s map=%s in_menu=%s remotes=%d uptime=%ds", st.version, tostring(S.role),
        tostring(S.map), tostring(S.in_menu), nrem, os.time() - st.started)
    log.info("[SNAP] own %s", own_line)
    local center = ue.valid(own_pawn) and ue.location(own_pawn) or nil
    if S.role == "host" then
        for _, r in pairs(S.remote or {}) do
            local pawn = ue.valid(r.pc) and ue.pawn_of(r.pc) or nil
            local d = pawn and dist(center, ue.location(pawn))
            log.info("[SNAP] remote %s %s dist=%s ping=%s dead_flag=%s respawn_wait=%s", tostring(r.name),
                pawn_info(pawn), d and string.format("%.0fm", d / 100) or "?", n0(ping_of(r.pc)),
                tostring(r.dead), r.respawn_wait and tostring(r.respawn_wait.mode) or "-")
        end
    else
        for _, p in ipairs(ue.find_all("BP_PlayerCharacter_C")) do
            if ue.valid(p) and not (own_pawn and ue.name(p) == ue.name(own_pawn)) then
                local d = dist(center, ue.location(p))
                log.info("[SNAP] other %s dead=%s hidden=%s role=%s dist=%s", ue.short(p), tostring(is_dead(p)),
                    tostring(ue.prop(p, "bHidden")), tostring(ue.role(p)),
                    d and string.format("%.0fm", d / 100) or "?")
            end
        end
    end
    -- the AI line every 4th snapshot (every 2 min with diag_snapshots = 30)
    st.ai_n = (st.ai_n or 0) + 1
    if st.ai_n % 4 == 1 then log.info("[SNAP] ai %s", ai_line(center, S.role == "client")) end
end

function M.init(version)
    st.version = version or "?"
end

local function perf_mod()
    local p = package.loaded["sdc_perf"]
    if type(p) == "table" then return p end
    return nil
end

local function ms_of(t)
    return type(t) == "table" and tonumber(t.ms) or 0
end

-- The longest piece of mod work since the previous tick: a task (with its
-- longest part) or a hook call; "none over 50 ms" when nothing took that long.
-- `ws`: the client's slowest AI step (sdc_ai.take_worst_step), named when it
-- ran in that task: the steps time themselves (sdc_ue's longest part is then
-- c:ai as a whole, or none at all in the task ai-client-rest).
local function longest_work(wt, wp, wh, ws)
    local best, ms = nil, 50
    if ms_of(wh) >= ms then
        ms = ms_of(wh)
        best = string.format("hook %s %.0f ms (writing UE4SS.log in it: %.0f ms)", tostring(wh.name), ms,
            tonumber(wh.log_ms) or 0)
    end
    if ms_of(wt) >= ms then
        ms = ms_of(wt)
        best = string.format("task '%s' %.0f ms", tostring(wt.label), ms)
        if ms_of(wp) >= 50 and wp.task == wt.label then
            best = best .. string.format(" (part %s %.0f ms)", tostring(wp.label), ms_of(wp))
        end
        if ms_of(ws) >= 50 and ws.task == wt.label then
            best = best .. string.format(" (AI step %s %.0f ms)", tostring(ws.label), ms_of(ws))
        end
    end
    return best or "none over 50 ms"
end

-- [HITCH] details: what the mod was doing, the slowest UE4SS.log write, the
-- Lua heap before (previous tick) and now, collector cycles in between.
local function hitch_details(c, w, wt, wp, wh, ws)
    local perf = perf_mod()
    local now_cycles = tonumber(perf and perf.gc_cycles)
    local cycles = now_cycles and st.last_cycles and (now_cycles - st.last_cycles) or -1
    local write = "none"
    if ms_of(w) > 0 then
        write = string.format("%.0f ms, %d line(s), %.1f s ago, during %s: '%s'", ms_of(w), tonumber(w.lines) or 0,
            tonumber(w.at) and (c - w.at) or -1, tostring(w.activity or "?"), tostring(w.text or ""))
    end
    return string.format("longest mod work: %s | slowest UE4SS.log write: %s | lua heap %.1f MB before, %.1f MB now,"
        .. " collector cycles finished: %d", longest_work(wt, wp, wh, ws), write, (st.last_kb or 0) / 1024,
        collectgarbage("count") / 1024, cycles)
end

-- Every second from main.lua with the session state.
function M.tick(S)
    -- [HITCH]: this 1 s task came much later than due: the game (or its
    -- game thread) stood still that long; name the mod task that ran last,
    -- the longest mod work and the slowest log write since the previous tick
    -- (taken every tick, so they cover the stall and the second before it)
    local c = os.clock()
    local w = log.take_worst_write and log.take_worst_write() or nil
    local wt, wp
    if ue.take_worst then wt, wp = ue.take_worst() end
    local perf = perf_mod()
    local wh = perf and perf.take_worst_hook and perf.take_worst_hook() or nil
    local ai = package.loaded["sdc_ai"]
    local ws = type(ai) == "table" and type(ai.take_worst_step) == "function" and ai.take_worst_step() or nil
    if st.last_tick and c - st.last_tick > 3 and S and (S.role == "host" or S.role == "client") and S.in_menu == false then
        local lt = ue.last_done or ue.last_task or {}
        log.warn("[HITCH] the game stood still for %.1f s (last mod task before this one: %s, took %s ms, ended %.1f s ago) | %s",
            c - st.last_tick - 1, tostring(lt.label), lt.ms and string.format("%.0f", lt.ms) or "?",
            lt.at and (c - lt.at) or -1, hitch_details(c, w, wt, wp, wh, ws))
    end
    st.last_tick = c
    st.last_kb = collectgarbage("count")
    st.last_cycles = tonumber(perf and perf.gc_cycles)
    -- one timed collector step a second, mid-cycle only ([PERF] "step max")
    if perf and type(perf.gc_step_sample) == "function" then pcall(perf.gc_step_sample) end
    local every = interval()
    if every <= 0 or not S or (S.role ~= "host" and S.role ~= "client") then
        st.own_key = nil
        return
    end
    local line, key, pawn = own_state(S.role == "client")
    if st.own_key ~= nil and key ~= st.own_key then
        M.stats.changes = M.stats.changes + 1
        log.info("[SNAP] change own %s (in_menu=%s)", line, tostring(S.in_menu))
    end
    st.own_key = key
    local now = os.time()
    if now - st.last_snap >= every then
        st.last_snap = now
        snapshot(S, line, pawn)
    end
end

function M.status_line()
    return string.format("diag: snaps=%d changes=%d every=%ss", M.stats.snaps, M.stats.changes, tostring(interval()))
end

return M
