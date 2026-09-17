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
unset PIPE QUEUE LOGDIR

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
