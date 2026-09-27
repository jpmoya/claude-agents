# Issue #101 regression guard: the deployer squashed a back-merge PR (main -> staging), which
# drops the merge commit's `main` parent since --squash always produces a single-parent commit.
# That left `main` permanently out of `staging`'s ancestry and broke the next staging->main
# promotion (quoting-tool #366/#377). agents/deployer.md's step 4 must choose the merge method
# from the PR's own commits (checked across all pages, since a back-merge PR can exceed the
# 30-commits-per-page default): any commit with 2+ parents means a real merge commit is present,
# so --merge is used to preserve it; otherwise --squash is kept. Step 7's DEPLOYED template must
# say which method was used and the merged commit's parent count.
# Nothing here touches the network, gh, or /tmp/pipeline: every case reads tracked files only.

HERE_DBM=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DBM=$(cd "$HERE_DBM/../../.." && pwd)
DEPLOYER_DBM="$ROOT_DBM/agents/deployer.md"

test_dbm_ac1_paginated_commits_check() {
  local body
  assert_file_exists "$DEPLOYER_DBM" "deployer definition" || return 1
  body=$(cat "$DEPLOYER_DBM")
  assert_contains "$body" "gh api --paginate repos/<owner>/<repo>/pulls/<N>/commits" "deployer.md" || return 1
}

test_dbm_ac1_not_single_page_call() {
  local body
  body=$(cat "$DEPLOYER_DBM")
  # A plain, non-paginated call to the same endpoint would silently miss commits past page 1 on
  # a large back-merge PR — regression guard for that specific mistake.
  assert_not_contains "$body" "gh api repos/<owner>/<repo>/pulls/<N>/commits" "deployer.md (non-paginated form)" || return 1
}

test_dbm_ac1_both_merge_methods_present() {
  local body
  body=$(cat "$DEPLOYER_DBM")
  assert_contains "$body" "--merge --delete-branch" "deployer.md" || return 1
  assert_contains "$body" "--squash --delete-branch" "deployer.md" || return 1
}

test_dbm_ac2_deployed_template_states_method_and_parents() {
  local body
  body=$(cat "$DEPLOYER_DBM")
  assert_contains "$body" "Merge method: <squash | merge> (merged commit has <1|2> parent(s))" "deployer.md DEPLOYED template" || return 1
}

echo "-- deployer back-merge method (issue #101)"
run_test test_dbm_ac1_paginated_commits_check
run_test test_dbm_ac1_not_single_page_call
run_test test_dbm_ac1_both_merge_methods_present
run_test test_dbm_ac2_deployed_template_states_method_and_parents
