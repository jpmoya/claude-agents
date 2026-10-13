# Issue #141 (Phase 3 of #134) — skills/orchestrate/rotate-logs.sh: size-triggered log rotation, the runs.jsonl
# 14-day window, and the one-off --archive-dead move.
#   AC14 text-log rotation + dead files     AC19 runs.jsonl rotation, reader parity, append race
# Expected values come from the ticket text or hand arithmetic in comments — never from the script.
# Every function/variable is prefixed rl_ / RL_ (all test files share one shell). Placeholder names only (public repo).
# Each case runs in an isolated HOME (new_home) with LOGDIR inside it; the script is NEVER run against the real HOME.
# Settings are put in the isolated HOME's config.local.sh (the documented override), not in the environment.
# Bash 3.2 compatible (see the portability test for the banned tools); big files and timestamps come from python3.

HERE_RL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_RL=$(cd "$HERE_RL/../../.." && pwd)
ROT_RL="$ROOT_RL/skills/orchestrate/rotate-logs.sh"

# rl_setup [min_bytes] [keep] [keep_days] — sets RL_HOME, RL_LOG, RL_RUNS and writes config.local.sh
rl_setup() {
  RL_HOME=$(new_home); RL_LOG="$RL_HOME/logs/pipeline"; RL_RUNS="$RL_HOME/.claude/pipeline/runs.jsonl"
  if [ -n "${1:-}" ]; then
    printf 'ROTATE_MIN_BYTES=%s\nROTATE_KEEP=%s\nRUNS_KEEP_DAYS=%s\n' "$1" "${2:-12}" "${3:-14}" > "$RL_HOME/.claude/pipeline/config.local.sh"
  fi
}
rl_teardown() { rm -rf "$RL_HOME"; }

# rl_run [args…] — sets RL_RC, RL_OUT (stdout), RL_ERR (stderr)
rl_run() {
  RL_OUT=$(HOME="$RL_HOME" LOGDIR="$RL_LOG" "$ROT_RL" "$@" 2>"$RL_HOME/stderr.txt"); RL_RC=$?
  RL_ERR=$(cat "$RL_HOME/stderr.txt")
}

# rl_bytes <path> <n> <char> — a file of n copies of char
rl_bytes() { python3 -c "import sys; open(sys.argv[1],'w').write(sys.argv[3]*int(sys.argv[2]))" "$1" "$2" "$3"; }
# rl_ts <secs-ago> — ISO-8601 UTC timestamp
rl_ts() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
rl_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c .; fi; }

RL_DAY=86400
# rl_runs_fixture <path> — lines, in this order:
#   1 old 41 dispatch (30d)  2 old 41 (30d)  3 NOT JSON  4 old 41 (30d)  5 JSON without ts
#   6 dispatch 42 (2h ago)   7 validate/structural/fail 42 (1h ago)
rl_runs_fixture() {
  local d30 d2h d1h; d30=$(rl_ts $((30 * RL_DAY))); d2h=$(rl_ts 7200); d1h=$(rl_ts 3600)
  {
    printf '{"ts":"%s","host":"h","event":"dispatch","repo":"project-a/app","issue":41,"marker":"OLD-A"}\n' "$d30"
    printf '{"ts":"%s","host":"h","event":"dispatch","repo":"project-a/app","issue":41,"marker":"OLD-B"}\n' "$d30"
    printf 'this line is not json at all\n'
    printf '{"ts":"%s","host":"h","event":"dispatch","repo":"project-a/app","issue":41,"marker":"OLD-C"}\n' "$d30"
    printf '{"host":"h","event":"note","issue":41,"marker":"NO-TS"}\n'
    printf '{"ts":"%s","host":"h","event":"dispatch","repo":"project-a/app","issue":42,"marker":"RECENT-DISPATCH"}\n' "$d2h"
    printf '{"ts":"%s","host":"h","event":"validate","repo":"project-a/app","issue":42,"stage":"structural","result":"fail","reason":"x"}\n' "$d1h"
  } > "$1"
}

# ------------------------------------------------------------------------------------------ settings

test_rl_config_sh_carries_the_four_settings() {
  local cfg="$ROOT_RL/skills/orchestrate/config.sh" r=0
  assert_eq "$(grep -c '^ROTATE_MIN_BYTES=1048576' "$cfg")" "1" "config.sh: ROTATE_MIN_BYTES=1048576" || r=1
  assert_eq "$(grep -c '^ROTATE_KEEP=12' "$cfg")" "1" "config.sh: ROTATE_KEEP=12" || r=1
  assert_eq "$(grep -c '^RUNS_KEEP_DAYS=14' "$cfg")" "1" "config.sh: RUNS_KEEP_DAYS=14" || r=1
  assert_eq "$(grep -c '^COST_CEILING_USD=40' "$cfg")" "1" "config.sh: COST_CEILING_USD=40" || r=1
  return $r
}

test_rl_default_threshold_is_1mb() {
  rl_setup   # no config.local.sh: defaults apply (ROTATE_MIN_BYTES=1048576)
  rl_bytes "$RL_LOG/supervisor.log" 1048577 S      # one byte over 1 MiB
  rl_bytes "$RL_LOG/report-status.log" 2000 R      # far under
  rl_run
  local r=0
  assert_exit0 "$RL_RC" "default threshold: exit" || r=1
  assert_file_absent "$RL_LOG/supervisor.log" "default threshold: 1,048,577 bytes rotates" || r=1
  assert_file_exists "$RL_LOG/supervisor.log.1" "default threshold: ...into .1" || r=1
  assert_file_exists "$RL_LOG/report-status.log" "default threshold: 2,000 bytes < 1 MiB stays" || r=1
  assert_file_absent "$RL_LOG/report-status.log.1" "default threshold: no rotation of the small log" || r=1
  rl_teardown; return $r
}

# ------------------------------------------------------------------------------------------ AC14 text logs

test_rl_ac14_supervisor_log_rotates_and_shifts_keeping_two() {
  rl_setup 1000 2
  rl_bytes "$RL_LOG/supervisor.log" 2000 S; cp "$RL_LOG/supervisor.log" "$RL_HOME/sup.orig"
  printf 'OLD1\n' > "$RL_LOG/supervisor.log.1"; printf 'OLD2\n' > "$RL_LOG/supervisor.log.2"
  rl_bytes "$RL_LOG/report-status.log" 500 R; cp "$RL_LOG/report-status.log" "$RL_HOME/rs.orig"
  rl_run
  local r=0
  assert_exit0 "$RL_RC" "AC14: exit 0" || r=1
  assert_file_absent "$RL_LOG/supervisor.log" "AC14: live supervisor.log is gone (next writer recreates it)" || r=1
  cmp -s "$RL_LOG/supervisor.log.1" "$RL_HOME/sup.orig" || { fail "AC14: .1 must hold the 2,000 original bytes"; r=1; }
  assert_eq "$(cat "$RL_LOG/supervisor.log.2" 2>/dev/null)" "OLD1" "AC14: old .1 is now .2" || r=1
  assert_file_absent "$RL_LOG/supervisor.log.3" "AC14: keep=2 — the old .2 is dropped, no .3" || r=1
  cmp -s "$RL_LOG/report-status.log" "$RL_HOME/rs.orig" || { fail "AC14: the 500-byte report-status.log is untouched"; r=1; }
  assert_file_absent "$RL_LOG/report-status.log.1" "AC14: no rotation of the small log" || r=1
  assert_eq "$(rl_lines "$RL_OUT")" "1" "AC14: one stdout line per file rotated" || r=1
  assert_contains "$RL_OUT" "supervisor.log" "AC14: the line names the file" || r=1
  rl_teardown; return $r
}

test_rl_ac14_second_run_changes_nothing() {
  rl_setup 1000 2
  rl_bytes "$RL_LOG/supervisor.log" 2000 S
  printf 'OLD1\n' > "$RL_LOG/supervisor.log.1"; printf 'OLD2\n' > "$RL_LOG/supervisor.log.2"
  rl_bytes "$RL_LOG/report-status.log" 500 R
  rl_run
  local before after r=0
  before=$(cd "$RL_LOG" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done)
  rl_run
  after=$(cd "$RL_LOG" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done)
  assert_exit0 "$RL_RC" "AC14 second run: exit 0" || r=1
  assert_eq "$after" "$before" "AC14: a second run changes nothing" || r=1
  assert_eq "$RL_OUT" "" "AC14 second run: prints nothing" || r=1
  # guard against a vacuous pass: the first run really rotated
  assert_eq "$(cat "$RL_LOG/supervisor.log.2" 2>/dev/null)" "OLD1" "AC14: first run rotated (old .1 became .2)" || r=1
  rl_teardown; return $r
}

# boundary: "larger than ROTATE_MIN_BYTES" — exactly 1000 bytes with a 1000 threshold stays; 1001 rotates
test_rl_ac14_boundary_exactly_at_threshold_stays_one_over_rotates() {
  rl_setup 1000 2
  rl_bytes "$RL_LOG/supervisor.log" 1000 S
  rl_bytes "$RL_LOG/report-status.log" 1001 R
  rl_run
  local r=0
  assert_file_exists "$RL_LOG/supervisor.log" "boundary: 1000 bytes is not larger than 1000 -> stays" || r=1
  assert_file_absent "$RL_LOG/supervisor.log.1" "boundary: no .1 at the threshold" || r=1
  assert_file_absent "$RL_LOG/report-status.log" "boundary: 1001 bytes rotates" || r=1
  assert_file_exists "$RL_LOG/report-status.log.1" "boundary: 1001 bytes lands in .1" || r=1
  rl_teardown; return $r
}

test_rl_ac14_missing_files_are_skipped_silently_exit_0() {
  rl_setup 1000 2   # no log files at all, no runs.jsonl
  rl_run
  local r=0
  assert_exit0 "$RL_RC" "missing files: exit 0" || r=1
  assert_eq "$RL_OUT" "" "missing files: no stdout" || r=1
  assert_eq "$RL_ERR" "" "missing files: no stderr" || r=1
  assert_eq "$(find "$RL_LOG" -type f | wc -l | tr -d ' ')" "0" "missing files: nothing created" || r=1
  rl_teardown; return $r
}

test_rl_unknown_argument_exits_non_zero() {
  rl_setup 1000 2
  rl_run --bogus
  assert_ne "$RL_RC" "0" "wrong arguments -> non-zero exit" || { rl_teardown; return 1; }
  rl_teardown
}

# ------------------------------------------------------------------------------------------ AC19 runs.jsonl

test_rl_ac19_old_lines_go_to_dot_1_recent_and_unparseable_stay_in_order() {
  rl_setup 100 12 14
  rl_runs_fixture "$RL_RUNS"; printf 'PRE-EXISTING\n' > "$RL_RUNS.1"
  rl_run
  local r=0 live old
  assert_exit0 "$RL_RC" "AC19: exit 0" || r=1
  old=$(cat "$RL_RUNS.1" 2>/dev/null)
  assert_eq "$(printf '%s\n' "$old" | grep -c 'OLD-')" "3" "AC19: the three 30-day-old lines are in runs.jsonl.1" || r=1
  assert_eq "$(printf '%s\n' "$old" | grep -o 'OLD-[A-C]' | tr '\n' ' ')" "OLD-A OLD-B OLD-C " "AC19: .1 keeps their original order" || r=1
  live=$(cat "$RL_RUNS")
  assert_eq "$(rl_lines "$live")" "4" "AC19: 4 lines stay (non-JSON, no-ts, 2 recent)" || r=1
  assert_not_contains "$live" "OLD-" "AC19: no old line left in the live file" || r=1
  assert_eq "$(printf '%s\n' "$live" | sed -n 1p)" "this line is not json at all" "AC19: live line 1 = the non-JSON line" || r=1
  assert_contains "$(printf '%s\n' "$live" | sed -n 2p)" "NO-TS" "AC19: live line 2 = the line without ts" || r=1
  assert_contains "$(printf '%s\n' "$live" | sed -n 3p)" "RECENT-DISPATCH" "AC19: live line 3 = the 2h-old dispatch" || r=1
  assert_contains "$(printf '%s\n' "$live" | sed -n 4p)" '"stage":"structural"' "AC19: live line 4 = the 1h-old structural fail" || r=1
  assert_eq "$(cat "$RL_RUNS.2" 2>/dev/null)" "PRE-EXISTING" "AC19: the earlier .1 shifts to .2 (same shift rule)" || r=1
  assert_eq "$(rl_lines "$RL_OUT")" "1" "AC19: one stdout line for runs.jsonl" || r=1
  assert_contains "$RL_OUT" "runs.jsonl" "AC19: the line names runs.jsonl" || r=1
  rl_teardown; return $r
}

test_rl_ac19_nothing_old_enough_means_nothing_happens() {
  rl_setup 100 12 14
  { printf '{"ts":"%s","event":"dispatch","issue":42,"marker":"R1"}\n' "$(rl_ts 7200)"
    printf '{"ts":"%s","event":"dispatch","issue":42,"marker":"R2"}\n' "$(rl_ts 3600)"; } > "$RL_RUNS"
  cp "$RL_RUNS" "$RL_HOME/runs.orig"
  rl_run
  local r=0
  cmp -s "$RL_RUNS" "$RL_HOME/runs.orig" || { fail "no old line: live file must be byte-identical"; r=1; }
  assert_file_absent "$RL_RUNS.1" "no old line: no .1 created" || r=1
  assert_eq "$RL_OUT" "" "no old line: no stdout" || r=1
  # control: add one 30-day-old line and the same file does rotate
  printf '{"ts":"%s","event":"dispatch","issue":41,"marker":"OLD-NOW"}\n' "$(rl_ts $((30 * RL_DAY)))" >> "$RL_RUNS"
  rl_run
  assert_contains "$(cat "$RL_RUNS.1" 2>/dev/null)" "OLD-NOW" "no old line (control): with one old line the file rotates" || r=1
  rl_teardown; return $r
}

test_rl_ac19_below_threshold_runs_jsonl_is_not_touched_even_with_old_lines() {
  rl_setup 1000000 12 14   # fixture is a few hundred bytes: under the threshold
  rl_runs_fixture "$RL_RUNS"; cp "$RL_RUNS" "$RL_HOME/runs.orig"
  rl_run
  local r=0
  cmp -s "$RL_RUNS" "$RL_HOME/runs.orig" || { fail "below threshold: live file byte-identical"; r=1; }
  assert_file_absent "$RL_RUNS.1" "below threshold: no .1" || r=1
  # control: lower the threshold and the same file rotates
  printf 'ROTATE_MIN_BYTES=100\nROTATE_KEEP=12\nRUNS_KEEP_DAYS=14\n' > "$RL_HOME/.claude/pipeline/config.local.sh"
  rl_run
  assert_eq "$(grep -c 'OLD-' "$RL_RUNS.1" 2>/dev/null)" "3" "below threshold (control): over the threshold the old lines rotate" || r=1
  rl_teardown; return $r
}

# ---- reader parity: (a) the supervisor's structural hold, (b) build-runs-json.py — same answer before and after
RL_IMPL='**[fullstack-developer] IMPLEMENTED**'
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "rl_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_RL/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f rl_real_run_test | sed '1s/rl_real_run_test/run_test/')"
fi

# rl_hold_after <rotate: yes|no> — a dead, non-terminal run of issue 42 launched 3 h ago over the runs.jsonl fixture;
# optionally rotated first. Ticks once and prints "<present|absent> <yes|no>": orch-42.held, runs.jsonl.1 exists.
rl_hold_after() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 10800 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$RL_IMPL"
  rl_runs_fixture "$SQ_HOME/.claude/pipeline/runs.jsonl"
  RL_ROTATED=no
  if [ "$1" = yes ]; then
    printf 'ROTATE_MIN_BYTES=100\nROTATE_KEEP=12\nRUNS_KEEP_DAYS=14\n' > "$SQ_HOME/.claude/pipeline/config.local.sh"
    HOME="$SQ_HOME" LOGDIR="$SQ_HOME/logs/pipeline" "$ROT_RL" >/dev/null 2>&1
    [ -e "$SQ_HOME/.claude/pipeline/runs.jsonl.1" ] && RL_ROTATED=yes
    rm -f "$SQ_HOME/.claude/pipeline/config.local.sh"
  fi
  sq_tick
  echo "$(sq_present "$SQ_PIPE/orch-42.held") $RL_ROTATED"   # runs in a $(...) subshell: report both through stdout
  sq_cleanup
}

test_rl_ac19_supervisor_structural_hold_same_before_and_after_rotation() {
  local before after r=0
  before=$(rl_hold_after no)
  after=$(rl_hold_after yes)
  assert_eq "$before" "present no" "AC19(a): held before rotation (fixture sanity)" || r=1
  assert_eq "$after" "present yes" "AC19(a): still held after rotation, and the file really was rotated" || r=1
  return $r
}

test_rl_ac19_build_runs_json_output_identical_before_and_after() {
  rl_setup 100 12 14
  local repo="$RL_HOME/repo-a" pipe="$RL_HOME/pipe" tsv before after r=0
  fixture_repo "$repo" "project-a/app"; mkdir -p "$pipe"
  rl_runs_fixture "$RL_RUNS"
  tsv=$(printf '42\t%s\trunning\t12345\t%s\t%s\t0\tdev' "$repo" "$(rl_ts 3600)" "$(date +%s)")
  before=$(printf '%s\n' "$tsv" | python3 "$ROOT_RL/skills/orchestrate/build-runs-json.py" "project-a/app:app" "$RL_RUNS" "$pipe" 2>&1)
  rl_run
  after=$(printf '%s\n' "$tsv" | python3 "$ROOT_RL/skills/orchestrate/build-runs-json.py" "project-a/app:app" "$RL_RUNS" "$pipe" 2>&1)
  assert_contains "$before" '"issue": 42' "AC19(b): the running issue 42 is in the output (fixture sanity)" || r=1
  assert_eq "$after" "$before" "AC19(b): build-runs-json.py output identical after rotation" || r=1
  assert_file_exists "$RL_RUNS.1" "AC19(b): the file really was rotated" || r=1
  rl_teardown; return $r
}

# ---- append race: ROTATE_TEST_HOOK names a script run between reading and replacing runs.jsonl
test_rl_ac19_line_appended_mid_rotation_survives() {
  rl_setup 100 12 14
  rl_runs_fixture "$RL_RUNS"
  cat > "$RL_HOME/hook.sh" <<EOS
#!/bin/bash
# append once only (the rotation may retry and run the hook again)
[ -e "$RL_HOME/hook.done" ] && exit 0
: > "$RL_HOME/hook.done"
printf '{"ts":"%s","event":"dispatch","issue":42,"marker":"APPENDED-MID-ROTATION"}\n' "$(rl_ts 5)" >> "$RL_RUNS"
EOS
  chmod +x "$RL_HOME/hook.sh"
  RL_OUT=$(HOME="$RL_HOME" LOGDIR="$RL_LOG" ROTATE_TEST_HOOK="$RL_HOME/hook.sh" "$ROT_RL" 2>&1); RL_RC=$?
  local r=0
  assert_exit0 "$RL_RC" "append race: exit 0" || r=1
  assert_file_exists "$RL_HOME/hook.done" "append race: the hook was run" || r=1
  assert_contains "$(cat "$RL_RUNS")" "APPENDED-MID-ROTATION" "append race: the appended line is in runs.jsonl" || r=1
  assert_not_contains "$(cat "$RL_RUNS.1" 2>/dev/null)" "APPENDED-MID-ROTATION" "append race: the appended line is not archived" || r=1
  assert_eq "$(grep -c 'OLD-' "$RL_RUNS.1" 2>/dev/null)" "3" "append race: after the retry the old lines are still rotated" || r=1
  rl_teardown; return $r
}

# a writer that appends every time defeats all retries: skip with a message, lose nothing
test_rl_ac19_persistent_appender_skips_with_message_and_loses_nothing() {
  rl_setup 100 12 14
  rl_runs_fixture "$RL_RUNS"; cp "$RL_RUNS" "$RL_HOME/runs.orig"
  cat > "$RL_HOME/hook.sh" <<EOS
#!/bin/bash
printf '{"ts":"%s","event":"dispatch","issue":42,"marker":"APPENDED"}\n' "$(rl_ts 5)" >> "$RL_RUNS"
EOS
  chmod +x "$RL_HOME/hook.sh"
  RL_OUT=$(HOME="$RL_HOME" LOGDIR="$RL_LOG" ROTATE_TEST_HOOK="$RL_HOME/hook.sh" "$ROT_RL" 2>&1); RL_RC=$?
  local r=0 n
  assert_exit0 "$RL_RC" "persistent appender: still exit 0" || r=1
  assert_contains "$RL_OUT" "runs.jsonl" "persistent appender: a message about runs.jsonl" || r=1
  n=$(grep -c 'OLD-' "$RL_RUNS" 2>/dev/null)
  assert_eq "$n" "3" "persistent appender: skipped — the old lines are still in the live file (nothing lost)" || r=1
  assert_ne "$(grep -c 'APPENDED' "$RL_RUNS")" "0" "persistent appender: appended lines kept" || r=1
  assert_file_absent "$RL_RUNS.1" "persistent appender: no .1 written" || r=1
  rl_teardown; return $r
}

# ------------------------------------------------------------------------------------------ AC14 dead files

RL_DEAD="logs/pipeline/handoffs.jsonl logs/pipeline/dispatch.log logs/pipeline/runs .claude/pipeline/dispatch.sh .claude/pipeline/run.sh .claude/pipeline/scan-backlog.sh .claude/pipeline/config.sh"
RL_LIVE=".claude/pipeline/config.local.sh .claude/pipeline/config.local.sh.bak-20260930 .claude/pipeline/runs.jsonl logs/pipeline/supervisor.log logs/pipeline/events.jsonl"

# rl_dead_fixture — all seven dead paths (runs/ holds two files) + five live neighbours; originals copied to $RL_HOME.orig
rl_dead_fixture() {
  rl_setup
  local p
  mkdir -p "$RL_LOG/runs"
  printf 'handoffs\n' > "$RL_HOME/logs/pipeline/handoffs.jsonl"
  printf 'dispatch log\n' > "$RL_HOME/logs/pipeline/dispatch.log"
  printf 'run one\n' > "$RL_LOG/runs/one.log"; printf 'run two\n' > "$RL_LOG/runs/two.log"
  printf 'dispatch sh\n' > "$RL_HOME/.claude/pipeline/dispatch.sh"
  printf 'run sh\n' > "$RL_HOME/.claude/pipeline/run.sh"
  printf 'scan sh\n' > "$RL_HOME/.claude/pipeline/scan-backlog.sh"
  printf 'old config sh\n' > "$RL_HOME/.claude/pipeline/config.sh"
  printf 'SECRET=live\n' > "$RL_HOME/.claude/pipeline/config.local.sh"
  printf 'SECRET=bak\n' > "$RL_HOME/.claude/pipeline/config.local.sh.bak-20260930"
  printf '{"ts":"2026-10-01T00:00:00Z"}\n' > "$RL_HOME/.claude/pipeline/runs.jsonl"
  printf 'sup\n' > "$RL_HOME/logs/pipeline/supervisor.log"
  printf '{"event":"stage_end"}\n' > "$RL_HOME/logs/pipeline/events.jsonl"
  RL_ORIG="$RL_HOME.orig"; rm -rf "$RL_ORIG"; mkdir -p "$RL_ORIG"
  for p in $RL_DEAD $RL_LIVE; do mkdir -p "$RL_ORIG/$(dirname "$p")"; cp -R "$RL_HOME/$p" "$RL_ORIG/$p"; done
}
rl_dead_teardown() { rm -rf "$RL_HOME" "$RL_ORIG"; }

test_rl_ac14_archive_dead_moves_exactly_the_seven_and_keeps_live_files() {
  rl_dead_fixture
  rl_run --archive-dead
  local r=0 p dest
  assert_exit0 "$RL_RC" "archive-dead: exit 0" || r=1
  dest=$(ls -d "$RL_LOG"/archive/dead-files-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | head -1)
  [ -n "$dest" ] || { fail "archive-dead: \$LOGDIR/archive/dead-files-<YYYYMMDD>/ not created"; rl_dead_teardown; return 1; }
  for p in $RL_DEAD; do
    [ ! -e "$RL_HOME/$p" ] || { fail "archive-dead: $p still at its original path"; r=1; }
    [ -e "$dest/$p" ] || { fail "archive-dead: $p missing from the archive at $dest/$p"; r=1; }
  done
  cmp -s "$dest/logs/pipeline/handoffs.jsonl" "$RL_ORIG/logs/pipeline/handoffs.jsonl" || { fail "archive-dead: handoffs.jsonl content differs"; r=1; }
  cmp -s "$dest/logs/pipeline/dispatch.log" "$RL_ORIG/logs/pipeline/dispatch.log" || { fail "archive-dead: dispatch.log content differs"; r=1; }
  cmp -s "$dest/logs/pipeline/runs/one.log" "$RL_ORIG/logs/pipeline/runs/one.log" || { fail "archive-dead: runs/one.log content differs"; r=1; }
  cmp -s "$dest/logs/pipeline/runs/two.log" "$RL_ORIG/logs/pipeline/runs/two.log" || { fail "archive-dead: runs/two.log content differs"; r=1; }
  cmp -s "$dest/.claude/pipeline/dispatch.sh" "$RL_ORIG/.claude/pipeline/dispatch.sh" || { fail "archive-dead: dispatch.sh content differs"; r=1; }
  cmp -s "$dest/.claude/pipeline/run.sh" "$RL_ORIG/.claude/pipeline/run.sh" || { fail "archive-dead: run.sh content differs"; r=1; }
  cmp -s "$dest/.claude/pipeline/scan-backlog.sh" "$RL_ORIG/.claude/pipeline/scan-backlog.sh" || { fail "archive-dead: scan-backlog.sh content differs"; r=1; }
  cmp -s "$dest/.claude/pipeline/config.sh" "$RL_ORIG/.claude/pipeline/config.sh" || { fail "archive-dead: config.sh content differs"; r=1; }
  for p in $RL_LIVE; do
    cmp -s "$RL_HOME/$p" "$RL_ORIG/$p" || { fail "archive-dead: live neighbour $p must be byte-identical and in place"; r=1; }
  done
  assert_eq "$(rl_lines "$RL_OUT")" "7" "archive-dead: one stdout line per path moved" || r=1
  rl_dead_teardown; return $r
}

test_rl_ac14_archive_dead_with_none_present_exits_0_and_creates_nothing() {
  rl_setup
  printf 'SECRET=live\n' > "$RL_HOME/.claude/pipeline/config.local.sh"
  local before after r=0
  before=$(cd "$RL_HOME" && find . | sort)
  rl_run --archive-dead
  after=$(cd "$RL_HOME" && find . | sort | grep -v '^./stderr.txt$')
  before=$(printf '%s\n' "$before" | grep -v '^./stderr.txt$')
  assert_exit0 "$RL_RC" "none present: exit 0" || r=1
  assert_eq "$after" "$before" "none present: nothing created (no archive dir either)" || r=1
  # control: with one dead path present the same call archives it
  printf 'x\n' > "$RL_HOME/.claude/pipeline/dispatch.sh"
  rl_run --archive-dead
  assert_file_absent "$RL_HOME/.claude/pipeline/dispatch.sh" "none present (control): a present dead path is moved" || r=1
  rl_teardown; return $r
}

test_rl_ac14_archive_dead_second_run_same_day_moves_nothing_and_overwrites_nothing() {
  rl_dead_fixture
  rl_run --archive-dead
  local dest r=0 snap1 snap2
  dest=$(ls -d "$RL_LOG"/archive/dead-files-[0-9]* 2>/dev/null | head -1)
  [ -n "$dest" ] || { fail "second run: first run produced no archive"; rl_dead_teardown; return 1; }
  # a plain second run: nothing left to move
  snap1=$(cd "$RL_HOME" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done | grep -v 'stderr.txt')
  rl_run --archive-dead
  snap2=$(cd "$RL_HOME" && find . -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done | grep -v 'stderr.txt')
  assert_exit0 "$RL_RC" "second run: exit 0" || r=1
  assert_eq "$snap2" "$snap1" "second run: moves nothing" || r=1
  # the writer recreates a dead path the same day: the archive copy must not be overwritten, the new file stays put
  printf 'NEW CONTENT\n' > "$RL_HOME/logs/pipeline/dispatch.log"
  rl_run --archive-dead
  assert_exit0 "$RL_RC" "recreated path: exit 0" || r=1
  assert_eq "$(cat "$dest/logs/pipeline/dispatch.log")" "dispatch log" "recreated path: the archived copy is not overwritten" || r=1
  assert_eq "$(cat "$RL_HOME/logs/pipeline/dispatch.log")" "NEW CONTENT" "recreated path: the new file is left where it is (deletes nothing)" || r=1
  assert_ne "$RL_OUT$RL_ERR" "" "recreated path: skipped with a message" || r=1
  rl_dead_teardown; return $r
}

test_rl_ac14_plain_run_never_touches_dead_files_and_archive_dead_never_rotates() {
  rl_dead_fixture
  printf 'ROTATE_MIN_BYTES=10\nROTATE_KEEP=2\nRUNS_KEEP_DAYS=14\n' >> "$RL_HOME/.claude/pipeline/config.local.sh"
  cp "$RL_HOME/.claude/pipeline/config.local.sh" "$RL_ORIG/config.local.with-settings"
  rl_run
  local r=0 p
  for p in $RL_DEAD; do
    [ -e "$RL_HOME/$p" ] || { fail "plain run: dead path $p must stay (only --archive-dead moves them)"; r=1; }
  done
  assert_file_absent "$RL_LOG/archive" "plain run: no archive dir" || r=1
  # now the reverse: --archive-dead does nothing else (supervisor.log is over the 10-byte threshold but must not rotate)
  rl_run --archive-dead
  assert_file_exists "$RL_LOG/supervisor.log" "archive-dead: does not rotate logs" || r=1
  assert_file_absent "$RL_LOG/supervisor.log.1" "archive-dead: no .1 created" || r=1
  cmp -s "$RL_HOME/.claude/pipeline/config.local.sh" "$RL_ORIG/config.local.with-settings" || { fail "config.local.sh must never move or change"; r=1; }
  for p in $RL_DEAD; do
    [ ! -e "$RL_HOME/$p" ] || { fail "archive-dead (control): $p should have been moved by --archive-dead"; r=1; }
  done
  rl_dead_teardown; return $r
}

for t in test_rl_config_sh_carries_the_four_settings \
  test_rl_default_threshold_is_1mb \
  test_rl_ac14_supervisor_log_rotates_and_shifts_keeping_two \
  test_rl_ac14_second_run_changes_nothing \
  test_rl_ac14_boundary_exactly_at_threshold_stays_one_over_rotates \
  test_rl_ac14_missing_files_are_skipped_silently_exit_0 \
  test_rl_unknown_argument_exits_non_zero \
  test_rl_ac19_old_lines_go_to_dot_1_recent_and_unparseable_stay_in_order \
  test_rl_ac19_nothing_old_enough_means_nothing_happens \
  test_rl_ac19_below_threshold_runs_jsonl_is_not_touched_even_with_old_lines \
  test_rl_ac19_supervisor_structural_hold_same_before_and_after_rotation \
  test_rl_ac19_build_runs_json_output_identical_before_and_after \
  test_rl_ac19_line_appended_mid_rotation_survives \
  test_rl_ac19_persistent_appender_skips_with_message_and_loses_nothing \
  test_rl_ac14_archive_dead_moves_exactly_the_seven_and_keeps_live_files \
  test_rl_ac14_archive_dead_with_none_present_exits_0_and_creates_nothing \
  test_rl_ac14_archive_dead_second_run_same_day_moves_nothing_and_overwrites_nothing \
  test_rl_ac14_plain_run_never_touches_dead_files_and_archive_dead_never_rotates; do
  run_test "$t"
done
