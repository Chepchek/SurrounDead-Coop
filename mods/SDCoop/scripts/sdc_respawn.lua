-- SDCoop: the game's own per-player server flows, run for the right player.
--
-- Some of the game's server code asks for "player 0" from an object nobody
-- owns (the GameInstance, a bed component). On a listen server that is always
-- the host. sdc_ctx redirects player-0 calls made from a remote player's own
-- objects; for these, sdc_ctx asks this module first (ctx.scope_resolver,
-- sdc_ctx SCOPE_API): a remote controller, false (the host's own action) or
-- nil (no opinion).
--
-- UE4SS note: a RegisterHook on a Blueprint function takes ONE callback and
-- runs it AFTER the function (LuaMod.cpp script-hook branch,
-- ProcessLocalScriptFunction post). Anything that must happen before the
-- game's code runs hangs on a NATIVE function the Blueprint calls first.
--
-- 1. Respawn (host). The death screen's buttons call BP_PlayerController's
--    Svr_RequestRespawn_Random / Svr_RequestRespawn_SpawnPoint and the pause
--    menu's suicide Svr_RequestRespawnSuicide (server RPCs; ubergraph
--    @7961->7042 / @7126->6958 / @7131->6875). Each body first runs
--    GameFunctionLibrary.GetGameInstance(self) = the native
--    GameplayStatics.GetGameInstance(WorldContextObject = that controller),
--    then SD_GameInstance.Survival_Respawn(Random?) / Survival_SuicideRespawn,
--    which take GetPlayerController(GameInstance, 0) for Possess @567/@1307,
--    RespawnLoc @1068, HUD Re-Initialise @51 and Death_PlayerStats @2137, and
--    broadcast KeepInventoryOnDeath @608/@1348 (the Keep Inventory
--    difficulty) and PlayerRespawned.
--    Pre-point: a native pre-hook on GameplayStatics:GetGameInstance. In the
--    whole game only BP_PlayerController passes a controller there (@6875,
--    @6958, @7042: the three respawn RPCs; @7205 Client_Died runs on the
--    client; @9290 is BeginPlay, before the player's first character). So on
--    the host, a remote controller whose player already had a character is a
--    respawn request. There, once per request:
--      * SpawnPoint safety: a controller whose host-side RespawnLoc is unusable
--        gets one next to the host (Random / Suicide do not read it);
--      * the player's own look goes into the host's Save_Player for the
--        construction script (sdc_charcreate.before_finish_spawn);
--      * a scope: GameInstance player-0 calls resolve to that controller, and
--        so does the new character while no one else possesses it (its
--        BeginPlay, then KeepInventoryOnDeath -> CastToController(self));
--        map-marker actors (the marker refresh the same function runs, with
--        1-2 s delays) for MARKER_WINDOW_S, so the copies go to the remote
--        character's off-screen server map widget, not the host's map.
--    Post-point: the Blueprint hook on the RPC itself (its only callback runs
--    after the body) - or a 0.5 s timer if that never comes: the old body
--    goes (the death screen destroys it in single player; a client cannot),
--    ShowStartingQuests? is cleared before ReceivePossessed's 4 s delay reads
--    it (@9557), sdc_players.after_spawn does the bookkeeping. No new
--    character: the mod spawns one next to the host.
--    The host tells each client it supports this (RSPCAP); the client then
--    keeps the game's own death-screen buttons (sdc_players).
-- 2. Beds and sleeping bags. Buildable_Bed / Buildable_SleepingBag run
--    OnServerExecuteInteract on the host, set CurrentActor = ByActor (@106)
--    and call BedComponent.GoToBed (sleep widget through GetGameHUD @264, or
--    the "too early" notification @306) and SetSpawnPoint (RespawnPointEnabled
--    / RespawnLoc through CastToController @46/@79, "Spawn Point Set" @128):
--    all player 0 from the BedComponent. Host: player-0 calls from a
--    BedComponent resolve, at call time, to the controller of its bed's
--    CurrentActor (config bed_for_client): a remote player's respawn point
--    lands on that player's server-side controller (what Survival_Respawn
--    reads) and the widget / notifications stay off the host; the host's own
--    use stays the host's whoever owns the bed. After GoToBed /
--    SetSpawnPoint (Blueprint hooks = post), BED tells the client, which shows
--    the game's sleep widget, the "too early" text, or runs SetSpawnPoint on
--    its own copy of the bed (its own controller's respawn point).
--    BP_SleepingBag (the item) runs both where the key was pressed: a
--    client's SetSpawnPoint is copied to its server-side controller (SPAWNPT).
--    Sleeping changes the world's time, which only the host can: the sleep
--    widget's "Sleep" button on a client (SleepingUI Button_60 @446 ->
--    UDS.Transition Time of Day(650, 2, 7, 2, false) on the client's copy only)
--    also sends SLEEP (hook = post, after the button's handler). Co-op rule
--    (config coop_sleep_all, section 2b): the host skips the night only when
--    every connected player sleeps; off = the old rule (any sleep skips it,
--    config client_sleep_skips_night).
-- 3. The death screen's "respawn at the spawn point" button (RespawnScreen
--    @2685) first reads CastToController(self).RespawnPointEnabled. Without a
--    respawn point it only calls CreateNotificationUI("No Respawn Point Set"),
--    whose widget Client_Died's RemoveAllWidgets (@7172) already took off the
--    screen: nothing visible happens, in single player too. After the
--    button's handler (Blueprint hook = post) the mod says so in Russian. With
--    a point the handler sweeps the player characters (@26, sdc_sweepguard
--    keeps remote players' ones) and calls Svr_RequestRespawn_SpawnPoint.
--    Diagnostics: this machine's own respawn point and own character are
--    logged when they change (died / lost while alive). The death and the
--    next living character also go to sdc_playernotes (on the host: "<host>
--    died / respawned" for the other players), which is ticked from here.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")
local players = require("sdc_players")
local localinit = require("sdc_localinit")

local M = { stats = { native = 0, fallback = 0, beds = 0, spawnpoints = 0, sleeps = 0, no_point = 0 } }

local S = nil   -- sdc_session.state

local GI_CLASS = "SD_GameInstance_C"
local CHAR_CLASS = "BP_PlayerCharacter_C"
local BED_COMP_CLASS = "BedComponent_C"
local GET_GI_FN = "/Script/Engine.GameplayStatics:GetGameInstance"
local PC_CLASS = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C"
local RESPAWN_RPCS = {
    { fn = "Svr_RequestRespawn_Random", kind = "random" },
    { fn = "Svr_RequestRespawn_SpawnPoint", kind = "point" },
    { fn = "Svr_RequestRespawnSuicide", kind = "suicide" },
}
local BED_CLASS = "/Game/Blueprints/Components/BedComponent.BedComponent_C"
local SLEEP_UI_FN = "/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C:"
    .. "BndEvt__Button_60_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local SKY_CLASS = "Ultra_Dynamic_Sky_C"
local SPAWN_BUTTON_FN = "/Game/UI/Widgets/Player/RespawnScreen.RespawnScreen_C:"
    .. "BndEvt__RespawnScreen_RespawnSpawnPointButton_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature"

local MARKER_CLASSES = { BP_Marker_C = true, BP_PlayerMarker_C = true, BP_POIManager_C = true, BP_QuestMarker_C = true }
local MARKER_WINDOW_S = 4.5      -- BP_PlayerMarker retries every 2 s until a map widget exists
local RESPAWN_FINISH_MS = 500    -- the post when the RPC's Blueprint hook did not come
local SLEEP_FROM, SLEEP_UNTIL = 1930, 630   -- BedComponent.GoToBed(1930, 630)
local SLEEP_TARGET, SLEEP_SECONDS, SLEEP_EASING, SLEEP_EXPONENT = 650, 2, 7, 2   -- SleepingUI @621
local SLEEP_HOST_MIN_S = 15
local SLEEP_EXIT_FN = "/Game/UI/Widgets/Buildable/SleepingUI.SleepingUI_C:Exit"
local SLEEP_ANIM_S = 2.5        -- SleepingUI: Delay(2.5) after the button, then Exit
local LEGACY_SLEEP_S = 20       -- an older client's SLEEP (no waiting window) counts this long
local ANSWER_WAIT_S = 6         -- a client with no answer from the host stops waiting
local HURT_HP = 3               -- a sleeper's health fell more than this within a tick: hurt, it gets up
-- (2b "hurt": a hit, but also the game's own health drains: Bleed 2-4 every
-- 1-2 s, HeavyBleed 4-6, thirst at 0 2-4 every 4-6 s, InfectionDamage,
-- radiation; hunger alone, 2-3 every 6-8 s, never does)

local TEXT = {
    -- co-op sleep (coop_sleep_all); counts are passed as strings ("?" possible)
    sleep_wait        = { "Waiting for all players to fall asleep (%s/%s).", "Ждём, пока уснут все игроки (%s/%s)." },
    sleep_wait_screen = { "Waiting for all players to fall asleep (%s/%s)\nEsc: get up",
                          "Ждём, пока уснут все игроки (%s/%s)\nEsc — встать" },
    sleep_other       = { "%s is sleeping (%s/%s): the night passes when everyone sleeps.",
                          "%s спит (%s/%s): ночь пройдёт, когда уснут все." },
    sleep_all         = { "Everyone is asleep: the night passes.", "Все уснули — ночь проходит." },
    sleep_late        = { "Morning has come: you get up.", "Наступило утро — вы встаёте." },
    -- any fall > HURT_HP: a hit, bleeding, thirst, infection, radiation
    sleep_hurt        = { "You are losing health: you wake up.", "Вы теряете здоровье — вы проснулись." },
    bed_slept     = { "%s went to sleep: the night passes.", "%s лёг спать — ночь проходит." },
    bed_sleep_off = { "The host does not let players skip the night.", "Хост не разрешает игрокам пропускать ночь." },
    bed_early     = { "It's too early to sleep yet, wait until 19:30.", "Ещё рано спать, подождите до 19:30." },
    bed_spawn_set = { "Spawn point set.", "Точка возрождения установлена." },
    respawn_no_point_host = {
        "No respawn point set (sleep in a bed or a sleeping bag to set one): use the random respawn.",
        "Точка возрождения не задана (её ставит сон в кровати или спальном мешке). Возродитесь случайно." },
    respawn_no_point_client = {
        "No respawn point set (sleep in a bed or a sleeping bag to set one): respawn randomly or next to the host.",
        "Точка возрождения не задана (её ставит сон в кровати или спальном мешке). Возродитесь случайно или рядом с хостом." },
}
for k, v in pairs(TEXT) do
    if not log.TEXT[k] then log.TEXT[k] = v end
end

local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("respawn." .. name, "respawn: %s hook: %s", name, tostring(err)) end
    end
end

local function remote_pc(pc)
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

local function sky()
    for _, s in ipairs(ue.find_all(SKY_CLASS)) do
        if ue.valid(s) and not ue.short(s):find("^Default__") then return s end
    end
    return nil
end

local function record_name(r, pc)
    return r and r.name or ue.short(pc)
end

local function scope_api()
    return ctx.SCOPE_API ~= nil and ctx.scope_resolver ~= nil
end

-- Per-tick caches (cleared every second: addresses get reused after GC).
local class_cache = {}    -- [address] = class name
local remote_by_addr = {} -- [controller address] = session record (host)
local bed_routing = false -- host and bed_for_client: route BedComponent player-0 calls

local function class_of(o, a)
    a = a or ctx.addr(o)
    if not a then return "" end
    local c = class_cache[a]
    if c == nil then
        c = ue.class_name(o)
        class_cache[a] = c
    end
    return c
end

-- ---------------------------------------------------------------------------
-- Scopes: player 0 for the game functions of one player
-- ---------------------------------------------------------------------------
-- { pc = <remote controller>, gi = bool, classes = { [class] = true },
--   till = os.clock() deadline }

local scopes = {}

local function push_scope(s)
    scopes[#scopes + 1] = s
    return s
end

-- The new character of a respawn scope: no other controller has it.
local function new_character_of(s, wco)
    local c = ue.prop(wco, "Controller")
    if not ue.valid(c) then return true end
    return ctx.addr(c) == ctx.addr(s.pc)
end

-- A BedComponent's player: the controller of its bed's CurrentActor, which
-- OnServerExecuteInteract sets (@106) just before GoToBed / SetSpawnPoint.
local function bed_player(comp)
    local owner = ue.try(function() return comp:GetOwner() end)
    local actor = ue.prop(owner, "CurrentActor")
    if not ue.valid(actor) then return nil end
    local c = ue.prop(actor, "Controller")
    if remote_pc(c) then return c end
    if ue.valid(c) then return false end   -- the host's own use
    return nil
end

-- sdc_ctx asks this for every player-0 call while its hooks are active
-- (`a` = the object's address, from sdc_ctx's hot path; optional).
local function resolve(wco, a)
    local n = #scopes
    if n == 0 and not bed_routing then return nil end
    local cls = class_of(wco, a)
    if bed_routing and cls == BED_COMP_CLASS then
        return bed_player(wco)
    end
    if n == 0 then return nil end
    local now = os.clock()
    for i = n, 1, -1 do
        local s = scopes[i]
        if now > s.till or not ue.valid(s.pc) then
            table.remove(scopes, i)
        else
            if (s.gi and cls == GI_CLASS) or (s.classes and s.classes[cls]) then
                return s.pc
            end
            if s.gi and cls == CHAR_CLASS and new_character_of(s, wco) then
                return s.pc
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Transforms
-- ---------------------------------------------------------------------------

local function read_transform(tf)
    if tf == nil then return nil end
    local ok, v = pcall(function()
        local t, q = tf.Translation, tf.Rotation
        return { t = { X = t.X, Y = t.Y, Z = t.Z }, q = { X = q.X, Y = q.Y, Z = q.Z, W = q.W } }
    end)
    if ok and type(v) == "table" and type(v.t.X) == "number" and type(v.q.W) == "number" then return v end
    return nil
end

local function make_transform(t, q)
    return {
        Rotation = { X = q.X, Y = q.Y, Z = q.Z, W = q.W },
        Translation = { X = t.X, Y = t.Y, Z = t.Z },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
end

local function same_spot(o, prop, t)
    local back = read_transform(ue.prop(o, prop))
    return back ~= nil and math.abs(back.t.X - t.X) < 1 and math.abs(back.t.Y - t.Y) < 1
        and math.abs(back.t.Z - t.Z) < 1
end

-- An FTransform property of `o`; true when it reads back.
local function write_transform(o, prop, t, q)
    ue.set_prop(o, prop, make_transform(t, q))
    if same_spot(o, prop, t) then return true end
    pcall(function()
        local tf = o:GetPropertyValue(prop)
        tf.Translation.X, tf.Translation.Y, tf.Translation.Z = t.X, t.Y, t.Z
        tf.Rotation.X, tf.Rotation.Y, tf.Rotation.Z, tf.Rotation.W = q.X, q.Y, q.Z, q.W
    end)
    return same_spot(o, prop, t)
end

local function yaw_quat(yaw)
    local h = math.rad(yaw or 0) / 2
    return { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) }
end

-- ---------------------------------------------------------------------------
-- 1. Respawn through the game's own RPCs (host)
-- ---------------------------------------------------------------------------

local pending = nil   -- the respawn request in progress
local hooks = { get_gi = false, respawn = {}, bed = false, sleep_ui = false, sleep_exit = false, spawn_button = false }
local cap = { sent = {}, host_native = false, client = nil }

-- Survival_Respawn(false) spawns at that controller's RespawnLoc. A player
-- whose bed never reached the host would spawn at the world origin.
-- Returns true when the spot was unusable and could not be replaced.
local function ensure_point(pc, r, name)
    local enabled = ue.prop(pc, "RespawnPointEnabled") == true
    local cur = read_transform(ue.prop(pc, "RespawnLoc"))
    if enabled and cur and (math.abs(cur.t.X) > 1 or math.abs(cur.t.Y) > 1) then return false end
    local h = players.helpers
    local loc, yaw = h.near_host_spot(r and r.index or 1, 0)
    if not loc then loc, yaw = h.random_spot() end
    if not loc then
        log.warn("respawn: %s has no respawn point on the host and no spot was found", name)
        return true
    end
    local ok = write_transform(pc, "RespawnLoc", loc, yaw_quat(yaw))
    log.debug("respawn: %s has no usable respawn point on the host (enabled=%s): one next to the host was put in (written=%s)",
        name, tostring(enabled), tostring(ok))
    return not ok
end

local complete   -- below
local preparing = false   -- the preparation itself may call into the engine

-- Native pre-hook GameplayStatics:GetGameInstance(WorldContextObject): the
-- first thing the respawn RPC bodies run before Survival_Respawn.
local function prepare(wco_p)
    if not S or S.role ~= "host" or next(remote_by_addr) == nil then return end
    local wco = wco_p and wco_p:get()
    if not wco then return end
    local a = ctx.addr(wco)
    local r = a and remote_by_addr[a]
    if not r then return end
    -- @9290 (the controller's BeginPlay) comes before the player's first
    -- character; afterwards only the three respawn RPCs pass a controller
    if not r.spawned_once or r.spawn_pending then return end
    if pending and ctx.addr(pending.pc) == a then return end   -- once per request
    local pc = r.pc
    local name = r.name
    if not scope_api() then
        log.err_throttled("respawn-noapi",
            "respawn: %s used the game's respawn, but sdc_ctx has no scope API: the host's controller takes the new character", name)
        return
    end
    if pending then complete(pending, nil, "superseded") end
    local cur = ue.pawn_of(pc)
    local old = cur or (ue.valid(r.pawn) and r.pawn or nil)
    local point_fix = ensure_point(pc, r, name)
    local restore = nil
    if players.before_finish_spawn then
        local okb, res = pcall(players.before_finish_spawn, nil, r)
        if okb and type(res) == "function" then restore = res end
        if not okb then log.err("respawn: own look of %s: %s", name, tostring(res)) end
    end
    local scope = push_scope({ pc = pc, gi = true, classes = MARKER_CLASSES, till = os.clock() + MARKER_WINDOW_S })
    local p = { pc = pc, r = r, name = name, scope = scope, restore = restore, old = old,
                old_name = old and ue.name(old) or nil, old_alive = ue.valid(old) and not players.helpers.is_dead(old),
                point_fix = point_fix, at = os.clock() }
    pending = p
    r.spawn_pending = true
    log.info("respawn: %s asked the game for a respawn (character %s, %s): GameInstance player 0 = this player until it ends",
        name, ue.short(old), p.old_alive and "alive" or "dead / none")
    -- the RPC's own Blueprint hook is the post; this only if it never comes
    ue.delay("respawn-finish", RESPAWN_FINISH_MS, function()
        if pending == p then complete(p, nil, "timer") end
    end)
end

local function on_get_game_instance(wco_p)
    if preparing then return end
    preparing = true
    local ok, err = pcall(prepare, wco_p)
    preparing = false
    if not ok then log.err_throttled("respawn.prepare", "respawn: preparing a respawn: %s", tostring(err)) end
end

complete = function(p, kind, why)
    if pending == p then pending = nil end
    p.scope.gi = false
    local r = p.r
    r.spawn_pending = false
    if p.restore then
        local ok, err = pcall(p.restore)
        if not ok then log.err("respawn: restoring the host's look data (%s): %s", why, tostring(err)) end
    end
    local pc = p.pc
    local new = ue.valid(pc) and ue.pawn_of(pc) or nil
    local got_new = ue.valid(new) and ue.name(new) ~= p.old_name
    if not got_new and p.old_alive and ue.valid(new) and ue.name(new) == p.old_name then
        -- still in the same living character: whatever asked for the
        -- GameInstance with this controller was not a respawn; touch nothing
        log.warn("respawn: %s kept its living character %s (%s): not a respawn after all", p.name, ue.short(new), why)
        return
    end
    -- the old body goes, as the death screen does in single player
    if ue.valid(p.old) and not (got_new and ue.name(p.old) == ue.name(new)) then
        if p.old_alive then log.warn("respawn: %s's old character %s was alive: removed", p.name, ue.short(p.old)) end
        pcall(function() p.old:K2_DestroyActor() end)
    end
    if got_new then
        ue.set_prop(new, "ShowStartingQuests?", false)
        M.stats.native = M.stats.native + 1
        log.info("respawn: %s respawned through the game's own %s respawn as %s (%s; %d so far)",
            p.name, kind or "?", ue.short(new), why, M.stats.native)
        if p.point_fix and kind ~= "random" and kind ~= "suicide" then
            local loc = players.helpers.near_host_spot(r.index or 1, 1)
            if loc then
                ue.teleport(new, loc)
                log.info("respawn: %s moved next to the host (no usable respawn point)", p.name)
            end
        end
        players.after_spawn(r, new, "native-" .. (kind or "?"))
    elseif ue.valid(pc) then
        M.stats.fallback = M.stats.fallback + 1
        log.warn("respawn: the game's respawn gave %s no character (%s); the mod spawns one next to the host", p.name, why)
        r.dead = false
        players.spawn_for(r, "host")
    end
end

-- Blueprint hook on the RPC (its only callback runs after the body).
local function respawn_post(kind, pc_p)
    local p = pending
    if not p then return end
    local pc = pc_p and pc_p:get()
    if not ue.valid(pc) or ctx.addr(pc) ~= ctx.addr(p.pc) then return end
    complete(p, kind, "post")
end

local function install_respawn_hooks()
    if not hooks.get_gi and ue.find_object(GET_GI_FN) then
        -- shared pre-only engine hook (sdc_ue.hook_native): no empty post callback
        local ok, err = ue.hook_native(GET_GI_FN, "respawn.getgi", function(_, wco_p)
            local okc, e = pcall(on_get_game_instance, wco_p)
            if not okc then log.err_throttled("respawn.getgi", "respawn: GetGameInstance hook: %s", tostring(e)) end
        end)
        hooks.get_gi = ok == true
        log.info("respawn: GetGameInstance pre-hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    for _, h in ipairs(RESPAWN_RPCS) do
        if not hooks.respawn[h.kind] then
            local path = PC_CLASS .. ":" .. h.fn
            if ue.find_object(path) then
                local kind = h.kind
                -- Blueprint function: one callback, after the body
                local ok, err = pcall(RegisterHook, path, safe("post-" .. kind, function(pc_p) respawn_post(kind, pc_p) end))
                hooks.respawn[kind] = ok
                log.info("respawn: hook %s (post) %s%s", h.fn, ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
            end
        end
    end
end

-- The pre-point is what makes it correct; the RPC hooks only finish sooner.
local function respawn_ready()
    return hooks.get_gi and scope_api()
end

-- Host: tell each client once that the game's death-screen buttons work.
local function send_caps()
    if not respawn_ready() then return end
    for key, r in pairs(S.remote or {}) do
        if r.hello and not cap.sent[key] and ue.valid(r.pc) then
            cap.sent[key] = true
            net.send_to(r.pc, "RSPCAP", "1")
            log.info("respawn: told %s that the game's own respawn buttons work here", r.name)
        end
    end
end

-- ---------------------------------------------------------------------------
-- 2. Beds and sleeping bags
-- ---------------------------------------------------------------------------

local applying_bed = false  -- client: a BED message is being applied
local sleep_state = { sent_at = -1000, ran_at = -1000 }
local on_sleep_status       -- section 2b (BED|sleepst on a client)

local function bed_location(comp)
    local owner = ue.try(function() return comp:GetOwner() end)
    return ue.location(owner) or { X = 0, Y = 0, Z = 0 }, owner
end

-- Blueprint hooks on BedComponent.GoToBed / SetSpawnPoint: after the call.
-- Host: tell a remote user what the game did for them. Client: a respawn
-- point set here (BP_SleepingBag item) goes to the host.
local function on_bed_call(kind, comp_p, a1_p, a2_p)
    if not S then return end
    local comp = comp_p and comp_p:get()
    if not ue.valid(comp) then return end
    if S.role == "host" then
        if not bed_routing then return end
        local pc = bed_player(comp)
        if pc == false and kind == "sleep" then
            -- the host's own bed: the game showed its window or its "too early"
            local tod = ue.prop(sky(), "Time of Day")
            local from = tonumber(a1_p and a1_p:get()) or SLEEP_FROM
            local untill = tonumber(a2_p and a2_p:get()) or SLEEP_UNTIL
            log.info("bed: the host used a bed (time %s): %s", tostring(tod),
                (type(tod) == "number" and (tod >= from or tod <= untill)) and "the game's sleep window" or "too early")
            return
        end
        if not remote_pc(pc) then return end
        local name = record_name(players.record_for(pc), pc)
        local l = bed_location(comp)
        local lx, ly, lz = string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z)
        if kind == "sleep" then
            local from = tonumber(a1_p and a1_p:get()) or SLEEP_FROM
            local untill = tonumber(a2_p and a2_p:get()) or SLEEP_UNTIL
            local tod = ue.prop(sky(), "Time of Day")
            local ok_sleep = type(tod) == "number" and (tod >= from or tod <= untill)
            M.stats.beds = M.stats.beds + 1
            net.send_to(pc, "BED", ok_sleep and "sleep" or "early", lx, ly, lz)
            log.info("bed: %s used a bed at %s,%s,%s (time %s): %s, shown on the client, not the host",
                name, lx, ly, lz, tostring(tod), ok_sleep and "sleep widget" or "too early")
        else
            -- the call's own argument, or what it just wrote into the
            -- player's host-side controller
            local tf = read_transform(a1_p and a1_p:get()) or read_transform(ue.prop(pc, "RespawnLoc"))
            M.stats.spawnpoints = M.stats.spawnpoints + 1
            if tf then
                net.send_to(pc, "BED", "spawn", lx, ly, lz,
                    string.format("%.1f", tf.t.X), string.format("%.1f", tf.t.Y), string.format("%.1f", tf.t.Z),
                    string.format("%.5f", tf.q.X), string.format("%.5f", tf.q.Y), string.format("%.5f", tf.q.Z),
                    string.format("%.5f", tf.q.W))
            end
            log.info("bed: %s set the respawn point at %s,%s,%s: host-side controller now enabled=%s (not the host's)",
                name, lx, ly, lz, tostring(ue.prop(pc, "RespawnPointEnabled")))
        end
    elseif S.role == "client" and kind == "spawn" and not applying_bed then
        -- BP_SleepingBag (the item) set this client's respawn point locally:
        -- the host's copy of the controller needs it for the game's respawn
        local tf = read_transform(a1_p and a1_p:get())
        if not tf then return end
        net.send_to_host("SPAWNPT", string.format("%.1f", tf.t.X), string.format("%.1f", tf.t.Y),
            string.format("%.1f", tf.t.Z), string.format("%.5f", tf.q.X), string.format("%.5f", tf.q.Y),
            string.format("%.5f", tf.q.Z), string.format("%.5f", tf.q.W))
        log.info("bed: respawn point set on this client at %.0f,%.0f,%.0f, sent to the host", tf.t.X, tf.t.Y, tf.t.Z)
    end
end

local function install_bed_hooks()
    if hooks.bed then return end
    local go, sp = BED_CLASS .. ":GoToBed", BED_CLASS .. ":SetSpawnPoint"
    if not ue.find_object(go) or not ue.find_object(sp) then return end
    -- Blueprint functions: one callback each, after the call
    local ok1, e1 = pcall(RegisterHook, go, safe("bed-sleep", function(c, a, b) on_bed_call("sleep", c, a, b) end))
    local ok2, e2 = pcall(RegisterHook, sp, safe("bed-spawn", function(c, a) on_bed_call("spawn", c, a) end))
    hooks.bed = ok1 and ok2
    log.info("bed: BedComponent hooks (post) GoToBed %s, SetSpawnPoint %s%s", ok1 and "ok" or "FAILED",
        ok2 and "ok" or "FAILED", (ok1 and ok2) and "" or (" " .. tostring(e1) .. " / " .. tostring(e2)))
end

-- Client: the bed whose message this is (its own copy, nearest to the host's
-- position of it).
local function find_bed(x, y, z)
    local best, best_d = nil, 400
    for _, c in ipairs(ue.find_all(BED_COMP_CLASS)) do
        if ue.valid(c) and not ue.short(c):find("^Default__") then
            local l = bed_location(c)
            local dx, dy, dz = l.X - x, l.Y - y, l.Z - z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < best_d then best, best_d = c, d end
        end
    end
    return best
end

-- Client: BED|sleep|early|spawn|bed x|y|z[|tx|ty|tz|qx|qy|qz|qw]
local function on_bed(f)
    local kind = f[1]
    local pc = ue.local_pc()
    if kind == "sleep" then
        -- what GoToBed does when it is time to sleep (@218-264)
        local hud = pc and ue.try(function() return pc:GetHUD() end)
        local ok, err = ue.call(hud, "ShowSleepWidget", true)
        log.info("bed: the host says sleep: the game's sleep widget (ok=%s%s)", tostring(ok), ok and "" or (" " .. tostring(err)))
    elseif kind == "sleepst" then
        -- co-op sleep: BED|sleepst|state|n|N|name|event (section 2b)
        on_sleep_status(f[2], tonumber(f[3]), tonumber(f[4]), f[5], f[6], true)
    elseif kind == "early" then
        -- GoToBed's notification goes through player 0 from the bed component,
        -- which sdc_ctx's client mode may hide when the bed belongs to someone
        -- else. sdc_notes relays the game's own notice (sent from inside
        -- GoToBed, before this BED message); the mod's toast is the fallback.
        local notes = package.loaded["sdc_notes"]
        if notes and notes.covered and notes.covered("It's too early to sleep yet, wait until 19:30", 5) then
            log.info("bed: the host says too early to sleep (the game's own notice came with it)")
            return
        end
        log.say("bed_early", "info", 4)
        log.info("bed: the host says too early to sleep")
    elseif kind == "spawn" then
        local x, y, z = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
        local t = { X = tonumber(f[5]), Y = tonumber(f[6]), Z = tonumber(f[7]) }
        local q = { X = tonumber(f[8]), Y = tonumber(f[9]), Z = tonumber(f[10]), W = tonumber(f[11]) }
        if not (t.X and t.Y and t.Z and q.X and q.Y and q.Z and q.W) or not pc then return end
        local comp = (x and y and z) and find_bed(x, y, z) or nil
        local how = "the bed's own SetSpawnPoint"
        if comp then
            applying_bed = true
            ue.call(comp, "SetSpawnPoint", make_transform(t, q))
            applying_bed = false
        end
        -- the game's call reaches this controller only if player 0 resolved
        -- to it: check, and set the two fields directly otherwise
        if not (ue.prop(pc, "RespawnPointEnabled") == true and same_spot(pc, "RespawnLoc", t)) then
            ue.set_prop(pc, "RespawnPointEnabled", true)
            local ok = write_transform(pc, "RespawnLoc", t, q)
            how = string.format("set directly (bed %s, written=%s)", comp and "found" or "not found", tostring(ok))
            log.say("bed_spawn_set", "ok", 3)
        end
        log.info("bed: respawn point %.0f,%.0f,%.0f on this client: %s, enabled=%s", t.X, t.Y, t.Z, how,
            tostring(ue.prop(pc, "RespawnPointEnabled")))
    end
end

-- Host: SPAWNPT|tx|ty|tz|qx|qy|qz|qw from a client (BP_SleepingBag item).
local function on_spawnpt(f, pc)
    if not S or S.role ~= "host" or not remote_pc(pc) then return end
    local t = { X = tonumber(f[1]), Y = tonumber(f[2]), Z = tonumber(f[3]) }
    local q = { X = tonumber(f[4]), Y = tonumber(f[5]), Z = tonumber(f[6]), W = tonumber(f[7]) }
    if not (t.X and t.Y and t.Z and q.X and q.Y and q.Z and q.W) then return end
    ue.set_prop(pc, "RespawnPointEnabled", true)
    local ok = write_transform(pc, "RespawnLoc", t, q)
    M.stats.spawnpoints = M.stats.spawnpoints + 1
    log.info("bed: %s's respawn point %.0f,%.0f,%.0f copied to its host-side controller (written=%s)",
        record_name(players.record_for(pc), pc), t.X, t.Y, t.Z, tostring(ok))
end

-- Host, coop_sleep_all off (the older rule): SLEEP from a client runs the
-- same time transition as the sleep widget.
local function legacy_sleep(_, pc)
    if not S or S.role ~= "host" or not remote_pc(pc) then return end
    local name = record_name(players.record_for(pc), pc)
    if cfg.get("client_sleep_skips_night") == false then
        log.info("bed: %s slept, the night is not skipped (client_sleep_skips_night = false)", name)
        net.send_to(pc, "MSG", "bed_sleep_off")
        return
    end
    local now = os.clock()
    if now - sleep_state.ran_at < SLEEP_HOST_MIN_S then return end
    local uds = sky()
    local tod = ue.prop(uds, "Time of Day")
    if type(tod) ~= "number" or not (tod >= SLEEP_FROM or tod <= SLEEP_UNTIL) then
        log.info("bed: %s asked to sleep at time %s: not night, ignored", name, tostring(tod))
        return
    end
    sleep_state.ran_at = now
    local ok, err = ue.call(uds, "Transition Time of Day", SLEEP_TARGET, SLEEP_SECONDS, SLEEP_EASING, SLEEP_EXPONENT, false)
    M.stats.sleeps = M.stats.sleeps + 1
    log.info("bed: %s slept: Transition Time of Day(%d) on the host's sky from %.0f (ok=%s%s)", name, SLEEP_TARGET, tod,
        tostring(ok), ok and "" or (" " .. tostring(err)))
    if ok then
        log.say("bed_slept", "info", 6, name)
        local others = {}
        for _, other in ipairs(S.remote_pcs or {}) do
            if ue.name(other) ~= ue.name(pc) then others[#others + 1] = other end
        end
        net.broadcast(others, "MSG", "bed_slept", name)
    end
end

-- ---------------------------------------------------------------------------
-- 2b. Co-op sleep: the night passes when every player sleeps
-- ---------------------------------------------------------------------------
-- The game's sleep (single player): BedComponent.GoToBed(1930, 630) opens the
-- sleep window (HUD_Game.ShowSleepWidget) while Time of Day >= 1930 or <= 630
-- (UDS units are hundredths of an hour: 19:18 to 06:18; 650 = 06:30),
-- otherwise "It's too early to sleep yet, wait until 19:30". Its "Sleep" button
-- (SleepingUI Button_60 @446): the game's save (Game.SleepingSavesGame; a
-- client saves into its throwaway slot), the choices hidden, "Sleeping . . .",
-- the blur, UDS.Transition Time of Day(650, 2 s, 7, 2, false), and 2.5 s
-- later Exit (input back, window gone). "Survive The Night" and the pause key
-- (its Tick) call Exit too. The game has no fatigue: sleeping skips time and
-- saves. Time is the host's sky; a client's transition moves only its copy.
--
-- coop_sleep_all (default on). The host keeps who sleeps:
--   * a player sleeps from its "Sleep" press until it gets up (Esc in the
--     sleep window), is hurt, dies, leaves, or the night is skipped / over;
--   * hurt = its health fell more than HURT_HP within a 1 s tick. The health
--     is the game's own on the host: MedicalComponent.Health of the host's
--     character and of each client's server-side one (the host gets a hurt
--     sleeping client up itself and tells it, BED|sleepst|hurt, then
--     BED|sleepst|off|..|hurt: the mods up to 0.10.0 have no "hurt" state and
--     would stay in bed, uncounted, but close the window on "off"; for a
--     newer one the "off" finds nothing left to close).
--     MedicalComponent does not replicate: a client's own copy stays 100, so
--     a client reads what the host sends to its HUD (Client_UpdateHealthUI ->
--     BP_Ingame.UpdateHealth -> HealthBar.PB_SetPercent(Health / 100),
--     ProgressMethod 0: CurrentPercent; TargetPercent stays 1.0), as sdc_diag
--     does (up to 0.10.0 inclusive it read the copy: a client never woke up
--     when hurt). A death is not "hurt": the host drops a dead sleeper without
--     "hurt", and a client does not show the "hurt" words when its character
--     is dead or its health reads 0 (the HUD's 0 can come before PlayerDead?);
--   * every connected player asleep in those hours: the host runs
--     the game's Transition Time of Day(650, 2, 7, 2, false) - when the host's
--     own press completes the set, the call the button made is that skip;
--   * otherwise the press only saves and plays the sleep animation: the
--     transition it started becomes one to the press time (the same UDS
--     function, allowed to go backwards: nothing moves), and after the
--     game's own Exit the sleeper gets the game's sleep window again in its
--     sleeping state, its text "Ждём, пока уснут все игроки (1/2) / Esc —
--     встать"; the game's notification says the same, awake players are told
--     who sleeps. A client always holds its own copy's transition: the host's
--     replicates.
-- Messages: client -> host SLEEP|2 (asleep, waits), SLEEP|x (got up; only to
-- a host that answered), SLEEP (an older client: asleep for LEGACY_SLEEP_S);
-- host -> client BED|sleepst|state|n|N|name|event, state wait / skip / late
-- (the night is over) / early (a Sleep in the day) / off (coop_sleep_all
-- off; with event "hurt": the follow-up to a hurt for older mods) / hurt
-- (only to the hurt client: it gets up), event in / out / end / all / "".
-- Logged on both machines ("bed: ..."); the time jump itself in sdc_sync.

local coop = { sleepers = {}, last = nil }   -- host: [controller name | "host"] = { name, since, till }
local nap = { active = false, orig = nil, widget = nil, pressed_at = -1000, closing = false, pending = false,
              n = nil, total = nil, hp = nil, host_v2 = false }   -- this machine's own sleep
local host_evaluate   -- below

local function sleep_all_on() return cfg.get("coop_sleep_all") ~= false end

local function is_night(tod)
    return type(tod) == "number" and (tod >= SLEEP_FROM or tod <= SLEEP_UNTIL)
end

local function clock_text(tod)
    local sync = package.loaded["sdc_sync"]
    if type(sync) == "table" and sync.hhmm then return sync.hhmm(tod) end
    return tostring(tod)
end

local function time_cause(text)
    local sync = package.loaded["sdc_sync"]
    if type(sync) == "table" and sync.note_time_cause then sync.note_time_cause(text, 15) end
end

-- Health of a character as the host has it (MedicalComponent.Health), or nil.
local function host_hp(pawn)
    return tonumber(ue.prop(ue.prop(pawn, "MedicalComponent"), "Health"))
end

-- This machine's own health, 0..100, or nil. A client: its HUD's health bar
-- (the host's value; see "hurt" above), not its own MedicalComponent copy.
local function own_hp()
    local pawn = ue.local_pawn()
    if S and S.role == "client" then
        local p = tonumber(ue.prop(ue.prop(ue.prop(pawn, "InGameUI"), "HealthBar"), "CurrentPercent"))
        return p and p * 100 or nil
    end
    return host_hp(pawn)
end

local function in_viewport(w)
    if not ue.valid(w) then return false end
    local ok, v = ue.call(w, "IsInViewport")
    return not ok or v ~= false
end

-- The transition the sleep button just started (A = the press time, B = 650)
-- becomes one to the press time: the same UDS function, 0.1 s, allowed to go
-- backwards, so nothing moves. Nothing running: nothing to hold.
local function hold_time(uds, why)
    if ue.prop(uds, "Transitioning Time") ~= true then
        log.info("bed: %s: no time transition running, nothing to hold", why)
        return false
    end
    local from, to = ue.prop(uds, "Transition Time A"), ue.prop(uds, "Transition Time B")
    if type(from) ~= "number" or type(to) ~= "number" or math.abs(to - SLEEP_TARGET) > 0.5 then
        from = ue.prop(uds, "Time of Day")
    end
    if type(from) ~= "number" then return false end
    local ok, err = ue.call(uds, "Transition Time of Day", from, 0.1, 0, 2, true)
    log.info("bed: %s: the sleep button's time skip held (Transition Time of Day(%.1f, 0.1 s, backwards allowed) ok=%s%s)",
        why, from, tostring(ok), ok and "" or (" " .. tostring(err)))
    return ok
end

local function wait_text()
    return log.tr("sleep_wait_screen", tostring(nap.n or "?"), tostring(nap.total or "?"))
end

-- The game's sleep window in its sleeping state (what the Sleep button does
-- to it @456-532), with `text` in place of "Sleeping . . .".
local function show_sleeping(w, text)
    local choices, label = ue.prop(w, "Choices"), ue.prop(w, "SleepingText")
    if ue.valid(choices) then pcall(function() choices:SetVisibility(2) end) end   -- Hidden
    if ue.valid(label) then
        pcall(function() label:SetText(FText(text)) end)
        pcall(function() label:SetVisibility(4) end)                              -- SelfHitTestInvisible
    end
end

-- The game's own sleep window again (HUD_Game.ShowSleepWidget: input to the
-- window, the character's input off, cursor on), in its sleeping state.
local function open_wait_window()
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    local pawn = ue.local_pawn()
    if not ue.valid(hud) or not pawn or players.helpers.is_dead(pawn) then
        log.info("bed: no HUD or no living character: not waiting in bed")
        nap.active, nap.pending = false, false
        return false
    end
    local ok, err = ue.call(hud, "ShowSleepWidget", true)
    local w = ue.prop(hud, "SleepUI")
    if not ok or not ue.valid(w) then
        log.warn("bed: the sleep window could not be opened again (ok=%s %s): not waiting in bed", tostring(ok), tostring(err))
        nap.active, nap.pending = false, false
        return false
    end
    nap.widget = w
    show_sleeping(w, wait_text())
    local anim = ue.prop(w, "BlurAnim")
    if ue.valid(anim) then pcall(function() w:PlayAnimationForward(anim, 1, false) end) end
    log.info("bed: the game's sleep window again, sleeping state (asleep %s/%s); Esc gets up",
        tostring(nap.n or "?"), tostring(nap.total or "?"))
    return true
end

-- Closes the waiting window the way the game ends a sleep (its Exit).
local function close_wait_window(why)
    local w = nap.widget
    nap.widget = nil
    if not ue.valid(w) then return end
    nap.closing = true
    local ok = ue.call(w, "Exit")
    nap.closing = false
    log.info("bed: sleep window closed (%s, Exit ok=%s)", why, tostring(ok))
end

local function stop_nap(why, close)
    if not nap.active and not nap.widget then return end
    nap.active, nap.pending = false, false
    log.info("bed: no longer waiting in bed: %s", why)
    if close then close_wait_window(why) end
end

-- This machine's player got up while waiting.
local function got_up(how)
    if not nap.active or not S then return end
    nap.active, nap.pending = false, false
    log.info("bed: got up while waiting for the others (%s)", how)
    if S.role == "client" then
        if nap.host_v2 then net.send_to_host("SLEEP", "x") end
    elseif S.role == "host" and coop.sleepers.host then
        coop.sleepers.host = nil
        host_evaluate("the host got up (" .. how .. ")", cfg.player_name(), "out")
    end
end

-- A sleep status on this machine (the host's own view, or BED|sleepst).
on_sleep_status = function(state, n, total, name, event, from_host)
    if from_host then nap.host_v2 = true end
    if from_host then
        log.info("bed: the host says %s, asleep %s/%s (%s %s)", tostring(state), tostring(n), tostring(total),
            tostring(name), tostring(event))
    end
    if state == "wait" then
        if nap.active then
            local changed = nap.n ~= n or nap.total ~= total
            nap.n, nap.total, nap.pending = n, total, false
            if ue.valid(nap.widget) then
                show_sleeping(nap.widget, wait_text())
            elseif os.clock() - nap.pressed_at > SLEEP_ANIM_S and not in_viewport(nap.orig) then
                open_wait_window()   -- the answer came after the game's sleep animation ended
            end
            if changed then log.say("sleep_wait", "info", 5, tostring(n), tostring(total)) end
        elseif event == "in" and name and name ~= "" then
            log.say("sleep_other", "info", 8, name, tostring(n), tostring(total))
        end
    elseif state == "skip" then
        if from_host then time_cause(string.format("sleep: all %s players asleep (the host's skip)", tostring(total))) end
        log.say("sleep_all", "info", 5)
        if nap.active then
            nap.active, nap.pending = false, false
            if ue.valid(nap.widget) then
                show_sleeping(nap.widget, log.tr("sleep_all"))
                ue.delay("sleep-close", math.floor(SLEEP_ANIM_S * 1000), function() close_wait_window("the night passed") end)
            end
        end
    elseif state == "late" or state == "early" then
        if nap.active then
            -- early: a Sleep outside the window (the game's own words for it)
            log.say(state == "late" and "sleep_late" or "bed_early", "info", 5)
            stop_nap(state == "late" and "the night is over" or "not night yet", true)
        end
    elseif state == "off" then
        -- event "hurt": what the host adds after a "hurt" for older mods (here
        -- the "hurt" already ended the waiting: nothing left to stop)
        stop_nap(event == "hurt" and "hurt (the host saw the health fall)"
            or "the host's rule: any player's sleep skips the night (coop_sleep_all off)", true)
    elseif state == "hurt" then
        -- the host saw this player's health fall (its server-side character)
        if nap.active then
            local pawn, hp = ue.local_pawn(), own_hp()
            if not pawn or players.helpers.is_dead(pawn) or (hp and hp <= 0) then
                stop_nap("the host saw the health fall: dead, no 'hurt' words", true)
            else
                log.say("sleep_hurt", "info", 5)
                stop_nap("hurt (the host saw the health fall)", true)
            end
        end
    end
end

-- Host: the status to every client and to the host's own view; repeated
-- states (the tick) only when they change.
local function send_status(state, n, total, name, event)
    local key = state .. " " .. n .. "/" .. total
    if not event and key == coop.last then return end
    coop.last = (state == "wait") and key or nil
    if S and #(S.remote_pcs or {}) > 0 then
        net.broadcast(S.remote_pcs, "BED", "sleepst", state, tostring(n), tostring(total), name or "", event or "")
    end
    on_sleep_status(state, n, total, name, event, false)
end

-- Host: who sleeps now; the skip when everyone does. `own_press`: the host's
-- own Sleep button just started the game's transition.
host_evaluate = function(why, name, event, own_press)
    if not S or S.role ~= "host" then return end
    local now = os.clock()
    local list = S.remote_pcs or {}
    local present = {}
    for _, pc in ipairs(list) do present[ue.name(pc)] = true end
    for id, sl in pairs(coop.sleepers) do
        if id ~= "host" and (not present[id] or (sl.till and now > sl.till)) then
            coop.sleepers[id] = nil
            log.info("bed: %s no longer counts as asleep (%s)", sl.name, present[id] and "an older mod's sleep ended" or "left")
        end
    end
    if coop.sleepers.host and not nap.active then coop.sleepers.host = nil end
    local total, n, awake = 1 + #list, 0, {}
    if coop.sleepers.host then n = 1 else awake[1] = cfg.player_name() end
    for _, pc in ipairs(list) do
        if coop.sleepers[ue.name(pc)] then n = n + 1 else awake[#awake + 1] = record_name(players.record_for(pc), pc) end
    end
    if n == 0 then
        if event then send_status("wait", 0, total, name, event) end
        coop.last = nil
        return
    end
    local uds = sky()
    local tod = ue.prop(uds, "Time of Day")
    if not is_night(tod) then
        if own_press then hold_time(uds, "the host's Sleep outside the sleep hours") end
        -- morning (the window ended while they waited) or a press in the day
        local state = (type(tod) == "number" and tod < 1200) and "late" or "early"
        log.info("bed: %s at %s (%s): outside the game's sleep hours (Time of Day %d..%d), %s, %d sleeper(s) get up",
            why, clock_text(tod), tostring(tod), SLEEP_FROM, SLEEP_UNTIL, state, n)
        coop.sleepers = {}
        send_status(state, n, total, name, event or "end")
        return
    end
    if n >= total then
        coop.sleepers = {}
        M.stats.sleeps = M.stats.sleeps + 1
        time_cause(string.format("sleep: all %d players asleep (%s)", total, why))
        if own_press then
            log.info("bed: all %d players asleep at %s (%.1f), the host last: the game's own Transition Time of Day(%d) from its Sleep button skips the night",
                total, clock_text(tod), tod, SLEEP_TARGET)
        else
            local ok, err = ue.call(uds, "Transition Time of Day", SLEEP_TARGET, SLEEP_SECONDS, SLEEP_EASING, SLEEP_EXPONENT, false)
            log.info("bed: all %d players asleep at %s (%.1f, %s): Transition Time of Day(%d, %d s) on the host's sky ok=%s%s",
                total, clock_text(tod), tod, why, SLEEP_TARGET, SLEEP_SECONDS, tostring(ok), ok and "" or (" " .. tostring(err)))
        end
        send_status("skip", n, total, name, event or "all")
        return
    end
    if own_press then hold_time(uds, "the host's Sleep, not everyone asleep") end
    if event then
        log.info("bed: %s at %s: asleep %d/%d, awake: %s -> the sleepers wait (coop_sleep_all)", why, clock_text(tod), n,
            total, table.concat(awake, ", "))
    end
    send_status("wait", n, total, name, event)
end

-- Any machine: after the sleep window's "Sleep" button handler ran (the
-- game already saved and started its transition).
local function on_sleep_button(c)
    if not S then return end
    local w = c and c:get()
    local role = S.role
    local uds = sky()
    local tod = ue.prop(uds, "Time of Day")
    local now = os.clock()
    if role ~= "client" and (role ~= "host" or #(S.remote_pcs or {}) == 0) then
        log.info("bed: Sleep pressed at %s (%s): no other players, the game's own sleep", clock_text(tod), tostring(tod))
        time_cause("sleep: the game's sleep window, no other players")
        return
    end
    if role == "host" then
        if not sleep_all_on() then
            log.info("bed: the host pressed Sleep at %s (%s): the night passes for everyone (coop_sleep_all off)",
                clock_text(tod), tostring(tod))
            time_cause("sleep: the host's own sleep (coop_sleep_all off)")
            net.broadcast(S.remote_pcs, "MSG", "bed_slept", cfg.player_name())
            return
        end
        nap.active, nap.orig, nap.widget, nap.pressed_at, nap.pending = true, w, nil, now, false
        nap.hp = own_hp()
        coop.sleepers.host = { name = cfg.player_name(), since = now }
        host_evaluate("the host pressed Sleep", cfg.player_name(), "in", true)
        return
    end
    -- client: the time is the host's; the host decides
    if now - sleep_state.sent_at < 2 then return end
    sleep_state.sent_at = now
    hold_time(uds, "Sleep on this client (the host's time counts)")
    nap.active, nap.orig, nap.widget, nap.pressed_at, nap.pending = true, w, nil, now, true
    nap.n, nap.total, nap.hp = nil, nil, own_hp()
    net.send_to_host("SLEEP", "2")
    log.info("bed: Sleep pressed on this client at %s (%s): asked the host (SLEEP 2), waiting for its answer",
        clock_text(tod), tostring(tod))
end

-- Any machine: after a sleep window's Exit (Esc, "Survive The Night", the
-- game's own end of the sleep animation, or ours).
local function on_sleep_exit(c)
    if nap.closing or not nap.active or not S then return end
    local w = c and c:get()
    if not ue.valid(w) then return end
    local a = ctx.addr(w)
    if not a then return end
    if nap.widget and a == ctx.addr(nap.widget) then
        nap.widget = nil
        got_up("Esc in the sleep window")
        return
    end
    if nap.orig and a == ctx.addr(nap.orig) then
        if os.clock() - nap.pressed_at < SLEEP_ANIM_S - 0.2 then
            got_up("Esc during the sleep animation")
            return
        end
        -- the game ended its sleep animation; this player still waits (a
        -- client still without the host's answer: when it comes)
        ue.delay("sleep-reopen", 1, function()
            if nap.active and not nap.pending and not nap.widget then open_wait_window() end
        end)
    end
end

local function install_sleep_hook()
    if not hooks.sleep_ui and ue.find_object(SLEEP_UI_FN) then
        local ok, err = pcall(RegisterHook, SLEEP_UI_FN, safe("sleep-button", on_sleep_button))
        hooks.sleep_ui = ok
        log.info("bed: SleepingUI sleep button hook (post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
    if not hooks.sleep_exit and ue.find_object(SLEEP_EXIT_FN) then
        local ok, err = pcall(RegisterHook, SLEEP_EXIT_FN, safe("sleep-exit", on_sleep_exit))
        hooks.sleep_exit = ok
        log.info("bed: SleepingUI Exit hook (post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
    end
end

-- Host: SLEEP|2 / SLEEP|x / SLEEP from a client.
local function on_sleep(f, pc)
    if not S or S.role ~= "host" or not remote_pc(pc) then return end
    local arg = f and f[1] or ""
    local name = record_name(players.record_for(pc), pc)
    if not sleep_all_on() then
        if arg == "x" then return end
        if arg == "2" then net.send_to(pc, "BED", "sleepst", "off", "0", "0", "", "") end
        legacy_sleep(f, pc)
        return
    end
    local id = ue.name(pc)
    if arg == "x" then
        local was = coop.sleepers[id] ~= nil
        coop.sleepers[id] = nil
        log.info("bed: %s got up (was counted asleep: %s)", name, tostring(was))
        if was then host_evaluate(name .. " got up", name, "out") end
        return
    end
    local now = os.clock()
    coop.sleepers[id] = { name = name, since = now, till = (arg ~= "2") and (now + LEGACY_SLEEP_S) or nil,
                          hp = host_hp(ue.pawn_of(pc)) }
    if arg ~= "2" then
        log.info("bed: %s pressed Sleep (an older mod: no waiting window, counted asleep for %d s)", name, LEGACY_SLEEP_S)
    end
    host_evaluate(name .. " pressed Sleep", name, "in")
end

-- Host: a sleeping client hurt (its server-side character's health fell
-- more than HURT_HP since the last tick) gets up: it is told
-- (BED|sleepst|hurt closes its window; then "off" with event "hurt", which
-- closes it in the mods up to 0.10.0 that have no "hurt"), the others get the
-- new count. A dead one (PlayerDead? or health 0) only stops counting: its
-- own death screen, not the "hurt" words.
local function watch_sleepers()
    local list = S.remote_pcs or {}
    for _, pc in ipairs(list) do
        local id = ue.name(pc)
        local sl = coop.sleepers[id]
        local pawn = sl and ue.pawn_of(pc)
        local hp = sl and host_hp(pawn)
        if sl and (players.helpers.is_dead(pawn) or (hp and hp <= 0)) then
            coop.sleepers[id] = nil
            log.info("bed: %s died while asleep (health %s on the host): no longer counts as asleep", sl.name, tostring(hp))
            host_evaluate(sl.name .. " died", sl.name, "out")
        elseif sl and sl.hp and hp and hp < sl.hp - HURT_HP then
            coop.sleepers[id] = nil
            local n = 0
            for _ in pairs(coop.sleepers) do n = n + 1 end
            log.info("bed: %s was hurt while asleep (health %.0f -> %.0f on the host): gets up", sl.name, sl.hp, hp)
            net.send_to(pc, "BED", "sleepst", "hurt", tostring(n), tostring(1 + #list), sl.name, "out")
            net.send_to(pc, "BED", "sleepst", "off", "0", "0", sl.name, "hurt")
            host_evaluate(sl.name .. " was hurt", sl.name, "out")
        elseif sl and hp then
            sl.hp = hp
        end
    end
end

-- Every second: this machine's own waiting; the host's bookkeeping.
local function sleep_tick()
    if nap.active then
        local now = os.clock()
        local pawn = ue.local_pawn()
        local hp = own_hp()
        if S.role ~= "host" and S.role ~= "client" then
            stop_nap("co-op ended", true)
        elseif not pawn or players.helpers.is_dead(pawn) then
            got_up("died or no character")
            close_wait_window("no living character")
        elseif nap.hp and hp and hp < nap.hp - HURT_HP then
            -- 0: the death (a client's HUD 0 can come before PlayerDead?): no "hurt" words
            if hp > 0 then log.say("sleep_hurt", "info", 5) end
            got_up(string.format("%s: health %.0f -> %.0f%s", hp > 0 and "hurt" or "died", nap.hp, hp,
                S.role == "client" and " (HUD)" or ""))
            close_wait_window(hp > 0 and "hurt" or "no living character")
        elseif S.role == "client" and nap.pending and now - nap.pressed_at > ANSWER_WAIT_S then
            log.info("bed: no answer from the host in %d s (an older mod?): the host decides the night", ANSWER_WAIT_S)
            stop_nap("no answer from the host", true)
        elseif nap.widget and not in_viewport(nap.widget) then
            nap.widget = nil
            got_up("the sleep window was removed")
        elseif not nap.widget and not nap.pending and now - nap.pressed_at > SLEEP_ANIM_S + 1.5
            and not in_viewport(nap.orig) then
            open_wait_window()   -- the Exit hook did not catch the game's own end of the animation
        end
        if hp then nap.hp = hp end
    end
    if S.role == "host" and next(coop.sleepers) then
        watch_sleepers()
        if next(coop.sleepers) then host_evaluate("tick") end
    end
end

-- ---------------------------------------------------------------------------
-- Tick, world reset, install
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The death screen's spawn-point button, own respawn point / character log
-- ---------------------------------------------------------------------------

local function point_desc(pc)
    if ue.prop(pc, "RespawnPointEnabled") ~= true then return "not set" end
    local tf = read_transform(ue.prop(pc, "RespawnLoc"))
    if not tf then return "set" end
    return string.format("set at %.0f,%.0f,%.0f", tf.t.X, tf.t.Y, tf.t.Z)
end

-- After RespawnScreen's spawn-point button handler (any role: the screen is
-- this machine's own).
local function on_spawn_button()
    if not S then return end
    local pc = ue.local_pc()
    if not pc then return end
    if ue.prop(pc, "RespawnPointEnabled") == true then
        log.info("respawn: spawn-point button on this machine: the game respawns at the respawn point (%s)", point_desc(pc))
        return
    end
    M.stats.no_point = M.stats.no_point + 1
    log.info("respawn: spawn-point button on this machine without a respawn point (RespawnPointEnabled=false); the game's own notification is not on screen")
    log.say(S.role == "client" and "respawn_no_point_client" or "respawn_no_point_host", "warn", 8)
end

local function install_spawn_button_hook()
    if hooks.spawn_button or not ue.find_object(SPAWN_BUTTON_FN) then return end
    -- Blueprint function: one callback, after the handler
    local ok, err = pcall(RegisterHook, SPAWN_BUTTON_FN, safe("spawn-button", on_spawn_button))
    hooks.spawn_button = ok
    log.info("respawn: death screen spawn-point button hook (post) %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

local own = { point = nil, pawn = nil, addr = nil, short = nil, alive = false, died = false }

-- sdc_playernotes: this machine's own character died ("died", its address) /
-- lives again after that ("back"); the host tells the other players.
local function own_player_event(kind, a)
    local pn = package.loaded["sdc_playernotes"]
    if type(pn) ~= "table" or type(pn.own_event) ~= "function" then return end
    local ok, err = pcall(pn.own_event, kind, a)
    if not ok then log.err_throttled("respawn.pnotes", "respawn: player notes (%s): %s", tostring(kind), tostring(err)) end
end

-- Every second in co-op: this machine's own respawn point and character.
local function own_watch()
    local pc = ue.local_pc()
    if not pc then return end
    local desc = point_desc(pc)
    if desc ~= own.point then
        log.info("respawn: own respawn point %s%s", desc, own.point and (" (was " .. own.point .. ")") or "")
        own.point = desc
    end
    local pawn = ue.pawn_of(pc)
    local a = pawn and ctx.addr(pawn)
    local dead = pawn ~= nil and players.helpers.is_dead(pawn)
    if own.alive and (a ~= own.addr or dead) then
        local prev = own.pawn
        local prev_dead = ue.valid(prev) and players.helpers.is_dead(prev)
        if prev_dead then
            log.info("respawn: own character %s died; own respawn point %s", tostring(own.short), desc)
            own.died = true
            own_player_event("died", own.addr)
        elseif not pawn then
            log.warn("respawn: own controller lost its living character %s without a death (%s)", tostring(own.short),
                ue.valid(prev) and ("its controller now " .. ue.short(ue.prop(prev, "Controller"))) or "gone")
        end
    end
    local alive = pawn ~= nil and not dead
    -- a living character after the death (also a new one seen in the same
    -- second as the death: the pause menu's suicide respawns at once)
    if alive and own.died and (not own.alive or a ~= own.addr) then
        own.died = false
        own_player_event("back", a)
    end
    own.pawn, own.addr, own.short, own.alive = pawn, a, pawn and ue.short(pawn) or nil, alive
end

local function tick()
    if not S then return end
    install_spawn_button_hook()
    if S.role == "host" or S.role == "client" then
        local okw, werr = pcall(own_watch)
        if not okw then log.err_throttled("respawn.own", "respawn: own watch: %s", tostring(werr)) end
    end
    localinit.install_hooks()
    class_cache = {}
    local role = S.role
    if role == "host" then
        local m = {}
        for _, r in pairs(S.remote or {}) do
            local a = ue.valid(r.pc) and ctx.addr(r.pc)
            if a then m[a] = r end
        end
        remote_by_addr = m
        bed_routing = cfg.get("bed_for_client") ~= false and scope_api()
        install_respawn_hooks()
        install_bed_hooks()
        install_sleep_hook()
        pcall(players.install_host_hooks)
        send_caps()
    else
        remote_by_addr, bed_routing = {}, false
        if role == "client" then
            if S.client ~= cap.client then
                cap.client, cap.host_native = S.client, false
                nap.host_v2 = false
            end
            install_bed_hooks()
            install_sleep_hook()
        end
    end
    local oks, serr = pcall(sleep_tick)
    if not oks then log.err_throttled("respawn.sleep", "respawn: co-op sleep tick: %s", tostring(serr)) end
    -- other players' deaths / respawns as notifications (sdc_playernotes; host decides)
    local pn = package.loaded["sdc_playernotes"]
    if type(pn) == "table" and type(pn.tick) == "function" then
        local okp, perr = pcall(pn.tick)
        if not okp then log.err_throttled("respawn.pnotes.tick", "respawn: player notes tick: %s", tostring(perr)) end
    end
end

local function reset_world()
    -- the old world's sleep windows are gone with it
    coop.sleepers, coop.last = {}, nil
    nap.active, nap.pending, nap.orig, nap.widget, nap.n, nap.total = false, false, nil, nil, nil, nil
    own.point, own.pawn, own.addr, own.short, own.alive, own.died = nil, nil, nil, nil, false, false
    scopes = {}
    pending = nil   -- the old world's objects: never touched again
    class_cache, remote_by_addr, bed_routing = {}, {}, false
    cap.sent = {}
    pcall(players.reset_world)
end

function M.register_handlers()
    -- host -> client: RSPCAP|1 (the game's own respawn buttons work here)
    net.on("RSPCAP", function()
        cap.host_native = true
        cap.client = S and S.client or nil
        log.info("respawn: the host runs the game's own respawn buttons for this client (respawn_native=%s)",
            tostring(cfg.get("respawn_native") ~= false))
    end)
    -- host -> client: BED|sleep|early|spawn|sleepst|...
    net.on("BED", function(f) if not applying_bed then on_bed(f) end end)
    -- client -> host: SPAWNPT|transform; SLEEP[|2|x] (section 2b)
    net.on("SPAWNPT", on_spawnpt)
    net.on("SLEEP", on_sleep)
end

-- main.lua, after sdc_session is loaded.
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    ctx.scope_resolver = resolve
    -- sdc_ctx's idle check: resolve() answers nil without side effects while
    -- no scope is open and beds are not routed (its first line)
    if ctx.set_idle_check then
        ctx.set_idle_check(resolve, function() return #scopes == 0 and not bed_routing end)
    end
    if not ctx.SCOPE_API then
        log.warn("respawn: sdc_ctx has no SCOPE_API: the game's respawn / bed functions stay with the host's player 0; the mod's own respawn is used")
    end
    players.native_respawn_ok = function()
        return cfg.get("respawn_native") ~= false and cap.host_native == true
    end
    if session then
        localinit.on_client_quit_to_menu = session.disconnect
        if session.world_reset_hooks then session.world_reset_hooks.respawn = reset_world end
    end
    localinit.install_hooks()
    M.register_handlers()
    -- a client's level / skills: a new character's (sdc_progress)
    local okp, perr = pcall(function() require("sdc_progress").install(S) end)
    if not okp then log.err("respawn: sdc_progress install: %s", tostring(perr)) end
    -- the host's own respawn / suicide / load / quit must not remove remote
    -- players' characters (sdc_sweepguard)
    local okg, gerr = pcall(function() require("sdc_sweepguard").install(S) end)
    if not okg then log.err("respawn: sdc_sweepguard install: %s", tostring(gerr)) end
    -- "<player> died / respawned" on the other players' screens (PEV handler;
    -- ticked from this module's tick, fed by own_watch)
    local okn, nerr = pcall(function() require("sdc_playernotes").install(S) end)
    if not okn then log.err("respawn: sdc_playernotes install: %s", tostring(nerr)) end
    ue.delay("respawn-boot", 5000, function() ue.every("respawn", 1000, tick) end)
    log.info("respawn: installed (scope API %s)", ctx.SCOPE_API and "present" or "MISSING")
end

-- Console / F7 status (sdc_progress and sdc_sweepguard lines appended).
function M.status_line()
    local line = string.format("respawn: native=%d fallback=%d no_point=%d | beds=%d spawnpoints=%d sleeps=%d | scopes=%d bed_routing=%s host_native=%s get_gi_hook=%s point_button_hook=%s",
        M.stats.native, M.stats.fallback, M.stats.no_point, M.stats.beds, M.stats.spawnpoints, M.stats.sleeps, #scopes,
        tostring(bed_routing), tostring(cap.host_native), tostring(hooks.get_gi), tostring(hooks.spawn_button))
    local asleep = 0
    for _ in pairs(coop.sleepers) do asleep = asleep + 1 end
    line = line .. string.format(" | sleep: all_must_sleep=%s asleep=%d waiting_here=%s hooks=%s/%s",
        tostring(sleep_all_on()), asleep, tostring(nap.active), tostring(hooks.sleep_ui), tostring(hooks.sleep_exit))
    local prog = package.loaded["sdc_progress"]
    if type(prog) == "table" and prog.status_line then line = line .. " || " .. prog.status_line() end
    local guard = package.loaded["sdc_sweepguard"]
    if type(guard) == "table" and guard.status_line then line = line .. " || " .. guard.status_line() end
    local pn = package.loaded["sdc_playernotes"]
    if type(pn) == "table" and pn.status_line then line = line .. " || " .. pn.status_line() end
    return line
end

return M
