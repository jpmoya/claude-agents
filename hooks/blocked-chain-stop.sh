#!/bin/bash
# Stop hook: enforces CLAUDE.md "Interactive sessions act as the delivery lead" (JP, 2026-11-03).
# A session may not stop while a pipeline run launched by hand in the last 3 hours is dead on a BLOCKED / delivery-lead
# decision that is not JP-only, or while a run launched in the last 10 minutes is already dead. Exit 2 + stderr makes
# the session continue. LOCAL STATE ONLY (no gh, no network); fails open (exit 0) and logs to
# ~/logs/pipeline/blocked-chain-stop.log. Not keyed on session identity: any run launched manually (any launcher) counts.
# Applies to every interactive session on the host; skipped for pipeline stage processes (PIPELINE_AGENT) and, when the
# session cwd is a git checkout of some unrelated product, for that session.
# Env (tests): BCS_NOW (epoch), BCS_RUN_RE (run key filter), BCS_SCOPE_RE (cwd repo filter).
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
LOGD="$HOME/logs/pipeline"; LOG="$LOGD/blocked-chain-stop.log"; STATE="$LOGD/blocked-chain-stop.state"
PIPE="${PIPE:-$HOME/.claude/pipeline/state}"; EVENTS="$LOGD/events.jsonl"
RUN_RE="${BCS_RUN_RE:-(benjis-ops-tool|benjis-sales-tool|scheduler|benjis-quoting-tool)-[0-9]+$}"
SCOPE_RE="${BCS_SCOPE_RE:-(benjis-ops-tool|benjis-sales-tool|benjis-quoting-tool|scheduler|claude-agents)(\.git)?$}"
JPONLY_RE='prod(uction)?[ -]?(deploy|release|migration|database)|deploy(ing)? to prod|merge (it |this )?to main|release bot|risky.list|safe route|destructive|JP.{0,12}(go|approv|decision|confirm)|needs_jp|AWAITING GO|MOCKUPS? PENDING|mockup approv|prod(uction)? go|production (deploy|release|migration|database)|spend(ing)? money|third-party system|system of record|delet(e|ing) (the )?(data|prod)|external communication|private artefact|who gets access|infra(structure)? go|JP-only|JP only'
BLOCK_RE='BLOCKED|delivery-lead.{0,25}decision'
NOW="${BCS_NOW:-$(date +%s)}"
mkdir -p "$LOGD" 2>/dev/null
elog() { printf '%s %s\n' "$(TZ=Europe/Madrid date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$LOG" 2>/dev/null; }
madrid() { TZ=Europe/Madrid date -d "@$1" '+%H:%M %Z' 2>/dev/null || TZ=Europe/Madrid date -r "$1" '+%H:%M %Z' 2>/dev/null; }

main() {
  local IN T CWD URL L1 MSG rows key epoch repo issue pid age tail_txt why fp="" findings="" fh sfp sts
  IN=$(cat)
  CWD=$(printf '%s' "$IN" | jq -r '.cwd // empty') || return 3
  T=$(printf '%s' "$IN" | jq -r '.transcript_path // empty') || return 3
  # Scope: a cwd that is a git checkout of an unrelated product is left alone; an undetectable cwd applies everywhere.
  if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    URL=$(git -C "$CWD" config --get remote.origin.url 2>/dev/null)
    if [ -n "$URL" ] && ! printf '%s' "$URL" | grep -Eq "$SCOPE_RE"; then return 0; fi
  fi
  # Claude Code sets stop_hook_active when the session is already continuing because of a Stop hook: never trap it twice.
  [ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ] && return 0
  [ -s "$EVENTS" ] || return 0
  # Manual run_launch rows within 3 h, ascending by time.
  rows=$(tail -n 4000 "$EVENTS" | jq -R -r --argjson now "$NOW" \
    'fromjson? | select(.event=="run_launch" and .reason=="manual") | (.ts|fromdateiso8601) as $t | select($now-$t < 10800)
     | [$t, .repo, .issue] | @tsv' 2>/dev/null | sort -k1,1n) || return 3
  [ -n "$rows" ] || return 0
  # An explicit status question in the last user message may end the turn. Read only the transcript tail (fast), and only
  # after the cheap events check above.
  if [ -f "$T" ]; then
    L1=$(tail -n 60 "$T" 2>/dev/null | jq -R -r 'fromjson? | select(.type=="user") | .message.content | if type=="string" then . else (map(select(.type=="text")|.text)|join(" ")) end | select(length>0)' 2>/dev/null | tail -n 1)
    if printf '%s' "$L1" | grep -Eqi '(^|[^a-z])(status|update me|where (is|are)|what.?s up|how.?s it going)([^a-z]|$)'; then return 0; fi
  fi
  while IFS="$(printf '\t')" read -r epoch repo issue; do
    [ -n "$issue" ] || continue
    key="${repo//\//_}-$issue"
    printf '%s' "$key" | grep -Eq "$RUN_RE" || continue
    # only the latest launch of each run counts
    if printf '%s\n' "$rows" | awk -F'\t' -v r="$repo" -v i="$issue" -v e="$epoch" '$2==r && $3==i && $1>e {f=1} END{exit !f}'; then continue; fi
    [ -e "$PIPE/orch-$key.stopped" ] && continue
    [ -e "$PIPE/orch-$key.done" ] && continue
    [ -e "$PIPE/orch-$key.closed" ] && continue
    pid=$(cat "$PIPE/orch-$key.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    age=$((NOW - epoch))
    tail_txt=$(tail -n 40 "$PIPE/orch-$key.log" 2>/dev/null | tail -c 6000)
    why=""
    if printf '%s' "$tail_txt" | grep -Eqi "$BLOCK_RE"; then
      if printf '%s' "$tail_txt" | grep -Eqi "$JPONLY_RE"; then continue; fi
      why="dead on a BLOCKED / delivery-lead decision request"
    elif [ "$age" -le 600 ]; then
      why="launched $((age/60)) min ago and already exited"
    else
      continue
    fi
    fp="$fp$key:$why;"
    findings="$findings
- $repo#$issue (key $key): $why. Launched $(madrid "$epoch") Madrid. Local repo: $(cat "$PIPE/orch-$key.repo" 2>/dev/null || echo '?')
  last log lines: $(printf '%s' "$tail_txt" | grep -v '^$' | tail -n 3 | cut -c1-240 | tr '\n' '|')"
  done <<EOF2
$rows
EOF2
  [ -n "$fp" ] || return 0
  # Loop guard: the same fingerprint already blocked once in the last 20 min lets the session stop.
  fh=$(printf '%s' "$fp" | cksum | cut -d' ' -f1)
  read -r sfp sts < "$STATE" 2>/dev/null
  if [ "$sfp" = "$fh" ] && [ -n "$sts" ] && [ $((NOW - sts)) -lt 1200 ]; then return 0; fi
  printf '%s %s\n' "$fh" "$NOW" > "$STATE" 2>/dev/null
  MSG="You may not stop yet: you are the delivery lead for these pipeline runs and each is dead with nobody owning it.$findings

Do now, without asking JP (unless the block is JP-only: production, spending money, third-party systems of record, deleting data, external communications, private-artefact storage/access, infra go, mockup approval):
1. Read the BLOCKED comment on the issue and rule on it technically.
2. Post a comment starting with **[delivery-lead] DECISION** that contains the ruling, the next step and a line 'Resolves: <URL of the BLOCKED comment>' (gh issue comment <n> --repo <owner/repo> --body-file <file>; GitHub may be rate-limited until 10:00 Madrid, retry when reachable).
3. Relaunch: ~/.claude/skills/orchestrate/orchestrate.sh <local repo path> <issue>.
4. Two minutes later confirm the pid in orch-<key>.pid is alive (orchestrate.sh status); a launch message is not proof. If it exited, read its log and repeat.
If it is genuinely JP-only, say that plainly to JP in one line instead."
  printf '%s' "$MSG"
  return 2
}

OUT=$(main 2>>"$LOG"); rc=$?
case $rc in
  2) printf '%s\n' "$OUT" >&2; exit 2 ;;
  0) exit 0 ;;
  *) elog "fail-open: main returned $rc (input or state unparseable)"; exit 0 ;;
esac
