# Issue #677 Part B (8) — a run parked `.held` with a "waiting on JP" alert for at least JP_GATE_REMIND_SECS (86400) gets ONE
# #engineering reminder (notify_engineering, ":hand:", "Reminder — still waiting on you (<N>d): <gate reason>") and a stamp
# orch-<rk>.jp-reminded. One reminder per hold; none for a parked auto-retry hold; none while this host's asks.tsv has an open
# ask for the same repo and issue (the pm-slack DM sweep covers it). Local state only.
#
# Whole supervisor ticks in the sq_* harness (test-supervisor-queued-not-counted.sh). Slack is a fake curl that appends each
# -d payload as one line to $SQ_GH/slack-payloads and answers {"ok":true} ({"ok":false} while $SQ_GH/slack-fail exists).
# Prefix jgr_ / JGR_. Placeholder repo names only.

HERE_JGR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "jgr_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_JGR/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f jgr_real_run_test | sed '1s/jgr_real_run_test/run_test/')"
fi

JGR_GATE='**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'
JGR_ALERT_JP="2026-11-01T00:00:00Z Pipeline #42 waiting on JP — $JGR_GATE; relaunch (or re-add agent-go) after acting"

# jgr_fixture <alert text> <hours held> — run #42 held with that alert; .held and .alert are both <hours> old
jgr_fixture() {
  sq_env open
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  sq_marker "$JGR_GATE"
  printf '%s\n' "$1" > "$(rkp "$SQ_PIPE/orch-42.alert")"
  jgr_age held "$2"; jgr_age alert "$2"
  cat > "$SQ_GH/curl" <<'CURL'
#!/bin/bash
D=$(dirname "$0")
while [ $# -gt 0 ]; do [ "$1" = -d ] && printf '%s\n' "$2" | tr '\n' ' ' >> "$D/slack-payloads" && echo >> "$D/slack-payloads"; shift; done
if [ -f "$D/slack-fail" ]; then echo '{"ok":false,"error":"channel_not_found"}'; else echo '{"ok":true}'; fi
CURL
  chmod +x "$SQ_GH/curl"
  : > "$SQ_GH/slack-payloads"
}
jgr_age() {  # <suffix> <hours> — backdate orch-42.<suffix>
  python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*3600; os.utime(sys.argv[1],(t,t))' "$(rkp "$SQ_PIPE/orch-42.$1")" "$2"
}
jgr_tick() {
  HOME="$SQ_HOME" PATH="$SQ_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SQ_PIPE" QUEUE="$SQ_PIPE/queue" LOGDIR="$SQ_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="fake-credential-for-tests-only" SLACK_ENGINEERING_CHANNEL="C0TEST" "$SUP_SQ" >/dev/null 2>&1
}
jgr_reminders() { grep -c 'Reminder' "$SQ_GH/slack-payloads" 2>/dev/null || true; }
jgr_payload() { grep 'Reminder' "$SQ_GH/slack-payloads" 2>/dev/null | head -1; }
jgr_stamp() { sq_present "$(rkp "$SQ_PIPE/orch-42.jp-reminded")"; }
jgr_ask() {  # <repo> <issue> <status> — one row in this host's asks.tsv
  mkdir -p "$SQ_PIPE/pm-slack"
  printf '%s\t%s\tDTEST1\t1700000001.000100\t1700000000\t%s\t0\t\n' "$1" "$2" "$3" >> "$SQ_PIPE/pm-slack/asks.tsv"
}

test_jgr_held_25h_waiting_on_jp_gets_one_reminder() {
  jgr_fixture "$JGR_ALERT_JP" 25
  jgr_tick
  local n p stamp held gh_before; n=$(jgr_reminders); p=$(jgr_payload); stamp=$(jgr_stamp); held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")")
  jgr_tick; jgr_tick
  local n2; n2=$(jgr_reminders)
  sq_cleanup
  assert_eq "$n" "1" "one reminder payload" || return 1
  assert_contains "$p" ":hand:" "the :hand: emoji" || return 1
  assert_contains "$p" "Reminder — still waiting on you (1d): $JGR_GATE" "wording: days held and the gate reason" || return 1
  assert_contains "$p" "https://github.com/project-a/repo-a/issues/42" "links the issue in its repo" || return 1
  assert_contains "$p" "C0TEST" "posted to the engineering channel" || return 1
  assert_not_contains "$p" "relaunch (or re-add" "the alert's relaunch hint is not part of the reason" || return 1
  assert_not_contains "$p" "fake-credential-for-tests-only" "no token in the payload" || return 1
  assert_eq "$stamp" "present" "orch-<rk>.jp-reminded written" || return 1
  assert_eq "$held" "present" "the run stays held" || return 1
  assert_eq "$n2" "1" "next ticks send no second reminder (one per hold)" || return 1
}

test_jgr_held_2h_gets_no_reminder() {
  jgr_fixture "$JGR_ALERT_JP" 2
  jgr_tick
  local n stamp; n=$(jgr_reminders); stamp=$(jgr_stamp); sq_cleanup
  assert_eq "$n" "0" "2h old: no reminder" || return 1
  assert_eq "$stamp" "absent" "2h old: no stamp" || return 1
}

test_jgr_parked_auto_retry_hold_gets_no_reminder() {
  jgr_fixture "2026-11-01T00:00:00Z Pipeline #42 parked, auto-retry (ci_red) — **[fullstack-developer] BLOCKED**" 25
  jgr_tick
  local n stamp; n=$(jgr_reminders); stamp=$(jgr_stamp); sq_cleanup
  assert_eq "$n" "0" "parked, auto-retry: not a JP gate, no reminder" || return 1
  assert_eq "$stamp" "absent" "no stamp" || return 1
}

test_jgr_hold_without_alert_gets_no_reminder() {
  jgr_fixture "$JGR_ALERT_JP" 25
  rm -f "$(rkp "$SQ_PIPE/orch-42.alert")"   # e.g. a structural or loop-cap hold
  jgr_tick
  local n; n=$(jgr_reminders); sq_cleanup
  assert_eq "$n" "0" "no 'waiting on JP' alert: no reminder" || return 1
}

test_jgr_open_ask_for_the_issue_suppresses_the_reminder() {
  jgr_fixture "$JGR_ALERT_JP" 25
  jgr_ask project-a/repo-a 42 open
  jgr_tick
  local n stamp; n=$(jgr_reminders); stamp=$(jgr_stamp); sq_cleanup
  assert_eq "$n" "0" "an open ask for the same repo and issue: the DM covers it" || return 1
  assert_eq "$stamp" "absent" "skipped, not consumed" || return 1
}

test_jgr_other_asks_do_not_suppress_the_reminder() {
  jgr_fixture "$JGR_ALERT_JP" 25
  jgr_ask project-a/repo-a 42 answered     # answered: no longer covered by the DM sweep
  jgr_ask project-b/repo-b 42 open          # same number, another repo
  jgr_ask project-a/repo-a 43 open          # same repo, another issue
  jgr_tick
  local n; n=$(jgr_reminders); sq_cleanup
  assert_eq "$n" "1" "only an open ask for this repo AND issue suppresses" || return 1
}

test_jgr_spend_hold_and_ci_handoff_are_reminded_with_their_reason() {
  jgr_fixture "2026-11-01T00:00:00Z Pipeline #42 waiting on JP — monthly spend limit reached; relaunch after credits or a model switch" 49
  jgr_tick
  local p1; p1=$(jgr_payload); sq_cleanup
  jgr_fixture "2026-11-01T00:00:00Z Pipeline #42 waiting on JP — **[fullstack-developer] BLOCKED** — finished red (real failure); relaunch (or re-add agent-go) after acting" 25
  jgr_tick
  local p2; p2=$(jgr_payload); sq_cleanup
  assert_contains "$p1" "Reminder — still waiting on you (2d): monthly spend limit reached" "spend hold: 49h = 2d, its own reason" || return 1
  assert_contains "$p2" "Reminder — still waiting on you (1d): **[fullstack-developer] BLOCKED** — finished red (real failure)" "#484 hand-off reason" || return 1
}

# the wait is counted from the newer of .held and the "waiting on JP" alert: a hold handed to JP an hour ago is not "25h waiting"
test_jgr_alert_newer_than_the_hold_counts_from_the_alert() {
  jgr_fixture "$JGR_ALERT_JP" 25
  jgr_age alert 1
  jgr_tick
  local n; n=$(jgr_reminders); sq_cleanup
  assert_eq "$n" "0" "handed to JP 1h ago: no reminder yet" || return 1
}

# one reminder per HOLD: a stamp left by an earlier hold (older than this hold) does not silence the new one
test_jgr_stamp_from_an_earlier_hold_does_not_silence_a_new_hold() {
  jgr_fixture "$JGR_ALERT_JP" 25
  : > "$(rkp "$SQ_PIPE/orch-42.jp-reminded")"; jgr_age jp-reminded 80
  jgr_tick
  local n; n=$(jgr_reminders)
  jgr_tick
  local n2; n2=$(jgr_reminders); sq_cleanup
  assert_eq "$n" "1" "new hold: reminded" || return 1
  assert_eq "$n2" "1" "and only once" || return 1
}

test_jgr_failed_post_is_logged_with_tags_and_retried_after_the_throttle() {
  jgr_fixture "$JGR_ALERT_JP" 25
  touch "$SQ_GH/slack-fail"
  jgr_tick
  local n1 log line; n1=$(jgr_reminders); log=$(sq_log)
  jgr_tick
  local n2; n2=$(jgr_reminders)
  rm -f "$SQ_GH/slack-fail"; jgr_age jp-reminded 0.6   # 36 min: past the 1800 s retry throttle
  jgr_tick
  local n3; n3=$(jgr_reminders)
  jgr_tick
  local n4; n4=$(jgr_reminders)
  sq_cleanup
  line=$(printf '%s\n' "$log" | grep -F 'route=supervisor/jp-gate-remind' | head -1)
  assert_eq "$n1" "1" "control: the reminder was attempted" || return 1
  assert_ne "$line" "" "the failed post is logged with the route tag" || return 1
  assert_contains "$line" "#42" "names the issue" || return 1
  assert_contains "$line" "release=" "release tag" || return 1
  assert_contains "$line" "environment=" "environment tag" || return 1
  assert_not_contains "$line" "fake-credential-for-tests-only" "no token in the log line" || return 1
  assert_eq "$n2" "1" "not retried on the very next tick" || return 1
  assert_eq "$n3" "2" "retried once the throttle has passed" || return 1
  assert_eq "$n4" "2" "and never again after it was delivered" || return 1
}

test_jgr_ac7_config_defines_the_reminder_delay() {
  assert_eq "$(grep -c '^JP_GATE_REMIND_SECS=86400' "$HERE_JGR/../config.sh")" "1" "AC7: config.sh defines JP_GATE_REMIND_SECS=86400" || return 1
}

run_test test_jgr_held_25h_waiting_on_jp_gets_one_reminder
run_test test_jgr_held_2h_gets_no_reminder
run_test test_jgr_parked_auto_retry_hold_gets_no_reminder
run_test test_jgr_hold_without_alert_gets_no_reminder
run_test test_jgr_open_ask_for_the_issue_suppresses_the_reminder
run_test test_jgr_other_asks_do_not_suppress_the_reminder
run_test test_jgr_spend_hold_and_ci_handoff_are_reminded_with_their_reason
run_test test_jgr_alert_newer_than_the_hold_counts_from_the_alert
run_test test_jgr_stamp_from_an_earlier_hold_does_not_silence_a_new_hold
run_test test_jgr_failed_post_is_logged_with_tags_and_retried_after_the_throttle
run_test test_jgr_ac7_config_defines_the_reminder_delay
