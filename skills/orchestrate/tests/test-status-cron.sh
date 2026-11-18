# Issue #756 — the beat payload's optional `cron[]` (the host user's crontab jobs): parsing, privacy,
# last run/result from ~/logs/<job>/, next_run, the write-budget hash, and the failure path (a broken
# crontab read never fails the beat and is alerted through the existing Slack webhook).
#
# Exercised through `report-status.sh --print` (no network) and, for the push/alert cases, a full
# `report-status.sh event` run with stub curl. STATUS_CRON_CMD points the reader at a fixture instead of
# the real `crontab -l`; TZ=UTC and STATUS_CRON_NOW pin "now" (2026-11-19T10:00:00Z, a Thursday), so every
# expected next_run below is hand-computed from the calendar, never from the code under test.

HERE_C756=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_C756="$HERE_C756/.."
C756_NOW=1795082400   # 2026-11-19T10:00:00Z (Thursday)
C756_PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# c756_print <pipe> <home> <crontab-cmd...> -> the printed payload (TZ=UTC, pinned clock)
c756_print() {
  local pipe=$1 home=$2; shift 2
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" TZ=UTC STATUS_CRON_NOW=$C756_NOW STATUS_CRON_CMD="$*" \
      "$RS_C756/report-status.sh" --print )
}

# c756_crontab <dir> <text> -> path of a crontab fixture file
c756_crontab() {
  printf '%s\n' "$2" > "$1/crontab.txt"
  printf '%s' "$1/crontab.txt"
}

# c756_log <home> <job> <file> <epoch> <text> — a log file with a fixed mtime
c756_log() {
  mkdir -p "$1/logs/$2"
  printf '%s\n' "$5" > "$1/logs/$2/$3"
  python3 -c "import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))" "$1/logs/$2/$3" "$4"
}

c756_job() {  # c756_job <json> <name> <field>
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" '.cron[]? | select(.name==$n) | .[$f] | if . == null then "null" else tostring end'
}

test_cron_privacy_only_basename_and_schedule_published() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  ct=$(c756_crontab "$pipe" '0 13 * * 1 TOKEN=abc123 /home/u/bin/layoff-scan-cron.sh --key sk-xyz >> ~/logs/x.log 2>&1')
  out=$(c756_print "$pipe" "$home" cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq -c '.cron | length')" "1" "AC3: one job parsed" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.cron[0].name')" "layoff-scan-cron" "AC3: name is the script basename without extension" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.cron[0].schedule')" "0 13 * * 1" "AC1: raw 5-field schedule" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.cron[0].schedule_human')" "Mondays at 13:00" "AC1: human schedule" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.cron[0] | keys')" '["last_result","last_run","name","next_run","schedule","schedule_human","source"]' "AC1: exactly the documented keys (description only when the script has a readable header comment)" || return 1
  assert_not_contains "$out" "abc123" "AC3: env assignment value never published" || return 1
  assert_not_contains "$out" "sk-xyz" "AC3: argument value never published" || return 1
  assert_not_contains "$out" "/home/u" "AC3: no path published" || return 1
  assert_not_contains "$out" "--key" "AC3: no argument published" || return 1
  assert_not_contains "$out" ">>" "AC3: no redirection published" || return 1
}

test_cron_parsing_skips_comments_blanks_env_and_malformed_lines() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  ct=$(c756_crontab "$pipe" '# a comment
MAILTO=someone@example.test
SHELL=/bin/bash

*/5 * * * * cd /srv/app && timeout 30 ./tick.py
30 8,20 * * 1-5 /usr/bin/python3 /opt/foo/report.py | mail -s x someone
@reboot /home/u/boot.sh
@daily nice -n 5 cleanup
this is not a cron line
61 * * * * out-of-range.sh
0 0 29 2 * leap.sh
0 9 1,15 * * monthly.sh
0 6 * * * bash -lc '"'"'cd ~/x && ./nightly.sh >> ~/logs/n.log 2>&1'"'"'')
  out=$(c756_print "$pipe" "$home" cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq -c '[.cron[].name]')" '["tick","report","boot","cleanup","leap","monthly","nightly"]' "AC4: comments/blank/env/malformed/out-of-range skipped, order kept; bash -lc '...' wrapper resolved" || return 1
  assert_not_contains "$out" "~/logs" "AC3: no path from a wrapped command published" || return 1
  assert_not_contains "$out" "cd " "AC3: no command text from a wrapped command published" || return 1
  assert_eq "$(c756_job "$out" tick schedule_human)" "Every 5 minutes" "human: */5" || return 1
  assert_eq "$(c756_job "$out" report schedule_human)" "Weekdays at 08:30 and 20:30" "human: weekdays, two times" || return 1
  assert_eq "$(c756_job "$out" boot schedule)" "@reboot" "AC4: @reboot schedule kept" || return 1
  assert_eq "$(c756_job "$out" boot next_run)" "null" "AC4: @reboot has no next_run" || return 1
  assert_eq "$(c756_job "$out" cleanup schedule)" "@daily" "AC4: @daily kept" || return 1
  assert_eq "$(c756_job "$out" cleanup schedule_human)" "Daily at 00:00" "human: @daily" || return 1
  assert_eq "$(c756_job "$out" monthly schedule_human)" "Monthly on day 1 and 15 at 09:00" "human: monthly list" || return 1
}

test_cron_next_run_hand_computed_utc() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  ct=$(c756_crontab "$pipe" '0 13 * * 1 mon.sh
*/5 * * * * tick.sh
30 8,20 * * 1-5 report.sh
@daily daily.sh
0 0 29 2 * leap.sh
0 12 1,15 * 1 either.sh
0 9 * * 7 sunday.sh')
  out=$(c756_print "$pipe" "$home" cat "$ct")
  rm -rf "$pipe" "$home"
  # now = Thu 2026-11-19 10:00:00Z
  assert_eq "$(c756_job "$out" mon next_run)" "2026-11-23T13:00:00Z" "next Monday 13:00" || return 1
  assert_eq "$(c756_job "$out" tick next_run)" "2026-11-19T10:05:00Z" "strictly after now: 10:05" || return 1
  assert_eq "$(c756_job "$out" report next_run)" "2026-11-19T20:30:00Z" "Thursday 08:30 has passed, 20:30 is next" || return 1
  assert_eq "$(c756_job "$out" daily next_run)" "2026-11-20T00:00:00Z" "@daily -> next midnight" || return 1
  assert_eq "$(c756_job "$out" leap next_run)" "2028-02-29T00:00:00Z" "29 Feb -> next leap year" || return 1
  assert_eq "$(c756_job "$out" either next_run)" "2026-11-23T12:00:00Z" "day-of-month AND day-of-week both set -> either matches (Mon 23 Nov before 1 Dec)" || return 1
  assert_eq "$(c756_job "$out" sunday next_run)" "2026-11-22T09:00:00Z" "day of week 7 is Sunday" || return 1
}

test_cron_next_run_uses_the_vm_timezone_then_emits_utc() {
  local pipe home out ct
  pipe=$(new_pipe); home=$(new_home)
  ct=$(c756_crontab "$pipe" '0 13 * * 1 mon.sh')
  out=$( ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" TZ=America/Toronto STATUS_CRON_NOW=$C756_NOW STATUS_CRON_CMD="cat $ct" \
      "$RS_C756/report-status.sh" --print ) )
  rm -rf "$pipe" "$home"
  # Mon 2026-11-23 13:00 EST (UTC-5) = 18:00Z
  assert_eq "$(c756_job "$out" mon next_run)" "2026-11-23T18:00:00Z" "13:00 Toronto time is 18:00Z in November" || return 1
}

test_cron_capped_at_50_jobs() {
  local pipe home out ct text i
  pipe=$(new_pipe); home=$(new_home)
  text=""
  for i in $(seq 1 60); do text="$text
0 1 * * * job$i.sh"; done
  ct=$(c756_crontab "$pipe" "$text")
  out=$(c756_print "$pipe" "$home" cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq '.cron | length')" "50" "AC4: capped at 50 jobs" || return 1
  assert_eq "$(c756_job "$out" job50 name)" "job50" "AC4: the first 50 are kept" || return 1
  assert_eq "$(c756_job "$out" job51 name)" "" "AC4: the 51st is dropped" || return 1
}

test_cron_last_result_from_log_dirs() {
  local pipe home out ct t1 t2
  pipe=$(new_pipe); home=$(new_home)
  t1=1795000000; t2=1795050000   # 2026-11-18T11:06:40Z and 2026-11-19T01:00:00Z
  ct=$(c756_crontab "$pipe" '0 1 * * * okjob.sh
0 1 * * * errjob.sh
0 1 * * * exitjob.sh
0 1 * * * exitzero.sh
0 1 * * * nolog.sh
0 1 * * * emptydir.sh
0 1 * * * newestok.sh
0 1 * * * oldfail.sh')
  c756_log "$home" okjob run.log "$t1" "started
finished fine"
  c756_log "$home" errjob run.log "$t1" "started
ERROR: SECRETLOGTEXT blew up"
  c756_log "$home" exitjob run.log "$t1" "started
exit=2"
  c756_log "$home" exitzero run.log "$t1" "done
exit code: 0"
  mkdir -p "$home/logs/emptydir"
  c756_log "$home" newestok old.log "$t1" "Traceback (most recent call last)"
  c756_log "$home" newestok new.log "$t2" "all good"
  # a failure marker older than the last 50 lines does not count
  c756_log "$home" oldfail run.log "$t2" "$(printf 'fatal: early\n'; for i in $(seq 1 60); do echo "line $i"; done)"
  out=$(c756_print "$pipe" "$home" cat "$ct")
  rm -rf "$pipe" "$home"
  assert_eq "$(c756_job "$out" okjob last_result)" "ok" "AC2: clean log -> ok" || return 1
  assert_eq "$(c756_job "$out" okjob last_run)" "2026-11-18T11:06:40Z" "AC2: last_run is the newest file mtime (UTC, Z form)" || return 1
  assert_eq "$(c756_job "$out" errjob last_result)" "failed" "AC2: error line in the tail -> failed" || return 1
  assert_eq "$(c756_job "$out" exitjob last_result)" "failed" "AC2: non-zero exit marker -> failed" || return 1
  assert_eq "$(c756_job "$out" exitzero last_result)" "ok" "AC2: zero exit marker -> ok" || return 1
  assert_eq "$(c756_job "$out" nolog last_result)" "unknown" "AC2: no log dir -> unknown" || return 1
  assert_eq "$(c756_job "$out" nolog last_run)" "null" "AC2: no log dir -> last_run null" || return 1
  assert_eq "$(c756_job "$out" emptydir last_result)" "unknown" "AC2: log dir with no files -> unknown" || return 1
  assert_eq "$(c756_job "$out" newestok last_result)" "ok" "AC2: only the newest file counts" || return 1
  assert_eq "$(c756_job "$out" newestok last_run)" "2026-11-19T01:00:00Z" "AC2: newest file mtime" || return 1
  assert_eq "$(c756_job "$out" oldfail last_result)" "ok" "AC2: only the last 50 lines count" || return 1
  assert_not_contains "$out" "SECRETLOGTEXT" "AC3: log content never published" || return 1
  assert_not_contains "$out" "$home" "AC3: no file path published" || return 1
}

test_cron_failing_crontab_read_omits_key_and_never_fails() {
  local pipe home out rc
  pipe=$(new_pipe); home=$(new_home)
  out=$(c756_print "$pipe" "$home" /bin/false)
  rc=$?
  rm -rf "$pipe" "$home"
  assert_exit0 "$rc" "AC4: a failing crontab read does not fail the reporter" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.v')" "1" "AC4: the payload is still built" || return 1
  assert_eq "$(printf '%s' "$out" | jq 'has("cron")')" "false" "AC4: cron key omitted on a read failure" || return 1
}

test_cron_empty_and_no_crontab_omit_key() {
  local pipe home out out2 ct
  pipe=$(new_pipe); home=$(new_home)
  ct=$(c756_crontab "$pipe" '# nothing scheduled')
  out=$(c756_print "$pipe" "$home" cat "$ct")
  printf '#!/bin/bash\necho "no crontab for someone" >&2\nexit 1\n' > "$pipe/nocrontab"; chmod +x "$pipe/nocrontab"
  out2=$(c756_print "$pipe" "$home" "$pipe/nocrontab")
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq 'has("cron")')" "false" "AC4: no jobs -> no cron key" || return 1
  assert_eq "$(printf '%s' "$out2" | jq 'has("cron")')" "false" "AC4: 'no crontab for user' -> no cron key" || return 1
}

# ---- full runs (stub curl): the alert path and the write-budget hash -----------------------------------------

c756_fixture() {  # c756_fixture <pipe> <home> <bindir> -> pushable host, stub curl logging args (+ the push body)
  local pipe=$1 home=$2 bindir=$3
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"
EOF
  mk_running "$pipe" 756 "$pipe/repo-project-a"
  cat > "$bindir/curl" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
echo "CALL $*" >> "$d/calls"
case "$*" in *"@-"*) cat > "$d/push.body"; printf 204 ;; esac
exit 0
EOF
  chmod +x "$bindir/curl"
}

c756_run() {  # c756_run <pipe> <home> <bindir> <crontab cmd...>
  local pipe=$1 home=$2 bindir=$3; shift 3
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" TZ=UTC STATUS_CRON_NOW=$C756_NOW STATUS_CRON_CMD="$*" \
      PATH="$bindir:$C756_PATH" "$RS_C756/report-status.sh" event )
}

c756_count() {  # c756_count <bindir> <pattern> -> number of recorded curl calls matching
  grep -c -- "$2" "$1/calls" 2>/dev/null || true
}

test_cron_failing_read_still_pushes_and_alerts_with_tags_only() {
  local pipe home bindir calls rc
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  c756_fixture "$pipe" "$home" "$bindir"
  printf '#!/bin/bash\necho "boom TOPSECRETCRONTEXT" >&2\nexit 3\n' > "$pipe/badcrontab"; chmod +x "$pipe/badcrontab"
  c756_run "$pipe" "$home" "$bindir" "$pipe/badcrontab"; rc=$?
  calls=$(cat "$bindir/calls" 2>/dev/null)
  local body; body=$(cat "$bindir/push.body" 2>/dev/null)
  cleanup_running
  local slack; slack=$(grep 'hooks.slack.test' "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$home" "$bindir"
  assert_exit0 "$rc" "AC12: reporter exits 0" || return 1
  assert_contains "$calls" "example.invalid/beat" "AC4: the beat is still pushed" || return 1
  assert_eq "$(printf '%s' "$body" | jq -r '.v')" "1" "AC4: pushed payload is a valid v1 payload" || return 1
  assert_eq "$(printf '%s' "$body" | jq 'has("cron")')" "false" "AC4: pushed payload omits cron" || return 1
  assert_contains "$slack" "route=status-reporter/cron" "AC12: alert carries the route tag" || return 1
  assert_contains "$slack" "release=" "AC12: alert carries the release tag" || return 1
  assert_contains "$slack" "environment=" "AC12: alert carries the environment tag" || return 1
  assert_not_contains "$calls" "TOPSECRETCRONTEXT" "AC12: crontab/stderr text never reaches the alert or the beat" || return 1
  assert_not_contains "$body" "TOPSECRETCRONTEXT" "AC12: nor the pushed payload" || return 1
  assert_not_contains "$slack" "fake-token-for-test-only" "AC12: push token never in the alert" || return 1
}

test_cron_failure_alert_is_throttled_and_clears_after_recovery() {
  local pipe home bindir ct n1 n2 n3
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  c756_fixture "$pipe" "$home" "$bindir"
  ct=$(c756_crontab "$pipe" '0 1 * * * a.sh')
  c756_run "$pipe" "$home" "$bindir" /bin/false
  n1=$(c756_count "$bindir" route=status-reporter/cron)
  c756_run "$pipe" "$home" "$bindir" /bin/false
  n2=$(c756_count "$bindir" route=status-reporter/cron)
  c756_run "$pipe" "$home" "$bindir" cat "$ct"      # recovered -> state cleared
  c756_run "$pipe" "$home" "$bindir" /bin/false     # fails again -> alerts again
  n3=$(c756_count "$bindir" route=status-reporter/cron)
  cleanup_running; rm -rf "$pipe" "$home" "$bindir"
  assert_eq "$n1" "1" "AC12: first failure alerts once" || return 1
  assert_eq "$n2" "1" "AC12: a repeat failure inside the throttle window does not alert again" || return 1
  assert_eq "$n3" "2" "AC12: a failure after a clean collection alerts again" || return 1
}

test_cron_drifting_last_run_and_next_run_do_not_change_the_push_hash() {
  local pipe home bindir ct t n1 n2 n3
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  c756_fixture "$pipe" "$home" "$bindir"
  ct=$(c756_crontab "$pipe" '*/5 * * * * tick.sh')
  c756_log "$home" tick run.log 1795000000 "fine"
  c756_run "$pipe" "$home" "$bindir" cat "$ct"
  n1=$(c756_count "$bindir" 'example.invalid/beat')
  t=$(python3 -c "import time; print(int(time.time()))")
  # state: last push is fresh (no keep-alive), last attempt older than the coalescing interval
  python3 -c "
import json, sys
p = sys.argv[1] + '/status-push.state'
d = json.load(open(p)); d['last_push_epoch'] = $t; d['last_attempt_epoch'] = $t - 400
json.dump(d, open(p, 'w'))" "$pipe"
  # only last_run and next_run move (a later log, a later clock)
  c756_log "$home" tick run.log 1795050000 "fine"
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" TZ=UTC STATUS_CRON_NOW=$((C756_NOW + 600)) STATUS_CRON_CMD="cat $ct" \
      PATH="$bindir:$C756_PATH" "$RS_C756/report-status.sh" event )
  n2=$(c756_count "$bindir" 'example.invalid/beat')
  python3 -c "
import json, sys
p = sys.argv[1] + '/status-push.state'
d = json.load(open(p)); d['last_push_epoch'] = $t; d['last_attempt_epoch'] = $t - 400
json.dump(d, open(p, 'w'))" "$pipe"
  # a real change: the job starts failing
  c756_log "$home" tick run.log 1795050000 "ERROR something"
  c756_run "$pipe" "$home" "$bindir" cat "$ct"
  n3=$(c756_count "$bindir" 'example.invalid/beat')
  cleanup_running; rm -rf "$pipe" "$home" "$bindir"
  assert_eq "$n1" "1" "first beat pushes" || return 1
  assert_eq "$n2" "1" "write budget: only last_run/next_run moved -> no new push" || return 1
  assert_eq "$n3" "2" "write budget: ok -> failed is a real change and pushes" || return 1
}

run_test test_cron_privacy_only_basename_and_schedule_published
run_test test_cron_parsing_skips_comments_blanks_env_and_malformed_lines
run_test test_cron_next_run_hand_computed_utc
run_test test_cron_next_run_uses_the_vm_timezone_then_emits_utc
run_test test_cron_capped_at_50_jobs
run_test test_cron_last_result_from_log_dirs
run_test test_cron_failing_crontab_read_omits_key_and_never_fails
run_test test_cron_empty_and_no_crontab_omit_key
run_test test_cron_failing_read_still_pushes_and_alerts_with_tags_only
run_test test_cron_failure_alert_is_throttled_and_clears_after_recovery
run_test test_cron_drifting_last_run_and_next_run_do_not_change_the_push_hash
