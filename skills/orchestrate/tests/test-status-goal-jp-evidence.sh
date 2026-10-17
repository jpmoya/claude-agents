# A registry goal whose tickets all wait on JP shows as "waiting on JP" even with no lead running.
# Registry state stays "active" until a lead writes goal-waiting-jp; goal_queue_derive (goal-lib.sh) adds needs_jp to
# goalqueue.json from the ticket evidence and build-runs-json.py maps it. Reuses gl_* helpers from test-status-goals.sh
# (loaded first alphabetically). Network-free: goal_eval is stubbed, the marker rules themselves are covered elsewhere.

GJ_SKILL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# gj_queue <waiting> <active> [total] — a goalqueue.json with one open "active" goal that carries needs_jp (or none: waiting=-)
gj_queue() {
  local nj='null'
  [ "$1" = "-" ] || nj=$(jq -nc --argjson w "$1" --argjson a "$2" --argjson t "${3:-7}" '{waiting:$w,active:$a,total:$t}')
  jq -nc --argjson nj "$nj" \
    '{at:1,candidate:null,recent:[],queued:[],open:[{id:"label-goal__X",issue:360,spec:"label:goal: X",title:"X goal",label:"goal: X",repos:["o/r"],st:"active",host:"claude",priority:1} + (if $nj then {needs_jp:$nj} else {} end)]}' \
    > "$GL_PIPE/goalqueue.json"
}

test_gj_open_goal_all_waiting_is_waiting_jp() {
  gl_env; gj_queue 2 0
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "waiting_jp" "needs_jp waiting>0 active=0 -> waiting_jp" || return 1
}

test_gj_open_goal_some_progressing_stays_between_cycles() {
  gl_env; gj_queue 2 1
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "between_cycles" "a progressable ticket keeps the goal between_cycles" || return 1
}

test_gj_open_goal_without_evidence_stays_between_cycles() {
  gl_env; gj_queue - 0
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "between_cycles" "no needs_jp -> unchanged" || return 1
}

test_gj_open_goal_nothing_waiting_stays_between_cycles() {
  gl_env; gj_queue 0 0
  local out; out=$(gl_mode); gl_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].state')" "between_cycles" "waiting=0 -> unchanged" || return 1
}

# goal_queue_derive with goal_eval stubbed: writes needs_jp for a goal whose lead is not alive, skips one whose lead is alive
gj_derive() {  # <waiting> <active> <total> [live] -> prints the goalqueue open[0] as compact json
  local w=$1 a=$2 t=$3 live=${4:-}
  gl_env; gj_queue -  0
  [ -z "$live" ] || gl_live_pid "label-goal__X"
  (
    PIPE="$GL_PIPE"; GOAL_QUEUE_FILE_NAME=goalqueue.json
    # shellcheck disable=SC1090
    . "$GJ_SKILL/goal-lib.sh" >/dev/null 2>&1
    PIPE="$GL_PIPE"
    latest_marker() { :; }
    goal_err() { :; }
    goal_eval() { GE_TOTAL=$t; GE_WAITING=$w; GE_ACTIVE=$a; GE_DELIVERED=$((t - w - a)); [ -z "${3:-}" ] || GJ_ROWS=$3; [ -n "${3:-}" ] || [ -z "${GJ_EMPTY:-}" ] || GE_TOTAL=0; return 0; }
    reg=${GJ_REG:-}; [ -n "$reg" ] || reg='[{"id":"label-goal__X","spec":"label:goal: X","st":"active"}]'
    goal_queue_derive "$reg"
    jq -c '.open[0].needs_jp // null' "$GL_PIPE/goalqueue.json"
  )
  gl_cleanup
}

test_gj_derive_records_evidence() {
  local r; r=$(gj_derive 2 0 7)
  assert_eq "$r" '{"waiting":2,"active":0,"total":7}' "derive writes the counts for a lead-less goal" || return 1
}

test_gj_derive_skips_live_lead() {
  local r; r=$(gj_derive 2 0 7 live)
  assert_eq "$r" "null" "a live lead mirrors its own state: no derived evidence" || return 1
}

test_gj_derive_nothing_waiting_writes_nothing() {
  local r; r=$(gj_derive 0 3 7)
  assert_eq "$r" "null" "no ticket waiting on JP -> no needs_jp" || return 1
}
run_test test_gj_open_goal_all_waiting_is_waiting_jp
run_test test_gj_open_goal_some_progressing_stays_between_cycles
run_test test_gj_open_goal_without_evidence_stays_between_cycles
run_test test_gj_open_goal_nothing_waiting_stays_between_cycles
run_test test_gj_derive_records_evidence
run_test test_gj_derive_skips_live_lead
run_test test_gj_derive_nothing_waiting_writes_nothing

# the label is gone from the tickets (scope empty): the go-granted list in the registry block is the scope
test_gj_derive_falls_back_to_granted_list() {
  local r
  GJ_EMPTY=1; GJ_REG='[{"id":"label-goal__X","spec":"label:goal: X","st":"active","block":{"granted":["o/r#1","o/r#2"]}}]'
  r=$(gj_derive 2 0 2); unset GJ_EMPTY GJ_REG
  assert_eq "$r" '{"waiting":2,"active":0,"total":2}' "empty label scope -> evaluate block.granted" || return 1
}
test_gj_derive_empty_scope_without_granted_writes_nothing() {
  local r
  GJ_EMPTY=1; r=$(gj_derive 2 0 2); unset GJ_EMPTY
  assert_eq "$r" "null" "empty scope and no granted list -> no evidence" || return 1
}
run_test test_gj_derive_falls_back_to_granted_list
run_test test_gj_derive_empty_scope_without_granted_writes_nothing
