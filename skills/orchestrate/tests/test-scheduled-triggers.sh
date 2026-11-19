# #769 — scheduled-triggers.sh: fires schedule-only workflows from the supervisor tick. Sandbox HOME/PIPE/LOGDIR, a stub `gh` and `curl` first on
# PATH (nothing reaches GitHub or Slack). Fixture files in the sandbox HOME drive the stubs:
#   runs-<workflow>.json   what `gh run list --workflow <file>` returns (default [])
#   runs-fail              `gh run list` exits 1          dispatch-fail   `gh workflow run` exits 1 (workflow names in it: only those fail)
#   dispatch-sleep         seconds `gh workflow run` takes (the two-instance test)
# Every gh call is appended to gh.log, every curl to curl.log. Expected values are hand-written from the ticket. Placeholder repo names only.

HERE_STT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STT="$HERE_STT/../scheduled-triggers.sh"

stt_home() {
  STT_HOME=$(new_home); mkdir -p "$STT_HOME/bin"
  : > "$STT_HOME/gh.log"; : > "$STT_HOME/curl.log"
  cat > "$STT_HOME/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$HOME/gh.log"
case "$1 $2" in
  "run list")
    [ -f "$HOME/runs-fail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    wf=""; prev=""; for a in "$@"; do [ "$prev" = "--workflow" ] && wf=$a; prev=$a; done
    if [ -f "$HOME/runs-$wf.json" ]; then cat "$HOME/runs-$wf.json"; else echo '[]'; fi
    exit 0 ;;
  "workflow run")
    [ -f "$HOME/dispatch-sleep" ] && sleep "$(cat "$HOME/dispatch-sleep")"
    if [ -f "$HOME/dispatch-fail" ] && { [ ! -s "$HOME/dispatch-fail" ] || grep -qx "$3" "$HOME/dispatch-fail"; }; then
      echo "HTTP 422: Workflow does not have 'workflow_dispatch' trigger" >&2; exit 1
    fi
    exit 0 ;;
  "api rate_limit") echo "0	0	0	0"; exit 0 ;;
esac
echo "stub gh: unexpected: $*" >&2; exit 1
STUB
  cat > "$STT_HOME/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$HOME/curl.log"; echo ok
STUB
  chmod +x "$STT_HOME/bin/gh" "$STT_HOME/bin/curl"
  printf 'SLACK_WEBHOOK_URL=https://example.invalid/hook-secret-token\n' > "$STT_HOME/.claude/pipeline/config.local.sh"
  STT_STATE="$STT_HOME/pipe/scheduled-triggers"; mkdir -p "$STT_HOME/pipe"
  STT_CONF="$STT_HOME/triggers.conf"; : > "$STT_CONF"
}
stt_conf() { printf '%s\n' "$@" >> "$STT_CONF"; }
stt_run() {  # stt_run [mode] — one pass in the sandbox; sets STT_RC, STT_OUT
  STT_OUT=$(HOME="$STT_HOME" PATH="$STT_HOME/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$STT_HOME/pipe" LOGDIR="$STT_HOME/logs/pipeline" \
    SCHEDULED_TRIGGERS_ENABLED="${STT_ENABLED:-1}" SCHEDULED_TRIGGERS_CONF="$STT_CONF" GH_BUDGET_ENABLED="${STT_BUDGET:-0}" \
    /bin/bash "$STT" "$@" 2>"$STT_HOME/stderr.log"); STT_RC=$?
}
stt_stamp() {  # stt_stamp <repo> <workflow> <secs ago> — a last-dispatch timestamp
  mkdir -p "$STT_STATE"; echo $(( $(date +%s) - $3 )) > "$STT_STATE/${1//\//_}__$2.last"
}
stt_iso_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
stt_calls() { grep -c "$1" "$STT_HOME/gh.log" 2>/dev/null | head -1; }

test_stt_adding_a_conf_line_is_picked_up_with_no_code_change() {
  stt_home
  stt_conf '# a comment' 'example-owner/project-a nightly.yml 1440' '' 'example-owner/project-b release.yaml 5   # trailing comment'
  stt_run
  assert_exit0 "$STT_RC" "run" || return 1
  assert_eq "$(sort "$STT_HOME/gh.log" | grep '^workflow run')" "workflow run nightly.yml --repo example-owner/project-a
workflow run release.yaml --repo example-owner/project-b" "both lines dispatched, no --ref (gh uses the default branch)" || return 1
  stt_conf 'example-owner/project-c added-later.yml 15'
  : > "$STT_HOME/gh.log"; stt_run
  assert_eq "$(grep '^workflow run' "$STT_HOME/gh.log")" "workflow run added-later.yml --repo example-owner/project-c" "the new line alone is due on the next pass" || return 1
}

test_stt_inputs_and_ref_become_flags() {
  stt_home
  stt_conf 'example-owner/project-a cleanup.yml 1440 dry_run=true ref=main'
  stt_run
  assert_eq "$(grep '^workflow run' "$STT_HOME/gh.log")" "workflow run cleanup.yml --repo example-owner/project-a -f dry_run=true --ref main" "flags" || return 1
}

test_stt_nothing_due_makes_zero_gh_calls() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5' 'example-owner/project-b b.yml 60'
  stt_stamp example-owner/project-a a.yml 120   # 2 min ago, interval 5 min
  stt_stamp example-owner/project-b b.yml 600
  STT_BUDGET=1 stt_run
  assert_eq "$(wc -c < "$STT_HOME/gh.log" | tr -d ' ')" "0" "no gh call at all (not even the quota read)" || return 1
}

test_stt_due_only_when_the_local_timestamp_is_older_than_the_interval() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  stt_stamp example-owner/project-a a.yml 301
  stt_run
  assert_eq "$(stt_calls '^run list')" "1" "one read" || return 1
  assert_eq "$(stt_calls '^workflow run')" "1" "one dispatch" || return 1
  local now stamp; now=$(date +%s); stamp=$(cat "$STT_STATE/example-owner_project-a__a.yml.last")
  [ $((now - stamp)) -le 5 ] || { fail "timestamp restamped to now, got $stamp vs $now"; return 1; }
  assert_contains "$(cat "$STT_HOME/logs/pipeline/scheduled-triggers.log")" " example-owner/project-a a.yml ok" "heartbeat line: <ts> <repo> <workflow> ok" || return 1
  case "$(cut -d' ' -f1 "$STT_HOME/logs/pipeline/scheduled-triggers.log")" in *[!0-9]*|'') fail "heartbeat line starts with an epoch"; return 1 ;; esac
}

test_stt_a_queued_or_in_progress_run_blocks_the_dispatch() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5' 'example-owner/project-b b.yml 5'
  echo "[{\"status\":\"queued\",\"createdAt\":\"$(stt_iso_ago 3600)\"}]" > "$STT_HOME/runs-a.yml.json"
  echo "[{\"status\":\"in_progress\",\"createdAt\":\"$(stt_iso_ago 3600)\"},{\"status\":\"completed\",\"createdAt\":\"$(stt_iso_ago 7200)\"}]" > "$STT_HOME/runs-b.yml.json"
  stt_run
  assert_eq "$(stt_calls '^workflow run')" "0" "no dispatch" || return 1
  assert_file_absent "$STT_STATE/example-owner_project-a__a.yml.last" "timestamp untouched" || return 1
}

test_stt_a_run_started_within_the_interval_stamps_the_timestamp_and_skips() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  echo "[{\"status\":\"completed\",\"createdAt\":\"$(stt_iso_ago 100)\"}]" > "$STT_HOME/runs-a.yml.json"
  stt_run
  assert_eq "$(stt_calls '^workflow run')" "0" "the other host / GitHub's cron fired it 100 s ago" || return 1
  local now stamp; now=$(date +%s); stamp=$(cat "$STT_STATE/example-owner_project-a__a.yml.last")
  [ $((now - stamp)) -ge 95 ] && [ $((now - stamp)) -le 110 ] || { fail "stamped from the run's own time, got age $((now - stamp))"; return 1; }
  : > "$STT_HOME/gh.log"; stt_run
  assert_eq "$(wc -c < "$STT_HOME/gh.log" | tr -d ' ')" "0" "and the next pass is not due" || return 1
}

test_stt_a_failed_dispatch_is_isolated_logged_once_and_never_stamped() {
  stt_home
  stt_conf 'example-owner/project-a bad.yml 5' 'example-owner/project-b good.yml 5'
  echo 'bad.yml' > "$STT_HOME/dispatch-fail"
  stt_run
  assert_exit0 "$STT_RC" "a failing workflow does not fail the pass" || return 1
  assert_eq "$(stt_calls '^workflow run good.yml')" "1" "the other workflow still dispatched" || return 1
  assert_file_absent "$STT_STATE/example-owner_project-a__bad.yml.last" "no timestamp for the failed one" || return 1
  assert_file_exists "$STT_STATE/example-owner_project-b__good.yml.last" "timestamp for the good one" || return 1
  assert_contains "$(cat "$STT_HOME/logs/pipeline/scheduled-triggers.log")" " example-owner/project-a bad.yml failed" "heartbeat log says failed" || return 1
  local c; c=$(cat "$STT_HOME/curl.log")
  assert_eq "$(grep -c . "$STT_HOME/curl.log")" "1" "one Slack message" || return 1
  assert_contains "$c" "route=scheduled-triggers" "route tag" || return 1
  assert_contains "$c" "environment=" "environment tag" || return 1
  assert_contains "$c" "release=" "release tag" || return 1
  assert_contains "$c" "bad.yml" "names the workflow" || return 1
  assert_not_contains "$c" "HTTP 422" "no gh error text (could carry anything)" || return 1
  assert_not_contains "$(sed 's#https://example.invalid/hook-secret-token##' "$STT_HOME/curl.log")" "secret" "the webhook is only the URL argument, not in the payload" || return 1
  local rel; rel=$(grep -o 'release=[0-9a-f]*' <<< "$c" | head -1)
  [ "${#rel}" -ge 47 ] || [ "$rel" = "release=unknown" ] || { fail "release is the full commit SHA, got [$rel]"; return 1; }
  : > "$STT_HOME/gh.log"; stt_run
  assert_eq "$(grep -c . "$STT_HOME/curl.log")" "1" "second failure within the hour: no second Slack message" || return 1
  assert_eq "$(grep -c 'bad.yml failed' "$STT_HOME/logs/pipeline/scheduled-triggers.log")" "1" "...and no second log line for it" || return 1
}

test_stt_a_failed_run_list_is_captured_and_skips_only_that_workflow() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  touch "$STT_HOME/runs-fail"
  stt_run
  assert_eq "$(stt_calls '^workflow run')" "0" "no blind dispatch when the read failed" || return 1
  assert_contains "$(cat "$STT_HOME/curl.log")" "route=scheduled-triggers" "captured with tags" || return 1
}

test_stt_two_instances_at_once_dispatch_once() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  echo 1 > "$STT_HOME/dispatch-sleep"
  ( stt_run ) & ( stt_run ) & wait
  assert_eq "$(stt_calls '^workflow run')" "1" "one dispatch" || return 1
  assert_eq "$(grep -c ' ok$' "$STT_HOME/logs/pipeline/scheduled-triggers.log")" "1" "one heartbeat line" || return 1
}

test_stt_low_budget_makes_no_github_call() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  # a fresh quota reading: core exhausted until an hour from now (gh-budget.sh: "<read at> <core> <core reset> <graphql> <graphql reset>")
  printf '%s 0 %s 4000 %s\n' "$(date +%s)" "$(( $(date +%s) + 3600 ))" "$(( $(date +%s) + 3600 ))" > "$STT_HOME/pipe/gh-quota"
  # _GH_INNER=1 makes gh-budget.sh's gh() wrapper pass every call straight through, so only the script's own
  # `gh_tier_allows normal` gate can keep the stub from being called: deleting that gate fails this test.
  _GH_INNER=1 STT_BUDGET=1 stt_run
  assert_eq "$(wc -c < "$STT_HOME/gh.log" | tr -d ' ')" "0" "nothing called (wrapper bypassed)" || return 1
  assert_file_absent "$STT_STATE/example-owner_project-a__a.yml.last" "nothing stamped" || return 1
  # control: the same pass with a healthy quota does call gh
  printf '%s 4000 %s 4000 %s\n' "$(date +%s)" "$(( $(date +%s) + 3600 ))" "$(( $(date +%s) + 3600 ))" > "$STT_HOME/pipe/gh-quota"
  _GH_INNER=1 STT_BUDGET=1 stt_run
  assert_eq "$(stt_calls '^workflow run')" "1" "control: healthy quota dispatches" || return 1
}

test_stt_a_malformed_run_list_is_captured_and_never_dispatches() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  echo '{"message":"Not Found"}' > "$STT_HOME/runs-a.yml.json"   # valid JSON, not an array
  stt_run
  assert_eq "$(stt_calls '^workflow run')" "0" "no dispatch on an unreadable run list" || return 1
  assert_contains "$(cat "$STT_HOME/curl.log")" "run list failed" "captured" || return 1
}

test_stt_an_unwritable_state_dir_is_captured_once_and_dispatches_nothing() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  : > "$STT_HOME/not-a-dir"
  SCHEDULED_TRIGGERS_STATE_DIR="$STT_HOME/not-a-dir/state" stt_run
  assert_eq "$(wc -c < "$STT_HOME/gh.log" | tr -d ' ')" "0" "nothing dispatched" || return 1
  assert_contains "$(cat "$STT_HOME/curl.log")" "state dir not writable" "captured" || return 1
  assert_contains "$(cat "$STT_HOME/curl.log")" "route=scheduled-triggers" "with the route tag" || return 1
  SCHEDULED_TRIGGERS_STATE_DIR="$STT_HOME/not-a-dir/state" stt_run
  assert_eq "$(grep -c . "$STT_HOME/curl.log")" "1" "once per hour" || return 1
}

test_stt_off_unless_enabled() {
  stt_home
  stt_conf 'example-owner/project-a a.yml 5'
  STT_ENABLED=0 stt_run
  assert_eq "$(wc -c < "$STT_HOME/gh.log" | tr -d ' ')" "0" "disabled: no call" || return 1
  STT_ENABLED=0 stt_run status
  assert_eq "$STT_OUT" "[]" "disabled: empty heartbeat" || return 1
}

test_stt_bad_config_lines_are_ignored_not_fatal() {
  stt_home
  stt_conf 'no-slash a.yml 5' 'example-owner/project-a notyaml.sh 5' 'example-owner/project-a b.yml 0' 'example-owner/project-a c.yml 5 badtoken' 'example-owner/project-a $(x).yml 5' 'example-owner/project-a ok.yml 5'
  stt_run
  assert_eq "$(grep '^workflow run' "$STT_HOME/gh.log")" "workflow run ok.yml --repo example-owner/project-a" "only the valid line runs" || return 1
}

test_stt_status_is_the_heartbeat_json() {
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5' 'example-owner/project-b never.yml 60'
  stt_stamp example-owner/project-a auto-release.yml 60
  stt_run status
  assert_eq "$(printf '%s' "$STT_OUT" | jq -c 'map(.repo + " " + .workflow + " " + (.interval_minutes|tostring) + " " + (.last_fired_at != null | tostring))')" \
    '["example-owner/project-a auto-release.yml 5 true","example-owner/project-b never.yml 60 false"]' "entries" || return 1
  assert_eq "$(stt_calls .)" "0" "status makes no gh call" || return 1
  local iso; iso=$(printf '%s' "$STT_OUT" | jq -r '.[0].last_fired_at')
  case "$iso" in 20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) ;; *) fail "ISO time, got $iso"; return 1 ;; esac
}

test_stt_report_status_publishes_the_heartbeat_by_alias_without_the_fire_time_in_the_hash() {
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5'
  stt_stamp example-owner/project-a auto-release.yml 60
  printf 'STATUS_REPO_ALIASES=("example-owner/project-a:project-a")\nSCHEDULED_TRIGGERS_ENABLED=1\nSCHEDULED_TRIGGERS_CONF="%s"\nSTATUS_PUSH_URL=https://example.invalid/beat\nSTATUS_PUSH_TOKEN=t\nMAX_PUSHES_PER_DAY=8640\n' "$STT_CONF" >> "$STT_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\necho "curl $*" >> "$HOME/curl.log"; printf 200\n' > "$STT_HOME/bin/curl"
  local out rs; rs() { HOME="$STT_HOME" PATH="$STT_HOME/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$STT_HOME/pipe" LOGDIR="$STT_HOME/logs/pipeline" STATUS_CRON_CMD=true \
    SCHEDULED_TRIGGERS_ENABLED=1 /bin/bash "$HERE_STT/../report-status.sh" "$@" 2>/dev/null; }
  out=$(rs --print)
  assert_eq "$(printf '%s' "$out" | jq -c '.scheduled_triggers | map({repo, workflow, interval_minutes})')" '[{"repo":"project-a","workflow":"auto-release.yml","interval_minutes":5}]' "published by alias" || return 1
  assert_not_contains "$out" "example-owner" "no owner/repo in the payload" || return 1
  # behavioural: a push happens, then a new fire time alone is "unchanged" (no second push), while a new workflow line is a change
  : > "$STT_HOME/curl.log"; rs tick >/dev/null
  assert_eq "$(grep -c 'beat' "$STT_HOME/curl.log")" "1" "first beat pushed" || return 1
  stt_stamp example-owner/project-a auto-release.yml 1   # the router fired again: only last_fired_at moves
  sleep 11; rs tick >/dev/null
  assert_eq "$(grep -c 'beat' "$STT_HOME/curl.log")" "1" "a new fire time alone does not push" || return 1
  stt_conf 'example-owner/project-a stale-prs.yml 1440'
  sleep 11; rs tick >/dev/null
  assert_eq "$(grep -c 'beat' "$STT_HOME/curl.log")" "2" "a new workflow line does push" || return 1
}

test_stt_the_shipped_conf_parses_and_lists_the_release_routers() {
  local out
  out=$(HOME=$(new_home) SCHEDULED_TRIGGERS_ENABLED=1 SCHEDULED_TRIGGERS_CONF="$HERE_STT/../scheduled-triggers.conf" PIPE=$(new_pipe) /bin/bash "$STT" status 2>&1)
  assert_contains "$out" '"workflow":"auto-release.yml"' "ops auto-release is active" || return 1
  assert_contains "$out" '"workflow":"ci-metrics.yml"' "claude-agents ci-metrics is active" || return 1
  assert_not_contains "$out" "deploy-staging" "deploy-staging stays off: a dispatched run deploys, a scheduled one only alerts" || return 1
  assert_not_contains "$out" "sentry-intake" "sentry-intake stays off: a dispatch bypasses its kill switch" || return 1
  assert_contains "$out" '"workflow":"feedback-attachments-cleanup.yml"' "cleanup listed" || return 1
  grep -q '^Benjis-Plants/benjis-ops-tool feedback-attachments-cleanup.yml 1440 dry_run=true' "$HERE_STT/../scheduled-triggers.conf" || { fail "cleanup mirrors its scheduled dry run"; return 1; }
}

run_test test_stt_adding_a_conf_line_is_picked_up_with_no_code_change
run_test test_stt_inputs_and_ref_become_flags
run_test test_stt_nothing_due_makes_zero_gh_calls
run_test test_stt_due_only_when_the_local_timestamp_is_older_than_the_interval
run_test test_stt_a_queued_or_in_progress_run_blocks_the_dispatch
run_test test_stt_a_run_started_within_the_interval_stamps_the_timestamp_and_skips
run_test test_stt_a_failed_dispatch_is_isolated_logged_once_and_never_stamped
run_test test_stt_a_failed_run_list_is_captured_and_skips_only_that_workflow
run_test test_stt_a_malformed_run_list_is_captured_and_never_dispatches
run_test test_stt_two_instances_at_once_dispatch_once
run_test test_stt_low_budget_makes_no_github_call
run_test test_stt_an_unwritable_state_dir_is_captured_once_and_dispatches_nothing
run_test test_stt_off_unless_enabled
run_test test_stt_bad_config_lines_are_ignored_not_fatal
run_test test_stt_status_is_the_heartbeat_json
run_test test_stt_report_status_publishes_the_heartbeat_by_alias_without_the_fire_time_in_the_hash
run_test test_stt_the_shipped_conf_parses_and_lists_the_release_routers
