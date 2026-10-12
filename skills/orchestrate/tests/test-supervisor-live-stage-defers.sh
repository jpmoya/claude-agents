# Regression for claude-agents#178 — the orchestrator exits (exit 0) at a stage's 30-min cap while the stage
# is still running; the supervisor counted that as "no progress" and held the ticket at 3.
#
#   1  dead orchestrator + live --agent stage with PIPELINE_ISSUE=42, marker unchanged for 3 ticks:
#      no [queue-restart], no [escalate], no .held, .restarts untouched, deferral logged
#   2  the live stage belongs to another issue -> counted and restarted as today
#   3  no live stage at all -> counted as today
#   4  stage gone -> the next tick logs exactly one [queue-restart]
#   5  the process table cannot be read -> falls through to today's counting
#   6  cap-exit relaunch preamble does not claim the previous run "exited without reaching a terminal state"
#
# RS_PS_CMD (run-state.sh) stands in for the process table. Reuses the sq_* helpers of
# test-supervisor-queued-not-counted.sh (same loading trick as test-supervisor-fast-death-escalates.sh).

HERE_LS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "ls_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_LS/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f ls_real_run_test | sed '1s/ls_real_run_test/run_test/')"
fi

LS_STAGE_42="printf '1000\t42\tclaude --agent test-writer -p\n'"
LS_STAGE_77="printf '1000\t77\tclaude --agent test-writer -p\n'"

ls_fixture() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$SQ_READY"
}
ls_tick() { sq_run env RS_PS_CMD="$1" "$SUP_SQ" >/dev/null 2>&1; }
ls_restart_lines() { sq_log | grep -cF "[queue-restart] #42"; }

test_ls_1_live_stage_defers_three_ticks() {
  ls_fixture
  sq_seed_restarts 1 1 "$SQ_READY"
  cp "$SQ_PIPE/orch-42.restarts" "$SQ_PIPE/restarts.before"
  ls_tick "$LS_STAGE_42"; ls_tick "$LS_STAGE_42"; ls_tick "$LS_STAGE_42"
  local same=no held log q
  cmp -s "$SQ_PIPE/orch-42.restarts" "$SQ_PIPE/restarts.before" && same=yes
  held=$(sq_present "$SQ_PIPE/orch-42.held"); log=$(sq_log); q=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  sq_cleanup
  assert_eq "$same" "yes" "#178/1: .restarts untouched" || return 1
  assert_eq "$held" "absent" "#178/1: not held" || return 1
  assert_eq "$q" "absent" "#178/1: nothing queued" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "#178/1: no restart" || return 1
  assert_not_contains "$log" "[escalate] #42" "#178/1: no escalation" || return 1
  assert_contains "$log" "[stage-wait] #42" "#178/1: deferral logged" || return 1
}

test_ls_2_other_issue_stage_does_not_defer() {
  ls_fixture
  ls_tick "$LS_STAGE_77"
  local n; n=$(ls_restart_lines)
  sq_cleanup
  assert_eq "$n" "1" "#178/2: counted and restarted" || return 1
}

test_ls_3_no_live_stage_counts() {
  ls_fixture
  ls_tick "true"
  local n; n=$(ls_restart_lines)
  sq_cleanup
  assert_eq "$n" "1" "#178/3: counted and restarted" || return 1
}

test_ls_4_release_after_stage_exits() {
  ls_fixture
  ls_tick "$LS_STAGE_42"; ls_tick "$LS_STAGE_42"
  local before after
  before=$(ls_restart_lines)
  ls_tick "true"
  after=$(ls_restart_lines)
  sq_cleanup
  assert_eq "$before" "0" "#178/4: nothing while the stage lives" || return 1
  assert_eq "$after" "1" "#178/4: exactly one restart after the stage exits" || return 1
}

test_ls_5_unreadable_process_table_falls_through() {
  ls_fixture
  ls_tick "exit 1"
  local n; n=$(ls_restart_lines)
  sq_cleanup
  assert_eq "$n" "1" "#178/5: fail-safe counts the exit" || return 1
}

# ls_launch_prompt <exit-code> <exit-class> -> the prompt a due auto-restart passes to claude
ls_launch_prompt() {
  sq_env open
  sq_free_slots
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/prompt.out"\n' "$SQ_PIPE" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_seed_restarts 1 1 "$SQ_READY"
  echo "$1" > "$SQ_PIPE/orch-42.exit"
  echo "$2 -" > "$SQ_PIPE/orch-42.exit-class"
  [ "${3:-}" = cap ] && touch "$SQ_PIPE/orch-42.cap-exit"
  python3 -c "
import json, sys
json.dump({'issue': '42', 'repo': sys.argv[1], 'extra': '', 'reason': 'auto-restart',
           'queued_at': '2026-01-01T00:00:00Z', 'not_before': 0}, open(sys.argv[2], 'w'))
" "$SQ_REPO" "$SQ_PIPE/queue/orch-42.json"
  sq_marker "$SQ_READY"
  sq_tick
  local i; for i in $(seq 1 30); do [ -s "$SQ_PIPE/prompt.out" ] && break; sleep 0.1; done
  cat "$SQ_PIPE/prompt.out" 2>/dev/null
}

test_ls_6_preamble_not_a_fault_on_cap_exit() {
  local p; p=$(ls_launch_prompt 0 normal cap)
  sq_cleanup
  assert_contains "$p" "AUTO-RESTART #1" "#178/6: relaunched with a preamble" || return 1
  assert_not_contains "$p" "exited without reaching a terminal state" "#178/6: cap exit not described as a fault" || return 1
  assert_contains "$p" "stage's time cap" "#178/6: cap wording present" || return 1
}

test_ls_7_preamble_keeps_fault_wording_on_abnormal_exit() {
  local p; p=$(ls_launch_prompt 1 error)
  sq_cleanup
  assert_contains "$p" "exited without reaching a terminal state" "#178/7: abnormal exit keeps the wording" || return 1
}

test_ls_8_silent_exit0_keeps_fault_wording() {
  local p; p=$(ls_launch_prompt 0 normal)
  sq_cleanup
  assert_contains "$p" "exited without reaching a terminal state" "#178/8: silent exit 0 (no cap signal) keeps the fault wording" || return 1
}

run_test test_ls_1_live_stage_defers_three_ticks
run_test test_ls_2_other_issue_stage_does_not_defer
run_test test_ls_3_no_live_stage_counts
run_test test_ls_4_release_after_stage_exits
run_test test_ls_5_unreadable_process_table_falls_through
run_test test_ls_6_preamble_not_a_fault_on_cap_exit
run_test test_ls_7_preamble_keeps_fault_wording_on_abnormal_exit
run_test test_ls_8_silent_exit0_keeps_fault_wording
