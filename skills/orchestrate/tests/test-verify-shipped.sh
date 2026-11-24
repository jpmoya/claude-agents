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

# vs_pr <n> <merged true|false> <merge sha> <status:path>...   (e.g. added:feature.txt removed:old.txt); VS_PR_TITLE sets
# the PR's title; VS_PR_BASE sets its base.ref (default "staging", as on the real repos — every fixture carries one).
vs_pr() {
  local n=$1 merged=$2 sha=$3 spec files="[]"
  shift 3
  for spec in "$@"; do
    files=$(printf '%s' "$files" | jq -c --arg s "${spec%%:*}" --arg f "${spec#*:}" '. + [{status:$s, filename:$f}]')
  done
  jq -nc --argjson m "$merged" --arg sha "$sha" --arg t "${VS_PR_TITLE:-}" --arg base "${VS_PR_BASE:-staging}" \
    '{merged:$m, merge_commit_sha:$sha, base:{ref:$base}} + (if $t == "" then {} else {title:$t} end)' > "$VS_D/gh/pull-$n.json"
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

# #822: a main commit names the PR but the squash picked up staging's CURRENT tree, which had already renamed the PR's file —
# the squash commit's diff never touches the original path at all. "Moved on" is judged against the PR's base branch
# (PR_BASE_REF, here "staging"): staging itself renamed the file with a plain (non-revert) commit, and the renamed-to blob
# is actually present on main (under its new name) — not just "staging moved it somewhere", which could still be a real drop.
test_vs_renamed_on_base_before_promotion_is_shipped() {
  vs_setup
  printf 'feature\n' > "$VS_D/remote/feature.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git mv feature.txt renamed.txt && vs_git commit -q -m "rename feature to renamed on staging"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'feature\n' > "$VS_D/remote/renamed.txt"; vs_git add -A && vs_git commit -q -m "release v1.3.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:feature.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "0" "renamed on staging before promotion, same content under the new name on main: shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#7: SHIPPED" "reports SHIPPED" || { vs_cleanup; return 1; }
  vs_cleanup
}

# Negative counterpart: staging renamed the file (a non-revert commit deletes the old path), but the renamed-to content never
# actually reached main — the naming commit carries some unrelated file, not the rename. A bare "staging deleted the old path"
# must not be read as "shipped"; the exact content must be found on main too.
test_vs_renamed_on_base_but_never_promoted_is_not_shipped() {
  vs_setup
  printf 'feature\n' > "$VS_D/remote/feature.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git mv feature.txt renamed.txt && vs_git commit -q -m "rename feature to renamed on staging"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'something unrelated\n' > "$VS_D/remote/unrelated.txt"; vs_git add -A && vs_git commit -q -am "release v1.3.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:feature.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "staging renamed it, but the content never reached main: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (feature.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# code-reviewer (#824 FAIL): a PLAIN deletion on the base branch (git rm, not a rename) must not pass just because main happens
# to hold some UNRELATED file with an identical blob (e.g. two empty files, or duplicate boilerplate) — that coincidence is not
# proof the base branch's drop ever reached main. Staging adds an empty placeholder.txt then plain-deletes it (no mv); main has
# an unrelated empty file plus a naming commit that never touches placeholder.txt at all. Must read NOT SHIPPED, not SHIPPED.
test_vs_plain_deletion_on_base_coincidental_blob_on_main_is_not_shipped() {
  vs_setup
  : > "$VS_D/remote/placeholder.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git rm -q placeholder.txt && vs_git commit -q -m "drop placeholder.txt from staging (not a rename)"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  : > "$VS_D/remote/unrelated-empty.txt"; vs_git add -A && vs_git commit -q -am "release v1.9.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:placeholder.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "plain drop on staging; main's identical blob elsewhere is an unrelated coincidence: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (placeholder.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# Non-empty sibling of the case above: confirms the cycle-1 HIGH fix (a plain drop — deletion with no add in the SAME commit —
# never pairs as a rename, whatever the content) still holds on its own, independent of the $EMPTY_BLOB guard added in fix
# cycle 2 (which would otherwise mask this case, since the guard alone now short-circuits every empty-file example before
# diff-tree even runs). Also exercises rename_target's parser on a plain "D <path>" (single-field, non-rename) diff-tree entry.
test_vs_plain_deletion_on_base_coincidental_nonempty_blob_on_main_is_not_shipped() {
  vs_setup
  printf 'boilerplate\n' > "$VS_D/remote/placeholder.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git rm -q placeholder.txt && vs_git commit -q -m "drop placeholder.txt from staging (not a rename)"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'boilerplate\n' > "$VS_D/remote/unrelated-boilerplate.txt"; vs_git add -A && vs_git commit -q -am "release v1.9.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:placeholder.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "plain drop (non-empty content), no add in the same commit: not a rename, main's identical blob elsewhere is coincidence: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (placeholder.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# code-reviewer (#824 second HIGH, fix cycle 2): git's own -M rename detection treats two EMPTY files as 100% similar by
# definition (there is no content to differ), so a SINGLE commit that deletes one empty file and ALSO adds a different,
# unrelated empty file reads as a rename to git itself — unlike the plain-deletion case above, here rename_target's underlying
# diff-tree -M genuinely reports "R100 placeholder.txt -> other-empty.txt". Staging adds placeholder.txt (empty) for the PR, then
# one later commit deletes placeholder.txt and adds an unrelated other-empty.txt (both empty); main's naming commit never
# touches placeholder.txt (promoted_blob falls back) but happens to also hold an other-empty.txt with the same (empty) content.
# Trusting the rename here would wrongly confirm it and report SHIPPED; "same empty content" proves nothing. Must read NOT SHIPPED.
test_vs_rename_detection_on_two_empty_files_is_not_shipped() {
  vs_setup
  : > "$VS_D/remote/placeholder.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git rm -q placeholder.txt
  : > "$VS_D/remote/other-empty.txt"; vs_git add -A && vs_git commit -q -m "unrelated cleanup on staging (deletes and adds in one commit)"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  : > "$VS_D/remote/other-empty.txt"; vs_git add -A && vs_git commit -q -am "release v1.9.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:placeholder.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "git's -M detector matched two unrelated empty files as a rename; same empty content proves nothing: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (placeholder.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# code-reviewer (#824 LOW, fix cycle 2): git's default --name-status quotes non-ASCII paths (wraps them in quotes with octal
# escapes), so a naive rename_target that compares <path> against that quoted form would fail to match a REAL rename whose old
# path has a non-ASCII filename, and wrongly report NOT SHIPPED (fail-closed, but still wrong). Staging legitimately renames a
# non-ASCII-named file before promotion, exactly like the ASCII case above. Must still read SHIPPED.
test_vs_renamed_on_base_with_non_ascii_filename_is_shipped() {
  vs_setup
  printf 'feature\n' > "$VS_D/remote/café.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git mv café.txt renamed.txt && vs_git commit -q -m "rename café to renamed on staging"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'feature\n' > "$VS_D/remote/renamed.txt"; vs_git add -A && vs_git commit -q -m "release v1.3.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:café.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "0" "renamed non-ASCII filename on staging before promotion, same content under the new name on main: shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#7: SHIPPED" "reports SHIPPED" || { vs_cleanup; return 1; }
  vs_cleanup
}

# Parser robustness: the deleting/renaming commit on the base branch also touches an unrelated file in the SAME commit, so
# rename_target's diff-tree -M output carries more than one entry (an "M a.txt" row alongside the "R feature.txt -> renamed.txt"
# row — "a.txt" sorts before "feature.txt", so the non-rename row comes first). The read -d '' state machine must skip the
# unrelated single-path entry and still find the rename among several rows, not just the first one. Must still read SHIPPED.
test_vs_renamed_on_base_alongside_other_changes_in_same_commit_is_shipped() {
  vs_setup
  printf 'feature\n' > "$VS_D/remote/feature.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git mv feature.txt renamed.txt
  printf 'a changed\n' > "$VS_D/remote/a.txt"
  vs_git add -A && vs_git commit -q -m "rename feature to renamed on staging, alongside an unrelated a.txt edit"
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'feature\n' > "$VS_D/remote/renamed.txt"; vs_git add -A && vs_git commit -q -m "release v1.4.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:feature.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "0" "rename shares a commit with an unrelated edit; the parser must still find it among several diff-tree rows: shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "#7: SHIPPED" "reports SHIPPED" || { vs_cleanup; return 1; }
  vs_cleanup
}

# The base-branch fallback is gated on a main commit actually naming the PR (promoted_blob's exit status 2). Here main holds
# the exact renamed-to content AND staging legitimately renamed the file (both of which, on their own, the fallback would
# accept) — but NO main commit mentions PR 7 at all, so the fallback must never run and behaviour must stay exactly as
# before #822: still NOT SHIPPED.
test_vs_renamed_on_base_and_present_on_main_but_no_naming_commit_is_not_shipped() {
  vs_setup
  printf 'feature\n' > "$VS_D/remote/feature.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git mv feature.txt renamed.txt && vs_git commit -q -m "rename feature to renamed on staging"
  vs_git checkout -q main
  printf 'feature\n' > "$VS_D/remote/renamed.txt"; vs_git add -A && vs_git commit -q -m "add renamed.txt (unrelated to any PR)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:feature.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "no main commit names (#7): the fallback never runs, even though main happens to hold the content" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (feature.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# A cherry-pick trailer names the PR but the picked commit is a no-op for this file (main already holds a LATER staging
# rewrite of the same path from an earlier, unrelated sync) — promoted_blob skips it as "unchanged vs parent". The base
# branch's own history shows the later rewrite came after the PR's commit, so it is moved on, not dropped.
test_vs_cherry_pick_noop_because_main_already_has_a_later_rewrite_is_shipped() {
  vs_setup; vs_multiline_base
  sed -i.bak 's/^line12$/line12 changed by the PR/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12 rewritten by staging\n' > "$VS_D/remote/a.txt"
  vs_git commit -q -am "staging rewrites a.txt again"
  vs_git checkout -q main
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12 rewritten by staging\n' > "$VS_D/remote/a.txt"
  vs_git commit -q -am "already synced a.txt from staging"
  printf 'marker\n' > "$VS_D/remote/cp-marker.txt"; vs_git add -A
  vs_git commit -q -am "cherry pick marker

(cherry picked from commit $s)"
  vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "0" "main already holds a later staging rewrite of the same path: shipped" || { vs_cleanup; return 1; }
  vs_cleanup
}

# #822 AC: a squash commit NAMES the PR by its title bullet (not a cherry-pick trailer) and does not carry the file at all
# (the path does not exist on main yet) — the content later reaches main through a SEPARATE, non-naming commit that just
# happens to match what staging had rewritten the file to. Shipped.
test_vs_squash_by_title_lacks_file_later_plain_commit_adds_staging_rewrite_is_shipped() {
  vs_setup
  printf 'v1 by the PR\n' > "$VS_D/remote/newfile.txt"; vs_git add -A && vs_git commit -q -m "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  printf 'v2 rewritten by staging\n' > "$VS_D/remote/newfile.txt"; vs_git commit -q -am "staging rewrites newfile.txt"
  vs_git checkout -q main
  printf 'squash marker\n' > "$VS_D/remote/squash-marker.txt"; vs_git add -A && vs_git commit -q -m "release v1.5.0 (#20)

* feature on staging (#7)"
  printf 'v2 rewritten by staging\n' > "$VS_D/remote/newfile.txt"; vs_git add -A && vs_git commit -q -m "unrelated later sync of newfile.txt"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:newfile.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "0" "the naming squash lacked the file; a later plain commit's content matches staging's rewrite: shipped" || { vs_cleanup; return 1; }
  vs_cleanup
}

# #822 negative (AC): the naming commit exists, but staging's later change that superseded the PR's content never reached
# main at all — main still holds the PRE-PR version. in_history on the base branch must see "got" as an ancestor of "want"
# (an earlier version) and refuse to call it moved on, exactly as it already does when checked against main's own history.
test_vs_named_but_main_still_holds_the_pre_pr_version_is_not_shipped() {
  vs_setup; vs_multiline_base
  sed -i.bak 's/^line12$/line12 changed by the PR/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12 superseded by staging\n' > "$VS_D/remote/a.txt"
  vs_git commit -q -am "staging supersedes it again, never promoted"
  vs_git checkout -q main
  printf 'squash marker\n' > "$VS_D/remote/squash-marker.txt"; vs_git add -A && vs_git commit -q -m "release v1.6.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "main still holds the pre-PR version; staging's later change never reached main: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# #822: in_history on the base branch alone only proves "got" is not an EARLIER version of "want" — it does not prove the base
# branch ever produced "got" at all. Here main's content for a.txt is a main-only edit staging never held, before or after the
# PR's commit; in_history(base) would pass (it just isn't found as an ancestor), so held_after must catch it.
test_vs_main_only_content_never_held_by_base_is_not_shipped() {
  vs_setup; vs_multiline_base
  sed -i.bak 's/^line12$/line12 changed by the PR/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "feature on staging"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git checkout -q main
  sed -i.bak 's/^line12$/line12 invented independently on main/' "$VS_D/remote/a.txt" && rm -f "$VS_D/remote/a.txt.bak"
  vs_git commit -q -am "main's own independent edit, never on staging"
  printf 'squash marker\n' > "$VS_D/remote/squash-marker.txt"; vs_git add -A && vs_git commit -q -m "release v1.7.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" modified:a.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "main's content was never produced by the base branch at all: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (a.txt (differs on main))" "names the file" || { vs_cleanup; return 1; }
  vs_cleanup
}

# Negative: the PR's change was reverted on staging (a real "Revert" commit, not a plain move) before any promotion; a later
# main commit names the PR but does not carry the file. The base-branch fallback must see the revert and refuse to call it
# moved on.
test_vs_reverted_on_base_then_named_by_main_is_not_shipped() {
  vs_setup
  printf 'feature\n' > "$VS_D/remote/feature.txt"; vs_git add -A && vs_git commit -q -m "feature on staging (#7)"
  local s; s=$(vs_git rev-parse HEAD)
  vs_git revert --no-edit HEAD >/dev/null 2>&1
  vs_git checkout -q main
  printf 'main moved on\n' > "$VS_D/remote/other.txt"; vs_git add -A && vs_git commit -q -m "unrelated main commit"
  printf 'something unrelated\n' > "$VS_D/remote/unrelated.txt"; vs_git add -A && vs_git commit -q -am "release v1.3.0 (#20)

* feature on staging (#7)"
  VS_PR_TITLE="feature on staging" vs_pr 7 true "$s" added:feature.txt
  vs_run --no-deploy 7; local rc=$?
  assert_eq "$rc" "1" "reverted on staging before promotion: not shipped" || { vs_cleanup; return 1; }
  assert_contains "$VS_OUT" "NOT SHIPPED (feature.txt (absent on main))" "names the file" || { vs_cleanup; return 1; }
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
run_test test_vs_renamed_on_base_before_promotion_is_shipped
run_test test_vs_renamed_on_base_but_never_promoted_is_not_shipped
run_test test_vs_plain_deletion_on_base_coincidental_blob_on_main_is_not_shipped
run_test test_vs_plain_deletion_on_base_coincidental_nonempty_blob_on_main_is_not_shipped
run_test test_vs_rename_detection_on_two_empty_files_is_not_shipped
run_test test_vs_renamed_on_base_with_non_ascii_filename_is_shipped
run_test test_vs_renamed_on_base_alongside_other_changes_in_same_commit_is_shipped
run_test test_vs_renamed_on_base_and_present_on_main_but_no_naming_commit_is_not_shipped
run_test test_vs_cherry_pick_noop_because_main_already_has_a_later_rewrite_is_shipped
run_test test_vs_squash_by_title_lacks_file_later_plain_commit_adds_staging_rewrite_is_shipped
run_test test_vs_named_but_main_still_holds_the_pre_pr_version_is_not_shipped
run_test test_vs_main_only_content_never_held_by_base_is_not_shipped
run_test test_vs_reverted_on_base_then_named_by_main_is_not_shipped
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
