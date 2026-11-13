# Issue #182 — daily cap on automatic Sentry-ticket launches: the intake side (code review of PR #683, HIGH).
# Since #186 a source:sentry intake run cannot write to GitHub; the supervisor applies the labels from intake-labels.sh
# through its fixed filter (intake_apply_decision). So:
#   - `sentry-auto-go` is written by the supervisor only, in the same write as `agent-go`, and only with SENTRY_AUTO_GO=1;
#   - with SENTRY_AUTO_GO=1 an `agent-go` WITHOUT `sentry-auto-go` on a source:sentry ticket that an intake run still owns is
#     stripped (it would launch outside the cap); a hand release after intake is done still launches uncapped (fixture 4,
#     test-issue182-sentry-cap-supervisor.sh);
#   - end to end: triaged by intake -> labelled by the supervisor -> dispatched -> counted in the launch log.
# Reuses the itr_* harness of test-intake-restriction.sh (stub gh / claude, whole supervisor ticks). That file sorts before
# this one in run-tests.sh; run alone, its helpers are loaded here with its cases switched off. Placeholder repo names only.

HERE_SCI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f itr_env >/dev/null 2>&1; then
  eval "sci_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_SCI/test-intake-restriction.sh"
  eval "$(declare -f sci_real_run_test | sed '1s/sci_real_run_test/run_test/')"
fi

# sci_ticks <n> — <n> supervisor ticks, then (bounded, 5 s) wait for every orchestrator launch the supervisor log reports
sci_ticks() {
  local i=0 want
  while [ "$i" -lt "$1" ]; do itr_tick; i=$((i + 1)); done
  want=$(grep -c 'claimed by .*orchestrate\.sh status ' "$ITR_HOME/logs/pipeline/supervisor.log" 2>/dev/null); i=0
  while [ "$(grep -c -- '--agent orchestrator' "$ITR_D/claude.log")" -lt "${want:-0}" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  return 0
}
sci_orch() { grep -c -- '--agent orchestrator' "$ITR_D/claude.log"; }
sci_adds() { grep -- '--add-label' "$ITR_D/gh-calls.log" | grep -v -- '--add-label agent-in-progress'; }   # triage label writes (claims excluded)

test_sci_supervisor_writes_sentry_auto_go_with_agent_go_and_the_launch_is_counted() {
  itr_env; echo 'SENTRY_AUTO_GO=1' >> "$ITR_HOME/.claude/pipeline/config.local.sh"
  itr_issue 8 user-feedback-intake source:sentry
  itr_stage 8 '{"verdict":"bug"}'
  sci_ticks 3
  local adds marker n cl log lines rc=0
  adds=$(sci_adds); marker=$(itr_marker 8); n=$(sci_orch); cl=$(cat "$ITR_D/claude.log")
  log=$(cat "$ITR_PIPE/sentry-launches.log" 2>/dev/null); lines=$(printf '%s\n' "$log" | grep -c .)
  assert_eq "$adds" "issue edit 8 --repo project-a/repo-a --add-label user-feedback,bug,agent-go,sentry-auto-go" "one label write: agent-go and sentry-auto-go together, from the helper" \
    && assert_eq "$marker" "**[intake] TRIAGED BUG**" "control: the decision was applied" \
    && assert_eq "$n" "1" "the labelled ticket is dispatched" \
    && assert_contains "$cl" "Drive project-a/repo-a#8 through the pipeline" "the orchestrator was started for it" \
    && assert_eq "$lines" "1" "the launch is counted: one line in the launch log" \
    || rc=1
  if [ "$rc" = 0 ]; then printf '%s\n' "$log" | grep -qE '^[0-9]+ project-a/repo-a 8$' || { fail "launch line shape, got: $log"; rc=1; }; fi
  itr_cleanup; return $rc
}

test_sci_no_sentry_auto_go_without_the_gate_or_for_noise() {
  local adds0 adds_noise rc=0
  itr_env   # SENTRY_AUTO_GO unset (0)
  itr_issue 8 user-feedback-intake source:sentry; itr_stage 8 '{"verdict":"bug"}'
  sci_ticks 2; adds0=$(sci_adds); itr_cleanup
  itr_env; echo 'SENTRY_AUTO_GO=1' >> "$ITR_HOME/.claude/pipeline/config.local.sh"
  itr_issue 8 user-feedback-intake source:sentry; itr_stage 8 '{"verdict":"noise"}'
  sci_ticks 2; adds_noise=$(sci_adds); itr_cleanup
  assert_eq "$adds0" "issue edit 8 --repo project-a/repo-a --add-label user-feedback,bug,agent-proposed" "SENTRY_AUTO_GO=0: agent-proposed, neither agent-go nor sentry-auto-go" || rc=1
  assert_eq "$adds_noise" "issue edit 8 --repo project-a/repo-a --add-label sentry-noise" "noise with SENTRY_AUTO_GO=1: only sentry-noise" || rc=1
  return $rc
}

test_sci_decision_file_cannot_name_sentry_auto_go() {
  itr_env; echo 'SENTRY_AUTO_GO=0' >> "$ITR_HOME/.claude/pipeline/config.local.sh"
  itr_issue 8 user-feedback-intake source:sentry
  itr_stage 8 '{"verdict":"bug","labels":["agent-go","sentry-auto-go"]}'
  sci_ticks 2
  local adds labels slog; adds=$(sci_adds); labels=$(itr_labels 8); slog=$(cat "$ITR_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  itr_cleanup
  assert_contains "$slog" "decision file refused" "a decision naming labels is refused as a whole" || return 1
  assert_not_contains "$adds" "sentry-auto-go" "no label write carries sentry-auto-go" || return 1
  assert_not_contains "$labels" "sentry-auto-go" "the issue does not get it" || return 1
}

test_sci_lone_agent_go_in_the_intake_window_is_stripped_with_auto_go_on() {
  # SENTRY_AUTO_GO=1. An agent-go is on the ticket while intake owns it, without sentry-auto-go (the supervisor did not put
  # it there: the verdict is `blocked`, which adds no label). It must not survive to dispatch, where it would launch uncounted.
  itr_env; echo 'SENTRY_AUTO_GO=1' >> "$ITR_HOME/.claude/pipeline/config.local.sh"
  itr_issue 8 user-feedback-intake source:sentry agent-go
  itr_stage 8 '{"verdict":"blocked"}'
  sci_ticks 3
  local calls labels n slog marker rc=0 counted=no
  calls=$(itr_calls_for 8); labels=$(itr_labels 8); n=$(sci_orch); slog=$(cat "$ITR_HOME/logs/pipeline/supervisor.log" 2>/dev/null); marker=$(itr_marker 8)
  [ -e "$ITR_PIPE/sentry-launches.log" ] && counted=yes
  assert_eq "$marker" "**[intake] BLOCKED**" "control: intake finished without granting agent-go" \
    && assert_contains "$calls" "issue edit 8 --repo project-a/repo-a --remove-label agent-go" "the lone agent-go is stripped though SENTRY_AUTO_GO=1" \
    && assert_not_contains "$labels" "agent-go" "the ticket no longer carries agent-go" \
    && assert_contains "$slog" "carried agent-go without sentry-auto-go during intake" "the strip is logged with its reason" \
    && assert_eq "$n" "0" "nothing was dispatched" \
    && assert_eq "$counted" "no" "and nothing was launched uncounted or counted" \
    || rc=1
  itr_cleanup; return $rc
}

test_sci_staff_feedback_run_costs_no_extra_label_read_with_auto_go_on() {
  # the SENTRY_AUTO_GO=1 strip reads labels only for runs launched as source:sentry; a staff-feedback run keeps the one
  # read intake_launch already makes
  itr_env; echo 'SENTRY_AUTO_GO=1' >> "$ITR_HOME/.claude/pipeline/config.local.sh"; touch "$ITR_D/mode-marker"
  itr_issue 5 user-feedback-intake
  sci_ticks 2
  local reads labels; reads=$(grep -c '^issue view 5 --repo project-a/repo-a --json labels --jq \[.labels\[\].name\] | join(" ")$' "$ITR_D/gh-calls.log"); labels=$(itr_labels 5)
  itr_cleanup
  assert_contains "$labels" "user-feedback" "control: the staff run was triaged" || return 1
  assert_eq "$reads" "1" "one label read (the launch), none added by the strip" || return 1
}

run_test test_sci_supervisor_writes_sentry_auto_go_with_agent_go_and_the_launch_is_counted
run_test test_sci_no_sentry_auto_go_without_the_gate_or_for_noise
run_test test_sci_decision_file_cannot_name_sentry_auto_go
run_test test_sci_lone_agent_go_in_the_intake_window_is_stripped_with_auto_go_on
run_test test_sci_staff_feedback_run_costs_no_extra_label_read_with_auto_go_on
