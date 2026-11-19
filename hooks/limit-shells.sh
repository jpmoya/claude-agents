#!/bin/bash
# Limits concurrent Claude Code background shells.
# Per-session cap (5) prevents any single session from hogging resources.
# Global cap (20) prevents runaway accumulation across concurrent orchestrators.
# Kills any shell that has been running longer than 10 minutes.

MAX_PER_SESSION=5
MAX_GLOBAL=20
MAX_AGE_SECONDS=600

# Kill stale shells (older than MAX_AGE_SECONDS)
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $1}')
  elapsed=$(echo "$line" | awk '{print $2}')
  if [ "$elapsed" -gt "$MAX_AGE_SECONDS" ] 2>/dev/null; then
    kill "$pid" 2>/dev/null
  fi
done < <(ps -eo pid,etimes,command 2>/dev/null | grep -E "claude.*bash|claude.*Bash" | grep -v grep | grep -v "limit-shells" | awk '{print $1, $2}')

# What counts as a shell (#803, #729): only a real tool shell, i.e. "<shell> -c source …/.claude/shell-snapshots/snapshot-…",
# whose parent is a claude CLI. Not counted: the app's --resume processes, scripts started from a scratchpad, forked subshells of a
# tool shell (their parent is a shell, not the CLI), orphans (ppid 1), zombies (stat Z) and stale shells (running longer than
# LIMIT_SHELLS_STALE_SECONDS: a leaked or long-finished run is not fan-out; 0 disables the bound). One `ps` snapshot feeds both caps
# (`ps -axo pid=,ppid=,stat=,etime=,command=` is valid on macOS and Linux; macOS ps has no etimes).
# Caps and the stale bound are configurable via LIMIT_SHELLS_MAX_PER_SESSION, LIMIT_SHELLS_MAX_GLOBAL, LIMIT_SHELLS_STALE_SECONDS.
# Stale shells are exempt from the caps above, but a separate ceiling counts them too: LIMIT_SHELLS_MAX_TOTAL (default 40) blocks when
# all tool shells of all CLIs, stale included, reach it, and names the stale pids to reap (nothing is killed automatically).
# This is a resource guard, not a security check: when the count cannot be decided it fails open (exit 0) and logs one line.
TOOL_SHELL_RE='(^|/)(zsh|bash|sh) -c ([-][a-zA-Z]+ )*source [^ ]*/[.]claude/shell-snapshots/snapshot-'
LOG="${LIMIT_SHELLS_LOG:-$HOME/logs/pipeline/limit-shells.log}"
log_once() {   # log_once <key> <message>: one line per key per 10 minutes (the hook runs before every Bash call)
  local mark="$LOG.$1"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  [ -n "$(find "$mark" -mmin -10 2>/dev/null)" ] && return 0
  printf '%s limit-shells: %s\n' "$(date -u +%FT%TZ 2>/dev/null)" "$2" >> "$LOG" 2>/dev/null
  : > "$mark" 2>/dev/null
  return 0
}
fail_open() { log_once failopen "fail-open: $1"; exit 0; }
num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
MAX_PER_SESSION=$(num "${LIMIT_SHELLS_MAX_PER_SESSION:-}" "$MAX_PER_SESSION")
MAX_GLOBAL=$(num "${LIMIT_SHELLS_MAX_GLOBAL:-}" "$MAX_GLOBAL")
STALE=$(num "${LIMIT_SHELLS_STALE_SECONDS:-}" 1800)
MAX_TOTAL=$(num "${LIMIT_SHELLS_MAX_TOTAL:-}" 40)

# The CLI of this session is the nearest claude ancestor of this hook (falling back to $CLAUDE_PID only when that really is an
# ancestor: a nested `claude -p` stage inherits its parent CLI's CLAUDE_PID, so the env var alone could name the wrong CLI).
# Main session and Agent-tool helpers share the CLI process, so they share the per-session budget.
PS_TABLE=$(ps -axo pid=,ppid=,stat=,etime=,command= 2>/dev/null)
[ -n "$PS_TABLE" ] || fail_open "ps returned no process table"
counts=$(RE="$TOOL_SHELL_RE" CLI="${CLAUDE_PID:-}" SID="${CLAUDE_CODE_SESSION_ID:-}" START="$PPID" STALE="$STALE" \
  awk '
    function secs(e,   d, t, n, a) {   # [[dd-]hh:]mm:ss -> seconds (-1 if unparseable)
      d = 0
      if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
      n = split(e, t, ":")
      if (n == 3) return d * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
      if (n == 2) return d * 86400 + t[1] * 60 + t[2]
      return -1
    }
    {
      p = $1; par[p] = $2; st[p] = $3; el[p] = $4
      c = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +[^ ]+ */, "", c)
      cmd[p] = c; pids[n++] = p
    }
    END {
      re = ENVIRON["RE"]; sid = ENVIRON["SID"]; stale = ENVIRON["STALE"] + 0
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
      k = 0; g = 0; t = 0; sn = 0; sl = ""; loose = 0
      for (i = 0; i < n; i++) {
        p = pids[i]
        if (cmd[p] !~ re || st[p] ~ /^Z/) continue
        q = par[p]
        if (q in cmd && cmd[q] ~ /(^|\/)claude( |$)/ && cmd[q] !~ re) t++; else loose++
        if (stale > 0 && (s = secs(el[p])) > stale) {
          if (q in cmd && cmd[q] ~ /(^|\/)claude( |$)/ && cmd[q] !~ re) { sn++; sl = sl (sl == "" ? "" : ",") p }
          continue
        }
        if (q in cmd && cmd[q] ~ /(^|\/)claude( |$)/ && cmd[q] !~ re) g++
        if (cli != "" && q == cli) k++
      }
      print (cli == "" ? -1 : k), g, t, sn, (sl == "" ? "-" : sl), loose
    }' <<< "$PS_TABLE")
read -r session_count global_count total_count stale_count stale_pids loose_count <<< "$counts"
case "$session_count$global_count$total_count$stale_count$loose_count" in ''|*[!0-9-]*) fail_open "could not parse process table (got: $counts)" ;; esac
[ "$global_count" -eq 0 ] && [ "$total_count" -eq 0 ] && [ "$loose_count" -gt 0 ] && \
  log_once noparent "global count is 0 but $loose_count tool shells exist and none has a claude CLI parent (process table format changed?)"

# Ceiling: every tool shell of every CLI, stale included. Stale shells are exempt from the caps below, never from this.
if [ "$total_count" -ge "$MAX_TOTAL" ] 2>/dev/null; then
  hint="Wait for existing commands to finish."
  [ "$stale_count" -gt 0 ] && hint="Reap the stale ones yourself if they are leaked: kill ${stale_pids//,/ }"
  echo "BLOCKED: $total_count shells in total ($stale_count stale, running > ${STALE}s; max $MAX_TOTAL). $hint" >&2
  exit 2
fi

# Global cap: tool shells of every claude CLI combined.
if [ "$global_count" -ge "$MAX_GLOBAL" ] 2>/dev/null; then
  echo "BLOCKED: $global_count background shells globally (max $MAX_GLOBAL). Kill stale orchestrators or wait." >&2
  exit 2
fi

# Per-session cap. -1 = this session's CLI not found: fail open and say so.
[ "$session_count" = "-1" ] && fail_open "claude CLI of this session not found in the parent chain (hook pid $$)"
if [ "$session_count" -ge "$MAX_PER_SESSION" ] 2>/dev/null; then
  echo "BLOCKED: $session_count shells in this session (max $MAX_PER_SESSION). Wait for existing commands to finish." >&2
  exit 2
fi

exit 0
