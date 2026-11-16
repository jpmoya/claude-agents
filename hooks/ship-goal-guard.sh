#!/bin/bash
# Stop hook: a session may not end its turn while a ship goal is open and unverified (JP, 2026-11-16: "ship to prod" was
# reported done from staging merges, nothing was on main). Goals live in ~/.claude/state/ship-goals/<name>.json, opened with
# `skills/orchestrate/ship-goal.sh start`. Exit 2 + a short stderr reason makes the session continue.
# Allowed to stop when: the last assistant message says it is blocked on a JP-only item; every open goal verifies (verify-shipped.sh
# exit 0, cached SGG_CACHE_SECS so a Stop does not hit the GitHub API every time); a goal is older than SGG_TTL_HOURS (stale,
# another session's); the same goal already blocked SGG_MAX_BLOCKS times in SGG_WINDOW_SECS (never an endless loop).
# Fails open (exit 0, logged to ~/logs/pipeline/ship-goal-guard.log) when the ledger tooling is missing or input is unparseable.
# Skipped for pipeline stage processes (PIPELINE_AGENT) and the headless orchestrator.
# Env (tests): SHIP_GOALS_DIR, SGG_SHIP_GOAL (ship-goal.sh path), SGG_NOW (epoch), SGG_CACHE_SECS, SGG_TTL_HOURS, SGG_MAX_BLOCKS, SGG_WINDOW_SECS.
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
DIR="${SHIP_GOALS_DIR:-$HOME/.claude/state/ship-goals}"
LOG="$HOME/logs/pipeline/ship-goal-guard.log"
CACHE_SECS="${SGG_CACHE_SECS:-120}"; TTL_H="${SGG_TTL_HOURS:-24}"; MAX_BLOCKS="${SGG_MAX_BLOCKS:-6}"; WINDOW="${SGG_WINDOW_SECS:-1800}"
NOW="${SGG_NOW:-$(date +%s)}"
# Narrow on purpose: only an explicit JP-only item lets a turn end. "the production deploy is still running" is NOT one (that is the incident).
JPONLY_RE='risky.list|safe route|destructive (db|database|migration)|JP.{0,12}(go|approv|decision|confirm)|needs_jp|AWAITING GO|mockup approv|prod(uction)? go|spend(ing)? money|third-party system|system of record|delet(e|ing) (the )?(data|prod)|external communication|private artefact|who gets access|infra(structure)? go|JP-only|JP only'
BLOCKED_RE='blocked|waiting (on|for) (JP|you)|need(s)? (JP|your)|awaiting (JP|your)'
mkdir -p "$(dirname "$LOG")" 2>/dev/null
elog() { printf '%s %s\n' "$(TZ=Europe/Madrid date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG" 2>/dev/null; }

main() {
  local IN T last f name started age lc rc ts summary recent msg="" blocked_names="" bin
  [ -d "$DIR" ] || return 0
  ls "$DIR"/*.json >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || { elog "fail-open: jq missing"; return 0; }
  IN=$(cat); T=$(printf '%s' "$IN" | jq -r '.transcript_path // empty' 2>/dev/null) || return 3
  if [ -n "$T" ] && [ -r "$T" ] && head -n 1 "$T" 2>/dev/null | jq -e '.agentSetting=="orchestrator"' >/dev/null 2>&1; then return 0; fi
  bin="${SGG_SHIP_GOAL:-$HOME/.claude/skills/orchestrate/ship-goal.sh}"
  [ -f "$bin" ] || { elog "fail-open: $bin missing"; return 0; }

  # JP-only escape: the last assistant message says it is blocked on a JP-only item.
  last=$(printf '%s' "$IN" | jq -r '.last_assistant_message // empty' 2>/dev/null)
  if [ -z "$last" ] && [ -n "$T" ] && [ -r "$T" ]; then
    last=$(tail -n 80 "$T" 2>/dev/null | jq -R -r 'fromjson? | select(.type=="assistant") | .message.content | if type=="string" then . else (map(select(.type=="text")|.text)|join(" ")) end | select(length>0)' 2>/dev/null | tail -n 1)
  fi
  if [ -n "$last" ] && printf '%s' "$last" | grep -Eqi "$BLOCKED_RE" && printf '%s' "$last" | grep -Eqi "$JPONLY_RE"; then
    elog "allowed: last message blocked on a JP-only item"; return 0
  fi

  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.status // empty' "$f" 2>/dev/null)" = open ] || continue
    name=$(jq -r .name "$f"); started=$(jq -r '.started // empty' "$f")
    age=$(jq -rn --arg s "$started" --argjson now "$NOW" '($s | fromdateiso8601? // $now) | ($now - .)' 2>/dev/null); age=${age:-0}
    if [ "$age" -gt $((TTL_H * 3600)) ] 2>/dev/null; then elog "skip $name: older than ${TTL_H}h"; continue; fi
    # block cap: never loop forever
    recent=$(jq -r --argjson now "$NOW" --argjson w "$WINDOW" '[(.blocks // [])[] | select($now - . < $w)] | length' "$f" 2>/dev/null); recent=${recent:-0}
    if [ "$recent" -ge "$MAX_BLOCKS" ]; then elog "allowed $name: already blocked $recent times in ${WINDOW}s"; continue; fi
    # verified? use the cached check while fresh, else run it
    ts=$(jq -r '.last_check.ts // 0' "$f"); rc=$(jq -r '.last_check.rc // 99' "$f")
    if [ $((NOW - ts)) -ge "$CACHE_SECS" ]; then   # a result younger than SGG_CACHE_SECS is reused (no API call per Stop)
      bash "$bin" check "$name" >/dev/null 2>&1
      rc=$(jq -r '.last_check.rc // 99' "$f")
    fi
    if [ "$rc" = 0 ]; then
      # verified: close it so it never blocks again
      jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "done" | .verified_at = $ts' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; rm -f "$f.tmp"
      elog "closed $name: verified on main"
      continue
    fi
    summary=$(jq -r '.last_check.summary // "not checked"' "$f")
    jq -c --argjson now "$NOW" --argjson w "$WINDOW" '.blocks = ([(.blocks // [])[] | select($now - . < $w)] + [$now])' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; rm -f "$f.tmp"
    msg="$msg
- ship goal '$name' ($(jq -r .repo "$f")): $summary"
    blocked_names="$blocked_names $name"
  done
  [ -n "$blocked_names" ] || return 0
  printf 'You may not stop: not live on prod yet.%s\nNot done until skills/orchestrate/verify-shipped.sh exits 0 (files on origin/main + green prod deploy). Build the promotion PR yourself, dispatch every independent job now, then run: ship-goal.sh done <name>. Only if blocked on a JP-only item, say so plainly in your last message.' "$msg"
  return 2
}

OUT=$(main 2>>"$LOG"); rc=$?
case $rc in
  2) printf '%s\n' "$OUT" >&2; exit 2 ;;
  0) exit 0 ;;
  *) elog "fail-open: main returned $rc"; exit 0 ;;
esac
