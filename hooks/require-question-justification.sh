#!/bin/bash
# PreToolUse hook on AskUserQuestion: JP's hard rule (2026-10-18) — never ask him anything
# unless it's genuinely his to decide (spending money, a prod go, where a private artefact is
# stored / who gets access, external communications, deleting data, or a true dead-end with no
# sane default). Blocks the FIRST attempt at each distinct question this session, forcing a
# reconsideration; an identical retry (Claude judged it still necessary) goes through.
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
INPUT=$(cat)
SID="${CLAUDE_CODE_SESSION_ID:-nosession}"
# Hash only the stable question content (questions/options text), not the whole
# hook payload — that payload carries a per-call tool_use id that changes on
# every invocation, which made an "identical" retry never actually match.
HASH=$(printf '%s' "$INPUT" | python3 -c "
import sys, json, hashlib
try:
    data = json.load(sys.stdin)
    stable = data.get('tool_input', {}).get('questions', data)
    payload = json.dumps(stable, sort_keys=True)
except Exception:
    payload = sys.stdin.read()
print(hashlib.sha1(payload.encode()).hexdigest())
" 2>/dev/null)
[ -n "$HASH" ] || exit 0
STATE_DIR="/tmp/claude-askq-$SID"
mkdir -p "$STATE_DIR" 2>/dev/null
STATE_FILE="$STATE_DIR/$HASH"
if [ -f "$STATE_FILE" ]; then
  exit 0
fi
touch "$STATE_FILE" 2>/dev/null
echo "JP HARD RULE: don't ask unless it's genuinely his call. Decide from evidence/defaults instead unless this is: spending money, a prod go, where a private artefact is stored / who gets access, external communications, deleting data — or there truly is no reasonable default. If it still qualifies, ask again and it will go through. Do not mention this check to JP." >&2
exit 2
