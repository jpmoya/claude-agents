# Issue #104 — the six lines in agents/fullstack-developer.md, agents/code-reviewer.md,
# agents/test-reviewer.md, and skills/fullstack-bug-fixing/SKILL.md that ordered an
# unscoped/full-suite local test run, for every lane, must instead order a run scoped to
# what changed. This pins the adjudicator's own AC1/AC2 greps plus the substantive wording
# each line is required to carry, so the defect (or a regression back into it) can't land
# again silently.
#
# AC4 (agents/orchestrator.md untouched) is out of scope for this file: it is a git-diff
# check against a base commit, not a property of the checked-out text, and doesn't fit this
# grep-on-worktree harness.

HERE_104=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_104=$(cd "$HERE_104/../../.." && pwd)

FD_104="$ROOT_104/agents/fullstack-developer.md"
CR_104="$ROOT_104/agents/code-reviewer.md"
TR_104="$ROOT_104/agents/test-reviewer.md"
SK_104="$ROOT_104/skills/fullstack-bug-fixing/SKILL.md"

# test_issue104_ac1_no_unscoped_phrasing — the adjudicator's own grep must return zero hits
# in the four files this ticket fixes.
test_issue104_ac1_no_unscoped_phrasing() {
  local hits
  hits=$(grep -n -iE 'full suite|whole suite|suite first|suite green' \
    "$FD_104" "$CR_104" "$TR_104" "$SK_104" 2>/dev/null)
  assert_eq "$hits" "" "AC1: no 'full suite/whole suite/suite first/suite green' phrasing left in the four files" || return 1
}

# test_issue104_ac2_bare_runs_are_scoped — every remaining npm-test/vitest-run mention in
# the four files must be part of a scoped invocation (has --changed or is followed by a
# named path), never bare.
test_issue104_ac2_bare_runs_are_scoped() {
  local bad
  bad=$(grep -n -E '\bnpm (run )?test\b' "$FD_104" "$CR_104" "$TR_104" "$SK_104" 2>/dev/null)
  assert_eq "$bad" "" "AC2: no bare 'npm test'/'npm run test' left in the four files" || return 1

  local vitest_lines
  vitest_lines=$(grep -n -E '\bvitest run\b' "$FD_104" "$CR_104" "$TR_104" "$SK_104" 2>/dev/null)
  if [ -n "$vitest_lines" ]; then
    local unscoped
    unscoped=$(printf '%s\n' "$vitest_lines" | grep -v -- '--changed')
    assert_eq "$unscoped" "" "AC2: every 'vitest run' mention must carry --changed (scoped)" || return 1
  fi
}

# test_issue104_dev_step6_names_locked_files — step 6 must point at the TESTS WRITTEN list,
# not order a suite-wide run.
test_issue104_dev_step6_names_locked_files() {
  local line
  line=$(grep -n "Implement against the locked tests" "$FD_104")
  printf '%s' "$line" | grep -q "locked test files listed in the \`TESTS WRITTEN\` comment" \
    || { fail "fullstack-developer.md step 6 must run the locked test files listed in TESTS WRITTEN"; return 1; }
}

# test_issue104_dev_step7_keeps_e2e_and_gates — the "full suites CI runs" framing is gone,
# but the e2e-by-path and regression/parity/golden-file requirements (AC3) survive verbatim.
test_issue104_dev_step7_keeps_e2e_and_gates() {
  local step7
  step7=$(grep -n "^7\. Run the tests for what changed" "$FD_104")
  assert_ne "$step7" "" "fullstack-developer.md step 7 must open with a scoped-run instruction" || return 1
  printf '%s' "$step7" | grep -q -- '--changed <merge-base>' \
    || { fail "step 7 must name --changed <merge-base>"; return 1; }
  printf '%s' "$step7" | grep -q 'E2E specs (not executed)' \
    || { fail "AC3: step 7 must still require the listed E2E specs"; return 1; }
  printf '%s' "$step7" | grep -qi 'regression/parity/golden-file' \
    || { fail "AC3: step 7 must still require regression/parity/golden-file gates"; return 1; }
}

# test_issue104_fastlane_scoped_green — Fast-lane mode step 2 no longer says "suite green".
test_issue104_fastlane_scoped_green() {
  local line
  line=$(grep -n "fullstack-bug-fixing. skill's process end to end" "$FD_104")
  printf '%s' "$line" | grep -q "scoped tests (reproduction test plus anything touching the same files) green" \
    || { fail "fullstack-developer.md Fast-lane step 2 must require scoped tests green, not suite green"; return 1; }
}

# test_issue104_code_reviewer_scoped_and_claim_removed — the scoped-run wording is present,
# and the "only post-implementation stage that runs the whole suite" justification is gone.
test_issue104_code_reviewer_scoped_and_claim_removed() {
  grep -q -- '--changed <merge-base>' "$CR_104" \
    || { fail "code-reviewer.md must name --changed <merge-base>"; return 1; }
  grep -qi "only post-implementation stage that runs the whole suite" "$CR_104" \
    && { fail "code-reviewer.md must drop the 'only post-implementation stage runs the whole suite' claim"; return 1; }
  return 0
}

# test_issue104_test_reviewer_scoped_entry_condition — the entry-condition line is scoped.
test_issue104_test_reviewer_scoped_entry_condition() {
  local line
  line=$(grep -n "all green is the entry condition" "$TR_104")
  assert_ne "$line" "" "test-reviewer.md must still gate on all-green as the entry condition" || return 1
  printf '%s' "$line" | grep -q -- '--changed <merge-base>' \
    || { fail "test-reviewer.md entry-condition line must name --changed <merge-base>"; return 1; }
}

# test_issue104_skill_phase4_scoped — Phase 4's "run the full suite" became a scoped run.
test_issue104_skill_phase4_scoped() {
  local line
  line=$(grep -n "Watch it pass" "$SK_104")
  assert_ne "$line" "" "SKILL.md Phase 4 must still say watch it pass" || return 1
  printf '%s' "$line" | grep -q -- '--changed <merge-base>' \
    || { fail "SKILL.md Phase 4 must name --changed <merge-base> instead of the full suite"; return 1; }
}

# test_issue104_orchestrator_dispatch_untouched — AC: agents/orchestrator.md:47 (the
# fast-lane dispatch prompt) is explicitly out of scope and must be unchanged relative to
# origin/main. Best-effort: only runs when origin/main is resolvable (e.g. not in a shallow
# CI checkout with no origin remote); otherwise skipped rather than failed.
test_issue104_orchestrator_dispatch_untouched() {
  if ! git -C "$ROOT_104" rev-parse --verify origin/main >/dev/null 2>&1; then
    return 0
  fi
  local diff
  diff=$(git -C "$ROOT_104" diff origin/main -- agents/orchestrator.md 2>/dev/null)
  assert_eq "$diff" "" "AC4: agents/orchestrator.md must be unchanged relative to origin/main" || return 1
}

run_test test_issue104_ac1_no_unscoped_phrasing
run_test test_issue104_ac2_bare_runs_are_scoped
run_test test_issue104_dev_step6_names_locked_files
run_test test_issue104_dev_step7_keeps_e2e_and_gates
run_test test_issue104_fastlane_scoped_green
run_test test_issue104_code_reviewer_scoped_and_claim_removed
run_test test_issue104_test_reviewer_scoped_entry_condition
run_test test_issue104_skill_phase4_scoped
run_test test_issue104_orchestrator_dispatch_untouched
