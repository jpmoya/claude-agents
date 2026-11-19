# #795 — the status page's goal list comes from one shared snapshot, not whichever host's local file wins.
#   - build-runs-json.py `goalasof` mode: goalqueue.json's own `at` (else its mtime) as an ISO UTC string; nothing without the file.
#   - report-status.sh publishes it as the beat's top-level `goals_as_of` (only when there is a queue file) and the push hash ignores it
#     (a registry sync that changes nothing else costs no push).
#   - webhook fast path: while the VM's goal-push-pending marker is set, a changed goal list pushes after 30 s instead of the usual spacing,
#     still under the daily cap; with no marker the usual spacing holds.
#   - webhook-events.sh: which events can change the goal list, and the VM-only early registry sync (goal-sync.last reset) coalesced to 30 s.
# Expected values are hand-written. Prefix gsn_. Reuses test-ac12-write-budget.sh's setup_pushable_fixture / count_curl_calls / now_epoch.

GSN_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GSN_RS="$GSN_HERE/.."

gsn_mode() { PATH="$PATH" python3 "$GSN_RS/build-runs-json.py" "" "$1/runs.jsonl" "$1" goalasof </dev/null 2>/dev/null; }
gsn_print() {  # <pipe> <home>
  HOME="$2" PATH="$PATH" PIPE="$1" QUEUE="$1/queue" LOGDIR="$2/logs/pipeline" "$GSN_RS/report-status.sh" --print 2>/dev/null
}
gsn_ok_curl() {  # <bindir> records each call and reports a 204 so the push counts as successful
  cat > "$1/curl" <<'CURL'
#!/bin/bash
echo "1" >> "$(dirname "$0")/curl.calls"
printf '%s' "204"
exit 0
CURL
  chmod +x "$1/curl"
}
gsn_push() { ( PIPE="$1" QUEUE="$1/queue" HOME="$2" PATH="$3:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" "$GSN_RS/report-status.sh" event ); }
gsn_age_attempt() {  # <pipe> <secs>: backdate last_attempt_epoch (and last_push_epoch a little less than the keep-alive) so only the rules under test decide
  local t; t=$(now_epoch)
  python3 -c "
import json
d = json.load(open('$1/status-push.state'))
d['last_attempt_epoch'] = $t - $2
d['last_push_epoch'] = $t - 60
json.dump(d, open('$1/status-push.state', 'w'))
"
}
gsn_goal_file() { jq -nc --arg id "$2" '{id:$id, spec:("Spec of " + $id), host:"mac", state:"active", issue:193}' > "$1/goal-$2.json"; }

test_gsn_goalasof_uses_the_queue_files_own_timestamp() {
  local p; p=$(new_pipe)
  printf '%s' '{"at":1763500000,"queued":[]}' > "$p/goalqueue.json"
  local out; out=$(gsn_mode "$p"); rm -rf "$p"
  assert_eq "$out" "2025-11-18T21:06:40Z" "at=1763500000 is 2025-11-18T21:06:40Z" || return 1
}
test_gsn_goalasof_falls_back_to_mtime_and_is_empty_without_the_file() {
  local p out; p=$(new_pipe)
  out=$(gsn_mode "$p")
  assert_eq "$out" "" "no goalqueue.json: nothing" || { rm -rf "$p"; return 1; }
  printf '%s' 'not json' > "$p/goalqueue.json"; touch -t 202511182106.40 "$p/goalqueue.json"
  out=$(gsn_mode "$p"); rm -rf "$p"
  case "$out" in 2025-11-18T2[0-2]:*Z|2025-11-1[89]T*Z) ;; *) fail "unreadable file: ISO from mtime, got [$out]"; return 1 ;; esac
}

test_gsn_payload_carries_goals_as_of_only_with_a_queue_file() {
  local p h; p=$(new_pipe); h=$(new_home)
  assert_eq "$(gsn_print "$p" "$h" | jq -c 'has("goals_as_of")')" "false" "no queue file: no key" || { rm -rf "$p" "$h"; return 1; }
  printf '%s' '{"at":1763500000}' > "$p/goalqueue.json"
  assert_eq "$(gsn_print "$p" "$h" | jq -r '.goals_as_of')" "2025-11-18T21:06:40Z" "queue file: its sync time"
  local rc=$?; rm -rf "$p" "$h"; return $rc
}

test_gsn_as_of_only_change_does_not_push_but_a_goal_change_does() {
  local p h b c1 c2 c3; p=$(new_pipe); h=$(new_home); b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$p" "$h"; gsn_ok_curl "$b"
  printf '%s' '{"at":1763500000}' > "$p/goalqueue.json"
  gsn_push "$p" "$h" "$b"; c1=$(count_curl_calls "$b")
  printf '%s' '{"at":1763500300}' > "$p/goalqueue.json"   # a later sync, nothing else changed
  gsn_age_attempt "$p" 300; gsn_push "$p" "$h" "$b"; c2=$(count_curl_calls "$b")
  gsn_goal_file "$p" g1                                    # a goal appears
  gsn_age_attempt "$p" 300; gsn_push "$p" "$h" "$b"; c3=$(count_curl_calls "$b")
  cleanup_running; rm -rf "$p" "$h" "$b"
  assert_eq "$c1" "1" "first push" || return 1
  assert_eq "$c2" "1" "goals_as_of alone does not change the hash: no new push" || return 1
  assert_eq "$c3" "2" "a real goal change still pushes" || return 1
}

test_gsn_pending_marker_pushes_a_changed_goal_list_after_30_seconds() {
  local p h b c1 c2 c3; p=$(new_pipe); h=$(new_home); b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$p" "$h"; gsn_ok_curl "$b"; mkdir -p "$p/webhook"
  gsn_push "$p" "$h" "$b"; c1=$(count_curl_calls "$b")
  gsn_goal_file "$p" g1
  gsn_age_attempt "$p" 40                                  # 40 s: past the 30 s early gap, inside the usual ~216 s spacing
  gsn_push "$p" "$h" "$b"; c2=$(count_curl_calls "$b")     # no marker: the usual spacing holds
  echo "$(now_epoch)" > "$p/webhook/goal-push-pending"
  gsn_push "$p" "$h" "$b"; c3=$(count_curl_calls "$b")
  local left=0; [ -f "$p/webhook/goal-push-pending" ] && left=1
  cleanup_running; rm -rf "$p" "$h" "$b"
  assert_eq "$c1" "1" "first push" || return 1
  assert_eq "$c2" "1" "no marker, 40 s after the last attempt: still coalesced" || return 1
  assert_eq "$c3" "2" "marker + changed goal list + 40 s: pushed" || return 1
  assert_eq "$left" "0" "the marker is cleared by the push" || return 1
}

test_gsn_pending_marker_waits_30_seconds_and_needs_a_goal_change() {
  local p h b c1 c2 c3; p=$(new_pipe); h=$(new_home); b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$p" "$h"; gsn_ok_curl "$b"; mkdir -p "$p/webhook"
  gsn_push "$p" "$h" "$b"; c1=$(count_curl_calls "$b")
  echo "$(now_epoch)" > "$p/webhook/goal-push-pending"
  gsn_goal_file "$p" g1
  gsn_age_attempt "$p" 10; gsn_push "$p" "$h" "$b"; c2=$(count_curl_calls "$b")   # 10 s: too soon
  rm -f "$p/goal-g1.json"                                                         # list back to what was pushed: nothing to say
  gsn_age_attempt "$p" 40; gsn_push "$p" "$h" "$b"; c3=$(count_curl_calls "$b")
  cleanup_running; rm -rf "$p" "$h" "$b"
  assert_eq "$c2" "$c1" "10 s after the last attempt: coalesced" || return 1
  assert_eq "$c3" "$c1" "unchanged goal list: the marker alone does not push" || return 1
}

test_gsn_stale_pending_marker_is_dropped() {
  local p h b; p=$(new_pipe); h=$(new_home); b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$p" "$h"; gsn_ok_curl "$b"; mkdir -p "$p/webhook"
  gsn_push "$p" "$h" "$b"
  echo "$(( $(now_epoch) - 700 ))" > "$p/webhook/goal-push-pending"
  gsn_age_attempt "$p" 40; gsn_push "$p" "$h" "$b"
  local left=0; [ -f "$p/webhook/goal-push-pending" ] && left=1
  cleanup_running; rm -rf "$p" "$h" "$b"
  assert_eq "$left" "0" "a marker older than 10 minutes is removed (the event did not move the goal list)" || return 1
}

# ---- webhook-events.sh -------------------------------------------------------------------------------------------------------------------
gsn_relevant() {  # <gap> <events jsonl> -> "yes" | "no"; the registry cache knows issues 21 (open) and 30 (queued)
  local p out; p=$(new_pipe)
  printf '%s' '{"open":[{"id":"o","issue":21}],"queued":[{"id":"q","issue":30}],"recent":[]}' > "$p/goalqueue.json"
  out=$(PIPE="$p" bash -c ". '$GSN_RS/webhook-events.sh'; _wh_goals_relevant \"\$1\" \"\$2\" && echo yes || echo no" _ "$1" "$2"); rm -rf "$p"
  printf '%s' "$out"
}
test_gsn_relevant_events() {
  assert_eq "$(gsn_relevant 0 '{"event":"issues","action":"labeled","repo":"jpmoya/claude-agents","number":21}')" "yes" "a registry issue (listed in goalqueue.json) is labelled" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"issues","action":"closed","repo":"JPMoya/Claude-Agents","number":30}')" "yes" "a queued goal's registry issue closes (repo case ignored)" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"issues","action":"opened","repo":"jpmoya/claude-agents","number":99}')" "yes" "a new registry-repo issue may be a new goal" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"projects_v2_item","action":"edited","repo":"","number":null}')" "yes" "a project item changed" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"pull_request","action":"closed","repo":"example-owner/project-a","number":5}')" "yes" "a pull request closed or merged" || return 1
  assert_eq "$(gsn_relevant 1 '')" "yes" "a gap (lost events) may hide anything" || return 1
}
test_gsn_irrelevant_events() {
  assert_eq "$(gsn_relevant 0 '{"event":"issues","action":"labeled","repo":"jpmoya/claude-agents","number":77}')" "no" "an unrelated registry-repo issue edited" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"issues","action":"labeled","repo":"example-owner/project-a","number":21}')" "no" "same number in another repo" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"pull_request","action":"opened","repo":"example-owner/project-a","number":5}')" "no" "a pull request opened" || return 1
  assert_eq "$(gsn_relevant 0 '{"event":"check_run","action":"completed","repo":"example-owner/project-a","number":null}')" "no" "a CI check" || return 1
  assert_eq "$(gsn_relevant 0 '')" "no" "no events" || return 1
}

gsn_nudge() {  # <receiver url> <last sync age secs|none> -> "<goal-sync.last>|<marker present>"
  local p out m=0; p=$(new_pipe)
  printf '%s' '{"open":[{"id":"o","issue":21}]}' > "$p/goalqueue.json"
  [ "$2" = none ] || echo "$(( $(date +%s) - $2 ))" > "$p/goal-sync.last"
  PIPE="$p" WEBHOOK_RECEIVER_URL="$1" bash -c ". '$GSN_RS/webhook-events.sh'; _wh_goal_nudge 0 '{\"event\":\"projects_v2_item\"}'" >/dev/null 2>&1
  [ -f "$p/webhook/goal-push-pending" ] && m=1
  out="$(cat "$p/goal-sync.last" 2>/dev/null | awk '{ if ($1 == 0) print "reset"; else print "kept" }')|$m"; rm -rf "$p"
  printf '%s' "$out"
}
test_gsn_nudge_brings_the_sync_forward_on_the_vm_only_and_coalesces() {
  assert_eq "$(gsn_nudge '' 200)" "reset|1" "VM (no receiver URL), last sync 200 s ago: sync brought forward, push marker set" || return 1
  assert_eq "$(gsn_nudge '' 10)" "kept|0" "VM, last sync 10 s ago: coalesced, nothing changed" || return 1
  assert_eq "$(gsn_nudge '' none)" "reset|1" "VM, never synced: sync now" || return 1
  assert_eq "$(gsn_nudge 'https://hooks.example.invalid' 200)" "kept|0" "Mac (has a receiver URL): never nudges" || return 1
}

run_test test_gsn_goalasof_uses_the_queue_files_own_timestamp
run_test test_gsn_goalasof_falls_back_to_mtime_and_is_empty_without_the_file
run_test test_gsn_payload_carries_goals_as_of_only_with_a_queue_file
run_test test_gsn_as_of_only_change_does_not_push_but_a_goal_change_does
run_test test_gsn_pending_marker_pushes_a_changed_goal_list_after_30_seconds
run_test test_gsn_pending_marker_waits_30_seconds_and_needs_a_goal_change
run_test test_gsn_stale_pending_marker_is_dropped
run_test test_gsn_relevant_events
run_test test_gsn_irrelevant_events
run_test test_gsn_nudge_brings_the_sync_forward_on_the_vm_only_and_coalesces
