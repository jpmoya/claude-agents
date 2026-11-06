# Issue #587 — claim arbitration: while agent-in-progress is on, the host of the latest claim before this host's own claim
# owns the run whatever its age; the 600 s window only settles fresh races. Both readers (GraphQL + REST) and reconcile share
# claim_foreign_owner. Placeholder repo names only. Uses the shared fake gh.

HERE_CO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_CO="$HERE_CO/../pipeline-lib.sh"

co_env() {  # co_env <label_on 0|1>
  CO_HOME=$(new_home); CO_BIN="$CO_HOME/.local/bin"; mk_fake_gh "$CO_BIN"
  [ "$1" = 1 ] && echo '[{"name":"agent-in-progress"}]' > "$CO_BIN/gh-issue-labels-json"
  CO_ME=$(hostname -s); CO_AS=$CO_ME; CO_N=0
  printf '#!/bin/sh\necho "${CO_AS:-%s}"\n' "$CO_ME" > "$CO_BIN/hostname"; chmod +x "$CO_BIN/hostname"   # lets one test play either host
}
co_claim() {  # co_claim <host> <secs-ago>
  local t; t=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$2")
  CO_N=$((CO_N + 1))
  jq -nc --arg b "**[supervisor] NOTE** claim: $1 $t" --arg t "$t" --arg u "https://github.com/project-a/repo-a/issues/42#issuecomment-$CO_N" \
    '{body:$b,createdAt:$t,url:$u}' >> "$CO_BIN/gh-claims.jsonl"
}
co_run() {  # co_run <gql|rest> -> winner on stdout
  ( export HOME="$CO_HOME" PATH="$CO_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$CO_HOME/pipe"; mkdir -p "$PIPE"
    export LOGDIR="$CO_HOME/logs" CO_AS="${CO_AS:-}"
    . "$LIB_CO" >/dev/null 2>&1
    if [ "$1" = rest ]; then claim_winner_rest project-a/repo-a 42; else claim_winner "$CO_HOME" 42; fi )
}

test_co_incident_replay_aged_owner_wins() {   # VM claimed 1100 s ago (past the window), label on, this host claims now: loses
  local m
  for m in gql rest; do
    co_env 1; co_claim otherhost 1100; co_claim "$CO_ME" 20
    assert_eq "$(co_run $m)" "otherhost" "#587 ($m): label on, other host's claim is older than the window -> it still owns the run" || return 1
    rm -rf "$CO_HOME"
  done
}
test_co_fresh_race_earliest_wins() {   # no label: earliest claim in the window wins
  local m
  for m in gql rest; do
    co_env 0; co_claim otherhost 20; co_claim "$CO_ME" 15
    assert_eq "$(co_run $m)" "otherhost" "#587 ($m): no label, other host claimed first -> it wins" || return 1
    rm -rf "$CO_HOME"; co_env 0; co_claim "$CO_ME" 20; co_claim otherhost 15
    assert_eq "$(co_run $m)" "$CO_ME" "#587 ($m): no label, this host claimed first -> it wins" || return 1
    rm -rf "$CO_HOME"
  done
}
test_co_own_restart_wins() {   # label on, the latest prior claim is this host's own (even an aged one)
  local m
  for m in gql rest; do
    co_env 1; co_claim "$CO_ME" 1100; co_claim "$CO_ME" 20
    assert_eq "$(co_run $m)" "$CO_ME" "#587 ($m): own-host restart wins" || return 1
    rm -rf "$CO_HOME"
  done
}
test_co_dead_owner_label_left_on_no_autolaunch() {   # owner died, label stays: the other host never auto-takes over (--force does)
  co_env 1; co_claim otherhost 7200; co_claim "$CO_ME" 20
  assert_eq "$(co_run gql)" "otherhost" "#587: a 2h-old foreign claim with the label on still owns the run" || { rm -rf "$CO_HOME"; return 1; }
  rm -rf "$CO_HOME"
  grep -q -- '--force' <(awk '/^# claim_pick/,/^claim_pick\(\)/' "$LIB_CO") || { fail "#587: claim_pick comment must name --force as the takeover path"; return 1; }
}
co_events() { cat "$CO_HOME/logs/events.jsonl" 2>/dev/null; }
test_co_unreadable_label_fails_closed() {   # comments read fine, only the label/issue read fails
  local m out rc
  co_env 1; co_claim "$CO_ME" 20; echo 1 > "$CO_BIN/gh-issue-labels-rc"
  out=$(co_run rest); rc=$?
  assert_eq "$rc" "1" "#587: unreadable label read returns 1" || return 1
  assert_eq "$out" "" "#587: nothing printed on a failed label read" || return 1
  assert_contains "$(co_events)" '"event":"claim_lookup_failed"' "#587: label failure records claim_lookup_failed" || return 1
  assert_contains "$(co_events)" '"route":"claim-arbitration"' "#587: event carries the route tag" || return 1
  assert_contains "$(co_events)" '"release":' "#587: event carries release" || return 1
  assert_contains "$(co_events)" '"environment":' "#587: event carries environment" || return 1
  rm -rf "$CO_HOME"
}
test_co_unreadable_comments_fails_closed() {
  local m out rc
  for m in gql rest; do
    co_env 1; co_claim "$CO_ME" 20; echo 1 > "$CO_BIN/gh-issue-view-rc"
    out=$(co_run $m); rc=$?
    assert_eq "$rc" "1" "#587 ($m): unreadable comment read returns 1" || return 1
    assert_eq "$out" "" "#587 ($m): nothing printed" || return 1
    assert_contains "$(co_events)" '"event":"claim_lookup_failed"' "#587 ($m): records claim_lookup_failed" || return 1
    rm -rf "$CO_HOME"
  done
}
test_co_loser_withdraws_claim_owner_restart_wins() {   # vm 1100 s, mac 500 s (loses, withdraws), vm 20 s: both hosts agree vm owns
  local m
  for m in gql rest; do
    co_env 1; co_claim otherhost 1100; co_claim "$CO_ME" 500
    assert_eq "$(co_run $m)" "otherhost" "#587 ($m): this host loses to the aged owner" || return 1
    assert_contains "$(gh_calls "$CO_BIN")" "api -X DELETE repos/project-a/repo-a/issues/comments/2" "#587 ($m): the loser deletes its own claim comment" || return 1
    assert_not_contains "$(cat "$CO_BIN/gh-claims.jsonl")" "$CO_ME" "#587 ($m): loser's claim is gone from the history" || return 1
    CO_N=2; co_claim otherhost 20                               # the owner restarts
    CO_AS=otherhost; assert_eq "$(co_run $m)" "otherhost" "#587 ($m): owner's restart wins after the loser withdrew" || return 1
    rm -rf "$CO_HOME"
  done
}
test_co_winner_deletes_nothing() {
  co_env 1; co_claim "$CO_ME" 1100; co_claim "$CO_ME" 20
  assert_eq "$(co_run rest)" "$CO_ME" "#587: own restart wins" || return 1
  assert_eq "$(gh_call_count "$CO_BIN" 'DELETE')" "0" "#587: the winner deletes no claim" || return 1
  rm -rf "$CO_HOME"
}
test_co_reconcile_rule_behaviour() {   # reconcile pipes claims into claim_foreign_owner (see test-reconcile-cross-host.sh for the end-to-end run)
  local t_old t_new
  t_old=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=7200)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  t_new=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  ( . "$LIB_CO" >/dev/null 2>&1
    c=$(jq -nc --arg o "**[supervisor] NOTE** claim: otherhost $t_old" --arg a "$t_old" '[{b:$o,t:$a}]')
    assert_eq "$(printf '%s' "$c" | claim_foreign_owner thishost)" "otherhost" "#587: 2h-old foreign claim still owns the run" || exit 1
    c=$(jq -nc --arg o "**[supervisor] NOTE** claim: otherhost $t_old" --arg a "$t_old" --arg m "**[supervisor] NOTE** claim: thishost $t_new" --arg n "$t_new" '[{b:$o,t:$a},{b:$m,t:$n}]')
    assert_eq "$(printf '%s' "$c" | claim_foreign_owner thishost)" "" "#587: latest claim is this host's -> no foreign owner" || exit 1
    assert_eq "$(printf '[]' | claim_foreign_owner thishost)" "" "#587: no claims -> no foreign owner" || exit 1 ) || return 1
  grep -q 'claim_foreign_owner "\$HOST"' "$HERE_CO/../supervisor.sh" || { fail "#587: reconcile must call claim_foreign_owner"; return 1; }
}

run_test test_co_incident_replay_aged_owner_wins
run_test test_co_fresh_race_earliest_wins
run_test test_co_own_restart_wins
run_test test_co_dead_owner_label_left_on_no_autolaunch
run_test test_co_unreadable_label_fails_closed
run_test test_co_unreadable_comments_fails_closed
run_test test_co_loser_withdraws_claim_owner_restart_wins
run_test test_co_winner_deletes_nothing
run_test test_co_reconcile_rule_behaviour
