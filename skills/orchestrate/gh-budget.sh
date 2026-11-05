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
#                     $PIPE/gh-cache (key: cwd + args); only rc 0 output is stored; any write call empties the cache;
#                     supervisor.sh empties it at the start of every tick so decisions never use a previous tick's read.
#                     GH_NOCACHE=1 gh ... bypasses it (claim reads do).
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

# _gh_scan <gh args...> — classify one call into globals (no subshell, so it is cheap):
#   _GH_SUB (log text), _GH_BUCKET (core|graphql|none), _GH_WRITE (0|1), _GH_CACHEABLE (0|1)
_gh_scan() {
  _GH_SUB=""; _GH_BUCKET=graphql; _GH_WRITE=0; _GH_CACHEABLE=0
  local first="${1:-}" second="${2:-}" a prev="" method=GET payload=0 path=""
  case "$first" in
    api)
      shift
      for a in "$@"; do
        if [ -n "$prev" ]; then
          case "$prev" in
            -X|--method) method="$a" ;;
            -f|-F|--field|--raw-field|--input) payload=1 ;;
          esac
          prev=""; continue
        fi
        case "$a" in
          -X|--method|-f|-F|--field|--raw-field|--input|-H|--header|--jq|-q|--template|-t|--cache|--hostname|-p|--preview) prev="$a" ;;
          --method=*) method="${a#*=}" ;;
          --input=*|--field=*|--raw-field=*) payload=1 ;;
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
      [ "$payload" = 1 ] && _GH_WRITE=1
      if [ "$_GH_WRITE" = 0 ]; then
        case "$path" in
          repos/*/issues|repos/*/issues/*|repos/*/milestones|repos/*/milestones/*|repos/*/labels|repos/*/labels/*|'repos/{owner}/{repo}') _GH_CACHEABLE=1 ;;
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
      fi ;;
  esac
  return 0
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
gh_cache_clear() {
  _gh_budget_paths
  local f
  for f in "$GH_CACHE_DIR"/[0-9]*; do
    case "${f##*/}" in *[!0-9]*) continue ;; esac
    rm -f "$f" 2>/dev/null
  done
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
      IFS= read -r t < "$cf" 2>/dev/null || t=0
      case "$t" in ''|*[!0-9]*) t=0 ;; esac
      now=$(date +%s)
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
    fi
    cat "$tmp" 2>/dev/null; rm -f "$tmp" "$cf.w$$" 2>/dev/null
    return $rc
  fi
  command gh "$@"; rc=$?
  [ "$_GH_WRITE" = 1 ] && gh_cache_clear
  return $rc
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
