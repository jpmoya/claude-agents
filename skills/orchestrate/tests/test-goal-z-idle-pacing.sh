# #627 (fix cycle, code review of PR #630) — pacing of the idle hand-off and the resume path.
#   P1 (pure jq) a deferred queued goal is not the candidate within GOAL_CYCLE_SECS of its deferred_at; after that it is,
#      in the usual order; a non-deferred goal is never held back by it.
#   P2 (supervisor ticks) two idle goals do not ping-pong: once both handed the slot off, nothing starts until a
#      deferral is a cycle old; then the oldest one in queue order starts and the claim-win drops its deferred_at.
#   P3 (deliver.sh) `resume` drops block.deferred_at (and the local .idle file) so a resumed goal is a normal goal again.
#   plus: the idle branch's registry-read guard is the one that fails closed (the hand-off is never decided on a guess).
# Expected values come from the ticket (#627), the review, or hand arithmetic in comments — never from the code under test.
# Clock anchors: GOAL_CYCLE_SECS=1200 (config.sh). "young" = 60 s ago (< 1200), "old" = 1500 s ago (> 1200); both >= 60 s
# away from the boundary. Prefix zp_ / ZP_. Reuses gs_* (test-goal-supervisor.sh), zq_* (test-goal-z-queue.sh),
# zs_* (test-goal-z-serial.sh) and dg_* (test-goal-deliver.sh); loaded below when this file runs alone.

ZP_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZP_SKILL=$(cd "$ZP_HERE/.." && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$ZP_HERE/test-goal-supervisor.sh" > "$ZP_HERE/.zp-gs-lib.$$.sh"
  . "$ZP_HERE/.zp-gs-lib.$$.sh"; rm -f "$ZP_HERE/.zp-gs-lib.$$.sh"
fi
if ! type zq_env >/dev/null 2>&1; then
  sed '/^run_test /,$d' "$ZP_HERE/test-goal-z-queue.sh" > "$ZP_HERE/.zp-zq-lib.$$.sh"
  . "$ZP_HERE/.zp-zq-lib.$$.sh"; rm -f "$ZP_HERE/.zp-zq-lib.$$.sh"
fi
if ! type zs_mode >/dev/null 2>&1; then
  sed '/^echo "-- one goal at a time/,$d' "$ZP_HERE/test-goal-z-serial.sh" > "$ZP_HERE/.zp-zs-lib.$$.sh"
  . "$ZP_HERE/.zp-zs-lib.$$.sh"; rm -f "$ZP_HERE/.zp-zs-lib.$$.sh"
fi
if ! type dg_setup >/dev/null 2>&1; then
  sed '/^for t in \\$/,$d' "$ZP_HERE/test-goal-deliver.sh" > "$ZP_HERE/.zp-dg-lib.$$.sh"   # its tests run from one `for t in \` loop at the end
  . "$ZP_HERE/.zp-dg-lib.$$.sh"; rm -f "$ZP_HERE/.zp-dg-lib.$$.sh"
fi

ZP_YOUNG=60; ZP_OLD=1500

# zp_goal <registry issue> <id> <priority> <deferred secs ago | ""> — a queued registry goal in the shape _GOAL_ISSUE_JQ produces
zp_goal() {
  local d=""; [ -n "$4" ] && d=$(gs_iso_ago "$4")
  jq -nc --argjson n "$1" --arg id "$2" --arg p "$3" --arg d "$d" --arg spec "example-owner/project-a#$1" '
    {issue:$n, id:$id, spec:$spec, host:"", instructions:"", state:"open", closed_at:null, st:"queued",
     block:({v:1, id:$id, spec:$spec, priority:($p|tonumber)} + (if $d != "" then {deferred_at:$d} else {} end))}'
}
# zp_q <field: candidate|queued> <goal json>... -> candidate id / "null", or the queued ids joined by ","
zp_q() {
  local field=$1 reg; shift
  reg=$(printf '%s\n' "$@" | jq -sc '.')
  ( . "$ZP_SKILL/goal-lib.sh" >/dev/null 2>&1; GOAL_SERIAL=1; GOAL_SERIAL_FEEDBACK=0
    if [ "$field" = queued ]; then printf '%s' "$reg" | _goal_queue_jq ' | .queued | map(.id) | join(",")' | jq -r .
    else printf '%s' "$reg" | _goal_queue_jq ' | (.candidate | if type == "object" then .id else "null" end)' | jq -r .; fi )
}
# zp_defer <registry issue> <secs ago> — stamp (or re-stamp) block.deferred_at on a zq_reg goal (same body surgery as the locked file)
zp_defer() {
  local f ts; f=$(gs_regfile "$1"); ts=$(gs_iso_ago "$2")
  jq -c --arg ts "$ts" '.body |= (sub("\"deferred_at\":\"[^\"]*\","; "") | sub("\\{\"v\":1,"; "{\"v\":1,\"deferred_at\":\"\($ts)\","))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ---------------------------------------------------------------- P1: queue admission (pure jq) ----------------

# Two deferred goals, both young: queue order unchanged, nobody is the candidate (the slot stays free one cycle).
test_zp_p1_young_deferred_goals_are_not_candidates() {
  local a b c q
  a=$(zp_goal 50 goal-a 1 "$ZP_YOUNG"); b=$(zp_goal 51 goal-b 5 "$ZP_YOUNG")
  c=$(zp_q candidate "$a" "$b"); q=$(zp_q queued "$a" "$b")
  assert_eq "$q" "goal-a,goal-b" "P1: both stay listed as queued, in priority order" || return 1
  assert_eq "$c" "null" "P1: a goal deferred 60 s ago (< GOAL_CYCLE_SECS=1200) is not the candidate" || return 1
}
# An old deferral is eligible again, even behind a better-priority young one.
test_zp_p1_old_deferred_goal_is_the_candidate_past_the_cycle() {
  local a b c
  a=$(zp_goal 50 goal-a 5 "$ZP_OLD"); b=$(zp_goal 51 goal-b 1 "$ZP_YOUNG")
  c=$(zp_q candidate "$a" "$b")
  assert_eq "$c" "goal-a" "P1: deferred 1500 s ago (> 1200) -> candidate, although goal-b (young, priority 1) sorts first" || return 1
  c=$(zp_q candidate "$(zp_goal 50 goal-a 5 "$ZP_OLD")" "$(zp_goal 51 goal-b 1 "$ZP_OLD")")
  assert_eq "$c" "goal-b" "P1: two old deferrals -> the usual priority order (goal-b, priority 1)" || return 1
}
# A non-deferred goal is never held back; the window follows GOAL_CYCLE_SECS.
test_zp_p1_non_deferred_goal_and_cycle_length() {
  local c
  c=$(zp_q candidate "$(zp_goal 50 goal-a 1 "$ZP_YOUNG")" "$(zp_goal 52 goal-c 9 "")")
  assert_eq "$c" "goal-c" "P1: the non-deferred goal is the candidate while goal-a cools" || return 1
  c=$( GOAL_CYCLE_SECS=30 zp_q candidate "$(zp_goal 50 goal-a 1 "$ZP_YOUNG")" )
  assert_eq "$c" "goal-a" "P1: with GOAL_CYCLE_SECS=30 a 60 s old deferral is eligible (window = GOAL_CYCLE_SECS)" || return 1
}

# ---------------------------------------------------------------- P2: supervisor ticks ---------------------------

# A active (lead dead, idle), B queued: tick 1 hands off and B starts on tick 2 (AC10). B's lead then ends idle too:
# B hands off (A is queued behind it) and, both deferrals being young, NO lead starts on the following ticks.
test_zp_p2_two_idle_goals_stop_instead_of_ping_pong() {
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-a "" "" 1
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 5 "" "" "" 5
  gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a
  gs_launch_state "$ZQ_A" 60 0 30
  : > "$GS_PIPE/goal-$ZQ_A.idle"
  gs_tick; gs_tick
  gs_wait_claude 1 || { gs_cleanup; fail "P2: B's lead never started after A handed off"; return 1; }
  local n1 qa qb cand n2 da db log
  n1=$(gs_claude_count); qb=$(gs_has_label 51 goal-queued && echo yes || echo no)
  # B's cycle ends idle: dead pid, clean exit 30 s ago, launched 60 s ago, idle file
  gs_launch_state "$ZQ_B" 60 0 30
  : > "$GS_PIPE/goal-$ZQ_B.idle"
  gs_tick; gs_settle          # B hands off (A queued behind it)
  qa=$(gs_has_label 50 goal-queued && echo yes || echo no); qb="$qb/$(gs_has_label 51 goal-queued && echo yes || echo no)"
  da=$(zq_block_field 50 deferred_at); db=$(zq_block_field 51 deferred_at)
  gs_tick; gs_tick; gs_settle  # both young: nothing may start
  n2=$(gs_claude_count); cand=$(jq -r '.candidate' "$GS_PIPE/goalqueue.json" 2>/dev/null); log=$(gs_log)
  gs_cleanup
  assert_eq "$n1" "1" "P2: exactly one lead (B) started after A's hand-off" || return 1
  assert_eq "$qb" "no/yes" "P2: B left the queue when it started and is queued again after its own hand-off" || return 1
  assert_eq "$qa" "yes" "P2: A is still queued" || return 1
  printf '%s' "$da" | grep -Eq '^[0-9]{4}-' || { fail "P2: A carries deferred_at, got [$da]"; return 1; }
  printf '%s' "$db" | grep -Eq '^[0-9]{4}-' || { fail "P2: B carries deferred_at, got [$db]"; return 1; }
  assert_eq "$(printf '%s\n' "$log" | grep -cF 'no dispatchable work: slot handed to the queue')" "2" "P2: two hand-offs logged (A, then B)" || return 1
  assert_eq "$cand" "null" "P2: both deferrals young -> no candidate" || return 1
  assert_eq "$n2" "1" "P2: no third lead session within the cycle (the ping-pong stops)" || return 1
}
# The slot is free and both deferrals are young: nothing starts; once A's deferral is a cycle old, A starts (in queue
# order: A priority 1 before B priority 5) and the claim-win drops its deferred_at.
test_zp_p2_oldest_deferral_starts_after_one_cycle() {
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" queued 1 "" "" "" 1
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 5 "" "" "" 5
  zp_defer 50 "$ZP_YOUNG"; zp_defer 51 "$ZP_YOUNG"
  gs_tick; gs_tick; gs_settle
  local n0 cand n1 host da qb
  n0=$(gs_claude_count); cand=$(jq -r '.candidate' "$GS_PIPE/goalqueue.json" 2>/dev/null)
  zp_defer 50 "$ZP_OLD"   # A's hand-off is now a cycle old
  gs_tick; gs_wait_claude 1; gs_settle
  n1=$(gs_claude_count); host=$(zq_block_field 50 host); da=$(zq_block_field 50 deferred_at)
  qb=$(gs_has_label 51 goal-queued && echo yes || echo no)
  gs_cleanup
  assert_eq "$n0" "0" "P2: slot free, both deferrals young -> no lead started" || return 1
  assert_eq "$cand" "null" "P2: ... and goalqueue.json shows no candidate" || return 1
  assert_eq "$n1" "1" "P2: A starts once its deferral is older than GOAL_CYCLE_SECS" || return 1
  assert_eq "$host" "host-a" "P2: A pinned to the starting host" || return 1
  assert_eq "$da" "MISSING" "P2: the claim-win dropped A's deferred_at" || return 1
  assert_eq "$qb" "yes" "P2: B (young) stays queued" || return 1
}

# ---------------------------------------------------------------- P3: deliver.sh resume ---------------------------

# A goal stopped while queued-deferred: `resume` puts it back in the queue with deferred_at gone and no .idle left over.
test_zp_p3_resume_drops_deferred_at_and_idle_file() {
  dg_setup
  DG_GOAL_ID=$DG_ID_T7 dg_goal 50 "$DG_SPEC_T7" "" stopped
  local f; f="$DG_ST/issues/$DG_REG/50.json"
  jq -c '.body |= sub("\\{\"v\":1,"; "{\"v\":1,\"deferred_at\":\"2026-11-09T12:00:00Z\",")' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  [ "$(dg_block "$f" | jq -r '.deferred_at // "MISSING"')" = "2026-11-09T12:00:00Z" ] || { dg_teardown; fail "fixture: deferred_at not seeded"; return 1; }
  : > "$DG_PIPE/goal-$DG_ID_T7.idle"
  dg_run resume "$DG_ID_T7"
  local rc=$DG_RC out=$DG_OUT da lb=no idle=gone st
  da=$(dg_block "$f" | jq -r '.deferred_at // "MISSING"'); dg_has_label "$f" goal-queued && lb=yes
  [ -e "$DG_PIPE/goal-$DG_ID_T7.idle" ] && idle=present; st=$(jq -r .state "$f")
  dg_teardown
  assert_eq "$rc" "0" "P3: resume exits 0" || return 1
  assert_contains "$out" "queued again" "P3: a goal with no host is queued again" || return 1
  assert_eq "$st" "open" "P3: the registry issue is open" || return 1
  assert_eq "$lb" "yes" "P3: goal-queued is back on" || return 1
  assert_eq "$da" "MISSING" "P3: block.deferred_at is dropped by the resume" || return 1
  assert_eq "$idle" "gone" "P3: the stale .idle file is removed by the resume" || return 1
}

echo "-- idle hand-off pacing + resume (#627 fix cycle)"
run_test test_zp_p1_young_deferred_goals_are_not_candidates
run_test test_zp_p1_old_deferred_goal_is_the_candidate_past_the_cycle
run_test test_zp_p1_non_deferred_goal_and_cycle_length
run_test test_zp_p2_two_idle_goals_stop_instead_of_ping_pong
run_test test_zp_p2_oldest_deferral_starts_after_one_cycle
run_test test_zp_p3_resume_drops_deferred_at_and_idle_file
gs_tree_cleanup
