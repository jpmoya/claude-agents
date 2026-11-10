# #632 AC6–AC9 (+ the AC13 brief) — goals and direct-route repos. Sourced after test-goal-deliver.sh / test-goal-label.sh
# (alphabetical, like the other test-goal-z-*.sh files) because it reuses their dg_* / glb_* sandbox: the stateful REST
# fake gh, registry, checkouts and config.local.sh. Prefix dr_ / DR_. jpmoya/claude-agents is the real constant under
# test; every other repo name is a placeholder (public repo). Expected values are hand arithmetic from the ticket.
#   AC6  goal_launch for a goal whose repo is direct-route returns without launching and logs "[goal] … direct-route … skipped";
#        a cross-repo goal spanning claude-agents + an app repo launches its lead from the app repo (goal #404 keeps working)
#   AC7  deliver.sh refuses the three spec forms on jpmoya/claude-agents before any write; a --repos list drops it with a warning,
#        and dies when nothing is left
#   AC8  goal_eval leaves direct-route rows out of every count and lists them in GE_DIRECT
#   AC9  goal_sync grants no agent-go to a direct-route ticket; the app-repo ticket of the same goal is still granted
#   AC13 the generated brief lists direct-route tickets apart under "Direct route — needs the interactive session"

DR_CA=jpmoya_claude-agents
DR_RCA=jpmoya/claude-agents
DR_REFUSAL="is a direct-route repo: its changes are made by the interactive session with subagents, never by a goal (see CLAUDE.md)"

dr_setup() { glb_setup; mkdir -p "$DG_ST/issues/$DR_CA"; }

# dr_goal_json <id> <registry n> <repos csv> [spec] -> a goal JSON as _goal_find returns it (label goal unless a spec is given)
dr_goal_json() {
  local id=$1 n=$2 repos=$3 spec=${4:-}
  if [ -n "$spec" ]; then
    jq -nc --arg id "$id" --argjson n "$n" --arg spec "$spec" '{id:$id, issue:$n, spec:$spec, host:"host-a", st:"active", instructions:"",
      block:{v:1,id:$id,spec:$spec,host:"host-a",go:true,granted:[]}}'
  else
    jq -nc --arg id "$id" --argjson n "$n" --arg r "$repos" '{id:$id, issue:$n, spec:"label:goal: DR", host:"host-a", st:"active", instructions:"",
      block:{v:2,id:$id,title:"DR",label:"goal: DR",repos:($r|split(",")),spec:"label:goal: DR",host:"host-a",go:true,granted:[]}}'
  fi
}

# dr_lib <snippet> — dg_lib with slog recorded in $DG_HOME/slog.txt (goal-lib's skips log through it)
dr_lib() { dg_lib 'slog(){ printf "%s\n" "$*" >> "$HOME/slog.txt"; }; report_status_async(){ :; }; '"$1"; }
dr_slog() { cat "$DG_HOME/slog.txt" 2>/dev/null; }

# ------------------------------------------------------------------ AC6 goal_launch ----------------------------
test_dr_ac6_goal_launch_skips_a_direct_route_goal() {
  dr_setup
  local rc=0 g
  # a legacy single-ticket goal on the repo, and a label goal whose only repo is the repo
  for g in "$(dr_goal_json dr-t 900 "" "$DR_RCA#627")" "$(dr_goal_json dr-l 901 "$DR_RCA")"; do
    : > "$DG_HOME/slog.txt"
    printf '%s' "$g" > "$DG_HOME/goal.json"
    dr_lib 'goal_launch "$(jq -r .id "$HOME/goal.json")" "$(cat "$HOME/goal.json")"'
    assert_ne "$DG_RC" "0" "AC6: goal_launch returns non-zero for $(printf '%s' "$g" | jq -r .id) (a launch that did not happen; stderr: $DG_ERR)" || rc=1
    assert_contains "$(dr_slog)" "[goal] $(printf '%s' "$g" | jq -r .id): $DR_RCA is a direct-route repo" "AC6: slog names the goal and the repo" || rc=1
    assert_contains "$(dr_slog)" "skipped" "AC6: slog says skipped" || rc=1
    assert_eq "$(dg_claude_count)" "0" "AC6: no lead (claude) launched" || rc=1
    assert_eq "$(dg_goal_files)" "0" "AC6: no goal-*.pid/.start/.launched-at written" || rc=1
  done
  glb_teardown; return $rc
}

test_dr_ac6_cross_repo_goal_launches_its_lead_from_the_app_repo() {
  dr_setup
  local rc=0 d
  glb_label $GLB_A "goal: DR"; glb_label $DR_CA "goal: DR"
  glb_ticket $GLB_A 8 open "goal: DR"; glb_ticket $DR_CA 627 open "goal: DR"
  glb_v2 902 "goal: DR" "DR" "$DR_RCA,$GLB_RA" active dr-x   # registry goal; claude-agents listed FIRST, as goal #404 has it
  dr_lib '_goal_primary_repo "$(_goal_find dr-x)"'
  assert_eq "$DG_OUT" "$GLB_RA" "AC6: the primary repo skips the direct-route one (stderr: $DG_ERR)" || rc=1
  dr_lib 'goal_launch dr-x'
  assert_eq "$DG_RC" "0" "AC6: the cross-repo goal launches (stderr: $DG_ERR)" || rc=1
  dg_wait_claude 1 || { fail "AC6: no lead launched for the cross-repo goal"; rc=1; }
  d=$(dg_last_claude_dir)
  [ -n "$d" ] && assert_eq "$(cat "$d/cwd" 2>/dev/null)" "$DG_CK_A" "AC6: the lead runs in the app repo checkout" || rc=1
  assert_not_contains "$(dr_slog)" "launch skipped" "AC6: nothing skipped" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC7 deliver.sh -----------------------------
test_dr_ac7_register_refuses_the_three_spec_forms_before_any_write() {
  dr_setup
  local rc=0 spec
  glb_seed7
  for spec in "$DR_RCA:milestone:1" "$DR_RCA:milestones:all" "$DR_RCA#627" "$DR_RCA:feedback"; do
    dg_run "$spec"
    assert_ne "$DG_RC" "0" "AC7: [$spec] is refused" || rc=1
    assert_contains "$DG_ERR" "$DR_RCA $DR_REFUSAL" "AC7: [$spec] refusal message" || rc=1
    assert_not_contains "$DG_ERR" "not in DISPATCH_REPOS" "AC7: [$spec] the direct-route message wins over the DISPATCH_REPOS one" || rc=1
    assert_eq "$(dg_writes)" "0" "AC7: [$spec] no GitHub write (no registry issue, comment or label)" || rc=1
    assert_eq "$(dg_reg_count)" "0" "AC7: [$spec] no registry issue" || rc=1
    assert_eq "$(dg_goal_files)" "0" "AC7: [$spec] no local goal state" || rc=1
  done
  # ...even on a host whose config.local.sh still lists the repo as dispatchable (the entry is dropped at load)
  echo "DISPATCH_REPOS+=(\"$DR_RCA:$DG_CK_A\")" >> "$DG_HOME/.claude/pipeline/config.local.sh"
  dg_run "$DR_RCA#627"
  assert_ne "$DG_RC" "0" "AC7: refused with the repo in DISPATCH_REPOS" || rc=1
  assert_contains "$DG_ERR" "$DR_REFUSAL" "AC7: same message with the repo in DISPATCH_REPOS" || rc=1
  assert_eq "$(dg_writes)" "0" "AC7: still no write" || rc=1
  glb_teardown; return $rc
}

test_dr_ac7_label_goal_drops_the_direct_route_repo_and_dies_when_none_is_left() {
  dr_setup
  local rc=0 f blk
  glb_seed7
  dg_run --repos "$DR_RCA,$GLB_RA" --title "DR mixed" --requirements "$GLB_RA#7"
  assert_eq "$DG_RC" "0" "AC7: a --repos list with a direct-route repo still registers (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_ERR" "direct-route repo $DR_RCA ignored for goal label-goal__DR_mixed" "AC7: the ignored warning names repo and goal id" || rc=1
  f=$(dg_reg_files | head -1); blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -c .repos)" "[\"$GLB_RA\"]" "AC7: repos = the app repo only" || rc=1
  assert_eq "$(glb_label_names $DR_CA | wc -l | tr -d ' ')" "0" "AC7: no goal label created in the direct-route repo" || rc=1
  glb_label_names $GLB_A | grep -qxF -- "goal: DR mixed" || { fail "AC7: goal label created in the app repo"; rc=1; }
  glb_teardown
  dr_setup
  dg_run --repos "$DR_RCA" --title "DR only"
  assert_ne "$DG_RC" "0" "AC7: --repos with only the direct-route repo dies" || rc=1
  assert_contains "$DG_ERR" "$DR_RCA $DR_REFUSAL" "AC7: same refusal message as the spec forms" || rc=1
  assert_eq "$(dg_writes)" "0" "AC7: no write" || rc=1
  assert_eq "$(dg_reg_count)" "0" "AC7: no registry issue" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC8 goal_eval ------------------------------
# Rows (explicit, full shape): claude-agents#609 open | project-a#1 closed completed | project-b#2 open (no marker).
# Hand arithmetic: total 2 (609 excluded), delivered 1 (#1), active 1 (#2), waiting 0, GE_DIRECT = the one 609 ref.
dr_rows3() {
  printf '%s\topen\t-\tjpmoya\t-\t-\t-\n' "$DR_RCA#609"
  printf '%s\tclosed\t-\tjpmoya\t-\tcompleted\t-\n' "$GLB_RA#1"
  printf '%s\topen\t-\tjpmoya\t-\t-\t-\n' "$GLB_RB#2"
}
dr_eval() {  # dr_eval <rows> -> DG_OUT = "rc total delivered active waiting|direct|snap-refs|refs-refs"
  printf '%s' "$1" > "$DG_HOME/rows.txt"
  dr_lib 'goal_eval dr-e "label:goal: DR" "$(cat "$HOME/rows.txt")"; rc=$?
          printf "%s %s %s %s %s|%s|%s|%s" "$rc" "$GE_TOTAL" "$GE_DELIVERED" "$GE_ACTIVE" "$GE_WAITING" "$(printf "%s" "$GE_DIRECT" | tr "\n" ",")" \
            "$(printf "%s" "$GE_SNAP" | cut -f1 | tr "\n" ",")" "$(printf "%s" "$GE_REFS" | cut -f1 | tr "\n" ",")"'
}

test_dr_ac8_goal_eval_leaves_direct_route_rows_out_of_every_count() {
  dr_setup
  local rc=0
  glb_ticket $GLB_B 2 open
  dr_eval "$(dr_rows3)"
  assert_eq "$DG_OUT" "0 2 1 1 0|$DR_RCA#609,|$GLB_RA#1,$GLB_RB#2,|$GLB_RA#1,$GLB_RB#2," "AC8: counts, GE_DIRECT, GE_SNAP and GE_REFS (stderr: $DG_ERR)" || rc=1
  assert_eq "$(grep -c "repos/$DR_RCA/" "$DG_BIN/gh-calls.log")" "0" "AC8: the direct-route ticket is never read" || rc=1
  glb_teardown; return $rc
}

test_dr_ac8_only_direct_route_rows_evaluate_to_an_empty_goal() {
  dr_setup
  local rc=0
  dr_eval "$(printf '%s\topen\t-\tjpmoya\t-\t-\t-\n%s\tclosed\t-\tjpmoya\t-\tcompleted\t-\n' "$DR_RCA#609" "$DR_RCA#611")"
  assert_eq "$DG_OUT" "0 0 0 0 0|$DR_RCA#609,$DR_RCA#611,||" "AC8: only direct-route rows -> GE_TOTAL=0, both in GE_DIRECT, nothing in snap/refs (stderr: $DG_ERR)" || rc=1
  assert_eq "$(grep -c "repos/$DR_RCA/" "$DG_BIN/gh-calls.log")" "0" "AC8: explicit rows trigger no read and no #605 granted-list fallback" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC9 goal_sync ------------------------------
# Label "goal: DR" on claude-agents#627 (open) and project-a#8 (open); v2 goal over both repos with go:true, nothing granted yet.
test_dr_ac9_goal_sync_grants_no_agent_go_on_the_direct_route_ticket() {
  dr_setup
  local rc=0 body
  glb_label $GLB_A "goal: DR"; glb_label $DR_CA "goal: DR"
  glb_ticket $GLB_A 8 open "goal: DR"; glb_ticket $DR_CA 627 open "goal: DR"
  glb_v2 900 "goal: DR" "DR" "$DR_RCA,$GLB_RA" active dr-s
  glb_cache 900 dr-s
  glb_sync
  assert_eq "$DG_RC" "0" "AC9: goal_sync rc (stderr: $DG_ERR)" || rc=1
  glb_has_label $GLB_A 8 agent-go || { fail "AC9: the app-repo ticket of the same goal is still granted agent-go"; rc=1; }
  glb_has_label $DR_CA 627 agent-go && { fail "AC9: the direct-route ticket must not get agent-go"; rc=1; }
  assert_eq "$(grep -c "POST repos/$DR_RCA/issues/627/labels" "$DG_BIN/writes.log")" "0" "AC9: no label write on the direct-route ticket" || rc=1
  body=$(jq -r .body "$DG_ST/issues/$DG_REG/900.json")
  assert_contains "$body" "$GLB_RA#8" "AC9: Go-granted records the app-repo ticket" || rc=1
  assert_not_contains "$body" "$DR_RCA#627" "AC9: Go-granted never records the direct-route ticket" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.txt")" "repo=$DR_RCA reason=direct-route repo" "AC9: the skip is logged" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ AC13 the brief -----------------------------
test_dr_ac13_brief_lists_direct_route_tickets_apart() {
  dr_setup
  local rc=0 out scope direct
  glb_label $GLB_A "goal: DR"; glb_label $DR_CA "goal: DR"
  glb_ticket $GLB_A 8 open "goal: DR"; glb_ticket $DR_CA 627 open "goal: DR"
  glb_v2 903 "goal: DR" "DR" "$DR_RCA,$GLB_RA" active dr-b
  dr_lib 'goal_brief dr-b'
  assert_eq "$DG_RC" "0" "AC13: brief rc (stderr: $DG_ERR)" || rc=1
  out=$DG_OUT
  assert_contains "$out" "Direct route — needs the interactive session" "AC13: the heading is in the brief" || rc=1
  scope=$(printf '%s\n' "$out" | awk '/^Scope \(live from GitHub\):/ {on=1; next} /^Direct route — / {on=0} on')
  direct=$(printf '%s\n' "$out" | awk '/^Direct route — / {on=1; next} /^Rules:/ {on=0} on')
  assert_contains "$scope" "$GLB_RA#8  open  latest marker:" "AC13: the app-repo ticket is a scope row" || rc=1
  assert_not_contains "$scope" "$DR_RCA#627" "AC13: the direct-route ticket is not a scope row" || rc=1
  assert_contains "$direct" "$DR_RCA#627  open" "AC13: the direct-route ticket is listed under the heading" || rc=1
  assert_contains "$out" "never dispatch" "AC13: the rule is in the brief" || rc=1
  assert_contains "$out" "Checkout: $DG_CK_A" "AC13: the lead's checkout is the app repo" || rc=1
  assert_eq "$(grep -c "repos/$DR_RCA/issues/627" "$DG_BIN/gh-calls.log")" "0" "AC13: no marker read on the direct-route ticket" || rc=1
  glb_teardown; return $rc
}

echo "-- direct-route repos: goals (issue #632 AC6-AC9, AC13 brief)"
run_test test_dr_ac6_goal_launch_skips_a_direct_route_goal
run_test test_dr_ac6_cross_repo_goal_launches_its_lead_from_the_app_repo
run_test test_dr_ac7_register_refuses_the_three_spec_forms_before_any_write
run_test test_dr_ac7_label_goal_drops_the_direct_route_repo_and_dies_when_none_is_left
run_test test_dr_ac8_goal_eval_leaves_direct_route_rows_out_of_every_count
run_test test_dr_ac8_only_direct_route_rows_evaluate_to_an_empty_goal
run_test test_dr_ac9_goal_sync_grants_no_agent_go_on_the_direct_route_ticket
run_test test_dr_ac13_brief_lists_direct_route_tickets_apart
