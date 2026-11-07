# GOAL_SERIAL=1: a queued goal only this host may run, whose repo is not in this host's DISPATCH_REPOS, must not hold the
# serial queue (2026-11-07: a goal pinned to the Mac after its repo left the Mac's DISPATCH_REPOS starved every goal behind it).
#   U1 pinned here + repo missing: held once (goal-queued kept, one held note), the next queued goal starts; lifted once the
#      repo is back in DISPATCH_REPOS.
#   U2 pinned to the other host + repo missing here: this host never judges it; the line still waits (unchanged).
#   U3 unpinned + repo missing here: not held; on the Mac the next goal still waits (unchanged).
# Expected values come from the request, never from the code under test. Prefix zu_ / ZU_. Reuses gs_* and zq_* helpers.

ZU_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$ZU_HERE/test-goal-supervisor.sh" > "$ZU_HERE/.zu-gs-lib.$$.sh"
  . "$ZU_HERE/.zu-gs-lib.$$.sh"
  rm -f "$ZU_HERE/.zu-gs-lib.$$.sh"
fi
if ! type zq_env >/dev/null 2>&1; then
  sed '/^run_test /,$d' "$ZU_HERE/test-goal-z-queue.sh" > "$ZU_HERE/.zu-zq-lib.$$.sh"
  . "$ZU_HERE/.zu-zq-lib.$$.sh"
  rm -f "$ZU_HERE/.zu-zq-lib.$$.sh"
fi

ZU_SPEC_B="example-owner/project-b#5"   # project-b is not in the sandbox's DISPATCH_REPOS
ZU_B="example-owner_project-b-t-5"

# zu_world <kind> <head host_pref> — serial mode; head B (project-b, priority 1, pinned as given) and C (project-a, priority 2)
zu_world() {
  zq_env; zq_kind "$1"; zq_ac on
  echo "GOAL_SERIAL=1" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  zq_reg 51 "$ZU_B" "$ZU_SPEC_B" queued 1 "" "$2"
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 2 ""
}
zu_held_notes() { gs_reg_comment_count 51 '**[deliver] NOTE** held: '; }

test_zu_pinned_here_unstartable_head_is_held_once_and_frees_the_line() {
  # VM (a Mac's keep-awake caffeinate keeps the sandbox's supervisor lock and would skip the later ticks): tick 1 holds B,
  # C becomes the candidate at tick 2's sync and starts at once; ticks 3-4 must not hold B again
  zu_world vm host-a
  gs_tick; gs_tick; gs_wait_claude 1; gs_tick; gs_tick; gs_settle
  local held=no queued=no notes n cb cc
  gs_has_label 51 goal-held && held=yes; gs_has_label 51 goal-queued && queued=yes
  notes=$(zu_held_notes); n=$(gs_claude_count); cb=$(zq_claims 51); cc=$(zq_claims_by 52 host-a)
  # the repo comes back: the hold lifts by itself (C holds the slot, so B just waits in the queue)
  echo "DISPATCH_REPOS=(\"example-owner/project-a:$GS_CK_A\" \"example-owner/project-b:$GS_CK_A\")" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  gs_tick; gs_tick; gs_settle
  local held2=no queued2=no unheld
  gs_has_label 51 goal-held && held2=yes; gs_has_label 51 goal-queued && queued2=yes
  unheld=$(gs_reg_comment_count 51 '**[deliver] NOTE** unheld: ')
  gs_cleanup
  assert_eq "$held" "yes" "U1: the pinned-here head whose repo is missing is held" || return 1
  assert_eq "$queued" "yes" "U1: it keeps goal-queued (resume puts it straight back in line)" || return 1
  assert_eq "$notes" "1" "U1: one held note across four ticks" || return 1
  assert_eq "$cb" "0" "U1: no start claim for the held goal" || return 1
  assert_eq "$n" "1" "U1: the next queued goal's lead started" || return 1
  assert_eq "$cc" "1" "U1: the next queued goal was claimed here" || return 1
  assert_eq "$held2" "no" "U1: the hold lifts once the repo is in DISPATCH_REPOS" || return 1
  assert_eq "$queued2" "yes" "U1: ... and the goal is queued again" || return 1
  assert_eq "$unheld" "1" "U1: one unheld note" || return 1
}

test_zu_pinned_elsewhere_head_still_holds_the_line() {
  zu_world vm host-b
  gs_tick; gs_tick; gs_tick; gs_settle
  local held=no n cc
  gs_has_label 51 goal-held && held=yes; n=$(gs_claude_count); cc=$(zq_claims 52)
  gs_cleanup
  assert_eq "$held" "no" "U2: a host never holds a goal pinned to another host" || return 1
  assert_eq "$n$cc" "00" "U2: the next goal still waits behind it (unchanged)" || return 1
}

test_zu_unpinned_head_keeps_the_vm_first_wait() {
  zu_world mac ""
  gs_tick; gs_tick; gs_tick; gs_tick; gs_settle
  local held=no n cc
  gs_has_label 51 goal-held && held=yes; n=$(gs_claude_count); cc=$(zq_claims 52)
  local log; log=$(gs_log)
  gs_cleanup
  assert_eq "$held" "no" "U3: an unpinned goal is never held for a repo missing on one host" || return 1
  assert_eq "$n$cc" "00" "U3: the next goal waits (the other host may start the head)" || return 1
  printf '%s\n' "$log" | grep -F "$ZU_B" | grep -q 'not in DISPATCH_REPOS on this host' \
    || { fail "U3: the Mac reached its two-tick wait and logged the missing repo, in:
$log"; return 1; }
}

echo "-- goal queue: unstartable pinned head (GOAL_SERIAL=1)"
run_test test_zu_pinned_here_unstartable_head_is_held_once_and_frees_the_line
run_test test_zu_pinned_elsewhere_head_still_holds_the_line
run_test test_zu_unpinned_head_keeps_the_vm_first_wait
gs_tree_cleanup
