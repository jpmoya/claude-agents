# Tests for claude-agents#129 — the supervisor holds (not restarts) a run that handed a passed PR to JP
# (post-PASS hand-to-JP exit, incl. merge-gate wait) and logged a validate stage "hand-to-jp" result "fail".
#
#   supervisor  hand-to-jp fail (this run, this issue, gate marker code-reviewer PASS) -> held
#               controls: stale line, other issue, PASS marker with no line -> restart
#   observ.     the hold posts through the existing Slack notify (no new webhook), payload has no secrets
#   doc pins    orchestrator.md: hand-to-jp log line, Run log list, :65/:385 merged rule, merge-gate exit (inverted by #304)
# Prefixed i129_ (all test files share one shell). Placeholder repos only.

HERE_I129=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_I129=$(cd "$HERE_I129/../../.." && pwd)
I129_PASS='**[code-reviewer] PASS**'

if ! declare -f sq_env >/dev/null 2>&1; then
  eval "i129_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I129/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f i129_real_run_test | sed '1s/i129_real_run_test/run_test/')"
fi

# i129_run <secs-ago|none> <issue-in-line> [reason] [slack] — run launched 600 s ago; one hand-to-jp validate fail
# line (omitted when secs-ago is "none"); gate marker is code-reviewer PASS; ticks once.
# Sets I129_LOG / I129_HELD / I129_QUEUED / I129_PAYLOAD.
i129_run() {
  local ago="$1" line_issue="$2" reason="${3:-both PASSes; PR base is main on the quoting tool, handed to JP}" slack="${4:-}"
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  if [ -n "${I129_LAUNCH:-}" ]; then printf '%s\n' "$I129_LAUNCH" > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  else sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"; fi
  sq_marker "$I129_PASS"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  if [ "$ago" != none ]; then
    printf '{"ts":"%s","host":"h","event":"validate","repo":"project-a/repo-a","issue":%s,"stage":"hand-to-jp","result":"fail","reason":"%s"}\n' \
      "${I129_TS:-$(sq_iso_ago "$ago")}" "$line_issue" "$reason" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
  fi
  if [ -n "$slack" ]; then
    # fake curl: save the -d payload, answer ok
    cat > "$SQ_GH/curl" <<'CURL'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = -d ] && printf '%s' "$2" > "$(dirname "$0")/slack-payload"; shift; done
echo '{"ok":true}'
CURL
    chmod +x "$SQ_GH/curl"
    HOME="$SQ_HOME" PATH="$SQ_GH:/usr/bin:/bin" PIPE="$SQ_PIPE" QUEUE="$SQ_PIPE/queue" LOGDIR="$SQ_HOME/logs/pipeline" \
      SLACK_BOT_TOKEN="fake-credential-for-tests-only" SLACK_ENGINEERING_CHANNEL="C0TEST" "$SUP_SQ" >/dev/null 2>&1
    I129_PAYLOAD=$(cat "$SQ_GH/slack-payload" 2>/dev/null)
  else
    sq_tick
  fi
  I129_LOG=$(sq_log)
  I129_HELD=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")")
  I129_QUEUED=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")")
  sq_cleanup
}

i129_assert_held() {
  assert_eq "$I129_HELD" "present" "#129: .held created" || return 1
  assert_contains "$I129_LOG" "[held] #42" "#129: [held] logged" || return 1
  assert_not_contains "$I129_LOG" "[queue-restart] #42" "#129: no [queue-restart]" || return 1
  assert_eq "$I129_QUEUED" "absent" "#129: no queue entry" || return 1
}

i129_assert_restarted() {
  assert_contains "$I129_LOG" "[queue-restart] #42" "#129: restart path" || return 1
  assert_not_contains "$I129_LOG" "[held] #42" "#129: not held" || return 1
  assert_eq "$I129_HELD" "absent" "#129: no .held" || return 1
  assert_eq "$I129_QUEUED" "present" "#129: queue entry written" || return 1
}

test_i129_hand_to_jp_fail_holds() {
  i129_run 60 42
  i129_assert_held
}

# #304 (inverted from #129): a merge-gate wait after PASS is NOT a hand-to-jp exit. The deployer owns the gate and
# posts BLOCKED "Blocked on: dependency"; the orchestrator rule must not tell it to log a merge-gate hand-to-jp row.
test_i129_merge_gate_wait_holds() {
  local f="$ROOT_I129/agents/orchestrator.md" row
  row=$(grep -F 'One post-PASS hand-to-JP rule' "$f" | head -1)
  [ -n "$row" ] || { fail "orchestrator.md: post-PASS hand-to-JP rule row missing"; return 1; }
  assert_not_contains "$row" "merge gate:" "#304: hand-to-jp reason template has no merge-gate reason" || return 1
  assert_not_contains "$row" "merge-gate wait" "#304: merge-gate wait is not an exit of the hand-to-jp rule" || return 1
  assert_not_contains "$row" "Depends on #N for merging" "#304: hand-to-jp rule does not read the merge-gate line" || return 1
}

test_i129_stale_hand_to_jp_fail_restarts() {
  i129_run 4200 42   # an hour before .launched-at (600 s ago)
  i129_assert_restarted
}

# ts >= .launched-at boundary: both stamps from one python call (no second-tick drift)
i129_boundary() {  # i129_boundary <offset secs of line ts vs launched-at>
  local pair
  pair=$(python3 -c "import datetime,sys; n=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=600); f='%Y-%m-%dT%H:%M:%SZ'; print(n.strftime(f), (n+datetime.timedelta(seconds=int(sys.argv[1]))).strftime(f))" "$1")
  I129_LAUNCH=${pair% *} I129_TS=${pair#* } i129_run 0 42
}

test_i129_hand_to_jp_ts_equal_launched_at_holds() {
  i129_boundary 0     # ts == .launched-at counts as "this run" (>=)
  i129_assert_held
}

test_i129_hand_to_jp_ts_one_second_before_launched_at_restarts() {
  i129_boundary -1    # 1 s before .launched-at is the previous run
  i129_assert_restarted
}

test_i129_other_issue_hand_to_jp_fail_restarts() {
  i129_run 60 99
  i129_assert_restarted
}

test_i129_pass_marker_without_line_restarts() {
  i129_run none 42
  i129_assert_restarted
}

# terminal_kind unchanged: PASS still returns "" (detached-deployer restart keeps working)
test_i129_terminal_kind_pass_still_empty() {
  local out
  out=$(awk '/^terminal_kind\(\)/{f=1} f{print} f&&/^}/{exit}' "$ROOT_I129/skills/orchestrate/supervisor.sh")
  assert_not_contains "$out" "hand-to-jp" "#129: terminal_kind does not know hand-to-jp" || return 1
}

# Observability: hold goes out through the existing Slack notify; payload = issue number + stage, no secrets
test_i129_hold_posts_existing_slack_notify() {
  i129_run 60 42 "both PASSes; handed to JP" slack
  i129_assert_held || return 1
  assert_contains "$I129_PAYLOAD" "#42" "#129: Slack payload names the issue" || return 1
  assert_contains "$I129_PAYLOAD" "hand-to-jp" "#129: Slack payload names the stage" || return 1
  assert_not_contains "$I129_PAYLOAD" "fake-credential-for-tests-only" "#129: no token in payload" || return 1
  assert_contains "$I129_LOG" "[slack] #42 — posted to engineering" "#129: existing notify path used" || return 1
}

test_i129_hold_path_tags_route() {
  local sup="$ROOT_I129/skills/orchestrate/supervisor.sh"
  grep -qF 'supervisor/hold/hand-to-jp' "$sup" || { fail "supervisor.sh: missing route tag supervisor/hold/hand-to-jp"; return 1; }
}

# ---- doc pins ----
i129_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }

test_i129_supervisor_stage_tuple() {
  i129_has "$ROOT_I129/skills/orchestrate/supervisor.sh" '("structural", "delegated-decision", "loop-cap", "hand-to-jp")' || return 1
}

test_i129_orchestrator_logs_hand_to_jp_before_terminal() {
  local f="$ROOT_I129/agents/orchestrator.md" ln_stage ln_term
  i129_has "$f" '"stage":"hand-to-jp","result":"fail"' || return 1
  # the instruction sits in the routing-table :65 rule (the one rule defining every post-PASS hand-to-JP exit)
  local row before_log
  row=$(grep -F 'One post-PASS hand-to-JP rule' "$f" | head -1)
  [ -n "$row" ] || { fail "orchestrator.md: no routing-table row defines the post-PASS hand-to-JP rule"; return 1; }
  assert_contains "$row" '"stage":"hand-to-jp","result":"fail"' "#129: the rule row carries the log line" || return 1
  # ordering: the "Before the `terminal` event ... first log_run" sentence precedes the log_run literal
  before_log=${row%%log_run*}
  assert_contains "$before_log" 'Before the `terminal` event' "#129: log line is specified as logged before the terminal event" || return 1
  # every exit kind is inside that same rule
  assert_not_contains "$row" "merge-gate wait" "#304: merge-gate wait is no longer an exit of the rule" || return 1
  assert_contains "$row" "unsupported project" "#129: unsupported project is an exit of the rule" || return 1
}

test_i129_run_log_lists_hand_to_jp() {
  local sec
  sec=$(awk '/^## Run log/{f=1;next} /^## /{f=0} f' "$ROOT_I129/agents/orchestrator.md")
  assert_contains "$sec" '"stage":"hand-to-jp","result":"fail"' "#129: Run log lists hand-to-jp" || return 1
  assert_contains "$sec" '"stage":"delegated-decision","result":"fail"' "#129: delegated-decision still listed" || return 1
  assert_contains "$sec" '"stage":"loop-cap","result":"fail"' "#129: loop-cap still listed" || return 1
}

# :65 deployer row carries the main-base exception; :385 "Otherwise, hand to JP" no longer a separate rule
test_i129_deployer_row_names_main_base_exception() {
  local row
  row=$(grep -F 'Dispatch the deployer (the repo-local' "$ROOT_I129/agents/orchestrator.md" | head -1)
  assert_contains "$row" "hand-to-jp" "#129: row names the hand-to-jp log line (exception rule lives in this row)" || return 1
  assert_contains "$row" 'base is `main`' "#129: row names main as the PR base for the exception" || return 1
  assert_contains "$row" "quoting tool" "#129: row names the scheduler/quoting-tool main-base exception" || return 1
  assert_contains "$row" "to JP directly" "#129: handed to JP directly, no deployer dispatch" || return 1
}

# one rule: no free-standing second "Otherwise, hand to JP" rule left in the post-PASS exit text
test_i129_no_second_hand_to_jp_rule() {
  local f="$ROOT_I129/agents/orchestrator.md" n
  n=$(grep -ciE 'otherwise,? (hand|report)[^.]*to JP' "$f")
  assert_eq "$n" "0" "#129: no free-standing 'Otherwise, hand to JP' rule" || return 1
  local exits
  exits=$(grep -F 'The only exits are:' "$f")
  assert_contains "$exits" '`hand-to-jp`' "#129: exit list names hand-to-jp" || return 1
  assert_contains "$exits" '`:65`' "#129: exit list points at the :65 rule instead of restating it" || return 1
}

test_i129_orchestrator_lists_merge_gate_wait_as_hand_to_jp_exit() {
  local f="$ROOT_I129/agents/orchestrator.md"
  # #304: inverted — no line may list the merge-gate wait as a hand-to-jp exit
  if grep -iE 'merge.gate|Depends on #N for merging' "$f" | grep -qF 'hand-to-jp'; then
    fail "orchestrator.md: a line still lists the merge-gate wait as a hand-to-jp exit"; return 1
  fi
  if grep -iE 'merge.gate wait' "$f" | grep -qiE 'hand(ed)?[ -]to[ -]JP'; then
    fail "orchestrator.md: merge-gate wait still handed to JP"; return 1
  fi
}

run_test test_i129_hand_to_jp_fail_holds
run_test test_i129_merge_gate_wait_holds
run_test test_i129_stale_hand_to_jp_fail_restarts
run_test test_i129_hand_to_jp_ts_equal_launched_at_holds
run_test test_i129_hand_to_jp_ts_one_second_before_launched_at_restarts
run_test test_i129_other_issue_hand_to_jp_fail_restarts
run_test test_i129_pass_marker_without_line_restarts
run_test test_i129_terminal_kind_pass_still_empty
run_test test_i129_hold_posts_existing_slack_notify
run_test test_i129_hold_path_tags_route
run_test test_i129_supervisor_stage_tuple
run_test test_i129_orchestrator_logs_hand_to_jp_before_terminal
run_test test_i129_run_log_lists_hand_to_jp
run_test test_i129_deployer_row_names_main_base_exception
run_test test_i129_no_second_hand_to_jp_rule
run_test test_i129_orchestrator_lists_merge_gate_wait_as_hand_to_jp_exit
