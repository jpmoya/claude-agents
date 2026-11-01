# claude-agents#560 (fix cycle 1): the no-NOTE baseline is the gate marker; a later non-gate comment must not strand a decision.
HERE_LG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Reuse the locked file's helpers without re-registering its cases (it sorts before this file under run-tests.sh, so normally already sourced).
if ! declare -f lc_fixture >/dev/null 2>&1; then
  eval "lg_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_LG/test-loopcap-resume-comment-id.sh"
  eval "$(declare -f lg_real_run_test | sed '1s/lg_real_run_test/run_test/')"
fi

test_lg_later_non_gate_comment_keeps_decision_valid() {
  lc_fixture
  local gate dec note n
  gate=$(lc_c 100 '**[code-reviewer] FAIL: 2 findings**' 2026-11-01T10:00:00Z)
  dec=$(lc_c 105 $'**[delivery-lead] DECISION**\nResolves: x' 2026-11-01T10:01:00Z)
  note=$(lc_c 106 '**[jp] NOTE**' 2026-11-01T10:02:00Z)
  lc_comments "[$gate,$dec,$note]"; ar2_tick
  n=$(ar2_launches); sq_cleanup
  assert_eq "$n" "1" "gate 100, decision 105, jp note 106 -> one relaunch" || return 1
}

run_test test_lg_later_non_gate_comment_keeps_decision_valid
