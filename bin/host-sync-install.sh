#!/bin/bash
# Install the host-sync schedules on THIS machine (idempotent). docs/host-sync.md.
#   bin/host-sync-install.sh
# Mac: two launchd agents (com.jp.host-drift daily 09:05 with --fix --alert; com.jp.memory-sync hourly).
# VM : two cron lines. Neither touches the supervisor schedule. The memory job no-ops until MEMORY_REMOTE is set.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; HOMEDIR="$HOME"; LOGS="$HOME/logs/pipeline"; mkdir -p "$LOGS" "$HOME/.claude/pipeline"
CONF="$HOME/.claude/pipeline/memory-sync.conf"
[ -f "$CONF" ] || cat > "$CONF" <<'C'
# Memory sync storage backend (docs/host-sync.md). ONE value. Unset = memory sync does nothing.
# A private git remote only, e.g. git@github.com:jpmoya/<private-repo>.git  (JP decides where private memory lives and who can read it)
MEMORY_REMOTE=
# MEMORY_STORE=$HOME/.claude/memory-store
C
PATHV="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ "$(uname)" = Darwin ]; then
  mk() { # label, minute/hour spec (xml), program args...
    local label=$1 sched=$2; shift 2; local plist="$HOME/Library/LaunchAgents/$label.plist" args=""
    for a in "$@"; do args="$args<string>$a</string>"; done
    cat > "$plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array>$args</array>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$HOMEDIR</string><key>PATH</key><string>$PATHV</string></dict>
<key>StartCalendarInterval</key>$sched
<key>StandardOutPath</key><string>$LOGS/$label.log</string><key>StandardErrorPath</key><string>$LOGS/$label.log</string>
</dict></plist>
P
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; launchctl bootstrap "gui/$(id -u)" "$plist" && echo "  ok   $label"
  }
  mk com.jp.host-drift '<dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>5</integer></dict>' /usr/bin/python3 "$REPO/bin/host-drift.py" --fix --alert
  mk com.jp.memory-sync '<dict><key>Minute</key><integer>17</integer></dict>' /usr/bin/python3 "$REPO/bin/memory-sync.py"
else
  tmp=$(mktemp); crontab -l 2>/dev/null | grep -v 'host-drift.py\|memory-sync.py' > "$tmp"
  {
    echo "PATH=$PATHV"
    echo "5 13 * * * python3 $REPO/bin/host-drift.py --fix --alert >> $LOGS/host-drift.log 2>&1   # host-sync, daily"
    echo "47 * * * * python3 $REPO/bin/memory-sync.py >> $LOGS/memory-sync.log 2>&1   # host-sync, hourly (no-op until MEMORY_REMOTE set)"
  } >> "$tmp"
  # cron-wide PATH= must not clobber other jobs: only add if no PATH line exists yet
  if crontab -l 2>/dev/null | grep -q '^PATH='; then grep -v "^PATH=$PATHV\$" "$tmp" > "$tmp.2"; mv "$tmp.2" "$tmp"; fi
  crontab "$tmp" && echo "  ok   cron lines installed"; rm -f "$tmp"
fi
