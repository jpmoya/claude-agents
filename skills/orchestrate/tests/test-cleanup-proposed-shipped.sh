# Issue #676 (a), Expected Behavior 4 — cleanup-proposed-shipped.sh [--dry-run] <owner/repo>...: the one-time, idempotent
# removal of `agent-proposed` from open issues the pipeline has in flight or has shipped: the latest stage marker comes from
# an engineering-or-later stage (test-writer, test-reviewer, fullstack-developer, code-reviewer, deployer, infra track).
# A ticket whose latest stage marker is a spec-stage one (PM, intake, design, architect), or that has none, keeps the label.
#
# gh stub with label state (so a second run really sees the first run's writes), fixture files in the sandbox HOME:
#   issues.json          [{number, repo, labels:[{name}]}] — `issue list --label L` filters it, `issue edit --remove-label` rewrites it
#   comments-<n>.json    the per-issue comments read (REST shape; default [])
#   comments-<n>.rc      exit code of that read (default 0)
#   list-fail            when present, `issue list` exits 1
#   edit-fail            when present, `issue edit` exits 1 (and writes nothing)
# Expected values are hand-written from the ticket. Placeholder repo names only.

HERE_CPS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CPS="$HERE_CPS/../cleanup-proposed-shipped.sh"

cps_home() {
  local home; home=$(new_home); CPS_HOME=$home; mkdir -p "$home/bin"
  echo '[]' > "$home/issues.json"; : > "$home/gh.log"; : > "$home/curl.log"
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$HOME/gh.log"
jqx=""; label=""; repo=""; reml=""; prev=""
for a in "$@"; do
  case "$prev" in --jq|-q) jqx=$a ;; --label) label=$a ;; --repo) repo=$a ;; --remove-label) reml=$a ;; esac; prev=$a
done
case "$1 $2" in
  "api repos/"*)
    case "$2" in
      repos/*/issues/[0-9]*/comments*)
        n=$(printf '%s' "$2" | sed -E 's#.*/issues/([0-9]+)/comments.*#\1#')
        rc=$(cat "$HOME/comments-$n.rc" 2>/dev/null || echo 0)
        [ "$rc" -eq 0 ] || { echo "gh: HTTP 502" >&2; exit "$rc"; }
        if [ -f "$HOME/comments-$n.json" ]; then cat "$HOME/comments-$n.json"; else echo '[]'; fi
        exit 0 ;;
    esac
    echo '[]'; exit 0 ;;
  "issue list")
    [ -f "$HOME/list-fail" ] && exit 1
    j=$(jq -c --arg r "$repo" --arg l "$label" '[.[] | select(.repo == $r) | select($l == "" or ([.labels[].name] | index($l)))]' "$HOME/issues.json")
    if [ -n "$jqx" ]; then printf '%s' "$j" | jq -r "$jqx"; else printf '%s\n' "$j"; fi
    exit 0 ;;
  "issue edit")
    [ -f "$HOME/edit-fail" ] && exit 1
    jq --argjson n "$3" --arg r "$repo" --arg rm "$reml" \
      'map(if .number == $n and .repo == $r then .labels |= map(select(.name != $rm)) else . end)' "$HOME/issues.json" > "$HOME/i.tmp" && mv "$HOME/i.tmp" "$HOME/issues.json"
    exit 0 ;;
esac
exit 0
STUB
  cat > "$home/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$HOME/curl.log"; echo ok
STUB
  chmod +x "$home/bin/gh" "$home/bin/curl"
  printf 'SLACK_WEBHOOK_URL=https://example.invalid/hook\n' > "$home/.claude/pipeline/config.local.sh"
}
# cps_issue <n> <repo> [label...]
cps_issue() {
  local n=$1 r=$2; shift 2
  jq --argjson n "$n" --arg r "$r" --argjson l "$(printf '%s\n' "$@" | jq -R 'select(length > 0)' | jq -sc 'map({name:.})')" \
    '. + [{number:$n,repo:$r,labels:$l}]' "$CPS_HOME/issues.json" > "$CPS_HOME/i.tmp" && mv "$CPS_HOME/i.tmp" "$CPS_HOME/issues.json"
}
cps_comment() {  # cps_comment <n> <body>
  local f="$CPS_HOME/comments-$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq --arg b "$2" '. + [{id: (length + 1), body: $b, created_at: "2026-11-06T00:00:00Z", user: {login: "someone"}}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# cps_run [args...] — one run in the sandbox; sets CPS_RC, CPS_OUT (stdout), CPS_ERR (stderr)
cps_run() {
  CPS_OUT=$(HOME="$CPS_HOME" PATH="$CPS_HOME/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" /bin/bash "$CPS" "$@" 2>"$CPS_HOME/stderr.log"); CPS_RC=$?
  CPS_ERR=$(cat "$CPS_HOME/stderr.log")
}
cps_labels() { jq -r --argjson n "$1" '.[] | select(.number == $n) | [.labels[].name] | sort | join(",")' "$CPS_HOME/issues.json"; }
cps_writes() { grep -c '^issue edit ' "$CPS_HOME/gh.log"; }
cps_cleanup() { rm -rf "$CPS_HOME"; }

# the ticket's four fixtures: (i) IMPLEMENTED, (ii) DEPLOYED TO STAGING, (iii) only a PM READY, (iv) no comments
cps_fixture() {
  cps_home
  cps_issue 1 project-a/repo-a agent-proposed bug;  cps_comment 1 "**[product-manager] READY FOR ENGINEERING**"; cps_comment 1 "**[fullstack-developer] IMPLEMENTED**"
  cps_issue 2 project-a/repo-a agent-proposed;      cps_comment 2 "$(printf '**[deployer] DEPLOYED TO STAGING**\nPR #9 merged')"
  cps_issue 3 project-a/repo-a agent-proposed;      cps_comment 3 "**[product-manager] READY FOR ENGINEERING**"
  cps_issue 4 project-a/repo-a agent-proposed
  cps_issue 5 project-a/repo-a agent-go;            cps_comment 5 "**[deployer] DEPLOYED**"   # not agent-proposed: never listed
}

test_cps_removes_label_on_implemented_and_deployed_only() {
  cps_fixture
  cps_run project-a/repo-a
  local l1 l2 l3 l4 l5 writes out=$CPS_OUT rc=$CPS_RC
  l1=$(cps_labels 1); l2=$(cps_labels 2); l3=$(cps_labels 3); l4=$(cps_labels 4); l5=$(cps_labels 5); writes=$(cps_writes)
  local log; log=$(cat "$CPS_HOME/gh.log")
  cps_cleanup
  assert_eq "$rc" "0" "exit 0 when every read and write worked" || return 1
  assert_eq "$l1" "bug" "(i) IMPLEMENTED: agent-proposed removed, other labels kept" || return 1
  assert_eq "$l2" "" "(ii) DEPLOYED TO STAGING: agent-proposed removed" || return 1
  assert_eq "$l3" "agent-proposed" "(iii) only a PM READY: label kept (a specified idea waiting for JP)" || return 1
  assert_eq "$l4" "agent-proposed" "(iv) no comments: label kept" || return 1
  assert_eq "$l5" "agent-go" "an issue without agent-proposed is never touched" || return 1
  assert_eq "$writes" "2" "exactly two writes (i and ii)" || return 1
  assert_contains "$log" "issue edit 1 --repo project-a/repo-a --remove-label agent-proposed" "the write removes agent-proposed" || return 1
  assert_contains "$out" "project-a/repo-a#1 removed" "one line per issue: (i) removed" || return 1
  assert_contains "$out" "project-a/repo-a#2 removed" "one line per issue: (ii) removed" || return 1
  assert_contains "$out" "project-a/repo-a#3 kept" "one line per issue: (iii) kept" || return 1
  assert_contains "$out" "project-a/repo-a#4 kept" "one line per issue: (iv) kept" || return 1
  assert_eq "$(printf '%s\n' "$out" | grep -c .)" "4" "four lines, one per agent-proposed issue" || return 1
}

test_cps_applied_marker_also_removes() {
  cps_home
  cps_issue 6 project-a/repo-a agent-proposed infra; cps_comment 6 "**[infra-operator] APPLIED**"
  cps_issue 7 project-a/repo-a agent-proposed;       cps_comment 7 "The deployer said **[deployer] DEPLOYED** somewhere mid-sentence"
  cps_issue 8 project-a/repo-a agent-proposed;       cps_comment 8 "$(printf 'Status update\n**[deployer] DEPLOYED**')"
  cps_run project-a/repo-a
  local l6 l7 l8; l6=$(cps_labels 6); l7=$(cps_labels 7); l8=$(cps_labels 8)
  cps_cleanup
  assert_eq "$l6" "infra" "[infra-operator] APPLIED removes the label" || return 1
  assert_eq "$l7" "agent-proposed" "a marker quoted mid-line is not a first-line marker: kept" || return 1
  assert_eq "$l8" "agent-proposed" "a marker on line 2 is not a first-line marker: kept" || return 1
}

test_cps_latest_routing_marker_decides() {
  # code review of PR #680: an older shipped marker must not strip the label of a ticket that was re-specified since
  cps_home
  cps_issue 30 project-a/repo-a agent-proposed   # shipped, then specified again by the PM: waiting for JP, label kept
  cps_comment 30 "**[deployer] DEPLOYED**"; cps_comment 30 "**[product-manager] READY FOR ENGINEERING**"
  cps_issue 31 project-a/repo-a agent-proposed   # implemented, review failed: in a fix cycle, i.e. in flight
  cps_comment 31 "**[fullstack-developer] IMPLEMENTED**"; cps_comment 31 "**[code-reviewer] FAIL**"
  cps_issue 32 project-a/repo-a agent-proposed   # re-specified, then shipped again: the latest marker is the deployer's
  cps_comment 32 "**[deployer] DEPLOYED**"; cps_comment 32 "**[product-manager] READY FOR ENGINEERING**"; cps_comment 32 "**[deployer] DEPLOYED TO STAGING**"
  cps_issue 33 project-a/repo-a agent-proposed   # shipped, then only chatter and inert lines: still the latest ROUTING marker
  cps_comment 33 "**[deployer] DEPLOYED**"; cps_comment 33 "Thanks, looks good"
  cps_comment 33 "**[supervisor] NOTE** claim: Claude 2026-11-06T00:00:00Z"; cps_comment 33 "**[fullstack-developer] NOTE** follow-up filed"
  cps_run project-a/repo-a
  local l30 l31 l32 l33 out=$CPS_OUT rc=$CPS_RC; l30=$(cps_labels 30); l31=$(cps_labels 31); l32=$(cps_labels 32); l33=$(cps_labels 33)
  cps_cleanup
  assert_eq "$rc" "0" "latest marker: exit 0" || return 1
  assert_eq "$l30" "agent-proposed" "DEPLOYED then a PM READY: re-specified, label kept" || return 1
  assert_contains "$out" "project-a/repo-a#30 kept" "re-specified ticket reported as kept" || return 1
  assert_eq "$l31" "" "IMPLEMENTED then [code-reviewer] FAIL: in flight, label removed" || return 1
  assert_eq "$l32" "" "READY then DEPLOYED TO STAGING: the latest marker is shipped, label removed" || return 1
  assert_eq "$l33" "" "comments and NOTEs after DEPLOYED are not routing markers: label removed" || return 1
}

# cps_latest <n> <marker first line>... — an agent-proposed issue whose comments are these lines, in order
cps_latest() { local n=$1 m; shift; cps_issue "$n" project-a/repo-a agent-proposed; for m in "$@"; do cps_comment "$n" "$m"; done; }

test_cps_engineering_or_later_stage_removes_the_label() {
  # the stranding bug: a ticket the pipeline has in flight (any engineering-or-later stage) or shipped must lose agent-proposed
  cps_home
  cps_latest 40 "**[product-manager] READY FOR ENGINEERING**" "**[test-writer] TESTS WRITTEN**"
  cps_latest 41 "**[test-writer] TESTS WRITTEN**" "**[test-reviewer] TESTS APPROVED**"
  cps_latest 42 "**[fullstack-developer] IMPLEMENTED**" "**[code-reviewer] PASS**"
  cps_latest 43 "**[fullstack-developer] IMPLEMENTED**" "**[test-reviewer] FAIL**"
  cps_latest 44 "$(printf '**[fullstack-developer] BLOCKED**\nBlocked on: ci_red — x')"
  cps_latest 45 "$(printf '**[deployer] BLOCKED**\nBlocked on: merge_conflict — x')"
  cps_latest 46 "**[infra-planner] PLAN READY**" "**[infra-reviewer] PLAN PASS**" "**[infra-operator] AWAITING GO**"
  cps_latest 47 "**[deployer] DEPLOYED TO STAGING**" "**[jp] GO**"                          # JP's answer is not a stage
  cps_latest 48 "**[fullstack-developer] BLOCKED**" "$(printf '**[delivery-lead] DECISION**\nResolves: https://example.invalid/x#issuecomment-1')"
  cps_run project-a/repo-a
  local n left="" out=$CPS_OUT rc=$CPS_RC
  for n in 40 41 42 43 44 45 46 47 48; do [ -z "$(cps_labels "$n")" ] || left="$left $n"; done
  cps_cleanup
  assert_eq "$rc" "0" "engineering or later: exit 0" || return 1
  assert_eq "$left" "" "engineering or later: agent-proposed removed from every in-flight / shipped ticket (still labelled:$left)" || return 1
  assert_eq "$(printf '%s\n' "$out" | grep -c ' removed$')" "9" "engineering or later: nine removed lines" || return 1
}

test_cps_spec_stage_or_no_marker_keeps_the_label() {
  # a ticket that is specified (or re-specified) and waiting for approval keeps agent-proposed
  cps_home
  cps_latest 50 "**[intake] TRIAGED BUG**"
  cps_latest 51 "**[product-manager] READY FOR ARCHITECTURE**"
  cps_latest 52 "**[product-manager] READY FOR ENGINEERING**" "**[ux-flow-designer] USER FLOW READY**"
  cps_latest 53 "**[ui-ux-designer] MOCKUPS PENDING APPROVAL**" "**[jp] MOCKUPS APPROVED**"   # still a design-stage ticket
  cps_latest 54 "**[solutions-architect] READY FOR ENGINEERING**"
  cps_latest 55 "**[deployer] DEPLOYED**" "**[fullstack-developer] NOTE** follow-up" "**[product-manager] EFFORT APPROVAL NEEDED**"
  cps_latest 56 "$(printf '**[orchestrator] BLOCKED**\nBlocked on: unsupported_project — x')"   # no stage marker at all
  cps_latest 57 "Could we also cover the mobile view?"
  cps_run project-a/repo-a
  local n lost="" out=$CPS_OUT rc=$CPS_RC writes; writes=$(cps_writes)
  for n in 50 51 52 53 54 55 56 57; do [ "$(cps_labels "$n")" = "agent-proposed" ] || lost="$lost $n"; done
  cps_cleanup
  assert_eq "$rc" "0" "spec stage: exit 0" || return 1
  assert_eq "$lost" "" "spec stage / no stage marker: agent-proposed kept (lost on:$lost)" || return 1
  assert_eq "$writes" "0" "spec stage: zero writes" || return 1
  assert_eq "$(printf '%s\n' "$out" | grep -c ' kept$')" "8" "spec stage: eight kept lines" || return 1
}

test_cps_second_run_issues_zero_writes() {
  cps_fixture
  cps_run project-a/repo-a
  : > "$CPS_HOME/gh.log"
  cps_run project-a/repo-a
  local writes out=$CPS_OUT rc=$CPS_RC; writes=$(cps_writes)
  cps_cleanup
  assert_eq "$writes" "0" "idempotent: the second run removes nothing" || return 1
  assert_eq "$rc" "0" "idempotent: the second run exits 0" || return 1
  assert_not_contains "$out" "removed" "idempotent: nothing reported as removed" || return 1
  assert_contains "$out" "project-a/repo-a#3 kept" "idempotent: the kept tickets are still listed" || return 1
}

test_cps_dry_run_makes_no_write() {
  cps_fixture
  cps_run --dry-run project-a/repo-a
  local writes out=$CPS_OUT rc=$CPS_RC l1; writes=$(cps_writes); l1=$(cps_labels 1)
  cps_cleanup
  assert_eq "$writes" "0" "--dry-run: zero writes" || return 1
  assert_eq "$l1" "agent-proposed,bug" "--dry-run: labels untouched" || return 1
  assert_eq "$rc" "0" "--dry-run: exit 0" || return 1
  assert_contains "$out" "project-a/repo-a#1 would remove" "--dry-run: (i) would remove" || return 1
  assert_contains "$out" "project-a/repo-a#2 would remove" "--dry-run: (ii) would remove" || return 1
  assert_contains "$out" "project-a/repo-a#3 kept" "--dry-run: (iii) kept" || return 1
}

test_cps_failed_comments_read_exits_1_and_writes_nothing_for_that_issue() {
  cps_fixture
  echo 1 > "$CPS_HOME/comments-2.rc"
  cps_run project-a/repo-a
  local l1 l2 writes out=$CPS_OUT err=$CPS_ERR rc=$CPS_RC curl sha
  l1=$(cps_labels 1); l2=$(cps_labels 2); writes=$(cps_writes); curl=$(cat "$CPS_HOME/curl.log")
  sha=$(git -C "$HERE_CPS" rev-parse HEAD 2>/dev/null || echo unknown)
  cps_cleanup
  assert_eq "$rc" "1" "read failure: exit 1" || return 1
  assert_eq "$l2" "agent-proposed" "read failure: no write for that issue" || return 1
  assert_eq "$l1" "bug" "read failure: the other issues are still processed" || return 1
  assert_eq "$writes" "1" "read failure: one write only (issue 1)" || return 1
  assert_contains "$out" "project-a/repo-a#2 read failed" "read failure: its line says read failed" || return 1
  assert_contains "$err" "project-a/repo-a#2 read failed: release=$sha environment=$(hostname -s) route=cleanup-proposed" "read failure: tagged stderr line" || return 1
  assert_eq "$(printf '%s\n' "$curl" | grep -c 'example.invalid/hook')" "1" "read failure: one Slack message through the existing webhook" || return 1
  assert_contains "$curl" "cleanup-proposed-shipped: 1 failure(s) (project-a/repo-a#2 read failed): release=$sha environment=$(hostname -s) route=cleanup-proposed" "read failure: tagged payload, refs and counts only" || return 1
}

test_cps_failed_list_and_failed_write_exit_1() {
  cps_fixture; touch "$CPS_HOME/list-fail"
  cps_run project-a/repo-a
  local rc_list=$CPS_RC out_list=$CPS_OUT writes_list; writes_list=$(cps_writes)
  rm -f "$CPS_HOME/list-fail"; touch "$CPS_HOME/edit-fail"
  cps_run project-a/repo-a
  local rc_edit=$CPS_RC out_edit=$CPS_OUT err_edit=$CPS_ERR l1; l1=$(cps_labels 1)
  cps_cleanup
  assert_eq "$rc_list" "1" "list read failure: exit 1" || return 1
  assert_eq "$writes_list" "0" "list read failure: nothing written" || return 1
  assert_contains "$out_list" "project-a/repo-a read failed" "list read failure: reported" || return 1
  assert_eq "$rc_edit" "1" "write failure: exit 1" || return 1
  assert_eq "$l1" "agent-proposed,bug" "write failure: label still there" || return 1
  assert_contains "$out_edit" "project-a/repo-a#1 write failed" "write failure: reported, not claimed as removed" || return 1
  assert_not_contains "$out_edit" "removed" "write failure: nothing reported as removed" || return 1
  assert_contains "$err_edit" "route=cleanup-proposed" "write failure: tagged stderr line" || return 1
}

test_cps_dry_run_failure_posts_no_slack() {
  cps_fixture; echo 1 > "$CPS_HOME/comments-2.rc"
  cps_run --dry-run project-a/repo-a
  local rc=$CPS_RC curl; curl=$(cat "$CPS_HOME/curl.log")
  cps_cleanup
  assert_eq "$rc" "1" "--dry-run read failure: still exit 1" || return 1
  assert_eq "$curl" "" "--dry-run: no Slack post (the operator is reading the output)" || return 1
}

test_cps_refuses_business_intelligence_and_direct_route_repos() {
  cps_fixture
  cps_issue 20 project-c/Business-Intelligence agent-proposed; cps_comment 20 "**[deployer] DEPLOYED**"
  cps_run project-a/repo-a project-c/Business-Intelligence
  local rc_bi=$CPS_RC err_bi=$CPS_ERR calls_bi; calls_bi=$(grep -c . "$CPS_HOME/gh.log")
  local dr; dr=$(sed -n 's/^DIRECT_ROUTE_REPOS=("\([^"]*\)").*/\1/p' "$HERE_CPS/../config.sh")   # the repo config.sh names, not a literal here
  [ -n "$dr" ] || { cps_cleanup; fail "could not read DIRECT_ROUTE_REPOS from config.sh"; return 1; }
  cps_run "$dr"
  local rc_dr=$CPS_RC err_dr=$CPS_ERR calls_dr; calls_dr=$(grep -c . "$CPS_HOME/gh.log")
  cps_run
  local rc_none=$CPS_RC
  cps_cleanup
  assert_eq "$rc_bi" "2" "Business-Intelligence: refused with exit 2" || return 1
  assert_contains "$err_bi" "refused: project-c/Business-Intelligence" "Business-Intelligence: the refusal names the repo" || return 1
  assert_eq "$calls_bi" "0" "Business-Intelligence: nothing read or written, not even for the valid repo of the same run" || return 1
  assert_eq "$rc_dr" "2" "direct-route repo: refused with exit 2" || return 1
  assert_contains "$err_dr" "refused: $dr" "direct-route repo: the refusal names the repo" || return 1
  assert_eq "$calls_dr" "0" "direct-route repo: nothing read or written" || return 1
  assert_eq "$rc_none" "2" "no repo given: usage error" || return 1
}

echo "-- cleanup-proposed-shipped.sh (#676)"
run_test test_cps_removes_label_on_implemented_and_deployed_only
run_test test_cps_applied_marker_also_removes
run_test test_cps_latest_routing_marker_decides
run_test test_cps_engineering_or_later_stage_removes_the_label
run_test test_cps_spec_stage_or_no_marker_keeps_the_label
run_test test_cps_second_run_issues_zero_writes
run_test test_cps_dry_run_makes_no_write
run_test test_cps_failed_comments_read_exits_1_and_writes_nothing_for_that_issue
run_test test_cps_failed_list_and_failed_write_exit_1
run_test test_cps_dry_run_failure_posts_no_slack
run_test test_cps_refuses_business_intelligence_and_direct_route_repos
