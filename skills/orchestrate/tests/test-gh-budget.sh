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

# #808 AC1: a read-only GraphQL query sent with -f/-F is not a write; a mutation (or --input) still is
test_gb_graphql_query_read_is_not_a_write_and_cache_survives() {
  gb_env 5000
  local out
  out=$(gb_run '_gh_scan api graphql -f query="query { viewer { login } }" -f owner=o -F number=1; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "query with -f/-F is a read" || return 1
  out=$(gb_run '_gh_scan api graphql -f query="  
  query { repository(owner:\"o\", name:\"r\") { id } }" -f o=x; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "leading whitespace/newline query is a read" || return 1
  out=$(gb_run '_gh_scan api graphql --raw-field "query=query { viewer { login } }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "query=... in one --raw-field arg is a read" || return 1
  # the read-only query must not flush a cached REST read
  gb_run 'gh api repos/o/r/issues/5/comments >/dev/null; gh api graphql -f query="query { viewer { login } }" >/dev/null; gh api repos/o/r/issues/5/comments >/dev/null'
  assert_eq "$(gb_calls)" 2 "REST read, graphql query, REST read again: cache survived (2 real calls)" || return 1
  rm -rf "$GB"
}

test_gb_graphql_mutation_and_input_stay_writes() {
  gb_env 5000
  local out
  out=$(gb_run '_gh_scan api graphql -f query="mutation { addStar(input:{starrableId:\"x\"}) { clientMutationId } }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "mutation is a write" || return 1
  out=$(gb_run '_gh_scan api graphql -f query="
   mutation M { x }" -F n=1; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "mutation after leading whitespace is a write" || return 1
  out=$(gb_run '_gh_scan api graphql --input payload.json; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "--input to graphql is still a write" || return 1
  out=$(gb_run '_gh_scan api graphql -X POST -f query="query { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "non-GET method is still a write" || return 1
  gb_run 'gh api repos/o/r/issues/5/comments >/dev/null; gh api graphql -f query="mutation { x }" >/dev/null; gh api repos/o/r/issues/5/comments >/dev/null'
  assert_eq "$(gb_calls)" 3 "mutation flushes the cache" || return 1
  rm -rf "$GB"
}

# #808 review: attached-value forms are parsed too; anything not provably a non-mutation query stays a write
test_gb_attached_flag_forms_fail_safe() {
  gb_env 5000
  local out
  out=$(gb_run '_gh_scan api graphql -fquery="mutation { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "-fquery=mutation is a write" || return 1
  out=$(gb_run '_gh_scan api graphql -Fquery="mutation { x }" -Fn=1; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "-Fquery=mutation is a write" || return 1
  out=$(gb_run '_gh_scan api graphql --field=query="mutation { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "--field=query=mutation is a write" || return 1
  out=$(gb_run '_gh_scan api graphql --raw-field=query="  mutation { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "--raw-field=query=<ws>mutation is a write" || return 1
  out=$(gb_run '_gh_scan api graphql -fquery="query { x }" -fowner=o; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "attached -fquery=query... is still a read" || return 1
  out=$(gb_run '_gh_scan api graphql --field=query="query { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "--field=query=query... is a read" || return 1
  out=$(gb_run '_gh_scan api graphql -fquery="# note
mutation { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "a comment-led document cannot be proven a query: write" || return 1
  out=$(gb_run '_gh_scan api graphql -fowner=o; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "fields without any query= value: write" || return 1
  out=$(gb_run '_gh_scan api repos/o/r/issues/1/labels/x -XDELETE; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "attached -XDELETE is a write" || return 1
  out=$(gb_run '_gh_scan api repos/o/r/issues/1 -XGET; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "attached -XGET stays a read" || return 1
  rm -rf "$GB"
}

test_gb_real_goal_project_calls_are_reads() {
  gb_env 5000
  local out gp="$(cd "$(dirname "$GB_LIB")" && pwd)/goal-project.sh" call
  # the two real callers' exact argv shapes, with the real query strings (goal-project.sh _GP_ITEMS_Q / _GP_SCOPE_Q)
  for call in '-f query="$_GP_ITEMS_Q" -f owner=o -F number=1 -f cursor=c' '-f query="$_GP_SCOPE_Q" -f owner=o -F number=1 -F first=50'; do
    out=$(gb_run ". '$gp' 2>/dev/null; _gh_scan api graphql $call; echo WRITE=\$_GH_WRITE")
    assert_contains "$out" "WRITE=0" "real goal-project call [$call] is a read" || return 1
  done
  out=$(gb_run '_gh_scan api graphql -F query=@q.graphql; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "query=@file cannot be inspected: stays a write" || return 1
  rm -rf "$GB"
}

test_gb_non_graphql_paths_unchanged() {
  gb_env 5000
  local out
  out=$(gb_run '_gh_scan api repos/o/r/issues/1 -f body=x; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "REST with -f stays a write" || return 1
  out=$(gb_run '_gh_scan api repos/o/r/issues/1 -f query="query { x }"; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=1" "-f query= on a REST path stays a write" || return 1
  out=$(gb_run '_gh_scan api repos/o/r/issues/1; echo WRITE=$_GH_WRITE')
  assert_contains "$out" "WRITE=0" "plain REST GET stays a read" || return 1
  rm -rf "$GB"
}

# #808 AC3: the per-tick summary gains core_used = REST core quota consumed between gh_tick_mark and gh_tick_summary
test_gb_tick_summary_core_used() {
  gb_env 4000
  local now; now=$(date +%s)
  printf '%s 4000 %s 5000 %s\n' "$((now - 500))" "$((now + 3600))" "$((now + 3600))" > "$GB/pipe/gh-quota"
  local out
  out=$(gb_run 'gh_tick_mark; printf "%s 3700 %s 5000 %s\n" "$(date +%s)" '"$((now + 3600))"' '"$((now + 3600))"' > "$PIPE/gh-quota"; gh_tick_summary')
  assert_contains "$out" "calls=0 hits=0 skips=0 webhook=off core_used=300" "4000 -> 3700 is 300 used, field appended after the existing ones" || return 1
  assert_eq "$(grep -c . "$GB/rlcalls")" 0 "tick mark + summary make no rate_limit call, even with a stale quota file" || return 1
  # window reset between the readings (remaining went up): unknown, never negative
  out=$(gb_run 'gh_tick_mark; printf "%s 4900 %s 5000 %s\n" "$(date +%s)" '"$((now + 7200))"' '"$((now + 7200))"' > "$PIPE/gh-quota"; gh_tick_summary')
  assert_contains "$out" "core_used=unknown" "reset window -> unknown" || return 1
  rm -rf "$GB"
}

for t in test_gb_log_line_format test_gb_tiers test_gb_exhausted_skips_with_one_quiet_line test_gb_graphql_bucket_is_separate \
         test_gb_quota_read_cached_60s test_gb_quota_line_madrid test_gb_unreadable_rate_limit_does_not_block \
         test_gb_cache_hit_within_ttl_and_expiry test_gb_cache_key_includes_args_and_cwd test_gb_write_flushes_cache_and_nocache_bypasses \
         test_gb_cache_clear_spares_in_flight_reads test_gb_cache_clear_removes_finished_keeps_in_flight \
         test_gb_failed_read_not_cached test_gb_ttl_zero_disables_cache test_gb_disabled_is_passthrough test_gb_tick_due \
         test_gb_log_cap_stops_logging \
         test_gb_graphql_query_read_is_not_a_write_and_cache_survives test_gb_graphql_mutation_and_input_stay_writes \
         test_gb_real_goal_project_calls_are_reads test_gb_attached_flag_forms_fail_safe test_gb_non_graphql_paths_unchanged test_gb_tick_summary_core_used; do
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

test_gbs_tick_line_has_core_used() {   # #808 AC3: the supervisor's own end-of-tick line carries the new field, after the existing ones
  sq_env empty
  gbs_tick 4000
  assert_contains "$(sq_log)" "[gh-calls] tick calls=" "tick line logged" || { sq_cleanup; return 1; }
  assert_contains "$(sq_log)" " webhook=off core_used=" "core_used appended after webhook=" || { sq_cleanup; return 1; }
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

for t in test_gbs_quota_line_each_tick test_gbs_tick_line_has_core_used test_gbs_reduced_tier_logged test_gbs_essential_only_tier test_gbs_exhausted_tick_ends_quietly; do
  run_test "$t"
done
