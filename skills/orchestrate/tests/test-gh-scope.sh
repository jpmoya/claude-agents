# gh-scope.sh (2026-11-23 incident: the Mac's gh token lost `project`, 94 identical goal errors, nobody told).
# A stub `gh` answers `api rate_limit -i` with a header block (X-OAuth-Scopes from $GS/scopes) + the TSV line and records every call;
# a stub `curl` records Slack posts. Every tick is one process: gh_quota_line (the supervisor's own call) then gh_scope_check.
# Expected values hand-written. Prefix gs_.

GS_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GS_LIB="$GS_HERE/.."

gs_env() {  # gs_env <scopes header value, or - for no header>
  GS=$(mktemp -d "${TMPDIR:-/tmp}/gh-scope-test.XXXXXX")
  mkdir -p "$GS/bin" "$GS/pipe" "$GS/log"
  : > "$GS/calls"; : > "$GS/slack"; : > "$GS/slog"
  printf '%s' "$1" > "$GS/scopes"
  cat > "$GS/bin/gh" <<EOT
#!/bin/bash
echo "\$*" >> "$GS/calls"
[ -e "$GS/fail" ] && exit 1
if [ "\$1 \$2" = "api rate_limit" ]; then
  echo "HTTP/2.0 200 OK"
  [ "\$(cat "$GS/scopes")" = "-" ] || echo "X-Oauth-Scopes: \$(cat "$GS/scopes")"
  echo "X-Ratelimit-Remaining: 4000"
  echo
  printf '4000\t9999999999\t5000\t9999999999\n'
  exit 0
fi
echo "unexpected gh call: \$*" >&2; exit 1
EOT
  cat > "$GS/bin/curl" <<EOT
#!/bin/bash
echo "\$*" >> "$GS/slack"
EOT
  chmod +x "$GS/bin/gh" "$GS/bin/curl"
}

gs_tick() {  # gs_tick [extra env assignments...] — one supervisor-tick's worth: quota read (saves the scopes) then the check
  env PATH="$GS/bin:$PATH" PIPE="$GS/pipe" LOGDIR="$GS/log" GH_BUDGET_ENABLED=1 GH_QUOTA_TTL_SECS=0 GH_SCOPE_CHECK_ENABLED=1 \
    SLACK_WEBHOOK_URL=https://hooks.example.invalid/x GH_REQUIRED_SCOPES="${GS_REQ:-repo workflow project read:org}" "$@" \
    bash -c ". '$GS_LIB/gh-budget.sh'; . '$GS_LIB/code-sync.sh'; . '$GS_LIB/gh-scope.sh'
      slog() { echo \"\$*\" >> '$GS/slog'; }
      gh_quota_line >/dev/null; gh_scope_check" 2>>"$GS/err"
}
gs_slack_count() { local n; n=$(grep -c . "$GS/slack" 2>/dev/null); echo "${n:-0}"; }
gs_log_count() { local n; n=$(grep -c '^\[gh-scope\]' "$GS/slog" 2>/dev/null); echo "${n:-0}"; }
gs_done() { rm -rf "$GS"; }

test_gs_missing_scope_alerts_once_with_host_scope_and_fix_command() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick
  local a host; a=$(cat "$GS/pipe/gh-scope.alert" 2>/dev/null); host=$(hostname -s | tr '[:upper:]' '[:lower:]')
  assert_contains "$a" "on $host is missing the project permission" "alert names the host and the scope" || return 1
  assert_contains "$a" "gh auth refresh -h github.com -s project" "alert carries the exact fix command" || return 1
  assert_eq "$(gs_slack_count)" 1 "one Slack post on the first tick" || return 1
  assert_contains "$(cat "$GS/slack")" "gh auth refresh -h github.com -s project" "Slack text carries the fix command" || return 1
  gs_done
}

test_gs_repeated_ticks_do_not_realert_and_log_one_line_per_tick() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick; gs_tick; gs_tick
  assert_eq "$(gs_slack_count)" 1 "still one Slack post after three ticks" || return 1
  assert_eq "$(gs_log_count)" 3 "exactly one [gh-scope] log line per tick" || return 1
  assert_contains "$(cat "$GS/pipe/gh-scope.alert-state" | cut -d' ' -f2)" 3 "state counts the ticks" || return 1
  gs_done
}

test_gs_scope_back_clears_the_alert_and_stays_quiet() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick; gs_tick
  printf '%s' "gist, project, read:org, repo, workflow" > "$GS/scopes"
  gs_tick
  assert_file_absent "$GS/pipe/gh-scope.alert" "alert file removed" || return 1
  assert_file_absent "$GS/pipe/gh-scope.alert-state" "state removed" || return 1
  assert_eq "$(gs_slack_count)" 1 "clearing posts nothing more to Slack" || return 1
  assert_contains "$(cat "$GS/slog")" "alert cleared" "the clear is logged" || return 1
  gs_tick
  assert_eq "$(gs_log_count)" 3 "after the clear a healthy tick logs nothing" || return 1
  # a NEW outage after recovery is a new alert
  printf '%s' "gist, read:org, repo, workflow" > "$GS/scopes"
  gs_tick
  assert_eq "$(gs_slack_count)" 2 "a second outage alerts again" || return 1
  gs_done
}

test_gs_all_scopes_present_is_silent() {
  gs_env "gist, project, read:org, repo, workflow"
  gs_tick; gs_tick
  assert_file_absent "$GS/pipe/gh-scope.alert" "no alert" || return 1
  assert_eq "$(gs_slack_count)" 0 "no Slack" || return 1
  assert_eq "$(gs_log_count)" 0 "no log line" || return 1
  gs_done
}

test_gs_no_extra_rest_calls_only_the_free_rate_limit_read() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick; gs_tick
  assert_eq "$(gs_calls_count)" 2 "one gh call per tick (the supervisor's own quota read)" || return 1
  assert_eq "$(grep -vc '^api rate_limit ' "$GS/calls")" 0 "every call is api rate_limit: no api user, no core endpoint" || return 1
  assert_eq "$(bash -c ". '$GS_LIB/gh-budget.sh'; _gh_scan api rate_limit -i --jq x; echo \$_GH_BUCKET")" none "gh-budget classes the read as bucket none (free, no REST quota)" || return 1
  gs_done
}
gs_calls_count() { local n; n=$(grep -c . "$GS/calls" 2>/dev/null); echo "${n:-0}"; }

test_gs_unknown_scopes_neither_alert_nor_clear() {
  gs_env "-"   # fine-grained / app token: no X-OAuth-Scopes header
  gs_tick
  assert_file_absent "$GS/pipe/gh-scope.alert" "no header -> no alert" || return 1
  gs_done
  gs_env "gist, read:org, repo, workflow"
  gs_tick
  printf '%s' "-" > "$GS/scopes"; gs_tick
  assert_file_exists "$GS/pipe/gh-scope.alert" "an unknown read does not clear a standing alert" || return 1
  touch "$GS/fail"; gs_tick
  assert_file_exists "$GS/pipe/gh-scope.alert" "a failed read does not clear it either" || return 1
  assert_eq "$(gs_slack_count)" 1 "and none of this re-alerts" || return 1
  gs_done
}

test_gs_a_process_with_its_own_token_env_never_touches_the_host_scopes() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick; gs_tick
  printf '%s' "gist, project, read:org, repo, workflow" > "$GS/scopes"   # a bot PAT that DOES hold project
  gs_tick GH_TOKEN=x
  assert_file_exists "$GS/pipe/gh-scope.alert" "a GH_TOKEN process does not clear the host's standing alert" || return 1
  gs_done
  gs_env "gist, read:org, repo, workflow"   # and a narrow bot PAT does not start one
  gs_tick GITHUB_TOKEN=x
  assert_file_absent "$GS/pipe/gh-scope.alert" "nor create one" || return 1
  assert_file_absent "$GS/pipe/gh-scopes" "and nothing is recorded" || return 1
  gs_done
}

test_gs_stale_scopes_file_is_unknown() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick; rm -f "$GS/pipe/gh-scope.alert" "$GS/pipe/gh-scope.alert-state"
  touch "$GS/fail"
  printf '%s known gist,repo\n' "$(( $(date +%s) - 3600 ))" > "$GS/pipe/gh-scopes"
  gs_tick
  assert_file_absent "$GS/pipe/gh-scope.alert" "a scopes file older than GH_SCOPES_STALE_SECS is not trusted" || return 1
  gs_done
}

test_gs_a_different_missing_set_alerts_again() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick
  printf '%s' "gist, read:org, repo" > "$GS/scopes"; gs_tick
  assert_eq "$(gs_slack_count)" 2 "project, then workflow too: a new problem posts once more" || return 1
  assert_contains "$(cat "$GS/pipe/gh-scope.alert")" "workflow, project" "both scopes named" || return 1
  gs_done
}

test_gs_admin_org_satisfies_read_org_and_the_required_set_is_overridable() {
  gs_env "admin:org, project, repo, workflow"
  gs_tick
  assert_file_absent "$GS/pipe/gh-scope.alert" "admin:org covers read:org" || return 1
  gs_done
  gs_env "repo, workflow, read:org"
  GS_REQ="repo workflow read:org" gs_tick
  assert_file_absent "$GS/pipe/gh-scope.alert" "a host that does not require project is quiet without it" || return 1
  gs_done
}

test_gs_switch_off_is_silent() {
  gs_env "gist"
  gs_tick GH_SCOPE_CHECK_ENABLED=0
  assert_file_absent "$GS/pipe/gh-scope.alert" "GH_SCOPE_CHECK_ENABLED=0 -> nothing" || return 1
  gs_done
}

gs_stall_json() {  # build-runs-json.py goalstall against $GS/pipe
  python3 "$GS_LIB/build-runs-json.py" "" "$GS/pipe/runs.jsonl" "$GS/pipe" goalstall </dev/null 2>/dev/null
}
test_gs_status_page_payload_carries_the_alert_and_clears_with_it() {
  gs_env "gist, read:org, repo, workflow"
  assert_eq "$(gs_stall_json)" "[]" "no alert -> nothing in goal_stall" || return 1
  gs_tick
  local j host; j=$(gs_stall_json); host=$(hostname -s | cut -d. -f1)
  assert_eq "$(printf '%s' "$j" | jq -r '.[0].kind')" token_scope "entry kind (no goal queue file needed)" || return 1
  assert_eq "$(printf '%s' "$j" | jq -r '.[0].reason')" project "missing scope named" || return 1
  assert_contains "$(printf '%s' "$j" | jq -r '.[0].hint')" "gh auth refresh -h github.com -s project on" "fix command in the hint" || return 1
  printf '%s' "gist, project, read:org, repo, workflow" > "$GS/scopes"; gs_tick
  assert_eq "$(gs_stall_json)" "[]" "cleared with the alert" || return 1
  gs_done
}

test_gs_launcher_status_shows_the_alert_line() {
  gs_env "gist, read:org, repo, workflow"
  gs_tick
  assert_contains "$(grep -n 'gh-scope.alert' "$GS_LIB/launcher.sh")" "!! GH TOKEN" "launcher.sh status prints it next to the code-sync line" || return 1
  gs_done
}

run_test test_gs_missing_scope_alerts_once_with_host_scope_and_fix_command
run_test test_gs_repeated_ticks_do_not_realert_and_log_one_line_per_tick
run_test test_gs_scope_back_clears_the_alert_and_stays_quiet
run_test test_gs_all_scopes_present_is_silent
run_test test_gs_no_extra_rest_calls_only_the_free_rate_limit_read
run_test test_gs_unknown_scopes_neither_alert_nor_clear
run_test test_gs_a_process_with_its_own_token_env_never_touches_the_host_scopes
run_test test_gs_stale_scopes_file_is_unknown
run_test test_gs_a_different_missing_set_alerts_again
run_test test_gs_admin_org_satisfies_read_org_and_the_required_set_is_overridable
run_test test_gs_switch_off_is_silent
run_test test_gs_status_page_payload_carries_the_alert_and_clears_with_it
run_test test_gs_launcher_status_shows_the_alert_line
