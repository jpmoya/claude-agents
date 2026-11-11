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
run_test test_cqh_report_status_never_shells_to_gh_end_to_end
