# Issue #250 decision 3 — supervisor.sh auto-retries a .held run whose latest gate is a BLOCKED of class
# ci_pending/ci_red/merge_conflict/dependency once the cause has cleared: bounded at 3 (orch-<n>.autoretry),
# throttled to one cause-check per 30 min per run, never for needs_jp / other / unsupported_project / non-BLOCKED
# gates. Errors on the path alert the existing Slack webhook with release/environment/route tags.
#
# Fake gh (wrapper over the shared fake) knobs, files in $SQ_GH:
#   gh-pr-checks       pass (default) | fail | pending   -> `gh pr checks` exit 0 / 1 / 8
#   gh-pr-mergeable    MERGEABLE (default) | CONFLICTING | UNKNOWN
#   gh-pr-fail         exit code: every `gh pr ...` fails with that code (stderr carries a fake secret)
#   gh-issue-body-<n>  body of issue n;  gh-issue-state-<n> OPEN|CLOSED (shared fake)
# Expected values come from the ticket. Reuses the sq_* helpers (same loading trick as test-supervisor-live-stage-defers.sh).

HERE_AR2=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "ar2_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_AR2/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f ar2_real_run_test | sed '1s/ar2_real_run_test/run_test/')"
fi

AR2_BLK='**[fullstack-developer] BLOCKED**'

ar2_install_gh() {
  cp "$SQ_GH/gh" "$SQ_GH/gh-base"
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$1 $2" in
  "pr "*|"issue view"|"api repos/"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log" ;;
  *) exec "$HERE/gh-base" "$@" ;;
esac
jqexpr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr=$a; prev=$a; done
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
if [ "$1" = pr ]; then
  if [ -f "$HERE/gh-pr-fail" ]; then echo "HTTP 500 token=ghp_FAKESECRET123" >&2; exit "$(cat "$HERE/gh-pr-fail")"; fi
  mg=$(cat "$HERE/gh-pr-mergeable" 2>/dev/null || echo MERGEABLE)
  ck=$(cat "$HERE/gh-pr-checks" 2>/dev/null || echo pass)
  case "$2" in
    list)
      case "$*" in
        *"--state merged"*) [ -f "$HERE/gh-pr-merged" ] && emit "[{\"number\":7,\"headRefName\":\"issue-42-x\"}]" || emit "[]" ;;
        *) [ -f "$HERE/gh-pr-none-open" ] && emit "[]" || emit "[{\"number\":7,\"state\":\"OPEN\",\"headRefName\":\"issue-42-x\",\"mergeable\":\"$mg\"}]" ;;
      esac ;;
    view) emit "{\"number\":7,\"state\":\"OPEN\",\"mergeable\":\"$mg\",\"headRefName\":\"issue-42-x\"}" ;;
    checks)
      case "$ck" in pass) rc=0 ;; fail) rc=1 ;; *) rc=8 ;; esac
      case "$*" in
        *--json*) emit "[{\"name\":\"ci\",\"state\":\"$(echo $ck | tr a-z A-Z)\",\"bucket\":\"$ck\"}]" ;;
        *) printf 'ci\t%s\t1m\turl\n' "$ck" ;;
      esac
      exit $rc ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
  esac
  exit 0
fi
# issue view (and its REST twin, #388: gh api repos/<o>/<r>/issues/<n>[/comments])
n=$(printf '%s' "$*" | sed -n -e 's/.*issue view \([0-9][0-9]*\).*/\1/p' -e 's|^api repos/[^/]*/[^/]*/issues/\([0-9][0-9]*\).*|\1|p')
if [ "$1" = api ]; then
  [ -f "$HERE/gh-api-fail" ] && { echo "token=ghp_FAKESECRET123" >&2; exit 1; }
  case "$*" in
    *"/comments"*) jq -c 'map({body: .body, created_at: .createdAt})' "$HERE/gh-issue-comments-json-$n" 2>/dev/null || echo '[]' ;;
    *) jq -nc --arg s "$(cat "$HERE/gh-issue-state-$n" 2>/dev/null || echo OPEN)" --arg b "$(cat "$HERE/gh-issue-body-$n" 2>/dev/null)" '{state:($s|ascii_downcase), body:$b, updated_at:"2026-01-01T00:00:00Z"}' ;;
  esac
  exit 0
fi
state=$(cat "$HERE/gh-issue-state-$n" 2>/dev/null || echo OPEN)
body=$(cat "$HERE/gh-issue-body-$n" 2>/dev/null || echo "")
comments=$(cat "$HERE/gh-issue-comments-json-$n" 2>/dev/null || echo '[]')
emit "$(jq -nc --arg s "$state" --arg b "$body" --argjson c "$comments" '{state:$s, body:$b, comments:$c, labels:[], title:"T"}')"
exit 0
GH_EOF
  chmod +x "$SQ_GH/gh"
  # claude stub: one line per launch
  printf '#!/bin/bash\necho "$*" >> "%s/claude.calls"\nexit 0\n' "$SQ_PIPE" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"
}

# ar2_fixture <class-line or marker body line 2> [marker] — held run #42 whose latest gate is the BLOCKED comment
ar2_fixture() {
  local line2=$1 marker=${2:-$AR2_BLK} body
  sq_env open; sq_free_slots; ar2_install_gh
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  printf 'BLOCKED\n' > "$(rkp "$SQ_PIPE/orch-42.marker")"
  body="$marker"$'\n'"$line2"
  jq -nc --arg b "$body" '[{body:$b, createdAt:"2026-09-20T10:00:00Z", author:{login:"x"}}]' > "$SQ_GH/gh-issue-comments-json-42"
  : > "$SQ_PIPE/claude.calls"
}
ar2_tick() { sq_run "$SUP_SQ" >/dev/null 2>&1; }
ar2_launches() {  # wait briefly for the async launch, then count claude invocations
  local i; for i in $(seq 1 20); do [ -s "$SQ_PIPE/claude.calls" ] && break; sleep 0.1; done
  wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '
}
ar2_no_launch() {  # negatives: sq_run is synchronous; wait for the cause-check signal (pr call) if one is expected, then settle
  local i; for i in $(seq 1 10); do [ "$(ar2_pr_calls)" -ge 1 ] && break; sleep 0.1; done
  sleep 0.7; wc -l < "$SQ_PIPE/claude.calls" | tr -d ' '
}
ar2_pr_calls() { grep -c '^pr ' "$SQ_GH/gh-calls.log" 2>/dev/null || true; }
ar2_counter() { if [ -f "$(rkp "$SQ_PIPE/orch-42.autoretry")" ]; then head -n1 "$(rkp "$SQ_PIPE/orch-42.autoretry")" | tr -d ' \n'; else echo ABSENT; fi; }
ar2_held() { sq_present "$(rkp "$SQ_PIPE/orch-42.held")"; }

# ---- cleared -> relaunched once --------------------------------------------------------------------------------
test_ar2_ci_red_checks_green_relaunches_once() {
  ar2_fixture 'Blocked on: ci_red — checks failing'
  echo pass > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local n c h log calls; n=$(ar2_launches); c=$(ar2_counter); h=$(ar2_held); log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "decision 3: cleared ci_red -> relaunched exactly once" || return 1
  assert_eq "$c" "1" "decision 3: orch-42.autoretry = 1" || return 1
  assert_eq "$h" "absent" "decision 3: .held cleared" || return 1
  assert_contains "$calls" "auto-retry 1/3: ci_red cleared" "decision 3: NOTE posted on the issue" || return 1
  assert_contains "$calls" "**[supervisor] NOTE**" "decision 3: the comment is a supervisor NOTE" || return 1
  assert_contains "$log" "#42" "control: the tick logged the run" || return 1
}

test_ar2_ci_pending_relaunches_when_checks_pass() {
  ar2_fixture 'Blocked on: ci_pending — waiting for checks'
  echo pass > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "ci_pending cleared -> relaunched" || return 1
  assert_contains "$calls" "auto-retry 1/3: ci_pending cleared" "NOTE names the class" || return 1
}

test_ar2_merge_conflict_relaunches_when_mergeable() {
  ar2_fixture 'Blocked on: merge_conflict — rebase needed'
  echo MERGEABLE > "$SQ_GH/gh-pr-mergeable"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "merge_conflict cleared (not CONFLICTING) -> relaunched" || return 1
  assert_contains "$calls" "auto-retry 1/3: merge_conflict cleared" "NOTE names the class" || return 1
}

test_ar2_dependency_relaunches_when_all_depends_closed() {
  ar2_fixture 'Blocked on: dependency — waits on #77 and #78'
  printf 'Why\nDepends on #77\nDepends on #78\n' > "$SQ_GH/gh-issue-body-42"
  echo CLOSED > "$SQ_GH/gh-issue-state-77"; echo CLOSED > "$SQ_GH/gh-issue-state-78"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "every Depends on #N closed -> relaunched" || return 1
  assert_contains "$calls" "auto-retry 1/3: dependency cleared" "NOTE names the class" || return 1
}

# ---- cause not cleared -> held stays ----------------------------------------------------------------------------
test_ar2_439_ci_pending_merged_pr_clears() {
  ar2_fixture 'Blocked on: ci_pending — waiting for staging deploy'
  : > "$SQ_GH/gh-pr-none-open"; : > "$SQ_GH/gh-pr-merged"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "merged PR, no open PR -> relaunched" || return 1
  assert_contains "$calls" "auto-retry 1/3: ci_pending cleared" "NOTE posted" || return 1
}

test_ar2_439_no_open_no_merged_not_cleared() {
  ar2_fixture 'Blocked on: ci_pending — waiting for checks'
  : > "$SQ_GH/gh-pr-none-open"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "no PR at all -> not cleared" || return 1
}

test_ar2_439_merge_conflict_merged_pr_unchanged() {
  ar2_fixture 'Blocked on: merge_conflict — rebase needed'
  : > "$SQ_GH/gh-pr-none-open"; : > "$SQ_GH/gh-pr-merged"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "merge_conflict ignores merged PRs" || return 1
}

test_ar2_ci_red_checks_still_failing_not_relaunched() {
  ar2_fixture 'Blocked on: ci_red — checks failing'
  echo fail > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local n c h; n=$(ar2_no_launch); c=$(ar2_counter); h=$(ar2_held)
  sq_cleanup
  assert_eq "$n" "0" "failing checks -> no relaunch" || return 1
  assert_eq "$h" "present" "still held" || return 1
  assert_eq "$c" "ABSENT" "no retry consumed" || return 1
}

test_ar2_ci_red_checks_pending_not_relaunched() {
  ar2_fixture 'Blocked on: ci_red — checks failing'
  echo pending > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "pending checks (none failing/pending required) -> no relaunch" || return 1
}

test_ar2_merge_conflict_still_conflicting_not_relaunched() {
  ar2_fixture 'Blocked on: merge_conflict — rebase needed'
  echo CONFLICTING > "$SQ_GH/gh-pr-mergeable"
  ar2_tick
  local n h; n=$(ar2_no_launch); h=$(ar2_held)
  sq_cleanup
  assert_eq "$n" "0" "CONFLICTING -> no relaunch" || return 1
  assert_eq "$h" "present" "still held" || return 1
}

test_ar2_dependency_one_still_open_not_relaunched() {
  ar2_fixture 'Blocked on: dependency — waits on #77 and #78'
  printf 'Depends on #77\nDepends on #78\n' > "$SQ_GH/gh-issue-body-42"
  echo CLOSED > "$SQ_GH/gh-issue-state-77"; echo OPEN > "$SQ_GH/gh-issue-state-78"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "one dependency still open -> no relaunch" || return 1
}

# ---- bound of 3 --------------------------------------------------------------------------------------------------
test_ar2_third_retry_is_allowed_and_numbered_3_of_3() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo 2 > "$(rkp "$SQ_PIPE/orch-42.autoretry")"
  ar2_tick
  local n c calls; n=$(ar2_launches); c=$(ar2_counter); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "counter 2 -> the 3rd retry still fires" || return 1
  assert_eq "$c" "3" "counter = 3" || return 1
  assert_contains "$calls" "auto-retry 3/3: ci_red cleared" "NOTE says 3/3" || return 1
}

test_ar2_fourth_retry_never_fires() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo 3 > "$(rkp "$SQ_PIPE/orch-42.autoretry")"
  echo pass > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local n c h; n=$(ar2_no_launch); c=$(ar2_counter); h=$(ar2_held)
  sq_cleanup
  assert_eq "$n" "0" "counter 3 -> no 4th relaunch even though the cause cleared" || return 1
  assert_eq "$c" "3" "counter unchanged" || return 1
  assert_eq "$h" "present" "run stays held (shown in Parked with its reason)" || return 1
}

# ---- never touches JP-only / unretryable gates --------------------------------------------------------------------
test_ar2_jp_only_and_unretryable_gates_are_never_relaunched() {
  local spec marker line2 n h
  for spec in 'needs_jp|Blocked on: needs_jp — pick a vendor' 'other|Blocked on: other — odd' \
              'unsupported_project|Blocked on: unsupported_project — x' 'noclass|Blocked on: which DB?' 'empty|'; do
    line2=${spec#*|}
    ar2_fixture "$line2"
    echo pass > "$SQ_GH/gh-pr-checks"; echo MERGEABLE > "$SQ_GH/gh-pr-mergeable"
    ar2_tick
    n=$(ar2_no_launch); h=$(ar2_held)
    sq_cleanup
    assert_eq "$n" "0" "[$line2] is never auto-retried" || return 1
    assert_eq "$h" "present" "[$line2] stays held" || return 1
  done
}

test_ar2_non_blocked_gates_are_never_relaunched() {
  local m n h
  for m in '**[infra-operator] AWAITING GO**' '**[product-manager] EFFORT APPROVAL NEEDED**' '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'; do
    ar2_fixture 'Blocked on: ci_red — decoy class on a JP gate' "$m"
    echo pass > "$SQ_GH/gh-pr-checks"
    ar2_tick
    n=$(ar2_no_launch); h=$(ar2_held)
    sq_cleanup
    assert_eq "$n" "0" "$m never auto-retried" || return 1
    assert_eq "$h" "present" "$m stays held" || return 1
  done
}

# ---- throttle --------------------------------------------------------------------------------------------------
test_ar2_second_tick_within_30_min_does_not_check_again() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo fail > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local first; first=$(ar2_pr_calls)
  ar2_tick
  local second; second=$(ar2_pr_calls)
  sq_cleanup
  [ "$first" -ge 1 ] || { fail "control: the first tick must check the cause (pr calls: $first)"; return 1; }
  assert_eq "$second" "$first" "throttle: no second cause-check within 30 minutes" || return 1
}

# F2: after the 30 min window the cause is checked again (state backdated by 31 min; works for mtime- or epoch-content state)
test_ar2_check_runs_again_after_30_min() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo fail > "$SQ_GH/gh-pr-checks"
  local before; before=$(ls "$SQ_PIPE")
  ar2_tick
  local first f new; first=$(ar2_pr_calls)
  for f in $(ls "$SQ_PIPE"); do
    case "$f" in orch-*-42.*) printf '%s\n' "$before" | grep -qx "$f" && continue
      python3 -c 'import os,sys,time; t=time.time()-31*60; os.utime(sys.argv[1],(t,t))' "$SQ_PIPE/$f"
      if grep -Eqx '[0-9]{9,}' "$SQ_PIPE/$f" 2>/dev/null; then echo $(( $(head -n1 "$SQ_PIPE/$f") - 1900 )) > "$SQ_PIPE/$f"; fi ;;
    esac
  done
  ar2_tick
  local second; second=$(ar2_pr_calls)
  sq_cleanup
  [ "$first" -ge 1 ] || { fail "control: the first tick must check the cause (pr calls: $first)"; return 1; }
  [ "$second" -gt "$first" ] || { fail "after 31 min the cause is checked again (first=$first second=$second)"; return 1; }
}

# ---- observability ---------------------------------------------------------------------------------------------
test_ar2_cause_check_error_alerts_slack_with_tags_and_no_secret() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo 4 > "$SQ_GH/gh-pr-fail"
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$SQ_GH" > "$SQ_GH/curl"; chmod +x "$SQ_GH/curl"
  ar2_tick
  local calls n c h log
  calls=$(grep 'hooks.slack.test' "$SQ_GH/curl.calls" 2>/dev/null); n=$(ar2_no_launch); c=$(ar2_counter); h=$(ar2_held); log=$(sq_log)
  sq_cleanup
  assert_contains "$calls" "route=supervisor/auto-retry" "alert carries the route tag" || return 1
  case "$calls" in *environment=[a-zA-Z0-9]*) ;; *) fail "environment tag must have a value: $calls"; return 1 ;; esac
  assert_contains "$calls" "release=" "alert carries the release tag" || return 1
  case "$calls" in *release=unknown*) fail "release must be the commit SHA, got unknown"; return 1 ;; esac
  assert_not_contains "$calls" "ghp_FAKESECRET123" "alert carries no secret from the failing call" || return 1
  assert_not_contains "$log" "ghp_FAKESECRET123" "supervisor log carries no secret" || return 1
  assert_eq "$n" "0" "an unreadable cause is not a cleared cause: no relaunch" || return 1
  assert_eq "$c" "ABSENT" "no retry consumed on error" || return 1
  assert_eq "$h" "present" "stays held" || return 1
}

run_test test_ar2_ci_red_checks_green_relaunches_once
run_test test_ar2_ci_pending_relaunches_when_checks_pass
run_test test_ar2_merge_conflict_relaunches_when_mergeable
run_test test_ar2_dependency_relaunches_when_all_depends_closed
run_test test_ar2_ci_red_checks_still_failing_not_relaunched
run_test test_ar2_439_ci_pending_merged_pr_clears
run_test test_ar2_439_no_open_no_merged_not_cleared
run_test test_ar2_439_merge_conflict_merged_pr_unchanged
run_test test_ar2_ci_red_checks_pending_not_relaunched
run_test test_ar2_merge_conflict_still_conflicting_not_relaunched
run_test test_ar2_dependency_one_still_open_not_relaunched
run_test test_ar2_third_retry_is_allowed_and_numbered_3_of_3
run_test test_ar2_fourth_retry_never_fires
run_test test_ar2_jp_only_and_unretryable_gates_are_never_relaunched
run_test test_ar2_non_blocked_gates_are_never_relaunched
run_test test_ar2_second_tick_within_30_min_does_not_check_again
run_test test_ar2_check_runs_again_after_30_min
run_test test_ar2_cause_check_error_alerts_slack_with_tags_and_no_secret

# ===================================================================================================================
# Issue #269 (follow-up to #250) — NOTE posted before the requeue, spend-hold skip, multi-#N deps, extra carry-over,
# local-marker check before the gh read, alert on gh failure. Expected values from the ticket's ACs 3, 4, 6.
# ===================================================================================================================

# ar2_wrap_comment — layer over the fake gh: on `issue comment` record whether the queue file / .held existed at that
# instant (-> comment-state.log); fail with exit 1 (stderr carries a fake secret) when $SQ_GH/gh-comment-fail exists.
ar2_wrap_comment() {
  cp "$SQ_GH/gh" "$SQ_GH/gh-ar2"
  cat > "$SQ_GH/gh" <<GH_EOF
#!/bin/bash
HERE=\$(cd "\$(dirname "\$0")" && pwd)
if [ "\$1 \$2" = "issue comment" ]; then
  printf 'queue=%s held=%s\n' "\$([ -e "$(rkp "$SQ_PIPE/queue/orch-42.json")" ] && echo yes || echo no)" "\$([ -e "$(rkp "$SQ_PIPE/orch-42.held")" ] && echo yes || echo no)" >> "\$HERE/comment-state.log"
  if [ -f "\$HERE/gh-comment-fail" ]; then echo "HTTP 502 token=ghp_FAKESECRET123" >&2; exit 1; fi
fi
exec "\$HERE/gh-ar2" "\$@"
GH_EOF
  chmod +x "$SQ_GH/gh"
}
ar2_queue_exists() { sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")"; }

# AC3a: the NOTE is posted before the queue file is written (and before .held is removed)
test_ar2_269_note_posted_before_queue_file_written() {
  ar2_fixture 'Blocked on: ci_red — x'
  ar2_wrap_comment
  echo pass > "$SQ_GH/gh-pr-checks"
  ar2_tick
  local st n; st=$(cat "$SQ_GH/comment-state.log" 2>/dev/null); n=$(ar2_launches)
  sq_cleanup
  assert_eq "$st" "queue=no held=yes" "269 AC3: at the instant the NOTE is posted the queue file is absent and .held still present" || return 1
  assert_eq "$n" "1" "269 control: the run is still relaunched after the NOTE posted" || return 1
}

# AC3b: failing `gh issue comment` -> no queue file, .held kept, counter unchanged, no launch
test_ar2_269_failed_note_post_does_not_requeue() {
  ar2_fixture 'Blocked on: ci_red — x'
  ar2_wrap_comment
  echo pass > "$SQ_GH/gh-pr-checks"; echo fail > "$SQ_GH/gh-comment-fail"
  ar2_tick
  local q h c n log
  q=$(ar2_queue_exists); h=$(ar2_held); c=$(ar2_counter); n=$(ar2_no_launch); log=$(sq_log)
  sq_cleanup
  assert_eq "$(cat /dev/null; echo x)" "x" "control" || return 1
  assert_eq "$q" "absent" "269 AC3: no queue file when the NOTE could not be posted" || return 1
  assert_eq "$h" "present" "269 AC3: .held kept for the next tick" || return 1
  assert_eq "$c" "ABSENT" "269 AC3: counter unchanged" || return 1
  assert_eq "$n" "0" "269 AC3: nothing launched" || return 1
  assert_not_contains "$log" "ghp_FAKESECRET123" "269: no secret in the supervisor log" || return 1
}

# AC6: gh comment failure alerts Slack with release/environment/route tags and no secret
test_ar2_269_comment_failure_alerts_slack_with_tags() {
  ar2_fixture 'Blocked on: ci_red — x'
  ar2_wrap_comment
  echo pass > "$SQ_GH/gh-pr-checks"; echo fail > "$SQ_GH/gh-comment-fail"
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$SQ_GH" > "$SQ_GH/curl"; chmod +x "$SQ_GH/curl"
  ar2_tick
  local calls; calls=$(grep 'hooks.slack.test' "$SQ_GH/curl.calls" 2>/dev/null)
  sq_cleanup
  assert_contains "$calls" "route=supervisor/auto-retry" "269 AC6: route tag" || return 1
  assert_contains "$calls" "release=" "269 AC6: release tag" || return 1
  case "$calls" in *release=unknown*) fail "269 AC6: release must be the commit SHA"; return 1 ;; esac
  case "$calls" in *environment=[a-zA-Z0-9]*) ;; *) fail "269 AC6: environment tag must have a value: $calls"; return 1 ;; esac
  assert_not_contains "$calls" "ghp_FAKESECRET123" "269 AC6: no secret in the event" || return 1
}

# AC6: gh issue-read failure alerts too (existing path, with the same tags)
test_ar2_269_issue_read_failure_alerts_slack_with_tags() {
  ar2_fixture 'Blocked on: ci_red — x'
  cp "$SQ_GH/gh" "$SQ_GH/gh-ar2"
  printf '#!/bin/bash\nif [ "$1" = "api" ]; then echo "token=ghp_FAKESECRET123" >&2; exit 1; fi\nexec "$(dirname "$0")/gh-ar2" "$@"\n' > "$SQ_GH/gh"; chmod +x "$SQ_GH/gh"
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$SQ_GH" > "$SQ_GH/curl"; chmod +x "$SQ_GH/curl"
  ar2_tick
  local calls h; calls=$(grep 'hooks.slack.test' "$SQ_GH/curl.calls" 2>/dev/null); h=$(ar2_held)
  sq_cleanup
  assert_contains "$calls" "route=supervisor/auto-retry" "269 AC6: issue-read failure carries route tag" || return 1
  assert_not_contains "$calls" "ghp_FAKESECRET123" "269 AC6: no secret" || return 1
  assert_eq "$h" "present" "269: stays held" || return 1
}

# AC4 item 1: a run held for the monthly spend limit is never auto-retried, even with a cleared class-matching BLOCKED
test_ar2_269_monthly_spend_held_run_is_not_retried() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo pass > "$SQ_GH/gh-pr-checks"
  printf 'rate_limited monthly_spend\n' > "$(rkp "$SQ_PIPE/orch-42.exit-class")"
  printf '2026-10-15T00:00:00Z Pipeline #42 waiting on JP — monthly spend limit reached; relaunch after credits or a model switch\n' > "$(rkp "$SQ_PIPE/orch-42.alert")"
  ar2_tick
  local n c h calls; n=$(ar2_no_launch); c=$(ar2_counter); h=$(ar2_held); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "0" "269 item1: spend-held run not relaunched" || return 1
  assert_eq "$c" "ABSENT" "269 item1: no retry consumed" || return 1
  assert_eq "$h" "present" "269 item1: stays held" || return 1
  assert_not_contains "$calls" "auto-retry" "269 item1: no NOTE posted" || return 1
}

# AC4 item 2: every #N on a `Depends on` line counts
test_ar2_269_multi_dependency_line_one_open_not_cleared() {
  ar2_fixture 'Blocked on: dependency — waits'
  printf 'Why\nDepends on #77, #78 and #79\n' > "$SQ_GH/gh-issue-body-42"
  echo CLOSED > "$SQ_GH/gh-issue-state-77"; echo OPEN > "$SQ_GH/gh-issue-state-78"; echo CLOSED > "$SQ_GH/gh-issue-state-79"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "269 item2: #78 (2nd on the line) still open -> not cleared" || return 1
}

test_ar2_269_multi_dependency_last_one_open_not_cleared() {
  ar2_fixture 'Blocked on: dependency — waits'
  printf 'Depends on #77 and #78 for merging\n' > "$SQ_GH/gh-issue-body-42"
  echo CLOSED > "$SQ_GH/gh-issue-state-77"; echo OPEN > "$SQ_GH/gh-issue-state-78"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "269 item2: '#77 and #78 for merging' with #78 open -> not cleared" || return 1
}

test_ar2_269_multi_dependency_all_closed_cleared() {
  ar2_fixture 'Blocked on: dependency — waits'
  printf 'Why\nDepends on #77, #78 and #79\n' > "$SQ_GH/gh-issue-body-42"
  echo CLOSED > "$SQ_GH/gh-issue-state-77"; echo CLOSED > "$SQ_GH/gh-issue-state-78"; echo CLOSED > "$SQ_GH/gh-issue-state-79"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "269 item2: all three closed -> cleared, relaunched" || return 1
  assert_contains "$calls" "issue view 79" "269 item2: the 3rd dependency was actually checked" || return 1
}

# AC4 item 3: the auto-retry relaunch carries the run's saved .extra (observable in the launch prompt)
test_ar2_269_extra_carried_over_to_relaunch() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo pass > "$SQ_GH/gh-pr-checks"
  printf '%s' 'EXTRA-SENTINEL-269' > "$(rkp "$SQ_PIPE/orch-42.extra")"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(cat "$SQ_PIPE/claude.calls")
  sq_cleanup
  assert_eq "$n" "1" "269 item3 control: relaunched" || return 1
  assert_contains "$calls" "EXTRA-SENTINEL-269" "269 item3: saved extra reaches the relaunch prompt" || return 1
}

# AC4 item 4: local state shows no BLOCKED hold -> no `gh issue view` at all
test_ar2_269_non_blocked_alert_skips_issue_view() {
  ar2_fixture 'Blocked on: ci_red — decoy: older class-matching BLOCKED in thread'
  echo pass > "$SQ_GH/gh-pr-checks"
  printf '2026-10-15T00:00:00Z Pipeline #42 waiting on JP — **[infra-operator] AWAITING GO**; relaunch (or re-add agent-go) after acting\n' > "$(rkp "$SQ_PIPE/orch-42.alert")"
  ar2_tick
  local views n; views=$(grep -c '^issue view' "$SQ_GH/gh-calls.log" 2>/dev/null || true); n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "${views:-0}" "0" "269 item4: no gh issue view for a held JP gate" || return 1
  assert_eq "$n" "0" "269 item4: not relaunched" || return 1
}

test_ar2_269_blocked_alert_still_reads_issue_and_retries() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo pass > "$SQ_GH/gh-pr-checks"
  printf '2026-10-15T00:00:00Z Pipeline #42 waiting on JP — **[fullstack-developer] BLOCKED**; relaunch (or re-add agent-go) after acting\n' > "$(rkp "$SQ_PIPE/orch-42.alert")"
  ar2_tick
  local n views; n=$(ar2_launches); views=$(grep -c '^issue view' "$SQ_GH/gh-calls.log" 2>/dev/null || true)
  sq_cleanup
  assert_eq "$n" "1" "269 item4 control: a BLOCKED hold is still retried" || return 1
  [ "${views:-0}" -ge 1 ] || { fail "269 item4 control: BLOCKED hold must read the issue"; return 1; }
}

# ---- #293: a held run with no .autoretry file reads the counter silently ------------------------------------------
test_ar2_293_missing_autoretry_file_no_stderr() {
  ar2_fixture 'Blocked on: ci_pending — checks running'
  echo pending > "$SQ_GH/gh-pr-checks"
  rm -f "$(rkp "$SQ_PIPE/orch-42.autoretry")"
  sq_run "$SUP_SQ" >/dev/null 2>"$SQ_PIPE/tick.stderr"
  local err stamp=no; err=$(grep -c 'autoretry: No such file' "$SQ_PIPE/tick.stderr" 2>/dev/null || true)
  [ -e "$(rkp "$SQ_PIPE/orch-42.autoretry-check")" ] && stamp=yes
  sq_cleanup
  assert_eq "${err:-0}" "0" "293: no 'No such file' stderr for a missing .autoretry" || return 1
  assert_eq "$stamp" "yes" "293: loop reaches the throttle stamp" || return 1
}

run_test test_ar2_269_note_posted_before_queue_file_written
run_test test_ar2_269_failed_note_post_does_not_requeue
run_test test_ar2_269_comment_failure_alerts_slack_with_tags
run_test test_ar2_269_issue_read_failure_alerts_slack_with_tags
run_test test_ar2_269_monthly_spend_held_run_is_not_retried
run_test test_ar2_269_multi_dependency_line_one_open_not_cleared
run_test test_ar2_269_multi_dependency_last_one_open_not_cleared
run_test test_ar2_269_multi_dependency_all_closed_cleared
run_test test_ar2_269_extra_carried_over_to_relaunch
run_test test_ar2_269_non_blocked_alert_skips_issue_view
run_test test_ar2_269_blocked_alert_still_reads_issue_and_retries
run_test test_ar2_293_missing_autoretry_file_no_stderr
