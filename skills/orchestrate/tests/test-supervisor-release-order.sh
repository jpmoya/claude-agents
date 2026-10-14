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

test_rq_release_order_and_nonversion_last() {
  si_env
  # newest-first listing, as GitHub returns it
  rq_issue 900 ""; rq_issue 899 staging; rq_issue 898 "v1.20.13 - e"; rq_issue 897 "v1.20.10 - d"
  rq_issue 896 "v1.20.3 - c"; rq_issue 895 "v1.20.2 - b"; rq_issue 894 "v1.20.2 - b"; rq_issue 893 "garbage"
  # make every claim attempt fail so the loop walks the whole list in order
  mv "$SI_D/gh" "$SI_D/gh.real"
  printf '#!/bin/bash\necho "$*" >> "%s/gh-calls.log"\nif [ "$1 $2" = "issue comment" ]; then exit 1; fi\nexec "%s/gh.real" "$@"\n' "$SI_D" "$SI_D" > "$SI_D/gh"; chmod +x "$SI_D/gh"
  si_tick
  local got; got=$(rq_order); si_cleanup
  assert_eq "$got" "894 895 896 897 898 893 899 900 " "release order, non-version last by number" || return 1
}

test_rq_in_progress_dropped_before_cap() {
  si_env
  local i; for i in $(seq 1 50); do rq_issue $((100+i)) "v1.0.0" agent-go agent-in-progress; done
  rq_issue 500 "v2.0.0"
  # fresh last comment so step 4 (orphan reconcile) leaves the in-progress labels alone
  jq -n --arg t "$(date -u +%FT%TZ)" '[{body:"x",createdAt:$t}]' > "$SI_D/comments.json"
  si_tick
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
