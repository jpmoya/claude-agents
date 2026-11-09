# Issue #624 — supervisor step 1 takes the process scan once per tick (via run-state.sh's _rs_ps_scan/_RS_PS_CACHE, #599),
# not once per recorded pid file. 60 tombstoned dead runs + one run with a live stage; RS_PS_CMD is a counting stub.
HERE_S1=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "s1_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_S1/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f s1_real_run_test | sed '1s/s1_real_run_test/run_test/')"
fi

test_s1_step1_scans_once_and_keeps_stage_wait() {
  local cnt i k stub log n
  sq_env open
  cnt="$SQ_PIPE/scan.count"; : > "$cnt"
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  echo 0 > "$(rkp "$SQ_PIPE/orch-42.exit")"
  printf '{"ts":"%s","host":"h","event":"terminal","repo":"project-a/repo-a","issue":42,"state":"stage running at cap","next_action":"supervisor relaunch picks up result"}\n' "$(sq_iso_ago 10)" \
    >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
  sq_marker "$SQ_READY"
  for i in $(seq 100 159); do
    mk_restarting "$SQ_PIPE" "$i" "$SQ_REPO"
    k=$(_mk_key "$SQ_REPO" "$i"); : > "$SQ_PIPE/orch-$k.stopped"
  done
  stub="echo x >> $cnt; printf '1000\t42\tclaude --agent test-writer -p\n'"
  sq_run env RS_PS_CMD="$stub" "$SUP_SQ" >/dev/null 2>&1
  n=$(wc -l < "$cnt" | tr -d ' '); log=$(sq_log)
  sq_cleanup
  assert_eq "$n" "1" "#624: one process scan for the whole tick, not one per pid file" || return 1
  assert_contains "$log" "[stage-wait] #42" "#624: live-stage record still defers (#178)" || return 1
  assert_contains "$log" "pid=" "#624: stage-wait line still carries the proc detail" || return 1
}

# A failed scan is logged and sent through the existing Slack alert (tags only: release, environment, route).
test_s1_failed_scan_is_reported() {
  local log hook
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_marker "$SQ_READY"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/curl.args"\n' "$SQ_PIPE" > "$SQ_GH/curl"; chmod +x "$SQ_GH/curl"
  sq_run env SLACK_WEBHOOK_URL=http://hook.invalid/x RS_PS_CMD="exit 3" "$SUP_SQ" >/dev/null 2>&1
  log=$(sq_log); hook=$(cat "$SQ_PIPE/curl.args" 2>/dev/null)
  sq_cleanup
  assert_contains "$log" "[ps-scan-failed]" "#624: failed step-1 scan is logged" || return 1
  assert_contains "$hook" "route=supervisor/ps-scan" "#624: failed scan reaches the Slack alert with route tag" || return 1
  assert_contains "$hook" "release=" "#624: alert carries release" || return 1
  assert_contains "$hook" "environment=" "#624: alert carries environment" || return 1
}

run_test test_s1_failed_scan_is_reported
run_test test_s1_step1_scans_once_and_keeps_stage_wait
