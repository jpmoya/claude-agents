#!/bin/bash
# UserPromptSubmit hook (JP, 2026-11-18): every time JP says he wants a ticket logged, a bug filed, or something done through
# the pipeline, the session must run the ticket-intake skill BEFORE anything else, so no ticket JP asked for is left without
# a project and the agent-go label. This hook only DETECTS the intent and injects the hard instruction (additionalContext,
# exit 0 — it never blocks a prompt); skills/ticket-intake/SKILL.md does the work and hooks/ticket-intake-guard.sh (PreToolUse)
# refuses a bare `gh issue create` on the application repos.
# Patterns live in ONE file: hooks/ticket-intent-patterns.txt (override with TICKET_INTENT_PATTERNS for tests).
# Interactive sessions only: pipeline stages (PIPELINE_AGENT) write briefs that say "file a ticket" all day.
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INPUT=$(cat)
printf '%s' "$INPUT" | python3 -I -c '
import json, re, sys
pat_file = sys.argv[1]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
msg = ""
for k in ("prompt", "user_prompt", "message"):   # Claude Code documents "prompt"; the older hooks here read the other two
    if isinstance(data.get(k), str) and data[k]:
        msg = data[k]; break
if not msg:
    sys.exit(0)
NOUN = r"(?:(?:new|separate|github|gh|jira|bug|feature|follow-?up|backlog)\s+)*(?:tickets?|issues?|stor(?:y|ies)|tasks?|cards?|bugs?|bug\s+reports?)"
END = r"(?=\s*(?:$|[.,:;!?\-–—)]|\n)|\s+(?:for|to|about|on|in|so|that|with|called|titled|from|covering|saying|of|because|please|and|but|then|as)\b)"
try:
    lines = open(pat_file, encoding="utf-8").read().splitlines()
except OSError:
    sys.exit(0)
for ln in lines:
    ln = ln.strip()
    if not ln or ln.startswith("#"):
        continue
    rx = ln.replace("{NOUN}", NOUN).replace("{END}", END)
    try:
        hit = re.search(rx, msg, re.I | re.M)
    except re.error:
        continue
    if hit:
        ctx = ("TICKET REQUEST DETECTED (JP hard rule, 2026-11-18). REQUIRED, before anything else (no investigating, no coding, no gh issue create): "
               "invoke the ticket-intake skill (~/.claude/skills/ticket-intake/SKILL.md). It runs the duplicate check, has product-manager file the ticket "
               "with the Reported by / Intake lines, asks JP ONE short question (which goal project, or none), then puts the ticket in that project "
               "and adds agent-go with ~/.claude/skills/ticket-intake/ticket-intake.sh. A ticket in an application repo created without it is refused by hooks/ticket-intake-guard.sh. "
               "If the message is not actually a request to log a ticket, say so in one line and carry on. The jpmoya/claude-agents repo is exempt (direct route: no project, no agent-go).")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}))
        break
' "${TICKET_INTENT_PATTERNS:-$HERE/ticket-intent-patterns.txt}"
exit 0
