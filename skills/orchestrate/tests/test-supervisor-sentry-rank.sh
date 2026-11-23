# #761 — supervisor.sh's shared-dispatch step 5 ranks the sentry-auto-go candidates by impact
# (`Events: N   Users: M   First seen: DATE` in the ticket body: users, then events, then older first-seen) among the slots
# they already occupy; non-Sentry and goal slots keep their positions; a body without parseable
# counts scores 0. Reuses test-intake-supervisor.sh / test-supervisor-release-order.sh helpers.
HERE_SR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$(type -t si_env)" = function ] || . "$HERE_SR/test-intake-supervisor.sh"
[ "$(type -t rq_issue)" = function ] || . "$HERE_SR/test-supervisor-release-order.sh"

# sr_body <issue> <body text> — sets the body of an already added fixture issue
sr_body() {
  jq --argjson n "$1" --arg b "$2" 'map(if .number == $n then . + {body: $b} else . end)' "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
}

test_sr_highest_impact_sentry_ticket_dispatched_first() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go; rq_issue 3 "" agent-go sentry-auto-go
  sr_body 1 $'Sentry error\nEvents: 1   Users: 0   First seen: 2026-11-01'
  sr_body 2 $'Sentry error\nEvents: 40   Users: 3   First seen: 2026-11-02'
  sr_body 3 $'Sentry error\nEvents: 900   Users: 1   First seen: 2026-11-03'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "2 3 1 " "3 users beats 1 user (despite 900 events) beats 0 users" || return 1
}

test_sr_same_users_and_events_older_first_seen_first() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go
  sr_body 1 $'Events: 4   Users: 2   First seen: 2026-11-12'
  sr_body 2 $'Events: 4   Users: 2   First seen: 2026-11-03'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "2 1 " "equal users and events: the older first-seen goes first" || return 1
}

test_sr_non_sentry_slot_keeps_its_position() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go; rq_issue 3 "" agent-go sentry-auto-go
  sr_body 1 $'Events: 1   Users: 0'
  sr_body 2 $'Events: 5000   Users: 90'    # not a Sentry auto-go ticket: its score is irrelevant
  sr_body 3 $'Events: 1   Users: 5'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "3 2 1 " "plain ticket #2 stays in the middle; the two sentry slots swap" || return 1
}

test_sr_goal_slot_keeps_its_position() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go "goal: Something"; rq_issue 3 "" agent-go sentry-auto-go
  sr_body 1 $'Events: 1   Users: 0'
  sr_body 2 $'Events: 1   Users: 50'
  sr_body 3 $'Events: 1   Users: 5'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "3 2 1 " "goal-labelled #2 keeps its slot even though it carries sentry-auto-go and the top score" || return 1
}

test_sr_missing_or_unparseable_counts_score_zero_and_keep_order() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go; rq_issue 3 "" agent-go sentry-auto-go; rq_issue 4 "" agent-go sentry-auto-go
  # #1 no body at all; #2 junk; #3 a 20-digit count (not parsed); #4 a real one
  sr_body 2 $'Events: lots   Users: -3'
  sr_body 3 $'Events: 99999999999999999999   Users: 0'
  sr_body 4 $'Events: 2   Users: 0'
  rq_wrap failclaim
  si_tick
  local got log; got=$(rq_order); log=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); si_cleanup
  assert_eq "$got" "4 1 2 3 " "only #4 scores; the zero-score tickets keep today's order" || return 1
  assert_not_contains "$log" "listing or release sort failed" "bad bodies never abort the repo's dispatch" || return 1
}

test_sr_no_bodies_reproduces_todays_order() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go; rq_issue 3 ""
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "1 2 3 " "all scores 0: today's order unchanged" || return 1
}

test_sr_free_text_cannot_fake_the_stats_line() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go
  # #1: the real stats line is last; Symptoms text above it quotes a fake pair mid-line and another at a line start
  sr_body 1 $'Symptoms: log says "Events: 99999 Users: 99999" often\nEvents: 99999 Users: 99999 (pasted)\nEvents: 1   Users: 0   First seen: 2026-11-01'
  sr_body 2 $'Symptoms: none\nEvents: 5   Users: 2   First seen: 2026-11-02'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "2 1 " "#1 scores its real last stats line (0 users), not the pasted 99999 pair" || return 1
}

test_sr_ci_critical_sentry_ticket_keeps_its_slot() {
  si_env
  rq_issue 1 "" agent-go sentry-auto-go; rq_issue 2 "" agent-go sentry-auto-go ci-critical; rq_issue 3 "" agent-go sentry-auto-go
  sr_body 1 $'Events: 1   Users: 0'
  sr_body 2 $'Events: 9000   Users: 90'
  sr_body 3 $'Events: 20   Users: 5'
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "3 2 1 " "ci-critical #2 stays in the middle slot; only the two plain Sentry slots swap" || return 1
}

run_test test_sr_free_text_cannot_fake_the_stats_line
run_test test_sr_ci_critical_sentry_ticket_keeps_its_slot
run_test test_sr_highest_impact_sentry_ticket_dispatched_first
run_test test_sr_same_users_and_events_older_first_seen_first
run_test test_sr_non_sentry_slot_keeps_its_position
run_test test_sr_goal_slot_keeps_its_position
run_test test_sr_missing_or_unparseable_counts_score_zero_and_keep_order
run_test test_sr_no_bodies_reproduces_todays_order
