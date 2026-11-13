-- SDCoop: a client renames a placed storage container (crate, cupboard, safe,
-- locker...) and every machine shows the same name, saved with the host's
-- world.
--
-- How the game renames one (work\re\pseudo_rename\BuildableRenameObject.txt,
-- pseudo\BuildableMaster_Container.txt, HUD_Game.txt, GameFunctionLibrary.txt):
--   * "Rename" is interact option Jig.InteractOptions.Option2 of
--     BuildableMaster_Container_C (Buildable_StorageCrate and the other placed
--     containers are its children). On the presser's machine
--     Buildable_MASTER.OnExecuteInteract @4051 -> its character's
--     OnRequestServerInteract -> BP_JigComponent.SERVER_ForwardInteract
--     (Server RPC on its own component) -> on the server
--     BuildableMaster_Container.OnServerExecuteInteract(Option, ByActor):
--     @2778 CurrentActor = ByActor, Option2 @3101 GameFunctionLibrary.GetHUD(
--     self) -> HUD_Game.ShowChangeObjectNameWidget(true, self).
--   * GetHUD @807: GetPlayerController(self, 0), its pawn valid and
--     IsLocalController -> GetHUD, else None.
--   * ShowChangeObjectNameWidget @257: BuildableRenameObject_C with ActorRef =
--     the container, AddToViewport, UI-only input and cursor (false: remove,
--     game input back).
--   * BuildableRenameObject.Confirm: empty text -> OverrideBuildName(
--     "Container"), else OverrideBuildName(EditableText.GetText()) through
--     BPI_Buildables on ActorRef, then the window closes. No server call, no
--     length limit (the EditableText has none).
--   * BuildableMaster_Container.OverrideBuildName @3889: ContainerName = Name.
--     ContainerName (Text) is CPF_SaveGame and NOT replicated: Easy Multi Save
--     keeps it with the actor where the world is saved (the host); BeginPlay
--     @985 sets it from PickupDataAsset.name. Each machine shows its own copy's
--     ContainerName: OnBeginInteract (ShowInteractWidget) and the storage
--     window's title (OnInteractBuildable -> AddJigWidgetToContent).
-- In co-op:
--   * a client's Rename runs OnServerExecuteInteract on the host. sdc_ctx's
--     scope turns GetPlayerController(container, 0) into that client's
--     controller (CurrentActor), which is not local on the host: GetHUD gives
--     None and no window opens anywhere (without the scope it opened on the
--     host's screen). A client could not rename at all.
--   * the host's own rename changed the host's copy only: clients kept the
--     default name (also after joining or a load).
-- Here (config world_rename, under world_sync):
--   host   OnServerExecuteInteract (post), Option2 by a remote player -> RNOPEN
--          to that client (a rename window the host's HUD opened for it is
--          closed again).
--   client RNOPEN -> HUD_Game.ShowChangeObjectNameWidget(true, its copy): the
--          game's own window, which runs Confirm -> OverrideBuildName here.
--   client OverrideBuildName (post) on its copy -> RNREQ to the host.
--   host   RNREQ (a player near it, or one it opened the window for) ->
--          OverrideBuildName(name) on the host's copy: the game's own function,
--          so the host's save carries the name -> RNAME to every client. A
--          refused request gets the host's name back (RNAME to that client).
--   host   OverrideBuildName (post) of its own rename -> RNAME to every client.
--   client RNAME -> OverrideBuildName(name) on its copy. The name is kept per
--          container and put on copies that replicate in later (out of range,
--          joined later): a pass every PASS_S while names are known.
--   client once in a world, RNAMEQ; the host answers RNAME for each container
--          whose name differs from its item's default (renamed earlier this
--          session or loaded from the save).
-- A container on the wire: class and place (runtime-spawned: its object name
-- differs per machine, as sdc_world / sdc_stations name buildables) plus the
-- first UID of its main containers (BP_JigMultiplayer.MainContainersIDs,
-- replicated and saved; sdc_containers' key) when this machine knows it.
-- Messages:
--   RNOPEN|class|x,y,z|uid            host -> client
--   RNREQ|class|x,y,z|uid|name        client -> host
--   RNAME|class|x,y,z|uid|name        host -> client(s)
--   RNAME|class!x,y,z!uid!name;...    host -> client (the RNAMEQ answer: every
--                                     renamed container in messages of at most
--                                     CHUNK characters)
--   RNAMEQ                            client -> host
-- name: control characters removed, at most NAME_MAX characters, '%', '|'
-- and ';' written %25 / %7C / %3B.
-- Hooks: post only, wrapped in pcall, return nothing; parameters are read
-- inside the callback; no engine object is kept between calls (class, place,
-- UID and name strings only).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = { opens_sent = 0, opens = 0, host_closed = 0, req_sent = 0, req_applied = 0, req_refused = 0,
              names_sent = 0, names_applied = 0, late_applied = 0, snapshots = 0 },
}

local CONT = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local BASE_CLS = "BuildableMaster_Container_C"
local OPTION_RENAME = "Jig.InteractOptions.Option2"

local NAME_MAX = 100        -- characters of a name on the wire (the game's window has no limit)
local PLACE_MATCH = 100     -- cm: a container this close to the named place is the one
local REACH = 2000          -- cm: host takes a rename from a player this close to the container
local GRANT_KEEP = 600      -- s: the window the host opened for a player counts this long
local REQ_GAP = 0.5         -- s between two rename requests of one player
local HOOK_RETRY_S = 2
local PASS_S = 3            -- client: names put on copies that appeared
local SNAP_AFTER_S = 3      -- client: in the world this long before asking for the names
local KNOWN_MAX = 1000
local CHUNK = 1500          -- characters of one RNAME list message

local clock = os.clock
local S
local st = {
    role = nil,
    hooks = {},          -- [key] = true once registered
    hook_logged = {},
    hook_at = -100,
    applying = false,    -- this module's own OverrideBuildName is running
    known = {},          -- client: { cls =, loc =, uid =, name = } per container the host named
    pass_at = -100,
    asked = nil,         -- client: world key the names were asked for
    since = nil,         -- client: { key =, t = } in this world since
    grants = {},         -- host: [controller address] = { cls =, loc =, at = }
    last_req = {},       -- host: [controller address] = clock
}

local function on()
    return cfg.get("world_sync") ~= false and cfg.get("world_rename") ~= false
end

local function pget(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function addr(o)
    if not ue.valid(o) then return nil end
    return ctx.addr(o)
end

-- ---------------------------------------------------------------------------
-- Names and places
-- ---------------------------------------------------------------------------

-- Control characters out, at most NAME_MAX characters (cut on a UTF-8
-- character boundary).
local function clean(s)
    s = tostring(s or ""):gsub("%c", "")
    local okl, len = pcall(utf8.len, s)
    if okl and len then
        if len > NAME_MAX then s = s:sub(1, utf8.offset(s, NAME_MAX + 1) - 1) end
    elseif #s > NAME_MAX then
        s = s:sub(1, NAME_MAX)
    end
    return s
end
local function esc(s)
    return (tostring(s or ""):gsub("[%%|;]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unesc(s)
    return (tostring(s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
M.clean, M.esc, M.unesc = clean, esc, unesc

local function loc_str(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function parse_loc(s)
    local x, y, z = tostring(s or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end
local function d2(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function guid_str(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end

-- The first UID of the container's main containers ("" when not known here).
local function uid_of(box)
    local comp = ue.prop(box, "BP_JigMultiplayer")
    if not ue.valid(comp) then return "" end
    local first
    pcall(function()
        ue.prop(comp, "MainContainersIDs"):ForEach(function(_, e)
            if first == nil then first = e:get() end
        end)
    end)
    local s = first ~= nil and ue.try(guid_str, first) or nil
    if not s or s == "0:0:0:0" then return "" end
    return s
end

local isa_cache = {}   -- [class name] = bool
local function is_box(o)
    local cn = ue.class_name(o)
    if cn == "" then return false end
    local c = isa_cache[cn]
    if c ~= nil then return c end
    local cls = ue.find_object(CONT)
    if not cls then return false end   -- not loaded: no container exists
    local ok, r = pcall(function() return o:IsA(cls) end)
    if not ok then return false end
    isa_cache[cn] = r == true
    return r == true
end

local function name_of(box) return ue.str(ue.prop(box, "ContainerName")) end

-- The name the game gives it at BeginPlay (@985: PickupDataAsset.name).
local function default_name(box)
    local da = ue.prop(box, "PickupDataAsset")
    if not ue.valid(da) then return nil end
    return ue.str(ue.prop(da, "name"))
end

-- class, "x,y,z", uid of a container (nil when it has no place)
local function wire_of(box)
    local l = ue.location(box)
    local cls = ue.class_name(box)
    if not l or cls == "" then return nil end
    return cls, loc_str(l), uid_of(box)
end

-- The containers of a class here: { o =, l = place, u = UID (read when
-- needed) }. `list`: a FindAllOf result to use.
local function candidates(cls, list)
    local out = {}
    if type(cls) ~= "string" or cls == "" then return out end
    for _, o in ipairs(list or ue.find_all(cls)) do
        if ue.valid(o) and ue.class_name(o) == cls and is_box(o) then out[#out + 1] = { o = o, l = ue.location(o) } end
    end
    return out
end
local function cand_uid(c)
    if c.u == nil then c.u = uid_of(c.o) end
    return c.u
end

-- The container this machine has for a wire name: at the place (within
-- PLACE_MATCH) the one with that UID, else the nearest one whose UID does not
-- say it is another container (picked up and placed again); nothing at the
-- place: the one with that UID elsewhere (moved).
local function find_box(cls, loc, uid, cands)
    if not loc then return nil end
    cands = cands or candidates(cls)
    local best, bestd = nil, PLACE_MATCH * PLACE_MATCH
    for _, c in ipairs(cands) do
        local d = d2(c.l, loc)
        if d <= PLACE_MATCH * PLACE_MATCH then
            local u = uid ~= "" and cand_uid(c) or ""
            if u ~= "" and u == uid then return c.o end
            if u == "" and d <= bestd then best, bestd = c.o, d end
        end
    end
    if best or uid == "" then return best end
    for _, c in ipairs(cands) do
        if cand_uid(c) == uid then return c.o end
    end
    return nil
end

-- The game's own rename on this machine's copy (OverrideBuildName:
-- ContainerName = Name); the property itself only when the call fails.
local function apply_name(box, name)
    st.applying = true
    local ok, err = pcall(function() box:OverrideBuildName(FText(name)) end)
    st.applying = false
    if ok and name_of(box) == name then return true end
    local okp = ue.set_prop(box, "ContainerName", FText(name))
    log.warn("rename: OverrideBuildName on %s %s; ContainerName set directly: %s", ue.short(box),
        ok and "left another name" or ("failed (" .. tostring(err) .. ")"), okp and "ok" or "FAILED")
    return okp
end

local function hud_here()
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    if ue.valid(hud) then return hud end
    return nil
end

-- The rename window open on this screen, if any.
local function open_window(hud)
    local w = ue.prop(hud, "ChangeNameWidget")
    if ue.valid(w) and ue.try(function() return w:IsInViewport() end) == true then return w end
    return nil
end

local function remote_pc_of(pawn)
    if not ue.valid(pawn) then return nil end
    local pc = ue.prop(pawn, "Controller")
    if ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection")) then return pc end
    return nil
end

local function who_of(pc)
    local p = ue.pawn_of(pc)
    return p and ue.short(p) or ue.short(pc)
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function broadcast(box, why)
    local cls, loc, uid = wire_of(box)
    if not cls then return end
    local name = clean(name_of(box))
    local pcs = S.remote_pcs or {}
    if #pcs > 0 then net.broadcast(pcs, "RNAME", cls, loc, uid, esc(name)) end
    M.stats.names_sent = M.stats.names_sent + #pcs
    log.info("rename: host: %s (%s at %s) is now '%s' (%s): RNAME to %d client(s)", ue.short(box), cls, loc, name,
        why, #pcs)
end

-- BuildableMaster_Container.OnServerExecuteInteract(Option, ByActor, Payload),
-- post, host: a remote player chose Rename; the game's window goes to it.
local function on_server_interact(c, opt_p, by_p)
    if not S or S.role ~= "host" or not on() then return end
    local tag = ue.try(function() return ue.str(opt_p:get().TagName) end)
    if tag ~= OPTION_RENAME then return end
    local by = pget(by_p)
    local pc = remote_pc_of(by)
    if not pc then return end   -- the host's own: the game opened the window on this screen
    local box = pget(c)
    if not ue.valid(box) then return end
    local cls, loc, uid = wire_of(box)
    if not cls then return end
    -- the game's GetHUD gave this screen's HUD (no scope for it): not the host's window
    local hud = hud_here()
    local w = hud and open_window(hud)
    if w and addr(ue.prop(w, "ActorRef")) == addr(box) then
        pcall(function() hud:ShowChangeObjectNameWidget(false, nil) end)
        M.stats.host_closed = M.stats.host_closed + 1
        log.info("rename: host: the game opened the rename window of %s on the host's screen for %s: closed here",
            ue.short(box), ue.short(by))
    end
    st.grants[addr(pc) or -1] = { cls = cls, loc = parse_loc(loc), at = clock() }
    net.send_to(pc, "RNOPEN", cls, loc, uid)
    M.stats.opens_sent = M.stats.opens_sent + 1
    log.info("rename: host: %s chose Rename on %s (%s at %s, '%s'): the game's window opens on that player's screen (RNOPEN)",
        ue.short(by), ue.short(box), cls, loc, name_of(box))
end

-- RNREQ|class|x,y,z|uid|name (client -> host): that player renamed its copy.
local function req_msg(f, pc)
    if not S or S.role ~= "host" then return end
    local who = who_of(pc)
    if not on() then
        log.info("rename: host: rename from %s ignored (world_rename or world_sync off)", who)
        return
    end
    local cls, loc, uid, name = f[1], parse_loc(f[2]), f[3] or "", clean(unesc(f[4]))
    if type(cls) ~= "string" or cls == "" or not loc then return end
    local k = addr(pc) or -1
    local now = clock()
    if now - (st.last_req[k] or -100) < REQ_GAP then
        log.info("rename: host: rename from %s too soon after the last one: ignored", who)
        return
    end
    st.last_req[k] = now
    local box = find_box(cls, loc, uid)
    if not box then
        log.warn("rename: host: %s renamed %s at %s to '%s', but the host has no such container: nothing renamed",
            who, cls, f[2], name)
        return
    end
    local g = st.grants[k]
    local granted = g ~= nil and now - g.at <= GRANT_KEEP and g.cls == cls
        and d2(g.loc, ue.location(box)) <= PLACE_MATCH * PLACE_MATCH
    local near = d2(ue.location(ue.pawn_of(pc)), ue.location(box)) <= REACH * REACH
    if name == "" or not (granted or near) then
        M.stats.req_refused = M.stats.req_refused + 1
        local bc, bl, bu = wire_of(box)
        local cur = clean(name_of(box))
        if bc then net.send_to(pc, "RNAME", bc, bl, bu, esc(cur)) end
        log.warn("rename: host: %s's rename of %s to '%s' refused (%s): it keeps '%s'", who, ue.short(box), name,
            name == "" and "empty name" or "not near it and no window opened for it", cur)
        return
    end
    st.grants[k] = nil
    apply_name(box, name)
    M.stats.req_applied = M.stats.req_applied + 1
    broadcast(box, "renamed by " .. who .. " - the host's copy, saved with the world")
end

-- RNAMEQ (client -> host): the names of every renamed container, as lists
-- (RNAME|class!x,y,z!uid!name;...) of at most CHUNK characters.
local function snap_msg(_, pc)
    if not S or S.role ~= "host" or not on() then return end
    local items, total = {}, 0
    for _, box in ipairs(ue.find_all(BASE_CLS)) do
        if ue.valid(box) and is_box(box) then
            total = total + 1
            local name, def = clean(name_of(box)), default_name(box)
            if name ~= "" and def ~= nil and name ~= clean(def) then
                local cls, loc, uid = wire_of(box)
                if cls then items[#items + 1] = table.concat({ cls, loc, uid, esc(name) }, "!") end
            end
        end
    end
    local msgs, buf, len = 0, {}, 0
    local function flush()
        if #buf == 0 then return end
        if net.send_to(pc, "RNAME", table.concat(buf, ";")) then msgs = msgs + 1 end
        buf, len = {}, 0
    end
    for _, it in ipairs(items) do
        if len + #it + 1 > CHUNK then flush() end
        buf[#buf + 1] = it
        len = len + #it + 1
    end
    flush()
    M.stats.snapshots = M.stats.snapshots + 1
    M.stats.names_sent = M.stats.names_sent + #items
    log.info("rename: host: %s asked for the containers' names: %d of %d container(s) renamed, sent (RNAME, %d message(s))",
        who_of(pc), #items, total, msgs)
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- The host's name for a container, kept for copies that appear later.
local function remember(cls, loc, uid, name)
    for _, e in ipairs(st.known) do
        if e.cls == cls and ((uid ~= "" and e.uid == uid) or d2(e.loc, loc) <= PLACE_MATCH * PLACE_MATCH) then
            e.loc, e.name = loc, name
            if uid ~= "" then e.uid = uid end
            return e
        end
    end
    if #st.known >= KNOWN_MAX then table.remove(st.known, 1) end
    local e = { cls = cls, loc = loc, uid = uid, name = name }
    st.known[#st.known + 1] = e
    return e
end

-- RNOPEN|class|x,y,z|uid (host -> client): the game's rename window here.
local function open_msg(f)
    if not S or S.role ~= "client" or not on() then return end
    local cls, loc, uid = f[1], parse_loc(f[2]), f[3] or ""
    if type(cls) ~= "string" or cls == "" or not loc then return end
    local box = find_box(cls, loc, uid)
    if not box then
        log.warn("rename: the host opened Rename of %s at %s, but this machine has no such container: no window", cls, f[2])
        return
    end
    local hud = hud_here()
    if not hud then
        log.warn("rename: no game HUD here: the rename window of %s not opened", ue.short(box))
        return
    end
    if open_window(hud) then
        log.info("rename: a rename window is already open here: %s not opened again", ue.short(box))
        return
    end
    local ok, err = pcall(function() hud:ShowChangeObjectNameWidget(true, box) end)
    if ok then M.stats.opens = M.stats.opens + 1 end
    log.info("rename: the game's rename window for %s ('%s') opened here (Rename, run on the host)%s", ue.short(box),
        name_of(box), ok and "" or (" - FAILED: " .. tostring(err)))
end

-- The host's name for one container (`at`: its place as sent, for the log).
local function name_one(cls, at, uid, name)
    local loc = parse_loc(at)
    if type(cls) ~= "string" or cls == "" or not loc or name == "" then return end
    remember(cls, loc, uid, name)
    local box = find_box(cls, loc, uid, candidates(cls, ue.find_all_recent(cls, 1)))
    if not box then
        log.debug("rename: '%s' (%s at %s) kept for when that container is here", name, cls, at)
        return
    end
    if name_of(box) == name then
        log.debug("rename: %s is already called '%s' here", ue.short(box), name)
        return
    end
    apply_name(box, name)
    M.stats.names_applied = M.stats.names_applied + 1
    log.info("rename: %s is called '%s' here, as on the host", ue.short(box), name)
end

-- RNAME|class|x,y,z|uid|name or RNAME|class!x,y,z!uid!name;... (host ->
-- client): the host's names.
local function name_msg(f)
    if not S or S.role ~= "client" or not on() then return end
    if f[2] ~= nil then return name_one(f[1], f[2], f[3] or "", clean(unesc(f[4]))) end
    for e in tostring(f[1] or ""):gmatch("[^;]+") do
        local cls, at, uid, name = e:match("^([^!]+)!([^!]+)!([^!]*)!(.*)$")
        if cls then name_one(cls, at, uid, clean(unesc(name))) end
    end
end

-- Every PASS_S while names are known: copies that appeared get theirs.
local function client_pass(now)
    if #st.known == 0 or now - st.pass_at < PASS_S then return end
    st.pass_at = now
    local by_cls = {}   -- [class] = candidates (one search, places and UIDs read once per pass)
    for _, e in ipairs(st.known) do
        local cands = by_cls[e.cls]
        if not cands then
            cands = candidates(e.cls, ue.find_all_recent(e.cls, PASS_S))
            by_cls[e.cls] = cands
        end
        local box = find_box(e.cls, e.loc, e.uid, cands)
        if box and name_of(box) ~= e.name then
            apply_name(box, e.name)
            M.stats.late_applied = M.stats.late_applied + 1
            log.info("rename: %s appeared here: it gets its name '%s' from the host", ue.short(box), e.name)
        end
    end
end

local function client_ask(now)
    local cs = S.client
    if not (cs and cs.acked == true) or not ue.local_pawn() then return end
    local key = tostring(S.map) .. "|" .. tostring(cs.pc_key)
    if st.asked == key then return end
    if not st.since or st.since.key ~= key then
        st.since = { key = key, t = now }
        return
    end
    if now - st.since.t < SNAP_AFTER_S then return end
    if net.send_to_host("RNAMEQ") then
        st.asked = key
        log.info("rename: asked the host for the names of renamed containers (RNAMEQ)")
    end
end

-- ---------------------------------------------------------------------------
-- Both: OverrideBuildName (post) - a rename on this machine
-- ---------------------------------------------------------------------------

-- BuildableMaster_Container.OverrideBuildName(Name), post. Its only caller is
-- the rename window's Confirm; this module's own calls are skipped.
local function on_override(c)
    if not S or st.applying or not on() then return end
    local box = pget(c)
    if not ue.valid(box) then return end
    if S.role == "client" then
        local cls, loc, uid = wire_of(box)
        if not cls then return end
        local name = clean(name_of(box))
        if name == "" then return end
        remember(cls, parse_loc(loc), uid, name)
        net.send_to_host("RNREQ", cls, loc, uid, esc(name))
        M.stats.req_sent = M.stats.req_sent + 1
        log.info("rename: %s (%s at %s) renamed here to '%s': the host renames its copy (RNREQ)", ue.short(box), cls,
            loc, name)
    elseif S.role == "host" then
        if #(S.remote_pcs or {}) == 0 then return end
        broadcast(box, "the host's rename")
    end
end

-- ---------------------------------------------------------------------------
-- Hooks, tick, install
-- ---------------------------------------------------------------------------

local HOOKS = {
    { key = "override", fn = "OverrideBuildName", cb = on_override },
    { key = "server", fn = "OnServerExecuteInteract", cb = on_server_interact, host = true },
}

-- The container class exists once a container (or its item) is loaded: tried
-- again every HOOK_RETRY_S until each hook is in.
local function try_hooks(now, role)
    if now - st.hook_at < HOOK_RETRY_S then return end
    st.hook_at = now
    if not ue.find_object(CONT) then return end
    for _, h in ipairs(HOOKS) do
        if not st.hooks[h.key] and (role == "host" or not h.host) then
            local cb = h.cb
            local ok, err = pcall(RegisterHook, CONT .. ":" .. h.fn, function(...)
                local okc, e = pcall(cb, ...)
                if not okc then log.err_throttled("rename." .. h.key, "rename: %s hook: %s", h.fn, tostring(e)) end
            end)
            if ok then
                st.hooks[h.key] = true
                log.info("rename: hook BuildableMaster_Container_C:%s ok", h.fn)
            elseif not st.hook_logged[h.key] then
                st.hook_logged[h.key] = true
                log.warn("rename: cannot hook BuildableMaster_Container_C:%s yet (%s); retried", h.fn, tostring(err))
            end
        end
    end
end

local function tick()
    if not S then return end
    local role = S.role
    if role ~= st.role then
        if st.role ~= nil then M.reset("role " .. tostring(st.role) .. " -> " .. tostring(role)) end
        st.role = role
    end
    if not on() then return end
    local now = clock()
    if role == "host" then
        if #(S.remote_pcs or {}) == 0 then return end
        try_hooks(now, role)
        for k, g in pairs(st.grants) do if now - g.at > GRANT_KEEP then st.grants[k] = nil end end
        for k, t in pairs(st.last_req) do if now - t > 60 then st.last_req[k] = nil end end
    elseif role == "client" then
        try_hooks(now, role)
        client_ask(now)
        client_pass(now)
    end
end

-- main.lua, every 500 ms (any role).
function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("rename.tick", "rename: tick: %s", tostring(err)) end
end

-- World change / role change: every kept name belonged to the old world.
function M.reset(why)
    st.known, st.pass_at = {}, -100
    st.asked, st.since = nil, nil
    st.grants, st.last_req = {}, {}
    st.applying = false
    log.debug("rename: reset (%s)", tostring(why))
end

function M.install(state)
    S = state
    net.on("RNOPEN", open_msg)
    net.on("RNREQ", req_msg)
    net.on("RNAME", name_msg)
    net.on("RNAMEQ", snap_msg)
    log.info("rename: installed (world_rename=%s): a client's Rename of a storage container opens the game's window on its screen (RNOPEN), the host renames its own copy (RNREQ, saved with the world) and every client shows the host's names (RNAME, RNAMEQ on join)",
        tostring(on()))
end

function M.status_line()
    local s = M.stats
    return string.format("rename: on=%s hooks override=%s server=%s | host: windows sent=%d closed here=%d, renames applied=%d refused=%d, names sent=%d, snapshots=%d | client: windows=%d, requests=%d, names applied=%d (later copies %d), known=%d",
        tostring(on()), tostring(st.hooks.override == true), tostring(st.hooks.server == true),
        s.opens_sent, s.host_closed, s.req_applied, s.req_refused, s.names_sent, s.snapshots,
        s.opens, s.req_sent, s.names_applied, s.late_applied, #st.known)
end

return M
