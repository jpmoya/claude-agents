# Code sync guard (docs/host-sync.md): fresh / updated (fast-forward) / stale (refuse to launch).
HERE_CS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cs_fixture() {  # cs_fixture -> $CSD with origin (bare), upstream (pusher), host (clone with code-sync.sh)
  CSD=$(mktemp -d "${TMPDIR:-/tmp}/cs-test.XXXXXX")
  git init -q --bare -b main "$CSD/origin.git"
  git clone -q "$CSD/origin.git" "$CSD/up" 2>/dev/null
  ( cd "$CSD/up" && git config user.email t@t && git config user.name t && mkdir -p skills/orchestrate \
    && cp "$HERE_CS/../code-sync.sh" skills/orchestrate/ && git add -A && git commit -qm base && git push -q origin HEAD:main )
  git clone -q "$CSD/origin.git" "$CSD/host" 2>/dev/null
  ( cd "$CSD/host" && git config user.email t@t && git config user.name t )
}
cs_push() { ( cd "$CSD/up" && echo "$1" >> f && git add -A && git commit -qm "$1" && git push -q origin HEAD:main ); }
cs_run() { ( cd "$CSD/host/skills/orchestrate" && ./code-sync.sh check 2>/dev/null ); }
cs_apply() { ( cd "$CSD/host/skills/orchestrate" && ./code-sync.sh apply 2>/dev/null ); }

test_code_sync_fresh_when_equal() {
  cs_fixture; assert_eq "$(cs_run)" fresh "equal -> fresh"
}
test_code_sync_behind_is_fixable_and_check_does_not_merge() {
  cs_fixture; cs_push one; assert_eq "$(cs_run)" fixable "behind clean main -> fixable"
  assert_ne "$(git -C "$CSD/host" rev-parse HEAD)" "$(git -C "$CSD/up" rev-parse HEAD)" "check does not merge"
}
test_code_sync_apply_fast_forwards() {
  cs_fixture; cs_push one; cs_run >/dev/null; cs_apply >/dev/null
  assert_eq "$(git -C "$CSD/host" rev-parse HEAD)" "$(git -C "$CSD/up" rev-parse HEAD)" "host at origin/main after apply"
  assert_eq "$(cs_run)" fresh "fresh after apply"
}
test_code_sync_other_branch_clean_is_fixable_and_apply_returns_to_main() {
  cs_fixture; ( cd "$CSD/host" && git checkout -q -b feature ); cs_push one
  assert_eq "$(cs_run)" fixable "clean feature branch -> fixable"; cs_apply >/dev/null
  assert_eq "$(git -C "$CSD/host" branch --show-current)" main "back on main"
}
test_code_sync_stale_with_unpushed_commit_on_branch() {
  cs_fixture; ( cd "$CSD/host" && git checkout -q -b feature && echo l >> g && git add -A && git commit -qm local ); cs_push one
  assert_eq "$(cs_run)" stale "unpushed work on another branch -> stale"
}
test_code_sync_stale_when_dirty_tracked_tree() {
  cs_fixture; cs_push one; echo x >> "$CSD/host/skills/orchestrate/code-sync.sh"
  assert_eq "$(cs_run)" stale "dirty tracked file -> stale"
}
test_code_sync_offline_is_not_stale() {
  cs_fixture; mv "$CSD/origin.git" "$CSD/gone.git"; assert_eq "$(cs_run)" fresh "fetch failure keeps last known state"
}

run_test test_code_sync_fresh_when_equal
run_test test_code_sync_behind_is_fixable_and_check_does_not_merge
run_test test_code_sync_apply_fast_forwards
run_test test_code_sync_other_branch_clean_is_fixable_and_apply_returns_to_main
run_test test_code_sync_stale_with_unpushed_commit_on_branch
run_test test_code_sync_stale_when_dirty_tracked_tree
run_test test_code_sync_offline_is_not_stale
