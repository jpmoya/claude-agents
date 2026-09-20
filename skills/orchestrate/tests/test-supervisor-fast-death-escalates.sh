# Regression for claude-agents#38 — a run that keeps dying in seconds was "transient" and never
# escalated (only transient_count >= 20 could), and the [queue-restart] line printed a stale exit
# status read from orch-<N>.exit left by an earlier run.
#
#   AC1 (1a-1d)  one escalation ceiling: every non-terminal exit advances total; total >= 6 escalates
#   AC2 (2a-2c)  a killed run never reports a stale exit status (.exit removed at launch)
#
# Reuses the sq_* helpers of test-supervisor-queued-not-counted.sh. run-tests.sh sources test files
# alphabetically, so that file is not loaded yet when this one is: source it here with run_test
# neutralised (its cases must run once, from the runner, not twice). Issue 42 / placeholder repos only.

HERE_FD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "fd_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_FD/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f fd_real_run_test | sed '1s/fd_real_run_test/run_test/')"
fi
ORCH_FD="$HERE_FD/../orchestrate.sh"

# fd_fast_tick — reset .launched-at to now (this "run" lived 0s), drop the queue entry, tick.
fd_fast_tick() {
  sq_iso_ago 0 > "$SQ_PIPE/orch-42.launched-at"
  rm -f "$SQ_PIPE/queue/orch-42.json"
  sq_tick
}

fd_fast_fixture() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_marker "$SQ_READY"
}

# hand arithmetic: MAX_TOTAL=6 -> ticks 1..5 must not escalate, tick 6 must.
test_fd_1a_sixth_fast_exit_escalates_fifth_does_not() {
  fd_fast_fixture
  local i held5 held6 total5 log calls
  for i in 1 2 3 4 5; do fd_fast_tick; done
  held5=$(sq_present "$SQ_PIPE/orch-42.held"); total5=$(sq_restarts_field total)
  fd_fast_tick
  held6=$(sq_present "$SQ_PIPE/orch-42.held"); log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$total5" "5" "#38/1a: total=5 after five fast exits" || return 1
  assert_eq "$held5" "absent" "#38/1a: not held after five fast exits" || return 1
  assert_eq "$held6" "present" "#38/1a: held after the sixth fast exit" || return 1
  assert_contains "$log" "[escalate] #42" "#38/1a: escalation logged" || return 1
  assert_contains "$calls" "issue comment 42" "#38/1a: supervisor NOTE posted on the issue" || return 1
}

# hand arithmetic: total 1,2,3 -> TRANSIENT_BACKOFF idx 0,1,2 = 300,600,1200; count stays 0.
test_fd_1b_three_fast_exits_count_total_and_backoff() {
  fd_fast_fixture
  fd_fast_tick; fd_fast_tick; fd_fast_tick
  local total count log lines held
  total=$(sq_restarts_field total); count=$(sq_restarts_field count)
  held=$(sq_present "$SQ_PIPE/orch-42.held")
  log=$(sq_log)
  lines=$(printf '%s\n' "$log" | grep -F "[queue-restart] #42" | grep -o 'backoff=[0-9]*s' | tr '\n' ' ')
  sq_cleanup
  assert_eq "$total" "3" "#38/1b: total=3" || return 1
  assert_eq "$count" "0" "#38/1b: count=0 (transient exits do not count)" || return 1
  assert_eq "$held" "absent" "#38/1b: not escalated after three" || return 1
  assert_not_contains "$log" "[escalate] #42" "#38/1b: no escalation after three" || return 1
  assert_eq "$lines" "backoff=300s backoff=600s backoff=1200s " "#38/1b: backoff indexed by total-1" || return 1
  if printf '%s\n' "$log" | grep -Eq 'transient=[0-9]+/'; then
    fail "#38/1b: [queue-restart] still prints a transient=N/MAX counter"; return 1
  fi
}

test_fd_1c_non_transient_run_still_escalates_at_no_progress_cap() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$SQ_READY"
  sq_seed_restarts 2 2 "$SQ_READY"   # count 2 -> this exit makes 3 = MAX_NO_PROGRESS
  sq_tick
  local held log
  held=$(sq_present "$SQ_PIPE/orch-42.held"); log=$(sq_log)
  sq_cleanup
  assert_eq "$held" "present" "#38/1c: held on the third no-progress non-transient exit" || return 1
  assert_contains "$log" "[escalate] #42" "#38/1c: escalation logged" || return 1
}

test_fd_1d_transient_ceiling_removed_from_source() {
  local hits
  hits=$(cd "$HERE_FD/.." && grep -n 'MAX_TRANSIENT_TOTAL\|transient_count' supervisor.sh config.sh orchestrate.sh)
  assert_eq "$hits" "" "#38/1d: no MAX_TRANSIENT_TOTAL / transient_count left" || return 1
  assert_contains "$(cat "$HERE_FD/../config.sh")" "TRANSIENT_BACKOFF=" "#38/1d: TRANSIENT_BACKOFF table kept" || return 1
}

# fd_wait_dead <pid> — poll up to 5s
fd_wait_dead() {
  local i
  for i in $(seq 1 50); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

# fd_launch_then_die <claude-stub-body> — stale .exit=0, queued run, free slots, stub claude; tick launches,
# wait for death, tick again (the tick under test). Leaves the env open for the caller.
fd_launch_then_die() {
  sq_env open
  sq_free_slots
  printf '#!/bin/bash\n%s\n' "$1" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"
  sq_marker "$SQ_READY"
  echo 0 > "$SQ_PIPE/orch-42.exit"
  mk_queued "$SQ_PIPE" 42 "$SQ_REPO"
  sq_tick
  local pid; pid=$(cat "$SQ_PIPE/orch-42.pid" 2>/dev/null)
  [ -n "$pid" ] || return 1
  fd_wait_dead "$pid" || return 1
  sq_tick
}

test_fd_2a_killed_run_logs_unknown_exit_not_stale_zero() {
  fd_launch_then_die 'kill -9 $PPID' || { sq_cleanup; fail "#38/2a: fixture failed to launch/kill"; return 1; }
  local line last
  line=$(sq_log | grep -F "[queue-restart] #42")
  last=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['history'][-1]['exit'])" "$SQ_PIPE/orch-42.restarts" 2>/dev/null)
  sq_cleanup
  assert_contains "$line" "exit=?" "#38/2a: killed run logs exit=?" || return 1
  assert_not_contains "$line" "exit=0" "#38/2a: stale exit=0 not reported" || return 1
  assert_eq "$last" "?" "#38/2a: history exit is ?" || return 1
}

test_fd_2b_real_exit_status_is_reported() {
  fd_launch_then_die 'exit 3' || { sq_cleanup; fail "#38/2b: fixture failed to launch/exit"; return 1; }
  local line; line=$(sq_log | grep -F "[queue-restart] #42")
  sq_cleanup
  assert_contains "$line" "exit=3" "#38/2b: real exit status 3 reported" || return 1
}

test_fd_2c_manual_relaunch_clears_stale_exit_file() {
  sq_env full
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  echo 0 > "$SQ_PIPE/orch-42.exit"
  local out rc
  out=$(sq_run "$ORCH_FD" "$SQ_REPO" 42 2>&1); rc=$?
  local exit_state; exit_state=$(sq_present "$SQ_PIPE/orch-42.exit")
  sq_cleanup
  assert_exit0 "$rc" "#38/2c: manual relaunch exits 0" || return 1
  assert_contains "$out" "queued #42" "#38/2c: relaunch queued (full capacity)" || return 1
  assert_eq "$exit_state" "absent" "#38/2c: stale orch-42.exit removed" || return 1
}

run_test test_fd_1a_sixth_fast_exit_escalates_fifth_does_not
run_test test_fd_1b_three_fast_exits_count_total_and_backoff
run_test test_fd_1c_non_transient_run_still_escalates_at_no_progress_cap
run_test test_fd_1d_transient_ceiling_removed_from_source
run_test test_fd_2a_killed_run_logs_unknown_exit_not_stale_zero
run_test test_fd_2b_real_exit_status_is_reported
run_test test_fd_2c_manual_relaunch_clears_stale_exit_file
