# Issue #781 — a sentry-auto-go ticket that also carries `ci-critical` is exempt from the daily launch cap, and the cap hold
# is published for the status page. Whole supervisor ticks and hand launches in an isolated HOME/PIPE (lib/sentry-cap.sh).
#
#   AC1  cap full, a ci-critical sentry-auto-go ticket launches; a normal one of the same repo and tick still waits (whichever
#        comes first); negatives: ci-critical without sentry-auto-go is never touched by the cap, a ci-critical ticket of
#        another repo does not exempt this repo's others
#   AC2  exempt launches are not counted: 3 normal + 2 exempt -> SENTRY_CAP_N 3, the gate still refuses a normal ticket
#   AC3  an unreadable launch log does not block an exempt ticket; a failed append of its `exempt` line is logged and alerted
#   AC4  the cap hold record: {repo,count,max,resets_at,held} from a 3-line log at a fixed clock, nothing under the cap,
#        carried by report-status.sh --print and by no other payload
#
# Expected values are hand-written from the ticket (cap 3, window 86400 s). Fixed clock: 1795082400 = 2026-11-19T10:00:00Z.

HERE_C781=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_C781/lib/sentry-cap.sh"

C781_NOW=1795082400
C781_LABELS="agent-go sentry-auto-go source:sentry bug"
c781_exempt_lines() { grep -c ' exempt$' "$SC_LOG" 2>/dev/null || true; }
# c781_fixed_log <owner/repo> — three counted launches at 09:10, 09:30 and 09:50 UTC on the fixed clock
c781_fixed_log() {
  printf '%s %s 900\n%s %s 901\n%s %s 902\n' $((C781_NOW - 3000)) "$1" $((C781_NOW - 1800)) "$1" $((C781_NOW - 600)) "$1" >> "$SC_LOG"
}

# ------------------------------------------------------------------------------------------ AC1: the supervisor

test_c781_exempt_launches_with_a_full_window_and_the_normal_ticket_before_it_waits() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 4 "$SC_A" $C781_LABELS
  # shellcheck disable=SC2086
  sc_issue 5 "$SC_A" $C781_LABELS ci-critical
  sc_tick
  local cl labels4 labels5 lines n count log
  cl=$(cat "$SC_D/claude.log"); labels4=$(sc_labels 4); labels5=$(sc_labels 5); lines=$(sc_log_lines); n=$(c781_exempt_lines)
  count=$(sc_lib "sentry_launch_count $SC_A"); log=$(sc_suplog)
  sc_cleanup
  assert_contains "$cl" "Drive $SC_A#5 through the pipeline" "the ci-critical ticket launched with the cap full" || return 1
  assert_not_contains "$cl" "Drive $SC_A#4 " "the normal sentry-auto-go ticket of the same tick still waits" || return 1
  assert_eq "$labels4" "agent-go,bug,sentry-auto-go,source:sentry" "the waiting ticket keeps its labels" || return 1
  assert_eq "$labels5" "agent-in-progress,bug,ci-critical,sentry-auto-go,source:sentry" "the exempt ticket was claimed" || return 1
  assert_eq "$lines" "4" "one audit line appended" || return 1
  assert_eq "$n" "1" "and it ends in exempt" || return 1
  assert_eq "$count" "3" "the exempt launch is not counted" || return 1
  assert_contains "$log" "$SC_A#5 — ci-critical, exempt from the sentry launch cap" "the exemption is logged" || return 1
  assert_contains "$log" "sentry launch cap reached" "the normal ticket meets the cap" || return 1
}

test_c781_exempt_ticket_first_does_not_open_the_gate_for_the_next_normal_ticket() {
  sc_env; touch "$SC_D/claude-hold"; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 4 "$SC_A" $C781_LABELS ci-critical
  # shellcheck disable=SC2086
  sc_issue 5 "$SC_A" $C781_LABELS
  sc_tick; sc_tick
  local cl labels5 n
  cl=$(cat "$SC_D/claude.log"); labels5=$(sc_labels 5); n=$(sc_orch_launches)
  sc_cleanup
  assert_contains "$cl" "Drive $SC_A#4 through the pipeline" "the ci-critical ticket launched" || return 1
  assert_not_contains "$cl" "Drive $SC_A#5 " "the normal ticket behind it did not slip through on the exempt one's decision" || return 1
  assert_eq "$labels5" "agent-go,bug,sentry-auto-go,source:sentry" "and is still queued" || return 1
  assert_eq "$n" "1" "one orchestrator in two ticks" || return 1
}

test_c781_ci_critical_without_sentry_auto_go_is_never_touched_by_the_cap() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 4 "$SC_A" agent-go bug ci-critical
  sc_tick
  local cl lines n log
  cl=$(cat "$SC_D/claude.log"); lines=$(sc_log_lines); n=$(c781_exempt_lines); log=$(sc_suplog)
  sc_cleanup
  assert_contains "$cl" "Drive $SC_A#4 through the pipeline" "launched as any non-Sentry ticket" || return 1
  assert_eq "$lines" "3" "nothing appended: it is not a cap launch, exempt or counted" || return 1
  assert_eq "$n" "0" "no exempt line" || return 1
  assert_not_contains "$log" "exempt from the sentry launch cap" "no exemption was needed" || return 1
}

test_c781_ci_critical_label_of_another_repo_does_not_exempt_this_repos_tickets() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $C781_LABELS
  # shellcheck disable=SC2086
  sc_issue 8 "$SC_B" $C781_LABELS ci-critical
  sc_tick
  local cl labels7
  cl=$(cat "$SC_D/claude.log"); labels7=$(sc_labels 7)
  sc_cleanup
  assert_contains "$cl" "Drive $SC_B#8 through the pipeline" "repo B's ci-critical ticket launched" || return 1
  assert_not_contains "$cl" "Drive $SC_A#7 " "repo A's normal ticket is still capped" || return 1
  assert_eq "$labels7" "agent-go,bug,sentry-auto-go,source:sentry" "labels untouched" || return 1
}

# ------------------------------------------------------------------------------------------ AC1/AC2: launcher.sh

test_c781_hand_launches_of_exempt_tickets_are_not_counted() {
  sc_env; touch "$SC_D/claude-hold"; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 6 "$SC_A" $C781_LABELS ci-critical
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $C781_LABELS ci-critical
  # shellcheck disable=SC2086
  sc_issue 8 "$SC_A" $C781_LABELS
  local o1 r1 o2 r2 o3 r3 lines n count gate
  o1=$(sc_launch "$SC_RA" 6); r1=$?
  o2=$(sc_launch "$SC_RA" 7); r2=$?
  o3=$(sc_launch "$SC_RA" 8); r3=$?
  lines=$(sc_log_lines); n=$(c781_exempt_lines); count=$(sc_lib "sentry_launch_count $SC_A")
  gate=$(sc_lib "sentry_cap_gate $SC_A 8; echo \"\$? \$SENTRY_CAP_N\"")
  sc_cleanup
  assert_eq "$r1" "0" "exempt launch 1 exits 0 with the cap full" || return 1
  assert_contains "$o1" "launched orchestrator for $SC_A#6" "exempt launch 1 started" || return 1
  assert_eq "$r2" "0" "exempt launch 2 exits 0" || return 1
  assert_contains "$o2" "launched orchestrator for $SC_A#7" "exempt launch 2 started" || return 1
  assert_eq "$r3" "3" "a normal ticket is still refused" || return 1
  assert_contains "$o3" "sentry launch cap reached for $SC_A (3/3 in 24h)" "with the exact refusal" || return 1
  assert_eq "$lines" "5" "3 normal + 2 exempt lines" || return 1
  assert_eq "$n" "2" "two of them exempt" || return 1
  assert_eq "$count" "3" "3 normal + 2 exempt launches: the window holds 3" || return 1
  assert_eq "$gate" "3 3" "SENTRY_CAP_N is 3 and the gate still says capped" || return 1
}

test_c781_exempt_env_without_the_label_is_ignored_by_a_hand_launch() {
  # SENTRY_CAP_EXEMPT only travels with SENTRY_CAP_LABELLED from the supervisor; alone it exempts nothing
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 8 "$SC_A" $C781_LABELS
  local o r lines
  o=$(SENTRY_CAP_EXEMPT=1 sc_launch "$SC_RA" 8); r=$?
  lines=$(sc_log_lines)
  sc_cleanup
  assert_eq "$r" "3" "refused" || return 1
  assert_contains "$o" "sentry launch cap reached" "by the cap" || return 1
  assert_eq "$lines" "3" "nothing appended" || return 1
}

# ------------------------------------------------------------------------------------------ AC3: unreadable log

test_c781_unreadable_log_does_not_block_an_exempt_ticket_and_the_failed_append_is_alerted() {
  sc_env; mkdir "$SC_LOG"   # exists, cannot be read or appended as a file
  # shellcheck disable=SC2086
  sc_issue 5 "$SC_A" $C781_LABELS ci-critical
  SC_WEBHOOK=https://hooks.example.test/x
  sc_tick
  local cl alert
  cl=$(cat "$SC_D/claude.log"); alert=$(grep 'sentry-launch-cap' "$SC_D/curl.log")
  sc_cleanup
  assert_contains "$cl" "Drive $SC_A#5 through the pipeline" "the exempt ticket launched with an unreadable log" || return 1
  assert_contains "$alert" "exempt launch log append failed" "the failed audit append alerts on the existing webhook" || return 1
  assert_contains "$alert" "route=sentry-launch-cap" "tagged with the route" || return 1
  assert_contains "$alert" "release=" "and the release" || return 1
  assert_not_contains "$alert" "ghp_" "no secret in the alert" || return 1
}

# ------------------------------------------------------------------------------------------ AC4: the cap hold record

test_c781_cap_record_has_the_oldest_launch_plus_24h_and_the_held_tickets() {
  sc_env; c781_fixed_log "$SC_A"
  local rec
  rec=$(sc_lib "SENTRY_CAP_NOW=$C781_NOW sentry_cap_record $SC_A 7 8")
  sc_cleanup
  assert_eq "$(printf '%s' "$rec" | jq -c .)" "{\"repo\":\"$SC_A\",\"count\":3,\"max\":3,\"resets_at\":\"2026-11-20T09:10:00Z\",\"held\":[7,8]}" "record at the fixed clock" || return 1
}

test_c781_cap_record_is_empty_under_the_cap_and_ignores_exempt_lines() {
  sc_env
  printf '%s %s 900\n%s %s 901\n' $((C781_NOW - 3000)) "$SC_A" $((C781_NOW - 1800)) "$SC_A" >> "$SC_LOG"
  printf '%s %s 950 exempt\n%s %s 951 exempt\n' $((C781_NOW - 100)) "$SC_A" $((C781_NOW - 50)) "$SC_A" >> "$SC_LOG"
  local rec
  rec=$(sc_lib "SENTRY_CAP_NOW=$C781_NOW sentry_cap_record $SC_A 7")
  sc_cleanup
  assert_eq "$rec" "" "2 counted + 2 exempt lines: under the cap, no record" || return 1
}

test_c781_cap_record_with_an_overfull_window_resets_when_the_cap_actually_frees() {
  sc_env; c781_fixed_log "$SC_A"; printf '%s %s 903\n' $((C781_NOW - 300)) "$SC_A" >> "$SC_LOG"
  local rec
  rec=$(sc_lib "SENTRY_CAP_NOW=$C781_NOW sentry_cap_record $SC_A 7 | jq -r '.count, .resets_at'" | tr '\n' ' ')
  sc_cleanup
  assert_eq "$rec" "4 2026-11-20T09:30:00Z " "4 counted, cap 3: it frees when the 2nd oldest (09:30) ages out" || return 1
}

test_c781_supervisor_writes_the_hold_for_non_exempt_tickets_and_clears_it_when_the_window_frees() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 4 "$SC_A" $C781_LABELS
  # shellcheck disable=SC2086
  sc_issue 5 "$SC_A" $C781_LABELS ci-critical
  # shellcheck disable=SC2086
  sc_issue 6 "$SC_A" $C781_LABELS
  sc_tick
  local f held
  f="$SC_PIPE/sentry-cap-held.project-a_repo-a.json"
  held=$(jq -c '[.repo, .held]' "$f" 2>/dev/null)
  : > "$SC_LOG"; sc_seed "$SC_A" 90000 90000 90000   # the window frees
  sc_tick
  local after=present; [ -e "$f" ] || after=absent
  sc_cleanup
  assert_eq "$held" "[\"$SC_A\",[4,6]]" "the waiting tickets, without the exempt one" || return 1
  assert_eq "$after" "absent" "the file is removed once nothing is held" || return 1
}

test_c781_report_status_carries_sentry_cap_only_while_capped() {
  sc_env; c781_fixed_log "$SC_A"
  sc_lib "sentry_cap_held_write $SC_A 7 8" || { sc_cleanup; fail "held file written"; return 1; }
  local p1 p2
  p1=$( ( HOME="$SC_HOME" PATH="$(sc_path)" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" STATUS_CRON_CMD=true SENTRY_CAP_NOW=$C781_NOW \
    /bin/bash "$RS_SC/report-status.sh" --print ) )
  p2=$( ( HOME="$SC_HOME" PATH="$(sc_path)" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" STATUS_CRON_CMD=true SENTRY_CAP_NOW=$((C781_NOW + 86400)) \
    /bin/bash "$RS_SC/report-status.sh" --print ) )
  sc_cleanup
  assert_eq "$(printf '%s' "$p1" | jq -c '.sentry_cap')" "[{\"repo\":\"$SC_A\",\"count\":3,\"max\":3,\"resets_at\":\"2026-11-20T09:10:00Z\",\"held\":[7,8]}]" "payload record while capped" || return 1
  assert_eq "$(printf '%s' "$p2" | jq -c 'has("sentry_cap")')" "false" "no key once the window has freed, even with the file still there" || return 1
}

test_c781_label_is_defined_and_documented() {
  local cfg doc
  cfg=$(grep -c '^LABEL_CI_CRITICAL="ci-critical"' "$RS_SC/config.sh"); doc=$(grep -c 'ci-critical' "$RS_SC/SKILL.md")
  assert_eq "$cfg" "1" "config.sh defines LABEL_CI_CRITICAL" || return 1
  assert_ne "$doc" "0" "SKILL.md documents the exemption" || return 1
}

run_test test_c781_exempt_launches_with_a_full_window_and_the_normal_ticket_before_it_waits
run_test test_c781_exempt_ticket_first_does_not_open_the_gate_for_the_next_normal_ticket
run_test test_c781_ci_critical_without_sentry_auto_go_is_never_touched_by_the_cap
run_test test_c781_ci_critical_label_of_another_repo_does_not_exempt_this_repos_tickets
run_test test_c781_hand_launches_of_exempt_tickets_are_not_counted
run_test test_c781_exempt_env_without_the_label_is_ignored_by_a_hand_launch
run_test test_c781_unreadable_log_does_not_block_an_exempt_ticket_and_the_failed_append_is_alerted
run_test test_c781_cap_record_has_the_oldest_launch_plus_24h_and_the_held_tickets
run_test test_c781_cap_record_is_empty_under_the_cap_and_ignores_exempt_lines
run_test test_c781_cap_record_with_an_overfull_window_resets_when_the_cap_actually_frees
run_test test_c781_supervisor_writes_the_hold_for_non_exempt_tickets_and_clears_it_when_the_window_frees
run_test test_c781_report_status_carries_sentry_cap_only_while_capped
run_test test_c781_label_is_defined_and_documented
