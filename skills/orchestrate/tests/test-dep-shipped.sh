# Issue #677 Part A — skills/orchestrate/dep-shipped.sh <owner/repo> <N>: has dependency #N shipped to the integration branch?
# Exit 0 = shipped, 1 = not shipped, 2 = read error; one reason line on stdout. Self-contained (gh + jq only).
#
# Black-box against a fake `gh` first on PATH. Knobs, files in $DS_D:
#   staging            present -> `gh api repos/<r>/branches/staging` succeeds; absent -> exits 1 with "HTTP 404" on stderr
#   branch-fail        the branch call exits 1 with "HTTP 500" (not a 404)
#   default-branch     the repo's default branch (default: main); default-fail -> that read exits 1
#   comments.json      REST comments of the dependency issue (default []); comments-fail -> the read exits 1
#   pr-<n>.json        {state, baseRefName} for `gh pr view <n>`; absent or pr-fail -> exits 1
#   merged.json        [{number, headRefName, baseRefName}] for `gh pr list --state merged --base <b>` (filtered on --base);
#                      list-fail -> exits 1
# Expected exit codes are the ticket's fixtures i-vi. Prefix ds_ / DS_. Placeholder repo names only.

HERE_DS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DS_SCRIPT="$HERE_DS/../dep-shipped.sh"
DS_REPO="project-a/repo-a"
DS_IMPL='**[fullstack-developer] IMPLEMENTED**'

ds_setup() {
  DS_D=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ds.XXXXXX")
  : > "$DS_D/gh-calls.log"
  cat > "$DS_D/gh" <<'GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$D/gh-calls.log"
jqx=""; base=""; prev=""
for a in "$@"; do
  case "$prev" in --jq|-q) jqx=$a ;; --base|-B) base=$a ;; esac
  prev=$a
done
emit() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
case "$1 $2" in
  "pr view")
    [ -f "$D/pr-fail" ] && { echo "HTTP 502 token=ghp_FAKESECRET123" >&2; exit 1; }
    [ -f "$D/pr-$3.json" ] || { echo "no pull requests found" >&2; exit 1; }
    emit < "$D/pr-$3.json"; exit 0 ;;
  "pr list")
    [ -f "$D/list-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    case "$*" in *"--state merged"*) ;; *) echo "fake gh: pr list without --state merged" >&2; exit 1 ;; esac
    if [ -f "$D/merged.json" ]; then jq -c --arg b "$base" '[.[] | select(.baseRefName == $b) | {number, headRefName}]' "$D/merged.json" | emit
    else echo '[]' | emit; fi
    exit 0 ;;
esac
[ "$1" = api ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
path=""; shift
for a in "$@"; do case "$a" in repos/*) path=$a ;; esac; done
case "$path" in
  repos/*/*/branches/staging)
    [ -f "$D/branch-fail" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [ -f "$D/staging" ] || { echo "gh: Branch not found (HTTP 404)" >&2; exit 1; }
    echo '{"name":"staging"}' | emit ;;
  repos/*/*/issues/*/comments*)
    [ -f "$D/comments-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    if [ -f "$D/comments.json" ]; then emit < "$D/comments.json"; else echo '[]' | emit; fi ;;
  repos/*/*/*) echo "fake gh: unexpected path $path" >&2; exit 1 ;;
  repos/*/*)
    [ -f "$D/default-fail" ] && { echo "HTTP 502" >&2; exit 1; }
    jq -nc --arg b "$(cat "$D/default-branch" 2>/dev/null || echo main)" '{default_branch: $b}' | emit ;;
  *) echo "fake gh: unexpected path $path" >&2; exit 1 ;;
esac
GH_EOF
  chmod +x "$DS_D/gh"
}
ds_cleanup() { rm -rf "$DS_D"; }

# ds_comment <body> — append one REST comment to the dependency issue
ds_comment() {
  [ -f "$DS_D/comments.json" ] || echo '[]' > "$DS_D/comments.json"
  jq -c --arg b "$1" '. + [{id: (length + 1), body: $b, created_at: "2026-11-10T10:00:00Z", user: {login: "fixture"}}]' \
    "$DS_D/comments.json" > "$DS_D/c.tmp" && mv "$DS_D/c.tmp" "$DS_D/comments.json"
}
ds_pr() { jq -nc --arg s "$2" --arg b "$3" '{state: $s, baseRefName: $b}' > "$DS_D/pr-$1.json"; }   # <n> <state> <base>
ds_merged() { printf '%s' "$1" > "$DS_D/merged.json"; }

# ds_run <N> [repo] — sets DS_RC, DS_OUT (stdout only), DS_ERR
ds_run() {
  DS_OUT=$(PATH="$DS_D:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" /bin/bash "$DS_SCRIPT" "${2:-$DS_REPO}" "$1" 2>"$DS_D/stderr" </dev/null); DS_RC=$?
  DS_ERR=$(cat "$DS_D/stderr" 2>/dev/null)
}
ds_one_line() { assert_eq "$(printf '%s\n' "$DS_OUT" | grep -c .)" "1" "$1: exactly one reason line on stdout ($DS_OUT)"; }

# ---- fixture i: latest IMPLEMENTED names PR 12, PR 12 MERGED into staging, repo has a staging branch -> 0
test_ds_i_implemented_pr_merged_into_staging_is_shipped() {
  ds_setup; touch "$DS_D/staging"
  ds_comment "$DS_IMPL"$'\nPR #12 https://github.com/project-a/repo-a/pull/12\nAC1 -> test'
  ds_pr 12 MERGED staging
  ds_run 5
  local rc=$DS_RC out=$DS_OUT calls; calls=$(cat "$DS_D/gh-calls.log")
  ds_one_line "i" || { ds_cleanup; return 1; }
  ds_cleanup
  assert_eq "$rc" "0" "i: merged into staging -> shipped ($out)" || return 1
  assert_contains "$calls" "pr view 12" "i: the PR named by the latest IMPLEMENTED is the one read" || return 1
}

# ---- fixture ii: same, but the PR's base is feature-x -> 1
test_ds_ii_merged_into_another_branch_is_not_shipped() {
  ds_setup; touch "$DS_D/staging"
  ds_comment "$DS_IMPL"$'\nPR #12'
  ds_pr 12 MERGED feature-x
  ds_run 5
  local rc=$DS_RC out=$DS_OUT
  ds_one_line "ii" || { ds_cleanup; return 1; }
  ds_cleanup
  assert_eq "$rc" "1" "ii: base feature-x is not the integration branch ($out)" || return 1
}

# ---- fixture iii: two IMPLEMENTED comments, the latest names an OPEN PR, an older one a merged PR -> 1 (no fallback)
test_ds_iii_latest_implemented_unmerged_is_not_shipped_no_fallback() {
  ds_setup; touch "$DS_D/staging"
  ds_comment "$DS_IMPL"$'\nPR #11'
  ds_comment '**[code-reviewer] FAIL**'
  ds_comment "$DS_IMPL"$'\nPR #12'
  ds_pr 11 MERGED staging; ds_pr 12 OPEN staging
  ds_merged '[{"number":11,"headRefName":"issue-5-old","baseRefName":"staging"}]'   # the list fallback would say shipped
  ds_run 5
  local rc=$DS_RC out=$DS_OUT calls; calls=$(cat "$DS_D/gh-calls.log")
  ds_cleanup
  assert_eq "$rc" "1" "iii: the latest IMPLEMENTED names an open PR -> not shipped ($out)" || return 1
  assert_not_contains "$calls" "pr list" "iii: no fallback to the merged-PR list when an IMPLEMENTED names a PR" || return 1
}

# the first `PR #<n>` of the latest IMPLEMENTED is the PR, later numbers on the comment are not
test_ds_first_pr_number_in_the_comment_wins() {
  ds_setup; touch "$DS_D/staging"
  ds_comment "$DS_IMPL"$'\nPR #12 (replaces PR #9)\n#3 is unrelated'
  ds_pr 12 MERGED staging; ds_pr 9 CLOSED staging
  ds_run 5
  local rc=$DS_RC calls; calls=$(cat "$DS_D/gh-calls.log")
  ds_cleanup
  assert_eq "$rc" "0" "first PR #n of the latest IMPLEMENTED decides" || return 1
  assert_not_contains "$calls" "pr view 9" "the second PR number is never read" || return 1
}

# ---- fixture iv: no IMPLEMENTED; the merged-PR list holds head issue-7-foo -> 0 for N=7, 1 for N=70 and N=8
test_ds_iv_no_implemented_falls_back_to_merged_head_branch() {
  ds_setup; touch "$DS_D/staging"
  ds_comment '**[product-manager] READY FOR ENGINEERING**'
  ds_merged '[{"number":40,"headRefName":"issue-7-foo","baseRefName":"staging"},{"number":41,"headRefName":"issue-9-bar","baseRefName":"staging"}]'
  local rc7 rc70 rc8 calls
  ds_run 7; rc7=$DS_RC
  ds_one_line "iv" || { ds_cleanup; return 1; }
  ds_run 70; rc70=$DS_RC
  ds_run 8; rc8=$DS_RC
  calls=$(cat "$DS_D/gh-calls.log")
  ds_cleanup
  assert_eq "$rc7" "0" "iv: head issue-7-foo merged -> #7 shipped" || return 1
  assert_eq "$rc70" "1" "iv: issue-7-foo is not #70's branch" || return 1
  assert_eq "$rc8" "1" "iv: no issue-8- head -> #8 not shipped" || return 1
  assert_contains "$calls" "--state merged" "iv: the list is the merged PRs" || return 1
  assert_contains "$calls" "--base staging" "iv: restricted to the integration branch" || return 1
  assert_contains "$calls" "--limit 100" "iv: the ticket's limit" || return 1
}

# a merged issue-7- PR into another branch is not shipped (the fake filters the list on --base)
test_ds_iv_merged_head_on_another_base_is_not_shipped() {
  ds_setup; touch "$DS_D/staging"
  ds_merged '[{"number":40,"headRefName":"issue-7-foo","baseRefName":"feature-x"}]'
  ds_run 7
  local rc=$DS_RC; ds_cleanup
  assert_eq "$rc" "1" "iv: merged into feature-x only -> not shipped" || return 1
}

# ---- fixture v: repo without staging (404), PR merged into the default branch -> 0
test_ds_v_no_staging_branch_uses_the_default_branch() {
  ds_setup; echo trunk > "$DS_D/default-branch"
  ds_comment "$DS_IMPL"$'\nPR #12'
  ds_pr 12 MERGED trunk
  ds_run 5
  local rc=$DS_RC out=$DS_OUT
  ds_cleanup
  assert_eq "$rc" "0" "v: no staging branch, merged into the default branch -> shipped ($out)" || return 1
}
test_ds_v_no_staging_branch_list_fallback_uses_the_default_branch() {
  ds_setup
  ds_merged '[{"number":40,"headRefName":"issue-7-foo","baseRefName":"main"}]'
  ds_run 7
  local rc=$DS_RC calls; calls=$(cat "$DS_D/gh-calls.log"); ds_cleanup
  assert_eq "$rc" "0" "v: list fallback against the default branch" || return 1
  assert_contains "$calls" "--base main" "v: --base is the default branch when there is no staging" || return 1
}
# on a staging-model repo a PR merged into the default branch is not "on the integration branch"
test_ds_staging_repo_pr_merged_into_main_is_not_shipped() {
  ds_setup; touch "$DS_D/staging"
  ds_comment "$DS_IMPL"$'\nPR #12'
  ds_pr 12 MERGED main
  ds_run 5
  local rc=$DS_RC; ds_cleanup
  assert_eq "$rc" "1" "staging exists: base main is not the integration branch" || return 1
}

# ---- fixture vi: the PR read exits non-zero -> 2; every other failed gh call too
test_ds_vi_pr_read_failure_is_exit_2() {
  ds_setup; touch "$DS_D/staging" "$DS_D/pr-fail"
  ds_comment "$DS_IMPL"$'\nPR #12'
  ds_pr 12 MERGED staging
  ds_run 5
  local rc=$DS_RC out=$DS_OUT err=$DS_ERR
  ds_one_line "vi" || { ds_cleanup; return 1; }
  ds_cleanup
  assert_eq "$rc" "2" "vi: a failed PR read is a read error ($out)" || return 1
  assert_not_contains "$out$err" "ghp_FAKESECRET123" "vi: gh's stderr (may carry a token) is never echoed" || return 1
}
test_ds_other_read_failures_are_exit_2() {
  local rc_c rc_l rc_b rc_d
  ds_setup; touch "$DS_D/staging" "$DS_D/comments-fail"; ds_run 5; rc_c=$DS_RC; ds_cleanup
  ds_setup; touch "$DS_D/staging" "$DS_D/list-fail"; ds_run 5; rc_l=$DS_RC; ds_cleanup
  ds_setup; touch "$DS_D/branch-fail"; ds_merged '[{"number":1,"headRefName":"issue-5-x","baseRefName":"main"}]'; ds_run 5; rc_b=$DS_RC; ds_cleanup
  ds_setup; touch "$DS_D/default-fail"; ds_run 5; rc_d=$DS_RC; ds_cleanup
  assert_eq "$rc_c" "2" "comments read failed -> 2" || return 1
  assert_eq "$rc_l" "2" "merged-PR list failed -> 2" || return 1
  assert_eq "$rc_b" "2" "branch lookup failed with something other than a 404 -> 2 (never judged against the wrong branch)" || return 1
  assert_eq "$rc_d" "2" "default-branch read failed -> 2" || return 1
}
test_ds_bad_arguments_are_exit_2() {
  ds_setup
  local rc1 rc2 rc3 rc4 n
  ds_run abc; rc1=$DS_RC
  ds_run 5 not-a-repo; rc2=$DS_RC
  ds_run 5 "project-a/repo-a/extra"; rc3=$DS_RC
  ds_run 5 "../repo-a"; rc4=$DS_RC
  n=$(grep -c . "$DS_D/gh-calls.log")
  ds_cleanup
  assert_eq "$rc1" "2" "non-numeric issue -> 2" || return 1
  assert_eq "$rc2" "2" "repo without owner/ -> 2" || return 1
  assert_eq "$rc3" "2" "more than owner/repo -> 2" || return 1
  assert_eq "$rc4" "2" "a path segment is not an owner -> 2" || return 1
  assert_eq "$n" "0" "no gh call on a bad argument" || return 1
}

# ---- self-contained: gh + jq only, never config.sh (the orchestrator agent runs it from any directory)
test_ds_script_is_self_contained() {
  [ -x "$DS_SCRIPT" ] || { fail "dep-shipped.sh missing or not executable"; return 1; }
  local src; src=$(grep -vE '^[[:space:]]*#' "$DS_SCRIPT")
  assert_not_contains "$src" "config.sh" "does not source config.sh" || return 1
  assert_not_contains "$src" "pipeline-lib.sh" "does not source pipeline-lib.sh" || return 1
  /bin/bash -n "$DS_SCRIPT" || { fail "bash -n failed"; return 1; }
}

run_test test_ds_i_implemented_pr_merged_into_staging_is_shipped
run_test test_ds_ii_merged_into_another_branch_is_not_shipped
run_test test_ds_iii_latest_implemented_unmerged_is_not_shipped_no_fallback
run_test test_ds_first_pr_number_in_the_comment_wins
run_test test_ds_iv_no_implemented_falls_back_to_merged_head_branch
run_test test_ds_iv_merged_head_on_another_base_is_not_shipped
run_test test_ds_v_no_staging_branch_uses_the_default_branch
run_test test_ds_v_no_staging_branch_list_fallback_uses_the_default_branch
run_test test_ds_staging_repo_pr_merged_into_main_is_not_shipped
run_test test_ds_vi_pr_read_failure_is_exit_2
run_test test_ds_other_read_failures_are_exit_2
run_test test_ds_bad_arguments_are_exit_2
run_test test_ds_script_is_self_contained
