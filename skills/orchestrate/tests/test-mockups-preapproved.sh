# Issue #677 Part C — a `**[jp] MOCKUPS APPROVED**` relay posted BEFORE the single `MOCKUPS PENDING APPROVAL` stamp counts.
# jp_mockups_preapproved_jq (hooks/pipeline-markers.sh) prints a jq filter over an issue's comments (one JSON array, REST or
# `gh issue view` shape; the issue author is passed as --arg a) that is true only when all hold:
#   - a comment by the issue author whose first line is exactly `**[jp] MOCKUPS APPROVED**` and second line `JP said: "<text>"`
#   - it is newer than the latest `[product-manager] READY FOR (ARCHITECTURE|ENGINEERING)` marker
#   - the issue has exactly one `[ui-ux-designer] MOCKUPS PENDING APPROVAL` marker and the approval is older than it
#   - it is newer than the latest mockups post (the newest `[ui-ux-designer]` comment, the stamp included, whose body carries
#     the mockups): an approval that predates the mockups it would approve never counts (code review of PR #682)
#   - no later comment by the issue author is revision feedback (neither an agent marker line nor an approval)
# A bare approval word before the stamp never counts. Goal eval: fixture (i) classifies `active`, (ii) `waiting_jp`.
# Fixtures i-vii are the ticket's, each with the mockups posted (MP_MOCK, a designer NOTE with the images) before the approval,
# so every negative fails for the reason it names. Prefix mp_ / MP_. Placeholder repo names only.

HERE_MP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_MP=$(cd "$HERE_MP/../../.." && pwd)
MARKERS_MP="$ROOT_MP/hooks/pipeline-markers.sh"
ORCH_MP="$ROOT_MP/agents/orchestrator.md"
if ! declare -f ro_setup >/dev/null 2>&1; then
  eval "mp_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_MP/test-goal-sync-reads.sh"
  eval "$(declare -f mp_real_run_test | sed '1s/mp_real_run_test/run_test/')"
fi

MP_READY='**[product-manager] READY FOR ENGINEERING**'
MP_STAMP='**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'   # the bare stamp: "mockups are posted above"
MP_IMG='![Desktop mockup](https://github.com/example-owner/project-a/blob/mockups/issue-6/.mockups/issue-6/01-list-desktop.png?raw=true)'
MP_MOCK=$'**[ui-ux-designer] NOTE**\n'"$MP_IMG"                              # a mockups post that is not the stamp
MP_STAMP_IMG="$MP_STAMP"$'\n\n'"$MP_IMG"$'\n\nplease review these mockups'   # the designer's usual handoff: the stamp carries the mockups
MP_APPROVE=$'**[jp] MOCKUPS APPROVED**\nJP said: "no need for me to approve just proceed"'
MP_AUTHOR=jpmoya

# mp_comments <login|body>... — REST comments array, in the given order (ids and timestamps ascending); bodies may hold newlines
mp_comments() {
  local j='[]' c i=0
  for c in "$@"; do
    i=$((i + 1))
    j=$(printf '%s' "$j" | jq -c --arg u "${c%%|*}" --arg b "${c#*|}" --argjson i "$i" \
      '. + [{id: (1000 + $i), user: {login: $u}, created_at: ("2026-11-12T21:" + (if $i < 10 then "0" else "" end) + ($i | tostring) + ":00Z"), body: $b}]')
  done
  printf '%s' "$j"
}
# mp_is <comments json> [author] -> true | false | error
mp_is() {
  local f
  f=$( . "$MARKERS_MP"; jp_mockups_preapproved_jq ) || { echo error; return 0; }
  [ -n "$f" ] || { echo error; return 0; }
  printf '%s' "$1" | jq -e --arg a "${2-$MP_AUTHOR}" "$f" >/dev/null 2>&1
  case $? in 0) echo true ;; 1) echo false ;; *) echo error ;; esac
}

test_mp_i_relay_before_the_single_stamp_counts() {
  local c; c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "true" "i: PM READY, [jp] MOCKUPS APPROVED + JP said, then the stamp" || return 1
}
test_mp_ii_bare_approval_word_before_the_stamp_never_counts() {
  local w c
  for w in approved go lgtm "Approved — proceed."; do
    c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$w" "$MP_AUTHOR|$MP_STAMP")
    assert_eq "$(mp_is "$c")" "false" "ii: bare '$w' before the stamp" || return 1
  done
}
test_mp_iii_approval_before_the_pm_ready_does_not_count() {
  local c; c=$(mp_comments "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "iii: approval older than the PM READY" || return 1
  # a later PM READY (the spec was re-issued) outdates an approval given for the earlier one
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|**[product-manager] READY FOR ARCHITECTURE**" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "iii: approval older than the LATEST PM READY (ARCHITECTURE form)" || return 1
}
test_mp_iv_missing_or_empty_second_line_does_not_count() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|**[jp] MOCKUPS APPROVED**" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "iv: no second line" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|"$'**[jp] MOCKUPS APPROVED**\nJP said: ""' "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "iv: empty JP said quote" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|"$'**[jp] MOCKUPS APPROVED**\nlooks good' "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "iv: second line is not a JP said line" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|"$'**[jp] MOCKUPS APPROVED** yes\nJP said: "ok"' "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "iv: first line must be exactly the marker" || return 1
}
test_mp_v_not_the_issue_author_does_not_count() {
  local c; c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "someone-else|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "v: relay by another account" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c" "")" "false" "v: unknown issue author fails closed" || return 1
}
test_mp_vi_two_stamps_do_not_count() {
  local c; c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "vi: after a revision round only an approval after the newest stamp counts" || return 1
}
test_mp_vii_author_feedback_after_the_approval_does_not_count() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|make the button bigger" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "vii: feedback after the approval, before the stamp" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP" "$MP_AUTHOR|make the button bigger")
  assert_eq "$(mp_is "$c")" "false" "vii: feedback after the stamp" || return 1
}

# agent comments (posted from the author's account) and a later approval are not revision feedback
test_mp_agent_markers_and_later_approvals_are_not_feedback() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|**[supervisor] NOTE** claim: Host 2026-11-12T21:20:00Z" \
    "$MP_AUTHOR|**[ux-flow-designer] USER FLOW READY**" "$MP_AUTHOR|$MP_STAMP" "$MP_AUTHOR|**[delivery-lead] NOTE** status" "someone-else|nice mockups!")
  assert_eq "$(mp_is "$c")" "true" "agent marker lines and another account's comment are not revision feedback" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP" "$MP_AUTHOR|approved")
  assert_eq "$(mp_is "$c")" "true" "a later approval word is an approval, not feedback" || return 1
}
test_mp_no_stamp_or_no_pm_ready_does_not_count() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE")
  assert_eq "$(mp_is "$c")" "false" "no stamp yet" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "no PM READY marker: fails closed" || return 1
  assert_eq "$(mp_is '[]')" "false" "no comments" || return 1
}
# ---- the approval must follow the mockups it approves (both sides) --------------------------------------------------
test_mp_approval_after_the_latest_mockups_post_counts() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "true" "mockups posted, then approved, then the stamp" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "true" "two mockups posts, approval after the latest" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|"$'**[ui-ux-designer] NOTE**\nMockups: .mockups/issue-6/01-list-desktop.png' "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "true" "a designer comment naming the .mockups/ files is a mockups post" || return 1
}
test_mp_approval_that_predates_the_latest_mockups_post_never_counts() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "approved before the mockups were posted" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP_IMG")
  assert_eq "$(mp_is "$c")" "false" "the stamp comment carries the mockups (usual handoff): nothing before it counts" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "a newer mockups post after the approval: JP has not seen it" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP_IMG")
  assert_eq "$(mp_is "$c")" "false" "the stamp is the latest mockups post" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "no mockups post anywhere: fails closed" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|"$'**[ux-flow-designer] USER FLOW READY**\n'"$MP_IMG" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_is "$c")" "false" "an image in another agent's comment is not the designer's mockups post" || return 1
}

test_mp_relay_after_the_stamp_is_left_to_jp_go() {
  local c; c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_STAMP" "$MP_AUTHOR|$MP_APPROVE")
  assert_eq "$(mp_is "$c")" "false" "an approval after the stamp is the existing jp_go path, not a pre-approval" || return 1
}
test_mp_crlf_and_gh_cli_shape_are_accepted() {
  local c
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|"$'**[jp] MOCKUPS APPROVED**\r\nJP said: "go ahead"\r\n' "$MP_AUTHOR|$MP_STAMP"$'\r\nsee the PNGs')
  assert_eq "$(mp_is "$c")" "true" "CRLF line endings" || return 1
  c=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP" | jq -c 'map({body, createdAt: .created_at, author: {login: .user.login}})')
  assert_eq "$(mp_is "$c")" "true" "gh issue view shape (author.login / createdAt)" || return 1
}

# ---- goal eval: (i) -> active, (ii) -> waiting_jp ------------------------------------------------------------------
mp_goal() {  # <comments json> — approved ticket #6 by $MP_AUTHOR with those comments
  ro_setup
  jq -n --arg a "$MP_AUTHOR" '[{number:6,state:"open",labels:[{name:"agent-in-progress"}],user:{login:$a},body:"UI ticket"}]' > "$RO_DIR/list-proj_repo-a.json"
  printf '%s' "$1" > "$RO_DIR/comments-proj_repo-a-6.json"
}
test_mp_goal_eval_preapproved_gate_is_active() {
  mp_goal "$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")"; local rc=0
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "$RO_RC" "0" "eval exits 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "$RO_OUT" "active	OPEN	$MP_STAMP	you approved the mockups — the pipeline will re-check" "(i): the goal's lead relaunches the parked run" || rc=1
  ro_teardown; return $rc
}
test_mp_goal_eval_approval_before_the_mockups_is_still_waiting() {
  mp_goal "$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP_IMG")"; local rc=0
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "$RO_RC" "0" "eval exits 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "${RO_OUT%%	*}" "waiting_jp" "approved before the mockups were posted: the gate stays with JP ($RO_OUT)" || rc=1
  ro_teardown; return $rc
}
test_mp_goal_eval_bare_word_before_the_stamp_is_still_waiting() {
  mp_goal "$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|approved" "$MP_AUTHOR|$MP_STAMP")"; local rc=0
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "$RO_RC" "0" "eval exits 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "$RO_OUT" "waiting_jp	OPEN	$MP_STAMP	mockups need your approval" "(ii): a bare word before the stamp leaves the gate with JP" || rc=1
  ro_teardown; return $rc
}

# ---- the orchestrator's own command: jp_preapproved <N>, extracted from orchestrator.md, gh stubbed as a function ----
mp_preapproved_rc() {  # <comments json | FAIL> -> the exit status of jp_preapproved 6 (NOHELPER when the doc has no such function)
  local code; code=$(awk '/^jp_preapproved\(\) \{/{on=1} on{print} on&&/^}$/{exit}' "$ORCH_MP")
  [ -n "$code" ] || { echo NOHELPER; return 0; }
  ( export MP_C="$1" MP_AUTHOR
    gh() {
      case "$*" in
        *"/comments"*) [ "$MP_C" = FAIL ] && return 1; printf '%s' "$MP_C" ;;
        *"--jq"*) echo "$MP_AUTHOR" ;;   # the issue-author lookup
        *) return 1 ;;
      esac
    }
    . "$MARKERS_MP"; eval "$code"; jp_preapproved 6 >/dev/null 2>&1; echo $? )
}
test_mp_orchestrator_jp_preapproved_command() {
  local yes no
  yes=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|$MP_APPROVE" "$MP_AUTHOR|$MP_STAMP")
  no=$(mp_comments "$MP_AUTHOR|$MP_READY" "$MP_AUTHOR|$MP_MOCK" "$MP_AUTHOR|approved" "$MP_AUTHOR|$MP_STAMP")
  assert_eq "$(mp_preapproved_rc "$yes")" "0" "jp_preapproved: fixture (i) -> 0" || return 1
  assert_eq "$(mp_preapproved_rc "$no")" "1" "jp_preapproved: fixture (ii) -> 1" || return 1
  assert_eq "$(mp_preapproved_rc FAIL)" "2" "jp_preapproved: a failed comments read is 2, never 'no approval'" || return 1
  # two REST pages (gh --paginate prints one array per page) are read as one thread
  local paged; paged="$(printf '%s' "$yes" | jq -c '.[0:2]')$(printf '%s' "$yes" | jq -c '.[2:]')"
  assert_eq "$(mp_preapproved_rc "$paged")" "0" "jp_preapproved: paginated output" || return 1
}

# ---- docs: AC8, AC9 ------------------------------------------------------------------------------------------------
mp_row() { grep -F -- "$1" "$ORCH_MP" | head -1; }
test_mp_ac8_orchestrator_rows_name_the_preapproval_rule() {
  local row label
  for label in '| `[ui-ux-designer] MOCKUPS PENDING APPROVAL` + JP approval comment' '1. **JP approves**' '| test-writer (first dispatch) |'; do
    row=$(mp_row "$label")
    assert_ne "$row" "" "AC8: row [$label] exists" || return 1
    assert_contains "$row" "jp_mockups_preapproved_jq" "AC8: row [$label] names the pre-approval rule" || return 1
    printf '%s' "$row" | grep -qiE 'bare approval word[^.|]*before the stamp[^.|]*(not|never)[^.|]*approval' \
      || { fail "AC8: row [$label] must still say a bare approval word before the stamp is not an approval"; return 1; }
    assert_contains "$row" "after the latest mockups post" "row [$label] says the relay must follow the latest mockups post" || return 1
  done
  assert_contains "$(cat "$ORCH_MP")" '"reason":"[jp] MOCKUPS APPROVED relay posted before the stamp"' "AC8/10: the mockup-gate validate reason" || return 1
  for label in '| `[ui-ux-designer] MOCKUPS PENDING APPROVAL` | **Terminal' '| `[solutions-architect] READY FOR ENGINEERING` | If the issue has UI changes'; do
    assert_contains "$(mp_row "$label")" "jp_mockups_preapproved_jq" "item 10: row [$label] names the pre-approval rule" || return 1
  done
}
test_mp_ac9_no_agent_can_produce_the_preapproval() {
  local f; f=$( . "$MARKERS_MP"; jp_mockups_preapproved_jq )
  assert_contains "$f" 'JP said: ' "AC9: the filter requires the JP said line" || return 1
  assert_contains "$f" '$a' "AC9: the filter requires the issue author" || return 1
  grep -qxF 'Never write a comment whose first line starts `**[jp] ` (e.g. `**[jp] SKIP MOCKUPS**`, `**[jp] GO**`) — those are JP'"'"'s alone.' "$ORCH_MP" \
    || { fail "AC9: orchestrator.md's 'Never write a comment whose first line starts **[jp] ' sentence changed"; return 1; }
}

run_test test_mp_i_relay_before_the_single_stamp_counts
run_test test_mp_ii_bare_approval_word_before_the_stamp_never_counts
run_test test_mp_iii_approval_before_the_pm_ready_does_not_count
run_test test_mp_iv_missing_or_empty_second_line_does_not_count
run_test test_mp_v_not_the_issue_author_does_not_count
run_test test_mp_vi_two_stamps_do_not_count
run_test test_mp_vii_author_feedback_after_the_approval_does_not_count
run_test test_mp_agent_markers_and_later_approvals_are_not_feedback
run_test test_mp_no_stamp_or_no_pm_ready_does_not_count
run_test test_mp_approval_after_the_latest_mockups_post_counts
run_test test_mp_approval_that_predates_the_latest_mockups_post_never_counts
run_test test_mp_relay_after_the_stamp_is_left_to_jp_go
run_test test_mp_crlf_and_gh_cli_shape_are_accepted
run_test test_mp_goal_eval_preapproved_gate_is_active
run_test test_mp_goal_eval_approval_before_the_mockups_is_still_waiting
run_test test_mp_goal_eval_bare_word_before_the_stamp_is_still_waiting
run_test test_mp_orchestrator_jp_preapproved_command
run_test test_mp_ac8_orchestrator_rows_name_the_preapproval_rule
run_test test_mp_ac9_no_agent_can_produce_the_preapproval
