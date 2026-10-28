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
  assert_contains "$gate" "A read that fails or comes up short is evidence for no skip" "short file list fails closed" || return 1
  # A rename prints two lines (new + old path): counting the recompute list against changedFiles would deny every
  # skip on a rename PR. Completeness is counted on .filename alone.
  assert_contains "$gate" "--jq '.[].filename' | grep -c .\` must equal \`gh pr view <N> --json changedFiles" "completeness counts new paths only" || return 1
  # #473's staging tolerance must not wave a rejected skip through as infrastructure.
  assert_contains "$(cat "$DEPLOYER_DCP")" "A \`skipped\` check the skip rule rejects is never infrastructure class" "rejected skip is never tolerated" || return 1
}

# Review finding (#520, round 3): the skip licence was a deny list (the base classifier's mapping, a list of linter
# inputs) and every round found a path it missed: benjis_payroll/config/ (payroll tests), supabase/cutover/
# (rehearsal), .npmrc (linter's npm ci). It is now an allowlist the doc ships as an executable function; these tests
# run that function, extracted from deployer.md, on real-shaped file lists.
dcp_skip_fn() {  # the doc's skip_licence() definition, indentation stripped
  awk '/^ *skip_licence\(\) \{/ { on=1 } on { sub(/^ +/, ""); print } on && /^\}$/ { exit }' "$DEPLOYER_DCP"
}
# dcp_lic <job> <path>... → the function's output for that file list (one path per argument)
dcp_lic() { local job=$1; shift; printf '%s\n' "$@" | bash -c "$(dcp_skip_fn)"$'\n''skip_licence "$1"' _ "$job" 2>&1; }
dcp_denies() {  # <job> <label> <path>... — the skip must NOT be licensed
  local job=$1 label=$2 out; shift 2; out=$(dcp_lic "$job" "$@")
  case "$out" in "not licensed: "*) return 0 ;; esac
  fail "$job must not be licensed ($label): got '$out' for: $*"; return 1
}
dcp_allows() {  # <job> <label> <path>... — the skip must be licensed
  local job=$1 label=$2 out; shift 2; out=$(dcp_lic "$job" "$@")
  [ "$out" = licensed ] && return 0
  fail "$job must be licensed ($label): got '$out' for: $*"; return 1
}
DCP_MIG=supabase/migrations/20261028_add_x.sql

test_dcp_skip_allowlist_is_shipped_and_deny_list_gone() {
  local gate fn; gate=$(dcp_gate); fn=$(dcp_skip_fn)
  assert_contains "$gate" "an allowlist, never a deny list" "skip licence is an allowlist" || return 1
  assert_contains "$fn" "skip_licence() {" "doc ships the function" || return 1
  assert_contains "$fn" 'echo "not licensed: no allowlist for $job"' "a job without a list is never licensed" || return 1
  assert_contains "$gate" "--jq '.[] | .filename, (.previous_filename // empty)' | skip_licence <job key>" "the doc pipes the GitHub file list, old paths included, into it" || return 1
  assert_contains "$gate" "A missing entry can only block a PR, never wave one through" "fail-closed property stated" || return 1
  # The deny-list forms of rounds 2-3 are gone: no classifier recompute, no hand list of linter inputs.
  assert_not_contains "$gate" "bash <(gh api" "base classifier recompute removed" || return 1
  assert_not_contains "$gate" "anything under \`scripts/lib/\` (its imports live there)" "linter deny list removed" || return 1
  assert_contains "$gate" "\`Blocked on: needs_jp — destructive-migration-approval skipped while this PR changes migrations plus <path>" "unlicensed destructive skip goes to JP" || return 1
  assert_contains "$gate" "\`<check> skipped, but this PR changes <path>, which is not on its skip allowlist; the job must run\`" "unlicensed path-gated skip is ci_red" || return 1
  assert_contains "$gate" "A job gated on another job's output gets a skip licence only from a base-only rule named here" "future output-gated jobs get no free licence" || return 1
}

# The three round-3 vectors: each touches only a file the job reads that the old deny lists did not name.
test_dcp_skip_allowlist_denies_round3_vectors() {
  dcp_denies payroll-sync-tests "payroll config fixture" benjis_payroll/config/stat_pay_fixtures.json || return 1
  dcp_denies payroll-scrape-tests "payroll config fixture" benjis_payroll/config/stat_pay_fixtures.json || return 1
  dcp_denies migration-rehearsal "cutover SQL the rehearsal runs" supabase/cutover/reconcile.sql || return 1
  dcp_denies destructive-migration-approval "migration + .npmrc" "$DCP_MIG" .npmrc || return 1
}

# Rounds 1-2 vectors, now caught by the same allowlist (no classifier involved).
test_dcp_skip_allowlist_denies_round2_vectors() {
  dcp_denies payroll-sync-tests "edited changes job + payroll code" .github/workflows/ci.yml benjis_payroll/sync/timesheet-sync.mjs || return 1
  dcp_denies payroll-scrape-tests "edited classifier + payroll code" scripts/ci-changes.sh benjis_payroll/scrape/qbo-payroll-scraper.mjs || return 1
  dcp_denies payroll-sync-tests "rename out of the payroll tree (old path)" src/lib/sync.mjs benjis_payroll/sync/sync.mjs || return 1
  dcp_denies migration-rehearsal "ci.yml alone" .github/workflows/ci.yml || return 1
  # ci.yml defines the payroll jobs' steps and is read by benjis_payroll/scrape/repo-guards.test.mjs.
  dcp_denies payroll-sync-tests "ci.yml alone" .github/workflows/ci.yml || return 1
  dcp_denies payroll-scrape-tests "ci.yml alone" .github/workflows/ci.yml || return 1
  dcp_denies migration-rehearsal "the rehearsal's own entry script" scripts/rehearse-migrations.sh || return 1
  dcp_denies destructive-migration-approval "migration + linter CLI" "$DCP_MIG" scripts/lint-migrations.ts || return 1
  dcp_denies destructive-migration-approval "migration + linter lib" "$DCP_MIG" scripts/lib/migration-lint-core.ts || return 1
  dcp_denies destructive-migration-approval "migration + a test file inside scripts/lib/" "$DCP_MIG" scripts/lib/migration-lint-core.test.ts || return 1
  dcp_denies destructive-migration-approval "migration + ci.yml" "$DCP_MIG" .github/workflows/ci.yml || return 1
  # A migration renamed out of supabase/migrations/ still counts through its old path, so the linter edit is caught.
  dcp_denies destructive-migration-approval "migration renamed away + linter edit" docs/x.sql "$DCP_MIG" scripts/lint-migrations.ts || return 1
}

# Paths that look unrelated but are not provably outside the job's reads: root configs, lockfiles, dotfiles, a new
# top-level folder, a .md inside the job's own tree. None is on any list, so none licenses a skip.
test_dcp_skip_allowlist_denies_unlisted_lookalikes() {
  local job p
  for job in payroll-sync-tests payroll-scrape-tests migration-rehearsal; do
    for p in .nvmrc .npmrc package.json package-lock.json tsconfig.json playwright.config.ts .gitattributes newtool/run.ts; do
      dcp_denies "$job" "unlisted $p" src/app/page.tsx "$p" || return 1
    done
    dcp_denies "$job" "empty file list" || return 1
  done
  for p in .nvmrc package.json package-lock.json tsconfig.json tsconfig.scripts.json .github/workflows/other.yml scripts/run.ts newtool/run.ts; do
    dcp_denies destructive-migration-approval "migration + $p" "$DCP_MIG" "$p" || return 1
  done
  dcp_denies payroll-sync-tests "a .md inside the payroll tree" benjis_payroll/MIGRATION.md || return 1
  dcp_denies migration-rehearsal "a .md inside supabase/" supabase/rehearsal/assertions/README.md || return 1
  dcp_denies destructive-migration-approval "empty file list" || return 1
  dcp_denies unit-tests "a job with no allowlist" src/app/page.tsx || return 1
  # Real PR (scheduler #1992, merged 2026-10-28 with payroll-scrape-tests skipped): payroll config + app code.
  dcp_denies payroll-scrape-tests "scheduler #1992's file list" benjis_payroll/config/cutoff_fixtures.json \
    benjis_payroll/sync/cutoff.mjs docs/user-guide/analytics.md src/lib/services/payrollCutoff.ts || return 1
}

# Controls: the lists must keep the skips ordinary PRs rely on (measured on 100 merged scheduler PRs: 1-2 blocks per job).
test_dcp_skip_allowlist_keeps_safe_skips() {
  local job
  for job in payroll-sync-tests payroll-scrape-tests migration-rehearsal; do
    dcp_allows "$job" "app-only PR" src/app/page.tsx src/components/x.tsx || return 1
    dcp_allows "$job" "docs-only PR" docs/user-guide/analytics.md README.md CLAUDE.md || return 1
    dcp_allows "$job" "e2e + unit test + other workflow" e2e/ops/x.spec.ts scripts/foo.test.ts .github/workflows/mobile-auto-release.yml || return 1
  done
  dcp_allows payroll-sync-tests "migration PR" "$DCP_MIG" scripts/rehearse-migrations.test.ts src/types/database.ts || return 1
  dcp_allows payroll-scrape-tests "classifier edit only (payroll never reads it)" scripts/ci-changes.sh || return 1
  dcp_allows migration-rehearsal "payroll-only PR" benjis_payroll/sync/timesheet-sync.mjs benjis_payroll/config/x.json || return 1
  dcp_allows destructive-migration-approval "no migration, linter edited: nothing to approve" scripts/lint-migrations.ts package.json .npmrc || return 1
  dcp_allows destructive-migration-approval "typical migration PR" "$DCP_MIG" scripts/rehearse-migrations.test.ts \
    supabase/rehearsal/production-order.txt src/types/database.ts e2e/ops/x-rls.spec.ts docs/user-guide/x.md || return 1
  dcp_allows destructive-migration-approval "migration + nested scripts test" "$DCP_MIG" scripts/migration-rehearsal/migrations.test.ts || return 1
}

# Review finding (#520, round 3, MEDIUM): a PR can add a workflow file with a job named like a gate; a same-named
# passing run must never stand in for the real one. Re-run attempts collapse under filter=latest (verified).
test_dcp_duplicate_check_names_each_must_pass() {
  local gate body; gate=$(dcp_gate); body=$(cat "$DEPLOYER_DCP")
  assert_contains "$body" "check-runs?filter=latest&per_page=100" "step-2 read pins filter=latest" || return 1
  assert_contains "$gate" "**Several check runs with one name: every one must pass.**" "duplicate-name rule" || return 1
  assert_contains "$gate" "never once per name" "each run judged on its own" || return 1
  assert_contains "$body" "suite:.check_suite.id,url:.details_url" "step-2 read carries each run's suite and link" || return 1
  assert_contains "$gate" "never by joining a check run to a \`gh pr checks\` row by name" "run id from the run's own link, not a name join" || return 1
  assert_contains "$gate" "a re-run attempt replaces its earlier attempts in the same workflow run" "retries are not duplicates" || return 1
  assert_contains "$gate" "A passing run never stands in for a failing, skipped, queued or running one of the same name" "no stand-in" || return 1
  assert_contains "$(dcp_gate | grep -F 'Present floor')" "a same-named run from another workflow file never fills the floor" "floor needs the mapped run" || return 1
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
run_test test_dcp_skip_allowlist_is_shipped_and_deny_list_gone
run_test test_dcp_skip_allowlist_denies_round3_vectors
run_test test_dcp_skip_allowlist_denies_round2_vectors
run_test test_dcp_skip_allowlist_denies_unlisted_lookalikes
run_test test_dcp_skip_allowlist_keeps_safe_skips
run_test test_dcp_duplicate_check_names_each_must_pass
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
