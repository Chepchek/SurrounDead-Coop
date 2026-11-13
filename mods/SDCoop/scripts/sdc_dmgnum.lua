-- SDCoop: floating damage numbers of a client's own hits.
--
-- The game shows them from the weapon's Client_HitUI (NetClient RPC, called
-- after ApplyDamage in BP_FirearmPickup @4480/5801/6017/6245 and
-- BP_MeleePickup @841) -> GameFunctionLibrary.SpawnDamageNumbers(Dmg, Colour,
-- ImpactPoint): FloatingDamageNumbersUI_C projected through player 0.
-- A NetClient RPC reaches a client only when the weapon belongs to that
-- client's connection; otherwise it runs on the host, and the client sees no
-- numbers. Here:
--   host:   Client_HitUI that ran on the host for a remote player's weapon is
--           sent to that player (DMGNUM).
--   client: DMGNUM -> the game's own SpawnDamageNumbers on this machine.
--           A Client_HitUI that arrives natively is only counted (that path
--           already shows the numbers).
--
-- Hit marker of a client's own firearm hits (combat.md section 4).
-- Single player: the shooter's FireSurfaceHit -> Trace_BodyImpact / Trace_Headshot
-- -> SERVER_DamageEvent(Headshot, Actor, ImpactPoint) runs at once, and after
-- its Client_HitUI (@5801 body / @4480 head) it calls
-- GetOwner().GetInGameUI().Hitmarker(white @3372 / red @3604)
-- (BP_Ingame.Hitmarker: CVar UI.Hitmarker, colour, HitmarkerEffect animation).
-- In co-op that server half runs on the host's copy of the client's
-- character, which has no InGameUI: the client never saw a marker.
--   client: when the server's Client_HitUI of the own firearm arrives (the
--           moment the game shows the damage number), the own
--           InGameUI.Hitmarker is called with the game's colour: red when the
--           impact point is one of the own Trace_Headshot points (the headshot
--           branch that sent SERVER_DamageEvent(true) with that point), white
--           otherwise. The Client_HitUI the client runs itself after an object
--           hit (@6017 / @6245, impact point 0,0,0) has no marker in the game.
--           Projectile weapons (crossbow) whose shots fly on the host
--           (sdc_throw, launcher_sync): the marker comes with the host's
--           report of the hit (sdc_throw calls M.hitmarker).
-- Config client_hitmarker.

local log = require("sdc_log")
local ue  = require("sdc_ue")
local net = require("sdc_net")
local cfg = require("sdc_config")

local M = { stats = { host_forwarded = 0, client_native = 0, client_shown = 0, failed = 0, zero_hidden = 0,
                      markers = 0, markers_head = 0, marker_failed = 0, heads = 0, marker_skipped = 0 } }

local S
function M.init(state) S = state end

local HOOKS = {
    firearm = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Client_HitUI",
    melee   = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C:Client_HitUI",
}
local GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local MAX_DMG = 100000

local hooked = {}
local seen = {}
-- hooks whose Blueprint class is not loaded yet (it loads with the first
-- weapon of its kind): the next try per hook (sdc_ue.backoff)
local RETRY_S, RETRY_MAX_S = 1, 30
local retry = {}

local function due(key, now)
    local r = retry[key]
    return r == nil or now >= r.next_try
end

local function missed(key, now)
    local r = retry[key]
    if not r then
        r = {}
        retry[key] = r
    end
    ue.backoff(r, now, RETRY_S, RETRY_MAX_S)
end

local function once(key, fmt, ...)
    if seen[key] then return end
    seen[key] = true
    log.info(fmt, ...)
end

local function num(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return 0 end
    return v
end

-- weapon -> owning player character and its controller on the host, when
-- that controller belongs to a remote connection
local function remote_owner(w)
    if not ue.valid(w) then return nil end
    local pawn = ue.try(function() return w:GetOwner() end)
    if not ue.valid(pawn) or not ue.class_name(pawn):find("PlayerCharacter", 1, true) then return nil end
    local pc = ue.prop(pawn, "Controller")
    if not ue.valid(pc) or not ue.valid(ue.prop(pc, "NetConnection")) then return nil end
    return pawn, pc
end

-- ---------------------------------------------------------------------------
-- Client: hit marker of the own firearm hits
-- ---------------------------------------------------------------------------

local TRACE_HEAD = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C:Trace_Headshot"
local WHITE = { R = 1, G = 1, B = 1, A = 1 }    -- BP_FirearmPickup @3372
local RED = { R = 1, G = 0, B = 0, A = 1 }      -- @3604
local HEAD_KEEP_S = 5      -- s an own headshot point waits for its Client_HitUI
local HEAD_MATCH_CM = 3    -- the same vector, sent there and back
local HEADS_MAX = 32
local heads = {}           -- own Trace_Headshot points { x, y, z, os.clock() }
local head_hooked = false

local function marker_on() return cfg.get("client_hitmarker") ~= false end

local function addr_of(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

local function vec3(v)
    if v == nil then return nil end
    local x = tonumber(ue.try(function() return v.X end))
    local y = tonumber(ue.try(function() return v.Y end))
    local z = tonumber(ue.try(function() return v.Z end))
    if not (x and y and z) or x ~= x or y ~= y or z ~= z then return nil end
    return { X = x, Y = y, Z = z }
end

-- The game's own marker on this player's screen: InGameUI.Hitmarker (what
-- GetInGameUI returns, BP_PlayerCharacter@7380). Returns true when shown.
function M.hitmarker(head, why)
    if not S or S.role ~= "client" or not marker_on() then return false end
    local pawn = ue.local_pawn()
    local ui = pawn and ue.prop(pawn, "InGameUI") or nil
    if not ue.valid(ui) then
        M.stats.marker_failed = M.stats.marker_failed + 1
        log.err_throttled("dmgnum.marker-ui", "dmgnum: no InGameUI on the own character for a hit marker (%s)", tostring(why))
        return false
    end
    local ok, err = pcall(function() ui:Hitmarker(head and RED or WHITE) end)
    if not ok then
        M.stats.marker_failed = M.stats.marker_failed + 1
        log.err_throttled("dmgnum.marker", "dmgnum: Hitmarker failed: %s", tostring(err))
        return false
    end
    M.stats.markers = M.stats.markers + 1
    if head then M.stats.markers_head = M.stats.markers_head + 1 end
    if M.stats.markers <= 3 or (head and M.stats.markers_head <= 2) then
        log.info("dmgnum: hit marker (%s) shown for an own hit (%s)", head and "red, head" or "white, body", tostring(why))
    end
    return true
end

-- BP_FirearmPickup.Trace_Headshot(Location, Rotation, Actor), after it ran:
-- only on the shooter's machine (FireSurfaceHit). Location is the impact point
-- it sends with SERVER_DamageEvent(true), and Client_HitUI brings it back.
local function on_trace_head(loc_p)
    if not S or S.role ~= "client" or not marker_on() then return end
    local l = vec3(ue.try(function() return loc_p:get() end))
    if not l then return end
    heads[#heads + 1] = { l.X, l.Y, l.Z, os.clock() }
    if #heads > HEADS_MAX then table.remove(heads, 1) end
    M.stats.heads = M.stats.heads + 1
end

-- true when p is a remembered own headshot point (used up); old ones go.
local function take_head(p)
    local now = os.clock()
    for i = #heads, 1, -1 do
        local h = heads[i]
        if now - h[4] > HEAD_KEEP_S then
            table.remove(heads, i)
        elseif math.abs(h[1] - p.X) <= HEAD_MATCH_CM and math.abs(h[2] - p.Y) <= HEAD_MATCH_CM
            and math.abs(h[3] - p.Z) <= HEAD_MATCH_CM then
            table.remove(heads, i)
            return true
        end
    end
    return false
end

local function uses_projectile(w)
    return ue.prop(ue.prop(w, "BP_WeaponsPickupComponent"), "DoesWeaponUseAProjectile?") == true
end

-- Client_HitUI of a firearm on this client: the server's answer to the own
-- SERVER_DamageEvent (or the own object-hit call, impact point 0,0,0).
local function client_marker(w, imp_p)
    if not marker_on() then return end
    local me = ue.local_pawn()
    local owner = ue.try(function() return w:GetOwner() end)
    if not me or not ue.valid(owner) or addr_of(owner) ~= addr_of(me) then return end
    local p = vec3(ue.try(function() return imp_p:get() end))
    if not p or math.abs(p.X) + math.abs(p.Y) + math.abs(p.Z) < 0.01 then return end
    if uses_projectile(w) then
        local throw = package.loaded["sdc_throw"]
        if type(throw) == "table" and type(throw.host_drives_projectiles) == "function" and throw.host_drives_projectiles() then
            -- the bolt flew on the host: its marker comes with the host's report of the hit
            M.stats.marker_skipped = M.stats.marker_skipped + 1
            return
        end
    end
    M.hitmarker(take_head(p), "Client_HitUI " .. ue.short(w))
end

local function on_hit_ui(kind, w, dmg_p, col_p, imp_p)
    if not S then return end
    if S.role == "client" then
        M.stats.client_native = M.stats.client_native + 1
        once("native", "dmgnum: Client_HitUI reached this client natively (%s %s), the game shows the numbers", kind, ue.short(w))
        if kind == "firearm" then client_marker(w, imp_p) end
        return
    end
    if S.role ~= "host" or #(S.remote_pcs or {}) == 0 then return end
    local _, pc = remote_owner(w)
    if not pc then return end
    local dmg = num(ue.try(function() return dmg_p:get() end))
    local col = ue.try(function() return col_p:get() end)
    local imp = ue.try(function() return imp_p:get() end)
    if not col or not imp then return end
    local c = string.format("%.3f,%.3f,%.3f,%.3f",
        num(ue.try(function() return col.R end)), num(ue.try(function() return col.G end)),
        num(ue.try(function() return col.B end)), num(ue.try(function() return col.A end)))
    local p = string.format("%.1f,%.1f,%.1f",
        num(ue.try(function() return imp.X end)), num(ue.try(function() return imp.Y end)),
        num(ue.try(function() return imp.Z end)))
    if net.send_to(pc, "DMGNUM", string.format("%.2f", dmg), c, p) then
        M.stats.host_forwarded = M.stats.host_forwarded + 1
        once("fwd|" .. kind, "dmgnum: %s Client_HitUI of %s ran on the host, sent to %s (dmg %.1f)",
            kind, ue.short(w), ue.short(pc), dmg)
    end
end

-- Client: the "0" next to every knife hit. A client's own swing also runs
-- the melee trace on the client (the attack montage's notify), whose
-- ApplyDamage has no authority there and returns 0; Client_HitUI then shows
-- "0" locally while the host's real hit arrives through the RPC. The 0 widget
-- is hidden as it is added to the viewport (SpawnDamageNumbers sets Damage
-- before AddToViewport). Co-op client only; single player is untouched.
local VIEWPORT_FN = "/Script/UMG.UserWidget:AddToViewport"
local NUM_CLASS = "FloatingDamageNumbersUI_C"
local zero_hooked = false

local function on_add_to_viewport(w)
    if not S or S.role ~= "client" then return end
    if not ue.valid(w) or ue.class_name(w) ~= NUM_CLASS then return end
    local dmg = tonumber(ue.prop(w, "Damage"))
    if dmg == nil or math.abs(dmg) >= 0.5 then return end
    pcall(function() w:SetVisibility(1) end)          -- Collapsed
    -- removed a moment later (removing it inside AddToViewport would be
    -- undone by the add itself); the number widget lives ~1 s on its own
    ue.delay("dmgnum-zero", 30, function()
        if ue.valid(w) and ue.class_name(w) == NUM_CLASS then pcall(function() w:RemoveFromParent() end) end
    end)
    M.stats.zero_hidden = M.stats.zero_hidden + 1
    if M.stats.zero_hidden <= 2 then log.info("dmgnum: a 0 damage number of the local melee trace hidden") end
end

-- UserWidget.AddToViewport, pre: a subscriber of sdc_ue.hook_native (it runs
-- in its own pcall there)
local function on_viewport(ctx) on_add_to_viewport(ctx and ctx:get()) end

local function hook_zero_filter()
    if zero_hooked or cfg.get("hide_zero_damage_numbers") == false then return end
    zero_hooked = true
    local ok, err = ue.hook_native(VIEWPORT_FN, "dmgnum.zero", on_viewport)
    log.info("dmgnum: zero damage number filter %s%s", ok and "ok" or "FAILED ", ok and "" or tostring(err))
end

-- Registered on both roles, once each class is loaded (retried until then,
-- less often each time: at most every 30 s).
function M.try_hooks()
    local now = os.clock()
    if S and S.role == "client" then hook_zero_filter() end
    if S and S.role == "client" and not head_hooked and marker_on() and due("head", now) then
        -- the firearm class loads with the first firearm
        local ok = pcall(RegisterHook, TRACE_HEAD, function(_, loc_p)
            local okh, err = pcall(on_trace_head, loc_p)
            if not okh then log.err_throttled("dmgnum.head", "dmgnum: Trace_Headshot hook: %s", tostring(err)) end
        end)
        if ok then
            head_hooked = true
            log.info("dmgnum: Trace_Headshot hook ok (colour of the client's hit marker)")
        else
            missed("head", now)
        end
    end
    for kind, path in pairs(HOOKS) do
        if not hooked[kind] and due(kind, now) then
            local ok = pcall(RegisterHook, path, function(c, d, col, imp)
                local okh, err = pcall(function() on_hit_ui(kind, c and c:get(), d, col, imp) end)
                if not okh then log.err_throttled("dmgnum." .. kind, "dmgnum: %s hook: %s", kind, tostring(err)) end
            end)
            if ok then
                hooked[kind] = true
                log.info("dmgnum: %s Client_HitUI hook ok", kind)
            else
                missed(kind, now)
            end
        end
    end
end

local function floats(s, n)
    local out = {}
    for v in tostring(s or ""):gmatch("[^,]+") do out[#out + 1] = tonumber(v) end
    if #out ~= n then return nil end
    for i = 1, n do if not out[i] or out[i] ~= out[i] then return nil end end
    return out
end

function M.register_handlers()
    -- host -> client: DMGNUM|<damage>|<r,g,b,a>|<x,y,z>
    net.on("DMGNUM", function(f)
        if not S or S.role ~= "client" then return end
        local dmg = tonumber(f[1])
        local c, p = floats(f[2], 4), floats(f[3], 3)
        if not dmg or dmg ~= dmg or dmg < 0 or dmg > MAX_DMG or not c or not p then return end
        local gfl = ue.find_object(GFL)
        local wc = ue.local_pc()
        if not ue.valid(gfl) or not ue.valid(wc) then return end
        local ok, err = pcall(function()
            gfl:SpawnDamageNumbers(dmg, { R = c[1], G = c[2], B = c[3], A = c[4] }, { X = p[1], Y = p[2], Z = p[3] }, wc)
        end)
        if ok then
            M.stats.client_shown = M.stats.client_shown + 1
            if M.stats.client_shown <= 2 then log.info("dmgnum: showed %.1f from the host", dmg) end
        else
            M.stats.failed = M.stats.failed + 1
            log.err_throttled("dmgnum.spawn", "dmgnum: SpawnDamageNumbers failed: %s", tostring(err))
        end
    end)
end

return M
