# Backlog priority (JP's drag-and-reorder view on the status page) — supervisor.sh's shared-dispatch
# step 5 (around "5. Shared dispatch") reorders candidates by $PIPE/backlog-priority.json
# ({"owner/repo#issue": rank}, lower rank dispatched first) instead of the plain milestone+issue
# tiebreak, but:
#   - a ticket the store has no rank for still sorts by today's milestone+issue order, after every
#     ranked ticket (so a new agent-go ticket defaults to the bottom of the explicit order);
#   - a missing or corrupt store never aborts dispatch for the repo (falls back to {});
#   - a ticket carrying a "goal: " label is NEVER reordered by this feature — it keeps the exact
#     slot today's sort already gave it; only non-goal tickets are shuffled among themselves.
# Reuses test-intake-supervisor.sh / test-supervisor-release-order.sh's rq_* helpers (this file
# must sort after both — it does: "supervisor-queue" < "supervisor-release" < this).
HERE_BP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$(type -t si_env)" = function ] || . "$HERE_BP/test-intake-supervisor.sh"
[ "$(type -t rq_issue)" = function ] || . "$HERE_BP/test-supervisor-release-order.sh"

# bp_store <json> — writes $SI_PIPE/backlog-priority.json
bp_store() { printf '%s' "$1" > "$SI_PIPE/backlog-priority.json"; }

test_bpq_stored_priority_wins_over_fallback_order() {
  si_env
  rq_issue 10 ""; rq_issue 20 ""; rq_issue 30 ""
  bp_store '{"project-a/repo-a#30":0,"project-a/repo-a#10":1}'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "30 10 20 " "ranked tickets first (lowest rank), unranked after, in today's order" || return 1
}

test_bpq_untracked_ticket_defaults_to_todays_order() {
  si_env
  rq_issue 1 ""; rq_issue 2 ""
  # no store at all
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "1 2 " "no store: today's order (issue asc) unchanged" || return 1
}

test_bpq_corrupt_store_falls_back_and_does_not_abort_dispatch() {
  si_env
  rq_issue 1 ""; rq_issue 2 ""
  printf '{not valid json' > "$SI_PIPE/backlog-priority.json"
  rq_wrap failclaim
  si_tick
  local got log; got=$(rq_order); log=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); si_cleanup
  assert_eq "$got" "1 2 " "corrupt store: falls back to today's order" || return 1
  assert_not_contains "$log" "listing or release sort failed" "corrupt store never aborts the repo's dispatch" || return 1
}

test_bpq_goal_ticket_keeps_its_position_never_reordered() {
  si_env
  rq_issue 1 "" agent-go
  rq_issue 2 "" agent-go "goal: Something"
  rq_issue 3 "" agent-go
  # today's order (no store) is 1 2 3; rank #3 highest priority, #1 next, #2 (goal) unranked
  bp_store '{"project-a/repo-a#3":0,"project-a/repo-a#1":1}'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "3 2 1 " "goal ticket (#2) keeps its original middle slot; only the two non-goal slots swap" || return 1
}

run_test test_bpq_stored_priority_wins_over_fallback_order
run_test test_bpq_untracked_ticket_defaults_to_todays_order
run_test test_bpq_corrupt_store_falls_back_and_does_not_abort_dispatch
run_test test_bpq_goal_ticket_keeps_its_position_never_reordered
