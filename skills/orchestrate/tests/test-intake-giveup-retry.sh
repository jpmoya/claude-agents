# Issue #676 (b) — an intake (step 3b) or spec (step 3c) run that exits with no handoff marker is classified, and a give-up
# is no longer permanent:
#   limit      the run's log says "hit your … limit": never counted, never gives up; the issue is released and nothing is
#              launched by 3b/3c on this host until $PIPE/intake-limit-until passes (6h for a monthly spend limit, 1h otherwise)
#   transient  non-zero exit or no exit code: released without counting, retried after 300 / 600 / 1200 s, at most
#              INTAKE_MAX_TRANSIENT (3) per give-up cycle; the fourth is handled as failed
#   failed     exit 0, no marker: today's flow (one recovery launch, then give up)
# A give-up writes the cycle count to .giveups and expires after INTAKE_GAVEUP_RETRY_SECS (6h) while .giveups < 4; the
# fourth is final (NOTE + one #engineering message).
#
# Reuses the si_* harness of test-intake-supervisor.sh (stateful gh stub: issues.json / comments.json, call log). Whole
# supervisor ticks, isolated HOME/PIPE. The claude stub's behaviour comes from $SI_D/claude-mode (or claude-mode-<issue>):
#   spend | weekly   prints a usage-limit line, exits 1
#   kill             exits 137 with no output
#   vanish           kills its wrapper, so no exit code is ever written
#   add-go-kill      adds agent-go to the issue (as a hijacked run would), exits 137
#   marker           posts `**[intake] TRIAGED BUG**`, exits 0
#   (absent)         exits 0 with no marker
# Expected values are hand-written from the ticket. Placeholder repo names only.

HERE_IGR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f si_env >/dev/null 2>&1; then   # this file sorts before test-intake-supervisor.sh: load its harness, not its cases
  eval "igr_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_IGR/test-intake-supervisor.sh"
  eval "$(declare -f igr_real_run_test | sed '1s/igr_real_run_test/run_test/')"
fi

igr_env() {
  si_env "$@"
  cat > "$SI_D/claude" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$* | ISSUE=${PIPELINE_ISSUE:-} AGENT=${PIPELINE_AGENT:-} REPO=${PIPELINE_REPO:-}" >> "$D/claude.log"
mode=$(cat "$D/claude-mode" 2>/dev/null)
[ -f "$D/claude-mode-${PIPELINE_ISSUE:-}" ] && mode=$(cat "$D/claude-mode-${PIPELINE_ISSUE:-}")
case "$mode" in
  spend)  echo "You've hit your monthly spend limit"; exit 1 ;;
  weekly) echo "You've hit your weekly limit · resets Monday 09:00"; exit 1 ;;
  kill)   exit 137 ;;
  vanish) kill -9 "$PPID"; exit 0 ;;
  add-go-kill)
    jq --argjson n "$PIPELINE_ISSUE" 'map(if .number==$n then .labels += [{name:"agent-go"}] else . end)' "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"
    exit 137 ;;
  marker)
    jq --arg b $'**[intake] TRIAGED BUG**\nok' '. + [{body:$b,createdAt:"2099-01-01T00:00:00Z"}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
    exit 0 ;;
esac
exit 0
X
  : > "$SI_D/curl.log"
  cat > "$SI_D/curl" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/curl.log"; echo '{"ok":true}'
X
  # the harness gh answers every `issue view` from comments.json; serve the labels-only read from issues.json (as #176's tests do)
  mv "$SI_D/gh" "$SI_D/gh-base"
  cat > "$SI_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
case "$*" in
  "issue view "*"--json labels --jq"*)
    echo "$*" >> "$D/gh-calls.log"
    n=$3; jqx=${@: -1}
    jq -c --argjson n "$n" '.[]|select(.number==$n)|{labels:.labels}' "$D/issues.json" | jq -r "$jqx"; exit 0;;
esac
exec "$D/gh-base" "$@"
X
  chmod +x "$SI_D/claude" "$SI_D/curl" "$SI_D/gh"
}
igr_mode() { if [ -n "${2:-}" ]; then echo "$1" > "$SI_D/claude-mode-$2"; else echo "$1" > "$SI_D/claude-mode"; fi; }
# igr_tick — one supervisor tick; IGR_SLACK=1 wires the #engineering bot token + channel (curl is the recorder above)
igr_tick() {
  local tok="" ch=""; [ "${IGR_SLACK:-0}" = 1 ] && { tok="slack-bot-token-for-tests"; ch="C0TEST"; }
  HOME="$SI_HOME" PATH="$SI_D:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SI_PIPE" QUEUE="$SI_PIPE/queue" LOGDIR="$SI_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="$tok" SLACK_ENGINEERING_CHANNEL="$ch" /bin/bash "$SUP_SI" >/dev/null 2>&1
  igr_settle
}
# igr_settle — wait (up to 10 s) until the run the tick launched has exited, so the tick counts below are exact on a busy host:
# a stub still running at the next tick reads as a live run and moves every later step by one tick.
igr_settle() {
  local i f alive
  for i in $(seq 1 100); do
    alive=0
    for f in "$SI_PIPE"/intake-*.pid "$SI_PIPE"/spec-*.pid; do
      [ -f "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && return 0
    sleep 0.1
  done
}
igr_ticks() { local i; for i in $(seq 1 "$1"); do igr_tick; done; }
igr_k()  { printf '%s/intake-project-a_repo-a-%s' "$SI_PIPE" "$1"; }   # state-file stem of an intake run
igr_sk() { printf '%s/spec-project-a_repo-a-%s' "$SI_PIPE" "$1"; }     # ... of a spec run
igr_file() { cat "$1" 2>/dev/null || echo "ABSENT"; }
igr_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
igr_runs() { grep -c -- "--agent $1 " "$SI_D/claude.log"; }             # launches of that agent so far
igr_notes() { jq -r '.[].body | select(startswith("**[supervisor] NOTE**") and (contains("claim:") | not))' "$SI_D/comments.json"; }
igr_comment_calls() { grep -c '^issue comment ' "$SI_D/gh-calls.log"; }
igr_age() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" "$1" "$2"; }
igr_near() {  # igr_near <epoch> <expected seconds from now> — within 180 s (ticks take a couple of seconds each)
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  local d=$(( $1 - $(date +%s) - $2 )); [ "$d" -ge -180 ] && [ "$d" -le 30 ]
}
igr_log() { cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }

# --------------------------------------------------------------------------------------------------------
# limit — never counts, never gives up, host-wide stamp (Expected Behavior 5, 6; AC4, AC6)
# --------------------------------------------------------------------------------------------------------

test_igr_limit_exit_releases_without_counting_and_stamps_six_hours() {
  igr_env; igr_mode spend; si_issue 7 project-a/repo-a user-feedback-intake
  igr_tick
  local launched_at; launched_at=$(igr_file "$(igr_k 7).launched-at")
  igr_ticks 2   # grace tick, then the classification
  local attempts lim labels notes runs id log
  attempts=$(igr_file "$(igr_k 7).attempts"); lim=$(igr_file "$SI_PIPE/intake-limit-until"); labels=$(si_labels 7)
  notes=$(igr_notes | grep -c .); runs=$(igr_runs intake); id=$(igr_present "$(igr_k 7).id"); log=$(igr_log)
  # a second intake issue and a spec issue queue up while the stamp is in the future: neither may be claimed
  si_issue 8 project-a/repo-a user-feedback-intake; si_issue 9 project-a/repo-a user-feedback-needs-spec
  : > "$SI_D/gh-calls.log"
  igr_ticks 2
  local comment_calls runs_blocked labels8 labels9
  comment_calls=$(igr_comment_calls); runs_blocked=$(grep -c . "$SI_D/claude.log"); labels8=$(si_labels 8); labels9=$(si_labels 9)
  # the stamp passes: the released issue is claimed again and the limit run was never counted
  echo $(( $(date +%s) - 5 )) > "$SI_PIPE/intake-limit-until"; igr_mode none
  igr_tick
  local runs_after attempts_after; runs_after=$(igr_runs intake); attempts_after=$(igr_file "$(igr_k 7).attempts")
  si_cleanup
  igr_near "$launched_at" 0 || { fail "launch: .launched-at must hold the launch epoch, got [$launched_at]"; return 1; }
  assert_eq "$runs" "1" "limit: one run, no recovery launch" || return 1
  assert_eq "$attempts" "0" "limit: the run is not counted (.attempts back to its pre-launch value)" || return 1
  igr_near "$lim" 21600 || { fail "limit: intake-limit-until must be about 6h ahead for a monthly spend limit, got [$lim]"; return 1; }
  assert_eq "$labels" "user-feedback-intake" "limit: issue back to user-feedback-intake without agent-in-progress" || return 1
  assert_eq "$notes" "0" "limit: no issue comment" || return 1
  assert_eq "$id" "absent" "limit: the run's state is cleared" || return 1
  assert_contains "$log" "[intake] project-a/repo-a#7 exit class=limit kind=monthly_spend" "limit: one slog line for the classification" || return 1
  assert_eq "$comment_calls" "0" "AC6: zero gh issue comment calls (no claim by 3b or 3c) while the stamp is in the future" || return 1
  assert_eq "$runs_blocked" "1" "limit: nothing launched while the stamp is in the future" || return 1
  assert_eq "$labels8" "user-feedback-intake" "limit: the second queued intake issue is not claimed" || return 1
  assert_eq "$labels9" "user-feedback-needs-spec" "limit: the queued spec issue is not claimed" || return 1
  assert_eq "$runs_after" "2" "limit: once the stamp has passed the issue is claimed again" || return 1
  assert_eq "$attempts_after" "1" "limit: the relaunch is attempt 1 again (the limit run never counted)" || return 1
}

test_igr_weekly_limit_stamps_one_hour() {
  igr_env; igr_mode weekly; si_issue 7 project-a/repo-a user-feedback-intake
  igr_ticks 3
  local lim attempts gave; lim=$(igr_file "$SI_PIPE/intake-limit-until"); attempts=$(igr_file "$(igr_k 7).attempts"); gave=$(igr_present "$(igr_k 7).gaveup")
  si_cleanup
  igr_near "$lim" 3600 || { fail "limit: a non-spend limit waits RATE_LIMIT_BACKOFF_SECS (1h), got [$lim]"; return 1; }
  assert_eq "$attempts" "0" "limit (weekly): not counted" || return 1
  assert_eq "$gave" "absent" "limit (weekly): never a give-up" || return 1
}

test_igr_limit_never_gives_up_however_often_it_repeats() {
  igr_env; igr_mode spend; si_issue 7 project-a/repo-a user-feedback-intake
  local i
  for i in 1 2 3; do   # three limit exits in a row, the stamp moved back each time
    igr_ticks 3
    echo $(( $(date +%s) - 5 )) > "$SI_PIPE/intake-limit-until"
  done
  igr_ticks 3
  local runs gave giveups notes attempts
  runs=$(igr_runs intake); gave=$(igr_present "$(igr_k 7).gaveup"); giveups=$(igr_file "$(igr_k 7).giveups")
  notes=$(igr_notes | grep -c .); attempts=$(igr_file "$(igr_k 7).attempts")
  si_cleanup
  assert_eq "$runs" "4" "limit: relaunched after every stamp, four runs" || return 1
  assert_eq "$gave" "absent" "limit: four limit exits never give up" || return 1
  assert_eq "$giveups" "ABSENT" "limit: no give-up cycle counted" || return 1
  assert_eq "$attempts" "0" "limit: still not counted" || return 1
  assert_eq "$notes" "0" "limit: still no issue comment" || return 1
}

test_igr_limit_stamp_holds_the_recovery_launch_too() {
  igr_env; si_issue 7 project-a/repo-a user-feedback-intake     # exit 0, no marker: a failed run that is owed one recovery launch
  igr_tick
  echo $(( $(date +%s) + 3600 )) > "$SI_PIPE/intake-limit-until"
  igr_ticks 3
  local runs_held; runs_held=$(igr_runs intake)
  echo $(( $(date +%s) - 5 )) > "$SI_PIPE/intake-limit-until"
  igr_tick
  local runs_after; runs_after=$(igr_runs intake)
  si_cleanup
  assert_eq "$runs_held" "1" "limit stamp: steps 3b/3c launch nothing, the recovery run included" || return 1
  assert_eq "$runs_after" "2" "limit stamp: the recovery launch happens once the stamp has passed" || return 1
}

# --------------------------------------------------------------------------------------------------------
# transient — not an attempt, backoff, at most 3 per cycle (Expected Behavior 5, 7; AC4)
# --------------------------------------------------------------------------------------------------------

test_igr_transient_exit_backs_off_and_is_not_counted() {
  igr_env; igr_mode kill; si_issue 7 project-a/repo-a user-feedback-intake
  igr_ticks 3
  local transients retry attempts labels notes log
  transients=$(igr_file "$(igr_k 7).transients"); retry=$(igr_file "$(igr_k 7).retry-after"); attempts=$(igr_file "$(igr_k 7).attempts")
  labels=$(si_labels 7); notes=$(igr_notes | grep -c .); log=$(igr_log)
  : > "$SI_D/gh-calls.log"
  igr_ticks 2
  local runs_waiting comment_calls; runs_waiting=$(igr_runs intake); comment_calls=$(igr_comment_calls)
  echo $(( $(date +%s) - 5 )) > "$(igr_k 7).retry-after"   # the wait is over
  igr_tick
  local runs_after claims; runs_after=$(igr_runs intake); claims=$(grep -c '^issue comment 7 ' "$SI_D/gh-calls.log")
  igr_ticks 2   # the second run dies the same way: second transient of the cycle
  local transients2 retry2 attempts2; transients2=$(igr_file "$(igr_k 7).transients"); retry2=$(igr_file "$(igr_k 7).retry-after"); attempts2=$(igr_file "$(igr_k 7).attempts")
  local gave; gave=$(igr_present "$(igr_k 7).gaveup")
  si_cleanup
  assert_eq "$transients" "1" "transient: .transients = 1" || return 1
  igr_near "$retry" 300 || { fail "transient: .retry-after must be now + 300 (first TRANSIENT_BACKOFF value), got [$retry]"; return 1; }
  assert_eq "$attempts" "0" "transient: not counted as an attempt" || return 1
  assert_eq "$labels" "user-feedback-intake" "transient: issue released (label back, agent-in-progress gone)" || return 1
  assert_eq "$notes" "0" "transient: no issue comment" || return 1
  assert_contains "$log" "[intake] project-a/repo-a#7 exit class=transient" "transient: one slog line for the classification" || return 1
  assert_eq "$runs_waiting" "1" "transient: not claimed before .retry-after" || return 1
  assert_eq "$comment_calls" "0" "transient: no claim comment before .retry-after" || return 1
  assert_eq "$runs_after" "2" "transient: claimed again after .retry-after" || return 1
  assert_eq "$claims" "1" "transient: through a fresh claim" || return 1
  assert_eq "$transients2" "2" "transient: the second one of the cycle is counted in .transients" || return 1
  igr_near "$retry2" 600 || { fail "transient: the second wait is 600 s, got [$retry2]"; return 1; }
  assert_eq "$attempts2" "0" "transient: still no attempt counted" || return 1
  assert_eq "$gave" "absent" "transient: no give-up" || return 1
}

test_igr_missing_exit_code_is_transient() {
  igr_env; igr_mode vanish; si_issue 7 project-a/repo-a user-feedback-intake
  igr_ticks 3
  local transients exitf attempts; transients=$(igr_file "$(igr_k 7).transients"); exitf=$(igr_present "$(igr_k 7).exit"); attempts=$(igr_file "$(igr_k 7).attempts")
  si_cleanup
  assert_eq "$exitf" "absent" "precondition: the run died without writing an exit code" || return 1
  assert_eq "$transients" "1" "a missing exit code is a transient exit" || return 1
  assert_eq "$attempts" "0" "and is not counted" || return 1
}

test_igr_fourth_transient_in_a_cycle_is_handled_as_failed() {
  igr_env; igr_mode kill; si_issue 7 project-a/repo-a user-feedback-intake
  igr_tick
  echo 3 > "$(igr_k 7).transients"   # three transient exits already used in this cycle
  igr_ticks 2
  local runs labels retry transients attempts
  runs=$(igr_runs intake); labels=$(si_labels 7); retry=$(igr_present "$(igr_k 7).retry-after")
  transients=$(igr_file "$(igr_k 7).transients"); attempts=$(igr_file "$(igr_k 7).attempts")
  igr_ticks 2   # the recovery run dies too: attempts reaches 2, give up
  local gave giveups; gave=$(igr_present "$(igr_k 7).gaveup"); giveups=$(igr_file "$(igr_k 7).giveups")
  si_cleanup
  assert_eq "$runs" "2" "4th transient: handled as failed — the one recovery launch, no release" || return 1
  assert_eq "$labels" "agent-in-progress" "4th transient: the issue is not released to the queue" || return 1
  assert_eq "$retry" "absent" "4th transient: no .retry-after" || return 1
  assert_eq "$transients" "3" "4th transient: .transients stays at the cap" || return 1
  assert_eq "$attempts" "2" "4th transient: counted as an attempt (recovery launch = attempt 2)" || return 1
  assert_eq "$gave" "present" "4th transient: the next failure gives up" || return 1
  assert_eq "$giveups" "1" "4th transient: give-up cycle 1" || return 1
}

test_igr_transient_release_strips_agent_go_from_a_sentry_issue() {
  # #176's gate holds on the new release path: a source:sentry run that added agent-go and then crashed is released without it,
  # and the launch-time sentry record survives the release (so the relaunch is still gated if the label was removed)
  igr_env; igr_mode add-go-kill; si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  igr_ticks 3
  local labels sentry calls other
  labels=$(si_labels 7); sentry=$(igr_present "$(igr_k 7).sentry"); calls=$(cat "$SI_D/gh-calls.log"); other=$(grep -vc -- '--agent intake' "$SI_D/claude.log")
  si_cleanup
  assert_contains "$calls" "issue edit 7 --repo project-a/repo-a --remove-label agent-go" "sentry: the release strips agent-go first" || return 1
  assert_eq "$labels" "source:sentry,user-feedback-intake" "sentry: released without agent-go" || return 1
  assert_eq "$sentry" "present" "sentry: the launch-time .sentry record is kept across the release" || return 1
  assert_eq "$other" "0" "sentry: nothing was dispatched" || return 1
}

# --------------------------------------------------------------------------------------------------------
# failed — today's flow, then a give-up that expires (Expected Behavior 8, 9, 10; AC5)
# --------------------------------------------------------------------------------------------------------

test_igr_failed_twice_gives_up_with_cycle_count_and_retry_note() {
  igr_env; si_issue 7 project-a/repo-a user-feedback-intake     # exit 0, no marker, twice
  igr_ticks 6
  local runs gave giveups note n_notes labels launched_at when ok=no
  runs=$(igr_runs intake); gave=$(igr_present "$(igr_k 7).gaveup"); giveups=$(igr_file "$(igr_k 7).giveups")
  note=$(igr_notes); n_notes=$(printf '%s\n' "$note" | grep -c .); labels=$(si_labels 7); launched_at=$(igr_present "$(igr_k 7).launched-at")
  si_cleanup
  assert_eq "$runs" "2" "failed: one recovery launch, then give up" || return 1
  assert_eq "$gave" "present" "failed: .gaveup written" || return 1
  assert_eq "$giveups" "1" "failed: .giveups = 1" || return 1
  assert_eq "$n_notes" "1" "failed: exactly one NOTE" || return 1
  printf '%s' "$note" | grep -Eq '^\*\*\[supervisor\] NOTE\*\* intake failed \(cycle 1/4\); automatic retry after [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z\.$' \
    || { fail "failed: non-final NOTE text, got [$note]"; return 1; }
  when=$(printf '%s' "$note" | sed -E 's/.*retry after ([0-9TZ:-]+)\.$/\1/')
  python3 -c "import sys,datetime,time
t=datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%MZ').replace(tzinfo=datetime.timezone.utc).timestamp()
sys.exit(0 if abs(t-(time.time()+21600))<300 else 1)" "$when" && ok=yes
  assert_eq "$ok" "yes" "failed: the NOTE's retry time is 6h ahead (UTC), got [$when]" || return 1
  assert_eq "$labels" "user-feedback-intake" "failed: issue back in the intake queue" || return 1
  assert_eq "$launched_at" "absent" "failed: the cycle's launch stamp is cleared at give-up" || return 1
}

test_igr_giveup_expires_after_six_hours() {
  igr_env; si_issue 7 project-a/repo-a user-feedback-intake
  touch "$(igr_k 7).gaveup"; echo 1 > "$(igr_k 7).giveups"; echo 2 > "$(igr_k 7).attempts"; echo 2 > "$(igr_k 7).transients"
  igr_age "$(igr_k 7).gaveup" $((1 * 3600))
  igr_ticks 2
  local runs_1h comments_1h gave_1h; runs_1h=$(igr_runs intake); comments_1h=$(igr_comment_calls); gave_1h=$(igr_present "$(igr_k 7).gaveup")
  igr_age "$(igr_k 7).gaveup" $((7 * 3600))
  igr_tick
  local runs_7h gave_7h attempts transients giveups labels
  runs_7h=$(igr_runs intake); gave_7h=$(igr_present "$(igr_k 7).gaveup"); attempts=$(igr_file "$(igr_k 7).attempts")
  transients=$(igr_file "$(igr_k 7).transients"); giveups=$(igr_file "$(igr_k 7).giveups"); labels=$(si_labels 7)
  si_cleanup
  assert_eq "$runs_1h" "0" "expiry: a 1h-old give-up is skipped" || return 1
  assert_eq "$comments_1h" "0" "expiry: no claim comment for a 1h-old give-up" || return 1
  assert_eq "$gave_1h" "present" "expiry: the 1h-old .gaveup stays" || return 1
  assert_eq "$runs_7h" "1" "expiry: a 7h-old give-up with .giveups = 1 is claimed again" || return 1
  assert_eq "$gave_7h" "absent" "expiry: .gaveup removed" || return 1
  assert_eq "$attempts" "1" "expiry: .attempts reset (the relaunch is attempt 1)" || return 1
  assert_eq "$transients" "ABSENT" "expiry: .transients reset" || return 1
  assert_eq "$giveups" "1" "expiry: the cycle count is kept" || return 1
  assert_eq "$labels" "agent-in-progress" "expiry: the issue is claimed (label swapped)" || return 1
}

test_igr_legacy_giveup_without_cycle_count_expires_too() {
  # a .gaveup written before #676 has no .giveups: it must not strand the issue on that host forever
  igr_env; si_issue 7 project-a/repo-a user-feedback-intake
  touch "$(igr_k 7).gaveup"; echo 2 > "$(igr_k 7).attempts"; igr_age "$(igr_k 7).gaveup" $((7 * 3600))
  igr_tick
  local runs; runs=$(igr_runs intake); si_cleanup
  assert_eq "$runs" "1" "legacy: a 7h-old .gaveup with no .giveups is retried" || return 1
}

test_igr_fourth_giveup_is_final_note_once_and_engineering_alert() {
  igr_env; si_issue 7 project-a/repo-a user-feedback-intake
  touch "$(igr_k 7).gaveup"; echo 2 > "$(igr_k 7).giveups"; echo 2 > "$(igr_k 7).attempts"; igr_age "$(igr_k 7).gaveup" $((7 * 3600))
  IGR_SLACK=1 igr_ticks 5   # cycle 3: claim + run, grace, recovery run, grace, give up
  local giveups3 note3 curl3
  giveups3=$(igr_file "$(igr_k 7).giveups"); note3=$(igr_notes); curl3=$(grep -c 'gave up after' "$SI_D/curl.log")
  igr_age "$(igr_k 7).gaveup" $((7 * 3600))
  IGR_SLACK=1 igr_ticks 5   # cycle 4: the final one
  local giveups4 notes final_n curl log runs4 sha
  giveups4=$(igr_file "$(igr_k 7).giveups"); notes=$(igr_notes); final_n=$(printf '%s\n' "$notes" | grep -c 'intake failed 4 cycles; needs manual triage\.')
  curl=$(cat "$SI_D/curl.log"); log=$(igr_log); runs4=$(igr_runs intake)
  sha=$(git -C "$HERE_IGR" rev-parse HEAD 2>/dev/null || echo unknown)
  igr_age "$(igr_k 7).gaveup" $((7 * 3600))   # 7h later: a final give-up never expires
  : > "$SI_D/gh-calls.log"
  IGR_SLACK=1 igr_ticks 3
  local runs_final comments_final final_n2 gave labels
  runs_final=$(igr_runs intake); comments_final=$(igr_comment_calls); final_n2=$(igr_notes | grep -c 'needs manual triage')
  gave=$(igr_present "$(igr_k 7).gaveup"); labels=$(si_labels 7)
  si_cleanup
  assert_eq "$giveups3" "3" "cycle 3: .giveups = 3" || return 1
  assert_contains "$note3" "**[supervisor] NOTE** intake failed (cycle 3/4); automatic retry after " "cycle 3: non-final NOTE" || return 1
  assert_eq "$curl3" "0" "cycle 3: no #engineering alert before the final give-up" || return 1
  assert_eq "$giveups4" "4" "cycle 4: .giveups = 4" || return 1
  assert_eq "$runs4" "4" "two runs per cycle (cycles 3 and 4)" || return 1
  assert_contains "$notes" "**[supervisor] NOTE** intake failed 4 cycles; needs manual triage." "cycle 4: final NOTE text" || return 1
  assert_eq "$final_n" "1" "cycle 4: the final NOTE is posted once" || return 1
  assert_contains "$curl" "chat.postMessage" "cycle 4: one #engineering message through notify_engineering" || return 1
  assert_contains "$curl" "intake gave up after 4 cycles — needs manual triage" "cycle 4: notify_engineering payload recorded" || return 1
  assert_contains "$curl" "project-a/repo-a/issues/7" "cycle 4: the payload links the issue" || return 1
  assert_eq "$(printf '%s\n' "$curl" | grep -c 'gave up after 4 cycles')" "1" "cycle 4: exactly one alert" || return 1
  assert_contains "$log" "project-a/repo-a#7 gave up for good after 4 cycles" "cycle 4: failure line logged" || return 1
  assert_contains "$log" "release=$sha environment=$(hostname -s) route=intake-giveup" "cycle 4: the line is tagged (release = commit SHA, environment, route)" || return 1
  assert_eq "$runs_final" "4" "final: a 7h-old .gaveup with .giveups = 4 is skipped (never more than 4 cycles)" || return 1
  assert_eq "$comments_final" "0" "final: no claim comment either" || return 1
  assert_eq "$final_n2" "1" "final: the NOTE is not repeated" || return 1
  assert_eq "$gave" "present" "final: .gaveup stays" || return 1
  assert_eq "$labels" "user-feedback-intake" "final: the issue waits in the intake queue for manual triage" || return 1
}

test_igr_healthy_run_clears_the_cycle_state() {
  igr_env; igr_mode marker; si_issue 7 project-a/repo-a user-feedback-intake
  echo 2 > "$(igr_k 7).transients"
  igr_ticks 2
  local left; left=$(ls "$SI_PIPE" | grep '^intake-project-a_repo-a-7\.' | grep -Ev '\.log$' | tr '\n' ' ')
  si_cleanup
  assert_eq "$left" "" "done: no per-run state is left behind (.launched-at, .transients, .retry-after included)" || return 1
}

# --------------------------------------------------------------------------------------------------------
# spec step (3c) — same helpers, spec-* state, the word `spec`, never re-adds a label it did not remove
# --------------------------------------------------------------------------------------------------------

test_igr_spec_limit_exit_releases_without_counting() {
  igr_env; igr_mode spend; si_issue 9 project-a/repo-a user-feedback-needs-spec
  igr_ticks 2   # 3c has no grace tick: claim + run, then the classification
  local attempts lim labels notes runs readds launched_at
  attempts=$(igr_file "$(igr_sk 9).attempts"); lim=$(igr_file "$SI_PIPE/intake-limit-until"); labels=$(si_labels 9)
  notes=$(igr_notes | grep -c .); runs=$(igr_runs product-manager); readds=$(grep -c -- '--add-label user-feedback' "$SI_D/gh-calls.log")
  launched_at=$(igr_file "$(igr_sk 9).launched-at")
  si_issue 8 project-a/repo-a user-feedback-intake
  : > "$SI_D/gh-calls.log"
  igr_ticks 2
  local comment_calls runs_blocked; comment_calls=$(igr_comment_calls); runs_blocked=$(grep -c . "$SI_D/claude.log")
  si_cleanup
  assert_eq "$runs" "1" "spec limit: one PM run" || return 1
  igr_near "$launched_at" 0 || { fail "spec launch: .launched-at must hold the launch epoch, got [$launched_at]"; return 1; }
  assert_eq "$attempts" "0" "spec limit: not counted" || return 1
  igr_near "$lim" 21600 || { fail "spec limit: intake-limit-until about 6h ahead, got [$lim]"; return 1; }
  assert_eq "$labels" "user-feedback-needs-spec" "spec limit: agent-in-progress removed, needs-spec untouched" || return 1
  assert_eq "$readds" "0" "spec limit: step 3c never re-adds a label it did not remove" || return 1
  assert_eq "$notes" "0" "spec limit: no issue comment" || return 1
  assert_eq "$comment_calls" "0" "AC6: zero gh issue comment calls by 3b or 3c while the stamp is in the future" || return 1
  assert_eq "$runs_blocked" "1" "spec limit: nothing launched while the stamp is in the future" || return 1
}

test_igr_spec_transient_exit_backs_off() {
  igr_env; igr_mode kill; si_issue 9 project-a/repo-a user-feedback-needs-spec
  igr_ticks 2
  local transients retry attempts; transients=$(igr_file "$(igr_sk 9).transients"); retry=$(igr_file "$(igr_sk 9).retry-after"); attempts=$(igr_file "$(igr_sk 9).attempts")
  igr_ticks 2
  local runs_waiting; runs_waiting=$(igr_runs product-manager)
  echo $(( $(date +%s) - 5 )) > "$(igr_sk 9).retry-after"
  igr_tick
  local runs_after gave; runs_after=$(igr_runs product-manager); gave=$(igr_present "$(igr_sk 9).gaveup")
  si_cleanup
  assert_eq "$transients" "1" "spec transient: .transients = 1" || return 1
  igr_near "$retry" 300 || { fail "spec transient: .retry-after = now + 300, got [$retry]"; return 1; }
  assert_eq "$attempts" "0" "spec transient: not counted" || return 1
  assert_eq "$runs_waiting" "1" "spec transient: not claimed before .retry-after" || return 1
  assert_eq "$runs_after" "2" "spec transient: claimed after .retry-after" || return 1
  assert_eq "$gave" "absent" "spec transient: no give-up" || return 1
}

test_igr_spec_failed_twice_gives_up_with_spec_note() {
  igr_env; si_issue 9 project-a/repo-a user-feedback-needs-spec     # PM exits 0 with no marker, twice
  igr_ticks 4
  local runs gave giveups note labels readds
  runs=$(igr_runs product-manager); gave=$(igr_present "$(igr_sk 9).gaveup"); giveups=$(igr_file "$(igr_sk 9).giveups")
  note=$(igr_notes); labels=$(si_labels 9); readds=$(grep -c -- '--add-label user-feedback' "$SI_D/gh-calls.log")
  si_cleanup
  assert_eq "$runs" "2" "spec failed: two runs, then give up" || return 1
  assert_eq "$gave" "present" "spec failed: .gaveup written" || return 1
  assert_eq "$giveups" "1" "spec failed: .giveups = 1" || return 1
  printf '%s' "$note" | grep -Eq '^\*\*\[supervisor\] NOTE\*\* spec failed \(cycle 1/4\); automatic retry after [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z\.$' \
    || { fail "spec failed: non-final NOTE uses the word spec, got [$note]"; return 1; }
  assert_eq "$labels" "user-feedback-needs-spec" "spec failed: labels as before the claim" || return 1
  assert_eq "$readds" "0" "spec failed: no label re-added" || return 1
}

test_igr_spec_giveup_expiry_and_final_cycle() {
  igr_env; si_issue 9 project-a/repo-a user-feedback-needs-spec
  touch "$(igr_sk 9).gaveup"; echo 3 > "$(igr_sk 9).giveups"; echo 2 > "$(igr_sk 9).attempts"
  igr_age "$(igr_sk 9).gaveup" $((1 * 3600))
  igr_ticks 2
  local runs_1h comments_1h; runs_1h=$(igr_runs product-manager); comments_1h=$(igr_comment_calls)
  igr_age "$(igr_sk 9).gaveup" $((7 * 3600))
  IGR_SLACK=1 igr_tick
  local runs_7h; runs_7h=$(igr_runs product-manager)
  IGR_SLACK=1 igr_ticks 3   # second failed run of cycle 4, then the final give-up
  local giveups notes curl log sha; giveups=$(igr_file "$(igr_sk 9).giveups"); notes=$(igr_notes); curl=$(cat "$SI_D/curl.log"); log=$(igr_log)
  sha=$(git -C "$HERE_IGR" rev-parse HEAD 2>/dev/null || echo unknown)
  igr_age "$(igr_sk 9).gaveup" $((7 * 3600))
  : > "$SI_D/gh-calls.log"
  local runs_before; runs_before=$(igr_runs product-manager)
  IGR_SLACK=1 igr_ticks 2
  local runs_final comments_final; runs_final=$(igr_runs product-manager); comments_final=$(igr_comment_calls)
  si_cleanup
  assert_eq "$runs_1h" "0" "spec expiry: a 1h-old give-up is skipped" || return 1
  assert_eq "$comments_1h" "0" "spec expiry: no claim comment for it" || return 1
  assert_eq "$runs_7h" "1" "spec expiry: a 7h-old give-up with .giveups = 3 is claimed again" || return 1
  assert_eq "$giveups" "4" "spec final: .giveups = 4" || return 1
  assert_contains "$notes" "**[supervisor] NOTE** spec failed 4 cycles; needs manual triage." "spec final: NOTE text" || return 1
  assert_eq "$(printf '%s\n' "$notes" | grep -c 'needs manual triage')" "1" "spec final: NOTE posted once" || return 1
  assert_contains "$curl" "spec gave up after 4 cycles — needs manual triage" "spec final: notify_engineering payload recorded" || return 1
  assert_contains "$log" "release=$sha environment=$(hostname -s) route=intake-giveup" "spec final: tagged failure line" || return 1
  assert_eq "$runs_final" "$runs_before" "spec final: a 7h-old .gaveup with .giveups = 4 is skipped" || return 1
  assert_eq "$comments_final" "0" "spec final: no claim comment" || return 1
}

# --------------------------------------------------------------------------------------------------------
# AC7 / AC10 — config defaults and docs
# --------------------------------------------------------------------------------------------------------

test_igr_config_defines_the_four_settings_with_their_defaults() {
  local cfg="$HERE_IGR/../config.sh" line
  for line in INTAKE_LIMIT_BACKOFF_SPEND_SECS=21600 INTAKE_MAX_TRANSIENT=3 INTAKE_GAVEUP_RETRY_SECS=21600 INTAKE_MAX_GIVEUPS=4; do
    grep -qx "$line" "$cfg" || { fail "AC7: config.sh must define $line"; return 1; }
  done
  # next to INTAKE_AUTO_GO, and before the host override so config.local.sh can still change them
  local at_auto at_new at_local
  at_auto=$(grep -n '^INTAKE_AUTO_GO=' "$cfg" | cut -d: -f1); at_new=$(grep -n '^INTAKE_MAX_GIVEUPS=' "$cfg" | cut -d: -f1)
  at_local=$(grep -n 'config.local.sh" ] && source' "$cfg" | head -1 | cut -d: -f1)
  [ "$at_new" -gt "$at_auto" ] && [ $((at_new - at_auto)) -le 12 ] || { fail "AC7: the settings sit next to INTAKE_AUTO_GO (lines $at_auto / $at_new)"; return 1; }
  assert_lt "$at_new" "$at_local" "AC7: defined before config.local.sh is sourced" || return 1
}

test_igr_docs_describe_the_retry_rule_and_the_scan_guard() {
  local root="$HERE_IGR/../../.." f para scan
  for f in "$root/README.md" "$root/agents/README.md"; do
    para=$(grep 'INTAKE_GAVEUP_RETRY_SECS' "$f")
    [ -n "$para" ] || { fail "AC10: ${f#$root/} must name INTAKE_GAVEUP_RETRY_SECS in its intake paragraph"; return 1; }
    assert_contains "$para" "user-feedback-intake" "AC10: ${f#$root/}: it is the intake paragraph" || return 1
    assert_contains "$para" "never counts" "AC10: ${f#$root/}: a limit exit never counts" || return 1
    assert_contains "$para" "6h" "AC10: ${f#$root/}: the 6h expiry" || return 1
    assert_contains "$para" "4" "AC10: ${f#$root/}: 4 cycles" || return 1
    scan=$(printf '%s\n' "$para" | awk '{gsub(/\. /, ".\n"); print}' | grep 'scan-backlog' | grep -c '`user-feedback`')
    [ "$scan" -ge 1 ] || { fail "AC10: ${f#$root/}: the scan sentence must name the user-feedback exclusion"; return 1; }
  done
}

echo "-- intake / spec exit classification, retry and give-up expiry (#676)"
run_test test_igr_config_defines_the_four_settings_with_their_defaults
run_test test_igr_docs_describe_the_retry_rule_and_the_scan_guard
run_test test_igr_limit_exit_releases_without_counting_and_stamps_six_hours
run_test test_igr_weekly_limit_stamps_one_hour
run_test test_igr_limit_never_gives_up_however_often_it_repeats
run_test test_igr_limit_stamp_holds_the_recovery_launch_too
run_test test_igr_transient_exit_backs_off_and_is_not_counted
run_test test_igr_missing_exit_code_is_transient
run_test test_igr_fourth_transient_in_a_cycle_is_handled_as_failed
run_test test_igr_transient_release_strips_agent_go_from_a_sentry_issue
run_test test_igr_failed_twice_gives_up_with_cycle_count_and_retry_note
run_test test_igr_giveup_expires_after_six_hours
run_test test_igr_legacy_giveup_without_cycle_count_expires_too
run_test test_igr_fourth_giveup_is_final_note_once_and_engineering_alert
run_test test_igr_healthy_run_clears_the_cycle_state
run_test test_igr_spec_limit_exit_releases_without_counting
run_test test_igr_spec_transient_exit_backs_off
run_test test_igr_spec_failed_twice_gives_up_with_spec_note
run_test test_igr_spec_giveup_expiry_and_final_cycle
