# #725: ci_infra_gate must not hand an exempt-only red `Playwright E2E` to JP. agents/deployer.md (JP 2026-09-22) keeps
# that job out of the merge gate on STAGING, so the supervisor drops it from the failing set (never re-run, never
# classified); with nothing gating left the hold clears (return 0 -> deployer relaunched). Staging base only.
# Builds on the cr_* fixtures of test-supervisor-ci-rerun.sh (sourced earlier in the same run).

HERE_EX=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f cr_fixture >/dev/null 2>&1; then   # standalone run: load the cr_* helpers without running their tests
  declare -f run_test >/dev/null 2>&1 && eval "ex_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_EX/test-supervisor-ci-rerun.sh"
  if declare -f ex_real_run_test >/dev/null 2>&1; then eval "$(declare -f ex_real_run_test | sed '1s/ex_real_run_test/run_test/')"; fi
fi

EX_E2E_LINK="https://github.com/o/r/actions/runs/600/job/950"
# ex_fixture <base branch> <gate log or ''> — exempt E2E (job 950) red; plus gate "unit-tests" (job 901) red when a log is given
ex_fixture() {
  local base=$1 glog=${2:-}
  cr_fixture_cls 'Blocked on: ci_red — checks failing' "$glog"
  printf '%s\n' "$base" > "$SQ_GH/ex-base"
  printf 'Process completed with exit code 1.\nError: migration 068 is missing\n' > "$SQ_GH/cr-log-950"
  local j='{"name":"Playwright E2E","bucket":"fail","link":"'"$EX_E2E_LINK"'"}'
  if [ -n "$glog" ]; then
    j='{"name":"unit-tests","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/901"},'"$j"
  fi
  printf '[%s]\n' "$j" > "$SQ_GH/cr-checks.json"
  # answer the baseRefName read; everything else falls through to the cr_* wrapper
  cp "$SQ_GH/gh" "$SQ_GH/gh-cr"
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$1 $2" in
  "pr view") case "$*" in *baseRefName*) printf '%s\n' "$*" >> "$HERE/gh-calls.log"; cat "$HERE/ex-base"; exit 0 ;; esac ;;
  "run rerun") if [ -f "$HERE/ex-refuse-second-job" ] && [ "$(grep -c '^run rerun' "$HERE/gh-calls.log" 2>/dev/null)" -ge 1 ]; then
      printf '%s\n' "$*" >> "$HERE/gh-calls.log"; echo "run is already running" >&2; exit 1; fi ;;
esac
exec "$HERE/gh-cr" "$@"
GH_EOF
  chmod +x "$SQ_GH/gh"
}
ex_counts() {  # prints: reruns, classify-fetches-of-the-E2E-job, relaunches
  local calls; calls=$(gh_calls "$SQ_GH")
  EX_RERUNS=$(printf '%s\n' "$calls" | grep -c '^run rerun' || true)
  EX_E2E_FETCH=$(printf '%s\n' "$calls" | grep -c -- '--job 950' || true)
  EX_N=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' ')
}

# AC1: staging, only the exempt E2E red -> hold clears, deployer relaunched, no re-run, no classify, no hand-off
test_ex_staging_exempt_only_clears_and_relaunches() {
  ex_fixture staging ''
  ar2_tick; cr_settle; ex_counts
  local alert log h; alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null); log=$(sq_log); h=$(ar2_held)
  sq_cleanup
  assert_eq "$EX_N" "1" "exempt-only red E2E on staging: deployer relaunched" || return 1
  assert_eq "$EX_RERUNS" "0" "exempt E2E never re-run" || return 1
  assert_eq "$EX_E2E_FETCH" "0" "exempt E2E log never read/classified" || return 1
  assert_not_contains "$alert" "finished red" "no real-failure hand-off alert" || return 1
  assert_not_contains "$log" "finished red (real failure)" "no real-failure hand-off log line" || return 1
  assert_eq "$h" "absent" "hold cleared" || return 1
}

# AC2: staging, E2E exempt AND a real gate red -> the real gate is still classified and handed off
test_ex_staging_real_gate_still_handed_off() {
  ex_fixture staging $'AssertionError: expected 1 to equal 2'
  ar2_tick; cr_settle; ex_counts
  local alert h; alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null); h=$(ar2_held)
  sq_cleanup
  assert_contains "$alert" "finished red (real failure)" "real gate red is handed to JP as today" || return 1
  assert_eq "$EX_N" "0" "not relaunched" || return 1
  assert_eq "$EX_RERUNS" "0" "real failure never re-run" || return 1
  assert_eq "$EX_E2E_FETCH" "0" "exempt E2E still not classified" || return 1
  assert_eq "$h" "present" "still held" || return 1
}

# AC3: main / release base -> a red Playwright E2E is still classified and handed off (exemption is staging-only)
test_ex_non_staging_bases_keep_e2e_as_gate() {
  local base alert
  for base in main release/v1.2.3 release/auto-20261115; do
    ex_fixture "$base" ''
    ar2_tick; cr_settle; ex_counts
    alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
    sq_cleanup
    assert_contains "$alert" "finished red (real failure)" "$base: red E2E still handed to JP" || return 1
    assert_eq "$EX_N" "0" "$base: not relaunched" || return 1
    assert_eq "$EX_E2E_FETCH" "1" "$base: E2E log still classified" || return 1
  done
}

# AC3: jpmoya/claude-agents keeps the check as a gate even if a branch were called staging
test_ex_claude_agents_keeps_e2e_as_gate() {
  ex_fixture staging ''
  git -C "$SQ_REPO" remote set-url origin "https://github.com/jpmoya/claude-agents.git"
  ar2_tick; cr_settle; ex_counts
  local alert; alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  sq_cleanup
  assert_contains "$alert" "finished red (real failure)" "claude-agents: red E2E handed to JP" || return 1
  assert_eq "$EX_N" "0" "claude-agents: not relaunched" || return 1
}

# AC4: staging, exempt E2E red + an infra-class gate red -> one re-run of the gate's run only, never the E2E's
test_ex_staging_infra_gate_rerun_never_touches_exempt() {
  ex_fixture staging $'##[group]Initialize containers\n##[error]Error response from daemon'
  ar2_tick; cr_settle; ex_counts
  local calls st; calls=$(gh_calls "$SQ_GH"); st=$(cat "$(rkp "$SQ_PIPE/orch-42.ci-rerun")" 2>/dev/null)
  sq_cleanup
  assert_eq "$EX_RERUNS" "1" "exactly one re-run" || return 1
  assert_contains "$calls" "run rerun 500 --failed" "the gate's run is re-run" || return 1
  assert_not_contains "$calls" "run rerun 600" "the exempt E2E's run is never re-run" || return 1
  assert_eq "$EX_E2E_FETCH" "0" "exempt E2E never classified" || return 1
  assert_eq "$st" "abcdef0123456789" "re-run recorded against the head" || return 1
  assert_eq "$EX_N" "0" "not relaunched on the re-run tick" || return 1
}

# AC4, shared run: the exempt E2E sits in the same workflow run as the gate -> re-run the gate's job by id, never `--failed`
test_ex_staging_infra_gate_shared_run_rerun_by_job() {
  ex_fixture staging $'##[group]Initialize containers\n##[error]Error response from daemon'
  printf '[{"name":"unit-tests","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/901"},{"name":"Playwright E2E","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/950"}]\n' > "$SQ_GH/cr-checks.json"
  ar2_tick; cr_settle; ex_counts
  local calls; calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$EX_RERUNS" "1" "exactly one re-run call" || return 1
  assert_contains "$calls" "run rerun 500 --job 901" "only the gate job is re-run" || return 1
  assert_not_contains "$calls" "--failed" "no --failed re-run that would also restart the exempt job" || return 1
  assert_eq "$EX_E2E_FETCH" "0" "exempt E2E never classified" || return 1
}

# AC4, shared run with two infra gates: GitHub refuses the second per-job re-run -> the head is still recorded
# (one re-run per head), the hold is not re-run again on the next tick
test_ex_shared_run_second_job_refused_still_records_head() {
  ex_fixture staging $'##[group]Initialize containers\n##[error]Error response from daemon'
  printf '[{"name":"unit-tests","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/901"},{"name":"Quality","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/902"},{"name":"Playwright E2E","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/950"}]\n' > "$SQ_GH/cr-checks.json"
  printf '> next build\nProcess completed with exit code 137.\n' > "$SQ_GH/cr-log-902"
  : > "$SQ_GH/ex-refuse-second-job"
  ar2_tick; cr_settle
  local st; st=$(cat "$(rkp "$SQ_PIPE/orch-42.ci-rerun")" 2>/dev/null)
  cr_force_next_check; ar2_tick; cr_settle; ex_counts
  sq_cleanup
  assert_eq "$st" "abcdef0123456789" "head recorded although the second job re-run was refused" || return 1
  assert_eq "$EX_N" "1" "second tick (same head, only infra gates) relaunches instead of re-running again" || return 1
  assert_eq "$EX_E2E_FETCH" "0" "exempt E2E never classified" || return 1
}

echo "-- supervisor ci gate: deployer-exempt Playwright E2E (issue #725)"
run_test test_ex_staging_exempt_only_clears_and_relaunches
run_test test_ex_staging_real_gate_still_handed_off
run_test test_ex_non_staging_bases_keep_e2e_as_gate
run_test test_ex_claude_agents_keeps_e2e_as_gate
run_test test_ex_staging_infra_gate_rerun_never_touches_exempt
run_test test_ex_staging_infra_gate_shared_run_rerun_by_job
run_test test_ex_shared_run_second_job_refused_still_records_head
