# #473: on a ci_red or ci_pending (#484) BLOCKED the supervisor re-runs the failed jobs once per PR head (gh run
# rerun --failed), then relaunches only when every still-failing check is infrastructure-class (ci-classify.sh);
# a real failure stays held — and once classified, hands off to "waiting on JP" instead of parking forever (#484).
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

# cr_fixture_cls <Blocked-on class line> <log for job 901> [log for job 902] — same setup as cr_fixture, with the
# BLOCKED class line chosen by the caller (#484: lets ci_pending use the same fixtures as ci_red).
cr_fixture_cls() {
  local cls_line=$1; shift
  ar2_fixture "$cls_line"
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
# cr_fixture <log for job 901> [log for job 902] — failing checks "unit-tests" (job 901) and optionally "Quality" (job 902)
cr_fixture() { cr_fixture_cls 'Blocked on: ci_red — checks failing' "$@"; }
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

# #484: ci_pending now goes through the same re-run/classify gate as ci_red (a ci_pending hold whose checks
# finish red must not sit "parked, auto-retry" forever — it used to never even re-run its failed checks).
test_cr_ci_pending_also_reruns_once() {
  ar2_fixture 'Blocked on: ci_pending — waiting for checks'
  cr_install_gh
  echo fail > "$SQ_GH/gh-pr-checks"
  printf 'abcdef0123456789\n' > "$SQ_GH/cr-head"
  printf '[{"name":"unit-tests","bucket":"fail","link":"https://github.com/o/r/actions/runs/500/job/901"}]\n' > "$SQ_GH/cr-checks.json"
  ar2_tick; cr_settle
  local reruns h; reruns=$(gh_calls "$SQ_GH" | grep -c '^run rerun' || true); h=$(ar2_held)
  sq_cleanup
  assert_eq "$reruns" "1" "ci_pending re-runs the failed job once, same as ci_red" || return 1
  assert_eq "$h" "present" "still held on the re-run tick" || return 1
}

# ---- #484: a ci_pending/ci_red hold whose CI finishes red for real hands off to "waiting on JP" instead of
# parking forever as "parked, auto-retry" ---------------------------------------------------------------------

test_cr_484_ci_pending_real_failure_hands_off_to_waiting_on_jp() {
  cr_fixture_cls 'Blocked on: ci_pending — waiting for checks' $'AssertionError: expected 1 to equal 2'
  ar2_tick; cr_force_next_check; ar2_tick; cr_settle
  local alert log n h c st calls_after_2
  alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  log=$(sq_log)
  st=$(cat "$(rkp "$SQ_PIPE/orch-42.ci-rerun")" 2>/dev/null)
  n=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '); h=$(ar2_held); c=$(ar2_counter)
  calls_after_2=$(wc -l < "$SQ_GH/gh-calls.log" | tr -d ' ')
  assert_eq "$st" "abcdef0123456789" "484: one re-run recorded against the head (reused .ci-rerun)" || { sq_cleanup; return 1; }
  assert_contains "$alert" "waiting on JP" "484: .alert becomes the waiting-on-JP text" || { sq_cleanup; return 1; }
  assert_contains "$alert" "finished red (real failure)" "484: .alert names the real failure" || { sq_cleanup; return 1; }
  assert_eq "$(printf '%s\n' "$log" | grep -c '\[auto-retry\] #42 — ci_pending finished red (real failure), waiting on JP' || true)" "1" \
    "484: exactly one hand-off log line" || { sq_cleanup; return 1; }
  assert_eq "$n" "0" "484: not relaunched" || { sq_cleanup; return 1; }
  assert_eq "$h" "present" "484: still held (now waiting on JP, counter untouched)" || { sq_cleanup; return 1; }
  assert_eq "$c" "ABSENT" "484: no retry consumed (reused .autoretry, not bumped)" || { sq_cleanup; return 1; }

  # Issue #484 AC: the hand-off happens once per hold, not on every tick. A 3rd tick (throttle forced open again)
  # must not touch gh at all (the "finished red (real failure)" alert is recognized and skipped before any gh
  # call), must not write a 2nd log line, and must leave .alert byte-identical.
  cr_force_next_check; ar2_tick; cr_settle
  local alert2 log2 calls_after_3
  alert2=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  log2=$(sq_log)
  calls_after_3=$(wc -l < "$SQ_GH/gh-calls.log" | tr -d ' ')
  sq_cleanup
  assert_eq "$alert2" "$alert" "484: .alert unchanged by the 3rd tick" || return 1
  assert_eq "$(printf '%s\n' "$log2" | grep -c '\[auto-retry\] #42 — ci_pending finished red (real failure), waiting on JP' || true)" "1" \
    "484: still exactly one hand-off log line after a 3rd tick" || return 1
  assert_eq "$calls_after_3" "$calls_after_2" "484: the 3rd tick makes no further gh calls for this hold" || return 1
}

# Same scenario starting from ci_red, confirming the pre-existing #473 real-failure path still works (and now
# also reaches the #271 hand-off, same as ci_pending above).
test_cr_484_ci_red_real_failure_hands_off_to_waiting_on_jp() {
  cr_fixture $'AssertionError: expected 1 to equal 2'
  ar2_tick; cr_force_next_check; ar2_tick; cr_settle
  local alert log n h c
  alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  log=$(sq_log)
  n=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '); h=$(ar2_held); c=$(ar2_counter)
  sq_cleanup
  assert_contains "$alert" "waiting on JP" "484 (ci_red): .alert becomes the waiting-on-JP text" || return 1
  assert_contains "$alert" "finished red (real failure)" "484 (ci_red): .alert names the real failure" || return 1
  assert_eq "$(printf '%s\n' "$log" | grep -c '\[auto-retry\] #42 — ci_red finished red (real failure), waiting on JP' || true)" "1" \
    "484 (ci_red): exactly one hand-off log line" || return 1
  assert_eq "$n" "0" "484 (ci_red): not relaunched" || return 1
  assert_eq "$h" "present" "484 (ci_red): still held" || return 1
  assert_eq "$c" "ABSENT" "484 (ci_red): no retry consumed" || return 1
}

# A ci_pending hold whose checks are still pending (not yet finished, red or green) stays parked, unchanged: no
# hand-off, no re-run, no log line, no alert rewrite.
test_cr_484_ci_pending_still_pending_stays_parked_unchanged() {
  cr_fixture_cls 'Blocked on: ci_pending — waiting for checks' ''
  printf '[{"name":"unit-tests","bucket":"pending","link":"https://github.com/o/r/actions/runs/500/job/901"}]\n' > "$SQ_GH/cr-checks.json"
  ar2_tick; cr_settle
  local alert log n h c reruns
  alert=$(cat "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null)
  log=$(sq_log)
  n=$(wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '); h=$(ar2_held); c=$(ar2_counter)
  reruns=$(gh_calls "$SQ_GH" | grep -c '^run rerun' || true)
  sq_cleanup
  assert_eq "$reruns" "0" "484: still-pending checks are never re-run" || return 1
  assert_not_contains "$alert" "waiting on JP" "484: .alert not rewritten while still pending" || return 1
  assert_not_contains "$log" "finished red (real failure)" "484: no hand-off log line while still pending" || return 1
  assert_eq "$n" "0" "484: not relaunched" || return 1
  assert_eq "$h" "present" "484: stays parked" || return 1
  assert_eq "$c" "ABSENT" "484: no retry consumed" || return 1
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
run_test test_cr_ci_pending_also_reruns_once
run_test test_cr_484_ci_pending_real_failure_hands_off_to_waiting_on_jp
run_test test_cr_484_ci_red_real_failure_hands_off_to_waiting_on_jp
run_test test_cr_484_ci_pending_still_pending_stays_parked_unchanged
run_test test_cr_docs_name_the_classes
