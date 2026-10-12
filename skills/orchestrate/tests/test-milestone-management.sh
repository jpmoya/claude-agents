# Issue #188 — PM and other filing agents assign milestones. Prose contract pinned by literal greps
# on tracked files only (no gh, no network).
HERE_188=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_188=$(cd "$HERE_188/../../.." && pwd)
PM_188="$ROOT_188/agents/product-manager.md"

# ms188_has <file> <literal> — self-contained (run-tests.sh sources files alphabetically).
ms188_has() {
  grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }
}

# AC3: SA slice creation carries --milestone derived from the parent.
test_ms188_ac3_sa_slice_milestone_from_parent() {
  local snip
  snip=$(grep -F -A12 'gh issue create --title "<parent-title>: <slice-name>"' "$ROOT_188/agents/solutions-architect.md")
  assert_contains "$snip" '--milestone' "SA slice snippet carries --milestone" || return 1
  assert_contains "$(cat "$ROOT_188/agents/solutions-architect.md")" 'gh issue view <parent> --json milestone' "SA derives milestone from parent" || return 1
}

# AC3: adjudicator fix-ticket snippet carries --milestone "Pipeline fixes".
test_ms188_ac3_adjudicator_pipeline_fixes_milestone() {
  local f="$ROOT_188/agents/pipeline-adjudicator.md"
  grep -qF -- '--milestone "Pipeline fixes"' "$f" || { fail "pipeline-adjudicator.md: missing [--milestone \"Pipeline fixes\"]"; return 1; }
  # the milestone flag sits on the `gh issue create` instruction line, not just anywhere
  local l; l=$(grep -F 'gh issue create --repo jpmoya/claude-agents' "$f" | head -1)
  assert_contains "$l" '--milestone "Pipeline fixes"' "adjudicator gh issue create line" || return 1
}

# AC4: title rule states the 60-char limit and the charset, and the charset equals validate.js MILESTONE.
test_ms188_ac4_title_rule_limit_and_charset() {
  local cs='[\w .,()&/+:-]'
  grep -qF -- "$cs" "$PM_188" || { fail "product-manager.md: missing charset [$cs]"; return 1; }
  grep -qE -- '(≤|<=|at most|max(imum)?)[ ]*60[ ]*(char|chars|characters)|60[- ]char' "$PM_188" || { fail "product-manager.md: 60-char limit not stated"; return 1; }
  grep -qF -- "/^$cs{1,60}\$/" "$ROOT_188/status-page/src/validate.js" || { fail "validate.js MILESTONE no longer matches the charset pinned by the PM rule"; return 1; }
}

# AC1 (extra): each Milestones-rule element the ticket lists is present.
test_ms188_ac1_pm_rule_elements() {
  local s
  for s in '--milestone' 'gh api repos/<o>/<r>/milestones' 'gh release list'; do
    ms188_has "$PM_188" "$s" || return 1
  done
}

# AC5: #188 did not touch deployer.md. Scoped to #188's own squash commit (df5be07), not to the
# file's current content, so later legitimate deployer edits (#156, #158, #171) stay green.
test_ms188_ac5_deployer_byte_unchanged() {
  local c=df5be07ae942dc6941b557bc9e335c40d9e27e2f
  # Shallow/partial clone without that commit: nothing to inspect.
  git -C "$ROOT_188" cat-file -e "$c^{commit}" 2>/dev/null || return 0
  local touched; touched=$(git -C "$ROOT_188" diff-tree --no-commit-id --name-only -r "$c" -- agents/deployer.md)
  assert_eq "$touched" "" "#188 commit $c must not touch agents/deployer.md" || return 1
}

# Docs (ticket "Docs" section): CLAUDE.md and README cite planning milestones and the child tickets.
test_ms188_docs_claude_md_planning_vs_shipped() {
  local sec s
  sec=$(awk '/^[*][*]Exception — releases/{on=1} on{print} on&&/^## /{exit}' "$ROOT_188/CLAUDE.md")
  for s in 'write-once' 'never hand-edit' 'planning milestone' 'PM-owned'; do
    assert_contains "$sec" "$s" "CLAUDE.md releases paragraph" || return 1
  done
}
test_ms188_docs_readme_cites_children() {
  local s
  for s in 'Benjis-Plants/scheduler#1321' 'Benjis-Plants/benjis-quoting-tool#661' 'Benjis-Plants/scheduler#653' 'issue #37'; do
    ms188_has "$ROOT_188/README.md" "$s" || return 1
  done
}

echo "-- milestone management (issue #188)"
run_test test_ms188_ac3_sa_slice_milestone_from_parent
run_test test_ms188_ac3_adjudicator_pipeline_fixes_milestone
run_test test_ms188_ac4_title_rule_limit_and_charset
run_test test_ms188_ac1_pm_rule_elements
run_test test_ms188_ac5_deployer_byte_unchanged
run_test test_ms188_docs_claude_md_planning_vs_shipped
run_test test_ms188_docs_readme_cites_children
