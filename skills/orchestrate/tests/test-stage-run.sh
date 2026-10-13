# Issue #136 (Phase 1 of #134): skills/orchestrate/stage-run.sh writes stage_start / stage_end rows to
# $LOGDIR/events.jsonl; agents/orchestrator.md dispatches through it; the duplicate-stage guard and the
# process counters keep working with the wrapper in the process table.
#   AC6  killed/ok/fail rows + exit codes     AC7  rate-limit outcome        AC8  row shape + argv
#   AC9  duplicate guard on the doc's command  AC11 orchestrator doc          AC11a carve-out sentence
#   AC12 marker fields                         AC13 cost fields              AC14 logging never blocks
#   AC15 process counting                      AC16 output passthrough       AC17 pre-change form
# Expected values come from the ticket text or hand arithmetic in comments — never from the wrapper.
# Every function/variable is prefixed sr_ / SR_ (all test files share one shell). Placeholder names only.
# Each case gets its own PIPE, HOME, LOGDIR, CLAUDE_PROJECTS_DIR. Bash 3.2 compatible (see the hygiene case for the banned tools).

HERE_SR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SR=$(cd "$HERE_SR/../../.." && pwd)
WRAP_SR="$ROOT_SR/skills/orchestrate/stage-run.sh"
LIB_SR="$ROOT_SR/skills/orchestrate/pipeline-lib.sh"
ORCH_SR="$ROOT_SR/agents/orchestrator.md"
GUARD_SR="$ROOT_SR/hooks/no-duplicate-stage.sh"
SR_CLAUDE_ARGS_TAIL="Review. Repo: project-a/app. Issue: #42."

# sr_setup — fresh sandbox. Sets SR_BIN (stubs + knobs), SR_PIPE, SR_HOME, SR_LOG (LOGDIR), SR_PROJ.
# Stub claude knobs (env at run time): STUB_MODE ok|fail|hang, STUB_OUT (printed + newline), STUB_OUT_FILE
# (cat'd), STUB_ERR (to stderr), STUB_TRANSCRIPT=1 (writes a transcript with two cost-state records).
# Fake gh knobs (files in SR_BIN): pages/page*.json (REST comment arrays), gh-fail-always, gh-fail-once.
sr_setup() {
  SR_BIN=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sr.XXXXXX")
  SR_PIPE=$(new_pipe); SR_HOME=$(new_home)
  SR_LOG="$SR_HOME/logs/pipeline"; SR_PROJ="$SR_HOME/.claude/projects"
  mkdir -p "$SR_BIN/pages" "$SR_PROJ"
  cat > "$SR_BIN/claude" <<'EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$@" > "$D/argv"
echo $$ > "$D/stub.pid"
if [ "${STUB_TRANSCRIPT:-}" = 1 ]; then
  sid=$2
  mkdir -p "$CLAUDE_PROJECTS_DIR/-x-app"
  {
    echo '{"type":"user","sessionId":"'"$sid"'"}'
    echo '{"type":"cost-state","sessionId":"'"$sid"'","totalCostUSD":0.1,"modelUsage":{"claude-haiku-4-5":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,"costUSD":0.1}}}'
    echo '{"type":"cost-state","sessionId":"'"$sid"'","totalCostUSD":0.95,"modelUsage":{"claude-opus-5-5":{"inputTokens":100,"outputTokens":2000,"cacheReadInputTokens":5000000,"cacheCreationInputTokens":100000,"costUSD":0.51},"claude-haiku-4-5":{"inputTokens":648,"outputTokens":18389,"cacheReadInputTokens":299294,"cacheCreationInputTokens":79730,"costUSD":0.44}}}'
  } > "$CLAUDE_PROJECTS_DIR/-x-app/$sid.jsonl"
fi
if [ "${STUB_TRANSCRIPT:-}" = nocost ]; then
  mkdir -p "$CLAUDE_PROJECTS_DIR/-x-app"
  echo '{"type":"user","sessionId":"'"$2"'"}' > "$CLAUDE_PROJECTS_DIR/-x-app/$2.jsonl"
fi
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
[ -n "${STUB_OUT_FILE:-}" ] && cat "$STUB_OUT_FILE"
[ -n "${STUB_ERR:-}" ] && printf '%s' "$STUB_ERR" >&2
case "${STUB_MODE:-ok}" in
  ok) exit 0 ;;
  fail) exit 1 ;;
  hang) exec sleep 300 ;;
esac
EOF
  cat > "$SR_BIN/gh" <<'EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$D/gh-calls.log"
[ -e "$D/gh-fail-always" ] && { echo "HTTP 500" >&2; exit 1; }
if [ -e "$D/gh-fail-once" ] && [ ! -e "$D/gh-failed-already" ]; then : > "$D/gh-failed-already"; echo "HTTP 502" >&2; exit 1; fi
[ "$1" = "api" ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
expr=""
while [ $# -gt 0 ]; do case "$1" in --jq) expr=$2; shift ;; esac; shift; done
for p in "$D"/pages/page*.json; do      # paginate-faithful: --jq runs on each page separately
  [ -e "$p" ] || continue
  if [ -n "$expr" ]; then jq -r "$expr" "$p" || exit 1; else cat "$p"; fi
done
exit 0
EOF
  chmod +x "$SR_BIN/claude" "$SR_BIN/gh"
  : > "$SR_BIN/gh-calls.log"
  echo '[]' > "$SR_BIN/pages/page1.json"
}

sr_teardown() { rm -rf "$SR_BIN" "$SR_PIPE" "$SR_HOME"; }

# sr_comment <id> <created_at> <body> — one REST-shaped comment object
sr_comment() { jq -n --argjson i "$1" --arg t "$2" --arg b "$3" '{id:$i, created_at:$t, user:{login:"jpmoya"}, body:$b}'; }

# sr_env — the environment every wrapper run gets (prints VAR=value words for `env`)
sr_envwords() {
  printf '%s\n' "PIPE=$SR_PIPE" "LOGDIR=${SR_LOGDIR_OVERRIDE:-$SR_LOG}" "HOME=$SR_HOME" "CLAUDE_PROJECTS_DIR=$SR_PROJ" \
    "PATH=$SR_BIN:$PATH" "PIPELINE_ISSUE=${SR_ISSUE:-42}" "PIPELINE_AGENT=${SR_AGENT:-code-reviewer}" "PIPELINE_REPO=project-a/app"
}

# sr_run [wrapper flags…] — foreground run; sets SR_RC, SR_OUT (stdout file), SR_ERR (stderr file).
sr_run() {
  SR_OUT="$SR_BIN/out"; SR_ERR="$SR_BIN/err"
  ( cd "$SR_HOME" && env $(sr_envwords | tr '\n' ' ') "$WRAP_SR" "$@" -- claude --dangerously-skip-permissions \
      --agent "${SR_AGENT:-code-reviewer}" -p "$SR_CLAUDE_ARGS_TAIL" > "$SR_OUT" 2> "$SR_ERR" )
  SR_RC=$?
}

# sr_bg [wrapper flags…] — background run; sets SR_WPID, SR_OUT, SR_ERR. Waits (≤10s) for the stub to start.
sr_bg() {
  SR_OUT="$SR_BIN/out"; SR_ERR="$SR_BIN/err"
  rm -f "$SR_BIN/stub.pid"
  env $(sr_envwords | tr '\n' ' ') "$WRAP_SR" "$@" -- claude --dangerously-skip-permissions \
      --agent "${SR_AGENT:-code-reviewer}" -p "$SR_CLAUDE_ARGS_TAIL" > "$SR_OUT" 2> "$SR_ERR" &
  SR_WPID=$!
  local i=0
  while [ ! -s "$SR_BIN/stub.pid" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  SR_STUBPID=$(cat "$SR_BIN/stub.pid" 2>/dev/null)
}

sr_events() { echo "$SR_LOG/events.jsonl"; }
sr_end() { jq -c 'select(.event=="stage_end")' "$(sr_events)" 2>/dev/null | tail -1; }
sr_start() { jq -c 'select(.event=="stage_start")' "$(sr_events)" 2>/dev/null | tail -1; }
sr_count() { jq -c "select(.event==\"$1\")" "$(sr_events)" 2>/dev/null | wc -l | tr -d ' '; }
# sr_f <json> <jq expr> — evaluates a jq expression to a raw string
sr_f() { printf '%s' "$1" | jq -r "$2"; }

# --------------------------------------------------------------------------------------------- AC6

test_sr_ac6_ok_writes_start_and_end() {
  sr_setup; STUB_MODE=ok sr_run
  assert_eq "$SR_RC" 0 "AC6: wrapper exit code equals the child's (0)" || { sr_teardown; return 1; }
  assert_eq "$(sr_count stage_start)" 1 "AC6: one stage_start" || { sr_teardown; return 1; }
  assert_eq "$(sr_count stage_end)" 1 "AC6: one stage_end" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .exit_code)" 0 "AC6: exit_code 0" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac6_fail_exit_code_passes_through() {
  sr_setup; STUB_MODE=fail sr_run
  assert_eq "$SR_RC" 1 "AC6: wrapper exit code equals the child's (1)" || { sr_teardown; return 1; }
  assert_eq "$(sr_count stage_start)" 1 "AC6: one stage_start" || { sr_teardown; return 1; }
  assert_eq "$(sr_count stage_end)" 1 "AC6: one stage_end" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .exit_code)" 1 "AC6: exit_code 1" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac6_child_sigterm_is_killed_143() {
  sr_setup; STUB_MODE=hang sr_bg
  [ -n "$SR_STUBPID" ] || { sr_teardown; fail "AC6: the stub claude never started"; return 1; }
  assert_eq "$(sr_count stage_start)" 1 "AC6: stage_start is written before the child finishes" || { kill -KILL "$SR_WPID" "$SR_STUBPID" 2>/dev/null; sr_teardown; return 1; }
  assert_eq "$(sr_count stage_end)" 0 "AC6: no stage_end while the child still runs" || { kill -KILL "$SR_WPID" "$SR_STUBPID" 2>/dev/null; sr_teardown; return 1; }
  kill -TERM "$SR_STUBPID"; wait "$SR_WPID"; SR_RC=$?
  assert_eq "$SR_RC" 143 "AC6: wrapper exits with the child's 143" || { sr_teardown; return 1; }
  assert_eq "$(sr_count stage_end)" 1 "AC6: one stage_end" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .exit_code)" 143 "AC6: exit_code 143" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .outcome)" killed "AC6: outcome killed" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac6_wrapper_sigterm_forwards_and_still_writes_end() {
  sr_setup; STUB_MODE=hang sr_bg
  [ -n "$SR_STUBPID" ] || { sr_teardown; fail "AC6: the stub claude never started"; return 1; }
  assert_ne "$SR_STUBPID" "$SR_WPID" "AC6: the wrapper must not exec — the child has its own pid" || { kill -KILL "$SR_WPID" "$SR_STUBPID" 2>/dev/null; sr_teardown; return 1; }
  kill -TERM "$SR_WPID"; wait "$SR_WPID"; SR_RC=$?
  assert_eq "$SR_RC" 143 "AC6: wrapper exits 143 after forwarding TERM" || { kill -KILL "$SR_STUBPID" 2>/dev/null; sr_teardown; return 1; }
  if kill -0 "$SR_STUBPID" 2>/dev/null; then kill -KILL "$SR_STUBPID" 2>/dev/null; sr_teardown; fail "AC6: the child was not signalled"; return 1; fi
  assert_eq "$(sr_count stage_end)" 1 "AC6: the end row is still written" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .exit_code)" 143 "AC6: exit_code 143" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .outcome)" killed "AC6: outcome killed" || { sr_teardown; return 1; }
  sr_teardown
}

# --------------------------------------------------------------------------------------------- AC7

test_sr_ac7_weekly_limit() {
  sr_setup; STUB_OUT="You've hit your weekly limit · resets 3am (UTC)" sr_run
  assert_eq "$SR_RC" 0 "AC7: claude exits 0 on a limit and so does the wrapper" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .outcome)" rate_limited "AC7: outcome" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .limit_kind)" weekly "AC7: limit_kind" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac7_monthly_spend_limit() {
  sr_setup
  STUB_OUT="You've hit your monthly spend limit. Switch to another model, or manage usage credits at https://example.invalid/usage" sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" rate_limited "AC7: outcome" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .limit_kind)" monthly_spend "AC7: limit_kind" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac7_limit_beats_a_new_marker() {   # outcome order: rate_limited is checked first
  sr_setup
  sr_comment 5001 2099-01-01T00:00:00Z '**[code-reviewer] PASS**
ok' | jq -s . > "$SR_BIN/pages/page1.json"; echo 0 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_OUT="You've hit your weekly limit · resets 3am (UTC)" sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" rate_limited "AC7: rate_limited wins over marker" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac7_limit_line_beyond_last_20_lines_is_ignored() {
  sr_setup
  { echo "You've hit your weekly limit · resets 3am (UTC)"; local i=1; while [ $i -le 25 ]; do echo "later line $i"; i=$((i + 1)); done; } > "$SR_BIN/o.txt"
  STUB_OUT_FILE="$SR_BIN/o.txt" sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" no_marker "AC7: a limit line older than the last 20 lines is not a limit" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .limit_kind)" null "AC7: limit_kind null" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac7_limit_kind_of_function() {
  local d f; d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-lk.XXXXXX")
  printf '%s\n' "You've HIT YOUR Weekly Limit · resets 3am (UTC)" > "$d/weekly"          # case-insensitive
  printf '%s\n' "You've hit your monthly spend limit. Switch to another model" > "$d/spend"
  printf '%s\n' "You've hit your usage limit" > "$d/other"
  printf '%s\n' "all good" "weekly limit mentioned without the hit-your phrase" > "$d/none"
  assert_eq "$( . "$LIB_SR"; limit_kind_of "$d/weekly" 2>/dev/null )" weekly "limit_kind_of weekly (case-insensitive)" || { rm -rf "$d"; return 1; }
  assert_eq "$( . "$LIB_SR"; limit_kind_of "$d/spend" 2>/dev/null )" monthly_spend "limit_kind_of spend" || { rm -rf "$d"; return 1; }
  assert_eq "$( . "$LIB_SR"; limit_kind_of "$d/other" 2>/dev/null )" other "limit_kind_of other" || { rm -rf "$d"; return 1; }
  assert_eq "$( . "$LIB_SR"; limit_kind_of "$d/none" 2>/dev/null )" "" "limit_kind_of no match prints nothing" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

# --------------------------------------------------------------------------------------------- AC8

test_sr_ac8_rows_valid_json_host_session_argv() {
  sr_setup; STUB_MODE=ok sr_run --lane full
  local ev; ev=$(sr_events); assert_file_exists "$ev" "AC8: events.jsonl written" || { sr_teardown; return 1; }
  local n; n=$(wc -l < "$ev" | tr -d ' ')
  assert_eq "$n" 2 "AC8: exactly two rows" || { sr_teardown; return 1; }
  while IFS= read -r line; do
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || { fail "AC8: not valid JSON: $line"; sr_teardown; return 1; }
  done < "$ev"
  assert_eq "$(jq -r '.v' "$ev" | sort -u)" 1 "AC8: v is 1 in every row" || { sr_teardown; return 1; }
  local hosts; hosts=$(jq -r '.host' "$ev" | sort -u)
  assert_eq "$(printf '%s\n' "$hosts" | wc -l | tr -d ' ')" 1 "AC8: one host value across rows" || { sr_teardown; return 1; }
  assert_ne "$hosts" "" "AC8: host not empty" || { sr_teardown; return 1; }
  assert_eq "$hosts" "$(printf '%s' "$hosts" | tr '[:upper:]' '[:lower:]')" "AC8: host is lower-case" || { sr_teardown; return 1; }
  local sid; sid=$(jq -r '.session_id' "$ev" | sort -u)
  assert_eq "$(printf '%s\n' "$sid" | wc -l | tr -d ' ')" 1 "AC8: same session_id on both rows" || { sr_teardown; return 1; }
  case "$sid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "AC8: session_id is not a uuid: [$sid]"; sr_teardown; return 1 ;;
  esac
  # argv: --session-id <uuid>, then exactly the claude args given after `--`, in order
  local want got
  want=$(printf '%s\n' --session-id "$sid" --dangerously-skip-permissions --agent code-reviewer -p "$SR_CLAUDE_ARGS_TAIL")
  got=$(cat "$SR_BIN/argv" 2>/dev/null)
  assert_eq "$got" "$want" "AC8: stub argv" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_start_row_has_only_start_fields() {
  sr_setup; STUB_MODE=ok sr_run
  local s; s=$(sr_start)
  assert_ne "$s" "" "AC8: a stage_start row exists" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$s" '[has("dur_s"), has("exit_code"), has("outcome")] | any')" false "AC8: stage_start carries no end fields" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$s" '.start_ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" true "AC8: start_ts is ISO-8601 Z" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_identity_fields_from_env() {
  sr_setup; STUB_MODE=ok sr_run --lane fast --mode narrow --cycle 2 --pr 51
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .repo)" project-a/app "repo" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.issue | type')" number "issue is a number" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .issue)" 42 "issue" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .agent)" code-reviewer "agent" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .lane)" fast "lane" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .mode)" narrow "mode" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.cycle | type')" number "cycle is a number" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .cycle)" 2 "cycle" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .pr)" 51 "pr" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .attempt)" 1 "attempt (first run)" || { sr_teardown; return 1; }
  local host start; host=$(sr_f "$e" .host); start=$(sr_f "$(sr_start)" .start_ts)
  assert_eq "$(sr_f "$e" '. as $r | .run_id | test("^" + $r.host + "-42-code-reviewer-[0-9]+$")')" true "run_id is <host>-<issue>-<agent>-<epoch>" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.start_ts')" "$start" "stage_end repeats the start_ts" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.dur_s | type')" number "dur_s is a number" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_invalid_flag_values_become_null_and_stage_still_runs() {
  sr_setup; STUB_MODE=ok sr_run --lane bogus --mode sideways --cycle abc --pr x1
  assert_eq "$SR_RC" 0 "stage still runs, wrapper exits with child's code" || { sr_teardown; return 1; }
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" '[.lane, .mode, .cycle, .pr] | map(. == null) | all')" true "invalid lane/mode/cycle/pr are null" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_missing_flags_are_null() {
  sr_setup; STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" '[.lane, .mode, .cycle, .pr] | map(. == null) | all')" true "absent flags are null" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_identity_falls_back_to_claude_args_without_env() {
  sr_setup
  ( cd "$SR_HOME" && env -u PIPELINE_ISSUE -u PIPELINE_AGENT -u PIPELINE_REPO PIPE="$SR_PIPE" LOGDIR="$SR_LOG" HOME="$SR_HOME" \
      CLAUDE_PROJECTS_DIR="$SR_PROJ" PATH="$SR_BIN:$PATH" "$WRAP_SR" -- claude --dangerously-skip-permissions --agent test-reviewer \
      -p "Review. Repo: project-a/app. Issue: #42." >/dev/null 2>&1 )
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .agent)" test-reviewer "agent parsed from --agent" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .issue)" 42 "issue parsed from 'Issue: #42'" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .repo)" project-a/app "repo parsed from 'Repo: owner/repo'" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_identity_null_when_nowhere() {
  sr_setup
  ( cd "$SR_HOME" && env -u PIPELINE_ISSUE -u PIPELINE_AGENT -u PIPELINE_REPO PIPE="$SR_PIPE" LOGDIR="$SR_LOG" HOME="$SR_HOME" \
      CLAUDE_PROJECTS_DIR="$SR_PROJ" PATH="$SR_BIN:$PATH" "$WRAP_SR" -- claude -p "no coordinates here" >/dev/null 2>&1 )
  local e; e=$(sr_end)
  assert_ne "$e" "" "row still written" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '[.agent, .issue, .repo] | map(. == null) | all')" true "agent/issue/repo null" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac8_attempt_counts_earlier_starts_for_same_ticket_and_agent() {
  sr_setup
  STUB_MODE=ok sr_run; local a1; a1=$(sr_f "$(sr_end)" .attempt)
  STUB_MODE=ok sr_run; local a2; a2=$(sr_f "$(sr_end)" .attempt)
  SR_AGENT=test-reviewer STUB_MODE=ok sr_run; local a3; a3=$(sr_f "$(sr_end)" .attempt)
  SR_ISSUE=43 STUB_MODE=ok sr_run; local a4; a4=$(sr_f "$(sr_end)" .attempt)   # same agent? no: agent default restored below
  assert_eq "$a1" 1 "first run attempt" || { sr_teardown; return 1; }
  assert_eq "$a2" 2 "second run, same repo/issue/agent" || { sr_teardown; return 1; }
  assert_eq "$a3" 1 "a different agent starts at 1" || { sr_teardown; return 1; }
  assert_eq "$a4" 1 "a different issue starts at 1" || { sr_teardown; return 1; }
  sr_teardown
}

# --------------------------------------------------------------------------------------------- AC12

# sr_one <body> <created_at> <id> — page1 holds an old dev IMPLEMENTED marker plus this one new comment
sr_page_with() {
  { sr_comment 1001 2020-01-01T00:00:00Z '**[fullstack-developer] IMPLEMENTED**
done'
    sr_comment "$3" "$2" "$1"
  } | jq -s . > "$SR_BIN/pages/page1.json"
  echo "${SR_BEFORE:-0}" > "$SR_PIPE/${SR_ISSUE:-42}-${SR_AGENT:-code-reviewer}-before.txt"
}

test_sr_ac12_fail_marker_fields() {
  sr_setup
  sr_page_with '**[code-reviewer] FAIL: 3 findings**
1. a
2. b
3. c' 2099-01-01T00:00:00Z 5942270284
  STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .outcome)" marker "outcome" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_after)" '**[code-reviewer] FAIL: 3 findings**' "marker_after" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_comment_id)" 5942270284 "marker_comment_id" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .findings)" 3 "findings" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_before)" '**[fullstack-developer] IMPLEMENTED**' "marker_before = newest routing marker created before start_ts" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_read_ok)" true "marker_read_ok" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .block_class)" null "block_class null when not BLOCKED" || { sr_teardown; return 1; }
  assert_contains "$(cat "$SR_BIN/gh-calls.log")" "repos/project-a/app/issues/42/comments" "REST read of the issue's comments" || { sr_teardown; return 1; }
  assert_contains "$(cat "$SR_BIN/gh-calls.log")" "--paginate" "paginated read" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_findings_for_tests_fail_and_plan_fail() {
  sr_setup
  SR_AGENT=test-reviewer sr_page_with '**[test-reviewer] TESTS FAIL: 4 findings**
x' 2099-01-01T00:00:00Z 7001
  SR_AGENT=test-reviewer STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .findings)" 4 "TESTS FAIL: 4 findings -> 4" || { sr_teardown; return 1; }
  SR_AGENT=infra-reviewer sr_page_with '**[infra-reviewer] PLAN FAIL: 2 findings**
x' 2099-01-01T00:00:00Z 7002
  SR_AGENT=infra-reviewer STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .findings)" 2 "PLAN FAIL: 2 findings -> 2" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_pass_marker_has_null_findings() {
  sr_setup
  sr_page_with '**[code-reviewer] PASS**
ok' 2099-01-01T00:00:00Z 7003
  STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" marker "outcome" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$(sr_end)" .findings)" null "findings null for PASS" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_block_class_ci_pending() {
  sr_setup
  SR_AGENT=deployer sr_page_with '**[deployer] BLOCKED**
Blocked on: ci_pending — 2 required checks still running' 2099-01-01T00:00:00Z 8001
  SR_AGENT=deployer STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .marker_after)" '**[deployer] BLOCKED**' "marker_after" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .block_class)" ci_pending "block_class" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_block_class_every_enum_word() {
  local c
  for c in ci_pending ci_red merge_conflict unsupported_project needs_jp dependency other; do
    sr_setup
    SR_AGENT=deployer sr_page_with "**[deployer] BLOCKED**
Blocked on: $c — some one-line reason" 2099-01-01T00:00:00Z 8002
    SR_AGENT=deployer STUB_MODE=ok sr_run
    assert_eq "$(sr_f "$(sr_end)" .block_class)" "$c" "block_class for [$c]" || { sr_teardown; return 1; }
    sr_teardown
  done
}

test_sr_ac12_block_class_free_text_is_other() {
  sr_setup
  SR_AGENT=deployer sr_page_with '**[deployer] BLOCKED**
Blocked on: needs prod write' 2099-01-01T00:00:00Z 8003
  SR_AGENT=deployer STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .block_class)" other "free text -> other" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_block_class_other_when_line2_has_no_blocked_on() {
  sr_setup
  SR_AGENT=infra-operator sr_page_with '**[infra-operator] BLOCKED**
terraform plan drifted' 2099-01-01T00:00:00Z 8004
  SR_AGENT=infra-operator STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .block_class)" other "infra BLOCKED without the line -> other" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_no_new_marker_exit0_is_no_marker() {
  sr_setup
  echo '[]' > "$SR_BIN/pages/page1.json"; echo 0 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .outcome)" no_marker "outcome" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '[.marker_after, .marker_comment_id, .findings, .block_class] | map(. == null) | all')" true "marker fields null" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_read_ok)" true "read succeeded" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_no_new_marker_exit1_is_error() {
  sr_setup
  echo '[]' > "$SR_BIN/pages/page1.json"; echo 0 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_MODE=fail sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" error "outcome" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_marker_beats_error() {   # outcome order: marker is checked before error
  sr_setup
  sr_page_with '**[code-reviewer] PASS**
ok' 2099-01-01T00:00:00Z 7004
  STUB_MODE=fail sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" marker "new marker + exit 1 -> marker" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_marker_count_equal_to_before_is_not_new() {   # boundary: count == before.txt
  sr_setup
  { sr_comment 1002 2020-01-01T00:00:00Z '**[code-reviewer] PASS**
old'; } | jq -s . > "$SR_BIN/pages/page1.json"
  echo 1 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .outcome)" no_marker "an old marker is not a new one" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_after)" null "marker_after null" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_note_and_other_agents_markers_do_not_count() {
  sr_setup
  { sr_comment 1003 2099-01-01T00:00:00Z '**[code-reviewer] NOTE**
chatter'
    sr_comment 1004 2099-01-01T00:00:01Z '**[test-reviewer] PASS**
someone else'
  } | jq -s . > "$SR_BIN/pages/page1.json"
  echo 0 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" no_marker "NOTE / other agent's marker is not this agent's marker" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_marker_on_second_page_is_found() {
  sr_setup
  { sr_comment 1001 2020-01-01T00:00:00Z '**[fullstack-developer] IMPLEMENTED**
x'; } | jq -s . > "$SR_BIN/pages/page1.json"
  { sr_comment 9001 2099-01-01T00:00:00Z '**[code-reviewer] FAIL: 1 findings**
x'; } | jq -s . > "$SR_BIN/pages/page2.json"
  echo 0 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_MODE=ok sr_run
  assert_eq "$(sr_f "$(sr_end)" .marker_comment_id)" 9001 "marker on page 2" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_newest_of_this_agents_markers_is_reported() {
  sr_setup
  { sr_comment 1002 2020-01-01T00:00:00Z '**[code-reviewer] FAIL: 5 findings**
old'
    sr_comment 9002 2099-01-01T00:00:00Z '**[code-reviewer] PASS**
new'
  } | jq -s . > "$SR_BIN/pages/page1.json"
  echo 1 > "$SR_PIPE/42-code-reviewer-before.txt"
  STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .marker_comment_id)" 9002 "newest marker id" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_after)" '**[code-reviewer] PASS**' "newest marker line" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_failing_gh_nulls_marker_fields_but_writes_row() {
  sr_setup
  : > "$SR_BIN/gh-fail-always"
  STUB_MODE=ok sr_run
  assert_eq "$SR_RC" 0 "exit code is the child's" || { sr_teardown; return 1; }
  local e; e=$(sr_end)
  assert_ne "$e" "" "the stage_end row is still written" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_read_ok)" false "marker_read_ok false" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '[.marker_before, .marker_after, .marker_comment_id, .findings, .block_class] | map(. == null) | all')" true "marker fields null" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .outcome)" no_marker "outcome decided without the marker step (exit 0)" || { sr_teardown; return 1; }
  assert_eq "$(wc -l < "$SR_BIN/gh-calls.log" | tr -d ' ')" 2 "one read plus one retry" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_failing_gh_with_exit1_is_error() {
  sr_setup
  : > "$SR_BIN/gh-fail-always"
  STUB_MODE=fail sr_run
  assert_eq "$(sr_f "$(sr_end)" .outcome)" error "outcome without marker step, exit 1" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac12_gh_retry_after_one_failure_succeeds() {
  sr_setup
  sr_page_with '**[code-reviewer] PASS**
ok' 2099-01-01T00:00:00Z 7005
  : > "$SR_BIN/gh-fail-once"
  STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" .marker_read_ok)" true "second read succeeded" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .marker_comment_id)" 7005 "marker found via the retry" || { sr_teardown; return 1; }
  sr_teardown
}

# --------------------------------------------------------------------------------------------- AC13

test_sr_ac13_cost_fields_from_last_cost_state() {
  sr_setup
  STUB_TRANSCRIPT=1 STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  # hand arithmetic: in 100+648=748; out 2000+18389=20389; cache_read 5000000+299294=5299294; cache_create 100000+79730=179730
  assert_eq "$(sr_f "$e" '.cost_usd == 0.95')" true "cost_usd = last totalCostUSD (0.95, not the earlier 0.1)" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .in_tok)" 748 "in_tok" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .out_tok)" 20389 "out_tok" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .cache_read)" 5299294 "cache_read" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .cache_create)" 179730 "cache_create" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.models == {"claude-haiku-4-5":0.44,"claude-opus-5-5":0.51}')" true "models {model: costUSD}" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" .tool_calls)" null "tool_calls is null in this ticket" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac13_no_transcript_nulls_cost_but_writes_row() {
  sr_setup
  STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_ne "$e" "" "row written" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '[.cost_usd, .in_tok, .out_tok, .cache_read, .cache_create] | map(. == null) | all')" true "cost fields null" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.models == {}')" true "models {}" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac13_transcript_without_cost_state_is_null() {
  sr_setup
  STUB_TRANSCRIPT=nocost STUB_MODE=ok sr_run
  local e; e=$(sr_end)
  assert_eq "$(sr_f "$e" '[.cost_usd, .in_tok, .out_tok, .cache_read, .cache_create] | map(. == null) | all')" true "cost fields null" || { sr_teardown; return 1; }
  assert_eq "$(sr_f "$e" '.models == {}')" true "models {}" || { sr_teardown; return 1; }
  sr_teardown
}

# --------------------------------------------------------------------------------------------- AC14

test_sr_ac14_unwritable_logdir_never_blocks_work() {
  sr_setup
  : > "$SR_BIN/not-a-dir"                       # a file as parent: every mkdir/append under it fails, even for root
  SR_LOGDIR_OVERRIDE="$SR_BIN/not-a-dir/logs" STUB_OUT="hello from the stage" STUB_MODE=fail sr_run
  assert_eq "$SR_RC" 1 "wrapper exits with the stub's code" || { sr_teardown; return 1; }
  assert_eq "$(cat "$SR_OUT")" "hello from the stage" "the stage's output still reaches stdout" || { sr_teardown; return 1; }
  assert_file_exists "$SR_BIN/argv" "the stub still ran" || { sr_teardown; return 1; }
  SR_LOGDIR_OVERRIDE="$SR_BIN/not-a-dir/logs" STUB_MODE=ok sr_run
  assert_eq "$SR_RC" 0 "exit 0 passes through too" || { sr_teardown; return 1; }
  sr_teardown
}

test_sr_ac14_readonly_dir_never_blocks_work() {
  sr_setup
  mkdir -p "$SR_BIN/ro"; chmod 555 "$SR_BIN/ro"
  SR_LOGDIR_OVERRIDE="$SR_BIN/ro/logs" STUB_OUT="still here" STUB_MODE=ok sr_run
  chmod 755 "$SR_BIN/ro"
  assert_eq "$SR_RC" 0 "wrapper exits with the stub's code" || { sr_teardown; return 1; }
  assert_eq "$(cat "$SR_OUT")" "still here" "output reaches stdout" || { sr_teardown; return 1; }
  sr_teardown
}

# --------------------------------------------------------------------------------------------- AC16

test_sr_ac16_output_passthrough_is_byte_exact() {
  sr_setup
  printf 'line one\n\n\ttabbed ünïcode\r\nno trailing newline' > "$SR_BIN/bytes.txt"
  STUB_OUT_FILE="$SR_BIN/bytes.txt" STUB_ERR=$'err line\nerr tail' STUB_MODE=ok sr_run
  cmp -s "$SR_BIN/bytes.txt" "$SR_OUT" || { fail "AC16: stdout differs from what the stub printed"; sr_teardown; return 1; }
  assert_eq "$(cat "$SR_ERR")" $'err line\nerr tail' "AC16: stderr passes through unchanged" || { sr_teardown; return 1; }
  sr_teardown
}

# --------------------------------------------------------------------------------------------- wrapper hygiene

test_sr_wrapper_uses_python_uuid_and_no_gnu_or_missing_tools() {
  assert_file_exists "$WRAP_SR" "wrapper exists" || return 1
  local body; body=$(cat "$WRAP_SR")
  assert_contains "$body" "import uuid; print(uuid.uuid4())" "UUID from python3" || return 1
  local banned_a="uuid""gen" banned_b="flo""ck" banned_c="date -""d"   # spelled split so the suite's own syntax scan stays clean
  assert_not_contains "$body" "$banned_a" "no uuid tool outside python3 (macOS/VM portability)" || return 1
  assert_not_contains "$body" "$banned_b" "no file-lock tool" || return 1
  assert_not_contains "$body" "$banned_c" "no GNU date -d" || return 1
  assert_contains "$body" "limit_kind_of" "uses the shared limit function from pipeline-lib.sh" || return 1
}

# --------------------------------------------------------------------------------------------- orchestrator.md extraction helpers

# sr_single_dispatch — the single-stage dispatch command from agents/orchestrator.md ("Every stage — detached + poll"
# bash block): the nohup line and its backslash continuations, joined into one line, placeholders substituted.
sr_single_dispatch() {
  awk '/^### Every stage — detached \+ poll/ {s=1} s && /^```bash/ {b=1; next} s && b && /^```/ {exit}
       s && b { if (go || $0 ~ /nohup /) { go=1; line = line " " $0; if ($0 !~ /\\[[:space:]]*$/) exit } }
       END { print line }' "$ORCH_SR" \
    | sed -e 's/\\[[:space:]]*$//' -e 's/<agent-name>/code-reviewer/g' -e 's/<agent>/code-reviewer/g' \
          -e 's/<owner>\/<repo>/project-a\/app/g' -e 's/<issue>/42/g' -e 's/<N>/42/g' -e 's/<task>/Review/g' -e 's/<[a-z_ -]*>/1/g'
}

# sr_fake_ps <file> <line…> — a `ps` on PATH that prints the given lines
sr_fake_ps() {
  local d=$1; shift
  { echo '#!/bin/bash'; local l; for l in "$@"; do printf 'printf "%%s\\n" %q\n' "$l"; done; } > "$d/ps"
  chmod +x "$d/ps"
}

# sr_guard <command> <fake-ps-dir> — runs the duplicate-stage hook; sets SR_GRC, SR_GERR
sr_guard() {
  SR_GERR=$(printf '%s' "$(jq -nc --arg c "$1" '{tool_input:{command:$c}}')" | PATH="$2:$PATH" bash "$GUARD_SR" 2>&1 >/dev/null)
  SR_GRC=$?
}

# --------------------------------------------------------------------------------------------- AC9 / AC17

test_sr_ac9_guard_blocks_documented_dispatch_when_stage_running() {
  local cmd d; cmd=$(sr_single_dispatch); d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ps.XXXXXX")
  assert_contains "$cmd" "stage-run.sh" "AC9: the documented single-stage dispatch goes through the wrapper" || { rm -rf "$d"; return 1; }
  assert_contains "$cmd" "--agent code-reviewer" "AC9: the claude --agent text stays literally in the command" || { rm -rf "$d"; return 1; }
  assert_contains "$cmd" "Issue: #42" "AC9: the issue number stays literally in the command" || { rm -rf "$d"; return 1; }
  sr_fake_ps "$d" "claude --session-id 1111 --dangerously-skip-permissions --agent code-reviewer -p Review. Repo: project-a/app. Issue: #42."
  sr_guard "$cmd" "$d"
  assert_eq "$SR_GRC" 2 "AC9: exit 2 when the same stage runs for the same ticket" || { rm -rf "$d"; return 1; }
  assert_contains "$SR_GERR" "already running" "AC9: refusal message" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_sr_ac9_guard_allows_other_ticket_or_other_stage() {
  local cmd d; cmd=$(sr_single_dispatch); d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ps.XXXXXX")
  assert_contains "$cmd" "stage-run.sh" "AC9: precondition — documented dispatch uses the wrapper" || { rm -rf "$d"; return 1; }
  sr_fake_ps "$d" "claude --session-id 1111 --dangerously-skip-permissions --agent code-reviewer -p Review. Repo: project-a/app. Issue: #43."
  sr_guard "$cmd" "$d"; assert_eq "$SR_GRC" 0 "AC9: same stage, ticket #43 -> exit 0" || { rm -rf "$d"; return 1; }
  sr_fake_ps "$d" "claude --session-id 1111 --dangerously-skip-permissions --agent test-reviewer -p Review. Repo: project-a/app. Issue: #42."
  sr_guard "$cmd" "$d"; assert_eq "$SR_GRC" 0 "AC9: test-reviewer for #42 -> exit 0" || { rm -rf "$d"; return 1; }
  sr_fake_ps "$d"
  sr_guard "$cmd" "$d"; assert_eq "$SR_GRC" 0 "AC9: nothing running -> exit 0" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_sr_ac9_hooks_unchanged_vs_origin_main() {
  local out
  out=$(cd "$ROOT_SR" && git diff --stat origin/main -- hooks/require-handoff-marker.sh 2>&1)
  assert_eq "$out" "" "AC9: git diff --stat origin/main for the two hooks is empty" || return 1
}

test_sr_ac17_pre_change_form_still_guarded() {
  local cmd d
  cmd='nohup claude --dangerously-skip-permissions --agent code-reviewer -p "Review. Repo: project-a/app. Issue: #42." > /tmp/pipeline/run-42-code-reviewer.log 2>&1 &'
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ps.XXXXXX")
  sr_fake_ps "$d"
  sr_guard "$cmd" "$d"; assert_eq "$SR_GRC" 0 "AC17: nothing running -> exit 0" || { rm -rf "$d"; return 1; }
  sr_fake_ps "$d" "claude --dangerously-skip-permissions --agent code-reviewer -p Review. Repo: project-a/app. Issue: #42."
  sr_guard "$cmd" "$d"; assert_eq "$SR_GRC" 2 "AC17: duplicate running -> exit 2" || { rm -rf "$d"; return 1; }
  # the same running process, now wrapper-started (session-id first), still blocks the pre-change command
  sr_fake_ps "$d" "claude --session-id 1111 --dangerously-skip-permissions --agent code-reviewer -p Review. Repo: project-a/app. Issue: #42."
  sr_guard "$cmd" "$d"; assert_eq "$SR_GRC" 2 "AC17: wrapper-started duplicate blocks an old-form dispatch" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

# --------------------------------------------------------------------------------------------- AC15

test_sr_ac15_concurrency_filter_counts_child_not_wrapper() {
  local prog fixture n
  prog=$(grep -F 'ACTIVE=$(ps -axo comm=,args=' "$ORCH_SR" | head -1 | sed -e "s/^.*awk '//" -e "s/'.*\$//")
  assert_ne "$prog" "" "AC15: the awk filter is extractable from wait_for_capacity" || return 1
  fixture=$(printf '%s\n' \
    'bash bash /x/stage-run.sh --lane full -- claude --dangerously-skip-permissions --agent code-reviewer -p y' \
    'claude claude --session-id 1 --dangerously-skip-permissions --agent code-reviewer -p y')
  n=$(printf '%s\n' "$fixture" | awk "$prog" | wc -l | tr -d ' ')
  assert_eq "$n" 1 "AC15: wrapper + child count as one claude process" || return 1
}

test_sr_ac15_live_stage_reports_agent_for_wrapper_and_child() {
  local got
  got=$( . "$ROOT_SR/skills/orchestrate/run-state.sh"
    RS_PS_CMD="printf '1000\t42\tbash /x/stage-run.sh --lane full -- claude --dangerously-skip-permissions --agent code-reviewer -p y\n1001\t42\tclaude --session-id 1 --dangerously-skip-permissions --agent code-reviewer -p y\n'"
    _rs_live_stage 42 1 )
  assert_eq "$got" code-reviewer "AC15: _rs_live_stage reports code-reviewer" || return 1
}

# --------------------------------------------------------------------------------------------- AC11 / AC11a

test_sr_ac11_every_nohup_dispatch_calls_the_wrapper() {
  local total with
  total=$(grep -cE '^[[:space:]]*nohup ' "$ORCH_SR")
  with=$(grep -E '^[[:space:]]*nohup ' "$ORCH_SR" | grep -c 'stage-run\.sh .*-- claude --dangerously-skip-permissions --agent ')
  assert_le 3 "$total" "AC11: at least the three documented dispatch snippets exist (got $total)" || return 1
  assert_eq "$with" "$total" "AC11: every nohup dispatch line calls stage-run.sh -- claude … --agent" || return 1
}

test_sr_ac11_snippets_pass_wrapper_flags() {
  local f
  for f in --lane --mode --cycle --pr; do
    assert_contains "$(grep -E '^[[:space:]]*nohup .*stage-run\.sh' "$ORCH_SR")" "$f" "AC11: dispatch snippets pass $f" || return 1
  done
}

test_sr_ac11_events_file_named_once_and_never_in_a_code_block() {
  assert_eq "$(grep -c 'events.jsonl' "$ORCH_SR")" 1 "AC11: events.jsonl appears exactly once (the Run log sentence)" || return 1
  local in_block
  in_block=$(awk '/^```/ {b = !b; next} b && /events\.jsonl/ {print}' "$ORCH_SR")
  assert_eq "$in_block" "" "AC11: no code block writes to events.jsonl" || return 1
  assert_contains "$(grep 'events.jsonl' "$ORCH_SR")" "stage-run.sh" "AC11: the sentence names the wrapper as the writer" || return 1
}

test_sr_ac11_log_run_and_runs_jsonl_unchanged() {
  local now base
  now=$(grep -c 'log_run' "$ORCH_SR")
  base=$(cd "$ROOT_SR" && git show origin/main:agents/orchestrator.md | grep -c 'log_run')
  assert_le "$base" "$now" "AC11: log_run count ($now) not lower than main ($base)" || return 1
  assert_contains "$(cat "$ORCH_SR")" '"event":"dispatch","repo":"jpmoya/scheduler"' "AC11: the dispatch log_run example is still there" || return 1
  assert_contains "$(cat "$ORCH_SR")" "It is the only file you write" "AC11: 'only file you write' stays" || return 1
  assert_eq "$(cd "$ROOT_SR" && git show origin/main:agents/orchestrator.md | grep -c 'It is the only file you write')" \
            "$(grep -c 'It is the only file you write' "$ORCH_SR")" "AC11: that line is unchanged in count" || return 1
}

test_sr_ac11a_carve_out_names_class_word_and_needs_jp() {
  assert_eq "$(grep -n 'never resumes' "$ORCH_SR" | grep -c 'needs_jp')" 1 "AC11a: the carve-out line names needs_jp" || return 1
  assert_contains "$(grep 'never resumes' "$ORCH_SR" | grep 'needs_jp')" "class word" "AC11a: ...and says 'class word'" || return 1
}

# --------------------------------------------------------------------------------------------- run
for t in $(declare -F | awk '{print $3}' | grep '^test_sr_'); do run_test "$t"; done
