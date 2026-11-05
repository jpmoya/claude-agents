# skills/orchestrate/lib/backlog-sort.jq — unit tests against plain `jq`, independent of gh/the
# supervisor (the integration-level dispatch tests live in test-supervisor-backlog-priority.sh).
# Input shape: [{n, g, k}, ...] already sorted by k (today's milestone+issue tiebreak); g = true
# for a goal-labelled ticket. --argjson prio is the per-repo rank map.
BSJ_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BSJ_FILE="$BSJ_HERE/../lib/backlog-sort.jq"

bsj_run() {  # bsj_run <input json> <prio json> -> space-joined output numbers
  printf '%s' "$1" | jq --argjson prio "$2" -f "$BSJ_FILE" 2>/dev/null | tr '\n' ' '
}

test_bsj_empty_prio_reproduces_input_order() {
  local got; got=$(bsj_run '[{"n":8,"g":false,"k":[0,1,0,0,8]},{"n":7,"g":false,"k":[1,0,0,0,7]}]' '{}')
  assert_eq "$got" "8 7 " "empty store: order unchanged" || return 1
}

test_bsj_ranked_tickets_sort_by_rank_ascending() {
  local got; got=$(bsj_run '[{"n":1,"g":false,"k":[1,0,0,0,1]},{"n":2,"g":false,"k":[1,0,0,0,2]},{"n":3,"g":false,"k":[1,0,0,0,3]}]' '{"3":0,"1":1,"2":2}')
  assert_eq "$got" "3 1 2 " "lowest rank dispatched first" || return 1
}

test_bsj_unranked_after_ranked_in_original_order() {
  local got; got=$(bsj_run '[{"n":5,"g":false,"k":[1,0,0,0,5]},{"n":6,"g":false,"k":[0,1,0,0,6]}]' '{"5":0}')
  assert_eq "$got" "5 6 " "an explicit rank beats the fallback tier even when the fallback k would sort it first" || return 1
}

test_bsj_goal_ticket_position_is_never_touched() {
  local got; got=$(bsj_run '[{"n":1,"g":false,"k":[1,0,0,0,1]},{"n":2,"g":true,"k":[1,0,0,0,2]},{"n":3,"g":false,"k":[1,0,0,0,3]}]' '{"3":0,"1":1}')
  assert_eq "$got" "3 2 1 " "goal ticket (middle slot) keeps its position; only the two non-goal slots swap" || return 1
}

test_bsj_all_goal_tickets_are_a_no_op() {
  local got; got=$(bsj_run '[{"n":1,"g":true,"k":[1,0,0,0,1]},{"n":2,"g":true,"k":[1,0,0,0,2]}]' '{"2":0,"1":1}')
  assert_eq "$got" "1 2 " "a rank on a goal ticket (should never be stored, but if it were) changes nothing" || return 1
}

test_bsj_corrupt_prio_argument_is_the_callers_job_not_this_filters() {
  # backlog-sort.jq trusts --argjson prio to already be a valid object (supervisor.sh guarantees
  # {} on any read/parse failure before invoking jq at all) -- this pins that contract in words,
  # the actual fallback-to-{} behaviour is exercised end to end in test-supervisor-backlog-priority.sh.
  local got; got=$(bsj_run '[{"n":1,"g":false,"k":[1,0,0,0,1]}]' '{}')
  assert_eq "$got" "1 " "well-formed empty prio: single ticket passes through" || return 1
}

run_test test_bsj_empty_prio_reproduces_input_order
run_test test_bsj_ranked_tickets_sort_by_rank_ascending
run_test test_bsj_unranked_after_ranked_in_original_order
run_test test_bsj_goal_ticket_position_is_never_touched
run_test test_bsj_all_goal_tickets_are_a_no_op
run_test test_bsj_corrupt_prio_argument_is_the_callers_job_not_this_filters
