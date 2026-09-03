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

# Find the working directory — use the cwd from the hook environment
DIR="$PWD"

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
