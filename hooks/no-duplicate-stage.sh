#!/bin/bash
# PreToolUse hook on Bash (orchestrator sessions): never start a second copy of the same
# pipeline stage for the same ticket while one is still running on this host.
# 2026-09-22: restarted orchestrators re-dispatched reviewers/developers 2–5× on #261/#703/#793,
# thrashing the VM. Exempt: the orchestrator itself, and commands that do not launch a stage.
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null)
case "$CMD" in *"--agent "*) ;; *) exit 0 ;; esac
STAGE=$(printf '%s' "$CMD" | grep -oE -- '--agent [a-z-]+' | head -1 | awk '{print $2}')
[ -z "$STAGE" ] || [ "$STAGE" = "orchestrator" ] && exit 0
ISSUE=$(printf '%s' "$CMD" | grep -oE 'PIPELINE_ISSUE=[0-9]+' | head -1 | cut -d= -f2)
[ -z "$ISSUE" ] && ISSUE=$(printf '%s' "$CMD" | grep -oE '(issue |#)[0-9]+' | head -1 | grep -oE '[0-9]+')
[ -z "$ISSUE" ] && exit 0
if ps -eo args 2>/dev/null | grep -E "claude .*--agent $STAGE -p " | grep -vE "grep" | grep -qE "(#|issue )$ISSUE([^0-9]|$)"; then
  echo "BLOCKED: a $STAGE for #$ISSUE is already running on this host — poll it (tail its log / wait for its marker) instead of starting another." >&2
  exit 2
fi
exit 0
