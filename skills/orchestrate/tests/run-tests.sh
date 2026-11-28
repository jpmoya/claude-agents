#!/bin/bash
# Plain-bash test runner for skills/orchestrate — no bats (nothing else in this repo has one, and
# this must run on macOS bash 3.2 per AC11). Every test-*.sh file under this directory is sourced
# in turn; each builds its own mktemp -d fixtures via lib/fixture.sh and registers its cases with
# run_test (lib/assert.sh).
#
# Usage: skills/orchestrate/tests/run-tests.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Refuse to run against the host's real pipeline state. A test that forgot to call new_pipe and
# instead touched /tmp/pipeline could write fake orch-*.pid files a real supervisor cron would
# then act on. This is a hard stop, not a test.
if [ "${PIPE:-}" = "/tmp/pipeline" ]; then
  echo "refusing to run: PIPE=/tmp/pipeline (the host's real pipeline state) — unset PIPE and re-run" >&2
  exit 2
fi
# #341: config.sh's one-time legacy-state move (PIPE_LEGACY, default /tmp/pipeline) must never see the real dir.
if [ "${PIPE_LEGACY:-}" = "/tmp/pipeline" ]; then
  echo "refusing to run: PIPE_LEGACY=/tmp/pipeline (the host's real pipeline state) — unset PIPE_LEGACY and re-run" >&2
  exit 2
fi
unset PIPE QUEUE LOGDIR GH_CLASS   # GH_CLASS leaks in from pipeline-agent shells (gh-budget.sh tiers calls by it) and skews call-count/log pins
PIPE_LEGACY="$(mktemp -d "${TMPDIR:-/tmp}/orch-test-legacy.XXXXXX")/legacy"   # fresh path that does not exist
if [ "$PIPE_LEGACY" = "/tmp/pipeline" ]; then echo "refusing to run: PIPE_LEGACY resolves to /tmp/pipeline" >&2; exit 2; fi
export PIPE_LEGACY
export PIPELINE_TEST_CLAIM_SETTLE_SECS=0   # #217: hand launches wait the settle window; suites need not pay it (hand-launch test pins its own)
# Supervisor tests run supervisor.sh, whose code-sync gate refuses to launch when the checkout is off main / behind origin/main /
# dirty (any worktree or feature branch, or a stale local main). That is host state, not what these suites test: switch it off here.
# test-code-sync.sh drives code-sync.sh directly and sets its own state.
export CODE_SYNC_ENABLED=0
export GH_BUDGET_ENABLED=0   # gh-budget.sh (call log, quota guard, read cache) is off for the suites; test-gh-budget.sh turns it on for itself
# #643: report-status.sh's opt-in background call to the host-side CI queue collector (real gh/GitHub
# Actions API calls) must never fire just because the suite ran report-status.sh — explicit, not just
# relying on the script's own default-off, in case a real ~/.claude/pipeline/config.local.sh enabled it.
# #645: CI_QUEUE_COLLECT_TEST_DISABLE is the structural guarantee — config.sh forces
# CI_QUEUE_COLLECT_ENABLED back to 0 AFTER sourcing config.local.sh whenever this is set, so a host
# config.local.sh that turns the collector on for real (its one intended purpose) can't win a race
# against this plain export.
export CI_QUEUE_COLLECT_ENABLED=0
export CI_QUEUE_COLLECT_TEST_DISABLE=1
# #769: scheduled-triggers.sh dispatches real GitHub workflows from the supervisor tick; no suite may fire it (test-scheduled-triggers.sh sets its own env).
export SCHEDULED_TRIGGERS_ENABLED=0
# #778: status-page-deploy.sh runs a real `wrangler deploy` from the supervisor tick; no suite may fire it (config.sh forces the flag to 0 whenever the
# marker is set, so a host config.local.sh that enables it for real cannot win). test-status-page-deploy.sh removes the marker for its own calls.
export STATUS_PAGE_DEPLOY_ENABLED=0
export STATUS_PAGE_DEPLOY_TEST_DISABLE=1
# #773: the webhook event queue (kill switch, default 0) must never be switched on by a host config.local.sh while the suites run
# (it would read the host's real queue and skip since-syncs); test-webhook-events.sh sets it per call.
export WEBHOOK_EVENTS_ENABLED=0
# gh-scope.sh reads the scopes gh-budget.sh saved; supervisor suites must not alert on a stub's headers. test-gh-scope.sh switches it on per call.
export GH_SCOPE_CHECK_ENABLED=0
# #837: the tick's `claude auth status` check and probe run must never reach the real CLI (or add calls to a suite's claude stub);
# test-agents-down.sh switches it on per call.
export AGENTS_DOWN_CHECK_ENABLED=0
# #756: report-status.sh reads the host user's real crontab (`crontab -l`) for the payload's optional `cron[]`;
# a suite must never publish (or depend on) whatever the machine running it happens to schedule. `true` is an empty crontab.
# test-status-cron.sh overrides this per call with its own fixtures.
export STATUS_CRON_CMD=true
# The same for the Mac-only launchd / Claude desktop task collectors (empty = off): no suite publishes JP's real jobs.
export STATUS_LAUNCHD_DIR=""
export STATUS_DESKTOP_TASKS_DIR=""
# verify-shipped gate (goal_eval's "not live on prod" check, real timeline reads + git fetches): off for the suites that fake a GitHub
# without those routes; test-goal-ship-gate.sh turns it on for itself via config.local.sh.
export GOAL_SHIP_GATE=0
# JP, 2026-11-18: deliver.sh refuses to register any goal that is not a GitHub Project. The older suites register milestone goals
# as fixtures, so the legacy override is on for them; test-goal-nomilestone.sh unsets it around every call it makes.
export GOAL_ALLOW_LEGACY_REGISTER=1

. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

for f in "$HERE"/test-*.sh; do
  [ -e "$f" ] || continue
  echo "== $(basename "$f") =="
  . "$f"
done

echo
echo "=================================================="
echo "TOTAL: $ASSERT_PASS passed, $ASSERT_FAIL failed"
[ -n "$ASSERT_FAIL_NAMES" ] && echo "Failing cases:$ASSERT_FAIL_NAMES"
[ "$ASSERT_FAIL" -eq 0 ]
