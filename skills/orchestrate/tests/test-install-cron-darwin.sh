# #408 — install.sh must not write the supervisor cron line on Darwin (launchd runs it there);
# Linux behaviour unchanged. Stub uname/crontab first on PATH; HOME is a temp dir.

INSTALL_408="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"

setup_408() {  # setup_408 <Darwin|Linux> [seed-crontab-text]
  T408=$(mktemp -d "${TMPDIR:-/tmp}/inst408.XXXXXX")
  mkdir -p "$T408/bin" "$T408/home"
  printf '#!/bin/sh\necho %s\n' "$1" > "$T408/bin/uname"
  cat > "$T408/bin/crontab" <<'STUB'
#!/bin/sh
F="$T408/cron.txt"
if [ "$1" = "-l" ]; then [ -f "$F" ] && cat "$F"; exit 0; fi
cat > "$F"; echo x >> "$T408/writes"
STUB
  chmod +x "$T408/bin/uname" "$T408/bin/crontab"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$T408/cron.txt"
  return 0
}
run_408() {  # run_408 [install args...] — sets OUT408, RC408
  OUT408=$(env HOME="$T408/home" T408="$T408" PATH="$T408/bin:$PATH" bash "$INSTALL_408" "$@" 2>&1); RC408=$?
}
writes_408() { [ -f "$T408/writes" ] && wc -l < "$T408/writes" | tr -d ' ' || echo 0; }
sup_count_408() { grep -c 'orchestrate/supervisor\.sh' "$T408/cron.txt" || true; }

test_408_darwin_strips_supervisor_line() {
  setup_408 Darwin '1-59/2 * * * * /x/.claude/skills/orchestrate/supervisor.sh >> /x/s.log 2>&1'
  run_408 --minute odd
  assert_eq "$(sup_count_408)" 0 "supervisor lines" || return 1
  assert_contains "$(cat "$T408/cron.txt")" "orchestrate/session-backfill.sh" "backfill" || return 1
  assert_contains "$(cat "$T408/cron.txt")" "orchestrate/rotate-logs.sh" "rotate" || return 1
  assert_contains "$OUT408" "com.jp.pipeline-supervisor" "launchd line"
}
test_408_darwin_idempotent() {
  setup_408 Darwin
  run_408 --minute odd; run_408 --minute odd
  assert_contains "$OUT408" "crontab already correct" "second run" || return 1
  assert_eq "$(writes_408)" 1 "crontab writes"
}
test_408_darwin_exact_supervisor_line_is_stripped() {
  setup_408 Darwin
  run_408 --minute odd
  printf '%s\n' "1-59/2 * * * * $T408/home/.claude/skills/orchestrate/supervisor.sh >> $T408/home/logs/pipeline/supervisor.log 2>&1" >> "$T408/cron.txt"
  run_408 --minute odd
  assert_eq "$(sup_count_408)" 0 "supervisor lines" || return 1
  assert_contains "$OUT408" "crontab updated" "rewrote"
}
test_408_darwin_missing_plist_warns_exit0() {
  setup_408 Darwin
  run_408 --minute odd
  assert_eq "$RC408" 0 "exit" || return 1
  assert_contains "$OUT408" "com.jp.pipeline-supervisor" "warning" || return 1
  [ ! -e "$T408/home/Library/LaunchAgents/com.jp.pipeline-supervisor.plist" ] || fail "plist created"
}
test_408_linux_writes_supervisor_line_and_idempotent() {
  setup_408 Linux
  run_408 --minute odd
  assert_contains "$(cat "$T408/cron.txt")" "1-59/2 * * * * $T408/home/.claude/skills/orchestrate/supervisor.sh" "odd" || return 1
  run_408 --minute odd
  assert_contains "$OUT408" "crontab already correct" "second run" || return 1
  assert_eq "$(writes_408)" 1 "writes" || return 1
  setup_408 Linux; run_408 --minute even
  assert_contains "$(cat "$T408/cron.txt")" "*/2 * * * * $T408/home/.claude/skills/orchestrate/supervisor.sh" "even"
}
test_408_scan_line_both_os() {
  setup_408 Darwin; run_408 --minute odd --scan
  assert_contains "$(cat "$T408/cron.txt")" "orchestrate/scan-backlog.sh" "darwin scan" || return 1
  setup_408 Linux; run_408 --minute odd --scan
  assert_contains "$(cat "$T408/cron.txt")" "orchestrate/scan-backlog.sh" "linux scan"
}

run_test test_408_darwin_strips_supervisor_line
run_test test_408_darwin_idempotent
run_test test_408_darwin_missing_plist_warns_exit0
run_test test_408_linux_writes_supervisor_line_and_idempotent
run_test test_408_scan_line_both_os
run_test test_408_darwin_exact_supervisor_line_is_stripped
