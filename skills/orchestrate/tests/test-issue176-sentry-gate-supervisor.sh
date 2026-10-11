# Issue #176 — code-review fixes: SENTRY_AUTO_GO=0 gate in the supervisor. Reuses the si_* harness of
# test-intake-supervisor.sh (sourced earlier by the runner). Added by the implementer; not part of the locked set.

# s176g_env [SENTRY_AUTO_GO value] — si_env plus a claude stub that, in intake mode, posts a marker and adds agent-go
s176g_env() {
  type si_env >/dev/null 2>&1 || { fail "si_env harness missing"; return 1; }
  si_env
  [ -n "${1:-}" ] && echo "SENTRY_AUTO_GO=$1" >> "$SI_HOME/.claude/pipeline/config.local.sh"
  cat > "$SI_D/claude" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$* | ISSUE=${PIPELINE_ISSUE:-} AGENT=${PIPELINE_AGENT:-} REPO=${PIPELINE_REPO:-}" >> "$D/claude.log"
if [ "${PIPELINE_AGENT:-}" = intake ]; then
  if [ ! -f "$D/no-marker" ]; then
    jq --arg b $'**[intake] TRIAGED BUG**\nok' '. + [{body:$b,createdAt:"2099-01-01T00:00:00Z"}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
  fi
  jq --argjson n "$PIPELINE_ISSUE" 'map(if .number==$n then .labels += [{name:"agent-go"}] else . end)' "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"
fi
exit 0
X
  chmod +x "$SI_D/claude"
  # the harness gh answers every `issue view` from comments.json; serve `--json labels` from issues.json
  mv "$SI_D/gh" "$SI_D/gh-base"
  cat > "$SI_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
case "$*" in
  "issue view "*"--json labels --jq"*)
    echo "$*" >> "$D/gh-calls.log"
    n=$3; jqx=${@: -1}
    jq -c --argjson n "$n" '.[]|select(.number==$n)|{labels:.labels}' "$D/issues.json" | jq -r "$jqx"; exit 0;;
esac
exec "$D/gh-base" "$@"
X
  chmod +x "$SI_D/gh"
}

test_s176g_strip_removes_adjacent_agent_go_from_sentry_issue() {
  s176g_env || return 1
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3; do si_tick; done
  local labels calls; labels=$(si_labels 7); calls=$(cat "$SI_D/gh-calls.log"); si_cleanup
  assert_contains "$calls" "issue edit 7 --repo project-a/repo-a --remove-label agent-go" "strip fires though labels sort adjacent (agent-go, source:sentry)" || return 1
  assert_not_contains "$labels" "agent-go" "sentry issue must not keep agent-go with SENTRY_AUTO_GO=0" || return 1
  assert_contains "$labels" "source:sentry" "source:sentry untouched" || return 1
}

test_s176g_dispatch_launches_sentry_agent_go_issue_labelled_after_intake() {
  # JP's hand-added agent-go on an approved Sentry bug must launch even with SENTRY_AUTO_GO=0 (no dispatch gate)
  s176g_env || return 1
  si_issue 7 project-a/repo-a agent-go source:sentry
  si_issue 8 project-a/repo-a agent-go
  si_tick
  local calls; calls=$(cat "$SI_D/gh-calls.log"); si_cleanup
  assert_contains "$calls" "issue comment 7" "sentry agent-go issue is claimed for dispatch" || return 1
}

test_s176g_dispatch_launches_sentry_agent_go_issue_when_auto_go_one() {
  s176g_env 1 || return 1
  si_issue 7 project-a/repo-a agent-go source:sentry
  si_tick
  local calls; calls=$(cat "$SI_D/gh-calls.log"); si_cleanup
  assert_contains "$calls" "issue comment 7" "SENTRY_AUTO_GO=1: sentry agent-go issue is dispatched" || return 1
}

test_s176g_giveup_branch_strips_agent_go_from_sentry_issue() {
  s176g_env || return 1
  touch "$SI_D/no-marker"   # the agent adds agent-go but never posts a marker -> two runs, then give-up
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3 4 5 6; do si_tick; done
  local labels gave n; labels=$(si_labels 7); n=$(si_launches)
  gave=0; ls "$SI_PIPE"/intake-*.gaveup >/dev/null 2>&1 && gave=1
  si_cleanup
  assert_eq "$n" "2" "two intake runs before giving up" || return 1
  assert_eq "$gave" "1" "run parked as gave-up" || return 1
  assert_not_contains "$labels" "agent-go" "give-up branch must strip agent-go from a source:sentry issue" || return 1
  assert_contains "$labels" "user-feedback-intake" "give-up re-queues for manual attention" || return 1
}

test_s176g_label_read_failure_keeps_state_and_retries() {
  s176g_env || return 1
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  si_tick                       # launch; the run adds agent-go + marker
  touch "$SI_D/labels-fail"
  # make the labels-only read fail
  sed -i 's|^  "issue view "\*"--json labels --jq"\*)|  "issue view "*"--json labels --jq"*)\n    [ -f "$D/labels-fail" ] \&\& exit 1|' "$SI_D/gh"
  si_tick; si_tick
  local kept=0; ls "$SI_PIPE"/intake-*.id >/dev/null 2>&1 && kept=1
  assert_eq "$kept" "1" "intake state kept while the label read fails" || { si_cleanup; return 1; }
  rm -f "$SI_D/labels-fail"; si_tick
  local labels; labels=$(si_labels 7); si_cleanup
  assert_not_contains "$labels" "agent-go" "strip retried and applied once the read works" || return 1
}

run_test test_s176g_strip_removes_adjacent_agent_go_from_sentry_issue
run_test test_s176g_dispatch_launches_sentry_agent_go_issue_labelled_after_intake
run_test test_s176g_dispatch_launches_sentry_agent_go_issue_when_auto_go_one
run_test test_s176g_giveup_branch_strips_agent_go_from_sentry_issue
run_test test_s176g_label_read_failure_keeps_state_and_retries
