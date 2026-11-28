# #478: settings.json gates the Monitor tool with hooks/limit-shells.sh (and only that hook), and the Bash
# matcher keeps every hook it had.

HERE_478=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SETTINGS_478="$(cd "$HERE_478/../../.." && pwd)/settings.json"

l478_commands() {  # l478_commands <tool name> — hook commands of every PreToolUse entry whose matcher matches the tool, one per line
  python3 - "$SETTINGS_478" "$1" <<'PY'
import json, re, sys
s = json.load(open(sys.argv[1]))
for e in s["hooks"]["PreToolUse"]:
    if re.fullmatch(e.get("matcher", ""), sys.argv[2]):
        for h in e["hooks"]:
            print(h["command"])
PY
}

test_monitor_calls_run_only_limit_shells() {
  local cmds
  cmds=$(l478_commands Monitor)
  assert_eq "$cmds" "~/.claude/hooks/limit-shells.sh" "Monitor PreToolUse hooks" || return 1
}

test_bash_calls_keep_every_hook() {
  local cmds
  cmds=$(l478_commands Bash)
  assert_contains "$cmds" "Dangerous command detected" "dangerous-command guard" || return 1
  assert_contains "$cmds" "~/.claude/hooks/limit-shells.sh" "limit-shells" || return 1
  assert_contains "$cmds" "~/.claude/hooks/enforce-tests-before-commit.sh" "enforce-tests-before-commit" || return 1
  assert_contains "$cmds" "~/.claude/hooks/email-send-guard.sh" "email-send-guard" || return 1
}

run_test test_monitor_calls_run_only_limit_shells
run_test test_bash_calls_keep_every_hook
