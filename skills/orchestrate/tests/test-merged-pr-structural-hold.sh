# Tests for claude-agents#92 — a PR merged outside the pipeline, and a structural stop (start-gate, closed PR),
# must not loop the supervisor to 6 restarts.
#
#   supervisor  structural fail in this run -> held; concurrency-gate fail in this run -> restart;
#               structural fail only in an earlier run -> restart (extends #88's hold; "this run" = ts >= .launched-at)
#   doc pins    orchestrator merged-PR route + structural log line + start-gate wording; deployer post-merge
#               exception (incl. migration check); project-manager :76 "counted as deployed" wording removed
#
# Reuses the sq_* helpers of test-supervisor-queued-not-counted.sh (same load trick as test-supervisor-total-reset.sh).
# Placeholder repos only.

HERE_MS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_MS=$(cd "$HERE_MS/../../.." && pwd)
ORCH_MS="$ROOT_MS/agents/orchestrator.md"
DEPL_MS="$ROOT_MS/agents/deployer.md"
PMGR_MS="$ROOT_MS/agents/project-manager.md"

if ! declare -f sq_env >/dev/null 2>&1; then
  eval "ms_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_MS/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f ms_real_run_test | sed '1s/ms_real_run_test/run_test/')"
fi

MS_IMPL='**[fullstack-developer] IMPLEMENTED**'

# ms_seed_run_line <stage> <secs-ago> — one validate fail line for issue 42 in the isolated runs.jsonl
ms_seed_run_line() {
  local ts
  ts=$(sq_iso_ago "$2")
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"ts":"%s","host":"h","event":"validate","repo":"project-a/repo-a","issue":42,"stage":"%s","result":"fail","reason":"x"}\n' \
    "$ts" "$1" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
}

# ms_exited_run <stage> <secs-ago> — a run that exited non-transiently (launched 600 s ago), gate marker IMPLEMENTED,
# one validate fail line of <stage> logged <secs-ago> seconds ago. Ticks once; prints nothing, sets MS_LOG/MS_HELD/MS_QUEUED.
ms_exited_run() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$MS_IMPL"
  ms_seed_run_line "$1" "$2"
  sq_tick
  MS_LOG=$(sq_log)
  MS_HELD=$(sq_present "$SQ_PIPE/orch-42.held")
  MS_QUEUED=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  sq_cleanup
}

test_ms_structural_fail_in_this_run_holds() {
  ms_exited_run structural 60   # 60 s ago >= launched 600 s ago: this run
  assert_eq "$MS_HELD" "present" "#92: structural fail this run -> .held" || return 1
  assert_contains "$MS_LOG" "[held] #42" "#92: [held] line logged" || return 1
  assert_not_contains "$MS_LOG" "[queue-restart] #42" "#92: no restart queued" || return 1
  assert_eq "$MS_QUEUED" "absent" "#92: no queue entry" || return 1
}

test_ms_concurrency_gate_fail_in_this_run_restarts() {
  ms_exited_run concurrency-gate 60
  assert_contains "$MS_LOG" "[queue-restart] #42" "#92: other validate-fail stage still restarts" || return 1
  assert_not_contains "$MS_LOG" "[held] #42" "#92: not held" || return 1
  assert_eq "$MS_HELD" "absent" "#92: no .held" || return 1
}

test_ms_structural_fail_in_earlier_run_restarts() {
  ms_exited_run structural 1200   # 1200 s ago < launched 600 s ago: an earlier run
  assert_contains "$MS_LOG" "[queue-restart] #42" "#92: stale structural fail (before .launched-at) still restarts" || return 1
  assert_not_contains "$MS_LOG" "[held] #42" "#92: not held" || return 1
  assert_eq "$MS_HELD" "absent" "#92: no .held" || return 1
}

# structural fail logged for a different issue (99) must not hold #42
test_ms_structural_fail_other_issue_does_not_hold() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$MS_IMPL"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"ts":"%s","host":"h","event":"validate","repo":"project-a/repo-a","issue":99,"stage":"structural","result":"fail","reason":"x"}\n' \
    "$(sq_iso_ago 60)" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
  sq_tick
  local log held
  log=$(sq_log); held=$(sq_present "$SQ_PIPE/orch-42.held")
  sq_cleanup
  assert_contains "$log" "[queue-restart] #42" "#92: other issue's structural fail does not hold #42" || return 1
  assert_eq "$held" "absent" "#92: no .held for #42" || return 1
}

# ---- doc pins (text of the agent definitions) ----

ms_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
ms_lacks() { if grep -qF -- "$2" "$1"; then fail "$(basename "$1"): must NOT contain [$2]"; return 1; fi; }

test_ms_orchestrator_merged_pr_route() {
  local row
  row=$(grep -F 'already merged' "$ORCH_MS" | grep -F 'post-merge checks only' | head -1)
  assert_ne "$row" "" "#92: orchestrator names the 'PR #N is already merged — post-merge checks only' dispatch" || return 1
  assert_contains "$row" "deployer" "#92: route dispatches the deployer" || return 1
  assert_contains "$row" "MERGED" "#92: keyed on state MERGED" || return 1
  assert_contains "$row" "baseRefName" "#92: keyed on baseRefName" || return 1
  assert_contains "$row" "integration branch" "#92: base must be the integration branch" || return 1
  assert_contains "$row" "IMPLEMENTED" "#92: gate marker IMPLEMENTED covered" || return 1
  assert_contains "$row" "PASS" "#92: gate marker code-reviewer PASS (deployer merged, no marker) covered" || return 1
  assert_contains "$row" "closingIssuesReferences" "#92: row states the route does not key on closingIssuesReferences" || return 1
  assert_contains "$row" "no reviewer" "#92: dispatches no reviewer for an already-merged PR" || return 1
  assert_contains "$row" "unmerged" "#92: closed, unmerged PR stays a Structural stop" || return 1
  assert_contains "$row" "Structural" "#92: closed, unmerged PR stays a Structural stop" || return 1
}

test_ms_orchestrator_structural_log_line() {
  ms_has "$ORCH_MS" '"event":"validate","stage":"structural","result":"fail"' || return 1
  local line
  line=$(grep -F '**Structural**' "$ORCH_MS" | head -1)
  assert_contains "$line" "structural" "#92: Structural bullet says to log the structural fail line" || return 1
  assert_contains "$line" "reason" "#92: failing check goes in reason" || return 1
  assert_not_contains "$line" "PR missing/closed/draft" "#92: merged PR no longer lumped under 'PR missing/closed/draft'" || return 1
}

test_ms_orchestrator_start_gate_wording() {
  ms_lacks "$ORCH_MS" "resumes automatically" || return 1
  ms_has "$ORCH_MS" "held until it is relaunched after" || return 1
}

test_ms_deployer_post_merge_mode() {
  ms_has "$DEPL_MS" "post-merge mode" || return 1
  ms_has "$DEPL_MS" "Merged outside the pipeline; reviews not run" || return 1
  ms_has "$DEPL_MS" "DEPLOYED TO STAGING" || return 1
  local para
  para=$(grep -F 'post-merge mode' "$DEPL_MS")
  assert_contains "$para" "reviewer" "#92: exception skips the reviewer-pass input" || return 1
  assert_contains "$para" "OPEN" "#92: exception skips the OPEN check" || return 1
  assert_contains "$para" "Skip" "#92: exception says skip (steps 1-2)" || return 1
  assert_contains "$para" "merge commit" "#92: deploy job verified for the merge commit" || return 1
  assert_contains "$para" "MERGED" "#92: post-merge mode starts from a MERGED PR (skips the OPEN check)" || return 1
  assert_contains "$para" "migration" "#92: post-merge mode checks migrations" || return 1
  assert_contains "$para" "staging project" "#92: migrations checked on the staging project" || return 1
  assert_contains "$para" "refuse" "#92: missing migration applied under the refuse-list" || return 1
  assert_contains "$para" "BLOCKED" "#92: unappliable migration -> BLOCKED" || return 1
  assert_contains "$para" "deploy job" "#92: verifies the deploy job" || return 1
  assert_contains "$para" "milestone" "#92: runs the milestone check" || return 1
}

test_ms_project_manager_wording_replaced() {
  ms_lacks "$PMGR_MS" "counted as deployed to staging" || return 1
  local line
  line=$(grep -F 'post-merge mode' "$PMGR_MS" | head -1)
  assert_ne "$line" "" "#92: PM rule points at the deployer's post-merge mode" || return 1
  assert_contains "$line" "relaunch" "#92: PM rule says to relaunch the ticket" || return 1
}

run_test test_ms_structural_fail_in_this_run_holds
run_test test_ms_concurrency_gate_fail_in_this_run_restarts
run_test test_ms_structural_fail_in_earlier_run_restarts
run_test test_ms_structural_fail_other_issue_does_not_hold
run_test test_ms_orchestrator_merged_pr_route
run_test test_ms_orchestrator_structural_log_line
run_test test_ms_orchestrator_start_gate_wording
run_test test_ms_deployer_post_merge_mode
run_test test_ms_project_manager_wording_replaced
