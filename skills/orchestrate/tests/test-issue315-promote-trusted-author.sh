# Issue #315 fix cycle — only OWNER/MEMBER/COLLABORATOR deferral NOTEs trigger promotion (public repos: outsiders must not get agent-go).
# Reuses the pc_* harness defined by the earlier-sourced promote-deferred-child test file.
pc_set_assoc() { jq --argjson n "$1" --arg a "$2" 'map(if .number==$n then .comments[0].authorAssociation=$a else . end)' "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"; }

test_pc_outsider_note_does_not_promote() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10; pc_set_assoc 21 NONE
  pc_control
  si_tick
  local l lc; l=$(si_labels 21); lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: trusted-author child promoted" || return 1
  assert_eq "$l" "agent-proposed" "outsider NOTE: not promoted" || return 1
}
test_pc_collaborator_note_promotes() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10; pc_set_assoc 21 COLLABORATOR
  si_tick
  local l; l=$(si_labels 21); si_cleanup
  assert_eq "$l" "agent-go" "collaborator NOTE promotes" || return 1
}
run_test test_pc_outsider_note_does_not_promote
run_test test_pc_collaborator_note_promotes
