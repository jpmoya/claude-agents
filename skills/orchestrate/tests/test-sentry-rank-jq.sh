# skills/orchestrate/lib/sentry-rank.jq (#761) — unit tests against plain `jq`, independent of gh/the supervisor
# (the integration-level dispatch tests live in test-supervisor-sentry-rank.sh).
# Input shape: [{n, g, s, e, u, f}, ...]; --argjson order = candidate numbers in current dispatch order.
SRJ_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRJ_FILE="$SRJ_HERE/../lib/sentry-rank.jq"

srj_run() {  # srj_run <input json> <order json> -> space-joined output numbers
  printf '%s' "$1" | jq --argjson order "$2" -f "$SRJ_FILE" 2>/dev/null | tr '\n' ' '
}

test_srj_users_weigh_more_than_events() {
  # lexicographic: 3 users beats 1 user beats 0 users, however many events
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":500,"u":0},{"n":2,"g":false,"s":true,"e":0,"u":1},{"n":3,"g":false,"s":true,"e":0,"u":3}]' '[1,2,3]')
  assert_eq "$got" "3 2 1 " "users first: 3 users, then 1 user, then 500 events with no user" || return 1
}

test_srj_events_break_a_users_tie() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":3,"u":2},{"n":2,"g":false,"s":true,"e":40,"u":2},{"n":3,"g":false,"s":true,"e":9,"u":2}]' '[1,2,3]')
  assert_eq "$got" "2 3 1 " "same users: more events first" || return 1
}

test_srj_older_first_seen_breaks_a_users_and_events_tie() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":5,"u":1,"f":"2026-11-10"},{"n":2,"g":false,"s":true,"e":5,"u":1,"f":"2026-11-02"},{"n":3,"g":false,"s":true,"e":5,"u":1,"f":""},{"n":4,"g":false,"s":true,"e":5,"u":1}]' '[1,3,4,2]')
  assert_eq "$got" "2 1 3 4 " "older date first, undated after dated, undated keep incoming order" || return 1
}

test_srj_ties_keep_existing_order() {
  local got; got=$(srj_run '[{"n":7,"g":false,"s":true,"e":2,"u":0},{"n":5,"g":false,"s":true,"e":2,"u":0},{"n":9,"g":false,"s":true,"e":2,"u":0}]' '[7,5,9]')
  assert_eq "$got" "7 5 9 " "equal scores: the incoming order stands" || return 1
}

test_srj_non_sentry_slots_keep_their_positions() {
  # slots 0 and 2 are sentry; 20 (slot 1) and 40 (slot 3) are not and must not move
  local got; got=$(srj_run '[{"n":10,"g":false,"s":true,"e":1,"u":0},{"n":20,"g":false,"s":false,"e":999,"u":99},{"n":30,"g":false,"s":true,"e":0,"u":2},{"n":40,"g":false,"s":false,"e":0,"u":0}]' '[10,20,30,40]')
  assert_eq "$got" "30 20 10 40 " "only the two sentry slots swap" || return 1
}

test_srj_goal_slot_keeps_position_even_with_sentry_label() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":1,"u":0},{"n":2,"g":true,"s":true,"e":0,"u":9},{"n":3,"g":false,"s":true,"e":0,"u":1}]' '[1,2,3]')
  assert_eq "$got" "3 2 1 " "goal ticket stays in the middle; the other two sentry slots swap" || return 1
}

test_srj_follows_the_given_order_not_the_input_array_order() {
  # backlog-sort.jq may have reordered; the rank works on the slots of $order
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":1,"u":0},{"n":2,"g":false,"s":false,"e":0,"u":0},{"n":3,"g":false,"s":true,"e":8,"u":0}]' '[2,1,3]')
  assert_eq "$got" "2 3 1 " "slot 0 is the non-sentry 2; the sentry slots 1,2 are refilled by score" || return 1
}

test_srj_missing_or_garbage_counts_score_zero() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true},{"n":2,"g":false,"s":true,"e":"x","u":null},{"n":3,"g":false,"s":true,"e":1,"u":0}]' '[1,2,3]')
  assert_eq "$got" "3 1 2 " "missing/non-numeric e and u score 0" || return 1
}

test_srj_unknown_number_in_order_is_passed_through_in_place() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":0,"u":0},{"n":3,"g":false,"s":true,"e":0,"u":5}]' '[1,99,3]')
  assert_eq "$got" "3 99 1 " "a number cand_json does not know keeps its slot" || return 1
}

test_srj_no_sentry_candidates_is_a_no_op() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":false,"e":0,"u":0},{"n":2,"g":false,"s":false,"e":5,"u":5}]' '[1,2]')
  assert_eq "$got" "1 2 " "nothing to rank" || return 1
}

test_srj_ci_critical_slot_is_never_traded_away() {
  # x:true = also carries ci-critical (#781): #2 keeps its middle slot; the two plain Sentry slots swap around it
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":1,"u":0},{"n":2,"g":false,"s":true,"x":true,"e":0,"u":0},{"n":3,"g":false,"s":true,"e":5,"u":2}]' '[1,2,3]')
  assert_eq "$got" "3 2 1 " "ci-critical keeps its slot, however high the others score" || return 1
}

test_srj_ci_critical_first_slot_is_not_displaced_by_higher_impact() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"x":true,"e":0,"u":0},{"n":2,"g":false,"s":true,"e":900,"u":50},{"n":3,"g":false,"s":true,"e":9,"u":9}]' '[1,2,3]')
  assert_eq "$got" "1 2 3 " "ci-critical in slot 0 stays first; 2 (higher) is already ahead of 3" || return 1
}

test_srj_users_weigh_more_than_events() {
  # lexicographic: 3 users beats 1 user beats 0 users, however many events
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":500,"u":0},{"n":2,"g":false,"s":true,"e":0,"u":1},{"n":3,"g":false,"s":true,"e":0,"u":3}]' '[1,2,3]')
  assert_eq "$got" "3 2 1 " "users first: 3 users, then 1 user, then 500 events with no user" || return 1
}

test_srj_events_break_a_users_tie() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":3,"u":2},{"n":2,"g":false,"s":true,"e":40,"u":2},{"n":3,"g":false,"s":true,"e":9,"u":2}]' '[1,2,3]')
  assert_eq "$got" "2 3 1 " "same users: more events first" || return 1
}

test_srj_older_first_seen_breaks_a_users_and_events_tie() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":5,"u":1,"f":"2026-11-10"},{"n":2,"g":false,"s":true,"e":5,"u":1,"f":"2026-11-02"},{"n":3,"g":false,"s":true,"e":5,"u":1,"f":""},{"n":4,"g":false,"s":true,"e":5,"u":1}]' '[1,3,4,2]')
  assert_eq "$got" "2 1 3 4 " "older date first, undated after dated, undated keep incoming order" || return 1
}

test_srj_ties_keep_existing_order() {
  local got; got=$(srj_run '[{"n":7,"g":false,"s":true,"e":2,"u":0},{"n":5,"g":false,"s":true,"e":2,"u":0},{"n":9,"g":false,"s":true,"e":2,"u":0}]' '[7,5,9]')
  assert_eq "$got" "7 5 9 " "equal scores: the incoming order stands" || return 1
}

test_srj_non_sentry_slots_keep_their_positions() {
  # slots 0 and 2 are sentry; 20 (slot 1) and 40 (slot 3) are not and must not move
  local got; got=$(srj_run '[{"n":10,"g":false,"s":true,"e":1,"u":0},{"n":20,"g":false,"s":false,"e":999,"u":99},{"n":30,"g":false,"s":true,"e":0,"u":2},{"n":40,"g":false,"s":false,"e":0,"u":0}]' '[10,20,30,40]')
  assert_eq "$got" "30 20 10 40 " "only the two sentry slots swap" || return 1
}

test_srj_goal_slot_keeps_position_even_with_sentry_label() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":1,"u":0},{"n":2,"g":true,"s":true,"e":0,"u":9},{"n":3,"g":false,"s":true,"e":0,"u":1}]' '[1,2,3]')
  assert_eq "$got" "3 2 1 " "goal ticket stays in the middle; the other two sentry slots swap" || return 1
}

test_srj_follows_the_given_order_not_the_input_array_order() {
  # backlog-sort.jq may have reordered; the rank works on the slots of $order
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":1,"u":0},{"n":2,"g":false,"s":false,"e":0,"u":0},{"n":3,"g":false,"s":true,"e":8,"u":0}]' '[2,1,3]')
  assert_eq "$got" "2 3 1 " "slot 0 is the non-sentry 2; the sentry slots 1,2 are refilled by score" || return 1
}

test_srj_missing_or_garbage_counts_score_zero() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true},{"n":2,"g":false,"s":true,"e":"x","u":null},{"n":3,"g":false,"s":true,"e":1,"u":0}]' '[1,2,3]')
  assert_eq "$got" "3 1 2 " "missing/non-numeric e and u score 0" || return 1
}

test_srj_unknown_number_in_order_is_passed_through_in_place() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":0,"u":0},{"n":3,"g":false,"s":true,"e":0,"u":5}]' '[1,99,3]')
  assert_eq "$got" "3 99 1 " "a number cand_json does not know keeps its slot" || return 1
}

test_srj_no_sentry_candidates_is_a_no_op() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":false,"e":0,"u":0},{"n":2,"g":false,"s":false,"e":5,"u":5}]' '[1,2]')
  assert_eq "$got" "1 2 " "nothing to rank" || return 1
}

test_srj_ci_critical_sentry_ticket_is_never_outranked_by_triage() {
  # x:true = also carries ci-critical (#781): it leads whatever the impact of the others
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"e":900,"u":50},{"n":2,"g":false,"s":true,"x":true,"e":0,"u":0},{"n":3,"g":false,"s":true,"e":5,"u":2}]' '[1,3,2]')
  assert_eq "$got" "2 1 3 " "ci-critical first, then by users/events" || return 1
}

test_srj_ci_critical_tickets_rank_among_themselves_by_impact() {
  local got; got=$(srj_run '[{"n":1,"g":false,"s":true,"x":true,"e":1,"u":0},{"n":2,"g":false,"s":true,"x":true,"e":1,"u":4},{"n":3,"g":false,"s":true,"e":99,"u":99}]' '[3,1,2]')
  assert_eq "$got" "2 1 3 " "two ci-critical tickets: more users first; the plain one after both" || return 1
}

run_test test_srj_ci_critical_slot_is_never_traded_away
run_test test_srj_ci_critical_first_slot_is_not_displaced_by_higher_impact
run_test test_srj_users_weigh_more_than_events
run_test test_srj_events_break_a_users_tie
run_test test_srj_older_first_seen_breaks_a_users_and_events_tie
run_test test_srj_ties_keep_existing_order
run_test test_srj_non_sentry_slots_keep_their_positions
run_test test_srj_goal_slot_keeps_position_even_with_sentry_label
run_test test_srj_follows_the_given_order_not_the_input_array_order
run_test test_srj_missing_or_garbage_counts_score_zero
run_test test_srj_unknown_number_in_order_is_passed_through_in_place
run_test test_srj_no_sentry_candidates_is_a_no_op
