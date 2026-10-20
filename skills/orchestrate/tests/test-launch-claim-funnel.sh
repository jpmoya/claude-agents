# Issue #438 — the claim check lives in do_launch (the single launch funnel), so a queued launch (loop-cap resume,
# auto-restart, plain queue) for a ticket the other host holds never starts; two launch paths for one ticket: one wins.
# Placeholder repo names only. Uses the shared fake gh (claims posted by `issue comment` are readable back).

HERE_CF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP_CF="$HERE_CF/../supervisor.sh"

cf_env() {
  CF_PIPE=$(new_pipe); CF_HOME=$(new_home)
  CF_REPO="$CF_PIPE/repo-a"; fixture_repo "$CF_REPO" "project-a/repo-a"
  CF_BIN="$CF_HOME/.local/bin"; mk_fake_gh "$CF_BIN"
  echo "project-a/repo-a" > "$CF_BIN/gh-name-with-owner"
  echo 'MEM_FLOOR_MB=0' > "$CF_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\nexec sleep 30\n' > "$CF_BIN/claude"; chmod +x "$CF_BIN/claude"
  printf '#!/bin/bash\nexit 0\n' > "$CF_BIN/sleep"; chmod +x "$CF_BIN/sleep"
}
cf_claim() {  # cf_claim <host> <secs-ago>
  local t; t=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$2")
  jq -nc --arg b "**[supervisor] NOTE** claim: $1 $t" --arg t "$t" '{body:$b,createdAt:$t}' >> "$CF_BIN/gh-claims.jsonl"
}
cf_tick() {
  HOME="$CF_HOME" PATH="$CF_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$CF_PIPE" QUEUE="$CF_PIPE/queue" LOGDIR="$CF_HOME/logs/pipeline" \
    "$SUP_CF" >/dev/null 2>&1
}
cf_cleanup() {
  local f pid
  for f in "$CF_PIPE"/orch-*.pid; do [ -e "$f" ] || continue; pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }; done
  rm -rf "$CF_PIPE" "$CF_HOME"
}

test_cf_queued_launch_loses_to_other_host_claim() {
  cf_env
  cf_claim otherhost 30
  mk_queued "$CF_PIPE" 42 "$CF_REPO"
  cf_tick
  local pid=absent q=present
  [ -f "$(rkp "$CF_PIPE/orch-42.pid")" ] && pid=present
  [ -f "$(rkp "$CF_PIPE/queue/orch-42.json")" ] || q=dropped
  cf_cleanup
  assert_eq "$pid" "absent" "#438: other host holds the claim -> do_launch must not start the run" || return 1
  assert_eq "$q" "dropped" "#438: the losing queue entry is dropped" || return 1
}

test_cf_queued_launch_wins_without_foreign_claim() {
  cf_env
  mk_queued "$CF_PIPE" 42 "$CF_REPO"
  cf_tick
  local pid=absent
  [ -f "$(rkp "$CF_PIPE/orch-42.pid")" ] && pid=present
  cf_cleanup
  assert_eq "$pid" "present" "#438: no foreign claim -> the funnel launches" || return 1
}

test_cf_two_launch_paths_only_one_wins() {
  # One ticket, both hosts' launch paths reach the funnel: the earliest claim wins, the later one stands down.
  cf_env
  cf_claim "$(hostname -s)" 40; cf_claim otherhost 20     # this host claimed first -> it launches
  mk_queued "$CF_PIPE" 42 "$CF_REPO"
  cf_tick
  local mine=absent
  [ -f "$(rkp "$CF_PIPE/orch-42.pid")" ] && mine=present
  cf_cleanup
  cf_env
  cf_claim otherhost 40; cf_claim "$(hostname -s)" 20     # the other host claimed first -> this host stands down
  mk_queued "$CF_PIPE" 42 "$CF_REPO"
  cf_tick
  local theirs=absent
  [ -f "$(rkp "$CF_PIPE/orch-42.pid")" ] && theirs=present
  cf_cleanup
  assert_eq "$mine" "present" "#438: earliest claim (this host) launches" || return 1
  assert_eq "$theirs" "absent" "#438: later claimant stands down" || return 1
}

test_cf_claim_check_is_in_do_launch() {
  awk '/^do_launch\(\)/,/^}/' "$SUP_CF" | grep -q 'claim_winner_rest' || { fail "#438: claim_winner_rest must be called inside do_launch"; return 1; }
}

run_test test_cf_queued_launch_loses_to_other_host_claim
run_test test_cf_queued_launch_wins_without_foreign_claim
run_test test_cf_two_launch_paths_only_one_wins
run_test test_cf_claim_check_is_in_do_launch
