# Issue #677 Part A — a start-gate is met when the dependency is closed OR shipped to the integration branch
# (dep-shipped.sh), and a run held on a start-gate resumes by itself.
#
#   goal eval   _goal_ticket_eval: open + shipped -> active; open + not shipped -> waiting_jp "(not shipped yet)"; read error -> 1
#   promote     promote_deferred: open + shipped -> agent-go + "… — start-gate #N shipped" NOTE, once; not shipped / not planned -> untouched
#   hold        step 1 structural stop: unmet start-gate refs -> orch-<rk>.startgate + "[held] … resumes when shipped"
#   resume      step 1b: all refs met -> NOTE, queue entry, .held/.startgate gone; throttled; NOTE failure / read error stay held
#   tombstones  a launch clears .startgate and .jp-reminded
#   docs        AC4 (orchestrator.md) and AC5 (product-manager.md, SKILL.md, README.md)
#
# Harnesses reused, each loaded without running its cases when this file runs first or on its own:
#   ar2_* / sq_*  (test-supervisor-auto-retry.sh)   whole supervisor ticks, per-issue fake gh
#   pc_* / si_*   (test-issue315-promote-deferred-child.sh, test-intake-supervisor.sh)   promote ticks
#   ro_*          (test-goal-sync-reads.sh)          goal-lib functions against a counting fake gh
# In the ar2 fake the repo always has a `staging` branch and `gh pr list --state merged` answers one PR whose head is the
# content of $SQ_GH/gh-pr-merged (absent = none), so "#5 shipped" is `echo issue-5-x > gh-pr-merged`.
# Prefix sg_ / SG_. Placeholder repo names only.

HERE_SG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SG=$(cd "$HERE_SG/../../.." && pwd)
sg_load() {  # <probe function> <test file> — load a harness file with run_test stubbed out
  declare -f "$1" >/dev/null 2>&1 && return 0
  eval "sg_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_SG/$2"
  eval "$(declare -f sg_real_run_test | sed '1s/sg_real_run_test/run_test/')"
}
sg_load ar2_fixture test-supervisor-auto-retry.sh
sg_load si_env test-intake-supervisor.sh
sg_load pc_env test-issue315-promote-deferred-child.sh
sg_load ro_setup test-goal-sync-reads.sh

SG_READY='**[product-manager] READY FOR ENGINEERING**'
SG_NOTE='**[supervisor] NOTE** start-gate cleared: #5 — relaunching'

# ============================================================== goal eval ==========================================
# sg_goal <gate state open|closed> — approved, never-started #6 whose body names "Depends on #5 for starting work"
sg_goal() {
  ro_setup
  jq -n '[{number:6,state:"open",labels:[{name:"agent-go"}],user:{login:"jpmoya"},body:"Why\n\nDepends on #5 for starting work"}]' > "$RO_DIR/list-proj_repo-a.json"
  echo '[]' > "$RO_DIR/comments-proj_repo-a-6.json"; echo '[]' > "$RO_DIR/comments-proj_repo-a-5.json"
  jq -n --arg s "$1" '{number:5,state:$s,labels:[],user:{login:"jpmoya"},body:""}' > "$RO_DIR/issue-proj_repo-a-5.json"
}

test_sg_goal_open_shipped_gate_is_active() {
  sg_goal open; local rc=0
  echo '[{"number":70,"headRefName":"issue-5-migration"}]' > "$RO_DIR/merged-prs.json"
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "$RO_RC" "0" "eval exits 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "${RO_OUT%%	*}" "active" "open + shipped start-gate is treated like closed ($RO_OUT)" || rc=1
  ro_teardown; return $rc
}

test_sg_goal_open_unshipped_gate_is_waiting_with_the_new_reason() {
  sg_goal open; local rc=0
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "$RO_RC" "0" "eval exits 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "$RO_OUT" "waiting_jp	OPEN	none	waits on #5 (not shipped yet)" "open + not shipped -> waiting_jp with the new reason" || rc=1
  ro_teardown; return $rc
}

test_sg_goal_dep_read_error_returns_1() {
  sg_goal open; local rc=0
  touch "$RO_DIR/pr-fail"
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "$RO_RC" "1" "a dep-shipped read error is a failed evaluation, never waiting and never active ($RO_OUT)" || rc=1
  ro_teardown; return $rc
}

test_sg_goal_closed_gate_is_active_without_a_shipped_lookup() {
  sg_goal closed; local rc=0
  ro_run "_goal_ticket_eval proj/repo-a 6"
  assert_eq "${RO_OUT%%	*}" "active" "closed gate: active, as before" \
    && assert_eq "$(ro_count '^pr |branches/staging')" "0" "closed gate: dep-shipped.sh is not consulted" || rc=1
  ro_teardown; return $rc
}

# ============================================================== promote ============================================
# sg_pc_env — pc_env + a gh wrapper serving dep-shipped.sh's merged-PR list from $SI_D/merged.json (pr-fail = the read fails)
sg_pc_env() {
  pc_env "$@" || return 1
  mv "$SI_D/gh" "$SI_D/gh-pc"
  cat > "$SI_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
case "$1 $2" in
  "pr list"|"pr view")
    echo "$*" >> "$D/gh-calls.log"
    [ -f "$D/pr-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    [ "$2" = list ] && { cat "$D/merged.json" 2>/dev/null || echo '[]'; exit 0; }
    exit 1 ;;
esac
exec "$D/gh-pc" "$@"
X
  chmod +x "$SI_D/gh"
}
SG_PROMO='**[supervisor] NOTE** approval inherited from project-a/repo-a#5 — start-gate #10 shipped'

test_sg_promote_open_shipped_gate_promotes_once_with_the_shipped_note() {
  sg_pc_env; local R=project-a/repo-a
  pc_issue 10 $R OPEN "gate"
  pc_issue 21 $R OPEN "child" agent-proposed enhancement; pc_note 21 $R 10
  echo '[{"number":70,"headRefName":"issue-10-migration"}]' > "$SI_D/merged.json"
  si_tick
  local l1 p1; l1=$(si_labels 21); p1=$(pc_promos 21)
  si_tick
  local l2 n2 adds; l2=$(si_labels 21); n2=$(pc_promos 21 | grep -c .); adds=$(grep -c -- '--add-label agent-go' "$SI_D/gh-calls.log")
  # the label was consumed by a launch and came back as agent-proposed: the NOTE alone must stop a second promotion
  jq 'map(if .number==21 then .labels=[{name:"agent-proposed"}] else . end)' "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
  si_tick
  local l3 n3; l3=$(si_labels 21); n3=$(pc_promos 21 | grep -c .)
  si_cleanup
  assert_eq "$l1" "agent-go,enhancement" "open + shipped gate: agent-go added, agent-proposed removed" || return 1
  assert_eq "$p1" "$SG_PROMO" "the promotion NOTE says the start-gate shipped" || return 1
  assert_eq "$l2" "agent-go,enhancement" "second tick leaves labels alone" || return 1
  assert_eq "$n2" "1" "second tick posts no second NOTE" || return 1
  assert_eq "$adds" "1" "agent-go added exactly once across two ticks" || return 1
  assert_eq "$l3" "agent-proposed" "idempotency filter accepts the 'shipped' NOTE: no re-promotion once the label is gone" || return 1
  assert_eq "$n3" "1" "still one promotion NOTE" || return 1
}

test_sg_promote_open_unshipped_gate_is_untouched() {
  sg_pc_env; local R=project-a/repo-a
  pc_issue 10 $R OPEN "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  echo '[{"number":70,"headRefName":"issue-100-other"}]' > "$SI_D/merged.json"
  pc_control
  si_tick
  local l p lc; l=$(si_labels 21); p=$(pc_promos 21); lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: a promotable child was promoted" || return 1
  assert_eq "$l" "agent-proposed" "open + not shipped: labels untouched" || return 1
  assert_eq "$p" "" "open + not shipped: no promotion NOTE" || return 1
}

test_sg_promote_not_planned_gate_is_untouched_even_when_a_pr_merged() {
  sg_pc_env; local R=project-a/repo-a
  pc_issue 10 $R NOT_PLANNED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  echo '[{"number":70,"headRefName":"issue-10-migration"}]' > "$SI_D/merged.json"
  pc_control
  si_tick
  local l p lc; l=$(si_labels 21); p=$(pc_promos 21); lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: a promotable child was promoted" || return 1
  assert_eq "$l" "agent-proposed" "closed as not planned: left for JP (unchanged)" || return 1
  assert_eq "$p" "" "closed as not planned: no promotion NOTE" || return 1
}

test_sg_promote_shipped_lookup_error_is_logged_with_tags_and_not_promoted() {
  sg_pc_env; local R=project-a/repo-a
  pc_issue 10 $R OPEN "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  touch "$SI_D/pr-fail"
  si_tick
  local l line; l=$(si_labels 21); line=$(pc_slog | grep -F '[promote]' | grep -F "$R#21" | grep -F 'state read failed' | head -1)
  si_cleanup
  assert_eq "$l" "agent-proposed" "read error: not promoted" || return 1
  assert_ne "$line" "" "read error: [promote] … state read failed is logged" || return 1
  assert_contains "$line" "route=supervisor/promote" "route tag" || return 1
  assert_contains "$line" "environment=" "environment tag" || return 1
  case "$line" in *release=unknown*|*release=\ *) fail "release must be the commit SHA: $line"; return 1 ;; esac
  assert_contains "$line" "release=" "release tag" || return 1
}

# ============================================================== hold + resume ======================================
# sg_run_env [open|full] — ar2 world; `issue comment` of the start-gate NOTE fails while $SQ_GH/sg-comment-fail exists
sg_run_env() {
  local mode=${1:-open}
  sq_env "$mode"; [ "$mode" = open ] && sq_free_slots
  ar2_install_gh
  mv "$SQ_GH/gh" "$SQ_GH/gh-ar2"
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "issue comment"*"start-gate cleared"*)
    if [ -f "$HERE/sg-comment-fail" ]; then printf '%s\n' "FAILED $*" >> "$HERE/gh-calls.log"; echo "HTTP 500" >&2; exit 1; fi ;;
esac
exec "$HERE/gh-ar2" "$@"
GH_EOF
  chmod +x "$SQ_GH/gh"
  : > "$SQ_PIPE/claude.calls"
  jq -nc --arg b "$SG_READY" '[{body:$b, createdAt:"2026-09-20T10:00:00Z", author:{login:"x"}}]' > "$SQ_GH/gh-issue-comments-json-42"
}
# sg_exited_structural <issue body> — run #42 exited (launched 600 s ago) after a structural validate fail logged 60 s ago
sg_exited_structural() {
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  printf '%s\n' "$1" > "$SQ_GH/gh-issue-body-42"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"ts":"%s","host":"h","event":"validate","repo":"project-a/repo-a","issue":42,"stage":"structural","result":"fail","reason":"start-gate #5 still open"}\n' \
    "$(sq_iso_ago 60)" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
}
# sg_held_on <refs, one per line> — a run already held on a start-gate (what step 1 leaves behind), no throttle stamp
sg_held_on() {
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  printf '%s\n' "$1" > "$(rkp "$SQ_PIPE/orch-42.startgate")"
  rm -f "$(rkp "$SQ_PIPE/orch-42.autoretry-check")"
}
sg_file() { rkp "$SQ_PIPE/orch-42.$1"; }
sg_startgate() { cat "$(sg_file startgate)" 2>/dev/null || echo ABSENT; }
sg_notes() { grep -c '^issue comment.*start-gate cleared' "$SQ_GH/gh-calls.log" 2>/dev/null || true; }
sg_evals() { grep -c '^pr list' "$SQ_GH/gh-calls.log" 2>/dev/null || true; }   # one merged-PR list per dep-shipped evaluation here
sg_unthrottle() { rm -f "$(sg_file autoretry-check)"; }
sg_curl_log() {
  echo 'SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X"' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$SQ_GH" > "$SQ_GH/curl"; chmod +x "$SQ_GH/curl"
}

test_sg_structural_stop_on_open_unshipped_gate_writes_startgate() {
  sg_run_env
  sg_exited_structural $'Why\n\nDepends on #5 for starting work'
  ar2_tick
  local held sg log notes q evals
  held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate); log=$(sq_log); notes=$(sg_notes)
  q=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")"); evals=$(sg_evals)
  sq_cleanup
  assert_eq "$held" "present" "structural stop -> .held" || return 1
  assert_eq "$sg" "#5" ".startgate holds the unmet ref, one per line" || return 1
  assert_contains "$log" "[held] #42 — start-gate: waits on #5, resumes when shipped" "the hold is logged as a start-gate wait" || return 1
  assert_eq "$notes" "0" "no NOTE while the gate is unmet" || return 1
  assert_eq "$q" "absent" "no queue entry" || return 1
  assert_eq "$evals" "1" "one evaluation in the tick that holds (step 1b does not re-check it straight away)" || return 1
}

test_sg_hold_then_shipped_resumes_and_launches_exactly_once() {
  sg_run_env
  sg_exited_structural $'Why\n\nDepends on #5 for starting work'
  ar2_tick
  assert_eq "$(sg_startgate)" "#5" "control: held on #5" || { sq_cleanup; return 1; }
  echo issue-5-x > "$SQ_GH/gh-pr-merged"; sg_unthrottle
  ar2_tick
  local n notes held sg calls log
  n=$(ar2_launches); notes=$(sg_notes); held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate); calls=$(gh_calls "$SQ_GH"); log=$(sq_log)
  assert_contains "$calls" "issue comment 42 --body $SG_NOTE" "NOTE posted on the issue" || { sq_cleanup; return 1; }
  assert_eq "$notes" "1" "one NOTE" || { sq_cleanup; return 1; }
  assert_eq "$held" "absent" ".held removed" || { sq_cleanup; return 1; }
  assert_eq "$sg" "ABSENT" ".startgate removed" || { sq_cleanup; return 1; }
  assert_eq "$n" "1" "the queued relaunch is launched once" || { sq_cleanup; return 1; }
  assert_contains "$log" "[startgate-resume] #42" "resume is logged" || { sq_cleanup; return 1; }
  sg_unthrottle; ar2_tick; sg_unthrottle; ar2_tick
  notes=$(sg_notes); log=$(sq_log)
  sq_cleanup
  assert_eq "$notes" "1" "later ticks post no second NOTE (a cleared gate resumes once)" || return 1
  assert_eq "$(printf '%s\n' "$log" | grep -c '\[startgate-resume\] #42')" "1" "one resume per cleared gate" || return 1
}

test_sg_resume_writes_the_queue_entry_like_the_loopcap_resume() {
  sg_run_env full   # no free slot: the queue entry stays visible
  sg_held_on "#5"
  echo issue-5-x > "$SQ_GH/gh-pr-merged"
  ar2_tick
  local reason nb issue held sg
  reason=$(sq_queue_field reason); nb=$(sq_queue_field not_before); issue=$(sq_queue_field issue)
  held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate)
  sq_cleanup
  assert_eq "$reason" "queued" "queue entry reason" || return 1
  assert_eq "$nb" "0" "queue entry is due at once" || return 1
  assert_eq "$issue" "42" "queue entry names the issue" || return 1
  assert_eq "$held" "absent" ".held removed" || return 1
  assert_eq "$sg" "ABSENT" ".startgate removed" || return 1
}

test_sg_closed_gate_resumes_too() {
  sg_run_env full
  sg_held_on "#5"
  echo CLOSED > "$SQ_GH/gh-issue-state-5"
  ar2_tick
  local q evals; q=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")"); evals=$(sg_evals)
  sq_cleanup
  assert_eq "$q" "present" "a closed dependency meets the gate" || return 1
  assert_eq "$evals" "0" "closed: dep-shipped.sh is not consulted" || return 1
}

test_sg_still_unshipped_stays_held_without_a_note() {
  sg_run_env
  sg_held_on "#5"
  ar2_tick
  local n held sg notes evals; n=$(ar2_no_launch); held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate); notes=$(sg_notes); evals=$(sg_evals)
  sq_cleanup
  assert_eq "$evals" "1" "control: the gate was evaluated" || return 1
  assert_eq "$held" "present" "stays held" || return 1
  assert_eq "$sg" "#5" ".startgate kept" || return 1
  assert_eq "$notes" "0" "no NOTE" || return 1
  assert_eq "$n" "0" "no relaunch" || return 1
}

test_sg_two_gates_one_unmet_stays_held() {
  sg_run_env
  sg_held_on $'#5\nproject-b/repo-b#6'
  echo issue-5-x > "$SQ_GH/gh-pr-merged"   # #5 shipped, project-b/repo-b#6 (head issue-6-) is not
  ar2_tick
  local held notes; held=$(sq_present "$(sg_file held)"); notes=$(sg_notes)
  sq_cleanup
  assert_eq "$held" "present" "one unmet ref keeps the run held" || return 1
  assert_eq "$notes" "0" "no NOTE" || return 1
}

test_sg_two_passes_inside_the_throttle_make_one_evaluation() {
  sg_run_env
  sg_held_on "#5"
  ar2_tick
  local first second third; first=$(sg_evals)
  ar2_tick
  second=$(sg_evals)
  python3 -c 'import os,sys,time; t=time.time()-31*60; os.utime(sys.argv[1],(t,t))' "$(sg_file autoretry-check)"
  ar2_tick
  third=$(sg_evals)
  sq_cleanup
  assert_eq "$first" "1" "control: first pass evaluates" || return 1
  assert_eq "$second" "1" "second pass inside 1800 s does not evaluate again" || return 1
  assert_eq "$third" "2" "after 31 min the gate is evaluated again" || return 1
}

test_sg_note_post_failure_stays_held() {
  sg_run_env
  sg_held_on "#5"
  echo issue-5-x > "$SQ_GH/gh-pr-merged"; touch "$SQ_GH/sg-comment-fail"
  ar2_tick
  local n held sg log q
  n=$(ar2_no_launch); held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate); log=$(sq_log); q=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")")
  sq_cleanup
  assert_eq "$held" "present" "NOTE not posted: stays held" || return 1
  assert_eq "$sg" "#5" ".startgate kept for the next pass" || return 1
  assert_eq "$q" "absent" "no queue entry" || return 1
  assert_eq "$n" "0" "no relaunch" || return 1
  local line; line=$(printf '%s\n' "$log" | grep -F '[startgate-resume] #42' | grep -F 'NOTE post failed' | head -1)
  assert_ne "$line" "" "the failed NOTE post is logged" || return 1
  assert_contains "$line" "route=supervisor/startgate" "route tag" || return 1
  assert_contains "$line" "release=" "release tag" || return 1
  assert_contains "$line" "environment=" "environment tag" || return 1
}

test_sg_read_error_in_the_resume_pass_logs_alerts_once_and_stays_held() {
  sg_run_env
  sg_held_on "#5"
  echo 4 > "$SQ_GH/gh-pr-fail"; sg_curl_log
  ar2_tick
  local n held log calls line
  n=$(ar2_no_launch); held=$(sq_present "$(sg_file held)"); log=$(sq_log)
  calls=$(grep 'hooks.slack.test' "$SQ_GH/curl.calls" 2>/dev/null | grep -F 'startgate')
  sq_cleanup
  line=$(printf '%s\n' "$log" | grep -F '[startgate-resume] #42' | grep -F 'read failed' | head -1)
  assert_ne "$line" "" "[startgate-resume] … read failed is logged" || return 1
  assert_contains "$line" "#5" "the line names the dependency ref" || return 1
  assert_contains "$line" "route=supervisor/startgate" "route tag" || return 1
  assert_contains "$line" "environment=" "environment tag" || return 1
  case "$line" in *release=unknown*) fail "release must be the commit SHA: $line"; return 1 ;; esac
  assert_contains "$line" "release=" "release tag" || return 1
  assert_eq "$(printf '%s\n' "$calls" | grep -c .)" "1" "exactly one autoretry_alert for the failed read" || return 1
  assert_contains "$calls" "route=supervisor/startgate" "the alert carries the route tag" || return 1
  assert_not_contains "$log$calls" "ghp_FAKESECRET123" "no secret from the failing call in the log or the alert" || return 1
  assert_eq "$held" "present" "read error: stays held" || return 1
  assert_eq "$n" "0" "read error: no relaunch" || return 1
}

test_sg_read_error_at_hold_time_writes_every_ref() {
  sg_run_env
  sg_exited_structural $'Depends on #5 for starting work\nDepends on project-b/repo-b#6 for starting work\nDepends on #9 for merging'
  echo CLOSED > "$SQ_GH/gh-issue-state-6"   # met, but the pass cannot finish: #5's lookup fails
  echo 4 > "$SQ_GH/gh-pr-fail"
  ar2_tick
  local held sg; held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate)
  sq_cleanup
  assert_eq "$held" "present" "held" || return 1
  assert_eq "$sg" $'#5\nproject-b/repo-b#6' "read error: every start-gate ref is written (checked again later); the merge-gate is not a start-gate" || return 1
}

# a structural stop that is not a start-gate wait (no start-gate line, or every gate already met) is never relaunched by 1b
sg_never_resumed() {  # <body> <label>
  sg_run_env
  sg_exited_structural "$1"
  ar2_tick
  local held sg n log
  held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate)
  sg_unthrottle; ar2_tick; sg_unthrottle; ar2_tick
  n=$(ar2_no_launch); log=$(sq_log)
  local held2; held2=$(sq_present "$(sg_file held)")
  sq_cleanup
  assert_eq "$held" "present" "$2: structural stop is held" || return 1
  assert_eq "$sg" "ABSENT" "$2: no .startgate" || return 1
  assert_eq "$held2" "present" "$2: still held after two more passes" || return 1
  assert_eq "$n" "0" "$2: 1b never relaunches it" || return 1
  assert_not_contains "$log" "[startgate-resume]" "$2: no start-gate resume" || return 1
  assert_contains "$log" "[held] #42 — structural stop" "$2: logged as a plain structural stop" || return 1
}
test_sg_structural_stop_without_a_start_gate_line_is_never_resumed() {
  sg_never_resumed $'Why\n\nDepends on #5 for merging' "no start-gate line"
}
test_sg_structural_stop_with_every_gate_met_is_never_resumed() {
  sg_run_env
  echo issue-5-x > "$SQ_GH/gh-pr-merged"   # #5 open but shipped: the gate is met, so the stop has another cause
  sg_exited_structural $'Why\n\nDepends on #5 for starting work'
  ar2_tick
  local sg n held; sg=$(sg_startgate)
  sg_unthrottle; ar2_tick
  n=$(ar2_no_launch); held=$(sq_present "$(sg_file held)")
  sq_cleanup
  assert_eq "$sg" "ABSENT" "all gates met: no .startgate" || return 1
  assert_eq "$held" "present" "all gates met: held as a plain structural stop" || return 1
  assert_eq "$n" "0" "all gates met: 1b never relaunches it" || return 1
}

# a new hold never inherits a start-gate file left by an earlier hold: a run parked on a JP gate is not "start-gate resumed"
test_sg_stale_startgate_does_not_resume_a_later_jp_gate_hold() {
  sg_run_env
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 3600 > "$(rkp "$SQ_PIPE/orch-42.start")"; sq_iso_ago 3600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  jq -nc '[{body:"**[infra-operator] AWAITING GO**", createdAt:"2026-09-20T10:00:00Z", author:{login:"x"}}]' > "$SQ_GH/gh-issue-comments-json-42"
  echo "#5" > "$(rkp "$SQ_PIPE/orch-42.startgate")"; echo CLOSED > "$SQ_GH/gh-issue-state-5"   # stale file whose gate is met
  ar2_tick; sg_unthrottle; ar2_tick
  local held sg n notes; held=$(sq_present "$(sg_file held)"); sg=$(sg_startgate); n=$(ar2_no_launch); notes=$(sg_notes)
  sq_cleanup
  assert_eq "$held" "present" "the JP gate parks the run" || return 1
  assert_eq "$sg" "ABSENT" "the stale .startgate is dropped when the new hold is created" || return 1
  assert_eq "$notes" "0" "no start-gate NOTE" || return 1
  assert_eq "$n" "0" "no relaunch" || return 1
}

# ============================================================== tombstones =========================================
test_sg_manual_launch_clears_startgate_and_jp_reminded() {
  sq_env open; sq_free_slots
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  echo "#5" > "$(rkp "$SQ_PIPE/orch-42.startgate")"; : > "$(rkp "$SQ_PIPE/orch-42.jp-reminded")"
  local out rc sg jr
  out=$(sq_run "$ORCH_SQ" "$SQ_REPO" 42 2>&1); rc=$?
  sg=$(sq_present "$(sg_file startgate)"); jr=$(sq_present "$(sg_file jp-reminded)")
  sq_cleanup
  assert_exit0 "$rc" "launch exits 0 ($out)" || return 1
  assert_eq "$sg" "absent" "a launch clears .startgate" || return 1
  assert_eq "$jr" "absent" "a launch clears .jp-reminded" || return 1
}
test_sg_dispatch_tombstone_clear_names_both_files() {
  local line; line=$(grep -F 'rm -f "$PIPE/orch-$rk".{stopped,held,done' "$HERE_SG/../supervisor.sh")
  assert_contains "$line" "startgate" "step 5 re-dispatch clears .startgate" || return 1
  assert_contains "$line" "jp-reminded" "step 5 re-dispatch clears .jp-reminded" || return 1
}

# ============================================================== docs (AC4, AC5) ====================================
test_sg_ac4_orchestrator_names_dep_shipped_and_drops_must_be_closed() {
  local orch="$ROOT_SG/agents/orchestrator.md" row
  row=$(grep -F 'Dependency gates:' "$orch" | head -1)
  assert_contains "$row" 'dep-shipped.sh <owner/repo> <N>' "AC4: the start-gate check runs dep-shipped.sh" || return 1
  assert_contains "$row" "~/.claude/skills/orchestrate/dep-shipped.sh" "AC4: by its installed path" || return 1
  if grep -qF 'must be closed' "$orch"; then fail "AC4: orchestrator.md still says a start-gate 'must be closed'"; return 1; fi
  row=$(grep -F '**Structural**' "$orch" | head -1)
  assert_contains "$row" "ships to the integration branch; the supervisor resumes it" "AC4: the structural stop message" || return 1
}
test_sg_ac5_docs_say_shipped_to_the_integration_branch() {
  local f
  for f in agents/product-manager.md skills/orchestrate/SKILL.md README.md; do
    grep -iF 'start-gate' "$ROOT_SG/$f" | grep -qF 'shipped to the integration branch' \
      || { fail "AC5: $f has no start-gate line saying 'shipped to the integration branch'"; return 1; }
  done
  grep -F 'Open start-gate at filing time' "$ROOT_SG/agents/product-manager.md" | grep -qF 'shipped to the integration branch' \
    || { fail "AC5: product-manager.md 'Open start-gate at filing time' rule not updated"; return 1; }
}

run_test test_sg_goal_open_shipped_gate_is_active
run_test test_sg_goal_open_unshipped_gate_is_waiting_with_the_new_reason
run_test test_sg_goal_dep_read_error_returns_1
run_test test_sg_goal_closed_gate_is_active_without_a_shipped_lookup
run_test test_sg_promote_open_shipped_gate_promotes_once_with_the_shipped_note
run_test test_sg_promote_open_unshipped_gate_is_untouched
run_test test_sg_promote_not_planned_gate_is_untouched_even_when_a_pr_merged
run_test test_sg_promote_shipped_lookup_error_is_logged_with_tags_and_not_promoted
run_test test_sg_structural_stop_on_open_unshipped_gate_writes_startgate
run_test test_sg_hold_then_shipped_resumes_and_launches_exactly_once
run_test test_sg_resume_writes_the_queue_entry_like_the_loopcap_resume
run_test test_sg_closed_gate_resumes_too
run_test test_sg_still_unshipped_stays_held_without_a_note
run_test test_sg_two_gates_one_unmet_stays_held
run_test test_sg_two_passes_inside_the_throttle_make_one_evaluation
run_test test_sg_note_post_failure_stays_held
run_test test_sg_read_error_in_the_resume_pass_logs_alerts_once_and_stays_held
run_test test_sg_read_error_at_hold_time_writes_every_ref
run_test test_sg_structural_stop_without_a_start_gate_line_is_never_resumed
run_test test_sg_structural_stop_with_every_gate_met_is_never_resumed
run_test test_sg_stale_startgate_does_not_resume_a_later_jp_gate_hold
run_test test_sg_manual_launch_clears_startgate_and_jp_reminded
run_test test_sg_dispatch_tombstone_clear_names_both_files
run_test test_sg_ac4_orchestrator_names_dep_shipped_and_drops_must_be_closed
run_test test_sg_ac5_docs_say_shipped_to_the_integration_branch
