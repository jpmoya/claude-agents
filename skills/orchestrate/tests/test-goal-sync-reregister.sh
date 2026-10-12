#!/bin/bash
# Sourced by run-tests.sh AFTER the goal-supervisor suite (reuses its gs_* fixtures). Issue #195 fix cycle 3:
# a goal re-registered after a stop/delivery shares its id with the old closed registry issue; sync must act
# only on the issue the cache tracks, so the old closed issue never kills the new lead.

test_gs_sync_old_closed_issue_with_same_id_does_not_kill_new_lead() {
  gs_env
  gs_reg 10 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a stopped
  gs_reg 20 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a active
  gs_cache 20 "$GS_ID_MS12" "$GS_SPEC_MS12" host-a
  gs_live "$GS_ID_MS12"
  local p=$GS_P alive=no stopped=absent
  gs_tick; gs_settle
  gs_gone=no; gs_wait_dead "$p" && gs_gone=yes
  [ "$gs_gone" = no ] && alive=yes
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.stopped" ] && stopped=present
  gs_cleanup
  assert_eq "$alive" "yes" "re-registered goal: the new lead survives a sync" || return 1
  assert_eq "$stopped" "absent" "re-registered goal: the old closed issue leaves no .stopped" || return 1
}

# the stop must still propagate when the closed issue IS the one the cache tracks
test_gs_sync_closed_tracked_issue_still_kills_lead() {
  gs_env
  gs_reg 10 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a stopped
  gs_cache 10 "$GS_ID_MS12" "$GS_SPEC_MS12" host-a
  gs_live "$GS_ID_MS12"
  local p=$GS_P alive=yes
  gs_tick; gs_settle
  gs_wait_dead "$p" && alive=no
  gs_cleanup
  assert_eq "$alive" "no" "closed tracked issue: the lead is stopped" || return 1
}

run_test test_gs_sync_old_closed_issue_with_same_id_does_not_kill_new_lead
run_test test_gs_sync_closed_tracked_issue_still_kills_lead
