# Issue #831 — one issue is one PR: "deployed" ends a ticket, so a ticket planned as several PRs stops after the first.
# Text-pins on fullstack-developer.md and product-manager.md. Prefix i831_ (all test files share one shell).

I831_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
I831_DEV="$I831_ROOT/agents/fullstack-developer.md"
I831_PM="$I831_ROOT/agents/product-manager.md"

i831_dev_line() { grep -F -- '- **One PR per issue, one issue per PR.**' "$I831_DEV" | head -1; }
i831_pm_line() { grep -F -- '- **Keep issues small enough for a single, reviewable PR.**' "$I831_PM" | head -1; }

test_i831_ac1_developer_rule_has_no_exception() {
  local l; l=$(i831_dev_line)
  assert_ne "$l" "" "AC1: the one-PR guardrail still exists" || return 1
  assert_contains "$l" "Never split one issue across multiple PRs, whatever the ticket's landing order says" "AC1: landing order grants no exception" || return 1
  assert_not_contains "$l" 'unless' "AC1: no exception clause" || return 1
}

test_i831_ac1_developer_blocks_instead_of_second_pr() {
  local l; l=$(i831_dev_line)
  assert_contains "$l" 'do not open a second one' "AC1: no second PR" || return 1
  assert_contains "$l" '`**[fullstack-developer] BLOCKED**`' "AC1: posts BLOCKED" || return 1
  assert_contains "$l" '`Blocked on: other — ' "AC1: technical block class, answered without JP" || return 1
  assert_contains "$l" 'split into child issues' "AC1: asks for a split into child issues" || return 1
}

test_i831_release_note_rule_does_not_imply_multi_pr_tickets() {
  local l; l=$(grep -F -- '- **One feature = one `yes`.**' "$I831_DEV" | head -1)
  assert_contains "$l" 'several tickets (one PR each)' "a feature spans tickets, each with one PR" || return 1
  assert_not_contains "$l" 'several PRs or tickets' "old wording gone" || return 1
}

test_i831_ac2_pm_never_plans_several_prs_on_one_ticket() {
  local l; l=$(i831_pm_line)
  assert_ne "$l" "" "AC2: the PM sizing rule still exists" || return 1
  assert_contains "$l" 'Never plan several PRs on one ticket' "AC2: stated outright" || return 1
  assert_contains "$l" '"PR A/B/C"' "AC2: names the PR A/B/C shape" || return 1
  assert_contains "$l" '"Part of #N, never Closes"' "AC2: names the Part-of shape" || return 1
}

test_i831_ac2_pm_files_sequential_child_issues() {
  local l; l=$(i831_pm_line)
  assert_contains "$l" 'Work needing several PRs is filed as sequential child issues' "AC2: child issues" || return 1
  assert_contains "$l" 'the first ticket covers the first slice only' "AC2: the first ticket keeps one PR of scope" || return 1
  assert_contains "$l" 'after the duplicate check' "AC2: duplicate check first" || return 1
  assert_contains "$l" '`Parent: owner/repo#N`' "AC2: Parent line" || return 1
  assert_contains "$l" 'landing order' "AC2: landing order" || return 1
  assert_contains "$l" '`Depends on #M for starting work`' "AC2: order is expressed as a gate on the previous slice" || return 1
}

echo "-- one issue, one PR (issue #831)"
run_test test_i831_ac1_developer_rule_has_no_exception
run_test test_i831_ac1_developer_blocks_instead_of_second_pr
run_test test_i831_release_note_rule_does_not_imply_multi_pr_tickets
run_test test_i831_ac2_pm_never_plans_several_prs_on_one_ticket
run_test test_i831_ac2_pm_files_sequential_child_issues
