# claude-agents#306 — a run that step 1b re-queued (auto-retry) is not re-held by step 1's gate branch while its
# queue entry exists; without a queue entry the gate behaves as before. Prefixed i306_.
HERE_I306=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "i306_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I306/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f i306_real_run_test | sed '1s/i306_real_run_test/run_test/')"
fi

i306_fixture() {  # dead run (no .held), latest marker a BLOCKED gate
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 7200 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"; sq_iso_ago 7200 > "$(rkp "$SQ_PIPE/orch-42.start")"
  sq_marker "$SQ_BLOCKED"
}

test_i306_queued_run_not_reheld_and_entry_kept() {
  i306_fixture
  sq_seed_auto_restart_queue
  sq_tick
  local held q log
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); q=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")"); log=$(sq_log)
  sq_cleanup
  assert_eq "$held" "absent" "#306: queued run is not re-held" || return 1
  assert_eq "$q" "present" "#306: queue entry survives the gate branch" || return 1
  assert_contains "$log" "[queue-wait] #42" "#306: gate skip is logged" || return 1
  assert_not_contains "$log" "[held] #42" "#306: no [held] line while queued" || return 1
}

test_i306_unqueued_run_still_held_with_alert() {
  i306_fixture
  sq_tick
  local held alert
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  sq_cleanup
  assert_eq "$held" "present" "#306: no queue entry -> held as before" || return 1
  assert_contains "$alert" "Pipeline #42" "#306: alert written" || return 1
}

run_test test_i306_queued_run_not_reheld_and_entry_kept
run_test test_i306_unqueued_run_still_held_with_alert
