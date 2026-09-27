# Issue #94 — launch writes the real newest GitHub routing marker to orch-<n>.marker instead of
# deleting it, from the SAME `gh issue view <n> --json title,comments` call that fetches the title.
#
#   AC3a  orchestrate.sh launched AND queued paths: orch-<n>.marker = marker name (no "**[agent] "
#         prefix, no trailing "**"), e.g. "**[test-reviewer] TESTS APPROVED**" -> "TESTS APPROVED"
#   AC3b  no extra API call: exactly one `issue view <n>` call asks for comments, and it is the title call
#   AC3c  failed fetch / no routing marker (NOTE only) -> the file is removed, never stale; launch still succeeds
#   AC3d  supervisor.sh do_launch (title file absent) writes the marker the same way; failed fetch removes a stale one
#   AC3e  the marker parsing (marker_last_jq + the sed cleanup) lives once, in pipeline-lib.sh
#
# Placeholder repo names only (public repo). Expected values hand-written from the ticket. Bash 3.2 portable.
# Fake gh: tests/lib/fixture.sh mk_fake_gh (extended additively so `--json title,comments` returns the
# per-issue gh-issue-latest-marker[-n] comment).

HERE_LM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_LM="$HERE_LM/.."
ORCH_LM="$RS_LM/orchestrate.sh"
SUP_LM="$RS_LM/supervisor.sh"

lm_env() {  # lm_env <full|open> -> LM_PIPE, LM_HOME, LM_REPO, LM_BIN
  local mode=$1 i
  LM_PIPE=$(new_pipe); LM_HOME=$(new_home)
  LM_REPO="$LM_PIPE/repo-a"
  fixture_repo "$LM_REPO" "project-a/repo-a"
  LM_BIN="$LM_HOME/.local/bin"
  mk_fake_gh "$LM_BIN"
  echo "project-a/repo-a" > "$LM_BIN/gh-name-with-owner"
  if [ "$mode" = "full" ]; then
    for i in 1 2 3; do mk_running "$LM_PIPE" "$i" "$LM_REPO"; done
  else
    echo 'MEM_FLOOR_MB=0' > "$LM_HOME/.claude/pipeline/config.local.sh"
    printf '#!/bin/bash\nexec sleep 30\n' > "$LM_BIN/claude"
    chmod +x "$LM_BIN/claude"
  fi
}

lm_cleanup() {
  local f pid
  for f in "$LM_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running; rm -rf "$LM_PIPE" "$LM_HOME"
}

lm_launch() {  # lm_launch <issue>
  HOME="$LM_HOME" PATH="$LM_BIN:/usr/bin:/bin" PIPE="$LM_PIPE" QUEUE="$LM_PIPE/queue" \
    "$ORCH_LM" "$LM_REPO" "$1" 2>&1
}

lm_tick() {  # one supervisor tick (drains the queue -> do_launch)
  HOME="$LM_HOME" PATH="$LM_BIN:/usr/bin:/bin" PIPE="$LM_PIPE" QUEUE="$LM_PIPE/queue" LOGDIR="$LM_HOME/logs/pipeline" \
    "$SUP_LM" >/dev/null 2>&1
}

lm_marker_file() {  # content of orch-<n>.marker or ABSENT
  if [ -f "$LM_PIPE/orch-$1.marker" ]; then printf '%s' "$(head -n1 "$LM_PIPE/orch-$1.marker")"; else printf 'ABSENT'; fi
}

test_lm_launched_path_writes_marker_name() {
  lm_env open
  printf '%s\n' '**[test-reviewer] TESTS APPROVED**' > "$LM_BIN/gh-issue-latest-marker"
  local out rc m
  out=$(lm_launch 42); rc=$?
  m=$(lm_marker_file 42)
  lm_cleanup
  assert_exit0 "$rc" "#94: launch exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "#94: took the launch path" || return 1
  assert_eq "$m" "TESTS APPROVED" "#94: orch-42.marker = newest routing marker name (launched path)" || return 1
}

test_lm_queued_path_writes_marker_name() {
  lm_env full
  printf '%s\n' '**[product-manager] READY FOR ENGINEERING**' > "$LM_BIN/gh-issue-latest-marker"
  local out rc m queued=absent
  out=$(lm_launch 42); rc=$?
  m=$(lm_marker_file 42)
  [ -f "$LM_PIPE/queue/orch-42.json" ] && queued=present
  lm_cleanup
  assert_exit0 "$rc" "#94: queued launch exits 0" || return 1
  assert_eq "$queued" "present" "#94: scenario sanity — the launch was queued" || return 1
  assert_eq "$m" "READY FOR ENGINEERING" "#94: orch-42.marker written on the queued path too" || return 1
}

test_lm_marker_comes_from_the_title_call_no_extra_gh_call() {
  lm_env open
  printf '%s\n' '**[code-reviewer] PASS**' > "$LM_BIN/gh-issue-latest-marker"
  local calls n_comments n_both
  lm_launch 42 >/dev/null
  calls=$(gh_calls "$LM_BIN")
  n_comments=$(printf '%s\n' "$calls" | grep -c 'issue view 42 .*comments')
  n_both=$(printf '%s\n' "$calls" | grep 'issue view 42 ' | grep 'title' | grep -c 'comments')
  lm_cleanup
  assert_eq "$n_comments" "1" "#94: exactly one gh call for #42 asks for comments" || return 1
  assert_eq "$n_both" "1" "#94: that one call is the title call (--json title,comments) — no extra API call" || return 1
}

test_lm_failed_fetch_removes_stale_marker_and_still_launches() {
  lm_env open
  printf '%s\n' '**[code-reviewer] PASS**' > "$LM_BIN/gh-issue-latest-marker"
  local ctl
  lm_launch 41 >/dev/null
  ctl=$(lm_marker_file 41)                                  # positive control: a good fetch writes the file
  echo 1 > "$LM_BIN/gh-issue-title-rc"
  echo "STALE MARKER" > "$LM_PIPE/orch-42.marker"
  local out rc m pid=absent
  out=$(lm_launch 42); rc=$?
  m=$(lm_marker_file 42)
  [ -f "$LM_PIPE/orch-42.pid" ] && pid=present
  lm_cleanup
  assert_eq "$ctl" "PASS" "#94: control — a good fetch wrote #41's marker" || return 1
  assert_exit0 "$rc" "#94: launch exits 0 when the fetch fails" || return 1
  assert_eq "$pid" "present" "#94: launch proceeded despite the failed fetch" || return 1
  assert_eq "$m" "ABSENT" "#94: failed gh call leaves no orch-<n>.marker (a stale one is removed)" || return 1
}

test_lm_note_only_comments_leave_no_marker() {
  lm_env open
  printf '%s\n' '**[code-reviewer] PASS**' > "$LM_BIN/gh-issue-latest-marker"
  printf '%s\n' '**[supervisor] NOTE** nothing routable here' > "$LM_BIN/gh-issue-latest-marker-42"
  echo "STALE MARKER" > "$LM_PIPE/orch-42.marker"
  local ctl m
  lm_launch 41 >/dev/null; ctl=$(lm_marker_file 41)
  lm_launch 42 >/dev/null; m=$(lm_marker_file 42)
  lm_cleanup
  assert_eq "$ctl" "PASS" "#94: control — #41 has a routing marker" || return 1
  assert_eq "$m" "ABSENT" "#94: no real routing marker on the issue -> no orch-<n>.marker" || return 1
}

test_lm_supervisor_do_launch_writes_marker_when_title_absent() {
  lm_env open
  printf '%s\n' '**[solutions-architect] SPEC RESOLVED**' > "$LM_BIN/gh-issue-latest-marker"
  mk_queued "$LM_PIPE" 42 "$LM_REPO"
  lm_tick
  local m pid=absent
  m=$(lm_marker_file 42)
  [ -f "$LM_PIPE/orch-42.pid" ] && pid=present
  lm_cleanup
  assert_eq "$pid" "present" "#94: supervisor launched #42 (scenario sanity)" || return 1
  assert_eq "$m" "SPEC RESOLVED" "#94: supervisor dispatch launch writes orch-<n>.marker from GitHub" || return 1
}

test_lm_supervisor_failed_fetch_removes_stale_marker() {
  lm_env open
  printf '%s\n' '**[solutions-architect] SPEC RESOLVED**' > "$LM_BIN/gh-issue-latest-marker"
  mk_queued "$LM_PIPE" 41 "$LM_REPO"
  lm_tick
  local ctl; ctl=$(lm_marker_file 41)                       # control: good fetch writes the file
  echo 1 > "$LM_BIN/gh-issue-title-rc"
  echo "STALE MARKER" > "$LM_PIPE/orch-42.marker"
  mk_queued "$LM_PIPE" 42 "$LM_REPO"
  lm_tick
  local m pid=absent
  m=$(lm_marker_file 42)
  [ -f "$LM_PIPE/orch-42.pid" ] && pid=present
  lm_cleanup
  assert_eq "$ctl" "SPEC RESOLVED" "#94: control — #41's marker written" || return 1
  assert_eq "$pid" "present" "#94: supervisor launch not blocked by a failed fetch" || return 1
  assert_eq "$m" "ABSENT" "#94: failed fetch at supervisor launch -> no stale marker file" || return 1
}

test_lm_marker_parsing_lives_once_in_pipeline_lib() {
  local sedexpr='s/^\*\*\[[^]]*\] //'
  grep -qF -- "$sedexpr" "$RS_LM/pipeline-lib.sh" || { fail "#94: the marker sed cleanup must live in pipeline-lib.sh"; return 1; }
  if grep -qF -- "$sedexpr" "$RS_LM/reconcile-status.sh"; then fail "#94: reconcile-status.sh still carries its own copy of the marker sed cleanup"; return 1; fi
  if grep -qF -- "$sedexpr" "$RS_LM/orchestrate.sh" "$RS_LM/supervisor.sh"; then fail "#94: launchers must use the shared function, not a copy"; return 1; fi
}

test_lm_build_runs_json_has_no_runs_jsonl_marker_fallback() {
  if grep -q 'marker_after' "$RS_LM/build-runs-json.py"; then fail "#94: marker_after fallback must be deleted from build-runs-json.py"; return 1; fi
  if grep -q '_marker_cache' "$RS_LM/build-runs-json.py"; then fail "#94: the runs.jsonl marker cache must be deleted from build-runs-json.py"; return 1; fi
}

run_test test_lm_launched_path_writes_marker_name
run_test test_lm_queued_path_writes_marker_name
run_test test_lm_marker_comes_from_the_title_call_no_extra_gh_call
run_test test_lm_failed_fetch_removes_stale_marker_and_still_launches
run_test test_lm_note_only_comments_leave_no_marker
run_test test_lm_supervisor_do_launch_writes_marker_when_title_absent
run_test test_lm_supervisor_failed_fetch_removes_stale_marker
run_test test_lm_marker_parsing_lives_once_in_pipeline_lib
run_test test_lm_build_runs_json_has_no_runs_jsonl_marker_fallback
