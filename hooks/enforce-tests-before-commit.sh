#!/bin/bash
# Blocks git commit if the project has a test script and tests fail.
# Reads PreToolUse JSON from stdin, checks if the Bash command is a git commit,
# finds the nearest package.json with a "test" script, and runs it.

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

# Skip during pipeline test-writer stage (tests are intentionally red)
if [ -n "$PIPELINE_LOCKED_TESTS_FILE" ]; then
  exit 0
fi

# Skip commits whose message signals intentionally-red tests (test-writer TDD commits)
if echo "$CMD" | grep -qE 'test\(#[0-9]+\):'; then
  exit 0
fi

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

# Walk up to find package.json with a test script
FOUND=""
CHECK="$DIR"
while [ "$CHECK" != "/" ]; do
  if [ -f "$CHECK/package.json" ]; then
    HAS_TEST=$(python3 -c "
import json, sys
try:
    pkg = json.load(open('$CHECK/package.json'))
    scripts = pkg.get('scripts', {})
    test_cmd = scripts.get('test', '')
    if test_cmd and 'no test specified' not in test_cmd:
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null)
    if [ "$HAS_TEST" = "yes" ]; then
      FOUND="$CHECK"
      break
    fi
  fi
  CHECK=$(dirname "$CHECK")
done

# No test script found — allow the commit
if [ -z "$FOUND" ]; then
  exit 0
fi

# Run tests
TEST_OUTPUT=$(cd "$FOUND" && npm test 2>&1)
TEST_EXIT=$?

if [ $TEST_EXIT -ne 0 ]; then
  echo "BLOCKED: Tests failed. Fix failing tests before committing." >&2
  echo "" >&2
  # Show last 20 lines of test output for context
  echo "$TEST_OUTPUT" | tail -20 >&2
  exit 2
fi

exit 0
