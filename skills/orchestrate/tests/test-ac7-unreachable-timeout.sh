# AC7 — with the push endpoint unreachable, the reporter exits within 10 s and the calling
# supervisor tick / dispatch step completes normally and unaffected (test simulates an
# unreachable/hanging endpoint and asserts the caller's own exit code and duration).
#
# The design pins the client-side bound (`curl --connect-timeout 3 --max-time 5`); this test
# proves the reporter doesn't add a longer wait of its own on top, and that a caller invoking it
# through the real fire-and-forget wrapper is never blocked at all.

HERE_AC7=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC7="$HERE_AC7/.."

start_hang_server() {  # start_hang_server <marker-file> -> prints "PID PORT"
  local marker=$1 line pid port outfile
  outfile=$(mktemp "${TMPDIR:-/tmp}/orch-hang-server-out.XXXXXX")
  python3 "$HERE_AC7/bin/hang-server.py" "$marker" > "$outfile" &
  pid=$!
  # wait for the "PORT n" line (server prints it as soon as it's listening)
  local tries=0
  while [ $tries -lt 50 ]; do
    line=$(grep -m1 '^PORT ' "$outfile" 2>/dev/null || true)
    [ -n "$line" ] && break
    sleep 0.1; tries=$((tries + 1))
  done
  rm -f "$outfile"
  port=${line#PORT }
  echo "$pid $port"
}

test_ac7_reporter_exits_within_10s_and_attempted_the_push() {
  local pipe home marker srv pid port url start end dur rc attempted
  pipe=$(new_pipe); home=$(new_home)
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-hang-hit.XXXXXX")
  srv=$(start_hang_server "$marker")
  pid=${srv%% *}; port=${srv##* }
  if [ -z "$port" ]; then rm -rf "$pipe" "$home"; kill "$pid" 2>/dev/null; fail "AC7: hang-server never reported a port (test infra broken)"; return 1; fi

  url="http://127.0.0.1:$port/beat"
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<EOF
STATUS_PUSH_URL="$url"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
EOF

  start=$(date +%s)
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$RS_AC7/report-status.sh" event ) >/dev/null 2>&1
  rc=$?
  end=$(date +%s)
  dur=$((end - start))

  attempted=absent; [ -e "$marker" ] && attempted=present
  kill "$pid" 2>/dev/null
  rm -rf "$pipe" "$home"; rm -f "$marker"

  assert_lt "$dur" 10 "AC7: reporter duration against a hanging endpoint" || return 1
  assert_exit0 "$rc" "AC7: reporter always exits 0, even on push failure" || return 1
  assert_eq "$attempted" "present" "AC7: the reporter actually attempted the push (server saw a connection) — a no-op that never tries would pass the timing check vacuously" || return 1
}

test_ac7_caller_via_report_status_async_is_never_blocked() {
  local pipe home marker srv pid port url start end dur rc
  pipe=$(new_pipe); home=$(new_home)
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-hang-hit2.XXXXXX")
  srv=$(start_hang_server "$marker")
  pid=${srv%% *}; port=${srv##* }
  if [ -z "$port" ]; then rm -rf "$pipe" "$home"; kill "$pid" 2>/dev/null; fail "AC7: hang-server never reported a port (test infra broken)"; return 1; fi

  url="http://127.0.0.1:$port/beat"
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<EOF
STATUS_PUSH_URL="$url"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
EOF

  # Simulate a real call site: source run-state.sh, call report_status_async exactly like
  # orchestrate.sh / supervisor.sh / the hook do, and time only the caller's own return.
  start=$(date +%s)
  ( HOME="$home" PIPE="$pipe" QUEUE="$pipe/queue" bash -c '
      . "'"$RS_AC7"'/run-state.sh"
      report_status_async event
      exit $?
    ' )
  rc=$?
  end=$(date +%s)
  dur=$((end - start))

  sleep 1  # give the backgrounded (or not-yet-implemented) reporter a moment
  local attempted=absent; [ -e "$marker" ] && attempted=present
  kill "$pid" 2>/dev/null
  rm -rf "$pipe" "$home"; rm -f "$marker"

  # AC7's literal wording: "the caller's own exit code and duration" — a call site using
  # report_status_async (set -uo pipefail, like supervisor.sh) must see exit 0 regardless of
  # what the reporter does downstream.
  assert_exit0 "$rc" "AC7: the caller (via report_status_async) must see exit 0 even while the endpoint is hanging" || return 1
  assert_lt "$dur" 2 "AC7/AC9: report_status_async must return to its caller almost immediately, never waiting on the curl timeout" || return 1
  assert_eq "$attempted" "present" "AC7: report_status_async must still have triggered the reporter (which then hits its own 10s bound) — a call that does nothing would pass the timing check vacuously" || return 1
}

run_test test_ac7_reporter_exits_within_10s_and_attempted_the_push
run_test test_ac7_caller_via_report_status_async_is_never_blocked
