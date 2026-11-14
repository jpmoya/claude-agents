# Issue #643 ACs 1-6 + Observability — infra/ci-runners/ci-queue-collect.sh. No live network
# calls: `gh api` is replaced by the script's own CI_QUEUE_FIXTURE_DIR/CI_QUEUE_FIXTURE_FAIL seam
# (mirrors ci-report.sh's CI_REPORT_JOBS_FILE pattern); Sentry/Slack are exercised through a
# counting fake `curl` on PATH, same seam ci-metrics.sh's own tests use.
#
# Safe to source into run-tests.sh's shared shell: no top-level `exit`, every helper prefixed
# _ciqc_, every test function declares its own locals.

HERE_CIQC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQC=$(cd "$HERE_CIQC/../../.." && pwd)
COLLECTOR_CIQC="$REPO_ROOT_CIQC/infra/ci-runners/ci-queue-collect.sh"
REPOS_FILE_CIQC="$REPO_ROOT_CIQC/scripts/ci-metrics.repos"

# _ciqc_build_fixtures <dir> — the standard scenario used by most of these tests:
#   - Benjis-Plants/scheduler: 1 queued run (id 101), dependabot actor AND pull_request event
#     (precedence case) with a .999Z fractional-seconds queued job, the earliest timestamp —
#     exercises both the dependabot-wins-over-pr precedence and fractional-seconds stripping on
#     the SAME entry that ends up as `oldest`.
#   - Benjis-Plants/benjis-sales-tool: 1 in_progress run (id 201), name "Deploy to production",
#     push event -> deploy_release.
#   - jpmoya/claude-agents: 1 queued run (id 301), pull_request event, non-dependabot actor -> pr.
#   - Benjis-Plants/benjis-ops-tool: 7 queued runs (ids 401-407), schedule event, non-dependabot,
#     non-deploy name -> other. Only AC6's MAX_RUN_LOOKUPS_PER_REPO (5) of these get a job lookup.
#   - org runners: 3 total, 2 busy. jpmoya/claude-agents repo-level runners: 2 total, 1 busy.
#     Combined busy=3, total=5 — deliberately NOT equal to ci-metrics.repos' SLOTS=4 (AC4).
_ciqc_build_fixtures() {
  local d=$1
  # #648: status:"online" added to every runner below so the online-only counting change doesn't
  # alter this suite's pre-existing busy=3/total=5 expectations (AC4) — all 5 are online here.
  cat > "$d/runners-org.json" <<'EOF'
{"total_count":3,"runners":[{"id":1,"name":"r1","status":"online","busy":true},{"id":2,"name":"r2","status":"online","busy":true},{"id":3,"name":"r3","status":"online","busy":false}]}
EOF
  cat > "$d/runners-repo.json" <<'EOF'
{"total_count":2,"runners":[{"id":10,"name":"r10","status":"online","busy":true},{"id":11,"name":"r11","status":"online","busy":false}]}
EOF
  cat > "$d/runs-Benjis-Plants__scheduler-queued.json" <<'EOF'
{"workflow_runs":[{"id":101,"name":"CI","event":"pull_request","actor":{"login":"dependabot[bot]"}}]}
EOF
  echo '{"workflow_runs":[]}' > "$d/runs-Benjis-Plants__scheduler-in_progress.json"
  cat > "$d/jobs-101.json" <<'EOF'
{"jobs":[{"id":1,"status":"queued","created_at":"2020-01-01T00:00:00.999Z"}]}
EOF

  echo '{"workflow_runs":[]}' > "$d/runs-Benjis-Plants__benjis-sales-tool-queued.json"
  cat > "$d/runs-Benjis-Plants__benjis-sales-tool-in_progress.json" <<'EOF'
{"workflow_runs":[{"id":201,"name":"Deploy to production","event":"push","actor":{"login":"jpmoya"}}]}
EOF
  cat > "$d/jobs-201.json" <<'EOF'
{"jobs":[{"id":2,"status":"queued","created_at":"2026-11-10T10:05:00Z"},{"id":3,"status":"completed","created_at":"2026-11-10T10:05:01Z"}]}
EOF

  cat > "$d/runs-jpmoya__claude-agents-queued.json" <<'EOF'
{"workflow_runs":[{"id":301,"name":"CI","event":"pull_request","actor":{"login":"someone"}}]}
EOF
  echo '{"workflow_runs":[]}' > "$d/runs-jpmoya__claude-agents-in_progress.json"
  cat > "$d/jobs-301.json" <<'EOF'
{"jobs":[{"id":4,"status":"queued","created_at":"2026-11-10T09:00:00Z"}]}
EOF

  local runs='[' i
  for i in 401 402 403 404 405 406 407; do
    runs="$runs{\"id\":$i,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    cat > "$d/jobs-$i.json" <<EOF
{"jobs":[{"id":$((i+100)),"status":"queued","created_at":"2026-11-10T08:00:00Z"}]}
EOF
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$d/runs-Benjis-Plants__benjis-ops-tool-queued.json"
  echo '{"workflow_runs":[]}' > "$d/runs-Benjis-Plants__benjis-ops-tool-in_progress.json"
}

# _ciqc_run <pipe> <fixturedir> [extra env...] — one collection cycle, forced (bypasses the
# throttle) unless the caller overrides CI_QUEUE_FORCE in <extra env...>.
_ciqc_run() {
  local pipe=$1 fixdir=$2; shift 2
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$REPOS_FILE_CIQC" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    env "$@" bash "$COLLECTOR_CIQC" )
    # `env "$@"`, not a bare `"$@"` prefix: an extra VAR=val arrives here via a parameter
    # expansion, and bash only recognises the NAME=VALUE assignment-prefix syntax lexically
    # (before expansion) — a word that becomes "VAR=val" only after "$@" expands is just treated
    # as the command name otherwise, which fails with "command not found".
}

_ciqc_calls() { cat "$1/calls.log" 2>/dev/null; }   # total API call count from the last run

test_ciqc_ac1_repos_file_lists_benjis_ops_tool() {
  assert_contains "$(cat "$REPOS_FILE_CIQC")" "Benjis-Plants/benjis-ops-tool" "AC1: ci-metrics.repos lists benjis-ops-tool" || return 1
}

test_ciqc_ac2_atomic_write_pattern_in_source() {
  local src; src=$(cat "$COLLECTOR_CIQC")
  assert_contains "$src" "mktemp" "AC2: collector uses mktemp for its atomic write" || return 1
  assert_contains "$src" 'mv -f "$tmp" "$OUT"' "AC2: collector moves the temp file onto \$OUT (grep-verifiable mktemp+mv pair)" || return 1
  case "$src" in
    *'> "$OUT"'*) fail "AC2: collector must never write \$OUT directly (no mktemp+mv), found a direct redirect" || return 1 ;;
  esac
}

test_ciqc_ac2_fresh_snapshot_is_throttled_no_calls_no_change() {
  local pipe before after rc
  pipe=$(mktemp -d)
  echo '{"as_of":"2020-01-01T00:00:00Z","runners_busy":0,"runners_total":0,"queued_total":0,"categories":[],"oldest":null}' > "$pipe/status-ci.json"
  before=$(cat "$pipe/status-ci.json")
  ( CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" CI_QUEUE_REPOS_FILE="$REPOS_FILE_CIQC" \
    bash "$COLLECTOR_CIQC" )
  rc=$?
  after=$(cat "$pipe/status-ci.json")
  local calls; calls=$(_ciqc_calls "$pipe")
  rm -rf "$pipe"

  assert_exit0 "$rc" "AC2: a throttled cycle still exits 0" || return 1
  assert_eq "$before" "$after" "AC2: a fresh (un-backdated) snapshot is throttled — no write" || return 1
  assert_eq "${calls:-0}" "0" "AC2: a throttled cycle makes zero API calls" || return 1
}

test_ciqc_ac2_backdated_snapshot_runs() {
  local pipe rc calls
  pipe=$(mktemp -d)
  echo '{"as_of":"2020-01-01T00:00:00Z","runners_busy":0,"runners_total":0,"queued_total":0,"categories":[],"oldest":null}' > "$pipe/status-ci.json"
  python3 -c "import os,sys,time; t=time.time()-1000; os.utime(sys.argv[1], (t, t))" "$pipe/status-ci.json"
  local fixdir; fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  ( CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" CI_QUEUE_REPOS_FILE="$REPOS_FILE_CIQC" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" bash "$COLLECTOR_CIQC" )
  rc=$?
  calls=$(_ciqc_calls "$pipe")
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "AC2: a run past the interval still exits 0" || return 1
  assert_ne "${calls:-0}" "0" "AC2: a snapshot older than CI_QUEUE_INTERVAL_SECS is no longer throttled" || return 1
}

# Issue #663 AC4 (supersedes the old AC3 "whole cycle aborts" behavior — see the issue's own
# "one bad repo blanks the whole cycle" finding): a malformed response for ONE repo now skips
# just that repo; the cycle still succeeds and writes fresh data for every other repo, with the
# failing repo's name surfaced in `unavailable_repos`.
test_ciqc_ac4_one_malformed_repo_is_skipped_not_fatal() {
  local pipe fixdir out rc unavail queued
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  echo '{}' > "$fixdir/runs-Benjis-Plants__scheduler-queued.json"   # 200 OK but missing "workflow_runs"
  echo '{"as_of":"2020-01-01T00:00:00Z","runners_busy":0,"runners_total":0,"queued_total":0,"categories":[],"oldest":null}' > "$pipe/status-ci.json"
  _ciqc_run "$pipe" "$fixdir"
  rc=$?
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  unavail=$(printf '%s' "$out" | jq -c '.unavailable_repos')
  queued=$(printf '%s' "$out" | jq '.queued_total')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "AC4: a cycle with one malformed repo still exits 0" || return 1
  assert_eq "$unavail" '["Benjis-Plants/scheduler"]' "AC4: the malformed repo is named in unavailable_repos" || return 1
  # Full fixture totals 8 queued jobs (AC5's own test: dependabot 1 + deploy_release 1 + pr 1 +
  # other 5). Dropping just the scheduler repo's 1 (dependabot) leaves 7 from the other 3 repos.
  assert_eq "$queued" "7" "AC4: the OTHER repos' data is still collected and written (not a zeroed snapshot)" || return 1
}

test_ciqc_ac4_every_repo_failing_is_still_a_whole_cycle_failure() {
  local pipe fixdir before after rc
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  # Every configured repo's queued-run-list response is malformed — nothing left to build a real
  # snapshot from. This must still behave like any other whole-cycle failure: previous snapshot
  # kept byte-identical, not a zeroed/partial write.
  echo '{}' > "$fixdir/runs-Benjis-Plants__scheduler-queued.json"
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-sales-tool-queued.json"
  echo '{}' > "$fixdir/runs-jpmoya__claude-agents-queued.json"
  echo '{}' > "$fixdir/runs-Benjis-Plants__benjis-ops-tool-queued.json"
  echo '{"as_of":"2020-01-01T00:00:00Z","runners_busy":0,"runners_total":0,"queued_total":0,"categories":[],"oldest":null}' > "$pipe/status-ci.json"
  before=$(cat "$pipe/status-ci.json")
  _ciqc_run "$pipe" "$fixdir"
  rc=$?
  after=$(cat "$pipe/status-ci.json")
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "AC4: a whole-cycle failure still exits 0" || return 1
  assert_eq "$before" "$after" "AC4: every repo failing is treated as a whole-cycle failure (previous snapshot kept)" || return 1
}

test_ciqc_ac3_failed_api_call_leaves_snapshot_byte_identical_and_no_temp_file() {
  local pipe fixdir before after rc tmp_left
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  echo '{"as_of":"2020-01-01T00:00:00Z","runners_busy":1,"runners_total":1,"queued_total":1,"categories":[{"key":"other","count":1}],"oldest":{"key":"other","queued_at":"2020-01-01T00:00:00Z"}}' > "$pipe/status-ci.json"
  before=$(cat "$pipe/status-ci.json")
  _ciqc_run "$pipe" "$fixdir" CI_QUEUE_FIXTURE_FAIL=1
  rc=$?
  after=$(cat "$pipe/status-ci.json")
  tmp_left=$(find "$pipe" -maxdepth 1 -name 'status-ci.json.*' 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "AC3: a failed API call still exits 0" || return 1
  assert_eq "$before" "$after" "AC3: the previous snapshot is byte-for-byte unchanged on failure" || return 1
  assert_eq "$tmp_left" "0" "AC3: a failed cycle leaves no mktemp leftover in \$PIPE" || return 1
}

test_ciqc_ac4_runner_counts_are_live_not_the_slots_constant() {
  local pipe fixdir out busy total
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  _ciqc_run "$pipe" "$fixdir"
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  busy=$(printf '%s' "$out" | jq '.runners_busy')
  total=$(printf '%s' "$out" | jq '.runners_total')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$busy" "3" "AC4: runners_busy comes from the live fixture (org 2 busy + repo 1 busy), not SLOTS=4" || return 1
  assert_eq "$total" "5" "AC4: runners_total comes from the live fixture (org 3 + repo 2), not SLOTS=4" || return 1
}

test_ciqc_ac5_categorization_precedence_and_exact_counts() {
  local pipe fixdir out
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  _ciqc_run "$pipe" "$fixdir"
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  rm -rf "$pipe" "$fixdir"

  assert_eq "$(printf '%s' "$out" | jq '.categories | length')" "4" "AC5: exactly the 4 vocab keys are present (none silently dropped)" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.categories[] | select(.key=="dependabot") | .count')" "1" "AC5: dependabot wins over pull_request (precedence) — exactly 1" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.categories[] | select(.key=="deploy_release") | .count')" "1" "AC5: deploy-workflow-name run categorised deploy_release" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.categories[] | select(.key=="pr") | .count')" "1" "AC5: plain pull_request run categorised pr" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.categories[] | select(.key=="other") | .count')" "5" "AC5: unmatched (schedule-triggered) runs land in other, not dropped" || return 1
}

test_ciqc_oldest_strips_fractional_seconds() {
  local pipe fixdir out oldest
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  _ciqc_run "$pipe" "$fixdir"
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  oldest=$(printf '%s' "$out" | jq -c '.oldest')
  rm -rf "$pipe" "$fixdir"

  assert_eq "$oldest" '{"key":"dependabot","queued_at":"2020-01-01T00:00:00Z"}' "oldest strips the .999Z fractional seconds AND picks the earliest queued job" || return 1
}

test_ciqc_ac6_run_lookup_cap_bounds_total_calls() {
  local pipe fixdir calls bound
  pipe=$(mktemp -d); fixdir=$(mktemp -d); _ciqc_build_fixtures "$fixdir"
  _ciqc_run "$pipe" "$fixdir"
  calls=$(_ciqc_calls "$pipe")
  rm -rf "$pipe" "$fixdir"

  # 2 (runners) + 2*4 (run lists) + (1+1+1+5) (job lookups, the 7-run repo capped to 5) = 18.
  # Without the cap the 7-run repo would cost 7, giving 20 — this value only matches with the cap applied.
  assert_eq "$calls" "18" "AC6: run-lookup cap (5) applied to the 7-run repo — exact call count" || return 1
  bound=$((2 + 2 * 4 + 5 * 4))
  assert_le "$calls" "$bound" "AC6: total calls stay <= the stated bound formula (2 + 2N + MAX_RUN_LOOKUPS_PER_REPO*N)" || return 1
}

# ---- Observability -----------------------------------------------------------------------------

_ciqc_write_recording_curl() {  # <bindir>
  cat > "$1/curl" <<'EOF'
#!/bin/bash
echo "CALL $*" >> "$(dirname "$0")/calls"
exit 0
EOF
  chmod +x "$1/curl"
}

test_ciqc_obs_sentry_event_has_route_release_environment_no_token_leak() {
  local pipe fixdir bindir body token
  pipe=$(mktemp -d); fixdir=$(mktemp -d); bindir=$(mktemp -d)
  _ciqc_write_recording_curl "$bindir"
  token="ghp_fakeTestTokenNotReal0000"
  ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$REPOS_FILE_CIQC" CI_QUEUE_FIXTURE_DIR="$fixdir" CI_QUEUE_FIXTURE_FAIL=1 \
    SENTRY_DSN="https://testkey@sentry.test/42" GH_TOKEN="$token" \
    PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    bash "$COLLECTOR_CIQC" )
  body=$(grep "sentry.test" "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$fixdir" "$bindir"

  assert_contains "$body" "route\":\"ci-queue/collect\"" "Observability: Sentry event carries route=ci-queue/collect" || return 1
  assert_contains "$body" "release\":\"" "Observability: Sentry event carries a release" || return 1
  assert_contains "$body" "environment\":\"" "Observability: Sentry event carries an environment" || return 1
  case "$body" in
    *"$token"*) fail "Observability: the fake GH_TOKEN must never appear in the Sentry call" || return 1 ;;
  esac
}

# Issue #663 AC6: the Slack-alert trigger is lowered from a 3-failure streak to 2 (fires once per
# streak, same "once on the transition into the streak" semantics, just at a lower bar) — an
# intermittent pair of failures a day apart used to never page at all.
test_ciqc_obs_slack_only_on_second_consecutive_failure() {
  local pipe fixdir bindir slack_calls
  pipe=$(mktemp -d); fixdir=$(mktemp -d); bindir=$(mktemp -d)
  _ciqc_write_recording_curl "$bindir"

  _ciqc_fail_run() {  # one forced-failure cycle
    ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
      CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
      CI_QUEUE_REPOS_FILE="$REPOS_FILE_CIQC" CI_QUEUE_FIXTURE_DIR="$fixdir" CI_QUEUE_FIXTURE_FAIL=1 \
      SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X" \
      PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
      bash "$COLLECTOR_CIQC" )
  }
  _ciqc_ok_run() {  # one successful cycle (resets the failure streak)
    _ciqc_build_fixtures "$fixdir"
    ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
      CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
      CI_QUEUE_REPOS_FILE="$REPOS_FILE_CIQC" CI_QUEUE_FIXTURE_DIR="$fixdir" \
      SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X" \
      PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
      bash "$COLLECTOR_CIQC" )
  }

  _ciqc_fail_run   # 1st consecutive failure: no Slack yet
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  assert_eq "${slack_calls:-0}" "0" "Observability: 1 failure posts no Slack message" || { rm -rf "$pipe" "$fixdir" "$bindir"; return 1; }

  _ciqc_ok_run   # streak reset
  _ciqc_fail_run   # 1 more (streak restarted): still no Slack
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  assert_eq "${slack_calls:-0}" "0" "Observability: a reset streak's 1st failure still posts no Slack message" || { rm -rf "$pipe" "$fixdir" "$bindir"; return 1; }

  _ciqc_fail_run   # 2nd consecutive failure: exactly one Slack post
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$fixdir" "$bindir"
  assert_eq "${slack_calls:-0}" "1" "Observability: the 2nd consecutive failure posts exactly one Slack message" || return 1
}

run_test test_ciqc_ac1_repos_file_lists_benjis_ops_tool
run_test test_ciqc_ac2_atomic_write_pattern_in_source
run_test test_ciqc_ac2_fresh_snapshot_is_throttled_no_calls_no_change
run_test test_ciqc_ac2_backdated_snapshot_runs
run_test test_ciqc_ac4_one_malformed_repo_is_skipped_not_fatal
run_test test_ciqc_ac4_every_repo_failing_is_still_a_whole_cycle_failure
run_test test_ciqc_ac3_failed_api_call_leaves_snapshot_byte_identical_and_no_temp_file
run_test test_ciqc_ac4_runner_counts_are_live_not_the_slots_constant
run_test test_ciqc_ac5_categorization_precedence_and_exact_counts
run_test test_ciqc_oldest_strips_fractional_seconds
run_test test_ciqc_ac6_run_lookup_cap_bounds_total_calls
run_test test_ciqc_obs_sentry_event_has_route_release_environment_no_token_leak
run_test test_ciqc_obs_slack_only_on_second_consecutive_failure
