# Issue #79 regression guard: the deployer pre-dispatch row in agents/orchestrator.md must not
# duplicate the `mergeable` check. A conflicting PR that failed that duplicate check before the
# deployer was ever dispatched left the orchestrator posting no marker at all — the only route to
# **[deployer] BLOCKED** (the one status the supervisor can park and a delegated decision can
# resume) runs through an actual deployer dispatch. deployer.md already owns the mergeable check
# (`MERGEABLE`, `:113`) and reports it as BLOCKED (`:98`), so the orchestrator's copy is deleted,
# not replaced.
# Nothing here touches the network, gh, or /tmp/pipeline: every case reads tracked files only.

HERE_DMP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DMP=$(cd "$HERE_DMP/../../.." && pwd)
ORCH_DMP="$ROOT_DMP/agents/orchestrator.md"
DEPLOYER_DMP="$ROOT_DMP/agents/deployer.md"

# dmp_deployer_row — prints the `| deployer | ... |` row from the pre-dispatch validation table.
dmp_deployer_row() {
  grep -E '^\| deployer \|' "$ORCH_DMP"
}

test_dmp_ac1_no_mergeable_clause_in_orchestrator_row() {
  local body
  assert_file_exists "$ORCH_DMP" "orchestrator definition" || return 1
  [ -n "$(dmp_deployer_row)" ] || { fail "orchestrator.md: no '| deployer |' pre-dispatch row found"; return 1; }
  # File-wide, not row-scoped: the incident was the orchestrator owning a mergeable check at all,
  # so a clause reappearing anywhere in the file (not just this row) would reopen the gap.
  body=$(cat "$ORCH_DMP")
  assert_not_contains "$body" "mergeable" "orchestrator.md (whole file)" || return 1
  assert_not_contains "$body" "MERGEABLE" "orchestrator.md (whole file)" || return 1
}

test_dmp_ac1_other_conditions_unchanged() {
  local row
  row=$(dmp_deployer_row)
  [ -n "$row" ] || { fail "orchestrator.md: no '| deployer |' pre-dispatch row found"; return 1; }
  assert_contains "$row" "[code-reviewer] PASS" "deployer pre-dispatch row" || return 1
  assert_contains "$row" "[test-reviewer] PASS" "deployer pre-dispatch row" || return 1
  assert_contains "$row" "dated after the latest \`IMPLEMENTED\`" "deployer pre-dispatch row" || return 1
  assert_contains "$row" "test-lock validate line for this issue is \`pass\`" "deployer pre-dispatch row" || return 1
}

# AC2/read-only confirmation: deployer.md still owns the mergeable check and reports it as BLOCKED.
test_dmp_ac2_deployer_still_owns_the_check() {
  assert_file_exists "$DEPLOYER_DMP" "deployer definition" || return 1
  assert_contains "$(cat "$DEPLOYER_DMP")" "MERGEABLE" "deployer.md" || return 1
  assert_contains "$(cat "$DEPLOYER_DMP")" "**[deployer] BLOCKED**" "deployer.md" || return 1
  assert_contains "$(cat "$DEPLOYER_DMP")" "If the PR isn't mergeable, stop and report why" "deployer.md" || return 1
}

# AC6: net new mechanisms are 0 — no new marker/state-file vocabulary was introduced by this change.
test_dmp_ac6_no_new_marker_introduced() {
  local hits
  hits=$(grep -n 'CONFLICTING' "$ORCH_DMP" || true)
  assert_eq "$hits" "" "orchestrator.md should not gain a new CONFLICTING-specific route" || return 1
}

echo "-- deployer mergeable pre-check (issue #79)"
run_test test_dmp_ac1_no_mergeable_clause_in_orchestrator_row
run_test test_dmp_ac1_other_conditions_unchanged
run_test test_dmp_ac2_deployer_still_owns_the_check
run_test test_dmp_ac6_no_new_marker_introduced
