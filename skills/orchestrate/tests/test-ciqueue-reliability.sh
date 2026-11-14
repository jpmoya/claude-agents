# Issue #663 — CI collector reliability: AC2 (queued-count honesty under a deep backlog), AC3
# (hung `gh` calls fail silently), AC4's extra "all repos failed" edge (AC4's main per-repo-skip
# coverage lives in test-ciqueue-collector.sh, alongside the pre-existing fixtures it builds on),
# AC6 (lowered Slack-alert threshold + redacted stderr in the alert).
#
# Self-contained (own HERE/paths/helpers, `_ciqr_` prefix) rather than reusing
# test-ciqueue-collector.sh's helpers — this file must not depend on load order with any sibling
# test-*.sh file. Safe to source into run-tests.sh's shared shell: no top-level `exit`, every
# helper prefixed _ciqr_, every test function declares its own locals.

HERE_CIQR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQR=$(cd "$HERE_CIQR/../../.." && pwd)
COLLECTOR_CIQR="$REPO_ROOT_CIQR/infra/ci-runners/ci-queue-collect.sh"
REAL_REPOS_FILE_CIQR="$REPO_ROOT_CIQR/scripts/ci-metrics.repos"

# _ciqr_run <pipe> <fixturedir> <reposfile> [extra env...] — one forced collection cycle.
_ciqr_run() {
  local pipe=$1 fixdir=$2 reposfile=$3; shift 3
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    env "$@" bash "$COLLECTOR_CIQR" )
}

_ciqr_trivial_runners() {  # <dir> — zero runners, both shaped calls satisfied
  echo '{"total_count":0,"runners":[]}' > "$1/runners-org.json"
  echo '{"total_count":0,"runners":[]}' > "$1/runners-repo.json"
}

# ---- AC2: queued-count honesty — the collector's own truncated flag ----------------------------

test_ciqr_ac2_single_repo_over_cap_sets_truncated_true() {
  local pipe fixdir reposfile out truncated i
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  printf 'owner/overcap\n' > "$reposfile"
  _ciqr_trivial_runners "$fixdir"

  # 7 queued runs, cap is 5: only the oldest 5 (ids 1-5) ever get a job lookup, but the
  # TRUNCATION signal must come from the full pre-selection count (7), not the capped selection.
  local runs='['
  for i in 1 2 3 4 5 6 7; do
    runs="$runs{\"id\":$i,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    echo '{"jobs":[]}' > "$fixdir/jobs-$i.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$fixdir/runs-owner__overcap-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-owner__overcap-in_progress.json"

  _ciqr_run "$pipe" "$fixdir" "$reposfile"
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  truncated=$(printf '%s' "$out" | jq '.truncated')
  rm -rf "$pipe" "$fixdir" "$reposfile"

  assert_eq "$truncated" "true" "AC2: a repo with more runs than MAX_RUN_LOOKUPS_PER_REPO (5) sets truncated:true" || return 1
}

test_ciqr_ac2_exactly_at_cap_is_not_truncated() {
  local pipe fixdir reposfile out truncated i
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  printf 'owner/atcap\n' > "$reposfile"
  _ciqr_trivial_runners "$fixdir"

  local runs='['
  for i in 1 2 3 4 5; do
    runs="$runs{\"id\":$i,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    echo '{"jobs":[]}' > "$fixdir/jobs-$i.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$fixdir/runs-owner__atcap-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-owner__atcap-in_progress.json"

  _ciqr_run "$pipe" "$fixdir" "$reposfile"
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  truncated=$(printf '%s' "$out" | jq '.truncated')
  rm -rf "$pipe" "$fixdir" "$reposfile"

  assert_eq "$truncated" "false" "AC2: exactly MAX_RUN_LOOKUPS_PER_REPO (5) runs is NOT truncated (every run got looked up)" || return 1
}

test_ciqr_ac2_one_of_several_repos_over_cap_still_sets_truncated_true() {
  local pipe fixdir reposfile out truncated i
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(mktemp)
  printf 'owner/fine\nowner/overcap2\n' > "$reposfile"
  _ciqr_trivial_runners "$fixdir"

  echo '{"workflow_runs":[]}' > "$fixdir/runs-owner__fine-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-owner__fine-in_progress.json"

  local runs='['
  for i in 11 12 13 14 15 16; do
    runs="$runs{\"id\":$i,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    echo '{"jobs":[]}' > "$fixdir/jobs-$i.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$fixdir/runs-owner__overcap2-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-owner__overcap2-in_progress.json"

  _ciqr_run "$pipe" "$fixdir" "$reposfile"
  out=$(cat "$pipe/status-ci.json" 2>/dev/null)
  truncated=$(printf '%s' "$out" | jq '.truncated')
  rm -rf "$pipe" "$fixdir" "$reposfile"

  assert_eq "$truncated" "true" "AC2: truncated is true for the whole cycle when ANY one repo exceeds the cap" || return 1
}

# ---- AC3: a hung `gh api` call fails (times out) instead of hanging forever --------------------

_ciqr_write_hanging_gh() {  # <bindir> — a fake `gh` that never returns on its own AND ignores
  # SIGALRM/SIGTERM for a while, same as a real `gh` (a Go binary: the Go runtime installs its
  # own SIGALRM handler that does nothing unless the program calls signal.Notify for it) — this
  # is the exact shape that breaks a bare `perl alarm; exec` wrapper (the alarm fires in a
  # replaced process that never dies from it) and proves the fork+kill fallback actually works.
  cat > "$1/gh" <<'EOF'
#!/bin/bash
trap '' ALRM TERM
exec sleep 30
EOF
  chmod +x "$1/gh"
}

test_ciqr_ac3_hung_gh_call_times_out_and_counts_as_a_failure() {
  local pipe bindir rc start end elapsed fails
  pipe=$(mktemp -d); bindir=$(mktemp -d)
  _ciqr_write_hanging_gh "$bindir"
  start=$(date +%s)
  ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" \
    CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$REAL_REPOS_FILE_CIQR" \
    CI_QUEUE_GH_TIMEOUT_SECS=2 \
    PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    bash "$COLLECTOR_CIQR" )
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  fails=$(python3 -c "
import json
try: print(json.load(open('$pipe/state.json')).get('fails', 0))
except Exception: print('?')
" 2>/dev/null)
  rm -rf "$pipe" "$bindir"

  assert_exit0 "$rc" "AC3: a hung gh call still exits 0" || return 1
  assert_le "$elapsed" "15" "AC3: the cycle returns well within the 60s lock-reclaim window (timeout=2s)" || return 1
  assert_eq "${fails:-?}" "1" "AC3: the timeout counts as a normal API failure (fails=1), not a hang" || return 1
}

# ---- AC6: lowered Slack threshold (fires at 2, was 3) + redacted gh stderr in the alert --------

_ciqr_write_failing_gh_with_token() {  # <bindir> — a fake `gh` that fails, echoing GH_TOKEN to stderr
  cat > "$1/gh" <<'EOF'
#!/bin/bash
echo "error: bad credentials for token ${GH_TOKEN:-unknown}" >&2
exit 1
EOF
  chmod +x "$1/gh"
}

_ciqr_write_recording_curl() {  # <bindir> — records every curl invocation's args to ./calls
  cat > "$1/curl" <<'EOF'
#!/bin/bash
echo "CALL $*" >> "$(dirname "$0")/calls"
exit 0
EOF
  chmod +x "$1/curl"
}

test_ciqr_ac6_lowered_threshold_fires_at_two_with_redacted_stderr() {
  local pipe bindir token rc slack_calls body
  pipe=$(mktemp -d); bindir=$(mktemp -d)
  _ciqr_write_failing_gh_with_token "$bindir"
  _ciqr_write_recording_curl "$bindir"
  token="ghp_fakeTestTokenAC6Reliability0"

  _ciqr_run_once() {
    ( CI_QUEUE_FORCE=1 CI_QUEUE_OUT="$pipe/status-ci.json" CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
      CI_QUEUE_STATE_FILE="$pipe/state.json" CI_QUEUE_LOCKDIR="$pipe/lockdir" \
      CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" CI_QUEUE_CALL_LOG="$pipe/calls.log" \
      CI_QUEUE_REPOS_FILE="$REAL_REPOS_FILE_CIQR" \
      SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X" GH_TOKEN="$token" \
      PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
      bash "$COLLECTOR_CIQR" )
  }

  _ciqr_run_once   # failure 1: no Slack yet
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  assert_eq "${slack_calls:-0}" "0" "AC6: 1st consecutive failure posts no Slack message" || { rm -rf "$pipe" "$bindir"; return 1; }

  _ciqr_run_once   # failure 2: exactly one Slack post, carrying the redacted gh stderr
  slack_calls=$(grep -c "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  body=$(grep "hooks.slack.test" "$bindir/calls" 2>/dev/null)
  rm -rf "$pipe" "$bindir"

  assert_eq "${slack_calls:-0}" "1" "AC6: the 2nd consecutive failure posts exactly one Slack message (lowered threshold)" || return 1
  assert_contains "$body" "bad credentials" "AC6: the alert carries the captured gh stderr detail" || return 1
  assert_contains "$body" '***' "AC6: the redacted token placeholder appears in the alert" || return 1
  case "$body" in
    *"$token"*) fail "AC6: the real GH_TOKEN must never appear in the Slack call" || return 1 ;;
  esac
}

run_test test_ciqr_ac2_single_repo_over_cap_sets_truncated_true
run_test test_ciqr_ac2_exactly_at_cap_is_not_truncated
run_test test_ciqr_ac2_one_of_several_repos_over_cap_still_sets_truncated_true
run_test test_ciqr_ac3_hung_gh_call_times_out_and_counts_as_a_failure
run_test test_ciqr_ac6_lowered_threshold_fires_at_two_with_redacted_stderr
