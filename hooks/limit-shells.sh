#!/bin/bash
# Limits concurrent Claude Code background shells to 5.
# Kills any shell that has been running longer than 10 minutes.

MAX_SHELLS=5
MAX_AGE_SECONDS=600

# Kill stale shells (older than MAX_AGE_SECONDS)
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $1}')
  elapsed=$(echo "$line" | awk '{print $2}')
  if [ "$elapsed" -gt "$MAX_AGE_SECONDS" ] 2>/dev/null; then
    kill "$pid" 2>/dev/null
  fi
done < <(ps -eo pid,etimes,command 2>/dev/null | grep -E "claude.*bash|claude.*Bash" | grep -v grep | grep -v "limit-shells" | awk '{print $1, $2}')

# Count currently running shells spawned by Claude
count=$(ps -eo pid,command 2>/dev/null | grep -E "[/]tmp/claude-" | grep -v grep | grep -v "limit-shells" | wc -l | tr -d ' ')

if [ "$count" -ge "$MAX_SHELLS" ]; then
  echo "BLOCKED: $count background shells already running (max $MAX_SHELLS). Wait for existing commands to finish or kill stale ones." >&2
  exit 2
fi

exit 0
