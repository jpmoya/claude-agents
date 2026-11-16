# skills/orchestrate/verify-shipped.sh — "done means on main + green prod deploy" (JP, 2026-11-16).
# Each case builds a throwaway git "GitHub" (a local repo with main + staging) and a fake gh that serves canned PR/files/runs JSON;
# the host's real GitHub, clone cache and state are never touched. Prefix vs_ / VS_ (all tests share one shell).

HERE_VS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_VS=$(cd "$HERE_VS/../../.." && pwd)
SCRIPT_VS="$ROOT_VS/skills/orchestrate/verify-shipped.sh"

vs_git() { git -C "$VS_D/remote" -c user.email=t@example.invalid -c user.name=t "$@"; }

vs_setup() {  # a remote with main (a.txt, old.txt) and staging (one extra commit per case, made by the case)
  VS_D=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-vs.XXXXXX")
  mkdir -p "$VS_D/remote" "$VS_D/gh"
  git init -q "$VS_D/remote" && vs_git checkout -q -b main
  vs_git config uploadpack.allowAnySHA1InWant true
  printf 'a\n' > "$VS_D/remote/a.txt"; printf 'old\n' > "$VS_D/remote/old.txt"
  vs_git add -A && vs_git commit -q -m base
  VS_BASE_SHA=$(vs_git rev-parse HEAD)
  vs_git checkout -q -b staging
  cat > "$VS_D/gh/gh" <<'EOF'
#!/bin/bash
# fake gh: serves $VS_FIX/<kind>.json for the one REST path it is given; counts calls
p=""; for a in "$@"; do case "$a" in repos/*) p=$a ;; esac; done
printf '%s\n' "$p" >> "$VS_FIX/calls.log"
case "$p" in
  repos/*/pulls/*/files*) n=${p#*/pulls/}; n=${n%%/*}; cat "$VS_FIX/files-$n.json" ;;
  repos/*/pulls/*) n=${p#*/pulls/}; cat "$VS_FIX/pull-$n.json" 2>/dev/null || exit 1 ;;
  repos/*/actions/*runs*) cat "$VS_FIX/runs.json" 2>/dev/null || echo '{"workflow_runs":[]}' ;;
  *) echo "fake gh: unexpected $p" >&2; exit 1 ;;
esac
EOF
  chmod +x "$VS_D/gh/gh"
}

vs_cleanup() { rm -rf "$VS_D"; }

# vs_pr <n> <merged true|false> <merge sha> <status:path>...   (e.g. added:feature.txt removed:old.txt)
vs_pr() {
  local n=$1 merged=$2 sha=$3 spec files="[]"
  shift 3
  for spec in "$@"; do
    files=$(printf '%s' "$files" | jq -c --arg s "${spec%%:*}" --arg f "${spec#*:}" '. + [{status:$s, filename:$f}]')
  done
  jq -nc --argjson m "$merged" --arg sha "$sha" '{merged:$m, merge_commit_sha:$sha}' > "$VS_D/gh/pull-$n.json"
  printf '%s\n' "$files" > "$VS_D/gh/files-$n.json"
}

# vs_run <args…> -> VS_OUT (stdout+stderr), returns the script's exit code
vs_run() {
  VS_OUT=$(env VS_GH="$VS_D/gh/gh" VS_FIX="$VS_D/gh" VS_REMOTE="$VS_D/remote" VS_GIT_DIR="$VS_D/cache.git" \
    bash "$SCRIPT_VS" example-owner/project-a "$@" 2>&1)
}

# vs_runs <status> <conclusion> <head sha> — the latest prod deploy run on main
vs_runs() {
  jq -nc --arg s "$1" --arg c "$2" --arg h "$3" \
    '{workflow_runs:[{id:555, name:"Deploy to Vercel", path:".github/workflows/deploy.yml", status:$s, conclusion:(if $c == "" then null else $c end), head_sha:$h},
                     {id:1, name:"CI", path:".github/workflows/ci.yml", status:"completed", conclusion:"failure", head_sha:"0000000"}]}' > "$VS_D/gh/runs.json"
}

# staging gets feature.txt; prints the staging commit sha
vs_staging_feature() {
  printf 'feature\n' > "$VS_D/remote/feature.txt"
  vs_git add -A && vs_git commit -q -m "feature on staging"
  vs_git rev-parse HEAD
}

test_vs_staging_merged_not_on_main_is_not_shipped() {
  vs_setup
  local s; s=$(vs_staging_feature)
  vs_pr 1 true "$s" added:feature.txt
  vs_run --no-deploy 1; local rc=$?
  assert_eq "$rc" "1" "staging-only change must fail" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "example-owner/project-a#1: NOT SHIPPED (feature.txt" "names the missing file" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_cherry_picked_with_new_sha_is_shipped() {
  vs_setup
  local s m; s=$(vs_staging_feature)
  vs_git checkout -q main
  printf 'unrelated\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"   # so the pick cannot fast-forward
  vs_git cherry-pick "$s" >/dev/null 2>&1
  m=$(vs_git rev-parse HEAD)
  assert_ne "$m" "$s" "the cherry-pick has a new SHA" || { vs_cleanup; return 1; }
  vs_pr 1 true "$s" added:feature.txt
  vs_run --no-deploy 1; local rc=$?
  assert_eq "$rc" "0" "same content on main under a new SHA is shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "example-owner/project-a#1: SHIPPED" "reports SHIPPED" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_deleted_file_still_on_main_is_not_shipped() {
  vs_setup
  vs_git rm -q old.txt && vs_git commit -q -m "delete old on staging"
  local d; d=$(vs_git rev-parse HEAD)
  vs_pr 2 true "$d" removed:old.txt
  vs_run --no-deploy 2; local rc=$?
  assert_eq "$rc" "1" "a deletion not on main fails" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (old.txt (still on main))" "names the file still on main" || { vs_cleanup; return 1; }
  # once main drops it too, it is shipped
  vs_git checkout -q main && vs_git cherry-pick "$d" >/dev/null 2>&1
  vs_run --no-deploy 2; rc=$?
  assert_eq "$rc" "0" "deletion on main is shipped" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_modified_file_with_different_content_on_main_is_not_shipped() {
  vs_setup
  printf 'new a\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "modify a on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main && printf 'other a\n' > "$VS_D/remote/a.txt" && vs_git commit -q -am "different a on main"
  vs_pr 3 true "$s" modified:a.txt
  vs_run --no-deploy 3; local rc=$?
  assert_eq "$rc" "1" "different content on main fails" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the differing file" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_file_changed_again_by_a_later_pr_is_still_shipped() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v1 on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  printf 'v2 from a later PR\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v2 on main"
  vs_pr 5 true "$s" modified:a.txt
  vs_run --no-deploy 5; local rc=$?
  assert_eq "$rc" "0" "a later change to the same file does not unship the earlier PR" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_not_on_main_beats_deploy_pending_in_the_exit_code() {
  vs_setup
  local s; s=$(vs_staging_feature)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  vs_pr 1 true "$s" added:feature.txt
  vs_pr 2 true "$s" added:nowhere.txt
  vs_run 1 2; local rc=$?   # no deploy run: PR 1 is DEPLOY PENDING, PR 2 is NOT SHIPPED
  assert_eq "$rc" "1" "NOT SHIPPED wins over DEPLOY PENDING" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_unmerged_pr_is_not_shipped() {
  vs_setup
  vs_pr 4 false "" added:feature.txt
  vs_run --no-deploy 4; local rc=$?
  assert_eq "$rc" "1" "unmerged PR" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (PR is not merged)" "says why" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_deploy_states() {
  vs_setup
  local s m; s=$(vs_staging_feature)
  vs_git checkout -q main
  m0=$(vs_git rev-parse HEAD)
  vs_git cherry-pick "$s" >/dev/null 2>&1; m=$(vs_git rev-parse HEAD)
  vs_pr 1 true "$s" added:feature.txt
  # no deploy run at all
  vs_run 1; local rc=$?
  assert_eq "$rc" "2" "no deploy run is pending" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "DEPLOY PENDING" "pending line" || { vs_cleanup; return 1; }
  # a green deploy of an older main commit (predates the change)
  vs_runs completed success "$m0"
  vs_run 1; rc=$?
  assert_eq "$rc" "2" "green deploy that predates the change is pending" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "predates this change" "says it predates" || { vs_cleanup; return 1; }
  # running
  vs_runs in_progress "" "$m"
  vs_run 1; rc=$?
  assert_eq "$rc" "2" "running deploy is pending" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "DEPLOY PENDING" "running is pending" || { vs_cleanup; return 1; }
  # failed
  vs_runs completed failure "$m"
  vs_run 1; rc=$?
  assert_eq "$rc" "2" "failed deploy" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "DEPLOY FAILED" "failed line" || { vs_cleanup; return 1; }
  # green on a commit that carries the change
  vs_runs completed success "$m"
  vs_run 1; rc=$?
  assert_eq "$rc" "0" "green deploy covering the change" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#1: SHIPPED" "shipped" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_not_on_main_beats_a_green_deploy() {
  vs_setup
  local s; s=$(vs_staging_feature)
  vs_runs completed success "$VS_BASE_SHA"
  vs_pr 1 true "$s" added:feature.txt
  vs_run 1; local rc=$?
  assert_eq "$rc" "1" "not on main stays NOT SHIPPED even with a green deploy" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_one_line_per_pr_and_frugal_gh_calls() {
  vs_setup
  local s; s=$(vs_staging_feature)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  vs_pr 1 true "$s" added:feature.txt
  vs_pr 2 true "$s" added:missing-everywhere.txt
  vs_run --no-deploy 1 2; local rc=$?
  assert_eq "$rc" "1" "one bad PR fails the run" || { vs_cleanup; return 1; }
  assert_eq "$(printf '%s\n' "$VS_OUT" | grep -c '^example-owner/project-a#')" "2" "one line per PR" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#1: SHIPPED" "first PR" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#2: NOT SHIPPED (missing-everywhere.txt" "second PR" || { vs_cleanup; return 1; }
  assert_eq "$(wc -l < "$VS_D/gh/calls.log" | tr -d ' ')" "4" "two gh calls per PR, none for the deploy with --no-deploy" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_usage_errors_exit_3() {
  vs_setup
  vs_run; local rc=$?
  assert_eq "$rc" "3" "no PR numbers" || { vs_cleanup; return 1; }
  vs_run abc; rc=$?
  assert_eq "$rc" "3" "bad PR number" || { vs_cleanup; return 1; }
  vs_cleanup
}

run_test test_vs_staging_merged_not_on_main_is_not_shipped
run_test test_vs_cherry_picked_with_new_sha_is_shipped
run_test test_vs_deleted_file_still_on_main_is_not_shipped
run_test test_vs_modified_file_with_different_content_on_main_is_not_shipped
run_test test_vs_file_changed_again_by_a_later_pr_is_still_shipped
run_test test_vs_not_on_main_beats_deploy_pending_in_the_exit_code
run_test test_vs_unmerged_pr_is_not_shipped
run_test test_vs_deploy_states
run_test test_vs_not_on_main_beats_a_green_deploy
run_test test_vs_one_line_per_pr_and_frugal_gh_calls
run_test test_vs_usage_errors_exit_3
