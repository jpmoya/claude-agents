# claude-agents#387 — the supervisor must not count a failed GitHub read as "no progress".
# 2026-10-17: JP's GraphQL allowance ran out; latest_marker (GraphQL) printed "?", the restart path counted it as
# no progress, and four runs sitting on real gates were escalated "too many restarts without progress".
#
#   AC1  latest_marker reads comments over REST, paginated + slurped (>100 comments = same gate marker)
#   AC2  a failed read prints "?" and logs one `[marker] <repo>#<n> — marker read failed rc=<code>: <gh stderr line 1>`
#   AC3  restart path: marker "?" is transient — total advances, count does not, last_marker not overwritten
#   AC4  a good read equal to last_marker still counts; 3 still escalate
#   AC5  repo name for the launch prompt (and every other lookup) comes from REST, not `gh repo view`
#   AC6  GraphQL failing + REST giving MOCKUPS PENDING APPROVAL => parked; REST failing too => never escalates
#
# Fake gh (wrapper in front of the fixture fake): `gh api repos/*/issues/*/comments*` serves $D/rest-pages/page*.json
# (or fails with the rc in $D/rest-fail), `gh api repos/<o>/<r>` serves the name, and `gh issue view|list` /
# `gh repo view` (GraphQL) fail when $D/graphql-fail exists. Placeholder repo names only.

HERE_N3=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "n3_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_N3/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f n3_real_run_test | sed '1s/n3_real_run_test/run_test/')"
fi
SUP_N3="$HERE_N3/../supervisor.sh"
N3_GATE='**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'
N3_SECRET='ghp_SECRETTOKEN0123456789'

# n3_install_gh <dir> — wrap the fixture fake gh already in <dir> (mk_fake_gh) with the REST/GraphQL behaviour above.
n3_install_gh() {
  local d=$1
  mkdir -p "$d/rest-pages"
  mv "$d/gh" "$d/gh.orig"
  cat > "$d/gh" <<'GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
case "$1" in
  api)
    printf '%s\n' "$*" >> "$D/gh-calls.log"
    case "$2" in
      repos/*/issues/*/comments*)
        if [ -f "$D/rest-fail" ]; then
          echo "HTTP 403: API rate limit exceeded" >&2
          echo "Authorization: token $GH_TOKEN" >&2
          exit "$(cat "$D/rest-fail")"
        fi
        expr=""; slurp=0; prev=""
        for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; [ "$a" = "--slurp" ] && slurp=1; prev=$a; done
        if [ -n "$expr" ]; then for p in "$D"/rest-pages/page*.json; do jq -r "$expr" "$p" || exit 1; done   # --paginate --jq: per page
        elif [ "$slurp" = 1 ]; then jq -s . "$D"/rest-pages/page*.json
        else cat "$D"/rest-pages/page*.json; fi
        exit 0 ;;
      repos/*/*)
        case "$2" in */issues*|*/pulls*) ;; *) cat "$D/gh-name-with-owner"; exit 0 ;; esac ;;
    esac ;;
  issue|repo)
    case "$1 $2" in "issue view"|"issue list"|"repo view")
      printf '%s\n' "$*" >> "$D/gh-calls.log"
      if [ -f "$D/graphql-fail" ]; then echo "GraphQL: API rate limit already exceeded for user ID 12925455" >&2; exit 1; fi ;;
    esac ;;
esac
exec "$D/gh.orig" "$@"
GH_EOF
  chmod +x "$d/gh"
}

# n3_page <dir> <n> <jq-array-program> — write rest-pages/page<n>.json
n3_page() { local d=$1 n=$2; shift 2; jq -n "$@" > "$d/rest-pages/page$n.json"; }
n3_c() { jq -n --arg b "$1" '{body:$b, created_at:"2026-10-17T18:00:00Z", user:{login:"jpmoya"}}'; }

# n3_fn_run <dir> — latest_marker for issue 42 in a sandbox. Sets N3_OUT / N3_LOG. GraphQL is down.
n3_fn_run() {
  local d=$1 repo="$1/repo"
  N3_OUT=$( cd "$HERE_N3/.." && PATH="$d:$PATH" GH_TOKEN="$N3_SECRET" bash -c '
    D=$1; REPO=$2
    . ../../hooks/pipeline-markers.sh; . ./pipeline-lib.sh
    slog() { printf "%s\n" "$*" >> "$D/slog.txt"; }
    eval "$(sed -n "/^latest_marker() {/,/^}/p" ./supervisor.sh)"
    latest_marker "$REPO" 42' _ "$d" "$repo" 2>/dev/null )
  N3_LOG=$(cat "$d/slog.txt" 2>/dev/null)
}
n3_fn_env() {
  N3_D=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-n3.XXXXXX")
  fixture_repo "$N3_D/repo" "project-a/repo-a"
  mk_fake_gh "$N3_D"; n3_install_gh "$N3_D"
  echo "project-a/repo-a" > "$N3_D/gh-name-with-owner"
  touch "$N3_D/graphql-fail"
}

# ---- AC1: REST, paginated, slurped -------------------------------------------------------------

# hand arithmetic: 120 comments in two pages (100 + 20); the gate (BLOCKED) is #5 on page 1, the
# [delivery-lead] DECISION is #110 on page 2 => output "<gate>\n<decision>", exactly as one page would give.
test_n3_1a_two_pages_same_result_as_one_page() {
  n3_fn_env
  local gate dec
  gate='**[fullstack-developer] BLOCKED**'; dec='**[delivery-lead] DECISION**'
  n3_page "$N3_D" 1 --arg g "$gate" '[range(0;100) | {body: (if . == 4 then $g else "chatter \(.)" end), created_at:"2026-10-17T18:00:00Z"}]'
  n3_page "$N3_D" 2 --arg d "$dec" '[range(0;20) | {body: (if . == 9 then $d else "more chatter \(.)" end), created_at:"2026-10-17T19:00:00Z"}]'
  n3_fn_run "$N3_D"; local two=$N3_OUT args; args=$(gh_calls "$N3_D")
  jq -s 'add' "$N3_D/rest-pages/page1.json" "$N3_D/rest-pages/page2.json" > "$N3_D/one.json"
  jq -c . "$N3_D/one.json" > "$N3_D/rest-pages/page1.json"; rm "$N3_D/rest-pages/page2.json"
  n3_fn_run "$N3_D"; local one=$N3_OUT
  rm -rf "$N3_D"
  assert_eq "$two" "$(printf '%s\n%s' "$gate" "$dec")" "#387/1a: gate + later delivery-lead marker found across two pages" || return 1
  assert_eq "$one" "$two" "#387/1a: one-page and two-page reads agree" || return 1
  assert_contains "$args" "repos/" "#387/1a: comments read via gh api (REST)" || return 1
  assert_contains "$args" "issues/42/comments?per_page=100" "#387/1a: REST comments endpoint, per_page=100" || return 1
  assert_contains "$args" "--paginate" "#387/1a: paginated" || return 1
  assert_not_contains "$args" "issue view" "#387/1a: no GraphQL issue view" || return 1
}

# the newest marker is on page 2 and is itself the gate: a read that stopped at page 1 would return the page-1 one.
test_n3_1b_gate_on_second_page_wins() {
  n3_fn_env
  n3_page "$N3_D" 1 '[range(0;100) | {body: (if . == 50 then "**[fullstack-developer] IMPLEMENTED**" else "x \(.)" end)}]'
  n3_page "$N3_D" 2 --arg g "$N3_GATE" '[{body: $g}]'
  n3_fn_run "$N3_D"; local out=$N3_OUT
  rm -rf "$N3_D"
  assert_eq "$out" "$N3_GATE" "#387/1b: marker on page 2 is the gate" || return 1
}

test_n3_1c_no_comments_is_none_not_error() {
  n3_fn_env
  echo '[]' > "$N3_D/rest-pages/page1.json"
  n3_fn_run "$N3_D"; local out=$N3_OUT log=$N3_LOG
  rm -rf "$N3_D"
  assert_eq "$out" "none" "#387/1c: empty comment list => none" || return 1
  assert_eq "$log" "" "#387/1c: an empty list is not a failed read" || return 1
}

# ---- AC2: failed read => "?" + one log line ----------------------------------------------------

# rc 4 (not 1) so a hard-coded code fails. Line 2 of gh's stderr carries the token and must not be logged.
test_n3_2a_failed_read_prints_question_mark_and_logs_one_line() {
  n3_fn_env
  echo 4 > "$N3_D/rest-fail"
  n3_page "$N3_D" 1 '[{body:"COMMENTBODY-SHOULD-NOT-LEAK"}]'
  n3_fn_run "$N3_D"; local out=$N3_OUT log=$N3_LOG
  rm -rf "$N3_D"
  assert_eq "$out" "?" "#387/2a: failed read prints ?" || return 1
  if ! printf '%s\n' "$log" | grep -Eq '^\[marker\] [^ ]+#42 — marker read failed rc=4: HTTP 403: API rate limit exceeded$'; then
    fail "#387/2a: expected one '[marker] <repo>#42 — marker read failed rc=4: HTTP 403: API rate limit exceeded' line, got: $log"; return 1
  fi
  assert_eq "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" "1" "#387/2a: exactly one log line" || return 1
  assert_not_contains "$log" "$N3_SECRET" "#387/2a: no token in the log line" || return 1
  assert_not_contains "$log" "Authorization" "#387/2a: only the first stderr line is logged" || return 1
  assert_not_contains "$log" "COMMENTBODY" "#387/2a: no comment body in the log line" || return 1
}

test_n3_2b_good_read_logs_nothing() {
  n3_fn_env
  n3_page "$N3_D" 1 --arg g "$N3_GATE" '[{body: $g}]'
  n3_fn_run "$N3_D"; local out=$N3_OUT log=$N3_LOG
  rm -rf "$N3_D"
  assert_eq "$out" "$N3_GATE" "#387/2b: good read returns the marker" || return 1
  assert_eq "$log" "" "#387/2b: good read logs no [marker] line" || return 1
}

# ---- tick-level fixtures -------------------------------------------------------------------------

# n3_env — isolated tick env (open slots), wrapped gh, GraphQL down, issue 42 exited 600 s ago (not transient).
n3_env() {
  sq_env open
  n3_install_gh "$SQ_GH"
  touch "$SQ_GH/graphql-fail"
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
}
n3_rest_marker() { n3_page "$SQ_GH" 1 --arg g "$1" '[{body: $g, created_at:"2026-10-17T18:00:00Z"}]'; }
# n3_exit_tick — a fresh non-transient exit: launched 600 s ago, no queue entry, then one tick.
n3_exit_tick() {
  sq_iso_ago 600 > "$(rkp "$SQ_PIPE/orch-42.launched-at")"
  rm -f "$(rkp "$SQ_PIPE/queue/orch-42.json")"
  sq_tick
}

# ---- AC3 / AC6: failed read is transient ---------------------------------------------------------

# hand arithmetic: three "?" exits => total 3, count 0 (was 3 => escalate), last_marker still READY, never "?".
test_n3_3a_three_failed_reads_do_not_escalate() {
  n3_env
  rm -f "$SQ_GH/rest-pages/"*; touch "$SQ_GH/rest-fail"; echo 1 > "$SQ_GH/rest-fail"
  sq_seed_restarts 0 0 "$SQ_READY"
  n3_exit_tick; n3_exit_tick; n3_exit_tick
  local count total last held log
  count=$(sq_restarts_field count); total=$(sq_restarts_field total); last=$(sq_restarts_field last_marker)
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); log=$(sq_log)
  sq_cleanup
  assert_not_contains "$log" "[escalate] #42" "#387/3a: no escalation on three failed reads" || return 1
  assert_not_contains "$log" "without progress" "#387/3a: no 'without progress' claim" || return 1
  assert_eq "$held" "absent" "#387/3a: not held" || return 1
  assert_eq "$count" "0" "#387/3a: count does not advance" || return 1
  assert_eq "$total" "3" "#387/3a: total advances once per exit (and is not reset as 'progress')" || return 1
  assert_eq "$last" "$SQ_READY" "#387/3a: last_marker not overwritten with ?" || return 1
  assert_not_contains "$log" "[progress]" "#387/3a: ? is not marker progress" || return 1
  assert_eq "$(printf '%s\n' "$log" | grep -c 'marker read failed rc=1')" "3" "#387/3a: the failed-read line is logged every time" || return 1
}

# MAX_TOTAL=6 still applies: total 5 + this failed-read exit = 6 => escalate (via total, not count).
test_n3_3b_failed_reads_still_hit_total_ceiling() {
  n3_env
  rm -f "$SQ_GH/rest-pages/"*; echo 1 > "$SQ_GH/rest-fail"
  sq_seed_restarts 0 5 "$SQ_READY"
  n3_exit_tick
  local held log count
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); log=$(sq_log); count=$(sq_restarts_field count)
  sq_cleanup
  assert_eq "$held" "present" "#387/3b: sixth exit hits MAX_TOTAL and holds" || return 1
  assert_contains "$log" "[escalate] #42" "#387/3b: escalation logged at the total ceiling" || return 1
  assert_eq "$count" "0" "#387/3b: count still 0" || return 1
}

# ---- AC4: good unchanged read still counts -------------------------------------------------------

# hand arithmetic: count 2 + this exit = 3 = MAX_NO_PROGRESS; marker (via REST) equals last_marker => escalate.
test_n3_4a_good_read_equal_to_last_marker_counts_and_escalates() {
  n3_env
  n3_rest_marker "$SQ_READY"
  sq_seed_restarts 2 2 "$SQ_READY"
  n3_exit_tick
  local held log count
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); log=$(sq_log); count=$(sq_restarts_field count)
  sq_cleanup
  assert_eq "$count" "3" "#387/4a: count advanced to 3" || return 1
  assert_eq "$held" "present" "#387/4a: held on the third no-progress exit" || return 1
  assert_contains "$log" "[escalate] #42" "#387/4a: escalation logged" || return 1
  assert_not_contains "$log" "marker read failed" "#387/4a: a good read logs no failure" || return 1
}

test_n3_4b_good_read_equal_to_last_marker_counts_below_cap() {
  n3_env
  n3_rest_marker "$SQ_READY"
  sq_seed_restarts 0 0 "$SQ_READY"
  n3_exit_tick
  local count total last
  count=$(sq_restarts_field count); total=$(sq_restarts_field total); last=$(sq_restarts_field last_marker)
  sq_cleanup
  assert_eq "$count" "1" "#387/4b: unchanged marker => count 1" || return 1
  assert_eq "$total" "1" "#387/4b: total 1" || return 1
  assert_eq "$last" "$SQ_READY" "#387/4b: last_marker kept" || return 1
}

# ---- AC6: gate parked with GraphQL down ----------------------------------------------------------

test_n3_6a_graphql_down_rest_gate_is_parked_not_restarted() {
  n3_env
  n3_rest_marker "$N3_GATE"
  sq_seed_restarts 0 0 "$SQ_READY"
  n3_exit_tick
  local held log queue calls
  held=$(sq_present "$(rkp "$SQ_PIPE/orch-42.held")"); log=$(sq_log)
  queue=$(sq_present "$(rkp "$SQ_PIPE/queue/orch-42.json")"); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$held" "present" "#387/6a: parked as a gate" || return 1
  assert_contains "$log" "[held] #42" "#387/6a: held line logged" || return 1
  assert_contains "$log" "MOCKUPS PENDING APPROVAL" "#387/6a: gate named in the log" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "#387/6a: not restarted" || return 1
  assert_eq "$queue" "absent" "#387/6a: nothing queued for relaunch" || return 1
  assert_contains "$calls" "issues/42/comments" "#387/6a: the supervisor read the marker over REST" || return 1
}

# ---- AC5: repo name over REST --------------------------------------------------------------------

test_n3_5a_launch_prompt_has_repo_name_when_graphql_down() {
  n3_env
  sq_free_slots
  mk_queued "$SQ_PIPE" 42 "$SQ_REPO"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/claude-args"\nexit 0\n' "$SQ_GH" > "$SQ_GH/claude"; chmod +x "$SQ_GH/claude"
  n3_rest_marker "$SQ_READY"
  sq_tick
  local i args=""
  for i in $(seq 1 50); do [ -s "$SQ_GH/claude-args" ] && break; sleep 0.1; done
  args=$(cat "$SQ_GH/claude-args" 2>/dev/null)
  sq_cleanup
  assert_contains "$args" "Drive project-a/repo-a#42" "#387/5a: prompt names the repo from REST" || return 1
  assert_not_contains "$args" "unknown#42" "#387/5a: no 'Drive unknown#42'" || return 1
}

test_n3_5b_no_graphql_repo_view_left_in_supervisor() {
  local hits
  hits=$(grep -n 'gh repo view' "$SUP_N3" | grep -F 'nameWithOwner')
  assert_eq "$hits" "" "#387/5b: no 'gh repo view --json nameWithOwner' lookup left in supervisor.sh" || return 1
}

run_test test_n3_1a_two_pages_same_result_as_one_page
run_test test_n3_1b_gate_on_second_page_wins
run_test test_n3_1c_no_comments_is_none_not_error
run_test test_n3_2a_failed_read_prints_question_mark_and_logs_one_line
run_test test_n3_2b_good_read_logs_nothing
run_test test_n3_3a_three_failed_reads_do_not_escalate
run_test test_n3_3b_failed_reads_still_hit_total_ceiling
run_test test_n3_4a_good_read_equal_to_last_marker_counts_and_escalates
run_test test_n3_4b_good_read_equal_to_last_marker_counts_below_cap
run_test test_n3_6a_graphql_down_rest_gate_is_parked_not_restarted
run_test test_n3_5a_launch_prompt_has_repo_name_when_graphql_down
run_test test_n3_5b_no_graphql_repo_view_left_in_supervisor
