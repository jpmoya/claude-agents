# Issue #83 — every stage is dispatched detached (nohup + poll); no foreground/wait dispatch, no timeout-600 promise.
ROOT_DD=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ORCH_DD="$ROOT_DD/agents/orchestrator.md"

test_dd_no_foreground_dispatch() {
  if grep -qiE 'Short stages.*foreground|\(foreground\)|both foreground|can run foreground' "$ORCH_DD"; then fail "foreground dispatch text remains"; return 1; fi
  assert_eq 0 0 "no foreground"
}
test_dd_no_wait_or_timeout600() {
  if grep -qE 'timeout 600|`wait`|background both in one shell' "$ORCH_DD"; then fail "wait/timeout 600 remains"; return 1; fi
  assert_eq 0 0 "no wait/timeout"
}
test_dd_reviewers_detached_both_pids() {
  grep -qF 'PID_CODE=$!' "$ORCH_DD" && grep -qF 'PID_TEST=$!' "$ORCH_DD" || { fail "both reviewer PIDs not recorded"; return 1; }
  grep -qF 'kill -0 "$PID_CODE"' "$ORCH_DD" && grep -qF 'kill -0 "$PID_TEST"' "$ORCH_DD" || { fail "poll must check both PIDs"; return 1; }
  assert_eq 0 0 "reviewers detached"
}
run_test test_dd_no_foreground_dispatch
run_test test_dd_no_wait_or_timeout600
run_test test_dd_reviewers_detached_both_pids
