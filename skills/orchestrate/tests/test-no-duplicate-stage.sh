# Issue #85: hooks/no-duplicate-stage.sh compares each running stage's OWN ticket (PIPELINE_ISSUE=N,
# else last "Issue: #N", else first reference), not any #N mention in its prompt.
# Fake `ps` first on PATH prints canned args lines. Placeholder numbers only.

HOOK_NDS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/no-duplicate-stage.sh"

# nds_run <running-args-or-empty> <new-prompt> [stage] — prints the hook's exit code
nds_run() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-nds.XXXXXX")
  printf '%s\n' "$1" > "$d/ps.out"
  printf '#!/bin/bash\ncat "%s/ps.out"\n' "$d" > "$d/ps"; chmod +x "$d/ps"
  local cmd="claude -p --agent ${3:-developer} -p \"$2\""
  local json; json=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$cmd")
  local rc
  printf '%s' "$json" | PATH="$d:$PATH" bash "$HOOK_NDS" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  echo "$rc"
}

test_nds_other_ticket_mentioned_in_note_does_not_block() {
  local run='claude -p --agent developer -p Implement issue #322 ... Note: #319 touches the same files ... Issue: #322.'
  assert_eq "$(nds_run "$run" 'Implement issue #319. Issue: #319.')" "0" "#85: running #322 (notes #319) must not block #319" || return 1
}

test_nds_same_ticket_still_blocks() {
  local run='claude -p --agent developer -p Implement issue #319 ... Issue: #319.'
  assert_eq "$(nds_run "$run" 'Implement issue #319. Issue: #319.')" "2" "#85: running #319 blocks a second #319" || return 1
}

test_nds_no_issue_line_uses_first_reference() {
  local run='claude -p --agent developer -p Implement issue #322 ... Note: #319 touches the same files'
  assert_eq "$(nds_run "$run" 'Implement issue #319.')" "0" "#85: first ref #322 -> not a #319 developer" || return 1
}

test_nds_different_stage_does_not_block() {
  local run='claude -p --agent reviewer -p Review issue #319. Issue: #319.'
  assert_eq "$(nds_run "$run" 'Implement issue #319. Issue: #319.')" "0" "#85: reviewer running does not block developer" || return 1
}

run_test test_nds_other_ticket_mentioned_in_note_does_not_block
run_test test_nds_same_ticket_still_blocks
run_test test_nds_no_issue_line_uses_first_reference
run_test test_nds_different_stage_does_not_block
