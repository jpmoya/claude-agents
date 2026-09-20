# Release tracking (issue #37): agent-side backstop for the staging / vX.Y.Z milestone stamping that
# lives in the app repos (scheduler#653/#655, quoting-tool#234/#235). The definitions are prose, so
# the contract is pinned by literal strings. Grep against tracked files only — no network, no gh, no ssh.

HERE_RM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_RM=$(cd "$HERE_RM/../../.." && pwd)

# rm_has <file> <literal> — fixed-string search; fails with the missing literal named.
rm_has() {
  grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }
}

# rm_section <file> <start-regex> — prints from the first line matching <start-regex> up to (not
# including) the next `## ` heading.
rm_section() {
  awk -v re="$2" '$0 ~ re { on = 1; print; next } on && /^## / { exit } on { print }' "$1"
}

# AC1: the closing-keyword guarantee stays grep-verifiable in the three files that enforce it.
test_rm_ac1_closing_keyword_guard() {
  local row
  rm_has "$ROOT_RM/agents/fullstack-developer.md" 'Closes #N' || return 1
  row=$(grep -F 'code-reviewer (+ test-reviewer narrow)' "$ROOT_RM/agents/orchestrator.md" | grep -F 'closingIssuesReferences')
  assert_ne "$row" "" "orchestrator code-reviewer pre-dispatch row lacks closingIssuesReferences" || return 1
  rm_has "$ROOT_RM/agents/code-reviewer.md" 'no linked issue, that itself is BLOCKED' || return 1
}

# AC2: deployer milestone check lives in the Staging-model repos section; checklist line is global.
test_rm_ac2_deployer_milestone_check() {
  local sec s
  sec=$(rm_section "$ROOT_RM/agents/deployer.md" '^### Staging-model repos')
  for s in 'select(.title=="staging")' 'never overwrite a version stamp' 'gh pr edit' '--milestone staging'; do
    assert_contains "$sec" "$s" "deployer Staging-model section" || return 1
  done
  rm_has "$ROOT_RM/agents/deployer.md" 'Milestone: <staging stamped | already staging | already vX.Y.Z, left alone | n/a — no staging milestone in this repo>' || return 1
}

# AC3: promotion rule sits in the "Exception — releases" paragraph of CLAUDE.md.
test_rm_ac3_claude_md_promotion_rule() {
  local sec s
  sec=$(rm_section "$ROOT_RM/CLAUDE.md" '^[*][*]Exception — releases')
  assert_ne "$sec" "" "CLAUDE.md: Exception — releases paragraph not found" || return 1
  for s in 'package.json' 'version bump' 'vX.Y.Z' 'stamp-release' 'write-once' 'never hand-edit'; do
    assert_contains "$sec" "$s" "CLAUDE.md releases paragraph" || return 1
  done
}

# AC4: README paragraph, with repo-qualified references (bare #653 would link into this repo).
test_rm_ac4_readme_paragraph() {
  local s
  for s in '**Release tracking (issue #37' '`staging`' 'vX.Y.Z' 'Benjis-Plants/scheduler#653' 'Benjis-Plants/scheduler#655'; do
    rm_has "$ROOT_RM/README.md" "$s" || return 1
  done
}

# AC5: the PM never invents a milestone convention.
test_rm_ac5_pm_no_preassigned_milestone() {
  rm_has "$ROOT_RM/agents/product-manager.md" 'never pre-assign a release milestone' || return 1
}

echo "-- release tracking (issue #37)"
run_test test_rm_ac1_closing_keyword_guard
run_test test_rm_ac2_deployer_milestone_check
run_test test_rm_ac3_claude_md_promotion_rule
run_test test_rm_ac4_readme_paragraph
run_test test_rm_ac5_pm_no_preassigned_milestone
