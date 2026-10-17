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
  touch "$GS_PIPE/goal-$GS_ID_MS12.held"; echo registry > "$GS_PIPE/goal-$GS_ID_MS12.stopped"
  gs_tick; gs_wait_claude 1; gs_settle
  local held=absent stopped=absent
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.stopped" ] && stopped=present
  gs_cleanup
  assert_eq "$held" "absent" "resumed elsewhere: stale .held cleared on the owner" || return 1
  assert_eq "$stopped" "absent" "resumed elsewhere: stale .stopped cleared on the owner" || return 1
}

# a local stop whose registry write failed (.stopped unconfirmed, registry still active) must not be undone by sync
test_gs_sync_unconfirmed_local_stop_survives_active_registry() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  touch "$GS_PIPE/goal-$GS_ID_MS12.stopped"
  gs_tick; gs_settle
  local stopped=absent cnt
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.stopped" ] && stopped=present
  cnt=$(gs_claude_count)
  gs_cleanup
  assert_eq "$stopped" "present" "failed registry write: local .stopped kept" || return 1
  assert_eq "$cnt" "0" "failed registry write: the lead is not relaunched" || return 1
}

# same id on two tickets: open B pinned here, old closed A (stopped) pinned elsewhere must not drop B's lead/cache (#366)
test_gs_sync_old_closed_ticket_of_other_host_does_not_repin_open_goal() {
  gs_env
  gs_reg 60 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a active
  gs_reg 50 "$GS_SPEC_MS12" "$GS_ID_MS12" host-b stopped
  gs_cache 60 "$GS_ID_MS12" "$GS_SPEC_MS12" host-a
  gs_live "$GS_ID_MS12"
  local p=$GS_P alive=no issue log
  gs_tick; gs_settle
  kill -0 "$p" 2>/dev/null && alive=yes
  issue=$(jq -r '.issue // empty' "$GS_PIPE/goal-$GS_ID_MS12.json" 2>/dev/null)
  log=$(gs_log)
  gs_cleanup
  assert_eq "$alive" "yes" "same id, other issue: the lead is not killed" || return 1
  assert_eq "$issue" "60" "same id, other issue: the cache of the open ticket survives" || return 1
  case "$log" in *"re-pinned"*) fail "same id, other issue: no re-pinned line, got: $log"; return 1 ;; esac
}

run_test test_gs_sync_repinned_goal_drops_local_lead_and_cache
run_test test_gs_sync_active_registry_goal_clears_stale_held_and_stopped
run_test test_gs_sync_unconfirmed_local_stop_survives_active_registry
run_test test_gs_sync_old_closed_ticket_of_other_host_does_not_repin_open_goal
