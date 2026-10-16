# Issue #315 — supervisor promotes a deferred child (inherited approval, start-gate open) to agent-go once its start-gate(s) close
# as completed. Whole ticks run in the si_* harness of test-intake-supervisor.sh (sourced earlier by the runner), with a richer
# stub `gh` that serves issue list/view with number,title,body,labels,state,stateReason,closedByPullRequestsReferences,comments.
# MAX_CONCURRENT=0 so the dispatch step never consumes the agent-go the promotion adds: the label stays observable.
# Placeholder repo names only. Expected values are from the ticket's "Decided design" and fixtures (1)-(7).

# pc_env [<DISPATCH entries>] — si_env + MAX_CONCURRENT=0 + the stateful gh stub
pc_env() {
  type si_env >/dev/null 2>&1 || { fail "si_env harness missing"; return 1; }
  si_env "$@"
  echo 'MAX_CONCURRENT=0' >> "$SI_HOME/.claude/pipeline/config.local.sh"
  cat > "$SI_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/gh-calls.log"
jqx=""; label=""; repo=""; prev=""; state="open"; body=""; adds=""; rems=""
for a in "$@"; do
  case "$prev" in --jq|-q) jqx=$a;; --label) label=$a;; --repo) repo=$a;; --state) state=$a;; --body) body=$a;;
    --add-label) adds="$adds,$a";; --remove-label) rems="$rems,$a";; esac; prev=$a
done
[ -z "$repo" ] && repo=$(cd "$PWD" && git config --get remote.origin.url | sed -E 's#.*github.com/(.*)\.git#\1#')
out() { if [ -n "$jqx" ]; then printf '%s' "$1" | jq -r "$jqx"; else printf '%s\n' "$1"; fi; }
num=$(printf '%s' "$3" | grep -E '^[0-9]+$')
FIELDS='{number,title,body,state,stateReason,labels,comments,closedByPullRequestsReferences}'
case "$1 $2" in
  "repo view") echo "$repo"; exit 0;;
  "issue list")
    j=$(jq -c --arg r "$repo" --arg l "$label" --arg s "$state" "[.[] | select(.repo==\$r)
      | select(\$s==\"all\" or (.state|ascii_downcase)==\$s) | select(\$l==\"\" or ([.labels[].name]|index(\$l))) | $FIELDS]" "$D/issues.json")
    out "$j"; exit 0;;
  "issue view")
    j=$(jq -c --arg r "$repo" --argjson n "${num:-0}" ".[] | select(.repo==\$r and .number==\$n) | $FIELDS" "$D/issues.json")
    [ -n "$j" ] || exit 1; out "$j"; exit 0;;
  "issue comment") now=$(date -u +%FT%TZ)
    jq --argjson n "${num:-0}" --arg r "$repo" --arg b "$body" --arg t "$now" \
      'map(if .number==$n and .repo==$r then .comments += [{body:$b,createdAt:$t}] else . end)' "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"
    exit 0;;
  "issue edit")
    [ -f "$D/edit-fail" ] && case "$adds" in *agent-go*) exit 1;; esac
    jq --argjson n "${num:-0}" --arg r "$repo" --arg a "$adds" --arg m "$rems" '
      map(if .number==$n and .repo==$r then .labels = ((.labels|map(.name)) - ($m|split(",")) + ($a|split(",")|map(select(.!=""))) | unique | map({name:.})) else . end)' \
      "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"; exit 0;;
esac
exit 0
X
  chmod +x "$SI_D/gh"
  echo '[]' > "$SI_D/issues.json"
}

# pc_issue <num> <repo> <OPEN|COMPLETED|NOT_PLANNED> <body> <label>...
pc_issue() {
  local n=$1 r=$2 st=$3 b=$4; shift 4
  local state=OPEN reason=null prs='[]'
  case "$st" in COMPLETED) state=CLOSED; reason='"COMPLETED"'; prs='[{"number":99}]';; NOT_PLANNED) state=CLOSED; reason='"NOT_PLANNED"';; esac
  jq --argjson n "$n" --arg r "$r" --arg s "$state" --argjson why "$reason" --argjson prs "$prs" --arg b "$b" \
    --argjson l "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(.!="")|{name:.})')" \
    '. + [{number:$n,repo:$r,title:"t",body:$b,state:$s,stateReason:$why,closedByPullRequestsReferences:$prs,labels:$l,comments:[]}]' \
    "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
}
# pc_note <num> <repo> <gate#> — the PM deferral NOTE exactly as product-manager.md files it
pc_note() {
  jq --argjson n "$1" --arg r "$2" --arg b "**[product-manager] NOTE** approval inherited from project-a/repo-a#5 — agent-go deferred: start-gate #$3 open" \
    'map(if .number==$n and .repo==$r then .comments += [{body:$b,createdAt:"2026-10-01T00:00:00Z"}] else . end)' \
    "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
}
pc_bodies() { jq -r --argjson n "$1" '.[]|select(.number==$n)|.comments[].body' "$SI_D/issues.json"; }
# first lines of the supervisor's promotion NOTEs on an issue
pc_promos() { pc_bodies "$1" | grep -E '^\*\*\[supervisor\] NOTE\*\* approval inherited from' ; true; }
pc_slog() { cat "$SI_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
# pc_control — a promotable child (#91, gate #90 completed): the negative tests assert it IS promoted, so they cannot pass vacuously
pc_control() { pc_issue 90 project-a/repo-a COMPLETED "control gate"; pc_issue 91 project-a/repo-a OPEN "control child" agent-proposed; pc_note 91 project-a/repo-a 90; }
PC_NOTE21='**[supervisor] NOTE** approval inherited from project-a/repo-a#5 — start-gate #10 closed'

# --- fixture 1 + AC1/AC2: gate closed completed -> labelled + one NOTE; second tick no-op
test_pc_closed_gate_promotes_once() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed enhancement; pc_note 21 $R 10
  si_tick
  local l1 p1 n1; l1=$(si_labels 21); p1=$(pc_promos 21); n1=$(printf '%s\n' "$p1" | grep -c .)
  si_tick
  local l2 n2 adds; l2=$(si_labels 21); n2=$(pc_promos 21 | grep -c .); adds=$(grep -c -- '--add-label agent-go' "$SI_D/gh-calls.log")
  . "$(dirname "${BASH_SOURCE[0]}")/../../../hooks/pipeline-markers.sh"
  local hit; hit=$(jq -n --arg s "$p1" "\$s | test($(marker_re | jq -Rs .))")
  si_cleanup
  assert_eq "$l1" "agent-go,enhancement" "agent-go added, agent-proposed removed, other labels kept" || return 1
  assert_eq "$n1" "1" "exactly one promotion NOTE after the first tick" || return 1
  assert_eq "$hit" "false" "AC2: the posted NOTE is not a routing marker (stages ignore it)" || return 1
  assert_eq "$p1" "$PC_NOTE21" "AC2: NOTE first line is the supervisor NOTE form with the deferral NOTE's ref" || return 1
  assert_eq "$l2" "agent-go,enhancement" "second tick leaves labels alone" || return 1
  assert_eq "$n2" "1" "second tick posts no second NOTE (idempotent)" || return 1
  assert_eq "$adds" "1" "agent-go added exactly once across two ticks" || return 1
}

# --- fixture 2: gate still open
test_pc_open_gate_does_nothing() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R OPEN "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  pc_control
  si_tick
  local l p; l=$(si_labels 21); p=$(pc_promos 21); local lc; lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: a promotable child was promoted" || return 1
  assert_eq "$l" "agent-proposed" "open gate: labels untouched" || return 1
  assert_eq "$p" "" "open gate: no promotion NOTE" || return 1
}

# --- fixture 3 + AC6: gate closed as not planned -> no promotion, refusal is logged with repo, issue and reason
test_pc_not_planned_gate_does_not_promote_and_logs() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R NOT_PLANNED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  si_tick
  local l p line; l=$(si_labels 21); p=$(pc_promos 21)
  line=$(pc_slog | grep -F "$R" | grep -E '21' | grep -iE 'not[ _]planned' | head -1); si_cleanup
  assert_eq "$l" "agent-proposed" "not planned gate: left for JP" || return 1
  assert_eq "$p" "" "not planned gate: no promotion NOTE" || return 1
  assert_ne "$line" "" "AC6: slog line naming repo, issue 21 and the not-planned reason on the refused path" || return 1
}

# --- fixture 4: two start-gates, one still open
test_pc_two_gates_one_open_does_nothing() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate a"; pc_issue 11 $R OPEN "gate b"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10; pc_note 21 $R 11
  pc_control
  si_tick
  local l p; l=$(si_labels 21); p=$(pc_promos 21); local lc; lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: a promotable child was promoted" || return 1
  assert_eq "$l" "agent-proposed" "one gate open: labels untouched" || return 1
  assert_eq "$p" "" "one gate open: no promotion NOTE" || return 1
}

test_pc_two_gates_both_closed_completed_promotes() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate a"; pc_issue 11 $R COMPLETED "gate b"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10; pc_note 21 $R 11
  si_tick
  local l n; l=$(si_labels 21); n=$(pc_promos 21 | grep -c .); si_cleanup
  assert_eq "$l" "agent-go" "all gates closed-completed: promoted" || return 1
  assert_eq "$n" "1" "one promotion NOTE for the ticket" || return 1
}

# --- several gates, one closed as not planned -> not all closed-completed
test_pc_two_gates_one_not_planned_does_nothing() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate a"; pc_issue 11 $R NOT_PLANNED "gate b"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10; pc_note 21 $R 11
  pc_control
  si_tick
  local l p; l=$(si_labels 21); p=$(pc_promos 21); local lc; lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: a promotable child was promoted" || return 1
  assert_eq "$l" "agent-proposed" "a not-planned gate blocks promotion" || return 1
  assert_eq "$p" "" "no promotion NOTE" || return 1
}

# --- design: a gate named only by "Depends on #N for starting work" in the body counts too
test_pc_body_gate_still_open_blocks_promotion() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate a"; pc_issue 11 $R OPEN "gate b"
  pc_issue 21 $R OPEN $'child\nDepends on #11 for starting work' agent-proposed; pc_note 21 $R 10
  pc_control
  si_tick
  local l p; l=$(si_labels 21); p=$(pc_promos 21); local lc; lc=$(si_labels 91); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: a promotable child was promoted" || return 1
  assert_eq "$l" "agent-proposed" "open body gate #11: labels untouched" || return 1
  assert_eq "$p" "" "open body gate #11: no promotion NOTE" || return 1
}

# --- fixture 5: Business-Intelligence never promoted (listed first; positive control proves the step ran)
test_pc_business_intelligence_never_promoted() {
  pc_env "project-c/Business-Intelligence:@PIPE@/repo-b" "project-a/repo-a:@PIPE@/repo-a"
  pc_issue 10 project-c/Business-Intelligence COMPLETED "gate"
  pc_issue 21 project-c/Business-Intelligence OPEN "child" agent-proposed; pc_note 21 project-c/Business-Intelligence 10
  pc_issue 30 project-a/repo-a COMPLETED "gate"
  pc_issue 31 project-a/repo-a OPEN "child" agent-proposed; pc_note 31 project-a/repo-a 30
  si_tick
  local lbi pbi lctl; lbi=$(jq -r '.[]|select(.repo=="project-c/Business-Intelligence" and .number==21)|[.labels[].name]|join(",")' "$SI_D/issues.json")
  pbi=$(pc_promos 21); lctl=$(si_labels 31); si_cleanup
  assert_eq "$lctl" "agent-go" "positive control: the non-BI child was promoted" || return 1
  assert_eq "$lbi" "agent-proposed" "BI child untouched" || return 1
  assert_eq "$pbi" "" "BI child gets no promotion NOTE" || return 1
}

# --- source:sentry guard
test_pc_sentry_issue_never_promoted() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed source:sentry; pc_note 21 $R 10
  pc_issue 22 $R OPEN "child" agent-proposed; pc_note 22 $R 10
  si_tick
  local ls lc p; ls=$(si_labels 21); lc=$(si_labels 22); p=$(pc_promos 21); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: the plain child was promoted" || return 1
  assert_eq "$ls" "agent-proposed,source:sentry" "source:sentry child untouched" || return 1
  assert_eq "$p" "" "source:sentry child gets no promotion NOTE" || return 1
}

# --- fixture 6: plain agent-proposed, no inherited-approval NOTE -> nothing (even with a closed body gate)
test_pc_no_inherited_approval_note_does_nothing() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN $'child\nDepends on #10 for starting work' agent-proposed
  pc_issue 22 $R OPEN "child" agent-proposed; pc_note 22 $R 10
  si_tick
  local l p lc; l=$(si_labels 21); p=$(pc_promos 21); lc=$(si_labels 22); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: child with the deferral NOTE promoted" || return 1
  assert_eq "$l" "agent-proposed" "no inherited approval: labels untouched" || return 1
  assert_eq "$p" "" "no inherited approval: no promotion NOTE" || return 1
}

# --- fixture 7: already agent-go / agent-in-progress -> nothing
test_pc_already_labelled_does_nothing() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-go; pc_note 21 $R 10
  pc_issue 22 $R OPEN "child" agent-in-progress; pc_note 22 $R 10
  pc_issue 23 $R OPEN "child" agent-proposed; pc_note 23 $R 10
  si_tick
  local p21 p22 l22 lc; p21=$(pc_promos 21); p22=$(pc_promos 22); l22=$(si_labels 22); lc=$(si_labels 23); si_cleanup
  assert_eq "$lc" "agent-go" "positive control: unlabelled child promoted" || return 1
  assert_eq "$p21" "" "agent-go child: no promotion NOTE" || return 1
  assert_eq "$p22" "" "agent-in-progress child: no promotion NOTE" || return 1
  assert_eq "$l22" "agent-in-progress" "agent-in-progress child: labels untouched" || return 1
}

# --- AC4: promotion adds agent-go only — never any other label
test_pc_promotion_adds_only_agent_go() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  si_tick
  local adds; adds=$(grep -o -- '--add-label [^ ]*' "$SI_D/gh-calls.log" | sort -u | tr '\n' ' '); local l; l=$(si_labels 21); si_cleanup
  assert_eq "$l" "agent-go" "promoted" || return 1
  assert_eq "$adds" "--add-label agent-go " "AC4: the only label ever added is agent-go (no JP-gate label, no agent-in-progress)" || return 1
}

# --- AC6: a failed label write is logged with repo, issue and reason, and retried next tick (no stuck state)
test_pc_label_write_failure_is_logged_and_retried() {
  pc_env; local R=project-a/repo-a
  pc_issue 10 $R COMPLETED "gate"
  pc_issue 21 $R OPEN "child" agent-proposed; pc_note 21 $R 10
  touch "$SI_D/edit-fail"
  si_tick
  local l1 line; l1=$(si_labels 21); line=$(pc_slog | grep -F "$R" | grep -E '21' | grep -iE 'fail' | head -1)
  rm -f "$SI_D/edit-fail"; si_tick
  local l2; l2=$(si_labels 21); si_cleanup
  assert_eq "$l1" "agent-proposed" "failed edit: labels unchanged" || return 1
  assert_ne "$line" "" "AC6: slog line with repo, issue 21 and a failure reason" || return 1
  assert_eq "$l2" "agent-go" "next tick retries and promotes" || return 1
}

run_test test_pc_closed_gate_promotes_once
run_test test_pc_open_gate_does_nothing
run_test test_pc_not_planned_gate_does_not_promote_and_logs
run_test test_pc_two_gates_one_open_does_nothing
run_test test_pc_two_gates_both_closed_completed_promotes
run_test test_pc_two_gates_one_not_planned_does_nothing
run_test test_pc_body_gate_still_open_blocks_promotion
run_test test_pc_business_intelligence_never_promoted
run_test test_pc_sentry_issue_never_promoted
run_test test_pc_no_inherited_approval_note_does_nothing
run_test test_pc_already_labelled_does_nothing
run_test test_pc_promotion_adds_only_agent_go
run_test test_pc_label_write_failure_is_logged_and_retried
