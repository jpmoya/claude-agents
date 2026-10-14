# Issue #209 fix cycle — the developer's merge_conflict BLOCKED has a dispatch row before the terminal `any BLOCKED` row.

HERE_209B=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_209B="$HERE_209B/../../../agents/orchestrator.md"

test_209_blocked_row_precedes_terminal_blocked_row() {
  local a b
  a=$(grep -n -F '| `[fullstack-developer] BLOCKED` with `Blocked on: merge_conflict — merge touches locked test' "$ORCH_209B" | head -1 | cut -d: -f1)
  b=$(grep -n -F '| any `BLOCKED` | Terminal' "$ORCH_209B" | head -1 | cut -d: -f1)
  assert_ne "$a" "" "209: dispatch row for the merge_conflict BLOCKED must exist" || return 1
  assert_ne "$b" "" "209: terminal any-BLOCKED row must exist" || return 1
  [ "$a" -lt "$b" ] || { echo "209: merge_conflict row must come before any BLOCKED"; return 1; }
}

run_test test_209_blocked_row_precedes_terminal_blocked_row
