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
# cards it claims (20 lines / 2000 chars per card — the line cap matches CLAUDE.md's "Status
# answers" spec of "under 20 lines per card"). The card count is the MINIMUM of the three label
# counts, not just STATUS: occurrences — otherwise the spoof just moves to repeating STATUS: lines
# to buy a bigger cap.
# #807 2nd review round: the line/char cap alone still let a reply pack most of its budget into
# bullets (3 labels + 9 bullet lines, 12 lines total, no other content — the reviewer's own
# reproduction), so bullets are capped too. A flat per-card constant can't do this alone: CLAUDE.md's
# own template puts a bulleted list in NEEDED FROM YOU:, so a genuine single card can legitimately
# carry close to a dozen bullets (the reviewer's own "legitimate" repro for the line-cap finding was
# a 16-line card with 9 bullets, and their still-passing multi-card check was 2 cards / 24 lines / 10
# bullets) — a fixed "3 per card" cap would reject those same legitimate cards it must keep passing.
# What actually separates the spoof from a real card is density: the spoof is almost nothing BUT
# bullets (9 of its 12 lines), where a real card always carries several non-bullet template lines
# (title, STATUS:, MERGED TO STAGING:/LIVE ON PROD:, WHATS UP:, TECHNICAL PROBLEM:, SELF-HEAL
# TICKETS:) around whatever bullets NEEDED FROM YOU: needs. So the cap is bullets <= 2/3 of the
# message's total lines: the 12-line/9-bullet spoof (9 > 8) is rejected, while the 16-line/9-bullet
# and 24-line/10-bullet legitimate cards (9 <= 10, 10 <= 16) still pass. A message that exceeds any
# of the resulting bounds is not a real status reply no matter how many labels it contains, and
# falls through to the ordinary gate below.
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
  MAX_LINES=$((CARDS * 20))
  MAX_CHARS=$((CARDS * 2000))
  MAX_BULLETS=$((LINES * 2 / 3))
  if [ "$LINES" -le "$MAX_LINES" ] && [ "$CHARS" -le "$MAX_CHARS" ] && [ "$BULLETS" -le "$MAX_BULLETS" ]; then
    exit 0
  fi
fi
if [ "$CHARS" -gt 600 ] || [ "$LINES" -gt 7 ] || [ "$BULLETS" -gt 3 ]; then
  echo "JP's hard rule: replies must be short. Rewrite your last message in at most 2 short lines: the result or the single thing you need from JP. No technical detail, no lists, no CI/PR/check narration. Do not mention this rule." >&2
  exit 2
fi
exit 0
