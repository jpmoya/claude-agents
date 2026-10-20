#!/bin/bash
# Shared launcher helpers (issue #8), sourced by orchestrate.sh and supervisor.sh right after config.sh.
# Reads $PIPE, $MAX_CONCURRENT and $MEM_FLOOR_MB at call time, so it does not source config.sh itself.
# marker_last_jq needs marker_re from hooks/pipeline-markers.sh, which both launchers also source.
pipeline_host() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there

# run_key <owner/repo> <issue> — prints <owner>_<repo>-<N> (#318): the one key of every per-run, queue and stage file
# (orch-<key>.*, <key>-<agent>-before.txt, locked-<key>.txt, run-<key>-<agent>.log). Same-numbered tickets of two repos
# never share a file. The issue is kept as written (leading zeros included): no arithmetic, so no octal reading.
run_key() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  printf '%s-%s\n' "${1//\//_}" "$2"
}

# repo_slug <local checkout> — prints owner/repo from the checkout's origin (local, no network); falls back to gh.
repo_slug() {
  local u slug
  u=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || u=""
  slug=$(printf '%s' "$u" | sed -E -e 's#^.*github\.com[:/]+##' -e 's#\.git$##' -e 's#/+$##')
  case "$slug" in */*) ;; *) slug="" ;; esac
  [ -n "$slug" ] || slug=$(cd "$1" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null </dev/null) || slug=""
  printf '%s' "$slug"
}

# rk_of <local checkout> <issue> — run key of a checkout's ticket; "unknown" repo when it cannot be resolved.
rk_of() {
  local slug; slug=$(repo_slug "$1"); run_key "${slug:-unknown/unknown}" "$2"
}

# rk_pick <local checkout> <issue> — the file stem to read a run under: its run key, or (read-both fallback, #318) the
# legacy bare <N> when only a legacy set exists and its .repo names the same repo. Never returns another repo's legacy set.
rk_pick() {
  local k rf
  k=$(rk_of "$1" "$2")
  if [ ! -e "$PIPE/orch-$k.repo" ] && [ ! -e "$PIPE/orch-$k.pid" ]; then
    rf=$(cat "$PIPE/orch-$2.repo" 2>/dev/null) || rf=""
    if [ -n "$rf" ] && [ "$(repo_slug "$rf")" = "$(repo_slug "$1")" ]; then k=$2; fi
  fi
  printf '%s' "$k"
}

# migrate_legacy_runs — one-time, per run atomic rename of legacy orch-<N>.* sets to the run key (#318). A set is
# migrated only when orch-<N>.repo names a checkout whose origin resolves; a missing/unresolvable repo file leaves the
# whole set untouched. All files of the run move (orch-<N>.*, queue/orch-<N>.json, run-<N>-*.log, <N>-*-before|nags.txt)
# or none do: a destination that already exists, or a failed mv, leaves/restores the legacy names, records one error row
# (pipeline_event error: release = checkout SHA, host, route) and, once per run, goes to notify_engineering.
# TODO(next ticket): remove together with the read-both fallback.
migrate_legacy_runs() {
  local f n seen=" " repo slug key src dst pairs ok done_pairs i conflict rel
  for f in "$PIPE"/orch-[0-9]*.*; do
    [ -e "$f" ] || continue
    n=${f##*/orch-}; n=${n%%.*}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    repo=$(cat "$PIPE/orch-$n.repo" 2>/dev/null) || repo=""
    [ -n "$repo" ] || continue
    slug=$(repo_slug "$repo"); [ -n "$slug" ] || continue
    key=$(run_key "$slug" "$n")
    pairs=()
    for src in "$PIPE"/orch-"$n".* "$QUEUE/orch-$n.json" "$PIPE"/run-"$n"-*.log "$PIPE"/"$n"-*-before.txt "$PIPE"/"$n"-*-nags.txt; do
      [ -e "$src" ] || continue
      case "${src##*/}" in
        orch-"$n".*) dst="${src%/*}/orch-$key.${src##*/orch-$n.}" ;;
        run-"$n"-*) dst="${src%/*}/run-$key-${src##*/run-$n-}" ;;
        *) dst="${src%/*}/$key-${src##*/$n-}" ;;
      esac
      pairs+=("$src|$dst")
    done
    conflict=""
    for i in "${pairs[@]}"; do [ ! -e "${i#*|}" ] || conflict="${i#*|}"; done
    ok=1; done_pairs=()
    if [ -z "$conflict" ]; then
      for i in "${pairs[@]}"; do
        if mv "${i%%|*}" "${i#*|}" 2>/dev/null; then done_pairs+=("$i"); else ok=0; break; fi
      done
      if [ "$ok" = 0 ]; then for i in ${done_pairs[@]+"${done_pairs[@]}"}; do mv "${i#*|}" "${i%%|*}" 2>/dev/null; done; fi
    else ok=0; fi
    if [ "$ok" = 1 ]; then
      command -v slog >/dev/null 2>&1 && slog "[migrate] orch-$n.* -> orch-$key.* (${#pairs[@]} files)"
      continue
    fi
    # one error row and one alert per run key until it is resolved
    [ -e "$PIPE/migrate-error-$key" ] && continue
    : > "$PIPE/migrate-error-$key" 2>/dev/null || true
    rel=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || echo unknown)
    pipeline_event error --arg level error --arg route supervisor/migrate-run-key --arg release "$rel" \
      --arg msg "legacy run set orch-$n.* could not be renamed to orch-$key.*; left untouched" --argjson issue "$n"
    command -v slog >/dev/null 2>&1 && slog "[migrate] error: legacy orch-$n.* not renamed to $key (release=$rel)"
    command -v notify_engineering >/dev/null 2>&1 \
      && notify_engineering "$n" ":warning:" "Run-key migration failed; legacy files left untouched (release $rel)" "$slug" || true
  done
}

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid "$PIPE"/intake-*.pid; do   # intake runs (#114) count against MAX_CONCURRENT too
    [ -e "$f" ] || continue
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
  # #272: a `**[jp] SKIP MOCKUPS**` comment counts only from the issue author (top-level .author.login, else the first comment's author — every gh issue view feeding this now fetches `author`;
  # REST comments carry .user.login, gh CLI .author.login) AND with a second line `JP said: "<non-empty>"`; any other (incl. malformed author) is dropped.
  local skip='def lg: ((.author | objects | .login) // (.user | objects | .login)); ((lg // (.comments[0] | lg)) // null) as $ia | '
  skip="$skip"'[.comments[] | select((.body | type) == "string") | select((.body | split("\n")) as $l | if ($l[0] | rtrimstr("\r") | test("^\\*\\*\\[jp\\] SKIP MOCKUPS\\*\\*[[:space:]]*$")) then (($ia != null) and (lg == $ia) and (($l[1] // "" | rtrimstr("\r")) | test("^JP said: \".+\"$"))) else true end)'
  # a valid skip posted anywhere (even before the gate comment) supersedes a newest MOCKUPS PENDING APPROVAL
  printf '%s | .body | split("\\n")[0] | select(test(%s))] | if ((last // "") | contains("] MOCKUPS PENDING APPROVAL")) and (map(select(rtrimstr("\\r") | test("^\\\\*\\\\*\\\\[jp\\\\] SKIP MOCKUPS\\\\*\\\\*[[:space:]]*$"))) | length > 0) then . + ["**[jp] SKIP MOCKUPS**"] else . end | last // "none"' "$skip" "$(marker_re | jq -Rs .)"
}

marker_name_from_line() {  # <first line of a routing-marker comment | none> -> bare marker name ("TESTS APPROVED"), empty for none
  case "$1" in
    none|"") return 0 ;;
    *) printf '%s' "$1" | sed -e 's/^\*\*\[[^]]*\] //' -e 's/\*\*.*$//' -e 's/:.*$//' -e 's/[[:space:]]*$//' ;;
  esac
}

# write_title_marker <repo dir> <issue> <rm-title-on-fail 0|1> [<run_key>] — ONE gh call (--json title,comments) refreshes
# orch-<key>.title and orch-<key>.marker (key = run_key of the checkout's repo + issue). A failed fetch removes the marker (never stale); the title only when asked.
write_title_marker() {
  local repo=$1 issue=$2 rmtitle=${3:-0} rk=${4:-} info title line marker
  [ -n "$rk" ] || rk=$(rk_of "$repo" "$issue")
  info=$(cd "$repo" && gh issue view "$issue" --json title,author,comments 2>/dev/null </dev/null) || info=""
  title=$(printf '%s' "$info" | jq -r '.title // empty' 2>/dev/null) || title=""
  if [ -n "$title" ]; then printf '%s\n' "$title" > "$PIPE/orch-$rk.title"
  elif [ "$rmtitle" = 1 ]; then rm -f "$PIPE/orch-$rk.title"; fi
  marker=""
  if [ -n "$info" ]; then
    line=$(printf '%s' "$info" | jq -r "$(marker_last_jq)" 2>/dev/null) || {
      line=""; type slog >/dev/null 2>&1 && slog "[marker-parse] #$issue — jq failed reading markers; release=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown) environment=$(hostname -s 2>/dev/null || echo unknown) route=pipeline-lib/write_title_marker"; }
    marker=$(marker_name_from_line "$line")
  fi
  if [ -n "$marker" ]; then printf '%s\n' "$marker" > "$PIPE/orch-$rk.marker"; else rm -f "$PIPE/orch-$rk.marker"; fi
}

# limit_kind_of <file> — looks at the last 20 lines, case-insensitive: a `hit your … limit` line prints monthly_spend
# (contains "spend limit"), weekly (contains "weekly limit") or other; no match prints nothing.
limit_kind_of() {
  local line
  line=$(tail -n 20 "$1" 2>/dev/null | grep -iE 'hit your.*limit' | tail -1) || true
  [ -n "$line" ] || return 0
  case $(printf '%s' "$line" | tr '[:upper:]' '[:lower:]') in
    *"spend limit"*) echo monthly_spend ;;
    *"weekly limit"*) echo weekly ;;
    *) echo other ;;
  esac
}

# last_launch_segment_line <log> — prints the last non-empty line after the last `===== … LAUNCH … =====` header of a
# run/goal log (the whole file when there is no header); nothing when the log is missing. Used to classify an exit.
last_launch_segment_line() {
  [ -f "$1" ] || return 0
  awk '/^===== .* LAUNCH .* =====$/ {buf=""; next} {buf = buf $0 "\n"} END {printf "%s", buf}' "$1" 2>/dev/null \
    | awk 'NF {l=$0} END {print l}' 2>/dev/null
}

# pipeline_event <event> [jq --arg/--argjson pairs…] — appends one row (v, ts, host, event + the given fields) to
# $LOGDIR/events.jsonl. Any failure is swallowed: logging never blocks a launch or a supervisor tick.
pipeline_event() {
  local ev=${1:-}; shift 2>/dev/null || true
  local dir=${LOGDIR:-$HOME/logs/pipeline} row
  row=$(jq -nc --arg event "$ev" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(pipeline_host)" "$@" \
    '{v:1,ts:$ts,host:$host,event:$event} + ($ARGS.named | del(.event,.ts,.host))' 2>/dev/null) || return 0
  { mkdir -p "$dir" && printf '%s\n' "$row" >> "$dir/events.jsonl"; } 2>/dev/null || true
  return 0
}

# log_run_launch <owner/repo> <issue> <reason> <restart_n> <queue_wait_s|""> [<run_key>] — writes $PIPE/orch-<run_key>.run-id, clears
# .exit-logged and appends the run_launch row. Call right after the process is started.
log_run_launch() {
  local repo=$1 issue=$2 reason=$3 restart_n=${4:-0} qw=${5:-} rk=${6:-} run_id
  [ -n "$rk" ] || rk=$(run_key "${repo:-unknown/unknown}" "$issue")
  run_id="$(pipeline_host)-orch-$issue-$(date +%s)"
  rm -f "$PIPE/orch-$rk.exit-logged" 2>/dev/null
  printf '%s\n' "$run_id" > "$PIPE/orch-$rk.run-id" 2>/dev/null || true
  case "$qw" in ''|*[!0-9]*) qw=null ;; esac
  case "$issue" in ''|*[!0-9]*) return 0 ;; esac
  pipeline_event run_launch --arg run_id "$run_id" --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
    --argjson restart_n "${restart_n:-0}" --argjson queue_wait_s "$qw"
  return 0
}

# claim_winner <local_path> <issue> — prints the host of the earliest "**[supervisor] NOTE** claim: <host> <ts>" comment
# inside CLAIM_WINDOW_SECS (empty if none). Shared by dispatch and hand launch (#217). A failed comment read returns 1,
# prints nothing and records a claim_lookup_failed event (issue number only), so callers fail closed.
# claim_alert <issue> <stage> — best-effort Slack alert (existing SLACK_WEBHOOK_URL) for a claim-lookup failure. Host and
# issue number only; silent when no webhook is configured. Never fails the caller.
claim_alert() {
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"claim lookup failed (#${1:-0}, stage $2, host $(hostname -s)); launch refused\"}" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
}

# launch_alert <goal id> <issue> — best-effort Slack alert (existing SLACK_WEBHOOK_URL) when deliver.sh register could not
# launch. Goal id and issue number only (no instruction text). Never fails the caller.
launch_alert() {
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"deliver.sh register: launch failed for goal ${1:-?} (issue #${2:-0}, host $(hostname -s)); closed as stopped\"}" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
}

# cleanup_finished_worktree <local_repo_path> <issue> — removes THIS host's copy of a finished ticket's worktree, if
# any. Called at every terminal transition (issue closed, or a DEPLOYED/SPLIT/REJECTED marker), on every host, so a
# ticket built on one machine and merged by a deployer on the other still gets its leftover copy cleared (the deployer's
# own pre-merge removal in deployer.md only ever reaches the worktree on the host that runs the merge). Matches by the
# `issue-<N>-*` / `issue-<N>` directory convention under <repo>/.worktrees/ — never touches a reviewer/scratch worktree
# (those are the creating agent's own responsibility) or anything outside .worktrees/. Best-effort: logs and continues
# on failure (e.g. a background process still writing inside it) rather than blocking the caller's done/held bookkeeping.
cleanup_finished_worktree() {
  type slog >/dev/null 2>&1 || slog() { echo "$*" >&2; }
  local repo="$1" issue="$2" wt
  [ -n "$repo" ] && [ -n "$issue" ] && [ -d "$repo/.worktrees" ] || return 0
  for wt in "$repo"/.worktrees/issue-"$issue"-* "$repo"/.worktrees/issue-"$issue"; do
    [ -e "$wt" ] || continue
    if git -C "$repo" worktree remove --force "$wt" 2>>"$SLOG"; then
      slog "[worktree-cleanup] #$issue — removed $wt"
    else
      slog "[worktree-cleanup] #$issue — remove failed for $wt (left in place; will retry next terminal check)"
    fi
  done
  git -C "$repo" worktree prune 2>/dev/null || true
}

# claim_winner <local_path> <issue> [owner/repo] — the optional repo reads a claim on an issue of a repo other than the
# checkout's (the goal registry issue, #320); same comment shape, same window, same fail-closed behaviour.
claim_winner() {
  local path=$1 issue=$2 repo_arg="" cutoff out
  [ -z "${3:-}" ] || repo_arg="--repo $3"
  cutoff=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${CLAIM_WINDOW_SECS:-600}") \
    || { pipeline_event claim_lookup_failed --argjson issue "${issue:-0}" --arg stage cutoff; claim_alert "$issue" cutoff; return 1; }
  out=$(cd "$path" && gh issue view "$issue" $repo_arg --json comments \
    --jq "[.comments[] | select(.body | startswith(\"**[supervisor] NOTE** claim: \")) | select(.createdAt > \"$cutoff\")] | sort_by(.createdAt) | first | .body // \"\"" 2>/dev/null) \
    || { pipeline_event claim_lookup_failed --argjson issue "${issue:-0}" --arg stage gh; claim_alert "$issue" gh; return 1; }
  printf '%s\n' "$out" | awk '{print $4}'
}

# claim_winner_rest <owner/repo> <issue> — #438: claim_winner over REST (the supervisor's launch funnel must keep working while GraphQL
# is exhausted, #387). Same comment shape, same CLAIM_WINDOW_SECS window, same fail-closed return 1 on an unreadable list.
claim_winner_rest() {
  local cutoff out
  cutoff=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${CLAIM_WINDOW_SECS:-600}") \
    || { pipeline_event claim_lookup_failed --argjson issue "${2:-0}" --arg stage cutoff; claim_alert "$2" cutoff; return 1; }
  out=$(set -o pipefail; gh api "repos/$1/issues/$2/comments?per_page=100" --paginate 2>/dev/null | jq -rs --arg c "$cutoff" \
    '[.[][] | select(.body | startswith("**[supervisor] NOTE** claim: ")) | select((.created_at // .createdAt) > $c)] | sort_by(.created_at // .createdAt) | first | .body // ""') \
    || { pipeline_event claim_lookup_failed --argjson issue "${2:-0}" --arg stage gh; claim_alert "$2" gh; return 1; }
  printf '%s\n' "$out" | awk '{print $4}'
}

# canonicalize_repo_lists — a repo renamed on GitHub keeps redirecting for `gh repo view` but `gh issue list -R <old>` returns []
# (2026-10-19: quoting-tool -> sales-tool blinded the supervisor). For every DISPATCH_REPOS / SCAN_ONLY_REPOS entry, resolve the
# canonical owner/name with `gh repo view` (cached 1h in $PIPE/repo-canon) and rewrite the entry in place; log a loud WARN on a
# rename or on a repo that cannot be resolved (entry kept as configured). Uses slog when defined, else stderr.
repo_canon() {  # repo_canon <owner/repo> -> canonical owner/name (cached 1h in $PIPE/repo-canon); empty when unresolvable
  local cdir="${PIPE:-$HOME/.claude/pipeline}/repo-canon" cf canon=""
  mkdir -p "$cdir" 2>/dev/null; cf="$cdir/${1//\//__}"
  if [ -f "$cf" ] && [ -n "$(find "$cf" -mmin -60 2>/dev/null)" ]; then canon=$(cat "$cf"); fi
  if [ -z "$canon" ]; then
    canon=$(gh repo view "$1" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
    case "$canon" in */*) printf '%s' "$canon" > "$cf" ;; *) canon="" ;; esac
  fi
  printf '%s' "$canon"
}
canonicalize_repo_lists() {
  local arr i entry slug rest canon
  for arr in DISPATCH_REPOS SCAN_ONLY_REPOS; do
    eval "[ \${#$arr[@]} -gt 0 ]" 2>/dev/null || continue
    eval "n=\${#$arr[@]}"
    for ((i = 0; i < n; i++)); do
      eval "entry=\${$arr[$i]}"
      slug="${entry%%:*}"; rest=""; [ "$slug" != "$entry" ] && rest=":${entry#*:}"
      canon=$(repo_canon "$slug")
      if [ -z "$canon" ]; then
        _canon_warn "WARN [repo-canon] $arr entry '$slug' does not resolve on GitHub (deleted, renamed without redirect, or no access); it will return nothing until fixed"
      elif [ "$canon" != "$slug" ]; then
        _canon_warn "WARN [repo-canon] $arr entry '$slug' was renamed to '$canon'; using '$canon' (fix config.local.sh)"
        eval "$arr[$i]=\"\$canon\$rest\""
      fi
    done
  done
}
_canon_warn() { if declare -F slog >/dev/null 2>&1; then slog "$1"; else echo "$1" >&2; fi; }
