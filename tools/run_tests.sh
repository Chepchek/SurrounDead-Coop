#!/usr/bin/env bash
# Runs every SDCoop check against one scripts folder (default: the source).
#   bash tools/run_tests.sh [scripts_dir]
# Lua 5.4.7 build: tools/lua54 (lua.exe, luac.exe). Tests: tests/.
# Some mocks write into a scratch folder: tests/_tmp (recreated each run).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="${1:-$ROOT/mods/SDCoop/scripts}"
LUA="$ROOT/tools/lua54/lua.exe"
LUAC="$ROOT/tools/lua54/luac.exe"
T="$ROOT/tests"
TMP="$T/_tmp"
rm -rf "$TMP"; mkdir -p "$TMP/wstore" "$TMP/savecheck" "$TMP/persist" "$TMP/lad"
winpath() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
# No test may touch this PC's real game folder: a test that becomes host in
# the real sdc_session copies %LOCALAPPDATA%\SurrounDead\Saved\SaveGames into
# SDCoop_Backups (2026-11-13: test runs left copies there, which the mod's
# backup rotation would have kept instead of real ones).
export LOCALAPPDATA="$(winpath "$TMP/lad")"
fail=0
note() { printf '%-22s %s\n' "$1" "$2"; case "$2" in *ALL\ OK*|*all\ ok*|*", 0 failed"*|"OK"*|*" 0 failed"*|"exit 0") ;; *) fail=1 ;; esac; }

for f in "$SCRIPTS"/*.lua; do "$LUAC" -p "$f" || { echo "SYNTAX FAIL $f"; fail=1; }; done
python -I "$T/luacheck.py" "$SCRIPTS"/*.lua | grep -v ": ok$"
python -I "$ROOT/tools/globalscan.py" "$LUAC" "$SCRIPTS"/*.lua | tail -1

note persist   "$("$LUA" "$T/persist/mock_persist.lua" "$SCRIPTS" "$SCRIPTS" "$(winpath "$TMP/persist")" 2>&1 | tail -1)"
note wstore    "$("$LUA" "$T/save/mock_wstore.lua" "$SCRIPTS" "$TMP/wstore" 2>&1 | tail -1)"
note savecheck "$("$LUA" "$T/save/mock_savecheck.lua" "$SCRIPTS" "$(winpath "$TMP/savecheck")" 2>&1 | tail -1)"
note logbatch  "$("$LUA" "$T/gcwork/test_logbatch.lua" "$SCRIPTS" >/dev/null 2>&1; echo "exit $?")"
for g in test_netbudget test_aisweep test_mem test_outrefs; do
    [ -f "$T/gcwork/$g.lua" ] && note "$g" "$("$LUA" "$T/gcwork/$g.lua" "$SCRIPTS" >/dev/null 2>&1; echo "exit $?")"
done
note gapdiff   "$(python -I "$T/test_gapdiff.py" 2>&1 | tail -1)"
for m in mock_trade mock_quests mock_quests_bounty_shared mock_mapmarks mock_combat_gaps mock_sound_range mock_sound_range2 mock_vehicles mock_vehicles_hud mock_vehicles_hud_passenger mock_vehseats_table mock_vehicles_seats mock_vehicles_seats_compat mock_vehicles_driveronly mock_world mock_world_power mock_world_crates mock_world_locks mock_world_infxp mock_world_primary mock_world_notes mock_steamlink mock_npc mock_zombie_sync mock_throw mock_progress mock_skilltree \
         mock_respawn mock_spawnbutton mock_coopsleep mock_sweepguard mock_marks mock_stealth mock_all_on mock_gearfx_laser mock_notes_route mock_zones_entry mock_uiinput_client mock_ctx_fastpath mock_names_chip mock_ue_playerlist mock_pawnstate_perf mock_gearfx_refit mock_items_perf mock_playernotes mock_vehicles_hostexit mock_world_lootsync mock_steamlink_hostdeath mock_vehicles_passenger_inv mock_vehicles_radio mock_vehicles_boxes mock_vehicles_boxes_e2e mock_weapon_wear mock_world_lockpick_count mock_map_shared mock_poimarks mock_respawn_filter mock_gear_hud mock_turrets mock_persist_commit mock_world_landmine mock_world_events mock_events_camps mock_rename mock_deathbox mock_disasm_output mock_builduse mock_bdoors mock_poiclear mock_lobby_coop_top mock_reopen_world mock_admin mock_join_cover mock_host_menu \
                 mock_fix_a1_early_id mock_fix_a1_admin mock_fix_a1_session mock_fix_a1_savecheck mock_fix_a1_persist mock_fix_a2_ui mock_fix_a2_lobby mock_fix_a2_notes \
                 mock_fix_b_keypad mock_fix_b_snapshot mock_fix_b_lists mock_fix_c_vehicles mock_fix_c_turrets mock_fix_c_items mock_fix_d_resource mock_world_rockloot mock_fix_d_marker mock_fix_d_seqprune mock_fix_d_combat \
                 mock_fix_e_players mock_fix_f_npc mock_fix_f_misc mock_integration_preload mock_zombie_names mock_access mock_access_flow mock_access_ui mock_ai_coop_host mock_ai_coop_client mock_ffire mock_ffire_ui mock_nullobj mock_pull mock_pull_persist mock_pull_ui mock_join_password mock_join_password_ui mock_infection_hud mock_widgets_child mock_charcreate_settings mock_stability mock_stability_main mock_wave_session mock_wave_players mock_wave_client mock_ai_wave_host mock_ai_wave_client mock_npc_wave mock_ai2 mock_look_scope mock_chat mock_killlog_once mock_ai_vehkill mock_items_sf mock_perf_link mock_sf_misc_charjoin mock_knockdown mock_consume_lootbox mock_reloadcap mock_shower mock_shower_relay mock_bunker_doors; do
    [ -f "$T/$m.lua" ] && note "$m" "$("$LUA" "$T/$m.lua" "$SCRIPTS" 2>&1 | tail -1)"
done
cd "$T/loadtest"
for t in run logic logic2 logic3 logic4 logic5 logic6 logic7 logic8 logic9 logic10 logic11 logic13_reattach logic_dlgstub logic_msgkinds logic_ui_i18n logic_roster; do
    [ -f "$t.lua" ] && note "$t" "$("$LUA" "$t.lua" "$SCRIPTS" 2>&1 | tail -1)"
done
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
