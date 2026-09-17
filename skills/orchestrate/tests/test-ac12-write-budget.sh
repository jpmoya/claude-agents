# AC12 — the write-budget arithmetic (verified current free-tier cap, worst-case event volume for
# two hosts, chosen coalescing interval) is shown in the PR description or a code comment, and a
# test asserts steady-state + worst-case-burst writes per host stay under the verified cap.
#
# Arithmetic (from the design, issue #4 §3 / #10 Design — the developer's PR re-verifies the cap
# against Cloudflare's live limits page; that re-verification itself is not something a test can
# perform, so it's called out as a developer obligation in the handoff, not asserted here):
#   MIN_PUSH_INTERVAL_SECS=10, KEEPALIVE_SECS=600, MAX_PUSHES_PER_DAY=400 (per host).
#   Keep-alive: 86400/600 = 144 writes/host/day -> 288/day for both hosts (29% of the 1,000/day cap).
#   Events: ~10-14 per run x 5-15 runs/host/day, coalesced at 10s -> ~264/host (~53% of cap).
#   Hard ceiling: 2 x 400 = 800/day (80% of cap) whatever the event storm.
# The discriminating assertions are the boundary ones on the per-host daily counter, which is
# exactly what enforces that ceiling regardless of event volume.

HERE_AC12=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC12="$HERE_AC12/.."

today_utc() { python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'))"; }
yesterday_utc() { python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).strftime('%Y-%m-%d'))"; }
now_epoch() { python3 -c "import time; print(int(time.time()))"; }

setup_pushable_fixture() {  # setup_pushable_fixture <pipe> <home> -> config + one running orchestrator (so the payload is non-empty and its hash differs from any seeded last_hash)
  local pipe=$1 home=$2
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
EOF
  mk_running "$pipe" 601 "$pipe/repo-project-a"
}

count_curl_calls() {  # count_curl_calls <bindir> -> number of times the fake curl recorded an invocation
  cat "$1/curl.calls" 2>/dev/null | wc -l | tr -d ' '
}

write_counting_fake_curl() {  # write_counting_fake_curl <bindir>
  cat > "$1/curl" <<'EOF'
#!/bin/bash
echo "1" >> "$(dirname "$0")/curl.calls"
exit 0
EOF
  chmod +x "$1/curl"
}

test_ac12_under_daily_cap_pushes() {
  local pipe home bindir day rc calls
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$pipe" "$home"
  write_counting_fake_curl "$bindir"
  day=$(today_utc)
  python3 -c "
import json
json.dump({'last_hash':'not-the-real-hash','last_push_epoch':0,'last_attempt_epoch':0,'day':'$day','count':399,'fails':0,'last_status':'204'}, open('$pipe/status-push.state','w'))
"
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" PATH="$bindir:/usr/bin:/bin" "$RS_AC12/report-status.sh" event )
  rc=$?
  calls=$(count_curl_calls "$bindir")
  cleanup_running; rm -rf "$pipe" "$home" "$bindir"

  assert_exit0 "$rc" "AC12: reporter exits 0 while under the daily cap" || return 1
  assert_eq "$calls" "1" "AC12: count=399 (< MAX_PUSHES_PER_DAY=400) with a changed payload still pushes" || return 1
}

test_ac12_at_daily_cap_never_pushes() {
  local pipe home bindir day rc calls
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$pipe" "$home"
  write_counting_fake_curl "$bindir"
  day=$(today_utc)
  python3 -c "
import json
json.dump({'last_hash':'not-the-real-hash','last_push_epoch':0,'last_attempt_epoch':0,'day':'$day','count':400,'fails':0,'last_status':'204'}, open('$pipe/status-push.state','w'))
"
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" PATH="$bindir:/usr/bin:/bin" "$RS_AC12/report-status.sh" event )
  rc=$?
  calls=$(count_curl_calls "$bindir")
  cleanup_running; rm -rf "$pipe" "$home" "$bindir"

  assert_exit0 "$rc" "AC12: reporter exits 0 even when capped" || return 1
  assert_eq "$calls" "0" "AC12: count=400 (== MAX_PUSHES_PER_DAY) must never push — this is the hard ceiling the arithmetic depends on" || return 1
}

test_ac12_utc_day_rollover_resets_counter_and_pushes() {
  local pipe home bindir yday rc calls
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$pipe" "$home"
  write_counting_fake_curl "$bindir"
  yday=$(yesterday_utc)
  python3 -c "
import json
json.dump({'last_hash':'not-the-real-hash','last_push_epoch':0,'last_attempt_epoch':0,'day':'$yday','count':400,'fails':0,'last_status':'204'}, open('$pipe/status-push.state','w'))
"
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" PATH="$bindir:/usr/bin:/bin" "$RS_AC12/report-status.sh" event )
  rc=$?
  calls=$(count_curl_calls "$bindir")
  cleanup_running; rm -rf "$pipe" "$home" "$bindir"

  assert_exit0 "$rc" "AC12: reporter exits 0 across a UTC day rollover" || return 1
  assert_eq "$calls" "1" "AC12: a capped count from a PRIOR UTC day must reset on rollover and push again" || return 1
}

test_ac12_two_pushes_under_10s_apart_coalesce_to_one_curl() {
  # The coalescing half of the arithmetic: MIN_PUSH_INTERVAL_SECS=10 absorbs a burst.
  local pipe home bindir day t rc1 rc2 calls
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$pipe" "$home"
  write_counting_fake_curl "$bindir"
  day=$(today_utc); t=$(now_epoch)
  python3 -c "
import json
json.dump({'last_hash':'not-the-real-hash','last_push_epoch':$t,'last_attempt_epoch':$t,'day':'$day','count':1,'fails':0,'last_status':'204'}, open('$pipe/status-push.state','w'))
"
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" PATH="$bindir:/usr/bin:/bin" "$RS_AC12/report-status.sh" event ); rc1=$?
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" PATH="$bindir:/usr/bin:/bin" "$RS_AC12/report-status.sh" event ); rc2=$?
  calls=$(count_curl_calls "$bindir")
  cleanup_running; rm -rf "$pipe" "$home" "$bindir"

  assert_exit0 "$rc1" "AC12: coalesced call still exits 0" || return 1
  assert_exit0 "$rc2" "AC12: coalesced call still exits 0" || return 1
  assert_eq "$calls" "0" "AC12: two attempts <10s after the last attempt, with an unchanged fixture, coalesce to zero new curls" || return 1
}

test_ac12_constants_match_the_arithmetic_in_a_comment() {
  # Must be real assignments, not just mentioned in the design-contract docstring — comment lines
  # excluded (the AC12 arithmetic comment itself is allowed to name them in prose elsewhere).
  local code hit
  code=$(grep -vE '^[[:space:]]*#' "$RS_AC12/report-status.sh")
  hit=$(echo "$code" | grep -c 'MIN_PUSH_INTERVAL_SECS=10')
  assert_ne "$hit" "0" "AC12: MIN_PUSH_INTERVAL_SECS=10 must be present as a named constant (in real code, not just a comment)" || return 1
  hit=$(echo "$code" | grep -c 'KEEPALIVE_SECS=600')
  assert_ne "$hit" "0" "AC12: KEEPALIVE_SECS=600 must be present as a named constant (in real code, not just a comment)" || return 1
  hit=$(echo "$code" | grep -c 'MAX_PUSHES_PER_DAY=400')
  assert_ne "$hit" "0" "AC12: MAX_PUSHES_PER_DAY=400 must be present as a named constant (in real code, not just a comment)" || return 1
}

run_test test_ac12_under_daily_cap_pushes
run_test test_ac12_at_daily_cap_never_pushes
run_test test_ac12_utc_day_rollover_resets_counter_and_pushes
run_test test_ac12_two_pushes_under_10s_apart_coalesce_to_one_curl
run_test test_ac12_constants_match_the_arithmetic_in_a_comment
