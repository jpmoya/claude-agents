#!/bin/bash
# Sourced by run-tests.sh AFTER the goal-supervisor suite (reuses its gs_* fixtures). Issue #195 fix cycle 1:
# a goal re-pinned to another host must not keep a lead running here, and a non-owner resume must unfreeze the owner.

test_gs_sync_repinned_goal_drops_local_lead_and_cache() {
  gs_env
  gs_reg 50 "$GS_SPEC_MS12" "$GS_ID_MS12" host-b active
  gs_cache 50 "$GS_ID_MS12" "$GS_SPEC_MS12" host-a
  gs_live "$GS_ID_MS12"
  local p=$GS_P alive=yes files cnt
  gs_tick; gs_settle
  gs_wait_dead "$p" && alive=no
  files=$(gs_goal_file_count "$GS_ID_MS12")
  cnt=$(gs_claude_count)
  gs_cleanup
  assert_eq "$alive" "no" "re-pin: the old owner's lead is killed" || return 1
  assert_eq "$files" "0" "re-pin: the old owner's goal cache is dropped" || return 1
  assert_eq "$cnt" "0" "re-pin: nothing is relaunched here" || return 1
}

test_gs_sync_active_registry_goal_clears_stale_held_and_stopped() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  touch "$GS_PIPE/goal-$GS_ID_MS12.held" "$GS_PIPE/goal-$GS_ID_MS12.stopped"
  gs_tick; gs_wait_claude 1; gs_settle
  local held=absent stopped=absent
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.stopped" ] && stopped=present
  gs_cleanup
  assert_eq "$held" "absent" "resumed elsewhere: stale .held cleared on the owner" || return 1
  assert_eq "$stopped" "absent" "resumed elsewhere: stale .stopped cleared on the owner" || return 1
}

run_test test_gs_sync_repinned_goal_drops_local_lead_and_cache
run_test test_gs_sync_active_registry_goal_clears_stale_held_and_stopped
