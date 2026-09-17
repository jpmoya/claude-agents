# AC10 — two reporter invocations started less than 100 ms apart both exit 0, and the on-disk
# change-detection cache is never left partially written or corrupted — lock uses an atomic
# `mkdir` with a stale-lock timeout, not `flock`/`setsid` (unavailable in macOS bash 3.2).

HERE_AC10=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC10="$HERE_AC10/.."

test_ac10_two_near_simultaneous_invocations_both_exit_0_cache_intact() {
  local pipe home rc1 rc2 cache_state
  pipe=$(new_pipe); home=$(new_home)
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
EOF

  # Launched back to back (well under 100ms apart by construction — no artificial delay between
  # the two `&` backgrounds).
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$RS_AC10/report-status.sh" event; echo $? > "$pipe/rc1" ) &
  local job1=$!
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$RS_AC10/report-status.sh" event; echo $? > "$pipe/rc2" ) &
  local job2=$!
  wait "$job1" 2>/dev/null
  wait "$job2" 2>/dev/null

  rc1=$(cat "$pipe/rc1" 2>/dev/null || echo "missing")
  rc2=$(cat "$pipe/rc2" 2>/dev/null || echo "missing")

  cache_state="absent"
  if [ -e "$pipe/status-push.state" ]; then
    if python3 -c "import json; json.load(open('$pipe/status-push.state'))" 2>/dev/null; then
      cache_state="valid-json"
    else
      cache_state="corrupt"
    fi
  fi
  local lockdir_left=absent; [ -e "$pipe/status-push.lockdir" ] && lockdir_left=present

  rm -rf "$pipe" "$home"

  assert_exit0 "$rc1" "AC10: first near-simultaneous invocation exits 0" || return 1
  assert_exit0 "$rc2" "AC10: second near-simultaneous invocation exits 0" || return 1
  assert_ne "$cache_state" "corrupt" "AC10: cache file is never left partially written / corrupt" || return 1
  assert_eq "$lockdir_left" "absent" "AC10: the lockdir must not survive past both invocations (trap ... EXIT cleans it up)" || return 1
}

test_ac10_stale_lock_reclaimed_after_60s() {
  local pipe home rc
  pipe=$(new_pipe); home=$(new_home)
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
EOF
  # Simulate a crashed prior run that left the lockdir behind, older than the 60s stale window.
  mkdir -p "$pipe/status-push.lockdir"
  local old_ts
  old_ts=$(python3 -c "import time; print(int(time.time()) - 120)")
  python3 -c "import os; os.utime('$pipe/status-push.lockdir', ($old_ts, $old_ts))"

  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$RS_AC10/report-status.sh" event )
  rc=$?
  rm -rf "$pipe" "$home"

  assert_exit0 "$rc" "AC10: a stale (>60s) lockdir is reclaimed, not treated as a permanent lock-out" || return 1
}

test_ac10_lock_is_mkdir_based_not_flock_or_setsid() {
  local hits mkdir_lock
  hits=$(grep -nE '\b(flock|setsid)\b' "$RS_AC10/report-status.sh" "$RS_AC10/run-state.sh" 2>/dev/null || true)
  assert_eq "$hits" "" "AC10: the reporter's lock must be mkdir-based, not flock/setsid (unavailable on macOS bash 3.2)" || return 1
  # Positive half: the mandated mechanism must actually be present, not just "nothing forbidden
  # found" (true of an empty file too) — mkdir targeting the documented lockdir name. Comment
  # lines are excluded: the stub's own design-contract comment mentions "mkdir ...lockdir" in
  # prose, which must not satisfy a check for real code.
  mkdir_lock=$(grep -vE '^[[:space:]]*#' "$RS_AC10/report-status.sh" | grep -nE 'mkdir[^|&;]*status-push\.lockdir' || true)
  assert_ne "$mkdir_lock" "" "AC10: report-status.sh must acquire the lock via mkdir \$PIPE/status-push.lockdir" || return 1
}

run_test test_ac10_two_near_simultaneous_invocations_both_exit_0_cache_intact
run_test test_ac10_stale_lock_reclaimed_after_60s
run_test test_ac10_lock_is_mkdir_based_not_flock_or_setsid
