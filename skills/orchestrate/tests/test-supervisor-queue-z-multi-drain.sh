# Tests for the multi-slot queue drain (pipeline audit 2026-11-18): supervisor.sh step 2 launches up to DRAIN_MAX_PER_TICK
# queued entries per tick, oldest queued_at first, re-checking slots and memory before every extra launch and reserving
# DRAIN_MEM_PER_LAUNCH_MB for each launch already made this tick. Evidence: on the Mac 15 queued tickets drained one per tick
# (6-16 min apart) from 14:03Z to 16:38Z while 1-4 of 7 slots were busy, queue waits up to 8599 s.
#
#   MD1  3 ready entries, free slots            -> all 3 launch in one tick, oldest first
#   MD2  MAX_CONCURRENT=2, 3 ready entries       -> 2 launch, the newest stays queued
#   MD3  DRAIN_MAX_PER_TICK=2, 3 ready entries   -> 2 launch
#   MD4  memory reservation not met               -> only the first entry launches
#   MD5  DRAIN_MAX_PER_TICK=1                     -> the old one-per-tick behaviour
#
# Reuses the queue-order harness (qo_* helpers from test-supervisor-queue-order.sh, sourced earlier by run-tests.sh).
# The claude stub sleeps so every launched run stays alive and counts against MAX_CONCURRENT.

md_env() {
  qo_env
  printf '#!/bin/bash\nexec /bin/sleep 20\n' > "$QO_GH/claude"; chmod +x "$QO_GH/claude"
  printf 'DRAIN_MAX_PER_TICK=3\n' >> "$QO_HOME/.claude/pipeline/config.local.sh"   # the default (qo_env pins 1 for the ordering cases)
  qo_entry 9 9; qo_entry 5 5; qo_entry 1 1     # oldest #9, then #5, newest #1
}

test_md_1_three_ready_entries_all_launch_oldest_first() {
  md_env
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$launched" "9 5 1" "MD1: three free slots, three ready entries -> all launch in one tick, oldest first" || return 1
  assert_eq "$queued" "" "MD1: queue drained" || return 1
}

test_md_2_stops_at_max_concurrent() {
  md_env
  printf 'MAX_CONCURRENT=2\n' >> "$QO_HOME/.claude/pipeline/config.local.sh"
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$launched" "9 5" "MD2: two slots -> the two oldest launch" || return 1
  assert_eq "$queued" "1" "MD2: the newest waits for a slot" || return 1
}

test_md_3_stops_at_drain_cap() {
  md_env
  printf 'DRAIN_MAX_PER_TICK=2\n' >> "$QO_HOME/.claude/pipeline/config.local.sh"
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$launched" "9 5" "MD3: per-tick cap of 2" || return 1
  assert_eq "$queued" "1" "MD3: the third entry waits for the next tick" || return 1
}

test_md_4_memory_reservation_limits_extra_launches() {
  md_env
  printf 'DRAIN_MEM_PER_LAUNCH_MB=100000000\n' >> "$QO_HOME/.claude/pipeline/config.local.sh"   # no host has 100 TB free
  qo_tick
  local launched queued log; launched=$(qo_launched); queued=$(qo_queued_issues); log=$(qo_log)
  qo_cleanup
  assert_eq "$launched" "9" "MD4: the first launch uses the tick's capacity decision; the next needs floor + reserve" || return 1
  assert_eq "$queued" "1 5" "MD4: the others stay queued" || return 1
  assert_contains "$log" "[drain] stopping after 1 launch" "MD4: the stop is logged with its reason" || return 1
}

test_md_5_cap_one_is_the_old_behaviour() {
  md_env
  printf 'DRAIN_MAX_PER_TICK=1\n' >> "$QO_HOME/.claude/pipeline/config.local.sh"
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$launched" "9" "MD5: cap 1 -> one launch per tick" || return 1
  assert_eq "$queued" "1 5" "MD5: two stay queued" || return 1
}

run_test test_md_1_three_ready_entries_all_launch_oldest_first
run_test test_md_2_stops_at_max_concurrent
run_test test_md_3_stops_at_drain_cap
run_test test_md_4_memory_reservation_limits_extra_launches
run_test test_md_5_cap_one_is_the_old_behaviour
