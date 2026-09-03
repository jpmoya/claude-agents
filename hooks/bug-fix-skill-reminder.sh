#!/bin/bash
# Fires on UserPromptSubmit. If the user's message contains bug-related
# keywords, injects a reminder to invoke fullstack-bug-fixing skill.

INPUT=$(cat)
MSG=$(echo "$INPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('user_prompt', data.get('message', '')).lower())
" 2>/dev/null || echo "")

if echo "$MSG" | grep -qEi '\b(bug|broken|not working|missing data|nulled|wiped|regression|data loss|data.{0,10}gone|fields.{0,10}empty|values.{0,10}gone|stopped working|came back|keeps happening|silent(ly)? fail|wrong (value|data|result)|zeros?ed out|all empty|disappeared|shows? (zero|null|nothing|blank|empty))\b'; then
  echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Bug-related message detected. REQUIRED: Invoke the fullstack-bug-fixing skill BEFORE investigating or writing any code. Follow its phases in order: Goal Gate → Reproduce → Root Cause → Test → Fix → Verify."}}'
fi
