# Issue #267 — a failing test is never `needs_jp`; TEST DEFECT is valid with a PR open.

HERE_267=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEV_267="$HERE_267/../../../agents/fullstack-developer.md"

test_267_test_defect_not_limited_to_before_pr() {
  local line
  line=$(grep -F '**[fullstack-developer] TEST DEFECT**' "$DEV_267" | grep -F -- '— the locked test')
  assert_ne "$line" "" "267: TEST DEFECT marker definition must exist" || return 1
  case "$line" in *"No PR yet"*) fail_267=1;; *) fail_267=0;; esac
  assert_eq "$fail_267" "0" "267: TEST DEFECT definition must not say 'No PR yet'" || return 1
  case "$line" in *"fix cycle"*) ;; *) assert_eq "x" "fix cycle" "267: TEST DEFECT must be stated valid in fix cycles" || return 1;; esac
}

test_267_failing_test_never_needs_jp() {
  local hit
  hit=$(grep -c 'failing test is never `needs_jp`' "$DEV_267")
  assert_ne "$hit" "0" "267: BLOCKED needs a sub-bullet saying a failing test is never needs_jp" || return 1
  hit=$(grep -c 'PIPELINE_LOCKED_TESTS_FILE' "$DEV_267")
  assert_ne "$hit" "0" "267: sub-bullet must point at the lock file" || return 1
}

run_test test_267_test_defect_not_limited_to_before_pr
run_test test_267_failing_test_never_needs_jp
