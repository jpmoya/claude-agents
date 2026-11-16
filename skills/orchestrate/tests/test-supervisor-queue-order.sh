# Tests for claude-agents#63 — supervisor.sh step 2 (drain) must launch the queued entry with the
# OLDEST queued_at (ties -> lowest issue number; missing/garbage queued_at -> queue file mtime), and
# the tick must decide capacity ONCE so the dispatch step (5) cannot steal a slot the drain was denied
# or take a new agent-go issue while an eligible queued entry waits.
#
#   AC1  queued_at order inverts file-name order            -> oldest queued_at launches
#   AC2  identical queued_at                                 -> lowest issue number (numeric) launches
#   AC3  missing / garbage queued_at                         -> ordered by file mtime, not promoted
#   AC4  capacity evaluated once per tick                    -> has_capacity called exactly once;
#                                                               drain denied => dispatch does not launch (#714: it claims and
#                                                               QUEUES the top candidate, at most one per tick)
#   AC5  eligible queued entry + agent-go issue              -> the queued entry launches; (#714) the new issue is claimed
#                                                               and queued behind it instead of waiting unclaimed
#   AC6  empty queue + agent-go issue                        -> issue is dispatched (guard, unchanged)
#   AC7  queue entry still in not_before backoff             -> does not block dispatch (guard)
#
# Same harness as test-supervisor-queued-not-counted.sh: isolated HOME + PIPE + QUEUE + LOGDIR, fake gh
# first on PATH, claude stubbed. "Tick" = one run of supervisor.sh. Placeholder repo names only.
# Hand-written expectations: "T-Nh" below means "now minus N hours"; a larger N is OLDER.

HERE_QO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_DIR_QO="$HERE_QO/.."

# qo_env — isolated env with open capacity, memory floor zeroed, claude stubbed, AC-power faked (macOS
# power_ok), claim settle 0, and a gh wrapper that answers `gh issue list --label agent-go` from
# $QO_GH/go-issues (one number per line) and `--label agent-in-progress` with nothing.
qo_env() {
  QO_PIPE=$(new_pipe); QO_HOME=$(new_home)
  QO_REPO="$QO_PIPE/repo-a"
  QO_GH="$QO_HOME/.local/bin"
  fixture_repo "$QO_REPO" "project-a/repo-a"
  mk_fake_gh "$QO_GH"
  mv "$QO_GH/gh" "$QO_GH/gh-base"
  cat > "$QO_GH/gh" <<'GHW'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "issue list"*"--label agent-go"*"--limit 500"*)   # the dispatch listing: its --jq already built {n,g,s,k} objects (backlog-sort.jq input)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    jq -Rsc '[split("\n")[] | select(length > 0) | tonumber | {n: ., g: false, s: false, k: [1, 0, 0, 0, .]}]' "$HERE/go-issues" 2>/dev/null
    exit 0 ;;
  "issue list"*"--label agent-go"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    cat "$HERE/go-issues" 2>/dev/null
    exit 0 ;;
  "issue list"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    exit 0 ;;
  *) exec "$HERE/gh-base" "$@" ;;
esac
GHW
  chmod +x "$QO_GH/gh"
  echo "project-a/repo-a" > "$QO_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$QO_GH/claude"; chmod +x "$QO_GH/claude"
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$QO_GH/pmset"; chmod +x "$QO_GH/pmset"
  : > "$QO_GH/go-issues"
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\n' > "$QO_HOME/.claude/pipeline/config.local.sh"
}

qo_cleanup() { cleanup_running; rm -rf "$QO_PIPE" "$QO_HOME" "${QO_COPY:-}"; QO_COPY=""; }

qo_dispatch_on() { printf 'DISPATCH_REPOS=("project-a/repo-a:%s")\n' "$QO_REPO" >> "$QO_HOME/.claude/pipeline/config.local.sh"; }

qo_run() {  # qo_run <script> — the script under test in the isolated env
  HOME="$QO_HOME" PATH="$QO_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$QO_PIPE" QUEUE="$QO_PIPE/queue" LOGDIR="$QO_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$@"
}
qo_tick() { qo_run "${1:-$ORCH_DIR_QO/supervisor.sh}" >/dev/null 2>&1; }
qo_log()  { cat "$QO_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }

qo_ago_iso() {  # <hours> -> ISO-8601 UTC, that many hours ago
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

# qo_entry <issue> <queued_at-hours-ago | missing | garbage> [mtime-hours-ago] [not_before]
qo_entry() {
  local issue=$1 qa=$2 mt=${3:-} nb=${4:-0} qa_val=""
  case "$qa" in
    missing) ;;
    garbage) qa_val="not-a-timestamp" ;;
    *) qa_val=$(qo_ago_iso "$qa") ;;
  esac
  python3 -c "
import json, sys, os, time
issue, repo, qa, mt, nb, path = sys.argv[1:7]
d = {'issue': issue, 'repo': repo, 'extra': '', 'reason': 'queued', 'not_before': int(nb)}
if qa != '': d['queued_at'] = qa
json.dump(d, open(path, 'w'))
if mt != '':
    t = time.time() - float(mt) * 3600
    os.utime(path, (t, t))
" "$issue" "$QO_REPO" "$qa_val" "$mt" "$nb" "$(rkp "$QO_PIPE/queue/orch-$issue.json")"
}

qo_launched() { qo_log | grep -F "[launch] #" | sed -n 's/.*\[launch\] #\([0-9]*\) .*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
qo_queued()   { local f out=""; for f in "$QO_PIPE"/queue/orch-*.json; do [ -e "$f" ] && out="$out $(basename "$f" .json | sed 's/orch-//')"; done; echo $out | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
qo_queued_issues() { python3 -c "
import json, glob, sys
print(' '.join(sorted((str(json.load(open(f))['issue']) for f in glob.glob(sys.argv[1] + '/queue/orch-*.json')), key=int)))" "$QO_PIPE"; }

# qo_claim_comments <issue> — gh-issue-comments-json-<issue> so this host wins the claim race
qo_win_claim() {
  python3 -c "
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump([{'body': '**[supervisor] NOTE** claim: %s %s' % (sys.argv[1], now), 'createdAt': now}], open(sys.argv[2], 'w'))
" "$(hostname -s)" "$QO_GH/gh-issue-comments-json-$1"
}

# ---------- AC1 ----------
test_qo_1_oldest_queued_at_launches_not_first_filename() {
  qo_env
  qo_entry 1 1     # newest  (T-1h) — first by file name
  qo_entry 5 5     # middle  (T-5h)
  qo_entry 9 9     # oldest  (T-9h) — last by file name
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued)
  qo_cleanup
  assert_eq "$launched" "9" "#63/1: the oldest queued_at (#9) launches, one per tick" || return 1
  assert_eq "$queued" "1 5" "#63/1: #9 consumed, #1 and #5 still queued" || return 1
}

# ---------- AC2 ----------
test_qo_2_identical_queued_at_lowest_issue_number_wins() {
  qo_env
  local same; same=$(qo_ago_iso 2)
  local n
  for n in 12 7 3; do   # file-name order is orch-12, orch-3, orch-7; numeric lowest is 3
    python3 -c "
import json, sys
json.dump({'issue': sys.argv[1], 'repo': sys.argv[2], 'extra': '', 'reason': 'queued', 'queued_at': sys.argv[3], 'not_before': 0}, open(sys.argv[4], 'w'))
" "$n" "$QO_REPO" "$same" "$(rkp "$QO_PIPE/queue/orch-$n.json")"
  done
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued)
  qo_cleanup
  assert_eq "$launched" "3" "#63/2: tie on queued_at -> lowest issue number (numeric: 3, not 12)" || return 1
  assert_eq "$queued" "7 12" "#63/2: the other two stay queued" || return 1
}

# ---------- AC3 ----------
# well-formed #2 = T-3h, #3 = T-1h; the malformed entry #1/#9 gets mtime <mt> hours ago.
qo_mtime_case() {  # qo_mtime_case <bad-issue> <missing|garbage> <mtime-hours-ago> -> prints launched
  qo_env
  qo_entry 2 3
  qo_entry 3 1
  qo_entry "$1" "$2" "$3"
  qo_tick
  qo_launched
  QO_LAST_QUEUED=$(qo_queued)
  qo_cleanup
}

test_qo_3a_missing_queued_at_is_not_promoted_as_oldest() {
  local launched; launched=$(qo_mtime_case 1 missing 2)   # mtime T-2h: newer than #2 (T-3h)
  assert_eq "$launched" "2" "#63/3a: entry without queued_at (mtime T-2h) must not jump ahead of #2 (T-3h) even though orch-1 sorts first" || return 1
}

test_qo_3b_garbage_queued_at_is_not_promoted_as_oldest() {
  local launched; launched=$(qo_mtime_case 1 garbage 2)
  assert_eq "$launched" "2" "#63/3b: unparseable queued_at (mtime T-2h) must not jump ahead of #2 (T-3h)" || return 1
}

test_qo_3c_missing_queued_at_uses_mtime_when_that_is_oldest() {
  local launched; launched=$(qo_mtime_case 9 missing 4)   # mtime T-4h: older than #2 (T-3h)
  assert_eq "$launched" "9" "#63/3c: entry without queued_at is ordered by its mtime (T-4h, oldest) -> launches" || return 1
}

test_qo_3d_garbage_queued_at_uses_mtime_when_that_is_oldest() {
  local launched; launched=$(qo_mtime_case 9 garbage 4)
  assert_eq "$launched" "9" "#63/3d: garbage queued_at falls back to mtime (T-4h, oldest) -> launches" || return 1
}

# ---------- AC4 ----------
# Copy the orchestrate dir + hooks into a temp tree and append a has_capacity stub to the COPY of
# pipeline-lib.sh (the repo's file is untouched): each call is logged to $HC_LOG and answers with the
# first line of $HC_SEQ (0 = capacity, 1 = none), popping it; an empty $HC_SEQ answers 0.
qo_stub_capacity() {  # qo_stub_capacity <answer-lines...> -> sets QO_COPY, HC_LOG, HC_SEQ
  QO_COPY=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-copy.XXXXXX")
  mkdir -p "$QO_COPY/skills" "$QO_COPY/hooks"
  cp -R "$ORCH_DIR_QO" "$QO_COPY/skills/orchestrate"
  rm -rf "$QO_COPY/skills/orchestrate/tests"
  cp "$ORCH_DIR_QO/../../hooks/pipeline-markers.sh" "$QO_COPY/hooks/"
  HC_LOG="$QO_COPY/hc-calls.log"; HC_SEQ="$QO_COPY/hc-seq"
  : > "$HC_LOG"; : > "$HC_SEQ"
  local a; for a in "$@"; do echo "$a" >> "$HC_SEQ"; done
  cat >> "$QO_COPY/skills/orchestrate/pipeline-lib.sh" <<STUB

has_capacity() {
  echo call >> "$HC_LOG"
  local first; first=\$(head -n 1 "$HC_SEQ" 2>/dev/null)
  tail -n +2 "$HC_SEQ" > "$HC_SEQ.tmp" 2>/dev/null; mv "$HC_SEQ.tmp" "$HC_SEQ"
  [ "\${first:-0}" = "0" ]
}
STUB
}

test_qo_4a_capacity_evaluated_once_per_tick() {
  qo_env; qo_dispatch_on            # empty queue, dispatch configured, no agent-go candidates
  qo_stub_capacity 0 0 0
  qo_tick "$QO_COPY/skills/orchestrate/supervisor.sh"
  local n; n=$(wc -l < "$HC_LOG" | tr -d ' ')
  qo_cleanup
  assert_eq "$n" "1" "#63/4a: exactly one has_capacity call per tick (drain + dispatch share it)" || return 1
}

test_qo_4b_drain_denied_means_dispatch_queues_the_candidate() {
  # #714 replaces #63's "no pick-up while the drain is denied": the claimed candidate is queued, never launched into a slot
  qo_env; qo_dispatch_on
  echo 500 > "$QO_GH/go-issues"; qo_win_claim 500
  qo_entry 9 9
  qo_stub_capacity 1 0 0            # the tick's single decision: no capacity; any later check (a slot freed mid-tick) would say yes
  qo_tick "$QO_COPY/skills/orchestrate/supervisor.sh"
  local calls launched queued log; calls=$(gh_calls "$QO_GH"); launched=$(qo_launched); queued=$(qo_queued_issues); log=$(qo_log)
  qo_cleanup
  assert_contains "$calls" "issue comment 500" "#714/4b: the new agent-go issue is claimed" || return 1
  assert_eq "$launched" "" "#714/4b: nothing launched while no slot is free" || return 1
  assert_eq "$queued" "9 500" "#714/4b: #500 got a place in the queue behind #9" || return 1
  assert_contains "$log" "[dispatch] project-a/repo-a#500 — claimed by" "#714/4b: dispatch logged" || return 1
}

test_qo_4c_at_most_one_enqueue_per_tick() {
  qo_env; qo_dispatch_on
  printf '500\n501\n' > "$QO_GH/go-issues"; qo_win_claim 500; qo_win_claim 501
  qo_stub_capacity 1 0 0 0
  qo_tick "$QO_COPY/skills/orchestrate/supervisor.sh"
  local queued; queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$queued" "500" "#714/4c: one top candidate is claimed and queued per tick" || return 1
}

# ---------- AC5-7 ----------
test_qo_5_queue_drain_takes_the_slot_and_the_new_issue_is_still_queued() {
  # #714 replaces #63/5: the drain launches the oldest entry, and the new agent-go issue is claimed and queued (queued_at = now),
  # not left unclaimed behind a queue that relaunches keep full
  qo_env; qo_dispatch_on
  printf 'MAX_CONCURRENT=1\n' >> "$QO_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\nexec /bin/sleep 20\n' > "$QO_GH/claude"
  echo 500 > "$QO_GH/go-issues"; qo_win_claim 500
  qo_entry 9 9
  qo_tick
  local calls launched queued qat; calls=$(gh_calls "$QO_GH"); launched=$(qo_launched); queued=$(qo_queued_issues)
  qat=$(python3 -c "
import json, glob, datetime, sys
for f in glob.glob(sys.argv[1] + '/queue/orch-*.json'):
    d = json.load(open(f))
    if str(d['issue']) == '500':
        t = datetime.datetime.strptime(d['queued_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        print(int(abs((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()) < 120))
" "$QO_PIPE")
  qo_cleanup
  assert_eq "$launched" "9" "#714/5: the oldest queued entry (#9) takes the slot" || return 1
  assert_contains "$calls" "issue comment 500" "#714/5: the new issue is claimed" || return 1
  assert_eq "$queued" "500" "#714/5: #500 is queued (no free slot left), #9 consumed" || return 1
  assert_eq "$qat" "1" "#714/5: queued_at of #500 is now" || return 1
}

test_qo_6_empty_queue_still_dispatches_new_issue() {
  qo_env; qo_dispatch_on
  echo 500 > "$QO_GH/go-issues"; qo_win_claim 500
  qo_tick
  local calls log; calls=$(gh_calls "$QO_GH"); log=$(qo_log)
  qo_cleanup
  assert_contains "$calls" "issue comment 500" "#63/6: claim comment posted for the agent-go issue" || return 1
  assert_contains "$log" "[dispatch] project-a/repo-a#500 — claimed by" "#63/6: dispatched" || return 1
}

test_qo_7_queue_entry_in_backoff_does_not_block_dispatch() {
  qo_env; qo_dispatch_on
  echo 500 > "$QO_GH/go-issues"; qo_win_claim 500
  qo_entry 9 9 "" "$(( $(date +%s) + 3600 ))"   # not_before = now + 1h: not eligible
  qo_tick
  local calls log queued; calls=$(gh_calls "$QO_GH"); log=$(qo_log); queued=$(qo_queued)
  qo_cleanup
  assert_contains "$calls" "issue comment 500" "#63/7: claim posted despite the backed-off entry" || return 1
  assert_contains "$log" "[dispatch] project-a/repo-a#500 — claimed by" "#63/7: dispatched" || return 1
  assert_eq "$queued" "9" "#63/7: backed-off entry untouched" || return 1
}

run_test test_qo_1_oldest_queued_at_launches_not_first_filename
run_test test_qo_2_identical_queued_at_lowest_issue_number_wins
run_test test_qo_3a_missing_queued_at_is_not_promoted_as_oldest
run_test test_qo_3b_garbage_queued_at_is_not_promoted_as_oldest
run_test test_qo_3c_missing_queued_at_uses_mtime_when_that_is_oldest
run_test test_qo_3d_garbage_queued_at_uses_mtime_when_that_is_oldest
run_test test_qo_4a_capacity_evaluated_once_per_tick
test_qo_4d_a_free_slot_after_the_drain_does_not_let_the_new_issue_jump_the_line() {
  # MAX_CONCURRENT=3, two older queued entries, one agent-go issue: the drain launches the oldest (#9), a slot is still free,
  # yet #500 is queued behind #8 instead of launching ahead of it
  qo_env; qo_dispatch_on
  printf '#!/bin/bash\nexec /bin/sleep 20\n' > "$QO_GH/claude"
  echo 500 > "$QO_GH/go-issues"; qo_win_claim 500
  qo_entry 9 9; qo_entry 8 5
  qo_tick
  local launched queued; launched=$(qo_launched); queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$launched" "9" "#714/4d: the oldest entry launches" || return 1
  assert_eq "$queued" "8 500" "#714/4d: #8 keeps its place and #500 is queued, not launched" || return 1
}

test_qo_4e_the_queued_new_issue_launches_before_an_entry_queued_after_it() {
  qo_env; qo_dispatch_on
  echo 500 > "$QO_GH/go-issues"; qo_win_claim 500
  qo_stub_capacity 1 0 0 0 0 0      # tick 1: no capacity, #500 is claimed and queued (queued_at = now)
  qo_tick "$QO_COPY/skills/orchestrate/supervisor.sh"
  : > "$QO_GH/go-issues"
  python3 -c "
import json, sys, datetime
t = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'issue': '77', 'repo': sys.argv[1], 'extra': '', 'reason': 'queued', 'queued_at': t, 'not_before': 0}, open(sys.argv[2], 'w'))
" "$QO_REPO" "$(rkp "$QO_PIPE/queue/orch-77.json")"   # queued after #500
  qo_tick                           # tick 2: capacity again, the real has_capacity
  local launched queued; launched=$(qo_launched); queued=$(qo_queued_issues)
  qo_cleanup
  assert_eq "$launched" "500" "#714/4e: the earlier-queued new issue launches first" || return 1
  assert_eq "$queued" "77" "#714/4e: the entry queued after it waits" || return 1
}

run_test test_qo_4b_drain_denied_means_dispatch_queues_the_candidate
run_test test_qo_4d_a_free_slot_after_the_drain_does_not_let_the_new_issue_jump_the_line
run_test test_qo_4e_the_queued_new_issue_launches_before_an_entry_queued_after_it
run_test test_qo_4c_at_most_one_enqueue_per_tick
run_test test_qo_5_queue_drain_takes_the_slot_and_the_new_issue_is_still_queued
run_test test_qo_6_empty_queue_still_dispatches_new_issue
run_test test_qo_7_queue_entry_in_backoff_does_not_block_dispatch
