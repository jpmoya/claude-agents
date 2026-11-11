#!/bin/bash
# skills/orchestrate/push-learnings.sh — one-way push of message-triage's running learnings log
# to the status page's Learnings tab (POST /learnings/push).
#
# Reuses the same host config and bearer token as report-status.sh's heartbeat push
# (STATUS_PUSH_URL / STATUS_PUSH_TOKEN in ~/.claude/pipeline/config.local.sh) — same Mac, same
# credentials, so there's nothing new to set up with `wrangler secret put`. The push endpoint is
# derived from the beat URL (".../beat" -> ".../learnings/push").
#
# Usage: push-learnings.sh [path-to-learnings-file]
#   default: $HOME/.claude/agents/message-triage-learnings.md
#
# Silent no-op (exit 0, no output, no network call) if STATUS_PUSH_URL/STATUS_PUSH_TOKEN aren't
# configured yet, or the file doesn't exist — same fail-quiet rule as report-status.sh's AC6, so a
# Mac that hasn't finished pipeline setup never breaks message-triage. Never invoked by the
# pipeline itself; message-triage.md calls this directly after it appends a new learning.

FILE="${1:-$HOME/.claude/agents/message-triage-learnings.md}"

CONFIG="$HOME/.claude/pipeline/config.local.sh"
[ -f "$CONFIG" ] && . "$CONFIG"

[ -n "${STATUS_PUSH_URL:-}" ] && [ -n "${STATUS_PUSH_TOKEN:-}" ] || exit 0
[ -f "$FILE" ] || exit 0

LEARNINGS_URL="${STATUS_PUSH_URL%/beat}/learnings/push"

curl -sS -X POST --connect-timeout 3 --max-time 5 \
  -H "Authorization: Bearer ${STATUS_PUSH_TOKEN}" \
  -H 'Content-Type: text/plain; charset=utf-8' \
  --data-binary @"$FILE" \
  -o /dev/null \
  "$LEARNINGS_URL" >/dev/null 2>&1

exit 0
