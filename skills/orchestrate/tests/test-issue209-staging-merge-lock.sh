# Issue #209 — staging merges touching a locked test are routed to test-writer, not the developer.
# Pins the three agent-prompt rules so they can't silently regress.

HERE_209=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AGENTS_209="$HERE_209/../../../agents"

test_209_orchestrator_routes_locked_test_merge_to_test_writer() {
  local f="$AGENTS_209/orchestrator.md" hit
  hit=$(grep -c 'Staging merge touching a locked test' "$f")
  assert_ne "$hit" "0" "209: orchestrator.md must carry the staging-merge route" || return 1
  hit=$(grep -c 'merge-base origin/<branch> origin/staging' "$f")
  assert_ne "$hit" "0" "209: orchestrator.md must detect locked-file changes via merge-base diff" || return 1
  hit=$(grep -c 'does not count against the 2-cycle caps' "$f")
  assert_ne "$hit" "0" "209: orchestrator.md must state the merge round is not a fix cycle" || return 1
}

test_209_delivery_lead_has_matching_rule() {
  local hit
  hit=$(grep -c 'refused staging merge' "$AGENTS_209/delivery-lead.md")
  assert_ne "$hit" "0" "209: delivery-lead.md must handle a developer BLOCKED on a refused staging merge" || return 1
}

test_209_developer_blocks_as_merge_conflict() {
  local hit
  hit=$(grep -c 'merge_conflict — merge touches locked test' "$AGENTS_209/fullstack-developer.md")
  assert_ne "$hit" "0" "209: fullstack-developer.md must post merge_conflict (not needs_jp) when the hook refuses a merge" || return 1
}

run_test test_209_orchestrator_routes_locked_test_merge_to_test_writer
run_test test_209_delivery_lead_has_matching_rule
run_test test_209_developer_blocks_as_merge_conflict
