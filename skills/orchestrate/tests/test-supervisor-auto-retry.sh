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
  "pr "*|"issue view")
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
    list) emit "[{\"number\":7,\"state\":\"OPEN\",\"headRefName\":\"issue-42-x\",\"mergeable\":\"$mg\"}]" ;;
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
# issue view
n=$(printf '%s' "$*" | sed -n 's/.*issue view \([0-9][0-9]*\).*/\1/p')
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
  printf 'BLOCKED\n' > "$SQ_PIPE/orch-42.marker"
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
ar2_counter() { if [ -f "$SQ_PIPE/orch-42.autoretry" ]; then head -n1 "$SQ_PIPE/orch-42.autoretry" | tr -d ' \n'; else echo ABSENT; fi; }
ar2_held() { sq_present "$SQ_PIPE/orch-42.held"; }

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
  echo 2 > "$SQ_PIPE/orch-42.autoretry"
  ar2_tick
  local n c calls; n=$(ar2_launches); c=$(ar2_counter); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "counter 2 -> the 3rd retry still fires" || return 1
  assert_eq "$c" "3" "counter = 3" || return 1
  assert_contains "$calls" "auto-retry 3/3: ci_red cleared" "NOTE says 3/3" || return 1
}

test_ar2_fourth_retry_never_fires() {
  ar2_fixture 'Blocked on: ci_red — x'
  echo 3 > "$SQ_PIPE/orch-42.autoretry"
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
    case "$f" in orch-42.*) printf '%s\n' "$before" | grep -qx "$f" && continue
      touch -t "$(date -v-31M +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 minutes ago' +%Y%m%d%H%M.%S)" "$SQ_PIPE/$f"
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
