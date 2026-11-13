-- SDCoop: the host's list of puzzle / power objects (sdc_world, PW section)
-- follows the game's level.
--
-- sdc_world's PW keeps one shared state of the power / laboratory / bunker
-- puzzle (generators, levers, circuit boxes, switches, lights, laboratory
-- sliding / secure / entrance doors, bunker doors, bunker scanners, sirens,
-- radios). None of these actors replicates and the game saves none of them.
-- The host lists them (FindAllOf, one class per tick, 5 s after the world
-- starts), sends every change to the clients (WPWS), gives a joiner what
-- differs from the level's start, writes that next to the slot at each save
-- and applies it again at the next load. A bunker door is a timeline that
-- turns its two meshes (BP_DoubleBunkerDoor / BP_LargeBunkerEntrance(_Small)
-- CallInteractOnObject: its sound, then Open? -> Reverse, else Play; their
-- collision turns with them). The scanner that opens it runs on the host only
-- (a client's press: OnRequestServerInteract -> the host's
-- OnServerExecuteInteract -> MC_CallInteract, a multicast of an actor that
-- does not replicate -> FindKeycard -> ListeningActor.CallInteractOnObject on
-- the HOST's doors), so a client's copy of the door opens only through that
-- list.
--
-- The game's world is no map of its own: the persistent level holds the main
-- menu, and Continue / Load / New Game streams the map (LongdownValley) into
-- it (PersistentLevel.Event_LoadLevel: UnloadStreamLevel + LoadStreamLevel,
-- work\re\pseudo\PersistentLevel.txt); a load during the session streams it
-- out and in again. None of that is a new map (no LoadMap, no world reset).
-- Up to 0.11.0 the host listed the objects 5 s after it became host, in the
-- main menu of "open my world to friends" (log 2026-11-13: 22:16:16 "0 puzzle
-- / power object(s) tracked", the map in at 22:16:59; the same in most logs
-- since 2026-11-11). The list stayed empty all session: nothing was sent (a
-- client's scanner use at 23:38:51 opened the bunker on the host only, the
-- client bumped into its own closed copy and got in only by the host's pull),
-- the join snapshot had puzzle=0 and each save wrote "0 states" over the
-- slot's file.
-- Here (host; sdc_world calls in from PW.host_tick, the list's build,
-- PW.restore, PW.save and its hook list):
--   * no list while this player is in the main menu (no character of its
--     own): it is made 5 s after the player is in the world. The host's REAL
--     main menu (S.real_menu_at: the menu's MenuWidget on screen, never the
--     death screen) drops a list made before: that world's level streamed out
--     (a New Game after it calls no load: nothing else would make the list
--     again). The host's death keeps it (the same world, joiners need it);
--   * the game's own load (EMS AsyncLoadActors on the host's controller:
--     every Continue / Load, also during the session) makes the list and the
--     restore from the loaded slot's file again; with clients connected, the
--     first pass after the new list sends them every state (their copies may
--     still hold the old world's);
--   * the level's start state of each object (what a joiner and the save are
--     compared with) is the first one seen in this game run, kept per path:
--     the level's placed actors start the same at every load, and a list made
--     again on top of applied states (a late load call, a level the engine
--     did not load anew) would otherwise take those for the start - left out
--     of the next save and of a joiner's states;
--   * the restore sets every listed object to the slot file's state, else to
--     the level's start (a level not loaded anew keeps the old world's
--     states), quietly: the game's notes of a restored generator / door stay
--     off the screen, a bunker door turns by its timeline (no door sound), a
--     circuit box's levers chain runs at once (cbox_now);
--   * sirens are neither saved nor restored (their kind's no_save): a siren
--     plays by itself (its random timer, 138 s, BP_Siren @101-135), and an
--     ActivateSiren at a load has no end (@1640): it howled, with AI noise,
--     until a player stopped it. The live sync of sirens stays;
--   * an empty list in the world is looked at again (one tracked class every
--     PROBE_S): a level object of a tracked class there -> listed again (the
--     same world: the sirens' press notes stay);
--   * a save while the list is empty, or while none of its objects is in the
--     world (the level streamed out), writes nothing: the slot's file keeps
--     its states.

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = {
    -- native static, pre (Context, WorldContextObject, ...): BP_PlayerController
    -- @806, after LoadGameFromSlot (only a load from a save calls it)
    LOAD_FN = "/Script/EasyMultiSave.EMSAsyncLoadGame:AsyncLoadActors",
    PROBE_S = 10,   -- s between two looks for objects while the list is empty
    stats = { loads = 0, relists = 0, menus = 0, probes = 0, full_sends = 0, saves_kept = 0, to_start = 0 },
}

local st = {
    full = false,      -- the next list is made after the game's load: all states to the clients
    probe_at = 0,      -- clock of the next look (empty list)
    probe_i = 0,       -- PW.FIND index of the last look
    menu_said = false,
}

-- [path] = the object's state at the level's start, the first one seen in
-- this game run (level constants: never reset)
local start = {}
M.start = start

local function in_menu(S) return S ~= nil and S.in_menu == true end

local function clients(S)
    local r = S and S.remote_pcs
    return type(r) == "table" and #r or 0
end

-- The list, what was sent and the restore start over (PW.reset). A "world:"
-- reason (another level: the game's load, the main menu) forgets the sirens'
-- press notes too: the next level's sirens are new actors.
local function relist(PW, why)
    PW.reset(why)
    st.probe_at, st.menu_said = 0, false
    M.stats.relists = M.stats.relists + 1
end

-- sdc_world PW.host_tick, first thing. true: nothing more of it this tick.
function M.host_tick(PW, now, S)
    if S and S.real_menu_at ~= nil and (PW.objs ~= nil or PW.todo ~= nil) then
        M.stats.menus = M.stats.menus + 1
        relist(PW, "world:the host's main menu")
        log.info("world: the host is in its main menu (its world's level streamed out): puzzle / power list dropped; the next world gets its own")
        return true
    end
    if not PW.objs then
        if PW.todo == nil and in_menu(S) then
            PW.world_at = nil   -- (its 5 s count starts in the world)
            if not st.menu_said then
                st.menu_said = true
                log.debug("world: puzzle / power objects are listed once this player is in the world (main menu now)")
            end
            return true
        end
        return false
    end
    if st.full then
        st.full = false
        local n = clients(S)
        if n > 0 then
            PW.sent = {}
            PW.mark_dirty()
            M.stats.full_sends = M.stats.full_sends + 1
            log.info("world: the game loaded a save with %d player(s) connected: every puzzle / power state goes to them again", n)
        end
    end
    if #PW.objs == 0 and not in_menu(S) and now >= st.probe_at then
        st.probe_at = now + M.PROBE_S
        st.probe_i = st.probe_i % #PW.FIND + 1
        for _, a in ipairs(ue.find_all(PW.FIND[st.probe_i])) do
            if ue.valid(a) and not ue.is_runtime_spawned(a) and PW.kind_of(a) then
                M.stats.probes = M.stats.probes + 1
                log.info("world: %s is in the world now and the puzzle / power list was empty: listed again", ue.short(a))
                relist(PW, "puzzle objects appeared")
                return true
            end
        end
    end
    return false
end

-- sdc_world, the list's build: the level's start state of an object listed
-- now (the first one seen in this game run).
function M.start_of(p, s)
    if start[p] == nil and s ~= nil then start[p] = s end
    return start[p]
end

-- EMSAsyncLoadGame.AsyncLoadActors (native static, pre): the game loads a save
-- into the level it has just streamed in. Host, its own controller only.
function M.on_load(PW, S, wco_p)
    if not S or S.role ~= "host" then return end
    local pc
    if wco_p ~= nil then
        local ok, v = pcall(function() return wco_p:get() end)
        if ok then pc = v end
    end
    if ue.valid(pc) then
        local okl, isl = pcall(function() return pc:IsLocalController() end)
        if okl and isl == false then return end
    end
    local had = PW.objs and #PW.objs
    M.stats.loads = M.stats.loads + 1
    relist(PW, "world:the game loaded a save")
    st.full = true
    log.info("world: the game loads a save: puzzle / power objects listed again 5 s after this player is in the world (%s before), then the slot's states",
        had and (tostring(had) .. " listed") or "none listed")
end

-- A circuit box restored to "2" by its own steps (Event_Door: its door, then
-- TL_Levers.Play, @3982 / @3028): the levers' end runs the box's chain
-- (TL_Levers__FinishedFunc -> @3918: its Doors unlocked, its LightSwitches'
-- Event_LightSwitch - a toggle, @3192 -, CanInteract? off, its door closed
-- again). Left to the timeline, that chain came a second after the restore
-- had set those switches from the file and switched them back (the save's
-- light off on every machine, the next save "off", the next load "on"...).
-- So the levers go to their end now and the chain runs now, inside the
-- restore, before the switches and doors (later in the chain's order) get
-- the file's states. Its panel's opening (`Timeline`, 0 -> 120, the first
-- Event_Door @3982 -> @381) goes to its end too: the chain closes the panel
-- again (TL_DoorReverse, @3944) in the same frame, and two 1 s timelines on
-- the same Door turned it against each other (the panel could stay open).
-- (Damage_Object - DamageToActivate? - runs its chain at once: nothing to do.)
local function to_end(PW, c, name)
    local tl = ue.prop(c, name)
    if not ue.valid(tl) then return end
    local len = tonumber(ue.try(function() return tl:GetTimelineLength() end)) or 0
    -- (its update runs: the mesh at the end; a failure here never skips the Stop / the chain)
    pcall(function() tl:SetNewTime(len) end)
    PW.tl(c, name, "Stop")   -- (no finished event of its own any more)
end

local function cbox_now(PW, c)
    if PW.tl_play(c, "TL_Levers") ~= "f" then return end
    to_end(PW, c, "Timeline")    -- the panel open
    to_end(PW, c, "TL_Levers")   -- the levers down
    if not PW.call(c, "TL_Levers__FinishedFunc") then
        log.warn("world: restore %s: its levers' chain (TL_Levers__FinishedFunc) did not run", ue.short(c))
    end
end

-- One object to `want` while restoring: the game's notes it raises stay off
-- the screen (sdc_notes); a bunker door by its timeline alone (its
-- CallInteractOnObject plays the door sound first, @642-689); a circuit box
-- with its levers' chain at once (cbox_now).
local function restore_one(PW, e, o, want)
    local set = PW.K[e.k].set
    if e.k == "bunker" then
        set = function(d, w) PW.tl(d, "DoorTimeline", w == "o" and "Play" or "Reverse") end
    elseif e.k == "cbox" then
        set = function(c, w, pawn)
            PW.K.cbox.set(c, w, pawn)
            if w == "2" then cbox_now(PW, c) end
        end
    end
    local notes = PW.notes()
    if notes and notes.quietly then
        return notes.quietly("restoring the save's " .. ue.short(o), set, o, want, nil)
    end
    return pcall(set, o, want, nil)
end

-- sdc_world PW.restore (once per list, after the start states were read):
-- every listed object, in the chain's order, to the slot file's state, else
-- to the level's start.
function M.restore(PW, unpack_path, stats)
    PW.restored = true
    local slot = ue.ems_current_slot()
    local f = PW.file_of(slot)
    local saved, lines, miss = {}, 0, 0
    local h = f and io.open(f, "rb")
    if h then
        local data = h:read("a")
        h:close()
        for line in tostring(data):gmatch("[^\r\n]+") do
            local pk, s = line:match("^([^#=][^=]*)=(.+)$")
            if pk then
                lines = lines + 1
                local p = unpack_path(pk)
                if PW.idx[p] then saved[p] = s else miss = miss + 1 end
            end
        end
    end
    local n, back = 0, 0
    for _, e in ipairs(PW.objs) do
        -- (a kind that is not saved - sirens - is left alone, an old file's line too)
        local want = not PW.K[e.k].no_save and (saved[e.p] or start[e.p]) or nil
        local o = want and PW.obj(e)
        if o and PW.state_of(e) ~= want then
            local ok, err = restore_one(PW, e, o, want)
            if ok then
                n = n + 1
                if not saved[e.p] then back = back + 1 end
            else
                log.warn("world: restore %s: %s", ue.short(o), tostring(err))
            end
        end
    end
    stats.pw_restored = n
    M.stats.to_start = M.stats.to_start + back
    log.info("world: %d puzzle / power state(s) restored from the save of slot %s (%d in the file, %d unknown here; %d back to the level's start)",
        n, tostring(slot), lines, miss, back)
    PW.mark_dirty()
end

-- sdc_world PW.save, before it writes: false keeps the slot's file as it is.
function M.may_save(PW)
    local why
    if #PW.objs == 0 then
        why = "no puzzle / power object is listed in this world"
    else
        local here = false
        for _, e in ipairs(PW.objs) do
            if PW.obj(e) then here = true break end
        end
        if not here then why = "none of the listed puzzle / power objects is in the world (its level is not loaded)" end
    end
    if not why then return true end
    M.stats.saves_kept = M.stats.saves_kept + 1
    log.warn("world: puzzle / power states not saved: %s; the slot's file keeps the states it has", why)
    return false
end

-- (sdc_world's status line)
function M.status_line()
    local s = M.stats
    local known = 0
    for _ in pairs(start) do known = known + 1 end
    return string.format("puzzlelist: game loads=%d lists again=%d (main menu %d, objects appeared %d) all states after a load=%d "
        .. "back to the start at restores=%d saves kept=%d start states known=%d",
        s.loads, s.relists, s.menus, s.probes, s.full_sends, s.to_start, s.saves_kept, known)
end

return M
