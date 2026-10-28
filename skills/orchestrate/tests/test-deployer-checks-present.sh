# Issue #156 regression guard: an absent floor check (never ran, queued) is not "not failing" — the floor must be
# PRESENT and passing on the PR head. Fix4: which checks block is read from the repo's workflow files (a job-level
# `continue-on-error: true` on base AND head = advisory) and from GitHub's required checks, not from a hand list.
# Reads agents/deployer.md (and orchestrator.md's stage cap line) only; no network.

HERE_DCP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOYER_DCP="$HERE_DCP/../../../agents/deployer.md"

# The Checks gate bullet plus its indented sub-bullets, up to the next 3-space bullet.
dcp_gate() { awk '/^   - \*\*Checks gate/ { on=1; print; next } on && /^   - / { exit } on { print }' "$DEPLOYER_DCP"; }
dcp_exception() { grep -E '^   - .*Exception \(JP, 2026-09-22' "$DEPLOYER_DCP"; }

test_dcp_command_reads_check_runs() {
  local body; body=$(cat "$DEPLOYER_DCP")
  assert_contains "$body" "--json state,mergeable,mergeStateStatus,reviews,headRefOid,statusCheckRollup" "pre-merge command" || return 1
  assert_contains "$body" "check-runs" "gate reads check runs of the head" || return 1
}

test_dcp_named_checks() {
  local gate c; gate=$(dcp_gate)
  [ -n "$gate" ] || { fail "deployer.md: no 'Checks gate' bullet"; return 1; }
  for c in Vitest Quality gitleaks unit-tests migration-rehearsal payroll-sync-tests payroll-scrape-tests; do
    assert_contains "$gate" "\`$c\`" "checks gate bullet" || return 1
  done
}

# The floor must not hand-list a job the repo itself marks continue-on-error: legacy-readers drifted that way and
# parked PRs whose only red check was that advisory job. Advisory status is read from the workflow YAML at the head.
test_dcp_floor_excludes_advisory_legacy_readers() {
  local floor; floor=$(dcp_gate | grep -F 'Present floor')
  [ -n "$floor" ] || { fail "deployer.md: no 'Present floor' sub-bullet"; return 1; }
  assert_not_contains "$floor" "legacy-readers" "present floor must not list the advisory legacy-readers job" || return 1
  assert_not_contains "$(cat "$DEPLOYER_DCP")" "23514" "the legacy-readers 23514 carve-out is subsumed by the advisory rule" || return 1
}

test_dcp_advisory_rule_reads_workflow_at_head() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "\`continue-on-error: true\`" "advisory rule" || return 1
  assert_contains "$gate" "**both on the base branch and at the PR head**" "advisory needs the flag on base and head" || return 1
  # a pull_request run uses the PR's own workflow copy: reading the head alone would let a PR exempt its own red gate
  assert_contains "$gate" "contents/<path>?ref=<base>" "advisory rule reads the base copy" || return 1
  assert_contains "$gate" "?ref=<headRefOid>" "advisory rule reads the head copy" || return 1
  assert_contains "$gate" "never for the base read" "run-success fallback cannot replace the base read" || return 1
  assert_contains "$gate" "never waited on, never blocking" "advisory checks are excluded from waiting too" || return 1
  assert_contains "$gate" "never a check GitHub requires" "advisory never overrides a GitHub-required check" || return 1
  assert_contains "$gate" "A check you cannot prove advisory is a gate" "unknown is never tolerated" || return 1
}

test_dcp_required_and_skipped() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "branches/<base>/protection" "required checks read from branch protection" || return 1
  assert_contains "$gate" "rules/branches/<base>" "required checks read from rulesets" || return 1
  assert_contains "$gate" "\`success\` or \`skipped\`" "path-gated floor jobs that skip are not a block" || return 1
}

test_dcp_wait_cap_fits_stage_cap() {
  local gate orch cap; gate=$(dcp_gate)
  local wait; wait=$(printf '%s\n' "$gate" | sed -nE 's/.*Wait at most \*\*([0-9]+) min\*\* from this run.s start.*/\1/p' | head -1)
  [ -n "$wait" ] || { fail "deployer.md: no 'Wait at most **N min** from this run's start' in the Checks gate"; return 1; }
  assert_contains "$gate" "45-min stage cap" "wait cap tied to the orchestrator stage cap" || return 1
  assert_contains "$gate" "Raise this cap only together with that stage cap" "caps move together" || return 1
  assert_not_contains "$gate" "30 min from" "old fixed 30 min cap is gone" || return 1
  # The wait plus the post-wait work (3-min post-merge deploy wait + ~7 min migrations/merge/report) must fit the
  # orchestrator's deployer stage cap, or the orchestrator kills the deployer — possibly after the merge.
  orch="$HERE_DCP/../../../agents/orchestrator.md"
  cap=$(grep -F '**Stage caps**' "$orch" | sed -nE 's/.*deployer \*\*([0-9]+) min\*\*.*/\1/p')
  [ -n "$cap" ] || { fail "orchestrator.md: no deployer stage cap in the Stage caps line"; return 1; }
  if [ "$cap" -lt $((wait + 10)) ]; then
    fail "orchestrator deployer stage cap ($cap min) < deployer wait cap ($wait min) + 10 min post-wait budget"; return 1
  fi
  assert_eq 0 0 "wait bound ok"
}

test_dcp_absent_blocks_ci_pending() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "absent" "checks gate bullet" || return 1
  assert_contains "$gate" "ci_pending" "checks gate bullet" || return 1
  assert_contains "$gate" "ci_red" "checks gate bullet" || return 1
}

test_dcp_exception_scoped_to_job_names() {
  local ex; ex=$(dcp_exception)
  [ -n "$ex" ] || { fail "deployer.md: no 2026-09-22 exception bullet"; return 1; }
  assert_contains "$ex" "\`Playwright E2E\` job" "exception" || return 1
  assert_contains "$ex" "\`e2e-smoke\` job" "exception" || return 1
  assert_contains "$ex" "\`Vitest\`/\`Quality\`" "exception states they are gates" || return 1
  assert_contains "$ex" "are gates" "exception states they are gates" || return 1
  assert_not_contains "$ex" "workflows — \`E2E Tests\`" "exception must not exempt the whole E2E Tests workflow" || return 1
}

test_dcp_pinned_wording_intact() {
  local body; body=$(cat "$DEPLOYER_DCP")
  assert_contains "$body" "→ \`ci_pending\`" "class guide" || return 1
  assert_contains "$body" "→ \`ci_red\`" "class guide" || return 1
  assert_contains "$body" "required checks (the Checks gate list)" "class guide refers to gate list" || return 1
}

echo "-- deployer checks present (issue #156)"
run_test test_dcp_command_reads_check_runs
run_test test_dcp_named_checks
run_test test_dcp_floor_excludes_advisory_legacy_readers
run_test test_dcp_advisory_rule_reads_workflow_at_head
run_test test_dcp_required_and_skipped
run_test test_dcp_wait_cap_fits_stage_cap
run_test test_dcp_absent_blocks_ci_pending
run_test test_dcp_exception_scoped_to_job_names
run_test test_dcp_pinned_wording_intact

# #471: the post-merge 3-minute deploy-wait-cap stop is class ci_pending (auto-retried), not other / waiting on JP.
test_dcp_postmerge_wait_cap_is_ci_pending() {
  local body line; body=$(cat "$DEPLOYER_DCP")
  line=$(grep -F 'at 3 minutes, stop waiting' "$DEPLOYER_DCP")
  assert_contains "$line" 'Blocked on: ci_pending — merged; staging deploy' "wait-cap stop names the class" || return 1
  assert_contains "$body" '3-minute post-merge wait cap → `ci_pending`' "class guide lists the wait-cap case" || return 1
}
run_test test_dcp_postmerge_wait_cap_is_ci_pending
