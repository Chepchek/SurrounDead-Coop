-- SDCoop: a client's game windows (inventory, trade window, loot window)
-- keep the game's own UI input: the cursor shows and the mouse stops turning
-- the camera, as in single player.
--
-- How the game does it (work\re\pseudo):
--   * One function opens and closes the player's inventory window and every
--     window built inside it: BP_JigComponent.ToggleInventory.
--     Open (@737-913): InventoryWidgetRef.AddToViewport(1),
--     SetInputMode_GameAndUIEx(GetPlayerController(self, 0),
--     InventoryWidgetRef, LockAlways, false, false), bShowMouseCursor = true.
--     Close (@99-262): RemoveFromParent, SetInputMode_GameOnly(.., false),
--     bShowMouseCursor = false. The Tab key (IA_Inventory, BP_PlayerCharacter
--     @108034 -> @107882; the interact key closes an open window, @108304), a
--     trader's trade window (BP_TraderMaster SetupInventoryWidget ->
--     BP_PlayerCharacter.AddJigWidgetToContent @0) and a loot container's
--     window (W_LootContainerUI @266) all go through it.
--   * Mouse look (IA_CameraRotation, BP_PlayerCharacter @32338-33346:
--     GetPlayerController(self, 0).AddYawInput / AddPitchInput) has no
--     "window open" check: only the game+UI input mode stops it (the game
--     viewport lets the mouse go). Clicks on the window need that mode too.
--   * At a trader in single player the dialogue's trade event
--     (Quest_Event_OnInteractNPC.ExecuteEvent) first calls TryExitDialogue
--     (@116) -> the dialogue HUD's On Dialogue Finished
--     (BP_CustomNarrativeDefaultUI @185-275: SetInputMode_GameOnly,
--     bShowMouseCursor = false), and only then OnExecuteInteractDialogue
--     (@316) opens the trade window with UI input. On a co-op client the
--     dialogue is the host's (sdc_dialogue): the client's own copy of the
--     trade event opens the window, and the dialogue's end can come back from
--     the host later (ServerTryExitDialogue -> ClientExitDialogue): a game
--     switch to game control then lands on the OPEN window.
--   * The mod's own "back to game controls" (sdc_widgets.game_input: after
--     possession, the setup check 6 s later, stray menu widgets, the death
--     screen) did the same when it fell into an open window.
--
-- What this module does (client only, config game_ui_input):
--   1. ToggleInventory post-hook (this player's own component): right after
--      the game's call the cursor flag of THIS machine's controller is read.
--      A window that opened with the cursor still off (the game's switch did
--      not reach this player's controller) gets the game's own open step on
--      it; a window that closed with the cursor still on gets the close step.
--   2. SetInputMode_GameOnly pre-hook: a switch to game control for this
--      player's controller while its inventory window stays open is
--      followed, on the next frame (after the caller's own "cursor off"), by
--      the window's own input again, the end state single player has. At
--      most KEEP_MAX times per opened window. Nothing happens while no
--      window is open.
--   3. M.game_ui_open(): the game window that is open, if any;
--      sdc_widgets.game_input and sdc_players never force game controls
--      over it.
--
-- Log lines start with "uiinput:". Every callback is wrapped in pcall and
-- returns nothing; no engine object wrapper is kept between calls (only
-- names and clock times).

local log = require("sdc_log")
local ue  = require("sdc_ue")
local cfg = require("sdc_config")

local M = {
    stats = { opened = 0, closed = 0, fixed_open = 0, fixed_close = 0, kept = 0, gave_up = 0 },
}

function M.enabled()
    return cfg.get("game_ui_input") ~= false
end

-- ---------------------------------------------------------------------------
-- Game assets
-- ---------------------------------------------------------------------------

local TOGGLE_FN   = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:ToggleInventory"
local GAMEONLY_FN = "/Script/UMG.WidgetBlueprintLibrary:SetInputMode_GameOnly"

local LOCK_ALWAYS = 2      -- EMouseLockMode::LockAlways, as ToggleInventory @800
local KEEP_MAX = 4         -- restores per opened window before giving up

-- Windows on the viewport that own the input while they are open (the game
-- sets UI input for each): pause menu (HUD_Game @483), keypad, lockpick,
-- sleep window, yes/no prompt, rename prompt.
local UI_WINDOWS = { "PauseScreen_C", "KeypadUI_C", "LockpickUI_C", "SleepingUI_C", "ModularYesNoUI_C",
                     "BuildableRenameObject_C" }

local S   -- sdc_session.state
local st = {
    installed = false,
    hooks = {},              -- [key] = true (in) / "failed"
    win = nil,               -- { key = window name, at = os.clock(), kept = n, fixed = bool }
    keep_pending = false,
    said = {},               -- first-time info lines per world
}

local function is_client()
    return S ~= nil and S.role == "client"
end

local function active()
    return is_client() and M.enabled()
end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function in_viewport(w)
    if not ue.valid(w) then return false end
    local ok, v = pcall(function() return w:IsInViewport() end)
    return ok and v == true
end

local function same(a, b)
    return ue.valid(a) and ue.valid(b) and ue.name(a) == ue.name(b)
end

local function cursor_on(pc)
    return ue.prop(pc, "bShowMouseCursor") == true
end

-- This player's inventory window (the widget ToggleInventory shows).
local function own_window()
    local pawn = ue.local_pawn()
    local comp = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) then return nil end
    local w = ue.prop(comp, "InventoryWidgetRef")
    if ue.valid(w) then return w end
    return nil
end

-- A component of this player's own character (not another player's copy,
-- not a stale local copy).
local function own_component(comp)
    local owner = ue.try(function() return comp:GetOwner() end)
    if not ue.valid(owner) then return false end
    local pc = ue.local_pc()
    if not pc then return false end
    if same(ue.pawn_of(pc), owner) then return true end
    return same(ue.prop(owner, "Controller"), pc)
end

-- ---------------------------------------------------------------------------
-- Which game window is open
-- ---------------------------------------------------------------------------

-- The open game window's name, or nil. Cheap checks first; the window
-- classes are looked up only when nothing on the character is open.
function M.game_ui_open()
    local pawn = ue.local_pawn()
    if pawn then
        local comp = ue.prop(pawn, "BP_JigMultiplayer")
        if ue.valid(comp) and in_viewport(ue.prop(comp, "InventoryWidgetRef")) then
            return "the inventory window (inventory / trade / loot)"
        end
        if ue.prop(pawn, "JournalOpen?") == true then return "the journal" end
        if ue.prop(pawn, "RadialMenuOpen?") == true then return "the radial menu" end
        local mm = ue.prop(pawn, "MinimapSystemComponent")
        if ue.valid(mm) and ue.prop(mm, "MapToggled") == true then return "the map" end
    end
    for _, cls in ipairs(UI_WINDOWS) do
        for _, w in ipairs(ue.find_all(cls)) do
            if in_viewport(w) then return cls end
        end
    end
    return nil
end

-- The co-op panel (F7) shows the cursor too (sdc_ui set_game_input).
local function panel_open()
    local ui = package.loaded["sdc_ui"]
    return type(ui) == "table" and ui.open == true
end

-- ---------------------------------------------------------------------------
-- The game's own input steps, on this machine's controller
-- ---------------------------------------------------------------------------

local function apply_open(pc, w)
    local wbl = ue.widget_lib()
    if not wbl then return false end
    local ok = pcall(function() wbl:SetInputMode_GameAndUIEx(pc, w, LOCK_ALWAYS, false, false) end)
    pcall(function() pc.bShowMouseCursor = true end)
    return ok
end

local function apply_close(pc)
    local wbl = ue.widget_lib()
    if not wbl then return false end
    local ok = pcall(function() wbl:SetInputMode_GameOnly(pc, false) end)
    pcall(function() pc.bShowMouseCursor = false end)
    return ok
end

-- What the game's GetPlayerController(0) gives the component and which
-- controller this machine's cursor follows (diagnostics for a switch that
-- did not reach this player).
local function controllers_note(comp, pc)
    local parts = {}
    local gps = ue.gameplay_statics()
    local got = gps and ue.try(function() return gps:GetPlayerController(comp, 0) end)
    parts[#parts + 1] = string.format("GetPlayerController(0) from the component = %s (%s)",
        ue.valid(got) and ue.short(got) or "None", same(got, pc) and "this player's" or "NOT this player's")
    local gi = ue.game_instance()
    local lps = gi and ue.prop(gi, "LocalPlayers")
    local n, first = 0, "None"
    if lps then
        pcall(function()
            lps:ForEach(function(_, e)
                n = n + 1
                if n == 1 then
                    local lp = e:get()
                    local lpc = ue.prop(lp, "PlayerController")
                    if ue.valid(lpc) then first = ue.short(lpc) end
                end
            end)
        end)
    end
    parts[#parts + 1] = string.format("%d local player(s), the first one's controller %s", n, first)
    parts[#parts + 1] = string.format("%d PlayerController object(s)", #ue.find_all("PlayerController"))
    return table.concat(parts, "; ")
end

local function new_window(w)
    st.win = { key = ue.name(w), at = os.clock(), kept = 0, fixed = false }
    return st.win
end

-- ---------------------------------------------------------------------------
-- 1. ToggleInventory (post)
-- ---------------------------------------------------------------------------

local function on_toggle(comp_p)
    if not active() then return end
    local comp = pget(comp_p)
    if not ue.valid(comp) or not own_component(comp) then return end
    local pc = ue.local_pc()
    if not pc then return end
    local w = ue.prop(comp, "InventoryWidgetRef")
    local open = in_viewport(w)
    local cursor = cursor_on(pc)
    if open then
        M.stats.opened = M.stats.opened + 1
        local win = new_window(w)
        if cursor then
            if not st.said.open_ok then
                st.said.open_ok = true
                log.info("uiinput: inventory window opened by the game; its switch to UI input reached this player's controller %s (cursor on) [%s]",
                    ue.short(pc), controllers_note(comp, pc))
            else
                log.debug("uiinput: inventory window opened (cursor on)")
            end
            return
        end
        local ok = apply_open(pc, w)
        win.fixed = true
        M.stats.fixed_open = M.stats.fixed_open + 1
        log.info("uiinput: inventory window opened but this player's controller %s still has game input (cursor off): the game's switch did not reach it; applied the game's own open step here (game+UI input on the window, cursor on, ok=%s) [%s]",
            ue.short(pc), tostring(ok), controllers_note(comp, pc))
        return
    end
    M.stats.closed = M.stats.closed + 1
    st.win = nil
    if not cursor then
        log.debug("uiinput: inventory window closed (game input, cursor off)")
        return
    end
    local other = M.game_ui_open() or (panel_open() and "the co-op panel") or nil
    if other then
        log.info("uiinput: inventory window closed; the cursor stays because %s is open", other)
        return
    end
    local ok = apply_close(pc)
    M.stats.fixed_close = M.stats.fixed_close + 1
    log.info("uiinput: inventory window closed but this player's controller %s still shows the cursor: applied the game's own close step here (game input, cursor off, ok=%s)",
        ue.short(pc), tostring(ok))
end

-- ---------------------------------------------------------------------------
-- 2. SetInputMode_GameOnly (pre) while the window is open
-- ---------------------------------------------------------------------------

local function source_hint()
    if panel_open() then return "the co-op panel" end
    return "another window's close or a late game event (an NPC dialogue's end)"
end

local function keep_window()
    st.keep_pending = false
    if not active() then return end
    local pc, w = ue.local_pc(), own_window()
    if not pc or not in_viewport(w) then
        log.debug("uiinput: the inventory window closed before its input could come back")
        return
    end
    local ok = apply_open(pc, w)
    M.stats.kept = M.stats.kept + 1
    log.info("uiinput: inventory window input restored on %s (game+UI input on the window, cursor on, ok=%s)",
        ue.short(pc), tostring(ok))
end

local function on_game_only(_, pc_p)
    if not active() then return end
    local w = own_window()
    if not in_viewport(w) then
        st.win = nil
        return
    end
    local pc = pget(pc_p)
    local mine = ue.local_pc()
    if not mine or not same(pc, mine) then return end
    local now = os.clock()
    local win = st.win
    if not win or win.key ~= ue.name(w) then win = new_window(w) end
    if win.kept >= KEEP_MAX then
        if win.kept == KEEP_MAX then
            win.kept = KEEP_MAX + 1
            M.stats.gave_up = M.stats.gave_up + 1
            log.warn("uiinput: the inventory window lost its input %d times since it opened; it is not restored again until it is reopened",
                KEEP_MAX)
        end
        return
    end
    win.kept = win.kept + 1
    log.info("uiinput: a switch to game control came while the inventory window is open (%s, %.0f ms after it opened): its own input comes back next frame",
        source_hint(), (now - win.at) * 1000)
    if st.keep_pending then return end
    st.keep_pending = true
    ue.delay("uiinput-keep", 1, keep_window)
end

-- ---------------------------------------------------------------------------
-- Install / tick
-- ---------------------------------------------------------------------------

local function safe(key, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("uiinput-" .. key, "uiinput: %s hook: %s", key, tostring(err)) end
    end
end

local BP_HOOKS = {
    { key = "toggle", path = TOGGLE_FN, fn = on_toggle },
}

local NATIVE_HOOKS = {
    -- pre only (sdc_ue.hook_native: one shared engine hook per function)
    { key = "gameonly", path = GAMEONLY_FN, fn = on_game_only },
}

local function install_hooks()
    for _, h in ipairs(NATIVE_HOOKS) do
        if not st.hooks[h.key] and ue.find_object(h.path) then
            local ok, err = ue.hook_native(h.path, "uiinput", safe(h.key, h.fn))
            st.hooks[h.key] = ok and true or "failed"
            log.info("uiinput: %s hook %s%s", h.path:match(":([%w_]+)$") or h.key, ok and "ok" or "FAILED",
                ok and "" or (" " .. tostring(err)))
        end
    end
    for _, h in ipairs(BP_HOOKS) do
        -- Blueprint functions: UE4SS runs the callback after the function;
        -- the class must be loaded first (the inventory UI loads it)
        if not st.hooks[h.key] and ue.find_object(h.path) then
            local ok, err = pcall(RegisterHook, h.path, safe(h.key, h.fn))
            st.hooks[h.key] = ok and true or "failed"
            log.info("uiinput: %s hook %s%s", h.path:match(":([%w_ ]+)$") or h.key, ok and "ok" or "FAILED",
                ok and "" or (" " .. tostring(err)))
        end
    end
end

-- Client, every second: hooks until they are in.
function M.tick()
    if not active() then return end
    install_hooks()
end

-- New world / role: window state goes (names only, nothing to release).
function M.reset(why)
    st.win, st.keep_pending, st.said = nil, false, {}
    log.debug("uiinput: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    if st.installed then return end
    st.installed = true
    ue.every("uiinput", 1000, M.tick)
    log.info("uiinput: installed (game_ui_input=%s); its hooks come from the 1 s tick on a client", tostring(M.enabled()))
end

-- Tests / diagnostics.
M._st = st

return M
