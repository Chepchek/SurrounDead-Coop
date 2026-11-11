-- SDCoop: the world's objects and their state in co-op (work\audit\world.md).
--
-- Most of the level is placed actors that every machine loads from the same
-- package, so an object has the same path name everywhere
-- (/Game/Levels/LongdownValley.LongdownValley:PersistentLevel.<name>) and is
-- found by it (StaticFindObject). Many of them do not replicate, or keep
-- their state in variables that do not replicate, and the game changes that
-- state only on the machine where the player pressed the key or swung the
-- axe. Each feature below sends that change to the other machines, which
-- apply it with the object's OWN function (the one the game runs for it).
-- Senders are Blueprint post-hooks (they run where the script ran); the host
-- is the authority and relays to every client; a client that joins asks the
-- host for a snapshot (WHI).
--
--   world_containers  loot containers (BP_LootContainer and children, lock-pick
--                     and tool containers): "searched" (ContainerLooted) and a
--                     picked lock (IsLocked?) are per machine. OpenContainer
--                     (post) -> WLOOT; the receiver sets the same variables
--                     (DistanceOutline drops the magnifier, the next search
--                     opens at once). A placed box is named by its level
--                     path; a runtime one (camps / POIs: PrefabMaster child
--                     actors, named differently on each machine) by class and
--                     place, @Class@x,y,z (CB), and a client keeps the host's
--                     word per place for copies that replicate in later.
--                     Refill on the host: Bind_Refill (post)
--                     -> clients run Bind_Refill. "Mark as storage container"
--                     (OnExecuteInteract Option2, presser's machine only)
--                     -> WSTORE: the host's copy (the one that refills and is
--                     saved) gets MarkedAsStorageContainer and the component's
--                     DoesContainerRefillLoot? the way the option sets them.
--   world_loot_noise  a client's noisy search (NoiseEvent -> PauseInteract)
--                     reported its AI noise and BreakOpen sound on the client
--                     only (no AI there): the host reports the same noise for
--                     that player and plays the sound for everyone. The looting
--                     camera shake: container player-0 calls whose CurrentActor
--                     is a remote player resolve to that player (scope).
--   world_doors       BP_LockedDoor (no replication at all: Event_Door /
--                     EventDoorBehind, lock picked / crowbar) and the
--                     laboratory sliding doors (Event_AutoDoor) -> WDOOR.
--                     Replicated doors with MC_OpenDoor (warehouse, keycard,
--                     keypad, hangar, gates...) sync natively within network
--                     range, but their open/closed variable does not replicate:
--                     WRDOOR reconciles a client that was far away or joined
--                     later, by the door's own MC_OpenDoor run locally.
--   world_harvest     trees / rocks (foliage instances): the swing removes the
--                     instance and spawns a BP_HarvestableObject_* on every
--                     machine that traced it; the client's own spawn is blocked
--                     (only the host's replicated one stays), the host sends
--                     every removed instance (WFOL) and a client's harvest the
--                     host did not see (WHARV) is done by the host the game's
--                     way. The harvestable's Mesh / Material do not replicate:
--                     on a client the host's tree had no mesh (invisible, no
--                     collision), so the client dresses it from the foliage
--                     component it came from. Its hits count on the host only
--                     (MaxHits, the fall and the grant are the host's): the
--                     host's replay of a client's swing practically never hits
--                     (sdc_combat), so the client sends its own hits (WHHIT)
--                     and the host runs HitHarvestableObject with them. Scrap
--                     metal piles (salvage) run on the host for a client
--                     (WSALV, with the client's own roll). Resources go to the
--                     player who harvested (scope), not to the host.
--   world_objects     trash piles (TrashObject), explosive barrels and
--                     infestations: destruction is mirrored (WTRASH / WBOOM /
--                     WINF), a client's firearm hit (Trace_Impact ->
--                     Damage_Object, client only) reaches the host (WDMG), and
--                     scrap / XP of the host-side destruction go to the player
--                     who did it (scope). Landmines (BP_Landmine, the
--                     player's Buildable_LandMine) replicate, but their
--                     explosion (Event_Explode: flash, sound, scorch) runs
--                     where it was set off: the host's -> WMINE to the
--                     clients in earshot, a client's own -> WMINE to the
--                     host (its mine goes off there: damage, kills).
--   world_build       a client's placement: Event_LaunchBuildMode is a client
--                     RPC, so the host's copy of the client's BuildingComponent
--                     never had DARef and Svr_SpawnBuild spawned nothing. The
--                     client mirrors its build mode (WBMODE); after the host's
--                     SpawnBuild the client runs SpawnBuild's own-player tail
--                     (consume the item, next item or stop) on WBUILT. Moving a
--                     placed buildable (ReplacingObject) and picking it up run
--                     for the client through the scope. Buildables do not
--                     replicate movement: the host's move (SpawnBuild ->
--                     K2_SetActorTransform) stayed on the host. The moved
--                     buildable replicates movement from then on, and the
--                     host sends the new place (WMOVE) for clients' copies.
--   world_prefabs     camps, abandoned trucks, crashed helicopters, settlements
--                     (PrefabMaster_C children: ChildActorComponents for the
--                     stations / containers / AI volume + static meshes for
--                     tents, RVs...), hidden caches and special item cases:
--                     their spawners are level actors that do not replicate,
--                     so a client rolled its own (BP_PrefabSpawner "Random
--                     Check", random spawn points) and got local-only camps
--                     whose stations did nothing on the host. Client: the
--                     spawn is blocked (BeginDeferredActorSpawnFromClass pre-
--                     hook, wco = the spawner: class swapped like sdc_items'
--                     loot block) and the useless spawner goes (its discovery
--                     timer / marker); a pass every 5 s removes client-only
--                     ones that still appeared. Host: each spawned prefab
--                     actor replicates (NotifyOnNewObject, SetReplicates, 1 km
--                     cull); on a client UChildActorComponent then skips the
--                     replicated children (stations, containers come from the
--                     host) and builds only the visual ones. The prefab's own
--                     AI volume copy on a client must not spawn AI
--                     (SpawnAIFromClass pre-hook).
--   world_resource_to_inventory  the host-side adds above use the game's
--                     JigTryAddItemSomewhere, which on the host finds no
--                     inventory widget for a remote player and drops the item
--                     at that player's feet; the drop is turned into the
--                     plugin's server-side add (AddNewItemSomewhere).
--
-- Rules: no object wrapper is kept beyond the call that got it (paths,
-- addresses and numbers only); hook callbacks never throw and return nothing;
-- FindAllOf only for the join snapshot (specific classes, once per join).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local M = {
    stats = {
        loot_sent = 0, loot_applied = 0, refills = 0, noise_sent = 0, noise_host = 0, store_sent = 0, store_applied = 0,
        camp_applied = 0, camp_missing = 0,
        doors_sent = 0, doors_applied = 0, rdoors_fixed = 0,
        fol_sent = 0, fol_applied = 0, harv_blocked = 0, harv_requests = 0, harv_host = 0, salvage = 0,
        trash = 0, booms = 0, infest = 0, dmg_sent = 0, dmg_host = 0,
        build_modes = 0, builds = 0, build_tails = 0,
        scopes = 0, grants = 0, grant_drops = 0, snapshots = 0, pending = 0,
        prefab_blocked = 0, prefab_ai_blocked = 0, prefab_replicated = 0, prefab_removed = 0,
        hits_sent = 0, hits_host = 0, hits_dup = 0, dressed = 0, fol_idx = 0, fol_ovl = 0, fol_miss = 0,
        moves = 0, moves_applied = 0,
        rinf = 0, rinf_shown = 0, moon = 0, jets = 0, waves_blocked = 0,
        pw_steps = 0, pw_host = 0, pw_sent = 0, pw_applied = 0, pw_tries = 0, pw_tries_ok = 0, pw_restored = 0,
        ad_rolls = 0, ad_planes = 0, ad_crates = 0, crate_sent = 0, crate_snapped = 0,
        lk_counts = 0, lk_breaks = 0, lk_unlocks = 0, lk_tools = 0, lk_keypads = 0, inf_shared = 0, inf_unlocked = 0,
        -- landmines: host explosions sent / a client's set off on the host / client own sent,
        -- shown here by the copy's Event_Explode / by the effects at the host's point / already here
        mines = 0, mines_host = 0, mines_sent = 0, mines_copy = 0, mines_fx = 0, mines_dup = 0,
    },
}

local S = nil
local addr = ctx.addr
local clock = os.clock

-- ---------------------------------------------------------------------------
-- Classes and functions
-- ---------------------------------------------------------------------------

-- class / asset paths in one table (the main chunk is near Lua's 200-locals limit)
local PATH = {}
PATH.LOOT = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
PATH.PICKLOCK = "/Game/Inventory/Containers/PicklockContainer/BP_MASTER_PicklockContainer.BP_MASTER_PicklockContainer_C"
PATH.TOOLBOX = "/Game/Inventory/Containers/ToolRequiredContainer/BP_MASTER_ToolRequiredContainer.BP_MASTER_ToolRequiredContainer_C"
PATH.LOCKED_DOOR = "/Game/Blueprints/Other/Doors/BP_LockedDoor.BP_LockedDoor_C"
PATH.LAB_DOOR = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySlidingDoor.BP_LaboratorySlidingDoor_C"
PATH.MELEE = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C"
PATH.FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C"
PATH.TRASH = "/Game/Blueprints/Other/InteractableWorldObject/TrashObject.TrashObject_C"
PATH.TRASH_DESTROYED = "BndEvt__TrashObject_WorldObjectComponent_K2Node_ComponentBoundEvent_1_ObjectDestroyed__DelegateSignature"
PATH.TRASH_DAMAGED = "BndEvt__TrashObject_WorldObjectComponent_K2Node_ComponentBoundEvent_0_ObjectDamaged__DelegateSignature"
PATH.BARREL = "/Game/Blueprints/Other/ExplosiveBarrel/BP_ExplosiveBarrelMaster.BP_ExplosiveBarrelMaster_C"
PATH.INFEST = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
PATH.GFL = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C"
PATH.BUILDING = "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C"
PATH.BUILDABLE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
PATH.PLAYER = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local SPAWN_FN = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"
-- world_prefabs: everything in one table (the main chunk is at the 200-locals limit)
local PF = {}
PF.SPAWN_AI_FN = "/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass"
PF.PREFAB = "/Game/Prefabs/PrefabMaster.PrefabMaster_C"
-- level spawners whose spawn must come from the host (class short name)
PF.BLOCK_SPAWNERS = {
    BP_PrefabSpawner_C = "prefab", BP_PrefabSpawner_Dynamic_C = "prefab",
    BP_HiddenCache_Spawner_C = "cache", BP_SpecialItemContainerSpawner_C = "cache",
    -- BP_SettlementManager rolls which camp spawns (Array_Random @203) on each
    -- machine: the client's settlement (traders, quest giver, stations) stood
    -- elsewhere than the host's
    BP_SettlementCampSpawner_C = "cache",
    -- late-game random infestations (BP_InfestationManager broadcasts Spawn ->
    -- RandomSpawn roll per point @503): the host's replicate (RI below)
    BP_RandomInfestationSpawnPoint_C = "nest",
    -- BP_EventManager (not replicated: every machine runs its own timers with
    -- local authority) spawns the airdrop plane (@4179) and the jet fly-by
    -- (@752); the host's replicate (both classes bReplicates)
    BP_EventManager_C = "event",
    -- BP_POIManager (189 named places, not replicated): its bosses (@340, on
    -- entering the radius) and its crates (@2026 rare compound crate 5%, @2946
    -- the major POI's unique crate) were made on every machine
    BP_POIManager_C = "poi",
    -- AirdropAircraft (replicated, but its drop runs on every copy: BeginPlay
    -- -> CheckForRegionCrossing timer -> SpawnAirdrop @450, no authority
    -- check): the client's copy dropped its own crates (removed only by the
    -- 5 s client-only pass, after they had fallen for a while)
    AirdropAircraft_C = "event",
}
-- which switch each kind of block belongs to
PF.BLOCK_KEY = { prefab = "world_prefabs", cache = "world_prefabs", nest = "world_objects", event = "world_prefabs",
                 poi = "world_prefabs" }
-- loot containers a client may keep although it made them itself (sdc_items' business)
PF.KEEP_LOCAL = { Container_DeadPlayerLoot_C = true }
PF.LOOT = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
-- what such spawns leave on a client (classes with few instances): only this
-- machine's own runtime ones go (authority); the host's replicated copies stay
PF.CLIENT_ONLY_CLASSES = { "PrefabMaster_C", "Container_HiddenCache_C", "Container_SpecialItemSpawner_C",
    "BP_Infestation_C", "AirdropAircraft_C", "Master_AirdropContainer_C", "BP_Event_JetActor_C" }
PF.PREFAB_CULL = 100000.0   -- cm: camps are relevant from 1 km (default 150 m: tents popping in)
-- Loot containers spawned at runtime: the camps' / POIs' (PrefabMaster child
-- actors: ChildActor4_GEN_VARIABLE_Container_..._CAT_2147475783), caches. The
-- host's replicate, but each machine names its copy differently, so the
-- path-named sync (WLOOT / WLOOTS / WLOOTR / WNOISE) skipped them: host and
-- client searched the same camp chests each on their own (0.7.0). On the wire
-- they are named by class and place, @Class@x,y,z (a copy's place is the
-- host's, replicated at its spawn). One table: the main chunk is near Lua's
-- 200-locals limit. Only paths, keys and numbers are kept.
local CB = {
    PREFIX = "@",
    MATCH = 50,            -- cm: a key's place -> the container here (same class), nearest
    SETTLE_S = 0.5,        -- client: a new copy is looked at this long after it appeared (after its BeginPlay)
    MAX = 3000,            -- client: places kept
    live = {},             -- [path] = clock it appeared (0: looked at) - runtime containers here (NotifyOnNewObject)
    fresh = false,         -- new entries in live
    prune_at = 0,
    keys = {},             -- client: [class] = { [key] = { loc, l = searched, u = unlocked } } the host's word
    nkeys = 0,
    logged = 0,
    scanned = {},          -- host: [class] = clock of its last FindAllOf (a container the watch missed)
}
PATH.HEARING = "/Script/AIModule.Default__AISense_Hearing"
local NOT_AN_ACTOR = "/Script/CoreUObject.Object"

local HARVEST_CLASS = {
    t = "/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Tree.BP_HarvestableObject_Tree_C",
    r = "/Game/Blueprints/Other/HarvestableObjects/BP_HarvestableObject_Rocks.BP_HarvestableObject_Rocks_C",
}
-- Harvestables of the host on clients, and clients' hits on them (one table:
-- the main chunk is at the 200-locals limit). Only paths and numbers kept.
local HV = {
    DUP_S = 0.5,           -- host: a client's hit this soon after the host's replay hit that tree with
                           -- that player's weapon is the same swing (the host plays the montage first)
    WAIT_S = 2,            -- host: a client's hit on a harvestable not spawned here yet waits this long
    MATCH = 80,            -- cm: a reported harvestable place -> the actor here
    REC_MAX = 400,         -- client: places of the host's harvestables kept for dressing
    live = {},             -- [path] = { kind = "t" | "r", t = clock, dressed = bool } (NotifyOnNewObject)
    recs = {},             -- client: { { ip = ism path, loc = {X,Y,Z}, t = clock } }
    dress_due = 0,         -- client: next dressing pass
    out = {},              -- client: [address] = { kind, loc, hits, at, n, name } hits to send
    replay = {},           -- host: ["tree:pc"] = clock of the host's replay hit
    wait = {},             -- host: { pc, kind, loc, hits, at, till } hits on harvestables not here yet
    rate = {},             -- host: [pc address] = { t, n } WHHIT per second
    logged = {},           -- [address] = count of info lines for that harvestable
    last_add = nil,        -- client: { name, n, t } the last JigTryAddItemSomewhere here (salvage roll)
}
-- Random infestations (one table, same reason): the host's runtime
-- BP_Infestation_C replicate; clients dress their copies (WRINF).
local RI = {
    CLASS = "BP_Infestation_C",
    PREFIX = "~R~",        -- key of a random nest on the wire: ~R~x,y,z (its spawn point's place)
    MATCH = 150,           -- cm: a key's place -> the nest here
    live = {},             -- [path] = { t, done } runtime BP_Infestation_C seen here (NotifyOnNewObject / scan)
    host = {},             -- host: [key] = { loc, nm, dm, d, name } the host's random nests this world
    recs = {},             -- client: [key] = { loc, nm, dm, d, t } what the host said about each
    dressed = {},          -- client: [address] = key of the copy dressed for it
    due = 0,               -- next pass
    scan_at = -100,        -- last FindAllOf fallback
}
-- World events of BP_EventManager (one table): the blood moon.
local EV = {
    MANAGER = "/Game/Blueprints/Events/BP_EventManager.BP_EventManager_C",
    JET = "/Game/Blueprints/Events/Jet/BP_Event_JetActor.BP_Event_JetActor_C",
    moon = false,          -- host: the blood moon is on (for snapshots)
    shown = nil,           -- client: the state applied here
    off_logged = {},       -- client: [manager path] = true: its own roll is off
    jets = {},             -- host: paths of new jets to make always relevant
}
-- Moved buildables (one table, same reason).
local MV = {
    moving = {},           -- host: [controller address | "host"] = { path, cls, name, old, at }
    marked = {},           -- host: [path] = true: replicates its movement now
}
-- Power / laboratory / bunker puzzle and other one-machine world switches
-- (one table, same reason): shared state, the host's (see the PW section).
local PW = {
    K = {},                -- [kind] = spec { order, classes, state, set, step }
    kinds = {},            -- kinds in apply order
    cls_kind = {},         -- [class short name] = kind
    objs = nil,            -- host: this world's tracked objects { { p = path, k = kind, o = object } }
    idx = {},              -- host: [path] = that entry
    todo = nil, found = nil,   -- host: classes still to list, entries listed so far
    base = {},             -- host: [path] = state at the world's start (the level's own)
    sent = {},             -- host: [path] = state last sent to the clients
    world_at = nil,        -- host: clock the world was first seen (objects listed 5 s later)
    dirty = {},            -- host: clocks of full passes to make
    cursor = 1,            -- host: idle pass position
    idle_at = 0,           -- host: next idle chunk
    want = {},             -- client: [path] = the host's state last received
    checks = {},           -- client: { at, paths, round } re-checks after applying
    pressed = {},          -- [path] = clock of this machine's own press
    restored = false,      -- host: the save's states applied this world
    save_pending = false,  -- host: a save's write is scheduled
    resync = {},           -- host: [controller address] = { pc, at }: all states to that client
    CHUNK = 60,            -- host: objects per tick in the idle pass
    RESYNC_S = 4,          -- host: a client's step -> all states to it this long after its last one
    IDLE_S = 5,            -- host: idle pass period
}
-- Infestation XP shared in co-op (one table, same reason; see IX below the
-- infestation code).
local IX = {
    got = {},      -- host: [nest key] = controller address whose own copy died (WINFD): the game paid it there
    own = {},      -- client: [nest key] = true: this machine's own copy died (the game paid it here)
    recv = {},     -- client: [nest key] = true: the host's share arrived
    SKULL = "/Game/UI/Textures/Survival-UI-Bundle/Rhombus_Solid/512x512/Skul.Skul",
}
-- Locks, keys and tools of a client (one table, same reason; see the LK section).
local LK = {
    counted = 0, counted_at = -100,   -- client: this player's lockpicks (widgets), cached
    break_at = -100,                  -- client: the last broken pick sent
    dur = nil,                        -- client: { u, m, destroy, t } the last wear call
    aimed = nil,                      -- client: the scanner / door this player looks at
    ui = {},                          -- client: [keypad widget address] = door path (opened here)
    break_host = {}, tool_host = {}, key_host = {},   -- host: [controller address] = clock (rate)
    aim = {},                         -- host: [object address] = { pc, t } the remote player at it
    redir = {},                       -- host: [object address] = clock of its last scope answer
}
PATH.JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
PATH.BREAK_OPEN_CUE = "/Game/Audio/BreakOpen_Cue.BreakOpen_Cue"
PATH.DA_SCRAP = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/DA_ScrapMetal.DA_ScrapMetal"

-- Replicated doors (bReplicates, MC_OpenDoor runs on every machine in
-- range) and the variable that holds their state on each machine. The value
-- is compared raw between host and client (same meaning on both).
local RDOORS = {
    { "/Game/Blueprints/Other/Doors/BP_WarehouseDoors.BP_WarehouseDoors_C", "BP_WarehouseDoors_C", "IsClosed" },
    { "/Game/Blueprints/Other/Doors/BP_ContainerDoors.BP_ContainerDoors_C", "BP_ContainerDoors_C", "Open?" },
    { "/Game/Blueprints/Other/Doors/BP_BarrierGate.BP_BarrierGate_C", "BP_BarrierGate_C", "Open?" },
    { "/Game/Blueprints/Other/Doors/BP_KeycardDoor.BP_KeycardDoor_C", "BP_KeycardDoor_C", "Open?" },
    { "/Game/Blueprints/Other/Doors/Keypad/BP_KeypadDoor.BP_KeypadDoor_C", "BP_KeypadDoor_C", "Open?" },
    { "/Game/Blueprints/Other/Doors/BP_HangarDoor.BP_HangarDoor_C", "BP_HangarDoor_C", "Open?" },
    { "/Game/Blueprints/Other/Doors/PoliceStation/BP_PoliceStationGarageDoor.BP_PoliceStationGarageDoor_C",
      "BP_PoliceStationGarageDoor_C", "Open?" },
}
local RDOOR_VAR = {}   -- [class short name] = state variable (children: by prefix)
for _, d in ipairs(RDOORS) do RDOOR_VAR[d[2]] = d[3] end

-- BP_LockedDoor timeline direction (ETimelineDirection: 0 forward = opening)
local LD_DIR = "Timeline_OpenDoor__Direction_CA4B83EF45872B61E7779EAD32D6380C"

-- RepItemInfo members (BP_JigComponent)
local F_ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local F_COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"

local HIT_KEEP_S = 120         -- a hitter is remembered this long
local GRANT_WINDOW = 0.1       -- s: the game's add (and its drop) follows its player-0 call at once;
                               -- a player's own inventory drop a moment later stays a drop
local HARV_WAIT_MS = 300       -- host: a client's harvest request waits for the host's own trace
                               -- (the host plays the swing before the client: its replay, if it hits
                               -- at all, came before the request)
local TRASH_WAIT_MS = 700
local RDOOR_SETTLE_MS = 4000   -- host: a door's timeline has finished by then
local RDOOR_CHECK_MS = 1500    -- client: compare after this
local FOL_RADIUS = 60          -- cm: a foliage instance at the reported place
local FOL_MATCH = 35
local PENDING_FOR_S = 90       -- client: objects not found yet are retried this long
local CHUNK = 1500             -- characters per snapshot message
local SNAP_AFTER_S = 3         -- client: ask for the snapshot this long after the handshake

-- ---------------------------------------------------------------------------
-- State (per world unless noted)
-- ---------------------------------------------------------------------------

local hooked = {}          -- [path] = true (never reset: hooks stay registered)
local hook_try_at = -100
local applying = 0         -- > 0 while this module calls into the game (client: no echo)
local cls_cache, cls_cache_at = {}, 0   -- [address] = kind | false (resolver)
local hitters = {}         -- host: [address] = { name =, pc = controller | false, t = }
local grant_until = {}     -- host: [controller address] = clock: a resource add for that player
local fol_removed = {}     -- host: [ism path] = { "x,y,z", ... } this session
local fol_seen = {}        -- host: ["ism|x|y|z"] = true
local pending_harv = nil   -- { t, loc, kind, block } from the spawn pre-hook
local pending_dmg = {}     -- client: { { path, dmg, t } } object damage waiting for its Trace_Impact
local loot_sent = {}       -- [path] = true: this machine already reported / applied it
local door_state = {}      -- host: [path] = { ev, want, unlocked } for the snapshot
local rdoor_toggled = {}   -- client: [path] = clock of the last local toggle
local pending = {}         -- client: { kind, path, args, until } objects not found yet
local snap_asked = {}      -- client: [world key] = clock
local world_since = nil    -- client: [world key] -> clock the world was first seen
local build = {}           -- host: [controller address] = { rep = bool, at = clock }
local last_role = nil
local prev_resolver = nil
local in_resolver = false
local cache = { block_cls = nil, harvest_cls = {}, scrap = nil, cue = nil, menu_cls = nil }

local function on(key)
    if cfg.get("world_sync") == false then return false end
    return cfg.get(key) ~= false
end

local function is_host() return S ~= nil and S.role == "host" end
local function client_ready()
    return S ~= nil and S.role == "client" and S.client ~= nil and S.client.acked == true
end

local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end

local function obj(p)
    local v = get(p)
    if ue.valid(v) then return v end
    return nil
end

local function num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n then return d end
    return n
end

-- Path of an object that may be inside its own destruction (same frame, not
-- yet collected): GetFullName without the validity check.
local function raw_path(o)
    if o == nil then return nil end
    local ok, s = pcall(function() return o:GetFullName() end)
    if not ok or type(s) ~= "string" then return nil end
    return s:match("^%S+%s+(.+)$") or s
end

local function path_of(o)
    if not ue.valid(o) then return nil end
    return raw_path(o)
end

-- Level paths are long and all alike: "~Map~Name" on the wire.
local function pack(p)
    if type(p) ~= "string" then return "" end
    return (p:gsub("^/Game/Levels/([%w_]+)%.%1:PersistentLevel%.", "~%1~"))
end

local function unpack_path(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^~([%w_]+)~", "/Game/Levels/%1.%1:PersistentLevel."))
end
M.pack, M.unpack = pack, unpack_path

local function find(path)
    if type(path) ~= "string" or path == "" then return nil end
    return ue.find_object(path)
end

local function level_actor(o)
    return ue.valid(o) and not ue.is_runtime_spawned(o)
end

local function short_class(o) return ue.class_name(o) end

-- A client world, read from the object's own world (during a client's map
-- load S.role can still be stale).
function PF.world_is_client(o)
    local ksl = ue.ksl()
    if not ksl then return false end
    local oks, standalone = pcall(function() return ksl:IsStandalone(o) end)
    if not oks or standalone == true then return false end
    local ok, server = pcall(function() return ksl:IsServer(o) end)
    return ok and server == false
end

local function is_player_character(o)
    return ue.valid(o) and ue.class_name(o):find("PlayerCharacter", 1, true) ~= nil
end

local function locally_controlled(p)
    local ok, v = pcall(function() return p:IsLocallyControlled() end)
    return ok and v == true
end

local function remote_pc(pc)
    return ue.valid(pc) and ue.valid(ue.prop(pc, "NetConnection"))
end

-- The character an actor (weapon) belongs to.
local function owner_character(a)
    local o = a
    for _ = 1, 3 do
        o = ue.try(function() return o:GetOwner() end)
        if not ue.valid(o) then return nil end
        if is_player_character(o) then return o end
    end
    return nil
end

-- Host: who a character is: its remote controller, false for the host's own,
-- nil when unknown.
local function player_of_character(ch)
    if not is_player_character(ch) then return nil end
    local pc = ue.prop(ch, "Controller")
    if remote_pc(pc) then return pc end
    if ue.valid(pc) then return false end
    return nil
end

local function remote_pcs()
    return (S and S.remote_pcs) or {}
end

local function to_host(kind, ...)
    if not client_ready() then return false end
    return net.send_to_host(kind, ...)
end

-- Host -> client traffic with a budget. A refill wave (every container's
-- Difficulty.Refill timer starts at the level's load, so they all fire within
-- seconds of each other) sent one message per container: 2569 in 4 s, the
-- client was dropped (0.6.46). Every host -> client message of this module goes
-- through Q.send: straight out while that client's queue is empty, else (and
-- always for snapshots and refill batches) queued and sent at most
-- Q.PER_TICK per client and 250 ms tick, in order.
local Q = {
    PER_TICK = 3,          -- messages per client and tick (12/s, at most ~18 KB/s)
    MAX = 1500,            -- queued messages per client before the oldest go
    out = {},              -- [controller address] = { items = { packed }, head = 1, n = 0 }
    all = false,           -- queue everything (snapshot)
    looted = {},           -- host: [path] = true: some client's copy may show it searched
    refill = {},           -- host: refilled paths not batched yet
    wave = nil,            -- host: summary of the current refill wave
    cref = {}, cref_set = {}, cref_head = 1,   -- client: refills to apply
    CREF_PER_TICK = 25,    -- client: Bind_Refill calls per tick
    cwave = nil,           -- client: summary
}

function Q.push(pc, kind, ...)
    local a = addr(pc)
    if not a then return false end
    local q = Q.out[a]
    if not q then q = { items = {}, head = 1, n = 0 }; Q.out[a] = q end
    if q.n - q.head + 1 >= Q.MAX then
        q.items[q.head] = nil
        q.head = q.head + 1
        log.err_throttled("world.queue", "world: message queue for %s is full: oldest dropped", ue.short(pc))
    end
    q.n = q.n + 1
    q.items[q.n] = table.pack(kind, ...)
    return true
end

function Q.send(pc, kind, ...)
    local a = addr(pc)
    if not a then return false end
    local q = Q.out[a]
    if Q.all or (q and q.head <= q.n) then return Q.push(pc, kind, ...) end
    return net.send_to(pc, kind, ...)
end

-- The answer to a player's own action (its placement, a move): one message,
-- never behind a snapshot or refill backlog (that can take seconds).
function Q.now(pc, kind, ...)
    if not addr(pc) then return false end
    return net.send_to(pc, kind, ...)
end

function Q.all_now(kind, ...)
    if not is_host() then return end
    for _, pc in ipairs(remote_pcs()) do Q.now(pc, kind, ...) end
end

-- Items joined by ";" in strings of at most CHUNK characters.
function Q.batches(items)
    local out, buf, len = {}, {}, 0
    for _, it in ipairs(items) do
        if len + #it + 1 > CHUNK and #buf > 0 then
            out[#out + 1] = table.concat(buf, ";")
            buf, len = {}, 0
        end
        buf[#buf + 1] = it
        len = len + #it + 1
    end
    if #buf > 0 then out[#out + 1] = table.concat(buf, ";") end
    return out
end

local function to_clients(kind, ...)
    if not is_host() then return end
    for _, pc in ipairs(remote_pcs()) do Q.send(pc, kind, ...) end
end

local function to_others(except, kind, ...)
    if not is_host() then return end
    local ea = except and addr(except)
    for _, pc in ipairs(remote_pcs()) do
        if addr(pc) ~= ea then Q.send(pc, kind, ...) end
    end
end

-- Runs fn with this module's own calls marked (client hooks then send nothing).
local function apply(fn)
    applying = applying + 1
    local ok, err = pcall(fn)
    applying = applying - 1
    if not ok then log.err_throttled("world.apply", "world: apply: %s", tostring(err)) end
    return ok
end

local function v3(t)
    local x, y, z = ue.try(function() return t.X end), ue.try(function() return t.Y end), ue.try(function() return t.Z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end

local function d2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function loc_str(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function parse_loc(s)
    local x, y, z = tostring(s or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end

local function load_object(path)
    local o = ue.find_object(path)
    if o then return o end
    ue.load_asset(path, "world")
    return ue.find_object(path)
end

-- Client: an object not found yet (its level part still loading) is retried.
local function later(kind, path, args, ttl)
    if #pending >= 400 then table.remove(pending, 1) end
    pending[#pending + 1] = { kind = kind, path = path, args = args, till = clock() + (ttl or PENDING_FOR_S) }
    M.stats.pending = #pending
end

-- Snapshot lists in messages of at most CHUNK characters.
local function send_list(pc, kind, items, head)
    local buf, len = {}, 0
    local function flush()
        if #buf == 0 then return end
        if head then Q.send(pc, kind, head, table.concat(buf, ";")) else Q.send(pc, kind, table.concat(buf, ";")) end
        buf, len = {}, 0
    end
    for _, it in ipairs(items) do
        if len + #it + 1 > CHUNK then flush() end
        buf[#buf + 1] = it
        len = len + #it + 1
    end
    flush()
end

local function split(s, sep)
    local out = {}
    for part in tostring(s or ""):gmatch("[^" .. sep .. "]+") do out[#out + 1] = part end
    return out
end

-- ===========================================================================
-- Scope: player 0 of world objects acting for a remote player (host)
-- ===========================================================================
-- sdc_ctx asks ctx.scope_resolver(world context) for every player-0 call while
-- remote players are connected. Kinds:
--   harvest / trash / infest: the last player who hit it (hook records);
--   build / container: its CurrentActor, set by OnServerExecuteInteract (build)
--     or by the searching player's own interaction (container).
-- Called very often (containers' DistanceOutline every 0.5 s): one address
-- lookup, a class name once per address and 2 s.

local KIND_PREFIX = {
    { "BP_ZombieBossHorde_", "horde" },
    { "BP_HarvestableObject", "harvest" },
    { "TrashObject", "trash" },
    { "BP_Infestation", "infest" }, { "BP_PrimaryInfestation", "infest" },
    { "Buildable_", "build" },
    { "Container_", "container" }, { "BP_LootContainer", "container" }, { "PicklockContainer_", "container" },
    { "BP_ToolRequired_", "container" }, { "BP_MASTER_PicklockContainer", "container" },
    { "BP_MASTER_ToolRequiredContainer", "container" }, { "BP_KeycardBriefcaseContainer", "container" },
    -- their server path asks for player 0 for a client's use (XP, notes): LK
    { "BP_BunkerScanner", "aim" }, { "BP_KeycardDoor", "aim" }, { "BP_KeypadDoor", "aim" },
    { "BP_HangarDoor", "aim" },
}
local GRANT_KINDS = { harvest = true, trash = true, build = true }

local function kind_of_class(c)
    for _, k in ipairs(KIND_PREFIX) do
        if c:sub(1, #k[1]) == k[1] then return k[2] end
    end
    if c:sub(-8) == "Pickup_C" then return "weapon" end   -- any item; melee weapons checked in note_swing
    return false
end

local kind_of
do
    -- kind_of_class is a function of the class name alone: kept for the session
    -- (a block local: this chunk is close to Lua's 200-locals limit)
    local kind_by_class = {}   -- [class name] = kind | false
    function kind_of(wco, a)
        a = a or addr(wco)
        if not a then return false, nil end
        local k = cls_cache[a]
        if k == nil then
            -- a live object (non-zero address): sdc_ctx's class-name cache (2
            -- engine calls instead of 4 and a new string)
            local c = (type(a) == "number" and a ~= 0 and ctx.class_name or ue.class_name)(wco)
            k = kind_by_class[c]
            if k == nil then
                k = kind_of_class(c)
                kind_by_class[c] = k
            end
            cls_cache[a] = k
        end
        return k, a
    end
end

-- Horde bosses (BP_ZombieBossHorde_Infestation / _Military / _Military_Small)
-- ReceiveBeginPlay @110-179: CastToCharacter(self) (= GetPlayerCharacter(self,
-- 0) twice) and binds that character's PlayerDead to Event_PlayerDead ->
-- DeathEvent(None) + destroy after 5 s. On the host that was always the
-- host's character: the host dying anywhere killed every horde boss (no loot,
-- no XP), a client's death did nothing. During the boss's first second (its
-- BeginPlay) player 0 is the player nearest to it: a remote one -> its
-- controller, the host -> default. Later calls (kill credit: sdc_ai_kills'
-- stand-in) are left alone.
local horde_bind = {}   -- [address] = { name =, pc = controller | false }

local function nearest_player(a)
    local l = ue.location(a)
    if not l then return nil end
    local best, bestd = nil, math.huge
    for _, p in ipairs(((ue.find_all_recent or ue.find_all)("BP_PlayerCharacter_C") or {})) do
        if ue.valid(p) and ue.valid(ue.prop(p, "Controller")) then
            local pl = ue.location(p)
            if pl then
                local d = d2(l, pl)
                if d < bestd then best, bestd = p, d end
            end
        end
    end
    return best
end

local function resolve_horde(wco, a)
    if not on("world_horde_bosses") then return nil end
    local name = ue.short(wco)
    local b = horde_bind[a]
    if not b or b.name ~= name then
        local age = ue.try(function() return wco:GetGameTimeSinceCreation() end)
        if type(age) ~= "number" or age > 1.5 then return nil end
        local p = nearest_player(wco)
        b = { name = name, pc = p and player_of_character(p) or false, t = clock() }
        horde_bind[a] = b
        log.info("world: horde boss %s binds to the death of %s (nearest player)", name,
            b.pc and ue.short(b.pc) or "the host")
    end
    if clock() - b.t > 2 then return nil end
    if b.pc and remote_pc(b.pc) then
        M.stats.scopes = M.stats.scopes + 1
        return b.pc
    end
    return nil
end

-- The swing in progress: a melee weapon asks GetPlayerController(self, 0) for
-- its camera shake right before it damages the object (HitFoliageRock /
-- HitFoliageTree @36, HitTrashObject @130). Rocks and trash hand out their
-- resource inside that same call, before any post-hook could name the hitter.
local swing = nil          -- { pc = controller | false, t = clock }
local weapon_pc = {}       -- [address] = controller | false | 0 (not a melee weapon / no owner)

local function note_swing(wco, a)
    local w = weapon_pc[a]
    if w == nil then
        w = 0
        if ue.valid(ue.prop(wco, "BP_WeaponsPickupComponent")) then
            local ch = owner_character(wco)
            local who = ch and player_of_character(ch)
            if who ~= nil then w = who end
        end
        weapon_pc[a] = w
    end
    if w ~= 0 then swing = { pc = w, t = clock() } end
end

local function hitter_of(wco, a)
    local h = hitters[a]
    if h and h.name ~= ue.short(wco) then hitters[a] = nil; h = nil end
    local now = clock()
    if h and now - h.t < 0.5 then return h.pc end           -- named by this hit's post-hook (tree: 0.2 s delay)
    if swing and now - swing.t < 0.05 then                   -- inside the swing
        hitters[a] = { name = ue.short(wco), pc = swing.pc, t = now }
        return swing.pc
    end
    if h and now - h.t < HIT_KEEP_S then return h.pc end
    return nil
end

local function own_resolve(wco, a0)
    if not is_host() then return nil end
    local k, a = kind_of(wco, a0)
    if not k then return nil end
    if k == "weapon" then note_swing(wco, a) return nil end
    if k == "horde" then return resolve_horde(wco, a) end
    if k == "aim" then
        if not on("world_doors") then return nil end
        return LK.aim_who(wco, a)
    end
    if k == "harvest" or k == "trash" or k == "infest" then
        -- an infestation asks for player 0 also while alive (health bar, its
        -- waves): only its destruction (XP, InfestationsDestroyed @9868-10911,
        -- after IsDestroyed? @11090) belongs to who destroyed it
        -- (the context object is alive - a non-zero address, running a
        -- Blueprint now -: ue.prop_live skips ue.prop's validity check)
        if k == "infest" and (math.type(a) == "integer" and a ~= 0 and ue.prop_live or ue.prop)(wco, "IsDestroyed?") ~= true then
            return nil
        end
        local who = hitter_of(wco, a)
        if who == false then return false end
        if who == nil or not remote_pc(who) then return nil end
        if GRANT_KINDS[k] then grant_until[addr(who) or -1] = clock() + GRANT_WINDOW end
        M.stats.scopes = M.stats.scopes + 1
        return who
    end
    if k == "build" or k == "container" then
        if (k == "build" and not on("world_build")) or (k == "container" and not on("world_loot_noise")) then return nil end
        -- every call of every container nearby (DistanceOutline, 2/s each)
        local cur = (math.type(a) == "integer" and a ~= 0 and ue.prop_live or ue.prop)(wco, "CurrentActor")
        local who = player_of_character(cur)
        if not who then return nil end
        if GRANT_KINDS[k] then grant_until[addr(who) or -1] = clock() + GRANT_WINDOW end
        M.stats.scopes = M.stats.scopes + 1
        return who
    end
    return nil
end

local function resolver(wco, a)
    if in_resolver then return nil end
    -- fast: not the host, or an object already known to be of no world kind
    -- (most player-0 calls: the HUD, the host's own character, the sky):
    -- straight to the next resolver, as own_resolve would answer nil
    if S == nil or S.role ~= "host" or (a ~= nil and cls_cache[a] == false) then
        if prev_resolver then return prev_resolver(wco, a) end
        return nil
    end
    in_resolver = true
    local ok, r = pcall(own_resolve, wco, a)
    in_resolver = false
    if not ok then
        log.err_throttled("world.resolve", "world: resolver: %s", tostring(r))
        r = nil
    end
    if r ~= nil then return r end
    if prev_resolver then return prev_resolver(wco, a) end
    return nil
end
M.resolver = resolver
-- sdc_ctx's idle check (ctx.set_idle_check): true exactly when resolver()
-- would answer nil for this address now without any side effect (the fast
-- branch above, and the chain behind it idle too).
M.resolver_idle = function(a)
    if in_resolver then return true end
    if S == nil or S.role ~= "host" or cls_cache[a] == false then
        return ctx.resolver_idle ~= nil and ctx.resolver_idle(prev_resolver, a)
    end
    return false
end

local function remember_hit(o, pc_or_false)
    local a = addr(o)
    if not a then return end
    hitters[a] = { name = ue.short(o), pc = pc_or_false, t = clock() }
end

-- ===========================================================================
-- Resource adds for remote players: the drop at their feet -> their inventory
-- ===========================================================================

-- BP_PlayerCharacter.JigMP_OnRequestDropItem(ItemInfo, ContainerName, out
-- ActorRef), post, host: JigTryAddItemSomewhere found no widget slot for a
-- remote player and dropped the item at the character.
local function on_player_drop(c, info_p, _, actor_p)
    if not is_host() or not on("world_resource_to_inventory") then return end
    local pawn = c and c:get()
    if not is_player_character(pawn) then return end
    local pc = ue.prop(pawn, "Controller")
    if not remote_pc(pc) then return end
    local until_t = grant_until[addr(pc) or -1]
    if not until_t or clock() > until_t then return end
    local info = get(info_p)
    local da = info and ue.try(function() return info[F_ITEMID] end)
    local n = math.floor(num(info and ue.try(function() return info[F_COUNT] end), 1))
    local drop = obj(actor_p)
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(da) or not ue.valid(comp) or n < 1 then return end
    local added, dropped, uid, to = {}, {}, {}, {}
    local ok, err = pcall(function()
        comp:AddNewItemSomewhere(da, n, nil, 1, false, FName("None"), added, dropped, uid, to)
    end)
    local name = ue.short(da)
    if ok and added.Added == true then
        M.stats.grants = M.stats.grants + 1
        local dpath = drop and path_of(drop)
        if dpath then
            -- the game still sets the drop's count right after this returns;
            -- the pickup goes a moment later, found again by its name
            ue.delay("world-grant", 50, function()
                local p = find(dpath)
                if p then pcall(function() p:K2_DestroyActor() end) end
            end)
        end
        log.info("world: %s x%d for %s went to its inventory (not dropped)", name, n, ue.short(pawn))
    else
        M.stats.grant_drops = M.stats.grant_drops + 1
        log.info("world: %s x%d for %s stays on the ground at its feet (add=%s%s)", name, n, ue.short(pawn),
            tostring(added.Added), ok and "" or (" " .. tostring(err)))
    end
end

-- Host: an item straight into a remote player's inventory (salvage).
local function grant(pawn, da, n)
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) or not ue.valid(da) then return false end
    local added, dropped, uid, to = {}, {}, {}, {}
    local ok, err = pcall(function()
        comp:AddNewItemSomewhere(da, n, nil, 1, true, FName("None"), added, dropped, uid, to)
    end)
    log.info("world: %s gets %s x%d (added=%s dropped=%s%s)", ue.short(pawn), ue.short(da), n, tostring(added.Added),
        tostring(dropped["Dropped?"]), ok and "" or (" FAILED " .. tostring(err)))
    return ok
end

-- ===========================================================================
-- Containers: searched / unlocked
-- ===========================================================================

local function looted_of(c)
    return ue.prop(c, "ContainerLooted") == true
end

local function unlocked_of(c)
    -- BP_LockPickObject children only; nil elsewhere
    local v = ue.prop(c, "IsLocked?")
    if v == nil then return false end
    return v == false
end

-- Receiver: the container as searched here (and its lock picked).
local function apply_loot(c, unlock)
    local changed = false
    if not looted_of(c) then
        ue.set_prop(c, "ContainerLooted", true)
        local comp = ue.prop(c, "BP_JigMultiplayer")
        if ue.valid(comp) then ue.set_prop(comp, "Looted?", true) end
        changed = true
        -- the magnifier: the box's own DistanceOutline (0.5 s timer) drops it
        -- once ContainerLooted is set, but it returns early without a valid
        -- GetPlayerCharacter(0) and its timer is stopped on some paths
        -- (@2543); 0.7.1: a box the client searched kept the host's magnifier.
        -- Drop it now the game's way (Event_MagnifierUI(false) destroys the
        -- widget component, PlayerClose? lets DistanceOutline start over).
        if ue.valid(ue.prop(c, "W_MagnifierUI")) then
            local okm = pcall(function() c:Event_MagnifierUI(false) end)
            if okm then ue.set_prop(c, "PlayerClose?", false) end
            log.debug("world: %s searched elsewhere: its magnifier dropped here (ok=%s)", ue.short(c), tostring(okm))
        end
    end
    if unlock and ue.prop(c, "IsLocked?") == true then
        ue.set_prop(c, "IsLocked?", false)
        changed = true
    end
    return changed
end

-- ---------------------------------------------------------------------------
-- Runtime containers (camps / POIs, caches): named by class and place (CB)
-- ---------------------------------------------------------------------------
-- What decides a search is the container's own ContainerLooted on the machine
-- of the player who presses (OnExecuteInteract -> Event_HoldToInteract @4576:
-- set -> OpenContainer at once; not set -> SearchSound + the HoldToInteract
-- timer, @788 StartRefillTimer). It does not replicate, so a camp chest the
-- host searched stayed unsearched on the client and the other way round. A
-- client's copy is also destroyed when it leaves the network range and comes
-- back fresh (ContainerLooted false): the client keeps the host's word per
-- place (CB.keys) and puts it on every copy that appears there.

function CB.is_key(k) return type(k) == "string" and k:sub(1, 1) == CB.PREFIX end

-- A runtime container this machine names for the others: the host's own (its
-- spawn), on a client only the host's replicated copy (its own leftovers are
-- removed by PF.flush_loot).
function CB.ours(o)
    if not ue.valid(o) or not ue.is_runtime_spawned(o) then return false end
    if S and S.role == "client" and ue.role(o) == ue.ROLE_AUTHORITY then return false end
    return true
end

function CB.key_of(o)
    local l = ue.location(o)
    local cls = ue.class_name(o)
    if not l or cls == "" then return nil end
    return CB.PREFIX .. cls .. CB.PREFIX .. loc_str(l)
end

-- A container as named on the wire: its level path, or @Class@x,y,z.
function CB.id_of(o)
    if level_actor(o) then return path_of(o) end
    if CB.ours(o) then return CB.key_of(o) end
    return nil
end

function CB.parse(k)
    local cls, l = tostring(k):match("^@([%w_]+)@(.+)$")
    local loc = l and parse_loc(l)
    if not loc then return nil end
    return cls, loc
end

-- The container a wire id names here (nil: not here / not yet).
function CB.box_of(id)
    if not CB.is_key(id) then return find(id) end
    local cls, loc = CB.parse(id)
    if not cls then return nil end
    local best, bestd = nil, CB.MATCH * CB.MATCH
    local function consider(o)
        local l = ue.location(o)
        local d = l and d2(l, loc)
        if d and d <= bestd then best, bestd = o, d end
    end
    for p in pairs(CB.live) do
        local o = find(p)
        if not o then
            CB.live[p] = nil
        elseif ue.class_name(o) == cls and CB.ours(o) then
            consider(o)
        end
    end
    -- host: its own containers must be here; one the watch missed (made before
    -- this mod loaded) is searched by its class, at most every 10 s per class
    if not best and is_host() and clock() - (CB.scanned[cls] or -100) >= 10 then
        CB.scanned[cls] = clock()
        for _, o in ipairs(ue.find_all(cls)) do
            if CB.ours(o) then
                local p = path_of(o)
                if p and not CB.live[p] then CB.live[p] = 0 end
                consider(o)
            end
        end
    end
    return best
end

-- Client: the key kept for this place (same class, within MATCH).
function CB.near(cls, loc)
    local b = CB.keys[cls]
    if not b then return nil end
    local best, bestd = nil, CB.MATCH * CB.MATCH
    for k, e in pairs(b) do
        local d = d2(e.loc, loc)
        if d <= bestd then best, bestd = k, d end
    end
    return best
end

-- Client: a place searched (l) / unlocked (u) on the host or here.
function CB.remember(k, l, u)
    local cls, loc = CB.parse(k)
    if not cls then return end
    local old = CB.near(cls, loc)
    local e = old and CB.keys[cls][old]
    if e then
        CB.keys[cls][old] = nil
        CB.nkeys = CB.nkeys - 1
    elseif CB.nkeys >= CB.MAX then
        return
    end
    local b = CB.keys[cls]
    if not b then b = {}; CB.keys[cls] = b end
    b[k] = { loc = loc, l = l or (e and e.l) or false, u = u or (e and e.u) or false }
    CB.nkeys = CB.nkeys + 1
end

-- Client: that place refilled on the host.
function CB.forget(k)
    local cls, loc = CB.parse(k)
    local old = cls and CB.near(cls, loc)
    if old then
        CB.keys[cls][old] = nil
        CB.nkeys = CB.nkeys - 1
    end
end

-- Client: what the host said about this copy's place, put on it (true: changed).
function CB.apply_known(o, why)
    local l, cls = ue.location(o), ue.class_name(o)
    local k = l and CB.near(cls, l)
    if not k then return false end
    local e = CB.keys[cls][k]
    local changed
    if e.l then
        changed = apply_loot(o, e.u)
        local id = CB.key_of(o)
        if id then loot_sent[id] = true end
    elseif e.u and ue.prop(o, "IsLocked?") == true then
        changed = ue.set_prop(o, "IsLocked?", false)
    end
    if changed then
        M.stats.camp_applied = M.stats.camp_applied + 1
        CB.logged = CB.logged + 1
        local line = string.format("world: camp container %s (%s) at %s %s here as on the host (%s)", ue.short(o), cls,
            loc_str(l), e.l and "searched" or "unlocked", why or "")
        if CB.logged <= 40 then log.info("%s", line) else log.debug("%s", line) end
    end
    return changed == true
end

-- Client: every copy here gets what is known about its place (after a snapshot).
function CB.apply_all(why)
    local n = 0
    for p in pairs(CB.live) do
        local o = find(p)
        if not o then
            CB.live[p] = nil
        elseif CB.ours(o) and CB.apply_known(o, why) then
            n = n + 1
        end
    end
    return n
end

-- NotifyOnNewObject (BP_LootContainer, picklock and tool containers): a
-- runtime container made here or arriving from the host. Its name only now
-- (the ~2900 placed boxes of a map load stop at it); looked at by CB.pass.
function CB.on_new(o)
    if not ue.is_runtime_spawned(o) then return end
    local p = raw_path(o)
    if not p or p:find("Default__", 1, true) then return end
    CB.live[p] = clock()
    CB.fresh = true
end

-- Tick: a client's new copies get the host's word about their places once
-- their BeginPlay ran (it may clear ContainerLooted: @657-705); gone ones
-- leave the list every 30 s.
function CB.pass(now)
    if S.role == "client" and CB.fresh then
        CB.fresh = false
        for p, t in pairs(CB.live) do
            if t > 0 then
                if now - t < CB.SETTLE_S then
                    CB.fresh = true
                else
                    CB.live[p] = 0
                    if CB.nkeys > 0 then
                        local o = find(p)
                        if not o then
                            CB.live[p] = nil
                        elseif CB.ours(o) then
                            CB.apply_known(o, "its copy came in range")
                        end
                    end
                end
            end
        end
    end
    if now - CB.prune_at >= 30 then
        CB.prune_at = now
        for p in pairs(CB.live) do
            if not find(p) then CB.live[p] = nil end
        end
    end
end

-- "Mark as storage container" (BP_LootContainer @5886-6924), see WSTORE below.
local OPTION2 = "Jig.InteractOptions.Option2"

local function stored_of(c) return ue.prop(c, "MarkedAsStorageContainer") == true end

-- What the option does besides the UI: the flag and the component's refill.
local function apply_store(c, v)
    if stored_of(c) == v then return false end
    ue.set_prop(c, "MarkedAsStorageContainer", v)
    local comp = ue.prop(c, "BP_JigMultiplayer")
    if ue.valid(comp) then
        if v then
            ue.set_prop(comp, "DoesContainerRefillLoot?", false)
        else
            local ksl = ue.ksl()
            local refill = ksl and ue.try(function() return ksl:GetConsoleVariableBoolValue("Difficulty.Refill") end)
            if refill == true then ue.set_prop(comp, "DoesContainerRefillLoot?", true) end
        end
    end
    return true
end

-- BP_LootContainer / picklock / tool container: OpenContainer (post).
local function on_open_container(c)
    if not on("world_containers") then return end
    local box = c and c:get()
    if not ue.valid(box) or not looted_of(box) then return end
    -- a placed box by its level path, a camp's by its class and place
    local p = CB.id_of(box)
    if not p then return end
    local camp = CB.is_key(p)
    if S.role == "client" then
        if applying > 0 or loot_sent[p] then return end
        loot_sent[p] = true
        -- (kept: this copy may leave the network range and come back unsearched)
        if camp then CB.remember(p, true, unlocked_of(box)) end
        if to_host("WLOOT", pack(p), unlocked_of(box) and "u" or "") then
            M.stats.loot_sent = M.stats.loot_sent + 1
            if camp then
                log.info("world: camp container %s searched here, sent to the host as %s", ue.short(box), p)
            else
                log.debug("world: container %s searched here, sent to the host", ue.short(box))
            end
        end
    elseif is_host() then
        if loot_sent[p] then return end
        loot_sent[p] = true
        Q.looted[p] = true
        to_clients("WLOOT", pack(p), unlocked_of(box) and "u" or "")
        M.stats.loot_sent = M.stats.loot_sent + 1
        if camp then log.info("world: camp container %s searched here, sent to the clients as %s", ue.short(box), p) end
    end
end

-- Host: the container refilled (Difficulty.Refill timer, BP_JigComponent.
-- ProcessRefillContainer -> OnRefillContainer -> Bind_Refill, post). A client's
-- copy runs its own refill timer only for a box that client searched itself
-- (HoldToInteract @788 StartRefillTimer); one the host or a snapshot marked
-- searched there has none and stays "searched" without this. Only such boxes
-- are sent, in batches (WLOOTR), from the next tick on.
local function on_refill(c)
    if not is_host() or not on("world_containers") then return end
    local box = c and c:get()
    local p = CB.id_of(box)
    if not p then return end
    loot_sent[p] = nil
    M.stats.refills = M.stats.refills + 1
    local w = Q.wave
    if not w then
        w = { refilled = 0, queued = 0, skipped = 0, batches = 0, at = clock() }
        Q.wave = w
    end
    w.refilled = w.refilled + 1
    w.last = clock()
    if Q.looted[p] then
        Q.looted[p] = nil
        Q.refill[#Q.refill + 1] = pack(p)
        w.queued = w.queued + 1
    else
        w.skipped = w.skipped + 1
    end
end

local function loot_msg(f, pc)
    if not on("world_containers") then return end
    local p = unpack_path(f[1])
    local flag = f[2] or ""
    local camp = CB.is_key(p)
    -- client: a camp container's place is kept (its copy may not be here, or
    -- may come back unsearched later)
    if camp and S.role == "client" and flag ~= "r" then CB.remember(p, true, flag == "u") end
    local box = CB.box_of(p)
    if not box then
        if S.role == "client" and flag ~= "r" and not camp then later("loot", p, flag) end
        if camp and is_host() then
            M.stats.camp_missing = M.stats.camp_missing + 1
            if M.stats.camp_missing <= 20 then
                log.warn("world: camp container %s searched by %s is not here (no such container within %.1f m)", p,
                    ue.short(pc), CB.MATCH / 100)
            end
        end
        return
    end
    if flag == "r" then
        if S.role == "client" then Q.cref_add(p) end
        return
    end
    -- a camp container: this machine's own name for it from now on
    local id = camp and CB.key_of(box) or p
    loot_sent[p] = true
    loot_sent[id] = true
    local changed = apply_loot(box, flag == "u")
    if changed then M.stats.loot_applied = M.stats.loot_applied + 1 end
    if camp and changed and S.role == "client" then
        M.stats.camp_applied = M.stats.camp_applied + 1
        log.info("world: camp container %s searched on the host: searched here too", ue.short(box))
    end
    if is_host() then
        Q.looted[id] = true
        -- the searching client started its refill timer on its own copy; the
        -- host's copy (the one with the real contents) does it here
        if changed then
            local comp = ue.prop(box, "BP_JigMultiplayer")
            if ue.valid(comp) then pcall(function() comp:StartRefillTimer(false) end) end
            log.info("world: %s searched by %s%s", ue.short(box), ue.short(pc), camp and (" (camp container " .. id .. ")") or "")
        end
        to_others(pc, "WLOOT", pack(id), flag)
    end
end

local LOOT_CLASSES = { "BP_LootContainer_C", "BP_MASTER_PicklockContainer_C", "BP_MASTER_ToolRequiredContainer_C" }

local function snapshot_loot(pc)
    local items = {}
    for i, cls in ipairs(LOOT_CLASSES) do
        local picklock = i == 2
        for _, box in ipairs(ue.find_all(cls)) do
            -- ContainerLooted first: most of the ~2900 boxes stop there
            local l = looted_of(box)
            local u = picklock and unlocked_of(box)
            if l or u then
                -- placed: its path; a camp's (runtime): @Class@x,y,z
                local p = CB.id_of(box)
                local st = l and stored_of(box)
                if p then
                    items[#items + 1] = pack(p) .. (u and "!u" or "") .. (l and "" or "!n") .. (st and "!s" or "")
                    if l then Q.looted[p] = true end
                end
            end
        end
    end
    send_list(pc, "WLOOTS", items)
    return #items
end

local function loots_msg(f)
    if S.role ~= "client" or not on("world_containers") then return end
    local n, miss, camps = 0, 0, 0
    for _, it in ipairs(split(f[1], ";")) do
        local p, flags = it:match("^([^!]+)(.*)$")
        p = unpack_path(p)
        flags = flags or ""
        local unlock = flags:find("!u", 1, true) ~= nil
        local looted = flags:find("!n", 1, true) == nil
        if CB.is_key(p) then
            -- a camp container: its place kept; the copies here get it after the list
            CB.remember(p, looted, unlock)
            camps = camps + 1
        else
            local box = find(p)
            if box then
                if looted then
                    loot_sent[p] = true
                    if apply_loot(box, unlock) then n = n + 1 end
                    if flags:find("!s", 1, true) then apply_store(box, true) end
                elseif unlock and ue.prop(box, "IsLocked?") == true then
                    ue.set_prop(box, "IsLocked?", false)
                    n = n + 1
                end
            else
                miss = miss + 1
                later("loot", p, unlock and "u" or "")
            end
        end
    end
    local camp_n = camps > 0 and CB.apply_all("the host's list") or 0
    M.stats.loot_applied = M.stats.loot_applied + n
    log.info("world: host's searched containers: %d applied here, %d not found yet; camp containers: %d, %d of them here now",
        n, miss, camps, camp_n)
end

-- ===========================================================================
-- Containers: "Mark as storage container" (BP_LootContainer @5886-6924)
-- ===========================================================================
-- The option runs where the key was pressed: on a client only the client's
-- copy stopped refilling, and the host's copy (Difficulty.Refill) cleared the
-- stored items at the next refill and saved the container unmarked.

-- BP_LootContainer.OnExecuteInteract (post): Option2 toggled the mark here.
local function on_interact_container(c, _, opt_p)
    if not on("world_containers") or applying > 0 then return end
    local box = c and c:get()
    if not level_actor(box) or not looted_of(box) then return end
    local tag = ue.try(function() return ue.str(opt_p:get().TagName) end)
    if tag ~= OPTION2 then return end
    local p = path_of(box)
    if not p then return end
    local v = stored_of(box) and "1" or "0"
    if S.role == "client" then
        if to_host("WSTORE", pack(p), v) then M.stats.store_sent = M.stats.store_sent + 1 end
    elseif is_host() then
        to_clients("WSTORE", pack(p), v)
        M.stats.store_sent = M.stats.store_sent + 1
    end
    log.info("world: %s marked as %s container here", ue.short(box), v == "1" and "storage" or "loot")
end

local function store_msg(f, pc)
    if not on("world_containers") then return end
    local p = unpack_path(f[1])
    local v = f[2] == "1"
    local box = find(p)
    if not box then return end
    if apply_store(box, v) then M.stats.store_applied = M.stats.store_applied + 1 end
    if is_host() then
        log.info("world: %s marked as %s container by %s", ue.short(box), v and "storage" or "loot", ue.short(pc))
        to_others(pc, "WSTORE", pack(p), f[2])
    end
end

-- ===========================================================================
-- Looting noise (client -> host: AI hearing, sound for everyone)
-- ===========================================================================

local function play_break_open(c)
    if not ue.valid(cache.cue) then cache.cue = load_object(PATH.BREAK_OPEN_CUE) end
    local gps = ue.gameplay_statics()
    local l = ue.location(c)
    if not cache.cue or not gps or not l then return end
    pcall(function()
        gps:PlaySoundAtLocation(c, cache.cue, l, { Pitch = 0, Yaw = 0, Roll = 0 }, 0.5, 1.0, 0.0, nil, nil, nil, nil)
    end)
end

-- <container>.PauseInteract (post): only NoiseEvent's noise branch calls it.
local function on_loot_noise(c)
    if not on("world_loot_noise") or applying > 0 then return end
    local box = c and c:get()
    -- (a camp's container by its class and place, like WLOOT)
    local p = CB.id_of(box)
    if not p then return end
    if S.role == "client" then
        if to_host("WNOISE", pack(p)) then M.stats.noise_sent = M.stats.noise_sent + 1 end
    elseif is_host() then
        -- the host's own noisy search: its sound on the clients that can hear
        -- it (BreakOpen_Cue: the Radio attenuation, 600 + 2500 cm = 31 m, + 5 m)
        local snd = package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
        local range = snd.range_of_path(PATH.BREAK_OPEN_CUE, 3100)
        local near, far = snd.pcs_near(remote_pcs(), ue.location(box), range)
        for _, pc in ipairs(near) do Q.send(pc, "WNOISE", pack(p)) end
        if far > 0 then log.debug("world: noise of %s not sent to %d client(s) beyond %.0f m", ue.short(box), far, range / 100) end
    end
end

local function noise_msg(f, pc)
    if not on("world_loot_noise") then return end
    local p = unpack_path(f[1])
    local box = CB.box_of(p)
    if not box then return end
    play_break_open(box)
    if not is_host() then return end
    -- NoiseEvent @488-542: ReportNoiseEvent(self, location, 1, player, 3000, 'Noise')
    local pawn = ue.pawn_of(pc)
    local hearing = ue.find_object(PATH.HEARING)
    local l = ue.location(box)
    if hearing and pawn and l then
        local ok, err = pcall(function() hearing:ReportNoiseEvent(box, l, 1.0, pawn, 3000.0, FName("Noise")) end)
        if not ok then log.err_throttled("world.noise", "world: loot noise: %s", tostring(err)) end
    end
    M.stats.noise_host = M.stats.noise_host + 1
    if M.stats.noise_host <= 3 then log.info("world: %s made noise searching %s (zombies hear it)", ue.short(pawn), ue.short(box)) end
    -- the sound to the other clients that can hear it (BreakOpen_Cue 31 m + 5 m)
    local snd = package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
    local range = snd.range_of_path(PATH.BREAK_OPEN_CUE, 3100)
    local near, far = snd.pcs_near(remote_pcs(), l, range, pc)
    for _, other in ipairs(near) do Q.send(other, "WNOISE", pack(p)) end
    if far > 0 then log.debug("world: noise of %s not sent to %d client(s) beyond %.0f m", ue.short(box), far, range / 100) end
end

-- ===========================================================================
-- Doors that do not replicate: BP_LockedDoor, laboratory sliding doors
-- ===========================================================================

-- What a BP_LockedDoor is doing: "o" opening/open, "c" closing/closed.
local function locked_door_target(d)
    local tl = ue.prop(d, "Timeline_OpenDoor")
    local playing = ue.valid(tl) and ue.try(function() return tl:IsPlaying() end) == true
    if playing then
        return num(ue.prop(d, LD_DIR), 0) == 0 and "o" or "c"
    end
    return ue.prop(d, "Closed?") == false and "o" or "c"
end

local function door_kind(d)
    local c = short_class(d)
    if c:find("^BP_LockedDoor") then return "locked" end
    if c:find("^BP_LaboratorySlidingDoor") then return "lab" end
    return nil
end

-- post-hook of a door event (ev: d = Event_Door, b = EventDoorBehind, a = Event_AutoDoor)
local function on_door(c, ev)
    if not on("world_doors") then return end
    local d = c and c:get()
    if not level_actor(d) then return end
    if S.role == "client" and applying > 0 then return end
    local p = path_of(d)
    if not p then return end
    local want = (ev == "d") and locked_door_target(d) or "o"
    local unlocked = ue.prop(d, "IsLocked?") == false and "u" or ""
    if S.role == "client" then
        if to_host("WDOOR", pack(p), ev, want, unlocked) then M.stats.doors_sent = M.stats.doors_sent + 1 end
    elseif is_host() then
        door_state[p] = { ev = ev, want = want, unlocked = unlocked }
        to_clients("WDOOR", pack(p), ev, want, unlocked)
        M.stats.doors_sent = M.stats.doors_sent + 1
    end
end

local function apply_door(d, ev, want, unlocked)
    local k = door_kind(d)
    local did = false
    if k == "locked" then
        if ev == "b" then
            if locked_door_target(d) == "c" then did = apply(function() d:EventDoorBehind() end) end
        elseif locked_door_target(d) ~= want then
            did = apply(function() d:Event_Door() end)
        end
        if unlocked == "u" and ue.prop(d, "IsLocked?") == true then ue.set_prop(d, "IsLocked?", false) end
    elseif k == "lab" then
        if ue.prop(d, "IsClosed") == true then did = apply(function() d:Event_AutoDoor() end) end
    end
    return did
end

local function door_msg(f, pc)
    if not on("world_doors") then return end
    local p = unpack_path(f[1])
    local ev, want, unlocked = f[2] or "d", f[3] or "o", f[4] or ""
    local d = find(p)
    if not d then
        if S.role == "client" then later("door", p, { ev, want, unlocked }) end
        return
    end
    if apply_door(d, ev, want, unlocked) then
        M.stats.doors_applied = M.stats.doors_applied + 1
        log.debug("world: door %s %s/%s applied", ue.short(d), ev, want)
    end
    if is_host() then
        door_state[p] = { ev = ev, want = want, unlocked = unlocked }
        -- the post-hook already told everyone when the host's door moved;
        -- unlocking alone does not move it
        to_others(pc, "WDOOR", pack(p), ev, want, unlocked)
    end
end

local function snapshot_doors(pc)
    local n = 0
    for _, d in ipairs(ue.find_all("BP_LockedDoor_C")) do
        if level_actor(d) then
            local open = locked_door_target(d) == "o"
            local unl = ue.prop(d, "IsLocked?") == false
            if open or unl then
                local p = path_of(d)
                if p then
                    Q.send(pc, "WDOOR", pack(p), "d", open and "o" or "c", unl and "u" or "")
                    n = n + 1
                end
            end
        end
    end
    -- replicated doors: their state variable
    for _, rd in ipairs(RDOORS) do
        for _, d in ipairs(ue.find_all(rd[2])) do
            if level_actor(d) then
                local v = ue.prop(d, rd[3])
                local p = path_of(d)
                if p and type(v) == "boolean" then
                    Q.send(pc, "WRDOOR", pack(p), v and "1" or "0")
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Replicated doors: reconcile a client that missed the multicast
-- ---------------------------------------------------------------------------

local function rdoor_var(d)
    local c = short_class(d)
    local v = RDOOR_VAR[c]
    if v then return v end
    for _, rd in ipairs(RDOORS) do
        local base = rd[2]:gsub("_C$", "")
        if c:sub(1, #base) == base then return rd[3] end
    end
    return nil
end

-- Host: MC_OpenDoor (post) -> the settled state a moment later.
local function on_rdoor(c, actor_p)
    if not is_host() or not on("world_doors") then return end
    local d = c and c:get()
    if not level_actor(d) then return end
    local p = path_of(d)
    if not p then return end
    LK.on_kdoor_mc(d, actor_p)
    ue.delay("world-rdoor", RDOOR_SETTLE_MS, function()
        local dd = find(p)
        local var = dd and rdoor_var(dd)
        if not var then return end
        local v = ue.prop(dd, var)
        if type(v) == "boolean" then to_clients("WRDOOR", pack(p), v and "1" or "0") end
    end)
end

local function rdoor_check(p, want, second)
    local d = find(p)
    local var = d and rdoor_var(d)
    if not var then return end
    local v = ue.prop(d, var)
    if type(v) ~= "boolean" or v == want then return end
    if not second then
        -- the multicast may still be playing here: look again
        ue.delay("world-rdoor2", RDOOR_CHECK_MS, function() rdoor_check(p, want, true) end)
        return
    end
    local last = rdoor_toggled[p]
    if last and clock() - last < 8 then return end
    rdoor_toggled[p] = clock()
    -- the door's own toggle, as the multicast runs it (Actor None: no
    -- montage). A keycard / hangar door's opening checks the card of that Actor
    -- (none: nothing happened, 0.6.61): its step after the check (Event_OpenDoor
    -- @70, hangar @1436).
    local ok
    local card = want == true and PW.is_card_door(d)
    if card then
        ok = PW.tl(d, "Timeline_OpenDoor", "PlayFromStart")
    else
        ok = apply(function() d:MC_OpenDoor(nil) end)
    end
    if ok then
        M.stats.rdoors_fixed = M.stats.rdoors_fixed + 1
        log.info("world: door %s was %s here, %s like on the host", ue.short(d), tostring(v), card and "opened" or "toggled")
    end
end

local function rdoor_msg(f)
    if S.role ~= "client" or not on("world_doors") then return end
    local p = unpack_path(f[1])
    local want = f[2] == "1"
    if not find(p) then later("rdoor", p, want) return end
    ue.delay("world-rdoor1", RDOOR_CHECK_MS, function() rdoor_check(p, want, false) end)
end

-- ===========================================================================
-- Power, the laboratory and bunker puzzle, sirens, radios (world_doors)
-- ===========================================================================
-- None of these actors replicates (BP_MasterObject / BP_LaboratoryMaster
-- children without bReplicates; their REPL variables never leave a machine)
-- and none is saved by the game (no EMSActorSaveInterface: single player
-- starts them over at every load). A press (OnExecuteInteract, from
-- BP_JigHelperComp on the presser's machine only) changed that machine alone.
-- The chain (work\re):
--   BP_PowerGenerator.Event_TurnOn (no gas: Event_AddGas consumes DA_GasCan;
--     first start: RequiredItem found and, ConsumeItemOnUse?, consumed) ->
--     Actors.SetPower_TurnedOn (BPI_WorldObjectPower): BP_Lever.PoweredOn,
--     the police garage door's Powered? ...
--   BP_Lever.OnExecuteInteract (PoweredOn) -> Actors.CallInteractOnObject:
--     BP_DoubleBunkerDoor / BP_LargeBunkerEntrance toggle (DoorTimeline, Open?)
--   BP_BunkerScanner: server interact -> MC_CallInteract (host only: the
--     actor does not replicate) -> FindKeycard -> Unlocked? -> ListeningActor
--     .CallInteractOnObject (the bunker doors)
--   BP_LaboratoryGenerator.Event_TurnOn -> Actors.SetPower_TurnedOn /
--     SetPower_Warning: light switches (On? / Warning?), sliding doors
--     (Unlocked / Warning), cables ... (+ the quest task PowerOnGenerator)
--   BP_LaboratoryCircuitBox.Event_Door: its door, then its levers (TL_Levers)
--     -> Doors.Unlocked + OnRep_Unlocked, LightSwitches.Event_LightSwitch
--     (Damage_Object instead when DamageToActivate?)
--   BP_LaboratoryLightSwitch.Event_LightSwitch: Lights.LightOn? + OnRep,
--     linked Switches On? / Off? + OnRep
--   BP_LaboratorySlidingDoor / BP_LaboratorySecureDoors.Event_Door: keycard
--     (DA_AllAccessKeycard found, or Keycard consumed) -> unlock, XP once, open
--   BP_LaboratoryEntranceDoors.Event_Door, BP_LaboratoryStairwellLightSwitch
--   BP_Siren (Activate / DeactivateSiren: AI noise every 2.5 s; a random
--     timer per machine), BP_Radio (Audio volume 0 / 0.5)
-- Inventory checks: FindJigItemByDA reads the inventory WIDGETS
-- (LocalJSIContainers: only the owner's machine has them), the consuming
-- ServerFindThenConsumeByItemID reads MainJigContainers (only the host has
-- them): a client passes the first only, the host the second only.
-- Here: one shared state, the host's.
--   * Each tracked object has a state string (its variables; doors and the
--     lever by their timeline: where it is going). The host sends every change
--     (WPWS|path=state;...) through the queue: right after a press, 3 s later
--     (timelines, the circuit box's levers) and from an idle pass over all of
--     them every 5 s. A client sets each object with the object's own
--     functions (Event_TurnOn, CallInteractOnObject, Event_Door, the REPL
--     variable + its OnRep, the timelines) and looks again 3, 8 and 15 s later.
--   * A client's press runs on the client as the game does; its result goes
--     to the host (WPSTEP|path|state), which runs the game's own function for
--     that object (Event_TurnOn, the lever's OnExecuteInteract, ...) and sends
--     the result to everyone.
--   * What the client's machine cannot do (consume a gas can, the generator's
--     item, a keycard) or the host cannot see (an all-access keycard in a
--     client's widgets) is asked of the host (WPTRY): it consumes from that
--     player's inventory with the game's ServerFindThenConsumeByItemID and runs
--     the step; the client's own false note ("No Gas Can In Inventory", "No
--     Keycard Available") is removed, the host's answer comes as the game's
--     note (WPNOTE), the door's XP as in single player (WPXP).
--   * Join: the host's objects that differ from the level's start.
--   * The host's save: those states go to <slot>_SDCoop_World.txt next to the
--     slot on every save of the game and come back when the world is loaded.

PW.PATHS = {
    pgen = "/Game/Blueprints/Other/Power/BP_PowerGenerator.BP_PowerGenerator_C",
    lgen = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryGenerator.BP_LaboratoryGenerator_C",
    lever = "/Game/Blueprints/Other/Power/BP_Lever.BP_Lever_C",
    cbox = "/Game/Blueprints/Laboratory/Blueprints/BP_LaboratoryCircuitBox.BP_LaboratoryCircuitBox_C",
    sw = "/Game/Blueprints/Laboratory/Blueprints/Lights/BP_LaboratoryLightSwitch.BP_LaboratoryLightSwitch_C",
    ssw = "/Game/Blueprints/Laboratory/Blueprints/Lights/Stairwell/BP_LaboratoryStairwellLightSwitch.BP_LaboratoryStairwellLightSwitch_C",
    sdoor = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySlidingDoor.BP_LaboratorySlidingDoor_C",
    secure = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySecureDoors.BP_LaboratorySecureDoors_C",
    entr = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratoryEntranceDoors.BP_LaboratoryEntranceDoors_C",
    scan = "/Game/Blueprints/Bunker/BP_BunkerScanner.BP_BunkerScanner_C",
    siren = "/Game/Blueprints/Other/Objects/BP_Siren.BP_Siren_C",
    radio = "/Game/Blueprints/Other/Radio/BP_Radio.BP_Radio_C",
    kdoor = "/Game/Blueprints/Other/Doors/BP_KeycardDoor.BP_KeycardDoor_C",
    hangar = "/Game/Blueprints/Other/Doors/BP_HangarDoor.BP_HangarDoor_C",
    nuke = "/Game/Blueprints/Other/EasterEggs/BP_EasterEgg_Nuke.BP_EasterEgg_Nuke_C",
    save = "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot",
    delete = "/Script/EasyMultiSave.EMSFunctionLibrary:DeleteAllSaveDataForSlot",
    allaccess = "/Game/Inventory/Items/DataAssets/Keycards/DA_AllAccessKeycard.DA_AllAccessKeycard",
    gascan = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Vehicle/DA_GasCan.DA_GasCan",
    green = "/Game/Meshes/Materials/M_EmissiveColour_Green.M_EmissiveColour_Green",
    red = "/Game/Meshes/Materials/M_EmissiveColour_Red.M_EmissiveColour_Red",
    gfl = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C",
}
-- FindAllOf per class (BP_LaboratoryMaster_C: every laboratory class at once)
PW.FIND = { "BP_LaboratoryMaster_C", "BP_PowerGenerator_C", "BP_Lever_C", "BP_BunkerScanner_C",
    "BP_DoubleBunkerDoor_C", "BP_LargeBunkerEntrance_C", "BP_Siren_C", "BP_Radio_C" }
PW.NOTE_MSG = "Message_6_EED8ECA340EFC5752E4CA6B7B32FABBE"   -- S_NotificationDetails.Message
PW.FILE_TAG = "_SDCoop_World.txt"
PW.dir = nil   -- tests: the folder of the state files (else the game's SaveGames)

function PW.b01(v) return v == true and "1" or "0" end

-- A timeline: "f" playing forward, "r" in reverse, nil not playing / none.
function PW.tl_play(o, name)
    local tl = ue.prop(o, name)
    if not ue.valid(tl) or ue.try(function() return tl:IsPlaying() end) ~= true then return nil end
    return ue.try(function() return tl:IsReversing() end) == true and "r" or "f"
end

-- Where a timeline is going: true forward (opening, pulled), false back.
function PW.tl_fwd(o, name)
    local tl = ue.prop(o, name)
    if not ue.valid(tl) then return nil end
    local p = PW.tl_play(o, name)
    if p then return p == "f" end
    return (tonumber(ue.try(function() return tl:GetPlaybackPosition() end)) or 0) > 0.001
end

function PW.tl(o, name, how)
    local tl = ue.prop(o, name)
    if not ue.valid(tl) then return false end
    return apply(function() tl[how](tl) end)
end

-- A Blueprint function by name (names with '?' too), as this module's call.
function PW.call(o, fname, ...)
    local args = table.pack(...)
    return apply(function()
        local f = o[fname]
        f(o, table.unpack(args, 1, args.n))
    end)
end

function PW.setrep(o, var, v, onrep)
    ue.set_prop(o, var, v)
    if onrep then PW.call(o, onrep) end
end

-- sdc_notes (the game's notices to the player they are for), when loaded.
function PW.notes()
    local n = package.loaded["sdc_notes"]
    return type(n) == "table" and n or nil
end

-- A keycard-checking replicated door (BP_KeycardDoor and children,
-- BP_HangarDoor): Event_OpenDoor checks the card of its Actor, XP @3219 / @2499.
function PW.is_card_door(o)
    local c = ue.class_name(o)
    return c:find("^BP_KeycardDoor") ~= nil or c:find("^BP_HangarDoor") ~= nil
end

function PW.option1() return { TagName = FName("Jig.InteractOptions.Option1") } end

-- name, apply order, { classes, state(o), set(o, want, pawn), step(o, want, pawn)? }
function PW.kind_def(name, order, spec)
    spec.name, spec.order = name, order
    PW.K[name] = spec
    PW.kinds[#PW.kinds + 1] = name
    for _, c in ipairs(spec.classes) do PW.cls_kind[c] = name end
end

-- generator: TurnedOn? GasAdded? ItemUsed?
PW.kind_def("pgen", 1, {
    classes = { "BP_PowerGenerator_C" },
    state = function(o)
        return PW.b01(ue.prop(o, "TurnedOn?")) .. PW.b01(ue.prop(o, "GasAdded?")) .. PW.b01(ue.prop(o, "ItemUsed?"))
    end,
    -- Event_TurnOn toggles (@1389 off, @1928-2362 on). On there means its gas
    -- and its item were there: set first, so its checks pass here.
    set = function(o, want, pawn)
        local t = want:sub(1, 1) == "1"
        if t or want:sub(2, 2) == "1" then ue.set_prop(o, "GasAdded?", true) end
        if want:sub(3, 3) == "1" or (t and ue.prop(o, "RequiredItemToPowerOn?") == true) then
            ue.set_prop(o, "ItemUsed?", true)
        end
        if (ue.prop(o, "TurnedOn?") == true) ~= t then PW.call(o, "Event_TurnOn", pawn) end
    end,
})
-- laboratory generator: TurnedOn? (Event_TurnOn toggles)
PW.kind_def("lgen", 2, {
    classes = { "BP_LaboratoryGenerator_C" },
    state = function(o) return PW.b01(ue.prop(o, "TurnedOn?")) end,
    set = function(o, want, pawn)
        if (ue.prop(o, "TurnedOn?") == true) ~= (want == "1") then PW.call(o, "Event_TurnOn", pawn) end
    end,
})
-- bunker scanner: Unlocked? KeycardRequired?
PW.kind_def("scan", 3, {
    classes = { "BP_BunkerScanner_C" },
    state = function(o) return PW.b01(ue.prop(o, "Unlocked?")) .. PW.b01(ue.prop(o, "KeycardRequired?")) end,
    -- its variables and its light (MC_CallInteract @1551-1630); the doors it
    -- opened come with their own state
    set = function(o, want)
        local u = want:sub(1, 1) == "1"
        ue.set_prop(o, "Unlocked?", u)
        ue.set_prop(o, "KeycardRequired?", want:sub(2, 2) == "1")
        local m = ue.loaded_asset(u and PW.PATHS.green or PW.PATHS.red, "world")
        local sc = ue.prop(o, "Scanner")
        if m and ue.valid(sc) then apply(function() sc:SetMaterial(1, m) end) end
    end,
    no_step = true,   -- a press goes to the host by the game's own server path
})
-- lever: PoweredOn, pulled (LeverMovement)
PW.kind_def("lever", 4, {
    classes = { "BP_Lever_C" },
    state = function(o) return PW.b01(ue.prop(o, "PoweredOn")) .. PW.b01(PW.tl_fwd(o, "LeverMovement")) end,
    -- client: its power and its handle (the doors come with their own state)
    set = function(o, want)
        local p = want:sub(1, 1) == "1"
        if (ue.prop(o, "PoweredOn") == true) ~= p then PW.call(o, "SetPower_TurnedOn", p) end
        local l = want:sub(2, 2) == "1"
        if PW.tl_fwd(o, "LeverMovement") ~= l then PW.tl(o, "LeverMovement", l and "PlayFromStart" or "Reverse") end
    end,
    -- host: a client pulled it: the game's pull (@1400: its doors toggle)
    step = function(o, want, pawn)
        if ue.prop(o, "PoweredOn") ~= true then return end
        if (want:sub(2, 2) == "1") ~= (PW.tl_fwd(o, "LeverMovement") == true) then
            PW.call(o, "OnExecuteInteract", pawn, PW.option1())
        end
    end,
})
-- circuit box: 0 closed, 1 its door open, 2 levers pulled / shot (done)
PW.kind_def("cbox", 5, {
    classes = { "BP_LaboratoryCircuitBox_C" },
    state = function(o)
        if ue.prop(o, "CanInteract?") ~= true or PW.tl_fwd(o, "TL_Levers") == true then return "2" end
        return ue.prop(o, "DoorClosed?") == true and "0" or "1"
    end,
    set = function(o, want, pawn)
        local s = PW.K.cbox.state(o)
        if s >= want then return end
        if ue.prop(o, "DamageToActivate?") == true then
            if want == "2" then PW.call(o, "Damage_Object", 1.0, pawn, nil) end
            return
        end
        -- Event_Door: the box's door (@3982), then its levers (@3028)
        if s == "0" then PW.call(o, "Event_Door"); s = "1" end
        if want == "2" and s == "1" then PW.call(o, "Event_Door") end
    end,
})
-- light switch: 1 on, 0 off, w warning, - none (REPL variables + OnRep)
PW.kind_def("sw", 6, {
    classes = { "BP_LaboratoryLightSwitch_C" },
    state = function(o)
        if ue.prop(o, "On?") == true then return "1" end
        if ue.prop(o, "Off?") == true then return "0" end
        if ue.prop(o, "Warning?") == true then return "w" end
        return "-"
    end,
    set = function(o, want)
        if want == "1" then PW.setrep(o, "On?", true, "OnRep_On?")
        elseif want == "0" then PW.setrep(o, "Off?", true, "OnRep_Off?")
        elseif want == "w" then PW.setrep(o, "Warning?", true, "OnRep_Warning?")
        else
            ue.set_prop(o, "On?", false); ue.set_prop(o, "Off?", false); ue.set_prop(o, "Warning?", false)
        end
    end,
    -- host: a client switched it: the game's switch (its lights, its linked switches)
    step = function(o, want)
        local s = PW.K.sw.state(o)
        if s ~= want and s ~= "w" then PW.call(o, "Event_LightSwitch") end
        if PW.K.sw.state(o) ~= want then PW.K.sw.set(o, want) end
    end,
})
-- stairwell switch: its first light lit (Event_LightSwitch toggles each light)
PW.kind_def("ssw", 7, {
    classes = { "BP_LaboratoryStairwellLightSwitch_C" },
    state = function(o)
        local lights = ue.prop(o, "Lights")
        local l = lights and ue.try(function() return lights[1] end)
        if l ~= nil and not ue.valid(l) then l = ue.try(function() return l:get() end) end
        local i = tonumber(ue.prop(ue.prop(l, "PointLight"), "Intensity")) or 0
        return i > 0 and "1" or "0"
    end,
    set = function(o, want)
        if PW.K.ssw.state(o) ~= want then PW.call(o, "Event_LightSwitch") end
    end,
})
-- laboratory light: LightOn? (REPL + OnRep)
PW.kind_def("light", 8, {
    classes = { "BP_LaboratoryLight_C" },
    state = function(o) return PW.b01(ue.prop(o, "LightOn?")) end,
    set = function(o, want) PW.setrep(o, "LightOn?", want == "1", "OnRep_LightOn?") end,
})
-- sliding door: lock (u / l / w / -), keycard opening (TL_DoorsKeycard), XPGiven?
PW.kind_def("sdoor", 9, {
    classes = { "BP_LaboratorySlidingDoor_C" },
    state = function(o)
        local lock = (ue.prop(o, "Unlocked") == true and "u") or (ue.prop(o, "Locked") == true and "l")
            or (ue.prop(o, "Warning") == true and "w") or "-"
        return lock .. (PW.tl_fwd(o, "TL_DoorsKeycard") and "o" or "c") .. PW.b01(ue.prop(o, "XPGiven?"))
    end,
    set = function(o, want)
        local lock, open = want:sub(1, 1), want:sub(2, 2) == "o"
        if want:sub(3, 3) == "1" then ue.set_prop(o, "XPGiven?", true) end
        if PW.K.sdoor.state(o):sub(1, 1) ~= lock then
            -- (each OnRep clears the other two, @286 / @272 / @300)
            if lock == "u" then PW.setrep(o, "Unlocked", true, "OnRep_Unlocked")
            elseif lock == "l" then PW.setrep(o, "Locked", true, "OnRep_Locked")
            elseif lock == "w" then PW.setrep(o, "Warning", true, "OnRep_Warning")
            else
                ue.set_prop(o, "Unlocked", false); ue.set_prop(o, "Locked", false); ue.set_prop(o, "Warning", false)
            end
        end
        -- Event_Door @575 / @689: the keycard timeline
        if (PW.tl_fwd(o, "TL_DoorsKeycard") == true) ~= open then
            PW.tl(o, "TL_DoorsKeycard", open and "Play" or "Reverse")
        end
    end,
})
-- secure doors: Unlocked, open, XPGiven?
PW.kind_def("secure", 10, {
    classes = { "BP_LaboratorySecureDoors_C" },
    state = function(o)
        -- closing: TL_MechanismReverse, then TL_Doors back (IsClosed at its end, @97)
        local closing = PW.tl_play(o, "TL_MechanismReverse") ~= nil or PW.tl_play(o, "TL_Doors") == "r"
        local open = ue.prop(o, "IsClosed") ~= true and not closing
        return PW.b01(ue.prop(o, "Unlocked")) .. PW.b01(open) .. PW.b01(ue.prop(o, "XPGiven?"))
    end,
    set = function(o, want)
        if want:sub(1, 1) == "1" then ue.set_prop(o, "Unlocked", true) end
        if want:sub(3, 3) == "1" then ue.set_prop(o, "XPGiven?", true) end
        local open = want:sub(2, 2) == "1"
        local cur = PW.K.secure.state(o):sub(2, 2) == "1"
        if open and not cur then
            -- Event_Door after its keycard check (@2115-2304, @113)
            ue.set_prop(o, "Unlocked", true)
            ue.set_prop(o, "IsClosed", false)
            PW.tl(o, "TL_Mechanism", "Play")
        elseif cur and not open then
            PW.tl(o, "TL_MechanismReverse", "Play")   -- @2320
        end
    end,
})
-- laboratory entrance doors: open (Timeline; Event_Door toggles)
PW.kind_def("entr", 11, {
    classes = { "BP_LaboratoryEntranceDoors_C" },
    state = function(o) return PW.tl_fwd(o, "Timeline") and "o" or "c" end,
    set = function(o, want)
        if PW.K.entr.state(o) ~= want then PW.call(o, "Event_Door") end
    end,
})
-- bunker doors: open (DoorTimeline; CallInteractOnObject toggles)
PW.kind_def("bunker", 12, {
    classes = { "BP_DoubleBunkerDoor_C", "BP_LargeBunkerEntrance_C" },
    state = function(o) return PW.tl_fwd(o, "DoorTimeline") and "o" or "c" end,
    set = function(o, want)
        if PW.K.bunker.state(o) ~= want then PW.call(o, "CallInteractOnObject") end
    end,
})
-- siren: Playing
PW.kind_def("siren", 13, {
    classes = { "BP_Siren_C" },
    state = function(o) return PW.b01(ue.prop(o, "Playing")) end,
    set = function(o, want)
        local on_ = want == "1"
        if (ue.prop(o, "Playing") == true) ~= on_ then PW.call(o, on_ and "ActivateSiren" or "DeactivateSiren") end
    end,
})
-- radio: playing (its volume: OnExecuteInteract @514-659 sets 0.5 / 0)
PW.kind_def("radio", 14, {
    classes = { "BP_Radio_C" },
    state = function(o)
        return (tonumber(ue.prop(ue.prop(o, "Audio"), "VolumeMultiplier")) or 0) > 0 and "1" or "0"
    end,
    set = function(o, want)
        local a = ue.prop(o, "Audio")
        if ue.valid(a) then apply(function() a:SetVolumeMultiplier(want == "1" and 0.5 or 0.0) end) end
    end,
})

-- The kind of an object: its class, or the longest tracked class it starts
-- with (BP_LaboratoryLight2_C, BP_LargeBunkerEntrance_Small_C).
function PW.kind_of(o)
    local c = ue.class_name(o)
    local k = PW.cls_kind[c]
    if k ~= nil then return k or nil end
    local best, blen = false, 0
    for cls, kind in pairs(PW.cls_kind) do
        local base = cls:gsub("_C$", "")
        if kind and #base > blen and c:sub(1, #base) == base then best, blen = kind, #base end
    end
    PW.cls_kind[c] = best
    return best or nil
end

-- Host: the world's tracked objects, one FindAllOf per tick.
function PW.build_step()
    if not PW.todo then PW.todo, PW.found, PW.idx = { table.unpack(PW.FIND) }, {}, {} end
    local cls = table.remove(PW.todo, 1)
    if cls then
        for _, a in ipairs(ue.find_all(cls)) do
            local k = level_actor(a) and PW.kind_of(a)
            local p = k and path_of(a)
            if p and not PW.idx[p] then
                local e = { p = p, k = k, o = a }
                PW.found[#PW.found + 1] = e
                PW.idx[p] = e
            end
        end
        if #PW.todo > 0 then return false end
    end
    table.sort(PW.found, function(a, b)
        local oa, ob = PW.K[a.k].order, PW.K[b.k].order
        if oa ~= ob then return oa < ob end
        return a.p < b.p
    end)
    PW.objs, PW.found, PW.todo = PW.found, nil, nil
    return true
end

function PW.obj(e)
    if ue.valid(e.o) then return e.o end
    e.o = find(e.p)
    return e.o
end

function PW.state_of(e)
    local o = PW.obj(e)
    if not o then return nil end
    local ok, s = pcall(PW.K[e.k].state, o)
    return ok and s or nil
end

-- Host: the given objects' states -> the changed ones to every client.
function PW.pass(entries)
    local items = {}
    for _, e in ipairs(entries) do
        local s = PW.state_of(e)
        if s and PW.sent[e.p] ~= s then
            PW.sent[e.p] = s
            items[#items + 1] = pack(e.p) .. "=" .. s
        end
    end
    if #items == 0 then return 0 end
    local batches = Q.batches(items)
    for _, pc in ipairs(remote_pcs()) do
        for _, b in ipairs(batches) do Q.push(pc, "WPWS", b) end
    end
    M.stats.pw_sent = M.stats.pw_sent + #items
    local line = string.format("world: %d puzzle / power state(s) changed on the host, sent: %s", #items,
        table.concat(items, ";", 1, math.min(#items, 4)) .. (#items > 4 and ";..." or ""))
    if M.stats.pw_sent <= 60 then log.info("%s", line) else log.debug("%s", line) end
    return #items
end

-- Host: look at every object now and again in 3 s (timelines, the circuit
-- box's levers).
function PW.mark_dirty()
    if not is_host() then return end
    local now = clock()
    PW.dirty[#PW.dirty + 1] = now + 0.2
    PW.dirty[#PW.dirty + 1] = now + 3
end

function PW.host_tick(now)
    if not PW.world_at then PW.world_at = now end
    if not PW.objs then
        if now - PW.world_at < 5 or not PW.build_step() then return end
        for _, e in ipairs(PW.objs) do
            local s = PW.state_of(e)
            PW.base[e.p], PW.sent[e.p] = s, s
        end
        log.info("world: %d puzzle / power object(s) tracked (generators, levers, circuit boxes, switches, lights, laboratory and bunker doors, scanners, sirens, radios)",
            #PW.objs)
        if not PW.restored then
            local ok, err = pcall(PW.restore)
            if not ok then log.warn("world: puzzle state restore: %s", tostring(err)) end
        end
        return
    end
    if #PW.dirty > 0 then
        local keep, due = {}, false
        for _, t in ipairs(PW.dirty) do if now >= t then due = true else keep[#keep + 1] = t end end
        PW.dirty = keep
        if due then PW.pass(PW.objs) return end
    end
    for a, r in pairs(PW.resync) do
        if now >= r.at then
            PW.resync[a] = nil
            local n = PW.send_all(r.pc, "r")
            log.debug("world: %d puzzle / power state(s) to %s again after its step", n, ue.short(r.pc))
        end
    end
    if now < PW.idle_at then return end
    local n = #PW.objs
    local chunk = {}
    for _ = 1, math.min(PW.CHUNK, n) do
        if PW.cursor > n then break end
        chunk[#chunk + 1] = PW.objs[PW.cursor]
        PW.cursor = PW.cursor + 1
    end
    PW.pass(chunk)
    if PW.cursor > n then
        PW.cursor = 1
        PW.idle_at = now + PW.IDLE_S
    end
end

-- Every state that differs from the level's start, to one client (queued).
function PW.send_all(pc, flag)
    if not PW.objs then return 0 end
    local items = {}
    for _, e in ipairs(PW.objs) do
        local s = PW.state_of(e)
        if s and s ~= PW.base[e.p] then items[#items + 1] = pack(e.p) .. "=" .. s end
    end
    for _, b in ipairs(Q.batches(items)) do
        if flag then Q.push(pc, "WPWS", b, flag) else Q.push(pc, "WPWS", b) end
    end
    return #items
end

-- Join: the same (snapshot, Q.all).
function PW.snapshot(pc) return PW.send_all(pc) end

-- Host: a client's own press may have run more of a chain on its machine
-- than the host's step (a circuit box shot again and again switches its
-- lights each time, a siren's flip-flop): RESYNC_S after its last step it
-- gets every state again ("r": what it just used is left alone).
function PW.resync_later(pc)
    local a = addr(pc)
    if a then PW.resync[a] = { pc = pc, at = clock() + PW.RESYNC_S } end
end

-- ---------------------------------------------------------------------------
-- The host's save: <slot>_SDCoop_World.txt
-- ---------------------------------------------------------------------------

function PW.save_dir()
    if PW.dir then return PW.dir end
    local p = package.loaded["sdc_persist"]
    if type(p) == "table" and type(p.savegames_dir) == "function" then
        local ok, d = pcall(p.savegames_dir)
        if ok and type(d) == "string" then return d end
    end
    local base = os.getenv("LOCALAPPDATA")
    if not base or base == "" then return nil end
    return base:gsub("\\", "/") .. "/SurrounDead/Saved/SaveGames/"
end

function PW.file_of(slot)
    if type(slot) ~= "string" or slot == "" or slot:find("[/\\:]") then return nil end
    local d = PW.save_dir()
    if not d then return nil end
    -- A UE4SS wrapper's text ("RemoteUnrealParam: 0000...") never gets here
    -- (the ':'), but the 0.6.40-0.6.48 bug left real worlds named
    -- "RemoteUnrealParam_<hex>": such a slot is a slot when its folder is on
    -- disk (0.7.1: one user's world had its puzzle / power states neither
    -- saved nor loaded because of that name).
    if ue.is_wrapper_text(slot) then
        local fh = io.open(d .. slot .. "/Slot.sav", "rb")
        if not fh then return nil end
        fh:close()
    end
    return d .. slot .. PW.FILE_TAG
end

function PW.save(why)
    PW.save_pending = false
    if not is_host() or not PW.objs or not on("world_doors") then return end
    local slot = ue.ems_current_slot()
    local f = PW.file_of(slot)
    if not f then
        log.warn("world: puzzle / power states not saved: no slot name (%s)", tostring(slot))
        return
    end
    local lines, n = { "# SDCoop: puzzle / power states of slot " .. slot .. " that differ from the level's start" }, 0
    for _, e in ipairs(PW.objs) do
        local s = PW.state_of(e)
        if s and PW.base[e.p] ~= nil and s ~= PW.base[e.p] then
            lines[#lines + 1] = pack(e.p) .. "=" .. s
            n = n + 1
        end
    end
    local tmp = f .. ".tmp"
    local h = io.open(tmp, "wb")
    if not h then log.warn("world: cannot write %s", tmp) return end
    h:write(table.concat(lines, "\n"), "\n")
    h:close()
    os.remove(f)
    local ok, err = os.rename(tmp, f)
    log.info("world: %d puzzle / power state(s) saved with slot %s (%s)%s", n, slot, tostring(why),
        ok and "" or (": rename FAILED " .. tostring(err)))
end

-- Host, once per world after the start states were read.
function PW.restore()
    PW.restored = true
    local slot = ue.ems_current_slot()
    local f = PW.file_of(slot)
    local h = f and io.open(f, "rb")
    if not h then return end
    local data = h:read("a")
    h:close()
    local list, miss = {}, 0
    for line in tostring(data):gmatch("[^\r\n]+") do
        local pk, s = line:match("^([^#=][^=]*)=(.+)$")
        if pk then
            local e = PW.idx[unpack_path(pk)]
            if e then list[#list + 1] = { e = e, s = s } else miss = miss + 1 end
        end
    end
    table.sort(list, function(a, b) return PW.K[a.e.k].order < PW.K[b.e.k].order end)
    local n = 0
    for _, it in ipairs(list) do
        local o = PW.obj(it.e)
        if o and PW.state_of(it.e) ~= it.s then
            local ok, err = pcall(PW.K[it.e.k].set, o, it.s, nil)
            if ok then n = n + 1 else log.warn("world: restore %s: %s", ue.short(o), tostring(err)) end
        end
    end
    M.stats.pw_restored = n
    log.info("world: %d puzzle / power state(s) restored from the save of slot %s (%d in the file, %d unknown here)",
        n, tostring(slot), #list + miss, miss)
    PW.mark_dirty()
end

-- BP_PlayerController.SaveGameToSlot (post): every save of the game. The
-- file is written 50 ms later, out of the game's call.
function PW.on_save()
    if not is_host() or PW.save_pending then return end
    PW.save_pending = true
    ue.delay("world-pwsave", 50, function() PW.save("the game's save") end)
end

-- EMSFunctionLibrary.DeleteAllSaveDataForSlot (native, pre: Context,
-- WorldContextObject, SaveGameName, UserIndex): the slot's file goes too.
function PW.on_delete(_, _, slot_p)
    local slot = ue.fstring(slot_p)
    local f = PW.file_of(slot)
    if f and os.remove(f) then log.info("world: puzzle / power states of deleted slot %s removed", slot) end
end

-- ---------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------

-- Set objects to the host's states, in the chain's order. A later look
-- leaves alone what this player just used (its step is on the way to the
-- host; the host's answer comes as a new state).
function PW.apply_list(paths, why)
    local list = {}
    local look = why ~= "host"
    local now = clock()
    for _, p in ipairs(paths) do
        local o = find(p)
        local want = PW.want[p]
        local k = o and want and PW.kind_of(o)
        if k and not (look and now - (PW.pressed[p] or -100) < 2) then
            list[#list + 1] = { o = o, k = k, want = want }
        end
    end
    table.sort(list, function(a, b) return PW.K[a.k].order < PW.K[b.k].order end)
    local n = 0
    for _, it in ipairs(list) do
        local okc, cur = pcall(PW.K[it.k].state, it.o)
        if okc and cur ~= it.want then
            -- another player's state applied here: the game's notices it raises are not this player's
            local notes = PW.notes()
            local ok, err
            if notes and notes.quietly then
                ok, err = notes.quietly("applying the host's " .. ue.short(it.o), PW.K[it.k].set, it.o, it.want, nil)
            else
                ok, err = pcall(PW.K[it.k].set, it.o, it.want, nil)
            end
            n = n + 1
            M.stats.pw_applied = M.stats.pw_applied + 1
            local line = string.format("world: %s %s -> %s as on the host (%s)%s", ue.short(it.o), tostring(cur), it.want,
                why, ok and "" or (" FAILED " .. tostring(err)))
            if M.stats.pw_applied <= 60 then log.info("%s", line) else log.debug("%s", line) end
        end
    end
    return n
end

-- WPWS|path=state;path=state...|r?   (host -> clients; r: again after a step)
function PW.msg(f)
    if S.role ~= "client" or not on("world_doors") then return end
    local paths = {}
    for _, it in ipairs(split(f[1], ";")) do
        local pk, s = it:match("^(.-)=(.+)$")
        if pk then
            local p = unpack_path(pk)
            PW.want[p] = s
            if find(p) then paths[#paths + 1] = p else later("pw", p, s) end
        end
    end
    if #paths == 0 then return end
    PW.apply_list(paths, f[2] == "r" and "again" or "host")
    -- timelines and the circuit box's levers (they switch lights) finish later
    PW.checks[#PW.checks + 1] = { at = clock() + PW.CHECK_AFTER[1], paths = paths, round = 1 }
end

PW.CHECK_AFTER = { 3, 5, 7 }   -- s between the looks (3, 8, 15 s after the message)
function PW.client_tick(now)
    if #PW.checks == 0 then return end
    local keep = {}
    for _, c in ipairs(PW.checks) do
        if now >= c.at then
            local n = PW.apply_list(c.paths, "check " .. c.round)
            if c.round < #PW.CHECK_AFTER then
                keep[#keep + 1] = { at = now + PW.CHECK_AFTER[c.round + 1], paths = c.paths, round = c.round + 1 }
            elseif n > 0 then
                log.warn("world: %d puzzle / power object(s) differed from the host again at the last look", n)
            end
        else
            keep[#keep + 1] = c
        end
    end
    PW.checks = keep
end

-- The newest notification with this text goes (the game's note of a check
-- this machine cannot make; the host answers instead). Notes are appended
-- (NotificationParentWidget @740 AddChildToVerticalBox).
function PW.unnote(text)
    local pc = ue.local_pc()
    local hud = pc and ue.try(function() return pc:GetHUD() end)
    local vb = ue.prop(ue.prop(hud, "NotificationUI"), "VerticalBox_31")
    if not ue.valid(vb) then return false end
    local n = tonumber(ue.try(function() return vb:GetChildrenCount() end)) or 0
    for i = n - 1, math.max(0, n - 6), -1 do
        local w = ue.try(function() return vb:GetChildAt(i) end)
        local det = ue.prop(w, "NotificationDetailsStruct")
        local msg = det and ue.try(function() return ue.str(det[PW.NOTE_MSG]) end)
        if msg == text then return (pcall(function() w:RemoveFromParent() end)) end
    end
    return false
end

-- The game's own note (GameFunctionLibrary.CreateNotificationUI).
function PW.note(text)
    local gfl = ue.find_object(PW.PATHS.gfl)
    local pc = ue.local_pc()
    if not gfl or not pc then return false end
    return apply(function()
        gfl:CreateNotificationUI(FText(text), nil, { R = 1, G = 1, B = 1, A = 1 }, 2.0, false, pc)
    end)
end

-- An all-access keycard in this player's inventory (FindJigItemByDA reads
-- this machine's widgets: the host has none for this player).
function PW.has_allaccess()
    local pawn = ue.local_pawn()
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    -- (not in memory: nobody carries one; no synchronous load)
    local da = ue.loaded_asset(PW.PATHS.allaccess, "world")
    if not ue.valid(jig) or not da then return false end
    local out = {}
    return pcall(function() jig:FindJigItemByDA(da, {}, true, false, 1, out) end) and out.Result == true
end

function PW.option_name(opt_p)
    local o = get(opt_p)
    if o == nil then return "" end
    return ue.str(ue.try(function() return o.TagName end))
end

-- What a client's press could not do here and the host has to: try, note.
function PW.try_of(o, k, s, opt_p)
    if k == "pgen" then
        local opt = PW.option_name(opt_p)
        if opt:find("Option2", 1, true) and ue.prop(o, "GasAdded?") ~= true then
            return "gas", "No Gas Can In Inventory"
        end
        if opt:find("Option1", 1, true) and ue.prop(o, "TurnedOn?") ~= true and ue.prop(o, "GasAdded?") == true
            and ue.prop(o, "RequiredItemToPowerOn?") == true and ue.prop(o, "ItemUsed?") ~= true then
            return "item", ue.str(ue.prop(o, "DisplayItemName")) .. " Not Found"
        end
    elseif (k == "sdoor" and s:sub(1, 1) == "l") or (k == "secure" and s:sub(2, 2) == "0") then
        return "key", "No Keycard Available"
    end
    return nil
end

-- <class>.OnExecuteInteract(InteractingActor, Option) (post), also the
-- circuit box's Damage_Object: this machine's player used it.
function PW.on_exec(c, _, opt_p)
    if not on("world_doors") then return end
    local o = c and c:get()
    if not level_actor(o) then return end
    local p = path_of(o)
    if not p then return end
    PW.pressed[p] = clock()
    if is_host() then PW.mark_dirty() return end
    if S.role ~= "client" or applying > 0 then return end
    local cls = ue.class_name(o)
    -- replicated keycard / hangar doors and the scanners go to the host by the
    -- game's server path; an all-access card there is in this player's widgets only
    if PW.is_card_door(o) or cls == "BP_BunkerScanner_C" then
        local locked
        if cls == "BP_BunkerScanner_C" then
            locked = ue.prop(o, "Unlocked?") ~= true and ue.prop(o, "KeycardRequired?") == true
        else
            locked = ue.prop(o, "Open?") ~= true
        end
        if locked and PW.has_allaccess() and to_host("WPTRY", pack(p), "allaccess") then
            M.stats.pw_tries = M.stats.pw_tries + 1
            log.info("world: %s used with an all-access keycard here: the host opens it", ue.short(o))
        end
        return
    end
    local k = PW.kind_of(o)
    if not k then return end
    local okc, s = pcall(PW.K[k].state, o)
    if not okc or not s then return end
    local try, note = PW.try_of(o, k, s, opt_p)
    if try then
        if not PW.unnote(note) then ue.delay("world-unnote", 100, function() PW.unnote(note) end) end
        if to_host("WPTRY", pack(p), try) then M.stats.pw_tries = M.stats.pw_tries + 1 end
        log.info("world: %s: '%s' here, the host checks (%s)", ue.short(o), note, try)
        return
    end
    if PW.K[k].no_step then return end
    if to_host("WPSTEP", pack(p), s) then M.stats.pw_steps = M.stats.pw_steps + 1 end
    log.info("world: used %s here (%s): sent to the host", ue.short(o), s)
end

-- ---------------------------------------------------------------------------
-- Host: a client's step / try
-- ---------------------------------------------------------------------------

-- WPSTEP|path|state   (client -> host): the host runs the game's step.
function PW.step_msg(f, pc)
    if not is_host() or not on("world_doors") then return end
    local p = unpack_path(f[1])
    local want = tostring(f[2] or "")
    local o = find(p)
    local k = o and PW.kind_of(o)
    if not k or want == "" or PW.K[k].no_step then return end
    local before = PW.K[k].state(o)
    if before ~= want then
        -- that player's action: the game's notices it raises go to that player
        local notes = PW.notes()
        local ok, err
        if notes and notes.for_player then
            ok, err = notes.for_player(pc, PW.K[k].step or PW.K[k].set, o, want, ue.pawn_of(pc))
        else
            ok, err = pcall(PW.K[k].step or PW.K[k].set, o, want, ue.pawn_of(pc))
        end
        M.stats.pw_host = M.stats.pw_host + 1
        log.info("world: %s used %s: %s -> %s on the host (theirs %s)%s", ue.short(pc), ue.short(o), before,
            tostring(PW.K[k].state(o)), want, ok and "" or (" FAILED " .. tostring(err)))
    end
    PW.mark_dirty()
    PW.resync_later(pc)
end

-- WPTRY|path|gas|item|key|allaccess   (client -> host)
function PW.try_msg(f, pc)
    if not is_host() or not on("world_doors") then return end
    local p = unpack_path(f[1])
    local what = tostring(f[2] or "")
    local o = find(p)
    local pawn = ue.pawn_of(pc)
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    if not o or not ue.valid(jig) then return end
    local function consume(da)
        if not ue.valid(da) then return false end
        local out = {}
        return pcall(function() jig:ServerFindThenConsumeByItemID(da, 1, out) end) and out.Result == true
    end
    local ok, reply = false, nil
    local k = PW.kind_of(o)
    -- the game's step for that player: its notices go to that player (sdc_notes)
    local notes = PW.notes()
    local function as_player(fn, ...)
        if notes and notes.for_player then return notes.for_player(pc, fn, ...) end
        return pcall(fn, ...)
    end
    if what == "gas" and k == "pgen" then
        -- Event_AddGas @2883-3729
        if ue.prop(o, "GasAdded?") == true then reply = "Gas Already Added"
        elseif consume(ue.loaded_asset(PW.PATHS.gascan, "world")) then
            ue.set_prop(o, "GasAdded?", true)
            ok, reply = true, "Generator Refueled"
        else reply = "No Gas Can In Inventory" end
    elseif what == "item" and k == "pgen" then
        -- Event_TurnOn @2061-2362 with that player's inventory
        if ue.prop(o, "ItemUsed?") == true
            or (ue.prop(o, "ConsumeItemOnUse?") == true and consume(ue.prop(o, "RequiredItem"))) then
            ue.set_prop(o, "ItemUsed?", true)
            if ue.prop(o, "TurnedOn?") ~= true then as_player(PW.call, o, "Event_TurnOn", pawn) end
            ok = true
        else
            reply = ue.str(ue.prop(o, "DisplayItemName")) .. " Not Found"
        end
    elseif what == "key" and (k == "sdoor" or k == "secure") then
        -- Event_Door: Keycard consumed (@2698 / @2434), unlocked, XP once, open
        if consume(ue.prop(o, "Keycard")) then
            local first = ue.prop(o, "XPGiven?") ~= true
            as_player(PW.K[k].set, o, k == "sdoor" and "uo1" or "111", pawn)
            ok = true
            if first then Q.now(pc, "WPXP", pack(p)) end
        else reply = "No Keycard Available" end
    elseif what == "allaccess" then
        local cls = ue.class_name(o)
        if cls == "BP_BunkerScanner_C" then
            if ue.prop(o, "Unlocked?") ~= true then
                -- FindKeycard @0: a scanner that needs no card passes
                ue.set_prop(o, "KeycardRequired?", false)
                PW.call(o, "MC_CallInteract", pawn)
            end
            ok = true
        elseif PW.is_card_door(o) then
            if ue.prop(o, "Open?") ~= true and PW.tl_play(o, "Timeline_OpenDoor") == nil then
                -- Event_OpenDoor after its card check (keycard door @70, hangar door @2074 -> @1436)
                PW.tl(o, "Timeline_OpenDoor", "PlayFromStart")
                ue.delay("world-rdoor", RDOOR_SETTLE_MS, function()
                    local d = find(p)
                    if d then to_clients("WRDOOR", pack(p), ue.prop(d, "Open?") == true and "1" or "0") end
                end)
            end
            ok = true
        end
    end
    M.stats.pw_tries = M.stats.pw_tries + 1
    if ok then M.stats.pw_tries_ok = M.stats.pw_tries_ok + 1 end
    if reply then Q.now(pc, "WPNOTE", reply) end
    log.info("world: %s asked the host for %s at %s: %s%s", ue.short(pc), what, ue.short(o), ok and "done" or "no",
        reply and (" ('" .. reply .. "')") or "")
    PW.mark_dirty()
    PW.resync_later(pc)
end

-- WPNOTE|text   (host -> one client): the game's note of the host's check.
function PW.note_msg(f)
    if S.role ~= "client" then return end
    local text = tostring(f[1] or "")
    PW.note(text)
    log.info("world: the host says '%s'", text)
end

-- WPXP|door   (host -> the client whose keycard opened it): the door's XP of
-- single player, once per door (Event_Door @1915-2605: CurrentLevel x 400).
function PW.xp_msg(f)
    if S.role ~= "client" then return end
    local d = find(unpack_path(f[1]))
    -- WPXP|path|mult|note (0.6.69: scanner x200 no note, keycard door x200);
    -- a keycard door whose own check here passed (all-access) gave it already
    local mult, with_note = tonumber(f[2]) or 400, f[3] ~= "0"
    if f[2] and d and ue.prop(d, "XPGiven?") == true then return end
    if d and ue.prop(d, "XPGiven?") ~= nil then ue.set_prop(d, "XPGiven?", true) end
    if f[2] and with_note and d and PW.is_card_door(d) then
        -- its own copy's check (@3077, hangar @3409) could not see the card the host took
        PW.unnote("No Keycard Available")
        ue.delay("world-unnote", 1000, function() PW.unnote("No Keycard Available") end)
    end
    local pc = ue.local_pc()
    local comp = ue.prop(pc, "LevellingComponent")
    if not ue.valid(comp) then return end
    -- the XP bar's timer (moves the added XP into the bar; sdc_ai_kills does the same)
    if not PW.xp_timer then PW.xp_timer = ue.call(comp, "Event_LevelBarTimer") end
    local xp = (tonumber(ue.prop(comp, "CurrentLevel")) or 1) * mult
    local out = {}
    if not pcall(function() comp:AddXP(xp, false, out) end) then return end
    local given = math.floor(tonumber(out.XPOutput) or xp)
    if with_note then PW.note(string.format("Door Unlocked, XP Given: %d", given)) end
    log.info("world: XP for %s: %d", d and ue.short(d) or "?", given)
end

-- BP_Siren.ActivateSiren / DeactivateSiren (post). Host: its random timer or
-- a press: a change to send. Client: its own random timer (one per machine,
-- @190) or its 138 s end: back to the host's state (a press is sent instead).
function PW.on_siren(c)
    if not on("world_doors") then return end
    local o = c and c:get()
    if not level_actor(o) then return end
    if is_host() then PW.mark_dirty() return end
    if S.role ~= "client" or applying > 0 then return end
    local p = path_of(o)
    if not p then return end
    ue.delay("world-siren", 100, function()
        local s = find(p)
        if not s or clock() - (PW.pressed[p] or -100) < 1 then return end
        local want = PW.want[p] or "0"
        if PW.K.siren.state(s) ~= want then
            PW.K.siren.set(s, want)
            log.debug("world: %s's own timer here: back to the host's siren (%s)", ue.short(s), want)
        end
    end)
end

-- BP_BunkerScanner.MC_CallInteract(InteractingActor) (post, host): a scanner used.
function PW.on_scan(c, actor_p)
    if not is_host() then return end
    PW.mark_dirty()
    LK.on_scan(c, actor_p)
end

function PW.reset()
    PW.objs, PW.idx, PW.todo, PW.found = nil, {}, nil, nil
    PW.base, PW.sent, PW.world_at, PW.dirty, PW.cursor, PW.idle_at = {}, {}, nil, {}, 1, 0
    PW.want, PW.checks, PW.pressed, PW.restored, PW.save_pending, PW.resync = {}, {}, {}, false, false, {}
    PW.xp_timer = nil
end

-- ===========================================================================
-- Harvesting: trees / rocks (foliage instances), scrap metal piles
-- ===========================================================================

local function harvest_class(kind)
    local c = cache.harvest_cls[kind]
    if ue.valid(c) then return c end
    c = load_object(HARVEST_CLASS[kind])
    cache.harvest_cls[kind] = c
    return c
end

-- GameplayStatics.BeginDeferredActorSpawnFromClass (native pre): the swing's
-- harvestable spawn (HitFoliageTree @553 / HitFoliageRock @553: wco = the
-- weapon, class BP_HarvestableObject_Tree/Rocks, the instance's transform).
function PF.block_class(class_p)
    if not ue.valid(cache.block_cls) then cache.block_cls = ue.find_object(NOT_AN_ACTOR) end
    if not cache.block_cls then return false end
    return (pcall(function() class_p:set(cache.block_cls) end))
end

-- Client: a level spawner (prefab camp, hidden cache, special item case)
-- about to spawn its own random actor. TSubclassOf<AActor> refuses a
-- non-actor class: the spawn returns None, the spawner's next steps
-- (FinishSpawningActor, SetObjectPropertyByName...) do nothing.
function PF.block_spawner(wco, wcls, class_p)
    if not on(PF.BLOCK_KEY[PF.BLOCK_SPAWNERS[wcls]] or "world_prefabs") or not PF.world_is_client(wco) then return end
    local cls = get(class_p)
    local cname = ue.valid(cls) and ue.short(cls) or "?"
    if not PF.block_class(class_p) then
        log.err_throttled("world.prefab-block", "world: cannot block the client's own spawn of %s by %s", cname, ue.short(wco))
        return
    end
    M.stats.prefab_blocked = M.stats.prefab_blocked + 1
    local line = string.format("world: %s's own spawn of %s blocked on this client (the host's comes replicated)",
        ue.short(wco), cname)
    if M.stats.prefab_blocked <= 8 then log.info("%s", line) else log.debug("%s", line) end
    -- a prefab spawner goes on with its discovery timer (DistanceToPrefab:
    -- XP, marker removal) and SpawnMarker for a camp that is not here: it
    -- goes, as it does itself when its random check fails (@598)
    if PF.BLOCK_SPAWNERS[wcls] == "prefab" then
        -- a dynamic one (this client's own event manager's roll) would still
        -- play its SoundOnSpawn (@46): sdc_events clears it
        local evm = package.loaded["sdc_events"]
        if evm and evm.client_own_roll then pcall(evm.client_own_roll, wco, cname) end
        local p = raw_path(wco)
        if p then
            ue.delay("world-spawner", 300, function()
                local sp = find(p)
                if sp and ue.role(sp) == ue.ROLE_AUTHORITY then pcall(function() sp:K2_DestroyActor() end) end
            end)
        end
    end
end

-- Client: an infestation's own wave of enemies (WavesOfEnemies -> @432
-- BeginDeferredActorSpawnFromClass(self, AI class)): the client's copy of a
-- nest overlapped by its player spawned a local horde (ghosts: no AI
-- controller on a client) next to the host's real one. Its map marker
-- (BP_Marker_C @1124) stays.
function PF.block_wave(wco, class_p)
    if not on("world_objects") or not PF.world_is_client(wco) then return end
    local cls = get(class_p)
    local cname = ue.valid(cls) and ue.short(cls) or "?"
    if cname == "BP_Marker_C" then return end
    if not PF.block_class(class_p) then return end
    M.stats.waves_blocked = M.stats.waves_blocked + 1
    local line = string.format("world: %s's own %s blocked on this client (the host's wave comes replicated)",
        ue.short(wco), cname)
    if M.stats.waves_blocked <= 5 then log.info("%s", line) else log.debug("%s", line) end
end

local function on_spawn(_, wco_p, class_p, tf_p)
    if not wco_p or not class_p then return end
    local wco = get(wco_p)
    if not ue.valid(wco) then return end
    local wcls = ue.class_name(wco)
    if (wcls == "BP_EventManager_C" or wcls:find("^AirdropAircraft")) and is_host() then EV.on_spawn_by(wcls, class_p) end
    if PF.BLOCK_SPAWNERS[wcls] then PF.block_spawner(wco, wcls, class_p) return end
    if wcls:find("^BP_Infestation") or wcls:find("^BP_PrimaryInfestation") then PF.block_wave(wco, class_p) return end
    if not on("world_harvest") then return end
    local role = S and S.role
    if role ~= "host" and role ~= "client" then return end
    if not wcls:find("Pickup", 1, true) then return end   -- a melee weapon's swing
    local cls = get(class_p)
    if not ue.valid(cls) then return end
    local cname = ue.try(function() return cls:GetFName():ToString() end) or ""
    local kind = (cname:find("^BP_HarvestableObject_Tree") and "t") or (cname:find("^BP_HarvestableObject_Rocks") and "r")
    if not kind then return end
    local tf = get(tf_p)
    local loc = tf and v3(ue.try(function() return tf.Translation end))
    pending_harv = { t = clock(), loc = loc, kind = kind }
    if role == "client" then
        -- only the host's replicated harvestable may exist (it counts the hits)
        if PF.block_class(class_p) then
            M.stats.harv_blocked = M.stats.harv_blocked + 1
            if M.stats.harv_blocked <= 3 then log.info("world: local %s spawn blocked (the host's one comes)", cname) end
        end
    end
end

-- Foliage instances. A place is matched to an instance of the component by
-- the index the sender had (both machines load the same level and remove the
-- same instances, so indices mostly agree), checked by its position, else
-- among the instances whose bounds overlap a small sphere there. UE4SS hands
-- a struct out parameter either as a field of the table passed
-- (out.OutInstanceTransform) or fills that table itself: both are read.
function HV.vec(t)
    local v = v3(t)
    if v then return v end
    if t ~= nil and type(t) ~= "number" then return v3(ue.try(function() return t:get() end)) end
    return nil
end

function HV.transform(ism, i)
    local out = {}
    if not pcall(function() ism:GetInstanceTransform(i, out, true) end) then return nil end
    local tf = out.OutInstanceTransform
    if tf == nil then tf = out end
    if ue.try(function() return tf.Translation end) == nil then
        local inner = ue.try(function() return tf:get() end)
        if inner ~= nil then tf = inner end
    end
    return tf
end

function HV.inst_loc(ism, i)
    local tf = HV.transform(ism, i)
    if tf == nil then return nil end
    return HV.vec(ue.try(function() return tf.Translation end))
end

function HV.ints(arr)
    local list = {}
    local function add(e)
        local v = e
        if type(e) ~= "number" then v = ue.try(function() return e:get() end) end
        v = tonumber(v)
        if v then list[#list + 1] = v end
    end
    if type(arr) == "table" then
        for _, e in ipairs(arr) do add(e) end
    elseif arr ~= nil then
        pcall(function() arr:ForEach(function(_, e) add(e) end) end)
    end
    return list
end

-- Index of the instance at `loc`; nil, why when there is none here (or it
-- cannot be read).
function HV.instance(ism, loc, hint)
    if not ue.valid(ism) or not loc then return nil, "no component" end
    local why = {}
    local lim = FOL_MATCH * FOL_MATCH
    hint = tonumber(hint)
    if hint and hint >= 0 then
        local l = HV.inst_loc(ism, hint)
        if l and d2(l, loc) <= lim then
            M.stats.fol_idx = M.stats.fol_idx + 1
            return hint, "index"
        end
        why[#why + 1] = l and string.format("index %d is %.0f cm away", hint, math.sqrt(d2(l, loc)))
            or string.format("index %d not readable", hint)
    end
    local ok, arr = pcall(function() return ism:GetInstancesOverlappingSphere(loc, FOL_RADIUS, true) end)
    if not ok then
        why[#why + 1] = "overlap query failed: " .. tostring(arr)
    else
        local list = HV.ints(arr)
        local best, bestd, nread = nil, lim, 0
        for _, i in ipairs(list) do
            local l = HV.inst_loc(ism, i)
            if l then
                nread = nread + 1
                local d = d2(l, loc)
                if d <= bestd then best, bestd = i, d end
            end
        end
        if best then
            M.stats.fol_ovl = M.stats.fol_ovl + 1
            return best, "overlap"
        end
        why[#why + 1] = string.format("%d overlapping instance(s), %d read, none within %d cm", #list, nread, FOL_MATCH)
    end
    M.stats.fol_miss = M.stats.fol_miss + 1
    return nil, table.concat(why, "; ")
end

local function host_record_fol(ism_path, loc)
    local key = ism_path .. "|" .. loc_str(loc)
    if fol_seen[key] then return false end
    fol_seen[key] = true
    local l = fol_removed[ism_path]
    if not l then l = {}; fol_removed[ism_path] = l end
    l[#l + 1] = loc_str(loc)
    return true
end

-- ---------------------------------------------------------------------------
-- The harvestables themselves (BP_HarvestableObject_Tree / _Rocks)
-- ---------------------------------------------------------------------------

-- NotifyOnNewObject: a harvestable made on this machine (the host's swing /
-- request) or arriving from the host (client). Its path only.
function HV.on_new(o, kind)
    if not S or (S.role ~= "host" and S.role ~= "client") then return end
    local p = raw_path(o)
    if not p or p:find("Default__", 1, true) then return end
    HV.live[p] = { kind = kind, t = clock() }
    if S.role == "client" then
        HV.dress_due = 0
        HV.seen_new = true
    end
end

local function harvest_kind_of(a)
    return ue.class_name(a):find("Rocks", 1, true) and "r" or "t"
end

-- Host: the harvestable of that kind at `loc` (nearest within MATCH).
function HV.find(kind, loc)
    local best, bestd = nil, HV.MATCH * HV.MATCH
    local function consider(a)
        local l = ue.location(a)
        if l then
            local d = d2(l, loc)
            if d <= bestd then best, bestd = a, d end
        end
    end
    for p, e in pairs(HV.live) do
        if e.kind == kind then
            local a = find(p)
            if a then consider(a) else HV.live[p] = nil end
        end
    end
    if not best then
        -- not reported by the watch (unavailable, or before it): the engine's list
        for _, a in ipairs(HV.scan(kind)) do consider(a) end
    end
    return best
end

-- The harvestables of a kind by FindAllOf (at most once a second per kind);
-- what it finds joins HV.live.
function HV.scan(kind)
    local cname = kind == "r" and "BP_HarvestableObject_Rocks_C" or "BP_HarvestableObject_Tree_C"
    local out = {}
    for _, a in ipairs(ue.find_all_recent(cname, 1.0)) do
        if ue.valid(a) then
            out[#out + 1] = a
            local p = path_of(a)
            if p and not HV.live[p] and not p:find("Default__", 1, true) then HV.live[p] = { kind = kind, t = clock() } end
        end
    end
    return out
end

-- Host: a new harvestable gets its hit count now (SetMaxHits, as its first
-- hit's Svr_SetMaxHits does; that first hit rolls again). Replicated with the
-- actor, a client's own first hit no longer sees the class default (tree: 1)
-- and "fells" it on its own at once.
function HV.prime_actor(a)
    if not ue.valid(a) or not is_host() then return end
    if num(ue.prop(a, "MaxHits"), 0) > 1 then return end
    pcall(function() a:SetMaxHits() end)
end

-- Client: hits of this player's own swing on the host's harvestable (the
-- host's replay of the swing practically never hits): summed per harvestable,
-- sent each tick.
function HV.relay(a, at, hits)
    local k = addr(a)
    local l = ue.location(a)
    if not k or not l then return end
    local e = HV.out[k]
    if not e then
        e = { kind = harvest_kind_of(a), loc = l, hits = 0, at = at or l, n = 0, name = ue.short(a) }
        HV.out[k] = e
    end
    e.hits = e.hits + math.max(1, hits or 1)
    e.n = e.n + 1
    if at then e.at = at end
end

function HV.flush()
    if next(HV.out) == nil then return end
    for k, e in pairs(HV.out) do
        local n = math.min(e.hits, 40)
        if to_host("WHHIT", e.kind, loc_str(e.loc), tostring(n), loc_str(e.at)) then
            M.stats.hits_sent = M.stats.hits_sent + 1
            local c = (HV.logged[k] or 0) + 1
            HV.logged[k] = c
            local line = string.format("world: own hit on the host's %s %s at %s: x%d (%d trace hit(s)) sent to the host",
                e.kind == "r" and "rock" or "tree", e.name, loc_str(e.loc), n, e.n)
            if c <= 2 then log.info("%s", line) else log.debug("%s", line) end
        end
    end
    HV.out = {}
end

function HV.pc_of(k)
    for _, pc in ipairs(remote_pcs()) do
        if addr(pc) == k then return pc end
    end
    return nil
end

-- Host: a client's hits, run with the harvestable's own HitHarvestableObject
-- (the swing's call: MaxHits, the chop sound, the fall at 0 and the grant to
-- GetPlayerCharacter(self, 0) = this player through the scope).
function HV.apply_hit(a, pc, hits, at)
    local ka = addr(a) or 0
    local name = ue.short(a)
    local rp = HV.replay[ka .. ":" .. (addr(pc) or 0)]
    if rp and clock() - rp < HV.DUP_S then
        M.stats.hits_dup = M.stats.hits_dup + 1
        log.debug("world: %s's hit on %s: the host's replay of that swing already counted it", ue.short(pc), name)
        return
    end
    local before = num(ue.prop(a, "MaxHits"), 1)
    if before <= 0 then
        log.debug("world: %s's hit on %s: already felled", ue.short(pc), name)
        return
    end
    remember_hit(a, pc)
    local ok, err = pcall(function() a:HitHarvestableObject(at, hits) end)
    if not ok then
        log.warn("world: %s's hit on %s failed: %s", ue.short(pc), name, tostring(err))
        return
    end
    M.stats.hits_host = M.stats.hits_host + 1
    local after = num(ue.prop(a, "MaxHits"), 0)
    local c = (HV.logged[ka] or 0) + 1
    HV.logged[ka] = c
    if after <= 0 then
        log.info("world: %s fells %s with its hit x%d (%d -> %d): the game's fall and grant follow for that player",
            ue.short(pc), name, hits, before, after)
    else
        local line = string.format("world: %s hits %s x%d on the host: %d -> %d hit(s) left", ue.short(pc), name, hits, before, after)
        if c <= 2 then log.info("%s", line) else log.debug("%s", line) end
    end
end

-- WHHIT|t/r|harvestable x,y,z|hits|impact x,y,z   (client -> host)
function HV.hit_msg(f, pc)
    if not is_host() or not on("world_harvest") then return end
    local kind = (f[1] == "r") and "r" or "t"
    local loc = parse_loc(f[2])
    if not loc then return end
    local hits = math.floor(num(f[3], 1))
    if hits < 1 then hits = 1 elseif hits > 40 then hits = 40 end
    local at = parse_loc(f[4]) or loc
    local k = addr(pc) or -1
    local now = clock()
    local r = HV.rate[k]
    if not r or now - r.t >= 1 then r = { t = now, n = 0 }; HV.rate[k] = r end
    r.n = r.n + 1
    if r.n > 20 then
        log.err_throttled("world.hhit-rate", "world: %s sends harvest hits too fast; extra ones dropped", ue.short(pc))
        return
    end
    local a = HV.find(kind, loc)
    if a then
        HV.apply_hit(a, pc, hits, at)
        return
    end
    -- its harvestable is still being made here (the client's WHARV)
    HV.wait[#HV.wait + 1] = { pck = k, name = ue.short(pc), kind = kind, loc = loc, hits = hits, at = at, till = now + HV.WAIT_S }
end

function HV.wait_pass(now)
    if #HV.wait == 0 then return end
    local keep = {}
    for _, w in ipairs(HV.wait) do
        local pc = HV.pc_of(w.pck)
        local a = pc and HV.find(w.kind, w.loc)
        if a then
            HV.apply_hit(a, pc, w.hits, w.at)
        elseif pc and now < w.till then
            keep[#keep + 1] = w
        else
            log.info("world: %s's hit at %s dropped: no %s there on the host", w.name, loc_str(w.loc), w.kind == "r" and "rock" or "tree")
        end
    end
    HV.wait = keep
end

-- Client: where the host's harvestables stand (WFOL / WFOLS / this machine's
-- own blocked spawn) and which foliage component they came from.
function HV.dress_add(ip, loc)
    if not ip or ip == "" or not loc then return end
    local now = clock()
    HV.dress_due = 0
    for _, r in ipairs(HV.recs) do
        if r.ip == ip and d2(r.loc, loc) < 4 then r.t = now return end
    end
    if #HV.recs >= HV.REC_MAX then table.remove(HV.recs, 1) end
    HV.recs[#HV.recs + 1] = { ip = ip, loc = loc, t = now }
end

function HV.rec_near(l)
    local best, bestd = nil, HV.MATCH * HV.MATCH
    for _, r in ipairs(HV.recs) do
        local d = d2(r.loc, l)
        if d <= bestd then best, bestd = r, d end
    end
    return best
end

-- The host's harvestable gets the mesh / material the swing set before
-- FinishSpawningActor (HitFoliageTree @597-711: SetObjectPropertyByName Mesh,
-- Material); Mesh and Material do not replicate, UserConstructionScript gave
-- the client's copy no mesh at all. Returns true, mesh | nil (try later) |
-- false, why.
function HV.dress(a, r)
    local ism = find(r.ip)
    if not ism then return nil, "foliage component not loaded here" end
    local mesh = ue.prop(ism, "StaticMesh")
    if not ue.valid(mesh) then return false, "the foliage component has no mesh" end
    local sm = ue.prop(a, "StaticMesh")
    if not ue.valid(sm) then return false, "no mesh component" end
    ue.set_prop(a, "Mesh", mesh)
    local ok, err = pcall(function() sm:SetStaticMesh(mesh) end)
    if not ok then return false, "SetStaticMesh: " .. tostring(err) end
    if harvest_kind_of(a) == "t" then
        local okm, mat = pcall(function() return ism:GetMaterial(0) end)
        if okm and ue.valid(mat) then
            ue.set_prop(a, "Material", mat)
            pcall(function() sm:SetMaterial(0, mat) end)
        end
    end
    return true, ue.short(mesh)
end

function HV.dress_pass(now)
    if now < HV.dress_due then return end
    HV.dress_due = now + 5
    if #HV.recs == 0 then return end
    -- the watch never reported one here: look for them (places younger than 2 min)
    local young = false
    if not HV.seen_new then
        for _, r in ipairs(HV.recs) do if now - r.t < 120 then young = true break end end
        if young and now - (HV.scanned or -100) >= 2 then
            HV.scanned = now
            HV.scan("t")
            HV.scan("r")
        end
    end
    local open = 0
    for p, e in pairs(HV.live) do
        if not e.dressed then
            local a = find(p)
            if not a then
                HV.live[p] = nil
            elseif ue.role(a) == ue.ROLE_AUTHORITY then
                e.dressed = true   -- this machine's own, not the host's
            elseif ue.valid(ue.prop(ue.prop(a, "StaticMesh"), "StaticMesh")) then
                e.dressed = true
            else
                local l = ue.location(a)
                local r = l and HV.rec_near(l)
                if not r then
                    open = open + 1
                else
                    local ok, what = HV.dress(a, r)
                    if ok then
                        e.dressed = true
                        M.stats.dressed = M.stats.dressed + 1
                        local line = string.format("world: the host's %s %s at %s shown here (mesh %s)",
                            e.kind == "r" and "rock" or "tree", ue.short(a), loc_str(l), tostring(what))
                        if M.stats.dressed <= 5 then log.info("%s", line) else log.debug("%s", line) end
                    else
                        open = open + 1
                        if ok == false and not e.warned then
                            e.warned = true
                            log.warn("world: the host's %s at %s cannot be shown here: %s", e.kind == "r" and "rock" or "tree",
                                loc_str(l), tostring(what))
                        end
                    end
                end
            end
        end
    end
    if open > 0 or young then HV.dress_due = now + 1 end
    -- a felled harvestable goes 30 s after its fall; old places go after 30 min
    if now - (HV.recs_pruned or 0) > 60 then
        HV.recs_pruned = now
        local keep = {}
        for _, r in ipairs(HV.recs) do if now - r.t < 1800 then keep[#keep + 1] = r end end
        HV.recs = keep
    end
end

-- BP_JigComponent.JigTryAddItemSomewhere (post), client: the amount single
-- player code just rolled here (a scrap pile's salvage, @866-1094: 12-20, x2
-- with this player's Harvest Master), sent with WSALV.
function HV.on_try_add(_, _, item_p, count_p)
    if not S or S.role ~= "client" then return end
    local da = obj(item_p)
    if not da then return end
    HV.last_add = { name = ue.short(da), n = math.floor(num(get(count_p), 0)), t = clock() }
end

-- ---------------------------------------------------------------------------

-- BP_MeleePickup.HitFoliageTree / HitFoliageRock(Object, SpawnTransform_Location,
-- PrimitiveComponent, Instance, Hits, out Hit?), post.
local function on_hit_foliage(c, obj_p, at_p, comp_p, inst_p, hits_p)
    if not on("world_harvest") then return end
    local role = S and S.role
    if role ~= "host" and role ~= "client" then return end
    local weapon = c and c:get()
    local who = owner_character(weapon)
    local target = obj(obj_p)
    -- a hit on a harvestable (@289 HitHarvestableObject, ran on this machine)
    if target and ue.class_name(target):find("^BP_HarvestableObject") then
        if role == "host" then
            if who then
                local pc = player_of_character(who)
                remember_hit(target, pc or false)
                if pc then HV.replay[(addr(target) or 0) .. ":" .. (addr(pc) or 0)] = clock() end
            end
        elseif applying == 0 and who and locally_controlled(who) and ue.role(target) ~= ue.ROLE_AUTHORITY then
            -- the host's harvestable: its count is the host's
            HV.relay(target, HV.vec(get(at_p)), math.floor(num(get(hits_p), 1)))
        end
        return
    end
    -- a foliage instance turned into a harvestable in this call
    local ph = pending_harv
    pending_harv = nil
    if not ph or clock() - ph.t > 0.05 or not ph.loc then return end
    local ism = obj(comp_p)
    local ip = path_of(ism)
    if not ip or not level_actor(ue.try(function() return ism:GetOwner() end)) then return end
    local idx = tonumber(get(inst_p))
    local idx_s = idx and string.format("%d", idx) or ""
    if role == "host" then
        HV.prime_actor(HV.find(ph.kind, ph.loc))
        if host_record_fol(ip, ph.loc) then
            Q.all_now("WFOL", pack(ip), loc_str(ph.loc), idx_s)
            M.stats.fol_sent = M.stats.fol_sent + 1
        end
    elseif applying == 0 and who and locally_controlled(who) then
        HV.dress_add(ip, ph.loc)
        if to_host("WHARV", pack(ip), loc_str(ph.loc), ph.kind, idx_s) then M.stats.harv_requests = M.stats.harv_requests + 1 end
        local line = string.format("world: own cut of a %s at %s (instance %s): the host's harvestable comes",
            ph.kind == "r" and "rock" or "tree", loc_str(ph.loc), idx_s)
        if M.stats.harv_requests <= 5 then log.info("%s", line) else log.debug("%s", line) end
    else
        HV.dress_add(ip, ph.loc)   -- another player's swing seen here: the host's harvestable comes too
    end
end

-- Host: the swing's own steps (HitFoliageTree @492-853) for an instance the
-- host's trace did not cut.
local function host_harvest(ism, idx, kind)
    local cls = harvest_class(kind)
    local gps = ue.gameplay_statics()
    if not cls or not gps then return false, "no class" end
    local tf = HV.transform(ism, idx)
    if tf == nil then return false, "no transform" end
    local t = ue.try(function() return tf.Translation end)
    local r = ue.try(function() return tf.Rotation end)
    local s = ue.try(function() return tf.Scale3D end)
    local function q(f, d) return num(ue.try(function() return r[f] end), d) end
    local T = {
        Translation = HV.vec(t),
        Rotation = { X = q("X", 0), Y = q("Y", 0), Z = q("Z", 0), W = q("W", 1) },
        Scale3D = HV.vec(s) or { X = 1, Y = 1, Z = 1 },
    }
    if not T.Translation then return false, "bad transform" end
    local a
    local ok, err = pcall(function() a = gps:BeginDeferredActorSpawnFromClass(ism, cls, T, 1, nil, 0) end)
    if not ok or not ue.valid(a) then return false, "spawn: " .. tostring(err) end
    ue.set_prop(a, "Mesh", ue.prop(ism, "StaticMesh"))
    if kind == "t" then
        local okm, mat = pcall(function() return ism:GetMaterial(0) end)
        if okm and ue.valid(mat) then ue.set_prop(a, "Material", mat) end
    end
    pcall(function() gps:FinishSpawningActor(a, T, 0) end)
    pcall(function() ism:RemoveInstance(idx) end)
    HV.prime_actor(a)
    return true, ue.short(a)
end

-- WHARV|ism|x,y,z|t/r|instance index   (client -> host)
local function harv_msg(f, pc)
    if not is_host() or not on("world_harvest") then return end
    local ip = unpack_path(f[1])
    local loc = parse_loc(f[2])
    local kind = (f[3] == "r") and "r" or "t"
    local hint = tonumber(f[4])
    if not loc then return end
    local what = kind == "t" and "tree" or "rock"
    local who = ue.short(pc)
    ue.delay("world-harv", HARV_WAIT_MS, function()
        if fol_seen[ip .. "|" .. loc_str(loc)] then
            log.debug("world: %s's cut of a %s at %s: the host's own trace cut it already", who, what, loc_str(loc))
            return
        end
        local ism = find(ip)
        if not ism then
            log.warn("world: %s cut a %s at %s: its foliage component is not loaded on the host (%s)", who, what, loc_str(loc), ip)
            return
        end
        local idx, how = HV.instance(ism, loc, hint)
        if not idx then
            log.warn("world: %s cut a %s at %s that the host cannot find: %s", who, what, loc_str(loc), tostring(how))
            return
        end
        local ok, made = host_harvest(ism, idx, kind)
        if ok then
            M.stats.harv_host = M.stats.harv_host + 1
            if host_record_fol(ip, loc) then Q.all_now("WFOL", pack(ip), loc_str(loc), string.format("%d", idx)) end
            log.info("world: %s cut a %s the host's trace missed: done on the host (%s, instance %d found by %s)",
                who, what, tostring(made), idx, tostring(how))
        else
            log.warn("world: harvest for %s failed: %s", who, tostring(made))
        end
    end)
end

local function fol_apply(ip, loc, hint)
    local ism = find(ip)
    if not ism then return nil end
    local idx, how = HV.instance(ism, loc, hint)
    if not idx then
        -- normally this machine's own swing removed it already
        local line = string.format("world: felled instance at %s not removed here (%s)", loc_str(loc), tostring(how))
        if M.stats.fol_miss <= 3 then log.info("%s", line) else log.debug("%s", line) end
        return false
    end
    apply(function() ism:RemoveInstance(idx) end)
    M.stats.fol_applied = M.stats.fol_applied + 1
    return true
end

-- WFOL|ism|x,y,z|instance index   (host -> clients)
local function fol_msg(f)
    if S.role ~= "client" or not on("world_harvest") then return end
    local ip, loc = unpack_path(f[1]), parse_loc(f[2])
    if not loc then return end
    HV.dress_add(ip, loc)
    local hint = tonumber(f[3])
    if fol_apply(ip, loc, hint) == nil then later("fol", ip, { loc = loc, idx = hint }) end
end

local function fols_msg(f)
    if S.role ~= "client" or not on("world_harvest") then return end
    local ip = unpack_path(f[1])
    local n = 0
    for _, s in ipairs(split(f[2], ";")) do
        local loc = parse_loc(s)
        if loc then
            HV.dress_add(ip, loc)
            local r = fol_apply(ip, loc)
            if r == nil then later("fol", ip, loc) elseif r then n = n + 1 end
        end
    end
    if n > 0 then log.info("world: %d felled tree(s) / rock(s) removed here as on the host", n) end
end

local function snapshot_fol(pc)
    local n = 0
    for ip, list in pairs(fol_removed) do
        send_list(pc, "WFOLS", list, pack(ip))
        n = n + #list
    end
    return n
end

-- Scrap metal piles: salvage is a hold interaction on the salvaging machine.
-- CreateNotificationUI(..., __WorldContext) (post) with the pile as context
-- marks the moment (@1369, right after the local add).
local function salvaged(s) return ue.prop(s, "Salvaged?") == true end

local function apply_salvage(s)
    if salvaged(s) then return false end
    ue.set_prop(s, "Salvaged?", true)
    local ps = ue.prop(s, "ParticleSystem")
    if ue.valid(ps) then pcall(function() ps:K2_DestroyComponent(s) end) end
    return true
end

local function on_notification(_, _, _, _, _, _, wco_p)
    local s = obj(wco_p)
    if not s then return end
    local cname = ue.class_name(s)
    -- a tool container (gun locker, axe crate) is marked searched only after
    -- its OpenContainer (@1238 -> @2192), then shows the XP notification
    if cname:find("^BP_ToolRequired_") then
        on_open_container({ get = function() return s end })
        return
    end
    if not on("world_harvest") then return end
    if not cname:find("^BP_HarvestableObject_ScrapMetal") or not level_actor(s) then return end
    local p = path_of(s)
    if not p then return end
    if S.role == "client" then
        if applying ~= 0 then return end
        -- the amount this machine's single-player code just rolled (with this
        -- player's own Harvest Master); its local add never stays (sdc_consume)
        local la = HV.last_add
        local n = (la and la.name == "DA_ScrapMetal" and clock() - la.t < 0.5) and la.n or nil
        HV.last_add = nil
        -- (also the pile's "No more Scrap Metal" note: the host ignores a salvaged pile)
        if to_host("WSALV", pack(p), n and tostring(n) or "") then
            M.stats.salvage = M.stats.salvage + 1
            if n then
                log.info("world: salvaged %s here: scrap metal x%d, the host adds it", ue.short(s), n)
            else
                log.debug("world: %s note here (no add seen): sent to the host", ue.short(s))
            end
        end
    elseif is_host() then
        to_clients("WSALV", pack(p))
    end
end

local function salv_msg(f, pc)
    if not on("world_harvest") then return end
    if S.role == "client" then
        for _, e in ipairs(split(f[1], ";")) do
            local p = unpack_path(e)
            local s = find(p)
            if s then apply_salvage(s) else later("salv", p) end
        end
        return
    end
    local p = unpack_path(f[1])
    local s = find(p)
    if not s or not is_host() or salvaged(s) then return end   -- the host (or another player) took it first
    apply_salvage(s)
    local l = ue.location(s)
    if l then pcall(function() s:Svr_PlaySound(l) end) end   -- authority: MC_PlaySound for everyone
    -- the pile's own amounts (@866: 12-20, x2 with Harvest Master): the
    -- client's own roll (its skill tree) when it sent one, else the base roll
    local n = math.floor(num(f[2], 0))
    local rolled = n >= 1 and n <= 80
    if not rolled then n = math.random(12, 20) end
    local pawn = ue.pawn_of(pc)
    if not ue.valid(cache.scrap) then cache.scrap = load_object(PATH.DA_SCRAP) end
    if pawn and cache.scrap then
        log.info("world: %s salvaged %s: scrap metal x%d (%s)", ue.short(pc), ue.short(s), n,
            rolled and "the client's roll" or "rolled here")
        grant(pawn, cache.scrap, n)
    end
    M.stats.salvage = M.stats.salvage + 1
    to_others(pc, "WSALV", pack(p))
end

local function snapshot_salvage(pc)
    local items = {}
    for _, s in ipairs(ue.find_all("BP_HarvestableObject_ScrapMetal_C")) do
        if level_actor(s) and salvaged(s) then
            local p = path_of(s)
            if p then items[#items + 1] = pack(p) end
        end
    end
    send_list(pc, "WSALV", items)
    return #items
end

-- ===========================================================================
-- Trash piles, explosive barrels, infestations
-- ===========================================================================

-- TrashObject ObjectDestroyed (post): destroyed on this machine.
local function on_trash_destroyed(c)
    if not on("world_objects") then return end
    local t = c and c:get()
    if not level_actor(t) then return end
    local p = path_of(t)
    if not p then return end
    if S.role == "client" then
        if applying == 0 then to_host("WTRASH", pack(p)) end
    elseif is_host() then
        to_clients("WTRASH", pack(p))
        M.stats.trash = M.stats.trash + 1
    end
end

-- BP_MeleePickup.HitTrashObject(Actor, Dmg, out Hit?), post, host: who hit it.
local function on_hit_trash(c, actor_p)
    if not is_host() or not on("world_objects") then return end
    local t = obj(actor_p)
    local who = owner_character(c and c:get())
    if t and who then remember_hit(t, player_of_character(who) or false) end
end

local function trash_hide(t)
    if ue.prop(t, "IsDestroyed") == true then return end
    ue.set_prop(t, "IsDestroyed", true)
    -- the game's own load path: hidden, no collision (@193-222)
    apply(function() t:ActorLoaded() end)
end

local function trash_msg(f, pc)
    if not on("world_objects") then return end
    if S.role == "client" then
        for _, e in ipairs(split(f[1], ";")) do
            local p = unpack_path(e)
            local t = find(p)
            if t then trash_hide(t) else later("trash", p) end
        end
        return
    end
    local p = unpack_path(f[1])
    if not is_host() then return end
    -- a client broke it with its own swing: the host's copy, if its trace
    -- missed, breaks the game's way (scrap for that client through the scope)
    ue.delay("world-trash", TRASH_WAIT_MS, function()
        local t = find(p)
        if not t or ue.prop(t, "IsDestroyed") == true then return end
        remember_hit(t, pc)
        ue.set_prop(t, "Health", 0.0)
        local ok = pcall(function() t[PATH.TRASH_DAMAGED](t, 0.0) end)
        log.info("world: trash %s broken by %s on the host too (ok=%s)", ue.short(t), ue.short(pc), tostring(ok))
    end)
end

local function snapshot_trash(pc)
    local items = {}
    for _, t in ipairs(ue.find_all("TrashObject_C")) do
        if level_actor(t) and ue.prop(t, "IsDestroyed") == true then
            local p = path_of(t)
            if p then items[#items + 1] = pack(p) end
        end
    end
    send_list(pc, "WTRASH", items)
    return #items
end

-- ---------------------------------------------------------------------------
-- Random infestations. BP_InfestationManager (level actor, not replicated)
-- after the EMS load + 4 s: if every BP_PrimaryInfestation is destroyed it
-- broadcasts Spawn on the 12 BP_RandomInfestationSpawnPoint_C; each rolls
-- (RandomSpawn @0: Difficulty.RandomInfestations, 0-100 <= RandomChance x
-- Difficulty.RandomInfestationsMultiplier, no 'NoSpawn' actor within 5 m) and
-- spawns a BP_Infestation_C at its own transform (@67-458: NormalMesh,
-- DestroyedMesh, UniqueLootSets, AISpawningTransforms, RandomInfestation? =
-- true) or destroys itself. BP_Infestation does not replicate and saves
-- itself only when random (BeginPlay @5448 SetActorSaveProperties(self,
-- RandomInfestation?)): every machine rolled its own nests, and the host's
-- saved ones existed on the host only. Its loot pile is the nest's own
-- inventory, which a client reaches through the host's object.
-- Now: a client's spawn points spawn nothing (PF block, class swap); the
-- host's random nests (spawned now or loaded by EMS) replicate (always
-- relevant: their map marker), so the client interacts with the host's
-- object. Mesh, DestroyedMesh and RandomInfestation? do not replicate: the
-- host sends them (WRINF) and the client dresses its copy. A random nest is
-- named on the wire by its place: ~R~x,y,z.
-- ---------------------------------------------------------------------------

function RI.is_random(o)
    return ue.valid(o) and ue.class_name(o) == RI.CLASS and ue.is_runtime_spawned(o)
end

function RI.key_of(o)
    local l = ue.location(o)
    return l and (RI.PREFIX .. loc_str(l)) or nil
end

-- An infestation (or barrel) as named on the wire: its level path, or ~R~x,y,z.
function RI.key(o)
    if level_actor(o) then
        local p = raw_path(o)
        return p and pack(p) or nil
    end
    if RI.is_random(o) then return RI.key_of(o) end
    return nil
end

function RI.is_key(k) return type(k) == "string" and k:sub(1, #RI.PREFIX) == RI.PREFIX end

-- The object a key names here (nil when it is not here / not yet).
function RI.find(k)
    if not RI.is_key(k) then return find(unpack_path(k)) end
    local loc = parse_loc(k:sub(#RI.PREFIX + 1))
    if not loc then return nil end
    local best, bestd = nil, RI.MATCH * RI.MATCH
    local function consider(a)
        local l = ue.location(a)
        if l then
            local d = d2(l, loc)
            if d <= bestd then best, bestd = a, d end
        end
    end
    for p in pairs(RI.live) do
        local a = find(p)
        if a then consider(a) else RI.live[p] = nil end
    end
    if not best then
        for _, a in ipairs(RI.scan()) do consider(a) end
    end
    return best
end

-- NotifyOnNewObject (BP_Infestation and children): a runtime nest made here or
-- arriving from the host. Path only (the placed ones load with the level).
function RI.on_new(o)
    if not S or (S.role ~= "host" and S.role ~= "client") then return end
    if not ue.is_runtime_spawned(o) or ue.class_name(o) ~= RI.CLASS then return end
    local p = raw_path(o)
    if not p or p:find("Default__", 1, true) then return end
    RI.live[p] = { t = clock() }
    RI.due = 0
    RI.seen_new = true
end

-- The runtime nests by FindAllOf (at most once a second); they join RI.live.
function RI.scan()
    local out = {}
    for _, a in ipairs(ue.find_all_recent(RI.CLASS, 1.0)) do
        if RI.is_random(a) then
            out[#out + 1] = a
            local p = path_of(a)
            if p and not RI.live[p] then RI.live[p] = { t = clock() } end
        end
    end
    return out
end

local function mesh_path(m) return ue.valid(m) and ue.path(m) or "" end

function RI.item(r)
    return string.format("%s>%s>%s>%s", loc_str(r.loc), r.nm or "", r.dm or "", r.d and "1" or "0")
end

-- Host: this random nest replicates from now on (the camps' way).
function RI.host_add(a)
    local key = RI.key_of(a)
    if not key then return false end
    if not ue.prop(a, "bReplicates") then
        if not pcall(function() a:SetReplicates(true) end) then
            log.err_throttled("world.rinf", "world: random infestation %s cannot replicate", ue.short(a))
            return false
        end
    end
    ue.set_prop(a, "bAlwaysRelevant", true)
    ue.set_prop(a, "NetCullDistanceSquared", PF.PREFAB_CULL * PF.PREFAB_CULL)
    ue.set_prop(a, "NetUpdateFrequency", 1.0)
    pcall(function() a:ForceNetUpdate() end)
    local r = {
        loc = ue.location(a), name = ue.short(a),
        nm = mesh_path(ue.prop(a, "NormalMesh")), dm = mesh_path(ue.prop(a, "DestroyedMesh")),
        d = ue.prop(a, "IsDestroyed?") == true,
    }
    RI.host[key] = r
    M.stats.rinf = M.stats.rinf + 1
    to_clients("WRINF", RI.item(r))
    log.info("world: random infestation %s at %s replicates to the clients (%s%s)", r.name, loc_str(r.loc),
        r.nm:match("([^%./]+)$") or "default mesh", r.d and ", destroyed" or "")
    return true
end

-- Host pass: new runtime nests (watch), and every 10 s a scan for missed ones.
function RI.host_pass(now)
    if now < RI.due then return end
    RI.due = now + 10
    if now - RI.scan_at >= 10 then
        RI.scan_at = now
        RI.scan()
    end
    for p, e in pairs(RI.live) do
        if not e.done and now - e.t >= 0.2 then
            local a = find(p)
            if not a then
                RI.live[p] = nil
            elseif RI.is_random(a) and ue.role(a) == ue.ROLE_AUTHORITY then
                e.done = RI.host_add(a)
                if not e.done then RI.due = now + 1 end
            else
                e.done = true
            end
        elseif not e.done then
            RI.due = math.min(RI.due, now + 0.25)
        end
    end
end

function RI.snapshot(pc)
    local items = {}
    for _, r in pairs(RI.host) do items[#items + 1] = RI.item(r) end
    send_list(pc, "WRINF", items)
    return #items
end

-- Host: a random nest's destruction (Event_OnDestroyed) for later snapshots.
function RI.host_destroyed(key)
    local r = RI.host[key]
    if r then r.d = true end
end

-- WRINF|x,y,z>NormalMesh>DestroyedMesh>0|1;...   (host -> clients)
function RI.msg(f)
    if S.role ~= "client" or not on("world_objects") then return end
    local n = 0
    for _, e in ipairs(split(f[1], ";")) do
        local ls, nm, dm, d = e:match("^([^>]*)>([^>]*)>([^>]*)>([01])$")
        local loc = parse_loc(ls)
        if loc then
            local key = RI.PREFIX .. loc_str(loc)
            local r = RI.recs[key] or {}
            r.loc, r.nm, r.dm, r.d, r.t = loc, nm, dm, (d == "1") or r.d == true, clock()
            RI.recs[key] = r
            n = n + 1
        end
    end
    RI.due = 0
    log.info("world: the host described %d random infestation(s) (%s)", n, f[1]:sub(1, 120))
end

-- Client: a WINF for a random nest (destroyed on the host).
function RI.mark_destroyed(key)
    local loc = parse_loc(key:sub(#RI.PREFIX + 1))
    if not loc then return end
    local r = RI.recs[key] or { loc = loc, t = clock() }
    r.d = true
    RI.recs[key] = r
    RI.due = 0
end

function RI.rec_near(l)
    local best, bestd = nil, RI.MATCH * RI.MATCH
    for key, r in pairs(RI.recs) do
        local d = d2(r.loc, l)
        if d <= bestd then best, bestd = key, d end
    end
    return best
end

local function load_mesh(p)
    if type(p) ~= "string" or p == "" then return nil end
    local m = ue.find_object(p)
    if m then return m end
    return load_object(p)
end

-- Client: the host's nest gets what its spawn point gave it on the host
-- (@139-397: NormalMesh, DestroyedMesh, RandomInfestation?); its
-- UserConstructionScript ran without them (mesh @35, dust @171). Destroyed
-- on the host: the game's load path (Event_OnDestroyed(None, true)).
function RI.dress(a, key, r)
    local nm, dm = load_mesh(r.nm), load_mesh(r.dm)
    if nm then ue.set_prop(a, "NormalMesh", nm) end
    if dm then ue.set_prop(a, "DestroyedMesh", dm) end
    ue.set_prop(a, "RandomInfestation?", true)
    local sm = ue.prop(a, "StaticMesh")
    local want = r.d and dm or nm
    if want and ue.valid(sm) then pcall(function() sm:SetStaticMesh(want) end) end
    local dust = ue.prop(a, "NS_InfestationDust")
    if ue.valid(dust) then pcall(function() dust:SetVisibility(not r.d, false) end) end
    if r.d and ue.prop(a, "IsDestroyed?") ~= true then
        apply(function() a:Event_OnDestroyed(nil, true) end)
    end
    RI.dressed[addr(a) or -1] = key .. (r.d and "|d" or "")
end

function RI.client_pass(now)
    if now < RI.due then return end
    RI.due = now + 5
    if next(RI.recs) == nil then return end
    if not RI.seen_new and now - RI.scan_at >= 5 then
        RI.scan_at = now
        RI.scan()
    end
    local open = 0
    for p in pairs(RI.live) do
        local a = find(p)
        if not a then
            RI.live[p] = nil
        elseif ue.role(a) ~= ue.ROLE_AUTHORITY then
            local l = ue.location(a)
            local key = l and RI.rec_near(l)
            if not key then
                open = open + 1
            else
                local r = RI.recs[key]
                local want = key .. (r.d and "|d" or "")
                if RI.dressed[addr(a) or -1] ~= want then
                    RI.dress(a, key, r)
                    M.stats.rinf_shown = M.stats.rinf_shown + 1
                    log.info("world: the host's random infestation at %s shown here (%s, %s)", loc_str(l),
                        tostring((r.nm or ""):match("([^%./]+)$") or "default mesh"), r.d and "destroyed" or "standing")
                end
            end
        end
    end
    if open > 0 then RI.due = now + 1 end
end

-- ---------------------------------------------------------------------------
-- BP_EventManager on every machine (local authority): its Server events run
-- on a client too. Airdrop plane and jet: the client's spawn is blocked (PF);
-- the host's plane / crates replicate (bAlwaysRelevant), its jets are made
-- always relevant here. The blood moon is a 5% roll at each sunset
-- (Event_StartBloodMoon @7344 <= BloodMoonChance) on each machine: a client's
-- own roll is off (its BloodMoonChance = 0, the game's variable) and the
-- host's SetBloodMoon (post) is run on the client's manager (WBMOON): UDS
-- modifier, notification, BloodMoon broadcast to the zombies.
-- Dynamic events (BP_PrefabSpawner_Dynamic) are prefabs (PF); their spawn
-- sound, notice, map marker and the wreck's range: sdc_events. The distant
-- explosion sounds (Explosion_Spawn) stay each machine's own ambience.
-- ---------------------------------------------------------------------------

function EV.manager()
    local p = EV.manager_path
    local m = p and find(p)
    if m then return m end
    local now = clock()
    if now < (EV.next_try or 0) then return nil end
    EV.next_try = now + 10
    for _, a in ipairs(ue.find_all("BP_EventManager_C")) do
        if ue.valid(a) then
            EV.manager_path = path_of(a)
            return a
        end
    end
    return nil
end

-- Client (2 s): this machine's own blood moon roll stays off.
function EV.client_pass()
    local m = EV.manager()
    if not m then return end
    local c = tonumber(ue.prop(m, "BloodMoonChance"))
    if c and c ~= 0 then
        ue.set_prop(m, "BloodMoonChance", 0.0)
        local p = EV.manager_path or "?"
        if not EV.off_logged[p] then
            EV.off_logged[p] = true
            log.info("world: this client's own blood moon roll is off (was %.0f%%); the host's comes", c)
        end
    end
end

-- BP_EventManager.SetBloodMoon(BloodMoon?), post, host.
function EV.on_blood_moon(c, on_p)
    if not is_host() or not on("world_objects") then return end
    local v = get(on_p) == true
    EV.moon = v
    M.stats.moon = M.stats.moon + 1
    to_clients("WBMOON", v and "1" or "0")
    log.info("world: blood moon %s on the host: sent to the clients", v and "rises" or "ends")
end

-- WBMOON|1|0   (host -> clients)
function EV.moon_msg(f)
    if S.role ~= "client" or not on("world_objects") then return end
    local v = f[1] == "1"
    -- (the host's manager calls SetBloodMoon(false) at every sunrise once a
    -- blood moon bound it: nothing to end here unless one is shown)
    if (EV.shown or false) == v then return end
    local m = EV.manager()
    if not m then
        log.info("world: blood moon %s on the host: no event manager here yet", v and "on" or "off")
        return
    end
    local ok = apply(function() m:SetBloodMoon(v) end)
    EV.shown = v
    M.stats.moon = M.stats.moon + 1
    log.info("world: blood moon %s as on the host (ok=%s)", v and "rises" or "ends", tostring(ok))
end

function EV.snapshot(pc)
    if not EV.moon then return 0 end
    Q.send(pc, "WBMOON", "1")
    return 1
end

-- Host: a new jet fly-by (replicated, but relevant only within 150 m of a
-- player while it flies 300-600 m up) reaches every client.
function EV.on_new_jet(o)
    if not is_host() then return end
    local p = raw_path(o)
    if p and not p:find("Default__", 1, true) then EV.jets[#EV.jets + 1] = p end
end

function EV.host_pass()
    if #EV.jets == 0 then return end
    local list = EV.jets
    EV.jets = {}
    for _, p in ipairs(list) do
        local a = find(p)
        if a then
            ue.set_prop(a, "bAlwaysRelevant", true)
            pcall(function() a:ForceNetUpdate() end)
            M.stats.jets = M.stats.jets + 1
            local line = string.format("jets: jet %s flies over: made always relevant, replicates to %d client(s)",
                ue.short(a), #remote_pcs())
            if M.stats.jets <= 20 then log.info("%s", line) else log.debug("%s", line) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Airdrops and jets on the host: the game's own timers, logged (0.6.62)
-- ---------------------------------------------------------------------------
-- BP_EventManager (work\re):
--   AirdropSpawn (BeginPlay @1759, and after a roll @5253) -> Delay 1 s (@5289)
--     -> Difficulty.Airdrop off: nothing (@1822); else AirdropTimeToSpawn =
--     RandomFloatInRange(MinimumTimeAirdrop, MaximumTimeAirdrop) x 60 s,
--     a one-shot timer -> SpawnAirdrop (@1832-2247)
--   SpawnAirdrop (the timer) -> Difficulty.Airdrop off: timer cleared, the end
--     (@3431 -> @5268); RandomBoolWithWeight(NormalizeToRange(ChanceOfAirdrop,
--     0, 1)) fails: THE END - no new timer until the world is loaded again
--     (@3628 pop_flow_if_not); DaysSurvived <= 5: no plane, AirdropSpawn (new
--     timer, @3695 -> @5233); else the AirdropAircraft (@4179, MaxAirdropsToSpawn
--     1-3 crates) and AirdropSpawn.
--   Jet_Spawn (BeginPlay @1729, after each fly-by @1560) -> JetTimeToSpawn =
--     30-3600 s -> SpawnJet: MaxNumberOfJetsToSpawn jets 1-3 s apart (@293-1650).
-- The client's own manager runs the same timers; its plane and jets are
-- blocked (PF.block_spawner, client only: IsServer false). The host's
-- replicate: the plane and the crates (bReplicates), the jets (made always
-- relevant, EV.host_pass).

EV.AIRCRAFT = "/Game/Blueprints/Events/Airdrop/AirdropAircraft.AirdropAircraft_C"
EV.CRATE = "/Game/Inventory/Containers/Containers/Airdrop/Master_AirdropContainer.Master_AirdropContainer_C"
EV.CU = "/Script/AutoSettings.Default__ConsoleUtils"
EV.SHOWN = { AirdropAircraft_C = "plane", Master_AirdropContainer_C = "crate", BP_Event_JetActor_C = "jet" }
EV.ad = { resched_t = nil, plane_t = nil, landed = {}, seen = {}, last = "none yet", jet_at = nil }
EV.crates = {}      -- host: [crate path] = { o, key = root "x,y,z", st = fall|land|rest, last, sent, next }
EV.ccrates = {}     -- client: [root key] = { loc, rot, flag, path }: the host's place of that crate
EV.crate_at = 0     -- host: next crate pass

-- A console variable through the game's helper (ConsoleUtils, as its Blueprints read them).
function EV.cvar(kind, name)
    local cu = ue.find_object(EV.CU)
    if not cu then return nil end
    return ue.try(function() return cu["Get" .. kind .. "CVar"](cu, FName(name)) end)
end

function EV.set_cvar(kind, name, v)
    local cu = ue.find_object(EV.CU)
    if cu and pcall(function() cu["Set" .. kind .. "CVar"](cu, FName(name), v) end) and EV.cvar(kind, name) == v then
        return true
    end
    local s = kind == "Bool" and (v and "1" or "0") or tostring(v)
    return (ue.exec(name .. " " .. s))
end

-- RandomBoolWithWeight(NormalizeToRange(cvar, 0, 1)): the weight is the cvar itself.
function EV.chance_text()
    local c = tonumber(EV.cvar("Float", "Difficulty.ChanceOfAirdrop"))
    if not c then return "?" end
    local pct = math.max(0, math.min(1, c)) * 100
    return string.format("%.0f%%", pct) .. (c > 1 and string.format(" (cvar %g)", c) or "")
end

function EV.days()
    local m = EV.manager()
    local out = {}
    if m and pcall(function() m:GetDaysSurvived(out) end) and tonumber(out.DaysSurvived) then
        return tonumber(out.DaysSurvived)
    end
    return tonumber(ue.prop(ue.local_pc(), "DaysSurvived"))
end

-- Seconds left on a timer bound to one of the manager's functions (-1: none).
function EV.left(m, fname)
    local ksl = ue.ksl()
    return tonumber(ksl and ue.try(function() return ksl:K2_GetTimerRemainingTime(m, fname) end))
end

function EV.where(a)
    local l = ue.try(function() return a:K2_GetActorLocation() end)
    return l and v3(l) and loc_str(v3(l)) or "?"
end

-- A crate's mesh (it is what falls, rolls and is looted): world location, rotation.
function EV.crate_tf(a)
    local m = ue.prop(a, "StaticMesh")
    if not ue.valid(m) then return nil end
    local l = v3(ue.try(function() return m:K2_GetComponentLocation() end))
    local r = ue.try(function() return m:K2_GetComponentRotation() end)
    local rot = r and {
        Pitch = tonumber(ue.try(function() return r.Pitch end)) or 0,
        Yaw = tonumber(ue.try(function() return r.Yaw end)) or 0,
        Roll = tonumber(ue.try(function() return r.Roll end)) or 0,
    }
    return l, rot or { Pitch = 0, Yaw = 0, Roll = 0 }
end

function EV.crate_where(a)
    local l = EV.crate_tf(a)
    return l and loc_str(l) or EV.where(a)
end

-- BP_EventManager.AirdropSpawn (post, host): the next timer is set 1 s later.
function EV.on_airdrop_timer()
    if not is_host() then return end
    EV.ad.resched_t = clock()
    ue.delay("world-adtimer", 1500, function()
        local m = EV.manager()
        if not m then return end
        local on_ = EV.cvar("Bool", "Difficulty.Airdrop")
        if on_ == false then
            log.info("airdrop: Difficulty.Airdrop=0: the game sets no airdrop timer")
            return
        end
        local t = tonumber(ue.prop(m, "AirdropTimeToSpawn")) or -1
        log.info("airdrop: next roll in %.1f min (Difficulty.Airdrop=%s, chance %s, %s-%s min; then DaysSurvived > 5, now %s)",
            t / 60, tostring(on_), EV.chance_text(), tostring(EV.cvar("Float", "Difficulty.MinimumTimeAirdrop")),
            tostring(EV.cvar("Float", "Difficulty.MaximumTimeAirdrop")), tostring(EV.days()))
    end)
end

-- BP_EventManager.SpawnAirdrop (post, host: the timer's, or sdcoop_airdrop's): the roll.
function EV.on_airdrop_roll()
    if not is_host() then return end
    M.stats.ad_rolls = M.stats.ad_rolls + 1
    local now = clock()
    local plane = EV.ad.plane_t ~= nil and now - EV.ad.plane_t < 0.5
    local resched = EV.ad.resched_t ~= nil and now - EV.ad.resched_t < 0.5
    EV.ad.plane_t, EV.ad.resched_t = nil, nil
    local days = EV.days()
    local line
    if EV.cvar("Bool", "Difficulty.Airdrop") == false then
        line = "skipped: Difficulty.Airdrop=0 (no new timer)"
    elseif plane then
        line = string.format("ok (chance %s), days survived %s: plane spawned%s", EV.chance_text(), tostring(days),
            resched and ", next timer set" or "")
    elseif resched then
        line = string.format("ok (chance %s), but days survived %s <= 5: no plane; next timer set", EV.chance_text(), tostring(days))
    else
        line = string.format("FAILED (chance %s), days survived %s: no plane, and the game sets no new timer: "
            .. "no more airdrops until the world is loaded again (BP_EventManager @3628)", EV.chance_text(), tostring(days))
    end
    EV.ad.last = line
    log.info("airdrop: roll %s", line)
end

-- BeginDeferredActorSpawnFromClass by the manager / a plane (host, from on_spawn).
function EV.on_spawn_by(wcls, class_p)
    local cls = get(class_p)
    local cname = ue.valid(cls) and ue.short(cls) or ""
    if wcls == "BP_EventManager_C" and cname:find("^AirdropAircraft") then
        EV.ad.plane_t = clock()
        ue.delay("world-adplane", 500, function() EV.log_new("AirdropAircraft_C", "plane spawned") end)
    elseif wcls ~= "BP_EventManager_C" and cname:find("AirdropContainer", 1, true) then
        ue.delay("world-adcrate", 500, function() EV.log_new("Master_AirdropContainer_C", "crate dropped") end)
    end
end

-- Host: the new planes / crates, once each.
function EV.log_new(cls, what)
    for _, a in ipairs(ue.find_all(cls)) do
        local p = ue.valid(a) and path_of(a)
        if p and not EV.ad.seen[p] and not p:find("Default__", 1, true) then
            EV.ad.seen[p] = true
            if cls == "AirdropAircraft_C" then M.stats.ad_planes = M.stats.ad_planes + 1
            else M.stats.ad_crates = M.stats.ad_crates + 1 end
            log.info("airdrop: %s %s at %s: replicates to %d client(s) (bReplicates=%s, always relevant=%s)",
                what, ue.short(a), EV.where(a), #remote_pcs(), tostring(ue.prop(a, "bReplicates")),
                tostring(ue.prop(a, "bAlwaysRelevant")))
            if cls ~= "AirdropAircraft_C" then EV.crate_track(a) end
        end
    end
end

-- Master_AirdropContainer.ReceiveHit (post): its landing (@1138 DoOnce -> parachute off), once per crate.
function EV.on_crate_hit(c)
    local a = c and c:get()
    local k = a and addr(a)
    if not k or EV.ad.landed[k] then return end
    EV.ad.landed[k] = true
    if is_host() then
        log.info("airdrop: crate %s landed at %s: replicates to %d client(s)", ue.short(a), EV.crate_where(a), #remote_pcs())
        if on("world_prefabs") then EV.crate_landed(a) end
    elseif S and S.role == "client" then
        log.info("airdrop: this machine's copy of the host's crate %s touched down at %s (the host's place follows)",
            ue.short(a), EV.crate_where(a))
    end
end

-- ---------------------------------------------------------------------------
-- Airdrop crates: one place for both (0.6.68)
-- ---------------------------------------------------------------------------
-- Master_AirdropContainer (bReplicates, bReplicateMovement, always relevant;
-- not saved): its root is BP_MasterObject's DefaultSceneRoot; the StaticMesh
-- under it simulates physics (bSimulatePhysics, LinearDamping 1, hit events),
-- the Parachute, the smoke (ParticleSystem) and the Magnifier hang on the
-- mesh. A simulating child moves on its own: the root stays at the drop point,
-- so the replicated movement (the root's) never changes and carries no
-- physics (bRepPhysics false) - every machine's crate fell and rolled with its
-- own physics; on a slope the client's ended elsewhere (its loot too).
--   * host: a crate is tracked from its drop / landing (ReceiveHit); at the
--     landing its mesh's transform goes to the clients ("l"), when it has
--     stopped (< 3 cm in 1 s) once more ("s"); a resting crate is looked at
--     every 5 s and sent again if it was pushed. Physics stays the game's.
--   * client: the host's copy is found by its root (the drop point: the
--     same on both; a replicated runtime actor's name is not); its mesh's
--     physics goes off and the mesh goes to the host's transform (teleport),
--     the parachute off as at its own landing (@15-49); looked at again every
--     2 s. WCRATE|root x,y,z|mesh x,y,z|pitch,yaw,roll|l/s/f
--   * join: every crate; a falling one ("f") keeps its physics.

-- Host: a crate to watch.
function EV.crate_track(a)
    local p = path_of(a)
    if not p or p:find("Default__", 1, true) then return nil end
    local c = EV.crates[p]
    if not c then
        local r = v3(ue.try(function() return a:K2_GetActorLocation() end))
        if not r then return nil end
        c = { o = a, key = loc_str(r), st = "fall", next = clock() + 3 }
        EV.crates[p] = c
    end
    return c
end

-- Host: its mesh's transform to the clients (or one client).
function EV.crate_send(c, flag, pc)
    local loc, rot = EV.crate_tf(c.o)
    if not loc then return false end
    local r = string.format("%.1f,%.1f,%.1f", rot.Pitch, rot.Yaw, rot.Roll)
    if pc then Q.send(pc, "WCRATE", c.key, loc_str(loc), r, flag)
    else to_clients("WCRATE", c.key, loc_str(loc), r, flag) end
    if not pc then c.sent = loc end
    M.stats.crate_sent = M.stats.crate_sent + 1
    return true, loc
end

-- Host: ReceiveHit (its first): on the ground; the place now, the final one when it stops.
function EV.crate_landed(a)
    local c = EV.crate_track(a)
    if not c or c.st ~= "fall" then return end
    c.st = "land"
    c.last = EV.crate_tf(a)
    c.next = clock() + 1
    EV.crate_send(c, "l")
end

-- Host (each tick, at most once a second).
function EV.crate_pass(now)
    if next(EV.crates) == nil or now < EV.crate_at then return end
    EV.crate_at = now + 1
    for p, c in pairs(EV.crates) do
        if not ue.valid(c.o) then
            EV.crates[p] = nil   -- looted and gone, or the world changed
        elseif now >= c.next then
            local loc = EV.crate_tf(c.o)
            if loc then
                local still = c.last ~= nil and d2(loc, c.last) < 9
                c.last = loc
                if c.st == "rest" then
                    -- pushed (a zombie, a blast): wait until it stops again
                    if not still or (c.sent and d2(loc, c.sent) > 400) then c.st, c.next = "land", now + 1
                    else c.next = now + 5 end
                elseif still then
                    -- (a crate without a hit event - in a tree, on a roof - stops too)
                    c.st, c.next = "rest", now + 5
                    local ok = EV.crate_send(c, "s")
                    local line = string.format("airdrop: crate %s settled at %s: its place sent to %d client(s)",
                        ue.short(c.o), loc_str(loc), #remote_pcs())
                    if ok and M.stats.crate_sent <= 30 then log.info("%s", line) else log.debug("%s", line) end
                else
                    c.next = now + (c.st == "fall" and 3 or 1)
                end
            end
        end
    end
end

-- Join: every crate (FindAllOf once per join).
function EV.crate_snapshot(pc)
    local n = 0
    for _, a in ipairs(ue.find_all("Master_AirdropContainer_C")) do
        local c = ue.valid(a) and EV.crate_track(a)
        if c and EV.crate_send(c, c.st == "fall" and "f" or "s", pc) then n = n + 1 end
    end
    return n
end

-- Client: the host's copy of a crate, by its root (the drop point), within 1.5 m.
function EV.crate_find(key)
    local k = parse_loc(key)
    if not k then return nil end
    local best, bd = nil, 150 * 150
    for _, a in ipairs(ue.find_all("Master_AirdropContainer_C")) do
        if ue.valid(a) and ue.role(a) ~= ue.ROLE_AUTHORITY then
            local r = v3(ue.try(function() return a:K2_GetActorLocation() end))
            local d = r and d2(r, k)
            if d and d < bd then best, bd = a, d end
        end
    end
    return best
end

-- Client: the copy's mesh to the host's place (physics off, unless still falling).
function EV.crate_apply(a, w, why)
    local m = ue.prop(a, "StaticMesh")
    if not ue.valid(m) then return false end
    local was = EV.crate_tf(a)
    local ok = apply(function()
        if w.flag ~= "f" then m:SetSimulatePhysics(false) end
        m:K2_SetWorldLocationAndRotation(w.loc, w.rot or { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
    end)
    if w.flag ~= "f" then
        -- as its own landing does (@15-49)
        local chute = ue.prop(a, "Parachute")
        if ue.valid(chute) then apply(function() chute:SetVisibility(false, false); chute:SetCollisionEnabled(0) end) end
    end
    w.path = path_of(a)
    M.stats.crate_snapped = M.stats.crate_snapped + 1
    local line = string.format("airdrop: the host's crate %s placed here as on the host at %s (%s, was %s, %.1f m off)%s%s",
        ue.short(a), loc_str(w.loc), w.flag == "f" and "falling" or (w.flag == "l" and "landed" or "settled"),
        was and loc_str(was) or "?", was and math.sqrt(d2(was, w.loc)) / 100 or -1,
        w.flag ~= "f" and ", its physics off" or "", why and (" (" .. why .. ")") or "")
    if M.stats.crate_snapped <= 30 then log.info("%s", line) else log.debug("%s", line) end
    return ok
end

-- WCRATE|root|mesh x,y,z|pitch,yaw,roll|l/s/f   (host -> clients)
function EV.crate_msg(f)
    if S.role ~= "client" or not on("world_prefabs") then return end
    local key, loc = f[1], parse_loc(f[2])
    if not key or not loc then return end
    local w = { loc = loc, rot = MV.parse_rot(f[3]), flag = f[4] or "s" }
    EV.ccrates[key] = w
    local a = EV.crate_find(key)
    if a then EV.crate_apply(a, w, nil) else later("crate", key, w, 60) end
end

-- Client (2 s): a placed copy stays at the host's place.
function EV.crate_check()
    for key, w in pairs(EV.ccrates) do
        if w.flag ~= "f" and w.path then
            local a = find(w.path)
            local m = a and ue.prop(a, "StaticMesh")
            if not ue.valid(m) then
                EV.ccrates[key] = nil
            else
                local loc = EV.crate_tf(a)
                local sim = ue.try(function() return m:IsSimulatingPhysics() end) == true
                if sim or (loc and d2(loc, w.loc) > 400) then EV.crate_apply(a, w, "moved again here") end
            end
        end
    end
end

-- Client (its 5 s pass, PF.client_only_pass): the host's plane / crates / jets arrived.
function EV.client_seen(a, cls)
    local p = path_of(a)
    if not p or EV.ad.seen[p] or p:find("Default__", 1, true) then return end
    EV.ad.seen[p] = true
    log.info("airdrop: the host's %s %s is here (replicated) at %s", EV.SHOWN[cls] or cls, ue.short(a), EV.where(a))
end

-- BP_EventManager.Jet_Spawn (post, host): the next fly-by's timer.
function EV.on_jet_timer()
    if not is_host() then return end
    local m = EV.manager()
    local t = m and tonumber(ue.prop(m, "JetTimeToSpawn"))
    EV.ad.jet_at = clock()
    log.info("jets: next fly-by in %.1f min (up to %s jet(s))", (t or -60) / 60, tostring(m and ue.prop(m, "MaxNumberOfJetsToSpawn")))
end

-- BP_EventManager.SpawnJet (post, host): the fly-by starts (jets 1-3 s apart).
function EV.on_jet_roll()
    if not is_host() then return end
    log.info("jets: fly-by now (the jets replicate to %d client(s), each made always relevant)", #remote_pcs())
end

-- sdcoop_events: the manager's timers on this machine.
function EV.report(reply)
    local m = EV.manager()
    if not m then
        EV.next_try = 0
        m = EV.manager()
    end
    reply(string.format("events (%s): manager %s", tostring(S and S.role), m and ue.short(m) or "none in this world"))
    if not m then return end
    local function mins(fname)
        local s = EV.left(m, fname)
        if not s or s < 0 then return "no timer" end
        return string.format("%.1f min", s / 60)
    end
    local on_ = EV.cvar("Bool", "Difficulty.Airdrop")
    local ad = mins("SpawnAirdrop")
    reply(string.format("airdrop: next roll in %s%s; Difficulty.Airdrop=%s chance %s every %s-%s min; days survived %s (> 5 needed)",
        ad, ad == "no timer" and " (the cycle has stopped: a failed roll or Difficulty.Airdrop off ends it until the world is loaded)" or "",
        tostring(on_), EV.chance_text(), tostring(EV.cvar("Float", "Difficulty.MinimumTimeAirdrop")),
        tostring(EV.cvar("Float", "Difficulty.MaximumTimeAirdrop")), tostring(EV.days())))
    reply(string.format("airdrop: last roll: %s | this session: rolls=%d planes=%d crates=%d", EV.ad.last, M.stats.ad_rolls,
        M.stats.ad_planes, M.stats.ad_crates))
    reply(string.format("jets: next fly-by in %s (JetTimeToSpawn %.0f s, up to %s jet(s)) | explosion sounds: %s | dynamic event: %s",
        mins("SpawnJet"), tonumber(ue.prop(m, "JetTimeToSpawn")) or -1, tostring(ue.prop(m, "MaxNumberOfJetsToSpawn")),
        mins("SpawnExplosion"), mins("SpawnRandomEvent")))
    reply(string.format("blood moon: %s (chance here %s%%)", (is_host() and EV.moon or EV.shown) and "on" or "off",
        tostring(ue.prop(m, "BloodMoonChance"))))
    if S and S.role == "client" then reply("(a client's own airdrops / jets are blocked: the host's come)") end
end

-- sdcoop_airdrop [force]: the game's own roll on the host's manager now
-- (SpawnAirdrop, as its timer calls it). force: Difficulty.Airdrop on, the
-- chance 1 and DaysSurvived at least 6 for that one call (put back after it).
function EV.cmd_airdrop(params, reply)
    if not is_host() then reply("sdcoop_airdrop: host only (the host's airdrop replicates)") return end
    local m = EV.manager()
    if not m then
        EV.next_try = 0
        m = EV.manager()
    end
    if not m then reply("sdcoop_airdrop: no BP_EventManager in this world") return end
    local force = ue.str(params and params[1]) == "force"
    local undo = {}
    if force then
        local on_ = EV.cvar("Bool", "Difficulty.Airdrop")
        if on_ == false and EV.set_cvar("Bool", "Difficulty.Airdrop", true) then undo.on = on_ end
        local c = EV.cvar("Float", "Difficulty.ChanceOfAirdrop")
        if c and c < 1 and EV.set_cvar("Float", "Difficulty.ChanceOfAirdrop", 1.0) then undo.chance = c end
        local pc = ue.local_pc()
        local d = tonumber(ue.prop(pc, "DaysSurvived"))
        if d and d <= 5 and ue.set_prop(pc, "DaysSurvived", 6) then undo.days, undo.pc = d, pc end
    end
    local ok, err = pcall(function() m:SpawnAirdrop() end)
    if undo.chance then EV.set_cvar("Float", "Difficulty.ChanceOfAirdrop", undo.chance) end
    if undo.on ~= nil then EV.set_cvar("Bool", "Difficulty.Airdrop", undo.on) end
    if undo.days then ue.set_prop(undo.pc, "DaysSurvived", undo.days) end
    reply(string.format("sdcoop_airdrop%s: SpawnAirdrop %s: roll %s", force and " force" or "",
        ok and "ran" or ("FAILED " .. tostring(err)), EV.ad.last))
end

-- Barrels and infestations: Damage_Object(Damage, Damage Causer, Event Instigator), post.
-- Client: remembered until the Trace_Impact that caused it ends (a firearm
-- hit; a melee hit also runs on the host's copy of the swing).
-- Host: who hurt it.
local function on_damage_object(c, dmg_p, causer_p)
    if not on("world_objects") then return end
    local o = c and c:get()
    if not ue.valid(o) then return end
    local causer = obj(causer_p)
    if is_host() then
        if causer then remember_hit(o, player_of_character(causer) or false) end
        return
    end
    if S.role ~= "client" or applying > 0 then return end
    if not causer or not locally_controlled(causer) then return end
    -- a primary nest still locked here refused it (@7876: the note): the host does not take it either
    if IX.locked(o) then
        log.debug("world: hit on %s refused here (secondaries first): not sent", ue.short(o))
        return
    end
    local key = RI.key(o)   -- level path, or ~R~x,y,z for the host's random nest
    local dmg = num(get(dmg_p), 0)
    if key and dmg > 0 then
        if #pending_dmg > 16 then pending_dmg = {} end
        pending_dmg[#pending_dmg + 1] = { key = key, dmg = dmg, t = clock() }
    end
end

-- BP_FirearmPickup.Trace_Impact / Trace_ImpactBulletHole (post), client.
local function on_trace_impact(c)
    if S.role ~= "client" or #pending_dmg == 0 then return end
    local list = pending_dmg
    pending_dmg = {}
    local who = owner_character(c and c:get())
    if not who or not locally_controlled(who) then return end
    local now = clock()
    for _, e in ipairs(list) do
        if now - e.t < 0.05 and to_host("WDMG", e.key, string.format("%.2f", e.dmg)) then
            M.stats.dmg_sent = M.stats.dmg_sent + 1
        end
    end
end

local function dmg_msg(f, pc)
    if not is_host() or not on("world_objects") then return end
    local o = RI.find(f[1])
    local dmg = math.max(0, math.min(1000, num(f[2], 0)))
    local pawn = ue.pawn_of(pc)
    if not o or not pawn or dmg <= 0 then return end
    local c = ue.class_name(o)
    if not (c:find("Barrel", 1, true) or c:find("Infestation", 1, true) or c:find("Nuke", 1, true)) then return end
    -- a primary nest still locked on the host would show its "Secondary Infestations Not
    -- Destroyed" (@7946) on the HOST's screen and take nothing: the game's check first
    if IX.locked(o) and not IX.unlock(o, false, "a client's hit") then
        log.info("world: %s hit %s: still locked on the host (secondaries standing), not applied", ue.short(pawn), ue.short(o))
        return
    end
    remember_hit(o, pc)
    local ok, err = pcall(function() o:Damage_Object(dmg, pawn, nil) end)
    M.stats.dmg_host = M.stats.dmg_host + 1
    if M.stats.dmg_host <= 5 then
        log.info("world: %s shot %s for %.1f: applied on the host (ok=%s%s)", ue.short(pawn), ue.short(o), dmg,
            tostring(ok), ok and "" or (" " .. tostring(err)))
    end
end

-- BP_ExplosiveBarrelMaster.Event_Explode(EventInstigator), post. The barrel
-- destroyed itself in it: its name is read raw (same frame).
-- BP_EasterEgg_Nuke.MC_Explode(InputPin), post, too: it does not replicate,
-- so a client's shot (Damage_Object -> Svr_Explode -> MC_Explode, all local)
-- blew up the client's copy only; its 250-500 damage to zombies and players
-- around it is the host's (the client's shot comes as WDMG / WBOOM).
local exploded = {}   -- host: [path] = true this session
local function on_explode(c)
    if not on("world_objects") then return end
    local b = c and c:get()
    local p = raw_path(b)
    if not p or not p:find(":PersistentLevel.", 1, true) or ue.is_runtime_spawned(b) then return end
    if S.role == "client" then
        if applying == 0 then to_host("WBOOM", pack(p)) end
    elseif is_host() then
        exploded[p] = true
        to_clients("WBOOM", pack(p))
        M.stats.booms = M.stats.booms + 1
    end
end

local function boom_msg(f, pc)
    if not on("world_objects") then return end
    if S.role == "client" then
        for _, e in ipairs(split(f[1], ";")) do
            local b = find(unpack_path(e))
            -- not found: gone here already. The nuke of a snapshot (f[2] "s")
            -- only goes: no blast, shake and noise at the join.
            if b and not short_class(b):find("Nuke", 1, true) then apply(function() b:Event_Explode(nil) end)
            elseif b and f[2] == "s" then apply(function() b:K2_DestroyActor() end)
            elseif b then apply(function() b:MC_Explode(nil) end) end
        end
        return
    end
    local b = find(unpack_path(f[1]))
    if not b or not is_host() then return end
    -- the client's shot / blast: the host's barrel explodes for that player
    -- (its damage to zombies and players is the host's); the post-hook tells everyone
    if short_class(b):find("Nuke", 1, true) then
        pcall(function() b:MC_Explode(pc) end)
    else
        pcall(function() b:Event_Explode(pc) end)
    end
    log.info("world: %s exploded by %s, on the host too", ue.short(b), ue.short(pc))
end

local function snapshot_barrels(pc)
    local items, n = {}, 0
    for p in pairs(exploded) do
        if p:find("BP_EasterEgg_Nuke", 1, true) then
            Q.send(pc, "WBOOM", pack(p), "s")
            n = n + 1
        else
            items[#items + 1] = pack(p)
        end
    end
    send_list(pc, "WBOOM", items)
    return #items + n
end

-- ---------------------------------------------------------------------------
-- Landmines: BP_Landmine (72 placed in LongdownValley, all with the class
-- default as template and no bool / role override; no camp, POI or other
-- asset spawns one) and Buildable_LandMine (a player's, spawned at runtime:
-- its name differs per machine).
-- Both replicate (BP_Landmine's default bReplicates, Buildable_LandMine's
-- RemoteRole SimulatedProxy): a client's copy is a simulated proxy, so its
-- own K2_DestroyActor is refused there (wrong role; also its 50% BeginPlay
-- roll: the host's roll decides) and only the host's destroy removes it. That
-- destroy runs nothing of the mine's on the client (no EndPlay / Destroyed
-- event in it): the mesh just goes. Event_Explode (BP_Landmine @15-1782, the buildable's
-- the same) does everything on the machine that runs it: DoOnce, then
-- SpawnEmitterAtLocation(FX_Explosion_New, yaw 0-360, scale 1-1.5) @312,
-- PlaySoundAtLocation(explosion_large_06_Cue) @401, SpawnDecalAtLocation(M_Burn,
-- 256x512x512, pitch -90, 30 s) @624, ReportNoiseEvent 7500 cm, damage to the
-- Characters within 5 m (Damage_Object; ApplyDamage on AI: pawns refuse it on
-- a client, no authority), a radial impulse, K2_DestroyActor. It runs where its
-- trigger ran:
--   * a shot: BP_FirearmPickup Trace_Impact -> IsObjectDamageable? (BP_Landmine
--     true, the buildable false) -> Damage_Object @7328 -> Event_Explode, on the
--     shooter's machine only;
--   * stepping on it: its Box overlap (BP_Landmine any actor, the buildable no
--     'Player'-tagged one), on each machine where the copies overlap.
-- So the host's shot or step blew up the host's mine only: the client saw its
-- copy vanish (the replicated destroy) and got EXPL (sdc_shake: the camera
-- shake, no sound), no flash, no boom. A client heard / saw a mine only when
-- its OWN copy went off (its own shot, or a copy stepping on it there). A
-- client's shot blew up its own copy only: no damage, no kills, its destroy
-- refused (an inert mine stayed), and the host's mine stood on (the host
-- heard nothing).
-- Now (world_objects, the barrels' switch):
--   host: Event_Explode (post) -> WMINE|items to every client within the sound's
--     range (explosion_large_06_Cue: GunshotsSniper 325 m, + 5 m), one message
--     per client for the mines of that moment (30 ms). Item c>path>x,y,z: c = w
--     (BP_Landmine) / b (buildable), path = the packed level path, empty for a
--     runtime mine (found by class and place, 1.5 m).
--   client: a mine already gone off here (its own shot / step, or the host's
--     word before) is not shown again; its copy, if still here, is hidden (the
--     host's destroy follows). Else the copy, if not destroyed (the engine's
--     IsValid: a destroyed one stays findable until the garbage collection),
--     explodes with its own Event_Explode (in apply: nothing goes back) and is
--     hidden; a copy the host's destroy already removed (usual: the destroy
--     leaves in the host's frame, WMINE after it) -> the explosion's own calls
--     at the host's point: the same GameplayStatics calls with the same assets
--     as Event_Explode (in memory: hard references of the mine class; never
--     loaded here).
--   client: its own Event_Explode (post, not our replay) -> WMINE to the host,
--     whose mine, still standing, goes off by its own Event_Explode (damage,
--     kills, destroy) and is reported to the clients (the shooter skips it).
--   The camera shake stays sdc_shake's (EXPL).
-- Hooks only record (class, raw path, place: the host's mine destroyed itself
-- in that call, same frame, not collected); messages and engine calls run
-- from a 30 ms delay (the tick flushes anything older than 1 s).
-- ---------------------------------------------------------------------------
local MN = {
    CLS = {
        w = "/Game/Blueprints/Other/Objects/BP_Landmine.BP_Landmine_C",
        b = "/Game/Blueprints/BuildingSystem/Actors/Traps/Buildable_LandMine.Buildable_LandMine_C",
    },
    SHORT = { w = "BP_Landmine_C", b = "Buildable_LandMine_C" },
    FX = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_New.FX_Explosion_New",
    CUE = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue",
    DECAL = "/Game/Blueprints/Other/ExplosiveBarrel/M_Burn.M_Burn",
    RANGE = 32500,       -- cm: the cue's reach (GunshotsSniper) when it is not in memory
    MATCH = 150,         -- cm: a reported place -> the mine of that class here
    SAME_S = 20,         -- s: a runtime mine gone off here this long ago is the one reported at its
                         -- place (a level mine goes off once a world: kept until the world resets)
    HERE_MAX = 160,
    FLUSH_MS = 30,       -- the mines of one moment go out together
    out = {},            -- gone off here, not sent yet: { c, p = level path | nil, loc | nil, t }
    flushing = false,
    here = {},           -- client: { { c, p, loc, t } } gone off here (own, or the host's shown)
}

-- A runtime-spawned name (counted down from INT_MAX), read from a raw path.
function MN.runtime(p)
    local n = tonumber(p:match("_(%d+)$"))
    return n ~= nil and n > 2000000000
end

function MN.item(e)
    return string.format("%s>%s>%s", e.c, e.p and pack(e.p) or "", e.loc and loc_str(e.loc) or "")
end

function MN.parse(s)
    local c, p, l = tostring(s or ""):match("^([wb])>([^>]*)>([^>]*)$")
    if not c then return nil end
    local e = { c = c, p = p ~= "" and unpack_path(p) or nil, loc = parse_loc(l) }
    if not e.p and not e.loc then return nil end
    return e
end

function MN.label(e)
    return e.p and (e.p:match("([^%.]+)$") or e.p) or string.format("%s at %s", MN.SHORT[e.c], e.loc and loc_str(e.loc) or "?")
end

function MN.same(a, b)
    if a.c ~= b.c then return false end
    if a.p and b.p then return a.p == b.p end
    return a.loc ~= nil and b.loc ~= nil and d2(a.loc, b.loc) <= MN.MATCH * MN.MATCH
end

-- Client: remember a mine gone off here; true if it already had.
function MN.note_here(e)
    local now = clock()
    local seen = false
    for i = #MN.here, 1, -1 do
        local h = MN.here[i]
        if not h.p and now - h.t > MN.SAME_S then table.remove(MN.here, i)
        elseif MN.same(h, e) then seen = true end
    end
    if not seen then
        if #MN.here >= MN.HERE_MAX then table.remove(MN.here, 1) end
        MN.here[#MN.here + 1] = { c = e.c, p = e.p, loc = e.loc, t = now }
    end
    return seen
end

-- Not destroyed. UE4SS's IsValid stays true for a destroyed actor until the
-- garbage collection (~1 min): a client's copy the host's destroy removed is
-- still found by its path then. The engine's KismetSystemLibrary.IsValid,
-- called through its UFunction object (sdc_sweepguard's way: ksl:IsValid
-- would be UE4SS's own method). `unknown` when that call cannot be made.
function MN.live(m, unknown)
    if not ue.valid(m) then return false end
    local k = ue.ksl()
    if not ue.valid(MN.isvalid) then MN.isvalid = ue.find_object("/Script/Engine.KismetSystemLibrary:IsValid") end
    if not k or not MN.isvalid then return unknown end
    local ok, v = pcall(MN.isvalid, k, m)
    if ok and type(v) == "boolean" then return v end
    return unknown
end

-- The mine an item names on this machine, not destroyed: by level path, else
-- the nearest of its class at its place (a fresh FindAllOf: only on a
-- message). `unknown`: whether a mine whose state cannot be read counts.
function MN.find(e, unknown)
    if e.p then
        local m = find(e.p)
        if m and MN.live(m, unknown) then return m end
        return nil
    end
    if not e.loc then return nil end
    local best, bestd = nil, MN.MATCH * MN.MATCH
    for _, a in ipairs(ue.find_all(MN.SHORT[e.c])) do
        local l = MN.live(a, unknown) and ue.location(a) or nil
        if l then
            local d = d2(l, e.loc)
            if d <= bestd then best, bestd = a, d end
        end
    end
    return best
end

-- BP_Landmine / Buildable_LandMine .Event_Explode (post), any machine. A
-- record only: the class, the name and the place read raw (on the host the
-- mine destroyed itself in this call).
function MN.on_explode(c, k)
    if not S or not on("world_objects") then return end
    local role = S.role
    if role == "host" then
        if #remote_pcs() == 0 then return end
    elseif role ~= "client" then
        return
    end
    local m = c and c:get()
    local p = raw_path(m)
    if not p then return end
    local loc = ue.location(m)
    local e = { c = k, p = (p:find(":PersistentLevel.", 1, true) and not MN.runtime(p)) and p or nil, loc = loc, t = clock() }
    if not e.p and not e.loc then return end
    if role == "client" then
        MN.note_here(e)
        if applying > 0 then return end   -- the host's mine shown here: nothing goes back
    end
    if #MN.out >= 64 then table.remove(MN.out, 1) end
    MN.out[#MN.out + 1] = e
    if not MN.flushing then
        MN.flushing = true
        ue.delay("world-mines", MN.FLUSH_MS, MN.flush)
    end
end

-- The explosion's own calls (Event_Explode @312 / @401 / @624) at a place, with
-- the assets in memory. Returns what played ("emitter+sound+decal").
function MN.effects(loc)
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then return "nothing (no world)" end
    local done = {}
    local fx = ue.loaded_asset(MN.FX, "world mines")
    if fx and pcall(function()
        gps:SpawnEmitterAtLocation(wc, fx, loc, { Pitch = 0, Yaw = math.random() * 360, Roll = 0 },
            { X = 1 + math.random() * 0.5, Y = 1 + math.random() * 0.5, Z = 1 + math.random() * 0.5 }, true, 0, true)
    end) then done[#done + 1] = "emitter" end
    local cue = ue.loaded_asset(MN.CUE, "world mines")
    if cue and pcall(function()
        gps:PlaySoundAtLocation(wc, cue, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil)
    end) then done[#done + 1] = "sound" end
    local dec = ue.loaded_asset(MN.DECAL, "world mines")
    if dec and pcall(function()
        gps:SpawnDecalAtLocation(wc, dec, { X = 256, Y = 512, Z = 512 }, loc,
            { Pitch = -90, Yaw = math.random() * 360, Roll = 0 }, 30.0)
    end) then done[#done + 1] = "decal" end
    return #done > 0 and table.concat(done, "+") or "nothing (assets not in memory)"
end

-- Client: a copy whose explosion was shown (or went off here) waits hidden
-- for the host's destroy (its own was refused).
function MN.hide(m)
    if not ue.valid(m) then return end
    pcall(function() m:SetActorHiddenInGame(true) end)
    pcall(function() m:SetActorEnableCollision(false) end)
end

-- Client: the host's mine went off.
function MN.show(e)
    local m = MN.find(e, false)
    if MN.note_here(e) then
        M.stats.mines_dup = M.stats.mines_dup + 1
        MN.hide(m)
        log.info("world: the host's mine %s went off here already (own shot / step): not shown again%s", MN.label(e),
            m and "; its copy hidden until the host's destroy" or "")
        return
    end
    if m then
        local name = ue.short(m)
        local ok = apply(function() m:Event_Explode() end)
        MN.hide(m)
        M.stats.mines_copy = M.stats.mines_copy + 1
        log.info("world: the host's mine %s exploded here: its copy %s ran its own Event_Explode (ok=%s), hidden until the host's destroy",
            MN.label(e), name, tostring(ok))
        return
    end
    if not e.loc then
        log.info("world: the host's mine %s: no copy here and no place given: nothing shown", MN.label(e))
        return
    end
    M.stats.mines_fx = M.stats.mines_fx + 1
    log.info("world: the host's mine %s exploded; its copy is gone here (the host's destroy came first): %s at %s",
        MN.label(e), MN.effects(e.loc), loc_str(e.loc))
end

-- WMINE|items (host -> client: shown here; client -> host: set off here too).
function MN.msg(f, pc)
    if not S or not on("world_objects") then return end
    local items = {}
    for _, s in ipairs(split(f[1], ";")) do
        local e = MN.parse(s)
        if e then items[#items + 1] = e end
    end
    if S.role == "client" then
        for _, e in ipairs(items) do MN.show(e) end
        return
    end
    if not is_host() then return end
    for _, e in ipairs(items) do
        local m = MN.find(e, true)
        if m then
            local name = ue.short(m)
            local ok, err = pcall(function() m:Event_Explode() end)
            M.stats.mines_host = M.stats.mines_host + 1
            log.info("world: %s set off mine %s in its game: %s exploded on the host too (ok=%s%s)", ue.short(pc),
                MN.label(e), name, tostring(ok), ok and "" or (" " .. tostring(err)))
        else
            log.info("world: %s set off mine %s in its game: not standing on the host (gone off here already)",
                ue.short(pc), MN.label(e))
        end
    end
end

-- The mines gone off here since the last flush, in one message per receiver
-- (from the hook's 30 ms delay, or the tick).
function MN.flush()
    MN.flushing = false
    local list = MN.out
    if #list == 0 then return end
    MN.out = {}
    if not S or not on("world_objects") then return end
    local items = {}
    for i, e in ipairs(list) do items[i] = MN.item(e) end
    if S.role == "client" then
        local n = 0
        for _, b in ipairs(Q.batches(items)) do
            if to_host("WMINE", b) then n = n + 1 end
        end
        M.stats.mines_sent = M.stats.mines_sent + #list
        log.info("world: %d mine(s) went off here (own shot / step: %s): %s to the host", #list, MN.label(list[1]),
            n > 0 and "sent" or "NOT sent (not connected)")
        return
    end
    if not is_host() then return end
    local snd = package.loaded["sdc_ownsounds"] or require("sdc_ownsounds")
    local range = snd.range_of_path(MN.CUE, MN.RANGE)
    local pcs = remote_pcs()
    local per, order = {}, {}
    for i, e in ipairs(list) do
        -- (place unreadable: everyone; the copy is found by its path)
        local near = e.loc and snd.pcs_near(pcs, e.loc, range) or pcs
        for _, pc in ipairs(near) do
            local a = addr(pc)
            if a then
                local r = per[a]
                if not r then
                    r = { pc = pc, items = {} }
                    per[a] = r
                    order[#order + 1] = a
                end
                r.items[#r.items + 1] = items[i]
            end
        end
    end
    local msgs = 0
    for _, a in ipairs(order) do
        local r = per[a]
        for _, b in ipairs(Q.batches(r.items)) do
            if Q.now(r.pc, "WMINE", b) then msgs = msgs + 1 end
        end
    end
    M.stats.mines = M.stats.mines + #list
    log.info("world: %d mine(s) exploded on the host (%s%s): WMINE to %d client(s) in %d message(s), %d client(s) beyond %.0f m",
        #list, MN.label(list[1]), list[1].loc and (" at " .. loc_str(list[1].loc)) or ", place unreadable: by name", #order,
        msgs, #pcs - #order, (range + (snd.MARGIN or 500)) / 100)
end

function MN.reset()
    MN.out, MN.here, MN.flushing = {}, {}, false
end

-- BP_Infestation.Event_OnDestroyed(Causer, CalledFromGameLoad?), post, host.
-- Its health differs per machine (DamageComponent.SetHealth: random deviation,
-- the machine's own Difficulty.InfestationsHealth) and melee hits are traced
-- on each machine, so the client's copy can die first. Its loot pile asks the
-- host (SERVER_RequestData -> JigCanInteract = the HOST's IsDestroyed?): an
-- empty pile on the client while the host's nest still stood. Client: its own
-- destruction -> WINFD; the host's nest dies the game's way for that player.
local function on_infest_destroyed(c, _, load_p)
    if not on("world_objects") then return end
    local i = c and c:get()
    if get(load_p) == true then return end
    local key = RI.key(i)   -- level path, or ~R~x,y,z for a random nest
    if not key then return end
    if S.role == "client" then
        if applying == 0 then
            IX.own[key] = true   -- (the game gave this player its XP here)
            if to_host("WINFD", key) then
                log.info("world: infestation %s destroyed here, sent to the host", ue.short(i))
            end
        end
        return
    end
    if not is_host() then return end
    if RI.is_key(key) then RI.host_destroyed(key) end
    to_clients("WINF", key, "l")
    M.stats.infest = M.stats.infest + 1
    log.info("world: infestation %s destroyed on the host", ue.short(i))
    IX.share(i, key)
end

local function infest_destroyed_msg(f, pc)
    if not is_host() or not on("world_objects") then return end
    local i = RI.find(f[1])
    if not i or ue.prop(i, "IsDestroyed?") == true then return end
    local pawn = ue.pawn_of(pc)
    remember_hit(i, pc)
    IX.got[f[1]] = addr(pc)   -- its own copy died there: the game paid that player there
    -- DamageComponent.DamageTaken(DmgAmount, DmgType, DmgCauser, IsHeadshot):
    -- its Death -> InfestationDestroyed(causer) -> Event_OnDestroyed (XP / stat
    -- for that player through the scope, the loot pile, WINF to the others).
    -- Damage_Object is not used: it refuses a primary nest while the host's
    -- secondaries stand (CanDamagePrimary? @7876), the client's are down.
    local dc = ue.prop(i, "DamageComponent")
    local hp = tonumber(ue.prop(dc, "CurrentHealth")) or 0
    local ok = ue.valid(dc) and pcall(function() dc:DamageTaken(hp + 100000.0, nil, pawn, false) end)
    if not ok then
        -- the bound Death event itself
        ok = pcall(function()
            i:BndEvt__BP_MasterZombie_DamageComponent_K2Node_ComponentBoundEvent_1_Death__DelegateSignature(pawn, false)
        end)
    end
    log.info("world: infestation %s destroyed by %s on the client: destroyed on the host too (ok=%s)",
        ue.short(i), ue.short(pc), tostring(ok))
    IX.unlock_primaries(true, "a client's kill")
end

local function infest_msg(f)
    if S.role ~= "client" or not on("world_objects") then return end
    for _, e in ipairs(split(f[1], ";")) do
        local i = RI.find(e)
        if RI.is_key(e) then RI.mark_destroyed(e) end   -- (its copy, when it comes, looks destroyed)
        if not i then
            if not RI.is_key(e) then later("infest", unpack_path(e)) end
        elseif ue.prop(i, "IsDestroyed?") ~= true then
            -- the game's load path: destroyed look, no XP / notification here
            apply(function() i:Event_OnDestroyed(nil, true) end)
        end
    end
    -- that path does not broadcast to the primary (only a death does): its update (live "l" / join)
    IX.unlock_primaries(f[2] == "l", f[2] == "l" and "the host's kill" or "the host's state")
end

-- ---------------------------------------------------------------------------
-- Infestation XP for everyone near (co-op rule, 0.6.72)
-- ---------------------------------------------------------------------------
-- The game (BP_Infestation.Event_OnDestroyed(Causer, CalledFromGameLoad?) ->
-- IsDestroyed? @11090 -> not from a load @11016 -> @9868-10911), for player 0
-- of the machine that runs it: CastToController(self).InfestationsDestroyed
-- + 1 (journal), GetLevellingComponent(self).AddXP(CurrentLevel x
-- Random(400, 500) for a primary nest / Random(100, 200) for any other
-- (secondary, random) x MultiplyValue), and with Game.XpPopUp the note
-- "Infestation Destroyed, XP Given: {XP}" (Skul icon, red). Nothing for the
-- waves. In co-op only the finisher got it: the host when its run was the
-- host's (resolver: no remote hitter); a client when its own copy died (its
-- own run; the host's run for it went to the host's copy of its controller,
-- which has no real progression); a client never got the host's kill.
-- Rule (infestation_xp_shared, infestation_xp_radius_m): when a nest dies on
-- the host (not from a load), every player within the radius of it gets the
-- same as the game's run, the game's way on its own progression (its own
-- level and multiplier, its own journal stat, the game's note on its own
-- screen): the host here, a client through WINFXP (after the WINF of that
-- nest, same queue). The finisher is never paid twice: the host when its run
-- paid it; the client whose own copy died (WINFD; on the client its own
-- death is remembered too); a client the host's run named but whose copy
-- did not die gets it even when farther away.

function IX.on()
    return on("world_objects") and cfg.get("infestation_xp_shared") ~= false
end

function IX.radius_cm()
    local m = tonumber(cfg.get("infestation_xp_radius_m")) or 150
    return math.max(0, m) * 100
end

-- Host: the nest is down (not from a load).
function IX.share(i, key)
    if not IX.on() then return end
    local primary = ue.prop(i, "PrimaryInfestation?") == true
    -- who the host's run paid (the scope: the last remote hitter, else the host)
    local who = hitter_of(i, addr(i) or -1)
    local fin = (who and remote_pc(who)) and who or nil
    local own = IX.got[key]
    IX.got[key] = nil
    local at = ue.location(i)
    local r2 = IX.radius_cm() ^ 2
    local function near(pawn)
        local l = ue.location(pawn)
        return at ~= nil and l ~= nil and d2(l, at) <= r2
    end
    local names = {}
    if fin and near(ue.local_pawn()) then
        if IX.grant(primary, ue.short(i)) then names[#names + 1] = "the host" end
    end
    for _, pc in ipairs(remote_pcs()) do
        local a = addr(pc)
        if a and a ~= own and (pc == fin or near(ue.pawn_of(pc))) then
            Q.send(pc, "WINFXP", key, primary and "1" or "0")
            names[#names + 1] = ue.short(pc)
        end
    end
    M.stats.inf_shared = M.stats.inf_shared + #names
    log.info("world: %s infestation %s down (paid by the game: %s): the same for %s within %.0f m",
        primary and "primary" or "secondary", ue.short(i),
        own and "the client whose copy died" or (fin and "nobody real (the host's copy of the finisher)" or "the host"),
        #names > 0 and table.concat(names, ", ") or "nobody else", IX.radius_cm() / 100)
end

-- The game's payment of a destroyed nest, for this machine's own player.
function IX.grant(primary, what)
    local pc = ue.local_pc()
    local comp = ue.prop(pc, "LevellingComponent")
    if not ue.valid(comp) then return false end
    -- CastToController(self).InfestationsDestroyed + 1 (@9868-10005)
    ue.set_prop(pc, "InfestationsDestroyed", (tonumber(ue.prop(pc, "InfestationsDestroyed")) or 0) + 1)
    if S.role == "client" and not PW.xp_timer then PW.xp_timer = ue.call(comp, "Event_LevelBarTimer") end
    -- @10100-10383
    local lo, hi = primary and 400 or 100, primary and 500 or 200
    local xp = (tonumber(ue.prop(comp, "CurrentLevel")) or 1) * (lo + math.random() * (hi - lo))
        * (tonumber(ue.prop(comp, "MultiplyValue")) or 1)
    local out = {}
    if not pcall(function() comp:AddXP(xp, false, out) end) then return false end
    local given = math.floor(tonumber(out.XPOutput) or xp)
    -- @10438-10911: the note, as the game shows it (Game.XpPopUp)
    if EV.cvar("Bool", "Game.XpPopUp") ~= false then
        local gfl = ue.find_object(PW.PATHS.gfl)
        local icon = ue.loaded_asset(IX.SKULL, "world")
        if gfl and FText then
            apply(function()
                gfl:CreateNotificationUI(FText(string.format("Infestation Destroyed, XP Given: %d", given)), icon,
                    { R = 1, G = 0, B = 0, A = 1 }, 2.0, false, pc)
            end)
        end
    end
    log.info("world: shared infestation XP here for %s: +%d XP, InfestationsDestroyed %d", tostring(what), given,
        tonumber(ue.prop(pc, "InfestationsDestroyed")) or -1)
    return true
end

-- WINFXP|nest key|primary 1/0   (host -> client)
function IX.xp_msg(f)
    if S.role ~= "client" or not IX.on() then return end
    local key = tostring(f[1] or "")
    if key == "" or IX.recv[key] then return end
    IX.recv[key] = true
    if IX.own[key] then
        log.info("world: shared infestation XP for %s: its own copy died here, the game paid it already", key)
        return
    end
    IX.grant(f[2] == "1", key)
    M.stats.inf_shared = M.stats.inf_shared + 1
end

-- ---------------------------------------------------------------------------
-- Primary nests: locked until their secondaries are down (0.6.74)
-- ---------------------------------------------------------------------------
-- The game (BP_Infestation): a primary (PrimaryInfestation?) binds, at its
-- BeginPlay (@5728-6154), every one of its SecondaryInfestations' own
-- InfestationDestroyed delegate to its Event_SecondaryDestroyed. A secondary's
-- death broadcasts it (Death @7817: InfestationDestroyed(DmgCauser, false);
-- a load @6980: (None, true)) -> Event_SecondaryDestroyed (@11379):
-- AreSecondariesDestroyed? (every one IsDestroyed?) -> CanDamagePrimary? =
-- true (@11282), a blast at the primary when not from a load (@11116-11181).
-- Damage_Object on a primary (@7862-7946): CanDamagePrimary? -> DamageTaken,
-- else the forced note "Secondary Infestations Not Destroyed In Surrounding
-- Area." Nothing of it replicates.
-- On a client the host's kills arrive as WINF and the copy dies by the load
-- path, Event_OnDestroyed(None, true) - the event itself, not the broadcast:
-- the client's primary never heard of it and stayed locked (the note), while
-- the host's took damage (a client's shot even reached it through WDMG).
-- Now: after the host's deaths (and on join, a nest found later, a client's
-- kill on the host) every primary whose secondaries are all down here runs the
-- game's Event_SecondaryDestroyed (live: with its blast; a join: as a load).
-- A hit the own primary refused is not forwarded; a client's hit on a primary
-- still locked on the host is not applied there (no note on the host's screen).

-- A primary nest still locked on this machine.
function IX.locked(o)
    return ue.prop(o, "PrimaryInfestation?") == true and ue.prop(o, "IsDestroyed?") ~= true
        and ue.prop(o, "CanDamagePrimary?") ~= true
end

-- Its secondaries all destroyed here (AreSecondariesDestroyed?, @0-711).
function IX.secondaries_down(o)
    local list = PF.list_of(ue.prop(o, "SecondaryInfestations"))
    for _, s in ipairs(list) do
        if ue.valid(s) and ue.prop(s, "IsDestroyed?") ~= true then return false end
    end
    return true
end

-- The game's update of a primary whose secondaries are down here.
function IX.unlock(o, live, why)
    if not IX.locked(o) or not IX.secondaries_down(o) then return false end
    apply(function() o:Event_SecondaryDestroyed(nil, not live) end)
    local ok = ue.prop(o, "CanDamagePrimary?") == true
    M.stats.inf_unlocked = M.stats.inf_unlocked + 1
    log.info("world: primary infestation %s: its secondaries are down here (%s): it can be damaged now%s",
        ue.short(o), tostring(why), ok and "" or " - FAILED (still locked)")
    return ok
end

function IX.unlock_primaries(live, why)
    if not on("world_objects") then return 0 end
    local n = 0
    for _, o in ipairs(ue.find_all("BP_Infestation_C")) do
        if ue.valid(o) and IX.locked(o) and IX.unlock(o, live, why) then n = n + 1 end
    end
    return n
end

local function snapshot_infest(pc)
    local items = {}
    for _, i in ipairs(ue.find_all("BP_Infestation_C")) do
        if level_actor(i) and ue.prop(i, "IsDestroyed?") == true then
            local p = path_of(i)
            if p then items[#items + 1] = pack(p) end
        end
    end
    send_list(pc, "WINF", items)
    return #items
end

-- ===========================================================================
-- Building (client placement through the host)
-- ===========================================================================

local function guid_str(g)
    local a, b, c, d = ue.try(function() return g.A end), ue.try(function() return g.B end),
        ue.try(function() return g.C end), ue.try(function() return g.D end)
    if type(a) ~= "number" then return "" end
    return string.format("%d:%d:%d:%d", a, b, c, d)
end

local function parse_guid(s)
    local a, b, c, d = tostring(s or ""):match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not a then return nil end
    return { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) }
end

local function own_building()
    local pawn = ue.local_pawn()
    local bc = pawn and ue.prop(pawn, "BuildingComponent")
    if not ue.valid(bc) then return nil, pawn end
    return bc, pawn
end

local function send_build_mode()
    local bc = own_building()
    if not bc or ue.prop(bc, "BuildModeOn?") ~= true then return end
    local da = ue.prop(bc, "DARef")
    if not ue.valid(da) then return end
    local moving = ue.prop(bc, "ReplacingObject?") == true
    if to_host("WBMODE", ue.path(da), moving and "1" or "0", guid_str(ue.prop(bc, "BuildUID"))) then
        M.stats.build_modes = M.stats.build_modes + 1
        log.info("world: build mode (%s %s) mirrored to the host", moving and "moving" or "placing",
            moving and ue.short(ue.prop(bc, "ReplacingActor")) or ue.short(da))
    end
end

-- BuildingComponent.Event_LaunchBuildMode(DA, Replacing?, ReplacingActor),
-- post, client (a client RPC: its body runs here only). ContextPlaceItem sets
-- BuildUID right after it: sent a moment later.
local function on_launch_build(c)
    if S.role ~= "client" or not on("world_build") then return end
    local bc = c and c:get()
    local owner = ue.try(function() return bc:GetOwner() end)
    if not is_player_character(owner) or not locally_controlled(owner) then return end
    ue.delay("world-bmode", 120, send_build_mode)
end

local function bmode_msg(f, pc)
    if not is_host() or not on("world_build") then return end
    local pawn = ue.pawn_of(pc)
    local bc = pawn and ue.prop(pawn, "BuildingComponent")
    if not ue.valid(bc) then return end
    local da = load_object(f[1] or "")
    if not da then log.warn("world: %s builds %s: no such item here", ue.short(pawn), tostring(f[1])) return end
    local k = addr(pc) or -1
    local b = build[k] or {}
    build[k] = b
    -- the move mode set by ReplacingObject a moment ago (its RPC -> this WBMODE)
    local host_rep = b.rep and clock() - (b.at or 0) < 1.5
    ue.set_prop(bc, "DARef", da)
    ue.set_prop(bc, "BuildModeOn?", true)
    if f[2] == "1" or host_rep then
        b.rep = true
    else
        b.rep = false
        ue.set_prop(bc, "ReplacingObject?", false)
    end
    local g = parse_guid(f[3])
    if g then ue.set_prop(bc, "BuildUID", g) end
    b.at = clock()
    b.da = ue.short(da)
    log.debug("world: build mode of %s mirrored (%s, replacing=%s)", ue.short(pawn), ue.short(da), tostring(b.rep))
end

-- ---------------------------------------------------------------------------
-- Moving a placed buildable. Buildable_MASTER replicates (bReplicates) but
-- not its movement (bReplicateMovement false): SpawnBuild's move
-- (@62 ReplacingActor.K2_SetActorTransform) happened on the host only, the
-- clients kept the old place (a client's own move "did nothing" for it; the
-- host saw and saved it moved). The host's buildable replicates its movement
-- from its first move on (AActor.SetReplicateMovement, the engine's own way),
-- and the host sends the new place (WMOVE) for copies the engine does not
-- update (out of range, dormant). EMS saves the host's actor where it is now.
-- ---------------------------------------------------------------------------

function MV.rot_of(a)
    local ok, r = pcall(function() return a:K2_GetActorRotation() end)
    if not ok or r == nil then return nil end
    local p, y, ro = ue.try(function() return r.Pitch end), ue.try(function() return r.Yaw end), ue.try(function() return r.Roll end)
    if type(p) ~= "number" or type(y) ~= "number" or type(ro) ~= "number" then return nil end
    return { Pitch = p, Yaw = y, Roll = ro }
end

function MV.parse_rot(s)
    local p, y, r = tostring(s or ""):match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not p then return nil end
    return { Pitch = tonumber(p), Yaw = tonumber(y), Roll = tonumber(r) }
end

-- Host: this buildable replicates its movement from now on.
function MV.mark(bld)
    local p = path_of(bld)
    if not p or MV.marked[p] then return end
    MV.marked[p] = true
    local ok = pcall(function() bld:SetReplicateMovement(true) end)
    if not ok then ue.set_prop(bld, "bReplicateMovement", true) end
    pcall(function() bld:FlushNetDormancy() end)
    log.debug("world: %s replicates its movement now (%s)", ue.short(bld), ok and "SetReplicateMovement" or "property set")
end

-- Host, ReplacingObject: who moves what from where.
function MV.begin(bld, key)
    local p, l = path_of(bld), ue.location(bld)
    if not p or not l then return end
    MV.mark(bld)
    MV.moving[key] = { path = p, cls = ue.class_name(bld), name = ue.short(bld), old = l, rot = MV.rot_of(bld), at = clock() }
end

-- Host, after SpawnBuild: the move is done (or this was a new building).
function MV.finish(key, who)
    local mv = MV.moving[key]
    if not mv then return false end
    local bld = find(mv.path)
    if not bld then MV.moving[key] = nil return false end
    local l, r = ue.location(bld), MV.rot_of(bld)
    if not l then return false end
    local turned = r and mv.rot and math.abs((r.Yaw - mv.rot.Yaw + 180) % 360 - 180) > 0.5
    if d2(l, mv.old) < 1 and not turned then return false end   -- not moved: a new building
    MV.moving[key] = nil
    pcall(function() bld:ForceNetUpdate() end)
    local rs = r and string.format("%.2f,%.2f,%.2f", r.Pitch, r.Yaw, r.Roll) or ""
    local ls = string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z)
    Q.all_now("WMOVE", mv.cls, loc_str(mv.old), ls, rs)
    M.stats.moves = M.stats.moves + 1
    log.info("world: %s moved %s from %s to %s (yaw %.0f): it replicates its movement, WMOVE to %d client(s)",
        who, mv.name, loc_str(mv.old), loc_str(l), r and r.Yaw or 0, #remote_pcs())
    return true
end

-- Client: the buildable of that class at the old place goes to the new one
-- (unless the engine's movement replication already put it there).
-- Returns true when done, false when the old one is not here (yet).
function MV.apply(cls, m)
    local best, bestd, there = nil, 50 * 50, false
    for _, a in ipairs(ue.find_all(cls)) do
        if ue.valid(a) then
            local l = ue.location(a)
            if l then
                if d2(l, m.new) < 25 then there = true end
                local d = d2(l, m.old)
                if d < bestd then best, bestd = a, d end
            end
        end
    end
    if there then
        log.info("world: moved %s already stands at %s here (its movement replicated)", cls, loc_str(m.new))
        return true
    end
    if not best then return false end
    local rot = m.rot or MV.rot_of(best) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local ok = apply(function() best:K2_SetActorLocationAndRotation(m.new, rot, false, {}, true) end)
    M.stats.moves_applied = M.stats.moves_applied + 1
    log.info("world: %s moved here from %s to %s as on the host%s", ue.short(best), loc_str(m.old), loc_str(m.new),
        ok and "" or " - FAILED")
    return true
end

-- WMOVE|class|old x,y,z|new x,y,z|pitch,yaw,roll   (host -> clients)
function MV.move_msg(f)
    if S.role ~= "client" or not on("world_build") then return end
    local cls, old, new = f[1], parse_loc(f[2]), parse_loc(f[3])
    if type(cls) ~= "string" or cls == "" or not old or not new then return end
    local m = { old = old, new = new, rot = MV.parse_rot(f[4]) }
    if not MV.apply(cls, m) then
        log.info("world: moved %s not here near %s yet: retried", cls, loc_str(old))
        later("move", cls, m, 20)
    end
end

-- Buildable_MASTER.ReplacingObject (post), host (OnServerExecuteInteract
-- Option1 "Move" @1349): the scope sent the client its move mode
-- (Event_LaunchBuildMode RPC); the host's copy of its BuildingComponent gets
-- the same state for the coming Svr_SpawnBuild. Any player's move: the
-- buildable replicates its movement from now on.
local function on_replacing(c)
    if not is_host() or not on("world_build") then return end
    local bld = c and c:get()
    local cur = ue.prop(bld, "CurrentActor")
    local pc = player_of_character(cur)
    if pc == nil then return end
    MV.begin(bld, pc and (addr(pc) or -1) or "host")
    if not pc then
        log.info("world: the host moves %s (its movement replicates now)", ue.short(bld))
        return
    end
    local bc = ue.prop(cur, "BuildingComponent")
    if not ue.valid(bc) then return end
    ue.set_prop(bc, "DARef", ue.prop(bld, "PickupDataAsset"))
    ue.set_prop(bc, "ReplacingObject?", true)
    ue.set_prop(bc, "ReplacingActor", bld)
    ue.set_prop(bc, "BuildModeOn?", true)
    build[addr(pc) or -1] = { rep = true, at = clock(), da = ue.short(bld) }
    log.info("world: %s moves %s (host-side build state set)", ue.short(cur), ue.short(bld))
end

-- BuildingComponent.SpawnBuild(SpawnTransform), post, host: a client's
-- placement / move done here; the host's own move -> WMOVE.
local function on_spawn_build(c)
    if not is_host() or not on("world_build") then return end
    local bc = c and c:get()
    local owner = ue.try(function() return bc:GetOwner() end)
    local pc = player_of_character(owner)
    if pc == nil then return end
    if pc == false then
        MV.finish("host", "the host")
        return
    end
    local k = addr(pc) or -1
    local b = build[k] or {}
    local rep = b.rep == true
    b.rep = false
    build[k] = b
    if rep then MV.finish(k, ue.short(owner)) end
    Q.now(pc, "WBUILT", rep and "1" or "0")
    M.stats.builds = M.stats.builds + 1
    log.info("world: %s placed %s on the host", ue.short(owner),
        rep and ("moved " .. tostring(b.da)) or tostring(b.da or ue.short(ue.prop(bc, "DARef"))))
end

-- Client: SpawnBuild's own-player tail (@822-1545), which in single player
-- runs on the builder's machine: pick up the ground pickup it came from,
-- consume the item, then the next one of the same kind or leave build mode.
local function built_msg(f)
    if S.role ~= "client" or not on("world_build") then return end
    local bc, pawn = own_building()
    if not bc then return end
    if f[1] == "1" then
        -- (Event_StopBuildMode gives the moved buildable its collision back here)
        apply(function() bc:Event_StopBuildMode() end)
        log.info("world: moved building placed on the host, build mode ends")
        return
    end
    M.stats.build_tails = M.stats.build_tails + 1
    local pr = ue.prop(bc, "PickupRef")
    if ue.valid(pr) then apply(function() pr:PickupBuildFromGround() end) end
    -- FGuid as a plain table (a struct read from one call is not passed to another)
    local uid = parse_guid(guid_str(ue.prop(bc, "BuildUID")))
    local menu = ue.prop(pawn, "JigContextMenuComp")
    local lc = ue.prop(menu, "LocalComp")
    local root = ue.prop(menu, "RootContainer")
    local rc = ue.prop(root, "JigMultiplayerComp")
    local consumed = false
    if ue.valid(lc) and ue.valid(rc) and uid then
        consumed = pcall(function() lc:SERVER_RequestConsumeItem(rc, uid, 1, "") end)
    end
    local da = ue.prop(bc, "DARef")
    local jig = ue.prop(pawn, "BP_JigMultiplayer")
    local out, found = {}, nil
    if ue.valid(da) and ue.valid(jig) then
        if pcall(function() jig:FindJigItemByDA(da, {}, true, false, 1, out) end) and out.Result == true then
            found = out.Found
        end
    end
    -- another stack of the same item (the consumed one may still be shown
    -- until the host's answer: same UID = leave build mode, as a free extra
    -- placement must not happen)
    local next_uid = ue.valid(found) and parse_guid(guid_str(ue.prop(found, "ItemUniqueID"))) or nil
    if next_uid and uid and guid_str(next_uid) ~= guid_str(uid) then
        ue.set_prop(bc, "BuildUID", next_uid)
        send_build_mode()
        log.info("world: placed (consumed=%s), next %s from the inventory", tostring(consumed), ue.short(da))
    else
        apply(function() bc:Event_StopBuildMode() end)
        log.info("world: placed (consumed=%s), build mode ends", tostring(consumed))
    end
end

-- ===========================================================================
-- Prefab camps and random spawners (world_prefabs)
-- ===========================================================================

-- AIBlueprintHelperLibrary.SpawnAIFromClass(WorldContextObject, PawnClass, ...)
-- (native pre), client: the AI volume of a host camp's copy is a local,
-- non-replicated child actor here, authority of itself, and would spawn its
-- own bandits (BP_AISpawningVolume_Prefab @1836); the host's come replicated.
function PF.on_spawn_ai(_, wco_p, class_p)
    if not wco_p or not class_p or not on("world_prefabs") then return end
    local wco = get(wco_p)
    if not ue.valid(wco) or not ue.class_name(wco):find("^BP_AISpawningVolume_") then return end
    -- a camp's own volume (child actor, runtime); placed ones are the AI modules'
    if not ue.is_runtime_spawned(wco) or not PF.world_is_client(wco) then return end
    if PF.block_class(class_p) then
        M.stats.prefab_ai_blocked = M.stats.prefab_ai_blocked + 1
        if M.stats.prefab_ai_blocked <= 3 then
            log.info("world: AI spawn of the camp volume %s blocked on this client (the host's AI comes replicated)", ue.short(wco))
        end
    end
end

function PF.list_of(arr)
    local out = {}
    if arr == nil then return out end
    if type(arr) == "table" then
        for _, v in ipairs(arr) do out[#out + 1] = v end
    else
        pcall(function() arr:ForEach(function(_, e) out[#out + 1] = e:get() end) end)
    end
    return out
end

-- Host: a camp the host's spawner made replicates; its replicated children
-- (stations, containers: separate actors already) get the same range.
function PF.replicate_prefab(a, why)
    if not ue.valid(a) or not ue.is_runtime_spawned(a) or ue.short(a):find("^Default__") then return false end
    if PF.world_is_client(a) or ue.prop(a, "bReplicates") == true then return false end
    if not pcall(function() a:SetReplicates(true) end) then return false end
    local cull = PF.PREFAB_CULL * PF.PREFAB_CULL
    ue.set_prop(a, "NetCullDistanceSquared", cull)
    ue.set_prop(a, "NetUpdateFrequency", 1.0)
    pcall(function() a:ForceNetUpdate() end)
    local out, kids, names = {}, 0, {}
    pcall(function() a:GetAllChildActors(out, true) end)
    -- UE4SS writes an out TArray into the passed table itself (out[i], each a
    -- param read with :get(), as GetAllActorsOfClass elsewhere); reading
    -- out.ChildActors found nothing: every camp logged "0 replicated part(s)"
    -- and its parts kept the default 150 m net range (0.7.1)
    local children = {}
    for i = 1, #out do
        local e = out[i]
        local okg, o = pcall(function() return e:get() end)
        children[#children + 1] = okg and o or e
    end
    if #children == 0 and out.ChildActors ~= nil then children = PF.list_of(out.ChildActors) end
    for _, ch in ipairs(children) do
        if ue.valid(ch) and ue.prop(ch, "bReplicates") == true then
            kids = kids + 1
            ue.set_prop(ch, "NetCullDistanceSquared", cull)
            pcall(function() ch:ForceNetUpdate() end)
            if #names < 6 then names[#names + 1] = ue.class_name(ch) end
        end
    end
    M.stats.prefab_replicated = M.stats.prefab_replicated + 1
    log.info("world: camp %s replicates to the clients (%s; %d replicated part(s): %s)", ue.short(a), why, kids,
        table.concat(names, ", "))
    -- a random event's wreck: always relevant (sdc_events)
    local evm = package.loaded["sdc_events"]
    if evm and evm.on_prefab_replicated then pcall(evm.on_prefab_replicated, a) end
    return true
end

PF.new, PF.flushing = {}, false

function PF.flush_prefabs()
    PF.flushing = false
    local list = PF.new
    PF.new = {}
    for _, o in ipairs(list) do pcall(PF.replicate_prefab, o, "spawned") end
end

-- NotifyOnNewObject(PrefabMaster_C and children): never touched while it is
-- being constructed; its children exist once FinishSpawningActor ran.
function PF.on_new_prefab(o)
    if not on("world_prefabs") then return end
    if #PF.new >= 64 then return end
    PF.new[#PF.new + 1] = o
    if not PF.flushing then
        PF.flushing = true
        ue.delay("world-prefab", 200, PF.flush_prefabs)
    end
end

-- Client: a new loot container this client made itself (authority, runtime-
-- spawned): F on it asks the host about an object the host does not have
-- (SERVER_RequestData resolves to nothing) and it stays empty, whatever the
-- host's copy holds. Checked 300 ms after construction.
PF.loot_new, PF.loot_flushing = {}, false

function PF.flush_loot()
    PF.loot_flushing = false
    local list = PF.loot_new
    PF.loot_new = {}
    for _, o in ipairs(list) do
        if ue.valid(o) and ue.role(o) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(o) and PF.world_is_client(o)
            and not PF.KEEP_LOCAL[ue.class_name(o)] then
            local name, cls = ue.short(o), ue.class_name(o)
            if pcall(function() o:K2_DestroyActor() end) then
                M.stats.prefab_removed = M.stats.prefab_removed + 1
                log.info("world: removed client-only container %s (%s): empty here, the host's copy is the real one", name, cls)
            end
        end
    end
end

function PF.on_new_loot(o)
    if not on("world_prefabs") or S == nil or S.role == "host" then return end
    -- only its name is read now (the ~2900 placed boxes of a map load stop here)
    if not ue.is_runtime_spawned(o) or #PF.loot_new >= 128 then return end
    PF.loot_new[#PF.loot_new + 1] = o
    if not PF.loot_flushing then
        PF.loot_flushing = true
        ue.delay("world-loot-new", 300, PF.flush_loot)
    end
end

-- Client (every 5 s): spawner leftovers that exist only here (authority,
-- runtime-spawned): a prefab goes with its child actors.
function PF.client_only_pass()
    local n = 0
    for _, cls in ipairs(PF.CLIENT_ONLY_CLASSES) do
        for _, a in ipairs(ue.find_all(cls)) do
            if ue.valid(a) and ue.role(a) == ue.ROLE_AUTHORITY and ue.is_runtime_spawned(a) then
                local name = ue.short(a)
                if pcall(function() a:K2_DestroyActor() end) then
                    n = n + 1
                    M.stats.prefab_removed = M.stats.prefab_removed + 1
                    log.info("world: removed client-only %s (%s, spawned by this client's own copy of the level)", name, cls)
                end
            elseif EV.SHOWN[cls] and ue.valid(a) then
                EV.client_seen(a, cls)   -- the host's plane / crate / jet arrived
            end
        end
    end
    return n
end

-- Host (every 10 s): a camp the notification missed.
function PF.host_prefab_pass()
    for _, a in ipairs(ue.find_all("PrefabMaster_C")) do
        if ue.valid(a) and ue.prop(a, "bReplicates") ~= true then pcall(PF.replicate_prefab, a, "late") end
    end
end

-- ===========================================================================
-- Locks, keys and tools for a client (0.6.69)
-- ===========================================================================
-- Lock picking (BP_LockPickObject children: BP_MASTER_PicklockContainer
-- cabinets / lockers / safes, BP_LockedDoor) runs on the picker's machine:
-- OnExecuteInteract -> IsLocked? -> AdvancedLockCheck (Skill_Lockpick for
-- difficulty 2-3, the own TechTree) -> LockpickUI on the own screen
-- (@2947-3464) -> the minigame (LockpickUI Tick) -> LockpickSuccessful
-- (IsLocked? false, Thief / Scavenging XP of player 0 = the picker) ->
-- OpenContainer (sdc_world WLOOT "u") / the door's next Event_Door (WDOOR "u").
-- The minigame turns the lock only while GetLockpickAmount > 0 (@571-651),
-- and that counts DA_Lockpick in JigRef.MainJigContainers - the HOST's
-- inventory data, empty on a client: the client's pin never moved, nothing
-- was ever picked, nothing reached the host. A broken pick (BreakLockpick:
-- durability 25 - 1.675 per 0.1 s of a wrong try, "Lockpick broke" @477) is
-- consumed by ServerFindThenConsumeByItemID (@621): host data, so a client
-- never lost one either.
--   * client: GetLockpickAmount (post) answers with the lockpicks this
--     player's own inventory widgets show (its out Lockpicks: the minigame's
--     gate) and puts that count on the screen (LK.show: the on-screen text is
--     a binding to GetLockpickAmountText, which a Blueprint hook cannot
--     answer); a broken pick -> WLPBREAK -> the host consumes one DA_Lockpick
--     from that player's inventory (the game's ServerFindThenConsumeByItemID
--     there), and here it counts as gone at once, as in single player;
--     LockpickSuccessful (post) -> WUNLOCK -> the host's copy unlocked (and
--     every other client's) at once, not only at the next open.
-- Tools (crowbar of BP_LockedDoor.FindCrowbar, BP_MASTER_ToolRequiredContainer
-- FindItem / HoldToInteract): found in the own widgets (works), but the wear
-- (ServerFuncUpdateDurabilityByUID, ReduceDurabilityOfFoundItem) writes the
-- host's data: a client's tool never wore. The wear call of such a use goes to
-- the host (WTOOLDUR), which runs it on that player's inventory.
-- Keypad doors (BP_KeypadDoor, replicated): the code is rolled at BeginPlay on
-- every machine (@113-221, the note gets it): the client's note showed another
-- code than the host's door. A client's press goes the server path and the
-- HOST's OnServerExecuteInteract opened the keypad on the HOST's screen
-- (@622 Create(self) for player 0). Now: the host's codes go to the clients
-- (WKEYCODE, door and note); the keypad the host's server path opened for a
-- client is closed again the widget's own way (PausePressed) and that client
-- opens the game's KeypadUI for its door (WKEYUI); its entry goes to the host
-- (WKEYTRY), which runs the door's CorrectCode / IncorrectCode (MC_OpenDoor
-- for everyone, its noise) for that player.
-- Scanner / keycard / keypad door XP and notes on the host: their server path
-- asks for player 0 (FindKeycard's "No Keycard Available" @547 and XP @705,
-- the keycard door's XP @3219, the keypad door's @3362): the host got them for
-- a client's use. The client says which of them it is looking at (WPAIM, from
-- OnBeginInteract / OnEndInteract); while it is within 7 m the scope resolver
-- answers that player for them. The host's copy of a client's controller has
-- no HUD and no real XP (sdc_progress: progression lives on the client): the
-- host sends the XP (WPXP) and the note (WPNOTE) to that player.

LK.PATHS = {
    ui = "/Game/UI/Lockpick/LockpickUI.LockpickUI_C",
    lockpick = "/Game/Inventory/Items/DataAssets/Other/DA_Lockpick.DA_Lockpick",
    keypad = "/Game/Blueprints/Other/Doors/Keypad/BP_KeypadDoor.BP_KeypadDoor_C",
    keypad_ui = "/Game/UI/Widgets/Other/KeypadUI.KeypadUI_C",
}
LK.AIM_S = 120      -- s: how long a WPAIM counts without a new one
LK.AIM_CM = 700     -- cm: that player still near the object
LK.CACHE_S = 0.5    -- s: the count is re-read this often (the minigame asks every frame)
LK.HOLD_S = 3       -- s: a pick broken here counts as gone this long while the host's change is on its way
LK.SHOW_S = 0.25    -- s: the minigame's count text re-checked this often
LK.LOGS = 60        -- count / text log lines per session (M.stats.lk_counts)
LK.WIDGETS = "inventory widgets"
-- client: where the last count came from; a broken pick's count; the count on screen
LK.src, LK.held, LK.held_at = "none", nil, -100
LK.shown_w, LK.shown_n, LK.shown_at = nil, -1, -100

-- ---------------------------------------------------------------------------
-- Lock picking (client)
-- ---------------------------------------------------------------------------

-- The lockpicks in one inventory widget (and the containers inside its items).
function LK.scan(w, depth, seen, uids)
    if depth > 4 or not ue.valid(w) then return 0 end
    local k = addr(w)
    if not k or seen[k] then return 0 end
    seen[k] = true
    local n = 0
    for _, slot in ipairs(PF.list_of(ue.prop(w, "ArrayOfItems"))) do
        if ue.valid(slot) then
            local da = ue.prop(slot, "JigDataAsset")
            if ue.valid(da) and ue.short(da) == "DA_Lockpick" then
                local u = guid_str(ue.prop(slot, "ItemUniqueID"))
                if u == "" or not uids[u] then
                    uids[u] = true
                    n = n + (tonumber(ue.prop(slot, "ItemCount")) or 1)
                end
            end
            local special = ue.prop(slot, "SpecialContainerRef")
            if ue.valid(special) then
                for _, c in ipairs(PF.list_of(ue.prop(special, "AllContainers"))) do n = n + LK.scan(c, depth + 1, seen, uids) end
            end
            n = n + LK.scan(ue.prop(slot, "SlotContainer"), depth + 1, seen, uids)
        end
    end
    return n
end

-- This player's lockpicks as its own inventory widgets show them (cached
-- LK.CACHE_S: the minigame asks every frame). A pick that broke here counts as
-- gone at once - single player's BreakLockpick consumes it (@621) before the
-- next frame's GetLockpickAmount - until the host's change reaches the widgets
-- (or LK.HOLD_S passed without it: then the widgets are right again).
function LK.count()
    local now = clock()
    if now - LK.counted_at < LK.CACHE_S then return LK.counted end
    local n, src = 0, "no inventory component"
    local pawn = ue.local_pawn()
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    if ue.valid(jig) then
        src = LK.WIDGETS
        local seen, uids = {}, {}
        for _, w in ipairs(PF.list_of(ue.prop(jig, "LocalJSIContainers"))) do n = n + LK.scan(w, 0, seen, uids) end
        if n == 0 then
            -- (the game's own lookup in the same widgets: at least one)
            local da = ue.loaded_asset(LK.PATHS.lockpick, "world")
            local out = {}
            if da and pcall(function() jig:FindJigItemByDA(da, {}, true, false, 1, out) end) and out.Result == true then
                n, src = 1, "the game's FindJigItemByDA: at least one"
            end
        end
    end
    LK.src = src
    if LK.held then
        local held, ago = LK.held, now - LK.held_at
        if src == LK.WIDGETS and n > held and ago <= LK.HOLD_S then
            n, src = held, "a pick broke here, the host's change is on its way"
        else
            LK.held, LK.counted = nil, n   -- (the line below is this change's log line)
            M.stats.lk_counts = M.stats.lk_counts + 1
            log.info("world: lockpicks here: %d (%s, %.1f s after the break: %s)", n, src, ago,
                n <= held and "the host took the broken pick" or "the host's change never came, the widgets count again")
        end
    end
    if n ~= LK.counted and M.stats.lk_counts < LK.LOGS then
        M.stats.lk_counts = M.stats.lk_counts + 1
        log.info("world: lockpicks here: %d (%s; the minigame goes on while it is not 0)", n, src)
    end
    LK.counted, LK.counted_at = n, now
    return n
end

-- The count on the minigame's screen. LockpickTxt.Text is bound (the widget's
-- Bindings) to GetLockpickAmountText, whose only parameter is its return
-- value: UE4SS gives a Blueprint hook the parameters without it (LuaMod
-- script_hook skips ReturnValue), so LK.on_amount_text never got it and the
-- binding showed the game's own count over the client's empty
-- MainJigContainers - "Lockpicks: 0" while the gate (out Lockpicks) had the
-- real count. UTextBlock.SetText shows this count and unbinds that binding
-- (UMG's own); GetText is what the screen shows, re-checked every LK.SHOW_S
-- and whenever the count or the widget changes. `w`: the hook's own widget.
function LK.show(w, n)
    if not FText or not ue.valid(w) then return end
    local now = clock()
    local k = addr(w)
    if k == LK.shown_w and n == LK.shown_n and now - LK.shown_at < LK.SHOW_S then return end
    LK.shown_at = now
    local tb = ue.prop(w, "LockpickTxt")
    if not ue.valid(tb) then return end
    local changed = k ~= LK.shown_w or n ~= LK.shown_n
    LK.shown_w, LK.shown_n = k, n
    local want = string.format("Lockpicks: %d", n)
    local was = ue.str(ue.try(LK.text_of, tb))
    if was == want then return end
    local ok = pcall(LK.set_text, tb, want)
    if changed and M.stats.lk_counts < LK.LOGS then
        M.stats.lk_counts = M.stats.lk_counts + 1
        log.info("world: lockpick minigame text '%s' -> '%s' (this player's count; set %s, reads '%s')", was, want,
            ok and "ok" or "FAILED", ue.str(ue.try(LK.text_of, tb)))
    end
end

function LK.text_of(tb) return tb:GetText() end
function LK.set_text(tb, s) tb:SetText(FText(s)) end

-- LockpickUI.GetLockpickAmount(out Lockpicks) -> Text (post, client; from
-- its Tick @576 every frame): the count (the out parameter is the minigame's
-- gate @617) and the same count on the screen.
function LK.on_amount(c, a_p, b_p)
    if S.role ~= "client" or not on("world_containers") then return end
    local n = LK.count()
    for _, p in ipairs({ a_p, b_p }) do
        local v = get(p)
        if type(v) == "number" then pcall(function() p:set(n) end)
        elseif v ~= nil and FText then pcall(function() p:set(FText(string.format("Lockpicks: %d", n))) end) end
    end
    LK.show(get(c), n)
end

-- LockpickUI.GetLockpickAmountText -> Text (post, client: its text binding).
-- A Blueprint hook gets no return value (r_p is nil in UE4SS 3.0.1): only
-- for a hook that passes one. The text is LK.show's; never set it from here
-- (this runs while Slate reads that very binding).
function LK.on_amount_text(_, r_p)
    if S.role ~= "client" or not on("world_containers") or r_p == nil or not FText then return end
    local n = LK.count()
    pcall(function() r_p:set(FText(string.format("Lockpicks: %d", n))) end)
end

-- LockpickUI.BreakLockpick (post, client; its timer every 0.1 s of a wrong
-- try): a pick that broke is back at durability 25 (@766) - only then. Its
-- ServerFindThenConsumeByItemID (@621) found nothing in the client's empty
-- MainJigContainers: the host takes it, and here it is gone at once (the
-- minigame stops on the next frame when it was the last one, as in single
-- player; with more it goes on with a fresh pick, as there too).
function LK.on_break(c)
    if S.role ~= "client" or not on("world_containers") then return end
    local w = c and c:get()
    if ue.prop(w, "UseLockpick") ~= true then return end
    local d = tonumber(ue.prop(ue.prop(w, "LPRef"), "LPDurability"))
    if not d or d < 24.99 then return end
    local now = clock()
    if now - LK.break_at < 0.3 then return end
    LK.break_at = now
    local before = LK.count()
    if not to_host("WLPBREAK") then
        LK.counted_at = -100
        return
    end
    M.stats.lk_breaks = M.stats.lk_breaks + 1
    if LK.src == LK.WIDGETS then
        LK.held, LK.held_at = math.max(0, before - 1), now
        LK.counted, LK.counted_at = LK.held, now
        log.info("world: a lockpick broke here: %d -> %d lockpicks (the host takes it out of this player's inventory)",
            before, LK.held)
    else
        LK.counted_at = -100
        log.info("world: a lockpick broke here (count from %s: re-read; the host takes it out of this player's inventory)",
            LK.src)
    end
end

-- WLPBREAK   (client -> host): one DA_Lockpick out of that player's inventory.
function LK.break_msg(_, pc)
    if not is_host() or not on("world_containers") then return end
    local k = addr(pc) or -1
    local now = clock()
    if now - (LK.break_host[k] or -100) < 0.25 then return end
    LK.break_host[k] = now
    local pawn = ue.pawn_of(pc)
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    local da = ue.loaded_asset(LK.PATHS.lockpick, "world")
    local out = {}
    local ok = ue.valid(jig) and da ~= nil
        and pcall(function() jig:ServerFindThenConsumeByItemID(da, 1, out) end) and out.Result == true
    M.stats.lk_breaks = M.stats.lk_breaks + 1
    log.info("world: %s broke a lockpick: %s", ue.short(pc), ok and "one taken out of its inventory"
        or "none found in its inventory on the host")
end

-- <BP_LockedDoor | BP_MASTER_PicklockContainer>.LockpickSuccessful (post,
-- client): unlocked here (@1692 / @690) -> the host's copy too, now.
function LK.on_picked(c)
    if S.role ~= "client" or applying > 0 then return end
    local o = c and c:get()
    if not level_actor(o) then return end
    local p = path_of(o)
    if p and to_host("WUNLOCK", pack(p)) then
        M.stats.lk_unlocks = M.stats.lk_unlocks + 1
        log.info("world: lock of %s picked here: unlocked on the host too", ue.short(o))
    end
end

-- WUNLOCK|path   (client -> host -> the other clients)
function LK.unlock_msg(f, pc)
    if not on("world_doors") and not on("world_containers") then return end
    local p = unpack_path(f[1])
    local o = find(p)
    if not o then
        if S.role == "client" then later("unlock", p, nil) end
        return
    end
    if ue.prop(o, "IsLocked?") == true then ue.set_prop(o, "IsLocked?", false) end
    if is_host() then
        M.stats.lk_unlocks = M.stats.lk_unlocks + 1
        log.info("world: %s picked the lock of %s: unlocked for everyone", ue.short(pc), ue.short(o))
        to_others(pc, "WUNLOCK", pack(p))
    end
end

-- ---------------------------------------------------------------------------
-- Tool wear (client -> host)
-- ---------------------------------------------------------------------------

-- BP_JigComponent.ServerFuncUpdateDurabilityByUID(UID, MinusDur,
-- DestroyItemIfZeroDur?, out NewDur) (post, client): remembered for the
-- world tool use whose post-hook comes right after it (same call).
function LK.on_dur(c, uid_p, minus_p, destroy_p)
    if S.role ~= "client" then return end
    local comp = c and c:get()
    local owner = comp and ue.try(function() return comp:GetOwner() end)
    if not owner or not locally_controlled(owner) then return end
    local u = guid_str(get(uid_p))
    local m = num(get(minus_p), 0)
    if u == "" or m <= 0 then return end
    LK.dur = { u = u, m = m, destroy = get(destroy_p) == true, t = clock() }
end

-- BP_LockedDoor.FindCrowbar / BP_MASTER_ToolRequiredContainer.FindItem /
-- HoldToInteract (post, client): the wear of that use to the host.
function LK.on_tool(c)
    if S.role ~= "client" or not LK.dur then return end
    local d = LK.dur
    LK.dur = nil
    if clock() - d.t > 0.05 then return end
    local o = c and c:get()
    if to_host("WTOOLDUR", d.u, string.format("%.3f", d.m), d.destroy and "1" or "0", ue.short(o)) then
        M.stats.lk_tools = M.stats.lk_tools + 1
        log.info("world: tool %s worn by %.1f using %s here: sent to the host", d.u, d.m, ue.short(o))
    end
end

-- WTOOLDUR|uid|minus|destroy|what   (client -> host): the game's wear on that
-- player's item (ServerFuncUpdateDurabilityByUID tells the client).
function LK.tool_msg(f, pc)
    if not is_host() then return end
    local g = parse_guid(f[1])
    local m = math.max(0, math.min(100, num(f[2], 0)))
    local pawn = ue.pawn_of(pc)
    local jig = pawn and ue.prop(pawn, "BP_JigMultiplayer")
    if not g or m <= 0 or not ue.valid(jig) then return end
    local k = addr(pc) or -1
    local now = clock()
    if now - (LK.tool_host[k] or -100) < 0.2 then return end
    LK.tool_host[k] = now
    local out = {}
    local ok, err = pcall(function() jig:ServerFuncUpdateDurabilityByUID(g, m, f[3] == "1", out) end)
    M.stats.lk_tools = M.stats.lk_tools + 1
    log.info("world: %s's tool %s worn by %.1f (%s) on the host%s", ue.short(pc), tostring(f[1]), m, tostring(f[4] or "?"),
        ok and string.format(": now %s", tostring(out.NewDur)) or (" FAILED " .. tostring(err)))
end

-- ---------------------------------------------------------------------------
-- Keypad doors
-- ---------------------------------------------------------------------------

-- Join: the host's codes (door and its note).
function LK.snapshot(pc)
    local n = 0
    for _, d in ipairs(ue.find_all("BP_KeypadDoor_C")) do
        local code = level_actor(d) and tonumber(ue.prop(d, "Code"))
        local p = code and path_of(d)
        if p then
            Q.send(pc, "WKEYCODE", pack(p), string.format("%d", code))
            n = n + 1
        end
    end
    return n
end

function LK.set_code(d, code)
    ue.set_prop(d, "Code", code)
    local note = ue.prop(d, "NoteRef")
    if ue.valid(note) then ue.set_prop(note, "Code", code) end
end

-- WKEYCODE|door|code   (host -> client)
function LK.keycode_msg(f)
    if S.role ~= "client" or not on("world_doors") then return end
    local d = find(unpack_path(f[1]))
    local code = tonumber(f[2])
    if not d or not code then return end
    if tonumber(ue.prop(d, "Code")) ~= code then
        LK.set_code(d, code)
        log.info("world: keypad code of %s as on the host (its note too)", ue.short(d))
    end
end

-- BP_KeypadDoor.OnServerExecuteInteract(Option, ByActor, Payload) (post,
-- host): a remote player's press opened the keypad here, on the host's screen.
function LK.on_keypad_server(c, _, by_p)
    if not is_host() or not on("world_doors") then return end
    local d = c and c:get()
    local pc = player_of_character(get(by_p))
    if not pc or not level_actor(d) then return end
    local da = addr(d)
    local closed = 0
    for _, w in ipairs(ue.find_all("KeypadUI_C")) do
        if ue.valid(w) and addr(ue.prop(w, "DoorRef")) == da and ue.try(function() return w:IsInViewport() end) == true then
            -- the widget's own close (@868: off the screen, the host's input back)
            if pcall(function() w:PausePressed() end) then closed = closed + 1 end
        end
    end
    if closed == 0 then return end
    LK.aim_set(d, pc)
    local p = path_of(d)
    Q.now(pc, "WKEYUI", pack(p), string.format("%d", tonumber(ue.prop(d, "Code")) or 0))
    M.stats.lk_keypads = M.stats.lk_keypads + 1
    log.info("world: %s pressed the keypad of %s: opened on that player's screen, not the host's", ue.short(pc), ue.short(d))
end

-- WKEYUI|door|code   (host -> the presser): the game's keypad, here.
function LK.keyui_msg(f)
    if S.role ~= "client" or not on("world_doors") then return end
    local p = unpack_path(f[1])
    local d = find(p)
    local code = tonumber(f[2])
    if not d or not code then return end
    LK.set_code(d, code)
    local cls = load_object(LK.PATHS.keypad_ui)
    local wl = ue.widget_lib()
    local pc = ue.local_pc()
    if not (cls and wl and pc) then
        log.warn("world: keypad of %s: no KeypadUI / controller here", ue.short(d))
        return
    end
    local w = ue.try(function() return wl:Create(d, cls, pc) end)
    if not ue.valid(w) then return end
    -- as the door's own server path does (@622-964); its Construct reads
    -- AcceptedCode from DoorRef.Code (@1122-1165)
    ue.set_prop(w, "DoorRef", d)
    local pawn = ue.local_pawn()
    apply(function()
        w:AddToViewport(2)
        if pawn then pawn:DisableInput(pc) end
        wl:SetInputMode_GameAndUIEx(pc, w, 2, false, false)
    end)
    ue.set_prop(pc, "bShowMouseCursor", true)
    ue.set_prop(w, "AcceptedCode", code)
    LK.ui[addr(w) or -1] = p
    M.stats.lk_keypads = M.stats.lk_keypads + 1
    log.info("world: keypad of %s opened here (the host checks the code)", ue.short(d))
end

-- KeypadUI.SetCurrentCode(Num) (post, client): a keypad this module opened;
-- a full entry (@424-746) goes to the host (the door's delegates are not
-- bound here: the host runs CorrectCode / IncorrectCode).
function LK.on_keypad_digit(c)
    if S.role ~= "client" then return end
    local w = c and c:get()
    local k = addr(w)
    local p = k and LK.ui[k]
    if not p then return end
    local cur = ue.str(ue.prop(w, "CurrentCode"))
    local acc = string.format("%d", tonumber(ue.prop(w, "AcceptedCode")) or 0)
    if #cur < #acc then return end
    LK.ui[k] = nil
    if to_host("WKEYTRY", pack(p), cur) then
        log.info("world: code entered at %s: sent to the host", ue.short(find(p)))
    end
end

-- WKEYTRY|door|code   (client -> host)
function LK.keytry_msg(f, pc)
    if not is_host() or not on("world_doors") then return end
    local d = find(unpack_path(f[1]))
    local pawn = ue.pawn_of(pc)
    if not d or not pawn then return end
    local k = addr(pc) or -1
    local now = clock()
    if now - (LK.key_host[k] or -100) < 0.5 then return end
    LK.key_host[k] = now
    local right = tostring(f[2]) == string.format("%d", tonumber(ue.prop(d, "Code")) or -1)
    ue.set_prop(d, "CurrentActor", pawn)
    LK.aim_set(d, pc)
    -- CorrectCode @1219: MC_PlaySound, MC_OpenDoor(CurrentActor); IncorrectCode @1199: sound, noise 8000
    local ok = apply(function() if right then d:CorrectCode() else d:IncorrectCode() end end)
    M.stats.lk_keypads = M.stats.lk_keypads + 1
    log.info("world: %s entered the %s code of %s: %s on the host (ok=%s)", ue.short(pc), right and "right" or "WRONG",
        ue.short(d), right and "the door opens for everyone" or "the wrong-code sound and noise", tostring(ok))
end

-- ---------------------------------------------------------------------------
-- The player at a scanner / keycard door / keypad door (host scope)
-- ---------------------------------------------------------------------------

-- <class>.OnBeginInteract / OnEndInteract (post, client): looking at it.
function LK.on_aim(c)
    if S.role ~= "client" or not on("world_doors") then return end
    local o = c and c:get()
    if not level_actor(o) then return end
    local p = path_of(o)
    if p and LK.aimed ~= p then
        LK.aimed = p
        to_host("WPAIM", pack(p), "1")
    end
end

function LK.on_unaim(c)
    if S.role ~= "client" then return end
    local o = c and c:get()
    local p = o and path_of(o)
    if p and LK.aimed == p then
        LK.aimed = nil
        to_host("WPAIM", pack(p), "0")
    end
end

function LK.aim_set(o, pc)
    local a = addr(o)
    if a then LK.aim[a] = { pc = pc, t = clock() } end
end

-- WPAIM|path|1/0   (client -> host)
function LK.aim_msg(f, pc)
    if not is_host() then return end
    local o = find(unpack_path(f[1]))
    local a = o and addr(o)
    if not a then return end
    if f[2] == "1" then
        LK.aim[a] = { pc = pc, t = clock() }
    elseif LK.aim[a] and addr(LK.aim[a].pc) == addr(pc) then
        LK.aim[a] = nil
    end
end

-- Resolver (host): the remote player looking at it, still near it.
function LK.aim_who(wco, a)
    local e = LK.aim[a]
    if not e then return nil end
    if clock() - e.t > LK.AIM_S or not remote_pc(e.pc) then
        LK.aim[a] = nil
        return nil
    end
    local pawn = ue.pawn_of(e.pc)
    local pl, ol = ue.location(pawn), ue.location(wco)
    if not pl or not ol or d2(pl, ol) > LK.AIM_CM * LK.AIM_CM then return nil end
    -- (the host standing nearer to it: the host's own use)
    local hl = ue.location(ue.local_pawn())
    if hl and d2(hl, ol) < d2(pl, ol) then return nil end
    LK.redir[a] = clock()
    M.stats.scopes = M.stats.scopes + 1
    return e.pc
end

function LK.redirected(o)
    local t = LK.redir[addr(o) or -1]
    return t ~= nil and clock() - t < 0.5
end

-- BP_BunkerScanner.MC_CallInteract(InteractingActor) (post, host): what the
-- check did for a remote player goes to that player.
function LK.on_scan(c, actor_p)
    local s = c and c:get()
    local pc = player_of_character(get(actor_p))
    if not pc or not level_actor(s) then return end
    local p = path_of(s)
    if ue.prop(s, "Unlocked?") ~= true and ue.prop(s, "KeycardRequired?") == true then
        -- FindKeycard @547, now that player's (unless sdc_notes relayed the game's own already)
        local notes = PW.notes()
        if notes and notes.sent_to and notes.sent_to(pc, "No Keycard Available", 2) then
            log.info("world: %s has no keycard for %s: the game's note went to that player", ue.short(pc), ue.short(s))
            return
        end
        Q.now(pc, "WPNOTE", "No Keycard Available")
        log.info("world: %s has no keycard for %s: told that player", ue.short(pc), ue.short(s))
    elseif LK.redirected(s) and p then
        -- its XP (@705-833, CurrentLevel x 200) went to that player's copy here
        Q.now(pc, "WPXP", pack(p), "200", "0")
        log.info("world: %s unlocked %s: its XP to that player", ue.short(pc), ue.short(s))
    end
end

-- BP_KeycardDoor / BP_HangarDoor.MC_OpenDoor(Actor) (post, host, from
-- on_rdoor): the host's card check passed for a remote player (its XP / note
-- asked for player 0: keycard door @3219-3810, hangar door @2499-3090).
function LK.on_kdoor_mc(d, actor_p)
    if not PW.is_card_door(d) then return end
    local pc = player_of_character(get(actor_p))
    local p = path_of(d)
    if not pc or not p or not LK.redirected(d) then return end
    Q.now(pc, "WPXP", pack(p), "200", "1")
    log.info("world: %s opened %s with its keycard on the host: its XP to that player", ue.short(pc), ue.short(d))
end

function LK.reset()
    LK.counted, LK.counted_at, LK.break_at, LK.dur, LK.aimed = 0, -100, -100, nil, nil
    LK.src, LK.held, LK.held_at = "none", nil, -100
    LK.shown_w, LK.shown_n, LK.shown_at = nil, -1, -100
    LK.break_host, LK.tool_host, LK.key_host, LK.ui, LK.aim, LK.redir = {}, {}, {}, {}, {}, {}
end

-- ===========================================================================
-- Hooks
-- ===========================================================================

local function guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log.err_throttled("world." .. name, "world: %s hook: %s", name, tostring(err)) end
    end
end

-- { path, name, fn, native = true for a native pre-hook }
local HOOKS = {
    { PATH.LOOT .. ":OpenContainer", "loot", on_open_container },
    { PATH.PICKLOCK .. ":OpenContainer", "loot", on_open_container },
    { PATH.TOOLBOX .. ":OpenContainer", "loot", on_open_container },
    { PATH.LOOT .. ":Bind_Refill", "refill", on_refill },
    { PATH.LOOT .. ":OnExecuteInteract", "store", on_interact_container },
    { PATH.LOOT .. ":PauseInteract", "noise", on_loot_noise },
    { PATH.TOOLBOX .. ":PauseInteract", "noise", on_loot_noise },
    { PATH.LOCKED_DOOR .. ":Event_Door", "door", function(c) on_door(c, "d") end },
    { PATH.LOCKED_DOOR .. ":EventDoorBehind", "door", function(c) on_door(c, "b") end },
    { PATH.LAB_DOOR .. ":Event_AutoDoor", "door", function(c) on_door(c, "a") end },
    { PATH.MELEE .. ":HitFoliageTree", "foliage", on_hit_foliage },
    { PATH.MELEE .. ":HitFoliageRock", "foliage", on_hit_foliage },
    { PATH.MELEE .. ":HitTrashObject", "trash-hit", on_hit_trash },
    { PATH.GFL .. ":CreateNotificationUI", "notify", on_notification },
    { PATH.TRASH .. ":" .. PATH.TRASH_DESTROYED, "trash", on_trash_destroyed },
    { PATH.BARREL .. ":Damage_Object", "damage", on_damage_object },
    { PATH.INFEST .. ":Damage_Object", "damage", on_damage_object },
    { PATH.FIREARM .. ":Trace_Impact", "impact", on_trace_impact },
    { PATH.FIREARM .. ":Trace_ImpactBulletHole", "impact", on_trace_impact },
    { PATH.BARREL .. ":Event_Explode", "explode", on_explode },
    { MN.CLS.w .. ":Event_Explode", "mine", function(c) MN.on_explode(c, "w") end },
    { MN.CLS.b .. ":Event_Explode", "mine", function(c) MN.on_explode(c, "b") end },
    { PATH.INFEST .. ":Event_OnDestroyed", "infest", on_infest_destroyed },
    { PATH.BUILDING .. ":Event_LaunchBuildMode", "build", on_launch_build },
    { PATH.BUILDING .. ":SpawnBuild", "build", on_spawn_build },
    { PATH.BUILDABLE .. ":ReplacingObject", "build", on_replacing },
    { PATH.PLAYER .. ":JigMP_OnRequestDropItem", "grant", on_player_drop },
    { PATH.JIG .. ":JigTryAddItemSomewhere", "salvage-roll", HV.on_try_add },
    { EV.MANAGER .. ":SetBloodMoon", "bloodmoon", EV.on_blood_moon },
    { EV.MANAGER .. ":AirdropSpawn", "airdrop", EV.on_airdrop_timer },
    { EV.MANAGER .. ":SpawnAirdrop", "airdrop", EV.on_airdrop_roll },
    { EV.MANAGER .. ":Jet_Spawn", "jets", EV.on_jet_timer },
    { EV.MANAGER .. ":SpawnJet", "jets", EV.on_jet_roll },
    { EV.CRATE .. ":ReceiveHit", "airdrop", EV.on_crate_hit },
    { LK.PATHS.ui .. ":GetLockpickAmount", "lockpick", LK.on_amount },
    { LK.PATHS.ui .. ":GetLockpickAmountText", "lockpick", LK.on_amount_text },
    { LK.PATHS.ui .. ":BreakLockpick", "lockpick", LK.on_break },
    { PATH.LOCKED_DOOR .. ":LockpickSuccessful", "lockpick", LK.on_picked },
    { PATH.PICKLOCK .. ":LockpickSuccessful", "lockpick", LK.on_picked },
    { PATH.JIG .. ":ServerFuncUpdateDurabilityByUID", "tool-wear", LK.on_dur },
    { PATH.LOCKED_DOOR .. ":FindCrowbar", "tool-wear", LK.on_tool },
    { PATH.TOOLBOX .. ":FindItem", "tool-wear", LK.on_tool },
    { PATH.TOOLBOX .. ":HoldToInteract", "tool-wear", LK.on_tool },
    { LK.PATHS.keypad .. ":OnServerExecuteInteract", "keypad", LK.on_keypad_server },
    { LK.PATHS.keypad_ui .. ":SetCurrentCode", "keypad", LK.on_keypad_digit },
    { SPAWN_FN, "spawn", on_spawn, native = true },
    { PF.SPAWN_AI_FN, "spawn-ai", PF.on_spawn_ai, native = true },
    { PW.PATHS.cbox .. ":Damage_Object", "power", PW.on_exec },
    { PW.PATHS.siren .. ":ActivateSiren", "siren", PW.on_siren },
    { PW.PATHS.siren .. ":DeactivateSiren", "siren", PW.on_siren },
    { PW.PATHS.scan .. ":MC_CallInteract", "scanner", PW.on_scan },
    { PW.PATHS.nuke .. ":Damage_Object", "damage", on_damage_object },
    { PW.PATHS.nuke .. ":MC_Explode", "explode", on_explode },
    { PW.PATHS.save, "power-save", PW.on_save },
    { PW.PATHS.delete, "power-delete", PW.on_delete, native = true },
}
for _, d in ipairs(RDOORS) do HOOKS[#HOOKS + 1] = { d[1] .. ":MC_OpenDoor", "rdoor", on_rdoor } end
-- the player at a scanner / keycard / hangar / keypad door (the host's scope, LK)
for _, path in ipairs({ PW.PATHS.scan, PW.PATHS.kdoor, PW.PATHS.hangar, LK.PATHS.keypad }) do
    HOOKS[#HOOKS + 1] = { path .. ":OnBeginInteract", "aim", LK.on_aim }
    HOOKS[#HOOKS + 1] = { path .. ":OnEndInteract", "aim", LK.on_unaim }
end
-- every press of a puzzle / power object (and the keycard / hangar door: its card)
for _, k in ipairs({ "pgen", "lgen", "lever", "cbox", "sw", "ssw", "sdoor", "secure", "entr", "scan", "siren", "radio", "kdoor",
                     "hangar" }) do
    HOOKS[#HOOKS + 1] = { PW.PATHS[k] .. ":OnExecuteInteract", "power", PW.on_exec }
end

HOOKS.missed = {}   -- [path] = true: its "not ready" was logged once
local function try_hooks(force, natives_only)
    local now = clock()
    if not force and now - hook_try_at < 3 then return end
    if not natives_only then hook_try_at = now end
    for _, h in ipairs(HOOKS) do
        local path = h[1]
        if not hooked[path] and (h.native or not natives_only) then
            local cb = guarded(h[2], h[3])
            local ok, err
            if h.native then
                ok, err = ue.hook_native(path, "world." .. h[2], cb)
            else
                ok, err = pcall(RegisterHook, path, cb)
            end
            if ok then
                hooked[path] = true
                log.info("world: hook ok (%s)", path:match("([%w_]+%.[%w_]+:[%w_%?]+)$") or path)
            elseif not HOOKS.missed[path] then
                -- once per hook: in the main menu most classes are not loaded and
                -- the retry every few seconds logged a full traceback each time
                -- (0.7.1: 1802 of them in 8 min in the menu); it hooks later
                HOOKS.missed[path] = true
                log.debug("world: hook not ready yet %s (%s); retried quietly until it hooks", path,
                    (tostring(err):match("^[^\r\n]*") or "?"))
            end
        end
    end
end

-- ===========================================================================
-- Refill batches and the per-client queues (host), refills applied a few per
-- tick (client)
-- ===========================================================================

function Q.cref_add(p)
    if Q.cref_set[p] then return end
    Q.cref_set[p] = true
    Q.cref[#Q.cref + 1] = p
end

-- WLOOTR|p1;p2;...   (host -> client: these boxes refilled on the host)
local function refill_msg(f)
    if S.role ~= "client" or not on("world_containers") then return end
    for _, e in ipairs(split(f[1], ";")) do Q.cref_add(unpack_path(e)) end
end

-- Client: Bind_Refill (ContainerLooted false, "[Looted]" text off, the
-- magnifier back) on at most CREF_PER_TICK boxes per tick; a box that is not
-- marked searched here needs no call.
function Q.client_pump()
    local n = 0
    while Q.cref_head <= #Q.cref and n < Q.CREF_PER_TICK do
        local p = Q.cref[Q.cref_head]
        Q.cref[Q.cref_head] = nil
        Q.cref_head = Q.cref_head + 1
        Q.cref_set[p] = nil
        loot_sent[p] = nil
        local w = Q.cwave or { done = 0, idle = 0, missing = 0 }
        Q.cwave = w
        -- a camp container: its place no longer searched (a copy that comes
        -- back later stays unsearched)
        local camp = CB.is_key(p)
        if camp then CB.forget(p) end
        local box = CB.box_of(p)
        if box and camp then loot_sent[CB.key_of(box) or p] = nil end
        if not box then
            w.missing = w.missing + 1
        elseif looted_of(box) then
            apply(function() box:Bind_Refill() end)
            w.done = w.done + 1
            n = n + 1
        else
            w.idle = w.idle + 1
        end
    end
    if Q.cref_head > #Q.cref then
        Q.cref, Q.cref_head = {}, 1
        local w = Q.cwave
        if w then
            Q.cwave = nil
            log.info("world: refill from the host: %d container(s) unsearched here, %d already were, %d not found",
                w.done, w.idle, w.missing)
        end
    end
end

-- Host: the refilled boxes of the last tick go out in batches; the queues
-- send at most PER_TICK messages per client; one summary line per wave.
function Q.host_pump()
    local pcs = remote_pcs()
    if #Q.refill > 0 then
        local batches = Q.batches(Q.refill)
        Q.refill = {}
        for _, pc in ipairs(pcs) do
            for _, b in ipairs(batches) do Q.push(pc, "WLOOTR", b) end
        end
        if Q.wave then Q.wave.batches = Q.wave.batches + #batches end
    end
    if next(Q.out) ~= nil then
        local by = {}
        for _, pc in ipairs(pcs) do
            local a = addr(pc)
            if a then by[a] = pc end
        end
        for a, q in pairs(Q.out) do
            local pc = by[a]
            if not pc then
                Q.out[a] = nil   -- that player left
            else
                local n = 0
                while q.head <= q.n and n < Q.PER_TICK do
                    local m = q.items[q.head]
                    q.items[q.head] = nil
                    q.head = q.head + 1
                    if m then
                        net.send_to(pc, table.unpack(m, 1, m.n))
                        n = n + 1
                    end
                end
                if q.head > q.n then Q.out[a] = nil end
            end
        end
    end
    local w = Q.wave
    if w and clock() - w.last > 3 and #Q.refill == 0 then
        Q.wave = nil
        local left = 0
        for _, q in pairs(Q.out) do left = left + (q.n - q.head + 1) end
        log.info("world: refill wave: %d container(s) refilled in %.1f s, %d sent to %d client(s) in %d batch(es), %d skipped (no client copy marked searched)%s",
            w.refilled, w.last - w.at, w.queued, #pcs, w.batches, w.skipped,
            left > 0 and string.format(", %d message(s) still queued", left) or "")
    end
end

-- ===========================================================================
-- Snapshot for a client that joined (or loaded the world again)
-- ===========================================================================

local function snapshot(pc)
    if not is_host() then return end
    -- every snapshot message goes through the queue (a few per tick)
    Q.all = true
    local parts = {}
    local function part(name, key, fn)
        if not on(key) then return end
        local ok, n = pcall(fn, pc)
        parts[#parts + 1] = string.format("%s=%s", name, ok and tostring(n) or ("ERR " .. tostring(n)))
    end
    part("containers", "world_containers", snapshot_loot)
    part("doors", "world_doors", snapshot_doors)
    part("felled", "world_harvest", snapshot_fol)
    part("scrap", "world_harvest", snapshot_salvage)
    part("trash", "world_objects", snapshot_trash)
    part("barrels", "world_objects", snapshot_barrels)
    part("infestations", "world_objects", snapshot_infest)
    part("random_nests", "world_objects", RI.snapshot)
    part("blood_moon", "world_objects", EV.snapshot)
    part("airdrop_crates", "world_prefabs", EV.crate_snapshot)
    part("keypads", "world_doors", LK.snapshot)
    part("puzzle", "world_doors", PW.snapshot)
    Q.all = false
    local q = Q.out[addr(pc) or -1]
    M.stats.snapshots = M.stats.snapshots + 1
    log.info("world: snapshot for %s: %s (%d message(s), %d per tick)", ue.short(pc), table.concat(parts, " "),
        q and (q.n - q.head + 1) or 0, Q.PER_TICK)
end

local function hi_msg(_, pc)
    if not is_host() or cfg.get("world_sync") == false then return end
    -- after the current call stack: FindAllOf over a few thousand containers
    local name = ue.name(pc)
    ue.delay("world-snapshot", 50, function()
        for _, p in ipairs(remote_pcs()) do
            if ue.name(p) == name then snapshot(p) return end
        end
    end)
end

-- ===========================================================================
-- Tick / reset / install
-- ===========================================================================

local function retry_pending()
    if #pending == 0 then return end
    local now = clock()
    local keep = {}
    for _, e in ipairs(pending) do
        local done = false
        if e.kind == "fol" then
            local r = fol_apply(e.path, e.args.loc or e.args, e.args.idx)
            done = r ~= nil
        elseif e.kind == "crate" then
            local a = EV.crate_find(e.path)
            if a then EV.crate_apply(a, EV.ccrates[e.path] or e.args, "found later") end
            done = a ~= nil
        elseif e.kind == "move" then
            done = MV.apply(e.path, e.args)
        else
            local o = find(e.path)
            if o then
                done = true
                if e.kind == "loot" then
                    loot_sent[e.path] = true
                    apply_loot(o, e.args == "u")
                elseif e.kind == "door" then
                    apply_door(o, e.args[1], e.args[2], e.args[3])
                elseif e.kind == "rdoor" then
                    rdoor_check(e.path, e.args, false)
                elseif e.kind == "pw" then
                    PW.apply_list({ e.path }, "found later")
                elseif e.kind == "salv" then
                    apply_salvage(o)
                elseif e.kind == "trash" then
                    trash_hide(o)
                elseif e.kind == "unlock" then
                    if ue.prop(o, "IsLocked?") == true then ue.set_prop(o, "IsLocked?", false) end
                elseif e.kind == "infest" then
                    if ue.prop(o, "IsDestroyed?") ~= true then apply(function() o:Event_OnDestroyed(nil, true) end) end
                    IX.unlock_primaries(false, "a nest found later")
                end
            end
        end
        if not done and now < e.till then keep[#keep + 1] = e end
    end
    pending = keep
    M.stats.pending = #pending
end

local last_slow = -100
PF.pass_at = -100
local function tick()
    if not S then return end
    local role = S.role
    if role ~= last_role then
        if last_role ~= nil then M.reset("role " .. tostring(last_role) .. " -> " .. tostring(role)) end
        last_role = role
    end
    if cfg.get("world_sync") == false then return end
    if role ~= "host" and role ~= "client" then return end
    try_hooks(false)
    local now = clock()
    if on("world_containers") then CB.pass(now) end
    -- mines whose 30 ms delay did not run
    if #MN.out > 0 and now - MN.out[1].t > 1 then MN.flush() end
    if role == "host" then
        Q.host_pump()
        if on("world_harvest") then HV.wait_pass(now) end
        if on("world_objects") then
            RI.host_pass(now)
            EV.host_pass()
        end
        if on("world_doors") then PW.host_tick(now) end
        if on("world_prefabs") then EV.crate_pass(now) end
    else
        Q.client_pump()
        if on("world_harvest") then
            HV.flush()
            HV.dress_pass(now)
        end
        if on("world_objects") then RI.client_pass(now) end
        if on("world_doors") then PW.client_tick(now) end
    end
    if now - last_slow < 2 then return end
    last_slow = now
    if now - cls_cache_at > 2 then cls_cache, weapon_pc, cls_cache_at = {}, {}, now end
    if on("world_prefabs") and now - PF.pass_at >= (role == "host" and 10 or 5) then
        PF.pass_at = now
        if role == "host" then PF.host_prefab_pass() else PF.client_only_pass() end
    end
    if role == "host" then
        for a, h in pairs(hitters) do if now - h.t > HIT_KEEP_S then hitters[a] = nil end end
        for a, t in pairs(grant_until) do if now > t then grant_until[a] = nil end end
        for a, b in pairs(horde_bind) do if now - b.t > 10 then horde_bind[a] = nil end end
        for k, t in pairs(HV.replay) do if now - t > 5 then HV.replay[k] = nil end end
        for k, r in pairs(HV.rate) do if now - r.t > 5 then HV.rate[k] = nil end end
        for k, mv in pairs(MV.moving) do if now - mv.at > 600 then MV.moving[k] = nil end end
    else
        if #pending_dmg > 0 and now - pending_dmg[#pending_dmg].t > 1 then pending_dmg = {} end
        retry_pending()
        if on("world_objects") then EV.client_pass() end
        if on("world_prefabs") then EV.crate_check() end
        if client_ready() and ue.local_pawn() then
            local cs = S.client
            local key = tostring(S.map) .. "|" .. tostring(cs.pc_key)
            if not snap_asked[key] then
                if not world_since or world_since.key ~= key then world_since = { key = key, t = now } end
                if now - world_since.t >= SNAP_AFTER_S then
                    snap_asked[key] = now
                    to_host("WHI")
                    log.info("world: asked the host for the world state")
                end
            end
        end
    end
end

function M.tick()
    local ok, err = pcall(tick)
    if not ok then log.err_throttled("world.tick", "world: tick: %s", tostring(err)) end
end

function M.reset(why)
    cls_cache, cls_cache_at, weapon_pc, swing = {}, 0, {}, nil
    hitters, grant_until = {}, {}
    fol_removed, fol_seen = {}, {}
    pending_harv, pending_dmg = nil, {}
    loot_sent, door_state, rdoor_toggled = {}, {}, {}
    pending, snap_asked, build = {}, {}, {}
    exploded, horde_bind = {}, {}
    MN.reset()
    Q.out, Q.all, Q.looted, Q.refill, Q.wave = {}, false, {}, {}, nil
    Q.cref, Q.cref_set, Q.cref_head, Q.cwave = {}, {}, 1, nil
    -- (CB.live stays, like HV.live: gone ones drop out when looked up)
    CB.keys, CB.nkeys, CB.fresh = {}, 0, next(CB.live) ~= nil
    cache = { block_cls = nil, harvest_cls = {}, scrap = nil, cue = nil, menu_cls = nil }
    world_since = nil
    -- (HV.live stays: harvestables seen by the watch around a role change;
    -- gone ones drop out when looked up)
    HV.recs, HV.out, HV.replay, HV.wait, HV.rate, HV.logged = {}, {}, {}, {}, {}, {}
    HV.dress_due, HV.last_add = 0, nil
    MV.moving, MV.marked = {}, {}
    -- (RI.live stays, like HV.live)
    RI.host, RI.recs, RI.dressed, RI.due, RI.scan_at = {}, {}, {}, 0, -100
    EV.moon, EV.shown, EV.manager_path, EV.jets, EV.next_try = false, nil, nil, {}, 0
    EV.ad = { landed = {}, seen = {}, last = "none yet" }
    EV.crates, EV.ccrates, EV.crate_at = {}, {}, 0
    PW.reset()
    LK.reset()
    IX.got, IX.own, IX.recv = {}, {}, {}
    log.info("world: reset (%s)", tostring(why))
end

function M.register_handlers()
    net.on("WHI", hi_msg)
    net.on("WLOOT", loot_msg)
    net.on("WLOOTS", loots_msg)
    net.on("WLOOTR", refill_msg)
    net.on("WSTORE", store_msg)
    net.on("WNOISE", noise_msg)
    net.on("WDOOR", door_msg)
    net.on("WRDOOR", rdoor_msg)
    net.on("WFOL", fol_msg)
    net.on("WFOLS", fols_msg)
    net.on("WHARV", harv_msg)
    net.on("WSALV", salv_msg)
    net.on("WTRASH", trash_msg)
    net.on("WDMG", dmg_msg)
    net.on("WBOOM", boom_msg)
    net.on("WMINE", MN.msg)
    net.on("WINF", infest_msg)
    net.on("WINFD", infest_destroyed_msg)
    net.on("WINFXP", IX.xp_msg)
    net.on("WBMODE", bmode_msg)
    net.on("WBUILT", built_msg)
    net.on("WHHIT", HV.hit_msg)
    net.on("WMOVE", MV.move_msg)
    net.on("WRINF", RI.msg)
    net.on("WBMOON", EV.moon_msg)
    net.on("WCRATE", EV.crate_msg)
    net.on("WLPBREAK", LK.break_msg)
    net.on("WUNLOCK", LK.unlock_msg)
    net.on("WTOOLDUR", LK.tool_msg)
    net.on("WKEYCODE", LK.keycode_msg)
    net.on("WKEYUI", LK.keyui_msg)
    net.on("WKEYTRY", LK.keytry_msg)
    net.on("WPAIM", LK.aim_msg)
    net.on("WPWS", PW.msg)
    net.on("WPSTEP", PW.step_msg)
    net.on("WPTRY", PW.try_msg)
    net.on("WPNOTE", PW.note_msg)
    net.on("WPXP", PW.xp_msg)
end

-- main.lua, right after sdc_respawn.install and before sdc_vehicles.install:
-- the scope chains in front of sdc_respawn's (sdc_vehicles later chains in
-- front of this one).
function M.install(state)
    local session = package.loaded["sdc_session"]
    S = state or (session and session.state)
    M.register_handlers()
    if ctx.scope_resolver ~= resolver then
        prev_resolver = ctx.scope_resolver
        ctx.scope_resolver = resolver
    end
    if ctx.set_idle_check then ctx.set_idle_check(resolver, M.resolver_idle) end
    if session and session.world_reset_hooks then
        session.world_reset_hooks.world = function(why) M.reset("world:" .. tostring(why)) end
    end
    -- native hooks and the new-object watch now: a client's level spawners
    -- run during its first map load, before the tick's role is "client"
    try_hooks(true, true)
    local okn, errn = pcall(NotifyOnNewObject, PF.PREFAB, function(o)
        local ok, err = pcall(PF.on_new_prefab, o)
        if not ok then log.err_throttled("world.prefab-new", "world: new prefab: %s", tostring(err)) end
    end)
    log.info("world: watching new camps (PrefabMaster_C) %s%s", okn and "ok" or "FAILED", okn and "" or (" " .. tostring(errn)))
    local okl, errl = pcall(NotifyOnNewObject, PF.LOOT, function(o)
        local ok, err = pcall(PF.on_new_loot, o)
        if not ok then log.err_throttled("world.loot-new", "world: new container: %s", tostring(err)) end
        ok, err = pcall(CB.on_new, o)
        if not ok then log.err_throttled("world.camp-new", "world: new camp container: %s", tostring(err)) end
    end)
    log.info("world: watching new loot containers (client-only ones, camps' searched state) %s%s", okl and "ok" or "FAILED",
        okl and "" or (" " .. tostring(errl)))
    -- lock-pick / tool containers are no BP_LootContainer (camps have them too)
    local ncb = 0
    for _, p in ipairs({ PATH.PICKLOCK, PATH.TOOLBOX }) do
        if pcall(NotifyOnNewObject, p, function(o)
            local ok, err = pcall(CB.on_new, o)
            if not ok then log.err_throttled("world.camp-new", "world: new camp container: %s", tostring(err)) end
        end) then ncb = ncb + 1 end
    end
    log.info("world: watching new lock-pick / tool containers %s", ncb == 2 and "ok" or "FAILED")
    local nh, errh = 0, nil
    for kind, p in pairs(HARVEST_CLASS) do
        local okh, e = pcall(NotifyOnNewObject, p, function(o)
            local ok, err = pcall(HV.on_new, o, kind)
            if not ok then log.err_throttled("world.harv-new", "world: new harvestable: %s", tostring(err)) end
        end)
        if okh then nh = nh + 1 else errh = e end
    end
    HV.watching = nh == 2
    log.info("world: watching new trees / rocks %s%s", HV.watching and "ok" or "FAILED (searched instead)",
        errh and (" " .. tostring(errh)) or "")
    local okr, errr = pcall(NotifyOnNewObject, PATH.INFEST, function(o)
        local ok, err = pcall(RI.on_new, o)
        if not ok then log.err_throttled("world.rinf-new", "world: new infestation: %s", tostring(err)) end
    end)
    local okj = pcall(NotifyOnNewObject, EV.JET, function(o)
        local ok, err = pcall(EV.on_new_jet, o)
        if not ok then log.err_throttled("world.jet-new", "world: new jet: %s", tostring(err)) end
    end)
    log.info("world: watching new infestations %s, jets %s%s", okr and "ok" or "FAILED (searched instead)",
        okj and "ok" or "FAILED", okr and "" or (" " .. tostring(errr)))
    log.info("sound relay WMINE (world_objects): a landmine's explosion on the host -> the clients within explosion_large_06_Cue's range + 5 m (%.0f m when the cue is not in memory), shown there by the copy's own Event_Explode or the same emitter / sound / decal calls at the host's point; a client's own mine explosion -> the host sets that mine off (damage, kills); one per mine and machine",
        (MN.RANGE + 500) / 100)
    log.info("world: installed (world_sync=%s containers=%s noise=%s doors=%s harvest=%s objects=%s build=%s to_inventory=%s; scope %s)",
        tostring(cfg.get("world_sync") ~= false), tostring(on("world_containers")), tostring(on("world_loot_noise")),
        tostring(on("world_doors")), tostring(on("world_harvest")), tostring(on("world_objects")),
        tostring(on("world_build")), tostring(on("world_resource_to_inventory")),
        ctx.SCOPE_API and (prev_resolver and "chained" or "first") or "MISSING (no SCOPE_API)")
end

function M.status_line()
    local s = M.stats
    local nh = 0
    for _ in pairs(hooked) do nh = nh + 1 end
    return string.format("world: %s hooks=%d/%d | loot sent=%d applied=%d (camps %d, missing %d, places kept %d) refills=%d storage=%d/%d noise=%d/%d | doors sent=%d applied=%d rfixed=%d | "
        .. "felled sent=%d applied=%d blocked=%d req=%d host=%d (found idx/ovl/miss=%d/%d/%d) shown=%d hits sent=%d host=%d dup=%d salvage=%d | "
        .. "trash=%d booms=%d infest=%d xp shared=%d primaries unlocked=%d dmg=%d/%d | "
        .. "mines host=%d set off for clients=%d own sent=%d shown copy=%d fx=%d already=%d | "
        .. "build modes=%d placed=%d tails=%d moves=%d/%d | camps blocked=%d ai=%d replicated=%d removed=%d | "
        .. "random nests=%d shown=%d moon=%d jets=%d waves blocked=%d airdrop rolls=%d planes=%d crates=%d placed=%d/%d | "
        .. "locks picked=%d breaks=%d tools=%d keypads=%d | "
        .. "puzzle objs=%d steps=%d host=%d sent=%d applied=%d tries=%d/%d restored=%d | "
        .. "scopes=%d grants=%d left=%d | snapshots=%d pending=%d",
        tostring(S and S.role), nh, #HOOKS, s.loot_sent, s.loot_applied, s.camp_applied, s.camp_missing, CB.nkeys, s.refills, s.store_sent, s.store_applied, s.noise_sent, s.noise_host,
        s.doors_sent, s.doors_applied, s.rdoors_fixed, s.fol_sent, s.fol_applied, s.harv_blocked, s.harv_requests,
        s.harv_host, s.fol_idx, s.fol_ovl, s.fol_miss, s.dressed, s.hits_sent, s.hits_host, s.hits_dup, s.salvage,
        s.trash, s.booms, s.infest, s.inf_shared, s.inf_unlocked, s.dmg_sent, s.dmg_host,
        s.mines, s.mines_host, s.mines_sent, s.mines_copy, s.mines_fx, s.mines_dup, s.build_modes, s.builds,
        s.build_tails, s.moves, s.moves_applied, s.prefab_blocked, s.prefab_ai_blocked, s.prefab_replicated, s.prefab_removed,
        s.rinf, s.rinf_shown, s.moon, s.jets, s.waves_blocked, s.ad_rolls, s.ad_planes, s.ad_crates, s.crate_sent, s.crate_snapped,
        s.lk_unlocks, s.lk_breaks, s.lk_tools, s.lk_keypads,
        PW.objs and #PW.objs or -1, s.pw_steps, s.pw_host, s.pw_sent, s.pw_applied, s.pw_tries_ok, s.pw_tries, s.pw_restored,
        s.scopes, s.grants, s.grant_drops, s.snapshots, s.pending)
end

-- main.lua: world.register_commands(add), next to savecheck.register_commands(add).
function M.register_commands(add)
    add("sdcoop_events", "airdrop / jet / explosion / dynamic event timers of this world (BP_EventManager)",
        function(_, reply) EV.report(reply) end)
    add("sdcoop_airdrop", "host: sdcoop_airdrop [force] - the game's own airdrop roll now (force: on, 100%, days > 5 for that roll)",
        function(params, reply) EV.cmd_airdrop(params, reply) end)
end

-- Test access (mock harness).
M._t = {
    hooks = HOOKS, kind_of_class = kind_of_class, pack = pack, unpack = unpack_path,
    parse_loc = parse_loc, parse_guid = parse_guid, split = split, send_list = send_list,
    hitters = function() return hitters end, pending = function() return pending end,
    fol_removed = function() return fol_removed end, resolver = resolver,
    on_open_container = on_open_container, loot_msg = loot_msg, loots_msg = loots_msg,
    on_interact_container = on_interact_container, store_msg = store_msg,
    on_spawn = on_spawn, on_hit_foliage = on_hit_foliage, fol_msg = fol_msg, harv_msg = harv_msg,
    on_door = on_door, door_msg = door_msg, rdoor_msg = rdoor_msg, on_damage_object = on_damage_object,
    on_trace_impact = on_trace_impact, dmg_msg = dmg_msg, on_explode = on_explode, boom_msg = boom_msg,
    on_player_drop = on_player_drop, bmode_msg = bmode_msg, built_msg = built_msg, on_notification = on_notification,
    salv_msg = salv_msg, trash_msg = trash_msg, snapshot = snapshot, try_hooks = try_hooks,
    set_state = function(st) S = st end,
    queue = Q, harvest = HV, move = MV, on_replacing = on_replacing, on_spawn_build = on_spawn_build,
    fols_msg = fols_msg, nests = RI, events = EV, infest_msg = infest_msg, client_only_pass = PF.client_only_pass,
    power = PW, rdoor_check = rdoor_check, retry_pending = retry_pending, locks = LK, infxp = IX,
    on_infest_destroyed = on_infest_destroyed, infest_destroyed_msg = infest_destroyed_msg,
    camps = CB, on_refill = on_refill, noise_msg = noise_msg, mines = MN, prefabs = PF,
}

return M
