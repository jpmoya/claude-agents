# Issue #566 — the staff-feedback lead adopts a goal-less blocker (open ticket, already agent-go, no live goal covers
# it) by adding user-feedback; "that goal's lead owns the others" applies only to tickets another live goal covers.
# Pinned phrases (test-chosen, case-insensitive): "no live goal covers" and "already carries" must appear in the
# brief (goal-lib.sh), agents/delivery-lead.md and SKILL.md; the old unconditional ownership clause must be gone.
# Sources dgf_setup from test-goal-feedback.sh (sorts earlier).

GL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

test_gl566_brief_adopts_goalless_blocker_and_scopes_other_lead_clause() {
  dgf_setup
  local rc=0 out
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
  dg_lib "goal_brief $DGF_ID"
  out=$DG_OUT
  assert_eq "$DG_RC" "0" "brief exits 0 ($DG_ERR)" || rc=1
  assert_not_contains "$out" "(that goal's lead owns the others)" "#566: unconditional 'that goal's lead owns the others' removed" || rc=1
  assert_contains "$out" "lead owns" "#566: the other-lead clause is kept, for tickets another live goal covers" || rc=1
  assert_contains "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" "no live goal covers" "#566: brief names the goal-less blocker case" || rc=1
  assert_contains "$(printf '%s' "$out" | tr 'A-Z' 'a-z')" "already carries" "#566: brief limits adoption to a blocker already carrying agent-go" || rc=1
  assert_contains "$out" "Never add agent-go" "#566: existing limit kept (no agent-go grants)" || rc=1
  assert_contains "$out" "needs_jp" "#566: brief forbids parking the in-scope ticket needs_jp to ask JP to queue it" || rc=1
  dg_teardown; return $rc
}

test_gl566_docs_state_goalless_blocker_rule() {
  local rc=0 f txt
  for f in agents/delivery-lead.md skills/orchestrate/SKILL.md; do
    txt=$(tr 'A-Z' 'a-z' < "$GL_ROOT/$f")
    assert_contains "$txt" "no live goal covers" "#566: $f names the goal-less blocker case" || rc=1
    assert_contains "$txt" "already carries" "#566: $f limits adoption to a blocker already carrying agent-go" || rc=1
  done
  assert_contains "$(cat "$GL_ROOT/agents/delivery-lead.md")" "needs_jp" "#566: delivery-lead.md says never to park needs_jp to ask JP to queue it" || rc=1
  return $rc
}

run_test test_gl566_brief_adopts_goalless_blocker_and_scopes_other_lead_clause
run_test test_gl566_docs_state_goalless_blocker_rule
