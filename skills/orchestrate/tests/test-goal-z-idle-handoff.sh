# #627 — an idle goal (its lead reports no dispatchable work) hands the serial slot to the next queued goal.
#   F1 hand-off (AC1, AC2, AC10)   F2 empty queue keeps the slot (AC3)   F3 exempt feedback goal (AC4)
#   F4 re-admission order + claim-win clears deferred_at (AC5)   F5 no idle file = today (AC6)
#   F6 registry unreadable fails closed (AC7)   brief / launch (AC8)   docs (AC9)
# Expected values come from the ticket (#627) or hand arithmetic in comments — never from the code under test.
# Prefix zi_ / ZI_. Reuses gs_* (test-goal-supervisor.sh), zq_* (test-goal-z-queue.sh) and zs_* (test-goal-z-serial.sh).
# World: A = project-a#7 (priority 1) active on host-a, lead dead, clean exit 0 written 30 s ago, launched 60 s ago
# (age 60 < GOAL_CYCLE_SECS=1200, so today's pacing gate would NOT yet relaunch). B = project-a#8 queued (priority 5).

ZI_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZI_SKILL=$(cd "$ZI_HERE/.." && pwd)
ZI_ROOT=$(cd "$ZI_SKILL/../.." && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$ZI_HERE/test-goal-supervisor.sh" > "$ZI_HERE/.zi-gs-lib.$$.sh"
  . "$ZI_HERE/.zi-gs-lib.$$.sh"; rm -f "$ZI_HERE/.zi-gs-lib.$$.sh"
fi
if ! type zq_env >/dev/null 2>&1; then
  sed '/^run_test /,$d' "$ZI_HERE/test-goal-z-queue.sh" > "$ZI_HERE/.zi-zq-lib.$$.sh"
  . "$ZI_HERE/.zi-zq-lib.$$.sh"; rm -f "$ZI_HERE/.zi-zq-lib.$$.sh"
fi
if ! type zs_mode >/dev/null 2>&1; then
  sed '/^echo "-- one goal at a time/,$d' "$ZI_HERE/test-goal-z-serial.sh" > "$ZI_HERE/.zi-zs-lib.$$.sh"
  . "$ZI_HERE/.zi-zs-lib.$$.sh"; rm -f "$ZI_HERE/.zi-zs-lib.$$.sh"
fi

ZI_IDLE_NOTE="slot handed off: no dispatchable work; back in the queue behind 1 goal(s)"
ZI_LOG_LINE="returned to the queue — no dispatchable work: slot handed to the queue (GOAL_SERIAL=1)"

# zi_world <b state: queued|delivered> [a spec] [idle yes|no] — F1 (F2 with delivered, F3 with a feedback spec, F5 with idle=no)
zi_world() {
  local bst=${1:-queued} aspec=${2:-$ZQ_SPEC_A} idle=${3:-yes}
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$aspec" active 1 host-a "" "" 1
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" "$bst" 5 "" "" "" 5
  gs_cache 50 "$ZQ_A" "$aspec" host-a
  gs_launch_state "$ZQ_A" 60 0 30
  echo 1 > "$GS_PIPE/goal-$ZQ_A.np"; echo snap > "$GS_PIPE/goal-$ZQ_A.snap"
  echo "lead log" > "$GS_PIPE/goal-$ZQ_A.log"
  [ "$idle" = yes ] && : > "$GS_PIPE/goal-$ZQ_A.idle"
  return 0
}
zi_file() { [ -e "$GS_PIPE/goal-$ZQ_A.$1" ] && echo present || echo gone; }
zi_label() { gs_has_label "$1" "$2" && echo yes || echo no; }

# AC1 + AC2 + AC10 (F1): one tick hands the slot off, never held, and B is the candidate in that same sync.
test_zi_f1_idle_goal_hands_the_slot_to_the_queue() {
  zi_world queued
  gs_tick; gs_settle
  local st q held host da notes log slot cand ev_goal ev_held files
  st=$(gs_reg_state 50); q=$(zi_label 50 goal-queued); held=$(zi_label 50 goal-held)
  host=$(zq_block_field 50 host); da=$(zq_block_field 50 deferred_at)
  notes=$(gs_reg_comment_count 50 "**[deliver] NOTE** $ZI_IDLE_NOTE")
  log=$(gs_log)
  slot=$(jq -r '.slot' "$GS_PIPE/goalqueue.json" 2>/dev/null); cand=$(jq -r '.candidate' "$GS_PIPE/goalqueue.json" 2>/dev/null)
  ev_goal=$(gs_event_count goal); ev_held=$(gs_event_count held)
  files="$(zi_file idle) $(zi_file np) $(zi_file snap) $(zi_file json) $(zi_file held) $(zi_file log)"
  gs_cleanup
  assert_eq "$st" "open" "AC1: A's registry issue is open" || return 1
  assert_eq "$q" "yes" "AC1: A carries goal-queued" || return 1
  assert_eq "$held" "no" "AC1/AC2: A does not carry goal-held" || return 1
  assert_eq "$host" "" "AC1: block.host is cleared" || return 1
  printf '%s' "$da" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || { fail "AC1: block.deferred_at must be an ISO-8601 UTC timestamp, got [$da]"; return 1; }
  # idle, np, snap, json gone; the lead log kept; no .held file (AC2)
  assert_eq "$files" "gone gone gone gone gone present" "AC1/AC2: local state dropped, log kept, no .held" || return 1
  assert_contains "$log" "[goal] $ZQ_A $ZI_LOG_LINE" "AC1: supervisor log line" || return 1
  assert_eq "$notes" "1" "AC1: exactly one hand-off note on the registry issue" || return 1
  assert_eq "$(gs_reg_comment_count 50 'held:')" "0" "AC2: no held: note" || return 1
  assert_eq "$slot" "null" "AC1/AC10: the sync's goalqueue.json has slot null" || return 1
  assert_eq "$cand" "$ZQ_B" "AC1/AC10: ... and B is the candidate (same tick, no GOAL_CYCLE_SECS wait)" || return 1
  [ "$ev_goal" -ge 1 ] || { fail "AC2: report_status_async \"goal\" not invoked"; return 1; }
  assert_eq "$ev_held" "0" "AC2: report_status_async \"held\" never invoked" || return 1
}

# AC10: from the hand-off tick, B starts on the very next tick (a lead for B is launched, A is not relaunched).
test_zi_f1_next_tick_starts_the_next_goal() {
  zi_world queued
  gs_tick; gs_tick; gs_wait_claude 1; gs_settle
  local n bh
  n=$(gs_claude_count); bh=$(zq_block_field 51 host)
  gs_cleanup
  assert_eq "$n" "1" "AC10: exactly one lead launched by the second tick" || return 1
  assert_eq "$bh" "host-a" "AC10: it is B's lead (B pinned to the starting host)" || return 1
}

# AC3 (F2): nobody queued behind A -> A keeps the slot; idle file removed; log line; pacing unchanged.
test_zi_f2_empty_queue_keeps_the_slot() {
  zi_world delivered
  gs_tick; gs_settle
  local q n np log da idle
  q=$(zi_label 50 goal-queued); n=$(gs_claude_count); np=$(cat "$GS_PIPE/goal-$ZQ_A.np" 2>/dev/null)
  da=$(zq_block_field 50 deferred_at); idle=$(zi_file idle); log=$(gs_log)
  gs_cleanup
  assert_eq "$q" "no" "AC3: A is not requeued" || return 1
  assert_eq "$da" "MISSING" "AC3: no deferred_at" || return 1
  assert_eq "$idle" "gone" "AC3: the idle file is removed" || return 1
  assert_contains "$log" "[goal] $ZQ_A idle but keeps the slot (no goal queued)" "AC3: log line" || return 1
  assert_eq "$n" "0" "AC3: clean-exit pacing unchanged — exit 30 s old, no relaunch" || return 1
  assert_eq "$np" "1" "AC3: .np untouched" || return 1
}

# AC4 (F3): an exempt feedback goal (GOAL_SERIAL_FEEDBACK=0) is never handed off.
test_zi_f3_exempt_feedback_goal_is_unaffected() {
  zi_world queued "example-owner/project-a:feedback"
  gs_tick; gs_settle
  local q da idle notes log
  q=$(zi_label 50 goal-queued); da=$(zq_block_field 50 deferred_at); idle=$(zi_file idle)
  notes=$(gs_reg_comment_count 50 "slot handed off"); log=$(gs_log)
  gs_cleanup
  assert_eq "$q" "no" "AC4: A (feedback) is not requeued" || return 1
  assert_eq "$da" "MISSING" "AC4: no deferred_at" || return 1
  assert_eq "$idle" "gone" "AC4: idle file removed" || return 1
  assert_eq "$notes" "0" "AC4: no hand-off note" || return 1
  assert_not_contains "$log" "$ZI_LOG_LINE" "AC4: no hand-off log line" || return 1
}

# zi_deferred_reg <id> <issue> <spec> <priority> <deferred 0|1> — a queued goal, optionally with block.deferred_at
zi_deferred_reg() {
  local f; zq_reg "$2" "$1" "$3" queued "$4" "" "" "" "$4"
  [ "$5" = 1 ] || return 0
  f=$(gs_regfile "$2")
  jq -c '.body |= sub("\\{\"v\":1,"; "{\"v\":1,\"deferred_at\":\"2026-11-09T12:00:00Z\",")' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# AC5 (F4), pure jq: A queued+deferred (priority 1) sorts after C queued (priority 9).
# The registry shape _GOAL_ISSUE_JQ produces nests the block as .block; deferred_at lives in .block.
test_zi_f4_deferred_goal_sorts_after_non_deferred() {
  local reg r
  reg=$(jq -nc '[
    {issue:50,id:"goal-a",spec:"example-owner/project-a#7",host:"",instructions:"",state:"open",closed_at:null,st:"queued",
     block:{v:1,id:"goal-a",spec:"example-owner/project-a#7",priority:1,deferred_at:"2026-11-09T12:00:00Z"}},
    {issue:52,id:"goal-c",spec:"example-owner/project-a#9",host:"",instructions:"",state:"open",closed_at:null,st:"queued",
     block:{v:1,id:"goal-c",spec:"example-owner/project-a#9",priority:9}}]')
  r=$( ( . "$ZI_SKILL/goal-lib.sh" >/dev/null 2>&1; GOAL_SERIAL=1; GOAL_SERIAL_FEEDBACK=0
         printf '%s' "$reg" | _goal_queue_jq ' | [.queued[0].id, .queued[1].id, .candidate.id] | join(",")' | jq -r . ) )
  assert_eq "$r" "goal-c,goal-a,goal-c" "AC5: queued = [C, A], candidate = C although A's priority (1) is better" || return 1
}
# The queue view the status page reads carries `deferred` per queued row (empty when not deferred).
test_zi_f4_queue_save_exposes_deferred() {
  local reg r
  reg=$(jq -nc '[
    {issue:50,id:"goal-a",spec:"x/y#1",host:"",instructions:"",state:"open",closed_at:null,st:"queued",block:{v:1,id:"goal-a",spec:"x/y#1",priority:1,deferred_at:"2026-11-09T12:00:00Z"}},
    {issue:51,id:"goal-c",spec:"x/y#2",host:"",instructions:"",state:"open",closed_at:null,st:"queued",block:{v:1,id:"goal-c",spec:"x/y#2",priority:9}}]')
  zq_env; zs_mode 1
  r=$( ( cd "$GS_HOME"; export HOME="$GS_HOME" PIPE="$GS_PIPE" LOGDIR="$GS_HOME/logs/pipeline" PATH="$GS_BIN:$PATH"
         . "$ZI_SKILL/config.sh" >/dev/null 2>&1; . "$ZI_SKILL/pipeline-lib.sh" >/dev/null 2>&1; . "$ZI_SKILL/goal-lib.sh" >/dev/null 2>&1
         goal_queue_save "$reg" >/dev/null 2>&1
         jq -r '.queued | map(.id + "=" + .deferred) | join(",")' "$GS_PIPE/goalqueue.json" ) )
  gs_cleanup
  assert_eq "$r" "goal-c=,goal-a=2026-11-09T12:00:00Z" "AC5: goalqueue.json queued rows carry deferred (display only)" || return 1
}
# AC5, claim-win: a deferred goal that reaches the front and starts is a normal goal again (deferred_at dropped).
test_zi_f4_claim_win_clears_deferred_at() {
  zq_env; zs_mode 1
  zi_deferred_reg "$ZQ_A" 50 "$ZQ_SPEC_A" 1 1
  [ "$(zq_block_field 50 deferred_at)" = "2026-11-09T12:00:00Z" ] || { gs_cleanup; fail "fixture: deferred_at not seeded"; return 1; }
  gs_tick; gs_wait_claude 1; gs_settle
  local da host n
  da=$(zq_block_field 50 deferred_at); host=$(zq_block_field 50 host); n=$(gs_claude_count)
  gs_cleanup
  assert_eq "$n" "1" "AC5: the deferred goal starts when it is first in line" || return 1
  assert_eq "$host" "host-a" "AC5: pinned to the starting host" || return 1
  assert_eq "$da" "MISSING" "AC5: the claim-win body patch drops block.deferred_at" || return 1
}

# AC6 (F5): no idle file -> nothing in this ticket fires; pacing holds (age 60 < 1200: no relaunch, no requeue).
test_zi_f5_without_idle_file_nothing_fires() {
  zi_world queued "$ZQ_SPEC_A" no
  gs_tick; gs_settle
  local q da n np notes log
  q=$(zi_label 50 goal-queued); da=$(zq_block_field 50 deferred_at); n=$(gs_claude_count); np=$(cat "$GS_PIPE/goal-$ZQ_A.np" 2>/dev/null)
  notes=$(gs_reg_comment_count 50 "slot handed off"); log=$(gs_log)
  gs_cleanup
  assert_eq "$q" "no" "AC6: no requeue" || return 1
  assert_eq "$da" "MISSING" "AC6: no deferred_at" || return 1
  assert_eq "$notes" "0" "AC6: no note" || return 1
  assert_eq "$n" "0" "AC6: pacing — no relaunch before GOAL_CYCLE_SECS" || return 1
  assert_eq "$np" "1" "AC6: .np unchanged" || return 1
  assert_not_contains "$log" "no dispatchable work" "AC6: no hand-off log line" || return 1
  assert_not_contains "$log" "idle but keeps the slot" "AC6: no keeps-the-slot log line" || return 1
}

# AC7 (F6): the registry read fails -> fail closed: idle file kept, A active, a goal_err row naming A, no requeue;
# with the read restored the next tick performs the AC1 hand-off.
test_zi_f6_registry_unreadable_fails_closed_then_retries() {
  zi_world queued
  : > "$GS_BIN/fail-registry"
  gs_tick; gs_settle
  local idle q da errs notes log
  idle=$(zi_file idle); q=$(zi_label 50 goal-queued); da=$(zq_block_field 50 deferred_at)
  log=$(gs_log); errs=$(printf '%s\n' "$log" | grep -F '[goal] error:' | grep -cF "$ZQ_A")
  gs_has_label 50 goal-held && q="$q held"
  rm -f "$GS_BIN/fail-registry"
  gs_tick; gs_settle
  local st2 q2 idle2 notes2 log2
  q2=$(zi_label 50 goal-queued); idle2=$(zi_file idle); notes2=$(gs_reg_comment_count 50 "**[deliver] NOTE** $ZI_IDLE_NOTE"); log2=$(gs_log)
  gs_cleanup
  assert_eq "$idle" "present" "AC7: the idle file is left in place" || return 1
  assert_eq "$q" "no" "AC7: A stays active (not queued, not held)" || return 1
  assert_eq "$da" "MISSING" "AC7: no deferred_at written on a guess" || return 1
  assert_eq "$errs" "1" "AC7: exactly one goal_err row names the goal" || return 1
  assert_not_contains "$log" "$ZI_LOG_LINE" "AC7: no hand-off on the failed tick" || return 1
  assert_eq "$q2" "yes" "AC7: the next tick (read restored) hands off" || return 1
  assert_eq "$idle2" "gone" "AC7: and drops the idle file" || return 1
  assert_eq "$notes2" "1" "AC7: one hand-off note after the retry" || return 1
  assert_contains "$log2" "$ZI_LOG_LINE" "AC7: hand-off logged after the retry" || return 1
}

# AC8: goal_brief carries the idle-file instruction with the expanded path.
test_zi_ac8_brief_names_the_idle_file() {
  zq_env; zs_mode 1
  gs_own "$ZQ_A" 50 "$ZQ_SPEC_A" 60 0 30
  local out
  out=$( cd "$GS_HOME" && env HOME="$GS_HOME" PIPE="$GS_PIPE" LOGDIR="$GS_HOME/logs/pipeline" PATH="$GS_BIN:$PATH" bash -c \
    '. "$1/config.sh"; . "$1/pipeline-lib.sh"; . "$1/../../hooks/pipeline-markers.sh"; . "$1/goal-lib.sh"; goal_brief "$2"' _ "$ZI_SKILL" "$ZQ_A" 2>&1 </dev/null )
  gs_cleanup
  assert_contains "$out" "No dispatchable work this cycle: run \`touch $GS_PIPE/goal-$ZQ_A.idle\` before ending the turn (headless only)." "AC8: brief idle-file line, literal expanded path" || return 1
  # placed after the memory line
  local mem idle
  mem=$(printf '%s\n' "$out" | grep -n 'Your memory' | head -1 | cut -d: -f1); idle=$(printf '%s\n' "$out" | grep -n 'No dispatchable work this cycle' | head -1 | cut -d: -f1)
  [ -n "$mem" ] && [ -n "$idle" ] && [ "$idle" -gt "$mem" ] || { fail "AC8: the idle line must come after the 'Your memory' line (memory=$mem idle=$idle)"; return 1; }
}
# AC8: goal_launch removes a pre-existing idle file (a stale one never counts). B queued, stale B.idle on disk, B starts.
test_zi_ac8_launch_removes_a_stale_idle_file() {
  zq_env; zs_mode 1
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 "" "" "" 1
  : > "$GS_PIPE/goal-$ZQ_B.idle"
  gs_tick; gs_wait_claude 1; gs_settle
  local idle=gone n
  [ -e "$GS_PIPE/goal-$ZQ_B.idle" ] && idle=present; n=$(gs_claude_count)
  gs_cleanup
  assert_eq "$n" "1" "AC8: B launched" || return 1
  assert_eq "$idle" "gone" "AC8: goal_launch removed the stale idle file" || return 1
}

# AC9 (docs): delivery-lead §4 and README carry the rule.
test_zi_ac9_docs() {
  local dl rd
  dl=$(cat "$ZI_ROOT/agents/delivery-lead.md"); rd=$(cat "$ZI_ROOT/README.md")
  assert_contains "$dl" "goal-<id>.idle" "AC9: delivery-lead.md names the idle file" || return 1
  assert_contains "$dl" "touch" "AC9: delivery-lead.md tells the lead to touch it" || return 1
  printf '%s' "$rd" | grep -Eqi 'idle goal.*(hands|hand).*slot.*next queued goal' \
    || { fail "AC9: README 'One goal at a time' must say an idle goal hands the slot to the next queued goal"; return 1; }
  printf '%s' "$rd" | grep -Eqi 'behind the goals already (queued|waiting)' \
    || { fail "AC9: README must say the goal rejoins the queue behind the goals already waiting/queued"; return 1; }
}

echo "-- idle goal hands the slot to the queue (#627)"
run_test test_zi_f1_idle_goal_hands_the_slot_to_the_queue
run_test test_zi_f1_next_tick_starts_the_next_goal
run_test test_zi_f2_empty_queue_keeps_the_slot
run_test test_zi_f3_exempt_feedback_goal_is_unaffected
run_test test_zi_f4_deferred_goal_sorts_after_non_deferred
run_test test_zi_f4_queue_save_exposes_deferred
run_test test_zi_f4_claim_win_clears_deferred_at
run_test test_zi_f5_without_idle_file_nothing_fires
run_test test_zi_f6_registry_unreadable_fails_closed_then_retries
run_test test_zi_ac8_brief_names_the_idle_file
run_test test_zi_ac8_launch_removes_a_stale_idle_file
run_test test_zi_ac9_docs
gs_tree_cleanup
