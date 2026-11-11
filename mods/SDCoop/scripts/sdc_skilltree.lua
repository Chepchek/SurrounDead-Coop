-- SDCoop: the skill tree (TechTreeComponent) in co-op.
--
-- How the game does it (decompiled, work\re):
--   * The tree is the "TechTree" plugin: BP_PlayerController.TechTreeComponent
--     is a C++ TechTreeManager. Its state (which Skill_* assets are unlocked)
--     lives in the C++ object, is NOT replicated and is not in the EMS save:
--     the game writes it to <slot>_SkillTree.sav itself (BP_PlayerController
--     @1958 SaveTechStateFromSlot) and reads it back in BP_PlayerCharacter.
--     Event_LoadPlayer (@14062 AssignTechTree, @14279 LoadTechStateFromSlot),
--     1.2 s after SD_GameInstance.Survival_SpawnPlayer's load branch. Only the
--     points (SkillPoints, CurrentPoints) are EMS component data.
--   * Unlocking is local: the journal's skill UI calls TechTreeComponent.
--     TryToUnlockTechnology on the machine it is shown on (pays SkillPoints,
--     then TechTreeManager.UnlockTechnology). No RPC.
--   * The skills act through IsTechnologyUnlocked(<Skill_X>) on the
--     controller of "player 0": BP_PlayerCharacter (Parkour climb/vault,
--     CombatRoll, Distraction, HealthRegen @78304/@84460, Deathbringer
--     @1243), GameFunctionLibrary.GetSkillTreeManager (CriticalHitter in
--     BP_FirearmPickup / BP_MeleePickup, NightCreature in BP_MeleePickup,
--     Huntsman in the animals' Death). On the host sdc_ctx sends those for a
--     client's character / weapon to the host's copy of the client's
--     controller, whose tree is never assigned or loaded: everything the
--     host evaluates (health regen, Deathbringer's second chance, critical
--     hits, night melee bonus) was "not unlocked" for clients, whatever they
--     unlocked. Climbing, the combat roll and the whistle run on the client
--     and used the client's own tree.
--
-- Here:
--   * client: its own tree is the truth. It sends the unlocked skills to the
--     host (SKTREE|name,name,... or SKTREE|-) on every change and every 20 s.
--     With fresh_client_progress (sdc_progress) the client starts with an
--     empty tree: the game's LoadTechStateFromSlot on a client is pointed at
--     a slot that does not exist (native pre-hook), and M.relock locks
--     whatever is still unlocked when sdc_progress resets the character.
--     A character the host saved for this player (sdc_persist) gets its
--     skills back after that reset: M.unlock (UnlockTechnology, the game's
--     own call), and the host answers from the saved list (M.seed) until the
--     client's first report.
--   * host: a native post-hook on TechTreeManager:IsTechnologyUnlocked
--     answers for the host's copy of a client's controller from that
--     client's list (config skilltree_sync). The C++ tree of that copy is not
--     touched (AssignTechTree needs the journal widget the host does not have
--     for a client).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = { stats = { sent = 0, received = 0, answers = 0, relocked = 0, loads_blocked = 0 } }

local SKILL_DIR = "/Game/Blueprints/SkillTree/Skills/"
local SKILLS = { "Skill_CombatRoll", "Skill_CriticalHitter", "Skill_Deathbringer", "Skill_DemolitionExpert",
    "Skill_Distraction", "Skill_HarvestMaster", "Skill_HealthRegen", "Skill_Huntsman", "Skill_Lockpick",
    "Skill_NightCreature", "Skill_Parkour" }
local IS_UNLOCKED_FN = "/Script/TechTree.TechTreeManager:IsTechnologyUnlocked"
local LOAD_STATE_FN = "/Script/TechTree.TechTreeManager:LoadTechStateFromSlot"
local NO_SLOT = "SDCoop_NoSkillTree"
local POLL_S = 2
local RESEND_S = 20

local S
local paths = {}            -- [skill name] = object path
for _, n in ipairs(SKILLS) do paths[n] = SKILL_DIR .. n .. "." .. n end
local names = { table.unpack(SKILLS) }
local discovered = false

local client = { conn = nil, last = nil, last_t = 0, poll_t = 0, dirty = false }
local trees = {}            -- host: [controller name] = { set = {}, list = "", name =, logged = {} }
local by_comp = {}          -- host: [TechTreeComponent address] = trees entry
local name_of = {}          -- host: [asset address] = "Skill_X"
local hooks = { unlocked = false, load = false }
local active = false

local function sync_enabled() return cfg.get("skilltree_sync") ~= false end
local function fresh_enabled() return cfg.get("fresh_client_progress") ~= false end

-- Skill assets this build has: the known list plus any other loaded
-- BP_SkillTreeAsset_C (looked up once; objects are found again by path).
local function discover()
    if discovered then return end
    discovered = true
    local extra = {}
    for _, a in ipairs(ue.find_all("BP_SkillTreeAsset_C")) do
        local n = ue.short(a)
        if ue.valid(a) and not n:find("^Default__") and not paths[n] then
            local p = ue.path(a)
            if p and p:find("^/") then
                paths[n] = p
                names[#names + 1] = n
                extra[#extra + 1] = n
            end
        end
    end
    table.sort(names)
    if #extra > 0 then log.info("skilltree: skills found besides the known ones: %s", table.concat(extra, ", ")) end
end

-- Unlocked skill names of one TechTreeComponent (this machine's view).
local function unlocked(tech)
    local out = {}
    if not ue.valid(tech) then return out end
    discover()
    for _, n in ipairs(names) do
        local o = ue.find_object(paths[n])
        if o then
            local ok, v = pcall(function() return tech:IsTechnologyUnlocked(o) end)
            if ok and v == true then out[#out + 1] = n end
        end
    end
    return out
end
M.unlocked = unlocked

-- Locks every unlocked skill of `tech` through the game's own function
-- (no widget needed, unlike AssignTechTree). Returns the names locked.
function M.relock(tech, why)
    local done, failed = {}, {}
    for _, n in ipairs(unlocked(tech)) do
        local o = ue.find_object(paths[n])
        local ok = o and pcall(function() tech:LockTechnology(o) end)
        if ok then done[#done + 1] = n else failed[#failed + 1] = n end
    end
    if #done > 0 or #failed > 0 then
        M.stats.relocked = M.stats.relocked + #done
        log.info("skilltree: locked %d skill(s) (%s): %s%s", #done, tostring(why), table.concat(done, ", "),
            #failed > 0 and (" | FAILED " .. table.concat(failed, ", ")) or "")
    end
    client.dirty = true
    return done
end

-- Unlocks the named skills on `tech` through the game's own
-- TechTreeManager.UnlockTechnology (what TryToUnlockTechnology calls after
-- paying; the points are restored separately). sdc_progress: a client's saved
-- character (sdc_persist). Returns the names unlocked.
function M.unlock(tech, list, why)
    local done, failed, had = {}, {}, {}
    if not ue.valid(tech) or type(list) ~= "table" then return done end
    discover()
    for _, n in ipairs(list) do
        local p = paths[n] or (SKILL_DIR .. n .. "." .. n)
        local o = ue.find_object(p)
        if not o then
            failed[#failed + 1] = n .. "(no asset)"
        else
            local okq, already = pcall(function() return tech:IsTechnologyUnlocked(o) end)
            if okq and already == true then
                had[#had + 1] = n
            elseif pcall(function() tech:UnlockTechnology(o) end) then
                done[#done + 1] = n
            else
                failed[#failed + 1] = n
            end
        end
    end
    log.info("skilltree: unlocked %d saved skill(s) (%s): %s%s%s", #done, tostring(why), table.concat(done, ", "),
        #had > 0 and (" | already: " .. table.concat(had, ", ")) or "",
        #failed > 0 and (" | FAILED " .. table.concat(failed, ", ")) or "")
    client.dirty = true
    return done
end

-- Host: the skills of a returning player's saved character answer the
-- host's checks until the client's own report (SKTREE) replaces them.
function M.seed(pc, list, name)
    if not ue.valid(pc) then return end
    local key = ue.name(pc)
    if trees[key] and trees[key].reported then return end
    local set = {}
    for n in tostring(list or "-"):gmatch("[^,]+") do
        if n ~= "-" then set[n] = true end
    end
    trees[key] = { logged = {}, set = set, list = tostring(list or "-"), name = name or ue.short(pc), seeded = true }
    log.info("skilltree: %s's saved skills answer the host's checks until the client reports: %s", tostring(name), tostring(list))
end

function M.mark_dirty() client.dirty = true end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

local function client_tick(now)
    if S.client ~= client.conn then
        client.conn, client.last, client.last_t, client.dirty = S.client, nil, 0, true
    end
    if now - client.poll_t < POLL_S and not client.dirty then return end
    client.poll_t = now
    -- with a fresh start, not before sdc_progress has reset this character
    local prog = package.loaded["sdc_progress"]
    if fresh_enabled() and type(prog) == "table" and prog.client_ready and not prog.client_ready() then return end
    local pc = ue.local_pc()
    local tech = ue.prop(pc, "TechTreeComponent")
    if not ue.valid(tech) then return end
    local list = table.concat(unlocked(tech), ",")
    if list == "" then list = "-" end
    if list ~= client.last or client.dirty or now - client.last_t >= RESEND_S then
        if net.send_to_host("SKTREE", list) then
            if list ~= client.last then log.info("skilltree: own unlocked skills sent to the host: %s", list) end
            client.last, client.last_t, client.dirty = list, now, false
            M.stats.sent = M.stats.sent + 1
        end
    end
end

-- The game loads the tree from <current slot>_SkillTree on this machine
-- (Event_LoadPlayer). On a client with a fresh start it must not: that file
-- is the client's single-player tree or a leftover of an earlier session.
local function on_load_state(ctx_p, slot_p)
    if not fresh_enabled() then return end
    local comp = ctx_p:get()
    local k = ue.ksl()
    if not k or not ue.valid(comp) then return end
    local oks, standalone = pcall(function() return k:IsStandalone(comp) end)
    local okv, server = pcall(function() return k:IsServer(comp) end)
    if not oks or not okv or standalone == true or server ~= false then return end
    local slot = ue.str(slot_p:get())
    slot_p:set(NO_SLOT)
    M.stats.loads_blocked = M.stats.loads_blocked + 1
    log.info("skilltree: the game loads this client's skill tree from %s; skipped (fresh_client_progress: a new character's tree)", slot)
end

-- ---------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------

local function on_sktree(f, pc)
    if not S or S.role ~= "host" or not ue.valid(pc) then return end
    local key = ue.name(pc)
    local r = S.remote and S.remote[key]
    local list = tostring(f[1] or "-")
    local set = {}
    for n in list:gmatch("[^,]+") do
        if n ~= "-" then set[n] = true end
    end
    local t = trees[key]
    if not t then
        t = { logged = {} }
        trees[key] = t
    end
    M.stats.received = M.stats.received + 1
    t.name = r and r.name or ue.short(pc)
    t.set = set
    t.reported = true
    if t.list ~= list then
        t.list = list
        t.logged = {}
        log.info("skilltree: %s's unlocked skills: %s (the host's skill checks for this player answer from them)",
            tostring(t.name), list)
    end
end

-- Post-hook: (Context, ReturnValue, Technology). A non-nil return replaces
-- the result; nil leaves the engine's answer.
local function on_is_unlocked(ctx_p, _, tech_p)
    if not active then return nil end
    local comp = ctx_p:get()
    local a = comp and ctx.addr(comp)
    local t = a and by_comp[a]
    if not t or not t.set then return nil end
    local tech = tech_p:get()
    local ta = tech and ctx.addr(tech)
    if not ta then return nil end
    local n = name_of[ta]
    if not n then
        n = ue.short(tech)
        name_of[ta] = n
    end
    local v = t.set[n] == true
    M.stats.answers = M.stats.answers + 1
    if not t.logged[n] then
        t.logged[n] = true
        log.info("skilltree: the game asked on the host whether %s has %s -> %s", tostring(t.name), n, tostring(v))
    end
    return v
end

local function install_unlocked_hook()
    if hooks.unlocked or not ue.find_object(IS_UNLOCKED_FN) then return end
    hooks.unlocked = true
    local ok, err = pcall(RegisterHook, IS_UNLOCKED_FN, function() end, function(ctx_p, ret_p, tech_p)
        local okc, v = pcall(on_is_unlocked, ctx_p, ret_p, tech_p)
        if not okc then
            log.err_throttled("skilltree-hook", "skilltree: IsTechnologyUnlocked hook: %s", tostring(v))
            return nil
        end
        return v
    end)
    log.info("skilltree: IsTechnologyUnlocked post-hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

local function install_load_hook()
    if hooks.load or not ue.find_object(LOAD_STATE_FN) then return end
    hooks.load = true
    local ok, err = pcall(RegisterHook, LOAD_STATE_FN, function(ctx_p, slot_p)
        local okc, e = pcall(on_load_state, ctx_p, slot_p)
        if not okc then log.err_throttled("skilltree-load", "skilltree: LoadTechStateFromSlot hook: %s", tostring(e)) end
    end, function() end)
    log.info("skilltree: LoadTechStateFromSlot pre-hook %s%s", ok and "ok" or "FAILED", ok and "" or (" " .. tostring(err)))
end

local function host_tick()
    local m = {}
    for key, t in pairs(trees) do
        local r = S.remote and S.remote[key]
        if not r or not ue.valid(r.pc) then
            trees[key] = nil
        else
            local tech = ue.prop(r.pc, "TechTreeComponent")
            local a = ue.valid(tech) and ctx.addr(tech)
            if a then m[a] = t end
        end
    end
    by_comp = m
    local want = sync_enabled() and next(S.remote or {}) ~= nil
    if want then install_unlocked_hook() end
    active = want and hooks.unlocked
end

-- ---------------------------------------------------------------------------
-- Tick / install
-- ---------------------------------------------------------------------------

local function tick()
    if not S then return end
    local now = os.time()
    install_load_hook()
    if S.role == "client" then
        active, by_comp = false, {}
        client_tick(now)
    elseif S.role == "host" then
        client.conn = nil
        host_tick()
    else
        active, by_comp, trees, client.conn = false, {}, {}, nil
    end
end

function M.reset_world()
    active, by_comp, name_of = false, {}, {}
    trees = {}
    client.last, client.dirty = nil, true
end

function M.status_line()
    local n = 0
    for _ in pairs(trees) do n = n + 1 end
    return string.format("skilltree: sent=%d received=%d players=%d answers=%d relocked=%d loads blocked=%d hooks=%s/%s",
        M.stats.sent, M.stats.received, n, M.stats.answers, M.stats.relocked, M.stats.loads_blocked,
        tostring(hooks.unlocked), tostring(hooks.load))
end

local installed = false
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    if session and session.world_reset_hooks then session.world_reset_hooks.skilltree = M.reset_world end
    if installed then return end
    installed = true
    net.on("SKTREE", on_sktree)
    install_load_hook()
    ue.every("skilltree", 1000, tick)
    log.info("skilltree: installed (skilltree_sync=%s, fresh_client_progress=%s)", tostring(sync_enabled()), tostring(fresh_enabled()))
end

return M
