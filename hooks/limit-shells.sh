#!/bin/bash
# Limits concurrent Claude Code background shells.
# Per-session cap (5) prevents any single session from hogging resources.
# Global cap (20) prevents runaway accumulation across concurrent orchestrators.
# Kills any shell that has been running longer than 10 minutes.

MAX_PER_SESSION=5
MAX_GLOBAL=20
MAX_AGE_SECONDS=600

# Kill stale shells (older than MAX_AGE_SECONDS). Only real Claude Code tool shells are selected
# (#720): argv is "<path>/<shell> -c source …/.claude/shell-snapshots/snapshot-…". Never a pipeline
# stage (`claude --agent … -p "…bash…"`) or its stage-run.sh wrapper, whose command line merely
# mentions claude and bash.
TOOL_SHELL_AGE_RE='^([^ ]*/)?(zsh|bash|sh) -c ([-][a-zA-Z]+ )*source [^ ]*/[.]claude/shell-snapshots/snapshot-'
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $1}')
  elapsed=$(echo "$line" | awk '{print $2}')
  if [ "$elapsed" -gt "$MAX_AGE_SECONDS" ] 2>/dev/null; then
    kill "$pid" 2>/dev/null
  fi
done < <(ps -axo pid=,etime=,command= 2>/dev/null | grep -v "limit-shells" | RE="$TOOL_SHELL_AGE_RE" awk '
  # etime ([[dd-]hh:]mm:ss) exists on macOS and Linux; etimes (plain seconds) is Linux-only.
  { c = $0; sub(/^ *[0-9]+ +[^ ]+ +/, "", c)
    if (c !~ ENVIRON["RE"]) next
    e = $2; d = 0
    if (e ~ /-/) { split(e, dp, "-"); d = dp[1]; e = dp[2] }
    n = split(e, t, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + t[i]
    print $1, s + d * 86400 }')

# Global cap — all Claude sessions combined
global_count=$(ps -eo pid,command 2>/dev/null | grep -E "[/]tmp/claude-" | grep -v grep | grep -v "limit-shells" | wc -l | tr -d ' ')

if [ "$global_count" -ge "$MAX_GLOBAL" ]; then
  echo "BLOCKED: $global_count background shells globally (max $MAX_GLOBAL). Kill stale orchestrators or wait." >&2
  exit 2
fi

# Per-session cap — only real tool shells of this session's claude CLI (#729).
# A tool shell is "<shell> -c source …/.claude/shell-snapshots/snapshot-…" whose parent is the CLI.
# Not counted: the app's --resume processes, detached scripts, children and forked subshells of a
# tool shell (their parent is a shell, not the CLI). Main session and Agent-tool helpers share the
# CLI process, so they share this one budget. The CLI is the nearest claude ancestor of this hook
# (falling back to $CLAUDE_PID only when that really is an ancestor: a nested `claude -p` stage inherits
# its parent CLI's CLAUDE_PID, so the env var alone could name the wrong CLI). Only `ps -axo pid=,ppid=,command=` is used
# (valid on macOS and Linux; macOS ps has no etimes).
TOOL_SHELL_RE='(^|/)(zsh|bash|sh) -c ([-][a-zA-Z]+ )*source [^ ]*/[.]claude/shell-snapshots/snapshot-'
session_count=$(RE="$TOOL_SHELL_RE" CLI="${CLAUDE_PID:-}" SID="${CLAUDE_CODE_SESSION_ID:-}" START="$PPID" \
  awk '
    { p = $1; c = $0; sub(/^ *[0-9]+ +[0-9]+ */, "", c); par[p] = $2; cmd[p] = c; pids[n++] = p }
    END {
      re = ENVIRON["RE"]; sid = ENVIRON["SID"]
      want = ENVIRON["CLI"]; cli = ""; env_hit = 0
      p = ENVIRON["START"]
      for (d = 0; p != "" && p + 0 > 1 && d < 30; d++) {
        if (p in cmd) {
          if (cmd[p] ~ /(^|\/)claude( |$)/ || (sid != "" && index(cmd[p], sid))) { cli = p; break }
          if (want != "" && p == want) env_hit = 1
        }
        p = par[p]
      }
      if (cli == "" && env_hit) cli = want
      if (cli == "") { print -1; exit }
      k = 0
      for (i = 0; i < n; i++) { p = pids[i]; if (par[p] == cli && cmd[p] ~ re) k++ }
      print k
    }' <<< "$(ps -axo pid=,ppid=,command= 2>/dev/null)")
# -1 = CLI not found: fail open (this is a resource guard, not a security check).
if [ "${session_count:--1}" -ge "$MAX_PER_SESSION" ] 2>/dev/null; then
  echo "BLOCKED: $session_count shells in this session (max $MAX_PER_SESSION). Wait for existing commands to finish." >&2
  exit 2
fi

exit 0
