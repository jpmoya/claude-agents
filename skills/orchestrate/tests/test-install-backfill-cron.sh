# Issue #135 AC12/AC13 — install.sh installs the daily session-backfill cron entry (idempotent), plus
# settings.json cleanupPeriodDays and the README paragraph. install.sh is executed ONLY inside an isolated
# HOME with a stub `crontab` first on PATH; the test hard-stops if `crontab` does not resolve to the stub.

HERE_IC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_IC=$(cd "$HERE_IC/../../.." && pwd)

ic_setup() {  # sets IC_HOME, IC_TAB
  IC_HOME=$(new_home)
  mkdir -p "$IC_HOME/.local/bin"
  IC_TAB="$IC_HOME/crontab.table"
  printf '0 14 * * 1 /usr/bin/true\n' > "$IC_TAB"
  cat > "$IC_HOME/.local/bin/crontab" <<EOS
#!/bin/bash
T="$IC_TAB"
case "\$1" in -l) [ -f "\$T" ] && cat "\$T"; exit 0 ;; -) cat > "\$T"; exit 0 ;; *) exit 1 ;; esac
EOS
  local t
  for t in gh claude vercel; do printf '#!/bin/bash\nexit 0\n' > "$IC_HOME/.local/bin/$t"; done
  chmod +x "$IC_HOME/.local/bin/"*
}

# ic_install <args...> — runs the repo's install.sh under the fake HOME. Hard stop unless crontab is the stub.
ic_install() {
  local resolved
  resolved=$(HOME="$IC_HOME" PATH="$IC_HOME/.local/bin:$PATH" bash -c 'command -v crontab')
  if [ "$resolved" != "$IC_HOME/.local/bin/crontab" ]; then
    echo "REFUSING to run install.sh: crontab resolves to [$resolved], not the stub" >&2
    return 99
  fi
  HOME="$IC_HOME" PATH="$IC_HOME/.local/bin:$PATH" "$ROOT_IC/skills/orchestrate/install.sh" "$@" >"$IC_HOME/install.out" 2>&1
}

test_ic_ac12_install_twice_one_backfill_line_and_one_supervisor_line() {
  ic_setup
  local r=0
  ic_install --minute even; local rc1=$?
  [ "$rc1" -ne 99 ] || { fail "AC12: refused to run (crontab not stubbed)"; rm -rf "$IC_HOME"; return 1; }
  ic_install --minute even
  local tab; tab=$(cat "$IC_TAB")
  assert_eq "$(printf '%s\n' "$tab" | grep -c 'orchestrate/session-backfill\.sh')" "1" "AC12 exactly one backfill line after two runs" || r=1
  assert_eq "$(printf '%s\n' "$tab" | grep -c 'orchestrate/supervisor\.sh')" "1" "AC12 exactly one supervisor line" || r=1
  assert_contains "$tab" "0 14 * * 1 /usr/bin/true" "AC12 unrelated seeded line kept" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_ic_ac12_backfill_line_exact_without_scan() {
  ic_setup
  ic_install --minute odd; local rc=$?
  [ "$rc" -ne 99 ] || { fail "AC12: refused to run (crontab not stubbed)"; rm -rf "$IC_HOME"; return 1; }
  local tab r=0; tab=$(cat "$IC_TAB")
  assert_contains "$tab" "23 13 * * * $IC_HOME/.claude/skills/orchestrate/session-backfill.sh >> $IC_HOME/logs/pipeline/session-backfill.log 2>&1" "AC12 daily 13:23 line, present without --scan" || r=1
  assert_contains "$tab" "# Agent pipeline session backfill (installed by claude-agents install.sh)" "AC12 comment header" || r=1
  assert_not_contains "$tab" "scan-backlog.sh" "no scan line without --scan" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_ic_ac12_rerun_with_scan_keeps_all_three_once() {
  ic_setup
  ic_install --minute even --scan; local rc=$?
  [ "$rc" -ne 99 ] || { fail "AC12: refused to run (crontab not stubbed)"; rm -rf "$IC_HOME"; return 1; }
  ic_install --minute even --scan
  local tab r=0; tab=$(cat "$IC_TAB")
  assert_eq "$(printf '%s\n' "$tab" | grep -c 'orchestrate/session-backfill\.sh')" "1" "one backfill line" || r=1
  assert_eq "$(printf '%s\n' "$tab" | grep -c 'scan-backlog\.sh')" "1" "one scan line" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_ic_ac12_stale_duplicate_backfill_lines_collapse_to_one() {
  ic_setup
  printf '0 14 * * 1 /usr/bin/true\n1 1 * * * /old/path/orchestrate/session-backfill.sh >> /x 2>&1\n2 2 * * * /older/orchestrate/session-backfill.sh\n' > "$IC_TAB"
  ic_install --minute even; local rc=$?
  [ "$rc" -ne 99 ] || { fail "AC12: refused to run (crontab not stubbed)"; rm -rf "$IC_HOME"; return 1; }
  local tab r=0; tab=$(cat "$IC_TAB")
  assert_eq "$(printf '%s\n' "$tab" | grep -c 'orchestrate/session-backfill\.sh')" "1" "old copies removed, one left" || r=1
  assert_not_contains "$tab" "/old/path" "old entry gone" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_ic_ac13_settings_json_has_cleanup_period_and_is_valid_json() {
  local r=0
  assert_eq "$(grep -c '"cleanupPeriodDays": 180' "$ROOT_IC/settings.json")" "1" "AC13 one cleanupPeriodDays line" || r=1
  python3 -m json.tool "$ROOT_IC/settings.json" >/dev/null 2>&1 || { fail "AC13 settings.json is not valid JSON"; r=1; }
  assert_eq "$(python3 -c "import json;print(json.load(open('$ROOT_IC/settings.json')).get('cleanupPeriodDays'))" 2>/dev/null)" "180" "AC13 top-level value 180" || r=1
  assert_eq "$(python3 -c "import json;print(list(json.load(open('$ROOT_IC/settings.json')))[1])" 2>/dev/null)" "cleanupPeriodDays" "AC13 second key in the file" || r=1
  return $r
}

test_ic_ac13_readme_paragraph() {
  local r=0 rd="$ROOT_IC/README.md"
  assert_ne "$(grep -c 'Pipeline logging (issue #134)' "$rd")" "0" "AC13 README heading" || r=1
  assert_ne "$(grep -c 'session-backfill\.sh' "$rd")" "0" "AC13 README names backfill script" || r=1
  assert_ne "$(grep -c 'pipeline-report\.sh' "$rd")" "0" "AC13 README names report script" || r=1
  assert_ne "$(grep -c 'sessions\.jsonl' "$rd")" "0" "AC13 README names sessions.jsonl" || r=1
  assert_ne "$(grep -c 'cleanupPeriodDays' "$rd")" "0" "AC13 README names cleanupPeriodDays" || r=1
  assert_ne "$(grep -c -e '--sessions' "$rd")" "0" "AC13 README explains merging hosts" || r=1
  return $r
}

for t in test_ic_ac12_install_twice_one_backfill_line_and_one_supervisor_line test_ic_ac12_backfill_line_exact_without_scan \
  test_ic_ac12_rerun_with_scan_keeps_all_three_once test_ic_ac12_stale_duplicate_backfill_lines_collapse_to_one \
  test_ic_ac13_settings_json_has_cleanup_period_and_is_valid_json test_ic_ac13_readme_paragraph; do
  run_test "$t"
done
