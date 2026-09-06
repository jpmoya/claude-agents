#!/bin/bash
# Stop / SubagentStop hook for pipeline stage runs. Active only when the orchestrator launched the
# stage with PIPELINE_ISSUE / PIPELINE_AGENT / PIPELINE_REPO set. Refuses to let the stage finish until
# the issue carries a NEW routing marker from this agent (count > the before-count the orchestrator wrote).
# Bounded: after 2 refusals it lets the run stop so a truly stuck agent can't loop forever.
[ -n "${PIPELINE_ISSUE:-}" ] && [ -n "${PIPELINE_AGENT:-}" ] && [ -n "${PIPELINE_REPO:-}" ] || exit 0
INPUT=$(cat)
PIPE=/tmp/pipeline
BEFORE_FILE="$PIPE/$PIPELINE_ISSUE-$PIPELINE_AGENT-before.txt"
NAG_FILE="$PIPE/$PIPELINE_ISSUE-$PIPELINE_AGENT-nags.txt"
[ -f "$BEFORE_FILE" ] || exit 0
BEFORE=$(cat "$BEFORE_FILE")
NOW=$(gh issue view "$PIPELINE_ISSUE" --repo "$PIPELINE_REPO" --json comments \
  --jq '[.comments[] | select(.body | test("^\\*\\*\\['"$PIPELINE_AGENT"'\\] ") and (test("^\\*\\*\\['"$PIPELINE_AGENT"'\\] NOTE") | not))] | length' 2>/dev/null) || exit 0
if [ "${NOW:-0}" -gt "$BEFORE" ]; then rm -f "$NAG_FILE"; exit 0; fi
NAGS=$(cat "$NAG_FILE" 2>/dev/null || echo 0)
if [ "$NAGS" -ge 2 ]; then exit 0; fi
echo $((NAGS+1)) > "$NAG_FILE"
echo "BLOCKED: you have not posted your handoff comment on $PIPELINE_REPO#$PIPELINE_ISSUE. The orchestrator routes only on a first-line \`**[$PIPELINE_AGENT] MARKER**\` and your work is invisible without it. Post it now via gh issue comment (a routing marker, not NOTE; BLOCKED with the exact reason if you could not finish), then stop." >&2
exit 2
