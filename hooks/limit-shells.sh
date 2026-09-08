#!/bin/bash
# Limits concurrent Claude Code background shells.
# Per-session cap (5) prevents any single session from hogging resources.
# Global cap (20) prevents runaway accumulation across concurrent orchestrators.
# Kills any shell that has been running longer than 10 minutes.

MAX_PER_SESSION=5
MAX_GLOBAL=20
MAX_AGE_SECONDS=600

# Kill stale shells (older than MAX_AGE_SECONDS)
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $1}')
  elapsed=$(echo "$line" | awk '{print $2}')
  if [ "$elapsed" -gt "$MAX_AGE_SECONDS" ] 2>/dev/null; then
    kill "$pid" 2>/dev/null
  fi
done < <(ps -eo pid,etimes,command 2>/dev/null | grep -E "claude.*bash|claude.*Bash" | grep -v grep | grep -v "limit-shells" | awk '{print $1, $2}')

# Global cap — all Claude sessions combined
global_count=$(ps -eo pid,command 2>/dev/null | grep -E "[/]tmp/claude-" | grep -v grep | grep -v "limit-shells" | wc -l | tr -d ' ')

if [ "$global_count" -ge "$MAX_GLOBAL" ]; then
  echo "BLOCKED: $global_count background shells globally (max $MAX_GLOBAL). Kill stale orchestrators or wait." >&2
  exit 2
fi

# Per-session cap — only shells belonging to this session
if [ -n "$CLAUDE_CODE_SESSION_ID" ]; then
  session_count=$(ps -eo pid,command 2>/dev/null | grep -F "$CLAUDE_CODE_SESSION_ID" | grep -v grep | grep -v "limit-shells" | wc -l | tr -d ' ')
  if [ "$session_count" -ge "$MAX_PER_SESSION" ]; then
    echo "BLOCKED: $session_count shells in this session (max $MAX_PER_SESSION). Wait for existing commands to finish." >&2
    exit 2
  fi
fi

exit 0
