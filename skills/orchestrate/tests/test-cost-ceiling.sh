# Issue #141 (Phase 3 of #134) — the per-ticket cost ceiling in skills/orchestrate/stage-run.sh.
#   AC15 refusal (fullstack-developer + test-writer)    AC16 never refused           AC17 fresh budget after a lift
#   AC18 fail open when the POST fails                  AC22 block_classes / markers_for / orchestrator.md
# Expected values come from the ticket text or hand arithmetic in comments — never from the wrapper.
# Every function/variable is prefixed cc_ / CC_ (all test files share one shell). Placeholder names only (public repo).
# Each case gets its own PIPE, HOME, LOGDIR, CLAUDE_PROJECTS_DIR. Bash 3.2 compatible.
#
# events.jsonl fixture (project-a/app unless noted; all rows are stage_end, ts ascending, cost_usd in dollars):
#   #42  fullstack-developer 15, test-writer 20, code-reviewer null, fullstack-developer 10  -> sum 45 over 4 rows
#   #43  15 + 14 + 10                                                                         -> sum 39 (under 40)
#   #44  null, null                                                                           -> no cost data at all
#   #45  25 + 15                                                                              -> exactly 40 (not over)
#   #46  25 + 15.01                                                                           -> 40.01 (over by a cent)
#   #47  30, <cost_ceiling row, null>, 5, 7                                                   -> 12 since the lift
#   #48  30, <cost_ceiling row>, 15, 14, 12                                                   -> 41 since the lift (3 rows)
#   project-b/app #42  100                                                                    -> other repo, must not count for project-a/app#42

HERE_CC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_CC=$(cd "$HERE_CC/../../.." && pwd)
WRAP_CC="$ROOT_CC/skills/orchestrate/stage-run.sh"
ORCH_CC="$ROOT_CC/agents/orchestrator.md"
MARK_CC="$ROOT_CC/hooks/pipeline-markers.sh"
CC_POST_ID=987654321

# cc_setup — sets CC_BIN (stubs), CC_PIPE, CC_HOME, CC_LOG (LOGDIR), CC_PROJ; seeds the events fixture.
# Stub claude: writes argv to $CC_BIN/argv. Fake gh: GET (and any non-POST) answers `[]`; a POST (-X/--method POST, or any
# -f/-F/--field/--raw-field/--input) records the body in $CC_BIN/post-<n>.body, counts it in post-count, and answers
# {"id":987654321}; the file $CC_BIN/gh-fail-post makes every POST exit 1. `--jq <expr>` is honoured on the answer.
cc_setup() {
  CC_BIN=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-cc.XXXXXX")
  CC_PIPE=$(new_pipe); CC_HOME=$(new_home)
  CC_LOG="$CC_HOME/logs/pipeline"; CC_PROJ="$CC_HOME/.claude/projects"
  mkdir -p "$CC_PROJ"
  cat > "$CC_BIN/claude" <<'EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$@" > "$D/argv"
exit 0
EOF
  cat > "$CC_BIN/gh" <<'EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$D/gh-calls.log"
[ "$1" = "api" ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
post=0; body=""; jqx=""; input=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) [ "$2" = POST ] && post=1; shift ;;
    -f|-F|--field|--raw-field)
      post=1
      case "$2" in
        body=@-) body=$(cat) ;;
        body=@*) body=$(cat "${2#body=@}") ;;
        body=*) body="${2#body=}" ;;
      esac
      shift ;;
    --input) post=1; input=$2; shift ;;
    --jq|-q) jqx=$2; shift ;;
  esac
  shift
done
if [ "$post" = 1 ]; then
  [ -e "$D/gh-fail-post" ] && { echo "HTTP 500" >&2; exit 1; }
  if [ -n "$input" ]; then
    if [ "$input" = "-" ]; then body=$(cat | jq -r .body); else body=$(jq -r .body "$input"); fi
  fi
  n=$(cat "$D/post-count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/post-count"
  printf '%s' "$body" > "$D/post-$n.body"
  ans='{"id":987654321,"html_url":"https://github.com/project-a/app/issues/42#issuecomment-987654321"}'
else
  ans='[]'
fi
if [ -n "$jqx" ]; then printf '%s' "$ans" | jq -r "$jqx"; else printf '%s\n' "$ans"; fi
exit 0
EOF
  chmod +x "$CC_BIN/claude" "$CC_BIN/gh"; : > "$CC_BIN/gh-calls.log"
  cc_events_fixture
}
cc_teardown() { rm -rf "$CC_BIN" "$CC_PIPE" "$CC_HOME"; }

# cc_row <repo> <issue> <agent> <cost|null> <block_class|null> <seq> — one stage_end row (ts = 2026-10-01T10:00:<seq>Z)
cc_row() {
  jq -nc --arg repo "$1" --argjson issue "$2" --arg agent "$3" --arg cost "$4" --arg bc "$5" --arg seq "$6" '
    {v:1,ts:("2026-10-01T10:00:" + $seq + "Z"),host:"vm",event:"stage_end",run_id:("r" + $seq),session_id:null,
     repo:$repo,issue:$issue,agent:$agent,mode:null,outcome:(if $bc == "cost_ceiling" then "marker" else "no_marker" end),
     cost_usd:(if $cost == "null" then null else ($cost | tonumber) end),
     block_class:(if $bc == "null" then null else $bc end)}'
}

cc_events_fixture() {
  mkdir -p "$CC_LOG"
  {
    cc_row project-a/app 42 fullstack-developer 15 null 01
    cc_row project-a/app 42 test-writer 20 null 02
    cc_row project-a/app 42 code-reviewer null null 03
    cc_row project-a/app 42 fullstack-developer 10 null 04
    cc_row project-b/app 42 fullstack-developer 100 null 05
    cc_row project-a/app 43 fullstack-developer 15 null 06
    cc_row project-a/app 43 test-writer 14 null 07
    cc_row project-a/app 43 fullstack-developer 10 null 08
    cc_row project-a/app 44 fullstack-developer null null 09
    cc_row project-a/app 44 test-writer null null 10
    cc_row project-a/app 45 fullstack-developer 25 null 11
    cc_row project-a/app 45 test-writer 15 null 12
    cc_row project-a/app 46 fullstack-developer 25 null 13
    cc_row project-a/app 46 test-writer 15.01 null 14
    cc_row project-a/app 47 fullstack-developer 30 null 15
    cc_row project-a/app 47 fullstack-developer null cost_ceiling 16
    cc_row project-a/app 47 fullstack-developer 5 null 17
    cc_row project-a/app 47 test-writer 7 null 18
    cc_row project-a/app 48 fullstack-developer 30 null 19
    cc_row project-a/app 48 fullstack-developer null cost_ceiling 20
    cc_row project-a/app 48 fullstack-developer 15 null 21
    cc_row project-a/app 48 test-writer 14 null 22
    cc_row project-a/app 48 fullstack-developer 12 null 23
  } > "$CC_LOG/events.jsonl"
}

# cc_run <issue> <agent> <mode|""> — foreground wrapper run for project-a/app; sets CC_RC. mode "" = no --mode flag.
cc_run() {
  local issue=$1 agent=$2 mode=$3 flags=""
  [ -n "$mode" ] && flags="--mode $mode"
  rm -f "$CC_BIN/argv"
  CC_ROWS_BEFORE=$(wc -l < "$CC_LOG/events.jsonl" | tr -d ' ')
  ( cd "$CC_HOME" && env "PIPE=$CC_PIPE" "LOGDIR=$CC_LOG" "HOME=$CC_HOME" "CLAUDE_PROJECTS_DIR=$CC_PROJ" \
      "PATH=$CC_BIN:$PATH" "PIPELINE_ISSUE=$issue" "PIPELINE_AGENT=$agent" "PIPELINE_REPO=project-a/app" \
      "$WRAP_CC" $flags -- claude --dangerously-skip-permissions --agent "$agent" -p "Fix. Repo: project-a/app. Issue: #$issue." \
      > "$CC_BIN/out" 2> "$CC_BIN/err" )
  CC_RC=$?
}

cc_posts() { cat "$CC_BIN/post-count" 2>/dev/null || echo 0; }
# new rows appended by the last run
cc_new_rows() { tail -n +$((CC_ROWS_BEFORE + 1)) "$CC_LOG/events.jsonl"; }
cc_new_count() { cc_new_rows | grep -c . ; }
cc_new_ev() { cc_new_rows | jq -c "select(.event==\"$1\")" | grep -c .; }


# cc_control — proves the discriminating condition: the same wrapper, over-ceiling ticket #42, --mode fix, fullstack-developer
# IS refused (so a "never refused" case below can only pass because of what it varies). Then resets the sandbox state.
cc_control() {
  cc_run 42 fullstack-developer fix
  if [ "$(cc_posts)" != "1" ] || [ -e "$CC_BIN/argv" ]; then
    fail "control: the over-ceiling fix-cycle dispatch of #42 must be refused (no ceiling in the wrapper yet?)"; return 1
  fi
  rm -f "$CC_BIN"/post-*.body "$CC_BIN/post-count" "$CC_BIN/argv"; cc_events_fixture
}

# cc_assert_refused <issue> <agent> <amount> <runs> — the full refusal contract (ticket §3)
cc_assert_refused() {
  local issue=$1 agent=$2 amount=$3 runs=$4 r=0 body row
  assert_eq "$CC_RC" "0" "refused: wrapper exits 0" || r=1
  assert_file_absent "$CC_BIN/argv" "refused: claude was not started" || r=1
  assert_eq "$(cc_posts)" "1" "refused: exactly one comment posted" || r=1
  body=$(cat "$CC_BIN/post-1.body" 2>/dev/null)
  assert_eq "$(printf '%s\n' "$body" | sed -n 1p)" "**[$agent] BLOCKED**" "refused: line 1" || r=1
  assert_eq "$(printf '%s\n' "$body" | sed -n 2p)" "Blocked on: cost_ceiling — this ticket has used \$$amount over $runs stage runs (ceiling \$40.00); no new fix cycle was started" "refused: line 2" || r=1
  assert_eq "$(printf '%s\n' "$body" | sed -n 3p)" "Posted by stage-run.sh, not by the agent. To continue, record a decision that resolves this comment; the ticket then gets a further \$40.00." "refused: line 3" || r=1
  assert_eq "$(cc_new_count)" "1" "refused: exactly one new events row" || r=1
  assert_eq "$(cc_new_ev stage_start)" "0" "refused: no stage_start row" || r=1
  row=$(cc_new_rows | tail -1)
  assert_eq "$(printf '%s' "$row" | jq -r .event)" "stage_end" "refused: row is a stage_end" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r .outcome)" "marker" "refused: outcome marker" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r .block_class)" "cost_ceiling" "refused: block_class cost_ceiling" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r .marker_after)" "**[$agent] BLOCKED**" "refused: marker_after is the first line" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r .marker_comment_id)" "$CC_POST_ID" "refused: marker_comment_id from the POST response" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r '[.exit_code, .session_id, .cost_usd] | map(tostring) | join(",")')" "null,null,null" "refused: exit_code, session_id, cost_usd are null" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r .dur_s)" "0" "refused: dur_s 0" || r=1
  assert_eq "$(printf '%s' "$row" | jq -r "[.agent, .repo, .issue, .mode] | map(tostring) | join(\",\")")" "$agent,project-a/app,$issue,fix" "refused: row identity (agent, repo, issue, mode)" || r=1
  return $r
}

# cc_assert_launched — the stage ran normally: stub claude started, normal start/end rows, no ceiling row, nothing posted
cc_assert_launched() {
  local r=0
  assert_file_exists "$CC_BIN/argv" "launched: claude was started" || r=1
  assert_eq "$CC_RC" "0" "launched: wrapper exit = child's (0)" || r=1
  assert_eq "$(cc_new_ev stage_start)" "1" "launched: one stage_start row" || r=1
  assert_eq "$(cc_new_ev stage_end)" "1" "launched: one stage_end row" || r=1
  assert_eq "$(cc_new_rows | jq -r 'select(.event=="stage_end") | .block_class // "null"')" "null" "launched: stage_end has no cost_ceiling class" || r=1
  assert_eq "$(cc_posts)" "0" "launched: no BLOCKED comment posted" || r=1
  return $r
}

# --------------------------------------------------------------------------------------------- AC15

# 15+20+null+10 = 45.00 over 4 rows; ceiling 40 (the config.sh default — no override here)
test_cc_ac15_fullstack_developer_fix_over_ceiling_is_refused() {
  cc_setup; cc_run 42 fullstack-developer fix
  cc_assert_refused 42 fullstack-developer 45.00 4; local r=$?
  cc_teardown; return $r
}

test_cc_ac15_test_writer_fix_over_ceiling_is_refused() {
  cc_setup; cc_run 42 test-writer fix
  cc_assert_refused 42 test-writer 45.00 4; local r=$?
  cc_teardown; return $r
}

# --------------------------------------------------------------------------------------------- AC16

test_cc_ac16_under_the_ceiling_is_never_refused() {   # #43: 15+14+10 = 39
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 43 fullstack-developer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_first_run_mode_is_never_refused() {      # #42 is over, but --mode first
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 42 fullstack-developer first; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_no_mode_flag_is_never_refused() {
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 42 fullstack-developer ""; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_code_reviewer_is_never_refused() {       # #42 is over, --mode fix, but the agent is a reviewer
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 42 code-reviewer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_deployer_is_never_refused() {
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 42 deployer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_ceiling_zero_turns_it_off() {
  cc_setup; cc_control || { cc_teardown; return 1; }
  printf 'COST_CEILING_USD=0\n' > "$CC_HOME/.claude/pipeline/config.local.sh"
  cc_run 42 fullstack-developer fix; cc_assert_launched; local r=$?
  cc_teardown; return $r
}

test_cc_ac16_ceiling_is_overridable_in_config_local() {   # raise to 50: 45 is under -> runs
  cc_setup; cc_control || { cc_teardown; return 1; }
  printf 'COST_CEILING_USD=50\n' > "$CC_HOME/.claude/pipeline/config.local.sh"
  cc_run 42 fullstack-developer fix; cc_assert_launched; local r=$?
  cc_teardown; return $r
}

test_cc_ac16_all_null_costs_means_inert() {           # #44: no non-null cost_usd -> never refused
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 44 fullstack-developer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_ticket_with_no_rows_is_never_refused() {
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 99 fullstack-developer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac16_missing_events_file_is_never_refused() {
  cc_setup; cc_control || { cc_teardown; return 1; }; rm -f "$CC_LOG/events.jsonl" "$CC_BIN/argv"
  CC_ROWS_BEFORE=0
  ( cd "$CC_HOME" && env "PIPE=$CC_PIPE" "LOGDIR=$CC_LOG" "HOME=$CC_HOME" "CLAUDE_PROJECTS_DIR=$CC_PROJ" \
      "PATH=$CC_BIN:$PATH" "PIPELINE_ISSUE=42" "PIPELINE_AGENT=fullstack-developer" "PIPELINE_REPO=project-a/app" \
      "$WRAP_CC" --mode fix -- claude --agent fullstack-developer -p "Fix. Repo: project-a/app. Issue: #42." >/dev/null 2>&1 )
  local rc=$? r=0
  assert_eq "$rc" "0" "no events file: wrapper exit 0" || r=1
  assert_file_exists "$CC_BIN/argv" "no events file: claude was started" || r=1
  assert_eq "$(cc_posts)" "0" "no events file: nothing posted" || r=1
  cc_teardown; return $r
}

# boundary: spent <= ceiling carries on (exactly 40.00), one cent over is refused
test_cc_ac16_boundary_exactly_at_the_ceiling_is_not_refused() {   # #45: 25 + 15 = 40.00
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 45 fullstack-developer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac15_boundary_one_cent_over_is_refused() {                # #46: 25 + 15.01 = 40.01 over 2 rows
  cc_setup; cc_run 46 fullstack-developer fix
  cc_assert_refused 46 fullstack-developer 40.01 2; local r=$?
  cc_teardown; return $r
}

# the other repo's #42 ($100) must not leak into project-a/app#42's total: still $45.00 over 4 runs
test_cc_ac15_spend_is_scoped_to_repo_and_issue() {
  cc_setup; cc_run 42 fullstack-developer fix
  assert_contains "$(cat "$CC_BIN/post-1.body" 2>/dev/null)" "\$45.00 over 4 stage runs" "scoping: project-b/app#42 and other issues excluded" || { cc_teardown; return 1; }
  cc_teardown
}

# --------------------------------------------------------------------------------------------- AC17

test_cc_ac17_lift_gives_a_fresh_budget_12_since_the_lift_runs() {   # #47: only 5+7 = 12 counted after the cost_ceiling row
  cc_setup; cc_control || { cc_teardown; return 1; }; cc_run 47 fullstack-developer fix; cc_assert_launched; local r=$?; cc_teardown; return $r
}

test_cc_ac17_41_since_the_lift_is_refused_again() {                 # #48: 15+14+12 = 41.00 over 3 rows after the lift
  cc_setup; cc_run 48 fullstack-developer fix
  cc_assert_refused 48 fullstack-developer 41.00 3; local r=$?
  cc_teardown; return $r
}

# --------------------------------------------------------------------------------------------- AC18

test_cc_ac18_post_failure_fails_open() {
  cc_setup; cc_control || { cc_teardown; return 1; }; : > "$CC_BIN/gh-fail-post"
  cc_run 42 fullstack-developer fix
  local r=0
  assert_file_exists "$CC_BIN/argv" "AC18: claude is started when the BLOCKED cannot be posted" || r=1
  assert_eq "$CC_RC" "0" "AC18: wrapper exit = child's" || r=1
  assert_eq "$(cc_new_rows | jq -r 'select(.block_class=="cost_ceiling") | .event' | grep -c .)" "0" "AC18: no cost_ceiling row written" || r=1
  assert_eq "$(cc_new_ev stage_start)" "1" "AC18: normal stage_start" || r=1
  assert_eq "$(cc_new_ev stage_end)" "1" "AC18: normal stage_end" || r=1
  cc_teardown; return $r
}

# --------------------------------------------------------------------------------------------- AC22

test_cc_ac22_block_classes_contains_cost_ceiling() {
  local out; out=$(bash -c ". '$MARK_CC' >/dev/null 2>&1; block_classes")
  assert_contains "$out" "cost_ceiling" "AC22: block_classes lists cost_ceiling" || return 1
  assert_contains "$out" "needs_jp" "AC22: existing classes kept" || return 1
}

test_cc_ac22_markers_for_is_byte_identical_to_main() {
  local cur base ref
  cur=$(awk '/^markers_for\(\)/{p=1} p{print} p&&/^}/{exit}' "$MARK_CC" | cksum)
  ref=$(cd "$ROOT_CC" && git merge-base HEAD origin/main 2>/dev/null)
  if [ -n "$ref" ] && base=$(cd "$ROOT_CC" && git show "$ref:hooks/pipeline-markers.sh" 2>/dev/null) && [ -n "$base" ]; then
    base=$(printf '%s\n' "$base" | awk '/^markers_for\(\)/{p=1} p{print} p&&/^}/{exit}' | cksum)
  else
    base="1931356475 1340"   # hand-recorded from main c0e8e6f (2026-10-03) when no origin/main is available
  fi
  assert_eq "$cur" "$base" "AC22: markers_for untouched" || return 1
  # a vacuous pass guard: the function exists and still knows the developer's BLOCKED
  assert_contains "$(bash -c ". '$MARK_CC' >/dev/null 2>&1; markers_for fullstack-developer")" "BLOCKED" "AC22: markers_for still works" || return 1
}

test_cc_ac22_orchestrator_md_loop_cap_sentence_and_mode_fix() {
  local sec r=0
  assert_eq "$(grep -c 'Blocked on: cost_ceiling' "$ORCH_CC")" "1" "AC22: 'Blocked on: cost_ceiling' appears once in orchestrator.md" || r=1
  sec=$(awk '/^## Loop cap/{p=1; next} p&&/^## /{exit} p{print}' "$ORCH_CC")
  assert_contains "$sec" "Blocked on: cost_ceiling" "AC22: ...and it is inside the Loop cap section" || r=1
  assert_contains "$sec" "COST_CEILING_USD" "AC22: Loop cap names COST_CEILING_USD" || r=1
  assert_contains "$sec" "stage-run.sh" "AC22: Loop cap says stage-run.sh posts it" || r=1
  assert_contains "$sec" "Resolves:" "AC22: Loop cap says a decision's Resolves: line resumes it" || r=1
  assert_contains "$sec" "JP-only" "AC22: Loop cap says it is not on the JP-only list" || r=1
  [ "$(grep -c -- '--mode fix' "$ORCH_CC")" -ge 1 ] || { fail "AC22: orchestrator.md must state fix-cycle dispatches pass --mode fix (found 0)"; r=1; }
  return $r
}

for t in test_cc_ac15_fullstack_developer_fix_over_ceiling_is_refused \
  test_cc_ac15_test_writer_fix_over_ceiling_is_refused \
  test_cc_ac16_under_the_ceiling_is_never_refused \
  test_cc_ac16_first_run_mode_is_never_refused \
  test_cc_ac16_no_mode_flag_is_never_refused \
  test_cc_ac16_code_reviewer_is_never_refused \
  test_cc_ac16_deployer_is_never_refused \
  test_cc_ac16_ceiling_zero_turns_it_off \
  test_cc_ac16_ceiling_is_overridable_in_config_local \
  test_cc_ac16_all_null_costs_means_inert \
  test_cc_ac16_ticket_with_no_rows_is_never_refused \
  test_cc_ac16_missing_events_file_is_never_refused \
  test_cc_ac16_boundary_exactly_at_the_ceiling_is_not_refused \
  test_cc_ac15_boundary_one_cent_over_is_refused \
  test_cc_ac15_spend_is_scoped_to_repo_and_issue \
  test_cc_ac17_lift_gives_a_fresh_budget_12_since_the_lift_runs \
  test_cc_ac17_41_since_the_lift_is_refused_again \
  test_cc_ac18_post_failure_fails_open \
  test_cc_ac22_block_classes_contains_cost_ceiling \
  test_cc_ac22_markers_for_is_byte_identical_to_main \
  test_cc_ac22_orchestrator_md_loop_cap_sentence_and_mode_fix; do
  run_test "$t"
done
