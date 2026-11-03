# Issue #566 — the staff-feedback lead adopts a goal-less blocker (open ticket, already agent-go, no live goal covers
# it) by adding user-feedback; "that goal's lead owns the others" applies only to tickets another live goal covers.
# Pinned phrases (test-chosen, case-insensitive): "no live goal covers" and "already carries" must appear in the
# brief (goal-lib.sh), agents/delivery-lead.md and SKILL.md; the old unconditional ownership clause must be gone.
# Sources dgf_setup from test-goal-feedback.sh (sorts earlier).

GL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

# gl566_rule_line <text> <pattern>...: "yes" when ONE line of <text> contains every pattern (case-insensitive).
# Ties the rule's conditions together so unrelated mentions elsewhere cannot satisfy the test.
gl566_rule_line() {
  local text=$1; shift
  local lines; lines=$(printf '%s\n' "$text")
  for p in "$@"; do lines=$(printf '%s\n' "$lines" | grep -i -- "$p") || { echo no; return; }; done
  echo yes
}

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
  assert_eq "$(gl566_rule_line "$out" "no live goal covers" "already carries" "agent-go" "user-feedback" "needs_jp")" "yes" "#566: ONE brief line: goal-less blocker, only if already carries agent-go, add user-feedback, never park needs_jp" || rc=1
  dg_teardown; return $rc
}

test_gl566_docs_state_goalless_blocker_rule() {
  local rc=0 f txt
  # AC1: the rule sits in ONE line naming the condition, the label added and the needs_jp ban.
  txt=$(cat "$GL_ROOT/agents/delivery-lead.md")
  assert_eq "$(gl566_rule_line "$txt" "no live goal covers" "already carries" "agent-go" "user-feedback" "needs_jp")" "yes" "#566: delivery-lead.md one line: goal-less blocker, only if already carries agent-go, add user-feedback, never park needs_jp" || rc=1
  # AC2: SKILL.md states the goal-less rule too (no needs_jp requirement there).
  txt=$(cat "$GL_ROOT/skills/orchestrate/SKILL.md")
  assert_eq "$(gl566_rule_line "$txt" "no live goal covers" "already carries" "agent-go" "user-feedback")" "yes" "#566: SKILL.md one line: goal-less blocker, only if already carries agent-go, add user-feedback" || rc=1
  # AC2 removal: unconditional ownership wording is gone (delivery-lead.md:68 and SKILL.md:64).
  assert_not_contains "$(cat "$GL_ROOT/agents/delivery-lead.md")" "the other goal's lead owns the rest" "#566: delivery-lead.md unconditional 'other goal's lead owns the rest' removed" || rc=1
  assert_not_contains "$(cat "$GL_ROOT/skills/orchestrate/SKILL.md")" "other goal's lead owns" "#566: SKILL.md does not imply another goal's lead owns goal-less tickets" || rc=1
  return $rc
}

run_test test_gl566_brief_adopts_goalless_blocker_and_scopes_other_lead_clause
run_test test_gl566_docs_state_goalless_blocker_rule
