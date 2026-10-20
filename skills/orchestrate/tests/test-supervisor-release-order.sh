# Issue #247 (queue-order name taken by #63 test) — supervisor step 5 dispatches in release order (milestone vX.Y.Z asc, then issue number asc; no/staging/
# non-version milestone last), drops agent-in-progress before the 50 cap, logs candidates=N. Reuses test-intake-supervisor.sh
# helpers (si_*), so this file must sort after it (it does: "supervisor-queue" > "intake").
HERE_QO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$(type -t si_env)" = function ] || . "$HERE_QO/test-intake-supervisor.sh"

# rq_issue <num> <milestone-title|""> [label...] — issues.json entry with milestone, default label agent-go
rq_issue() {
  local n=$1 m=$2; shift 2; local l=("$@"); [ ${#l[@]} -eq 0 ] && l=(agent-go)
  jq --argjson n "$n" --arg m "$m" --argjson l "$(printf '%s\n' "${l[@]}" | jq -R . | jq -sc 'map({name:.})')" \
    '. + [{number:$n,repo:"project-a/repo-a",labels:$l,milestone:(if $m=="" then null else {title:$m} end)}]' \
    "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
}
# rq_ticks <n> — repeated ticks; each claims one issue (comment) — report claimed issue numbers in order
rq_claimed() { jq -r '.[]' "$SI_D/claim-order.txt" 2>/dev/null; }
rq_order() {  # the issue-list order the supervisor would iterate = the order of claim attempts in gh-calls.log
  grep -o 'issue comment [0-9]*' "$SI_D/gh-calls.log" | awk '{print $3}' | awk '!s[$0]++' | tr '\n' ' '
}


# rq_wrap <mode> — front the stub gh: honours `issue list --limit/--search "-label:\"X\""` like GitHub (the shared stub ignores both).
# mode failclaim: every `issue comment` fails so the loop walks the whole list; listfail: `issue list` exits 1; garbage: `issue list` returns a payload the sort cannot parse.
rq_wrap() {
  mv "$SI_D/gh" "$SI_D/gh.real"
  cat > "$SI_D/gh" <<'WRAP'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"; MODE=$(cat "$D/rq-mode")
echo "$*" >> "$D/gh-calls.log"
[ "$MODE" = failclaim ] && [ "$1 $2" = "issue comment" ] && exit 1
if [ "$1 $2" = "issue list" ]; then
  [ "$MODE" = listfail ] && { echo "HTTP 502 boom" >&2; exit 1; }
  lim=30; ex=""; jq_x=""; args=(); prev=""
  for a in "$@"; do
    case "$prev" in
      --limit) lim=$a;;
      --search) ex=$(printf '%s' "$a" | sed -E 's/^-label:"(.*)"$/\1/');;
      --jq) jq_x=$a;;
      *) case "$a" in --limit|--search|--jq) ;; *) args+=("$a");; esac;;
    esac
    prev=$a
  done
  # like gh: filter server-side, cap, then apply --jq; a jq error is a non-zero exit with stderr
  flt='[.[] | select($ex=="" or (([.labels[].name]|index($ex))|not))] | .[:$lim]'
  [ "$MODE" = garbage ] && flt='{"unexpected":"shape"}'   # a payload the sort cannot parse
  "$D/gh.real" "${args[@]}" | jq -c --arg ex "$ex" --argjson lim "$lim" "$flt" | jq -r "$jq_x"
  exit ${PIPESTATUS[2]}
fi
exec "$D/gh.real" "$@"
WRAP
  chmod +x "$SI_D/gh"; echo "$1" > "$SI_D/rq-mode"
}
# rq_tick — one tick with Slack configured against a stub curl that records the alert.
rq_tick() {
  printf '#!/bin/bash\necho "$*" >> "%s/curl.log"\necho "{\\"ok\\":true}"\n' "$SI_D" > "$SI_D/curl"; chmod +x "$SI_D/curl"
  HOME="$SI_HOME" PATH="$SI_D:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SI_PIPE" QUEUE="$SI_PIPE/queue" LOGDIR="$SI_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="x" SLACK_ENGINEERING_CHANNEL="C1" /bin/bash "$SUP_SI" >/dev/null 2>&1; sleep 1.5
}
rq_bulk() {  # rq_bulk <count> <start> <milestone> [label...] — many issues in one jq pass
  local c=$1 st=$2 m=$3; shift 3; local l=("$@"); [ ${#l[@]} -eq 0 ] && l=(agent-go)
  jq --argjson c "$c" --argjson s "$st" --arg m "$m" --argjson l "$(printf '%s\n' "${l[@]}" | jq -R . | jq -sc 'map({name:.})')" \
    '. + [range($s;$s+$c) | {number:.,repo:"project-a/repo-a",labels:$l,milestone:{title:$m}}]' "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
}

test_rq_release_order_and_nonversion_last() {
  si_env
  # newest-first listing, as GitHub returns it
  rq_issue 900 ""; rq_issue 899 staging; rq_issue 898 "v1.20.13 - e"; rq_issue 897 "v1.20.10 - d"
  rq_issue 896 "v1.20.3 - c"; rq_issue 895 "v1.20.2 - b"; rq_issue 894 "v1.20.2 - b"; rq_issue 893 "garbage"
  rq_wrap failclaim
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "894 895 896 897 898 893 899 900 " "release order, non-version last by number" || return 1
}

test_rq_in_progress_dropped_before_cap() {
  si_env
  rq_bulk 520 1000 "v1.0.0" agent-go agent-in-progress
  rq_issue 500 "v2.0.0"
  # fresh last comment so step 4 (orphan reconcile) leaves the in-progress labels alone
  jq -n --arg t "$(date -u +%FT%TZ)" '[{body:"x",createdAt:$t}]' > "$SI_D/comments.json"
  rq_wrap plain; si_tick
  local got; got=$(rq_order); local log; log=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); si_cleanup
  assert_eq "$got" "500 " "the single eligible ticket is still claimed" || return 1
  assert_contains "$log" "candidates=1" "log carries candidates=N" || return 1
}

test_rq_malformed_milestone_degrades_not_aborts() {
  si_env
  jq -n '[{number:7,repo:"project-a/repo-a",labels:[{name:"agent-go"}],milestone:{title:null}},{number:8,repo:"project-a/repo-a",labels:[{name:"agent-go"}],milestone:{title:"v1.0.0"}}]' > "$SI_D/issues.json"
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "8 " "malformed milestone does not abort the tick; valid one claimed first" || return 1
}

test_rq_cap_warning_only_at_the_cap() {
  si_env; rq_bulk 500 1000 "v1.0.0"; rq_wrap failclaim; si_tick
  local at; at=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); si_cleanup
  si_env; rq_bulk 499 1000 "v1.0.0"; rq_wrap failclaim; si_tick
  local below; below=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); si_cleanup
  assert_contains "$at" "reached the 500 cap" "warning logged at the cap" || return 1
  assert_not_contains "$below" "reached the 500 cap" "no warning below the cap" || return 1
}

test_rq_listing_failure_is_logged_tagged_and_alerted() {
  si_env; rq_issue 8 "v1.0.0"; rq_wrap listfail; rq_tick
  local log calls; log=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); calls=$(cat "$SI_D/curl.log" 2>/dev/null); si_cleanup
  assert_contains "$log" "listing or release sort failed" "failure logged" || return 1
  assert_contains "$log" "HTTP 502 boom" "stderr kept" || return 1
  assert_contains "$log" "route=dispatch-order" "route tag" || return 1
  assert_contains "$log" "release=" "release tag" || return 1
  assert_contains "$log" "environment=" "environment tag" || return 1
  assert_contains "$calls" "chat.postMessage" "alert posted via the existing Slack path" || return 1
}

test_rq_sort_failure_is_logged_and_alerted() {
  si_env; rq_issue 8 "v1.0.0"; rq_wrap garbage; rq_tick
  local log calls; log=$(cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null); calls=$(cat "$SI_D/curl.log" 2>/dev/null); si_cleanup
  assert_contains "$log" "listing or release sort failed" "sort failure logged" || return 1
  assert_contains "$calls" "chat.postMessage" "alert posted" || return 1
}

test_rq_numeric_milestone_title_sorts_last_not_abort() {
  si_env
  jq -n '[{number:7,repo:"project-a/repo-a",labels:[{name:"agent-go"}],milestone:{title:5}},{number:8,repo:"project-a/repo-a",labels:[{name:"agent-go"}],milestone:{title:"v1.0.0"}}]' > "$SI_D/issues.json"
  rq_wrap failclaim; si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "8 7 " "non-string title sorts last, tick not aborted" || return 1
}

run_test test_rq_release_order_and_nonversion_last
run_test test_rq_in_progress_dropped_before_cap
run_test test_rq_malformed_milestone_degrades_not_aborts
run_test test_rq_cap_warning_only_at_the_cap
run_test test_rq_listing_failure_is_logged_tagged_and_alerted
run_test test_rq_sort_failure_is_logged_and_alerted
run_test test_rq_numeric_milestone_title_sorts_last_not_abort
