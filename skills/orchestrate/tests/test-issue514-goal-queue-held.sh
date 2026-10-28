# #514 — a held goal must not hold the goal queue line; a launch that never got to work is not "no progress".
#   AC1 held(1) + queued(2) -> candidate is the queued goal         AC2 held(1) + held(2) + queued(3) -> candidate is 3
#   AC3 delivered / stopped / waiting_jp exclusions unchanged; active still holds the line
#   AC4 three launch failures park via GOAL_MAX_LAUNCH_FAILS ("could not launch"), never via GOAL_MAX_NO_PROGRESS
#   AC5 a stalled cycle that ran >= MIN_RUN_SECS still parks via the np path ("no progress")
#   AC6 an attempt that ran resets .launchfails to 0                AC7 an unreadable registry goal still holds the line
#   Observability: the launch-failure park logs release / host / route=goal-queue and posts one #engineering alert.
#   Review fixes (PR #526): a resume run on the other host clears the owner's streaks at its next sync; an unconfirmed
#   local park is lifted without clearing them; an unhold does not re-judge the parked attempt; waiting on JP ends the
#   streak; a failed goal_launch backs off TRANSIENT_BACKOFF[streak] (in the AC4 launch-error test).
# Note on AC3 wording: "holds the line exactly as today" — today delivered / stopped / waiting_jp are EXCLUDED from the
# head-of-line check (a goal behind them can start, see test_zq_waiting_jp_releases_the_next_goal_only). The tests pin that
# unchanged exclusion; active and unreadable are the states that hold the line, before and after this change.
# Expected values come from the ticket or hand arithmetic in comments — never from the code under test.
# Prefix t514_ / T514_. Reuses the gs_* sandbox of test-goal-supervisor.sh and the zq_* helpers of test-goal-z-queue.sh
# (function definitions only when this file runs alone; a full run has both loaded already).
# Clock anchors: BACKOFF=(120 300 900 1800), TRANSIENT_BACKOFF=(300 600 1200 1800 3600), MIN_RUN_SECS=180, GOAL_CYCLE_SECS=1200.

T514_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T514_SKILL=$(cd "$T514_HERE/.." && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$T514_HERE/test-goal-supervisor.sh" > "$T514_HERE/.t514-gs-lib.$$.sh"
  . "$T514_HERE/.t514-gs-lib.$$.sh"
  rm -f "$T514_HERE/.t514-gs-lib.$$.sh"
fi
if ! type zq_env >/dev/null 2>&1; then
  sed '/^run_test /,$d' "$T514_HERE/test-goal-z-queue.sh" > "$T514_HERE/.t514-zq-lib.$$.sh"
  . "$T514_HERE/.t514-zq-lib.$$.sh"
  rm -f "$T514_HERE/.t514-zq-lib.$$.sh"
fi

# ---------------------------------------------------------------- queue admission (pure jq) ---------------------

# t514_goal <registry issue> <id> <st> <priority|""> — one registry goal in the shape _GOAL_ISSUE_JQ produces
t514_goal() {
  jq -nc --argjson n "$1" --arg id "$2" --arg st "$3" --arg p "$4" '
    {issue:$n, id:$id, spec:"example-owner/project-a#\($n)", host:"", instructions:"",
     state:(if $st == "delivered" or $st == "stopped" then "closed" else "open" end), closed_at:null, st:$st,
     block:({v:1, id:$id} + (if $p != "" then {priority:($p|tonumber)} else {} end))}'
}
# t514_unreadable <registry issue> — an open registry issue whose block cannot be parsed (block null, st unreadable)
t514_unreadable() {
  jq -nc --argjson n "$1" '{issue:$n, id:"registry-issue-\($n)", spec:"", host:"", instructions:"", state:"open",
                           closed_at:null, block:null, st:"unreadable"}'
}
# t514_candidate <goal json>... -> the candidate id the queue offers, or "null". goal-lib.sh is sourced in a subshell so
# its functions never leak into the shell the other test files share.
t514_candidate() {
  local reg
  reg=$(printf '%s\n' "$@" | jq -sc '.')
  ( . "$T514_SKILL/goal-lib.sh" >/dev/null 2>&1; printf '%s' "$reg" | jq -r "$_GOAL_QUEUE_JQ"' | .candidate.id // "null"' )
}

test_t514_ac1_held_goal_does_not_hold_the_line() {
  local c
  c=$(t514_candidate "$(t514_goal 50 goal-a held 1)" "$(t514_goal 51 goal-b queued 2)")
  assert_eq "$c" "goal-b" "AC1: A held at priority 1, B queued at priority 2 -> candidate is B (was null)" || return 1
}

test_t514_ac2_two_held_goals_do_not_hold_the_line() {
  local c
  c=$(t514_candidate "$(t514_goal 50 goal-a held 1)" "$(t514_goal 51 goal-b held 2)" "$(t514_goal 52 goal-c queued 3)")
  assert_eq "$c" "goal-c" "AC2: A held (1), B held (2), C queued (3) -> candidate is C" || return 1
}

test_t514_ac3_other_exclusions_unchanged_and_active_still_blocks() {
  local st c
  for st in delivered stopped waiting_jp; do
    c=$(t514_candidate "$(t514_goal 50 goal-a "$st" 1)" "$(t514_goal 51 goal-b queued 2)")
    assert_eq "$c" "goal-b" "AC3: an earlier $st goal is still excluded from the head-of-line check (unchanged)" || return 1
  done
  c=$(t514_candidate "$(t514_goal 50 goal-a active 1)" "$(t514_goal 51 goal-b queued 2)")
  assert_eq "$c" "null" "AC3: an earlier active goal still holds the line" || return 1
  c=$(t514_candidate "$(t514_goal 50 goal-a active 1)" "$(t514_goal 51 goal-b held 2)" "$(t514_goal 52 goal-c queued 3)")
  assert_eq "$c" "null" "AC3: an active goal ahead of a held one still holds the line" || return 1
  c=$(t514_candidate "$(t514_goal 50 goal-a queued 1)" "$(t514_goal 51 goal-b queued 2)")
  assert_eq "$c" "goal-a" "AC3: queue order unchanged — the first queued goal is the candidate" || return 1
  c=$(t514_candidate "$(t514_goal 50 goal-a held 3)" "$(t514_goal 51 goal-b queued 1)")
  assert_eq "$c" "goal-b" "AC3: a queued goal ahead of a held one is the candidate (unchanged)" || return 1
}

# An unreadable goal has no block, so it sorts by its registry issue number (50) in the same key space as priority.
# Priority 60 sorts after it (60 > 50): the unreadable goal is first and must hold the line (fail closed).
# Control: priority 40 sorts before it (40 < 50) and is the candidate — proves the fixture order is what the test says.
test_t514_ac7_unreadable_goal_still_holds_the_line() {
  local c
  c=$(t514_candidate "$(t514_unreadable 50)" "$(t514_goal 51 goal-b queued 60)")
  assert_eq "$c" "null" "AC7: an unreadable registry goal ahead in the queue still holds the line" || return 1
  c=$(t514_candidate "$(t514_unreadable 50)" "$(t514_goal 51 goal-b held 45)" "$(t514_goal 52 goal-c queued 60)")
  assert_eq "$c" "null" "AC7: still held by the unreadable goal when a held goal sits in between" || return 1
  c=$(t514_candidate "$(t514_unreadable 50)" "$(t514_goal 51 goal-b queued 40)")
  assert_eq "$c" "goal-b" "AC7 control: a queued goal sorting before the unreadable one is the candidate" || return 1
}

# ---------------------------------------------------------------- queue admission (supervisor tick) -------------

# The incident shape end to end: goal A held on THIS host (cache + .held, no lead running), B queued behind it.
# goal_queue_step re-reads the registry through the same jq, so B must be claimed and its lead launched here.
test_t514_ac1_supervisor_starts_the_goal_behind_a_held_one() {
  zq_env
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" held 1 host-a "" "" 1
  gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a
  touch "$GS_PIPE/goal-$ZQ_A.held"
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 2 "" "" "" 2
  gs_tick
  gs_wait_claude 1 || { gs_cleanup; fail "AC1 tick: the lead of B (queued behind held A) was never launched"; return 1; }
  gs_settle
  local n claims_b claims_a lb=no held_a=no brief
  n=$(gs_claude_count); claims_b=$(zq_claims_by 51 host-a); claims_a=$(zq_claims 50)
  gs_has_label 51 goal-queued && lb=yes
  [ -e "$GS_PIPE/goal-$ZQ_A.held" ] && held_a=yes
  brief=$(cat "$(gs_last_claude)/argv")
  gs_cleanup
  assert_eq "$n" "1" "AC1 tick: exactly one lead launched" || return 1
  assert_contains "$brief" "$ZQ_B" "AC1 tick: the launched lead is goal B's" || return 1
  assert_eq "$claims_b" "1" "AC1 tick: B is claimed by this host" || return 1
  assert_eq "$lb" "no" "AC1 tick: B left the queue" || return 1
  assert_eq "$claims_a" "0" "AC1 tick: the held goal is not started from the queue" || return 1
  assert_eq "$held_a" "yes" "AC1 tick: the held goal stays held (its own resume rules are untouched)" || return 1
}

# ---------------------------------------------------------------- launch failures vs no progress -----------------

# t514_slack — route notify_engineering to a recording fake curl (the existing #engineering path, as in test-goal-z-queue)
t514_slack() {
  printf 'SLACK_BOT_TOKEN=xoxb-test-token\nSLACK_ENGINEERING_CHANNEL=C0TEST\n' >> "$GS_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/curl-calls.log"\necho "{\\"ok\\":true}"\n' "$GS_BIN" > "$GS_BIN/curl"; chmod +x "$GS_BIN/curl"
}

# The incident path: the lead starts and dies non-zero within seconds (e.g. an expired login), so goal_launch itself returns 0.
# Hand arithmetic: launched 2050 s ago, exited 2000 s ago -> run 50 s < MIN_RUN_SECS 180 -> a launch failure.
# Wait TRANSIENT_BACKOFF[.restarts]: decisions 1-3 run with .restarts 0, 1, 2 -> 300, 600, 1200 s, all < 2000 (>= 60 s margin).
# Scope ms-12 is unchanged throughout. Decisions 1 and 2 count launch failures 1 and 2 and relaunch (2 launches);
# decision 3 reaches GOAL_MAX_LAUNCH_FAILS=3 and parks without launching. The scope np is never touched (no .np file).
# Before #514 the same fixture gave np 0, 1, 2 and no park until a 4th decision, with the "no progress" note.
test_t514_ac4_fast_exits_park_as_could_not_launch() {
  gs_env; t514_slack
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 2050 1 2000
  local k c lf np held=absent
  for k in 1 2; do
    [ "$k" -gt 1 ] && gs_launch_state "$GS_ID_MS12" 2050 1 2000
    gs_tick; gs_wait_claude "$k"; gs_settle
    c=$(gs_claude_count); lf=$(gs_file "$GS_ID_MS12" launchfails); np=$(gs_file "$GS_ID_MS12" np)
    [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
    assert_eq "$held" "absent" "AC4: not parked at decision $k" || { gs_cleanup; return 1; }
    assert_eq "$c" "$k" "AC4: decision $k relaunches" || { gs_cleanup; return 1; }
    assert_eq "$lf" "$k" "AC4: .launchfails after decision $k" || { gs_cleanup; return 1; }
    assert_eq "$np" "MISSING" "AC4: the scope np is not counted for a launch failure (decision $k)" || { gs_cleanup; return 1; }
  done
  gs_launch_state "$GS_ID_MS12" 2050 1 2000
  gs_tick; gs_settle
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  local c3 lf3 np3 lab cl np_notes state
  c3=$(gs_claude_count); lf3=$(gs_file "$GS_ID_MS12" launchfails); np3=$(gs_file "$GS_ID_MS12" np)
  gs_has_label 50 goal-held && lab=yes || lab=no
  cl=$(gs_reg_comment_count 50 '**[deliver] NOTE** held: could not launch in 3 consecutive attempts')
  np_notes=$(gs_reg_comment_count 50 'no progress')
  state=$(gs_json "$GS_ID_MS12" state)
  # observability: one slog line with release / host / route, one #engineering alert for the streak
  local log rel alerts alert_text
  log=$(gs_log); rel=$(git -C "$GS_TREE" rev-parse HEAD | cut -c1-7)
  alerts=$(grep -c 'chat.postMessage' "$GS_BIN/curl-calls.log" 2>/dev/null || echo 0)
  alert_text=$(cat "$GS_BIN/curl-calls.log" 2>/dev/null)
  gs_tick; gs_settle   # a held goal is not relaunched and not re-alerted
  local c4 alerts4 cl4
  c4=$(gs_claude_count); alerts4=$(grep -c 'chat.postMessage' "$GS_BIN/curl-calls.log" 2>/dev/null || echo 0)
  cl4=$(gs_reg_comment_count 50 'held: could not launch')
  gs_cleanup
  assert_eq "$held" "present" "AC4: parked at the third launch failure" || return 1
  assert_eq "$lf3" "3" "AC4: .launchfails reached GOAL_MAX_LAUNCH_FAILS" || return 1
  assert_eq "$np3" "MISSING" "AC4: parked by launch failures, not by the scope np" || return 1
  assert_eq "$c3" "2" "AC4: the parking decision does not launch" || return 1
  assert_eq "$lab" "yes" "AC4: label goal-held" || return 1
  assert_eq "$cl" "1" "AC4: one held note naming 'could not launch'" || return 1
  assert_eq "$np_notes" "0" "AC4: no 'no progress' note" || return 1
  assert_eq "$state" "held" "AC4: cache mirror state held" || return 1
  printf '%s\n' "$log" | grep -F "[goal] $GS_ID_MS12 held — could not launch in 3 consecutive attempts" \
    | grep -F "release=$rel" | grep -F "host=" | grep -qF "route=goal-queue" \
    || { fail "AC4 observability: no launch-failure park slog line with release/host/route in:
$log"; return 1; }
  printf '%s\n' "$log" | grep -qF "[goal] $GS_ID_MS12 held — no progress" && { fail "AC4: a 'no progress' slog line was written"; return 1; }
  assert_eq "$alerts" "1" "AC4 observability: one #engineering alert for the streak" || return 1
  assert_contains "$alert_text" "could not launch in 3 consecutive attempts" "AC4 observability: the alert names the failure mode" || return 1
  assert_contains "$alert_text" "$GS_ID_MS12" "AC4 observability: the alert names the goal" || return 1
  assert_contains "$alert_text" "release $rel" "AC4 observability: the alert carries the release" || return 1
  assert_eq "$c4" "2" "AC4: a goal held for launch failures is not relaunched" || return 1
  assert_eq "$alerts4" "1" "AC4 observability: no second alert on the next tick" || return 1
  assert_eq "$cl4" "1" "AC4: the held note is posted once" || return 1
}

# t514_fail_goal_find — the full registry read (closed goals with no `since`, used only by _goal_find, which goal_launch
# calls to load the goal) fails like a transient GitHub error; every other read still answers. So the scope evaluation
# works and goal_launch returns non-zero before any process starts.
t514_fail_goal_find() {
  mv "$GS_BIN/gh" "$GS_BIN/gh.t514"
  cat > "$GS_BIN/gh" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in *labels=delivery-goal*state=closed*) case "$*" in *since=*) ;; *) echo "gh: HTTP 502" >&2; exit 1 ;; esac ;; esac
exec "$HERE/gh.t514" "$@"
EOF
  chmod +x "$GS_BIN/gh"
}

# goal_launch itself fails (it cannot load the goal from the registry: it returns non-zero before any process starts).
# Hand arithmetic: launched 3600 s ago, clean exit 1300 s ago -> past GOAL_CYCLE_SECS 1200 -> decision 1 (a cycle that ran:
# np path, no .snap yet -> np 0). Its launch fails and leaves .launch-failed (.exit, .launched-at stay). Review fix: the
# next decision waits TRANSIENT_BACKOFF[streak] from that marker — streak 0, 1, 2 -> 300, 600, 1200 s — so a tick right
# after a failure (marker ~1 s old) is no decision, and with the marker aged 1300 s (>= 100 s past every wait) it is.
# Decisions 2 and 3 count launch failures 1 and 2 (np stays 0) and their launches fail again; decision 4 counts the third
# and parks. Before #514 these decisions gave np 1, 2, 3 and parked with the "no progress" note.
test_t514_ac4_goal_launch_errors_park_as_could_not_launch() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 0 1300
  t514_fail_goal_find
  local k lf np held=absent was
  gs_tick; gs_settle
  np=$(gs_file "$GS_ID_MS12" np); lf=$(gs_file "$GS_ID_MS12" launchfails)
  assert_eq "$np" "0" "AC4 launch error: decision 1 is a cycle that ran (np path)" || { gs_cleanup; return 1; }
  assert_eq "$lf" "MISSING" "AC4 launch error: decision 1 counts no launch failure yet" || { gs_cleanup; return 1; }
  for k in 1 2; do
    was=$lf
    gs_tick; gs_settle   # inside the backoff: no decision
    lf=$(gs_file "$GS_ID_MS12" launchfails)
    assert_eq "$lf" "$was" "AC4 launch error: no decision within TRANSIENT_BACKOFF of failed launch $k" || { gs_cleanup; return 1; }
    gs_touch_ago "$GS_PIPE/goal-$GS_ID_MS12.launch-failed" 1300
    gs_tick; gs_settle
    np=$(gs_file "$GS_ID_MS12" np); lf=$(gs_file "$GS_ID_MS12" launchfails)
    [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
    assert_eq "$lf" "$k" "AC4 launch error: launch failure $k counted" || { gs_cleanup; return 1; }
    assert_eq "$np" "0" "AC4 launch error: np unchanged after failed launch $k" || { gs_cleanup; return 1; }
    assert_eq "$held" "absent" "AC4 launch error: not parked after failure $k" || { gs_cleanup; return 1; }
  done
  gs_touch_ago "$GS_PIPE/goal-$GS_ID_MS12.launch-failed" 1300
  gs_tick; gs_settle
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  local c cl np_notes
  c=$(gs_claude_count); lf=$(gs_file "$GS_ID_MS12" launchfails); np=$(gs_file "$GS_ID_MS12" np)
  cl=$(gs_reg_comment_count 50 'held: could not launch in 3 consecutive attempts'); np_notes=$(gs_reg_comment_count 50 'no progress')
  gs_cleanup
  assert_eq "$held" "present" "AC4 launch error: parked after three failed launches" || return 1
  assert_eq "$lf" "3" "AC4 launch error: .launchfails reached GOAL_MAX_LAUNCH_FAILS" || return 1
  assert_eq "$np" "0" "AC4 launch error: the scope np never moved" || return 1
  assert_eq "$cl" "1" "AC4 launch error: the held note names 'could not launch'" || return 1
  assert_eq "$np_notes" "0" "AC4 launch error: no 'no progress' note" || return 1
  assert_eq "$c" "0" "AC4 launch error: no lead process ever started" || return 1
}

# A genuine stall: every cycle ran >= MIN_RUN_SECS and exited non-zero, scope unchanged -> the np path, as before #514.
# Hand arithmetic: launched 2600 s ago, exited 2000 s ago -> run 600 s >= 180 -> not a launch failure. Wait BACKOFF[.restarts]:
# decisions 1-4 with .restarts 0..3 -> 120, 300, 900, 1800 s, all < 2000. np = 0, 1, 2 on decisions 1-3 (decision 1 has no
# .snap), decision 4 reaches GOAL_MAX_NO_PROGRESS=3 and parks with the "no progress" note.
test_t514_ac5_stalled_cycles_still_park_via_np() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 2600 1 2000
  local k np lf
  for k in 1 2 3; do
    [ "$k" -gt 1 ] && gs_launch_state "$GS_ID_MS12" 2600 1 2000
    gs_tick; gs_wait_claude "$k"; gs_settle
    np=$(gs_file "$GS_ID_MS12" np); lf=$(gs_file "$GS_ID_MS12" launchfails)
    assert_eq "$np" "$((k - 1))" "AC5: .np after decision $k" || { gs_cleanup; return 1; }
    assert_eq "$lf" "MISSING" "AC5: no launch failure counted at decision $k" || { gs_cleanup; return 1; }
  done
  gs_launch_state "$GS_ID_MS12" 2600 1 2000
  gs_tick; gs_settle
  local held=absent c np4 notes cl
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  c=$(gs_claude_count); np4=$(gs_file "$GS_ID_MS12" np)
  notes=$(gs_reg_comment_count 50 '**[deliver] NOTE** held: no progress in 3 cycles')
  cl=$(gs_reg_comment_count 50 'could not launch')
  local log; log=$(gs_log)
  gs_cleanup
  assert_eq "$held" "present" "AC5: parked at the fourth decision" || return 1
  assert_eq "$np4" "3" "AC5: .np reached GOAL_MAX_NO_PROGRESS" || return 1
  assert_eq "$c" "3" "AC5: the parking decision does not launch" || return 1
  assert_eq "$notes" "1" "AC5: the held note is the unchanged 'no progress in 3 cycles' text" || return 1
  assert_eq "$cl" "0" "AC5: no 'could not launch' note" || return 1
  printf '%s\n' "$log" | grep -qF "[goal] $GS_ID_MS12 held — no progress in 3 cycles" \
    || { fail "AC5: the 'no progress' slog line changed or is missing in:
$log"; return 1; }
}

# A launch failure (fast exit) then a cycle that ran: the streak resets to 0, and the next fast exit counts from 1 again.
# Hand arithmetic: decision 1 — run 50 s (launched 2050 s ago, exited 2000 s ago) < 180 -> launchfails 1, np untouched.
# Decision 2 — clean exit, launched 3600 s ago, exited 1300 s ago (> GOAL_CYCLE_SECS 1200) -> ran: launchfails 0, np path
# (no .snap yet -> np 0). Decision 3 — run 50 s again; .restarts is 0 after the clean exit -> TRANSIENT_BACKOFF[0] 300 < 2000
# -> launchfails 1 (not 2).
test_t514_ac6_an_attempt_that_ran_resets_launchfails() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 2050 1 2000
  gs_tick; gs_wait_claude 1; gs_settle
  local lf1 np1; lf1=$(gs_file "$GS_ID_MS12" launchfails); np1=$(gs_file "$GS_ID_MS12" np)
  gs_launch_state "$GS_ID_MS12" 3600 0 1300
  gs_tick; gs_wait_claude 2; gs_settle
  local lf2 np2; lf2=$(gs_file "$GS_ID_MS12" launchfails); np2=$(gs_file "$GS_ID_MS12" np)
  gs_launch_state "$GS_ID_MS12" 2050 1 2000
  gs_tick; gs_wait_claude 3; gs_settle
  local lf3 np3 c; lf3=$(gs_file "$GS_ID_MS12" launchfails); np3=$(gs_file "$GS_ID_MS12" np); c=$(gs_claude_count)
  gs_cleanup
  assert_eq "$lf1" "1" "AC6: a fast exit counts one launch failure" || return 1
  assert_eq "$np1" "MISSING" "AC6: and leaves the scope np alone" || return 1
  assert_eq "$lf2" "0" "AC6: a cycle that ran resets .launchfails to 0" || return 1
  assert_eq "$np2" "0" "AC6: and goes through the np path" || return 1
  assert_eq "$lf3" "1" "AC6: the next fast exit starts a new streak at 1" || return 1
  assert_eq "$np3" "0" "AC6: np unchanged by that launch failure" || return 1
  assert_eq "$c" "3" "AC6: every decision relaunched (nothing parked)" || return 1
}

# ---------------------------------------------------------------- review fixes (PR #526) -------------------------

# t514_resume_on_host_b — run the real `deliver.sh resume <ms-12>` as the OTHER host: hostname Host-B, its own PIPE / LOGDIR,
# the same fake GitHub (the gh fake keeps its store next to itself in $GS_BIN). The goal is pinned to host-a, so host B
# only edits the registry (reopen, drop goal-held / goal-stopped) and prints "pinned to". Prints deliver.sh's output.
t514_resume_on_host_b() {
  local b="$GS_HOME/host-b-bin"
  mkdir -p "$b" "$GS_HOME/host-b-pipe"
  printf '#!/bin/bash\necho Host-B\n' > "$b/hostname"; chmod +x "$b/hostname"
  ( cd "$GS_HOME" && env HOME="$GS_HOME" PATH="$b:$GS_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
      PIPE="$GS_HOME/host-b-pipe" QUEUE="$GS_HOME/host-b-pipe/queue" LOGDIR="$GS_HOME/logs/host-b" \
      bash "$GS_TREE/skills/orchestrate/deliver.sh" resume "$GS_ID_MS12" 2>&1 </dev/null )
}

# HIGH: a goal pinned to host-a (this host) is parked for launch failures, then resumed from host B. Host A must clear its
# own streaks at its next sync, not re-park the goal on its stale .launchfails and the last attempt's fast .exit.
# Hand arithmetic: three fast exits (launched 2050 s ago, exited 2000 s ago, run 50 s < 180) park it exactly as in AC4:
# 2 launches, .launchfails 3, one held note, one alert; the third fast .exit stays behind. After the resume, host A's tick:
# with the streaks cleared there is no .exit and no .restarts, so the wait is BACKOFF[0] 120 s from a launch 2050 s ago ->
# a decision that is not a launch failure -> launchfails 0 and the 3rd launch. Before this fix the same tick saw run 50 s
# (fast), counted launch failure 4 and parked again: a second held note, a second alert and no launch.
test_t514_review_resume_from_the_other_host_clears_the_owner_streaks() {
  gs_env; t514_slack
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 2050 1 2000
  local k
  for k in 1 2 3; do
    [ "$k" -gt 1 ] && gs_launch_state "$GS_ID_MS12" 2050 1 2000
    gs_tick; gs_settle
  done
  local held0=absent lf0 c0 alerts0 lab0=no
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held0=present
  lf0=$(gs_file "$GS_ID_MS12" launchfails); c0=$(gs_claude_count)
  alerts0=$(grep -c 'chat.postMessage' "$GS_BIN/curl-calls.log" 2>/dev/null || echo 0)
  gs_has_label 50 goal-held && lab0=yes
  local out
  out=$(t514_resume_on_host_b)
  local lab_b=no st_b
  gs_has_label 50 goal-held && lab_b=yes; st_b=$(gs_reg_state 50)
  gs_tick; gs_wait_claude 3; gs_settle
  local held1=absent lf1 c1 alerts1 cl1 log b_launches
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held1=present
  lf1=$(gs_file "$GS_ID_MS12" launchfails); c1=$(gs_claude_count)
  alerts1=$(grep -c 'chat.postMessage' "$GS_BIN/curl-calls.log" 2>/dev/null || echo 0)
  cl1=$(gs_reg_comment_count 50 'held: could not launch')
  log=$(gs_log)
  b_launches=$(ls "$GS_HOME/host-b-pipe"/goal-*.pid 2>/dev/null | wc -l | tr -d ' ')
  gs_cleanup
  # the park this test starts from
  assert_eq "$held0" "present" "review HIGH setup: parked on host A" || return 1
  assert_eq "$lf0" "3" "review HIGH setup: .launchfails 3 on host A" || return 1
  assert_eq "$lab0" "yes" "review HIGH setup: goal-held on the registry issue" || return 1
  assert_eq "$c0" "2" "review HIGH setup: 2 launches before the park" || return 1
  assert_eq "$alerts0" "1" "review HIGH setup: one alert for the streak" || return 1
  # the resume ran on host B and only touched the registry
  assert_contains "$out" "pinned to host-a" "review HIGH: host B does not run a goal pinned to host-a" || return 1
  assert_eq "$lab_b" "no" "review HIGH: host B's resume dropped goal-held" || return 1
  assert_eq "$st_b" "open" "review HIGH: registry issue open" || return 1
  assert_eq "$b_launches" "0" "review HIGH: nothing launched on host B" || return 1
  # host A, the owner, picks the resume up at its next sync
  assert_eq "$held1" "absent" "review HIGH: host A unheld the goal" || return 1
  assert_eq "$lf1" "0" "review HIGH: host A's launch-failure streak cleared" || return 1
  assert_eq "$c1" "3" "review HIGH: host A relaunched the resumed goal on its first decision" || return 1
  assert_eq "$cl1" "1" "review HIGH: no second 'could not launch' park" || return 1
  assert_eq "$alerts1" "1" "review HIGH: no second #engineering alert" || return 1
  printf '%s\n' "$log" | grep -qF "[goal] $GS_ID_MS12 resumed in the registry" \
    || { fail "review HIGH: no 'resumed in the registry' slog line on host A in:
$log"; return 1; }
}

# A local park whose label write never reached the registry is not a resume: the sync lifts .held as it always did, but the
# streaks stay (so the goal re-parks at its next decision instead of getting fresh tries). Hand arithmetic: launched 100 s
# ago, exited 50 s ago (fast) -> TRANSIENT_BACKOFF[0] 300 s not reached -> no decision this tick.
test_t514_review_unconfirmed_park_is_lifted_without_clearing_streaks() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 100 1 50
  touch "$GS_PIPE/goal-$GS_ID_MS12.held"; echo 2 > "$GS_PIPE/goal-$GS_ID_MS12.launchfails"
  gs_tick; gs_settle
  local held=absent lf c log
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  lf=$(gs_file "$GS_ID_MS12" launchfails); c=$(gs_claude_count); log=$(gs_log)
  gs_cleanup
  assert_eq "$held" "absent" "review: an unconfirmed local park is lifted by the sync (unchanged)" || return 1
  assert_eq "$lf" "2" "review: and its launch-failure streak is kept" || return 1
  assert_eq "$c" "0" "review: no decision inside the backoff" || return 1
  printf '%s\n' "$log" | grep -qF "resumed in the registry" && { fail "review: an unconfirmed park was read as a resume"; return 1; }
  return 0
}

# The local "scope changed" unhold: the goal gets its full GOAL_MAX_LAUNCH_FAILS tries, so the last attempt's fast .exit
# (already judged when it was parked) must not count again. Hand arithmetic: parked with .launchfails 3 and a fast .exit
# (launched 2050 s ago, exited 2000 s ago). Tick 1: the stored snapshot differs from the live scope -> unheld. Tick 2: no
# non-zero .exit left -> BACKOFF[0] 120 s from the launch 2050 s ago -> a decision that is no launch failure -> launchfails 0
# and a launch. Before this fix tick 2 counted the old fast exit again (launchfails 1).
test_t514_review_scope_unhold_does_not_rejudge_the_parked_attempt() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 2050 1 2000
  gs_reg 50 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a held
  echo registry > "$GS_PIPE/goal-$GS_ID_MS12.held"; echo 3 > "$GS_PIPE/goal-$GS_ID_MS12.launchfails"
  echo "stale snapshot" > "$GS_PIPE/goal-$GS_ID_MS12.snap"
  gs_tick; gs_settle
  local held=absent lf1 c1
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  lf1=$(gs_file "$GS_ID_MS12" launchfails); c1=$(gs_claude_count)
  gs_tick; gs_wait_claude 1; gs_settle
  local lf2 c2
  lf2=$(gs_file "$GS_ID_MS12" launchfails); c2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$held" "absent" "review: scope change unholds the goal" || return 1
  assert_eq "$lf1" "0" "review: the unhold resets the launch-failure streak" || return 1
  assert_eq "$c1" "0" "review: the unholding tick does not launch" || return 1
  assert_eq "$lf2" "0" "review: the parked attempt's fast exit is not counted a second time" || return 1
  assert_eq "$c2" "1" "review: the next decision launches" || return 1
}

# MEDIUM: a decision that ends waiting on JP ends the launch-failure streak. Hand arithmetic: 101 carries DEPLOYED TO
# STAGING (waiting on JP), 102 is closed, 103 is a PR -> 0 active, 1 waiting. Launched 2050 s ago, fast exit 2000 s ago ->
# TRANSIENT_BACKOFF[0] 300 s passed -> a decision, which takes the waiting-on-JP branch. Before this fix .launchfails kept 2.
test_t514_review_waiting_on_jp_ends_the_launch_failure_streak() {
  gs_env
  gs_comment 101 $'**[deployer] DEPLOYED TO STAGING**\nstaging up'
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 2050 1 2000
  echo 2 > "$GS_PIPE/goal-$GS_ID_MS12.launchfails"
  gs_tick; gs_settle
  local lab=no lf c
  gs_has_label 50 goal-waiting-jp && lab=yes
  lf=$(gs_file "$GS_ID_MS12" launchfails); c=$(gs_claude_count)
  gs_cleanup
  assert_eq "$lab" "yes" "review MEDIUM: the decision ended waiting on JP" || return 1
  assert_eq "$c" "0" "review MEDIUM: nothing launched while waiting on JP" || return 1
  case "$lf" in 0|MISSING) ;; *) fail "review MEDIUM: .launchfails is $lf after a waiting-on-JP decision (want 0 or none)"; return 1 ;; esac
}

echo "-- goal queue held / launch failures (#514)"
run_test test_t514_ac1_held_goal_does_not_hold_the_line
run_test test_t514_ac2_two_held_goals_do_not_hold_the_line
run_test test_t514_ac3_other_exclusions_unchanged_and_active_still_blocks
run_test test_t514_ac7_unreadable_goal_still_holds_the_line
run_test test_t514_ac1_supervisor_starts_the_goal_behind_a_held_one
run_test test_t514_ac4_fast_exits_park_as_could_not_launch
run_test test_t514_ac4_goal_launch_errors_park_as_could_not_launch
run_test test_t514_ac5_stalled_cycles_still_park_via_np
run_test test_t514_ac6_an_attempt_that_ran_resets_launchfails
run_test test_t514_review_resume_from_the_other_host_clears_the_owner_streaks
run_test test_t514_review_unconfirmed_park_is_lifted_without_clearing_streaks
run_test test_t514_review_scope_unhold_does_not_rejudge_the_parked_attempt
run_test test_t514_review_waiting_on_jp_ends_the_launch_failure_streak
gs_tree_cleanup
