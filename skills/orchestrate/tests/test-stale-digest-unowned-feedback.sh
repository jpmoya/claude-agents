# Issue #676 (c) — the supervisor's stale-work digest reports feedback tickets nobody owns (Expected Behavior 12-14):
#   user-feedback-intake, idle past STALE_WORK_HOURS, no agent-in-progress          → "intake not picked up"
#   user-feedback, idle, none of agent-go / agent-in-progress / agent-proposed / user-feedback-needs-spec, and
#     no routing marker                                                             → "never started (no approval label, no marker)"
#     a gate marker that is neither a gate nor done (terminal_kind)                 → "stopped mid-pipeline after <marker first line>"
# and no live or pending run on this host. One log line per ticket, one #engineering message per repo (at most once per 24h,
# or when the set changes; stamp $PIPE/stale-feedback-<owner_repo>.notified). Read-only: no GitHub write, ever.
#
# Harness: sq_env (test-supervisor-queued-not-counted.sh) + the fixture fake gh, wrapped here to answer the digest's two
# list reads (`gh issue list … --label user-feedback-intake|user-feedback --limit 300`) from ufd-intake.json / ufd-feedback.json
# (ufd-list-fail makes both exit 1). Comments come from the fixture's gh-issue-comments-json-<n> / gh-issue-latest-marker-<n>;
# gh-issue-view-rc-<n> fails that issue's comments read. The repo is scanned through SCAN_ONLY_REPOS, so no dispatch step
# touches it. Expected values are hand-written from the ticket. Placeholder repo names only.

HERE_UFD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "ufd_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_UFD/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f ufd_real_run_test | sed '1s/ufd_real_run_test/run_test/')"
fi

ufd_env() {
  sq_env open
  printf 'SCAN_ONLY_REPOS=("project-a/repo-a")\n' > "$SQ_HOME/.claude/pipeline/config.local.sh"
  echo '[]' > "$SQ_GH/ufd-intake.json"; echo '[]' > "$SQ_GH/ufd-feedback.json"
  cp "$SQ_GH/gh" "$SQ_GH/gh-base"
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "issue list "*"--label user-feedback-intake "*"--limit 300"*|"issue list "*"--label user-feedback "*"--limit 300"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    [ -f "$HERE/ufd-list-fail" ] && exit 1
    case "$*" in *"--label user-feedback-intake "*) cat "$HERE/ufd-intake.json" ;; *) cat "$HERE/ufd-feedback.json" ;; esac
    exit 0 ;;
  *) exec "$HERE/gh-base" "$@" ;;
esac
GH_EOF
  : > "$SQ_GH/curl-calls.log"
  cat > "$SQ_GH/curl" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/curl-calls.log"; echo '{"ok":true}'
X
  chmod +x "$SQ_GH/gh" "$SQ_GH/curl"
  printf '#!/bin/bash\necho "Filesystem 512-blocks Used Available Capacity Mounted"\necho "/dev/fake 100 0 0 10%% /"\n' > "$SQ_GH/df"; chmod +x "$SQ_GH/df"
}
# ufd_ticket <intake|feedback> <num> <secs idle> [label...] — one open issue in that list read
ufd_ticket() {
  local f="$SQ_GH/ufd-$1.json" n=$2 idle=$3; shift 3
  jq --argjson n "$n" --arg u "$(sq_iso_ago "$idle")" --argjson l "$(printf '%s\n' "$@" | jq -R 'select(length > 0)' | jq -sc 'map({name:.})')" \
    '. + [{number:$n, updatedAt:$u, labels:$l}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
ufd_marker() { printf '[{"body":"%s","createdAt":"%s"}]' "$2" "$(sq_iso_ago $((6 * 3600)))" > "$SQ_GH/gh-issue-comments-json-$1"; }   # the issue's only comment
# ufd_tick — one supervisor tick with the #engineering bot + the digest's error webhook wired (curl is the recorder above)
ufd_tick() {
  HOME="$SQ_HOME" PATH="$SQ_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SQ_PIPE" QUEUE="$SQ_PIPE/queue" LOGDIR="$SQ_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="slack-bot-token-for-tests" SLACK_ENGINEERING_CHANNEL="C0TEST" SLACK_WEBHOOK_URL="https://example.invalid/hook" "$SUP_SQ" >/dev/null 2>&1
}
ufd_again() {  # let the next tick run the digest again (it is throttled to once per 600 s)
  python3 -c "import os,sys,time; t=time.time()-601; os.utime(sys.argv[1], (t, t))" "$SQ_PIPE/stale-work-digest.stamp"
}
ufd_lines() { sq_log | grep 'feedback unowned'; }
ufd_slack() { grep -c 'feedback tickets with no owner' "$SQ_GH/curl-calls.log"; }
ufd_stamp() { printf '%s' "$SQ_PIPE/stale-feedback-project-a_repo-a.notified"; }
H5=$((5 * 3600))

test_ufd_i_ii_intake_issue_reported_only_when_idle_and_unclaimed() {
  ufd_env
  ufd_ticket intake 7 "$H5" user-feedback-intake                       # (i) idle 5h, no state
  ufd_ticket intake 8 3600 user-feedback-intake                        # (ii) idle 1h
  ufd_ticket intake 9 "$H5" user-feedback-intake agent-in-progress     # claimed on some host
  ufd_tick
  local lines; lines=$(ufd_lines)
  sq_cleanup
  assert_contains "$lines" "[stale-digest] project-a/repo-a#7 — feedback unowned 5h: intake not picked up" "(i) idle 5h, unclaimed: reported" || return 1
  assert_not_contains "$lines" "#8 " "(ii) idle 1h: not reported" || return 1
  assert_not_contains "$lines" "#9 " "an intake issue carrying agent-in-progress is not reported" || return 1
  assert_eq "$(printf '%s\n' "$lines" | grep -c .)" "1" "exactly one finding" || return 1
}

test_ufd_iii_feedback_with_an_owner_label_is_not_reported_and_costs_no_comments_read() {
  ufd_env
  ufd_ticket feedback 11 "$H5" user-feedback agent-go                  # (iii)
  ufd_ticket feedback 21 "$H5" user-feedback agent-in-progress
  ufd_ticket feedback 22 "$H5" user-feedback agent-proposed
  ufd_ticket feedback 23 "$H5" user-feedback user-feedback-needs-spec
  ufd_ticket feedback 24 3600 user-feedback                            # no label, but idle 1h only
  ufd_ticket feedback 25 "$H5" user-feedback                           # control: idle, no owner label
  ufd_tick
  local lines reads; lines=$(ufd_lines); reads=$(grep -cE '/issues/(11|21|22|23|24)/comments' "$SQ_GH/gh-calls.log")
  sq_cleanup
  assert_contains "$lines" "project-a/repo-a#25 — feedback unowned 5h: never started" "control: the idle ticket with no owner label is reported" || return 1
  assert_eq "$(printf '%s\n' "$lines" | grep -c .)" "1" "(iii) agent-go / agent-in-progress / agent-proposed / needs-spec / fresh: none reported by this finding" || return 1
  assert_eq "$reads" "0" "the comments read happens only after the cheaper checks passed" || return 1
}

test_ufd_iv_feedback_never_started() {
  ufd_env
  ufd_ticket feedback 12 "$H5" user-feedback bug                       # (iv) no approval label, no comments
  ufd_tick
  local lines reads; lines=$(ufd_lines); reads=$(grep -c '/issues/12/comments' "$SQ_GH/gh-calls.log")
  sq_cleanup
  assert_contains "$lines" "[stale-digest] project-a/repo-a#12 — feedback unowned 5h: never started (no approval label, no marker)" "(iv) reported as never started" || return 1
  assert_eq "$reads" "1" "(iv) one comments read for the candidate" || return 1
}

test_ufd_v_vi_vii_gate_marker_decides() {
  ufd_env
  ufd_ticket feedback 13 "$H5" user-feedback; ufd_marker 13 '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'   # (v) a gate: JP owns it
  ufd_ticket feedback 14 "$H5" user-feedback; ufd_marker 14 '**[deployer] DEPLOYED TO STAGING**'              # (vi) done
  ufd_ticket feedback 15 "$H5" user-feedback; ufd_marker 15 '**[fullstack-developer] IMPLEMENTED**'           # (vii) mid-pipeline, no run state
  ufd_ticket feedback 16 "$H5" user-feedback; ufd_marker 16 '**[fullstack-developer] BLOCKED**'               # a BLOCKED is a gate too
  ufd_tick
  local lines; lines=$(ufd_lines)
  sq_cleanup
  assert_not_contains "$lines" "#13 " "(v) MOCKUPS PENDING APPROVAL is a gate: not reported" || return 1
  assert_not_contains "$lines" "#14 " "(vi) DEPLOYED TO STAGING is done: not reported" || return 1
  assert_contains "$lines" "[stale-digest] project-a/repo-a#15 — feedback unowned 5h: stopped mid-pipeline after **[fullstack-developer] IMPLEMENTED**" "(vii) reported as stopped mid-pipeline" || return 1
  assert_not_contains "$lines" "#16 " "a BLOCKED gate is not reported" || return 1
  assert_eq "$(printf '%s\n' "$lines" | grep -c .)" "1" "exactly one finding" || return 1
}

test_ufd_local_run_state_means_owned() {
  ufd_env
  ufd_ticket intake 7 "$H5" user-feedback-intake
  ufd_ticket feedback 12 "$H5" user-feedback
  ufd_ticket feedback 15 "$H5" user-feedback; ufd_marker 15 '**[fullstack-developer] IMPLEMENTED**'
  ufd_ticket feedback 17 "$H5" user-feedback; ufd_marker 17 '**[fullstack-developer] IMPLEMENTED**'
  ufd_ticket feedback 18 "$H5" user-feedback; ufd_marker 18 '**[fullstack-developer] IMPLEMENTED**'   # control: no local state
  # a live intake run of #7 and a live spec run of #12 on this host
  local k
  for k in intake-project-a_repo-a-7 spec-project-a_repo-a-12; do
    sleep 300 & RUNNING_PIDS="$RUNNING_PIDS $!"
    echo "$!" > "$SQ_PIPE/$k.pid"; echo "project-a/repo-a ${k##*-}" > "$SQ_PIPE/$k.id"; echo "$SQ_REPO" > "$SQ_PIPE/$k.path"
  done
  mk_running "$SQ_PIPE" 15 "$SQ_REPO"                                   # a live orchestrator
  mk_held "$SQ_PIPE" 17 "$SQ_REPO"                                      # a hold (neutralised like the #491 fixtures)
  touch "$(rkp "$SQ_PIPE/orch-17.label-cleared")"; echo 3 > "$(rkp "$SQ_PIPE/orch-17.autoretry")"
  printf '%s Pipeline #17 parked, auto-retry (ci_red) — x\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-17.alert")"
  ufd_tick
  local lines; lines=$(ufd_lines)
  sq_cleanup
  assert_contains "$lines" "project-a/repo-a#18 — feedback unowned 5h: stopped mid-pipeline" "control: the ticket with no local state is reported" || return 1
  assert_not_contains "$lines" "#7 " "a ticket with a local intake run is owned" || return 1
  assert_not_contains "$lines" "#12 " "a ticket with a local spec run is owned" || return 1
  assert_not_contains "$lines" "#15 " "a ticket with a live orchestrator is owned" || return 1
  assert_not_contains "$lines" "#17 " "a ticket held on this host is owned" || return 1
}

test_ufd_queued_launch_means_owned() {
  ufd_env
  ufd_ticket feedback 19 "$H5" user-feedback; ufd_marker 19 '**[fullstack-developer] IMPLEMENTED**'
  ufd_ticket feedback 18 "$H5" user-feedback; ufd_marker 18 '**[fullstack-developer] IMPLEMENTED**'   # control: nothing queued
  python3 -c "
import json, sys, time
json.dump({'issue': '19', 'repo': sys.argv[1], 'extra': '', 'reason': 'auto-restart', 'queued_at': '2026-01-01T00:00:00Z', 'not_before': int(time.time()) + 3600}, open(sys.argv[2], 'w'))
" "$SQ_REPO" "$SQ_PIPE/queue/orch-project-a_repo-a-19.json"
  ufd_tick
  local lines queued; lines=$(ufd_lines); queued=$(sq_present "$SQ_PIPE/queue/orch-project-a_repo-a-19.json")
  sq_cleanup
  assert_eq "$queued" "present" "precondition: the launch is still queued after the tick" || return 1
  assert_contains "$lines" "project-a/repo-a#18 — feedback unowned 5h: stopped mid-pipeline" "control: the ticket with nothing queued is reported" || return 1
  assert_not_contains "$lines" "#19 " "a ticket with a queued launch on this host is owned" || return 1
}

test_ufd_issue_in_both_lists_is_reported_once() {
  ufd_env
  ufd_ticket intake 7 "$H5" user-feedback user-feedback-intake         # re-queued for intake: carries both labels
  ufd_ticket feedback 7 "$H5" user-feedback user-feedback-intake
  ufd_tick
  local lines; lines=$(ufd_lines)
  sq_cleanup
  assert_eq "$(printf '%s\n' "$lines" | grep -c .)" "1" "one finding for the ticket" || return 1
  assert_contains "$lines" "#7 — feedback unowned 5h: intake not picked up" "judged as an intake ticket" || return 1
}

test_ufd_viii_list_read_failure_logs_and_alerts_once() {
  ufd_env
  ufd_ticket intake 7 "$H5" user-feedback-intake
  touch "$SQ_GH/ufd-list-fail"
  ufd_tick
  local log curl sha stamp
  log=$(sq_log); curl=$(cat "$SQ_GH/curl-calls.log"); stamp=$(sq_present "$(ufd_stamp)")
  sha=$(git -C "$HERE_UFD" rev-parse HEAD 2>/dev/null || echo unknown)
  sq_cleanup
  assert_contains "$log" "[stale-digest] project-a/repo-a — feedback list read failed" "(viii) read failed line" || return 1
  assert_contains "$log" "feedback list read failed; release=$sha environment=$(hostname -s) route=supervisor-tick" "(viii) tagged: release = commit SHA, environment, route" || return 1
  assert_eq "$(printf '%s\n' "$curl" | grep -c 'example.invalid/hook')" "1" "(viii) one sw_alert through the existing webhook" || return 1
  assert_contains "$curl" "stale-work digest error: feedback list (project-a/repo-a)" "(viii) the recorded Slack payload names the failed read" || return 1
  assert_not_contains "$log" "feedback unowned" "(viii) nothing is reported from an unreadable list" || return 1
  assert_eq "$stamp" "absent" "(viii) no Slack stamp from an unreadable list" || return 1
}

test_ufd_marker_read_failure_logs_alerts_and_does_not_report() {
  ufd_env
  ufd_ticket feedback 12 "$H5" user-feedback
  ufd_ticket feedback 15 "$H5" user-feedback; ufd_marker 15 '**[fullstack-developer] IMPLEMENTED**'
  echo 1 > "$SQ_GH/gh-issue-view-rc-12"
  ufd_tick
  local log curl lines slack; log=$(sq_log); curl=$(cat "$SQ_GH/curl-calls.log"); lines=$(ufd_lines); slack=$(ufd_slack)
  sq_cleanup
  assert_contains "$log" "[stale-digest] project-a/repo-a#12 — feedback marker read failed; release=" "comments read failed: tagged line" || return 1
  assert_contains "$curl" "stale-work digest error: feedback marker (project-a/repo-a#12)" "comments read failed: sw_alert" || return 1
  assert_not_contains "$lines" "#12 " "an unreadable ticket is not reported as unowned" || return 1
  assert_contains "$lines" "#15 " "the readable ticket of the same run is still logged" || return 1
  assert_eq "$slack" "0" "the per-repo Slack message waits for a run where every ticket could be judged" || return 1
}

test_ufd_slack_once_per_set_again_on_change_and_after_24h() {
  ufd_env
  ufd_ticket intake 7 "$H5" user-feedback-intake
  ufd_ticket feedback 12 "$H5" user-feedback
  ufd_ticket feedback 15 "$H5" user-feedback; ufd_marker 15 '**[fullstack-developer] IMPLEMENTED**'
  ufd_tick
  local n1 curl1 stamp1; n1=$(ufd_slack); curl1=$(cat "$SQ_GH/curl-calls.log"); stamp1=$(cat "$(ufd_stamp)" 2>/dev/null)
  ufd_again; ufd_tick
  local n2; n2=$(ufd_slack)
  ufd_ticket intake 30 "$H5" user-feedback-intake                      # the set changes
  ufd_again; ufd_tick
  local n3 curl3; n3=$(ufd_slack); curl3=$(cat "$SQ_GH/curl-calls.log")
  python3 -c "import os,sys,time; t=time.time()-25*3600; os.utime(sys.argv[1], (t, t))" "$(ufd_stamp)"   # same set, a day later
  ufd_again; ufd_tick
  local n4; n4=$(ufd_slack)
  echo '[]' > "$SQ_GH/ufd-intake.json"; echo '[]' > "$SQ_GH/ufd-feedback.json"                         # everything got an owner
  ufd_again; ufd_tick
  local n5 stamp5 calls mutating; n5=$(ufd_slack); stamp5=$(sq_present "$(ufd_stamp)")
  calls=$(gh_calls "$SQ_GH"); mutating=$(printf '%s\n' "$calls" | grep -E 'issue edit|issue comment|issue close|pr merge|label (add|delete)|-X[[:space:]]+(POST|PATCH|PUT|DELETE)')
  sq_cleanup
  assert_eq "$n1" "1" "Slack: first run with unowned tickets posts one message" || return 1
  assert_contains "$curl1" "chat.postMessage" "Slack: through notify_engineering" || return 1
  assert_contains "$curl1" ":mag: <https://github.com/project-a/repo-a/issues/0|#0> — 3 feedback tickets with no owner for more than 4h: #7, #12, #15" "Slack: payload text (count, hours, sorted refs)" || return 1
  assert_eq "$stamp1" "#7 #12 #15" "Slack: the stamp holds the sorted refs" || return 1
  assert_eq "$n2" "1" "Slack: a second digest run with the same set posts nothing" || return 1
  assert_eq "$n3" "2" "Slack: a changed set posts a second message" || return 1
  assert_contains "$curl3" "4 feedback tickets with no owner for more than 4h: #7, #12, #15, #30" "Slack: the new set" || return 1
  assert_eq "$n4" "3" "Slack: the same set is repeated once 24h have passed" || return 1
  assert_eq "$n5" "3" "Slack: an empty set posts nothing" || return 1
  assert_eq "$stamp5" "absent" "Slack: the stamp is dropped once nothing is unowned" || return 1
  assert_eq "$mutating" "" "AC8: the digest makes no GitHub write (no issue edit / issue comment, no -X write) over five runs" || return 1
}

test_ufd_slack_lists_first_thirty_then_a_count() {
  ufd_env
  local i; for i in $(seq 101 132); do ufd_ticket intake "$i" "$H5" user-feedback-intake; done
  ufd_tick
  local curl; curl=$(cat "$SQ_GH/curl-calls.log")
  sq_cleanup
  assert_contains "$curl" "32 feedback tickets with no owner for more than 4h: #101, #102, " "Slack: count and the first refs" || return 1
  assert_contains "$curl" "#129, #130, +2 more" "Slack: first 30 refs, then +<k> more" || return 1
  assert_not_contains "$curl" "#131" "Slack: the 31st ref is not listed" || return 1
}

echo "-- stale-work digest: unowned feedback (#676)"
run_test test_ufd_i_ii_intake_issue_reported_only_when_idle_and_unclaimed
run_test test_ufd_iii_feedback_with_an_owner_label_is_not_reported_and_costs_no_comments_read
run_test test_ufd_iv_feedback_never_started
run_test test_ufd_v_vi_vii_gate_marker_decides
run_test test_ufd_local_run_state_means_owned
run_test test_ufd_queued_launch_means_owned
run_test test_ufd_issue_in_both_lists_is_reported_once
run_test test_ufd_viii_list_read_failure_logs_and_alerts_once
run_test test_ufd_marker_read_failure_logs_alerts_and_does_not_report
run_test test_ufd_slack_once_per_set_again_on_change_and_after_24h
run_test test_ufd_slack_lists_first_thirty_then_a_count
