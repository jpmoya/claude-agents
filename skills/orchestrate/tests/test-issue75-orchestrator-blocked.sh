# Issue #75: a config-error refusal posts `**[orchestrator] BLOCKED**`; the marker vocabulary knows it and the
# supervisor parks the run through the gate path (no [queue-restart]). Prefixed i75_ (shared shell).

HERE_I75=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_I75=$(cd "$HERE_I75/../../.." && pwd)

if ! declare -f sq_env >/dev/null 2>&1; then
  eval "i75_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I75/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f i75_real_run_test | sed '1s/i75_real_run_test/run_test/')"
fi

test_i75_markers_for_orchestrator() {
  local out; out=$( . "$ROOT_I75/hooks/pipeline-markers.sh"; markers_for orchestrator )
  assert_eq "$out" "BLOCKED" "#75: markers_for orchestrator" || return 1
}

test_i75_marker_re_all_agents_matches_orchestrator_blocked() {
  local re body n
  re=$( . "$ROOT_I75/hooks/pipeline-markers.sh"; marker_re )
  body=$'**[orchestrator] BLOCKED**\nBlocked on: unsupported_project — .claude/agents/x.md'
  n=$(jq -n --arg b "$body" --arg re "$re" '$b | split("\n")[0] | test($re)')
  assert_eq "$n" "true" "#75: any-agent regex sees the orchestrator BLOCKED" || return 1
  n=$(jq -n --arg re "$re" '"**[orchestrator] NOTE**" | test($re)')
  assert_eq "$n" "false" "#75: orchestrator NOTE stays inert" || return 1
}

test_i75_supervisor_parks_config_error_refusal() {
  local log held queued
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  echo 0 > "$(rkp "$SQ_PIPE/orch-42.exit")"
  sq_iso_ago 1300 > "$(rkp "$SQ_PIPE/orch-42.start")"   # past the 1200 s BLOCKED grace window
  sq_marker '**[orchestrator] BLOCKED**'
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"ts":"%s","host":"h","event":"terminal","repo":"project-a/repo-a","issue":42,"state":"config error"}\n' \
    "$(sq_iso_ago 60)" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
  sq_tick
  log=$(sq_log); held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); queued=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")")
  local alert; alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  sq_cleanup
  assert_contains "$log" "[held] #42" "#75: [held] logged" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "#75: no restart" || return 1
  assert_eq "$held" "present" "#75: .held" || return 1
  assert_eq "$queued" "absent" "#75: queue entry removed" || return 1
  assert_contains "$alert" "orchestrator] BLOCKED" "#75: alert written" || return 1
}

test_i75_orchestrator_md_posts_blocked() {
  local line; line=$(grep -F 'config error' "$ROOT_I75/agents/orchestrator.md" | head -1)
  assert_contains "$line" '**[orchestrator] BLOCKED**' "#75: orchestrator.md posts BLOCKED" || return 1
  assert_not_contains "$line" 'post nothing' "#75: no longer silent" || return 1
}

run_test test_i75_markers_for_orchestrator
run_test test_i75_marker_re_all_agents_matches_orchestrator_blocked
run_test test_i75_supervisor_parks_config_error_refusal
run_test test_i75_orchestrator_md_posts_blocked
