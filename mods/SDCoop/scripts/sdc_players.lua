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
--   * "unstuck": a client moves its character next to the host (UNSTUCK);
--     "pull": the host moves a client's character next to itself (F7 list);
--     "go to a player" (sdcoop_goto, host setting teleport_to_players): any
--     player next to any other one, another client only with its consent.
--   * the server's ClientRestart on a client starts the own setup at once.

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

-- Down (sdc_down's knockdown): alive for the game, but it cannot be moved
-- (unstuck, pull, go to) and cannot move itself.
local function downed(pawn)
    local dn = package.loaded["sdc_down"]
    if type(dn) ~= "table" or type(dn.is_down) ~= "function" or not ue.valid(pawn) then return false end
    local ok, v = pcall(dn.is_down, pawn)
    return ok and v == true
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

-- sdc_admin: access_gate(r, now) false = the host has not let the player in
-- (join_access approve) or refused it: no first character.
M.access_gate = nil

local function access_held(r, now)
    if r.spawned_once or not M.access_gate then return false end
    local ok, open = pcall(M.access_gate, r, now)
    if not ok then
        log.err_throttled("access-gate", "host: access gate: %s", tostring(open))
        return false
    end
    return open == false
end

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
    for _, p in ipairs(ue.player_chars() or {}) do
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
    -- the first character waits for the host's yes (sdc_admin), then while
    -- the player makes their own one
    local gate_open = not access_held(r, now)
    if gate_open and not r.spawned_once and M.join_gate then
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
end

function M.force_spawn_all()
    for _, r in pairs(S.remote) do
        if ue.valid(r.pc) and not ue.pawn_of(r.pc) then
            if access_held(r, os.time()) then
                log.info("host: %s is not let in (sdc_admin): no character for it", tostring(r.name))
            else
                M.spawn_for(r, "host")
            end
        end
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

-- The server's ClientRestart(NewPawn) on this client (0.7.3 wave): the
-- engine's own "your character is here" (APlayerController::ClientRestart,
-- sent when the host possesses the character). A pre-hook (sdc_ue's shared
-- native hook) notes it and starts the own setup 250 ms later, instead of
-- waiting for the next 1 s tick plus a second (client_tick stage 0). The
-- mod's own ClientRestart call (setup_input) is not taken for the server's.
local restart = { own = false, at = nil, pawn = nil, n = 0 }
M.restart = restart   -- tests

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
        restart.own = true
        step("ClientRestart", function() pc:ClientRestart(pawn) end)
        restart.own = false
    end
    W.game_input(pc, first and "own character set up after possession" or "own character setup check")
    log.info("client: input %s (%s) %s", ue.short(pawn), first and "first" or "check", table.concat(steps, " "))
end

-- The game's HUDs (BP_Ingame_C) on this screen. FindAllOf does not see UMG
-- widgets in this UE4SS build (sdc_lobby.live_widgets): the game's own
-- WidgetBlueprintLibrary.GetAllWidgetsOfClass (top level only = in the
-- viewport), plus whatever FindAllOf still finds; each widget once, never
-- the class default. Also sdc_playermarks' sweep of stray HUD compasses.
local INGAME_CLASS = "/Game/Inventory/BP_Ingame.BP_Ingame_C"
function M.screen_huds()
    local out, seen = {}, {}
    local function add(w)
        if not ue.valid(w) or seen[ue.name(w)] or ue.short(w):find("^Default__") then return end
        seen[ue.name(w)] = true
        out[#out + 1] = w
    end
    local wbl, wc = ue.widget_lib and ue.widget_lib() or nil, ue.local_pc() or ue.game_instance()
    local cls = ue.find_object(INGAME_CLASS)
    if wbl and wc and ue.valid(cls) then
        local arr = {}
        if pcall(function() wbl:GetAllWidgetsOfClass(wc, arr, cls, true) end) then
            for _, v in ipairs(arr) do
                local w = v
                if type(v) == "userdata" and not ue.valid(v) then w = ue.try(function() return v:get() end) end
                add(w)
            end
        end
    end
    for _, w in ipairs(ue.find_all("BP_Ingame_C")) do add(w) end
    return out
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
    for _, w in ipairs(M.screen_huds()) do
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
-- client's own character never got one. Markers then register into it
-- (map markers players place, BP_PlayerMarker_C: sdc_playermarks).
local function ensure_minimap(pawn)
    local mm = ue.prop(pawn, "MinimapSystemComponent")
    if not ue.valid(mm) then return end
    if ue.valid(ue.prop(mm, "MapWidget")) then return end
    local ok, err = pcall(function() mm:Event_ConstructMap() end)
    log.info("client: minimap built (ok=%s%s)", tostring(ok), ok and "" or (" " .. tostring(err)))
    ue.delay("markers", 1200, function()
        local n = 0
        for _, a in ipairs(ue.find_all("BP_POIManager_C")) do
            if pcall(function() a:RespawnMarker() end) then n = n + 1 end
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
        log.info("client: possessing %s%s%s", ue.short(pawn), cs.respawned and " (respawn)" or "",
            (restart.pawn == key and restart.at) and string.format(" (the server's ClientRestart %.1f s ago)",
                os.clock() - restart.at) or "")
    end
    -- the server's ClientRestart for this very character came: no second's wait
    if restart.pawn == key and cs.setup_stage == 0 and cs.restart_used ~= restart.n then
        cs.restart_used = restart.n
        cs.pawn_seen_at = math.min(cs.pawn_seen_at, now - 1)
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

-- Client: this player's own death boxes, newest last, in S.client (a new
-- connection starts with none): { box = path, name, mark = its marker's
-- path, loc = { X, Y } }. 2026-11-13: a copy of the own box that went out of
-- network range (150 m) and came back is a new actor (sdc_deathbox FL): its
-- BeginPlay spawns a marker and the floating widget again, and with the
-- player alive by then it was taken for someone else's box - both went,
-- while the earlier copy's marker stayed on the map, so opening the box
-- (the game removes the box's own marker then) no longer cleared it.
local OWN = { XY = 100, KEEP = 8 }   -- cm: a copy lies where the earlier one did (the box only moves down)

-- An actor still in the world: a destroyed one stays valid until the
-- garbage collector and reads (0, 0, 0).
function OWN.placed(a)
    local l = ue.valid(a) and ue.location(a)
    return type(l) == "table" and (math.abs(l.X or 0) >= 1 or math.abs(l.Y or 0) >= 1 or math.abs(l.Z or 0) >= 1)
end

function OWN.note(cs, container, cl)
    if not cs or not cl then return end
    cs.own_boxes = cs.own_boxes or {}
    local path, rec = ue.path(container), nil
    for _, o in ipairs(cs.own_boxes) do if o.box == path then rec = o end end
    if not rec then
        rec = { box = path, name = ue.short(container), loc = { X = cl.X, Y = cl.Y } }
        cs.own_boxes[#cs.own_boxes + 1] = rec
        if #cs.own_boxes > OWN.KEEP then table.remove(cs.own_boxes, 1) end
    end
    local m = ue.prop(container, "DeathMarker")
    if ue.valid(m) and ue.class_name(m) == "BP_Marker_C" then rec.mark = ue.path(m) end
end

-- A new copy of an own box (its earlier copy here is gone, at the same
-- place): true = this player's, kept, as one marker - the new copy's (which
-- opening the box removes), with the earlier marker's time left; false (+
-- why) = not.
function OWN.copy(cs, container, cl)
    if not cs or not cs.own_boxes or not cl then return false end
    local path = ue.path(container)
    for _, o in ipairs(cs.own_boxes) do
        if o.box == path then return true end   -- taken already (the later checks)
    end
    for i = #cs.own_boxes, 1, -1 do
        local o = cs.own_boxes[i]
        local dx, dy = o.loc.X - cl.X, o.loc.Y - cl.Y
        local old = ue.find_object(o.box)
        if dx * dx + dy * dy < OWN.XY * OWN.XY and not (old and ue.short(old) == o.name and OWN.placed(old)) then
            local m = o.mark and ue.find_object(o.mark)
            if not (m and ue.class_name(m) == "BP_Marker_C" and OWN.placed(m)) then
                -- opened before (the game removed its marker) or its 20 min ran out: none, as in single player
                return false, "this player's box, its marker gone already: opened, or its time ran out"
            end
            local nm = ue.prop(container, "DeathMarker")
            if not (ue.valid(nm) and ue.class_name(nm) == "BP_Marker_C") then return true end   -- the earlier one stays
            local left = ue.try(function() return m:GetLifeSpan() end)
            if type(left) == "number" and left > 0 then pcall(function() nm:SetLifeSpan(left) end) end
            local mw = ue.prop(m, "Marker")
            if ue.valid(mw) then pcall(function() mw:RemoveFromParent() end) end
            local gone = pcall(function() m:K2_DestroyActor() end)
            log.info("death marker of %s kept (this player's own box: its copy here came again, the earlier copy %s"
                .. " went out of range)%s", ue.short(container), o.name,
                gone and string.format("; the earlier copy's marker removed, this one has its %s s left",
                    type(left) == "number" and string.format("%.0f", left) or "?") or "")
            o.box, o.name, o.mark = path, ue.short(container), ue.path(nm)
            return true
        end
    end
    return false
end

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
        if me and is_dead(me) and dist(ue.location(me), cl) < 600 then
            OWN.note(cs, container, cl)
            return
        end
        -- the body is already gone: the bag lies where this player last stood
        local own = (not me or is_dead(me)) and cs and cs.last_loc and dist(cs.last_loc, cl) < 600
        if own then
            OWN.note(cs, container, cl)
            local k = ue.name(container)
            if not kept_logged[k] then
                kept_logged[k] = true
                log.info("death marker of %s kept (this player's death)", ue.short(container))
            end
        else
            local mine, why = OWN.copy(cs, container, cl)
            if not mine then remove_marker(container, why or "not this player's death") end
        end
    end
end

-- ===========================================================================
-- Hooks / watches
-- ===========================================================================

-- Client: the server's ClientRestart(NewPawn) on the own controller (the
-- hook below). Notes the moment and runs the own setup 250 ms later.
function M.on_client_restart(pc, pawn)
    if restart.own or not S or S.role ~= "client" then return end
    if not ue.valid(pc) or ue.name(pc) ~= ue.name(ue.local_pc()) then return end
    local key = ue.valid(pawn) and ue.name(pawn) or nil
    restart.n = restart.n + 1
    restart.at, restart.pawn = os.clock(), key
    log.info("client: the server's ClientRestart(%s): the own character is here", key and ue.short(pawn) or "none")
    if not key then return end
    local n = restart.n
    ue.delay("client-restart", 250, function()
        if restart.n ~= n or not S or S.role ~= "client" or not S.client then return end
        local lpc = ue.local_pc()
        local p = lpc and ue.pawn_of(lpc)
        if not p or ue.name(p) ~= key then return end
        local ok, err = pcall(M.client_tick, S.client, lpc, p, os.time())
        if not ok then log.err_throttled("client-restart", "client: setup after ClientRestart: %s", tostring(err)) end
    end)
end

function M.install_watches()
    local function watch(path, fn)
        local ok, err = pcall(NotifyOnNewObject, path, fn)
        log.info("watch %s %s%s", path:match("[^%.]+$"), ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    -- the server's ClientRestart reaching this client (M.on_client_restart)
    local function arg(x)
        if x == nil then return nil end
        local ok, v = pcall(function() return x:get() end)
        if ok then return v end
        return x
    end
    local okr, errr = ue.hook_native("/Script/Engine.PlayerController:ClientRestart", "players.restart", function(c, p)
        M.on_client_restart(arg(c), arg(p))
    end)
    log.info("watch ClientRestart %s%s", okr and "ok" or "FAILED", okr and "" or (" " .. tostring(errr)))
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
-- Moving a client's character: "unstuck" (the client asks) and "pull" (the
-- host asks, F7 player list «Ещё ›» -> «Притянуть к себе», sdcoop_pull)
-- ===========================================================================
-- Idea from SurrounDeadMP's tphost (work\audit\surroundeadmp.md, idea 1).
-- Client -> host: UNSTUCK|host|start. The host picks the spot (clear_spot
-- next to its own character, or a random 'Survival' PlayerStart as the game's
-- respawn does) and checks the character: alive, not in a vehicle, not more
-- often than every UNSTUCK_HOST_MIN_S.
--  * client_movement_authority on (the server takes the client's position):
--    host -> client UNSTUCKTO|x|y|z|yaw|where[|id]; the client moves itself
--    with K2_TeleportTo (the engine's encroachment check), rising 150 cm per
--    try. where = host | start | saved (sdc_persist) | pull; a pull's client
--    answers PULLACK|ok|failed|dead|vehicle|nopawn|pull|id (an older client
--    shows its "moved to the host" line and sends nothing: the host checks the
--    position itself after PULL_ACK_MS).
--  * off: the host moves the server's character with K2_TeleportTo; the
--    engine's movement correction brings the client along (UNSTUCKOK).
-- A character left in MOVE_None (movement off) is set to falling.
-- Every host-driven move (send_move: pull, unstuck, sdc_persist's fall check)
-- zeroes the fall speed of the host's copy and keeps it low for a while (the
-- landing guard, below): only the host's copy deals the game's landing damage.

local UNSTUCK_HOST_MIN_S = 10
local MOVE_NONE, MOVE_FALLING = 0, 3
local unstuck = { last_request = -1000 }   -- client
local PULL_ACK_MS = 5000   -- host: a pull's answer from the client is awaited this long
local pull_seq = 0

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
    -- the host's pull: the host's notices (the name first)
    pull_asked         = { "Moving %s to you...", "Переношу игрока %s к вам…" },
    pull_done_host     = { "%s was moved to you.", "%s перенесён к вам." },
    pull_failed_host   = { "Couldn't move %s: there's no free spot next to you. Step away from walls and try again.",
                           "Не удалось перенести игрока %s: рядом с вами нет свободного места. Отойдите от стен и попробуйте ещё раз." },
    pull_unconfirmed   = { "Couldn't confirm that %s was moved.", "Не удалось подтвердить перенос игрока %s." },
    pull_dead          = { "%s is dead: they can respawn with \"Respawn - Near Host\".",
                           "Игрок %s погиб — пусть возродится кнопкой «Возрождение — рядом с хостом»." },
    pull_vehicle       = { "%s is in a vehicle: they need to get out first.",
                           "Игрок %s в транспорте — пусть сначала выйдет." },
    pull_ladder        = { "%s is on a ladder: they need to get off first.", "Игрок %s на лестнице — пусть слезет." },
    pull_sitting       = { "%s is sitting: they need to stand up first.", "Игрок %s сидит — пусть встанет." },
    pull_joining       = { "%s is still joining the world: wait a few seconds.",
                           "Игрок %s ещё входит в мир — подождите несколько секунд." },
    pull_waiting       = { "%s is still waiting for your permission to join (the World tab).",
                           "Игрок %s ещё ждёт вашего разрешения войти (вкладка «Мир»)." },
    pull_no_char       = { "%s has no character in the world yet.", "У игрока %s ещё нет персонажа в мире." },
    pull_gone          = { "%s has left the world.", "Игрок %s уже вышел из мира." },
    -- gone, and no name known for it (never the session key: a controller's name)
    pull_gone_anon     = { "That player has left the world.", "Этот игрок уже вышел из мира." },
    pull_wait          = { "%s can be moved again in %d s.", "Игрока %s можно будет перенести снова через %d с." },
    pull_host_dead     = { "You're dead: respawn first.", "Вы мертвы — сначала возродитесь." },
    pull_host_nochar   = { "You have no character in the world.", "У вас нет персонажа в мире." },
    pull_host_vehicle  = { "Get out of the vehicle first.", "Сначала выйдите из транспорта." },
    pull_host_air      = { "Stand on the ground: you're in the air, in water or on a ladder.",
                           "Встаньте на землю: вы в воздухе, в воде или на лестнице." },
    -- the pulled player's
    pull_done_client   = { "The host moved you next to them.", "Хост перенёс вас к себе." },
    pull_failed_client = { "The host tried to move you next to them, but there was no free spot.",
                           "Хост пытался перенести вас к себе, но рядом с ним не нашлось места." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end
local REFUSE_RU = {
    nopawn = "нет персонажа", dead = "персонаж мёртв", vehicle = "персонаж в транспорте",
    soon = "слишком часто", nospot = "нет места", down = "персонаж лежит раненый",
}

local function in_vehicle(pawn)
    local vdc = ue.prop(pawn, "VehicleDrivingComponent")
    return ue.valid(ue.prop(vdc, "Vehicle"))
end

-- In a vehicle seat: sdc_vehicles' own seat of a remote player (host), the
-- game's driving state or its flag (InVehicle? can be set without Vehicle,
-- sdc_vehicles @608), or an attachment (a passenger is attached with
-- K2_AttachToActor; a teleport would leave it attached).
local function seated(pawn, key)
    if key then
        local veh = package.loaded["sdc_vehicles"]
        if type(veh) == "table" and type(veh.seat_of) == "function" then
            local ok, seat = pcall(veh.seat_of, key)
            if ok and seat ~= nil then return true end
        end
    end
    if in_vehicle(pawn) or ue.prop(pawn, "InVehicle?") == true then return true end
    return ue.valid(ue.try(function() return pawn:GetAttachParentActor() end))
end

-- CharacterMovement:IsFalling() / IsSwimming() (the game's own checks,
-- BP_PlayerCharacter @57789 / @57835).
local function moving_is(pawn, fn)
    local cmc = ue.prop(pawn, "CharacterMovement")
    if not ue.valid(cmc) then return false end
    local ok, v = pcall(function() return cmc[fn](cmc) end)
    return ok and v == true
end

-- Velocity to zero (UMovementComponent.StopMovementImmediately).
local function stop_movement(pawn)
    local cmc = ue.prop(pawn, "CharacterMovement")
    if not ue.valid(cmc) then return false end
    return (pcall(function() cmc:StopMovementImmediately() end))
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

-- ---------------------------------------------------------------------------
-- Host: a free spot next to the host
-- ---------------------------------------------------------------------------
-- 8 directions at SPOT.dist around the host (from index * 72 degrees, 45 apart).
-- A direction counts when a capsule of the player's size (BP_PlayerCharacter
-- CollisionCylinder: radius 30, half height 82) sweeps there from the host on
-- the 'Pawn' profile without a hit (the friend lands on the host's side of a
-- wall, not on a roof), and a line down from there finds ground no more than
-- SPOT.below under the host's feet (no cliff edge, pier or stairwell). The
-- spot is SPOT.lift above that ground. None: near_host_spot (as before).
local CAPSULE = { r = 30, half = 82 }
local SPOT = { dist = 160, dirs = 8, step = 45, up = 40, below = 150, lift = 100 }
local NO_COLOR = { R = 0, G = 0, B = 0, A = 0 }

local function yaw_to(from, to)
    return math.deg(math.atan(to.Y - from.Y, to.X - from.X))
end

-- Returns spot, yaw, direction number; or nil, why.
local function clear_spot(index, hp, pawn)
    local ksl = ue.ksl()
    local hl = ue.location(hp)
    if not ksl or not hl then return nil, "no trace library / host location" end
    local ignore = { hp }
    if pawn then ignore[2] = pawn end
    local feet = hl.Z - CAPSULE.half
    local from = { X = hl.X, Y = hl.Y, Z = hl.Z + SPOT.up }
    local base = ((index or 1) * 72) % 360
    local profile = FName("Pawn")
    for i = 0, SPOT.dirs - 1 do
        local ang = math.rad(base + i * SPOT.step)
        local cand = { X = hl.X + math.cos(ang) * SPOT.dist, Y = hl.Y + math.sin(ang) * SPOT.dist, Z = from.Z }
        local hit = {}
        local ok, blocked = pcall(function()
            return ksl:CapsuleTraceSingleByProfile(hp, from, cand, CAPSULE.r, CAPSULE.half, profile, false, ignore, 0,
                hit, true, NO_COLOR, NO_COLOR, 0.0)
        end)
        if not ok then return nil, "capsule trace: " .. tostring(blocked) end
        if blocked ~= true then
            local ghit = {}
            local okg, ground = pcall(function()
                return ksl:LineTraceSingle(hp, cand, { X = cand.X, Y = cand.Y, Z = feet - SPOT.below }, 0, false, ignore, 0,
                    ghit, true, NO_COLOR, NO_COLOR, 0.0)
            end)
            if not okg then return nil, "ground trace: " .. tostring(ground) end
            local gp = ground == true and (ue.vec(ghit.ImpactPoint) or ue.vec(ghit.Location)) or nil
            if gp then
                local spot = { X = cand.X, Y = cand.Y, Z = gp.Z + SPOT.lift }
                return spot, yaw_to(spot, hl), i + 1
            end
        end
    end
    return nil, "no clear direction"
end

-- The spot for a move next to the host: loc, yaw, how (for the log).
local function pick_spot(r, hp, pawn)
    local spot, yaw_or_why, dir = nil, nil, nil
    if hp then
        local ok
        ok, spot, yaw_or_why, dir = pcall(clear_spot, r.index, hp, pawn)
        if not ok then spot, yaw_or_why = nil, tostring(spot) end
    end
    if spot then return spot, yaw_or_why, "clear spot, direction " .. tostring(dir) end
    local loc, yaw = near_host_spot(r.index, 0)
    return loc, yaw, "near_host_spot (" .. tostring(yaw_or_why or "no host character") .. ")"
end

-- ---------------------------------------------------------------------------
-- Host: the landing guard
-- ---------------------------------------------------------------------------
-- K2_TeleportTo keeps the velocity, and the host's copy of a client's
-- character simulates the client's moves itself (sdc_sync only makes it take
-- the client's position): a player pulled out of a long fall under the map
-- lands next to the host at that speed. BP_PlayerCharacter.OnLanded
-- (@122799-124357) reads GetVelocity().Z: -Vz >= 1300 deals 15, >= 1500 a
-- broken bone, a 1.5 s freeze and 30-80, >= 2200 999; the damage counts on the
-- host's copy only (ApplyDamage needs the authority). GravityScale 1.75
-- (~1715 cm/s²) gets a zeroed copy back to 1300 in ~0.76 s, longer than a
-- slow client may need for the move to arrive, so for GUARD.s after a move
-- the copy's fall speed is zeroed whenever it is beyond GUARD.vz. The guard
-- ends early once the copy stood within GUARD.near of the spot, not falling,
-- for GUARD.calm_s; at once when the record, the character or the host role
-- is gone.
local GUARD = { s = 4, step_ms = 100, vz = -600, near = 400, calm_s = 0.5 }
local guards = {}         -- [session key] = { r, spot, till, where, zeroed, fastest, calm }
local guard_running = false

local function guard_step()
    local now = os.clock()
    local any = false
    for key, g in pairs(guards) do
        local r = S and S.role == "host" and S.remote and S.remote[key] or nil
        local pawn = (r ~= nil and r == g.r and ue.valid(r.pc)) and ue.pawn_of(r.pc) or nil
        local done = nil
        if not pawn or is_dead(pawn) then
            done = "the character is gone"
        else
            local cmc = ue.prop(pawn, "CharacterMovement")
            local v = ue.valid(cmc) and ue.vec(ue.prop(cmc, "Velocity")) or nil
            if v and v.Z < GUARD.vz then
                if pcall(function() cmc:StopMovementImmediately() end) then g.zeroed = g.zeroed + 1 end
                if v.Z < g.fastest then g.fastest = v.Z end
            end
            local loc = ue.location(pawn)
            if loc and dist(loc, g.spot) <= GUARD.near and not moving_is(pawn, "IsFalling") then
                g.calm = g.calm or now
            else
                g.calm = nil
            end
            if g.calm and now - g.calm >= GUARD.calm_s then
                done = "landed"
            elseif now >= g.till then
                done = "time up"
            end
        end
        if done then
            guards[key] = nil
            log.info("host: landing guard (%s) for %s ended: %s; fall speed zeroed %d time(s)%s", g.where,
                tostring(g.r.name), done, g.zeroed, g.fastest < 0 and string.format(" (fastest %.0f cm/s)", g.fastest) or "")
        else
            any = true
        end
    end
    guard_running = any
    if any then ue.delay("move-guard", GUARD.step_ms, guard_step) end
end

local function guard_start(r, spot, where)
    guards[r.key] = { r = r, spot = spot, till = os.clock() + GUARD.s, where = where, zeroed = 0, fastest = 0 }
    if not guard_running then
        guard_running = true
        ue.delay("move-guard", GUARD.step_ms, guard_step)
    end
end

-- One host-driven move of remote player r's character to `loc`: the fall
-- speed of the host's copy to zero, the move (UNSTUCKTO to the client, or the
-- host's own teleport of its copy with client_movement_authority off), the
-- landing guard, and sdc_persist told (its fall check and a late id's move to
-- the saved spot would undo this one). Returns moved (server: the teleport's
-- result; client: true = sent) and the mode ("client" | "server"). `extra`
-- (a move to another player: that player's name) goes after the id.
local function send_move(r, pawn, loc, yaw, where, id, extra)
    stop_movement(pawn)
    local pers = package.loaded["sdc_persist"]
    if type(pers) == "table" and type(pers.note_moved) == "function" then pcall(pers.note_moved, r.key) end
    local moved, mode = true, "client"
    if cfg.get("client_movement_authority") then
        local x, y, z, w = string.format("%.0f", loc.X), string.format("%.0f", loc.Y), string.format("%.0f", loc.Z),
            string.format("%.0f", yaw or 0)
        if id and extra then
            net.send_to(r.pc, "UNSTUCKTO", x, y, z, w, where, id, extra)
        elseif id then
            net.send_to(r.pc, "UNSTUCKTO", x, y, z, w, where, id)
        else
            net.send_to(r.pc, "UNSTUCKTO", x, y, z, w, where)
        end
    else
        mode = "server"
        local attempt
        moved, attempt = teleport_near(pawn, loc, yaw)
        stop_movement(pawn)
        local freed = free_movement(pawn)
        log.info("host: move (%s) of %s: K2_TeleportTo %.0f,%.0f,%.0f moved=%s (try %s), movement freed=%s",
            where, r.name, loc.X, loc.Y, loc.Z, tostring(moved), tostring(attempt), tostring(freed))
    end
    guard_start(r, loc, where)
    return moved, mode
end

-- sdc_persist: a remote player's character next to the host (its fall check
-- of a character put at the saved spot). Returns moved, spot.
function M.host_move(r, where)
    if not S or S.role ~= "host" or not r or not ue.valid(r.pc) then return false end
    local pawn = ue.pawn_of(r.pc)
    if not pawn then return false end
    local loc, yaw, how = pick_spot(r, ue.local_pawn(), pawn)
    if not loc then return false end
    local moved, mode = send_move(r, pawn, loc, yaw, where or "host")
    log.info("host: %s moved next to the host (%s): spot %.0f,%.0f,%.0f (%s)", r.name, mode, loc.X, loc.Y, loc.Z, how)
    return moved, loc
end

-- Client: co-op panel button / console sdcoop_unstuck. where = "host" | "start".
function M.request_unstuck(where)
    where = where == "start" and "start" or "host"
    if not S or S.role ~= "client" then log.say("unstuck_not_client", "warn") return false end
    local pawn = ue.local_pawn()
    if not pawn then log.say("no_local_pawn", "warn") return false end
    if is_dead(pawn) then log.say("unstuck_dead", "warn") return false end
    if downed(pawn) then log.say("unstuck_down", "warn") return false end
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
    if downed(pawn) then refuse("down") return end
    if in_vehicle(pawn) then refuse("vehicle") return end
    local now = os.time()
    if now - (r.unstuck_at or -1000) < UNSTUCK_HOST_MIN_S then refuse("soon") return end
    r.unstuck_at = now
    local loc, yaw, how
    if where == "start" then
        loc, yaw = random_spot()
        how = "a start point"
    end
    if not loc then loc, yaw, how = pick_spot(r, ue.local_pawn(), pawn) end
    if not loc then
        loc, yaw = random_spot()
        how = "a start point (no host character)"
    end
    if not loc then refuse("nospot") return end
    local moved, mode = send_move(r, pawn, loc, yaw, where)
    if mode == "client" then
        log.info("host: unstuck (%s) for %s: spot %.0f,%.0f,%.0f (%s) sent (the client moves itself, client-authoritative movement)",
            where, r.name, loc.X, loc.Y, loc.Z, how)
        return
    end
    net.send_to(pc, "UNSTUCKOK", moved and "ok" or "failed", where)
end

-- ---------------------------------------------------------------------------
-- Host: pull a player to the host
-- ---------------------------------------------------------------------------

-- sdc_persist: this player's saved character still being put back (or its
-- id not here yet): its own move to the saved spot would undo a pull.
local function restoring(key)
    local pers = package.loaded["sdc_persist"]
    if type(pers) ~= "table" or type(pers.restoring) ~= "function" then return false end
    local ok, v = pcall(pers.restoring, key)
    return ok and v == true
end

-- The pull's answer, from the client (PULLACK) or the host's own check.
local PULL_SAY = {
    ok = { "pull_done_host", "ok", 5 }, failed = { "pull_failed_host", "warn", 8 },
    dead = { "pull_dead", "warn", 6 }, vehicle = { "pull_vehicle", "warn", 6 }, nopawn = { "pull_no_char", "warn", 6 },
    down = { "pull_down", "warn", 6 },   -- sdc_down: the player went down meanwhile
}

-- No PULLACK within PULL_ACK_MS (an older client, or the answer lost): the
-- host's copy within 600 cm (3D) of the spot AND more than 300 cm from where
-- it was. Silent (log only) when the player left, died or the world changed.
local function pull_unanswered(key, id)
    if not S or S.role ~= "host" then return end
    local r = S.remote and S.remote[key]
    local pr = r and r.pull
    if not pr or pr.id ~= id then return end
    r.pull = nil
    local pawn = ue.valid(r.pc) and ue.pawn_of(r.pc) or nil
    if not pawn or is_dead(pawn) then
        log.info("host: pull #%s of %s: no answer, and the character is gone or dead: nothing to say", id, r.name)
        return
    end
    local loc = ue.location(pawn)
    local near = loc ~= nil and dist(loc, pr.spot) <= 600
    local moved = loc ~= nil and pr.from ~= nil and dist(loc, pr.from) > 300
    log.info("host: pull #%s of %s: no answer from the client in %d s; the host's copy is %.0f cm from the spot, %.0f cm from where it was",
        id, r.name, PULL_ACK_MS // 1000, loc and dist(loc, pr.spot) or -1, (loc and pr.from) and dist(loc, pr.from) or -1)
    if near and moved then
        log.say("pull_done_host", "ok", 5, r.name)
    else
        log.say("pull_unconfirmed", "warn", 6, r.name)
    end
end

-- Host: player `key`'s character next to the host. Returns true (the move
-- was sent / done), or false and the refusal code; each refusal tells the
-- host why (the player is not told). `shown`: the name the caller showed
-- for that player (the F7 row, the console's roster), said when its record
-- is gone already. The cooldown is the client's own unstuck one (r.unstuck_at).
function M.pull_to_host(key, shown)
    if not S or S.role ~= "host" then return false, "not_host" end
    local r = S.remote and S.remote[key]
    shown = shown ~= nil and tostring(shown) or ""
    local name = r and tostring(r.name) or (shown ~= "" and shown or nil)
    local function refuse(code, ...)
        log.info("host: pull of %s refused: %s", name or tostring(key), code)
        log.say("pull_" .. code, "warn", 6, ...)
        return false, code
    end
    if not r or r.kicked or r.access == "refused" or not ue.valid(r.pc) then
        if not name then
            -- no name for it: a text without one (not the controller's name)
            log.info("host: pull of %s refused: gone", tostring(key))
            log.say("pull_gone_anon", "warn", 6)
            return false, "gone"
        end
        return refuse("gone", name)
    end
    if r.access == "wait" then return refuse("waiting", name) end
    local pawn = ue.pawn_of(r.pc)
    if r.dead or (pawn and is_dead(pawn)) then return refuse("dead", name) end
    if pawn and downed(pawn) then return refuse("down", name) end
    if not pawn then return refuse((r.hello and r.spawned_once) and "no_char" or "joining", name) end
    if restoring(key) then return refuse("joining", name) end
    if seated(pawn, key) then return refuse("vehicle", name) end
    if ue.prop(pawn, "ClimbingLadder?") == true then return refuse("ladder", name) end
    if ue.prop(pawn, "Sitting?") == true then return refuse("sitting", name) end
    local hp = ue.local_pawn()
    if not hp then return refuse("host_nochar") end
    if is_dead(hp) then return refuse("host_dead") end
    if downed(hp) then return refuse("host_down") end
    if seated(hp) then return refuse("host_vehicle") end
    if ue.prop(hp, "ClimbingLadder?") == true or moving_is(hp, "IsFalling") or moving_is(hp, "IsSwimming") then
        return refuse("host_air")
    end
    local now = os.time()
    local left = UNSTUCK_HOST_MIN_S - (now - (r.unstuck_at or -1000))
    if left > 0 then return refuse("wait", name, left) end
    local spot, yaw, how = pick_spot(r, hp, pawn)
    if not spot then return refuse("failed_host", name) end
    r.unstuck_at = now
    pull_seq = pull_seq + 1
    local id = tostring(pull_seq)
    local from = ue.location(pawn)
    local moved, mode = send_move(r, pawn, spot, yaw, "pull", id)
    log.info("host: pull #%s of %s from %s m away: spot %.0f,%.0f,%.0f (%s), %s", id, name,
        from and string.format("%.0f", dist(from, spot) / 100) or "?", spot.X, spot.Y, spot.Z, how,
        mode == "client" and "sent (the client moves itself)" or ("the host's teleport moved=" .. tostring(moved)))
    if mode == "client" then
        r.pull = { id = id, spot = spot, from = from, at = os.clock() }
        log.say("pull_asked", "info", 4, name)
        ue.delay("pull-check", PULL_ACK_MS, function() pull_unanswered(key, id) end)
    else
        net.send_to(r.pc, "UNSTUCKOK", moved and "ok" or "failed", "pull")
        local s = PULL_SAY[moved and "ok" or "failed"]
        log.say(s[1], s[2], s[3], name)
    end
    return true
end

-- Host: PULLACK|result|pull|id from the pulled client.
local function host_pull_ack(f, pc)
    if not S or S.role ~= "host" then return end
    local r = M.record_for(pc)
    local pr = r and r.pull
    if not pr or pr.id ~= f[3] then
        log.info("host: pull answer %s (#%s) from %s: no pull waits for it", tostring(f[1]), tostring(f[3]),
            r and r.name or "?")
        return
    end
    r.pull = nil
    local s = PULL_SAY[f[1] or ""] or PULL_SAY.nopawn
    log.info("host: pull #%s of %s: the client says %s after %.1f s", pr.id, r.name, tostring(f[1]), os.clock() - pr.at)
    log.say(s[1], s[2], s[3], r.name)
end

-- Console sdcoop_pull <name | row number in the F7 list> (host). `roster`:
-- sdc_session.roster() (the F7 list's order, the host first). Returns the reply.
function M.pull_console(query, roster)
    if not S or S.role ~= "host" then return "sdcoop_pull: only the host can pull players" end
    local q = tostring(query or ""):match("^%s*(.-)%s*$")
    if q == "" then return "usage: sdcoop_pull <name | row number in the F7 list (the host is 1)>" end
    local key, shown = nil, nil
    local n = tonumber(q)
    if n and type(roster) == "table" and roster[n] then key, shown = roster[n].key, roster[n].name end
    if not key then
        for k, r in pairs(S.remote or {}) do
            if tostring(r.name):lower() == q:lower() then key, shown = k, r.name end
        end
    end
    if not key then return "sdcoop_pull: no player " .. q end
    local ok, why = M.pull_to_host(key, shown)
    -- the record gone: the roster's name, never the session key (a controller's name)
    local rec = (S.remote or {})[key]
    local name = rec and rec.name or shown or ("row " .. q)
    return ok and ("sdcoop_pull: moving " .. tostring(name)) or ("sdcoop_pull: " .. tostring(name) .. " not moved: " .. tostring(why))
end

-- ---------------------------------------------------------------------------
-- "Go to a player" (0.7.3 wave): any player next to any other one
-- ---------------------------------------------------------------------------
-- Console sdcoop_goto <name | row number in the F7 list> (the panel's button
-- is still to come). Host setting teleport_to_players (default off) lets
-- clients use it; the host's own move to a client needs no setting (it can
-- pull them anyway).
--   client -> host : GOTO|<name>                    move me next to <name>
--   host -> target : GOTOASK|<id>|<asker's name>   (another client: it agrees
--                                                   first, sdcoop_goto_yes / _no)
--   target -> host : GOTOANS|<id>|<1|0>
--   host -> asker  : GOTOST|<code>|<name>[|<s>]    asked / refused / done (texts goto_<code>)
--   host -> asker  : UNSTUCKTO|x|y|z|yaw|goto|<id>|<name> (the shared host move:
--                    the landing guard, sdc_persist told; the asker answers
--                    GOTOACK|ok|failed|...|<id>, and then the target is told)
-- Without client_movement_authority the host teleports its copy and says
-- the result (GOTOST|done|failed). To the host: no question. The cooldown is
-- the unstuck / pull one (r.unstuck_at); an unanswered ask ends after
-- GT.ASK_S (GOTOST|noanswer). The one moved is not taken off a ladder or a
-- seat (as the pull). A client whose GOTO gets no word at all in GT.WAIT_S
-- (a host whose mod has no GOTO says nothing) is told so.
local GT = { seq = 0, reqs = {}, ask = nil, ASK_S = 30, WAIT_S = 8, wait = nil, wait_seq = 0 }
M.GOTO = GT   -- tests

local GOTO_TEXT = {
    goto_off           = { "Moving to other players is off on the host.", "Перенос к другим игрокам выключен у хоста." },
    goto_gone          = { "%s is not in the world.", "Игрока %s нет в мире." },
    goto_self          = { "That's you.", "Это вы." },
    goto_nopawn        = { "You have no character in the world.", "У вас нет персонажа в мире." },
    goto_dead          = { "Your character is dead: respawn first.", "Персонаж мёртв — сначала возродитесь." },
    goto_vehicle       = { "Leave the vehicle first.", "Сначала выйдите из транспорта." },
    goto_soon          = { "Moving will be available again in %d s.", "Перенос снова будет доступен через %d с." },
    goto_target_nochar = { "%s has no character in the world yet.", "У игрока %s ещё нет персонажа в мире." },
    goto_target_dead   = { "%s is dead.", "Игрок %s мёртв." },
    goto_target_vehicle = { "%s is in a vehicle.", "Игрок %s в транспорте." },
    goto_target_air    = { "%s is in the air, in water or on a ladder: try again in a moment.",
                           "Игрок %s сейчас в воздухе, в воде или на лестнице — попробуйте чуть позже." },
    goto_pending       = { "You already asked %s: wait for the answer.", "Вы уже спросили игрока %s — дождитесь ответа." },
    goto_asked         = { "Asking %s whether you may come...", "Спрашиваю игрока %s, можно ли к нему…" },
    goto_denied        = { "%s did not let you come.", "Игрок %s не разрешил перенос." },
    goto_noanswer      = { "%s did not answer.", "Игрок %s не ответил на запрос переноса." },
    goto_nospot        = { "No free spot next to %s.", "Рядом с игроком %s нет свободного места." },
    goto_done          = { "You were moved to %s.", "Вы перенесены к игроку %s." },
    goto_failed        = { "Couldn't move you to %s: no free spot.", "Не удалось перенести вас к игроку %s: нет свободного места." },
    goto_arrived       = { "%s moved to you.", "%s переместился к вам." },
    goto_ask           = { "%s wants to move to you. Allow: console (~) sdcoop_goto_yes; refuse: sdcoop_goto_no.",
                           "%s хочет переместиться к вам. Разрешить: консоль (~) → sdcoop_goto_yes, отказать: sdcoop_goto_no." },
    goto_allowed_you   = { "%s may come to you.", "Вы разрешили игроку %s переместиться к вам." },
    -- the one moved (a client or the host itself), as the pull's checks
    goto_ladder        = { "Get off the ladder first.", "Сначала слезьте с лестницы." },
    goto_sitting       = { "Stand up first.", "Сначала встаньте." },
    -- no word from the host at all (its mod has no GOTO: an older version)
    goto_noreply       = { "The host did not answer: its mod may be an older version without moving to players.",
                           "Хост не ответил на запрос переноса — возможно, у него старая версия мода без этой функции." },
}
for k, v in pairs(GOTO_TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end
local GOTO_KIND = { asked = "info", done = "ok" }

-- Host: a free spot next to `anchor` (a character) for remote player r:
-- the clear spot search, else next to it unchecked (the client's own
-- teleport still rises until it fits). Returns spot, yaw, how.
function GT.spot_near(r, anchor, pawn)
    local ok, spot, yaw, dir = pcall(clear_spot, r and r.index or 1, anchor, pawn)
    if ok and spot then return spot, yaw, "clear spot, direction " .. tostring(dir) end
    local loc = ue.location(anchor)
    if not loc then return nil end
    local ang = math.rad((((r and r.index) or 1) * 72) % 360)
    return { X = loc.X + math.cos(ang) * 160, Y = loc.Y + math.sin(ang) * 160, Z = loc.Z + 80 }, 0,
        "next to it, unchecked (" .. tostring(ok and yaw or spot) .. ")"
end

-- Why character `p` cannot be gone to right now (nil = it can).
local function goto_target_why(p, key)
    if downed(p) then return "target_down" end
    if seated(p, key) then return "target_vehicle" end
    if ue.prop(p, "ClimbingLadder?") == true or moving_is(p, "IsFalling") or moving_is(p, "IsSwimming") then
        return "target_air"
    end
    return nil
end

-- Why character `p` (the one moved) cannot go right now (nil = it can): as
-- the pull, not off a ladder or out of a seat (a teleport leaves the game's
-- climbing / sitting state on). In the air or in water it can: the move
-- stops it first.
local function goto_mover_why(p)
    if downed(p) then return "down" end
    if ue.prop(p, "ClimbingLadder?") == true then return "ladder" end
    if ue.prop(p, "Sitting?") == true then return "sitting" end
    return nil
end

-- A name in lower case, Russian letters too (string.lower knows ASCII only):
-- UTF-8 А-П D0 90-9F -> D0 B0-BF, Р-Я D0 A0-AF -> D1 80-8F, Ё D0 81 -> D1 91.
function GT.lower(s)
    s = tostring(s or ""):lower()
    s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
    s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
    return (s:gsub("\208\129", "\209\145"))
end

-- Host: the record of the player called `q` (any case), or "host", or nil.
function GT.find(q)
    local low = GT.lower(q)
    if low == "" then return nil end
    if GT.lower(cfg.player_name()) == low then return "host" end
    for _, r in pairs(S.remote or {}) do
        if GT.lower(r.name) == low then return r end
    end
    return nil
end

-- Host: move asker ra next to `anchor` (the host's character, or target
-- record rb's). `name`: the target's name for the asker.
local function goto_move(ra, pawn, anchor, name, rb)
    local spot, yaw, how = GT.spot_near(ra, anchor, pawn)
    if not spot then
        net.send_to(ra.pc, "GOTOST", "nospot", name)
        return false
    end
    ra.unstuck_at = os.time()
    GT.seq = GT.seq + 1
    local id = "g" .. GT.seq
    local moved, mode = send_move(ra, pawn, spot, yaw, "goto", id, name)
    log.info("host: %s goes to %s: spot %.0f,%.0f,%.0f (%s), %s", tostring(ra.name), tostring(name), spot.X, spot.Y,
        spot.Z, how, mode == "client" and "sent (the client moves itself)" or ("the host's teleport moved=" .. tostring(moved)))
    if mode == "client" then
        -- the target is told once the asker's GOTOACK says it moved
        ra.goto_move = { id = id, to = rb and rb.key or "host", name = name }
        return true
    end
    net.send_to(ra.pc, "GOTOST", moved and "done" or "failed", name)
    if moved then
        if rb then net.send_to(rb.pc, "MSG", "goto_arrived", ra.name) else log.say("goto_arrived", "ok", 5, ra.name) end
    end
    return moved
end

-- Host: GOTO|<name> from a client.
local function host_goto(f, pc)
    if not S or S.role ~= "host" then return end
    local ra = api.remote_record(pc)
    local q = tostring(f[1] or "")
    local function refuse(code, name, extra)
        log.info("host: %s asked to go to %s: %s", tostring(ra.name), q, code)
        if extra then net.send_to(pc, "GOTOST", code, name or q, extra) else net.send_to(pc, "GOTOST", code, name or q) end
    end
    if cfg.get("teleport_to_players") ~= true then return refuse("off") end
    local target = GT.find(q)
    if not target or (target ~= "host" and (target.kicked or not ue.valid(target.pc))) then return refuse("gone") end
    if target == ra then return refuse("self") end
    local pawn = ue.pawn_of(pc)
    if not pawn then return refuse("nopawn") end
    if ra.dead or is_dead(pawn) then return refuse("dead") end
    if seated(pawn, ra.key) then return refuse("vehicle") end
    local mwhy = goto_mover_why(pawn)
    if mwhy then return refuse(mwhy) end
    local now = os.time()
    local left = UNSTUCK_HOST_MIN_S - (now - (ra.unstuck_at or -1000))
    if left > 0 then return refuse("soon", nil, tostring(left)) end
    if target == "host" then
        local hp = ue.local_pawn()
        local name = cfg.player_name()
        if not hp then return refuse("target_nochar", name) end
        if is_dead(hp) then return refuse("target_dead", name) end
        local why = goto_target_why(hp, nil)
        if why then return refuse(why, name) end
        return goto_move(ra, pawn, hp, name, nil)
    end
    local tp = ue.pawn_of(target.pc)
    if not target.hello or target.access == "wait" or not tp or restoring(target.key) then
        return refuse("target_nochar", target.name)
    end
    if target.dead or is_dead(tp) then return refuse("target_dead", target.name) end
    local why = goto_target_why(tp, target.key)
    if why then return refuse(why, target.name) end
    local pend = ra.goto_req
    if pend and GT.reqs[pend.id] == pend and now - pend.at < GT.ASK_S then return refuse("pending", pend.name) end
    GT.seq = GT.seq + 1
    local id = "a" .. GT.seq
    local req = { id = id, from = ra.key, to = target.key, name = target.name, at = now }
    GT.reqs[id], ra.goto_req = req, req
    net.send_to(target.pc, "GOTOASK", id, ra.name)
    refuse("asked", target.name)
    ue.delay("goto-ask", GT.ASK_S * 1000, function() GT.expire(id) end)
end

-- Host: an ask nobody answered in GT.ASK_S.
function GT.expire(id)
    local req = GT.reqs[id]
    if not req or not S or S.role ~= "host" then return end
    GT.reqs[id] = nil
    local ra = S.remote and S.remote[req.from]
    if ra and ra.goto_req == req then ra.goto_req = nil end
    log.info("host: no answer from %s to %s's ask to come (%s)", tostring(req.name), ra and tostring(ra.name) or "?", id)
    if ra and ue.valid(ra.pc) then net.send_to(ra.pc, "GOTOST", "noanswer", req.name) end
end

-- Host: GOTOANS|<id>|<1|0> from the asked player.
local function host_goto_answer(f, pc)
    if not S or S.role ~= "host" then return end
    local req = GT.reqs[f[1] or ""]
    local rb = M.record_for(pc)
    if not req or not rb or rb.key ~= req.to then
        log.info("host: an answer to ask %s from %s: none waits for it", tostring(f[1]), rb and tostring(rb.name) or "?")
        return
    end
    GT.reqs[req.id] = nil
    local ra = S.remote and S.remote[req.from]
    if ra and ra.goto_req == req then ra.goto_req = nil end
    if not ra or not ue.valid(ra.pc) then return end
    local yes = f[2] == "1"
    log.info("host: %s %s %s to come", tostring(rb.name), yes and "lets" or "does not let", tostring(ra.name))
    if not yes then
        net.send_to(ra.pc, "GOTOST", "denied", rb.name)
        return
    end
    -- both again: a minute may have passed
    local pawn, tp = ue.pawn_of(ra.pc), ue.pawn_of(rb.pc)
    if not pawn then return net.send_to(ra.pc, "GOTOST", "nopawn", rb.name) end
    if ra.dead or is_dead(pawn) then return net.send_to(ra.pc, "GOTOST", "dead", rb.name) end
    if seated(pawn, ra.key) then return net.send_to(ra.pc, "GOTOST", "vehicle", rb.name) end
    local mwhy = goto_mover_why(pawn)
    if mwhy then return net.send_to(ra.pc, "GOTOST", mwhy, rb.name) end
    if not tp then return net.send_to(ra.pc, "GOTOST", "target_nochar", rb.name) end
    if rb.dead or is_dead(tp) then return net.send_to(ra.pc, "GOTOST", "target_dead", rb.name) end
    local why = goto_target_why(tp, rb.key)
    if why then return net.send_to(ra.pc, "GOTOST", why, rb.name) end
    goto_move(ra, pawn, tp, rb.name, rb)
end

-- Host: GOTOACK|<result>|<id> from the asker after its own teleport.
local function host_goto_ack(f, pc)
    if not S or S.role ~= "host" then return end
    local ra = M.record_for(pc)
    local mv = ra and ra.goto_move
    if not mv or mv.id ~= f[2] then return end
    ra.goto_move = nil
    log.info("host: %s's move to %s: %s", tostring(ra.name), tostring(mv.name), tostring(f[1]))
    if f[1] ~= "ok" then return end
    if mv.to == "host" then
        log.say("goto_arrived", "ok", 5, ra.name)
    else
        local rb = S.remote and S.remote[mv.to]
        if rb and ue.valid(rb.pc) then net.send_to(rb.pc, "MSG", "goto_arrived", ra.name) end
    end
end

-- Host: its own character next to remote player `key` (sdcoop_goto on the
-- host). Returns true, or false and the refusal code (said to the host).
function M.host_goto(key, shown)
    if not S or S.role ~= "host" then return false, "not_host" end
    local r = S.remote and S.remote[key]
    local name = r and tostring(r.name) or tostring(shown or "?")
    local function refuse(code, ...)
        log.info("host: going to %s refused: %s", name, code)
        log.say(code:find("^pull_") and code or ("goto_" .. code), "warn", 6, ...)
        return false, code
    end
    if not r or r.kicked or not ue.valid(r.pc) then return refuse("gone", name) end
    local tp = ue.pawn_of(r.pc)
    if not r.hello or r.access == "wait" or not tp or restoring(key) then return refuse("target_nochar", name) end
    if r.dead or is_dead(tp) then return refuse("target_dead", name) end
    local why = goto_target_why(tp, key)
    if why then return refuse(why, name) end
    local hp = ue.local_pawn()
    if not hp then return refuse("pull_host_nochar") end
    if is_dead(hp) then return refuse("pull_host_dead") end
    if seated(hp) then return refuse("pull_host_vehicle") end
    local mwhy = goto_mover_why(hp)
    if mwhy then return refuse(mwhy) end
    local spot, yaw, how = GT.spot_near(r, tp, hp)
    if not spot then return refuse("nospot", name) end
    stop_movement(hp)
    local moved, attempt = teleport_near(hp, spot, yaw)
    stop_movement(hp)
    local freed = free_movement(hp)
    log.info("host: going to %s: spot %.0f,%.0f,%.0f (%s), moved=%s (try %s), movement freed=%s", name, spot.X, spot.Y,
        spot.Z, how, tostring(moved), tostring(attempt), tostring(freed))
    if not moved then return refuse("failed", name) end
    log.say("goto_done", "ok", 5, name)
    net.send_to(r.pc, "MSG", "goto_arrived", cfg.player_name())
    return true
end

-- Console sdcoop_goto <name | row number in the F7 list> (host or client).
-- `roster`: sdc_session.roster(). Returns the console reply.
function M.goto_console(query, roster)
    if not S or (S.role ~= "host" and S.role ~= "client") then return "sdcoop_goto: only in a co-op world" end
    local q = tostring(query or ""):match("^%s*(.-)%s*$")
    if q == "" then return "usage: sdcoop_goto <name | row number in the F7 list (the host is 1)>" end
    local n = tonumber(q)
    local entry = nil
    if n and type(roster) == "table" and roster[n] then
        entry = roster[n]
    elseif type(roster) == "table" then
        for _, e in ipairs(roster) do
            if GT.lower(e.name) == GT.lower(q) then entry = e break end
        end
    end
    if S.role == "host" then
        local key = entry and entry.key
        if not key then
            local r = GT.find(q)
            key = type(r) == "table" and r.key or nil
        end
        if not key then return "sdcoop_goto: no other player " .. q end
        local ok, why = M.host_goto(key, entry and entry.name or q)
        return ok and "sdcoop_goto: moved" or ("sdcoop_goto: not moved: " .. tostring(why))
    end
    local name = entry and entry.name or q
    if entry and entry.me then
        log.say("goto_self", "warn", 4)
        return "sdcoop_goto: that is you"
    end
    local pawn = ue.local_pawn()
    if not pawn then log.say("goto_nopawn", "warn", 5) return "sdcoop_goto: no own character" end
    if is_dead(pawn) then log.say("goto_dead", "warn", 5) return "sdcoop_goto: dead" end
    if in_vehicle(pawn) then log.say("goto_vehicle", "warn", 5) return "sdcoop_goto: in a vehicle" end
    net.send_to_host("GOTO", name)
    log.info("client: asked the host to go to %s", tostring(name))
    -- a host whose mod has no GOTO says nothing at all (GT.unanswered)
    GT.wait_seq = GT.wait_seq + 1
    local seq = GT.wait_seq
    GT.wait = { seq = seq, name = name, cs = S.client }
    ue.delay("goto-wait", GT.WAIT_S * 1000, function() GT.unanswered(seq) end)
    return "sdcoop_goto: asked the host to move you to " .. tostring(name)
end

-- Client: no word at all from the host (GOTOST, or its move) on the own
-- GOTO in GT.WAIT_S: an older host's mod without "go to a player".
function GT.unanswered(seq)
    local w = GT.wait
    if not w or w.seq ~= seq then return end
    GT.wait = nil
    -- left, or another connection since: nothing to say
    if not S or S.role ~= "client" or S.client ~= w.cs then return end
    log.info("client: no word from the host on going to %s in %d s (the host's mod version %s)", tostring(w.name),
        GT.WAIT_S, tostring(w.cs and w.cs.host_version))
    log.say("goto_noreply", "warn", 8)
end

-- Client: GOTOASK|<id>|<name> - another player asks to come.
local function client_goto_ask(f)
    if not S or S.role ~= "client" then return end
    GT.ask = { id = f[1], name = f[2] or "?", at = os.time() }
    log.info("client: %s asks to come here (%s); sdcoop_goto_yes / sdcoop_goto_no", tostring(f[2]), tostring(f[1]))
    log.say("goto_ask", "info", 15, f[2] or "?")
end

-- Console sdcoop_goto_yes / sdcoop_goto_no (client). Returns the reply.
function M.goto_answer(yes)
    local a = GT.ask
    if not S or S.role ~= "client" or not a or os.time() - a.at > GT.ASK_S then
        GT.ask = nil
        return "sdcoop_goto: nobody is asking to come to you"
    end
    GT.ask = nil
    net.send_to_host("GOTOANS", a.id, yes and "1" or "0")
    if yes then log.say("goto_allowed_you", "ok", 5, a.name) end
    return string.format("sdcoop_goto: %s %s", tostring(a.name), yes and "may come" or "may not come")
end

-- Client: GOTOST|<code>|<name>[|<s>] - the host's word on the own ask.
local function client_goto_status(f)
    if not S or S.role ~= "client" then return end
    local code, name = tostring(f[1] or ""), f[2] or "?"
    GT.wait = nil   -- the host answered
    local key = "goto_" .. code
    if not log.TEXT[key] then key = "goto_failed" end
    log.info("client: going to %s: %s", tostring(name), code)
    if code == "soon" then
        log.say(key, "warn", 5, tonumber(f[3]) or UNSTUCK_HOST_MIN_S)
    else
        log.say(key, GOTO_KIND[code] or "warn", 6, name)
    end
end

-- ---------------------------------------------------------------------------
-- Client: the host's move
-- ---------------------------------------------------------------------------

-- Client: UNSTUCKTO from the host. The fall speed goes to zero before and
-- after the teleport (the own copy's landing effects; the damage is the
-- host's copy's, see the landing guard).
local function client_unstuck_to(f)
    local pawn = ue.local_pawn()
    local x, y, z, yaw = tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
    local where, id = f[5], f[6]
    if not (x and y and z) then return end
    if where == "goto" then GT.wait = nil end   -- the host's answer to the own GOTO
    if where == "pull" or where == "goto" then
        -- the host checked; this side may have changed since (a race)
        local why = (not pawn and "nopawn") or (is_dead(pawn) and "dead") or (seated(pawn) and "vehicle")
            or (downed(pawn) and "down") or nil
        if why then
            log.info("client: the host's %s to %.0f,%.0f,%.0f not done here: %s", where, x, y, z, why)
            if where == "pull" then
                net.send_to_host("PULLACK", why, "pull", id or "")
            else
                net.send_to_host("GOTOACK", why, id or "")
            end
            return
        end
    end
    if not pawn then return end
    stop_movement(pawn)
    local moved, attempt = teleport_near(pawn, { X = x, Y = y, Z = z }, yaw)
    stop_movement(pawn)
    local freed = free_movement(pawn)
    log.info("client: unstuck to %.0f,%.0f,%.0f: moved=%s (try %s), movement freed=%s (%s)", x, y, z,
        tostring(moved), tostring(attempt), tostring(freed), tostring(where))
    -- "saved": sdc_persist puts a character that spawned before its id came
    -- back where the player left - nothing to announce
    if where == "saved" then return end
    if where == "pull" then
        net.send_to_host("PULLACK", moved and "ok" or "failed", "pull", id or "")
        log.say(moved and "pull_done_client" or "pull_failed_client", moved and "ok" or "warn", moved and 5 or 6)
        return
    end
    if where == "goto" then
        -- f[7]: the player gone to
        net.send_to_host("GOTOACK", moved and "ok" or "failed", id or "")
        log.say(moved and "goto_done" or "goto_failed", moved and "ok" or "warn", moved and 5 or 6, f[7] or "?")
        return
    end
    if moved then
        log.say(where == "start" and "unstuck_done_start" or "unstuck_done", "ok", 5)
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
    -- host -> client: UNSTUCKTO|x|y|z|yaw|where[|id] (client-authoritative movement)
    net.on("UNSTUCKTO", client_unstuck_to)
    -- client -> host: PULLACK|ok|failed|dead|vehicle|nopawn|pull|id (the host's pull)
    net.on("PULLACK", host_pull_ack)
    -- "go to a player" (GT above): GOTO / GOTOANS / GOTOACK to the host,
    -- GOTOASK / GOTOST to a client
    net.on("GOTO", host_goto)
    net.on("GOTOANS", host_goto_answer)
    net.on("GOTOACK", host_goto_ack)
    net.on("GOTOASK", client_goto_ask)
    net.on("GOTOST", client_goto_status)
    -- host -> client: UNSTUCKOK|ok|failed|refused|<where or reason>
    net.on("UNSTUCKOK", function(f)
        if f[1] == "ok" then
            log.say((f[2] == "pull" and "pull_done_client") or (f[2] == "start" and "unstuck_done_start") or "unstuck_done", "ok", 5)
        elseif f[1] == "failed" then
            log.say(f[2] == "pull" and "pull_failed_client" or "unstuck_failed", "warn", 6)
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
