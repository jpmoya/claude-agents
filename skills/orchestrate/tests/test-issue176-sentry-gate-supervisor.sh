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
  if [ -f "$D/drop-ip" ]; then   # the agent also drops agent-in-progress, so only the strip stands between agent-go and dispatch
    jq --argjson n "$PIPELINE_ISSUE" 'map(if .number==$n then .labels |= map(select(.name != "agent-in-progress")) else . end)' "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"
  fi
  if [ -f "$D/drop-sentry" ]; then   # the agent also removes source:sentry, so a label-keyed strip would no-op
    jq --argjson n "$PIPELINE_ISSUE" 'map(if .number==$n then .labels |= map(select(.name != "source:sentry")) else . end)' "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"
  fi
  [ -f "$D/hang" ] && sleep 20   # keeps the intake run alive across ticks
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
  "issue edit "*"--remove-label agent-go"*)
    [ -f "$D/strip-fail" ] && { echo "$*" >> "$D/gh-calls.log"; exit 1; };;
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
  # a finished intake run with SENTRY_AUTO_GO=1: agent-go is kept and no strip is issued
  s176g_env 1 || return 1
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3; do si_tick; done   # launch (agent adds agent-go + marker), then the done branch
  local calls; calls=$(cat "$SI_D/gh-calls.log"); si_cleanup
  assert_not_contains "$calls" "issue edit 7 --repo project-a/repo-a --remove-label agent-go" "SENTRY_AUTO_GO=1: no agent-go strip is issued" || return 1
  # agent-go survived to dispatch: step 5 claimed the issue (its claim edit is what consumes the label)
  assert_contains "$calls" "issue edit 7 --add-label agent-in-progress --remove-label agent-go" "SENTRY_AUTO_GO=1: agent-go kept, issue dispatched" || return 1
}

test_s176g_strip_survives_agent_removing_source_sentry_label() {
  s176g_env || return 1
  touch "$SI_D/drop-sentry" "$SI_D/drop-ip"   # the agent adds agent-go and removes source:sentry
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3; do si_tick; done
  local labels calls; labels=$(si_labels 7); calls=$(cat "$SI_D/gh-calls.log"); si_cleanup
  assert_not_contains "$labels" "source:sentry" "precondition: the agent removed source:sentry" || return 1
  assert_contains "$calls" "issue edit 7 --repo project-a/repo-a --remove-label agent-go" "strip keyed on the launch-time record, not the label" || return 1
  assert_not_contains "$labels" "agent-go" "agent-go stripped though source:sentry was removed" || return 1
}

test_s176g_giveup_branch_strips_agent_go_from_sentry_issue() {
  s176g_env || return 1
  touch "$SI_D/no-marker"   # the agent adds agent-go but never posts a marker -> two runs, then give-up
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3 4 5 6; do si_tick; done
  local labels gave n calls other; labels=$(si_labels 7); n=$(si_launches); calls=$(cat "$SI_D/gh-calls.log")
  other=$(grep -vc -- '--agent intake' "$SI_D/claude.log")
  gave=0; ls "$SI_PIPE"/intake-*.gaveup >/dev/null 2>&1 && gave=1
  si_cleanup
  assert_eq "$n" "2" "two intake runs before giving up" || return 1
  assert_eq "$gave" "1" "run parked as gave-up" || return 1
  assert_contains "$calls" "issue edit 7 --repo project-a/repo-a --remove-label agent-go" "give-up branch itself issues the agent-go strip" || return 1
  assert_eq "$other" "0" "no dispatch launch happened (agent-go was stripped, not consumed by a claim)" || return 1
  assert_not_contains "$labels" "agent-in-progress" "issue was not claimed for dispatch" || return 1
  assert_not_contains "$labels" "agent-go" "give-up branch must strip agent-go from a source:sentry issue" || return 1
  assert_contains "$labels" "user-feedback-intake" "give-up re-queues for manual attention" || return 1
}

test_s176g_label_read_failure_keeps_state_and_retries() {
  s176g_env || return 1
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  si_tick                       # launch; the run adds agent-go + marker
  touch "$SI_D/labels-fail"
  # make the labels-only read fail
  perl -pi -e 's|^(  "issue view "\*"--json labels --jq"\*\))|$1\n    [ -f "\$D/labels-fail" ] && exit 1|' "$SI_D/gh"   # #434: perl, not sed -i (BSD sed has no \n in the replacement)
  si_tick; si_tick
  local kept=0; ls "$SI_PIPE"/intake-*.id >/dev/null 2>&1 && kept=1
  assert_eq "$kept" "1" "intake state kept while the label read fails" || { si_cleanup; return 1; }
  rm -f "$SI_D/labels-fail"; si_tick
  local labels; labels=$(si_labels 7); si_cleanup
  assert_not_contains "$labels" "agent-go" "strip retried and applied once the read works" || return 1
}

test_s176g_giveup_strip_failure_keeps_state_and_retries() {
  s176g_env || return 1
  touch "$SI_D/no-marker"
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3 4; do si_tick; done   # two runs, both exited; the next tick is the give-up
  touch "$SI_D/strip-fail"; si_tick; si_tick
  local kept=0 gave=0 note; ls "$SI_PIPE"/intake-*.id >/dev/null 2>&1 && kept=1
  ls "$SI_PIPE"/intake-*.gaveup >/dev/null 2>&1 && gave=1
  note=$(jq -r '.[].body' "$SI_D/comments.json")
  assert_eq "$kept" "1" "state kept while the give-up strip fails" || { si_cleanup; return 1; }
  assert_eq "$gave" "0" "not parked as gave-up while the strip fails" || { si_cleanup; return 1; }
  assert_not_contains "$note" "ran twice" "no give-up NOTE before the strip succeeded" || { si_cleanup; return 1; }
  rm -f "$SI_D/strip-fail"; si_tick
  local labels; labels=$(si_labels 7); gave=0; ls "$SI_PIPE"/intake-*.gaveup >/dev/null 2>&1 && gave=1; si_cleanup
  assert_not_contains "$labels" "agent-go" "strip retried and applied" || return 1
  assert_eq "$gave" "1" "parked as gave-up once the strip succeeded" || return 1
}

test_s176g_failed_strip_blocks_same_tick_dispatch() {
  s176g_env || return 1
  touch "$SI_D/drop-ip"
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  si_tick                       # launch; the run adds agent-go + marker and drops agent-in-progress
  touch "$SI_D/strip-fail"
  si_tick; si_tick              # done branch: the strip fails; step 5 must not claim the still-agent-go issue
  local claims; claims=$(grep -c -- 'issue comment 7 ' "$SI_D/gh-calls.log")
  si_cleanup
  assert_eq "$claims" "1" "only the intake claim: a failed strip must not let step 5 dispatch the sentry issue" || return 1
}

# s176g_tick_noflock — one supervisor tick with the file-lock binary absent from PATH, so the mkdir lock (the macOS path) is used. A live
# intake run's backgrounding subshell keeps the supervisor lock fd open (pre-existing, out of scope), which would make the next
# tick exit at the lock before it ever reaches the intake loop.
s176g_tick_noflock() {
  if [ ! -d "$SI_D/nof" ]; then
    mkdir -p "$SI_D/nof"; local f lk="fl"; lk="${lk}ock"
    for f in /usr/bin/* /bin/*; do [ "${f##*/}" = "$lk" ] || ln -sf "$f" "$SI_D/nof/${f##*/}" 2>/dev/null; done
  fi
  HOME="$SI_HOME" PATH="$SI_D:$SI_D/nof:/usr/local/bin:/opt/homebrew/bin" PIPE="$SI_PIPE" QUEUE="$SI_PIPE/queue" LOGDIR="$SI_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" /bin/bash "$SUP_SI" >/dev/null 2>&1; sleep 1.5
}

test_s176g_live_intake_run_is_stripped_and_nothing_dispatched() {
  # tradeoff (stated in the handoff): a hand-added agent-go on a live-intake source:sentry issue is stripped too
  s176g_env || return 1
  touch "$SI_D/hang"
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  s176g_tick_noflock           # launches intake; the run adds agent-go then stays alive
  local before; before=$(si_labels 7)
  s176g_tick_noflock           # run is live: the strip must still fire
  local labels calls other; labels=$(si_labels 7); calls=$(cat "$SI_D/gh-calls.log"); other=$(grep -vc -- '--agent intake' "$SI_D/claude.log")
  si_cleanup
  assert_contains "$before" "agent-go" "precondition: the live run added agent-go" || return 1
  assert_contains "$calls" "issue edit 7 --repo project-a/repo-a --remove-label agent-go" "live run: strip issued" || return 1
  assert_not_contains "$labels" "agent-go" "agent-go stripped while intake is still running" || return 1
  assert_eq "$other" "0" "the tick dispatched nothing" || return 1
}

run_test test_s176g_strip_removes_adjacent_agent_go_from_sentry_issue
run_test test_s176g_dispatch_launches_sentry_agent_go_issue_labelled_after_intake
run_test test_s176g_dispatch_launches_sentry_agent_go_issue_when_auto_go_one
run_test test_s176g_strip_survives_agent_removing_source_sentry_label
run_test test_s176g_giveup_branch_strips_agent_go_from_sentry_issue
run_test test_s176g_label_read_failure_keeps_state_and_retries
run_test test_s176g_giveup_strip_failure_keeps_state_and_retries
run_test test_s176g_live_intake_run_is_stripped_and_nothing_dispatched
run_test test_s176g_failed_strip_blocks_same_tick_dispatch
