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
  # The PR's own changes are head vs merge-base: a job the base gained after the PR branched is not "removed by this PR".
  assert_contains "$gate" ".merge_base_commit.sha" "merge-base copy is read" || return 1
  assert_contains "$gate" "head vs **merge-base**, never head vs the base tip" "PR changes are measured against the merge base" || return 1
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
  assert_contains "$gate" "\`scripts/ci-changes.sh\`" "editing the path classifier voids the skip licence" || return 1
  assert_contains "$gate" "\`ci_red\` with \`<check> skipped; success required\`" "unlicensed skip is ci_red" || return 1
  assert_contains "$gate" "a gate the PR gave an \`if:\` (\`if: false\` on a gate must never read as a pass)" "if:false case named" || return 1
  # Only checks a PR's workflow YAML can disable lose skipped-as-pass; a non-Actions app check keeps it.
  assert_contains "$gate" "a GitHub Actions check that maps to nothing" "unmapped Actions check skip is ci_red" || return 1
  assert_contains "$gate" "A check from a non-Actions app" "non-Actions app checks keep skipped-as-pass" || return 1
  floor=$(dcp_gate | grep -F 'Present floor')
  assert_contains "$floor" "\`unit-tests\`, \`gitleaks\`, \`Vitest\` and \`Quality\` must be \`success\`" "unconditional floor jobs need success" || return 1
}

# Review finding (#520, round 2): the scheduler's `changes` job (classify step in ci.yml + scripts/ci-changes.sh)
# runs from the PR head. A PR that rewrites it to report "payroll untouched" while it edits benjis_payroll/ makes
# payroll-sync-tests skip with its `if:` line untouched. A skip is licensed only by the BASE logic run on the PR's
# real file list (from GitHub, not from the run); a PR changing the workflow file or the classifier gets no licence.
test_dcp_skip_needs_trusted_evidence() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "**A PR never decides, through its own changes, whether its own gates apply to it.**" "principle stated" || return 1
  assert_contains "$gate" "The PR's run is never that evidence" "the run's own skip decision is untrusted" || return 1
  assert_contains "$gate" "the classify step of the scheduler's \`changes\` job in \`ci.yml\`" "the edited-changes-job vector is named" || return 1
  assert_contains "$gate" "pulls/<N>/files?per_page=100\" --jq '.[] | .filename, (.previous_filename // empty)'" "file list from GitHub, renames' old paths included" || return 1
  assert_contains "$gate" "\`gh pr view <N> --json changedFiles --jq .changedFiles\`" "file list completeness checked" || return 1
  assert_contains "$gate" "a read that fails or comes up short is evidence for no skip" "short file list fails closed" || return 1
}

dcp_classifier_cmd() {  # the doc's fenced recompute command, placeholders filled, one shell string
  awk '/^ *```/ { if (on) { if (blk ~ /ci-changes\.sh\?ref=<base>/) { printf "%s", blk; exit } on=0; blk=""; next } on=1; next }
       on { sub(/^ +/, ""); blk = blk $0 "\n" }' "$DEPLOYER_DCP" \
    | sed -e 's#<owner>/<repo>#o/r#g' -e 's#<N>#7#g' -e 's#<base>#staging#g'
}

# The exact bypass, run end to end: the doc's own recompute command against a stub `gh` that serves the real base
# classifier at ref=staging and a tampered, all-false classifier at any other ref (the PR's copy).
test_dcp_edited_classifier_bypass_is_not_exempt() {
  local gate cmd dir out; gate=$(dcp_gate)
  assert_contains "$gate" "the file list holds neither the workflow file that defines the job (\`.github/workflows/ci.yml\`) nor any file the base \`changes\` job runs" "editing ci.yml or the classifier voids the licence" || return 1
  assert_contains "$gate" "the **base copy** of the classifier, run by you on the file list, prints \`<key>=false\`" "licence only from the base classifier's false" || return 1
  assert_contains "$gate" "\`<key>=true\`, no \`<key>=\` line, or a classifier that cannot be read or run → \`ci_red\`" "true/missing/unreadable fail closed" || return 1
  assert_contains "$gate" "A PR that changes \`ci.yml\` or the classifier gets no skip licence at all" "no licence for a classifier-editing PR" || return 1
  assert_contains "$gate" "\`<check> skipped while this PR changes its classifier; success required\`" "classifier-edit skip is ci_red" || return 1
  cmd=$(dcp_classifier_cmd)
  assert_contains "$cmd" "contents/scripts/ci-changes.sh?ref=staging" "recompute reads the classifier at the base ref" || return 1
  dir=$(mktemp -d "${TMPDIR:-/tmp}/dcp-skip.XXXXXX")
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'STUB'
#!/bin/bash
[ "$1" = api ] || { echo "stub gh: only api is served" >&2; exit 9; }
shift; path=""; filter="."
while [ $# -gt 0 ]; do case "$1" in --paginate) shift ;; --jq) filter=$2; shift 2 ;; *) path=$1; shift ;; esac; done
case "$path" in
  "repos/o/r/pulls/7/files?per_page=100") jq -r "$filter" "$DCP_DIR/files.json" ;;
  "repos/o/r/contents/scripts/ci-changes.sh?ref=staging") jq -r "$filter" "$DCP_DIR/base.json" ;;
  "repos/o/r/contents/scripts/ci-changes.sh?ref="*) jq -r "$filter" "$DCP_DIR/head.json" ;;
  *) echo "stub gh: unexpected path $path" >&2; exit 9 ;;
esac
STUB
  chmod +x "$dir/bin/gh"
  # GitHub returns content base64-wrapped at 60 columns.
  printf '{"content":"%s"}\n' "$(base64 < "$HERE_DCP/fixtures/deployer-skip/ci-changes.base.sh" | tr -d '\n' | fold -w 60 | awk '{printf "%s\\n", $0}')" > "$dir/base.json"
  printf '{"content":"%s"}\n' "$(printf 'echo payroll-sync=false\necho payroll-scrape=false\necho migration-rehearsal=false\n' | base64 | tr -d '\n')" > "$dir/head.json"
  dcp_run() { printf '%s\n' "$1" > "$dir/files.json"; DCP_DIR="$dir" PATH="$dir/bin:$PATH" bash -c "$cmd" 2>&1; }
  # 1. The reviewer's case: ci.yml's classify step rewritten to emit nothing, payroll sync code edited.
  out=$(dcp_run '[{"filename":".github/workflows/ci.yml"},{"filename":"benjis_payroll/sync/timesheet-sync.mjs"}]')
  assert_contains "$out" "payroll-sync=true" "edited changes job + payroll code: base classifier requires payroll-sync-tests" || { rm -rf "$dir"; return 1; }
  # 2. Only scripts/ci-changes.sh rewritten (ci.yml untouched), payroll scrape code edited.
  out=$(dcp_run '[{"filename":"scripts/ci-changes.sh"},{"filename":"benjis_payroll/scrape/qbo-payroll-scraper.mjs"}]')
  assert_contains "$out" "payroll-scrape=true" "edited classifier script + payroll code: base classifier requires payroll-scrape-tests" || { rm -rf "$dir"; return 1; }
  # 3. Payroll code moved out of its gated path: the old path still counts.
  out=$(dcp_run '[{"filename":"src/lib/sync.mjs","previous_filename":"benjis_payroll/sync/sync.mjs"}]')
  assert_contains "$out" "payroll-sync=true" "a rename out of benjis_payroll/sync/ still requires the job" || { rm -rf "$dir"; return 1; }
  # 4. Control: an ordinary app-only PR keeps its legitimate skip (no false ci_red).
  out=$(dcp_run '[{"filename":"src/app/page.tsx"}]')
  assert_contains "$out" "payroll-sync=false" "app-only PR: payroll-sync skip stays licensed" || { rm -rf "$dir"; return 1; }
  assert_contains "$out" "migration-rehearsal=false" "app-only PR: migration-rehearsal skip stays licensed" || { rm -rf "$dir"; return 1; }
  rm -rf "$dir"
}

# Same bypass on JP's destructive-DDL approval: migration-lint (scripts/lint-migrations.ts + scripts/lib/, npm deps)
# runs from the PR head and its `destructive` output decides whether destructive-migration-approval runs.
test_dcp_destructive_approval_skip_needs_untouched_linter() {
  local gate; gate=$(dcp_gate)
  assert_contains "$gate" "**Gated by \`migration-lint\`'s \`destructive\` output**" "destructive approval has its own trusted rule" || return 1
  assert_contains "$gate" "The skip passes when the file list holds no path under \`supabase/migrations/\`" "no migrations: nothing to approve" || return 1
  assert_contains "$gate" "none of the linter's inputs: the workflow file, \`scripts/lint-migrations.ts\`, anything under \`scripts/lib/\`" "migrations + edited linter: no licence" || return 1
  assert_contains "$gate" "\`package.json\`, \`package-lock.json\` or \`tsconfig*.json\`" "linter dependencies are inputs too" || return 1
  assert_contains "$gate" "\`Blocked on: needs_jp — destructive-migration-approval skipped while this PR changes both migrations and the migration linter\`" "bypassed JP approval goes to JP" || return 1
  assert_contains "$gate" "A job gated on another job's output gets a skip licence only from a base-only rule named here" "future output-gated jobs get no free licence" || return 1
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

# Review findings (#520, round 2): the class guide still said "35-min" after the wait went back to 30, and a gate
# restart on a new head was not bound by the same deadline.
test_dcp_wait_cap_named_consistently() {
  local gate wait n; gate=$(dcp_gate)
  wait=$(printf '%s\n' "$gate" | sed -nE 's/.*Wait at most \*\*([0-9]+) min\*\* from this run.s start.*/\1/p' | head -1)
  [ -n "$wait" ] || { fail "deployer.md: no wait cap in the Checks gate"; return 1; }
  for n in $(grep -oE '[0-9]+-min in-run wait cap' "$DEPLOYER_DCP" | grep -oE '^[0-9]+'); do
    assert_eq "$n" "$wait" "every 'N-min in-run wait cap' names the gate's wait cap" || return 1
  done
  assert_contains "$(cat "$DEPLOYER_DCP")" "past the ${wait}-min in-run wait cap → \`ci_pending\`" "class guide names the wait cap" || return 1
  assert_contains "$(grep -F '**Pin the head.**' "$DEPLOYER_DCP")" "the restarted wait still ends at the ${wait}-min mark from this run's start" "a restart keeps the deadline" || return 1
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
  # Review finding (#520, round 2): a new failing job a PR adds under one of these names must not be exempt.
  assert_not_contains "$ex" "matched by job name" "exception is not matched by name" || return 1
  assert_contains "$ex" "**job key in the merge-base copy**" "exception anchored on the merge-base job key" || return 1
  assert_contains "$ex" "never by check name" "exception anchored on the merge-base job key" || return 1
  assert_contains "$ex" "key \`e2e\` of \`.github/workflows/e2e-tests.yml\`" "quoting-tool job key named" || return 1
  assert_contains "$ex" "A job a PR adds under either name, in any file, maps to no merge-base job and stays a gate." "added same-name job stays a gate" || return 1
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
run_test test_dcp_skip_needs_trusted_evidence
run_test test_dcp_edited_classifier_bypass_is_not_exempt
run_test test_dcp_destructive_approval_skip_needs_untouched_linter
run_test test_dcp_wait_cap_fits_stage_cap
run_test test_dcp_wait_cap_named_consistently
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
