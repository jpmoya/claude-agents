# Issue #138 (Phase 2 of #134): run_launch / run_exit rows in $LOGDIR/events.jsonl, exit classification,
# limit hold/backoff in the supervisor, `Caused by:` in the PM templates.
#   AC12 weekly limit waits   AC13 history class (+exit pin)   AC14 monthly spend holds
#   AC15 classification       AC16 one row per launch          AC17 run_launch
#   AC18 row shape / logging never blocks                      AC20 PM templates
# Expected values come from the ticket text or hand arithmetic in comments — never from the code.
# Reuses the sq_* harness of test-supervisor-queued-not-counted.sh (sourced here with run_test neutralised,
# as test-supervisor-fast-death-escalates.sh does). All names are rl_/RL_ prefixed. Issue 42, placeholder repos only.
# Bash 3.2 compatible (see the portability test for the banned tools).

HERE_RL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "rl_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_RL/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f rl_real_run_test | sed '1s/rl_real_run_test/run_test/')"
fi
ORCH_RL="$HERE_RL/../orchestrate.sh"
LIB_RL="$HERE_RL/../pipeline-lib.sh"
PM_RL="$HERE_RL/../../../agents/product-manager.md"
RL_HOST=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')

RL_WEEKLY="You've hit your weekly limit · resets 3am (UTC)"
RL_MONTHLY="You've hit your monthly spend limit. Switch to another model, or manage usage credits at https://example.invalid/usage"
RL_OTHER="You've hit your usage limit for today"
RL_NORMAL="All stages finished normally."

# rl_open — open env, stub claude that records each launch in $SQ_GH/launches, no memory floor.
rl_open() {
  sq_env open
  echo 'MEM_FLOOR_MB=0' > "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "$*" >> "$(dirname "$0")/launches"\nexit 0\n' > "$SQ_GH/claude"
  chmod +x "$SQ_GH/claude"
  RL_EV="$SQ_HOME/logs/pipeline/events.jsonl"
}
rl_launches() { local n; n=$(wc -l < "$SQ_GH/launches" 2>/dev/null | tr -d ' '); echo "${n:-0}"; }
rl_wait_launches() {  # rl_wait_launches <n> — up to 8 s for the detached stub to record
  local i=0; while [ "$(rl_launches)" -lt "$1" ] && [ $i -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
}
# rl_rows <event> — all rows of that event, one JSON per line
rl_rows() { jq -c "select(.event==\"$1\")" "$RL_EV" 2>/dev/null; }
rl_count() { rl_rows "$1" | wc -l | tr -d ' '; }
rl_last() { rl_rows "$1" | tail -1; }
rl_f() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }   # rl_f <json> <jq expr>

# rl_exit_fixture <exit: N|none> <log tail text> [noid] — a dead launched run: run-id, .exit, log with an older
# segment (normal sentence), a LAUNCH separator, then the tail text and a blank line. Launched 600 s ago, so
# the run is not transient. Restart state count=1 total=1 on the READY marker.
rl_exit_fixture() {
  local ex=$1 tail_text=$2 noid=${3:-}
  rl_open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  [ "$noid" = noid ] || echo "$RL_HOST-orch-42-1700000000" > "$SQ_PIPE/orch-42.run-id"
  [ "$ex" = none ] || echo "$ex" > "$SQ_PIPE/orch-42.exit"
  printf '%s\n===== [2026-01-01T00:00:00Z] LAUNCH issue=42 reason=manual =====\n%s\n\n' "$RL_NORMAL" "$tail_text" > "$SQ_PIPE/orch-42.log"
  sq_seed_restarts 1 1 "$SQ_READY"
  sq_marker "$SQ_READY"
}
rl_hist() { python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['history'][-1]))" "$SQ_PIPE/orch-42.restarts" 2>/dev/null; }

# ------------------------------------------------------------------------------------------ pipeline_event

test_rl_event_helper_writes_one_valid_row() {
  local d out rc row
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-rl.XXXXXX")
  out=$(LOGDIR="$d" PIPE="$d" bash -c ". '$LIB_RL'; pipeline_event demo --arg a b --argjson n 3; echo rc=\$?" 2>&1)
  row=$(tail -n 1 "$d/events.jsonl" 2>/dev/null)
  local lines; lines=$(wc -l < "$d/events.jsonl" 2>/dev/null | tr -d ' ')
  rm -rf "$d"
  assert_contains "$out" "rc=0" "#138/1: pipeline_event returns 0" || return 1
  assert_eq "$lines" "1" "#138/1: exactly one line appended" || return 1
  assert_eq "$(rl_f "$row" .v)" "1" "#138/1: v is 1" || return 1
  assert_eq "$(rl_f "$row" .event)" "demo" "#138/1: event" || return 1
  assert_eq "$(rl_f "$row" .host)" "$RL_HOST" "#138/1: host is the lower-case short hostname" || return 1
  assert_eq "$(rl_f "$row" .a)" "b" "#138/1: --arg field" || return 1
  assert_eq "$(rl_f "$row" '.n|type')" "number" "#138/1: --argjson field keeps its type" || return 1
  assert_eq "$(rl_f "$row" '.ts|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" "true" "#138/1: ts is UTC ISO" || return 1
}

test_rl_event_helper_swallows_unwritable_logdir() {
  local d out
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-rl.XXXXXX")
  mkdir "$d/events.jsonl"   # appending to a directory fails even for root
  out=$(LOGDIR="$d" PIPE="$d" bash -c ". '$LIB_RL'; pipeline_event demo; echo rc=\$?" 2>&1)
  rm -rf "$d"
  assert_contains "$out" "rc=0" "#138/1: failure to write is swallowed (returns 0)" || return 1
}

# ------------------------------------------------------------------------------------------ AC12

test_rl_ac12_weekly_limit_waits_without_counting() {
  rl_exit_fixture 0 "$RL_WEEKLY"
  local t0; t0=$(date +%s)
  sq_tick
  local rows row nb before_launch
  rows=$(rl_count run_exit); row=$(rl_last run_exit)
  nb=$(sq_queue_field not_before)
  assert_eq "$rows" "1" "#138/12: one run_exit row" || { sq_cleanup; return 1; }
  assert_eq "$(rl_f "$row" .class)" "rate_limited" "#138/12: class" || { sq_cleanup; return 1; }
  assert_eq "$(rl_f "$row" .limit_kind)" "weekly" "#138/12: limit_kind" || { sq_cleanup; return 1; }
  assert_eq "$(rl_f "$row" .exit_code)" "0" "#138/12: exit_code 0" || { sq_cleanup; return 1; }
  # hand arithmetic: RATE_LIMIT_BACKOFF_SECS=3600, so not_before >= t0 + 3500 (100 s of slack)
  case "$nb" in ''|*[!0-9]*) sq_cleanup; fail "#138/12: queue entry has numeric not_before, got [$nb]"; return 1 ;; esac
  [ "$nb" -ge $((t0 + 3500)) ] || { sq_cleanup; fail "#138/12: not_before $nb is not >= $((t0 + 3500))"; return 1; }
  assert_eq "$(sq_restarts_field count)" "1" "#138/12: count unchanged" || { sq_cleanup; return 1; }
  assert_eq "$(sq_restarts_field total)" "1" "#138/12: total unchanged" || { sq_cleanup; return 1; }
  assert_contains "$(sq_log)" "[rate-limited] #42 limit=weekly" "#138/12: slog line" || { sq_cleanup; return 1; }
  sq_tick; sleep 1
  before_launch=$(rl_launches)
  assert_eq "$before_launch" "0" "#138/12: second tick inside the window launches nothing" || { sq_cleanup; return 1; }
  assert_eq "$(sq_restarts_field total)" "1" "#138/12: total still unchanged after second tick" || { sq_cleanup; return 1; }
  # move not_before into the past: the next tick launches it
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1])); d['not_before']=1; json.dump(d, open(sys.argv[1],'w'))" "$SQ_PIPE/queue/orch-42.json"
  sq_tick; rl_wait_launches 1
  assert_eq "$(rl_launches)" "1" "#138/12: due entry launches on the next tick" || { sq_cleanup; return 1; }
  sq_cleanup
}

test_rl_ac12_unrecognised_limit_also_waits() {
  rl_exit_fixture 0 "$RL_OTHER"
  sq_tick
  local row nb; row=$(rl_last run_exit); nb=$(sq_queue_field not_before)
  local now; now=$(date +%s)
  assert_eq "$(rl_f "$row" .class)" "rate_limited" "#138/12: class" || { sq_cleanup; return 1; }
  assert_eq "$(rl_f "$row" .limit_kind)" "other" "#138/12: limit_kind other" || { sq_cleanup; return 1; }
  [ "$nb" != "NO-QUEUE-ENTRY" ] && [ "$nb" -ge $((now + 3400)) ] || { sq_cleanup; fail "#138/12: other-limit is requeued with the long backoff, not_before=$nb"; return 1; }
  assert_eq "$(sq_restarts_field count)" "1" "#138/12: count unchanged" || { sq_cleanup; return 1; }
  assert_eq "$(sq_restarts_field total)" "1" "#138/12: total unchanged" || { sq_cleanup; return 1; }
  sq_cleanup
}

test_rl_ac12_terminal_marker_beats_limit() {
  rl_exit_fixture 0 "$RL_WEEKLY"
  sq_marker '**[deployer] DEPLOYED**'
  sq_tick
  local done_f q rows
  done_f=$(sq_present "$SQ_PIPE/orch-42.done"); q=$(sq_present "$SQ_PIPE/queue/orch-42.json"); rows=$(rl_count run_exit)
  sq_cleanup
  assert_eq "$done_f" "present" "#138/4: terminal done handling keeps priority" || return 1
  assert_eq "$q" "absent" "#138/4: nothing requeued" || return 1
  assert_eq "$rows" "1" "#138/3: run_exit is still logged before the tombstone skips" || return 1
}

# ------------------------------------------------------------------------------------------ AC13

test_rl_ac13_history_entries_carry_class() {
  rl_exit_fixture 1 "$RL_NORMAL"
  sq_tick
  local h; h=$(rl_hist)
  sq_cleanup
  assert_eq "$(rl_f "$h" '.exit|tostring')" "1" "#138/13: history exit stays 1 (regression pin; may pass before implementation)" || return 1
  assert_eq "$(rl_f "$h" .class)" "error" "#138/13: error exit -> class error" || return 1
  assert_eq "$(rl_f "$h" '.transient')" "false" "#138/13: transient key keeps its value" || return 1
  assert_eq "$(rl_f "$h" '.marker')" "$SQ_READY" "#138/13: marker key keeps its value" || return 1
  assert_eq "$(rl_f "$h" '.run_secs|type')" "number" "#138/13: run_secs keeps its type" || return 1
}

test_rl_ac13_history_limit_and_killed() {
  rl_exit_fixture 0 "$RL_WEEKLY"
  sq_tick
  local h; h=$(rl_hist)
  sq_cleanup
  assert_eq "$(rl_f "$h" .class)" "rate_limited" "#138/13: limit entry class" || return 1
  assert_eq "$(rl_f "$h" .limit_kind)" "weekly" "#138/13: limit entry limit_kind" || return 1
  assert_eq "$(rl_f "$h" '.exit|tostring')" "0" "#138/13: limit entry keeps exit 0" || return 1
  rl_exit_fixture none "$RL_NORMAL"
  sq_tick
  h=$(rl_hist)
  sq_cleanup
  assert_eq "$(rl_f "$h" .class)" "killed" "#138/13: killed entry class" || return 1
}

# ------------------------------------------------------------------------------------------ AC14

test_rl_ac14_monthly_spend_limit_holds() {
  rl_exit_fixture 0 "$RL_MONTHLY"
  sq_seed_auto_restart_queue   # a pending queue entry must be removed by the hold
  sq_tick; sleep 1
  local row held q alert log
  row=$(rl_last run_exit); held=$(sq_present "$SQ_PIPE/orch-42.held"); q=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  alert=$(sq_present "$SQ_PIPE/orch-42.alert"); log=$(sq_log)
  local count total launches; count=$(sq_restarts_field count); total=$(sq_restarts_field total); launches=$(rl_launches)
  sq_cleanup
  assert_eq "$(rl_f "$row" .class)" "rate_limited" "#138/14: class" || return 1
  assert_eq "$(rl_f "$row" .limit_kind)" "monthly_spend" "#138/14: limit_kind" || return 1
  assert_eq "$held" "present" "#138/14: .held exists" || return 1
  assert_eq "$q" "absent" "#138/14: no queue entry" || return 1
  assert_eq "$alert" "present" "#138/14: .alert written" || return 1
  assert_contains "$log" "[held] #42 — monthly spend limit" "#138/14: slog line" || return 1
  assert_eq "$count" "1" "#138/14: count unchanged" || return 1
  assert_eq "$total" "1" "#138/14: total unchanged" || return 1
  assert_eq "$launches" "0" "#138/14: no restart launched" || return 1
}

# ------------------------------------------------------------------------------------------ AC15

test_rl_ac15_nonzero_exit_is_error() {
  rl_exit_fixture 1 "$RL_NORMAL"
  sq_tick
  local row; row=$(rl_last run_exit); local cls; cls=$(cat "$SQ_PIPE/orch-42.exit-class" 2>/dev/null); local lg; lg=$(sq_present "$SQ_PIPE/orch-42.exit-logged")
  sq_cleanup
  assert_eq "$(rl_f "$row" .class)" "error" "#138/15: class error" || return 1
  assert_eq "$(rl_f "$row" .exit_code)" "1" "#138/15: exit_code 1" || return 1
  assert_eq "$(rl_f "$row" '.exit_code|type')" "number" "#138/15: exit_code is an integer" || return 1
  assert_eq "$(rl_f "$row" '.limit_kind')" "null" "#138/15: limit_kind null" || return 1
  assert_eq "$(rl_f "$row" .last_line)" "$RL_NORMAL" "#138/15: last_line is the last non-empty log line" || return 1
  case "$cls" in error*) ;; *) fail "#138/15: exit-class file starts with 'error', got [$cls]"; return 1 ;; esac
  assert_eq "$lg" "present" "#138/16: exit-logged touched" || return 1
}

test_rl_ac15_killed_has_null_exit_code() {
  rl_exit_fixture none "$RL_NORMAL"
  sq_tick
  local row; row=$(rl_last run_exit)
  sq_cleanup
  assert_eq "$(rl_f "$row" .class)" "killed" "#138/15: class killed" || return 1
  assert_eq "$(rl_f "$row" .exit_code)" "null" "#138/15: exit_code null" || return 1
  # hand arithmetic: launched 600 s ago, no .exit -> dur_s measured to now, ~600
  local d; d=$(rl_f "$row" .dur_s)
  case "$d" in ''|null|*[!0-9]*) fail "#138/15: dur_s numeric, got [$d]"; return 1 ;; esac
  [ "$d" -ge 590 ] && [ "$d" -le 700 ] || { fail "#138/15: dur_s $d not within 590..700"; return 1; }
}

test_rl_ac15_stopped_beats_everything() {
  rl_open
  mk_stopped "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  echo "$RL_HOST-orch-42-1700000000" > "$SQ_PIPE/orch-42.run-id"
  echo 0 > "$SQ_PIPE/orch-42.exit"
  printf '===== [2026-01-01T00:00:00Z] LAUNCH issue=42 reason=manual =====\n%s\n' "$RL_WEEKLY" > "$SQ_PIPE/orch-42.log"
  sq_tick
  local row; row=$(rl_last run_exit); local rows; rows=$(rl_count run_exit)
  sq_cleanup
  assert_eq "$rows" "1" "#138/15: stopped run gets its row" || return 1
  assert_eq "$(rl_f "$row" .class)" "stopped" "#138/15: class stopped (first match wins over the limit text)" || return 1
}

test_rl_ac15_limit_text_in_older_segment_is_normal() {
  rl_open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  echo "$RL_HOST-orch-42-1700000000" > "$SQ_PIPE/orch-42.run-id"
  echo 0 > "$SQ_PIPE/orch-42.exit"
  printf '%s\n\n===== [2026-01-01T00:00:00Z] LAUNCH issue=42 reason=manual =====\n%s\n\n' "$RL_WEEKLY" "$RL_NORMAL" > "$SQ_PIPE/orch-42.log"
  sq_seed_restarts 1 1 "$SQ_READY"; sq_marker "$SQ_READY"
  sq_tick
  local row; row=$(rl_last run_exit)
  sq_cleanup
  assert_eq "$(rl_f "$row" .class)" "normal" "#138/15: older-segment limit text does not count" || return 1
  assert_eq "$(rl_f "$row" .exit_code)" "0" "#138/15: exit_code 0" || return 1
}

test_rl_ac15_last_line_cut_to_200_and_nothing_else_copied() {
  local long; long=$(python3 -c "print('x'*300)")
  rl_exit_fixture 0 "$long"
  sq_tick
  local row raw; row=$(rl_last run_exit); raw=$(rl_rows run_exit)
  sq_cleanup
  assert_eq "$(rl_f "$row" '.last_line|length')" "200" "#138/15: last_line cut to 200 characters" || return 1
  assert_eq "$(rl_f "$row" .last_line)" "$(python3 -c "print('x'*200)")" "#138/15: last_line is the first 200 chars of the line" || return 1
  assert_not_contains "$raw" "$RL_NORMAL" "#138/15: no other log text is copied" || return 1
}

test_rl_ac15_row_fields_and_dur() {
  rl_exit_fixture 0 "$RL_NORMAL"
  sq_tick
  local row; row=$(rl_last run_exit)
  sq_cleanup
  assert_eq "$(rl_f "$row" .class)" "normal" "#138/15: exit 0, no limit text -> normal" || return 1
  assert_eq "$(rl_f "$row" .run_id)" "$RL_HOST-orch-42-1700000000" "#138/3: run_id comes from the run-id file" || return 1
  assert_eq "$(rl_f "$row" .repo)" "project-a/repo-a" "#138/3: repo" || return 1
  assert_eq "$(rl_f "$row" '.issue|tostring')" "42" "#138/3: issue" || return 1
  local d; d=$(rl_f "$row" .dur_s)
  case "$d" in ''|null|*[!0-9]*) fail "#138/3: dur_s numeric, got [$d]"; return 1 ;; esac
  [ "$d" -ge 590 ] && [ "$d" -le 700 ] || { fail "#138/3: dur_s $d not within 590..700 (launched-at 600 s before the .exit file)"; return 1; }
}

# ------------------------------------------------------------------------------------------ AC16

test_rl_ac16_three_ticks_one_row() {
  rl_exit_fixture 1 "$RL_NORMAL"
  sq_tick; sq_tick; sq_tick
  local rows; rows=$(rl_count run_exit)
  sq_cleanup
  assert_eq "$rows" "1" "#138/16: exactly one run_exit per launch" || return 1
}

test_rl_ac16_pre_merge_run_gets_no_row() {
  rl_exit_fixture 1 "$RL_NORMAL" noid
  sq_tick
  local rows q; rows=$(rl_count run_exit); q=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  sq_cleanup
  assert_eq "$rows" "0" "#138/16: no run-id file -> no run_exit" || return 1
  assert_eq "$q" "present" "#138/16: the restart path still runs for it" || return 1
}

# ------------------------------------------------------------------------------------------ AC17

test_rl_ac17_orchestrate_launch_manual_by_default() {
  rl_open
  touch "$SQ_PIPE/orch-42.exit-logged"
  local out rc
  out=$(sq_run "$ORCH_RL" "$SQ_REPO" 42 2>&1); rc=$?
  rl_wait_launches 1
  local row id idf logged; row=$(rl_last run_launch); idf=$(cat "$SQ_PIPE/orch-42.run-id" 2>/dev/null); logged=$(sq_present "$SQ_PIPE/orch-42.exit-logged")
  sq_cleanup
  assert_exit0 "$rc" "#138/17: launch exits 0 ($out)" || return 1
  assert_eq "$(rl_f "$row" .reason)" "manual" "#138/17: default reason" || return 1
  assert_eq "$(rl_f "$row" .repo)" "project-a/repo-a" "#138/2: repo" || return 1
  assert_eq "$(rl_f "$row" '.issue|tostring')" "42" "#138/2: issue" || return 1
  assert_eq "$(rl_f "$row" '.restart_n|tostring')" "0" "#138/2: restart_n" || return 1
  assert_eq "$(rl_f "$row" '.queue_wait_s')" "null" "#138/2: queue_wait_s null outside the queue" || return 1
  assert_eq "$(rl_f "$row" .run_id)" "$idf" "#138/17: run_id equals the run-id file" || return 1
  assert_eq "$(rl_f "$row" '.run_id|test("^'"$RL_HOST"'-orch-42-[0-9]+$")')" "true" "#138/2: run_id shape <host>-orch-<issue>-<epoch>" || return 1
  assert_eq "$logged" "absent" "#138/2: exit-logged removed at launch" || return 1
}

test_rl_ac17_orchestrate_launch_reason_agent_go() {
  rl_open
  LAUNCH_REASON=agent-go sq_run "$ORCH_RL" "$SQ_REPO" 42 >/dev/null 2>&1
  rl_wait_launches 1
  local row; row=$(rl_last run_launch)
  sq_cleanup
  assert_eq "$(rl_f "$row" .reason)" "agent-go" "#138/17: LAUNCH_REASON=agent-go" || return 1
}

test_rl_ac17_queue_drain_reason_and_wait() {
  rl_open
  python3 -c "
import json, sys, time
json.dump({'issue': '42', 'repo': sys.argv[1], 'extra': '', 'reason': 'queued',
           'queued_at': sys.argv[2], 'not_before': 0}, open(sys.argv[3], 'w'))" "$SQ_REPO" "$(sq_iso_ago 600)" "$SQ_PIPE/queue/orch-42.json"
  touch "$SQ_PIPE/orch-42.exit-logged"
  sq_tick; rl_wait_launches 1
  local row w idf logged; row=$(rl_last run_launch); w=$(rl_f "$row" .queue_wait_s); idf=$(cat "$SQ_PIPE/orch-42.run-id" 2>/dev/null)
  logged=$(sq_present "$SQ_PIPE/orch-42.exit-logged")
  sq_cleanup
  assert_eq "$(rl_f "$row" .reason)" "queue" "#138/17: queued entry -> reason queue" || return 1
  case "$w" in ''|null|*[!0-9]*) fail "#138/17: queue_wait_s numeric, got [$w]"; return 1 ;; esac
  # hand arithmetic: queued 600 s ago -> 590..700 with slack
  [ "$w" -ge 590 ] && [ "$w" -le 700 ] || { fail "#138/17: queue_wait_s $w not within 590..700"; return 1; }
  assert_eq "$(rl_f "$row" .run_id)" "$idf" "#138/17: run_id equals run-id file" || return 1
  assert_eq "$logged" "absent" "#138/2: do_launch removes exit-logged" || return 1
}

test_rl_ac17_auto_restart_reason_and_restart_n() {
  rl_open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_seed_restarts 2 2 "$SQ_READY"
  python3 -c "
import json, sys
json.dump({'issue': '42', 'repo': sys.argv[1], 'extra': '', 'reason': 'auto-restart',
           'queued_at': sys.argv[2], 'not_before': 0}, open(sys.argv[3], 'w'))" "$SQ_REPO" "$(sq_iso_ago 60)" "$SQ_PIPE/queue/orch-42.json"
  sq_marker "$SQ_READY"
  sq_tick; rl_wait_launches 1
  local row; row=$(rl_last run_launch)
  sq_cleanup
  assert_eq "$(rl_f "$row" .reason)" "auto-restart" "#138/17: reason auto-restart" || return 1
  assert_eq "$(rl_f "$row" '.restart_n|tostring')" "2" "#138/17: restart_n is the restart count (2)" || return 1
}

test_rl_ac17_supervisor_label_dispatch_is_agent_go() {
  rl_open
  cat >> "$SQ_HOME/.claude/pipeline/config.local.sh" <<EOF
DISPATCH_REPOS=("project-a/repo-a:$SQ_REPO")
CLAIM_SETTLE_SECS=0
EOF
  echo 42 > "$SQ_GH/gh-list-approved-project-a_repo-a"   # fake gh ignores --jq; this is the already-filtered output (issue numbers)
  jq -n --arg b "**[supervisor] NOTE** claim: $(hostname -s) $(sq_iso_ago 0)" --arg t "$(sq_iso_ago 0)" \
    '[{body:$b, createdAt:$t}]' > "$SQ_GH/gh-issue-comments-json"
  sq_tick; rl_wait_launches 1
  assert_eq "$(rl_launches)" "1" "#138/17: fixture sanity — dispatch launched the stub" || { sq_cleanup; return 1; }
  local row; row=$(rl_last run_launch)
  sq_cleanup
  assert_eq "$(rl_f "$row" .reason)" "agent-go" "#138/17: supervisor label dispatch logs agent-go, not manual" || return 1
}

test_rl_ac17_run_launch_and_run_exit_share_run_id() {
  rl_open
  sq_run "$ORCH_RL" "$SQ_REPO" 42 >/dev/null 2>&1
  rl_wait_launches 1
  sleep 1   # the stub exits at once and writes .exit; the pid is dead by the next tick
  sq_marker "$SQ_READY"
  sq_tick
  local l e; l=$(rl_last run_launch); e=$(rl_last run_exit)
  sq_cleanup
  assert_ne "$(rl_f "$l" .run_id)" "" "#138/17: run_launch has a run_id" || return 1
  assert_eq "$(rl_f "$e" .run_id)" "$(rl_f "$l" .run_id)" "#138/17: run_exit.run_id equals run_launch.run_id" || return 1
  assert_eq "$(rl_f "$e" .class)" "normal" "#138/15: the stub exits 0 with no limit text -> normal" || return 1
}

# ------------------------------------------------------------------------------------------ AC18

test_rl_ac18_all_rows_valid_json_with_v_and_host() {
  rl_exit_fixture 0 "$RL_WEEKLY"
  sq_tick
  sq_run "$ORCH_RL" "$SQ_REPO" 43 >/dev/null 2>&1   # a second launch (issue 43) adds a run_launch row
  rl_wait_launches 1
  local bad total
  total=$(jq -c 'select(.event=="run_launch" or .event=="run_exit")' "$RL_EV" 2>/dev/null | wc -l | tr -d ' ')
  bad=$(jq -c 'select(.event=="run_launch" or .event=="run_exit") | select(.v != 1 or .host != "'"$RL_HOST"'")' "$RL_EV" 2>/dev/null | wc -l | tr -d ' ')
  local parse; parse=$(jq -e . "$RL_EV" >/dev/null 2>&1 && echo ok || echo bad)
  sq_cleanup
  [ "$total" -ge 2 ] || { fail "#138/18: expected at least a run_exit and a run_launch row, got $total"; return 1; }
  assert_eq "$bad" "0" "#138/18: every row has v 1 and the lower-case host" || return 1
  assert_eq "$parse" "ok" "#138/18: every line of events.jsonl is valid JSON" || return 1
}

test_rl_ac18_unwritable_logdir_never_blocks() {
  rl_open
  mkdir -p "$SQ_HOME/logs/pipeline"
  mkdir "$RL_EV"                       # appends to events.jsonl fail (also for root)
  chmod 555 "$SQ_HOME/logs/pipeline"   # and the directory is read-only
  local rc idf
  sq_run "$ORCH_RL" "$SQ_REPO" 42 >/dev/null 2>&1; rc=$?
  rl_wait_launches 1
  idf=$(cat "$SQ_PIPE/orch-42.run-id" 2>/dev/null)
  local l=$(rl_launches) pidf; pidf=$(sq_present "$SQ_PIPE/orch-42.pid")
  # a dead run with a run-id: the tick must still complete and requeue it normally
  rm -f "$SQ_PIPE/orch-42.exit-logged"; echo 1 > "$SQ_PIPE/orch-42.exit"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"; mk_dead_pid "$SQ_PIPE" 42
  sq_marker "$SQ_READY"
  sq_run "$SUP_SQ" >/dev/null 2>&1; local trc=$?
  local q; q=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  chmod 755 "$SQ_HOME/logs/pipeline"
  sq_cleanup
  assert_exit0 "$rc" "#138/18: launch completes with its normal exit code" || return 1
  assert_eq "$l" "1" "#138/18: the run still launched" || return 1
  assert_eq "$pidf" "present" "#138/18: pid file written" || return 1
  assert_ne "$idf" "" "#138/18: run-id file is written even when events.jsonl is not (PIPE is not LOGDIR)" || return 1
  assert_exit0 "$trc" "#138/18: tick completes with its normal exit code" || return 1
  assert_eq "$q" "present" "#138/18: tick still requeued the dead run" || return 1
}

# ------------------------------------------------------------------------------------------ config + AC20

test_rl_config_rate_limit_backoff_default() {
  local h out; h=$(new_home)
  out=$(HOME="$h" PIPE="$h/p" bash -c ". '$HERE_RL/../config.sh'; echo \"\$RATE_LIMIT_BACKOFF_SECS\"" 2>/dev/null)
  rm -rf "$h"
  assert_eq "$out" "3600" "#138/4: RATE_LIMIT_BACKOFF_SECS defaults to 3600" || return 1
}

test_rl_ac20_pm_templates_carry_caused_by() {
  local n; n=$(grep -c 'Caused by' "$PM_RL")
  assert_le 2 "$n" "#138/20: 'Caused by' appears at least twice in product-manager.md (got $n)" || return 1
  assert_eq "$(grep -c 'Caused by: owner/repo#N' "$PM_RL")" "1" "#138/20: full-lane Bug bullet names the 'Caused by: owner/repo#N' line" || return 1
  grep -q '\*\*Caused by\*\* (bugs only, when known) — owner/repo#N' "$PM_RL" || { fail "#138/20: fast-lane list has the optional **Caused by** item"; return 1; }
}

run_test test_rl_event_helper_writes_one_valid_row
run_test test_rl_event_helper_swallows_unwritable_logdir
run_test test_rl_ac12_weekly_limit_waits_without_counting
run_test test_rl_ac12_unrecognised_limit_also_waits
run_test test_rl_ac12_terminal_marker_beats_limit
run_test test_rl_ac13_history_entries_carry_class
run_test test_rl_ac13_history_limit_and_killed
run_test test_rl_ac14_monthly_spend_limit_holds
run_test test_rl_ac15_nonzero_exit_is_error
run_test test_rl_ac15_killed_has_null_exit_code
run_test test_rl_ac15_stopped_beats_everything
run_test test_rl_ac15_limit_text_in_older_segment_is_normal
run_test test_rl_ac15_last_line_cut_to_200_and_nothing_else_copied
run_test test_rl_ac15_row_fields_and_dur
run_test test_rl_ac16_three_ticks_one_row
run_test test_rl_ac16_pre_merge_run_gets_no_row
run_test test_rl_ac17_orchestrate_launch_manual_by_default
run_test test_rl_ac17_orchestrate_launch_reason_agent_go
run_test test_rl_ac17_queue_drain_reason_and_wait
run_test test_rl_ac17_auto_restart_reason_and_restart_n
run_test test_rl_ac17_supervisor_label_dispatch_is_agent_go
run_test test_rl_ac17_run_launch_and_run_exit_share_run_id
run_test test_rl_ac18_all_rows_valid_json_with_v_and_host
run_test test_rl_ac18_unwritable_logdir_never_blocks
run_test test_rl_config_rate_limit_backoff_default
run_test test_rl_ac20_pm_templates_carry_caused_by
