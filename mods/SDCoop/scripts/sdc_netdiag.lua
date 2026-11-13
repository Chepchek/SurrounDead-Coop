-- SDCoop: network diagnostics for "the world does not open for friends".
--
-- A shipping build writes no engine log, so when "open <map>?listen" stays
-- standalone nothing says why. This logs what the engine has: the net driver
-- definitions (the game names SteamSockets.SteamSocketsNetDriver with
-- OnlineSubsystemUtils.IpNetDriver as fallback), whether those classes exist,
-- every NetDriver object, and the world's own driver / net mode.
--
-- switch_to_ip: the GameNetDriver definition is switched to IpNetDriver in
-- memory (the engine reads UEngine.NetDriverDefinitions each time it creates
-- a driver): a plain UDP listen server on port 7777, the same as an exe
-- started outside Steam. sdc_steamlink does it at start, sdc_session before
-- every listen and IP join; the Steam link helper and IP joins both use it.

local log = require("sdc_log")
local ue  = require("sdc_ue")

local M = { ip_fallback = false }

local function engine()
    return ue.find_first("GameEngine")
end

local function each_definition(fn)
    local eng = engine()
    local defs = ue.valid(eng) and ue.prop(eng, "NetDriverDefinitions")
    if not defs then return false end
    local ok = pcall(function()
        defs:ForEach(function(i, e)
            local d = e:get()
            fn(i, d)
        end)
    end)
    return ok
end

function M.report(why)
    log.info("netdiag [%s]: role=%s steam id=%s", tostring(why), ue.net_role(),
        tostring(package.loaded["sdc_steam"] and package.loaded["sdc_steam"].id or "?"))
    local any = each_definition(function(i, d)
        log.info("netdiag: definition %d: %s -> %s (fallback %s)", i, ue.str(d.DefName), ue.str(d.DriverClassName),
            ue.str(d.DriverClassNameFallback))
    end)
    if not any then log.info("netdiag: net driver definitions not readable") end
    for _, path in ipairs({ "/Script/SteamSockets.SteamSocketsNetDriver", "/Script/SteamSockets.SteamSocketsNetConnection",
                            "/Script/OnlineSubsystemUtils.IpNetDriver", "/Script/OnlineSubsystemUtils.IpConnection" }) do
        log.info("netdiag: class %s %s", path, ue.find_object(path) and "present" or "MISSING")
    end
    local n = 0
    for _, d in ipairs(ue.find_all("NetDriver")) do
        if ue.valid(d) and not ue.short(d):find("^Default__") then
            n = n + 1
            log.info("netdiag: driver %s class=%s name=%s", ue.short(d), ue.class_name(d), ue.str(ue.prop(d, "NetDriverName")))
        end
    end
    log.info("netdiag: %d net driver object(s)", n)
    local wc = ue.world_context()
    local world = wc and ue.try(function() return wc:GetWorld() end)
    local nd = ue.valid(world) and ue.prop(world, "NetDriver")
    log.info("netdiag: world %s driver=%s", ue.short(world), ue.valid(nd) and (ue.short(nd) .. " " .. ue.class_name(nd)) or "none")
end

-- GameNetDriver -> IpNetDriver in memory. Returns true when changed.
function M.switch_to_ip()
    local changed = false
    each_definition(function(_, d)
        if ue.str(d.DefName) == "GameNetDriver" then
            local ok = pcall(function()
                d.DriverClassName = FName("OnlineSubsystemUtils.IpNetDriver")
                d.DriverClassNameFallback = FName("OnlineSubsystemUtils.IpNetDriver")
            end)
            changed = ok and ue.str(d.DriverClassName):find("IpNetDriver", 1, true) ~= nil
            log.info("netdiag: GameNetDriver definition -> %s (ok=%s)", ue.str(d.DriverClassName), tostring(ok))
        end
    end)
    M.ip_fallback = changed
    return changed
end

return M
