# Automatic go for every goal (JP, 2026-11-16): registering a goal records go:true and gives agent-go to its in-scope tickets,
# except staff-feedback (`user-feedback`) tickets, which keep their own approval flow. `deliver.sh approve` backfills a goal that
# was registered before this (go null / false).
#   zag_label_*      a label goal with no requirements ticket still records go:true; its tickets get agent-go at register and at sync
#   zag_feedback_*   a user-feedback ticket in scope is never granted (label goal and milestone goal), and the skip is logged
#   zag_approve_*    approve turns a go-less goal into an approved one, grants its tickets, is idempotent, skips closed/unknown
# Sourced after test-goal-deliver.sh, test-goal-label.sh and test-goal-register-go.sh (alphabetical): reuses their dg_ / glb_ / grg_
# helpers. Hand arithmetic is in the comments. Placeholder repo names only.

ZAG_L="goal: Auto test"

# zag_world — label goal world: a#8 open (grantable), a#9 open + user-feedback (never), b#1 open (grantable)
zag_label_world() {
  glb_label $GLB_A "$ZAG_L"; glb_label $GLB_B "$ZAG_L"
  glb_ticket $GLB_A 8 open "$ZAG_L"
  glb_ticket $GLB_A 9 open "$ZAG_L,user-feedback"
  glb_ticket $GLB_B 1 open "$ZAG_L"
}

# zag_reset_go <registry file> — back to a goal registered before the automatic go: no go / granted / granted_at in the block
zag_reset_go() {
  local f=$1 blk body
  blk=$(dg_block "$f" | jq -c 'del(.go, .granted, .granted_at)')
  body=$(printf 'Goal: reset\n\n```json\n%s\n```\n' "$blk")
  jq --arg b "$body" '.body = $b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

test_zag_label_goal_without_requirements_gets_go_and_labels() {
  glb_setup; local rc=0 blk
  zag_label_world
  dg_run --repos "$GLB_REPOS" --title "Auto test" --now           # no --requirements, no --approve-all
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  blk=$(dg_block "$(dg_reg_files | head -1)")
  assert_eq "$(printf '%s' "$blk" | jq -r .go)" "true" "block.go is true" || rc=1
  # a#8 and b#1 are open + unguarded -> granted; hand count 2 (a#9 is user-feedback)
  assert_eq "$(printf '%s' "$blk" | jq -r '.granted | length')" "2" "two tickets granted" || rc=1
  glb_has_label $GLB_A 8 agent-go || { fail "a#8 gets agent-go"; rc=1; }
  glb_has_label $GLB_B 1 agent-go || { fail "b#1 gets agent-go"; rc=1; }
  glb_teardown; return $rc
}

test_zag_label_goal_sync_grants_later_arrival_not_feedback() {
  glb_setup; local rc=0
  zag_label_world
  dg_run --repos "$GLB_REPOS" --title "Auto test" --now
  glb_ticket $GLB_A 20 open "$ZAG_L"
  glb_ticket $GLB_A 21 open "$ZAG_L,user-feedback"
  glb_cache_of_registered
  glb_sync
  glb_has_label $GLB_A 20 agent-go || { fail "a#20 arrived later and inherits agent-go"; rc=1; }
  glb_has_label $GLB_A 21 agent-go && { fail "a user-feedback arrival must not inherit agent-go"; rc=1; }
  glb_has_label $GLB_A 9 agent-go && { fail "a#9 (user-feedback) still has no agent-go after sync"; rc=1; }
  assert_contains "$(grg_slog)" "repo=$GLB_RA issue=21" "the skip of a#21 is logged" || rc=1
  assert_not_contains "$(jq -r .body "$(dg_reg_files | head -1)")" "$GLB_RA#21" "a#21 is not in the grant list" || rc=1
  glb_teardown; return $rc
}

test_zag_milestone_goal_skips_user_feedback_ticket() {
  grg_world; local rc=0 blk
  grg_ticket $GRG_A 106 open "agent-proposed,user-feedback" 12
  dg_run "$DG_SPEC_MS" --now
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  blk=$(grg_reg_block)
  grg_has $GRG_A 102 agent-go || { fail "positive control: a#102 gets agent-go"; rc=1; }
  grg_has $GRG_A 106 agent-go && { fail "a user-feedback ticket in the milestone must not get agent-go"; rc=1; }
  grg_has $GRG_A 106 agent-proposed || { fail "a#106 keeps agent-proposed (untouched)"; rc=1; }
  assert_eq "$(printf '%s' "$blk" | jq -r --arg a "$GRG_RA#106" '(.granted // []) | index($a) != null')" "false" "a#106 is not in the granted list" || rc=1
  assert_contains "$DG_ERR" "issue=106" "the skip is logged" || rc=1
  glb_teardown; return $rc
}

test_zag_approve_backfills_label_goal() {
  glb_setup; local rc=0 f blk
  zag_label_world
  dg_run --repos "$GLB_REPOS" --title "Auto test" --now
  f=$(dg_reg_files | head -1)
  zag_reset_go "$f"
  glb_strip_label $GLB_A 8 agent-go; glb_strip_label $GLB_B 1 agent-go
  assert_eq "$(dg_block "$f" | jq -r '.go // "null"')" "null" "precondition: go is null" || rc=1
  dg_run approve "$(dg_block "$f" | jq -r .id)"
  assert_eq "$DG_RC" "0" "approve exits 0 (stderr: $DG_ERR)" || rc=1
  blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r .go)" "true" "block.go is true" || rc=1
  printf '%s' "$(printf '%s' "$blk" | jq -r '.granted_at // ""')" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { fail "granted_at is an ISO date"; rc=1; }
  assert_contains "$(jq -r .body "$f")" "Go-granted:" "the registry body carries the Go-granted line" || rc=1
  glb_has_label $GLB_A 8 agent-go || { fail "a#8 gets agent-go from approve"; rc=1; }
  glb_has_label $GLB_B 1 agent-go || { fail "b#1 gets agent-go from approve"; rc=1; }
  glb_has_label $GLB_A 9 agent-go && { fail "the user-feedback ticket is not approved"; rc=1; }
  glb_teardown; return $rc
}

test_zag_approve_backfills_milestone_goal_and_is_idempotent() {
  grg_world; local rc=0 f w1 w2
  dg_run "$DG_SPEC_MS" --now
  f=$(dg_reg_files | head -1)
  zag_reset_go "$f"
  grg_has $GRG_A 102 agent-go && glb_strip_label $GRG_A 102 agent-go
  dg_run approve "$DG_ID_MS"
  assert_eq "$DG_RC" "0" "approve exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_block "$f" | jq -r .go)" "true" "block.go is true" || rc=1
  grg_has $GRG_A 102 agent-go || { fail "a#102 gets agent-go from approve"; rc=1; }
  w1=$(dg_writes)
  dg_run approve "$DG_ID_MS"
  assert_eq "$DG_RC" "0" "second approve exits 0" || rc=1
  assert_contains "$DG_OUT" "already approved" "second approve says so" || rc=1
  assert_eq "$(dg_writes)" "$w1" "second approve writes nothing" || rc=1
  glb_teardown; return $rc
}

test_zag_approve_unknown_goal_fails() {
  grg_world; local rc=0
  dg_run approve example-owner_project-a-ms-999
  assert_ne "$DG_RC" "0" "approve of an unknown goal exits non-zero" || rc=1
  glb_teardown; return $rc
}

for t in test_zag_label_goal_without_requirements_gets_go_and_labels \
         test_zag_label_goal_sync_grants_later_arrival_not_feedback \
         test_zag_milestone_goal_skips_user_feedback_ticket \
         test_zag_approve_backfills_label_goal \
         test_zag_approve_backfills_milestone_goal_and_is_idempotent \
         test_zag_approve_unknown_goal_fails; do
  run_test "$t"
done
