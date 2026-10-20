#!/bin/bash
# Stateless supervisor tick — cron runs it every 2 min (VM even minutes, Mac odd minutes). One tick does, in order:
#   1. restart exited non-terminal local orchestrators with backoff
#   2. drain the local launch queue
#   3. label lifecycle: drop agent-in-progress on issues this machine finished, parked, or abandoned
#   4. label reconciliation: clear orphaned agent-in-progress labels (no local pid, no queue, stale marker)
#   3b. intake: triage one user-feedback-intake issue from DISPATCH_REPOS (claim, swap label, launch `--agent intake`)
#   3c. spec: PM-only spec run for one `user-feedback-needs-spec` idea from DISPATCH_REPOS (no agent-go, no orchestrator; ends in agent-proposed)
#   5. shared dispatch: launch one agent-go issue from DISPATCH_REPOS after winning a claim
#   3d. goal step (#195): keep-alive, pacing, parking, completion of goal-bound delivery leads pinned to this host
#   7. status reconcile: refresh listed tickets from GitHub (backgrounded, throttled to once per 600 s; issue #51)
#   8. PM Slack DM poll: record JP's replies to project-manager asks (backgrounded, no-op without PM_SLACK_BOT_TOKEN; issue #117)
# One launch per tick max. All state is local (/tmp/pipeline); the only shared state is the issue's markers and labels.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"
# shared launcher helpers: SETSID probe, capacity checks, marker jq expression (issue #8)
source "$HERE/pipeline-lib.sh"
# shared run-state derivation + report_status_async (issue #10)
source "$HERE/run-state.sh"
# goal-bound delivery lead library (goal-lib.sh; the goal step #195 lives there)
source "$HERE/goal-lib.sh"
# routing-marker vocabulary (marker_re), shared with the handoff hook and the orchestrator
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"

SLOG="$LOGDIR/supervisor.log"
HOST=$(hostname -s)
mkdir -p "$PIPE" "$QUEUE" "$LOGDIR"

slog() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SLOG"; }
# #341: every .held creation logs its path and caller (log line only, no behaviour change)
touch_held() { touch "$1"; slog "[held-touch] path=$1 caller=${FUNCNAME[1]:-main}:${BASH_LINENO[0]}"; }
# A GitHub rename must never silently blind the scan: resolve canonical names, WARN loudly on rename/unresolvable.
canonicalize_repo_lists

# Event push: every tick, deliberately outside the single-flight lock below — this is the
# keep-alive + safety net (design #10 §4.4), so it must still fire even on a tick that skips
# because a previous one is still running.
report_status_async "tick"

# Acquire lock — exit if previous tick still running
if command -v flock >/dev/null 2>&1; then
  exec 9>"$PIPE/supervisor.lock"
  flock -n 9 || exit 0
else
  # macOS has no flock: mkdir is atomic; a lock older than 10 min is a dead tick, reclaim it
  LOCKDIR="$PIPE/supervisor.lockdir"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCKDIR" 2>/dev/null; mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else exit 0; fi
  fi
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
fi

# Code sync (docs/host-sync.md), inside the lock: refuse to launch on code that cannot be brought current; otherwise
# the EXIT trap fast-forwards main after this script has finished reading itself (the next tick runs the new code).
CS_STATE=fresh
if [ "${CODE_SYNC_ENABLED:-1}" = 1 ]; then
  source "$HERE/code-sync.sh"
  CS_STATE=$(code_sync_state 2>>"$SLOG")
  _cs_exit() { [ -n "${LOCKDIR:-}" ] && rmdir "$LOCKDIR" 2>/dev/null; [ "$CS_STATE" = fixable ] && code_sync_apply 2>>"$SLOG" && slog "[code-sync] fast-forwarded to $(git -C "$HERE" rev-parse --short HEAD)"; }
  trap _cs_exit EXIT
  if [ "$CS_STATE" = stale ]; then slog "[code-sync] STALE: checkout is behind origin/main or off main and cannot be fixed safely (uncommitted tracked edits or unpushed commits); refusing to launch this tick"; exit 0; fi
fi

to_epoch() {  # ISO-8601 UTC → epoch; portable (macOS date has no -d)
  python3 -c "import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$1" 2>/dev/null || echo 0
}

power_ok() {  # Mac: dispatch new work only on AC power (a sleeping laptop strands claimed issues). Linux: always.
  [ "$(uname)" = "Darwin" ] || return 0
  [ "${ALLOW_BATTERY:-0}" = "1" ] && return 0   # machine-local opt-out (config.local.sh); the Mac must be kept awake
  local batt pct
  batt=$(pmset -g batt 2>/dev/null)
  printf '%s' "$batt" | grep -q "AC Power" && return 0
  # On battery: dispatch while charge >= BATTERY_MIN_PCT (default 30; 0 = never on battery). keep_awake holds the machine awake, so the
  # old "a sleeping laptop strands claimed issues" reason no longer applies above the floor (20.3 h of dispatch lost 10-14..10-16).
  pct=$(printf '%s' "$batt" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
  [ -n "$pct" ] && [ "${BATTERY_MIN_PCT:-30}" -gt 0 ] && [ "$pct" -ge "${BATTERY_MIN_PCT:-30}" ]
}

# keep_awake — Mac only: every tick (launchd, every 2 min) holds an idle-sleep assertion for 5 min while any orchestrator/goal/queued run
# exists, so ticks overlap and the lid-open Mac never idles to sleep mid-run. No-op on Linux or when caffeinate is missing.
keep_awake() {
  [ "$(uname)" = "Darwin" ] || return 0
  [ "${KEEP_AWAKE:-1}" = "1" ] || return 0
  command -v caffeinate >/dev/null 2>&1 || return 0
  local f busy=0
  ls "$QUEUE"/orch-*.json >/dev/null 2>&1 && busy=1
  for f in "$PIPE"/orch-*.pid "$PIPE"/goal-*.pid; do
    [ -f "$f" ] && kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null && busy=1
  done
  [ "$busy" -eq 1 ] || return 0
  nohup caffeinate -i -t 300 >/dev/null 2>&1 &
  slog "[keep-awake] caffeinate -i -t 300 (pid $!)"
}

# gh_err_line <stderr file> — gh's error as ONE line for logs: first line, tokens/Bearer redacted, trimmed to 200 chars (#388).
gh_err_line() {
  head -1 "$1" 2>/dev/null | sed -E -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/[redacted]/g' -e 's/([Bb]earer|[Tt]oken)[ =:]+[^ ]+/\1 [redacted]/g' -e 's/token=\[redacted\]|token=[^ ]+/token=[redacted]/g' | cut -c1-200
}

autoretry_alert() {  # <issue> <what> [step, default auto-retry] — Slack webhook, tags only (release = commit SHA); never command output
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  local rel msg step=${3:-auto-retry}
  rel=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown)
  msg="supervisor read failed for #$1 ($2): release=$rel environment=$(hostname -s 2>/dev/null || echo unknown) route=supervisor/$step"
  curl -s --max-time 10 -X POST -H 'Content-type: application/json' \
    --data "$(jq -nc --arg t "$msg" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# issue_info_rest <checkout> <issue> → JSON {state, body, comments:[{body,createdAt}]} over REST (the old `gh issue view --json
# state,body,comments` shape, #388). On failure returns 1 and prints a one-line, token-free reason instead.
issue_info_rest() {
  local repo=$1 issue=$2 slug errf iss com rc=0
  slug=$(repo_slug "$repo"); errf=$(mktemp "${TMPDIR:-/tmp}/iir-err.XXXXXX")
  if [ -z "$slug" ]; then rm -f "$errf"; echo "rc=1: repo name not resolvable"; return 1; fi
  iss=$(cd "$repo" 2>/dev/null && gh api "repos/$slug/issues/$issue" 2>"$errf" </dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    com=$(cd "$repo" 2>/dev/null && gh api "repos/$slug/issues/$issue/comments?per_page=100" --paginate 2>>"$errf" </dev/null) || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$com" | jq -s '{c: (map(if type == "array" then .[] else . end))}' 2>>"$errf" | jq -c --argjson i "$iss" \
      '{state: (($i.state // "") | ascii_upcase), body: ($i.body // ""), updatedAt: $i.updated_at,
        author: (if ($i.user.login | type) == "string" then {login: $i.user.login} else null end),
        comments: [.c[] | {body: .body, createdAt: .created_at, author: (if (.user.login | type) == "string" then {login: .user.login} else null end)}]}' 2>>"$errf" \
      && { rm -f "$errf"; return 0; }
    rc=1
  fi
  echo "rc=$rc: $(gh_err_line "$errf")"; rm -f "$errf"; return 1   # stdout = the reason on failure
}

latest_marker() {  # the GATE marker: newest real routing marker whose agent is not delivery-lead (or its legacy alias project-manager) (NOTEs and off-vocabulary lines are inert).
  # Parallel pairs (claude-agents#169, replaces the #133 exception): except for stages dispatched in parallel from the same marker (ui-ux-designer ∥ solutions-architect, fullstack-developer ∥ test-reviewer, code-reviewer ∥ test-reviewer): when that latest marker is not itself a `BLOCKED` / `TEST DEFECT` / `FAIL` and the nearest earlier marker from a different stage is a `BLOCKED`, `TEST DEFECT` or `FAIL` from its parallel partner, that earlier marker is the gate marker and stays so until its own stage posts again. A sibling's later marker answers the sibling's work, not the blocked stage. For fullstack-developer ∥ test-reviewer the partner block is `BLOCKED` / `TEST DEFECT` / `TESTS FAIL` only (a bare `FAIL` is the narrow review after the developer's fix, not a partner), and a developer `IMPLEMENTED` also stays the gate marker over a later `TESTS APPROVED`.
  # When the newest routing marker overall is a `[delivery-lead]` (or legacy `[project-manager]`) one (it follows the gate marker), it is printed on a 2nd line.
  # Both come out of the same single paginated REST comments read (claude-agents#59, #388).
  local repo=$1 issue=$2 last list prog
  last=$(marker_last_jq); list=${last% | last // \"none\"}   # list = the same expression minus its final `last`
  prog="($last) as \$last | {author: .author, comments: [.comments[] | select(.body | test(\"^\\\\*\\\\*\\\\[(delivery-lead|project-manager)\\\\] \") | not)]} as \$np  # legacy alias
    | (\$np | $last) as \$g0 | (\$np | $list) as \$m | (\$m | length) as \$n
    | ((\$g0 | capture(\"^\\\\*\\\\*\\\\[(?<a>[a-z-]+)\\\\]\")? // {a: \"\"}).a) as \$ga
    | ([\$m[0:(\$n - 1)] | reverse[] | select(((capture(\"^\\\\*\\\\*\\\\[(?<a>[a-z-]+)\\\\]\")? // {a: \"\"}).a) != \$ga)] | first // null) as \$p
    | (if \$p == null then \"\" else ((\$p | capture(\"^\\\\*\\\\*\\\\[(?<a>[a-z-]+)\\\\]\")? // {a: \"\"}).a) end) as \$pa
    | ([\$pa, \$ga] | sort) as \$pair
    | (if (\$g0 | test(\"\\\\] (BLOCKED|TEST DEFECT|FAIL|TESTS FAIL)\") | not) and \$p != null and (if \$pair == [\"fullstack-developer\", \"test-reviewer\"] then ((\$p | test(\"\\\\] (BLOCKED|TEST DEFECT|TESTS FAIL)\")) or ((\$p | test(\"\\\\] IMPLEMENTED\")) and (\$g0 | test(\"\\\\] TESTS APPROVED\")))) else (\$p | test(\"\\\\] (BLOCKED|TEST DEFECT|FAIL|TESTS FAIL)\")) end)
         and (\$pair == [\"solutions-architect\", \"ui-ux-designer\"] or \$pair == [\"fullstack-developer\", \"test-reviewer\"] or \$pair == [\"code-reviewer\", \"test-reviewer\"])
       then \$p else \$g0 end) as \$gate
    | if (\$last | test(\"^\\\\*\\\\*\\\\[(delivery-lead|project-manager)\\\\] \") | not) then \$gate else \$gate + \"\\n\" + \$last end  # legacy alias"
  # REST, not GraphQL (#388): the shared GraphQL budget runs out hourly; the REST core limit is separate (same shape as #57's hook).
  # A failed read is "?" — callers must treat it as unknown, never as "no progress" (#387) — and is logged with rc + gh's first error line.
  # One comments call per read; the issue author (SKIP MOCKUPS check, #272) is fetched only when such a comment exists.
  local slug errf raw out rc=0 author=""
  slug=$(repo_slug "$repo"); errf=$(mktemp "${TMPDIR:-/tmp}/lm-err.XXXXXX")
  if [ -z "$slug" ]; then rc=1; echo "repo name not resolvable" > "$errf"
  else raw=$(cd "$repo" 2>/dev/null && gh api "repos/$slug/issues/$issue/comments?per_page=100" --paginate 2>"$errf" </dev/null) || rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    raw=$(printf '%s' "$raw" | jq -s '{comments: (map(if type == "array" then .[] else . end))}' 2>>"$errf") || rc=1
  fi
  if [ "$rc" -eq 0 ] && printf '%s' "$raw" | grep -q 'SKIP MOCKUPS'; then
    author=$(cd "$repo" 2>/dev/null && gh api "repos/$slug/issues/$issue" 2>/dev/null </dev/null | jq -r '.user.login // empty' 2>/dev/null) || author=""   # failure => no author => the skip is ignored, the gate stays
    [ -z "$author" ] || raw=$(printf '%s' "$raw" | jq -c --arg a "$author" '. + {author: {login: $a}}')
  fi
  if [ "$rc" -eq 0 ] && out=$(printf '%s' "$raw" | jq -r "$prog" 2>>"$errf") && [ -n "$out" ]; then
    rm -f "$errf"; printf '%s\n' "$out"; return 0
  fi
  [ "$rc" -ne 0 ] || rc=1
  slog "[marker] ${slug:-$repo}#$issue — marker read failed rc=$rc: $(gh_err_line "$errf")"
  rm -f "$errf"
  autoretry_alert "$issue" "latest_marker" latest_marker
  echo "?"
}

# #272: a comment whose first line is the exact skip marker but whose author/body cannot be read is ignored (the gate
# stays) and logged once per tick. The `JP said:` quote is never logged.
skip_marker_malformed_log() {
  local repo=$1 issue=$2 n
  n=$(issue_info_rest "$repo" "$issue" | jq -r '[.comments[] | select((.body | type) == "string" and (.body | split("\n")[0] | rtrimstr("\r") | test("^\\*\\*\\[jp\\] SKIP MOCKUPS\\*\\*[[:space:]]*$")))
      | select(((.author | type) != "object") or ((.author.login | type) != "string"))] | length' 2>/dev/null) || n=""
  case "$n" in ''|0|*[!0-9]*) return 0 ;; esac
  slog "[skip-mockups] #$issue — malformed SKIP MOCKUPS comment ignored ($n), gate stays"
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then   # tags only (release = commit SHA); never the comment text or the JP quote
    local rel msg
    rel=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown)
    msg="skip-mockups marker malformed for #$issue: release=$rel environment=$(hostname -s 2>/dev/null || echo unknown) route=supervisor/skip-mockups"
    curl -s --max-time 10 -X POST -H 'Content-type: application/json' \
      --data "$(jq -nc --arg t "$msg" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

# blocked_class_of <issue json with .comments> → the `Blocked on: <class>` word of the latest routing marker when it is a
# BLOCKED, else empty. One rule for the step-1 gate alert wording (#271) and the auto-retry scan (#250).
blocked_class_of() {
  printf '%s' "$1" | jq -r --arg re "$(marker_re)" '
    ([(.comments // [])[] | select(.body | split("\n")[0] | test($re))] | last) as $g
    | if $g == null or ($g.body | split("\n")[0] | test("\\] BLOCKED(\\*\\*|:| |$)") | not) then empty
      else (($g.body | split("\n")[1] // "") | capture("^Blocked on: (?<w>[a-z_]+)( |$)") | .w) // empty end' 2>/dev/null
}

issue_is_closed() {
  local repo=$1 issue=$2
  local state
  state=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json state --jq .state 2>/dev/null) || return 1
  [ "$state" = "CLOSED" ]
}

# #115 begin
# rejected_ok <repo dir> <issue> → 0 when the newest REJECTED is a real terminal outcome; otherwise logs it as inert (routing unchanged).
rejected_ok() {
  local repo=$1 issue=$2 why
  why=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json labels,comments 2>/dev/null | jq -r '
    ([.comments[].body | split("\n")] | map(select(.[0] | test("^\\*\\*\\[(product-manager|fullstack-developer)\\] REJECTED(\\*\\*|:| |$)"))) | last) as $r
    | if ([.labels[].name] | index("user-feedback") | not) then "no user-feedback label"
      elif $r == null then "no REJECTED from an allowed agent"
      elif ($r[1] // "" | rtrimstr("\r") | test("^Reason: (not-a-bug|cannot-reproduce|needs-spec|duplicate of #[0-9]+)$") | not) then "unknown or missing Reason"
      else "ok" end') || why="?"
  [ "$why" = ok ] && return 0
  slog "[rejected] #$issue — REJECTED marker inert: $why"; return 1
}
# #115 end
# "done" covers DEPLOYED / DEPLOYED TO STAGING / APPLIED and the architect's SPLIT (children run their own pipelines; #118).
# terminal_kind <gate marker> <issue> [<delivery-lead marker posted after it>] [<repo dir>] → prints "done" / "gate" /
# "grace" (BLOCKED inside the grace window: wait) / "" (not terminal). It judges the GATE marker. A later
# `[delivery-lead] DECISION` / `JP CONFIRMED` (legacy spelling `[project-manager]` accepted) lifts exactly one gate — a code-track BLOCKED — so the run takes the
# normal restart path and the orchestrator validates and relays the decision. It never lifts MOCKUPS PENDING APPROVAL,
# AWAITING GO, EFFORT APPROVAL NEEDED or an infra-reviewer BLOCKED. An infra planner/operator BLOCKED is lifted only when
# infra_staging_only holds (staging-only ticket, no JP-only item; claude-agents#89); otherwise it stays with JP.
terminal_kind() {
  local marker=$1 issue=${2:-} decision=${3:-} repo=${4:-.}
  marker=${marker%%\*\*}   # markers are bold ("**[deployer] DEPLOYED**"): strip the trailing bold so the $-anchors below match
  [[ "$marker" =~ \]\ (DEPLOYED|DEPLOYED\ TO\ STAGING|APPLIED|SPLIT)$ ]] && { echo done; return; }
  [[ "$marker" =~ \]\ REJECTED ]] && { rejected_ok "$repo" "$issue" && echo done || echo ""; return; }   # #115: valid only on user-feedback, from PM/developer, with a known Reason
  [[ "$marker" =~ \]\ (MOCKUPS\ PENDING\ APPROVAL|AWAITING\ GO|EFFORT\ APPROVAL\ NEEDED)$ ]] && { echo gate; return; }
  if [[ "$marker" =~ \]\ BLOCKED ]]; then
    # delegated decision recorded after a code-track BLOCKED: not a gate. An infra planner/operator BLOCKED is lifted
    # only when infra_staging_only succeeds (claude-agents#89); infra-reviewer BLOCKED always stays a gate.
    if [ -n "$decision" ]; then
      if ! [[ "$marker" =~ ^\*\*\[infra- ]]; then echo ""; return; fi
      if [[ "$marker" =~ ^\*\*\[infra-(planner|operator)\] ]]; then
        local orepo burl
        orepo=$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null)
        burl=$(gh issue view "$issue" --repo "$orepo" --json comments --jq \
          '[.comments[] | select(.body | split("\n")[0] | test("^\\*\\*\\[infra-(planner|operator)\\] BLOCKED"))] | last | .url' 2>/dev/null)
        if [ -n "$orepo" ] && [ -n "$burl" ] && infra_staging_only "$orepo" "$issue" "$burl"; then echo ""; return; fi
      fi
    fi
    # BLOCKED gets a grace period — false BLOCKEDs from subagent races resolve within minutes
    if [ -n "$issue" ] && [ -f "$PIPE/orch-$rk.start" ]; then
      local age=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$rk.start")") ))
      if [ "$age" -lt "$GRACE_PERIOD_SECS" ]; then
        slog "[grace] #$issue — BLOCKED marker seen but run is ${age}s old (<${GRACE_PERIOD_SECS}s), waiting"
        echo grace; return
      fi
    fi
    echo gate; return
  fi
  echo ""
}

# infra_staging_only <owner/repo> <issue> <blocked-comment-url> → 0 when a staging-only infra BLOCKED may be resumed by a
# delegated decision, 1 otherwise (claude-agents#89). All must hold: the BLOCKED is an infra-planner/operator one (not
# "Held: blocked by", not JP-only: prod/spend/secret/external comms); the issue body has a line exactly
# `Scope: staging-only`; the latest PLAN READY has no prod target step; a later `[delivery-lead]` (or legacy `[project-manager]`) `DECISION`/`JP CONFIRMED`
# has line 2 `Resolves: <that url>`.
infra_staging_only() {
  local owner_repo=$1 issue=$2 url=$3 json
  json=$(gh issue view "$issue" --repo "$owner_repo" --json body,comments 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e --arg url "$url" '
    def l1: (.body | split("\n")[0] | rtrimstr("\r"));
    def l2: (.body | split("\n")[1] // "" | rtrimstr("\r"));
    ([.body | split("\n")[] | rtrimstr("\r") | select(. == "Scope: staging-only")] | length > 0) as $scoped
    | (.comments | map(select(.url == $url)) | first) as $b
    | if ($scoped | not) or $b == null then false else
      ($b | l1 | test("^\\*\\*\\[infra-(planner|operator)\\] BLOCKED")) as $kind
      | ($b.body | test("held: blocked by|\\bprod(uction)?\\b|\\bspend|\\bsecret|who gets access|external communication"; "i") | not) as $safe
      | ([.comments[] | select(l1 | test("\\[infra-planner\\] PLAN READY"))] | last) as $plan
      | (($plan == null) or ($plan.body | test("(target|environment|env)\\s*:\\s*prod|prod step"; "i") | not)) as $planok
      | ([.comments[] | select((l1 == "**[delivery-lead] DECISION**" or l1 == "**[delivery-lead] JP CONFIRMED**"
               or l1 == "**[project-manager] DECISION**" or l1 == "**[project-manager] JP CONFIRMED**")   # legacy spelling
            and l2 == ("Resolves: " + $url) and .createdAt > $b.createdAt)] | length > 0) as $dec
      | $kind and $safe and $planok and $dec end' >/dev/null 2>&1
}

slack_thread_for() {  # <owner/repo> <issue> → "<channel> <ts>" from the last "**[pipeline-bridge] NOTE** slack-thread: <channel>:<ts>" comment, only if <channel> is $SLACK_ENGINEERING_CHANNEL; else nothing
  local owner_repo=$1 issue=$2 prefix line ch ts
  prefix='**[pipeline-bridge] NOTE** slack-thread: '
  line=$(gh issue view "$issue" --repo "$owner_repo" --json comments \
    --jq '[.comments[] | .body | split("\n")[0] | select(startswith("**[pipeline-bridge] NOTE** slack-thread: "))] | last // empty' 2>/dev/null) || return 0
  line=${line%$'\r'}
  [ -n "$line" ] || return 0
  line=${line#"$prefix"}
  ch=${line%%:*}
  ts=${line#*:}
  [ -n "$ch" ] && [ -n "$ts" ] && [ "$ch" != "$line" ] || return 0
  [ "$ch" = "${SLACK_ENGINEERING_CHANNEL:-}" ] || return 0
  printf '%s %s\n' "$ch" "$ts"
}

notify_engineering() {  # post a pipeline event to #engineering; requires SLACK_BOT_TOKEN + SLACK_ENGINEERING_CHANNEL
  local issue=$1 emoji=$2 reason=$3 owner_repo=$4
  [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_ENGINEERING_CHANNEL:-}" ] && return 0
  local link="https://github.com/$owner_repo/issues/$issue"
  local msg="$emoji <$link|#$issue> — $reason"
  local payload thread thread_ts
  thread=$(slack_thread_for "$owner_repo" "$issue" 2>/dev/null) || thread=""
  thread_ts=${thread#* }
  if [ -n "$thread" ]; then
    payload=$(jq -n --arg ch "$SLACK_ENGINEERING_CHANNEL" --arg txt "$msg" --arg ts "$thread_ts" \
      '{channel: $ch, text: $txt, unfurl_links: false, thread_ts: $ts}')
  else
    payload=$(jq -n --arg ch "$SLACK_ENGINEERING_CHANNEL" --arg txt "$msg" \
      '{channel: $ch, text: $txt, unfurl_links: false}')
  fi
  local resp
  resp=$(curl -s --max-time 10 -X POST -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" -d "$payload" https://slack.com/api/chat.postMessage 2>/dev/null) || true
  if echo "$resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
    slog "[slack] #$issue — posted to engineering"
  else
    slog "[slack] #$issue — post failed: $(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo 'curl error')"
  fi
}

clear_in_progress() {  # <repo> <issue> <why> <run_key> — idempotent; one gh call per issue, remembered in a marker file
  local repo=$1 issue=$2 why=$3 rk=$4
  [ -f "$PIPE/orch-$rk.label-cleared" ] && return 0
  if (cd "$repo" 2>/dev/null && gh issue edit "$issue" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1); then
    touch "$PIPE/orch-$rk.label-cleared"
    slog "[label] #$issue — removed $LABEL_IN_PROGRESS ($why)"
  fi
}

do_launch() {  # <repo> <issue> <extra> <restart_n> <reason> <queue_wait_s> <run_key>
  local repo=$1 issue=$2 extra=$3 restart_n=${4:-0} reason=${5:-manual} queue_wait_s=${6:-} rk=${7:-}
  [ -n "$rk" ] || rk=$(rk_of "$repo" "$issue")
  local owner_repo prompt title preamble=""

  # #438: the single launch funnel arbitrates the cross-host claim itself, so no path (queue, auto-restart, loop-cap
  # resume) can start a ticket the other host already holds. Same comment shape and CLAIM_WINDOW_SECS expiry as dispatch.
  # Returns 1 = lost to another host (caller drops the queue entry), 2 = claim could not be posted/read (fail closed, retry).
  local claim_win
  owner_repo=$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")
  gh api "repos/$owner_repo/issues/$issue/comments" -f body="**[supervisor] NOTE** claim: $HOST $(date -u +%FT%TZ)" >/dev/null 2>&1 \
    || { slog "[launch] #$issue — claim comment failed; not launching (will retry)"; return 2; }
  sleep "$CLAIM_SETTLE_SECS"
  claim_win=$(claim_winner_rest "$owner_repo" "$issue") \
    || { slog "[launch] #$issue — claim lookup failed; not launching (will retry)"; return 2; }
  if [ -n "$claim_win" ] && [ "$claim_win" != "$HOST" ]; then
    slog "[launch] #$issue — lost claim to $claim_win; not launching (running there)"
    return 1
  fi

  # Ticket title for the status board (#29): orchestrate.sh normally wrote it at launch and restarts reuse that
  # file; fetch only when it is missing. A failed or empty fetch leaves no file and never blocks the launch.
  if [ ! -f "$PIPE/orch-$rk.title" ]; then
    write_title_marker "$repo" "$issue" 0 "$rk"   # one gh issue view --json title,comments (title + marker)
  fi

  if [ "$restart_n" -gt 0 ]; then
    preamble="AUTO-RESTART #$restart_n: a previous orchestrator process exited without reaching a terminal state. Verify branch/PR/comment state with gh before dispatching anything. Never redo a completed stage. "
    # #178 begin
    # .cap-exit is written only by the stage-wait deferral in the main tick, which requires exit 0, a live stage
    # and the orchestrator's own cap-exit terminal row. A silent exit 0 has no such row and keeps the fault wording.
    if [ -f "$PIPE/orch-$rk.cap-exit" ]; then
      preamble="AUTO-RESTART #$restart_n: the previous orchestrator process stopped waiting at a stage's time cap (normal, not a fault; do not report it as a technical problem). Verify branch/PR/comment state with gh before dispatching anything. Never redo a completed stage. "
    fi
    # #178 end
  fi
  # #178 begin
  rm -f "$PIPE/orch-$rk.cap-exit"   # every launch consumes the signal
  # #178 end

  # Same launch shape as orchestrate.sh: the headless session IS the orchestrator (--agent), no Agent() call.
  prompt="Drive $owner_repo#$issue through the pipeline. Repo: $repo. Read the latest marker on the issue and continue from there. ${preamble}${extra}"

  printf '\n===== [%s] LAUNCH issue=%s reason=%s restart=%s =====\n' "$(date -u +%FT%TZ)" "$issue" "$reason" "$restart_n" >> "$PIPE/orch-$rk.log"
  rm -f "$PIPE/orch-$rk.exit"   # a killed run never writes it; a stale value would be reported as this run's (#38)
  cd "$repo"
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup $SETSID bash -c '
    echo 300 > /proc/self/oom_score_adj 2>/dev/null
    claude --dangerously-skip-permissions --agent orchestrator -p "$1"
    echo $? > "$2"
  ' _ "$prompt" "$PIPE/orch-$rk.exit" >> "$PIPE/orch-$rk.log" 2>&1 9>&- &

  echo $! > "$PIPE/orch-$rk.pid"
  echo "$repo" > "$PIPE/orch-$rk.repo"
  [ -f "$PIPE/orch-$rk.start" ] || date -u +%FT%TZ > "$PIPE/orch-$rk.start"
  date -u +%FT%TZ > "$PIPE/orch-$rk.launched-at"
  rm -f "$PIPE/orch-$rk.label-cleared"
  local ev_reason=manual
  case "$reason" in auto-restart) ev_reason=auto-restart ;; queued) ev_reason=queue ;; esac
  log_run_launch "$owner_repo" "$issue" "$ev_reason" "$restart_n" "$queue_wait_s" "$rk"

  slog "[launch] #$issue pid=$! reason=$reason restart=$restart_n mem=$(mem_available_mb)MB running=$(count_running)/$MAX_CONCURRENT"
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# log_run_exit <repo dir> <issue> <run_key> — the one writer of run_exit (design #138): classify the exit of a launched run
# (stopped > rate_limited > killed > error > normal), append the row, write .exit-class ("<class> <limit_kind|->"),
# touch .exit-logged. Never fails the tick.
log_run_exit() {
  local repo=$1 issue=$2 rk=$3 rid ex="" cls lk="" last_line seg exf="$PIPE/orch-$3.exit" lf="$PIPE/orch-$3.log"
  local launched dur now owner_repo
  rid=$(cat "$PIPE/orch-$rk.run-id" 2>/dev/null) || return 0
  [ -f "$exf" ] && ex=$(tr -dc '0-9' < "$exf")
  last_line=""; seg=$(mktemp "${TMPDIR:-/tmp}/run-exit.XXXXXX" 2>/dev/null) || seg=""
  if [ -n "$seg" ] && [ -f "$lf" ]; then
    last_launch_segment_line "$lf" > "$seg" 2>/dev/null
    last_line=$(cat "$seg" 2>/dev/null)
  fi
  if [ -f "$PIPE/orch-$rk.stopped" ]; then cls=stopped
  elif [ -n "$seg" ] && lk=$(limit_kind_of "$seg") && [ -n "$lk" ]; then cls=rate_limited
  elif [ ! -f "$exf" ]; then cls=killed
  elif [ "${ex:-0}" != 0 ]; then cls=error
  else cls=normal; fi
  [ "$cls" = rate_limited ] || lk=""
  [ -n "$seg" ] && rm -f "$seg"
  now=$(date +%s)
  launched=$(to_epoch "$(cat "$PIPE/orch-$rk.launched-at" 2>/dev/null)")
  if [ "$launched" -gt 0 ] 2>/dev/null; then
    if [ -f "$exf" ]; then dur=$(( $(file_mtime "$exf") - launched )); else dur=$((now - launched)); fi
    [ "$dur" -ge 0 ] 2>/dev/null || dur=0
  else dur=null; fi
  owner_repo=$(cd "$repo" 2>/dev/null && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null </dev/null) || owner_repo=""
  [ -n "$owner_repo" ] || owner_repo=unknown
  pipeline_event run_exit --arg run_id "$rid" --arg repo "$owner_repo" --argjson issue "$issue" \
    --argjson exit_code "${ex:-null}" --arg class "$cls" \
    --argjson limit_kind "$([ -n "$lk" ] && jq -nc --arg v "$lk" '$v' || echo null)" \
    --argjson dur_s "$dur" --arg last_line "${last_line:0:200}"
  printf '%s %s\n' "$cls" "${lk:--}" > "$PIPE/orch-$rk.exit-class" 2>/dev/null || true
  touch "$PIPE/orch-$rk.exit-logged" 2>/dev/null || true
  return 0
}

escalate() {  # <repo> <issue> <restarts file> <run_key>
  local repo=$1 issue=$2 restarts_file=$3 rk=$4
  local owner_repo history_text

  owner_repo=$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")
  history_text=$(python3 -c "
import json, sys
try:
    d = json.load(open('$restarts_file'))
    for h in d.get('history', []):
        print(f\"| {h.get('ts','?')} | exit {h.get('exit','?')} | {h.get('marker','?')} |\")
except: pass
" 2>/dev/null)

  (cd "$repo" && gh issue comment "$issue" --body "$(cat <<EOC
**[supervisor] NOTE**

This orchestrator has been auto-restarted multiple times without making progress. Pausing automatic restarts — manual intervention needed.

| Time | Exit | Marker |
|---|---|---|
$history_text

Relaunch manually with \`orchestrate.sh $repo $issue\` after investigating.
EOC
)") 2>/dev/null

  touch_held "$PIPE/orch-$rk.held"
  rm -f "$QUEUE/orch-$rk.json"
  printf '%s Pipeline #%s held — needs manual relaunch after investigation (%s)\n' "$(date -u +%FT%TZ)" "$issue" "$owner_repo" > "$PIPE/orch-$rk.alert"
  slog "[escalate] #$issue — too many restarts without progress (queue entry purged)"
  report_status_async "escalate"   # event push: run held (design #10 §4.4)
  notify_engineering "$issue" ":rotating_light:" "Stalled — restarted multiple times without progress. Needs investigation." "$owner_repo"
}

# #178 begin
# cap_exit_row <repo dir> <issue> <run_key> — 0 when runs.jsonl holds a terminal row for this repo+issue, written at or after
# this launch, whose next_action is the orchestrator's stage-cap hand-off. Any read/parse problem -> 1 (counted).
cap_exit_row() {
  local repo=$1 issue=$2 rk=$3 since owner_repo
  since=$(cat "$PIPE/orch-$rk.launched-at" 2>/dev/null || cat "$PIPE/orch-$rk.start" 2>/dev/null)
  [ -n "$since" ] && [ -f "$HOME/.claude/pipeline/runs.jsonl" ] || return 1
  owner_repo=$(cd "$repo" 2>/dev/null && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null </dev/null) || return 1
  [ -n "$owner_repo" ] || return 1
  python3 - "$HOME/.claude/pipeline/runs.jsonl" "$issue" "$since" "$owner_repo" <<'PY' 2>/dev/null
import json, sys
path, issue, since, repo = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
for line in open(path):
    try: r = json.loads(line)
    except ValueError: continue
    if (r.get("event") == "terminal" and r.get("issue") == issue and r.get("repo") == repo
            and r.get("next_action") == "supervisor relaunch picks up result" and str(r.get("ts", "")) >= since):
        sys.exit(0)
sys.exit(1)
PY
}
# #178 end
# --- Main tick ---

launched=0

# 0. One-time legacy migration (#318): orch-<N>.* sets whose .repo names a known checkout move to orch-<run_key>.*
migrate_legacy_runs

keep_awake   # Mac: hold the machine awake while runs exist (stall cause A)

# 1. Check each recorded orchestrator
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  rk=$(basename "$f" .pid); rk=${rk#orch-}; issue=${rk##*-}   # <owner>_<repo>-<N>; an unmigrated legacy bare <N> reads as is
  pid=$(cat "$f")
  repo=$(cat "$PIPE/orch-$rk.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue

  # Skip if alive
  kill -0 "$pid" 2>/dev/null && continue
  # #178 begin
  # The orchestrator exits by design at a stage's time cap while the stage keeps running (#178). It is a cap exit
  # only when ALL hold: exit code 0, the stage process is alive, and runs.jsonl has a terminal row for this
  # repo+issue written after this launch with next_action "supervisor relaunch picks up result" (the row the
  # orchestrator writes at the cap). Then wait like for a live orchestrator: no count, no requeue, no relaunch.
  # Anything else (silent exit 0, non-zero exit, no stage, unreadable process table) is counted as before.
  live_stage=$(_rs_live_stage "$issue" 0 2>/dev/null)
  [ -n "$live_stage" ] && slog "[stage-wait] #$issue — live_stage=$live_stage $(_rs_live_stage_proc "$issue" 2>/dev/null)"
  if [ -n "$live_stage" ] && [ "$(cat "$PIPE/orch-$rk.exit" 2>/dev/null)" = 0 ] && cap_exit_row "$repo" "$issue" "$rk"; then
    [ -f "$PIPE/orch-$rk.cap-exit" ] || slog "[stage-wait] #$issue — orchestrator exited at a stage cap, stage $live_stage still running; deferring"
    touch "$PIPE/orch-$rk.cap-exit" 2>/dev/null || true
    continue
  fi
  # A live stage that is not a cap exit (silent exit 0, crash) clears any stale signal; a gone stage keeps the
  # signal a prior deferral wrote, for the relaunch to consume.
  [ -n "$live_stage" ] && rm -f "$PIPE/orch-$rk.cap-exit"
  # #178 end

  # First tick that sees a launched run gone: one run_exit row (runs without a run-id predate #138 and log nothing)
  if [ -f "$PIPE/orch-$rk.run-id" ] && [ ! -f "$PIPE/orch-$rk.exit-logged" ]; then
    log_run_exit "$repo" "$issue" "$rk"
  fi

  # Skip if tombstoned
  [ -f "$PIPE/orch-$rk.stopped" ] && continue
  [ -f "$PIPE/orch-$rk.held" ] && continue
  [ -f "$PIPE/orch-$rk.done" ] && continue

  # Check if terminal
  if issue_is_closed "$repo" "$issue"; then
    touch "$PIPE/orch-$rk.done"
    slog "[done] #$issue — issue closed"
    cleanup_finished_worktree "$repo" "$issue"
    continue
  fi

  marker=$(latest_marker "$repo" "$issue")
  decision=""
  case "$marker" in *$'\n'*) decision=${marker#*$'\n'}; marker=${marker%%$'\n'*} ;; esac   # line 2 = [delivery-lead] (or legacy [project-manager]) marker after the gate marker
  case "$(terminal_kind "$marker" "$issue" "$decision" "$repo")" in
    done)
      touch "$PIPE/orch-$rk.done"
      slog "[done] #$issue — terminal marker: $marker"
      done_text="Deployed"; case "$marker" in *"] SPLIT"*) done_text="Split into sub-issues" ;; esac
      case "$marker" in *"] REJECTED"*) done_text="Rejected" ;; esac
      cleanup_finished_worktree "$repo" "$issue"
      notify_engineering "$issue" ":white_check_mark:" "$done_text" "$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")"
      continue ;;
    gate)
      # Human gate (mockups, infra go, BLOCKED with no delegated decision after it): park it; JP relaunches (or re-adds
      # agent-go) after acting. $marker is the gate marker, never a [delivery-lead] (or legacy [project-manager]) one. A run that is already .held is
      # skipped above and stays held — held runs are not polled; the delivery lead relaunches with orchestrate.sh,
      # which clears .held (claude-agents#59).
      skip_marker_malformed_log "$repo" "$issue"   # #272: at every gate park (not only MOCKUPS PENDING); an extra per-tick fetch would break the one-comments-call-per-tick pin
      # #306: a run auto-retry (step 1b) re-queued keeps its queue entry for the drain; re-holding it here would swallow the retry.
      if [ -f "$QUEUE/orch-$rk.json" ]; then
        slog "[queue-wait] #$issue — gate marker but already queued for relaunch, leaving the queue entry"
        continue
      fi
      touch_held "$PIPE/orch-$rk.held"
      rm -f "$QUEUE/orch-$rk.json"
      gate_reason=$(echo "$marker" | sed 's/\*\*\[[^]]*\]\*\* *//; s/^ *//; s/ *$//')
      [ -z "$gate_reason" ] && gate_reason="$marker"
      # #271: a BLOCKED whose class auto-retry clears is parked, not waiting on JP. Read failure -> today's text.
      gate_cls=""
      case "$marker" in *"] BLOCKED"*) gate_cls=$(blocked_class_of "$(cd "$repo" && gh issue view "$issue" --json comments 2>/dev/null </dev/null)") ;; esac
      case "|$(autoretry_classes)|" in *"|$gate_cls|"*) ;; *) gate_cls="" ;; esac
      # Park only while retries remain; once the cap is spent auto-retry stops and JP must act.
      gate_n=$(tr -dc '0-9' 2>/dev/null < "$PIPE/orch-$rk.autoretry")
      [ "${gate_n:-0}" -lt "${AUTORETRY_MAX:-3}" ] || gate_cls=""
      if [ -n "$gate_cls" ]; then
        printf '%s Pipeline #%s parked, auto-retry (%s) — %s\n' "$(date -u +%FT%TZ)" "$issue" "$gate_cls" "$marker" > "$PIPE/orch-$rk.alert"
        slog "[held] #$issue — parked for auto-retry ($gate_cls): $marker"
        report_status_async "held"
        notify_engineering "$issue" ":hourglass:" "Parked, auto-retry ($gate_cls) — $gate_reason" "$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")"
      else
        printf '%s Pipeline #%s waiting on JP — %s; relaunch (or re-add %s) after acting\n' "$(date -u +%FT%TZ)" "$issue" "$marker" "$LABEL_GO" > "$PIPE/orch-$rk.alert"
        slog "[held] #$issue — waiting on JP: $marker"
        report_status_async "held"   # event push: run held/gate (design #10 §4.4)
        notify_engineering "$issue" ":hand:" "Waiting on you — $gate_reason" "$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")"
      fi
      continue ;;
    grace) continue ;;
  esac

  # How this run ended (written by log_run_exit; absent for runs launched before #138)
  exit_class=""; exit_lk=""
  [ -f "$PIPE/orch-$rk.exit-class" ] && read -r exit_class exit_lk < "$PIPE/orch-$rk.exit-class"
  [ "$exit_lk" = "-" ] && exit_lk=""

  restarts_file="$PIPE/orch-$rk.restarts"
  exit_code=$(cat "$PIPE/orch-$rk.exit" 2>/dev/null || echo "?")

  if [ "$exit_class" = rate_limited ] && [ "$exit_lk" = monthly_spend ]; then
    # Restarting cannot fix it and clearing it means spending money: park like a human gate. Counters untouched.
    run_owner_repo=$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")
    python3 - "$restarts_file" "$(date -u +%FT%TZ)" "$exit_code" "$marker" "$exit_class" "$exit_lk" <<'PY' 2>/dev/null
import json, sys
path, ts, ex, marker, cls, lk = sys.argv[1:7]
try: d = json.load(open(path))
except Exception: d = {'count': 0, 'total': 0, 'last_marker': '', 'history': []}
d.setdefault('history', []).append({'ts': ts, 'exit': ex, 'marker': marker, 'transient': False, 'run_secs': 0, 'class': cls, 'limit_kind': lk or None})
json.dump(d, open(path, 'w'))
PY
    touch_held "$PIPE/orch-$rk.held"
    rm -f "$QUEUE/orch-$rk.json"
    printf '%s Pipeline #%s waiting on JP — monthly spend limit reached; relaunch after credits or a model switch\n' "$(date -u +%FT%TZ)" "$issue" > "$PIPE/orch-$rk.alert"
    slog "[held] #$issue — monthly spend limit: needs JP"
    report_status_async "held"
    notify_engineering "$issue" ":hand:" "Waiting on you — monthly spend limit reached" "$run_owner_repo"
    continue
  fi

  # Already queued — nothing ended this tick: don't count it, don't overwrite its not_before
  if [ -f "$QUEUE/orch-$rk.json" ]; then
    slog "[queue-wait] #$issue — already queued, skipping re-enqueue"
    continue
  fi

  if [ "$exit_class" = rate_limited ]; then
    # Weekly / unrecognised limit: wait, don't count (never trips the "stalled" escalation)
    python3 - "$restarts_file" "$(date -u +%FT%TZ)" "$exit_code" "$marker" "$exit_class" "$exit_lk" <<'PY' 2>/dev/null
import json, sys
path, ts, ex, marker, cls, lk = sys.argv[1:7]
try: d = json.load(open(path))
except Exception: d = {'count': 0, 'total': 0, 'last_marker': '', 'history': []}
d.setdefault('history', []).append({'ts': ts, 'exit': ex, 'marker': marker, 'transient': False, 'run_secs': 0, 'class': cls, 'limit_kind': lk or None})
json.dump(d, open(path, 'w'))
PY
    extra=$(cat "$PIPE/orch-$rk.extra" 2>/dev/null || echo "")
    not_before=$(( $(date +%s) + RATE_LIMIT_BACKOFF_SECS ))
    python3 - "$QUEUE/orch-$rk.json" "$issue" "$repo" "$extra" "$(date -u +%FT%TZ)" "$not_before" <<'PY' 2>/dev/null
import json, sys
path, issue, repo, extra, qa, nb = sys.argv[1:7]
json.dump({'issue': issue, 'repo': repo, 'extra': extra, 'reason': 'auto-restart', 'queued_at': qa, 'not_before': int(nb)}, open(path, 'w'))
PY
    slog "[rate-limited] #$issue limit=$exit_lk backoff=${RATE_LIMIT_BACKOFF_SECS}s"
    report_status_async "queue-restart"
    continue
  fi

  # Non-terminal exit — potential restart
  [ "$launched" -ge 1 ] && continue  # one launch per tick
  extra=$(cat "$PIPE/orch-$rk.extra" 2>/dev/null || echo "")

  # Detect transient exit: use per-launch timestamp (.launched-at), not the original .start
  # .start is preserved across restarts (used by BLOCKED grace window); .launched-at tracks this launch only
  run_duration=0
  if [ -f "$PIPE/orch-$rk.launched-at" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$rk.launched-at")") ))
  elif [ -f "$PIPE/orch-$rk.start" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$rk.start")") ))
  fi
  transient=false
  [ "$run_duration" -lt "$MIN_RUN_SECS" ] && transient=true

  # Deliberate stop: the run that just ended logged a validate fail of a deliberate-stop stage (start-gate, closed PR, refused delegated decision, loop cap).
  # A restart cannot heal it — hold instead of looping to MAX_TOTAL. Other stages (concurrency-gate, ...) still restart.
  # "This run" = ts >= .launched-at. One list of stage values: structural (claude-agents#92), delegated-decision, loop-cap (#88), hand-to-jp (#129).
  since=$(cat "$PIPE/orch-$rk.launched-at" 2>/dev/null || cat "$PIPE/orch-$rk.start" 2>/dev/null)   # this launch's start (no GNU date -d: BSD date lacks it)
  found_stage=""
  if [ -n "$since" ] && [ -f "$HOME/.claude/pipeline/runs.jsonl" ]; then
    found_stage=$(python3 - "$HOME/.claude/pipeline/runs.jsonl" "$issue" "$since" <<'PY' 2>/dev/null
import json, sys
path, issue, since = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for line in open(path):
    try: r = json.loads(line)
    except ValueError: continue
    if (r.get("issue") == issue and r.get("event") == "validate" and r.get("result") == "fail"
            and r.get("stage") in ("structural", "delegated-decision", "loop-cap", "hand-to-jp") and str(r.get("ts", "")) >= since):
        print(r.get("stage"))
        break
PY
)
  fi
  if [ -n "$found_stage" ]; then
    touch_held "$PIPE/orch-$rk.held"
    case "$found_stage" in
      loop-cap) hold_reason="loop-cap stop" ;;
      delegated-decision) hold_reason="refused delegated decision" ;;
      hand-to-jp) hold_reason="hand-to-jp: PR passed review, waiting on JP's merge" ;;
      *) hold_reason="structural stop (start-gate / closed PR)" ;;
    esac
    slog "[held] #$issue — $hold_reason, needs a relaunch after it is resolved"
    if [ "$found_stage" = "hand-to-jp" ]; then   # route supervisor/hold/hand-to-jp; payload = issue number + stage only
      notify_engineering "$issue" ":hand:" "Waiting on you — hand-to-jp, PR passed review (route supervisor/hold/hand-to-jp)" \
        "$(cd "$repo" && gh api repos/{owner}/{repo} --jq .full_name 2>/dev/null || echo "unknown")"
    fi
    report_status_async "held"
    continue
  fi

  # Load or init restart state
  if [ -f "$restarts_file" ]; then
    count=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('count',0))" 2>/dev/null || echo 0)
    total=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('total',0))" 2>/dev/null || echo 0)
    last_marker=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('last_marker',''))" 2>/dev/null || echo "")
  else
    count=0; total=0; last_marker=""
  fi

  # A failed marker read ("?") is not evidence of anything: not progress, not no-progress (#387).
  marker_unknown=false; [ "$marker" = "?" ] && marker_unknown=true
  if $marker_unknown; then
    marker=$last_marker   # never store "?" as last_marker
  elif [ "$marker" != "$last_marker" ] && [ -n "$last_marker" ]; then   # marker progressed (reset no-progress counter)
    count=0
    total=0
    slog "[progress] #$issue marker advanced: $last_marker -> $marker"
  fi

  # #178 begin
  # A cap exit (the deferral signal is set, exit 0, and the orchestrator's own terminal row for this launch) is the
  # orchestrator waiting by design: it increments neither count nor total, now that its stage has ended too.
  cap_exit_now=false
  if [ -f "$PIPE/orch-$rk.cap-exit" ] && [ "$exit_code" = 0 ] && cap_exit_row "$repo" "$issue" "$rk"; then
    cap_exit_now=true
    slog "[cap-exit] #$issue — stage ended after a cap exit; relaunching without counting"
  fi
  # #178 end

  if ! $cap_exit_now; then
    total=$((total + 1))
    if $transient; then
      slog "[transient] #$issue ran ${run_duration}s (<${MIN_RUN_SECS}s) — treating as transient"
    elif $marker_unknown; then
      slog "[marker] #$issue — marker unreadable; exit not counted as no-progress (total=$total)"
    else
      count=$((count + 1))
    fi
  fi

  # One ceiling for every exit, fast or slow
  should_escalate=false
  if [ "$count" -ge "$MAX_NO_PROGRESS" ] || [ "$total" -ge "$MAX_TOTAL" ]; then
    should_escalate=true
  fi

  python3 -c "
import json
try: d = json.load(open('$restarts_file'))
except: d = {'count':0,'total':0,'last_marker':'','history':[]}
d['history'].append({'ts':'$(date -u +%FT%TZ)','exit':'$exit_code','marker':'''$marker''','transient':$($transient && echo True || echo False),'run_secs':$run_duration,'class':$([ -n "$exit_class" ] && echo "'$exit_class'" || echo None),'limit_kind':$([ -n "$exit_lk" ] && echo "'$exit_lk'" || echo None)})
d['count']=$count; d['total']=$total; d['last_marker']='''$marker'''
json.dump(d, open('$restarts_file','w'))
" 2>/dev/null

  if $should_escalate; then
    escalate "$repo" "$issue" "$restarts_file" "$rk"
    continue
  fi

  # Calculate backoff — transient exits use longer backoff
  if $cap_exit_now; then
    backoff_val=${BACKOFF[0]}
  elif $transient; then
    idx=$((total - 1))
    [ "$idx" -ge "${#TRANSIENT_BACKOFF[@]}" ] && idx=$(( ${#TRANSIENT_BACKOFF[@]} - 1 ))
    backoff_val=${TRANSIENT_BACKOFF[$idx]}
  else
    idx=$((count - 1))
    [ "$idx" -ge "${#BACKOFF[@]}" ] && idx=$(( ${#BACKOFF[@]} - 1 ))
    backoff_val=${BACKOFF[$idx]}
  fi
  not_before=$(( $(date +%s) + backoff_val ))

  # Enqueue with backoff
  python3 -c "
import json
json.dump({'issue':'$issue','repo':'$repo','extra':'''$extra''','reason':'auto-restart','queued_at':'$(date -u +%FT%TZ)','not_before':$not_before}, open('$QUEUE/orch-$rk.json','w'))
" 2>/dev/null

  slog "[queue-restart] #$issue exit=$exit_code marker='$marker' transient=$transient run=${run_duration}s count=$count/$MAX_NO_PROGRESS total=$total backoff=${backoff_val}s"
  report_status_async "queue-restart"   # event push: run exited -> requeued (design #10 §4.4)
done

# 1b. Auto-retry (#250): a .held run whose latest gate is a BLOCKED of a machine-clearable class
# (autoretry_classes in hooks/pipeline-markers.sh) is requeued once the cause has cleared. At most
# AUTORETRY_MAX per run, one cause-check per AUTORETRY_THROTTLE_SECS per run. Never touches JP gates
# (needs_jp, unparsable class, other, unsupported_project, AWAITING GO, EFFORT, MOCKUPS, spend hold).
AUTORETRY_MAX=3
AUTORETRY_THROTTLE_SECS=1800



# autoretry_cleared <repo> <issue> <class> <issue json> — 0 cleared, 1 not cleared, 2 error (reason in AR_ERR)
autoretry_cleared() {
  local repo=$1 issue=$2 cls=$3 info=$4 prs pr mergeable dep rc deps
  AR_ERR=""
  case "$cls" in
    dependency)
      deps=$(printf '%s' "$info" | jq -r '.body // ""' | grep -iE '^[[:space:]]*([-*][[:space:]]+)?depends on ' | grep -oE '#[0-9]+' | tr -d '#')
      [ -n "$deps" ] || return 1
      for dep in $deps; do
        [ "$(cd "$repo" && gh issue view "$dep" --json state --jq .state 2>/dev/null </dev/null)" = "CLOSED" ] || return 1
      done
      return 0 ;;
    ci_*|merge_conflict)
      prs=$(cd "$repo" && gh pr list --state open --limit 100 --json number,headRefName,mergeable 2>/dev/null </dev/null) \
        || { AR_ERR="pr list"; return 2; }
      pr=$(printf '%s' "$prs" | jq -r --arg p "issue-$issue-" '[.[] | select(.headRefName | startswith($p))][0] // empty | "\(.number) \(.mergeable)"' 2>/dev/null) \
        || { AR_ERR="pr list parse"; return 2; }
      if [ -z "$pr" ] && [ "$cls" != merge_conflict ]; then
        # #439: a ci_* stop can come after the merge (deployer waiting on the staging deploy); the open-PR list is then
        # empty forever. A merged issue-N- PR means the cause is gone: relaunch (still capped by AUTORETRY_MAX).
        prs=$(cd "$repo" && gh pr list --state merged --limit 100 --json number,headRefName 2>/dev/null </dev/null) \
          || { AR_ERR="pr list merged"; return 2; }
        printf '%s' "$prs" | jq -e --arg p "issue-$issue-" '[.[] | select(.headRefName | startswith($p))] | length > 0' >/dev/null 2>&1 && return 0
      fi
      [ -n "$pr" ] || return 1
      mergeable=${pr#* }; pr=${pr%% *}
      if [ "$cls" = merge_conflict ]; then
        [ "$mergeable" != "CONFLICTING" ]; return $?
      fi
      (cd "$repo" && gh pr checks "$pr" >/dev/null 2>&1 </dev/null); rc=$?
      case "$rc" in 0) return 0 ;; 1|8) return 1 ;; *) AR_ERR="pr checks rc=$rc"; return 2 ;; esac ;;
  esac
  return 1
}

# Loop-cap resume: a loop-cap stop is held "needs a relaunch after it is resolved", and nothing re-read it (#1141 sat 161 h).
# held_by_loopcap <rk> <issue> — local state only: the hold has no alert (gate/spend holds write one) and the run's newest
# deliberate-stop validate row in runs.jsonl is a loop-cap one (same stage list as the exit handler above).
held_by_loopcap() {
  [ -s "$PIPE/orch-$1.alert" ] && return 1
  [ -f "$HOME/.claude/pipeline/runs.jsonl" ] || return 1
  [ "$(python3 - "$HOME/.claude/pipeline/runs.jsonl" "$2" <<'PY' 2>/dev/null
import json, sys
last = ""
for line in open(sys.argv[1]):
    try: r = json.loads(line)
    except ValueError: continue
    if (r.get("issue") == int(sys.argv[2]) and r.get("event") == "validate" and r.get("result") == "fail"
            and r.get("stage") in ("structural", "delegated-decision", "loop-cap", "hand-to-jp")):
        last = r.get("stage")
print(last)
PY
)" = "loop-cap" ]
}
LOOPCAP_THROTTLE_SECS=300

for f in "$PIPE"/orch-*.held; do
  [ -e "$f" ] || break
  rk=$(basename "$f" .held); rk=${rk#orch-}; issue=${rk##*-}
  repo=$(cat "$PIPE/orch-$rk.repo" 2>/dev/null || echo "")
  [ -n "$repo" ] || continue
  [ -f "$PIPE/orch-$rk.stopped" ] || [ -f "$PIPE/orch-$rk.done" ] && continue
  n=$(tr -dc '0-9' 2>/dev/null < "$PIPE/orch-$rk.autoretry"); n=${n:-0}
  is_lc=0; held_by_loopcap "$rk" "$issue" && is_lc=1
  [ "$n" -lt "$AUTORETRY_MAX" ] || [ "$is_lc" -eq 1 ] || continue
  stamp="$PIPE/orch-$rk.autoretry-check"
  last=$(file_mtime "$stamp")
  thr=$AUTORETRY_THROTTLE_SECS; [ "$is_lc" -eq 1 ] && thr=$LOOPCAP_THROTTLE_SECS
  if [ -n "$last" ] && [ $(( $(date +%s) - last )) -lt "$thr" ]; then continue; fi
  touch "$stamp" 2>/dev/null || true   # throttle failed checks too

  # Local state first (#269): no API call for a run that is not parked on a BLOCKED
  ar_ec=""; [ -f "$PIPE/orch-$rk.exit-class" ] && ar_ec=$(tr -s ' \t' ' ' < "$PIPE/orch-$rk.exit-class" | head -1)
  [ "$ar_ec" = "rate_limited monthly_spend" ] && continue
  if [ -s "$PIPE/orch-$rk.alert" ] && ! grep -q 'BLOCKED' "$PIPE/orch-$rk.alert" 2>/dev/null; then continue; fi

  info=$(issue_info_rest "$repo" "$issue") \
    || { slog "[auto-retry] #$issue — issue read failed: ${info:-no error text}"; autoretry_alert "$issue" "issue read"; continue; }
  [ "$(printf '%s' "$info" | jq -r '.state // empty')" = "OPEN" ] || continue
  if [ "$is_lc" -eq 1 ]; then
    # Resume only on a delegated decision posted AFTER the hold: [delivery-lead] DECISION / JP CONFIRMED (legacy [project-manager] spelling).
    # The relaunched orchestrator validates it (Resolves: line); if it refuses, the new hold is later than the decision, so no loop.
    held_at=$(file_mtime "$f")
    if [ -n "$held_at" ] && printf '%s' "$info" | jq -e --argjson t "$held_at" '[.comments[]
        | select((.body | split("\n")[0] | rtrimstr("\r")) as $l | ($l == "**[delivery-lead] DECISION**" or $l == "**[delivery-lead] JP CONFIRMED**"
            or $l == "**[project-manager] DECISION**" or $l == "**[project-manager] JP CONFIRMED**")
          and (.createdAt | fromdateiso8601) > $t)] | length > 0' >/dev/null 2>&1; then
      if ! (cd "$repo" && gh issue comment "$issue" --body "**[supervisor] NOTE** loop-cap hold resumed: a delegated decision was posted after the stop" >/dev/null 2>&1 </dev/null); then
        slog "[loopcap-resume] #$issue — NOTE post failed, staying held"
        continue
      fi
      rm -f "$PIPE/orch-$rk.held" "$PIPE/orch-$rk.alert"
      python3 - "$issue" "$repo" "$QUEUE/orch-$rk.json" "$(date -u +%FT%TZ)" "$PIPE/orch-$rk.extra" <<'PY' 2>/dev/null
import json, sys
issue, repo, out, ts, ex = sys.argv[1:6]
try: extra = open(ex).read()
except Exception: extra = ''
json.dump({'issue': issue, 'repo': repo, 'extra': extra, 'reason': 'queued', 'queued_at': ts, 'not_before': 0}, open(out, 'w'))
PY
      slog "[loopcap-resume] #$issue — decision posted after the loop-cap stop, relaunching"
      report_status_async "auto-retry"
    fi
    continue
  fi
  [ "$n" -lt "$AUTORETRY_MAX" ] || continue
  cls=$(blocked_class_of "$info")
  case "|$(autoretry_classes)|" in *"|$cls|"*) ;; *) continue ;; esac

  autoretry_cleared "$repo" "$issue" "$cls" "$info"; rc=$?
  if [ "$rc" -eq 2 ]; then
    slog "[auto-retry] #$issue — $cls check failed: $AR_ERR"
    autoretry_alert "$issue" "$AR_ERR"
    continue
  fi
  [ "$rc" -eq 0 ] || continue

  n=$((n + 1))
  # NOTE first: the relaunched orchestrator resumes on it. If it cannot be posted, stay held for the next tick.
  if ! (cd "$repo" && gh issue comment "$issue" --body "**[supervisor] NOTE** auto-retry $n/$AUTORETRY_MAX: $cls cleared" >/dev/null 2>&1 </dev/null); then
    slog "[auto-retry] #$issue — NOTE post failed, staying held"
    autoretry_alert "$issue" "issue comment"
    continue
  fi
  echo "$n" > "$PIPE/orch-$rk.autoretry"
  rm -f "$PIPE/orch-$rk.held" "$PIPE/orch-$rk.alert"
  python3 - "$issue" "$repo" "$QUEUE/orch-$rk.json" "$(date -u +%FT%TZ)" "$PIPE/orch-$rk.extra" <<'PY' 2>/dev/null
import json, sys
issue, repo, out, ts, ex = sys.argv[1:6]
try: extra = open(ex).read()
except Exception: extra = ''
json.dump({'issue': issue, 'repo': repo, 'extra': extra, 'reason': 'queued', 'queued_at': ts, 'not_before': 0}, open(out, 'w'))
PY
  slog "[auto-retry] #$issue — $cls cleared, relaunching ($n/$AUTORETRY_MAX)"
  report_status_async "auto-retry"
done

# 2. Drain queue (one item per tick, oldest queued_at first)
# Capacity is decided once per tick; the drain and the dispatch step (5) share the result, so a slot freed
# mid-tick never goes to a new agent-go issue while a queued ticket waits.
HAS_CAP=0
has_capacity && HAS_CAP=1
if [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ]; then
  now_epoch=$(date +%s)
  best_qf=""
  best_issue=""
  best_rk=""
  best_key=""

  for qf in "$QUEUE"/orch-*.json; do
    [ -e "$qf" ] || break
    not_before=$(python3 -c "import json; print(json.load(open('$qf')).get('not_before',0))" 2>/dev/null || echo 0)
    [ "$now_epoch" -lt "$not_before" ] && continue

    q_issue=$(python3 -c "import json; print(json.load(open('$qf'))['issue'])" 2>/dev/null)
    q_rk=${qf##*/orch-}; q_rk=${q_rk%.json}
    case "$q_rk" in *[!0-9]*) ;; *) q_rk=$(rk_of "$(python3 -c "import json; print(json.load(open('$qf'))['repo'])" 2>/dev/null)" "$q_issue") ;; esac   # legacy queue name: never write legacy names
    # Skip if tombstoned (stopped, held, or done)
    if [ -f "$PIPE/orch-$q_rk.stopped" ] || [ -f "$PIPE/orch-$q_rk.held" ] || [ -f "$PIPE/orch-$q_rk.done" ]; then
      rm -f "$qf"
      slog "[drain-skip] #$q_issue — tombstoned, purging queue entry"
      continue
    fi
    # Skip if already running
    if [ -f "$PIPE/orch-$q_rk.pid" ] && kill -0 "$(cat "$PIPE/orch-$q_rk.pid")" 2>/dev/null; then
      rm -f "$qf"
      continue
    fi

    # Order key: queued_at epoch (fallback: file mtime when missing/unparseable), then issue number
    q_key=$(python3 -c "
import json, os, datetime
f='$qf'
try:
    t=datetime.datetime.strptime(json.load(open(f))['queued_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
except Exception:
    t=os.path.getmtime(f)
print('%d %d' % (int(t), int('$q_issue')))
" 2>/dev/null)
    [ -z "$q_key" ] && q_key="$(stat -c %Y "$qf" 2>/dev/null || stat -f %m "$qf") ${q_issue//[!0-9]/}"
    if [ -z "$best_qf" ] || python3 -c "import sys; a=tuple(map(int,'$q_key'.split())); b=tuple(map(int,'$best_key'.split())); sys.exit(0 if a<b else 1)"; then
      best_qf="$qf"
      best_issue="$q_issue"
      best_rk="$q_rk"
      best_key="$q_key"
    fi
  done

  if [ -n "$best_qf" ]; then
    q_repo=$(python3 -c "import json; print(json.load(open('$best_qf'))['repo'])" 2>/dev/null)
    q_extra=$(python3 -c "import json; print(json.load(open('$best_qf')).get('extra',''))" 2>/dev/null)
    q_reason=$(python3 -c "import json; print(json.load(open('$best_qf')).get('reason','queued'))" 2>/dev/null)
    restart_n=0
    if [ "$q_reason" = "auto-restart" ] && [ -f "$PIPE/orch-$best_rk.restarts" ]; then
      restart_n=$(python3 -c "import json; print(json.load(open('$PIPE/orch-$best_rk.restarts')).get('count',0))" 2>/dev/null || echo 0)
    fi

    q_wait=$(python3 -c "
import json, datetime, time
try:
    t = datetime.datetime.strptime(json.load(open('$best_qf'))['queued_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    print(max(0, int(time.time() - t)))
except Exception:
    pass
" 2>/dev/null)
    # #178: a cap exit is not counted, so count may be 0; the relaunch still needs its (cap) preamble
    [ "$q_reason" = "auto-restart" ] && [ "$restart_n" -eq 0 ] && [ -f "$PIPE/orch-$best_rk.cap-exit" ] && restart_n=1
    do_launch "$q_repo" "$best_issue" "$q_extra" "$restart_n" "$q_reason" "$q_wait" "$best_rk"
    case $? in
      0) rm -f "$best_qf"; launched=1 ;;
      1) rm -f "$best_qf" ;;   # #438: the other host holds the claim; drop our queue entry
      *) : ;;                  # #438: claim unreadable; keep the entry for the next tick
    esac
  fi
fi

# 3. Label lifecycle — agent-in-progress means "an orchestrator owns this somewhere"; drop it once this machine
#    finished (done), parked (held: gate or escalation), stopped, or dead with no pending relaunch.
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  rk=$(basename "$f" .pid); rk=${rk#orch-}; issue=${rk##*-}   # <owner>_<repo>-<N>; an unmigrated legacy bare <N> reads as is
  repo=$(cat "$PIPE/orch-$rk.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue
  kill -0 "$(cat "$f")" 2>/dev/null && continue
  if   [ -f "$PIPE/orch-$rk.done" ];    then clear_in_progress "$repo" "$issue" done "$rk"
  elif [ -f "$PIPE/orch-$rk.held" ];    then clear_in_progress "$repo" "$issue" held "$rk"
  elif [ -f "$PIPE/orch-$rk.stopped" ]; then clear_in_progress "$repo" "$issue" stopped "$rk"
  elif [ ! -f "$QUEUE/orch-$rk.json" ]; then
    # #208: step 1 owns a fresh death (it queues the restart); act only once it has logged the exit, or for
    # pre-#138 runs that never get a run-id.
    if [ -f "$PIPE/orch-$rk.exit-logged" ] || [ ! -f "$PIPE/orch-$rk.run-id" ]; then
      clear_in_progress "$repo" "$issue" "dead-no-queue" "$rk"
      slog "[label] #$issue — process dead, no queue entry, cleared orphaned label"
    else
      slog "[label] #$issue — process dead, exit not yet handled by step 1; label kept"
      pipeline_event label_clear_deferred --arg level warn --arg route supervisor/step3 --argjson issue "$issue" \
        --arg release "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || echo unknown)"
    fi
  fi
done

# 3b. Intake — triage raw staff feedback (#114): one `user-feedback-intake` issue per tick from DISPATCH_REPOS, claimed like
#     step 5, label swapped to agent-in-progress, `claude --agent intake -p` launched detached. State is separate from the
#     orchestrator's (PIPE/intake-<owner_repo>-<n>.*) but counts against MAX_CONCURRENT. A run that exits with no [intake]
#     marker gets one recovery launch; a second failure posts a NOTE, re-adds the label once and parks it locally (.gaveup).
intake_key() { printf 'intake-%s-%s' "${1//\//_}" "$2"; }
intake_launch() {  # <owner/repo> <local path> <issue> <prompt>
  local k; k=$(intake_key "$1" "$3")
  echo 0 > "$PIPE/$(run_key "$1" "$3")-intake-before.txt"; rm -f "$PIPE/$k.exit" "$PIPE/$k.exit-seen"
  # #176: remember a source:sentry issue at launch, so the agent removing the label cannot turn the agent-go strip into a no-op
  case " $(gh issue view "$3" --repo "$1" --json labels --jq '[.labels[].name] | join(" ")' 2>/dev/null) " in
    *" source:sentry "*) touch "$PIPE/$k.sentry" ;; esac
  ( cd "$PIPE" && PIPELINE_ISSUE="$3" PIPELINE_AGENT=intake PIPELINE_REPO="$1" PIPE="$PIPE" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    nohup $SETSID bash -c 'claude --dangerously-skip-permissions --agent intake -p "$1"; echo $? > "$2"' _ "$4" "$PIPE/$k.exit" \
    >> "$PIPE/$k.log" 2>&1 9>&- & echo $! > "$PIPE/$k.pid" )
  echo "$2" > "$PIPE/$k.path"; echo "$1 $3" > "$PIPE/$k.id"
  echo $(( $(cat "$PIPE/$k.attempts" 2>/dev/null || echo 0) + 1 )) > "$PIPE/$k.attempts"
  slog "[intake] $1#$3 launched (attempt $(cat "$PIPE/$k.attempts"))"
}
# code-enforced gate (#176): the intake agent reads attacker-influenced text, so a source:sentry issue never keeps agent-go
# unless SENTRY_AUTO_GO=1, whatever the agent did. Returns 1 when the label read fails (caller retries next tick), else 0.
sentry_strip_go() {  # <owner/repo> <issue>
  [ "${SENTRY_AUTO_GO:-0}" = 1 ] && return 0
  local lbls k; k=$(intake_key "$1" "$2")
  lbls=$(gh issue view "$2" --repo "$1" --json labels --jq '[.labels[].name] | join(" ")' 2>/dev/null) || {
    slog "[intake] $1#$2 label read failed — will retry the source:sentry $LABEL_GO strip next tick"; return 1; }
  # sentry = recorded at launch (survives the agent removing the label) OR labelled now
  if [ -e "$PIPE/$k.sentry" ]; then lbls="$lbls source:sentry"; fi
  case " $lbls " in *" source:sentry "*)
    case " $lbls " in *" $LABEL_GO "*)
      if gh issue edit "$2" --repo "$1" --remove-label "$LABEL_GO" >/dev/null 2>&1; then
        slog "[intake] $1#$2 source:sentry carried $LABEL_GO with SENTRY_AUTO_GO=0 — removed"
      else
        slog "[intake] $1#$2 failed to remove $LABEL_GO from source:sentry issue — will retry next tick"; return 1
      fi ;;
    esac ;;
  esac
  return 0
}
INTAKE_RE=$(marker_re intake | jq -Rs .)
for idf in "$PIPE"/intake-*.id; do   # runs that have exited: healthy -> clear state; no marker -> recover once, then give up
  [ -e "$idf" ] || break
  k=$(basename "$idf" .id); read -r i_repo i_num < "$idf"; i_path=$(cat "$PIPE/$k.path")
  if kill -0 "$(cat "$PIPE/$k.pid" 2>/dev/null)" 2>/dev/null; then
    sentry_strip_go "$i_repo" "$i_num" || launched=1   # live run: strip an injected agent-go before step 5 can dispatch it (also strips a hand-added one until intake finishes); a failed strip holds dispatch this tick
    continue
  fi
  # done = a terminal marker (a NEEDS INFO-only run that died before labelling is not done) or the issue already carries user-feedback
  have=$(gh issue view "$i_num" --repo "$i_repo" --json comments,labels \
    --jq "([.comments[].body | split(\"\\n\")[0] | select(test(\"^\\\\*\\\\*\\\\[intake\\\\] (TRIAGED BUG|TRIAGED IDEA|DUPLICATE|NOISE|BLOCKED)\"))] | length) + ([(.labels // [])[].name | select(. == \"user-feedback\")] | length)" 2>/dev/null) || continue
  if [ "${have:-0}" -gt 0 ]; then
    sentry_strip_go "$i_repo" "$i_num" || { launched=1; continue; }   # keep state so the next tick retries the strip; hold dispatch this tick
    gh issue edit "$i_num" --repo "$i_repo" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1
    rm -f "$PIPE/$k".{id,pid,path,exit,exit-seen,attempts,sentry}; slog "[intake] $i_repo#$i_num done"
  elif [ ! -e "$PIPE/$k.exit-seen" ]; then
    touch "$PIPE/$k.exit-seen"   # one grace tick: a slow marker or a lagging gh read must not trigger a recovery run
  elif [ "$(cat "$PIPE/$k.attempts" 2>/dev/null || echo 1)" -lt 2 ]; then
    [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ] || continue
    intake_launch "$i_repo" "$i_path" "$i_num" "Triage $i_repo#$i_num as the intake agent. A previous run exited without posting an [intake] handoff marker: check the issue state with gh, finish the triage if it is incomplete, and post the handoff marker."
    launched=1
  else
    sentry_strip_go "$i_repo" "$i_num" || { launched=1; continue; }   # keep state (no .gaveup) so the next tick retries the strip; hold dispatch this tick
    gh issue comment "$i_num" --repo "$i_repo" --body "**[supervisor] NOTE** intake ran twice without a handoff marker; the issue is back in the intake queue for manual attention." >/dev/null 2>&1
    gh issue edit "$i_num" --repo "$i_repo" --remove-label "$LABEL_IN_PROGRESS" --add-label user-feedback-intake >/dev/null 2>&1
    rm -f "$PIPE/$k".{id,pid,path,exit,exit-seen,sentry}; touch "$PIPE/$k.gaveup"; slog "[intake] $i_repo#$i_num gave up after 2 runs without a marker"
  fi
done
if [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ] && power_ok; then
  cutoff=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=$CLAIM_WINDOW_SECS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  for entry in "${DISPATCH_REPOS[@]}"; do
    [ "$launched" -ge 1 ] && break
    owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
    case "$owner_repo" in */Business-Intelligence) continue ;; esac
    [ -d "$local_path/.git" ] || continue
    for num in $(gh issue list --repo "$owner_repo" --state open --label user-feedback-intake --limit 50 --json number,labels \
        --jq ".[] | select([.labels[].name] | index(\"$LABEL_IN_PROGRESS\") | not) | .number" 2>/dev/null); do
      case "$num" in ''|*[!0-9]*) continue ;; esac
      k=$(intake_key "$owner_repo" "$num"); [ -e "$PIPE/$k.id" ] || [ -e "$PIPE/$k.gaveup" ] && continue
      ts=$(date -u +%FT%TZ)
      gh issue comment "$num" --repo "$owner_repo" --body "**[supervisor] NOTE** claim: $HOST $ts" >/dev/null 2>&1 || continue
      sleep "$CLAIM_SETTLE_SECS"
      winner=$(claim_winner "$local_path" "$num")
      [ "$winner" = "$HOST" ] || { slog "[intake] $owner_repo#$num — lost claim to ${winner:-?}"; continue; }
      gh issue edit "$num" --repo "$owner_repo" --add-label "$LABEL_IN_PROGRESS" --remove-label user-feedback-intake >/dev/null 2>&1
      rm -f "$PIPE/$k.attempts" "$PIPE/$k.sentry"
      intake_launch "$owner_repo" "$local_path" "$num" "Triage $owner_repo#$num as the intake agent."
      launched=1; break
    done
  done
fi

# 3c. Spec — PM-only run (#115) for one `user-feedback-needs-spec` idea: claim, swap in agent-in-progress, launch `claude --agent product-manager -p`.
#     Never adds agent-go and never starts an orchestrator. When the PM exits, drop agent-in-progress + needs-spec and add agent-proposed (JP's digest).
#     Any PM routing marker except REJECTED blocks a launch, as do two REJECTED needs-spec (a PM REJECTED needs-spec is how a fix reaches here). State: PIPE/spec-<owner_repo>-<n>.*
spec_key() { printf 'spec-%s-%s' "${1//\//_}" "$2"; }
spec_pm_markers() {  # <owner/repo> <issue> → PM routing markers other than REJECTED, +1 once two REJECTED needs-spec are on the issue (re-reject loop stop)
  gh issue view "$2" --repo "$1" --json comments 2>/dev/null | jq --arg re "$(marker_re product-manager)" '[.comments[].body | split("\n")] as $c
    | ([$c[] | select(.[0] | test($re) and (test("\\] REJECTED") | not))] | length)
    + (if ([$c[] | select((.[0] | test("^\\*\\*\\[(product-manager|fullstack-developer)\\] REJECTED")) and ((.[1] // "") | test("^Reason: needs-spec")))] | length) >= 2 then 1 else 0 end)' 2>/dev/null
}
for idf in "$PIPE"/spec-*.id; do   # exited PM runs: marker posted -> hand the spec to JP; none -> one retry, then park
  [ -e "$idf" ] || break
  k=$(basename "$idf" .id); read -r s_repo s_num < "$idf"
  kill -0 "$(cat "$PIPE/$k.pid" 2>/dev/null)" 2>/dev/null && continue
  m=$(spec_pm_markers "$s_repo" "$s_num"); case "$m" in ''|*[!0-9]*) continue ;; esac   # failed gh/jq lookup: act on nothing, retry next tick
  if [ "$m" != 0 ]; then
    gh issue edit "$s_num" --repo "$s_repo" --remove-label "$LABEL_IN_PROGRESS" --remove-label user-feedback-needs-spec --add-label "$LABEL_PROPOSED" >/dev/null 2>&1
    rm -f "$PIPE/$k".{id,pid,path,attempts}; slog "[spec] $s_repo#$s_num spec written, moved to $LABEL_PROPOSED"
  else
    gh issue edit "$s_num" --repo "$s_repo" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1; rm -f "$PIPE/$k".{id,pid,path}
    [ "$(cat "$PIPE/$k.attempts" 2>/dev/null || echo 1)" -ge 2 ] && { touch "$PIPE/$k.gaveup"; slog "[spec] $s_repo#$s_num gave up: no PM marker after 2 runs"; }
  fi
done
if [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ] && power_ok; then
  cutoff=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=$CLAIM_WINDOW_SECS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  for entry in "${DISPATCH_REPOS[@]}"; do
    [ "$launched" -ge 1 ] && break
    owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
    case "$owner_repo" in */Business-Intelligence) continue ;; esac
    [ -d "$local_path/.git" ] || continue
    for num in $(gh issue list --repo "$owner_repo" --state open --label user-feedback-needs-spec --limit 50 --json number,labels \
        --jq ".[] | select([.labels[].name] | (index(\"$LABEL_IN_PROGRESS\") or index(\"$LABEL_GO\") or index(\"source:sentry\")) | not) | .number" 2>/dev/null); do
      case "$num" in ''|*[!0-9]*) continue ;; esac
      k=$(spec_key "$owner_repo" "$num"); [ -e "$PIPE/$k.id" ] || [ -e "$PIPE/$k.gaveup" ] && continue
      [ "$(spec_pm_markers "$owner_repo" "$num")" = 0 ] || continue
      gh issue comment "$num" --repo "$owner_repo" --body "**[supervisor] NOTE** claim: $HOST $(date -u +%FT%TZ)" >/dev/null 2>&1 || continue
      sleep "$CLAIM_SETTLE_SECS"
      winner=$(claim_winner "$local_path" "$num")
      [ "$winner" = "$HOST" ] || { slog "[spec] $owner_repo#$num — lost claim to ${winner:-?}"; continue; }
      gh issue edit "$num" --repo "$owner_repo" --add-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1
      ( cd "$PIPE" && PIPELINE_ISSUE="$num" PIPELINE_AGENT=product-manager PIPELINE_REPO="$owner_repo" PIPE="$PIPE" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
        nohup $SETSID bash -c 'claude --dangerously-skip-permissions --agent product-manager -p "$1"; echo $? > "$2"' _ \
        "Write the spec for $owner_repo#$num as the product-manager (spec-only run for a user-feedback idea): do not add agent-go; do not file dependency follow-ups on this issue; post your READY marker." "$PIPE/$k.exit" \
        >> "$PIPE/$k.log" 2>&1 9>&- & echo $! > "$PIPE/$k.pid" )
      echo "$owner_repo $num" > "$PIPE/$k.id"; echo $(( $(cat "$PIPE/$k.attempts" 2>/dev/null || echo 0) + 1 )) > "$PIPE/$k.attempts"
      slog "[spec] $owner_repo#$num launched (attempt $(cat "$PIPE/$k.attempts"))"; launched=1; break
    done
  done
fi

# 3d. Goal step (#195) — goal pids are coordinators: not in count_running, never set the orchestrator `launched` flag.
goal_step

# 3e. Promote deferred children (#315) — a ticket filed with the PM deferral NOTE ("approval inherited from <ref> — agent-go deferred:
#     start-gate #N open") gets agent-go once every start-gate is CLOSED as completed. Launch permission only: no JP-only gate is answered here.
#     Only deferral NOTEs from OWNER/MEMBER/COLLABORATOR comments count (public repos: outsiders cannot trigger a launch).
#     Never Business-Intelligence, never source:sentry; a gate closed "not planned" is left for JP. Idempotent: the supervisor NOTE stops repeats.
promote_gate_state() {  # <owner/repo> <gate ref owner/repo#N> → open | completed | notplanned | error
  local g=$2 gr gn st
  gr="${g%#*}"; gn="${g##*#}"
  st=$(gh issue view "$gn" --repo "$gr" --json state,stateReason --jq '[.state, (.stateReason // "")] | join(" ")' 2>/dev/null) || { echo error; return; }
  case "$st" in
    "OPEN "*|"REOPENED "*) echo open ;;
    "CLOSED COMPLETED") echo completed ;;
    "CLOSED "*) echo notplanned ;;
    *) echo error ;;
  esac
}
promote_deferred() {
  local entry owner_repo line num ref gates g st ok why seen
  for entry in "${DISPATCH_REPOS[@]}"; do
    owner_repo="${entry%%:*}"
    case "$owner_repo" in */Business-Intelligence) continue ;; esac
    while IFS=$'\t' read -r num ref gates; do
      case "$num" in ''|*[!0-9]*) continue ;; esac
      ok=1; why=""
      for g in $gates; do
        st=$(promote_gate_state "$owner_repo" "$g")
        case "$st" in
          completed) ;;
          open) ok=0; break ;;
          notplanned) ok=0; why="start-gate $g closed as not planned, left for JP"; break ;;
          *) ok=0; why="start-gate $g state read failed, will retry"; break ;;
        esac
      done
      if [ "$ok" -ne 1 ]; then
        if [ -n "$why" ]; then
          seen="promote-${owner_repo//\//_}-$num.${why%%,*}"; seen="$PIPE/${seen//[ #\/]/_}"
          [ -e "$seen" ] || { slog "[promote] $owner_repo#$num — not promoted: $why"; case "$why" in *"read failed"*) autoretry_alert "$num" "promote $owner_repo: $why" ;; esac; : > "$seen"; }
        fi
        continue
      fi
      if gh issue edit "$num" --repo "$owner_repo" --add-label "$LABEL_GO" --remove-label "$LABEL_PROPOSED" >/dev/null 2>&1; then
        gh issue comment "$num" --repo "$owner_repo" --body "**[supervisor] NOTE** approval inherited from $ref — start-gate #${gates##*#} closed" >/dev/null 2>&1 \
          || slog "[promote] $owner_repo#$num — $LABEL_GO added but promotion NOTE post failed"
        rm -f "$PIPE/promote-${owner_repo//\//_}-$num.labelfail"
        slog "[promote] $owner_repo#$num — start-gate(s) closed, added $LABEL_GO (approval inherited from $ref)"
      else
        slog "[promote] $owner_repo#$num — failed to add $LABEL_GO, will retry next tick"
        seen="$PIPE/promote-${owner_repo//\//_}-$num.labelfail"
        [ -e "$seen" ] || { autoretry_alert "$num" "promote $owner_repo: failed to add $LABEL_GO"; : > "$seen"; }
      fi
    done < <(gh issue list --repo "$owner_repo" --state open --limit 100 --json number,body,labels,comments --jq '
        .[] | ([.labels[].name]) as $l
        | select(($l | index("'"$LABEL_GO"'") | not) and ($l | index("'"$LABEL_IN_PROGRESS"'") | not) and ($l | index("source:sentry") | not))
        | select([.comments[].body | split("\n")[0] | select(test("^\\*\\*\\[supervisor\\] NOTE\\*\\* approval inherited from .* — start-gate #[0-9]+ closed$"))] | length == 0)
        | [.comments[] | select((.authorAssociation // "OWNER") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body | split("\n")[0] | capture("^\\*\\*\\[product-manager\\] NOTE\\*\\* approval inherited from (?<ref>[^ ]+) — agent-go deferred: start-gate (?<g>[A-Za-z0-9._/-]*#[0-9]+) open$")] as $d
        | select($d | length > 0)
        | ([$d[].g, (.body | [scan("Depends on ([A-Za-z0-9._/-]*#[0-9]+) for starting work") | .[0]][])]
            | map(if startswith("#") then "'"$owner_repo"'" + . else . end) | unique) as $gs
        | [.number, $d[0].ref, ($gs | join(" "))] | @tsv' 2>/dev/null)
  done
}
if [ "${#DISPATCH_REPOS[@]}" -gt 0 ]; then promote_deferred; fi

# 4. Label reconciliation — catch orphaned agent-in-progress labels that have no local state at all
#    (e.g. /tmp was cleared, or a run from another machine died). Only clear if no marker movement for 30+ min.
STALE_LABEL_SECS=1800
if [ "${#DISPATCH_REPOS[@]}" -gt 0 ]; then
  for entry in "${DISPATCH_REPOS[@]}"; do
    owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
    [ -d "$local_path/.git" ] || continue
    orphans=$(gh issue list --repo "$owner_repo" --state open --label "$LABEL_IN_PROGRESS" --limit 50 --json number --jq '.[].number' 2>/dev/null) || continue
    for num in $orphans; do
      rk=$(run_key "$owner_repo" "$num")
      # Skip if we have a live process or queue entry
      # #208: any local pid file, alive or not, means steps 1/3 own this run
      [ -f "$PIPE/orch-$rk.pid" ] && continue
      [ -f "$QUEUE/orch-$rk.json" ] && continue
      [ -e "$PIPE/$(intake_key "$owner_repo" "$num").id" ] && continue   # an intake run (3b) owns it
      [ -e "$PIPE/spec-${owner_repo//\//_}-$num.id" ] && continue   # a spec run (3c) owns it
      # Check marker staleness — only clear if no movement for STALE_LABEL_SECS
      # Same call also yields the latest "claim: <host>" comment: a claim naming another machine means it owns the run.
      info=$(issue_info_rest "$local_path" "$num") || { slog "[reconcile] $owner_repo#$num — issue read failed: ${info:-no error text}, skipped"; autoretry_alert "$num" "issue read" reconcile; continue; }
      view=$(printf '%s' "$info" | jq -r '((.comments[-1].createdAt // .updatedAt) // ""), ([.comments[] | select(.body | startswith("**[supervisor] NOTE** claim: "))] | last | .body // "" | split(" ") | .[3] // "")' 2>/dev/null) || { slog "[reconcile] $owner_repo#$num — issue read failed (unparseable), skipped"; continue; }
      last_comment_age=$(printf '%s\n' "$view" | sed -n 1p)
      claim_host=$(printf '%s\n' "$view" | sed -n 2p)
      [ -n "$claim_host" ] && [ "$claim_host" != "$HOST" ] && continue
      [ -n "$last_comment_age" ] || continue   # #326: no timestamp to judge staleness by — never clear on a blind read
      comment_epoch=$(to_epoch "$last_comment_age")
      age=$(( $(date +%s) - comment_epoch ))
      [ "$age" -lt "$STALE_LABEL_SECS" ] && continue
      (cd "$local_path" && gh issue edit "$num" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1) && \
        slog "[reconcile] $owner_repo#$num — cleared orphaned $LABEL_IN_PROGRESS (no local state, marker stale ${age}s)"
    done
  done
fi

# 5 (was 4). Shared dispatch — one agent-go issue per tick, claimed before launch so two machines never take the same one.
# JP (2026-10-18): only the goal-based pipeline launches work; SHARED_DISPATCH_ENABLED=0 turns this whole step off for
# ordinary agent-go tickets. Exception (JP 2026-10-19): a ticket labeled user-feedback (staff-reported bug/idea) still
# dispatches even then — feedback bugs must keep auto-fixing regardless of goal-gating.
if [ "$launched" -eq 0 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ]; then
  if ! power_ok; then
    slog "[dispatch] skipped — on battery power"
  elif [ "$HAS_CAP" -ne 1 ]; then
    :  # nothing to log every 2 min; status shows the running set
  else
    if [ "${SHARED_DISPATCH_ENABLED:-1}" = 1 ]; then
      dispatch_feedback_only=0
    else
      dispatch_feedback_only=1
      slog "[dispatch] SHARED_DISPATCH_ENABLED=0 — restricting this tick to $LABEL_FEEDBACK tickets"
    fi
    now_epoch=$(date +%s)
    cutoff=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=$CLAIM_WINDOW_SECS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    goal_skip_json=$( { goal_live_labels; goal_queued_labels; goal_foreign_labels; } 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null) || goal_skip_json='[]'
    [ -n "$goal_skip_json" ] || goal_skip_json='[]'
    for entry in "${DISPATCH_REPOS[@]}"; do
      [ "$launched" -ge 1 ] && break
      owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
      if [ ! -d "$local_path/.git" ]; then slog "[dispatch] $owner_repo — no local checkout at $local_path, skipping"; continue; fi
      # #320: a ticket carrying the label of a goal whose lead is live on THIS host is the lead's to dispatch; tickets in no goal,
      # and goal tickets whose lead is not live (fallback), stay dispatched here. A goal still queued has not started: its tickets wait.
      # Spread: with the default `hosts: both`, a goal whose lead is on the other host is dispatched here too (the claim comment keeps
      # a ticket on one host); a goal confined with `hosts: mac|vm` to the other host is skipped (goal_foreign_labels).
      # #247 begin
      # Release order (#247): in-progress dropped server-side before the cap (and again in jq), then sort by milestone
      # vX.Y.Z numerically asc, then issue number asc; no / staging / non-version / malformed milestone last (#247).
      # A failed listing or sort is logged with release/environment/route tags and alerted via notify_engineering (#247).
      rq_err=$(mktemp); rq_tags="release=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown) environment=${HOST} route=dispatch-order"
      dispatch_search="-label:\"$LABEL_IN_PROGRESS\""
      [ "$dispatch_feedback_only" -eq 1 ] && dispatch_search="$dispatch_search label:\"$LABEL_FEEDBACK\""
      candidates=$(gh issue list --repo "$owner_repo" --state open --label "$LABEL_GO" --limit 500 \
        --search "$dispatch_search" --json number,labels,milestone \
        --jq "[.[] | select([.labels[].name] | index(\"$LABEL_IN_PROGRESS\") | not) | select(([.labels[].name] | map(. as \$l | $goal_skip_json | index(\$l)) | any(. != null)) | not)]
          | map(. as \$i | ((((\$i.milestone.title? // \"\") | tostring) | capture(\"^v(?<a>[0-9]+)\\\\.(?<b>[0-9]+)\\\\.(?<c>[0-9]+)\")) // null) as \$v
            | {n: \$i.number, k: (if \$v then [0, (\$v.a|tonumber), (\$v.b|tonumber), (\$v.c|tonumber), \$i.number] else [1, 0, 0, 0, \$i.number] end)})
          | sort_by(.k) | .[].n" 2>"$rq_err") || {
        slog "[dispatch] $owner_repo — listing or release sort failed ($rq_tags): $(head -c 300 "$rq_err" | tr '\n' ' ')"
        notify_engineering 0 ":warning:" "dispatch listing/sort failed for $owner_repo ($rq_tags)" "$owner_repo"; rm -f "$rq_err"; continue; }
      rm -f "$rq_err"
      cand_n=$(printf '%s\n' "$candidates" | grep -c '[0-9]')
      [ "$cand_n" -ge 500 ] && slog "[dispatch] $owner_repo — candidate list reached the 500 cap; later tickets are not visible this tick"
      # #247 end
      for num in $candidates; do
        rk=$(run_key "$owner_repo" "$num")
        # local state: alive or queued here → not a candidate
        if [ -f "$PIPE/orch-$rk.pid" ] && kill -0 "$(cat "$PIPE/orch-$rk.pid")" 2>/dev/null; then continue; fi
        [ -f "$QUEUE/orch-$rk.json" ] && continue

        ts=$(date -u +%FT%TZ)
        (cd "$local_path" && gh issue comment "$num" --body "**[supervisor] NOTE** claim: $HOST $ts" >/dev/null 2>&1) || { slog "[dispatch] $owner_repo#$num — claim comment failed"; continue; }
        sleep "$CLAIM_SETTLE_SECS"
        winner=$(claim_winner "$local_path" "$num")
        if [ "$winner" != "$HOST" ]; then
          slog "[dispatch] $owner_repo#$num — lost claim to ${winner:-?}"
          continue
        fi
        # Won: a re-dispatch is JP's explicit "go again", so clear local tombstones like a manual launch does.
        rm -f "$PIPE/orch-$rk".{stopped,held,done,closed,marker,milestone,alert,label-cleared} "$PIPE/orch-$rk.restarts"
        out=$(LAUNCH_REASON=agent-go "$(dirname "${BASH_SOURCE[0]}")/orchestrate.sh" --force "$local_path" "$num" 2>&1 | tail -1)
        slog "[dispatch] $owner_repo#$num — claimed by $HOST, candidates=$cand_n, $out"
        launched=1
        break
      done
    done
  fi
fi

# 6. Slack reply bridge — handled by openclaw's native Slack event routing (agent "pipeline-bridge"
#    in ~/.openclaw/agents/, binding in openclaw.json for #engineering, requireMention: true), not
#    by this supervisor tick. The relay's own logic is two tracked files in this repo:
#    skills/orchestrate/pipeline-bridge-dispatch.sh (deterministic resolve + agent-go dispatch) and
#    skills/orchestrate/pipeline-bridge-prompt.md (the relay's instructions — manually installed to
#    ~/.openclaw/agents/pipeline-bridge/agent/IDENTITY.md, outside this repo; see README.md).

# 7. Status reconcile (issue #51) — refresh every listed ticket from GitHub (closed -> Completed, latest marker).
#    Throttled inside the script (600 s/host); backgrounded with fd 9 closed like report_status_async, so a slow
#    or failing pass never delays or fails the tick.
( "$HERE/reconcile-status.sh" >/dev/null 2>&1 & ) 9>&- || true

# 8. PM Slack DM poll (issue #117) — copy JP's DM replies onto the tickets the project-manager asked about.
#    No-op unless PM_SLACK_BOT_TOKEN is set on this host; backgrounded with fd 9 closed so it never delays or fails the tick.
( "$HERE/pm-slack.sh" poll >/dev/null 2>&1 & ) 9>&- || true

exec 9>&- 2>/dev/null
