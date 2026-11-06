# gh-budget.sh — call log line format, quota tiers (optional < 1500, normal < 300, exhausted = 0), the 60 s quota read cache and the
# read cache TTL / flush-on-write / bypass. No network: a stub `gh` first on PATH answers `api rate_limit` from $GB/rl and records every
# other call in $GB/calls.

GB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../gh-budget.sh"

gb_env() {  # sets GB (scratch dir) with a stub gh; rate limit core=$1 reset-offset-secs=$2 graphql=$3
  GB=$(mktemp -d "${TMPDIR:-/tmp}/gh-budget-test.XXXXXX")
  mkdir -p "$GB/bin" "$GB/pipe"
  : > "$GB/calls"; : > "$GB/rlcalls"
  printf '%s\t%s\t%s\t%s\n' "$1" "$(( $(date +%s) + ${2:-3600} ))" "${3:-5000}" "$(( $(date +%s) + ${2:-3600} ))" > "$GB/rl"
  cat > "$GB/bin/gh" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "api rate_limit" ]; then echo x >> "$GB/rlcalls"; cat "$GB/rl"; exit 0; fi
echo "\$*" >> "$GB/calls"
echo "OUT:\$*"
EOF
  chmod +x "$GB/bin/gh"
}

gb_run() {  # gb_run <bash text> — runs it with gh-budget.sh sourced and the stub gh on PATH
  PATH="$GB/bin:$PATH" PIPE="$GB/pipe" LOGDIR="$GB/log" GH_BUDGET_ENABLED=1 GH_CACHE_TTL_SECS="${GB_TTL:-60}" \
    bash -c ". '$GB_LIB'; $1" 2>"$GB/err"
}

gb_calls() { local n; n=$(grep -c . "$GB/calls" 2>/dev/null); echo "${n:-0}"; }

test_gb_log_line_format() {
  gb_env 5000
  gb_run 'f() { gh issue view 7 --json title; }; f' >/dev/null
  local line; line=$(cat "$GB/log/gh-calls.log")
  case "$line" in
    [0-9]*\ *:f\ normal\ call\ issue\ view) ;;
    *) fail "log line shape: [$line]"; return 1 ;;
  esac
  gb_run 'gh api "repos/o/r/issues/7/comments?per_page=100" --paginate' >/dev/null
  assert_contains "$(tail -1 "$GB/log/gh-calls.log")" " api repos/o/r/issues/7/comments" "api endpoint logged without the query string" || return 1
  rm -rf "$GB"
}

test_gb_tiers() {
  local core class rc expect
  for case_ in "5000 optional 0" "1499 optional 1" "1499 normal 0" "299 normal 1" "299 essential 0" "1 essential 0" "0 essential 1"; do
    set -- $case_; core=$1; class=$2; expect=$3
    gb_env "$core" 3600 "$core"   # issue view is GraphQL-backed: same level in both buckets
    gb_run "GH_CLASS=$class; gh issue view 1 >/dev/null"; rc=$?
    assert_eq "$rc" "$expect" "core=$core class=$class rc" || return 1
    if [ "$expect" = 1 ]; then assert_eq "$(gb_calls)" 0 "core=$core class=$class: skipped call must not reach gh" || return 1; fi
    rm -rf "$GB"
  done
}

test_gb_exhausted_skips_with_one_quiet_line() {
  gb_env 0 3600 0
  gb_run 'GH_CLASS=essential; gh api repos/o/r/issues/1; gh api repos/o/r/issues/2'
  assert_eq "$(gb_calls)" 0 "no call reaches gh at 0" || return 1
  assert_contains "$(cat "$GB/err")" "gh-budget: skipped essential call" "one stderr line per skipped call" || return 1
  assert_contains "$(cat "$GB/log/gh-calls.log")" " essential skip " "skip logged" || return 1
  rm -rf "$GB"
}

test_gb_graphql_bucket_is_separate() {
  gb_env 5000 3600 0   # core fine, graphql empty
  gb_run 'gh api repos/o/r/issues/1 >/dev/null'; assert_eq "$?" 0 "REST call runs" || return 1
  gb_run 'gh issue view 1 >/dev/null'; assert_eq "$?" 1 "graphql-backed call skipped" || return 1
  rm -rf "$GB"
}

test_gb_quota_read_cached_60s() {
  gb_env 5000
  gb_run 'gh issue view 1 >/dev/null; gh issue view 2 >/dev/null; gh issue view 3 >/dev/null'
  assert_eq "$(grep -c . "$GB/rlcalls")" 1 "three calls inside the TTL read rate_limit once" || return 1
  # age the cache past the TTL: next call reads again
  printf '%s 5000 %s 5000 %s\n' "$(( $(date +%s) - 61 ))" "$(( $(date +%s) + 3600 ))" "$(( $(date +%s) + 3600 ))" > "$GB/pipe/gh-quota"
  gb_run 'gh issue view 4 >/dev/null'
  assert_eq "$(grep -c . "$GB/rlcalls")" 2 "stale quota file refreshed" || return 1
  rm -rf "$GB"
}

test_gb_quota_line_madrid() {
  gb_env 1234 3600 4321
  local out; out=$(gb_run 'gh_quota_line')
  case "$out" in
    "gh-quota remaining=1234 reset="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]" Europe/Madrid graphql=4321") ;;
    *) fail "quota line: [$out]"; return 1 ;;
  esac
  rm -rf "$GB"
}

test_gb_unreadable_rate_limit_does_not_block() {
  gb_env 0
  : > "$GB/rl"   # rate_limit answers nothing
  gb_run 'GH_CLASS=optional; gh issue view 1 >/dev/null'
  assert_eq "$?" 0 "unknown quota never blocks" || return 1
  rm -rf "$GB"
}

test_gb_cache_hit_within_ttl_and_expiry() {
  gb_env 5000
  gb_run 'gh issue view 9 --json comments; gh issue view 9 --json comments' >"$GB/out"
  assert_eq "$(gb_calls)" 1 "second identical read served from cache" || return 1
  assert_eq "$(grep -c 'OUT:issue view 9' "$GB/out")" 2 "both reads return the output" || return 1
  assert_contains "$(cat "$GB/log/gh-calls.log")" " hit issue view" "hit logged" || return 1
  # expire: backdate the stored epoch
  local f; f=$(ls "$GB/pipe/gh-cache"/* | head -1)
  { echo $(( $(date +%s) - 61 )); tail -n +2 "$f"; } > "$f.n" && mv "$f.n" "$f"
  gb_run 'gh issue view 9 --json comments' >/dev/null
  assert_eq "$(gb_calls)" 2 "expired entry re-read" || return 1
  rm -rf "$GB"
}

test_gb_cache_key_includes_args_and_cwd() {
  gb_env 5000
  mkdir -p "$GB/d1" "$GB/d2"
  gb_run "gh issue view 1; gh issue view 2; (cd '$GB/d1' && gh repo view); (cd '$GB/d2' && gh repo view)" >/dev/null
  assert_eq "$(gb_calls)" 4 "different args or cwd are different reads" || return 1
  rm -rf "$GB"
}

test_gb_write_flushes_cache_and_nocache_bypasses() {
  gb_env 5000
  gb_run 'gh issue view 5; gh issue comment 5 --body hi >/dev/null; gh issue view 5' >/dev/null
  assert_eq "$(gb_calls)" 3 "read, write, read again after the write" || return 1
  : > "$GB/calls"
  gb_run 'gh api repos/o/r/issues/5/comments >/dev/null; GH_NOCACHE=1 gh api repos/o/r/issues/5/comments >/dev/null; gh api -X POST repos/o/r/issues/5/comments -f body=x >/dev/null; gh api repos/o/r/issues/5/comments >/dev/null'
  assert_eq "$(gb_calls)" 4 "NOCACHE bypasses; POST flushes" || return 1
  rm -rf "$GB"
}

test_gb_cache_clear_spares_in_flight_reads() {
  gb_env 5000
  printf '#!/bin/bash\nif [ "$1 $2" = "api rate_limit" ]; then cat "%s/rl"; exit 0; fi\necho "$*" >> "%s/calls"\nsleep 1\necho "SLOW:$*"\n' "$GB" "$GB" > "$GB/bin/gh"
  gb_run '(gh issue view 77 > "$PIPE/out") & sleep 0.4; gh_cache_clear; wait'
  assert_eq "$(cat "$GB/pipe/out")" "SLOW:issue view 77" "read in flight during a clear still returns its full output" || return 1
  rm -rf "$GB"
}

test_gb_cache_clear_removes_finished_keeps_in_flight() {
  gb_env 5000
  gb_run 'gh issue view 3 >/dev/null; touch "$GH_CACHE_DIR/123.4567" "$GH_CACHE_DIR/123.w4567"; gh_cache_clear'
  assert_eq "$(ls "$GB/pipe/gh-cache" | sort | tr '\n' ' ')" "123.4567 123.w4567 " "finished entry gone, in-flight files survive" || return 1
  rm -rf "$GB"
}

test_gb_failed_read_not_cached() {
  gb_env 5000
  printf '#!/bin/bash\nif [ "$1 $2" = "api rate_limit" ]; then cat "%s/rl"; exit 0; fi\necho "$*" >> "%s/calls"; exit 1\n' "$GB" "$GB" > "$GB/bin/gh"
  gb_run 'gh issue view 3; gh issue view 3' >/dev/null
  assert_eq "$(gb_calls)" 2 "rc!=0 output is never cached" || return 1
  rm -rf "$GB"
}

test_gb_ttl_zero_disables_cache() {
  gb_env 5000
  GB_TTL=0 gb_run 'gh issue view 9; gh issue view 9' >/dev/null
  assert_eq "$(gb_calls)" 2 "TTL 0 = no cache" || return 1
  rm -rf "$GB"
}

test_gb_disabled_is_passthrough() {
  gb_env 0
  PATH="$GB/bin:$PATH" PIPE="$GB/pipe" LOGDIR="$GB/log" GH_BUDGET_ENABLED=0 bash -c ". '$GB_LIB'; gh issue view 1 >/dev/null; gh issue view 1 >/dev/null"
  assert_eq "$(gb_calls)" 2 "disabled: every call goes straight to gh" || return 1
  assert_file_absent "$GB/log/gh-calls.log" "disabled: no log" || return 1
  rm -rf "$GB"
}

test_gb_tick_due() {
  gb_env 5000
  gb_run 'gh_tick_due x 600'; assert_eq "$?" 0 "first run due" || return 1
  gb_run 'gh_tick_due x 600'; assert_eq "$?" 1 "second run inside the window not due" || return 1
  echo $(( $(date +%s) - 601 )) > "$GB/pipe/tick-x.last"
  gb_run 'gh_tick_due x 600'; assert_eq "$?" 0 "due again after the window" || return 1
  rm -rf "$GB"
}

test_gb_log_cap_stops_logging() {
  gb_env 5000
  mkdir -p "$GB/log"; head -c 200 /dev/zero | tr '\0' 'x' > "$GB/log/gh-calls.log"
  PATH="$GB/bin:$PATH" PIPE="$GB/pipe" LOGDIR="$GB/log" GH_BUDGET_ENABLED=1 GH_CALL_LOG_MAX_BYTES=100 bash -c ". '$GB_LIB'; gh issue view 1 >/dev/null"
  assert_eq "$(wc -c < "$GB/log/gh-calls.log" | tr -d ' ')" 200 "log over its cap is not appended to" || return 1
  rm -rf "$GB"
}

for t in test_gb_log_line_format test_gb_tiers test_gb_exhausted_skips_with_one_quiet_line test_gb_graphql_bucket_is_separate \
         test_gb_quota_read_cached_60s test_gb_quota_line_madrid test_gb_unreadable_rate_limit_does_not_block \
         test_gb_cache_hit_within_ttl_and_expiry test_gb_cache_key_includes_args_and_cwd test_gb_write_flushes_cache_and_nocache_bypasses \
         test_gb_cache_clear_spares_in_flight_reads test_gb_cache_clear_removes_finished_keeps_in_flight \
         test_gb_failed_read_not_cached test_gb_ttl_zero_disables_cache test_gb_disabled_is_passthrough test_gb_tick_due \
         test_gb_log_cap_stops_logging; do
  run_test "$t"
done

# ---- supervisor.sh: one quota line per tick (Europe/Madrid), reduced tiers, exhausted = quiet exit ------------------------------------
GBS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "gbs_real_$(declare -f run_test)"
  run_test() { :; }
  . "$GBS_DIR/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f gbs_real_run_test | sed '1s/gbs_real_run_test/run_test/')"
fi

gbs_tick() {  # gbs_tick <core remaining> — one supervisor tick, guard on, a rate_limit-aware gh in front of the fake one
  local shim="$SQ_HOME/shim"
  mkdir -p "$shim"
  printf '%s\t%s\t5000\t%s\n' "$1" "$(( $(date +%s) + 3600 ))" "$(( $(date +%s) + 3600 ))" > "$SQ_HOME/rl"
  printf '#!/bin/bash\nif [ "$1 $2" = "api rate_limit" ]; then cat "%s/rl"; exit 0; fi\nexec "%s/gh" "$@"\n' "$SQ_HOME" "$SQ_GH" > "$shim/gh"
  chmod +x "$shim/gh"
  HOME="$SQ_HOME" PATH="$shim:$SQ_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SQ_PIPE" QUEUE="$SQ_PIPE/queue" LOGDIR="$SQ_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" GH_BUDGET_ENABLED=1 "$SUP_SQ" >/dev/null 2>&1
}

test_gbs_quota_line_each_tick() {
  sq_env empty
  gbs_tick 4000
  assert_contains "$(sq_log)" "gh-quota remaining=4000 reset=" "quota line logged" || { sq_cleanup; return 1; }
  assert_contains "$(sq_log)" "Europe/Madrid" "reset time is Madrid time" || { sq_cleanup; return 1; }
  assert_not_contains "$(sq_log)" "reduced tier" "full tier above 1500" || { sq_cleanup; return 1; }
  sq_cleanup
}

test_gbs_reduced_tier_logged() {
  sq_env empty
  gbs_tick 1000
  assert_contains "$(sq_log)" "[gh-quota] reduced tier: normal=1 optional=0" "optional work off below 1500" || { sq_cleanup; return 1; }
  sq_cleanup
}

test_gbs_essential_only_tier() {
  sq_env empty
  gbs_tick 100
  assert_contains "$(sq_log)" "reduced tier: normal=0 optional=0" "only essential work below 300" || { sq_cleanup; return 1; }
  sq_cleanup
}

test_gbs_exhausted_tick_ends_quietly() {
  sq_env empty
  gbs_tick 0
  assert_contains "$(sq_log)" "gh-quota remaining=0" "quota line logged at 0" || { sq_cleanup; return 1; }
  assert_contains "$(sq_log)" "REST quota exhausted" "one explanatory line" || { sq_cleanup; return 1; }
  assert_not_contains "$(sq_log)" "rate limit exceeded" "no failing calls" || { sq_cleanup; return 1; }
  sq_cleanup
}

for t in test_gbs_quota_line_each_tick test_gbs_reduced_tier_logged test_gbs_essential_only_tier test_gbs_exhausted_tick_ends_quietly; do
  run_test "$t"
done
