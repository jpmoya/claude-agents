# #417 — a goal lead killed by the Claude usage limit is not "no progress".
#   AC1 limit segment: wait RATE_LIMIT_BACKOFF_SECS, np untouched, never parked   AC2 only the last segment counts
#   AC3 plain exits still count and park                                          AC4 one "[goal] <id> rate-limited" line
# Expected values come from the ticket or hand arithmetic in comments. Prefix gl_. Reuses the gs_* sandbox of
# test-goal-supervisor.sh (function definitions only; no tests of that file run).
# Clock anchors: RATE_LIMIT_BACKOFF_SECS=3600, BACKOFF=(120 300 900 1800), MIN_RUN_SECS=180.

GL_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$GL_HERE/test-goal-supervisor.sh" > "$GL_HERE/.gl-gs-lib.$$.sh"
  . "$GL_HERE/.gl-gs-lib.$$.sh"
  rm -f "$GL_HERE/.gl-gs-lib.$$.sh"
fi

# gl_log <kind: limit|crash> — append one LAUNCH segment to the goal log
gl_log() {
  printf '\n===== [2026-10-17T22:00:00Z] LAUNCH goal=%s =====\n' "$GS_ID_MS12" >> "$GS_PIPE/goal-$GS_ID_MS12.log"
  case "$1" in
    limit) printf "You've hit your weekly limit · resets 3am\n" >> "$GS_PIPE/goal-$GS_ID_MS12.log" ;;
    *) printf 'Error: connection reset\n' >> "$GS_PIPE/goal-$GS_ID_MS12.log" ;;
  esac
}

# Three limit-ending launches in a row, each past the 3600 s limit wait: .np stays 0 (each decision's snapshot is
# "different" or first; hand arithmetic: if np were counted it would be 0,1,2 then park on the 4th), never held, each launches.
test_gl_ac1_limit_exits_never_count_or_park() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 5000 1 4000
  local k np c held=absent
  for k in 1 2 3 4 5; do
    gl_log limit
    gs_launch_state "$GS_ID_MS12" 5000 1 4000
    gs_tick; gs_wait_claude "$k"; gs_settle
    c=$(gs_claude_count); np=$(gs_file "$GS_ID_MS12" np)
    [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
    assert_eq "$held" "absent" "AC1: never parked (decision $k)" || { gs_cleanup; return 1; }
    assert_eq "$c" "$k" "AC1: decision $k relaunches" || { gs_cleanup; return 1; }
    case "$np" in 0|MISSING) ;; *) gs_cleanup; fail "AC1: np counted ($np) at decision $k"; return 1 ;; esac
  done
  gs_cleanup
}

# The wait is RATE_LIMIT_BACKOFF_SECS (3600) from the exit, not the 120 s transient backoff.
test_gl_ac1_waits_the_rate_limit_backoff() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 1000 1 600   # short run (400 s > MIN_RUN) crashed 600 s ago: BACKOFF[0]=120 would relaunch
  gl_log limit
  gs_tick; gs_settle
  local c1; c1=$(gs_claude_count)
  gs_launch_state "$GS_ID_MS12" 5000 1 3700            # exit 3700 s ago > 3600
  gs_tick; gs_wait_claude 1; gs_settle
  local c2; c2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "0" "AC1: 600 s after a limit exit nothing launches" || return 1
  assert_eq "$c2" "1" "AC1: 3700 s after it relaunches" || return 1
}

# AC2: limit line only in an earlier segment; the last segment is a plain crash -> counted like today.
test_gl_ac2_only_last_segment_counts() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 1500 0 60
  gl_log limit; gl_log crash
  local k np
  for k in 1 2 3; do
    [ "$k" -gt 1 ] && gs_launch_state "$GS_ID_MS12" 1500 0 60
    gs_tick; gs_wait_claude "$k"; gs_settle
  done
  np=$(gs_file "$GS_ID_MS12" np)
  gs_launch_state "$GS_ID_MS12" 1500 0 60
  gs_tick; gs_settle
  local held=absent; [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  gs_cleanup
  assert_eq "$np" "2" "AC2: decisions 1-3 give np 0,1,2 (counted)" || return 1
  assert_eq "$held" "present" "AC2: parked at the 4th" || return 1
}

# AC3: plain exits with an unchanged snapshot park, as in test-goal-supervisor AC6.
test_gl_ac3_plain_exits_still_park() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 1500 0 60
  local k
  for k in 1 2 3; do
    gl_log crash
    [ "$k" -gt 1 ] && gs_launch_state "$GS_ID_MS12" 1500 0 60
    gs_tick; gs_wait_claude "$k"; gs_settle
  done
  gs_launch_state "$GS_ID_MS12" 1500 0 60
  gs_tick; gs_settle
  local held=absent; [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  gs_cleanup
  assert_eq "$held" "present" "AC3: parked after 3 unchanged plain exits" || return 1
}

# AC4: the log line names the goal and the limit kind.
test_gl_ac4_logs_one_rate_limited_line() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 5000 1 4000
  gl_log limit
  gs_tick; gs_wait_claude 1; gs_settle
  local n; n=$(gs_log | grep -cF "[goal] $GS_ID_MS12 rate-limited limit=weekly backoff=3600s")
  gs_cleanup
  assert_eq "$n" "1" "AC4: one rate-limited line" || return 1
}

echo "-- goal limit exit (#417)"
run_test test_gl_ac1_limit_exits_never_count_or_park
run_test test_gl_ac1_waits_the_rate_limit_backoff
run_test test_gl_ac2_only_last_segment_counts
run_test test_gl_ac3_plain_exits_still_park
run_test test_gl_ac4_logs_one_rate_limited_line
