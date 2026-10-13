# Issue #156 regression guard: the deployer must merge only when the repo's named unit/lint/secret
# checks are PRESENT and SUCCESS on the PR head — an absent check (never ran, queued) is not "not failing".
# Reads agents/deployer.md only; no network.

HERE_DCP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOYER_DCP="$HERE_DCP/../../../agents/deployer.md"

dcp_gate() { grep -E '^   - \*\*Checks gate' "$DEPLOYER_DCP"; }
dcp_exception() { grep -E '^   - .*Exception \(JP, 2026-09-22' "$DEPLOYER_DCP"; }

test_dcp_command_reads_check_runs() {
  local body; body=$(cat "$DEPLOYER_DCP")
  assert_contains "$body" "--json state,mergeable,mergeStateStatus,reviews,headRefOid,statusCheckRollup" "pre-merge command" || return 1
  assert_contains "$body" "check-runs" "gate reads check runs of the head" || return 1
}

test_dcp_named_checks() {
  local gate c; gate=$(dcp_gate)
  [ -n "$gate" ] || { fail "deployer.md: no 'Checks gate' bullet"; return 1; }
  for c in Vitest Quality gitleaks unit-tests migration-rehearsal legacy-readers payroll-sync-tests payroll-scrape-tests; do
    assert_contains "$gate" "$c" "checks gate bullet" || return 1
  done
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
run_test test_dcp_absent_blocks_ci_pending
run_test test_dcp_exception_scoped_to_job_names
run_test test_dcp_pinned_wording_intact
