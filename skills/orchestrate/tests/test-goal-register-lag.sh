# #292 — `deliver.sh register` launches from the issue it just created (POST response), never from a lagging list read.
# Sourced by run-tests.sh AFTER test-goal-deliver.sh (reuses its dg_* sandbox, stateful fake gh and fixtures).
#   AC-A register builds the launched goal + brief from the POST response   AC-B one shared per-issue parser
#   AC-C resume + supervisor keep _goal_find   AC-D first registration, list lagging   AC-E re-registration, list lagging
#   AC-F no sleep/retry/backoff/state file     AC-G launch failure is alerted once (existing SLACK_WEBHOOK_URL), no instruction text
# Expected values come from the ticket text or hand arithmetic in comments — never from the code.
#
# Lag simulation: the fake gh is wrapped so that a GET of the registry issue LIST (labels=delivery-goal) hides every
# issue numbered >= 900. The stateful fake numbers new issues from 900 (max 899 + 1), so the issue `register` creates
# is invisible to list reads, exactly like GitHub's list endpoint in the first seconds. Single-issue GETs and writes
# are untouched. Predecessors seeded with numbers < 900 stay visible.

dl_setup() {
  dg_setup
  mv "$DG_BIN/gh" "$DG_BIN/gh.real"
  cat > "$DG_BIN/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  *"issues?"*labels=delivery-goal*) "$HERE/gh.real" "$@" | jq -c 'map(select(.number < 900))' ;;
  *) exec "$HERE/gh.real" "$@" ;;
esac
GH_EOF
  chmod +x "$DG_BIN/gh"
}

# AC-D (first registration of a new id, list lagging): launches on the first call, no goal-stopped, issue stays open.
# Hand arithmetic: no registry issue exists beforehand, so the new one is #900 and open; exactly 1 lead launch.
test_dl_first_registration_with_lagging_list_launches() {
  dl_setup
  dg_run "$DG_SPEC_T7" --now "focus on quotes"   # #320: --now keeps the immediate launch these cases are about
  local f rc=0
  assert_eq "$DG_RC" "0" "AC-D: register exits 0 despite the lagging list (stderr: $DG_ERR)" || rc=1
  assert_not_contains "$DG_ERR" "not found in the registry" "AC-D: no 'not found in the registry' message" || rc=1
  assert_not_contains "$DG_ERR" "closed it as stopped" "AC-D: no 'closed it as stopped' message" || rc=1
  f="$DG_ST/issues/$DG_REG/900.json"
  assert_file_exists "$f" "AC-D: the registry issue was created as #900" || rc=1
  if [ -f "$f" ]; then
    assert_eq "$(jq -r .state "$f")" "open" "AC-D: the new issue is not closed" || rc=1
    if dg_has_label "$f" goal-stopped; then fail "AC-D: the new issue got goal-stopped"; rc=1; fi
  fi
  assert_contains "$DG_OUT" "registered $DG_ID_T7 (issue #900)" "AC-D: success line" || rc=1
  dg_wait_claude 1 || { fail "AC-D: the lead was never launched"; rc=1; }
  sleep 1
  assert_eq "$(dg_claude_count)" "1" "AC-D: lead launched exactly once" || rc=1
  dg_teardown; return $rc
}

# AC-E (re-registration, list lagging): closed predecessor #10 has the same id but a different spec spelling and
# different instructions. Hand arithmetic: milestone "v1.2.0 - Goal delivery" is number 12 → same id as ...:milestone:12.
# The lead prompt's Goal:/Instructions: lines must be the NEW issue's, not #10's.
test_dl_reregistration_with_lagging_list_uses_new_issue() {
  dl_setup
  DG_GOAL_ID=$DG_ID_MS
  dg_goal 10 "$DG_SPEC_MS" host-a stopped "OLD-INSTRUCTIONS-FROM-PREDECESSOR"
  local newspec="example-owner/project-a:milestone:$DG_TITLE" d prompt rc=0
  dg_run "$newspec" --now "NEW-INSTRUCTIONS-FROM-REGISTER"
  assert_eq "$DG_RC" "0" "AC-E: register exits 0 (stderr: $DG_ERR)" || rc=1
  dg_wait_claude 1 || { fail "AC-E: the lead was never launched"; dg_teardown; return 1; }
  d=$(dg_last_claude_dir); prompt=$(cat "$d/argv")
  assert_contains "$prompt" "Goal: $newspec" "AC-E: Goal: line comes from the new issue" || rc=1
  assert_contains "$prompt" "Instructions: NEW-INSTRUCTIONS-FROM-REGISTER" "AC-E: Instructions: line comes from the new issue" || rc=1
  assert_not_contains "$prompt" "OLD-INSTRUCTIONS-FROM-PREDECESSOR" "AC-E: predecessor instructions absent" || rc=1
  assert_not_contains "$prompt" "Goal: $DG_SPEC_MS" "AC-E: predecessor spec absent" || rc=1
  dg_teardown; return $rc
}

# AC-A / AC-B / AC-C / AC-F — structure of the change.
test_dl_register_passes_created_goal_and_keeps_single_parser() {
  local reg lib launch brief rc=0 n
  reg=$(awk '/^cmd_register\(\)/{f=1} f{print} f&&/^}/{exit}' "$DG_SKILL/deliver.sh")
  lib="$DG_SKILL/goal-lib.sh"
  launch=$(awk '/^goal_launch\(\)/{f=1} f{print} f&&/^}/{exit}' "$lib")
  brief=$(awk '/^goal_brief\(\)/{f=1} f{print} f&&/^}/{exit}' "$lib")
  [ -n "$reg" ] || { fail "cmd_register not found"; return 1; }
  # AC-A: the goal_launch call inside cmd_register carries a second argument (the goal built from $resp)
  printf '%s' "$reg" | grep -Eq 'goal_launch "\$id" +[^ >)|;&]' \
    || { fail "AC-A: cmd_register must call goal_launch \"\$id\" <goal json>"; rc=1; }
  printf '%s' "$reg" | grep -q '\$resp' || { fail "AC-A: cmd_register no longer reads the POST response"; rc=1; }
  # AC-B: exactly one per-issue body parser (the fenced-block fromjson) across the library and deliver.sh
  n=$(cat "$lib" "$DG_SKILL/deliver.sh" | grep -c 'fromjson')
  assert_eq "$n" "1" "AC-B: one per-issue parser (fromjson occurrences)" || rc=1
  # AC-A (brief): goal_brief accepts the goal as optional 2nd arg and goal_launch forwards it
  printf '%s' "$brief" | grep -q '\$2' || { fail "AC-A: goal_brief must read an optional 2nd argument"; rc=1; }
  printf '%s' "$launch" | grep -Eq 'goal_brief "\$id" +"?\$' || { fail "AC-A: goal_launch must forward the goal to goal_brief"; rc=1; }
  # AC-C: resume and supervisor paths unchanged (still launch by id alone)
  [ "$(grep -c 'if ! goal_launch "\$id"; then' "$DG_SKILL/deliver.sh")" = "1" ] \
    || { fail "AC-C: resume must keep 'goal_launch \"\$id\"' and register must not (exactly one occurrence)"; rc=1; }
  grep -q 'if goal_launch "\$id" >/dev/null 2>&1; then' "$lib" || { fail "AC-C: supervisor must keep 'goal_launch \"\$id\"'"; rc=1; }
  # AC-F: no sleep / retry / backoff added to the register path or the launch functions
  if printf '%s\n%s\n%s' "$reg" "$launch" "$brief" | grep -Eiq 'sleep +[0-9$]|retry|backoff'; then
    fail "AC-F: sleep/retry/backoff found in register/launch/brief"; rc=1
  fi
  return $rc
}

# AC-C behaviour: resume of an existing goal still works through the list (unchanged _goal_find path).
test_dl_resume_still_launches_via_registry() {
  dl_setup
  DG_GOAL_ID=$DG_ID_T7
  dg_goal 10 "$DG_SPEC_T7" host-a stopped "resume me"
  dg_run resume "$DG_ID_T7"
  local rc=0
  assert_eq "$DG_RC" "0" "AC-C: resume exits 0 (stderr: $DG_ERR)" || rc=1
  dg_wait_claude 1 || { fail "AC-C: resume did not launch the lead"; rc=1; }
  dg_teardown; return $rc
}

# AC-G: with the launch failing, the existing Slack alert path fires exactly once with the goal id and no
# instruction text. Launch failure is forced by making goal-<id>.pid a directory (the pid write in goal_launch fails).
# The alert is observed at the true external boundary: a fake curl receiving the SLACK_WEBHOOK_URL post.
test_dl_launch_failure_is_alerted_once_without_instructions() {
  DG_EXTRA_CFG='SLACK_WEBHOOK_URL=https://hooks.example.invalid/T000/B000/XXXX'
  dl_setup
  DG_EXTRA_CFG=""
  cat > "$DG_BIN/curl" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d "$HERE/curl-calls.XXXXXX"); printf '%s\n' "$@" > "$d/argv"; exit 0
EOF
  chmod +x "$DG_BIN/curl"
  mkdir -p "$DG_PIPE/goal-$DG_ID_T7.pid"
  local rc=0 n all
  dg_run "$DG_SPEC_T7" --now "SECRET-INSTRUCTION-TEXT"
  assert_ne "$DG_RC" "0" "AC-G: register fails when the launch fails" || rc=1
  assert_contains "$DG_ERR" "launch failed" "AC-G: failure message" || rc=1
  n=$(ls -d "$DG_BIN"/curl-calls.* 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$n" "1" "AC-G: alert helper invoked exactly once" || rc=1
  all=$(cat "$DG_BIN"/curl-calls.*/argv 2>/dev/null)
  assert_contains "$all" "$DG_ID_T7" "AC-G: alert carries the goal id" || rc=1
  assert_not_contains "$all" "SECRET-INSTRUCTION-TEXT" "AC-G: alert carries no instruction text" || rc=1
  dg_teardown; return $rc
}

# #440 label-goal path (cmd_register_label), list lagging, closed same-id predecessor #10 with OLD instructions.
# Hand arithmetic: label "goal: Cross-repo goal model for the" → id "label-goal__Cross-repo_goal_model_for_the".
test_dl_label_reregistration_with_lagging_list_uses_new_issue() {
  glb_setup
  mv "$DG_BIN/gh" "$DG_BIN/gh.real"
  cat > "$DG_BIN/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  *"issues?"*labels=delivery-goal*) "$HERE/gh.real" "$@" | jq -c 'map(select(.number < 900))' ;;
  *) exec "$HERE/gh.real" "$@" ;;
esac
GH_EOF
  chmod +x "$DG_BIN/gh"
  local id rc=0 d prompt
  id=$(printf 'label-%s' "$GLB_L" | sed 's/[^A-Za-z0-9._-]/_/g')
  glb_v2 10 "$GLB_L" "$GLB_T" "$GLB_REPOS" stopped "$id" "$GLB_RA#7"
  jq '.body |= sub("\"go\":true"; "\"instructions\":\"OLD-INSTRUCTIONS-FROM-PREDECESSOR\",\"go\":true")' \
    "$DG_ST/issues/$DG_REG/10.json" > "$DG_ST/x.json" && mv "$DG_ST/x.json" "$DG_ST/issues/$DG_REG/10.json"
  glb_seed7; glb_ticket $GLB_B 1 open
  glb_reg "$GLB_T" "NEW-INSTRUCTIONS-FROM-REGISTER"
  assert_eq "$DG_RC" "0" "#440 label: register exits 0 (stderr: $DG_ERR)" || rc=1
  dg_wait_claude 1 || { fail "#440 label: the lead was never launched"; glb_teardown; return 1; }
  d=$(dg_last_claude_dir); prompt=$(cat "$d/argv")
  assert_contains "$prompt" "Instructions: NEW-INSTRUCTIONS-FROM-REGISTER" "#440 label: new instructions launched" || rc=1
  assert_not_contains "$prompt" "OLD-INSTRUCTIONS-FROM-PREDECESSOR" "#440 label: predecessor instructions absent" || rc=1
  glb_teardown; return $rc
}

run_test test_dl_first_registration_with_lagging_list_launches
run_test test_dl_reregistration_with_lagging_list_uses_new_issue
run_test test_dl_register_passes_created_goal_and_keeps_single_parser
run_test test_dl_resume_still_launches_via_registry
run_test test_dl_launch_failure_is_alerted_once_without_instructions
run_test test_dl_label_reregistration_with_lagging_list_uses_new_issue
