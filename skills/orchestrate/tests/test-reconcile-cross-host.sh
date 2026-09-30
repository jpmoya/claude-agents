# Tests for claude-agents#119 — supervisor reconcile (section 4) must not strip agent-in-progress from a run another
# host owns, and orchestrate.sh launch/queue must post the ownership claim line reconcile reads.
#
#   AC1  orchestrate.sh launch AND queue paths each post exactly one `**[supervisor] NOTE** claim: <hostname -s> <UTC ISO ts>`
#        (dispatch's format, supervisor.sh:541); a failing comment call never blocks the launch
#   AC2  reconcile: latest claim (no time window) naming another host -> label kept; naming this host / no claim -> today's rule
#   AC3  (a) other-host claim, 2h old, no local state -> kept   (b) this-host claim, 2h old -> cleared
#        (c) older other-host claim + newer this-host claim -> cleared   (d) no claim -> as today   (e) launch/queue post one claim
#
# Isolated HOME/PIPE/QUEUE/LOGDIR. Placeholder repo names only. Own gh stub for reconcile: applies whatever --jq the
# supervisor passes to a full issue JSON, so the tests do not pin the query shape. Bash 3.2 portable.

HERE_RH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_RH="$HERE_RH/../orchestrate.sh"
SUP_RH="$HERE_RH/../supervisor.sh"
RH_THIS=$(hostname -s)
RH_OTHER="other-host-zz"

rh_iso_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

# ---- reconcile side ---------------------------------------------------------------------------------------------
rh_env() {
  RH_PIPE=$(new_pipe); RH_HOME=$(new_home)
  RH_REPO="$RH_PIPE/repo-a"; RH_GH="$RH_HOME/.local/bin"
  fixture_repo "$RH_REPO" "project-a/repo-a"
  mkdir -p "$RH_GH"; : > "$RH_GH/gh-calls.log"
  cat > "$RH_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
expr=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
emit() { if [ -n "$expr" ]; then printf '%s' "$1" | jq -r "$expr"; else printf '%s\n' "$1"; fi; }
case "$*" in
  "issue list"*"--label agent-in-progress"*) emit '[{"number":88}]' ;;
  "issue list"*) emit '[]' ;;
  "issue view"*)
    upd=$(cat "$HERE/updated-at"); com=$(cat "$HERE/comments-json")
    emit "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"agent-in-progress\"}],\"updatedAt\":\"$upd\",\"comments\":$com}" ;;
  *) exit 0 ;;
esac
GH_EOF
  chmod +x "$RH_GH/gh"
  printf 'MEM_FLOOR_MB=0\nDISPATCH_REPOS=("project-a/repo-a:%s")\n' "$RH_REPO" > "$RH_HOME/.claude/pipeline/config.local.sh"
}
rh_cleanup() { rm -rf "$RH_PIPE" "$RH_HOME"; }
# rh_comment <body> <age-secs> -> one comment JSON object
rh_comment() { jq -cn --arg b "$1" --arg t "$(rh_iso_ago "$2")" '{body:$b,createdAt:$t}'; }
# rh_tick <comments-json> — issue 88 has agent-in-progress, no local pid/queue; updatedAt 2h old
rh_tick() {
  rh_iso_ago 7200 > "$RH_GH/updated-at"; printf '%s' "$1" > "$RH_GH/comments-json"
  HOME="$RH_HOME" PATH="$RH_GH:/usr/bin:/bin" PIPE="$RH_PIPE" QUEUE="$RH_PIPE/queue" LOGDIR="$RH_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_RH" >/dev/null 2>&1
  RH_LOG=$(cat "$RH_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  RH_CALLS=$(cat "$RH_GH/gh-calls.log")
}

test_rh_a_other_host_claim_2h_old_keeps_label() {
  rh_env
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_OTHER 2026-01-01T00:00:00Z" 7200)]"
  rh_cleanup
  assert_not_contains "$RH_CALLS" "issue edit 88 --remove-label" "#119/a: label not removed" || return 1
  assert_not_contains "$RH_LOG" "[reconcile]" "#119/a: no reconcile line" || return 1
}

test_rh_a2_other_host_claim_days_old_still_keeps_label() {
  rh_env   # no time window on the claim
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_OTHER 2026-01-01T00:00:00Z" 400000)]"
  rh_cleanup
  assert_not_contains "$RH_CALLS" "issue edit 88 --remove-label" "#119/a2: label not removed" || return 1
}

test_rh_a3_other_host_claim_then_later_plain_comments_keeps_label() {
  rh_env   # the claim stays the owner even when ordinary comments follow it
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_OTHER 2026-01-01T00:00:00Z" 20000),$(rh_comment "**[test-writer] TESTS WRITTEN**" 7200)]"
  rh_cleanup
  assert_not_contains "$RH_CALLS" "issue edit 88 --remove-label" "#119/a3: label not removed" || return 1
}

test_rh_b_this_host_claim_2h_old_clears_label() {
  rh_env
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_THIS 2026-01-01T00:00:00Z" 7200)]"
  rh_cleanup
  assert_contains "$RH_CALLS" "issue edit 88 --remove-label agent-in-progress" "#119/b: label removed" || return 1
  assert_contains "$RH_LOG" "[reconcile] project-a/repo-a#88" "#119/b: reconcile logged" || return 1
}

test_rh_c_older_other_newer_this_clears_label() {
  rh_env
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_OTHER 2026-01-01T00:00:00Z" 20000),$(rh_comment "**[supervisor] NOTE** claim: $RH_THIS 2026-01-01T01:00:00Z" 7200)]"
  rh_cleanup
  assert_contains "$RH_CALLS" "issue edit 88 --remove-label agent-in-progress" "#119/c: label removed" || return 1
}

test_rh_c2_older_this_newer_other_keeps_label() {
  rh_env   # latest claim wins in both directions
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_THIS 2026-01-01T00:00:00Z" 20000),$(rh_comment "**[supervisor] NOTE** claim: $RH_OTHER 2026-01-01T01:00:00Z" 7200)]"
  rh_cleanup
  assert_not_contains "$RH_CALLS" "issue edit 88 --remove-label" "#119/c2: label not removed" || return 1
}

test_rh_d_no_claim_stale_comment_clears_label() {
  rh_env
  rh_tick "[$(rh_comment "**[test-writer] TESTS WRITTEN**" 7200)]"
  rh_cleanup
  assert_contains "$RH_CALLS" "issue edit 88 --remove-label agent-in-progress" "#119/d: label removed as today" || return 1
}

test_rh_d2_no_claim_fresh_comment_keeps_label() {
  rh_env
  rh_tick "[$(rh_comment "**[test-writer] TESTS WRITTEN**" 60)]"
  rh_cleanup
  assert_not_contains "$RH_CALLS" "issue edit 88 --remove-label" "#119/d2: label kept as today" || return 1
}

test_rh_e_this_host_claim_fresh_comment_keeps_label() {
  rh_env   # own claim: existing staleness rule unchanged
  rh_tick "[$(rh_comment "**[supervisor] NOTE** claim: $RH_THIS 2026-01-01T00:00:00Z" 60)]"
  rh_cleanup
  assert_not_contains "$RH_CALLS" "issue edit 88 --remove-label" "#119/e: label kept" || return 1
}

test_rh_f_claim_text_not_at_start_of_comment_is_ignored() {
  rh_env   # only comments STARTING with the claim prefix count
  rh_tick "[$(rh_comment "quoting: **[supervisor] NOTE** claim: $RH_OTHER 2026-01-01T00:00:00Z" 7200)]"
  rh_cleanup
  assert_contains "$RH_CALLS" "issue edit 88 --remove-label agent-in-progress" "#119/f: label removed" || return 1
}

# ---- orchestrate.sh side ----------------------------------------------------------------------------------------
rh_o_env() {  # rh_o_env <full|open>
  local mode=$1 i
  RO_PIPE=$(new_pipe); RO_HOME=$(new_home)
  RO_REPO="$RO_PIPE/repo-a"
  fixture_repo "$RO_REPO" "project-a/repo-a"
  RO_BIN="$RO_HOME/.local/bin"
  mk_fake_gh "$RO_BIN"
  echo "project-a/repo-a" > "$RO_BIN/gh-name-with-owner"
  if [ "$mode" = "full" ]; then
    for i in 1 2 3; do mk_running "$RO_PIPE" "$i" "$RO_REPO"; done
  else
    echo 'MEM_FLOOR_MB=0' > "$RO_HOME/.claude/pipeline/config.local.sh"
    printf '#!/bin/bash\nexec sleep 30\n' > "$RO_BIN/claude"; chmod +x "$RO_BIN/claude"
  fi
}
rh_o_cleanup() {
  local f pid
  for f in "$RO_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running; rm -rf "$RO_PIPE" "$RO_HOME"
}
rh_o_launch() {
  RO_OUT=$(HOME="$RO_HOME" PATH="$RO_BIN:/usr/bin:/bin" PIPE="$RO_PIPE" QUEUE="$RO_PIPE/queue" "$ORCH_RH" "$RO_REPO" "$1" 2>&1); RO_RC=$?
  RO_CLAIMS=$(grep -F 'issue comment' "$RO_BIN/gh-calls.log" | grep -F '**[supervisor] NOTE** claim: ' || true)
  RO_NCLAIMS=$(printf '%s' "$RO_CLAIMS" | grep -c . || true)
}
# rh_claim_ok <line> — line is `issue comment <n> --body **[supervisor] NOTE** claim: <host> <YYYY-MM-DDTHH:MM:SSZ>` exactly
rh_claim_ok() {
  printf '%s' "$1" | grep -Eq "^issue comment [0-9]+ --body \*\*\[supervisor\] NOTE\*\* claim: $RH_THIS [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$" && echo ok || echo bad
}

test_rh_o_launch_path_posts_one_claim_line() {
  rh_o_env open; rh_o_launch 41
  local out="$RO_OUT" n="$RO_NCLAIMS" line="$RO_CLAIMS" rc="$RO_RC" ok; ok=$(rh_claim_ok "$line")
  rh_o_cleanup
  assert_exit0 "$rc" "#119/AC1: launch exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "#119/AC1: took the launch path" || return 1
  assert_eq "$n" "1" "#119/AC1: exactly one claim comment on launch" || return 1
  assert_eq "$ok" "ok" "#119/AC1: dispatch format '**[supervisor] NOTE** claim: <host -s> <UTC ts>' — got: $line" || return 1
  assert_contains "$line" "issue comment 41 " "#119/AC1: posted on the launched issue" || return 1
}

test_rh_o_queue_path_posts_one_claim_line() {
  rh_o_env full; rh_o_launch 42
  local out="$RO_OUT" n="$RO_NCLAIMS" line="$RO_CLAIMS" rc="$RO_RC" ok; ok=$(rh_claim_ok "$line")
  rh_o_cleanup
  assert_exit0 "$rc" "#119/AC1: queue exits 0" || return 1
  assert_contains "$out" "queued #42" "#119/AC1: took the queue path" || return 1
  assert_eq "$n" "1" "#119/AC1: exactly one claim comment on queue" || return 1
  assert_eq "$ok" "ok" "#119/AC1: queue claim in dispatch format — got: $line" || return 1
}

test_rh_o_failed_claim_comment_never_blocks_launch() {
  rh_o_env open
  mv "$RO_BIN/gh" "$RO_BIN/gh-real"
  cat > "$RO_BIN/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in "issue comment"*) printf '%s\n' "$*" >> "$HERE/gh-calls.log"; exit 1 ;; esac
exec "$HERE/gh-real" "$@"
GH_EOF
  chmod +x "$RO_BIN/gh"
  rh_o_launch 43
  local out="$RO_OUT" rc="$RO_RC" started=no
  [ -f "$RO_PIPE/orch-43.pid" ] && started=yes
  rh_o_cleanup
  assert_exit0 "$rc" "#119/AC1: launch still exits 0 when the claim comment fails" || return 1
  assert_contains "$out" "launched orchestrator" "#119/AC1: still launched" || return 1
  assert_eq "$started" "yes" "#119/AC1: pid file written" || return 1
}

run_test test_rh_a_other_host_claim_2h_old_keeps_label
run_test test_rh_a2_other_host_claim_days_old_still_keeps_label
run_test test_rh_a3_other_host_claim_then_later_plain_comments_keeps_label
run_test test_rh_b_this_host_claim_2h_old_clears_label
run_test test_rh_c_older_other_newer_this_clears_label
run_test test_rh_c2_older_this_newer_other_keeps_label
run_test test_rh_d_no_claim_stale_comment_clears_label
run_test test_rh_d2_no_claim_fresh_comment_keeps_label
run_test test_rh_e_this_host_claim_fresh_comment_keeps_label
run_test test_rh_f_claim_text_not_at_start_of_comment_is_ignored
run_test test_rh_o_launch_path_posts_one_claim_line
run_test test_rh_o_queue_path_posts_one_claim_line
run_test test_rh_o_failed_claim_comment_never_blocks_launch
