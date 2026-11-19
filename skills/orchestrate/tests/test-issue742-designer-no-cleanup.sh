# Issue #742: ui-ux-designer must not order an `rm -rf` cleanup of /tmp/mockups-*; the repos' `Bash(rm -rf *)`
# deny rule refuses the whole shell call (push included), and the .mockups/ branch is the durable record.
# No replacement deletion (rm -r, find -exec rm, ...) may be added either. Prose contract pinned by literal strings.
ROOT_742=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
UX_742="$ROOT_742/agents/ui-ux-designer.md"

test_742_no_rm_rf_in_designer() {
  assert_eq "$(grep -c 'rm -rf' "$UX_742")" "0" "rm -rf in ui-ux-designer.md" || return 1
}
test_742_no_clean_up_bullet() {
  assert_eq "$(grep -c 'Delete the `/tmp/mockups' "$UX_742")" "0" "Delete the /tmp/mockups bullet" || return 1
  assert_eq "$(grep -c '^- \*\*Clean up' "$UX_742")" "0" "Clean up bullet" || return 1
}
test_742_no_replacement_deletion() {
  assert_eq "$(grep -cE 'rm -r|rm -fr|find .*-exec rm|find .*-delete|rmdir|shutil\.rmtree' "$UX_742")" "0" "replacement deletion of /tmp/mockups-*" || return 1
}
test_742_keeps_neighbouring_rule() {
  assert_eq "$(grep -c '^- \*\*Don.t mock standard states' "$UX_742")" "1" "neighbouring rule kept" || return 1
}

run_test test_742_no_rm_rf_in_designer
run_test test_742_no_clean_up_bullet
run_test test_742_no_replacement_deletion
run_test test_742_keeps_neighbouring_rule
