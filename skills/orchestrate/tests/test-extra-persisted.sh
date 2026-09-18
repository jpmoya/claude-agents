# Regression for claude-agents#3 — orchestrate.sh must persist the extra instructions to
# $PIPE/orch-<issue>.extra on BOTH the immediate-launch and the queued path. supervisor.sh treats
# that file as the source of truth and rebuilds the queue JSON from it, so a queued launch that
# skipped the write lost its extra on the next supervisor tick.
#
# Every case runs in an isolated PIPE + HOME (config.sh prepends $HOME/.local/bin to PATH, so the
# fake gh/claude installed there win over any real binary). Placeholder repo names only.

HERE_EXT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_EXT="$HERE_EXT/../orchestrate.sh"
SUP_EXT="$HERE_EXT/../supervisor.sh"

# ext_env <full|open> -> sets EXT_PIPE, EXT_HOME, EXT_REPO. "full" fills every MAX_CONCURRENT slot
# (3 live placeholders) so has_capacity is false; "open" leaves capacity and zeroes the memory
# floor so has_capacity is true regardless of the host's free RAM.
ext_env() {
  local mode=$1 i
  EXT_PIPE=$(new_pipe); EXT_HOME=$(new_home)
  EXT_REPO="$EXT_PIPE/repo-a"
  fixture_repo "$EXT_REPO" "project-a/repo-a"
  mk_fake_gh "$EXT_HOME/.local/bin"
  echo "project-a/repo-a" > "$EXT_HOME/.local/bin/gh-name-with-owner"
  if [ "$mode" = "full" ]; then
    for i in 1 2 3; do mk_running "$EXT_PIPE" "$i" "$EXT_REPO"; done
  else
    echo 'MEM_FLOOR_MB=0' > "$EXT_HOME/.claude/pipeline/config.local.sh"
    # stub claude: no real process; exits at once
    printf '#!/bin/bash\nexit 0\n' > "$EXT_HOME/.local/bin/claude"
    chmod +x "$EXT_HOME/.local/bin/claude"
  fi
}

ext_cleanup() { cleanup_running; rm -rf "$EXT_PIPE" "$EXT_HOME"; }

# ext_launch <issue> [extra...] -> runs orchestrate.sh in the isolated env; stdout+stderr on stdout, rc returned
ext_launch() {
  local issue=$1; shift
  HOME="$EXT_HOME" PATH="$EXT_HOME/.local/bin:/usr/bin:/bin" PIPE="$EXT_PIPE" QUEUE="$EXT_PIPE/queue" \
    "$ORCH_EXT" "$EXT_REPO" "$issue" "$@" 2>&1
}

# file_equals <file> <expected-string> -> 0 iff the file's bytes are exactly the string (no newline added/stripped)
file_equals() {
  local expected_file
  expected_file=$(mktemp "${TMPDIR:-/tmp}/orch-test-expected.XXXXXX")
  printf '%s' "$2" > "$expected_file"
  cmp -s "$1" "$expected_file"
  local rc=$?
  rm -f "$expected_file"
  return $rc
}

test_extra_queued_path_persists_extra() {
  ext_env full
  local out rc
  out=$(ext_launch 42 "resume from stage X"); rc=$?
  local same=1; file_equals "$EXT_PIPE/orch-42.extra" "resume from stage X" && same=0
  local queued=absent; [ -f "$EXT_PIPE/queue/orch-42.json" ] && queued=present
  ext_cleanup
  assert_exit0 "$rc" "extra/AC1: queued launch exits 0" || return 1
  assert_contains "$out" "queued #42" "extra/AC1: launch was queued" || return 1
  assert_eq "$queued" "present" "extra/AC1: queue entry written" || return 1
  assert_eq "$same" "0" "extra/AC1: .extra holds exactly the extra, byte-for-byte" || return 1
}

test_extra_queued_path_roundtrips_multiline_apostrophe() {
  ext_env full
  local extra out rc
  extra=$'previous attempt failed because it\'s flaky\n\nresume from stage X; keep "quotes" and $HOME literal'
  out=$(ext_launch 42 "$extra"); rc=$?
  local same=1; file_equals "$EXT_PIPE/orch-42.extra" "$extra" && same=0
  ext_cleanup
  assert_exit0 "$rc" "extra/AC1: multi-line queued launch exits 0" || return 1
  assert_contains "$out" "queued #42" "extra/AC1: multi-line launch was queued" || return 1
  assert_eq "$same" "0" "extra/AC1: multi-line extra with apostrophe round-trips unchanged" || return 1
}

test_extra_queued_path_overwrites_stale_extra() {
  ext_env full
  printf '%s' "old" > "$EXT_PIPE/orch-42.extra"
  local out rc
  out=$(ext_launch 42 "new"); rc=$?
  local same=1; file_equals "$EXT_PIPE/orch-42.extra" "new" && same=0
  ext_cleanup
  assert_exit0 "$rc" "extra/AC2: queued launch exits 0" || return 1
  assert_eq "$same" "0" "extra/AC2: stale 'old' replaced by 'new'" || return 1
}

test_extra_queued_path_no_extra_empties_stale_extra() {
  ext_env full
  printf '%s' "old" > "$EXT_PIPE/orch-42.extra"
  local out rc
  out=$(ext_launch 42); rc=$?
  local exists=no size=-1
  [ -f "$EXT_PIPE/orch-42.extra" ] && { exists=yes; size=$(wc -c < "$EXT_PIPE/orch-42.extra" | tr -d ' '); }
  ext_cleanup
  assert_exit0 "$rc" "extra/AC2: queued launch without extra exits 0" || return 1
  assert_eq "$exists" "yes" "extra/AC2: .extra exists after a no-extra queued launch" || return 1
  assert_eq "$size" "0" "extra/AC2: .extra is 0 bytes, not the stale 'old'" || return 1
}

test_extra_launch_path_still_persists_extra() {
  ext_env open
  local out rc
  out=$(ext_launch 42 "abc"); rc=$?
  local same=1; file_equals "$EXT_PIPE/orch-42.extra" "abc" && same=0
  local queued=absent; [ -f "$EXT_PIPE/queue/orch-42.json" ] && queued=present
  ext_cleanup
  assert_exit0 "$rc" "extra/AC3: launch exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "extra/AC3: took the launch path" || return 1
  assert_eq "$same" "0" "extra/AC3: launch path still leaves .extra = abc" || return 1
  assert_eq "$queued" "absent" "extra/AC3: no queue JSON on the launch path" || return 1
}

test_extra_supervisor_reenqueue_keeps_extra() {
  ext_env full
  local extra out rc
  extra=$'resume from stage X\nit\'s the second paragraph'
  out=$(ext_launch 42 "$extra"); rc=$?
  assert_exit0 "$rc" "extra/AC4: queued launch exits 0" || { ext_cleanup; return 1; }
  # A queued-launched #42 that the supervisor sees as a dead, non-terminal run to re-enqueue
  # (stale .exit + .repo + dead .pid). Drop the queue entry orchestrate.sh wrote: the supervisor
  # only rebuilds it (from .extra) when none exists.
  mk_dead_pid "$EXT_PIPE" 42
  echo "$EXT_REPO" > "$EXT_PIPE/orch-42.repo"
  echo 1 > "$EXT_PIPE/orch-42.exit"
  rm -f "$EXT_PIPE/queue/orch-42.json"
  HOME="$EXT_HOME" PATH="$EXT_HOME/.local/bin:/usr/bin:/bin" PIPE="$EXT_PIPE" QUEUE="$EXT_PIPE/queue" LOGDIR="$EXT_HOME/logs/pipeline" \
    "$SUP_EXT" >/dev/null 2>&1
  local reason queued_extra
  reason=$(python3 -c "import json; print(json.load(open('$EXT_PIPE/queue/orch-42.json')).get('reason','MISSING'))" 2>/dev/null || echo "NO-QUEUE-ENTRY")
  queued_extra=$(python3 -c "import json; print(json.load(open('$EXT_PIPE/queue/orch-42.json')).get('extra','MISSING'), end='')" 2>/dev/null || echo "NO-QUEUE-ENTRY")
  ext_cleanup
  assert_eq "$reason" "auto-restart" "extra/AC4: supervisor tick re-enqueued #42" || return 1
  assert_eq "$queued_extra" "$extra" "extra/AC4: re-enqueued queue JSON keeps the original extra" || return 1
}

run_test test_extra_queued_path_persists_extra
run_test test_extra_queued_path_roundtrips_multiline_apostrophe
run_test test_extra_queued_path_overwrites_stale_extra
run_test test_extra_queued_path_no_extra_empties_stale_extra
run_test test_extra_launch_path_still_persists_extra
run_test test_extra_supervisor_reenqueue_keeps_extra
