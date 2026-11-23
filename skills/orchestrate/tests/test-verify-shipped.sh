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
  if [ "${VS_NO_WORKFLOW:-0}" != 1 ]; then   # a repo with a prod deploy workflow, as the app repos have
    mkdir -p "$VS_D/remote/.github/workflows"; printf 'name: Deploy to Vercel\non: push\n' > "$VS_D/remote/.github/workflows/deploy.yml"
  fi
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

# vs_pr <n> <merged true|false> <merge sha> <status:path>...   (e.g. added:feature.txt removed:old.txt); VS_PR_TITLE sets the PR's title
vs_pr() {
  local n=$1 merged=$2 sha=$3 spec files="[]"
  shift 3
  for spec in "$@"; do
    files=$(printf '%s' "$files" | jq -c --arg s "${spec%%:*}" --arg f "${spec#*:}" '. + [{status:$s, filename:$f}]')
  done
  jq -nc --argjson m "$merged" --arg sha "$sha" --arg t "${VS_PR_TITLE:-}" '{merged:$m, merge_commit_sha:$sha} + (if $t == "" then {} else {title:$t} end)' > "$VS_D/gh/pull-$n.json"
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

test_vs_reverted_pr_is_not_shipped() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v1 on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  vs_pr 6 true "$s" modified:a.txt
  vs_run --no-deploy 6; local rc=$?
  assert_eq "$rc" "0" "before the revert it is shipped" || { vs_cleanup; return 1; }
  vs_git revert --no-edit HEAD >/dev/null 2>&1
  vs_run --no-deploy 6; rc=$?
  assert_eq "$rc" "1" "main went back to the earlier version: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the reverted file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# vs_multiline_base — give main (and staging, fast-forwarded) a 12-line a.txt so changes at the top and bottom merge cleanly
vs_multiline_base() {
  vs_git checkout -q main
  local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'line%s\n' "$i"; done > "$VS_D/remote/a.txt"
  vs_git commit -q -am "multiline a"
  vs_git checkout -q staging && vs_git merge -q --ff-only main
}

# #810: a PR squash-merged to staging whose content reached main only through a squash release commit naming "(#N)" in its subject, on a base
# that lacks staging's other unpromoted change to the same file — main never holds the staging merge commit's blob.
test_vs_squash_promoted_with_different_base_is_shipped() {
  vs_setup; vs_multiline_base
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nother PR line\n' > "$VS_D/remote/a.txt"
  vs_git commit -q -am "other PR on staging (#8)"
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nother PR line\nfeature line\n' > "$VS_D/remote/a.txt"
  vs_git commit -q -am "feature on staging (#7)"
  local s; s=$(vs_git rev-parse HEAD)
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "before any promotion it is not shipped" || { vs_cleanup; return 1; }
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nfeature line\n' > "$VS_D/remote/a.txt"
  vs_git commit -q -am "release v1.2.0 (#20)

* feature on staging (#7)"
  vs_run --no-deploy 7; rc=$?
  assert_eq "$rc" "0" "squash release naming (#7) ships it even though the blob differs from the staging merge commit" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#7: SHIPPED" "reports SHIPPED" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_cherry_pick_x_onto_a_different_base_is_shipped() {
  vs_setup; vs_multiline_base
  sed -i.bak 's/^line12$/line12 changed by the PR/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  sed -i.bak 's/^line1$/line1 changed on main/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "main moved on"
  vs_git cherry-pick -x "$s" >/dev/null 2>&1
  assert_eq "$(vs_git status --porcelain | wc -l | tr -d ' ')" "0" "the cherry-pick applied cleanly" || { vs_cleanup; return 1; }
  assert_ne "$(vs_git rev-parse HEAD:a.txt)" "$(vs_git rev-parse "$s:a.txt")" "blob differs from the staging merge commit's" || { vs_cleanup; return 1; }
  vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "0" "the 'cherry picked from commit' trailer ships it" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_staging_only_pr_on_a_moved_on_file_is_not_shipped() {
  vs_setup; vs_multiline_base
  sed -i.bak 's/^line12$/line12 changed by PR 7/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "feature on staging (#7)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  sed -i.bak 's/^line1$/line1 changed by PR 8/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "another feature on main (#8)"
  vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "no main commit names (#7): still NOT SHIPPED" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_pr_number_must_match_exactly() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v1 on staging (#7)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  printf 'something else\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "other work (#77) and (#70)"
  vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "(#77) and (#70) do not name PR 7" || { vs_cleanup; return 1; }
  vs_cleanup
}

# vs_named_case <subject> <body> <PR title> -> VS_RC: PR 7 modifies a.txt on staging; main rewrites a.txt in one commit with this message
vs_named_case() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "feature on staging (#7)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  printf 'main version\n' > "$VS_D/remote/a.txt"
  if [ -n "$2" ]; then vs_git commit -q -a -m "$1" -m "$2"; else vs_git commit -q -a -m "$1"; fi
  VS_PR_TITLE="$3" vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; VS_RC=$?
}

# A line that merely mentions (#7) in prose does not carry PR 7: the line must also contain the PR's title.
test_vs_subject_prose_mentioning_the_pr_is_not_shipped() {
  vs_named_case "Follow-up to (#7)" "" "feature on staging"
  assert_eq "$VS_RC" "1" "a subject without the PR's title does not carry it" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_bullet_prose_mentioning_the_pr_is_not_shipped() {
  vs_named_case "release v2 (#20)" "* Follow-up to (#7)" "feature on staging"
  assert_eq "$VS_RC" "1" "a bullet without the PR's title does not carry it" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_subject_with_the_pr_title_is_shipped_comparing_loosely() {
  vs_named_case "Feature  ON staging (#3) (#7)" "" "Feature on Staging (#3)"
  assert_eq "$VS_RC" "0" "title matched ignoring case, spacing and (#N) markers" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_bullet_with_the_pr_title_is_shipped() {
  vs_named_case "release v2 (#20)" "* feature on staging (#7)" "feature on staging"
  assert_eq "$VS_RC" "0" "squash bullet with the title carries the PR" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_pr_without_a_title_matches_only_by_trailer() {
  vs_named_case "feature on staging (#7)" "" ""
  assert_eq "$VS_RC" "1" "no title to compare: fail closed" || { vs_cleanup; return 1; }
  vs_cleanup
}

# A release body that quotes the revert marker mid-line is not a revert (only a line STARTING "This reverts commit " is git revert's own).
test_vs_release_body_quoting_the_revert_marker_still_carries_the_pr() {
  vs_named_case "release v2 (#20)" "* feature on staging (#7)
* docs: git writes \"This reverts commit <sha>\" when you revert" "feature on staging"
  assert_eq "$VS_RC" "0" "a mid-line mention does not disqualify the release commit" || { vs_cleanup; return 1; }
  vs_cleanup
}

# A main commit that mentions (#N) only in its BODY ("Follow-up to (#7)") does not carry PR 7.
test_vs_pr_number_in_a_commit_body_only_is_not_shipped() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v1 on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  printf 'something else\n' > "$VS_D/remote/a.txt"; vs_git commit -q -a -m "Unrelated change to a (#8)" -m "Follow-up to (#7), which is still only on staging."
  VS_PR_TITLE="Unrelated change to a" vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "(#7) in a body is not the PR landing on main" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# A hand-written Revert commit whose subject names the PR must not be taken as the commit that carried it.
test_vs_revert_commit_naming_the_pr_does_not_carry_it() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v1 on staging (#6)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  printf 'weird\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am 'Revert "a v1 on staging (#6)"'
  VS_PR_TITLE="a v1 on staging" vs_pr 6 true "$s" modified:a.txt
  vs_run --no-deploy 6; local rc=$?
  assert_eq "$rc" "1" "a Revert commit is never the carrier" || { vs_cleanup; return 1; }
  vs_cleanup
}

# A revert whose subject does not start with "Revert" is still a revert when the message says "This reverts commit".
test_vs_revert_with_a_custom_title_is_not_shipped() {
  vs_setup
  local s; s=$(vs_staging_feature)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  local c; c=$(vs_git rev-parse HEAD)
  vs_git rm -q feature.txt && vs_git commit -q -m "Remove the feature" -m "This reverts commit $c."
  vs_pr 1 true "$s" added:feature.txt
  vs_run --no-deploy 1; local rc=$?
  assert_eq "$rc" "1" "a deletion by a 'This reverts commit' commit is not moving on" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (feature.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_promoted_pr_reverted_on_main_is_not_shipped() {
  vs_setup
  printf 'v1\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "a v1 on staging (#6)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  printf 'other\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated"
  printf 'v1 plus promotion edits\n' > "$VS_D/remote/a.txt"; vs_git commit -q -am "release v1.0.1 (#30)

* a v1 on staging (#6)"
  VS_PR_TITLE="a v1 on staging" vs_pr 6 true "$s" modified:a.txt
  vs_run --no-deploy 6; local rc=$?
  assert_eq "$rc" "0" "before the revert it is shipped" || { vs_cleanup; return 1; }
  vs_git revert --no-edit HEAD >/dev/null 2>&1   # restores the earlier a.txt (the Revert subject quotes the release (#30), not PR 6)
  vs_run --no-deploy 6; rc=$?
  assert_eq "$rc" "1" "reverted on main: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the reverted file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# #747: a file the PR changed and a later change deleted from main moved on; it is not missing.
test_vs_file_changed_by_the_pr_and_deleted_later_is_shipped() {
  vs_setup
  printf 'old v2\n' > "$VS_D/remote/old.txt"; vs_git commit -q -am "old v2 on staging (#9)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  vs_git rm -q old.txt && vs_git commit -q -m "delete old (#10)"
  vs_pr 9 true "$s" modified:old.txt
  vs_run --no-deploy 9; local rc=$?
  assert_eq "$rc" "0" "a later deletion on main is not a failure" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_added_file_reverted_away_on_main_is_not_shipped() {
  vs_setup
  local s; s=$(vs_staging_feature)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  vs_git revert --no-edit HEAD >/dev/null 2>&1   # deletes feature.txt again
  vs_pr 1 true "$s" added:feature.txt
  vs_run --no-deploy 1; local rc=$?
  assert_eq "$rc" "1" "a file removed by a Revert commit is not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (feature.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_deleted_file_never_on_main_is_not_shipped() {
  vs_setup
  printf 'old v2\n' > "$VS_D/remote/old.txt"; vs_git commit -q -am "old v2 on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main && vs_git rm -q old.txt && vs_git commit -q -m "delete old on main"   # old.txt v2 never existed on main
  vs_pr 9 true "$s" modified:old.txt
  vs_run --no-deploy 9; local rc=$?
  assert_eq "$rc" "1" "the PR's version never reached main" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (old.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# #747: the PR's blob reached main only through a merge's SECOND parent (the merge keeps main's blob). The main-side commit is dated
# BEFORE the PR commit so a date-ordered "held before" check would wrongly call main's blob an earlier version.
test_vs_blob_reaching_main_only_via_a_second_parent_is_shipped() {
  vs_setup
  vs_git checkout -q main
  printf 'v2 main side\n' > "$VS_D/remote/a.txt"
  GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" vs_git commit -q -am "a v2 on main"
  vs_git checkout -q -b side "$VS_BASE_SHA"
  printf 'v1 pr side\n' > "$VS_D/remote/a.txt"
  GIT_AUTHOR_DATE="2021-01-01T00:00:00Z" GIT_COMMITTER_DATE="2021-01-01T00:00:00Z" vs_git commit -q -am "a v1 by the PR"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  GIT_AUTHOR_DATE="2022-01-01T00:00:00Z" GIT_COMMITTER_DATE="2022-01-01T00:00:00Z" vs_git merge -q -s ours --no-edit side >/dev/null 2>&1
  assert_eq "$(vs_git show HEAD:a.txt)" "v2 main side" "the merge kept main's blob" || { vs_cleanup; return 1; }
  vs_pr 11 true "$s" modified:a.txt
  vs_run --no-deploy 11; local rc=$?
  assert_eq "$rc" "0" "the PR's commit is in main's history through the second parent" || { vs_cleanup; return 1; }
  vs_cleanup
}

test_vs_repo_without_a_deploy_workflow_needs_no_deploy_run() {
  VS_NO_WORKFLOW=1 vs_setup
  local s; s=$(vs_staging_feature)
  vs_git checkout -q main && vs_git cherry-pick "$s" >/dev/null 2>&1
  vs_pr 1 true "$s" added:feature.txt
  vs_run 1; local rc=$?
  assert_eq "$rc" "0" "no deploy workflow: on main is enough (jpmoya/claude-agents)" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#1: SHIPPED" "shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "no prod deploy workflow" "says why the deploy was not checked" || { vs_cleanup; return 1; }
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
run_test test_vs_reverted_pr_is_not_shipped
run_test test_vs_squash_promoted_with_different_base_is_shipped
run_test test_vs_cherry_pick_x_onto_a_different_base_is_shipped
run_test test_vs_staging_only_pr_on_a_moved_on_file_is_not_shipped
run_test test_vs_pr_number_must_match_exactly
run_test test_vs_pr_number_in_a_commit_body_only_is_not_shipped
run_test test_vs_subject_prose_mentioning_the_pr_is_not_shipped
run_test test_vs_bullet_prose_mentioning_the_pr_is_not_shipped
run_test test_vs_subject_with_the_pr_title_is_shipped_comparing_loosely
run_test test_vs_bullet_with_the_pr_title_is_shipped
run_test test_vs_pr_without_a_title_matches_only_by_trailer
run_test test_vs_release_body_quoting_the_revert_marker_still_carries_the_pr
run_test test_vs_revert_commit_naming_the_pr_does_not_carry_it
run_test test_vs_revert_with_a_custom_title_is_not_shipped
run_test test_vs_promoted_pr_reverted_on_main_is_not_shipped
run_test test_vs_file_changed_by_the_pr_and_deleted_later_is_shipped
run_test test_vs_added_file_reverted_away_on_main_is_not_shipped
run_test test_vs_deleted_file_never_on_main_is_not_shipped
run_test test_vs_blob_reaching_main_only_via_a_second_parent_is_shipped
run_test test_vs_repo_without_a_deploy_workflow_needs_no_deploy_run
run_test test_vs_unmerged_pr_is_not_shipped
run_test test_vs_deploy_states
run_test test_vs_not_on_main_beats_a_green_deploy
run_test test_vs_one_line_per_pr_and_frugal_gh_calls
run_test test_vs_usage_errors_exit_3
