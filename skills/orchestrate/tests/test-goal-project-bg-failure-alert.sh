# Issue #624 — a backgrounded goal-project job that exits nonzero is reported through the supervisor's alert path
# (log line + autoretry_alert with a label, not an issue number), and a clean job raises nothing.
HERE_GPF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

gpf_run() {  # gpf_run <refresh-rc> → prints the alert calls and the job log
  local d out
  d=$(mktemp -d "${TMPDIR:-/tmp}/gpf.XXXXXX")
  out=$( PIPE="$d" GOAL_PROJECT_SECS=999999 GOAL_PROJECTS=1 bash -c '
    _gp_log() { :; }
    . "$1/goal-project.sh"
    goal_project_refresh_list() { return '"$2"'; }
    goal_project_sync_all() { return 0; }
    autoretry_alert() { echo "ALERT $*" >> "$PIPE/alerts"; }
    goal_project_tick "{}"
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$(cat "$PIPE/goal-project.pid")" 2>/dev/null || break; sleep 0.3; done
    sleep 0.3
  ' _ "$HERE_GPF/.." 2>&1 )
  printf '%s\n--log--\n%s\n' "$(cat "$d/alerts" 2>/dev/null)" "$(cat "$d/goal-project.log" 2>/dev/null)"
  rm -rf "$d"
}

test_gpf_failed_job_is_alerted() {
  local o; o=$(gpf_run x 3)
  assert_contains "$o" "ALERT goal-project project job rc=3 goal-project" "#624: failed backgrounded job reaches autoretry_alert" || return 1
  assert_contains "$o" "[goal-project-failed]" "#624: and is logged" || return 1
}

test_gpf_clean_job_is_silent() {
  local o; o=$(gpf_run x 0)
  assert_not_contains "$o" "ALERT" "#624: clean job raises no alert" || return 1
}

run_test test_gpf_failed_job_is_alerted
run_test test_gpf_clean_job_is_silent
