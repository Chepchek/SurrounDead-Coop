-- SDCoop: knockdown checks in the game (phase 0 of
-- work\reports\18_nokdaun_proekt.md): console sdcoop_down <what> [who] [...].
-- Loaded by the first sdcoop_down command; nothing here runs otherwise.
-- "who": a name, a row number of the F7 list, or "me". Every game call is
-- in pcall; each result is a "[DOWN] probe ..." log line and a console line.
-- Only status, down and up change the world's knockdown state; hp, god,
-- kill, deathbringer, used change the player they name (a test).

local log = require("sdc_log")
local ue = require("sdc_ue")
local ctx = require("sdc_ctx")

local M = {}
local addr = ctx.addr

local HELP = {
    "status                     records, candidates, rescuers, hooks, fuse",
    "half <who>                 the next hit on that player: a half-health probe (h0, damage, probe, h1, divisor, result)",
    "hp <who> <n>               set its health (host) and SendHealthToClient",
    "god <who> on|off           its CanTakeDamage? (host)",
    "kill <who> yes             the game's death through ApplyDamage(999) (host)",
    "deathbringer <who>         the game's Deathbringer(out Used?): flag and health before / after (restored)",
    "used <who>                 the fallback: DeathbringerSkillUsed? = true and health 1, read back (restored)",
    "pose <who> on|off          the sitting pose on that character here",
    "freeze on|off              this player's flags and frozen movement (IsMoveInputIgnored shown)",
    "prompt [game]              the game's timer bar with MaxTime 5 (game: ShowInteractWidget - may crash, test only)",
    "zombies <who> on|off       its ZombieCanAttack tag renamed / back, zombies within 50 m dropping it (host)",
    "capsule <who> on|off       its capsule's Pawn response (here); capsule use on|off: the feature's own",
    "causes on|off              a log line for every ApplyDamage on a watched player (host)",
    "vehicle                    the host out of its vehicle the knockdown way; InVehicle? after 0.5 / 1 / 2 s",
    "pos <who>                  how far its character is from its knockdown spot",
    "pause                      hide / show Save, QuickSave, Suicide on the open pause menu; AllowSaving?",
    "radial on|off              a log line for every ApplyRadialDamage (host)",
    "bleed <who>                health drops per second for 10 s",
    "key                        the interact key (IA_Interact)",
    "anim <path>                a montage / sequence of another skeleton on this player (PlaySlotAnimationAsDynamicMontage)",
    "down <who> / up <who>      put a player down without a hit / get it up (host)",
}

local function say(reply, fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    s = ok and s or tostring(fmt)
    log.info("[DOWN] probe %s", s)
    if reply then reply(s) end
end

-- who -> character, key (host: the session key; "host" = its own)
local function find(D, who)
    who = tostring(who or "me")
    local S = require("sdc_session").state
    if who == "" or who == "me" or who == "host" and S.role == "host" then
        return ue.local_pawn(), S.role == "host" and "host" or nil
    end
    if S.role == "host" then
        local roster = require("sdc_session").roster()
        local n = tonumber(who)
        local row = n and roster[n] or nil
        if row then
            if row.host then return ue.local_pawn(), "host" end
            return row.key and D.pawn_of_key(row.key), row.key
        end
        local low = who:lower()
        for key, r in pairs(S.remote or {}) do
            if tostring(r.name or ""):lower() == low then return D.pawn_of_key(key), key end
        end
        return nil
    end
    local low = who:lower()
    for _, p in ipairs(ue.player_chars() or {}) do
        local ps = ue.prop(p, "PlayerState")
        local n = ue.valid(ps) and ue.str(ue.try(function() return ps:GetPlayerName() end)) or ""
        if n:lower() == low then return p, nil end
    end
    return nil
end

local function med(p) return ue.prop(p, "MedicalComponent") end
local function hp(p) return ue.prop(med(p), "Health") end

local function words(params)
    local w, i = {}, 1
    while params[i] ~= nil do
        w[#w + 1] = ue.str(params[i])
        i = i + 1
    end
    return w
end

function M.run(D, params, reply)
    local w = words(params)
    local what = (w[1] or "help"):lower()
    local H = D._H
    local pose = package.loaded["sdc_down_pose"]
    local S = require("sdc_session").state
    local host = S.role == "host"
    local function need_host()
        if not host then say(reply, "%s: host only", what) return false end
        return true
    end
    local function target(i)
        local p, key = find(D, w[i or 2])
        if not ue.valid(p) then say(reply, "%s: no character for '%s'", what, tostring(w[i or 2] or "me")) return nil end
        return p, key
    end
    if what == "help" then
        for _, l in ipairs(HELP) do reply("sdcoop_down " .. l) end
    elseif what == "status" then
        reply(D.status_line())
        if pose then reply("pose: " .. pose.status()) end
        if host then
            for key, r in pairs(S.remote or {}) do
                reply(string.format("  %s: downcap=%s ready=%s access=%s rescuers besides it=%d", tostring(r.name),
                    tostring(r.downcap), tostring(r.down_ready), tostring(r.access), D.rescuers(key)))
            end
            reply(string.format("  host: rescuers besides it=%d", D.rescuers("host")))
        end
    elseif what == "half" then
        if not need_host() then return end
        local p = target()
        if not p then return end
        H.half[addr(p)] = true
        D.recount()
        local ai = require("sdc_ai")
        ai.install_now()
        say(reply, "half: the next hit on %s is a half-health probe (health now %s)", ue.short(p), tostring(hp(p)))
    elseif what == "hp" then
        if not need_host() then return end
        local p = target()
        local n = tonumber(w[3])
        if not p or not n then return end
        local ok = ue.set_prop(med(p), "Health", n)
        local oks, e = pcall(function() p:SendHealthToClient(n) end)
        say(reply, "hp: %s health %s (write %s, SendHealthToClient %s%s)", ue.short(p), tostring(hp(p)), tostring(ok),
            tostring(oks), oks and "" or (": " .. tostring(e)))
    elseif what == "god" then
        if not need_host() then return end
        local p = target()
        if not p then return end
        local on = w[3] == "on"
        local ok = ue.set_prop(med(p), "CanTakeDamage?", not on)
        say(reply, "god: %s CanTakeDamage? = %s (write %s)", ue.short(p), tostring(ue.prop(med(p), "CanTakeDamage?")), tostring(ok))
    elseif what == "kill" then
        if not need_host() then return end
        local p = target()
        if not p then return end
        if w[3] ~= "yes" then say(reply, "kill: add 'yes' to really kill %s", ue.short(p)) return end
        local r = D.kill_pawn(p, "sdcoop_down kill", ue.short(p))
        say(reply, "kill: %s -> %s (PlayerDead?=%s health=%s)", ue.short(p), r, tostring(ue.prop(p, "PlayerDead?")), tostring(hp(p)))
    elseif what == "deathbringer" or what == "used" then
        if not need_host() then return end
        local p = target()
        if not p then return end
        local f0, h0 = ue.prop(p, "DeathbringerSkillUsed?"), hp(p)
        if what == "deathbringer" then
            local out = {}
            local ok, e = pcall(function() p:Deathbringer(out) end)
            say(reply, "deathbringer: %s call %s%s: Used?=%s flag %s -> %s, health %s -> %s", ue.short(p), tostring(ok),
                ok and "" or (" (" .. tostring(e) .. ")"), tostring(out["Used?"]), tostring(f0),
                tostring(ue.prop(p, "DeathbringerSkillUsed?")), tostring(h0), tostring(hp(p)))
        else
            local a = ue.set_prop(p, "DeathbringerSkillUsed?", true)
            local b = ue.set_prop(med(p), "Health", 1)
            say(reply, "used: %s DeathbringerSkillUsed? write %s -> %s, health write %s -> %s", ue.short(p), tostring(a),
                tostring(ue.prop(p, "DeathbringerSkillUsed?")), tostring(b), tostring(hp(p)))
        end
        ue.set_prop(p, "DeathbringerSkillUsed?", f0 == true)
        if type(h0) == "number" then
            ue.set_prop(med(p), "Health", h0)
            pcall(function() p:SendHealthToClient(h0) end)
        end
        say(reply, "%s: %s restored (flag %s, health %s)", what, ue.short(p), tostring(ue.prop(p, "DeathbringerSkillUsed?")), tostring(hp(p)))
    elseif what == "pose" then
        local p = target()
        if not p or not pose then return end
        local on = w[3] ~= "off"
        pose.test_pose(p, on)
        if on then pose.hold_pose(p) end
        local cur = ue.try(function() return p:GetCurrentMontage() end)
        local cam = ue.try(function() return ue.local_pc().PlayerCameraManager:GetCameraLocation() end)
        say(reply, "pose: %s %s; montage now %s; montage in memory %s; camera %s", ue.short(p), on and "on" or "off",
            ue.valid(cur) and ue.short(cur) or "none", tostring(pose.montage(pose.FLOOR) ~= nil),
            cam and string.format("%.0f,%.0f,%.0f", cam.X, cam.Y, cam.Z) or "?")
    elseif what == "freeze" then
        if not pose then return end
        local on = w[2] ~= "off"
        pose.test_freeze(on)
        ue.delay("down-probe", 500, function()
            -- the controller again (a world change in 0.5 s frees the old one)
            local pc = ue.local_pc()
            say(reply, "freeze %s: IsMoveInputIgnored=%s MovementMode=%s IsPlayerRolling?=%s", on and "on" or "off",
                tostring(pc and ue.try(function() return pc:IsMoveInputIgnored() end)),
                tostring(ue.prop(ue.prop(ue.local_pawn(), "CharacterMovement"), "MovementMode")),
                tostring(ue.prop(ue.local_pawn(), "IsPlayerRolling?")))
        end)
    elseif what == "prompt" then
        if not pose then return end
        if w[2] == "game" then
            local pc = ue.local_pc()
            local hud = pc and ue.try(function() return pc:GetHUD() end)
            if not ue.valid(hud) then say(reply, "prompt game: no HUD") return end
            local ok, e = pcall(function() hud:ShowInteractWidget(true, FText("Player"), FText("[F] Revive"), {}, {}, {}) end)
            say(reply, "prompt game: ShowInteractWidget %s%s; it closes in 3 s", tostring(ok), ok and "" or (" (" .. tostring(e) .. ")"))
            ue.delay("down-probe", 3000, function()
                -- the HUD again: the one of 3 s ago may be gone with its world
                local pc2 = ue.local_pc()
                local hud2 = pc2 and ue.try(function() return pc2:GetHUD() end)
                if ue.valid(hud2) then
                    pcall(function() hud2:ShowInteractWidget(false, FText(""), FText(""), {}, {}, {}) end)
                end
            end)
            return
        end
        local ok = pose.bar("probe", "Revive test", 2.5, 5)
        local hud = ue.try(function() return ue.local_pc():GetHUD() end)
        local wd = ue.prop(hud, "InteractTimerWidget")
        say(reply, "prompt: timer bar %s; widget %s CurrentTime=%s MaxTime=%s; it closes in 3 s", tostring(ok),
            ue.valid(wd) and ue.short(wd) or "none", tostring(ue.prop(wd, "CurrentTime")), tostring(ue.prop(wd, "MaxTime")))
        ue.delay("down-probe", 3000, function() pose.bar_off() end)
    elseif what == "zombies" then
        if not need_host() then return end
        local p = target()
        if not p then return end
        if w[3] == "off" then
            local i = D.tag_swap(p, "SDCDown", "ZombieCanAttack")
            say(reply, "zombies off: tag back at %s; ActorHasTag(ZombieCanAttack)=%s", tostring(i),
                tostring(ue.try(function() return p:ActorHasTag(FName("ZombieCanAttack")) end)))
        else
            local i = D.tag_swap(p, "ZombieCanAttack", "SDCDown")
            local n = D.drop_zombies(p, ue.location(p))
            say(reply, "zombies on: tag renamed at %s; ActorHasTag(ZombieCanAttack)=%s; %d zombie(s) dropped it", tostring(i),
                tostring(ue.try(function() return p:ActorHasTag(FName("ZombieCanAttack")) end)), n)
        end
    elseif what == "capsule" then
        if not pose then return end
        if w[2] == "use" then
            pose.capsule_use(w[3] == "on")
            say(reply, "capsule use %s (the feature's own, until the game restarts)", w[3] == "on" and "on" or "off")
            return
        end
        local p = target()
        if not p then return end
        local cap = ue.prop(p, "CapsuleComponent")
        local was = ue.try(function() return cap:GetCollisionResponseToChannel(2) end)
        local ok = pcall(function() cap:SetCollisionResponseToChannel(2, w[3] == "off" and 2 or 0) end)
        say(reply, "capsule: %s Pawn response %s -> %s (call %s)", ue.short(p), tostring(was),
            tostring(ue.try(function() return cap:GetCollisionResponseToChannel(2) end)), tostring(ok))
    elseif what == "causes" or what == "radial" then
        if not need_host() then return end
        local on = w[2] ~= "off"
        if what == "causes" then H.log_causes = on else H.log_radial = on end
        require("sdc_ai").install_now()
        say(reply, "%s %s (hooks are installed while knockdown is armed or somebody is down)", what, on and "on" or "off")
    elseif what == "vehicle" then
        if not need_host() then return end
        local vm = package.loaded["sdc_vehicles"]
        if not (vm and vm.force_out_host) then say(reply, "vehicle: sdc_vehicles has no force_out_host") return end
        local ok, r = pcall(vm.force_out_host, "probe")
        say(reply, "vehicle: force_out_host %s: %s", tostring(ok), tostring(r))
        for _, ms in ipairs({ 500, 1000, 2000 }) do
            ue.delay("down-probe", ms, function()
                local p = ue.local_pawn()
                say(reply, "vehicle: after %d ms InVehicle?=%s attached=%s", ms, tostring(ue.prop(p, "InVehicle?")),
                    tostring(ue.valid(ue.try(function() return p:GetAttachParentActor() end))))
            end)
        end
    elseif what == "pos" then
        local p = target()
        if not p then return end
        local id = D.player_id(p)
        local v = id and D.views()[id]
        local l = ue.location(p)
        if v and v.spot and l then
            say(reply, "pos: %s %.0f cm from its spot (horizontal %.0f)", ue.short(p), D.dist(l, v.spot), D.hdist(l, v.spot))
        else
            say(reply, "pos: %s is not down here; at %s", ue.short(p), l and string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) or "?")
        end
    elseif what == "pause" then
        local n = 0
        for _, sw in ipairs(ue.find_all("PauseScreen_C")) do
            if ue.valid(sw) and ue.try(function() return sw:IsInViewport() end) == true then
                n = n + D._t.hide_pause(sw)
            end
        end
        if n > 0 then
            ue.delay("down-probe", 3000, function()
                -- the menus open now (the one of 3 s ago may have been closed
                -- and collected): never a call on the old object
                for _, sw in ipairs(ue.find_all("PauseScreen_C")) do
                    if ue.valid(sw) and ue.try(function() return sw:IsInViewport() end) == true then
                        pcall(function() sw:RemoveSaveAndSuicideButton() end)
                    end
                end
            end)
        end
        local gi = ue.game_instance()
        say(reply, "pause: %d button(s) hidden on the open pause menu (back in 3 s); AllowSaving?=%s", n,
            tostring(ue.prop(gi, "AllowSaving?")))
    elseif what == "bleed" then
        local p = target()
        if not p then return end
        local a, n, drops, last = addr(p), 0, 0, hp(p)
        local function step()
            n = n + 1
            local q = nil
            for _, c in ipairs(ue.player_chars() or {}) do if ue.valid(c) and addr(c) == a then q = c end end
            local h = q and hp(q)
            if type(h) == "number" and type(last) == "number" and h < last then drops = drops + 1 end
            last = h
            if n < 100 then ue.delay("down-probe", 100, step) else
                say(reply, "bleed: %s: %d health drop(s) in 10 s (bleed=%s heavy=%s)", ue.short(p), drops,
                    tostring(ue.prop(med(q), "Bleed?")), tostring(ue.prop(med(q), "HeavyBleed?")))
            end
        end
        step()
        say(reply, "bleed: watching %s for 10 s", ue.short(p))
    elseif what == "key" then
        if not pose then return end
        local _, name = pose.interact_key()
        say(reply, "key: IA_Interact in memory=%s, mapped to %s", tostring(ue.find_object(pose.IA_INTERACT) ~= nil), tostring(name))
    elseif what == "anim" then
        local path = w[2]
        local p = ue.local_pawn()
        if not path or not p then say(reply, "anim: sdcoop_down anim <asset path>") return end
        local seq = ue.loaded_asset(path, "down probe")
        if not seq then
            local ok, o = ue.load_asset(path, "down probe")
            seq = ok and ue.valid(o) and o or nil
        end
        if not seq then say(reply, "anim: %s not found", path) return end
        local mesh = ue.prop(p, "Mesh")
        local anim = ue.valid(mesh) and ue.try(function() return mesh:GetAnimInstance() end)
        local ok, e = pcall(function() anim:PlaySlotAnimationAsDynamicMontage(seq, FName("DefaultSlot"), 0.25, 0.25, 1.0, 1, -1, 0) end)
        say(reply, "anim: %s on this player: %s%s", path, tostring(ok), ok and "" or (" (" .. tostring(e) .. ")"))
    elseif what == "down" then
        if not need_host() then return end
        local p, key = target()
        if not p or not key then return end
        D._start(key, p, hp(p) or 50, nil, "sdcoop_down down")
        say(reply, "down: %s put down without a hit", ue.short(p))
    elseif what == "up" then
        if not need_host() then return end
        local _, key = target()
        if not key then return end
        say(reply, "up: %s", tostring(D.revive(key, nil, "up")))
    else
        say(reply, "unknown '%s' (sdcoop_down help)", what)
    end
end

return M
