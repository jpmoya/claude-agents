# Status page alert banner, alert 1 (JP, 2026-11-19; #762 in part): why the goal queue is not moving.
#   - goal_queue_save writes `unreadable` ([{id, issue}], serial mode only) into goalqueue.json; candidate / slot / queued are unchanged.
#   - build-runs-json.py `goalstall` mode, wired by report-status.sh as the payload's `goal_stall` key only when non-empty, reports an
#     unreadable registry entry and a project goal whose scope cannot be read (error events on route goal-project-scope in events.jsonl,
#     younger than 15 minutes), each with the queued goals it blocks. Nothing when no goal is queued or GOAL_SERIAL is off.
# Expected values hand-written. Prefix gst_.

GST_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_GST="$GST_HERE/.."

gst_env() { GST_PIPE=$(new_pipe); GST_HOME=$(new_home); GST_EVENTS="$GST_HOME/events.jsonl"; : > "$GST_EVENTS"; }
gst_cleanup() { rm -rf "$GST_PIPE" "$GST_HOME"; return 0; }
gst_mode() {
  PATH="$PATH" STATUS_EVENTS_FILE="$GST_EVENTS" python3 "$RS_GST/build-runs-json.py" "" "$GST_HOME/runs.jsonl" "$GST_PIPE" goalstall </dev/null 2>/dev/null
}
gst_ts() { date -u -r "$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
# gst_event <seconds ago> <route> <message>
gst_event() { jq -nc --arg ts "$(gst_ts "$1")" --arg r "$2" --arg m "$3" '{v:1,ts:$ts,host:"h",event:"error",level:"error",route:$r,message:$m}' >> "$GST_EVENTS"; }
gst_queue() {  # gst_queue <json> -> $PIPE/goalqueue.json
  printf '%s' "$1" > "$GST_PIPE/goalqueue.json"
}
GST_QUEUED='[{"id":"q1","issue":21,"title":"Sales Workflow 3.0"},{"id":"q2","issue":22,"title":"Plants Goal"}]'

test_gst_queue_save_records_unreadable_entries() {
  gst_env
  local reg out
  reg='[{"issue":9,"id":"registry-issue-9","spec":"","host":"","state":"open","closed_at":null,"block":null,"st":"unreadable"},
        {"issue":21,"id":"q1","spec":"s1","host":"","state":"open","closed_at":null,"st":"queued","block":{"title":"Q one"}},
        {"issue":22,"id":"q2","spec":"s2","host":"","state":"open","closed_at":null,"st":"queued","block":{"title":"Q two"}}]'
  out=$(bash -c ". '$RS_GST/config.sh' >/dev/null 2>&1; PIPE='$GST_PIPE'; . '$RS_GST/pipeline-lib.sh' >/dev/null 2>&1; . '$RS_GST/goal-lib.sh' >/dev/null 2>&1; PIPE='$GST_PIPE'; GOAL_SERIAL=1; goal_queue_save \"\$1\"; jq -c '{unreadable,candidate,slot,queued:(.queued|map(.id))}' '$GST_PIPE/goalqueue.json'" _ "$reg")
  gst_cleanup
  assert_eq "$out" '{"unreadable":[{"id":"registry-issue-9","issue":9}],"candidate":null,"slot":null,"queued":["q1","q2"]}' \
    "the unreadable entry is listed; it still blocks the candidate (queue behaviour unchanged); queued order kept" || return 1
}

test_gst_unreadable_entry_blocks_both_queued_goals() {
  gst_env
  gst_queue "{\"serial\":true,\"slot\":null,\"candidate\":null,\"unreadable\":[{\"id\":\"registry-issue-9\",\"issue\":9}],\"queued\":$GST_QUEUED,\"open\":[],\"recent\":[]}"
  local j; j=$(gst_mode); gst_cleanup
  assert_eq "$j" '[{"kind": "unreadable", "goal": "registry issue #9", "reason": "its goal block cannot be read, so no queued goal may start", "hint": "fix or close registry issue #9", "blocked": ["Sales Workflow 3.0", "Plants Goal"]}]' \
    "kind, goal, reason, hint and both blocked goals in queue order" || return 1
}

test_gst_nothing_when_no_goal_is_queued_or_serial_is_off() {
  gst_env
  gst_queue '{"serial":true,"slot":null,"candidate":null,"unreadable":[{"id":"registry-issue-9","issue":9}],"queued":[],"open":[],"recent":[]}'
  gst_event 30 goal-project-scope "project goal jpmoya/41: cannot read the project scope: the project is closed"
  local a; a=$(gst_mode)
  gst_queue "{\"unreadable\":[{\"id\":\"registry-issue-9\",\"issue\":9}],\"queued\":$GST_QUEUED,\"open\":[],\"recent\":[]}"   # no "serial": GOAL_SERIAL off
  local b; b=$(gst_mode); gst_cleanup
  assert_eq "$a" '[]' "no queued goal: nothing is blocked" || return 1
  assert_eq "$b" '[]' "not serial: nothing" || return 1
}

test_gst_closed_project_names_the_goal_and_what_it_blocks() {
  gst_env
  gst_queue "{\"serial\":true,\"slot\":null,\"candidate\":null,\"unreadable\":[],\"queued\":$GST_QUEUED,\"open\":[{\"id\":\"proj-jpmoya_41\",\"issue\":759,\"title\":\"CD hardening\",\"st\":\"active\"}],\"recent\":[]}"
  gst_event 60 goal-project-scope "project goal jpmoya/41: cannot read the project scope: the project is closed"
  gst_event 5 goal-project-scope "project goal jpmoya/41: cannot read the project scope: the project is closed"
  local j; j=$(gst_mode); gst_cleanup
  assert_eq "$j" '[{"kind": "project_error", "goal": "CD hardening", "reason": "the project is closed", "hint": "reopen the project, or stop the goal bound to it (deliver.sh stop)", "blocked": ["Sales Workflow 3.0", "Plants Goal"]}]' \
    "closed project: one entry (newest event per project) named like its goals-list row, reason from the log, hint to reopen" || return 1
}

test_gst_old_or_foreign_events_are_ignored_and_text_is_plain() {
  gst_env
  gst_queue "{\"serial\":true,\"slot\":null,\"candidate\":null,\"unreadable\":[],\"queued\":$GST_QUEUED,\"open\":[],\"recent\":[]}"
  gst_event 2000 goal-project-scope "project goal jpmoya/41: cannot read the project scope: the project is closed"   # 33 min: stopped repeating
  gst_event 5 supervisor/goal "project goal jpmoya/42: cannot read the project scope: the project is closed"          # other route
  gst_event 5 goal-project-scope "project goal jpmoya/43: cannot read the project scope: gh exit 1: <b>boom</b> token"
  local j; j=$(gst_mode); gst_cleanup
  assert_eq "$(printf '%s' "$j" | jq -c 'map({goal,reason})')" '[{"goal":"project jpmoya/43","reason":"gh exit 1: b boom /b token"}]' \
    "only the recent goal-project-scope event; markup characters become spaces" || return 1
}

test_gst_report_status_publishes_goal_stall_only_when_non_empty() {
  gst_env
  local run="HOME=$GST_HOME PIPE=$GST_PIPE QUEUE=$GST_PIPE/queue LOGDIR=$GST_HOME STATUS_EVENTS_FILE=$GST_EVENTS"
  local none; none=$(env $run PATH="$PATH" "$RS_GST/report-status.sh" --print 2>/dev/null | jq -c 'has("goal_stall")')
  gst_queue "{\"serial\":true,\"slot\":null,\"candidate\":null,\"unreadable\":[{\"id\":\"registry-issue-9\",\"issue\":9}],\"queued\":$GST_QUEUED,\"open\":[],\"recent\":[]}"
  local some; some=$(env $run PATH="$PATH" "$RS_GST/report-status.sh" --print 2>/dev/null | jq -c '.goal_stall | map(.kind)')
  gst_cleanup
  assert_eq "$none" 'false' "no stall: no key" || return 1
  assert_eq "$some" '["unreadable"]' "stall: the key carries it" || return 1
}

echo "-- status goal stall (alert banner)"
run_test test_gst_queue_save_records_unreadable_entries
run_test test_gst_unreadable_entry_blocks_both_queued_goals
run_test test_gst_nothing_when_no_goal_is_queued_or_serial_is_off
run_test test_gst_closed_project_names_the_goal_and_what_it_blocks
run_test test_gst_old_or_foreign_events_are_ignored_and_text_is_plain
run_test test_gst_report_status_publishes_goal_stall_only_when_non_empty
