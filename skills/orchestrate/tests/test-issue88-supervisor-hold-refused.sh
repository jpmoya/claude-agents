# Tests for claude-agents#88 — the supervisor holds (not restarts) a run whose own delegated-decision check or
# loop-cap check failed in this launch.
#
#   supervisor  delegated-decision / loop-cap fail (this run, this issue) -> held; pass line, stale fail,
#               other-issue fail -> restart as today
#   doc pins    supervisor stage tuple; orchestrator Loop cap + Run log; CLAUDE.md wording
# Prefixed i88_ (all test files share one shell). Placeholder repos only.

HERE_I88=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_I88=$(cd "$HERE_I88/../../.." && pwd)

if ! declare -f sq_env >/dev/null 2>&1; then
  eval "i88_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I88/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f i88_real_run_test | sed '1s/i88_real_run_test/run_test/')"
fi

# i88_run <stage> <result> <secs-ago> <issue-in-line> [gate-marker] — run launched 600 s ago, one validate line; ticks once.
# Sets I88_LOG / I88_HELD / I88_QUEUED.
i88_run() {
  local stage="$1" result="$2" ago="$3" line_issue="$4" gate="${5:-**[fullstack-developer] IMPLEMENTED**}"
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$gate"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"ts":"%s","host":"h","event":"validate","repo":"project-a/repo-a","issue":%s,"stage":"%s","result":"%s","reason":"x"}\n' \
    "$(sq_iso_ago "$ago")" "$line_issue" "$stage" "$result" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
  sq_tick
  I88_LOG=$(sq_log)
  I88_HELD=$(sq_present "$SQ_PIPE/orch-42.held")
  I88_QUEUED=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  sq_cleanup
}

i88_assert_held() {
  assert_eq "$I88_HELD" "present" "#88: .held created" || return 1
  assert_contains "$I88_LOG" "[held] #42" "#88: [held] logged" || return 1
  assert_not_contains "$I88_LOG" "[queue-restart] #42" "#88: no [queue-restart]" || return 1
  assert_eq "$I88_QUEUED" "absent" "#88: no queue entry" || return 1
}

i88_assert_restarted() {
  assert_contains "$I88_LOG" "[queue-restart] #42" "#88: restart path" || return 1
  assert_not_contains "$I88_LOG" "[held] #42" "#88: not held" || return 1
  assert_eq "$I88_HELD" "absent" "#88: no .held" || return 1
  assert_eq "$I88_QUEUED" "present" "#88: queue entry written" || return 1
}

test_i88_delegated_decision_fail_holds() {
  i88_run delegated-decision fail 60 42
  i88_assert_held
}

test_i88_loop_cap_fail_holds() {
  i88_run loop-cap fail 60 42
  i88_assert_held
}

# gate marker is whatever it was at the cap: TESTS FAIL must hold too
test_i88_loop_cap_fail_holds_on_tests_fail_marker() {
  i88_run loop-cap fail 60 42 '**[test-reviewer] TESTS FAIL: 1 findings**'
  i88_assert_held
}

test_i88_delegated_decision_pass_restarts() {
  i88_run delegated-decision pass 60 42
  i88_assert_restarted
}

test_i88_delegated_decision_stale_fail_restarts() {
  i88_run delegated-decision fail 4200 42   # an hour before .launched-at (600 s ago)
  i88_assert_restarted
}

test_i88_loop_cap_stale_fail_restarts() {
  i88_run loop-cap fail 4200 42
  i88_assert_restarted
}

test_i88_delegated_decision_other_issue_restarts() {
  i88_run delegated-decision fail 60 99
  i88_assert_restarted
}

test_i88_loop_cap_other_issue_restarts() {
  i88_run loop-cap fail 60 99
  i88_assert_restarted
}

# ---- doc pins ----
i88_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
i88_lacks() { if grep -qF -- "$2" "$1"; then fail "$(basename "$1"): must NOT contain [$2]"; return 1; fi; }

test_i88_supervisor_stage_tuple() {
  i88_has "$ROOT_I88/skills/orchestrate/supervisor.sh" '("structural", "delegated-decision", "loop-cap")' || return 1
  i88_lacks "$ROOT_I88/skills/orchestrate/supervisor.sh" 'in ("structural",)' || return 1
}

test_i88_orchestrator_loop_cap_logs_fail() {
  local sec
  sec=$(awk '/^## Loop cap/{f=1;next} /^## /{f=0} f' "$ROOT_I88/agents/orchestrator.md")
  assert_contains "$sec" '"stage":"loop-cap","result":"fail"' "#88: Loop cap section names the loop-cap fail line" || return 1
  assert_contains "$sec" "log_run" "#88: via log_run" || return 1
  assert_contains "$sec" "terminal" "#88: logged before the terminal event" || return 1
  assert_contains "$sec" "TEST DEFECT" "#88: covers the TEST DEFECT second-round cap" || return 1
  assert_contains "$sec" "pre-impl" "#88: covers pre-implementation cap" || return 1
  assert_contains "$sec" "post-impl" "#88: covers post-implementation cap" || return 1
}

test_i88_orchestrator_run_log_lists_loop_cap() {
  local sec
  sec=$(awk '/^## Run log/{f=1;next} /^## /{f=0} f' "$ROOT_I88/agents/orchestrator.md")
  assert_contains "$sec" '"stage":"loop-cap","result":"fail"' "#88: Run log lists the loop-cap stage" || return 1
  assert_contains "$sec" '"stage":"delegated-decision","result":"fail"' "#88: delegated-decision example still there" || return 1
}

test_i88_claude_md_resolves_wording() {
  i88_has "$ROOT_I88/CLAUDE.md" 'a `Resolves: <URL of the comment this answers>` line' || return 1
  i88_lacks "$ROOT_I88/CLAUDE.md" 'a `Resolves:` line pointing at the comment' || return 1
}

run_test test_i88_delegated_decision_fail_holds
run_test test_i88_loop_cap_fail_holds
run_test test_i88_loop_cap_fail_holds_on_tests_fail_marker
run_test test_i88_delegated_decision_pass_restarts
run_test test_i88_delegated_decision_stale_fail_restarts
run_test test_i88_loop_cap_stale_fail_restarts
run_test test_i88_delegated_decision_other_issue_restarts
run_test test_i88_loop_cap_other_issue_restarts
run_test test_i88_supervisor_stage_tuple
run_test test_i88_orchestrator_loop_cap_logs_fail
run_test test_i88_orchestrator_run_log_lists_loop_cap
run_test test_i88_claude_md_resolves_wording
