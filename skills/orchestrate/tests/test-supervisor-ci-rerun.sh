# #473: on a ci_red BLOCKED the supervisor re-runs the failed jobs once per PR head (gh run rerun --failed), then
# relaunches only when every still-failing check is infrastructure-class (ci-classify.sh); real failures stay held.
# Builds on the ar2_* fixtures of test-supervisor-auto-retry.sh (sourced earlier in the same run).

HERE_CR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f ar2_fixture >/dev/null 2>&1; then   # standalone run: load the ar2_* helpers without running their tests
  eval "cr_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_CR/test-supervisor-auto-retry.sh"
  eval "$(declare -f cr_real_run_test | sed '1s/cr_real_run_test/run_test/')"
fi

cr_install_gh() {  # layer ci-rerun answers over the ar2 fake gh; everything else falls through to it
  cp "$SQ_GH/gh" "$SQ_GH/gh-ar2"   # ar2_fixture already installed the ar2 wrapper
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$1 $2" in
  "pr view") case "$*" in *headRefOid*) printf '%s\n' "$(cat "$HERE/cr-head" 2>/dev/null)"; printf '%s\n' "$*" >> "$HERE/gh-calls.log"; exit 0 ;; esac ;;
  "pr checks") case "$*" in *--json*) printf '%s\n' "$*" >> "$HERE/gh-calls.log"; cat "$HERE/cr-checks.json"; exit 1 ;; esac ;;
  "run rerun") printf '%s\n' "$*" >> "$HERE/gh-calls.log"; exit 0 ;;
  "run view") printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    job=""; prev=""; for a in "$@"; do [ "$prev" = "--job" ] && job=$a; prev=$a; done
    cat "$HERE/cr-log-$job" 2>/dev/null; exit 0 ;;
esac
exec "$HERE/gh-ar2" "$@"
GH_EOF
  chmod +x "$SQ_GH/gh"
}

# cr_fixture <log for job 901> [log for job 902] — failing checks "unit-tests" (job 901) and optionally "Quality" (job 902)
cr_fixture() {
  ar2_fixture 'Blocked on: ci_red — checks failing'
  cr_install_gh
  echo fail > "$SQ_GH/gh-pr-checks"
  printf 'abcdef0123456789\n' > "$SQ_GH/cr-head"
  local j='[{"name":"unit-tests","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/901"}'
  printf '%s\n' "$1" > "$SQ_GH/cr-log-901"
  if [ -n "${2:-}" ]; then
    j="$j"',{"name":"Quality","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/902"}'
    printf '%s\n' "$2" > "$SQ_GH/cr-log-902"
  fi
  printf '%s]\n' "$j" > "$SQ_GH/cr-checks.json"
}
cr_force_next_check() { rm -f "$(rkp "$SQ_PIPE/orch-42.autoretry-check")"; }
cr_settle() { local i; for i in $(seq 1 10); do [ -s "$SQ_PIPE/claude.calls" ] && break; sleep 0.1; done; sleep 0.5; }

test_cr_first_tick_reruns_failed_once_and_stays_held() {
  cr_fixture $'##[group]Initialize containers\n##[error]Error response from daemon'
  ar2_tick; cr_settle
  local calls n h st; calls=$(gh_calls "$SQ_GH"); n=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '); h=$(ar2_held)
  st=$(cat "$(rkp "$SQ_PIPE/orch-42.ci-rerun")" 2>/dev/null)
  sq_cleanup
  assert_contains "$calls" "run rerun 500 --failed" "failed jobs re-run" || return 1
  assert_eq "$n" "0" "no relaunch on the re-run tick" || return 1
  assert_eq "$h" "present" "still held" || return 1
  assert_eq "$st" "abcdef0123456789" "re-run recorded against the head" || return 1
}

test_cr_second_tick_infra_only_relaunches_with_tolerated_checks() {
  cr_fixture $'##[group]Initialize containers\n##[error]Error response from daemon' $'> next build\nProcess completed with exit code 137.'
  ar2_tick; cr_force_next_check; ar2_tick; cr_settle
  local calls n reruns; calls=$(gh_calls "$SQ_GH"); n=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' ')
  reruns=$(printf '%s\n' "$calls" | grep -c '^run rerun' || true)
  sq_cleanup
  assert_eq "$reruns" "1" "exactly one re-run" || return 1
  assert_eq "$n" "1" "infra-only after the re-run -> relaunched" || return 1
  assert_contains "$calls" "only infrastructure-class checks fail after one re-run of abcdef012345: unit-tests (container_start); Quality (oom)" "NOTE names the tolerated checks" || return 1
}

test_cr_second_tick_real_failure_stays_held() {
  cr_fixture $'##[group]Initialize containers\n##[error]Error response from daemon' $'AssertionError: expected 1 to equal 2'
  ar2_tick; cr_force_next_check; ar2_tick; cr_settle
  local n h c; n=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '); h=$(ar2_held); c=$(ar2_counter)
  sq_cleanup
  assert_eq "$n" "0" "a real failure is never tolerated" || return 1
  assert_eq "$h" "present" "still held" || return 1
  assert_eq "$c" "ABSENT" "no retry consumed" || return 1
}

test_cr_no_second_rerun_for_same_head() {
  cr_fixture $'AssertionError: nope'
  ar2_tick; cr_force_next_check; ar2_tick; cr_force_next_check; ar2_tick; cr_settle
  local reruns; reruns=$(gh_calls "$SQ_GH" | grep -c '^run rerun' || true)
  sq_cleanup
  assert_eq "$reruns" "1" "one re-run per head" || return 1
}

test_cr_new_head_gets_one_more_rerun() {
  cr_fixture $'AssertionError: nope'
  ar2_tick; printf 'fedcba9876543210\n' > "$SQ_GH/cr-head"; cr_force_next_check; ar2_tick; cr_settle
  local reruns; reruns=$(gh_calls "$SQ_GH" | grep -c '^run rerun' || true)
  sq_cleanup
  assert_eq "$reruns" "2" "a new head is re-run once" || return 1
}

test_cr_ci_pending_never_reruns() {
  ar2_fixture 'Blocked on: ci_pending — waiting for checks'
  cr_install_gh
  echo fail > "$SQ_GH/gh-pr-checks"
  printf 'abcdef0123456789\n' > "$SQ_GH/cr-head"
  printf '[{"name":"unit-tests","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/901"}]\n' > "$SQ_GH/cr-checks.json"
  ar2_tick; cr_settle
  local reruns; reruns=$(gh_calls "$SQ_GH" | grep -c '^run rerun' || true)
  sq_cleanup
  assert_eq "$reruns" "0" "only ci_red re-runs" || return 1
}

test_cr_docs_name_the_classes() {
  local sup dep
  sup=$(cat "$(dirname "${BASH_SOURCE[0]}")/../supervisor.sh")
  dep=$(cat "$(dirname "${BASH_SOURCE[0]}")/../../../agents/deployer.md")
  assert_contains "$sup" "Initialize containers" "supervisor documents the classes" || return 1
  assert_contains "$sup" "No space left on device" "supervisor documents ENOSPC" || return 1
  assert_contains "$dep" "ci-classify.sh" "deployer uses the classifier" || return 1
  assert_contains "$dep" "STAGING ONLY" "deployer tolerance is staging only" || return 1
  assert_contains "$dep" "User-facing change" "deployer documents the PR-format class" || return 1
}

echo "-- supervisor ci re-run (issue #473)"
run_test test_cr_first_tick_reruns_failed_once_and_stays_held
run_test test_cr_second_tick_infra_only_relaunches_with_tolerated_checks
run_test test_cr_second_tick_real_failure_stays_held
run_test test_cr_no_second_rerun_for_same_head
run_test test_cr_new_head_gets_one_more_rerun
run_test test_cr_ci_pending_never_reruns
run_test test_cr_docs_name_the_classes
