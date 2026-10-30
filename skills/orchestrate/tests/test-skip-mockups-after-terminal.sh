# Issue #551 — a [jp] SKIP MOCKUPS posted AFTER a terminal marker (DEPLOYED / DEPLOYED TO STAGING / APPLIED / SPLIT) is inert:
# supervisor.sh latest_marker keeps the terminal marker as the gate marker, so terminal_kind says "done" and no restart is counted.
#
#   AC1  st_ac1_*   latest_marker returns the terminal marker (each of the four) when a valid SKIP MOCKUPS follows it
#   AC2  st_ac2_*   SKIP MOCKUPS before / without a terminal marker behaves as today
#   AC3  st_ac3_*   [jp] GO (and other jp markers) after DEPLOYED TO STAGING still route
#   AC4  st_ac4_*   DEPLOYED then SKIP MOCKUPS: latest_marker = DEPLOYED, terminal_kind = done; a tick logs [done], no [queue-restart]
#   AC5  st_ac5_*   orchestrate.sh LAUNCH banner carries the caller's parent PID and command
#   AC6  st_ac6_*   the drain's "already running" branch logs a line naming the issue
#   AC7  st_ac7_*   (IF IT WORKS) manual-relaunch trail: [done] line, never [queue-restart] on SKIP MOCKUPS
#   AC8  st_ac8_*   no new mechanism (no new function, no new state file/counter in the two scripts)
#   AC9  st_ac9_*   failing latest_marker read still alerts through autoretry_alert with release/environment/route tags
#
# Expected values hand-written from the ticket. Prefixes st_ / ST_. Placeholder repo names only.

HERE_ST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_ST=$(cd "$HERE_ST/../../.." && pwd)
SUP_ST="$HERE_ST/../supervisor.sh"
ORCH_ST="$HERE_ST/../orchestrate.sh"
LIB_ST="$HERE_ST/../pipeline-lib.sh"
MARKERS_ST="$ROOT_ST/hooks/pipeline-markers.sh"

ST_DEPLOYED='**[deployer] DEPLOYED**'
ST_STAGING='**[deployer] DEPLOYED TO STAGING**'
ST_APPLIED='**[infra-operator] APPLIED**'
ST_SPLIT='**[solutions-architect] SPLIT**'
ST_SKIP=$'**[jp] SKIP MOCKUPS**\nJP said: "skip it"'
ST_SKIP_L1='**[jp] SKIP MOCKUPS**'
ST_OPEN='**[product-manager] ISSUE OPENED**'

st_fn() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

st_env() {
  ST_PIPE=$(new_pipe); ST_HOME=$(new_home)
  ST_REPO="$ST_PIPE/repo-a"; ST_GH="$ST_HOME/.local/bin"
  fixture_repo "$ST_REPO" "project-a/repo-a"
  mk_fake_gh "$ST_GH"
  echo "project-a/repo-a" > "$ST_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexec sleep 30\n' > "$ST_GH/claude"; chmod +x "$ST_GH/claude"
  echo 'MEM_FLOOR_MB=0' > "$ST_HOME/.claude/pipeline/config.local.sh" 2>/dev/null || { mkdir -p "$ST_HOME/.claude/pipeline"; echo 'MEM_FLOOR_MB=0' > "$ST_HOME/.claude/pipeline/config.local.sh"; }
}
st_cleanup() {
  local f pid
  for f in "$ST_PIPE"/orch-*.pid; do [ -e "$f" ] || continue; pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }; done
  cleanup_running; rm -rf "$ST_PIPE" "$ST_HOME"
}

# st_thread <body>... — comments oldest -> newest, one minute apart; all authored by issue author "author-a" (the SKIP author check, #272)
st_thread() {
  local arr='[]' b i=0
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "$(printf '2026-10-01T12:%02d:00Z' "$i")" '. + [{body: $b, createdAt: $t, author: {login: "author-a"}}]')
  done
  printf '%s' "$arr" > "$ST_GH/gh-issue-comments-json"
}

st_latest() {  # latest_marker extracted from supervisor.sh (sourcing it would run a tick)
  ( . "$MARKERS_ST"; . "$LIB_ST"
    eval "$(st_fn "$SUP_ST" latest_marker)"
    PATH="$ST_GH:$PATH"; latest_marker "$ST_REPO" 42 )
}

st_terminal() {  # terminal_kind of a marker, extracted the same way
  ( . "$MARKERS_ST"; . "$LIB_ST"
    eval "$(st_fn "$SUP_ST" terminal_kind)"
    PATH="$ST_GH:$PATH"; PIPE="$ST_PIPE"; rk=x; terminal_kind "$1" 42 "" "$ST_REPO" )
}

st_tick() {
  HOME="$ST_HOME" PATH="$ST_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$ST_PIPE" QUEUE="$ST_PIPE/queue" LOGDIR="$ST_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_ST" >/dev/null 2>&1
}
st_log() { cat "$ST_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }

# ------------------------------------------------------------------------------------------ AC1

test_st_ac1_skip_after_each_terminal_marker_keeps_the_terminal_marker() {
  local m rc=0
  for m in "$ST_DEPLOYED" "$ST_STAGING" "$ST_APPLIED" "$ST_SPLIT"; do
    st_env; st_thread "$ST_OPEN" "$m" "$ST_SKIP"
    assert_eq "$(st_latest)" "$m" "AC1: latest_marker after [$m] + SKIP MOCKUPS" || rc=1
    st_cleanup
    [ "$rc" = 0 ] || return 1
  done
}

test_st_ac1_skip_with_intervening_note_still_inert() {
  st_env; st_thread "$ST_OPEN" "$ST_DEPLOYED" $'**[deployer] NOTE**\nmerged' "$ST_SKIP"
  local got; got=$(st_latest); st_cleanup
  assert_eq "$got" "$ST_DEPLOYED" "AC1: NOTE between terminal and SKIP changes nothing" || return 1
}

# ------------------------------------------------------------------------------------------ AC2 (characterisation)

test_st_ac2_skip_after_mockups_pending_is_still_the_gate_marker() {
  st_env; st_thread "$ST_OPEN" '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' "$ST_SKIP"
  local got; got=$(st_latest); st_cleanup
  assert_eq "$got" "$ST_SKIP_L1" "AC2: SKIP MOCKUPS with no terminal marker before it is the gate marker" || return 1
}

test_st_ac2_skip_before_terminal_marker_terminal_wins_as_today() {
  st_env; st_thread "$ST_OPEN" "$ST_SKIP" "$ST_DEPLOYED"
  local got; got=$(st_latest); st_cleanup
  assert_eq "$got" "$ST_DEPLOYED" "AC2: DEPLOYED newer than SKIP MOCKUPS" || return 1
}

test_st_ac2_skip_alone_after_a_non_terminal_marker_is_the_gate_marker() {
  st_env; st_thread "$ST_OPEN" '**[test-reviewer] TESTS APPROVED**' "$ST_SKIP"
  local got; got=$(st_latest); st_cleanup
  assert_eq "$got" "$ST_SKIP_L1" "AC2: non-terminal earlier marker does not neutralise SKIP MOCKUPS" || return 1
}

# ------------------------------------------------------------------------------------------ AC3

test_st_ac3_jp_go_after_deployed_to_staging_still_routes() {
  st_env; st_thread "$ST_OPEN" "$ST_STAGING" '**[jp] GO**'
  local got; got=$(st_latest); st_cleanup
  assert_eq "$got" '**[jp] GO**' "AC3: [jp] GO after DEPLOYED TO STAGING stays the gate marker" || return 1
}

# ------------------------------------------------------------------------------------------ AC4

test_st_ac4_deployed_then_skip_is_done() {
  st_env; st_thread "$ST_OPEN" "$ST_DEPLOYED" "$ST_SKIP"
  local got kind; got=$(st_latest); kind=$(st_terminal "$got"); st_cleanup
  assert_eq "$got" "$ST_DEPLOYED" "AC4: latest_marker yields DEPLOYED" || return 1
  assert_eq "$kind" "done" "AC4: terminal_kind yields done" || return 1
}

test_st_ac4_tick_marks_done_and_does_not_restart() {
  st_env
  mk_restarting "$ST_PIPE" 42 "$ST_REPO"
  st_thread "$ST_OPEN" "$ST_DEPLOYED" "$ST_SKIP"
  st_tick
  local log done_f; log=$(st_log)
  done_f=$([ -e "$(rkp "$ST_PIPE/orch-42.done")" ] && echo present || echo absent)
  st_cleanup
  assert_contains "$log" "[done] #42 — terminal marker: $ST_DEPLOYED" "AC4: done line" || return 1
  assert_eq "$done_f" "present" "AC4: .done written" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "AC4: no queue-restart" || return 1
}

# ------------------------------------------------------------------------------------------ AC5

test_st_ac5_launch_banner_logs_parent_pid_and_command() {
  st_env
  local out rc log
  out=$(HOME="$ST_HOME" PATH="$ST_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$ST_PIPE" QUEUE="$ST_PIPE/queue" \
    bash -c 'exec "$0" "$@"' "$ORCH_ST" "$ST_REPO" 42 2>&1); rc=$?
  log=$(cat "$(rkp "$ST_PIPE/orch-42.log")" 2>/dev/null)
  st_cleanup
  assert_exit0 "$rc" "AC5: launch ($out)" || return 1
  # the caller here is `bash -c 'exec <orchestrate.sh> ...'` re-exec'd, so the command shown is the orchestrate.sh invocation itself;
  # the banner must carry a ppid=<digits> field and a cmd= field on the LAUNCH line, with the existing issue/reason fields kept.
  printf '%s' "$log" | grep -E '^===== \[[^]]+\] LAUNCH issue=42 reason=manual .*ppid=[0-9]+' >/dev/null \
    || { fail "AC5: LAUNCH banner has no ppid=<pid>: $(printf '%s' "$log" | grep LAUNCH)"; return 1; }
  printf '%s' "$log" | grep -E 'LAUNCH issue=42 .*cmd=.*orchestrate\.sh' >/dev/null \
    || { fail "AC5: LAUNCH banner has no cmd=<caller command>: $(printf '%s' "$log" | grep LAUNCH)"; return 1; }
}

# ------------------------------------------------------------------------------------------ AC6

test_st_ac6_drain_logs_when_it_removes_an_entry_for_a_running_issue() {
  st_env
  mk_running "$ST_PIPE" 42 "$ST_REPO"
  mk_queued "$ST_PIPE" 42 "$ST_REPO"
  st_thread "$ST_OPEN" '**[test-writer] TESTS WRITTEN**'
  st_tick
  local log queued; log=$(st_log)
  queued=$([ -e "$(rkp "$ST_PIPE/queue/orch-42.json")" ] && echo present || echo absent)
  st_cleanup
  assert_eq "$queued" "absent" "AC6: queue entry removed" || return 1
  printf '%s' "$log" | grep -E '#42.*already running' >/dev/null \
    || { fail "AC6: no log line naming #42 and 'already running' in: $log"; return 1; }
}

# ------------------------------------------------------------------------------------------ AC7

test_st_ac7_manual_relaunch_trail_logs_done_not_queue_restart_on_skip() {
  st_env
  mk_restarting "$ST_PIPE" 42 "$ST_REPO"
  st_thread "$ST_OPEN" "$ST_DEPLOYED" "$ST_SKIP"
  st_tick; st_tick
  local log; log=$(st_log); st_cleanup
  assert_not_contains "$log" "marker='$ST_SKIP_L1'" "AC7: no queue-restart on the SKIP MOCKUPS marker" || return 1
  assert_contains "$log" "[done] #42 — terminal marker: $ST_DEPLOYED" "AC7: done line instead" || return 1
}

# ------------------------------------------------------------------------------------------ AC8

test_st_ac8_no_new_mechanism() {
  local base added
  base=$(cd "$ROOT_ST" && git merge-base HEAD origin/main 2>/dev/null); [ -n "$base" ] || { fail "AC8: no merge-base"; return 1; }
  added=$(cd "$ROOT_ST" && git diff -U0 "$base" -- skills/orchestrate/supervisor.sh skills/orchestrate/orchestrate.sh | grep -E '^\+' | grep -vE '^\+\+\+ ')
  assert_not_contains "$(printf '%s' "$added" | grep -E '^\+[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{' || true)" "()" "AC8: no new function definitions" || return 1
  assert_eq "$(printf '%s' "$added" | grep -cE 'touch .*orch-.*\.[a-z-]+"|> *"\$PIPE/orch-\$[a-z]+\.[a-z-]+"' || true)" "0" "AC8: no new per-run state file" || return 1
  assert_eq "$(printf '%s' "$added" | grep -ciE 'counter|no_progress_count|\.np\b' || true)" "0" "AC8: no new counter" || return 1
}

# ------------------------------------------------------------------------------------------ AC9

test_st_ac9_failing_marker_read_alerts_with_tags_and_no_secrets() {
  st_env
  local fakebin="$ST_PIPE/bin"; mkdir -p "$fakebin"
  # gh returns a non-JSON comments page -> the jq normalisation fails -> "?" and an alert
  printf '#!/bin/bash\ncase "$*" in *"/comments"*) echo "not json {" ;; *) echo "{}" ;; esac\n' > "$fakebin/gh"; chmod +x "$fakebin/gh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/curl.log"\n' "$ST_PIPE" > "$fakebin/curl"; chmod +x "$fakebin/curl"
  local out alert
  out=$( PATH="$fakebin:$PATH" SLACK_WEBHOOK_URL=https://hooks.example.test/x SLOG="$ST_PIPE/slog"
    . "$MARKERS_ST"; . "$LIB_ST"
    slog() { printf '%s\n' "$*" >> "$SLOG"; }
    eval "$(st_fn "$SUP_ST" latest_marker)"; eval "$(st_fn "$SUP_ST" gh_err_line)"; eval "$(st_fn "$SUP_ST" autoretry_alert)"
    latest_marker "$ST_REPO" 42 )
  alert=$(cat "$ST_PIPE/curl.log" 2>/dev/null); st_cleanup
  assert_eq "$out" "?" "AC9: failed read answers ?" || return 1
  assert_contains "$alert" "hooks.example.test" "AC9: Slack webhook called" || return 1
  assert_contains "$alert" "release=" "AC9: release tag" || return 1
  assert_contains "$alert" "environment=" "AC9: environment tag" || return 1
  assert_contains "$alert" "route=supervisor/latest_marker" "AC9: route tag" || return 1
  assert_not_contains "$alert" "JP said" "AC9: no comment text in the alert" || return 1
}

run_test test_st_ac1_skip_after_each_terminal_marker_keeps_the_terminal_marker
run_test test_st_ac1_skip_with_intervening_note_still_inert
run_test test_st_ac2_skip_after_mockups_pending_is_still_the_gate_marker
run_test test_st_ac2_skip_before_terminal_marker_terminal_wins_as_today
run_test test_st_ac2_skip_alone_after_a_non_terminal_marker_is_the_gate_marker
run_test test_st_ac3_jp_go_after_deployed_to_staging_still_routes
run_test test_st_ac4_deployed_then_skip_is_done
run_test test_st_ac4_tick_marks_done_and_does_not_restart
run_test test_st_ac5_launch_banner_logs_parent_pid_and_command
run_test test_st_ac6_drain_logs_when_it_removes_an_entry_for_a_running_issue
run_test test_st_ac7_manual_relaunch_trail_logs_done_not_queue_restart_on_skip
run_test test_st_ac8_no_new_mechanism
run_test test_st_ac9_failing_marker_read_alerts_with_tags_and_no_secrets
