# Issue #139 (host half) — reconcile-status.sh decides, per held ticket, what JP has to do
# (orch-<n>.needs), when the gate was posted (.gate_at) and why it should leave Needs JP
# (.parked_reason: answered | out_of_scope). build-runs-json.py emits the three as runs[] keys.
#
# Fixtures from the ticket's "Test fixtures" section (a)-(f). Placeholder repo names only.
# Expected values are hand-written from the ticket. Bash 3.2 portable. Reuses the sc_* helpers of
# test-status-completed.sh (sourced earlier by run-tests.sh in alphabetical order is NOT relied on:
# they are redefined here with an nj_ prefix).

HERE_NJ=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_NJ="$HERE_NJ/.."
NJ_ALIAS="example-owner/project-a"

nj_env() {
  NJ_PIPE=$(new_pipe); NJ_HOME=$(new_home)
  NJ_REPO="$NJ_PIPE/repo-project-a"
  fixture_repo "$NJ_REPO" "$NJ_ALIAS"
  NJ_BIN="$NJ_HOME/.local/bin"
  mk_fake_gh "$NJ_BIN"
  echo "$NJ_ALIAS" > "$NJ_BIN/gh-name-with-owner"
  # the ticket's repo is in scope unless a test overrides the config
  nj_config "DISPATCH_REPOS=(\"$NJ_ALIAS:$NJ_REPO\")"
}
nj_config() { printf '%s\nSTATUS_REPO_ALIASES=("%s:project-a")\n' "$1" "$NJ_ALIAS" > "$NJ_HOME/.claude/pipeline/config.local.sh"; }
nj_cleanup() { cleanup_running; rm -rf "$NJ_PIPE" "$NJ_HOME"; return 0; }

# nj_comments <n> <json array> — the issue's full comments, as `gh issue view --json comments` returns them
nj_comments() { printf '%s' "$2" > "$NJ_BIN/gh-issue-comments-json-$1"; }
# nj_c <body> <createdAt> — one comment object
nj_c() { jq -nc --arg b "$1" --arg t "$2" '{body:$b, createdAt:$t, author:{login:"x"}}'; }

nj_held() { mk_held "$NJ_PIPE" "$1" "$NJ_REPO"; printf 'Title of %s\n' "$1" > "$NJ_PIPE/orch-$1.title"; }

nj_reconcile() {
  HOME="$NJ_HOME" PATH="$NJ_BIN:/usr/bin:/bin" PIPE="$NJ_PIPE" QUEUE="$NJ_PIPE/queue" LOGDIR="$NJ_HOME/logs/pipeline" \
    "$RS_NJ/reconcile-status.sh" --force >/dev/null 2>&1
}
nj_print() {
  HOME="$NJ_HOME" PATH="$NJ_BIN:/usr/bin:/bin" PIPE="$NJ_PIPE" QUEUE="$NJ_PIPE/queue" LOGDIR="$NJ_HOME/logs/pipeline" \
    "$RS_NJ/report-status.sh" --print 2>/dev/null
}
nj_file() { if [ -f "$1" ]; then head -n1 "$1"; else echo ABSENT; fi; }   # first line of a state file, or ABSENT
nj_run_field() {  # nj_run_field <json> <issue> <field>
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" \
    '[.runs[] | select((.issue|tostring)==$n)] | if length==0 then "NORUN" else (.[0] | if has($f) then (.[$f]|tostring) else "MISSING_FIELD" end) end' 2>/dev/null || echo INVALID_JSON
}

GATE_T="2026-09-20T10:00:00Z"
LATER_T="2026-09-21T10:00:00Z"

# (a) gate, then a free-text [jp] reply -> answered
test_nj_a_free_text_jp_reply_after_gate_is_answered() {
  nj_env; nj_held 301
  nj_comments 301 "[$(nj_c $'**[infra-operator] AWAITING GO**\nPlan ready.' "$GATE_T"),$(nj_c $'**[jp] looks fine, wait for Friday**' "$LATER_T")]"
  nj_reconcile
  local r; r=$(nj_file "$NJ_PIPE/orch-301.parked_reason")
  nj_cleanup
  assert_eq "$r" "answered" "rule 2: a **[jp] free-text reply after the gate -> parked_reason answered" || return 1
}

test_nj_a_project_manager_decision_after_gate_is_answered() {
  nj_env; nj_held 302
  nj_comments 302 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c $'**[project-manager] we wait, not urgent**' "$LATER_T")]"
  nj_reconcile
  local r; r=$(nj_file "$NJ_PIPE/orch-302.parked_reason")
  nj_cleanup
  assert_eq "$r" "answered" "rule 2: a **[project-manager] reply after the gate -> answered" || return 1
}

# (b) [project-manager] NOTE is not an answer
test_nj_b_project_manager_note_is_not_an_answer() {
  nj_env; nj_held 303
  nj_comments 303 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c $'**[project-manager] NOTE**\nfyi' "$LATER_T")]"
  nj_reconcile
  local r nd; r=$(nj_file "$NJ_PIPE/orch-303.parked_reason"); nd=$(nj_file "$NJ_PIPE/orch-303.needs")
  nj_cleanup
  assert_eq "$nd" "Say go" "control: the pass ran and labelled the gate" || return 1
  assert_eq "$r" "ABSENT" "rule 2: **[project-manager] NOTE** never counts as an answer" || return 1
}

# (c) other agent roles never answer
test_nj_c_other_role_comment_is_not_an_answer() {
  nj_env; nj_held 304
  nj_comments 304 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c $'**[test-writer] NOTE**\nx' "$LATER_T")]"
  nj_reconcile
  local r nd; r=$(nj_file "$NJ_PIPE/orch-304.parked_reason"); nd=$(nj_file "$NJ_PIPE/orch-304.needs")
  nj_cleanup
  assert_eq "$nd" "Say go" "control: the pass ran and labelled the gate" || return 1
  assert_eq "$r" "ABSENT" "rule 2: **[test-writer] NOTE** is not an answer" || return 1
}

test_nj_c_unprefixed_comment_is_not_an_answer() {
  nj_env; nj_held 305
  nj_comments 305 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c 'go ahead please' "$LATER_T")]"
  nj_reconcile
  local r nd; r=$(nj_file "$NJ_PIPE/orch-305.parked_reason"); nd=$(nj_file "$NJ_PIPE/orch-305.needs")
  nj_cleanup
  assert_eq "$nd" "Say go" "control: the pass ran and labelled the gate" || return 1
  assert_eq "$r" "ABSENT" "non-blocking default: only the **[jp] prefix counts" || return 1
}

test_nj_a_jp_comment_before_the_gate_is_not_an_answer() {
  nj_env; nj_held 306
  nj_comments 306 "[$(nj_c $'**[jp] earlier chatter**' "2026-09-19T10:00:00Z"),$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_reconcile
  local r nd; r=$(nj_file "$NJ_PIPE/orch-306.parked_reason"); nd=$(nj_file "$NJ_PIPE/orch-306.needs")
  nj_cleanup
  assert_eq "$nd" "Say go" "control: the pass ran and labelled the gate" || return 1
  assert_eq "$r" "ABSENT" "rule 2: only comments AFTER the gate comment count" || return 1
}

# (d) needs label
test_nj_d_blocked_credential_reason_is_missing_credential() {
  nj_env; nj_held 307
  nj_comments 307 "[$(nj_c $'**[fullstack-developer] BLOCKED**\nBlocked on: missing GitHub token\nDetails' "$GATE_T")]"
  nj_reconcile
  local n; n=$(nj_file "$NJ_PIPE/orch-307.needs")
  nj_cleanup
  assert_eq "$n" "Missing credential" "BLOCKED + 'missing GitHub token' -> Missing credential" || return 1
}

test_nj_d_blocked_credential_match_is_case_insensitive() {
  nj_env; nj_held 308
  nj_comments 308 "[$(nj_c $'**[fullstack-developer] BLOCKED**\nBlocked on: need the API KEY for staging' "$GATE_T")]"
  nj_reconcile
  local n; n=$(nj_file "$NJ_PIPE/orch-308.needs")
  nj_cleanup
  assert_eq "$n" "Missing credential" "'API KEY' matches 'api key' case-insensitively" || return 1
}

test_nj_d_blocked_other_reason_is_decision_needed() {
  nj_env; nj_held 309
  nj_comments 309 "[$(nj_c $'**[fullstack-developer] BLOCKED**\nBlocked on: which DB?' "$GATE_T")]"
  nj_reconcile
  local n; n=$(nj_file "$NJ_PIPE/orch-309.needs")
  nj_cleanup
  assert_eq "$n" "Decision needed" "BLOCKED + 'which DB?' -> Decision needed" || return 1
}

test_nj_d_credential_word_only_on_line_3_does_not_count() {
  nj_env; nj_held 310
  nj_comments 310 "[$(nj_c $'**[fullstack-developer] BLOCKED**\nBlocked on: which DB?\nthe token is fine' "$GATE_T")]"
  nj_reconcile
  local n; n=$(nj_file "$NJ_PIPE/orch-310.needs")
  nj_cleanup
  assert_eq "$n" "Decision needed" "only line 2 (Blocked on:) is matched against the credential words" || return 1
}

test_nj_d_fixed_labels_for_the_other_three_gates() {
  nj_env; nj_held 311; nj_held 312; nj_held 313
  nj_comments 311 "[$(nj_c $'**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nsecret sauce' "$GATE_T")]"
  nj_comments 312 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_comments 313 "[$(nj_c $'**[product-manager] EFFORT APPROVAL NEEDED**' "$GATE_T")]"
  nj_reconcile
  local a b c
  a=$(nj_file "$NJ_PIPE/orch-311.needs"); b=$(nj_file "$NJ_PIPE/orch-312.needs"); c=$(nj_file "$NJ_PIPE/orch-313.needs")
  nj_cleanup
  assert_eq "$a" "Approve mockups" "MOCKUPS PENDING APPROVAL -> Approve mockups" || return 1
  assert_eq "$b" "Say go" "AWAITING GO -> Say go" || return 1
  assert_eq "$c" "Approve effort" "EFFORT APPROVAL NEEDED -> Approve effort" || return 1
}

test_nj_gate_at_is_the_latest_routing_marker_comment_time() {
  nj_env; nj_held 314
  nj_comments 314 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c $'**[project-manager] NOTE**' "$LATER_T")]"
  nj_reconcile
  local g; g=$(nj_file "$NJ_PIPE/orch-314.gate_at")
  nj_cleanup
  assert_eq "$g" "$GATE_T" "gate_at = createdAt of the latest routing-marker comment (a NOTE is not one)" || return 1
}

# (e) scope
test_nj_e_repo_not_in_config_is_out_of_scope() {
  nj_env; nj_held 315
  nj_config 'DISPATCH_REPOS=("example-owner/other-repo:/tmp/x")'
  nj_comments 315 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_reconcile
  local r; r=$(nj_file "$NJ_PIPE/orch-315.parked_reason")
  nj_cleanup
  assert_eq "$r" "out_of_scope" "rule 3: repo not in DISPATCH_REPOS u SCAN_ONLY_REPOS -> out_of_scope" || return 1
}

test_nj_e_scan_only_repo_is_in_scope() {
  nj_env; nj_held 316
  nj_config "SCAN_ONLY_REPOS=(\"$NJ_ALIAS\")"
  nj_comments 316 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_reconcile
  local r nd; r=$(nj_file "$NJ_PIPE/orch-316.parked_reason"); nd=$(nj_file "$NJ_PIPE/orch-316.needs")
  nj_cleanup
  assert_eq "$nd" "Say go" "control: the pass ran and labelled the gate" || return 1
  assert_eq "$r" "ABSENT" "rule 3: a SCAN_ONLY_REPOS repo is in scope" || return 1
}

test_nj_parked_reason_is_removed_when_no_longer_applicable() {
  nj_env; nj_held 317
  nj_comments 317 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c $'**[jp] wait**' "$LATER_T")]"
  nj_reconcile
  local first; first=$(nj_file "$NJ_PIPE/orch-317.parked_reason")
  nj_comments 317 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"   # reply deleted
  nj_reconcile
  local second; second=$(nj_file "$NJ_PIPE/orch-317.parked_reason")
  nj_cleanup
  assert_eq "$first" "answered" "control: answered first" || return 1
  assert_eq "$second" "ABSENT" "stale .parked_reason is removed" || return 1
}

test_nj_unanswered_in_scope_gate_writes_no_parked_reason() {
  nj_env; nj_held 318
  nj_comments 318 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_reconcile
  local r n; r=$(nj_file "$NJ_PIPE/orch-318.parked_reason"); n=$(nj_file "$NJ_PIPE/orch-318.needs")
  nj_cleanup
  assert_eq "$r" "ABSENT" "open, unanswered, in scope -> no parked_reason" || return 1
  assert_eq "$n" "Say go" "...and it still carries its needs label" || return 1
}

# (f) regression: closed issue
test_nj_f_closed_issue_writes_closed() {
  nj_env; nj_held 319
  echo CLOSED > "$NJ_BIN/gh-issue-state-319"; echo "$GATE_T" > "$NJ_BIN/gh-issue-closed-at-319"
  nj_comments 319 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_reconcile
  local c; c=$(nj_file "$NJ_PIPE/orch-319.closed")
  nj_cleanup
  assert_eq "$c" "$GATE_T" "regression: a CLOSED issue still writes orch-<n>.closed (closedAt)" || return 1
}

# payload
test_nj_payload_emits_needs_gate_at_and_parked_reason() {
  nj_env; nj_held 320; nj_held 321
  nj_comments 320 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T")]"
  nj_comments 321 "[$(nj_c $'**[infra-operator] AWAITING GO**' "$GATE_T"),$(nj_c $'**[jp] later**' "$LATER_T")]"
  nj_reconcile
  local out; out=$(nj_print)
  nj_cleanup
  assert_eq "$(nj_run_field "$out" 320 needs)" "Say go" "runs[].needs" || return 1
  assert_eq "$(nj_run_field "$out" 320 gate_at)" "$GATE_T" "runs[].gate_at" || return 1
  assert_eq "$(nj_run_field "$out" 320 parked_reason)" "MISSING_FIELD" "no parked_reason key when not applicable" || return 1
  assert_eq "$(nj_run_field "$out" 321 parked_reason)" "answered" "runs[].parked_reason" || return 1
}

test_nj_payload_has_no_free_text_from_comments() {
  nj_env; nj_held 322
  nj_comments 322 "[$(nj_c $'**[fullstack-developer] BLOCKED**\nBlocked on: need password hunter2-sekret' "$GATE_T")]"
  nj_reconcile
  local out; out=$(nj_print)
  nj_cleanup
  assert_eq "$(nj_run_field "$out" 322 needs)" "Missing credential" "control: label present" || return 1
  assert_not_contains "$out" "hunter2" "AC7: no comment text reaches the payload" || return 1
}

run_test test_nj_a_free_text_jp_reply_after_gate_is_answered
run_test test_nj_a_project_manager_decision_after_gate_is_answered
run_test test_nj_b_project_manager_note_is_not_an_answer
run_test test_nj_c_other_role_comment_is_not_an_answer
run_test test_nj_c_unprefixed_comment_is_not_an_answer
run_test test_nj_a_jp_comment_before_the_gate_is_not_an_answer
run_test test_nj_d_blocked_credential_reason_is_missing_credential
run_test test_nj_d_blocked_credential_match_is_case_insensitive
run_test test_nj_d_blocked_other_reason_is_decision_needed
run_test test_nj_d_credential_word_only_on_line_3_does_not_count
run_test test_nj_d_fixed_labels_for_the_other_three_gates
run_test test_nj_gate_at_is_the_latest_routing_marker_comment_time
run_test test_nj_e_repo_not_in_config_is_out_of_scope
run_test test_nj_e_scan_only_repo_is_in_scope
run_test test_nj_parked_reason_is_removed_when_no_longer_applicable
run_test test_nj_unanswered_in_scope_gate_writes_no_parked_reason
run_test test_nj_f_closed_issue_writes_closed
run_test test_nj_payload_emits_needs_gate_at_and_parked_reason
run_test test_nj_payload_has_no_free_text_from_comments
