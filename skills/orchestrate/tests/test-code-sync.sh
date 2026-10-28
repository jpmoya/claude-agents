# Code sync guard (docs/host-sync.md): fresh / updated (fast-forward) / stale (refuse to launch).
HERE_CS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

cs_settings() {  # cs_settings <model> <hooks> — a multi-line settings.json, so edits far apart do not overlap in a patch
  printf '{\n  "model": "%s",\n  "a": 1,\n  "b": 2,\n  "c": 3,\n  "d": 4,\n  "e": 5,\n  "f": 6,\n  "g": 7,\n  "hooks": "%s"\n}\n' "$1" "$2"
}

cs_fixture() {  # cs_fixture -> $CSD with origin (bare), upstream (pusher), host (clone with code-sync.sh)
  CSD=$(mktemp -d "${TMPDIR:-/tmp}/cs-test.XXXXXX")
  git init -q --bare -b main "$CSD/origin.git"
  git clone -q "$CSD/origin.git" "$CSD/up" 2>/dev/null
  ( cd "$CSD/up" && git config user.email t@t && git config user.name t && mkdir -p skills/orchestrate \
    && cp "$HERE_CS/../code-sync.sh" skills/orchestrate/ && cs_settings sonnet h1 > settings.json \
    && cs_settings sonnet h1 > skills/orchestrate/settings.json \
    && git add -A && git commit -qm base && git push -q origin HEAD:main )
  git clone -q "$CSD/origin.git" "$CSD/host" 2>/dev/null
  ( cd "$CSD/host" && git config user.email t@t && git config user.name t )
}
cs_push() { ( cd "$CSD/up" && echo "$1" >> f && git add -A && git commit -qm "$1" && git push -q origin HEAD:main ); }
cs_push_settings() { ( cd "$CSD/up" && cs_settings "$1" "$2" > settings.json && git add -A && git commit -qm "settings $1 $2" && git push -q origin HEAD:main ); }
cs_run() { ( cd "$CSD/host/skills/orchestrate" && ./code-sync.sh check 2>/dev/null ); }
cs_apply() { ( cd "$CSD/host/skills/orchestrate" && ./code-sync.sh apply 2>/dev/null ); }
cs_head_is_origin() { assert_eq "$(git -C "$CSD/host" rev-parse HEAD)" "$(git -C "$CSD/up" rev-parse HEAD)" "$1"; }

test_code_sync_fresh_when_equal() {
  cs_fixture; assert_eq "$(cs_run)" fresh "equal -> fresh"
}
test_code_sync_behind_is_fixable_and_check_does_not_merge() {
  cs_fixture; cs_push one; assert_eq "$(cs_run)" fixable "behind clean main -> fixable"
  assert_ne "$(git -C "$CSD/host" rev-parse HEAD)" "$(git -C "$CSD/up" rev-parse HEAD)" "check does not merge"
}
test_code_sync_apply_fast_forwards() {
  cs_fixture; cs_push one; cs_run >/dev/null; cs_apply >/dev/null
  cs_head_is_origin "host at origin/main after apply"
  assert_eq "$(cs_run)" fresh "fresh after apply"
}
test_code_sync_other_branch_clean_is_fixable_and_apply_returns_to_main() {
  cs_fixture; ( cd "$CSD/host" && git checkout -q -b feature ); cs_push one
  assert_eq "$(cs_run)" fixable "clean feature branch -> fixable"; cs_apply >/dev/null
  assert_eq "$(git -C "$CSD/host" branch --show-current)" main "back on main"
}
test_code_sync_stale_with_unpushed_commit_on_branch() {
  cs_fixture; ( cd "$CSD/host" && git checkout -q -b feature && echo l >> g && git add -A && git commit -qm local ); cs_push one
  assert_eq "$(cs_run)" stale "unpushed work on another branch -> stale"
}
test_code_sync_stale_when_dirty_tracked_tree() {
  cs_fixture; cs_push one; echo x >> "$CSD/host/skills/orchestrate/code-sync.sh"
  assert_eq "$(cs_run)" stale "dirty tracked file -> stale"
}
test_code_sync_offline_is_not_stale() {
  cs_fixture; mv "$CSD/origin.git" "$CSD/gone.git"; assert_eq "$(cs_run)" fresh "fetch failure keeps last known state"
}

# --- the settings.json trap: ~/.claude/settings.json is a symlink into the checkout, so the harness itself dirties it ---
test_code_sync_harness_settings_drift_alone_is_not_stale() {
  cs_fixture; cs_push one; cs_settings opus h1 > "$CSD/host/settings.json"
  assert_eq "$(cs_run)" fixable "only top-level settings.json dirty + behind -> fixable, not stale" || return 1
  assert_eq "$(cs_apply)" applied "apply succeeds" || return 1
  cs_head_is_origin "fast-forwarded despite settings drift" || return 1
  assert_contains "$(cat "$CSD/host/settings.json")" '"model": "opus"' "harness edit kept across the fast-forward" || return 1
  assert_eq "$(cs_run)" fresh "fresh afterwards (drift on an up-to-date main is fine)"
}
test_code_sync_settings_drift_and_upstream_change_merge_when_apart() {
  cs_fixture; cs_push_settings sonnet h2; cs_settings opus h1 > "$CSD/host/settings.json"
  assert_eq "$(cs_run)" fixable "drift + non-overlapping upstream settings change -> fixable" || return 1
  assert_eq "$(cs_apply)" applied "apply succeeds" || return 1
  cs_head_is_origin "fast-forwarded" || return 1
  local s; s=$(cat "$CSD/host/settings.json")
  assert_contains "$s" '"hooks": "h2"' "upstream settings change landed" || return 1
  assert_contains "$s" '"model": "opus"' "local harness edit re-applied on top" || return 1
  assert_eq "$(ls "$CSD/host/.git/code-sync" 2>/dev/null | wc -l | tr -d ' ')" 0 "no leftover drift patch when it re-applied"
}
test_code_sync_settings_drift_clashing_with_upstream_takes_upstream_and_keeps_patch() {
  cs_fixture; cs_push_settings haiku h1; cs_settings opus h1 > "$CSD/host/settings.json"
  assert_eq "$(cs_run)" fixable "drift clashing with upstream -> still fixable (never fixable-forever)" || return 1
  assert_eq "$(cs_apply)" applied "apply succeeds" || return 1
  cs_head_is_origin "fast-forwarded, the host is not left on old code" || return 1
  assert_eq "$(cat "$CSD/host/settings.json")" "$(cat "$CSD/up/settings.json")" "origin/main's settings.json wins on a clash" || return 1
  assert_not_contains "$(cat "$CSD/host/settings.json")" '<<<<<<<' "no conflict markers in the live settings file" || return 1
  assert_contains "$(cat "$CSD/host/.git/code-sync/"drift-*.patch 2>/dev/null)" '"model": "opus"' "local edit saved as a patch" || return 1
  assert_eq "$(cs_run)" fresh "fresh afterwards"
}
test_code_sync_settings_drift_on_feature_branch_returns_to_main() {
  cs_fixture; ( cd "$CSD/host" && git checkout -q -b feature ); cs_push_settings sonnet h2; cs_settings opus h1 > "$CSD/host/settings.json"
  assert_eq "$(cs_run)" fixable "clean feature branch + settings drift -> fixable" || return 1
  assert_eq "$(cs_apply)" applied "apply succeeds" || return 1
  assert_eq "$(git -C "$CSD/host" branch --show-current)" main "back on main" || return 1
  cs_head_is_origin "at origin/main"
}
test_code_sync_settings_drift_plus_real_file_is_stale() {
  cs_fixture; cs_push one; cs_settings opus h1 > "$CSD/host/settings.json"; echo x >> "$CSD/host/skills/orchestrate/code-sync.sh"
  assert_eq "$(cs_run)" stale "settings drift does not hide a real dirty file"
}
test_code_sync_nested_settings_json_still_counts_as_dirty() {
  cs_fixture; cs_push one; cs_settings opus h1 > "$CSD/host/skills/orchestrate/settings.json"
  assert_eq "$(cs_run)" stale "only the top-level settings.json is harness-owned"
}
test_code_sync_why_names_the_dirty_file() {
  cs_fixture; cs_push one; echo "# x" >> "$CSD/host/skills/orchestrate/code-sync.sh"; cs_settings opus h1 > "$CSD/host/settings.json"
  local w tab; tab=$(printf '\t'); w=$( cd "$CSD/host/skills/orchestrate" && ./code-sync.sh why )
  assert_eq "${w%%$tab*}" dirty "class is dirty" || return 1
  assert_contains "$w" "skills/orchestrate/code-sync.sh" "names the dirty file" || return 1
  assert_not_contains "$w" "settings.json" "harness drift is not reported as the cause"
}

# --- the loud guard: alert file + throttled Slack + recovery ---------------------------------------------------------
cs_alert_env() {  # -> $CSA_PIPE (temp PIPE), $CSA_BIN (curl recorder first on PATH)
  CSA_PIPE=$(mktemp -d "${TMPDIR:-/tmp}/cs-alert-pipe.XXXXXX"); CSA_BIN=$(mktemp -d "${TMPDIR:-/tmp}/cs-alert-bin.XXXXXX")
  : > "$CSA_BIN/curl-calls.log"
  printf '#!/bin/bash\necho "$*" >> "%s/curl-calls.log"\nexit 0\n' "$CSA_BIN" > "$CSA_BIN/curl"; chmod +x "$CSA_BIN/curl"
}
cs_alert_call() {  # cs_alert_call <shell snippet> — runs it with code-sync.sh sourced in an isolated subshell
  ( PIPE="$CSA_PIPE" PATH="$CSA_BIN:$PATH" SLACK_WEBHOOK_URL="${CSA_HOOK-https://hooks.example.invalid/x}"
    . "$HERE_CS/../code-sync.sh"; eval "$1" )
}
cs_curl_count() { wc -l < "$CSA_BIN/curl-calls.log" | tr -d ' '; }

test_code_sync_alert_file_written_on_refusal_and_slack_throttled() {
  cs_alert_env
  cs_alert_call 'code_sync_alert dirty "uncommitted edits to tracked files: hooks/x.sh"'
  cs_alert_call 'code_sync_alert dirty "uncommitted edits to tracked files: hooks/x.sh"'
  assert_file_exists "$CSA_PIPE/code-sync.alert" "alert file present while refusing" || return 1
  local a; a=$(cat "$CSA_PIPE/code-sync.alert")
  assert_contains "$a" "refused to launch since" "alert says the supervisor is refusing" || return 1
  assert_contains "$a" "(2 ticks)" "alert counts consecutive refusals" || return 1
  assert_contains "$a" "hooks/x.sh" "local alert names the dirty file" || return 1
  assert_eq "$(cs_curl_count)" 1 "first refusal posts to Slack at once, the second (within the hour) does not" || return 1
  local c; c=$(cat "$CSA_BIN/curl-calls.log")
  assert_contains "$c" "route=supervisor/code-sync" "tags-only Slack message" || return 1
  assert_contains "$c" "reason=dirty" "Slack carries the reason class" || return 1
  assert_not_contains "$c" "hooks/x.sh" "Slack never carries file names"
}
test_code_sync_alert_three_consecutive_refusals_post_once() {
  cs_alert_env
  cs_alert_call 'code_sync_alert dirty d'; cs_alert_call 'code_sync_alert dirty d'; cs_alert_call 'code_sync_alert dirty d'
  assert_eq "$(cs_curl_count)" 1 "#515 AC2: a refusal persisting over 3 ticks posts once, not every tick" || return 1
  assert_contains "$(cat "$CSA_PIPE/code-sync.alert")" "(3 ticks)" "the alert file still tracks every refused tick"
}
test_code_sync_alert_reposts_after_the_repeat_window() {
  cs_alert_env
  cs_alert_call 'code_sync_alert dirty d'
  read -r s n l < "$CSA_PIPE/code-sync.alert-state"; echo "$s $n $((l - 4000))" > "$CSA_PIPE/code-sync.alert-state"
  cs_alert_call 'code_sync_alert dirty d'
  assert_eq "$(cs_curl_count)" 2 "a refusal still going after CODE_SYNC_ALERT_REPEAT_SECS is posted again" || return 1
  assert_contains "$(cat "$CSA_PIPE/code-sync.alert")" "(2 ticks)" "streak kept across the repost"
}
test_code_sync_clear_alert_removes_file_and_posts_recovery_once() {
  cs_alert_env
  cs_alert_call 'code_sync_alert unpushed u'
  cs_alert_call 'code_sync_clear_alert'
  assert_file_absent "$CSA_PIPE/code-sync.alert" "alert removed once the guard reopens" || return 1
  assert_file_absent "$CSA_PIPE/code-sync.alert-state" "streak state removed" || return 1
  assert_eq "$(cs_curl_count)" 2 "one refusal post + one recovery post" || return 1
  assert_contains "$(tail -1 "$CSA_BIN/curl-calls.log")" "recovered" "recovery message" || return 1
  cs_alert_call 'code_sync_clear_alert'
  assert_eq "$(cs_curl_count)" 2 "a healthy tick with no streak posts nothing"
}
test_code_sync_alert_file_written_without_a_webhook() {
  cs_alert_env
  CSA_HOOK="" cs_alert_call 'code_sync_alert dirty d'
  assert_file_exists "$CSA_PIPE/code-sync.alert" "alert file does not depend on Slack being configured" || return 1
  assert_eq "$(cs_curl_count)" 0 "no webhook -> no network call"
}
test_code_sync_status_shows_alert_only_when_present() {
  cs_alert_env
  local home; home=$(mktemp -d "${TMPDIR:-/tmp}/cs-alert-home.XXXXXX"); mkdir -p "$home/.claude/pipeline" "$CSA_PIPE/queue"
  local out
  out=$(HOME="$home" PIPE="$CSA_PIPE" QUEUE="$CSA_PIPE/queue" "$HERE_CS/../orchestrate.sh" status 2>&1)
  assert_not_contains "$out" "CODE SYNC" "no alert file -> no line" || return 1
  cs_alert_call 'code_sync_alert dirty d'
  out=$(HOME="$home" PIPE="$CSA_PIPE" QUEUE="$CSA_PIPE/queue" "$HERE_CS/../orchestrate.sh" status 2>&1)
  assert_contains "$out" "!! CODE SYNC:" "status surfaces the refusing guard" || return 1
  assert_contains "$out" "refused to launch since" "with the alert text"
}

# --- end to end: a real supervisor tick on a stale checkout refuses, loudly; a fixed checkout clears it -------------
cs_sup_fixture() {  # a host clone carrying the real supervisor + its libraries, dirtied by a hand patch
  local root; root=$(cd "$HERE_CS/../../.." && pwd)
  CSD=$(mktemp -d "${TMPDIR:-/tmp}/cs-sup.XXXXXX")
  git init -q --bare -b main "$CSD/origin.git"
  git clone -q "$CSD/origin.git" "$CSD/up" 2>/dev/null
  ( cd "$CSD/up" && git config user.email t@t && git config user.name t && mkdir -p skills/orchestrate hooks \
    && cp "$root"/skills/orchestrate/*.sh "$root"/skills/orchestrate/*.py skills/orchestrate/ \
    && cp "$root"/hooks/pipeline-markers.sh hooks/ && cs_settings sonnet h1 > settings.json \
    && git add -A && git commit -qm base && git push -q origin HEAD:main )
  git clone -q "$CSD/origin.git" "$CSD/host" 2>/dev/null
  ( cd "$CSD/host" && git config user.email t@t && git config user.name t )
  CSS_HOME=$(mktemp -d "${TMPDIR:-/tmp}/cs-sup-home.XXXXXX"); mkdir -p "$CSS_HOME/.claude/pipeline" "$CSS_HOME/logs/pipeline"
  CSS_PIPE="$CSS_HOME/.claude/pipeline/state"; mkdir -p "$CSS_PIPE/queue"
  CSA_BIN=$(mktemp -d "${TMPDIR:-/tmp}/cs-sup-bin.XXXXXX"); : > "$CSA_BIN/curl-calls.log"
  printf '#!/bin/bash\necho "$*" >> "%s/curl-calls.log"\nexit 0\n' "$CSA_BIN" > "$CSA_BIN/curl"; chmod +x "$CSA_BIN/curl"
  printf '#!/bin/bash\nexit 1\n' > "$CSA_BIN/gh"; chmod +x "$CSA_BIN/gh"
}
cs_sup_tick() {
  HOME="$CSS_HOME" PATH="$CSA_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$CSS_PIPE" QUEUE="$CSS_PIPE/queue" \
    LOGDIR="$CSS_HOME/logs/pipeline" CODE_SYNC_ENABLED=1 DISPATCH_REPOS="" SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" \
    SLACK_WEBHOOK_URL="https://hooks.example.invalid/x" STATUS_PUSH_URL="" STATUS_PUSH_TOKEN="" \
    "$CSD/host/skills/orchestrate/supervisor.sh" >/dev/null 2>&1
}
test_code_sync_supervisor_tick_refuses_loudly_then_recovers() {
  cs_sup_fixture; cs_push one
  echo "# hand patch" >> "$CSD/host/hooks/pipeline-markers.sh"   # the 2026-10 VM incident: a file hand-copied into the checkout
  cs_sup_tick
  local log; log=$(cat "$CSS_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  assert_contains "$log" "[code-sync] STALE" "tick refused and logged" || return 1
  assert_contains "$log" "hooks/pipeline-markers.sh" "log names the dirty file" || return 1
  assert_file_exists "$CSS_PIPE/code-sync.alert" "a refused tick leaves a visible alert" || return 1
  assert_contains "$(cat "$CSA_BIN/curl-calls.log")" "route=supervisor/code-sync" "and pages Slack" || return 1
  ( cd "$CSD/host" && git checkout -q -- hooks/pipeline-markers.sh )   # the human fix
  cs_sup_tick
  assert_file_absent "$CSS_PIPE/code-sync.alert" "fixed checkout: the fast-forward tick clears the alert" || return 1
  cs_head_is_origin "host fast-forwarded" || return 1
  assert_contains "$(tail -1 "$CSA_BIN/curl-calls.log")" "recovered" "recovery posted"
}
test_code_sync_supervisor_failed_fast_forward_is_loud() {
  cs_sup_fixture; cs_push one; : > "$CSD/host/.git/index.lock"   # fixable, but git cannot move the checkout
  cs_sup_tick
  assert_contains "$(cat "$CSS_HOME/logs/pipeline/supervisor.log" 2>/dev/null)" "[code-sync] APPLY FAILED" "failed fast-forward logged" || return 1
  assert_contains "$(cat "$CSS_PIPE/code-sync.alert" 2>/dev/null)" "apply_failed" "and raised as an alert, not swallowed" || return 1
  rm -f "$CSD/host/.git/index.lock"; cs_sup_tick
  cs_head_is_origin "next tick fast-forwards" || return 1
  assert_file_absent "$CSS_PIPE/code-sync.alert" "and clears the alert"
}
test_code_sync_supervisor_tick_not_blocked_by_settings_drift() {
  cs_sup_fixture; cs_push one; cs_settings opus h1 > "$CSD/host/settings.json"
  cs_sup_tick
  assert_not_contains "$(cat "$CSS_HOME/logs/pipeline/supervisor.log" 2>/dev/null)" "[code-sync] STALE" "harness drift alone never refuses a tick" || return 1
  assert_file_absent "$CSS_PIPE/code-sync.alert" "no alert" || return 1
  cs_head_is_origin "fast-forwarded on exit" || return 1
  assert_contains "$(cat "$CSD/host/settings.json")" '"model": "opus"' "drift kept"
}

run_test test_code_sync_fresh_when_equal
run_test test_code_sync_behind_is_fixable_and_check_does_not_merge
run_test test_code_sync_apply_fast_forwards
run_test test_code_sync_other_branch_clean_is_fixable_and_apply_returns_to_main
run_test test_code_sync_stale_with_unpushed_commit_on_branch
run_test test_code_sync_stale_when_dirty_tracked_tree
run_test test_code_sync_offline_is_not_stale
run_test test_code_sync_harness_settings_drift_alone_is_not_stale
run_test test_code_sync_settings_drift_and_upstream_change_merge_when_apart
run_test test_code_sync_settings_drift_clashing_with_upstream_takes_upstream_and_keeps_patch
run_test test_code_sync_settings_drift_on_feature_branch_returns_to_main
run_test test_code_sync_settings_drift_plus_real_file_is_stale
run_test test_code_sync_nested_settings_json_still_counts_as_dirty
run_test test_code_sync_why_names_the_dirty_file
run_test test_code_sync_alert_file_written_on_refusal_and_slack_throttled
run_test test_code_sync_alert_three_consecutive_refusals_post_once
run_test test_code_sync_alert_reposts_after_the_repeat_window
run_test test_code_sync_clear_alert_removes_file_and_posts_recovery_once
run_test test_code_sync_alert_file_written_without_a_webhook
run_test test_code_sync_status_shows_alert_only_when_present
run_test test_code_sync_supervisor_tick_refuses_loudly_then_recovers
run_test test_code_sync_supervisor_failed_fast_forward_is_loud
run_test test_code_sync_supervisor_tick_not_blocked_by_settings_drift
