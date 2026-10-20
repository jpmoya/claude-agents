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
# sm_neg <label> <body> — one negative fixture per test, so a failure names it
sm_neg() { sm_thread jpmoya "$2"; mg_tick; mg_assert_gate "negative fixture: $1" || return 1; }
test_sm_negative_prose_sentence_stays_a_gate() { sm_neg "prose sentence" "I'd skip mockups here"; }
test_sm_negative_trailing_text_stays_a_gate() { sm_neg "trailing text on first line" $'**[jp] SKIP MOCKUPS** please\nJP said: "skip it"'; }
test_sm_negative_missing_jp_said_stays_a_gate() { sm_neg "no JP said line" $'**[jp] SKIP MOCKUPS**'; }
test_sm_negative_delivery_lead_decision_stays_a_gate() { sm_neg "delivery-lead DECISION" $'**[delivery-lead] DECISION**\nResolves: https://x/1\n**[jp] SKIP MOCKUPS**\nJP said: "skip it"'; }
test_sm_negative_pm_note_stays_a_gate() { sm_neg "PM NOTE" $'**[product-manager] NOTE**\n**[jp] SKIP MOCKUPS**\nJP said: "skip it"'; }
test_sm_negative_empty_quote_stays_a_gate() { sm_neg "empty quote" $'**[jp] SKIP MOCKUPS**\nJP said: ""'; }
# AC3 / ticket default "any order = yes": the marker may precede the gate comment
test_sm_valid_marker_before_pending_clears_gate() {
  mg_thread "$SM_VALID" "$SM_PEND"
  jq 'map(.author = {login: "jpmoya"})' "$MG_GH/gh-issue-comments-json" > "$MG_GH/x.tmp" && mv "$MG_GH/x.tmp" "$MG_GH/gh-issue-comments-json"
  mg_tick; mg_assert_not_gate "valid skip posted before MOCKUPS PENDING" || return 1
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
# sm_slack_fixture — webhook configured + fake curl recording its argv (precedent: test-supervisor-auto-retry.sh)
sm_slack_fixture() {
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"' >> "$1/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$2" > "$2/curl"; chmod +x "$2/curl"
}
test_sm_malformed_check_fails_closed_and_reports_with_tags_without_quote() {
  local log held calls
  mg_thread "$SM_PEND" $'**[jp] SKIP MOCKUPS**\nJP said: "SECRET-QUOTE-272" \x01\xff'
  jq 'map(.author = 7)' "$MG_GH/gh-issue-comments-json" > "$MG_GH/x.tmp" && mv "$MG_GH/x.tmp" "$MG_GH/gh-issue-comments-json"
  sm_slack_fixture "$MG_HOME" "$MG_GH"
  mg_tick
  log=$(cat "$MG_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  calls=$(grep 'hooks.slack.test' "$MG_GH/curl.calls" 2>/dev/null)
  held=$(if [ -e "$(rkp "$MG_PIPE/orch-74.held")" ]; then echo present; else echo absent; fi)
  mg_cleanup
  assert_eq "$held" present "malformed skip fails closed (gate stays)" || return 1
  assert_contains "$calls" "route=supervisor/skip-mockups" "Slack alert carries the route tag" || return 1
  assert_contains "$calls" "release=" "alert carries the release tag" || return 1
  case "$calls" in *release=unknown*|*"release= "*) fail "release must be the commit SHA: $calls"; return 1 ;; esac
  case "$calls" in *environment=[a-zA-Z0-9]*) ;; *) fail "environment tag must have a value: $calls"; return 1 ;; esac
  assert_not_contains "$calls" "SECRET-QUOTE-272" "JP quote never forwarded to Slack" || return 1
  assert_not_contains "$log" "SECRET-QUOTE-272" "JP quote never in supervisor.log" || return 1
}

# ------------------------------------------------------------------ status text (AC7)
# Real status path: reconcile-status.sh (writes orch-N.needs) -> report-status.sh --print (runs[] JSON).
# A held run whose newest routing marker is MOCKUPS PENDING APPROVAL, then one candidate comment (all by the pipeline account
# `jpmoya` unless stated). CONTRACT: the published run object carries the text "mockups skipped by JP" and never "Approve mockups".
SM_GATE_T="2026-09-20T10:00:00Z"; SM_LATER_T="2026-09-21T10:00:00Z"
# sm_status <candidate body> <candidate author> — prints the run's published JSON object (issue 501)
sm_status() {
  local P H R B alias="example-owner/project-a" out
  P=$(new_pipe); H=$(new_home); R="$P/repo-project-a"; B="$H/.local/bin"
  fixture_repo "$R" "$alias"; mk_fake_gh "$B"; echo "$alias" > "$B/gh-name-with-owner"
  printf 'DISPATCH_REPOS=("%s:%s")\nSTATUS_REPO_ALIASES=("%s:project-a")\n' "$alias" "$R" "$alias" > "$H/.claude/pipeline/config.local.sh"
  mk_held "$P" 501 "$R"; printf 'Title of 501\n' > "$P/orch-501.title"
  jq -nc --arg g "$SM_PEND" --arg c "$1" --arg a "$2" --arg t1 "$SM_GATE_T" --arg t2 "$SM_LATER_T" \
    '[{body:$g,createdAt:$t1,author:{login:"jpmoya"}},{body:$c,createdAt:$t2,author:{login:$a}}]' > "$B/gh-issue-comments-json-501"
  HOME="$H" PATH="$B:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$P" QUEUE="$P/queue" LOGDIR="$H/logs/pipeline" "$HERE_MG/../reconcile-status.sh" --force >/dev/null 2>&1
  out=$(HOME="$H" PATH="$B:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$P" QUEUE="$P/queue" LOGDIR="$H/logs/pipeline" "$HERE_MG/../report-status.sh" --print 2>/dev/null \
    | jq -c '[.runs[] | select((.issue|tostring)=="501")] | .[0] // "NORUN"' 2>/dev/null)
  cleanup_running; rm -rf "$P" "$H"
  printf '%s' "$out"
}
test_sm_status_shows_mockups_skipped_by_jp_not_approve_mockups() {
  local r; r=$(sm_status "$SM_VALID" jpmoya)
  assert_ne "$r" "NORUN" "control: the held run is published" || return 1
  assert_contains "$r" "mockups skipped by JP" "skipped ticket shows the skipped text" || return 1
  assert_not_contains "$r" "Approve mockups" "skipped ticket is not 'Approve mockups'" || return 1
}
test_sm_status_without_marker_still_says_approve_mockups() {
  local r; r=$(sm_status 'unrelated chatter' jpmoya)
  assert_contains "$r" "Approve mockups" "no marker: gate label unchanged" || return 1
  assert_not_contains "$r" "mockups skipped by JP" "no marker: no skipped text" || return 1
}
test_sm_status_non_author_marker_still_says_approve_mockups() {
  local r; r=$(sm_status "$SM_VALID" someone-else)
  assert_contains "$r" "Approve mockups" "non-author marker is ignored by status" || return 1
  assert_not_contains "$r" "mockups skipped by JP" "non-author marker: no skipped text" || return 1
}
test_sm_status_marker_without_quote_still_says_approve_mockups() {
  local r; r=$(sm_status '**[jp] SKIP MOCKUPS**' jpmoya)
  assert_contains "$r" "Approve mockups" "no JP said line: ignored by status" || return 1
  assert_not_contains "$r" "mockups skipped by JP" "no JP said line: no skipped text" || return 1
}

# ------------------------------------------------------------------ docs (AC5/AC8/AC9)
test_sm_orchestrator_names_marker_and_only_skip_path() {
  mg_has "$ORCH_SM" 'only skip path: JP'"'"'s exact `**[jp] SKIP MOCKUPS**` marker' || return 1
  mg_lacks "$ORCH_SM" "there is no skip path" || return 1
  mg_has "$ORCH_SM" 'JP said:' || return 1
}
# sm_clause <file> <row-anchor> — what the single line containing <row-anchor> says from its first SKIP MOCKUPS onward
# (anchors are the stable row keys, not formatting). Empty when the row or the marker is missing.
sm_clause() {
  local r; r=$(grep -F -- "$2" "$1" | head -1)
  case "$r" in *"SKIP MOCKUPS"*) printf '%s' "${r#*SKIP MOCKUPS}" ;; *) printf '' ;; esac
}
sm_needs() {  # <label> <text> <word>... — text must mention every word
  local l=$1 t=$2 w; shift 2
  [ -n "$t" ] || { fail "$l: row or SKIP MOCKUPS clause missing"; return 1; }
  for w in "$@"; do mg_text_has "$l" "$t" "$w" || return 1; done
}
test_sm_orchestrator_entry_check_and_sa_row_accept_skip_marker() {
  # AC5: both rows accept the valid marker in place of approval, and only the valid (exact, JP said:) one
  local c
  c=$(sm_clause "$ORCH_SM" 'test-writer (first dispatch)')
  sm_needs "entry check" "$c" "exact" "JP said" || return 1
  c=$(sm_clause "$ORCH_SM" '| `[solutions-architect] READY FOR ENGINEERING` |')
  sm_needs "SA row" "$c" "test-writer" "exact" "JP said" || return 1
}
test_sm_orchestrator_architecture_row_skips_design_and_dispatches_sa() {
  # AC2 (:46): marker present -> no ux-flow-designer / ui-ux-designer dispatch, solutions-architect next
  local c; c=$(sm_clause "$ORCH_SM" '| `[product-manager] READY FOR ARCHITECTURE` |')
  sm_needs "READY FOR ARCHITECTURE row" "$c" "ux-flow-designer" "ui-ux-designer" "solutions-architect" || return 1
  mg_text_has "READY FOR ARCHITECTURE row says design stages are not dispatched" "$c" "not dispatch" || return 1
}
test_sm_orchestrator_engineering_row_skips_design_and_goes_to_test_writer() {
  # AC1 (:47): marker present -> no ux-flow-designer / ui-ux-designer dispatch, no gate, test-writer next
  local c; c=$(sm_clause "$ORCH_SM" '| `[product-manager] READY FOR ENGINEERING` |')
  sm_needs "READY FOR ENGINEERING row" "$c" "ux-flow-designer" "ui-ux-designer" "test-writer" "not dispatch" || return 1
  mg_text_has "READY FOR ENGINEERING row: no gate" "$c" "no mockup gate" || return 1
}
test_sm_orchestrator_user_flow_ready_row_skips_ui_designer() {
  local c; c=$(sm_clause "$ORCH_SM" '| `[ux-flow-designer] USER FLOW READY` |')
  sm_needs "USER FLOW READY row" "$c" "ui-ux-designer" "not dispatch" || return 1
}
test_sm_orchestrator_gate_row_supersede_by_skip_marker() {
  # AC3 (:52/:53): a valid marker after MOCKUPS PENDING APPROVAL clears the gate, same as approval
  local c; c=$(sm_clause "$ORCH_SM" '| `[ui-ux-designer] MOCKUPS PENDING APPROVAL` + JP approval comment')
  sm_needs "approval row" "$c" "JP said" "exact" || return 1
  c=$(sm_clause "$ORCH_SM" '| `[ui-ux-designer] MOCKUPS PENDING APPROVAL` |')
  sm_needs "terminal gate row" "$c" "supersede" || return 1
}
test_sm_orchestrator_marker_is_a_noop_on_fast_lane_and_no_ui() {
  local t; t=$(grep -F 'SKIP MOCKUPS' "$ORCH_SM")
  mg_text_has "no-op scope" "$t" "no-op" || return 1
  mg_text_has "no-op scope names fast lane" "$t" "fast" || return 1
}
test_sm_orchestrator_ignores_non_author_sources() {
  local t s; t=$(grep -F 'SKIP MOCKUPS' "$ORCH_SM")
  for s in 'issue body' 'launch' 'delivery-lead' 'PM'; do mg_text_has "ignored sources" "$t" "$s" || return 1; done
  mg_text_has "ignored sources are ignored" "$t" "never" || return 1
}
test_sm_pm_never_writes_or_implies_marker() {
  local t; t=$(grep -F 'SKIP MOCKUPS' "$PM_SM")
  sm_needs "pm" "$t" "never" "write" "imply" || return 1
  mg_has "$PM_SM" "approval inheritance" || return 1   # :78 text kept
}
test_sm_delivery_lead_decision_is_never_a_skip() {
  local t; t=$(grep -F 'SKIP MOCKUPS' "$DL_SM")
  sm_needs "delivery-lead" "$t" "DECISION" "never" || return 1
}
test_sm_designer_describes_skip_and_no_mockup_case() {
  local t; t=$(grep -F 'SKIP MOCKUPS' "$UX_SM")
  sm_needs "ui-ux-designer" "$t" "not dispatched" "JP" || return 1
}
test_sm_developer_does_not_bind_to_mockup_when_none_exists() {
  local t; t=$(grep -F 'SKIP MOCKUPS' "$FS_SM")
  sm_needs "fullstack-developer" "$t" "no mockup" "not applied" || return 1
}
test_sm_orchestrate_skill_says_main_session_posts_only_when_quoting_jp() {
  local t; t=$(grep -F 'SKIP MOCKUPS' "$SKILL_SM")
  sm_needs "skill" "$t" "quoting JP" "JP said" || return 1
}

# ------------------------------------------------------------------ goal-lib classification (AC7, goal-lib.sh:256)
# Reuses the goal-supervisor harness (gs_*). When this file runs on its own (not after test-goal-supervisor.sh in
# the shared shell) load only that file's definitions — everything before its first run_test line.
if ! type gs_env >/dev/null 2>&1; then
  . <(sed '/^echo "-- goal supervisor/,$d' "$HERE_MG/test-goal-supervisor.sh")
  GS_SKILL=$(cd "$HERE_MG/.." && pwd)   # the sourced copy derived these from /dev/fd/N
  GS_ROOT=$(cd "$GS_SKILL/../.." && pwd)
fi
# CONTRACT: the goal step reads through REST (`gh api repos/<r>/issues/<n>` .user.login and .../comments .user.login),
# as _goal_ticket_eval already does; the issue author and the marker author are `jpmoya`.
# sm_goal_class <author> <body of the comment posted after MOCKUPS PENDING APPROVAL, or "" for none>
# prints delivered | waiting_jp | active | none (same outcome reading as gs_classify: registry store / launch).
sm_goal_class() {
  local who=$1 body=$2 out=none f
  gs_env
  gs_issue 7 open
  jq -c '.user = {login: "jpmoya"}' "$GS_ST/issues/$GS_A/7.json" > "$GS_ST/issues/$GS_A/7.json.tmp" \
    && mv "$GS_ST/issues/$GS_A/7.json.tmp" "$GS_ST/issues/$GS_A/7.json"
  f="$GS_ST/comments/$GS_A-7.json"
  jq -nc --arg now "$GS_NOW" --arg p "$SM_PEND"$'\nmockups ready' '[{created_at:$now, user:{login:"jpmoya"}, body:$p}]' > "$f"
  if [ -n "$body" ]; then
    jq -c --arg now "$GS_NOW" --arg b "$body" --arg a "$who" '. + [{created_at:$now, user:{login:$a}, body:$b}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  gs_tick
  if [ "$(gs_reg_state 50)" = closed ] && ! gs_has_label 50 goal-stopped; then out=delivered
  elif gs_has_label 50 goal-waiting-jp; then out=waiting_jp
  elif gs_wait_claude 1; then out=active
  fi
  gs_cleanup
  printf '%s' "$out"
}
# 7: a skipped ticket is not "waiting on you" in a goal run — the goal keeps it active (arch: it is not delivered either)
test_sm_goal_valid_marker_is_not_waiting_jp() {
  assert_eq "$(sm_goal_class jpmoya "$SM_VALID")" "active" "goal class: PENDING + valid skip marker" || return 1
}
# controls — each must stay "mockups need your approval" (waiting_jp)
test_sm_goal_no_marker_stays_waiting_jp() {
  assert_eq "$(sm_goal_class jpmoya "")" "waiting_jp" "goal class: PENDING, no marker" || return 1
}
test_sm_goal_non_author_marker_stays_waiting_jp() {
  assert_eq "$(sm_goal_class someone-else "$SM_VALID")" "waiting_jp" "goal class: marker from non-author" || return 1
}
test_sm_goal_marker_without_quote_stays_waiting_jp() {
  assert_eq "$(sm_goal_class jpmoya "$SM_MARK")" "waiting_jp" "goal class: marker without JP said line" || return 1
}

run_test test_sm_jp_vocabulary_has_skip_mockups_and_keeps_approved
run_test test_sm_marker_re_matches_exact_valid_first_line
run_test test_sm_marker_re_rejects_non_exact_lines
run_test test_sm_agents_cannot_post_skip_mockups_as_agent_marker
run_test test_sm_valid_marker_after_pending_clears_gate
run_test test_sm_valid_marker_before_pending_clears_gate
run_test test_sm_negative_prose_sentence_stays_a_gate
run_test test_sm_negative_trailing_text_stays_a_gate
run_test test_sm_negative_missing_jp_said_stays_a_gate
run_test test_sm_negative_delivery_lead_decision_stays_a_gate
run_test test_sm_negative_pm_note_stays_a_gate
run_test test_sm_negative_empty_quote_stays_a_gate
run_test test_sm_marker_only_in_pm_ready_comment_stays_a_gate
run_test test_sm_non_author_marker_stays_a_gate
run_test test_sm_marker_only_in_issue_body_stays_a_gate
run_test test_sm_marker_in_launch_text_stays_a_gate
run_test test_sm_malformed_check_fails_closed_and_reports_with_tags_without_quote
run_test test_sm_status_shows_mockups_skipped_by_jp_not_approve_mockups
run_test test_sm_status_without_marker_still_says_approve_mockups
run_test test_sm_status_non_author_marker_still_says_approve_mockups
run_test test_sm_status_marker_without_quote_still_says_approve_mockups
run_test test_sm_orchestrator_names_marker_and_only_skip_path
run_test test_sm_orchestrator_entry_check_and_sa_row_accept_skip_marker
run_test test_sm_orchestrator_architecture_row_skips_design_and_dispatches_sa
run_test test_sm_orchestrator_engineering_row_skips_design_and_goes_to_test_writer
run_test test_sm_orchestrator_user_flow_ready_row_skips_ui_designer
run_test test_sm_orchestrator_gate_row_supersede_by_skip_marker
run_test test_sm_orchestrator_marker_is_a_noop_on_fast_lane_and_no_ui
run_test test_sm_orchestrator_ignores_non_author_sources
run_test test_sm_pm_never_writes_or_implies_marker
run_test test_sm_delivery_lead_decision_is_never_a_skip
run_test test_sm_designer_describes_skip_and_no_mockup_case
run_test test_sm_developer_does_not_bind_to_mockup_when_none_exists
run_test test_sm_orchestrate_skill_says_main_session_posts_only_when_quoting_jp
run_test test_sm_goal_valid_marker_is_not_waiting_jp
run_test test_sm_goal_no_marker_stays_waiting_jp
run_test test_sm_goal_non_author_marker_stays_waiting_jp
run_test test_sm_goal_marker_without_quote_stays_waiting_jp
gs_tree_cleanup
