# Issue #837 — a host that cannot run agents (Claude logged out, weekly / monthly spend limit) raises one alert: state in
# $PIPE/agents-down.state, one Slack post per outage, a `launcher.sh status` line, a `goal_stall[]` entry of kind agents_down.
# Incident 2026-11-25: the VM's CLI session expired and every launch failed for ~38 h with nothing saying why.
# A stub `claude` answers `auth status` from $AD/status_{out,rc} and the probe from $AD/probe_{out,rc}; a stub `curl` records every
# post (Slack and Sentry). Expected values are hand-written from the ticket. Prefix ad_.

AD_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AD_LIB="$AD_HERE/.."
. "$AD_HERE/lib/goal-sandbox.sh"
if ! declare -f sq_env >/dev/null 2>&1 || ! declare -f si_env >/dev/null 2>&1; then
  eval "ad_real_$(declare -f run_test)"
  run_test() { :; }
  declare -f sq_env >/dev/null 2>&1 || . "$AD_HERE/test-supervisor-queued-not-counted.sh"
  declare -f si_env >/dev/null 2>&1 || . "$AD_HERE/test-intake-supervisor.sh"
  eval "$(declare -f ad_real_run_test | sed '1s/ad_real_run_test/run_test/')"
fi

# verbatim from the VM logs / the CLI
AD_EXPIRED='Failed to authenticate: OAuth session expired and could not be refreshed'
AD_NOTLOGGED='Not logged in · Please run /login'
AD_WEEKLY="You've hit your weekly limit · resets 3am (UTC)"
AD_MONTHLY="You've hit your monthly spend limit. Switch to another model, or manage usage credits at https://example.invalid/usage"
AD_OTHER="You've hit your usage limit for today"
AD_IN='{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.invalid", "orgName": "Example Org"}'
AD_OUT='{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}'

ad_env() {
  AD=$(mktemp -d "${TMPDIR:-/tmp}/agents-down-test.XXXXXX")
  mkdir -p "$AD/bin" "$AD/pipe/queue" "$AD/log"
  : > "$AD/calls"; : > "$AD/posts"; : > "$AD/slog"
  printf '%s' "$AD_IN" > "$AD/status_out"; echo 0 > "$AD/status_rc"
  printf 'API Error: connection reset\n' > "$AD/probe_out"; echo 1 > "$AD/probe_rc"
  cat > "$AD/bin/claude" <<EOT
#!/bin/bash
A="$AD"
if [ "\$1 \$2" = "auth status" ]; then
  echo "status" >> "\$A/calls"
  [ -e "\$A/status_sleep" ] && sleep 5
  cat "\$A/status_out"; exit "\$(cat "\$A/status_rc")"
fi
echo "probe \$*" >> "\$A/calls"
env | grep -E '^PIPELINE_(ISSUE|AGENT|REPO)=' > "\$A/probe_env"
[ -e "\$A/probe_sleep" ] && sleep 5
cat "\$A/probe_out"; exit "\$(cat "\$A/probe_rc")"
EOT
  cat > "$AD/bin/curl" <<EOT
#!/bin/bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "$AD/posts"; echo >> "$AD/posts"
EOT
  chmod +x "$AD/bin/claude" "$AD/bin/curl"
}
ad_done() { rm -rf "$AD"; }

# ad_sh [VAR=val ...] <snippet> — the snippet in a shell holding the library, with the stubs first on PATH
ad_sh() {
  local envs=()
  while [ $# -gt 1 ]; do envs+=("$1"); shift; done
  env PATH="$AD/bin:$PATH" PIPE="$AD/pipe" LOGDIR="$AD/log" AGENTS_DOWN_CHECK_ENABLED=1 \
    SLACK_WEBHOOK_URL=https://hooks.slack.invalid/x SENTRY_DSN=https://testkey@sentry.invalid/42 ${envs[@]+"${envs[@]}"} \
    bash -c "set -u; . '$AD_LIB/pipeline-lib.sh'; . '$AD_LIB/code-sync.sh'; slog() { echo \"\$*\" >> '$AD/slog'; }
$1" 2>>"$AD/err"
}
ad_check() { ad_sh "$@" 'agents_down_check'; }
ad_state() { cat "$AD/pipe/agents-down.state" 2>/dev/null; }
ad_field() { ad_state | awk -v n="$1" '{print $n}'; }   # 1 down|ok, 2 since|cleared_at, 3 cause, 4 last probe
ad_n() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
ad_slacks() { ad_n 'hooks.slack.invalid' "$AD/posts"; }
ad_sentry() { ad_n 'sentry.invalid' "$AD/posts"; }
ad_probes() { ad_n '^probe ' "$AD/calls"; }
ad_seed_down() { printf 'down %s %s %s\n' "$1" "${2:-auth}" "${3:-$(date +%s)}" > "$AD/pipe/agents-down.state"; }  # <since> [cause] [last probe]
ad_age() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"; }  # <file> <secs ago>
# ad_log <file> <line...> — a log with one older segment, then a LAUNCH header and the given lines
ad_log() {
  local f=$1; shift
  { echo "older output"; echo "===== [2026-11-25T23:55:00Z] LAUNCH issue=1 reason=manual ====="; printf '%s\n' "$@"; } > "$f"
}
# ad_exit <exit code|none> <line...> — one run exit fed to the library
ad_exit() {
  local code=$1; shift
  ad_log "$AD/run.log" "$@"; rm -f "$AD/run.exit"
  [ "$code" = none ] || echo "$code" > "$AD/run.exit"
  ad_sh "agents_down_exit '$AD/run.log' '$AD/run.exit'"
}

# ------------------------------------------------------------------------------------------ AC: auth status

test_ad_logged_out_status_raises_in_one_check() {
  ad_env; printf '%s' "$AD_OUT" > "$AD/status_out"; echo 1 > "$AD/status_rc"
  local t0; t0=$(date +%s)
  ad_check
  local st since; st=$(ad_field 1); since=$(ad_field 2)
  assert_eq "$st" down "alert raised" || { ad_done; return 1; }
  assert_eq "$(ad_field 3)" auth "cause" || { ad_done; return 1; }
  [ "$since" -ge "$t0" ] || { ad_done; fail "since $since is not the raise time (>= $t0)"; return 1; }
  assert_eq "$(ad_slacks)" 1 "one Slack post" || { ad_done; return 1; }
  assert_contains "$(grep slack "$AD/posts")" "claude auth login" "Slack names the action" || { ad_done; return 1; }
  ad_done
}

test_ad_logged_in_raises_nothing_and_never_probes() {
  ad_env; ad_check; ad_check; ad_check
  assert_file_absent "$AD/pipe/agents-down.state" "no state" || { ad_done; return 1; }
  assert_eq "$(ad_probes)" 0 "healthy host: zero probe runs" || { ad_done; return 1; }
  assert_eq "$(ad_slacks)" 0 "no Slack" || { ad_done; return 1; }
  ad_done
}

test_ad_unreadable_or_unsupported_status_raises_nothing() {
  local c rc out
  for c in '1|garbage' '1|' "2|error: unknown command 'auth'" "0|$AD_OUT" "2|$AD_OUT" '1|{"authMethod":"none"}' '1|{"loggedIn": true}'; do
    ad_env; rc=${c%%|*}; out=${c#*|}; echo "$rc" > "$AD/status_rc"; printf '%s' "$out" > "$AD/status_out"
    ad_check
    assert_file_absent "$AD/pipe/agents-down.state" "rc=$rc out=$out raises nothing" || { ad_done; return 1; }
    assert_eq "$(ad_probes)" 0 "and probes nothing" || { ad_done; return 1; }
    ad_done
  done
}

test_ad_hung_status_is_bounded_and_raises_nothing() {
  ad_env; touch "$AD/status_sleep"; printf '%s' "$AD_OUT" > "$AD/status_out"; echo 1 > "$AD/status_rc"
  local t0 dt; t0=$(date +%s)
  ad_check AGENTS_DOWN_STATUS_TIMEOUT_SECS=1
  dt=$(( $(date +%s) - t0 ))
  assert_file_absent "$AD/pipe/agents-down.state" "timed out: nothing raised" || { ad_done; return 1; }
  assert_lt "$dt" 4 "bounded" || { ad_done; return 1; }
  ad_done
}

test_ad_logged_in_or_unreadable_status_clears_nothing() {
  ad_env; ad_seed_down 1000
  ad_check; echo 2 > "$AD/status_rc"; printf 'nope' > "$AD/status_out"; ad_check
  assert_eq "$(ad_field 1) $(ad_field 2)" "down 1000" "a status read never clears a standing alert" || { ad_done; return 1; }
  ad_done
}

test_ad_kill_switch_calls_nothing() {
  ad_env; printf '%s' "$AD_OUT" > "$AD/status_out"; echo 1 > "$AD/status_rc"
  ad_check AGENTS_DOWN_CHECK_ENABLED=0
  ad_log "$AD/run.log" "$AD_EXPIRED"; echo 1 > "$AD/run.exit"
  ad_sh AGENTS_DOWN_CHECK_ENABLED=0 "agents_down_exit '$AD/run.log' '$AD/run.exit'"
  assert_file_absent "$AD/pipe/agents-down.state" "off: nothing raised" || { ad_done; return 1; }
  assert_eq "$(grep -c . "$AD/calls")" 0 "off: claude never called" || { ad_done; return 1; }
  ad_done
}

# ------------------------------------------------------------------------------------------ AC: run logs

test_ad_auth_lines_raise_on_a_failed_exit() {
  local line code
  for line in "$AD_EXPIRED" "$AD_NOTLOGGED"; do
    for code in 1 none; do
      ad_env; ad_exit "$code" "$line"
      assert_eq "$(ad_field 1) $(ad_field 3)" "down auth" "exit=$code line=$line" || { ad_done; return 1; }
      ad_done
    done
  done
}

test_ad_auth_line_followed_by_more_output_still_raises() {
  ad_env; ad_exit 1 "$AD_EXPIRED" "cleanup done"
  assert_eq "$(ad_field 1)" down "any line of the last segment" || { ad_done; return 1; }
  ad_done
}

test_ad_negatives_raise_nothing() {
  ad_env
  ad_exit 1 "stage said: $AD_EXPIRED" "  $AD_NOTLOGGED"
  assert_file_absent "$AD/pipe/agents-down.state" "quoted mid-line / indented" || { ad_done; return 1; }
  printf '%s\n===== [2026-11-26T00:00:00Z] LAUNCH issue=1 reason=manual =====\nError: boom\n' "$AD_EXPIRED" > "$AD/run.log"; echo 1 > "$AD/run.exit"
  ad_sh "agents_down_exit '$AD/run.log' '$AD/run.exit'"
  assert_file_absent "$AD/pipe/agents-down.state" "earlier launch segment" || { ad_done; return 1; }
  ad_exit 0 "$AD_EXPIRED"
  assert_file_absent "$AD/pipe/agents-down.state" "successful run" || { ad_done; return 1; }
  ad_exit 1 "$AD_OTHER"
  assert_file_absent "$AD/pipe/agents-down.state" "an 'other' (short) limit" || { ad_done; return 1; }
  ad_exit 0 "$AD_WEEKLY"
  assert_file_absent "$AD/pipe/agents-down.state" "limit text in a successful run" || { ad_done; return 1; }
  assert_eq "$(ad_slacks)" 0 "no Slack" || { ad_done; return 1; }
  ad_done
}

test_ad_weekly_and_monthly_limits_raise_with_the_limit_action() {
  local c line cause
  for c in "weekly|$AD_WEEKLY" "monthly_spend|$AD_MONTHLY"; do
    cause=${c%%|*}; line=${c#*|}
    ad_env; ad_exit 1 "$line"
    assert_eq "$(ad_field 1) $(ad_field 3)" "down $cause" "$cause raises" || { ad_done; return 1; }
    assert_contains "$(ad_sh 'agents_down_line')" "Wait for the reset or raise the limit" "$cause action" || { ad_done; return 1; }
    ad_done
  done
}

# ------------------------------------------------------------------------------------------ AC: probe and clear

test_ad_probe_at_most_once_per_15_minutes_and_keeps_since() {
  ad_env; ad_seed_down 1000 auth 0
  ad_check; ad_check; ad_check
  assert_eq "$(ad_probes)" 1 "three checks inside the window: one probe" || { ad_done; return 1; }
  assert_eq "$(ad_field 1) $(ad_field 2)" "down 1000" "failed probe keeps since" || { ad_done; return 1; }
  ad_seed_down 1000 auth $(( $(date +%s) - 840 )); ad_check
  assert_eq "$(ad_probes)" 1 "14 minutes after the last probe: still none" || { ad_done; return 1; }
  ad_seed_down 1000 auth $(( $(date +%s) - 901 )); ad_check
  assert_eq "$(ad_probes)" 2 "after 15 minutes: one more" || { ad_done; return 1; }
  assert_eq "$(ad_field 2)" 1000 "since still unchanged" || { ad_done; return 1; }
  ad_done
}

test_ad_probe_is_minimal_and_carries_no_pipeline_env() {
  ad_env; ad_seed_down 1000 auth 0
  ad_check PIPELINE_ISSUE=7 PIPELINE_AGENT=intake PIPELINE_REPO=project-a/repo-a
  local c; c=$(grep '^probe ' "$AD/calls")
  assert_contains "$c" " -p " "a -p run" || { ad_done; return 1; }
  assert_contains "$c" "--model haiku" "cheapest model" || { ad_done; return 1; }
  assert_eq "$(cat "$AD/probe_env")" "" "no PIPELINE_ISSUE / AGENT / REPO (handoff hooks stay quiet)" || { ad_done; return 1; }
  ad_done
}

test_ad_probe_output_updates_the_cause() {
  ad_env; ad_seed_down 1000 auth 0; printf '%s\n' "$AD_WEEKLY" > "$AD/probe_out"
  ad_check
  assert_eq "$(ad_field 1) $(ad_field 2) $(ad_field 3)" "down 1000 weekly" "the newest evidence names the cause" || { ad_done; return 1; }
  assert_eq "$(ad_slacks)" 0 "same outage: no new post" || { ad_done; return 1; }
  ad_done
}

test_ad_successful_probe_clears_and_old_log_does_not_re_raise() {
  ad_env; ad_exit 1 "$AD_EXPIRED"; ad_age "$AD/run.log" 60
  echo 0 > "$AD/probe_rc"; echo OK > "$AD/probe_out"
  ad_check
  assert_eq "$(ad_field 1)" ok "successful probe clears" || { ad_done; return 1; }
  ad_sh "agents_down_exit '$AD/run.log' '$AD/run.exit'"
  assert_eq "$(ad_field 1)" ok "the old failed log does not raise again" || { ad_done; return 1; }
  assert_eq "$(ad_slacks)" 1 "still the one post" || { ad_done; return 1; }
  ad_check; assert_eq "$(ad_probes)" 1 "cleared: no more probes" || { ad_done; return 1; }
  # a log written after the clear is a new outage
  printf 'ok %s\n' $(( $(date +%s) - 120 )) > "$AD/pipe/agents-down.state"
  ad_exit 1 "$AD_EXPIRED"
  assert_eq "$(ad_field 1)" down "a newer failure raises again" || { ad_done; return 1; }
  assert_eq "$(ad_slacks)" 2 "second outage, second post" || { ad_done; return 1; }
  ad_done
}

test_ad_successful_run_clears_only_when_newer_than_the_alert() {
  ad_env; ad_seed_down $(( $(date +%s) - 600 ))
  ad_log "$AD/ok.log" "All done."; echo 0 > "$AD/ok.exit"; ad_age "$AD/ok.exit" 3600
  ad_sh "agents_down_exit '$AD/ok.log' '$AD/ok.exit'"
  assert_eq "$(ad_field 1)" down "a success older than the alert proves nothing" || { ad_done; return 1; }
  ad_age "$AD/ok.exit" 10
  ad_sh "agents_down_exit '$AD/ok.log' '$AD/ok.exit'"
  assert_eq "$(ad_field 1)" ok "a newer success clears" || { ad_done; return 1; }
  ad_done
}

test_ad_one_slack_post_per_outage() {
  ad_env; ad_exit 1 "$AD_EXPIRED"; ad_exit 1 "$AD_WEEKLY"; printf '%s' "$AD_OUT" > "$AD/status_out"; echo 1 > "$AD/status_rc"; ad_check; ad_check
  assert_eq "$(ad_slacks)" 1 "one outage, one post" || { ad_done; return 1; }
  ad_done
}

# ------------------------------------------------------------------------------------------ AC: observability

test_ad_failed_probe_is_captured_with_tags_and_no_private_data() {
  ad_env; ad_seed_down 1000 auth 0
  printf 'Failed to authenticate: token sk-ant-SECRET for someone@example.invalid\n' > "$AD/probe_out"
  printf '%s' "$AD_IN" > "$AD/status_out"
  ad_check
  local p sha; p=$(grep 'sentry.invalid' "$AD/posts"); sha=$(git -C "$AD_LIB" rev-parse HEAD)
  assert_eq "$(ad_sentry)" 1 "captured" || { ad_done; return 1; }
  assert_contains "$p" "https://sentry.invalid/api/42/store/" "the DSN's store endpoint" || { ad_done; return 1; }
  assert_contains "$p" "\"release\":\"$sha\"" "release is the commit SHA" || { ad_done; return 1; }
  assert_contains "$p" "\"environment\":\"" "environment tag" || { ad_done; return 1; }
  assert_contains "$p" "\"route\":\"supervisor/agents-down\"" "route tag" || { ad_done; return 1; }
  local all; all=$(cat "$AD/posts" "$AD/slog" "$AD/pipe/agents-down.state"; ad_sh 'agents_down_line')
  assert_not_contains "$all" "SECRET" "no raw output anywhere" || { ad_done; return 1; }
  assert_not_contains "$all" "someone@" "no email anywhere" || { ad_done; return 1; }
  assert_not_contains "$all" "Example Org" "no org name anywhere" || { ad_done; return 1; }
  ad_done
}

test_ad_timed_out_probe_is_captured() {
  ad_env; ad_seed_down 1000 auth 0; touch "$AD/probe_sleep"; echo 0 > "$AD/probe_rc"
  ad_check AGENTS_DOWN_PROBE_TIMEOUT_SECS=1
  assert_eq "$(ad_field 1)" down "a timed-out probe is not a success" || { ad_done; return 1; }
  assert_contains "$(cat "$AD/posts")" "probe timed out" "captured" || { ad_done; return 1; }
  ad_done
}

test_ad_state_write_failure_is_captured() {
  ad_env; mkdir "$AD/pipe/agents-down.state"   # the state path cannot be written
  ad_exit 1 "$AD_EXPIRED"
  assert_contains "$(cat "$AD/posts")" "state write failed" "captured" || { ad_done; return 1; }
  assert_eq "$(ad_slacks)" 0 "no Slack for an alert that was not recorded (it would repeat every tick)" || { ad_done; return 1; }
  ad_done
}

test_ad_unset_sentry_dsn_logs_a_line() {
  ad_env; ad_seed_down 1000 auth 0
  ad_check SENTRY_DSN=
  assert_eq "$(ad_sentry)" 0 "nothing sent" || { ad_done; return 1; }
  assert_contains "$(cat "$AD/slog")" "SENTRY_DSN unset" "said so in the log" || { ad_done; return 1; }
  ad_done
}

# ------------------------------------------------------------------------------------------ AC: status line and heartbeat

test_ad_launcher_status_prints_one_line() {
  ad_env; local home; home=$(new_home)
  local out; out=$(HOME="$home" PIPE="$AD/pipe" QUEUE="$AD/pipe/queue" LOGDIR="$AD/log" "$AD_LIB/launcher.sh" status 2>/dev/null)
  assert_not_contains "$out" "AGENTS DOWN" "healthy: no line" || { ad_done; rm -rf "$home"; return 1; }
  ad_seed_down 1764114900 auth
  out=$(HOME="$home" PIPE="$AD/pipe" QUEUE="$AD/pipe/queue" LOGDIR="$AD/log" "$AD_LIB/launcher.sh" status 2>/dev/null)
  rm -rf "$home"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'AGENTS DOWN')" 1 "one line" || { ad_done; return 1; }
  assert_contains "$out" "since 2025-11-25T23:55:00Z" "since" || { ad_done; return 1; }
  assert_contains "$out" "claude auth login" "action" || { ad_done; return 1; }
  ad_done
}

ad_stall() {  # the payload's goal_stall, through report-status.sh
  local home; home=$(new_home)
  HOME="$home" PIPE="$AD/pipe" QUEUE="$AD/pipe/queue" LOGDIR="$AD/log" "$AD_LIB/report-status.sh" --print 2>/dev/null | jq -cS '.goal_stall // []'
  rm -rf "$home"
}

test_ad_heartbeat_carries_agents_down_first_and_stable_across_ticks() {
  ad_env
  assert_eq "$(ad_stall)" '[]' "healthy: nothing published" || { ad_done; return 1; }
  ad_seed_down 1764114900 auth 0
  printf '1764000000 4 project\n' > "$AD/pipe/gh-scope.alert-state"
  local a b; a=$(ad_stall)
  ad_check   # a failed probe moves the last-probe time only
  b=$(ad_stall)
  assert_eq "$(printf '%s' "$a" | jq -c 'map(.kind)')" '["agents_down","token_scope"]' "listed first" || { ad_done; return 1; }
  assert_eq "$(printf '%s' "$a" | jq -r '.[0].since')" "2025-11-25T23:55:00Z" "constant since timestamp" || { ad_done; return 1; }
  assert_eq "$(printf '%s' "$a" | jq -r '.[0].reason')" "Claude is logged out or its sign-in failed" "reason" || { ad_done; return 1; }
  assert_eq "$(printf '%s' "$a" | jq -r '.[0].hint')" "Log in on that host: claude auth login" "action" || { ad_done; return 1; }
  assert_eq "$(printf '%s' "$a" | jq -r '.[0] | keys | join(",")')" "goal,hint,kind,reason,since" "no published age" || { ad_done; return 1; }
  assert_eq "$b" "$a" "unchanged across ticks of the same outage" || { ad_done; return 1; }
  local c
  for c in weekly:'Claude weekly usage limit reached' monthly_spend:'Claude monthly spend limit reached'; do
    ad_seed_down 1764114900 "${c%%:*}"
    a=$(ad_stall)
    assert_eq "$(printf '%s' "$a" | jq -r '.[0] | .reason + " | " + .hint')" "${c#*:} | Wait for the reset or raise the limit" "${c%%:*}" || { ad_done; return 1; }
  done
  printf 'ok 1764114900\n' > "$AD/pipe/agents-down.state"; rm "$AD/pipe/gh-scope.alert-state"
  assert_eq "$(ad_stall)" '[]' "cleared: nothing published" || { ad_done; return 1; }
  ad_done
}

# ------------------------------------------------------------------------------------------ wiring: the real supervisor call sites

test_ad_wiring_tick_raises_on_a_logged_out_status() {
  si_env; echo 'AGENTS_DOWN_CHECK_ENABLED=1' >> "$SI_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\n[ "$1 $2" = "auth status" ] || exit 1\necho %s\nexit 1\n' "'$AD_OUT'" > "$SI_D/claude"
  si_tick
  local st; st=$(awk '{print $1, $3}' "$SI_PIPE/agents-down.state" 2>/dev/null)
  si_cleanup
  assert_eq "$st" "down auth" "one tick raises it" || return 1
}

# ad_claude_stub <file> — logged in; the probe fails; every agent launch exits 0 at once
ad_claude_stub() {
  printf '#!/bin/bash\n[ "$1 $2" = "auth status" ] && { echo %s; exit 0; }\ncase "$*" in *"--model haiku"*) exit 1 ;; esac\nexit 0\n' "'{\"loggedIn\":true}'" > "$1"
  chmod +x "$1"
}

ad_orch_tick() {  # <exit code> <log line> [state line] -> the state after one tick
  sq_env open
  echo 'MEM_FLOOR_MB=0' > "$SQ_HOME/.claude/pipeline/config.local.sh"; echo 'AGENTS_DOWN_CHECK_ENABLED=1' >> "$SQ_HOME/.claude/pipeline/config.local.sh"
  ad_claude_stub "$SQ_GH/claude"
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  echo "host-orch-42-1700000000" > "$(rkp "$SQ_PIPE/orch-42.run-id")"
  echo "$1" > "$(rkp "$SQ_PIPE/orch-42.exit")"
  printf '===== [2026-11-25T23:55:00Z] LAUNCH issue=42 reason=manual =====\n%s\n' "$2" > "$(rkp "$SQ_PIPE/orch-42.log")"
  [ -z "${3:-}" ] || echo "$3" > "$SQ_PIPE/agents-down.state"
  sq_seed_restarts 1 1 "$SQ_READY"; sq_marker "$SQ_READY"
  sq_tick
  awk '{print $1, $3}' "$SQ_PIPE/agents-down.state" 2>/dev/null
  sq_cleanup
}

test_ad_wiring_orchestrator_exit() {
  assert_eq "$(ad_orch_tick 1 "$AD_EXPIRED")" "down auth" "expired session" || return 1
  assert_eq "$(ad_orch_tick 1 "$AD_NOTLOGGED")" "down auth" "not logged in" || return 1
  assert_eq "$(ad_orch_tick 0 "All done." "down 1000 auth $(date +%s)" | awk '{print $1}')" "ok" "a successful run clears" || return 1
}

ad_lead_tick() {  # <exit code> <log line> -> the state after one goal tick
  gs_env
  echo 'AGENTS_DOWN_CHECK_ENABLED=1' >> "$GS_HOME/.claude/pipeline/config.local.sh"
  ad_claude_stub "$GS_BIN/claude"
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 600 "$1" 5
  printf '===== [2026-11-25T23:55:00Z] LAUNCH goal=%s =====\n%s\n' "$GS_ID_MS12" "$2" > "$GS_PIPE/goal-$GS_ID_MS12.log"
  gs_tick
  awk '{print $1, $3}' "$GS_PIPE/agents-down.state" 2>/dev/null
  gs_cleanup
}

test_ad_wiring_lead_exit() {
  assert_eq "$(ad_lead_tick 1 "$AD_EXPIRED")" "down auth" "expired session" || return 1
  assert_eq "$(ad_lead_tick 1 "$AD_NOTLOGGED")" "down auth" "not logged in" || return 1
  assert_eq "$(ad_lead_tick 1 "Error: connection reset")" "" "a plain crash raises nothing" || return 1
}

# ad_run_tick <intake|spec> <exit code> <log line> — a dead run of that kind with this log, one tick
ad_run_tick() {
  local kind=$1 k="$1-project-a_repo-a-7"
  si_env; echo 'AGENTS_DOWN_CHECK_ENABLED=1' >> "$SI_HOME/.claude/pipeline/config.local.sh"
  ad_claude_stub "$SI_D/claude"
  si_issue 7 project-a/repo-a agent-in-progress
  echo "project-a/repo-a 7" > "$SI_PIPE/$k.id"; echo "$SI_PIPE/repo-a" > "$SI_PIPE/$k.path"
  mk_dead_pid "$SI_PIPE" 7 "x"; mv "$SI_PIPE/orch-x.pid" "$SI_PIPE/$k.pid"
  echo 1 > "$SI_PIPE/$k.attempts"; echo "$2" > "$SI_PIPE/$k.exit"
  printf 'old\n===== [2026-11-25T23:55:00Z] LAUNCH %s=7 =====\n%s\n' "$kind" "$3" > "$SI_PIPE/$k.log"
  si_tick
  awk '{print $1, $3}' "$SI_PIPE/agents-down.state" 2>/dev/null
  sleep 1   # the tick's backgrounded reporter is still writing into the sandbox
  si_cleanup
}

test_ad_wiring_intake_exit() {
  assert_eq "$(ad_run_tick intake 1 "$AD_EXPIRED")" "down auth" "expired session" || return 1
  assert_eq "$(ad_run_tick intake 1 "$AD_NOTLOGGED")" "down auth" "not logged in" || return 1
}

test_ad_wiring_spec_exit() {
  assert_eq "$(ad_run_tick spec 1 "$AD_EXPIRED")" "down auth" "expired session" || return 1
  assert_eq "$(ad_run_tick spec 1 "$AD_NOTLOGGED")" "down auth" "not logged in" || return 1
}

# intake and spec logs are appended across attempts: each launch must start its own segment
test_ad_intake_and_spec_launches_start_a_log_segment() {
  si_env; si_issue 7 project-a/repo-a user-feedback-intake
  si_tick
  local i; i=$(grep -c '^===== .* LAUNCH .* =====$' "$SI_PIPE/intake-project-a_repo-a-7.log" 2>/dev/null)
  sleep 1
  si_cleanup
  assert_eq "$i" 1 "intake launch header" || return 1
  si_env; si_issue 8 project-a/repo-a user-feedback-needs-spec
  si_tick
  local s; s=$(grep -c '^===== .* LAUNCH .* =====$' "$SI_PIPE/spec-project-a_repo-a-8.log" 2>/dev/null)
  sleep 1
  si_cleanup
  assert_eq "$s" 1 "spec launch header" || return 1
}

run_test test_ad_logged_out_status_raises_in_one_check
run_test test_ad_logged_in_raises_nothing_and_never_probes
run_test test_ad_unreadable_or_unsupported_status_raises_nothing
run_test test_ad_hung_status_is_bounded_and_raises_nothing
run_test test_ad_logged_in_or_unreadable_status_clears_nothing
run_test test_ad_kill_switch_calls_nothing
run_test test_ad_auth_lines_raise_on_a_failed_exit
run_test test_ad_auth_line_followed_by_more_output_still_raises
run_test test_ad_negatives_raise_nothing
run_test test_ad_weekly_and_monthly_limits_raise_with_the_limit_action
run_test test_ad_probe_at_most_once_per_15_minutes_and_keeps_since
run_test test_ad_probe_is_minimal_and_carries_no_pipeline_env
run_test test_ad_probe_output_updates_the_cause
run_test test_ad_successful_probe_clears_and_old_log_does_not_re_raise
run_test test_ad_successful_run_clears_only_when_newer_than_the_alert
run_test test_ad_one_slack_post_per_outage
run_test test_ad_failed_probe_is_captured_with_tags_and_no_private_data
run_test test_ad_timed_out_probe_is_captured
run_test test_ad_state_write_failure_is_captured
run_test test_ad_unset_sentry_dsn_logs_a_line
run_test test_ad_launcher_status_prints_one_line
run_test test_ad_heartbeat_carries_agents_down_first_and_stable_across_ticks
run_test test_ad_wiring_tick_raises_on_a_logged_out_status
run_test test_ad_wiring_orchestrator_exit
run_test test_ad_wiring_lead_exit
run_test test_ad_wiring_intake_exit
run_test test_ad_wiring_spec_exit
run_test test_ad_intake_and_spec_launches_start_a_log_segment
