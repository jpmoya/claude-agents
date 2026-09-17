# AC5 — a repo absent from the alias map is published as "other"; a test runs the reporter
# against a fixture /tmp/pipeline-shaped tree (placeholder repo names only, e.g. project-a) and
# greps its output to assert no owner/repo string, real hostname, username, path, or pid appears
# anywhere. (The alias-mapping correctness itself is asserted in test-ac1-ac2-payload.sh; this
# file is the leak grep.)

HERE_AC5=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC5="$HERE_AC5/.."

test_ac5_print_output_leaks_nothing() {
  local pipe home repoA repoUnmapped out marker_hostname marker_user
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  repoUnmapped="$pipe/repo-unmapped"; fixture_repo "$repoUnmapped" "example-owner/some-unlisted-repo"
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_REPO_ALIASES=("example-owner/project-a:project-a")
EOF

  mk_running "$pipe" 501 "$repoA"
  mk_running "$pipe" 502 "$repoUnmapped"

  out=$( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$RS_AC5/report-status.sh" --print 2>&1 )
  local live_pid=""
  for p in $RUNNING_PIDS; do live_pid="$p"; done
  cleanup_running

  marker_hostname=$(hostname -s 2>/dev/null || echo "")
  marker_user=$(whoami 2>/dev/null || echo "")

  # Positive half first: the leak checks below are all "absence" assertions, trivially true of
  # empty/error output — require a real, non-empty payload to have actually been produced.
  if ! echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'runs' in d" >/dev/null 2>&1; then
    fail "AC5: report-status.sh --print must emit a valid v1 payload with a \"runs\" key — an error/no-op stub would make every leak check below vacuously true. Got: $out"
    rm -rf "$pipe" "$home"; return 1
  fi

  assert_not_contains "$out" "example-owner/project-a" "AC5: mapped owner/repo string never leaks (must publish as its alias)" || { rm -rf "$pipe" "$home"; return 1; }
  assert_not_contains "$out" "example-owner/some-unlisted-repo" "AC5: unmapped owner/repo string never leaks (must publish as \"other\")" || { rm -rf "$pipe" "$home"; return 1; }
  assert_not_contains "$out" "$pipe" "AC5: no tmp/pipeline path leaks" || { rm -rf "$pipe" "$home"; return 1; }
  assert_not_contains "$out" "$repoA" "AC5: no local checkout path leaks" || { rm -rf "$pipe" "$home"; return 1; }
  [ -n "$marker_hostname" ] && { assert_not_contains "$out" "$marker_hostname" "AC5: no real hostname leaks" || { rm -rf "$pipe" "$home"; return 1; }; }
  [ -n "$marker_user" ] && { assert_not_contains "$out" "$marker_user" "AC5: no real username leaks" || { rm -rf "$pipe" "$home"; return 1; }; }
  [ -n "$live_pid" ] && { assert_not_contains "$out" "$live_pid" "AC5: no raw pid leaks" || { rm -rf "$pipe" "$home"; return 1; }; }

  rm -rf "$pipe" "$home"
}

run_test test_ac5_print_output_leaks_nothing
