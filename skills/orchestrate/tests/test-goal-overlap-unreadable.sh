# #193 fix cycle — the overlap guard must fail closed on a live registry goal it cannot read.
# Regression: an unreadable goal's empty `spec` field collapsed under IFS=$'\t' read, shifting the state
# into the wrong variable, so the guard silently `continue`d and an overlapping goal registered.
# Reuses the dg_ sandbox helpers from the goal-deliver suite (run-tests.sh sources it first, alphabetical).

# dg_raw_registry_issue <n> <body> — an open delivery-goal registry issue with an arbitrary body
dg_raw_registry_issue() {
  jq -nc --argjson n "$1" --arg body "$2" --arg now "$DG_NOW" \
    '{number:$n, title:"Goal: broken", body:$body, state:"open", labels:[{name:"delivery-goal"}],
      milestone:null, closed_at:null, created_at:$now, updated_at:$now}' > "$DG_ST/issues/$DG_REG/$1.json"
}

dg_check_blind_refused() {  # <label>
  assert_eq "$DG_RC" "1" "$1: second goal must be refused (stderr: $DG_ERR)" || return 1
  assert_contains "$DG_ERR" "refusing to go on blind" "$1: refuses because the live goal is unreadable" || return 1
  assert_eq "$(dg_reg_count)" "1" "$1: no new registry issue (only the broken one)" || return 1
  assert_eq "$(dg_goal_files)" "0" "$1: no goal-* files" || return 1
  assert_eq "$(dg_claude_count)" "0" "$1: nothing launched" || return 1
}

test_dgu_live_goal_without_json_block_blocks_registration() {
  dg_setup
  local rc=0
  dg_raw_registry_issue 900 "Goal: example-owner/project-a:milestone:12"   # no fenced json block
  dg_run "$DG_SPEC_MS"
  dg_check_blind_refused "unparseable block" || rc=1
  dg_teardown; return $rc
}

test_dgu_live_goal_with_empty_spec_field_blocks_registration() {
  dg_setup
  local rc=0
  dg_raw_registry_issue 901 "$(printf 'Goal: x\n\n```json\n%s\n```\n' '{"v":1,"id":"broken-goal","spec":"","host":"host-a"}')"
  dg_run "$DG_SPEC_T7"
  dg_check_blind_refused "empty spec" || rc=1
  dg_teardown; return $rc
}

for t in test_dgu_live_goal_without_json_block_blocks_registration \
         test_dgu_live_goal_with_empty_spec_field_blocks_registration; do
  run_test "$t"
done
