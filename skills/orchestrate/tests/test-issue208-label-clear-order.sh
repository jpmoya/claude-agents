# Regression for claude-agents#208 — step 3 must not clear agent-in-progress for a death step 1 has not handled
# (.exit-logged absent with a run-id), and step 4 must skip any issue that still has a local orch-<n>.pid.
#
#   1  dead, run-id, no .exit-logged, step 1 defers (cap exit) -> label kept, warn row supervisor/step3, release=SHA
#   2  dead, run-id, .exit-logged present, no queue -> step 3 clears (existing behaviour)
#   3  dead, no run-id (pre-#138), no queue -> step 3 clears
#   4  dead pid file, stale marker, label on GitHub -> step 4 leaves it (step 3 deferred above)
#   5  no pid file at all, label on GitHub, marker 30+ min old -> step 4 still clears
# Reuses the sq_* helpers (same loading trick as test-supervisor-live-stage-defers.sh).

HERE_L8=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "l8_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_L8/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f l8_real_run_test | sed '1s/l8_real_run_test/run_test/')"
fi
L8_STAGE="printf '1000\t42\tclaude --agent test-writer -p\n'"

# l8_fixture — dead orchestrator, exit 0, cap row + live stage so step 1 defers without logging the exit
l8_fixture() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  echo 0 > "$(rkp "$SQ_PIPE/orch-42.exit")"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"ts":"%s","host":"h","event":"terminal","repo":"project-a/repo-a","issue":42,"state":"stage running at cap","next_action":"supervisor relaunch picks up result"}\n' \
    "$(sq_iso_ago 10)" >> "$SQ_HOME/.claude/pipeline/runs.jsonl"
  sq_marker "$SQ_READY"
}
l8_tick() { sq_run env RS_PS_CMD="$1" "$SUP_SQ" >/dev/null 2>&1; }
l8_removed() { grep -c "issue edit 42 --remove-label agent-in-progress" "$SQ_GH/gh-calls.log" 2>/dev/null || true; }

test_l8_1_unhandled_death_keeps_label_and_warns() {
  l8_fixture
  echo "h-orch-42-1700000000" > "$(rkp "$SQ_PIPE/orch-42.run-id")"
  l8_tick "$L8_STAGE"
  local n log row sha want
  n=$(l8_removed); log=$(sq_log)
  row=$(jq -c 'select(.event=="label_clear_deferred")' "$SQ_HOME/logs/pipeline/events.jsonl" 2>/dev/null | tail -1)
  want=$(git -C "$HERE_L8" rev-parse HEAD)
  sq_cleanup
  assert_eq "$n" "0" "#208/1: label not removed" || return 1
  assert_contains "$log" "label kept" "#208/1: deferral logged" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .route)" "supervisor/step3" "#208/1: route" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .level)" "warn" "#208/1: level" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .release)" "$want" "#208/1: release is the checkout SHA" || return 1
  assert_not_contains "$row" "hooks.slack.com" "#208/1: no webhook in row" || return 1
}

test_l8_2_exit_logged_present_step3_clears() {
  l8_fixture
  echo "h-orch-42-1700000000" > "$(rkp "$SQ_PIPE/orch-42.run-id")"
  touch "$(rkp "$SQ_PIPE/orch-42.exit-logged")"
  l8_tick "$L8_STAGE"
  local n; n=$(l8_removed)
  sq_cleanup
  assert_eq "$n" "1" "#208/2: label removed once" || return 1
}

test_l8_3_no_run_id_step3_clears() {
  l8_fixture
  l8_tick "$L8_STAGE"
  local n; n=$(l8_removed)
  sq_cleanup
  assert_eq "$n" "1" "#208/3: label removed" || return 1
}

# step 4 harness: gh lists issue 42 as labelled, comments 2h old
l8_s4_env() {
  sq_env open
  printf 'MEM_FLOOR_MB=0\nDISPATCH_REPOS=("project-a/repo-a:%s")\n' "$SQ_REPO" > "$SQ_HOME/.claude/pipeline/config.local.sh"
  mv "$SQ_GH/gh" "$SQ_GH/gh-real"
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "issue list"*"--label agent-in-progress"*) printf '%s\n' "$*" >> "$HERE/gh-calls.log"; echo 42; exit 0 ;;
  "issue list"*) printf '%s\n' "$*" >> "$HERE/gh-calls.log"; exit 0 ;;
  "issue view"*"--json comments,updatedAt"*) printf '%s\n' "$*" >> "$HERE/gh-calls.log"; cat "$HERE/view-out"; exit 0 ;;
esac
exec "$HERE/gh-real" "$@"
GH_EOF
  chmod +x "$SQ_GH/gh"
  printf '%s\n\n' "$(sq_iso_ago 7200)" > "$SQ_GH/view-out"
}

test_l8_4_dead_pid_file_step4_skips() {
  l8_fixture   # cap exit: step 1 defers, so no queue entry and no .exit-logged
  echo "h-orch-42-1700000000" > "$(rkp "$SQ_PIPE/orch-42.run-id")"
  printf 'MEM_FLOOR_MB=0\nDISPATCH_REPOS=("project-a/repo-a:%s")\n' "$SQ_REPO" > "$SQ_HOME/.claude/pipeline/config.local.sh"
  mv "$SQ_GH/gh" "$SQ_GH/gh-real"
  printf '#!/bin/bash\nHERE=$(cd "$(dirname "$0")" && pwd)\ncase "$*" in\n  "issue list"*"--label agent-in-progress"*) echo "$*" >> "$HERE/gh-calls.log"; echo 42; exit 0 ;;\n  "issue view"*"--json comments,updatedAt"*) echo "$*" >> "$HERE/gh-calls.log"; cat "$HERE/view-out"; exit 0 ;;\nesac\nexec "$HERE/gh-real" "$@"\n' > "$SQ_GH/gh"
  chmod +x "$SQ_GH/gh"; printf '%s\n\n' "$(sq_iso_ago 7200)" > "$SQ_GH/view-out"
  l8_tick "$L8_STAGE"
  local n; n=$(l8_removed)
  sq_cleanup
  assert_eq "$n" "0" "#208/4: step 4 leaves the label while a pid file exists" || return 1
}

test_l8_5_no_pid_file_stale_step4_clears() {
  l8_s4_env
  sq_tick
  local n log; n=$(l8_removed); log=$(sq_log)
  sq_cleanup
  assert_eq "$n" "1" "#208/5: orphan from another host still cleared" || return 1
  assert_contains "$log" "[reconcile] project-a/repo-a#42" "#208/5: reconcile logged" || return 1
}

run_test test_l8_1_unhandled_death_keeps_label_and_warns
run_test test_l8_2_exit_logged_present_step3_clears
run_test test_l8_3_no_run_id_step3_clears
run_test test_l8_4_dead_pid_file_step4_skips
run_test test_l8_5_no_pid_file_stale_step4_clears
