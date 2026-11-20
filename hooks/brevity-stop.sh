#!/bin/bash
# Stop hook: JP's hard rule (2026-10-17) — replies are short, so-what first, no technical narration.
# Blocks (once) a final message that is too long so Claude rewrites it. Interactive sessions only.
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
IN=$(cat)
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
T=$(printf '%s' "$IN" | jq -r '.transcript_path // empty')
[ -f "$T" ] || exit 0
MSG=$(jq -rs '[.[]|select(.type=="assistant")]|last|.message.content|map(select(.type=="text")|.text)|join("\n")' "$T" 2>/dev/null)
[ -n "$MSG" ] || exit 0
# #806/#807: the mandated multi-line status card (CLAUDE.md "Status answers") is exempt from the
# length/line/bullet gate below. Detected by three of its distinctive, always-co-occurring
# template lines — STATUS:, NEEDED FROM YOU:, and TECHNICAL PROBLEM: — tolerating a
# markdown/list prefix (bold/italic markers, a leading `-`/`*`/blockquote `>`) before the label.
# #807 code review: two labels alone were spoofable (a long narration reply with just those two
# lines prepended got exempted with no cap at all), so a third required label is not enough on its
# own either — even when exempted, the message is capped to a multi-card bound scaled by how many
# cards it claims (~12 lines / ~1200 chars per card, roomy enough for a real card's bulleted
# NEEDED FROM YOU: and multi-line SELF-HEAL TICKETS:). The card count is the MINIMUM of the three
# label counts, not just STATUS: occurrences — otherwise the spoof just moves to repeating STATUS:
# lines to buy a bigger cap. A message that exceeds the resulting bound is not a real status reply
# no matter how many labels it contains, and falls through to the ordinary gate below.
CHARS=${#MSG}
LINES=$(printf '%s\n' "$MSG" | grep -c .)
BULLETS=$(printf '%s\n' "$MSG" | grep -cE '^\s*([-*•]|[0-9]+[.)]) ')
STATUS_RE='^[[:space:]*_>-]*STATUS:'
NEEDED_RE='^[[:space:]*_>-]*NEEDED FROM YOU:'
TECH_RE='^[[:space:]*_>-]*TECHNICAL PROBLEM:'
if printf '%s\n' "$MSG" | grep -qE "$STATUS_RE" \
  && printf '%s\n' "$MSG" | grep -qE "$NEEDED_RE" \
  && printf '%s\n' "$MSG" | grep -qE "$TECH_RE"; then
  N_STATUS=$(printf '%s\n' "$MSG" | grep -cE "$STATUS_RE")
  N_NEEDED=$(printf '%s\n' "$MSG" | grep -cE "$NEEDED_RE")
  N_TECH=$(printf '%s\n' "$MSG" | grep -cE "$TECH_RE")
  CARDS=$N_STATUS
  [ "$N_NEEDED" -lt "$CARDS" ] && CARDS=$N_NEEDED
  [ "$N_TECH" -lt "$CARDS" ] && CARDS=$N_TECH
  [ "$CARDS" -ge 1 ] || CARDS=1
  MAX_LINES=$((CARDS * 12))
  MAX_CHARS=$((CARDS * 1200))
  if [ "$LINES" -le "$MAX_LINES" ] && [ "$CHARS" -le "$MAX_CHARS" ]; then
    exit 0
  fi
fi
if [ "$CHARS" -gt 600 ] || [ "$LINES" -gt 7 ] || [ "$BULLETS" -gt 3 ]; then
  echo "JP's hard rule: replies must be short. Rewrite your last message in at most 2 short lines: the result or the single thing you need from JP. No technical detail, no lists, no CI/PR/check narration. Do not mention this rule." >&2
  exit 2
fi
exit 0
