# Tests for claude-agents#93 — (a) `orchestrate.sh stop` on a queued-only ticket (no pid file) must still
# write the tombstone and drop the queue entry; (b)-(d) supervisor reconcile (step 4) ages a zero-comment
# agent-in-progress issue by its updatedAt instead of clearing the label at once.
# Isolated HOME/PIPE/QUEUE/LOGDIR. Own gh stub (the shared fake has no updatedAt). Placeholder names only.

HERE_Z=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_Z="$HERE_Z/../orchestrate.sh"
SUP_Z="$HERE_Z/../supervisor.sh"

# z_env — Z_PIPE, Z_HOME, Z_REPO, Z_GH; DISPATCH_REPOS lists one repo; gh stub reports issue 77 as
# labelled agent-in-progress with no local state.
z_env() {
  Z_PIPE=$(new_pipe); Z_HOME=$(new_home)
  Z_REPO="$Z_PIPE/repo-a"; Z_GH="$Z_HOME/.local/bin"
  fixture_repo "$Z_REPO" "project-a/repo-a"
  mkdir -p "$Z_GH"; : > "$Z_GH/gh-calls.log"
  cat > "$Z_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
expr=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
emit() { if [ -n "$expr" ]; then printf '%s' "$1" | jq -r "$expr"; else printf '%s\n' "$1"; fi; }
case "$*" in
  "issue list"*"--label agent-in-progress"*) emit '[{"number":77}]' ;;
  "issue list"*) emit '[]' ;;
  "issue view"*)
    upd=$(cat "$HERE/updated-at"); com=$(cat "$HERE/comments-json")
    emit "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"agent-in-progress\"}],\"updatedAt\":\"$upd\",\"comments\":$com}" ;;
  *) exit 0 ;;
esac
GH_EOF
  chmod +x "$Z_GH/gh"
  printf 'MEM_FLOOR_MB=0\nDISPATCH_REPOS=("project-a/repo-a:%s")\n' "$Z_REPO" > "$Z_HOME/.claude/pipeline/config.local.sh"
}
z_cleanup() { rm -rf "$Z_PIPE" "$Z_HOME"; }
z_iso_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
z_run() {
  HOME="$Z_HOME" PATH="$Z_GH:/usr/bin:/bin" PIPE="$Z_PIPE" QUEUE="$Z_PIPE/queue" LOGDIR="$Z_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$@"
}
# z_tick <updatedAt-secs-ago> <comments-json>
z_tick() {
  z_iso_ago "$1" > "$Z_GH/updated-at"; printf '%s' "$2" > "$Z_GH/comments-json"
  z_run "$SUP_Z" >/dev/null 2>&1
  Z_LOG=$(cat "$Z_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  Z_CALLS=$(cat "$Z_GH/gh-calls.log")
}

test_z_a_stop_queued_only_ticket_writes_tombstone() {
  z_env
  echo '{"issue":"917"}' > "$Z_PIPE/queue/orch-917.json"   # queued, never launched: no orch-917.pid
  local out rc
  out=$(z_run "$ORCH_Z" stop 917 2>&1); rc=$?
  local tomb=absent queued=present
  [ -f "$Z_PIPE/orch-917.stopped" ] && tomb=present
  [ -f "$Z_PIPE/queue/orch-917.json" ] || queued=absent
  z_cleanup
  assert_exit0 "$rc" "#93/a: stop exits 0 with no pid file" || return 1
  assert_contains "$out" "orchestrator for #917 not running" "#93/a: says not running" || return 1
  assert_eq "$tomb" "present" "#93/a: orch-917.stopped written" || return 1
  assert_eq "$queued" "absent" "#93/a: queue entry removed" || return 1
}

test_z_b_zero_comments_updated_60s_ago_keeps_label() {
  z_env; z_tick 60 '[]'
  z_cleanup
  assert_not_contains "$Z_LOG" "[reconcile]" "#93/b: no reconcile line" || return 1
  assert_not_contains "$Z_CALLS" "issue edit 77" "#93/b: label not removed" || return 1
}

test_z_c_zero_comments_updated_2h_ago_clears_label() {
  z_env; z_tick 7200 '[]'
  z_cleanup
  assert_contains "$Z_CALLS" "issue edit 77 --remove-label agent-in-progress" "#93/c: label removed" || return 1
  assert_contains "$Z_LOG" "[reconcile] project-a/repo-a#77" "#93/c: reconcile logged" || return 1
}

test_z_d_comment_60s_old_keeps_label() {
  local c; z_env
  c="[{\"body\":\"x\",\"createdAt\":\"$(z_iso_ago 60)\"}]"
  z_tick 7200 "$c"   # updatedAt is old, the comment is fresh: the comment wins
  z_cleanup
  assert_not_contains "$Z_LOG" "[reconcile]" "#93/d: no reconcile line" || return 1
  assert_not_contains "$Z_CALLS" "issue edit 77" "#93/d: label not removed" || return 1
}

test_z_e_stale_comment_clears_even_if_updated_recently() {
  local c; z_env
  c="[{\"body\":\"x\",\"createdAt\":\"$(z_iso_ago 7200)\"}]"
  z_tick 60 "$c"   # issues with comments behave as today: last comment time decides
  z_cleanup
  assert_contains "$Z_CALLS" "issue edit 77 --remove-label agent-in-progress" "#93/e: label removed on stale comment" || return 1
}

test_z_f_orchestrator_structural_bullet_names_start_gate() {
  local line; line=$(grep -F '**Structural**' "$HERE_Z/../../../agents/orchestrator.md")
  assert_contains "$line" "start-gate still open" "#93/AC3: Structural bullet names the start-gate case" || return 1
}

run_test test_z_a_stop_queued_only_ticket_writes_tombstone
run_test test_z_b_zero_comments_updated_60s_ago_keeps_label
run_test test_z_c_zero_comments_updated_2h_ago_clears_label
run_test test_z_d_comment_60s_old_keeps_label
run_test test_z_e_stale_comment_clears_even_if_updated_recently
run_test test_z_f_orchestrator_structural_bullet_names_start_gate
