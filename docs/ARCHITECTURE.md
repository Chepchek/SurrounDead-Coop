# SDCoop — code map

A guide to where things are and what each file does, for anyone (human or tool) reading or changing the code.
Every module starts with a header comment that explains the game mechanics it relies on; read it before you edit the module.

## The idea in one paragraph

SurrounDead is a single-player Unreal Engine 5.6 game, but its Blueprints already contain listen-server RPCs (`Svr_*`, `MC_*`, `Client_*`), so movement, shooting and most of the inventory replicate by themselves once the world is opened with `?listen`.
SDCoop is a UE4SS 3.0.1 Lua mod that turns the host's world into a listen server and then fixes everything the game does not replicate, or does only for "player 0".
The host is authoritative: the client asks, the host runs the game's own function for the right player, and the result replicates (or is sent through the mod's message channel).
The mod never ships game assets and never edits `.pak` files; it only calls the game's own functions.

## Repository layout

| Path | What it is |
|---|---|
| `mods/SDCoop/scripts/` | The mod. `main.lua` plus flat `sdc_*.lua` modules (UE4SS's module searcher does not map dots to folders). Copied as-is into `SurrounDead/Binaries/Win64/ue4ss/Mods/SDCoop/scripts/`. |
| `mods/SDCoop/enabled.txt` | Empty file; makes UE4SS load the mod without editing `mods.txt`. |
| `docs/CONFIG.md` | Every setting (`config.ini` key, type, default, description), generated from `SCHEMA` in `sdc_config.lua` by `tools/gen_config_doc.py`. |
| `tests/` | Offline tests: each one loads real modules against fake UE objects and checks behaviour. Run all with `tools/run_tests.sh`. |
| `tools/steamlink/` | `SDCoopSteamLink.exe`, the Steam join helper (C#, .NET Framework 4, built with the system `csc.exe` by `build.ps1`). It loads the game's own `steam_api64.dll` and tunnels the game's UDP port over Steam P2P (friends only), sets rich presence for "Join Game", lists friends. Shipped in release archives at `Mods/SDCoop/steamlink/`. |
| `tools/package.ps1` | Builds `dist/SDCoop_<version>.zip` (UE4SS taken from the local game install + this mod + the Steam helper + a Russian README). |
| `tools/deploy.ps1` | Copies the scripts into a game install (and an optional second test install). |
| `tools/run_tests.sh` | `luac -p` on every file, a global-variable scan, then every test. Needs a Lua 5.4 `lua.exe`/`luac.exe` in `tools/lua54/`. |
| `tools/globalscan.py` | Finds accidental global reads/writes (typos, forward-declared locals) with `luac -l`. |
| `tools/dmpscan.py` | Reads a crash minidump (`ue4ss/crash_*.dmp`) without a debugger: faulting module + offset, stack scan. |

## Runtime structure

- **Entry point:** `main.lua` requires every module, calls each `install`, and schedules the ticks with `sdc_ue.every(name, ms, fn)` / `every_frame` (all on the game thread). The tick list at the end of `main.lua` is the place to see what runs how often.
- **Roles:** `sdc_session` decides `standalone` / `host` / `client` and keeps `session.state` (`S`): role, remote players (`S.remote`, `S.remote_pcs`), menu state. Most modules receive `S` in `install(S)`.
- **Messages:** `sdc_net` is the host↔client channel (`SDC1|KIND|field|…`) riding on two stock engine RPCs (`ClientMessage` down, `ServerExecRPC` up). Modules register handlers with `net.on("KIND", fn)`; send with `net.send_to(pc, …)`, `net.broadcast(pcs, …)`, `net.send_to_host(…)`.
- **Player 0:** the game's Blueprints ask `GetPlayerController(0)` everywhere. On the host `sdc_ctx` rewrites the index by context (who is acting) through pre-hooks; other modules add "scope resolvers" to it (vehicles, world, respawn).
- **Hooks:** Blueprint function hooks (`RegisterHook`, one callback after the function) and native hooks (pre/post, shared through `sdc_ue.hook_native`). Every callback is wrapped in `pcall`, returns nothing, and never keeps engine object wrappers between calls.
- **Config:** `sdc_config` reads/writes `Mods/SDCoop/config.ini`; every feature has a switch in `SCHEMA` (see `docs/CONFIG.md`).
- **Logging:** `sdc_log` writes English lines to `UE4SS.log` (batched to at most one write per second when a write was slow), and Russian on-screen toasts. Diagnostics: `[SNAP]` state snapshots (`sdc_diag`), `[PERF]` cost per hook/task (`sdc_perf`), `[SLOW]` / `[HITCH]` / `[SLOWLOG]` warnings.

## Modules

### Core
| File | What it does |
|---|---|
| `main.lua` | Entry point: version, requires, installs, tick schedule, console commands (`sdcoop_*`). |
| `sdc_ue.lua` | Safe wrappers around the UE4SS object API (validity, properties, calls, game-thread scheduling, timed `load_asset`, `hook_native`, task timing, a shared player-character list refreshed on new-object notifications). Every engine access goes through it. |
| `sdc_log.lua` | Log lines, debug/probe switches, batched log writing, toasts. |
| `sdc_config.lua` | `config.ini` and the settings `SCHEMA` (key, type, default, Russian description). |
| `sdc_net.lua` | Host↔client message channel, handler registry, message statistics. |
| `sdc_ctx.lua` | "Player 0" by context on the host; scope resolvers chained by other modules. |
| `sdc_session.lua` | Host / join / roles / handshake, per-role ticks, save backups before hosting. |
| `sdc_steam.lua` | Steam identity (SteamID via SteamCore), `Engine.ini` `bUseSteamNetworking=False` (plain UDP sockets under Steam), the launch join code. |
| `sdc_steamlink.lua` | Steam join: starts and drives `SDCoopSteamLink.exe` through files in its folder (UE4SS Lua has no sockets). The game itself stays on the plain IP net driver: a joining client opens `127.0.0.1:<tunnel port>`. Interface for the panel: `status()`, `friends()`, `join(id)`, `invite()`. |
| `sdc_netdiag.lua` | Network diagnostics when the world does not open for friends. |
| `sdc_perf.lua` | Per-hook/per-task cost report (`[PERF]`, with an `ctx:` section for the player-0 hooks), hook counts by kind, Lua collector settings. |
| `sdc_bench.lua` | `sdcoop_bench`: single-player A/B fps / frame-time windows and per-call hook costs (`[BENCH]`), to decide whether a custom UE4SS build is worth it. |
| `sdc_diag.lua` | `[SNAP]` state snapshots and `[HITCH]` detection. |
| `sdc_gaptrace.lua`, `sdc_movedbg.lua` | Debug-only tracers (player-0 calls; client movement back-steps). Off unless enabled. |

### UI
| File | What it does |
|---|---|
| `sdc_lobby.lua` | The co-op lobby built into the game's own main menu (host / join / character). |
| `sdc_widgets.lua` | Helpers that clone the game's own widgets so new buttons look native. |
| `sdc_ui.lua` | The co-op panel (main menu button and F7): tabs Steam / By IP / Character / Settings, the players list in the header, collapsible sections, settings built from `SCHEMA`, «Report a bug»; the mod's own toasts in the panel's style. |
| `sdc_i18n.lua` | On-screen language (RU/EN): panel strings, English setting descriptions, translation of other modules' toasts. Log text stays English. |
| `sdc_charcreate.lua` | A client's co-op character made in the game's own character creator before joining. |

### Players
| File | What it does |
|---|---|
| `sdc_players.lua` | Spawn, death, respawn, HUD and death screen of every player, the game's way. |
| `sdc_respawn.lua` | Runs the game's per-player server flows (point respawn, bed) for the right player; co-op sleep (the night passes only when every player sleeps). |
| `sdc_notes.lua` | Every game notification on the screen of the player it is for: the host relays notices the game raises for a client (`NOTE`) and takes notices about another player's action off the wrong screen. |
| `sdc_playernotes.lua` | Player events for the other players in the game's notification style: "X died" (with the cause when the killing hit shows it) and "X respawned" (`PEV`); installed and ticked by `sdc_respawn`. Setting `player_event_notes`. |
| `sdc_uiinput.lua` | A client's game windows (inventory, trade, loot) keep the game's UI input (cursor, no camera turning); container-open requests logged. |
| `sdc_sweepguard.lua` | Stops the game's "remove every player character" sweeps from deleting other players. |
| `sdc_localinit.lua` | Re-runs the game's local-player setup on a client that missed it. |
| `sdc_appearance.lua` | Owner-published looks (body, hair, clothes). |
| `sdc_pawnstate.lua` | Owner-published local state (weapon held, sprint, lean, flashlight, aim pose); per-frame left-hand IK and head of the other players. |
| `sdc_playermarks.lua` | Other players' names and GPS markers through the game's own UI. |
| `sdc_progress.lua` | Level / XP / passive skills / journal stats of clients. |
| `sdc_skilltree.lua` | The skill tree (TechTree plugin) per player. |
| `sdc_persist.lua` | Clients' characters (inventory, progression, health, position, map discoveries) saved by the host next to its world slot and restored on rejoin. Live records during a session; every game save commits them (generations, atomic), a load of the slot (also mid-session) brings them back to the commit (`persist_follow_host_save`). Shared map discoveries (`MAPSHARE`). |
| `sdc_savecheck.lua` | Host save checks and guards: who is saved, slot repair, co-op autosave, backup pruning. |
| `sdc_stealth.lua` | A client's own sneaking noise and the zombies' perception of it. |
| `sdc_geiger.lua` | Every player hears only their own dosimeter; radiation stops on leaving a zone. |
| `sdc_whistle.lua` | Other players' distraction whistle. |
| `sdc_ownsounds.lua` | Sounds the game plays only on the owner's machine, relayed to others. |

### Combat
| File | What it does |
|---|---|
| `sdc_damage.lua` | Damage of remote players' weapons computed on the host with the shooter's stats. |
| `sdc_dmgnum.lua` | Floating damage numbers for a client's own hits. |
| `sdc_combat.lua` | Weapon montages (bolt/pump cycling, reloads) of other players; reload loop fix. |
| `sdc_throw.lua` | Grenades, pipe bombs, Molotovs, bottles: a client's throw runs on the host, everyone sees it. |
| `sdc_shake.lua` | Explosion camera shake for every player inside the blast zone, nobody else. |
| `sdc_turrets.lua` | Camp and player-built turrets (their logic runs on the host only): the host's shots, aim, switching off and health reach clients in batches (`TURFIRE` / `TURSTATE`), a client's switch-off and hits reach the host (`TUROFF` / `TURHIT`); turrets near a remote player are woken from the AI optimizer. Setting `turret_sync`. |
| `sdc_gearfx.lua` | Other players' weapon lights and lasers; on a client, re-runs the game's `ProcessAttachments` for a weapon that arrived already fitted (sight / suppressor / muzzle brake). |

### Zombies and NPCs
| File | What it does |
|---|---|
| `sdc_ai.lua` | Core of the zombie features (switches, shared helpers). |
| `sdc_ai_zombie.lua` | Read-only helpers describing a zombie (type, archetype, mesh). |
| `sdc_ai_looks.lua` | A client's copy of a zombie looks like the host's (mesh, material, crawler height, effects). |
| `sdc_ai_attacks.lua` | Attack / flinch / scream montages of zombies, bosses and animals on clients. |
| `sdc_ai_corpses.lua` | Corpses stay on clients, fallen and lootable/harvestable. |
| `sdc_ai_fx.lua` | One-shot archetype effects (grenadier beep and blast, acid burst). |
| `sdc_ai_ghosts.lua` | Removes AI that exist only on a client. |
| `sdc_ai_hud.lua` | The enemy health bar on clients, with the host's values. |
| `sdc_ai_kills.lua` | A kill by a client counts for that client (counter, XP, popup). |
| `sdc_ai_killlog.lua` | One log line per AI death, with type and killer (diagnostics). |
| `sdc_ai_offscreen.lua` | Zombies keep animating/attacking for clients when the host does not look at them. |
| `sdc_npc.lua` | Zombie bosses and human NPCs: unseen attacks, roars, fire, health bar, looks. |
| `sdc_dialogue.lua` | NPC dialogues and trading for every player (the host starts a client's dialogue; trader money sync). |
| `sdc_quests.lua` | Quests in co-op: each player has their own quests, run on the host on that player's Narrative component (bounties, quest areas, the starting quest, markers, XP, save/load); laptop bounties are shared (`QG`: the others see the buyer's bounty, its marker and get its XP); `quest_own` off = the old shared host log. |

### Items
| File | What it does |
|---|---|
| `sdc_items.lua` | Item actors: worn items on clients, drops, hotbar; drives the item sub-modules below. |
| `sdc_wear.lua` | A client's gun and muzzle-attachment wear: the game's own wear call finds nothing in a client's (empty) inventory, so the client sums it per item and the host runs `ServerFuncUpdateDurabilityByUID` on its copy (`GWEAR`); the client shows the host's value minus the wear in flight. |
| `sdc_consume.lua` | Crafting, medical items, food/water, items a use gives back, ghost-use protection. |
| `sdc_containers.lua` | Moves/splits in chests, bodies, stations and trunks reach the client reliably (no "blinking"). |
| `sdc_stations.lua` | Workbenches whose single-player code needs the host (disassembly — results into the "Disassembled" output grid —, cooking, camp). |
| `sdc_deathbox.lua` | A dead player's loot box (run by `sdc_containers`): the host removes it once nothing visible is left in it (`DBOXGONE` takes its death marker off clients). |
| `sdc_tools.lua` | Worn tools whose checks read the host's data (binoculars, night vision). |
| `sdc_hudmods.lua` | The HUD gear icons for clients (run by `sdc_geiger`): respirator filter from the host's radiation timer (`RESPUI`), flashlight / night vision icons restored when the game's own call was lost. |

### World
| File | What it does |
|---|---|
| `sdc_world.lua` | Searched containers and refills (placed boxes by level path, camp / POI boxes by class and place), doors, trees/rocks/scrap harvesting, buildings and moved furniture, trash, barrels, infestations, camps/settlements from the host, horde bosses. Its own send queue keeps bursts from flooding a client.; landmine explosions (`WMINE`: the host's explosion shown on clients with the game's own effects, a client's shot sets off the host's mine). |
| `sdc_sync.lua` | Time and weather, pause, AI replication rate, sound relays, movement fixes. |
| `sdc_events.lua` | The game's random world events (crashed helicopters, abandoned trucks): their sound, notice, map marker and wreck from the host on every client (`WEVT`). |
| `sdc_rename.lua` | Renaming storage buildables: the game's rename window on the client's screen, the name set by the host with the game's own function and sent to everyone (`RNOPEN` / `RNREQ` / `RNAME` / `RNAMEQ`). |
| `sdc_builduse.lua` | Ends a client's use of a buildable on the host the way the game does (`BREL`), so the host's own look at a door / gate a client used last shows its prompt again. |
| `sdc_bdoors.lua` | Buildable doors / gates / garage doors the same on every machine: swing side of the opener, open/closed state from the host (`WBDOOR` / `WBDOORQ`), the garage door's power from the host (the client's generator timers stopped). |
| `sdc_poimarks.lua` | The host's place markers stay on the host's own map (a client's respawn made the game rebuild them on the client's hidden map on the host); places seen only by another player are dimmed until visited. |
| `sdc_poiclear.lua` | Major places' objectives (boss defeated, special container looted) for every player: a client's crate counts with its XP, state from the host (`POICL` / `POIST` / `POIQ`). |
| `sdc_vehicles.lua` | Vehicles, host-authoritative: seats (driver/passenger), poses, exits, fuel/repair, lights/horn/colour, vehicle trader purchases. |
| `sdc_vehradio.lua` | The vehicle radio (part of the vehicle sync, run by `sdc_vehicles`): a seated player's radio (on, track, pause, volume, speed) on every machine's copy of the vehicle with the game's own radio functions (`VRADIO` / `VRADIOQ`); the music is each player's own `Radio` folder. |

## Conventions (read before changing code)

- Engine objects are touched only on the game thread (`sdc_ue.delay` / `every`); never in `LoopAsync`.
- No Lua work in a `RegisterKeyBind` callback. UE4SS runs it on its own thread while native hooks on the game thread take no lock, so Lua runs on two threads at once. A bind only flips an existing flag that the frame loop acts on (`main.lua`, F7). Better still, read the key on the game thread with `PlayerController:IsInputKeyDown` (`sdc_vehicles`, Tab). An `ExecuteInGameThread` from a Tab bind was the 0.7.1 host crashes.
- Reading a property the object does not have returns a UE4SS `TrivialObject`, not `nil`, so `ue.prop(o, X) ~= nil` is always true. Check with `ue.has_prop` / `ue.missing`; `ue.str` gives `""` for it. Mocks must return such an object too (`tests/mock_quests_bounty_shared.lua`). In 0.7.1 this broke quest names and shared laptop bounties.
- An actor destroyed with `K2_DestroyActor` stays valid until the garbage collector, and its location reads (0, 0, 0). Remember what you destroyed and treat (0, 0, 0) as "no place" (`sdc_deathbox`).
- No synchronous `LoadAsset` in hot paths on clients (it froze clients); use assets already in memory.
- Lua's 200-locals limit per function/chunk is real here; big modules group locals in tables.
- Never send one network message per world object; batch and queue (see `sdc_world` and `sdc_containers`).
- UE4SS gives some strings wrapped (out parameters, array elements): read them with `ue.fstring`, never `tostring`.
- New behaviour gets a config switch in `SCHEMA` (Russian description), log lines on both machines, and a test in `tests/`.
- Log text is English; on-screen text is Russian.

## Testing

`bash tools/run_tests.sh [scripts_dir]` runs syntax checks, the global scan and every test in `tests/` (mocks of the engine objects; no game needed).
Each test file names the module and behaviour it covers in its header. The game itself is the final test: both players' `UE4SS.log` files are the source of truth, and the `[SNAP] head v=` line shows which version actually ran.
