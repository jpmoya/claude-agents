# Issue #224 — re-registering a goal must not inherit the old goal's local stop/held/retry files (same goal id, new registry issue).
# Uses the dg_* helpers of test-goal-deliver.sh (sourced earlier by the runner).

test_rs_reregister_clears_stale_stop_held_and_retry_state() {
  type dg_setup >/dev/null 2>&1 || { fail "dg_* harness missing"; return 1; }
  dg_setup
  local rc=0 f
  mkdir -p "$DG_PIPE"
  for f in stopped held restarts np snap; do echo old > "$DG_PIPE/goal-$DG_ID_T7.$f"; done
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  for f in stopped held restarts np snap; do
    [ ! -e "$DG_PIPE/goal-$DG_ID_T7.$f" ] || { fail "stale .$f survived the re-registration"; rc=1; }
  done
  dg_teardown; return $rc
}

run_test test_rs_reregister_clears_stale_stop_held_and_retry_state
