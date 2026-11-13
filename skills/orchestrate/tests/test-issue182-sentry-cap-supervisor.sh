# Issue #182 — daily cap on automatic Sentry-ticket launches per repo: the supervisor's shared-dispatch step (5).
# Whole ticks in an isolated HOME/PIPE with stubbed gh / claude / pmset / curl (lib/sentry-cap.sh); step 5 launches
# through the real orchestrate.sh. Config is the default (cap 3) unless a test says otherwise.
#
#   AC1  fixture 1: cap 3, 3 launches of repo A in the last hour, one sentry-auto-go issue queued in A -> not launched,
#                   slog line written, labels unchanged
#        fixture 2: same log, queued issue in repo B -> launched (the cap is per repo)
#        fixture 3: the 3 entries are 25 h old -> launched
#        fixture 4: a hand-released Sentry ticket (agent-go + source:sentry, no sentry-auto-go) with a full log -> launched
#   AC3  a non-Sentry issue dispatches as before, also next to a capped one
#   AC4  a missing log counts as zero; a launch appends its line only after the claim is won and the run is launched
#   Obs  an unreadable log fails closed (no launch), logged with release / environment / route=sentry-launch-cap, one alert
#   Rev  (code review of PR #683) a launch counted when it was queued gives its place back when the drain drops the entry
#        before it started (tombstone, lost claim) and keeps it when the drain starts it; restarts are not counted
#
# Expected values are hand-written from the ticket.

HERE_SCS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_SCS/lib/sentry-cap.sh"

SC_SENTRY_LABELS="agent-go sentry-auto-go source:sentry user-feedback bug"
sc_cap_lines() { sc_suplog | grep -c 'sentry launch cap reached'; }

test_scs_fx1_full_log_same_repo_is_not_launched() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $SC_SENTRY_LABELS
  sc_tick
  local n log labels calls lines caps; n=$(sc_orch_launches); log=$(sc_suplog); labels=$(sc_labels 7)
  calls=$(cat "$SC_D/gh-calls.log"); lines=$(sc_log_lines); caps=$(sc_cap_lines)
  local lists reads; lists=$(grep -c -- "issue list --repo $SC_A --state open --label agent-go --limit 500" "$SC_D/gh-calls.log"); reads=$(sc_label_reads "$SC_A" 7)
  sc_cleanup
  assert_eq "$n" "0" "fixture 1: not launched" || return 1
  assert_eq "$lists" "1" "the cap adds no listing call: one dispatch listing for the repo this tick" || return 1
  assert_eq "$reads" "0" "the cap is decided from local state: no label read for the capped ticket" || return 1
  assert_contains "$log" "sentry launch cap reached" "fixture 1: slog line written" || return 1
  assert_contains "$log" "$SC_A#7" "fixture 1: the line names the repo and the ticket" || return 1
  assert_contains "$log" "(3/3 in 24h)" "fixture 1: the line carries count and cap" || return 1
  assert_eq "$caps" "1" "fixture 1: one line this tick" || return 1
  assert_eq "$labels" "agent-go,bug,sentry-auto-go,source:sentry,user-feedback" "fixture 1: labels unchanged (stays queued)" || return 1
  assert_not_contains "$calls" "issue comment 7" "fixture 1: no claim comment for a capped ticket" || return 1
  assert_not_contains "$calls" "issue edit 7" "fixture 1: no label write" || return 1
  assert_eq "$lines" "3" "fixture 1: nothing appended to the launch log" || return 1
}

test_scs_fx2_other_repo_is_launched() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 8 "$SC_B" $SC_SENTRY_LABELS
  sc_tick
  local n cl labels lines last caps reads; n=$(sc_orch_launches); cl=$(cat "$SC_D/claude.log"); labels=$(sc_labels 8)
  lines=$(sc_log_lines); last=$(tail -1 "$SC_LOG"); caps=$(sc_cap_lines)
  reads=$(sc_label_reads "$SC_B" 8)
  sc_cleanup
  assert_eq "$n" "1" "fixture 2: launched (repo A's full window does not count for repo B)" || return 1
  assert_contains "$cl" "Drive $SC_B#8 through the pipeline" "fixture 2: the orchestrator was started for repo B's ticket" || return 1
  assert_eq "$labels" "agent-in-progress,bug,sentry-auto-go,source:sentry,user-feedback" "fixture 2: agent-go consumed, sentry-auto-go kept" || return 1
  assert_eq "$caps" "0" "fixture 2: no cap line" || return 1
  assert_eq "$lines" "4" "fixture 2: the launch appended one line" || return 1
  printf '%s\n' "$last" | grep -qE "^[0-9]+ $SC_B 8\$" || { fail "fixture 2: appended line must be '<epoch> $SC_B 8', got: $last"; return 1; }
  assert_eq "$reads" "0" "no extra GitHub label read on the dispatch path (the listing already carries the labels)" || return 1
}

test_scs_fx3_entries_older_than_24h_do_not_count() {
  sc_env; sc_seed "$SC_A" 90000 90000 90000   # 25 h
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $SC_SENTRY_LABELS
  sc_tick
  local n cl lines a; n=$(sc_orch_launches); cl=$(cat "$SC_D/claude.log"); lines=$(sc_log_lines)
  a=$(sc_lib "sentry_launch_count $SC_A")
  sc_cleanup
  assert_eq "$n" "1" "fixture 3: launched (the window freed)" || return 1
  assert_contains "$cl" "Drive $SC_A#7 through the pipeline" "fixture 3: orchestrator started" || return 1
  assert_eq "$lines" "4" "fixture 3: the old lines stay, one is appended" || return 1
  assert_eq "$a" "1" "fixture 3: the window now holds this one launch" || return 1
}

test_scs_fx4_hand_released_sentry_ticket_is_launched() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go source:sentry user-feedback bug   # no sentry-auto-go: JP released it by hand
  sc_tick
  local n cl lines caps; n=$(sc_orch_launches); cl=$(cat "$SC_D/claude.log"); lines=$(sc_log_lines); caps=$(sc_cap_lines)
  sc_cleanup
  assert_eq "$n" "1" "fixture 4: launched despite the full log" || return 1
  assert_contains "$cl" "Drive $SC_A#7 through the pipeline" "fixture 4: orchestrator started" || return 1
  assert_eq "$caps" "0" "fixture 4: never throttled, no cap line" || return 1
  assert_eq "$lines" "3" "fixture 4: a hand-released ticket is not counted" || return 1
}

test_scs_capped_ticket_does_not_block_the_next_one() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $SC_SENTRY_LABELS
  sc_issue 9 "$SC_A" agent-go bug          # an ordinary ticket, later in the order
  sc_tick
  local n cl l7 l9 caps; n=$(sc_orch_launches); cl=$(cat "$SC_D/claude.log"); l7=$(sc_labels 7); l9=$(sc_labels 9); caps=$(sc_cap_lines)
  sc_cleanup
  assert_eq "$n" "1" "one launch this tick" || return 1
  assert_contains "$cl" "Drive $SC_A#9 through the pipeline" "AC3: the non-Sentry ticket is dispatched past the capped one" || return 1
  assert_not_contains "$cl" "#7 " "the capped ticket is not launched" || return 1
  assert_eq "$l7" "agent-go,bug,sentry-auto-go,source:sentry,user-feedback" "capped ticket: labels untouched" || return 1
  assert_eq "$l9" "agent-in-progress,bug" "ordinary ticket: claimed as before" || return 1
  assert_eq "$caps" "1" "the cap line is still written" || return 1
}

test_scs_one_cap_line_per_repo_per_tick() {
  sc_env; sc_seed "$SC_A" 600 1800 3000
  # shellcheck disable=SC2086
  { sc_issue 7 "$SC_A" $SC_SENTRY_LABELS; sc_issue 8 "$SC_A" $SC_SENTRY_LABELS; sc_issue 9 "$SC_A" $SC_SENTRY_LABELS; }
  sc_tick
  local c1 n1; c1=$(sc_cap_lines); n1=$(sc_orch_launches)
  sc_tick
  local c2 n2; c2=$(sc_cap_lines); n2=$(sc_orch_launches)
  sc_cleanup
  assert_eq "$n1" "0" "three capped tickets: none launched" || return 1
  assert_eq "$c1" "1" "three capped tickets of one repo: one slog line per tick" || return 1
  assert_eq "$n2" "0" "second tick: still none launched" || return 1
  assert_eq "$c2" "2" "second tick: one more line" || return 1
}

test_scs_cap_fills_from_its_own_launches_and_follows_config() {
  # no log yet (missing file = zero), cap 1 from config.local.sh: tick 1 launches #7 and records it, tick 2 holds #8
  sc_env 'SENTRY_AUTO_GO_DAILY_CAP=1'; touch "$SC_D/claude-hold"
  # shellcheck disable=SC2086
  { sc_issue 7 "$SC_A" $SC_SENTRY_LABELS; sc_issue 8 "$SC_A" $SC_SENTRY_LABELS; }
  local had=absent; [ -e "$SC_LOG" ] && had=present
  sc_tick
  local n1 lines1 last; n1=$(sc_orch_launches); lines1=$(sc_log_lines); last=$(tail -1 "$SC_LOG" 2>/dev/null)
  sc_tick
  local n2 lines2 l8 log; n2=$(sc_orch_launches); lines2=$(sc_log_lines); l8=$(sc_labels 8); log=$(sc_suplog)
  sc_cleanup
  assert_eq "$had" "absent" "control: no launch log before the first tick" || return 1
  assert_eq "$n1" "1" "AC4: a missing log counts as zero, the first ticket launches" || return 1
  assert_eq "$lines1" "1" "the launch wrote the first line" || return 1
  printf '%s\n' "$last" | grep -qE "^[0-9]+ $SC_A 7\$" || { fail "first line must be '<epoch> $SC_A 7', got: $last"; return 1; }
  assert_eq "$n2" "1" "cap 1: the second ticket is not launched on the next tick" || return 1
  assert_eq "$lines2" "1" "nothing appended for the held ticket" || return 1
  assert_eq "$l8" "agent-go,bug,sentry-auto-go,source:sentry,user-feedback" "held ticket keeps its labels" || return 1
  assert_contains "$log" "(1/1 in 24h)" "the line reports the configured cap" || return 1
}

test_scs_lost_claim_appends_nothing() {
  # another host claimed first: step 5 loses the claim, nothing is launched, nothing is counted
  sc_env
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $SC_SENTRY_LABELS
  local t; t=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  jq -n --arg t "$t" '[{body: ("**[supervisor] NOTE** claim: otherhost " + $t), createdAt: $t}]' > "$SC_D/comments.json"
  sc_tick
  local n lines log; n=$(sc_orch_launches); lines=$(sc_log_lines); log=$(sc_suplog)
  sc_cleanup
  assert_contains "$log" "lost claim to otherhost" "control: the claim was lost" || return 1
  assert_eq "$n" "0" "lost claim: not launched" || return 1
  assert_eq "$lines" "0" "lost claim: no launch line" || return 1
}

test_scs_unreadable_log_fails_closed_tagged_and_alerted() {
  sc_env; mkdir "$SC_LOG"   # exists, cannot be read as a file (also for root)
  # shellcheck disable=SC2086
  sc_issue 7 "$SC_A" $SC_SENTRY_LABELS
  sc_issue 9 "$SC_A" agent-go bug
  SC_WEBHOOK=https://hooks.example.test/x
  sc_tick
  local cl log line alert l7 calls; cl=$(cat "$SC_D/claude.log"); log=$(sc_suplog); alert=$(grep 'sentry-launch-cap' "$SC_D/curl.log")
  line=$(printf '%s\n' "$log" | grep 'route=sentry-launch-cap'); l7=$(sc_labels 7); calls=$(cat "$SC_D/gh-calls.log")
  sc_cleanup
  assert_not_contains "$cl" "Drive $SC_A#7 " "unreadable log: the Sentry ticket is not launched (fail closed)" || return 1
  assert_not_contains "$calls" "issue comment 7" "unreadable log: no claim comment" || return 1
  assert_eq "$l7" "agent-go,bug,sentry-auto-go,source:sentry,user-feedback" "unreadable log: labels untouched" || return 1
  assert_contains "$line" "$SC_A#7" "tagged line names repo and issue number" || return 1
  assert_contains "$line" "release=" "tagged line: release" || return 1
  assert_contains "$line" "environment=" "tagged line: environment" || return 1
  assert_eq "$(printf '%s\n' "$line" | grep -c .)" "1" "one tagged line" || return 1
  assert_contains "$alert" "hooks.example.test" "alert sent on the existing Slack webhook" || return 1
  assert_contains "$alert" "release=" "alert payload: release tag" || return 1
  assert_contains "$alert" "environment=" "alert payload: environment tag" || return 1
  assert_contains "$alert" "route=supervisor/sentry-launch-cap" "alert payload: route tag (autoretry_alert)" || return 1
  assert_not_contains "$alert$line" "Jane Doe" "no issue text in the line or the alert" || return 1
  assert_eq "$(printf '%s\n' "$alert" | grep -c .)" "1" "one alert" || return 1
  assert_contains "$cl" "Drive $SC_A#9 through the pipeline" "AC3: the non-Sentry ticket still dispatches" || return 1
}

test_scs_fx4_hand_release_is_not_throttled_with_auto_go_on_either() {
  # SENTRY_AUTO_GO=1 and no intake run owning the ticket: JP's agent-go on a source:sentry ticket launches, uncounted
  sc_env 'SENTRY_AUTO_GO=1'; sc_seed "$SC_A" 600 1800 3000
  sc_issue 7 "$SC_A" agent-go source:sentry user-feedback bug
  sc_tick
  local n lines caps l7; n=$(sc_orch_launches); lines=$(sc_log_lines); caps=$(sc_cap_lines); l7=$(sc_labels 7)
  sc_cleanup
  assert_eq "$n" "1" "hand release after intake launches with SENTRY_AUTO_GO=1 and a full log" || return 1
  assert_eq "$caps" "0" "no cap line" || return 1
  assert_eq "$lines" "3" "not counted" || return 1
  assert_eq "$l7" "agent-in-progress,bug,source:sentry,user-feedback" "claimed as any agent-go ticket" || return 1
}

# sc_queue_counted <issue> — a launch of repo A that orchestrate.sh queued and counted: the queue entry with its sentry_slot
# key and the launch line, as the queued path writes them
sc_queue_counted() {
  jq -nc --arg i "$1" --arg r "$SC_RA" --arg s "$SC_A" --arg t "$(date -u +%FT%TZ)" \
    '{issue: $i, repo: $r, extra: "", reason: "queued", queued_at: $t, not_before: 0, sentry_slot: $s}' > "$SC_PIPE/queue/orch-project-a_repo-a-$1.json"
  printf '%s %s %s\n' "$(date +%s)" "$SC_A" "$1" >> "$SC_LOG"
}

test_scs_drain_purge_of_a_counted_queue_entry_releases_its_place() {
  sc_env; sc_queue_counted 7
  touch "$SC_PIPE/orch-project-a_repo-a-7.stopped"      # stopped while queued: the drain purges the entry
  local c1; c1=$(sc_lib "sentry_launch_count $SC_A")
  sc_tick
  local c2 q=absent n log last; c2=$(sc_lib "sentry_launch_count $SC_A"); n=$(sc_orch_launches); log=$(sc_suplog); last=$(tail -1 "$SC_LOG")
  [ -e "$SC_PIPE/queue/orch-project-a_repo-a-7.json" ] && q=present
  sc_cleanup
  assert_eq "$c1" "1" "control: the queued launch holds a place" || return 1
  assert_contains "$log" "tombstoned, purging queue entry" "control: the drain purged the entry" || return 1
  assert_eq "$q" "absent" "entry removed" || return 1
  assert_eq "$n" "0" "nothing launched" || return 1
  assert_eq "$c2" "0" "the purged entry's place is released" || return 1
  printf '%s\n' "$last" | grep -qE "^[0-9]+ $SC_A 7 released\$" || { fail "release line shape, got: $last"; return 1; }
  assert_contains "$log" "$SC_A#7 — queued launch dropped before it started" "the release is logged" || return 1
}

test_scs_drain_lost_claim_releases_the_place_and_a_drained_launch_keeps_it() {
  sc_env; touch "$SC_D/rest-comments" "$SC_D/claude-hold"
  sc_queue_counted 7
  local t; t=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  jq -n --arg t "$t" '[{body: ("**[supervisor] NOTE** claim: otherhost " + $t), createdAt: $t}]' > "$SC_D/comments.json"
  sc_tick
  local c_lost n_lost log; c_lost=$(sc_lib "sentry_launch_count $SC_A"); n_lost=$(sc_orch_launches); log=$(sc_suplog)
  # second half: no competing claim, the drain starts the queued launch; its place stays, nothing is appended
  echo '[]' > "$SC_D/comments.json"; sc_queue_counted 8
  local before; before=$(sc_log_lines)
  sc_tick
  local c_run n_run after; c_run=$(sc_lib "sentry_launch_count $SC_A"); n_run=$(sc_orch_launches); after=$(sc_log_lines)
  sc_cleanup
  assert_contains "$log" "lost claim to otherhost" "control: the drain lost the claim" || return 1
  assert_eq "$n_lost" "0" "lost claim: not launched" || return 1
  assert_eq "$c_lost" "0" "lost claim: the queued launch's place is released" || return 1
  assert_eq "$n_run" "1" "the drain starts the other queued launch" || return 1
  assert_eq "$after" "$before" "a drained launch appends nothing: it was counted when it was queued" || return 1
  assert_eq "$c_run" "1" "and keeps its one place" || return 1
}

test_scs_auto_restart_of_a_launched_ticket_is_not_counted() {
  # decision on PR #683: the cap bounds new tickets; a restart of one that already launched goes through the drain uncounted,
  # also with a full window
  sc_env; touch "$SC_D/rest-comments" "$SC_D/claude-hold"; sc_seed "$SC_A" 600 1800 3000
  jq -nc --arg r "$SC_RA" --arg t "$(date -u +%FT%TZ)" '{issue: "7", repo: $r, extra: "", reason: "auto-restart", queued_at: $t, not_before: 0}' \
    > "$SC_PIPE/queue/orch-project-a_repo-a-7.json"
  sc_tick
  local n lines c; n=$(sc_orch_launches); lines=$(sc_log_lines); c=$(sc_lib "sentry_launch_count $SC_A")
  sc_cleanup
  assert_eq "$n" "1" "the restart is launched though the window is full" || return 1
  assert_eq "$lines" "3" "and appends no launch line" || return 1
  assert_eq "$c" "3" "the count is unchanged" || return 1
}

run_test test_scs_fx1_full_log_same_repo_is_not_launched
run_test test_scs_fx2_other_repo_is_launched
run_test test_scs_fx3_entries_older_than_24h_do_not_count
run_test test_scs_fx4_hand_released_sentry_ticket_is_launched
run_test test_scs_capped_ticket_does_not_block_the_next_one
run_test test_scs_one_cap_line_per_repo_per_tick
run_test test_scs_cap_fills_from_its_own_launches_and_follows_config
run_test test_scs_lost_claim_appends_nothing
run_test test_scs_unreadable_log_fails_closed_tagged_and_alerted
run_test test_scs_fx4_hand_release_is_not_throttled_with_auto_go_on_either
run_test test_scs_drain_purge_of_a_counted_queue_entry_releases_its_place
run_test test_scs_drain_lost_claim_releases_the_place_and_a_drained_launch_keeps_it
run_test test_scs_auto_restart_of_a_launched_ticket_is_not_counted
