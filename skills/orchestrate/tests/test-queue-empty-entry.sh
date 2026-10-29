# Tests for claude-agents#539 — a 0-byte/unparseable queue entry must never be launched as a blank ticket,
# and queue writers must never leave a 0-byte/partial orch-*.json.
#   AC1  0-byte orch-*.json in queue -> purged, logged [drain-skip], no do_launch with blank issue
#   AC2  failed queue write          -> no orch-*.json and no *.tmp left, caller sees failure
#   AC3  successful queue write      -> valid JSON entry, no *.tmp left

HERE_QE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_DIR_QE="$HERE_QE/.."

test_qe_1_zero_byte_entry_purged_not_launched() {
  local pipe home gh log
  pipe=$(new_pipe); home=$(new_home); gh="$home/.local/bin"
  fixture_repo "$pipe/repo-a" "project-a/repo-a"
  mk_fake_gh "$gh"
  echo "project-a/repo-a" > "$gh/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$gh/claude"; chmod +x "$gh/claude"
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$gh/pmset"; chmod +x "$gh/pmset"
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\n' > "$home/.claude/pipeline/config.local.sh"
  mkdir -p "$pipe/queue"; : > "$pipe/queue/orch-1.json"
  HOME="$home" PATH="$gh:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$pipe" QUEUE="$pipe/queue" LOGDIR="$home/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$ORCH_DIR_QE/supervisor.sh" >/dev/null 2>&1
  log=$(cat "$home/logs/pipeline/supervisor.log" 2>/dev/null)
  assert_file_absent "$pipe/queue/orch-1.json" "0-byte entry purged"
  assert_contains "$log" "[drain-skip] orch-1.json — blank issue/repo" "purge logged"
  assert_not_contains "$log" "[launch] # " "no blank-ticket launch"
  cleanup_running; rm -rf "$pipe" "$home"
}

qe_load_writer() { eval "$(sed -n '/^queue_write() {/,/^}/p' "$ORCH_DIR_QE/supervisor.sh")"; }

test_qe_2_failed_write_leaves_nothing() {
  local d stub rc
  d=$(mktemp -d); stub=$(mktemp -d)
  printf '#!/bin/bash\nexit 1\n' > "$stub/python3"; chmod +x "$stub/python3"
  qe_load_writer
  ( PATH="$stub:$PATH"; queue_write "$d/orch-1.json" 1 project-a/repo-a "" 0 ); rc=$?
  assert_eq "$rc" "1" "failed write returns 1"
  assert_eq "$(ls -A "$d" | wc -l | tr -d ' ')" "0" "no orch-*.json / *.tmp left"
  rm -rf "$d" "$stub"
}

test_qe_3_good_write_valid_json() {
  local d
  d=$(mktemp -d)
  qe_load_writer
  queue_write "$d/orch-1.json" 7 project-a/repo-a "" 0
  assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['issue'])" "$d/orch-1.json")" "7" "entry parses"
  assert_eq "$(ls -A "$d")" "orch-1.json" "no .tmp left"
  rm -rf "$d"
}

run_test test_qe_1_zero_byte_entry_purged_not_launched
run_test test_qe_2_failed_write_leaves_nothing
run_test test_qe_3_good_write_valid_json
