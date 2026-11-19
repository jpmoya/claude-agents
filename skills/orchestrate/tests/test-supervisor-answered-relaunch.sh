# #780 — a held ticket JP (or his delegate) has answered is relaunched by the supervisor itself, once per answer.
# Acceptance criteria 1-4 and 6 of the ticket; the detector's own table is test-held-answer.sh, the status page is alerts.test.js.
# Fake gh: the shared fixture (comments from gh-issue-comments-json-<n>, the issue author is the first comment's author).
# A real tick = supervisor.sh in an isolated HOME/PIPE/QUEUE with a `claude` stub that logs one line per launch. Expected values come
# from the ticket, not from the code. Placeholder repo names only.

HERE_AN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "an_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_AN/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f an_real_run_test | sed '1s/an_real_run_test/run_test/')"
fi

AN_BLK='**[fullstack-developer] BLOCKED**'
AN_GATE_URL='https://github.com/project-a/repo-a/issues/42#issuecomment-100'

# an_fixture <block class line> [<extra comment json>...] — held run #42; comments: issue opened by jp (id 1), the BLOCKED (id 100, bot),
# then the given comments (JSON objects). Slots free, claude stubbed, the answer re-check throttle off.
an_fixture() {
  local line2=$1 extra="" c; shift
  sq_env open; sq_free_slots
  printf 'ANSWERED_CHECK_SECS=0\n' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/claude.calls"\nexit 0\n' "$SQ_PIPE" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"
  : > "$SQ_PIPE/claude.calls"
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  printf 'BLOCKED\n' > "$(rkp "$SQ_PIPE/orch-42.marker")"
  for c in "$@"; do extra="$extra,$c"; done
  an_comments "$(jq -nc --arg b "$AN_BLK"$'\n'"$line2" '{id:100, body:$b, createdAt:"2026-11-19T09:00:00Z", author:{login:"bot"}}')$extra"
}
an_comments() {  # <comma separated comment objects after the opening comment>
  printf '[{"id":1,"body":"Reported by: JP","createdAt":"2026-11-19T08:00:00Z","author":{"login":"jp"}},%s]' "$1" > "$SQ_GH/gh-issue-comments-json-42"
}
an_c() {  # <id> <author> <body> → one comment object
  jq -nc --argjson i "$1" --arg a "$2" --arg b "$3" '{id:$i, body:$b, createdAt:"2026-11-19T10:00:00Z", author:{login:$a}}'
}
an_tick() { sq_run "$SUP_SQ" >/dev/null 2>&1; }
an_launches() { local i; for i in $(seq 1 100); do [ -s "$SQ_PIPE/claude.calls" ] && break; sleep 0.02; done; wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '; }
an_none() { sleep 0.3; wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '; }   # negatives: sq_run is synchronous; settle, then count
an_held() { sq_present "$(rkp "$SQ_PIPE/orch-42.held")"; }
an_guard() { cat "$(rkp "$SQ_PIPE/orch-42.answered")" 2>/dev/null | tr -d ' \n'; }

# ---- AC1: JP's [jp] GO; one launch per answer id ---------------------------------------------------------------------------------------
test_an_jp_go_after_the_hold_relaunches_once_and_records_the_answer() {
  an_fixture 'Blocked on: needs_jp — pick one' "$(an_c 105 jp '**[jp] GO**'$'\n''JP said: "go"')"
  an_tick
  local n h g log; n=$(an_launches); h=$(an_held); g=$(an_guard); log=$(sq_log)
  # second tick with the SAME answer and the hold re-created (a run that parked again on the same gate): must not launch again
  rm -f "$SQ_PIPE"/orch-*; rm -f "$SQ_PIPE"/queue/*.json; mk_held "$SQ_PIPE" 42 "$SQ_REPO"; printf '105\n' > "$(rkp "$SQ_PIPE/orch-42.answered")"
  printf 'BLOCKED\n' > "$(rkp "$SQ_PIPE/orch-42.marker")"
  : > "$SQ_PIPE/claude.calls"; an_tick
  local n2 h2; n2=$(an_none); h2=$(an_held)
  sq_cleanup
  assert_eq "$n" "1" "AC1: the first tick launches the answered ticket" || return 1
  assert_eq "$h" "absent" "AC1: .held cleared" || return 1
  assert_eq "$g" "105" "AC1: the answer comment id is recorded in orch-<rk>.answered" || return 1
  assert_contains "$log" "[answered] project-a/repo-a#42 — relaunched after GO 105" "AC6: the slog line names marker and comment id" || return 1
  assert_eq "$n2" "0" "AC1: a second tick with the same answer does not launch again" || return 1
  assert_eq "$h2" "present" "AC1: ... and leaves the hold alone" || return 1
}

test_an_a_newer_answer_to_the_same_gate_relaunches_again() {
  an_fixture 'Blocked on: needs_jp — pick one' "$(an_c 105 jp '**[jp] GO**')"
  printf '104\n' > "$(rkp "$SQ_PIPE/orch-42.answered")"   # an earlier answer (id 104, before this one) was already acted on
  an_tick
  local n; n=$(an_launches); sq_cleanup
  assert_eq "$n" "1" "an answer id above the recorded one launches" || return 1
}

# ---- AC2: JP's resolving comment and a delegate DECISION, plus the negatives -----------------------------------------------------------
test_an_jp_resolving_comment_relaunches() {
  an_fixture 'Blocked on: needs_jp — pick one' "$(an_c 105 jp 'approved - use option B')"
  an_tick; local n; n=$(an_launches); sq_cleanup
  assert_eq "$n" "1" "AC2: JP's resolving comment relaunches" || return 1
}
test_an_delegate_decision_resolving_the_blocked_comment_relaunches() {
  an_fixture 'Blocked on: other — design call' "$(an_c 110 jp "**[delivery-lead] DECISION**"$'\n'"Resolves: $AN_GATE_URL"$'\n'"use option A")"
  an_tick; local n log; n=$(an_launches); log=$(sq_log); sq_cleanup
  assert_eq "$n" "1" "AC2: DECISION + matching Resolves relaunches" || return 1
  assert_contains "$log" "relaunched after DECISION 110" "AC6: slog names the marker" || return 1
}
an_negative() {  # <label> <block line 2> <comment json...> — no launch, hold untouched, nothing recorded
  local label=$1 line2=$2; shift 2
  an_fixture "$line2" "$@"
  an_tick
  local n h g log; n=$(an_none); h=$(an_held); g=$(an_guard); log=$(sq_log); sq_cleanup
  assert_eq "$n" "0" "$label: no launch" || return 1
  assert_eq "$h" "present" "$label: still held" || return 1
  assert_eq "$g" "" "$label: nothing recorded" || return 1
  assert_not_contains "$log" "[answered]" "$label: no relaunch logged" || return 1
}
test_an_negative_decision_resolving_another_comment() {
  an_negative "DECISION for another comment" 'Blocked on: other — design call' "$(an_c 110 jp "**[delivery-lead] DECISION**"$'\n'"Resolves: https://github.com/project-a/repo-a/issues/42#issuecomment-99")" || return 1
}
test_an_negative_go_posted_before_the_blocked_marker() {
  an_fixture 'Blocked on: needs_jp — pick one'
  an_comments "$(an_c 90 jp '**[jp] GO**'),$(jq -nc --arg b "$AN_BLK"$'\nBlocked on: needs_jp — pick one' '{id:100, body:$b, createdAt:"2026-11-19T09:00:00Z", author:{login:"bot"}}')"
  an_tick; local n h; n=$(an_none); h=$(an_held); sq_cleanup
  assert_eq "$n" "0" "a GO before the BLOCKED: no launch" || return 1
  assert_eq "$h" "present" "a GO before the BLOCKED: still held" || return 1
}
test_an_negative_go_from_a_non_accepted_account() {
  an_negative "GO by a stranger" 'Blocked on: needs_jp — pick one' "$(an_c 105 stranger '**[jp] GO**')" || return 1
}
test_an_negative_plain_chatty_jp_comment() {
  an_negative "chatty JP comment" 'Blocked on: needs_jp — pick one' "$(an_c 105 jp 'thanks, looking at this tomorrow')" || return 1
}
test_an_negative_a_decision_never_answers_a_jp_only_gate() {
  an_negative "DECISION on a needs_jp BLOCKED" 'Blocked on: needs_jp — spend money' "$(an_c 110 jp "**[delivery-lead] DECISION**"$'\n'"Resolves: $AN_GATE_URL")" || return 1
}

# ---- AC3: no answer, the restart limit ------------------------------------------------------------------------------------------------
test_an_held_ticket_with_no_answer_is_untouched() {
  an_negative "no answer" 'Blocked on: needs_jp — pick one' || return 1
}
test_an_ticket_at_the_restart_limit_is_not_relaunched_and_says_why_once() {
  an_fixture 'Blocked on: needs_jp — pick one' "$(an_c 105 jp '**[jp] GO**')"
  sq_seed_restarts 3 6 BLOCKED
  an_tick; an_tick
  local n h log hits; n=$(an_none); h=$(an_held); log=$(sq_log); hits=$(printf '%s\n' "$log" | grep -c 'answer 105 not relaunched: restart limit reached')
  sq_cleanup
  assert_eq "$n" "0" "AC3: no launch at the restart limit" || return 1
  assert_eq "$h" "present" "AC3: still held" || return 1
  assert_eq "$hits" "1" "AC3: reported once, not every tick" || return 1
}

# ---- AC4: slots and SHARED_DISPATCH_ENABLED ------------------------------------------------------------------------------------------
test_an_answered_ticket_waits_in_the_queue_while_every_slot_is_busy_then_launches() {
  sq_env full
  printf 'ANSWERED_CHECK_SECS=0\n' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/claude.calls"\nexit 0\n' "$SQ_PIPE" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"; : > "$SQ_PIPE/claude.calls"
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  an_comments "$(jq -nc --arg b "$AN_BLK"$'\nBlocked on: needs_jp — pick one' '{id:100, body:$b, createdAt:"2026-11-19T09:00:00Z", author:{login:"bot"}}'),$(an_c 105 jp '**[jp] GO**')"
  an_tick
  local n h q; n=$(an_none); h=$(an_held); q=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")")
  assert_eq "$n" "0" "AC4: all slots busy: nothing launched" || { sq_cleanup; return 1; }
  assert_eq "$h" "absent" "AC4: the hold is gone (the run is queued: owned, not unowned)" || { sq_cleanup; return 1; }
  assert_eq "$q" "present" "AC4: waiting as a queue entry" || { sq_cleanup; return 1; }
  sq_free_slots; printf 'ANSWERED_CHECK_SECS=0\n' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/claude.calls"\nexit 0\n' "$SQ_PIPE" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"
  an_tick; n=$(an_launches); sq_cleanup
  assert_eq "$n" "1" "AC4: when a slot frees the queued answer launches once" || return 1
}
test_an_shared_dispatch_off_relaunches_only_feedback_tickets() {
  an_fixture 'Blocked on: needs_jp — pick one' "$(an_c 105 jp '**[jp] GO**')"
  echo 'SHARED_DISPATCH_ENABLED=0' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  an_tick
  local n log; n=$(an_none); log=$(sq_log)
  assert_eq "$n" "0" "SHARED_DISPATCH_ENABLED=0: an ordinary ticket is not relaunched" || { sq_cleanup; return 1; }
  assert_contains "$log" "answer 105 not relaunched here" "the refusal is logged" || { sq_cleanup; return 1; }
  echo '[{"name":"user-feedback"}]' > "$SQ_GH/gh-issue-labels-json"
  rm -f "$(rkp "$SQ_PIPE/orch-42.answered-skip")"
  an_tick; n=$(an_launches); sq_cleanup
  assert_eq "$n" "1" "SHARED_DISPATCH_ENABLED=0: a user-feedback ticket still relaunches" || return 1
}

# ---- reads are throttled on a repo this process has not synced ------------------------------------------------------------------------
test_an_unsynced_repo_is_read_at_most_once_per_throttle_window() {
  an_fixture 'Blocked on: needs_jp — pick one'
  sed -i.bak 's/^ANSWERED_CHECK_SECS=0$/ANSWERED_CHECK_SECS=300/' "$SQ_HOME/.claude/pipeline/config.local.sh"
  an_tick                                                   # no answer yet: reads once, stamps
  an_comments "$(jq -nc --arg b "$AN_BLK"$'\nBlocked on: needs_jp — pick one' '{id:100, body:$b, createdAt:"2026-11-19T09:00:00Z", author:{login:"bot"}}'),$(an_c 105 jp '**[jp] GO**')"
  an_tick; local n1 stamp; n1=$(an_none); stamp=$(sq_present "$(rkp "$SQ_PIPE/orch-42.answer-check")")
  rm -f "$(rkp "$SQ_PIPE/orch-42.answer-check")"
  an_tick; local n2; n2=$(an_launches); sq_cleanup
  assert_eq "$stamp" "present" "throttle stamp written" || return 1
  assert_eq "$n1" "0" "inside the window the new answer waits" || return 1
  assert_eq "$n2" "1" "after the window it is picked up" || return 1
}

# ---- AC6: a failed relaunch logs and alerts, nothing is recorded ---------------------------------------------------------------------
test_an_a_failed_relaunch_logs_alerts_slack_with_tags_and_records_nothing() {
  an_fixture 'Blocked on: needs_jp — pick one' "$(an_c 105 jp '**[jp] GO**')"
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$SQ_GH" > "$SQ_GH/curl"; chmod +x "$SQ_GH/curl"
  mkdir -p "$SQ_PIPE/queue"; chmod 555 "$SQ_PIPE/queue"   # the queue entry cannot be written
  an_tick
  chmod 755 "$SQ_PIPE/queue"
  local n h g log calls; n=$(an_none); h=$(an_held); g=$(an_guard); log=$(sq_log); calls=$(grep 'hooks.slack.test' "$SQ_GH/curl.calls" 2>/dev/null)
  sq_cleanup
  assert_eq "$n" "0" "AC6: nothing launched" || return 1
  assert_eq "$h" "present" "AC6: the hold stays so the next tick retries" || return 1
  assert_eq "$g" "" "AC6: the answer id is not recorded" || return 1
  assert_contains "$log" "[answered] project-a/repo-a#42 — relaunch after GO 105 failed" "AC6: logged" || return 1
  assert_contains "$log" "route=supervisor/answered" "AC6: route tag" || return 1
  assert_contains "$calls" "route=supervisor/answered" "AC6: Slack alert through the existing webhook" || return 1
  assert_contains "$calls" "release=" "AC6: release tag" || return 1
  assert_contains "$calls" "environment=" "AC6: environment tag" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_an_'); do run_test "$t"; done
