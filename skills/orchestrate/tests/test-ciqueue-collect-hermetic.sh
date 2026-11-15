# #645 code-review follow-up (MEDIUM finding 2) — the test suite's disable of #643's host-side CI
# queue collector (CI_QUEUE_COLLECT_ENABLED=0, set by run-tests.sh) must survive a real
# ~/.claude/pipeline/config.local.sh turning it back on for its one intended host. Without the
# CI_QUEUE_COLLECT_TEST_DISABLE guard in config.sh, config.local.sh's plain assignment (sourced
# inside config.sh, after run-tests.sh's export) wins and a test run on that host would make live
# `gh`/GitHub Actions API calls.
#
# Prefix cqh_ / CQH_. Placeholder repo names only (public repo).

HERE_CQH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_CQH="$HERE_CQH/.."

# repos_file_count — number of owner/repo lines in the collector's default REPOS_FILE
# (scripts/ci-metrics.repos), same filter the collector's own `repos()` uses (excludes the
# trailing SLOTS=N line) — lets an end-to-end test assert an exact per-repo call count without
# hardcoding (or drifting from) that file's current contents.
repos_file_count() {
  grep -c -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[[:space:]]*$' "$HERE_CQH/../../../scripts/ci-metrics.repos" 2>/dev/null
}

# cqh_write_fake_gh <dir> <marker> — proves invocation positively (touches <marker>) rather than
# by absence of a side effect that might never have fired anyway. Mirrors test-ac6-disabled-noop.sh's
# fake-curl pattern; this fakes `gh` since ci-queue-collect.sh shells out to `gh api`.
cqh_write_fake_gh() {
  local dir=$1 marker=$2
  cat > "$dir/gh" <<EOF
#!/bin/bash
touch "$marker"
echo '{"fake":"gh should never have been invoked under CI_QUEUE_COLLECT_TEST_DISABLE"}'
exit 0
EOF
  chmod +x "$dir/gh"
  # report-status.sh backgrounds the collector with curl/Sentry+Slack reachable too; a no-op fake
  # curl keeps this hermetic in case a stray failure path tries to phone home.
  cat > "$dir/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$dir/curl"
}

# cqh_write_fake_gh_shaped <dir> <callslog> — a `gh` fake shaped enough for the REAL
# ci-queue-collect.sh to run an entire cycle end to end without a FIXTURE_DIR: any
# `actions/runners` call gets zero runners, everything else (queued/in_progress/completed run
# lists, job lookups) gets an empty `workflow_runs`/`jobs` list — every `_ciq_call_shaped` required
# key is present, so no step aborts early before reaching the metrics gate under test. Every
# invocation's raw "$*" is appended to <callslog> (test-reviewer finding, PR #713: proves what the
# collector did or didn't call, not just that it exited 0).
cqh_write_fake_gh_shaped() {
  local dir=$1 callslog=$2
  cat > "$dir/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$callslog"
case "\$*" in
  *"actions/runners"*) echo '{"total_count":0,"runners":[]}' ;;
  *"/jobs"*"filter=latest"*) echo '{"jobs":[]}' ;;
  *) echo '{"workflow_runs":[]}' ;;
esac
exit 0
EOF
  chmod +x "$dir/gh"
  cat > "$dir/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$dir/curl"
}

# cqh_poll_marker <marker> <timeout_secs> -> 0 if <marker> appears within the timeout, 1 otherwise.
# report-status.sh backgrounds the collector ("( ... & )"), so a passing fixed-gate case can only be
# proven by waiting long enough for a WOULD-fire collector to have run — not by checking immediately.
cqh_poll_marker() {
  local marker=$1 timeout=$2 waited=0
  while [ "$waited" -lt "$timeout" ]; do
    [ -e "$marker" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  [ -e "$marker" ]
}

test_cqh_config_local_cannot_re_enable_the_collector_under_test_disable() {
  local home out
  home=$(new_home)
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
CI_QUEUE_COLLECT_ENABLED=1
EOF
  out=$(HOME="$home" CI_QUEUE_COLLECT_ENABLED=0 CI_QUEUE_COLLECT_TEST_DISABLE=1 \
    bash -c 'set -u; . "$1/config.sh"; echo "$CI_QUEUE_COLLECT_ENABLED"' _ "$RS_CQH" 2>&1)
  rm -rf "$home"

  assert_eq "$out" "0" "config.local.sh's CI_QUEUE_COLLECT_ENABLED=1 is overridden back to 0 under CI_QUEUE_COLLECT_TEST_DISABLE=1 (output: $out)" || return 1
}

test_cqh_config_local_still_wins_without_test_disable() {
  # sanity check: without the test-only marker, config.local.sh's host override still works as
  # documented (report-status.sh's own opt-in path) — the guard above is test-scoped, not a
  # permanent lockout of the real feature. Explicitly clears CI_QUEUE_COLLECT_TEST_DISABLE rather
  # than just omitting it from this invocation's env: run-tests.sh exports it for the whole shared
  # shell this suite runs in, and a bare `bash -c` subshell inherits exported vars from its parent
  # — omitting it here would leave the suite's own export in effect and falsely pass.
  local home out
  home=$(new_home)
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
CI_QUEUE_COLLECT_ENABLED=1
EOF
  out=$(HOME="$home" bash -c 'unset CI_QUEUE_COLLECT_TEST_DISABLE; set -u; . "$1/config.sh"; echo "$CI_QUEUE_COLLECT_ENABLED"' _ "$RS_CQH" 2>&1)
  rm -rf "$home"

  assert_eq "$out" "1" "without CI_QUEUE_COLLECT_TEST_DISABLE, config.local.sh's CI_QUEUE_COLLECT_ENABLED=1 is honoured (output: $out)" || return 1
}

# Issue #660: CI_QUEUE_METRICS_ENABLED is opt-OUT, not opt-in — config.sh defaults it to 1 so the
# live duration/health pull turns on automatically wherever CI_QUEUE_COLLECT_ENABLED is already 1.
# A plain default-only typo (e.g. `:-0` instead of `:-1`) would ship the feature permanently dark
# with no other test here going red for it.
test_cqh_metrics_enabled_defaults_to_1_via_config_sh() {
  local home out
  home=$(new_home)
  out=$(HOME="$home" bash -c 'unset CI_QUEUE_METRICS_ENABLED; set -u; . "$1/config.sh"; echo "$CI_QUEUE_METRICS_ENABLED"' _ "$RS_CQH" 2>&1)
  rm -rf "$home"

  assert_eq "$out" "1" "CI_QUEUE_METRICS_ENABLED, left completely unset, defaults to 1 via config.sh (output: $out)" || return 1
}

# _cqh_metrics_e2e_completed_calls <config.local.sh-body> -> number of "status=completed" gh
# invocations made by the REAL collector, launched end to end through the REAL report-status.sh
# (same launch line #660 touched), under the given host config.local.sh. No FIXTURE_DIR: a shaped
# fake `gh` (cqh_write_fake_gh_shaped) lets every real step of collect_once succeed so execution
# actually reaches the metrics gate under test, instead of aborting early on unrelated fixture gaps.
_cqh_metrics_e2e_completed_calls() {
  local body=$1 pipe home bindir callslog out
  pipe=$(new_pipe); home=$(new_home)
  printf '%s\n' "$body" > "$home/.claude/pipeline/config.local.sh"
  bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  callslog=$(mktemp -u "${TMPDIR:-/tmp}/orch-gh-calls.XXXXXX")
  cqh_write_fake_gh_shaped "$bindir" "$callslog"

  ( PIPE="$pipe" HOME="$home" \
    CI_QUEUE_COLLECT_TEST_DISABLE=0 \
    STATUS_PUSH_URL="https://example.invalid/beat" STATUS_PUSH_TOKEN="fake-token-value" \
    PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    "$RS_CQH/report-status.sh" event ) >/dev/null 2>&1

  # 30s, not 10s: this waits on a REAL multi-call collector cycle (runners + 2 calls per tracked
  # repo + possibly the completed-run call), on a possibly-busy shared CI runner -- cqh_poll_marker
  # returns as soon as the file appears, so a generous ceiling costs nothing on a fast machine but
  # avoids a false FAIL from timing rather than a real code bug on a slow/busy one.
  cqh_poll_marker "$pipe/status-ci.json" 30
  out=$(grep -c "status=completed" "$callslog" 2>/dev/null)
  rm -rf "$pipe" "$home" "$bindir"; rm -f "$callslog"
  printf '%s' "${out:-0}"
}

# test-reviewer finding (PR #713, Tier 1 vacuous): the config.sh-only version of this test
# ("source config.sh, check the final value") passed identically even with config.sh fully
# reverted to pre-#660 — a plain CI_QUEUE_METRICS_ENABLED=0 in config.local.sh survives being
# sourced regardless of whether config.sh's own default logic exists at all (config.local.sh
# sourcing predates #660), and an opt-out that suppresses a call which doesn't exist yet proves
# nothing on its own. Strengthened to run the REAL collector end to end through report-status.sh
# and compare TWO scenarios: (A) CI_QUEUE_COLLECT_ENABLED=1 alone, metrics left unset — this must
# make a real `status=completed` call per tracked repo (scripts/ci-metrics.repos), proving the
# #660 feature exists and defaults ON; a full revert makes this call count 0, going red. (B) the
# SAME setup plus the host's own CI_QUEUE_METRICS_ENABLED=0 override — this must suppress it
# entirely, proving the opt-out actually works (not just that config.local.sh survives sourcing).
test_cqh_metrics_enabled_host_opt_out_via_config_local_sh() {
  local n_repos n_default n_opt_out
  n_repos=$(repos_file_count)

  n_default=$(_cqh_metrics_e2e_completed_calls 'CI_QUEUE_COLLECT_ENABLED=1')
  assert_eq "$n_default" "$n_repos" "metrics defaults ON (no override): one status=completed call per tracked repo (output: $n_default, expected $n_repos)" || return 1

  n_opt_out=$(_cqh_metrics_e2e_completed_calls "$(printf 'CI_QUEUE_COLLECT_ENABLED=1\nCI_QUEUE_METRICS_ENABLED=0\n')")
  assert_eq "$n_opt_out" "0" "a host's own config.local.sh setting CI_QUEUE_METRICS_ENABLED=0 opts out: zero status=completed calls (output: $n_opt_out)" || return 1
}

test_cqh_report_status_never_shells_to_gh_end_to_end() {
  local pipe home bindir marker rc gh_ran
  pipe=$(new_pipe); home=$(new_home)
  # STATUS_PUSH_URL/TOKEN must be set too: report-status.sh's AC6 gate (unset -> silent exit 0)
  # fires BEFORE the CI queue collector block and would otherwise make this test pass vacuously
  # whether or not the collector gate itself is fixed.
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
CI_QUEUE_COLLECT_ENABLED=1
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-value"
EOF
  bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-gh-invoked.XXXXXX")
  cqh_write_fake_gh "$bindir" "$marker"

  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" \
    CI_QUEUE_COLLECT_ENABLED=0 CI_QUEUE_COLLECT_TEST_DISABLE=1 \
    PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
    "$RS_CQH/report-status.sh" event ) >/dev/null 2>&1
  rc=$?

  cqh_poll_marker "$marker" 5
  gh_ran=absent; [ -e "$marker" ] && gh_ran=present
  rm -rf "$pipe" "$home" "$bindir"; rm -f "$marker"

  assert_exit0 "$rc" "report-status.sh still exits 0 with the collector gated off" || return 1
  assert_eq "$gh_ran" "absent" "a config.local.sh that turns the collector on is overridden by CI_QUEUE_COLLECT_TEST_DISABLE — gh never invoked" || return 1
}

run_test test_cqh_config_local_cannot_re_enable_the_collector_under_test_disable
run_test test_cqh_config_local_still_wins_without_test_disable
run_test test_cqh_metrics_enabled_defaults_to_1_via_config_sh
run_test test_cqh_metrics_enabled_host_opt_out_via_config_local_sh
run_test test_cqh_report_status_never_shells_to_gh_end_to_end
