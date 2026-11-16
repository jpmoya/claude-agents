# goal-lib.sh goal_eval / _goal_ship_gate — "done means on prod" for the delivery-lead goals (JP, 2026-11-16).
# A goal whose tickets are all delivered (closed) must not close while verify-shipped.sh fails for a merged PR that closes one of
# them: it stays open with the reason "not live on prod" and its lead keeps being relaunched. verify-shipped.sh is a stub here (its
# own behaviour is pinned in test-verify-shipped.sh); the REST timeline that names the PR comes from a wrapper around the sandbox gh.
# Uses the shared goal sandbox (lib/goal-sandbox.sh): the supervisor runs in an isolated tree and HOME, never on the host's state.

. "$(dirname "${BASH_SOURCE[0]}")/lib/goal-sandbox.sh"

# gsg_env <gate 0|1> <verify rc> — t-7 is closed (delivered); PR 101 merged and "Closes #7"; the verify stub exits <rc>
gsg_env() {
  gs_env
  gs_issue 7 closed
  rm -f "$GS_ST/comments/$GS_A-7.json"
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  mv "$GS_BIN/gh" "$GS_BIN/gh.real"
  cat > "$GS_BIN/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"/issues/"*"/timeline"*) cat "$(dirname "$0")/timeline.json"; exit 0 ;;
esac
exec "$(dirname "$0")/gh.real" "$@"
EOF
  chmod +x "$GS_BIN/gh"
  cat > "$GS_BIN/timeline.json" <<'EOF'
[{"event":"labeled"},
 {"event":"cross-referenced","source":{"issue":{"number":101,"body":"Closes #7","repository_url":"https://api.github.com/repos/example-owner/project-a","pull_request":{"merged_at":"2026-11-16T00:00:00Z"}}}},
 {"event":"cross-referenced","source":{"issue":{"number":102,"body":"mentions #7 only","repository_url":"https://api.github.com/repos/example-owner/project-a","pull_request":{"merged_at":"2026-11-16T00:00:00Z"}}}},
 {"event":"cross-referenced","source":{"issue":{"number":103,"body":"Closes #7","repository_url":"https://api.github.com/repos/example-owner/project-a","pull_request":{"merged_at":null}}}}]
EOF
  cat > "$GS_HOME/verify" <<'EOF'
#!/bin/bash
echo "$*" >> "$(dirname "$0")/verify-calls.log"
echo "example-owner/project-a#101: $(cat "$(dirname "$0")/verify-line")"
exit "$(cat "$(dirname "$0")/verify-rc")"
EOF
  chmod +x "$GS_HOME/verify"
  gsg_verify "$2"
  { echo "GOAL_SHIP_GATE=$1"; echo "GOAL_VERIFY_SHIPPED=\"$GS_HOME/verify\""; } >> "$GS_HOME/.claude/pipeline/config.local.sh"
}

gsg_verify() {  # <rc>
  echo "$1" > "$GS_HOME/verify-rc"
  if [ "$1" = 0 ]; then echo SHIPPED > "$GS_HOME/verify-line"; else echo "NOT SHIPPED (feature.txt (absent on main))" > "$GS_HOME/verify-line"; fi
}

test_gsg_staging_only_goal_stays_open_not_live_on_prod() {
  gsg_env 1 1
  gs_tick
  assert_eq "$(gs_reg_state 50)" "open" "all tickets delivered but not on prod: the registry issue stays open" || { gs_cleanup; return 1; }
  [ -s "$GS_PIPE/goal-$GS_ID_T7.notlive" ] || { fail "the reason file goal-<id>.notlive is missing"; gs_cleanup; return 1; }
  assert_contains "$(cat "$GS_PIPE/goal-$GS_ID_T7.notlive")" "NOT SHIPPED (feature.txt" "reason names the unshipped file" || { gs_cleanup; return 1; }
  gs_wait_claude 1 || { fail "the lead was not relaunched while the goal is not live on prod"; gs_cleanup; return 1; }
  assert_contains "$(cat "$GS_HOME/verify-calls.log")" "example-owner/project-a 101" "verified the merged PR that closes the ticket" || { gs_cleanup; return 1; }
  assert_not_contains "$(cat "$GS_HOME/verify-calls.log")" "102" "a PR that only mentions the ticket is not checked" || { gs_cleanup; return 1; }
  assert_not_contains "$(cat "$GS_HOME/verify-calls.log")" "103" "an unmerged PR is not checked" || { gs_cleanup; return 1; }
  assert_contains "$(cat "$GS_BIN"/claude-calls.*/argv 2>/dev/null)" "NOT LIVE ON PROD" "the lead's brief says why" || { gs_cleanup; return 1; }
  gs_cleanup
}

test_gsg_all_prs_shipped_goal_completes() {
  gsg_env 1 0
  gs_tick
  assert_eq "$(gs_reg_state 50)" "closed" "everything verified on main with a green deploy: the goal closes" || { gs_cleanup; return 1; }
  assert_eq "$(gs_claude_count)" "0" "no lead launched for a finished goal" || { gs_cleanup; return 1; }
  gs_cleanup
}

test_gsg_gate_off_keeps_the_old_behaviour() {
  gsg_env 0 1
  gs_tick
  assert_eq "$(gs_reg_state 50)" "closed" "GOAL_SHIP_GATE=0 is the kill switch" || { gs_cleanup; return 1; }
  [ ! -e "$GS_HOME/verify-calls.log" ] || { fail "verify-shipped was called with the gate off"; gs_cleanup; return 1; }
  gs_cleanup
}

test_gsg_ticket_without_a_merged_pr_is_not_gated() {
  gsg_env 1 1
  echo '[]' > "$GS_BIN/timeline.json"
  gs_tick
  assert_eq "$(gs_reg_state 50)" "closed" "a ticket closed with no merged PR has nothing to verify" || { gs_cleanup; return 1; }
  gs_cleanup
}

run_test test_gsg_staging_only_goal_stays_open_not_live_on_prod
run_test test_gsg_all_prs_shipped_goal_completes
run_test test_gsg_gate_off_keeps_the_old_behaviour
run_test test_gsg_ticket_without_a_merged_pr_is_not_gated
