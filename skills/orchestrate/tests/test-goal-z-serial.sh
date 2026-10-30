# One goal at a time across both hosts (GOAL_SERIAL, JP 2026-10-30).
#   S1 queue admission (pure jq): any active goal holds the one slot, wherever it sits in the order; a running feedback goal
#      does not hold it unless GOAL_SERIAL_FEEDBACK=1 (a queued one still waits its turn); an unreadable entry fails closed; GOAL_SERIAL=0 gives byte-identical queue output.
#   S2 supervisor ticks: two queued goals, both hosts ticking -> exactly one lead; a later-priority active goal elsewhere
#      blocks an earlier queued one (serial) but not with GOAL_SERIAL=0 (today's rule).
#   S3 an extra active goal (hand launch / already running) is returned to the queue at the end of its cycle, never killed;
#      the slot holder relaunches; with GOAL_SERIAL=0 both relaunch as today.
#   S4 a goal back from waiting on JP rejoins the queue instead of relaunching.
#   S5 spread: with SHARED_DISPATCH_ENABLED=0 the host without the lead dispatches the slot goal's agent-go tickets (never a
#      bare agent-go ticket); the lead's own host leaves them to the live lead; GOAL_SERIAL=0 dispatches none (today).
#   S6 two-host race: the claim settles one start; a goal that takes the slot during the settle wait stops the start.
# Expected values come from the request or hand arithmetic in comments — never from the code under test.
# Prefix zs_ / ZS_. Reuses the gs_* sandbox (test-goal-supervisor.sh) and zq_* helpers (test-goal-z-queue.sh).

ZS_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ZS_SKILL=$(cd "$ZS_HERE/.." && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$ZS_HERE/test-goal-supervisor.sh" > "$ZS_HERE/.zs-gs-lib.$$.sh"
  . "$ZS_HERE/.zs-gs-lib.$$.sh"
  rm -f "$ZS_HERE/.zs-gs-lib.$$.sh"
fi
if ! type zq_env >/dev/null 2>&1; then
  sed '/^run_test /,$d' "$ZS_HERE/test-goal-z-queue.sh" > "$ZS_HERE/.zs-zq-lib.$$.sh"
  . "$ZS_HERE/.zs-zq-lib.$$.sh"
  rm -f "$ZS_HERE/.zs-zq-lib.$$.sh"
fi

# ---------------------------------------------------------------- S1: queue admission (pure jq) -----------------

# zs_goal <registry issue> <id> <st> <priority> [spec] — one registry goal in the shape _GOAL_ISSUE_JQ produces
zs_goal() {
  jq -nc --argjson n "$1" --arg id "$2" --arg st "$3" --arg p "$4" --arg spec "${5:-example-owner/project-a#$1}" '
    {issue:$n, id:$id, spec:$spec, host:"", instructions:"",
     state:(if $st == "delivered" or $st == "stopped" then "closed" else "open" end), closed_at:null, st:$st,
     block:{v:1, id:$id, spec:$spec, priority:($p|tonumber)}}'
}
zs_unreadable() {
  jq -nc --argjson n "$1" '{issue:$n, id:"registry-issue-\($n)", spec:"", host:"", instructions:"", state:"open", closed_at:null, block:null, st:"unreadable"}'
}
# zs_q <serial 0|1> <feedback 0|1> <field: candidate|slot> <goal json>... -> that field's id, or "null"
zs_q() {
  local s=$1 fb=$2 field=$3 reg; shift 3
  reg=$(printf '%s\n' "$@" | jq -sc '.')
  ( . "$ZS_SKILL/goal-lib.sh" >/dev/null 2>&1; GOAL_SERIAL=$s GOAL_SERIAL_FEEDBACK=$fb
    printf '%s' "$reg" | _goal_queue_jq " | (.$field | if type == \"object\" then .id elif . == null then \"null\" else . end)" | jq -r . )
}

test_zs_s1_any_active_goal_holds_the_slot() {
  local c
  # A queued at priority 1, B active at priority 2 (later in the order): today A starts; serial: the slot is B's.
  c=$(zs_q 0 0 candidate "$(zs_goal 50 goal-a queued 1)" "$(zs_goal 51 goal-b active 2)")
  assert_eq "$c" "goal-a" "S1 off: an active goal LATER in the order does not hold the line (today)" || return 1
  c=$(zs_q 1 0 candidate "$(zs_goal 50 goal-a queued 1)" "$(zs_goal 51 goal-b active 2)")
  assert_eq "$c" "null" "S1 serial: an active goal anywhere holds the one slot" || return 1
  c=$(zs_q 1 0 slot "$(zs_goal 50 goal-a queued 1)" "$(zs_goal 51 goal-b active 2)")
  assert_eq "$c" "goal-b" "S1 serial: the slot is the active goal's" || return 1
  # two active (a hand launch): the slot is the first in order
  c=$(zs_q 1 0 slot "$(zs_goal 50 goal-a active 3)" "$(zs_goal 51 goal-b active 2)")
  assert_eq "$c" "goal-b" "S1 serial: with two active goals the slot is the first by priority" || return 1
  # nothing active: the first queued goal (waiting / held / delivered do not hold the slot)
  c=$(zs_q 1 0 candidate "$(zs_goal 50 goal-a waiting_jp 1)" "$(zs_goal 51 goal-b held 2)" "$(zs_goal 52 goal-c queued 4)" "$(zs_goal 53 goal-d queued 3)")
  assert_eq "$c" "goal-d" "S1 serial: slot free -> the first queued goal by priority (3 before 4)" || return 1
  c=$(zs_q 1 0 slot "$(zs_goal 50 goal-a waiting_jp 1)" "$(zs_goal 52 goal-c queued 4)")
  assert_eq "$c" "null" "S1 serial: waiting on JP frees the slot" || return 1
}

test_zs_s1_feedback_goals_exempt_by_default() {
  local fb=example-owner/project-a:feedback c
  c=$(zs_q 1 0 candidate "$(zs_goal 50 goal-a active 1)" "$(zs_goal 51 goal-fb queued 2 "$fb")")
  assert_eq "$c" "null" "S1 serial: a queued feedback goal still waits for its turn (no queue jumping)" || return 1
  c=$(zs_q 1 0 candidate "$(zs_goal 50 goal-fb queued 1 "$fb")" "$(zs_goal 51 goal-b queued 2)")
  assert_eq "$c" "goal-fb" "S1 serial: slot free -> a feedback goal first in line starts" || return 1
  c=$(zs_q 1 0 candidate "$(zs_goal 50 goal-fb active 1 "$fb")" "$(zs_goal 51 goal-b queued 2)")
  assert_eq "$c" "goal-b" "S1 serial: an active feedback goal does not hold the slot" || return 1
  c=$(zs_q 1 0 slot "$(zs_goal 50 goal-fb active 1 "$fb")" "$(zs_goal 51 goal-b queued 2)")
  assert_eq "$c" "null" "S1 serial: ... and is never the slot holder" || return 1
  c=$(zs_q 1 1 candidate "$(zs_goal 50 goal-fb active 1 "$fb")" "$(zs_goal 51 goal-b queued 2)")
  assert_eq "$c" "null" "S1 GOAL_SERIAL_FEEDBACK=1: an active feedback goal holds the slot" || return 1
}

test_zs_s1_unreadable_entry_fails_closed() {
  local c
  # unreadable sorts by its issue number 60, after the queued goal at priority 1: today it does not block; serial: it does
  c=$(zs_q 0 0 candidate "$(zs_goal 50 goal-a queued 1)" "$(zs_unreadable 60)")
  assert_eq "$c" "goal-a" "S1 off: an unreadable entry behind the queued goal does not block (today)" || return 1
  c=$(zs_q 1 0 candidate "$(zs_goal 50 goal-a queued 1)" "$(zs_unreadable 60)")
  assert_eq "$c" "null" "S1 serial: an unreadable entry anywhere may be an active goal -> nothing starts" || return 1
}

test_zs_s1_off_output_is_byte_identical_to_the_old_jq() {
  local reg a b
  reg=$(printf '%s\n' "$(zs_goal 50 goal-a queued 1)" "$(zs_goal 51 goal-b active 2)" "$(zs_goal 52 goal-c held 3)" \
    "$(zs_goal 53 goal-d delivered 4)" "$(zs_unreadable 70)" "$(zs_goal 54 goal-e waiting_jp 5 example-owner/project-a:feedback)" | jq -sc '.')
  a=$( ( . "$ZS_SKILL/goal-lib.sh" >/dev/null 2>&1; printf '%s' "$reg" | jq -c "$_GOAL_QUEUE_JQ" ) )
  b=$( ( . "$ZS_SKILL/goal-lib.sh" >/dev/null 2>&1; GOAL_SERIAL=0; printf '%s' "$reg" | _goal_queue_jq '' ) )
  assert_eq "$b" "$a" "S1 off: GOAL_SERIAL=0 runs exactly the pre-change queue jq" || return 1
}

# ---------------------------------------------------------------- sandbox helpers -------------------------------

# zs_mode <0|1> — GOAL_SERIAL for every tick of this sandbox (config.local.sh is sourced after config.sh)
zs_mode() { echo "GOAL_SERIAL=$1" >> "$GS_HOME/.claude/pipeline/config.local.sh"; }

# zs_host_b — a second host ("Host-B") on the SAME fake GitHub: own HOME / PIPE / claude recorder, gh forwarded to host A's store.
zs_host_b() {
  ZS_HOME_B=$(new_home); ZS_PIPE_B=$(new_pipe); ZS_BIN_B="$ZS_HOME_B/.local/bin"
  mkdir -p "$ZS_BIN_B"
  printf '#!/bin/bash\necho "Host-B"\n' > "$ZS_BIN_B/hostname"
  printf '#!/bin/bash\nexec "%s/gh" "$@"\n' "$GS_BIN" > "$ZS_BIN_B/gh"
  cp "$GS_BIN/uname" "$GS_BIN/pmset" "$GS_BIN/claude" "$ZS_BIN_B/"
  cp "$GS_BIN/kind" "$ZS_BIN_B/kind" 2>/dev/null; cp "$GS_BIN/ac" "$ZS_BIN_B/ac" 2>/dev/null
  chmod +x "$ZS_BIN_B"/*
  cp "$GS_HOME/.claude/pipeline/config.local.sh" "$ZS_HOME_B/.claude/pipeline/config.local.sh"
}
zs_tick_b() {
  ( cd "$ZS_HOME_B" && env HOME="$ZS_HOME_B" PATH="$ZS_BIN_B:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$ZS_PIPE_B" QUEUE="$ZS_PIPE_B/queue" \
      LOGDIR="$ZS_HOME_B/logs/pipeline" GS_RS_LOG="$GS_RS_LOG" SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" STATUS_PUSH_URL="" STATUS_PUSH_TOKEN="" \
      bash "$GS_TREE/skills/orchestrate/supervisor.sh" >"$ZS_HOME_B/tick.out" 2>&1 </dev/null ) || true
  sleep 0.4
}
zs_claude_count_b() { ls -d "$ZS_BIN_B"/claude-calls.* 2>/dev/null | wc -l | tr -d ' '; }
zs_cleanup_b() {
  local p
  for p in "$ZS_PIPE_B"/goal-*.pid; do [ -e "$p" ] || continue; pkill -TERM -P "$(cat "$p" 2>/dev/null)" 2>/dev/null; kill "$(cat "$p" 2>/dev/null)" 2>/dev/null; done
  rm -rf "$ZS_HOME_B" "$ZS_PIPE_B"
}
zs_leads_total() { echo $(( $(gs_claude_count) + $(zs_claude_count_b) )); }

# ---------------------------------------------------------------- S2: one lead across both hosts -------------------

# B (priority 1) and C (priority 2) queued, nothing active, both hosts are VMs (no Mac wait) ticking in turn: B starts on one
# host; C must not start on either host while B is active (today C would start on the other host: two goals at once).
test_zs_s2_two_queued_goals_two_hosts_one_lead() {
  zq_env; zs_mode 1; zs_host_b
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 2 ""
  gs_tick; gs_wait_claude 1
  zs_tick_b; gs_tick; zs_tick_b; gs_settle
  local n c_claims b_host lc=no
  n=$(zs_leads_total); c_claims=$(zq_claims 52); b_host=$(zq_block_field 51 host)
  gs_has_label 52 goal-queued && lc=yes
  zs_cleanup_b; gs_cleanup
  assert_eq "$n" "1" "S2 serial: exactly one lead across both hosts" || return 1
  assert_eq "$b_host" "host-a" "S2 serial: the first goal by priority started (on the host that ticked first)" || return 1
  assert_eq "$c_claims" "0" "S2 serial: the second goal posts no claim on either host" || return 1
  assert_eq "$lc" "yes" "S2 serial: the second goal stays queued" || return 1
}

# zs_two_hosts_later_active <mode> — A active at priority 5 with its lead live on host A; B queued at priority 1; host B ticks.
# Prints the number of leads alive across both hosts. Serial: 1 (B waits for the slot); off: 2 (today: B starts on host B).
zs_two_hosts_later_active() {
  zq_env; zs_mode "$1"; zs_host_b
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 5 host-a; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a; gs_live "$ZQ_A"
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zs_tick_b; zs_tick_b; gs_tick; gs_settle
  local n; n=$(( 1 + $(zs_leads_total) ))   # A's live lead + any lead launched by either host
  zs_cleanup_b; gs_cleanup
  printf '%s' "$n"
}
test_zs_s2_two_hosts_later_active_goal() {
  assert_eq "$(zs_two_hosts_later_active 1)" "1" "S2 serial: the other host does not start a second goal" || return 1
  assert_eq "$(zs_two_hosts_later_active 0)" "2" "S2 off: today's behaviour — the other host starts a second goal" || return 1
}

# A active on host-b at priority 5 (a later priority), B queued at priority 1: serial -> nothing starts; off -> B starts (today).
test_zs_s2_later_active_goal_blocks_only_in_serial() {
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 5 host-b
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 51)
  gs_cleanup
  assert_eq "$n$c" "00" "S2 serial: an active goal elsewhere holds the slot -> no claim, no lead" || return 1
  zq_env; zs_mode 0
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 5 host-b
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_wait_claude 1; gs_settle
  n=$(gs_claude_count)
  gs_cleanup
  assert_eq "$n" "1" "S2 off: today the earlier queued goal starts beside the later active one" || return 1
}

# ---------------------------------------------------------------- S3: extra active goal -> queue at cycle end --------

# zs_two_active <mode> — A (priority 1) and B (priority 2) both active and owned here, both leads ended cleanly long ago
# (launched 5000 s ago, exit 0: past GOAL_CYCLE_SECS=1200), so both are due a relaunch decision. Prints
# "<leads launched> <B has goal-queued> <B block host> <B local cache files> <A has goal-queued>".
zs_two_active() {
  zq_env; zs_mode "$1"
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-a; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a; gs_launch_state "$ZQ_A" 5000 0 4000
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" active 2 host-a; gs_cache 51 "$ZQ_B" "$ZQ_SPEC_B" host-a; gs_launch_state "$ZQ_B" 5000 0 4000
  echo "lead log line" > "$GS_PIPE/goal-$ZQ_B.log"
  gs_tick; gs_wait_claude 1; gs_tick; gs_settle
  local n qb=no qa=no hb fb logb=gone
  n=$(gs_claude_count); hb=$(zq_block_field 51 host); fb=$(ls "$GS_PIPE"/goal-"$ZQ_B".json 2>/dev/null | wc -l | tr -d ' ')
  gs_has_label 51 goal-queued && qb=yes; gs_has_label 50 goal-queued && qa=yes
  [ -f "$GS_PIPE/goal-$ZQ_B.log" ] && logb=kept
  ZS_LAST_BRIEF=$(cat "$(gs_last_claude)/argv" 2>/dev/null)
  gs_cleanup
  printf '%s %s %s %s %s %s' "$n" "$qb" "${hb:-empty}" "$fb" "$qa" "$logb"
}
test_zs_s3_extra_active_goal_returns_to_the_queue_at_cycle_end() {
  local r; r=$(zs_two_active 1)
  # 1 lead (A, the holder); B queued, unpinned (host ""), local cache dropped, lead log kept; A not queued
  assert_eq "$r" "1 yes empty 0 no kept" "S3 serial: holder relaunches, the other goal goes back to the queue" || return 1
}
test_zs_s3_off_relaunches_both() {
  local r; r=$(zs_two_active 0)
  # two ticks, one launch per tick: both relaunch; nothing queued, B still pinned here
  assert_eq "$r" "2 no host-a 1 no kept" "S3 off: today's behaviour — both goals relaunch" || return 1
}
# The holder's lead is alive; the extra goal's lead is alive too: nothing is killed (only cycle-end decisions requeue).
test_zs_s3_live_extra_lead_is_never_killed() {
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-a; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a; gs_live "$ZQ_A"
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" active 2 host-a; gs_cache 51 "$ZQ_B" "$ZQ_SPEC_B" host-a; gs_live "$ZQ_B"; local pb=$GS_P
  gs_tick; gs_tick; gs_settle
  local alive=no qb=no; gs_alive "$pb" && alive=yes; gs_has_label 51 goal-queued && qb=yes
  gs_cleanup
  assert_eq "$alive" "yes" "S3 serial: a running extra lead is left to finish its cycle" || return 1
  assert_eq "$qb" "no" "S3 serial: and is not queued while it runs" || return 1
}

# ---------------------------------------------------------------- S4: waiting on JP -> back to the queue -------------

# A waits on JP (registry + local .waiting), its lead ended long ago; JP answered: ticket 7 is READY FOR ENGINEERING again.
# Serial: A rejoins the queue (no relaunch); off: A relaunches at once (today).
zs_unwait() {
  zq_env; zs_mode "$1"
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" waiting 1 host-a; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a; gs_launch_state "$ZQ_A" 5000 0 4000
  echo "#7 x" > "$GS_PIPE/goal-$ZQ_A.waiting"
  gs_tick; gs_settle
  local n q=no w=no; n=$(gs_claude_count); gs_has_label 50 goal-queued && q=yes; gs_has_label 50 goal-waiting-jp && w=yes
  gs_cleanup
  printf '%s %s %s' "$n" "$q" "$w"
}
test_zs_s4_goal_back_from_waiting_rejoins_the_queue() {
  assert_eq "$(zs_unwait 1)" "0 yes no" "S4 serial: back from waiting on JP -> queued, not relaunched" || return 1
  assert_eq "$(zs_unwait 0)" "1 no no" "S4 off: today it relaunches at once" || return 1
}
# The requeued goal is then started again from the queue (slot free) on a later tick: nothing is stranded.
test_zs_s4_requeued_goal_starts_again() {
  zq_env; zs_mode 1
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" waiting 1 host-a; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a; gs_launch_state "$ZQ_A" 5000 0 4000
  echo "#7 x" > "$GS_PIPE/goal-$ZQ_A.waiting"
  gs_tick; gs_tick; gs_wait_claude 1; gs_settle
  local n q=no h; n=$(gs_claude_count); gs_has_label 50 goal-queued && q=yes; h=$(zq_block_field 50 host)
  gs_cleanup
  assert_eq "$n" "1" "S4 serial: the requeued goal starts again on the next tick (slot free)" || return 1
  assert_eq "$q$h" "nohost-a" "S4 serial: left the queue and is pinned to the starting host" || return 1
}

# ---------------------------------------------------------------- S5: spread across hosts ---------------------------

# zs_spread <mode> <lead: other|here> — SHARED_DISPATCH_ENABLED=0 (both hosts' live setting). Goal t-42 (project-a#42)
# active with its lead on host-b ("other") or live here; ticket 42 and loose ticket 7 both agent-go with no labels.
# Prints "<42 dispatched yes|no> <7 dispatched yes|no>".
# zs_gh_honours_feedback_search — the zq fake ignores --search; GitHub applies `label:"user-feedback"` server side, so emulate it
zs_gh_honours_feedback_search() {
  mv "$GS_BIN/gh" "$GS_BIN/gh.zq"
  cat > "$GS_BIN/gh" <<'GHEOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "$1 $2" = "issue list" ]; then
  repo=""; expr=""; search=""; prev=""; golabel=0
  for a in "$@"; do
    [ "$prev" = "--repo" ] && repo=$a; [ "$prev" = "--jq" ] && expr=$a; [ "$prev" = "--search" ] && search=$a
    [ "$prev" = "--label" ] && [ "$a" = agent-go ] && golabel=1; prev=$a
  done
  f="$HERE/issue-list-$(printf '%s' "$repo" | tr '/' '_').json"
  if [ "$golabel" = 1 ] && [ -f "$f" ]; then
    case "$search" in *'label:"user-feedback"'*) sel='[.[] | select(any(.labels[]; .name == "user-feedback"))]' ;; *) sel='.' ;; esac
    if [ -n "$expr" ]; then jq -c "$sel" "$f" | jq -r "$expr"; else jq -c "$sel" "$f"; fi
    exit 0
  fi
fi
exec "$HERE/gh.zq" "$@"
GHEOF
  chmod +x "$GS_BIN/gh"
}
zs_spread() {
  local mode=$1 lead=$2 out42=no out7=no gid=${3:-example-owner_project-a-t-42} gspec=${4:-example-owner/project-a#42} tn=${5:-42}
  zq_env; zs_mode "$mode"; zq_ac on
  echo "SHARED_DISPATCH_ENABLED=0" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  zs_gh_honours_feedback_search
  if [ "$tn" = 42 ]; then gs_issue 42 open "" "" "agent-go"; else gs_issue "$tn" open 12 "" "agent-go"; fi
  gs_issue 7 open "" "" "agent-go"
  jq -sc '[.[] | {number, title, labels, milestone}]' "$GS_ST/issues/$GS_A/$tn.json" "$GS_ST/issues/$GS_A/7.json" > "$GS_BIN/issue-list-$GS_A.json"
  if [ "$lead" = other ]; then
    zq_reg 50 "$gid" "$gspec" active 1 host-b
  else
    zq_reg 50 "$gid" "$gspec" active 1 host-a
    gs_cache 50 "$gid" "$gspec" host-a; gs_live "$gid"
  fi
  gs_tick; gs_settle
  [ "$(gs_reg_comment_count_issue "$tn" 'claim: Host-A')" -ge 1 ] && out42=yes
  [ "$(gs_reg_comment_count_issue 7 'claim: Host-A')" -ge 1 ] && out7=yes
  gs_cleanup
  printf '%s %s' "$out42" "$out7"
}
test_zs_s5_other_host_dispatches_the_slot_goal_tickets() {
  assert_eq "$(zs_spread 1 other)" "yes no" "S5 serial: the host without the lead runs the goal's ticket; a bare agent-go ticket still waits" || return 1
}
# Same for a milestone goal (ms-12; ticket 101 is open in milestone 12): its scope is read from the milestone, not a label.
test_zs_s5_milestone_goal_spreads_too() {
  assert_eq "$(zs_spread 1 other "$GS_ID_MS12" "$GS_SPEC_MS12" 101)" "yes no" "S5 serial: a milestone goal's ticket is dispatched by the other host" || return 1
}
test_zs_s5_lead_host_leaves_tickets_to_the_live_lead() {
  assert_eq "$(zs_spread 1 here)" "no no" "S5 serial: the lead's own host does not double-dispatch while the lead is live" || return 1
}
test_zs_s5_off_keeps_todays_no_spread() {
  assert_eq "$(zs_spread 0 other)" "no no" "S5 off: today, shared dispatch off means no spread at all" || return 1
}

# Review fix: a requeue whose label delete fails (the delete swallows errors) must not drop the local cache: the registry
# still reads waiting on JP, so with no cache anywhere nothing would ever restart the goal. The fake fails every DELETE
# of goal-waiting-jp; the goal must stay owned here (cache kept), not launched, and must not read queued-but-strandable.
test_zs_s4_failed_label_delete_never_strands_the_goal() {
  zq_env; zs_mode 1
  mv "$GS_BIN/gh" "$GS_BIN/gh.inner"
  printf '#!/bin/bash\nHERE=$(cd "$(dirname "$0")" && pwd)\ncase "$*" in *"-X DELETE"*goal-waiting-jp*) exit 1 ;; esac\nexec "$HERE/gh.inner" "$@"\n' > "$GS_BIN/gh"
  chmod +x "$GS_BIN/gh"
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" waiting 1 host-a; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a; gs_launch_state "$ZQ_A" 5000 0 4000
  echo "#7 x" > "$GS_PIPE/goal-$ZQ_A.waiting"
  gs_tick; gs_settle
  local n cache=gone; n=$(gs_claude_count); [ -f "$GS_PIPE/goal-$ZQ_A.json" ] && cache=kept
  gs_cleanup
  assert_eq "$n" "0" "S4 serial: no relaunch while the requeue is incomplete" || return 1
  assert_eq "$cache" "kept" "S4 serial: the local cache stays, so the next decision retries the requeue" || return 1
}

# Review fix: the spread list is from the last sync; once its goal no longer holds the slot (stopped here), step 5 stops
# spreading at once instead of until the next sync. GS_SYNC=default: tick 1 syncs (writes the list), tick 2 does not.
zs_spread_after_stop() {
  local stop=$1 out=no
  GS_SYNC=default zq_env; zs_mode 1; zq_ac on
  echo "SHARED_DISPATCH_ENABLED=0" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  zs_gh_honours_feedback_search
  gs_issue 42 open "" "" "agent-go"
  echo '[]' > "$GS_BIN/issue-list-$GS_A.json"
  zq_reg 50 example-owner_project-a-t-42 example-owner/project-a#42 active 1 host-b
  gs_tick
  [ "$stop" = stop ] && zq_reg 50 example-owner_project-a-t-42 example-owner/project-a#42 stopped 1 host-b
  jq -sc '[.[] | {number, title, labels, milestone}]' "$GS_ST/issues/$GS_A/42.json" > "$GS_BIN/issue-list-$GS_A.json"
  gs_tick; gs_settle
  [ "$(gs_reg_comment_count_issue 42 'claim: Host-A')" -ge 1 ] && out=yes
  gs_cleanup
  printf '%s' "$out"
}
test_zs_s5_spread_stops_when_the_goal_leaves_the_slot() {
  assert_eq "$(zs_spread_after_stop keep)" "yes" "S5 control: the list from the last sync spreads on a tick without a sync" || return 1
  assert_eq "$(zs_spread_after_stop stop)" "no" "S5 serial: goal stopped since the sync -> its tickets are no longer spread" || return 1
}

# ---------------------------------------------------------------- S6: two-host race --------------------------------

# Both hosts tick the same queued candidate; host-b already holds the earliest claim -> host-a loses, never launches.
test_zs_s6_race_on_the_one_candidate() {
  zq_env; zs_mode 1
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 2 ""
  zq_foreign_claim 51 host-b 5
  gs_tick; gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 52)
  gs_cleanup
  assert_eq "$n" "0" "S6 serial: the loser of the claim on the one candidate launches nothing" || return 1
  assert_eq "$c" "0" "S6 serial: and does not move on to the next goal (no second start elsewhere)" || return 1
}
# Another goal becomes active while host-a waits out its claim (settle 2 s; the registry changes once the claim is posted): host-a won the
# claim but must not start a second goal.
test_zs_s6_slot_taken_during_the_settle_wait() {
  zq_env; zs_mode 1
  echo "CLAIM_SETTLE_SECS=2" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  ( i=0; while [ "$i" -lt 100 ] && [ "$(zq_claims 51)" -lt 1 ]; do sleep 0.1; i=$((i + 1)); done
    zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 3 host-b ) &
  local bg=$!
  gs_tick; wait "$bg" 2>/dev/null; gs_settle
  local n mine q=no log; n=$(gs_claude_count); mine=$(zq_claims_by 51 host-a); gs_has_label 51 goal-queued && q=yes; log=$(gs_log)
  gs_cleanup
  assert_eq "$mine" "1" "S6 serial: host-a posted its claim (and was the only claimant)" || return 1
  assert_eq "$n" "0" "S6 serial: the slot was taken during the wait -> no launch" || return 1
  assert_eq "$q" "yes" "S6 serial: the goal stays queued" || return 1
  assert_contains "$log" "goal slot is no longer free" "S6 serial: the abort is logged" || return 1
}

echo "-- one goal at a time (GOAL_SERIAL)"
run_test test_zs_s1_any_active_goal_holds_the_slot
run_test test_zs_s1_feedback_goals_exempt_by_default
run_test test_zs_s1_unreadable_entry_fails_closed
run_test test_zs_s1_off_output_is_byte_identical_to_the_old_jq
run_test test_zs_s2_two_queued_goals_two_hosts_one_lead
run_test test_zs_s2_two_hosts_later_active_goal
run_test test_zs_s2_later_active_goal_blocks_only_in_serial
run_test test_zs_s3_extra_active_goal_returns_to_the_queue_at_cycle_end
run_test test_zs_s3_off_relaunches_both
run_test test_zs_s3_live_extra_lead_is_never_killed
run_test test_zs_s4_goal_back_from_waiting_rejoins_the_queue
run_test test_zs_s4_requeued_goal_starts_again
run_test test_zs_s5_other_host_dispatches_the_slot_goal_tickets
run_test test_zs_s5_milestone_goal_spreads_too
run_test test_zs_s5_lead_host_leaves_tickets_to_the_live_lead
run_test test_zs_s5_off_keeps_todays_no_spread
run_test test_zs_s4_failed_label_delete_never_strands_the_goal
run_test test_zs_s5_spread_stops_when_the_goal_leaves_the_slot
run_test test_zs_s6_race_on_the_one_candidate
run_test test_zs_s6_slot_taken_during_the_settle_wait
