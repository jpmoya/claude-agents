# Issue #269 AC1+AC2 — agents/orchestrator.md has a routing row, BEFORE the terminal `any BLOCKED` row, that resumes a
# BLOCKED (class ci_pending|ci_red|merge_conflict|dependency) once a LATER `[supervisor] NOTE auto-retry n/max: <cls> cleared`
# with the same class exists. Text-level checks on the doc (the orchestrator is an LLM prompt); expected strings from the ticket.
# These greps alone let #269 ship while markers() still filtered every NOTE out, so the row could never fire.
# test-orchestrator-sees-autoretry-note.sh is the behavioural guard: it runs the real markers()/gate-marker code
# from orchestrator.md on a NOTE captured from a real supervisor tick.
# Prefixed o269_.

HERE_O269=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_O269="$HERE_O269/../../../agents/orchestrator.md"

# the resume row: a table row (starts with `| `) naming the supervisor auto-retry NOTE, first one in the file
o269_row() { grep -F '| ' "$ORCH_O269" | grep -F 'auto-retry' | grep -F 'cleared' | grep -F '[supervisor] NOTE' | head -1; }
o269_line_of() { grep -n -F -- "$1" "$ORCH_O269" | head -1 | cut -d: -f1; }

test_o269_row_exists_before_terminal_any_blocked() {
  local row a b
  row=$(o269_row)
  assert_ne "$row" "" "269 AC1: a routing row for the supervisor auto-retry NOTE must exist" || return 1
  a=$(grep -n -F -- "$row" "$ORCH_O269" | head -1 | cut -d: -f1)
  b=$(o269_line_of '| any `BLOCKED` | Terminal')
  assert_ne "$b" "" "269 AC1: terminal any-BLOCKED row must still exist (AC2: stays terminal)" || return 1
  [ "$a" -lt "$b" ] || { fail "269 AC1: resume row (line $a) must come before any-BLOCKED (line $b)"; return 1; }
}

test_o269_row_names_the_four_classes() {
  local row c
  row=$(o269_row); assert_ne "$row" "" "269: row exists" || return 1
  for c in ci_pending ci_red merge_conflict dependency; do
    assert_contains "$row" "$c" "269 AC1: row names class $c" || return 1
  done
  assert_contains "$row" 'Blocked on: ' "269 AC1: row keys on line 2 Blocked on" || return 1
}

test_o269_row_has_exact_note_first_line() {
  local row; row=$(o269_row); assert_ne "$row" "" "269: row exists" || return 1
  assert_contains "$row" '**[supervisor] NOTE** auto-retry <n>/<max>: <cls> cleared' "269 AC1: exact NOTE first line" || return 1
  # The supervisor appends ` — <detail>` on infra-tolerated retries (#473); "exactly" rejected those. The row now defers to
  # autoretry_note_re, the regex markers() reads with, so the doc and the code path cannot disagree.
  assert_contains "$row" 'autoretry_note_re' "269 AC2: the row names the regex markers() lists the NOTE with" || return 1
  assert_contains "$row" '` — <detail>`' "269 AC2: the row accepts the supervisor's detail suffix" || return 1
  assert_contains "$row" 'leading text' "269 AC2: a NOTE with leading text resumes nothing" || return 1
}

test_o269_row_redispatches_blocked_author_with_note_url() {
  local row; row=$(o269_row); assert_ne "$row" "" "269: row exists" || return 1
  assert_contains "$row" 'Re-dispatch the agent that posted' "269 AC1: re-dispatches the BLOCKED's author" || return 1
  assert_contains "$row" 'the supervisor verified the blocker cleared: <URL> — re-check and continue' "269 AC1: prompt carries the NOTE URL" || return 1
}

test_o269_row_requires_later_note_same_class() {
  local row; row=$(o269_row); assert_ne "$row" "" "269: row exists" || return 1
  assert_contains "$row" 'later' "269 AC2: NOTE must be later than the BLOCKED (earlier NOTE does not resume)" || return 1
  assert_contains "$row" 'same `<cls>`' "269 AC2: NOTE class must equal the BLOCKED's class" || return 1
  assert_contains "$row" 'supersedes' "269 AC2: a later BLOCKED supersedes the NOTE" || return 1
}

test_o269_row_excludes_jp_gates_and_other_tracks() {
  local row t; row=$(o269_row); assert_ne "$row" "" "269: row exists" || return 1
  for t in needs_jp other unsupported_project cost_ceiling 'infra' 'AWAITING GO' 'MOCKUPS PENDING APPROVAL' 'JP-only'; do
    assert_contains "$row" "$t" "269 AC2: row excludes $t" || return 1
  done
  assert_contains "$row" 'Never applies' "269 AC2: explicit never-applies clause" || return 1
}

run_test test_o269_row_exists_before_terminal_any_blocked
run_test test_o269_row_names_the_four_classes
run_test test_o269_row_has_exact_note_first_line
run_test test_o269_row_redispatches_blocked_author_with_note_url
run_test test_o269_row_requires_later_note_same_class
run_test test_o269_row_excludes_jp_gates_and_other_tracks
