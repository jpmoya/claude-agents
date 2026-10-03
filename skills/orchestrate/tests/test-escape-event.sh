# Issue #138 AC19 (Phase 2 of #134): at product-manager stage end, stage-run.sh reads the issue body once and, when a
# line matches `^Caused by: <owner>/<repo>#<N>$` (trailing spaces allowed), appends one `escape` row to events.jsonl
# (unless one already exists for that repo + issue). stage_start / stage_end rows are written as before in every case.
# Expected values come from the ticket text. All names are ee_/EE_ prefixed; placeholder repos only; issue 42.

HERE_EE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAP_EE="$HERE_EE/../stage-run.sh"

# ee_setup — sandbox with stub claude (exit 0) and fake gh. Fake gh knobs (files in EE_BIN):
#   body.txt   the issue body answered to `gh api repos/<r>/issues/<n> --jq .body`
#   gh-fail    every call exits 1
ee_setup() {
  EE_BIN=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ee.XXXXXX")
  EE_PIPE=$(new_pipe); EE_HOME=$(new_home); EE_LOG="$EE_HOME/logs/pipeline"
  printf '#!/bin/bash\nexit 0\n' > "$EE_BIN/claude"
  cat > "$EE_BIN/gh" <<'EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$D/gh-calls.log"
[ -e "$D/gh-fail" ] && { echo "boom" >&2; exit 1; }
[ "$1" = "api" ] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
case "$*" in
  *"/comments"*) echo '[]'; exit 0 ;;
  *"issues/42"*) cat "$D/body.txt" 2>/dev/null; exit 0 ;;
esac
echo "fake gh: unsupported: $*" >&2; exit 1
EOF
  chmod +x "$EE_BIN/claude" "$EE_BIN/gh"
  : > "$EE_BIN/gh-calls.log"
}
ee_teardown() { rm -rf "$EE_BIN" "$EE_PIPE" "$EE_HOME"; }

# ee_run [agent] — one wrapper run for issue 42 as <agent> (default product-manager); sets EE_RC
ee_run() {
  local agent=${1:-product-manager}
  ( cd "$EE_HOME" && env PIPE="$EE_PIPE" LOGDIR="$EE_LOG" HOME="$EE_HOME" CLAUDE_PROJECTS_DIR="$EE_HOME/.claude/projects" \
      PATH="$EE_BIN:$PATH" PIPELINE_ISSUE=42 PIPELINE_AGENT="$agent" PIPELINE_REPO=project-a/app \
      "$WRAP_EE" -- claude --dangerously-skip-permissions --agent "$agent" -p "Refine. Repo: project-a/app. Issue: #42." >/dev/null 2>&1 )
  EE_RC=$?
}
ee_count() { jq -c "select(.event==\"$1\")" "$EE_LOG/events.jsonl" 2>/dev/null | wc -l | tr -d ' '; }
ee_last() { jq -c "select(.event==\"$1\")" "$EE_LOG/events.jsonl" 2>/dev/null | tail -1; }
ee_f() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ee_negative <label> — shared assertions: the product-manager stage read the issue body, no escape row,
# stage rows intact, exit code passed through
ee_negative() {
  assert_eq "$(grep -c 'issues/42 ' "$EE_BIN/gh-calls.log"; true)" "1" "#138/5: $1 -> the body was read once at stage end" || return 1
  assert_eq "$(ee_count escape)" "0" "#138/19: $1 -> no escape row" || return 1
  assert_eq "$(ee_count stage_start)" "1" "#138/19: $1 -> stage_start still written" || return 1
  assert_eq "$(ee_count stage_end)" "1" "#138/19: $1 -> stage_end still written" || return 1
  assert_eq "$EE_RC" "0" "#138/19: $1 -> wrapper exit code is the child's" || return 1
}

test_ee_caused_by_line_yields_one_escape_row() {
  ee_setup
  printf 'Why: it broke.\nCaused by: project-a/app#7\nMore text.\n' > "$EE_BIN/body.txt"
  ee_run
  local row; row=$(ee_last escape)
  local n; n=$(ee_count escape)
  assert_eq "$n" "1" "#138/19: one escape row" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" .caused_by_repo)" "project-a/app" "#138/19: caused_by_repo" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" .caused_by_issue)" "7" "#138/19: caused_by_issue value" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" '.caused_by_issue|type')" "number" "#138/19: caused_by_issue is a number" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" .repo)" "project-a/app" "#138/19: repo" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" .issue)" "42" "#138/19: issue" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" .v)" "1" "#138/18: v 1" || { ee_teardown; return 1; }
  assert_eq "$(ee_f "$row" .host)" "$(hostname -s | tr '[:upper:]' '[:lower:]')" "#138/18: host matches the stage rows" || { ee_teardown; return 1; }
  assert_eq "$(ee_count stage_start)" "1" "#138/19: stage_start still written" || { ee_teardown; return 1; }
  assert_eq "$(ee_count stage_end)" "1" "#138/19: stage_end still written" || { ee_teardown; return 1; }
  ee_teardown
}

test_ee_trailing_spaces_allowed() {
  ee_setup
  printf 'Caused by: project-a/app#7   \n' > "$EE_BIN/body.txt"
  ee_run
  local n; n=$(ee_count escape)
  ee_teardown
  assert_eq "$n" "1" "#138/19: trailing spaces allowed" || return 1
}

test_ee_no_caused_by_line_yields_none() {
  ee_setup
  printf 'Why: it broke.\nNothing about causes.\n' > "$EE_BIN/body.txt"
  ee_run
  ee_negative "no Caused by line"; local rc=$?
  ee_teardown; return $rc
}

test_ee_caused_by_unknown_yields_none() {
  ee_setup
  printf 'Caused by: unknown\n' > "$EE_BIN/body.txt"
  ee_run
  ee_negative "Caused by: unknown"; local rc=$?
  ee_teardown; return $rc
}

test_ee_line_must_match_whole_line() {
  ee_setup
  printf 'Caused by: project-a/app#7 and also something\nSee Caused by: project-a/app#7\n' > "$EE_BIN/body.txt"
  ee_run
  ee_negative "line not anchored to ^...$"; local rc=$?
  ee_teardown; return $rc
}

test_ee_gh_failure_writes_nothing_else_changes() {
  ee_setup
  printf 'Caused by: project-a/app#7\n' > "$EE_BIN/body.txt"
  : > "$EE_BIN/gh-fail"
  ee_run
  ee_negative "gh exits 1"; local rc=$?
  ee_teardown; return $rc
}

test_ee_only_product_manager_stage_reads_the_body() {
  ee_setup
  printf 'Caused by: project-a/app#7\n' > "$EE_BIN/body.txt"
  ee_run product-manager
  local after_pm; after_pm=$(grep -c 'issues/42 ' "$EE_BIN/gh-calls.log"; true)
  ee_run code-reviewer
  local after_cr; after_cr=$(grep -c 'issues/42 ' "$EE_BIN/gh-calls.log"; true)
  local esc; esc=$(ee_count escape)
  ee_teardown
  assert_eq "$after_pm" "1" "#138/5: the product-manager stage reads the body once" || return 1
  assert_eq "$after_cr" "1" "#138/5: a non product-manager stage reads nothing more" || return 1
  assert_eq "$esc" "1" "#138/19: only the product-manager stage logged an escape row" || return 1
}

test_ee_twice_for_same_ticket_yields_one_row() {
  ee_setup
  printf 'Caused by: project-a/app#7\n' > "$EE_BIN/body.txt"
  ee_run; ee_run
  local n s; n=$(ee_count escape); s=$(ee_count stage_end)
  ee_teardown
  assert_eq "$n" "1" "#138/19: second run for the same repo+issue adds no escape row" || return 1
  assert_eq "$s" "2" "#138/19: both runs still wrote their stage_end" || return 1
}

run_test test_ee_caused_by_line_yields_one_escape_row
run_test test_ee_trailing_spaces_allowed
run_test test_ee_no_caused_by_line_yields_none
run_test test_ee_caused_by_unknown_yields_none
run_test test_ee_line_must_match_whole_line
run_test test_ee_gh_failure_writes_nothing_else_changes
run_test test_ee_only_product_manager_stage_reads_the_body
run_test test_ee_twice_for_same_ticket_yields_one_row
