# Issue #156 regression guard: an absent floor check (never ran, queued) is not "not failing" — the floor must be
# PRESENT and passing on the PR head. Fix4: which checks block is read from the repo's workflow files, anchored on
# the BASE copy (only a job already `continue-on-error: true` on the base is advisory; only a job with a base `if:`
# may pass as `skipped`) and from GitHub's required checks, not from a hand list.
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
  # a pull_request run uses the PR's own workflow copy: the exemption is anchored on the base copy, never the head's
  assert_contains "$gate" "anchored on the **base branch's copy**" "every rule is anchored on the base copy" || return 1
  assert_contains "$gate" "**already advisory on the base before this PR**" "only a job advisory on the base can be advisory" || return 1
  assert_contains "$gate" "contents/<path>?ref=<base>" "advisory rule reads the base copy" || return 1
  assert_contains "$gate" "?ref=<headRefOid>" "a PR that changed the workflow file has its head copy compared" || return 1
  assert_contains "$gate" "never evidence on its own" "failed-job/successful-run pattern is not evidence (the run used the PR's YAML)" || return 1
  assert_not_contains "$gate" "may stand in for" "no run-level fallback in place of a YAML read" || return 1
  assert_contains "$gate" "never waited on, never blocking" "advisory checks are excluded from waiting too" || return 1
  assert_contains "$gate" "never a check GitHub requires" "advisory never overrides a GitHub-required check" || return 1
  assert_contains "$gate" "A check you cannot prove advisory is a gate" "unknown is never tolerated" || return 1
}

# Review finding (#520): matching by check name alone let a PR rename its own gate (`name:` or key) to an advisory
# job's name and exempt itself. Identity is the base job key: exactly one job in each copy, same key, and a job the
# PR removes or renames is a BLOCK (its check would just vanish from the head, invisible to the catch-all).
test_dcp_advisory_rename_is_not_advisory() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "**Map each check to its base job**" "checks are mapped to a base job, not matched by name" || return 1
  assert_contains "$gate" "exactly one job of the base copy has that check name" "unique base match" || return 1
  assert_contains "$gate" "exactly one head job with that check name, under the same key" "head job must keep the base key" || return 1
  assert_contains "$gate" "renames a gate (key or \`name:\`) to an advisory job's name, does not exempt its own red check" "rename case" || return 1
  assert_contains "$gate" "removed or renamed by this PR" "a vanished gate job blocks" || return 1
  assert_contains "$gate" "**When \`gh pr diff <N> --name-only\` lists that workflow file**" "head copy read when the PR changed the file" || return 1
}

test_dcp_required_and_skipped() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "branches/<base>/protection" "required checks read from branch protection" || return 1
  assert_contains "$gate" "rules/branches/<base>" "required checks read from rulesets" || return 1
  assert_contains "$gate" "**\`skipped\` passes only for a job that is conditional by design.**" "skip rule" || return 1
  assert_contains "$gate" "or \`skipped\` only where the skip rule above allows it" "floor accepts skipped only via the skip rule" || return 1
  assert_not_contains "$gate" "completed \`success\`, \`skipped\` or \`neutral\`" "catch-all no longer accepts any skipped" || return 1
}

# Review finding (#520): `if: false` added to `unit-tests` reports `skipped`; that must never pass the gate.
test_dcp_unconditional_skipped_is_ci_red() {
  local gate floor; gate=$(dcp_gate)
  assert_contains "$gate" "maps to a base job with a job-level \`if:\`" "skip licence comes from the base copy" || return 1
  assert_contains "$gate" "\`if:\` and \`needs:\` are text-identical to the base's" "a PR cannot rewrite a gate's condition" || return 1
  assert_contains "$gate" "\`scripts/ci-changes.sh\`" "editing the path classifier voids the skip licence" || return 1
  assert_contains "$gate" "\`ci_red\` with \`<check> skipped; success required\`" "unlicensed skip is ci_red" || return 1
  assert_contains "$gate" "\`if: false\` on a gate must never read as a pass" "if:false case named" || return 1
  floor=$(dcp_gate | grep -F 'Present floor')
  assert_contains "$floor" "\`unit-tests\`, \`gitleaks\`, \`Vitest\` and \`Quality\` must be \`success\`" "unconditional floor jobs need success" || return 1
}

test_dcp_wait_cap_fits_stage_cap() {
  local gate orch cap; gate=$(dcp_gate)
  local wait; wait=$(printf '%s\n' "$gate" | sed -nE 's/.*Wait at most \*\*([0-9]+) min\*\* from this run.s start.*/\1/p' | head -1)
  [ -n "$wait" ] || { fail "deployer.md: no 'Wait at most **N min** from this run's start' in the Checks gate"; return 1; }
  assert_contains "$gate" "45-min stage cap" "wait cap tied to the orchestrator stage cap" || return 1
  assert_contains "$gate" "Raise this cap only together with that stage cap" "caps move together" || return 1
  # Review finding (#520): the cap was checked only between polls of up to 9 min, so a wait could overrun it by 9 min.
  assert_contains "$gate" "**each poll loop runs for at most min(9 min, the time left to the ${wait}-min mark)**" "each poll is bounded by the time left to the wait cap" || return 1
  # The wait + post-wait work (3-min post-merge deploy wait + ~7 min migrations/merge/report) + 5 min slack must fit
  # the orchestrator's deployer stage cap: at the cap the orchestrator stops waiting while the deployer may be mid-merge.
  orch="$HERE_DCP/../../../agents/orchestrator.md"
  cap=$(grep -F '**Stage caps**' "$orch" | sed -nE 's/.*deployer \*\*([0-9]+) min\*\*.*/\1/p')
  [ -n "$cap" ] || { fail "orchestrator.md: no deployer stage cap in the Stage caps line"; return 1; }
  if [ "$cap" -lt $((wait + 15)) ]; then
    fail "orchestrator deployer stage cap ($cap min) < deployer wait cap ($wait min) + 10 min post-wait + 5 min slack"; return 1
  fi
  assert_contains "$(grep -F '**Stage caps**' "$orch")" "its ${wait} min pending-checks wait" "orchestrator line names the current wait cap" || return 1
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
run_test test_dcp_advisory_rename_is_not_advisory
run_test test_dcp_required_and_skipped
run_test test_dcp_unconditional_skipped_is_ci_red
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
