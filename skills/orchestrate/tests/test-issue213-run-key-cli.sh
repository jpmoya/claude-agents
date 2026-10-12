# #213 — run state keyed by <owner/repo> + issue number. This file: run_key itself, the static "no
# number-only per-run path" grep, hand-launch isolation, `stop`/`tail` taking <owner/repo> <N>, `status`
# and `queue` with two repos sharing a number, run-id, and the doc updates.
#
# Expected values come from the ticket's Decisions section (hand-written):
#   run_key project-a/repo-1 196  ->  orch-project-a_repo-1-196
# Two placeholder repos share every number. See lib/runkey.sh.

HERE_RK1=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_RK1/lib/runkey.sh"
SK_RK1="$HERE_RK1/.."
ORCH_RK1="$SK_RK1/orchestrate.sh"

# AC1a — run_key exists once, in pipeline-lib.sh, and prints the documented format.
test_rk1_run_key_prints_orch_owner_repo_number() {
  local out
  out=$( bash -c '. "'"$SK_RK1"'/pipeline-lib.sh"; run_key project-a/repo-1 196' 2>&1 )
  assert_eq "$out" "orch-project-a_repo-1-196" "#213: run_key <owner/repo> <N> -> orch-<owner>_<repo>-<N>" || return 1
  out=$( bash -c '. "'"$SK_RK1"'/pipeline-lib.sh"; run_key project-b/repo-2 7' 2>&1 )
  assert_eq "$out" "orch-project-b_repo-2-7" "#213: run_key second sample" || return 1
}

test_rk1_run_key_defined_exactly_once_in_pipeline_lib() {
  local n_lib n_other
  n_lib=$(grep -cE '^run_key\(\)|^run_key \(\)|^function run_key' "$SK_RK1/pipeline-lib.sh")
  n_other=$(grep -lE '^run_key\(\)|^function run_key' "$SK_RK1"/*.sh "$SK_RK1"/*.py 2>/dev/null | grep -v 'pipeline-lib.sh' | wc -l | tr -d ' ')
  assert_eq "$n_lib" "1" "#213: pipeline-lib.sh defines run_key once" || return 1
  assert_eq "$n_other" "0" "#213: no other script redefines run_key" || return 1
}

# AC1b — the ticket's own grep finds nothing.
test_rk1_no_per_run_path_built_from_a_number_alone() {
  local hits
  hits=$(cd "$SK_RK1" && grep -nE 'orch-\$\{?(ISSUE|issue|num|n|q_issue|best_issue|[12])\}?[.\"]' *.sh *.py 2>/dev/null)
  assert_eq "$hits" "" "#213 AC1: per-run file path built from a number alone remains:
$hits" || return 1
}

# AC2 — a hand-launch of A#196 leaves B#196's files untouched and creates its own distinct set.
test_rk1_hand_launch_leaves_other_repos_same_number_files_untouched() {
  rk_env
  rk_run_files "$RK_KB" "$RK_REPO_B" held 196 >/dev/null
  rk_queue_entry "$RK_KB" "$RK_REPO_B" 196
  local f sum_before="" sum_after="" out rc
  for f in "$RK_PIPE/$RK_KB-196.pid" "$RK_PIPE/$RK_KB-196.repo" "$RK_PIPE/$RK_KB-196.held" "$RK_PIPE/queue/$RK_KB-196.json"; do
    sum_before="$sum_before $(rk_sum "$f")"
  done
  out=$(rk_env_run "$ORCH_RK1" "$RK_REPO_A" 196); rc=$?
  for f in "$RK_PIPE/$RK_KB-196.pid" "$RK_PIPE/$RK_KB-196.repo" "$RK_PIPE/$RK_KB-196.held" "$RK_PIPE/queue/$RK_KB-196.json"; do
    sum_after="$sum_after $(rk_sum "$f")"
  done
  local own_pid own_repo number_only
  own_pid=$(cat "$RK_PIPE/$RK_KA-196.pid" 2>/dev/null || echo ABSENT)
  own_repo=$(cat "$RK_PIPE/$RK_KA-196.repo" 2>/dev/null || echo ABSENT)
  number_only=$(ls "$RK_PIPE" 2>/dev/null | grep -E '^orch-[0-9]+\.' | tr '\n' ' ')
  local sc=$(rk_sum "$RK_PIPE/$RK_KA-196.start")
  rk_cleanup
  assert_exit0 "$rc" "#213: hand-launch exits 0 ($out)" || return 1
  assert_ne "$own_pid" "ABSENT" "#213: launch wrote its own pid file under the repo-keyed name" || return 1
  assert_ne "$sc" "ABSENT" "#213: launch wrote its own .start under the repo-keyed name" || return 1
  assert_eq "$own_repo" "$RK_REPO_A" "#213: own .repo holds this checkout path" || return 1
  assert_eq "$sum_after" "$sum_before" "#213: the other repo's pid/repo/held/queue files are byte-identical after the launch" || return 1
  assert_eq "$number_only" "" "#213: no orch-<N>.* number-only file created" || return 1
}

# AC4 — stop <owner/repo> <N> kills only that run and writes only its tombstone.
test_rk1_stop_with_repo_kills_only_that_run() {
  rk_env
  local pa pb
  pa=$(rk_run_files "$RK_KA" "$RK_REPO_A" live 198)
  pb=$(rk_run_files "$RK_KB" "$RK_REPO_B" live 198)
  rk_queue_entry "$RK_KA" "$RK_REPO_A" 198
  rk_queue_entry "$RK_KB" "$RK_REPO_B" 198
  local out rc a_dead=1 b_alive=1
  out=$(rk_env_run "$ORCH_RK1" stop "$RK_OWNER_A" 198); rc=$?
  rk_wait_dead "$pa" || a_dead=0
  rk_alive "$pb" || b_alive=0
  local a_tomb=ABSENT b_tomb=ABSENT bare=ABSENT a_q=present b_q=ABSENT
  [ -e "$RK_PIPE/$RK_KA-198.stopped" ] && a_tomb=present
  [ -e "$RK_PIPE/$RK_KB-198.stopped" ] && b_tomb=present
  [ -e "$RK_PIPE/orch-198.stopped" ] && bare=present
  [ -e "$RK_PIPE/queue/$RK_KA-198.json" ] || a_q=ABSENT
  [ -e "$RK_PIPE/queue/$RK_KB-198.json" ] && b_q=present
  rk_cleanup
  assert_exit0 "$rc" "#213: stop <owner/repo> <N> exits 0 ($out)" || return 1
  assert_eq "$a_dead" "1" "#213: the named run's process is killed" || return 1
  assert_eq "$b_alive" "1" "#213: the other repo's same-number run is still alive" || return 1
  assert_eq "$a_tomb" "present" "#213: tombstone written under the repo-keyed name" || return 1
  assert_eq "$b_tomb" "ABSENT" "#213: no tombstone for the other repo's run" || return 1
  assert_eq "$bare" "ABSENT" "#213: no number-only tombstone" || return 1
  assert_eq "$a_q" "ABSENT" "#213: the named run's queue entry is removed" || return 1
  assert_eq "$b_q" "present" "#213: the other repo's queue entry is kept" || return 1
}

# AC4 (negative) — the old one-argument form is refused with usage, kills nothing, writes nothing.
test_rk1_stop_with_number_only_exits_2_and_changes_nothing() {
  rk_env
  local pa pb out rc
  pa=$(rk_run_files "$RK_KA" "$RK_REPO_A" live 198)
  pb=$(rk_run_files "$RK_KB" "$RK_REPO_B" live 198)
  out=$(rk_env_run "$ORCH_RK1" stop 198); rc=$?
  local a_alive=1 b_alive=1 tombs
  rk_alive "$pa" || a_alive=0
  rk_alive "$pb" || b_alive=0
  tombs=$(ls "$RK_PIPE" | grep -E '\.stopped$' | tr '\n' ' ')
  rk_cleanup
  assert_eq "$rc" "2" "#213: stop <N> (old form) exits 2" || return 1
  assert_contains "$out" "owner/repo" "#213: usage line names <owner/repo>" || return 1
  assert_eq "$a_alive$b_alive" "11" "#213: no process was killed" || return 1
  assert_eq "$tombs" "" "#213: no .stopped tombstone written anywhere" || return 1
}

# tail <owner/repo> <N> [lines]
test_rk1_tail_takes_repo_and_number() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" held 198 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" held 198 >/dev/null
  printf 'a-one\na-two\na-three\n' > "$RK_PIPE/$RK_KA-198.log"
  printf 'b-one\nb-two\nb-three\n' > "$RK_PIPE/$RK_KB-198.log"
  local out rc out_old rc_old
  out=$(rk_env_run "$ORCH_RK1" tail "$RK_OWNER_A" 198 2); rc=$?
  out_old=$(rk_env_run "$ORCH_RK1" tail 198 2); rc_old=$?
  rk_cleanup
  assert_exit0 "$rc" "#213: tail <owner/repo> <N> <lines> exits 0" || return 1
  assert_eq "$out" "$(printf 'a-two\na-three')" "#213: tail prints the named repo's log, last 2 lines" || return 1
  assert_eq "$rc_old" "2" "#213: tail <N> (old form) exits 2" || return 1
}

# status [N] prints every repo's match, each with its own repo= and log= path.
test_rk1_status_by_number_lists_both_repos_with_their_own_log() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" live 196 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" held 196 >/dev/null
  local out n
  out=$(rk_env_run "$ORCH_RK1" status 196)
  n=$(printf '%s\n' "$out" | grep -c '^#196 ')
  rk_cleanup
  assert_eq "$n" "2" "#213: status 196 prints one line per repo holding #196" || return 1
  assert_contains "$out" "repo=$RK_REPO_A" "#213: first repo's line" || return 1
  assert_contains "$out" "repo=$RK_REPO_B" "#213: second repo's line" || return 1
  assert_contains "$out" "log=$RK_PIPE/$RK_KA-196.log" "#213: log= path is the repo-keyed one (A)" || return 1
  assert_contains "$out" "log=$RK_PIPE/$RK_KB-196.log" "#213: log= path is the repo-keyed one (B)" || return 1
}

# queue ordering: oldest queued_at first, not filename order. Filename order puts repo-1 first.
test_rk1_queue_and_status_order_by_queued_at() {
  rk_env
  rk_queue_entry "$RK_KA" "$RK_REPO_A" 5 "2026-10-12T10:00:00Z"   # newer
  rk_queue_entry "$RK_KB" "$RK_REPO_B" 9 "2026-10-12T08:00:00Z"   # older -> must print first
  local q s qpos_b qpos_a spos_b spos_a
  q=$(rk_env_run "$ORCH_RK1" queue)
  s=$(rk_env_run "$ORCH_RK1" status)
  rk_cleanup
  qpos_b=$(printf '%s\n' "$q" | grep -n '^#9 ' | cut -d: -f1); qpos_a=$(printf '%s\n' "$q" | grep -n '^#5 ' | cut -d: -f1)
  spos_b=$(printf '%s\n' "$s" | grep -n '^#9 ' | cut -d: -f1); spos_a=$(printf '%s\n' "$s" | grep -n '^#5 ' | cut -d: -f1)
  [ -n "$qpos_b" ] && [ -n "$qpos_a" ] || { fail "#213: queue lists both entries, got: $q"; return 1; }
  assert_lt "$qpos_b" "$qpos_a" "#213: queue lists the older queued_at first" || return 1
  [ -n "$spos_b" ] && [ -n "$spos_a" ] || { fail "#213: status lists both queued entries, got: $s"; return 1; }
  assert_lt "$spos_b" "$spos_a" "#213: status queued section lists the older queued_at first" || return 1
}

# run_id embeds the run key, in the .run-id file and in the run_launch event row.
test_rk1_run_id_embeds_the_run_key() {
  rk_env
  local out rid row_rid
  out=$(rk_env_run "$ORCH_RK1" "$RK_REPO_A" 196)
  rid=$(cat "$RK_PIPE/$RK_KA-196.run-id" 2>/dev/null || echo ABSENT)
  row_rid=$(grep '"run_launch"' "$RK_HOME/logs/pipeline/events.jsonl" 2>/dev/null | tail -1 | jq -r .run_id 2>/dev/null)
  rk_cleanup
  assert_contains "$rid" "$RK_KA-196" "#213: .run-id file embeds the run key (got $rid)" || return 1
  assert_contains "$row_rid" "$RK_KA-196" "#213: run_launch row's run_id embeds the run key (got $row_rid)" || return 1
}

# Docs: README.md and SKILL.md no longer describe number-keyed files or one-argument stop/tail.
test_rk1_docs_describe_repo_keyed_files_and_two_arg_stop_tail() {
  local root skill readme
  root="$SK_RK1/../.."
  skill="$SK_RK1/SKILL.md"; readme="$root/README.md"
  local left
  left=$(cat "$skill" "$readme" | grep -cE 'orch-<(issue|n|N)>')
  assert_eq "$left" "0" "#213: no orch-<issue>/orch-<n> left in SKILL.md/README.md" || return 1
  if grep -qE 'orchestrate\.sh (stop|tail) [0-9]+' "$skill"; then fail "#213: SKILL.md still shows one-argument stop/tail"; return 1; fi
  grep -qE 'orchestrate\.sh stop <?[^ ]*/[^ ]*>? ' "$skill" || { fail "#213: SKILL.md must show 'stop <owner/repo> <N>'"; return 1; }
  grep -qE 'orchestrate\.sh tail <?[^ ]*/[^ ]*>? ' "$skill" || { fail "#213: SKILL.md must show 'tail <owner/repo> <N>'"; return 1; }
}

run_test test_rk1_run_key_prints_orch_owner_repo_number
run_test test_rk1_run_key_defined_exactly_once_in_pipeline_lib
run_test test_rk1_no_per_run_path_built_from_a_number_alone
run_test test_rk1_hand_launch_leaves_other_repos_same_number_files_untouched
run_test test_rk1_stop_with_repo_kills_only_that_run
run_test test_rk1_stop_with_number_only_exits_2_and_changes_nothing
run_test test_rk1_tail_takes_repo_and_number
run_test test_rk1_status_by_number_lists_both_repos_with_their_own_log
run_test test_rk1_queue_and_status_order_by_queued_at
run_test test_rk1_run_id_embeds_the_run_key
run_test test_rk1_docs_describe_repo_keyed_files_and_two_arg_stop_tail
