# #473: ci-classify.sh — infrastructure-class vs real CI failures, from a failed-step log.
# Pure function of stdin + check name; no network.

CC_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../ci-classify.sh"

cc_expect() {  # cc_expect <name> <log> <expected out> <expected rc>
  local out rc
  out=$(printf '%s\n' "$2" | bash "$CC_BIN" "$1"); rc=$?
  assert_eq "$out" "$3" "class of [$1]" || return 1
  assert_eq "$rc" "$4" "exit of [$1]" || return 1
}

test_cc_container_start() {
  cc_expect unit-tests $'##[group]Initialize containers\n##[error]Docker create failed: Error response from daemon: Conflict' infra:container_start 0
}
test_cc_oom_137() {
  cc_expect Vitest $'> next build\nProcess completed with exit code 137.' infra:oom 0
}
test_cc_oom_killed_word() {
  cc_expect Quality $'> npm run build\nKilled\n##[error]Process completed' infra:oom 0
}
test_cc_enospc() {
  cc_expect unit-tests $'npm ERR! ENOSPC: no space left\nwrite /tmp/x: No space left on device' infra:enospc 0
}
test_cc_runner_lost() {
  cc_expect unit-tests $'The runner has received a shutdown signal. This can happen when the runner service is stopped' infra:runner_lost 0
}
test_cc_pr_format_by_log() {
  cc_expect pr-description $'PR body is missing the "User-facing change" line' infra:pr_format 0
}
test_cc_pr_format_by_name() {
  cc_expect 'User-facing change' $'format error' infra:pr_format 0
}
test_cc_assertion_is_real() {
  cc_expect unit-tests $'AssertionError: expected 3 to equal 4\n  at foo.test.ts:10' real 1
}
test_cc_tsc_is_real() {
  cc_expect Quality $'src/a.ts(3,5): error TS2322: Type string is not assignable to number' real 1
}
test_cc_lint_is_real() {
  cc_expect Quality $'/src/a.ts\n  3:1  error  no-unused-vars\n✖ 2 problems (2 errors, 0 warnings)' real 1
}
test_cc_vitest_failure_is_real() {
  cc_expect Vitest $' FAIL  src/a.test.ts > adds\nTests  1 failed | 10 passed' real 1
}
test_cc_real_beats_infra() {
  cc_expect unit-tests $'AssertionError: expected 1 to be 2\nProcess completed with exit code 137.' real 1
}
test_cc_empty_log_is_real() {
  cc_expect unit-tests '' real 1
}
test_cc_unknown_is_real() {
  cc_expect unit-tests $'something odd happened' real 1
}

echo "-- ci-classify (issue #473)"
run_test test_cc_container_start
run_test test_cc_oom_137
run_test test_cc_oom_killed_word
run_test test_cc_enospc
run_test test_cc_runner_lost
run_test test_cc_pr_format_by_log
run_test test_cc_pr_format_by_name
run_test test_cc_assertion_is_real
run_test test_cc_tsc_is_real
run_test test_cc_lint_is_real
run_test test_cc_vitest_failure_is_real
run_test test_cc_real_beats_infra
run_test test_cc_empty_log_is_real
run_test test_cc_unknown_is_real
