#!/bin/bash
# Issue #203 — adjudicator DO NOW is scoped to the incident; a struck claim records only "did not reproduce".
# Standalone grep checks over the agent/instruction files.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ADJ="$ROOT/agents/pipeline-adjudicator.md"; CMD="$ROOT/CLAUDE.md"
fail=0
check() { # desc file line-regex pattern
  local line; line=$(grep -n -E "$3" "$2" | head -1 | cut -d: -f2-)
  if [ -n "$line" ] && printf '%s' "$line" | grep -q -F "$4"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
check "adjudicator DO NOW template line is scoped"   "$ADJ" '^DO NOW  '                 "named in the incident"
check "adjudicator 'executes every DO NOW' scoped"   "$ADJ" 'executes every `DO NOW`'   "named in the incident"
check "CLAUDE.md DO NOW paragraph scoped"            "$CMD" '^\*\*Pipeline incidents'   "named in the incident"
check "cite-or-drop: struck = did not reproduce"     "$ADJ" '^1\. \*\*Cite-or-drop'     "did not reproduce"
check "cite-or-drop: no replacement fact"            "$ADJ" '^1\. \*\*Cite-or-drop'     "replacement fact"
exit $fail
