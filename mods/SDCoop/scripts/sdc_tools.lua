-- SDCoop: worn tools whose single-player checks read the host's data.
-- Driven by sdc_items (init / host_begin + host_player (host tick) / client_tick /
-- reset / register_handlers).
--
-- Binoculars. The input (BP_PlayerCharacter ubergraph @126869) asks
-- BP_JigHelperComp.GetEquippedInfoBySlot(Jig.PlayerSlot.Binoculars); it reads
-- ServerEquippedItems.EquippedBinoculars, which only the host fills (the
-- equip runs in the Jig server RPCs) and which is not replicated. On a client
-- the slot is always empty: "You do not have Binoculars equipped". The zoom
-- itself (BinocularsVisibility: widget, field of view; the distance readout
-- from ItemID.ShowDistance?) is local. Fix, as sdc_playermarks does for the
-- GPS / compass slots: the host sends the item in the client's binoculars
-- slot (its copy's ServerEquippedItems) and the client writes that item into
-- its own ServerEquippedItems, exactly what GetEquippedInfoBySlot tests.
--
-- Night vision (an NVG attachment on the worn headwear). NightVisionOn ->
-- NightVisionBatteryCheck looks the helmet up in MainJigContainers (the
-- host's data: on a client nothing is found, so the goggles never switch on),
-- and the drain timer NightVisionCheck (every 0.1 s: battery durability -=
-- 0.015 * Difficulty.BatteryDepletionMultiplier, off with "No Battery" at 0)
-- works on the same data. Fix: the host reads that battery (helmet ->
-- SubContainers[0] item 0 = the NVG -> its SubContainers[0] item 0 = the
-- battery, the check's own chain) and sends its charge; the client's check
-- answers yes while the host has a charged battery; while the client's
-- goggles are on (MYNVG) the host drains that battery with the same rate
-- through the server's ServerFuncUpdateDurabilityByUID (which tells the
-- client), and the client switches them off when the host's charge is gone.
--
-- Others checked: GPS / compass (sdc_playermarks, PEQUIP), the handheld
-- flashlight (sdc_items / sdc_pawnstate), the fishing rod (equipped actor +
-- durability by UID, sdc_items), clothing (sdc_appearance); throwables are
-- sdc_throw's.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local ctx = require("sdc_ctx")
local net = require("sdc_net")
local consume = require("sdc_consume")   -- the shared inventory walk / equipment (host)

local M = { stats = { tools_sent = 0, slot_writes = 0, nvg_checks = 0, nvg_drains = 0, nvg_offs = 0 } }
local S
function M.init(state) S = state end

local addr = ctx.addr

local PLAYER_FN = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local CONSOLE_UTILS = "/Script/AutoSettings.Default__ConsoleUtils"

-- S_ServerEquippedItems members / RepItemInfo.ItemID
local BINOCULARS = "EquippedBinoculars_57_FA37337F42E4A60116D21485F6D57AB7"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
-- (the Jig container structs are read by sdc_consume.inventory)

local RESEND = 10           -- s: the state is sent again this often even unchanged
local NVG_RATE = 0.15       -- battery durability per second (0.015 every 0.1 s)

local function is_locally_controlled(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

local function is_player_character(p)
    return ue.valid(p) and ue.class_name(p):find("PlayerCharacter", 1, true) ~= nil
end

local function param(p)
    if not p then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local hooked = {}
local function try_hook(path, tag, fn)
    if hooked[path] then return end
    local ok = pcall(RegisterHook, path, function(c, ...)
        local okc, err = pcall(fn, c, ...)
        if not okc then log.err_throttled("tools." .. tag, "tools: %s hook: %s", tag, tostring(err)) end
    end)
    if ok then
        hooked[path] = true
        log.info("tools: %s hook ok", tag)
    end
end

-- The item in a ServerEquippedItems slot of a character, or nil.
local function slot_item(p, field)
    local helper = ue.prop(p, "BP_JigHelperComp")
    if not ue.valid(helper) then return nil end
    local ok, v = pcall(function() return helper.ServerEquippedItems[field][ITEM_ID] end)
    if ok and ue.valid(v) then return v end
    return nil
end

-- ===========================================================================
-- Host
-- ===========================================================================

-- Battery of the NVG on the worn headwear, as NightVisionBatteryCheck finds
-- it: { g = Guid table, dur = charge, e = its entry in the walk } or nil (no
-- helmet / NVG / battery). The equipment and the inventory walk are the
-- tick's shared ones (`pass`, sdc_consume.host_player), read here only
-- without one.
local function nvg_battery(pawn, pass)
    local helper = ue.prop(pawn, "BP_JigHelperComp")
    local jig = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(helper) or not ue.valid(jig) then return nil end
    local helmet = nil
    for _, e in ipairs((consume.equipment_of(pass, helper))) do
        if e.tag == "Jig.PlayerSlot.Headwear" then helmet = e.g end
    end
    if not helmet then return nil end
    local inv = pass and pass.inv
    if not inv then
        inv = consume.inventory(jig, true)
        if pass then pass.inv = inv end
    end
    local by_uid, at0 = inv.by_uid, inv.at0
    local h = by_uid[helmet]
    local nvg = h and h.sub and at0[h.sub]
    local n = nvg and by_uid[nvg.uid]
    local bat = n and n.sub and at0[n.sub]
    local e = bat and by_uid[bat.uid]
    if not e then return nil end
    return { g = e.g, sub = e.sub, dur = tonumber(e.dur) or 0, e = e }
end

local function depletion_multiplier()
    local cu = ue.find_object(CONSOLE_UTILS)
    local ok, v = false, nil
    if cu then ok, v = pcall(function() return cu:GetFloatCVar(FName("Difficulty.BatteryDepletionMultiplier")) end) end
    if ok and type(v) == "number" and v >= 0 then return v end
    return 1
end

local sent = {}        -- [pc address] = { s = last message, at = os.clock() }
local nvg_on = {}      -- [pc address] = true while that client's goggles are on
local last_tick = nil
local tick = { dt = 1, mult = nil }   -- this tick's drain time step / depletion multiplier

-- Host tick (1 s), once before the players (host_player): the drain's time
-- step, the same for every player of the tick.
function M.host_begin()
    if cfg.get("client_tools") == false then return end
    local now = os.clock()
    tick.dt = last_tick and math.min(2, now - last_tick) or 1
    tick.mult = nil
    last_tick = now
end

-- One remote player: the binoculars item and NVG charge; the charge of
-- goggles that are on goes down as the client's own timer would. `pass`:
-- the tick's shared data of that player (sdc_items / sdc_consume), or nil.
function M.host_player(pc, pass)
    if cfg.get("client_tools") == false then return end
    local now = os.clock()
    local k = addr(pc)
    local pawn
    if pass then pawn = pass.pawn else pawn = ue.pawn_of(pc) end
    if k and is_player_character(pawn) then
        local bat = nvg_battery(pawn, pass)
        if nvg_on[k] and bat and bat.dur > 0 then
            tick.mult = tick.mult or depletion_multiplier()
            local out = {}
            local ok = pcall(function()
                pawn.BP_JigMultiplayer:ServerFuncUpdateDurabilityByUID(bat.g, NVG_RATE * tick.mult * tick.dt, false, out)
            end)
            M.stats.nvg_drains = M.stats.nvg_drains + 1
            if ok and type(out.NewDur) == "number" then
                bat.dur = out.NewDur
                -- the shared walk is read again by sdc_items (ITEMS) after this
                bat.e.dur = out.NewDur
            end
            if bat.dur <= 0 then log.info("tools: night vision battery of %s is empty", ue.short(pawn)) end
        end
        local bino = slot_item(pawn, BINOCULARS)
        local s = string.format("%s|%s", bino and ue.path(bino) or "", bat and string.format("%.2f", bat.dur) or "-1")
        local e = sent[k]
        if not e or e.s ~= s or now - e.at >= RESEND then
            if not e or e.s:match("^[^|]*") ~= s:match("^[^|]*") then
                log.info("tools: %s binoculars slot: %s", ue.short(pawn), bino and ue.short(bino) or "empty")
            end
            sent[k] = { s = s, at = now }
            M.stats.tools_sent = M.stats.tools_sent + 1
            net.send_to(pc, "PTOOLS", bino and ue.path(bino) or "", bat and string.format("%.2f", bat.dur) or "-1")
        end
    end
end

-- Host tick (1 s), all remote players at once (sdc_items calls host_begin and
-- host_player itself, with the players spread over the second).
function M.host_tick(remote_pcs)
    if cfg.get("client_tools") == false then return end
    M.host_begin()
    for _, pc in ipairs(remote_pcs or {}) do M.host_player(pc, nil) end
end

-- net MYNVG|<0|1>, client -> host: the client's goggles on / off.
local function on_nvg_msg(f, pc)
    if S.role ~= "host" then return end
    local k = addr(pc)
    if not k then return end
    local on = f[1] == "1"
    if (nvg_on[k] == true) ~= on then
        log.info("tools: %s night vision %s", ue.short(ue.pawn_of(pc)), on and "on" or "off")
    end
    nvg_on[k] = on or nil
end

-- ===========================================================================
-- Client
-- ===========================================================================

local own = { got = false, bino = "", nvg = -1 }

local function own_pawn()
    local p = ue.local_pawn()
    if is_player_character(p) and is_locally_controlled(p) then return p end
    return nil
end

local function load_obj(path)
    local o = ue.find_object(path)
    if not o then
        ue.load_asset(path, "tools")
        o = ue.find_object(path)
    end
    return o
end

-- net PTOOLS|<binoculars item path, "" = empty>|<NVG battery charge, -1 = none>
local function on_tools_msg(f)
    if S.role ~= "client" then return end
    local bino, nvg = f[1] or "", tonumber(f[2]) or -1
    if not own.got or own.bino ~= bino then log.info("tools: host says own binoculars slot '%s'", bino) end
    own.got, own.bino, own.nvg = true, bino, nvg
end

-- BP_PlayerCharacter.NightVisionBatteryCheck(out Successful), post (client):
-- the battery is the host's.
local function on_nvg_check(c, ok_p)
    if S.role ~= "client" or cfg.get("client_tools") == false then return end
    local p = c and c:get()
    if not is_player_character(p) or not is_locally_controlled(p) then return end
    if param(ok_p) == true then return end
    M.stats.nvg_checks = M.stats.nvg_checks + 1
    if own.got and own.nvg > 0 and pcall(function() ok_p:set(true) end) then
        log.info("tools: night vision battery check: the host's battery has %.1f -> yes", own.nvg)
    else
        log.info("tools: night vision battery check: %s", own.got and (own.nvg < 0 and "no NVG battery on the host" or "the host's battery is empty")
            or "nothing from the host yet")
    end
end

-- BP_PlayerCharacter.NightVisionOn(Enabled), post (client): tell the host.
local nvg_said = nil
local function on_nvg_on(c)
    if S.role ~= "client" then return end
    local p = c and c:get()
    if not is_player_character(p) or not is_locally_controlled(p) then return end
    local on = ue.prop(p, "PlayerUsingNightVision?") == true
    if nvg_said ~= on then
        nvg_said = on
        net.send_to_host("MYNVG", on and "1" or "0")
    end
end

local hook_at = -100

function M.client_tick()
    local now = os.clock()
    if now - hook_at >= 5 then
        hook_at = now
        try_hook(PLAYER_FN .. "NightVisionBatteryCheck", "nvg-check", on_nvg_check)
        try_hook(PLAYER_FN .. "NightVisionOn", "nvg-on", on_nvg_on)
    end
    if cfg.get("client_tools") == false or not own.got then return end
    local me = own_pawn()
    if not me then return end
    -- the binoculars slot as the host has it
    local want = own.bino ~= "" and load_obj(own.bino) or nil
    if own.bino ~= "" and not want then
        log.err_throttled("tools.asset", "tools: item %s not found on this machine", own.bino)
    end
    local have = slot_item(me, BINOCULARS)
    if (have ~= nil) ~= (want ~= nil) or (have and want and ue.name(have) ~= ue.name(want)) then
        local helper = ue.prop(me, "BP_JigHelperComp")
        local ok = ue.valid(helper) and pcall(function() helper.ServerEquippedItems[BINOCULARS][ITEM_ID] = want end)
        M.stats.slot_writes = M.stats.slot_writes + 1
        log.info("tools: own binoculars slot set from the host: %s -> %s (ok=%s)", have and ue.short(have) or "empty",
            want and ue.short(want) or "empty", tostring(ok))
    end
    -- goggles on: the HUD charge, and off when the host's battery is gone
    if ue.prop(me, "PlayerUsingNightVision?") == true then
        local hud = ue.prop(me, "InGameUI")
        if own.nvg >= 0 and ue.valid(hud) then pcall(function() hud:GetNightVisionDurability(own.nvg) end) end
        if own.nvg <= 0 then
            pcall(function() me:NightVisionOn(false) end)
            local ksl = ue.ksl()
            if ksl then pcall(function() ksl:K2_ClearTimer(me, "NightVisionCheck") end) end
            M.stats.nvg_offs = M.stats.nvg_offs + 1
            log.info("tools: night vision off: %s", own.nvg < 0 and "no NVG battery on the host" or "the host's battery is empty")
        end
    elseif nvg_said == true then
        nvg_said = false
        net.send_to_host("MYNVG", "0")
    end
end

function M.reset()
    sent, nvg_on, last_tick = {}, {}, nil
    own = { got = false, bino = "", nvg = -1 }
    nvg_said = nil
    hook_at = -100
end

function M.register_handlers()
    -- host -> client: PTOOLS|<binoculars item path>|<NVG battery charge or -1>
    net.on("PTOOLS", on_tools_msg)
    -- client -> host: MYNVG|<0|1>   (own night vision on / off)
    net.on("MYNVG", on_nvg_msg)
end

return M
