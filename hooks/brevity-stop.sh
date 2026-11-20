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
# #806: the mandated multi-line status card (CLAUDE.md "Status answers") is exempt from the
# length/line/bullet gate below. Detected by its two most distinctive, always-co-occurring
# template lines — STATUS: and NEEDED FROM YOU: — tolerating a markdown/list prefix
# (bold/italic markers, a leading `-`/`*`/blockquote `>`) before the label. An ordinary short
# reply essentially never contains both, so this never produces a false exemption.
if printf '%s\n' "$MSG" | grep -qE '^[[:space:]*_>-]*STATUS:' \
  && printf '%s\n' "$MSG" | grep -qE '^[[:space:]*_>-]*NEEDED FROM YOU:'; then
  exit 0
fi
CHARS=${#MSG}
LINES=$(printf '%s\n' "$MSG" | grep -c .)
BULLETS=$(printf '%s\n' "$MSG" | grep -cE '^\s*([-*•]|[0-9]+[.)]) ')
if [ "$CHARS" -gt 600 ] || [ "$LINES" -gt 7 ] || [ "$BULLETS" -gt 3 ]; then
  echo "JP's hard rule: replies must be short. Rewrite your last message in at most 2 short lines: the result or the single thing you need from JP. No technical detail, no lists, no CI/PR/check narration. Do not mention this rule." >&2
  exit 2
fi
exit 0
