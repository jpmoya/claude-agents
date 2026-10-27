# Issue #491 — supervisor.sh stale-work digest step: a read-only, log-only pass inside the existing tick
# (never a new cron/process) that surfaces, without ever acting on them:
#   (a) open agent-go issues, in a scanned repo, idle longer than STALE_WORK_HOURS and not covered by an
#       approved goal (milestone via goal_milestone_approved, or a label-goal match against the registry)
#   (b) open issues sitting in a ci_red/ci_pending/merge_conflict hold (orch-<rk>.held) past the same threshold
#   (c) a WARN line when the filesystem holding ~/.claude/pipeline is >= 85% full
# Throttled to once per 600 s (stamp file, same shape as reconcile-status.sh's own throttle). Read-only: a
# test proves zero mutating gh calls happen during the step.
#
# Same harness as test-supervisor-queued-not-counted.sh (sq_env/sq_tick/etc, loaded the same way
# test-supervisor-auto-retry.sh does it). Placeholder repo names only (public repo — AC5/AC17).

HERE_SWD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "swd_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_SWD/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f swd_real_run_test | sed '1s/swd_real_run_test/run_test/')"
fi

# swd_tick — one supervisor.sh tick with an optional Slack webhook wired (sq_run omits it).
swd_tick() {
  HOME="$SQ_HOME" PATH="$SQ_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SQ_PIPE" QUEUE="$SQ_PIPE/queue" LOGDIR="$SQ_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" SLACK_WEBHOOK_URL="${SWD_WEBHOOK:-}" "$SUP_SQ" >/dev/null 2>&1
}

swd_touch_ago() {  # swd_touch_ago <file> <secs ago>
  python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" "$1" "$2"
}

swd_iso_ago() { sq_iso_ago "$1"; }

swd_install_df() {  # swd_install_df <bin> <pct> — stub df: fixed capacity% on every call, whatever the path
  printf '#!/bin/bash\necho "Filesystem 512-blocks Used Available Capacity Mounted"\necho "/dev/fake 100 0 0 %s%% /"\n' "$2" > "$1/df"
  chmod +x "$1/df"
}

swd_install_df_fail() { printf '#!/bin/bash\nexit 1\n' > "$1/df"; chmod +x "$1/df"; }

swd_install_curl_recorder() {  # swd_install_curl_recorder <bin>
  : > "$1/curl-calls.log"
  printf '#!/bin/bash\necho "$*" >> "%s/curl-calls.log"\nexit 0\n' "$1" > "$1/curl"
  chmod +x "$1/curl"
}

# swd_install_registry <bin> <GOAL_REGISTRY_REPO> — intercepts the one goal-registry listing endpoint
# (_goal_registry_json's `gh api --paginate repos/<registry>/issues?labels=delivery-goal...`), content from
# <bin>/gh-registry.json (default '[]' = no goals at all); everything else falls through to the real fake gh.
swd_install_registry() {
  local bin=$1
  [ -f "$bin/gh-registry.json" ] || printf '[]' > "$bin/gh-registry.json"
  cp "$bin/gh" "$bin/gh-base"
  cat > "$bin/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "api --paginate repos/"*"/issues?labels=delivery-goal"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    cat "$HERE/gh-registry.json" 2>/dev/null || echo '[]'
    exit 0 ;;
  *) exec "$HERE/gh-base" "$@" ;;
esac
GH_EOF
  chmod +x "$bin/gh"
}

# swd_scan_env — sq_env open + the goal-registry endpoint wired (empty registry by default), repo scanned
# via SCAN_ONLY_REPOS (never DISPATCH_REPOS, so step 5 dispatch never touches it): item (a) tests build on this.
swd_scan_env() {
  sq_env open
  swd_install_registry "$SQ_GH"
  printf 'GOAL_REGISTRY_REPO=example-owner/registry\nSCAN_ONLY_REPOS=("project-a/repo-a")\n' > "$SQ_HOME/.claude/pipeline/config.local.sh"
}

swd_list_fixture() {  # swd_list_fixture <num> <updatedAt> <milestone number|null> <labels json array>
  printf '[{"number":%s,"updatedAt":"%s","milestone":%s,"labels":%s}]' "$1" "$2" "$3" "$4" > "$SQ_GH/gh-list-approved-project-a_repo-a"
}

# --------------------------------------------------------------------------------------------------------
# AC3(c) — disk pressure
# --------------------------------------------------------------------------------------------------------

test_swd_ac3c_warn_at_85_percent() {
  sq_env open
  swd_install_df "$SQ_GH" 85
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_contains "$log" "[stale-digest] WARN disk usage 85%" "AC3c: >=85% logs a WARN" || return 1
}

test_swd_ac3c_no_warn_at_84_percent() {
  sq_env open
  swd_install_df "$SQ_GH" 84
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "disk usage" "AC3c: 84% logs nothing" || return 1
}

test_swd_ac3c_df_failure_logs_and_alerts() {
  sq_env open
  swd_install_df_fail "$SQ_GH"
  swd_install_curl_recorder "$SQ_GH"
  SWD_WEBHOOK="https://example.invalid/hook" swd_tick
  local log calls
  log=$(sq_log); calls=$(cat "$SQ_GH/curl-calls.log" 2>/dev/null)
  sq_cleanup
  assert_contains "$log" "[stale-digest] disk usage check failed" "error: slog line present" || return 1
  assert_contains "$calls" "example.invalid/hook" "error: one Slack alert posted" || return 1
}

# --------------------------------------------------------------------------------------------------------
# Throttle — at most once per 600 s, same shape as reconcile-status.sh
# --------------------------------------------------------------------------------------------------------

test_swd_throttle_runs_once_then_again_after_backdate() {
  sq_env open
  swd_install_df "$SQ_GH" 90
  swd_tick
  swd_tick   # second tick inside the 600 s window: no new WARN
  local n1 stamp
  n1=$(grep -c "WARN disk usage" "$SQ_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  stamp="$SQ_PIPE/stale-work-digest.stamp"
  assert_file_exists "$stamp" "throttle: stamp file created" || { sq_cleanup; return 1; }
  swd_touch_ago "$stamp" 601
  swd_tick
  local n2
  n2=$(grep -c "WARN disk usage" "$SQ_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  sq_cleanup
  assert_eq "$n1" "1" "throttle: two back-to-back ticks run the digest once" || return 1
  assert_eq "$n2" "2" "throttle: a stamp backdated past 600s runs it again" || return 1
}

# --------------------------------------------------------------------------------------------------------
# STALE_WORK_HOURS override (config.local.sh)
# --------------------------------------------------------------------------------------------------------

test_swd_hours_override_from_config_local() {
  sq_env open
  swd_install_df "$SQ_GH" 10
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  touch "$(rkp "$SQ_PIPE/orch-42.label-cleared")"   # keep the unrelated step-3/4 label lifecycle out of this log
  echo 3 > "$(rkp "$SQ_PIPE/orch-42.autoretry")"   # neutralize the 1b auto-retry loop, same fixture both runs
  printf '%s Pipeline #42 parked, auto-retry (ci_red) — %s\n' "$(date -u +%FT%TZ)" "$AR2_BLK" > "$(rkp "$SQ_PIPE/orch-42.alert")" 2>/dev/null \
    || printf '%s Pipeline #42 parked, auto-retry (ci_red) — x\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-42.alert")"
  swd_touch_ago "$(rkp "$SQ_PIPE/orch-42.held")" $((2 * 3600))   # 2h old: under the default 4h threshold
  swd_tick
  local log_default; log_default=$(sq_log)

  sq_cleanup
  sq_env open
  swd_install_df "$SQ_GH" 10
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  touch "$(rkp "$SQ_PIPE/orch-42.label-cleared")"
  echo 3 > "$(rkp "$SQ_PIPE/orch-42.autoretry")"
  printf '%s Pipeline #42 parked, auto-retry (ci_red) — x\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-42.alert")"
  swd_touch_ago "$(rkp "$SQ_PIPE/orch-42.held")" $((2 * 3600))
  echo 'STALE_WORK_HOURS=1' > "$SQ_HOME/.claude/pipeline/config.local.sh"
  swd_tick
  local log_override; log_override=$(sq_log)
  sq_cleanup

  assert_not_contains "$log_default" "[stale-digest]" "override: default 4h does not yet flag a 2h-old hold" || return 1
  assert_contains "$log_override" "[stale-digest] project-a/repo-a#42 — stuck in ci_red hold for 2h" "override: STALE_WORK_HOURS=1 flags the same 2h-old hold" || return 1
}

# --------------------------------------------------------------------------------------------------------
# AC3(a) — stale agent-go
# --------------------------------------------------------------------------------------------------------

test_swd_ac3a_stale_uncovered_ticket_logged() {
  swd_scan_env
  swd_list_fixture 501 "$(swd_iso_ago $((6 * 3600)))" null '[]'
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_contains "$log" "[stale-digest] project-a/repo-a#501 — agent-go idle 6h, no approved goal covers it" "AC3a: idle, uncovered ticket logged" || return 1
}

test_swd_ac3a_fresh_ticket_not_logged() {
  swd_scan_env
  swd_list_fixture 502 "$(swd_iso_ago 60)" null '[]'
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "#502" "AC3a: a ticket updated a minute ago is never flagged" || return 1
}

test_swd_ac3a_recent_marker_resets_idle() {
  swd_scan_env
  # updatedAt itself is stale, but a routing-marker comment landed recently — later-of must win
  swd_list_fixture 503 "$(swd_iso_ago $((6 * 3600)))" null '[]'
  printf '[{"body":"**[fullstack-developer] IMPLEMENTED**","createdAt":"%s"}]' "$(swd_iso_ago 60)" > "$SQ_GH/gh-issue-comments-json-503"
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "#503" "AC3a: a marker comment newer than updatedAt keeps the ticket out of the digest" || return 1
}

test_swd_ac3a_label_goal_coverage_is_not_reported() {
  swd_scan_env
  swd_list_fixture 504 "$(swd_iso_ago $((6 * 3600)))" null '["goal: stale test"]'
  printf '[{"number":900,"state":"open","closed_at":null,"labels":[{"name":"delivery-goal"}],"body":"Goal\n\n```json\n{\"id\":\"ex-goal\",\"spec\":\"label:goal: stale test\",\"label\":\"goal: stale test\",\"go\":true,\"v\":2}\n```\n"}]' \
    > "$SQ_GH/gh-registry.json"
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "#504" "AC3a: a ticket covered by an approved label-goal is never flagged" || return 1
}

test_swd_ac3a_agent_go_list_failure_logs_and_alerts() {
  swd_scan_env
  echo 1 > "$SQ_GH/gh-list-fail-project-a_repo-a"
  swd_install_curl_recorder "$SQ_GH"
  SWD_WEBHOOK="https://example.invalid/hook" swd_tick
  local log calls
  log=$(sq_log); calls=$(cat "$SQ_GH/curl-calls.log" 2>/dev/null)
  sq_cleanup
  assert_contains "$log" "[stale-digest] project-a/repo-a — agent-go list read failed" "AC3a: a failed list read is logged" || return 1
  assert_contains "$calls" "example.invalid/hook" "AC3a: a failed list read alerts once" || return 1
}

# --------------------------------------------------------------------------------------------------------
# AC3(b) — stuck ci_red/ci_pending/merge_conflict holds
# --------------------------------------------------------------------------------------------------------

AR2_BLK='**[fullstack-developer] BLOCKED**'

test_swd_ac3b_stuck_ci_red_hold_logged() {
  sq_env open
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  echo 3 > "$(rkp "$SQ_PIPE/orch-42.autoretry")"
  printf '%s Pipeline #42 parked, auto-retry (ci_red) — x\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-42.alert")"
  swd_touch_ago "$(rkp "$SQ_PIPE/orch-42.held")" $((5 * 3600))
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_contains "$log" "[stale-digest] project-a/repo-a#42 — stuck in ci_red hold for 5h" "AC3b: a 5h-old ci_red hold is logged" || return 1
}

test_swd_ac3b_fresh_hold_not_logged() {
  sq_env open
  swd_install_df "$SQ_GH" 10
  mk_held "$SQ_PIPE" 43 "$SQ_REPO"
  touch "$(rkp "$SQ_PIPE/orch-43.label-cleared")"
  echo 3 > "$(rkp "$SQ_PIPE/orch-43.autoretry")"
  printf '%s Pipeline #43 parked, auto-retry (ci_pending) — x\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-43.alert")"
  # mk_held leaves the .held mtime at "now" — well under the 4h default threshold
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "[stale-digest]" "AC3b: a freshly parked hold is never flagged" || return 1
}

test_swd_ac3b_non_ci_hold_not_logged() {
  sq_env open
  swd_install_df "$SQ_GH" 10
  mk_held "$SQ_PIPE" 44 "$SQ_REPO"
  touch "$(rkp "$SQ_PIPE/orch-44.label-cleared")"
  echo 3 > "$(rkp "$SQ_PIPE/orch-44.autoretry")"
  printf '%s Pipeline #44 waiting on JP — **[infra-operator] AWAITING GO**; relaunch after acting\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-44.alert")"
  swd_touch_ago "$(rkp "$SQ_PIPE/orch-44.held")" $((10 * 3600))
  swd_tick
  local log; log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "[stale-digest]" "AC3b: an old hold whose class is not ci_red/ci_pending/merge_conflict is never flagged" || return 1
}

# --------------------------------------------------------------------------------------------------------
# AC7 — read-only, hard requirement
# --------------------------------------------------------------------------------------------------------

test_swd_ac7_digest_makes_zero_mutating_calls() {
  swd_scan_env
  swd_list_fixture 505 "$(swd_iso_ago $((8 * 3600)))" null '[]'
  mk_held "$SQ_PIPE" 45 "$SQ_REPO"
  touch "$(rkp "$SQ_PIPE/orch-45.label-cleared")"   # keep the unrelated step-3/4 label lifecycle (its own `gh issue edit`) out of this call log
  echo 3 > "$(rkp "$SQ_PIPE/orch-45.autoretry")"
  printf '%s Pipeline #45 parked, auto-retry (merge_conflict) — x\n' "$(date -u +%FT%TZ)" > "$(rkp "$SQ_PIPE/orch-45.alert")"
  swd_touch_ago "$(rkp "$SQ_PIPE/orch-45.held")" $((6 * 3600))
  swd_install_df "$SQ_GH" 90
  cp "$(rkp "$SQ_PIPE/orch-45.alert")" "$SQ_PIPE/alert-45.before"

  swd_tick
  local calls mutating alert_same="no" held_present="no" no_orch_for_scanned_ticket="no"
  calls=$(gh_calls "$SQ_GH")
  mutating=$(printf '%s\n' "$calls" | grep -E 'issue edit|issue comment|pr merge|run rerun|label (add|delete)|-X[[:space:]]+(POST|PATCH|PUT|DELETE)')
  cmp -s "$(rkp "$SQ_PIPE/orch-45.alert")" "$SQ_PIPE/alert-45.before" && alert_same="yes"
  [ -f "$(rkp "$SQ_PIPE/orch-45.held")" ] && held_present="yes"
  ls "$SQ_PIPE"/orch-*-505.* >/dev/null 2>&1 || no_orch_for_scanned_ticket="yes"   # a merely-listed ticket is never turned into a local run record
  local log; log=$(sq_log)
  sq_cleanup
  assert_contains "$log" "[stale-digest] project-a/repo-a#505" "AC7: control — the digest did find something to report" || return 1
  assert_contains "$log" "[stale-digest] project-a/repo-a#45 — stuck in merge_conflict hold" "AC7: control — the hold was found too" || return 1
  assert_eq "$mutating" "" "AC7: zero mutating gh calls during the tick (no edit/comment/merge/rerun/label/-X write)" || return 1
  assert_eq "$alert_same" "yes" "AC7: the hold's .alert file is byte-identical after the tick" || return 1
  assert_eq "$held_present" "yes" "AC7: the hold is still held — the digest never clears or resolves it" || return 1
  assert_eq "$no_orch_for_scanned_ticket" "yes" "AC7: a scanned-but-not-running ticket gets no local run record" || return 1
}

run_test test_swd_ac3c_warn_at_85_percent
run_test test_swd_ac3c_no_warn_at_84_percent
run_test test_swd_ac3c_df_failure_logs_and_alerts
run_test test_swd_throttle_runs_once_then_again_after_backdate
run_test test_swd_hours_override_from_config_local
run_test test_swd_ac3a_stale_uncovered_ticket_logged
run_test test_swd_ac3a_fresh_ticket_not_logged
run_test test_swd_ac3a_recent_marker_resets_idle
run_test test_swd_ac3a_label_goal_coverage_is_not_reported
run_test test_swd_ac3a_agent_go_list_failure_logs_and_alerts
run_test test_swd_ac3b_stuck_ci_red_hold_logged
run_test test_swd_ac3b_fresh_hold_not_logged
run_test test_swd_ac3b_non_ci_hold_not_logged
run_test test_swd_ac7_digest_makes_zero_mutating_calls
