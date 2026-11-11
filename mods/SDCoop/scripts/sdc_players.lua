-- SDCoop: players' characters — spawn, death, respawn, HUD.
--
-- Built on the game's own flow (see docs\PLAN_v0.4.md):
--   * spawn  = what SD_GameInstance.Survival_Respawn does (deferred spawn of
--     BP_PlayerCharacter, SpawnStartingItems?, Possess), but possessed by the
--     right controller. Possess fires the character's ReceivePossessed on the
--     host, which sends the game's own Client_AddUI to the client (HUD).
--   * death  = the game's own server flow; with sdc_ctx its "player 0" calls
--     (UnPossess, Client_Died...) reach the dying player, not the host.
--   * death screen = the game's RespawnScreen. Its respawn buttons call the
--     game's own Svr_RequestRespawn_* RPCs; sdc_respawn makes the host run
--     them for the calling player (config respawn_native). Without that the
--     buttons would run Survival_Respawn through the host's player 0 (the
--     host would take the new body), so they are swapped for identical-looking
--     buttons that ask the host for the mod's own respawn (RESPAWN).
--   * things the game only does through player 0 on the host (minimap, input
--     mode, level/XP refresh) are done on the client itself; the minimap the
--     host's ReceivePossessed builds for a remote character on the HOST's
--     screen is taken off it in the same frame (install_host_hooks).
--   * "unstuck": a client moves its character next to the host (UNSTUCK).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local W = require("sdc_widgets")

local M = {}

local PLAYER_CLASS = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local IMC_PATH = "/Game/Input/IMC_General.IMC_General"
local SPAWN_COLLISION = 2   -- AdjustIfPossibleButAlwaysSpawn, as the game does
local SPAWN_SCALE = 1       -- MultiplyWithRoot

local S          -- session state (sdc_session.state)
local api        -- { remote_record = fn(pc) }

function M.init(state, session_api)
    S, api = state, session_api
end

local function dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function is_dead(pawn)
    return ue.valid(pawn) and ue.prop(pawn, "PlayerDead?") == true
end

-- ===========================================================================
-- Host: spawning a character for a remote player
-- ===========================================================================

local function yaw_transform(loc, yaw)
    local h = math.rad(yaw or 0) / 2
    return {
        Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
end

local function has_tag(actor, tag)
    local found = false
    pcall(function()
        actor.Tags:ForEach(function(_, e)
            if ue.str(e:get()) == tag then found = true end
        end)
    end)
    return found
end

-- The game's random respawn: a PlayerStart tagged 'Survival'.
local function random_spot()
    local list = {}
    for _, ps in ipairs(ue.find_all("PlayerStart")) do
        if has_tag(ps, "Survival") then list[#list + 1] = ps end
    end
    if #list == 0 then return nil end
    local ps = list[math.random(#list)]
    local loc, rot = ue.location(ps), ue.rotation(ps)
    if not loc then return nil end
    return loc, rot and rot.Yaw or 0
end

local function near_host_spot(index, attempt)
    local host_pawn = ue.local_pawn()
    if not host_pawn then return nil end
    local loc, rot = ue.location(host_pawn), ue.rotation(host_pawn)
    if not loc then return nil end
    local ang = math.rad(((index or 1) * 72) % 360)
    return { X = loc.X + math.cos(ang) * 160, Y = loc.Y + math.sin(ang) * 160, Z = loc.Z + 80 + (attempt or 0) * 150 },
        rot and rot.Yaw or 0
end

-- For sdc_respawn.
M.helpers = { yaw_transform = yaw_transform, random_spot = random_spot,
              near_host_spot = near_host_spot, is_dead = is_dead, has_tag = has_tag }

-- Host: the session record of a remote controller (nil if unknown).
function M.record_for(pc)
    if not S or not ue.valid(pc) then return nil end
    return S.remote[ue.name(pc)]
end

-- Client: may the death screen use the game's own respawn buttons? Set by
-- sdc_respawn (config respawn_native and the host said it supports them).
M.native_respawn_ok = function() return false end

-- sdc_charcreate: a player's own look (M.before_finish_spawn puts it into
-- the host's Save_Player for the construction script's SetSexMesh and
-- returns the function that restores the host's values) and the hold of a
-- player's first character while they create it (M.join_gate).
M.before_finish_spawn = nil
M.join_gate = nil

-- sdc_persist: a returning player's saved character. persist_gate(r, now)
-- holds the first character until the player's id came (false = wait);
-- join_point(r) -> { loc = {X,Y,Z}, yaw } where the saved character was (or
-- nil); starting_items(r) -> false when the saved inventory replaces the
-- starting kit. PERSIST_HOOKS tells sdc_persist these are read here.
M.persist_gate = nil
M.join_point = nil
M.starting_items = nil
M.PERSIST_HOOKS = 1

local function spawn_character(loc, yaw, r)
    local cls = ue.find_object(PLAYER_CLASS)
    local gs = ue.gameplay_statics()
    local wc = ue.local_pawn() or ue.local_pc()
    if not cls or not gs or not wc then return nil, "class/statics/world missing" end
    local tf = yaw_transform(loc, yaw)
    local ok, actor = pcall(function()
        return gs:BeginDeferredActorSpawnFromClass(wc, cls, tf, SPAWN_COLLISION, nil, SPAWN_SCALE)
    end)
    if ok and ue.valid(actor) then
        -- as Survival_Respawn: a fresh character gets the starting kit (not
        -- one whose saved inventory comes back, sdc_persist); the starting
        -- quests are the host's story, not shown for remote players
        local kit = true
        if M.starting_items then
            local okk, v = pcall(M.starting_items, r)
            if okk and v == false then kit = false end
        end
        ue.set_prop(actor, "SpawnStartingItems?", kit)
        ue.set_prop(actor, "ShowStartingQuests?", false)
        local restore = nil
        if M.before_finish_spawn then
            local okb, res = pcall(M.before_finish_spawn, actor, r)
            if okb then restore = res else log.err("host: own look for %s: %s", r and r.name or "?", tostring(res)) end
        end
        local okf, done = pcall(function() return gs:FinishSpawningActor(actor, tf, SPAWN_SCALE) end)
        if type(restore) == "function" then
            local okr, errr = pcall(restore)
            if not okr then log.err("host: restoring the host's look data: %s", tostring(errr)) end
        end
        if okf and ue.valid(done) then return done end
        if ue.valid(actor) then return actor end
        return nil, "FinishSpawningActor failed"
    end
    -- fallback: plain spawn (no starting kit)
    local world = ue.try(function() return wc:GetWorld() end)
    local a2 = ue.try(function() return world:SpawnActor(cls, loc, { Pitch = 0, Yaw = yaw or 0, Roll = 0 }) end)
    if ue.valid(a2) then
        log.warn("host: deferred spawn failed (%s), used SpawnActor", tostring(actor))
        return a2
    end
    return nil, tostring(actor)
end

-- Host-side leftovers of the remote character's ReceivePossessed: the game
-- builds the minimap widget through player 0, i.e. onto the HOST's screen.
local function host_cleanup_remote_ui(pawn)
    local mm = ue.prop(pawn, "MinimapSystemComponent")
    local mw = ue.prop(mm, "MapWidget")
    if ue.valid(mw) then
        local ok, inv = pcall(function() return mw:IsInViewport() end)
        if ok and inv then
            pcall(function() mw:RemoveFromParent() end)
            log.info("host: removed the minimap of %s from the host's screen", ue.short(pawn))
        end
    end
end

-- The same, in the frame it happens. BP_PlayerCharacter.ReceivePossessed
-- (server only) runs, one tick after possession (@81240 -> @9505),
-- MinimapSystemComponent.Event_ConstructMap -> BPC_MinimapSystem ubergraph
-- @698: WidgetBlueprintLibrary.Create(self, MapWidget_C, OwningPlayer None)
-- -> BP_MapData.Construct Minimap -> @124 MapWidget.AddToViewport(99). With no
-- owning player the widget goes to the first local player: the HOST's screen,
-- once per remote character. The ubergraph runs synchronously (the BP_MapData
-- retry delay only when the map data actor is missing), so a post-hook on
-- Event_ConstructMap removes it before it is ever drawn. The widget object
-- stays on the remote character's server-side component (markers that the
-- host's code adds to it go nowhere). The client builds its own map
-- (ensure_minimap).
local MINIMAP_FN = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C:Event_ConstructMap"
local host_hooks = { minimap = false, minimap_removed = 0 }

local function on_construct_map(comp_p)
    if not S or S.role ~= "host" then return end
    local comp = comp_p and comp_p:get()
    if not ue.valid(comp) then return end
    local owner = ue.try(function() return comp:GetOwner() end)
    if not ue.valid(owner) or not ue.class_name(owner):find("PlayerCharacter", 1, true) then return end
    local okl, is_local = pcall(function() return owner:IsLocallyControlled() end)
    if not okl or is_local == true then return end
    local mw = ue.prop(comp, "MapWidget")
    if not ue.valid(mw) then return end
    local okv, inv = pcall(function() return mw:IsInViewport() end)
    if not (okv and inv) then return end
    pcall(function() mw:RemoveFromParent() end)
    host_hooks.minimap_removed = host_hooks.minimap_removed + 1
    log.info("host: the minimap the game built for remote %s on the host's screen was taken off right away (%d so far)",
        ue.short(owner), host_hooks.minimap_removed)
end

-- Host hooks; safe to call every tick until they are in.
function M.install_host_hooks()
    if host_hooks.minimap or not ue.find_object(MINIMAP_FN) then return end
    -- Blueprint function: UE4SS takes one callback and runs it after the call
    local ok, err = pcall(RegisterHook, MINIMAP_FN, function(comp_p)
        local okc, e = pcall(on_construct_map, comp_p)
        if not okc then log.err_throttled("minimap-hook", "host: minimap hook: %s", tostring(e)) end
    end)
    host_hooks.minimap = ok
    log.info("host: Event_ConstructMap hook (post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

-- mode: "join" | "host" | "random" | "point" (point = { loc, yaw })
function M.spawn_for(r, mode, point)
    if r.spawn_pending then return end
    local hp = ue.local_pawn()
    if not hp or is_dead(hp) then
        if mode == "join" then
            log.debug("host: no host pawn yet, delaying spawn for %s", r.name)
            return
        end
        -- the host is dead (death screen / respawning): the request waits for
        -- the host's new character, host_player_tick carries it out
        local first = r.respawn_wait == nil
        r.respawn_wait = { mode = mode, point = point, at = os.time() }
        if first then
            log.info("host: %s respawns (%s) once the host is alive again", r.name, mode)
            if ue.valid(r.pc) then net.send_to(r.pc, "MSG", "respawn_wait_host") end
        end
        return
    end
    r.respawn_wait = nil
    local loc, yaw
    if mode == "random" then loc, yaw = random_spot() end
    if mode == "point" and point then loc, yaw = point.loc, point.yaw end
    -- a returning player: where the saved character was (sdc_persist)
    r.spawn_at_saved = nil
    if mode == "join" and M.join_point then
        local okj, pt = pcall(M.join_point, r)
        if okj and type(pt) == "table" and pt.loc then loc, yaw, r.spawn_at_saved = pt.loc, pt.yaw, true end
    end
    if not loc then loc, yaw = near_host_spot(r.index, 0) end
    if not loc then return end

    local actor, err = spawn_character(loc, yaw, r)
    if not ue.valid(actor) and (mode == "join" or mode == "host") then
        for attempt = 1, 2 do
            loc, yaw = near_host_spot(r.index, attempt)
            r.spawn_at_saved = nil
            actor, err = spawn_character(loc, yaw, r)
            if ue.valid(actor) then break end
        end
    end
    if not ue.valid(actor) then
        log.warn("host: spawn for %s failed: %s", r.name, tostring(err))
        r.pawnless_since = os.time()
        return
    end
    log.info("host: spawned %s for %s (%s)", ue.short(actor), r.name, mode)

    -- Possess in the same frame, as the game does. Bind first so the
    -- character's ReceivePossessed already sees its own player as "player 0".
    ctx.bind(actor, r.pc)
    local ok, perr = pcall(function() r.pc:Possess(actor) end)
    log.info("host: possess %s -> %s ok=%s%s", r.name, ue.short(actor), tostring(ok), ok and "" or (" err=" .. tostring(perr)))
    if not ok then
        pcall(function() actor:K2_DestroyActor() end)
        r.pawnless_since = os.time()
        return
    end
    M.after_spawn(r, actor, mode)
end

-- Bookkeeping and follow-ups of a remote player's new character, possessed
-- by the mod (spawn_for) or by the game's own Survival_Respawn (sdc_respawn).
function M.after_spawn(r, actor, mode)
    if r.spawned_key then S.spawned[r.spawned_key] = nil end
    r.spawned_key = ue.name(actor)
    S.spawned[r.spawned_key] = r.key
    ctx.bind(actor, r.pc)
    r.spawned_once = true
    r.dead = false
    r.pawnless_since = nil
    r.pawn = actor

    local host_pawn = ue.local_pawn()
    local at_saved = r.spawn_at_saved   -- sdc_persist checks a saved spot itself
    ue.delay("after-spawn", 1500, function()
        if not ue.valid(actor) then return end
        host_cleanup_remote_ui(actor)
        if ue.valid(r.pc) then net.send_to(r.pc, "SPAWNED", ue.name(actor)) end
    end)
    -- The starting kit can leave a weapon (the knife) in the hand on the host
    -- only: the client's own "holding / selected slot" state is set by its own
    -- input, so its hotbar showed nothing selected and the next key press put
    -- the weapon away instead. Start with empty hands on both sides.
    local function empty_hands()
        if not ue.valid(actor) then return end
        local helper = ue.prop(actor, "BP_JigHelperComp")
        local active = ue.str(ue.try(function() return helper.ActiveWeapon.TagName end))
        if active ~= "" and active ~= "None" then
            local ok, err = pcall(function() actor:ServerFuncChangeActiveSlot({ TagName = FName("None") }) end)
            log.info("host: %s spawned holding %s, put away (ok=%s%s)", r.name, active, tostring(ok),
                ok and "" or (" " .. tostring(err)))
        end
    end
    ue.delay("after-spawn", 3000, empty_hands)
    ue.delay("after-spawn", 8000, empty_hands)

    ue.delay("after-spawn", 4000, function()
        if not ue.valid(actor) then return end
        host_cleanup_remote_ui(actor)
        -- the spot can be over a slope edge; pull a falling character back
        if (mode == "join" or mode == "host") and ue.valid(host_pawn) and not at_saved then
            local hl, pl = ue.location(host_pawn), ue.location(actor)
            if hl and pl and pl.Z < hl.Z - 1000 then
                ue.teleport(actor, { X = hl.X + 120, Y = hl.Y, Z = hl.Z + 120 })
                log.info("host: %s fell after spawn, moved next to host", r.name)
            end
        end
    end)
end

-- Host saves. Easy Multi Save skips player-controlled pawns, but a remote
-- player's DEAD (unpossessed) body is saved as a world actor and its
-- ActorPreSave writes ITS inventory, look and location into the host's player
-- save (single Save_Player object); on load the body comes back as a stray
-- character. Every player character except the host's own is tagged
-- skip-save the game's way (EMSFunctionLibrary.SetActorSaveProperties, the
-- EMS_SkipSave tag; the tag survives death). Never the host's own pawn: the
-- player save skips tagged actors too.
local EMS_LIB = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"
local SKIP_TAG = "EMS_SkipSave"   -- tag names checked in the game's EMS build
local skip_saved = {}   -- [object name] = true (tried; re-checked through the tag)

-- One actor: tag it skip-save unless it already carries the tag. Returns
-- false when the EMS library is missing.
local function mark_skip_save(lib_ref, a, what)
    if has_tag(a, SKIP_TAG) then return true end
    local k = ue.name(a)
    if skip_saved[k] then return true end   -- tried; the tag check above may not see EMS's tag
    lib_ref.lib = lib_ref.lib or ue.find_object(EMS_LIB)
    if not lib_ref.lib then return false end
    local ok, err = pcall(function() lib_ref.lib:SetActorSaveProperties(a, true, false, false, 0) end)
    skip_saved[k] = true
    log.info("saves: %s %s marked skip-save (ok=%s, tag now %s%s)", what, ue.short(a), tostring(ok),
        tostring(has_tag(a, SKIP_TAG)), ok and "" or (" " .. tostring(err)))
    return true
end

function M.host_skip_save_tick()
    local lib_ref = {}
    -- Remote players' controllers: BP_PlayerController's BeginPlay (@9243)
    -- marks every controller persistent, and its ActorPreSave (@3716) writes
    -- the host's single Save_Player (name, kills, respawn point) from that
    -- controller's values. Done first: does not depend on the host's pawn.
    for _, r in pairs(S and S.remote or {}) do
        if ue.valid(r.pc) and not mark_skip_save(lib_ref, r.pc, "remote controller") then return end
    end
    local me = ue.local_pawn()
    local me_name = me and ue.name(me)
    if not me_name then
        -- host dead / respawning: only characters known to be other players'
        -- (the host's own new character may not be possessed yet)
        for _, r in pairs(S and S.remote or {}) do
            local p = ue.pawn_of(r.pc)
            if p and not mark_skip_save(lib_ref, p, "character") then return end
            if ue.valid(r.pawn) and not mark_skip_save(lib_ref, r.pawn, "character") then return end
        end
        return
    end
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and ue.name(p) ~= me_name then
            if not mark_skip_save(lib_ref, p, "character") then return end
        end
    end
end

-- New world (sdc_session.world_reset_hooks via sdc_respawn): names of the old
-- world's objects can come back for new ones.
function M.reset_world()
    skip_saved = {}
end

-- Host tick for one remote player (1 s).
function M.host_player_tick(r, now)
    -- The last character is kept while the player is dead. The game can
    -- destroy it (death path, respawn screen); drop it while it is only
    -- pending kill, long before the garbage collector frees its memory.
    if r.pawn ~= nil and not ue.valid(r.pawn) then r.pawn = nil end
    local pawn = ue.pawn_of(r.pc)
    if pawn then
        r.pawn = pawn
        r.pawnless_since = nil
        local dead = is_dead(pawn)
        if dead and not r.dead then
            log.info("host: %s died", r.name)
        end
        r.dead = dead
        -- alive again (any respawn path): nothing left to wait for; a dead
        -- body still possessed must not block a waiting respawn
        if not dead then r.respawn_wait = nil end
        if not (dead and r.respawn_wait) then return end
    end
    r.pawnless_since = r.pawnless_since or now
    -- a respawn the player asked for while the host was dead
    if r.respawn_wait then
        local hp = ue.local_pawn()
        if hp and not is_dead(hp) and S.in_menu == false and now - (S.menu_since or 0) >= 3 then
            local w = r.respawn_wait
            r.respawn_wait, r.dead = nil, false
            log.info("host: the host is alive again; %s respawns now (%s, waited %d s)", r.name, w.mode, now - w.at)
            M.spawn_for(r, w.mode, w.point)
        end
        return
    end
    -- A dead player chooses how to respawn on the game's death screen.
    if r.dead or (ue.valid(r.pawn) and is_dead(r.pawn)) then
        r.dead = true
        return
    end
    local wait = r.spawned_once and cfg.get("respawn_delay") or 2
    -- not while the host's own save is still being restored: a character
    -- spawned then comes out with movement disabled
    local host_ready = S.in_menu == false and now - S.menu_since >= 4
    -- the first character waits while the player makes their own one
    local gate_open = true
    if not r.spawned_once and M.join_gate then
        local okg, open = pcall(M.join_gate, r, now)
        if okg then gate_open = open ~= false else log.err_throttled("join-gate", "host: join gate: %s", tostring(open)) end
    end
    -- and until the host knows who it is (sdc_persist: the saved character)
    if gate_open and not r.spawned_once and M.persist_gate then
        local okp, open = pcall(M.persist_gate, r, now)
        if okp then gate_open = open ~= false else log.err_throttled("persist-gate", "host: persist gate: %s", tostring(open)) end
    end
    if host_ready and gate_open and not r.spawn_pending and now - r.pawnless_since >= wait then
        M.spawn_for(r, r.spawned_once and "host" or "join")
    end
end

function M.on_left(r)
    local p = r.pawn
    if ue.valid(p) and not ue.valid(ue.prop(p, "Controller")) then
        pcall(function() p:K2_DestroyActor() end)
        log.info("host: removed the character of %s", r.name)
    end
    if r.spawned_key then S.spawned[r.spawned_key] = nil end
end

function M.force_spawn_all()
    for _, r in pairs(S.remote) do
        if ue.valid(r.pc) and not ue.pawn_of(r.pc) then M.spawn_for(r, "host") end
    end
end

-- Safety net: a death screen on the host while the host is alive belongs to a
-- client (should not happen any more with sdc_ctx; logged if it does).
local DEATH_SCREENS = { "RespawnScreen_C", "ScreenPermadeath_C" }

local function host_remove_foreign_death_screen()
    if S.role ~= "host" then return end
    local me = ue.local_pawn()
    if not me or is_dead(me) then return end
    for _, cls in ipairs(DEATH_SCREENS) do
        for _, w in ipairs(ue.find_all(cls)) do
            local ok, inv = pcall(function() return w:IsInViewport() end)
            if ok and inv then
                pcall(function() w:RemoveFromParent() end)
                local pc = ue.local_pc()
                if pc then
                    pcall(function() pc:ResetIgnoreInputFlags() end)
                    W.game_input(pc, "host: a death screen meant for a client was taken off the host's screen")
                    pcall(function() pc:SetViewTargetWithBlend(me, 0.0, 0, 0.0, false) end)
                end
                log.warn("host: removed a death screen that was meant for a client")
            end
        end
    end
end

-- ===========================================================================
-- Client: own character setup
-- ===========================================================================

-- Fallback only. The main menu's widgets on a client come from the MainMenu
-- sublevel's level script (MainMenu_C: PressAnyKeyWidget@75, MenuWidget@1251,
-- which opens SaveMenu / DifficultySettingsMenu / CharacterCreatorMenu). The
-- client no longer loads that sublevel in the host's world (sdc_localinit),
-- so normally there is nothing to close. Only widgets that are themselves on
-- the viewport are taken off: the pause and death screens hold their own
-- SaveMenu / DifficultySettingsMenu children, which must stay.
local MENU_WIDGETS = { "PressAnyKeyWidget_C", "MenuWidget_C", "SaveMenu_C",
                       "CharacterCreatorMenu_C", "DifficultySettingsMenu_C" }

local function charcreate_open()
    local cc = package.loaded["sdc_charcreate"]
    if type(cc) ~= "table" or type(cc.is_open) ~= "function" then return false end
    local ok, open = pcall(cc.is_open)
    return ok and open == true
end

-- A menu widget on the viewport is a stray main-menu one only while no game
-- window is open: the pause menu's own Load puts a SaveMenu_C on the
-- viewport (PauseScreen @2680-2766), and a window keeps the UI input the
-- game gave it (sdc_uiinput, config game_ui_input).
local function close_menu_widgets(pc)
    if charcreate_open() then return end
    local found = {}
    for _, cls in ipairs(MENU_WIDGETS) do
        for _, w in ipairs(ue.find_all(cls)) do
            local okv, inv = pcall(function() return w:IsInViewport() end)
            if okv and inv == true then found[#found + 1] = { w = w, cls = cls } end
        end
    end
    if #found == 0 then return end
    local open = W.game_window_open()
    if open then
        local names = {}
        for _, f in ipairs(found) do names[#names + 1] = f.cls end
        log.info("client: menu widget(s) %s on screen while %s is open: theirs, left alone (game controls not forced)",
            table.concat(names, ", "), open)
        return
    end
    local closed = {}
    for _, f in ipairs(found) do
        if pcall(function() f.w:RemoveFromParent() end) then closed[#closed + 1] = f.cls end
    end
    if #closed > 0 then
        log.info("client: closed menu widgets of the client's own level script (MainMenu got loaded after all?): %s",
            table.concat(closed, ", "))
        W.game_input(pc, "stray main-menu widgets closed: " .. table.concat(closed, ", "))
    end
end
M.close_menu_widgets = close_menu_widgets

local function setup_input(pc, pawn, first)
    local steps = {}
    local function step(name, fn)
        local ok, err = pcall(fn)
        steps[#steps + 1] = name .. "=" .. (ok and "ok" or ("ERR " .. tostring(err)))
    end
    if first then step("ResetIgnoreInputFlags", function() pc:ResetIgnoreInputFlags() end) end
    local imc = ue.find_object(IMC_PATH)
    if imc then
        for _, ss in ipairs(ue.find_all("EnhancedInputLocalPlayerSubsystem")) do
            if ue.valid(ss) then step("AddMappingContext", function() ss:AddMappingContext(imc, 0, {}) end) end
        end
    end
    local vt = ue.try(function() return pc:GetViewTarget() end)
    if ue.name(vt) ~= ue.name(pawn) then
        step("SetViewTarget", function() pc:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
    end
    if first and ue.name(ue.prop(pc, "AcknowledgedPawn")) ~= ue.name(pawn) then
        step("ClientRestart", function() pc:ClientRestart(pawn) end)
    end
    W.game_input(pc, first and "own character set up after possession" or "own character setup check")
    log.info("client: input %s (%s) %s", ue.short(pawn), first and "first" or "check", table.concat(steps, " "))
end

-- HUD: created by the game's Client_AddUI (sent by the host on possession,
-- unreliable). If it did not arrive, run it here: a Client RPC called on the
-- owning client executes locally.
local function ensure_hud(pawn, final)
    local hud = ue.prop(pawn, "InGameUI")
    if not ue.valid(hud) then
        if final then
            log.warn("client: still no HUD for %s", ue.short(pawn))
            return false
        end
        local ok, err = pcall(function() pawn:Client_AddUI() end)
        log.info("client: no HUD yet, ran Client_AddUI locally (ok=%s%s)", tostring(ok), ok and "" or (" " .. tostring(err)))
        return false
    end
    -- an old HUD (of a dead body) must not stay on screen
    for _, w in ipairs(ue.find_all("BP_Ingame_C")) do
        if ue.name(w) ~= ue.name(hud) then
            local ok, inv = pcall(function() return w:IsInViewport() end)
            if ok and inv then
                pcall(function() w:RemoveFromParent() end)
                log.info("client: removed an old HUD %s", ue.short(w))
            end
        end
    end
    return true
end

-- Minimap: the game builds it in ReceivePossessed (host side), so the
-- client's own character never got one. Markers then register into it.
local function ensure_minimap(pawn)
    local mm = ue.prop(pawn, "MinimapSystemComponent")
    if not ue.valid(mm) then return end
    if ue.valid(ue.prop(mm, "MapWidget")) then return end
    local ok, err = pcall(function() mm:Event_ConstructMap() end)
    log.info("client: minimap built (ok=%s%s)", tostring(ok), ok and "" or (" " .. tostring(err)))
    ue.delay("markers", 1200, function()
        local n = 0
        for _, cls in ipairs({ "BP_PlayerMarker_C", "BP_POIManager_C" }) do
            for _, a in ipairs(ue.find_all(cls)) do
                if pcall(function() a:RespawnMarker() end) then n = n + 1 end
            end
        end
        for _, a in ipairs(ue.find_all("BP_Marker_C")) do
            if pcall(function() a:AddMarker() end) then n = n + 1 end
        end
        log.info("client: %d map markers registered", n)
    end)
end

function M.client_tick(cs, pc, pawn, now)
    -- the dead body is kept for the death marker check; drop it as soon as
    -- it is gone (pending kill), before its memory can be freed
    if cs.last_pawn ~= nil and not ue.valid(cs.last_pawn) then cs.last_pawn = nil end
    if not pawn then return end
    cs.last_pawn = pawn
    -- the game destroys the dead body when it spawns the loot bag: keep where
    -- this player last was, for the own death marker check
    cs.last_loc = ue.location(pawn) or cs.last_loc
    local key = ue.name(pawn)
    if key ~= cs.pawn_key then
        cs.pawn_key, cs.pawn_seen_at, cs.setup_stage = key, now, 0
        cs.respawned = cs.had_pawn == true
        cs.had_pawn = true
        log.info("client: possessing %s%s", ue.short(pawn), cs.respawned and " (respawn)" or "")
    end
    local age = now - cs.pawn_seen_at
    if cs.setup_stage == 0 and age >= 1 then
        cs.setup_stage = 1
        close_menu_widgets(pc)
        setup_input(pc, pawn, true)
    elseif cs.setup_stage == 1 and age >= 3 then
        cs.setup_stage = 2
        ensure_hud(pawn, false)
        ensure_minimap(pawn)
    elseif cs.setup_stage == 2 and age >= 6 then
        cs.setup_stage = 3
        setup_input(pc, pawn, false)
        if ensure_hud(pawn, true) then
            -- level / XP widgets of the new HUD
            pcall(function() pc:BindPlayerRespawn() end)
        end
    elseif cs.setup_stage == 3 and age >= 15 then
        -- the title screen can show up late (after the intro sequence)
        cs.setup_stage = 4
        close_menu_widgets(pc)
    end
end

function M.reinit()
    local pc, pawn = ue.local_pc(), ue.local_pawn()
    if not (pc and pawn) then log.say("no_local_pawn", "warn") return end
    setup_input(pc, pawn, true)
    ensure_hud(pawn, false)
    ensure_minimap(pawn)
end

-- ===========================================================================
-- Client: the game's death screen and pause menu
-- ===========================================================================

-- Screens already adapted, by object name (an address can be reused by the
-- next screen once the old one is freed). Death screens keep their cloned
-- buttons here: [name] = { clicks = { { button, label, fn } } }.
local patched = {}

function M.request_respawn(mode, screen)
    if S.role ~= "client" then return end
    local pc = ue.local_pc()
    local args = { mode or "host" }
    if mode == "point" and pc then
        local tf = ue.prop(pc, "RespawnLoc")
        local t = tf and ue.try(function() return tf.Translation end)
        if t then args[2], args[3], args[4] = string.format("%.0f", t.X), string.format("%.0f", t.Y), string.format("%.0f", t.Z) end
    end
    log.say("respawning", "info", 4)
    net.send_to_host("RESPAWN", table.unpack(args))
    -- stop polling the screen's buttons before it is removed (and later freed)
    W.forget(screen)
    if ue.valid(screen) then pcall(function() screen:RemoveFromParent() end) end
    W.game_input(pc, "death screen closed: respawn asked")
end

local function patch_respawn_screen(w)
    if S.role ~= "client" or not ue.valid(w) then return end
    local k = ue.name(w)
    local rec = patched[k]
    if rec then
        -- the same screen shown again: its clicks were dropped when it left
        -- the screen, register them again
        local okv, inv = pcall(function() return w:IsInViewport() end)
        if rec.clicks and okv and inv == true and not W.has(w) then
            for _, c in ipairs(rec.clicks) do
                if ue.valid(c[1]) then W.on_click(c[1], c[2], c[3], w) end
            end
        end
        return
    end
    local rnd = W.child(w, "RespawnRandomButton")
    if not ue.valid(rnd) or not ue.valid(ue.prop(rnd, "Slot")) then return end   -- not built yet
    rec = { clicks = {} }
    patched[k] = rec
    local sp = W.child(w, "RespawnSpawnPointButton")
    local show_point = W.visible(sp)
    local function add(orig, label_key, mode, after)
        local fn = function() M.request_respawn(mode, w) end
        local label = log.tr(label_key)
        local b = W.clone_button(orig, label, fn, after, w)
        rec.clicks[#rec.clicks + 1] = { b, label, fn }
        return b
    end
    local native = false
    do
        local okn, v = pcall(M.native_respawn_ok)
        native = okn and v == true
    end
    local ok, err
    if native then
        -- The game's own buttons stay: RespawnRandomButton -> Svr_RequestRespawn_Random,
        -- RespawnSpawnPointButton -> Svr_RequestRespawn_SpawnPoint (RespawnScreen
        -- @1052 / @435); the host runs them for this player (sdc_respawn).
        -- Only "near the host", which the game does not have, is added.
        ok, err = pcall(function() add(rnd, "btn_respawn_host", "host", rnd) end)
    else
        ok, err = pcall(function()
            local b1 = add(rnd, "btn_respawn_host", "host", rnd)
            local b2 = add(rnd, "btn_respawn_random", "random", b1)
            if show_point then add(sp, "btn_respawn_point", "point", b2) end
        end)
        W.hide(rnd)
        W.hide(sp)
    end
    -- "Load A Previous Save" would load the client's own single-player save
    W.hide(W.child(w, "LoadSaveButton"))
    log.info("client: death screen adapted for co-op (%s respawn buttons; ok=%s%s)",
        native and "the game's own" or "the mod's", tostring(ok), ok and "" or (" " .. tostring(err)))
end

-- Pause menu on a client: saving would write the host's world into the
-- client's own save, and suicide / difficulty run through the host's player 0.
local PAUSE_HIDE = { "Save", "QuickSave", "Suicide", "DifficultySettings" }

local function patch_pause_screen(w)
    if S.role ~= "client" or not ue.valid(w) then return end
    local k = ue.name(w)
    if patched[k] then return end
    local first = W.child(w, "Resume")
    if not ue.valid(first) then return end
    patched[k] = true
    local hidden = {}
    for _, name in ipairs(PAUSE_HIDE) do
        local b = W.child(w, name)
        if ue.valid(b) then
            W.hide(b)
            hidden[#hidden + 1] = name
        end
    end
    log.info("client: pause menu adapted for co-op (hidden: %s)", table.concat(hidden, ", "))
end

-- ===========================================================================
-- Death markers ("Location of your death") — every machine
-- ===========================================================================
-- The dead player's loot container spawns a local map marker in its
-- BeginPlay on every machine, so everybody got everybody's death marker.

-- Two things show someone's death: the BP_Marker (map + compass, registered
-- with the minimap ~1 s after it spawns) and, with Game.DeathWidget on, the
-- container's own DeathWidget component - the floating "Death Location" skull
-- (Container_DeadPlayerLoot @948; the game destroys it when looted, @1949).
local function remove_marker(container, why)
    local did = {}
    local m = ue.prop(container, "DeathMarker")
    if ue.valid(m) then
        local mw = ue.prop(m, "Marker")
        if ue.valid(mw) then pcall(function() mw:RemoveFromParent() end) end
        if pcall(function() m:K2_DestroyActor() end) then did[#did + 1] = "map/compass marker" end
    end
    local dw = ue.prop(container, "DeathWidget")
    if ue.valid(dw) and pcall(function() dw:K2_DestroyComponent(container) end) then
        did[#did + 1] = "floating death widget"
    end
    if #did > 0 then
        log.info("death marker of %s removed (%s): %s", ue.short(container), why, table.concat(did, ", "))
    end
end

local kept_logged = {}
local function check_death_marker(container)
    if not ue.valid(container) then return end
    local cl = ue.location(container)
    if S.role == "host" then
        -- both died at the same spot: the nearer body owns the bag
        local me = ue.local_pawn()
        local my_d = (me and is_dead(me)) and dist(ue.location(me), cl) or math.huge
        for _, r in pairs(S.remote) do
            local p = ue.valid(r.pawn) and r.pawn or nil
            local d = p and is_dead(p) and dist(ue.location(p), cl) or math.huge
            if d < 600 and d < my_d then
                remove_marker(container, "a remote player's death")
                return
            end
        end
    elseif S.role == "client" then
        -- after death the body is unpossessed: use the last own character
        local cs = S.client
        local me = ue.local_pawn() or (cs and ue.valid(cs.last_pawn) and cs.last_pawn or nil)
        if me and is_dead(me) and dist(ue.location(me), cl) < 600 then return end
        -- the body is already gone: the bag lies where this player last stood
        local own = (not me or is_dead(me)) and cs and cs.last_loc and dist(cs.last_loc, cl) < 600
        if own then
            local k = ue.name(container)
            if not kept_logged[k] then
                kept_logged[k] = true
                log.info("death marker of %s kept (this player's death)", ue.short(container))
            end
        else
            remove_marker(container, "not this player's death")
        end
    end
end

-- ===========================================================================
-- Hooks / watches
-- ===========================================================================

function M.install_watches()
    local function watch(path, fn)
        local ok, err = pcall(NotifyOnNewObject, path, fn)
        log.info("watch %s %s%s", path:match("[^%.]+$"), ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    watch("/Game/UI/Widgets/Player/RespawnScreen.RespawnScreen_C", function(w)
        if S.role == "client" then
            for _, ms in ipairs({ 50, 200, 600 }) do
                ue.delay("death-screen", ms, function() patch_respawn_screen(w) end)
            end
        elseif S.role == "host" then
            for _, ms in ipairs({ 200, 1000 }) do
                ue.delay("death-screen", ms, host_remove_foreign_death_screen)
                -- the host's own death screen: loading a previous save while
                -- others are connected would reload the world under them
                ue.delay("death-screen-host", ms + 50, function()
                    if not ue.valid(w) or #(S.remote_pcs or {}) == 0 then return end
                    local okv, inv = pcall(function() return w:IsInViewport() end)
                    if not okv or inv ~= true then return end
                    local b = W.child(w, "LoadSaveButton")
                    if W.visible(b) then
                        W.hide(b)
                        log.info("host: \"Load A Previous Save\" hidden on the death screen (players connected)")
                    end
                end)
            end
        end
    end)
    watch("/Game/UI/Menus/PauseScreen/PauseScreen.PauseScreen_C", function(w)
        if S.role ~= "client" then return end
        for _, ms in ipairs({ 50, 300 }) do
            ue.delay("pause-screen", ms, function() patch_pause_screen(w) end)
        end
    end)
    watch("/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C", function(c)
        if S.role ~= "host" and S.role ~= "client" then return end
        -- early, before the marker registers with the minimap (~1 s after
        -- it spawns); again later for a dead body that was not there yet
        for _, ms in ipairs({ 300, 900, 2500 }) do
            ue.delay("death-marker", ms, function() check_death_marker(c) end)
        end
    end)
end

-- Client tick fallback for widgets the creation watch missed (reused ones).
function M.client_widgets_tick()
    for _, w in ipairs(ue.find_all("RespawnScreen_C")) do
        local ok, inv = pcall(function() return w:IsInViewport() end)
        if ok and inv then patch_respawn_screen(w) end
    end
    for _, w in ipairs(ue.find_all("PauseScreen_C")) do patch_pause_screen(w) end
end

-- ===========================================================================
-- Unstuck: a client's character next to the host (or at a game start)
-- ===========================================================================
-- Idea from SurrounDeadMP's tphost (work\audit\surroundeadmp.md, idea 1).
-- Client -> host: UNSTUCK|host|start. The host picks the spot (near_host_spot
-- around its own character, or a random 'Survival' PlayerStart as the game's
-- respawn does) and checks the character: alive, not in a vehicle, not more
-- often than every UNSTUCK_HOST_MIN_S.
--  * client_movement_authority on (the server takes the client's position):
--    host -> client UNSTUCKTO|x|y|z|yaw|where; the client moves itself with
--    K2_TeleportTo (the engine's encroachment check), rising 150 cm per try.
--  * off: the host moves the server's character with K2_TeleportTo; the
--    engine's movement correction brings the client along (UNSTUCKOK).
-- A character left in MOVE_None (movement off) is set to falling.

local UNSTUCK_HOST_MIN_S = 10
local MOVE_NONE, MOVE_FALLING = 0, 3
local unstuck = { last_request = -1000 }   -- client

local TEXT = {
    unstuck_not_client = { "Unstuck: only for a client connected to a host.",
                           "Перенос к хосту работает только у подключённого игрока." },
    unstuck_dead       = { "Unstuck: you are dead, use the respawn buttons.",
                           "Персонаж мёртв — воспользуйтесь кнопками возрождения." },
    unstuck_vehicle    = { "Unstuck: leave the vehicle first.", "Сначала выйдите из транспорта." },
    unstuck_wait       = { "Unstuck: again in %d s.", "Перенос снова будет доступен через %d с." },
    unstuck_asked      = { "Unstuck: asking the host for a free spot...", "Переношу персонажа к хосту..." },
    unstuck_done       = { "Unstuck: moved next to the host.", "Персонаж перенесён к хосту." },
    unstuck_done_start = { "Unstuck: moved to a start point.", "Персонаж перенесён на точку старта." },
    unstuck_failed     = { "Unstuck: no free spot found.",
                           "Не нашлось свободного места — попробуйте ещё раз или попросите хоста отойти." },
    unstuck_refused    = { "Unstuck: the host refused.", "Хост не перенёс персонажа: %s." },
    respawn_wait_host  = { "The host is dead: you respawn next to them as soon as they respawn.",
                           "Хост мёртв — вы возродитесь рядом с ним, как только он возродится." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end
local REFUSE_RU = {
    nopawn = "нет персонажа", dead = "персонаж мёртв", vehicle = "персонаж в транспорте",
    soon = "слишком часто", nospot = "нет места",
}

local function in_vehicle(pawn)
    local vdc = ue.prop(pawn, "VehicleDrivingComponent")
    return ue.valid(ue.prop(vdc, "Vehicle"))
end

local function free_movement(pawn)
    local cmc = ue.prop(pawn, "CharacterMovement")
    if ue.valid(cmc) and ue.prop(cmc, "MovementMode") == MOVE_NONE then
        return (pcall(function() cmc:SetMovementMode(MOVE_FALLING, 0) end))
    end
    return false
end

-- Moves `pawn` to the first height K2_TeleportTo accepts. Returns moved, try.
local function teleport_near(pawn, loc, yaw)
    for attempt = 0, 3 do
        local dest = { X = loc.X, Y = loc.Y, Z = loc.Z + attempt * 150 }
        local ok, moved = pcall(function()
            return pawn:K2_TeleportTo(dest, { Pitch = 0, Yaw = yaw or 0, Roll = 0 })
        end)
        if ok and moved == true then return true, attempt end
    end
    return false, nil
end

-- Client: co-op panel button / console sdcoop_unstuck. where = "host" | "start".
function M.request_unstuck(where)
    where = where == "start" and "start" or "host"
    if not S or S.role ~= "client" then log.say("unstuck_not_client", "warn") return false end
    local pawn = ue.local_pawn()
    if not pawn then log.say("no_local_pawn", "warn") return false end
    if is_dead(pawn) then log.say("unstuck_dead", "warn") return false end
    if in_vehicle(pawn) then log.say("unstuck_vehicle", "warn") return false end
    local cd = tonumber(cfg.get("unstuck_cooldown")) or 30
    local now = os.time()
    if now - unstuck.last_request < cd then
        log.say("unstuck_wait", "warn", 4, cd - (now - unstuck.last_request))
        return false
    end
    unstuck.last_request = now
    log.say("unstuck_asked", "info", 4)
    log.info("client: unstuck (%s) asked from %s", where, ue.short(pawn))
    net.send_to_host("UNSTUCK", where)
    return true
end

-- Host: UNSTUCK from a client.
local function host_unstuck(f, pc)
    local r = api.remote_record(pc)
    local where = f[1] == "start" and "start" or "host"
    local pawn = ue.pawn_of(pc)
    local function refuse(code)
        log.info("host: unstuck (%s) for %s refused: %s", where, r.name, code)
        net.send_to(pc, "UNSTUCKOK", "refused", code)
    end
    if not pawn then refuse("nopawn") return end
    if is_dead(pawn) then refuse("dead") return end
    if in_vehicle(pawn) then refuse("vehicle") return end
    local now = os.time()
    if now - (r.unstuck_at or -1000) < UNSTUCK_HOST_MIN_S then refuse("soon") return end
    r.unstuck_at = now
    local loc, yaw
    if where == "start" then loc, yaw = random_spot() end
    if not loc then loc, yaw = near_host_spot(r.index, 0) end
    if not loc then loc, yaw = random_spot() end
    if not loc then refuse("nospot") return end
    if cfg.get("client_movement_authority") then
        net.send_to(pc, "UNSTUCKTO", string.format("%.0f", loc.X), string.format("%.0f", loc.Y),
            string.format("%.0f", loc.Z), string.format("%.0f", yaw or 0), where)
        log.info("host: unstuck (%s) for %s: spot %.0f,%.0f,%.0f sent (the client moves itself, client-authoritative movement)",
            where, r.name, loc.X, loc.Y, loc.Z)
        return
    end
    local moved, attempt = teleport_near(pawn, loc, yaw)
    local freed = free_movement(pawn)
    log.info("host: unstuck (%s) for %s: K2_TeleportTo %.0f,%.0f,%.0f moved=%s (try %s), movement freed=%s",
        where, r.name, loc.X, loc.Y, loc.Z, tostring(moved), tostring(attempt), tostring(freed))
    net.send_to(pc, "UNSTUCKOK", moved and "ok" or "failed", where)
end

-- Client: UNSTUCKTO from the host.
local function client_unstuck_to(f)
    local pawn = ue.local_pawn()
    local x, y, z, yaw = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    if not pawn or not (x and y and z) then return end
    local moved, attempt = teleport_near(pawn, { X = x, Y = y, Z = z }, yaw)
    local freed = free_movement(pawn)
    log.info("client: unstuck to %.0f,%.0f,%.0f: moved=%s (try %s), movement freed=%s (%s)", x, y, z,
        tostring(moved), tostring(attempt), tostring(freed), tostring(f[5]))
    -- "saved": sdc_persist puts a character that spawned before its id came
    -- back where the player left - nothing to announce
    if f[5] == "saved" then return end
    if moved then
        log.say(f[5] == "start" and "unstuck_done_start" or "unstuck_done", "ok", 5)
    else
        log.say("unstuck_failed", "warn", 6)
    end
end

-- ===========================================================================
-- Messages
-- ===========================================================================

function M.register_handlers()
    -- client -> host: UNSTUCK|host|start
    net.on("UNSTUCK", host_unstuck)
    -- host -> client: UNSTUCKTO|x|y|z|yaw|where (client-authoritative movement)
    net.on("UNSTUCKTO", client_unstuck_to)
    -- host -> client: UNSTUCKOK|ok|failed|refused|<where or reason>
    net.on("UNSTUCKOK", function(f)
        if f[1] == "ok" then
            log.say(f[2] == "start" and "unstuck_done_start" or "unstuck_done", "ok", 5)
        elseif f[1] == "failed" then
            log.say("unstuck_failed", "warn", 6)
        else
            log.info("client: unstuck refused by the host: %s", tostring(f[2]))
            log.say("unstuck_refused", "warn", 6, REFUSE_RU[f[2] or ""] or "?")
        end
    end)

    -- client -> host: RESPAWN|mode[|x|y|z]
    net.on("RESPAWN", function(f, pc)
        local r = api.remote_record(pc)
        if r.spawn_pending then return end
        local mode = f[1] or "host"
        local cur = ue.pawn_of(pc)
        if cur and not is_dead(cur) then
            log.info("host: %s asked to respawn while alive, ignored", r.name)
            return
        end
        log.info("host: %s respawns (%s)", r.name, mode)
        -- as in single player, the body goes away (its loot is in the
        -- death container)
        local body = cur or r.pawn
        if cur then pcall(function() pc:UnPossess() end) end
        if ue.valid(body) and is_dead(body) then pcall(function() body:K2_DestroyActor() end) end
        local point
        if mode == "point" then
            local x, y, z = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
            if x and y and z and (x ~= 0 or y ~= 0) then point = { loc = { X = x, Y = y, Z = z }, yaw = 0 } end
        end
        r.dead = false
        M.spawn_for(r, mode, point)
    end)

    -- host -> client: SPAWNED|pawn name (the client re-checks its setup)
    net.on("SPAWNED", function()
        local cs = S.client
        if cs and cs.setup_stage and cs.setup_stage > 2 then cs.setup_stage = 1 end
    end)
end

return M
