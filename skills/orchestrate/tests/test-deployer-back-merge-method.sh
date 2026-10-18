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
  # A plain, non-paginated call to the same endpoint would silently miss commits past page 1 on
  # a large back-merge PR — regression guard for that specific mistake. Folded into this test
  # (rather than a standalone negative test) because it only means anything alongside the
  # positive assert above: on its own it's vacuously true whenever there's no commits call at all.
  assert_not_contains "$body" "gh api repos/<owner>/<repo>/pulls/<N>/commits" "deployer.md (non-paginated form)" || return 1
}

test_dbm_ac1_both_merge_methods_present() {
  local body
  body=$(cat "$DEPLOYER_DBM")
  assert_contains "$body" "--merge --delete-branch" "deployer.md" || return 1
  assert_contains "$body" "--squash --delete-branch" "deployer.md" || return 1
  # Positively pin the correct filter literal, rather than blacklisting one wrong spelling —
  # a blacklist on ">= 1" alone would still let a semantically identical off-by-one, like
  # "> 0" (merge on every PR, since every commit has at least 1 parent), slip through.
  assert_contains "$body" "select((.parents|length) > 1)" "deployer.md (jq filter must be exactly '> 1')" || return 1
}

test_dbm_ac1_merge_methods_wired_to_correct_branch() {
  # Reject the exact incident this ticket fixes reintroduced as an inverted mapping: non-empty
  # commits output (a real merge commit present) routed to --squash, empty routed to --merge.
  # both_merge_methods_present alone can't catch that — both strings are still present somewhere
  # in the file either way. Pin each merge method to its own branch by slicing the text between
  # the "Non-empty output" / "Empty output" markers and the following step.
  local body non_empty_block empty_block
  body=$(cat "$DEPLOYER_DBM")
  assert_contains "$body" "Back-merge parent found" "deployer.md (back-merge branch marker)" || return 1
  assert_contains "$body" "No merge commits, or none with a back-merge parent" "deployer.md (squash branch marker)" || return 1

  non_empty_block="${body#*Back-merge parent found}"
  non_empty_block="${non_empty_block%%No merge commits, or none*}"
  assert_contains "$non_empty_block" "--merge --delete-branch" "deployer.md (non-empty-output branch must use --merge)" || return 1
  assert_not_contains "$non_empty_block" "--squash --delete-branch" "deployer.md (non-empty-output branch must not use --squash)" || return 1

  empty_block="${body#*No merge commits, or none with a back-merge parent}"
  empty_block="${empty_block%%Note the merged commit*}"
  assert_contains "$empty_block" "--squash --delete-branch" "deployer.md (empty-output branch must use --squash)" || return 1
  assert_not_contains "$empty_block" "--merge --delete-branch" "deployer.md (empty-output branch must not use --merge)" || return 1
}

test_dbm_ac2_deployed_template_states_method_and_parents() {
  local body
  body=$(cat "$DEPLOYER_DBM")
  assert_contains "$body" "Merge method: <squash | merge> (merged commit has <1|2> parent(s)) — <back-merge | squash despite catch-up merges | no merge commits>" "deployer.md DEPLOYED template" || return 1
}

# Issue #400: --merge only when a non-first parent is on main and not on the base; catch-up
# merges (parent on neither / already on base) must be squashed so the commit title ends "(#N)".
test_dbm_400_back_merge_discriminator() {
  local body step
  body=$(cat "$DEPLOYER_DBM")
  step="${body#*4. **Merge the PR.**}"
  step="${step%%5. **Verify deployment.**}"
  assert_contains "$step" "compare/main...<P>" "deployer.md step 4 (is parent on main)" || return 1
  assert_contains "$step" "compare/<base>...<P>" "deployer.md step 4 (is parent on base)" || return 1
  assert_contains "$step" "behind" "deployer.md step 4 (behind status)" || return 1
  assert_contains "$step" "identical" "deployer.md step 4 (identical status)" || return 1
  assert_contains "$step" "on \`main\` (status \`behind\`/\`identical\`) and NOT on \`<base>\`" "deployer.md step 4 (rule)" || return 1
}

test_dbm_400_catch_up_merge_is_squashed() {
  local body step
  body=$(cat "$DEPLOYER_DBM")
  step="${body#*4. **Merge the PR.**}"
  step="${step%%5. **Verify deployment.**}"
  assert_contains "$step" "a parent that is on neither" "deployer.md step 4 (feature catch-up case)" || return 1
  assert_contains "$step" "a parent already on \`<base>\`" "deployer.md step 4 (branch-sync case)" || return 1
  assert_contains "$step" "catch-up merges included" "deployer.md step 4 (squash despite catch-up)" || return 1
  assert_not_contains "$step" "Non-empty output (a 2+-parent" "deployer.md step 4 (old any-2-parent rule)" || return 1
}

echo "-- deployer back-merge method (issue #101)"
run_test test_dbm_ac1_paginated_commits_check
run_test test_dbm_ac1_both_merge_methods_present
run_test test_dbm_ac1_merge_methods_wired_to_correct_branch
run_test test_dbm_ac2_deployed_template_states_method_and_parents
run_test test_dbm_400_back_merge_discriminator
run_test test_dbm_400_catch_up_merge_is_squashed
