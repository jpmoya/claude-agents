# Every product-manager launch carries a `Goal: <goal id>` line (skills/pm-goal-assignment). Prefix pg_ / PG_.
#   stage-run.sh   a product-manager stage without the line exits 2 and never starts claude; with the line (or
#                  `none-confirmed-by-JP`) claude is started with the prompt; any other agent is unaffected
#   pm-goal.sh     `require` refuses / accepts a prompt; `feedback` resolves the live feedback goal from the registry
#                  (none live -> exit 3); `ticket` reads the Goal line of a ticket body
#   supervisor.sh  step 3c asks pm-goal.sh for the goal, checks the prompt with `require` and passes the prompt to claude
#   docs           product-manager.md, CLAUDE.md, orchestrator.md, message-triage.md and the skill carry the rule
# Black-box with a fake `claude` and `gh` first on PATH. Placeholder repo names only.

HERE_PG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_PG=$(cd "$HERE_PG/../../.." && pwd)
STAGE_PG="$HERE_PG/../stage-run.sh"
GOAL_PG="$HERE_PG/../pm-goal.sh"

pg_setup() {
  PG_D=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-pg.XXXXXX")
  mkdir -p "$PG_D/bin" "$PG_D/log" "$PG_D/pipe"
  cat > "$PG_D/bin/claude" <<'X'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$D/claude.log"
exit 0
X
  cat > "$PG_D/bin/gh" <<'X'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  *"issue view"*) cat "$D/body.txt" 2>/dev/null; exit 0 ;;
  *"state=open"*) cat "$D/registry-open.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *"state=closed"*) echo '[]'; exit 0 ;;
esac
echo "fake gh: unexpected $*" >&2; exit 1
X
  chmod +x "$PG_D/bin/claude" "$PG_D/bin/gh"
}

pg_stage() {  # pg_stage <agent> <prompt> -> runs stage-run.sh; sets PG_RC, PG_ERR
  PG_ERR=$(PATH="$PG_D/bin:$PATH" PIPE="$PG_D/pipe" LOGDIR="$PG_D/log" PIPELINE_AGENT="$1" \
    bash "$STAGE_PG" --lane full --mode first -- claude --agent "$1" -p "$2" 2>&1 >/dev/null); PG_RC=$?
}

test_pg_stage_run_refuses_pm_without_goal() {
  pg_setup
  pg_stage product-manager $'Write the spec. Repo: a/b. Issue: #5.'
  assert_eq "$PG_RC" "2" "exit code" || return 1
  assert_contains "$PG_ERR" "Goal:" "refusal line" || return 1
  [ ! -s "$PG_D/bin/claude.log" ] || { fail "claude was started without a Goal line"; return 1; }
  assert_contains "$(cat "$PG_D/log/events.jsonl")" "refused_no_goal" "stage_end row" || return 1
  rm -rf "$PG_D"
}

test_pg_stage_run_starts_pm_with_goal_line() {
  pg_setup
  pg_stage product-manager $'Write the spec. Repo: a/b. Issue: #5.\nGoal: org_repo-fb-feedback'
  assert_eq "$PG_RC" "0" "exit code" || return 1
  assert_contains "$(cat "$PG_D/bin/claude.log")" "Goal: org_repo-fb-feedback" "claude got the goal line" || return 1
  rm -rf "$PG_D"
}

test_pg_stage_run_accepts_none_confirmed_by_jp() {
  pg_setup
  pg_stage product-manager $'File it. Goal: none-confirmed-by-JP'
  assert_eq "$PG_RC" "0" "exit code" || return 1
  assert_contains "$(cat "$PG_D/bin/claude.log")" "none-confirmed-by-JP" "claude started" || return 1
  rm -rf "$PG_D"
}

test_pg_stage_run_other_agents_need_no_goal() {
  pg_setup
  pg_stage code-reviewer $'Review it. Repo: a/b. Issue: #5.'
  assert_eq "$PG_RC" "0" "exit code" || return 1
  assert_contains "$(cat "$PG_D/bin/claude.log")" "Review it" "claude started" || return 1
  rm -rf "$PG_D"
}

test_pg_require() {
  local out rc
  out=$(bash "$GOAL_PG" require $'File this.\nReported by: JP (directly)' 2>&1); rc=$?
  assert_eq "$rc" "2" "no Goal line refuses" || return 1
  assert_contains "$out" "no 'Goal: <goal id>' line" "one-line refusal" || return 1
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "refusal is one line" || return 1
  bash "$GOAL_PG" require $'File this.\nGoal: label-goal__Sales_Workflow_3.0' >/dev/null 2>&1 || { fail "a Goal line must pass"; return 1; }
  bash "$GOAL_PG" require "x Goal: none-confirmed-by-JP" >/dev/null 2>&1 || { fail "none-confirmed-by-JP must pass"; return 1; }
  bash "$GOAL_PG" require "Goal: " >/dev/null 2>&1 && { fail "an empty Goal must be refused"; return 1; }
  bash "$GOAL_PG" require "" >/dev/null 2>&1 && { fail "an empty prompt must be refused"; return 1; }
  return 0
}

pg_registry() {  # <issue number> <id> <spec> <extra label name> -> one registry issue JSON object
  jq -nc --argjson n "$1" --arg id "$2" --arg spec "$3" --arg l "$4" \
    '{number:$n, state:"open", closed_at:null, labels:[{name:"delivery-goal"},{name:$l}],
      body:("Goal: x\n\n```json\n" + ({id:$id, spec:$spec} | tojson) + "\n```\n")}'
}

test_pg_feedback_goal_from_registry() {
  pg_setup
  { pg_registry 11 "org_repo-a-ms-3" "org/repo-a:milestone:3" goal-active
    pg_registry 12 "org_repo-a-fb-feedback" "org/repo-a:feedback" goal-queued
    pg_registry 13 "org_repo-b-fb-feedback" "org/repo-b:feedback" goal-stopped; } | jq -sc . > "$PG_D/bin/registry-open.json"
  local out
  out=$(PATH="$PG_D/bin:$PATH" PIPE="$PG_D/pipe" bash "$GOAL_PG" feedback org/repo-a 2>/dev/null); local rc=$?
  assert_eq "$rc" "0" "feedback goal found" || return 1
  assert_eq "$out" "org_repo-a-fb-feedback" "id" || return 1
  PATH="$PG_D/bin:$PATH" PIPE="$PG_D/pipe" bash "$GOAL_PG" feedback org/repo-b >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "3" "a stopped feedback goal is not live" || return 1
  PATH="$PG_D/bin:$PATH" PIPE="$PG_D/pipe" bash "$GOAL_PG" feedback org/repo-c >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "3" "no goal for the repo" || return 1
  rm -rf "$PG_D"
}

test_pg_ticket_goal_line() {
  pg_setup
  printf 'Why: x\nGoal: label-goal__Sales_Sentry_goal\nMore\n' > "$PG_D/bin/body.txt"
  local out; out=$(PATH="$PG_D/bin:$PATH" PIPE="$PG_D/pipe" bash "$GOAL_PG" ticket org/repo-a 5 2>/dev/null); local rc=$?
  assert_eq "$rc" "0" "has a Goal line" || return 1
  assert_eq "$out" "label-goal__Sales_Sentry_goal" "id" || return 1
  printf 'Why: x\n' > "$PG_D/bin/body.txt"
  PATH="$PG_D/bin:$PATH" PIPE="$PG_D/pipe" bash "$GOAL_PG" ticket org/repo-a 5 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "3" "no Goal line" || return 1
  rm -rf "$PG_D"
}

if ! declare -f sp_env >/dev/null 2>&1; then   # reuse the spec-run supervisor sandbox (same trick as test-issue182-spec-run-counted.sh)
  eval "pg_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_PG/test-spec-run-supervisor.sh"
  eval "$(declare -f pg_real_run_test | sed '1s/pg_real_run_test/run_test/')"
fi

pg_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }

test_pg_spec_run_launches_with_the_goal_line() {
  sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_tick
  local n log; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log")
  sp_cleanup
  assert_eq "$n" "1" "the PM is launched when the repo has a live feedback goal" || return 1
  assert_contains "$log" "Goal: project-a_repo-a-fb-feedback" "launch prompt carries the feedback goal" || return 1
}

test_pg_spec_run_does_not_launch_without_a_goal() {
  sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  echo '[]' > "$SP_D/registry.json"
  sp_tick
  local n labels; n=$(sp_pm_launches); labels=$(sp_labels 7)
  sp_cleanup
  assert_eq "$n" "0" "no live goal: the PM is not started" || return 1
  assert_eq "$labels" "user-feedback,user-feedback-needs-spec" "no claim, labels untouched" || return 1
}

test_pg_supervisor_spec_run_passes_the_goal() {
  local blk; blk=$(awk '/^# 3c\. Spec/{on=1} on&&/^# 3d\./{exit} on' "$ROOT_PG/skills/orchestrate/supervisor.sh")
  assert_contains "$blk" 'pm-goal.sh" feedback' "3c resolves the feedback goal" || return 1
  assert_contains "$blk" 'pm-goal.sh" require "$sg_prompt"' "3c checks the prompt before claiming" || return 1
  assert_contains "$blk" '"$sg_prompt" "$PIPE/$k.exit"' "3c launches claude with the checked prompt" || return 1
  assert_contains "$blk" 'Goal: $sg_id' "prompt carries the Goal line" || return 1
  # the require check sits before the claim comment: no claim, no label swap, without a goal
  local req claim
  req=$(printf '%s\n' "$blk" | grep -n 'pm-goal.sh" require' | head -1 | cut -d: -f1)
  claim=$(printf '%s\n' "$blk" | grep -n 'NOTE\*\* claim' | tail -1 | cut -d: -f1)
  assert_lt "$req" "$claim" "require runs before the claim" || return 1
}

test_pg_docs_carry_the_rule() {
  pg_has "$ROOT_PG/agents/product-manager.md" "## Goal line first" || return 1
  pg_has "$ROOT_PG/agents/product-manager.md" "print the one-line refusal" || return 1
  pg_has "$ROOT_PG/agents/orchestrator.md" "product-manager dispatches carry a Goal line" || return 1
  pg_has "$ROOT_PG/agents/message-triage.md" "Goal first" || return 1
  pg_has "$ROOT_PG/CLAUDE.md" "Every ticket belongs to a goal" || return 1
  pg_has "$ROOT_PG/skills/pm-goal-assignment/SKILL.md" "name: pm-goal-assignment" || return 1
  pg_has "$ROOT_PG/skills/pm-goal-assignment/SKILL.md" "none-confirmed-by-JP" || return 1
}

run_test test_pg_stage_run_refuses_pm_without_goal
run_test test_pg_stage_run_starts_pm_with_goal_line
run_test test_pg_stage_run_accepts_none_confirmed_by_jp
run_test test_pg_stage_run_other_agents_need_no_goal
run_test test_pg_require
run_test test_pg_feedback_goal_from_registry
run_test test_pg_ticket_goal_line
run_test test_pg_spec_run_launches_with_the_goal_line
run_test test_pg_spec_run_does_not_launch_without_a_goal
run_test test_pg_supervisor_spec_run_passes_the_goal
run_test test_pg_docs_carry_the_rule
