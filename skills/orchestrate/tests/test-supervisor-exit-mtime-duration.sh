# Regression for claude-agents#753 — step 1's restart path timed a run as now - launched-at, i.e. up to
# the tick that handled the exit. Ticks lagging 200-340 s turned 12-13 s failed runs into "long runs with
# no progress" and held the ticket after three. A run ends when its .exit file was written (the rule
# log_run_exit already applies), so these cases set that file's mtime well before the handling tick.
#
#   1  launched T, .exit T+15 s, handled T+300 s -> transient, count unchanged, total +1
#   2  six such exits still escalate through MAX_TOTAL (the #38 guarantee, on the .exit path)
#   3  a run that really lasted past MIN_RUN_SECS is still counted, with its real length
#   4  the .start fallback (no .launched-at) ends at the same point
# The no-.exit fallback (now - launched-at) is pinned by test_sq_4a and test_fd_1c.
#
# Reuses the sq_* helpers of test-supervisor-queued-not-counted.sh. run-tests.sh sources test files
# alphabetically, so source it here with run_test neutralised (its cases must run once, from the runner).

HERE_EM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "em_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_EM/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f em_real_run_test | sed '1s/em_real_run_test/run_test/')"
fi

# em_exited_run <launched-secs-ago> <run-secs> — the run launched that long ago wrote .exit <run-secs> later.
# .exit's mtime is derived from the written launched-at stamp, so the difference is exact.
em_exited_run() {
  local stamp
  stamp=$(sq_iso_ago "$1")
  printf '%s\n' "$stamp" > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  echo 0 > "$(rkp "$SQ_PIPE/orch-42.exit")"
  python3 -c "
import datetime, os, sys
t = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp() + int(sys.argv[2])
os.utime(sys.argv[3], (t, t))
" "$stamp" "$2" "$(rkp "$SQ_PIPE/orch-42.exit")"
}

em_fixture() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_marker "$SQ_READY"
}

em_last_history() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['history'][-1][sys.argv[2]])" "$(rkp "$SQ_PIPE/orch-42.restarts")" "$1" 2>/dev/null || echo "NO-HISTORY"; }

# count 2 is one short of MAX_NO_PROGRESS=3: counting this exit would hold the ticket, as in the incident.
test_em_1_short_run_handled_late_is_transient() {
  em_fixture
  sq_seed_restarts 2 2 "$SQ_READY"
  em_exited_run 300 15
  sq_tick
  local count total held secs transient log line
  count=$(sq_restarts_field count); total=$(sq_restarts_field total)
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")")
  secs=$(em_last_history run_secs); transient=$(em_last_history transient)
  log=$(sq_log); line=$(printf '%s\n' "$log" | grep -F "[queue-restart] #42")
  sq_cleanup
  assert_eq "$count" "2" "#753/1: count unchanged" || return 1
  assert_eq "$total" "3" "#753/1: total +1" || return 1
  assert_eq "$held" "absent" "#753/1: not held" || return 1
  assert_eq "$transient" "True" "#753/1: history says transient" || return 1
  assert_eq "$secs" "15" "#753/1: history run_secs is the run's length" || return 1
  assert_contains "$log" "[transient] #42 ran 15s" "#753/1: [transient] line reports 15s" || return 1
  assert_contains "$line" "transient=true run=15s" "#753/1: [queue-restart] line reports 15s" || return 1
}

# hand arithmetic: MAX_TOTAL=6 -> ticks 1..5 must not escalate, tick 6 must.
test_em_2_six_short_runs_handled_late_escalate_at_max_total() {
  em_fixture
  local i held5 held6 total count log
  for i in 1 2 3 4 5; do
    em_exited_run 300 15
    rm -f "$(rkp "$SQ_PIPE/queue/orch-42.json")"
    sq_tick
  done
  held5=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")")
  em_exited_run 300 15
  rm -f "$(rkp "$SQ_PIPE/queue/orch-42.json")"
  sq_tick
  held6=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")")
  total=$(sq_restarts_field total); count=$(sq_restarts_field count); log=$(sq_log)
  sq_cleanup
  assert_eq "$held5" "absent" "#753/2: not held after five short exits" || return 1
  assert_eq "$held6" "present" "#753/2: held after the sixth short exit" || return 1
  assert_eq "$total" "6" "#753/2: total=6" || return 1
  assert_eq "$count" "0" "#753/2: none counted as no-progress" || return 1
  assert_contains "$log" "[escalate] #42" "#753/2: escalation logged" || return 1
}

# 600 s > MIN_RUN_SECS=180; handled 900 s after launch, so only the .exit mtime gives 600.
test_em_3_long_run_handled_late_still_counts_with_its_real_length() {
  em_fixture
  em_exited_run 900 600
  sq_tick
  local count total secs line
  count=$(sq_restarts_field count); total=$(sq_restarts_field total)
  secs=$(em_last_history run_secs)
  line=$(sq_log | grep -F "[queue-restart] #42")
  sq_cleanup
  assert_eq "$count" "1" "#753/3: long run counted as no-progress" || return 1
  assert_eq "$total" "1" "#753/3: total=1" || return 1
  assert_eq "$secs" "600" "#753/3: history run_secs is the run's length" || return 1
  assert_contains "$line" "transient=false run=600s" "#753/3: [queue-restart] line reports 600s" || return 1
}

# Without .launched-at the run is timed from .start, still up to the .exit mtime.
test_em_4_start_fallback_also_ends_at_exit_mtime() {
  em_fixture
  em_exited_run 300 15
  mv "$(rkp "$SQ_PIPE/orch-42.launched-at")" "$(rkp "$SQ_PIPE/orch-42.start")"
  sq_tick
  local count secs line
  count=$(sq_restarts_field count); secs=$(em_last_history run_secs)
  line=$(sq_log | grep -F "[queue-restart] #42")
  sq_cleanup
  assert_eq "$count" "0" "#753/4: not counted as no-progress" || return 1
  assert_eq "$secs" "15" "#753/4: history run_secs measured from .start to .exit" || return 1
  assert_contains "$line" "transient=true run=15s" "#753/4: [queue-restart] line reports 15s" || return 1
}

run_test test_em_1_short_run_handled_late_is_transient
run_test test_em_2_six_short_runs_handled_late_escalate_at_max_total
run_test test_em_3_long_run_handled_late_still_counts_with_its_real_length
run_test test_em_4_start_fallback_also_ends_at_exit_mtime
