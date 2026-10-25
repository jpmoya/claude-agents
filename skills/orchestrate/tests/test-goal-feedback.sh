# #472 — standing staff-feedback goal `owner/repo:feedback`: a delivery lead bound to the repo's open user-feedback
# tickets that sit in no milestone. Reuses the dg_* sandbox of test-goal-deliver.sh (sourced earlier, alphabetical).
# Hand arithmetic: project-a gets feedback tickets 301 (open, no milestone), 302 (closed, no milestone),
# 303 (open, in milestone 12 -> out of scope), 304 (open, no milestone, no user-feedback label -> out of scope).
# Scope = {301, 302}; 1 closed of 2.

DGF_SPEC="example-owner/project-a:feedback"
DGF_ID="example-owner_project-a-fb-feedback"

dgf_label() {  # dgf_label <n> <label>
  local f="$DG_ST/issues/example-owner_project-a/$1.json"
  jq -c --arg l "$2" '.labels += [{name:$l}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

dgf_setup() {
  dg_setup
  local a=example-owner_project-a
  dg_issue $a 301 open; dg_issue $a 302 closed; dg_issue $a 303 open 12; dg_issue $a 304 open
  dgf_label 301 user-feedback; dgf_label 302 user-feedback; dgf_label 303 user-feedback
}

test_dgf_parse_and_id() {
  dgf_setup
  local rc=0
  dg_lib "goal_parse $DGF_SPEC; goal_id $DGF_SPEC"
  assert_eq "$DG_RC" "0" "parse exits 0 ($DG_ERR)" || rc=1
  assert_contains "$DG_OUT" "$(printf 'example-owner/project-a\tfb\tfeedback')" "kind fb" || rc=1
  assert_contains "$DG_OUT" "$DGF_ID" "goal id" || rc=1
  dg_teardown; return $rc
}

test_dgf_scope_is_open_and_closed_feedback_outside_milestones() {
  dgf_setup
  local rc=0
  dg_lib "_goal_scope_rows $DGF_SPEC"
  assert_eq "$(printf '%s' "$DG_OUT" | sort)" "$(printf 'example-owner/project-a#301\topen\nexample-owner/project-a#302\tclosed')" "scope rows" || rc=1
  dg_teardown; return $rc
}

test_dgf_register_grants_no_agent_go_and_launches_lead() {
  dgf_setup
  local rc=0 f blk
  dg_run "$DGF_SPEC" --now
  assert_eq "$DG_RC" "0" "register exits 0 ($DG_ERR)" || rc=1
  f=$(dg_reg_file_for "$DGF_ID"); assert_ne "$f" "" "registry block carries the id" || rc=1
  blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r '.spec')" "$DGF_SPEC" "spec recorded" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r '.go // false')" "false" "no go recorded" || rc=1
  assert_eq "$(grep -c 'agent-go' "$DG_BIN/writes.log")" "0" "no agent-go label write" || rc=1
  assert_contains "$DG_ERR" "no go granted" "operator is told no go was granted" || rc=1
  dg_wait_claude 1 || { fail 'lead was never launched'; rc=1; }
  dg_teardown; return $rc
}

test_dgf_register_refused_when_no_feedback_ticket_in_scope() {
  dg_setup
  local rc=0
  dg_run "$DGF_SPEC"
  assert_ne "$DG_RC" "0" "empty scope refused" || rc=1
  assert_contains "$DG_ERR" "empty scope" "reason" || rc=1
  dg_teardown; return $rc
}

test_dgf_brief_states_the_job_and_the_limits() {
  dgf_setup
  local rc=0 out
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
  dg_lib "goal_brief $DGF_ID"
  out=$DG_OUT
  assert_eq "$DG_RC" "0" "brief exits 0 ($DG_ERR)" || rc=1
  assert_contains "$out" "TECHNICAL blocks" "job" || rc=1
  assert_contains "$out" "Never add agent-go" "limit" || rc=1
  assert_contains "$out" "project-a#301" "open feedback ticket in scope" || rc=1
  assert_not_contains "$out" "project-a#303" "milestoned feedback ticket out of scope" || rc=1
  assert_not_contains "$out" "project-a#304" "unlabelled ticket out of scope" || rc=1
  dg_teardown; return $rc
}

test_dgf_overlap_with_milestone_goal_on_other_tickets_accepted() {
  dgf_setup
  local rc=0
  DG_GOAL_ID=$DG_ID_MS; dg_goal 501 "$DG_SPEC_MS" host-a active
  dg_run "$DGF_SPEC"
  assert_eq "$DG_RC" "0" "feedback goal beside a milestone goal (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

test_dgf_delivered_when_every_feedback_ticket_is_closed() {
  dgf_setup
  local rc=0
  dg_set_state example-owner_project-a 301 closed
  dg_lib "goal_eval $DGF_ID $DGF_SPEC; echo \$GE_TOTAL \$GE_DELIVERED"
  assert_eq "$DG_OUT" "2 2" "all scope tickets closed = goal complete" || rc=1
  dg_teardown; return $rc
}

test_dgf_docs_name_the_goal() {
  local root; root=$(cd "$DG_SKILL/../.." && pwd)
  assert_contains "$(cat "$root/agents/delivery-lead.md")" "owner/repo:feedback" "delivery-lead.md" || return 1
  assert_contains "$(cat "$DG_SKILL/SKILL.md")" "owner/repo:feedback" "SKILL.md" || return 1
  assert_contains "$(cat "$root/README.md")" "owner/repo:feedback" "README.md" || return 1
}

for t in test_dgf_parse_and_id test_dgf_scope_is_open_and_closed_feedback_outside_milestones \
         test_dgf_register_grants_no_agent_go_and_launches_lead test_dgf_register_refused_when_no_feedback_ticket_in_scope \
         test_dgf_brief_states_the_job_and_the_limits test_dgf_overlap_with_milestone_goal_on_other_tickets_accepted \
         test_dgf_delivered_when_every_feedback_ticket_is_closed test_dgf_docs_name_the_goal; do
  run_test "$t"
done
