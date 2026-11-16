# Tests for claude-agents#726 — an IMPLEMENTED / PASS gate on a closed-unmerged PR (superseded: its change shipped inside
# another merged PR) must be resumable by a [delivery-lead] DECISION that names the merged integration-branch PR, through
# the deployer in post-merge mode. Without a decision, or with a decision naming a PR that is not merged into the
# integration branch, it stays the #92 Structural stop. The orchestrator is a prompt, so the routing is pinned on its text
# (same approach as test-merged-pr-structural-hold.sh); the one executable piece, the shared Resolves: helper, is run for real.
# Placeholder repos only. Prefixed sp_ / SP_.

HERE_SP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SP=$(cd "$HERE_SP/../../.." && pwd)
ORCH_SP="$ROOT_SP/agents/orchestrator.md"
. "$ROOT_SP/hooks/pipeline-markers.sh"

# sp_row: the superseded-PR routing row (the Gate-marker row that mentions `mergedAt` null).
sp_row() { grep -F '| Gate marker `[fullstack-developer] IMPLEMENTED`' "$ORCH_SP" | grep -F 'mergedAt' | head -1; }

test_sp_row_routes_decision_to_deployer_post_merge() {
  local row; row=$(sp_row)
  assert_ne "$row" "" "#726: a routing row for a closed-unmerged PR + decision exists" || return 1
  assert_contains "$row" "IMPLEMENTED" "#726: gate marker IMPLEMENTED covered" || return 1
  assert_contains "$row" "PASS" "#726: gate marker code-reviewer PASS covered" || return 1
  assert_contains "$row" "CLOSED" "#726: keyed on the PR being CLOSED" || return 1
  assert_contains "$row" "[delivery-lead] DECISION" "#726: a delegated decision resumes it" || return 1
  assert_contains "$row" "JP CONFIRMED" "#726: JP CONFIRMED spelling accepted" || return 1
  assert_contains "$row" "decision_resolves_id" "#726: Resolves: judged by the shared helper" || return 1
  assert_contains "$row" "that gate comment" "#726: Resolves: must be the gate comment" || return 1
  assert_contains "$row" "names exactly one other PR" "#726: the decision names the merged PR #M" || return 1
  assert_contains "$row" "MERGED" "#726: #M must be MERGED" || return 1
  assert_contains "$row" "baseRefName" "#726: #M must be on the integration branch" || return 1
  assert_contains "$row" "integration branch" "#726: base is the integration branch" || return 1
  assert_contains "$row" "deployer" "#726: dispatches the deployer" || return 1
  assert_contains "$row" "PR #M is already merged — post-merge checks only" "#726: post-merge mode prompt on #M" || return 1
}

test_sp_row_failure_stays_structural_with_fail_row() {
  local row; row=$(sp_row)
  assert_contains "$row" "Structural stop" "#726: a decision naming an unmerged / wrong-base PR stays a Structural stop" || return 1
  assert_contains "$row" '"stage":"delegated-decision"' "#726: logs a delegated-decision row" || return 1
  assert_contains "$row" "fail row" "#726: fail row names why" || return 1
  assert_contains "$row" "reason" "#726: fail row carries a reason" || return 1
  assert_contains "$row" "the \`structural\` fail row (so the supervisor holds the ticket" "#726: structural row logged too so the supervisor holds, not restart-loops" || return 1
}

# The code-reviewer validation row must not claim a closed-unmerged PR with a qualifying decision (it would fail the
# 'PR open' check and become a Structural stop before the superseded-PR row is reached).
test_sp_code_reviewer_row_exempts_the_superseded_case() {
  local row
  row=$(grep -F '| code-reviewer (+ test-reviewer narrow) |' "$ORCH_SP" | head -1)
  assert_contains "$row" "closed-unmerged PR with a qualifying" "#726: reviewer row exempts the decision case" || return 1
  assert_contains "$row" "no reviewer is dispatched on the closed PR" "#726: no reviewer on the closed PR" || return 1
}

test_sp_row_no_reviewer_no_ancestry() {
  local row; row=$(sp_row)
  assert_contains "$row" "no reviewer on the closed PR" "#726: no reviewer dispatched on the closed PR" || return 1
  assert_contains "$row" "no ancestry check" "#726: no ancestry check on the closed head" || return 1
  assert_contains "$row" "squash" "#726: squash merges have no ancestry" || return 1
}

test_sp_merged_pr_row_points_to_the_case_and_keeps_structural_default() {
  local row
  row=$(grep -F 'post-merge checks only' "$ORCH_SP" | head -1)
  assert_contains "$row" "A closed, unmerged PR stays a Structural stop unless a decision under the Look-through rule names the merged PR that carries it" \
    "#726: :81 closing sentence points at the decision case" || return 1
  assert_contains "$row" "closingIssuesReferences" "#726: #92 pins stay intact" || return 1
}

test_sp_look_through_rule_resumes_four_stops() {
  local para
  para=$(grep -F '**Look-through rule.**' "$ORCH_SP")
  assert_contains "$para" "resumes exactly four stops" "#726: look-through rule counts the fourth resumable stop" || return 1
  assert_not_contains "$para" "exactly three stops" "#726: old three-stop wording gone" || return 1
  assert_contains "$para" "closed-unmerged PR" "#726: the fourth stop is the closed-unmerged-PR gate" || return 1
}

test_sp_structural_stop_names_only_an_accepted_path() {
  local line
  line=$(grep -F '**Structural**' "$ORCH_SP" | head -1)
  assert_contains "$line" "Closed-unmerged PR behind an \`IMPLEMENTED\` / \`PASS\` gate" "#726: structural bullet covers this stop" || return 1
  assert_contains "$line" "naming the merged integration-branch PR" "#726: next action is the decision naming the merged PR" || return 1
  assert_contains "$line" "never an ask to JP" "#726: not a JP ask" || return 1
  assert_contains "$line" "never a decision on any other comment" "#726: no decision on a stop the rules do not resume" || return 1
}

test_sp_validation_table_has_the_resume_check() {
  local row
  row=$(grep -F '| deployer (post-merge mode on a superseded PR' "$ORCH_SP" | head -1)
  assert_ne "$row" "" "#726: pre-dispatch validation row exists" || return 1
  assert_contains "$row" "mergedAt" "#726: validates the closed PR is unmerged" || return 1
  assert_contains "$row" "decision_resolves_id" "#726: validates the Resolves: pointer" || return 1
  assert_contains "$row" "compared as numbers" "#726: orders by comment id" || return 1
}

# The decision's Resolves: line must point at the IMPLEMENTED comment, and the shared helper must read it (real code).
test_sp_decision_resolves_the_implemented_comment() {
  local url="https://github.com/owner/project-a/issues/2419#issuecomment-6895000001" body out
  body=$'**[delivery-lead] DECISION**\n\nPR #2420 was closed as superseded; its change shipped in merged PR #2607 (staging). Run the deployer post-merge on #2607.\n\nResolves: '"$url"
  out=$(decision_resolves_id "$body" 2>/dev/null) || { fail "#726: helper rejected a well-formed decision"; return 1; }
  assert_eq "$out" "6895000001" "#726: helper reads the IMPLEMENTED comment id" || return 1
}

run_test test_sp_row_routes_decision_to_deployer_post_merge
run_test test_sp_row_failure_stays_structural_with_fail_row
run_test test_sp_code_reviewer_row_exempts_the_superseded_case
run_test test_sp_row_no_reviewer_no_ancestry
run_test test_sp_merged_pr_row_points_to_the_case_and_keeps_structural_default
run_test test_sp_look_through_rule_resumes_four_stops
run_test test_sp_structural_stop_names_only_an_accepted_path
run_test test_sp_validation_table_has_the_resume_check
run_test test_sp_decision_resolves_the_implemented_comment
