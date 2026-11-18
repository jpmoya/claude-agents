# Audit 2026-11-18: config.sh sentry_goal_label names a goal label the repo may no longer have (sales: "goal: Sales Sentry goal"
# was renamed "... (done)" when the goal closed). intake_apply_decision wrote it in the same edit as agent-go, so the whole edit
# failed every tick ("label write failed ... every label must exist", sales #1508 from 23:33Z) and the triaged Sentry bug never
# got agent-go. The goal label is optional: when the full write fails, the labels are written again without it.
# Reuses the itr_* harness of test-intake-restriction.sh (same loading guard as test-issue182-sentry-cap-intake.sh).

HERE_SGM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f itr_env >/dev/null 2>&1; then
  eval "sgm_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_SGM/test-intake-restriction.sh"
  eval "$(declare -f sgm_real_run_test | sed '1s/sgm_real_run_test/run_test/')"
fi

sgm_env() {
  itr_env
  { echo 'SENTRY_AUTO_GO=1'
    echo 'sentry_goal_label() { case "$1" in project-a/repo-a) echo "goal: Old Sentry goal" ;; esac; }'; } >> "$ITR_HOME/.claude/pipeline/config.local.sh"
  itr_issue 8 user-feedback-intake source:sentry
  itr_stage 8 '{"verdict":"bug"}'
}

test_sgm_missing_goal_label_still_releases_the_bug() {
  sgm_env
  echo 'goal:_Old_Sentry_goal' > "$ITR_D/missing-labels"
  local i; for i in 1 2 3; do itr_tick; done
  local labels log marker
  labels=$(jq -r '.[] | select(.number==8) | [.labels[].name] | join(",")' "$ITR_D/issues.json"); log=$(cat "$ITR_HOME/logs/pipeline/supervisor.log"); marker=$(itr_marker 8)
  itr_cleanup
  assert_contains "$labels" "agent-go" "the triaged Sentry bug gets agent-go although its goal label is missing" || return 1
  assert_contains "$labels" "sentry-auto-go" "sentry-auto-go still lands with agent-go" || return 1
  assert_not_contains "$labels" "Old Sentry goal" "the missing goal label is not on the issue" || return 1
  assert_contains "$log" "goal label 'goal: Old Sentry goal' could not be added" "the dropped goal label is logged" || return 1
  assert_eq "$marker" "**[intake] TRIAGED BUG**" "the decision was applied" || return 1
}

test_sgm_existing_goal_label_is_written_in_the_same_edit() {
  sgm_env
  local i; for i in 1 2 3; do itr_tick; done
  local adds; adds=$(grep -- '--add-label' "$ITR_D/gh-calls.log" | grep -v -- '--add-label agent-in-progress')
  itr_cleanup
  assert_eq "$adds" "issue edit 8 --repo project-a/repo-a --add-label user-feedback,bug,agent-go,sentry-auto-go,goal: Old Sentry goal" "control: one write with the goal label when it exists" || return 1
}

run_test test_sgm_missing_goal_label_still_releases_the_bug
run_test test_sgm_existing_goal_label_is_written_in_the_same_edit
