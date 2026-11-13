# Issue #677 Part B (7) — `pm-slack.sh poll` ends with a reminder sweep: every open ask older than 24h that was never
# reminded (and is not a mockup-skip ask) gets ONE DM for the whole sweep, one line per ask; an ask whose issue is closed is
# stored `answered` instead. An ask is reminded once in total (the flag is shared with `ask`'s own reminder).
#
# Reuses the pms_* harness of test-pm-slack.sh (fake curl = Slack, shared fake gh, fake clock FAKE_NOW=$PMS_NOW); loaded
# without running its cases when this file runs first or on its own. asks.tsv rows are written directly:
#   repo \t issue \t channel \t ts \t asked_at \t status \t reminded \t kind
# Hand arithmetic: now = PMS_T0. A asked 25h ago -> floor(25/24) = 1d; F asked 50h ago -> 2d.
# Prefix pmr_ / PMR_. Placeholder repo names only.

HERE_PMR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f pms_setup >/dev/null 2>&1; then
  eval "pmr_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_PMR/test-pm-slack.sh"
  eval "$(declare -f pmr_real_run_test | sed '1s/pmr_real_run_test/run_test/')"
fi

PMR_TAB=$(printf '\t')

# pmr_setup — pms world where an ask was already made on this host (last-read + cached DM channel), empty asks.tsv
pmr_setup() {
  pms_setup
  mkdir -p "$PMS_PIPE/pm-slack"
  echo "1699000000.000000" > "$PMS_PIPE/pm-slack/last-read"
  echo "DTEST1" > "$PMS_PIPE/pm-slack/channel"
  : > "$PMS_PIPE/pm-slack/asks.tsv"
}
pmr_cleanup() { rm -rf "$PMS_PIPE" "$PMS_HOME" "$PMS_DATA"; }
# pmr_row <repo> <issue> <hours ago> <status> <reminded> [kind]
pmr_row() {
  printf '%s\t%s\tDTEST1\t1699000000.%06d\t%s\t%s\t%s\t%s\n' "$1" "$2" "$2" "$(( PMS_T0 - $3 * 3600 ))" "$4" "$5" "${6:-}" >> "$PMS_PIPE/pm-slack/asks.tsv"
}
pmr_field() {  # <issue> <field number> — one field of the stored row
  awk -F'\t' -v i="$1" -v f="$2" '$2==i {print $f}' "$PMS_PIPE/pm-slack/asks.tsv"
}
pmr_state_reads() { pms_gh_n "issue view $1 "; }
# the ticket's rows A-E
pmr_rows_a_to_e() {
  pmr_row "$PMS_REPO_A" 41 25 open 0                 # A: due
  pmr_row "$PMS_REPO_A" 42 2 open 0                  # B: too young
  pmr_row "$PMS_REPO_A" 43 30 open 0 mockup-skip     # C: never reminded
  pmr_row "$PMS_REPO_B" 44 26 open 0                 # D: issue closed
  pmr_row "$PMS_REPO_A" 45 30 open 1                 # E: already reminded
  echo CLOSED > "$PMS_BIN/gh-issue-state-44"
}

test_pmr_sweep_reminds_only_the_due_ask_in_one_dm() {
  pmr_setup; pmr_rows_a_to_e
  pms_run poll
  local rc=$PMS_RC out=$PMS_OUT n line
  n=$(pms_n chat.postMessage); line=$(pms_lines chat.postMessage)
  local a_rem a_st b_rem c_rem d_st d_rem e_rem reads41 reads44 reads42 reads43 reads45
  a_rem=$(pmr_field 41 7); a_st=$(pmr_field 41 6); b_rem=$(pmr_field 42 7); c_rem=$(pmr_field 43 7)
  d_st=$(pmr_field 44 6); d_rem=$(pmr_field 44 7); e_rem=$(pmr_field 45 7)
  reads41=$(pmr_state_reads 41); reads44=$(pmr_state_reads 44); reads42=$(pmr_state_reads 42); reads43=$(pmr_state_reads 43); reads45=$(pmr_state_reads 45)
  pms_run poll
  local n2 reads41b; n2=$(pms_n chat.postMessage); reads41b=$(pmr_state_reads 41)
  local kind43; kind43=$(pmr_field 43 8)
  pmr_cleanup
  assert_exit0 "$rc" "poll exits 0 ($out)" || return 1
  assert_eq "$n" "1" "exactly one chat.postMessage for the whole sweep" || return 1
  assert_contains "$line" "Still waiting on your answer:" "the DM heading" || return 1
  assert_contains "$line" "#41 · project-a — waiting 1d — https://github.com/$PMS_REPO_A/issues/41" "one line for ask A, as the ticket words it" || return 1
  assert_contains "$line" "Reply here with #<issue> and your answer." "the DM ending" || return 1
  assert_contains "$line" "DTEST1" "posted into the DM channel" || return 1
  assert_not_contains "$line" "thread_ts" "top-level, never a thread" || return 1
  local other; for other in 42 43 44 45; do assert_not_contains "$line" "#$other" "the DM names only A (not #$other)" || return 1; done
  assert_eq "$a_rem" "1" "A stored reminded=1" || return 1
  assert_eq "$a_st" "open" "A stays open" || return 1
  assert_eq "$d_st" "answered" "D (issue closed) stored answered" || return 1
  assert_eq "$d_rem" "0" "D was not reminded" || return 1
  assert_eq "$b_rem" "0" "B (2h) untouched" || return 1
  assert_eq "$c_rem" "0" "C (mockup-skip) untouched" || return 1
  assert_eq "$kind43" "mockup-skip" "C keeps its kind" || return 1
  assert_eq "$e_rem" "1" "E unchanged" || return 1
  assert_eq "$reads41" "1" "A: the issue state is read once" || return 1
  assert_eq "$reads44" "1" "D: the issue state is read once" || return 1
  assert_eq "$reads42$reads43$reads45" "000" "rows that are not due cost no issue read" || return 1
  assert_eq "$n2" "1" "a second poll posts nothing (an ask is reminded once)" || return 1
  assert_eq "$reads41b" "1" "a second poll reads no issue state for a reminded ask" || return 1
}

test_pmr_two_due_asks_share_one_dm() {
  pmr_setup
  pmr_row "$PMS_REPO_A" 41 25 open 0
  pmr_row "$PMS_REPO_B" 46 50 open 0
  pms_run poll
  local n line r41 r46; n=$(pms_n chat.postMessage); line=$(pms_lines chat.postMessage); r41=$(pmr_field 41 7); r46=$(pmr_field 46 7)
  pmr_cleanup
  assert_eq "$n" "1" "two due asks -> still one DM" || return 1
  assert_contains "$line" "#41 · project-a — waiting 1d — https://github.com/$PMS_REPO_A/issues/41" "line for #41" || return 1
  assert_contains "$line" "#46 · project-b — waiting 2d — https://github.com/$PMS_REPO_B/issues/46" "line for #46 (50h = 2d)" || return 1
  assert_eq "$r41$r46" "11" "both stored reminded=1" || return 1
}

test_pmr_nothing_due_posts_nothing() {
  pmr_setup
  pmr_row "$PMS_REPO_A" 42 23 open 0
  pmr_row "$PMS_REPO_A" 47 40 answered 0
  pms_run poll
  local n reads; n=$(pms_n chat.postMessage); reads=$(pms_gh_n "issue view")
  pmr_cleanup
  assert_eq "$n" "0" "23h-old ask and an answered ask: no reminder" || return 1
  assert_eq "$reads" "0" "no issue read when nothing is due" || return 1
}

test_pmr_slack_failure_leaves_the_ask_unreminded_and_logs_tags() {
  pmr_setup; pmr_rows_a_to_e
  touch "$PMS_DATA/fail-chat.postMessage"
  pms_run poll
  local out=$PMS_OUT a_rem d_st; a_rem=$(pmr_field 41 7); d_st=$(pmr_field 44 6)
  rm -f "$PMS_DATA/fail-chat.postMessage"
  pms_run poll
  local a_rem2 n2; a_rem2=$(pmr_field 41 7); n2=$(grep -c '^chat.postMessage ' "$PMS_DATA/calls.log")
  pmr_cleanup
  assert_eq "$a_rem" "0" "failed Slack post: A stays reminded=0" || return 1
  assert_eq "$d_st" "answered" "the closed issue is still stored answered" || return 1
  local line; line=$(printf '%s\n' "$out" | grep -F 'route=pm-slack/remind' | head -1)
  assert_ne "$line" "" "a tagged stderr line for the failed reminder ($out)" || return 1
  assert_contains "$line" "environment=" "environment tag" || return 1
  case "$line" in *release=unknown*) fail "release must be the commit SHA: $line"; return 1 ;; esac
  assert_contains "$line" "release=" "release tag" || return 1
  assert_not_contains "$out" "fake-not-a-real-token" "the token is never printed" || return 1
  assert_not_contains "$line" "Blocked" "the ask text is never in the tagged line" || return 1
  assert_eq "$a_rem2" "1" "the next poll retries and reminds" || return 1
  assert_eq "$n2" "2" "one failed post + one successful retry" || return 1
}

# the alert path is the existing Slack webhook: one alert per failure streak (never one per 2-minute poll), tags only
test_pmr_slack_failure_alerts_the_webhook_once_per_streak() {
  pmr_setup
  pmr_row "$PMS_REPO_A" 41 25 open 0
  # the fake curl logs any slack.com/api/<method> URL: this webhook URL shows up as method "webhook-alert"
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.com/api/webhook-alert"' >> "$PMS_HOME/.claude/pipeline/config.local.sh"
  touch "$PMS_DATA/fail-chat.postMessage"
  pms_run poll; pms_run poll
  local n line; n=$(pms_n webhook-alert); line=$(pms_lines webhook-alert | head -1)
  rm -f "$PMS_DATA/fail-chat.postMessage"
  pms_run poll
  touch "$PMS_DATA/fail-chat.postMessage"
  pmr_row "$PMS_REPO_A" 48 25 open 0
  pms_run poll
  local n2; n2=$(pms_n webhook-alert)
  pmr_cleanup
  assert_eq "$n" "1" "two failing polls in a row: one webhook alert" || return 1
  assert_contains "$line" "route=pm-slack/remind" "alert carries the route tag" || return 1
  assert_contains "$line" "release=" "alert carries the release tag" || return 1
  assert_contains "$line" "environment=" "alert carries the environment tag" || return 1
  assert_not_contains "$line" "#41" "no ask in the alert" || return 1
  assert_eq "$n2" "2" "a new failure streak after a delivered reminder alerts again" || return 1
}

test_pmr_unreadable_issue_state_is_not_reminded_this_poll() {
  pmr_setup
  pmr_row "$PMS_REPO_A" 41 25 open 0
  echo 1 > "$PMS_BIN/gh-issue-view-rc-41"
  pms_run poll
  local n a_rem a_st; n=$(pms_n chat.postMessage); a_rem=$(pmr_field 41 7); a_st=$(pmr_field 41 6)
  pmr_cleanup
  assert_eq "$n" "0" "state unknown: no reminder this poll" || return 1
  assert_eq "$a_rem" "0" "state unknown: retried next poll" || return 1
  assert_eq "$a_st" "open" "state unknown: never rewritten answered" || return 1
}

# the flag is shared with `ask`: after the sweep reminded an ask, `ask` on the same issue never posts a second reminder
test_pmr_ask_after_a_sweep_reminder_does_not_remind_again() {
  pmr_setup
  pmr_row "$PMS_REPO_A" 41 25 open 0
  pms_run poll
  local n1; n1=$(pms_n chat.postMessage)
  pms_ask "$PMS_REPO_A" 41 "Blocked: pick A or B. Recommend A."
  local n2 rem; n2=$(pms_n chat.postMessage); rem=$(pmr_field 41 7)
  pmr_cleanup
  assert_eq "$n1" "1" "control: the sweep reminded once" || return 1
  assert_eq "$n2" "1" "ask after the sweep posts no second reminder" || return 1
  assert_eq "$rem" "1" "flag still 1" || return 1
}
# ... and the other way round: an ask that `ask` already reminded is skipped by the sweep (row E, asserted above), and an
# ask the sweep has not reached is still reminded by `ask` itself, once
test_pmr_ask_own_reminder_still_works_and_blocks_the_sweep() {
  pmr_setup
  pmr_row "$PMS_REPO_A" 41 25 open 0
  pms_ask "$PMS_REPO_A" 41 "Blocked: pick A or B. Recommend A."
  local n1 rem line; n1=$(pms_n chat.postMessage); rem=$(pmr_field 41 7); line=$(pms_lines chat.postMessage)
  pms_run poll
  local n2; n2=$(pms_n chat.postMessage)
  pmr_cleanup
  assert_eq "$n1" "1" "ask's own 24h reminder is posted" || return 1
  assert_contains "$line" "Reminder: still waiting on your answer" "ask's reminder wording is unchanged" || return 1
  assert_eq "$rem" "1" "stored reminded=1" || return 1
  assert_eq "$n2" "1" "the sweep does not remind it a second time" || return 1
}

run_test test_pmr_sweep_reminds_only_the_due_ask_in_one_dm
run_test test_pmr_two_due_asks_share_one_dm
run_test test_pmr_nothing_due_posts_nothing
run_test test_pmr_slack_failure_leaves_the_ask_unreminded_and_logs_tags
run_test test_pmr_slack_failure_alerts_the_webhook_once_per_streak
run_test test_pmr_unreadable_issue_state_is_not_reminded_this_poll
run_test test_pmr_ask_after_a_sweep_reminder_does_not_remind_again
run_test test_pmr_ask_own_reminder_still_works_and_blocks_the_sweep
