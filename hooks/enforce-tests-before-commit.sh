#!/bin/bash
# Never blocks git commit on a test failure. Reads PreToolUse JSON from stdin, checks if the
# Bash command is a git commit, finds the nearest package.json with a "test" script, and runs
# the SMALLEST trustworthy set of tests for the change so agents get a fast local signal.
#
# Selection (in order):
#   1. Vitest project, safe `scripts.test`, merge-base with the target branch resolvable, and no
#      config/shared-fixture files touched -> `vitest run --changed <merge-base> --passWithNoTests`.
#   2. Anything that makes scoping untrustworthy (no vitest, compound/unsafe test script, no
#      merge-base, or a config/fixture file in the diff) -> fall back to `npm test` (today's
#      full-suite behavior), for SELECTION only.
# Either way: the result (pass/fail/skip + which mode ran) is logged to the pipeline run log and
# to stderr. The commit is NEVER blocked on a red or skipped test — only on this hook's own
# inability to invoke a test runner at all (missing node_modules/npm, JSON parse failure).
#
# CI's full-suite job on the PR/promotion is untouched by this change; it remains the only thing
# that blocks a merge.

INPUT=$(cat)
CMD=$(echo "$INPUT" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('tool_input', {}).get('command', ''))" 2>/dev/null)

# Only intercept git commit commands (not amend-only, not git commit --allow-empty for merges)
if ! echo "$CMD" | grep -qE 'git\s+commit\s'; then
  exit 0
fi

# Skip if the commit command itself is just an amend with no changes
if echo "$CMD" | grep -qE -- '--allow-empty'; then
  exit 0
fi

# Skip during pipeline test-writer stage (tests are intentionally red) — no logging either,
# per AC: both bypasses skip the hook entirely.
if [ -n "$PIPELINE_LOCKED_TESTS_FILE" ]; then
  exit 0
fi

# Skip commits whose message signals intentionally-red tests (test-writer TDD commits)
if echo "$CMD" | grep -qE 'test\(#[0-9]+\):'; then
  exit 0
fi

LOGDIR="${LOGDIR:-$HOME/logs/pipeline}"
LOGFILE="$LOGDIR/enforce-tests-before-commit.log"

log_line() {
  # $1 = one-line summary. Never let logging failure affect the hook's exit code.
  echo "$1" >&2
  { mkdir -p "$LOGDIR" && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >>"$LOGFILE"; } 2>/dev/null || true
}

# Determine the effective directory: if the command starts with "cd <path> &&",
# use that path; otherwise fall back to $PWD
DIR="$PWD"
CD_TARGET=$(echo "$CMD" | python3 -c "
import sys, re
cmd = sys.stdin.read().strip()
m = re.match(r'cd\s+([\"'\'']*([^\"'\'';&|]+?)[\"'\'']*)\s*&&', cmd)
if m:
    import os
    print(os.path.expanduser(m.group(2).strip()))
else:
    print('')
" 2>/dev/null)
if [ -n "$CD_TARGET" ] && [ -d "$CD_TARGET" ]; then
  DIR="$CD_TARGET"
fi

# Walk up to find package.json with a test script; also report whether the test script itself
# is a single-command invocation of vitest (safe to pass --changed/--passWithNoTests to) versus
# something compound (&&, ;, ||) that isn't safe to append flags to.
FOUND=""
TEST_SCRIPT=""
VITEST_SAFE=""
CHECK="$DIR"
while [ "$CHECK" != "/" ]; do
  if [ -f "$CHECK/package.json" ]; then
    read -r HAS_TEST TEST_SCRIPT_LINE VITEST_SAFE_LINE <<PYEOF_MARKER
$(python3 -c "
import json, sys
try:
    pkg = json.load(open('$CHECK/package.json'))
    scripts = pkg.get('scripts', {})
    test_cmd = (scripts.get('test', '') or '').strip()
    has = 'yes' if (test_cmd and 'no test specified' not in test_cmd) else 'no'
    import re
    compound = bool(re.search(r'&&|;|\|\|', test_cmd))
    is_vitest = bool(re.match(r'^(npx\s+)?vitest(\s|\$)', test_cmd)) or 'vitest' in test_cmd.split(' ')[0]
    safe = 'yes' if (has == 'yes' and is_vitest and not compound) else 'no'
    print(has, (test_cmd.replace(' ', '\x1f') or '-'), safe)
except Exception:
    print('no - no')
" 2>/dev/null)
PYEOF_MARKER
    TEST_SCRIPT=$(echo "$TEST_SCRIPT_LINE" | tr '\x1f' ' ')
    if [ "$HAS_TEST" = "yes" ]; then
      FOUND="$CHECK"
      VITEST_SAFE="$VITEST_SAFE_LINE"
      break
    fi
  fi
  CHECK=$(dirname "$CHECK")
done

# No test script found — allow the commit
if [ -z "$FOUND" ]; then
  exit 0
fi

REPO_ROOT=$(git -C "$FOUND" rev-parse --show-toplevel 2>/dev/null)
MODE="full"
FALLBACK_REASON=""
MERGE_BASE=""

if [ "$VITEST_SAFE" = "yes" ] && [ -n "$REPO_ROOT" ]; then
  # Resolve the target/integration branch from local refs only — no network call in a
  # pre-commit hook. Prefer staging (scheduler/quoting-tool convention), else main.
  TARGET_REF=""
  if git -C "$REPO_ROOT" rev-parse --verify -q origin/staging >/dev/null; then
    TARGET_REF="origin/staging"
  elif git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null; then
    TARGET_REF="origin/main"
  fi

  if [ -n "$TARGET_REF" ]; then
    MERGE_BASE=$(git -C "$REPO_ROOT" merge-base HEAD "$TARGET_REF" 2>/dev/null)
  fi

  if [ -z "$MERGE_BASE" ]; then
    FALLBACK_REASON="no-merge-base"
  else
    # Conservative fallback: a config/shared-fixture file changed since the merge-base, so a
    # changed-file diff isn't trustworthy for impact — run everything but keep it non-blocking.
    CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only "$MERGE_BASE" 2>/dev/null)
    if echo "$CHANGED_FILES" | grep -qE '(^|/)(vitest\.config\.|vite\.config\.|tsconfig.*\.json$|package(-lock)?\.json$|package\.json$)|(^|/)(test-)?setup\.[jt]sx?$|(^|/)fixtures?/'; then
      FALLBACK_REASON="config-or-fixture-change"
    else
      MODE="scoped"
    fi
  fi
else
  if [ -z "$REPO_ROOT" ]; then
    FALLBACK_REASON="not-a-git-repo"
  else
    FALLBACK_REASON="no-scoped-runner"
  fi
fi

VITEST_BIN="$FOUND/node_modules/.bin/vitest"

if [ "$MODE" = "scoped" ] && [ -x "$VITEST_BIN" ]; then
  TEST_OUTPUT=$(cd "$FOUND" && "$VITEST_BIN" run --changed "$MERGE_BASE" --passWithNoTests 2>&1)
  TEST_EXIT=$?
  SELECTION_DESC="scoped(vitest --changed ${MERGE_BASE:0:12})"
elif [ "$MODE" = "scoped" ]; then
  # vitest binary missing despite scripts.test naming it — can't trust scoping, fall back.
  FALLBACK_REASON="vitest-binary-missing"
  MODE="full"
fi

if [ "$MODE" = "full" ]; then
  TEST_OUTPUT=$(cd "$FOUND" && npm test 2>&1)
  TEST_EXIT=$?
  if [ -n "$FALLBACK_REASON" ]; then
    SELECTION_DESC="full(fallback: $FALLBACK_REASON)"
  else
    SELECTION_DESC="full(no scoped runner)"
  fi
fi

OUTCOME="pass"
[ "$TEST_EXIT" -ne 0 ] && OUTCOME="fail"

log_line "enforce-tests-before-commit: dir=$FOUND selection=$SELECTION_DESC outcome=$OUTCOME (non-blocking; CI is the merge gate)"
if [ "$OUTCOME" = "fail" ]; then
  echo "$TEST_OUTPUT" | tail -20 >&2
fi

# Never exit non-zero for a test outcome, scoped or fallback-full. This hook may only fail on
# its own operational errors (e.g. it could not run any test command at all) — there is none
# left in this path, since both selection branches above always attempt a run.
exit 0
