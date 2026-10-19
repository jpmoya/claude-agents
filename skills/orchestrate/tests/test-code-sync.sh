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
cs_run() { ( cd "$CSD/host/skills/orchestrate" && ./code-sync.sh 2>/dev/null ); }

test_code_sync_fresh_when_equal() {
  cs_fixture; local out; out=$(cs_run); assert_eq "$out" fresh "equal -> fresh"
}
test_code_sync_fast_forwards_when_behind() {
  cs_fixture; cs_push one; local out rc; out=$(cs_run); rc=$?
  assert_eq "$out" updated "behind -> updated"; assert_eq "$rc" 10 "rc 10"
  assert_eq "$(git -C "$CSD/host" rev-parse HEAD)" "$(git -C "$CSD/up" rev-parse HEAD)" "host at origin/main"
}
test_code_sync_stale_when_on_other_branch() {
  cs_fixture; ( cd "$CSD/host" && git checkout -q -b feature ); cs_push one
  local out rc; out=$(cs_run); rc=$?; assert_eq "$out" stale "feature branch behind -> stale"; assert_eq "$rc" 20 "rc 20"
}
test_code_sync_stale_when_dirty_tracked_tree() {
  cs_fixture; cs_push one; echo x >> "$CSD/host/skills/orchestrate/code-sync.sh"
  local out; out=$(cs_run); assert_eq "$out" stale "dirty tracked file -> stale"
}
test_code_sync_fresh_when_ahead_with_local_work() {
  cs_fixture; ( cd "$CSD/host" && echo l >> g && git add -A && git commit -qm local )
  local out; out=$(cs_run); assert_eq "$out" fresh "local ahead -> fresh"
}
test_code_sync_offline_is_not_stale() {
  cs_fixture; mv "$CSD/origin.git" "$CSD/gone.git"; local out; out=$(cs_run); assert_eq "$out" fresh "fetch failure keeps last known state"
}

run_test test_code_sync_fresh_when_equal
run_test test_code_sync_fast_forwards_when_behind
run_test test_code_sync_stale_when_on_other_branch
run_test test_code_sync_stale_when_dirty_tracked_tree
run_test test_code_sync_fresh_when_ahead_with_local_work
run_test test_code_sync_offline_is_not_stale
