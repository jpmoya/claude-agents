# #213 — the one-shot, idempotent cutover step in install.sh (number-keyed -> repo-keyed names), and
# the observability of a migration / launch failure.
#
#   AC7  negative: a file whose .repo is missing/unresolvable stays in place, is printed, exit 0; a
#        second run changes nothing
#   AC8  cutover: orch-198.* (live), orch-196.*, queue/orch-196.json -> no ^orch-[0-9]+\. file remains;
#        a supervisor tick sees the live run and the queued entry
#   AC12 observability: a migration failure (route run-key-migration) and a launch failure (route
#        launch) append an `error` row to events.jsonl with release = the claude-agents checkout SHA and
#        host, post through the existing Slack path (curl chat.postMessage), and leak no token.
#        Triggers chosen by the test author: migration = an unresolvable .repo file; launch = `gh repo
#        view` failing for the hand-launched checkout.
# install.sh runs ONLY under an isolated HOME with stub crontab/gh/claude/curl first on PATH.
# Placeholder repos only. Bash 3.2 portable.

HERE_RK4=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_RK4/lib/runkey.sh"
ROOT_RK4=$(cd "$HERE_RK4/../../.." && pwd)
RK4_TOKEN="xoxb-FAKE-213-TOKEN"

rk4_install() {  # rk4_install -> output on stdout, rc in RK4_RC. Refuses unless crontab is the stub.
  local resolved
  resolved=$(HOME="$RK_HOME" PATH="$RK_BIN:/usr/bin:/bin" bash -c 'command -v crontab')
  if [ "$resolved" != "$RK_BIN/crontab" ]; then echo "REFUSING: crontab is [$resolved]" >&2; RK4_RC=99; return 99; fi
  RK4_OUT=$(HOME="$RK_HOME" PATH="$RK_BIN:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
    "$ROOT_RK4/skills/orchestrate/install.sh" --minute even 2>&1)
  RK4_RC=$?
}

rk4_snapshot() {  # names + content checksums of every file under PIPE (not subdir logs of the test itself)
  ( cd "$RK_PIPE" && find . -type f -not -name 'supervisor.lock' | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done )
}

rk4_slack_cfg() {
  cat >> "$RK_HOME/.claude/pipeline/config.local.sh" <<CFG
SLACK_BOT_TOKEN="$RK4_TOKEN"
SLACK_ENGINEERING_CHANNEL="C213FAKE"
CFG
}

rk4_json_queue() {  # rk4_json_queue <name-without-.json> <issue> <repo path>
  python3 -c "
import json, sys
json.dump({'issue': sys.argv[2], 'repo': sys.argv[3], 'extra': '', 'reason': 'queued',
           'queued_at': '2026-10-12T08:00:00Z', 'not_before': 0}, open('$RK_PIPE/queue/' + sys.argv[1] + '.json', 'w'))
" "$1" "$2" "$3"
}

# AC8
test_rk4_cutover_renames_everything_and_supervisor_tick_sees_it() {
  rk_env
  local pid198; pid198=$(rk_live)
  echo "$pid198" > "$RK_PIPE/orch-198.pid"; echo "$RK_REPO_B" > "$RK_PIPE/orch-198.repo"
  date -u +%FT%TZ > "$RK_PIPE/orch-198.start"; : > "$RK_PIPE/orch-198.log"
  echo "$(rk_dead_pid)" > "$RK_PIPE/orch-196.pid"; echo "$RK_REPO_A" > "$RK_PIPE/orch-196.repo"
  touch "$RK_PIPE/orch-196.held"; echo "Title A" > "$RK_PIPE/orch-196.title"; date -u +%FT%TZ > "$RK_PIPE/orch-196.start"
  rk4_json_queue orch-77 77 "$RK_REPO_B"
  rk4_json_queue orch-196 196 "$RK_REPO_A"
  rk4_install
  local left_pipe left_queue pid_after a_held a_title q77 q196 repo_in_q
  left_pipe=$(ls "$RK_PIPE" | grep -E '^orch-[0-9]+\.' | tr '\n' ' ')
  left_queue=$(ls "$RK_PIPE/queue" | grep -E '^orch-[0-9]+\.' | tr '\n' ' ')
  pid_after=$(cat "$RK_PIPE/$RK_KB-198.pid" 2>/dev/null || echo ABSENT)
  a_held=ABSENT; [ -e "$RK_PIPE/$RK_KA-196.held" ] && a_held=present
  a_title=$(cat "$RK_PIPE/$RK_KA-196.title" 2>/dev/null || echo ABSENT)
  q77=ABSENT; [ -e "$RK_PIPE/queue/$RK_KB-77.json" ] && q77=present
  repo_in_q=$(jq -r .repo "$RK_PIPE/queue/$RK_KA-196.json" 2>/dev/null || echo ABSENT)
  local alive=0; rk_alive "$pid198" && alive=1
  # supervisor tick afterwards: the queued entry for #77 is launched under its own key, the live run is left alone
  rk_env_run "$ROOT_RK4/skills/orchestrate/supervisor.sh" >/dev/null
  local launched77=ABSENT pid_after_tick
  [ -f "$RK_PIPE/$RK_KB-77.launched-at" ] && launched77=yes
  pid_after_tick=$(cat "$RK_PIPE/$RK_KB-198.pid" 2>/dev/null || echo ABSENT)
  rk_cleanup
  assert_eq "$RK4_RC" "0" "#213 AC8: install exits 0" || return 1
  assert_eq "$left_pipe" "" "#213 AC8: no ^orch-[0-9]+\\. file remains in PIPE" || return 1
  assert_eq "$left_queue" "" "#213 AC8: no ^orch-[0-9]+\\. file remains in QUEUE" || return 1
  assert_eq "$pid_after" "$pid198" "#213 AC8: the live run's pid file was renamed, content unchanged" || return 1
  assert_eq "$alive" "1" "#213 AC8: the live process survives (only names change)" || return 1
  assert_eq "$a_held" "present" "#213 AC8: .held moved to repo-1's key" || return 1
  assert_eq "$a_title" "Title A" "#213 AC8: .title moved to repo-1's key" || return 1
  assert_eq "$q77" "present" "#213 AC8: queue entry moved to its repo-keyed name (resolved from the JSON repo)" || return 1
  assert_eq "$repo_in_q" "$RK_REPO_A" "#213 AC8: queue JSON content unchanged" || return 1
  assert_eq "$launched77" "yes" "#213 AC8: a supervisor tick sees and launches the migrated queue entry" || return 1
  assert_eq "$pid_after_tick" "$pid198" "#213 AC8: the tick leaves the live run alone (no duplicate launch)" || return 1
}

# AC7 + idempotence
test_rk4_unresolvable_files_stay_listed_exit_0_and_second_run_is_a_noop() {
  rk_env
  # resolvable (so this test is red on number-keyed code): repo-1 #310
  echo "$(rk_dead_pid)" > "$RK_PIPE/orch-310.pid"; echo "$RK_REPO_A" > "$RK_PIPE/orch-310.repo"; touch "$RK_PIPE/orch-310.done"
  # unresolvable: no .repo at all; .repo pointing at a non-checkout; queue JSON whose repo is not a checkout
  echo "$(rk_dead_pid)" > "$RK_PIPE/orch-300.pid"; touch "$RK_PIPE/orch-300.held"
  mkdir -p "$RK_PIPE/not-a-checkout"
  echo "$(rk_dead_pid)" > "$RK_PIPE/orch-301.pid"; echo "$RK_PIPE/not-a-checkout" > "$RK_PIPE/orch-301.repo"
  rk4_json_queue orch-302 302 "$RK_PIPE/not-a-checkout"
  local before_unres="" f
  for f in orch-300.pid orch-300.held orch-301.pid orch-301.repo queue/orch-302.json; do before_unres="$before_unres $(rk_sum "$RK_PIPE/$f")"; done
  rk4_install; local out1=$RK4_OUT rc1=$RK4_RC
  local after_unres=""
  for f in orch-300.pid orch-300.held orch-301.pid orch-301.repo queue/orch-302.json; do after_unres="$after_unres $(rk_sum "$RK_PIPE/$f")"; done
  local migrated=ABSENT; [ -e "$RK_PIPE/$RK_KA-310.done" ] && migrated=present
  local snap1 snap2; snap1=$(rk4_snapshot)
  rk4_install; local rc2=$RK4_RC
  snap2=$(rk4_snapshot)
  rk_cleanup
  assert_eq "$rc1" "0" "#213 AC7: install exits 0 with unresolvable files" || return 1
  assert_eq "$migrated" "present" "#213 AC7: the resolvable file was migrated to its repo-keyed name" || return 1
  assert_eq "$after_unres" "$before_unres" "#213 AC7: unresolvable files are left in place, byte-identical (never deleted)" || return 1
  assert_contains "$out1" "orch-300" "#213 AC7: install output lists the file with no .repo" || return 1
  assert_contains "$out1" "orch-301" "#213 AC7: install output lists the file whose .repo does not resolve" || return 1
  assert_contains "$out1" "orch-302" "#213 AC7: install output lists the queue entry whose repo does not resolve" || return 1
  assert_eq "$rc2" "0" "#213 AC7: second run exits 0" || return 1
  assert_eq "$snap2" "$snap1" "#213 AC7: running the step twice changes nothing the second time" || return 1
}

# AC12 — migration failure
test_rk4_migration_failure_is_logged_as_error_row_and_posted_to_slack() {
  rk_env
  rk4_slack_cfg
  echo "$(rk_dead_pid)" > "$RK_PIPE/orch-300.pid"   # no .repo: cannot be migrated
  rk4_install
  local ev="$RK_HOME/logs/pipeline/events.jsonl" row sha host curl_log
  sha=$(git -C "$ROOT_RK4" rev-parse HEAD)
  row=$(grep '"event":"error"' "$ev" 2>/dev/null | grep 'run-key-migration' | tail -1)
  curl_log=$(cat "$RK_BIN/curl.log" 2>/dev/null)
  rk_cleanup
  [ -n "$row" ] || { fail "#213 AC12: no error row with route run-key-migration in events.jsonl"; return 1; }
  assert_eq "$(printf '%s' "$row" | jq -r .event)" "error" "#213 AC12: event=error" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .route)" "run-key-migration" "#213 AC12: route" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .release)" "$sha" "#213 AC12: release = claude-agents checkout commit SHA" || return 1
  assert_ne "$(printf '%s' "$row" | jq -r '.host // ""')" "" "#213 AC12: host is set" || return 1
  assert_not_contains "$row" "$RK4_TOKEN" "#213 AC12: row carries no Slack token" || return 1
  assert_not_contains "$row" "hooks.slack.com" "#213 AC12: row carries no webhook URL" || return 1
  assert_contains "$curl_log" "chat.postMessage" "#213 AC12: posted through the existing Slack path" || return 1
  assert_contains "$curl_log" "C213FAKE" "#213 AC12: to the configured engineering channel" || return 1
}

# AC12 — launch failure
test_rk4_launch_failure_is_logged_as_error_row_and_posted_to_slack() {
  rk_env
  rk4_slack_cfg
  : > "$RK_BIN/repo-view-fail"        # gh repo view fails -> owner/repo cannot be resolved -> no run key
  local out
  out=$(HOME="$RK_HOME" PATH="$RK_BIN:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="$RK4_TOKEN" SLACK_ENGINEERING_CHANNEL="C213FAKE" \
    "$ROOT_RK4/skills/orchestrate/orchestrate.sh" "$RK_REPO_A" 196 2>&1)
  local ev="$RK_HOME/logs/pipeline/events.jsonl" row sha curl_log pids
  sha=$(git -C "$ROOT_RK4" rev-parse HEAD)
  row=$(grep '"event":"error"' "$ev" 2>/dev/null | grep '"route":"launch"' | tail -1)
  curl_log=$(cat "$RK_BIN/curl.log" 2>/dev/null)
  pids=$(ls "$RK_PIPE" | grep -E '\.pid$' | tr '\n' ' ')
  rk_cleanup
  [ -n "$row" ] || { fail "#213 AC12: no error row with route launch in events.jsonl (launch output: $out)"; return 1; }
  assert_eq "$(printf '%s' "$row" | jq -r .route)" "launch" "#213 AC12: route" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .release)" "$sha" "#213 AC12: release = claude-agents checkout commit SHA" || return 1
  assert_ne "$(printf '%s' "$row" | jq -r '.host // ""')" "" "#213 AC12: host is set" || return 1
  assert_not_contains "$row" "$RK4_TOKEN" "#213 AC12: row carries no Slack token" || return 1
  assert_contains "$curl_log" "chat.postMessage" "#213 AC12: posted through the existing Slack path" || return 1
  assert_eq "$pids" "" "#213 AC12: a failed launch leaves no pid file (no number-only fallback key)" || return 1
}

run_test test_rk4_cutover_renames_everything_and_supervisor_tick_sees_it
run_test test_rk4_unresolvable_files_stay_listed_exit_0_and_second_run_is_a_noop
run_test test_rk4_migration_failure_is_logged_as_error_row_and_posted_to_slack
run_test test_rk4_launch_failure_is_logged_as_error_row_and_posted_to_slack
