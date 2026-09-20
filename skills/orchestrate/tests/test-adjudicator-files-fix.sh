# Issue #39: the adjudicator files and queues its own zero-mechanism fix ticket; JP is asked only
# for a new mechanism or a JP-only item. Prose contract, pinned by literal strings in tracked files.
ROOT_AF=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ADJ_AF="$ROOT_AF/agents/pipeline-adjudicator.md"
CMD_AF="$ROOT_AF/CLAUDE.md"

af_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
af_lacks() { if grep -qiF -- "$2" "$1"; then fail "$(basename "$1"): still contains [$2]"; return 1; fi; }

test_af_ac1_files_and_labels() {
  af_has "$ADJ_AF" 'gh issue create --repo jpmoya/claude-agents' || return 1
  af_has "$ADJ_AF" 'gh issue edit <n> --add-label agent-go' || return 1
  af_has "$ADJ_AF" 'tells JP the issue number filed' || return 1
  for s in 'You file nothing' 'You file no issue' 'you add no label' 'no write at all'; do
    af_lacks "$ADJ_AF" "$s" || return 1
  done
}

test_af_ac2_ac3_no_file_cases() {
  af_has "$ADJ_AF" '` ≥ 1 → file nothing' || return 1
  af_has "$ADJ_AF" 'JP must approve first' || return 1
  af_has "$ADJ_AF" 'File no new issue' || return 1
}

test_af_ac4_do_now() {
  af_has "$ADJ_AF" 'DO NOW' || return 1
  af_has "$ADJ_AF" 'DO: <exact instruction>' || return 1
  af_has "$ADJ_AF" '"JP should consider"' || return 1
}

test_af_ac5_hard_limits() {
  local hl
  hl=$(awk '/^## Hard limits/ { on = 1; next } on && /^## / { exit } on { print }' "$ADJ_AF")
  for s in '`gh issue comment`' '`gh issue create` (repo `jpmoya/claude-agents` only)' \
           '`gh issue edit --add-label agent-go` on the issue you just created' 'no `orchestrate.sh`'; do
    case "$hl" in *"$s"*) ;; *) fail "hard limits: missing [$s]"; return 1 ;; esac
  done
}

test_af_ac6_description() {
  local d
  d=$(grep '^description:' "$ADJ_AF")
  assert_not_contains "$d" 'files nothing;' "description" || return 1
  assert_contains "$d" 'files the fix ticket' "description" || return 1
  assert_contains "$d" 'agent-go' "description" || return 1
}

test_af_ac7_claude_md() {
  af_lacks "$CMD_AF" 'only after JP says yes' || return 1
  af_lacks "$ADJ_AF" 'only after JP says yes' || return 1
  af_has "$CMD_AF" 'files and queues' || return 1
  af_has "$CMD_AF" 'DO NOW' || return 1
  af_has "$CMD_AF" 'without asking JP' || return 1
}

echo "-- adjudicator files fix ticket (issue #39)"
run_test test_af_ac1_files_and_labels
run_test test_af_ac2_ac3_no_file_cases
run_test test_af_ac4_do_now
run_test test_af_ac5_hard_limits
run_test test_af_ac6_description
run_test test_af_ac7_claude_md
