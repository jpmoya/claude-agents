# #213 — supervisor.sh drain and dispatch treat the same issue number in two repos as independent runs.
#
#   AC3  queued/running/held/done/stopped state of one repo's #N never skips, purges or clears the
#        other repo's #N; a held run of repo-1 #703 survives a repo-2 #703 dispatch (supervisor.sh:836 path).
# Each case pairs an assertion that is red on number-keyed code ("the launched run landed at its own
# repo-keyed file") with the "other repo's state untouched" assertions, so a no-op cannot pass.
# Placeholder repos only. Bash 3.2 portable.

HERE_RK2=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_RK2/lib/runkey.sh"
SUP_RK2="$HERE_RK2/../supervisor.sh"

rk2_tick() { rk_env_run "$SUP_RK2" >/dev/null; }

rk2_sums() {  # rk2_sums <key> <N> -> checksum line over the named state files of that run
  local key=$1 n=$2 s="" f
  for f in pid repo held done stopped; do s="$s $(rk_sum "$RK_PIPE/$key-$n.$f")"; done
  printf '%s' "$s"
}

# Drain: repo-1 #196 is queued; repo-2 #196 is in <state>. repo-1's run must launch under its own key,
# repo-2's files must be exactly as they were.
rk2_drain_case() {  # rk2_drain_case <live|held|done|stopped>
  local st=$1 before after launched repo_of_a
  rk_env
  rk_run_files "$RK_KB" "$RK_REPO_B" "$st" 196 >/dev/null
  rk_queue_entry "$RK_KA" "$RK_REPO_A" 196
  before=$(rk2_sums "$RK_KB" 196)
  rk2_tick
  after=$(rk2_sums "$RK_KB" 196)
  launched=ABSENT; [ -f "$RK_PIPE/$RK_KA-196.launched-at" ] && launched=yes
  repo_of_a=$(cat "$RK_PIPE/$RK_KA-196.repo" 2>/dev/null || echo ABSENT)
  local a_queue=present; [ -e "$RK_PIPE/queue/$RK_KA-196.json" ] || a_queue=gone
  local bare; bare=$(ls "$RK_PIPE" | grep -E '^orch-[0-9]+\.' | tr '\n' ' ')
  rk_cleanup
  assert_eq "$launched" "yes" "#213 drain ($st): repo-1 #196 launched with its own repo-keyed files" || return 1
  assert_eq "$repo_of_a" "$RK_REPO_A" "#213 drain ($st): the launched run's .repo is repo-1's checkout" || return 1
  assert_eq "$a_queue" "gone" "#213 drain ($st): the launched queue entry is consumed" || return 1
  assert_eq "$after" "$before" "#213 drain ($st): repo-2's #196 pid/repo/held/done/stopped files are untouched" || return 1
  assert_eq "$bare" "" "#213 drain ($st): no number-only orch-<N>.* file was written" || return 1
}
test_rk2_drain_launches_when_other_repos_same_number_is_running() { rk2_drain_case live; }
test_rk2_drain_launches_when_other_repos_same_number_is_held()    { rk2_drain_case held; }
test_rk2_drain_launches_when_other_repos_same_number_is_done()    { rk2_drain_case done; }
test_rk2_drain_launches_when_other_repos_same_number_is_stopped() { rk2_drain_case stopped; }

# Drain, reverse direction: repo-2 #196 queued while repo-1 #196 is held — the held tombstone must not
# purge repo-2's queue entry ("[drain-skip] tombstoned").
test_rk2_drain_does_not_purge_queue_entry_because_other_repo_is_held() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" held 196 >/dev/null
  rk_queue_entry "$RK_KB" "$RK_REPO_B" 196
  local held_before held_after launched=ABSENT
  held_before=$(rk2_sums "$RK_KA" 196)
  rk2_tick
  held_after=$(rk2_sums "$RK_KA" 196)
  [ -f "$RK_PIPE/$RK_KB-196.launched-at" ] && launched=yes
  rk_cleanup
  assert_eq "$launched" "yes" "#213 drain: repo-2 #196 launched although repo-1 #196 is held" || return 1
  assert_eq "$held_after" "$held_before" "#213 drain: repo-1's held run is untouched" || return 1
}

# Dispatch: repo-2 has agent-go #703; repo-1 #703 is <state>. repo-2 must be dispatched under its own key.
rk2_dispatch_case() {  # rk2_dispatch_case <live|held|done|queued>
  local st=$1 before after dispatched=ABSENT q_before q_after
  rk_env
  # only repo-2 is dispatchable in this tick
  cat > "$RK_HOME/.claude/pipeline/config.local.sh" <<CFG
MEM_FLOOR_MB=0
CLAIM_SETTLE_SECS=0
DISPATCH_REPOS=("$RK_OWNER_B:$RK_REPO_B")
CFG
  rk_gh_set B list-go '[{"number":703,"labels":[]}]'
  if [ "$st" = queued ]; then
    rk_queue_entry "$RK_KA" "$RK_REPO_A" 703 "2099-01-01T00:00:00Z"
    python3 -c "import json; p='$RK_PIPE/queue/$RK_KA-703.json'; d=json.load(open(p)); d['not_before']=4102444800; json.dump(d, open(p,'w'))"
  else
    rk_run_files "$RK_KA" "$RK_REPO_A" "$st" 703 >/dev/null
  fi
  before=$(rk2_sums "$RK_KA" 703); q_before=$(rk_sum "$RK_PIPE/queue/$RK_KA-703.json")
  rk2_tick
  after=$(rk2_sums "$RK_KA" 703); q_after=$(rk_sum "$RK_PIPE/queue/$RK_KA-703.json")
  [ -f "$RK_PIPE/$RK_KB-703.launched-at" ] && dispatched=yes
  local own_repo; own_repo=$(cat "$RK_PIPE/$RK_KB-703.repo" 2>/dev/null || echo ABSENT)
  rk_cleanup
  assert_eq "$dispatched" "yes" "#213 dispatch ($st): repo-2 #703 dispatched with its own repo-keyed files" || return 1
  assert_eq "$own_repo" "$RK_REPO_B" "#213 dispatch ($st): dispatched run's .repo is repo-2's checkout" || return 1
  assert_eq "$after" "$before" "#213 dispatch ($st): repo-1's #703 state files survive (held tombstone is not wiped)" || return 1
  assert_eq "$q_after" "$q_before" "#213 dispatch ($st): repo-1's #703 queue entry is untouched" || return 1
}
test_rk2_dispatch_ignores_other_repos_running_same_number() { rk2_dispatch_case live; }
test_rk2_dispatch_keeps_other_repos_held_tombstone()        { rk2_dispatch_case held; }
test_rk2_dispatch_keeps_other_repos_done_tombstone()        { rk2_dispatch_case done; }
test_rk2_dispatch_ignores_other_repos_queued_same_number()  { rk2_dispatch_case queued; }

run_test test_rk2_drain_launches_when_other_repos_same_number_is_running
run_test test_rk2_drain_launches_when_other_repos_same_number_is_held
run_test test_rk2_drain_launches_when_other_repos_same_number_is_done
run_test test_rk2_drain_launches_when_other_repos_same_number_is_stopped
run_test test_rk2_drain_does_not_purge_queue_entry_because_other_repo_is_held
run_test test_rk2_dispatch_ignores_other_repos_running_same_number
run_test test_rk2_dispatch_keeps_other_repos_held_tombstone
run_test test_rk2_dispatch_keeps_other_repos_done_tombstone
run_test test_rk2_dispatch_ignores_other_repos_queued_same_number
