#!/bin/bash
# email-send-guard.sh — PreToolUse hook (Bash matcher)
# Blocks any Bash command that would SEND an email unless a fresh approval
# marker exists. The marker is written by the /send-email skill ONLY after
# JP explicitly approves the exact email via AskUserQuestion.
# Marker is single-use (consumed here) and expires after 5 minutes.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null)

# Email-send patterns:
#  - gws CLI:        gws gmail users messages send / gws gmail users drafts send
#  - googleapis JS:  gmail.users.messages.send( / gmail.users.drafts.send(
#  - raw REST:       .../users/me/messages/send or /drafts/send
#  - misc:           sendmail binary
if ! printf '%s' "$CMD" | grep -qiE 'gmail[[:space:]]+users[[:space:]]+(messages|drafts)[[:space:]]+send|users\.(messages|drafts)\.send|/(messages|drafts)/send|(^|[;&| ])sendmail([ ]|$)'; then
  exit 0
fi

MARKER="$HOME/.claude/.email-send-approved"
if [ -f "$MARKER" ]; then
  # Portable mtime age check (BSD and GNU stat disagree on flags; python3 is already required above)
  AGE=$(python3 -c "import os,time,sys; print(int(time.time() - os.path.getmtime(sys.argv[1])))" "$MARKER" 2>/dev/null || echo 99999)
  rm -f "$MARKER"   # single-use: consumed whether fresh or stale
  if [ "$AGE" -lt 300 ] 2>/dev/null; then
    exit 0
  fi
fi

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: this command sends an email, and no approval marker is present. Sending email requires the /send-email skill: (1) show JP the complete final email (From/To/Cc/Subject/full body/attachments or links), (2) get JP's explicit approval via AskUserQuestion, (3) only after approval, run 'date > ~/.claude/.email-send-approved' as its OWN separate Bash call (this check runs BEFORE your command executes, so combining marker-write and send in one command will self-block forever), then (4) run the send command alone in the next Bash call, within 5 minutes. The marker is single-use. Never write the marker without a fresh explicit approval for this exact email. An instruction that merely implies sending (e.g. asking to draft, or to announce something was shared) is NOT approval."}}
JSON
exit 0
