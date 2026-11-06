# Issue #587 — claim arbitration: while agent-in-progress is on, the host of the latest claim before this host's own claim
# owns the run whatever its age; the 600 s window only settles fresh races. Both readers (GraphQL + REST) and reconcile share
# claim_foreign_owner. Placeholder repo names only. Uses the shared fake gh.

HERE_CO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_CO="$HERE_CO/../pipeline-lib.sh"

co_env() {  # co_env <label_on 0|1>
  CO_HOME=$(new_home); CO_BIN="$CO_HOME/.local/bin"; mk_fake_gh "$CO_BIN"
  [ "$1" = 1 ] && echo '[{"name":"agent-in-progress"}]' > "$CO_BIN/gh-issue-labels-json"
  CO_ME=$(hostname -s)
}
co_claim() {  # co_claim <host> <secs-ago>
  local t; t=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$2")
  jq -nc --arg b "**[supervisor] NOTE** claim: $1 $t" --arg t "$t" '{body:$b,createdAt:$t}' >> "$CO_BIN/gh-claims.jsonl"
}
co_run() {  # co_run <gql|rest> -> winner on stdout
  ( export HOME="$CO_HOME" PATH="$CO_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$CO_HOME/pipe"; mkdir -p "$PIPE"
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
test_co_unreadable_label_fails_closed() {
  co_env 1; co_claim "$CO_ME" 20; echo 1 > "$CO_BIN/gh-issue-view-rc"
  local out rc
  out=$(co_run rest); rc=$?
  rm -rf "$CO_HOME"
  assert_eq "$rc" "1" "#587: unreadable comment/label read returns 1" || return 1
  assert_eq "$out" "" "#587: nothing printed on a failed read" || return 1
}
test_co_reconcile_uses_shared_helper() {
  grep -q 'claim_foreign_owner' "$HERE_CO/../supervisor.sh" || { fail "#587: reconcile must use claim_foreign_owner"; return 1; }
}

run_test test_co_incident_replay_aged_owner_wins
run_test test_co_fresh_race_earliest_wins
run_test test_co_own_restart_wins
run_test test_co_dead_owner_label_left_on_no_autolaunch
run_test test_co_unreadable_label_fails_closed
run_test test_co_reconcile_uses_shared_helper
