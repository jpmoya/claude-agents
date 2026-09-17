# AC6 — with STATUS_PUSH_URL or STATUS_PUSH_TOKEN unset in config.local.sh, the reporter exits 0
# silently and makes no network call.

HERE_AC6=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC6="$HERE_AC6/.."
FAKEBIN_AC6="$HERE_AC6/bin"

# fake curl that proves it was invoked (touches a marker) if it ever runs, so "no network call"
# is asserted positively rather than by absence of a side effect that would never occur anyway.
write_fake_curl() {
  local dir=$1 marker=$2
  cat > "$dir/curl" <<EOF
#!/bin/bash
touch "$marker"
echo '{"fake":"curl should never have been invoked"}'
exit 0
EOF
  chmod +x "$dir/curl"
}

run_reporter_case() {  # run_reporter_case <pipe> <home> <curl_marker> -> prints stdout+stderr, returns the reporter's exit code
  local pipe=$1 home=$2 marker=$3 bindir rc
  bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  write_fake_curl "$bindir" "$marker"
  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" PATH="$bindir:/usr/bin:/bin" "$RS_AC6/report-status.sh" event )
  rc=$?
  rm -rf "$bindir"
  return "$rc"
}

test_ac6_url_unset_exits_0_silently_no_network() {
  local pipe home marker out rc
  pipe=$(new_pipe); home=$(new_home)
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_TOKEN="fake-token-value"
# STATUS_PUSH_URL intentionally unset
EOF
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-invoked.XXXXXX")
  out=$(run_reporter_case "$pipe" "$home" "$marker" 2>&1); rc=$?
  local curl_ran=absent; [ -e "$marker" ] && curl_ran=present
  rm -rf "$pipe" "$home"; rm -f "$marker"

  assert_exit0 "$rc" "AC6: STATUS_PUSH_URL unset -> exit 0" || return 1
  assert_eq "$out" "" "AC6: STATUS_PUSH_URL unset -> silent (no stdout/stderr)" || return 1
  assert_eq "$curl_ran" "absent" "AC6: STATUS_PUSH_URL unset -> curl never invoked" || return 1
}

test_ac6_token_unset_exits_0_silently_no_network() {
  local pipe home marker out rc
  pipe=$(new_pipe); home=$(new_home)
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
# STATUS_PUSH_TOKEN intentionally unset
EOF
  marker=$(mktemp -u "${TMPDIR:-/tmp}/orch-curl-invoked.XXXXXX")
  out=$(run_reporter_case "$pipe" "$home" "$marker" 2>&1); rc=$?
  local curl_ran=absent; [ -e "$marker" ] && curl_ran=present
  rm -rf "$pipe" "$home"; rm -f "$marker"

  assert_exit0 "$rc" "AC6: STATUS_PUSH_TOKEN unset -> exit 0" || return 1
  assert_eq "$out" "" "AC6: STATUS_PUSH_TOKEN unset -> silent (no stdout/stderr)" || return 1
  assert_eq "$curl_ran" "absent" "AC6: STATUS_PUSH_TOKEN unset -> curl never invoked" || return 1
}

run_test test_ac6_url_unset_exits_0_silently_no_network
run_test test_ac6_token_unset_exits_0_silently_no_network
