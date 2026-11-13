-- SDCoop: the game's own "this is my character" setup, when a client missed it.
--
-- BP_PlayerCharacter runs its local-player setup only if the character
-- already has a local controller at BeginPlay, or once more 0.5 s later
-- (ubergraph entry 8728, the resume point of that Delay). The setup starts the
-- per-player timers (TraceForAI: the enemy health bar under the crosshair,
-- TraceToWorldChecks, WeaponWallTrace, CameraWaterEffect, WaterAudioCheck),
-- fills the weapon slot containers and asks the server for the inventory data.
-- On a client a character the host spawns (join, respawn) can receive its
-- controller later than that, and the setup never runs: no health bar, no
-- wall check, no water effects.
--
-- Marker: the CameraWaterEffect timer, which the game never clears. When the
-- own character still has no such timer a few seconds after it appeared and
-- its controller is now local, the game's own entry 8728 is run once, the
-- same way the engine resumes the Delay.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")

local M = {}

local ENTRY = 8728
local MARK = "CameraWaterEffect"
local WAIT_S = 3

local st = { key = nil, since = 0, done = false, tries = 0 }

local function timer_active(ksl, pawn, name)
    local ok, v = pcall(function() return ksl:K2_IsTimerActive(pawn, name) end)
    if not ok then return nil end
    return v == true
end

local note_played -- defined below (the main menu sublevel)

-- Client tick: pawn = own character (or nil).
function M.tick(pawn, now)
    M.install_hooks()
    if not ue.valid(pawn) then st.key = nil return end
    note_played()
    if not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return end
    local key = ue.name(pawn)
    if key ~= st.key then
        st.key, st.since, st.done, st.tries = key, now, false, 0
    end
    if st.done or now - st.since < WAIT_S then return end
    local ksl = ue.ksl()
    if not ksl then return end

    local mark = timer_active(ksl, pawn, MARK)
    local trace_ai = timer_active(ksl, pawn, "TraceForAI")
    if mark ~= false then
        st.done = true
        log.info("localinit: %s set up by the game (%s=%s TraceForAI=%s)",
            ue.short(pawn), MARK, tostring(mark), tostring(trace_ai))
        return
    end

    -- the setup needs a local controller, as the game checks it
    local ctl = ue.try(function() return pawn:GetController() end)
    local is_local = ue.valid(ctl) and ue.try(function() return ctl:IsLocalController() end) == true
    if not is_local then
        st.tries = st.tries + 1
        st.since = now
        if st.tries >= 10 then
            st.done = true
            log.warn("localinit: %s still has no local controller, setup not run", ue.short(pawn))
        end
        return
    end

    st.done = true
    local ok, err = pcall(function() pawn:ExecuteUbergraph_BP_PlayerCharacter(ENTRY) end)
    log.info("localinit: %s missed the game's local setup (no %s timer); ran entry %d: %s, now %s=%s TraceForAI=%s",
        ue.short(pawn), MARK, ENTRY, ok and "ok" or tostring(err),
        MARK, tostring(timer_active(ksl, pawn, MARK)), tostring(timer_active(ksl, pawn, "TraceForAI")))
end

-- ---------------------------------------------------------------------------
-- The main menu sublevel on a client.
--
-- The game is one world: PersistentLevel streams in MainMenu or the map.
-- Its level script (PersistentLevel ReceiveBeginPlay@232..553) runs on every
-- machine and loads MainMenu through SD_GameInstance.Event_LoadLevel; the
-- host unloads it when it starts playing (Event_LoadLevel(map) ->
-- UnloadStreamLevel(CurrentLevel)@672). A client that joins gets the map from
-- the server (the engine replicates the server's streaming state) but its own
-- level script then loaded MainMenu on top: that level's Ultra Dynamic Sky
-- (frozen at 9:00, never started because the server has no such level) and
-- Weather (its material snow / wetness parameters are global) drew over the
-- host's, plus the menu level script (MainMenu_C: PRESS ANY KEY, main menu,
-- GetUDS().Time of Day = random).
--
-- 1. Prevention (block_menu_level): a native pre-hook on
--    GameplayStatics:LoadStreamLevel (what PersistentLevel's script calls
--    @166 with CurrentLevel = 'MainMenu') turns the level name into None in a
--    client's world, so the latent action finds no level and completes at
--    once (the loading screen fades out as usual). (A hook on the Blueprint
--    event SD_GameInstance.Event_LoadLevel cannot do it: UE4SS runs Blueprint
--    hooks only after the function, when the load has already started.)
--    Never in a standalone / host world, never while sdc_charcreate has the
--    game's creator open (main menu only).
--    The same request after this client has played in the world is the
--    death screen's "Quit to main menu": the client leaves the server.
-- 2. Fallback (unload_menu_level): if MainMenu got loaded anyway, it is
--    unloaded the way the engine streams any level:
--    LevelStreaming.SetShouldBeVisible/Loaded(false).
-- ---------------------------------------------------------------------------
local MENU_LEVEL = "MainMenu"
local LOAD_LEVEL_FN = "/Script/Engine.GameplayStatics:LoadStreamLevel"
local menu = { key = nil, done = false, tries = 0, at = 0, played = false }
local hook = { done = false, tries = 0, blocked = 0 }
local HOOK_TRIES = 5   -- a failed registration is retried on later ticks this often

-- Set by sdc_respawn: how a client leaves the server (sdc_session.disconnect).
M.on_client_quit_to_menu = nil

local function world_key()
    local pc = ue.local_pc()
    local key = ue.world_path and ue.world_path() or "world"
    return key .. "|" .. (pc and ue.name(pc) or "")
end

-- The own character exists in this world: the client plays here, so a later
-- LoadStreamLevel(MainMenu) is the death screen's "Quit to main menu". Every
-- client tick (M.tick), whatever unload_menu_level says.
note_played = function()
    local key = world_key()
    if menu.key ~= key then
        menu.key, menu.done, menu.tries, menu.at = key, false, 0, 0
    end
    menu.played = true
end

local function charcreate_open()
    local cc = package.loaded["sdc_charcreate"]
    if type(cc) ~= "table" or type(cc.is_open) ~= "function" then return false end
    local ok, open = pcall(cc.is_open)
    return ok and open == true
end

-- Net mode of the world the GameInstance is in, from the hook's own context
-- (the role cached by sdc_session can still be the old world's here).
local function world_is_client(gi)
    local ksl = ue.ksl()
    if not ksl or not ue.valid(gi) then return false end
    local oks, standalone = pcall(function() return ksl:IsStandalone(gi) end)
    if not oks or standalone ~= false then return false end
    local okv, server = pcall(function() return ksl:IsServer(gi) end)
    return okv and server == false
end

-- LoadStreamLevel(WorldContextObject, LevelName, bMakeVisibleAfterLoad,
-- bShouldBlockOnLoad, LatentInfo): pre-hook args after the CDO context.
local function on_load_level(wco_p, level_p)
    if cfg.get("block_menu_level") == false then return end
    local level = ue.str(level_p and level_p:get())
    if level ~= MENU_LEVEL then return end
    local gi = wco_p and wco_p:get()
    if not world_is_client(gi) then return end
    if charcreate_open() then
        log.info("localinit: LoadStreamLevel(MainMenu) on a client while the character creator is open: allowed")
        return
    end
    -- The level script's own load on arrival (PersistentLevel ReceiveBeginPlay
    -- -> Event_LoadLevel(MainMenu) -> loading-screen fade -> LoadStreamLevel)
    -- comes once per world and can be 10+ s late, after the character is
    -- already there: it is never a quit. Only a later request in the same
    -- world, after playing, is the death screen's "Quit to main menu".
    local wk = world_key()
    local first = menu.first_load_key ~= wk
    if first then menu.first_load_key = wk end
    local quit = not first and menu.played and menu.key == wk
    if not pcall(function() level_p:set(FName("None")) end) then
        log.warn("localinit: could not keep MainMenu from loading (parameter not writable)")
        return
    end
    hook.blocked = hook.blocked + 1
    if quit then
        log.info("localinit: LoadStreamLevel(MainMenu) after playing = the game's 'Quit to main menu' on a client: leaving the server")
        local fn = M.on_client_quit_to_menu
        ue.delay("quit-to-menu", 50, function()
            if type(fn) == "function" then fn() else ue.exec("disconnect") end
        end)
    else
        log.info("localinit: kept the client's own MainMenu sublevel from loading (LoadStreamLevel MainMenu -> None, %d so far)",
            hook.blocked)
    end
end

-- Registered once (shared pre-only engine hook, sdc_ue.hook_native); safe to
-- call again from the ticks: a failed registration is retried HOOK_TRIES times.
function M.install_hooks()
    if hook.done then return true end
    if hook.tries >= HOOK_TRIES then return false end
    hook.tries = hook.tries + 1
    local ok, err = ue.hook_native(LOAD_LEVEL_FN, "localinit.menulevel", function(_, wco_p, level_p)
        local okc, e = pcall(on_load_level, wco_p, level_p)
        if not okc then log.err_throttled("localinit-loadlevel", "localinit: LoadStreamLevel hook: %s", tostring(e)) end
    end)
    hook.done = ok == true
    if ok or hook.tries == 1 or hook.tries == HOOK_TRIES then
        log.info("localinit: LoadStreamLevel hook %s%s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)),
            (not ok and hook.tries == HOOK_TRIES) and "; not tried again" or "")
    end
    return hook.done
end

-- Client tick: pawn = own character (only once it exists the client plays).
-- Safe to call every tick whatever the settings: with unload_menu_level =
-- false it only says once per world whether the sublevel is there.
function M.menu_level_tick(pawn, now, keep)
    M.install_hooks()
    if not ue.valid(pawn) then return end
    note_played()
    if menu.done or keep or now - menu.at < 3 then return end
    menu.at = now
    local gps = ue.gameplay_statics()
    local wc = ue.local_pc()
    if not gps or not wc then return end
    local okg, ls = pcall(function() return gps:GetStreamingLevel(wc, FName(MENU_LEVEL)) end)
    if not okg or not ue.valid(ls) then
        menu.done = true
        log.info("localinit: no %s streaming level in this world (%s)", MENU_LEVEL, okg and "none" or tostring(ls))
        return
    end
    local loaded = ue.try(function() return ls:IsLevelLoaded() end)
    local wanted = ue.try(function() return ls:ShouldBeLoaded() end)
    if loaded ~= true and wanted ~= true then
        menu.done = true
        log.info("localinit: %s sublevel is not loaded on this client", MENU_LEVEL)
        return
    end
    if cfg.get("unload_menu_level") == false then
        menu.done = true
        log.warn("localinit: %s sublevel is loaded on this client (unload_menu_level = false, left as is)", MENU_LEVEL)
        return
    end
    menu.tries = menu.tries + 1
    local okv = pcall(function() ls:SetShouldBeVisible(false) end)
    local okl = pcall(function() ls:SetShouldBeLoaded(false) end)
    log.info("localinit: unloading the client's own %s sublevel (its sky / weather / menu script draw over the host's world): visible->false %s, loaded->false %s (was loaded=%s)",
        MENU_LEVEL, okv and "ok" or "failed", okl and "ok" or "failed", tostring(loaded))
    if menu.tries >= 5 then
        menu.done = true
        log.warn("localinit: %s sublevel still loaded after %d tries", MENU_LEVEL, menu.tries)
    end
end

return M
