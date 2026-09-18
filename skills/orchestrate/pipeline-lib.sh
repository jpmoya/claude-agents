#!/bin/bash
# Shared launcher helpers (issue #8), sourced by orchestrate.sh and supervisor.sh right after config.sh.
# Reads $PIPE, $MAX_CONCURRENT and $MEM_FLOOR_MB at call time, so it does not source config.sh itself.
# marker_last_jq needs marker_re from hooks/pipeline-markers.sh, which both launchers also source.
SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid; do
    [ -e "$f" ] || break
    kill -0 "$(cat "$f")" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

mem_available_mb() {
  if [ -r /proc/meminfo ]; then awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo
  else vm_stat 2>/dev/null | awk '/page size of/ {ps=$8} /Pages free|Pages inactive|Pages speculative/ {gsub(/\./,"",$NF); p+=$NF} END {print int(p*ps/1048576)}'
  fi
}

has_capacity() {
  [ "$(count_running)" -lt "$MAX_CONCURRENT" ] && [ "$(mem_available_mb)" -ge "$MEM_FLOOR_MB" ]
}

marker_last_jq() {  # prints (no gh call) the jq expression yielding the newest real routing marker first line, or "none"; NOTEs and off-vocabulary lines are inert
  printf '[.comments[] | .body | split("\\n")[0] | select(test(%s))] | last // "none"' "$(marker_re | jq -Rs .)"
}
