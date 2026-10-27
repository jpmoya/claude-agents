# Issue #492 — sweep_stale_worktrees (skills/orchestrate/pipeline-lib.sh) must never remove a worktree/branch whose
# GitHub issue is still OPEN, even when its PR has merged (a multi-PR ticket, or one back in a fix cycle after its
# first PR merged). This was the gap found by JP's diagnostician -> adjudicator pipeline-stall review: the sweep's
# only "safe to delete" signal was "branch has a merged PR", never whether the issue itself is still open.
#
# sweep_stale_worktrees had no test file before this ticket (there was nothing green to preserve); every case here
# is new. Fixture design: `gh pr list --state merged` is always stubbed to report a merged PR for the branch under
# test, so every case below exercises the NEW issue-open guard specifically, not the pre-existing merge/ancestor
# logic (untouched by this ticket, and not what these cases are pinned against) — AC3's case is the one exception,
# proving that logic alone still governs an ad hoc branch. Issue state and `gh issue view` failure are controlled
# per case via files in the fake gh's directory. `slack_post` does not exist in this repo; the alert reuses the
# existing SLACK_WEBHOOK_URL the same way claim_alert/launch_alert already do (pipeline-lib.sh). Every function/
# variable is prefixed ws_ / WS_ (all test files share one shell). Placeholder repo/owner names only (public repo).

HERE_WS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_WS=$(cd "$HERE_WS/../../.." && pwd)
PLS_WS="$ROOT_WS/skills/orchestrate/pipeline-lib.sh"
WS_OWNER_REPO="example-owner/project-a"

# ws_install_gh <dir> — fake `gh` logging every call to <dir>/gh-calls.log.
#   gh pr list --state merged   -> "[]" if <dir>/gh-pr-none exists, else one fake merged PR (always merged by default,
#                                  so every case here exercises the NEW issue-open guard, not the pre-existing merge check)
#   gh issue view <n> --json state --jq .state --repo <repo>
#                                -> exits 1 if <dir>/gh-issue-fail-<n> or <dir>/gh-issue-fail exists (simulated lookup
#                                   failure); else prints the contents of <dir>/gh-issue-state-<n> verbatim (default CLOSED)
#                                   — a case can put any junk ("null", "", a typo) in that file to test the fail-closed
#                                   allowlist, not just OPEN/CLOSED.
ws_install_gh() {
  local dir=$1
  mkdir -p "$dir"; : > "$dir/gh-calls.log"
  cat > "$dir/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
case "$*" in
  "pr list "*)
    if [ -f "$HERE/gh-pr-none" ]; then echo '[]'; else echo '[{"number":1,"mergedAt":"2026-01-01T00:00:00Z"}]'; fi
    exit 0 ;;
  "issue view "*)
    n=$(printf '%s' "$*" | sed -n 's/^issue view \([0-9][0-9]*\).*/\1/p')
    if [ -f "$HERE/gh-issue-fail-$n" ] || [ -f "$HERE/gh-issue-fail" ]; then exit 1; fi
    if [ -f "$HERE/gh-issue-state-$n" ]; then cat "$HERE/gh-issue-state-$n"; else echo CLOSED; fi
    exit 0 ;;
  *) exit 0 ;;
esac
GH_EOF
  chmod +x "$dir/gh"
}

# ws_env — a fresh isolated HOME + a throwaway local git repo (origin resolves to WS_OWNER_REPO, main has one commit,
# refs/remotes/origin/main points at it — the fp_history read sweep_stale_worktrees needs, with no real network).
ws_env() {
  WS_HOME=$(new_home)
  WS_HOME=${WS_HOME//\/\//\/}   # TMPDIR ending in / must not leave // in paths (same fix as test-rotate-logs.sh)
  WS_BIN="$WS_HOME/bin"; ws_install_gh "$WS_BIN"
  WS_REPO="$WS_HOME/repo"; mkdir -p "$WS_REPO"
  # `git worktree list --porcelain` prints the fully resolved (symlink-free) path — on macOS $TMPDIR is itself a
  # /var -> /private/var symlink, so WS_REPO must be resolved the same way or sweep_stale_worktrees's own
  # "$path starts with $local_path/.worktrees/" prefix match (pipeline-lib.sh) never fires.
  WS_REPO=$(cd "$WS_REPO" && pwd -P)
  ( cd "$WS_REPO" && git init -q -b main \
      && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init \
      && git remote add origin "https://github.com/$WS_OWNER_REPO.git" ) >/dev/null 2>&1
  git -C "$WS_REPO" update-ref refs/remotes/origin/main "$(git -C "$WS_REPO" rev-parse main)"
}

# ws_add_worktree <branch> [dir] — a clean worktree at .worktrees/<dir|branch>, cut from main (no uncommitted work,
# no commits of its own — irrelevant here since every case's `gh pr list` reports a merged PR, which bypasses that
# ancestor/fresh check entirely, same as the real sweep does for a real squash-merged branch).
ws_add_worktree() {
  git -C "$WS_REPO" worktree add -q ".worktrees/${2:-$1}" -b "$1" main >/dev/null 2>&1
}

# ws_run [extra shell…] — runs sweep_stale_worktrees against WS_REPO via the fake gh; sets WS_ERR (stderr, which is
# where the fallback slog() writes with no SLOG set) and WS_RC (the function's own exit status).
ws_run() {
  WS_ERR=$(cd "$WS_REPO" && HOME="$WS_HOME" PATH="$WS_BIN:$PATH" bash -c '
    set -u
    . "'"$PLS_WS"'"
    DISPATCH_REPOS=("'"$WS_OWNER_REPO"':'"$WS_REPO"'")
    '"${1:-}"'
    sweep_stale_worktrees
  ' 2>&1 1>/dev/null); WS_RC=$?
}

ws_teardown() { git -C "$WS_REPO" worktree prune >/dev/null 2>&1; rm -rf "$WS_HOME"; }

# ---------------------------------------------------------------------------------------------- AC1: open issue survives

test_ws_open_issue_worktree_never_removed_even_though_pr_merged() {
  ws_env
  echo OPEN > "$WS_BIN/gh-issue-state-10"
  ws_add_worktree issue-10-foo
  local r=0
  ws_run
  assert_exit0 "$WS_RC" "AC1: sweep itself must still exit 0" || r=1
  assert_contains "$WS_ERR" "issue #10 is OPEN" "AC1: logs the OPEN skip" || r=1
  assert_contains "$WS_ERR" "environment=" "AC1: skip line carries the environment tag" || r=1
  assert_contains "$WS_ERR" "route=worktree-sweep" "AC1: skip line carries the route tag" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-10-foo" "AC1: worktree dir still present" || r=1
  git -C "$WS_REPO" show-ref --verify --quiet refs/heads/issue-10-foo \
    || { fail "AC1: branch issue-10-foo must still exist"; r=1; }
  ws_teardown; return $r
}

# same as above, but a multi-segment suffix after the issue number (issue-10-fix-retry) — still parses to #10
test_ws_open_issue_worktree_survives_with_multi_segment_branch_suffix() {
  ws_env
  echo OPEN > "$WS_BIN/gh-issue-state-10"
  ws_add_worktree issue-10-fix-retry
  local r=0
  ws_run
  assert_contains "$WS_ERR" "issue #10 is OPEN" "AC1b: logs the OPEN skip for a multi-segment branch" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-10-fix-retry" "AC1b: worktree dir still present" || r=1
  ws_teardown; return $r
}

# bare issue-<N> (no suffix at all) also parses and survives
test_ws_open_issue_worktree_survives_with_bare_branch_name() {
  ws_env
  echo OPEN > "$WS_BIN/gh-issue-state-10"
  ws_add_worktree issue-10
  local r=0
  ws_run
  assert_contains "$WS_ERR" "issue #10 is OPEN" "AC1c: logs the OPEN skip for a bare issue-<N> branch" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-10" "AC1c: worktree dir still present" || r=1
  ws_teardown; return $r
}

# the worktree DIRECTORY name carries no issue number at all (deployer.md: "directories are issue-N-slug, branches
# may differ" — this is that mismatch in the other direction), but the BRANCH does, with a prefix
# (fix/issue-10-retry, the shape fullstack-developer's own fix-cycle branches can take) — still guarded
test_ws_open_issue_survives_when_only_the_prefixed_branch_name_maps_not_the_worktree_dir() {
  ws_env
  echo OPEN > "$WS_BIN/gh-issue-state-10"
  ws_add_worktree fix/issue-10-retry custom-dir-name
  local r=0
  ws_run
  assert_contains "$WS_ERR" "issue #10 is OPEN" "AC1d: logs the OPEN skip via the branch name alone" || r=1
  assert_file_exists "$WS_REPO/.worktrees/custom-dir-name" "AC1d: worktree dir still present" || r=1
  ws_teardown; return $r
}

# ---------------------------------------------------------------------------------------------- AC2: closed issue — unchanged good path

test_ws_closed_issue_merged_pr_no_uncommitted_removed_exactly_as_today() {
  ws_env
  echo CLOSED > "$WS_BIN/gh-issue-state-11"
  ws_add_worktree issue-11-foo
  local r=0
  ws_run
  assert_exit0 "$WS_RC" "AC2: sweep itself must exit 0 on a normal removal" || r=1
  assert_contains "$WS_ERR" "removed $WS_OWNER_REPO" "AC2: removal logged" || r=1
  assert_file_absent "$WS_REPO/.worktrees/issue-11-foo" "AC2: worktree dir gone" || r=1
  git -C "$WS_REPO" show-ref --verify --quiet refs/heads/issue-11-foo \
    && { fail "AC2: branch issue-11-foo must be deleted too"; r=1; }
  ws_teardown; return $r
}

# "MERGED" (not just "CLOSED") is also an explicit confirmed-closed state per the ticket text
test_ws_merged_state_also_counts_as_confirmed_closed() {
  ws_env
  echo MERGED > "$WS_BIN/gh-issue-state-16"
  ws_add_worktree issue-16-foo
  local r=0
  ws_run
  assert_contains "$WS_ERR" "removed $WS_OWNER_REPO" "MERGED state: removal logged" || r=1
  assert_file_absent "$WS_REPO/.worktrees/issue-16-foo" "MERGED state: worktree dir gone" || r=1
  ws_teardown; return $r
}

# ---------------------------------------------------------------------------------------------- AC3: ad hoc branch — guard does not apply

test_ws_ad_hoc_branch_not_mapped_to_issue_uses_existing_merge_logic_only() {
  ws_env
  ws_add_worktree release/2026-10-27
  local r=0
  ws_run
  assert_contains "$WS_ERR" "removed $WS_OWNER_REPO" "AC3: an ad hoc branch with a merged PR is still removed (new guard never consulted)" || r=1
  assert_not_contains "$(gh_calls "$WS_BIN")" "issue view" "AC3: gh issue view is never called for a branch with no issue number" || r=1
  assert_file_absent "$WS_REPO/.worktrees/release/2026-10-27" "AC3: worktree dir gone" || r=1
  ws_teardown; return $r
}

# ---------------------------------------------------------------------------------------------- AC4: gh lookup failure / unexpected state — fail closed

test_ws_gh_issue_view_failure_skips_never_removes() {
  ws_env
  : > "$WS_BIN/gh-issue-fail-12"
  ws_add_worktree issue-12-foo
  local r=0
  ws_run
  assert_contains "$WS_ERR" "fail-closed" "AC4: logs the fail-closed skip" || r=1
  assert_contains "$WS_ERR" "view #12" "AC4: names the issue number" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-12-foo" "AC4: worktree dir still present" || r=1
  ws_teardown; return $r
}

# a `gh` call that exits 0 but prints neither OPEN nor CLOSED/MERGED (empty, "null", or junk) must ALSO fail
# closed — it is not enough to only special-case a non-zero exit, since a flaky/odd response is not an error exit
test_ws_unparseable_state_value_fails_closed_not_removed() {
  ws_env
  printf 'null' > "$WS_BIN/gh-issue-state-17"
  ws_add_worktree issue-17-foo
  local r=0
  ws_run
  assert_contains "$WS_ERR" "fail-closed" "unparseable state: logs the fail-closed skip" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-17-foo" "unparseable state ('null'): worktree dir still present" || r=1
  ws_teardown
  ws_env
  : > "$WS_BIN/gh-issue-state-18"   # empty output (not a gh failure — exit 0, zero bytes)
  ws_add_worktree issue-18-foo
  ws_run
  assert_contains "$WS_ERR" "fail-closed" "unparseable state (empty): logs the fail-closed skip" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-18-foo" "unparseable state (empty): worktree dir still present" || r=1
  ws_teardown; return $r
}

# recurring (>1) fail-closed skips in the same tick post one throttled Slack alert; a single one does not
test_ws_repeated_fail_closed_skips_post_one_throttled_slack_alert() {
  ws_env
  : > "$WS_BIN/gh-issue-fail-13"
  : > "$WS_BIN/gh-issue-fail-14"
  ws_add_worktree issue-13-foo
  ws_add_worktree issue-14-bar
  local r=0
  WS_ERR=$(cd "$WS_REPO" && HOME="$WS_HOME" PATH="$WS_BIN:$PATH" SLACK_WEBHOOK_URL="http://127.0.0.1:1/fake-hook" bash -c '
    set -u
    . "'"$PLS_WS"'"
    curl() { printf "CURL %s\n" "$*" >> "'"$WS_HOME"'/curl-calls.log"; return 0; }
    DISPATCH_REPOS=("'"$WS_OWNER_REPO"':'"$WS_REPO"'")
    sweep_stale_worktrees
  ' 2>&1 1>/dev/null); WS_RC=$?
  assert_exit0 "$WS_RC" "repeated fail-closed skips: sweep itself must still exit 0" || r=1
  assert_eq "$(grep -c 'fail-closed' <<< "$WS_ERR")" "2" "two fail-closed skips logged" || r=1
  assert_eq "$(grep -c CURL "$WS_HOME/curl-calls.log" 2>/dev/null)" "1" "exactly one alert posted for two fail-closed skips" || r=1
  assert_contains "$(cat "$WS_HOME/curl-calls.log" 2>/dev/null)" "worktree-sweep" "the alert names worktree-sweep" || r=1
  ws_teardown; return $r
}

test_ws_single_fail_closed_skip_posts_no_slack_alert() {
  ws_env
  : > "$WS_BIN/gh-issue-fail-15"
  ws_add_worktree issue-15-foo
  local r=0
  WS_ERR=$(cd "$WS_REPO" && HOME="$WS_HOME" PATH="$WS_BIN:$PATH" SLACK_WEBHOOK_URL="http://127.0.0.1:1/fake-hook" bash -c '
    set -u
    . "'"$PLS_WS"'"
    curl() { printf "CURL %s\n" "$*" >> "'"$WS_HOME"'/curl-calls.log"; return 0; }
    DISPATCH_REPOS=("'"$WS_OWNER_REPO"':'"$WS_REPO"'")
    sweep_stale_worktrees
  ' 2>&1 1>/dev/null); WS_RC=$?
  assert_exit0 "$WS_RC" "single fail-closed skip: sweep itself must still exit 0" || r=1
  assert_eq "$([ -f "$WS_HOME/curl-calls.log" ] && grep -c CURL "$WS_HOME/curl-calls.log" || echo 0)" "0" "a single fail-closed skip alerts no one (avoid alert spam on one blip)" || r=1
  ws_teardown; return $r
}

# ---------------------------------------------------------------------------------------------- AC5: dry run never removes

test_ws_dry_run_open_issue_still_skipped_nothing_removed() {
  ws_env
  echo OPEN > "$WS_BIN/gh-issue-state-20"
  ws_add_worktree issue-20-foo
  local r=0
  ws_run 'WORKTREE_SWEEP_DRY_RUN=1'
  assert_contains "$WS_ERR" "would-skip $WS_REPO/.worktrees/issue-20-foo: issue #20 is OPEN" "AC5a: logs would-skip (not skipped) under dry run" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-20-foo" "AC5a: worktree dir still present under dry run" || r=1
  ws_teardown; return $r
}

test_ws_dry_run_fail_closed_still_skipped_nothing_removed() {
  ws_env
  : > "$WS_BIN/gh-issue-fail-21"
  ws_add_worktree issue-21-foo
  local r=0
  ws_run 'WORKTREE_SWEEP_DRY_RUN=1'
  assert_contains "$WS_ERR" "would-skip $WS_REPO/.worktrees/issue-21-foo: gh issue view #21" "AC5b: logs would-skip (not skipped) for the fail-closed path under dry run" || r=1
  assert_contains "$WS_ERR" "fail-closed" "AC5b: still names it fail-closed under dry run" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-21-foo" "AC5b: worktree dir still present under dry run" || r=1
  ws_teardown; return $r
}

test_ws_dry_run_closed_issue_would_remove_only_logs_no_removal() {
  ws_env
  echo CLOSED > "$WS_BIN/gh-issue-state-22"
  ws_add_worktree issue-22-foo
  local r=0
  ws_run 'WORKTREE_SWEEP_DRY_RUN=1'
  assert_contains "$WS_ERR" "would-remove $WS_OWNER_REPO" "AC5c: would-remove logged, never removed" || r=1
  assert_file_exists "$WS_REPO/.worktrees/issue-22-foo" "AC5c: worktree dir still present under dry run" || r=1
  ws_teardown; return $r
}

# ---------------------------------------------------------------------------------------------- observability: no secrets

test_ws_no_secrets_or_webhook_url_in_slog_output() {
  ws_env
  : > "$WS_BIN/gh-issue-fail-30"
  ws_add_worktree issue-30-foo
  local r=0
  WS_ERR=$(cd "$WS_REPO" && HOME="$WS_HOME" PATH="$WS_BIN:$PATH" SLACK_WEBHOOK_URL="http://127.0.0.1:1/FAKE-HOOK-PATH" bash -c '
    set -u
    . "'"$PLS_WS"'"
    curl() { return 0; }
    DISPATCH_REPOS=("'"$WS_OWNER_REPO"':'"$WS_REPO"'")
    sweep_stale_worktrees
  ' 2>&1 1>/dev/null)
  assert_not_contains "$WS_ERR" "FAKE-HOOK-PATH" "no webhook URL leaks into the logged text" || r=1
  ws_teardown; return $r
}

for t in test_ws_open_issue_worktree_never_removed_even_though_pr_merged \
  test_ws_open_issue_worktree_survives_with_multi_segment_branch_suffix \
  test_ws_open_issue_worktree_survives_with_bare_branch_name \
  test_ws_open_issue_survives_when_only_the_prefixed_branch_name_maps_not_the_worktree_dir \
  test_ws_closed_issue_merged_pr_no_uncommitted_removed_exactly_as_today \
  test_ws_merged_state_also_counts_as_confirmed_closed \
  test_ws_ad_hoc_branch_not_mapped_to_issue_uses_existing_merge_logic_only \
  test_ws_gh_issue_view_failure_skips_never_removes \
  test_ws_unparseable_state_value_fails_closed_not_removed \
  test_ws_repeated_fail_closed_skips_post_one_throttled_slack_alert \
  test_ws_single_fail_closed_skip_posts_no_slack_alert \
  test_ws_dry_run_open_issue_still_skipped_nothing_removed \
  test_ws_dry_run_fail_closed_still_skipped_nothing_removed \
  test_ws_dry_run_closed_issue_would_remove_only_logs_no_removal \
  test_ws_no_secrets_or_webhook_url_in_slog_output; do
  run_test "$t"
done
