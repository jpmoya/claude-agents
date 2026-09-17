# AC11 — the reporter and its tests contain no flock, setsid, GNU-only date/stat flags, or
# bash-4-only syntax (declare -A, etc.) — grep-verifiable — and the test suite passes on both a
# Linux and a macOS-shaped shell (document the manual/CI check used).
#
# Two halves, both real checks:
#   (a) the test suite itself (files that already exist) contains none of the forbidden syntax —
#       meaningful right now.
#   (b) the not-yet-implemented reporter/run-state.sh contain none of the forbidden syntax AND
#       do contain the mandated portable replacement (the python3 mtime helper) — the negative
#       half is trivially true of an empty stub, so it's paired with the positive requirement,
#       which is genuinely absent today and fails until implemented.
#
# macOS bash 3.2 itself cannot be executed in this environment (no macOS host, no shellcheck
# installed here) — running the suite under a real bash-3.2 shell on the Mac is a manual
# developer/CI check, documented in the handoff, not something this grep can prove.

HERE_AC11=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC11="$HERE_AC11/.."

FORBIDDEN_RE='\bflock\b|\bsetsid\b|\bdeclare[[:space:]]+-A\b|date[[:space:]]+-d[[:space:]]|date[[:space:]]+-r[[:space:]]|stat[[:space:]]+-c[[:space:]]|stat[[:space:]]+-f[[:space:]]|readlink[[:space:]]+-f\b'

test_ac11_own_test_suite_has_no_forbidden_syntax() {
  # test-ac10-lock.sh and this file itself legitimately grep FOR the words "flock"/"setsid" (to
  # assert their absence elsewhere) — excluded here as self-reference, not scanned for it.
  local files hits
  files=$(ls "$HERE_AC11"/test-*.sh "$HERE_AC11"/lib/*.sh "$HERE_AC11"/run-tests.sh 2>/dev/null \
    | grep -v -e 'test-ac10-lock\.sh$' -e 'test-ac11-portability\.sh$')
  hits=$(grep -nE "$FORBIDDEN_RE" $files 2>/dev/null || true)
  assert_eq "$hits" "" "AC11: the test suite itself must contain no flock/setsid/declare -A/GNU-only date-stat flags" || return 1
}

test_ac11_reporter_and_run_state_no_forbidden_syntax_and_use_python3_mtime() {
  local hits hit
  hits=$(grep -nE "$FORBIDDEN_RE" "$RS_AC11/report-status.sh" "$RS_AC11/run-state.sh" 2>/dev/null || true)
  assert_eq "$hits" "" "AC11: report-status.sh/run-state.sh must contain no flock/setsid/declare -A/GNU-only date-stat flags" || return 1
  # Positive half: the negative check alone is trivially true of an empty stub, so also require
  # the mandated portable replacement (python3 -c 'import os...getmtime') — absent today. Comment
  # lines excluded so a design-contract docstring mentioning the helper in prose can't satisfy it.
  hit=$(grep -vE '^[[:space:]]*#' "$RS_AC11/run-state.sh" | grep -nE "os\.path\.getmtime|os\.stat\(" || true)
  assert_ne "$hit" "" "AC11: run-state.sh must derive mtimes via python3's os.path.getmtime (design), not GNU stat/date flags" || return 1
}

test_ac11_alias_map_documented_as_indexed_array_not_declare_a() {
  # AC18 requires config.local.example.sh to document STATUS_REPO_ALIASES; AC11 requires it be an
  # indexed array, never `declare -A`. Paired positive+negative: absent from the file today (AC18
  # isn't done either), so this fails until both land, then guards the array form specifically.
  local declare_a_hits array_form
  declare_a_hits=$(grep -nE '\bdeclare[[:space:]]+-A\b' "$RS_AC11/config.local.example.sh" 2>/dev/null || true)
  assert_eq "$declare_a_hits" "" "AC11: STATUS_REPO_ALIASES must never use declare -A (bash-4-only)" || return 1
  array_form=$(grep -nE 'STATUS_REPO_ALIASES=\(' "$RS_AC11/config.local.example.sh" 2>/dev/null || true)
  assert_ne "$array_form" "" "AC11/AC18: config.local.example.sh must document STATUS_REPO_ALIASES as an indexed array (\"owner/repo:alias\")" || return 1
}

run_test test_ac11_own_test_suite_has_no_forbidden_syntax
run_test test_ac11_reporter_and_run_state_no_forbidden_syntax_and_use_python3_mtime
run_test test_ac11_alias_map_documented_as_indexed_array_not_declare_a
