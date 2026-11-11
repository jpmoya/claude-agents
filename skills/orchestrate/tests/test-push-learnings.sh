# push-learnings.sh — the Learnings tab's Mac-side push script. Same AC6-style fail-quiet rule as
# report-status.sh: a host that hasn't set STATUS_PUSH_URL/STATUS_PUSH_TOKEN yet, or whose
# learnings file doesn't exist, never makes a network call. When both are set, it posts the
# file's raw bytes to the URL derived from STATUS_PUSH_URL ("…/beat" -> "…/learnings/push") with
# the bearer token.

HERE_PL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PL_SCRIPT="$HERE_PL/../push-learnings.sh"

# fake curl that records every argument it was called with (one per line) and touches a marker,
# so "no network call" is asserted positively and a real call's URL/headers/body are inspectable.
write_fake_curl_pl() {
  local dir=$1 marker=$2 argsfile=$3
  cat > "$dir/curl" <<EOF
#!/bin/bash
touch "$marker"
printf '%s\n' "\$@" > "$argsfile"
exit 0
EOF
  chmod +x "$dir/curl"
}

run_push_learnings_case() {  # <home> <marker> <argsfile> <file> -> stdout+stderr, returns exit code
  local home=$1 marker=$2 argsfile=$3 file=$4 bindir rc
  bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  write_fake_curl_pl "$bindir" "$marker" "$argsfile"
  ( HOME="$home" PATH="$bindir:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" "$PL_SCRIPT" "$file" )
  rc=$?
  rm -rf "$bindir"
  return "$rc"
}

test_push_learnings_config_unset_is_silent_noop() {
  local home marker argsfile file out rc
  home=$(new_home); mkdir -p "$home/.claude/pipeline" "$home/.claude/agents"
  file="$home/.claude/agents/message-triage-learnings.md"
  printf '%s\n' '- a lesson' > "$file"
  # no config.local.sh at all -> STATUS_PUSH_URL/TOKEN unset
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-invoked.XXXXXX")
  argsfile=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-args.XXXXXX")
  out=$(run_push_learnings_case "$home" "$marker" "$argsfile" "$file" 2>&1); rc=$?
  local curl_ran=absent; [ -e "$marker" ] && curl_ran=present
  rm -rf "$home"; rm -f "$marker" "$argsfile"

  assert_exit0 "$rc" "push-learnings: config unset -> exit 0" || return 1
  assert_eq "$out" "" "push-learnings: config unset -> silent (no stdout/stderr)" || return 1
  assert_eq "$curl_ran" "absent" "push-learnings: config unset -> curl never invoked" || return 1
}

test_push_learnings_missing_file_is_silent_noop() {
  local home marker argsfile file out rc
  home=$(new_home); mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-value"
EOF
  file="$home/.claude/agents/message-triage-learnings.md"   # intentionally not created
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-invoked.XXXXXX")
  argsfile=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-args.XXXXXX")
  out=$(run_push_learnings_case "$home" "$marker" "$argsfile" "$file" 2>&1); rc=$?
  local curl_ran=absent; [ -e "$marker" ] && curl_ran=present
  rm -rf "$home"; rm -f "$marker" "$argsfile"

  assert_exit0 "$rc" "push-learnings: missing file -> exit 0" || return 1
  assert_eq "$curl_ran" "absent" "push-learnings: missing file -> curl never invoked" || return 1
}

test_push_learnings_configured_posts_derived_url_and_body() {
  local home marker argsfile file out rc args
  home=$(new_home); mkdir -p "$home/.claude/pipeline" "$home/.claude/agents"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-value"
EOF
  file="$home/.claude/agents/message-triage-learnings.md"
  printf '%s\n' '- a lesson' '- another lesson' > "$file"
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-invoked.XXXXXX")
  argsfile=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-args.XXXXXX")
  out=$(run_push_learnings_case "$home" "$marker" "$argsfile" "$file" 2>&1); rc=$?
  local curl_ran=absent; [ -e "$marker" ] && curl_ran=present
  args=$(cat "$argsfile" 2>/dev/null)
  rm -rf "$home"; rm -f "$marker" "$argsfile"

  assert_exit0 "$rc" "push-learnings: configured -> exit 0" || return 1
  assert_eq "$curl_ran" "present" "push-learnings: configured -> curl invoked" || return 1
  assert_contains "$args" "https://example.invalid/learnings/push" "push-learnings: posts to the derived /learnings/push URL" || return 1
  assert_contains "$args" "Authorization: Bearer fake-token-value" "push-learnings: carries the bearer token" || return 1
  assert_contains "$args" "$file" "push-learnings: --data-binary reads the learnings file" || return 1
}

run_test test_push_learnings_config_unset_is_silent_noop
run_test test_push_learnings_missing_file_is_silent_noop
run_test test_push_learnings_configured_posts_derived_url_and_body
