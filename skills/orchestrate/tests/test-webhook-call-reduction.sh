# #773 AC8 — the supervisor's GitHub calls per idle tick drop when the webhook queue is on. Real gh-budget.sh / webhook-events.sh / config.sh
# with a stub `gh` that answers canned JSON: the numbers come from the call log (gh_tick_mark / gh_tick_summary, the per-tick counter the
# supervisor logs as "[gh-calls] tick calls=N ..."). A "tick" is the idle read set of one supervisor tick: the repo sync, the goal-sync style
# REST list in a separate process that never synced, and the `issue view|list`, `pr list`, `repo view` reads of reconcile / sweep /
# repo_canon (the top sources in the 2026-11-17..18 call log). Idle = an empty event queue. The ratio is the ticket's "at least 80% fewer"
# bar on this read set; the live 30-idle-tick average is measured after go-live (docs/webhook-events.md). Prefix cr_ / CR_.

CR_RS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cr_setup() {
  CR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-cr.XXXXXX"); mkdir -p "$CR/bin" "$CR/pipe" "$CR/home/.claude/pipeline" "$CR/checkout"
  git -C "$CR/checkout" init -q 2>/dev/null; git -C "$CR/checkout" remote add origin "https://github.com/Example-Owner/Project-A.git"
  echo '[]' > "$CR/since-resp.json"
  cat > "$CR/bin/gh" <<EOF
#!/bin/bash
D="$CR"
printf '%s\\n' "\$*" >> "\$D/calls.log"
if [ "\$1 \$2" = "api rate_limit" ]; then printf '5000\t9999999999\t5000\t9999999999\n'; exit 0; fi
case "\$*" in
  *"issues?state=all"*"since="*) cat "\$D/since-resp.json"; exit 0 ;;
  "api repos/"*"/comments"*) echo '[]'; exit 0 ;;
  "api repos/"*) echo '{"number":1}'; exit 0 ;;
  "issue view"*) echo '{"state":"OPEN","comments":[]}'; exit 0 ;;
  "issue list"*|"pr list"*) echo '[]'; exit 0 ;;
  "repo view"*) echo '{"nameWithOwner":"example-owner/project-a"}'; exit 0 ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$CR/bin/gh"
}
cr_teardown() { rm -rf "$CR"; }
# cr_proc <enabled 0|1> <bash text> — a fresh process (config.sh sourced) like one supervisor / goal-sync process
cr_proc() {
  PATH="$CR/bin:$PATH" PIPE="$CR/pipe" LOGDIR="$CR/log" HOME="$CR/home" GH_BUDGET_ENABLED=1 WEBHOOK_EVENTS_ENABLED="$1" WEBHOOK_OWNERS="example-owner" \
    GH_CACHE_TTL_SECS=60 bash -c ". '$CR_RS/config.sh'; $2" 2>"$CR/err"
}
# the idle read set of one tick; prints gh_tick_summary
CR_SUP='gh_tick_mark; webhook_tick_prepare; gh_since_sync example-owner/project-a
  gh api repos/example-owner/project-a/issues/5 >/dev/null; gh api repos/example-owner/project-a/issues/5/comments >/dev/null
  gh api repos/example-owner/project-a/issues/6 >/dev/null
  ( cd "$CR_CHECKOUT"; gh issue view 5 --json state,comments >/dev/null; gh issue view 6 --json state,comments >/dev/null
    gh issue list --state open --json number >/dev/null; gh pr list --state merged --json number >/dev/null; gh repo view --json nameWithOwner >/dev/null )
  bash -c ". \"$CR_CONFIG\"; gh api \"repos/example-owner/project-a/issues?state=open\" >/dev/null"   # goal sync: a process that never synced the repo
  gh_tick_summary'
cr_tick() { CR_CHECKOUT="$CR/checkout" CR_CONFIG="$CR_RS/config.sh" cr_proc "$1" "export CR_CHECKOUT CR_CONFIG; $CR_SUP"; }
cr_age_to() {  # <secs ago> — make every cached read that old: the 60 s TTL has lapsed; 120 s is inside the 20 min cap, 21 min is past it
  local f t=$(( $(date +%s) - $1 )); for f in "$CR/pipe/gh-cache"/[0-9]*; do [ -f "$f" ] && { { echo "$t"; tail -n +2 "$f"; } > "$f.t"; mv "$f.t" "$f"; }; done
}
cr_calls() { printf '%s' "$1" | sed -n 's/^calls=\([0-9]*\) .*/\1/p'; }
cr_event() {  # <seq> <number|null>
  mkdir -p "$CR/pipe/webhook"
  printf '{"seq":%s,"ts":%s,"delivery":"d-%s","event":"issues","action":"edited","repo":"Example-Owner/Project-A","owner":"example-owner","number":%s,"sender":"octo-user"}\n' "$1" "$(date +%s)" "$1" "$2" >> "$CR/pipe/webhook/events.jsonl"
}

test_cr_idle_tick_makes_at_least_80_percent_fewer_calls_with_the_queue_on() {
  cr_setup
  cr_tick 0 >/dev/null; cr_age_to 120; local off; off=$(cr_tick 0)
  cr_teardown; cr_setup
  cr_event 1 99                                                   # one unrelated event so the queue is not empty
  cr_tick 1 >/dev/null; cr_age_to 120; local on; on=$(cr_tick 1)  # tick 1 warms and stamps the fallback; tick 2 is idle
  local n_off n_on; n_off=$(cr_calls "$off"); n_on=$(cr_calls "$on")
  cr_teardown
  [ -n "$n_off" ] && [ -n "$n_on" ] || { fail "no summary line: off=[$off] on=[$on]"; return 1; }
  assert_contains "$off" "webhook=off" "the counter says which mode it measured" || return 1
  assert_contains "$on" "webhook=on" "the counter says which mode it measured" || return 1
  [ "$n_off" -ge 5 ] || { fail "baseline too small to mean anything: off=$n_off ($off)"; return 1; }
  [ $(( n_on * 5 )) -le "$n_off" ] || { fail "AC8: idle tick with the queue on made $n_on calls vs $n_off off (need <= 20%)"; return 1; }
}

test_cr_an_event_re_reads_only_what_it_touched() {
  cr_setup
  cr_event 1 99
  cr_tick 1 >/dev/null; cr_age_to 120
  cr_event 2 5                                                    # issue 5 changed
  local s n; s=$(cr_tick 1); n=$(cr_calls "$s")
  local six; six=$(grep -c '^api repos/example-owner/project-a/issues/6$' "$CR/calls.log" 2>/dev/null)
  local six_view; six_view=$(grep -c '^issue view 6 ' "$CR/calls.log" 2>/dev/null)
  cr_teardown
  [ "${n:-0}" -ge 1 ] || { fail "the touched issue was not re-read: $s"; return 1; }
  # touched: issue 5 (REST, comments, issue view) + the repo's lists (issue list, pr list, repo view, REST list) = 7; issue 6 stays cached
  [ "$n" -le 7 ] || { fail "an event for one issue re-read too much: $s"; return 1; }
  assert_eq "$six" "1" "the untouched issue 6 was read once in total (tick 1), not again" || return 1
  assert_eq "$six_view" "1" "gh issue view 6 was read once in total (tick 1), not again" || return 1
}

test_cr_a_due_fallback_poll_runs_the_full_sync() {
  cr_setup
  cr_event 1 99
  cr_tick 1 >/dev/null; cr_age_to 120
  echo $(( $(date +%s) - 25 * 60 )) > "$CR/pipe/webhook/full.example-owner_project-a"   # the fallback poll is overdue
  local s since; s=$(cr_tick 1); since=$(grep -c 'issues?state=all' "$CR/calls.log")
  local stamp_age; stamp_age=$(( $(date +%s) - $(cat "$CR/pipe/webhook/full.example-owner_project-a") ))
  cr_teardown
  assert_eq "$since" "1" "the overdue repo did its full since-sync (the keep-the-20-minute-poll requirement)" || return 1
  [ "$stamp_age" -lt 60 ] || { fail "the full-sync stamp was not refreshed ($stamp_age s old)"; return 1; }
}

test_cr_a_dropped_event_cannot_leave_a_list_stale_past_the_fallback_interval() {
  cr_setup
  cr_event 1 99
  cr_tick 1 >/dev/null
  cr_age_to $(( 21 * 60 ))      # past WEBHOOK_LIST_MAX_AGE_SECS while the supervisor keeps applying an empty queue and the fallback stays fresh
  date +%s > "$CR/pipe/webhook/full.example-owner_project-a"
  local s n; s=$(cr_tick 1); n=$(cr_calls "$s")
  cr_teardown
  [ "${n:-0}" -ge 3 ] || { fail "a 21-minute-old issue list / pr list / repo view must be re-read even on trust: $s"; return 1; }
}

test_cr_with_the_switch_off_every_read_is_unchanged_and_nothing_is_trusted() {
  cr_setup
  cr_tick 0 >/dev/null; cr_age_to 120
  cr_tick 0 >/dev/null
  local pr view; pr=$(grep -c 'pr list' "$CR/log/gh-calls.log"); view=$(grep -c 'issue view' "$CR/log/gh-calls.log")
  cr_teardown
  assert_eq "$pr" "2" "AC9: pr list is never cached with the switch off (one call per tick)" || return 1
  assert_eq "$view" "4" "AC9: issue view re-read after its TTL, two per tick" || return 1
}

test_cr_the_counter_line_is_logged_per_supervisor_tick() {
  local sup="$CR_RS/supervisor.sh"
  assert_contains "$(grep -n 'gh_tick_mark' "$sup")" "gh_tick_mark" "supervisor marks the tick start" || return 1
  assert_contains "$(grep -n '\[gh-calls\] tick' "$sup")" "gh_tick_summary" "supervisor logs the per-tick summary" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_cr_'); do run_test "$t"; done
