# #627 (fix cycle 2, code review of PR #630) — the idle hand-off is bounded.
#   W1 an idle goal whose open tickets all wait on JP is parked "waiting on JP" (slot freed, no requeue, no hand-off note);
#      the next queued goal starts on the following tick.
#   W2 consecutive idle hand-offs with an unchanged scope count like no-progress cycles: the GOAL_MAX_NO_PROGRESS-th holds
#      the goal exactly as the no-progress path does (goal-held, `held:` note, .held, report_status_async held) — no 4th stint.
#   W3 a scope change between two hand-offs starts the count over (block.idle_handoffs back to 1).
#   W4 deliver.sh resume drops block.idle_handoffs / idle_snap with deferred_at and keeps a v2 body's Go-granted lines.
# Expected values come from the ticket (#627), the review, config.sh or hand arithmetic — never from the code under test.
# Clock anchors: GOAL_MAX_NO_PROGRESS=3 and GOAL_CYCLE_SECS=1200 (config.sh); "young" deferral = 60 s ago (cooling),
# "old" = 1500 s ago (eligible). World: A = project-a#7 (priority 1) active on host-a, lead dead with .idle; B = project-a#8
# queued (priority 5). Prefix zc_ / ZC_. Reuses gs_* / zq_* / zs_* / dg_* helpers (loaded below when this file runs alone).

ZC_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZC_SKILL=$(cd "$ZC_HERE/.." && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$ZC_HERE/test-goal-supervisor.sh" > "$ZC_HERE/.zc-gs-lib.$$.sh"
  . "$ZC_HERE/.zc-gs-lib.$$.sh"; rm -f "$ZC_HERE/.zc-gs-lib.$$.sh"
fi
if ! type zq_env >/dev/null 2>&1; then
  sed '/^run_test /,$d' "$ZC_HERE/test-goal-z-queue.sh" > "$ZC_HERE/.zc-zq-lib.$$.sh"
  . "$ZC_HERE/.zc-zq-lib.$$.sh"; rm -f "$ZC_HERE/.zc-zq-lib.$$.sh"
fi
if ! type zs_mode >/dev/null 2>&1; then
  sed '/^echo "-- one goal at a time/,$d' "$ZC_HERE/test-goal-z-serial.sh" > "$ZC_HERE/.zc-zs-lib.$$.sh"
  . "$ZC_HERE/.zc-zs-lib.$$.sh"; rm -f "$ZC_HERE/.zc-zs-lib.$$.sh"
fi
if ! type dg_setup >/dev/null 2>&1; then
  sed '/^for t in \\$/,$d' "$ZC_HERE/test-goal-deliver.sh" > "$ZC_HERE/.zc-dg-lib.$$.sh"   # its tests run from one `for t in \` loop at the end
  . "$ZC_HERE/.zc-dg-lib.$$.sh"; rm -f "$ZC_HERE/.zc-dg-lib.$$.sh"
fi

ZC_HANDOFF="returned to the queue — no dispatchable work: slot handed to the queue (GOAL_SERIAL=1)"
ZC_HELD_NOTE="**[deliver] NOTE** held: no dispatchable work in 3 consecutive cycles"

# zc_world [cool] — A active (dead lead, clean exit 30 s ago, launched 60 s ago, .idle), B queued; GOAL_SERIAL=1.
# `cool`: B is queued but cooling (deferred 60 s ago) so it counts as a goal behind A without ever taking the slot — the
# hand-off starts the next candidate in the same tick, and a live B would then hold the slot for the rest of the test.
zc_world() {
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-a "" "" 1
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 5 "" "" "" 5
  [ "${1:-}" = cool ] && zc_defer 51 60
  gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a
  zc_end_idle "$ZQ_A"
  echo "lead log" > "$GS_PIPE/goal-$ZQ_A.log"
}
# zc_end_idle <id> — the lead's cycle ends idle: dead pid, launched 60 s ago, clean exit 30 s ago, idle file
zc_end_idle() { gs_launch_state "$1" 60 0 30; : > "$GS_PIPE/goal-$1.idle"; }
# zc_defer <registry issue> <secs ago> — stamp (or re-stamp) block.deferred_at (the key may sit mid-block or last: both forms removed)
zc_defer() {
  local f ts; f=$(gs_regfile "$1"); ts=$(gs_iso_ago "$2")
  jq -c --arg ts "$ts" '.body |= (sub("\"deferred_at\":\"[^\"]*\","; "") | sub(",\"deferred_at\":\"[^\"]*\""; "") | sub("\\{\"v\":1,"; "{\"v\":1,\"deferred_at\":\"\($ts)\","))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
zc_label() { gs_has_label "$1" "$2" && echo yes || echo no; }
zc_file() { [ -e "$GS_PIPE/goal-$ZQ_A.$1" ] && echo present || echo gone; }
# zc_rotate_a — B keeps cooling (deferred 60 s ago) and A's deferral is a cycle old: A alone is eligible to start again
zc_rotate_a() { zc_defer 51 60; zc_defer 50 1500; }

# ---------------------------------------------------------------- W1: waiting on JP beats the hand-off --------------

test_zc_w1_idle_goal_waiting_only_on_jp_is_parked_not_handed_off() {
  zc_world
  gs_comment 7 $'**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp\nneeds JP to decide'   # A's only ticket waits on JP
  gs_tick; gs_settle
  local q w idle st da notes cards log n bh
  q=$(zc_label 50 goal-queued); w=$(zc_label 50 goal-waiting-jp); idle=$(zc_file idle)
  st=$(gs_json "$ZQ_A" state); da=$(zq_block_field 50 deferred_at)
  notes=$(gs_reg_comment_count 50 "slot handed off"); cards=$(gs_reg_comment_count 50 '**[deliver] NOTE** card'); log=$(gs_log)
  gs_tick; gs_wait_claude 1; gs_settle          # waiting on JP does not hold the slot: B starts
  n=$(gs_claude_count); bh=$(zq_block_field 51 host)
  gs_cleanup
  assert_eq "$q" "no" "W1: A is not requeued" || return 1
  assert_eq "$w" "yes" "W1: A carries goal-waiting-jp" || return 1
  assert_eq "$st" "waiting_jp" "W1: A's cache mirrors waiting_jp (the status page reads it)" || return 1
  assert_eq "$idle" "gone" "W1: the idle file is consumed" || return 1
  assert_eq "$da" "MISSING" "W1: no deferred_at (no hand-off)" || return 1
  assert_eq "$notes" "0" "W1: no hand-off note" || return 1
  assert_eq "$cards" "1" "W1: one waiting-on-JP card" || return 1
  assert_not_contains "$log" "$ZC_HANDOFF" "W1: no hand-off log line" || return 1
  assert_eq "$n" "1" "W1: B's lead starts on the next tick (slot freed by waiting_jp)" || return 1
  assert_eq "$bh" "host-a" "W1: ... pinned to the starting host" || return 1
}

# ---------------------------------------------------------------- W2: the third idle hand-off holds the goal ---------

# Hand arithmetic: GOAL_MAX_NO_PROGRESS=3 -> hand-offs 1 and 2 requeue (count 1, 2), the 3rd idle cycle holds. A starts
# twice more after the first hand-off (claude count 2); B never starts (kept cooling), so no 4th A stint exists.
test_zc_w2_three_idle_handoffs_with_unchanged_scope_hold_the_goal() {
  zc_world cool
  gs_tick; gs_settle                                   # hand-off 1
  zc_rotate_a
  gs_tick; gs_wait_claude 1 || { gs_cleanup; fail "W2: A did not start its 2nd stint"; return 1; }; gs_settle
  local h1 h2 held q heldfile hold_notes handoff_notes ev_held n bq log
  h1=$(zq_block_field 50 idle_handoffs)
  zc_end_idle "$ZQ_A"; gs_tick; gs_settle              # hand-off 2
  h2=$(zq_block_field 50 idle_handoffs)
  zc_rotate_a
  gs_tick; gs_wait_claude 2 || { gs_cleanup; fail "W2: A did not start its 3rd stint"; return 1; }; gs_settle
  zc_end_idle "$ZQ_A"; gs_tick; gs_settle              # 3rd idle cycle: held, not handed off
  held=$(zc_label 50 goal-held); q=$(zc_label 50 goal-queued); heldfile=$(zc_file held)
  hold_notes=$(gs_reg_comment_count 50 "$ZC_HELD_NOTE"); handoff_notes=$(gs_reg_comment_count 50 "slot handed off")
  ev_held=$(gs_event_count held); n=$(gs_claude_count); bq=$(zc_label 51 goal-queued); log=$(gs_log)
  gs_tick; gs_settle                                   # one more tick: nothing starts, nothing moves
  local n2; n2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$h1" "1" "W2: the first hand-off recorded idle_handoffs=1 in the registry block" || return 1
  assert_eq "$h2" "2" "W2: the second hand-off recorded idle_handoffs=2" || return 1
  assert_eq "$held" "yes" "W2: the 3rd idle cycle holds the goal (goal-held)" || return 1
  assert_eq "$q" "no" "W2: ... and does not requeue it" || return 1
  assert_eq "$heldfile" "present" "W2: local .held written" || return 1
  assert_eq "$hold_notes" "1" "W2: one held: note naming the idle hand-offs" || return 1
  assert_eq "$handoff_notes" "2" "W2: exactly two hand-off notes (1 and 2)" || return 1
  [ "$ev_held" -ge 1 ] || { fail "W2: report_status_async \"held\" not invoked"; return 1; }
  assert_eq "$n" "2" "W2: A ran two more stints and no other lead started" || return 1
  assert_eq "$n2" "2" "W2: the rotation stopped — no lead starts after the hold" || return 1
  assert_eq "$bq" "yes" "W2: B (cooling) stays queued, untouched" || return 1
  assert_contains "$log" "held — no dispatchable work in 3 consecutive cycles" "W2: supervisor log line" || return 1
}

# ---------------------------------------------------------------- W3: a scope change resets the count ---------------

test_zc_w3_scope_change_between_handoffs_resets_the_count() {
  zc_world cool
  gs_tick; gs_settle                                   # hand-off 1 (count 1)
  gs_comment 7 $'**[test-writer] TESTS WRITTEN**\nBranch: x'   # the ticket moved: its latest marker (hence the snapshot) changed
  zc_rotate_a
  gs_tick; gs_wait_claude 1 || { gs_cleanup; fail "W3: A did not start its 2nd stint"; return 1; }; gs_settle
  zc_end_idle "$ZQ_A"; gs_tick; gs_settle              # hand-off 2 against a changed snapshot
  local h q held notes
  h=$(zq_block_field 50 idle_handoffs); q=$(zc_label 50 goal-queued); held=$(zc_label 50 goal-held)
  notes=$(gs_reg_comment_count 50 "slot handed off")
  gs_cleanup
  assert_eq "$notes" "2" "W3: two hand-offs happened" || return 1
  assert_eq "$h" "1" "W3: the count starts over at 1 when the scope changed since the last hand-off" || return 1
  assert_eq "$q" "yes" "W3: handed off again (queued)" || return 1
  assert_eq "$held" "no" "W3: not held" || return 1
}

# ---------------------------------------------------------------- W4: resume (deliver.sh) -----------------------------

# A v2 goal (go granted) stopped while queued-deferred with an idle count: resume drops the three hand-off fields and
# rewrites the body with the shared builder, so the Go-granted lines survive.
test_zc_w4_resume_drops_idle_count_and_keeps_the_v2_body() {
  dg_setup
  local f block body rc out da ih is lb body2
  f="$DG_ST/issues/$DG_REG/50.json"
  block=$(jq -nc --arg id "$DG_ID_T7" --arg spec "$DG_SPEC_T7" --arg c "$DG_NOW" '
    {v:2, id:$id, spec:$spec, host:"", title:"ticket 7", label:"", repos:["example-owner/project-a"], order:0, priority:1,
     go:true, granted:["example-owner/project-a#7"], granted_at:"2026-11-01", created:$c, instructions:"",
     deferred_at:"2026-11-09T12:00:00Z", idle_handoffs:2, idle_snap:"abc"}')
  body=$(printf 'Goal: ticket 7\n\n```json\n%s\n```\n\nGo-granted: 2026-11-01\n- example-owner/project-a#7\n' "$block")
  jq -nc --arg body "$body" --arg now "$DG_NOW" '{number:50, title:"Goal: ticket 7", body:$body, state:"closed",
    labels:[{name:"delivery-goal"},{name:"goal-stopped"}], milestone:null, closed_at:$now, created_at:$now, updated_at:$now}' > "$f"
  dg_run resume "$DG_ID_T7"
  rc=$DG_RC; out=$DG_OUT
  da=$(dg_block "$f" | jq -r '.deferred_at // "MISSING"'); ih=$(dg_block "$f" | jq -r '.idle_handoffs // "MISSING"'); is=$(dg_block "$f" | jq -r '.idle_snap // "MISSING"')
  lb=no; dg_has_label "$f" goal-queued && lb=yes
  body2=$(jq -r .body "$f")
  dg_teardown
  assert_eq "$rc" "0" "W4: resume exits 0 (stderr: $DG_ERR)" || return 1
  assert_contains "$out" "queued again" "W4: queued again (no host)" || return 1
  assert_eq "$lb" "yes" "W4: goal-queued back on" || return 1
  assert_eq "$da/$ih/$is" "MISSING/MISSING/MISSING" "W4: deferred_at, idle_handoffs and idle_snap all dropped" || return 1
  assert_contains "$body2" "Go-granted: 2026-11-01" "W4: the v2 body keeps its Go-granted line" || return 1
  assert_contains "$body2" "- example-owner/project-a#7" "W4: ... and the granted ticket list" || return 1
}

echo "-- idle hand-off is bounded: waiting on JP, hold after GOAL_MAX_NO_PROGRESS (#627 fix cycle 2)"
run_test test_zc_w1_idle_goal_waiting_only_on_jp_is_parked_not_handed_off
run_test test_zc_w2_three_idle_handoffs_with_unchanged_scope_hold_the_goal
run_test test_zc_w3_scope_change_between_handoffs_resets_the_count
run_test test_zc_w4_resume_drops_idle_count_and_keeps_the_v2_body
gs_tree_cleanup
