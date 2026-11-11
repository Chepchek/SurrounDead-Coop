-- SDCoop: "player 0" by context (host only).
--
-- SurrounDead's Blueprints ask GameplayStatics for player index 0 all over the
-- place (death, respawn, minimap, weapon stats, skills...). On a listen server
-- index 0 is always the host, so a client's death unpossessed the host, a
-- client's broken leg landed on the host, and so on.
--
-- While remote players are connected the host hooks GetPlayerCharacter /
-- GetPlayerPawn / GetPlayerController / GetPlayerCameraManager. Blueprints
-- pass their own `self` as WorldContextObject, so the hook can tell on whose
-- behalf the code runs: the remote player's character, one of its components,
-- an actor it owns (weapon, item), or its controller. For those the call is
-- made for that player instead of the host.
--
-- How: a PRE-hook changes the PlayerIndex argument from 0 to the index of
-- that player's controller in the world's controller list, and the engine
-- itself returns the controller / pawn / camera manager. Earlier versions
-- replaced the RETURN value from a post-hook; UE4SS once handed a controller
-- to a GetPlayerCameraManager call that way and the game died with "Failed
-- to find function GetCameraRotation in BP_PlayerController_C". An index can
-- never produce an object of the wrong type.
--
-- Known gap: inside the new character's ReceivePossessed (before the engine
-- sets the controller's Pawn) GetPlayerCharacter / GetPlayerPawn give None
-- for that player. The game never asks for them there (no such call seen in
-- any run), the controller is already right.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")

local M = {
    active = false,
    count = 0,
}

local FUNCS = {
    "/Script/Engine.GameplayStatics:GetPlayerCharacter",
    "/Script/Engine.GameplayStatics:GetPlayerPawn",
    "/Script/Engine.GameplayStatics:GetPlayerController",
    "/Script/Engine.GameplayStatics:GetPlayerCameraManager",
}

-- The hooks are registered once (the first time a remote player connects) and
-- stay; M.active gates them. Unregistering / re-registering on every join and
-- leave is avoided on purpose: crash (b) came out of this hook set.
local hooks = {}
local installed = false
local map = {}        -- [address] = { pc =, pawn = }  for remote controllers and their pawns
local cache = {}      -- [address] = entry | false
local index_of = {}   -- [controller address] = its PlayerIndex on this machine
local index_count = nil   -- number of controllers when index_of was built
local refreshing = false
local num_pcs_ok = true
local seen = {}
local post_pending = {}   -- [function name] = true: log the next post call (first redirect)
local post_logged = {}    -- [function name] = true
local post_hooked = false -- the logging post-hooks are registered (debug_probes)

-- ---------------------------------------------------------------------------
-- Hot-path helpers (the hooked functions run ~1000-1500 times a second on a
-- host with a client: HUD bindings, containers, the sky). No closure is made
-- per call: pcall gets a module-level function and its argument.
-- ---------------------------------------------------------------------------
local clock = os.clock
local function p_get(p) return p:get() end
local function p_set(p, v) p:set(v) end
local function o_addr(o) return o:GetAddress() end
local function o_outer(o) return o:GetOuter() end
local function o_owner(o) return o:GetOwner() end
local function o_class(o) return o:GetClass() end
local function m_num_pcs(gps, wc) return gps:GetNumPlayerControllers(wc) end
local function m_get_pc(gps, wc, i) return gps:GetPlayerController(wc, i) end

local function addr(o)
    if o == nil then return nil end
    local ok, a = pcall(o_addr, o)
    if ok and a then return a end
    return ue.name(o)
end

-- Address of a live object, or nil (a null object's wrapper gives 0).
local function fast_addr(o)
    if o == nil then return nil end
    local ok, a = pcall(o_addr, o)
    if ok and type(a) == "number" and a ~= 0 then return a end
    return nil
end

-- [PERF] "ctx:" (sdc_perf.report, sdcoop_bench): where the hooks' time goes.
-- Counters, every player_for cache miss and every redirect timed whole, and
-- the reading of the context object and its address (2 engine calls: the
-- part no Lua change can remove) timed on every 4th call.
local PS = { calls = 0, idx = 0, idle = 0, miss = 0, miss_ms = 0, answered = 0, redirect = 0, redirect_ms = 0,
             quiet = 0, arg_n = 0, arg_ms = 0 }
M.pstats = PS
local arg_tick = 0

-- Class short name through a cache keyed by the class object's address
-- (2 engine calls instead of 4 and a new string). Classes outlive the
-- objects; the cache is dropped on a world / role reset.
local class_names = {}   -- [class address] = "BP_Foo_C"
local function cls_info(o)
    local okc, c = pcall(o_class, o)
    local ca = okc and c ~= nil and fast_addr(c) or nil
    if not ca then return ue.class_name(o), nil end
    local n = class_names[ca]
    if n == nil then
        n = ue.class_name(o)
        class_names[ca] = n
    end
    return n, ca
end
local function cls_name(o)
    return (cls_info(o))
end
-- other modules' resolvers (sdc_world): the same class-name lookup
M.class_name = cls_name

-- Nothing above these in an outer chain acts for a player: the outer walks
-- stop there (an actor's outer is its Level).
local CHAIN_END = { Level = true, World = true, Package = true, GameEngine = true, GameInstance = true,
                    SD_GameInstance_C = true }

local function step_outer(o)
    local ok, n = pcall(o_outer, o)
    if not ok then return nil end
    local a = fast_addr(n)
    if not a then return nil end
    return n, a
end

-- Classes that have no GetOwner (widgets, anim instances, plain objects):
-- calling it there is a Lua error (a few us each, on every cache miss of such
-- an object). Learned from the error itself ("attempt to call": the member
-- does not exist for that class); an error from inside a real GetOwner call
-- is not remembered. Same result as before: no owner, the walk stops.
-- `ca` = the object's class address when the caller has it (the first step
-- of a walk; the owners after it are actors, which all have GetOwner).
local no_owner = {}   -- [class address] = true
local function step_owner(o, ca)
    if ca and no_owner[ca] then return nil end
    local ok, n = pcall(o_owner, o)
    if not ok then
        if ca and type(n) == "string" and n:find("attempt to call", 1, true) then no_owner[ca] = true end
        return nil
    end
    local a = fast_addr(n)
    if not a then return nil end
    return n, a
end

local weapon_cache = {}   -- [address] = true when the object has a BP_WeaponsPickupComponent
local function is_weapon(o, a)
    a = a or addr(o)
    if not a then return false end
    local w = weapon_cache[a]
    if w == nil then
        w = ue.valid(ue.prop(o, "BP_WeaponsPickupComponent"))
        weapon_cache[a] = w
    end
    return w
end
M.addr = addr

local function is_remote_pc(pc)
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

-- Number of controllers in the world (cheap; not one of the hooked functions).
local function controller_count()
    if not num_pcs_ok then return nil end
    local gps = ue.gameplay_statics()
    local wc = ue.local_pc() or ue.game_instance()
    if not gps or not wc then return nil end
    local ok, n = pcall(m_num_pcs, gps, wc)
    if ok and type(n) == "number" then return n end
    num_pcs_ok = false
    log.warn("ctx: GetNumPlayerControllers unavailable (%s); player indices refresh once a second only", tostring(n))
    return nil
end

-- The PlayerIndex of every controller, in the order GameplayStatics counts
-- them (the world's controller list: the host first, then remote players and
-- helper controllers such as the item inspector, in creation order).
local function refresh_indices()
    -- GetPlayerController below runs through this module's own hook
    if refreshing then return end
    refreshing = true
    local ok, err = pcall(function()
        local gps = ue.gameplay_statics()
        local wc = ue.local_pc() or ue.game_instance()
        local t = {}
        if gps and wc then
            for i = 0, 15 do
                local okc, pc = pcall(m_get_pc, gps, wc, i)
                if not okc or not ue.valid(pc) then break end
                local a = addr(pc)
                if a then t[a] = i end
            end
        end
        index_of = t
        index_count = controller_count()
    end)
    refreshing = false
    if not ok then log.err_throttled("ctx-indices", "ctx: cannot read player indices: %s", tostring(err)) end
end

function M.index_of(pc)
    local a = addr(pc)
    return a and index_of[a] or nil
end

-- A character that is not in the map yet (spawned this frame, possessed in the
-- same call stack): ask its controller. `cls` = the object's class name when
-- the caller has it already.
local function entry_from_pawn(o, cls)
    if not (cls or cls_name(o)):find("PlayerCharacter", 1, true) then return nil end
    local pc = ue.prop(o, "Controller")
    if is_remote_pc(pc) then return { pc = pc, pawn = o } end
    return nil
end

-- The walk behind player_for (a cache miss).
local function resolve_player(obj, a)
    local e = map[a]
    local oca = nil   -- obj's class address (its owner step)
    if not e then
        local ocls
        ocls, oca = cls_info(obj)
        e = entry_from_pawn(obj, ocls)
    end
    -- components, anim instances, widgets' outers: walk the outer chain
    -- (stops at the Level / World / package: no player above those)
    local o = obj
    for _ = 1, 4 do
        if e then break end
        local oa
        o, oa = step_outer(o)
        if not o then break end
        e = map[oa]
        if not e then
            local cls = cls_name(o)
            if CHAIN_END[cls] then break end
            e = entry_from_pawn(o, cls)
        end
    end
    -- actors owned by a player (weapons, items, projectiles): the owner chain
    o = obj
    for i = 1, 3 do
        if e then break end
        local oa
        o, oa = step_owner(o, i == 1 and oca or nil)
        if not o then break end
        e = map[oa] or entry_from_pawn(o)
    end
    return e
end

-- Remote player entry for any object that acts on that player's behalf.
-- `a` = the object's address when the caller has it (hook hot path).
-- Cached per address until the next tick (1 s).
function M.player_for(obj, a)
    a = a or fast_addr(obj)
    if not a then return nil end
    local c = cache[a]
    if c ~= nil then return c or nil end
    local t0 = clock()
    local e = resolve_player(obj, a)
    cache[a] = e or false
    PS.miss = PS.miss + 1
    PS.miss_ms = PS.miss_ms + (clock() - t0) * 1000
    return e
end

-- Register a pawn for a remote controller right away (before Possess, so the
-- character's own ReceivePossessed already resolves to its player).
function M.bind(pawn, pc)
    if not ue.valid(pawn) or not ue.valid(pc) then return end
    local e = { pc = pc, pawn = pawn }
    local pa, wa = addr(pc), addr(pawn)
    if pa then map[pa] = e end
    if wa then map[wa] = e end
    cache = {}
    weapon_cache = {}
    if not M.index_of(pc) then refresh_indices() end
end

-- Hook arguments after the context: (WorldContextObject, PlayerIndex). Found
-- by value rather than by position.
local function find_args(...)
    local n = select("#", ...)
    for i = 1, n - 1 do
        local p = select(i, ...)
        local ok, v = pcall(function() return p:get() end)
        if ok and type(v) ~= "number" and ue.valid(v) then
            local q = select(i + 1, ...)
            local okq, idx = pcall(function() return q:get() end)
            if okq and type(idx) == "number" then return v, q, idx end
            return nil
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Client mode: on a client "player 0" is always its own player, and only its
-- own controller / camera manager exist there. Code that runs for ANOTHER
-- player's character on this machine (multicasts, OnReps, anim notifies:
-- MC_ADS camera sway, StopADS cancelling every shake, someone's knife hits
-- shaking this camera and giving this player Strength XP, someone's illness
-- notifications, Sneaking XP from someone's footsteps, the whistle message)
-- then acts on this player. For those the call gets an index with no player
-- behind it: the game's own IsValid / cast branches skip the effect, and its
-- "is this the local player?" checks keep answering no.
-- ---------------------------------------------------------------------------
M.client_mode = false
local NO_PLAYER = 64
local client_cache = {}   -- [address] = true (another player's) / false
local client_seen = {}

-- The player character an object acts for (itself, a component / anim
-- instance in its outer chain, or an actor it owns), or nil. The outer walk
-- stops at the Level / World / package (nothing above acts for a player).
local function character_of(obj)
    local oca = nil   -- obj's class address (its owner step)
    if ue.valid(obj) then
        local ocls
        ocls, oca = cls_info(obj)
        if ocls:find("PlayerCharacter", 1, true) then return obj end
    end
    local o = obj
    for _ = 1, 4 do
        o = step_outer(o)
        if not o then break end
        local cls = cls_name(o)
        if CHAIN_END[cls] then break end
        if cls:find("PlayerCharacter", 1, true) then return o end
    end
    o = obj
    for i = 1, 3 do
        o = step_owner(o, i == 1 and oca or nil)
        if not o then break end
        if cls_name(o):find("PlayerCharacter", 1, true) then return o end
    end
    return nil
end

local function p_set_none(p) p:set(NO_PLAYER) end

-- [function name][address] = true: this object's calls were reported already
-- (the class name is looked up once per object and second, not per call)
local seen_addr = {}
local function first_of(fname, a)
    local t = seen_addr[fname]
    if not t then t = {}; seen_addr[fname] = t end
    if t[a] then return false end
    t[a] = true
    return true
end

local function client_quiet(fname, wco, idx_p, a)
    a = a or fast_addr(wco)
    if not a then return end
    local other = client_cache[a]
    if other == nil then
        local ch = character_of(wco)
        other = false
        if ch then
            local ok, loc = pcall(function() return ch:IsLocallyControlled() end)
            other = ok and loc ~= true
        end
        client_cache[a] = other
    end
    if not other then return end
    if not pcall(p_set_none, idx_p) then return end
    M.count = M.count + 1
    if first_of(fname, a) then
        local cls = cls_name(wco)
        local k = fname .. "|" .. cls
        if not client_seen[k] then
            client_seen[k] = true
            log.info("ctx: client: %s(0) from %s of another player -> no player (effect skipped)", fname, cls)
        end
    end
end

-- Debug (sdc_gaptrace): observer(fname, world_context, "remote" | nil) is
-- called for every player-0 call while the hooks are active.
M.observer = nil

-- sdc_respawn: a game function running for one player (the respawn RPCs, a
-- bed) names that player for the objects it asks player 0 from: a remote
-- controller, false (the host's own action: player 0 stays) or nil.
M.SCOPE_API = 1
M.scope_resolver = nil

-- Idle checks (hot-path shortcut). A resolver (or M.stand_in) may register
-- fn(address) -> true when, right now and for that object, it would answer
-- nil WITHOUT any side effect; a chained resolver's check includes the one
-- behind it (M.resolver_idle(prev, a)). A resolver without a check counts as
-- busy, so the shortcut only works once every resolver in the chain has one.
-- When the whole chain, stand_in and the per-second cache all say "nothing
-- to do", the hook returns before even reading PlayerIndex (one engine call
-- of three; most calls on a host: its HUD, character, the sky).
local idle_of = setmetatable({}, { __mode = "k" })
function M.set_idle_check(fn, check)
    if type(fn) == "function" then idle_of[fn] = check end
end
-- true when `fn` (a resolver or stand_in; nil = none) would do nothing for `a`
function M.resolver_idle(fn, a)
    if fn == nil then return true end
    local check = idle_of[fn]
    if not check then return false end
    return check(a) == true
end
local function chain_idle(a)
    return M.resolver_idle(M.scope_resolver, a) and M.resolver_idle(M.stand_in, a)
end

local function controller_of(obj)
    local o = obj
    for _ = 1, 4 do
        if not ue.valid(o) then return nil end
        if ue.class_name(o):find("PlayerController", 1, true) then return o end
        local nxt = ue.try(function() return o:GetOuter() end)
        if not ue.valid(nxt) or ue.class_name(nxt):find("World", 1, true) or ue.class_name(nxt):find("Level", 1, true) then
            nxt = ue.try(function() return o:GetOwner() end)
        end
        o = nxt
    end
    return nil
end

-- A widget (or a widget inside one) belongs to its owning player.
local function widget_owner(obj)
    local o = obj
    for _ = 1, 4 do
        if not ue.valid(o) then return nil end
        local pc = ue.try(function() return o:GetOwningPlayer() end)
        if ue.valid(pc) then return pc end
        o = ue.try(function() return o:GetOuter() end)
    end
    return nil
end

-- Who an object acts for, read only:
--   host:   "remote" (a remote player's), "local" (the host player's), "world"
--   client: "own" (this player's), "other" (another player's), "world"
function M.classify(obj, role)
    if not ue.valid(obj) then return "none" end
    if role == "host" then
        if M.player_for(obj) then return "remote" end
        local ch = character_of(obj)
        if ch then
            local pc = ue.prop(ch, "Controller")
            if is_remote_pc(pc) then return "remote" end
            return "local"
        end
        local pc = controller_of(obj) or widget_owner(obj)
        if pc then return is_remote_pc(pc) and "remote" or "local" end
        return "world"
    end
    local ch = character_of(obj)
    if ch then
        local ok, loc = pcall(function() return ch:IsLocallyControlled() end)
        return (ok and loc == true) and "own" or "other"
    end
    local pc = controller_of(obj) or widget_owner(obj)
    if pc then
        local ok, loc = pcall(function() return pc:IsLocalController() end)
        return (ok and loc == true) and "own" or "other"
    end
    return "world"
end

local function make_hook(path)
    local fname = path:match(":([%w_]+)$")
    -- every path returns nothing: a value returned from a hook would replace
    -- the function's result. The body never throws either: UE4SS keeps a
    -- callback's results on the hook's Lua stack until the post-hook, and an
    -- error there leaves the stack unbalanced (its leftovers can end up
    -- written into a later call's return value).
    local is_gpc = fname == "GetPlayerController"
    -- The call is for a remote player: its PlayerIndex.
    local function redirect(wco, idx_p, a, pc)
        -- a controller that left shifts the indices of the ones after it
        local cnt = controller_count()
        if cnt and cnt ~= index_count then refresh_indices() end
        local n = M.index_of(pc)
        if not n or n == 0 then return end
        if not pcall(p_set, idx_p, n) then return end
        M.count = M.count + 1
        PS.redirect = PS.redirect + 1
        if post_hooked and not post_logged[fname] then post_pending[fname] = true end
        if first_of(fname, a) then
            local who = cls_name(wco)
            local k = fname .. "|" .. who
            if not seen[k] then
                seen[k] = true
                log.info("ctx: %s(0) from %s of a remote player -> index %d (%s)", fname, who, n, ue.short(pc))
            end
        end
    end
    -- One call with its context object read (always inside a pcall).
    local function decide(wco, idx_p, a)
        if M.client_mode then
            client_quiet(fname, wco, idx_p, a)
            if M.observer then pcall(M.observer, fname, wco, nil) end
            return
        end
        local e = nil
        local sr = M.scope_resolver
        if sr then
            -- resolvers take (object, its address); older ones ignore the 2nd
            local spc = sr(wco, a)
            if spc ~= nil then PS.answered = PS.answered + 1 end
            if spc == false then return end
            if spc ~= nil and is_remote_pc(spc) then e = { pc = spc } end
        end
        if not e then
            -- the per-second cache first (player_for checks it too)
            local c = cache[a]
            if c == nil then e = M.player_for(wco, a) elseif c then e = c end
        end
        if M.observer then pcall(M.observer, fname, wco, e and "remote" or nil) end
        -- not a remote player's own object: sdc_ai may name the player on
        -- whose behalf a dying zombie / bandit runs (its killer)
        if not e and M.stand_in then
            local ok, pc = pcall(M.stand_in, wco)
            if ok and pc ~= nil and is_remote_pc(pc) then e = { pc = pc } end
        end
        if not e or not ue.valid(e.pc) then return end
        -- A remote player's weapon asks for "its" controller only for effects the
        -- owner runs itself (MC_WeaponEffects@2450, melee HitBody@882 / HitHead@969 /
        -- HitFoliage*@36 / HitTrashObject@130: CameraShake -> CameraShakeClient RPC,
        -- so the shooter shook twice) or for BeginPlay's GetPassiveSkillsComponent,
        -- which sdc_damage sets itself (fix_weapon_skills, also on the first FindStat).
        if is_gpc and cfg.get("host_weapon_fx_quiet") ~= false
            and cfg.get("fix_client_damage") ~= false and is_weapon(wco, a) then
            if pcall(p_set_none, idx_p) then
                M.count = M.count + 1
                PS.quiet = PS.quiet + 1
                if first_of("quiet", a) then
                    local cls = cls_name(wco)
                    local k = "quiet|" .. cls
                    if not seen[k] then
                        seen[k] = true
                        log.info("ctx: GetPlayerController(0) from %s of a remote player -> no player (owner runs its weapon effects)", cls)
                    end
                end
            end
            return
        end
        local t0 = clock()
        redirect(wco, idx_p, a, e.pc)
        PS.redirect_ms = PS.redirect_ms + (clock() - t0) * 1000
    end
    -- An unexpected parameter layout: the arguments searched by value.
    local function by_value(...)
        local wco, ip, i = find_args(...)
        if not wco or i ~= 0 then return end
        local a = fast_addr(wco)
        if not a then return end
        decide(wco, ip, a)
    end
    -- (WorldContextObject, PlayerIndex) by position, checked on the first
    -- call (UE4SS passes a function's parameters the same way every time);
    -- an unexpected layout keeps the search by value for good.
    local layout = nil
    -- The callback. Outside any pcall only table reads and pcall'd engine
    -- calls (nothing here can throw). The context object and its address
    -- first; an object nothing can act on right now (no remote player's per
    -- the cache, every resolver and stand_in idle, no debug observer) ends
    -- here without reading PlayerIndex. Otherwise the index (a number, no
    -- object wrapper), and decide() as before.
    return function(_, wco_p, idx_p, ...)
        if not M.active then return end
        PS.calls = PS.calls + 1
        arg_tick = arg_tick + 1
        local t0 = (arg_tick & 3) == 0 and clock() or nil
        local wco, a = nil, nil
        if layout then
            local okw, w = pcall(p_get, wco_p)
            if okw and w ~= nil then
                wco = w
                local oka, x = pcall(o_addr, w)
                if oka and type(x) == "number" and x ~= 0 then a = x end
            end
            if a then
                if t0 then PS.arg_n, PS.arg_ms = PS.arg_n + 1, PS.arg_ms + (clock() - t0) * 1000 end
                if M.observer == nil then
                    if M.client_mode then
                        -- client: an object already known as not another player's
                        if client_cache[a] == false then return end
                    elseif cache[a] == false then
                        local oki, idle = pcall(chain_idle, a)
                        if oki and idle then
                            PS.idle = PS.idle + 1
                            return
                        end
                    end
                end
            end
        end
        local okq, idx = pcall(p_get, idx_p)
        if not okq or type(idx) ~= "number" then
            layout = false
            local ok, err = pcall(by_value, wco_p, idx_p, ...)
            if not ok then log.err_throttled("ctx-pre", "ctx: %s pre-hook: %s", fname, tostring(err)) end
            return
        end
        if layout == nil then layout = true end
        if idx ~= 0 then
            PS.idx = PS.idx + 1
            return
        end
        if wco == nil then
            local okw, w = pcall(p_get, wco_p)
            if not okw or w == nil then return end
            wco = w
            local oka, x = pcall(o_addr, w)
            if oka and type(x) == "number" and x ~= 0 then a = x end
        end
        if not a then return end
        -- client: an object already known as not another player's
        if M.client_mode and client_cache[a] == false and not M.observer then return end
        local ok, err = pcall(decide, wco, idx_p, a)
        if not ok then log.err_throttled("ctx-pre", "ctx: %s pre-hook: %s", fname, tostring(err)) end
    end
end

-- Class of a hook argument (read only), for the log.
local function describe(p)
    local ok, v = pcall(function() return p:get() end)
    if not ok then return "?" end
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if ue.valid(v) then return ue.class_name(v) end
    return "None"
end

-- Post hook: once per function, after its first redirected call, log what
-- the engine returned (expected: a controller / character / camera manager of
-- the remote player). Reads only; returns nothing.
local function make_post(path)
    local fname = path:match(":([%w_]+)$")
    local function body(...)
        post_pending[fname] = nil
        post_logged[fname] = true
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = describe((select(i, ...)))
        end
        log.info("ctx: first redirected %s returned %s (post args: %s)", fname, parts[1] or "?",
            table.concat(parts, ", "))
    end
    return function(_, ...)
        if not post_pending[fname] then return end
        local ok, err = pcall(body, ...)
        if not ok then log.err_throttled("ctx-post", "ctx: %s post-hook: %s", fname, tostring(err)) end
    end
end

-- The post-hook only logs what the first redirected call returned. Every
-- registered callback makes UE4SS wrap all parameters again on every call
-- (~1000+ calls a second here), so it is registered only with debug_probes.
local function install()
    if installed then return end
    installed = true
    post_hooked = log.probes_enabled == true
    for _, path in ipairs(FUNCS) do
        local ok, pre, post = pcall(RegisterHook, path, make_hook(path), post_hooked and make_post(path) or nil)
        if ok then
            hooks[#hooks + 1] = { path = path, pre = pre, post = post }
        else
            log.err("ctx: cannot hook %s: %s", path, tostring(pre))
        end
    end
    log.info("ctx: player-0 hooks installed (%d, %s); active only while remote players are connected", #hooks,
        post_hooked and "with the first-redirect post-hooks (debug_probes)" or "pre-hooks only")
end

-- Host tick (1 s): rebuild the map from the live controllers; the hooks act
-- only while remote players are connected.
function M.tick(remote_pcs)
    if not cfg.get("redirect_player0") then remote_pcs = {} end
    local m = {}
    for _, pc in ipairs(remote_pcs) do
        local pawn = ue.pawn_of(pc)
        local e = { pc = pc, pawn = pawn }
        local pa = addr(pc)
        if pa then m[pa] = e end
        if pawn then
            local wa = addr(pawn)
            if wa then m[wa] = e end
        end
    end
    -- keep pawns bound this second that the controller does not report yet
    for a, e in pairs(map) do
        if not m[a] and ue.valid(e.pawn) and ue.valid(e.pc) and is_remote_pc(e.pc) then m[a] = e end
    end
    map = m
    cache = {}
    weapon_cache = {}
    seen_addr = {}
    local want = next(map) ~= nil
    if want then refresh_indices() else index_of, index_count = {}, nil end
    if want and not installed then install() end
    if want ~= M.active then
        if want then
            log.info("ctx: player-0 redirection on")
        else
            log.info("ctx: player-0 redirection off (%d calls redirected)", M.count)
        end
    end
    M.active = want
end

-- Role change / level change: every cached controller and pawn is dropped
-- without touching it; the hooks stay registered but inactive.
function M.reset()
    if M.active then log.info("ctx: player-0 redirection off (%d calls redirected)", M.count) end
    map, cache, index_of, index_count = {}, {}, {}, nil
    weapon_cache = {}
    post_pending = {}
    client_cache = {}
    seen_addr = {}
    class_names = {}
    no_owner = {}
    M.client_mode = false
    M.active = false
end

-- Client tick (1 s): client mode on / off.
function M.tick_client(on)
    client_cache = {}
    seen_addr = {}
    if on and not installed then install() end
    if on ~= M.client_mode then
        log.info("ctx: client mode %s (other players' player-0 effects %s)", on and "on" or "off",
            on and "skipped" or "as in the game")
    end
    M.client_mode = on
    M.active = on
end

-- sdcoop_bench floor (sdc_bench): the player-0 hooks registered without a
-- remote player (they stay registered, inactive, as after any co-op game).
function M.install_hooks()
    install()
    return #hooks
end

-- [PERF] "ctx:" for the window since the last call (sdc_perf.report), or nil
-- when the hooks did nothing. `dt` = the window in seconds.
local pwin = {}
function M.perf_text(dt)
    local d = {}
    for k, v in pairs(PS) do
        d[k] = v - (pwin[k] or 0)
        pwin[k] = v
    end
    dt = math.max(0.001, tonumber(dt) or 1)
    if d.calls <= 0 and d.miss <= 0 then return nil end
    return string.format("%.0f calls/s (idle shortcut %.0f/s, index not 0 %.0f/s), player_for misses %.1f/s"
        .. " %.1fms/s, resolver answers %.1f/s, redirected %.1f/s %.1fms/s, weapon quiet %.1f/s, context read"
        .. " ~%s us/call", d.calls / dt, d.idle / dt, d.idx / dt, d.miss / dt, d.miss_ms / dt, d.answered / dt,
        d.redirect / dt, d.redirect_ms / dt, d.quiet / dt,
        d.arg_n > 0 and string.format("%.1f", d.arg_ms * 1000 / d.arg_n) or "?")
end

return M
