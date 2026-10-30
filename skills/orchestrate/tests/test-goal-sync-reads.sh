# #548 — goal sync reads each ticket ONCE per sync (goal-lib/sync-rereads-all-tickets).
# A counting fake `gh` logs every call; the real goal_eval / _goal_ticket_eval / latest_marker / sw_covered run against it.
# Contract choices made here (the ticket leaves them open):
#   * latest_marker <checkout> <issue> [<comments>]: the optional 3rd argument is the comments as ONE JSON array
#     (the shape `_goal_get_all repos/<r>/issues/<n>/comments?per_page=100` returns); with it, latest_marker makes no gh call.
#   * an "issue read" = a gh call whose path is exactly repos/<r>/issues/<n> (no query string, no /comments).
# Hand arithmetic for the 5-ticket fixture (milestone 12 of proj/repo-a, listing served by the milestone list endpoint):
#   #1 open, newest marker `fullstack-developer BLOCKED` + line 2 `Blocked on: needs_jp`        -> waiting_jp
#   #2 open, newest marker `fullstack-developer IMPLEMENTED`                                     -> active
#   #3 open, newest marker `deployer DEPLOYED`                                                   -> delivered
#   #4 closed in the listing                                                                     -> delivered (no reads at all)
#   #5 open, no comments, label agent-proposed without agent-go                                  -> waiting_jp (labels from the listing)
#   => GE_TOTAL=5 GE_DELIVERED=2 GE_WAITING=2 GE_ACTIVE=1; comments fetches = 4 (#1,#2,#3,#5); issue reads = 0; list reads = 1.
# Prefix ro_ / RO_. Placeholder repo names only.

HERE_RO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_RO=$(cd "$HERE_RO/../../.." && pwd)
SKILL_RO="$HERE_RO/.."

ro_setup() {
  RO_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ro.XXXXXX")
  mkdir -p "$RO_DIR/bin" "$RO_DIR/pipe" "$RO_DIR/co-a" "$RO_DIR/co-new"
  ( cd "$RO_DIR/co-a" && git init -q && git remote add origin https://github.com/proj/repo-a.git ) >/dev/null 2>&1
  ( cd "$RO_DIR/co-new" && git init -q && git remote add origin https://github.com/new-org/ops-tool.git ) >/dev/null 2>&1
  : > "$RO_DIR/gh.log"
  cat > "$RO_DIR/bin/gh" <<'EOF2'
#!/bin/bash
# counting fake gh; D is exported by the harness. One log line per call.
printf '%s\n' "$*" >> "$D/gh.log"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  case "$3" in old-org/scheduler) echo new-org/ops-tool ;; *) echo "$3" ;; esac; exit 0
fi
[ "$1" = "api" ] || { echo "fake gh: unexpected $*" >&2; exit 1; }
shift
args=(); jqx=""
while [ $# -gt 0 ]; do
  case "$1" in --paginate) ;; --jq) jqx=$2; shift ;; *) args+=("$1") ;; esac; shift
done
p=${args[0]}
emit() { if [ -n "$jqx" ]; then jq -r "$jqx" "$1"; else cat "$1"; fi; }
case "$p" in
  repos/old-org/scheduler*) echo "HTTP 301: moved permanently (a redirect is a second billed request)" >&2; exit 1 ;;
  repos/jpmoya/claude-agents/issues\?labels=delivery-goal\&state=open*)
    [ -e "$D/registry-fail" ] && { echo "HTTP 500" >&2; exit 1; }; emit "$D/reg-open.json" ;;
  repos/jpmoya/claude-agents/issues\?labels=delivery-goal\&state=closed*)
    [ -e "$D/registry-fail" ] && { echo "HTTP 500" >&2; exit 1; }; emit "$D/reg-closed.json" ;;
  repos/*/issues\?milestone=*)
    r=${p#repos/}; r=${r%%/issues*}; emit "$D/list-${r//\//_}.json" ;;
  repos/*/issues/*/comments*)
    r=${p#repos/}; r=${r%%/issues*}; n=${p#*/issues/}; n=${n%%/*}
    [ -e "$D/fail-comments-$n" ] && { echo "HTTP 403: API rate limit exceeded" >&2; exit 1; }
    emit "$D/comments-${r//\//_}-$n.json" ;;
  repos/*/issues/*)
    r=${p#repos/}; r=${r%%/issues*}; n=${p##*/}
    if [ ! -e "$D/issue-${r//\//_}-$n.json" ] && [ -e "$D/list-${r//\//_}.json" ]; then   # same object the listing carries
      jq -c --argjson n "$n" '.[] | select(.number == $n)' "$D/list-${r//\//_}.json" > "$D/issue-${r//\//_}-$n.json"
    fi
    [ -s "$D/issue-${r//\//_}-$n.json" ] || { echo "HTTP 404 Not Found" >&2; exit 1; }
    emit "$D/issue-${r//\//_}-$n.json" ;;
  *) echo "fake gh: unexpected path $p" >&2; exit 1 ;;
esac
EOF2
  chmod +x "$RO_DIR/bin/gh"
  # milestone-12 listing (state/labels/user/body travel here)
  jq -n '[{number:1,state:"open",labels:[],user:{login:"jpmoya"},body:""},
          {number:2,state:"open",labels:[],user:{login:"jpmoya"},body:""},
          {number:3,state:"open",labels:[],user:{login:"jpmoya"},body:""},
          {number:4,state:"closed",labels:[],user:{login:"jpmoya"},body:""},
          {number:5,state:"open",labels:[{name:"agent-proposed"}],user:{login:"jpmoya"},body:""}]' > "$RO_DIR/list-proj_repo-a.json"
  ro_comments 1 '**[fullstack-developer] BLOCKED**
Blocked on: needs_jp
waiting for a decision'
  ro_comments 2 '**[fullstack-developer] IMPLEMENTED**'
  ro_comments 3 '**[deployer] DEPLOYED**'
  echo '[]' > "$RO_DIR/comments-proj_repo-a-5.json"
  echo '[]' > "$RO_DIR/reg-open.json"; echo '[]' > "$RO_DIR/reg-closed.json"
}
ro_teardown() { rm -rf "$RO_DIR"; }

ro_comments() {  # ro_comments <n> <body of the one comment>  (repo proj/repo-a, authored by the issue author)
  jq -n --arg b "$2" '[{created_at:"2026-10-01T12:00:00Z",user:{login:"jpmoya"},body:$b}]' > "$RO_DIR/comments-proj_repo-a-$1.json"
}

# ro_reg <issue> <state open|closed> <json block> <labels csv> — one registry issue into reg-open / reg-closed
ro_reg() {
  local f="$RO_DIR/reg-$2.json" body
  body=$(printf '```json\n%s\n```' "$3")
  jq -c --argjson n "$1" --arg s "$2" --arg b "$body" --arg l "$4" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + [{number:$n,state:$s,body:$b,closed_at:(if $s == "closed" then $now else null end),labels:([{name:"delivery-goal"}] + ($l | split(",") | map(select(. != "") | {name:.})))}]' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ro_run <bash code> — runs it with the real goal-lib + every top-level function of supervisor.sh against the fake gh.
# Sets RO_OUT (stdout), RO_RC. Slog lines: $RO_DIR/slog; pipeline events: $RO_DIR/events.log; gh calls: $RO_DIR/gh.log.
ro_run() {
  awk '/^[a-z_]+\(\) *\{.*\}[[:space:]]*(#.*)?$/ {print; next} /^[a-z_]+\(\) *\{/ {on=1} on {print} on && /^}/ {on=0}' "$SKILL_RO/supervisor.sh" > "$RO_DIR/sup-fns.sh"
  RO_OUT=$( export D="$RO_DIR" PATH="$RO_DIR/bin:$PATH" PIPE="$RO_DIR/pipe" LOGDIR="$RO_DIR/logs" HOST=host-test \
              SLOG="$RO_DIR/slog" GRACE_PERIOD_SECS=0 SLACK_WEBHOOK_URL=
            DISPATCH_REPOS=("proj/repo-a:$RO_DIR/co-a" "new-org/ops-tool:$RO_DIR/co-new")
            . "$ROOT_RO/hooks/pipeline-markers.sh"; . "$SKILL_RO/pipeline-lib.sh"; . "$SKILL_RO/goal-lib.sh"
            SW_REGISTRY_LOADED=0; SW_REGISTRY_JSON=""   # supervisor.sh's own initial values (only its functions are loaded)
            . "$RO_DIR/sup-fns.sh"
            slog() { printf '%s\n' "$*" >> "$SLOG"; }
            report_status_async() { :; }
            pipeline_event() { printf '%s\n' "$*" >> "$D/events.log"; }
            eval "$1" 2>"$RO_DIR/stderr" ); RO_RC=$?
}

ro_count() { grep -c -E "$1" "$RO_DIR/gh.log" 2>/dev/null; }                   # calls matching an ERE
ro_issue_reads() { ro_count "^api( --paginate)? repos/$1/issues/$2( |\$)"; }     # exact repos/<r>/issues/<n>

RO_MS_SPEC="proj/repo-a:milestone:12"
RO_MS_ID="proj_repo-a-ms-12"

# ---- AC1: no per-ticket issue read for tickets that came from a scope listing -----------------------------------------
test_ro_ac1_scope_listed_tickets_cost_no_issue_read() {
  ro_setup; local rc=0
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; echo \"\$GE_TOTAL \$GE_DELIVERED \$GE_WAITING \$GE_ACTIVE\""
  assert_eq "$RO_RC" "0" "goal_eval exits 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "$RO_OUT" "5 2 2 1" "AC1/AC5: total delivered waiting active" \
    && assert_eq "$(ro_count '^api( --paginate)? repos/proj/repo-a/issues/[0-9]+( |$)')" "0" "AC1: zero repos/<r>/issues/<n> reads" \
    && assert_eq "$(ro_count 'issues\?milestone=12')" "1" "AC1: the scope listing is read once" || rc=1
  ro_teardown; return $rc
}

test_ro_ac1_labels_and_author_come_from_the_listing() {
  ro_setup; local rc=0
  # #5: labels (agent-proposed, no agent-go) from the listing -> waiting_jp "not approved yet"; asserted via GE_REFS.
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_REFS\" | grep -F 'proj/repo-a#5'"
  assert_contains "$RO_OUT" "waiting_jp	not approved yet" "AC1: labels read from the listing row" || rc=1
  ro_teardown
  # author from the listing: JP (issue author) answers a MOCKUPS gate -> active; a non-author answer leaves it waiting_jp
  local who exp
  for who in jpmoya someone-else; do
    ro_setup
    jq -n --arg w "$who" '[{created_at:"2026-10-01T12:00:00Z",user:{login:"jpmoya"},body:"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nmockups ready"},
                           {created_at:"2026-10-01T13:00:00Z",user:{login:$w},body:"approved"}]' > "$RO_DIR/comments-proj_repo-a-2.json"
    ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_REFS\" | grep -F 'proj/repo-a#2'"
    if [ "$who" = jpmoya ]; then exp="active"; else exp="waiting_jp"; fi
    assert_contains "$RO_OUT" "proj/repo-a#2	$exp" "AC1: answer by $who -> $exp (author taken from the listing)" || rc=1
    assert_eq "$(ro_count '^api( --paginate)? repos/proj/repo-a/issues/[0-9]+( |$)')" "0" "AC1: no issue read ($who)" || rc=1
    ro_teardown
  done
  return $rc
}

test_ro_ac1_start_gate_body_comes_from_the_listing() {
  ro_setup; local rc=0
  # #6: no marker yet, body names an open start-gate dependency -> waiting_jp. Only the dependency (#9) may be read.
  jq -n '[{number:6,state:"open",labels:[],user:{login:"jpmoya"},body:"Depends on proj/repo-a#9 for starting work"}]' > "$RO_DIR/list-proj_repo-a.json"
  echo '[]' > "$RO_DIR/comments-proj_repo-a-6.json"
  jq -n '{number:9,state:"open",labels:[],user:{login:"jpmoya"},body:""}' > "$RO_DIR/issue-proj_repo-a-9.json"
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_REFS\""
  assert_contains "$RO_OUT" "proj/repo-a#6	waiting_jp	waits on proj/repo-a#9" "AC1: start-gate parsed from the listing's body" \
    && assert_eq "$(ro_issue_reads proj/repo-a 6)" "0" "AC1: #6 itself is never re-read" || rc=1
  ro_teardown; return $rc
}

test_ro_ac1_single_ticket_spec_keeps_its_one_read() {
  ro_setup; local rc=0
  jq -n '{number:2,state:"open",labels:[],user:{login:"jpmoya"},body:""}' > "$RO_DIR/issue-proj_repo-a-2.json"
  ro_run "goal_eval proj_repo-a-t2 proj/repo-a#2; echo \"\$GE_TOTAL \$GE_ACTIVE\""
  assert_eq "$RO_RC" "0" "exit 0 ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "$RO_OUT" "1 1" "single-ticket goal evaluates #2 as active" \
    && assert_eq "$(ro_issue_reads proj/repo-a 2)" "1" "AC1: the t spec keeps exactly its one issue read" || rc=1
  ro_teardown; return $rc
}

# ---- AC2: one comments fetch per open ticket, reused by the BLOCKED check and the #456 block --------------------------
test_ro_ac2_blocked_latest_ticket_costs_one_comments_fetch_and_no_issue_read() {
  ro_setup; local rc=0
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_REFS\" | grep -F 'proj/repo-a#1'"
  assert_contains "$RO_OUT" "proj/repo-a#1	waiting_jp	blocked on a decision only you can make" "BLOCKED needs_jp still classifies waiting_jp" \
    && assert_eq "$(ro_count 'repos/proj/repo-a/issues/1/comments')" "1" "AC2: exactly 1 comments call for #1 (3 today)" \
    && assert_eq "$(ro_issue_reads proj/repo-a 1)" "0" "AC2: 0 issue reads for #1" || rc=1
  ro_teardown; return $rc
}

test_ro_ac2_every_open_ticket_gets_exactly_one_comments_fetch() {
  ro_setup; local rc=0 n
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC"
  for n in 1 2 3 5; do
    assert_eq "$(ro_count "repos/proj/repo-a/issues/$n/comments")" "1" "AC2: #$n comments fetched once" || rc=1
  done
  assert_eq "$(ro_count 'repos/proj/repo-a/issues/4/comments')" "0" "AC2: closed #4 costs no read" || rc=1
  ro_teardown; return $rc
}

test_ro_ac2_latest_marker_with_prefetched_comments_makes_no_gh_call() {
  ro_setup; local rc=0 want got
  ro_run "latest_marker $RO_DIR/co-a 2"
  want=$RO_OUT
  : > "$RO_DIR/gh.log"
  ro_run "latest_marker $RO_DIR/co-a 2 \"\$(cat $RO_DIR/comments-proj_repo-a-2.json)\""
  got=$RO_OUT
  assert_eq "$want" "**[fullstack-developer] IMPLEMENTED**" "control: the fetching call answers the gate marker" \
    && assert_eq "$got" "$want" "AC2: pre-fetched comments give the same answer" \
    && assert_eq "$(wc -l < "$RO_DIR/gh.log" | tr -d ' ')" "0" "AC2: with pre-fetched comments latest_marker calls gh 0 times" || rc=1
  # other callers (no 3rd arg) are unchanged: they still fetch (1 comments call) and answer the same
  : > "$RO_DIR/gh.log"
  ro_run "latest_marker $RO_DIR/co-a 3"
  assert_eq "$RO_OUT" "**[deployer] DEPLOYED**" "AC2: no-argument callers still answer" \
    && assert_eq "$(ro_count 'repos/proj/repo-a/issues/3/comments')" "1" "AC2: no-argument callers still fetch once" || rc=1
  ro_teardown; return $rc
}

test_ro_ac2_failed_comments_fetch_is_surfaced_not_swallowed() {
  ro_setup; local rc=0 ev
  touch "$RO_DIR/fail-comments-1"
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC"
  ev=$(cat "$RO_DIR/events.log" 2>/dev/null)
  assert_ne "$RO_RC" "0" "a failed comments fetch fails the evaluation (never 'delivered')" \
    && assert_contains "$(cat "$RO_DIR/slog")" "proj/repo-a#1" "log names the ticket" \
    && assert_contains "$ev" "error" "error event captured" \
    && assert_contains "$ev" "supervisor/goal" "event carries the route tag" \
    && assert_contains "$ev" "release" "event carries the release tag" \
    && assert_contains "$ev" "proj/repo-a#1" "event names the ticket" \
    && assert_not_contains "$ev" "ghp_" "no token in the event" \
    && assert_eq "$(ro_count 'repos/proj/repo-a/issues/1/comments')" "1" "no retry or second fetch" \
    && assert_eq "$(ro_issue_reads proj/repo-a 1)" "0" "no issue read even on the failure path" || rc=1
  ro_teardown; return $rc
}

# ---- AC3: the digest reads the registry once; sw_covered answers from SW_REGISTRY_JSON ---------------------------------
ro_registry_fixture() {
  ro_reg 901 open '{"id":"proj_repo-a-ms-12","spec":"proj/repo-a:milestone:12","go":true}' ""
  ro_reg 902 open '{"id":"proj_repo-b-all","spec":"proj/repo-b:milestones:all","go":true}' ""
  ro_reg 903 open '{"id":"proj_repo-c-ms-5","spec":"proj/repo-c:milestone:Sprint Five","go":true}' ""
  ro_reg 904 open '{"id":"proj_repo-d-ms-3","spec":"proj/repo-d:milestone:3","go":false}' ""
  ro_reg 906 closed '{"id":"proj_repo-e-ms-4","spec":"proj/repo-e:milestone:4","go":true}' ""
}

# prints "<ms-case rc>..." for the six coverage questions, all in ONE shell (the cache lives in that shell)
RO_COVER_Q='for q in "proj/repo-a 12 []" "proj/repo-b 99 []" "proj/repo-c 5 []" "proj/repo-d 3 []" "proj/repo-a 13 []" "proj/repo-e 4 []"; do
  set -- $q; sw_covered "$1" "$2" "$3"; printf "%s " "$?"; done'

test_ro_ac3_covered_answers_follow_the_goal_milestone_approved_rules() {
  ro_setup; ro_registry_fixture; local rc=0
  ro_run "$RO_COVER_Q"
  # a: milestone:12 spec, go:true -> 0 | b: milestones:all -> 0 | c: -ms-5 id match under a renamed title -> 0
  # d: go:false -> 1 | a#13: no goal covers 13 -> 1 | e#4: covering goal is closed -> 1 (goal_milestone_approved reads open registry issues only)
  assert_eq "$RO_OUT" "0 0 0 1 1 1 " "AC3: coverage verdicts" \
    && assert_eq "$(ro_count 'labels=delivery-goal&state=open')" "1" "AC3: ...answered from one registry read" || rc=1
  ro_teardown; return $rc
}

test_ro_ac3_digest_run_reads_the_registry_once() {
  ro_setup; ro_registry_fixture; local rc=0
  ro_run "$RO_COVER_Q"
  assert_eq "$(ro_count 'labels=delivery-goal&state=open')" "1" "AC3: open registry listing read once for 6 questions (6 today)" \
    && assert_eq "$(ro_count 'labels=delivery-goal&state=closed')" "1" "AC3: closed registry listing read once" || rc=1
  ro_teardown; return $rc
}

test_ro_ac3_unreadable_registry_fails_closed() {
  ro_setup; ro_registry_fixture; touch "$RO_DIR/registry-fail"; local rc=0
  ro_run 'sw_covered proj/repo-a 12 "[]"; a=$?; sw_covered proj/repo-z null "[]"; echo "$a $?"'
  assert_eq "$RO_OUT" "2 2" "AC3: unreadable registry -> 2 (unknown), for a milestone ticket and a ticket with no milestone" \
    && assert_eq "$(ro_count 'labels=delivery-goal&state=open')" "1" "the failed read is not retried per ticket" || rc=1
  ro_teardown; return $rc
}

# ---- AC4: a goal naming a renamed repo uses the canonical slug in every REST path ---------------------------------------
test_ro_ac4_renamed_repo_goal_never_hits_the_old_slug() {
  ro_setup; local rc=0 f
  cp "$RO_DIR/list-proj_repo-a.json" "$RO_DIR/list-new-org_ops-tool.json"
  for f in 1 2 3 5; do cp "$RO_DIR/comments-proj_repo-a-$f.json" "$RO_DIR/comments-new-org_ops-tool-$f.json"; done
  ro_run "goal_eval old-org_scheduler-ms-12 old-org/scheduler:milestone:12; echo \"\$GE_TOTAL \$GE_DELIVERED \$GE_WAITING \$GE_ACTIVE\""
  assert_eq "$RO_RC" "0" "goal_eval succeeds on the renamed-repo goal ($(cat "$RO_DIR/stderr"))" \
    && assert_eq "$RO_OUT" "5 2 2 1" "same classes as the same fixture under its canonical name" \
    && assert_eq "$(ro_count 'repos/old-org/scheduler')" "0" "AC4: no REST path names the old slug (each would be a 301)" \
    && assert_eq "$(ro_count '^repo view old-org/scheduler')" "1" "AC4: repo_canon resolves the old slug once (cached), not per ticket" || rc=1
  # AC6: no new state file under $PIPE besides repo_canon's own cache dir
  assert_eq "$(find "$RO_DIR/pipe" -type f -not -path '*/repo-canon/*' | wc -l | tr -d ' ')" "0" "AC6: no new file under \$PIPE" || rc=1
  ro_teardown; return $rc
}

# ---- AC5: classification unchanged -----------------------------------------------------------------------------------
test_ro_ac5_snapshot_is_unchanged() {
  ro_setup; local rc=0 want
  # GE_SNAP lines: ref <TAB> issue state <TAB> gate-marker first line <TAB> class (hand-written from the fixture)
  want=$(printf '%s\n' \
    "proj/repo-a#1	OPEN	**[fullstack-developer] BLOCKED**	waiting_jp" \
    "proj/repo-a#2	OPEN	**[fullstack-developer] IMPLEMENTED**	active" \
    "proj/repo-a#3	OPEN	**[deployer] DEPLOYED**	delivered" \
    "proj/repo-a#4	CLOSED	-	delivered" \
    "proj/repo-a#5	OPEN	none	waiting_jp")
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_SNAP\""
  assert_eq "$RO_OUT" "$want" "AC5: GE_SNAP identical to the pre-change classification" \
    && assert_eq "$(ro_count '^api( --paginate)? repos/proj/repo-a/issues/[0-9]+( |$)')" "0" "AC5: ...while reading no issue (the AC1 saving does not change the answer)" || rc=1
  ro_teardown; return $rc
}

run_test test_ro_ac1_scope_listed_tickets_cost_no_issue_read
run_test test_ro_ac1_labels_and_author_come_from_the_listing
run_test test_ro_ac1_start_gate_body_comes_from_the_listing
run_test test_ro_ac1_single_ticket_spec_keeps_its_one_read
run_test test_ro_ac2_blocked_latest_ticket_costs_one_comments_fetch_and_no_issue_read
run_test test_ro_ac2_every_open_ticket_gets_exactly_one_comments_fetch
run_test test_ro_ac2_latest_marker_with_prefetched_comments_makes_no_gh_call
run_test test_ro_ac2_failed_comments_fetch_is_surfaced_not_swallowed
run_test test_ro_ac3_covered_answers_follow_the_goal_milestone_approved_rules
run_test test_ro_ac3_digest_run_reads_the_registry_once
run_test test_ro_ac3_unreadable_registry_fails_closed
run_test test_ro_ac4_renamed_repo_goal_never_hits_the_old_slug
run_test test_ro_ac5_snapshot_is_unchanged
