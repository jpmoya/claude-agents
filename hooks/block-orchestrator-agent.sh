#!/bin/bash
# PreToolUse hook on Agent: the orchestrator must run headless (skills/orchestrate), never as a
# subagent of an interactive session — it dies when the session compacts or exits.
# The headless launcher sets PIPELINE_HEADLESS=1, which exempts the one Agent call it makes.
[ "${PIPELINE_HEADLESS:-}" = "1" ] && exit 0
INPUT=$(cat)
TYPE=$(echo "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('subagent_type', ''))" 2>/dev/null)
if [ "$TYPE" = "orchestrator" ]; then
  echo "BLOCKED: never dispatch the orchestrator as a subagent — it dies with this session. Use the orchestrate skill: ~/.claude/skills/orchestrate/orchestrate.sh <repo-path> <issue>" >&2
  exit 2
fi
exit 0
