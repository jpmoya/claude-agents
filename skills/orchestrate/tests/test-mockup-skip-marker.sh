# Issue #272 — JP-declared upfront skip of the mockup gate: exact first line `**[jp] SKIP MOCKUPS**` +
# second line `JP said: "<verbatim>"`, from the issue author only. Expected values come from the ticket text.
# Sorted after test-mockup-gate-exact-marker.sh on purpose: reuses its mg_* harness (issue 74, supervisor tick).
# Helpers prefixed sm_ / SM_. Placeholder repos only.
#
# CONTRACTS the ticket leaves open (decided here, flagged in the handoff):
#  - comment fixtures carry `author.login`; the issue author is `jpmoya` (every pipeline comment is posted as that account).
#  - a malformed/unparseable skip check fails CLOSED (gate stays) and logs one supervisor.log line containing
#    `[skip-mockups]` and `malformed`, never the `JP said:` quote.

ORCH_SM="$ROOT_MG/agents/orchestrator.md"
PM_SM="$ROOT_MG/agents/product-manager.md"
DL_SM="$ROOT_MG/agents/delivery-lead.md"
UX_SM="$ROOT_MG/agents/ui-ux-designer.md"
FS_SM="$ROOT_MG/agents/fullstack-developer.md"
SKILL_SM="$HERE_MG/../SKILL.md"
SM_MARK='**[jp] SKIP MOCKUPS**'
SM_VALID=$'**[jp] SKIP MOCKUPS**\nJP said: "skip it"'
SM_PEND='**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'

# sm_thread <author> <body> — gate comment then one candidate comment (issue 74), authors set
sm_thread() {
  mg_thread "$SM_PEND" "$2"
  jq --arg a "$1" 'map(.author = {login: "jpmoya"}) | .[-1].author.login = $a' "$MG_GH/gh-issue-comments-json" > "$MG_GH/x.tmp" \
    && mv "$MG_GH/x.tmp" "$MG_GH/gh-issue-comments-json"
}

# ------------------------------------------------------------------ hook vocabulary (AC6)
test_sm_jp_vocabulary_has_skip_mockups_and_keeps_approved() {
  local v; v=$(. "$MARKERS_MG"; markers_for jp)
  assert_contains "$v" "SKIP MOCKUPS" "jp vocabulary" || return 1
  assert_contains "$v" "MOCKUPS APPROVED" "jp vocabulary keeps approval" || return 1
}
test_sm_marker_re_matches_exact_valid_first_line() {
  assert_eq "$(mg_matches "$SM_MARK")" "true" "exact SKIP MOCKUPS first line" || return 1
  assert_eq "$(mg_matches "**[jp] MOCKUPS APPROVED**")" "true" "approval twin unchanged" || return 1
}
test_sm_marker_re_rejects_non_exact_lines() {
  local l
  for l in "I'd skip mockups here" '**[jp] SKIP MOCKUPS** please' 'ok **[jp] SKIP MOCKUPS**' '**[product-manager] SKIP MOCKUPS**' '**[delivery-lead] SKIP MOCKUPS**'; do
    assert_eq "$(mg_matches "$l")" "false" "reject [$l]" || return 1
  done
}
test_sm_agents_cannot_post_skip_mockups_as_agent_marker() {
  local a v
  for a in product-manager ux-flow-designer ui-ux-designer solutions-architect test-writer test-reviewer fullstack-developer code-reviewer deployer infra-planner infra-reviewer infra-operator intake orchestrator delivery-lead project-manager; do
    v=$(. "$MARKERS_MG"; markers_for "$a")
    assert_not_contains "$v" "SKIP MOCKUPS" "$a vocabulary" || return 1
  done
}

# ------------------------------------------------------------------ supervisor gate (AC1/AC3/AC4/AC7)
test_sm_valid_marker_after_pending_clears_gate() {
  sm_thread jpmoya "$SM_VALID"; mg_tick; mg_assert_not_gate "valid skip after MOCKUPS PENDING" || return 1
}
test_sm_negative_fixtures_stay_a_gate() {
  local b i=0
  for b in "I'd skip mockups here" $'**[jp] SKIP MOCKUPS** please\nJP said: "skip it"' $'**[jp] SKIP MOCKUPS**' \
           $'**[delivery-lead] DECISION**\nResolves: https://x/1\n**[jp] SKIP MOCKUPS**\nJP said: "skip it"' \
           $'**[product-manager] NOTE**\n**[jp] SKIP MOCKUPS**\nJP said: "skip it"' \
           $'**[jp] SKIP MOCKUPS**\nJP said: ""'; do
    i=$((i+1)); sm_thread jpmoya "$b"; mg_tick; mg_assert_gate "negative fixture $i" || return 1
  done
}
test_sm_marker_only_in_pm_ready_comment_stays_a_gate() {
  mg_thread '**[product-manager] READY FOR ENGINEERING**'$'\n''UI change: yes'$'\n''**[jp] SKIP MOCKUPS**'$'\n''JP said: "skip it"' "$SM_PEND"
  jq 'map(.author = {login: "jpmoya"})' "$MG_GH/gh-issue-comments-json" > "$MG_GH/x.tmp" && mv "$MG_GH/x.tmp" "$MG_GH/gh-issue-comments-json"
  mg_tick; mg_assert_gate "marker only in PM READY comment" || return 1
}
test_sm_non_author_marker_stays_a_gate() {
  sm_thread someone-else "$SM_VALID"; mg_tick; mg_assert_gate "non-author valid-looking marker" || return 1
}
test_sm_marker_only_in_issue_body_stays_a_gate() {
  mg_thread "$SM_PEND" 'unrelated chatter'
  jq -n --arg b "$SM_VALID" '{body:$b}' > "$MG_GH/gh-issue-body-json" 2>/dev/null
  printf '%s' "$SM_VALID" > "$MG_GH/gh-issue-body"
  mg_tick; mg_assert_gate "marker only in issue body" || return 1
}
test_sm_marker_in_launch_text_stays_a_gate() {
  mg_thread "$SM_PEND" 'unrelated chatter'
  printf '%s\n' "$SM_VALID" > "$MG_PIPE/orch-74.brief"
  printf '%s\n' "$SM_VALID" > "$MG_PIPE/orch-74.launch"
  mg_tick; mg_assert_gate "marker only in launch/brief text" || return 1
}
test_sm_malformed_check_fails_closed_and_logs_without_quote() {
  local log held
  mg_thread "$SM_PEND" $'**[jp] SKIP MOCKUPS**\nJP said: "SECRET-QUOTE-272" \x01\xff'
  jq 'map(.author = 7)' "$MG_GH/gh-issue-comments-json" > "$MG_GH/x.tmp" && mv "$MG_GH/x.tmp" "$MG_GH/gh-issue-comments-json"
  mg_tick
  log=$(cat "$MG_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  held=$(if [ -e "$MG_PIPE/orch-74.held" ]; then echo present; else echo absent; fi)
  mg_cleanup
  assert_eq "$held" present "malformed skip fails closed" || return 1
  assert_contains "$log" "[skip-mockups]" "parse failure logged" || return 1
  assert_contains "$log" "malformed" "parse failure logged as malformed" || return 1
  assert_not_contains "$log" "SECRET-QUOTE-272" "JP quote never forwarded" || return 1
}

# ------------------------------------------------------------------ status text (AC7)
test_sm_status_scripts_say_mockups_skipped_by_jp() {
  local f
  for f in reconcile-status.sh goal-lib.sh build-runs-json.py; do
    mg_has "$HERE_MG/../$f" "mockups skipped by JP" || return 1
  done
}

# ------------------------------------------------------------------ docs (AC5/AC8/AC9)
test_sm_orchestrator_names_marker_and_only_skip_path() {
  mg_has "$ORCH_SM" 'only skip path: JP'"'"'s exact `**[jp] SKIP MOCKUPS**` marker' || return 1
  mg_lacks "$ORCH_SM" "there is no skip path" || return 1
  mg_has "$ORCH_SM" 'JP said:' || return 1
}
test_sm_orchestrator_entry_check_and_sa_row_accept_skip_marker() {
  local r
  r=$(grep -F 'test-writer (first dispatch)' "$ORCH_SM")
  mg_text_has "entry check" "$r" "SKIP MOCKUPS" || return 1
  r=$(grep -F '`[solutions-architect] READY FOR ENGINEERING`' "$ORCH_SM" | head -1)
  mg_text_has "SA row" "$r" "SKIP MOCKUPS" || return 1
}
test_sm_orchestrator_routing_rows_and_gate_mention_skip() {
  local r
  for r in 'USER FLOW READY' 'MOCKUPS PENDING APPROVAL` + JP approval' 'READY FOR ENGINEERING` | **Lane check first.**'; do
    mg_text_has "row [$r]" "$(grep -F -- "$r" "$ORCH_SM" | head -1)" "SKIP MOCKUPS" || return 1
  done
}
test_sm_orchestrator_ignores_non_author_sources() {
  local t; t=$(grep -n 'SKIP MOCKUPS' "$ORCH_SM")
  for s in 'issue body' 'launch' 'delivery-lead'; do mg_text_has "ignored sources" "$t" "$s" || return 1; done
}
test_sm_pm_never_writes_or_implies_marker() {
  mg_has "$PM_SM" "SKIP MOCKUPS" || return 1
  mg_text_has "pm" "$(grep -F 'SKIP MOCKUPS' "$PM_SM")" "never" || return 1
}
test_sm_delivery_lead_decision_is_never_a_skip() {
  mg_has "$DL_SM" "SKIP MOCKUPS" || return 1
}
test_sm_designer_and_developer_describe_no_mockup_case() {
  mg_has "$UX_SM" "SKIP MOCKUPS" || return 1
  mg_has "$FS_SM" "SKIP MOCKUPS" || return 1
}
test_sm_orchestrate_skill_says_main_session_posts_only_when_quoting_jp() {
  mg_has "$SKILL_SM" "SKIP MOCKUPS" || return 1
  mg_text_has "skill" "$(grep -F 'SKIP MOCKUPS' "$SKILL_SM")" "quoting JP" || return 1
}


run_test test_sm_jp_vocabulary_has_skip_mockups_and_keeps_approved
run_test test_sm_marker_re_matches_exact_valid_first_line
run_test test_sm_marker_re_rejects_non_exact_lines
run_test test_sm_agents_cannot_post_skip_mockups_as_agent_marker
run_test test_sm_valid_marker_after_pending_clears_gate
run_test test_sm_negative_fixtures_stay_a_gate
run_test test_sm_marker_only_in_pm_ready_comment_stays_a_gate
run_test test_sm_non_author_marker_stays_a_gate
run_test test_sm_marker_only_in_issue_body_stays_a_gate
run_test test_sm_marker_in_launch_text_stays_a_gate
run_test test_sm_malformed_check_fails_closed_and_logs_without_quote
run_test test_sm_status_scripts_say_mockups_skipped_by_jp
run_test test_sm_orchestrator_names_marker_and_only_skip_path
run_test test_sm_orchestrator_entry_check_and_sa_row_accept_skip_marker
run_test test_sm_orchestrator_routing_rows_and_gate_mention_skip
run_test test_sm_orchestrator_ignores_non_author_sources
run_test test_sm_pm_never_writes_or_implies_marker
run_test test_sm_delivery_lead_decision_is_never_a_skip
run_test test_sm_designer_and_developer_describe_no_mockup_case
run_test test_sm_orchestrate_skill_says_main_session_posts_only_when_quoting_jp
