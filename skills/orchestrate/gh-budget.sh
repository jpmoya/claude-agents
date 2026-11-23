#!/bin/bash
# gh-budget.sh — sourced by config.sh, so every orchestrate script gets it. One shared GitHub API budget (5000/hr per bucket,
# one account) serves every session and pipeline script; the pipeline itself used to exhaust it (core limit at 0 on 2026-11-03).
# This file defines a `gh` shell FUNCTION that shadows the binary for the sourcing script (and its subshells; separate
# scripts source config.sh again). It adds, around `command gh "$@"`, and changes no result:
#   1. a call log   : one line per call in $GH_CALL_LOG (default $LOGDIR/gh-calls.log), size-capped, rotated by rotate-logs.sh
#                     "<epoch> <file>:<function> <class> <call|hit|skip> <subcommand or endpoint>"
#   2. a quota guard: `gh api rate_limit` (free) read at most once per GH_QUOTA_TTL_SECS, cached in $PIPE/gh-quota. Work has a class
#                     (GH_CLASS: essential | normal | optional; default normal). Remaining < GH_QUOTA_OPTIONAL_BELOW skips optional,
#                     < GH_QUOTA_ESSENTIAL_BELOW skips normal too (only essential runs), 0 skips every call until the reset.
#                     A skipped call returns 1 with one stderr line, like a failed call, without touching GitHub.
#   3. a read cache : GETs of issues/comments/milestones/labels/`issue view|list`/`repo view` are cached GH_CACHE_TTL_SECS in
#                     $PIPE/gh-cache (key: cwd + args); only rc 0 output is stored; any write call empties the cache.
#                     GH_NOCACHE=1 gh ... bypasses it (claim reads do). A single issue (`repos/<r>/issues/<n>`) and its
#                     comments are the one exception: they are kept with no TTL and survive across supervisor ticks,
#                     valid until gh_since_sync (#637, below) finds that issue changed — supervisor.sh calls it once
#                     per in-scope repo per tick instead of wiping the whole cache, so a tick where nothing changed
#                     re-reads nothing per-ticket, only that one list call per repo.
# GH_BUDGET_ENABLED=0 turns all three off (the test runner does; tests of this file turn it on). Bash 3.2 safe (macOS).

GH_BUDGET_ENABLED="${GH_BUDGET_ENABLED:-1}"
GH_QUOTA_TTL_SECS="${GH_QUOTA_TTL_SECS:-60}"
GH_QUOTA_OPTIONAL_BELOW="${GH_QUOTA_OPTIONAL_BELOW:-1500}"
GH_QUOTA_ESSENTIAL_BELOW="${GH_QUOTA_ESSENTIAL_BELOW:-300}"
GH_CACHE_TTL_SECS="${GH_CACHE_TTL_SECS:-60}"
GH_CALL_LOG_MAX_BYTES="${GH_CALL_LOG_MAX_BYTES:-8388608}"

_gh_budget_paths() {  # resolved lazily: tests and callers may set PIPE / LOGDIR after sourcing
  GH_QUOTA_FILE="${GH_QUOTA_FILE:-${PIPE:-$HOME/.claude/pipeline/state}/gh-quota}"
  GH_CACHE_DIR="${GH_CACHE_DIR:-${PIPE:-$HOME/.claude/pipeline/state}/gh-cache}"
  GH_CALL_LOG="${GH_CALL_LOG:-${LOGDIR:-$HOME/logs/pipeline}/gh-calls.log}"
}

# gh_class <essential|normal|optional> — class of the work that follows (exported so child scripts inherit it)
gh_class() { GH_CLASS="$1"; export GH_CLASS; }

# _gh_madrid <epoch> -> "YYYY-MM-DD HH:MM Europe/Madrid" (GNU date, then BSD date); times meant for JP are never UTC
_gh_madrid() {
  local e="$1" out
  case "$e" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  out=$(TZ=Europe/Madrid date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null) \
    || out=$(TZ=Europe/Madrid date -r "$e" '+%Y-%m-%d %H:%M' 2>/dev/null) || out=""
  [ -n "$out" ] || { printf 'unknown'; return 0; }
  printf '%s Europe/Madrid' "$out"
}

# _gh_scan_gqlq <field value> — #808: when the value is `query=<text>`, set the caller's (_gh_scan's, by bash dynamic scope) gqlq to
# `mutation` when <text> starts with "mutation" (after leading whitespace), "@" or "#", else `read`; any other field leaves it alone.
_gh_scan_gqlq() {
  case "$1" in
    query=*)
      local v="${1#query=}"
      v="${v#"${v%%[![:space:]]*}"}"
      # a query=@file value is read by gh from a file we cannot see, and a document that opens with a # comment may hide a mutation: both stay writes
      case "$v" in mutation*|@*|\#*) gqlq=mutation ;; *) [ "$gqlq" = mutation ] || gqlq=read ;; esac ;;
  esac
}

# _gh_scan <gh args...> — classify one call into globals (no subshell, so it is cheap):
#   _GH_SUB (log text), _GH_BUCKET (core|graphql|none), _GH_WRITE (0|1), _GH_CACHEABLE (0|1)
_gh_scan() {
  _GH_SUB=""; _GH_BUCKET=graphql; _GH_WRITE=0; _GH_CACHEABLE=0; _GH_ISSUE_REPO=""; _GH_ISSUE_NUM=""; _GH_LIST_REPO=""; _GH_WH_REPO=""; _GH_WH_NUM=""
  local first="${1:-}" second="${2:-}" a prev="" method=GET payload=0 path="" inputp=0 gqlq=""
  case "$first" in
    api)
      shift
      for a in "$@"; do
        if [ -n "$prev" ]; then
          case "$prev" in
            -X|--method) method="$a" ;;
            -f|-F|--field|--raw-field) payload=1; _gh_scan_gqlq "$a" ;;
            --input) payload=1; inputp=1 ;;
          esac
          prev=""; continue
        fi
        case "$a" in
          -X|--method|-f|-F|--field|--raw-field|--input|-H|--header|--jq|-q|--template|-t|--cache|--hostname|-p|--preview) prev="$a" ;;
          --method=*) method="${a#*=}" ;;
          --input=*) payload=1; inputp=1 ;;
          --field=*|--raw-field=*) payload=1; _gh_scan_gqlq "${a#*=}" ;;
          -f?*|-F?*) payload=1; _gh_scan_gqlq "${a#-?}" ;;   # attached value: -fquery=... / -Fnumber=1
          -X?*) method="${a#-X}" ;;                           # attached method: -XPOST
          -*) ;;
          *) [ -n "$path" ] || path="$a" ;;
        esac
      done
      path="${path%%\?*}"; path="${path#/}"
      _GH_SUB="api $path"
      case "$path" in
        graphql) _GH_BUCKET=graphql ;;
        rate_limit) _GH_BUCKET=none ;;
        *) _GH_BUCKET=core ;;
      esac
      case "$method" in GET|get) ;; *) _GH_WRITE=1 ;; esac
      # #808: a GraphQL call carrying only -f/-F fields whose query= value is not a mutation is a read (the goal-project reads);
      # --input, a mutation, a non-GET method and every non-graphql path with a payload stay writes.
      if [ "$payload" = 1 ]; then
        if [ "$path" = graphql ] && [ "$inputp" = 0 ] && [ "$gqlq" = read ]; then :; else _GH_WRITE=1; fi
      fi
      if [ "$_GH_WRITE" = 0 ]; then
        case "$path" in
          repos/*/issues|repos/*/issues/*|repos/*/milestones|repos/*/milestones/*|repos/*/labels|repos/*/labels/*|'repos/{owner}/{repo}') _GH_CACHEABLE=1 ;;
        esac
        # #637: a single issue (or its comments), or a repo's issues? scope list, is cached with no wall-clock
        # expiry below (in a process that synced it) — gh_since_sync is what invalidates it, regardless of which
        # cwd/arg shape read it. Not `.../milestones`: a milestone edit does not bump any issue's updated_at.
        case "$path" in
          repos/*/issues/[0-9]*)
            _GH_ISSUE_REPO="${path#repos/}"; _GH_ISSUE_REPO="${_GH_ISSUE_REPO%%/issues/*}"
            _GH_ISSUE_NUM="${path#*/issues/}"; _GH_ISSUE_NUM="${_GH_ISSUE_NUM%%/*}"
            case "$_GH_ISSUE_NUM" in ''|*[!0-9]*) _GH_ISSUE_REPO=""; _GH_ISSUE_NUM="" ;; esac
            ;;
          repos/*/issues)
            _GH_LIST_REPO="${path#repos/}"; _GH_LIST_REPO="${_GH_LIST_REPO%%/issues}"
            ;;
        esac
      fi ;;
    auth|config|alias|extension|completion|help|version|--version|status|browse) _GH_SUB="$first"; _GH_BUCKET=none ;;
    run|workflow|release|cache|secret|variable|search) _GH_SUB="$first $second"; _GH_BUCKET=core ;;
    *) _GH_SUB="$first $second" ;;
  esac
  case "$first" in
    api|auth|config|alias|extension|completion|help|version|--version|status|browse) ;;
    *)
      case "$second" in
        edit|comment|close|reopen|create|merge|delete|lock|unlock|transfer|pin|unpin|develop|ready|review|rerun|cancel|label|set|remove|add|rename|fork|sync|archive|unarchive) _GH_WRITE=1 ;;
      esac
      if [ "$_GH_WRITE" = 0 ]; then
        case "$first $second" in "issue view"|"issue list"|"repo view") _GH_CACHEABLE=1 ;; esac
        # #773 AC8: with the webhook queue on, these reads (and `pr list`, never cached otherwise) may be served from the cache for up to
        # WEBHOOK_LIST_MAX_AGE_SECS while the repo is webhook_trusted; any event for the repo drops them (see _gh_wh_classify).
        if [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ]; then
          case "$first $second" in "issue view"|"issue list"|"repo view"|"pr list") _gh_wh_classify "$@" ;; esac
        fi
      fi ;;
  esac
  return 0
}

# _gh_wh_classify <gh args...> — sets _GH_WH_REPO (the repo the read is about: -R/--repo, else the checkout's origin, read locally with
# no API call), _GH_WH_NUM (the issue number of `issue view <n>`), and makes `pr list` cacheable. Unknown repo = not event-trusted.
_gh_wh_classify() {
  local first="$1" second="$2" a prev="" repo="" num="" url
  shift 2
  for a in "$@"; do
    if [ -n "$prev" ]; then repo="$a"; prev=""; continue; fi
    case "$a" in
      -R|--repo) prev=1 ;;
      --repo=*) repo="${a#--repo=}" ;;
      -*) ;;
      *) [ -n "$num" ] || num="$a" ;;
    esac
  done
  if [ -z "$repo" ]; then
    url=$(git config --get remote.origin.url 2>/dev/null) || url=""
    repo=$(printf '%s' "$url" | sed -E -e 's#^.*github\.com[:/]+##' -e 's#\.git$##' -e 's#/+$##')
  fi
  case "$repo" in */*/*|''|*[!A-Za-z0-9._/-]*) return 0 ;; */*) ;; *) return 0 ;; esac
  _GH_WH_REPO="$repo"
  case "$first $second" in
    "issue view") case "$num" in ''|*[!0-9]*) _GH_WH_NUM="" ;; *) _GH_WH_NUM="$num" ;; esac ;;
    "pr list") _GH_CACHEABLE=1 ;;
  esac
}

_gh_log() {  # _gh_log <class> <call|hit|skip> — fixed-format line; never fails the caller
  [ -n "${GH_CALL_LOG:-}" ] || _gh_budget_paths
  _GH_LOGN=$(( ${_GH_LOGN:-0} + 1 ))
  if [ $(( _GH_LOGN % 200 )) -eq 1 ]; then   # size cap, checked every 200 calls (rotate-logs.sh does the real rotation)
    mkdir -p "${GH_CALL_LOG%/*}" 2>/dev/null
    _GH_LOG_FULL=0
    if [ -f "$GH_CALL_LOG" ]; then
      local sz; sz=$(wc -c < "$GH_CALL_LOG" 2>/dev/null) || sz=0
      [ "${sz:-0}" -gt "$GH_CALL_LOG_MAX_BYTES" ] && _GH_LOG_FULL=1
    fi
  fi
  [ "${_GH_LOG_FULL:-0}" = 1 ] && return 0
  local _src="${BASH_SOURCE[2]:-main}"
  printf '%s %s:%s %s %s %s\n' "$(date +%s)" "${_src##*/}" "${FUNCNAME[2]:-main}" "$1" "$2" "$_GH_SUB" >> "$GH_CALL_LOG" 2>/dev/null || true
}

# gh_quota_read — fill GHQ_CORE / GHQ_CORE_RESET / GHQ_GQL / GHQ_GQL_RESET (-1 = unknown) from the cache file, refreshing it with
# `gh api rate_limit` when older than GH_QUOTA_TTL_SECS (or when a cached reset time has passed). A failed refresh keeps the old
# numbers and still stamps the attempt, so a broken read is retried once per TTL, not once per call.
gh_quota_read() {
  _gh_budget_paths
  local now at c cr g gr out
  now=$(date +%s)
  GHQ_CORE=-1; GHQ_CORE_RESET=0; GHQ_GQL=-1; GHQ_GQL_RESET=0
  at=0
  if [ -f "$GH_QUOTA_FILE" ]; then
    read -r at c cr g gr < "$GH_QUOTA_FILE" 2>/dev/null || at=0
    case "$at$c$cr$g$gr" in *[!0-9-]*|'') at=0; c=-1; cr=0; g=-1; gr=0 ;; esac
    GHQ_CORE=${c:--1}; GHQ_CORE_RESET=${cr:-0}; GHQ_GQL=${g:--1}; GHQ_GQL_RESET=${gr:-0}
  fi
  if [ $(( now - at )) -ge "$GH_QUOTA_TTL_SECS" ] \
     || { [ "$GHQ_CORE" -ge 0 ] && [ "$GHQ_CORE_RESET" -gt 0 ] && [ "$GHQ_CORE_RESET" -le "$now" ]; } \
     || { [ "$GHQ_GQL" -ge 0 ] && [ "$GHQ_GQL_RESET" -gt 0 ] && [ "$GHQ_GQL_RESET" -le "$now" ]; }; then
    out=$(command gh api rate_limit --jq '[.resources.core.remaining, .resources.core.reset, .resources.graphql.remaining, .resources.graphql.reset] | @tsv' 2>/dev/null </dev/null) || out=""
    read -r c cr g gr <<< "$out"
    case "$c$cr$g$gr" in
      ''|*[!0-9]*) ;;   # unreadable: keep the previous numbers
      *) GHQ_CORE=$c; GHQ_CORE_RESET=$cr; GHQ_GQL=$g; GHQ_GQL_RESET=$gr ;;
    esac
    mkdir -p "${GH_QUOTA_FILE%/*}" 2>/dev/null
    printf '%s %s %s %s %s\n' "$now" "$GHQ_CORE" "$GHQ_CORE_RESET" "$GHQ_GQL" "$GHQ_GQL_RESET" > "$GH_QUOTA_FILE.$$" 2>/dev/null \
      && mv "$GH_QUOTA_FILE.$$" "$GH_QUOTA_FILE" 2>/dev/null || rm -f "$GH_QUOTA_FILE.$$" 2>/dev/null
  fi
  # a window that has already reset is unknown, not exhausted
  [ "$GHQ_CORE" -ge 0 ] && [ "$GHQ_CORE_RESET" -gt 0 ] && [ "$GHQ_CORE_RESET" -le "$now" ] && GHQ_CORE=-1
  [ "$GHQ_GQL" -ge 0 ] && [ "$GHQ_GQL_RESET" -gt 0 ] && [ "$GHQ_GQL_RESET" -le "$now" ] && GHQ_GQL=-1
  return 0
}

# _gh_quota_peek — #808: REST core remaining + reset (-1 / 0 when unknown) from the quota cache file as it stands, NEVER refreshing it
# (no rate_limit call). Sets _GHP_CORE / _GHP_RESET.
_gh_quota_peek() {
  _gh_budget_paths
  local at c cr g gr
  _GHP_CORE=-1; _GHP_RESET=0
  [ -f "$GH_QUOTA_FILE" ] || return 0
  read -r at c cr g gr < "$GH_QUOTA_FILE" 2>/dev/null || return 0
  case "$at$c$cr$g$gr" in *[!0-9-]*|'') return 0 ;; esac
  _GHP_CORE=${c:--1}; _GHP_RESET=${cr:-0}
}

# gh_quota_line — "gh-quota remaining=N reset=<Europe/Madrid time> graphql=M" (REST core first: the supervisor's essential reads use it)
gh_quota_line() {
  gh_quota_read
  printf 'gh-quota remaining=%s reset=%s graphql=%s' "$( [ "$GHQ_CORE" -ge 0 ] && echo "$GHQ_CORE" || echo unknown )" \
    "$(_gh_madrid "$GHQ_CORE_RESET")" "$( [ "$GHQ_GQL" -ge 0 ] && echo "$GHQ_GQL" || echo unknown )"
}

# _gh_tier_ok <remaining, -1 unknown> <class> -> 0 allowed, 1 not
_gh_tier_ok() {
  local rem="$1" class="${2:-normal}"
  [ "$rem" -ge 0 ] 2>/dev/null || return 0                     # unknown: never block on a guess
  [ "$rem" -gt 0 ] || return 1                                 # exhausted: nothing until the reset
  case "$class" in
    essential) return 0 ;;
    optional) [ "$rem" -ge "$GH_QUOTA_OPTIONAL_BELOW" ] ;;
    *) [ "$rem" -ge "$GH_QUOTA_ESSENTIAL_BELOW" ] ;;
  esac
}

# gh_tier_allows <class> — may work of this class start now, judged on the REST core bucket? (supervisor step gating)
gh_tier_allows() {
  [ "$GH_BUDGET_ENABLED" = 1 ] || return 0
  gh_quota_read
  _gh_tier_ok "$GHQ_CORE" "${1:-normal}"
}

# Finished entries only (all-digit names): another process's in-flight <key>.<pid> / <key>.w<pid> files must survive (#582).
# The #637 since-sync bookkeeping (dot-named: .since.* and .since-idx/) is untouched here — a write flushing the data
# it points at just makes the next lookup a cache miss (and a real re-read), never a stale hit.
gh_cache_clear() {
  _gh_budget_paths
  local f
  for f in "$GH_CACHE_DIR"/[0-9]*; do
    case "${f##*/}" in *[!0-9]*) continue ;; esac
    rm -f "$f" 2>/dev/null
  done
  return 0
}

# --- #637: per-repo incremental sync for single-issue / its-comments / its-list reads --------------------------------
# repos/<r>/issues/<n>, repos/<r>/issues/<n>/comments... and repos/<r>/issues (list/scope calls, e.g. ?milestone=,
# ?labels=, ?state=open — NOT ?.../milestones, which isn't driven by an issue's updated_at) are cached above with no
# wall-clock expiry IN A PROCESS THAT HAS SYNCED THIS REPO: once read, an entry is trusted until gh_since_sync finds
# the repo changed. "Synced" is deliberately per-process (the in-memory _GH_SYNCED set below, never written to disk):
# a process that never calls gh_since_sync for a repo (deliver.sh, a goal repo outside sw_repo_list, the literal
# `repos/{owner}/{repo}` placeholder, a case/slug mismatch) gets the plain TTL-governed cache exactly as before —
# never the no-expiry exemption on data nothing in this process ever validated. supervisor.sh calls gh_since_sync once
# per repo near the top of its tick, before the per-ticket reads later in that same process.
# The on-disk index (one tiny file per owner/repo/issue, plus one per owner/repo for list calls, living in
# $GH_CACHE_DIR like everything else here — no separate state file) maps a resource back to the cache key(s) that
# hold it, so invalidation does not depend on which cwd / arg order a caller used to read it.

_gh_since_lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

_gh_since_mark_synced() {  # <owner/repo> — this process trusts the no-TTL cache for it from now on
  local r; r=$(_gh_since_lc "$1")
  case "${_GH_SYNCED:- }" in *" $r "*) ;; *) _GH_SYNCED="${_GH_SYNCED:- } $r " ;; esac
}
_gh_since_unmark_synced() {  # <owner/repo> — a failed sync must never leave it trusted
  local r; r=$(_gh_since_lc "$1")
  local cur=${_GH_SYNCED:- }
  _GH_SYNCED=${cur//" $r "/ }   # quoted pattern: the "/" of owner/repo broke the old sed expression and emptied the whole set
}
_gh_since_synced() {  # <owner/repo> — 0 if this process has successfully synced it
  case "${_GH_SYNCED:- }" in *" $(_gh_since_lc "$1") "*) return 0 ;; esac
  return 1
}

# lower-cased: a read classified from a checkout's origin URL (#773 AC8) and an event's full_name may spell the repo differently
_gh_since_idx_dir() { printf '%s/.since-idx/%s\n' "$GH_CACHE_DIR" "$(printf '%s' "$1" | tr 'A-Z/' 'a-z_')"; }
_gh_since_list_idx_file() { printf '%s/.since-list-idx.%s\n' "$GH_CACHE_DIR" "$(printf '%s' "$1" | tr 'A-Z/' 'a-z_')"; }

_gh_since_index_add() {  # <owner/repo> <issue> <cache key>
  local f; f="$(_gh_since_idx_dir "$1")/$2"
  mkdir -p "${f%/*}" 2>/dev/null
  grep -qxF "$3" "$f" 2>/dev/null || printf '%s\n' "$3" >> "$f" 2>/dev/null
}
_gh_since_list_index_add() {  # <owner/repo> <cache key>
  local f; f=$(_gh_since_list_idx_file "$1")
  grep -qxF "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >> "$f" 2>/dev/null
}

_gh_since_invalidate_issue() {  # <owner/repo> <issue>
  local f k; f="$(_gh_since_idx_dir "$1")/$2"
  [ -f "$f" ] || return 0
  while IFS= read -r k; do [ -n "$k" ] && rm -f "$GH_CACHE_DIR/$k" 2>/dev/null; done < "$f"
  rm -f "$f" 2>/dev/null
}

_gh_since_invalidate_repo() {  # <owner/repo> — every issue this cache currently holds for it
  local d f; d=$(_gh_since_idx_dir "$1")
  [ -d "$d" ] || return 0
  for f in "$d"/[0-9]*; do
    [ -f "$f" ] || continue
    _gh_since_invalidate_issue "$1" "${f##*/}"
  done
}

_gh_since_invalidate_lists() {  # <owner/repo> — every repo-level issues? list entry cached for it (membership may have changed)
  local f k; f=$(_gh_since_list_idx_file "$1")
  [ -f "$f" ] || return 0
  while IFS= read -r k; do [ -n "$k" ] && rm -f "$GH_CACHE_DIR/$k" 2>/dev/null; done < "$f"
  rm -f "$f" 2>/dev/null
}

# _gh_since_iso <epoch> -> UTC ISO-8601 (GNU date, then BSD date); "" on failure
_gh_since_iso() {
  local e="$1" out
  case "$e" in ''|*[!0-9-]*) printf ''; return 1 ;; esac
  out=$(TZ=UTC date -u -d "@$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || out=$(TZ=UTC date -u -r "$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || out=""
  printf '%s' "$out"
}

# gh_since_sync <owner/repo> — one `issues?state=all&since=<last>` list call (never cached itself: the since= value
# changes every call), telling us which tickets changed since the last successful sync of this repo. Invalidates
# exactly their cached issues/<n> and issues/<n>/comments entries, and (only when something did change — list
# membership may have moved) every cached issues? scope-list entry too, so the next read of everything else in this
# process is served from the kept previous result instead of hitting GitHub again (#637). The stored timestamp lives
# in $GH_CACHE_DIR, the same directory as the read cache it governs.
# First sync for a repo (no stored timestamp): treated as cold — any leftover cache for the repo is invalidated
# instead of trusted, and no list call is made (nothing to compare against yet). A failed list call falls back to a
# full invalidation for the repo, never marks it synced, and does not advance the timestamp, so the next attempt
# retries from the same point rather than ever serving stale data as fresh. No-op when the budget guard itself is off.
gh_since_sync() {
  [ "${GH_BUDGET_ENABLED:-1}" = 1 ] || return 0
  _gh_budget_paths
  local repo="$1" sf prev start_epoch start out rc=0 new_since numbers
  [ -n "$repo" ] || return 1
  # #773: with WEBHOOK_EVENTS_ENABLED=1 and the tick's queue already applied to the cache (webhook_tick_prepare), a repo whose own
  # fallback poll is not due needs no API read at all. Anything else (off, not prepared, fallback due, gap) runs the code below unchanged.
  if [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ] && type webhook_sync_repo >/dev/null 2>&1 && webhook_sync_repo "$repo"; then return 0; fi
  mkdir -p "$GH_CACHE_DIR" 2>/dev/null
  sf="$GH_CACHE_DIR/.since.$(printf '%s' "$repo" | tr '/' '_')"
  prev=$(cat "$sf" 2>/dev/null) || prev=""
  start_epoch=$(date +%s); start=$(_gh_since_iso "$start_epoch"); [ -n "$start" ] || start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -z "$prev" ]; then
    _gh_since_invalidate_repo "$repo"; _gh_since_invalidate_lists "$repo"
    printf '%s\n' "$start" > "$sf.$$" 2>/dev/null && mv "$sf.$$" "$sf" 2>/dev/null
    _gh_since_mark_synced "$repo"
    [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ] && type webhook_full_done >/dev/null 2>&1 && webhook_full_done "$repo"
    return 0
  fi
  out=$(GH_NOCACHE=1 gh api --paginate "repos/$repo/issues?state=all&since=$prev&per_page=100" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || ! out=$(printf '%s' "$out" | jq -s 'add // []' 2>/dev/null); then
    _gh_since_invalidate_repo "$repo"; _gh_since_invalidate_lists "$repo"
    _gh_since_unmark_synced "$repo"
    return 1
  fi
  numbers=$(printf '%s' "$out" | jq -r '.[].number' 2>/dev/null)
  if [ -n "$numbers" ]; then
    while IFS= read -r n; do [ -n "$n" ] && _gh_since_invalidate_issue "$repo" "$n"; done <<< "$numbers"
    _gh_since_invalidate_lists "$repo"
  fi
  # a one-tick overlap tolerates clock skew between this host and GitHub: re-flagging an already-fresh issue costs
  # nothing until it is next read; missing a real change would not.
  new_since=$(_gh_since_iso $(( start_epoch - 120 ))); [ -n "$new_since" ] || new_since="$start"
  printf '%s\n' "$new_since" > "$sf.$$" 2>/dev/null && mv "$sf.$$" "$sf" 2>/dev/null
  _gh_since_mark_synced "$repo"
  [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ] && type webhook_full_done >/dev/null 2>&1 && webhook_full_done "$repo"
  return 0
}

gh() {
  if [ "$GH_BUDGET_ENABLED" != 1 ] || [ -n "${_GH_INNER:-}" ]; then command gh "$@"; return $?; fi
  _gh_budget_paths
  local class="${GH_CLASS:-normal}" now key cf t tmp rc rem
  _gh_scan "$@"
  # 1. cache hit: costs no API call, so it is allowed at any quota
  if [ "$_GH_CACHEABLE" = 1 ] && [ -z "${GH_NOCACHE:-}" ] && [ "$GH_CACHE_TTL_SECS" -gt 0 ] 2>/dev/null; then
    key=$(printf '%s\037%s' "$PWD" "$*" | cksum | tr -d ' '); cf="$GH_CACHE_DIR/$key"
    if [ -f "$cf" ]; then
      # #637: a single issue / its comments / a repo's issues? scope list has no wall-clock TTL in a process that
      # has gh_since_sync'd this repo — trusted until that finds it changed (or a write flushes the cache), so it
      # survives across ticks instead of expiring inside one. Never exempt in a process that never synced the repo
      # (deliver.sh, a goal repo outside sw_repo_list, the literal `repos/{owner}/{repo}` placeholder, a slug
      # mismatch) — those fall straight through to the ordinary TTL check below, same as before #637.
      # #773: with the webhook queue on, a process that never synced the repo itself (goal sync, reconcile) trusts the same entries
      # while the supervisor's applied-events stamp is fresh and the repo's fallback poll is not overdue (webhook_trusted).
      if { [ -n "$_GH_ISSUE_REPO" ] && _gh_since_synced "$_GH_ISSUE_REPO"; } || { [ -n "$_GH_LIST_REPO" ] && _gh_since_synced "$_GH_LIST_REPO"; } \
         || { [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ] && [ -n "$_GH_ISSUE_REPO$_GH_LIST_REPO" ] && type webhook_trusted >/dev/null 2>&1 && webhook_trusted "${_GH_ISSUE_REPO:-$_GH_LIST_REPO}"; }; then
        _gh_log "$class" hit; tail -n +2 "$cf"; return 0
      fi
      IFS= read -r t < "$cf" 2>/dev/null || t=0
      case "$t" in ''|*[!0-9]*) t=0 ;; esac
      now=$(date +%s)
      # #773 AC8: `issue view|list`, `repo view`, `pr list`: served for up to WEBHOOK_LIST_MAX_AGE_SECS (default = the fallback poll interval)
      # while the repo is webhook_trusted. The age cap bounds what a dropped delivery can leave stale (check state is not covered by the
      # fallback's issues?since= sync); an event for the repo drops the entry sooner (webhook_tick_prepare -> the list / issue index).
      if [ -n "$_GH_WH_REPO" ] && type webhook_trusted >/dev/null 2>&1 && webhook_trusted "$_GH_WH_REPO" \
         && [ $(( now - t )) -lt "$(_gh_wh_max_age)" ]; then
        _gh_log "$class" hit; tail -n +2 "$cf"; return 0
      fi
      if [ $(( now - t )) -lt "$GH_CACHE_TTL_SECS" ]; then
        _gh_log "$class" hit; tail -n +2 "$cf"; return 0
      fi
    fi
  fi
  # 2. quota guard
  if [ "$_GH_BUCKET" != none ]; then
    gh_quota_read
    if [ "$_GH_BUCKET" = core ]; then rem=$GHQ_CORE; else rem=$GHQ_GQL; fi
    if ! _gh_tier_ok "$rem" "$class"; then
      _gh_log "$class" skip
      echo "gh-budget: skipped $class call ($_GH_SUB), $_GH_BUCKET remaining=$rem" >&2
      return 1
    fi
  fi
  _gh_log "$class" call
  # 3. the call itself (+ cache store for reads, cache flush for writes)
  if [ "$_GH_CACHEABLE" = 1 ] && [ -z "${GH_NOCACHE:-}" ] && [ "$GH_CACHE_TTL_SECS" -gt 0 ] 2>/dev/null; then
    mkdir -p "$GH_CACHE_DIR" 2>/dev/null
    tmp="$cf.$$"
    command gh "$@" > "$tmp"; rc=$?
    if [ "$rc" -eq 0 ]; then
      { date +%s; cat "$tmp"; } > "$cf.w$$" 2>/dev/null && mv "$cf.w$$" "$cf" 2>/dev/null
      [ -n "$_GH_ISSUE_REPO" ] && _gh_since_index_add "$_GH_ISSUE_REPO" "$_GH_ISSUE_NUM" "$key"
      [ -n "$_GH_LIST_REPO" ] && _gh_since_list_index_add "$_GH_LIST_REPO" "$key"
      if [ -n "$_GH_WH_REPO" ]; then   # #773 AC8: indexed so a queue event for the repo (or the issue) drops it
        if [ -n "$_GH_WH_NUM" ]; then _gh_since_index_add "$_GH_WH_REPO" "$_GH_WH_NUM" "$key"; else _gh_since_list_index_add "$_GH_WH_REPO" "$key"; fi
      fi
    fi
    cat "$tmp" 2>/dev/null; rm -f "$tmp" "$cf.w$$" 2>/dev/null
    return $rc
  fi
  command gh "$@"; rc=$?
  [ "$_GH_WRITE" = 1 ] && gh_cache_clear
  return $rc
}

_gh_wh_max_age() {
  local m="${WEBHOOK_LIST_MAX_AGE_SECS:-}"
  case "$m" in ''|*[!0-9]*) m=$(( ${WEBHOOK_FALLBACK_POLL_MINUTES:-20} * 60 )) ;; esac
  printf '%s' "$m"
}

# gh_tick_mark / gh_tick_summary — #773 AC8 counter: how many GitHub calls one supervisor tick cost, from this call log (all callers in
# the tick's window: the supervisor, reconcile, goal sync). gh_tick_mark remembers the log's byte offset at tick start; gh_tick_summary
# prints "calls=N hits=H skips=S webhook=on|off core_used=N|unknown" for what was appended since (a rotated log counts from its start). Prints nothing with the
# budget guard off. Measure idle before/after the switch: grep '[gh-calls]' supervisor.log, average calls= over >= 30 idle ticks.
gh_tick_mark() {
  [ "$GH_BUDGET_ENABLED" = 1 ] || return 0
  _gh_budget_paths
  _GH_TICK_OFF=$(wc -c < "$GH_CALL_LOG" 2>/dev/null | tr -d ' '); _GH_TICK_OFF=${_GH_TICK_OFF:-0}
  _gh_quota_peek; _GH_TICK_CORE0=$_GHP_CORE; _GH_TICK_RESET0=$_GHP_RESET   # #808: REST core remaining at tick start (quota file as is: the tick's gh_quota_line just refreshed it)
}
gh_tick_summary() {
  [ "$GH_BUDGET_ENABLED" = 1 ] || return 0
  _gh_budget_paths
  local size off="${_GH_TICK_OFF:-0}" wh=off
  size=$(wc -c < "$GH_CALL_LOG" 2>/dev/null | tr -d ' '); size=${size:-0}
  [ "$size" -ge "$off" ] || off=0
  [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ] && wh=on
  tail -c +$(( off + 1 )) "$GH_CALL_LOG" 2>/dev/null | awk -v wh="$wh" '$4=="call"{c++} $4=="hit"{h++} $4=="skip"{s++} END{printf "calls=%d hits=%d skips=%d webhook=%s", c, h, s, wh}'
  # #808: REST core quota consumed between gh_tick_mark and now, from the quota cache file as it stands (no rate_limit call; the file is
  # refreshed by the tick's own calls at most once per GH_QUOTA_TTL_SECS, so both readings can be that old: a short tick can show
  # core_used=0 while using some). unknown when either reading is unknown or the window reset in between.
  local c0="${_GH_TICK_CORE0:--1}" cu=unknown
  _gh_quota_peek
  if [ "$c0" -ge 0 ] 2>/dev/null && [ "$_GHP_CORE" -ge 0 ] && [ "$_GHP_CORE" -le "$c0" ] && [ "$_GHP_RESET" = "${_GH_TICK_RESET0:-x}" ]; then
    cu=$(( c0 - _GHP_CORE ))
  fi
  printf ' core_used=%s' "$cu"
}

# gh_tick_due <name> <secs> — 0 when work <name> has not run for <secs> (and stamps it now), else 1. For GitHub-only reconciliation that
# does not need to run every 2-minute tick (decision-neutral: its own staleness windows are 30 min or more). With the budget guard off
# (the test default) it is always due, so behaviour and tests are unchanged.
gh_tick_due() {
  [ "$GH_BUDGET_ENABLED" = 1 ] || return 0
  _gh_budget_paths
  local f="${GH_QUOTA_FILE%/*}/tick-$1.last" now last
  now=$(date +%s); last=$(cat "$f" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -ge "$2" ] || return 1
  echo "$now" > "$f" 2>/dev/null
  return 0
}
