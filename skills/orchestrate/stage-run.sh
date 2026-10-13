#!/bin/bash
# Stage wrapper (issue #136, phase 1 of #134):
#   stage-run.sh [--lane fast|full|infra] [--mode first|pre|narrow|fix|recovery|resume] [--cycle N] [--pr N] -- claude <args…>
# Runs `claude --session-id <uuid> <args…>` as a child (never exec: this process stays the parent so the PID the
# orchestrator polls is ours), forwards TERM/INT/HUP, passes output through unchanged, and appends a stage_start and a
# stage_end row to $LOGDIR/events.jsonl. Logging never blocks work: every failure below is swallowed and the exit
# code is always the child's.

HERE=$(cd "$(dirname "$0")" && pwd -P)
for f in "$HERE/config.sh" "$HERE/pipeline-lib.sh"; do [ -f "$f" ] && . "$f" 2>/dev/null; done
if [ -f "$HERE/../../hooks/pipeline-markers.sh" ]; then . "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null
elif [ -f "$HOME/.claude/hooks/pipeline-markers.sh" ]; then . "$HOME/.claude/hooks/pipeline-markers.sh" 2>/dev/null; fi
PIPE="${PIPE:-/tmp/pipeline}"
LOGDIR="${LOGDIR:-$HOME/logs/pipeline}"

# ---- flags (an invalid value becomes null; a bad flag never stops the stage)
LANE=""; MODE=""; CYCLE=""; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --lane) LANE=${2:-}; shift 2 2>/dev/null || shift ;;
    --mode) MODE=${2:-}; shift 2 2>/dev/null || shift ;;
    --cycle) CYCLE=${2:-}; shift 2 2>/dev/null || shift ;;
    --pr) PR=${2:-}; shift 2 2>/dev/null || shift ;;
    *) break ;;
  esac
done
case "$LANE" in fast|full|infra) ;; *) LANE="" ;; esac
case "$MODE" in first|pre|narrow|fix|recovery|resume) ;; *) MODE="" ;; esac
case "$CYCLE" in ''|*[!0-9]*) CYCLE="" ;; esac
case "$PR" in ''|*[!0-9]*) PR="" ;; esac
[ "${1:-}" = claude ] && shift
[ $# -gt 0 ] || { echo "stage-run.sh: no claude arguments after --" >&2; exit 2; }

# ---- identity: environment first, then the claude arguments
ARGS_TEXT=" $* "
AGENT=${PIPELINE_AGENT:-}; ISSUE=${PIPELINE_ISSUE:-}; REPO=${PIPELINE_REPO:-}
if [ -z "$AGENT" ]; then
  prev=""; for a in "$@"; do [ "$prev" = "--agent" ] && { AGENT=$a; break; }; prev=$a; done
fi
[ -n "$ISSUE" ] || ISSUE=$(printf '%s' "$ARGS_TEXT" | sed -n 's/.*Issue: #\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$REPO" ] || REPO=$(printf '%s' "$ARGS_TEXT" | sed -n 's/.*Repo: \([A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]*\).*/\1/p' | head -1 | sed 's/\.$//')
case "$ISSUE" in ''|*[!0-9]*) ISSUE="" ;; esac

# ---- helpers (all quiet; callers ignore failures)
jstr() { if [ -n "$1" ]; then jq -nc --arg v "$1" '$v'; else echo null; fi; }
jnum() { if [ -n "$1" ]; then echo "$1"; else echo null; fi; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
EVENTS="$LOGDIR/events.jsonl"
emit() { { mkdir -p "$LOGDIR" && printf '%s\n' "$1" >> "$EVENTS"; } 2>/dev/null || true; }

HOST=$(pipeline_host 2>/dev/null)
SID=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
START_EPOCH=$(date +%s); START_TS=$(iso_now)
RUN_ID="${HOST}-${ISSUE:-null}-${AGENT:-null}-${START_EPOCH}"

ATTEMPT=1
if [ -f "$EVENTS" ] && [ -n "$REPO$ISSUE$AGENT" ]; then
  prior=$(jq -c --argjson r "$(jstr "$REPO")" --argjson i "$(jnum "$ISSUE")" --argjson a "$(jstr "$AGENT")" \
    'select(.event=="stage_start" and .repo==$r and .issue==$i and .agent==$a)' "$EVENTS" 2>/dev/null | wc -l | tr -d ' ')
  case "$prior" in ''|*[!0-9]*) ;; *) ATTEMPT=$((prior + 1)) ;; esac
fi

row_head() {  # row_head <event> → JSON object with the fields both rows carry
  jq -nc --arg event "$1" --arg ts "$(iso_now)" --arg host "$HOST" --arg run_id "$RUN_ID" \
    --argjson sid "$(jstr "$SID")" --argjson repo "$(jstr "$REPO")" --argjson issue "$(jnum "$ISSUE")" --argjson pr "$(jnum "$PR")" \
    --argjson agent "$(jstr "$AGENT")" --argjson lane "$(jstr "$LANE")" --argjson mode "$(jstr "$MODE")" --argjson cycle "$(jnum "$CYCLE")" \
    --argjson attempt "$ATTEMPT" --arg start_ts "$START_TS" \
    '{v:1,ts:$ts,host:$host,event:$event,run_id:$run_id,session_id:$sid,repo:$repo,issue:$issue,pr:$pr,agent:$agent,lane:$lane,mode:$mode,cycle:$cycle,attempt:$attempt,start_ts:$start_ts}'
}

# ---- cost ceiling (issue #141): refuse a new fix-cycle developer / test-writer stage once the ticket's logged cost passes
# COST_CEILING_USD. Spend counts stage_end rows after the ticket's last cost_ceiling row. Fails open on any problem.
cost_ceiling_check() {
  local ceil=${COST_CEILING_USD:-40} stats spent runs nn body line2 id row
  [ "$MODE" = fix ] || return 0
  case "$AGENT" in fullstack-developer|test-writer) ;; *) return 0 ;; esac
  [ -n "$REPO" ] && [ -n "$ISSUE" ] && [ -f "$EVENTS" ] || return 0
  case "$ceil" in ''|*[!0-9.]*) return 0 ;; esac
  awk -v c="$ceil" 'BEGIN{exit !(c+0 > 0)}' || return 0
  stats=$(jq -R 'fromjson? | select(type == "object")' "$EVENTS" 2>/dev/null | jq -s -r --arg repo "$REPO" --argjson issue "$ISSUE" '
    [.[] | select(.event == "stage_end" and .repo == $repo and .issue == $issue)] as $rows
    | ([$rows | to_entries[] | select(.value.block_class == "cost_ceiling") | .key] | last // -1) as $cut
    | [$rows | to_entries[] | select(.key > $cut) | .value] as $s
    | "\([$s[].cost_usd // 0] | add // 0) \($s | length) \([$s[] | select(.cost_usd != null)] | length)"' 2>/dev/null) || return 0
  set -- $stats; spent=${1:-}; runs=${2:-}; nn=${3:-}
  [ -n "$spent" ] && [ -n "$runs" ] && [ "${nn:-0}" -gt 0 ] || return 0
  awk -v s="$spent" -v c="$ceil" 'BEGIN{exit !(s+0 > c+0)}' || return 0
  line2=$(awk -v s="$spent" -v c="$ceil" -v r="$runs" 'BEGIN{printf "Blocked on: cost_ceiling — this ticket has used $%.2f over %d stage runs (ceiling $%.2f); no new fix cycle was started", s, r, c}')
  body="**[$AGENT] BLOCKED**"$'\n'"$line2"$'\n'"$(awk -v c="$ceil" 'BEGIN{printf "Posted by stage-run.sh, not by the agent. To continue, record a decision that resolves this comment; the ticket then gets a further $%.2f.", c}')"
  id=$(gh api -X POST "repos/$REPO/issues/$ISSUE/comments" -f "body=$body" --jq .id 2>/dev/null </dev/null) || return 0
  case "$id" in ''|*[!0-9]*) return 0 ;; esac
  row=$(row_head stage_end | jq -c --arg ma "**[$AGENT] BLOCKED**" --argjson id "$id" \
    '. + {dur_s:0, exit_code:null, outcome:"marker", limit_kind:null, marker_before:null, marker_after:$ma, marker_comment_id:$id,
          marker_read_ok:true, findings:null, block_class:"cost_ceiling", cost_usd:null, in_tok:null, out_tok:null,
          cache_read:null, cache_create:null, models:{}, tool_calls:null} | .session_id = null' 2>/dev/null) || return 0
  [ -n "$row" ] || return 0
  emit "$row"
  return 7
}
cost_ceiling_check 2>/dev/null; [ $? -eq 7 ] && exit 0

emit "$(row_head stage_start 2>/dev/null)"

# ---- run the child, keeping a private copy of the output for the limit check
CAP=""; F1=""; F2=""; TP1=""; TP2=""
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/stage-run.XXXXXX" 2>/dev/null) || TMPD=""
if [ -n "$TMPD" ] && mkfifo "$TMPD/o" "$TMPD/e" 2>/dev/null; then
  CAP="$TMPD/cap"; : > "$CAP"
  tee -a "$CAP" < "$TMPD/o" & TP1=$!
  tee -a "$CAP" < "$TMPD/e" >&2 & TP2=$!
  F1="$TMPD/o"; F2="$TMPD/e"
fi

WSIG=0; CPID=""
trap 'WSIG=1; [ -n "$CPID" ] && kill -TERM "$CPID" 2>/dev/null' TERM INT HUP
if [ -n "$F1" ]; then
  claude --session-id "$SID" "$@" <&0 > "$F1" 2> "$F2" & CPID=$!
else
  claude --session-id "$SID" "$@" <&0 & CPID=$!
fi
wait "$CPID"; RC=$?
while kill -0 "$CPID" 2>/dev/null; do wait "$CPID"; RC=$?; done
trap - TERM INT HUP

# let the tee copies drain (bounded: a lingering grandchild must not hang us)
if [ -n "$TP1" ]; then
  n=0; while { kill -0 "$TP1" 2>/dev/null || kill -0 "$TP2" 2>/dev/null; } && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  kill "$TP1" "$TP2" 2>/dev/null; wait "$TP1" "$TP2" 2>/dev/null
fi

END_EPOCH=$(date +%s)
DUR=$((END_EPOCH - START_EPOCH))

finish() {
  local limit_kind="" marker='{"marker_before":null,"marker_after":null,"marker_comment_id":null,"marker_read_ok":false,"findings":null,"block_class":null}'
  local cost='{"cost_usd":null,"in_tok":null,"out_tok":null,"cache_read":null,"cache_create":null,"models":{},"tool_calls":null}'
  local outcome out

  [ -n "$CAP" ] && limit_kind=$(limit_kind_of "$CAP" 2>/dev/null)

  # marker read: one REST read of the issue's comments, one retry after 5s
  if [ -n "$REPO" ] && [ -n "$ISSUE" ] && [ -n "$AGENT" ]; then
    local raw="" ok=0 try
    for try in 1 2; do
      if raw=$(gh api "repos/$REPO/issues/$ISSUE/comments?per_page=100" --paginate 2>/dev/null </dev/null) \
         && printf '%s' "$raw" | jq -s 'add // []' >/dev/null 2>&1; then ok=1; break; fi
      [ "$try" = 1 ] && sleep 5
    done
    if [ "$ok" = 1 ]; then
      local before=""
      [ -f "$PIPE/$ISSUE-$AGENT-before.txt" ] && before=$(tr -dc '0-9' < "$PIPE/$ISSUE-$AGENT-before.txt")
      marker=$(printf '%s' "$raw" | jq -s 'add // []' | jq -c --arg re_any "$(marker_re)" --arg re_me "$(marker_re "$AGENT")" \
        --arg start "$START_TS" --arg before "$before" --arg classes "$(block_classes)" '
        def first_line: (.body // "") | split("\n")[0];
        (sort_by(.created_at)) as $c
        | [$c[] | select(first_line | test($re_me))] as $mine
        | ([$c[] | select(.created_at < $start and (first_line | test($re_any)))] | last) as $prev
        | (if $before != "" and ($mine | length) > ($before | tonumber) then ($mine | last) else null end) as $m
        | ($m | if . == null then null else first_line end) as $ml
        | {marker_before: ($prev | if . == null then null else first_line end),
           marker_after: $ml,
           marker_comment_id: ($m.id // null),
           marker_read_ok: true,
           findings: (if $ml == null then null else ($ml | capture("\\] (?:TESTS |PLAN )?FAIL: (?<n>[0-9]+) findings") | .n | tonumber) // null end),
           block_class: (if $ml != null and ($ml | test("\\] BLOCKED(\\*\\*|:| |$)"))
                         then (($m.body | split("\n")[1] // "" | capture("^Blocked on: (?<w>[a-z_]+)( |$)") | .w) // "other") as $w
                              | (if ($classes | split("|") | index($w)) != null then $w else "other" end)
                         else null end)}' 2>/dev/null) || true
      [ -n "$marker" ] || marker='{"marker_before":null,"marker_after":null,"marker_comment_id":null,"marker_read_ok":false,"findings":null,"block_class":null}'
    fi
  fi

  # cost: last cost-state record of the session transcript
  if [ -n "$SID" ]; then
    local tf rec
    tf=$(ls "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"/*/"$SID".jsonl 2>/dev/null | head -1)
    if [ -n "$tf" ]; then
      rec=$(tail -n 20 "$tf" 2>/dev/null | grep '"type":"cost-state"' | tail -1)
      if [ -n "$rec" ]; then
        out=$(printf '%s' "$rec" | jq -c '(.modelUsage // {}) as $u
          | {cost_usd: (.totalCostUSD // null),
             in_tok: ([$u[]?.inputTokens] | add), out_tok: ([$u[]?.outputTokens] | add),
             cache_read: ([$u[]?.cacheReadInputTokens] | add), cache_create: ([$u[]?.cacheCreationInputTokens] | add),
             models: ($u | with_entries(.value = .value.costUSD)), tool_calls: null}' 2>/dev/null) && [ -n "$out" ] && cost=$out
      fi
    fi
  fi

  if [ -n "$limit_kind" ]; then outcome=rate_limited
  elif [ "$RC" -ge 128 ] || [ "$WSIG" = 1 ]; then outcome=killed
  elif [ "$(printf '%s' "$marker" | jq -r '.marker_after // empty' 2>/dev/null)" != "" ]; then outcome=marker
  elif [ "$RC" -ne 0 ]; then outcome=error
  else outcome=no_marker; fi

  row_head stage_end | jq -c --argjson dur "$DUR" --argjson rc "$RC" --arg outcome "$outcome" --argjson lk "$(jstr "$limit_kind")" \
    --argjson marker "$marker" --argjson cost "$cost" \
    '. + {dur_s:$dur, exit_code:$rc, outcome:$outcome, limit_kind:$lk} + $marker + $cost'
}

ROW=$(finish 2>/dev/null) || ROW=""
[ -n "$ROW" ] && emit "$ROW"

# escape row (#138): a product-manager stage that filed a bug with a `Caused by: owner/repo#N` line logs it once per ticket
log_escape() {
  [ "$AGENT" = product-manager ] && [ -n "$REPO" ] && [ -n "$ISSUE" ] || return 0
  local body line cr ci
  body=$(gh api "repos/$REPO/issues/$ISSUE" --jq .body 2>/dev/null </dev/null) || return 0
  line=$(printf '%s\n' "$body" | tr -d '\r' | grep -E '^Caused by: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+ *$' | head -1)
  [ -n "$line" ] || return 0
  line=${line#Caused by: }; line=${line%"${line##*[! ]}"}
  cr=${line%#*}; ci=${line##*#}
  if [ -f "$EVENTS" ] && jq -e --argjson r "$(jstr "$REPO")" --argjson i "$ISSUE" 'select(.event=="escape" and .repo==$r and .issue==$i)' "$EVENTS" 2>/dev/null | grep -q .; then return 0; fi
  emit "$(jq -nc --arg ts "$(iso_now)" --arg host "$HOST" --arg repo "$REPO" --argjson issue "$ISSUE" --arg cr "$cr" --argjson ci "$ci" \
    '{v:1,ts:$ts,host:$host,event:"escape",repo:$repo,issue:$issue,caused_by_repo:$cr,caused_by_issue:$ci}' 2>/dev/null)"
}
log_escape 2>/dev/null || true
[ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null
exit "$RC"
